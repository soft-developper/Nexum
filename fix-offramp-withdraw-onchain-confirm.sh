#!/usr/bin/env bash
# ============================================================
# fix-offramp-withdraw-onchain-confirm.sh
#
# Close the Phase 5 gap: the offramp WithdrawCard declared final success
# ("Withdrawal sent") on ANY non-failed state — including a bare hash that
# Circle hadn't yet confirmed on-chain. Same too-eager pattern we fixed for
# regular Send. A withdrawal could show "sent to your bank" before the USDC
# actually confirmed at the liquidation address.
#
# FIX (web-only, 1 file, 3 anchored edits to WithdrawCard in ramp/page.tsx):
#   • Replace the single `sent` boolean with a phase:
#       idle → confirming (hash exists, NOT yet COMPLETE/CONFIRMED) → confirmed
#   • Settle to 'confirmed' ONLY when Circle reports COMPLETE/CONFIRMED.
#   • A bare hash shows "Confirming on-chain…" (spinner), never a false success.
#   • FAILED/DENIED shows an explicit failure instead of success.
#   • The drain tracker below remains the downstream on-chain truth (it polls
#     Bridge's funds_received → payment_submitted → payment_processed).
#
# This makes offramp judge settlement by real on-chain confirmation, matching
# the Send tightening + on-chain reconciler philosophy.
#
# v2 delivery: 3 anchored byte-exact replacements; aborts cleanly if any anchor
# isn't found (e.g. Part 3 not applied). Idempotent (guard marker). --revert
# restores the timestamped backup.
#
# Usage:
#   bash fix-offramp-withdraw-onchain-confirm.sh          # apply
#   bash fix-offramp-withdraw-onchain-confirm.sh --revert # undo
# ============================================================
set -euo pipefail
STAMP="$(date +%Y%m%d-%H%M%S)"

if [ -d "nexum-web" ]; then WEB="nexum-web"
elif [ -d "../nexum-web" ]; then WEB="../nexum-web"
elif [ -f "package.json" ] && grep -q '"name": *"nexum-web"\|afrifx-web' package.json 2>/dev/null; then WEB="."
else echo "ERROR: run from the repo root (~/AfriFX) or nexum-web." >&2; exit 1; fi
echo "Using WEB package at: $WEB"

PAGE="$WEB/app/(app)/ramp/page.tsx"
GUARD="'idle' | 'confirming' | 'confirmed'"
[ -f "$PAGE" ] || { echo "ERROR: $PAGE not found." >&2; exit 1; }

# ---- revert -----------------------------------------------------------------
if [ "${1:-}" = "--revert" ]; then
  echo "Reverting offramp withdraw on-chain-confirm fix..."
  BK="$(ls -t "$PAGE".bak.* 2>/dev/null | head -1 || true)"
  if [ -n "$BK" ]; then cp "$BK" "$PAGE"; echo "  restored $PAGE from $BK"; else echo "  no backup found"; fi
  echo "Revert complete. Re-run: cd $WEB && rm -rf .next && npx tsc --noEmit && npm run build"
  exit 0
fi

if grep -qF "$GUARD" "$PAGE" 2>/dev/null; then
  echo "  page.tsx already has the phase-based withdraw fix — skipping (idempotent)."
  echo "Nothing to do."; exit 0
fi

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

decode () { base64 --decode "$1" > "$2" 2>/dev/null || { echo "ERROR: decode $2 failed" >&2; exit 1; }; [ -s "$2" ] || { echo "ERROR: $2 empty" >&2; exit 1; }; }

# Make ONE backup before the first edit.
cp "$PAGE" "$PAGE.bak.$STAMP"

apply_pair () { # <name>
  local n="$1"
  decode "$TMP/${n}_old.b64" "$TMP/${n}_old.txt"
  decode "$TMP/${n}_new.b64" "$TMP/${n}_new.txt"
  local old new; old="$(cat "$TMP/${n}_old.txt")"; new="$(cat "$TMP/${n}_new.txt")"
  if ! grep -qF "$old" "$PAGE"; then
    echo "ERROR: anchor '$n' not found in $PAGE — aborting, restoring backup." >&2
    cp "$PAGE.bak.$STAMP" "$PAGE"; exit 1
  fi
  OLD="$old" NEW="$new" python3 - "$PAGE" <<'PY'
import os, sys
p=sys.argv[1]; s=open(p).read()
old=os.environ['OLD']; new=os.environ['NEW']
assert s.count(old)==1, f"expected 1 '{old[:30]}...' got {s.count(old)}"
open(p,'w').write(s.replace(old,new,1))
PY
  echo "  applied edit: $n"
}

cat > "$TMP/state_old.b64" <<'B64_state_OLD'
ICBjb25zdCBbdHhIYXNoLCBzZXRUeEhhc2hdICAgPSB1c2VTdGF0ZTxzdHJpbmcgfCBudWxsPihu
dWxsKQogIGNvbnN0IFtzZW50LCBzZXRTZW50XSAgICAgICA9IHVzZVN0YXRlKGZhbHNlKQogIGNv
bnN0IFtlcnIsIHNldEVycl0gICAgICAgICA9IHVzZVN0YXRlPHN0cmluZyB8IG51bGw+KG51bGwp
B64_state_OLD
cat > "$TMP/state_new.b64" <<'B64_state_NEW'
ICBjb25zdCBbdHhIYXNoLCBzZXRUeEhhc2hdICAgPSB1c2VTdGF0ZTxzdHJpbmcgfCBudWxsPihu
dWxsKQogIC8vICdpZGxlJyB8ICdjb25maXJtaW5nJyAoaGFzaCBleGlzdHMsIG5vdCB5ZXQgY29u
ZmlybWVkIG9uLWNoYWluKSB8ICdjb25maXJtZWQnCiAgLy8gKENpcmNsZSByZXBvcnRlZCBDT01Q
TEVURS9DT05GSVJNRUQpLiBXZSBuZXZlciBjbGFpbSBmaW5hbCBzdWNjZXNzIG9uIGEgYmFyZQog
IC8vIHVuY29uZmlybWVkIGhhc2gg4oCUIHRoZSBkcmFpbiB0cmFja2VyIGJlbG93IGlzIHRoZSBk
b3duc3RyZWFtIG9uLWNoYWluIHRydXRoLgogIGNvbnN0IFtwaGFzZSwgc2V0UGhhc2VdICAgICA9
IHVzZVN0YXRlPCdpZGxlJyB8ICdjb25maXJtaW5nJyB8ICdjb25maXJtZWQnPignaWRsZScpCiAg
Y29uc3QgW2Vyciwgc2V0RXJyXSAgICAgICAgID0gdXNlU3RhdGU8c3RyaW5nIHwgbnVsbD4obnVs
bCk=
B64_state_NEW
cat > "$TMP/submit_old.b64" <<'B64_submit_OLD'
ICAgIHNldFNlbmRpbmcodHJ1ZSk7IHNldFNlbnQoZmFsc2UpOyBzZXRTdGVwKG51bGwpCiAgICB0
cnkgewogICAgICAvLyBUaGUgZXhhY3Qgc2FtZSBDaXJjbGUtc2lnbmVkIHNlbmQgcGF0aCBhcyBt
dWx0aWNoYWluIHNlbmQg4oCUIFVTREMgbGVhdmVzCiAgICAgIC8vIHRoZSB1c2VyJ3Mgd2FsbGV0
IG9uIEJhc2UgYW5kIGxhbmRzIGF0IHRoZSBCcmlkZ2UgbGlxdWlkYXRpb24gYWRkcmVzcywKICAg
ICAgLy8gd2hpY2ggYXV0by1jb252ZXJ0cyBpdCB0byBmaWF0IGFuZCBwYXlzIG91dCB0byB0aGVp
ciBiYW5rLgogICAgICBjb25zdCByZXN1bHQgPSBhd2FpdCBzZW5kVXNkYygKICAgICAgICB7IHRv
OiBsaXEuYWRkcmVzcywgYW1vdW50OiBTdHJpbmcoYW10KSwgY2hhaW5LZXk6IGxpcS5zb3VyY2VD
aGFpbiB9LAogICAgICAgIHNldFN0ZXAsCiAgICAgICkKICAgICAgaWYgKHJlc3VsdC50eEhhc2gp
IHsKICAgICAgICBzZXRUeEhhc2gocmVzdWx0LnR4SGFzaCkKICAgICAgICBjb25zdCBzdCA9IFN0
cmluZyhyZXN1bHQuc3RhdGUgPz8gJycpLnRvVXBwZXJDYXNlKCkKICAgICAgICBpZiAoc3QgIT09
ICdGQUlMRUQnICYmIHN0ICE9PSAnREVOSUVEJykgc2V0U2VudCh0cnVlKQogICAgICB9IGVsc2Ug
ewogICAgICAgIHNldFNlbnQodHJ1ZSkKICAgICAgfQogICAgfSBjYXRjaCAoZTogYW55KSB7
B64_submit_OLD
cat > "$TMP/submit_new.b64" <<'B64_submit_NEW'
ICAgIHNldFNlbmRpbmcodHJ1ZSk7IHNldFBoYXNlKCdpZGxlJyk7IHNldFN0ZXAobnVsbCkKICAg
IHRyeSB7CiAgICAgIC8vIFRoZSBleGFjdCBzYW1lIENpcmNsZS1zaWduZWQgc2VuZCBwYXRoIGFz
IG11bHRpY2hhaW4gc2VuZCDigJQgVVNEQyBsZWF2ZXMKICAgICAgLy8gdGhlIHVzZXIncyB3YWxs
ZXQgb24gQmFzZSBhbmQgbGFuZHMgYXQgdGhlIEJyaWRnZSBsaXF1aWRhdGlvbiBhZGRyZXNzLAog
ICAgICAvLyB3aGljaCBhdXRvLWNvbnZlcnRzIGl0IHRvIGZpYXQgYW5kIHBheXMgb3V0IHRvIHRo
ZWlyIGJhbmsuCiAgICAgIGNvbnN0IHJlc3VsdCA9IGF3YWl0IHNlbmRVc2RjKAogICAgICAgIHsg
dG86IGxpcS5hZGRyZXNzLCBhbW91bnQ6IFN0cmluZyhhbXQpLCBjaGFpbktleTogbGlxLnNvdXJj
ZUNoYWluIH0sCiAgICAgICAgc2V0U3RlcCwKICAgICAgKQogICAgICBjb25zdCBzdCA9IFN0cmlu
ZyhyZXN1bHQuc3RhdGUgPz8gJycpLnRvVXBwZXJDYXNlKCkKICAgICAgaWYgKHN0ID09PSAnRkFJ
TEVEJyB8fCBzdCA9PT0gJ0RFTklFRCcpIHsKICAgICAgICBzZXRFcnIoJ1RoZSB3aXRoZHJhd2Fs
IGZhaWxlZCBvbi1jaGFpbi4gTm8gZnVuZHMgbGVmdCB5b3VyIHdhbGxldC4nKQogICAgICB9IGVs
c2UgaWYgKHJlc3VsdC50eEhhc2gpIHsKICAgICAgICBzZXRUeEhhc2gocmVzdWx0LnR4SGFzaCkK
ICAgICAgICAvLyBDT01QTEVURS9DT05GSVJNRUQgPSBDaXJjbGUgY29uZmlybWVkIGl0IG9uLWNo
YWluIOKGkiBjb25maWRlbnQgc3VjY2Vzcy4KICAgICAgICAvLyBBIGJhcmUgaGFzaCAoU0VOVCkg
aXMgb24tY2hhaW4gYnV0IG5vdCB5ZXQgY29uZmlybWVkIOKGkiAnY29uZmlybWluZyc7CiAgICAg
ICAgLy8gdGhlIGRyYWluIHRyYWNrZXIgdXBncmFkZXMgdGhlIG1lc3NhZ2Ugb25jZSBCcmlkZ2Ug
c2VlcyBpdCBhcnJpdmUuCiAgICAgICAgc2V0UGhhc2UoKHN0ID09PSAnQ09NUExFVEUnIHx8IHN0
ID09PSAnQ09ORklSTUVEJykgPyAnY29uZmlybWVkJyA6ICdjb25maXJtaW5nJykKICAgICAgfSBl
bHNlIHsKICAgICAgICAvLyBObyBoYXNoIHlldCAoYXBwcm92ZWQgKyBicm9hZGNhc3QsIHNsb3cp
LiBUcmVhdCBhcyBjb25maXJtaW5nLCBub3QgZG9uZS4KICAgICAgICBzZXRQaGFzZSgnY29uZmly
bWluZycpCiAgICAgIH0KICAgIH0gY2F0Y2ggKGU6IGFueSkgew==
B64_submit_NEW
cat > "$TMP/card_old.b64" <<'B64_card_OLD'
ICBpZiAoc2VudCkgewogICAgcmV0dXJuICgKICAgICAgPGRpdiBjbGFzc05hbWU9InNwYWNlLXkt
NCByb3VuZGVkLTJ4bCBib3JkZXIgYm9yZGVyLWFwcC1ib3JkZXIgYmctYXBwLXN1cmZhY2UgcC01
Ij4KICAgICAgICA8ZGl2IGNsYXNzTmFtZT0iZmxleCBpdGVtcy1jZW50ZXIgZ2FwLTIuNSB0ZXh0
LWFwcC10ZXh0Ij4KICAgICAgICAgIDxzcGFuIGNsYXNzTmFtZT0iZmxleCBoLTkgdy05IGl0ZW1z
LWNlbnRlciBqdXN0aWZ5LWNlbnRlciByb3VuZGVkLWZ1bGwgYmctZW1lcmFsZC01MDAvMTUiPgog
ICAgICAgICAgICA8Q2lyY2xlQ2hlY2sgY2xhc3NOYW1lPSJoLTUgdy01IHRleHQtZW1lcmFsZC00
MDAiIC8+CiAgICAgICAgICA8L3NwYW4+CiAgICAgICAgICA8ZGl2PgogICAgICAgICAgICA8cCBj
bGFzc05hbWU9ImZvbnQtbWVkaXVtIj5XaXRoZHJhd2FsIHNlbnQ8L3A+CiAgICAgICAgICAgIDxw
IGNsYXNzTmFtZT0idGV4dC1zbSB0ZXh0LWFwcC1tdXRlZCI+CiAgICAgICAgICAgICAge2Ftb3Vu
dH0gVVNEQyBpcyBvbiBpdHMgd2F5IHRvIHlvdXIgYmFuay4gVHJhY2sgaXQgYmVsb3cuCiAgICAg
ICAgICAgIDwvcD4KICAgICAgICAgIDwvZGl2PgogICAgICAgIDwvZGl2PgogICAgICAgIHt0eEhh
c2ggJiYgKAogICAgICAgICAgPGEgaHJlZj17YGh0dHBzOi8vc2Vwb2xpYS5iYXNlc2Nhbi5vcmcv
dHgvJHt0eEhhc2h9YH0gdGFyZ2V0PSJfYmxhbmsiIHJlbD0ibm9vcGVuZXIgbm9yZWZlcnJlciIK
ICAgICAgICAgICAgY2xhc3NOYW1lPSJpbmxpbmUtZmxleCBpdGVtcy1jZW50ZXIgZ2FwLTEgdGV4
dC14cyB0ZXh0LWFwcC1hY2NlbnQtdGV4dCBob3Zlcjp1bmRlcmxpbmUiPgogICAgICAgICAgICBW
aWV3IHRyYW5zYWN0aW9uIDxFeHRlcm5hbExpbmsgY2xhc3NOYW1lPSJoLTMgdy0zIiAvPgogICAg
ICAgICAgPC9hPgogICAgICAgICl9CiAgICAgICAgPEJ1dHRvbiB2YXJpYW50PSJvdXRsaW5lIiBj
bGFzc05hbWU9InctZnVsbCIgb25DbGljaz17KCkgPT4geyBzZXRTZW50KGZhbHNlKTsgc2V0QW1v
dW50KCcnKTsgc2V0VHhIYXNoKG51bGwpIH19PgogICAgICAgICAgTWFrZSBhbm90aGVyIHdpdGhk
cmF3YWwKICAgICAgICA8L0J1dHRvbj4KICAgICAgPC9kaXY+CiAgICApCiAgfQ==
B64_card_OLD
cat > "$TMP/card_new.b64" <<'B64_card_NEW'
ICBpZiAocGhhc2UgIT09ICdpZGxlJykgewogICAgY29uc3QgY29uZmlybWVkID0gcGhhc2UgPT09
ICdjb25maXJtZWQnCiAgICByZXR1cm4gKAogICAgICA8ZGl2IGNsYXNzTmFtZT0ic3BhY2UteS00
IHJvdW5kZWQtMnhsIGJvcmRlciBib3JkZXItYXBwLWJvcmRlciBiZy1hcHAtc3VyZmFjZSBwLTUi
PgogICAgICAgIDxkaXYgY2xhc3NOYW1lPSJmbGV4IGl0ZW1zLWNlbnRlciBnYXAtMi41IHRleHQt
YXBwLXRleHQiPgogICAgICAgICAgPHNwYW4gY2xhc3NOYW1lPXtgZmxleCBoLTkgdy05IGl0ZW1z
LWNlbnRlciBqdXN0aWZ5LWNlbnRlciByb3VuZGVkLWZ1bGwgJHtjb25maXJtZWQgPyAnYmctZW1l
cmFsZC01MDAvMTUnIDogJ2JnLWFwcC1hY2NlbnQvMTUnfWB9PgogICAgICAgICAgICB7Y29uZmly
bWVkCiAgICAgICAgICAgICAgPyA8Q2lyY2xlQ2hlY2sgY2xhc3NOYW1lPSJoLTUgdy01IHRleHQt
ZW1lcmFsZC00MDAiIC8+CiAgICAgICAgICAgICAgOiA8TG9hZGVyMiBjbGFzc05hbWU9ImgtNSB3
LTUgYW5pbWF0ZS1zcGluIHRleHQtYXBwLWFjY2VudC10ZXh0IiAvPn0KICAgICAgICAgIDwvc3Bh
bj4KICAgICAgICAgIDxkaXY+CiAgICAgICAgICAgIDxwIGNsYXNzTmFtZT0iZm9udC1tZWRpdW0i
Pntjb25maXJtZWQgPyAnV2l0aGRyYXdhbCBzZW50JyA6ICdDb25maXJtaW5nIG9uLWNoYWlu4oCm
J308L3A+CiAgICAgICAgICAgIDxwIGNsYXNzTmFtZT0idGV4dC1zbSB0ZXh0LWFwcC1tdXRlZCI+
CiAgICAgICAgICAgICAge2NvbmZpcm1lZAogICAgICAgICAgICAgICAgPyBgJHthbW91bnR9IFVT
REMgaXMgb24gaXRzIHdheSB0byB5b3VyIGJhbmsuIFRyYWNrIGl0IGJlbG93LmAKICAgICAgICAg
ICAgICAgIDogYCR7YW1vdW50fSBVU0RDIHdhcyBzdWJtaXR0ZWQuIFdl4oCZcmUgY29uZmlybWlu
ZyBpdCBvbi1jaGFpbiBiZWZvcmUgaXQgaGVhZHMgdG8geW91ciBiYW5rIOKAlCB0aGlzIGlzIHRy
YWNrZWQgYmVsb3cuYH0KICAgICAgICAgICAgPC9wPgogICAgICAgICAgPC9kaXY+CiAgICAgICAg
PC9kaXY+CiAgICAgICAge3R4SGFzaCAmJiAoCiAgICAgICAgICA8YSBocmVmPXtgaHR0cHM6Ly9z
ZXBvbGlhLmJhc2VzY2FuLm9yZy90eC8ke3R4SGFzaH1gfSB0YXJnZXQ9Il9ibGFuayIgcmVsPSJu
b29wZW5lciBub3JlZmVycmVyIgogICAgICAgICAgICBjbGFzc05hbWU9ImlubGluZS1mbGV4IGl0
ZW1zLWNlbnRlciBnYXAtMSB0ZXh0LXhzIHRleHQtYXBwLWFjY2VudC10ZXh0IGhvdmVyOnVuZGVy
bGluZSI+CiAgICAgICAgICAgIFZpZXcgdHJhbnNhY3Rpb24gPEV4dGVybmFsTGluayBjbGFzc05h
bWU9ImgtMyB3LTMiIC8+CiAgICAgICAgICA8L2E+CiAgICAgICAgKX0KICAgICAgICA8QnV0dG9u
IHZhcmlhbnQ9Im91dGxpbmUiIGNsYXNzTmFtZT0idy1mdWxsIiBvbkNsaWNrPXsoKSA9PiB7IHNl
dFBoYXNlKCdpZGxlJyk7IHNldEFtb3VudCgnJyk7IHNldFR4SGFzaChudWxsKSB9fT4KICAgICAg
ICAgIE1ha2UgYW5vdGhlciB3aXRoZHJhd2FsCiAgICAgICAgPC9CdXR0b24+CiAgICAgIDwvZGl2
PgogICAgKQogIH0=
B64_card_NEW

apply_pair state
apply_pair submit
apply_pair card

# verify all three landed
if ! grep -qF "'idle' | 'confirming' | 'confirmed'" "$PAGE" || ! grep -qF "Confirming on-chain" "$PAGE"; then
  echo "ERROR: post-edit verification failed — restoring backup." >&2
  cp "$PAGE.bak.$STAMP" "$PAGE"; exit 1
fi
echo "  all 3 edits verified in $PAGE (backup at $PAGE.bak.$STAMP)"

echo ""
echo "Applied. Deploy (web flow — note the .next wipe):"
echo "  cd $WEB && rm -rf .next && npx tsc --noEmit && npm run build"
echo "  git add -A && git commit -m 'fix: offramp withdraw settles on on-chain confirmation, not bare hash' && git push"
echo ""
echo "After deploy: a withdrawal shows 'Confirming on-chain…' until Circle confirms,"
echo "then 'Withdrawal sent'. The drain tracker below shows the real payout lifecycle."
