#!/usr/bin/env bash
# Builds the database from db/01..08 in order, stopping at the first error.
# Part 1 DROPS the database, so this refuses to touch an existing Production
# database unless you pass --rebuild-production on purpose.
source "$(dirname "$0")/lib.sh"

FORCE=0
[[ "${1:-}" == "--rebuild-production" ]] && FORCE=1

exists=$(mysql_admin -N -B -e "SELECT COUNT(*) FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='$DB_NAME'")
if [[ "$GCR_ENV" == "production" && "$exists" == "1" && "$FORCE" -ne 1 ]]; then
  die "GCR_ENV=production and $DB_NAME already exists. Part 1 would DROP all live data.
       Take a backup first (scripts/backup_db.sh), then re-run with --rebuild-production."
fi

for f in "$ROOT_DIR"/db/0*.sql; do
  echo "-> $(basename "$f")"
  mysql_admin --batch --skip-column-names < "$f" | tail -n 1
done
echo "Build complete ($GCR_ENV)."
