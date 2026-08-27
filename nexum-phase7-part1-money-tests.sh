#!/usr/bin/env bash
# ============================================================================
# Nexum Phase 7 (Hardening) - Part 1: money-math test suite for the CCTP engine
#
# The roadmap flags "~no test coverage" as a HIGH risk during the rewrite, and
# the fee engine already shipped a bug no test would have caught (BigInt on a
# fractional bps, which killed the quote on every Fast-capable chain). This
# part stands up the web test harness and adds the first suite - 24 tests over
# toUnits/fromUnits, maxFeeFor, fastTransferSupported, etaSeconds,
# fetchFeeTable, getTransferQuote, getBothQuotes - INCLUDING a direct
# regression test for that exact bug.
#
# Matches the API package's existing Vitest setup (same runner, same layout).
# No network, no wallet, no funds: the quote tests stub global fetch.
#
# Adds/does:
#   NEW  nexum-web/vitest.config.ts
#   NEW  nexum-web/tests/cctp-money-math.test.ts
#   package.json: devDep vitest@^2.1.9 + scripts test / test:watch
#   installs deps, then RUNS the suite as part of the gate
#
# Delivery contract (your v2 spec) + full deploy:
#   * both payloads base64 + sha256 verified before writing
#   * idempotent (skips files that already exist with our marker)
#   * timestamped backup of package.json
#   * deploy GATE: install -> npx vitest run -> tsc --noEmit -> build -> push
#     (tests must PASS or nothing is committed)
#   * --revert removes the test files + restores package.json
#   * --no-deploy applies + installs + runs tests, but skips build/commit/push
#
# Run from REPO ROOT (folder containing nexum-web/).
#   bash nexum-phase7-part1-money-tests.sh
#   bash nexum-phase7-part1-money-tests.sh --no-deploy
#   bash nexum-phase7-part1-money-tests.sh --revert
# ============================================================================
set -euo pipefail

WEB="nexum-web"
TEST_DIR="$WEB/tests"
TEST_FILE="$TEST_DIR/cctp-money-math.test.ts"
CFG="$WEB/vitest.config.ts"
PKG="$WEB/package.json"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR=".nexum-phase7p1-backup/${STAMP}"
T_SHA="0c9b2829b5bb5ad98f55bfd8d6d887aac8fbd24831460c5f487782defa5f94d2"; C_SHA="f3fda1e0985a0edd50d5653a1d97bdf7a14ddf68311048b894a764f1575fa4e6"
COMMIT_MSG="test(bridge): money-math unit suite for CCTP fee/quote engine incl. fractional-bps regression (Phase 7.1)"

FLAG="${1:-}"
log(){ printf '  %s\n' "$*"; }
die(){ printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[ -d "$WEB" ] || die "Cannot find $WEB . Run from the repo root."

# ---------------------------------------------------------------- revert ----
if [ "$FLAG" = "--revert" ]; then
  rm -f "$TEST_FILE" && log "Removed $TEST_FILE"
  rmdir "$TEST_DIR" 2>/dev/null || true
  rm -f "$CFG" && log "Removed $CFG"
  # Deterministic: remove exactly the two scripts we added, regardless of any
  # backup state. (A backup taken on a later idempotent run could already
  # contain them, so restoring a backup is not reliable here.)
  ( cd "$WEB" && npm pkg delete scripts.test scripts.test:watch >/dev/null 2>&1 || true )
  log "Removed test scripts from package.json."
  log "Reverted Phase 7 Part 1. (vitest devDep left in place; harmless. Remove with: cd $WEB && npm uninstall -D vitest)"
  exit 0
fi

# --------------------------------------------- decode + verify payloads -----
TMP_T="$(mktemp /tmp/nexum-p7test.XXXXXX.ts)"
TMP_C="$(mktemp /tmp/nexum-p7cfg.XXXXXX.ts)"
trap 'rm -f "$TMP_T" "$TMP_C"' EXIT

base64 -d > "$TMP_T" <<'B64T'
aW1wb3J0IHsgZGVzY3JpYmUsIGl0LCBleHBlY3QsIHZpLCBhZnRlckVhY2ggfSBmcm9tICd2aXRl
c3QnCmltcG9ydCB7CiAgbWF4RmVlRm9yLCB0b1VuaXRzLCBmcm9tVW5pdHMsIGZhc3RUcmFuc2Zl
clN1cHBvcnRlZCwgZXRhU2Vjb25kcywKICBnZXRUcmFuc2ZlclF1b3RlLCBnZXRCb3RoUXVvdGVz
LCBmZXRjaEZlZVRhYmxlLAp9IGZyb20gJ0AvbGliL2NjdHAtY2xpZW50JwoKLy8gPT09PT09PT09
PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
PT09PT09PT09PQovLyBDQ1RQIG1vbmV5LW1hdGggdW5pdCB0ZXN0cyAoUGhhc2UgNyBIYXJkZW5p
bmcsIHBhcnQgMSkuCi8vCi8vIFRoaXMgaXMgdGhlIGhpZ2hlc3QtdmFsdWUgY292ZXJhZ2UgZ2Fw
IGluIHRoZSB3aG9sZSBwcm9qZWN0OiB0aGUgZmVlIG1hdGgKLy8gbW92ZXMgcmVhbCBVU0RDLCBh
bmQgaXQgYWxyZWFkeSBzaGlwcGVkIG9uZSBidWcgdGhhdCBubyB0ZXN0IHdvdWxkIGhhdmUKLy8g
Y2F1Z2h0IC0gQmlnSW50KGZyYWN0aW9uYWxCcHMpIHRocm93aW5nLCB3aGljaCBzaWxlbnRseSBr
aWxsZWQgdGhlIHF1b3RlIG9uCi8vIGV2ZXJ5IEZhc3QtY2FwYWJsZSBjaGFpbiAoQmFzZS9BcmJp
dHJ1bS9PUC9VbmljaGFpbikuIFRoZSBgZnJhY3Rpb25hbCBicHNgCi8vIGJsb2NrIGJlbG93IGlz
IGEgZGlyZWN0IHJlZ3Jlc3Npb24gdGVzdCBmb3IgZXhhY3RseSB0aGF0IGZhaWx1cmUsIHNvIGl0
IGNhbgovLyBuZXZlciBjb21lIGJhY2sgdW5ub3RpY2VkLgovLwovLyBFdmVyeXRoaW5nIGhlcmUg
aXMgcHVyZSBvciBmZXRjaC1zdHViYmVkIC0gbm8gbmV0d29yaywgbm8gd2FsbGV0LCBubyBmdW5k
cy4KLy8gPT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
PT09PT09PT09PT09PT09PT09PT09PT09PQoKY29uc3QgVVNEQyA9IChuOiBudW1iZXIpID0+IHRv
VW5pdHMobikgLy8gcmVhZGFibGUgaGVscGVyOiBVU0RDKDEwKSA9PT0gMTBfMDAwMDAwbgoKLy8g
QnVpbGQgYSBmYWtlIElyaXMvcHJveHkgZmVlIHJlc3BvbnNlLiBtaW5pbXVtRmVlIGlzIGluIGJh
c2lzIHBvaW50cyBhbmQgTUFZCi8vIGJlIGZyYWN0aW9uYWwsIGV4YWN0bHkgYXMgQ2lyY2xlIHJl
dHVybnMgaXQuCmZ1bmN0aW9uIHN0dWJGZWVzKHJvd3M6IEFycmF5PHsgZmluYWxpdHlUaHJlc2hv
bGQ6IG51bWJlcjsgbWluaW11bUZlZTogbnVtYmVyIH0+KSB7CiAgdmkuc3R1Ykdsb2JhbCgnZmV0
Y2gnLCB2aS5mbihhc3luYyAoKSA9PiAoewogICAgb2s6IHRydWUsCiAgICBqc29uOiBhc3luYyAo
KSA9PiByb3dzLAogIH0pKSBhcyBhbnkpCn0KZnVuY3Rpb24gc3R1YkZldGNoRmFpbHVyZSgpIHsK
ICB2aS5zdHViR2xvYmFsKCdmZXRjaCcsIHZpLmZuKGFzeW5jICgpID0+IHsgdGhyb3cgbmV3IEVy
cm9yKCduZXR3b3JrIGRvd24nKSB9KSBhcyBhbnkpCn0KZnVuY3Rpb24gc3R1YjQwNCgpIHsKICB2
aS5zdHViR2xvYmFsKCdmZXRjaCcsIHZpLmZuKGFzeW5jICgpID0+ICh7IG9rOiBmYWxzZSwgc3Rh
dHVzOiA0MDQsIGpzb246IGFzeW5jICgpID0+ICh7fSkgfSkpIGFzIGFueSkKfQoKYWZ0ZXJFYWNo
KCgpID0+IHsgdmkudW5zdHViQWxsR2xvYmFscygpIH0pCgovLyDilIDilIAgdG9Vbml0cyAvIGZy
b21Vbml0cyByb3VuZC10cmlwIOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKU
gOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKU
gOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgApkZXNjcmliZSgndG9Vbml0cyAvIGZyb21V
bml0cycsICgpID0+IHsKICBpdCgnY29udmVydHMgd2hvbGUgYW5kIGZyYWN0aW9uYWwgVVNEQyB0
byA2LWRlY2ltYWwgYmFzZSB1bml0cyBleGFjdGx5JywgKCkgPT4gewogICAgZXhwZWN0KHRvVW5p
dHMoMSkpLnRvQmUoQmlnSW50KDEwMDAwMDApKQogICAgZXhwZWN0KHRvVW5pdHMoMTAuNSkpLnRv
QmUoQmlnSW50KDEwNTAwMDAwKSkKICAgIGV4cGVjdCh0b1VuaXRzKDAuMDAwMDAxKSkudG9CZShC
aWdJbnQoMSkpICAgICAgICAgIC8vIG9uZSBiYXNlIHVuaXQKICAgIGV4cGVjdCh0b1VuaXRzKDAp
KS50b0JlKEJpZ0ludCgwKSkKICB9KQoKICBpdCgnZG9lcyBub3QgbG9zZSBwcmVjaXNpb24gb24g
dmFsdWVzIHRoYXQgZmxvYXQgbWF0aCB3b3VsZCByb3VuZCcsICgpID0+IHsKICAgIC8vIDAuMSAr
IDAuMiBmYW1vdXNseSAhPSAwLjMgaW4gZmxvYXQ7IHN0cmluZy1iYXNlZCB0b1VuaXRzIG11c3Qg
YmUgZXhhY3QuCiAgICBleHBlY3QodG9Vbml0cygwLjMpKS50b0JlKEJpZ0ludCgzMDAwMDApKQog
ICAgZXhwZWN0KHRvVW5pdHMoMTIzLjQ1Njc4OSkpLnRvQmUoQmlnSW50KDEyMzQ1Njc4OSkpIC8v
IDZkcCwgbm8gN3RoIGRpZ2l0CiAgfSkKCiAgaXQoJ3JvdW5kLXRyaXBzIHRocm91Z2ggZnJvbVVu
aXRzJywgKCkgPT4gewogICAgZm9yIChjb25zdCB2IG9mIFswLCAxLCAxMC41LCAwLjAwMDAwMSwg
OTk5Ljk5OTk5OV0pIHsKICAgICAgZXhwZWN0KGZyb21Vbml0cyh0b1VuaXRzKHYpKSkudG9CZSh2
KQogICAgfQogIH0pCn0pCgovLyDilIDilIAgbWF4RmVlRm9yOiBDaXJjbGUncyBleGFjdCBmb3Jt
dWxhLCBkZWNpbWFsLXNhZmUg4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA
4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSACmRlc2NyaWJlKCdtYXhGZWVGb3In
LCAoKSA9PiB7CiAgaXQoJ2lzIHplcm8gZm9yIGEgZnJlZSAoMCBicHMpIHRyYW5zZmVyJywgKCkg
PT4gewogICAgZXhwZWN0KG1heEZlZUZvcihVU0RDKDEwMCksIDApKS50b0JlKEJpZ0ludCgwKSkK
ICAgIGV4cGVjdChtYXhGZWVGb3IoVVNEQygxMDApLCAtMSkpLnRvQmUoQmlnSW50KDApKSAvLyBn
dWFyZDogbmV2ZXIgbmVnYXRpdmUKICB9KQoKICBpdCgnYXBwbGllcyBhbW91bnQgKiByb3VuZChi
cHMqMTAwKS8xZTYgd2l0aCBhIDIwJSBidWZmZXIgYnkgZGVmYXVsdCcsICgpID0+IHsKICAgIC8v
IDEwMCBVU0RDIEAgMSBicHM6IHByb3RvY29sRmVlID0gMTAwZTYgKiAxMDAgLyAxZTYgPSAxMDAw
MCB1bml0cyAoMC4wMSBVU0RDKQogICAgLy8gYnVmZmVyZWQgPSAxMDAwMCAqIDEyMC8xMDAgPSAx
MjAwMAogICAgZXhwZWN0KG1heEZlZUZvcihVU0RDKDEwMCksIDEpKS50b0JlKEJpZ0ludCgxMjAw
MCkpCiAgfSkKCiAgaXQoJ2hhbmRsZXMgRlJBQ1RJT05BTCBicHMgd2l0aG91dCB0aHJvd2luZyAo
dGhlIGNsYXNzIG9mIHRoZSBzaGlwcGVkIGJ1ZyknLCAoKSA9PiB7CiAgICAvLyAxMDAgVVNEQyBA
IDAuNSBicHM6IDEwMGU2ICogcm91bmQoNTApLzFlNiA9IDUwMDA7ICoxLjIgPSA2MDAwCiAgICBl
eHBlY3QoKCkgPT4gbWF4RmVlRm9yKFVTREMoMTAwKSwgMC41KSkubm90LnRvVGhyb3coKQogICAg
ZXhwZWN0KG1heEZlZUZvcihVU0RDKDEwMCksIDAuNSkpLnRvQmUoQmlnSW50KDYwMDApKQogICAg
Ly8gQCAxLjQgYnBzIChDaXJjbGUncyBkb2N1bWVudGVkIG1heCk6IDEwMGU2ICogMTQwIC8xZTYg
PSAxNDAwMDsgKjEuMiA9IDE2ODAwCiAgICBleHBlY3QobWF4RmVlRm9yKFVTREMoMTAwKSwgMS40
KSkudG9CZShCaWdJbnQoMTY4MDApKQogIH0pCgogIGl0KCdyZXNwZWN0cyBhIGN1c3RvbSBidWZm
ZXInLCAoKSA9PiB7CiAgICAvLyAxMDAgVVNEQyBAIDEgYnBzLCAwJSBidWZmZXIgLT4gZXhhY3Rs
eSB0aGUgcHJvdG9jb2wgZmVlLCAxMDAwMAogICAgZXhwZWN0KG1heEZlZUZvcihVU0RDKDEwMCks
IDEsIDApKS50b0JlKEJpZ0ludCgxMDAwMCkpCiAgfSkKCiAgaXQoJ2Zsb29ycyBhdCAxIHVuaXQg
d2hlbiB0aGUgbWF0aCByb3VuZHMgdG8gemVybyBidXQgYSBmZWUgaXMgb3dlZCcsICgpID0+IHsK
ICAgIC8vIEEgdGlueSBhbW91bnQgd2l0aCBhIHRpbnkgYnBzIHJvdW5kcyB0b3dhcmQgMCwgYnV0
IEZhc3QgcmVxdWlyZXMgZmVlID4gMC4KICAgIGV4cGVjdChtYXhGZWVGb3IoQmlnSW50KDEpLCAw
LjAxKSkudG9CZShCaWdJbnQoMSkpCiAgfSkKfSkKCi8vIOKUgOKUgCBzdGF0aWMgY2hhaW4gY2Fw
YWJpbGl0eSDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDi
lIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDi
lIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIAKZGVzY3JpYmUoJ2Zhc3RU
cmFuc2ZlclN1cHBvcnRlZCcsICgpID0+IHsKICBpdCgnaXMgdHJ1ZSBvbmx5IGZvciBjaGFpbnMg
Q2lyY2xlIG9mZmVycyBGYXN0IGFzIGEgc291cmNlJywgKCkgPT4gewogICAgZm9yIChjb25zdCBr
IG9mIFsnZXRoZXJldW0nLCAnYmFzZScsICdhcmJpdHJ1bScsICdvcHRpbWlzbScsICd1bmljaGFp
biddKSB7CiAgICAgIGV4cGVjdChmYXN0VHJhbnNmZXJTdXBwb3J0ZWQoaykpLnRvQmUodHJ1ZSkK
ICAgIH0KICB9KQogIGl0KCdpcyBmYWxzZSB3aGVyZSBzdGFuZGFyZCBhdHRlc3RhdGlvbiBpcyBh
bHJlYWR5IGZhc3QnLCAoKSA9PiB7CiAgICBmb3IgKGNvbnN0IGsgb2YgWydhcmMnLCAnYXZhbGFu
Y2hlJywgJ3BvbHlnb24nLCAnbW9uYWQnXSkgewogICAgICBleHBlY3QoZmFzdFRyYW5zZmVyU3Vw
cG9ydGVkKGspKS50b0JlKGZhbHNlKQogICAgfQogIH0pCiAgaXQoJ2lzIGZhbHNlIGZvciBhbiB1
bmtub3duIGNoYWluIGtleScsICgpID0+IHsKICAgIGV4cGVjdChmYXN0VHJhbnNmZXJTdXBwb3J0
ZWQoJ25vcGUnKSkudG9CZShmYWxzZSkKICB9KQp9KQoKZGVzY3JpYmUoJ2V0YVNlY29uZHMnLCAo
KSA9PiB7CiAgaXQoJ2dpdmVzIGEgZmFzdCBFVEEgb24gZmFzdC1jYXBhYmxlIGNoYWlucyBhbmQg
YSBzbG93IG9uZSBvbiBzdGFuZGFyZCcsICgpID0+IHsKICAgIGV4cGVjdChldGFTZWNvbmRzKCdi
YXNlJywgJ2Zhc3QnKSkudG9CZUxlc3NUaGFuKGV0YVNlY29uZHMoJ2Jhc2UnLCAnc3RhbmRhcmQn
KSkKICB9KQogIGl0KCdyZXBvcnRzIG5lYXItaW5zdGFudCBzdGFuZGFyZCBmaW5hbGl0eSBmb3Ig
QXJjJywgKCkgPT4gewogICAgZXhwZWN0KGV0YVNlY29uZHMoJ2FyYycsICdzdGFuZGFyZCcpKS50
b0JlTGVzc1RoYW5PckVxdWFsKDUpCiAgfSkKfSkKCi8vIOKUgOKUgCBmZXRjaEZlZVRhYmxlOiBu
b3JtYWxpc2VzICsgZGVncmFkZXMgc2FmZWx5IOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKU
gOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKU
gApkZXNjcmliZSgnZmV0Y2hGZWVUYWJsZScsICgpID0+IHsKICBpdCgnbm9ybWFsaXNlcyB0aGUg
ZmVlIHJvd3MgYW5kIGRyb3BzIGVudHJpZXMgd2l0aG91dCBhIHRocmVzaG9sZCcsIGFzeW5jICgp
ID0+IHsKICAgIHN0dWJGZWVzKFsKICAgICAgeyBmaW5hbGl0eVRocmVzaG9sZDogMTAwMCwgbWlu
aW11bUZlZTogMC41IH0sCiAgICAgIHsgZmluYWxpdHlUaHJlc2hvbGQ6IDIwMDAsIG1pbmltdW1G
ZWU6IDAgfSwKICAgICAgeyBmaW5hbGl0eVRocmVzaG9sZDogMCwgICAgbWluaW11bUZlZTogOSB9
LCAvLyBqdW5rLCBtdXN0IGJlIGZpbHRlcmVkCiAgICBdKQogICAgY29uc3QgdCA9IGF3YWl0IGZl
dGNoRmVlVGFibGUoJ3VudXNlZCcsIDYsIDApCiAgICBleHBlY3QodCkudG9FcXVhbChbCiAgICAg
IHsgZmluYWxpdHlUaHJlc2hvbGQ6IDEwMDAsIG1pbmltdW1GZWVCcHM6IDAuNSB9LAogICAgICB7
IGZpbmFsaXR5VGhyZXNob2xkOiAyMDAwLCBtaW5pbXVtRmVlQnBzOiAwIH0sCiAgICBdKQogIH0p
CgogIGl0KCdyZXR1cm5zIFtdIG9uIGEgbmV0d29yayBmYWlsdXJlIGluc3RlYWQgb2YgdGhyb3dp
bmcnLCBhc3luYyAoKSA9PiB7CiAgICBzdHViRmV0Y2hGYWlsdXJlKCkKICAgIGF3YWl0IGV4cGVj
dChmZXRjaEZlZVRhYmxlKCd1bnVzZWQnLCA2LCAwKSkucmVzb2x2ZXMudG9FcXVhbChbXSkKICB9
KQoKICBpdCgncmV0dXJucyBbXSBvbiBhIDQwNCAocm91dGUvZW5kcG9pbnQgbWlzc2luZyknLCBh
c3luYyAoKSA9PiB7CiAgICBzdHViNDA0KCkKICAgIGF3YWl0IGV4cGVjdChmZXRjaEZlZVRhYmxl
KCd1bnVzZWQnLCA2LCAwKSkucmVzb2x2ZXMudG9FcXVhbChbXSkKICB9KQp9KQoKLy8g4pSA4pSA
IGdldFRyYW5zZmVyUXVvdGU6IHRoZSB3aG9sZSBwYXRoLCBpbmNsdWRpbmcgdGhlIHJlZ3Jlc3Np
b24g4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSACmRlc2NyaWJl
KCdnZXRUcmFuc2ZlclF1b3RlJywgKCkgPT4gewogIGNvbnN0IGJhc2UgPSB7CiAgICBpcmlzQmFz
ZTogJ3VudXNlZCcsIGZyb21LZXk6ICdiYXNlJywgZnJvbURvbWFpbjogNiwgdG9Eb21haW46IDAs
CiAgICBhbW91bnRVbml0czogVVNEQygxMDApLAogIH0KCiAgaXQoJ3F1b3RlcyBhIEZBU1QgdHJh
bnNmZXIgd2l0aCBhIGZyYWN0aW9uYWwtYnBzIGZlZSAocmVncmVzc2lvbiknLCBhc3luYyAoKSA9
PiB7CiAgICBzdHViRmVlcyhbeyBmaW5hbGl0eVRocmVzaG9sZDogMTAwMCwgbWluaW11bUZlZTog
MC41IH1dKQogICAgY29uc3QgcSA9IGF3YWl0IGdldFRyYW5zZmVyUXVvdGUoeyAuLi5iYXNlLCBt
b2RlOiAnZmFzdCcgfSkKICAgIGV4cGVjdChxLm1vZGUpLnRvQmUoJ2Zhc3QnKQogICAgZXhwZWN0
KHEuZmVlQnBzKS50b0JlKDAuNSkKICAgIC8vIGZlZVVuaXRzID0gMTAwZTYgKiByb3VuZCgwLjUq
MTAwKS8xZTYgPSAxMDBlNiAqIDUwIC8xZTYgPSA1MDAwCiAgICBleHBlY3QocS5mZWVVbml0cyku
dG9CZShCaWdJbnQoNTAwMCkpCiAgICBleHBlY3QocS5yZWNlaXZlVW5pdHMpLnRvQmUoVVNEQygx
MDApIC0gQmlnSW50KDUwMDApKQogICAgZXhwZWN0KHEubWF4RmVlVW5pdHMpLnRvQmUoQmlnSW50
KDYwMDApKSAvLyA1MDAwICogMS4yCiAgICBleHBlY3QocS5kZWdyYWRlZCkudG9CZShmYWxzZSkK
ICB9KQoKICBpdCgndHJlYXRzIFNUQU5EQVJEIGFzIGZyZWUnLCBhc3luYyAoKSA9PiB7CiAgICBz
dHViRmVlcyhbeyBmaW5hbGl0eVRocmVzaG9sZDogMjAwMCwgbWluaW11bUZlZTogMCB9XSkKICAg
IGNvbnN0IHEgPSBhd2FpdCBnZXRUcmFuc2ZlclF1b3RlKHsgLi4uYmFzZSwgbW9kZTogJ3N0YW5k
YXJkJyB9KQogICAgZXhwZWN0KHEuZmVlQnBzKS50b0JlKDApCiAgICBleHBlY3QocS5mZWVVbml0
cykudG9CZShCaWdJbnQoMCkpCiAgICBleHBlY3QocS5yZWNlaXZlVW5pdHMpLnRvQmUoVVNEQygx
MDApKQogICAgZXhwZWN0KHEubWF4RmVlVW5pdHMpLnRvQmUoQmlnSW50KDApKQogIH0pCgogIGl0
KCdkZWdyYWRlcyBGYXN0IHRvIFN0YW5kYXJkIG9uIGEgc291cmNlIGNoYWluIHRoYXQgY2Fubm90
IGRvIEZhc3QnLCBhc3luYyAoKSA9PiB7CiAgICBzdHViRmVlcyhbeyBmaW5hbGl0eVRocmVzaG9s
ZDogMjAwMCwgbWluaW11bUZlZTogMCB9XSkKICAgIGNvbnN0IHEgPSBhd2FpdCBnZXRUcmFuc2Zl
clF1b3RlKHsKICAgICAgLi4uYmFzZSwgZnJvbUtleTogJ2FyYycsIG1vZGU6ICdmYXN0JywKICAg
IH0pCiAgICBleHBlY3QocS5tb2RlKS50b0JlKCdzdGFuZGFyZCcpIC8vIHNpbGVudGx5IGRvd25n
cmFkZWQKICAgIGV4cGVjdChxLmRlZ3JhZGVkKS50b0JlKHRydWUpCiAgICBleHBlY3QocS5mYXN0
U3VwcG9ydGVkKS50b0JlKGZhbHNlKQogIH0pCgogIGl0KCduZXZlciBtYWtlcyB0aGUgcmVjaXBp
ZW50IHJlY2VpdmUgbW9yZSB0aGFuIHdhcyBzZW50JywgYXN5bmMgKCkgPT4gewogICAgc3R1YkZl
ZXMoW3sgZmluYWxpdHlUaHJlc2hvbGQ6IDEwMDAsIG1pbmltdW1GZWU6IDEuNCB9XSkKICAgIGNv
bnN0IHEgPSBhd2FpdCBnZXRUcmFuc2ZlclF1b3RlKHsgLi4uYmFzZSwgbW9kZTogJ2Zhc3QnIH0p
CiAgICBleHBlY3QocS5yZWNlaXZlVW5pdHMgKyBxLmZlZVVuaXRzKS50b0JlKGJhc2UuYW1vdW50
VW5pdHMpCiAgfSkKCiAgaXQoJ3N0aWxsIHJldHVybnMgYSB1c2FibGUgcXVvdGUgd2hlbiB0aGUg
ZmVlIEFQSSBpcyBkb3duIChTdGFuZGFyZCBmcmVlKScsIGFzeW5jICgpID0+IHsKICAgIHN0dWJG
ZXRjaEZhaWx1cmUoKQogICAgY29uc3QgcSA9IGF3YWl0IGdldFRyYW5zZmVyUXVvdGUoeyAuLi5i
YXNlLCBtb2RlOiAnc3RhbmRhcmQnIH0pCiAgICBleHBlY3QocS5mZWVVbml0cykudG9CZShCaWdJ
bnQoMCkpCiAgICBleHBlY3QocS5yZWNlaXZlVW5pdHMpLnRvQmUoVVNEQygxMDApKQogIH0pCn0p
CgovLyDilIDilIAgZ2V0Qm90aFF1b3RlczogcG93ZXJzIHRoZSBVSSB0b2dnbGUg4pSA4pSA4pSA
4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA
4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSACmRlc2NyaWJlKCdn
ZXRCb3RoUXVvdGVzJywgKCkgPT4gewogIGl0KCdyZXR1cm5zIGJvdGggbW9kZXMgZm9yIGEgZmFz
dC1jYXBhYmxlIGNoYWluLCBzaGFyaW5nIG9uZSBmZWUgZmV0Y2gnLCBhc3luYyAoKSA9PiB7CiAg
ICBjb25zdCBzcHkgPSB2aS5mbihhc3luYyAoKSA9PiAoewogICAgICBvazogdHJ1ZSwKICAgICAg
anNvbjogYXN5bmMgKCkgPT4gWwogICAgICAgIHsgZmluYWxpdHlUaHJlc2hvbGQ6IDEwMDAsIG1p
bmltdW1GZWU6IDAuNSB9LAogICAgICAgIHsgZmluYWxpdHlUaHJlc2hvbGQ6IDIwMDAsIG1pbmlt
dW1GZWU6IDAgfSwKICAgICAgXSwKICAgIH0pKQogICAgdmkuc3R1Ykdsb2JhbCgnZmV0Y2gnLCBz
cHkgYXMgYW55KQoKICAgIGNvbnN0IHsgZmFzdCwgc3RhbmRhcmQgfSA9IGF3YWl0IGdldEJvdGhR
dW90ZXMoewogICAgICBpcmlzQmFzZTogJ3VudXNlZCcsIGZyb21LZXk6ICdiYXNlJywgZnJvbURv
bWFpbjogNiwgdG9Eb21haW46IDAsCiAgICAgIGFtb3VudFVuaXRzOiBVU0RDKDEwMCksCiAgICB9
KQogICAgZXhwZWN0KGZhc3QpLm5vdC50b0JlTnVsbCgpCiAgICBleHBlY3QoZmFzdCEuZmVlVW5p
dHMpLnRvQmUoQmlnSW50KDUwMDApKQogICAgZXhwZWN0KHN0YW5kYXJkLmZlZVVuaXRzKS50b0Jl
KEJpZ0ludCgwKSkKICAgIGV4cGVjdChzcHkpLnRvSGF2ZUJlZW5DYWxsZWRUaW1lcygxKSAvLyBv
bmUgc2hhcmVkIGZlZS10YWJsZSBmZXRjaAogIH0pCgogIGl0KCdyZXR1cm5zIGZhc3Q9bnVsbCBm
b3IgYSBjaGFpbiB0aGF0IGNhbm5vdCBzb3VyY2UgRmFzdCcsIGFzeW5jICgpID0+IHsKICAgIHN0
dWJGZWVzKFt7IGZpbmFsaXR5VGhyZXNob2xkOiAyMDAwLCBtaW5pbXVtRmVlOiAwIH1dKQogICAg
Y29uc3QgeyBmYXN0LCBzdGFuZGFyZCB9ID0gYXdhaXQgZ2V0Qm90aFF1b3Rlcyh7CiAgICAgIGly
aXNCYXNlOiAndW51c2VkJywgZnJvbUtleTogJ3BvbHlnb24nLCBmcm9tRG9tYWluOiA3LCB0b0Rv
bWFpbjogMCwKICAgICAgYW1vdW50VW5pdHM6IFVTREMoMTAwKSwKICAgIH0pCiAgICBleHBlY3Qo
ZmFzdCkudG9CZU51bGwoKQogICAgZXhwZWN0KHN0YW5kYXJkKS5ub3QudG9CZU51bGwoKQogIH0p
CgogIGl0KCdzdGlsbCB5aWVsZHMgYSBGYXN0IHF1b3RlIHdoZW4gdGhlIGZlZSBudW1iZXIgaXMg
bWlzc2luZyAoZmVlIHNob3dzIEZyZWUpJywgYXN5bmMgKCkgPT4gewogICAgLy8gVGhlIGJ1ZyBz
eW1wdG9tIHdhcyBGYXN0IHZhbmlzaGluZzsgYXZhaWxhYmlsaXR5IG11c3QgTk9UIGRlcGVuZCBv
biB0aGUKICAgIC8vIGZlZSBmZXRjaC4gV2l0aCBhbiBlbXB0eSB0YWJsZSwgRmFzdCBpcyBzdGls
bCBvZmZlcmVkIGF0IDAgZmVlLgogICAgc3R1YkZlZXMoW10pCiAgICBjb25zdCB7IGZhc3QgfSA9
IGF3YWl0IGdldEJvdGhRdW90ZXMoewogICAgICBpcmlzQmFzZTogJ3VudXNlZCcsIGZyb21LZXk6
ICdiYXNlJywgZnJvbURvbWFpbjogNiwgdG9Eb21haW46IDAsCiAgICAgIGFtb3VudFVuaXRzOiBV
U0RDKDEwMCksCiAgICB9KQogICAgZXhwZWN0KGZhc3QpLm5vdC50b0JlTnVsbCgpCiAgICBleHBl
Y3QoZmFzdCEuZmVlVW5pdHMpLnRvQmUoQmlnSW50KDApKQogIH0pCn0pCg==
B64T
base64 -d > "$TMP_C" <<'B64C'
aW1wb3J0IHsgZGVmaW5lQ29uZmlnIH0gZnJvbSAndml0ZXN0L2NvbmZpZycKaW1wb3J0IHBhdGgg
ZnJvbSAncGF0aCcKCmV4cG9ydCBkZWZhdWx0IGRlZmluZUNvbmZpZyh7CiAgdGVzdDogewogICAg
Ly8gTW9uZXktbW92aW5nIGNvZGU6IHJ1biBzZXJpYWxseSBzbyBub3RoaW5nIHJhY2VzIG9uIHNo
YXJlZCBnbG9iYWxzCiAgICAvLyAod2Ugc3R1YiBnbG9iYWwgZmV0Y2ggaW4gdGhlIHF1b3RlIHRl
c3RzKS4KICAgIGZpbGVQYXJhbGxlbGlzbTogZmFsc2UsCiAgICBpbmNsdWRlOiBbJ3Rlc3RzLyoq
LyoudGVzdC50cyddLAogICAgZW52aXJvbm1lbnQ6ICdub2RlJywKICB9LAogIHJlc29sdmU6IHsK
ICAgIC8vIE1pcnJvciB0c2NvbmZpZydzICJALyoiIC0+ICIuLyoiIHNvIHRlc3RzIGltcG9ydCB0
aGUgc2FtZSB3YXkgdGhlIGFwcCBkb2VzLgogICAgYWxpYXM6IHsgJ0AnOiBwYXRoLnJlc29sdmUo
X19kaXJuYW1lLCAnLicpIH0sCiAgfSwKfSkK
B64C

verify(){ local got; got="$( (sha256sum "$1" 2>/dev/null || shasum -a 256 "$1") | awk '{print $1}')"; [ "$got" = "$2" ] || die "Checksum mismatch for $1 (got $got). Nothing written."; }
verify "$TMP_T" "$T_SHA"; verify "$TMP_C" "$C_SHA"
log "Payloads verified."

mkdir -p "$BACKUP_DIR"; cp "$PKG" "$BACKUP_DIR/package.json"

mkdir -p "$TEST_DIR"
if [ -f "$TEST_FILE" ] && grep -qF "Phase 7 Hardening, part 1" "$TEST_FILE"; then
  log "Test file already present - skipping."
else
  cp "$TMP_T" "$TEST_FILE"; log "Added $TEST_FILE"
fi
if [ -f "$CFG" ]; then
  log "vitest.config.ts already present - leaving it."
else
  cp "$TMP_C" "$CFG"; log "Added $CFG"
fi

# package.json: add test scripts (idempotent) and ensure vitest devDep
( cd "$WEB" && npm pkg set scripts.test="vitest run" scripts.test:watch="vitest" >/dev/null )
log "Ensured test scripts in package.json."

log "Installing vitest (dev)..."
( cd "$WEB" && npm install -D vitest@^2.1.9 --no-audit --no-fund --loglevel=error >/dev/null )

log ""
log "=== Running the money-math suite (must pass) ==="
( cd "$WEB" && npx vitest run ) || die "Tests failed - not committing. Fix before shipping."
log "All tests passed."

# ------------------------------------------------------------- deploy gate --
if [ "$FLAG" = "--no-deploy" ]; then
  log "--no-deploy: tests pass and are in place. Rerun without the flag to build + push."
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
log "Pushed Phase 7 Part 1. 'cd nexum-web && npm test' now runs the money-math suite."
log "Next Phase 7 candidates: idempotency on money-moving endpoints, then Sentry + structured logging."
