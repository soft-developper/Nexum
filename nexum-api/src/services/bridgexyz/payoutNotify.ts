// ============================================================
// Payout email notifications (Phase 5 Part 4) — off-ramp mirror of
// depositNotify.ts.
//
// Called from the Bridge webhook handler after a verified liquidation_address
// drain event is mirrored. Fires a branded email on terminal drain states:
//   • payment_processed                       → "withdrawal paid" (fiat sent)
//   • returned / refunded                     → "withdrawal returned"
//   • undeliverable / error / canceled        → "withdrawal failed" (needs support)
//
// Every send is guarded by claimDrainNotification() so a webhook redelivery (or
// the same event via poll) can only email once per (drain, kind). Best-effort:
// any failure is logged and swallowed so it never breaks webhook processing.
// ============================================================

import { sendEmail } from '../email/client'
import { payoutPaidEmail, payoutReturnedEmail } from '../email/templates'
import {
  getAccountContact, getLiquidationAddressRowById, claimDrainNotification,
} from './repository'
import type { DrainDetail } from './webhooks'

type Kind = 'paid' | 'returned' | 'returned_failed'
function kindForState(state: string | null): Kind | null {
  switch (state) {
    case 'payment_processed': return 'paid'
    case 'returned':
    case 'refunded':          return 'returned'
    case 'undeliverable':
    case 'error':
    case 'canceled':          return 'returned_failed'
    default:                  return null
  }
}

export async function maybeSendPayoutEmail(detail: DrainDetail): Promise<void> {
  try {
    const kind = kindForState(detail.state)
    if (!kind) return // not a terminal state we notify on
    if (!detail.liquidationAddressId) return

    // Claim first — cheap guard, avoids lookups for a dupe.
    const won = await claimDrainNotification({
      liquidationAddressId: detail.liquidationAddressId,
      drainId:              detail.drainId,
      kind,
    })
    if (!won) return

    const laRow = await getLiquidationAddressRowById(detail.liquidationAddressId)
    if (!laRow) { console.warn('[PayoutNotify] no LA row for', detail.liquidationAddressId); return }
    const contact = await getAccountContact(laRow.account_id)
    if (!contact?.email) { console.warn('[PayoutNotify] no email for account', laRow.account_id); return }

    const displayName = contact.display_name ?? 'there'
    const currency    = detail.currency ?? laRow.destination_currency ?? undefined
    const rail        = laRow.destination_payment_rail ?? undefined

    let tmpl: { subject: string; html: string }
    if (kind === 'paid') {
      tmpl = payoutPaidEmail({
        displayName,
        amount:    detail.amount ?? '—',
        currency,
        rail,
        reference: detail.destinationTxHash ?? undefined,
      })
    } else {
      tmpl = payoutReturnedEmail({
        displayName,
        amount:   detail.amount ?? undefined,
        currency,
        failed:   kind === 'returned_failed',
      })
    }

    const res = await sendEmail({ to: contact.email, subject: tmpl.subject, html: tmpl.html })
    if (!res.success) console.error('[PayoutNotify] send failed:', res.error)
  } catch (err: any) {
    console.error('[PayoutNotify] error:', err?.message)
  }
}
