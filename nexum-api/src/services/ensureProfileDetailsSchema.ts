// ============================================================
// __NEXUM_PROFILE_DETAILS_SELF_HEAL__
// Boot-time self-heal for the profiles detail columns
// (date_of_birth, nationality, gender, location).
//
// WHY: the prod Turso DB has a confirmed "recorded-but-not-run" gap -
// migrations 0022/0023/0024 were logged as applied while their ALTER /
// INSERT never actually executed. A migration file alone is therefore not
// trusted for a brand-new column. This service adds each missing column at
// boot via ALTER TABLE, guarded so it is a no-op when the column already
// exists. Independent of the migration runner. Idempotent. Mirrors
// ensureTransactionsSchema.ts.
// ============================================================

import { db } from '../db/client'
import { sql } from 'drizzle-orm'

const COLUMNS = ['date_of_birth', 'nationality', 'gender', 'location'] as const

/** Names of profiles columns that exist right now. */
async function existingColumns(): Promise<Set<string>> {
  try {
    const info: any = await db.run(sql`PRAGMA table_info(profiles)`)
    const rows: any[] = info?.rows ?? info ?? []
    return new Set(rows.map((c: any) => String(c.name ?? c[1])))
  } catch {
    return new Set()
  }
}

/**
 * Ensure the four profile detail columns exist. Called once at boot, before
 * the server accepts requests. Safe to run every boot: existing columns are
 * skipped; a concurrent add that wins the race is swallowed.
 */
export async function ensureProfileDetailsSchema(): Promise<void> {
  try {
    const have = await existingColumns()
    const missing = COLUMNS.filter((c) => !have.has(c))
    if (missing.length === 0) {
      console.log('[Profile] detail columns present')
      return
    }
    for (const col of missing) {
      try {
        // Column name is from a fixed allow-list above, never user input.
        await db.run(sql.raw(`ALTER TABLE profiles ADD COLUMN ${col} TEXT`))
        console.log(`[Profile] \u2705 added profiles.${col} (self-heal)`)
      } catch (e: any) {
        if (/duplicate column/i.test(String(e?.message ?? ''))) {
          console.log(`[Profile] profiles.${col} already present (concurrent add)`)
        } else {
          throw e
        }
      }
    }
  } catch (err: any) {
    // Never crash boot over this - reads degrade gracefully to null fields.
    console.error('[Profile] \u26a0 ensureProfileDetailsSchema failed:', err?.message ?? err)
  }
}
