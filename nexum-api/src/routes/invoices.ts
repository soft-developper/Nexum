import { notifyInvoicePaid, notifyPaymentReceipt } from '../services/email/notifications'
import { sendInvoiceRequestEmail } from '../services/email/invoiceRequest'
import { Router }     from 'express'
import { db }         from '../db/client'
import { sql }        from 'drizzle-orm'
import { randomUUID } from 'crypto'

const router = Router()

function parseRows(r: any): any[] {
  if (!r) return []
  if (Array.isArray((r as any).rows)) return (r as any).rows
  if (Array.isArray(r)) return r
  return []
}

function normInvoice(r: any) {
  if (Array.isArray(r)) return {
    id: r[0], creator_address: r[1], payer_address: r[2],
    amount: Number(r[3]), currency: r[4], description: r[5],
    notes: r[6], due_date: r[7] ? Number(r[7]) : null,
    memo_ref: r[8], status: r[9], payment_tx_hash: r[10],
    paid_at: r[11] ? Number(r[11]) : null,
    created_at: Number(r[12]), updated_at: Number(r[13]),
  }
  return { ...r, amount: Number(r.amount) }
}

function genRef(prefix: string): string {
  const date = new Date().toISOString().slice(0,10).replace(/-/g,'')
  const rand = Math.random().toString(36).slice(2,6).toUpperCase()
  return `${prefix}-${date}-${rand}`
}

// GET /invoices?wallet=0x invoices created by or addressed to wallet
router.get('/', async (req, res) => {
  const wallet = (req.query.wallet as string)?.toLowerCase()
  if (!wallet) return res.status(400).json({ error: 'wallet required' })
  try {
    const rows = await db.run(
      sql`SELECT * FROM invoices
          WHERE LOWER(creator_address) = ${wallet}
             OR LOWER(payer_address)   = ${wallet}
          ORDER BY created_at DESC LIMIT 100`
    )
    res.json(parseRows(rows).map(normInvoice))
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// GET /invoices/ref/:ref by memo ref (for payment page)
router.get('/ref/:ref', async (req, res) => {
  try {
    const rows = await db.run(
      sql`SELECT i.*,
                 p.username     AS creator_username,
                 p.display_name AS creator_display_name
          FROM invoices i
          LEFT JOIN profiles p
            ON LOWER(p.wallet_address) = LOWER(i.creator_address)
          WHERE i.memo_ref = ${req.params.ref} LIMIT 1`
    )
    const r = parseRows(rows)
    if (!r.length) return res.status(404).json({ error: 'Invoice not found' })
    const row: any = r[0]
    res.json({
      ...normInvoice(row),
      creator_username:     row.creator_username ?? null,
      creator_display_name: row.creator_display_name ?? null,
    })
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// GET /invoices/:id
router.get('/:id', async (req, res) => {
  try {
    const rows = await db.run(
      sql`SELECT * FROM invoices WHERE id = ${req.params.id} LIMIT 1`
    )
    const r = parseRows(rows)
    if (!r.length) return res.status(404).json({ error: 'Invoice not found' })
    res.json(normInvoice(r[0]))
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// POST /invoices create invoice
router.post('/', async (req, res) => {
  const { walletAddress, amount, currency = 'USDC', description, notes, dueDate, payerAddress, recipientEmail, emailNote } = req.body
  if (!walletAddress || !amount) return res.status(400).json({ error: 'walletAddress and amount required' })

  const id      = randomUUID()
  const memoRef = genRef('INV')
  const now     = Math.floor(Date.now() / 1000)

  try {
    await db.run(
      sql`INSERT INTO invoices
          (id, creator_address, payer_address, amount, currency,
           description, notes, due_date, memo_ref, status, created_at, updated_at)
          VALUES
          (${id}, ${walletAddress.toLowerCase()},
           ${payerAddress?.toLowerCase() ?? null},
           ${Number(amount)}, ${currency},
           ${description ?? null}, ${notes ?? null},
           ${dueDate ?? null}, ${memoRef}, 'draft', ${now}, ${now})`
    )

    // Optional: email the payment request to a recipient. Sender-centric content
    // (no Nexum branding). NON-FATAL - a mail failure must not fail invoice
    // creation; we just report emailed:false.
    let emailed = false
    const cleanEmail = typeof recipientEmail === 'string' ? recipientEmail.trim() : ''
    if (cleanEmail && /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(cleanEmail)) {
      try {
        const r = await sendInvoiceRequestEmail({
          to:            cleanEmail,
          creatorWallet: walletAddress,
          memoRef,
          amount:        Number(amount),
          currency,
          note:          typeof emailNote === 'string' ? emailNote.trim() || null : null,
          description:   description ?? null,
          dueDate:       dueDate ?? null,
        })
        emailed = r.success
      } catch (e: any) {
        console.error('[Invoice] request email failed (non-fatal):', e?.message ?? e)
      }
    }

    res.status(201).json({ id, memoRef, emailed })
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// PATCH /invoices/:id/status update status (send, pay, cancel)
router.patch('/:id/status', async (req, res) => {
  const { status, paymentTxHash, paidAt } = req.body
  const now = Math.floor(Date.now() / 1000)
  try {
    await db.run(
      sql`UPDATE invoices SET
            status          = ${status},
            payment_tx_hash = COALESCE(${paymentTxHash ?? null}, payment_tx_hash),
            paid_at         = COALESCE(${paidAt ?? null}, paid_at),
            updated_at      = ${now}
          WHERE id = ${req.params.id}`
    )
    res.json({ success: true })
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// PATCH /invoices/ref/:ref/pay mark paid or failed by memo ref
// Called by frontend after on-chain confirmation with receipt.status
router.patch('/ref/:ref/pay', async (req, res) => {
  const { txHash, payerAddress, status: txStatus, usdcAmount } = req.body
  const now = Math.floor(Date.now() / 1000)

  try {
    // Read current state first. Payment status is MONOTONIC: once an invoice is
    // 'paid' it can never be moved back to 'sent'/'failed' by a later PATCH.
    // This is what makes the endpoint idempotent and preserves single-payment
    // integrity even if the client fires a stray 'failed' after a success.
    const curRows = parseRows(await db.run(
      sql`SELECT id, creator_address, memo_ref, currency, amount, usdc_amount, status, paid_at
          FROM invoices WHERE memo_ref = ${req.params.ref} LIMIT 1`))
    const cur = curRows[0]
    if (!cur) return res.status(404).json({ error: 'Invoice not found' })

    const alreadyPaid = cur.status === 'paid'
    const isFailure   = txStatus === 'failed'

    // A failure report NEVER downgrades an already-paid invoice, and never
    // marks an invoice failed on its own - we simply keep the prior status.
    // (On-chain revert is surfaced to the payer in the UI; the invoice stays
    // 'sent' so it can be retried, but a real success is never undone.)
    if (alreadyPaid) {
      // Idempotent no-op: record the tx hash if we somehow lacked one, but do
      // NOT change status, paid_at, or re-fire the paid email.
      if (txHash) {
        await db.run(sql`UPDATE invoices SET
          payment_tx_hash = COALESCE(payment_tx_hash, ${txHash}),
          updated_at = ${now} WHERE memo_ref = ${req.params.ref}`)
      }
      return res.json({ success: true, invoiceStatus: 'paid', idempotent: true })
    }

    if (isFailure) {
      // Record the attempt without flipping to 'paid'. Keep status as-is
      // (pending/sent). Store the failed tx hash for debugging only.
      await db.run(sql`UPDATE invoices SET
        payment_tx_hash = COALESCE(${txHash ?? null}, payment_tx_hash),
        updated_at = ${now} WHERE memo_ref = ${req.params.ref}`)
      return res.json({ success: true, invoiceStatus: cur.status ?? 'sent' })
    }

    // ── Genuine success transition: pending/sent -> paid ──
    await db.run(
      sql`UPDATE invoices SET
            status          = 'paid',
            payment_tx_hash = COALESCE(${txHash ?? null}, payment_tx_hash),
            payer_address   = COALESCE(${payerAddress?.toLowerCase() ?? null}, payer_address),
            usdc_amount     = COALESCE(${usdcAmount ?? null}, usdc_amount),
            paid_at         = ${now},
            updated_at      = ${now}
          WHERE memo_ref = ${req.params.ref}`
    )

    // Email fires exactly once, on the real transition (guarded above by the
    // alreadyPaid early-return, so repeat calls never re-send).
    try {
      const _inv = parseRows(await db.run(sql`SELECT id, creator_address, memo_ref, currency, amount, usdc_amount FROM invoices WHERE memo_ref = ${req.params.ref} LIMIT 1`))[0]
      if (_inv) {
        notifyInvoicePaid({
          creatorWallet: _inv.creator_address ?? '',
          payerAddress:  payerAddress ?? '',
          invoiceRef:    _inv.memo_ref ?? req.params.ref,
          usdcAmount:    Number(_inv.usdc_amount ?? usdcAmount ?? 0),
          localAmount:   _inv.amount ? Number(_inv.amount) : undefined,
          localCcy:      _inv.currency ?? undefined,
          invoiceId:     _inv.id ?? '',
          txHash:        txHash ?? '',
        }).catch((e: any) => console.error('[Notify] invoice_paid:', e.message))
      }
    } catch (err: any) { console.error('[Notify] invoice hook error:', err.message) }

    res.json({ success: true, invoiceStatus: 'paid' })
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

// DELETE /invoices/:id cancel/delete draft
router.delete('/:id', async (req, res) => {
  try {
    await db.run(
      sql`UPDATE invoices SET status = 'cancelled', updated_at = ${Math.floor(Date.now()/1000)}
          WHERE id = ${req.params.id} AND status IN ('draft','sent')`
    )
    res.json({ success: true })
  } catch (err: any) { res.status(500).json({ error: err.message }) }
})

export default router
