#!/usr/bin/env bash
#
# fix-remove-mdash-entity-ramp.sh
#
# WHAT: Replaces the single HTML entity em-dash (&mdash;) in the offramp bank
#       details copy with a plain hyphen '-'.
#
# WHY:  The earlier raw-codepoint sweep (perl s/\x{2014}/-/) could not see this
#       one because it is entity-encoded ASCII (&mdash;), not the U+2014 byte.
#       The browser renders &mdash; as an em-dash, so it looked identical on the
#       page while being invisible to a codepoint grep. This is the last dash of
#       any kind in the source tree (raw codepoints already zero, verified).
#
# SCOPE: web only, ONE file, ONE line. Anchored byte-exact replacement.
#
# DELIVERY: v2 - anchored single-replace (assert count==1), backup-once-per-run,
#           idempotent marker guard, --revert restores newest backup.
#
# USAGE:
#   bash fix-remove-mdash-entity-ramp.sh          # apply
#   bash fix-remove-mdash-entity-ramp.sh --revert # restore newest backup
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_ROOT"

TARGET="nexum-web/app/(app)/ramp/page.tsx"
STAMP="$(date +%Y%m%d-%H%M%S)"

OLD='straight to our payments partner &mdash; Nexum never stores your account number.'
NEW='straight to our payments partner - Nexum never stores your account number.'

# ----- revert -----
if [ "${1:-}" = "--revert" ]; then
  newest="$(ls -1t "$TARGET".bak.* 2>/dev/null | head -1 || true)"
  if [ -z "$newest" ]; then
    echo "revert: no backup found for $TARGET"
    exit 1
  fi
  cp "$newest" "$TARGET"
  echo "reverted $TARGET from $newest"
  exit 0
fi

# ----- preflight -----
if [ ! -f "$TARGET" ]; then
  echo "ABORT: target not found: $TARGET" >&2
  exit 1
fi

# ----- idempotency guard -----
if ! grep -qF '&mdash;' "$TARGET"; then
  echo "already clean: no &mdash; entity in $TARGET - nothing to do"
  exit 0
fi

# ----- anchored byte-exact replacement (assert exactly one match) -----
python3 - "$TARGET" "$OLD" "$NEW" "$STAMP" <<'PY'
import sys
path, old, new, stamp = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
with open(path, encoding="utf-8") as f:
    s = f.read()

n = s.count(old)
if n != 1:
    sys.stderr.write(f"ABORT: expected exactly 1 anchor in {path}, found {n}. No change made.\n")
    sys.exit(1)

# backup once per run
bak = f"{path}.bak.{stamp}"
import os
if not os.path.exists(bak):
    with open(bak, "w", encoding="utf-8") as b:
        b.write(s)

s2 = s.replace(old, new)

if "&mdash;" in s2:
    sys.stderr.write("ABORT: residual &mdash; after replace - restoring untouched.\n")
    sys.exit(1)

with open(path, "w", encoding="utf-8") as f:
    f.write(s2)

print(f"OK: replaced 1 anchor in {path} (backup: {bak})")
PY

echo ""
echo "Result line:"
grep -n 'payments partner - Nexum' "$TARGET" || true
echo ""
echo "Done. Standard deploy (web only):"
echo "  cd ~/AfriFX/nexum-web && rm -rf .next && npx tsc --noEmit && npm run build"
echo "  cd ~/AfriFX && git add -A && git commit -m 'fix: replace &mdash; entity with hyphen in offramp copy' && git push"
