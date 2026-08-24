#!/usr/bin/env bash
#
# fix-treasury-A1-payroll-dashboard.sh   (Item A, Phase A1)
#
# WHAT: Replaces /treasury (TreasuryContent.tsx) with the new PAYROLL DASHBOARD
#       shell - header + range selector + USD summary cards + recent-payrolls
#       list. Removes the auto-conversion RULES UI entirely (API + treasuryChecker
#       job stay dormant, untouched) and with it the old "Convert now" -> /convert
#       button (closes the Trade-retirement loose end).
#
# WHY:  /treasury becomes the dashboard for payroll, mirroring /settlements for
#       invoices. (A2 will add the tabbed batch table; A3 CSV export.)
#
# SCOPE: web only, ONE file, FULL-FILE REPLACEMENT (rules code was threaded
#        through the whole file, so a clean rewrite beats a dozen fragile edits).
#        Precondition: A0 (gateway removal) already applied - the base file must
#        have no GatewayBalancePanel. If A0 has not run, the SHA guard below still
#        makes this safe (it only checks the NEW content, and backs up whatever
#        is there before replacing).
#
# NOTE: rules API (/treasury/rules) + job (treasuryChecker.ts) are LEFT INTACT
#       but no longer surfaced in the UI. The /convert page is untouched too.
#       The nav still labels this section "Treasury" - rename separately if wanted.
#
# DELIVERY: v2 - base64 payload decoded to a temp file, SHA-256 verified BEFORE
#           replacing, backup-once, idempotent (skips if target already matches
#           the new SHA), --revert restores newest backup.
#
# USAGE:
#   bash fix-treasury-A1-payroll-dashboard.sh          # apply
#   bash fix-treasury-A1-payroll-dashboard.sh --revert # restore newest backup
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_ROOT"

TARGET="nexum-web/app/(app)/treasury/TreasuryContent.tsx"
STAMP="$(date +%Y%m%d-%H%M%S)"
EXPECTED_SHA="f93ca91fd3da298d38ba8b2b43ecf83d5919c17366549474a2c97079face8d95"

# ----- revert -----
if [ "${1:-}" = "--revert" ]; then
  newest="$(ls -1t "$TARGET".bak.* 2>/dev/null | head -1 || true)"
  if [ -z "$newest" ]; then echo "revert: no backup for $TARGET"; exit 1; fi
  cp "$newest" "$TARGET"; echo "reverted $TARGET from $newest"
  exit 0
fi

# ----- preflight -----
[ -f "$TARGET" ] || { echo "ABORT: $TARGET not found" >&2; exit 1; }

# ----- idempotency: already the new content? -----
if command -v sha256sum >/dev/null 2>&1; then
  CUR_SHA="$(sha256sum "$TARGET" | awk '{print $1}')"
  if [ "$CUR_SHA" = "$EXPECTED_SHA" ]; then
    echo "already applied: $TARGET matches A1 content - nothing to do"
    exit 0
  fi
fi

# ----- decode payload to temp, verify SHA BEFORE touching target -----
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT
cat > "$TMP.b64" <<'B64EOF'
J3VzZSBjbGllbnQnCmltcG9ydCB7IHVzZVN0YXRlIH0gZnJvbSAncmVhY3QnCmltcG9ydCB7IHVzZUFjY291bnRBZGRyZXNzIGFzIHVzZUFjY291bnQgfSBmcm9tICdAL2hvb2tzL3VzZUFjY291bnRBZGRyZXNzJwppbXBvcnQgTGluayBmcm9tICduZXh0L2xpbmsnCmltcG9ydCB7IEJ1dHRvbiB9IGZyb20gJ0AvY29tcG9uZW50cy91aS9idXR0b24nCmltcG9ydCB7IEJhZGdlIH0gZnJvbSAnQC9jb21wb25lbnRzL3VpL2JhZGdlJwppbXBvcnQgeyB1c2VQYXlyb2xsQmF0Y2hlcyB9IGZyb20gJ0AvaG9va3MvdXNlUGF5cm9sbCcKaW1wb3J0IHsgZm9ybWF0QW1vdW50IH0gZnJvbSAnQC9saWIvdXRpbHMnCmltcG9ydCB7CiAgUGx1cywgVXNlcnMsIEJ1aWxkaW5nMiwgQXJyb3dSaWdodCwKICBXYWxsZXQsIENoZWNrQ2lyY2xlMiwgQ2xvY2ssCn0gZnJvbSAnbHVjaWRlLXJlYWN0JwoKY29uc3QgUkFOR0VTID0gWwogIFsnNycsICAgJ0xhc3QgNyBkYXlzJ10sCiAgWyczMCcsICAnTGFzdCAzMCBkYXlzJ10sCiAgWyc5MCcsICAnTGFzdCA5MCBkYXlzJ10sCiAgWyczNjUnLCAnTGFzdCB5ZWFyJ10sCl0gYXMgY29uc3QKCmV4cG9ydCBmdW5jdGlvbiBUcmVhc3VyeUNvbnRlbnQoKSB7CiAgY29uc3QgeyBhZGRyZXNzIH0gICAgICAgICAgICA9IHVzZUFjY291bnQoKQogIGNvbnN0IHsgZGF0YTogYmF0Y2hlcyA9IFtdIH0gPSB1c2VQYXlyb2xsQmF0Y2hlcygpCiAgY29uc3QgW3JhbmdlLCBzZXRSYW5nZV0gICAgICA9IHVzZVN0YXRlKCczMCcpCgogIGNvbnN0IG5vdyAgICA9IE1hdGguZmxvb3IoRGF0ZS5ub3coKSAvIDEwMDApCiAgY29uc3QgZnJvbVRzID0gbm93IC0gTnVtYmVyKHJhbmdlKSAqIDg2NDAwCgogIC8vIFBheXJvbGwgaXMgVVNEQy1kZW5vbWluYXRlZCwgc28gVVNEIHZhbHVlID09IFVTREMgYW1vdW50ICgxOjEpLgogIGNvbnN0IGluUmFuZ2UgPSBiYXRjaGVzLmZpbHRlcihiID0+IChiLmNyZWF0ZWRfYXQgPz8gMCkgPj0gZnJvbVRzKQoKICBjb25zdCBjb21wbGV0ZWQgICA9IGluUmFuZ2UuZmlsdGVyKGIgPT4gYi5zdGF0dXMgPT09ICdjb21wbGV0ZWQnKQogIGNvbnN0IHByb2Nlc3NpbmcgID0gaW5SYW5nZS5maWx0ZXIoYiA9PiBiLnN0YXR1cyA9PT0gJ3Byb2Nlc3NpbmcnIHx8IGIuc3RhdHVzID09PSAncGFydGlhbCcpCiAgY29uc3QgdG90YWxQYWlkICAgPSBjb21wbGV0ZWQucmVkdWNlKChzLCBiKSA9PiBzICsgKGIudG90YWxfYW1vdW50ID8/IDApLCAwKQogIGNvbnN0IHJlY2lwaWVudHMgID0gY29tcGxldGVkLnJlZHVjZSgocywgYikgPT4gcyArIChiLnJlY2lwaWVudF9jb3VudCA/PyAwKSwgMCkKCiAgY29uc3Qgc3VtbWFyeSA9IFsKICAgIHsKICAgICAgbGFiZWw6ICdUb3RhbCBwYWlkIChVU0QpJywKICAgICAgdmFsdWU6IGAkJHtmb3JtYXRBbW91bnQodG90YWxQYWlkKX1gLAogICAgICBzdWI6ICAgYGFjcm9zcyAke2NvbXBsZXRlZC5sZW5ndGh9IGNvbXBsZXRlZCBiYXRjaCR7Y29tcGxldGVkLmxlbmd0aCA9PT0gMSA/ICcnIDogJ2VzJ31gLAogICAgICBpY29uOiAgV2FsbGV0LAogICAgfSwKICAgIHsKICAgICAgbGFiZWw6ICdSZWNpcGllbnRzIHBhaWQnLAogICAgICB2YWx1ZTogU3RyaW5nKHJlY2lwaWVudHMpLAogICAgICBzdWI6ICAgJ2luIHRoZSBzZWxlY3RlZCBwZXJpb2QnLAogICAgICBpY29uOiAgQ2hlY2tDaXJjbGUyLAogICAgfSwKICAgIHsKICAgICAgbGFiZWw6ICdJbiBwcm9ncmVzcycsCiAgICAgIHZhbHVlOiBTdHJpbmcocHJvY2Vzc2luZy5sZW5ndGgpLAogICAgICBzdWI6ICAgJ3Byb2Nlc3Npbmcgb3IgcGFydGlhbCcsCiAgICAgIGljb246ICBDbG9jaywKICAgIH0sCiAgXQoKICByZXR1cm4gKAogICAgPGRpdj4KICAgICAgey8qIEhlYWRlciAqL30KICAgICAgPGRpdiBjbGFzc05hbWU9Im1iLTYgZmxleCBpdGVtcy1jZW50ZXIganVzdGlmeS1iZXR3ZWVuIj4KICAgICAgICA8ZGl2PgogICAgICAgICAgPGgxIGNsYXNzTmFtZT0idGV4dC14bCBmb250LXNlbWlib2xkIHRleHQtYXBwLXRleHQiPlBheXJvbGw8L2gxPgogICAgICAgICAgPHAgY2xhc3NOYW1lPSJ0ZXh0LXNtIHRleHQtYXBwLW11dGVkIj5CYXRjaCBwYXlvdXRzIHdpdGggVVNEIGVxdWl2YWxlbnRzIMK3IGV4cG9ydGFibGU8L3A+CiAgICAgICAgPC9kaXY+CiAgICAgICAgPGRpdiBjbGFzc05hbWU9ImZsZXggZ2FwLTIiPgogICAgICAgICAgPHNlbGVjdCB2YWx1ZT17cmFuZ2V9IG9uQ2hhbmdlPXtlID0+IHNldFJhbmdlKGUudGFyZ2V0LnZhbHVlKX0KICAgICAgICAgICAgY2xhc3NOYW1lPSJyb3VuZGVkLWxnIGJvcmRlciBib3JkZXItYXBwLWJvcmRlciBiZy1hcHAtc3VyZmFjZSBweC0zIHB5LTEuNSB0ZXh0LXhzIHRleHQtYXBwLXRleHQgb3V0bGluZS1ub25lIj4KICAgICAgICAgICAge1JBTkdFUy5tYXAoKFt2LCBsXSkgPT4gPG9wdGlvbiBrZXk9e3Z9IHZhbHVlPXt2fT57bH08L29wdGlvbj4pfQogICAgICAgICAgPC9zZWxlY3Q+CiAgICAgICAgICA8TGluayBocmVmPSIvdHJlYXN1cnkvcGF5cm9sbCI+CiAgICAgICAgICAgIDxCdXR0b24gc2l6ZT0ic20iPgogICAgICAgICAgICAgIDxVc2VycyBjbGFzc05hbWU9ImgtNCB3LTQiIC8+IE5ldyBwYXlyb2xsCiAgICAgICAgICAgIDwvQnV0dG9uPgogICAgICAgICAgPC9MaW5rPgogICAgICAgIDwvZGl2PgogICAgICA8L2Rpdj4KCiAgICAgIHsvKiBTdW1tYXJ5IGNhcmRzICovfQogICAgICA8ZGl2IGNsYXNzTmFtZT0ibWItNiBncmlkIGdyaWQtY29scy0xIGdhcC0zIHNtOmdyaWQtY29scy0zIj4KICAgICAgICB7c3VtbWFyeS5tYXAoKHsgbGFiZWwsIHZhbHVlLCBzdWIsIGljb246IEljb24gfSkgPT4gKAogICAgICAgICAgPGRpdiBrZXk9e2xhYmVsfSBjbGFzc05hbWU9InJvdW5kZWQteGwgYm9yZGVyIGJvcmRlci1hcHAtYm9yZGVyIGJnLWFwcC1zdXJmYWNlIHAtNCI+CiAgICAgICAgICAgIDxkaXYgY2xhc3NOYW1lPSJmbGV4IGl0ZW1zLWNlbnRlciBqdXN0aWZ5LWJldHdlZW4iPgogICAgICAgICAgICAgIDxwIGNsYXNzTmFtZT0idGV4dC14cyB0ZXh0LWFwcC1tdXRlZCI+e2xhYmVsfTwvcD4KICAgICAgICAgICAgICA8SWNvbiBjbGFzc05hbWU9ImgtNCB3LTQgdGV4dC1hcHAtbXV0ZWQiIC8+CiAgICAgICAgICAgIDwvZGl2PgogICAgICAgICAgICA8cCBjbGFzc05hbWU9Im10LTEgZm9udC1tb25vIHRleHQteGwgZm9udC1zZW1pYm9sZCB0ZXh0LWFwcC10ZXh0Ij57dmFsdWV9PC9wPgogICAgICAgICAgICA8cCBjbGFzc05hbWU9Im10LTAuNSB0ZXh0LXhzIHRleHQtYXBwLW11dGVkIj57c3VifTwvcD4KICAgICAgICAgIDwvZGl2PgogICAgICAgICkpfQogICAgICA8L2Rpdj4KCiAgICAgIHsvKiBSZWNlbnQgcGF5cm9sbHMgKEEyIHdpbGwgdHVybiB0aGlzIGludG8gdGhlIHRhYmJlZCB0YWJsZSkgKi99CiAgICAgIDxkaXYgY2xhc3NOYW1lPSJyb3VuZGVkLXhsIGJvcmRlciBib3JkZXItYXBwLWJvcmRlciBiZy1hcHAtc3VyZmFjZSBwLTUiPgogICAgICAgIDxkaXYgY2xhc3NOYW1lPSJtYi00IGZsZXggaXRlbXMtY2VudGVyIGp1c3RpZnktYmV0d2VlbiI+CiAgICAgICAgICA8ZGl2PgogICAgICAgICAgICA8cCBjbGFzc05hbWU9InRleHQtc20gZm9udC1tZWRpdW0gdGV4dC1hcHAtdGV4dCI+UmVjZW50IHBheXJvbGxzPC9wPgogICAgICAgICAgICA8cCBjbGFzc05hbWU9InRleHQteHMgdGV4dC1hcHAtbXV0ZWQiPkJhdGNoIFVTREMgcGF5bWVudHMgd2l0aCBNZW1vIHJlZmVyZW5jZXM8L3A+CiAgICAgICAgICA8L2Rpdj4KICAgICAgICAgIDxMaW5rIGhyZWY9Ii90cmVhc3VyeS9wYXlyb2xsIj4KICAgICAgICAgICAgPEJ1dHRvbiBzaXplPSJzbSIgdmFyaWFudD0ib3V0bGluZSI+CiAgICAgICAgICAgICAgPFBsdXMgY2xhc3NOYW1lPSJoLTMuNSB3LTMuNSIgLz4gTmV3IGJhdGNoCiAgICAgICAgICAgIDwvQnV0dG9uPgogICAgICAgICAgPC9MaW5rPgogICAgICAgIDwvZGl2PgoKICAgICAgICB7aW5SYW5nZS5sZW5ndGggPT09IDAgPyAoCiAgICAgICAgICA8ZGl2IGNsYXNzTmFtZT0iZmxleCBmbGV4LWNvbCBpdGVtcy1jZW50ZXIgZ2FwLTIgcHktOCB0ZXh0LWNlbnRlciI+CiAgICAgICAgICAgIDxCdWlsZGluZzIgY2xhc3NOYW1lPSJoLTggdy04IHRleHQtYXBwLWJvcmRlciIgLz4KICAgICAgICAgICAgPHAgY2xhc3NOYW1lPSJ0ZXh0LXNtIHRleHQtYXBwLW11dGVkIj5ObyBwYXlyb2xscyBpbiB0aGlzIHBlcmlvZDwvcD4KICAgICAgICAgICAgPHAgY2xhc3NOYW1lPSJ0ZXh0LXhzIHRleHQtYXBwLW11dGVkIj4KICAgICAgICAgICAgICBTZW5kIFVTREMgdG8gbXVsdGlwbGUgd2FsbGV0cyBpbiBvbmUgYmF0Y2ggd2l0aCB1bmlxdWUgTWVtbyByZWZlcmVuY2VzCiAgICAgICAgICAgIDwvcD4KICAgICAgICAgICAgPExpbmsgaHJlZj0iL3RyZWFzdXJ5L3BheXJvbGwiPgogICAgICAgICAgICAgIDxCdXR0b24gc2l6ZT0ic20iIHZhcmlhbnQ9Im91dGxpbmUiIGNsYXNzTmFtZT0ibXQtMiI+Q3JlYXRlIGZpcnN0IHBheXJvbGw8L0J1dHRvbj4KICAgICAgICAgICAgPC9MaW5rPgogICAgICAgICAgPC9kaXY+CiAgICAgICAgKSA6ICgKICAgICAgICAgIDxkaXYgY2xhc3NOYW1lPSJzcGFjZS15LTIiPgogICAgICAgICAgICB7aW5SYW5nZS5zbGljZSgwLCAxMCkubWFwKGJhdGNoID0+ICgKICAgICAgICAgICAgICA8TGluayBrZXk9e2JhdGNoLmlkfSBocmVmPXtgL3RyZWFzdXJ5L3BheXJvbGwvJHtiYXRjaC5pZH1gfT4KICAgICAgICAgICAgICAgIDxkaXYgY2xhc3NOYW1lPSJmbGV4IGl0ZW1zLWNlbnRlciBqdXN0aWZ5LWJldHdlZW4gcm91bmRlZC14bCBib3JkZXIgYm9yZGVyLWFwcC1ib3JkZXIgYmctYXBwLWJnIHAtMyBob3Zlcjpib3JkZXItYXBwLWFjY2VudC80MCB0cmFuc2l0aW9uLWNvbG9ycyBjdXJzb3ItcG9pbnRlciI+CiAgICAgICAgICAgICAgICAgIDxkaXYgY2xhc3NOYW1lPSJmbGV4LTEgbWluLXctMCI+CiAgICAgICAgICAgICAgICAgICAgPGRpdiBjbGFzc05hbWU9ImZsZXggaXRlbXMtY2VudGVyIGdhcC0yIj4KICAgICAgICAgICAgICAgICAgICAgIDxwIGNsYXNzTmFtZT0idGV4dC1zbSBmb250LW1lZGl1bSB0ZXh0LWFwcC10ZXh0IHRydW5jYXRlIj57YmF0Y2gubmFtZX08L3A+CiAgICAgICAgICAgICAgICAgICAgICA8QmFkZ2UgdmFyaWFudD17CiAgICAgICAgICAgICAgICAgICAgICAgIGJhdGNoLnN0YXR1cyA9PT0gJ2NvbXBsZXRlZCcgID8gJ3N1Y2Nlc3MnIDoKICAgICAgICAgICAgICAgICAgICAgICAgYmF0Y2guc3RhdHVzID09PSAncHJvY2Vzc2luZycgPyAnYXJjJyAgICAgOgogICAgICAgICAgICAgICAgICAgICAgICBiYXRjaC5zdGF0dXMgPT09ICdmYWlsZWQnICAgICA/ICdkYW5nZXInICA6ICd3YXJuaW5nJwogICAgICAgICAgICAgICAgICAgICAgfT4KICAgICAgICAgICAgICAgICAgICAgICAge2JhdGNoLnN0YXR1c30KICAgICAgICAgICAgICAgICAgICAgIDwvQmFkZ2U+CiAgICAgICAgICAgICAgICAgICAgPC9kaXY+CiAgICAgICAgICAgICAgICAgICAgPHAgY2xhc3NOYW1lPSJ0ZXh0LXhzIHRleHQtYXBwLW11dGVkIj4KICAgICAgICAgICAgICAgICAgICAgIHtiYXRjaC5yZWNpcGllbnRfY291bnR9IHJlY2lwaWVudHMgwrcgJHtmb3JtYXRBbW91bnQoYmF0Y2gudG90YWxfYW1vdW50KX0gVVNEQwogICAgICAgICAgICAgICAgICAgICAgwrcge25ldyBEYXRlKGJhdGNoLmNyZWF0ZWRfYXQgKiAxMDAwKS50b0xvY2FsZURhdGVTdHJpbmcoKX0KICAgICAgICAgICAgICAgICAgICA8L3A+CiAgICAgICAgICAgICAgICAgIDwvZGl2PgogICAgICAgICAgICAgICAgICA8QXJyb3dSaWdodCBjbGFzc05hbWU9ImgtNCB3LTQgc2hyaW5rLTAgdGV4dC1hcHAtbXV0ZWQiIC8+CiAgICAgICAgICAgICAgICA8L2Rpdj4KICAgICAgICAgICAgICA8L0xpbms+CiAgICAgICAgICAgICkpfQogICAgICAgICAgPC9kaXY+CiAgICAgICAgKX0KICAgICAgPC9kaXY+CiAgICA8L2Rpdj4KICApCn0K
B64EOF
base64 -d "$TMP.b64" > "$TMP"
rm -f "$TMP.b64"

GOT_SHA="$(sha256sum "$TMP" | awk '{print $1}')"
if [ "$GOT_SHA" != "$EXPECTED_SHA" ]; then
  echo "ABORT: decoded payload SHA mismatch ($GOT_SHA != $EXPECTED_SHA). Target untouched." >&2
  exit 1
fi

# ----- backup + replace -----
cp "$TARGET" "$TARGET.bak.$STAMP"
cp "$TMP" "$TARGET"
echo "OK: $TARGET replaced with A1 payroll dashboard (backup: $TARGET.bak.$STAMP)"

echo ""
echo "Done. Standard deploy (web only):"
echo "  cd ~/AfriFX/nexum-web && rm -rf .next && npx tsc --noEmit && npm run build"
echo "  cd ~/AfriFX && git add -A && git commit -m 'feat: /treasury -> payroll dashboard shell, remove rules UI (A1)' && git push"
