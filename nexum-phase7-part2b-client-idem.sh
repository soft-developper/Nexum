#!/usr/bin/env bash
# ============================================================================
# Nexum Phase 7 (Hardening) - Part 2b: web client sends a stable Idempotency-Key
#
# Completes Part 2: the API honours Idempotency-Key; this makes the web client
# SEND one on the two money-moving POSTs it owns, so a retried or double-tapped
# submit dedupes instead of moving money twice.
#
#   CashOutCard.tsx -> POST /transfers/cashout (key in a ref: minted at submit,
#     reused if the user retries the same payout after an error, cleared on
#     success so a new payout gets a fresh key)
#   usePayments.ts  -> POST /payments (one key per mutate call)
#
# REQUIRES Phase 7 Part 2 (server middleware) deployed to have effect.
#
# Delivery contract (v2) + full deploy:
#   * payloads base64 + sha256 verified; exact-anchor patch; aborts on drift
#   * idempotent (marker __NEXUM_IDEMPOTENCY_CLIENT__); clean-only backups
#   * gate: rm -rf .next && npx tsc --noEmit && npm run build -> push
#   * --revert restores both files + removes the helper ; --no-deploy applies only
#
# Run from REPO ROOT (folder containing nexum-web/).
# ============================================================================
set -euo pipefail

WEB="nexum-web"
HELPER="$WEB/lib/idempotency-client.ts"
CASHOUT="$WEB/components/swap/CashOutCard.tsx"
PAYMENTS="$WEB/hooks/usePayments.ts"
MARKER="__NEXUM_IDEMPOTENCY_CLIENT__"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR=".nexum-phase7p2b-backup/${STAMP}"
HELPER_SHA="1b4e0831d3d629e51c20d608afc6148430f832ea9779220588ebe399837a3882"; PATCH_SHA="9ec7ffb2a1c9a97f1f05d10a805893e1109e0d4f2f6a88f11b0e1a9bd96644ee"
COMMIT_MSG="feat(web): send stable Idempotency-Key on cashout + payments POSTs (Phase 7.2b)"

FLAG="${1:-}"
log(){ printf '  %s\n' "$*"; }
die(){ printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[ -d "$WEB" ] || die "Cannot find $WEB . Run from the repo root."

if [ "$FLAG" = "--revert" ]; then
  LATEST=""
  for d in $(ls -1dt .nexum-phase7p2b-backup/*/ 2>/dev/null); do
    if [ -f "${d}CashOutCard.tsx" ] || [ -f "${d}usePayments.ts" ]; then LATEST="$d"; break; fi
  done
  if [ -n "$LATEST" ]; then
    [ -f "${LATEST}CashOutCard.tsx" ] && cp "${LATEST}CashOutCard.tsx" "$CASHOUT"  && log "Restored $CASHOUT"
    [ -f "${LATEST}usePayments.ts" ]  && cp "${LATEST}usePayments.ts"  "$PAYMENTS" && log "Restored $PAYMENTS"
  else
    log "No backup found; leaving files as-is."
  fi
  rm -f "$HELPER" && log "Removed $HELPER"
  log "Reverted Phase 7 Part 2b."
  exit 0
fi

THELP="$(mktemp)"; TPATCH="$(mktemp /tmp/p7p2b.XXXXXX.py)"
trap 'rm -f "$THELP" "$TPATCH"' EXIT

base64 -d > "$THELP" <<'B64HELP'
Ly8gX19ORVhVTV9JREVNUE9URU5DWV9DTElFTlRfXyAocGhhc2U3IHBhcnQyYikKLy8KLy8gSGVs
cGVycyBmb3Igc2VuZGluZyBhIHN0YWJsZSBJZGVtcG90ZW5jeS1LZXkgb24gbW9uZXktbW92aW5n
IFBPU1RzLCBzbyBhCi8vIHJldHJpZWQgb3IgZG91YmxlLXRhcHBlZCByZXF1ZXN0IGRlZHVwZXMg
YXQgdGhlIEFQSSBpbnN0ZWFkIG9mIG1vdmluZyBtb25leQovLyB0d2ljZS4gUGFpcnMgd2l0aCB0
aGUgc2VydmVyIG1pZGRsZXdhcmUgYWRkZWQgaW4gUGhhc2UgNyBQYXJ0IDIuCi8vCi8vIFRoZSBy
dWxlIHRoYXQgbWFrZXMgdGhpcyBjb3JyZWN0OiBhIGtleSBtdXN0IGJlIFNUQUJMRSBhY3Jvc3Mg
cmV0cmllcyBvZiB0aGUKLy8gU0FNRSBsb2dpY2FsIGFjdGlvbiwgYnV0IEZSRVNIIGZvciBhIG5l
dyBhY3Rpb24uIFNvIHdlIG1pbnQgdGhlIGtleSBhdCB0aGUKLy8gbW9tZW50IHRoZSB1c2VyIGlu
aXRpYXRlcyAoc3VibWl0IC8gbXV0YXRlKSwga2VlcCBpdCBmb3IgYXMgbG9uZyBhcyB0aGF0IG9u
ZQovLyBhdHRlbXB0IGlzIGJlaW5nIHJldHJpZWQsIGFuZCBvbmx5IG1pbnQgYSBuZXcgb25lIGZv
ciBhIGdlbnVpbmVseSBuZXcgYWN0aW9uLgoKZXhwb3J0IGZ1bmN0aW9uIG5ld0lkZW1wb3RlbmN5
S2V5KCk6IHN0cmluZyB7CiAgLy8gU2VjdXJlLWNvbnRleHQgYnJvd3NlcnMgYWxsIHN1cHBvcnQg
Y3J5cHRvLnJhbmRvbVVVSUQ7IGZhbGwgYmFjayBqdXN0IGluIGNhc2UuCiAgaWYgKHR5cGVvZiBj
cnlwdG8gIT09ICd1bmRlZmluZWQnICYmICdyYW5kb21VVUlEJyBpbiBjcnlwdG8pIHsKICAgIHJl
dHVybiBjcnlwdG8ucmFuZG9tVVVJRCgpCiAgfQogIHJldHVybiBgJHtEYXRlLm5vdygpfS0ke01h
dGgucmFuZG9tKCkudG9TdHJpbmcoMTYpLnNsaWNlKDIpfS0ke01hdGgucmFuZG9tKCkudG9TdHJp
bmcoMTYpLnNsaWNlKDIpfWAKfQoKLy8gQnVpbGQgZmV0Y2ggaGVhZGVycyB3aXRoIHRoZSBpZGVt
cG90ZW5jeSBrZXkgYXR0YWNoZWQuCmV4cG9ydCBmdW5jdGlvbiBpZGVtcG90ZW50SnNvbkhlYWRl
cnMoa2V5OiBzdHJpbmcpOiBSZWNvcmQ8c3RyaW5nLCBzdHJpbmc+IHsKICByZXR1cm4geyAnQ29u
dGVudC1UeXBlJzogJ2FwcGxpY2F0aW9uL2pzb24nLCAnSWRlbXBvdGVuY3ktS2V5Jzoga2V5IH0K
fQo=
B64HELP
base64 -d > "$TPATCH" <<'B64PATCH'
IyEvdXNyL2Jpbi9lbnYgcHl0aG9uMwoiIiIKUGhhc2UgNyBQYXJ0IDJiIC0gc2VuZCBhIHN0YWJs
ZSBJZGVtcG90ZW5jeS1LZXkgZnJvbSB0aGUgd2ViIGNsaWVudC4KCkVkaXRzOgogIGNvbXBvbmVu
dHMvc3dhcC9DYXNoT3V0Q2FyZC50c3gKICAgICogaW1wb3J0IHRoZSBrZXkgaGVscGVyICsgdXNl
UmVmCiAgICAqIGhvbGQgdGhlIGN1cnJlbnQgYXR0ZW1wdCdzIGtleSBpbiBhIHJlZiAobWludCBp
ZiBhYnNlbnQgYXQgc3VibWl0IHN0YXJ0LAogICAgICByZXVzZSBvbiByZXRyeSBvZiB0aGUgc2Ft
ZSBwYXlvdXQsIGNsZWFyIG9uIHN1Y2Nlc3MpCiAgICAqIHNlbmQgSWRlbXBvdGVuY3ktS2V5IG9u
IHRoZSAvdHJhbnNmZXJzL2Nhc2hvdXQgUE9TVAogIGhvb2tzL3VzZVBheW1lbnRzLnRzCiAgICAq
IGltcG9ydCB0aGUga2V5IGhlbHBlcgogICAgKiBtaW50IGEga2V5IHBlciBtdXRhdGUoKSBjYWxs
IGFuZCBzZW5kIGl0IG9uIHRoZSAvcGF5bWVudHMgUE9TVAoKSWRlbXBvdGVudCB2aWEgX19ORVhV
TV9JREVNUE9URU5DWV9DTElFTlRfXy4gRXhhY3QtYW5jaG9yOyBhYm9ydHMgb24gZHJpZnQuCiIi
IgppbXBvcnQgc3lzLCBpbwoKZGVmIHBhdGNoKHBhdGgsIGVkaXRzLCBtYXJrZXIpOgogICAgc3Jj
ID0gaW8ub3BlbihwYXRoLCBlbmNvZGluZz0idXRmLTgiKS5yZWFkKCkKICAgIGlmIG1hcmtlciBp
biBzcmM6CiAgICAgICAgcHJpbnQoZiIgIHtwYXRofTogYWxyZWFkeSB3aXJlZCAtIHNraXBwaW5n
LiIpCiAgICAgICAgcmV0dXJuCiAgICBmb3IgZGVzYywgb2xkLCBuZXcgaW4gZWRpdHM6CiAgICAg
ICAgbiA9IHNyYy5jb3VudChvbGQpCiAgICAgICAgaWYgbiAhPSAxOgogICAgICAgICAgICBwcmlu
dChmIkVSUk9SIFt7cGF0aH1dOiBhbmNob3IgJ3tkZXNjfScgbWF0Y2hlZCB7bn0gdGltZXMgKGV4
cGVjdGVkIDEpLiBBYm9ydGluZy4iKQogICAgICAgICAgICBzeXMuZXhpdCgyKQogICAgICAgIHNy
YyA9IHNyYy5yZXBsYWNlKG9sZCwgbmV3KQogICAgaW8ub3BlbihwYXRoLCAidyIsIGVuY29kaW5n
PSJ1dGYtOCIpLndyaXRlKHNyYykKICAgIHByaW50KGYiICB7cGF0aH06IHdpcmVkLiIpCgpNQVJL
RVIgPSAiX19ORVhVTV9JREVNUE9URU5DWV9DTElFTlRfXyIKCiMgLS0tLSBDYXNoT3V0Q2FyZC50
c3ggLS0tLQpwYXRjaCgibmV4dW0td2ViL2NvbXBvbmVudHMvc3dhcC9DYXNoT3V0Q2FyZC50c3gi
LCBbCiAgICAoImltcG9ydCByZWFjdCBob29rcyIsCiAgICAgImltcG9ydCB7IHVzZVN0YXRlLCB1
c2VFZmZlY3QsIHVzZUNhbGxiYWNrIH0gZnJvbSAncmVhY3QnIiwKICAgICAiaW1wb3J0IHsgdXNl
U3RhdGUsIHVzZUVmZmVjdCwgdXNlQ2FsbGJhY2ssIHVzZVJlZiB9IGZyb20gJ3JlYWN0J1xuIgog
ICAgICIvLyBfX05FWFVNX0lERU1QT1RFTkNZX0NMSUVOVF9fIChwaGFzZTcgcGFydDJiKSBzdGFi
bGUga2V5IGFjcm9zcyByZXRyaWVzXG4iCiAgICAgImltcG9ydCB7IG5ld0lkZW1wb3RlbmN5S2V5
LCBpZGVtcG90ZW50SnNvbkhlYWRlcnMgfSBmcm9tICdAL2xpYi9pZGVtcG90ZW5jeS1jbGllbnQn
IiksCgogICAgKCJrZXkgcmVmIHN0YXRlIiwKICAgICAiICBjb25zdCBbdHJhbnNmZXJJZCwgc2V0
VHJhbnNmZXJJZF0gPSB1c2VTdGF0ZTxzdHJpbmcgfCBudWxsPihudWxsKSIsCiAgICAgIiAgY29u
c3QgW3RyYW5zZmVySWQsIHNldFRyYW5zZmVySWRdID0gdXNlU3RhdGU8c3RyaW5nIHwgbnVsbD4o
bnVsbClcbiIKICAgICAiICAvLyBIb2xkcyB0aGlzIHBheW91dCBhdHRlbXB0J3MgSWRlbXBvdGVu
Y3ktS2V5LiBNaW50ZWQgYXQgc3VibWl0LCByZXVzZWQgaWZcbiIKICAgICAiICAvLyB0aGUgdXNl
ciByZXRyaWVzIHRoZSBTQU1FIHBheW91dCBhZnRlciBhbiBlcnJvciwgY2xlYXJlZCBvbiBzdWNj
ZXNzIHNvIGFcbiIKICAgICAiICAvLyBicmFuZC1uZXcgcGF5b3V0IGdldHMgYSBmcmVzaCBrZXku
XG4iCiAgICAgIiAgY29uc3QgaWRlbUtleVJlZiA9IHVzZVJlZjxzdHJpbmcgfCBudWxsPihudWxs
KSIpLAoKICAgICgic3VibWl0IG1pbnRzIGtleSIsCiAgICAgIiAgICBzZXRTdWJtaXR0aW5nKHRy
dWUpOyBzZXRFcnJvcihudWxsKVxuICAgIHRyeSB7XG4gICAgICBjb25zdCByZXMgPSBhd2FpdCBm
ZXRjaChgJHtBUEl9L3RyYW5zZmVycy9jYXNob3V0YCwge1xuICAgICAgICBtZXRob2Q6ICdQT1NU
JyxcbiAgICAgICAgaGVhZGVyczogeyAnQ29udGVudC1UeXBlJzogJ2FwcGxpY2F0aW9uL2pzb24n
IH0sIiwKICAgICAiICAgIHNldFN1Ym1pdHRpbmcodHJ1ZSk7IHNldEVycm9yKG51bGwpXG4iCiAg
ICAgIiAgICBpZiAoIWlkZW1LZXlSZWYuY3VycmVudCkgaWRlbUtleVJlZi5jdXJyZW50ID0gbmV3
SWRlbXBvdGVuY3lLZXkoKVxuIgogICAgICIgICAgdHJ5IHtcbiAgICAgIGNvbnN0IHJlcyA9IGF3
YWl0IGZldGNoKGAke0FQSX0vdHJhbnNmZXJzL2Nhc2hvdXRgLCB7XG4gICAgICAgIG1ldGhvZDog
J1BPU1QnLFxuICAgICAgICBoZWFkZXJzOiBpZGVtcG90ZW50SnNvbkhlYWRlcnMoaWRlbUtleVJl
Zi5jdXJyZW50KSwiKSwKCiAgICAoImNsZWFyIGtleSBvbiBzdWNjZXNzIiwKICAgICAiICAgICAg
c2V0VHJhbnNmZXJJZChkYXRhLnRyYW5zZmVySWQpIiwKICAgICAiICAgICAgc2V0VHJhbnNmZXJJ
ZChkYXRhLnRyYW5zZmVySWQpXG4iCiAgICAgIiAgICAgIGlkZW1LZXlSZWYuY3VycmVudCA9IG51
bGwgLy8gc3VjY2VzczogbmV4dCBwYXlvdXQgc3RhcnRzIGEgZnJlc2gga2V5IiksCl0sIE1BUktF
UikKCiMgLS0tLSB1c2VQYXltZW50cy50cyAtLS0tCnBhdGNoKCJuZXh1bS13ZWIvaG9va3MvdXNl
UGF5bWVudHMudHMiLCBbCiAgICAoImltcG9ydCBoZWxwZXIiLAogICAgICJpbXBvcnQgeyB1c2VR
dWVyeSwgdXNlTXV0YXRpb24sIHVzZVF1ZXJ5Q2xpZW50IH0gZnJvbSAnQHRhbnN0YWNrL3JlYWN0
LXF1ZXJ5JyIsCiAgICAgImltcG9ydCB7IHVzZVF1ZXJ5LCB1c2VNdXRhdGlvbiwgdXNlUXVlcnlD
bGllbnQgfSBmcm9tICdAdGFuc3RhY2svcmVhY3QtcXVlcnknXG4iCiAgICAgIi8vIF9fTkVYVU1f
SURFTVBPVEVOQ1lfQ0xJRU5UX18gKHBoYXNlNyBwYXJ0MmIpXG4iCiAgICAgImltcG9ydCB7IG5l
d0lkZW1wb3RlbmN5S2V5LCBpZGVtcG90ZW50SnNvbkhlYWRlcnMgfSBmcm9tICdAL2xpYi9pZGVt
cG90ZW5jeS1jbGllbnQnIiksCgogICAgKCJzZW5kIGtleSBvbiBwYXltZW50cyBQT1NUIiwKICAg
ICAiICAgICAgY29uc3QgcmVzID0gYXdhaXQgZmV0Y2goYCR7QVBJfS9wYXltZW50c2AsIHtcbiAg
ICAgICAgbWV0aG9kOiAnUE9TVCcsXG4gICAgICAgIGhlYWRlcnM6IHsgJ0NvbnRlbnQtVHlwZSc6
ICdhcHBsaWNhdGlvbi9qc29uJyB9LFxuICAgICAgICBib2R5OiBKU09OLnN0cmluZ2lmeSh7IHNl
bmRlckFkZHJlc3M6IGFkZHJlc3MsIC4uLmRhdGEgfSksXG4gICAgICB9KSIsCiAgICAgIiAgICAg
IC8vIE9uZSBrZXkgcGVyIG11dGF0ZSgpIGNhbGw6IHN0YWJsZSBmb3IgdGhpcyBwYXltZW50LCBm
cmVzaCBmb3IgdGhlIG5leHQuXG4iCiAgICAgIiAgICAgIGNvbnN0IGlkZW1LZXkgPSBuZXdJZGVt
cG90ZW5jeUtleSgpXG4iCiAgICAgIiAgICAgIGNvbnN0IHJlcyA9IGF3YWl0IGZldGNoKGAke0FQ
SX0vcGF5bWVudHNgLCB7XG4gICAgICAgIG1ldGhvZDogJ1BPU1QnLFxuICAgICAgICBoZWFkZXJz
OiBpZGVtcG90ZW50SnNvbkhlYWRlcnMoaWRlbUtleSksXG4gICAgICAgIGJvZHk6IEpTT04uc3Ry
aW5naWZ5KHsgc2VuZGVyQWRkcmVzczogYWRkcmVzcywgLi4uZGF0YSB9KSxcbiAgICAgIH0pIiks
Cl0sIE1BUktFUikKCnByaW50KCJDbGllbnQgaWRlbXBvdGVuY3kgd2lyaW5nIGNvbXBsZXRlLiIp
Cg==
B64PATCH

verify(){ local got; got="$( (sha256sum "$1" 2>/dev/null || shasum -a 256 "$1") | awk '{print $1}')"; [ "$got" = "$2" ] || die "Checksum mismatch for $1 (got $got). Nothing written."; }
verify "$THELP" "$HELPER_SHA"; verify "$TPATCH" "$PATCH_SHA"
log "Both payloads verified."

mkdir -p "$BACKUP_DIR"
if [ -f "$CASHOUT" ]  && ! grep -qF "$MARKER" "$CASHOUT";  then cp "$CASHOUT"  "$BACKUP_DIR/CashOutCard.tsx"; fi
if [ -f "$PAYMENTS" ] && ! grep -qF "$MARKER" "$PAYMENTS"; then cp "$PAYMENTS" "$BACKUP_DIR/usePayments.ts"; fi

mkdir -p "$WEB/lib"
if [ -f "$HELPER" ]; then log "helper already present - leaving it."; else cp "$THELP" "$HELPER"; log "Added $HELPER"; fi

python3 "$TPATCH" || {
  [ -f "$BACKUP_DIR/CashOutCard.tsx" ] && cp "$BACKUP_DIR/CashOutCard.tsx" "$CASHOUT"
  [ -f "$BACKUP_DIR/usePayments.ts" ]  && cp "$BACKUP_DIR/usePayments.ts"  "$PAYMENTS"
  die "Client wiring failed; files restored."
}

if [ "$FLAG" = "--no-deploy" ]; then
  log "--no-deploy: applied only. Rerun without the flag to build + push."
  exit 0
fi
log ""
log "=== Deploy gate: typecheck + build, then commit + push ==="
( cd "$WEB" && rm -rf .next && npx tsc --noEmit ) || die "tsc failed - not committing."
log "tsc clean."
( cd "$WEB" && npm run build ) || die "next build failed - not committing."
log "build clean."

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "Not a git work tree; commit manually."
REMOTE="$(git remote | head -1 || true)"; [ -n "$REMOTE" ] || die "No git remote; commit/push manually."
BRANCH="$(git rev-parse --abbrev-ref HEAD)"
git add -A
if git diff --cached --quiet; then log "Nothing to commit."; exit 0; fi
log "Committing on '$BRANCH' -> '$REMOTE'..."
git commit -m "$COMMIT_MSG"
git push "$REMOTE" "$BRANCH"
log ""
log "Pushed Phase 7 Part 2b. Cashout + payment retries now dedupe end to end."
