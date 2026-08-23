#!/usr/bin/env bash
#
# fix-landing-copy-update.sh
#
# WHAT: Updates landing-page copy to match what actually shipped:
#         - removes all "connect an external wallet / self-custody" mentions
#           (Circle wallet is the only option now)
#         - replaces the retired "Trade" feature card with "On/Off-ramp"
#         - refreshes the Wallet feature + closing CTA copy
#
# CHANGES (5 anchored edits across 2 files):
#   nexum-web/components/landing/LandingHowItWorks.tsx
#        step 01 body - drop external-wallet clause
#   nexum-web/components/landing/LandingFeatures.tsx
#        import  ArrowLeftRight -> ArrowDownUp
#        Exchange group  Trade card -> On/Off-ramp card
#        Wallet feature overview - drop self-custody line
#        closing CTA - drop "Connect a wallet"
#
# SCOPE: web only, 2 files, copy + one icon import. Hero "Non-custodial" badge is
#        intentionally left as-is (part of the separate external-wallet question).
#
# DELIVERY: v2 - anchored byte-exact edits (assert count==1 each, validated
#           across both files before any write), backup-once-per-run, idempotent
#           marker guard, --revert restores newest backups.
#
# USAGE:
#   bash fix-landing-copy-update.sh          # apply
#   bash fix-landing-copy-update.sh --revert # restore newest backups
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_ROOT"

HIW="nexum-web/components/landing/LandingHowItWorks.tsx"
FEAT="nexum-web/components/landing/LandingFeatures.tsx"
STAMP="$(date +%Y%m%d-%H%M%S)"
FILES=("$HIW" "$FEAT")

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

# ----- idempotency guard (marker = external-wallet copy already gone) -----
if ! grep -qF "connect an external wallet if you prefer self-custody" "$HIW"; then
  echo "already applied: external-wallet copy absent from $HIW - nothing to do"
  exit 0
fi

python3 - "$HIW" "$FEAT" "$STAMP" <<'PY'
import sys, os
hiw, feat, stamp = sys.argv[1], sys.argv[2], sys.argv[3]

def read(p):
    with open(p, encoding="utf-8") as f: return f.read()
def backup_once(p, content):
    bak = f"{p}.bak.{stamp}"
    if not os.path.exists(bak):
        with open(bak, "w", encoding="utf-8") as b: b.write(content)

plan = {
  hiw: [
    ("step01",
     "    body: 'Sign in with Google or email to get a secure Circle wallet, no seed phrase needed, or connect an external wallet if you prefer self-custody.',",
     "    body: 'Sign in with Google or email and get a secure Circle wallet, no seed phrase, no crypto setup. Your keys stay yours.',"),
  ],
  feat: [
    ("import",
     "  ArrowLeftRight, Globe, Send, Store, FileText, BarChart3,",
     "  ArrowDownUp, Globe, Send, Store, FileText, BarChart3,"),
    ("trade_card",
     "      {\n"
     "        icon: ArrowLeftRight,\n"
     "        name: 'Trade',\n"
     "        overview: 'Live rates between USDC and 160+ currencies worldwide, with fees shown upfront before you commit.',\n"
     "        useCase: 'A freelancer paid in USDC checks the live NGN rate and sees exactly what a conversion would cost.',\n"
     "      },\n",
     "      {\n"
     "        icon: ArrowDownUp,\n"
     "        name: 'On/Off-ramp',\n"
     "        overview: 'Move money between your bank and USDC through our regulated payments partner. Deposit local currency to fund your wallet, or cash out USDC straight to a bank account.',\n"
     "        useCase: 'Top up with a bank transfer, or withdraw USDC to your account in USD or EUR, no exchange, no manual crypto steps.',\n"
     "      },\n"),
    ("wallet_overview",
     "        overview: 'Sign in with Google or email to get a secure Circle wallet, your keys, no seed phrase required. Prefer self-custody? Connect an external wallet instead.',",
     "        overview: 'Sign in with Google or email to get a secure Circle wallet, your keys, no seed phrase required. Everything is ready the moment you sign in, no crypto setup.',"),
    ("cta",
     "          Connect a wallet or sign in with Google, you\u2019ll be transacting on Arc in under a minute.",
     "          Sign in with Google or email, you\u2019ll be transacting on Arc in under a minute."),
  ],
}

# validate all anchors first
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
h = read(hiw); f = read(feat)
for blob, label in ((h, "HowItWorks"), (f, "Features")):
    assert "external wallet" not in blob, f"{label} still mentions external wallet"
assert "self-custody" not in f and "Connect a wallet" not in f, "Features still has self-custody/connect copy"
assert "ArrowLeftRight" not in f, "Features still imports ArrowLeftRight"
assert f.count("On/Off-ramp") == 1 and f.count("ArrowDownUp") == 2
print("OK: landing copy updated (external-wallet removed, Trade->On/Off-ramp, CTA refreshed)")
PY

echo ""
echo "Done. Standard deploy (web only):"
echo "  cd ~/AfriFX/nexum-web && rm -rf .next && npx tsc --noEmit && npm run build"
echo "  cd ~/AfriFX && git add -A && git commit -m 'copy: update landing for Circle-only wallet + On/Off-ramp' && git push"
