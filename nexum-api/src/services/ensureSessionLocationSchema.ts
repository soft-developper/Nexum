// __NEXUM_SESSION_LOCATION_SELF_HEAL__
// Boot-time self-heal for account_sessions.location_city.
//
// WHY: prod Turso has a confirmed "recorded-but-not-run" migration gap, so a
// new column is not trusted to a migration file alone. This adds the column at
// boot if missing. Idempotent. Mirrors ensureProfileDetailsSchema.ts.

import { db } from '../db/client'
import { sql } from 'drizzle-orm'

async function hasColumn(table: string, col: string): Promise<boolean> {
  try {
    const info: any = await db.run(sql.raw(`PRAGMA table_info(${table})`))
    const rows: any[] = info?.rows ?? info ?? []
    return rows.some((c: any) => String(c.name ?? c[1]) === col)
  } catch {
    return false
  }
}

export async function ensureSessionLocationSchema(): Promise<void> {
  try {
    if (await hasColumn('account_sessions', 'location_city')) {
      console.log('[Sessions] location_city present')
      return
    }
    try {
      await db.run(sql.raw(`ALTER TABLE account_sessions ADD COLUMN location_city TEXT`))
      console.log('[Sessions] \u2705 added account_sessions.location_city (self-heal)')
    } catch (e: any) {
      if (/duplicate column/i.test(String(e?.message ?? ''))) {
        console.log('[Sessions] location_city already present (concurrent add)')
      } else {
        throw e
      }
    }
  } catch (err: any) {
    console.error('[Sessions] \u26a0 ensureSessionLocationSchema failed:', err?.message ?? err)
  }
}
