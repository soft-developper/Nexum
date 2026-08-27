// __NEXUM_MONITOR__ (phase7) monitoring + alerting for money flows
//
// Phase 7 Hardening. A cron job that watches the signals the roadmap named -
// failed transfers, stuck legs, and balance drift - and ALERTS through the
// structured logger + Sentry capture (Part 3), so a wedged payout or a run of
// failures surfaces instead of sitting silent in the DB.
//
// Mirrors the existing job pattern (treasuryChecker/txSettler): cron schedule,
// parseRows, a start* entry point mounted from index.ts. Read-only - it detects
// and alerts, it does not mutate money state (that is the engine/settler's job).
//
// Thresholds are env-tunable so alerting can be tightened without a deploy.

import cron from 'node-cron'
import { db } from '../db/client'
import { sql } from 'drizzle-orm'
import { log, captureException } from '../lib/logger'

function parseRows(r: any): any[] {
  if (!r) return []
  if (Array.isArray((r as any).rows)) return (r as any).rows
  if (Array.isArray(r)) return r
  return []
}

const int = (v: string | undefined, d: number) => {
  const n = Number(v); return Number.isFinite(n) && n > 0 ? n : d
}

// How far back to look for a burst of failures, and how many is "a burst".
const FAILED_LOOKBACK_MIN = int(process.env.MONITOR_FAILED_LOOKBACK_MIN, 60)
const FAILED_ALERT_COUNT  = int(process.env.MONITOR_FAILED_ALERT_COUNT, 3)

// A leg in flight (or a transfer in progress) older than this is "stuck".
const STUCK_MINUTES = int(process.env.MONITOR_STUCK_MINUTES, 30)

/*
  Alert helper: routes through captureException so it both logs structured JSON
  AND ships to Sentry when configured. We synthesize an Error so the alert lands
  in the same place real exceptions do, with a stable, greppable name.
*/
function alert(kind: string, summary: string, detail: Record<string, unknown>) {
  const e = new Error(`[monitor:${kind}] ${summary}`)
  e.name = `MonitorAlert:${kind}`
  captureException(e, { scope: 'monitor', kind, ...detail })
}

export function startMonitor() {
  console.log('[Monitor] ✅ Started, checks every 5 minutes')
  // Every 5 minutes.
  cron.schedule('*/5 * * * *', runChecks)
  // Also shortly after boot.
  setTimeout(runChecks, 45_000)
}

export async function runChecks() {
  await checkFailedTransfers().catch(err =>
    captureException(err, { scope: 'monitor.checkFailedTransfers' }))
  await checkStuckLegs().catch(err =>
    captureException(err, { scope: 'monitor.checkStuckLegs' }))
  await checkStuckTransfers().catch(err =>
    captureException(err, { scope: 'monitor.checkStuckTransfers' }))
}

// ── 1. A burst of failed transfers ──────────────────────────
async function checkFailedTransfers() {
  const cutoff = Math.floor(Date.now() / 1000) - FAILED_LOOKBACK_MIN * 60
  const rows = parseRows(await db.run(sql`
    SELECT id, updated_at FROM transfers
    WHERE status = 'failed' AND updated_at >= ${cutoff}`))

  if (rows.length >= FAILED_ALERT_COUNT) {
    alert('failed_transfers',
      `${rows.length} transfers failed in the last ${FAILED_LOOKBACK_MIN} min`,
      { count: rows.length, lookbackMin: FAILED_LOOKBACK_MIN,
        ids: rows.slice(0, 20).map(r => r.id ?? r[0]) })
  } else {
    log.debug('monitor: failed-transfer check ok', { count: rows.length })
  }
}

// ── 2. Legs stuck in flight ─────────────────────────────────
async function checkStuckLegs() {
  const cutoff = Math.floor(Date.now() / 1000) - STUCK_MINUTES * 60
  const rows = parseRows(await db.run(sql`
    SELECT id, transfer_id, leg_type, updated_at FROM transfer_legs
    WHERE status = 'in_flight' AND updated_at < ${cutoff}`))

  if (rows.length > 0) {
    alert('stuck_legs',
      `${rows.length} leg(s) in_flight for over ${STUCK_MINUTES} min`,
      { count: rows.length, stuckMinutes: STUCK_MINUTES,
        legs: rows.slice(0, 20).map(r => ({
          id: r.id ?? r[0], transferId: r.transfer_id ?? r[1],
          legType: r.leg_type ?? r[2] })) })
  } else {
    log.debug('monitor: stuck-leg check ok')
  }
}

// ── 3. Transfers stuck in progress ──────────────────────────
async function checkStuckTransfers() {
  const cutoff = Math.floor(Date.now() / 1000) - STUCK_MINUTES * 60
  const rows = parseRows(await db.run(sql`
    SELECT id, current_leg, updated_at FROM transfers
    WHERE status = 'in_progress' AND updated_at < ${cutoff}`))

  if (rows.length > 0) {
    alert('stuck_transfers',
      `${rows.length} transfer(s) in_progress for over ${STUCK_MINUTES} min`,
      { count: rows.length, stuckMinutes: STUCK_MINUTES,
        ids: rows.slice(0, 20).map(r => r.id ?? r[0]) })
  } else {
    log.debug('monitor: stuck-transfer check ok')
  }
}

// NOTE on balance drift: a meaningful drift alert needs an expected-balance
// source to compare the on-chain platform/treasury balance against (e.g. sum of
// completed-but-unswept legs, or a recorded ledger total). That reference does
// not exist yet as a single query, so rather than emit a fake number we leave a
// clear seam here. Wire it when the platform ledger total is available:
//
//   async function checkBalanceDrift() {
//     const onChain = await readPlatformUsdcBalance()      // viem, like treasuryChecker
//     const expected = await readLedgerExpectedBalance()   // TODO: ledger total
//     if (absDiff(onChain, expected) > DRIFT_TOLERANCE) alert('balance_drift', ...)
//   }
