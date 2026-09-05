// __NEXUM_INVOICE_REQUEST_EMAIL__
// Sends a payment-request email to an invoice recipient. Per product decision,
// the CONTENT is about the SENDER (their name, the amount, their note), NOT
// about Nexum - no Nexum branding, logo, or product copy in the body/subject.
//
// (The technical From domain is still the platform's Resend domain - we cannot
// send as the user's own email address without their domain's DKIM - but the
// recipient reads a personal, sender-centric message.)

import { db } from '../../db/client'
import { sql } from 'drizzle-orm'
import { sendEmail } from './client'

const APP_URL = process.env.APP_URL ?? 'https://nexumpay.xyz'

function esc(s: string): string {
  return String(s ?? '')
    .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
}

async function creatorName(wallet: string): Promise<string> {
  try {
    const rows = await db.run(sql`
      SELECT display_name, username FROM profiles
      WHERE LOWER(wallet_address) = LOWER(${wallet}) LIMIT 1`)
    const r: any[] = (rows as any)?.rows ?? rows ?? []
    const p = r[0]
    return p?.display_name || p?.username || 'Someone'
  } catch {
    return 'Someone'
  }
}

export async function sendInvoiceRequestEmail(params: {
  to:              string
  creatorWallet:   string
  memoRef:         string
  amount:          number
  currency:        string
  note?:           string | null
  description?:    string | null
  dueDate?:        number | null
}): Promise<{ success: boolean; error?: string }> {
  const name    = await creatorName(params.creatorWallet)
  const payLink = `${APP_URL}/pay/${params.memoRef}`
  const amountStr = `${params.amount.toLocaleString()} ${esc(params.currency)}`
  const due = params.dueDate
    ? new Date(params.dueDate * 1000).toLocaleDateString(undefined, { year: 'numeric', month: 'long', day: 'numeric' })
    : null

  // Subject + body are deliberately sender-centric. No Nexum wording.
  const subject = `${name} sent you a payment request`

  const html = `
<!DOCTYPE html>
<html>
  <body style="margin:0;padding:0;background:#f4f6fc;font-family:-apple-system,Segoe UI,Roboto,Helvetica,Arial,sans-serif;">
    <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#f4f6fc;padding:32px 0;">
      <tr><td align="center">
        <table role="presentation" width="480" cellpadding="0" cellspacing="0" style="background:#ffffff;border-radius:14px;overflow:hidden;border:1px solid #e6e9f2;">
          <tr><td style="padding:28px 32px 8px;">
            <p style="margin:0;font-size:15px;color:#0f1729;">Hi,</p>
            <p style="margin:14px 0 0;font-size:15px;line-height:1.6;color:#0f1729;">
              <strong>${esc(name)}</strong> has sent you a payment request${params.description ? ` for <strong>${esc(params.description)}</strong>` : ''}.
            </p>
          </td></tr>

          <tr><td style="padding:16px 32px 0;">
            <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#f7f9fd;border-radius:10px;">
              <tr><td style="padding:18px 20px;">
                <p style="margin:0;font-size:13px;color:#6b7280;">Amount due</p>
                <p style="margin:4px 0 0;font-size:26px;font-weight:700;color:#0f1729;">${amountStr}</p>
                ${due ? `<p style="margin:12px 0 0;font-size:13px;color:#6b7280;">Due by <strong style="color:#0f1729;">${esc(due)}</strong></p>` : ''}
                <p style="margin:12px 0 0;font-size:12px;color:#9aa3b2;">Reference: ${esc(params.memoRef)}</p>
              </td></tr>
            </table>
          </td></tr>

          ${params.note ? `
          <tr><td style="padding:16px 32px 0;">
            <p style="margin:0 0 4px;font-size:13px;color:#6b7280;">Note from ${esc(name)}:</p>
            <p style="margin:0;font-size:14px;line-height:1.6;color:#0f1729;white-space:pre-wrap;">${esc(params.note)}</p>
          </td></tr>` : ''}

          <tr><td style="padding:24px 32px 28px;" align="center">
            <a href="${payLink}" style="display:inline-block;background:#0e7c86;color:#ffffff;text-decoration:none;font-size:15px;font-weight:600;padding:13px 30px;border-radius:10px;">Pay now</a>
            <p style="margin:14px 0 0;font-size:12px;color:#9aa3b2;word-break:break-all;">Or open: ${esc(payLink)}</p>
          </td></tr>
        </table>
      </td></tr>
    </table>
  </body>
</html>`.trim()

  const result = await sendEmail({ to: params.to, subject, html })
  return { success: !!result.success, error: (result as any).error }
}

// __NEXUM_INVOICE_CANCELLED_EMAIL__
// Follow-up email when a payment request the recipient was emailed gets
// cancelled. Sender-centric, no Nexum branding.
export async function sendInvoiceCancelledEmail(params: {
  to:            string
  creatorWallet: string
  memoRef:       string
  amount:        number
  currency:      string
  description?:  string | null
}): Promise<{ success: boolean; error?: string }> {
  const name = await creatorName(params.creatorWallet)
  const amountStr = `${params.amount.toLocaleString()} ${esc(params.currency)}`
  const subject = `${name} cancelled a payment request`
  const html = `
<!DOCTYPE html>
<html>
  <body style="margin:0;padding:0;background:#f4f6fc;font-family:-apple-system,Segoe UI,Roboto,Helvetica,Arial,sans-serif;">
    <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#f4f6fc;padding:32px 0;">
      <tr><td align="center">
        <table role="presentation" width="480" cellpadding="0" cellspacing="0" style="background:#ffffff;border-radius:14px;overflow:hidden;border:1px solid #e6e9f2;">
          <tr><td style="padding:28px 32px;">
            <p style="margin:0;font-size:15px;color:#0f1729;">Hi,</p>
            <p style="margin:14px 0 0;font-size:15px;line-height:1.6;color:#0f1729;">
              <strong>${esc(name)}</strong> has cancelled the payment request${params.description ? ` for <strong>${esc(params.description)}</strong>` : ''}${` (${amountStr})`}.
            </p>
            <p style="margin:14px 0 0;font-size:14px;line-height:1.6;color:#6b7280;">
              No payment is needed. If you've already paid or think this is a mistake, please reach out to ${esc(name)} directly.
            </p>
            <p style="margin:18px 0 0;font-size:12px;color:#9aa3b2;">Reference: ${esc(params.memoRef)}</p>
          </td></tr>
        </table>
      </td></tr>
    </table>
  </body>
</html>`.trim()
  const result = await sendEmail({ to: params.to, subject, html })
  return { success: !!result.success, error: (result as any).error }
}

// __NEXUM_INVOICE_DUE_EMAIL__
// Reminder email to the recipient when an invoice's due date is reached and it
// is still unpaid. Sender-centric, no Nexum branding.
export async function sendInvoiceDueEmail(params: {
  to:            string
  creatorWallet: string
  memoRef:       string
  amount:        number
  currency:      string
  description?:  string | null
  dueDate?:      number | null
}): Promise<{ success: boolean; error?: string }> {
  const name = await creatorName(params.creatorWallet)
  const payLink = `${APP_URL}/pay/${params.memoRef}`
  const amountStr = `${params.amount.toLocaleString()} ${esc(params.currency)}`
  const due = params.dueDate
    ? new Date(params.dueDate * 1000).toLocaleDateString(undefined, { year: 'numeric', month: 'long', day: 'numeric' })
    : null
  const subject = `Reminder: payment request from ${name} is now due`
  const html = `
<!DOCTYPE html>
<html>
  <body style="margin:0;padding:0;background:#f4f6fc;font-family:-apple-system,Segoe UI,Roboto,Helvetica,Arial,sans-serif;">
    <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#f4f6fc;padding:32px 0;">
      <tr><td align="center">
        <table role="presentation" width="480" cellpadding="0" cellspacing="0" style="background:#ffffff;border-radius:14px;overflow:hidden;border:1px solid #e6e9f2;">
          <tr><td style="padding:28px 32px 8px;">
            <p style="margin:0;font-size:15px;color:#0f1729;">Hi,</p>
            <p style="margin:14px 0 0;font-size:15px;line-height:1.6;color:#0f1729;">
              This is a friendly reminder that your payment request from <strong>${esc(name)}</strong>${params.description ? ` for <strong>${esc(params.description)}</strong>` : ''} is now due${due ? ` (was due ${esc(due)})` : ''}.
            </p>
          </td></tr>
          <tr><td style="padding:16px 32px 0;">
            <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#f7f9fd;border-radius:10px;">
              <tr><td style="padding:18px 20px;">
                <p style="margin:0;font-size:13px;color:#6b7280;">Amount due</p>
                <p style="margin:4px 0 0;font-size:26px;font-weight:700;color:#0f1729;">${amountStr}</p>
                <p style="margin:12px 0 0;font-size:12px;color:#9aa3b2;">Reference: ${esc(params.memoRef)}</p>
              </td></tr>
            </table>
          </td></tr>
          <tr><td style="padding:24px 32px 28px;" align="center">
            <a href="${payLink}" style="display:inline-block;background:#0e7c86;color:#ffffff;text-decoration:none;font-size:15px;font-weight:600;padding:13px 30px;border-radius:10px;">Pay now</a>
            <p style="margin:14px 0 0;font-size:12px;color:#9aa3b2;word-break:break-all;">Or open: ${esc(payLink)}</p>
          </td></tr>
        </table>
      </td></tr>
    </table>
  </body>
</html>`.trim()
  const result = await sendEmail({ to: params.to, subject, html })
  return { success: !!result.success, error: (result as any).error }
}
