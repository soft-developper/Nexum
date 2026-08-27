#!/usr/bin/env bash
# ============================================================================
# Nexum Phase 7 (Hardening) - Part 4: rate limiting on auth + txn endpoints
#
# The app-wide 100/min/IP limiter is a floor, too loose for what matters. This
# adds TIGHT, purpose-built limits:
#   * AUTH (per IP, default 10/min): /circle/email-otp, /session, admin /login,
#     /forgot-password, /reset-password  - blunts brute-force + credential stuffing
#   * TXN (per ACCOUNT, default 20/min): /wallet/tx/transfer, /wallet/tx/contract
#     - stops money-moving spam; keyed per account so one user's abuse never
#       rate-limits everyone behind a shared IP (NAT / mobile carriers)
#
# Ships:
#   APPEND src/middleware/rateLimit.ts  - createRateLimiter factory + authRateLimiter/txnRateLimiter (global limiter left intact)
#   NEW    tests/ratelimit.test.ts      - 5 tests (limit, 429+Retry-After, isolation, account fallback, window reset)
#   PATCH  routes/auth.ts + routes/adminAuth.ts  - apply the limiters
#
# Zero new dependencies. In-memory store (single instance) - see the note in the
# factory about moving to Redis if the API is ever horizontally scaled.
#
# CONFIG (optional): RATE_LIMIT_AUTH_MAX / RATE_LIMIT_AUTH_WINDOW_MS,
#                    RATE_LIMIT_TXN_MAX  / RATE_LIMIT_TXN_WINDOW_MS
#
# Delivery contract (v2) + full deploy:
#   * payloads base64 + sha256 verified; exact-anchor patch; aborts on drift
#   * idempotent (__NEXUM_RATELIMIT_STRICT__ / __NEXUM_RATELIMIT_WIRED__)
#   * clean-only backups; gate: tsc --noEmit -> vitest run -> commit + push
#   * --revert restores all 3 files + removes the test
#   * --no-deploy applies + verifies only
#
# Run from REPO ROOT (folder containing nexum-api/).
#   bash nexum-phase7-part4-ratelimit.sh
#   bash nexum-phase7-part4-ratelimit.sh --no-deploy
#   bash nexum-phase7-part4-ratelimit.sh --revert
# ============================================================================
set -euo pipefail

API="nexum-api"
RL="$API/src/middleware/rateLimit.ts"
RL_TEST="$API/tests/ratelimit.test.ts"
AUTH="$API/src/routes/auth.ts"
ADMIN="$API/src/routes/adminAuth.ts"
FAC_MARKER="__NEXUM_RATELIMIT_STRICT__"
WIRE_MARKER="__NEXUM_RATELIMIT_WIRED__"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR=".nexum-phase7p4-backup/${STAMP}"
FAC_SHA="db1643f0870df76e4bc0874dc855b3266623a469cc7788c0f4695ee4ea6b69ae"; TEST_SHA="41e40e45da667b2f8708e09b004684e33db8d6046a0302cc1edfbb4503c1f4ba"; PATCH_SHA="6c8d16ddc2fc8bfb262e4580ecc67eab1ce3c3822701bf854303f22a26de05e9"
COMMIT_MSG="feat(api): tight rate limits on auth (brute-force) + txn (spam) endpoints (Phase 7.4)"

FLAG="${1:-}"
log(){ printf '  %s\n' "$*"; }
die(){ printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[ -d "$API" ] || die "Cannot find $API . Run from the repo root."

if [ "$FLAG" = "--revert" ]; then
  LATEST=""
  for d in $(ls -1dt .nexum-phase7p4-backup/*/ 2>/dev/null); do
    if [ -f "${d}rateLimit.ts" ] || [ -f "${d}auth.ts" ] || [ -f "${d}adminAuth.ts" ]; then LATEST="$d"; break; fi
  done
  if [ -n "$LATEST" ]; then
    [ -f "${LATEST}rateLimit.ts" ] && cp "${LATEST}rateLimit.ts" "$RL"    && log "Restored $RL"
    [ -f "${LATEST}auth.ts" ]      && cp "${LATEST}auth.ts"      "$AUTH"  && log "Restored $AUTH"
    [ -f "${LATEST}adminAuth.ts" ] && cp "${LATEST}adminAuth.ts" "$ADMIN" && log "Restored $ADMIN"
  else
    log "No backup found; leaving patched files as-is."
  fi
  rm -f "$RL_TEST" && log "Removed $RL_TEST"
  log "Reverted Phase 7 Part 4."
  exit 0
fi

TFAC="$(mktemp)"; TTEST="$(mktemp)"; TPATCH="$(mktemp /tmp/p7p4.XXXXXX.py)"
trap 'rm -f "$TFAC" "$TTEST" "$TPATCH"' EXIT

base64 -d > "$TFAC" <<'B64FAC'
Ly8gX19ORVhVTV9SQVRFTElNSVRfU1RSSUNUX18gKHBoYXNlNykgdGFyZ2V0ZWQgbGltaXRlcnMg
Zm9yIGF1dGggKyB0eG4KLy8KLy8gVGhlIGFwcC13aWRlIHJhdGVMaW1pdE1pZGRsZXdhcmUgYWJv
dmUgaXMgYSBibHVudCAxMDAvbWluL0lQIGd1YXJkIC0gZmluZSBhcwovLyBhIGZsb29yLCB0b28g
bG9vc2UgZm9yIHRoZSBlbmRwb2ludHMgdGhhdCBhY3R1YWxseSBtYXR0ZXIuIFRoZXNlIGZhY3Rv
cmllcyBhZGQKLy8gVElHSFQsIHB1cnBvc2UtYnVpbHQgbGltaXRzOgovLwovLyAgICogYXV0aCBl
bmRwb2ludHMgKGxvZ2luLCBPVFAsIHNlc3Npb24sIHBhc3N3b3JkIHJlc2V0KTogbG93IHBlci1J
UCBsaW1pdHMgdG8KLy8gICAgIGJsdW50IGJydXRlLWZvcmNlIGFuZCBjcmVkZW50aWFsLXN0dWZm
aW5nLgovLyAgICogdHhuIGVuZHBvaW50cyAod2FsbGV0IHRyYW5zZmVycy9jb250cmFjdCBjYWxs
cyk6IHBlci1BQ0NPVU5UIGxpbWl0cyBzbyBhCi8vICAgICBydW5hd2F5IG9yIG1hbGljaW91cyBj
bGllbnQgY2FuJ3Qgc3BhbSBtb25leS1tb3ZpbmcgY2FsbHMgLSBhbmQgb25lCi8vICAgICBhY2Nv
dW50J3MgYWJ1c2UgbmV2ZXIgcmF0ZS1saW1pdHMgZXZlcnlvbmUgc2hhcmluZyBhbiBJUCAoTkFU
L21vYmlsZSkuCi8vCi8vIFNhbWUgaW4tbWVtb3J5IHN0b3JlIGFwcHJvYWNoIGFzIHRoZSBleGlz
dGluZyBsaW1pdGVyIChzaW5nbGUtaW5zdGFuY2U7IGlmIHRoZQovLyBBUEkgaXMgZXZlciBob3Jp
em9udGFsbHkgc2NhbGVkLCBtb3ZlIHRoaXMgdG8gYSBzaGFyZWQgc3RvcmUgbGlrZSBSZWRpcyAt
IHNlZQovLyBub3RlIGJlbG93KS4gTGltaXRzIGFyZSBlbnYtdHVuYWJsZSBzbyB0aGV5IGNhbiBi
ZSB0aWdodGVuZWQgd2l0aG91dCBhIGRlcGxveS4KCgp0eXBlIEtleUJ5ID0gJ2lwJyB8ICdhY2Nv
dW50JwoKaW50ZXJmYWNlIExpbWl0ZXJPcHRzIHsKICB3aW5kb3dNczogbnVtYmVyCiAgbWF4OiAg
ICAgIG51bWJlcgogIGtleUJ5OiAgICBLZXlCeQogIG5hbWU6ICAgICBzdHJpbmcgICAvLyBmb3Ig
dGhlIDQyOSBib2R5ICsgbG9nZ2luZywgZS5nLiAnYXV0aCcgfCAndHhuJwp9CgovKgogIEJ1aWxk
IGEgbGltaXRlciBtaWRkbGV3YXJlLiBFYWNoIGxpbWl0ZXIga2VlcHMgaXRzIE9XTiBidWNrZXQg
bWFwLCBzbyBsaW1pdHMKICBkb24ndCBibGVlZCBhY3Jvc3MgZW5kcG9pbnRzICh0aGUgbG9naW4g
YnVja2V0IGlzIHNlcGFyYXRlIGZyb20gdGhlIHR4biBvbmUpLgoqLwpleHBvcnQgZnVuY3Rpb24g
Y3JlYXRlUmF0ZUxpbWl0ZXIob3B0czogTGltaXRlck9wdHMpIHsKICBjb25zdCBidWNrZXRzID0g
bmV3IE1hcDxzdHJpbmcsIHsgY291bnQ6IG51bWJlcjsgcmVzZXRBdDogbnVtYmVyIH0+KCkKCiAg
Ly8gT3Bwb3J0dW5pc3RpYyBjbGVhbnVwIHNvIHRoZSBtYXAgY2FuJ3QgZ3JvdyB1bmJvdW5kZWQg
ZnJvbSBvbmUtb2ZmIElQcy4KICBsZXQgbGFzdFN3ZWVwID0gRGF0ZS5ub3coKQogIGZ1bmN0aW9u
IHN3ZWVwKG5vdzogbnVtYmVyKSB7CiAgICBpZiAobm93IC0gbGFzdFN3ZWVwIDwgb3B0cy53aW5k
b3dNcykgcmV0dXJuCiAgICBsYXN0U3dlZXAgPSBub3cKICAgIGZvciAoY29uc3QgW2ssIHZdIG9m
IGJ1Y2tldHMpIGlmIChub3cgPiB2LnJlc2V0QXQpIGJ1Y2tldHMuZGVsZXRlKGspCiAgfQoKICBy
ZXR1cm4gZnVuY3Rpb24gKHJlcTogUmVxdWVzdCwgcmVzOiBSZXNwb25zZSwgbmV4dDogTmV4dEZ1
bmN0aW9uKSB7CiAgICBjb25zdCBub3cgPSBEYXRlLm5vdygpCiAgICBzd2VlcChub3cpCgogICAg
bGV0IGlkOiBzdHJpbmcKICAgIGlmIChvcHRzLmtleUJ5ID09PSAnYWNjb3VudCcpIHsKICAgICAg
Y29uc3QgYWNjdCA9IChyZXEgYXMgYW55KS5hY2NvdW50CiAgICAgIC8vIElmIHNvbWVob3cgdW5h
dXRoZW50aWNhdGVkIChzaG91bGRuJ3QgaGFwcGVuIGJlaGluZCByZXF1aXJlQWNjb3VudCksCiAg
ICAgIC8vIGZhbGwgYmFjayB0byBJUCBzbyB3ZSBzdGlsbCBsaW1pdCByYXRoZXIgdGhhbiBmYWls
IG9wZW4uCiAgICAgIGlkID0gYWNjdD8uaWQgPyBgYWNjdDoke2FjY3QuaWR9YCA6IGBpcDoke3Jl
cS5pcCA/PyAndW5rbm93bid9YAogICAgfSBlbHNlIHsKICAgICAgaWQgPSBgaXA6JHtyZXEuaXAg
Pz8gJ3Vua25vd24nfWAKICAgIH0KICAgIGNvbnN0IGtleSA9IGAke29wdHMubmFtZX06JHtpZH1g
CgogICAgY29uc3QgZW50cnkgPSBidWNrZXRzLmdldChrZXkpCiAgICBpZiAoIWVudHJ5IHx8IG5v
dyA+IGVudHJ5LnJlc2V0QXQpIHsKICAgICAgYnVja2V0cy5zZXQoa2V5LCB7IGNvdW50OiAxLCBy
ZXNldEF0OiBub3cgKyBvcHRzLndpbmRvd01zIH0pCiAgICAgIHJldHVybiBuZXh0KCkKICAgIH0K
ICAgIGVudHJ5LmNvdW50KysKICAgIGlmIChlbnRyeS5jb3VudCA+IG9wdHMubWF4KSB7CiAgICAg
IGNvbnN0IHJldHJ5QWZ0ZXIgPSBNYXRoLmNlaWwoKGVudHJ5LnJlc2V0QXQgLSBub3cpIC8gMTAw
MCkKICAgICAgcmVzLnNldEhlYWRlcignUmV0cnktQWZ0ZXInLCBTdHJpbmcocmV0cnlBZnRlcikp
CiAgICAgIHJldHVybiByZXMuc3RhdHVzKDQyOSkuanNvbih7CiAgICAgICAgZXJyb3I6ICdUb28g
bWFueSByZXF1ZXN0cy4gUGxlYXNlIHNsb3cgZG93biBhbmQgdHJ5IGFnYWluIHNob3J0bHkuJywK
ICAgICAgICBjb2RlOiAgYHJhdGVfbGltaXRlZF8ke29wdHMubmFtZX1gLAogICAgICAgIHJldHJ5
QWZ0ZXJTZWNvbmRzOiByZXRyeUFmdGVyLAogICAgICB9KQogICAgfQogICAgbmV4dCgpCiAgfQp9
Cgpjb25zdCBpbnQgPSAodjogc3RyaW5nIHwgdW5kZWZpbmVkLCBkOiBudW1iZXIpID0+IHsKICBj
b25zdCBuID0gTnVtYmVyKHYpOyByZXR1cm4gTnVtYmVyLmlzRmluaXRlKG4pICYmIG4gPiAwID8g
biA6IGQKfQoKLyoKICBBVVRIIGxpbWl0ZXI6IHN0cmljdCwgcGVyIElQLiBEZWZhdWx0cyB0byAx
MCBhdHRlbXB0cy9taW51dGUgLSBlbm91Z2ggZm9yIGEKICBmdW1ibGluZyBodW1hbiwgZmFyIGJl
bG93IHdoYXQgYSBicnV0ZS1mb3JjZSBzY3JpcHQgbmVlZHMuIFR1bmUgd2l0aAogIFJBVEVfTElN
SVRfQVVUSF9NQVggLyBSQVRFX0xJTUlUX0FVVEhfV0lORE9XX01TLgoqLwpleHBvcnQgY29uc3Qg
YXV0aFJhdGVMaW1pdGVyID0gY3JlYXRlUmF0ZUxpbWl0ZXIoewogIG5hbWU6ICAgICAnYXV0aCcs
CiAga2V5Qnk6ICAgICdpcCcsCiAgd2luZG93TXM6IGludChwcm9jZXNzLmVudi5SQVRFX0xJTUlU
X0FVVEhfV0lORE9XX01TLCA2MF8wMDApLAogIG1heDogICAgICBpbnQocHJvY2Vzcy5lbnYuUkFU
RV9MSU1JVF9BVVRIX01BWCwgMTApLAp9KQoKLyoKICBUWE4gbGltaXRlcjogcGVyIGFjY291bnQu
IERlZmF1bHRzIHRvIDIwIG1vbmV5LW1vdmluZyBjYWxscy9taW51dGUgcGVyIHVzZXIgLQogIGdl
bmVyb3VzIGZvciByZWFsIHVzZSwgdGlnaHQgZW5vdWdoIHRvIHN0b3AgYSBzcGFtIGxvb3AuIFR1
bmUgd2l0aAogIFJBVEVfTElNSVRfVFhOX01BWCAvIFJBVEVfTElNSVRfVFhOX1dJTkRPV19NUy4K
Ki8KZXhwb3J0IGNvbnN0IHR4blJhdGVMaW1pdGVyID0gY3JlYXRlUmF0ZUxpbWl0ZXIoewogIG5h
bWU6ICAgICAndHhuJywKICBrZXlCeTogICAgJ2FjY291bnQnLAogIHdpbmRvd01zOiBpbnQocHJv
Y2Vzcy5lbnYuUkFURV9MSU1JVF9UWE5fV0lORE9XX01TLCA2MF8wMDApLAogIG1heDogICAgICBp
bnQocHJvY2Vzcy5lbnYuUkFURV9MSU1JVF9UWE5fTUFYLCAyMCksCn0pCg==
B64FAC
base64 -d > "$TTEST" <<'B64TEST'
aW1wb3J0IHsgZGVzY3JpYmUsIGl0LCBleHBlY3QsIHZpIH0gZnJvbSAndml0ZXN0JwppbXBvcnQg
eyBjcmVhdGVSYXRlTGltaXRlciB9IGZyb20gJy4uL3NyYy9taWRkbGV3YXJlL3JhdGVMaW1pdCcK
Ci8vID09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
PT09PT09PT09PT09PT09PT09PT09PT0KLy8gU3RyaWN0IHJhdGUgbGltaXRlciAoUGhhc2UgNyBI
YXJkZW5pbmcpLgovLwovLyBUaGVzZSBndWFyZCBhdXRoIChicnV0ZS1mb3JjZSkgYW5kIHR4biAo
bW9uZXktbW92aW5nIHNwYW0pLCBzbyB0aGUgdGVzdHMgcGluCi8vIHRoZSBiZWhhdmlvdXJzIHRo
YXQgbWF0dGVyOiBhbGxvd3MgdXAgdG8gdGhlIGxpbWl0LCBibG9ja3MgcGFzdCBpdCB3aXRoIDQy
OSArCi8vIFJldHJ5LUFmdGVyLCBrZXlzIGFyZSBpc29sYXRlZCAob25lIElQL2FjY291bnQgY2Fu
J3QgZXhoYXVzdCBhbm90aGVyJ3MKLy8gYnVkZ2V0KSwgdGhlIHdpbmRvdyByZXNldHMsIGFuZCBh
Y2NvdW50LWtleWluZyBmYWxscyBiYWNrIHRvIElQIHdoZW4gdGhlcmUgaXMKLy8gbm8gYXV0aGVu
dGljYXRlZCBhY2NvdW50IHJhdGhlciB0aGFuIGZhaWxpbmcgb3Blbi4KLy8gPT09PT09PT09PT09
PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
PT09PT09PQoKZnVuY3Rpb24gbW9ja1JlcVJlcyhvdmVyOiBQYXJ0aWFsPGFueT4gPSB7fSkgewog
IGNvbnN0IHJlcTogYW55ID0geyBpcDogJzEuMi4zLjQnLCAuLi5vdmVyIH0KICBjb25zdCByZXM6
IGFueSA9IHsKICAgIHN0YXR1c0NvZGU6IDIwMCwKICAgIGhlYWRlcnM6IHt9IGFzIFJlY29yZDxz
dHJpbmcsIHN0cmluZz4sCiAgICBzZXRIZWFkZXIoazogc3RyaW5nLCB2OiBzdHJpbmcpIHsgdGhp
cy5oZWFkZXJzW2tdID0gdiB9LAogICAgc3RhdHVzKGM6IG51bWJlcikgeyB0aGlzLnN0YXR1c0Nv
ZGUgPSBjOyByZXR1cm4gdGhpcyB9LAogICAganNvbihiOiBhbnkpIHsgdGhpcy5ib2R5ID0gYjsg
cmV0dXJuIHRoaXMgfSwKICB9CiAgcmV0dXJuIHsgcmVxLCByZXMgfQp9CgpkZXNjcmliZSgnY3Jl
YXRlUmF0ZUxpbWl0ZXInLCAoKSA9PiB7CiAgaXQoJ2FsbG93cyByZXF1ZXN0cyB1cCB0byB0aGUg
bWF4LCB0aGVuIGJsb2NrcyB3aXRoIDQyOSArIFJldHJ5LUFmdGVyJywgKCkgPT4gewogICAgY29u
c3QgbGltaXRlciA9IGNyZWF0ZVJhdGVMaW1pdGVyKHsgbmFtZTogJ3Rlc3QnLCBrZXlCeTogJ2lw
Jywgd2luZG93TXM6IDYwXzAwMCwgbWF4OiAzIH0pCiAgICBsZXQgcGFzc2VkID0gMAogICAgZm9y
IChsZXQgaSA9IDA7IGkgPCAzOyBpKyspIHsKICAgICAgY29uc3QgeyByZXEsIHJlcyB9ID0gbW9j
a1JlcVJlcygpCiAgICAgIGxpbWl0ZXIocmVxLCByZXMsICgpID0+IHsgcGFzc2VkKysgfSkKICAg
IH0KICAgIGV4cGVjdChwYXNzZWQpLnRvQmUoMykKCiAgICBjb25zdCB7IHJlcSwgcmVzIH0gPSBt
b2NrUmVxUmVzKCkKICAgIGxldCBibG9ja2VkTmV4dCA9IGZhbHNlCiAgICBsaW1pdGVyKHJlcSwg
cmVzLCAoKSA9PiB7IGJsb2NrZWROZXh0ID0gdHJ1ZSB9KQogICAgZXhwZWN0KGJsb2NrZWROZXh0
KS50b0JlKGZhbHNlKQogICAgZXhwZWN0KHJlcy5zdGF0dXNDb2RlKS50b0JlKDQyOSkKICAgIGV4
cGVjdChyZXMuYm9keS5jb2RlKS50b0JlKCdyYXRlX2xpbWl0ZWRfdGVzdCcpCiAgICBleHBlY3Qo
cmVzLmhlYWRlcnNbJ1JldHJ5LUFmdGVyJ10pLnRvQmVUcnV0aHkoKQogIH0pCgogIGl0KCdpc29s
YXRlcyBidWNrZXRzIGFjcm9zcyBkaWZmZXJlbnQgSVBzJywgKCkgPT4gewogICAgY29uc3QgbGlt
aXRlciA9IGNyZWF0ZVJhdGVMaW1pdGVyKHsgbmFtZTogJ2lzbycsIGtleUJ5OiAnaXAnLCB3aW5k
b3dNczogNjBfMDAwLCBtYXg6IDEgfSkKICAgIGNvbnN0IGEgPSBtb2NrUmVxUmVzKHsgaXA6ICcx
MC4wLjAuMScgfSkKICAgIGNvbnN0IGIgPSBtb2NrUmVxUmVzKHsgaXA6ICcxMC4wLjAuMicgfSkK
ICAgIGxldCBhUGFzcyA9IGZhbHNlLCBiUGFzcyA9IGZhbHNlCiAgICBsaW1pdGVyKGEucmVxLCBh
LnJlcywgKCkgPT4geyBhUGFzcyA9IHRydWUgfSkKICAgIGxpbWl0ZXIoYi5yZXEsIGIucmVzLCAo
KSA9PiB7IGJQYXNzID0gdHJ1ZSB9KQogICAgLy8gRWFjaCBJUCBnZXRzIGl0cyBvd24gYnVkZ2V0
IG9mIDEuCiAgICBleHBlY3QoYVBhc3MpLnRvQmUodHJ1ZSkKICAgIGV4cGVjdChiUGFzcykudG9C
ZSh0cnVlKQogICAgLy8gQSdzIHNlY29uZCByZXF1ZXN0IGlzIGJsb2NrZWQsIEIgaXMgdW5hZmZl
Y3RlZC4KICAgIGNvbnN0IGEyID0gbW9ja1JlcVJlcyh7IGlwOiAnMTAuMC4wLjEnIH0pCiAgICBs
ZXQgYTJQYXNzID0gZmFsc2UKICAgIGxpbWl0ZXIoYTIucmVxLCBhMi5yZXMsICgpID0+IHsgYTJQ
YXNzID0gdHJ1ZSB9KQogICAgZXhwZWN0KGEyUGFzcykudG9CZShmYWxzZSkKICAgIGV4cGVjdChh
Mi5yZXMuc3RhdHVzQ29kZSkudG9CZSg0MjkpCiAgfSkKCiAgaXQoJ2tleXMgYnkgYWNjb3VudCB3
aGVuIGtleUJ5PWFjY291bnQsIHNvIG9uZSB1c2VyIGNhbm5vdCBsaW1pdCBhbm90aGVyJywgKCkg
PT4gewogICAgY29uc3QgbGltaXRlciA9IGNyZWF0ZVJhdGVMaW1pdGVyKHsgbmFtZTogJ2FjY3Qn
LCBrZXlCeTogJ2FjY291bnQnLCB3aW5kb3dNczogNjBfMDAwLCBtYXg6IDEgfSkKICAgIGNvbnN0
IHUxID0gbW9ja1JlcVJlcyh7IGFjY291bnQ6IHsgaWQ6ICd1c2VyLTEnIH0sIGlwOiAnc2hhcmVk
LWlwJyB9KQogICAgY29uc3QgdTIgPSBtb2NrUmVxUmVzKHsgYWNjb3VudDogeyBpZDogJ3VzZXIt
MicgfSwgaXA6ICdzaGFyZWQtaXAnIH0pCiAgICBsZXQgcDEgPSBmYWxzZSwgcDIgPSBmYWxzZQog
ICAgbGltaXRlcih1MS5yZXEsIHUxLnJlcywgKCkgPT4geyBwMSA9IHRydWUgfSkKICAgIGxpbWl0
ZXIodTIucmVxLCB1Mi5yZXMsICgpID0+IHsgcDIgPSB0cnVlIH0pCiAgICAvLyBTYW1lIElQLCBk
aWZmZXJlbnQgYWNjb3VudHMgLT4gYm90aCBhbGxvd2VkIChOQVQvbW9iaWxlIHNhZmV0eSkuCiAg
ICBleHBlY3QocDEpLnRvQmUodHJ1ZSkKICAgIGV4cGVjdChwMikudG9CZSh0cnVlKQogICAgLy8g
dXNlci0xJ3Mgc2Vjb25kIGNhbGwgaXMgYmxvY2tlZCwgdXNlci0yIHN0aWxsIGZpbmUuCiAgICBj
b25zdCB1MWIgPSBtb2NrUmVxUmVzKHsgYWNjb3VudDogeyBpZDogJ3VzZXItMScgfSwgaXA6ICdz
aGFyZWQtaXAnIH0pCiAgICBsZXQgcDFiID0gZmFsc2UKICAgIGxpbWl0ZXIodTFiLnJlcSwgdTFi
LnJlcywgKCkgPT4geyBwMWIgPSB0cnVlIH0pCiAgICBleHBlY3QocDFiKS50b0JlKGZhbHNlKQog
IH0pCgogIGl0KCdmYWxscyBiYWNrIHRvIElQIHdoZW4gYWNjb3VudC1rZXllZCBidXQgdW5hdXRo
ZW50aWNhdGVkIChkb2VzIG5vdCBmYWlsIG9wZW4pJywgKCkgPT4gewogICAgY29uc3QgbGltaXRl
ciA9IGNyZWF0ZVJhdGVMaW1pdGVyKHsgbmFtZTogJ2ZiJywga2V5Qnk6ICdhY2NvdW50Jywgd2lu
ZG93TXM6IDYwXzAwMCwgbWF4OiAxIH0pCiAgICBjb25zdCBhID0gbW9ja1JlcVJlcyh7IGlwOiAn
OS45LjkuOScgfSkgICAgICAgLy8gbm8gYWNjb3VudAogICAgY29uc3QgYiA9IG1vY2tSZXFSZXMo
eyBpcDogJzkuOS45LjknIH0pICAgICAgIC8vIHNhbWUgSVAsIG5vIGFjY291bnQKICAgIGxldCBh
UGFzcyA9IGZhbHNlLCBiQmxvY2tlZCA9IGZhbHNlCiAgICBsaW1pdGVyKGEucmVxLCBhLnJlcywg
KCkgPT4geyBhUGFzcyA9IHRydWUgfSkKICAgIGxpbWl0ZXIoYi5yZXEsIGIucmVzLCAoKSA9PiB7
IGJCbG9ja2VkID0gZmFsc2UgfSkKICAgIGV4cGVjdChhUGFzcykudG9CZSh0cnVlKQogICAgZXhw
ZWN0KGIucmVzLnN0YXR1c0NvZGUpLnRvQmUoNDI5KSAvLyBsaW1pdGVkIGJ5IHNoYXJlZCBJUCwg
bm90IGZhaWwtb3BlbgogIH0pCgogIGl0KCdyZXNldHMgYWZ0ZXIgdGhlIHdpbmRvdyBlbGFwc2Vz
JywgKCkgPT4gewogICAgdmkudXNlRmFrZVRpbWVycygpCiAgICBjb25zdCBsaW1pdGVyID0gY3Jl
YXRlUmF0ZUxpbWl0ZXIoeyBuYW1lOiAnd2luJywga2V5Qnk6ICdpcCcsIHdpbmRvd01zOiAxXzAw
MCwgbWF4OiAxIH0pCiAgICBjb25zdCBhID0gbW9ja1JlcVJlcyh7IGlwOiAnNS41LjUuNScgfSkK
ICAgIGxldCBwYXNzMSA9IGZhbHNlCiAgICBsaW1pdGVyKGEucmVxLCBhLnJlcywgKCkgPT4geyBw
YXNzMSA9IHRydWUgfSkKICAgIGV4cGVjdChwYXNzMSkudG9CZSh0cnVlKQoKICAgIGNvbnN0IGIg
PSBtb2NrUmVxUmVzKHsgaXA6ICc1LjUuNS41JyB9KQogICAgbGV0IHBhc3MyID0gZmFsc2UKICAg
IGxpbWl0ZXIoYi5yZXEsIGIucmVzLCAoKSA9PiB7IHBhc3MyID0gdHJ1ZSB9KQogICAgZXhwZWN0
KHBhc3MyKS50b0JlKGZhbHNlKSAvLyBibG9ja2VkIHdpdGhpbiB3aW5kb3cKCiAgICB2aS5hZHZh
bmNlVGltZXJzQnlUaW1lKDFfMTAwKQogICAgY29uc3QgYyA9IG1vY2tSZXFSZXMoeyBpcDogJzUu
NS41LjUnIH0pCiAgICBsZXQgcGFzczMgPSBmYWxzZQogICAgbGltaXRlcihjLnJlcSwgYy5yZXMs
ICgpID0+IHsgcGFzczMgPSB0cnVlIH0pCiAgICBleHBlY3QocGFzczMpLnRvQmUodHJ1ZSkgLy8g
YWxsb3dlZCBhZ2FpbiBhZnRlciByZXNldAogICAgdmkudXNlUmVhbFRpbWVycygpCiAgfSkKfSkK
B64TEST
base64 -d > "$TPATCH" <<'B64PATCH'
IyEvdXNyL2Jpbi9lbnYgcHl0aG9uMwoiIiIKUGhhc2UgNyBQYXJ0IDQgKHJhdGUgbGltaXRpbmcp
IC0gd2lyZSB0aWdodCBhdXRoICsgdHhuIGxpbWl0ZXJzLgoKRWRpdHM6CiAgc3JjL21pZGRsZXdh
cmUvcmF0ZUxpbWl0LnRzICAtIGFwcGVuZCB0aGUgc3RyaWN0IGxpbWl0ZXIgZmFjdG9yeSArIGlu
c3RhbmNlcwogIHNyYy9yb3V0ZXMvYXV0aC50cwogICAgKiBpbXBvcnQgYXV0aFJhdGVMaW1pdGVy
LCB0eG5SYXRlTGltaXRlcgogICAgKiBhdXRoUmF0ZUxpbWl0ZXIgb246IC9jaXJjbGUvZW1haWwt
b3RwLCAvc2Vzc2lvbgogICAgKiB0eG5SYXRlTGltaXRlciAoYWZ0ZXIgcmVxdWlyZUFjY291bnQp
IG9uOiAvd2FsbGV0L3R4L3RyYW5zZmVyLCAvd2FsbGV0L3R4L2NvbnRyYWN0CiAgc3JjL3JvdXRl
cy9hZG1pbkF1dGgudHMKICAgICogaW1wb3J0IGF1dGhSYXRlTGltaXRlcgogICAgKiBhdXRoUmF0
ZUxpbWl0ZXIgb246IC9sb2dpbiwgL2ZvcmdvdC1wYXNzd29yZCwgL3Jlc2V0LXBhc3N3b3JkCgpJ
ZGVtcG90ZW50IHZpYSBfX05FWFVNX1JBVEVMSU1JVF9TVFJJQ1RfXyAoZmFjdG9yeSkgYW5kIF9f
TkVYVU1fUkFURUxJTUlUX1dJUkVEX18KKHJvdXRlcykuIEV4YWN0LWFuY2hvcjsgYWJvcnRzIGNs
ZWFuIG9uIGRyaWZ0LgoiIiIKaW1wb3J0IHN5cywgaW8KCmRlZiBoYXMocGF0aCwgbWFya2VyKToK
ICAgIHJldHVybiBtYXJrZXIgaW4gaW8ub3BlbihwYXRoLCBlbmNvZGluZz0idXRmLTgiKS5yZWFk
KCkKCmRlZiBwYXRjaChwYXRoLCBlZGl0cywgbWFya2VyKToKICAgIHNyYyA9IGlvLm9wZW4ocGF0
aCwgZW5jb2Rpbmc9InV0Zi04IikucmVhZCgpCiAgICBpZiBtYXJrZXIgaW4gc3JjOgogICAgICAg
IHByaW50KGYiICB7cGF0aH06IGFscmVhZHkgd2lyZWQgLSBza2lwcGluZy4iKQogICAgICAgIHJl
dHVybgogICAgZm9yIGRlc2MsIG9sZCwgbmV3IGluIGVkaXRzOgogICAgICAgIG4gPSBzcmMuY291
bnQob2xkKQogICAgICAgIGlmIG4gIT0gMToKICAgICAgICAgICAgcHJpbnQoZiJFUlJPUiBbe3Bh
dGh9XTogYW5jaG9yICd7ZGVzY30nIG1hdGNoZWQge259IHRpbWVzIChleHBlY3RlZCAxKS4gQWJv
cnRpbmcuIikKICAgICAgICAgICAgc3lzLmV4aXQoMikKICAgICAgICBzcmMgPSBzcmMucmVwbGFj
ZShvbGQsIG5ldykKICAgIGlvLm9wZW4ocGF0aCwgInciLCBlbmNvZGluZz0idXRmLTgiKS53cml0
ZShzcmMpCiAgICBwcmludChmIiAge3BhdGh9OiB3aXJlZC4iKQoKIyAtLS0tIDEuIGFwcGVuZCBm
YWN0b3J5IHRvIHJhdGVMaW1pdC50cyAob25seSB0aGUgYXBwZW5kOyB0aGUgZmlsZSBhbHJlYWR5
CiMgICAgICAgICBleGlzdHMgd2l0aCB0aGUgZ2xvYmFsIGxpbWl0ZXIpLiBXZSByZWFkIHRoZSBw
YXlsb2FkIGZyb20gYSBzaWJsaW5nCiMgICAgICAgICBmaWxlIHRoZSBzaGVsbCBzY3JpcHQgZHJv
cHMgbmV4dCB0byB1cy4gLS0tLQpSTCA9ICJuZXh1bS1hcGkvc3JjL21pZGRsZXdhcmUvcmF0ZUxp
bWl0LnRzIgpGQUNUT1JZX01BUktFUiA9ICJfX05FWFVNX1JBVEVMSU1JVF9TVFJJQ1RfXyIKaWYg
bm90IGhhcyhSTCwgRkFDVE9SWV9NQVJLRVIpOgogICAgZmFjdG9yeSA9IGlvLm9wZW4oc3lzLmFy
Z3ZbMV0sIGVuY29kaW5nPSJ1dGYtOCIpLnJlYWQoKSBpZiBsZW4oc3lzLmFyZ3YpID4gMSBlbHNl
ICIiCiAgICBpZiBub3QgZmFjdG9yeToKICAgICAgICBwcmludCgiRVJST1I6IGZhY3RvcnkgcGF5
bG9hZCBwYXRoIG5vdCBwcm92aWRlZCBhcyBhcmd2WzFdLiBBYm9ydGluZy4iKQogICAgICAgIHN5
cy5leGl0KDIpCiAgICB3aXRoIGlvLm9wZW4oUkwsICJhIiwgZW5jb2Rpbmc9InV0Zi04IikgYXMg
ZjoKICAgICAgICBmLndyaXRlKCJcbiIgKyBmYWN0b3J5KQogICAgcHJpbnQoZiIgIHtSTH06IGZh
Y3RvcnkgYXBwZW5kZWQuIikKZWxzZToKICAgIHByaW50KGYiICB7Ukx9OiBmYWN0b3J5IGFscmVh
ZHkgcHJlc2VudCAtIHNraXBwaW5nLiIpCgojIC0tLS0gMi4gYXV0aC50cyAtLS0tCnBhdGNoKCJu
ZXh1bS1hcGkvc3JjL3JvdXRlcy9hdXRoLnRzIiwgWwogICAgKCJpbXBvcnQiLAogICAgICJ9IGZy
b20gJy4uL2xpYi9hY2NvdW50QXV0aCciLAogICAgICJ9IGZyb20gJy4uL2xpYi9hY2NvdW50QXV0
aCdcbiIKICAgICAiLy8gX19ORVhVTV9SQVRFTElNSVRfV0lSRURfXyAocGhhc2U3KSB0aWdodCBh
dXRoICsgdHhuIGxpbWl0c1xuIgogICAgICJpbXBvcnQgeyBhdXRoUmF0ZUxpbWl0ZXIsIHR4blJh
dGVMaW1pdGVyIH0gZnJvbSAnLi4vbWlkZGxld2FyZS9yYXRlTGltaXQnIiksCiAgICAoImVtYWls
LW90cCIsCiAgICAgInJvdXRlci5wb3N0KCcvY2lyY2xlL2VtYWlsLW90cCcsIGFzeW5jIChyZXEs
IHJlcykgPT4geyIsCiAgICAgInJvdXRlci5wb3N0KCcvY2lyY2xlL2VtYWlsLW90cCcsIGF1dGhS
YXRlTGltaXRlciwgYXN5bmMgKHJlcSwgcmVzKSA9PiB7IiksCiAgICAoInNlc3Npb24iLAogICAg
ICJyb3V0ZXIucG9zdCgnL3Nlc3Npb24nLCBhc3luYyAocmVxLCByZXMpID0+IHsiLAogICAgICJy
b3V0ZXIucG9zdCgnL3Nlc3Npb24nLCBhdXRoUmF0ZUxpbWl0ZXIsIGFzeW5jIChyZXEsIHJlcykg
PT4geyIpLAogICAgKCJ0eCB0cmFuc2ZlciIsCiAgICAgInJvdXRlci5wb3N0KCcvd2FsbGV0L3R4
L3RyYW5zZmVyJywgcmVxdWlyZUFjY291bnQsIGFzeW5jIChyZXEsIHJlcykgPT4geyIsCiAgICAg
InJvdXRlci5wb3N0KCcvd2FsbGV0L3R4L3RyYW5zZmVyJywgcmVxdWlyZUFjY291bnQsIHR4blJh
dGVMaW1pdGVyLCBhc3luYyAocmVxLCByZXMpID0+IHsiKSwKICAgICgidHggY29udHJhY3QiLAog
ICAgICJyb3V0ZXIucG9zdCgnL3dhbGxldC90eC9jb250cmFjdCcsIHJlcXVpcmVBY2NvdW50LCBh
c3luYyAocmVxLCByZXMpID0+IHsiLAogICAgICJyb3V0ZXIucG9zdCgnL3dhbGxldC90eC9jb250
cmFjdCcsIHJlcXVpcmVBY2NvdW50LCB0eG5SYXRlTGltaXRlciwgYXN5bmMgKHJlcSwgcmVzKSA9
PiB7IiksCl0sICJfX05FWFVNX1JBVEVMSU1JVF9XSVJFRF9fIikKCiMgLS0tLSAzLiBhZG1pbkF1
dGgudHMgLS0tLQpwYXRjaCgibmV4dW0tYXBpL3NyYy9yb3V0ZXMvYWRtaW5BdXRoLnRzIiwgWwog
ICAgKCJpbXBvcnQiLAogICAgICJpbXBvcnQgUVJDb2RlIGZyb20gJ3FyY29kZSciLAogICAgICJp
bXBvcnQgUVJDb2RlIGZyb20gJ3FyY29kZSdcbiIKICAgICAiLy8gX19ORVhVTV9SQVRFTElNSVRf
V0lSRURfXyAocGhhc2U3KSBicnV0ZS1mb3JjZSBwcm90ZWN0aW9uIG9uIGFkbWluIGF1dGhcbiIK
ICAgICAiaW1wb3J0IHsgYXV0aFJhdGVMaW1pdGVyIH0gZnJvbSAnLi4vbWlkZGxld2FyZS9yYXRl
TGltaXQnIiksCiAgICAoImxvZ2luIiwKICAgICAicm91dGVyLnBvc3QoJy9sb2dpbicsIGFzeW5j
IChyZXEsIHJlcykgPT4geyIsCiAgICAgInJvdXRlci5wb3N0KCcvbG9naW4nLCBhdXRoUmF0ZUxp
bWl0ZXIsIGFzeW5jIChyZXEsIHJlcykgPT4geyIpLAogICAgKCJmb3Jnb3QiLAogICAgICJyb3V0
ZXIucG9zdCgnL2ZvcmdvdC1wYXNzd29yZCcsIGFzeW5jIChyZXEsIHJlcykgPT4geyIsCiAgICAg
InJvdXRlci5wb3N0KCcvZm9yZ290LXBhc3N3b3JkJywgYXV0aFJhdGVMaW1pdGVyLCBhc3luYyAo
cmVxLCByZXMpID0+IHsiKSwKICAgICgicmVzZXQiLAogICAgICJyb3V0ZXIucG9zdCgnL3Jlc2V0
LXBhc3N3b3JkJywgYXN5bmMgKHJlcSwgcmVzKSA9PiB7IiwKICAgICAicm91dGVyLnBvc3QoJy9y
ZXNldC1wYXNzd29yZCcsIGF1dGhSYXRlTGltaXRlciwgYXN5bmMgKHJlcSwgcmVzKSA9PiB7Iiks
Cl0sICJfX05FWFVNX1JBVEVMSU1JVF9XSVJFRF9fIikKCnByaW50KCJSYXRlLWxpbWl0IHdpcmlu
ZyBjb21wbGV0ZS4iKQo=
B64PATCH

verify(){ local got; got="$( (sha256sum "$1" 2>/dev/null || shasum -a 256 "$1") | awk '{print $1}')"; [ "$got" = "$2" ] || die "Checksum mismatch for $1 (got $got). Nothing written."; }
verify "$TFAC" "$FAC_SHA"; verify "$TTEST" "$TEST_SHA"; verify "$TPATCH" "$PATCH_SHA"
log "All payloads verified."

mkdir -p "$BACKUP_DIR"
[ -f "$RL" ]    && ! grep -qF "$FAC_MARKER"  "$RL"    && cp "$RL"    "$BACKUP_DIR/rateLimit.ts"  || true
[ -f "$AUTH" ]  && ! grep -qF "$WIRE_MARKER" "$AUTH"  && cp "$AUTH"  "$BACKUP_DIR/auth.ts"       || true
[ -f "$ADMIN" ] && ! grep -qF "$WIRE_MARKER" "$ADMIN" && cp "$ADMIN" "$BACKUP_DIR/adminAuth.ts"  || true

mkdir -p "$API/tests"
if [ -f "$RL_TEST" ]; then log "test already present - leaving it."; else cp "$TTEST" "$RL_TEST"; log "Added $RL_TEST"; fi

# The patcher appends the factory (reading it from argv[1]) and wires routes.
python3 "$TPATCH" "$TFAC" || {
  [ -f "$BACKUP_DIR/rateLimit.ts" ]  && cp "$BACKUP_DIR/rateLimit.ts"  "$RL"
  [ -f "$BACKUP_DIR/auth.ts" ]       && cp "$BACKUP_DIR/auth.ts"       "$AUTH"
  [ -f "$BACKUP_DIR/adminAuth.ts" ]  && cp "$BACKUP_DIR/adminAuth.ts"  "$ADMIN"
  die "Wiring failed; patched files restored."
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
log "Pushed Phase 7 Part 4. Auth endpoints now brute-force limited; txn endpoints per-account limited."
log "Tune via RATE_LIMIT_AUTH_MAX / RATE_LIMIT_TXN_MAX env vars if needed."
