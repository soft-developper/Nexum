#!/usr/bin/env bash
# ============================================================================
# nexum-mainnet-M1-contracts.sh   (CONTRACTS-ONLY, v2 anchored-edit)
#
# MAINNET CUTOVER - Part M1 of 4. Adds an `arc_mainnet` hardhat network so the
# NexumVault can be deployed to Arc MAINNET, plus its arcscan/explorer verify
# entry. All Arc-mainnet values below are verified from official docs:
#   - Arc mainnet chain ID    : 5042            (docs.arc.io / ChainList)
#   - Arc mainnet RPC         : rpc.mainnet.arc.io   (Circle/Arc official)
#   - Arc mainnet explorer    : explorer.arc.io (Blockscout; NOT arcscan.app)
#   - Arc mainnet USDC        : 0x3600...0000   (SAME as testnet - predeploy)
#   - Arc mainnet TokenMessengerV2 : 0x28b5a0e9C621a5BadaA536219b3a228C8168cf5d
#         (Circle CCTP mainnet, uniform across standard chains)
#
# deploy.ts already reads:
#   - USDC_ADDRESS = 0x3600...0000  (identical on mainnet, no change needed)
#   - TOKEN_MESSENGER = env ARC_TOKEN_MESSENGER || <testnet default>
# So the ONLY code change is the hardhat network + customChain. At deploy time
# you set ARC_TOKEN_MESSENGER to the mainnet messenger (see runbook in M4).
#
# After applying, deploy with (on YOUR machine, needs mainnet USDC for gas):
#   cd nexum-contracts
#   npx hardhat compile
#   ARC_MAINNET_RPC_URL=https://rpc.mainnet.arc.io \
#   ARC_TOKEN_MESSENGER=0x28b5a0e9C621a5BadaA536219b3a228C8168cf5d \
#   DEPLOYER_PRIVATE_KEY=0x<key> \
#     npx hardhat run scripts/deploy.ts --network arc_mainnet
#   # then verify:
#   NEXUM_VAULT_ADDRESS=0x<NEW> ARC_MAINNET_RPC_URL=https://rpc.mainnet.arc.io \
#   DEPLOYER_PRIVATE_KEY=0x<key> \
#     npx hardhat run scripts/verify-deploy.ts --network arc_mainnet
#
# CRITICAL: deployer wallet becomes owner(); it MUST equal the mainnet
# PLATFORM_WALLET_PRIVATE_KEY holder (the watcher signs owner calls).
#
# v2: exact anchored replacement (assert count==1), marker-guarded backup-once,
# idempotent, --revert byte-identical. No em-dashes. Run from repo root.
# ============================================================================
set -euo pipefail

STAMP="$(date +%Y%m%d-%H%M%S)"
MARK="__NEXUM_MAINNET_M1__"

ROOT=""
for cand in "." ".." "$HOME/AfriFX" "$(pwd)"; do
  if [ -d "$cand/nexum-contracts" ]; then ROOT="$(cd "$cand" && pwd)"; break; fi
done
if [ -z "$ROOT" ]; then
  hit="$(find . -maxdepth 3 -type d -name nexum-contracts 2>/dev/null | head -1 || true)"
  [ -n "$hit" ] && ROOT="$(cd "$(dirname "$hit")" && pwd)"
fi
[ -z "$ROOT" ] && { echo "ERROR: could not find nexum-contracts from $(pwd)"; exit 1; }
FILE="$ROOT/nexum-contracts/hardhat.config.ts"
echo "repo root : $ROOT"
[ -f "$FILE" ] || { echo "ERROR: missing $FILE"; exit 1; }

if [ "${1:-}" = "--revert" ]; then
  bak="$(ls -1t "$FILE".bak.* 2>/dev/null | head -1 || true)"
  if [ -n "$bak" ]; then cp "$bak" "$FILE"; echo "restored $(basename "$FILE")"; else echo "(no backup)"; fi
  echo "Revert done."; exit 0
fi

if grep -q "$MARK" "$FILE"; then echo "Already applied. Nothing to do."; exit 0; fi

python3 - "$STAMP" "$MARK" "$FILE" <<'PYEOF'
import sys, os
stamp, mark, path = sys.argv[1], sys.argv[2], sys.argv[3]

# --- edit 1: add arc_mainnet network after arc_testnet block ---
old_net = (
"    arc_testnet: {\n"
"      url:      process.env.ARC_RPC_URL ?? 'https://rpc.testnet.arc.network',\n"
"      chainId:  5042002,\n"
"      accounts: [PRIVATE_KEY],\n"
"      // Arc uses USDC as gas token ensure deployer wallet has testnet USDC\n"
"      // Faucet: https://faucet.circle.com\n"
"    },\n"
)
new_net = (
"    arc_testnet: {\n"
"      url:      process.env.ARC_RPC_URL ?? 'https://rpc.testnet.arc.network',\n"
"      chainId:  5042002,\n"
"      accounts: [PRIVATE_KEY],\n"
"      // Arc uses USDC as gas token ensure deployer wallet has testnet USDC\n"
"      // Faucet: https://faucet.circle.com\n"
"    },\n"
"    arc_mainnet: {\n"
"      url:      process.env.ARC_MAINNET_RPC_URL ?? 'https://rpc.mainnet.arc.io',\n"
"      chainId:  5042,\n"
"      accounts: [PRIVATE_KEY],\n"
"      // Arc mainnet uses USDC as gas token - deployer wallet needs mainnet USDC.\n"
"    },\n"
)

# --- edit 2: add arc_mainnet apiKey entry ---
old_key = (
"    apiKey: {\n"
"      arc_testnet: process.env.ARCSCAN_API_KEY ?? 'placeholder',\n"
"    },\n"
)
new_key = (
"    apiKey: {\n"
"      arc_testnet: process.env.ARCSCAN_API_KEY ?? 'placeholder',\n"
"      arc_mainnet: process.env.ARCSCAN_API_KEY ?? 'placeholder',\n"
"    },\n"
)

# --- edit 3: add arc_mainnet customChain after the arc_testnet one ---
old_cc = (
"      {\n"
"        network: 'arc_testnet',\n"
"        chainId: 5042002,\n"
"        urls: {\n"
"          apiURL:     'https://testnet.arcscan.app/api',\n"
"          browserURL: 'https://testnet.arcscan.app',\n"
"        },\n"
"      },\n"
)
new_cc = (
"      {\n"
"        network: 'arc_testnet',\n"
"        chainId: 5042002,\n"
"        urls: {\n"
"          apiURL:     'https://testnet.arcscan.app/api',\n"
"          browserURL: 'https://testnet.arcscan.app',\n"
"        },\n"
"      },\n"
"      {\n"
"        network: 'arc_mainnet',\n"
"        chainId: 5042,\n"
"        urls: {\n"
"          apiURL:     'https://explorer.arc.io/api',\n"
"          browserURL: 'https://explorer.arc.io',\n"
"        },\n"
"      },\n"
)

with open(path, 'r', encoding='utf-8') as fh:
    text = fh.read()
if mark in text:
    raise SystemExit(0)

for label, old, new in [("network", old_net, new_net),
                        ("apiKey", old_key, new_key),
                        ("customChain", old_cc, new_cc)]:
    c = text.count(old)
    if c != 1:
        raise SystemExit(f"ABORT [{label}]: anchor matched {c} times (need 1). File unchanged.")

bak = f"{path}.bak.{stamp}"
if not os.path.exists(bak):
    with open(bak, 'w', encoding='utf-8') as fh:
        fh.write(text)

text = text.replace(old_net, new_net, 1)
text = text.replace(old_key, new_key, 1)
text = text.replace(old_cc, new_cc, 1)
if not text.endswith("\n"): text += "\n"
text += f"// {mark} {stamp}\n"

with open(path, 'w', encoding='utf-8') as fh:
    fh.write(text)
print("added arc_mainnet network + apiKey + customChain (backup:", os.path.basename(bak) + ")")
PYEOF

echo ""
echo "M1 applied. Verify: cd $ROOT/nexum-contracts && npx hardhat compile"
echo "Revert: bash $(basename "$0") --revert"
