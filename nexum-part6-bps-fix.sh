#!/usr/bin/env bash
# ============================================================================
# Nexum bridge upgrade - PART 6: fix fractional-bps crash that hid Fast + fees
#
# THE ACTUAL BUG (this is why Base/Arbitrum/OP/Unichain showed no speed toggle
# and no fees, while Arc/Polygon/Monad worked fine):
#
#   feeUnits was  (amountUnits * BigInt(feeBps)) / 10000n
#   Circle returns the Fast fee as a DECIMAL basis-point value (e.g. 0.5, 0.01,
#   up to 1.4). BigInt(0.5) throws RangeError, which aborted the entire quote -
#   but ONLY on Fast-capable chains, because the non-Fast chains have feeBps = 0
#   and never enter the throwing branch. Hence the symptom hit exactly the four
#   Fast chains and no others.
#
# THE FIX: compute feeUnits the decimal-safe way maxFeeFor already uses:
#   amount * round(bps * 100) / 1_000_000
# Never calls BigInt() on a non-integer. Integer bps results are unchanged.
#
# Touches only nexum-web/lib/cctp-client.ts (both identical fee-math lines).
# REQUIRES Parts 1-5.
#
# Delivery contract (your v2 spec) + full deploy:
#   * patcher base64 + sha256 verified before running
#   * exact-match on the buggy line(s); aborts clean if not found
#   * idempotent (__NEXUM_BPS_DECIMAL_FIX__); timestamped backup
#   * deploy GATE: (web) rm -rf .next && npx tsc --noEmit && npm run build -> push
#   * --revert restores the file ; --no-deploy applies only
#
# Run from REPO ROOT (folder containing nexum-web/).
#   bash nexum-part6-bps-fix.sh
#   bash nexum-part6-bps-fix.sh --no-deploy
#   bash nexum-part6-bps-fix.sh --revert
# ============================================================================
set -euo pipefail

TARGET="nexum-web/lib/cctp-client.ts"
MARKER="__NEXUM_BPS_DECIMAL_FIX__"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR=".nexum-part6-backup/${STAMP}"
EXPECT_SHA="7bcb4193621063d39618124d42ded3c780d28b8716eac94f0af2162aef570704"
COMMIT_MSG="fix(bridge): handle fractional-bps Fast fee (BigInt crash hid toggle+fees on Base/Arbitrum/OP/Unichain) (Part 6)"

FLAG="${1:-}"
log(){ printf '  %s\n' "$*"; }
die(){ printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[ -f "$TARGET" ] || die "Cannot find $TARGET . Run from the repo root (folder containing nexum-web/)."

if [ "$FLAG" = "--revert" ]; then
  LATEST="$(ls -1dt .nexum-part6-backup/*/ 2>/dev/null | head -1 || true)"
  [ -n "$LATEST" ] && [ -f "${LATEST}cctp-client.ts" ] || die "No Part 6 backup found."
  cp "${LATEST}cctp-client.ts" "$TARGET"
  log "Reverted $TARGET"
  exit 0
fi

grep -qF "__NEXUM_CCTP_QUOTE_ENGINE__" "$TARGET" || die "Parts 1-5 not applied. Apply them first."

if grep -qF "$MARKER" "$TARGET"; then
  log "Part 6 already applied - skipping edit."
else
  TMP="$(mktemp /tmp/nexum-part6.XXXXXX.py)"; trap 'rm -f "$TMP"' EXIT
  base64 -d > "$TMP" <<'B64'
IyEvdXNyL2Jpbi9lbnYgcHl0aG9uMwoiIiIKUGFydCA2IHBhdGNoZXIgZm9yIG5leHVtLXdlYi9s
aWIvY2N0cC1jbGllbnQudHMKClRIRSBCVUc6IGZlZVVuaXRzIHdhcyBjb21wdXRlZCBhcyAgKGFt
b3VudFVuaXRzICogQmlnSW50KGZlZUJwcykpIC8gMTAwMDBuIC4KQ2lyY2xlIHJldHVybnMgdGhl
IEZhc3QtVHJhbnNmZXIgZmVlIGFzIGEgREVDSU1BTCBiYXNpcy1wb2ludCB2YWx1ZSAoZS5nLiAw
LjUsCjAuMDEsIDEuNCkuIEJpZ0ludCgwLjUpIHRocm93cyBSYW5nZUVycm9yLCB3aGljaCBhYm9y
dGVkIHRoZSB3aG9sZSBxdW90ZSAtIGJ1dApPTkxZIG9uIEZhc3QtY2FwYWJsZSBjaGFpbnMgKGJh
c2UvYXJiaXRydW0vb3B0aW1pc20vdW5pY2hhaW4pLCBiZWNhdXNlIG9uIHRoZQpub24tRmFzdCBj
aGFpbnMgZmVlQnBzIGlzIDAgYW5kIHRoZSB0aHJvd2luZyBicmFuY2ggaXMgc2tpcHBlZC4gVGhh
dCBpcyB3aHkgdGhlCnNwZWVkIHRvZ2dsZSBhbmQgZmVlIHBhbmVsIHNpbGVudGx5IHZhbmlzaGVk
IG9uIGV4YWN0bHkgdGhvc2UgZm91ciBjaGFpbnMuCgpUSEUgRklYOiB1c2UgdGhlIHNhbWUgZGVj
aW1hbC1zYWZlIHNjYWxpbmcgbWF4RmVlRm9yIGFscmVhZHkgdXNlcyAtCiAgYW1vdW50ICogcm91
bmQoYnBzICogMTAwKSAvIDFfMDAwXzAwMAp3aGljaCBwcmVzZXJ2ZXMgZnJhY3Rpb25hbCBicHMg
YW5kIG5ldmVyIGNhbGxzIEJpZ0ludCgpIG9uIGEgbm9uLWludGVnZXIuCgpCb3RoIGlkZW50aWNh
bCBvY2N1cnJlbmNlcyAoZ2V0VHJhbnNmZXJRdW90ZSBhbmQgZ2V0Qm90aFF1b3RlcycgYnVpbGQp
IGFyZQpyZXBsYWNlZC4gSWRlbXBvdGVudCB2aWEgX19ORVhVTV9CUFNfREVDSU1BTF9GSVhfXy4K
IiIiCmltcG9ydCBzeXMsIGlvClBBVEggPSBzeXMuYXJndlsxXSBpZiBsZW4oc3lzLmFyZ3YpID4g
MSBlbHNlICJuZXh1bS13ZWIvbGliL2NjdHAtY2xpZW50LnRzIgpNQVJLRVIgPSAiX19ORVhVTV9C
UFNfREVDSU1BTF9GSVhfXyIKc3JjID0gaW8ub3BlbihQQVRILCBlbmNvZGluZz0idXRmLTgiKS5y
ZWFkKCkKaWYgTUFSS0VSIGluIHNyYzoKICAgIHByaW50KCIgIFBhcnQgNiBhbHJlYWR5IGFwcGxp
ZWQgLSBub3RoaW5nIHRvIGRvLiIpCiAgICBzeXMuZXhpdCgwKQoKQlVHR1kgPSAiICAgIGZlZUJw
cyA+IDAgPyAoYW1vdW50VW5pdHMgKiBCaWdJbnQoZmVlQnBzKSkgLyBCaWdJbnQoMTAwMDApIDog
QmlnSW50KDApIgpGSVhFRCA9ICIgICAgLy8gX19ORVhVTV9CUFNfREVDSU1BTF9GSVhfXyAocGFy
dDYpIGJwcyBjYW4gYmUgZnJhY3Rpb25hbCAoZS5nLiAwLjUpIC0gc2NhbGVcbiAgICAvLyBieSBy
b3VuZChicHMqMTAwKS8xXzAwMF8wMDAgc28gQmlnSW50KCkgbmV2ZXIgc2VlcyBhIG5vbi1pbnRl
Z2VyLlxuICAgIGZlZUJwcyA+IDBcbiAgICAgID8gKGFtb3VudFVuaXRzICogQmlnSW50KE1hdGgu
cm91bmQoZmVlQnBzICogMTAwKSkpIC8gQmlnSW50KDEwMDAwMDApXG4gICAgICA6IEJpZ0ludCgw
KSIKCiMgVGhlcmUgYXJlIHR3byBvY2N1cnJlbmNlcyBhdCBzbGlnaHRseSBkaWZmZXJlbnQgaW5k
ZW50YXRpb24/IENvbmZpcm0uCiMgTGluZSA0MDggaGFzIDQtc3BhY2UgaW5kZW50LCBsaW5lIDQ0
NCBoYXMgNi1zcGFjZSBpbmRlbnQgcGVyIGdyZXAuIEhhbmRsZSBib3RoLgp2YXJpYW50cyA9IFsK
ICAgICgiICAgIGZlZUJwcyA+IDAgPyAoYW1vdW50VW5pdHMgKiBCaWdJbnQoZmVlQnBzKSkgLyBC
aWdJbnQoMTAwMDApIDogQmlnSW50KDApIiwKICAgICAiICAgIC8vIF9fTkVYVU1fQlBTX0RFQ0lN
QUxfRklYX18gKHBhcnQ2KSBicHMgY2FuIGJlIGZyYWN0aW9uYWwgKGUuZy4gMC41KTsgc2NhbGVc
biAgICAvLyBieSByb3VuZChicHMqMTAwKS8xXzAwMF8wMDAgc28gQmlnSW50KCkgbmV2ZXIgc2Vl
cyBhIG5vbi1pbnRlZ2VyLlxuICAgIGZlZUJwcyA+IDBcbiAgICAgID8gKGFtb3VudFVuaXRzICog
QmlnSW50KE1hdGgucm91bmQoZmVlQnBzICogMTAwKSkpIC8gQmlnSW50KDEwMDAwMDApXG4gICAg
ICA6IEJpZ0ludCgwKSIpLAogICAgKCIgICAgICBmZWVCcHMgPiAwID8gKGFtb3VudFVuaXRzICog
QmlnSW50KGZlZUJwcykpIC8gQmlnSW50KDEwMDAwKSA6IEJpZ0ludCgwKSIsCiAgICAgIiAgICAg
IC8vIF9fTkVYVU1fQlBTX0RFQ0lNQUxfRklYX18gKHBhcnQ2KSBicHMgY2FuIGJlIGZyYWN0aW9u
YWwgKGUuZy4gMC41KTsgc2NhbGVcbiAgICAgIC8vIGJ5IHJvdW5kKGJwcyoxMDApLzFfMDAwXzAw
MCBzbyBCaWdJbnQoKSBuZXZlciBzZWVzIGEgbm9uLWludGVnZXIuXG4gICAgICBmZWVCcHMgPiAw
XG4gICAgICAgID8gKGFtb3VudFVuaXRzICogQmlnSW50KE1hdGgucm91bmQoZmVlQnBzICogMTAw
KSkpIC8gQmlnSW50KDEwMDAwMDApXG4gICAgICAgIDogQmlnSW50KDApIiksCl0KCnRvdGFsID0g
MApmb3Igb2xkLCBuZXcgaW4gdmFyaWFudHM6CiAgICBjID0gc3JjLmNvdW50KG9sZCkKICAgIGlm
IGM6CiAgICAgICAgc3JjID0gc3JjLnJlcGxhY2Uob2xkLCBuZXcpCiAgICAgICAgdG90YWwgKz0g
YwoKaWYgdG90YWwgPT0gMDoKICAgIHByaW50KCJFUlJPUjogbm8gb2NjdXJyZW5jZSBvZiB0aGUg
YnVnZ3kgZmVlLW1hdGggbGluZSBmb3VuZC4gQWJvcnRpbmcuIikKICAgIHN5cy5leGl0KDIpCmlm
IE1BUktFUiBub3QgaW4gc3JjOgogICAgcHJpbnQoIkVSUk9SOiBtYXJrZXIgbm90IHByZXNlbnQg
YWZ0ZXIgcmVwbGFjZS4gQWJvcnRpbmcuIikKICAgIHN5cy5leGl0KDIpCgppby5vcGVuKFBBVEgs
ICJ3IiwgZW5jb2Rpbmc9InV0Zi04Iikud3JpdGUoc3JjKQpwcmludChmIiAgUGFydCA2IGFwcGxp
ZWQgdG8ge1BBVEh9ICh7dG90YWx9IG9jY3VycmVuY2UocykgZml4ZWQpIikK
B64
  ACTUAL_SHA="$( (sha256sum "$TMP" 2>/dev/null || shasum -a 256 "$TMP") | awk '{print $1}')"
  [ "$ACTUAL_SHA" = "$EXPECT_SHA" ] || die "Patcher checksum mismatch (got $ACTUAL_SHA). File NOT modified."
  log "Patcher verified."
  mkdir -p "$BACKUP_DIR"; cp "$TARGET" "$BACKUP_DIR/cctp-client.ts"
  python3 "$TMP" "$TARGET" || { cp "$BACKUP_DIR/cctp-client.ts" "$TARGET"; die "Patch failed; restored."; }
  grep -qF "$MARKER" "$TARGET" || { cp "$BACKUP_DIR/cctp-client.ts" "$TARGET"; die "Post-write check failed; restored."; }
  # belt-and-braces: no buggy pattern should survive
  if grep -q "BigInt(feeBps)" "$TARGET"; then cp "$BACKUP_DIR/cctp-client.ts" "$TARGET"; die "A buggy BigInt(feeBps) remained; restored."; fi
  log "Applied Part 6 to $TARGET."
fi

if [ "$FLAG" = "--no-deploy" ]; then
  log "--no-deploy: applied only. Review, then rerun without the flag to ship."
  exit 0
fi

log ""
log "=== Deploy gate: typecheck + build, then commit + push ==="
( cd nexum-web && rm -rf .next && npx tsc --noEmit ) || die "tsc failed - not committing."
log "tsc clean."
( cd nexum-web && npm run build ) || die "next build failed - not committing."
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
log "Pushed Part 6. Base/Arbitrum/OP/Unichain should now show the speed toggle,"
log "the Fast fee, you-receive, and ETA when you enter an amount."
