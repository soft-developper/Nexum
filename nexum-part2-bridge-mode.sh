#!/usr/bin/env bash
# ============================================================================
# Nexum bridge upgrade - PART 2 of 4: Fast/Standard mode in useBridge
#
# Wires transfer mode into nexum-web/hooks/useBridge.ts:
#   * bridge() accepts  mode?: 'fast' | 'standard'  (defaults to 'fast')
#   * resolves a live quote via getTransferQuote (Part 1 engine)
#   * burn sends the mode-correct maxFee + minFinalityThreshold (1000/2000)
#   * BridgeState exposes { mode, quote } for the UI (Part 3)
#   * Fast auto-degrades to Standard on chains where Circle disables it
#
# REQUIRES Part 1 already applied (the quote engine in cctp-client.ts).
#
# Delivery contract (your v2 spec) + full deploy:
#   * embedded patcher is base64 + sha256 verified before it runs
#   * exact-anchor edits: a drifted file aborts clean, never half-patched
#   * idempotent (marker __NEXUM_BRIDGE_MODE__); re-run is a no-op
#   * timestamped backup of the original file
#   * deploy GATE: rm -rf .next && npx tsc --noEmit && npm run build
#     -> commits + pushes ONLY if all three pass
#   * --revert restores the file from backup
#   * --no-deploy applies the edit but skips build/commit/push
#
# Run from the REPO ROOT (the folder containing nexum-web/).
#
# Usage:
#   bash nexum-part2-bridge-mode.sh              # apply + build + push
#   bash nexum-part2-bridge-mode.sh --no-deploy  # apply only
#   bash nexum-part2-bridge-mode.sh --revert     # undo the file edit
# ============================================================================
set -euo pipefail

TARGET="nexum-web/hooks/useBridge.ts"
MARKER="__NEXUM_BRIDGE_MODE__"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR=".nexum-part2-backup/${STAMP}"
EXPECT_SHA="e761bbadc8273500c1724e3697e28e25ef488422ca40958ecefecb4d0dc33eb6"
COMMIT_MSG="feat(bridge): Fast/Standard transfer mode in useBridge (Part 2)"

MODE_FLAG="${1:-}"

log(){ printf '  %s\n' "$*"; }
die(){ printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[ -f "$TARGET" ] || die "Cannot find $TARGET . Run from the repo root (the folder that contains nexum-web/)."

# ---------------------------------------------------------------- revert ----
if [ "$MODE_FLAG" = "--revert" ]; then
  LATEST="$(ls -1dt .nexum-part2-backup/*/ 2>/dev/null | head -1 || true)"
  [ -n "$LATEST" ] && [ -f "${LATEST}useBridge.ts" ] || die "No Part 2 backup found to revert from."
  cp "${LATEST}useBridge.ts" "$TARGET"
  log "Reverted $TARGET from ${LATEST}useBridge.ts"
  exit 0
fi

# ------------------------------------------- Part 1 present precondition -----
if ! grep -qF "__NEXUM_CCTP_QUOTE_ENGINE__" "nexum-web/lib/cctp-client.ts"; then
  die "Part 1 quote engine not found in cctp-client.ts. Apply Part 1 first."
fi

# --------------------------------------------------------------- idempotent -
if grep -qF "$MARKER" "$TARGET"; then
  log "Part 2 already applied to $TARGET - skipping edit."
else
  # ------------------------------------- decode + verify the patcher --------
  TMP_PATCH="$(mktemp /tmp/nexum-part2.XXXXXX.py)"
  trap 'rm -f "$TMP_PATCH"' EXIT
  base64 -d > "$TMP_PATCH" <<'B64'
IyEvdXNyL2Jpbi9lbnYgcHl0aG9uMwoiIiIKUGFydCAyIHBhdGNoZXIgZm9yIG5leHVtLXdlYi9o
b29rcy91c2VCcmlkZ2UudHMKCkFkZHMgRmFzdC9TdGFuZGFyZCBtb2RlIHN1cHBvcnQgdG8gdGhl
IGJyaWRnZSBob29rOgogICogaW1wb3J0IGdldFRyYW5zZmVyUXVvdGUgKyBUcmFuc2Zlck1vZGUg
KGtlZXAgdG9Vbml0cywgZmV0Y2hBdHRlc3RhdGlvbikKICAqIEJyaWRnZVN0YXRlIGdhaW5zIGBt
b2RlYCBhbmQgYHF1b3RlYAogICogSU5JVElBTCBzZWVkcyB0aGVtCiAgKiBicmlkZ2UoKSBhY2Nl
cHRzIGBtb2RlPzogVHJhbnNmZXJNb2RlYCAoZGVmYXVsdCAnZmFzdCcpCiAgKiB0aGUgYnVybiBy
ZXNvbHZlcyBhIHF1b3RlIHZpYSBnZXRUcmFuc2ZlclF1b3RlIGFuZCBwYXNzZXMgdGhlCiAgICBt
b2RlLWNvcnJlY3QgbWF4RmVlICsgbWluRmluYWxpdHlUaHJlc2hvbGQgKDEwMDAgZmFzdCAvIDIw
MDAgc3RhbmRhcmQpCiAgKiB0aGUgcmVzb2x2ZWQgbW9kZSArIHF1b3RlIGFyZSB3cml0dGVuIHRv
IHN0YXRlIGZvciB0aGUgVUkgKFBhcnQgMykKICAqIGBtb2RlYCBpcyBzZW50IGluIHRoZSAvYnJp
ZGdlIGNyZWF0ZSBwYXlsb2FkIChBUEkgaWdub3JlcyBpdCBmb3Igbm93KQoKSWRlbXBvdGVudDog
a2V5ZWQgb2ZmIHRoZSBfX05FWFVNX0JSSURHRV9NT0RFX18gbWFya2VyLiBSZS1ydW5uaW5nIGlz
IGEgbm8tb3AuCkV4YWN0LW1hdGNoIGVkaXRzOiBpZiBhbnkgYW5jaG9yIGlzIG1pc3NpbmcgdGhl
IHNjcmlwdCBhYm9ydHMgd2l0aG91dCB3cml0aW5nLApzbyBhIGRyaWZ0ZWQgZmlsZSBjYW4gbmV2
ZXIgYmUgaGFsZi1wYXRjaGVkLgoiIiIKaW1wb3J0IHN5cywgaW8KClBBVEggPSBzeXMuYXJndlsx
XSBpZiBsZW4oc3lzLmFyZ3YpID4gMSBlbHNlICJuZXh1bS13ZWIvaG9va3MvdXNlQnJpZGdlLnRz
IgpNQVJLRVIgPSAiX19ORVhVTV9CUklER0VfTU9ERV9fIgoKc3JjID0gaW8ub3BlbihQQVRILCBl
bmNvZGluZz0idXRmLTgiKS5yZWFkKCkKCmlmIE1BUktFUiBpbiBzcmM6CiAgICBwcmludCgiICBQ
YXJ0IDIgYWxyZWFkeSBhcHBsaWVkIC0gbm90aGluZyB0byBkby4iKQogICAgc3lzLmV4aXQoMCkK
CmVkaXRzID0gW10gICMgKGRlc2NyaXB0aW9uLCBvbGQsIG5ldykgLSBlYWNoIG9sZCBtdXN0IGFw
cGVhciBleGFjdGx5IG9uY2UKCiMgMS4gSW1wb3J0OiBhZGQgZ2V0VHJhbnNmZXJRdW90ZSArIFRy
YW5zZmVyTW9kZTsgZHJvcCBnZXRCdXJuRmVlL0ZJTkFMSVRZIHVzZS4KZWRpdHMuYXBwZW5kKCgK
ICAgICJpbXBvcnQiLAogICAgImltcG9ydCB7XG4gIGdldEJ1cm5GZWUsIGZldGNoQXR0ZXN0YXRp
b24sIHRvVW5pdHMsIEZJTkFMSVRZLFxufSBmcm9tICdAL2xpYi9jY3RwLWNsaWVudCciLAogICAg
ImltcG9ydCB7XG4gIC8vIF9fTkVYVU1fQlJJREdFX01PREVfXyAocGFydDIpIEZhc3QvU3RhbmRh
cmQgc3VwcG9ydFxuICBnZXRUcmFuc2ZlclF1b3RlLCBmZXRjaEF0dGVzdGF0aW9uLCB0b1VuaXRz
LFxuICB0eXBlIFRyYW5zZmVyTW9kZSwgdHlwZSBUcmFuc2ZlclF1b3RlLFxufSBmcm9tICdAL2xp
Yi9jY3RwLWNsaWVudCciLAopKQoKIyAyLiBCcmlkZ2VTdGF0ZTogYWRkIG1vZGUgKyBxdW90ZSBm
aWVsZHMuCmVkaXRzLmFwcGVuZCgoCiAgICAiQnJpZGdlU3RhdGUgZmllbGRzIiwKICAgICIgIC8q
KiBBIGh1bWFuIHN0ZXAgbWVzc2FnZSB3aGlsZSB0aGUgdXNlciBhcHByb3ZlcyBvbiB0aGVpciBk
ZXZpY2UuICovXG4gIG5vdGU6ICAgICBzdHJpbmcgfCBudWxsXG59IiwKICAgICIgIC8qKiBBIGh1
bWFuIHN0ZXAgbWVzc2FnZSB3aGlsZSB0aGUgdXNlciBhcHByb3ZlcyBvbiB0aGVpciBkZXZpY2Uu
ICovXG4gIG5vdGU6ICAgICBzdHJpbmcgfCBudWxsXG4gIC8qKiBUaGUgdHJhbnNmZXIgbW9kZSBh
Y3R1YWxseSB1c2VkIGZvciB0aGlzIGJyaWRnZSAoZmFzdCBtYXkgZGVncmFkZSB0byBzdGFuZGFy
ZCkuICovXG4gIG1vZGU6ICAgICBUcmFuc2Zlck1vZGVcbiAgLyoqIFRoZSByZXNvbHZlZCBmZWUg
cXVvdGUsIHNvIHRoZSBVSSBjYW4gc2hvdyBmZWUgKyB5b3UtcmVjZWl2ZSArIEVUQS4gKi9cbiAg
cXVvdGU6ICAgIFRyYW5zZmVyUXVvdGUgfCBudWxsXG59IiwKKSkKCiMgMy4gSU5JVElBTDogc2Vl
ZCBtb2RlICsgcXVvdGUuCmVkaXRzLmFwcGVuZCgoCiAgICAiSU5JVElBTCIsCiAgICAiICBlcnJv
cjogbnVsbCwgaW5GbGlnaHQ6IGZhbHNlLCB3YWl0ZWRTZWM6IDAsIG5vdGU6IG51bGwsXG59IiwK
ICAgICIgIGVycm9yOiBudWxsLCBpbkZsaWdodDogZmFsc2UsIHdhaXRlZFNlYzogMCwgbm90ZTog
bnVsbCxcbiAgbW9kZTogJ2Zhc3QnLCBxdW90ZTogbnVsbCxcbn0iLAopKQoKIyA0LiBicmlkZ2Uo
KSBwYXJhbXM6IGFjY2VwdCBtb2RlLgplZGl0cy5hcHBlbmQoKAogICAgImJyaWRnZSBwYXJhbXMi
LAogICAgIiAgY29uc3QgYnJpZGdlID0gdXNlQ2FsbGJhY2soYXN5bmMgKHBhcmFtczoge1xuICAg
IGZyb21LZXk6IHN0cmluZ1xuICAgIHRvS2V5OiAgIHN0cmluZ1xuICAgIGFtb3VudDogIG51bWJl
clxuICAgIHJlY2lwaWVudD86IHN0cmluZ1xuICB9KSA9PiB7IiwKICAgICIgIGNvbnN0IGJyaWRn
ZSA9IHVzZUNhbGxiYWNrKGFzeW5jIChwYXJhbXM6IHtcbiAgICBmcm9tS2V5OiBzdHJpbmdcbiAg
ICB0b0tleTogICBzdHJpbmdcbiAgICBhbW91bnQ6ICBudW1iZXJcbiAgICByZWNpcGllbnQ/OiBz
dHJpbmdcbiAgICAvKiogRmFzdCAoZGVmYXVsdCkgb3IgU3RhbmRhcmQuIEZhc3QgYXV0by1kZWdy
YWRlcyB3aGVyZSB1bnN1cHBvcnRlZC4gKi9cbiAgICBtb2RlPzogVHJhbnNmZXJNb2RlXG4gIH0p
ID0+IHsiLAopKQoKIyA1LiByZXNldCBJTklUSUFMIHN0ZXA6IGFsc28gcmVzZXQgd2l0aCByZXF1
ZXN0ZWQgbW9kZSBzbyBVSSByZWZsZWN0cyBjaG9pY2UgZWFybHkuCmVkaXRzLmFwcGVuZCgoCiAg
ICAiY3JlYXRpbmcgc3RhdGUgc2VlZHMgbW9kZSIsCiAgICAiICAgICAgc2V0U3RhdGUoeyAuLi5J
TklUSUFMLCBzdGVwOiAnY3JlYXRpbmcnIH0pIiwKICAgICIgICAgICBjb25zdCByZXF1ZXN0ZWRN
b2RlOiBUcmFuc2Zlck1vZGUgPSBwYXJhbXMubW9kZSA/PyAnZmFzdCdcbiAgICAgIHNldFN0YXRl
KHsgLi4uSU5JVElBTCwgc3RlcDogJ2NyZWF0aW5nJywgbW9kZTogcmVxdWVzdGVkTW9kZSB9KSIs
CikpCgojIDYuIGNyZWF0ZSBwYXlsb2FkOiBzZW5kIG1vZGUgKEFQSSBjdXJyZW50bHkgaWdub3Jl
cyB1bmtub3duIGZpZWxkcykuCmVkaXRzLmFwcGVuZCgoCiAgICAiY3JlYXRlIHBheWxvYWQgbW9k
ZSIsCiAgICAiICAgICAgICBhbW91bnQ6IHBhcmFtcy5hbW91bnQsIHJlY2lwaWVudCxcbiAgICAg
IH0pIiwKICAgICIgICAgICAgIGFtb3VudDogcGFyYW1zLmFtb3VudCwgcmVjaXBpZW50LFxuICAg
ICAgICBtb2RlOiByZXF1ZXN0ZWRNb2RlLFxuICAgICAgfSkiLAopKQoKIyA3LiBmZWUgLT4gcXVv
dGUsIGFuZCBidXJuIHBhcmFtcyB1c2UgbW9kZS1jb3JyZWN0IG1heEZlZSArIHRocmVzaG9sZC4K
ZWRpdHMuYXBwZW5kKCgKICAgICJmZWUgY2FsbCAtPiBxdW90ZSIsCiAgICAiICAgICAgY29uc3Qg
ZmVlID0gYXdhaXQgZ2V0QnVybkZlZShpcmlzQmFzZSgpLCBmcm9tLmRvbWFpbiwgdG8uZG9tYWlu
LCBhbW91bnRVbml0cykiLAogICAgIiAgICAgIC8qXG4gICAgICAgIFJlc29sdmUgYSBGYXN0L1N0
YW5kYXJkIHF1b3RlLiBnZXRUcmFuc2ZlclF1b3RlIHJlYWRzIENpcmNsZSdzIGxpdmVcbiAgICAg
ICAgZmVlIHRhYmxlIGFuZCByZXR1cm5zIHRoZSBtb2RlLWNvcnJlY3QgbWF4RmVlIHBsdXMgdGhl
IGZpbmFsaXR5XG4gICAgICAgIHRocmVzaG9sZCB0byBzZW5kLiBGYXN0IHNpbGVudGx5IGRlZ3Jh
ZGVzIHRvIFN0YW5kYXJkIG9uIHNvdXJjZSBjaGFpbnNcbiAgICAgICAgd2hlcmUgQ2lyY2xlIGRp
c2FibGVzIEZhc3QgKHF1b3RlLm1vZGUgdGVsbHMgdXMgd2hhdCBhY3R1YWxseSBhcHBsaWVzKS5c
biAgICAgICovXG4gICAgICBjb25zdCBxdW90ZSA9IGF3YWl0IGdldFRyYW5zZmVyUXVvdGUoe1xu
ICAgICAgICBpcmlzQmFzZTogICAgaXJpc0Jhc2UoKSxcbiAgICAgICAgZnJvbUtleTogICAgIGZy
b20ua2V5LFxuICAgICAgICBmcm9tRG9tYWluOiAgZnJvbS5kb21haW4sXG4gICAgICAgIHRvRG9t
YWluOiAgICB0by5kb21haW4sXG4gICAgICAgIGFtb3VudFVuaXRzLFxuICAgICAgICBtb2RlOiAg
ICAgICAgcmVxdWVzdGVkTW9kZSxcbiAgICAgIH0pXG4gICAgICBjb25zdCBmaW5hbGl0eVRocmVz
aG9sZCA9IHF1b3RlLm1vZGUgPT09ICdmYXN0JyA/IDEwMDAgOiAyMDAwXG4gICAgICBzZXRTdGF0
ZShzID0+ICh7IC4uLnMsIG1vZGU6IHF1b3RlLm1vZGUsIHF1b3RlIH0pKSIsCikpCgojIDguIGJ1
cm4gYWJpUGFyYW1ldGVyczogbWF4RmVlICsgdGhyZXNob2xkIGZyb20gcXVvdGUuCmVkaXRzLmFw
cGVuZCgoCiAgICAiYnVybiBtYXhGZWUiLAogICAgIiAgICAgICAgICBmZWUubWF4RmVlVW5pdHMu
dG9TdHJpbmcoKSxcbiAgICAgICAgICBGSU5BTElUWS5GSU5BTElaRUQsIiwKICAgICIgICAgICAg
ICAgcXVvdGUubWF4RmVlVW5pdHMudG9TdHJpbmcoKSxcbiAgICAgICAgICBmaW5hbGl0eVRocmVz
aG9sZCwiLAopKQoKIyBhcHBseQpmb3IgZGVzYywgb2xkLCBuZXcgaW4gZWRpdHM6CiAgICBuID0g
c3JjLmNvdW50KG9sZCkKICAgIGlmIG4gIT0gMToKICAgICAgICBwcmludChmIkVSUk9SOiBhbmNo
b3IgJ3tkZXNjfScgbWF0Y2hlZCB7bn0gdGltZXMgKGV4cGVjdGVkIDEpLiBBYm9ydGluZyAtIGZp
bGUgTk9UIG1vZGlmaWVkLiIpCiAgICAgICAgc3lzLmV4aXQoMikKICAgIHNyYyA9IHNyYy5yZXBs
YWNlKG9sZCwgbmV3KQoKaW8ub3BlbihQQVRILCAidyIsIGVuY29kaW5nPSJ1dGYtOCIpLndyaXRl
KHNyYykKcHJpbnQoIiAgUGFydCAyIGFwcGxpZWQgdG8iLCBQQVRIKQo=
B64
  ACTUAL_SHA="$( (sha256sum "$TMP_PATCH" 2>/dev/null || shasum -a 256 "$TMP_PATCH") | awk '{print $1}')"
  [ "$ACTUAL_SHA" = "$EXPECT_SHA" ] || die "Patcher checksum mismatch (got $ACTUAL_SHA). Your file was NOT modified."
  log "Patcher verified (sha256 $ACTUAL_SHA)."

  mkdir -p "$BACKUP_DIR"
  cp "$TARGET" "$BACKUP_DIR/useBridge.ts"
  log "Backed up original to $BACKUP_DIR/useBridge.ts"

  python3 "$TMP_PATCH" "$TARGET" || { cp "$BACKUP_DIR/useBridge.ts" "$TARGET"; die "Patch failed; original restored."; }

  grep -qF "$MARKER" "$TARGET" || { cp "$BACKUP_DIR/useBridge.ts" "$TARGET"; die "Post-write marker check failed; original restored."; }
  log "Applied Part 2 to $TARGET."
fi

# ------------------------------------------------------------- deploy gate --
if [ "$MODE_FLAG" = "--no-deploy" ]; then
  log "--no-deploy set: skipping build + git. Review, then run without the flag to ship."
  exit 0
fi

log ""
log "=== Deploy gate: clean typecheck + build, then commit + push ==="
( cd nexum-web && rm -rf .next && npx tsc --noEmit ) || die "tsc failed - not committing."
log "tsc clean."
( cd nexum-web && npm run build ) || die "next build failed - not committing."
log "build clean."

# git safety: must be a work tree with a remote; never force-push
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "Not a git work tree; skipping git. (Files are applied + built.)"
REMOTE="$(git remote | head -1 || true)"
[ -n "$REMOTE" ] || die "No git remote configured; skipping push. Commit manually if you like."
BRANCH="$(git rev-parse --abbrev-ref HEAD)"

git add -A
if git diff --cached --quiet; then
  log "Nothing staged to commit (already committed?). Skipping commit/push."
  exit 0
fi
log "Committing on branch '$BRANCH' to remote '$REMOTE'..."
git commit -m "$COMMIT_MSG"
git push "$REMOTE" "$BRANCH"
log ""
log "Pushed Part 2. Next: Part 3 (bridge UI - Fast/Standard toggle + live quote panel)."
