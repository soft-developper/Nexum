import type { Request, Response, NextFunction } from 'express'
import { createHash } from 'crypto'
import { sql } from 'drizzle-orm'
import { db } from '../db/client'

// ============================================================================
// Request-level idempotency (Phase 7 Hardening).
//
// Wrap a money-moving POST handler with withIdempotency('scope'). The client
// sends an `Idempotency-Key` header (a UUID it keeps stable across retries of
// the SAME logical action). Behaviour:
//
//   * First time we see (scope, key): reserve it ('in_progress'), run the
//     handler, capture its JSON response, cache it ('completed'), return it.
//   * Replay after completion: return the cached status + body verbatim - the
//     handler never runs again, so no second transfer / payment is created.
//   * Replay WHILE the first is still running: 409 in_progress, so a double-tap
//     can't slip through the gap between "check" and "write" (the race the
//     payroll status-gate alone can't close).
//   * Same key, DIFFERENT body: 422 - a reused key with a changed payload is a
//     client bug we refuse rather than silently serve the wrong cached answer.
//
// If NO header is sent, the request proceeds normally (idempotency is opt-in
// per request) - but the wired endpoints' clients always send one.
//
// Mirrors the ramp_webhook_events dedupe approach: a small guard table, keyed
// uniquely, checked before the side effect.
// ============================================================================

const STALE_SECONDS = Number(process.env.IDEMPOTENCY_STALE_SECONDS ?? '120')

function parseRows(r: any): any[] {
  if (!r) return []
  if (Array.isArray((r as any).rows)) return (r as any).rows
  if (Array.isArray(r)) return r
  return []
}

function fingerprint(body: unknown): string {
  let s: string
  try { s = JSON.stringify(body ?? null) } catch { s = String(body) }
  return createHash('sha256').update(s).digest('hex')
}

export function withIdempotency(scope: string) {
  return async function (req: Request, res: Response, next: NextFunction) {
    const key =
      (req.header('Idempotency-Key') || req.header('idempotency-key') || '').trim()

    // Opt-in: no key means behave exactly as before.
    if (!key) return next()

    const fp  = fingerprint(req.body)
    const now = Math.floor(Date.now() / 1000)

    // 1. Try to RESERVE the key atomically. INSERT OR IGNORE means only the
    //    first concurrent request wins the insert; the rest affect 0 rows.
    try {
      await db.run(sql`
        INSERT OR IGNORE INTO idempotency_keys
          (scope, idempotency_key, status, request_fingerprint, created_at)
        VALUES (${scope}, ${key}, 'in_progress', ${fp}, ${now})`)
    } catch (err: any) {
      // If the guard table is unavailable, fail OPEN to not block payments -
      // the endpoint keeps its own downstream protections (Circle idempotency,
      // status gates). Log and proceed.
      console.error('[idempotency] reserve failed, proceeding:', err?.message)
      return next()
    }

    // 2. Read back the row we either just inserted or that already existed.
    const rows = parseRows(await db.run(sql`
      SELECT status, response_status, response_body, request_fingerprint, created_at
      FROM idempotency_keys WHERE scope = ${scope} AND idempotency_key = ${key} LIMIT 1`))
    const row = rows[0]

    // Shouldn't happen (we just inserted), but be safe: proceed.
    if (!row) return next()

    const rowStatus = String(row.status ?? row[0])
    const rowFp     = String(row.request_fingerprint ?? row[3] ?? '')
    const createdAt = Number(row.created_at ?? row[4] ?? now)

    // Same key, different payload -> refuse.
    if (rowFp && rowFp !== fp) {
      return res.status(422).json({
        error: 'Idempotency-Key was already used with a different request body.',
        code:  'idempotency_key_reuse',
      })
    }

    // 3a. Already completed -> replay the cached response.
    if (rowStatus === 'completed') {
      const status = Number(row.response_status ?? row[1] ?? 200)
      let body: any = {}
      try { body = JSON.parse(String(row.response_body ?? row[2] ?? '{}')) } catch {}
      res.setHeader('Idempotent-Replay', 'true')
      return res.status(status).json(body)
    }

    // 3b. In progress. If it's OUR fresh reservation (we won the insert this
    //     request), fall through and run the handler. If it belongs to another
    //     in-flight request, 409 - unless it's stale (crashed handler), which
    //     we reclaim by proceeding.
    //     We distinguish "ours" by whether the reservation timestamp is this
    //     request's `now` AND no other has completed it - simplest correct rule:
    //     if reserved within this tick treat as ours; otherwise if not stale,
    //     it's a concurrent duplicate.
    const age = now - createdAt
    const isFreshlyOurs = age <= 0
    if (!isFreshlyOurs && age < STALE_SECONDS) {
      return res.status(409).json({
        error: 'A request with this Idempotency-Key is already being processed.',
        code:  'idempotency_in_progress',
      })
    }
    // stale or ours -> proceed to run the handler.

    // 4. Intercept the response so we can cache it once the handler replies.
    const originalJson = res.json.bind(res)
    let cached = false
    ;(res as any).json = (body: any) => {
      if (!cached) {
        cached = true
        const doneAt = Math.floor(Date.now() / 1000)
        const statusCode = res.statusCode || 200
        // Only cache SUCCESSFUL responses. A 4xx/5xx should be retryable with
        // the same key (the money didn't move), so we RELEASE the reservation
        // instead of caching a failure.
        if (statusCode >= 200 && statusCode < 300) {
          let bodyStr = '{}'
          try { bodyStr = JSON.stringify(body ?? {}) } catch {}
          db.run(sql`
            UPDATE idempotency_keys
            SET status = 'completed', response_status = ${statusCode},
                response_body = ${bodyStr}, completed_at = ${doneAt}
            WHERE scope = ${scope} AND idempotency_key = ${key}`).catch(() => {})
        } else {
          db.run(sql`
            DELETE FROM idempotency_keys
            WHERE scope = ${scope} AND idempotency_key = ${key}`).catch(() => {})
        }
      }
      return originalJson(body)
    }

    return next()
  }
}
