#!/usr/bin/env bash
# Read-only — prints the exact code blocks Part 4 edits must match. No changes.
set -euo pipefail
API=nexum-api/src
echo "════════ A) transfers.ts webhook handler, lines 325–360 (the deposit branch I extend) ════════"
sed -n '325,360p' $API/routes/transfers.ts
echo ""
echo "════════ B) transfers.ts imports, lines 20–35 ════════"
sed -n '20,35p' $API/routes/transfers.ts
echo ""
echo "════════ C) depositLandedEmail + depositReturnedEmail full (templates.ts 778–870) ════════"
sed -n '778,875p' $API/services/email/templates.ts
echo ""
echo "════════ D) depositNotify.ts full (the file I mirror as payoutNotify.ts) ════════"
cat $API/services/bridgexyz/depositNotify.ts
echo ""
echo "════════ E) repository: claimDepositNotification + getAccountContact + getLiquidationAddressByAddress bodies ════════"
sed -n '300,360p' $API/services/bridgexyz/repository.ts
sed -n '470,500p' $API/services/bridgexyz/repository.ts
echo ""
echo "════════ F) ramp.ts drains endpoint full (760–800) ════════"
sed -n '760,800p' $API/routes/ramp.ts
echo ""
echo "════════ G) 0021 notifications migration (shape to mirror for drains) ════════"
cat nexum-api/migrations/0021_ramp_deposit_notifications.sql
echo ""
echo "════════ H) 0020 webhook/deposit events migration (ramp_deposit_events shape) ════════"
cat nexum-api/migrations/0020_ramp_webhook_events.sql
echo "DONE"
