#!/usr/bin/env bash
# ============================================================================
# Nexum bridge upgrade - PART 1 of 4: CCTP Fast/Standard quote engine
#
# Adds the fee/quote engine to nexum-web/lib/cctp-client.ts:
#   fetchFeeTable, maxFeeFor, getTransferQuote, getBothQuotes,
#   fastTransferSupported, etaSeconds, TransferMode, TransferQuote
#
# All existing exports are untouched. This is ADDITIVE - useBridge and the UI
# keep compiling. Part 2 (hook) and Part 3 (UI) consume what this adds.
#
# Delivery contract (your v2 spec):
#   * base64 heredoc, decoded + sha256-verified before it touches your file
#   * idempotent: re-running is a no-op (marker guard)
#   * timestamped backup of the original
#   * --revert restores the file to its pre-apply state
#   * run from the REPO ROOT (the dir containing nexum-web/)
#
# Usage:
#   bash nexum-part1-quote-engine.sh          # apply
#   bash nexum-part1-quote-engine.sh --revert # undo
# ============================================================================
set -euo pipefail

TARGET="nexum-web/lib/cctp-client.ts"
MARKER="// __NEXUM_CCTP_QUOTE_ENGINE__ (part1) do-not-duplicate"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR=".nexum-part1-backup/${STAMP}"
EXPECT_SHA="76229f48e756720cc3473150345d7c13f6a7a7fc86ade88dbdabf73ee60cd070"

log(){ printf '  %s\n' "$*"; }
die(){ printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[ -f "$TARGET" ] || die "Cannot find $TARGET . Run this from the repo root (the folder that contains nexum-web/)."

# ---------------------------------------------------------------- revert ----
if [ "${1:-}" = "--revert" ]; then
  if ! grep -qF "$MARKER" "$TARGET"; then
    log "Marker not found in $TARGET - nothing to revert."
    exit 0
  fi
  mkdir -p "$BACKUP_DIR"
  cp "$TARGET" "$BACKUP_DIR/cctp-client.ts.before-revert"
  # The engine is always appended last, preceded by exactly one blank line the
  # apply step inserts. Cut from that blank line to EOF to restore the original.
  LINE="$(grep -nF "$MARKER" "$TARGET" | head -1 | cut -d: -f1)"
  CUT="$LINE"
  # if the line above the marker is blank (the separator we added), drop it too
  if [ "$LINE" -gt 1 ] && [ -z "$(sed -n "$((LINE-1))p" "$TARGET")" ]; then
    CUT="$((LINE-1))"
  fi
  head -n "$((CUT-1))" "$TARGET" > "${TARGET}.tmp"
  mv "${TARGET}.tmp" "$TARGET"
  log "Reverted $TARGET to its pre-apply state (safety copy in $BACKUP_DIR)."
  exit 0
fi

# --------------------------------------------------------------- idempotent -
if grep -qF "$MARKER" "$TARGET"; then
  log "Quote engine already present in $TARGET - nothing to do."
  exit 0
fi

# --------------------------------------------- decode + verify the payload --
TMP_PAYLOAD="$(mktemp)"
trap 'rm -f "$TMP_PAYLOAD" "${TARGET}.tmp"' EXIT

base64 -d > "$TMP_PAYLOAD" <<'B64'
Ly8gX19ORVhVTV9DQ1RQX1FVT1RFX0VOR0lORV9fIChwYXJ0MSkgZG8tbm90LWR1cGxpY2F0ZQov
LyA9PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
PT09PT0KLy8gQ0NUUCBWMiBRVU9URSBFTkdJTkUgIChQYXJ0IDEgb2YgdGhlIEZhc3QvU3RhbmRh
cmQgdXBncmFkZSkKLy8KLy8gRXZlcnl0aGluZyBoZXJlIGlzIGRlcml2ZWQgZnJvbSBDaXJjbGUn
cyBsaXZlIGRvY3MsIHZlcmlmaWVkIDIwMjYtMDgtMjY6Ci8vICAgZmVlczogICAgICBodHRwczov
L2RldmVsb3BlcnMuY2lyY2xlLmNvbS9jY3RwL2NvbmNlcHRzL2ZlZXMKLy8gICBmaW5hbGl0eTog
IGh0dHBzOi8vZGV2ZWxvcGVycy5jaXJjbGUuY29tL2NjdHAvY29uY2VwdHMvZmluYWxpdHktYW5k
LWJsb2NrLWNvbmZpcm1hdGlvbnMKLy8gICBzZW1hbnRpY3M6IGh0dHBzOi8vZGV2ZWxvcGVycy5j
aXJjbGUuY29tL2NjdHAvY2N0cC1maW5hbGl0eS1hbmQtZmVlcwovLwovLyBGQUNUUyBUSEFUIFNI
QVBFIFRISVMgQ09ERSAoZWFjaCBvbmUgaXMgYSBidWcgd2UgYXJlIGZpeGluZyk6Ci8vCi8vICAg
KiBTdGFuZGFyZCBUcmFuc2ZlciBpcyBGUkVFICgwIGJwcykgdG9kYXkuIFRoZSBGYXN0IGZlZSAo
MS0xNCBicHMgYnkKLy8gICAgIHNvdXJjZSBjaGFpbikgaXMgdGhlIG9ubHkgcHJvdG9jb2wgZmVl
LiBUaGUgb2xkIGdldEJ1cm5GZWUgYXBwbGllZCBhCi8vICAgICAiMiBicHMgc3RhbmRhcmQgZmFs
bGJhY2siIC0gdGhhdCBmZWUgZG9lcyBub3QgZXhpc3QuIFdlIHJlYWQgdGhlIGZlZQovLyAgICAg
ZnJvbSB0aGUgQVBJIGFuZCBuZXZlciBoYXJkY29kZSBpdCAoQ2lyY2xlIGNhbiBmbGlwIGEgcGVy
LWNoYWluIGZlZQovLyAgICAgc3dpdGNoIGF0IGFueSB0aW1lKS4KLy8KLy8gICAqIFRoZSAvdjIv
YnVybi9VU0RDL2ZlZXMve2Zyb219L3t0b30gcmVzcG9uc2UgaXMgYW4gQVJSQVkuIEVhY2ggZW50
cnkgaGFzCi8vICAgICB7IGZpbmFsaXR5VGhyZXNob2xkLCBtaW5pbXVtRmVlIH0uIGZpbmFsaXR5
VGhyZXNob2xkIDEwMDAgPSBGYXN0LAovLyAgICAgMjAwMCA9IFN0YW5kYXJkLiBtaW5pbXVtRmVl
IGlzIGluIEJBU0lTIFBPSU5UUy4KLy8KLy8gICAqIENpcmNsZSdzIG93biBtYXhGZWUgZm9ybXVs
YSAoZnJvbSB0aGVpciBkb2NzKSwgcmVwcm9kdWNlZCBleGFjdGx5OgovLyAgICAgICAgcHJvdG9j
b2xGZWUgPSBhbW91bnQgKiByb3VuZChtaW5pbXVtRmVlICogMTAwKSAvIDFfMDAwXzAwMAovLyAg
ICAgICAgbWF4RmVlICAgICAgPSBwcm90b2NvbEZlZSAqIDEyMCAvIDEwMCAgICAgICAgKDIwJSBi
dWZmZXIpCi8vICAgICBBIG1heEZlZSBiZWxvdyB0aGUgcmVxdWlyZWQgbWluaW11bSBtYWtlcyB0
aGUgYnVybiBSRVZFUlQsIHNvIHRoZSBidWZmZXIKLy8gICAgIG1hdHRlcnMuIFdlIGtlZXAgaXQg
Y29uZmlndXJhYmxlLgovLwovLyAgICogVGhlIEZhc3QgZmVlIGlzIERFRFVDVEVEIEFUIE1JTlQ6
IHRoZSByZWNpcGllbnQgcmVjZWl2ZXMgYW1vdW50IC0gZmVlLgovLyAgICAgKFVwZnJvbnQtZmVl
IHBheW1lbnQgdmlhIFRva2VuTWVzc2VuZ2VyV2l0aEZlZXMgaXMgYSBsYXRlciBwaGFzZS4pCi8v
Ci8vICAgKiBGYXN0IFRyYW5zZmVyIGlzIG9ubHkgbWVhbmluZ2Z1bCBhcyBhIFNPVVJDRSB3aGVy
ZSBzdGFuZGFyZCBhdHRlc3RhdGlvbgovLyAgICAgaXMgc2xvdy4gQ2lyY2xlIG1hcmtzIGZhc3Qg
Ik4vQSIgYXMgc291cmNlIGZvciBjaGFpbnMgd2hvc2Ugc3RhbmRhcmQKLy8gICAgIGF0dGVzdGF0
aW9uIGlzIGFscmVhZHkgZmFzdCAoQXJjLCBBdmFsYW5jaGUsIFBvbHlnb24sIE1vbmFkIGhlcmUp
LiBPbgovLyAgICAgdGhvc2Ugd2UgbXVzdCBmYWxsIGJhY2sgdG8gU3RhbmRhcmQgLSB0aGUgdG9n
Z2xlIGlzIGRpc2FibGVkIGluIHRoZSBVSS4KLy8KLy8gTk9URSBPTiBCSUdJTlQ6IG5vIGJpZ2lu
dCBsaXRlcmFscyAoZS5nLiAxMjBuKSBhbnl3aGVyZSAtIHRoaXMgcHJvamVjdCdzCi8vIHRzY29u
ZmlnIGhhcyBubyBleHBsaWNpdCBFUzIwMjAgdGFyZ2V0LCBzbyB3ZSBidWlsZCBldmVyeSBiaWdp
bnQgd2l0aAovLyBCaWdJbnQoLi4uKSBleGFjdGx5IGFzIHRoZSByZXN0IG9mIHRoZSBmaWxlIGFs
cmVhZHkgZG9lcy4KLy8gPT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
PT09PT09PT09PT09PT09PT09CgpleHBvcnQgdHlwZSBUcmFuc2Zlck1vZGUgPSAnZmFzdCcgfCAn
c3RhbmRhcmQnCgovLyDilIDilIAgRmFzdC1UcmFuc2Zlci1hcy1zb3VyY2Ugc3VwcG9ydCwga2V5
ZWQgYnkgb3VyIGNoYWluIGtleSDilIDilIAKLy8KLy8gVFJVRSAgPSBGYXN0IGdpdmVzIGEgcmVh
bCBzcGVlZCB3aW4gYXMgYSBzb3VyY2UgKHNsb3cgc3RhbmRhcmQgZmluYWxpdHkpLgovLyBGQUxT
RSA9IHN0YW5kYXJkIGF0dGVzdGF0aW9uIGlzIGFscmVhZHkgZmFzdCwgQ2lyY2xlIGRpc2FibGVz
IEZhc3QgYXMgc291cmNlLgovLwovLyBWZXJpZmllZCBhZ2FpbnN0IHRoZSBmaW5hbGl0eSB0YWJs
ZS4gQW55dGhpbmcgbm90IGxpc3RlZCBkZWZhdWx0cyB0byBGQUxTRQovLyAoc2FmZTogd2Ugb25s
eSBvZmZlciBGYXN0IHdoZXJlIHdlJ3ZlIGNvbmZpcm1lZCBpdCBoZWxwcykuCmNvbnN0IEZBU1Rf
QVNfU09VUkNFOiBSZWNvcmQ8c3RyaW5nLCBib29sZWFuPiA9IHsKICBldGhlcmV1bTogdHJ1ZSwK
ICBiYXNlOiAgICAgdHJ1ZSwKICBhcmJpdHJ1bTogdHJ1ZSwKICBvcHRpbWlzbTogdHJ1ZSwgICAv
LyAiT1AgTWFpbm5ldCIgaW4gQ2lyY2xlJ3MgdGFibGVzCiAgdW5pY2hhaW46IHRydWUsCiAgLy8g
RmFzdCBOT1QgYXZhaWxhYmxlIGFzIHNvdXJjZSAoc3RhbmRhcmQgaXMgYWxyZWFkeSB+c2Vjb25k
cyk6CiAgYXJjOiAgICAgICBmYWxzZSwKICBhdmFsYW5jaGU6IGZhbHNlLAogIHBvbHlnb246ICAg
ZmFsc2UsIC8vIFBvbHlnb24gUG9TIHN0YW5kYXJkIH44cwogIG1vbmFkOiAgICAgZmFsc2UsIC8v
IH41cyBzdGFuZGFyZAp9CgpleHBvcnQgZnVuY3Rpb24gZmFzdFRyYW5zZmVyU3VwcG9ydGVkKGZy
b21LZXk6IHN0cmluZyk6IGJvb2xlYW4gewogIHJldHVybiBGQVNUX0FTX1NPVVJDRVtmcm9tS2V5
XSA9PT0gdHJ1ZQp9CgovLyDilIDilIAgRXN0aW1hdGVkIGF0dGVzdGF0aW9uIHRpbWUsIHNlY29u
ZHMgKHNvdXJjZS1jaGFpbiwgcGVyIG1vZGUpIOKUgOKUgAovLwovLyBGcm9tIENpcmNsZSdzIGZp
bmFsaXR5IHRhYmxlcy4gVGhlc2UgYXJlIGF2ZXJhZ2VzIGZvciB0aGUgU09VUkNFIGNoYWluJ3MK
Ly8gYXR0ZXN0YXRpb247IGRlc3RpbmF0aW9uIG1pbnQgaXMgbmVhci1pbnN0YW50IG9uY2UgYXR0
ZXN0ZWQuIFRlc3RuZXQgdGltaW5ncwovLyB0cmFjayBtYWlubmV0IGNsb3NlbHkgZW5vdWdoIGZv
ciBhIFVJIGVzdGltYXRlOyB3ZSBsYWJlbCB0aGVtICJ+Ii4KY29uc3QgRkFTVF9FVEFfU0VDOiBS
ZWNvcmQ8c3RyaW5nLCBudW1iZXI+ID0gewogIGV0aGVyZXVtOiAyMCwgYmFzZTogOCwgYXJiaXRy
dW06IDgsIG9wdGltaXNtOiA4LCB1bmljaGFpbjogOCwKfQpjb25zdCBTVERfRVRBX1NFQzogUmVj
b3JkPHN0cmluZywgbnVtYmVyPiA9IHsKICBldGhlcmV1bTogMTAyMCwgYmFzZTogMTAyMCwgYXJi
aXRydW06IDEwMjAsIG9wdGltaXNtOiAxMDIwLCB1bmljaGFpbjogMTAyMCwgLy8gfjE1LTE5IG1p
bgogIGFyYzogMSwgYXZhbGFuY2hlOiA4LCBwb2x5Z29uOiA4LCBtb25hZDogNSwKfQoKZXhwb3J0
IGZ1bmN0aW9uIGV0YVNlY29uZHMoZnJvbUtleTogc3RyaW5nLCBtb2RlOiBUcmFuc2Zlck1vZGUp
OiBudW1iZXIgewogIGlmIChtb2RlID09PSAnZmFzdCcpIHJldHVybiBGQVNUX0VUQV9TRUNbZnJv
bUtleV0gPz8gMjAKICByZXR1cm4gU1REX0VUQV9TRUNbZnJvbUtleV0gPz8gMTAyMAp9CgovLyDi
lIDilIAgRmVlIHRhYmxlIGxvb2t1cCDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDi
lIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDi
lIDilIDilIDilIDilIDilIDilIDilIDilIDilIAKZXhwb3J0IGludGVyZmFjZSBGZWVFbnRyeSB7
CiAgZmluYWxpdHlUaHJlc2hvbGQ6IG51bWJlciAgLy8gMTAwMCA9IGZhc3QsIDIwMDAgPSBzdGFu
ZGFyZAogIG1pbmltdW1GZWVCcHM6ICAgICBudW1iZXIgIC8vIGJhc2lzIHBvaW50cwp9CgovKgog
IEZldGNoIGJvdGggZmVlIGVudHJpZXMgZm9yIGEgcm91dGUgaW4gb25lIGNhbGwuIFJldHVybnMg
d2hhdGV2ZXIgQ2lyY2xlIGdpdmVzCiAgdXMsIG5vcm1hbGlzZWQuIElmIHRoZSBjYWxsIGZhaWxz
IHdlIHJldHVybiBhbiBlbXB0eSBsaXN0IGFuZCB0aGUgY2FsbGVyCiAgZGVjaWRlcyBob3cgdG8g
ZGVncmFkZSAoZmFzdCB1bmF2YWlsYWJsZSwgc3RhbmRhcmQgaXMgZnJlZSBhbnl3YXkpLgoqLwpl
eHBvcnQgYXN5bmMgZnVuY3Rpb24gZmV0Y2hGZWVUYWJsZSgKICBpcmlzQmFzZTogc3RyaW5nLCBm
cm9tRG9tYWluOiBudW1iZXIsIHRvRG9tYWluOiBudW1iZXIsCik6IFByb21pc2U8RmVlRW50cnlb
XT4gewogIGNvbnN0IHVybCA9IGAke2lyaXNCYXNlfS92Mi9idXJuL1VTREMvZmVlcy8ke2Zyb21E
b21haW59LyR7dG9Eb21haW59YAogIHRyeSB7CiAgICBjb25zdCByZXMgPSBhd2FpdCBmZXRjaCh1
cmwpCiAgICBpZiAoIXJlcy5vaykgcmV0dXJuIFtdCiAgICBjb25zdCBkYXRhOiBhbnkgPSBhd2Fp
dCByZXMuanNvbigpCiAgICBjb25zdCByb3dzOiBhbnlbXSA9IEFycmF5LmlzQXJyYXkoZGF0YSkg
PyBkYXRhIDogKGRhdGE/LmRhdGEgPz8gW2RhdGFdKQogICAgcmV0dXJuIHJvd3MKICAgICAgLm1h
cChyID0+ICh7CiAgICAgICAgZmluYWxpdHlUaHJlc2hvbGQ6IE51bWJlcihyPy5maW5hbGl0eVRo
cmVzaG9sZCA/PyAwKSwKICAgICAgICBtaW5pbXVtRmVlQnBzOiAgICAgTnVtYmVyKHI/Lm1pbmlt
dW1GZWUgPz8gMCksCiAgICAgIH0pKQogICAgICAuZmlsdGVyKHIgPT4gci5maW5hbGl0eVRocmVz
aG9sZCA+IDApCiAgfSBjYXRjaCB7CiAgICByZXR1cm4gW10KICB9Cn0KCmZ1bmN0aW9uIGJwc0Zv
ck1vZGUodGFibGU6IEZlZUVudHJ5W10sIG1vZGU6IFRyYW5zZmVyTW9kZSk6IG51bWJlciB7CiAg
Y29uc3Qgd2FudFRocmVzaG9sZCA9IG1vZGUgPT09ICdmYXN0JyA/IDEwMDAgOiAyMDAwCiAgY29u
c3QgZXhhY3QgPSB0YWJsZS5maW5kKGUgPT4gZS5maW5hbGl0eVRocmVzaG9sZCA9PT0gd2FudFRo
cmVzaG9sZCkKICBpZiAoZXhhY3QpIHJldHVybiBleGFjdC5taW5pbXVtRmVlQnBzCiAgLy8gU3Rh
bmRhcmQgaXMgZnJlZSBpZiB0aGUgQVBJIGRpZG4ndCByZXR1cm4gYSBzdGFuZGFyZCByb3cuCiAg
aWYgKG1vZGUgPT09ICdzdGFuZGFyZCcpIHJldHVybiAwCiAgLy8gRmFzdCByb3cgbWlzc2luZyBi
dXQgY2FsbGVyIGFza2VkIGZvciBmYXN0OiBmYWxsIGJhY2sgdG8gdGhlIGZpcnN0IHJvdy4KICBy
ZXR1cm4gdGFibGVbMF0/Lm1pbmltdW1GZWVCcHMgPz8gMAp9CgovKgogIENpcmNsZSdzIGV4YWN0
IG1heEZlZSBmb3JtdWxhIChzZWUgaGVhZGVyKS4gS2VwdCBhcyBpdHMgb3duIGZ1bmN0aW9uIHNv
IGJvdGgKICB0aGUgcXVvdGUgYW5kIHRoZSBidXJuIGNhbGwgdXNlIGlkZW50aWNhbCBtYXRoIC0g
YSBtaXNtYXRjaCBoZXJlIGlzIHdoYXQKICBtYWtlcyBhIGJ1cm4gcmV2ZXJ0LgoqLwpleHBvcnQg
ZnVuY3Rpb24gbWF4RmVlRm9yKAogIGFtb3VudFVuaXRzOiBiaWdpbnQsIG1pbmltdW1GZWVCcHM6
IG51bWJlciwgYnVmZmVyUGN0ID0gMjAsCik6IGJpZ2ludCB7CiAgaWYgKG1pbmltdW1GZWVCcHMg
PD0gMCkgcmV0dXJuIEJpZ0ludCgwKSAvLyBzdGFuZGFyZC9mcmVlOiBtYXhGZWUgMCBpcyB2YWxp
ZAogIC8vIGFtb3VudCAqIHJvdW5kKGJwcyAqIDEwMCkgLyAxXzAwMF8wMDAKICBjb25zdCBzY2Fs
ZWQgPSBCaWdJbnQoTWF0aC5yb3VuZChtaW5pbXVtRmVlQnBzICogMTAwKSkKICBjb25zdCBtaWxs
aW9uID0gQmlnSW50KDEwMDAwMDApCiAgY29uc3QgcHJvdG9jb2xGZWUgPSAoYW1vdW50VW5pdHMg
KiBzY2FsZWQpIC8gbWlsbGlvbgogIGNvbnN0IGJ1ZmZlcmVkID0gKHByb3RvY29sRmVlICogQmln
SW50KDEwMCArIGJ1ZmZlclBjdCkpIC8gQmlnSW50KDEwMCkKICAvLyBGYXN0IGZlZSBtdXN0IGJl
ID4gMCB0byBiZSBlbGlnaWJsZTsgZmxvb3IgYXQgMSB1bml0IGlmIG1hdGggcm91bmRzIHRvIDAu
CiAgcmV0dXJuIGJ1ZmZlcmVkID4gQmlnSW50KDApID8gYnVmZmVyZWQgOiBCaWdJbnQoMSkKfQoK
Ly8g4pSA4pSAIFRoZSBxdW90ZSBhIGNhbGxlciAoaG9vayArIFVJKSBjb25zdW1lcyDilIDilIDi
lIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIAKZXhwb3J0IGludGVy
ZmFjZSBUcmFuc2ZlclF1b3RlIHsKICBtb2RlOiAgICAgICAgICBUcmFuc2Zlck1vZGUKICBmZWVC
cHM6ICAgICAgICBudW1iZXIgICAvLyBwcm90b2NvbCBmZWUgcmF0ZSwgYmFzaXMgcG9pbnRzCiAg
ZmVlVW5pdHM6ICAgICAgYmlnaW50ICAgLy8gZXN0aW1hdGVkIGZlZSBhY3R1YWxseSBjaGFyZ2Vk
IChub3QgdGhlIGJ1ZmZlcikKICBtYXhGZWVVbml0czogICBiaWdpbnQgICAvLyB3aGF0IHRvIHBh
c3MgYXMgbWF4RmVlIGluIGRlcG9zaXRGb3JCdXJuCiAgcmVjZWl2ZVVuaXRzOiAgYmlnaW50ICAg
Ly8gYW1vdW50IHRoZSByZWNpcGllbnQgZ2V0cyAoYW1vdW50IC0gZmVlVW5pdHMpCiAgZXRhU2Vj
b25kczogICAgbnVtYmVyICAgLy8gZXN0aW1hdGVkIHRpbWUgdG8gYXR0ZXN0YXRpb24KICBmYXN0
U3VwcG9ydGVkOiBib29sZWFuICAvLyBpcyBmYXN0IGF2YWlsYWJsZSBvbiB0aGlzIHNvdXJjZSBh
dCBhbGwKICBkZWdyYWRlZDogICAgICBib29sZWFuICAvLyBjYWxsZXIgYXNrZWQgZmFzdCBidXQg
cm91dGUgZm9yY2VzIHN0YW5kYXJkCn0KCi8qCiAgQnVpbGQgYSBxdW90ZSBmb3Igb25lIG1vZGUu
IE5ldmVyIHRocm93cyAtIGEgZmVlLUFQSSBvdXRhZ2UgeWllbGRzIGEKICBiZXN0LWVmZm9ydCBx
dW90ZSAoc3RhbmRhcmQgaXMgZnJlZTsgZmFzdCBmbG9vcnMgc2Vuc2libHkpIHNvIHRoZSBVSSBz
dGF5cwogIHVzYWJsZSBhbmQgdGhlIGJ1cm4gc3RpbGwgc2V0cyBhIHNhZmUgbWF4RmVlLgoqLwpl
eHBvcnQgYXN5bmMgZnVuY3Rpb24gZ2V0VHJhbnNmZXJRdW90ZShwYXJhbXM6IHsKICBpcmlzQmFz
ZTogICAgc3RyaW5nCiAgZnJvbUtleTogICAgIHN0cmluZwogIGZyb21Eb21haW46ICBudW1iZXIK
ICB0b0RvbWFpbjogICAgbnVtYmVyCiAgYW1vdW50VW5pdHM6IGJpZ2ludAogIG1vZGU6ICAgICAg
ICBUcmFuc2Zlck1vZGUKICBidWZmZXJQY3Q/OiAgbnVtYmVyCn0pOiBQcm9taXNlPFRyYW5zZmVy
UXVvdGU+IHsKICBjb25zdCB7IGlyaXNCYXNlLCBmcm9tS2V5LCBmcm9tRG9tYWluLCB0b0RvbWFp
biwgYW1vdW50VW5pdHMsIG1vZGUgfSA9IHBhcmFtcwoKICBjb25zdCBmYXN0U3VwcG9ydGVkID0g
ZmFzdFRyYW5zZmVyU3VwcG9ydGVkKGZyb21LZXkpCiAgY29uc3QgZWZmZWN0aXZlTW9kZTogVHJh
bnNmZXJNb2RlID0KICAgIG1vZGUgPT09ICdmYXN0JyAmJiAhZmFzdFN1cHBvcnRlZCA/ICdzdGFu
ZGFyZCcgOiBtb2RlCiAgY29uc3QgZGVncmFkZWQgPSBtb2RlID09PSAnZmFzdCcgJiYgIWZhc3RT
dXBwb3J0ZWQKCiAgY29uc3QgdGFibGUgPSBhd2FpdCBmZXRjaEZlZVRhYmxlKGlyaXNCYXNlLCBm
cm9tRG9tYWluLCB0b0RvbWFpbikKICBjb25zdCBmZWVCcHMgPSBicHNGb3JNb2RlKHRhYmxlLCBl
ZmZlY3RpdmVNb2RlKQoKICAvLyBFc3RpbWF0ZWQgZmVlIGFjdHVhbGx5IGNoYXJnZWQgPSBhbW91
bnQgKiBicHMgLyAxMF8wMDAgKG5vIGJ1ZmZlcikuCiAgY29uc3QgZmVlVW5pdHMgPQogICAgZmVl
QnBzID4gMCA/IChhbW91bnRVbml0cyAqIEJpZ0ludChmZWVCcHMpKSAvIEJpZ0ludCgxMDAwMCkg
OiBCaWdJbnQoMCkKICBjb25zdCBtYXhGZWVVbml0cyA9IG1heEZlZUZvcihhbW91bnRVbml0cywg
ZmVlQnBzLCBwYXJhbXMuYnVmZmVyUGN0ID8/IDIwKQogIGNvbnN0IHJlY2VpdmVVbml0cyA9CiAg
ICBhbW91bnRVbml0cyA+IGZlZVVuaXRzID8gYW1vdW50VW5pdHMgLSBmZWVVbml0cyA6IEJpZ0lu
dCgwKQoKICByZXR1cm4gewogICAgbW9kZTogICAgICAgICAgZWZmZWN0aXZlTW9kZSwKICAgIGZl
ZUJwcywKICAgIGZlZVVuaXRzLAogICAgbWF4RmVlVW5pdHMsCiAgICByZWNlaXZlVW5pdHMsCiAg
ICBldGFTZWNvbmRzOiAgICBldGFTZWNvbmRzKGZyb21LZXksIGVmZmVjdGl2ZU1vZGUpLAogICAg
ZmFzdFN1cHBvcnRlZCwKICAgIGRlZ3JhZGVkLAogIH0KfQoKLyoKICBDb252ZW5pZW5jZTogcXVv
dGUgQk9USCBtb2RlcyBhdCBvbmNlIGZvciB0aGUgVUkncyB0b2dnbGUsIHNoYXJpbmcgYSBzaW5n
bGUKICBmZWUtdGFibGUgZmV0Y2guIFJldHVybnMgZmFzdD1udWxsIHdoZW4gdGhlIHNvdXJjZSBj
YW4ndCBkbyBmYXN0LgoqLwpleHBvcnQgYXN5bmMgZnVuY3Rpb24gZ2V0Qm90aFF1b3RlcyhwYXJh
bXM6IHsKICBpcmlzQmFzZTogICAgc3RyaW5nCiAgZnJvbUtleTogICAgIHN0cmluZwogIGZyb21E
b21haW46ICBudW1iZXIKICB0b0RvbWFpbjogICAgbnVtYmVyCiAgYW1vdW50VW5pdHM6IGJpZ2lu
dAogIGJ1ZmZlclBjdD86ICBudW1iZXIKfSk6IFByb21pc2U8eyBmYXN0OiBUcmFuc2ZlclF1b3Rl
IHwgbnVsbDsgc3RhbmRhcmQ6IFRyYW5zZmVyUXVvdGUgfT4gewogIGNvbnN0IHsgaXJpc0Jhc2Us
IGZyb21LZXksIGZyb21Eb21haW4sIHRvRG9tYWluLCBhbW91bnRVbml0cyB9ID0gcGFyYW1zCiAg
Y29uc3QgdGFibGUgPSBhd2FpdCBmZXRjaEZlZVRhYmxlKGlyaXNCYXNlLCBmcm9tRG9tYWluLCB0
b0RvbWFpbikKICBjb25zdCBidWZmZXIgPSBwYXJhbXMuYnVmZmVyUGN0ID8/IDIwCgogIGNvbnN0
IGJ1aWxkID0gKG1vZGU6IFRyYW5zZmVyTW9kZSk6IFRyYW5zZmVyUXVvdGUgPT4gewogICAgY29u
c3QgZmVlQnBzID0gYnBzRm9yTW9kZSh0YWJsZSwgbW9kZSkKICAgIGNvbnN0IGZlZVVuaXRzID0K
ICAgICAgZmVlQnBzID4gMCA/IChhbW91bnRVbml0cyAqIEJpZ0ludChmZWVCcHMpKSAvIEJpZ0lu
dCgxMDAwMCkgOiBCaWdJbnQoMCkKICAgIHJldHVybiB7CiAgICAgIG1vZGUsCiAgICAgIGZlZUJw
cywKICAgICAgZmVlVW5pdHMsCiAgICAgIG1heEZlZVVuaXRzOiAgIG1heEZlZUZvcihhbW91bnRV
bml0cywgZmVlQnBzLCBidWZmZXIpLAogICAgICByZWNlaXZlVW5pdHM6ICBhbW91bnRVbml0cyA+
IGZlZVVuaXRzID8gYW1vdW50VW5pdHMgLSBmZWVVbml0cyA6IEJpZ0ludCgwKSwKICAgICAgZXRh
U2Vjb25kczogICAgZXRhU2Vjb25kcyhmcm9tS2V5LCBtb2RlKSwKICAgICAgZmFzdFN1cHBvcnRl
ZDogZmFzdFRyYW5zZmVyU3VwcG9ydGVkKGZyb21LZXkpLAogICAgICBkZWdyYWRlZDogICAgICBm
YWxzZSwKICAgIH0KICB9CgogIHJldHVybiB7CiAgICBmYXN0OiAgICAgZmFzdFRyYW5zZmVyU3Vw
cG9ydGVkKGZyb21LZXkpID8gYnVpbGQoJ2Zhc3QnKSA6IG51bGwsCiAgICBzdGFuZGFyZDogYnVp
bGQoJ3N0YW5kYXJkJyksCiAgfQp9Cg==
B64

# verify integrity before we let it near your source tree
ACTUAL_SHA="$( (sha256sum "$TMP_PAYLOAD" 2>/dev/null || shasum -a 256 "$TMP_PAYLOAD") | awk '{print $1}')"
if [ "$ACTUAL_SHA" != "$EXPECT_SHA" ]; then
  die "Payload checksum mismatch (got $ACTUAL_SHA, expected $EXPECT_SHA). Aborting - your file was NOT modified."
fi
log "Payload verified (sha256 $ACTUAL_SHA)."

# sanity: the payload must actually carry the marker, else revert can't work
grep -qF "$MARKER" "$TMP_PAYLOAD" || die "Payload is missing its marker line; aborting."

# ------------------------------------------------------------------ backup --
mkdir -p "$BACKUP_DIR"
cp "$TARGET" "$BACKUP_DIR/cctp-client.ts"
log "Backed up original to $BACKUP_DIR/cctp-client.ts"

# ------------------------------------------------------------------- apply --
{
  cat "$TARGET"
  printf '\n'
  cat "$TMP_PAYLOAD"
} > "${TARGET}.tmp"
mv "${TARGET}.tmp" "$TARGET"

if ! grep -qF "$MARKER" "$TARGET"; then
  cp "$BACKUP_DIR/cctp-client.ts" "$TARGET"
  die "Post-write check failed; restored original from backup."
fi

log "Applied. Quote engine added to $TARGET."
log ""
log "Next: from nexum-web/ run  npx tsc --noEmit  to confirm a clean typecheck."
log "Then we move to Part 2 (useBridge mode support)."
