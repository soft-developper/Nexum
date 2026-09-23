#!/usr/bin/env bash
# ============================================================================
# nexum-mainnet-M3-web.sh   (WEB-ONLY, v2 anchored-edit)
#
# MAINNET CUTOVER - Part M3 of 4. Fills the web's Arc MAINNET chain entry and
# makes the app-wide Arc constants env-driven so NEXT_PUBLIC_CCTP_ENV=mainnet
# flips them. Verified Arc mainnet values (official docs):
#   chainId 5042 | USDC 0x3600...0000 | RPC rpc.mainnet.arc.io
#   explorer explorer.arc.io | CCTP domain 26
#
# Changes (default to TESTNET, so nothing moves until env is set):
#   1. cctp-chains.ts MAINNET_CHAINS Arc row: chainId 0 -> 5042, real USDC/RPC/
#      explorer defaults (still env-overridable).
#   2. contracts.ts ARC_CHAIN_ID: 5042002 -> env-aware (mainnet 5042).
#   3. arc-chain.ts: id/name/rpc/explorer/testnet env-aware.
#
# v2: exact anchored replacements (assert count==1 each), marker-guarded
# backup-once per file, idempotent, --revert byte-identical. No em-dashes.
# Run from repo root.
# ============================================================================
set -euo pipefail

STAMP="$(date +%Y%m%d-%H%M%S)"
MARK="__NEXUM_MAINNET_M3__"

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

CC="$WEB/lib/cctp-chains.ts"
CON="$WEB/lib/contracts.ts"
AC="$WEB/lib/arc-chain.ts"
FILES=("$CC" "$CON" "$AC")
for f in "${FILES[@]}"; do [ -f "$f" ] || { echo "ERROR: missing $f"; exit 1; }; done

if [ "${1:-}" = "--revert" ]; then
  for f in "${FILES[@]}"; do
    bak="$(ls -1t "$f".bak.* 2>/dev/null | head -1 || true)"
    if [ -n "$bak" ]; then cp "$bak" "$f"; echo "restored $(basename "$f")"; else echo "(no backup $(basename "$f"))"; fi
  done
  echo "Revert done."; exit 0
fi

already=1
for f in "${FILES[@]}"; do grep -q "$MARK" "$f" || already=0; done
[ "$already" = "1" ] && { echo "Already applied. Nothing to do."; exit 0; }

python3 - "$STAMP" "$MARK" "$CC" "$CON" "$AC" <<'PYEOF'
import sys, os
stamp, mark = sys.argv[1], sys.argv[2]
CC, CON, AC = sys.argv[3:6]
edits = {}

# ---- 1. cctp-chains MAINNET Arc row --------------------------------------
edits.setdefault(CC, []).append((
"""  {
    key: 'arc', name: 'Arc', domain: 26, chainId: 0,   // set when Arc mainnet lands
    usdc: process.env.NEXT_PUBLIC_ARC_USDC ?? '',
    rpcUrl:  process.env.NEXT_PUBLIC_ARC_RPC_URL ?? '',
    explorer: 'https://arcscan.app',
    isHome: true,
  },""",
"""  {
    key: 'arc', name: 'Arc', domain: 26, chainId: 5042,
    usdc: process.env.NEXT_PUBLIC_ARC_USDC ?? '0x3600000000000000000000000000000000000000',
    rpcUrl:  process.env.NEXT_PUBLIC_ARC_RPC_URL ?? 'https://rpc.mainnet.arc.io',
    explorer: 'https://explorer.arc.io',
    isHome: true,
  },""",
"1 cctp-chains MAINNET Arc row"))

# ---- 2. contracts.ts ARC_CHAIN_ID env-aware ------------------------------
edits.setdefault(CON, []).append((
"export const ARC_CHAIN_ID  = 5042002\n"
"export const ARC_RPC_URL   = process.env.NEXT_PUBLIC_ARC_RPC_URL ?? 'https://rpc.testnet.arc.network'",
"const ARC_IS_MAINNET = (process.env.NEXT_PUBLIC_CCTP_ENV ?? 'testnet') === 'mainnet'\n"
"export const ARC_CHAIN_ID  = Number(process.env.NEXT_PUBLIC_ARC_CHAIN_ID ?? (ARC_IS_MAINNET ? 5042 : 5042002))\n"
"export const ARC_RPC_URL   = process.env.NEXT_PUBLIC_ARC_RPC_URL ?? (ARC_IS_MAINNET ? 'https://rpc.mainnet.arc.io' : 'https://rpc.testnet.arc.network')",
"2 contracts.ts ARC_CHAIN_ID env"))

# ---- 3. arc-chain.ts env-aware -------------------------------------------
edits.setdefault(AC, []).append((
"""const RPC = process.env.NEXT_PUBLIC_ARC_RPC_URL ?? 'https://rpc.testnet.arc.network'

export const arcTestnet = defineChain({
  id: 5042002,
  name: 'Arc Testnet',
  nativeCurrency: {
    decimals: 18,
    name: 'USD Coin',
    symbol: 'USDC',
  },
  rpcUrls: {
    default: {
      http:      [RPC],
      webSocket: [RPC.replace('https://', 'wss://')],
    },
    blockdaemon: {
      http: ['https://rpc.blockdaemon.testnet.arc.network'],
    },
  },
  blockExplorers: {
    default: {
      name: 'ArcScan',
      url:  'https://testnet.arcscan.app',
    },
  },
  testnet: true,
})""",
"""const ARC_IS_MAINNET = (process.env.NEXT_PUBLIC_CCTP_ENV ?? 'testnet') === 'mainnet'
const RPC = process.env.NEXT_PUBLIC_ARC_RPC_URL ?? (ARC_IS_MAINNET ? 'https://rpc.mainnet.arc.io' : 'https://rpc.testnet.arc.network')
const ARC_EXPLORER = ARC_IS_MAINNET ? 'https://explorer.arc.io' : 'https://testnet.arcscan.app'

export const arcTestnet = defineChain({
  id: Number(process.env.NEXT_PUBLIC_ARC_CHAIN_ID ?? (ARC_IS_MAINNET ? 5042 : 5042002)),
  name: ARC_IS_MAINNET ? 'Arc' : 'Arc Testnet',
  nativeCurrency: {
    decimals: 18,
    name: 'USD Coin',
    symbol: 'USDC',
  },
  rpcUrls: {
    default: {
      http:      [RPC],
      webSocket: [RPC.replace('https://', 'wss://')],
    },
  },
  blockExplorers: {
    default: {
      name: ARC_IS_MAINNET ? 'ArcExplorer' : 'ArcScan',
      url:  ARC_EXPLORER,
    },
  },
  testnet: !ARC_IS_MAINNET,
})""",
"3 arc-chain.ts env-aware"))

# --------------------------------------------------------------------------
def apply(path, changes):
    with open(path,'r',encoding='utf-8') as fh: text = fh.read()
    if mark in text:
        print(f"  {os.path.basename(path)}: marker present, skipping"); return text, False
    for old,new,label in changes:
        c = text.count(old)
        if c != 1:
            raise SystemExit(f"ABORT [{label}] in {os.path.basename(path)}: matched {c} (need 1). No files changed.")
        text = text.replace(old,new,1); print(f"  {os.path.basename(path)}: {label}")
    return text, True

staged = {}
for path, changes in edits.items():
    t, ch = apply(path, changes)
    if ch: staged[path] = t

for path, t in staged.items():
    bak = f"{path}.bak.{stamp}"
    if not os.path.exists(bak):
        with open(path,'r',encoding='utf-8') as fh: orig = fh.read()
        with open(bak,'w',encoding='utf-8') as fh: fh.write(orig)
    if not t.endswith("\n"): t += "\n"
    t += f"// {mark} {stamp}\n"
    with open(path,'w',encoding='utf-8') as fh: fh.write(t)
    print(f"  wrote {os.path.basename(path)}")
print("M3 edits complete.")
PYEOF

echo ""
echo "M3 applied. Verify: cd $WEB && rm -rf .next && npx tsc --noEmit && npm run build"
echo "Revert: bash $(basename "$0") --revert"
