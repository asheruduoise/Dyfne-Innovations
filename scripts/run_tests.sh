#!/usr/bin/env bash
# Full security test run: rebuild a THROWAWAY database, create accounts,
# run the SQL suite as admin and the permission suite as the app account.
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

echo "== 3/4 SQL security suite (admin)"
LOG="$(mktemp)"
mysql_admin --table < "$ROOT_DIR/tests/test_security.sql" > "$LOG" 2>&1 || { cat "$LOG"; die "SQL suite crashed"; }
mysql_admin --table -e "SELECT TestID, IF(Passed,'PASS','FAIL') AS Result, TestName
                          FROM gcr_test.Result ORDER BY ResultID"
failed=$(mysql_admin -N -B -e "SELECT COUNT(*) FROM gcr_test.Result WHERE NOT Passed")
total=$(mysql_admin -N -B -e "SELECT COUNT(*) FROM gcr_test.Result")
if [[ "$failed" != "0" ]]; then
  mysql_admin --table -e "SELECT TestID, TestName, Detail FROM gcr_test.Result WHERE NOT Passed"
fi
echo "SQL suite: $((total - failed)) passed, $failed failed"

echo "== 4/4 Permission suite (svc_gcr_inventory)"
perm_rc=0
"$ROOT_DIR/tests/test_permissions.sh" || perm_rc=$?

if [[ "$failed" != "0" || "$perm_rc" != "0" ]]; then
  echo "RESULT: FAILED"; exit 1
fi
echo "RESULT: ALL SECURITY TESTS PASSED"
