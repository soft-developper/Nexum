import { describe, it, expect, beforeAll, afterAll } from 'vitest'
import { createClient, type Client } from '@libsql/client'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { splitStatements } from '../src/db/migrate-lib'

// ============================================================================
// Idempotency guard - migration + table semantics (Phase 7 Hardening).
//
// Proves the request-level idempotency table behaves the way the middleware
// relies on: a single reservation per (scope, key), INSERT OR IGNORE making a
// concurrent duplicate a no-op, cached-response replay, fingerprint capture for
// key-reuse detection, and scope isolation. Runs against a throwaway libsql
// file DB, applying the real 0026 migration through the real splitStatements
// so we exercise exactly what `npm run migrate` would.
// ============================================================================

const DB_PATH = join('/tmp', `idem-vitest-${process.pid}.db`)
let client: Client

const now = () => Math.floor(Date.now() / 1000)

beforeAll(async () => {
  client = createClient({ url: `file:${DB_PATH}` })
  const sqlText = readFileSync(join('migrations', '0026_idempotency_keys.sql'), 'utf8')
  for (const stmt of splitStatements(sqlText)) {
    await client.execute(stmt)
  }
})

afterAll(async () => {
  client.close()
  try { require('node:fs').unlinkSync(DB_PATH) } catch {}
})

async function reserve(scope: string, key: string, fp: string) {
  await client.execute({
    sql: `INSERT OR IGNORE INTO idempotency_keys
            (scope, idempotency_key, status, request_fingerprint, created_at)
          VALUES (?, ?, 'in_progress', ?, ?)`,
    args: [scope, key, fp, now()],
  })
}
async function read(scope: string, key: string) {
  const r = await client.execute({
    sql: `SELECT status, response_status, response_body, request_fingerprint
          FROM idempotency_keys WHERE scope = ? AND idempotency_key = ?`,
    args: [scope, key],
  })
  return r.rows[0] as any
}
async function complete(scope: string, key: string, status: number, body: unknown) {
  await client.execute({
    sql: `UPDATE idempotency_keys
          SET status = 'completed', response_status = ?, response_body = ?, completed_at = ?
          WHERE scope = ? AND idempotency_key = ?`,
    args: [status, JSON.stringify(body), now(), scope, key],
  })
}
async function count(scope: string, key: string) {
  const r = await client.execute({
    sql: `SELECT COUNT(*) AS c FROM idempotency_keys WHERE scope = ? AND idempotency_key = ?`,
    args: [scope, key],
  })
  return Number((r.rows[0] as any).c)
}

describe('idempotency_keys table', () => {
  it('reserves a new key as in_progress', async () => {
    await reserve('transfers.create', 'K1', 'fpA')
    expect((await read('transfers.create', 'K1')).status).toBe('in_progress')
  })

  it('a concurrent duplicate reservation is a no-op (single row)', async () => {
    await reserve('transfers.create', 'K1', 'fpA')
    expect(await count('transfers.create', 'K1')).toBe(1)
  })

  it('caches a completed response for replay', async () => {
    await complete('transfers.create', 'K1', 201, { transferId: 'T-123' })
    const row = await read('transfers.create', 'K1')
    expect(row.status).toBe('completed')
    expect(Number(row.response_status)).toBe(201)
    expect(JSON.parse(row.response_body).transferId).toBe('T-123')
  })

  it('stores the request fingerprint for key-reuse detection', async () => {
    expect((await read('transfers.create', 'K1')).request_fingerprint).toBe('fpA')
  })

  it('isolates the same key across different scopes', async () => {
    await reserve('payments.create', 'K1', 'fpZ')
    expect((await read('payments.create', 'K1')).status).toBe('in_progress')
    // the transfers-scoped K1 is still completed, untouched
    expect((await read('transfers.create', 'K1')).status).toBe('completed')
  })
})
