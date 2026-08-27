#!/usr/bin/env bash
# ============================================================================
# Nexum - smoother wallet login/logout on Circle signing-session expiry
#
# THE PROBLEM
# The Circle userToken lasts ~60 min (expired at 55, see useCircleTx); the app
# session lasts 30 days. So the dashboard can look fully signed in while the
# wallet can no longer sign - and today that only surfaces as a "sign in again"
# error in the MIDDLE of a transaction, because components read the signing
# session imperatively when they act, not reactively.
#
# THE FIX (built entirely on Circle's OWN expiry timestamp - no invented timer)
#   NEW  nexum-web/hooks/useSigningSession.ts
#        watches SigningSession.expiresAt; on expiry clears the dead signing
#        session and hard-refreshes ONCE so every wallet-gated surface goes
#        inactive. App (30-day) session survives, so the user stays signed into
#        the dashboard; the next action cleanly prompts re-auth.
#   PATCH hooks/useCircleTx.ts       export SIGNING_KEY (same key, no drift)
#   PATCH components/auth/AuthGuard.tsx   mount useSigningSession() by useIdleSignOut()
#   PATCH components/auth/AccountMenu.tsx manual sign-out now hard-refreshes to
#         /signin so wallet-gated data clears immediately
#
# Does NOT touch: the signing flow, token TTL, or useIdleSignOut (separate axis:
# 30-min real inactivity -> full sign-out). This only reacts to Circle's
# existing live-session config.
#
# Delivery contract (v2) + full deploy:
#   * payloads base64 + sha256 verified; exact-anchor patch; aborts on drift
#   * idempotent (marker __NEXUM_SIGNING_WATCHER__); clean-only backups
#   * gate: rm -rf .next && npx tsc --noEmit && npm run build -> commit + push
#   * --revert restores the 3 files + removes the hook
#   * --no-deploy applies only
#
# Run from REPO ROOT (folder containing nexum-web/).
#   bash nexum-wallet-session-ux.sh
#   bash nexum-wallet-session-ux.sh --no-deploy
#   bash nexum-wallet-session-ux.sh --revert
# ============================================================================
set -euo pipefail

WEB="nexum-web"
HOOK="$WEB/hooks/useSigningSession.ts"
UCT="$WEB/hooks/useCircleTx.ts"
AG="$WEB/components/auth/AuthGuard.tsx"
AM="$WEB/components/auth/AccountMenu.tsx"
MARKER="__NEXUM_SIGNING_WATCHER__"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR=".nexum-walletux-backup/${STAMP}"
HOOK_SHA="2176d80e808c1bfe12136ee2adccbe8af777df2e222894869421c813be492030"; PATCH_SHA="8031a351d0607dba7626e01e1215c6afc7602c09d14b58d9e262593418d46fe3"
COMMIT_MSG="feat(web): clean wallet-session expiry + sign-out refresh (Circle signing session)"

FLAG="${1:-}"
log(){ printf '  %s\n' "$*"; }
die(){ printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[ -d "$WEB" ] || die "Cannot find $WEB . Run from the repo root."

if [ "$FLAG" = "--revert" ]; then
  LATEST=""
  for d in $(ls -1dt .nexum-walletux-backup/*/ 2>/dev/null); do
    if [ -f "${d}useCircleTx.ts" ] || [ -f "${d}AuthGuard.tsx" ] || [ -f "${d}AccountMenu.tsx" ]; then LATEST="$d"; break; fi
  done
  if [ -n "$LATEST" ]; then
    [ -f "${LATEST}useCircleTx.ts" ] && cp "${LATEST}useCircleTx.ts" "$UCT" && log "Restored $UCT"
    [ -f "${LATEST}AuthGuard.tsx" ]  && cp "${LATEST}AuthGuard.tsx"  "$AG"  && log "Restored $AG"
    [ -f "${LATEST}AccountMenu.tsx" ] && cp "${LATEST}AccountMenu.tsx" "$AM" && log "Restored $AM"
  else
    log "No backup found; leaving patched files as-is."
  fi
  rm -f "$HOOK" && log "Removed $HOOK"
  log "Reverted wallet-session UX."
  exit 0
fi

THOOK="$(mktemp)"; TPATCH="$(mktemp /tmp/walletux.XXXXXX.py)"
trap 'rm -f "$THOOK" "$TPATCH"' EXIT

base64 -d > "$THOOK" <<'B64HOOK'
J3VzZSBjbGllbnQnCi8vID09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
PT09PT09PT09PT09PT09PT09PQovLyB1c2VTaWduaW5nU2Vzc2lvbiDigJQgY2xlYW4gaGFuZGxp
bmcgb2YgQ2lyY2xlIHNpZ25pbmctc2Vzc2lvbiBleHBpcnkuCi8vCi8vIFRIRSBQUk9CTEVNIFRI
SVMgU09MVkVTCi8vIFRoZSBDaXJjbGUgdXNlclRva2VuIGxhc3RzIH42MCBtaW4gKHdlIGV4cGly
ZSBvdXJzIGF0IDU1LCBzZWUgdXNlQ2lyY2xlVHgpLAovLyBidXQgb3VyIGFwcCBzZXNzaW9uIGxh
c3RzIDMwIGRheXMuIFNvIHRoZSBkYXNoYm9hcmQgY2FuIGxvb2sgZnVsbHkgc2lnbmVkIGluCi8v
IHdoaWxlIHRoZSB3YWxsZXQgY2FuIG5vIGxvbmdlciBzaWduLiBUb2RheSB0aGF0IG1pc21hdGNo
IG9ubHkgc3VyZmFjZXMgd2hlbgovLyB0aGUgdXNlciB0cmllcyBhIHRyYW5zYWN0aW9uIGFuZCBn
ZXRzIGEgInNpZ24gaW4gYWdhaW4iIGVycm9yIG1pZC1hY3Rpb24sCi8vIGJlY2F1c2UgY29tcG9u
ZW50cyByZWFkIGdldFNpZ25pbmdTZXNzaW9uKCkgaW1wZXJhdGl2ZWx5IHdoZW4gdGhleSBhY3Qs
IG5vdAovLyByZWFjdGl2ZWx5IOKAlCBub3RoaW5nIHJlLXJlbmRlcnMgd2hlbiB0aGUgdG9rZW4g
cXVpZXRseSBleHBpcmVzLgovLwovLyBXSEFUIFRISVMgRE9FUwovLyBXYXRjaCBDaXJjbGUncyBP
V04gZXhwaXJ5IHRpbWVzdGFtcCAoU2lnbmluZ1Nlc3Npb24uZXhwaXJlc0F0IOKAlCB0aGUgcmVh
bAovLyBsaXZlLXNlc3Npb24gY29uZmlnLCBub3QgYSB0aW1lciB3ZSBpbnZlbnRlZCkuIFdoZW4g
aXQgcGFzc2VzOgovLyAgIDEuIGNsZWFyIHRoZSAobm93IGRlYWQpIHNpZ25pbmcgc2Vzc2lvbiwg
YW5kCi8vICAgMi4gaGFyZC1yZWZyZXNoIHRoZSBhcHAgb25jZSwgc28gZXZlcnkgd2FsbGV0LWdh
dGVkIGhvb2sgcmUtcmVhZHMgYSBjbGVhbgovLyAgICAgIHN0YXRlIGFuZCB0aGUgd2FsbGV0LWxp
dmUgVUkgc3dpdGNoZXMgb2ZmLgovLyBUaGUgYXBwIHNlc3Npb24gc3RheXMgdmFsaWQsIHNvIHRo
ZSB1c2VyIHJlbWFpbnMgc2lnbmVkIGludG8gdGhlIGRhc2hib2FyZCDigJQKLy8gdGhlIHdhbGxl
dCBzaW1wbHkgZ29lcyBpbmFjdGl2ZSwgYW5kIHRoZSBuZXh0IGFjdGlvbiBjbGVhbmx5IHByb21w
dHMgcmUtYXV0aAovLyBpbnN0ZWFkIG9mIGVycm9yaW5nIGluIHRoZSBtaWRkbGUgb2YgYSB0cmFu
c2Zlci4KLy8KLy8gV0hBVCBUSElTIERPRVMgTk9UIFRPVUNICi8vIFRoZSBzaWduaW5nIGZsb3cg
aXRzZWxmLCB0b2tlbiBUVEwsIG9yIHVzZUlkbGVTaWduT3V0IChhIHNlcGFyYXRlIGF4aXM6Ci8v
IDMwLW1pbiByZWFsIGluYWN0aXZpdHkg4oaSIGZ1bGwgc2lnbi1vdXQpLiBUaGlzIG9ubHkgcmVh
Y3RzIHRvIENpcmNsZSdzCi8vIGV4aXN0aW5nIGV4cGlyeTsgaXQgbmV2ZXIgc2hvcnRlbnMgb3Ig
ZXh0ZW5kcyBpdC4KLy8KLy8gQ2hlY2tlZCBvbiBtb3VudCwgb24gdGFiIGZvY3VzL3Zpc2liaWxp
dHksIGFuZCB2aWEgYSB0aW1lciBhcm1lZCBmb3IgdGhlCi8vIGV4YWN0IG1vbWVudCB0aGUgdG9r
ZW4gZXhwaXJlcy4KLy8gPT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
PT09PT09PT09PT09PT09PT09CmltcG9ydCB7IHVzZUVmZmVjdCwgdXNlUmVmIH0gZnJvbSAncmVh
Y3QnCmltcG9ydCB7IGdldFNpZ25pbmdTZXNzaW9uLCBjbGVhclNpZ25pbmdTZXNzaW9uLCBTSUdO
SU5HX0tFWSB9IGZyb20gJ0AvaG9va3MvdXNlQ2lyY2xlVHgnCgovLyBBIHRpbnkgZ3JhY2Ugc28g
dGhlIHRpbWVyIGZpcmVzIGp1c3QgQUZURVIgZXhwaXJ5LCBuZXZlciBhIGhhaXIgYmVmb3JlLgpj
b25zdCBFWFBJUllfR1JBQ0VfTVMgPSA1MDAKCmV4cG9ydCBmdW5jdGlvbiB1c2VTaWduaW5nU2Vz
c2lvbigpIHsKICBjb25zdCB0aW1lciAgID0gdXNlUmVmPFJldHVyblR5cGU8dHlwZW9mIHNldFRp
bWVvdXQ+IHwgbnVsbD4obnVsbCkKICBjb25zdCBoYW5kbGVkID0gdXNlUmVmKGZhbHNlKQoKICB1
c2VFZmZlY3QoKCkgPT4gewogICAgLy8gUmVhZHMgc2Vzc2lvblN0b3JhZ2U7IGd1YXJkIHRoZSBy
YXcgdmFsdWUgc28gYSBjb3JydXB0IGVudHJ5IGNhbid0IHRocm93LgogICAgZnVuY3Rpb24gcmF3
RXhwaXJ5KCk6IG51bWJlciB8IG51bGwgewogICAgICBjb25zdCBzID0gZ2V0U2lnbmluZ1Nlc3Np
b24oKSAgIC8vIHJldHVybnMgbnVsbCBpZiBtaXNzaW5nIE9SIGFscmVhZHkgZXhwaXJlZAogICAg
ICByZXR1cm4gcyA/IHMuZXhwaXJlc0F0IDogbnVsbAogICAgfQoKICAgIC8vIFRoZSB3YWxsZXQg
c2Vzc2lvbiBoYXMgZW5kZWQgKG9yIHdhcyBuZXZlciBwcmVzZW50IGluIHRoaXMgdGFiKS4gQ2xl
YXIgaXQKICAgIC8vIGFuZCByZWZyZXNoIE9OQ0Ugc28gd2FsbGV0LWdhdGVkIFVJIGdvZXMgaW5h
Y3RpdmUuIFdlIG9ubHkgcmVmcmVzaCBpZiBhCiAgICAvLyBzZXNzaW9uIHRva2VuIHN0aWxsIHBo
eXNpY2FsbHkgZXhpc3RzIGluIHN0b3JhZ2Ug4oCUIG90aGVyd2lzZSBhIGZyZXNoIHRhYgogICAg
Ly8gdGhhdCBzaW1wbHkgbmV2ZXIgaGFkIGEgc2lnbmluZyBzZXNzaW9uIHdvdWxkIHJlbG9hZCBw
b2ludGxlc3NseS4KICAgIGZ1bmN0aW9uIGhhbmRsZUV4cGlyeSgpIHsKICAgICAgaWYgKGhhbmRs
ZWQuY3VycmVudCkgcmV0dXJuCiAgICAgIGhhbmRsZWQuY3VycmVudCA9IHRydWUKICAgICAgaWYg
KHRpbWVyLmN1cnJlbnQpIHsgY2xlYXJUaW1lb3V0KHRpbWVyLmN1cnJlbnQpOyB0aW1lci5jdXJy
ZW50ID0gbnVsbCB9CgogICAgICAvLyBXYXMgdGhlcmUgYW55dGhpbmcgdG8gZXhwaXJlPyBzZXNz
aW9uU3RvcmFnZSBzdGlsbCBob2xkcyB0aGUgKG5vdwogICAgICAvLyBzdGFsZSkgYmxvYiBldmVu
IHRob3VnaCBnZXRTaWduaW5nU2Vzc2lvbigpIHJldHVybnMgbnVsbCBvbmNlIHBhc3QKICAgICAg
Ly8gZXhwaXJlc0F0LiBJZiBub3RoaW5nIGlzIHRoZXJlIGF0IGFsbCwgZG8gbm90aGluZyDigJQg
dGhpcyB0YWIgd2FzCiAgICAgIC8vIG5ldmVyIHNpZ25pbmctZW5hYmxlZCwgc28gdGhlcmUncyBu
byBsaXZlIFVJIHRvIHJlc2V0LgogICAgICBsZXQgaGFkU2Vzc2lvbiA9IGZhbHNlCiAgICAgIHRy
eSB7IGhhZFNlc3Npb24gPSAhIXNlc3Npb25TdG9yYWdlLmdldEl0ZW0oU0lHTklOR19LRVkpIH0g
Y2F0Y2gge30KICAgICAgY2xlYXJTaWduaW5nU2Vzc2lvbigpCiAgICAgIGlmIChoYWRTZXNzaW9u
KSB7CiAgICAgICAgLy8gRnVsbCByZWxvYWQ6IGNvbXBvbmVudHMgcmVhZCB0aGUgc2lnbmluZyBz
ZXNzaW9uIGltcGVyYXRpdmVseSwgc28gYQogICAgICAgIC8vIGhhcmQgcmVmcmVzaCBpcyB0aGUg
cmVsaWFibGUgd2F5IHRvIHN3aXRjaCBldmVyeSB3YWxsZXQtbGl2ZSBzdXJmYWNlCiAgICAgICAg
Ly8gb2ZmIGF0IG9uY2UuIFRoZSBhcHAgKDMwLWRheSkgc2Vzc2lvbiBzdXJ2aXZlcyB0aGUgcmVs
b2FkLgogICAgICAgIHdpbmRvdy5sb2NhdGlvbi5yZWxvYWQoKQogICAgICB9CiAgICB9CgogICAg
Ly8gTG9vayBhdCB0aGUgY3VycmVudCBleHBpcnkgYW5kIGRlY2lkZTogZXhwaXJlZCBub3cg4oaS
IGhhbmRsZTsgc3RpbGwgbGl2ZSDihpIKICAgIC8vIGFybSBhIHRpbWVyIGZvciB0aGUgZXhhY3Qg
cmVtYWluaW5nIHRpbWUuCiAgICBmdW5jdGlvbiBldmFsdWF0ZSgpIHsKICAgICAgaWYgKGhhbmRs
ZWQuY3VycmVudCkgcmV0dXJuCiAgICAgIGNvbnN0IGV4cCA9IHJhd0V4cGlyeSgpCgogICAgICBp
ZiAoZXhwID09PSBudWxsKSB7CiAgICAgICAgLy8gZ2V0U2lnbmluZ1Nlc3Npb24oKSByZXR1cm5z
IG51bGwgZm9yIEJPVEggIm5vIHNlc3Npb24iIGFuZCAiZXhwaXJlZCIuCiAgICAgICAgLy8gRGlz
dGluZ3Vpc2g6IGlmIGEgc3RhbGUgYmxvYiBpcyBzdGlsbCBpbiBzdG9yYWdlLCBpdCBqdXN0IGV4
cGlyZWQg4oaSCiAgICAgICAgLy8gaGFuZGxlIGl0LiBJZiBzdG9yYWdlIGlzIGVtcHR5LCB0aGVy
ZSdzIG5vdGhpbmcgdG8gZG8uCiAgICAgICAgbGV0IHN0YWxlID0gZmFsc2UKICAgICAgICB0cnkg
eyBzdGFsZSA9ICEhc2Vzc2lvblN0b3JhZ2UuZ2V0SXRlbShTSUdOSU5HX0tFWSkgfSBjYXRjaCB7
fQogICAgICAgIGlmIChzdGFsZSkgaGFuZGxlRXhwaXJ5KCkKICAgICAgICByZXR1cm4KICAgICAg
fQoKICAgICAgY29uc3QgcmVtYWluaW5nID0gZXhwIC0gRGF0ZS5ub3coKQogICAgICBpZiAocmVt
YWluaW5nIDw9IDApIHsgaGFuZGxlRXhwaXJ5KCk7IHJldHVybiB9CgogICAgICBpZiAodGltZXIu
Y3VycmVudCkgY2xlYXJUaW1lb3V0KHRpbWVyLmN1cnJlbnQpCiAgICAgIHRpbWVyLmN1cnJlbnQg
PSBzZXRUaW1lb3V0KGhhbmRsZUV4cGlyeSwgcmVtYWluaW5nICsgRVhQSVJZX0dSQUNFX01TKQog
ICAgfQoKICAgIC8vIFJlLWV2YWx1YXRlIHdoZW4gdGhlIHVzZXIgcmV0dXJucyB0byB0aGUgdGFi
OiBhIGJhY2tncm91bmQgdGFiJ3MgdGltZXJzCiAgICAvLyBhcmUgdGhyb3R0bGVkLCBzbyB0aGUg
dG9rZW4gbWF5IGhhdmUgZXhwaXJlZCB3aGlsZSBpdCBzbGVwdC4KICAgIGNvbnN0IG9uRm9jdXMg
PSAoKSA9PiBldmFsdWF0ZSgpCgogICAgd2luZG93LmFkZEV2ZW50TGlzdGVuZXIoJ2ZvY3VzJywg
b25Gb2N1cykKICAgIGRvY3VtZW50LmFkZEV2ZW50TGlzdGVuZXIoJ3Zpc2liaWxpdHljaGFuZ2Un
LCBvbkZvY3VzKQoKICAgIGV2YWx1YXRlKCkKCiAgICByZXR1cm4gKCkgPT4gewogICAgICBpZiAo
dGltZXIuY3VycmVudCkgY2xlYXJUaW1lb3V0KHRpbWVyLmN1cnJlbnQpCiAgICAgIHdpbmRvdy5y
ZW1vdmVFdmVudExpc3RlbmVyKCdmb2N1cycsIG9uRm9jdXMpCiAgICAgIGRvY3VtZW50LnJlbW92
ZUV2ZW50TGlzdGVuZXIoJ3Zpc2liaWxpdHljaGFuZ2UnLCBvbkZvY3VzKQogICAgfQogIH0sIFtd
KQp9Cg==
B64HOOK
base64 -d > "$TPATCH" <<'B64PATCH'
IyEvdXNyL2Jpbi9lbnYgcHl0aG9uMwoiIiIKU21vb3RoZXIgd2FsbGV0IGxvZ2luL2xvZ291dCAt
IHdpcmUgdGhlIHNpZ25pbmctc2Vzc2lvbiB3YXRjaGVyICsgcmVmcmVzaC4KCkVkaXRzOgogIGhv
b2tzL3VzZUNpcmNsZVR4LnRzCiAgICAqIGV4cG9ydCB0aGUgc2Vzc2lvblN0b3JhZ2Uga2V5IGFz
IFNJR05JTkdfS0VZICh3YXMgcHJpdmF0ZSBgY29uc3QgS0VZYCksCiAgICAgIHNvIHRoZSB3YXRj
aGVyIHJlZmVyZW5jZXMgdGhlIGV4YWN0IHNhbWUga2V5IHdpdGggbm8gZHJpZnQKICBjb21wb25l
bnRzL2F1dGgvQXV0aEd1YXJkLnRzeAogICAgKiBtb3VudCB1c2VTaWduaW5nU2Vzc2lvbigpIGFs
b25nc2lkZSB1c2VJZGxlU2lnbk91dCgpCiAgY29tcG9uZW50cy9hdXRoL0FjY291bnRNZW51LnRz
eAogICAgKiBhZnRlciBhIG1hbnVhbCBzaWduLW91dCwgaGFyZC1yZWZyZXNoIHNvIHdhbGxldC1n
YXRlZCBkYXRhIGNsZWFycyBhdCBvbmNlCgpJZGVtcG90ZW50IHZpYSBfX05FWFVNX1NJR05JTkdf
V0FUQ0hFUl9fLiBFeGFjdC1hbmNob3I7IGFib3J0cyBjbGVhbiBvbiBkcmlmdC4KIiIiCmltcG9y
dCBzeXMsIGlvCgpkZWYgcGF0Y2gocGF0aCwgZWRpdHMsIG1hcmtlcik6CiAgICBzcmMgPSBpby5v
cGVuKHBhdGgsIGVuY29kaW5nPSJ1dGYtOCIpLnJlYWQoKQogICAgaWYgbWFya2VyIGluIHNyYzoK
ICAgICAgICBwcmludChmIiAge3BhdGh9OiBhbHJlYWR5IHdpcmVkIC0gc2tpcHBpbmcuIikKICAg
ICAgICByZXR1cm4KICAgIGZvciBkZXNjLCBvbGQsIG5ldyBpbiBlZGl0czoKICAgICAgICBuID0g
c3JjLmNvdW50KG9sZCkKICAgICAgICBpZiBuICE9IDE6CiAgICAgICAgICAgIHByaW50KGYiRVJS
T1IgW3twYXRofV06IGFuY2hvciAne2Rlc2N9JyBtYXRjaGVkIHtufSB0aW1lcyAoZXhwZWN0ZWQg
MSkuIEFib3J0aW5nLiIpCiAgICAgICAgICAgIHN5cy5leGl0KDIpCiAgICAgICAgc3JjID0gc3Jj
LnJlcGxhY2Uob2xkLCBuZXcpCiAgICBpby5vcGVuKHBhdGgsICJ3IiwgZW5jb2Rpbmc9InV0Zi04
Iikud3JpdGUoc3JjKQogICAgcHJpbnQoZiIgIHtwYXRofTogd2lyZWQuIikKCk1BUktFUiA9ICJf
X05FWFVNX1NJR05JTkdfV0FUQ0hFUl9fIgoKIyAxLiBFeHBvcnQgU0lHTklOR19LRVkgZnJvbSB1
c2VDaXJjbGVUeC50cy4gS2VlcCBgS0VZYCB3b3JraW5nIGludGVybmFsbHkgYnkKIyAgICBhbGlh
c2luZyBpdCB0byB0aGUgbmV3IGV4cG9ydGVkIGNvbnN0YW50IChtaW5pbWFsLCBubyBvdGhlciBs
aW5lIGNoYW5nZXMpLgpwYXRjaCgibmV4dW0td2ViL2hvb2tzL3VzZUNpcmNsZVR4LnRzIiwgWwog
ICAgKCJrZXkgZXhwb3J0IiwKICAgICAiY29uc3QgS0VZID0gJ2NpcmNsZV9zaWduaW5nJyIsCiAg
ICAgIi8vIF9fTkVYVU1fU0lHTklOR19XQVRDSEVSX18gZXhwb3J0ZWQgc28gdGhlIGV4cGlyeSB3
YXRjaGVyIHVzZXMgdGhlIHNhbWUga2V5XG4iCiAgICAgImV4cG9ydCBjb25zdCBTSUdOSU5HX0tF
WSA9ICdjaXJjbGVfc2lnbmluZydcbiIKICAgICAiY29uc3QgS0VZID0gU0lHTklOR19LRVkiKSwK
XSwgTUFSS0VSKQoKIyAyLiBNb3VudCB0aGUgd2F0Y2hlciBpbiBBdXRoR3VhcmQuCnBhdGNoKCJu
ZXh1bS13ZWIvY29tcG9uZW50cy9hdXRoL0F1dGhHdWFyZC50c3giLCBbCiAgICAoImltcG9ydCIs
CiAgICAgImltcG9ydCB7IHVzZUlkbGVTaWduT3V0IH0gZnJvbSAnQC9ob29rcy91c2VJZGxlU2ln
bk91dCciLAogICAgICJpbXBvcnQgeyB1c2VJZGxlU2lnbk91dCB9IGZyb20gJ0AvaG9va3MvdXNl
SWRsZVNpZ25PdXQnXG4iCiAgICAgIi8vIF9fTkVYVU1fU0lHTklOR19XQVRDSEVSX18gcmVhY3Qg
dG8gQ2lyY2xlIHNpZ25pbmctc2Vzc2lvbiBleHBpcnlcbiIKICAgICAiaW1wb3J0IHsgdXNlU2ln
bmluZ1Nlc3Npb24gfSBmcm9tICdAL2hvb2tzL3VzZVNpZ25pbmdTZXNzaW9uJyIpLAogICAgKCJt
b3VudCIsCiAgICAgIiAgdXNlSWRsZVNpZ25PdXQoKSIsCiAgICAgIiAgdXNlSWRsZVNpZ25PdXQo
KVxuICB1c2VTaWduaW5nU2Vzc2lvbigpIiksCl0sIE1BUktFUikKCiMgMy4gSGFyZC1yZWZyZXNo
IGFmdGVyIGEgbWFudWFsIHNpZ24tb3V0IHNvIHdhbGxldC1nYXRlZCBVSSBjbGVhcnMgaW1tZWRp
YXRlbHkuCnBhdGNoKCJuZXh1bS13ZWIvY29tcG9uZW50cy9hdXRoL0FjY291bnRNZW51LnRzeCIs
IFsKICAgICgic2lnbm91dCByZWZyZXNoIiwKICAgICAiPGJ1dHRvbiBvbkNsaWNrPXsoKSA9PiB7
IHNldE9wZW4oZmFsc2UpOyBjbGVhclNpZ25pbmdTZXNzaW9uKCk7IHZvaWQgc2lnbk91dCgpIH19
IHJvbGU9XCJtZW51aXRlbVwiIiwKICAgICAiPGJ1dHRvbiBvbkNsaWNrPXsoKSA9PiB7XG4iCiAg
ICAgIiAgICAgICAgICAgICAgLy8gX19ORVhVTV9TSUdOSU5HX1dBVENIRVJfXyBjbGVhciBib3Ro
IHNlc3Npb25zIHRoZW4gaGFyZC1yZWZyZXNoLFxuIgogICAgICIgICAgICAgICAgICAgIC8vIHNv
IGV2ZXJ5IHdhbGxldC1nYXRlZCBzdXJmYWNlIGdvZXMgYmFjayB0byBpdHMgc2lnbmVkLW91dCBz
dGF0ZVxuIgogICAgICIgICAgICAgICAgICAgIC8vIGF0IG9uY2UgcmF0aGVyIHRoYW4gbGluZ2Vy
aW5nIHVudGlsIHRoZSBuZXh0IG5hdmlnYXRpb24uXG4iCiAgICAgIiAgICAgICAgICAgICAgc2V0
T3BlbihmYWxzZSlcbiIKICAgICAiICAgICAgICAgICAgICBjbGVhclNpZ25pbmdTZXNzaW9uKClc
biIKICAgICAiICAgICAgICAgICAgICB2b2lkIHNpZ25PdXQoKS5maW5hbGx5KCgpID0+IHsgd2lu
ZG93LmxvY2F0aW9uLmhyZWYgPSAnL3NpZ25pbicgfSlcbiIKICAgICAiICAgICAgICAgICAgfX0g
cm9sZT1cIm1lbnVpdGVtXCIiKSwKXSwgTUFSS0VSKQoKcHJpbnQoIlNpZ25pbmctc2Vzc2lvbiB3
YXRjaGVyIHdpcmluZyBjb21wbGV0ZS4iKQo=
B64PATCH

verify(){ local got; got="$( (sha256sum "$1" 2>/dev/null || shasum -a 256 "$1") | awk '{print $1}')"; [ "$got" = "$2" ] || die "Checksum mismatch for $1 (got $got). Nothing written."; }
verify "$THOOK" "$HOOK_SHA"; verify "$TPATCH" "$PATCH_SHA"
log "Payloads verified."

mkdir -p "$BACKUP_DIR"
for f in "$UCT:useCircleTx.ts" "$AG:AuthGuard.tsx" "$AM:AccountMenu.tsx"; do
  src="${f%%:*}"; name="${f##*:}"
  [ -f "$src" ] && ! grep -qF "$MARKER" "$src" && cp "$src" "$BACKUP_DIR/$name" || true
done

mkdir -p "$WEB/hooks"
if [ -f "$HOOK" ]; then log "hook already present - leaving it."; else cp "$THOOK" "$HOOK"; log "Added $HOOK"; fi

python3 "$TPATCH" || {
  for f in "$UCT:useCircleTx.ts" "$AG:AuthGuard.tsx" "$AM:AccountMenu.tsx"; do
    src="${f%%:*}"; name="${f##*:}"
    [ -f "$BACKUP_DIR/$name" ] && cp "$BACKUP_DIR/$name" "$src"
  done
  die "Wiring failed; patched files restored."
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
log "Pushed. Wallet session expiry now refreshes the app cleanly; manual sign-out clears wallet UI at once."
