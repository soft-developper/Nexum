#!/usr/bin/env bash
# ============================================================================
# Nexum Phase 7 (Hardening) - Part 5: monitoring + alerting for money flows
#
# A cron job that watches the signals the roadmap named and ALERTS through the
# structured logger + Sentry capture (Part 3), so problems surface instead of
# sitting silent in the DB:
#   * failed_transfers  - a burst of failed transfers in the last window
#   * stuck_legs        - legs in_flight past a threshold (should have advanced)
#   * stuck_transfers   - transfers in_progress past a threshold
#   (balance_drift is left as a clearly-marked seam - it needs a ledger expected
#    balance to compare against, which does not exist as one query yet.)
#
# Read-only: it detects + alerts, it does NOT mutate money state. Mirrors the
# existing job pattern (treasuryChecker/txSettler) and runs every 5 minutes.
#
# REQUIRES Phase 7 Part 3 (the logger at src/lib/logger.ts). This script checks
# for it and aborts if missing.
#
# Ships:
#   NEW  nexum-api/src/jobs/monitor.ts    startMonitor + runChecks
#   NEW  nexum-api/tests/monitor.test.ts  7 tests (each check fires/quiet correctly)
#   PATCH src/index.ts                    mount startMonitor() with the other jobs
#
# CONFIG (optional): MONITOR_FAILED_LOOKBACK_MIN / MONITOR_FAILED_ALERT_COUNT /
#                    MONITOR_STUCK_MINUTES
#
# Delivery contract (v2) + full deploy:
#   * payloads base64 + sha256 verified; exact-anchor patch; aborts on drift
#   * idempotent (marker __NEXUM_MONITOR_WIRED__); clean-only backup of index.ts
#   * gate: tsc --noEmit -> vitest run -> commit + push
#   * --revert removes the job + test + restores index.ts
#   * --no-deploy applies + verifies only
#
# Run from REPO ROOT (folder containing nexum-api/).
#   bash nexum-phase7-part5-monitoring.sh
#   bash nexum-phase7-part5-monitoring.sh --no-deploy
#   bash nexum-phase7-part5-monitoring.sh --revert
# ============================================================================
set -euo pipefail

API="nexum-api"
MON="$API/src/jobs/monitor.ts"
MON_TEST="$API/tests/monitor.test.ts"
IDX="$API/src/index.ts"
MARKER="__NEXUM_MONITOR_WIRED__"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR=".nexum-phase7p5-backup/${STAMP}"
MON_SHA="17b7d8802efe1829e63a79a10270645541189e8d711cad10ed3a08694a636878"; TEST_SHA="075801abdeffb8c60c6b760c54dac5a7d53be81a8e145e6f93ac54c8b0744131"; PATCH_SHA="b8cd2a4ee0c8529f935ff5b101d103d5ea8beda9256ad3878966098e357f08eb"
COMMIT_MSG="feat(api): money-flow monitoring + alerting (failed/stuck transfers + legs) (Phase 7.5)"

FLAG="${1:-}"
log(){ printf '  %s\n' "$*"; }
die(){ printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[ -d "$API" ] || die "Cannot find $API . Run from the repo root."

if [ "$FLAG" = "--revert" ]; then
  LATEST=""
  for d in $(ls -1dt .nexum-phase7p5-backup/*/ 2>/dev/null); do
    if [ -f "${d}index.ts" ]; then LATEST="$d"; break; fi
  done
  [ -n "$LATEST" ] && [ -f "${LATEST}index.ts" ] && cp "${LATEST}index.ts" "$IDX" && log "Restored $IDX" || log "No index.ts backup; leaving as-is."
  rm -f "$MON" && log "Removed $MON"
  rm -f "$MON_TEST" && log "Removed $MON_TEST"
  log "Reverted Phase 7 Part 5."
  exit 0
fi

# precondition: Part 3 logger
[ -f "$API/src/lib/logger.ts" ] || die "Part 3 logger ($API/src/lib/logger.ts) not found. Apply Phase 7 Part 3 first."

TMON="$(mktemp)"; TTEST="$(mktemp)"; TPATCH="$(mktemp /tmp/p7p5.XXXXXX.py)"
trap 'rm -f "$TMON" "$TTEST" "$TPATCH"' EXIT

base64 -d > "$TMON" <<'B64MON'
Ly8gX19ORVhVTV9NT05JVE9SX18gKHBoYXNlNykgbW9uaXRvcmluZyArIGFsZXJ0aW5nIGZvciBt
b25leSBmbG93cwovLwovLyBQaGFzZSA3IEhhcmRlbmluZy4gQSBjcm9uIGpvYiB0aGF0IHdhdGNo
ZXMgdGhlIHNpZ25hbHMgdGhlIHJvYWRtYXAgbmFtZWQgLQovLyBmYWlsZWQgdHJhbnNmZXJzLCBz
dHVjayBsZWdzLCBhbmQgYmFsYW5jZSBkcmlmdCAtIGFuZCBBTEVSVFMgdGhyb3VnaCB0aGUKLy8g
c3RydWN0dXJlZCBsb2dnZXIgKyBTZW50cnkgY2FwdHVyZSAoUGFydCAzKSwgc28gYSB3ZWRnZWQg
cGF5b3V0IG9yIGEgcnVuIG9mCi8vIGZhaWx1cmVzIHN1cmZhY2VzIGluc3RlYWQgb2Ygc2l0dGlu
ZyBzaWxlbnQgaW4gdGhlIERCLgovLwovLyBNaXJyb3JzIHRoZSBleGlzdGluZyBqb2IgcGF0dGVy
biAodHJlYXN1cnlDaGVja2VyL3R4U2V0dGxlcik6IGNyb24gc2NoZWR1bGUsCi8vIHBhcnNlUm93
cywgYSBzdGFydCogZW50cnkgcG9pbnQgbW91bnRlZCBmcm9tIGluZGV4LnRzLiBSZWFkLW9ubHkg
LSBpdCBkZXRlY3RzCi8vIGFuZCBhbGVydHMsIGl0IGRvZXMgbm90IG11dGF0ZSBtb25leSBzdGF0
ZSAodGhhdCBpcyB0aGUgZW5naW5lL3NldHRsZXIncyBqb2IpLgovLwovLyBUaHJlc2hvbGRzIGFy
ZSBlbnYtdHVuYWJsZSBzbyBhbGVydGluZyBjYW4gYmUgdGlnaHRlbmVkIHdpdGhvdXQgYSBkZXBs
b3kuCgppbXBvcnQgY3JvbiBmcm9tICdub2RlLWNyb24nCmltcG9ydCB7IGRiIH0gZnJvbSAnLi4v
ZGIvY2xpZW50JwppbXBvcnQgeyBzcWwgfSBmcm9tICdkcml6emxlLW9ybScKaW1wb3J0IHsgbG9n
LCBjYXB0dXJlRXhjZXB0aW9uIH0gZnJvbSAnLi4vbGliL2xvZ2dlcicKCmZ1bmN0aW9uIHBhcnNl
Um93cyhyOiBhbnkpOiBhbnlbXSB7CiAgaWYgKCFyKSByZXR1cm4gW10KICBpZiAoQXJyYXkuaXNB
cnJheSgociBhcyBhbnkpLnJvd3MpKSByZXR1cm4gKHIgYXMgYW55KS5yb3dzCiAgaWYgKEFycmF5
LmlzQXJyYXkocikpIHJldHVybiByCiAgcmV0dXJuIFtdCn0KCmNvbnN0IGludCA9ICh2OiBzdHJp
bmcgfCB1bmRlZmluZWQsIGQ6IG51bWJlcikgPT4gewogIGNvbnN0IG4gPSBOdW1iZXIodik7IHJl
dHVybiBOdW1iZXIuaXNGaW5pdGUobikgJiYgbiA+IDAgPyBuIDogZAp9CgovLyBIb3cgZmFyIGJh
Y2sgdG8gbG9vayBmb3IgYSBidXJzdCBvZiBmYWlsdXJlcywgYW5kIGhvdyBtYW55IGlzICJhIGJ1
cnN0Ii4KY29uc3QgRkFJTEVEX0xPT0tCQUNLX01JTiA9IGludChwcm9jZXNzLmVudi5NT05JVE9S
X0ZBSUxFRF9MT09LQkFDS19NSU4sIDYwKQpjb25zdCBGQUlMRURfQUxFUlRfQ09VTlQgID0gaW50
KHByb2Nlc3MuZW52Lk1PTklUT1JfRkFJTEVEX0FMRVJUX0NPVU5ULCAzKQoKLy8gQSBsZWcgaW4g
ZmxpZ2h0IChvciBhIHRyYW5zZmVyIGluIHByb2dyZXNzKSBvbGRlciB0aGFuIHRoaXMgaXMgInN0
dWNrIi4KY29uc3QgU1RVQ0tfTUlOVVRFUyA9IGludChwcm9jZXNzLmVudi5NT05JVE9SX1NUVUNL
X01JTlVURVMsIDMwKQoKLyoKICBBbGVydCBoZWxwZXI6IHJvdXRlcyB0aHJvdWdoIGNhcHR1cmVF
eGNlcHRpb24gc28gaXQgYm90aCBsb2dzIHN0cnVjdHVyZWQgSlNPTgogIEFORCBzaGlwcyB0byBT
ZW50cnkgd2hlbiBjb25maWd1cmVkLiBXZSBzeW50aGVzaXplIGFuIEVycm9yIHNvIHRoZSBhbGVy
dCBsYW5kcwogIGluIHRoZSBzYW1lIHBsYWNlIHJlYWwgZXhjZXB0aW9ucyBkbywgd2l0aCBhIHN0
YWJsZSwgZ3JlcHBhYmxlIG5hbWUuCiovCmZ1bmN0aW9uIGFsZXJ0KGtpbmQ6IHN0cmluZywgc3Vt
bWFyeTogc3RyaW5nLCBkZXRhaWw6IFJlY29yZDxzdHJpbmcsIHVua25vd24+KSB7CiAgY29uc3Qg
ZSA9IG5ldyBFcnJvcihgW21vbml0b3I6JHtraW5kfV0gJHtzdW1tYXJ5fWApCiAgZS5uYW1lID0g
YE1vbml0b3JBbGVydDoke2tpbmR9YAogIGNhcHR1cmVFeGNlcHRpb24oZSwgeyBzY29wZTogJ21v
bml0b3InLCBraW5kLCAuLi5kZXRhaWwgfSkKfQoKZXhwb3J0IGZ1bmN0aW9uIHN0YXJ0TW9uaXRv
cigpIHsKICBjb25zb2xlLmxvZygnW01vbml0b3JdIOKchSBTdGFydGVkLCBjaGVja3MgZXZlcnkg
NSBtaW51dGVzJykKICAvLyBFdmVyeSA1IG1pbnV0ZXMuCiAgY3Jvbi5zY2hlZHVsZSgnKi81ICog
KiAqIConLCBydW5DaGVja3MpCiAgLy8gQWxzbyBzaG9ydGx5IGFmdGVyIGJvb3QuCiAgc2V0VGlt
ZW91dChydW5DaGVja3MsIDQ1XzAwMCkKfQoKZXhwb3J0IGFzeW5jIGZ1bmN0aW9uIHJ1bkNoZWNr
cygpIHsKICBhd2FpdCBjaGVja0ZhaWxlZFRyYW5zZmVycygpLmNhdGNoKGVyciA9PgogICAgY2Fw
dHVyZUV4Y2VwdGlvbihlcnIsIHsgc2NvcGU6ICdtb25pdG9yLmNoZWNrRmFpbGVkVHJhbnNmZXJz
JyB9KSkKICBhd2FpdCBjaGVja1N0dWNrTGVncygpLmNhdGNoKGVyciA9PgogICAgY2FwdHVyZUV4
Y2VwdGlvbihlcnIsIHsgc2NvcGU6ICdtb25pdG9yLmNoZWNrU3R1Y2tMZWdzJyB9KSkKICBhd2Fp
dCBjaGVja1N0dWNrVHJhbnNmZXJzKCkuY2F0Y2goZXJyID0+CiAgICBjYXB0dXJlRXhjZXB0aW9u
KGVyciwgeyBzY29wZTogJ21vbml0b3IuY2hlY2tTdHVja1RyYW5zZmVycycgfSkpCn0KCi8vIOKU
gOKUgCAxLiBBIGJ1cnN0IG9mIGZhaWxlZCB0cmFuc2ZlcnMg4pSA4pSA4pSA4pSA4pSA4pSA4pSA
4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA
CmFzeW5jIGZ1bmN0aW9uIGNoZWNrRmFpbGVkVHJhbnNmZXJzKCkgewogIGNvbnN0IGN1dG9mZiA9
IE1hdGguZmxvb3IoRGF0ZS5ub3coKSAvIDEwMDApIC0gRkFJTEVEX0xPT0tCQUNLX01JTiAqIDYw
CiAgY29uc3Qgcm93cyA9IHBhcnNlUm93cyhhd2FpdCBkYi5ydW4oc3FsYAogICAgU0VMRUNUIGlk
LCB1cGRhdGVkX2F0IEZST00gdHJhbnNmZXJzCiAgICBXSEVSRSBzdGF0dXMgPSAnZmFpbGVkJyBB
TkQgdXBkYXRlZF9hdCA+PSAke2N1dG9mZn1gKSkKCiAgaWYgKHJvd3MubGVuZ3RoID49IEZBSUxF
RF9BTEVSVF9DT1VOVCkgewogICAgYWxlcnQoJ2ZhaWxlZF90cmFuc2ZlcnMnLAogICAgICBgJHty
b3dzLmxlbmd0aH0gdHJhbnNmZXJzIGZhaWxlZCBpbiB0aGUgbGFzdCAke0ZBSUxFRF9MT09LQkFD
S19NSU59IG1pbmAsCiAgICAgIHsgY291bnQ6IHJvd3MubGVuZ3RoLCBsb29rYmFja01pbjogRkFJ
TEVEX0xPT0tCQUNLX01JTiwKICAgICAgICBpZHM6IHJvd3Muc2xpY2UoMCwgMjApLm1hcChyID0+
IHIuaWQgPz8gclswXSkgfSkKICB9IGVsc2UgewogICAgbG9nLmRlYnVnKCdtb25pdG9yOiBmYWls
ZWQtdHJhbnNmZXIgY2hlY2sgb2snLCB7IGNvdW50OiByb3dzLmxlbmd0aCB9KQogIH0KfQoKLy8g
4pSA4pSAIDIuIExlZ3Mgc3R1Y2sgaW4gZmxpZ2h0IOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKU
gOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKU
gOKUgOKUgOKUgOKUgOKUgAphc3luYyBmdW5jdGlvbiBjaGVja1N0dWNrTGVncygpIHsKICBjb25z
dCBjdXRvZmYgPSBNYXRoLmZsb29yKERhdGUubm93KCkgLyAxMDAwKSAtIFNUVUNLX01JTlVURVMg
KiA2MAogIGNvbnN0IHJvd3MgPSBwYXJzZVJvd3MoYXdhaXQgZGIucnVuKHNxbGAKICAgIFNFTEVD
VCBpZCwgdHJhbnNmZXJfaWQsIGxlZ190eXBlLCB1cGRhdGVkX2F0IEZST00gdHJhbnNmZXJfbGVn
cwogICAgV0hFUkUgc3RhdHVzID0gJ2luX2ZsaWdodCcgQU5EIHVwZGF0ZWRfYXQgPCAke2N1dG9m
Zn1gKSkKCiAgaWYgKHJvd3MubGVuZ3RoID4gMCkgewogICAgYWxlcnQoJ3N0dWNrX2xlZ3MnLAog
ICAgICBgJHtyb3dzLmxlbmd0aH0gbGVnKHMpIGluX2ZsaWdodCBmb3Igb3ZlciAke1NUVUNLX01J
TlVURVN9IG1pbmAsCiAgICAgIHsgY291bnQ6IHJvd3MubGVuZ3RoLCBzdHVja01pbnV0ZXM6IFNU
VUNLX01JTlVURVMsCiAgICAgICAgbGVnczogcm93cy5zbGljZSgwLCAyMCkubWFwKHIgPT4gKHsK
ICAgICAgICAgIGlkOiByLmlkID8/IHJbMF0sIHRyYW5zZmVySWQ6IHIudHJhbnNmZXJfaWQgPz8g
clsxXSwKICAgICAgICAgIGxlZ1R5cGU6IHIubGVnX3R5cGUgPz8gclsyXSB9KSkgfSkKICB9IGVs
c2UgewogICAgbG9nLmRlYnVnKCdtb25pdG9yOiBzdHVjay1sZWcgY2hlY2sgb2snKQogIH0KfQoK
Ly8g4pSA4pSAIDMuIFRyYW5zZmVycyBzdHVjayBpbiBwcm9ncmVzcyDilIDilIDilIDilIDilIDi
lIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDi
lIDilIAKYXN5bmMgZnVuY3Rpb24gY2hlY2tTdHVja1RyYW5zZmVycygpIHsKICBjb25zdCBjdXRv
ZmYgPSBNYXRoLmZsb29yKERhdGUubm93KCkgLyAxMDAwKSAtIFNUVUNLX01JTlVURVMgKiA2MAog
IGNvbnN0IHJvd3MgPSBwYXJzZVJvd3MoYXdhaXQgZGIucnVuKHNxbGAKICAgIFNFTEVDVCBpZCwg
Y3VycmVudF9sZWcsIHVwZGF0ZWRfYXQgRlJPTSB0cmFuc2ZlcnMKICAgIFdIRVJFIHN0YXR1cyA9
ICdpbl9wcm9ncmVzcycgQU5EIHVwZGF0ZWRfYXQgPCAke2N1dG9mZn1gKSkKCiAgaWYgKHJvd3Mu
bGVuZ3RoID4gMCkgewogICAgYWxlcnQoJ3N0dWNrX3RyYW5zZmVycycsCiAgICAgIGAke3Jvd3Mu
bGVuZ3RofSB0cmFuc2ZlcihzKSBpbl9wcm9ncmVzcyBmb3Igb3ZlciAke1NUVUNLX01JTlVURVN9
IG1pbmAsCiAgICAgIHsgY291bnQ6IHJvd3MubGVuZ3RoLCBzdHVja01pbnV0ZXM6IFNUVUNLX01J
TlVURVMsCiAgICAgICAgaWRzOiByb3dzLnNsaWNlKDAsIDIwKS5tYXAociA9PiByLmlkID8/IHJb
MF0pIH0pCiAgfSBlbHNlIHsKICAgIGxvZy5kZWJ1ZygnbW9uaXRvcjogc3R1Y2stdHJhbnNmZXIg
Y2hlY2sgb2snKQogIH0KfQoKLy8gTk9URSBvbiBiYWxhbmNlIGRyaWZ0OiBhIG1lYW5pbmdmdWwg
ZHJpZnQgYWxlcnQgbmVlZHMgYW4gZXhwZWN0ZWQtYmFsYW5jZQovLyBzb3VyY2UgdG8gY29tcGFy
ZSB0aGUgb24tY2hhaW4gcGxhdGZvcm0vdHJlYXN1cnkgYmFsYW5jZSBhZ2FpbnN0IChlLmcuIHN1
bSBvZgovLyBjb21wbGV0ZWQtYnV0LXVuc3dlcHQgbGVncywgb3IgYSByZWNvcmRlZCBsZWRnZXIg
dG90YWwpLiBUaGF0IHJlZmVyZW5jZSBkb2VzCi8vIG5vdCBleGlzdCB5ZXQgYXMgYSBzaW5nbGUg
cXVlcnksIHNvIHJhdGhlciB0aGFuIGVtaXQgYSBmYWtlIG51bWJlciB3ZSBsZWF2ZSBhCi8vIGNs
ZWFyIHNlYW0gaGVyZS4gV2lyZSBpdCB3aGVuIHRoZSBwbGF0Zm9ybSBsZWRnZXIgdG90YWwgaXMg
YXZhaWxhYmxlOgovLwovLyAgIGFzeW5jIGZ1bmN0aW9uIGNoZWNrQmFsYW5jZURyaWZ0KCkgewov
LyAgICAgY29uc3Qgb25DaGFpbiA9IGF3YWl0IHJlYWRQbGF0Zm9ybVVzZGNCYWxhbmNlKCkgICAg
ICAvLyB2aWVtLCBsaWtlIHRyZWFzdXJ5Q2hlY2tlcgovLyAgICAgY29uc3QgZXhwZWN0ZWQgPSBh
d2FpdCByZWFkTGVkZ2VyRXhwZWN0ZWRCYWxhbmNlKCkgICAvLyBUT0RPOiBsZWRnZXIgdG90YWwK
Ly8gICAgIGlmIChhYnNEaWZmKG9uQ2hhaW4sIGV4cGVjdGVkKSA+IERSSUZUX1RPTEVSQU5DRSkg
YWxlcnQoJ2JhbGFuY2VfZHJpZnQnLCAuLi4pCi8vICAgfQo=
B64MON
base64 -d > "$TTEST" <<'B64TEST'
aW1wb3J0IHsgZGVzY3JpYmUsIGl0LCBleHBlY3QsIHZpLCBiZWZvcmVFYWNoLCBhZnRlckVhY2gs
IGJlZm9yZUFsbCB9IGZyb20gJ3ZpdGVzdCcKCi8vID09PT09PT09PT09PT09PT09PT09PT09PT09
PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT0KLy8gTW9u
ZXktZmxvdyBtb25pdG9yIChQaGFzZSA3IEhhcmRlbmluZykuCi8vCi8vIEVhY2ggY2hlY2sgbXVz
dCBBTEVSVCB3aGVuIGl0cyB0aHJlc2hvbGQgaXMgY3Jvc3NlZCBhbmQgc3RheSBRVUlFVCBvdGhl
cndpc2UuCi8vIFRvIGF2b2lkIGNyb3NzLXRlc3QgREIgdmlzaWJpbGl0eSBnYXBzLCB3ZSBzZWVk
IGFuZCByZXNldCB0aHJvdWdoIHRoZSBTQU1FIGRiCi8vIHNpbmdsZXRvbiB0aGUgbW9uaXRvciBp
bXBvcnRzICguLi9zcmMvZGIvY2xpZW50KSwgcG9pbnRlZCBhdCBhIHRocm93YXdheSBmaWxlLgov
LyA9PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
PT09PT09PT09PT09PT09PT09PT09Cgpjb25zdCBEQl9QQVRIID0gYC90bXAvbW9uaXRvci12aXRl
c3QtJHtwcm9jZXNzLnBpZH0uZGJgCnByb2Nlc3MuZW52LlRVUlNPX0RBVEFCQVNFX1VSTCA9IGBm
aWxlOiR7REJfUEFUSH1gCgpjb25zdCBjYXB0dXJlU3B5ID0gdmkuZm4oKQp2aS5tb2NrKCcuLi9z
cmMvbGliL2xvZ2dlcicsICgpID0+ICh7CiAgbG9nOiB7IGRlYnVnOiB2aS5mbigpLCBpbmZvOiB2
aS5mbigpLCB3YXJuOiB2aS5mbigpLCBlcnJvcjogdmkuZm4oKSB9LAogIGNhcHR1cmVFeGNlcHRp
b246ICguLi5hOiBhbnlbXSkgPT4gY2FwdHVyZVNweSguLi5hKSwKfSkpCgppbXBvcnQgeyBzcWwg
fSBmcm9tICdkcml6emxlLW9ybScKaW1wb3J0IHsgZGIgfSBmcm9tICcuLi9zcmMvZGIvY2xpZW50
JwoKY29uc3Qgbm93ID0gKCkgPT4gTWF0aC5mbG9vcihEYXRlLm5vdygpIC8gMTAwMCkKY29uc3Qg
bWluc0FnbyA9IChtOiBudW1iZXIpID0+IG5vdygpIC0gbSAqIDYwCgpiZWZvcmVBbGwoYXN5bmMg
KCkgPT4gewogIGF3YWl0IGRiLnJ1bihzcWxgQ1JFQVRFIFRBQkxFIElGIE5PVCBFWElTVFMgdHJh
bnNmZXJzICgKICAgIGlkIFRFWFQgUFJJTUFSWSBLRVksIHN0YXR1cyBURVhUIE5PVCBOVUxMLCBj
dXJyZW50X2xlZyBURVhULAogICAgY3JlYXRlZF9hdCBJTlRFR0VSIE5PVCBOVUxMLCB1cGRhdGVk
X2F0IElOVEVHRVIgTk9UIE5VTEwpYCkKICBhd2FpdCBkYi5ydW4oc3FsYENSRUFURSBUQUJMRSBJ
RiBOT1QgRVhJU1RTIHRyYW5zZmVyX2xlZ3MgKAogICAgaWQgVEVYVCBQUklNQVJZIEtFWSwgdHJh
bnNmZXJfaWQgVEVYVCBOT1QgTlVMTCwgbGVnX3R5cGUgVEVYVCBOT1QgTlVMTCwKICAgIHN0YXR1
cyBURVhUIE5PVCBOVUxMLCB1cGRhdGVkX2F0IElOVEVHRVIgTk9UIE5VTEwpYCkKfSkKCmJlZm9y
ZUVhY2goYXN5bmMgKCkgPT4gewogIGF3YWl0IGRiLnJ1bihzcWxgREVMRVRFIEZST00gdHJhbnNm
ZXJzYCkKICBhd2FpdCBkYi5ydW4oc3FsYERFTEVURSBGUk9NIHRyYW5zZmVyX2xlZ3NgKQogIGNh
cHR1cmVTcHkubW9ja0NsZWFyKCkKfSkKYWZ0ZXJFYWNoKCgpID0+IHsgdHJ5IHsgcmVxdWlyZSgn
bm9kZTpmcycpLnVubGlua1N5bmMoREJfUEFUSCkgfSBjYXRjaCB7fSB9KQoKYXN5bmMgZnVuY3Rp
b24gYWRkVHJhbnNmZXIoaWQ6IHN0cmluZywgc3RhdHVzOiBzdHJpbmcsIHVwZGF0ZWRBdDogbnVt
YmVyKSB7CiAgYXdhaXQgZGIucnVuKHNxbGBJTlNFUlQgSU5UTyB0cmFuc2ZlcnMgKGlkLCBzdGF0
dXMsIGN1cnJlbnRfbGVnLCBjcmVhdGVkX2F0LCB1cGRhdGVkX2F0KQogICAgVkFMVUVTICgke2lk
fSwgJHtzdGF0dXN9LCAnYnJpZGdlJywgJHt1cGRhdGVkQXR9LCAke3VwZGF0ZWRBdH0pYCkKfQph
c3luYyBmdW5jdGlvbiBhZGRMZWcoaWQ6IHN0cmluZywgc3RhdHVzOiBzdHJpbmcsIHVwZGF0ZWRB
dDogbnVtYmVyKSB7CiAgYXdhaXQgZGIucnVuKHNxbGBJTlNFUlQgSU5UTyB0cmFuc2Zlcl9sZWdz
IChpZCwgdHJhbnNmZXJfaWQsIGxlZ190eXBlLCBzdGF0dXMsIHVwZGF0ZWRfYXQpCiAgICBWQUxV
RVMgKCR7aWR9LCAkeyd0LScgKyBpZH0sICdicmlkZ2UnLCAke3N0YXR1c30sICR7dXBkYXRlZEF0
fSlgKQp9CmNvbnN0IGFsZXJ0c09mS2luZCA9IChraW5kOiBzdHJpbmcpID0+CiAgY2FwdHVyZVNw
eS5tb2NrLmNhbGxzLmZpbHRlcihjID0+IGNbMV0/LmtpbmQgPT09IGtpbmQpCgpkZXNjcmliZSgn
bW9uaXRvcicsICgpID0+IHsKICBpdCgnYWxlcnRzIHdoZW4gZmFpbGVkIHRyYW5zZmVycyBleGNl
ZWQgdGhlIHRocmVzaG9sZCcsIGFzeW5jICgpID0+IHsKICAgIGZvciAobGV0IGkgPSAwOyBpIDwg
MzsgaSsrKSBhd2FpdCBhZGRUcmFuc2ZlcihgZiR7aX1gLCAnZmFpbGVkJywgbWluc0Fnbyg1KSkK
ICAgIGNvbnN0IHsgcnVuQ2hlY2tzIH0gPSBhd2FpdCBpbXBvcnQoJy4uL3NyYy9qb2JzL21vbml0
b3InKQogICAgYXdhaXQgcnVuQ2hlY2tzKCkKICAgIGV4cGVjdChhbGVydHNPZktpbmQoJ2ZhaWxl
ZF90cmFuc2ZlcnMnKS5sZW5ndGgpLnRvQmUoMSkKICB9KQogIGl0KCdzdGF5cyBxdWlldCB3aGVu
IGZhaWx1cmVzIGFyZSBiZWxvdyB0aGUgdGhyZXNob2xkJywgYXN5bmMgKCkgPT4gewogICAgYXdh
aXQgYWRkVHJhbnNmZXIoJ2YwJywgJ2ZhaWxlZCcsIG1pbnNBZ28oNSkpCiAgICBjb25zdCB7IHJ1
bkNoZWNrcyB9ID0gYXdhaXQgaW1wb3J0KCcuLi9zcmMvam9icy9tb25pdG9yJykKICAgIGF3YWl0
IHJ1bkNoZWNrcygpCiAgICBleHBlY3QoYWxlcnRzT2ZLaW5kKCdmYWlsZWRfdHJhbnNmZXJzJyku
bGVuZ3RoKS50b0JlKDApCiAgfSkKICBpdCgnaWdub3JlcyBPTEQgZmFpbHVyZXMgb3V0c2lkZSB0
aGUgbG9va2JhY2sgd2luZG93JywgYXN5bmMgKCkgPT4gewogICAgZm9yIChsZXQgaSA9IDA7IGkg
PCA1OyBpKyspIGF3YWl0IGFkZFRyYW5zZmVyKGBvbGQke2l9YCwgJ2ZhaWxlZCcsIG1pbnNBZ28o
NjAwKSkKICAgIGNvbnN0IHsgcnVuQ2hlY2tzIH0gPSBhd2FpdCBpbXBvcnQoJy4uL3NyYy9qb2Jz
L21vbml0b3InKQogICAgYXdhaXQgcnVuQ2hlY2tzKCkKICAgIGV4cGVjdChhbGVydHNPZktpbmQo
J2ZhaWxlZF90cmFuc2ZlcnMnKS5sZW5ndGgpLnRvQmUoMCkKICB9KQogIGl0KCdhbGVydHMgb24g
YSBsZWcgc3R1Y2sgaW5fZmxpZ2h0IHBhc3QgdGhlIHRocmVzaG9sZCcsIGFzeW5jICgpID0+IHsK
ICAgIGF3YWl0IGFkZExlZygnc3R1Y2sxJywgJ2luX2ZsaWdodCcsIG1pbnNBZ28oNDUpKQogICAg
Y29uc3QgeyBydW5DaGVja3MgfSA9IGF3YWl0IGltcG9ydCgnLi4vc3JjL2pvYnMvbW9uaXRvcicp
CiAgICBhd2FpdCBydW5DaGVja3MoKQogICAgZXhwZWN0KGFsZXJ0c09mS2luZCgnc3R1Y2tfbGVn
cycpLmxlbmd0aCkudG9CZSgxKQogIH0pCiAgaXQoJ2RvZXMgbm90IGFsZXJ0IG9uIGEgbGVnIG9u
bHkgcmVjZW50bHkgaW5fZmxpZ2h0JywgYXN5bmMgKCkgPT4gewogICAgYXdhaXQgYWRkTGVnKCdm
cmVzaDEnLCAnaW5fZmxpZ2h0JywgbWluc0Fnbyg1KSkKICAgIGNvbnN0IHsgcnVuQ2hlY2tzIH0g
PSBhd2FpdCBpbXBvcnQoJy4uL3NyYy9qb2JzL21vbml0b3InKQogICAgYXdhaXQgcnVuQ2hlY2tz
KCkKICAgIGV4cGVjdChhbGVydHNPZktpbmQoJ3N0dWNrX2xlZ3MnKS5sZW5ndGgpLnRvQmUoMCkK
ICB9KQogIGl0KCdhbGVydHMgb24gYSB0cmFuc2ZlciBzdHVjayBpbl9wcm9ncmVzcyBwYXN0IHRo
ZSB0aHJlc2hvbGQnLCBhc3luYyAoKSA9PiB7CiAgICBhd2FpdCBhZGRUcmFuc2ZlcigncDEnLCAn
aW5fcHJvZ3Jlc3MnLCBtaW5zQWdvKDQ1KSkKICAgIGNvbnN0IHsgcnVuQ2hlY2tzIH0gPSBhd2Fp
dCBpbXBvcnQoJy4uL3NyYy9qb2JzL21vbml0b3InKQogICAgYXdhaXQgcnVuQ2hlY2tzKCkKICAg
IGV4cGVjdChhbGVydHNPZktpbmQoJ3N0dWNrX3RyYW5zZmVycycpLmxlbmd0aCkudG9CZSgxKQog
IH0pCiAgaXQoJ2EgY2xlYW4gc3lzdGVtIHByb2R1Y2VzIG5vIGFsZXJ0cyBhdCBhbGwnLCBhc3lu
YyAoKSA9PiB7CiAgICBhd2FpdCBhZGRUcmFuc2Zlcignb2sxJywgJ2NvbXBsZXRlZCcsIG1pbnNB
Z28oNSkpCiAgICBhd2FpdCBhZGRMZWcoJ29rbGVnJywgJ2RvbmUnLCBtaW5zQWdvKDUpKQogICAg
Y29uc3QgeyBydW5DaGVja3MgfSA9IGF3YWl0IGltcG9ydCgnLi4vc3JjL2pvYnMvbW9uaXRvcicp
CiAgICBhd2FpdCBydW5DaGVja3MoKQogICAgZXhwZWN0KGNhcHR1cmVTcHkpLm5vdC50b0hhdmVC
ZWVuQ2FsbGVkKCkKICB9KQp9KQo=
B64TEST
base64 -d > "$TPATCH" <<'B64PATCH'
IyEvdXNyL2Jpbi9lbnYgcHl0aG9uMwoiIiIKUGhhc2UgNyBQYXJ0IDUgKG1vbml0b3JpbmcpIC0g
bW91bnQgdGhlIG1vbml0b3IgY3JvbiBqb2IgaW4gaW5kZXgudHMuCgpFZGl0cyBuZXh1bS1hcGkv
c3JjL2luZGV4LnRzOgogICogaW1wb3J0IHN0YXJ0TW9uaXRvcgogICogY2FsbCBzdGFydE1vbml0
b3IoKSBhbG9uZ3NpZGUgdGhlIG90aGVyIHN0YXJ0KiBqb2JzCgpJZGVtcG90ZW50IHZpYSBfX05F
WFVNX01PTklUT1JfV0lSRURfXy4gRXhhY3QtYW5jaG9yOyBhYm9ydHMgY2xlYW4gb24gZHJpZnQu
CiIiIgppbXBvcnQgc3lzLCBpbwpQQVRIID0gIm5leHVtLWFwaS9zcmMvaW5kZXgudHMiCk1BUktF
UiA9ICJfX05FWFVNX01PTklUT1JfV0lSRURfXyIKc3JjID0gaW8ub3BlbihQQVRILCBlbmNvZGlu
Zz0idXRmLTgiKS5yZWFkKCkKaWYgTUFSS0VSIGluIHNyYzoKICAgIHByaW50KGYiICB7UEFUSH06
IGFscmVhZHkgd2lyZWQgLSBza2lwcGluZy4iKQogICAgc3lzLmV4aXQoMCkKCmVkaXRzID0gWwog
ICAgKCJpbXBvcnQiLAogICAgICJpbXBvcnQgeyBzdGFydFR4U2V0dGxlciB9ICAgICAgICAgZnJv
bSAnLi9qb2JzL3R4U2V0dGxlciciLAogICAgICJpbXBvcnQgeyBzdGFydFR4U2V0dGxlciB9ICAg
ICAgICAgZnJvbSAnLi9qb2JzL3R4U2V0dGxlcidcbiIKICAgICAiLy8gX19ORVhVTV9NT05JVE9S
X1dJUkVEX18gKHBoYXNlNykgbW9uZXktZmxvdyBtb25pdG9yaW5nICsgYWxlcnRpbmdcbiIKICAg
ICAiaW1wb3J0IHsgc3RhcnRNb25pdG9yIH0gICAgICAgICAgIGZyb20gJy4vam9icy9tb25pdG9y
JyIpLAogICAgKCJzdGFydCBjYWxsIiwKICAgICAiICBzdGFydFJhdGVQb2xsZXIoKSIsCiAgICAg
IiAgc3RhcnRSYXRlUG9sbGVyKClcbiAgc3RhcnRNb25pdG9yKCkiKSwKXQpmb3IgZGVzYywgb2xk
LCBuZXcgaW4gZWRpdHM6CiAgICBuID0gc3JjLmNvdW50KG9sZCkKICAgIGlmIG4gIT0gMToKICAg
ICAgICBwcmludChmIkVSUk9SOiBhbmNob3IgJ3tkZXNjfScgbWF0Y2hlZCB7bn0gdGltZXMgKGV4
cGVjdGVkIDEpLiBBYm9ydGluZy4iKQogICAgICAgIHN5cy5leGl0KDIpCiAgICBzcmMgPSBzcmMu
cmVwbGFjZShvbGQsIG5ldykKaW8ub3BlbihQQVRILCAidyIsIGVuY29kaW5nPSJ1dGYtOCIpLndy
aXRlKHNyYykKcHJpbnQoZiIgIHtQQVRIfTogd2lyZWQuIikK
B64PATCH

verify(){ local got; got="$( (sha256sum "$1" 2>/dev/null || shasum -a 256 "$1") | awk '{print $1}')"; [ "$got" = "$2" ] || die "Checksum mismatch for $1 (got $got). Nothing written."; }
verify "$TMON" "$MON_SHA"; verify "$TTEST" "$TEST_SHA"; verify "$TPATCH" "$PATCH_SHA"
log "All payloads verified."

mkdir -p "$BACKUP_DIR"
[ -f "$IDX" ] && ! grep -qF "$MARKER" "$IDX" && cp "$IDX" "$BACKUP_DIR/index.ts" || true

mkdir -p "$API/src/jobs" "$API/tests"
if [ -f "$MON" ]; then log "monitor job already present - leaving it."; else cp "$TMON" "$MON"; log "Added $MON"; fi
if [ -f "$MON_TEST" ]; then log "monitor test already present - leaving it."; else cp "$TTEST" "$MON_TEST"; log "Added $MON_TEST"; fi

python3 "$TPATCH" || {
  [ -f "$BACKUP_DIR/index.ts" ] && cp "$BACKUP_DIR/index.ts" "$IDX"
  die "Wiring failed; index.ts restored."
}

log ""
log "=== Gate: tsc + tests ==="
( cd "$API" && npx tsc --noEmit ) || die "API tsc failed - not committing."
log "tsc clean."
( cd "$API" && npx vitest run ) || die "API tests failed - not committing."
log "tests pass."

if [ "$FLAG" = "--no-deploy" ]; then
  log "--no-deploy: applied + verified. Rerun without the flag to commit + push."
  exit 0
fi

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "Not a git work tree; commit manually."
REMOTE="$(git remote | head -1 || true)"; [ -n "$REMOTE" ] || die "No git remote; commit/push manually."
BRANCH="$(git rev-parse --abbrev-ref HEAD)"
git add -A
if git diff --cached --quiet; then log "Nothing to commit."; exit 0; fi
log "Committing on '$BRANCH' -> '$REMOTE'..."
git commit -m "$COMMIT_MSG"
git push "$REMOTE" "$BRANCH"
log ""
log "Pushed Phase 7 Part 5. The monitor runs every 5 min and alerts via the logger/Sentry."
log "Set SENTRY_DSN (Part 3) to route alerts to Sentry; tune MONITOR_* env vars as needed."
