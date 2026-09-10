#!/usr/bin/env bash
# ============================================================================
# nexum-dashboard-cleanup-A-web.sh   (WEB-ONLY, v2 anchored-edit delivery)
#
# Part A of a two-part dashboard cleanup. Pure copy + UI fixes, no API change:
#   A1. Bridge page  - remove the descriptive subtitle under the heading.
#   A2. Send page    - remove the descriptive subtitle under the heading.
#   A3. Wallet       - drop the Arc-only "USDC" entry from the Token-balances
#                      list (the per-chain cards already cover USDC, so it was
#                      showing twice). EURC + any non-USDC token still show.
#   A4. Wallet       - guard the Arcscan address link so it never links to
#                      /address/undefined before the wallet address resolves.
#   A5. Profile      - same address-link guard (identical bug).
#   A6. Payroll      - reword the 3 "Memo" mentions to "unique reference"
#                      (mechanism unchanged; refId/PAY-YYYYMMDD-XXXX still sent).
#
# Idempotent (marker-guarded), --revert (restores newest per-file backup),
# timestamped backups (backup-once-per-file-per-run). No em-dashes. No new deps.
# Run from repo root (~/AfriFX) or anywhere above nexum-web.
# ============================================================================
set -euo pipefail

STAMP="$(date +%Y%m%d-%H%M%S)"
MARK="__NEXUM_DASH_CLEANUP_A__"

# ---- locate repo root (dir containing nexum-web) ---------------------------
ROOT=""
for cand in "." ".." "$HOME/AfriFX" "$(pwd)"; do
  if [ -d "$cand/nexum-web" ]; then ROOT="$(cd "$cand" && pwd)"; break; fi
done
if [ -z "$ROOT" ]; then
  # search shallow
  hit="$(find . -maxdepth 3 -type d -name nexum-web 2>/dev/null | head -1 || true)"
  [ -n "$hit" ] && ROOT="$(cd "$(dirname "$hit")" && pwd)"
fi
[ -z "$ROOT" ] && { echo "ERROR: could not find nexum-web from $(pwd)"; exit 1; }
WEB="$ROOT/nexum-web"
echo "repo root : $ROOT"
echo "web       : $WEB"

BRIDGE="$WEB/app/(app)/bridge/page.tsx"
SEND="$WEB/app/(app)/send/page.tsx"
WALLET="$WEB/app/(app)/wallet/WalletContent.tsx"
PROFILE="$WEB/app/(app)/profile/page.tsx"
PAYROLL="$WEB/app/(app)/treasury/payroll/PayrollCreateContent.tsx"

for f in "$BRIDGE" "$SEND" "$WALLET" "$PROFILE" "$PAYROLL"; do
  [ -f "$f" ] || { echo "ERROR: missing $f"; exit 1; }
done

# ---------------------------------------------------------------------------
# --revert : restore the newest backup for every file we touch, then stop.
# ---------------------------------------------------------------------------
if [ "${1:-}" = "--revert" ]; then
  echo "Reverting to newest backups ..."
  n=0
  for f in "$BRIDGE" "$SEND" "$WALLET" "$PROFILE" "$PAYROLL"; do
    bak="$(ls -1t "$f".bak.* 2>/dev/null | head -1 || true)"
    if [ -n "$bak" ]; then
      cp "$bak" "$f"; echo "  restored $(basename "$f")  <- $(basename "$bak")"; n=$((n+1))
    else
      echo "  (no backup for $(basename "$f"), left as-is)"
    fi
  done
  echo "Revert done ($n file(s))."
  exit 0
fi

# ---------------------------------------------------------------------------
# idempotency: if every file already carries the marker, do nothing.
# ---------------------------------------------------------------------------
already=1
for f in "$BRIDGE" "$SEND" "$WALLET" "$PROFILE" "$PAYROLL"; do
  grep -q "$MARK" "$f" || already=0
done
if [ "$already" = "1" ]; then
  echo "Already applied ($MARK present in all files). Nothing to do."
  exit 0
fi

# ---------------------------------------------------------------------------
# Python anchored-edit engine. Reads a JSON-ish spec via env, does exact
# single-occurrence replacements, asserts each anchor hit exactly once,
# backs up once per file, appends the marker as a trailing comment line.
# ---------------------------------------------------------------------------
python3 - "$STAMP" "$MARK" "$BRIDGE" "$SEND" "$WALLET" "$PROFILE" "$PAYROLL" <<'PYEOF'
import sys, os

stamp = sys.argv[1]
mark  = sys.argv[2]
BRIDGE, SEND, WALLET, PROFILE, PAYROLL = sys.argv[3:8]

# edits[path] = list of (old, new, label). Each old MUST occur exactly once.
edits = {}

# ---- A1  bridge subtitle removal -----------------------------------------
edits.setdefault(BRIDGE, []).append((
'''          <h1 className="text-xl font-semibold text-app-text">Bridge</h1>
          <p className="text-sm text-app-muted">
            Move native USDC between Arc and other chains using Circle&apos;s CCTP.
          </p>
''',
'''          <h1 className="text-xl font-semibold text-app-text">Bridge</h1>
''',
"A1 bridge subtitle"))

# ---- A2  send subtitle removal -------------------------------------------
edits.setdefault(SEND, []).append((
'''        <h1 className="text-xl font-semibold text-app-text">Send</h1>
        <p className="text-sm text-app-muted">
          Send USDC to any address, on any chain your wallet holds USDC.
        </p>
''',
'''        <h1 className="text-xl font-semibold text-app-text">Send</h1>
''',
"A2 send subtitle"))

# ---- A3  wallet USDC token dedup -----------------------------------------
# Filter the Arc-only USDC entry out of data.tokens so USDC shows only via the
# per-chain cards below. Fallback list also drops its USDC seed.
edits.setdefault(WALLET, []).append((
"          {(data?.tokens ?? [{ symbol: 'USDC', name: 'USD Coin', balance: 0, usdValue: 0, color: '#378ADD', address: '' }, { symbol: 'EURC', name: 'Euro Coin', balance: 0, usdValue: 0, color: '#10B981', address: '' }]).map(token => (",
"          {((data?.tokens ?? [{ symbol: 'EURC', name: 'Euro Coin', balance: 0, usdValue: 0, color: '#10B981', address: '' }]).filter(t => t.symbol !== 'USDC')).map(token => (",
"A3 wallet USDC dedup"))

# ---- A4  wallet address-link guard ---------------------------------------
edits.setdefault(WALLET, []).append((
'''            <a href={`https://testnet.arcscan.app/address/${address}`}
              target="_blank" rel="noopener noreferrer"
              className="shrink-0 text-app-muted hover:text-app-accent-text">
              <ExternalLink className="h-3.5 w-3.5" />
            </a>''',
'''            {address && (
              <a href={`https://testnet.arcscan.app/address/${address}`}
                target="_blank" rel="noopener noreferrer"
                className="shrink-0 text-app-muted hover:text-app-accent-text">
                <ExternalLink className="h-3.5 w-3.5" />
              </a>
            )}''',
"A4 wallet address guard"))

# ---- A5  profile address-link guard (same pattern, 12-space indent) -------
edits.setdefault(PROFILE, []).append((
'''            <a href={`https://testnet.arcscan.app/address/${address}`}
              target="_blank" rel="noopener noreferrer"
              className="shrink-0 text-app-muted hover:text-app-accent-text">
              <ExternalLink className="h-3.5 w-3.5" />
            </a>''',
'''            {address && (
              <a href={`https://testnet.arcscan.app/address/${address}`}
                target="_blank" rel="noopener noreferrer"
                className="shrink-0 text-app-muted hover:text-app-accent-text">
                <ExternalLink className="h-3.5 w-3.5" />
              </a>
            )}''',
"A5 profile address guard"))

# ---- A6  payroll memo rewrites (3) ---------------------------------------
edits.setdefault(PAYROLL, []).append((
"            Send USDC to multiple wallets \u00b7 each payment gets a unique Memo reference",
"            Send USDC to multiple wallets \u00b7 each payment carries a unique reference",
"A6a payroll subtitle"))
edits.setdefault(PAYROLL, []).append((
'                <span className="text-app-muted">Gets unique Memo ref</span>',
'                <span className="text-app-muted">Gets unique reference</span>',
"A6b payroll summary row"))
edits.setdefault(PAYROLL, []).append((
"                'Each payment gets a unique Memo reference (PAY-YYYYMMDD-XXXX)',",
"                'Each payment carries a unique reference (PAY-YYYYMMDD-XXXX)',",
"A6c payroll how-it-works"))

# ---------------------------------------------------------------------------
def apply(path, changes):
    with open(path, 'r', encoding='utf-8') as fh:
        text = fh.read()
    if mark in text:
        print(f"  {os.path.basename(path)}: marker present, skipping edits")
        return text, False
    for old, new, label in changes:
        cnt = text.count(old)
        if cnt != 1:
            raise SystemExit(f"ABORT [{label}] in {os.path.basename(path)}: "
                             f"anchor matched {cnt} times (need exactly 1). "
                             f"No files changed for this path.")
        text = text.replace(old, new, 1)
        print(f"  {os.path.basename(path)}: applied {label}")
    return text, True

# Group edits per file; validate ALL anchors before writing ANY file.
staged = {}
for path, changes in edits.items():
    new_text, changed = apply(path, changes)
    if changed:
        staged[path] = new_text

# Write: backup-once then write new content + trailing marker comment.
for path, new_text in staged.items():
    bak = f"{path}.bak.{stamp}"
    if not os.path.exists(bak):
        with open(path, 'r', encoding='utf-8') as fh:
            orig = fh.read()
        with open(bak, 'w', encoding='utf-8') as fh:
            fh.write(orig)
    # append marker as a trailing line comment (harmless in a .tsx module tail)
    if not new_text.endswith("\n"):
        new_text += "\n"
    new_text += f"// {mark} {stamp}\n"
    with open(path, 'w', encoding='utf-8') as fh:
        fh.write(new_text)
    print(f"  wrote {os.path.basename(path)} (backup {os.path.basename(bak)})")

print("Python edit stage complete.")
PYEOF

echo ""
echo "Script A applied. Verify with:  cd $WEB && rm -rf .next && npx tsc --noEmit && npm run build"
echo "Revert with:                    bash $(basename "$0") --revert"
