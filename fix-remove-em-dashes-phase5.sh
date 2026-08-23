#!/usr/bin/env bash
# ============================================================
# fix-remove-em-dashes-phase5.sh
#
# Remove every em-dash (U+2014, —) from the Phase 5 ramp subsystem, replacing
# each with a hyphen '-'. Covers the files built during Phase 5 (offramp) AND
# the ramp-related shared files the onramp work left em-dashes in, so the whole
# ramp feature is consistent. All occurrences are in comments, UI copy, error
# messages, and log lines — none are load-bearing (verified: no idempotency
# marker, key, or matcher contains an em-dash; both packages tsc-clean after).
#
# Scope (deliberately narrow, per the "scope substitutions narrowly" rule):
#   API: services/bridgexyz/{client,config,customers,virtualAccounts,externalAccounts,liquidationAddresses,ensureOfframp,
#        payoutNotify,webhooks,repository}.ts, services/ensureTransactionsSchema.ts,
#        services/sendReconciler.ts, services/email/templates.ts,
#        routes/{ramp,transfers}.ts
#   WEB: hooks/useRamp.ts, app/(app)/ramp/page.tsx
#
# Idempotent (re-run finds nothing to change). --revert restores backups.
# Byte-safe UTF-8 replacement via perl -CSD (matches the exact — codepoint).
#
# Usage:
#   bash fix-remove-em-dashes-phase5.sh          # apply
#   bash fix-remove-em-dashes-phase5.sh --revert # undo
# ============================================================
set -euo pipefail
STAMP="$(date +%Y%m%d-%H%M%S)"

if [ -d "nexum-api" ] && [ -d "nexum-web" ]; then ROOT="."
elif [ -f "../nexum-api/package.json" ]; then ROOT=".."
else echo "ERROR: run from the repo root (~/AfriFX)." >&2; exit 1; fi
API="$ROOT/nexum-api"; WEB="$ROOT/nexum-web"

FILES=(
  "$API/src/services/bridgexyz/externalAccounts.ts"
  "$API/src/services/bridgexyz/client.ts"
  "$API/src/services/bridgexyz/config.ts"
  "$API/src/services/bridgexyz/customers.ts"
  "$API/src/services/bridgexyz/virtualAccounts.ts"
  "$API/src/services/bridgexyz/liquidationAddresses.ts"
  "$API/src/services/bridgexyz/ensureOfframp.ts"
  "$API/src/services/bridgexyz/payoutNotify.ts"
  "$API/src/services/bridgexyz/webhooks.ts"
  "$API/src/services/bridgexyz/repository.ts"
  "$API/src/services/ensureTransactionsSchema.ts"
  "$API/src/services/sendReconciler.ts"
  "$API/src/services/email/templates.ts"
  "$API/src/routes/ramp.ts"
  "$API/src/routes/transfers.ts"
  "$WEB/hooks/useRamp.ts"
  "$WEB/app/(app)/ramp/page.tsx"
)

# ---- revert -----------------------------------------------------------------
if [ "${1:-}" = "--revert" ]; then
  echo "Reverting em-dash removal..."
  for f in "${FILES[@]}"; do
    BK="$(ls -t "$f".emdash.bak.* 2>/dev/null | head -1 || true)"
    [ -n "$BK" ] && { cp "$BK" "$f"; echo "  restored $(basename "$f")"; }
  done
  echo "Revert complete. Re-run per-package tsc + build."
  exit 0
fi

changed=0
for f in "${FILES[@]}"; do
  if [ ! -f "$f" ]; then echo "  skip (not found): $f"; continue; fi
  n="$(grep -c $'\xe2\x80\x94' "$f" 2>/dev/null || true)"; n="${n:-0}"
  if [ "$n" = "0" ]; then echo "  clean already: $(basename "$f")"; continue; fi
  cp "$f" "$f.emdash.bak.$STAMP"
  perl -CSD -i -pe 's/\x{2014}/-/g' "$f"
  after="$(grep -c $'\xe2\x80\x94' "$f" 2>/dev/null || true)"; after="${after:-0}"
  if [ "$after" != "0" ]; then echo "ERROR: $(basename "$f") still has em-dashes after strip — restoring." >&2; cp "$f.emdash.bak.$STAMP" "$f"; exit 1; fi
  echo "  stripped $n em-dash(es) from $(basename "$f")"
  changed=$((changed+1))
done

echo ""
if [ "$changed" = "0" ]; then
  echo "Nothing to change — all files already em-dash-free."
else
  echo "Removed em-dashes from $changed file(s). Deploy BOTH packages:"
  echo "  cd $API && npx tsc --noEmit && npm run build"
  echo "  cd $WEB && rm -rf .next && npx tsc --noEmit && npm run build"
  echo "  cd $ROOT && git add -A && git commit -m 'style: remove em-dashes from ramp subsystem' && git push"
fi
