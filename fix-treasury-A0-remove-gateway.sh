#!/usr/bin/env bash
#
# fix-treasury-A0-remove-gateway.sh   (Item A, Phase A0)
#
# WHAT: Removes the unused Circle Gateway "unified balance" code (web-only).
#
# WHY:  The unified-balance panel was read-only and unused; the deposit/send
#       gateway code is imported nowhere. Clearing it shrinks the surface before
#       the Treasury -> Payroll dashboard rebuild.
#
# CHANGES:
#   DELETE (5 dead web files, backed up so --revert restores them):
#     nexum-web/components/treasury/GatewayBalancePanel.tsx
#     nexum-web/components/treasury/GatewayDepositForm.tsx
#     nexum-web/hooks/useGatewayDeposit.ts
#     nexum-web/hooks/useGatewaySend.ts
#     nexum-web/lib/gateway.ts
#   EDIT (1 file): nexum-web/app/(app)/treasury/TreasuryContent.tsx
#     - remove GatewayBalancePanel import
#     - remove the GatewayBalancePanel usage block (comment + wrapping div)
#
# SAFE: the 5 files import only each other + @/lib/gateway; nothing else in the
#       app references them (verified). API is UNTOUCHED - the API "Gateway"
#       refs are EIP-712 CCTP burn-intent signing, a different thing.
#
# DELIVERY: v2 - anchored byte-exact edit (assert count==1), file deletes with
#           per-file backup, idempotent marker guard, --revert restores
#           everything (edit + deleted files).
#
# USAGE:
#   bash fix-treasury-A0-remove-gateway.sh          # apply
#   bash fix-treasury-A0-remove-gateway.sh --revert # restore
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_ROOT"

TREASURY="nexum-web/app/(app)/treasury/TreasuryContent.tsx"
STAMP="$(date +%Y%m%d-%H%M%S)"

DELETE_FILES=(
  "nexum-web/components/treasury/GatewayBalancePanel.tsx"
  "nexum-web/components/treasury/GatewayDepositForm.tsx"
  "nexum-web/hooks/useGatewayDeposit.ts"
  "nexum-web/hooks/useGatewaySend.ts"
  "nexum-web/lib/gateway.ts"
)

# ----- revert -----
if [ "${1:-}" = "--revert" ]; then
  rc=0
  # restore TreasuryContent
  newest="$(ls -1t "$TREASURY".bak.* 2>/dev/null | head -1 || true)"
  if [ -n "$newest" ]; then cp "$newest" "$TREASURY"; echo "reverted $TREASURY from $newest"
  else echo "revert: no backup for $TREASURY"; rc=1; fi
  # restore deleted files from their .deleted backups
  for f in "${DELETE_FILES[@]}"; do
    bak="$(ls -1t "$f".deleted.* 2>/dev/null | head -1 || true)"
    if [ -n "$bak" ]; then cp "$bak" "$f"; echo "restored $f from $bak"
    else echo "revert: no deleted-backup for $f (may already be present)"; fi
  done
  exit $rc
fi

# ----- preflight -----
[ -f "$TREASURY" ] || { echo "ABORT: $TREASURY not found" >&2; exit 1; }

# ----- idempotency guard -----
if ! grep -qF "GatewayBalancePanel" "$TREASURY"; then
  echo "already applied: no GatewayBalancePanel in $TREASURY - nothing to do"
  exit 0
fi

# ----- edit TreasuryContent (anchored) -----
python3 - "$TREASURY" "$STAMP" <<'PY'
import sys, os
path, stamp = sys.argv[1], sys.argv[2]
with open(path, encoding="utf-8") as f: s = f.read()

imp = "import { GatewayBalancePanel } from '@/components/treasury/GatewayBalancePanel'\n"
block = ('      {/* Circle Gateway unified balance read-only for now. Sits above the\n'
         '          existing panels because "how much can I actually spend, anywhere" is\n'
         '          the first question when funding a payout. */}\n'
         '      <div className="mb-4">\n'
         '        <GatewayBalancePanel />\n'
         '      </div>\n\n')

for name, anchor in (("import", imp), ("usage block", block)):
    n = s.count(anchor)
    if n != 1:
        sys.stderr.write(f"ABORT: TreasuryContent anchor '{name}' expected 1, found {n}. No change made.\n")
        sys.exit(1)

bak = f"{path}.bak.{stamp}"
if not os.path.exists(bak):
    with open(bak, "w", encoding="utf-8") as b: b.write(s)

s = s.replace(imp, "").replace(block, "")
assert "GatewayBalancePanel" not in s and "lib/gateway" not in s
with open(path, "w", encoding="utf-8") as f: f.write(s)
print(f"OK: TreasuryContent cleaned (backup: {bak})")
PY

# ----- delete the 5 dead files (with restore-backups) -----
for f in "${DELETE_FILES[@]}"; do
  if [ -f "$f" ]; then
    cp "$f" "$f.deleted.$STAMP"
    rm "$f"
    echo "deleted $f (backup: $f.deleted.$STAMP)"
  else
    echo "skip (already gone): $f"
  fi
done

echo ""
echo "Done. Standard deploy (web only):"
echo "  cd ~/AfriFX/nexum-web && rm -rf .next && npx tsc --noEmit && npm run build"
echo "  cd ~/AfriFX && git add -A && git commit -m 'chore: remove unused Circle Gateway unified-balance code (Treasury A0)' && git push"
echo ""
echo "NOTE: git add -A will stage the deletions. The .deleted.* / .bak.* backups"
echo "sit next to the touched files (repo source only, never node_modules)."
echo "They are already git-ignored by the repo's *.bak pattern; if you also want"
echo "the .deleted.* copies gone before commit, remove them by exact path:"
for f in "${DELETE_FILES[@]}"; do echo "  rm -f \"$f\".deleted.* "; done
echo "  rm -f \"$TREASURY\".bak.*"
