#!/usr/bin/env bash
# ============================================================================
# nexum-account-part2a-sessions-web.sh
# Part 2 (Account Settings) - script 2a-web: "Devices & sessions" card.
#
# Adds a sessions/devices card to the profile page (next to Email preferences).
# Device label from user-agent, last-active time, approximate city, a
# "This device" marker, revoke per row, and "Sign out others". Revoking the
# CURRENT session clears the local session and redirects to /signin.
#
# CHANGES (all in nexum-web):
#   NEW  hooks/useSessions.ts               (list + revoke + revoke-others)
#   NEW  components/profile/SessionsCard.tsx (the card UI)
#   EDIT app/(app)/profile/page.tsx          (import + render after EmailPreferences)
#
# Depends on 2a-api (the /auth/sessions endpoints). Web-only: verify with
#   cd nexum-web && rm -rf .next && npx tsc --noEmit && npm run build
#
# v2 delivery: base64 heredocs (decode + sha verify before replace); anchored
# byte-exact Python edits (assert count==1); backup ONCE per file per run;
# idempotent (marker guarded); --revert restores newest backups.
# ============================================================================
set -euo pipefail

STAMP="$(date +%Y%m%d-%H%M%S)-$$"
WEB="nexum-web"
MARK_HOOK="__NEXUM_USE_SESSIONS__"
MARK_CARD="__NEXUM_SESSIONS_CARD__"

if [ ! -d "$WEB" ] && [ -d "../$WEB" ]; then cd ..; fi
if [ ! -d "$WEB" ]; then echo "ERROR: $WEB not found (run from repo root)"; exit 1; fi

HOOK="$WEB/hooks/useSessions.ts"
CARD="$WEB/components/profile/SessionsCard.tsx"
PAGE="$WEB/app/(app)/profile/page.tsx"

if [ "${1:-}" = "--revert" ]; then
  echo "Reverting Part 2a-web ..."
  newest="$(ls -1t "$PAGE".bak.* 2>/dev/null | head -1 || true)"
  if [ -n "$newest" ]; then cp "$newest" "$PAGE"; echo "  restored $PAGE  (from $(basename "$newest"))"; fi
  for f in "$HOOK" "$CARD"; do
    if [ -f "$f" ]; then rm -f "$f"; echo "  removed  $f"; fi
  done
  echo "Revert complete. Run: cd $WEB && rm -rf .next && npx tsc --noEmit"
  exit 0
fi

if [ -f "$HOOK" ] && [ -f "$CARD" ] && grep -q "SessionsCard" "$PAGE" 2>/dev/null; then
  echo "Part 2a-web already applied (markers present). Nothing to do."
  echo "  (use --revert to undo)"
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

place_file () {
  local b64file="$1" target="$2" want_sha="$3" want_mark="$4"
  local out="$TMP/$(basename "$target")"
  base64 --decode "$b64file" > "$out"
  if [ ! -s "$out" ]; then echo "ERROR: decoded $target is empty"; exit 1; fi
  local got_sha; got_sha="$(sha256sum "$out" | cut -d' ' -f1)"
  if [ "$got_sha" != "$want_sha" ]; then
    echo "ERROR: sha mismatch for $target"; echo "  want $want_sha"; echo "  got  $got_sha"; exit 1
  fi
  if [ -n "$want_mark" ] && ! grep -q "$want_mark" "$out"; then
    echo "ERROR: marker '$want_mark' missing in decoded $target"; exit 1
  fi
  mkdir -p "$(dirname "$target")"
  cp "$out" "$target"
  echo "  wrote $target  (sha ok, ${got_sha:0:12})"
}

cat > "$TMP/hook.b64" <<'B64_HOOK'
J3VzZSBjbGllbnQnCi8vIF9fTkVYVU1fVVNFX1NFU1NJT05TX18KLy8gU2Vzc2lvbnMvZGV2aWNl
cyBkYXRhIGxheWVyLiBSZWFkcyB0aGUgY2FsbGVyJ3MgbGl2ZSBzZXNzaW9ucyBhbmQgcmV2b2tl
cwovLyB0aGVtLCBhbGwgdGhyb3VnaCB0aGUgYXV0aGVudGljYXRlZCBhcGlGZXRjaCAoQmVhcmVy
IG5leHVtX3Rva2VuKS4KaW1wb3J0IHsgdXNlUXVlcnksIHVzZU11dGF0aW9uLCB1c2VRdWVyeUNs
aWVudCB9IGZyb20gJ0B0YW5zdGFjay9yZWFjdC1xdWVyeScKaW1wb3J0IHsgYXBpRmV0Y2ggfSBm
cm9tICdAL2hvb2tzL3VzZUF1dGgnCgpleHBvcnQgaW50ZXJmYWNlIERldmljZVNlc3Npb24gewog
IGlkOiAgICAgICAgICAgICBzdHJpbmcKICBpcF9hZGRyZXNzOiAgICAgc3RyaW5nIHwgbnVsbAog
IHVzZXJfYWdlbnQ6ICAgICBzdHJpbmcgfCBudWxsCiAgbG9jYXRpb25fY2l0eTogIHN0cmluZyB8
IG51bGwKICBjcmVhdGVkX2F0OiAgICAgbnVtYmVyCiAgbGFzdF9hY3RpdmVfYXQ6IG51bWJlciB8
IG51bGwKICBleHBpcmVzX2F0OiAgICAgbnVtYmVyCiAgaXNfY3VycmVudDogICAgIGJvb2xlYW4K
fQoKZXhwb3J0IGZ1bmN0aW9uIHVzZVNlc3Npb25zKCkgewogIHJldHVybiB1c2VRdWVyeTxEZXZp
Y2VTZXNzaW9uW10+KHsKICAgIHF1ZXJ5S2V5OiBbJ3Nlc3Npb25zJ10sCiAgICBxdWVyeUZuOiAg
YXN5bmMgKCkgPT4gewogICAgICBjb25zdCByZXMgPSBhd2FpdCBhcGlGZXRjaCgnL2F1dGgvc2Vz
c2lvbnMnKQogICAgICBpZiAoIXJlcy5vaykgdGhyb3cgbmV3IEVycm9yKCdGYWlsZWQgdG8gbG9h
ZCBzZXNzaW9ucycpCiAgICAgIGNvbnN0IGRhdGEgPSBhd2FpdCByZXMuanNvbigpCiAgICAgIHJl
dHVybiAoZGF0YS5zZXNzaW9ucyA/PyBbXSkgYXMgRGV2aWNlU2Vzc2lvbltdCiAgICB9LAogICAg
c3RhbGVUaW1lOiAzMF8wMDAsCiAgICByZXRyeTogICAgIGZhbHNlLAogIH0pCn0KCmV4cG9ydCBm
dW5jdGlvbiB1c2VSZXZva2VTZXNzaW9uKCkgewogIGNvbnN0IHFjID0gdXNlUXVlcnlDbGllbnQo
KQogIHJldHVybiB1c2VNdXRhdGlvbih7CiAgICBtdXRhdGlvbkZuOiBhc3luYyAoaWQ6IHN0cmlu
ZykgPT4gewogICAgICBjb25zdCByZXMgPSBhd2FpdCBhcGlGZXRjaCgnL2F1dGgvc2Vzc2lvbnMv
cmV2b2tlJywgewogICAgICAgIG1ldGhvZDogJ1BPU1QnLAogICAgICAgIGJvZHk6ICAgSlNPTi5z
dHJpbmdpZnkoeyBpZCB9KSwKICAgICAgfSkKICAgICAgaWYgKCFyZXMub2spIHRocm93IG5ldyBF
cnJvcignRmFpbGVkIHRvIHJldm9rZSBzZXNzaW9uJykKICAgICAgcmV0dXJuIHJlcy5qc29uKCkK
ICAgIH0sCiAgICBvblN1Y2Nlc3M6ICgpID0+IHsgcWMuaW52YWxpZGF0ZVF1ZXJpZXMoeyBxdWVy
eUtleTogWydzZXNzaW9ucyddIH0pIH0sCiAgfSkKfQoKZXhwb3J0IGZ1bmN0aW9uIHVzZVJldm9r
ZU90aGVyU2Vzc2lvbnMoKSB7CiAgY29uc3QgcWMgPSB1c2VRdWVyeUNsaWVudCgpCiAgcmV0dXJu
IHVzZU11dGF0aW9uKHsKICAgIG11dGF0aW9uRm46IGFzeW5jICgpID0+IHsKICAgICAgY29uc3Qg
cmVzID0gYXdhaXQgYXBpRmV0Y2goJy9hdXRoL3Nlc3Npb25zL3Jldm9rZS1vdGhlcnMnLCB7IG1l
dGhvZDogJ1BPU1QnIH0pCiAgICAgIGlmICghcmVzLm9rKSB0aHJvdyBuZXcgRXJyb3IoJ0ZhaWxl
ZCB0byBzaWduIG91dCBvdGhlciBkZXZpY2VzJykKICAgICAgcmV0dXJuIHJlcy5qc29uKCkKICAg
IH0sCiAgICBvblN1Y2Nlc3M6ICgpID0+IHsgcWMuaW52YWxpZGF0ZVF1ZXJpZXMoeyBxdWVyeUtl
eTogWydzZXNzaW9ucyddIH0pIH0sCiAgfSkKfQo=
B64_HOOK
place_file "$TMP/hook.b64" "$HOOK" "f168c890eec5ea15b19afeb172bd9954897ff5bebfad6ea1799d722d398d6856" "$MARK_HOOK"

cat > "$TMP/card.b64" <<'B64_CARD'
J3VzZSBjbGllbnQnCi8vIF9fTkVYVU1fU0VTU0lPTlNfQ0FSRF9fCi8vICJEZXZpY2VzICYgc2Vz
c2lvbnMiIGNhcmQuIExpc3RzIHRoZSB1c2VyJ3MgYWN0aXZlIHNlc3Npb25zIHdpdGggYSBmcmll
bmRseQovLyBkZXZpY2UgbGFiZWwsIGxhc3QtYWN0aXZlIHRpbWUgYW5kIGFwcHJveGltYXRlIGNp
dHksIGFuZCBsZXRzIHRoZW0gcmV2b2tlCi8vIGFueSBzZXNzaW9uLiBSZXZva2luZyB0aGUgQ1VS
UkVOVCBzZXNzaW9uIHNpZ25zIG91dCBsb2NhbGx5IGFuZCByZWRpcmVjdHMgdG8KLy8gL3NpZ25p
biAobWlycm9ycyBBY2NvdW50TWVudSdzIHNpZ24tb3V0KS4KaW1wb3J0IHsgdXNlU3RhdGUgfSBm
cm9tICdyZWFjdCcKaW1wb3J0IHsgdXNlU2Vzc2lvbnMsIHVzZVJldm9rZVNlc3Npb24sIHVzZVJl
dm9rZU90aGVyU2Vzc2lvbnMgfSBmcm9tICdAL2hvb2tzL3VzZVNlc3Npb25zJwppbXBvcnQgeyBj
bGVhclNlc3Npb24gfSBmcm9tICdAL2hvb2tzL3VzZUF1dGgnCmltcG9ydCB7IGNsZWFyU2lnbmlu
Z1Nlc3Npb24gfSBmcm9tICdAL2hvb2tzL3VzZUNpcmNsZVR4JwppbXBvcnQgeyBCdXR0b24gfSBm
cm9tICdAL2NvbXBvbmVudHMvdWkvYnV0dG9uJwppbXBvcnQgeyBMb2FkZXIyLCBNb25pdG9yLCBT
bWFydHBob25lLCBUYWJsZXQsIExvZ091dCB9IGZyb20gJ2x1Y2lkZS1yZWFjdCcKCi8vIEJlc3Qt
ZWZmb3J0IGZyaWVuZGx5IGxhYmVsIGZyb20gYSB1c2VyLWFnZW50IHN0cmluZy4KZnVuY3Rpb24g
ZGV2aWNlTGFiZWwodWE6IHN0cmluZyB8IG51bGwpOiB7IGxhYmVsOiBzdHJpbmc7IGtpbmQ6ICdt
b2JpbGUnIHwgJ3RhYmxldCcgfCAnZGVza3RvcCcgfSB7CiAgaWYgKCF1YSkgcmV0dXJuIHsgbGFi
ZWw6ICdVbmtub3duIGRldmljZScsIGtpbmQ6ICdkZXNrdG9wJyB9CiAgY29uc3QgcyA9IHVhLnRv
TG93ZXJDYXNlKCkKCiAgY29uc3QgaXNUYWJsZXQgPSBzLmluY2x1ZGVzKCdpcGFkJykgfHwgKHMu
aW5jbHVkZXMoJ2FuZHJvaWQnKSAmJiAhcy5pbmNsdWRlcygnbW9iaWxlJykpCiAgY29uc3QgaXNN
b2JpbGUgPSAhaXNUYWJsZXQgJiYgKHMuaW5jbHVkZXMoJ21vYmlsZScpIHx8IHMuaW5jbHVkZXMo
J2lwaG9uZScpIHx8IHMuaW5jbHVkZXMoJ2FuZHJvaWQnKSkKICBjb25zdCBraW5kOiAnbW9iaWxl
JyB8ICd0YWJsZXQnIHwgJ2Rlc2t0b3AnID0gaXNUYWJsZXQgPyAndGFibGV0JyA6IGlzTW9iaWxl
ID8gJ21vYmlsZScgOiAnZGVza3RvcCcKCiAgY29uc3Qgb3MgPQogICAgcy5pbmNsdWRlcygnaXBo
b25lJykgfHwgcy5pbmNsdWRlcygnaXBhZCcpIHx8IHMuaW5jbHVkZXMoJ2lvcycpICAgICA/ICdp
T1MnIDoKICAgIHMuaW5jbHVkZXMoJ21hYyBvcycpIHx8IHMuaW5jbHVkZXMoJ21hY2ludG9zaCcp
ICAgICAgICAgICAgICAgICAgICAgPyAnbWFjT1MnIDoKICAgIHMuaW5jbHVkZXMoJ2FuZHJvaWQn
KSAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA/ICdBbmRyb2lk
JyA6CiAgICBzLmluY2x1ZGVzKCd3aW5kb3dzJykgICAgICAgICAgICAgICAgICAgICAgICAgICAg
ICAgICAgICAgICAgICAgICA/ICdXaW5kb3dzJyA6CiAgICBzLmluY2x1ZGVzKCdsaW51eCcpICAg
ICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA/ICdMaW51eCcgOiAn
JwoKICBjb25zdCBicm93c2VyID0KICAgIHMuaW5jbHVkZXMoJ2VkZy8nKSAgICAgICAgICAgICAg
ICAgICAgICAgPyAnRWRnZScgOgogICAgcy5pbmNsdWRlcygnY2hyb21lJykgJiYgIXMuaW5jbHVk
ZXMoJ2VkZycpID8gJ0Nocm9tZScgOgogICAgcy5pbmNsdWRlcygnZmlyZWZveCcpICAgICAgICAg
ICAgICAgICAgICA/ICdGaXJlZm94JyA6CiAgICBzLmluY2x1ZGVzKCdzYWZhcmknKSAmJiAhcy5p
bmNsdWRlcygnY2hyb21lJykgPyAnU2FmYXJpJyA6ICcnCgogIGNvbnN0IGxhYmVsID0gW2Jyb3dz
ZXIsIG9zXS5maWx0ZXIoQm9vbGVhbikuam9pbignIG9uICcpIHx8ICdVbmtub3duIGRldmljZScK
ICByZXR1cm4geyBsYWJlbCwga2luZCB9Cn0KCmZ1bmN0aW9uIHJlbGF0aXZlVGltZSh0czogbnVt
YmVyIHwgbnVsbCk6IHN0cmluZyB7CiAgaWYgKCF0cykgcmV0dXJuICd1bmtub3duJwogIGNvbnN0
IHNlY3MgPSBNYXRoLm1heCgwLCBNYXRoLmZsb29yKERhdGUubm93KCkgLyAxMDAwKSAtIHRzKQog
IGlmIChzZWNzIDwgNjApICAgICAgcmV0dXJuICdqdXN0IG5vdycKICBjb25zdCBtaW5zID0gTWF0
aC5mbG9vcihzZWNzIC8gNjApCiAgaWYgKG1pbnMgPCA2MCkgICAgICByZXR1cm4gYCR7bWluc30g
bWluJHttaW5zICE9PSAxID8gJ3MnIDogJyd9IGFnb2AKICBjb25zdCBocnMgPSBNYXRoLmZsb29y
KG1pbnMgLyA2MCkKICBpZiAoaHJzIDwgMjQpICAgICAgIHJldHVybiBgJHtocnN9IGhvdXIke2hy
cyAhPT0gMSA/ICdzJyA6ICcnfSBhZ29gCiAgY29uc3QgZGF5cyA9IE1hdGguZmxvb3IoaHJzIC8g
MjQpCiAgaWYgKGRheXMgPCAzMCkgICAgICByZXR1cm4gYCR7ZGF5c30gZGF5JHtkYXlzICE9PSAx
ID8gJ3MnIDogJyd9IGFnb2AKICBjb25zdCBtb250aHMgPSBNYXRoLmZsb29yKGRheXMgLyAzMCkK
ICByZXR1cm4gYCR7bW9udGhzfSBtb250aCR7bW9udGhzICE9PSAxID8gJ3MnIDogJyd9IGFnb2AK
fQoKZXhwb3J0IGZ1bmN0aW9uIFNlc3Npb25zQ2FyZCgpIHsKICBjb25zdCB7IGRhdGE6IHNlc3Np
b25zLCBpc0xvYWRpbmcgfSA9IHVzZVNlc3Npb25zKCkKICBjb25zdCByZXZva2VPbmUgICAgPSB1
c2VSZXZva2VTZXNzaW9uKCkKICBjb25zdCByZXZva2VPdGhlcnMgPSB1c2VSZXZva2VPdGhlclNl
c3Npb25zKCkKICBjb25zdCBbYnVzeUlkLCBzZXRCdXN5SWRdID0gdXNlU3RhdGU8c3RyaW5nIHwg
bnVsbD4obnVsbCkKCiAgZnVuY3Rpb24gc2lnbk91dExvY2FsbHkoKSB7CiAgICBjbGVhclNpZ25p
bmdTZXNzaW9uKCkKICAgIGNsZWFyU2Vzc2lvbigpCiAgICB3aW5kb3cubG9jYXRpb24uaHJlZiA9
ICcvc2lnbmluJwogIH0KCiAgYXN5bmMgZnVuY3Rpb24gaGFuZGxlUmV2b2tlKGlkOiBzdHJpbmcs
IGlzQ3VycmVudDogYm9vbGVhbikgewogICAgc2V0QnVzeUlkKGlkKQogICAgdHJ5IHsKICAgICAg
YXdhaXQgcmV2b2tlT25lLm11dGF0ZUFzeW5jKGlkKQogICAgICBpZiAoaXNDdXJyZW50KSBzaWdu
T3V0TG9jYWxseSgpCiAgICB9IGNhdGNoIHsKICAgICAgc2V0QnVzeUlkKG51bGwpCiAgICB9CiAg
fQoKICBjb25zdCBoYXNPdGhlcnMgPSAoc2Vzc2lvbnMgPz8gW10pLnNvbWUocyA9PiAhcy5pc19j
dXJyZW50KQoKICByZXR1cm4gKAogICAgPGRpdiBjbGFzc05hbWU9InJvdW5kZWQteGwgYm9yZGVy
IGJvcmRlci1hcHAtYm9yZGVyIGJnLWFwcC1zdXJmYWNlIHAtNSI+CiAgICAgIDxkaXYgY2xhc3NO
YW1lPSJtYi0zIGZsZXggaXRlbXMtY2VudGVyIGp1c3RpZnktYmV0d2VlbiI+CiAgICAgICAgPGRp
dj4KICAgICAgICAgIDxwIGNsYXNzTmFtZT0idGV4dC1zbSBmb250LW1lZGl1bSB0ZXh0LWFwcC10
ZXh0Ij5EZXZpY2VzICYgc2Vzc2lvbnM8L3A+CiAgICAgICAgICA8cCBjbGFzc05hbWU9InRleHQt
eHMgdGV4dC1hcHAtbXV0ZWQiPldoZXJlIHlvdSdyZSBzaWduZWQgaW4uIFJldm9rZSBhbnkgeW91
IGRvbid0IHJlY29nbmlzZS48L3A+CiAgICAgICAgPC9kaXY+CiAgICAgICAge2hhc090aGVycyAm
JiAoCiAgICAgICAgICA8QnV0dG9uCiAgICAgICAgICAgIHZhcmlhbnQ9Im91dGxpbmUiIHNpemU9
InNtIgogICAgICAgICAgICBvbkNsaWNrPXsoKSA9PiByZXZva2VPdGhlcnMubXV0YXRlKCl9CiAg
ICAgICAgICAgIGRpc2FibGVkPXtyZXZva2VPdGhlcnMuaXNQZW5kaW5nfQogICAgICAgICAgPgog
ICAgICAgICAgICB7cmV2b2tlT3RoZXJzLmlzUGVuZGluZwogICAgICAgICAgICAgID8gPD48TG9h
ZGVyMiBjbGFzc05hbWU9ImgtMy41IHctMy41IGFuaW1hdGUtc3BpbiIgLz4gV29ya2luZzwvPgog
ICAgICAgICAgICAgIDogPD48TG9nT3V0IGNsYXNzTmFtZT0iaC0zLjUgdy0zLjUiIC8+IFNpZ24g
b3V0IG90aGVyczwvPn0KICAgICAgICAgIDwvQnV0dG9uPgogICAgICAgICl9CiAgICAgIDwvZGl2
PgoKICAgICAge2lzTG9hZGluZyA/ICgKICAgICAgICA8ZGl2IGNsYXNzTmFtZT0iZmxleCBoLTIw
IGl0ZW1zLWNlbnRlciBqdXN0aWZ5LWNlbnRlciI+CiAgICAgICAgICA8TG9hZGVyMiBjbGFzc05h
bWU9ImgtNSB3LTUgYW5pbWF0ZS1zcGluIHRleHQtYXBwLW11dGVkIiAvPgogICAgICAgIDwvZGl2
PgogICAgICApIDogIXNlc3Npb25zIHx8IHNlc3Npb25zLmxlbmd0aCA9PT0gMCA/ICgKICAgICAg
ICA8cCBjbGFzc05hbWU9InB5LTQgdGV4dC1jZW50ZXIgdGV4dC14cyB0ZXh0LWFwcC1tdXRlZCI+
Tm8gYWN0aXZlIHNlc3Npb25zIGZvdW5kLjwvcD4KICAgICAgKSA6ICgKICAgICAgICA8dWwgY2xh
c3NOYW1lPSJzcGFjZS15LTIiPgogICAgICAgICAge3Nlc3Npb25zLm1hcChzID0+IHsKICAgICAg
ICAgICAgY29uc3QgeyBsYWJlbCwga2luZCB9ID0gZGV2aWNlTGFiZWwocy51c2VyX2FnZW50KQog
ICAgICAgICAgICBjb25zdCBJY29uID0ga2luZCA9PT0gJ21vYmlsZScgPyBTbWFydHBob25lIDog
a2luZCA9PT0gJ3RhYmxldCcgPyBUYWJsZXQgOiBNb25pdG9yCiAgICAgICAgICAgIGNvbnN0IGJ1
c3kgPSBidXN5SWQgPT09IHMuaWQgJiYgcmV2b2tlT25lLmlzUGVuZGluZwogICAgICAgICAgICBy
ZXR1cm4gKAogICAgICAgICAgICAgIDxsaSBrZXk9e3MuaWR9CiAgICAgICAgICAgICAgICBjbGFz
c05hbWU9ImZsZXggaXRlbXMtY2VudGVyIGdhcC0zIHJvdW5kZWQtbGcgYm9yZGVyIGJvcmRlci1h
cHAtYm9yZGVyIGJnLWFwcC1iZyBweC0zIHB5LTIuNSI+CiAgICAgICAgICAgICAgICA8SWNvbiBj
bGFzc05hbWU9ImgtNCB3LTQgc2hyaW5rLTAgdGV4dC1hcHAtbXV0ZWQiIC8+CiAgICAgICAgICAg
ICAgICA8ZGl2IGNsYXNzTmFtZT0ibWluLXctMCBmbGV4LTEiPgogICAgICAgICAgICAgICAgICA8
ZGl2IGNsYXNzTmFtZT0iZmxleCBpdGVtcy1jZW50ZXIgZ2FwLTIiPgogICAgICAgICAgICAgICAg
ICAgIDxwIGNsYXNzTmFtZT0idHJ1bmNhdGUgdGV4dC1zbSB0ZXh0LWFwcC10ZXh0Ij57bGFiZWx9
PC9wPgogICAgICAgICAgICAgICAgICAgIHtzLmlzX2N1cnJlbnQgJiYgKAogICAgICAgICAgICAg
ICAgICAgICAgPHNwYW4gY2xhc3NOYW1lPSJzaHJpbmstMCByb3VuZGVkLWZ1bGwgYmctYXBwLWFj
Y2VudC8xMCBweC0yIHB5LTAuNSB0ZXh0LVsxMHB4XSB0ZXh0LWFwcC1hY2NlbnQtdGV4dCI+CiAg
ICAgICAgICAgICAgICAgICAgICAgIFRoaXMgZGV2aWNlCiAgICAgICAgICAgICAgICAgICAgICA8
L3NwYW4+CiAgICAgICAgICAgICAgICAgICAgKX0KICAgICAgICAgICAgICAgICAgPC9kaXY+CiAg
ICAgICAgICAgICAgICAgIDxwIGNsYXNzTmFtZT0idHJ1bmNhdGUgdGV4dC14cyB0ZXh0LWFwcC1t
dXRlZCI+CiAgICAgICAgICAgICAgICAgICAge3MubG9jYXRpb25fY2l0eSA/IGAke3MubG9jYXRp
b25fY2l0eX0gwrcgYCA6ICcnfUFjdGl2ZSB7cmVsYXRpdmVUaW1lKHMubGFzdF9hY3RpdmVfYXQp
fQogICAgICAgICAgICAgICAgICA8L3A+CiAgICAgICAgICAgICAgICA8L2Rpdj4KICAgICAgICAg
ICAgICAgIDxidXR0b24KICAgICAgICAgICAgICAgICAgb25DbGljaz17KCkgPT4gaGFuZGxlUmV2
b2tlKHMuaWQsIHMuaXNfY3VycmVudCl9CiAgICAgICAgICAgICAgICAgIGRpc2FibGVkPXtidXN5
fQogICAgICAgICAgICAgICAgICBjbGFzc05hbWU9InNocmluay0wIHJvdW5kZWQtbWQgYm9yZGVy
IGJvcmRlci1hcHAtYm9yZGVyIHB4LTIuNSBweS0xIHRleHQteHMgdGV4dC1hcHAtbXV0ZWQgdHJh
bnNpdGlvbi1jb2xvcnMgaG92ZXI6Ym9yZGVyLXJlZC05MDAvNDAgaG92ZXI6dGV4dC1yZWQtNDAw
IGRpc2FibGVkOm9wYWNpdHktNTAiCiAgICAgICAgICAgICAgICA+CiAgICAgICAgICAgICAgICAg
IHtidXN5ID8gPExvYWRlcjIgY2xhc3NOYW1lPSJoLTMuNSB3LTMuNSBhbmltYXRlLXNwaW4iIC8+
IDogKHMuaXNfY3VycmVudCA/ICdTaWduIG91dCcgOiAnUmV2b2tlJyl9CiAgICAgICAgICAgICAg
ICA8L2J1dHRvbj4KICAgICAgICAgICAgICA8L2xpPgogICAgICAgICAgICApCiAgICAgICAgICB9
KX0KICAgICAgICA8L3VsPgogICAgICApfQogICAgPC9kaXY+CiAgKQp9Cg==
B64_CARD
place_file "$TMP/card.b64" "$CARD" "064ccb8a612dd5cb16fe2ac1705a155ad77ed1223cb4683e992ab6b42d21b37b" "$MARK_CARD"

python3 - "$PAGE" "$STAMP" <<'PYEOF'
import sys
page_path, stamp = sys.argv[1], sys.argv[2]

def backup_once(path):
    import os, shutil
    b = f"{path}.bak.{stamp}"
    if not os.path.exists(b):
        shutil.copy2(path, b)
        print(f"  backup {b}")

def edit(path, anchor, replacement, label):
    with open(path, encoding='utf-8') as f:
        s = f.read()
    n = s.count(anchor)
    assert n == 1, f"ANCHOR for {label} matched {n} times in {path} (need exactly 1)"
    backup_once(path)
    s = s.replace(anchor, replacement, 1)
    with open(path, 'w', encoding='utf-8') as f:
        f.write(s)
    print(f"  edited {path}: {label}")

# import SessionsCard (anchor: the EmailPreferences import, present since before 1c)
edit(page_path,
     "import { EmailPreferences } from '@/components/notifications/EmailPreferences'",
     "import { EmailPreferences } from '@/components/notifications/EmailPreferences'\n"
     "import { SessionsCard } from '@/components/profile/SessionsCard'",
     "SessionsCard import")

# render SessionsCard after EmailPreferences (anchor: the render + its comment)
edit(page_path,
     "          {/* Email notification preferences */}\n"
     "          <EmailPreferences />",
     "          {/* Email notification preferences */}\n"
     "          <EmailPreferences />\n\n"
     "          {/* Devices & sessions */}\n"
     "          <SessionsCard />",
     "SessionsCard render")

print("All 2a-web anchored edits applied.")

PYEOF

echo ""
echo "Part 2a-web applied - Part 2 (Account Settings) COMPLETE. Next steps:"
echo "  cd $WEB && rm -rf .next && npx tsc --noEmit && npm run build"
echo "  (then commit + push; Vercel auto-deploys web)"
echo "Revert with: bash $(basename \"$0\") --revert"
