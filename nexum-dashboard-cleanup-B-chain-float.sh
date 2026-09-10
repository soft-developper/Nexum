#!/usr/bin/env bash
# ============================================================================
# nexum-dashboard-cleanup-B-chain-float.sh   (API + WEB, v2 delivery)
#
# Part B of the dashboard cleanup. Two features that need an API change:
#
#  B1. Per-chain explorer links on recent-activity lists.
#      Sends can happen on any of the 9 chains, but the dashboard AND wallet
#      "recent transactions" lists hardcoded testnet.arcscan.app, so a Base or
#      Polygon send linked to the wrong explorer. Fix mirrors history/page.tsx:
#        - API user.ts   : recent tx payload now carries fromChain (from_chain).
#        - API wallet.ts : /wallet/:address tx payload now carries fromChain.
#        - WEB dashboard  : RecentTx += fromChain; link uses chainByKey().explorer.
#        - WEB wallet     : tx link uses chainByKey().explorer.
#      Legacy rows with no from_chain fall back to Arc (unchanged behaviour).
#
#  B2. Payroll "Payroll float" balance.
#      The batch summary showed the USER's own wallet USDC ("Your balance"),
#      but payroll pays out of the developer-controlled FLOAT (per employer).
#      NEW hooks/useDisbursementFloat.ts reads /payroll/disbursement/status;
#      PayrollCreateContent shows "Payroll float" with that value instead.
#
# v2: NEW file delivered via its own base64 heredoc, decoded + verified (marker
# present, non-empty) before it lands. Existing files edited by exact anchored
# single-replacements (assert count==1). Idempotent (markers), --revert
# (restores newest per-file backups + removes the new hook), timestamped
# backups (once per file per run). No em-dashes. Run from repo root.
# ============================================================================
set -euo pipefail

STAMP="$(date +%Y%m%d-%H%M%S)"
MARK="__NEXUM_DASH_CLEANUP_B__"
HOOK_MARK="__NEXUM_USE_DISBURSEMENT_FLOAT__"

# ---- locate repo root (dir containing nexum-web AND nexum-api) -------------
ROOT=""
for cand in "." ".." "$HOME/AfriFX" "$(pwd)"; do
  if [ -d "$cand/nexum-web" ] && [ -d "$cand/nexum-api" ]; then ROOT="$(cd "$cand" && pwd)"; break; fi
done
if [ -z "$ROOT" ]; then
  hit="$(find . -maxdepth 3 -type d -name nexum-web 2>/dev/null | head -1 || true)"
  [ -n "$hit" ] && ROOT="$(cd "$(dirname "$hit")" && pwd)"
fi
[ -z "$ROOT" ] && { echo "ERROR: could not find repo root (needs nexum-web + nexum-api) from $(pwd)"; exit 1; }
WEB="$ROOT/nexum-web"
API="$ROOT/nexum-api"
echo "repo root : $ROOT"

USER_TS="$API/src/routes/user.ts"
WALLET_TS="$API/src/routes/wallet.ts"
DASH="$WEB/app/(app)/dashboard/page.tsx"
WALLETC="$WEB/app/(app)/wallet/WalletContent.tsx"
PAYROLL="$WEB/app/(app)/treasury/payroll/PayrollCreateContent.tsx"
HOOK="$WEB/hooks/useDisbursementFloat.ts"

for f in "$USER_TS" "$WALLET_TS" "$DASH" "$WALLETC" "$PAYROLL"; do
  [ -f "$f" ] || { echo "ERROR: missing $f"; exit 1; }
done

EDIT_FILES=("$USER_TS" "$WALLET_TS" "$DASH" "$WALLETC" "$PAYROLL")

# ---------------------------------------------------------------------------
# --revert
# ---------------------------------------------------------------------------
if [ "${1:-}" = "--revert" ]; then
  echo "Reverting ..."
  for f in "${EDIT_FILES[@]}"; do
    bak="$(ls -1t "$f".bak.* 2>/dev/null | head -1 || true)"
    if [ -n "$bak" ]; then cp "$bak" "$f"; echo "  restored $(basename "$f")"; else echo "  (no backup for $(basename "$f"))"; fi
  done
  if [ -f "$HOOK" ] && grep -q "$HOOK_MARK" "$HOOK"; then rm -f "$HOOK"; echo "  removed new hook useDisbursementFloat.ts"; fi
  echo "Revert done."
  exit 0
fi

# ---------------------------------------------------------------------------
# idempotency
# ---------------------------------------------------------------------------
already=1
for f in "${EDIT_FILES[@]}"; do grep -q "$MARK" "$f" || already=0; done
[ -f "$HOOK" ] || already=0
if [ "$already" = "1" ]; then echo "Already applied. Nothing to do."; exit 0; fi

# ---------------------------------------------------------------------------
# STEP 1 - decode + verify the NEW hook to a temp file (do not place yet).
# ---------------------------------------------------------------------------
TMP_HOOK="$(mktemp)"
cat > "$TMP_HOOK.b64" <<'B64_HOOK'
J3VzZSBjbGllbnQnCi8vIF9fTkVYVU1fVVNFX0RJU0JVUlNFTUVOVF9GTE9BVF9fCi8vIFJlYWQt
b25seSB2aWV3IG9mIHRoZSBjYWxsZXIncyBwYXlyb2xsIGZsb2F0ICh0aGUgZGV2ZWxvcGVyLWNv
bnRyb2xsZWQKLy8gZGlzYnVyc2VtZW50IHdhbGxldCBiYWxhbmNlLCBwZXIgZW1wbG95ZXIpLiBQ
YXlyb2xsIHBheXMgT1VUIG9mIHRoaXMgZmxvYXQsCi8vIG5vdCB0aGUgdXNlcidzIG93biBVU0RD
IHdhbGxldCwgc28gdGhpcyBpcyB0aGUgYmFsYW5jZSB0aGUgcGF5cm9sbCBVSSBzaG91bGQKLy8g
c2hvdy4gTWlycm9ycyB0aGUgZmV0Y2ggRGlzYnVyc2VtZW50RmxvYXRDYXJkIGFscmVhZHkgZG9l
cywgZXhwb3NlZCBhcyBhIGhvb2sKLy8gc28gdGhlIGJhdGNoIHN1bW1hcnkgYW5kIHRoZSBjYXJk
IHJlYWQgb25lIHNvdXJjZS4KaW1wb3J0IHsgdXNlUXVlcnkgfSBmcm9tICdAdGFuc3RhY2svcmVh
Y3QtcXVlcnknCmltcG9ydCB7IHVzZUFjY291bnRBZGRyZXNzIGFzIHVzZUFjY291bnQgfSBmcm9t
ICdAL2hvb2tzL3VzZUFjY291bnRBZGRyZXNzJwoKY29uc3QgQVBJID0gcHJvY2Vzcy5lbnYuTkVY
VF9QVUJMSUNfQVBJX1VSTCA/PyAnaHR0cDovL2xvY2FsaG9zdDo0MDAwJwoKZXhwb3J0IGludGVy
ZmFjZSBEaXNidXJzZW1lbnRGbG9hdCB7CiAgY29uZmlndXJlZDogYm9vbGVhbgogIGJhbGFuY2U6
ICAgIG51bWJlciB8IG51bGwKfQoKZXhwb3J0IGZ1bmN0aW9uIHVzZURpc2J1cnNlbWVudEZsb2F0
KCkgewogIGNvbnN0IHsgYWRkcmVzcyB9ID0gdXNlQWNjb3VudCgpCiAgcmV0dXJuIHVzZVF1ZXJ5
PERpc2J1cnNlbWVudEZsb2F0Pih7CiAgICBxdWVyeUtleTogWydkaXNidXJzZW1lbnQtZmxvYXQn
LCBhZGRyZXNzXSwKICAgIGVuYWJsZWQ6ICBCb29sZWFuKGFkZHJlc3MpLAogICAgcXVlcnlGbjog
IGFzeW5jICgpID0+IHsKICAgICAgY29uc3QgcmVzICA9IGF3YWl0IGZldGNoKGAke0FQSX0vcGF5
cm9sbC9kaXNidXJzZW1lbnQvc3RhdHVzP3dhbGxldD0ke2FkZHJlc3N9YCkKICAgICAgY29uc3Qg
ZGF0YSA9IGF3YWl0IHJlcy5qc29uKCkuY2F0Y2goKCkgPT4gKHt9KSkKICAgICAgcmV0dXJuIHsK
ICAgICAgICBjb25maWd1cmVkOiBCb29sZWFuKGRhdGEuY29uZmlndXJlZCksCiAgICAgICAgYmFs
YW5jZTogICAgdHlwZW9mIGRhdGEuYmFsYW5jZSA9PT0gJ251bWJlcicgPyBkYXRhLmJhbGFuY2Ug
OiBudWxsLAogICAgICB9CiAgICB9LAogICAgc3RhbGVUaW1lOiAgICAgICAzMF8wMDAsCiAgICBy
ZWZldGNoSW50ZXJ2YWw6IDMwXzAwMCwKICB9KQp9Cg==
B64_HOOK
base64 --decode "$TMP_HOOK.b64" > "$TMP_HOOK"
if [ ! -s "$TMP_HOOK" ] || ! grep -q "$HOOK_MARK" "$TMP_HOOK"; then
  echo "ABORT: decoded hook empty or marker missing. Nothing changed."
  rm -f "$TMP_HOOK" "$TMP_HOOK.b64"; exit 1
fi
echo "new hook decoded + verified ($(wc -l < "$TMP_HOOK") lines)"

# ---------------------------------------------------------------------------
# STEP 2 - anchored edits (validate ALL before writing ANY), via Python.
# ---------------------------------------------------------------------------
python3 - "$STAMP" "$MARK" "$USER_TS" "$WALLET_TS" "$DASH" "$WALLETC" "$PAYROLL" <<'PYEOF'
import sys, os
stamp, mark = sys.argv[1], sys.argv[2]
USER_TS, WALLET_TS, DASH, WALLETC, PAYROLL = sys.argv[3:8]
edits = {}

# ---- B1 API user.ts : add from_chain to array-branch tx map --------------
edits.setdefault(USER_TS, []).append((
"        status: r[13], created_at: Number(r[15] ?? r[14]),",
"        status: r[13], created_at: Number(r[15] ?? r[14]), from_chain: r[16],",
"B1 user.ts tx array from_chain"))
edits.setdefault(USER_TS, []).append((
"      arcTxHash:    t.arc_tx_hash,\n      createdAt:    t.created_at,\n    }))",
"      arcTxHash:    t.arc_tx_hash,\n      fromChain:    t.from_chain ?? null,\n      createdAt:    t.created_at,\n    }))",
"B1 user.ts recent fromChain"))

# ---- B1 API wallet.ts : add from_chain to SELECT + both map branches ------
edits.setdefault(WALLET_TS, []).append((
"      sql`SELECT id, from_currency, to_currency, from_amount, to_amount,\n                 status, arc_tx_hash, reference, created_at\n          FROM transactions",
"      sql`SELECT id, from_currency, to_currency, from_amount, to_amount,\n                 status, arc_tx_hash, reference, created_at, from_chain\n          FROM transactions",
"B1 wallet.ts SELECT from_chain"))
edits.setdefault(WALLET_TS, []).append((
"      status: r[5], arcTxHash: r[6], reference: r[7], createdAt: Number(r[8]),\n    } : {",
"      status: r[5], arcTxHash: r[6], reference: r[7], createdAt: Number(r[8]),\n      fromChain: r[9] ?? null,\n    } : {",
"B1 wallet.ts array fromChain"))
edits.setdefault(WALLET_TS, []).append((
"      status: r.status, arcTxHash: r.arc_tx_hash, reference: r.reference,\n      createdAt: Number(r.created_at),\n    })",
"      status: r.status, arcTxHash: r.arc_tx_hash, reference: r.reference,\n      createdAt: Number(r.created_at), fromChain: r.from_chain ?? null,\n    })",
"B1 wallet.ts object fromChain"))

# ---- B1 WEB dashboard : import chainByKey, RecentTx += fromChain, link ----
edits.setdefault(DASH, []).append((
"import { useTokens }         from '@/lib/tokens'",
"import { useTokens }         from '@/lib/tokens'\nimport { chainByKey }        from '@/lib/cctp-chains'",
"B1 dashboard import chainByKey"))
edits.setdefault(DASH, []).append((
"  status: string; reference: string; arcTxHash: string; createdAt: number\n}",
"  status: string; reference: string; arcTxHash: string; createdAt: number\n  fromChain?: string | null\n}",
"B1 dashboard RecentTx fromChain"))
edits.setdefault(DASH, []).append((
"                  {tx.arcTxHash && (\n                    <a href={`https://testnet.arcscan.app/tx/${tx.arcTxHash}`}\n                      target=\"_blank\" rel=\"noopener noreferrer\" className=\"shrink-0\">",
"                  {tx.arcTxHash && (\n                    <a href={`${chainByKey(tx.fromChain ?? 'arc')?.explorer ?? 'https://testnet.arcscan.app'}/tx/${tx.arcTxHash}`}\n                      target=\"_blank\" rel=\"noopener noreferrer\" className=\"shrink-0\">",
"B1 dashboard explorer link"))

# ---- B1 WEB wallet : import chainByKey, link -----------------------------
edits.setdefault(WALLETC, []).append((
"import { useAllChainUsdcBalances } from '@/hooks/useAllChainUsdcBalances'",
"import { useAllChainUsdcBalances } from '@/hooks/useAllChainUsdcBalances'\nimport { chainByKey } from '@/lib/cctp-chains'",
"B1 wallet import chainByKey"))
edits.setdefault(WALLETC, []).append((
"                  {tx.arcTxHash && (\n                    <a href={`https://testnet.arcscan.app/tx/${tx.arcTxHash}`}\n                      target=\"_blank\" rel=\"noopener noreferrer\" className=\"shrink-0\">",
"                  {tx.arcTxHash && (\n                    <a href={`${chainByKey((tx as any).fromChain ?? 'arc')?.explorer ?? 'https://testnet.arcscan.app'}/tx/${tx.arcTxHash}`}\n                      target=\"_blank\" rel=\"noopener noreferrer\" className=\"shrink-0\">",
"B1 wallet explorer link"))

# ---- B2 WEB payroll : swap useUSDCBalance -> useDisbursementFloat, row ----
edits.setdefault(PAYROLL, []).append((
"import { useUSDCBalance } from '@/hooks/useUSDCBalance'",
"import { useDisbursementFloat } from '@/hooks/useDisbursementFloat'",
"B2 payroll import hook"))
edits.setdefault(PAYROLL, []).append((
"  const { formatted: balance } = useUSDCBalance()",
"  const { data: float } = useDisbursementFloat()\n  const floatBalance = float?.balance != null ? formatAmount(float.balance) : '0.00'",
"B2 payroll hook usage"))
edits.setdefault(PAYROLL, []).append((
"                ['Your balance',    `${balance} USDC`],",
"                ['Payroll float',   `${floatBalance} USDC`],",
"B2 payroll summary row"))

# --------------------------------------------------------------------------
def apply(path, changes):
    with open(path, 'r', encoding='utf-8') as fh: text = fh.read()
    if mark in text:
        print(f"  {os.path.basename(path)}: marker present, skipping"); return text, False
    for old, new, label in changes:
        c = text.count(old)
        if c != 1:
            raise SystemExit(f"ABORT [{label}] in {os.path.basename(path)}: anchor matched {c} times (need 1). No files changed.")
        text = text.replace(old, new, 1)
        print(f"  {os.path.basename(path)}: {label}")
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
print("edits complete.")
PYEOF

# ---------------------------------------------------------------------------
# STEP 3 - place the verified new hook (only after edits succeeded).
# ---------------------------------------------------------------------------
mkdir -p "$(dirname "$HOOK")"
cp "$TMP_HOOK" "$HOOK"
rm -f "$TMP_HOOK" "$TMP_HOOK.b64"
echo "  placed hooks/useDisbursementFloat.ts"

echo ""
echo "Script B applied."
echo "Verify API : cd $API && npx tsc --noEmit"
echo "Verify WEB : cd $WEB && rm -rf .next && npx tsc --noEmit && npm run build"
echo "Revert     : bash $(basename "$0") --revert"
