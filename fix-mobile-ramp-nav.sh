#!/usr/bin/env bash
#
# fix-mobile-ramp-nav.sh
#
# WHAT: Adds the "On/Off-ramp" (/ramp) nav item to the mobile drawer's Exchange
#       section, mirroring the desktop Sidebar. Also adds the ArrowDownUp icon
#       import the new line needs.
#
# WHY:  On mobile the desktop Sidebar is hidden (md:flex). Navigation comes from
#       MobileNav (4 bottom tabs + More) and MobileDrawer (full list). The ramp
#       entry was added to Sidebar.tsx only - MobileDrawer.tsx never got it - so
#       /ramp was unreachable on mobile (not a bottom tab, not in the drawer).
#
# SCOPE: web only, ONE file (MobileDrawer.tsx), TWO anchored edits.
#
# DELIVERY: v2 - anchored byte-exact replacements (assert count==1 each),
#           backup-once-per-run, idempotent marker guard, --revert newest backup.
#
# USAGE:
#   bash fix-mobile-ramp-nav.sh          # apply
#   bash fix-mobile-ramp-nav.sh --revert # restore newest backup
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_ROOT"

TARGET="nexum-web/components/layout/MobileDrawer.tsx"
STAMP="$(date +%Y%m%d-%H%M%S)"

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

# ----- idempotency guard (marker = the ramp line already present) -----
if grep -qF "href: '/ramp'" "$TARGET"; then
  echo "already applied: /ramp nav item present in $TARGET - nothing to do"
  exit 0
fi

# ----- anchored byte-exact replacements -----
python3 - "$TARGET" "$STAMP" <<'PY'
import sys, os
path, stamp = sys.argv[1], sys.argv[2]
with open(path, encoding="utf-8") as f:
    s = f.read()

# edit 1: extend icon import with ArrowDownUp
imp_old = "  ArrowLeftRight, Send, History, LayoutDashboard,"
imp_new = "  ArrowLeftRight, ArrowDownUp, Send, History, LayoutDashboard,"

# edit 2: add ramp line right after Send in Exchange section
nav_old = "    { href: '/send',     icon: Send,           label: 'Send'     },\n"
nav_new = ("    { href: '/send',     icon: Send,           label: 'Send'     },\n"
           "    { href: '/ramp',     icon: ArrowDownUp,    label: 'On/Off-ramp' },\n")

for name, old in (("import", imp_old), ("nav", nav_old)):
    n = s.count(old)
    if n != 1:
        sys.stderr.write(f"ABORT: {name} anchor expected 1 match, found {n}. No change made.\n")
        sys.exit(1)

# backup once per run
bak = f"{path}.bak.{stamp}"
if not os.path.exists(bak):
    with open(bak, "w", encoding="utf-8") as b:
        b.write(s)

s2 = s.replace(imp_old, imp_new).replace(nav_old, nav_new)

# sanity: ArrowDownUp now appears exactly twice (import + usage), ramp line once
if s2.count("ArrowDownUp") != 2:
    sys.stderr.write("ABORT: ArrowDownUp count unexpected after edit.\n"); sys.exit(1)
if s2.count("href: '/ramp'") != 1:
    sys.stderr.write("ABORT: ramp line count unexpected after edit.\n"); sys.exit(1)

with open(path, "w", encoding="utf-8") as f:
    f.write(s2)

print(f"OK: 2 edits applied to {path} (backup: {bak})")
PY

echo ""
echo "Exchange section now:"
sed -n '16,21p' "$TARGET"
echo ""
echo "Done. Standard deploy (web only):"
echo "  cd ~/AfriFX/nexum-web && rm -rf .next && npx tsc --noEmit && npm run build"
echo "  cd ~/AfriFX && git add -A && git commit -m 'fix: add On/Off-ramp to mobile drawer nav' && git push"
