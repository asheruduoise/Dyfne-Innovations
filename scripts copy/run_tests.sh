#!/usr/bin/env bash
# Full test run: rebuild a THROWAWAY database, create accounts,
# run the scenario suite as admin and the permission suite as the app account.
# Exit code 0 = everything passed (CI uses this).
source "$(dirname "$0")/lib.sh"

[[ "$GCR_ENV" == "production" ]] && die "Tests are destructive. Never run them with GCR_ENV=production."

# Dev/Test get their own throwaway passwords (spec §4 rule 4)
export SVC_DB_PASSWORD="${SVC_DB_PASSWORD:-$(gen_password)}"
export DBA_DB_PASSWORD="${DBA_DB_PASSWORD:-$(gen_password)}"

echo "== 1/4 Build database"
"$ROOT_DIR/scripts/build_db.sh"

echo "== 2/4 Create DB accounts"
"$ROOT_DIR/scripts/create_db_accounts.sh"

echo "== 3/4 Scenario suite (admin): every use case, business rule and audit control"
OUT=$(mysql_admin --table < "$ROOT_DIR/tests/test_scenarios.sql" 2>&1) || { echo "$OUT"; die "Scenario suite crashed"; }
grep -E "^\| +[0-9]+ \| .* \| (PASS|FAIL) +\|" <<<"$OUT" | awk -F'|' '{gsub(/ +$/, "", $3); gsub(/ /, "", $4); printf "  %s %s\n", $4, $3}'
summary=$(grep -oE "[0-9]+ of [0-9]+ tests passed" <<<"$OUT" | head -1)
read -r passed _ total _ <<<"$summary"
failed=$((total - passed))
echo "Scenario suite: $passed passed, $failed failed"

echo "== 4/4 Permission suite (svc_gcr_inventory)"
perm_rc=0
"$ROOT_DIR/tests/test_permissions.sh" || perm_rc=$?

if [[ "$failed" != "0" || "$perm_rc" != "0" ]]; then
  echo "RESULT: FAILED"; exit 1
fi
echo "RESULT: ALL TESTS PASSED"
