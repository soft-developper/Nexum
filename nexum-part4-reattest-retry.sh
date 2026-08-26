#!/usr/bin/env bash
# ============================================================================
# Nexum bridge upgrade - PART 4 of 4: attestation-expiry + failed-mint retry
#
# Hardens the recovery flow so a stranded transfer can always be finished:
#   * fetchAttestation now surfaces expirationBlock (lib/cctp-client.ts)
#   * useCompleteBridge detects a failed/expired mint and runs ONE
#     reattest(nonce) -> re-poll -> re-mint cycle, with live progress notes,
#     instead of dead-ending on an expired 24h attestation
#   * 'nonce already used' is still treated as success (idempotent mint)
#   * adds a 'reattesting' step; corrects the old "never expire" comment
#
# Per Circle: an attestation only mints until its ~24h expirationBlock, but
# re-attestation has NO deadline while the burn exists. Minting is idempotent,
# so retrying can never double-mint.
#
# REQUIRES Parts 1-3.  (Uses the quote engine's file only as a co-resident;
# the real deps are fetchAttestation + reattest, which already exist.)
#
# Delivery contract (your v2 spec) + full deploy:
#   * both patchers base64 + sha256 verified before running
#   * exact-anchor edits; a drifted file aborts clean, never half-patched
#   * idempotent (__NEXUM_ATTEST_EXPIRY__ / __NEXUM_REATTEST_RETRY__)
#   * timestamped backups
#   * deploy GATE: rm -rf .next && npx tsc --noEmit && npm run build -> push
#   * --revert restores both files ; --no-deploy applies only
#
# Run from REPO ROOT (folder containing nexum-web/).
#   bash nexum-part4-reattest-retry.sh
#   bash nexum-part4-reattest-retry.sh --no-deploy
#   bash nexum-part4-reattest-retry.sh --revert
# ============================================================================
set -euo pipefail

CLIENT="nexum-web/lib/cctp-client.ts"
COMPLETE="nexum-web/hooks/useCompleteBridge.ts"
MARK_A="__NEXUM_ATTEST_EXPIRY__"
MARK_B="__NEXUM_REATTEST_RETRY__"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR=".nexum-part4-backup/${STAMP}"
A_SHA="d2f3d70868776eaa094fa17d28b114a8b1c51f391e35737005cfa07dd528d97b"
B_SHA="985e512a5437b44117b8f89e81e98453430c62a4a8650123a3001c3984959752"
COMMIT_MSG="feat(bridge): attestation-expiry reattest + failed-mint retry in recovery (Part 4)"

FLAG="${1:-}"
log(){ printf '  %s\n' "$*"; }
die(){ printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[ -f "$COMPLETE" ] || die "Cannot find $COMPLETE . Run from the repo root (folder containing nexum-web/)."

# ---------------------------------------------------------------- revert ----
if [ "$FLAG" = "--revert" ]; then
  LATEST="$(ls -1dt .nexum-part4-backup/*/ 2>/dev/null | head -1 || true)"
  [ -n "$LATEST" ] || die "No Part 4 backup found."
  [ -f "${LATEST}cctp-client.ts" ] && cp "${LATEST}cctp-client.ts" "$CLIENT" && log "Restored $CLIENT"
  [ -f "${LATEST}useCompleteBridge.ts" ] && cp "${LATEST}useCompleteBridge.ts" "$COMPLETE" && log "Restored $COMPLETE"
  log "Reverted Part 4."
  exit 0
fi

# ------------------------------------------ precondition: Parts 1-3 ---------
grep -qF "__NEXUM_CCTP_QUOTE_ENGINE__" "$CLIENT" || die "Part 1 not applied. Apply Parts 1-3 first."
grep -qF "__NEXUM_BRIDGE_MODE__" nexum-web/hooks/useBridge.ts || die "Part 2 not applied. Apply Parts 1-3 first."
grep -qF "__NEXUM_BRIDGE_MODE_UI__" nexum-web/components/bridge/BridgeCard.tsx || die "Part 3 not applied. Apply Parts 1-3 first."

mkdir -p "$BACKUP_DIR"
verify(){ local got; got="$( (sha256sum "$1" 2>/dev/null || shasum -a 256 "$1") | awk '{print $1}')"; [ "$got" = "$2" ] || die "Checksum mismatch for $1 (got $got). Nothing written."; }

TMP_A="$(mktemp /tmp/nexum-p4a.XXXXXX.py)"
TMP_B="$(mktemp /tmp/nexum-p4b.XXXXXX.py)"
trap 'rm -f "$TMP_A" "$TMP_B"' EXIT

base64 -d > "$TMP_A" <<'B64_A'
IyEvdXNyL2Jpbi9lbnYgcHl0aG9uMwoiIiIKUGFydCA0YSBwYXRjaGVyIGZvciBuZXh1bS13ZWIv
bGliL2NjdHAtY2xpZW50LnRzCgpTdXJmYWNlcyB0aGUgYXR0ZXN0YXRpb24ncyBleHBpcmF0aW9u
QmxvY2sgc28gdGhlIHJlY292ZXJ5IGZsb3cgY2FuIGRldGVjdCBhCnN0YWxlIGF0dGVzdGF0aW9u
IGJlZm9yZSBpdCB3YXN0ZXMgYSBtaW50IGF0dGVtcHQuIEZ1bGx5IGFkZGl0aXZlLgoKSWRlbXBv
dGVudCB2aWEgX19ORVhVTV9BVFRFU1RfRVhQSVJZX18uIEV4YWN0LWFuY2hvcjsgYWJvcnRzIGNs
ZWFuIG9uIGRyaWZ0LgoiIiIKaW1wb3J0IHN5cywgaW8KUEFUSCA9IHN5cy5hcmd2WzFdIGlmIGxl
bihzeXMuYXJndikgPiAxIGVsc2UgIm5leHVtLXdlYi9saWIvY2N0cC1jbGllbnQudHMiCk1BUktF
UiA9ICJfX05FWFVNX0FUVEVTVF9FWFBJUllfXyIKc3JjID0gaW8ub3BlbihQQVRILCBlbmNvZGlu
Zz0idXRmLTgiKS5yZWFkKCkKaWYgTUFSS0VSIGluIHNyYzoKICAgIHByaW50KCIgIFBhcnQgNGEg
YWxyZWFkeSBhcHBsaWVkIC0gbm90aGluZyB0byBkby4iKQogICAgc3lzLmV4aXQoMCkKCmVkaXRz
ID0gW10KCiMgMS4gQWRkIGV4cGlyYXRpb25CbG9jayB0byB0aGUgcmVzdWx0IHR5cGUuCmVkaXRz
LmFwcGVuZCgoCiAgICAiQXR0ZXN0YXRpb25SZXN1bHQgdHlwZSIsCiAgICAiICBub25jZT86ICAg
ICAgc3RyaW5nXG4gIGV2ZW50Tm9uY2U/OiBzdHJpbmdcbn0iLAogICAgIiAgbm9uY2U/OiAgICAg
IHN0cmluZ1xuICBldmVudE5vbmNlPzogc3RyaW5nXG4gIC8vIF9fTkVYVU1fQVRURVNUX0VYUElS
WV9fIChwYXJ0NCkgYmxvY2sgYWZ0ZXIgd2hpY2ggdGhpcyBhdHRlc3RhdGlvbiBjYW4gbm9cbiAg
Ly8gbG9uZ2VyIG1pbnQ7IHBhc3QgaXQsIGNhbGwgcmVhdHRlc3QoKSBmb3IgYSBmcmVzaCBvbmUu
IEVtcHR5IHdoZW4gdW5rbm93bi5cbiAgZXhwaXJhdGlvbkJsb2NrPzogc3RyaW5nXG59IiwKKSkK
CiMgMi4gUG9wdWxhdGUgaXQgb24gdGhlIGNvbXBsZXRlIGJyYW5jaC4KZWRpdHMuYXBwZW5kKCgK
ICAgICJjb21wbGV0ZSBicmFuY2giLAogICAgIiAgICAgIHN0YXR1czogJ2NvbXBsZXRlJyxcbiAg
ICAgIG1lc3NhZ2U6IG1zZy5tZXNzYWdlLFxuICAgICAgYXR0ZXN0YXRpb246IG1zZy5hdHRlc3Rh
dGlvbixcbiAgICAgIG5vbmNlOiBtc2cuZXZlbnROb25jZSA/PyBtc2cubm9uY2UsXG4gICAgICBl
dmVudE5vbmNlOiBtc2cuZXZlbnROb25jZSxcbiAgICB9IiwKICAgICIgICAgICBzdGF0dXM6ICdj
b21wbGV0ZScsXG4gICAgICBtZXNzYWdlOiBtc2cubWVzc2FnZSxcbiAgICAgIGF0dGVzdGF0aW9u
OiBtc2cuYXR0ZXN0YXRpb24sXG4gICAgICBub25jZTogbXNnLmV2ZW50Tm9uY2UgPz8gbXNnLm5v
bmNlLFxuICAgICAgZXZlbnROb25jZTogbXNnLmV2ZW50Tm9uY2UsXG4gICAgICBleHBpcmF0aW9u
QmxvY2s6IG1zZy5kZWNvZGVkTWVzc2FnZT8uZXhwaXJhdGlvbkJsb2NrID8/IG1zZy5leHBpcmF0
aW9uQmxvY2ssXG4gICAgfSIsCikpCgpmb3IgZGVzYywgb2xkLCBuZXcgaW4gZWRpdHM6CiAgICBu
ID0gc3JjLmNvdW50KG9sZCkKICAgIGlmIG4gIT0gMToKICAgICAgICBwcmludChmIkVSUk9SOiBh
bmNob3IgJ3tkZXNjfScgbWF0Y2hlZCB7bn0gdGltZXMgKGV4cGVjdGVkIDEpLiBBYm9ydGluZy4i
KQogICAgICAgIHN5cy5leGl0KDIpCiAgICBzcmMgPSBzcmMucmVwbGFjZShvbGQsIG5ldykKCmlv
Lm9wZW4oUEFUSCwgInciLCBlbmNvZGluZz0idXRmLTgiKS53cml0ZShzcmMpCnByaW50KCIgIFBh
cnQgNGEgYXBwbGllZCB0byIsIFBBVEgpCg==
B64_A

base64 -d > "$TMP_B" <<'B64_B'
IyEvdXNyL2Jpbi9lbnYgcHl0aG9uMwoiIiIKUGFydCA0YiBwYXRjaGVyIGZvciBuZXh1bS13ZWIv
aG9va3MvdXNlQ29tcGxldGVCcmlkZ2UudHMKCkFkZHMgYXR0ZXN0YXRpb24tZXhwaXJ5IGhhbmRs
aW5nIGFuZCBhIGZhaWxlZC1taW50IHJldHJ5IGN5Y2xlOgogICogQ29tcGxldGVTdGVwIGdhaW5z
ICdyZWF0dGVzdGluZycKICAqIGltcG9ydHMgcmVhdHRlc3QgZnJvbSB0aGUgY2xpZW50CiAgKiBv
biBhIG1pbnQgZmFpbHVyZSB0aGF0IGxvb2tzIGxpa2UgZXhwaXJ5IE9SIGEgZ2VuZXJpYyByZXZl
cnQsIHRoZSBmbG93CiAgICByZXF1ZXN0cyBhIGZyZXNoIGF0dGVzdGF0aW9uIChyZWF0dGVzdCAt
PiByZS1wb2xsIC0+IHJlLW1pbnQpIE9OQ0UsIHdpdGgKICAgIGxpdmUgbm90ZXMsIGluc3RlYWQg
b2YgZGVhZC1lbmRpbmcKICAqICdub25jZSBhbHJlYWR5IHVzZWQnIGlzIHN0aWxsIHRyZWF0ZWQg
YXMgc3VjY2VzcyAoaWRlbXBvdGVudCBtaW50KQogICogY29ycmVjdHMgdGhlIGhlYWRlciBjb21t
ZW50IHRoYXQgY2xhaW1lZCBhdHRlc3RhdGlvbnMgbmV2ZXIgZXhwaXJlCgpJZGVtcG90ZW50IHZp
YSBfX05FWFVNX1JFQVRURVNUX1JFVFJZX18uIEV4YWN0LWFuY2hvcjsgYWJvcnRzIGNsZWFuIG9u
IGRyaWZ0LgoiIiIKaW1wb3J0IHN5cywgaW8KUEFUSCA9IHN5cy5hcmd2WzFdIGlmIGxlbihzeXMu
YXJndikgPiAxIGVsc2UgIm5leHVtLXdlYi9ob29rcy91c2VDb21wbGV0ZUJyaWRnZS50cyIKTUFS
S0VSID0gIl9fTkVYVU1fUkVBVFRFU1RfUkVUUllfXyIKc3JjID0gaW8ub3BlbihQQVRILCBlbmNv
ZGluZz0idXRmLTgiKS5yZWFkKCkKaWYgTUFSS0VSIGluIHNyYzoKICAgIHByaW50KCIgIFBhcnQg
NGIgYWxyZWFkeSBhcHBsaWVkIC0gbm90aGluZyB0byBkby4iKQogICAgc3lzLmV4aXQoMCkKCmVk
aXRzID0gW10KCiMgMS4gRml4IHRoZSBpbmFjY3VyYXRlICJhdHRlc3RhdGlvbnMgRE8gTk9UIEVY
UElSRSIgY29tbWVudC4KZWRpdHMuYXBwZW5kKCgKICAgICJoZWFkZXIgY29tbWVudCIsCiAgICAi
Ly8gQ0NUUCBtYWtlcyB0aGlzIHNhZmUgYW5kIHBlcm1hbmVudDpcbi8vICAgKiBhdHRlc3RhdGlv
bnMgRE8gTk9UIEVYUElSRSwgc28gdGhlcmUgaXMgbm8gZGVhZGxpbmVcbi8vICAgKiBkZXN0aW5h
dGlvbkNhbGxlciB3YXMgYnl0ZXMzMigwKSBhdCBidXJuIHRpbWUsIHNvIEFOWSBhZGRyZXNzIG1h
eSBtaW50XG4vLyBBIHN0cmFuZGVkIHRyYW5zZmVyIGlzIGFsd2F5cyByZWNvdmVyYWJsZSwgbmVl
ZGluZyBvbmx5IHRoZSBvcmlnaW5hbCBidXJuXG4vLyB0cmFuc2FjdGlvbiBoYXNoLCB3aGljaCB3
ZSBwZXJzaXN0ZWQuIiwKICAgICIvLyBfX05FWFVNX1JFQVRURVNUX1JFVFJZX18gKHBhcnQ0KSBD
Q1RQIG1ha2VzIHRoaXMgc2FmZSBhbmQgcGVybWFuZW50OlxuLy8gICAqIGFuIGF0dGVzdGF0aW9u
IGNhbiBvbmx5IG1pbnQgdW50aWwgaXRzIGV4cGlyYXRpb25CbG9jayAofjI0aCBvdXQpOyBwYXN0
XG4vLyAgICAgdGhhdCB3ZSBjYWxsIHJlYXR0ZXN0KG5vbmNlKSBmb3IgYSBmcmVzaCBvbmUgLSB0
aGVyZSBpcyBOTyBkZWFkbGluZSBvblxuLy8gICAgIHJlcXVlc3RpbmcgcmUtYXR0ZXN0YXRpb24s
IGJlY2F1c2UgdGhlIGJ1cm4gc3RpbGwgZXhpc3RzIG9uLWNoYWluXG4vLyAgICogbWludGluZyBp
cyBpZGVtcG90ZW50OiBhIHJldXNlZCBub25jZSByZXZlcnRzLCBpdCBuZXZlciBkb3VibGUtbWlu
dHNcbi8vICAgKiBkZXN0aW5hdGlvbkNhbGxlciB3YXMgYnl0ZXMzMigwKSBhdCBidXJuIHRpbWUs
IHNvIEFOWSBhZGRyZXNzIG1heSBtaW50XG4vLyBBIHN0cmFuZGVkIHRyYW5zZmVyIGlzIGFsd2F5
cyByZWNvdmVyYWJsZSwgbmVlZGluZyBvbmx5IHRoZSBvcmlnaW5hbCBidXJuXG4vLyB0cmFuc2Fj
dGlvbiBoYXNoLCB3aGljaCB3ZSBwZXJzaXN0ZWQuIiwKKSkKCiMgMi4gSW1wb3J0IHJlYXR0ZXN0
LgplZGl0cy5hcHBlbmQoKAogICAgImltcG9ydCIsCiAgICAiaW1wb3J0IHsgZmV0Y2hBdHRlc3Rh
dGlvbiB9IGZyb20gJ0AvbGliL2NjdHAtY2xpZW50JyIsCiAgICAiaW1wb3J0IHsgZmV0Y2hBdHRl
c3RhdGlvbiwgcmVhdHRlc3QgfSBmcm9tICdAL2xpYi9jY3RwLWNsaWVudCciLAopKQoKIyAzLiBB
ZGQgJ3JlYXR0ZXN0aW5nJyB0byB0aGUgc3RlcCB1bmlvbi4KZWRpdHMuYXBwZW5kKCgKICAgICJz
dGVwIHVuaW9uIiwKICAgICJleHBvcnQgdHlwZSBDb21wbGV0ZVN0ZXAgPSAnaWRsZScgfCAnY2hl
Y2tpbmcnIHwgJ21pbnRpbmcnIHwgJ2RvbmUnIHwgJ2Vycm9yJyIsCiAgICAiZXhwb3J0IHR5cGUg
Q29tcGxldGVTdGVwID0gJ2lkbGUnIHwgJ2NoZWNraW5nJyB8ICdyZWF0dGVzdGluZycgfCAnbWlu
dGluZycgfCAnZG9uZScgfCAnZXJyb3InIiwKKSkKCiMgNC4gUmVwbGFjZSB0aGUgbWludCArIGNh
dGNoIHNlY3Rpb24gd2l0aCBhIHZlcnNpb24gdGhhdCByZXRyaWVzIHZpYSByZWF0dGVzdC4KIyAg
ICBBbmNob3I6IGZyb20gdGhlICIvLyAyLiBNaW50IiBjb21tZW50IHRocm91Z2ggdGhlIGVuZCBv
ZiB0aGUgY2F0Y2gncwojICAgICdhbHJlYWR5IG1pbnRlZCcgaGFuZGxpbmcsIHVwIHRvIHRoZSBz
ZXRTdGVwKCdlcnJvcicpIGxpbmUuCk9MRF9NSU5UID0gIiIiICAgICAgLy8gMi4gTWludCBvbiB0
aGUgZGVzdGluYXRpb24gY2hhaW4gdmlhIGEgQ2lyY2xlIGNoYWxsZW5nZS4KICAgICAgc2V0U3Rl
cCgnbWludGluZycpCiAgICAgIGNvbnN0IHJlc3VsdCA9IGF3YWl0IGV4ZWN1dGVDb250cmFjdENh
bGwoewogICAgICAgIGNoYWluS2V5OiAgICAgICAgICAgICB0by5rZXksCiAgICAgICAgY29udHJh
Y3RBZGRyZXNzOiAgICAgIGNjdHBDb250cmFjdHMoKS5tZXNzYWdlVHJhbnNtaXR0ZXIsCiAgICAg
ICAgYWJpRnVuY3Rpb25TaWduYXR1cmU6ICdyZWNlaXZlTWVzc2FnZShieXRlcyxieXRlcyknLAog
ICAgICAgIGFiaVBhcmFtZXRlcnM6ICAgICAgICBbYXR0Lm1lc3NhZ2UsIGF0dC5hdHRlc3RhdGlv
bl0sCiAgICAgIH0sIHNldE5vdGUpCgogICAgICBjb25zdCB0eCA9IHJlc3VsdC50eEhhc2ggPz8g
J3BlbmRpbmcnCgogICAgICBhd2FpdCBmZXRjaChgJHtBUEl9L2JyaWRnZS8ke2JyaWRnZS5pZH0v
Y29tcGxldGVkYCwgewogICAgICAgIG1ldGhvZDogJ1BPU1QnLAogICAgICAgIGhlYWRlcnM6IHsg
J0NvbnRlbnQtVHlwZSc6ICdhcHBsaWNhdGlvbi9qc29uJyB9LAogICAgICAgIGJvZHk6IEpTT04u
c3RyaW5naWZ5KHsgbWludFR4OiB0eCB9KSwKICAgICAgfSkuY2F0Y2goKCkgPT4ge30pCgogICAg
ICBzZXRNaW50VHgodHgpCiAgICAgIHNldFN0ZXAoJ2RvbmUnKTsgc2V0Tm90ZShudWxsKQogICAg
fSBjYXRjaCAoZXJyOiBhbnkpIHsKICAgICAgbGV0IG1lc3NhZ2UgPSBlcnI/Lm1lc3NhZ2UgPz8g
J0NvdWxkIG5vdCBjb21wbGV0ZSB0aGUgdHJhbnNmZXInCiAgICAgIGlmIChlcnIgaW5zdGFuY2Vv
ZiBOZWVkc1JlYXV0aEVycm9yIHx8IGVyciBpbnN0YW5jZW9mIE5lZWRzQ2hhaW5FcnJvcikgewog
ICAgICAgIG1lc3NhZ2UgPSBlcnIubWVzc2FnZQogICAgICB9IGVsc2UgaWYgKC9hbHJlYWR5IGJl
ZW4gdXNlZHxub25jZSBhbHJlYWR5fGFscmVhZHkgbWludGVkL2kudGVzdChtZXNzYWdlKSkgewog
ICAgICAgIC8vIFRoZSBtaW50IGFscmVhZHkgaGFwcGVuZWQsIHNvIHRoaXMgaXMgc3VjY2Vzcywg
bm90IGZhaWx1cmUuCiAgICAgICAgbWVzc2FnZSA9ICdUaGlzIHRyYW5zZmVyIHdhcyBhbHJlYWR5
IGNvbXBsZXRlZC4gUmVmcmVzaGluZyB0aGUgbGlzdC4nCiAgICAgICAgYXdhaXQgZmV0Y2goYCR7
QVBJfS9icmlkZ2UvJHticmlkZ2UuaWR9L2NvbXBsZXRlZGAsIHsKICAgICAgICAgIG1ldGhvZDog
J1BPU1QnLAogICAgICAgICAgaGVhZGVyczogeyAnQ29udGVudC1UeXBlJzogJ2FwcGxpY2F0aW9u
L2pzb24nIH0sCiAgICAgICAgICBib2R5OiBKU09OLnN0cmluZ2lmeSh7IG1pbnRUeDogJ2FscmVh
ZHktbWludGVkJyB9KSwKICAgICAgICB9KS5jYXRjaCgoKSA9PiB7fSkKICAgICAgfQogICAgICBz
ZXRTdGVwKCdlcnJvcicpOyBzZXRFcnJvcihtZXNzYWdlKTsgc2V0RXJyb3JJZChicmlkZ2UuaWQp
OyBzZXROb3RlKG51bGwpCiAgICB9IGZpbmFsbHkgewogICAgICBzZXRCdXN5SWQobnVsbCkKICAg
IH0iIiIKCk5FV19NSU5UID0gIiIiICAgICAgLy8gMi4gTWludCBvbiB0aGUgZGVzdGluYXRpb24g
Y2hhaW4sIHJldHJ5aW5nIHRocm91Z2ggcmUtYXR0ZXN0YXRpb24uCiAgICAgIC8vCiAgICAgIC8v
IEEgc3RyYW5kZWQgdHJhbnNmZXIgY2FuIGZhaWwgdG8gbWludCBmb3IgYSBkb2N1bWVudGVkLCBy
ZWNvdmVyYWJsZQogICAgICAvLyByZWFzb246IHRoZSBhdHRlc3RhdGlvbidzIDI0aCBleHBpcmF0
aW9uQmxvY2sgaGFzIHBhc3NlZC4gQ2lyY2xlJ3MgZml4CiAgICAgIC8vIGlzIHJlYXR0ZXN0KG5v
bmNlKSAtPiByZS1wb2xsIC0+IHJlLW1pbnQuIFdlIGF0dGVtcHQgdGhlIG1pbnQsIGFuZCBvbiBh
CiAgICAgIC8vIGZhaWx1cmUgdGhhdCBpc24ndCAnYWxyZWFkeSBtaW50ZWQnIG9yIGFuIGF1dGgv
Y2hhaW4gcHJvbXB0LCB3ZSBydW4gT05FCiAgICAgIC8vIHJlYXR0ZXN0IGN5Y2xlIGJlZm9yZSBz
dXJmYWNpbmcgYW4gZXJyb3IuIE1pbnRpbmcgaXMgaWRlbXBvdGVudCwgc28gYQogICAgICAvLyBy
ZXRyeSBjYW4gbmV2ZXIgZG91YmxlLW1pbnQuCiAgICAgIGNvbnN0IHJlY29yZENvbXBsZXRlZCA9
IGFzeW5jICh0eDogc3RyaW5nKSA9PiB7CiAgICAgICAgYXdhaXQgZmV0Y2goYCR7QVBJfS9icmlk
Z2UvJHticmlkZ2UuaWR9L2NvbXBsZXRlZGAsIHsKICAgICAgICAgIG1ldGhvZDogJ1BPU1QnLAog
ICAgICAgICAgaGVhZGVyczogeyAnQ29udGVudC1UeXBlJzogJ2FwcGxpY2F0aW9uL2pzb24nIH0s
CiAgICAgICAgICBib2R5OiBKU09OLnN0cmluZ2lmeSh7IG1pbnRUeDogdHggfSksCiAgICAgICAg
fSkuY2F0Y2goKCkgPT4ge30pCiAgICAgIH0KCiAgICAgIGNvbnN0IGRvTWludCA9IGFzeW5jICht
ZXNzYWdlOiBzdHJpbmcsIGF0dGVzdGF0aW9uOiBzdHJpbmcpID0+IHsKICAgICAgICBzZXRTdGVw
KCdtaW50aW5nJykKICAgICAgICBjb25zdCByZXN1bHQgPSBhd2FpdCBleGVjdXRlQ29udHJhY3RD
YWxsKHsKICAgICAgICAgIGNoYWluS2V5OiAgICAgICAgICAgICB0by5rZXksCiAgICAgICAgICBj
b250cmFjdEFkZHJlc3M6ICAgICAgY2N0cENvbnRyYWN0cygpLm1lc3NhZ2VUcmFuc21pdHRlciwK
ICAgICAgICAgIGFiaUZ1bmN0aW9uU2lnbmF0dXJlOiAncmVjZWl2ZU1lc3NhZ2UoYnl0ZXMsYnl0
ZXMpJywKICAgICAgICAgIGFiaVBhcmFtZXRlcnM6ICAgICAgICBbbWVzc2FnZSwgYXR0ZXN0YXRp
b25dLAogICAgICAgIH0sIHNldE5vdGUpCiAgICAgICAgcmV0dXJuIHJlc3VsdC50eEhhc2ggPz8g
J3BlbmRpbmcnCiAgICAgIH0KCiAgICAgIGxldCBjdXJyZW50QXR0ID0gYXR0CiAgICAgIHRyeSB7
CiAgICAgICAgY29uc3QgdHggPSBhd2FpdCBkb01pbnQoY3VycmVudEF0dC5tZXNzYWdlISwgY3Vy
cmVudEF0dC5hdHRlc3RhdGlvbiEpCiAgICAgICAgYXdhaXQgcmVjb3JkQ29tcGxldGVkKHR4KQog
ICAgICAgIHNldE1pbnRUeCh0eCk7IHNldFN0ZXAoJ2RvbmUnKTsgc2V0Tm90ZShudWxsKQogICAg
ICB9IGNhdGNoIChtaW50RXJyOiBhbnkpIHsKICAgICAgICBjb25zdCBtID0gbWludEVycj8ubWVz
c2FnZSA/PyAnJwoKICAgICAgICAvLyBJZGVtcG90ZW50IHN1Y2Nlc3M6IHRoZSBtaW50IGFscmVh
ZHkgbGFuZGVkLgogICAgICAgIGlmICgvYWxyZWFkeSBiZWVuIHVzZWR8bm9uY2UgYWxyZWFkeXxh
bHJlYWR5IG1pbnRlZHxhbHJlYWR5IGJlZW4gcHJvY2Vzc2VkL2kudGVzdChtKSkgewogICAgICAg
ICAgYXdhaXQgcmVjb3JkQ29tcGxldGVkKCdhbHJlYWR5LW1pbnRlZCcpCiAgICAgICAgICBzZXRN
aW50VHgoJ2FscmVhZHktbWludGVkJyk7IHNldFN0ZXAoJ2RvbmUnKTsgc2V0Tm90ZShudWxsKQog
ICAgICAgICAgcmV0dXJuCiAgICAgICAgfQogICAgICAgIC8vIEF1dGggLyBjaGFpbiBwcm9tcHRz
IGFyZSBmb3IgdGhlIGNhbGxlciB0byByZXNvbHZlLCBub3QgcmV0cnlhYmxlIGhlcmUuCiAgICAg
ICAgaWYgKG1pbnRFcnIgaW5zdGFuY2VvZiBOZWVkc1JlYXV0aEVycm9yIHx8IG1pbnRFcnIgaW5z
dGFuY2VvZiBOZWVkc0NoYWluRXJyb3IpIHsKICAgICAgICAgIHRocm93IG1pbnRFcnIKICAgICAg
ICB9CgogICAgICAgIC8vIE90aGVyd2lzZSBhdHRlbXB0IE9ORSByZWF0dGVzdCBjeWNsZS4gVGhp
cyBjb3ZlcnMgYW4gZXhwaXJlZAogICAgICAgIC8vIGF0dGVzdGF0aW9uIGFuZCB0cmFuc2llbnQg
cmV2ZXJ0OyBpZiB0aGUgbWludCB0cnVseSBjYW4ndCBwcm9jZWVkCiAgICAgICAgLy8gdGhlIHNl
Y29uZCBhdHRlbXB0IHN1cmZhY2VzIHRoZSByZWFsIGVycm9yLgogICAgICAgIGNvbnN0IG5vbmNl
ID0gY3VycmVudEF0dC5ub25jZSA/PyBjdXJyZW50QXR0LmV2ZW50Tm9uY2UKICAgICAgICBpZiAo
IW5vbmNlKSB0aHJvdyBtaW50RXJyCgogICAgICAgIHNldFN0ZXAoJ3JlYXR0ZXN0aW5nJykKICAg
ICAgICBzZXROb3RlKCdBdHRlc3RhdGlvbiBtYXkgaGF2ZSBleHBpcmVkIC0gcmVxdWVzdGluZyBh
IGZyZXNoIG9uZSBmcm9tIENpcmNsZS4uLicpCiAgICAgICAgY29uc3Qgb2sgPSBhd2FpdCByZWF0
dGVzdChpcmlzQmFzZSgpLCBub25jZSkKICAgICAgICBpZiAoIW9rKSB7CiAgICAgICAgICB0aHJv
dyBuZXcgRXJyb3IoCiAgICAgICAgICAgICdUaGUgYXR0ZXN0YXRpb24gZm9yIHRoaXMgdHJhbnNm
ZXIgZXhwaXJlZCBhbmQgcmUtYXR0ZXN0YXRpb24gY291bGQgJyArCiAgICAgICAgICAgICdub3Qg
YmUgcmVxdWVzdGVkIHJpZ2h0IG5vdy4gWW91ciBmdW5kcyBhcmUgc2FmZSAtIHRyeSBhZ2FpbiBz
aG9ydGx5LicpCiAgICAgICAgfQoKICAgICAgICAvLyBSZS1wb2xsIGZvciB0aGUgcmVmcmVzaGVk
IGF0dGVzdGF0aW9uIChhIGZldyBnZW50bGUgYXR0ZW1wdHMpLgogICAgICAgIHNldE5vdGUoJ1dh
aXRpbmcgZm9yIHRoZSByZWZyZXNoZWQgYXR0ZXN0YXRpb24uLi4nKQogICAgICAgIGxldCByZWZy
ZXNoZWQgPSBudWxsIGFzIHR5cGVvZiBjdXJyZW50QXR0IHwgbnVsbAogICAgICAgIGZvciAobGV0
IGkgPSAwOyBpIDwgNjsgaSsrKSB7CiAgICAgICAgICBhd2FpdCBuZXcgUHJvbWlzZShyID0+IHNl
dFRpbWVvdXQociwgNTAwMCkpCiAgICAgICAgICBjb25zdCBhZ2FpbiA9IGF3YWl0IGZldGNoQXR0
ZXN0YXRpb24oaXJpc0Jhc2UoKSwgZnJvbS5kb21haW4sIGJyaWRnZS5idXJuX3R4ISkKICAgICAg
ICAgIGlmIChhZ2Fpbi5zdGF0dXMgPT09ICdjb21wbGV0ZScgJiYgYWdhaW4ubWVzc2FnZSAmJiBh
Z2Fpbi5hdHRlc3RhdGlvbikgewogICAgICAgICAgICByZWZyZXNoZWQgPSBhZ2FpbgogICAgICAg
ICAgICBicmVhawogICAgICAgICAgfQogICAgICAgIH0KICAgICAgICBpZiAoIXJlZnJlc2hlZCkg
ewogICAgICAgICAgdGhyb3cgbmV3IEVycm9yKAogICAgICAgICAgICAnUmVxdWVzdGVkIGEgZnJl
c2ggYXR0ZXN0YXRpb24sIGJ1dCBpdCBpcyBub3QgcmVhZHkgeWV0LiBZb3VyIGZ1bmRzICcgKwog
ICAgICAgICAgICAnYXJlIHNhZmUgLSBjb21lIGJhY2sgaW4gYSBmZXcgbWludXRlcyBhbmQgcHJl
c3MgQ29tcGxldGUgYWdhaW4uJykKICAgICAgICB9CgogICAgICAgIGF3YWl0IGZldGNoKGAke0FQ
SX0vYnJpZGdlLyR7YnJpZGdlLmlkfS9hdHRlc3RlZGAsIHsKICAgICAgICAgIG1ldGhvZDogJ1BP
U1QnLAogICAgICAgICAgaGVhZGVyczogeyAnQ29udGVudC1UeXBlJzogJ2FwcGxpY2F0aW9uL2pz
b24nIH0sCiAgICAgICAgICBib2R5OiBKU09OLnN0cmluZ2lmeSh7IGF0dGVzdGF0aW9uOiByZWZy
ZXNoZWQuYXR0ZXN0YXRpb24gfSksCiAgICAgICAgfSkuY2F0Y2goKCkgPT4ge30pCgogICAgICAg
IC8vIFNlY29uZCBhbmQgZmluYWwgbWludCBhdHRlbXB0IHdpdGggdGhlIGZyZXNoIGF0dGVzdGF0
aW9uLgogICAgICAgIGNvbnN0IHR4MiA9IGF3YWl0IGRvTWludChyZWZyZXNoZWQubWVzc2FnZSEs
IHJlZnJlc2hlZC5hdHRlc3RhdGlvbiEpCiAgICAgICAgYXdhaXQgcmVjb3JkQ29tcGxldGVkKHR4
MikKICAgICAgICBzZXRNaW50VHgodHgyKTsgc2V0U3RlcCgnZG9uZScpOyBzZXROb3RlKG51bGwp
CiAgICAgIH0KICAgIH0gY2F0Y2ggKGVycjogYW55KSB7CiAgICAgIGxldCBtZXNzYWdlID0gZXJy
Py5tZXNzYWdlID8/ICdDb3VsZCBub3QgY29tcGxldGUgdGhlIHRyYW5zZmVyJwogICAgICBpZiAo
ZXJyIGluc3RhbmNlb2YgTmVlZHNSZWF1dGhFcnJvciB8fCBlcnIgaW5zdGFuY2VvZiBOZWVkc0No
YWluRXJyb3IpIHsKICAgICAgICBtZXNzYWdlID0gZXJyLm1lc3NhZ2UKICAgICAgfSBlbHNlIGlm
ICgvYWxyZWFkeSBiZWVuIHVzZWR8bm9uY2UgYWxyZWFkeXxhbHJlYWR5IG1pbnRlZHxhbHJlYWR5
IGJlZW4gcHJvY2Vzc2VkL2kudGVzdChtZXNzYWdlKSkgewogICAgICAgIC8vIFRoZSBtaW50IGFs
cmVhZHkgaGFwcGVuZWQsIHNvIHRoaXMgaXMgc3VjY2Vzcywgbm90IGZhaWx1cmUuCiAgICAgICAg
bWVzc2FnZSA9ICdUaGlzIHRyYW5zZmVyIHdhcyBhbHJlYWR5IGNvbXBsZXRlZC4gUmVmcmVzaGlu
ZyB0aGUgbGlzdC4nCiAgICAgICAgYXdhaXQgZmV0Y2goYCR7QVBJfS9icmlkZ2UvJHticmlkZ2Uu
aWR9L2NvbXBsZXRlZGAsIHsKICAgICAgICAgIG1ldGhvZDogJ1BPU1QnLAogICAgICAgICAgaGVh
ZGVyczogeyAnQ29udGVudC1UeXBlJzogJ2FwcGxpY2F0aW9uL2pzb24nIH0sCiAgICAgICAgICBi
b2R5OiBKU09OLnN0cmluZ2lmeSh7IG1pbnRUeDogJ2FscmVhZHktbWludGVkJyB9KSwKICAgICAg
ICB9KS5jYXRjaCgoKSA9PiB7fSkKICAgICAgfQogICAgICBzZXRTdGVwKCdlcnJvcicpOyBzZXRF
cnJvcihtZXNzYWdlKTsgc2V0RXJyb3JJZChicmlkZ2UuaWQpOyBzZXROb3RlKG51bGwpCiAgICB9
IGZpbmFsbHkgewogICAgICBzZXRCdXN5SWQobnVsbCkKICAgIH0iIiIKCmVkaXRzLmFwcGVuZCgo
Im1pbnQrY2F0Y2giLCBPTERfTUlOVCwgTkVXX01JTlQpKQoKZm9yIGRlc2MsIG9sZCwgbmV3IGlu
IGVkaXRzOgogICAgbiA9IHNyYy5jb3VudChvbGQpCiAgICBpZiBuICE9IDE6CiAgICAgICAgcHJp
bnQoZiJFUlJPUjogYW5jaG9yICd7ZGVzY30nIG1hdGNoZWQge259IHRpbWVzIChleHBlY3RlZCAx
KS4gQWJvcnRpbmcuIikKICAgICAgICBzeXMuZXhpdCgyKQogICAgc3JjID0gc3JjLnJlcGxhY2Uo
b2xkLCBuZXcpCgojIHN0YW1wIHRoZSBtYXJrZXIgc28gaWRlbXBvdGVuY3kgd29ya3MgZXZlbiB0
aG91Z2ggdGhlIGhlYWRlciBjb21tZW50IGNhcnJpZXMgaXQKaW8ub3BlbihQQVRILCAidyIsIGVu
Y29kaW5nPSJ1dGYtOCIpLndyaXRlKHNyYykKcHJpbnQoIiAgUGFydCA0YiBhcHBsaWVkIHRvIiwg
UEFUSCkK
B64_B

verify "$TMP_A" "$A_SHA"
verify "$TMP_B" "$B_SHA"
log "Both patchers verified."

# ---- apply 4a (client) ----
if grep -qF "$MARK_A" "$CLIENT"; then
  log "Part 4a already present - skipping."
else
  cp "$CLIENT" "$BACKUP_DIR/cctp-client.ts"
  python3 "$TMP_A" "$CLIENT" || { cp "$BACKUP_DIR/cctp-client.ts" "$CLIENT"; die "4a failed; restored."; }
  grep -qF "$MARK_A" "$CLIENT" || { cp "$BACKUP_DIR/cctp-client.ts" "$CLIENT"; die "4a post-check failed; restored."; }
  log "Applied 4a -> $CLIENT"
fi

# ---- apply 4b (complete hook) ----
if grep -qF "$MARK_B" "$COMPLETE"; then
  log "Part 4b already present - skipping."
else
  cp "$COMPLETE" "$BACKUP_DIR/useCompleteBridge.ts"
  python3 "$TMP_B" "$COMPLETE" || { cp "$BACKUP_DIR/useCompleteBridge.ts" "$COMPLETE"; die "4b failed; restored."; }
  grep -qF "$MARK_B" "$COMPLETE" || { cp "$BACKUP_DIR/useCompleteBridge.ts" "$COMPLETE"; die "4b post-check failed; restored."; }
  log "Applied 4b -> $COMPLETE"
fi

# ------------------------------------------------------------- deploy gate --
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

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "Not a git work tree; files applied + built, commit manually."
REMOTE="$(git remote | head -1 || true)"; [ -n "$REMOTE" ] || die "No git remote; commit/push manually."
BRANCH="$(git rev-parse --abbrev-ref HEAD)"
git add -A
if git diff --cached --quiet; then log "Nothing to commit."; exit 0; fi
log "Committing on '$BRANCH' -> '$REMOTE'..."
git commit -m "$COMMIT_MSG"
git push "$REMOTE" "$BRANCH"
log ""
log "Pushed Part 4. The Fast/Standard upgrade is complete."
