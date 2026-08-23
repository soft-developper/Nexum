#!/usr/bin/env bash
# ============================================================
# ramp-phase5-part4-drain-webhooks.sh
#
# Phase 5 (OFF-RAMP) — Part 4: drain webhooks + reconciliation + payout emails.
# API-ONLY. Depends on Parts 1–3. Mirrors the on-ramp Phase 3/4 deposit work.
#
# Adds, under nexum-api:
#   NEW  migrations/0025_ramp_drain_events.sql          (drain mirror + notif dedup)
#   NEW  src/services/bridgexyz/payoutNotify.ts         (branded payout emails)
#   EDIT src/services/bridgexyz/webhooks.ts             (+extractDrainDetail)
#   EDIT src/services/bridgexyz/repository.ts           (+drain CRUD, claim, LA-by-id)
#   EDIT src/services/email/templates.ts                (+payoutPaid/Returned emails)
#   EDIT src/routes/transfers.ts                        (webhook drain branch)
#   EDIT src/routes/ramp.ts                             (drains endpoint: merge poll+mirror)
#   EDIT src/services/bridgexyz/ensureOfframp.ts        (boot self-heal for 0025 tables)
#
# The webhook handler now mirrors liquidation_address drain events into
# ramp_drain_events (dedup via ramp_webhook_events) and fires payoutPaidEmail /
# payoutReturnedEmail on terminal states (paid / returned / failed), deduped per
# (drain, kind). The /drains endpoint merges Bridge's poll (ground truth) with
# the webhook mirror. Given the migration-runner history, the two new tables are
# ALSO created at boot by ensureOfframpSchema (self-heal) — no dependence on 0025
# actually running.
#
# ⚠ SANDBOX: Bridge sandbox won't fire drain webhooks or drain in prod-like
# fashion — this is proven by unit tests + schema and lights up on a real
# production withdrawal (same as the on-ramp deposit webhooks).
#
# v2 delivery: every payload → own temp file → decode → verify (marker) before
# replacing. Appends guarded by markers; edits are anchored byte-exact and abort
# cleanly if an anchor isn't found. Idempotent. --revert restores all backups
# and removes the new files.
#
# Usage:
#   bash ramp-phase5-part4-drain-webhooks.sh          # apply
#   bash ramp-phase5-part4-drain-webhooks.sh --revert # undo
# ============================================================
set -euo pipefail
STAMP="$(date +%Y%m%d-%H%M%S)"

if [ -d "nexum-api" ]; then API="nexum-api"
elif [ -d "../nexum-api" ]; then API="../nexum-api"
elif [ -f "package.json" ] && grep -q '"name": *"nexum-api"\|afrifx-api' package.json 2>/dev/null; then API="."
else echo "ERROR: run from the repo root (~/AfriFX) or nexum-api." >&2; exit 1; fi
echo "Using API package at: $API"

MIG="$API/migrations/0025_ramp_drain_events.sql"
NOTIFY="$API/src/services/bridgexyz/payoutNotify.ts"
WEBHOOKS="$API/src/services/bridgexyz/webhooks.ts"
REPO="$API/src/services/bridgexyz/repository.ts"
TEMPLATES="$API/src/services/email/templates.ts"
TRANSFERS="$API/src/routes/transfers.ts"
RAMP="$API/src/routes/ramp.ts"
ENSURE="$API/src/services/bridgexyz/ensureOfframp.ts"

for f in "$WEBHOOKS" "$REPO" "$TEMPLATES" "$TRANSFERS" "$RAMP"; do
  [ -f "$f" ] || { echo "ERROR: $f not found (are Parts 1-3 applied?)." >&2; exit 1; }
done

# ---- revert -----------------------------------------------------------------
if [ "${1:-}" = "--revert" ]; then
  echo "Reverting Phase 5 Part 4..."
  for f in "$WEBHOOKS" "$REPO" "$TEMPLATES" "$TRANSFERS" "$RAMP" "$ENSURE"; do
    BK="$(ls -t "$f".bak.* 2>/dev/null | head -1 || true)"
    [ -n "$BK" ] && { cp "$BK" "$f"; echo "  restored $f"; }
  done
  [ -f "$NOTIFY" ] && { rm -f "$NOTIFY"; echo "  removed $NOTIFY"; }
  [ -f "$MIG" ] && { rm -f "$MIG"; echo "  removed $MIG"; }
  echo "Revert complete. Re-run: cd $API && npx tsc --noEmit && npm run build"
  exit 0
fi

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# decode a b64 file to a path, verifying non-empty + marker
decode_verify () { # <b64file> <outfile> <marker>
  if ! base64 --decode "$1" > "$2" 2>/dev/null; then echo "ERROR: decode failed for $2" >&2; exit 1; fi
  if [ ! -s "$2" ]; then echo "ERROR: $2 empty after decode" >&2; exit 1; fi
  if [ -n "$3" ] && ! grep -qF "$3" "$2"; then echo "ERROR: marker '$3' missing in $2" >&2; exit 1; fi
}
# anchored replace in a file: <file> <old_b64> <new_b64> <guard_marker>
anchored_replace () {
  local file="$1" oldb="$2" newb="$3" guard="$4"
  if grep -qF "$guard" "$file" 2>/dev/null; then echo "  $(basename "$file"): already has '$guard' — skipping"; return; fi
  decode_verify "$oldb" "$TMP/old.txt" ""
  decode_verify "$newb" "$TMP/new.txt" ""
  local old new; old="$(cat "$TMP/old.txt")"; new="$(cat "$TMP/new.txt")"
  if ! grep -qF "$old" "$file"; then echo "ERROR: anchor not found in $file — aborting (no changes to this file)." >&2; exit 1; fi
  [ -f "$file.bak.$STAMP" ] || cp "$file" "$file.bak.$STAMP"
  # Python does the exact single replacement (safe with special chars)
  OLD="$old" NEW="$new" python3 - "$file" <<'PY'
import os, sys
p = sys.argv[1]; s = open(p).read()
old = os.environ['OLD']; new = os.environ['NEW']
assert s.count(old) == 1, f"expected 1 anchor in {p}, found {s.count(old)}"
open(p,'w').write(s.replace(old, new, 1))
PY
  if ! grep -qF "$guard" "$file"; then echo "ERROR: post-edit verify failed for $file — restoring." >&2; cp "$file.bak.$STAMP" "$file"; exit 1; fi
  echo "  edited $(basename "$file")"
}

cat > "$TMP/mig" <<'B64_mig'
LS0gPT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
PT09PT09Ci0tIDAwMjVfcmFtcF9kcmFpbl9ldmVudHMuc3FsCi0tIEJyaWRnZS54eXogT0ZGLXJh
bXAsIFBoYXNlIDUgUGFydCA0IOKAlCBkcmFpbiB3ZWJob29rcyArIHJlY29uY2lsaWF0aW9uLgot
LQotLSBNaXJyb3JzIHRoZSBvbi1yYW1wIGRlcG9zaXQgdGFibGVzICgwMDIwLzAwMjEpIGZvciB0
aGUgb2ZmLXJhbXAgZGlyZWN0aW9uOgotLSAgIHJhbXBfZHJhaW5fZXZlbnRzICAgICAgICDigJQg
YSBzbWFsbCBNSVJST1Igb2YgbGlxdWlkYXRpb24tYWRkcmVzcyBkcmFpbgotLSAgICAgICAgICAg
ICAgICAgICAgICAgICAgICAgIGFjdGl2aXR5LCBzbyB0aGUgL3JhbXAgd2l0aGRyYXdhbCB0cmFj
a2VyIGNhbgotLSAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIHJlYWQgdGhlIGxhdGVzdCBz
dGF0ZSBpbnN0YW50bHkgaW5zdGVhZCBvZgotLSAgICAgICAgICAgICAgICAgICAgICAgICAgICAg
IHdhaXRpbmcgb24gaXRzIHBvbGwgb2YgQnJpZGdlJ3MgL2RyYWlucy4gVGhlCi0tICAgICAgICAg
ICAgICAgICAgICAgICAgICAgICAgcG9sbCBSRU1BSU5TIGdyb3VuZCB0cnV0aDsgdGhpcyBpcyBh
biBvcHRpbWlzYXRpb24uCi0tICAgcmFtcF9kcmFpbl9ub3RpZmljYXRpb25zIOKAlCBkZWR1cCBn
dWFyZCBzbyBlYWNoIChkcmFpbiwga2luZCkgZW1haWxzIGF0IG1vc3QKLS0gICAgICAgICAgICAg
ICAgICAgICAgICAgICAgICBvbmNlLCBldmVuIG9uIHdlYmhvb2sgcmVkZWxpdmVyeS4ga2luZCDi
iIgKLS0gICAgICAgICAgICAgICAgICAgICAgICAgICAgICAoJ3NlbnQnLCdwYWlkJywncmV0dXJu
ZWQnLCdyZXR1cm5lZF9mYWlsZWQnKS4KLS0KLS0gTm8gUElJOiBkcmFpbiBhbW91bnRzICsgQnJp
ZGdlIGlkcyBvbmx5LCBzYW1lIGRhdGEgdGhlIHRyYWNrZXIgYWxyZWFkeQotLSBmZXRjaGVzIGZy
b20gL2RyYWlucy4gcmFtcF93ZWJob29rX2V2ZW50cyAoZnJvbSAwMDIwKSBpcyByZXVzZWQgYXMg
dGhlCi0tIHNoYXJlZCBpZGVtcG90ZW5jeSBsb2cg4oCUIG5vIG5ldyBhdWRpdCB0YWJsZSBuZWVk
ZWQuCi0tID09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
PT09PT09PT09PQoKQ1JFQVRFIFRBQkxFIElGIE5PVCBFWElTVFMgcmFtcF9kcmFpbl9ldmVudHMg
KAogIGlkICAgICAgICAgICAgICAgICAgICAgVEVYVCBQUklNQVJZIEtFWSwgICAgICAgLS0gb3Vy
IHV1aWQKICBwcm92aWRlciAgICAgICAgICAgICAgIFRFWFQgTk9UIE5VTEwgREVGQVVMVCAnYnJp
ZGdleHl6JywKICBsaXF1aWRhdGlvbl9hZGRyZXNzX2lkIFRFWFQsICAgICAgICAgICAgICAgICAg
IC0tIEJyaWRnZSBsaXF1aWRhdGlvbiBhZGRyZXNzIGlkCiAgZHJhaW5faWQgICAgICAgICAgICAg
ICBURVhULCAgICAgICAgICAgICAgICAgICAtLSBCcmlkZ2UgZHJhaW4gaWQgKGdyb3VwcyBhIGRy
YWluJ3MgZXZlbnRzKQogIGV2ZW50X2lkICAgICAgICAgICAgICAgVEVYVCwgICAgICAgICAgICAg
ICAgICAgLS0gc291cmNlIHdlYmhvb2sgZXZlbnRfaWQgKG51bGxhYmxlIGlmIGZyb20gcG9sbCkK
ICBzdGF0ZSAgICAgICAgICAgICAgICAgIFRFWFQsICAgICAgICAgICAgICAgICAgIC0tIGZ1bmRz
X3JlY2VpdmVkIHwgcGF5bWVudF9zdWJtaXR0ZWQgfCBwYXltZW50X3Byb2Nlc3NlZCB8IHVuZGVs
aXZlcmFibGUgfCByZXR1cm5lZCB8IHJlZnVuZGVkIHwgZXJyb3IgfCBjYW5jZWxlZAogIGN1cnJl
bmN5ICAgICAgICAgICAgICAgVEVYVCwgICAgICAgICAgICAgICAgICAgLS0gZGVzdGluYXRpb24g
ZmlhdCBjdXJyZW5jeQogIGFtb3VudCAgICAgICAgICAgICAgICAgVEVYVCwKICBkZXBvc2l0X3R4
X2hhc2ggICAgICAgIFRFWFQsICAgICAgICAgICAgICAgICAgIC0tIG9uLWNoYWluIHR4IHRoYXQg
ZnVuZGVkIHRoZSBkcmFpbgogIGRlc3RpbmF0aW9uX3R4X2hhc2ggICAgVEVYVCwgICAgICAgICAg
ICAgICAgICAgLS0gcGF5b3V0IHJlZmVyZW5jZSAoZmlhdCBzaWRlKSwgd2hlbiBwcmVzZW50CiAg
c291cmNlICAgICAgICAgICAgICAgICBURVhUIE5PVCBOVUxMIERFRkFVTFQgJ3dlYmhvb2snLCAg
LS0gJ3dlYmhvb2snIHwgJ3BvbGwnCiAgY3JlYXRlZF9hdCAgICAgICAgICAgICBJTlRFR0VSIE5P
VCBOVUxMLAogIC0tIE9uZSByb3cgcGVyIChsaXF1aWRhdGlvbiBhZGRyZXNzLCBkcmFpbiwgc3Rh
dGUpOiBhIHdlYmhvb2sgYW5kIGEgbGF0ZXIgcG9sbAogIC0tIG9mIHRoZSBzYW1lIGV2ZW50IGNv
bGxhcHNlIGluc3RlYWQgb2YgZHVwbGljYXRpbmcuCiAgVU5JUVVFIChsaXF1aWRhdGlvbl9hZGRy
ZXNzX2lkLCBkcmFpbl9pZCwgc3RhdGUpCik7CgpDUkVBVEUgSU5ERVggSUYgTk9UIEVYSVNUUyBp
ZHhfcmFtcF9kcmFpbl9ldmVudHNfbGEKICBPTiByYW1wX2RyYWluX2V2ZW50cyAobGlxdWlkYXRp
b25fYWRkcmVzc19pZCk7CkNSRUFURSBJTkRFWCBJRiBOT1QgRVhJU1RTIGlkeF9yYW1wX2RyYWlu
X2V2ZW50c19kcmFpbgogIE9OIHJhbXBfZHJhaW5fZXZlbnRzIChkcmFpbl9pZCk7CgpDUkVBVEUg
VEFCTEUgSUYgTk9UIEVYSVNUUyByYW1wX2RyYWluX25vdGlmaWNhdGlvbnMgKAogIGlkICAgICAg
ICAgICAgICAgICAgICAgVEVYVCBQUklNQVJZIEtFWSwgICAgICAgLS0gb3VyIHV1aWQKICBsaXF1
aWRhdGlvbl9hZGRyZXNzX2lkIFRFWFQsCiAgZHJhaW5faWQgICAgICAgICAgICAgICBURVhULAog
IGtpbmQgICAgICAgICAgICAgICAgICAgVEVYVCBOT1QgTlVMTCwgICAgICAgICAgLS0gc2VudCB8
IHBhaWQgfCByZXR1cm5lZCB8IHJldHVybmVkX2ZhaWxlZAogIHNlbnRfYXQgICAgICAgICAgICAg
ICAgSU5URUdFUiBOT1QgTlVMTCwKICBVTklRVUUgKGxpcXVpZGF0aW9uX2FkZHJlc3NfaWQsIGRy
YWluX2lkLCBraW5kKQopOwoKQ1JFQVRFIElOREVYIElGIE5PVCBFWElTVFMgaWR4X3JhbXBfZHJh
aW5fbm90aWZpY2F0aW9uc19kcmFpbgogIE9OIHJhbXBfZHJhaW5fbm90aWZpY2F0aW9ucyAoZHJh
aW5faWQpOwo=
B64_mig
cat > "$TMP/notify" <<'B64_notify'
Ly8gPT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
PT09PT09Ci8vIFBheW91dCBlbWFpbCBub3RpZmljYXRpb25zIChQaGFzZSA1IFBhcnQgNCkg4oCU
IG9mZi1yYW1wIG1pcnJvciBvZgovLyBkZXBvc2l0Tm90aWZ5LnRzLgovLwovLyBDYWxsZWQgZnJv
bSB0aGUgQnJpZGdlIHdlYmhvb2sgaGFuZGxlciBhZnRlciBhIHZlcmlmaWVkIGxpcXVpZGF0aW9u
X2FkZHJlc3MKLy8gZHJhaW4gZXZlbnQgaXMgbWlycm9yZWQuIEZpcmVzIGEgYnJhbmRlZCBlbWFp
bCBvbiB0ZXJtaW5hbCBkcmFpbiBzdGF0ZXM6Ci8vICAg4oCiIHBheW1lbnRfcHJvY2Vzc2VkICAg
ICAgICAgICAgICAgICAgICAgICDihpIgIndpdGhkcmF3YWwgcGFpZCIgKGZpYXQgc2VudCkKLy8g
ICDigKIgcmV0dXJuZWQgLyByZWZ1bmRlZCAgICAgICAgICAgICAgICAgICAgIOKGkiAid2l0aGRy
YXdhbCByZXR1cm5lZCIKLy8gICDigKIgdW5kZWxpdmVyYWJsZSAvIGVycm9yIC8gY2FuY2VsZWQg
ICAgICAgIOKGkiAid2l0aGRyYXdhbCBmYWlsZWQiIChuZWVkcyBzdXBwb3J0KQovLwovLyBFdmVy
eSBzZW5kIGlzIGd1YXJkZWQgYnkgY2xhaW1EcmFpbk5vdGlmaWNhdGlvbigpIHNvIGEgd2ViaG9v
ayByZWRlbGl2ZXJ5IChvcgovLyB0aGUgc2FtZSBldmVudCB2aWEgcG9sbCkgY2FuIG9ubHkgZW1h
aWwgb25jZSBwZXIgKGRyYWluLCBraW5kKS4gQmVzdC1lZmZvcnQ6Ci8vIGFueSBmYWlsdXJlIGlz
IGxvZ2dlZCBhbmQgc3dhbGxvd2VkIHNvIGl0IG5ldmVyIGJyZWFrcyB3ZWJob29rIHByb2Nlc3Np
bmcuCi8vID09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
PT09PT09PT09PQoKaW1wb3J0IHsgc2VuZEVtYWlsIH0gZnJvbSAnLi4vZW1haWwvY2xpZW50Jwpp
bXBvcnQgeyBwYXlvdXRQYWlkRW1haWwsIHBheW91dFJldHVybmVkRW1haWwgfSBmcm9tICcuLi9l
bWFpbC90ZW1wbGF0ZXMnCmltcG9ydCB7CiAgZ2V0QWNjb3VudENvbnRhY3QsIGdldExpcXVpZGF0
aW9uQWRkcmVzc1Jvd0J5SWQsIGNsYWltRHJhaW5Ob3RpZmljYXRpb24sCn0gZnJvbSAnLi9yZXBv
c2l0b3J5JwppbXBvcnQgdHlwZSB7IERyYWluRGV0YWlsIH0gZnJvbSAnLi93ZWJob29rcycKCnR5
cGUgS2luZCA9ICdwYWlkJyB8ICdyZXR1cm5lZCcgfCAncmV0dXJuZWRfZmFpbGVkJwpmdW5jdGlv
biBraW5kRm9yU3RhdGUoc3RhdGU6IHN0cmluZyB8IG51bGwpOiBLaW5kIHwgbnVsbCB7CiAgc3dp
dGNoIChzdGF0ZSkgewogICAgY2FzZSAncGF5bWVudF9wcm9jZXNzZWQnOiByZXR1cm4gJ3BhaWQn
CiAgICBjYXNlICdyZXR1cm5lZCc6CiAgICBjYXNlICdyZWZ1bmRlZCc6ICAgICAgICAgIHJldHVy
biAncmV0dXJuZWQnCiAgICBjYXNlICd1bmRlbGl2ZXJhYmxlJzoKICAgIGNhc2UgJ2Vycm9yJzoK
ICAgIGNhc2UgJ2NhbmNlbGVkJzogICAgICAgICAgcmV0dXJuICdyZXR1cm5lZF9mYWlsZWQnCiAg
ICBkZWZhdWx0OiAgICAgICAgICAgICAgICAgIHJldHVybiBudWxsCiAgfQp9CgpleHBvcnQgYXN5
bmMgZnVuY3Rpb24gbWF5YmVTZW5kUGF5b3V0RW1haWwoZGV0YWlsOiBEcmFpbkRldGFpbCk6IFBy
b21pc2U8dm9pZD4gewogIHRyeSB7CiAgICBjb25zdCBraW5kID0ga2luZEZvclN0YXRlKGRldGFp
bC5zdGF0ZSkKICAgIGlmICgha2luZCkgcmV0dXJuIC8vIG5vdCBhIHRlcm1pbmFsIHN0YXRlIHdl
IG5vdGlmeSBvbgogICAgaWYgKCFkZXRhaWwubGlxdWlkYXRpb25BZGRyZXNzSWQpIHJldHVybgoK
ICAgIC8vIENsYWltIGZpcnN0IOKAlCBjaGVhcCBndWFyZCwgYXZvaWRzIGxvb2t1cHMgZm9yIGEg
ZHVwZS4KICAgIGNvbnN0IHdvbiA9IGF3YWl0IGNsYWltRHJhaW5Ob3RpZmljYXRpb24oewogICAg
ICBsaXF1aWRhdGlvbkFkZHJlc3NJZDogZGV0YWlsLmxpcXVpZGF0aW9uQWRkcmVzc0lkLAogICAg
ICBkcmFpbklkOiAgICAgICAgICAgICAgZGV0YWlsLmRyYWluSWQsCiAgICAgIGtpbmQsCiAgICB9
KQogICAgaWYgKCF3b24pIHJldHVybgoKICAgIGNvbnN0IGxhUm93ID0gYXdhaXQgZ2V0TGlxdWlk
YXRpb25BZGRyZXNzUm93QnlJZChkZXRhaWwubGlxdWlkYXRpb25BZGRyZXNzSWQpCiAgICBpZiAo
IWxhUm93KSB7IGNvbnNvbGUud2FybignW1BheW91dE5vdGlmeV0gbm8gTEEgcm93IGZvcicsIGRl
dGFpbC5saXF1aWRhdGlvbkFkZHJlc3NJZCk7IHJldHVybiB9CiAgICBjb25zdCBjb250YWN0ID0g
YXdhaXQgZ2V0QWNjb3VudENvbnRhY3QobGFSb3cuYWNjb3VudF9pZCkKICAgIGlmICghY29udGFj
dD8uZW1haWwpIHsgY29uc29sZS53YXJuKCdbUGF5b3V0Tm90aWZ5XSBubyBlbWFpbCBmb3IgYWNj
b3VudCcsIGxhUm93LmFjY291bnRfaWQpOyByZXR1cm4gfQoKICAgIGNvbnN0IGRpc3BsYXlOYW1l
ID0gY29udGFjdC5kaXNwbGF5X25hbWUgPz8gJ3RoZXJlJwogICAgY29uc3QgY3VycmVuY3kgICAg
PSBkZXRhaWwuY3VycmVuY3kgPz8gbGFSb3cuZGVzdGluYXRpb25fY3VycmVuY3kgPz8gdW5kZWZp
bmVkCiAgICBjb25zdCByYWlsICAgICAgICA9IGxhUm93LmRlc3RpbmF0aW9uX3BheW1lbnRfcmFp
bCA/PyB1bmRlZmluZWQKCiAgICBsZXQgdG1wbDogeyBzdWJqZWN0OiBzdHJpbmc7IGh0bWw6IHN0
cmluZyB9CiAgICBpZiAoa2luZCA9PT0gJ3BhaWQnKSB7CiAgICAgIHRtcGwgPSBwYXlvdXRQYWlk
RW1haWwoewogICAgICAgIGRpc3BsYXlOYW1lLAogICAgICAgIGFtb3VudDogICAgZGV0YWlsLmFt
b3VudCA/PyAn4oCUJywKICAgICAgICBjdXJyZW5jeSwKICAgICAgICByYWlsLAogICAgICAgIHJl
ZmVyZW5jZTogZGV0YWlsLmRlc3RpbmF0aW9uVHhIYXNoID8/IHVuZGVmaW5lZCwKICAgICAgfSkK
ICAgIH0gZWxzZSB7CiAgICAgIHRtcGwgPSBwYXlvdXRSZXR1cm5lZEVtYWlsKHsKICAgICAgICBk
aXNwbGF5TmFtZSwKICAgICAgICBhbW91bnQ6ICAgZGV0YWlsLmFtb3VudCA/PyB1bmRlZmluZWQs
CiAgICAgICAgY3VycmVuY3ksCiAgICAgICAgZmFpbGVkOiAgIGtpbmQgPT09ICdyZXR1cm5lZF9m
YWlsZWQnLAogICAgICB9KQogICAgfQoKICAgIGNvbnN0IHJlcyA9IGF3YWl0IHNlbmRFbWFpbCh7
IHRvOiBjb250YWN0LmVtYWlsLCBzdWJqZWN0OiB0bXBsLnN1YmplY3QsIGh0bWw6IHRtcGwuaHRt
bCB9KQogICAgaWYgKCFyZXMuc3VjY2VzcykgY29uc29sZS5lcnJvcignW1BheW91dE5vdGlmeV0g
c2VuZCBmYWlsZWQ6JywgcmVzLmVycm9yKQogIH0gY2F0Y2ggKGVycjogYW55KSB7CiAgICBjb25z
b2xlLmVycm9yKCdbUGF5b3V0Tm90aWZ5XSBlcnJvcjonLCBlcnI/Lm1lc3NhZ2UpCiAgfQp9Cg==
B64_notify
cat > "$TMP/wh_append" <<'B64_wh_append'
Ci8qKgogKiBGb3IgYSBsaXF1aWRhdGlvbl9hZGRyZXNzIGRyYWluIGV2ZW50LCBkaWcgb3V0IHRo
ZSBmaWVsZHMgd2UgbWlycm9yIGxvY2FsbHkuCiAqIFRoZSBldmVudF9vYmplY3QgbWlycm9ycyB0
aGUgL2RyYWlucyBEcmFpbiBzaGFwZS4gUmV0dXJucyBudWxsIGZvciBldmVudHMKICogdGhhdCBh
cmVuJ3QgbGlxdWlkYXRpb24tYWRkcmVzcyBkcmFpbnMuCiAqCiAqIEJyaWRnZSBkcmFpbiBzdGF0
ZXM6IGZ1bmRzX3JlY2VpdmVkIOKGkiBwYXltZW50X3N1Ym1pdHRlZCDihpIgcGF5bWVudF9wcm9j
ZXNzZWQsCiAqIHBsdXMgdW5kZWxpdmVyYWJsZSB8IHJldHVybmVkIHwgcmVmdW5kZWQgfCBlcnJv
ciB8IGNhbmNlbGVkLgogKi8KZXhwb3J0IGludGVyZmFjZSBEcmFpbkRldGFpbCB7CiAgbGlxdWlk
YXRpb25BZGRyZXNzSWQ6IHN0cmluZyB8IG51bGwKICBkcmFpbklkOiAgICAgICAgICAgICAgc3Ry
aW5nIHwgbnVsbAogIHN0YXRlOiAgICAgICAgICAgICAgICBzdHJpbmcgfCBudWxsCiAgYW1vdW50
OiAgICAgICAgICAgICAgIHN0cmluZyB8IG51bGwKICBjdXJyZW5jeTogICAgICAgICAgICAgc3Ry
aW5nIHwgbnVsbAogIGRlcG9zaXRUeEhhc2g6ICAgICAgICBzdHJpbmcgfCBudWxsCiAgZGVzdGlu
YXRpb25UeEhhc2g6ICAgIHN0cmluZyB8IG51bGwKfQoKZXhwb3J0IGZ1bmN0aW9uIGV4dHJhY3RE
cmFpbkRldGFpbChldmVudDogQnJpZGdlV2ViaG9va0V2ZW50KTogRHJhaW5EZXRhaWwgfCBudWxs
IHsKICBpZiAoIS9saXF1aWRhdGlvbl9hZGRyZXNzL2kudGVzdChldmVudC5ldmVudF9jYXRlZ29y
eSkpIHJldHVybiBudWxsCiAgY29uc3QgbyA9IChldmVudC5ldmVudF9vYmplY3QgPz8ge30pIGFz
IFJlY29yZDxzdHJpbmcsIGFueT4KICBjb25zdCBkZXN0ID0gKG8uZGVzdGluYXRpb24gPz8ge30p
IGFzIFJlY29yZDxzdHJpbmcsIGFueT4KICByZXR1cm4gewogICAgbGlxdWlkYXRpb25BZGRyZXNz
SWQ6IG8ubGlxdWlkYXRpb25fYWRkcmVzc19pZCA/PyBvLmxpcXVpZGF0aW9uQWRkcmVzc0lkID8/
IG51bGwsCiAgICBkcmFpbklkOiAgICAgICAgICAgICAgby5pZCA/PyBvLmRyYWluX2lkID8/IG51
bGwsCiAgICBzdGF0ZTogICAgICAgICAgICAgICAgby5zdGF0ZSA/PyBldmVudC5ldmVudF90eXBl
ID8/IG51bGwsCiAgICBhbW91bnQ6ICAgICAgICAgICAgICAgby5hbW91bnQgPz8gbnVsbCwKICAg
IGN1cnJlbmN5OiAgICAgICAgICAgICBvLmN1cnJlbmN5ID8/IGRlc3QuY3VycmVuY3kgPz8gbnVs
bCwKICAgIGRlcG9zaXRUeEhhc2g6ICAgICAgICBvLmRlcG9zaXRfdHhfaGFzaCA/PyBudWxsLAog
ICAgZGVzdGluYXRpb25UeEhhc2g6ICAgIG8uZGVzdGluYXRpb25fdHhfaGFzaCA/PyBudWxsLAog
IH0KfQo=
B64_wh_append
cat > "$TMP/repo_append" <<'B64_repo_append'
Ci8vIOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKV
kOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKV
kOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKV
kOKVkOKVkAovLyBQaGFzZSA1IFBhcnQgNCDigJQgb2ZmLXJhbXAgZHJhaW4gZXZlbnRzICsgcGF5
b3V0IG5vdGlmaWNhdGlvbnMKLy8g4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ
4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ
4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ
4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQCgovKiogRmV0Y2ggYSBsaXF1aWRhdGlvbi1hZGRyZXNz
IHJvdyBieSBCcmlkZ2UncyBsaXF1aWRhdGlvbl9hZGRyZXNzX2lkLiAqLwpleHBvcnQgYXN5bmMg
ZnVuY3Rpb24gZ2V0TGlxdWlkYXRpb25BZGRyZXNzUm93QnlJZCgKICBsaXF1aWRhdGlvbkFkZHJl
c3NJZDogc3RyaW5nLAopOiBQcm9taXNlPFJhbXBMaXF1aWRhdGlvbkFkZHJlc3NSb3cgfCBudWxs
PiB7CiAgY29uc3Qgcm93cyA9IGF3YWl0IGRiLnJ1bihzcWxgCiAgICBTRUxFQ1QgKiBGUk9NIHJh
bXBfbGlxdWlkYXRpb25fYWRkcmVzc2VzCiAgICAgV0hFUkUgbGlxdWlkYXRpb25fYWRkcmVzc19p
ZCA9ICR7bGlxdWlkYXRpb25BZGRyZXNzSWR9IExJTUlUIDFgKQogIHJldHVybiAocGFyc2VSb3dz
KHJvd3MpWzBdIGFzIFJhbXBMaXF1aWRhdGlvbkFkZHJlc3NSb3cpID8/IG51bGwKfQoKLyoqCiAq
IFVwc2VydCBhIGRyYWluIGV2ZW50IG1pcnJvciByb3cuIE1pcnJvcnMgdXBzZXJ0RGVwb3NpdEV2
ZW50OiBvbmUgcm93IHBlcgogKiAobGlxdWlkYXRpb24gYWRkcmVzcywgZHJhaW4sIHN0YXRlKTsg
YSB3ZWJob29rIGFuZCBhIGxhdGVyIHBvbGwgb2YgdGhlIHNhbWUKICogZXZlbnQgY29sbGFwc2Ug
dmlhIHRoZSBVTklRVUUgY29uc3RyYWludCBpbnN0ZWFkIG9mIGR1cGxpY2F0aW5nLgogKi8KZXhw
b3J0IGFzeW5jIGZ1bmN0aW9uIHVwc2VydERyYWluRXZlbnQocGFyYW1zOiB7CiAgbGlxdWlkYXRp
b25BZGRyZXNzSWQ6IHN0cmluZwogIGRyYWluSWQ6ICAgICAgICAgICAgICBzdHJpbmcgfCBudWxs
CiAgZXZlbnRJZDogICAgICAgICAgICAgIHN0cmluZyB8IG51bGwKICBzdGF0ZTogICAgICAgICAg
ICAgICAgc3RyaW5nIHwgbnVsbAogIGN1cnJlbmN5OiAgICAgICAgICAgICBzdHJpbmcgfCBudWxs
CiAgYW1vdW50OiAgICAgICAgICAgICAgIHN0cmluZyB8IG51bGwKICBkZXBvc2l0VHhIYXNoOiAg
ICAgICAgc3RyaW5nIHwgbnVsbAogIGRlc3RpbmF0aW9uVHhIYXNoOiAgICBzdHJpbmcgfCBudWxs
CiAgc291cmNlOiAgICAgICAgICAgICAgICd3ZWJob29rJyB8ICdwb2xsJwp9KTogUHJvbWlzZTx2
b2lkPiB7CiAgY29uc3Qgbm93ID0gTWF0aC5mbG9vcihEYXRlLm5vdygpIC8gMTAwMCkKICBhd2Fp
dCBkYi5ydW4oc3FsYAogICAgSU5TRVJUIE9SIElHTk9SRSBJTlRPIHJhbXBfZHJhaW5fZXZlbnRz
CiAgICAgIChpZCwgcHJvdmlkZXIsIGxpcXVpZGF0aW9uX2FkZHJlc3NfaWQsIGRyYWluX2lkLCBl
dmVudF9pZCwgc3RhdGUsCiAgICAgICBjdXJyZW5jeSwgYW1vdW50LCBkZXBvc2l0X3R4X2hhc2gs
IGRlc3RpbmF0aW9uX3R4X2hhc2gsIHNvdXJjZSwgY3JlYXRlZF9hdCkKICAgIFZBTFVFUwogICAg
ICAoJHtyYW5kb21VVUlEKCl9LCAnYnJpZGdleHl6JywgJHtwYXJhbXMubGlxdWlkYXRpb25BZGRy
ZXNzSWR9LCAke3BhcmFtcy5kcmFpbklkfSwKICAgICAgICR7cGFyYW1zLmV2ZW50SWR9LCAke3Bh
cmFtcy5zdGF0ZX0sICR7cGFyYW1zLmN1cnJlbmN5fSwgJHtwYXJhbXMuYW1vdW50fSwKICAgICAg
ICR7cGFyYW1zLmRlcG9zaXRUeEhhc2h9LCAke3BhcmFtcy5kZXN0aW5hdGlvblR4SGFzaH0sICR7
cGFyYW1zLnNvdXJjZX0sICR7bm93fSlgKQp9CgpleHBvcnQgaW50ZXJmYWNlIFJhbXBEcmFpbkV2
ZW50Um93IHsKICBpZDogICAgICAgICAgICAgICAgICAgICBzdHJpbmcKICBwcm92aWRlcjogICAg
ICAgICAgICAgICBzdHJpbmcKICBsaXF1aWRhdGlvbl9hZGRyZXNzX2lkOiBzdHJpbmcgfCBudWxs
CiAgZHJhaW5faWQ6ICAgICAgICAgICAgICAgc3RyaW5nIHwgbnVsbAogIGV2ZW50X2lkOiAgICAg
ICAgICAgICAgIHN0cmluZyB8IG51bGwKICBzdGF0ZTogICAgICAgICAgICAgICAgICBzdHJpbmcg
fCBudWxsCiAgY3VycmVuY3k6ICAgICAgICAgICAgICAgc3RyaW5nIHwgbnVsbAogIGFtb3VudDog
ICAgICAgICAgICAgICAgIHN0cmluZyB8IG51bGwKICBkZXBvc2l0X3R4X2hhc2g6ICAgICAgICBz
dHJpbmcgfCBudWxsCiAgZGVzdGluYXRpb25fdHhfaGFzaDogICAgc3RyaW5nIHwgbnVsbAogIHNv
dXJjZTogICAgICAgICAgICAgICAgIHN0cmluZwogIGNyZWF0ZWRfYXQ6ICAgICAgICAgICAgIG51
bWJlcgp9CgovKiogTWlycm9yIHJvd3MgZm9yIGEgbGlxdWlkYXRpb24gYWRkcmVzcywgbmV3ZXN0
IGZpcnN0IChmb3IgdGhlIHRyYWNrZXIgbWVyZ2UpLiAqLwpleHBvcnQgYXN5bmMgZnVuY3Rpb24g
Z2V0RHJhaW5FdmVudHNCeUxpcXVpZGF0aW9uQWRkcmVzcygKICBsaXF1aWRhdGlvbkFkZHJlc3NJ
ZDogc3RyaW5nLAopOiBQcm9taXNlPFJhbXBEcmFpbkV2ZW50Um93W10+IHsKICBjb25zdCByb3dz
ID0gYXdhaXQgZGIucnVuKHNxbGAKICAgIFNFTEVDVCAqIEZST00gcmFtcF9kcmFpbl9ldmVudHMK
ICAgICBXSEVSRSBsaXF1aWRhdGlvbl9hZGRyZXNzX2lkID0gJHtsaXF1aWRhdGlvbkFkZHJlc3NJ
ZH0KICAgICBPUkRFUiBCWSBjcmVhdGVkX2F0IERFU0NgKQogIHJldHVybiBwYXJzZVJvd3Mocm93
cykgYXMgUmFtcERyYWluRXZlbnRSb3dbXQp9CgovKioKICogQXRvbWljYWxseSBjbGFpbSB0aGUg
cmlnaHQgdG8gc2VuZCBPTkUgcGF5b3V0IG5vdGlmaWNhdGlvbiBmb3IKICogKGxpcXVpZGF0aW9u
IGFkZHJlc3MsIGRyYWluLCBraW5kKS4gTWlycm9ycyBjbGFpbURlcG9zaXROb3RpZmljYXRpb24u
CiAqLwpleHBvcnQgYXN5bmMgZnVuY3Rpb24gY2xhaW1EcmFpbk5vdGlmaWNhdGlvbihwYXJhbXM6
IHsKICBsaXF1aWRhdGlvbkFkZHJlc3NJZDogc3RyaW5nIHwgbnVsbAogIGRyYWluSWQ6ICAgICAg
ICAgICAgICBzdHJpbmcgfCBudWxsCiAga2luZDogICAgICAgICAgICAgICAgICdzZW50JyB8ICdw
YWlkJyB8ICdyZXR1cm5lZCcgfCAncmV0dXJuZWRfZmFpbGVkJwp9KTogUHJvbWlzZTxib29sZWFu
PiB7CiAgaWYgKCFwYXJhbXMubGlxdWlkYXRpb25BZGRyZXNzSWQgfHwgIXBhcmFtcy5kcmFpbklk
KSByZXR1cm4gZmFsc2UKICBjb25zdCBleGlzdGluZyA9IGF3YWl0IGRiLnJ1bihzcWxgCiAgICBT
RUxFQ1QgMSBGUk9NIHJhbXBfZHJhaW5fbm90aWZpY2F0aW9ucwogICAgIFdIRVJFIGxpcXVpZGF0
aW9uX2FkZHJlc3NfaWQgPSAke3BhcmFtcy5saXF1aWRhdGlvbkFkZHJlc3NJZH0KICAgICAgIEFO
RCBkcmFpbl9pZCA9ICR7cGFyYW1zLmRyYWluSWR9CiAgICAgICBBTkQga2luZCA9ICR7cGFyYW1z
LmtpbmR9IExJTUlUIDFgKQogIGlmIChwYXJzZVJvd3MoZXhpc3RpbmcpLmxlbmd0aCA+IDApIHJl
dHVybiBmYWxzZQogIGNvbnN0IG5vdyA9IE1hdGguZmxvb3IoRGF0ZS5ub3coKSAvIDEwMDApCiAg
YXdhaXQgZGIucnVuKHNxbGAKICAgIElOU0VSVCBPUiBJR05PUkUgSU5UTyByYW1wX2RyYWluX25v
dGlmaWNhdGlvbnMKICAgICAgKGlkLCBsaXF1aWRhdGlvbl9hZGRyZXNzX2lkLCBkcmFpbl9pZCwg
a2luZCwgc2VudF9hdCkKICAgIFZBTFVFUyAoJHtyYW5kb21VVUlEKCl9LCAke3BhcmFtcy5saXF1
aWRhdGlvbkFkZHJlc3NJZH0sICR7cGFyYW1zLmRyYWluSWR9LCAke3BhcmFtcy5raW5kfSwgJHtu
b3d9KWApCiAgcmV0dXJuIHRydWUKfQo=
B64_repo_append
cat > "$TMP/tmpl_append" <<'B64_tmpl_append'
Ci8vIOKUgOKUgCBPZmYtcmFtcCBwYXlvdXQgZW1haWxzIChQaGFzZSA1IFBhcnQgNCkg4pSA4pSA
4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA
4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSACgovLyBBIHdpdGhkcmF3YWwncyBm
aWF0IHBheW91dCBjb21wbGV0ZWQg4oCUIG1vbmV5IGlzIG9uIGl0cyB3YXkgdG8gLyBhcnJpdmVk
IGF0IHRoZQovLyB1c2VyJ3MgYmFuay4gTWlycm9ycyBkZXBvc2l0TGFuZGVkRW1haWwgYnV0IGZv
ciB0aGUgVVNEQ+KGkmZpYXQgZGlyZWN0aW9uLgpleHBvcnQgZnVuY3Rpb24gcGF5b3V0UGFpZEVt
YWlsKHBhcmFtczogewogIGRpc3BsYXlOYW1lOiAgc3RyaW5nCiAgYW1vdW50OiAgICAgICBzdHJp
bmcgICAgICAgICAgLy8gZmlhdCBhbW91bnQgcGFpZCBvdXQgKG9yIFVTREMgZHJhaW5lZCwgaWYg
dGhhdCdzIGFsbCB3ZSBoYXZlKQogIGN1cnJlbmN5PzogICAgc3RyaW5nICAgICAgICAgIC8vIGRl
c3RpbmF0aW9uIGZpYXQgY3VycmVuY3kKICByYWlsPzogICAgICAgIHN0cmluZyAgICAgICAgICAv
LyBhY2ggfCBzZXBhIHwgc3BlaSB8IHdpcmUKICByZWZlcmVuY2U/OiAgIHN0cmluZyAgICAgICAg
ICAvLyB0cmFjZSAvIElNQUQsIHdoZW4gcHJlc2VudAp9KSB7CiAgY29uc3QgY2N5ICAgICAgICAg
PSAocGFyYW1zLmN1cnJlbmN5ID8/ICcnKS50b1VwcGVyQ2FzZSgpCiAgY29uc3Qgc3ViamVjdCAg
ICAgPSBg4pyFIFlvdXIgd2l0aGRyYXdhbCBpcyBvbiBpdHMgd2F5JHtjY3kgPyBgIOKAlCAke3Bh
cmFtcy5hbW91bnR9ICR7Y2N5fWAgOiAnJ31gCiAgY29uc3QgcHJldmlld1RleHQgPSBgWW91ciB3
aXRoZHJhd2FsIGhhcyBiZWVuIHNlbnQgdG8geW91ciBiYW5rLmAKCiAgY29uc3QgY29udGVudCA9
IGAKPGgxIHN0eWxlPSJtYXJnaW46MCAwIDEycHg7Y29sb3I6JHtTVUNDRVNTX0NPTE9SfTtmb250
LXNpemU6MjJweDtmb250LXdlaWdodDo2MDA7bGluZS1oZWlnaHQ6MS4zOyI+CiAg4pyFIFdpdGhk
cmF3YWwgc2VudCB0byB5b3VyIGJhbmsKPC9oMT4KPHAgc3R5bGU9Im1hcmdpbjowIDAgOHB4O2Nv
bG9yOiR7VEVYVF9TRUNPTkRBUll9O2ZvbnQtc2l6ZToxNHB4O2xpbmUtaGVpZ2h0OjEuNjsiPgog
IEhpICR7cGFyYW1zLmRpc3BsYXlOYW1lfSwKPC9wPgo8cCBzdHlsZT0ibWFyZ2luOjAgMCAxNnB4
O2NvbG9yOiR7VEVYVF9TRUNPTkRBUll9O2ZvbnQtc2l6ZToxNHB4O2xpbmUtaGVpZ2h0OjEuNjsi
PgogIFlvdXIgVVNEQyBoYXMgYmVlbiBjb252ZXJ0ZWQgYW5kIHBhaWQgb3V0IHRvIHlvdXIgbGlu
a2VkIGJhbmsgYWNjb3VudC4gQmFuawogIHBvc3RpbmcgdGltZXMgdmFyeSBieSBuZXR3b3JrLCBz
byBpdCBtYXkgdGFrZSBhIGxpdHRsZSB3aGlsZSB0byBhcHBlYXIuCjwvcD4KCiR7aW5mb0NhcmQo
WwogIHsgbGFiZWw6ICdBbW91bnQnLCAgdmFsdWU6IGNjeSA/IGAke3BhcmFtcy5hbW91bnR9ICR7
Y2N5fWAgOiBgJHtwYXJhbXMuYW1vdW50fWAgfSwKICAuLi4ocGFyYW1zLnJhaWwgPyBbeyBsYWJl
bDogJ01ldGhvZCcsIHZhbHVlOiBwYXJhbXMucmFpbC50b1VwcGVyQ2FzZSgpIH1dIDogW10pLAog
IHsgbGFiZWw6ICdGZWVzJywgICAgdmFsdWU6IGAwLjAwIOKAlCAwJSBhdCBsYXVuY2hgIH0sCiAg
Li4uKHBhcmFtcy5yZWZlcmVuY2UgPyBbeyBsYWJlbDogJ1JlZmVyZW5jZScsIHZhbHVlOiBgPHNw
YW4gc3R5bGU9ImZvbnQtZmFtaWx5Om1vbm9zcGFjZTtmb250LXNpemU6MTJweDsiPiR7cGFyYW1z
LnJlZmVyZW5jZX08L3NwYW4+YCB9XSA6IFtdKSwKXSl9Cgoke2N0YUJ1dHRvbignVmlldyBpbiBO
ZXh1bScsIGAke0FQUF9VUkx9L3JhbXBgKX0KCjxwIHN0eWxlPSJtYXJnaW46MTZweCAwIDA7Y29s
b3I6JHtURVhUX1NFQ09OREFSWX07Zm9udC1zaXplOjEycHg7bGluZS1oZWlnaHQ6MS41OyI+CiAg
VGhhbmtzIGZvciB1c2luZyBOZXh1bS4KPC9wPmAKCiAgcmV0dXJuIHsgc3ViamVjdCwgaHRtbDog
YmFzZUxheW91dChjb250ZW50LCB7IHByZXZpZXdUZXh0IH0pLCBwcmV2aWV3VGV4dCB9Cn0KCi8v
IEEgd2l0aGRyYXdhbCBjb3VsZG4ndCBiZSBkZWxpdmVyZWQgLyB3YXMgcmV0dXJuZWQuIGBmYWls
ZWRgIGRpc3Rpbmd1aXNoZXMgYQovLyBoYXJkIGZhaWx1cmUgbmVlZGluZyBzdXBwb3J0IGZyb20g
YSBub3JtYWwgcmV0dXJuLXRvLXdhbGxldC4KZXhwb3J0IGZ1bmN0aW9uIHBheW91dFJldHVybmVk
RW1haWwocGFyYW1zOiB7CiAgZGlzcGxheU5hbWU6IHN0cmluZwogIGFtb3VudD86ICAgICBzdHJp
bmcKICBjdXJyZW5jeT86ICAgc3RyaW5nCiAgcmVhc29uPzogICAgIHN0cmluZwogIGZhaWxlZDog
ICAgICBib29sZWFuCn0pIHsKICBjb25zdCBjY3kgICAgID0gKHBhcmFtcy5jdXJyZW5jeSA/PyAn
JykudG9VcHBlckNhc2UoKQogIGNvbnN0IHN1YmplY3QgPSBwYXJhbXMuZmFpbGVkCiAgICA/IGDi
mqDvuI8gQWN0aW9uIG5lZWRlZCBvbiB5b3VyIHdpdGhkcmF3YWxgCiAgICA6IGBZb3VyIHdpdGhk
cmF3YWwgd2FzIHJldHVybmVkYAogIGNvbnN0IHByZXZpZXdUZXh0ID0gcGFyYW1zLmZhaWxlZAog
ICAgPyBgV2UgY291bGRu4oCZdCBjb21wbGV0ZSB5b3VyIHdpdGhkcmF3YWwg4oCUIHBsZWFzZSBj
b250YWN0IHN1cHBvcnQuYAogICAgOiBgWW91ciB3aXRoZHJhd2FsIHdhcyByZXR1cm5lZCB0byB5
b3VyIHdhbGxldC5gCgogIGNvbnN0IGhlYWRDb2xvciA9IHBhcmFtcy5mYWlsZWQgPyBEQU5HRVJf
Q09MT1IgOiBXQVJOSU5HX0NPTE9SCiAgY29uc3QgaGVhZFRleHQgID0gcGFyYW1zLmZhaWxlZCA/
ICfimqDvuI8gV2UgbmVlZCB5b3VyIGhlbHAgd2l0aCBhIHdpdGhkcmF3YWwnIDogJ1lvdXIgd2l0
aGRyYXdhbCB3YXMgcmV0dXJuZWQnCgogIGNvbnN0IGJvZHkgPSBwYXJhbXMuZmFpbGVkCiAgICA/
IGBXZSB0cmllZCB0byBwYXkgb3V0IHlvdXIgd2l0aGRyYXdhbCBidXQgaXQgZGlkbuKAmXQgZ28g
dGhyb3VnaCwgYW5kIHRoZSByZXR1cm4gYWxzbyBmYWlsZWQuIFBsZWFzZSByZXBseSB0byB0aGlz
IGVtYWlsIG9yIGNvbnRhY3Qgc3VwcG9ydCBzbyB3ZSBjYW4gbWFrZSBzdXJlIHlvdXIgZnVuZHMg
cmVhY2ggeW91IHNhZmVseS5gCiAgICA6IGBZb3VyIHJlY2VudCB3aXRoZHJhd2FsIGNvdWxkbuKA
mXQgYmUgZGVsaXZlcmVkIHRvIHlvdXIgYmFuaywgc28gdGhlIFVTREMgd2FzIHJldHVybmVkIHRv
IHlvdXIgd2FsbGV0LiBUaGlzIHVzdWFsbHkgaGFwcGVucyB3aGVuIHRoZSBiYW5rIGRldGFpbHMg
ZG9u4oCZdCBtYXRjaCBvciB0aGUgcmVjZWl2aW5nIGJhbmsgcmVqZWN0cyB0aGUgdHJhbnNmZXIu
YAoKICBjb25zdCBjb250ZW50ID0gYAo8aDEgc3R5bGU9Im1hcmdpbjowIDAgMTJweDtjb2xvcjok
e2hlYWRDb2xvcn07Zm9udC1zaXplOjIycHg7Zm9udC13ZWlnaHQ6NjAwO2xpbmUtaGVpZ2h0OjEu
MzsiPgogICR7aGVhZFRleHR9CjwvaDE+CjxwIHN0eWxlPSJtYXJnaW46MCAwIDhweDtjb2xvcjok
e1RFWFRfU0VDT05EQVJZfTtmb250LXNpemU6MTRweDtsaW5lLWhlaWdodDoxLjY7Ij4KICBIaSAk
e3BhcmFtcy5kaXNwbGF5TmFtZX0sCjwvcD4KPHAgc3R5bGU9Im1hcmdpbjowIDAgMTZweDtjb2xv
cjoke1RFWFRfU0VDT05EQVJZfTtmb250LXNpemU6MTRweDtsaW5lLWhlaWdodDoxLjY7Ij4KICAk
e2JvZHl9CjwvcD4KCiR7aW5mb0NhcmQoWwogIC4uLihwYXJhbXMuYW1vdW50ID8gW3sgbGFiZWw6
ICdBbW91bnQnLCB2YWx1ZTogY2N5ID8gYCR7cGFyYW1zLmFtb3VudH0gJHtjY3l9YCA6IGAke3Bh
cmFtcy5hbW91bnR9YCB9XSA6IFtdKSwKICB7IGxhYmVsOiAnU3RhdHVzJywgdmFsdWU6IHBhcmFt
cy5mYWlsZWQgPyAnUmV0dXJuIGZhaWxlZCDigJQgc3VwcG9ydCBub3RpZmllZCcgOiAnUmV0dXJu
ZWQgdG8geW91ciB3YWxsZXQnIH0sCiAgLi4uKHBhcmFtcy5yZWFzb24gPyBbeyBsYWJlbDogJ1Jl
YXNvbicsIHZhbHVlOiBwYXJhbXMucmVhc29uIH1dIDogW10pLApdKX0KCiR7Y3RhQnV0dG9uKHBh
cmFtcy5mYWlsZWQgPyAnQ29udGFjdCBzdXBwb3J0JyA6ICdUcnkgYWdhaW4nLCBwYXJhbXMuZmFp
bGVkID8gYCR7QVBQX1VSTH0vc3VwcG9ydGAgOiBgJHtBUFBfVVJMfS9yYW1wYCl9Cgo8cCBzdHls
ZT0ibWFyZ2luOjE2cHggMCAwO2NvbG9yOiR7VEVYVF9TRUNPTkRBUll9O2ZvbnQtc2l6ZToxMnB4
O2xpbmUtaGVpZ2h0OjEuNTsiPgogIElmIHlvdSBoYXZlIHF1ZXN0aW9ucyBhYm91dCB0aGlzIHdp
dGhkcmF3YWwsIGp1c3QgcmVwbHkg4oCUIHdl4oCZcmUgaGVyZSB0byBoZWxwLgo8L3A+YAoKICBy
ZXR1cm4geyBzdWJqZWN0LCBodG1sOiBiYXNlTGF5b3V0KGNvbnRlbnQsIHsgcHJldmlld1RleHQg
fSksIHByZXZpZXdUZXh0IH0KfQo=
B64_tmpl_append
cat > "$TMP/ensure_block" <<'B64_ensure_block'
CiAgICAvLyBPZmYtcmFtcCBkcmFpbiBtaXJyb3IgKyBwYXlvdXQtbm90aWZpY2F0aW9uIGRlZHVw
IChQaGFzZSA1IFBhcnQgNCkuCiAgICAvLyBTYW1lIHNlbGYtaGVhbCByYXRpb25hbGU6IG1pZ3Jh
dGlvbiAwMDI1J3MgRERMIG1heSBub3QgcnVuIG9uIHByb2QgVHVyc28uCiAgICBhd2FpdCBkYi5y
dW4oc3FsYAogICAgICBDUkVBVEUgVEFCTEUgSUYgTk9UIEVYSVNUUyByYW1wX2RyYWluX2V2ZW50
cyAoCiAgICAgICAgaWQgICAgICAgICAgICAgICAgICAgICBURVhUIFBSSU1BUlkgS0VZLAogICAg
ICAgIHByb3ZpZGVyICAgICAgICAgICAgICAgVEVYVCBOT1QgTlVMTCBERUZBVUxUICdicmlkZ2V4
eXonLAogICAgICAgIGxpcXVpZGF0aW9uX2FkZHJlc3NfaWQgVEVYVCwKICAgICAgICBkcmFpbl9p
ZCAgICAgICAgICAgICAgIFRFWFQsCiAgICAgICAgZXZlbnRfaWQgICAgICAgICAgICAgICBURVhU
LAogICAgICAgIHN0YXRlICAgICAgICAgICAgICAgICAgVEVYVCwKICAgICAgICBjdXJyZW5jeSAg
ICAgICAgICAgICAgIFRFWFQsCiAgICAgICAgYW1vdW50ICAgICAgICAgICAgICAgICBURVhULAog
ICAgICAgIGRlcG9zaXRfdHhfaGFzaCAgICAgICAgVEVYVCwKICAgICAgICBkZXN0aW5hdGlvbl90
eF9oYXNoICAgIFRFWFQsCiAgICAgICAgc291cmNlICAgICAgICAgICAgICAgICBURVhUIE5PVCBO
VUxMIERFRkFVTFQgJ3dlYmhvb2snLAogICAgICAgIGNyZWF0ZWRfYXQgICAgICAgICAgICAgSU5U
RUdFUiBOT1QgTlVMTCwKICAgICAgICBVTklRVUUgKGxpcXVpZGF0aW9uX2FkZHJlc3NfaWQsIGRy
YWluX2lkLCBzdGF0ZSkKICAgICAgKWApCiAgICBhd2FpdCBkYi5ydW4oc3FsYENSRUFURSBJTkRF
WCBJRiBOT1QgRVhJU1RTIGlkeF9yYW1wX2RyYWluX2V2ZW50c19sYSBPTiByYW1wX2RyYWluX2V2
ZW50cyAobGlxdWlkYXRpb25fYWRkcmVzc19pZClgKQogICAgYXdhaXQgZGIucnVuKHNxbGBDUkVB
VEUgSU5ERVggSUYgTk9UIEVYSVNUUyBpZHhfcmFtcF9kcmFpbl9ldmVudHNfZHJhaW4gT04gcmFt
cF9kcmFpbl9ldmVudHMgKGRyYWluX2lkKWApCiAgICBhd2FpdCBkYi5ydW4oc3FsYAogICAgICBD
UkVBVEUgVEFCTEUgSUYgTk9UIEVYSVNUUyByYW1wX2RyYWluX25vdGlmaWNhdGlvbnMgKAogICAg
ICAgIGlkICAgICAgICAgICAgICAgICAgICAgVEVYVCBQUklNQVJZIEtFWSwKICAgICAgICBsaXF1
aWRhdGlvbl9hZGRyZXNzX2lkIFRFWFQsCiAgICAgICAgZHJhaW5faWQgICAgICAgICAgICAgICBU
RVhULAogICAgICAgIGtpbmQgICAgICAgICAgICAgICAgICAgVEVYVCBOT1QgTlVMTCwKICAgICAg
ICBzZW50X2F0ICAgICAgICAgICAgICAgIElOVEVHRVIgTk9UIE5VTEwsCiAgICAgICAgVU5JUVVF
IChsaXF1aWRhdGlvbl9hZGRyZXNzX2lkLCBkcmFpbl9pZCwga2luZCkKICAgICAgKWApCiAgICBh
d2FpdCBkYi5ydW4oc3FsYENSRUFURSBJTkRFWCBJRiBOT1QgRVhJU1RTIGlkeF9yYW1wX2RyYWlu
X25vdGlmaWNhdGlvbnNfZHJhaW4gT04gcmFtcF9kcmFpbl9ub3RpZmljYXRpb25zIChkcmFpbl9p
ZClgKQo=
B64_ensure_block
cat > "$TMP/ensure_anchor" <<'B64_ensure_anchor'
ICAgIGNvbnN0IHJvd3M6IGFueSA9IGF3YWl0IGRiLnJ1bihzcWxgU0VMRUNUIENPVU5UKCopIEFT
IGMgRlJPTSByYW1wX2NvcnJpZG9ycyBXSEVSRSBkaXJlY3Rpb24gPSAnb2ZmcmFtcCdgKQ==
B64_ensure_anchor
cat > "$TMP/tr_imp_old" <<'B64_tr_imp_old'
aW1wb3J0IHsKICB2ZXJpZnlXZWJob29rU2lnbmF0dXJlLCBwYXJzZVdlYmhvb2tFdmVudCwgZXh0
cmFjdEFjdGl2aXR5RGV0YWlsLAogIGJyaWRnZVdlYmhvb2tQdWJsaWNLZXksIGJyaWRnZVdlYmhv
b2tDb25maWd1cmVkLCBXZWJob29rU2lnbmF0dXJlRXJyb3IsCn0gZnJvbSAnLi4vc2VydmljZXMv
YnJpZGdleHl6L3dlYmhvb2tzJwppbXBvcnQgewogIHJlY29yZFdlYmhvb2tFdmVudCwgdXBzZXJ0
RGVwb3NpdEV2ZW50LAp9IGZyb20gJy4uL3NlcnZpY2VzL2JyaWRnZXh5ei9yZXBvc2l0b3J5Jwpp
bXBvcnQgeyBtYXliZVNlbmREZXBvc2l0RW1haWwgfSBmcm9tICcuLi9zZXJ2aWNlcy9icmlkZ2V4
eXovZGVwb3NpdE5vdGlmeScK
B64_tr_imp_old
cat > "$TMP/tr_imp_new" <<'B64_tr_imp_new'
aW1wb3J0IHsKICB2ZXJpZnlXZWJob29rU2lnbmF0dXJlLCBwYXJzZVdlYmhvb2tFdmVudCwgZXh0
cmFjdEFjdGl2aXR5RGV0YWlsLAogIGV4dHJhY3REcmFpbkRldGFpbCwKICBicmlkZ2VXZWJob29r
UHVibGljS2V5LCBicmlkZ2VXZWJob29rQ29uZmlndXJlZCwgV2ViaG9va1NpZ25hdHVyZUVycm9y
LAp9IGZyb20gJy4uL3NlcnZpY2VzL2JyaWRnZXh5ei93ZWJob29rcycKaW1wb3J0IHsKICByZWNv
cmRXZWJob29rRXZlbnQsIHVwc2VydERlcG9zaXRFdmVudCwgdXBzZXJ0RHJhaW5FdmVudCwKfSBm
cm9tICcuLi9zZXJ2aWNlcy9icmlkZ2V4eXovcmVwb3NpdG9yeScKaW1wb3J0IHsgbWF5YmVTZW5k
RGVwb3NpdEVtYWlsIH0gZnJvbSAnLi4vc2VydmljZXMvYnJpZGdleHl6L2RlcG9zaXROb3RpZnkn
CmltcG9ydCB7IG1heWJlU2VuZFBheW91dEVtYWlsIH0gZnJvbSAnLi4vc2VydmljZXMvYnJpZGdl
eHl6L3BheW91dE5vdGlmeScK
B64_tr_imp_new
cat > "$TMP/tr_br_old" <<'B64_tr_br_old'
ICAgICAgLy8gRmlyZSBhIGJyYW5kZWQgZW1haWwgb24gdGVybWluYWwgc3RhdGVzIChsYW5kZWQg
LyByZXR1cm5lZCAvIGZhaWxlZCkuCiAgICAgIC8vIEJlc3QtZWZmb3J0ICsgZGVkdXBlZDsgbmV2
ZXIgYmxvY2tzIHRoZSAyMDAgcmVzcG9uc2UuCiAgICAgIGF3YWl0IG1heWJlU2VuZERlcG9zaXRF
bWFpbChkZXRhaWwpCiAgICB9CgogICAgcmVzLnN0YXR1cygyMDApLmpzb24oeyByZWNlaXZlZDog
dHJ1ZSB9KQo=
B64_tr_br_old
cat > "$TMP/tr_br_new" <<'B64_tr_br_new'
ICAgICAgLy8gRmlyZSBhIGJyYW5kZWQgZW1haWwgb24gdGVybWluYWwgc3RhdGVzIChsYW5kZWQg
LyByZXR1cm5lZCAvIGZhaWxlZCkuCiAgICAgIC8vIEJlc3QtZWZmb3J0ICsgZGVkdXBlZDsgbmV2
ZXIgYmxvY2tzIHRoZSAyMDAgcmVzcG9uc2UuCiAgICAgIGF3YWl0IG1heWJlU2VuZERlcG9zaXRF
bWFpbChkZXRhaWwpCiAgICB9CgogICAgLy8gT2ZmLXJhbXAgKFBoYXNlIDUgUGFydCA0KTogbWly
cm9yIGxpcXVpZGF0aW9uLWFkZHJlc3MgZHJhaW4gZXZlbnRzIGFuZAogICAgLy8gZmlyZSBicmFu
ZGVkIHBheW91dCBlbWFpbHMgb24gdGVybWluYWwgc3RhdGVzLiBTYW1lIHNoYXBlIGFzIGRlcG9z
aXRzLgogICAgY29uc3QgZHJhaW4gPSBleHRyYWN0RHJhaW5EZXRhaWwoZXZlbnQpCiAgICBpZiAo
ZHJhaW4gJiYgZHJhaW4ubGlxdWlkYXRpb25BZGRyZXNzSWQpIHsKICAgICAgYXdhaXQgdXBzZXJ0
RHJhaW5FdmVudCh7CiAgICAgICAgbGlxdWlkYXRpb25BZGRyZXNzSWQ6IGRyYWluLmxpcXVpZGF0
aW9uQWRkcmVzc0lkLAogICAgICAgIGRyYWluSWQ6ICAgICAgICAgICAgICBkcmFpbi5kcmFpbklk
LAogICAgICAgIGV2ZW50SWQ6ICAgICAgICAgICAgICBldmVudC5ldmVudF9pZCwKICAgICAgICBz
dGF0ZTogICAgICAgICAgICAgICAgZHJhaW4uc3RhdGUsCiAgICAgICAgY3VycmVuY3k6ICAgICAg
ICAgICAgIGRyYWluLmN1cnJlbmN5LAogICAgICAgIGFtb3VudDogICAgICAgICAgICAgICBkcmFp
bi5hbW91bnQsCiAgICAgICAgZGVwb3NpdFR4SGFzaDogICAgICAgIGRyYWluLmRlcG9zaXRUeEhh
c2gsCiAgICAgICAgZGVzdGluYXRpb25UeEhhc2g6ICAgIGRyYWluLmRlc3RpbmF0aW9uVHhIYXNo
LAogICAgICAgIHNvdXJjZTogICAgICAgICAgICAgICAnd2ViaG9vaycsCiAgICAgIH0pCiAgICAg
IGF3YWl0IG1heWJlU2VuZFBheW91dEVtYWlsKGRyYWluKQogICAgfQoKICAgIHJlcy5zdGF0dXMo
MjAwKS5qc29uKHsgcmVjZWl2ZWQ6IHRydWUgfSkK
B64_tr_br_new
cat > "$TMP/ramp_imp_old" <<'B64_ramp_imp_old'
ICBnZXRMaXF1aWRhdGlvbkFkZHJlc3Nlc0J5QWNjb3VudCwgZ2V0TGlxdWlkYXRpb25BZGRyZXNz
QnlBY2NvdW50Q3VycmVuY3ksCiAgY3JlYXRlTGlxdWlkYXRpb25BZGRyZXNzUm93LA==
B64_ramp_imp_old
cat > "$TMP/ramp_imp_new" <<'B64_ramp_imp_new'
ICBnZXRMaXF1aWRhdGlvbkFkZHJlc3Nlc0J5QWNjb3VudCwgZ2V0TGlxdWlkYXRpb25BZGRyZXNz
QnlBY2NvdW50Q3VycmVuY3ksCiAgY3JlYXRlTGlxdWlkYXRpb25BZGRyZXNzUm93LCBnZXREcmFp
bkV2ZW50c0J5TGlxdWlkYXRpb25BZGRyZXNzLA==
B64_ramp_imp_new
cat > "$TMP/ramp_dr_old" <<'B64_ramp_dr_old'
ICAgIGxldCBkcmFpbnM6IGFueVtdID0gW10KICAgIGxldCBmYWlsZWQgPSBmYWxzZQogICAgdHJ5
IHsKICAgICAgZHJhaW5zID0gYXdhaXQgZ2V0TGlxdWlkYXRpb25BZGRyZXNzRHJhaW5zKAogICAg
ICAgIGdhdGUuY3VzdG9tZXIuY3VzdG9tZXJfaWQgYXMgc3RyaW5nLCByb3cubGlxdWlkYXRpb25f
YWRkcmVzc19pZCkKICAgIH0gY2F0Y2ggewogICAgICBmYWlsZWQgPSB0cnVlCiAgICB9CgogICAg
cmVzLmpzb24oewogICAgICBjdXJyZW5jeSwKICAgICAgYWRkcmVzczogcm93LmFkZHJlc3MsCiAg
ICAgIGNvdW50OiAgIGRyYWlucy5sZW5ndGgsCiAgICAgIGRyYWlucywKICAgICAgc291cmNlOiAg
ZmFpbGVkID8gJ3VuYXZhaWxhYmxlJyA6ICdicmlkZ2UnLAogICAgfSkK
B64_ramp_dr_old
cat > "$TMP/ramp_dr_new" <<'B64_ramp_dr_new'
ICAgIGxldCBkcmFpbnM6IGFueVtdID0gW10KICAgIGxldCBmYWlsZWQgPSBmYWxzZQogICAgdHJ5
IHsKICAgICAgZHJhaW5zID0gYXdhaXQgZ2V0TGlxdWlkYXRpb25BZGRyZXNzRHJhaW5zKAogICAg
ICAgIGdhdGUuY3VzdG9tZXIuY3VzdG9tZXJfaWQgYXMgc3RyaW5nLCByb3cubGlxdWlkYXRpb25f
YWRkcmVzc19pZCkKICAgIH0gY2F0Y2ggewogICAgICBmYWlsZWQgPSB0cnVlCiAgICB9CgogICAg
Ly8gTWVyZ2UgaW4gd2ViaG9vay1taXJyb3JlZCBkcmFpbiBldmVudHMgKFBoYXNlIDUgUGFydCA0
KS4gVGhlIEJyaWRnZSBwb2xsCiAgICAvLyBzdGF5cyBncm91bmQgdHJ1dGg7IHRoZSBtaXJyb3Ig
ZmlsbHMgZ2FwcyBiZXR3ZWVuIHBvbGxzIGFuZCDigJQgd2hlbiB0aGUKICAgIC8vIHBvbGwgZmFp
bHMg4oCUIHN0aWxsIHN1cmZhY2VzIHRoZSBsYXRlc3Qga25vd24gc3RhdGUuIERlZHVwZSBieSBk
cmFpbiBpZCArCiAgICAvLyBzdGF0ZSwgcHJlZmVycmluZyB0aGUgcG9sbCdzIHJpY2hlciBvYmpl
Y3Qgd2hlbiBib3RoIGV4aXN0LgogICAgbGV0IG1pcnJvcmVkOiBhbnlbXSA9IFtdCiAgICB0cnkg
ewogICAgICBjb25zdCByb3dzID0gYXdhaXQgZ2V0RHJhaW5FdmVudHNCeUxpcXVpZGF0aW9uQWRk
cmVzcyhyb3cubGlxdWlkYXRpb25fYWRkcmVzc19pZCkKICAgICAgbWlycm9yZWQgPSByb3dzLm1h
cChyID0+ICh7CiAgICAgICAgaWQ6ICAgICAgICAgICAgICAgICAgci5kcmFpbl9pZCwKICAgICAg
ICBzdGF0ZTogICAgICAgICAgICAgICByLnN0YXRlLAogICAgICAgIGFtb3VudDogICAgICAgICAg
ICAgIHIuYW1vdW50LAogICAgICAgIGN1cnJlbmN5OiAgICAgICAgICAgIHIuY3VycmVuY3ksCiAg
ICAgICAgZGVwb3NpdF90eF9oYXNoOiAgICAgci5kZXBvc2l0X3R4X2hhc2gsCiAgICAgICAgZGVz
dGluYXRpb25fdHhfaGFzaDogci5kZXN0aW5hdGlvbl90eF9oYXNoLAogICAgICAgIF9zb3VyY2U6
ICAgICAgICAgICAgIHIuc291cmNlLAogICAgICB9KSkKICAgIH0gY2F0Y2ggeyAvKiBtaXJyb3Ig
aXMgYmVzdC1lZmZvcnQgKi8gfQoKICAgIGNvbnN0IHNlZW4gPSBuZXcgU2V0PHN0cmluZz4oKQog
ICAgY29uc3QgbWVyZ2VkOiBhbnlbXSA9IFtdCiAgICBmb3IgKGNvbnN0IGQgb2YgZHJhaW5zKSB7
CiAgICAgIGNvbnN0IGtleSA9IGAke2QuaWQgPz8gJyd9OiR7ZC5zdGF0ZSA/PyAnJ31gCiAgICAg
IHNlZW4uYWRkKGtleSkKICAgICAgbWVyZ2VkLnB1c2goZCkKICAgIH0KICAgIGZvciAoY29uc3Qg
bSBvZiBtaXJyb3JlZCkgewogICAgICBjb25zdCBrZXkgPSBgJHttLmlkID8/ICcnfToke20uc3Rh
dGUgPz8gJyd9YAogICAgICBpZiAoIXNlZW4uaGFzKGtleSkpIHsgc2Vlbi5hZGQoa2V5KTsgbWVy
Z2VkLnB1c2gobSkgfQogICAgfQoKICAgIHJlcy5qc29uKHsKICAgICAgY3VycmVuY3ksCiAgICAg
IGFkZHJlc3M6IHJvdy5hZGRyZXNzLAogICAgICBjb3VudDogICBtZXJnZWQubGVuZ3RoLAogICAg
ICBkcmFpbnM6ICBtZXJnZWQsCiAgICAgIHNvdXJjZTogIGZhaWxlZCA/IChtaXJyb3JlZC5sZW5n
dGggPyAnbWlycm9yJyA6ICd1bmF2YWlsYWJsZScpIDogJ21lcmdlZCcsCiAgICB9KQo=
B64_ramp_dr_new

# ---- 1) NEW migration 0025 --------------------------------------------------
if [ -f "$MIG" ] && grep -q "ramp_drain_events" "$MIG" 2>/dev/null; then
  echo "  0025 migration already present — skipping"
else
  decode_verify "$TMP/mig" "$TMP/mig.sql" "ramp_drain_events"
  mkdir -p "$(dirname "$MIG")"; cp "$TMP/mig.sql" "$MIG"; echo "  wrote $MIG"
fi

# ---- 2) NEW payoutNotify.ts -------------------------------------------------
if grep -q "maybeSendPayoutEmail" "$NOTIFY" 2>/dev/null; then
  echo "  payoutNotify.ts already present — skipping"
else
  decode_verify "$TMP/notify" "$TMP/notify.ts" "maybeSendPayoutEmail"
  cp "$TMP/notify.ts" "$NOTIFY"; echo "  wrote $NOTIFY"
fi

# ---- 3) APPEND extractDrainDetail to webhooks.ts ----------------------------
if grep -q "extractDrainDetail" "$WEBHOOKS" 2>/dev/null; then
  echo "  webhooks.ts already has extractDrainDetail — skipping"
else
  decode_verify "$TMP/wh_append" "$TMP/wh.ts" "extractDrainDetail"
  cp "$WEBHOOKS" "$WEBHOOKS.bak.$STAMP"; cat "$TMP/wh.ts" >> "$WEBHOOKS"
  grep -q "extractDrainDetail" "$WEBHOOKS" || { echo "ERROR: webhooks append verify failed — restoring" >&2; cp "$WEBHOOKS.bak.$STAMP" "$WEBHOOKS"; exit 1; }
  echo "  appended extractDrainDetail to webhooks.ts"
fi

# ---- 4) APPEND drain CRUD to repository.ts ----------------------------------
if grep -q "getDrainEventsByLiquidationAddress" "$REPO" 2>/dev/null; then
  echo "  repository.ts already has drain CRUD — skipping"
else
  decode_verify "$TMP/repo_append" "$TMP/repo.ts" "getDrainEventsByLiquidationAddress"
  cp "$REPO" "$REPO.bak.$STAMP"; cat "$TMP/repo.ts" >> "$REPO"
  grep -q "getDrainEventsByLiquidationAddress" "$REPO" || { echo "ERROR: repo append verify failed — restoring" >&2; cp "$REPO.bak.$STAMP" "$REPO"; exit 1; }
  echo "  appended drain CRUD to repository.ts"
fi

# ---- 5) APPEND payout templates to templates.ts -----------------------------
if grep -q "payoutPaidEmail" "$TEMPLATES" 2>/dev/null; then
  echo "  templates.ts already has payout emails — skipping"
else
  decode_verify "$TMP/tmpl_append" "$TMP/tmpl.ts" "payoutPaidEmail"
  cp "$TEMPLATES" "$TEMPLATES.bak.$STAMP"; cat "$TMP/tmpl.ts" >> "$TEMPLATES"
  grep -q "payoutPaidEmail" "$TEMPLATES" || { echo "ERROR: templates append verify failed — restoring" >&2; cp "$TEMPLATES.bak.$STAMP" "$TEMPLATES"; exit 1; }
  echo "  appended payout templates to templates.ts"
fi

# ---- 6) EDIT transfers.ts: imports + drain branch ---------------------------
anchored_replace "$TRANSFERS" "$TMP/tr_imp_old" "$TMP/tr_imp_new" "maybeSendPayoutEmail"
anchored_replace "$TRANSFERS" "$TMP/tr_br_old"  "$TMP/tr_br_new"  "extractDrainDetail(event)"

# ---- 7) EDIT ramp.ts: repo import + drains merge ----------------------------
anchored_replace "$RAMP" "$TMP/ramp_imp_old" "$TMP/ramp_imp_new" "getDrainEventsByLiquidationAddress"
anchored_replace "$RAMP" "$TMP/ramp_dr_old"  "$TMP/ramp_dr_new"  "mirrored.length ? 'mirror'"

# ---- 8) EDIT ensureOfframp.ts: boot self-heal for the 2 drain tables --------
if [ -f "$ENSURE" ]; then
  if grep -q "ramp_drain_events" "$ENSURE" 2>/dev/null; then
    echo "  ensureOfframp.ts already self-heals drain tables — skipping"
  else
    decode_verify "$TMP/ensure_anchor" "$TMP/ea.txt" ""
    decode_verify "$TMP/ensure_block"  "$TMP/eb.txt" "ramp_drain_events"
    EA="$(cat "$TMP/ea.txt")"
    if grep -qF "$EA" "$ENSURE"; then
      cp "$ENSURE" "$ENSURE.bak.$STAMP"
      ANCHOR="$EA" BLOCKFILE="$TMP/eb.txt" python3 - "$ENSURE" <<'PY'
import os, sys
p=sys.argv[1]; s=open(p).read()
anchor=os.environ['ANCHOR']; block=open(os.environ['BLOCKFILE']).read()
assert s.count(anchor)==1, f"anchor count={s.count(anchor)}"
s=s.replace(anchor, block+"\n"+anchor, 1)
open(p,'w').write(s)
PY
      grep -q "ramp_drain_events" "$ENSURE" || { echo "ERROR: ensure edit verify failed — restoring" >&2; cp "$ENSURE.bak.$STAMP" "$ENSURE"; exit 1; }
      echo "  edited ensureOfframp.ts (boot self-heal for drain tables)"
    else
      echo "  ⚠ ensureOfframp.ts present but anchor not found — drain tables rely on migration 0025 only."
      echo "    (Non-fatal: 0025 creates them; boot self-heal just won't cover them.)"
    fi
  fi
else
  echo "  note: ensureOfframp.ts not found — drain tables rely on migration 0025."
fi

echo ""
echo "Phase 5 Part 4 applied."
echo "Deploy:"
echo "  cd $API && npx tsc --noEmit && npm run build"
echo "  git add -A && git commit -m 'ramp phase 5 part 4: offramp drain webhooks + payout emails' && git push"
echo ""
echo "On a real prod withdrawal, drain webhooks will mirror into ramp_drain_events"
echo "and fire payoutPaid/Returned emails. Sandbox won't drive these (as with deposits)."
