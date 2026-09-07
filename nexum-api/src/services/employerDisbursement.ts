// __NEXUM_EMPLOYER_DISBURSEMENT_WALLETS__
// Per-employer payroll disbursement wallets.
//
// FIXES: payroll previously disbursed from ONE shared developer-controlled
// wallet (PAYROLL_DISBURSEMENT_WALLET_ID), so every employer's top-ups pooled
// together and any user could spend the shared balance. Now each employer has
// their OWN Circle developer-controlled wallet - funds are isolated per user.
//
// These are Circle DEVELOPER-CONTROLLED wallets: Circle's MPC holds the key
// material; we hold only the wallet id and authorize signing via our entity
// secret through Circle's API. Backend-signed, headless (no per-recipient user
// PIN), which is why payroll can pay a batch without the employer signing each
// transfer - and why it must be developer-controlled, not user-controlled.

import { db } from '../db/client'
import { sql } from 'drizzle-orm'
import { provisionDisbursementWallet } from './platformDisbursement'

function parseRows(r: any): any[] {
  if (!r) return []
  if (Array.isArray((r as any).rows)) return (r as any).rows
  if (Array.isArray(r)) return r
  return []
}

// Boot-time self-heal for the mapping table (Turso records-but-doesn't-run
// guard). Idempotent. Mirrors the other ensure* services.
export async function ensureEmployerWalletSchema(): Promise<void> {
  try {
    await db.run(sql`
      CREATE TABLE IF NOT EXISTS payroll_disbursement_wallets (
        account_id     TEXT PRIMARY KEY,
        wallet_id      TEXT NOT NULL,
        wallet_address TEXT NOT NULL,
        blockchain     TEXT,
        created_at     INTEGER NOT NULL
      )`)
    console.log('[Payroll] employer disbursement wallet table ready')
  } catch (err: any) {
    console.error('[Payroll] \u26a0 ensureEmployerWalletSchema failed:', err?.message ?? err)
  }
}

export interface EmployerWallet {
  walletId: string
  address:  string
}

/**
 * Return the employer's own disbursement wallet, creating it on first use.
 *
 * Idempotent + race-safe: the row is keyed by account_id (PK). If two calls
 * race, the second's INSERT is ignored and we re-read the winner's row, so an
 * employer can never end up with two wallets. A provisioning failure throws (no
 * partial row is written).
 */
export async function getOrCreateEmployerWallet(accountId: string): Promise<EmployerWallet> {
  if (!accountId) throw new Error('accountId required for disbursement wallet')

  // Fast path: already provisioned.
  const existing = parseRows(await db.run(sql`
    SELECT wallet_id, wallet_address FROM payroll_disbursement_wallets
    WHERE account_id = ${accountId} LIMIT 1`))[0]
  if (existing) {
    return {
      walletId: String(existing.wallet_id ?? existing[0]),
      address:  String(existing.wallet_address ?? existing[1]),
    }
  }

  // Provision a fresh Circle developer-controlled wallet for this employer.
  const w = await provisionDisbursementWallet(`Nexum Payroll - ${accountId}`)
  const now = Math.floor(Date.now() / 1000)

  // INSERT OR IGNORE so a concurrent provision can't create a duplicate PK row;
  // whichever landed first wins, and we re-read it below.
  await db.run(sql`
    INSERT OR IGNORE INTO payroll_disbursement_wallets
      (account_id, wallet_id, wallet_address, blockchain, created_at)
    VALUES (${accountId}, ${w.id}, ${w.address}, ${w.blockchain}, ${now})`)

  const row = parseRows(await db.run(sql`
    SELECT wallet_id, wallet_address FROM payroll_disbursement_wallets
    WHERE account_id = ${accountId} LIMIT 1`))[0]
  if (!row) throw new Error('Failed to persist employer disbursement wallet')

  return {
    walletId: String(row.wallet_id ?? row[0]),
    address:  String(row.wallet_address ?? row[1]),
  }
}

/** Read-only lookup (no create). Null if the employer has no wallet yet. */
export async function getEmployerWallet(accountId: string): Promise<EmployerWallet | null> {
  if (!accountId) return null
  const row = parseRows(await db.run(sql`
    SELECT wallet_id, wallet_address FROM payroll_disbursement_wallets
    WHERE account_id = ${accountId} LIMIT 1`))[0]
  if (!row) return null
  return {
    walletId: String(row.wallet_id ?? row[0]),
    address:  String(row.wallet_address ?? row[1]),
  }
}
