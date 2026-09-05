import { db }  from '../db/client'
import { sql } from 'drizzle-orm'
import { notifyInvoiceReminder } from '../services/email/notifications'
import { sendInvoiceDueEmail } from '../services/email/invoiceRequest'

function parseRows(r: any): any[] {
  if (!r) return []
  if (Array.isArray((r as any).rows)) return (r as any).rows
  if (Array.isArray(r)) return r
  return []
}

export function startInvoiceReminders() {
  console.log('[InvoiceReminders] Started, checks every 6 hours')

  const check = async () => {
    const now      = Math.floor(Date.now() / 1000)
    const ago48h   = now - (48 * 3600)
    const ago96h   = now - (96 * 3600)

    try {
      // Find unpaid invoices created 48-96h ago that haven't been reminded yet
      const rows = await db.run(sql`
        SELECT id, memo_ref, creator_address, amount, currency, created_at
        FROM invoices
        WHERE status IN ('draft', 'sent')
          AND created_at BETWEEN ${ago96h} AND ${ago48h}
          AND reminder_sent_at IS NULL
        LIMIT 20
      `)

      const invoices = parseRows(rows)
      if (invoices.length === 0) return

      console.log(`[InvoiceReminders] Sending reminders for ${invoices.length} invoices`)

      for (const inv of invoices) {
        const invId = inv.id ?? inv[0]

        await notifyInvoiceReminder({
          creatorWallet: inv.creator_address ?? inv[2] ?? '',
          invoiceId:     invId,
          invoiceRef:    inv.memo_ref ?? inv[1] ?? '',
          amount:        Number(inv.amount ?? inv[3] ?? 0),
          currency:      inv.currency ?? inv[4] ?? '',
          createdAt:     Number(inv.created_at ?? inv[5] ?? 0),
        }).catch((err: any) => console.error('[InvoiceReminders] send failed:', err.message))

        // Mark as reminded
        await db.run(sql`UPDATE invoices SET reminder_sent_at = ${now} WHERE id = ${invId}`)
      }
    } catch (err: any) {
      console.error('[InvoiceReminders] error:', err.message)
    }

    // ── Due-date reminder to the RECIPIENT (invoices created with a due date
    //    that has now passed, still unpaid, that were emailed to someone, and
    //    not yet due-notified). Fires once per invoice via due_notified_at. ──
    try {
      const dueRows = await db.run(sql`
        SELECT id, memo_ref, creator_address, amount, currency, description,
               due_date, recipient_email
        FROM invoices
        WHERE status IN ('draft', 'sent')
          AND due_date IS NOT NULL
          AND due_date <= ${now}
          AND recipient_email IS NOT NULL
          AND due_notified_at IS NULL
        LIMIT 20
      `)
      const due = parseRows(dueRows)
      if (due.length > 0) {
        console.log(`[InvoiceReminders] Sending due-date reminders for ${due.length} invoices`)
        for (const inv of due) {
          const invId = inv.id ?? inv[0]
          await sendInvoiceDueEmail({
            to:            inv.recipient_email ?? inv[7],
            creatorWallet: inv.creator_address ?? inv[2] ?? '',
            memoRef:       inv.memo_ref ?? inv[1] ?? '',
            amount:        Number(inv.amount ?? inv[3] ?? 0),
            currency:      inv.currency ?? inv[4] ?? 'USDC',
            description:   inv.description ?? inv[5] ?? null,
            dueDate:       inv.due_date != null ? Number(inv.due_date ?? inv[6]) : null,
          }).catch((err: any) => console.error('[InvoiceReminders] due send failed:', err.message))
          await db.run(sql`UPDATE invoices SET due_notified_at = ${now} WHERE id = ${invId}`)
        }
      }
    } catch (err: any) {
      console.error('[InvoiceReminders] due-date error:', err.message)
    }
  }

  // Run once on startup after 30 seconds
  setTimeout(check, 30_000)
  // Then every 6 hours
  setInterval(check, 6 * 3600 * 1000)
}
