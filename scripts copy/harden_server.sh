#!/usr/bin/env bash
# One-time MySQL server hardening (spec §3 database + PC layers).
# MySQL equivalent of "sa is disabled / SQL Browser off / firewall":
#   - no anonymous accounts, no remote root, no 'test' database
#   - password policy for MySQL accounts (validate_password component)
#   - LOAD DATA LOCAL disabled
#   - failed MySQL logins written to the error log
# Settings that need a restart (bind-address, mysqlx) are in
# config/mysqld-hardening.cnf.
source "$(dirname "$0")/lib.sh"

# CI reaches its throwaway container as root over TCP, so it may keep remote root.
KEEP_REMOTE_ROOT=0
[[ "${HARDEN_KEEP_REMOTE_ROOT:-0}" == "1" && "$GCR_ENV" != "production" ]] && KEEP_REMOTE_ROOT=1

installed=$(mysql_admin -N -B -e \
  "SELECT COUNT(*) FROM mysql.component WHERE component_urn = 'file://component_validate_password'")
if [[ "$installed" == "0" ]]; then
  mysql_admin -e "INSTALL COMPONENT 'file://component_validate_password'"
fi

{
echo "SET @keep_remote_root = ${KEEP_REMOTE_ROOT};"
cat <<'SQL'
-- anonymous accounts
SET @drop_sql = (SELECT GROUP_CONCAT(CONCAT('''''@''', Host, '''') SEPARATOR ', ')
                   FROM mysql.user WHERE User = '');
SET @drop_sql = IF(@drop_sql IS NULL, 'DO 0', CONCAT('DROP USER ', @drop_sql));
PREPARE s FROM @drop_sql; EXECUTE s; DEALLOCATE PREPARE s;

-- root may only sign in from this machine
SET @drop_sql = (SELECT GROUP_CONCAT(CONCAT('''root''@''', Host, '''') SEPARATOR ', ')
                   FROM mysql.user WHERE User = 'root' AND Host NOT IN ('localhost', '127.0.0.1', '::1'));
SET @drop_sql = IF(@drop_sql IS NULL OR @keep_remote_root = 1, 'DO 0', CONCAT('DROP USER ', @drop_sql));
PREPARE s FROM @drop_sql; EXECUTE s; DEALLOCATE PREPARE s;

DROP DATABASE IF EXISTS test;

-- password policy for MySQL accounts (app user passwords are bcrypt in AppUser)
SET PERSIST validate_password.policy = 'MEDIUM';
SET PERSIST validate_password.length = 16;
SET PERSIST validate_password.check_user_name = ON;

SET PERSIST local_infile = 0;
SET PERSIST log_error_verbosity = 3;   -- "Access denied for user ..." lines = failed SQL logins

SELECT User, Host, account_locked FROM mysql.user ORDER BY User, Host;
SQL
} | mysql_admin --table

echo "Server hardening applied. Also install config/mysqld-hardening.cnf and restart MySQL."
