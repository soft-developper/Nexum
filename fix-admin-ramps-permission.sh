#!/usr/bin/env bash
#
# fix-admin-ramps-permission.sh
#
# WHAT: Gives the admin Ramps page its own permission ('view_ramps') instead of
#       sharing 'view_analytics'. Analytics keeps view_analytics unchanged.
#
# WHY:  Ramp analytics and platform analytics are distinct duties; a sub-admin
#       granted analytics should not automatically see fiat on/off-ramp data.
#
# CHANGES (5 anchored edits across 3 files):
#   API  nexum-api/src/lib/permissions.ts
#        + PERMISSIONS.VIEW_RAMPS = 'view_ramps'
#        + PERMISSION_META.view_ramps (label/description)
#        (auto-appears in grant UI via ALL_PERMISSIONS/PERMISSION_META, and is
#         auto-granted to super-admin on seed via ALL_PERMISSIONS)
#   API  nexum-api/src/routes/adminManage.ts
#        GET /admin/manage/ramps  guard VIEW_ANALYTICS -> VIEW_RAMPS
#   WEB  nexum-web/components/admin/AdminShell.tsx
#        Ramps nav entry + guard-map path  view_analytics -> view_ramps
#
# NOTE: after deploy, existing sub-admins with only view_analytics lose the Ramps
#       page; grant them view_ramps to restore it. Super-admin is unaffected.
#
# DELIVERY: v2 - anchored byte-exact replacements (assert count==1 each),
#           backup-once-per-run per file, idempotent marker guard, --revert.
#
# USAGE:
#   bash fix-admin-ramps-permission.sh          # apply
#   bash fix-admin-ramps-permission.sh --revert # restore newest backups
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_ROOT"

PERMS="nexum-api/src/lib/permissions.ts"
ADMIN="nexum-api/src/routes/adminManage.ts"
SHELL_F="nexum-web/components/admin/AdminShell.tsx"
STAMP="$(date +%Y%m%d-%H%M%S)"
FILES=("$PERMS" "$ADMIN" "$SHELL_F")

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

# ----- idempotency guard (marker = new permission already defined) -----
if grep -qF "VIEW_RAMPS:" "$PERMS"; then
  echo "already applied: VIEW_RAMPS present in $PERMS - nothing to do"
  exit 0
fi

python3 - "$PERMS" "$ADMIN" "$SHELL_F" "$STAMP" <<'PY'
import sys, os
perms, admin, shell, stamp = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]

def backup_once(path, content):
    bak = f"{path}.bak.{stamp}"
    if not os.path.exists(bak):
        with open(bak, "w", encoding="utf-8") as b: b.write(content)

def edit(path, pairs, checks):
    with open(path, encoding="utf-8") as f: s = f.read()
    for name, old, _ in pairs:
        n = s.count(old)
        if n != 1:
            sys.stderr.write(f"ABORT: {path} anchor '{name}' expected 1, found {n}. No change made to any file.\n")
            sys.exit(1)
    return s

# validate ALL anchors across ALL files BEFORE writing anything
perms_pairs = [
    ("PERMISSIONS.SEND_BROADCASTS",
     "  SEND_BROADCASTS:   'send_broadcasts',   // email sub-admins / users\n",
     "  SEND_BROADCASTS:   'send_broadcasts',   // email sub-admins / users\n"
     "  VIEW_RAMPS:        'view_ramps',        // fiat on/off-ramp analytics\n"),
    ("PERMISSION_META.send_broadcasts",
     "  send_broadcasts:  { label: 'Send Broadcasts',   description: 'Email sub-admins and registered users' },\n",
     "  send_broadcasts:  { label: 'Send Broadcasts',   description: 'Email sub-admins and registered users' },\n"
     "  view_ramps:       { label: 'View Ramp Analytics', description: 'See on/off-ramp volume, KYC funnel and health' },\n"),
]
admin_pairs = [
    ("ramps route guard",
     "router.get('/ramps', requirePermission(PERMISSIONS.VIEW_ANALYTICS), async (_req, res) => {",
     "router.get('/ramps', requirePermission(PERMISSIONS.VIEW_RAMPS), async (_req, res) => {"),
]
shell_pairs = [
    ("ramps nav entry",
     "  { href: '/admin/ramps',      icon: ArrowLeftRight,  label: 'Ramps',      perm: 'view_analytics'   },",
     "  { href: '/admin/ramps',      icon: ArrowLeftRight,  label: 'Ramps',      perm: 'view_ramps'       },"),
    ("ramps guard map",
     "      { perm: 'view_analytics',   path: '/admin/ramps'      },",
     "      { perm: 'view_ramps',       path: '/admin/ramps'      },"),
]

s_perms = edit(perms, perms_pairs, None)
s_admin = edit(admin, admin_pairs, None)
s_shell = edit(shell, shell_pairs, None)

# all anchors validated - now back up and write
backup_once(perms, s_perms)
for _, old, new in perms_pairs: s_perms = s_perms.replace(old, new)
assert s_perms.count("VIEW_RAMPS") == 1 and s_perms.count("view_ramps") == 2
with open(perms, "w", encoding="utf-8") as f: f.write(s_perms)

backup_once(admin, s_admin)
for _, old, new in admin_pairs: s_admin = s_admin.replace(old, new)
assert s_admin.count("PERMISSIONS.VIEW_RAMPS") == 1
with open(admin, "w", encoding="utf-8") as f: f.write(s_admin)

backup_once(shell, s_shell)
for _, old, new in shell_pairs: s_shell = s_shell.replace(old, new)
assert s_shell.count("path: '/admin/ramps'") == 1 and s_shell.count("view_ramps") == 2
# analytics must remain on view_analytics
assert "label: 'Analytics',  perm: 'view_analytics'" in s_shell
with open(shell, "w", encoding="utf-8") as f: f.write(s_shell)

print("OK: 5 edits applied across 3 files")
PY

echo ""
echo "permissions.ts:"; grep -n "VIEW_RAMPS\|view_ramps" "$PERMS"
echo "adminManage.ts:"; grep -n "VIEW_RAMPS" "$ADMIN"
echo "AdminShell.tsx:"; grep -n "view_ramps" "$SHELL_F"
echo ""
echo "Done. Standard deploy (BOTH packages):"
echo "  cd ~/AfriFX/nexum-api && npx tsc --noEmit && npm run build"
echo "  cd ~/AfriFX/nexum-web && rm -rf .next && npx tsc --noEmit && npm run build"
echo "  cd ~/AfriFX && git add -A && git commit -m 'feat: separate view_ramps permission for admin ramps page' && git push"
echo ""
echo "After deploy: grant 'View Ramp Analytics' to any sub-admin who needs the Ramps page."
