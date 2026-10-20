#!/usr/bin/env bash
# Creates (or rotates the password of) the two MySQL accounts and attaches
# their roles from db/08_db_roles_grants.sql. Passwords are read from the
# environment / .env and sent to MySQL on stdin, so they never appear on a
# command line, in the process list, or in this repo.
#
#   SVC_DB_PASSWORD  application account  svc_gcr_inventory
#   DBA_DB_PASSWORD  maintenance account  gcr_dba
#   APP_DB_HOST      host part, default 'localhost' (CI uses '%')
#
# Re-running this script = password rotation (spec §4 rule 3).
source "$(dirname "$0")/lib.sh"

: "${SVC_DB_PASSWORD:?Set SVC_DB_PASSWORD (in .env or the environment)}"
: "${DBA_DB_PASSWORD:?Set DBA_DB_PASSWORD (in .env or the environment)}"
[[ ${#SVC_DB_PASSWORD} -ge 16 ]] || die "SVC_DB_PASSWORD must be at least 16 characters."
[[ ${#DBA_DB_PASSWORD} -ge 16 ]] || die "DBA_DB_PASSWORD must be at least 16 characters."

SVC_PW=$(sql_escape "$SVC_DB_PASSWORD")
DBA_PW=$(sql_escape "$DBA_DB_PASSWORD")
HOST=$(sql_escape "$APP_DB_HOST")

# FAILED_LOGIN_ATTEMPTS 5 / PASSWORD_LOCK_TIME 1 = MySQL locks the account for
# 1 day after 5 consecutive bad passwords (database-layer lockout, spec §3).
mysql_admin <<SQL
CREATE USER IF NOT EXISTS 'svc_gcr_inventory'@'${HOST}' IDENTIFIED BY '${SVC_PW}';
ALTER USER 'svc_gcr_inventory'@'${HOST}' IDENTIFIED BY '${SVC_PW}'
      FAILED_LOGIN_ATTEMPTS 5 PASSWORD_LOCK_TIME 1;
GRANT 'gcr_app_role' TO 'svc_gcr_inventory'@'${HOST}';
SET DEFAULT ROLE 'gcr_app_role' TO 'svc_gcr_inventory'@'${HOST}';

CREATE USER IF NOT EXISTS 'gcr_dba'@'${HOST}' IDENTIFIED BY '${DBA_PW}';
ALTER USER 'gcr_dba'@'${HOST}' IDENTIFIED BY '${DBA_PW}'
      FAILED_LOGIN_ATTEMPTS 5 PASSWORD_LOCK_TIME 1;
GRANT 'gcr_dba_role' TO 'gcr_dba'@'${HOST}';
SET DEFAULT ROLE 'gcr_dba_role' TO 'gcr_dba'@'${HOST}';
SQL

echo "Accounts ready: svc_gcr_inventory@${APP_DB_HOST} (gcr_app_role), gcr_dba@${APP_DB_HOST} (gcr_dba_role)."
