#!/usr/bin/env bash
# Nightly/weekly backup by the gcr_dba account (spec §2/§3).
# Uses a mysql_config_editor login path so no password is in this script:
#   mysql_config_editor set --login-path=gcr_dba --host=localhost --user=gcr_dba --password
# BACKUP_DIR should be on the BitLocker-encrypted drive.
source "$(dirname "$0")/lib.sh"

BACKUP_DIR="${BACKUP_DIR:?Set BACKUP_DIR (a folder on the encrypted drive)}"
KEEP_DAYS="${BACKUP_KEEP_DAYS:-30}"
LOGIN_PATH="${DBA_LOGIN_PATH:-gcr_dba}"

mkdir -p "$BACKUP_DIR"
umask 077
out="$BACKUP_DIR/${DB_NAME}_$(date +%Y%m%d_%H%M%S).sql.gz"

mysqldump --login-path="$LOGIN_PATH" --single-transaction --routines --triggers --events \
          --set-gtid-purged=OFF "$DB_NAME" | gzip > "$out"
gzip -t "$out"                                   # verify the archive is readable
find "$BACKUP_DIR" -name "${DB_NAME}_*.sql.gz" -mtime +"$KEEP_DAYS" -delete
echo "Backup written: $out"
