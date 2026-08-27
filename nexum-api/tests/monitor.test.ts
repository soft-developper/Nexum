import { describe, it, expect, vi, beforeEach, afterEach, beforeAll } from 'vitest'

// ============================================================================
// Money-flow monitor (Phase 7 Hardening).
//
// Each check must ALERT when its threshold is crossed and stay QUIET otherwise.
// To avoid cross-test DB visibility gaps, we seed and reset through the SAME db
// singleton the monitor imports (../src/db/client), pointed at a throwaway file.
// ============================================================================

const DB_PATH = `/tmp/monitor-vitest-${process.pid}.db`
process.env.TURSO_DATABASE_URL = `file:${DB_PATH}`

const captureSpy = vi.fn()
vi.mock('../src/lib/logger', () => ({
  log: { debug: vi.fn(), info: vi.fn(), warn: vi.fn(), error: vi.fn() },
  captureException: (...a: any[]) => captureSpy(...a),
}))

import { sql } from 'drizzle-orm'
import { db } from '../src/db/client'

const now = () => Math.floor(Date.now() / 1000)
const minsAgo = (m: number) => now() - m * 60

beforeAll(async () => {
  await db.run(sql`CREATE TABLE IF NOT EXISTS transfers (
    id TEXT PRIMARY KEY, status TEXT NOT NULL, current_leg TEXT,
    created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL)`)
  await db.run(sql`CREATE TABLE IF NOT EXISTS transfer_legs (
    id TEXT PRIMARY KEY, transfer_id TEXT NOT NULL, leg_type TEXT NOT NULL,
    status TEXT NOT NULL, updated_at INTEGER NOT NULL)`)
})

beforeEach(async () => {
  await db.run(sql`DELETE FROM transfers`)
  await db.run(sql`DELETE FROM transfer_legs`)
  captureSpy.mockClear()
})
afterEach(() => { try { require('node:fs').unlinkSync(DB_PATH) } catch {} })

async function addTransfer(id: string, status: string, updatedAt: number) {
  await db.run(sql`INSERT INTO transfers (id, status, current_leg, created_at, updated_at)
    VALUES (${id}, ${status}, 'bridge', ${updatedAt}, ${updatedAt})`)
}
async function addLeg(id: string, status: string, updatedAt: number) {
  await db.run(sql`INSERT INTO transfer_legs (id, transfer_id, leg_type, status, updated_at)
    VALUES (${id}, ${'t-' + id}, 'bridge', ${status}, ${updatedAt})`)
}
const alertsOfKind = (kind: string) =>
  captureSpy.mock.calls.filter(c => c[1]?.kind === kind)

describe('monitor', () => {
  it('alerts when failed transfers exceed the threshold', async () => {
    for (let i = 0; i < 3; i++) await addTransfer(`f${i}`, 'failed', minsAgo(5))
    const { runChecks } = await import('../src/jobs/monitor')
    await runChecks()
    expect(alertsOfKind('failed_transfers').length).toBe(1)
  })
  it('stays quiet when failures are below the threshold', async () => {
    await addTransfer('f0', 'failed', minsAgo(5))
    const { runChecks } = await import('../src/jobs/monitor')
    await runChecks()
    expect(alertsOfKind('failed_transfers').length).toBe(0)
  })
  it('ignores OLD failures outside the lookback window', async () => {
    for (let i = 0; i < 5; i++) await addTransfer(`old${i}`, 'failed', minsAgo(600))
    const { runChecks } = await import('../src/jobs/monitor')
    await runChecks()
    expect(alertsOfKind('failed_transfers').length).toBe(0)
  })
  it('alerts on a leg stuck in_flight past the threshold', async () => {
    await addLeg('stuck1', 'in_flight', minsAgo(45))
    const { runChecks } = await import('../src/jobs/monitor')
    await runChecks()
    expect(alertsOfKind('stuck_legs').length).toBe(1)
  })
  it('does not alert on a leg only recently in_flight', async () => {
    await addLeg('fresh1', 'in_flight', minsAgo(5))
    const { runChecks } = await import('../src/jobs/monitor')
    await runChecks()
    expect(alertsOfKind('stuck_legs').length).toBe(0)
  })
  it('alerts on a transfer stuck in_progress past the threshold', async () => {
    await addTransfer('p1', 'in_progress', minsAgo(45))
    const { runChecks } = await import('../src/jobs/monitor')
    await runChecks()
    expect(alertsOfKind('stuck_transfers').length).toBe(1)
  })
  it('a clean system produces no alerts at all', async () => {
    await addTransfer('ok1', 'completed', minsAgo(5))
    await addLeg('okleg', 'done', minsAgo(5))
    const { runChecks } = await import('../src/jobs/monitor')
    await runChecks()
    expect(captureSpy).not.toHaveBeenCalled()
  })
})
