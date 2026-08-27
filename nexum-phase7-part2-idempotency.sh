#!/usr/bin/env bash
# ============================================================================
# Nexum Phase 7 (Hardening) - Part 2: request-level idempotency (money path)
#
# Guards the tightest money path against double execution from a retried or
# double-tapped request:
#   POST /transfers          -> withIdempotency('transfers.create')
#   POST /transfers/cashout  -> withIdempotency('transfers.cashout')
#   POST /payments           -> withIdempotency('payments.create')
#
# A client sends an `Idempotency-Key` header; the first request runs and caches
# its response, replays return the cached status+body, a concurrent duplicate
# gets 409, and a reused key with a changed body gets 422. Mirrors the existing
# ramp_webhook_events dedupe pattern (guard table + INSERT OR IGNORE).
#
# NOTE: payroll already has per-recipient idempotency at the Circle SDK layer
# (stableUuid), so it is intentionally NOT re-wrapped here - this part adds the
# HTTP-boundary guard the create endpoints lacked.
#
# Ships:
#   NEW  nexum-api/src/middleware/idempotency.ts
#   NEW  nexum-api/migrations/0026_idempotency_keys.sql
#   NEW  nexum-api/tests/idempotency.test.ts   (migration + table semantics)
#   PATCH transfers.ts + payments.ts (wire the middleware)
#
# Delivery contract (your v2 spec) + full deploy:
#   * all four payloads base64 + sha256 verified before writing
#   * exact-anchor route wiring; drift aborts clean, never half-patched
#   * idempotent (markers per file); timestamped backups of patched routes
#   * deploy GATE: tsc --noEmit -> vitest run -> (migration) -> commit + push
#   * the DB migration is a DISTINCT, explained step: it runs `npm run migrate`
#     against your configured DB. Use --skip-migrate to handle it yourself.
#   * --revert removes the new files + restores the routes
#   * --no-deploy applies + tests, skips migrate/build/commit/push
#
# Run from REPO ROOT (folder containing nexum-api/).
#   bash nexum-phase7-part2-idempotency.sh
#   bash nexum-phase7-part2-idempotency.sh --no-deploy
#   bash nexum-phase7-part2-idempotency.sh --skip-migrate
#   bash nexum-phase7-part2-idempotency.sh --revert
# ============================================================================
set -euo pipefail

API="nexum-api"
MW="$API/src/middleware/idempotency.ts"
SQLF="$API/migrations/0026_idempotency_keys.sql"
TESTF="$API/tests/idempotency.test.ts"
TRANSFERS="$API/src/routes/transfers.ts"
PAYMENTS="$API/src/routes/payments.ts"
MARKER="__NEXUM_IDEMPOTENCY_WIRED__"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR=".nexum-phase7p2-backup/${STAMP}"
MW_SHA="9313ed4b8383890d83d907274bae687d3014e9923dcbb5f0f15c7be3fdd34e5e"; SQL_SHA="5c920b3a09771cc3748c0548e478026cdcc5254f611a55afb768424d3f963123"; PATCH_SHA="e894f956377ce505831459f234ba7e384abea8adba30c6cc82c9a62520642358"; TEST_SHA="d07562e5e4c9b932f97853cabd68ed6aaef083517312f6a96ff243a8404e4086"
COMMIT_MSG="feat(api): request-level idempotency on transfers/cashout/payments (Phase 7.2)"

FLAG="${1:-}"
log(){ printf '  %s\n' "$*"; }
die(){ printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[ -d "$API" ] || die "Cannot find $API . Run from the repo root."

# ---------------------------------------------------------------- revert ----
if [ "$FLAG" = "--revert" ]; then
  # Pick the newest backup dir that actually holds a route file (an idempotent
  # re-run may have created an empty backup dir).
  LATEST=""
  for d in $(ls -1dt .nexum-phase7p2-backup/*/ 2>/dev/null); do
    if [ -f "${d}transfers.ts" ] || [ -f "${d}payments.ts" ]; then LATEST="$d"; break; fi
  done
  if [ -n "$LATEST" ]; then
    [ -f "${LATEST}transfers.ts" ] && cp "${LATEST}transfers.ts" "$TRANSFERS" && log "Restored $TRANSFERS"
    [ -f "${LATEST}payments.ts" ]  && cp "${LATEST}payments.ts"  "$PAYMENTS"  && log "Restored $PAYMENTS"
  else
    log "No route backup found; leaving route files as-is."
  fi
  rm -f "$MW" && log "Removed $MW"
  rmdir "$API/src/middleware" 2>/dev/null || true
  rm -f "$TESTF" && log "Removed $TESTF"
  log "NOTE: migration $SQLF and the idempotency_keys table are left in place on"
  log "      purpose - dropping an applied migration/table is unsafe. Remove by"
  log "      hand only if you are certain nothing depends on it."
  rm -f "$SQLF" && log "Removed the migration FILE (table in your DB is untouched)."
  log "Reverted Phase 7 Part 2."
  exit 0
fi

# --------------------------------------------- decode + verify payloads -----
TMW="$(mktemp)"; TSQL="$(mktemp)"; TPATCH="$(mktemp /tmp/p7p2.XXXXXX.py)"; TTEST="$(mktemp)"
trap 'rm -f "$TMW" "$TSQL" "$TPATCH" "$TTEST"' EXIT

base64 -d > "$TMW" <<'B64MW'
aW1wb3J0IHR5cGUgeyBSZXF1ZXN0LCBSZXNwb25zZSwgTmV4dEZ1bmN0aW9uIH0gZnJvbSAnZXhw
cmVzcycKaW1wb3J0IHsgY3JlYXRlSGFzaCB9IGZyb20gJ2NyeXB0bycKaW1wb3J0IHsgc3FsIH0g
ZnJvbSAnZHJpenpsZS1vcm0nCmltcG9ydCB7IGRiIH0gZnJvbSAnLi4vZGIvY2xpZW50JwoKLy8g
PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
PT09PT09PT09PT09PT09PT09PQovLyBSZXF1ZXN0LWxldmVsIGlkZW1wb3RlbmN5IChQaGFzZSA3
IEhhcmRlbmluZykuCi8vCi8vIFdyYXAgYSBtb25leS1tb3ZpbmcgUE9TVCBoYW5kbGVyIHdpdGgg
d2l0aElkZW1wb3RlbmN5KCdzY29wZScpLiBUaGUgY2xpZW50Ci8vIHNlbmRzIGFuIGBJZGVtcG90
ZW5jeS1LZXlgIGhlYWRlciAoYSBVVUlEIGl0IGtlZXBzIHN0YWJsZSBhY3Jvc3MgcmV0cmllcyBv
ZgovLyB0aGUgU0FNRSBsb2dpY2FsIGFjdGlvbikuIEJlaGF2aW91cjoKLy8KLy8gICAqIEZpcnN0
IHRpbWUgd2Ugc2VlIChzY29wZSwga2V5KTogcmVzZXJ2ZSBpdCAoJ2luX3Byb2dyZXNzJyksIHJ1
biB0aGUKLy8gICAgIGhhbmRsZXIsIGNhcHR1cmUgaXRzIEpTT04gcmVzcG9uc2UsIGNhY2hlIGl0
ICgnY29tcGxldGVkJyksIHJldHVybiBpdC4KLy8gICAqIFJlcGxheSBhZnRlciBjb21wbGV0aW9u
OiByZXR1cm4gdGhlIGNhY2hlZCBzdGF0dXMgKyBib2R5IHZlcmJhdGltIC0gdGhlCi8vICAgICBo
YW5kbGVyIG5ldmVyIHJ1bnMgYWdhaW4sIHNvIG5vIHNlY29uZCB0cmFuc2ZlciAvIHBheW1lbnQg
aXMgY3JlYXRlZC4KLy8gICAqIFJlcGxheSBXSElMRSB0aGUgZmlyc3QgaXMgc3RpbGwgcnVubmlu
ZzogNDA5IGluX3Byb2dyZXNzLCBzbyBhIGRvdWJsZS10YXAKLy8gICAgIGNhbid0IHNsaXAgdGhy
b3VnaCB0aGUgZ2FwIGJldHdlZW4gImNoZWNrIiBhbmQgIndyaXRlIiAodGhlIHJhY2UgdGhlCi8v
ICAgICBwYXlyb2xsIHN0YXR1cy1nYXRlIGFsb25lIGNhbid0IGNsb3NlKS4KLy8gICAqIFNhbWUg
a2V5LCBESUZGRVJFTlQgYm9keTogNDIyIC0gYSByZXVzZWQga2V5IHdpdGggYSBjaGFuZ2VkIHBh
eWxvYWQgaXMgYQovLyAgICAgY2xpZW50IGJ1ZyB3ZSByZWZ1c2UgcmF0aGVyIHRoYW4gc2lsZW50
bHkgc2VydmUgdGhlIHdyb25nIGNhY2hlZCBhbnN3ZXIuCi8vCi8vIElmIE5PIGhlYWRlciBpcyBz
ZW50LCB0aGUgcmVxdWVzdCBwcm9jZWVkcyBub3JtYWxseSAoaWRlbXBvdGVuY3kgaXMgb3B0LWlu
Ci8vIHBlciByZXF1ZXN0KSAtIGJ1dCB0aGUgd2lyZWQgZW5kcG9pbnRzJyBjbGllbnRzIGFsd2F5
cyBzZW5kIG9uZS4KLy8KLy8gTWlycm9ycyB0aGUgcmFtcF93ZWJob29rX2V2ZW50cyBkZWR1cGUg
YXBwcm9hY2g6IGEgc21hbGwgZ3VhcmQgdGFibGUsIGtleWVkCi8vIHVuaXF1ZWx5LCBjaGVja2Vk
IGJlZm9yZSB0aGUgc2lkZSBlZmZlY3QuCi8vID09PT09PT09PT09PT09PT09PT09PT09PT09PT09
PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT0KCmNvbnN0IFNU
QUxFX1NFQ09ORFMgPSBOdW1iZXIocHJvY2Vzcy5lbnYuSURFTVBPVEVOQ1lfU1RBTEVfU0VDT05E
UyA/PyAnMTIwJykKCmZ1bmN0aW9uIHBhcnNlUm93cyhyOiBhbnkpOiBhbnlbXSB7CiAgaWYgKCFy
KSByZXR1cm4gW10KICBpZiAoQXJyYXkuaXNBcnJheSgociBhcyBhbnkpLnJvd3MpKSByZXR1cm4g
KHIgYXMgYW55KS5yb3dzCiAgaWYgKEFycmF5LmlzQXJyYXkocikpIHJldHVybiByCiAgcmV0dXJu
IFtdCn0KCmZ1bmN0aW9uIGZpbmdlcnByaW50KGJvZHk6IHVua25vd24pOiBzdHJpbmcgewogIGxl
dCBzOiBzdHJpbmcKICB0cnkgeyBzID0gSlNPTi5zdHJpbmdpZnkoYm9keSA/PyBudWxsKSB9IGNh
dGNoIHsgcyA9IFN0cmluZyhib2R5KSB9CiAgcmV0dXJuIGNyZWF0ZUhhc2goJ3NoYTI1NicpLnVw
ZGF0ZShzKS5kaWdlc3QoJ2hleCcpCn0KCmV4cG9ydCBmdW5jdGlvbiB3aXRoSWRlbXBvdGVuY3ko
c2NvcGU6IHN0cmluZykgewogIHJldHVybiBhc3luYyBmdW5jdGlvbiAocmVxOiBSZXF1ZXN0LCBy
ZXM6IFJlc3BvbnNlLCBuZXh0OiBOZXh0RnVuY3Rpb24pIHsKICAgIGNvbnN0IGtleSA9CiAgICAg
IChyZXEuaGVhZGVyKCdJZGVtcG90ZW5jeS1LZXknKSB8fCByZXEuaGVhZGVyKCdpZGVtcG90ZW5j
eS1rZXknKSB8fCAnJykudHJpbSgpCgogICAgLy8gT3B0LWluOiBubyBrZXkgbWVhbnMgYmVoYXZl
IGV4YWN0bHkgYXMgYmVmb3JlLgogICAgaWYgKCFrZXkpIHJldHVybiBuZXh0KCkKCiAgICBjb25z
dCBmcCAgPSBmaW5nZXJwcmludChyZXEuYm9keSkKICAgIGNvbnN0IG5vdyA9IE1hdGguZmxvb3Io
RGF0ZS5ub3coKSAvIDEwMDApCgogICAgLy8gMS4gVHJ5IHRvIFJFU0VSVkUgdGhlIGtleSBhdG9t
aWNhbGx5LiBJTlNFUlQgT1IgSUdOT1JFIG1lYW5zIG9ubHkgdGhlCiAgICAvLyAgICBmaXJzdCBj
b25jdXJyZW50IHJlcXVlc3Qgd2lucyB0aGUgaW5zZXJ0OyB0aGUgcmVzdCBhZmZlY3QgMCByb3dz
LgogICAgdHJ5IHsKICAgICAgYXdhaXQgZGIucnVuKHNxbGAKICAgICAgICBJTlNFUlQgT1IgSUdO
T1JFIElOVE8gaWRlbXBvdGVuY3lfa2V5cwogICAgICAgICAgKHNjb3BlLCBpZGVtcG90ZW5jeV9r
ZXksIHN0YXR1cywgcmVxdWVzdF9maW5nZXJwcmludCwgY3JlYXRlZF9hdCkKICAgICAgICBWQUxV
RVMgKCR7c2NvcGV9LCAke2tleX0sICdpbl9wcm9ncmVzcycsICR7ZnB9LCAke25vd30pYCkKICAg
IH0gY2F0Y2ggKGVycjogYW55KSB7CiAgICAgIC8vIElmIHRoZSBndWFyZCB0YWJsZSBpcyB1bmF2
YWlsYWJsZSwgZmFpbCBPUEVOIHRvIG5vdCBibG9jayBwYXltZW50cyAtCiAgICAgIC8vIHRoZSBl
bmRwb2ludCBrZWVwcyBpdHMgb3duIGRvd25zdHJlYW0gcHJvdGVjdGlvbnMgKENpcmNsZSBpZGVt
cG90ZW5jeSwKICAgICAgLy8gc3RhdHVzIGdhdGVzKS4gTG9nIGFuZCBwcm9jZWVkLgogICAgICBj
b25zb2xlLmVycm9yKCdbaWRlbXBvdGVuY3ldIHJlc2VydmUgZmFpbGVkLCBwcm9jZWVkaW5nOics
IGVycj8ubWVzc2FnZSkKICAgICAgcmV0dXJuIG5leHQoKQogICAgfQoKICAgIC8vIDIuIFJlYWQg
YmFjayB0aGUgcm93IHdlIGVpdGhlciBqdXN0IGluc2VydGVkIG9yIHRoYXQgYWxyZWFkeSBleGlz
dGVkLgogICAgY29uc3Qgcm93cyA9IHBhcnNlUm93cyhhd2FpdCBkYi5ydW4oc3FsYAogICAgICBT
RUxFQ1Qgc3RhdHVzLCByZXNwb25zZV9zdGF0dXMsIHJlc3BvbnNlX2JvZHksIHJlcXVlc3RfZmlu
Z2VycHJpbnQsIGNyZWF0ZWRfYXQKICAgICAgRlJPTSBpZGVtcG90ZW5jeV9rZXlzIFdIRVJFIHNj
b3BlID0gJHtzY29wZX0gQU5EIGlkZW1wb3RlbmN5X2tleSA9ICR7a2V5fSBMSU1JVCAxYCkpCiAg
ICBjb25zdCByb3cgPSByb3dzWzBdCgogICAgLy8gU2hvdWxkbid0IGhhcHBlbiAod2UganVzdCBp
bnNlcnRlZCksIGJ1dCBiZSBzYWZlOiBwcm9jZWVkLgogICAgaWYgKCFyb3cpIHJldHVybiBuZXh0
KCkKCiAgICBjb25zdCByb3dTdGF0dXMgPSBTdHJpbmcocm93LnN0YXR1cyA/PyByb3dbMF0pCiAg
ICBjb25zdCByb3dGcCAgICAgPSBTdHJpbmcocm93LnJlcXVlc3RfZmluZ2VycHJpbnQgPz8gcm93
WzNdID8/ICcnKQogICAgY29uc3QgY3JlYXRlZEF0ID0gTnVtYmVyKHJvdy5jcmVhdGVkX2F0ID8/
IHJvd1s0XSA/PyBub3cpCgogICAgLy8gU2FtZSBrZXksIGRpZmZlcmVudCBwYXlsb2FkIC0+IHJl
ZnVzZS4KICAgIGlmIChyb3dGcCAmJiByb3dGcCAhPT0gZnApIHsKICAgICAgcmV0dXJuIHJlcy5z
dGF0dXMoNDIyKS5qc29uKHsKICAgICAgICBlcnJvcjogJ0lkZW1wb3RlbmN5LUtleSB3YXMgYWxy
ZWFkeSB1c2VkIHdpdGggYSBkaWZmZXJlbnQgcmVxdWVzdCBib2R5LicsCiAgICAgICAgY29kZTog
ICdpZGVtcG90ZW5jeV9rZXlfcmV1c2UnLAogICAgICB9KQogICAgfQoKICAgIC8vIDNhLiBBbHJl
YWR5IGNvbXBsZXRlZCAtPiByZXBsYXkgdGhlIGNhY2hlZCByZXNwb25zZS4KICAgIGlmIChyb3dT
dGF0dXMgPT09ICdjb21wbGV0ZWQnKSB7CiAgICAgIGNvbnN0IHN0YXR1cyA9IE51bWJlcihyb3cu
cmVzcG9uc2Vfc3RhdHVzID8/IHJvd1sxXSA/PyAyMDApCiAgICAgIGxldCBib2R5OiBhbnkgPSB7
fQogICAgICB0cnkgeyBib2R5ID0gSlNPTi5wYXJzZShTdHJpbmcocm93LnJlc3BvbnNlX2JvZHkg
Pz8gcm93WzJdID8/ICd7fScpKSB9IGNhdGNoIHt9CiAgICAgIHJlcy5zZXRIZWFkZXIoJ0lkZW1w
b3RlbnQtUmVwbGF5JywgJ3RydWUnKQogICAgICByZXR1cm4gcmVzLnN0YXR1cyhzdGF0dXMpLmpz
b24oYm9keSkKICAgIH0KCiAgICAvLyAzYi4gSW4gcHJvZ3Jlc3MuIElmIGl0J3MgT1VSIGZyZXNo
IHJlc2VydmF0aW9uICh3ZSB3b24gdGhlIGluc2VydCB0aGlzCiAgICAvLyAgICAgcmVxdWVzdCks
IGZhbGwgdGhyb3VnaCBhbmQgcnVuIHRoZSBoYW5kbGVyLiBJZiBpdCBiZWxvbmdzIHRvIGFub3Ro
ZXIKICAgIC8vICAgICBpbi1mbGlnaHQgcmVxdWVzdCwgNDA5IC0gdW5sZXNzIGl0J3Mgc3RhbGUg
KGNyYXNoZWQgaGFuZGxlciksIHdoaWNoCiAgICAvLyAgICAgd2UgcmVjbGFpbSBieSBwcm9jZWVk
aW5nLgogICAgLy8gICAgIFdlIGRpc3Rpbmd1aXNoICJvdXJzIiBieSB3aGV0aGVyIHRoZSByZXNl
cnZhdGlvbiB0aW1lc3RhbXAgaXMgdGhpcwogICAgLy8gICAgIHJlcXVlc3QncyBgbm93YCBBTkQg
bm8gb3RoZXIgaGFzIGNvbXBsZXRlZCBpdCAtIHNpbXBsZXN0IGNvcnJlY3QgcnVsZToKICAgIC8v
ICAgICBpZiByZXNlcnZlZCB3aXRoaW4gdGhpcyB0aWNrIHRyZWF0IGFzIG91cnM7IG90aGVyd2lz
ZSBpZiBub3Qgc3RhbGUsCiAgICAvLyAgICAgaXQncyBhIGNvbmN1cnJlbnQgZHVwbGljYXRlLgog
ICAgY29uc3QgYWdlID0gbm93IC0gY3JlYXRlZEF0CiAgICBjb25zdCBpc0ZyZXNobHlPdXJzID0g
YWdlIDw9IDAKICAgIGlmICghaXNGcmVzaGx5T3VycyAmJiBhZ2UgPCBTVEFMRV9TRUNPTkRTKSB7
CiAgICAgIHJldHVybiByZXMuc3RhdHVzKDQwOSkuanNvbih7CiAgICAgICAgZXJyb3I6ICdBIHJl
cXVlc3Qgd2l0aCB0aGlzIElkZW1wb3RlbmN5LUtleSBpcyBhbHJlYWR5IGJlaW5nIHByb2Nlc3Nl
ZC4nLAogICAgICAgIGNvZGU6ICAnaWRlbXBvdGVuY3lfaW5fcHJvZ3Jlc3MnLAogICAgICB9KQog
ICAgfQogICAgLy8gc3RhbGUgb3Igb3VycyAtPiBwcm9jZWVkIHRvIHJ1biB0aGUgaGFuZGxlci4K
CiAgICAvLyA0LiBJbnRlcmNlcHQgdGhlIHJlc3BvbnNlIHNvIHdlIGNhbiBjYWNoZSBpdCBvbmNl
IHRoZSBoYW5kbGVyIHJlcGxpZXMuCiAgICBjb25zdCBvcmlnaW5hbEpzb24gPSByZXMuanNvbi5i
aW5kKHJlcykKICAgIGxldCBjYWNoZWQgPSBmYWxzZQogICAgOyhyZXMgYXMgYW55KS5qc29uID0g
KGJvZHk6IGFueSkgPT4gewogICAgICBpZiAoIWNhY2hlZCkgewogICAgICAgIGNhY2hlZCA9IHRy
dWUKICAgICAgICBjb25zdCBkb25lQXQgPSBNYXRoLmZsb29yKERhdGUubm93KCkgLyAxMDAwKQog
ICAgICAgIGNvbnN0IHN0YXR1c0NvZGUgPSByZXMuc3RhdHVzQ29kZSB8fCAyMDAKICAgICAgICAv
LyBPbmx5IGNhY2hlIFNVQ0NFU1NGVUwgcmVzcG9uc2VzLiBBIDR4eC81eHggc2hvdWxkIGJlIHJl
dHJ5YWJsZSB3aXRoCiAgICAgICAgLy8gdGhlIHNhbWUga2V5ICh0aGUgbW9uZXkgZGlkbid0IG1v
dmUpLCBzbyB3ZSBSRUxFQVNFIHRoZSByZXNlcnZhdGlvbgogICAgICAgIC8vIGluc3RlYWQgb2Yg
Y2FjaGluZyBhIGZhaWx1cmUuCiAgICAgICAgaWYgKHN0YXR1c0NvZGUgPj0gMjAwICYmIHN0YXR1
c0NvZGUgPCAzMDApIHsKICAgICAgICAgIGxldCBib2R5U3RyID0gJ3t9JwogICAgICAgICAgdHJ5
IHsgYm9keVN0ciA9IEpTT04uc3RyaW5naWZ5KGJvZHkgPz8ge30pIH0gY2F0Y2gge30KICAgICAg
ICAgIGRiLnJ1bihzcWxgCiAgICAgICAgICAgIFVQREFURSBpZGVtcG90ZW5jeV9rZXlzCiAgICAg
ICAgICAgIFNFVCBzdGF0dXMgPSAnY29tcGxldGVkJywgcmVzcG9uc2Vfc3RhdHVzID0gJHtzdGF0
dXNDb2RlfSwKICAgICAgICAgICAgICAgIHJlc3BvbnNlX2JvZHkgPSAke2JvZHlTdHJ9LCBjb21w
bGV0ZWRfYXQgPSAke2RvbmVBdH0KICAgICAgICAgICAgV0hFUkUgc2NvcGUgPSAke3Njb3BlfSBB
TkQgaWRlbXBvdGVuY3lfa2V5ID0gJHtrZXl9YCkuY2F0Y2goKCkgPT4ge30pCiAgICAgICAgfSBl
bHNlIHsKICAgICAgICAgIGRiLnJ1bihzcWxgCiAgICAgICAgICAgIERFTEVURSBGUk9NIGlkZW1w
b3RlbmN5X2tleXMKICAgICAgICAgICAgV0hFUkUgc2NvcGUgPSAke3Njb3BlfSBBTkQgaWRlbXBv
dGVuY3lfa2V5ID0gJHtrZXl9YCkuY2F0Y2goKCkgPT4ge30pCiAgICAgICAgfQogICAgICB9CiAg
ICAgIHJldHVybiBvcmlnaW5hbEpzb24oYm9keSkKICAgIH0KCiAgICByZXR1cm4gbmV4dCgpCiAg
fQp9Cg==
B64MW
base64 -d > "$TSQL" <<'B64SQL'
LS0gPT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
PT09PT09Ci0tIDAwMjZfaWRlbXBvdGVuY3lfa2V5cy5zcWwKLS0gUGhhc2UgNyBIYXJkZW5pbmcg
LSByZXF1ZXN0LWxldmVsIGlkZW1wb3RlbmN5IGZvciBtb25leS1tb3ZpbmcgZW5kcG9pbnRzLgot
LQotLSBHdWFyZHMgdGhlIHRpZ2h0ZXN0IG1vbmV5IHBhdGggKFBPU1QgL3RyYW5zZmVycywgL3Ry
YW5zZmVycy9jYXNob3V0LAotLSAvcGF5bWVudHMpIGFnYWluc3QgZG91YmxlIGV4ZWN1dGlvbiBm
cm9tIGEgcmV0cmllZCBvciBkb3VibGUtdGFwcGVkIHJlcXVlc3QuCi0tIEEgY2xpZW50IHNlbmRz
IGFuIElkZW1wb3RlbmN5LUtleSBoZWFkZXI7IHRoZSBmaXJzdCByZXF1ZXN0IGZvciBhIGdpdmVu
Ci0tIChzY29wZSwga2V5KSBydW5zIGFuZCBjYWNoZXMgaXRzIHJlc3BvbnNlLCBhbmQgYW55IHJl
cGxheSByZXR1cm5zIHRoYXQgc2FtZQotLSBjYWNoZWQgc3RhdHVzICsgYm9keSBpbnN0ZWFkIG9m
IG1vdmluZyBtb25leSBhZ2Fpbi4KLS0KLS0gTWlycm9ycyB0aGUgZXhpc3RpbmcgcmFtcF93ZWJo
b29rX2V2ZW50cyBkZWR1cGUgcGF0dGVybiAoYSBQUklNQVJZIEtFWSBwbHVzCi0tIElOU0VSVCBP
UiBJR05PUkUpLiBUaGUgKHNjb3BlLCBrZXkpIGNvbXBvc2l0ZSBsZXRzIHRoZSBzYW1lIGNsaWVu
dC1nZW5lcmF0ZWQKLS0ga2V5IGJlIHJldXNlZCBhY3Jvc3MgZGlmZmVyZW50IGVuZHBvaW50cyB3
aXRob3V0IGNvbGxpZGluZy4KLS0KLS0gTGlmZWN5Y2xlIG9mIGEgcm93OgotLSAgIHN0YXR1cyA9
ICdpbl9wcm9ncmVzcycgIHJlc2VydmVkIHRoZSBpbnN0YW50IGEgbmV3IGtleSBhcnJpdmVzOyBh
IGNvbmN1cnJlbnQKLS0gICAgICAgICAgICAgICAgICAgICAgICAgICByZXBsYXkgd2hpbGUgdGhl
IGhhbmRsZXIgcnVucyBnZXRzIDQwOSAobm8gZG91YmxlCi0tICAgICAgICAgICAgICAgICAgICAg
ICAgICAgZXhlY3V0aW9uIHdpbmRvdykuCi0tICAgc3RhdHVzID0gJ2NvbXBsZXRlZCcgICAgaGFu
ZGxlciBmaW5pc2hlZDsgcmVzcG9uc2Vfc3RhdHVzICsgcmVzcG9uc2VfYm9keQotLSAgICAgICAg
ICAgICAgICAgICAgICAgICAgIGFyZSB0aGUgY2FjaGVkIHJlcGx5IHRvIHJlcGxheS4KLS0gQSBj
cmFzaGVkIGhhbmRsZXIgbGVhdmVzIGFuICdpbl9wcm9ncmVzcycgcm93OyBpdCBpcyByZWNsYWlt
YWJsZSBhZnRlcgotLSBJREVNUE9URU5DWV9TVEFMRV9TRUNPTkRTICh0aGUgbWlkZGxld2FyZSB0
cmVhdHMgYSBzdGFsZSByZXNlcnZhdGlvbiBhcwotLSByZXRyeWFibGUgcmF0aGVyIHRoYW4gd2Vk
Z2luZyB0aGUga2V5IGZvcmV2ZXIpLgotLQotLSBObyBQSUkgYmV5b25kIHdoYXQgdGhlIGVuZHBv
aW50IGFscmVhZHkgcmV0dXJucyB0byB0aGUgc2FtZSBjYWxsZXI6IHRoZQotLSBjYWNoZWQgYm9k
eSBpcyBleGFjdGx5IHRoZSBKU09OIHRoYXQgY2FsbGVyIHJlY2VpdmVkLgotLSA9PT09PT09PT09
PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT0KCkNSRUFU
RSBUQUJMRSBJRiBOT1QgRVhJU1RTIGlkZW1wb3RlbmN5X2tleXMgKAogIHNjb3BlICAgICAgICAg
ICAgVEVYVCAgICBOT1QgTlVMTCwgICAgICAgICAgLS0gZS5nLiAndHJhbnNmZXJzLmNyZWF0ZScK
ICBpZGVtcG90ZW5jeV9rZXkgIFRFWFQgICAgTk9UIE5VTEwsICAgICAgICAgIC0tIGNsaWVudC1z
dXBwbGllZCBJZGVtcG90ZW5jeS1LZXkKICBzdGF0dXMgICAgICAgICAgIFRFWFQgICAgTk9UIE5V
TEwsICAgICAgICAgIC0tICdpbl9wcm9ncmVzcycgfCAnY29tcGxldGVkJwogIHJlc3BvbnNlX3N0
YXR1cyAgSU5URUdFUiwgICAgICAgICAgICAgICAgICAgLS0gY2FjaGVkIEhUVFAgc3RhdHVzICh3
aGVuIGNvbXBsZXRlZCkKICByZXNwb25zZV9ib2R5ICAgIFRFWFQsICAgICAgICAgICAgICAgICAg
ICAgIC0tIGNhY2hlZCBKU09OIGJvZHkgKHdoZW4gY29tcGxldGVkKQogIHJlcXVlc3RfZmluZ2Vy
cHJpbnQgVEVYVCwgICAgICAgICAgICAgICAgICAgLS0gc2hhMjU2IG9mIHRoZSBib2R5LCB0byBj
YXRjaCBrZXkgcmV1c2Ugd2l0aCBhIGRpZmZlcmVudCBwYXlsb2FkCiAgY3JlYXRlZF9hdCAgICAg
ICBJTlRFR0VSIE5PVCBOVUxMLCAgICAgICAgICAtLSB1bml4IHNlY29uZHMsIHJlc2VydmF0aW9u
IHRpbWUKICBjb21wbGV0ZWRfYXQgICAgIElOVEVHRVIsICAgICAgICAgICAgICAgICAgIC0tIHVu
aXggc2Vjb25kcywgd2hlbiBjYWNoZWQKICBQUklNQVJZIEtFWSAoc2NvcGUsIGlkZW1wb3RlbmN5
X2tleSkKKTsKCkNSRUFURSBJTkRFWCBJRiBOT1QgRVhJU1RTIGlkeF9pZGVtcG90ZW5jeV9rZXlz
X2NyZWF0ZWQKICBPTiBpZGVtcG90ZW5jeV9rZXlzIChjcmVhdGVkX2F0KTsK
B64SQL
base64 -d > "$TPATCH" <<'B64PATCH'
IyEvdXNyL2Jpbi9lbnYgcHl0aG9uMwoiIiIKUGhhc2UgNyBQYXJ0IDIgcm91dGUgcGF0Y2hlciAt
IHdpcmUgd2l0aElkZW1wb3RlbmN5IGludG8gdGhlIHRpZ2h0ZXN0IG1vbmV5IHBhdGguCgpFZGl0
czoKICBuZXh1bS1hcGkvc3JjL3JvdXRlcy90cmFuc2ZlcnMudHMKICAgICogaW1wb3J0IHdpdGhJ
ZGVtcG90ZW5jeQogICAgKiBQT1NUIC8gICAgICAgICAgLT4gd2l0aElkZW1wb3RlbmN5KCd0cmFu
c2ZlcnMuY3JlYXRlJykKICAgICogUE9TVCAvY2FzaG91dCAgIC0+IHdpdGhJZGVtcG90ZW5jeSgn
dHJhbnNmZXJzLmNhc2hvdXQnKQogIG5leHVtLWFwaS9zcmMvcm91dGVzL3BheW1lbnRzLnRzCiAg
ICAqIGltcG9ydCB3aXRoSWRlbXBvdGVuY3kKICAgICogUE9TVCAvICAgICAgICAgIC0+IHdpdGhJ
ZGVtcG90ZW5jeSgncGF5bWVudHMuY3JlYXRlJykKCklkZW1wb3RlbnQgdmlhIHRoZSBfX05FWFVN
X0lERU1QT1RFTkNZX1dJUkVEX18gbWFya2VyIGluIGVhY2ggZmlsZS4KRXhhY3QtYW5jaG9yOyBh
Ym9ydHMgY2xlYW4gb24gZHJpZnQuCiIiIgppbXBvcnQgc3lzLCBpbwoKZGVmIHBhdGNoKHBhdGgs
IGVkaXRzLCBtYXJrZXIpOgogICAgc3JjID0gaW8ub3BlbihwYXRoLCBlbmNvZGluZz0idXRmLTgi
KS5yZWFkKCkKICAgIGlmIG1hcmtlciBpbiBzcmM6CiAgICAgICAgcHJpbnQoZiIgIHtwYXRofTog
YWxyZWFkeSB3aXJlZCAtIHNraXBwaW5nLiIpCiAgICAgICAgcmV0dXJuCiAgICBmb3IgZGVzYywg
b2xkLCBuZXcgaW4gZWRpdHM6CiAgICAgICAgbiA9IHNyYy5jb3VudChvbGQpCiAgICAgICAgaWYg
biAhPSAxOgogICAgICAgICAgICBwcmludChmIkVSUk9SIFt7cGF0aH1dOiBhbmNob3IgJ3tkZXNj
fScgbWF0Y2hlZCB7bn0gdGltZXMgKGV4cGVjdGVkIDEpLiBBYm9ydGluZy4iKQogICAgICAgICAg
ICBzeXMuZXhpdCgyKQogICAgICAgIHNyYyA9IHNyYy5yZXBsYWNlKG9sZCwgbmV3KQogICAgaW8u
b3BlbihwYXRoLCAidyIsIGVuY29kaW5nPSJ1dGYtOCIpLndyaXRlKHNyYykKICAgIHByaW50KGYi
ICB7cGF0aH06IHdpcmVkLiIpCgojIC0tLS0gdHJhbnNmZXJzLnRzIC0tLS0KdHJhbnNmZXJzID0g
Im5leHVtLWFwaS9zcmMvcm91dGVzL3RyYW5zZmVycy50cyIKcGF0Y2godHJhbnNmZXJzLCBbCiAg
ICAoImltcG9ydCIsCiAgICAgImltcG9ydCB7IHN0YXJ0Q2FzaE91dCB9IGZyb20gJy4uL3NlcnZp
Y2VzL2Nhc2hvdXQnIiwKICAgICAiaW1wb3J0IHsgc3RhcnRDYXNoT3V0IH0gZnJvbSAnLi4vc2Vy
dmljZXMvY2FzaG91dCdcbiIKICAgICAiLy8gX19ORVhVTV9JREVNUE9URU5DWV9XSVJFRF9fIChw
aGFzZTcpIHJlcXVlc3QtbGV2ZWwgaWRlbXBvdGVuY3lcbiIKICAgICAiaW1wb3J0IHsgd2l0aElk
ZW1wb3RlbmN5IH0gZnJvbSAnLi4vbWlkZGxld2FyZS9pZGVtcG90ZW5jeSciKSwKICAgICgiY2Fz
aG91dCByb3V0ZSIsCiAgICAgInJvdXRlci5wb3N0KCcvY2FzaG91dCcsIGFzeW5jIChyZXEsIHJl
cykgPT4geyIsCiAgICAgInJvdXRlci5wb3N0KCcvY2FzaG91dCcsIHdpdGhJZGVtcG90ZW5jeSgn
dHJhbnNmZXJzLmNhc2hvdXQnKSwgYXN5bmMgKHJlcSwgcmVzKSA9PiB7IiksCiAgICAoImNyZWF0
ZSByb3V0ZSIsCiAgICAgIi8vIOKUgOKUgCBTdGFydCBhIHRyYW5zZmVyIOKUgOKUgOKUgOKUgOKU
gOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKU
gOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgFxucm91dGVyLnBv
c3QoJy8nLCBhc3luYyAocmVxLCByZXMpID0+IHsiLAogICAgICIvLyDilIDilIAgU3RhcnQgYSB0
cmFuc2ZlciDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDi
lIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDi
lIDilIDilIDilIBcbnJvdXRlci5wb3N0KCcvJywgd2l0aElkZW1wb3RlbmN5KCd0cmFuc2ZlcnMu
Y3JlYXRlJyksIGFzeW5jIChyZXEsIHJlcykgPT4geyIpLApdLCAiX19ORVhVTV9JREVNUE9URU5D
WV9XSVJFRF9fIikKCiMgLS0tLSBwYXltZW50cy50cyAtLS0tCnBheW1lbnRzID0gIm5leHVtLWFw
aS9zcmMvcm91dGVzL3BheW1lbnRzLnRzIgpwYXRjaChwYXltZW50cywgWwogICAgKCJpbXBvcnQi
LAogICAgICJpbXBvcnQgeyBnZXRDYWNoZWRSYXRlcyB9IGZyb20gJy4uL3NlcnZpY2VzL3JhdGVP
cmFjbGUnIiwKICAgICAiaW1wb3J0IHsgZ2V0Q2FjaGVkUmF0ZXMgfSBmcm9tICcuLi9zZXJ2aWNl
cy9yYXRlT3JhY2xlJ1xuIgogICAgICIvLyBfX05FWFVNX0lERU1QT1RFTkNZX1dJUkVEX18gKHBo
YXNlNykgcmVxdWVzdC1sZXZlbCBpZGVtcG90ZW5jeVxuIgogICAgICJpbXBvcnQgeyB3aXRoSWRl
bXBvdGVuY3kgfSBmcm9tICcuLi9taWRkbGV3YXJlL2lkZW1wb3RlbmN5JyIpLAogICAgKCJjcmVh
dGUgcm91dGUiLAogICAgICJyb3V0ZXIucG9zdCgnLycsIGFzeW5jIChyZXEsIHJlcykgPT4ge1xu
ICBjb25zdCB7XG4gICAgc2VuZGVyQWRkcmVzcywgcmVjaXBpZW50QWRkcmVzcywgYW1vdW50LCIs
CiAgICAgInJvdXRlci5wb3N0KCcvJywgd2l0aElkZW1wb3RlbmN5KCdwYXltZW50cy5jcmVhdGUn
KSwgYXN5bmMgKHJlcSwgcmVzKSA9PiB7XG4gIGNvbnN0IHtcbiAgICBzZW5kZXJBZGRyZXNzLCBy
ZWNpcGllbnRBZGRyZXNzLCBhbW91bnQsIiksCl0sICJfX05FWFVNX0lERU1QT1RFTkNZX1dJUkVE
X18iKQoKcHJpbnQoIlJvdXRlIHdpcmluZyBjb21wbGV0ZS4iKQo=
B64PATCH
base64 -d > "$TTEST" <<'B64TEST'
aW1wb3J0IHsgZGVzY3JpYmUsIGl0LCBleHBlY3QsIGJlZm9yZUFsbCwgYWZ0ZXJBbGwgfSBmcm9t
ICd2aXRlc3QnCmltcG9ydCB7IGNyZWF0ZUNsaWVudCwgdHlwZSBDbGllbnQgfSBmcm9tICdAbGli
c3FsL2NsaWVudCcKaW1wb3J0IHsgcmVhZEZpbGVTeW5jIH0gZnJvbSAnbm9kZTpmcycKaW1wb3J0
IHsgam9pbiB9IGZyb20gJ25vZGU6cGF0aCcKaW1wb3J0IHsgc3BsaXRTdGF0ZW1lbnRzIH0gZnJv
bSAnLi4vc3JjL2RiL21pZ3JhdGUtbGliJwoKLy8gPT09PT09PT09PT09PT09PT09PT09PT09PT09
PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PQovLyBJZGVt
cG90ZW5jeSBndWFyZCAtIG1pZ3JhdGlvbiArIHRhYmxlIHNlbWFudGljcyAoUGhhc2UgNyBIYXJk
ZW5pbmcpLgovLwovLyBQcm92ZXMgdGhlIHJlcXVlc3QtbGV2ZWwgaWRlbXBvdGVuY3kgdGFibGUg
YmVoYXZlcyB0aGUgd2F5IHRoZSBtaWRkbGV3YXJlCi8vIHJlbGllcyBvbjogYSBzaW5nbGUgcmVz
ZXJ2YXRpb24gcGVyIChzY29wZSwga2V5KSwgSU5TRVJUIE9SIElHTk9SRSBtYWtpbmcgYQovLyBj
b25jdXJyZW50IGR1cGxpY2F0ZSBhIG5vLW9wLCBjYWNoZWQtcmVzcG9uc2UgcmVwbGF5LCBmaW5n
ZXJwcmludCBjYXB0dXJlIGZvcgovLyBrZXktcmV1c2UgZGV0ZWN0aW9uLCBhbmQgc2NvcGUgaXNv
bGF0aW9uLiBSdW5zIGFnYWluc3QgYSB0aHJvd2F3YXkgbGlic3FsCi8vIGZpbGUgREIsIGFwcGx5
aW5nIHRoZSByZWFsIDAwMjYgbWlncmF0aW9uIHRocm91Z2ggdGhlIHJlYWwgc3BsaXRTdGF0ZW1l
bnRzCi8vIHNvIHdlIGV4ZXJjaXNlIGV4YWN0bHkgd2hhdCBgbnBtIHJ1biBtaWdyYXRlYCB3b3Vs
ZC4KLy8gPT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
PT09PT09PT09PT09PT09PT09PT09PT09PQoKY29uc3QgREJfUEFUSCA9IGpvaW4oJy90bXAnLCBg
aWRlbS12aXRlc3QtJHtwcm9jZXNzLnBpZH0uZGJgKQpsZXQgY2xpZW50OiBDbGllbnQKCmNvbnN0
IG5vdyA9ICgpID0+IE1hdGguZmxvb3IoRGF0ZS5ub3coKSAvIDEwMDApCgpiZWZvcmVBbGwoYXN5
bmMgKCkgPT4gewogIGNsaWVudCA9IGNyZWF0ZUNsaWVudCh7IHVybDogYGZpbGU6JHtEQl9QQVRI
fWAgfSkKICBjb25zdCBzcWxUZXh0ID0gcmVhZEZpbGVTeW5jKGpvaW4oJ21pZ3JhdGlvbnMnLCAn
MDAyNl9pZGVtcG90ZW5jeV9rZXlzLnNxbCcpLCAndXRmOCcpCiAgZm9yIChjb25zdCBzdG10IG9m
IHNwbGl0U3RhdGVtZW50cyhzcWxUZXh0KSkgewogICAgYXdhaXQgY2xpZW50LmV4ZWN1dGUoc3Rt
dCkKICB9Cn0pCgphZnRlckFsbChhc3luYyAoKSA9PiB7CiAgY2xpZW50LmNsb3NlKCkKICB0cnkg
eyByZXF1aXJlKCdub2RlOmZzJykudW5saW5rU3luYyhEQl9QQVRIKSB9IGNhdGNoIHt9Cn0pCgph
c3luYyBmdW5jdGlvbiByZXNlcnZlKHNjb3BlOiBzdHJpbmcsIGtleTogc3RyaW5nLCBmcDogc3Ry
aW5nKSB7CiAgYXdhaXQgY2xpZW50LmV4ZWN1dGUoewogICAgc3FsOiBgSU5TRVJUIE9SIElHTk9S
RSBJTlRPIGlkZW1wb3RlbmN5X2tleXMKICAgICAgICAgICAgKHNjb3BlLCBpZGVtcG90ZW5jeV9r
ZXksIHN0YXR1cywgcmVxdWVzdF9maW5nZXJwcmludCwgY3JlYXRlZF9hdCkKICAgICAgICAgIFZB
TFVFUyAoPywgPywgJ2luX3Byb2dyZXNzJywgPywgPylgLAogICAgYXJnczogW3Njb3BlLCBrZXks
IGZwLCBub3coKV0sCiAgfSkKfQphc3luYyBmdW5jdGlvbiByZWFkKHNjb3BlOiBzdHJpbmcsIGtl
eTogc3RyaW5nKSB7CiAgY29uc3QgciA9IGF3YWl0IGNsaWVudC5leGVjdXRlKHsKICAgIHNxbDog
YFNFTEVDVCBzdGF0dXMsIHJlc3BvbnNlX3N0YXR1cywgcmVzcG9uc2VfYm9keSwgcmVxdWVzdF9m
aW5nZXJwcmludAogICAgICAgICAgRlJPTSBpZGVtcG90ZW5jeV9rZXlzIFdIRVJFIHNjb3BlID0g
PyBBTkQgaWRlbXBvdGVuY3lfa2V5ID0gP2AsCiAgICBhcmdzOiBbc2NvcGUsIGtleV0sCiAgfSkK
ICByZXR1cm4gci5yb3dzWzBdIGFzIGFueQp9CmFzeW5jIGZ1bmN0aW9uIGNvbXBsZXRlKHNjb3Bl
OiBzdHJpbmcsIGtleTogc3RyaW5nLCBzdGF0dXM6IG51bWJlciwgYm9keTogdW5rbm93bikgewog
IGF3YWl0IGNsaWVudC5leGVjdXRlKHsKICAgIHNxbDogYFVQREFURSBpZGVtcG90ZW5jeV9rZXlz
CiAgICAgICAgICBTRVQgc3RhdHVzID0gJ2NvbXBsZXRlZCcsIHJlc3BvbnNlX3N0YXR1cyA9ID8s
IHJlc3BvbnNlX2JvZHkgPSA/LCBjb21wbGV0ZWRfYXQgPSA/CiAgICAgICAgICBXSEVSRSBzY29w
ZSA9ID8gQU5EIGlkZW1wb3RlbmN5X2tleSA9ID9gLAogICAgYXJnczogW3N0YXR1cywgSlNPTi5z
dHJpbmdpZnkoYm9keSksIG5vdygpLCBzY29wZSwga2V5XSwKICB9KQp9CmFzeW5jIGZ1bmN0aW9u
IGNvdW50KHNjb3BlOiBzdHJpbmcsIGtleTogc3RyaW5nKSB7CiAgY29uc3QgciA9IGF3YWl0IGNs
aWVudC5leGVjdXRlKHsKICAgIHNxbDogYFNFTEVDVCBDT1VOVCgqKSBBUyBjIEZST00gaWRlbXBv
dGVuY3lfa2V5cyBXSEVSRSBzY29wZSA9ID8gQU5EIGlkZW1wb3RlbmN5X2tleSA9ID9gLAogICAg
YXJnczogW3Njb3BlLCBrZXldLAogIH0pCiAgcmV0dXJuIE51bWJlcigoci5yb3dzWzBdIGFzIGFu
eSkuYykKfQoKZGVzY3JpYmUoJ2lkZW1wb3RlbmN5X2tleXMgdGFibGUnLCAoKSA9PiB7CiAgaXQo
J3Jlc2VydmVzIGEgbmV3IGtleSBhcyBpbl9wcm9ncmVzcycsIGFzeW5jICgpID0+IHsKICAgIGF3
YWl0IHJlc2VydmUoJ3RyYW5zZmVycy5jcmVhdGUnLCAnSzEnLCAnZnBBJykKICAgIGV4cGVjdCgo
YXdhaXQgcmVhZCgndHJhbnNmZXJzLmNyZWF0ZScsICdLMScpKS5zdGF0dXMpLnRvQmUoJ2luX3By
b2dyZXNzJykKICB9KQoKICBpdCgnYSBjb25jdXJyZW50IGR1cGxpY2F0ZSByZXNlcnZhdGlvbiBp
cyBhIG5vLW9wIChzaW5nbGUgcm93KScsIGFzeW5jICgpID0+IHsKICAgIGF3YWl0IHJlc2VydmUo
J3RyYW5zZmVycy5jcmVhdGUnLCAnSzEnLCAnZnBBJykKICAgIGV4cGVjdChhd2FpdCBjb3VudCgn
dHJhbnNmZXJzLmNyZWF0ZScsICdLMScpKS50b0JlKDEpCiAgfSkKCiAgaXQoJ2NhY2hlcyBhIGNv
bXBsZXRlZCByZXNwb25zZSBmb3IgcmVwbGF5JywgYXN5bmMgKCkgPT4gewogICAgYXdhaXQgY29t
cGxldGUoJ3RyYW5zZmVycy5jcmVhdGUnLCAnSzEnLCAyMDEsIHsgdHJhbnNmZXJJZDogJ1QtMTIz
JyB9KQogICAgY29uc3Qgcm93ID0gYXdhaXQgcmVhZCgndHJhbnNmZXJzLmNyZWF0ZScsICdLMScp
CiAgICBleHBlY3Qocm93LnN0YXR1cykudG9CZSgnY29tcGxldGVkJykKICAgIGV4cGVjdChOdW1i
ZXIocm93LnJlc3BvbnNlX3N0YXR1cykpLnRvQmUoMjAxKQogICAgZXhwZWN0KEpTT04ucGFyc2Uo
cm93LnJlc3BvbnNlX2JvZHkpLnRyYW5zZmVySWQpLnRvQmUoJ1QtMTIzJykKICB9KQoKICBpdCgn
c3RvcmVzIHRoZSByZXF1ZXN0IGZpbmdlcnByaW50IGZvciBrZXktcmV1c2UgZGV0ZWN0aW9uJywg
YXN5bmMgKCkgPT4gewogICAgZXhwZWN0KChhd2FpdCByZWFkKCd0cmFuc2ZlcnMuY3JlYXRlJywg
J0sxJykpLnJlcXVlc3RfZmluZ2VycHJpbnQpLnRvQmUoJ2ZwQScpCiAgfSkKCiAgaXQoJ2lzb2xh
dGVzIHRoZSBzYW1lIGtleSBhY3Jvc3MgZGlmZmVyZW50IHNjb3BlcycsIGFzeW5jICgpID0+IHsK
ICAgIGF3YWl0IHJlc2VydmUoJ3BheW1lbnRzLmNyZWF0ZScsICdLMScsICdmcFonKQogICAgZXhw
ZWN0KChhd2FpdCByZWFkKCdwYXltZW50cy5jcmVhdGUnLCAnSzEnKSkuc3RhdHVzKS50b0JlKCdp
bl9wcm9ncmVzcycpCiAgICAvLyB0aGUgdHJhbnNmZXJzLXNjb3BlZCBLMSBpcyBzdGlsbCBjb21w
bGV0ZWQsIHVudG91Y2hlZAogICAgZXhwZWN0KChhd2FpdCByZWFkKCd0cmFuc2ZlcnMuY3JlYXRl
JywgJ0sxJykpLnN0YXR1cykudG9CZSgnY29tcGxldGVkJykKICB9KQp9KQo=
B64TEST

verify(){ local got; got="$( (sha256sum "$1" 2>/dev/null || shasum -a 256 "$1") | awk '{print $1}')"; [ "$got" = "$2" ] || die "Checksum mismatch for $1 (got $got). Nothing written."; }
verify "$TMW" "$MW_SHA"; verify "$TSQL" "$SQL_SHA"; verify "$TPATCH" "$PATCH_SHA"; verify "$TTEST" "$TEST_SHA"
log "All four payloads verified."

mkdir -p "$BACKUP_DIR"
# Only back up a route that is NOT already wired, so an idempotent re-run can't
# overwrite the clean backup with an already-modified copy (which would make
# --revert restore the wired version).
if [ -f "$TRANSFERS" ] && ! grep -qF "$MARKER" "$TRANSFERS"; then cp "$TRANSFERS" "$BACKUP_DIR/transfers.ts"; fi
if [ -f "$PAYMENTS" ]  && ! grep -qF "$MARKER" "$PAYMENTS";  then cp "$PAYMENTS"  "$BACKUP_DIR/payments.ts";  fi

# place new files (idempotent)
mkdir -p "$API/src/middleware" "$API/tests" "$API/migrations"
if [ -f "$MW" ]; then log "middleware already present - leaving it."; else cp "$TMW" "$MW"; log "Added $MW"; fi
if [ -f "$SQLF" ]; then log "migration already present - leaving it."; else cp "$TSQL" "$SQLF"; log "Added $SQLF"; fi
if [ -f "$TESTF" ]; then log "test already present - leaving it."; else cp "$TTEST" "$TESTF"; log "Added $TESTF"; fi

# wire routes (idempotent via marker inside the patcher)
python3 "$TPATCH" || { 
  [ -f "$BACKUP_DIR/transfers.ts" ] && cp "$BACKUP_DIR/transfers.ts" "$TRANSFERS"
  [ -f "$BACKUP_DIR/payments.ts" ]  && cp "$BACKUP_DIR/payments.ts"  "$PAYMENTS"
  die "Route wiring failed; routes restored."
}

# ------------------------------------------------------------- gate: types + tests
log ""
log "=== tsc + tests ==="
( cd "$API" && npx tsc --noEmit ) || die "API tsc failed - not committing."
log "tsc clean."
( cd "$API" && npx vitest run ) || die "API tests failed - not committing."
log "tests pass."

if [ "$FLAG" = "--no-deploy" ]; then
  log "--no-deploy: applied + verified. Skipping migration, build, commit, push."
  log "Remember: run 'cd $API && npm run migrate' before this code serves traffic."
  exit 0
fi

# ------------------------------------------------------------- gate: migration
if [ "$FLAG" = "--skip-migrate" ]; then
  log "--skip-migrate: NOT running the DB migration. You MUST run"
  log "  cd $API && npm run migrate"
  log "against your DB before the new endpoints serve traffic (else the"
  log "idempotency_keys table is missing and the guard cannot write)."
else
  log ""
  log "=== DB migration: applying 0026_idempotency_keys to your configured DB ==="
  log "(uses TURSO_DATABASE_URL if set, else file:local.db - the same target as"
  log " every other migration. Re-running is safe; applied migrations are skipped.)"
  ( cd "$API" && npm run migrate ) || die "Migration failed - not committing. Fix DB access, then rerun."
  log "Migration applied."
fi

# ------------------------------------------------------------- commit + push
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "Not a git work tree; commit manually."
REMOTE="$(git remote | head -1 || true)"; [ -n "$REMOTE" ] || die "No git remote; commit/push manually."
BRANCH="$(git rev-parse --abbrev-ref HEAD)"
git add -A
if git diff --cached --quiet; then log "Nothing to commit."; exit 0; fi
log "Committing on '$BRANCH' -> '$REMOTE'..."
git commit -m "$COMMIT_MSG"
git push "$REMOTE" "$BRANCH"
log ""
log "Pushed Phase 7 Part 2. transfers/cashout/payments now honour Idempotency-Key."
log "Next: have the WEB client send a stable Idempotency-Key on these POSTs so"
log "real retries dedupe (I can deliver that as Part 2b)."
