#!/usr/bin/env bash
# Connects AS THE APPLICATION ACCOUNT (svc_gcr_inventory) and proves it can
# only run procedures / read views (spec §2, §3 "no direct table edits").
# Needs SVC_DB_PASSWORD; run after build + create_db_accounts.sh.
source "$(dirname "$0")/../scripts/lib.sh"
: "${SVC_DB_PASSWORD:?Set SVC_DB_PASSWORD}"

SVC_HOST_CONNECT="${SVC_CONNECT_HOST:-localhost}"
SVC_CNF=$(mktemp); chmod 600 "$SVC_CNF"
BAD_CNF=$(mktemp); chmod 600 "$BAD_CNF"
trap 'rm -f "$SVC_CNF" "$BAD_CNF"' EXIT
printf '[client]\nuser=svc_gcr_inventory\npassword="%s"\nhost=%s\nprotocol=%s\n' \
  "$SVC_DB_PASSWORD" "$SVC_HOST_CONNECT" "${SVC_CONNECT_PROTOCOL:-SOCKET}" > "$SVC_CNF"
printf '[client]\nuser=svc_gcr_inventory\npassword="wrong-password-123"\nhost=%s\nprotocol=%s\n' \
  "$SVC_HOST_CONNECT" "${SVC_CONNECT_PROTOCOL:-SOCKET}" > "$BAD_CNF"

svc() { mysql --defaults-extra-file="$SVC_CNF" -N -B "$DB_NAME" -e "$1" 2>&1; }

pass=0; fail=0
check() {  # id, description, result(0/1), detail
  if [[ "$3" == "0" ]]; then pass=$((pass+1)); printf '  PASS %-4s %s\n' "$1" "$2"
  else fail=$((fail+1)); printf '  FAIL %-4s %s\n         %s\n' "$1" "$2" "$4"; fi
}
expect_ok()     { local o; if o=$(svc "$3"); then check "$1" "$2" 0; else check "$1" "$2" 1 "$o"; fi; }
expect_denied() { local o; if o=$(svc "$3"); then check "$1" "$2" 1 "NOT denied: $o";
                  elif grep -qiE "denied" <<<"$o"; then check "$1" "$2" 0;
                  else check "$1" "$2" 1 "$o"; fi; }

echo "App account permission tests (svc_gcr_inventory)"
expect_ok     P01 "Can run an entry-form procedure"              "CALL usp_GetSelectableVariants(NULL)"
expect_ok     P02 "Can read report views"                        "SELECT COUNT(*) FROM vw_CurrentInventory"
expect_ok     P03 "Can run the weekly security review"           "CALL usp_Security_WeeklyReview(7)"
expect_denied P04 "Cannot read the user table (password hashes)" "SELECT Username, PasswordHash FROM AppUser"
expect_denied P05 "Cannot read AuditLog directly"                "SELECT * FROM AuditLog"
expect_denied P06 "Cannot edit quantities directly"              "UPDATE InventoryBalance SET CurrentQuantity = 999 WHERE VariantID = 1"
expect_denied P07 "Cannot insert transactions directly"          "INSERT INTO InventoryTransaction (UserID, TransactionType, StockInReason) VALUES (1, 'IN', 'Received')"
expect_denied P08 "Cannot delete audit rows"                     "DELETE FROM AuditLog"
expect_denied P09 "Cannot TRUNCATE the audit log"                "TRUNCATE TABLE AuditLog"
expect_denied P10 "Cannot drop tables"                           "DROP TABLE AuditLog"
expect_denied P11 "Cannot create tables"                         "CREATE TABLE hack (id INT)"
expect_denied P12 "Cannot change triggers"                       "DROP TRIGGER trg_sec_AuditLog_BlockDelete"
expect_denied P13 "Cannot grant itself privileges"               "GRANT SELECT ON $DB_NAME.AppUser TO CURRENT_USER()"
expect_denied P14 "Cannot read MySQL account table"              "SELECT User, authentication_string FROM mysql.user"

# end-to-end through the app account: change is attributed to the APP USER and not flagged
expect_ok     P15 "Can change a setpoint through the procedure"  "CALL usp_UpdateSetpoint(1, 2, 2)"
attrib=$(mysql_admin -N -B "$DB_NAME" -e "SELECT COUNT(*) FROM AuditLog
         WHERE Action='SetpointChange' AND RecordID='1' AND UserID=2 AND NOT IsDirectEdit
           AND DbAccount LIKE 'svc_gcr_inventory@%'")
[[ "$attrib" -ge 1 ]] && check P16 "Change is logged as app user 2 via svc account, not a direct edit" 0 \
                      || check P16 "Change is logged as app user 2 via svc account, not a direct edit" 1 "found $attrib rows"

# SQL injection: hostile text is stored as plain data
INJ="x'); DROP TABLE AuditLog; --"
svc "CALL usp_StockIn(2, 1, 1, 'Received', NULL, '$(sql_escape "$INJ")', @t)" >/dev/null
inj=$(mysql_admin -N -B "$DB_NAME" -e "SELECT (SELECT COUNT(*) FROM information_schema.TABLES
        WHERE TABLE_SCHEMA='$DB_NAME' AND TABLE_NAME='AuditLog') = 1
        AND EXISTS (SELECT 1 FROM InventoryTransaction WHERE Notes = '$(sql_escape "$INJ")')")
check P17 "Injection text saved as data; AuditLog still exists" "$([[ "$inj" == "1" ]] && echo 0 || echo 1)" "got $inj"

# account policy
policy=$(mysql_admin -N -B -e "SHOW CREATE USER 'svc_gcr_inventory'@'$APP_DB_HOST'")
grep -q "FAILED_LOGIN_ATTEMPTS 5" <<<"$policy" \
  && check P18 "App account locks after 5 bad MySQL passwords" 0 \
  || check P18 "App account locks after 5 bad MySQL passwords" 1 "$policy"

if mysql --defaults-extra-file="$BAD_CNF" -e "SELECT 1" >/dev/null 2>&1; then
  check P19 "Wrong MySQL password is refused" 1 "login succeeded"
else
  check P19 "Wrong MySQL password is refused" 0
fi

echo "Permission tests: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
