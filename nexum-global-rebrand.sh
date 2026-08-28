#!/usr/bin/env bash
# ============================================================================
# Nexum - global rebrand: metadata + full flag map + remove Market section
#
# THREE changes:
#  1. METADATA - drop "African currencies" PRODUCT framing -> "160+ global
#     currencies" (layout.tsx description + OpenGraph; convert + corridor copy).
#     This is what link unfurls (Discord/X) read. Currency NAMES that legitimately
#     contain "African" (South African Rand, CFA) are left untouched.
#  2. FLAGS - expand CURRENCY_FLAG to every currency the live feed returns (~180
#     ISO 4217 codes), each mapped to its nation's flag; metals/funds/regional
#     unions get sensible symbols. Retyped Record<string,string>. The landing
#     rates already render the global feed - this gives every one a real flag
#     instead of the generic fallback.
#  3. REMOVE MARKET - delete the "Market" nav group (Sidebar + MobileDrawer) and
#     the /rates page. Live rates already live on the landing page, so the
#     dashboard duplicate serves no purpose. The P2P *marketplace* is a separate
#     thing and is NOT touched.
#
# Delivery contract (v2) + full deploy:
#   * patcher base64 + sha256 verified; exact-anchor; aborts clean on drift
#   * idempotent (per-file markers); backs up every touched file incl. the
#     /rates page so --revert fully restores it
#   * gate: rm -rf .next && npx tsc --noEmit && npm run build -> commit + push
#   * --revert restores all files + the /rates page ; --no-deploy applies only
#
# Run from REPO ROOT (folder containing nexum-web/).
#   bash nexum-global-rebrand.sh
#   bash nexum-global-rebrand.sh --no-deploy
#   bash nexum-global-rebrand.sh --revert
# ============================================================================
set -euo pipefail

WEB="nexum-web"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR=".nexum-globalrebrand-backup/${STAMP}"
PATCH_SHA="0fa6d45b0a7ae8777d2b66674503ece8cf21de03c3558fb6291a7a2b6dcb36a3"
COMMIT_MSG="chore: global rebrand - metadata + full currency flag map; remove dashboard Market/rates (dup of landing)"

# Files the patcher touches (for backup/revert).
FILES=(
  "$WEB/app/layout.tsx"
  "$WEB/app/(app)/convert/page.tsx"
  "$WEB/app/(app)/corridor/page.tsx"
  "$WEB/lib/corridor.ts"
  "$WEB/components/layout/Sidebar.tsx"
  "$WEB/components/layout/MobileDrawer.tsx"
)
RATES_PAGE="$WEB/app/(app)/rates/page.tsx"

FLAG="${1:-}"
log(){ printf '  %s\n' "$*"; }
die(){ printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[ -d "$WEB" ] || die "Cannot find $WEB . Run from the repo root."

if [ "$FLAG" = "--revert" ]; then
  LATEST=""
  for d in $(ls -1dt .nexum-globalrebrand-backup/*/ 2>/dev/null); do
    if [ -f "${d}corridor.ts" ]; then LATEST="$d"; break; fi
  done
  [ -n "$LATEST" ] || { log "No backup found; nothing to revert."; exit 0; }
  cp "${LATEST}layout.tsx"       "$WEB/app/layout.tsx"                     && log "Restored layout.tsx"
  cp "${LATEST}convert-page.tsx" "$WEB/app/(app)/convert/page.tsx"         && log "Restored convert/page.tsx"
  cp "${LATEST}corridor-page.tsx" "$WEB/app/(app)/corridor/page.tsx"       && log "Restored corridor/page.tsx"
  cp "${LATEST}corridor.ts"      "$WEB/lib/corridor.ts"                    && log "Restored corridor.ts"
  cp "${LATEST}Sidebar.tsx"      "$WEB/components/layout/Sidebar.tsx"      && log "Restored Sidebar.tsx"
  cp "${LATEST}MobileDrawer.tsx" "$WEB/components/layout/MobileDrawer.tsx" && log "Restored MobileDrawer.tsx"
  if [ -f "${LATEST}rates-page.tsx" ]; then
    mkdir -p "$WEB/app/(app)/rates"
    cp "${LATEST}rates-page.tsx" "$RATES_PAGE" && log "Restored /rates page"
  fi
  log "Reverted global rebrand."
  exit 0
fi

TPATCH="$(mktemp /tmp/globalrebrand.XXXXXX.py)"
trap 'rm -f "$TPATCH"' EXIT
base64 -d > "$TPATCH" <<'B64'
IyEvdXNyL2Jpbi9lbnYgcHl0aG9uMwoiIiIKVGhyZWUgcmVsYXRlZCBjaGFuZ2VzIGZvciB0aGUg
Z2xvYmFsIHJlYnJhbmQ6CiAgMS4gTUVUQURBVEE6IGRyb3AgJ0FmcmljYW4gY3VycmVuY2llcycg
ZnJhbWluZyAtPiBnbG9iYWwsIGV2ZXJ5d2hlcmUgaXQgZnJhbWVzCiAgICAgdGhlIFBST0RVQ1Qg
KGxheW91dC50c3ggT0cvdHdpdHRlci9kZXNjcmlwdGlvbiwgY29udmVydCArIGNvcnJpZG9yIGNv
cHkpLgogICAgIExlZ2l0aW1hdGUgY3VycmVuY3kgTkFNRVMgKFNvdXRoIEFmcmljYW4gUmFuZCBl
dGMuKSBhcmUgbGVmdCB1bnRvdWNoZWQuCiAgMi4gRkxBR1M6IGV4cGFuZCBDVVJSRU5DWV9GTEFH
IHRvIGV2ZXJ5IGN1cnJlbmN5IHRoZSBnbG9iYWwgZmVlZCByZXR1cm5zICh+MTgwKSwKICAgICBl
YWNoIG1hcHBlZCB0byBpdHMgbmF0aW9uJ3MgZmxhZzsgbWV0YWxzL2Z1bmRzL3VuaW9ucyBnZXQg
c2Vuc2libGUgc3ltYm9scy4KICAgICBSZXR5cGVkIFJlY29yZDxzdHJpbmcsc3RyaW5nPiBzbyBh
bGwgY29kZXMgYXJlIGFsbG93ZWQuCiAgMy4gUkVNT1ZFIE1BUktFVDogZGVsZXRlIHRoZSAnTWFy
a2V0JyBuYXYgZ3JvdXAgKFNpZGViYXIgKyBNb2JpbGVEcmF3ZXIpIGFuZCB0aGUKICAgICAvcmF0
ZXMgcGFnZSAtIGxpdmUgcmF0ZXMgYWxyZWFkeSBsaXZlIG9uIHRoZSBsYW5kaW5nIHBhZ2UuIFAy
UCBtYXJrZXRwbGFjZQogICAgIChhIGRpZmZlcmVudCB0aGluZykgaXMgdW50b3VjaGVkLgoKSWRl
bXBvdGVudCB2aWEgcGVyLWZpbGUgbWFya2Vycy4gRXhhY3QtYW5jaG9yOyBhYm9ydHMgb24gZHJp
ZnQuCiIiIgppbXBvcnQgc3lzLCBpbywgb3MKCmRlZiBwYXRjaChwYXRoLCBlZGl0cywgbWFya2Vy
KToKICAgIHNyYyA9IGlvLm9wZW4ocGF0aCwgZW5jb2Rpbmc9InV0Zi04IikucmVhZCgpCiAgICBp
ZiBtYXJrZXIgaW4gc3JjOgogICAgICAgIHByaW50KGYiICB7cGF0aH06IGFscmVhZHkgcGF0Y2hl
ZCAtIHNraXBwaW5nLiIpCiAgICAgICAgcmV0dXJuCiAgICBmb3IgZGVzYywgb2xkLCBuZXcgaW4g
ZWRpdHM6CiAgICAgICAgbiA9IHNyYy5jb3VudChvbGQpCiAgICAgICAgaWYgbiAhPSAxOgogICAg
ICAgICAgICBwcmludChmIkVSUk9SIFt7cGF0aH1dOiBhbmNob3IgJ3tkZXNjfScgbWF0Y2hlZCB7
bn0gdGltZXMgKGV4cGVjdGVkIDEpLiBBYm9ydGluZy4iKQogICAgICAgICAgICBzeXMuZXhpdCgy
KQogICAgICAgIHNyYyA9IHNyYy5yZXBsYWNlKG9sZCwgbmV3KQogICAgIyBFbWJlZCB0aGUgbWFy
a2VyIGFzIGEgdHJhaWxpbmcgY29tbWVudCBzbyBhIHJlLXJ1biBkZXRlY3RzIGl0IGFuZCBza2lw
cy4KICAgIGlmIG5vdCBzcmMucnN0cmlwKCkuZW5kc3dpdGgoZiIvLyB7bWFya2VyfSIpOgogICAg
ICAgIHNyYyA9IHNyYy5yc3RyaXAoKSArIGYiXG4vLyB7bWFya2VyfVxuIgogICAgaW8ub3Blbihw
YXRoLCAidyIsIGVuY29kaW5nPSJ1dGYtOCIpLndyaXRlKHNyYykKICAgIHByaW50KGYiICB7cGF0
aH06IHBhdGNoZWQuIikKCiMgLS0tLS0tLS0tLSAxLiBNRVRBREFUQSAtLS0tLS0tLS0tCnBhdGNo
KCJuZXh1bS13ZWIvYXBwL2xheW91dC50c3giLCBbCiAgICAoIm1ldGEgZGVzY3JpcHRpb24iLAog
ICAgICIgIGRlc2NyaXB0aW9uOiAnQ29udmVydCBiZXR3ZWVuIFVTREMgYW5kIEFmcmljYW4gY3Vy
cmVuY2llcywgc2VuZCBhY3Jvc3MgYm9yZGVycywgYW5kIHRyYWRlIHBlZXItdG8tcGVlciwgc2V0
dGxlZCBvbiB0aGUgQXJjIGJsb2NrY2hhaW4gaW4gc2Vjb25kcy4nLCIsCiAgICAgIiAgZGVzY3Jp
cHRpb246ICdDb252ZXJ0IGJldHdlZW4gVVNEQyBhbmQgMTYwKyBnbG9iYWwgY3VycmVuY2llcywg
c2VuZCBhY3Jvc3MgYm9yZGVycywgYW5kIHRyYWRlIHBlZXItdG8tcGVlciwgc2V0dGxlZCBvbiB0
aGUgQXJjIGJsb2NrY2hhaW4gaW4gc2Vjb25kcy4nLCIpLAogICAgKCJvZyBkZXNjcmlwdGlvbiIs
CiAgICAgIiAgICBkZXNjcmlwdGlvbjogJ0NvbnZlcnQgYmV0d2VlbiBVU0RDIGFuZCBBZnJpY2Fu
IGN1cnJlbmNpZXMsIHNlbmQgYWNyb3NzIGJvcmRlcnMsIGFuZCB0cmFkZSBwZWVyLXRvLXBlZXIs
IHNldHRsZWQgb24gQXJjIGluIHNlY29uZHMuJywiLAogICAgICIgICAgZGVzY3JpcHRpb246ICdD
b252ZXJ0IGJldHdlZW4gVVNEQyBhbmQgMTYwKyBnbG9iYWwgY3VycmVuY2llcywgc2VuZCBhY3Jv
c3MgYm9yZGVycywgYW5kIHRyYWRlIHBlZXItdG8tcGVlciwgc2V0dGxlZCBvbiBBcmMgaW4gc2Vj
b25kcy4nLCIpLApdLCAiX19ORVhVTV9HTE9CQUxfTUVUQV9fIikKCnBhdGNoKCJuZXh1bS13ZWIv
YXBwLyhhcHApL2NvbnZlcnQvcGFnZS50c3giLCBbCiAgICAoImNvbnZlcnQgY29weSIsCiAgICAg
IiAgICAgICAgICBMaXZlIHJhdGVzIGJldHdlZW4gVVNEQyBhbmQgMTMgQWZyaWNhbiBjdXJyZW5j
aWVzLiBUbyByZWNlaXZlIGxvY2FsIiwKICAgICAiICAgICAgICAgIExpdmUgcmF0ZXMgYmV0d2Vl
biBVU0RDIGFuZCAxNjArIGdsb2JhbCBjdXJyZW5jaWVzLiBUbyByZWNlaXZlIGxvY2FsIiksCl0s
ICJfX05FWFVNX0dMT0JBTF9NRVRBX18iKQoKcGF0Y2goIm5leHVtLXdlYi9hcHAvKGFwcCkvY29y
cmlkb3IvcGFnZS50c3giLCBbCiAgICAoImNvcnJpZG9yIGNvcHkiLAogICAgICIgICAgICAgICAg
U2VuZCBiZXR3ZWVuIEFmcmljYW4gY3VycmVuY2llcyBpbiB0d28gc3RlcHMgdmlhIFVTREMuIiwK
ICAgICAiICAgICAgICAgIFNlbmQgYmV0d2VlbiBnbG9iYWwgY3VycmVuY2llcyBpbiB0d28gc3Rl
cHMgdmlhIFVTREMuIiksCl0sICJfX05FWFVNX0dMT0JBTF9NRVRBX18iKQoKIyAtLS0tLS0tLS0t
IDIuIEZMQUdTIC0tLS0tLS0tLS0KRkxBR19CT0RZID0gJycnICBBRUQ6ICAn8J+HpvCfh6onLAog
IEFGTjogICfwn4em8J+HqycsCiAgQUxMOiAgJ/Cfh6bwn4exJywKICBBTUQ6ICAn8J+HpvCfh7In
LAogIEFORzogICfwn4eo8J+HvCcsCiAgQU9BOiAgJ/Cfh6bwn4e0JywKICBBUlM6ICAn8J+HpvCf
h7cnLAogIEFVRDogICfwn4em8J+HuicsCiAgQVdHOiAgJ/Cfh6bwn4e8JywKICBBWk46ICAn8J+H
pvCfh78nLAogIEJBTTogICfwn4en8J+HpicsCiAgQkJEOiAgJ/Cfh6fwn4enJywKICBCRFQ6ICAn
8J+Hp/Cfh6knLAogIEJHTjogICfwn4en8J+HrCcsCiAgQkhEOiAgJ/Cfh6fwn4etJywKICBCSUY6
ICAn8J+Hp/Cfh64nLAogIEJNRDogICfwn4en8J+HsicsCiAgQk5EOiAgJ/Cfh6fwn4ezJywKICBC
T0I6ICAn8J+Hp/Cfh7QnLAogIEJPVjogICfwn4en8J+HtCcsCiAgQlJMOiAgJ/Cfh6fwn4e3JywK
ICBCU0Q6ICAn8J+Hp/Cfh7gnLAogIEJUTjogICfwn4en8J+HuScsCiAgQldQOiAgJ/Cfh6fwn4e8
JywKICBCWU46ICAn8J+Hp/Cfh74nLAogIEJaRDogICfwn4en8J+HvycsCiAgQ0FEOiAgJ/Cfh6jw
n4emJywKICBDREY6ICAn8J+HqPCfh6knLAogIENIRTogICfwn4eo8J+HrScsCiAgQ0hGOiAgJ/Cf
h6jwn4etJywKICBDSFc6ICAn8J+HqPCfh60nLAogIENMRjogICfwn4eo8J+HsScsCiAgQ0xQOiAg
J/Cfh6jwn4exJywKICBDTlk6ICAn8J+HqPCfh7MnLAogIENPUDogICfwn4eo8J+HtCcsCiAgQ09V
OiAgJ/Cfh6jwn4e0JywKICBDUkM6ICAn8J+HqPCfh7cnLAogIENVQzogICfwn4eo8J+HuicsCiAg
Q1VQOiAgJ/Cfh6jwn4e6JywKICBDVkU6ICAn8J+HqPCfh7snLAogIENaSzogICfwn4eo8J+Hvycs
CiAgREpGOiAgJ/Cfh6nwn4evJywKICBES0s6ICAn8J+HqfCfh7AnLAogIERPUDogICfwn4ep8J+H
tCcsCiAgRFpEOiAgJ/Cfh6nwn4e/JywKICBFR1A6ICAn8J+HqvCfh6wnLAogIEVSTjogICfwn4eq
8J+HtycsCiAgRVRCOiAgJ/Cfh6rwn4e5JywKICBFVVI6ICAn8J+HqvCfh7onLAogIEZKRDogICfw
n4er8J+HrycsCiAgRktQOiAgJ/Cfh6vwn4ewJywKICBHQlA6ICAn8J+HrPCfh6cnLAogIEdFTDog
ICfwn4es8J+HqicsCiAgR0hTOiAgJ/Cfh6zwn4etJywKICBHSVA6ICAn8J+HrPCfh64nLAogIEdN
RDogICfwn4es8J+HsicsCiAgR05GOiAgJ/Cfh6zwn4ezJywKICBHVFE6ICAn8J+HrPCfh7knLAog
IEdZRDogICfwn4es8J+HvicsCiAgSEtEOiAgJ/Cfh63wn4ewJywKICBITkw6ICAn8J+HrfCfh7Mn
LAogIEhURzogICfwn4et8J+HuScsCiAgSFVGOiAgJ/Cfh63wn4e6JywKICBJRFI6ICAn8J+HrvCf
h6knLAogIElMUzogICfwn4eu8J+HsScsCiAgSU5SOiAgJ/Cfh67wn4ezJywKICBJUUQ6ICAn8J+H
rvCfh7YnLAogIElSUjogICfwn4eu8J+HtycsCiAgSVNLOiAgJ/Cfh67wn4e4JywKICBKTUQ6ICAn
8J+Hr/Cfh7InLAogIEpPRDogICfwn4ev8J+HtCcsCiAgSlBZOiAgJ/Cfh6/wn4e1JywKICBLRVM6
ICAn8J+HsPCfh6onLAogIEtHUzogICfwn4ew8J+HrCcsCiAgS0hSOiAgJ/Cfh7Dwn4etJywKICBL
TUY6ICAn8J+HsPCfh7InLAogIEtQVzogICfwn4ew8J+HtScsCiAgS1JXOiAgJ/Cfh7Dwn4e3JywK
ICBLV0Q6ICAn8J+HsPCfh7wnLAogIEtZRDogICfwn4ew8J+HvicsCiAgS1pUOiAgJ/Cfh7Dwn4e/
JywKICBMQUs6ICAn8J+HsfCfh6YnLAogIExCUDogICfwn4ex8J+HpycsCiAgTEtSOiAgJ/Cfh7Hw
n4ewJywKICBMUkQ6ICAn8J+HsfCfh7cnLAogIExTTDogICfwn4ex8J+HuCcsCiAgTFlEOiAgJ/Cf
h7Hwn4e+JywKICBNQUQ6ICAn8J+HsvCfh6YnLAogIE1ETDogICfwn4ey8J+HqScsCiAgTUdBOiAg
J/Cfh7Lwn4esJywKICBNS0Q6ICAn8J+HsvCfh7AnLAogIE1NSzogICfwn4ey8J+HsicsCiAgTU5U
OiAgJ/Cfh7Lwn4ezJywKICBNT1A6ICAn8J+HsvCfh7QnLAogIE1SVTogICfwn4ey8J+HtycsCiAg
TVVSOiAgJ/Cfh7Lwn4e6JywKICBNVlI6ICAn8J+HsvCfh7snLAogIE1XSzogICfwn4ey8J+HvCcs
CiAgTVhOOiAgJ/Cfh7Lwn4e9JywKICBNWFY6ICAn8J+HsvCfh70nLAogIE1ZUjogICfwn4ey8J+H
vicsCiAgTVpOOiAgJ/Cfh7Lwn4e/JywKICBOQUQ6ICAn8J+Hs/Cfh6YnLAogIE5HTjogICfwn4ez
8J+HrCcsCiAgTklPOiAgJ/Cfh7Pwn4euJywKICBOT0s6ICAn8J+Hs/Cfh7QnLAogIE5QUjogICfw
n4ez8J+HtScsCiAgTlpEOiAgJ/Cfh7Pwn4e/JywKICBPTVI6ICAn8J+HtPCfh7InLAogIFBBQjog
ICfwn4e18J+HpicsCiAgUEVOOiAgJ/Cfh7Xwn4eqJywKICBQR0s6ICAn8J+HtfCfh6wnLAogIFBI
UDogICfwn4e18J+HrScsCiAgUEtSOiAgJ/Cfh7Xwn4ewJywKICBQTE46ICAn8J+HtfCfh7EnLAog
IFBZRzogICfwn4e18J+HvicsCiAgUUFSOiAgJ/Cfh7bwn4emJywKICBST046ICAn8J+Ht/Cfh7Qn
LAogIFJTRDogICfwn4e38J+HuCcsCiAgUlVCOiAgJ/Cfh7fwn4e6JywKICBSV0Y6ICAn8J+Ht/Cf
h7wnLAogIFNBUjogICfwn4e48J+HpicsCiAgU0JEOiAgJ/Cfh7jwn4enJywKICBTQ1I6ICAn8J+H
uPCfh6gnLAogIFNERzogICfwn4e48J+HqScsCiAgU0VLOiAgJ/Cfh7jwn4eqJywKICBTR0Q6ICAn
8J+HuPCfh6wnLAogIFNIUDogICfwn4e48J+HrScsCiAgU0xFOiAgJ/Cfh7jwn4exJywKICBTT1M6
ICAn8J+HuPCfh7QnLAogIFNSRDogICfwn4e48J+HtycsCiAgU1NQOiAgJ/Cfh7jwn4e4JywKICBT
VE46ICAn8J+HuPCfh7knLAogIFNWQzogICfwn4e48J+HuycsCiAgU1lQOiAgJ/Cfh7jwn4e+JywK
ICBTWkw6ICAn8J+HuPCfh78nLAogIFRIQjogICfwn4e58J+HrScsCiAgVEpTOiAgJ/Cfh7nwn4ev
JywKICBUTVQ6ICAn8J+HufCfh7InLAogIFRORDogICfwn4e58J+HsycsCiAgVE9QOiAgJ/Cfh7nw
n4e0JywKICBUUlk6ICAn8J+HufCfh7cnLAogIFRURDogICfwn4e58J+HuScsCiAgVFdEOiAgJ/Cf
h7nwn4e8JywKICBUWlM6ICAn8J+HufCfh78nLAogIFVBSDogICfwn4e68J+HpicsCiAgVUdYOiAg
J/Cfh7rwn4esJywKICBVU046ICAn8J+HuvCfh7gnLAogIFVZSTogICfwn4e68J+HvicsCiAgVVlV
OiAgJ/Cfh7rwn4e+JywKICBVWVc6ICAn8J+HuvCfh74nLAogIFVaUzogICfwn4e68J+HvycsCiAg
VkVEOiAgJ/Cfh7vwn4eqJywKICBWRVM6ICAn8J+Hu/Cfh6onLAogIFZORDogICfwn4e78J+Hsycs
CiAgVlVWOiAgJ/Cfh7vwn4e6JywKICBXU1Q6ICAn8J+HvPCfh7gnLAogIFhBRjogICfwn4yNJywK
ICBYQUc6ICAn8J+liCcsCiAgWEFVOiAgJ/CfpYcnLAogIFhCQTogICfwn5KxJywKICBYQkI6ICAn
8J+SsScsCiAgWEJDOiAgJ/CfkrEnLAogIFhCRDogICfwn5KxJywKICBYQ0Q6ICAn8J+HpvCfh6wn
LAogIFhEUjogICfwn4yQJywKICBYT0Y6ICAn8J+MjScsCiAgWFBEOiAgJ+KaqicsCiAgWFBGOiAg
J/CfjI0nLAogIFhQVDogICfimqonLAogIFhTVTogICfwn4yNJywKICBYVFM6ICAn8J+SsScsCiAg
WFVBOiAgJ/CfjI0nLAogIFhYWDogICfwn5KxJywKICBZRVI6ICAn8J+HvvCfh6onLAogIFpBUjog
ICfwn4e/8J+HpicsCiAgWk1XOiAgJ/Cfh7/wn4eyJywKICBaV0c6ICAn8J+Hv/Cfh7wnLAogIFVT
REM6ICfwn5K1JywKICBFVVJDOiAn8J+HqvCfh7onLAogIFVTRDogICfwn4e68J+HuCcsJycnCmZs
YWdzX29sZF9zdGFydCA9ICJleHBvcnQgY29uc3QgQ1VSUkVOQ1lfRkxBRzogUmVjb3JkPEN1cnJl
bmN5LCBzdHJpbmc+ID0geyIKd2ViX2NvcnIgPSAibmV4dW0td2ViL2xpYi9jb3JyaWRvci50cyIK
c3JjID0gaW8ub3Blbih3ZWJfY29yciwgZW5jb2Rpbmc9InV0Zi04IikucmVhZCgpCmlmICJfX05F
WFVNX0dMT0JBTF9GTEFHU19fIiBpbiBzcmM6CiAgICBwcmludChmIiAge3dlYl9jb3JyfTogZmxh
Z3MgYWxyZWFkeSBwYXRjaGVkIC0gc2tpcHBpbmcuIikKZWxzZToKICAgIGltcG9ydCByZQogICAg
IyBSZXBsYWNlIHRoZSBlbnRpcmUgQ1VSUkVOQ1lfRkxBRyBvYmplY3QgKGZyb20gdGhlIGRlY2xh
cmF0aW9uIHRvIGl0cyBjbG9zaW5nIGJyYWNlKS4KICAgIHN0YXJ0ID0gc3JjLmluZGV4KGZsYWdz
X29sZF9zdGFydCkKICAgIGVuZCA9IHNyYy5pbmRleCgiXG59Iiwgc3RhcnQpICsgMgogICAgbmV3
X2Jsb2NrID0gKCIvLyBfX05FWFVNX0dMT0JBTF9GTEFHU19fIGV2ZXJ5IGN1cnJlbmN5IHRoZSBn
bG9iYWwgZmVlZCByZXR1cm5zLCBtYXBwZWQgdG8gaXRzXG4iCiAgICAgICAgICAgICAgICAgIi8v
IG5hdGlvbidzIGZsYWc7IG1ldGFscy9mdW5kcy9yZWdpb25hbCB1bmlvbnMgdXNlIGEgc2Vuc2li
bGUgc3ltYm9sLiBUeXBlZFxuIgogICAgICAgICAgICAgICAgICIvLyBSZWNvcmQ8c3RyaW5nLHN0
cmluZz4gYmVjYXVzZSB0aGUgbGl2ZSBmZWVkIHNwYW5zIH4xNjAgSVNPIDQyMTcgY29kZXMsXG4i
CiAgICAgICAgICAgICAgICAgIi8vIGJleW9uZCB0aGUgbmFycm93IEN1cnJlbmN5IHVuaW9uIHVz
ZWQgZWxzZXdoZXJlLlxuIgogICAgICAgICAgICAgICAgICJleHBvcnQgY29uc3QgQ1VSUkVOQ1lf
RkxBRzogUmVjb3JkPHN0cmluZywgc3RyaW5nPiA9IHtcbiIKICAgICAgICAgICAgICAgICArIEZM
QUdfQk9EWSArICJcbn0iKQogICAgc3JjID0gc3JjWzpzdGFydF0gKyBuZXdfYmxvY2sgKyBzcmNb
ZW5kOl0KICAgIGlvLm9wZW4od2ViX2NvcnIsICJ3IiwgZW5jb2Rpbmc9InV0Zi04Iikud3JpdGUo
c3JjKQogICAgcHJpbnQoZiIgIHt3ZWJfY29ycn06IGZsYWdzIHBhdGNoZWQgKGdsb2JhbCBtYXAp
LiIpCgojIC0tLS0tLS0tLS0gMy4gUkVNT1ZFIE1BUktFVCAtLS0tLS0tLS0tCm1hcmtldF9ncm91
cCA9ICgiICB7IGxhYmVsOiAnTWFya2V0JywgaXRlbXM6IFtcbiIKICAgICAgICAgICAgICAgICIg
ICAgeyBocmVmOiAnL3JhdGVzJywgaWNvbjogVHJlbmRpbmdVcCwgbGFiZWw6ICdMaXZlIHJhdGVz
JyB9LFxuIgogICAgICAgICAgICAgICAgIiAgXX0sXG4iKQpmb3IgbmF2ZmlsZSBpbiBbIm5leHVt
LXdlYi9jb21wb25lbnRzL2xheW91dC9TaWRlYmFyLnRzeCIsCiAgICAgICAgICAgICAgICAibmV4
dW0td2ViL2NvbXBvbmVudHMvbGF5b3V0L01vYmlsZURyYXdlci50c3giXToKICAgIHMgPSBpby5v
cGVuKG5hdmZpbGUsIGVuY29kaW5nPSJ1dGYtOCIpLnJlYWQoKQogICAgaWYgIl9fTkVYVU1fTUFS
S0VUX1JFTU9WRURfXyIgaW4gczoKICAgICAgICBwcmludChmIiAge25hdmZpbGV9OiBtYXJrZXQg
Z3JvdXAgYWxyZWFkeSByZW1vdmVkIC0gc2tpcHBpbmcuIikKICAgICAgICBjb250aW51ZQogICAg
aWYgcy5jb3VudChtYXJrZXRfZ3JvdXApICE9IDE6CiAgICAgICAgcHJpbnQoZiJFUlJPUiBbe25h
dmZpbGV9XTogTWFya2V0IGdyb3VwIGFuY2hvciBtYXRjaGVkIHtzLmNvdW50KG1hcmtldF9ncm91
cCl9IHRpbWVzIChleHBlY3RlZCAxKS4gQWJvcnRpbmcuIikKICAgICAgICBzeXMuZXhpdCgyKQog
ICAgcyA9IHMucmVwbGFjZShtYXJrZXRfZ3JvdXAsICIgIC8vIF9fTkVYVU1fTUFSS0VUX1JFTU9W
RURfXyBNYXJrZXQgbmF2IGdyb3VwIHJlbW92ZWQ7IGxpdmUgcmF0ZXMgbGl2ZSBvbiB0aGUgbGFu
ZGluZyBwYWdlLlxuIikKICAgICMgVHJlbmRpbmdVcCB3YXMgb25seSB1c2VkIGJ5IHRoZSByZW1v
dmVkICdMaXZlIHJhdGVzJyBpdGVtOyBkcm9wIHRoZSBub3ctdW51c2VkIGltcG9ydC4KICAgIHMg
PSBzLnJlcGxhY2UoIiAgVHJlbmRpbmdVcCwgR2xvYmUsIFN0b3JlLCBDbGlwYm9hcmRMaXN0LCBV
c2VyLFxuIiwKICAgICAgICAgICAgICAgICAgIiAgR2xvYmUsIFN0b3JlLCBDbGlwYm9hcmRMaXN0
LCBVc2VyLFxuIikKICAgIGlvLm9wZW4obmF2ZmlsZSwgInciLCBlbmNvZGluZz0idXRmLTgiKS53
cml0ZShzKQogICAgcHJpbnQoZiIgIHtuYXZmaWxlfTogbWFya2V0IGdyb3VwIHJlbW92ZWQuIikK
CiMgUmVtb3ZlIHRoZSAvcmF0ZXMgcGFnZSAod2hvbGUgZmlsZSkuIExlYXZlIGEgbm90ZSBpZiBh
bHJlYWR5IGdvbmUuCnJhdGVzX3BhZ2UgPSAibmV4dW0td2ViL2FwcC8oYXBwKS9yYXRlcy9wYWdl
LnRzeCIKaWYgb3MucGF0aC5leGlzdHMocmF0ZXNfcGFnZSk6CiAgICBvcy5yZW1vdmUocmF0ZXNf
cGFnZSkKICAgICMgcmVtb3ZlIHRoZSBub3ctZW1wdHkgZGlyIGlmIGVtcHR5CiAgICBkID0gb3Mu
cGF0aC5kaXJuYW1lKHJhdGVzX3BhZ2UpCiAgICB0cnk6CiAgICAgICAgb3Mucm1kaXIoZCkKICAg
IGV4Y2VwdCBPU0Vycm9yOgogICAgICAgIHBhc3MKICAgIHByaW50KGYiICB7cmF0ZXNfcGFnZX06
IHJlbW92ZWQuIikKZWxzZToKICAgIHByaW50KGYiICB7cmF0ZXNfcGFnZX06IGFscmVhZHkgYWJz
ZW50LiIpCgpwcmludCgiR2xvYmFsLXJlYnJhbmQgcGF0Y2ggY29tcGxldGUuIikK
B64
ACTUAL="$( (sha256sum "$TPATCH" 2>/dev/null || shasum -a 256 "$TPATCH") | awk '{print $1}')"
[ "$ACTUAL" = "$PATCH_SHA" ] || die "Patcher checksum mismatch (got $ACTUAL). Nothing changed."
log "Patcher verified."

# Back up touched files ONCE, before the first patch. Guard on the markers so an
# idempotent re-run can't overwrite the clean backup with already-patched files.
if grep -qF "__NEXUM_GLOBAL_META__" "$WEB/app/layout.tsx" 2>/dev/null \
   && grep -qF "__NEXUM_GLOBAL_FLAGS__" "$WEB/lib/corridor.ts" 2>/dev/null; then
  log "Already applied (markers present) - skipping backup + patch."
  ALREADY_APPLIED=1
else
  ALREADY_APPLIED=0
  mkdir -p "$BACKUP_DIR"
  cp "$WEB/app/layout.tsx"                     "$BACKUP_DIR/layout.tsx"
  cp "$WEB/app/(app)/convert/page.tsx"         "$BACKUP_DIR/convert-page.tsx"
  cp "$WEB/app/(app)/corridor/page.tsx"        "$BACKUP_DIR/corridor-page.tsx"
  cp "$WEB/lib/corridor.ts"                    "$BACKUP_DIR/corridor.ts"
  cp "$WEB/components/layout/Sidebar.tsx"      "$BACKUP_DIR/Sidebar.tsx"
  cp "$WEB/components/layout/MobileDrawer.tsx" "$BACKUP_DIR/MobileDrawer.tsx"
  [ -f "$RATES_PAGE" ] && cp "$RATES_PAGE" "$BACKUP_DIR/rates-page.tsx" || true
fi

if [ "$ALREADY_APPLIED" = "1" ]; then
  log "Nothing to patch."
elif ! python3 "$TPATCH"; then
  log "Patch failed - restoring from backup..."
  cp "$BACKUP_DIR/layout.tsx"       "$WEB/app/layout.tsx"
  cp "$BACKUP_DIR/convert-page.tsx" "$WEB/app/(app)/convert/page.tsx"
  cp "$BACKUP_DIR/corridor-page.tsx" "$WEB/app/(app)/corridor/page.tsx"
  cp "$BACKUP_DIR/corridor.ts"      "$WEB/lib/corridor.ts"
  cp "$BACKUP_DIR/Sidebar.tsx"      "$WEB/components/layout/Sidebar.tsx"
  cp "$BACKUP_DIR/MobileDrawer.tsx" "$WEB/components/layout/MobileDrawer.tsx"
  [ -f "$BACKUP_DIR/rates-page.tsx" ] && { mkdir -p "$WEB/app/(app)/rates"; cp "$BACKUP_DIR/rates-page.tsx" "$RATES_PAGE"; }
  die "Patch failed; all files restored."
fi

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
log "Pushed. Metadata now reads global; every live-rate currency shows its flag;"
log "the dashboard Market/rates section is gone (landing page keeps live rates)."
log "NOTE: link unfurls (Discord/X) cache aggressively - the old 'African' embed"
log "may persist until their cache refreshes; the site metadata itself is updated."
