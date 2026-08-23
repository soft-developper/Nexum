#!/usr/bin/env bash
# Read-only probe — prints the exact current shapes Part 4 must slot against.
# Makes NO changes. Run from ~/AfriFX and paste the whole output back.
set -euo pipefail
API=nexum-api/src
echo "════════ 1) webhooks.ts — exports + drain handling present? ════════"
grep -n "export function\|export interface\|liquidation\|extractDrainDetail\|event_category\|event_object" $API/services/bridgexyz/webhooks.ts | head -40
echo ""
echo "════════ 2) repository.ts — offramp + notification helpers present? ════════"
grep -n "getLiquidationAddressByAddress\|getLiquidationAddressRowById\|ramp_drain_events\|upsertDrainEvent\|claimDrainNotification\|getAccountContact\|ramp_deposit_notifications\|claimDepositNotification" $API/services/bridgexyz/repository.ts | head -30
echo ""
echo "════════ 3) transfers.ts — webhook drain branch present? ════════"
grep -n "extractDrainDetail\|liquidation\|upsertDrainEvent\|maybeSendPayoutEmail\|extractActivityDetail\|maybeSendDepositEmail" $API/routes/transfers.ts | head
echo ""
echo "════════ 4) templates.ts — deposit/payout email templates present? ════════"
grep -n "depositLandedEmail\|depositReturnedEmail\|payoutSentEmail\|payoutPaidEmail\|payoutReturnedEmail" $API/services/email/templates.ts | head
echo ""
echo "════════ 5) migrations present (highest number = latest applied locally) ════════"
ls nexum-api/migrations/ | tail -8
echo ""
echo "════════ 6) ramp.ts — drains endpoint + offramp routes present? ════════"
grep -n "liquidation-address/:currency/drains\|liquidation-address\b\|external-account" $API/routes/ramp.ts | head
echo ""
echo "════════ 7) drains endpoint currently poll-only or merges webhook mirror? ════════"
grep -n "getDrainEventsByLiquidationAddress\|getLiquidationAddressDrains\|source:" $API/routes/ramp.ts | head
echo "DONE — paste everything above."
