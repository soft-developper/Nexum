// __NEXUM_INVOICE_SCHEMA_SELF_HEAL__
// Boot-time self-heal for invoice payment columns.
//
// The pay endpoint writes payment_tx_hash and usdc_amount, but the original
// invoices table (migration 0003) never defined them. On Turso/libSQL an UPDATE
// referencing a missing column throws, which corrupted invoice pay state. This
// adds the columns at boot if absent. Idempotent. Mirrors
// ensureTransactionsSchema.ts / ensureProfileDetailsSchema.ts.

import { db } from '../db/client'
import { sql } from 'drizzle-orm'

const COLUMNS: Array<{ name: string; ddl: string }> = [
  { name: 'payment_tx_hash', ddl: 'ALTER TABLE invoices ADD COLUMN payment_tx_hash TEXT' },
  { name: 'usdc_amount',     ddl: 'ALTER TABLE invoices ADD COLUMN usdc_amount REAL' },
  { name: 'recipient_email', ddl: 'ALTER TABLE invoices ADD COLUMN recipient_email TEXT' },
  { name: 'email_note',      ddl: 'ALTER TABLE invoices ADD COLUMN email_note TEXT' },
  { name: 'due_notified_at', ddl: 'ALTER TABLE invoices ADD COLUMN due_notified_at INTEGER' },
]

async function existingColumns(): Promise<Set<string>> {
  try {
    const info: any = await db.run(sql`PRAGMA table_info(invoices)`)
    const rows: any[] = info?.rows ?? info ?? []
    return new Set(rows.map((c: any) => String(c.name ?? c[1])))
  } catch {
    return new Set()
  }
}

export async function ensureInvoiceSchema(): Promise<void> {
  try {
    const have = await existingColumns()
    const missing = COLUMNS.filter((c) => !have.has(c.name))
    if (missing.length === 0) {
      console.log('[Invoices] payment columns present')
      return
    }
    for (const col of missing) {
      try {
        await db.run(sql.raw(col.ddl))
        console.log(`[Invoices] \u2705 added invoices.${col.name} (self-heal)`)
      } catch (e: any) {
        if (/duplicate column/i.test(String(e?.message ?? ''))) {
          console.log(`[Invoices] invoices.${col.name} already present (concurrent add)`)
        } else {
          throw e
        }
      }
    }
  } catch (err: any) {
    console.error('[Invoices] \u26a0 ensureInvoiceSchema failed:', err?.message ?? err)
  }
}
