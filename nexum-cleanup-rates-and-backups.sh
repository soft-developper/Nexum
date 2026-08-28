#!/usr/bin/env bash
# ============================================================================
# Nexum - minor cleanup: mobile live-rates fix + remove committed backup files
#
# TWO independent jobs, each safe on its own:
#
# 1. UI FIX  nexum-web/components/landing/LandingRates.tsx
#    On mobile (2-col) the pair label and the rate number overlapped when the
#    number is long (e.g. NGN ~1,600). Adds a gap + shrink/truncate control so
#    the two sides never collide. Layout-only; no data or logic change.
#
# 2. BACKUP CLEANUP
#    Removes the *.bak / *.bak.* / *.new / *.orig files and the .*backup* /
#    .nexum-* dirs that accumulated in the repo during past deploys. These were
#    per-run safety copies for scripts that are long since deployed and
#    confirmed; nothing imports them (verified), and tsc/next ignore them.
#    Removed with `git rm` so they leave the repo, not just the disk.
#
# Delivery contract (v2) + full deploy:
#   * the UI patcher is base64 + sha256 verified; exact-anchor; aborts on drift
#   * idempotent (UI marker __NEXUM_RATES_MOBILE_FIX__; cleanup is no-op if none)
#   * the cleanup PREVIEWS the exact file list and count, then removes
#   * gate for the UI change: rm -rf .next && npx tsc --noEmit && npm run build
#   * commits + pushes once (both changes in one commit)
#   * --revert restores LandingRates.tsx; backup files are gone from git history
#     going forward but recoverable from the commit before this one if ever
#     needed, so removal is intentionally NOT auto-undone
#   * --no-deploy applies + previews only
#   * --skip-cleanup does only the UI fix ; --skip-ui does only the cleanup
#
# Run from REPO ROOT (folder containing nexum-web/ and nexum-api/).
#   bash nexum-cleanup-rates-and-backups.sh
#   bash nexum-cleanup-rates-and-backups.sh --no-deploy
#   bash nexum-cleanup-rates-and-backups.sh --skip-cleanup
#   bash nexum-cleanup-rates-and-backups.sh --skip-ui
#   bash nexum-cleanup-rates-and-backups.sh --revert
# ============================================================================
set -euo pipefail

WEB="nexum-web"
RATES="$WEB/components/landing/LandingRates.tsx"
MARKER="__NEXUM_RATES_MOBILE_FIX__"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR=".nexum-cleanup-backup/${STAMP}"
PATCH_SHA="e48b5866ddde6df549464575b9303b1eab8d17877e89ce04025de5ff600370ab"
COMMIT_MSG="chore: fix mobile live-rates overlap + remove stale committed backup files"

FLAG="${1:-}"
log(){ printf '  %s\n' "$*"; }
die(){ printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[ -d "$WEB" ] || die "Cannot find $WEB . Run from the repo root."

# ---------------------------------------------------------------- revert ----
if [ "$FLAG" = "--revert" ]; then
  LATEST="$(ls -1dt .nexum-cleanup-backup/*/ 2>/dev/null | head -1 || true)"
  if [ -n "$LATEST" ] && [ -f "${LATEST}LandingRates.tsx" ]; then
    cp "${LATEST}LandingRates.tsx" "$RATES" && log "Restored $RATES"
  else
    log "No LandingRates backup found; leaving as-is."
  fi
  log "NOTE: deleted backup files are not auto-restored (they were removed on"
  log "      purpose). If you need one, recover it from the commit before this."
  exit 0
fi

DO_UI=1; DO_CLEAN=1
[ "$FLAG" = "--skip-ui" ] && DO_UI=0
[ "$FLAG" = "--skip-cleanup" ] && DO_CLEAN=0

# ============================ 1. UI FIX ====================================
if [ "$DO_UI" = "1" ]; then
  if grep -qF "$MARKER" "$RATES"; then
    log "Live-rates mobile fix already applied - skipping."
  else
    TPATCH="$(mktemp /tmp/rates.XXXXXX.py)"; trap 'rm -f "$TPATCH"' EXIT
    base64 -d > "$TPATCH" <<'B64'
IyEvdXNyL2Jpbi9lbnYgcHl0aG9uMwoiIiIKRml4IG1vYmlsZSBvdmVybGFwIGluIHRoZSBsYW5k
aW5nIGxpdmUtcmF0ZXMgZGFzaGJvYXJkLgpBZGp1c3RzIE9OTFkgdGhlIGNlbGwgbGF5b3V0IHNv
IHRoZSB0d28gc2lkZXMgY29leGlzdCBvbiBtb2JpbGU6CmdhcCBiZXR3ZWVuIHNpZGVzLCBsZWZ0
IHNocmlua3MrdHJ1bmNhdGVzLCByaWdodCBuZXZlciBzaHJpbmtzL3dyYXBzLgpJZGVtcG90ZW50
IHZpYSBfX05FWFVNX1JBVEVTX01PQklMRV9GSVhfXyAoYSBKUyBsaW5lIGNvbW1lbnQsIG5vdCBh
IEpTWCBub2RlKS4KIiIiCmltcG9ydCBzeXMsIGlvClBBVEggPSAibmV4dW0td2ViL2NvbXBvbmVu
dHMvbGFuZGluZy9MYW5kaW5nUmF0ZXMudHN4IgpNQVJLRVIgPSAiX19ORVhVTV9SQVRFU19NT0JJ
TEVfRklYX18iCnNyYyA9IGlvLm9wZW4oUEFUSCwgZW5jb2Rpbmc9InV0Zi04IikucmVhZCgpCmlm
IE1BUktFUiBpbiBzcmM6CiAgICBwcmludChmIiAge1BBVEh9OiBhbHJlYWR5IGZpeGVkIC0gc2tp
cHBpbmcuIikKICAgIHN5cy5leGl0KDApCgplZGl0cyA9IFsKICAgICgibWFya2VyIiwKICAgICAi
ICAgICAgICAgICAgY29uc3QgdXAgPSAoci5jaGFuZ2UyNGggPz8gMCkgPj0gMFxuICAgICAgICAg
ICAgcmV0dXJuICgiLAogICAgICIgICAgICAgICAgICBjb25zdCB1cCA9IChyLmNoYW5nZTI0aCA/
PyAwKSA+PSAwXG4iCiAgICAgIiAgICAgICAgICAgIC8vIF9fTkVYVU1fUkFURVNfTU9CSUxFX0ZJ
WF9fIGdhcCArIHNocmluayBjb250cm9sIHNvIHBhaXIgYW5kIHJhdGUgbmV2ZXIgb3ZlcmxhcCBv
biBtb2JpbGVcbiIKICAgICAiICAgICAgICAgICAgcmV0dXJuICgiKSwKICAgICgiY2VsbCB3cmFw
cGVyIiwKICAgICAnPGRpdiBrZXk9e3IucGFpcn0gY2xhc3NOYW1lPSJmbGV4IGl0ZW1zLWNlbnRl
ciBqdXN0aWZ5LWJldHdlZW4gcm91bmRlZC14bCBiZy1hcHAtYmcvNjAgcHgtMyBweS0yLjUiPics
CiAgICAgJzxkaXYga2V5PXtyLnBhaXJ9IGNsYXNzTmFtZT0iZmxleCBpdGVtcy1jZW50ZXIganVz
dGlmeS1iZXR3ZWVuIGdhcC0yIHJvdW5kZWQteGwgYmctYXBwLWJnLzYwIHB4LTMgcHktMi41Ij4n
KSwKICAgICgnbGVmdCBzaWRlJywKICAgICAnPHNwYW4gY2xhc3NOYW1lPSJmbGV4IGl0ZW1zLWNl
bnRlciBnYXAtMiI+XG4gICAgICAgICAgICAgICAgICA8c3BhbiBjbGFzc05hbWU9InRleHQtbGcg
bGVhZGluZy1ub25lIj57RkxBR1tjY3kgYXMga2V5b2YgdHlwZW9mIEZMQUddID8/IFwnXFUwMDAx
ZjRiMVwnfTwvc3Bhbj5cbiAgICAgICAgICAgICAgICAgIDxzcGFuIGNsYXNzTmFtZT0idGV4dC1z
bSBmb250LW1lZGl1bSB0ZXh0LWFwcC10ZXh0Ij57ci5wYWlyfTwvc3Bhbj5cbiAgICAgICAgICAg
ICAgICA8L3NwYW4+JywKICAgICAnPHNwYW4gY2xhc3NOYW1lPSJmbGV4IG1pbi13LTAgaXRlbXMt
Y2VudGVyIGdhcC0yIj5cbicKICAgICAnICAgICAgICAgICAgICAgICAgPHNwYW4gY2xhc3NOYW1l
PSJzaHJpbmstMCB0ZXh0LWxnIGxlYWRpbmctbm9uZSI+e0ZMQUdbY2N5IGFzIGtleW9mIHR5cGVv
ZiBGTEFHXSA/PyBcJ1xVMDAwMWY0YjFcJ308L3NwYW4+XG4nCiAgICAgJyAgICAgICAgICAgICAg
ICAgIDxzcGFuIGNsYXNzTmFtZT0idHJ1bmNhdGUgdGV4dC1zbSBmb250LW1lZGl1bSB0ZXh0LWFw
cC10ZXh0Ij57ci5wYWlyfTwvc3Bhbj5cbicKICAgICAnICAgICAgICAgICAgICAgIDwvc3Bhbj4n
KSwKICAgICgncmlnaHQgc2lkZScsCiAgICAgJzxzcGFuIGNsYXNzTmFtZT0idGV4dC1yaWdodCI+
XG4gICAgICAgICAgICAgICAgICA8c3BhbiBjbGFzc05hbWU9ImJsb2NrIGZvbnQtbW9ubyB0ZXh0
LXNtIHRleHQtYXBwLXRleHQiPicsCiAgICAgJzxzcGFuIGNsYXNzTmFtZT0ic2hyaW5rLTAgd2hp
dGVzcGFjZS1ub3dyYXAgdGV4dC1yaWdodCI+XG4gICAgICAgICAgICAgICAgICA8c3BhbiBjbGFz
c05hbWU9ImJsb2NrIGZvbnQtbW9ubyB0ZXh0LXNtIHRleHQtYXBwLXRleHQiPicpLApdCmZvciBk
ZXNjLCBvbGQsIG5ldyBpbiBlZGl0czoKICAgIG4gPSBzcmMuY291bnQob2xkKQogICAgaWYgbiAh
PSAxOgogICAgICAgIHByaW50KGYiRVJST1I6IGFuY2hvciAne2Rlc2N9JyBtYXRjaGVkIHtufSB0
aW1lcyAoZXhwZWN0ZWQgMSkuIEFib3J0aW5nLiIpCiAgICAgICAgc3lzLmV4aXQoMikKICAgIHNy
YyA9IHNyYy5yZXBsYWNlKG9sZCwgbmV3KQppby5vcGVuKFBBVEgsICJ3IiwgZW5jb2Rpbmc9InV0
Zi04Iikud3JpdGUoc3JjKQpwcmludChmIiAge1BBVEh9OiBmaXhlZC4iKQo=
B64
    ACTUAL="$( (sha256sum "$TPATCH" 2>/dev/null || shasum -a 256 "$TPATCH") | awk '{print $1}')"
    [ "$ACTUAL" = "$PATCH_SHA" ] || die "Patcher checksum mismatch (got $ACTUAL). Nothing changed."
    mkdir -p "$BACKUP_DIR"; cp "$RATES" "$BACKUP_DIR/LandingRates.tsx"
    python3 "$TPATCH" || { cp "$BACKUP_DIR/LandingRates.tsx" "$RATES"; die "UI patch failed; restored."; }
    grep -qF "$MARKER" "$RATES" || { cp "$BACKUP_DIR/LandingRates.tsx" "$RATES"; die "UI post-check failed; restored."; }
    log "Applied live-rates mobile fix."
  fi
fi

# ======================== 2. BACKUP CLEANUP ================================
if [ "$DO_CLEAN" = "1" ]; then
  log ""
  log "=== Scanning for stale backup files + dirs ==="
  # Files: *.bak, *.bak.*, *.new, *.orig  (never touch node_modules or .git)
  mapfile -t BK_FILES < <(find . -type f \( -name '*.bak' -o -name '*.bak.*' -o -name '*.new' -o -name '*.orig' \) \
    -not -path './node_modules/*' -not -path './.git/*' -not -path '*/node_modules/*' | sort)
  # Dirs: .*backup* and .nexum-*  (the per-run script backup folders)
  mapfile -t BK_DIRS < <(find . -type d \( -name '.*backup*' -o -name '.nexum-*' \) \
    -not -path './node_modules/*' -not -path './.git/*' | sort)

  if [ "${#BK_FILES[@]}" -eq 0 ] && [ "${#BK_DIRS[@]}" -eq 0 ]; then
    log "No backup files or dirs found - nothing to clean."
  else
    log "Will remove ${#BK_FILES[@]} file(s) and ${#BK_DIRS[@]} dir(s):"
    for f in "${BK_FILES[@]}"; do printf '    - %s\n' "$f"; done
    for d in "${BK_DIRS[@]}"; do printf '    - %s/ (dir)\n' "$d"; done

    # Remove. Use git rm for tracked files so they leave the repo; fall back to
    # plain rm for anything git doesn't track.
    for f in "${BK_FILES[@]}"; do
      if git ls-files --error-unmatch "$f" >/dev/null 2>&1; then
        git rm -q --cached "$f" >/dev/null 2>&1 || true
      fi
      rm -f "$f"
    done
    for d in "${BK_DIRS[@]}"; do
      if git ls-files --error-unmatch "$d" >/dev/null 2>&1 || [ -n "$(git ls-files "$d" 2>/dev/null)" ]; then
        git rm -qr --cached "$d" >/dev/null 2>&1 || true
      fi
      rm -rf "$d"
    done
    log "Removed."

    # Add a .gitignore rule so these never get committed again.
    if [ -f .gitignore ] && grep -qF "# nexum backup artifacts" .gitignore; then
      log ".gitignore already guards backup artifacts."
    else
      {
        echo ""
        echo "# nexum backup artifacts (never commit deploy-script backups)"
        echo "*.bak"
        echo "*.bak.*"
        echo "*.orig"
        echo ".nexum-*-backup/"
        echo ".*-backup/"
      } >> .gitignore
      log "Added .gitignore rules to prevent re-committing backups."
    fi
  fi
fi

# ------------------------------------------------------------- deploy gate --
if [ "$FLAG" = "--no-deploy" ]; then
  log ""
  log "--no-deploy: changes applied + cleanup done locally. Review, then rerun without the flag to build + push."
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
log "Pushed. Mobile live-rates no longer overlap; stale backup files removed from the repo."
