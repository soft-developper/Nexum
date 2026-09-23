#!/usr/bin/env bash
# ============================================================================
# nexum-mainnet-M2-api.sh   (API-ONLY, v2 anchored-edit)
#
# MAINNET CUTOVER - Part M2 of 4. Makes the API's Arc chain config env-driven
# so CCTP_ENV=mainnet + the Arc mainnet env vars flip it, and fixes the Circle
# blockchain map that still said ARC-TESTNET in the mainnet branch.
#
# Verified Arc mainnet values (official docs):
#   chainId 5042 | RPC rpc.mainnet.arc.io | explorer explorer.arc.io
#   Circle Wallets enum: ARC (mainnet) / ARC-TESTNET (testnet)
#   USDC 0x3600...0000 (same both envs) | CCTP domain 26 | decimals via ERC-20 (6)
#
# Changes (all default to TESTNET values, so nothing moves until env is set):
#   1. arc.ts            : chain id/name/rpc/explorer/testnet all env-driven
#                          (ARC_CHAIN_ID, ARC_RPC_URL, ARC_EXPLORER_URL, CCTP_ENV)
#   2. txSettler.ts      : inline Arc chain id -> ARC_CHAIN_ID env (default 5042002)
#   3. treasuryChecker.ts: same
#   4. wallet.ts         : same
#   5. circleWallets.ts  : mainnet cctpBlockchainFor map arc 'ARC-TESTNET'->'ARC'
#                          + add missing mainnet codes (OP/AVAX/UNI/MONAD),
#                          verified from Circle supported-blockchains.
#      PRIMARY_BLOCKCHAIN already respects CIRCLE_BLOCKCHAIN (set it to ARC in env).
#
# v2: exact anchored replacements (assert count==1 each), marker-guarded
# backup-once per file, idempotent, --revert byte-identical. No em-dashes.
# Run from repo root.
# ============================================================================
set -euo pipefail

STAMP="$(date +%Y%m%d-%H%M%S)"
MARK="__NEXUM_MAINNET_M2__"

ROOT=""
for cand in "." ".." "$HOME/AfriFX" "$(pwd)"; do
  if [ -d "$cand/nexum-api" ]; then ROOT="$(cd "$cand" && pwd)"; break; fi
done
if [ -z "$ROOT" ]; then
  hit="$(find . -maxdepth 3 -type d -name nexum-api 2>/dev/null | head -1 || true)"
  [ -n "$hit" ] && ROOT="$(cd "$(dirname "$hit")" && pwd)"
fi
[ -z "$ROOT" ] && { echo "ERROR: could not find nexum-api from $(pwd)"; exit 1; }
API="$ROOT/nexum-api"
echo "repo root : $ROOT"

ARC="$API/src/services/arc.ts"
TXS="$API/src/jobs/txSettler.ts"
TRC="$API/src/jobs/treasuryChecker.ts"
WAL="$API/src/routes/wallet.ts"
CW="$API/src/services/circleWallets.ts"
FILES=("$ARC" "$TXS" "$TRC" "$WAL" "$CW")
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

python3 - "$STAMP" "$MARK" "$ARC" "$TXS" "$TRC" "$WAL" "$CW" <<'PYEOF'
import sys, os
stamp, mark = sys.argv[1], sys.argv[2]
ARC, TXS, TRC, WAL, CW = sys.argv[3:8]
edits = {}

# ---- 1. arc.ts : full env-driven chain def -------------------------------
edits.setdefault(ARC, []).append((
"""// Arc Testnet Chain ID 5042002
export const arcTestnet = defineChain({
  id: 5042002,
  name: 'Arc Testnet',
  nativeCurrency: { decimals: 18, name: 'USD Coin', symbol: 'USDC' },
  rpcUrls: {
    default: { http: [process.env.ARC_RPC_URL ?? 'https://rpc.testnet.arc.network'] },
  },
  blockExplorers: {
    default: { name: 'ArcScan', url: 'https://testnet.arcscan.app' },
  },
  testnet: true,
})

export const arcClient = createPublicClient({
  chain: arcTestnet,
  transport: http(process.env.ARC_RPC_URL ?? 'https://rpc.testnet.arc.network'),
})""",
"""// Arc chain - env-driven so CCTP_ENV=mainnet flips it to Arc mainnet.
// Mainnet: id 5042, rpc.mainnet.arc.io, explorer.arc.io (verified, official).
// Testnet: id 5042002, rpc.testnet.arc.network, testnet.arcscan.app.
const ARC_IS_MAINNET = (process.env.CCTP_ENV ?? 'testnet') === 'mainnet'
const ARC_CHAIN_ID   = Number(process.env.ARC_CHAIN_ID ?? (ARC_IS_MAINNET ? 5042 : 5042002))
const ARC_RPC        = process.env.ARC_RPC_URL ?? (ARC_IS_MAINNET ? 'https://rpc.mainnet.arc.io' : 'https://rpc.testnet.arc.network')
const ARC_EXPLORER   = process.env.ARC_EXPLORER_URL ?? (ARC_IS_MAINNET ? 'https://explorer.arc.io' : 'https://testnet.arcscan.app')

export const arcTestnet = defineChain({
  id: ARC_CHAIN_ID,
  name: ARC_IS_MAINNET ? 'Arc' : 'Arc Testnet',
  nativeCurrency: { decimals: 18, name: 'USD Coin', symbol: 'USDC' },
  rpcUrls: {
    default: { http: [ARC_RPC] },
  },
  blockExplorers: {
    default: { name: ARC_IS_MAINNET ? 'ArcExplorer' : 'ArcScan', url: ARC_EXPLORER },
  },
  testnet: !ARC_IS_MAINNET,
})

export const arcClient = createPublicClient({
  chain: arcTestnet,
  transport: http(ARC_RPC),
})""",
"1 arc.ts env-driven chain"))

# ---- 2/3/4. inline chain defs : id 5042002 -> env ARC_CHAIN_ID -----------
inline_old = (
"  chain: {\n"
"    id: 5042002, name: 'Arc Testnet',\n"
"    nativeCurrency: { name: 'ARC', symbol: 'ARC', decimals: 18 },\n"
"    rpcUrls: { default: { http: [ARC_RPC] } },\n"
"  } as any,"
)
inline_new = (
"  chain: {\n"
"    id: Number(process.env.ARC_CHAIN_ID ?? ((process.env.CCTP_ENV ?? 'testnet') === 'mainnet' ? 5042 : 5042002)),\n"
"    name: (process.env.CCTP_ENV ?? 'testnet') === 'mainnet' ? 'Arc' : 'Arc Testnet',\n"
"    nativeCurrency: { name: 'ARC', symbol: 'ARC', decimals: 18 },\n"
"    rpcUrls: { default: { http: [ARC_RPC] } },\n"
"  } as any,"
)
edits.setdefault(TXS, []).append((inline_old, inline_new, "2 txSettler chain id env"))
edits.setdefault(TRC, []).append((inline_old, inline_new, "3 treasuryChecker chain id env"))
edits.setdefault(WAL, []).append((inline_old, inline_new, "4 wallet.ts chain id env"))

# Also bump the ARC_RPC default in the 3 files so mainnet RPC is used when env absent.
rpc_old = "process.env.ARC_RPC_URL ?? 'https://rpc.testnet.arc.network'"
rpc_new = "process.env.ARC_RPC_URL ?? ((process.env.CCTP_ENV ?? 'testnet') === 'mainnet' ? 'https://rpc.mainnet.arc.io' : 'https://rpc.testnet.arc.network')"
edits.setdefault(TXS, []).append((rpc_old, rpc_new, "2b txSettler ARC_RPC default"))
edits.setdefault(TRC, []).append((rpc_old, rpc_new, "3b treasuryChecker ARC_RPC default"))
edits.setdefault(WAL, []).append((rpc_old, rpc_new, "4b wallet.ts ARC_RPC default"))

# ---- 5. circleWallets.ts : fix mainnet map -------------------------------
edits.setdefault(CW, []).append((
"  const mainnet: Record<string, string> = {\n"
"    arc: 'ARC-TESTNET', base: 'BASE', ethereum: 'ETH',\n"
"    arbitrum: 'ARB', polygon: 'MATIC',\n"
"  }",
"  const mainnet: Record<string, string> = {\n"
"    arc: 'ARC', base: 'BASE', ethereum: 'ETH',\n"
"    arbitrum: 'ARB', polygon: 'MATIC',\n"
"    optimism: 'OP', avalanche: 'AVAX',\n"
"    unichain: 'UNI', monad: 'MONAD',\n"
"  }",
"5 circleWallets mainnet map"))

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
print("M2 edits complete.")
PYEOF

echo ""
echo "M2 applied. Verify: cd $API && npx tsc --noEmit"
echo "Revert: bash $(basename "$0") --revert"
