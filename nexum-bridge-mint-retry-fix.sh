#!/usr/bin/env bash
# ============================================================================
# Nexum bridge fix - correct the stranded-mint retry (Issue 2 of 2)
#
# THE BUG (confirmed by decoding a real stuck burn via get-messages-v2):
# the burn attested `complete`, destinationCaller was zero (anyone can mint),
# recipient + chain were correct - the message was fully mint-ready. Yet the
# mint produced NO tx hash and "Complete transfer" kept failing, even after
# "Waiting for the refreshed attestation".
#
# ROOT CAUSE: on any mint failure that wasn't 'already minted' / auth / chain,
# useCompleteBridge ASSUMED an expired attestation and ran a reattest cycle.
# With an already-complete attestation that is useless: the re-poll returns the
# same complete attestation, the re-mint fails identically, and Circle's REAL
# error (from createContractExecution on the destination - gas, contract, or a
# Circle-side rejection) was discarded. A submission failure was misreported as
# an attestation problem and could never be resolved from the UI.
#
# THE FIX (nexum-web/hooks/useCompleteBridge.ts):
# after a failed mint, RE-FETCH the attestation and branch:
#   * still `complete` -> message is valid, the mint SUBMISSION failed. Surface
#     Circle's actual error verbatim (and console.error it). No pointless reattest.
#   * no longer complete -> genuinely expired -> run the reattest cycle (the one
#     case it actually helps).
# Idempotent-success and auth/chain handling are unchanged.
#
# NOTE: this makes the real failure VISIBLE. After deploying, retry the stuck
# mint once - the error message (and browser console) will now show Circle's
# actual reason on Arc, which tells us the final fix (usually: top up gas on the
# destination, or a contract-address correction).
#
# Delivery contract (v2) + full deploy:
#   * patcher base64 + sha256 verified; exact-anchor; aborts on drift
#   * idempotent (marker __NEXUM_MINT_RETRY_FIX__); clean-only backup
#   * gate: rm -rf .next && npx tsc --noEmit && npm run build -> commit + push
#   * --revert restores the file ; --no-deploy applies only
#
# Run from REPO ROOT (folder containing nexum-web/).
#   bash nexum-bridge-mint-retry-fix.sh
#   bash nexum-bridge-mint-retry-fix.sh --no-deploy
#   bash nexum-bridge-mint-retry-fix.sh --revert
# ============================================================================
set -euo pipefail

WEB="nexum-web"
TARGET="$WEB/hooks/useCompleteBridge.ts"
MARKER="__NEXUM_MINT_RETRY_FIX__"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR=".nexum-mintfix-backup/${STAMP}"
PATCH_SHA="52be033ed1b322c5bd4ce104f02fd20c3f5c80558928094f7a2856ada13b23d3"
COMMIT_MSG="fix(bridge): surface real mint error; only reattest when attestation truly expired"

FLAG="${1:-}"
log(){ printf '  %s\n' "$*"; }
die(){ printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[ -d "$WEB" ] || die "Cannot find $WEB . Run from the repo root."

if [ "$FLAG" = "--revert" ]; then
  LATEST=""
  for d in $(ls -1dt .nexum-mintfix-backup/*/ 2>/dev/null); do
    if [ -f "${d}useCompleteBridge.ts" ]; then LATEST="$d"; break; fi
  done
  if [ -n "$LATEST" ]; then
    cp "${LATEST}useCompleteBridge.ts" "$TARGET" && log "Restored $TARGET"
  else
    log "No backup found; leaving file as-is."
  fi
  log "Reverted mint-retry fix."
  exit 0
fi

TPATCH="$(mktemp /tmp/mintfix.XXXXXX.py)"
trap 'rm -f "$TPATCH"' EXIT
base64 -d > "$TPATCH" <<'B64'
IyEvdXNyL2Jpbi9lbnYgcHl0aG9uMwoiIiIKRml4IHRoZSBzdHJhbmRlZC1taW50IHJldHJ5IGlu
IHVzZUNvbXBsZXRlQnJpZGdlLgoKQlVHOiBvbiBBTlkgbWludCBmYWlsdXJlIG90aGVyIHRoYW4g
J2FscmVhZHkgbWludGVkJyAvIGF1dGggLyBjaGFpbiwgdGhlIGNvZGUKYXNzdW1lZCBhbiBleHBp
cmVkIGF0dGVzdGF0aW9uIGFuZCByYW4gYSByZWF0dGVzdCBjeWNsZS4gQnV0IGlmIHRoZSBhdHRl
c3RhdGlvbgppcyBhbHJlYWR5IGBjb21wbGV0ZWAgKHZlcmlmaWVkIHZpYSBnZXQtbWVzc2FnZXMt
djIpLCByZWF0dGVzdGluZyBkb2VzIG5vdGhpbmcgLQp0aGUgcmUtcG9sbCByZXR1cm5zIHRoZSBz
YW1lIGNvbXBsZXRlIGF0dGVzdGF0aW9uIGFuZCB0aGUgcmUtbWludCBmYWlscyB0aGUgc2FtZQp3
YXkuIENpcmNsZSdzIFJFQUwgZXJyb3IgKGZyb20gY3JlYXRlQ29udHJhY3RFeGVjdXRpb24gb24g
dGhlIGRlc3RpbmF0aW9uKSB3YXMKZGlzY2FyZGVkLCBzbyBhIGdhcyAvIGNvbnRyYWN0IC8gQ2ly
Y2xlLXNpZGUgZmFpbHVyZSBsb29rZWQgbGlrZSBhbiBhdHRlc3RhdGlvbgpwcm9ibGVtIGFuZCB3
YXMgdW5maXhhYmxlIGZyb20gdGhlIFVJLgoKRklYOiBhZnRlciBhIGZhaWxlZCBtaW50LCBSRS1G
RVRDSCB0aGUgYXR0ZXN0YXRpb24gdG8gZGVjaWRlOgogICogc3RpbGwgYGNvbXBsZXRlYCAtPiB0
aGUgbWVzc2FnZSBpcyB2YWxpZDsgdGhlIGZhaWx1cmUgaXMgaW4gc3VibWlzc2lvbi4KICAgIFN1
cmZhY2UgQ2lyY2xlJ3MgYWN0dWFsIGVycm9yIHZlcmJhdGltLiBObyBwb2ludGxlc3MgcmVhdHRl
c3QuCiAgKiBOT1QgY29tcGxldGUgYW55bW9yZSAoZ2VudWluZWx5IGV4cGlyZWQvZ29uZSkgLT4g
VEhFTiBydW4gdGhlIHJlYXR0ZXN0CiAgICBjeWNsZSwgd2hpY2ggaXMgdGhlIG9ubHkgY2FzZSBp
dCBjYW4gYWN0dWFsbHkgaGVscC4KCklkZW1wb3RlbnQtc3VjY2VzcyBhbmQgYXV0aC9jaGFpbiBo
YW5kbGluZyBhcmUgcHJlc2VydmVkIHVuY2hhbmdlZC4KCk1hcmtlcjogX19ORVhVTV9NSU5UX1JF
VFJZX0ZJWF9fLiBFeGFjdC1hbmNob3I7IGFib3J0cyBvbiBkcmlmdC4KIiIiCmltcG9ydCBzeXMs
IGlvCgpQQVRIID0gIm5leHVtLXdlYi9ob29rcy91c2VDb21wbGV0ZUJyaWRnZS50cyIKTUFSS0VS
ID0gIl9fTkVYVU1fTUlOVF9SRVRSWV9GSVhfXyIKc3JjID0gaW8ub3BlbihQQVRILCBlbmNvZGlu
Zz0idXRmLTgiKS5yZWFkKCkKaWYgTUFSS0VSIGluIHNyYzoKICAgIHByaW50KGYiICB7UEFUSH06
IGFscmVhZHkgZml4ZWQgLSBza2lwcGluZy4iKQogICAgc3lzLmV4aXQoMCkKCk9MRCA9ICIiIiAg
ICAgIH0gY2F0Y2ggKG1pbnRFcnI6IGFueSkgewogICAgICAgIGNvbnN0IG0gPSBtaW50RXJyPy5t
ZXNzYWdlID8/ICcnCgogICAgICAgIC8vIElkZW1wb3RlbnQgc3VjY2VzczogdGhlIG1pbnQgYWxy
ZWFkeSBsYW5kZWQuCiAgICAgICAgaWYgKC9hbHJlYWR5IGJlZW4gdXNlZHxub25jZSBhbHJlYWR5
fGFscmVhZHkgbWludGVkfGFscmVhZHkgYmVlbiBwcm9jZXNzZWQvaS50ZXN0KG0pKSB7CiAgICAg
ICAgICBhd2FpdCByZWNvcmRDb21wbGV0ZWQoJ2FscmVhZHktbWludGVkJykKICAgICAgICAgIHNl
dE1pbnRUeCgnYWxyZWFkeS1taW50ZWQnKTsgc2V0U3RlcCgnZG9uZScpOyBzZXROb3RlKG51bGwp
CiAgICAgICAgICByZXR1cm4KICAgICAgICB9CiAgICAgICAgLy8gQXV0aCAvIGNoYWluIHByb21w
dHMgYXJlIGZvciB0aGUgY2FsbGVyIHRvIHJlc29sdmUsIG5vdCByZXRyeWFibGUgaGVyZS4KICAg
ICAgICBpZiAobWludEVyciBpbnN0YW5jZW9mIE5lZWRzUmVhdXRoRXJyb3IgfHwgbWludEVyciBp
bnN0YW5jZW9mIE5lZWRzQ2hhaW5FcnJvcikgewogICAgICAgICAgdGhyb3cgbWludEVycgogICAg
ICAgIH0KCiAgICAgICAgLy8gT3RoZXJ3aXNlIGF0dGVtcHQgT05FIHJlYXR0ZXN0IGN5Y2xlLiBU
aGlzIGNvdmVycyBhbiBleHBpcmVkCiAgICAgICAgLy8gYXR0ZXN0YXRpb24gYW5kIHRyYW5zaWVu
dCByZXZlcnQ7IGlmIHRoZSBtaW50IHRydWx5IGNhbid0IHByb2NlZWQKICAgICAgICAvLyB0aGUg
c2Vjb25kIGF0dGVtcHQgc3VyZmFjZXMgdGhlIHJlYWwgZXJyb3IuCiAgICAgICAgY29uc3Qgbm9u
Y2UgPSBjdXJyZW50QXR0Lm5vbmNlID8/IGN1cnJlbnRBdHQuZXZlbnROb25jZQogICAgICAgIGlm
ICghbm9uY2UpIHRocm93IG1pbnRFcnIKCiAgICAgICAgc2V0U3RlcCgncmVhdHRlc3RpbmcnKQog
ICAgICAgIHNldE5vdGUoJ0F0dGVzdGF0aW9uIG1heSBoYXZlIGV4cGlyZWQgLSByZXF1ZXN0aW5n
IGEgZnJlc2ggb25lIGZyb20gQ2lyY2xlLi4uJykKICAgICAgICBjb25zdCBvayA9IGF3YWl0IHJl
YXR0ZXN0KGlyaXNCYXNlKCksIG5vbmNlKQogICAgICAgIGlmICghb2spIHsKICAgICAgICAgIHRo
cm93IG5ldyBFcnJvcigKICAgICAgICAgICAgJ1RoZSBhdHRlc3RhdGlvbiBmb3IgdGhpcyB0cmFu
c2ZlciBleHBpcmVkIGFuZCByZS1hdHRlc3RhdGlvbiBjb3VsZCAnICsKICAgICAgICAgICAgJ25v
dCBiZSByZXF1ZXN0ZWQgcmlnaHQgbm93LiBZb3VyIGZ1bmRzIGFyZSBzYWZlIC0gdHJ5IGFnYWlu
IHNob3J0bHkuJykKICAgICAgICB9CgogICAgICAgIC8vIFJlLXBvbGwgZm9yIHRoZSByZWZyZXNo
ZWQgYXR0ZXN0YXRpb24gKGEgZmV3IGdlbnRsZSBhdHRlbXB0cykuCiAgICAgICAgc2V0Tm90ZSgn
V2FpdGluZyBmb3IgdGhlIHJlZnJlc2hlZCBhdHRlc3RhdGlvbi4uLicpCiAgICAgICAgbGV0IHJl
ZnJlc2hlZCA9IG51bGwgYXMgdHlwZW9mIGN1cnJlbnRBdHQgfCBudWxsCiAgICAgICAgZm9yIChs
ZXQgaSA9IDA7IGkgPCA2OyBpKyspIHsKICAgICAgICAgIGF3YWl0IG5ldyBQcm9taXNlKHIgPT4g
c2V0VGltZW91dChyLCA1MDAwKSkKICAgICAgICAgIGNvbnN0IGFnYWluID0gYXdhaXQgZmV0Y2hB
dHRlc3RhdGlvbihpcmlzQmFzZSgpLCBmcm9tLmRvbWFpbiwgYnJpZGdlLmJ1cm5fdHghKQogICAg
ICAgICAgaWYgKGFnYWluLnN0YXR1cyA9PT0gJ2NvbXBsZXRlJyAmJiBhZ2Fpbi5tZXNzYWdlICYm
IGFnYWluLmF0dGVzdGF0aW9uKSB7CiAgICAgICAgICAgIHJlZnJlc2hlZCA9IGFnYWluCiAgICAg
ICAgICAgIGJyZWFrCiAgICAgICAgICB9CiAgICAgICAgfQogICAgICAgIGlmICghcmVmcmVzaGVk
KSB7CiAgICAgICAgICB0aHJvdyBuZXcgRXJyb3IoCiAgICAgICAgICAgICdSZXF1ZXN0ZWQgYSBm
cmVzaCBhdHRlc3RhdGlvbiwgYnV0IGl0IGlzIG5vdCByZWFkeSB5ZXQuIFlvdXIgZnVuZHMgJyAr
CiAgICAgICAgICAgICdhcmUgc2FmZSAtIGNvbWUgYmFjayBpbiBhIGZldyBtaW51dGVzIGFuZCBw
cmVzcyBDb21wbGV0ZSBhZ2Fpbi4nKQogICAgICAgIH0KCiAgICAgICAgYXdhaXQgZmV0Y2goYCR7
QVBJfS9icmlkZ2UvJHticmlkZ2UuaWR9L2F0dGVzdGVkYCwgewogICAgICAgICAgbWV0aG9kOiAn
UE9TVCcsCiAgICAgICAgICBoZWFkZXJzOiB7ICdDb250ZW50LVR5cGUnOiAnYXBwbGljYXRpb24v
anNvbicgfSwKICAgICAgICAgIGJvZHk6IEpTT04uc3RyaW5naWZ5KHsgYXR0ZXN0YXRpb246IHJl
ZnJlc2hlZC5hdHRlc3RhdGlvbiB9KSwKICAgICAgICB9KS5jYXRjaCgoKSA9PiB7fSkKCiAgICAg
ICAgLy8gU2Vjb25kIGFuZCBmaW5hbCBtaW50IGF0dGVtcHQgd2l0aCB0aGUgZnJlc2ggYXR0ZXN0
YXRpb24uCiAgICAgICAgY29uc3QgdHgyID0gYXdhaXQgZG9NaW50KHJlZnJlc2hlZC5tZXNzYWdl
ISwgcmVmcmVzaGVkLmF0dGVzdGF0aW9uISkKICAgICAgICBhd2FpdCByZWNvcmRDb21wbGV0ZWQo
dHgyKQogICAgICAgIHNldE1pbnRUeCh0eDIpOyBzZXRTdGVwKCdkb25lJyk7IHNldE5vdGUobnVs
bCkiIiIKCk5FVyA9ICIiIiAgICAgIH0gY2F0Y2ggKG1pbnRFcnI6IGFueSkgewogICAgICAgIC8v
IF9fTkVYVU1fTUlOVF9SRVRSWV9GSVhfXyBkaXN0aW5ndWlzaCBhIHN1Ym1pc3Npb24gZmFpbHVy
ZSAodmFsaWQKICAgICAgICAvLyBhdHRlc3RhdGlvbiwgbWludCBjYWxsIGl0c2VsZiBmYWlsZWQp
IGZyb20gYSBnZW51aW5lbHkgZXhwaXJlZAogICAgICAgIC8vIGF0dGVzdGF0aW9uLiBPbmx5IHRo
ZSBsYXR0ZXIgaXMgaGVscGVkIGJ5IHJlYXR0ZXN0YXRpb24uCiAgICAgICAgY29uc3QgbSA9IG1p
bnRFcnI/Lm1lc3NhZ2UgPz8gJycKCiAgICAgICAgLy8gSWRlbXBvdGVudCBzdWNjZXNzOiB0aGUg
bWludCBhbHJlYWR5IGxhbmRlZC4KICAgICAgICBpZiAoL2FscmVhZHkgYmVlbiB1c2VkfG5vbmNl
IGFscmVhZHl8YWxyZWFkeSBtaW50ZWR8YWxyZWFkeSBiZWVuIHByb2Nlc3NlZC9pLnRlc3QobSkp
IHsKICAgICAgICAgIGF3YWl0IHJlY29yZENvbXBsZXRlZCgnYWxyZWFkeS1taW50ZWQnKQogICAg
ICAgICAgc2V0TWludFR4KCdhbHJlYWR5LW1pbnRlZCcpOyBzZXRTdGVwKCdkb25lJyk7IHNldE5v
dGUobnVsbCkKICAgICAgICAgIHJldHVybgogICAgICAgIH0KICAgICAgICAvLyBBdXRoIC8gY2hh
aW4gcHJvbXB0cyBhcmUgZm9yIHRoZSBjYWxsZXIgdG8gcmVzb2x2ZSwgbm90IHJldHJ5YWJsZSBo
ZXJlLgogICAgICAgIGlmIChtaW50RXJyIGluc3RhbmNlb2YgTmVlZHNSZWF1dGhFcnJvciB8fCBt
aW50RXJyIGluc3RhbmNlb2YgTmVlZHNDaGFpbkVycm9yKSB7CiAgICAgICAgICB0aHJvdyBtaW50
RXJyCiAgICAgICAgfQoKICAgICAgICAvLyBJcyB0aGUgYXR0ZXN0YXRpb24gQUNUVUFMTFkgZXhw
aXJlZCwgb3IgaXMgaXQgc3RpbGwgdmFsaWQgYW5kIHRoZSBtaW50CiAgICAgICAgLy8gc3VibWlz
c2lvbiBpdHNlbGYgZmFpbGVkPyBSZS1mZXRjaCBhbmQgY2hlY2suIElmIENpcmNsZSBzdGlsbCBy
ZXR1cm5zCiAgICAgICAgLy8gaXQgYXMgY29tcGxldGUsIHJlYXR0ZXN0aW5nIGlzIHBvaW50bGVz
cyAtIHRoZSByZWFsIHByb2JsZW0gaXMgdGhlCiAgICAgICAgLy8gbWludCBjYWxsIChnYXMgb24g
dGhlIGRlc3RpbmF0aW9uLCB3cm9uZyBjb250cmFjdCwgb3IgYSBDaXJjbGUtc2lkZQogICAgICAg
IC8vIHJlamVjdGlvbiksIGFuZCB3ZSBtdXN0IHN1cmZhY2UgVEhBVCBlcnJvciwgbm90IGhpZGUg
aXQgYmVoaW5kIGEKICAgICAgICAvLyByZWF0dGVzdCB0aGF0IGNhbiBuZXZlciBoZWxwLgogICAg
ICAgIHNldE5vdGUoJ0NoZWNraW5nIHdoZXRoZXIgdGhlIGF0dGVzdGF0aW9uIGlzIHN0aWxsIHZh
bGlkLi4uJykKICAgICAgICBjb25zdCByZWNoZWNrID0gYXdhaXQgZmV0Y2hBdHRlc3RhdGlvbihp
cmlzQmFzZSgpLCBmcm9tLmRvbWFpbiwgYnJpZGdlLmJ1cm5fdHghKQogICAgICAgIGNvbnN0IHN0
aWxsVmFsaWQgPQogICAgICAgICAgcmVjaGVjay5zdGF0dXMgPT09ICdjb21wbGV0ZScgJiYgISFy
ZWNoZWNrLm1lc3NhZ2UgJiYgISFyZWNoZWNrLmF0dGVzdGF0aW9uCgogICAgICAgIGlmIChzdGls
bFZhbGlkKSB7CiAgICAgICAgICAvLyBUaGUgbWVzc2FnZSBpcyBtaW50LXJlYWR5OyB0aGUgZmFp
bHVyZSBpcyBpbiBzdWJtaXNzaW9uLiBTdXJmYWNlCiAgICAgICAgICAvLyBDaXJjbGUncyByZWFs
IGVycm9yIHNvIGl0IGlzIGRpYWdub3NhYmxlIGluc3RlYWQgb2YgbWlzcmVwb3J0ZWQuCiAgICAg
ICAgICBjb25zb2xlLmVycm9yKCdbYnJpZGdlXSBtaW50IGZhaWxlZCB3aXRoIGEgVkFMSUQgYXR0
ZXN0YXRpb246JywgbWludEVycikKICAgICAgICAgIHRocm93IG5ldyBFcnJvcigKICAgICAgICAg
ICAgJ1RoZSB0cmFuc2ZlciBpcyBhdHRlc3RlZCBhbmQgcmVhZHksIGJ1dCB0aGUgbWludCBjb3Vs
ZCBub3QgYmUgJyArCiAgICAgICAgICAgICdzdWJtaXR0ZWQgb24gJyArIHRvLm5hbWUgKyAnLiBU
aGlzIGlzIHVzdWFsbHkgZ2FzIG9uIHRoZSAnICsKICAgICAgICAgICAgJ2Rlc3RpbmF0aW9uIG9y
IGEgdGVtcG9yYXJ5IENpcmNsZSBpc3N1ZSAtIHlvdXIgZnVuZHMgYXJlIHNhZmUuICcgKwogICAg
ICAgICAgICAnRGV0YWlsczogJyArIChtIHx8ICd1bmtub3duIGVycm9yJykpCiAgICAgICAgfQoK
ICAgICAgICAvLyBHZW51aW5lbHkgbm90IGNvbXBsZXRlIGFueW1vcmUgLT4gdGhlIGF0dGVzdGF0
aW9uIGV4cGlyZWQuIE5PVyBhCiAgICAgICAgLy8gcmVhdHRlc3QgY3ljbGUgaXMgdGhlIGNvcnJl
Y3QgcmVtZWR5LgogICAgICAgIGNvbnN0IG5vbmNlID0gY3VycmVudEF0dC5ub25jZSA/PyBjdXJy
ZW50QXR0LmV2ZW50Tm9uY2UKICAgICAgICBpZiAoIW5vbmNlKSB0aHJvdyBtaW50RXJyCgogICAg
ICAgIHNldFN0ZXAoJ3JlYXR0ZXN0aW5nJykKICAgICAgICBzZXROb3RlKCdUaGUgYXR0ZXN0YXRp
b24gZXhwaXJlZCAtIHJlcXVlc3RpbmcgYSBmcmVzaCBvbmUgZnJvbSBDaXJjbGUuLi4nKQogICAg
ICAgIGNvbnN0IG9rID0gYXdhaXQgcmVhdHRlc3QoaXJpc0Jhc2UoKSwgbm9uY2UpCiAgICAgICAg
aWYgKCFvaykgewogICAgICAgICAgdGhyb3cgbmV3IEVycm9yKAogICAgICAgICAgICAnVGhlIGF0
dGVzdGF0aW9uIGZvciB0aGlzIHRyYW5zZmVyIGV4cGlyZWQgYW5kIHJlLWF0dGVzdGF0aW9uIGNv
dWxkICcgKwogICAgICAgICAgICAnbm90IGJlIHJlcXVlc3RlZCByaWdodCBub3cuIFlvdXIgZnVu
ZHMgYXJlIHNhZmUgLSB0cnkgYWdhaW4gc2hvcnRseS4nKQogICAgICAgIH0KCiAgICAgICAgLy8g
UmUtcG9sbCBmb3IgdGhlIHJlZnJlc2hlZCBhdHRlc3RhdGlvbiAoYSBmZXcgZ2VudGxlIGF0dGVt
cHRzKS4KICAgICAgICBzZXROb3RlKCdXYWl0aW5nIGZvciB0aGUgcmVmcmVzaGVkIGF0dGVzdGF0
aW9uLi4uJykKICAgICAgICBsZXQgcmVmcmVzaGVkID0gbnVsbCBhcyB0eXBlb2YgY3VycmVudEF0
dCB8IG51bGwKICAgICAgICBmb3IgKGxldCBpID0gMDsgaSA8IDY7IGkrKykgewogICAgICAgICAg
YXdhaXQgbmV3IFByb21pc2UociA9PiBzZXRUaW1lb3V0KHIsIDUwMDApKQogICAgICAgICAgY29u
c3QgYWdhaW4gPSBhd2FpdCBmZXRjaEF0dGVzdGF0aW9uKGlyaXNCYXNlKCksIGZyb20uZG9tYWlu
LCBicmlkZ2UuYnVybl90eCEpCiAgICAgICAgICBpZiAoYWdhaW4uc3RhdHVzID09PSAnY29tcGxl
dGUnICYmIGFnYWluLm1lc3NhZ2UgJiYgYWdhaW4uYXR0ZXN0YXRpb24pIHsKICAgICAgICAgICAg
cmVmcmVzaGVkID0gYWdhaW4KICAgICAgICAgICAgYnJlYWsKICAgICAgICAgIH0KICAgICAgICB9
CiAgICAgICAgaWYgKCFyZWZyZXNoZWQpIHsKICAgICAgICAgIHRocm93IG5ldyBFcnJvcigKICAg
ICAgICAgICAgJ1JlcXVlc3RlZCBhIGZyZXNoIGF0dGVzdGF0aW9uLCBidXQgaXQgaXMgbm90IHJl
YWR5IHlldC4gWW91ciBmdW5kcyAnICsKICAgICAgICAgICAgJ2FyZSBzYWZlIC0gY29tZSBiYWNr
IGluIGEgZmV3IG1pbnV0ZXMgYW5kIHByZXNzIENvbXBsZXRlIGFnYWluLicpCiAgICAgICAgfQoK
ICAgICAgICBhd2FpdCBmZXRjaChgJHtBUEl9L2JyaWRnZS8ke2JyaWRnZS5pZH0vYXR0ZXN0ZWRg
LCB7CiAgICAgICAgICBtZXRob2Q6ICdQT1NUJywKICAgICAgICAgIGhlYWRlcnM6IHsgJ0NvbnRl
bnQtVHlwZSc6ICdhcHBsaWNhdGlvbi9qc29uJyB9LAogICAgICAgICAgYm9keTogSlNPTi5zdHJp
bmdpZnkoeyBhdHRlc3RhdGlvbjogcmVmcmVzaGVkLmF0dGVzdGF0aW9uIH0pLAogICAgICAgIH0p
LmNhdGNoKCgpID0+IHt9KQoKICAgICAgICAvLyBTZWNvbmQgYW5kIGZpbmFsIG1pbnQgYXR0ZW1w
dCB3aXRoIHRoZSBmcmVzaCBhdHRlc3RhdGlvbi4KICAgICAgICBjb25zdCB0eDIgPSBhd2FpdCBk
b01pbnQocmVmcmVzaGVkLm1lc3NhZ2UhLCByZWZyZXNoZWQuYXR0ZXN0YXRpb24hKQogICAgICAg
IGF3YWl0IHJlY29yZENvbXBsZXRlZCh0eDIpCiAgICAgICAgc2V0TWludFR4KHR4Mik7IHNldFN0
ZXAoJ2RvbmUnKTsgc2V0Tm90ZShudWxsKSIiIgoKbiA9IHNyYy5jb3VudChPTEQpCmlmIG4gIT0g
MToKICAgIHByaW50KGYiRVJST1I6IHJldHJ5IGJsb2NrIG1hdGNoZWQge259IHRpbWVzIChleHBl
Y3RlZCAxKS4gQWJvcnRpbmcuIikKICAgIHN5cy5leGl0KDIpCnNyYyA9IHNyYy5yZXBsYWNlKE9M
RCwgTkVXKQppby5vcGVuKFBBVEgsICJ3IiwgZW5jb2Rpbmc9InV0Zi04Iikud3JpdGUoc3JjKQpw
cmludChmIiAge1BBVEh9OiBmaXhlZC4iKQo=
B64
ACTUAL="$( (sha256sum "$TPATCH" 2>/dev/null || shasum -a 256 "$TPATCH") | awk '{print $1}')"
[ "$ACTUAL" = "$PATCH_SHA" ] || die "Patcher checksum mismatch (got $ACTUAL). Nothing changed."
log "Patcher verified."

mkdir -p "$BACKUP_DIR"
[ -f "$TARGET" ] && ! grep -qF "$MARKER" "$TARGET" && cp "$TARGET" "$BACKUP_DIR/useCompleteBridge.ts" || true

python3 "$TPATCH" || {
  [ -f "$BACKUP_DIR/useCompleteBridge.ts" ] && cp "$BACKUP_DIR/useCompleteBridge.ts" "$TARGET"
  die "Patch failed; file restored."
}

if [ "$FLAG" = "--no-deploy" ]; then
  log "--no-deploy: applied only. Rerun without the flag to build + push."
  exit 0
fi
log ""
log "=== Deploy gate: typecheck + build, then commit + push ==="
( cd "$WEB" && rm -rf .next && npx tsc --noEmit ) || die "tsc failed - not committing."
log "tsc clean."
( cd "$WEB" && npm run build ) || die "next build failed - not committing."
log "build clean."

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "Not a git work tree; commit manually."
REMOTE="$(git remote | head -1 || true)"; [ -n "$REMOTE" ] || die "No git remote; commit/push manually."
BRANCH="$(git rev-parse --abbrev-ref HEAD)"
git add -A
if git diff --cached --quiet; then log "Nothing to commit."; exit 0; fi
log "Committing on '$BRANCH' -> '$REMOTE'..."
git commit -m "$COMMIT_MSG"
git push "$REMOTE" "$BRANCH"
log ""
log "Pushed. Now retry the stuck mint ONCE - the error shown (and the browser"
log "console line '[bridge] mint failed with a VALID attestation:') will reveal"
log "Circle's real reason on Arc. Send me that and I'll build the final fix."
