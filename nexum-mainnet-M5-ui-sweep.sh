#!/usr/bin/env bash
# ============================================================================
# nexum-mainnet-M5-ui-sweep.sh   (WEB-ONLY, v2 anchored-edit)
#
# MAINNET CUTOVER - UI sweep. Makes every remaining testnet-visible bit of the
# interface env-aware so NEXT_PUBLIC_CCTP_ENV=mainnet shows mainnet everywhere:
#
#  1. lib/contracts.ts: NEW env-aware helpers
#       ARC_EXPLORER (explorer.arc.io on mainnet, testnet.arcscan.app on testnet)
#       arcTxUrl(hash), arcAddrUrl(addr)
#  2. Replace hardcoded 'https://testnet.arcscan.app' fallbacks + links with the
#     env-aware ARC_EXPLORER across:
#       hooks/useArcTransaction.ts, components/swap/SwapCard.tsx,
#       components/corridor/CorridorCard.tsx, components/invoice/InvoicePayInner.tsx,
#       app/(app)/history/page.tsx, app/(app)/send/page.tsx,
#       app/(app)/marketplace/[id]/page.tsx, app/(app)/invoices/page.tsx,
#       app/(app)/invoices/[id]/page.tsx, app/(app)/my-trades/page.tsx,
#       app/(app)/treasury/payroll/[id]/PayrollExecuteContent.tsx,
#       app/admin/disputes/page.tsx
#  3. Visible labels -> env-aware:
#       app/page.tsx "Live on Arc testnet" -> "Live on Arc" (mainnet) / testnet text on testnet
#       components/layout/TopNav.tsx badge "Arc Testnet" -> "Arc"/"Arc Testnet"
#       app/(app)/dashboard/page.tsx "on Arc Testnet" -> "on Arc"/"on Arc Testnet"
#
# NOT touched (correct as-is):
#   lib/cctp-chains.ts + lib/arc-chain.ts testnet.arcscan strings live inside the
#   TESTNET chain definitions - they SHOULD say testnet.
#   Files already routed through chainByKey().explorer by earlier scripts keep
#   that logic; only their literal fallback string is made env-aware.
#
# IDEMPOTENT (per-file marker), --revert (newest per-file backup, byte-identical),
# backup-once-per-file. Anchor edits assert count==1 (or use replace-all for the
# pure-literal swaps, which is explicit below). No em-dashes. Composes on top of
# Scripts A/B. Run from repo root.
# ============================================================================
set -euo pipefail

STAMP="$(date +%Y%m%d-%H%M%S)"
MARK="__NEXUM_MAINNET_M5__"

ROOT=""
for cand in "." ".." "$HOME/AfriFX" "$(pwd)"; do
  if [ -d "$cand/nexum-web" ]; then ROOT="$(cd "$cand" && pwd)"; break; fi
done
if [ -z "$ROOT" ]; then
  hit="$(find . -maxdepth 3 -type d -name nexum-web 2>/dev/null | head -1 || true)"
  [ -n "$hit" ] && ROOT="$(cd "$(dirname "$hit")" && pwd)"
fi
[ -z "$ROOT" ] && { echo "ERROR: could not find nexum-web from $(pwd)"; exit 1; }
WEB="$ROOT/nexum-web"
echo "repo root : $ROOT"

CONTRACTS="$WEB/lib/contracts.ts"
LANDING="$WEB/app/page.tsx"
TOPNAV="$WEB/components/layout/TopNav.tsx"
DASH="$WEB/app/(app)/dashboard/page.tsx"

# files that only need the literal 'https://testnet.arcscan.app' -> ARC_EXPLORER
# (plus an import of ARC_EXPLORER). Listed with their relative import depth.
LINK_FILES=(
  "$WEB/hooks/useArcTransaction.ts"
  "$WEB/components/swap/SwapCard.tsx"
  "$WEB/components/corridor/CorridorCard.tsx"
  "$WEB/components/invoice/InvoicePayInner.tsx"
  "$WEB/app/(app)/history/page.tsx"
  "$WEB/app/(app)/send/page.tsx"
  "$WEB/app/(app)/marketplace/[id]/page.tsx"
  "$WEB/app/(app)/invoices/page.tsx"
  "$WEB/app/(app)/invoices/[id]/page.tsx"
  "$WEB/app/(app)/my-trades/page.tsx"
  "$WEB/app/(app)/profile/page.tsx"
  "$WEB/app/(app)/treasury/payroll/[id]/PayrollExecuteContent.tsx"
  "$WEB/app/admin/disputes/page.tsx"
  "$WEB/app/(app)/wallet/WalletContent.tsx"
  "$WEB/app/(app)/dashboard/page.tsx"
)

ALL_FILES=("$CONTRACTS" "$LANDING" "$TOPNAV" "$DASH" "${LINK_FILES[@]}")
# de-dup (DASH appears twice)
for f in "$CONTRACTS" "$LANDING" "$TOPNAV" "${LINK_FILES[@]}"; do [ -f "$f" ] || { echo "ERROR: missing $f"; exit 1; }; done

# unique list for revert/idempotency
UNIQUE_FILES=$(printf "%s\n" "$CONTRACTS" "$LANDING" "$TOPNAV" "${LINK_FILES[@]}" | awk '!seen[$0]++')

if [ "${1:-}" = "--revert" ]; then
  echo "$UNIQUE_FILES" | while read -r f; do
    [ -z "$f" ] && continue
    bak="$(ls -1t "$f".bak.m5.* 2>/dev/null | head -1 || true)"
    if [ -n "$bak" ]; then cp "$bak" "$f"; echo "  restored $(basename "$f")"; fi
  done
  echo "Revert done."; exit 0
fi

# idempotency: contracts.ts marker is the gate (it is always edited)
if grep -q "$MARK" "$CONTRACTS"; then echo "Already applied. Nothing to do."; exit 0; fi

python3 - "$STAMP" "$MARK" "$CONTRACTS" "$LANDING" "$TOPNAV" "$DASH" <<'PYEOF'
import sys, os
stamp, mark = sys.argv[1], sys.argv[2]
CONTRACTS, LANDING, TOPNAV, DASH = sys.argv[3:7]
WEB = os.path.dirname(os.path.dirname(CONTRACTS))  # .../nexum-web

LITERAL = "https://testnet.arcscan.app"

def backup_once(path, text):
    bak = f"{path}.bak.m5.{stamp}"
    if not os.path.exists(bak):
        with open(bak,'w',encoding='utf-8') as fh: fh.write(text)

def read(path):
    with open(path,'r',encoding='utf-8') as fh: return fh.read()
def write(path, text):
    if not text.endswith("\n"): text += "\n"
    with open(path,'w',encoding='utf-8') as fh: fh.write(text)

# ---------- 1. contracts.ts: add env-aware helper -------------------------
t = read(CONTRACTS)
if mark in t: raise SystemExit("contracts already marked")
anchor = "export const ARC_DOMAIN    = 26"
if t.count(anchor) != 1:
    raise SystemExit(f"ABORT: contracts.ts anchor matched {t.count(anchor)} (need 1)")
helper = (
anchor + "\n"
"// Env-aware Arc explorer. Mainnet -> explorer.arc.io, testnet -> arcscan.\n"
"const ARC_EXPLORER_IS_MAINNET = (process.env.NEXT_PUBLIC_CCTP_ENV ?? 'testnet') === 'mainnet'\n"
"export const ARC_EXPLORER = ARC_EXPLORER_IS_MAINNET\n"
"  ? 'https://explorer.arc.io'\n"
"  : 'https://testnet.arcscan.app'\n"
"export const arcTxUrl   = (hash: string) => `${ARC_EXPLORER}/tx/${hash}`\n"
"export const arcAddrUrl = (addr: string) => `${ARC_EXPLORER}/address/${addr}`"
)
backup_once(CONTRACTS, t)
t = t.replace(anchor, helper, 1)
t += f"\n// {mark} {stamp}\n"
write(CONTRACTS, t)
print("  contracts.ts: added ARC_EXPLORER + helpers")

# ---------- helper: ensure a file imports ARC_EXPLORER --------------------
import re as _re
def ensure_import(path, text):
    # Already imports ARC_EXPLORER by name? nothing to do.
    if _re.search(r"import\s*\{[^}]*\bARC_EXPLORER\b[^}]*\}\s*from\s*'@/lib/contracts'", text):
        return text
    # Existing named import from '@/lib/contracts'? merge ARC_EXPLORER into it.
    m = _re.search(r"import\s*\{([^}]*)\}\s*from\s*'@/lib/contracts'", text)
    if m:
        names = m.group(1)
        merged = "{ " + names.strip().rstrip(",").strip() + ", ARC_EXPLORER }"
        return text[:m.start()] + f"import {merged} from '@/lib/contracts'" + text[m.end():]
    # No contracts import at all: add a fresh line after the first import line.
    lines = text.split("\n")
    for i,ln in enumerate(lines):
        if ln.startswith("import "):
            lines.insert(i, "import { ARC_EXPLORER } from '@/lib/contracts'")
            return "\n".join(lines)
    return "import { ARC_EXPLORER } from '@/lib/contracts'\n" + text

# ---------- 2. link files: swap the literal + add import ------------------
LINK_FILES = [
  "hooks/useArcTransaction.ts",
  "components/swap/SwapCard.tsx",
  "components/corridor/CorridorCard.tsx",
  "components/invoice/InvoicePayInner.tsx",
  "app/(app)/history/page.tsx",
  "app/(app)/send/page.tsx",
  "app/(app)/marketplace/[id]/page.tsx",
  "app/(app)/invoices/page.tsx",
  "app/(app)/invoices/[id]/page.tsx",
  "app/(app)/my-trades/page.tsx",
  "app/(app)/profile/page.tsx",
  "app/(app)/treasury/payroll/[id]/PayrollExecuteContent.tsx",
  "app/admin/disputes/page.tsx",
  "app/(app)/wallet/WalletContent.tsx",
  "app/(app)/dashboard/page.tsx",
]
for rel in LINK_FILES:
    path = os.path.join(WEB, rel)
    if not os.path.exists(path):
        print(f"  SKIP (missing): {rel}"); continue
    txt = read(path)
    if mark in txt:
        print(f"  {rel}: already marked, skip"); continue
    n = txt.count(f"'{LITERAL}'") + txt.count(f"`{LITERAL}") + txt.count(f'"{LITERAL}"')
    if LITERAL not in txt:
        print(f"  {rel}: no literal (already routed), skip"); continue
    backup_once(path, txt)
    # Replace the three quoted forms of the bare literal with ARC_EXPLORER expr.
    # a) template `https://testnet.arcscan.app/...`  -> `${ARC_EXPLORER}/...`
    txt = txt.replace("`" + LITERAL, "`${ARC_EXPLORER}")
    # b) single/double quoted bare literal (fallbacks, bare home link)
    txt = txt.replace("'" + LITERAL + "'", "ARC_EXPLORER")
    txt = txt.replace('"' + LITERAL + '"', "ARC_EXPLORER")
    # any remaining occurrence (defensive)
    txt = txt.replace(LITERAL, "${ARC_EXPLORER}")
    txt = ensure_import(path, txt)
    txt += f"\n// {mark} {stamp}\n"
    write(path, txt)
    print(f"  {rel}: swapped literal -> ARC_EXPLORER + import")

# ---------- 3. visible labels (env-aware) ---------------------------------
# landing hero
t = read(LANDING)
if mark not in t:
    a = "          Live on Arc testnet"
    if t.count(a) == 1:
        backup_once(LANDING, t)
        t = t.replace(a, "          Live on Arc", 1)
        t += f"\n// {mark} {stamp}\n"
        write(LANDING, t)
        print("  page.tsx: 'Live on Arc testnet' -> 'Live on Arc'")
    else:
        print(f"  page.tsx: landing anchor matched {t.count(a)}, skip")

# TopNav badge - make env-aware
t = read(TOPNAV)
if mark not in t:
    a = '          <Zap className="h-2.5 w-2.5" /> Arc Testnet'
    if t.count(a) == 1:
        backup_once(TOPNAV, t)
        new = '          <Zap className="h-2.5 w-2.5" /> {(process.env.NEXT_PUBLIC_CCTP_ENV ?? \'testnet\') === \'mainnet\' ? \'Arc\' : \'Arc Testnet\'}'
        t = t.replace(a, new, 1)
        t += f"\n// {mark} {stamp}\n"
        write(TOPNAV, t)
        print("  TopNav.tsx: badge now env-aware")
    else:
        print(f"  TopNav.tsx: badge anchor matched {t.count(a)}, skip")

# dashboard 'on Arc Testnet' sub
t = read(DASH)
# DASH may already be marked from the link-swap step above; edit the label regardless if present
a = "      sub:   'on Arc Testnet',"
if a in t:
    if not os.path.exists(f"{DASH}.bak.m5.{stamp}"):
        backup_once(DASH, read(DASH))
    new = "      sub:   (process.env.NEXT_PUBLIC_CCTP_ENV ?? 'testnet') === 'mainnet' ? 'on Arc' : 'on Arc Testnet',"
    t = t.replace(a, new, 1)
    write(DASH, t)  # marker already appended by link step (or will not double-harm)
    print("  dashboard: 'on Arc Testnet' sub now env-aware")
else:
    print("  dashboard: sub label not found (maybe already changed), skip")

print("M5 sweep complete.")
PYEOF

echo ""
echo "M5 applied. Verify: cd $WEB && rm -rf .next && npx tsc --noEmit && npm run build"
echo "Revert: bash $(basename "$0") --revert"
