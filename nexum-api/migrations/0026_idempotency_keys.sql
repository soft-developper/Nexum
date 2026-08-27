-- ============================================================
-- 0026_idempotency_keys.sql
-- Phase 7 Hardening - request-level idempotency for money-moving endpoints.
--
-- Guards the tightest money path (POST /transfers, /transfers/cashout,
-- /payments) against double execution from a retried or double-tapped request.
-- A client sends an Idempotency-Key header; the first request for a given
-- (scope, key) runs and caches its response, and any replay returns that same
-- cached status + body instead of moving money again.
--
-- Mirrors the existing ramp_webhook_events dedupe pattern (a PRIMARY KEY plus
-- INSERT OR IGNORE). The (scope, key) composite lets the same client-generated
-- key be reused across different endpoints without colliding.
--
-- Lifecycle of a row:
--   status = 'in_progress'  reserved the instant a new key arrives; a concurrent
--                           replay while the handler runs gets 409 (no double
--                           execution window).
--   status = 'completed'    handler finished; response_status + response_body
--                           are the cached reply to replay.
-- A crashed handler leaves an 'in_progress' row; it is reclaimable after
-- IDEMPOTENCY_STALE_SECONDS (the middleware treats a stale reservation as
-- retryable rather than wedging the key forever).
--
-- No PII beyond what the endpoint already returns to the same caller: the
-- cached body is exactly the JSON that caller received.
-- ============================================================

CREATE TABLE IF NOT EXISTS idempotency_keys (
  scope            TEXT    NOT NULL,          -- e.g. 'transfers.create'
  idempotency_key  TEXT    NOT NULL,          -- client-supplied Idempotency-Key
  status           TEXT    NOT NULL,          -- 'in_progress' | 'completed'
  response_status  INTEGER,                   -- cached HTTP status (when completed)
  response_body    TEXT,                      -- cached JSON body (when completed)
  request_fingerprint TEXT,                   -- sha256 of the body, to catch key reuse with a different payload
  created_at       INTEGER NOT NULL,          -- unix seconds, reservation time
  completed_at     INTEGER,                   -- unix seconds, when cached
  PRIMARY KEY (scope, idempotency_key)
);

CREATE INDEX IF NOT EXISTS idx_idempotency_keys_created
  ON idempotency_keys (created_at);
