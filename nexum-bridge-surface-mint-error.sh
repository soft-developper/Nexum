#!/usr/bin/env bash
# ============================================================================
# Nexum bridge - surface Circle's real mint error ("Nonce already used" = done)
#
# CONFIRMED ROOT CAUSE (from the Circle console for a stuck mint):
#   State: Failed | Error Reason: ESTIMATION_ERROR | Details: "Nonce already used"
# That is CCTP's double-mint guard: the mint ALREADY succeeded and the USDC is
# on the destination. The retry fails at gas ESTIMATION because the nonce is
# spent - which is correct, expected behaviour.
#
# THE BUG was purely in reporting: executeContractCall threw a hardcoded
# "Transaction failed" on a FAILED state, DISCARDING Circle's errorReason /
# errorDetails. So useCompleteBridge's idempotent-success check (which already
# matches "nonce already") never saw the real string, and an already-completed
# transfer showed as a permanent failure with a Complete button that could only
# ever fail again.
#
# THE FIX (3 surgical edits, both packages):
#   api  CircleTransaction         + optional errorReason / errorDetails
#   api  find* mappers (mint+xfer) pass those through from Circle's tx object
#   web  executeContractCall       on FAILED, throw an error INCLUDING the detail
# The existing idempotent-success branch then marks such transfers complete.
#
# PAIRS WITH the earlier retry fix (nexum-bridge-mint-retry-fix.sh); apply that
# first if you have not - though this stands alone too.
#
# Delivery contract (v2) + full deploy:
#   * patcher base64 + sha256 verified; exact-anchor; aborts on drift
#   * idempotent (marker __NEXUM_SURFACE_MINT_ERROR__); clean-only backups
#   * gate: API tsc  +  WEB (rm -rf .next && tsc && build)  -> commit + push
#   * --revert restores all touched files ; --no-deploy applies only
#
# Run from REPO ROOT (folder containing nexum-api/ and nexum-web/).
#   bash nexum-bridge-surface-mint-error.sh
#   bash nexum-bridge-surface-mint-error.sh --no-deploy
#   bash nexum-bridge-surface-mint-error.sh --revert
# ============================================================================
set -euo pipefail

API="nexum-api"; WEB="nexum-web"
CW="$API/src/services/circleWallets.ts"
UCT="$WEB/hooks/useCircleTx.ts"
MARKER="__NEXUM_SURFACE_MINT_ERROR__"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR=".nexum-surfacemint-backup/${STAMP}"
PATCH_SHA="0d77957b88418caf57bb8e99be8eefddb7009217a3be75d78d052368af90901d"
COMMIT_MSG="fix(bridge): surface Circle error so 'Nonce already used' is treated as an already-completed mint"

FLAG="${1:-}"
log(){ printf '  %s\n' "$*"; }
die(){ printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[ -d "$API" ] || die "Cannot find $API . Run from the repo root."
[ -d "$WEB" ] || die "Cannot find $WEB . Run from the repo root."

if [ "$FLAG" = "--revert" ]; then
  LATEST=""
  for d in $(ls -1dt .nexum-surfacemint-backup/*/ 2>/dev/null); do
    if [ -f "${d}circleWallets.ts" ] || [ -f "${d}useCircleTx.ts" ]; then LATEST="$d"; break; fi
  done
  if [ -n "$LATEST" ]; then
    [ -f "${LATEST}circleWallets.ts" ] && cp "${LATEST}circleWallets.ts" "$CW"  && log "Restored $CW"
    [ -f "${LATEST}useCircleTx.ts" ]   && cp "${LATEST}useCircleTx.ts"   "$UCT" && log "Restored $UCT"
  else
    log "No backup found; leaving files as-is."
  fi
  log "Reverted surface-mint-error patch."
  exit 0
fi

TPATCH="$(mktemp /tmp/surfacemint.XXXXXX.py)"
trap 'rm -f "$TPATCH"' EXIT
base64 -d > "$TPATCH" <<'B64'
IyEvdXNyL2Jpbi9lbnYgcHl0aG9uMwoiIiIKU3VyZmFjZSBDaXJjbGUncyByZWFsIGNvbnRyYWN0
LWV4ZWN1dGlvbiBlcnJvciBzbyAnTm9uY2UgYWxyZWFkeSB1c2VkJyAodGhlIG1pbnQKQUxSRUFE
WSBzdWNjZWVkZWQpIGlzIHJlY29nbml6ZWQgaW5zdGVhZCBvZiBzaG93biBhcyBhIGdlbmVyaWMg
ZmFpbHVyZS4KCkNvbmZpcm1lZCBmcm9tIHRoZSBDaXJjbGUgY29uc29sZTogYSBzdHJhbmRlZCBt
aW50IHJldHJ5IGhpdHMKICBzdGF0ZT1GQUlMRUQsIGVycm9yUmVhc29uPUVTVElNQVRJT05fRVJS
T1IsIGVycm9yRGV0YWlscz0iTm9uY2UgYWxyZWFkeSB1c2VkIgooQ0NUUCdzIGRvdWJsZS1taW50
IGd1YXJkIC0gZnVuZHMgYWxyZWFkeSBvbiB0aGUgZGVzdGluYXRpb24pLiBCdXQgdGhlIGNsaWVu
dAp0aHJldyBhIGhhcmRjb2RlZCAiVHJhbnNhY3Rpb24gZmFpbGVkIiwgZGlzY2FyZGluZyBlcnJv
ckRldGFpbHMsIHNvIHRoZQppZGVtcG90ZW50LXN1Y2Nlc3MgY2hlY2sgaW4gdXNlQ29tcGxldGVC
cmlkZ2UgbmV2ZXIgc2F3ICJub25jZSBhbHJlYWR5Ii4KCkZJWDoKICBhcGkgIENpcmNsZVRyYW5z
YWN0aW9uICAgICAgICAtIGFkZCBvcHRpb25hbCBlcnJvclJlYXNvbiAvIGVycm9yRGV0YWlscwog
IGFwaSAgZmluZCogbWFwcGVycyAoQk9USCkgICAgIC0gcGFzcyB0aG9zZSB0aHJvdWdoIChtaW50
IEFORCB0cmFuc2ZlciBwYXRocykKICB3ZWIgIGV4ZWN1dGVDb250cmFjdENhbGwgICAgICAtIG9u
IEZBSUxFRCwgdGhyb3cgZXJyb3IgSU5DTFVESU5HIHRoZSBkZXRhaWwKCklkZW1wb3RlbnQgdmlh
IF9fTkVYVU1fU1VSRkFDRV9NSU5UX0VSUk9SX18uCiIiIgppbXBvcnQgc3lzLCBpbwoKTUFSS0VS
ID0gIl9fTkVYVU1fU1VSRkFDRV9NSU5UX0VSUk9SX18iCgojIC0tLS0gQVBJIC0tLS0KYXBpID0g
Im5leHVtLWFwaS9zcmMvc2VydmljZXMvY2lyY2xlV2FsbGV0cy50cyIKc3JjID0gaW8ub3Blbihh
cGksIGVuY29kaW5nPSJ1dGYtOCIpLnJlYWQoKQppZiBNQVJLRVIgaW4gc3JjOgogICAgcHJpbnQo
ZiIgIHthcGl9OiBhbHJlYWR5IHBhdGNoZWQgLSBza2lwcGluZy4iKQplbHNlOgogICAgIyBpbnRl
cmZhY2UgKHVuaXF1ZSkKICAgIGlmYWNlX29sZCA9ICgiZXhwb3J0IGludGVyZmFjZSBDaXJjbGVU
cmFuc2FjdGlvbiB7XG4gIGlkOiAgICAgICAgICBzdHJpbmdcbiAgc3RhdGU6ICAgICAgIHN0cmlu
Z1xuIgogICAgICAgICAgICAgICAgICIgIHR4SGFzaD86ICAgICBzdHJpbmdcbiAgYmxvY2tjaGFp
bj86IHN0cmluZ1xuICBhbW91bnRzPzogICAgc3RyaW5nW11cbn0iKQogICAgaWZhY2VfbmV3ID0g
KCJleHBvcnQgaW50ZXJmYWNlIENpcmNsZVRyYW5zYWN0aW9uIHtcbiAgaWQ6ICAgICAgICAgIHN0
cmluZ1xuICBzdGF0ZTogICAgICAgc3RyaW5nXG4iCiAgICAgICAgICAgICAgICAgIiAgdHhIYXNo
PzogICAgIHN0cmluZ1xuICBibG9ja2NoYWluPzogc3RyaW5nXG4gIGFtb3VudHM/OiAgICBzdHJp
bmdbXVxuIgogICAgICAgICAgICAgICAgICIgIC8vIF9fTkVYVU1fU1VSRkFDRV9NSU5UX0VSUk9S
X18gY2FycnkgQ2lyY2xlJ3MgZmFpbHVyZSByZWFzb24gc28gdGhlIGNsaWVudFxuIgogICAgICAg
ICAgICAgICAgICIgIC8vIGNhbiByZWNvZ25pemUgJ05vbmNlIGFscmVhZHkgdXNlZCcgKGFuIGFs
cmVhZHktY29tcGxldGVkIG1pbnQpIGluc3RlYWQgb2ZcbiIKICAgICAgICAgICAgICAgICAiICAv
LyByZXBvcnRpbmcgYSBnZW5lcmljIGZhaWx1cmUuXG4gIGVycm9yUmVhc29uPzogIHN0cmluZ1xu
ICBlcnJvckRldGFpbHM/OiBzdHJpbmdcbn0iKQogICAgaWYgc3JjLmNvdW50KGlmYWNlX29sZCkg
IT0gMToKICAgICAgICBwcmludChmIkVSUk9SOiBpbnRlcmZhY2UgYW5jaG9yIG1hdGNoZWQge3Ny
Yy5jb3VudChpZmFjZV9vbGQpfSB0aW1lcy4gQWJvcnRpbmcuIik7IHN5cy5leGl0KDIpCiAgICBz
cmMgPSBzcmMucmVwbGFjZShpZmFjZV9vbGQsIGlmYWNlX25ldykKCiAgICAjIEJPVEggbWFwcGVy
IGJsb2NrcyAoaWRlbnRpY2FsKSAtIHJlcGxhY2UgYWxsIG9jY3VycmVuY2VzLgogICAgbWFwX29s
ZCA9ICgiICAgIGlkOiAgICAgICAgIFN0cmluZyhtYXRjaC5pZCksXG4gICAgc3RhdGU6ICAgICAg
U3RyaW5nKG1hdGNoLnN0YXRlID8/ICdVTktOT1dOJyksXG4iCiAgICAgICAgICAgICAgICIgICAg
dHhIYXNoOiAgICAgbWF0Y2gudHhIYXNoLFxuICAgIGJsb2NrY2hhaW46IG1hdGNoLmJsb2NrY2hh
aW4sXG4gICAgYW1vdW50czogICAgbWF0Y2guYW1vdW50cyxcbiAgfSIpCiAgICBtYXBfbmV3ID0g
KCIgICAgaWQ6ICAgICAgICAgU3RyaW5nKG1hdGNoLmlkKSxcbiAgICBzdGF0ZTogICAgICBTdHJp
bmcobWF0Y2guc3RhdGUgPz8gJ1VOS05PV04nKSxcbiIKICAgICAgICAgICAgICAgIiAgICB0eEhh
c2g6ICAgICBtYXRjaC50eEhhc2gsXG4gICAgYmxvY2tjaGFpbjogbWF0Y2guYmxvY2tjaGFpbixc
biAgICBhbW91bnRzOiAgICBtYXRjaC5hbW91bnRzLFxuIgogICAgICAgICAgICAgICAiICAgIGVy
cm9yUmVhc29uOiAgbWF0Y2guZXJyb3JSZWFzb24sICAgLy8gX19ORVhVTV9TVVJGQUNFX01JTlRf
RVJST1JfX1xuIgogICAgICAgICAgICAgICAiICAgIGVycm9yRGV0YWlsczogbWF0Y2guZXJyb3JE
ZXRhaWxzLFxuICB9IikKICAgIGNudCA9IHNyYy5jb3VudChtYXBfb2xkKQogICAgaWYgY250IDwg
MToKICAgICAgICBwcmludChmIkVSUk9SOiBtYXBwZXIgYW5jaG9yIG1hdGNoZWQge2NudH0gdGlt
ZXMgKGV4cGVjdGVkID49MSkuIEFib3J0aW5nLiIpOyBzeXMuZXhpdCgyKQogICAgc3JjID0gc3Jj
LnJlcGxhY2UobWFwX29sZCwgbWFwX25ldykgICAjIHJlcGxhY2UgQUxMIChib3RoIGZpbmQqIGhl
bHBlcnMpCiAgICBpby5vcGVuKGFwaSwgInciLCBlbmNvZGluZz0idXRmLTgiKS53cml0ZShzcmMp
CiAgICBwcmludChmIiAge2FwaX06IHBhdGNoZWQgKHtjbnR9IG1hcHBlciBibG9jayhzKSkuIikK
CiMgLS0tLSBXRUIgLS0tLQp3ZWIgPSAibmV4dW0td2ViL2hvb2tzL3VzZUNpcmNsZVR4LnRzIgpz
cmMgPSBpby5vcGVuKHdlYiwgZW5jb2Rpbmc9InV0Zi04IikucmVhZCgpCmlmIE1BUktFUiBpbiBz
cmM6CiAgICBwcmludChmIiAge3dlYn06IGFscmVhZHkgcGF0Y2hlZCAtIHNraXBwaW5nLiIpCmVs
c2U6CiAgICAjIE9ubHkgdGhlIGNvbnRyYWN0LWNhbGwgbG9vcCdzIEZBSUxFRCB0aHJvdyAodGhl
IG1pbnQgcGF0aCkuIFRoZSB0cmFuc2ZlcgogICAgIyBsb29wJ3MgaWRlbnRpY2FsIGxpbmUgaXMg
bGVmdCBhcy1pcyB0byBrZWVwIHRoaXMgY2hhbmdlIHRpZ2h0bHkgc2NvcGVkIHRvCiAgICAjIHRo
ZSBicmlkZ2UgbWludDsgd2UgZGlzYW1iaWd1YXRlIHZpYSB0aGUgdHJhaWxpbmcgY29tbWVudCB0
aGF0IGRpZmZlcnMuCiAgICBvbGQgPSAoIiAgICBjb25zdCB0eCA9IGF3YWl0IHIyLmpzb24oKS5j
YXRjaCgoKSA9PiAoe30pKVxuIgogICAgICAgICAgICIgICAgaWYgKERPTkUuaW5jbHVkZXModHgu
c3RhdGUpKSAgIHJldHVybiB7IHR4SGFzaDogdHgudHhIYXNoLCBzdGF0ZTogdHguc3RhdGUgfVxu
IgogICAgICAgICAgICIgICAgaWYgKEZBSUxFRC5pbmNsdWRlcyh0eC5zdGF0ZSkpIHRocm93IG5l
dyBFcnJvcihgVHJhbnNhY3Rpb24gJHtTdHJpbmcodHguc3RhdGUpLnRvTG93ZXJDYXNlKCl9YClc
blxuIgogICAgICAgICAgICIgICAgLy8gT25jZSB3ZSBoYXZlIGEgaGFzaCBpdCdzIG9uLWNoYWlu
LCBldmVuIGlmIENpcmNsZSBoYXNuJ3QgbWFya2VkIGl0XG4iCiAgICAgICAgICAgIiAgICAvLyBD
T01QTEVURSB5ZXQuIFJldHVybiBpdCByYXRoZXIgdGhhbiBtYWtpbmcgdGhlIGNhbGxlciB3YWl0
LiIpCiAgICBuZXcgPSAoIiAgICBjb25zdCB0eCA9IGF3YWl0IHIyLmpzb24oKS5jYXRjaCgoKSA9
PiAoe30pKVxuIgogICAgICAgICAgICIgICAgaWYgKERPTkUuaW5jbHVkZXModHguc3RhdGUpKSAg
IHJldHVybiB7IHR4SGFzaDogdHgudHhIYXNoLCBzdGF0ZTogdHguc3RhdGUgfVxuIgogICAgICAg
ICAgICIgICAgaWYgKEZBSUxFRC5pbmNsdWRlcyh0eC5zdGF0ZSkpIHtcbiIKICAgICAgICAgICAi
ICAgICAgLy8gX19ORVhVTV9TVVJGQUNFX01JTlRfRVJST1JfXyBpbmNsdWRlIENpcmNsZSdzIHJl
YWwgcmVhc29uIHNvIGNhbGxlcnMgY2FuXG4iCiAgICAgICAgICAgIiAgICAgIC8vIHJlY29nbml6
ZSBlLmcuICdOb25jZSBhbHJlYWR5IHVzZWQnIChtaW50IGFscmVhZHkgY29tcGxldGVkKS4gRmFs
bCBiYWNrIHRvXG4iCiAgICAgICAgICAgIiAgICAgIC8vIHRoZSBiYXJlIHN0YXRlIG9ubHkgd2hl
biBubyBkZXRhaWwgaXMgYXZhaWxhYmxlLlxuIgogICAgICAgICAgICIgICAgICBjb25zdCBkZXRh
aWwgPSB0eC5lcnJvckRldGFpbHMgPz8gdHguZXJyb3JSZWFzb24gPz8gJydcbiIKICAgICAgICAg
ICAiICAgICAgdGhyb3cgbmV3IEVycm9yKFxuIgogICAgICAgICAgICIgICAgICAgIGRldGFpbCA/
IGBUcmFuc2FjdGlvbiAke1N0cmluZyh0eC5zdGF0ZSkudG9Mb3dlckNhc2UoKX06ICR7ZGV0YWls
fWBcbiIKICAgICAgICAgICAiICAgICAgICAgICAgICAgOiBgVHJhbnNhY3Rpb24gJHtTdHJpbmco
dHguc3RhdGUpLnRvTG93ZXJDYXNlKCl9YClcbiIKICAgICAgICAgICAiICAgIH1cblxuIgogICAg
ICAgICAgICIgICAgLy8gT25jZSB3ZSBoYXZlIGEgaGFzaCBpdCdzIG9uLWNoYWluLCBldmVuIGlm
IENpcmNsZSBoYXNuJ3QgbWFya2VkIGl0XG4iCiAgICAgICAgICAgIiAgICAvLyBDT01QTEVURSB5
ZXQuIFJldHVybiBpdCByYXRoZXIgdGhhbiBtYWtpbmcgdGhlIGNhbGxlciB3YWl0LiIpCiAgICBp
ZiBzcmMuY291bnQob2xkKSAhPSAxOgogICAgICAgIHByaW50KGYiRVJST1I6IHdlYiBjb250cmFj
dC10aHJvdyBhbmNob3IgbWF0Y2hlZCB7c3JjLmNvdW50KG9sZCl9IHRpbWVzIChleHBlY3RlZCAx
KS4gQWJvcnRpbmcuIik7IHN5cy5leGl0KDIpCiAgICBzcmMgPSBzcmMucmVwbGFjZShvbGQsIG5l
dykKICAgIGlvLm9wZW4od2ViLCAidyIsIGVuY29kaW5nPSJ1dGYtOCIpLndyaXRlKHNyYykKICAg
IHByaW50KGYiICB7d2VifTogcGF0Y2hlZC4iKQoKcHJpbnQoIk1pbnQtZXJyb3Igc3VyZmFjaW5n
IHBhdGNoIGNvbXBsZXRlLiIpCg==
B64
ACTUAL="$( (sha256sum "$TPATCH" 2>/dev/null || shasum -a 256 "$TPATCH") | awk '{print $1}')"
[ "$ACTUAL" = "$PATCH_SHA" ] || die "Patcher checksum mismatch (got $ACTUAL). Nothing changed."
log "Patcher verified."

mkdir -p "$BACKUP_DIR"
[ -f "$CW" ]  && ! grep -qF "$MARKER" "$CW"  && cp "$CW"  "$BACKUP_DIR/circleWallets.ts" || true
[ -f "$UCT" ] && ! grep -qF "$MARKER" "$UCT" && cp "$UCT" "$BACKUP_DIR/useCircleTx.ts"   || true

python3 "$TPATCH" || {
  [ -f "$BACKUP_DIR/circleWallets.ts" ] && cp "$BACKUP_DIR/circleWallets.ts" "$CW"
  [ -f "$BACKUP_DIR/useCircleTx.ts" ]   && cp "$BACKUP_DIR/useCircleTx.ts"   "$UCT"
  die "Patch failed; files restored."
}

if [ "$FLAG" = "--no-deploy" ]; then
  log "--no-deploy: applied only. Rerun without the flag to build + push."
  exit 0
fi

log ""
log "=== Gate: API typecheck ==="
( cd "$API" && npx tsc --noEmit ) || die "API tsc failed - not committing."
log "API tsc clean."
log "=== Gate: WEB typecheck + build ==="
( cd "$WEB" && rm -rf .next && npx tsc --noEmit ) || die "WEB tsc failed - not committing."
log "WEB tsc clean."
( cd "$WEB" && npm run build ) || die "WEB build failed - not committing."
log "WEB build clean."

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "Not a git work tree; commit manually."
REMOTE="$(git remote | head -1 || true)"; [ -n "$REMOTE" ] || die "No git remote; commit/push manually."
BRANCH="$(git rev-parse --abbrev-ref HEAD)"
git add -A
if git diff --cached --quiet; then log "Nothing to commit."; exit 0; fi
log "Committing on '$BRANCH' -> '$REMOTE'..."
git commit -m "$COMMIT_MSG"
git push "$REMOTE" "$BRANCH"
log ""
log "Pushed. A stranded transfer whose mint already landed will now be marked"
log "complete (Circle's 'Nonce already used' is recognized) instead of showing"
log "a failure. Your existing already-minted transfers will flip to Complete on"
log "the next Complete-transfer attempt."
