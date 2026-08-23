-- ============================================================
-- 0025_ramp_drain_events.sql
-- Bridge.xyz OFF-ramp, Phase 5 Part 4 — drain webhooks + reconciliation.
--
-- Mirrors the on-ramp deposit tables (0020/0021) for the off-ramp direction:
--   ramp_drain_events        — a small MIRROR of liquidation-address drain
--                              activity, so the /ramp withdrawal tracker can
--                              read the latest state instantly instead of
--                              waiting on its poll of Bridge's /drains. The
--                              poll REMAINS ground truth; this is an optimisation.
--   ramp_drain_notifications — dedup guard so each (drain, kind) emails at most
--                              once, even on webhook redelivery. kind ∈
--                              ('sent','paid','returned','returned_failed').
--
-- No PII: drain amounts + Bridge ids only, same data the tracker already
-- fetches from /drains. ramp_webhook_events (from 0020) is reused as the
-- shared idempotency log — no new audit table needed.
-- ============================================================

CREATE TABLE IF NOT EXISTS ramp_drain_events (
  id                     TEXT PRIMARY KEY,       -- our uuid
  provider               TEXT NOT NULL DEFAULT 'bridgexyz',
  liquidation_address_id TEXT,                   -- Bridge liquidation address id
  drain_id               TEXT,                   -- Bridge drain id (groups a drain's events)
  event_id               TEXT,                   -- source webhook event_id (nullable if from poll)
  state                  TEXT,                   -- funds_received | payment_submitted | payment_processed | undeliverable | returned | refunded | error | canceled
  currency               TEXT,                   -- destination fiat currency
  amount                 TEXT,
  deposit_tx_hash        TEXT,                   -- on-chain tx that funded the drain
  destination_tx_hash    TEXT,                   -- payout reference (fiat side), when present
  source                 TEXT NOT NULL DEFAULT 'webhook',  -- 'webhook' | 'poll'
  created_at             INTEGER NOT NULL,
  -- One row per (liquidation address, drain, state): a webhook and a later poll
  -- of the same event collapse instead of duplicating.
  UNIQUE (liquidation_address_id, drain_id, state)
);

CREATE INDEX IF NOT EXISTS idx_ramp_drain_events_la
  ON ramp_drain_events (liquidation_address_id);
CREATE INDEX IF NOT EXISTS idx_ramp_drain_events_drain
  ON ramp_drain_events (drain_id);

CREATE TABLE IF NOT EXISTS ramp_drain_notifications (
  id                     TEXT PRIMARY KEY,       -- our uuid
  liquidation_address_id TEXT,
  drain_id               TEXT,
  kind                   TEXT NOT NULL,          -- sent | paid | returned | returned_failed
  sent_at                INTEGER NOT NULL,
  UNIQUE (liquidation_address_id, drain_id, kind)
);

CREATE INDEX IF NOT EXISTS idx_ramp_drain_notifications_drain
  ON ramp_drain_notifications (drain_id);
