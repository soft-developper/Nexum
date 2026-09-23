#!/usr/bin/env bash
# ============================================================================
# nexum-fees-remove-bridge-protocol.sh   (API-ONLY, v2 anchored-edit delivery)
#
# FIX: the admin Platform-fees dashboard was throwing
#   "The contract function feesAccrued reverted ... feesAccrued(uint8) args:(2)"
#
# CAUSE: the deployed vault holding the real (withdrawable) P2P + invoice fees
# is a 2-protocol contract: FeeProtocol { P2P, Invoice }. A later bridge-fee
# addition extended the code's enum + the API's FEE_PROTOCOLS loop to include
# Bridge (index 2). Bridge fees were never successfully collectable on Arc's
# single-chain model, so no bridge protocol exists on the live contract, and
# asking it for feesAccrued(2) reverts - taking the whole dashboard down.
#
# FIX (matches reality): drop the Bridge row from FEE_PROTOCOLS in
# nexum-api/src/routes/adminManage.ts. That single array drives BOTH:
#   - GET  /admin/manage/fees        (no longer reads feesAccrued(2))
#   - POST /admin/manage/fees/withdraw (find() can no longer target bridge)
# The web page renders data.protocols.map(...) so the Bridge card disappears
# automatically - no web change needed. totalFeesAvailable() is unaffected
# (the deployed contract's own function only sums the protocols it has).
#
# Leaves P2P + Invoice fees fully intact and withdrawable on the SAME contract.
# No redeploy. FeeProtocol.Bridge stays defined in the enum (harmless, unused
# here); P2P/Invoice keep the FeeProtocol import valid.
#
# v2: exact anchored single-replacement (assert count==1), marker-guarded
# backup-once, idempotent, --revert (newest backup, byte-identical). No
# em-dashes. Run from repo root (~/AfriFX) or anywhere above nexum-api.
# ============================================================================
set -euo pipefail

STAMP="$(date +%Y%m%d-%H%M%S)"
MARK="__NEXUM_FEES_NO_BRIDGE__"

# ---- locate repo root (dir containing nexum-api) --------------------------
ROOT=""
for cand in "." ".." "$HOME/AfriFX" "$(pwd)"; do
  if [ -d "$cand/nexum-api" ]; then ROOT="$(cd "$cand" && pwd)"; break; fi
done
if [ -z "$ROOT" ]; then
  hit="$(find . -maxdepth 3 -type d -name nexum-api 2>/dev/null | head -1 || true)"
  [ -n "$hit" ] && ROOT="$(cd "$(dirname "$hit")" && pwd)"
fi
[ -z "$ROOT" ] && { echo "ERROR: could not find nexum-api from $(pwd)"; exit 1; }
API="$ROOT/nexum-api"
FILE="$API/src/routes/adminManage.ts"
echo "repo root : $ROOT"
[ -f "$FILE" ] || { echo "ERROR: missing $FILE"; exit 1; }

# ---- --revert -------------------------------------------------------------
if [ "${1:-}" = "--revert" ]; then
  bak="$(ls -1t "$FILE".bak.* 2>/dev/null | head -1 || true)"
  if [ -n "$bak" ]; then cp "$bak" "$FILE"; echo "restored $(basename "$FILE") <- $(basename "$bak")";
  else echo "(no backup found for $(basename "$FILE"))"; fi
  echo "Revert done."
  exit 0
fi

# ---- idempotency ----------------------------------------------------------
if grep -q "$MARK" "$FILE"; then
  echo "Already applied ($MARK present). Nothing to do."
  exit 0
fi

# ---- anchored single-replacement via Python -------------------------------
python3 - "$STAMP" "$MARK" "$FILE" <<'PYEOF'
import sys, os
stamp, mark, path = sys.argv[1], sys.argv[2], sys.argv[3]

old = (
"const FEE_PROTOCOLS: { key: string; protocol: FeeProtocol; label: string }[] = [\n"
"  { key: 'p2p',     protocol: FeeProtocol.P2P,     label: 'Marketplace (P2P)' },\n"
"  { key: 'invoice', protocol: FeeProtocol.Invoice, label: 'Invoices' },\n"
"  { key: 'bridge',  protocol: FeeProtocol.Bridge,  label: 'Bridge' },\n"
"]"
)
new = (
"const FEE_PROTOCOLS: { key: string; protocol: FeeProtocol; label: string }[] = [\n"
"  { key: 'p2p',     protocol: FeeProtocol.P2P,     label: 'Marketplace (P2P)' },\n"
"  { key: 'invoice', protocol: FeeProtocol.Invoice, label: 'Invoices' },\n"
"  // Bridge fee removed: never collectable on Arc's single-chain model, and the\n"
"  // deployed vault has no Bridge protocol, so feesAccrued(2) reverted the page.\n"
"]"
)

with open(path, 'r', encoding='utf-8') as fh:
    text = fh.read()

if mark in text:
    print("marker present, skipping"); raise SystemExit(0)

c = text.count(old)
if c != 1:
    raise SystemExit(f"ABORT: FEE_PROTOCOLS anchor matched {c} times (need exactly 1). "
                     f"File unchanged.")

# backup once per run
bak = f"{path}.bak.{stamp}"
if not os.path.exists(bak):
    with open(bak, 'w', encoding='utf-8') as fh:
        fh.write(text)

text = text.replace(old, new, 1)
if not text.endswith("\n"):
    text += "\n"
text += f"// {mark} {stamp}\n"

with open(path, 'w', encoding='utf-8') as fh:
    fh.write(text)

print("removed Bridge from FEE_PROTOCOLS (backup:", os.path.basename(bak) + ")")
PYEOF

echo ""
echo "Applied. Verify: cd $API && npx tsc --noEmit"
echo "Revert:  bash $(basename "$0") --revert"
