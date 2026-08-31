-- ============================================================
-- Part 2: sessions/devices - store an approximate city per session
-- for the "devices & sessions" list. Resolved once at login from the
-- client IP (best-effort; null when unknown or private/local).
--
-- Mirrored by boot self-heal (services/ensureSessionLocationSchema.ts)
-- because prod Turso has a confirmed recorded-but-not-run gap.
-- ============================================================

ALTER TABLE account_sessions ADD COLUMN location_city TEXT;
