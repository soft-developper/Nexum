#!/usr/bin/env bash
#
# fix-retire-trade-nav.sh
#
# WHAT: Retires the "Trade" (/convert) feature from navigation and in-app entry
#       points. The /convert page itself and Treasury are LEFT UNTOUCHED (Treasury
#       is being reworked separately into a payroll dashboard).
#
# WHY:  Fiat conversion now happens through the On/Off-ramp (Bridge + future
#       providers), so the standalone Trade page is redundant in the nav.
#
# CHANGES (removals + orphaned-import cleanup):
#   nexum-web/components/layout/Sidebar.tsx      - remove /convert nav line + drop orphaned ArrowLeftRight import
#   nexum-web/components/layout/MobileDrawer.tsx - remove /convert nav line + drop orphaned ArrowLeftRight import (keeps ArrowDownUp + /ramp)
#   nexum-web/components/layout/MobileNav.tsx    - remove /convert bottom tab + drop orphaned ArrowLeftRight import
#   nexum-web/app/(app)/wallet/WalletContent.tsx - remove 2 /convert buttons (quick-action + empty-state); KEEPS ArrowLeftRight import (still used by P2P-volume card)
#
# PRECONDITION: run AFTER fix-mobile-ramp-nav.sh (Sidebar/Drawer imports must
#               contain "ArrowLeftRight, ArrowDownUp, ..."). If the mobile-nav
#               fix has not run, the Sidebar/Drawer import anchors will not match
#               and the script aborts cleanly with no changes.
#
# DELIVERY: v2 - anchored byte-exact edits (assert count==1 each, validated
#           across ALL files before any write), backup-once-per-run per file,
#           idempotent marker guard, --revert restores newest backups.
#
# USAGE:
#   bash fix-retire-trade-nav.sh          # apply
#   bash fix-retire-trade-nav.sh --revert # restore newest backups
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_ROOT"

SIDEBAR="nexum-web/components/layout/Sidebar.tsx"
DRAWER="nexum-web/components/layout/MobileDrawer.tsx"
MOBNAV="nexum-web/components/layout/MobileNav.tsx"
WALLET="nexum-web/app/(app)/wallet/WalletContent.tsx"
STAMP="$(date +%Y%m%d-%H%M%S)"
FILES=("$SIDEBAR" "$DRAWER" "$MOBNAV" "$WALLET")

# ----- revert -----
if [ "${1:-}" = "--revert" ]; then
  rc=0
  for f in "${FILES[@]}"; do
    newest="$(ls -1t "$f".bak.* 2>/dev/null | head -1 || true)"
    if [ -z "$newest" ]; then echo "revert: no backup for $f"; rc=1; continue; fi
    cp "$newest" "$f"; echo "reverted $f from $newest"
  done
  exit $rc
fi

# ----- preflight -----
for f in "${FILES[@]}"; do
  [ -f "$f" ] || { echo "ABORT: target not found: $f" >&2; exit 1; }
done

# ----- idempotency guard (marker = Sidebar no longer links /convert) -----
if ! grep -qF "href: '/convert'" "$SIDEBAR"; then
  echo "already applied: no /convert nav in $SIDEBAR - nothing to do"
  exit 0
fi

python3 - "$SIDEBAR" "$DRAWER" "$MOBNAV" "$WALLET" "$STAMP" <<'PY'
import sys, os
sidebar, drawer, mobnav, wallet, stamp = sys.argv[1:6]

def read(p):
    with open(p, encoding="utf-8") as f: return f.read()

def backup_once(p, content):
    bak = f"{p}.bak.{stamp}"
    if not os.path.exists(bak):
        with open(bak, "w", encoding="utf-8") as b: b.write(content)

# (path, [(name, old, new), ...])
plan = {
  sidebar: [
    ("nav", "    { href: '/convert',  icon: ArrowLeftRight, label: 'Trade'    },\n", ""),
    ("import", "  ArrowLeftRight, ArrowDownUp, Send, History, LayoutDashboard,",
               "  ArrowDownUp, Send, History, LayoutDashboard,"),
  ],
  drawer: [
    ("nav", "    { href: '/convert',  icon: ArrowLeftRight, label: 'Trade'    },\n", ""),
    ("import", "  ArrowLeftRight, ArrowDownUp, Send, History, LayoutDashboard,",
               "  ArrowDownUp, Send, History, LayoutDashboard,"),
  ],
  mobnav: [
    ("nav", "  { href: '/convert',     icon: ArrowLeftRight, label: 'Convert'   },\n", ""),
    ("import", "  ArrowLeftRight, Store, LayoutDashboard,", "  Store, LayoutDashboard,"),
  ],
  wallet: [
    ("btn1",
     '            <Link href="/convert" className="flex-1">\n'
     '              <Button variant="outline" size="sm" className="w-full">\n'
     '                <ArrowLeftRight className="h-3.5 w-3.5" /> Convert\n'
     '              </Button>\n'
     '            </Link>\n', ""),
    ("btn2",
     '              <Link href="/convert">\n'
     '                <Button variant="outline" size="sm">Make your first conversion</Button>\n'
     '              </Link>\n', ""),
  ],
}

# validate every anchor across every file first - abort all if any fails
contents = {}
for path, edits in plan.items():
    s = read(path)
    for name, old, _ in edits:
        n = s.count(old)
        if n != 1:
            sys.stderr.write(f"ABORT: {path} anchor '{name}' expected 1, found {n}. No files changed.\n")
            sys.exit(1)
    contents[path] = s

# apply
for path, edits in plan.items():
    s = contents[path]
    backup_once(path, s)
    for _, old, new in edits:
        s = s.replace(old, new)
    with open(path, "w", encoding="utf-8") as f:
        f.write(s)

# post-checks
for p in (sidebar, drawer, mobnav):
    assert "ArrowLeftRight" not in read(p), f"{p} still imports ArrowLeftRight"
assert "href: '/ramp'" in read(drawer), "drawer lost /ramp line"
w = read(wallet)
assert 'href="/convert"' not in w, "wallet still links /convert"
assert w.count("ArrowLeftRight") == 3, f"wallet ArrowLeftRight now {w.count('ArrowLeftRight')} (want 3)"
print("OK: Trade retired from 3 nav files + 2 wallet buttons; imports cleaned; /ramp intact")
PY

echo ""
echo "Done. Standard deploy (web only):"
echo "  cd ~/AfriFX/nexum-web && rm -rf .next && npx tsc --noEmit && npm run build"
echo "  cd ~/AfriFX && git add -A && git commit -m 'feat: retire Trade from nav and wallet entry points' && git push"
