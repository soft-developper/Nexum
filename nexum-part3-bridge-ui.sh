#!/usr/bin/env bash
# ============================================================================
# Nexum bridge upgrade - PART 3 of 4: bridge UI (Fast/Standard + live quote)
#
# Adds to the bridge card:
#   * a Fast / Standard speed toggle (Fast default), auto-locked to Standard
#     with an explanation on source chains where Circle disables Fast
#   * a live quote panel - bridge fee, you-receive on destination, and ETA -
#     that updates as the user types (debounced)
#   * passes the chosen mode into bridge()
#
# Ships two files:
#   NEW   nexum-web/hooks/useQuotePreview.ts        (live dual-mode quote hook)
#   PATCH nexum-web/components/bridge/BridgeCard.tsx (toggle + panel + mode)
#
# REQUIRES Parts 1 + 2 (quote engine + useBridge mode support).
#
# Delivery contract (your v2 spec) + full deploy:
#   * both payloads base64 + sha256 verified before anything is written
#   * exact-anchor patch: a drifted card aborts clean, never half-patched
#   * idempotent (markers __NEXUM_QUOTE_PREVIEW__ / __NEXUM_BRIDGE_MODE_UI__)
#   * timestamped backups
#   * deploy GATE: rm -rf .next && npx tsc --noEmit && npm run build
#     -> commits + pushes ONLY if all pass
#   * --revert undoes both files ; --no-deploy applies only
#
# Run from the REPO ROOT (folder containing nexum-web/).
#   bash nexum-part3-bridge-ui.sh
#   bash nexum-part3-bridge-ui.sh --no-deploy
#   bash nexum-part3-bridge-ui.sh --revert
# ============================================================================
set -euo pipefail

HOOK="nexum-web/hooks/useQuotePreview.ts"
CARD="nexum-web/components/bridge/BridgeCard.tsx"
MARK_HOOK="__NEXUM_QUOTE_PREVIEW__"
MARK_CARD="__NEXUM_BRIDGE_MODE_UI__"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR=".nexum-part3-backup/${STAMP}"
HOOK_SHA="d325f4f1f80f4644dd825f1395860cfb57007d5425fa2fa8760d9d490658a5ae"
PATCH_SHA="3255f26d1dda99d4d65672b18592cda0cf3c0947e5cadf960ac745ce4fc49ce7"
COMMIT_MSG="feat(bridge): Fast/Standard toggle + live fee/receive/ETA quote panel (Part 3)"

FLAG="${1:-}"
log(){ printf '  %s\n' "$*"; }
die(){ printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[ -f "$CARD" ] || die "Cannot find $CARD . Run from the repo root (folder containing nexum-web/)."

# ---------------------------------------------------------------- revert ----
if [ "$FLAG" = "--revert" ]; then
  LATEST="$(ls -1dt .nexum-part3-backup/*/ 2>/dev/null | head -1 || true)"
  [ -n "$LATEST" ] || die "No Part 3 backup found."
  [ -f "${LATEST}BridgeCard.tsx" ] && cp "${LATEST}BridgeCard.tsx" "$CARD" && log "Restored $CARD"
  # the hook is new in this part; revert removes it
  if [ -f "$HOOK" ] && grep -qF "$MARK_HOOK" "$HOOK"; then rm -f "$HOOK" && log "Removed $HOOK"; fi
  log "Reverted Part 3."
  exit 0
fi

# ------------------------------------------ preconditions: Parts 1 + 2 ------
grep -qF "__NEXUM_CCTP_QUOTE_ENGINE__" nexum-web/lib/cctp-client.ts || die "Part 1 not applied (quote engine missing). Apply Part 1 first."
grep -qF "__NEXUM_BRIDGE_MODE__"       nexum-web/hooks/useBridge.ts   || die "Part 2 not applied (useBridge mode missing). Apply Part 2 first."

mkdir -p "$BACKUP_DIR"
verify(){ # $1 file  $2 expected sha
  local got; got="$( (sha256sum "$1" 2>/dev/null || shasum -a 256 "$1") | awk '{print $1}')"
  [ "$got" = "$2" ] || die "Checksum mismatch for $1 (got $got). Nothing was written."
}

# ------------------------------------------------ decode payloads to tmp ----
TMP_HOOK="$(mktemp /tmp/nexum-hook.XXXXXX.ts)"
TMP_PATCH="$(mktemp /tmp/nexum-cardpatch.XXXXXX.py)"
trap 'rm -f "$TMP_HOOK" "$TMP_PATCH"' EXIT

base64 -d > "$TMP_HOOK" <<'B64_HOOK'
Ly8gX19ORVhVTV9RVU9URV9QUkVWSUVXX18gKHBhcnQzKSBsaXZlIEZhc3QvU3RhbmRhcmQgcXVv
dGUgZm9yIHRoZSBicmlkZ2UgVUkKJ3VzZSBjbGllbnQnCmltcG9ydCB7IHVzZUVmZmVjdCwgdXNl
UmVmLCB1c2VTdGF0ZSB9IGZyb20gJ3JlYWN0JwppbXBvcnQgeyBjaGFpbkJ5S2V5LCBpcmlzQmFz
ZSB9IGZyb20gJ0AvbGliL2NjdHAtY2hhaW5zJwppbXBvcnQgewogIGdldEJvdGhRdW90ZXMsIHRv
VW5pdHMsIGZyb21Vbml0cywKICB0eXBlIFRyYW5zZmVyUXVvdGUsCn0gZnJvbSAnQC9saWIvY2N0
cC1jbGllbnQnCgovKgogIExpdmUgcXVvdGUgcHJldmlldyBmb3IgdGhlIGJyaWRnZSBjYXJkLgoK
ICBUaGUgYnJpZGdlIGhvb2sgb25seSByZXNvbHZlcyBhIHF1b3RlIG9uY2UgYSB0cmFuc2ZlciBp
cyBhY3R1YWxseSBydW5uaW5nLgogIEZvciB0aGUgcHJlLXN1Ym1pdCBVSSB3ZSBuZWVkIGJvdGgg
RmFzdCBhbmQgU3RhbmRhcmQgcXVvdGVzIGFzIHRoZSB1c2VyIHR5cGVzLAogIHNvIHRoZXkgY2Fu
IHNlZSB0aGUgZmVlLCB0aGUgYW1vdW50IHRoYXQgbGFuZHMsIGFuZCB0aGUgRVRBIEJFRk9SRSBz
aWduaW5nLgoKICBUaGlzIGhvb2s6CiAgICAqIGRlYm91bmNlcyBvbiBhbW91bnQgc28gd2UgZG9u
J3QgaGFtbWVyIENpcmNsZSdzIGZlZSBBUEkgcGVyIGtleXN0cm9rZQogICAgKiBmZXRjaGVzIGJv
dGggbW9kZXMgaW4gb25lIGNhbGwgKGdldEJvdGhRdW90ZXMgc2hhcmVzIG9uZSBmZWUtdGFibGUg
ZmV0Y2gpCiAgICAqIHJldHVybnMgZmFzdD1udWxsIHdoZW4gdGhlIHNvdXJjZSBjaGFpbiBjYW4n
dCBkbyBGYXN0LCBzbyB0aGUgVUkgY2FuCiAgICAgIGRpc2FibGUgdGhlIEZhc3Qgb3B0aW9uIGFu
ZCBleHBsYWluIHdoeQogICAgKiBuZXZlciB0aHJvd3MgLSBhIGZlZS1BUEkgaGljY3VwIGp1c3Qg
eWllbGRzIGxvYWRpbmc9ZmFsc2Ugd2l0aCB3aGF0ZXZlcgogICAgICBpdCBjb3VsZCByZXNvbHZl
IChTdGFuZGFyZCBpcyBmcmVlLCBzbyBpdCBhbHdheXMgaGFzIGEgc2FuZSBhbnN3ZXIpCiovCmV4
cG9ydCBpbnRlcmZhY2UgUXVvdGVQcmV2aWV3IHsKICBsb2FkaW5nOiAgYm9vbGVhbgogIGZhc3Q6
ICAgICBUcmFuc2ZlclF1b3RlIHwgbnVsbAogIHN0YW5kYXJkOiBUcmFuc2ZlclF1b3RlIHwgbnVs
bAogIC8qKiB0cnVlIHdoZW4gdGhlIHNvdXJjZSBjaGFpbiBzdXBwb3J0cyBGYXN0IGFzIGEgc291
cmNlIGF0IGFsbCAqLwogIGZhc3RBdmFpbGFibGU6IGJvb2xlYW4KfQoKY29uc3QgRU1QVFk6IFF1
b3RlUHJldmlldyA9IHsKICBsb2FkaW5nOiBmYWxzZSwgZmFzdDogbnVsbCwgc3RhbmRhcmQ6IG51
bGwsIGZhc3RBdmFpbGFibGU6IGZhbHNlLAp9CgpleHBvcnQgZnVuY3Rpb24gdXNlUXVvdGVQcmV2
aWV3KAogIGZyb21LZXk6IHN0cmluZywgdG9LZXk6IHN0cmluZywgYW1vdW50OiBzdHJpbmcsCik6
IFF1b3RlUHJldmlldyB7CiAgY29uc3QgW3ByZXZpZXcsIHNldFByZXZpZXddID0gdXNlU3RhdGU8
UXVvdGVQcmV2aWV3PihFTVBUWSkKICAvLyBHdWFyZHMgYWdhaW5zdCBhIHNsb3cgZWFybGllciBy
ZXF1ZXN0IG92ZXJ3cml0aW5nIGEgbmV3ZXIgb25lLgogIGNvbnN0IHJlcUlkID0gdXNlUmVmKDAp
CgogIHVzZUVmZmVjdCgoKSA9PiB7CiAgICBjb25zdCBhbXQgPSBOdW1iZXIoYW1vdW50KQogICAg
Y29uc3QgZnJvbSA9IGNoYWluQnlLZXkoZnJvbUtleSkKICAgIGNvbnN0IHRvICAgPSBjaGFpbkJ5
S2V5KHRvS2V5KQoKICAgIC8vIE5vdGhpbmcgdG8gcXVvdGUgeWV0OiBjbGVhciB3aXRob3V0IGEg
bmV0d29yayBjYWxsLgogICAgaWYgKCFmcm9tIHx8ICF0byB8fCBmcm9tS2V5ID09PSB0b0tleSB8
fCAhKGFtdCA+IDApKSB7CiAgICAgIHNldFByZXZpZXcoRU1QVFkpCiAgICAgIHJldHVybgogICAg
fQoKICAgIGNvbnN0IGlkID0gKytyZXFJZC5jdXJyZW50CiAgICBzZXRQcmV2aWV3KHAgPT4gKHsg
Li4ucCwgbG9hZGluZzogdHJ1ZSB9KSkKCiAgICBjb25zdCB0ID0gc2V0VGltZW91dChhc3luYyAo
KSA9PiB7CiAgICAgIHRyeSB7CiAgICAgICAgY29uc3QgYW1vdW50VW5pdHMgPSB0b1VuaXRzKGFt
dCkKICAgICAgICBjb25zdCB7IGZhc3QsIHN0YW5kYXJkIH0gPSBhd2FpdCBnZXRCb3RoUXVvdGVz
KHsKICAgICAgICAgIGlyaXNCYXNlOiAgIGlyaXNCYXNlKCksCiAgICAgICAgICBmcm9tS2V5OiAg
ICBmcm9tLmtleSwKICAgICAgICAgIGZyb21Eb21haW46IGZyb20uZG9tYWluLAogICAgICAgICAg
dG9Eb21haW46ICAgdG8uZG9tYWluLAogICAgICAgICAgYW1vdW50VW5pdHMsCiAgICAgICAgfSkK
ICAgICAgICBpZiAoaWQgIT09IHJlcUlkLmN1cnJlbnQpIHJldHVybiAvLyBhIG5ld2VyIHJlcXVl
c3Qgc3VwZXJzZWRlZCB0aGlzIG9uZQogICAgICAgIHNldFByZXZpZXcoewogICAgICAgICAgbG9h
ZGluZzogZmFsc2UsCiAgICAgICAgICBmYXN0LAogICAgICAgICAgc3RhbmRhcmQsCiAgICAgICAg
ICBmYXN0QXZhaWxhYmxlOiBmYXN0ICE9PSBudWxsLAogICAgICAgIH0pCiAgICAgIH0gY2F0Y2gg
ewogICAgICAgIGlmIChpZCAhPT0gcmVxSWQuY3VycmVudCkgcmV0dXJuCiAgICAgICAgc2V0UHJl
dmlldyh7IC4uLkVNUFRZLCBsb2FkaW5nOiBmYWxzZSB9KQogICAgICB9CiAgICB9LCAzNTApCgog
ICAgcmV0dXJuICgpID0+IGNsZWFyVGltZW91dCh0KQogIH0sIFtmcm9tS2V5LCB0b0tleSwgYW1v
dW50XSkKCiAgcmV0dXJuIHByZXZpZXcKfQoKLyogRm9ybWF0IGEgVVNEQyB1bml0IGFtb3VudCAo
YmlnaW50KSBmb3IgZGlzcGxheSwgdHJpbW1pbmcgdG8gYGRwYCBkZWNpbWFscy4gKi8KZXhwb3J0
IGZ1bmN0aW9uIGZvcm1hdFVuaXRzKHVuaXRzOiBiaWdpbnQsIGRwID0gNCk6IHN0cmluZyB7CiAg
Y29uc3QgbiA9IGZyb21Vbml0cyh1bml0cykKICByZXR1cm4gbi50b0xvY2FsZVN0cmluZyh1bmRl
ZmluZWQsIHsKICAgIG1pbmltdW1GcmFjdGlvbkRpZ2l0czogMCwgbWF4aW11bUZyYWN0aW9uRGln
aXRzOiBkcCwKICB9KQp9CgovKiBIdW1hbiBFVEEgZnJvbSBzZWNvbmRzOiAifjhzIiwgIn4yIG1p
biIsICJ+MTUtMTkgbWluIiBzdHlsZS4gKi8KZXhwb3J0IGZ1bmN0aW9uIGZvcm1hdEV0YShzZWNv
bmRzOiBudW1iZXIpOiBzdHJpbmcgewogIGlmIChzZWNvbmRzIDw9IDApIHJldHVybiAnaW5zdGFu
dCcKICBpZiAoc2Vjb25kcyA8IDYwKSByZXR1cm4gYH4ke3NlY29uZHN9c2AKICBjb25zdCBtaW5z
ID0gTWF0aC5yb3VuZChzZWNvbmRzIC8gNjApCiAgcmV0dXJuIGB+JHttaW5zfSBtaW5gCn0K
B64_HOOK

base64 -d > "$TMP_PATCH" <<'B64_PATCH'
IyEvdXNyL2Jpbi9lbnYgcHl0aG9uMwoiIiIKUGFydCAzIHBhdGNoZXIgZm9yIG5leHVtLXdlYi9j
b21wb25lbnRzL2JyaWRnZS9CcmlkZ2VDYXJkLnRzeAoKQWRkcyB0byB0aGUgYnJpZGdlIFVJOgog
ICogYSBGYXN0IC8gU3RhbmRhcmQgbW9kZSB0b2dnbGUgKEZhc3QgZGVmYXVsdCksIGRpc2FibGVk
ICsgZXhwbGFpbmVkIHdoZW4gdGhlCiAgICBzb3VyY2UgY2hhaW4gY2FuJ3QgZG8gRmFzdAogICog
YSBsaXZlIHF1b3RlIHBhbmVsOiBmZWUsIHlvdS1yZWNlaXZlLCBhbmQgRVRBLCB1cGRhdGluZyBh
cyB0aGUgdXNlciB0eXBlcwogICogcGFzc2VzIHRoZSBjaG9zZW4gbW9kZSB0byBicmlkZ2UoKQoK
Q29uc3VtZXM6IHVzZVF1b3RlUHJldmlldyAobmV3IGhvb2ssIHNoaXBwZWQgaW4gdGhlIHNhbWUg
c2NyaXB0KSBhbmQgdGhlCkJyaWRnZVN0YXRlIHsgbW9kZSwgcXVvdGUgfSBmcm9tIFBhcnQgMi4K
CklkZW1wb3RlbnQgdmlhIF9fTkVYVU1fQlJJREdFX01PREVfVUlfXy4gRXhhY3QtYW5jaG9yIGVk
aXRzOiBhIGRyaWZ0ZWQgZmlsZQphYm9ydHMgY2xlYW4gd2l0aG91dCB3cml0aW5nLgoiIiIKaW1w
b3J0IHN5cywgaW8KClBBVEggPSBzeXMuYXJndlsxXSBpZiBsZW4oc3lzLmFyZ3YpID4gMSBlbHNl
ICJuZXh1bS13ZWIvY29tcG9uZW50cy9icmlkZ2UvQnJpZGdlQ2FyZC50c3giCk1BUktFUiA9ICJf
X05FWFVNX0JSSURHRV9NT0RFX1VJX18iCgpzcmMgPSBpby5vcGVuKFBBVEgsIGVuY29kaW5nPSJ1
dGYtOCIpLnJlYWQoKQppZiBNQVJLRVIgaW4gc3JjOgogICAgcHJpbnQoIiAgUGFydCAzIGFscmVh
ZHkgYXBwbGllZCAtIG5vdGhpbmcgdG8gZG8uIikKICAgIHN5cy5leGl0KDApCgplZGl0cyA9IFtd
CgojIDEuIEltcG9ydHM6IGljb25zICsgcHJldmlldyBob29rICsgVHJhbnNmZXJNb2RlLiBBZGQg
YWZ0ZXIgdGhlIHVzZUJyaWRnZSBpbXBvcnQuCmVkaXRzLmFwcGVuZCgoCiAgICAiaW1wb3J0cyIs
CiAgICAiaW1wb3J0IHsgdXNlQnJpZGdlIH0gZnJvbSAnQC9ob29rcy91c2VCcmlkZ2UnXG4iLAog
ICAgImltcG9ydCB7IHVzZUJyaWRnZSB9IGZyb20gJ0AvaG9va3MvdXNlQnJpZGdlJ1xuIgogICAg
Ii8vIF9fTkVYVU1fQlJJREdFX01PREVfVUlfXyAocGFydDMpIEZhc3QvU3RhbmRhcmQgdG9nZ2xl
ICsgbGl2ZSBxdW90ZVxuIgogICAgImltcG9ydCB7IFphcCwgQ2xvY2sgfSBmcm9tICdsdWNpZGUt
cmVhY3QnXG4iCiAgICAiaW1wb3J0IHR5cGUgeyBUcmFuc2Zlck1vZGUgfSBmcm9tICdAL2xpYi9j
Y3RwLWNsaWVudCdcbiIKICAgICJpbXBvcnQge1xuIgogICAgIiAgdXNlUXVvdGVQcmV2aWV3LCBm
b3JtYXRVbml0cywgZm9ybWF0RXRhLFxuIgogICAgIn0gZnJvbSAnQC9ob29rcy91c2VRdW90ZVBy
ZXZpZXcnXG4iLAopKQoKIyAyLiBTdGF0ZTogYWRkIG1vZGUsIGFuZCB0aGUgbGl2ZSBwcmV2aWV3
LCByaWdodCBhZnRlciB0aGUgYW1vdW50IHN0YXRlLgplZGl0cy5hcHBlbmQoKAogICAgInN0YXRl
IiwKICAgICIgIGNvbnN0IFthbW91bnQsICBzZXRBbW91bnRdICA9IHVzZVN0YXRlKCcnKVxuIiwK
ICAgICIgIGNvbnN0IFthbW91bnQsICBzZXRBbW91bnRdICA9IHVzZVN0YXRlKCcnKVxuIgogICAg
IiAgY29uc3QgW21vZGUsICAgIHNldE1vZGVdICAgID0gdXNlU3RhdGU8VHJhbnNmZXJNb2RlPign
ZmFzdCcpXG4iCiAgICAiXG4iCiAgICAiICAvLyBMaXZlIEZhc3QvU3RhbmRhcmQgcXVvdGUgYXMg
dGhlIHVzZXIgdHlwZXMgKGZlZSwgeW91LXJlY2VpdmUsIEVUQSkuXG4iCiAgICAiICBjb25zdCBw
cmV2aWV3ID0gdXNlUXVvdGVQcmV2aWV3KGZyb21LZXksIHRvS2V5LCBhbW91bnQpXG4iCiAgICAi
ICAvLyBJZiB0aGUgc291cmNlIGNhbid0IGRvIEZhc3QsIGZvcmNlIFN0YW5kYXJkIGFuZCBsb2Nr
IHRoZSB0b2dnbGUuXG4iCiAgICAiICB1c2VFZmZlY3QoKCkgPT4ge1xuIgogICAgIiAgICBpZiAo
IXByZXZpZXcubG9hZGluZyAmJiBwcmV2aWV3LnN0YW5kYXJkICYmICFwcmV2aWV3LmZhc3RBdmFp
bGFibGUgJiYgbW9kZSA9PT0gJ2Zhc3QnKSB7XG4iCiAgICAiICAgICAgc2V0TW9kZSgnc3RhbmRh
cmQnKVxuIgogICAgIiAgICB9XG4iCiAgICAiICB9LCBbcHJldmlldy5sb2FkaW5nLCBwcmV2aWV3
LmZhc3RBdmFpbGFibGUsIHByZXZpZXcuc3RhbmRhcmQsIG1vZGVdKVxuIgogICAgIiAgY29uc3Qg
YWN0aXZlUXVvdGUgPSBtb2RlID09PSAnZmFzdCcgPyBwcmV2aWV3LmZhc3QgOiBwcmV2aWV3LnN0
YW5kYXJkXG4iLAopKQoKIyAzLiBQYXNzIG1vZGUgdG8gYnJpZGdlKCkKZWRpdHMuYXBwZW5kKCgK
ICAgICJicmlkZ2UgY2FsbCIsCiAgICAiICAgICAgICAgIG9uQ2xpY2s9eygpID0+IGJyaWRnZSh7
IGZyb21LZXksIHRvS2V5LCBhbW91bnQ6IGFtdCB9KX0iLAogICAgIiAgICAgICAgICBvbkNsaWNr
PXsoKSA9PiBicmlkZ2UoeyBmcm9tS2V5LCB0b0tleSwgYW1vdW50OiBhbXQsIG1vZGUgfSl9IiwK
KSkKCiMgNC4gSW5zZXJ0IHRoZSB0b2dnbGUgKyBxdW90ZSBwYW5lbCByaWdodCBhZnRlciB0aGUg
YW1vdW50IGlucHV0IGJsb2NrLAojICAgIGJlZm9yZSB0aGUgc2FtZS1jaGFpbiB3YXJuaW5nLiBB
bmNob3Igb24gdGhlIHJvdXRlIHdhcm5pbmcgY29tbWVudC4KVE9HR0xFX0FORF9QQU5FTCA9IHIn
JycgICAgICB7LyogX19ORVhVTV9CUklER0VfTU9ERV9VSV9fICBUcmFuc2ZlciBzcGVlZDogRmFz
dCB2cyBTdGFuZGFyZC4KICAgICAgICAgIEZhc3QgcGF5cyBhIHNtYWxsIENpcmNsZSBmZWUgZm9y
IG5lYXItaW5zdGFudCBhdHRlc3RhdGlvbjsgU3RhbmRhcmQgaXMKICAgICAgICAgIGZyZWUgYnV0
IHdhaXRzIGZvciBoYXJkIGZpbmFsaXR5LiBGYXN0IGlzIHRoZSBkZWZhdWx0OyBpdCBpcyBkaXNh
YmxlZAogICAgICAgICAgb24gc291cmNlIGNoYWlucyB3aGVyZSBDaXJjbGUgZG9lc24ndCBvZmZl
ciBpdCAoc3RhbmRhcmQgaXMgYWxyZWFkeQogICAgICAgICAgZmFzdCB0aGVyZSkuICovfQogICAg
ICB7cm91dGVPayAmJiBhbXQgPiAwICYmICgKICAgICAgICA8ZGl2IGNsYXNzTmFtZT0ibWItNCI+
CiAgICAgICAgICA8bGFiZWwgY2xhc3NOYW1lPSJtYi0xLjUgYmxvY2sgdGV4dC14cyB0ZXh0LWFw
cC1tdXRlZCI+VHJhbnNmZXIgc3BlZWQ8L2xhYmVsPgogICAgICAgICAgPGRpdiBjbGFzc05hbWU9
ImdyaWQgZ3JpZC1jb2xzLTIgZ2FwLTIiPgogICAgICAgICAgICA8YnV0dG9uCiAgICAgICAgICAg
ICAgdHlwZT0iYnV0dG9uIgogICAgICAgICAgICAgIG9uQ2xpY2s9eygpID0+IHByZXZpZXcuZmFz
dEF2YWlsYWJsZSAmJiBzZXRNb2RlKCdmYXN0Jyl9CiAgICAgICAgICAgICAgZGlzYWJsZWQ9e2J1
c3kgfHwgIXByZXZpZXcuZmFzdEF2YWlsYWJsZX0KICAgICAgICAgICAgICBjbGFzc05hbWU9e2Bm
bGV4IGZsZXgtY29sIGl0ZW1zLXN0YXJ0IGdhcC0wLjUgcm91bmRlZC1sZyBib3JkZXIgcHgtMyBw
eS0yIHRleHQtbGVmdCB0cmFuc2l0aW9uCiAgICAgICAgICAgICAgICAke21vZGUgPT09ICdmYXN0
JwogICAgICAgICAgICAgICAgICA/ICdib3JkZXItYXBwLWFjY2VudC10ZXh0IGJnLWFwcC1hY2Nl
bnQtdGV4dC8xMCcKICAgICAgICAgICAgICAgICAgOiAnYm9yZGVyLWFwcC1ib3JkZXIgYmctYXBw
LWJnIGhvdmVyOmJvcmRlci1hcHAtbXV0ZWQnfQogICAgICAgICAgICAgICAgJHshcHJldmlldy5m
YXN0QXZhaWxhYmxlID8gJ2N1cnNvci1ub3QtYWxsb3dlZCBvcGFjaXR5LTQwJyA6ICcnfWB9CiAg
ICAgICAgICAgID4KICAgICAgICAgICAgICA8c3BhbiBjbGFzc05hbWU9ImZsZXggaXRlbXMtY2Vu
dGVyIGdhcC0xIHRleHQteHMgZm9udC1tZWRpdW0gdGV4dC1hcHAtdGV4dCI+CiAgICAgICAgICAg
ICAgICA8WmFwIGNsYXNzTmFtZT0iaC0zIHctMyIgLz4gRmFzdAogICAgICAgICAgICAgIDwvc3Bh
bj4KICAgICAgICAgICAgICA8c3BhbiBjbGFzc05hbWU9InRleHQtWzEwcHhdIHRleHQtYXBwLW11
dGVkIj4KICAgICAgICAgICAgICAgIHtwcmV2aWV3LmZhc3QgPyBmb3JtYXRFdGEocHJldmlldy5m
YXN0LmV0YVNlY29uZHMpIDogJ3NlY29uZHMnfQogICAgICAgICAgICAgIDwvc3Bhbj4KICAgICAg
ICAgICAgPC9idXR0b24+CiAgICAgICAgICAgIDxidXR0b24KICAgICAgICAgICAgICB0eXBlPSJi
dXR0b24iCiAgICAgICAgICAgICAgb25DbGljaz17KCkgPT4gc2V0TW9kZSgnc3RhbmRhcmQnKX0K
ICAgICAgICAgICAgICBkaXNhYmxlZD17YnVzeX0KICAgICAgICAgICAgICBjbGFzc05hbWU9e2Bm
bGV4IGZsZXgtY29sIGl0ZW1zLXN0YXJ0IGdhcC0wLjUgcm91bmRlZC1sZyBib3JkZXIgcHgtMyBw
eS0yIHRleHQtbGVmdCB0cmFuc2l0aW9uCiAgICAgICAgICAgICAgICAke21vZGUgPT09ICdzdGFu
ZGFyZCcKICAgICAgICAgICAgICAgICAgPyAnYm9yZGVyLWFwcC1hY2NlbnQtdGV4dCBiZy1hcHAt
YWNjZW50LXRleHQvMTAnCiAgICAgICAgICAgICAgICAgIDogJ2JvcmRlci1hcHAtYm9yZGVyIGJn
LWFwcC1iZyBob3Zlcjpib3JkZXItYXBwLW11dGVkJ31gfQogICAgICAgICAgICA+CiAgICAgICAg
ICAgICAgPHNwYW4gY2xhc3NOYW1lPSJmbGV4IGl0ZW1zLWNlbnRlciBnYXAtMSB0ZXh0LXhzIGZv
bnQtbWVkaXVtIHRleHQtYXBwLXRleHQiPgogICAgICAgICAgICAgICAgPENsb2NrIGNsYXNzTmFt
ZT0iaC0zIHctMyIgLz4gU3RhbmRhcmQKICAgICAgICAgICAgICA8L3NwYW4+CiAgICAgICAgICAg
ICAgPHNwYW4gY2xhc3NOYW1lPSJ0ZXh0LVsxMHB4XSB0ZXh0LWFwcC1tdXRlZCI+CiAgICAgICAg
ICAgICAgICB7cHJldmlldy5zdGFuZGFyZCA/IGZvcm1hdEV0YShwcmV2aWV3LnN0YW5kYXJkLmV0
YVNlY29uZHMpIDogJ2ZyZWUnfQogICAgICAgICAgICAgIDwvc3Bhbj4KICAgICAgICAgICAgPC9i
dXR0b24+CiAgICAgICAgICA8L2Rpdj4KCiAgICAgICAgICB7IXByZXZpZXcuZmFzdEF2YWlsYWJs
ZSAmJiAhcHJldmlldy5sb2FkaW5nICYmIHByZXZpZXcuc3RhbmRhcmQgJiYgKAogICAgICAgICAg
ICA8cCBjbGFzc05hbWU9Im10LTEuNSBmbGV4IGl0ZW1zLWNlbnRlciBnYXAtMSB0ZXh0LVsxMHB4
XSB0ZXh0LWFwcC1tdXRlZCI+CiAgICAgICAgICAgICAgPEluZm8gY2xhc3NOYW1lPSJoLTMgdy0z
IHNocmluay0wIiAvPgogICAgICAgICAgICAgIEZhc3QgaXNuJ3QgYXZhaWxhYmxlIGZyb20ge2Zy
b20/Lm5hbWV9IC0gc3RhbmRhcmQgYXR0ZXN0YXRpb24gaXMgYWxyZWFkeSBmYXN0IGhlcmUuCiAg
ICAgICAgICAgIDwvcD4KICAgICAgICAgICl9CgogICAgICAgICAgey8qIFF1b3RlIHBhbmVsOiBm
ZWUsIHlvdS1yZWNlaXZlLCBFVEEgZm9yIHRoZSBjaG9zZW4gbW9kZS4gKi99CiAgICAgICAgICA8
ZGl2IGNsYXNzTmFtZT0ibXQtMiBzcGFjZS15LTEgcm91bmRlZC1sZyBib3JkZXIgYm9yZGVyLWFw
cC1ib3JkZXIgYmctYXBwLWJnIHB4LTMgcHktMi41IHRleHQtWzExcHhdIj4KICAgICAgICAgICAg
e3ByZXZpZXcubG9hZGluZyA/ICgKICAgICAgICAgICAgICA8cCBjbGFzc05hbWU9ImZsZXggaXRl
bXMtY2VudGVyIGdhcC0xLjUgdGV4dC1hcHAtbXV0ZWQiPgogICAgICAgICAgICAgICAgPExvYWRl
cjIgY2xhc3NOYW1lPSJoLTMgdy0zIGFuaW1hdGUtc3BpbiIgLz4gRmV0Y2hpbmcgcXVvdGXigKYK
ICAgICAgICAgICAgICA8L3A+CiAgICAgICAgICAgICkgOiBhY3RpdmVRdW90ZSA/ICgKICAgICAg
ICAgICAgICA8PgogICAgICAgICAgICAgICAgPGRpdiBjbGFzc05hbWU9ImZsZXggaXRlbXMtY2Vu
dGVyIGp1c3RpZnktYmV0d2VlbiI+CiAgICAgICAgICAgICAgICAgIDxzcGFuIGNsYXNzTmFtZT0i
dGV4dC1hcHAtbXV0ZWQiPkJyaWRnZSBmZWU8L3NwYW4+CiAgICAgICAgICAgICAgICAgIDxzcGFu
IGNsYXNzTmFtZT0iZm9udC1tb25vIHRleHQtYXBwLXRleHQiPgogICAgICAgICAgICAgICAgICAg
IHthY3RpdmVRdW90ZS5mZWVVbml0cyA+IEJpZ0ludCgwKQogICAgICAgICAgICAgICAgICAgICAg
PyBgJHtmb3JtYXRVbml0cyhhY3RpdmVRdW90ZS5mZWVVbml0cyl9IFVTRENgCiAgICAgICAgICAg
ICAgICAgICAgICA6ICdGcmVlJ30KICAgICAgICAgICAgICAgICAgICB7YWN0aXZlUXVvdGUuZmVl
QnBzID4gMCAmJiAoCiAgICAgICAgICAgICAgICAgICAgICA8c3BhbiBjbGFzc05hbWU9Im1sLTEg
dGV4dC1hcHAtbXV0ZWQiPih7YWN0aXZlUXVvdGUuZmVlQnBzfSBicHMpPC9zcGFuPgogICAgICAg
ICAgICAgICAgICAgICl9CiAgICAgICAgICAgICAgICAgIDwvc3Bhbj4KICAgICAgICAgICAgICAg
IDwvZGl2PgogICAgICAgICAgICAgICAgPGRpdiBjbGFzc05hbWU9ImZsZXggaXRlbXMtY2VudGVy
IGp1c3RpZnktYmV0d2VlbiI+CiAgICAgICAgICAgICAgICAgIDxzcGFuIGNsYXNzTmFtZT0idGV4
dC1hcHAtbXV0ZWQiPllvdSByZWNlaXZlIG9uIHt0bz8ubmFtZX08L3NwYW4+CiAgICAgICAgICAg
ICAgICAgIDxzcGFuIGNsYXNzTmFtZT0iZm9udC1tb25vIGZvbnQtbWVkaXVtIHRleHQtYXBwLXRl
eHQiPgogICAgICAgICAgICAgICAgICAgIHtmb3JtYXRVbml0cyhhY3RpdmVRdW90ZS5yZWNlaXZl
VW5pdHMpfSBVU0RDCiAgICAgICAgICAgICAgICAgIDwvc3Bhbj4KICAgICAgICAgICAgICAgIDwv
ZGl2PgogICAgICAgICAgICAgICAgPGRpdiBjbGFzc05hbWU9ImZsZXggaXRlbXMtY2VudGVyIGp1
c3RpZnktYmV0d2VlbiI+CiAgICAgICAgICAgICAgICAgIDxzcGFuIGNsYXNzTmFtZT0idGV4dC1h
cHAtbXV0ZWQiPkVzdGltYXRlZCB0aW1lPC9zcGFuPgogICAgICAgICAgICAgICAgICA8c3BhbiBj
bGFzc05hbWU9ImZvbnQtbW9ubyB0ZXh0LWFwcC10ZXh0Ij57Zm9ybWF0RXRhKGFjdGl2ZVF1b3Rl
LmV0YVNlY29uZHMpfTwvc3Bhbj4KICAgICAgICAgICAgICAgIDwvZGl2PgogICAgICAgICAgICAg
IDwvPgogICAgICAgICAgICApIDogKAogICAgICAgICAgICAgIDxwIGNsYXNzTmFtZT0idGV4dC1h
cHAtbXV0ZWQiPkVudGVyIGFuIGFtb3VudCB0byBzZWUgdGhlIGZlZSBhbmQgYXJyaXZhbCB0b3Rh
bC48L3A+CiAgICAgICAgICAgICl9CiAgICAgICAgICA8L2Rpdj4KICAgICAgICA8L2Rpdj4KICAg
ICAgKX0KCicnJwplZGl0cy5hcHBlbmQoKAogICAgImluc2VydCB0b2dnbGUrcGFuZWwiLAogICAg
IiAgICAgIHshcm91dGVPayAmJiBmcm9tS2V5ID09PSB0b0tleSAmJiAoIiwKICAgIFRPR0dMRV9B
TkRfUEFORUwgKyAiICAgICAgeyFyb3V0ZU9rICYmIGZyb21LZXkgPT09IHRvS2V5ICYmICgiLAop
KQoKZm9yIGRlc2MsIG9sZCwgbmV3IGluIGVkaXRzOgogICAgbiA9IHNyYy5jb3VudChvbGQpCiAg
ICBpZiBuICE9IDE6CiAgICAgICAgcHJpbnQoZiJFUlJPUjogYW5jaG9yICd7ZGVzY30nIG1hdGNo
ZWQge259IHRpbWVzIChleHBlY3RlZCAxKS4gQWJvcnRpbmcgLSBmaWxlIE5PVCBtb2RpZmllZC4i
KQogICAgICAgIHN5cy5leGl0KDIpCiAgICBzcmMgPSBzcmMucmVwbGFjZShvbGQsIG5ldykKCmlv
Lm9wZW4oUEFUSCwgInciLCBlbmNvZGluZz0idXRmLTgiKS53cml0ZShzcmMpCnByaW50KCIgIFBh
cnQgMyBhcHBsaWVkIHRvIiwgUEFUSCkK
B64_PATCH

verify "$TMP_HOOK"  "$HOOK_SHA"
verify "$TMP_PATCH" "$PATCH_SHA"
log "Both payloads verified."

# ------------------------------------------------------ install the hook ----
if [ -f "$HOOK" ] && grep -qF "$MARK_HOOK" "$HOOK"; then
  log "Hook already present - skipping."
else
  [ -f "$HOOK" ] && cp "$HOOK" "$BACKUP_DIR/useQuotePreview.ts.pre"
  cp "$TMP_HOOK" "$HOOK"
  log "Installed $HOOK"
fi

# ------------------------------------------------------ patch the card ------
if grep -qF "$MARK_CARD" "$CARD"; then
  log "Card already patched - skipping."
else
  cp "$CARD" "$BACKUP_DIR/BridgeCard.tsx"
  python3 "$TMP_PATCH" "$CARD" || { cp "$BACKUP_DIR/BridgeCard.tsx" "$CARD"; die "Card patch failed; restored."; }
  grep -qF "$MARK_CARD" "$CARD" || { cp "$BACKUP_DIR/BridgeCard.tsx" "$CARD"; die "Post-write check failed; restored."; }
  log "Patched $CARD"
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
log "Pushed Part 3. Next: Part 4 (attestation-expiry + failed-mint retry hardening)."
