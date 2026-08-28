#!/usr/bin/env bash
# ============================================================================
# Nexum bridge - remove interval auto-refresh (Issue 1 of 2)
#
# Two pollers burdened the API/Circle on every render while a bridge was pending:
#   1. BridgeHistory: setInterval(load, 20_000) - refetched the WHOLE bridge
#      history every 20s while any row was in progress.
#   2. useAttestationStatus: setInterval(check, 30_000) - hit Circle's
#      attestation API every 30s for each pending row.
#
# Both are removed. History now updates ONLY via:
#   * the manual Refresh button (unchanged), and
#   * the existing completion trigger finish.step === 'done' -> load(), which
#     fires exactly when a mint is confirmed minted on the destination.
# That is exactly the "auto-refresh only on confirmed completion" you asked for.
#
# SAFETY (verified): the 4 live steps (Approve, Burn, Wait for attest, Mint)
# have their OWN self-contained polling inside useBridge / useCompleteBridge and
# do NOT depend on either poller. useAttestationStatus is imported only by
# BridgeHistory (display), never by the live flow. So removing the intervals
# cannot break the bridge flow. useAttestationStatus keeps its one-shot on-mount
# check and its manual `refresh`.
#
# Edits:
#   nexum-web/components/bridge/BridgeHistory.tsx  - remove the 20s interval
#   nexum-web/hooks/useAttestationStatus.ts        - remove the 30s interval + POLL_MS
#
# Delivery contract (v2) + full deploy:
#   * patcher base64 + sha256 verified; exact-anchor; aborts on drift
#   * idempotent (marker __NEXUM_NO_AUTO_REFRESH__); clean-only backups
#   * gate: rm -rf .next && npx tsc --noEmit && npm run build -> commit + push
#   * --revert restores both files ; --no-deploy applies only
#
# Run from REPO ROOT (folder containing nexum-web/).
#   bash nexum-bridge-remove-auto-refresh.sh
#   bash nexum-bridge-remove-auto-refresh.sh --no-deploy
#   bash nexum-bridge-remove-auto-refresh.sh --revert
# ============================================================================
set -euo pipefail

WEB="nexum-web"
BH="$WEB/components/bridge/BridgeHistory.tsx"
UAS="$WEB/hooks/useAttestationStatus.ts"
MARKER="__NEXUM_NO_AUTO_REFRESH__"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR=".nexum-noautorefresh-backup/${STAMP}"
PATCH_SHA="d888e39c1067dd6dd034e06aa373af6cbe72691f869fcc5a8fd2b4871cf70a6b"
COMMIT_MSG="perf(bridge): remove interval auto-refresh; update history on manual + confirmed-completion only"

FLAG="${1:-}"
log(){ printf '  %s\n' "$*"; }
die(){ printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[ -d "$WEB" ] || die "Cannot find $WEB . Run from the repo root."

if [ "$FLAG" = "--revert" ]; then
  LATEST=""
  for d in $(ls -1dt .nexum-noautorefresh-backup/*/ 2>/dev/null); do
    if [ -f "${d}BridgeHistory.tsx" ] || [ -f "${d}useAttestationStatus.ts" ]; then LATEST="$d"; break; fi
  done
  if [ -n "$LATEST" ]; then
    [ -f "${LATEST}BridgeHistory.tsx" ]       && cp "${LATEST}BridgeHistory.tsx"       "$BH"  && log "Restored $BH"
    [ -f "${LATEST}useAttestationStatus.ts" ] && cp "${LATEST}useAttestationStatus.ts" "$UAS" && log "Restored $UAS"
  else
    log "No backup found; leaving files as-is."
  fi
  log "Reverted auto-refresh removal."
  exit 0
fi

TPATCH="$(mktemp /tmp/noautoref.XXXXXX.py)"
trap 'rm -f "$TPATCH"' EXIT
base64 -d > "$TPATCH" <<'B64'
IyEvdXNyL2Jpbi9lbnYgcHl0aG9uMwoiIiIKUmVtb3ZlIGludGVydmFsLWJhc2VkIGJyaWRnZSBh
dXRvLXJlZnJlc2g7IGtlZXAgbWFudWFsICsgY29tcGxldGlvbi1kcml2ZW4uCgpUd28gcG9sbGVy
cyBhZGRlZCBBUEkvQ2lyY2xlIGxvYWQgb24gZXZlcnkgcmVuZGVyIHdoaWxlIGEgYnJpZGdlIHdh
cyBwZW5kaW5nOgogIDEuIEJyaWRnZUhpc3Rvcnk6IHNldEludGVydmFsKGxvYWQsIDIwXzAwMCkg
LSByZWZldGNoZWQgdGhlIFdIT0xFIGhpc3RvcnkKICAgICBldmVyeSAyMHMgd2hpbGUgYW55IHJv
dyB3YXMgaW4gcHJvZ3Jlc3MuCiAgMi4gdXNlQXR0ZXN0YXRpb25TdGF0dXM6IHNldEludGVydmFs
KGNoZWNrLCAzMF8wMDApIC0gaGl0IENpcmNsZSdzIGF0dGVzdGF0aW9uCiAgICAgQVBJIGV2ZXJ5
IDMwcyBmb3IgZWFjaCBwZW5kaW5nIHJvdy4KCk5laXRoZXIgaXMgbmVlZGVkLiBUaGUgNCBsaXZl
IHN0ZXBzIChBcHByb3ZlLCBCdXJuLCBBdHRlc3Qgd2FpdCwgTWludCkgaGF2ZQp0aGVpciBPV04g
c2VsZi1jb250YWluZWQgcG9sbGluZyBpbnNpZGUgdXNlQnJpZGdlIC8gdXNlQ29tcGxldGVCcmlk
Z2UgYW5kIGRvIE5PVApkZXBlbmQgb24gdGhlc2UgLSBzbyByZW1vdmluZyB0aGVtIGNhbm5vdCBi
cmVhayB0aGUgbGl2ZSBmbG93LiBIaXN0b3J5IHVwZGF0ZXMKbm93IGNvbWUgZnJvbToKICAqIHRo
ZSBtYW51YWwgUmVmcmVzaCBidXR0b24gKGxvYWQpLCBhbmQKICAqIHRoZSBFWElTVElORyBjb21w
bGV0aW9uIHRyaWdnZXI6IGZpbmlzaC5zdGVwID09PSAnZG9uZScgLT4gbG9hZCgpLCB3aGljaAog
ICAgZmlyZXMgZXhhY3RseSB3aGVuIGEgbWludCBjb25maXJtcyBzdWNjZXNzZnVsbHkgbWludGVk
IG9uIHRoZSBkZXN0aW5hdGlvbi4KVGhhdCBpcyBwcmVjaXNlbHkgImF1dG8tcmVmcmVzaCBvbmx5
IHdoZW4gYSB0cmFuc2FjdGlvbiBpcyBjb25maXJtZWQgY29tcGxldGUuIgoKdXNlQXR0ZXN0YXRp
b25TdGF0dXMga2VlcHMgaXRzIG9uZS10aW1lIG9uLW1vdW50IGNoZWNrICsgaXRzIG1hbnVhbCBg
cmVmcmVzaGAsCmp1c3Qgd2l0aG91dCB0aGUgcmVwZWF0aW5nIGludGVydmFsLgoKSWRlbXBvdGVu
dCB2aWEgX19ORVhVTV9OT19BVVRPX1JFRlJFU0hfXy4gRXhhY3QtYW5jaG9yOyBhYm9ydHMgb24g
ZHJpZnQuCiIiIgppbXBvcnQgc3lzLCBpbwoKZGVmIHBhdGNoKHBhdGgsIGVkaXRzLCBtYXJrZXIp
OgogICAgc3JjID0gaW8ub3BlbihwYXRoLCBlbmNvZGluZz0idXRmLTgiKS5yZWFkKCkKICAgIGlm
IG1hcmtlciBpbiBzcmM6CiAgICAgICAgcHJpbnQoZiIgIHtwYXRofTogYWxyZWFkeSBwYXRjaGVk
IC0gc2tpcHBpbmcuIikKICAgICAgICByZXR1cm4KICAgIGZvciBkZXNjLCBvbGQsIG5ldyBpbiBl
ZGl0czoKICAgICAgICBuID0gc3JjLmNvdW50KG9sZCkKICAgICAgICBpZiBuICE9IDE6CiAgICAg
ICAgICAgIHByaW50KGYiRVJST1IgW3twYXRofV06IGFuY2hvciAne2Rlc2N9JyBtYXRjaGVkIHtu
fSB0aW1lcyAoZXhwZWN0ZWQgMSkuIEFib3J0aW5nLiIpCiAgICAgICAgICAgIHN5cy5leGl0KDIp
CiAgICAgICAgc3JjID0gc3JjLnJlcGxhY2Uob2xkLCBuZXcpCiAgICBpby5vcGVuKHBhdGgsICJ3
IiwgZW5jb2Rpbmc9InV0Zi04Iikud3JpdGUoc3JjKQogICAgcHJpbnQoZiIgIHtwYXRofTogcGF0
Y2hlZC4iKQoKTUFSS0VSID0gIl9fTkVYVU1fTk9fQVVUT19SRUZSRVNIX18iCgojIDEuIEJyaWRn
ZUhpc3Rvcnk6IGRyb3AgdGhlIDIwcyBpbnRlcnZhbDsga2VlcCB0aGUgJ2RvbmUnIHJlZnJlc2gg
KyBtYW51YWwgbG9hZC4KcGF0Y2goIm5leHVtLXdlYi9jb21wb25lbnRzL2JyaWRnZS9CcmlkZ2VI
aXN0b3J5LnRzeCIsIFsKICAgICgicmVtb3ZlIGhpc3RvcnkgaW50ZXJ2YWwiLAogICAgICIgIC8v
IFBvbGwgd2hpbGUgYW55dGhpbmcgaXMgc3RpbGwgbW92aW5nLCBzbyBhIGNvbXBsZXRlZCBtaW50
IGFwcGVhcnMgd2l0aG91dCBhXG4iCiAgICAgIiAgLy8gbWFudWFsIHJlZnJlc2guXG4iCiAgICAg
IiAgdXNlRWZmZWN0KCgpID0+IHtcbiIKICAgICAiICAgIGNvbnN0IHBlbmRpbmcgPSByb3dzLnNv
bWUociA9PlxuIgogICAgICIgICAgICBbJ2F0dGVzdGluZycsICdtaW50aW5nJywgJ3N0cmFuZGVk
JywgJ2J1cm5pbmcnXS5pbmNsdWRlcyhyLnN0YXR1cykpXG4iCiAgICAgIiAgICBpZiAoIXBlbmRp
bmcpIHJldHVyblxuIgogICAgICIgICAgY29uc3QgdCA9IHNldEludGVydmFsKGxvYWQsIDIwXzAw
MClcbiIKICAgICAiICAgIHJldHVybiAoKSA9PiBjbGVhckludGVydmFsKHQpXG4iCiAgICAgIiAg
fSwgW3Jvd3MsIGxvYWRdKVxuXG4iLAogICAgICIgIC8vIF9fTkVYVU1fTk9fQVVUT19SRUZSRVNI
X18gaW50ZXJ2YWwtYmFzZWQgYXV0by1yZWZyZXNoIHJlbW92ZWQgLSBpdFxuIgogICAgICIgIC8v
IHJlZmV0Y2hlZCB0aGUgd2hvbGUgaGlzdG9yeSBldmVyeSAyMHMgYW5kIGJ1cmRlbmVkIHRoZSBB
UEkuIEhpc3RvcnlcbiIKICAgICAiICAvLyBub3cgdXBkYXRlcyBvbiB0aGUgbWFudWFsIFJlZnJl
c2ggYnV0dG9uIGFuZCBvbiB0aGUgY29tcGxldGlvbiB0cmlnZ2VyXG4iCiAgICAgIiAgLy8gYWJv
dmUgKGZpbmlzaC5zdGVwID09PSAnZG9uZScpLCB3aGljaCBmaXJlcyBleGFjdGx5IHdoZW4gYSBt
aW50IGlzXG4iCiAgICAgIiAgLy8gY29uZmlybWVkIG9uIHRoZSBkZXN0aW5hdGlvbi4gVGhlIGxp
dmUgc3RlcHMgcG9sbCB0aGVtc2VsdmVzLlxuXG4iKSwKXSwgTUFSS0VSKQoKIyAyLiB1c2VBdHRl
c3RhdGlvblN0YXR1czogZHJvcCB0aGUgaW50ZXJ2YWw7IGtlZXAgdGhlIG9uZS1zaG90IGNoZWNr
ICsgcmVmcmVzaC4KcGF0Y2goIm5leHVtLXdlYi9ob29rcy91c2VBdHRlc3RhdGlvblN0YXR1cy50
cyIsIFsKICAgICgicmVtb3ZlIFBPTExfTVMgY29uc3QiLAogICAgICJjb25zdCBQT0xMX01TID0g
MzBfMDAwXG4iLAogICAgICIvLyBfX05FWFVNX05PX0FVVE9fUkVGUkVTSF9fIFBPTExfTVMgcmVt
b3ZlZCB3aXRoIHRoZSByZXBlYXRpbmcgaW50ZXJ2YWwuXG4iKSwKICAgICgicmVtb3ZlIGF0dGVz
dGF0aW9uIGludGVydmFsIiwKICAgICAiICB1c2VFZmZlY3QoKCkgPT4ge1xuIgogICAgICIgICAg
Y2hlY2soKVxuIgogICAgICIgICAgY29uc3QgdCA9IHNldEludGVydmFsKGNoZWNrLCBQT0xMX01T
KVxuIgogICAgICIgICAgcmV0dXJuICgpID0+IGNsZWFySW50ZXJ2YWwodClcbiIKICAgICAiICB9
LCBbY2hlY2tdKSIsCiAgICAgIiAgLy8gX19ORVhVTV9OT19BVVRPX1JFRlJFU0hfXyBydW4gb25j
ZSBvbiBtb3VudDsgbm8gcmVwZWF0aW5nIGludGVydmFsLlxuIgogICAgICIgIC8vIENhbGxlcnMg
cmVmcmVzaCBleHBsaWNpdGx5IHZpYSB0aGUgcmV0dXJuZWQgYHJlZnJlc2hgIChtYW51YWwgYnV0
dG9uKVxuIgogICAgICIgIC8vIG9yIHdoZW4gYSBjb21wbGV0aW9uIGV2ZW50IGxhbmRzLiBUaGlz
IHN0b3BzIHBlci1yb3cgQ2lyY2xlIHBvbGxpbmcuXG4iCiAgICAgIiAgdXNlRWZmZWN0KCgpID0+
IHtcbiIKICAgICAiICAgIGNoZWNrKClcbiIKICAgICAiICB9LCBbY2hlY2tdKSIpLApdLCBNQVJL
RVIpCgpwcmludCgiQXV0by1yZWZyZXNoIHJlbW92YWwgY29tcGxldGUuIikK
B64
ACTUAL="$( (sha256sum "$TPATCH" 2>/dev/null || shasum -a 256 "$TPATCH") | awk '{print $1}')"
[ "$ACTUAL" = "$PATCH_SHA" ] || die "Patcher checksum mismatch (got $ACTUAL). Nothing changed."
log "Patcher verified."

mkdir -p "$BACKUP_DIR"
[ -f "$BH" ]  && ! grep -qF "$MARKER" "$BH"  && cp "$BH"  "$BACKUP_DIR/BridgeHistory.tsx"       || true
[ -f "$UAS" ] && ! grep -qF "$MARKER" "$UAS" && cp "$UAS" "$BACKUP_DIR/useAttestationStatus.ts" || true

python3 "$TPATCH" || {
  [ -f "$BACKUP_DIR/BridgeHistory.tsx" ]       && cp "$BACKUP_DIR/BridgeHistory.tsx"       "$BH"
  [ -f "$BACKUP_DIR/useAttestationStatus.ts" ] && cp "$BACKUP_DIR/useAttestationStatus.ts" "$UAS"
  die "Patch failed; files restored."
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
log "Pushed. Bridge history no longer polls on a timer - it refreshes on the"
log "Refresh button and when a mint is confirmed complete. Live steps unaffected."
