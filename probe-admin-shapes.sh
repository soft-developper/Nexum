#!/usr/bin/env bash
# Read-only — prints the admin shapes the Ramps page must slot against. No changes.
set -euo pipefail
API=nexum-api/src
WEB=nexum-web
echo "════════ 1) admin permissions enum ════════"
grep -rn "VIEW_ANALYTICS\|VIEW_DASHBOARD\|MANAGE_\|VIEW_AUDIT\|VIEW_DISPUTES\|export enum\|export const PERMISSIONS\|Permission" $API/services/adminAuth.ts $API/lib/permissions.ts 2>/dev/null | head -30
echo ""
echo "════════ 2) how admin routes are registered + guarded (adminManage or admin) ════════"
ls $API/routes/ | grep -i admin
grep -n "requirePermission\|requireAdmin\|router\." $API/routes/adminManage.ts 2>/dev/null | head -20
echo ""
echo "════════ 3) an example admin GET handler (overview) — for the response pattern ════════"
sed -n '1,45p' $API/routes/adminManage.ts
echo ""
echo "════════ 4) how volume is aggregated today (USD normalization) ════════"
grep -n "usd\|rate\|volume\|SUM\|fx_rates\|toUsd\|normaliz" $API/routes/adminManage.ts 2>/dev/null | head -20
echo ""
echo "════════ 5) admin frontend: pages + nav ════════"
find $WEB/app -path "*admin*" -name "*.tsx" | head -20
echo "--- admin nav/sidebar ---"
grep -rn "admin/" $WEB/components/*.tsx $WEB/app/\(admin\)/**/*.tsx 2>/dev/null | grep -iE "href|nav|link" | head -20
echo ""
echo "════════ 6) admin API client (how the web calls admin endpoints) ════════"
grep -rn "adminFetch\|/admin/\|useAdmin" $WEB/hooks/*.ts $WEB/lib/*.ts 2>/dev/null | head -15
echo ""
echo "════════ 7) ramp tables that exist (for aggregation) ════════"
ls nexum-api/migrations/ | grep -i ramp
echo ""
echo "════════ 8) an existing admin PAGE component (to mirror structure/styling) ════════"
F=$(find $WEB/app -path "*admin*" -name "page.tsx" | head -1)
echo "-- $F (first 40 lines) --"
sed -n '1,40p' "$F"
echo "DONE"
