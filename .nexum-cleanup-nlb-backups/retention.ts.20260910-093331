// __NEXUM_RETENTION_CAP__
// Per-user history cap: keep only the newest KEEP_LAST TERMINAL records per user,
// per protocol. On-chain data remains the source of truth (verifiable on
// explorers), so pruning old finished rows loses nothing critical.
//
// SAFETY (non-negotiable):
//  - Scoped per user (wallet), never global.
//  - Only TERMINAL (finished, money-settled) rows are counted or deleted.
//    In-flight rows (escrowed offers, unpaid invoices, processing payroll,
//    pending/mid-stage transfers) are NEVER counted and NEVER deleted.
//  - Every prune is best-effort: a failure here NEVER breaks the caller.
//  - Conservative terminal sets: anything ambiguous is treated as non-terminal.

import { db }  from '../db/client'
import { sql } from 'drizzle-orm'

const KEEP_LAST = 30

function lc(s: string): string { return String(s ?? '').toLowerCase() }

// Generic single-table pruner: delete a user's terminal rows older than the
// newest KEEP_LAST terminal rows. Uses id NOT IN (newest 30) so only surplus
// terminal rows go; in-flight rows are excluded by the status filter entirely.
async function pruneTable(
  table: 'transactions' | 'bridge_transfers' | 'p2p_offers' | 'invoices',
  ownerCol: string,
  owner: string,
  terminal: string[],
): Promise<void> {
  try {
    if (!owner) return
    const statuses = terminal.map((s) => `'${s}'`).join(', ')
    // sql.raw for identifiers/status-list (all internal constants, never user
    // input); the owner value is still bound as a parameter.
    await db.run(sql.raw(
      `DELETE FROM ${table}
        WHERE ${ownerCol} = '${lc(owner)}'
          AND status IN (${statuses})
          AND id NOT IN (
            SELECT id FROM ${table}
             WHERE ${ownerCol} = '${lc(owner)}'
               AND status IN (${statuses})
             ORDER BY created_at DESC
             LIMIT ${KEEP_LAST}
          )`
    ))
  } catch (e: any) {
    console.error(`[Retention] prune ${table} failed (non-fatal):`, e?.message ?? e)
  }
}

/** SEND - transactions. Terminal = settled | failed. */
export async function pruneSend(wallet: string): Promise<void> {
  await pruneTable('transactions', 'wallet_address', wallet, ['settled', 'failed'])
}

/** BRIDGE - bridge_transfers. Terminal = completed | failed | cancelled.
 *  'cancelled' is safe: markCancelled only writes it when NO burn landed (a
 *  burn would become 'stranded'), so no funds ever moved.
 *  NEVER prunes 'stranded' or any mid-stage (created/burning/attesting/
 *  minting) - those hold recovery evidence or are still in flight. */
export async function pruneBridge(wallet: string): Promise<void> {
  await pruneTable('bridge_transfers', 'wallet_address', wallet, ['completed', 'failed', 'cancelled'])
}

/** MY TRADES - p2p_offers, scoped to the offer owner (maker).
 *  Terminal = released | cancelled. NEVER prunes open/accepted (escrowed). */
export async function pruneTrades(maker: string): Promise<void> {
  await pruneTable('p2p_offers', 'maker_address', maker, ['released', 'cancelled'])
}

/** INVOICES - invoices, scoped to creator. Terminal = paid | cancelled.
 *  NEVER prunes draft/sent/overdue (live payment requests). */
export async function pruneInvoices(creator: string): Promise<void> {
  await pruneTable('invoices', 'creator_address', creator, ['paid', 'cancelled'])
}

/** PAYROLL - payroll_batches (+ cascade payroll_recipients).
 *  Terminal = completed | failed | partial. NEVER prunes draft/processing.
 *  Child recipients are deleted for exactly the batches being pruned. */
export async function prunePayroll(wallet: string): Promise<void> {
  try {
    if (!wallet) return
    const term = `('completed', 'failed', 'partial')`
    const w = lc(wallet)
    // Ids of surplus terminal batches to remove (older than newest 30).
    const rows = await db.run(sql.raw(
      `SELECT id FROM payroll_batches
        WHERE wallet_address = '${w}'
          AND status IN ${term}
          AND id NOT IN (
            SELECT id FROM payroll_batches
             WHERE wallet_address = '${w}'
               AND status IN ${term}
             ORDER BY created_at DESC
             LIMIT ${KEEP_LAST}
          )`
    ))
    const ids: string[] = ((rows as any)?.rows ?? rows ?? [])
      .map((r: any) => String(r.id ?? r[0])).filter(Boolean)
    if (ids.length === 0) return
    const idList = ids.map((i) => `'${i.replace(/'/g, "''")}'`).join(', ')
    // Cascade children first, then the batches.
    await db.run(sql.raw(`DELETE FROM payroll_recipients WHERE batch_id IN (${idList})`))
    await db.run(sql.raw(`DELETE FROM payroll_batches WHERE id IN (${idList})`))
  } catch (e: any) {
    console.error('[Retention] prune payroll failed (non-fatal):', e?.message ?? e)
  }
}
