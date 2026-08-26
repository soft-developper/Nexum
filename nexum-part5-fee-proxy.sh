#!/usr/bin/env bash
# ============================================================================
# Nexum bridge upgrade - PART 5: fee-proxy fix (Fast greyed out / no fees shown)
#
# ROOT CAUSE (diagnosed against Circle's live docs):
#   * The quote fetched Circle's Iris fee API directly from the BROWSER, which
#     is unreliable (CORS / network) - when it failed, the Fast toggle greyed
#     out and the fee panel stayed blank.
#   * On a mainnet build, MAINNET_CHAINS was missing optimism/avalanche/
#     unichain/monad, so chainByKey() returned undefined for them -> same
#     symptom. (Domains were all CORRECT; that was never the issue.)
#
# FIX (four changes across BOTH packages):
#   5a  nexum-api  : add GET /bridge/fees/:from/:to proxy to Circle Iris
#   5b  nexum-web  : fetchFeeTable now calls OUR proxy, not Iris directly
#   5c  nexum-web  : Fast availability = static chain capability, so a slow/failed
#                    fee call can NEVER grey out Fast on a supported chain
#   5d  nexum-web  : add the 4 missing mainnet chains (USDC addresses + domains
#                    verified against Circle's canonical pages)
#
# REQUIRES Parts 1-4.
#
# Delivery contract (your v2 spec) + full deploy:
#   * all four patchers base64 + sha256 verified before running
#   * exact-anchor edits; any drift aborts clean, never half-patched
#   * idempotent per-file markers
#   * timestamped backups of all four files
#   * deploy GATE typechecks BOTH packages, builds web, then commits + pushes:
#       (api)  npx tsc --noEmit
#       (web)  rm -rf .next && npx tsc --noEmit && npm run build
#   * --revert restores all four ; --no-deploy applies only
#
# Run from REPO ROOT (folder containing nexum-web/ and nexum-api/).
#   bash nexum-part5-fee-proxy.sh
#   bash nexum-part5-fee-proxy.sh --no-deploy
#   bash nexum-part5-fee-proxy.sh --revert
# ============================================================================
set -euo pipefail

API_BRIDGE="nexum-api/src/routes/bridge.ts"
CLIENT="nexum-web/lib/cctp-client.ts"
PREVIEW="nexum-web/hooks/useQuotePreview.ts"
CHAINS="nexum-web/lib/cctp-chains.ts"
M_A="__NEXUM_FEE_PROXY__"
M_B="__NEXUM_FEE_PROXY_CLIENT__"
M_C="__NEXUM_FAST_STATIC__"
M_D="__NEXUM_MAINNET_CHAINS__"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR=".nexum-part5-backup/${STAMP}"
A_SHA="f1c6463d279a788ddff7caedd7770c9af18f576c6623b3d4abdbb5d926372add"; B_SHA="6f45ebfb7c11de7612ac58cb29fae0e188df2c3a9a7c9c3fe47d1a830028bf5c"; C_SHA="930a86e8ad50374319593e22a8dfeeaed07e933701ebc45b639730fcf4e1d1e5"; D_SHA="db5ff8751923a785ead76009c8a3137c1a1a436d55e68c136a7163c103dbbf04"
COMMIT_MSG="fix(bridge): proxy CCTP fees via API + static Fast availability + missing mainnet chains (Part 5)"

FLAG="${1:-}"
log(){ printf '  %s\n' "$*"; }
die(){ printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[ -f "$CLIENT" ] || die "Cannot find $CLIENT . Run from the repo root (folder with nexum-web/ and nexum-api/)."
[ -f "$API_BRIDGE" ] || die "Cannot find $API_BRIDGE . This part edits the API too - run from the repo root."

# ---------------------------------------------------------------- revert ----
if [ "$FLAG" = "--revert" ]; then
  LATEST="$(ls -1dt .nexum-part5-backup/*/ 2>/dev/null | head -1 || true)"
  [ -n "$LATEST" ] || die "No Part 5 backup found."
  [ -f "${LATEST}bridge.ts" ]          && cp "${LATEST}bridge.ts"          "$API_BRIDGE" && log "Restored $API_BRIDGE"
  [ -f "${LATEST}cctp-client.ts" ]     && cp "${LATEST}cctp-client.ts"     "$CLIENT"     && log "Restored $CLIENT"
  [ -f "${LATEST}useQuotePreview.ts" ] && cp "${LATEST}useQuotePreview.ts" "$PREVIEW"    && log "Restored $PREVIEW"
  [ -f "${LATEST}cctp-chains.ts" ]     && cp "${LATEST}cctp-chains.ts"     "$CHAINS"     && log "Restored $CHAINS"
  log "Reverted Part 5."
  exit 0
fi

# ------------------------------------------ precondition: Parts 1-4 ---------
grep -qF "__NEXUM_CCTP_QUOTE_ENGINE__" "$CLIENT"      || die "Part 1 missing. Apply Parts 1-4 first."
grep -qF "__NEXUM_BRIDGE_MODE__" nexum-web/hooks/useBridge.ts || die "Part 2 missing."
grep -qF "__NEXUM_BRIDGE_MODE_UI__" nexum-web/components/bridge/BridgeCard.tsx || die "Part 3 missing."
grep -qF "__NEXUM_REATTEST_RETRY__" nexum-web/hooks/useCompleteBridge.ts || die "Part 4 missing."
[ -f "$PREVIEW" ] || die "$PREVIEW missing (Part 3 hook). Apply Part 3 first."

mkdir -p "$BACKUP_DIR"
verify(){ local got; got="$( (sha256sum "$1" 2>/dev/null || shasum -a 256 "$1") | awk '{print $1}')"; [ "$got" = "$2" ] || die "Checksum mismatch for $1 (got $got). Nothing written."; }

TA="$(mktemp /tmp/p5a.XXXXXX.py)"; TB="$(mktemp /tmp/p5b.XXXXXX.py)"
TC="$(mktemp /tmp/p5c.XXXXXX.py)"; TD="$(mktemp /tmp/p5d.XXXXXX.py)"
trap 'rm -f "$TA" "$TB" "$TC" "$TD"' EXIT

base64 -d > "$TA" <<'B64A'
IyEvdXNyL2Jpbi9lbnYgcHl0aG9uMwoiIiIKUGFydCA1YSBwYXRjaGVyIGZvciBuZXh1bS1hcGkv
c3JjL3JvdXRlcy9icmlkZ2UudHMKCkFkZHMgYSBzZXJ2ZXItc2lkZSBwcm94eSBmb3IgQ2lyY2xl
J3MgSXJpcyBmZWUgZW5kcG9pbnQgc28gdGhlIGJyb3dzZXIgbmV2ZXIKaGFzIHRvIHJlYWNoIGly
aXMtYXBpIGRpcmVjdGx5IChDT1JTIC8gbmV0d29yayByZWFjaGFiaWxpdHkgd2FzIGdyZXlpbmcg
b3V0IHRoZQpGYXN0IHRvZ2dsZSBhbmQgaGlkaW5nIHRoZSBmZWUgcGFuZWwpOgoKICBHRVQgL2Jy
aWRnZS9mZWVzLzpmcm9tLzp0byAgLT4gIENpcmNsZSBHRVQgL3YyL2J1cm4vVVNEQy9mZWVzLzpm
cm9tLzp0bwoKQ2hvb3NlcyB0aGUgSXJpcyBob3N0IGZyb20gQ0NUUF9FTlYgKHRlc3RuZXQgZGVm
YXVsdCwgbWF0Y2hpbmcgdGhlIHdlYidzCk5FWFRfUFVCTElDX0NDVFBfRU5WKS4gUmV0dXJucyB0
aGUgcmF3IGZlZSBhcnJheTsgb24gYW55IHVwc3RyZWFtIHByb2JsZW0gaXQKcmV0dXJucyBbXSB3
aXRoIDIwMCBzbyB0aGUgY2xpZW50IGRlZ3JhZGVzIHRvICJTdGFuZGFyZCBpcyBmcmVlIiBpbnN0
ZWFkIG9mCmVycm9yaW5nLgoKSWRlbXBvdGVudCB2aWEgX19ORVhVTV9GRUVfUFJPWFlfXy4gRXhh
Y3QtYW5jaG9yOyBhYm9ydHMgY2xlYW4gb24gZHJpZnQuCiIiIgppbXBvcnQgc3lzLCBpbwpQQVRI
ID0gc3lzLmFyZ3ZbMV0gaWYgbGVuKHN5cy5hcmd2KSA+IDEgZWxzZSAibmV4dW0tYXBpL3NyYy9y
b3V0ZXMvYnJpZGdlLnRzIgpNQVJLRVIgPSAiX19ORVhVTV9GRUVfUFJPWFlfXyIKc3JjID0gaW8u
b3BlbihQQVRILCBlbmNvZGluZz0idXRmLTgiKS5yZWFkKCkKaWYgTUFSS0VSIGluIHNyYzoKICAg
IHByaW50KCIgIFBhcnQgNWEgYWxyZWFkeSBhcHBsaWVkIC0gbm90aGluZyB0byBkby4iKQogICAg
c3lzLmV4aXQoMCkKClJPVVRFID0gcicnJwovLyBfX05FWFVNX0ZFRV9QUk9YWV9fIChwYXJ0NSkg
Q0NUUCBmZWUgcHJveHkgLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tCi8vIFRoZSBicmlk
Z2UgVUkgbmVlZHMgQ2lyY2xlJ3MgRmFzdC1UcmFuc2ZlciBmZWUgZm9yIGEgcm91dGUgdG8gc2hv
dyB0aGUgZmVlLAovLyB0aGUgeW91LXJlY2VpdmUgdG90YWwsIGFuZCB0byBjb21wdXRlIG1heEZl
ZS4gQ2FsbGluZyBDaXJjbGUncyBJcmlzIEFQSSBmcm9tCi8vIHRoZSBicm93c2VyIGlzIHVucmVs
aWFibGUgKENPUlMgLyBuZXR3b3JrKSwgd2hpY2ggbGVmdCB0aGUgRmFzdCBvcHRpb24gZ3JleWVk
Ci8vIG91dCBhbmQgdGhlIGZlZSBwYW5lbCBibGFuay4gUHJveHlpbmcgaXQgaGVyZSBtYWtlcyBp
dCByZWxpYWJsZS4KLy8KLy8gR0VUIC9icmlkZ2UvZmVlcy86ZnJvbS86dG8gIC0+ICBJcmlzIEdF
VCAvdjIvYnVybi9VU0RDL2ZlZXMvOmZyb20vOnRvCi8vIFJldHVybnMgdGhlIHJhdyBmZWUgYXJy
YXkuIEZhc3QgaXMgdGhlIGVudHJ5IHdpdGggZmluYWxpdHlUaHJlc2hvbGQgMTAwMCwKLy8gU3Rh
bmRhcmQgaXMgMjAwMCAoY3VycmVudGx5IGZyZWUpLiBPbiBhbnkgdXBzdHJlYW0gZmFpbHVyZSB3
ZSByZXR1cm4gW10gd2l0aAovLyAyMDAgc28gdGhlIGNsaWVudCBkZWdyYWRlcyBncmFjZWZ1bGx5
IHJhdGhlciB0aGFuIGJyZWFraW5nIHRoZSBwYW5lbC4KY29uc3QgQ0NUUF9JUklTX0JBU0UgPQog
IChwcm9jZXNzLmVudi5DQ1RQX0VOViA9PT0gJ21haW5uZXQnKQogICAgPyAnaHR0cHM6Ly9pcmlz
LWFwaS5jaXJjbGUuY29tJwogICAgOiAnaHR0cHM6Ly9pcmlzLWFwaS1zYW5kYm94LmNpcmNsZS5j
b20nCgpyb3V0ZXIuZ2V0KCcvZmVlcy86ZnJvbS86dG8nLCBhc3luYyAocmVxLCByZXMpID0+IHsK
ICBjb25zdCBmcm9tID0gTnVtYmVyKHJlcS5wYXJhbXMuZnJvbSkKICBjb25zdCB0byAgID0gTnVt
YmVyKHJlcS5wYXJhbXMudG8pCiAgaWYgKCFOdW1iZXIuaXNGaW5pdGUoZnJvbSkgfHwgIU51bWJl
ci5pc0Zpbml0ZSh0bykpIHsKICAgIHJldHVybiByZXMuc3RhdHVzKDQwMCkuanNvbih7IGVycm9y
OiAnZnJvbSBhbmQgdG8gZG9tYWlucyBtdXN0IGJlIG51bWJlcnMnIH0pCiAgfQogIHRyeSB7CiAg
ICBjb25zdCB1cmwgPSBgJHtDQ1RQX0lSSVNfQkFTRX0vdjIvYnVybi9VU0RDL2ZlZXMvJHtmcm9t
fS8ke3RvfWAKICAgIGNvbnN0IHVwc3RyZWFtID0gYXdhaXQgZmV0Y2godXJsKQogICAgaWYgKCF1
cHN0cmVhbS5vaykgewogICAgICAvLyBOb3QgZmF0YWw6IGFuIHVua25vd24gcm91dGUgb3IgYSB0
cmFuc2llbnQgSXJpcyBlcnJvciBqdXN0IG1lYW5zIHdlCiAgICAgIC8vIGNhbid0IHNob3cgYSBG
YXN0IGZlZS4gU3RhbmRhcmQgaXMgZnJlZSwgc28gW10gaXMgYSBzYWZlIGFuc3dlci4KICAgICAg
cmV0dXJuIHJlcy5qc29uKFtdKQogICAgfQogICAgY29uc3QgZGF0YSA9IGF3YWl0IHVwc3RyZWFt
Lmpzb24oKQogICAgY29uc3Qgcm93cyA9IEFycmF5LmlzQXJyYXkoZGF0YSkgPyBkYXRhIDogKChk
YXRhIGFzIGFueSk/LmRhdGEgPz8gW2RhdGFdKQogICAgcmV0dXJuIHJlcy5qc29uKHJvd3MpCiAg
fSBjYXRjaCB7CiAgICByZXR1cm4gcmVzLmpzb24oW10pCiAgfQp9KQoKJycnCgphbmNob3IgPSAi
ZXhwb3J0IGRlZmF1bHQgcm91dGVyXG4iCm4gPSBzcmMuY291bnQoYW5jaG9yKQppZiBuICE9IDE6
CiAgICBwcmludChmIkVSUk9SOiBhbmNob3IgJ2V4cG9ydCBkZWZhdWx0IHJvdXRlcicgbWF0Y2hl
ZCB7bn0gdGltZXMuIEFib3J0aW5nLiIpCiAgICBzeXMuZXhpdCgyKQpzcmMgPSBzcmMucmVwbGFj
ZShhbmNob3IsIFJPVVRFICsgYW5jaG9yKQppby5vcGVuKFBBVEgsICJ3IiwgZW5jb2Rpbmc9InV0
Zi04Iikud3JpdGUoc3JjKQpwcmludCgiICBQYXJ0IDVhIGFwcGxpZWQgdG8iLCBQQVRIKQo=
B64A
base64 -d > "$TB" <<'B64B'
IyEvdXNyL2Jpbi9lbnYgcHl0aG9uMwoiIiIKUGFydCA1YiBwYXRjaGVyIGZvciBuZXh1bS13ZWIv
bGliL2NjdHAtY2xpZW50LnRzCgpSb3V0ZXMgdGhlIGZlZSBsb29rdXAgdGhyb3VnaCB0aGUgQVBJ
IHByb3h5IChQYXJ0IDVhKSBpbnN0ZWFkIG9mIGNhbGxpbmcKQ2lyY2xlJ3MgSXJpcyBkaXJlY3Rs
eSBmcm9tIHRoZSBicm93c2VyLiBLZWVwcyBmZXRjaEZlZVRhYmxlJ3Mgc2lnbmF0dXJlIHNvIG5v
CmNhbGxlciBjaGFuZ2VzLiBUaGUgZmlyc3QgYXJnIGlzIHN0aWxsIGFjY2VwdGVkIGZvciBjb21w
YXRpYmlsaXR5IGJ1dCB0aGUgY2FsbApub3cgdGFyZ2V0cyBORVhUX1BVQkxJQ19BUElfVVJMIC9i
cmlkZ2UvZmVlcy86ZnJvbS86dG8uCgpJZGVtcG90ZW50IHZpYSBfX05FWFVNX0ZFRV9QUk9YWV9D
TElFTlRfXy4gRXhhY3QtYW5jaG9yOyBhYm9ydHMgY2xlYW4gb24gZHJpZnQuCiIiIgppbXBvcnQg
c3lzLCBpbwpQQVRIID0gc3lzLmFyZ3ZbMV0gaWYgbGVuKHN5cy5hcmd2KSA+IDEgZWxzZSAibmV4
dW0td2ViL2xpYi9jY3RwLWNsaWVudC50cyIKTUFSS0VSID0gIl9fTkVYVU1fRkVFX1BST1hZX0NM
SUVOVF9fIgpzcmMgPSBpby5vcGVuKFBBVEgsIGVuY29kaW5nPSJ1dGYtOCIpLnJlYWQoKQppZiBN
QVJLRVIgaW4gc3JjOgogICAgcHJpbnQoIiAgUGFydCA1YiBhbHJlYWR5IGFwcGxpZWQgLSBub3Ro
aW5nIHRvIGRvLiIpCiAgICBzeXMuZXhpdCgwKQoKT0xEID0gIiIiZXhwb3J0IGFzeW5jIGZ1bmN0
aW9uIGZldGNoRmVlVGFibGUoCiAgaXJpc0Jhc2U6IHN0cmluZywgZnJvbURvbWFpbjogbnVtYmVy
LCB0b0RvbWFpbjogbnVtYmVyLAopOiBQcm9taXNlPEZlZUVudHJ5W10+IHsKICBjb25zdCB1cmwg
PSBgJHtpcmlzQmFzZX0vdjIvYnVybi9VU0RDL2ZlZXMvJHtmcm9tRG9tYWlufS8ke3RvRG9tYWlu
fWAKICB0cnkgewogICAgY29uc3QgcmVzID0gYXdhaXQgZmV0Y2godXJsKQogICAgaWYgKCFyZXMu
b2spIHJldHVybiBbXQogICAgY29uc3QgZGF0YTogYW55ID0gYXdhaXQgcmVzLmpzb24oKQogICAg
Y29uc3Qgcm93czogYW55W10gPSBBcnJheS5pc0FycmF5KGRhdGEpID8gZGF0YSA6IChkYXRhPy5k
YXRhID8/IFtkYXRhXSkKICAgIHJldHVybiByb3dzCiAgICAgIC5tYXAociA9PiAoewogICAgICAg
IGZpbmFsaXR5VGhyZXNob2xkOiBOdW1iZXIocj8uZmluYWxpdHlUaHJlc2hvbGQgPz8gMCksCiAg
ICAgICAgbWluaW11bUZlZUJwczogICAgIE51bWJlcihyPy5taW5pbXVtRmVlID8/IDApLAogICAg
ICB9KSkKICAgICAgLmZpbHRlcihyID0+IHIuZmluYWxpdHlUaHJlc2hvbGQgPiAwKQogIH0gY2F0
Y2ggewogICAgcmV0dXJuIFtdCiAgfQp9IiIiCgpORVcgPSAiIiIvLyBfX05FWFVNX0ZFRV9QUk9Y
WV9DTElFTlRfXyAocGFydDUpIGZlZSBsb29rdXAgZ29lcyB0aHJvdWdoIE9VUiBBUEksIG5vdCBJ
cmlzLgovLyBDYWxsaW5nIENpcmNsZSdzIElyaXMgZmVlIGVuZHBvaW50IHN0cmFpZ2h0IGZyb20g
dGhlIGJyb3dzZXIgd2FzIHVucmVsaWFibGUKLy8gKENPUlMgLyBuZXR3b3JrKSwgd2hpY2ggZ3Jl
eWVkIG91dCBGYXN0IGFuZCBoaWQgdGhlIGZlZSBwYW5lbC4gVGhlIEFQSSBwcm94aWVzCi8vIGl0
IHNlcnZlci1zaWRlLiBGaXJzdCBhcmcga2VwdCBmb3Igc2lnbmF0dXJlIGNvbXBhdGliaWxpdHk7
IGl0IGlzIHVudXNlZCBub3cuCmNvbnN0IEZFRV9BUElfQkFTRSA9IHByb2Nlc3MuZW52Lk5FWFRf
UFVCTElDX0FQSV9VUkwgPz8gJ2h0dHA6Ly9sb2NhbGhvc3Q6NDAwMCcKCmV4cG9ydCBhc3luYyBm
dW5jdGlvbiBmZXRjaEZlZVRhYmxlKAogIF9pcmlzQmFzZTogc3RyaW5nLCBmcm9tRG9tYWluOiBu
dW1iZXIsIHRvRG9tYWluOiBudW1iZXIsCik6IFByb21pc2U8RmVlRW50cnlbXT4gewogIGNvbnN0
IHVybCA9IGAke0ZFRV9BUElfQkFTRX0vYnJpZGdlL2ZlZXMvJHtmcm9tRG9tYWlufS8ke3RvRG9t
YWlufWAKICB0cnkgewogICAgY29uc3QgcmVzID0gYXdhaXQgZmV0Y2godXJsKQogICAgaWYgKCFy
ZXMub2spIHJldHVybiBbXQogICAgY29uc3QgZGF0YTogYW55ID0gYXdhaXQgcmVzLmpzb24oKQog
ICAgY29uc3Qgcm93czogYW55W10gPSBBcnJheS5pc0FycmF5KGRhdGEpID8gZGF0YSA6IChkYXRh
Py5kYXRhID8/IFtkYXRhXSkKICAgIHJldHVybiByb3dzCiAgICAgIC5tYXAociA9PiAoewogICAg
ICAgIGZpbmFsaXR5VGhyZXNob2xkOiBOdW1iZXIocj8uZmluYWxpdHlUaHJlc2hvbGQgPz8gMCks
CiAgICAgICAgbWluaW11bUZlZUJwczogICAgIE51bWJlcihyPy5taW5pbXVtRmVlID8/IDApLAog
ICAgICB9KSkKICAgICAgLmZpbHRlcihyID0+IHIuZmluYWxpdHlUaHJlc2hvbGQgPiAwKQogIH0g
Y2F0Y2ggewogICAgcmV0dXJuIFtdCiAgfQp9IiIiCgpuID0gc3JjLmNvdW50KE9MRCkKaWYgbiAh
PSAxOgogICAgcHJpbnQoZiJFUlJPUjogZmV0Y2hGZWVUYWJsZSBhbmNob3IgbWF0Y2hlZCB7bn0g
dGltZXMuIEFib3J0aW5nLiIpCiAgICBzeXMuZXhpdCgyKQpzcmMgPSBzcmMucmVwbGFjZShPTEQs
IE5FVykKaW8ub3BlbihQQVRILCAidyIsIGVuY29kaW5nPSJ1dGYtOCIpLndyaXRlKHNyYykKcHJp
bnQoIiAgUGFydCA1YiBhcHBsaWVkIHRvIiwgUEFUSCkK
B64B
base64 -d > "$TC" <<'B64C'
IyEvdXNyL2Jpbi9lbnYgcHl0aG9uMwoiIiIKUGFydCA1YyBwYXRjaGVyIGZvciBuZXh1bS13ZWIv
aG9va3MvdXNlUXVvdGVQcmV2aWV3LnRzCgpNYWtlcyBGYXN0IGF2YWlsYWJpbGl0eSBkZXBlbmQg
b24gdGhlIFNUQVRJQyBwZXItY2hhaW4gY2FwYWJpbGl0eQooZmFzdFRyYW5zZmVyU3VwcG9ydGVk
KSwgbm90IG9uIHdoZXRoZXIgdGhlIGZlZSBmZXRjaCBoYXBwZW5lZCB0byByZXR1cm4gYSBmYXN0
Cm9iamVjdC4gQmVmb3JlIHRoaXMsIGFueSBoaWNjdXAgaW4gdGhlIGZlZSBjYWxsIGxlZnQgZmFz
dEF2YWlsYWJsZT1mYWxzZSwgd2hpY2gKZ3JleWVkIG91dCB0aGUgRmFzdCB0b2dnbGUgb24gY2hh
aW5zIHRoYXQgY2xlYXJseSBzdXBwb3J0IGl0IChCYXNlLCBBcmJpdHJ1bSwKT1AsIFVuaWNoYWlu
KS4gTm93IHRoZSB0b2dnbGUgcmVmbGVjdHMgdGhlIGNoYWluJ3MgcmVhbCBjYXBhYmlsaXR5IGFu
ZCB0aGUgZmVlCnNpbXBseSBzaG93cyAiRnJlZSIgdW50aWwgdGhlIG51bWJlciBhcnJpdmVzLgoK
SWRlbXBvdGVudCB2aWEgX19ORVhVTV9GQVNUX1NUQVRJQ19fLiBFeGFjdC1hbmNob3I7IGFib3J0
cyBjbGVhbiBvbiBkcmlmdC4KIiIiCmltcG9ydCBzeXMsIGlvClBBVEggPSBzeXMuYXJndlsxXSBp
ZiBsZW4oc3lzLmFyZ3YpID4gMSBlbHNlICJuZXh1bS13ZWIvaG9va3MvdXNlUXVvdGVQcmV2aWV3
LnRzIgpNQVJLRVIgPSAiX19ORVhVTV9GQVNUX1NUQVRJQ19fIgpzcmMgPSBpby5vcGVuKFBBVEgs
IGVuY29kaW5nPSJ1dGYtOCIpLnJlYWQoKQppZiBNQVJLRVIgaW4gc3JjOgogICAgcHJpbnQoIiAg
UGFydCA1YyBhbHJlYWR5IGFwcGxpZWQgLSBub3RoaW5nIHRvIGRvLiIpCiAgICBzeXMuZXhpdCgw
KQoKZWRpdHMgPSBbXQoKIyAxLiBpbXBvcnQgZmFzdFRyYW5zZmVyU3VwcG9ydGVkIGFsb25nc2lk
ZSB0aGUgb3RoZXIgY2xpZW50IGltcG9ydHMuCmVkaXRzLmFwcGVuZCgoCiAgICAiaW1wb3J0IiwK
ICAgICJpbXBvcnQge1xuICBnZXRCb3RoUXVvdGVzLCB0b1VuaXRzLCBmcm9tVW5pdHMsXG4gIHR5
cGUgVHJhbnNmZXJRdW90ZSxcbn0gZnJvbSAnQC9saWIvY2N0cC1jbGllbnQnIiwKICAgICJpbXBv
cnQge1xuICAvLyBfX05FWFVNX0ZBU1RfU1RBVElDX18gKHBhcnQ1KSBGYXN0IGF2YWlsYWJpbGl0
eSBpcyBhIHN0YXRpYyBjaGFpbiBmYWN0XG4gIGdldEJvdGhRdW90ZXMsIHRvVW5pdHMsIGZyb21V
bml0cywgZmFzdFRyYW5zZmVyU3VwcG9ydGVkLFxuICB0eXBlIFRyYW5zZmVyUXVvdGUsXG59IGZy
b20gJ0AvbGliL2NjdHAtY2xpZW50JyIsCikpCgojIDIuIFNldCBmYXN0QXZhaWxhYmxlIGZyb20g
dGhlIHN0YXRpYyBjYXBhYmlsaXR5LCBub3QgZnJvbSBmYXN0ICE9PSBudWxsLgplZGl0cy5hcHBl
bmQoKAogICAgImZhc3RBdmFpbGFibGUgc3VjY2VzcyIsCiAgICAiICAgICAgICBpZiAoaWQgIT09
IHJlcUlkLmN1cnJlbnQpIHJldHVybiAvLyBhIG5ld2VyIHJlcXVlc3Qgc3VwZXJzZWRlZCB0aGlz
IG9uZVxuICAgICAgICBzZXRQcmV2aWV3KHtcbiAgICAgICAgICBsb2FkaW5nOiBmYWxzZSxcbiAg
ICAgICAgICBmYXN0LFxuICAgICAgICAgIHN0YW5kYXJkLFxuICAgICAgICAgIGZhc3RBdmFpbGFi
bGU6IGZhc3QgIT09IG51bGwsXG4gICAgICAgIH0pIiwKICAgICIgICAgICAgIGlmIChpZCAhPT0g
cmVxSWQuY3VycmVudCkgcmV0dXJuIC8vIGEgbmV3ZXIgcmVxdWVzdCBzdXBlcnNlZGVkIHRoaXMg
b25lXG4gICAgICAgIHNldFByZXZpZXcoe1xuICAgICAgICAgIGxvYWRpbmc6IGZhbHNlLFxuICAg
ICAgICAgIGZhc3QsXG4gICAgICAgICAgc3RhbmRhcmQsXG4gICAgICAgICAgLy8gRmFzdCBhdmFp
bGFiaWxpdHkgaXMgYSBwcm9wZXJ0eSBvZiB0aGUgU09VUkNFIENIQUlOLCBub3Qgb2Ygd2hldGhl
clxuICAgICAgICAgIC8vIHRoZSBmZWUgZmV0Y2ggc3VjY2VlZGVkLiBOZXZlciBncmV5IG91dCBG
YXN0IG9uIGEgY2hhaW4gdGhhdFxuICAgICAgICAgIC8vIHN1cHBvcnRzIGl0IGp1c3QgYmVjYXVz
ZSB0aGUgZmVlIG51bWJlciBpc24ndCBpbiB5ZXQuXG4gICAgICAgICAgZmFzdEF2YWlsYWJsZTog
ZmFzdFRyYW5zZmVyU3VwcG9ydGVkKGZyb20ua2V5KSxcbiAgICAgICAgfSkiLAopKQoKZm9yIGRl
c2MsIG9sZCwgbmV3IGluIGVkaXRzOgogICAgbiA9IHNyYy5jb3VudChvbGQpCiAgICBpZiBuICE9
IDE6CiAgICAgICAgcHJpbnQoZiJFUlJPUjogYW5jaG9yICd7ZGVzY30nIG1hdGNoZWQge259IHRp
bWVzLiBBYm9ydGluZy4iKQogICAgICAgIHN5cy5leGl0KDIpCiAgICBzcmMgPSBzcmMucmVwbGFj
ZShvbGQsIG5ldykKaW8ub3BlbihQQVRILCAidyIsIGVuY29kaW5nPSJ1dGYtOCIpLndyaXRlKHNy
YykKcHJpbnQoIiAgUGFydCA1YyBhcHBsaWVkIHRvIiwgUEFUSCkK
B64C
base64 -d > "$TD" <<'B64D'
IyEvdXNyL2Jpbi9lbnYgcHl0aG9uMwoiIiIKUGFydCA1ZCBwYXRjaGVyIGZvciBuZXh1bS13ZWIv
bGliL2NjdHAtY2hhaW5zLnRzCgpBZGRzIHRoZSBmb3VyIG1haW5uZXQgY2hhaW5zIHByZXNlbnQg
aW4gVEVTVE5FVF9DSEFJTlMgYnV0IG1pc3NpbmcgZnJvbQpNQUlOTkVUX0NIQUlOUzogT1AgTWFp
bm5ldCwgQXZhbGFuY2hlLCBVbmljaGFpbiwgTW9uYWQuIFdpdGhvdXQgdGhlc2UsIG9uIGEKbWFp
bm5ldCBidWlsZCBjaGFpbkJ5S2V5KCkgcmV0dXJucyB1bmRlZmluZWQgZm9yIHRob3NlIGtleXMs
IHdoaWNoIGdyZXlzIG91dCB0aGUKRmFzdCB0b2dnbGUgYW5kIGJsYW5rcyB0aGUgcXVvdGUgcGFu
ZWwgKHRoZSBzeW1wdG9tIHJlcG9ydGVkKS4KCkFsbCBVU0RDIGFkZHJlc3NlcyBhbmQgZG9tYWlu
cyB2ZXJpZmllZCBhZ2FpbnN0IENpcmNsZSdzIGNhbm9uaWNhbAp1c2RjLWNvbnRyYWN0LWFkZHJl
c3NlcyBwYWdlIGFuZCBzdXBwb3J0ZWQtZG9tYWlucyB0YWJsZS4KCklkZW1wb3RlbnQgdmlhIF9f
TkVYVU1fTUFJTk5FVF9DSEFJTlNfXy4gRXhhY3QtYW5jaG9yOyBhYm9ydHMgY2xlYW4gb24gZHJp
ZnQuCiIiIgppbXBvcnQgc3lzLCBpbwpQQVRIID0gc3lzLmFyZ3ZbMV0gaWYgbGVuKHN5cy5hcmd2
KSA+IDEgZWxzZSAibmV4dW0td2ViL2xpYi9jY3RwLWNoYWlucy50cyIKTUFSS0VSID0gIl9fTkVY
VU1fTUFJTk5FVF9DSEFJTlNfXyIKc3JjID0gaW8ub3BlbihQQVRILCBlbmNvZGluZz0idXRmLTgi
KS5yZWFkKCkKaWYgTUFSS0VSIGluIHNyYzoKICAgIHByaW50KCIgIFBhcnQgNWQgYWxyZWFkeSBh
cHBsaWVkIC0gbm90aGluZyB0byBkby4iKQogICAgc3lzLmV4aXQoMCkKCiMgQW5jaG9yOiB0aGUg
cG9seWdvbiBtYWlubmV0IGVudHJ5IGlzIHRoZSBsYXN0IG9uZSBiZWZvcmUgdGhlIGNsb3Npbmcg
XS4KT0xEID0gIiIiICB7CiAgICBrZXk6ICdwb2x5Z29uJywgbmFtZTogJ1BvbHlnb24nLCBkb21h
aW46IDcsIGNoYWluSWQ6IDEzNywKICAgIHVzZGM6ICcweDNjNDk5YzU0MmNFRjVFMzgxMWUxMTky
Y2U3MGQ4Y0MwM2Q1YzMzNTknLAogICAgcnBjVXJsOiAgcHJvY2Vzcy5lbnYuTkVYVF9QVUJMSUNf
UE9MWUdPTl9SUENfVVJMID8/ICdodHRwczovL3BvbHlnb24tcnBjLmNvbScsCiAgICBleHBsb3Jl
cjogJ2h0dHBzOi8vcG9seWdvbnNjYW4uY29tJywKICB9LApdIiIiCgpORVcgPSAiIiIgIHsKICAg
IGtleTogJ3BvbHlnb24nLCBuYW1lOiAnUG9seWdvbicsIGRvbWFpbjogNywgY2hhaW5JZDogMTM3
LAogICAgdXNkYzogJzB4M2M0OTljNTQyY0VGNUUzODExZTExOTJjZTcwZDhjQzAzZDVjMzM1OScs
CiAgICBycGNVcmw6ICBwcm9jZXNzLmVudi5ORVhUX1BVQkxJQ19QT0xZR09OX1JQQ19VUkwgPz8g
J2h0dHBzOi8vcG9seWdvbi1ycGMuY29tJywKICAgIGV4cGxvcmVyOiAnaHR0cHM6Ly9wb2x5Z29u
c2Nhbi5jb20nLAogIH0sCiAgLy8gX19ORVhVTV9NQUlOTkVUX0NIQUlOU19fIChwYXJ0NSkgYWRk
cmVzc2VzIHZlcmlmaWVkIGFnYWluc3QgQ2lyY2xlJ3MKICAvLyBjYW5vbmljYWwgVVNEQyBjb250
cmFjdCArIHN1cHBvcnRlZC1kb21haW5zIHBhZ2VzLgogIHsKICAgIGtleTogJ29wdGltaXNtJywg
bmFtZTogJ09QIE1haW5uZXQnLCBkb21haW46IDIsIGNoYWluSWQ6IDEwLAogICAgdXNkYzogJzB4
MGIyQzYzOWM1MzM4MTNmNEFhOUQ3ODM3Q0FmNjI2NTNkMDk3RmY4NScsCiAgICBycGNVcmw6ICBw
cm9jZXNzLmVudi5ORVhUX1BVQkxJQ19PUF9SUENfVVJMID8/ICdodHRwczovL21haW5uZXQub3B0
aW1pc20uaW8nLAogICAgZXhwbG9yZXI6ICdodHRwczovL29wdGltaXN0aWMuZXRoZXJzY2FuLmlv
JywKICB9LAogIHsKICAgIGtleTogJ2F2YWxhbmNoZScsIG5hbWU6ICdBdmFsYW5jaGUnLCBkb21h
aW46IDEsIGNoYWluSWQ6IDQzMTE0LAogICAgdXNkYzogJzB4Qjk3RUY5RWY4NzM0QzcxOTA0RDgw
MDJGOGI2QmM2NkRkOWM0OGE2RScsCiAgICBycGNVcmw6ICBwcm9jZXNzLmVudi5ORVhUX1BVQkxJ
Q19BVkFYX1JQQ19VUkwgPz8gJ2h0dHBzOi8vYXBpLmF2YXgubmV0d29yay9leHQvYmMvQy9ycGMn
LAogICAgZXhwbG9yZXI6ICdodHRwczovL3Nub3d0cmFjZS5pbycsCiAgfSwKICB7CiAgICBrZXk6
ICd1bmljaGFpbicsIG5hbWU6ICdVbmljaGFpbicsIGRvbWFpbjogMTAsIGNoYWluSWQ6IDEzMCwK
ICAgIHVzZGM6ICcweDA3OEQ3ODJiNzYwNDc0YTM2MWREQTBBRjM4MzkyOTBiMEVGNTdBRDYnLAog
ICAgcnBjVXJsOiAgcHJvY2Vzcy5lbnYuTkVYVF9QVUJMSUNfVU5JQ0hBSU5fUlBDX1VSTCA/PyAn
aHR0cHM6Ly9tYWlubmV0LnVuaWNoYWluLm9yZycsCiAgICBleHBsb3JlcjogJ2h0dHBzOi8vdW5p
c2Nhbi54eXonLAogIH0sCiAgewogICAga2V5OiAnbW9uYWQnLCBuYW1lOiAnTW9uYWQnLCBkb21h
aW46IDE1LCBjaGFpbklkOiAxNDMsCiAgICB1c2RjOiAnMHg3NTQ3MDRCYzA1OUY4QzY3MDEyZkVk
NjlCQzhBMzI3YTVhYWZiNjAzJywKICAgIHJwY1VybDogIHByb2Nlc3MuZW52Lk5FWFRfUFVCTElD
X01PTkFEX1JQQ19VUkwgPz8gJycsCiAgICBleHBsb3JlcjogJ2h0dHBzOi8vbW9uYWRleHBsb3Jl
ci5jb20nLAogIH0sCl0iIiIKCm4gPSBzcmMuY291bnQoT0xEKQppZiBuICE9IDE6CiAgICBwcmlu
dChmIkVSUk9SOiBNQUlOTkVUX0NIQUlOUyBwb2x5Z29uIGFuY2hvciBtYXRjaGVkIHtufSB0aW1l
cy4gQWJvcnRpbmcuIikKICAgIHN5cy5leGl0KDIpCnNyYyA9IHNyYy5yZXBsYWNlKE9MRCwgTkVX
KQppby5vcGVuKFBBVEgsICJ3IiwgZW5jb2Rpbmc9InV0Zi04Iikud3JpdGUoc3JjKQpwcmludCgi
ICBQYXJ0IDVkIGFwcGxpZWQgdG8iLCBQQVRIKQo=
B64D

verify "$TA" "$A_SHA"; verify "$TB" "$B_SHA"; verify "$TC" "$C_SHA"; verify "$TD" "$D_SHA"
log "All four patchers verified."

apply(){ # $1 marker  $2 file  $3 patcher-tmp  $4 backup-name
  if grep -qF "$1" "$2"; then log "$(basename "$2"): already patched - skipping."; return; fi
  cp "$2" "$BACKUP_DIR/$4"
  python3 "$3" "$2" || { cp "$BACKUP_DIR/$4" "$2"; die "Patch failed on $2; restored."; }
  grep -qF "$1" "$2" || { cp "$BACKUP_DIR/$4" "$2"; die "Post-write check failed on $2; restored."; }
  log "Patched $2"
}

apply "$M_A" "$API_BRIDGE" "$TA" "bridge.ts"
apply "$M_B" "$CLIENT"     "$TB" "cctp-client.ts"
apply "$M_C" "$PREVIEW"    "$TC" "useQuotePreview.ts"
apply "$M_D" "$CHAINS"     "$TD" "cctp-chains.ts"

# ------------------------------------------------------------- deploy gate --
if [ "$FLAG" = "--no-deploy" ]; then
  log "--no-deploy: applied only. Review, then rerun without the flag to ship."
  exit 0
fi

log ""
log "=== Deploy gate: typecheck API + web, build web, then commit + push ==="
if [ -d nexum-api/node_modules ]; then
  ( cd nexum-api && npx tsc --noEmit ) || die "API tsc failed - not committing."
  log "API tsc clean."
else
  log "Skipping API tsc (nexum-api/node_modules not installed). Run 'npm ci' in nexum-api to enable this check."
fi
( cd nexum-web && rm -rf .next && npx tsc --noEmit ) || die "web tsc failed - not committing."
log "web tsc clean."
( cd nexum-web && npm run build ) || die "web build failed - not committing."
log "web build clean."

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "Not a git work tree; files applied, commit manually."
REMOTE="$(git remote | head -1 || true)"; [ -n "$REMOTE" ] || die "No git remote; commit/push manually."
BRANCH="$(git rev-parse --abbrev-ref HEAD)"
git add -A
if git diff --cached --quiet; then log "Nothing to commit."; exit 0; fi
log "Committing on '$BRANCH' -> '$REMOTE'..."
git commit -m "$COMMIT_MSG"
git push "$REMOTE" "$BRANCH"
log ""
log "Pushed Part 5. Fast should now show for Base/Arbitrum/OP/Unichain with live fees."
log "NOTE: set CCTP_ENV=mainnet on the API in production so the proxy uses the mainnet Iris host."
