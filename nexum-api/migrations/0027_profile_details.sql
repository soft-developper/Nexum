-- ============================================================
-- Part 1: profile detail fields (DOB, nationality, gender, location).
--
-- These are OWNER-ONLY profile fields. They are added to `profiles`
-- (the wallet-era profile table the profile UI + /profile API use),
-- NOT to `accounts` (the session table).
--
-- Privacy: the public profile routes strip these four fields; only the
-- authenticated owner reads them via GET /profile/me.
--
-- age is NOT stored - it is derived from date_of_birth on read, so it
-- can never drift out of sync with the birth date.
--
-- NOTE: the prod Turso DB has a confirmed "recorded-but-not-run" gap
-- (migrations 0022/0023/0024 logged as applied while their DDL never
-- executed). This migration is therefore MIRRORED by a boot-time
-- self-heal (services/ensureProfileDetailsSchema.ts) which adds any
-- missing column at startup. The migration remains the source of truth
-- for a clean DB; the self-heal covers the prod gap.
-- ============================================================

ALTER TABLE profiles ADD COLUMN date_of_birth TEXT;
ALTER TABLE profiles ADD COLUMN nationality   TEXT;
ALTER TABLE profiles ADD COLUMN gender        TEXT;
ALTER TABLE profiles ADD COLUMN location      TEXT;
