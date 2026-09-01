-- Invoice payment columns the original 0003 table omitted but the pay
-- endpoint writes. Mirrored by boot self-heal (ensureInvoiceSchema.ts).
-- per the Turso recorded-but-not-run gap.
ALTER TABLE invoices ADD COLUMN payment_tx_hash TEXT;
ALTER TABLE invoices ADD COLUMN usdc_amount REAL;
