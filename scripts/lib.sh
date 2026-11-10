#!/usr/bin/env bash
# Shared helpers. Secrets come from the environment or the git-ignored .env
# file, never from this repo (Spec 4.9 §4).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DB_NAME="UH_GCR_Inventory"

if [[ -f "$ROOT_DIR/.env" ]]; then
  set -a; # shellcheck disable=SC1091
  . "$ROOT_DIR/.env"; set +a
fi

GCR_ENV="${GCR_ENV:-dev}"                 # dev | test | production
APP_DB_HOST="${APP_DB_HOST:-localhost}"   # host part of the MySQL accounts

# Admin connection, in order of preference:
#   1) MYSQL_ADMIN_LOGIN_PATH  -> mysql_config_editor login path (recommended on the GCR PC)
#   2) MYSQL_ADMIN_DEFAULTS_FILE -> option file with [client] user/password (chmod 600; CI uses this)
#   3) plain `mysql` (local socket auth, e.g. root on Linux)
mysql_admin() {
  if [[ -n "${MYSQL_ADMIN_LOGIN_PATH:-}" ]]; then
    mysql --login-path="$MYSQL_ADMIN_LOGIN_PATH" "$@"
  elif [[ -n "${MYSQL_ADMIN_DEFAULTS_FILE:-}" ]]; then
    mysql --defaults-extra-file="$MYSQL_ADMIN_DEFAULTS_FILE" "$@"
  else
    mysql "$@"
  fi
}

# Escape a value for use inside a single-quoted SQL string literal
sql_escape() {
  local v="${1//\\/\\\\}"
  printf '%s' "${v//\'/\'\'}"
}

# Random throwaway password for dev/test only (upper, lower, digit, symbol)
gen_password() {
  printf '%s-Gx9' "$(openssl rand -base64 30 | tr -d '/+=\n')"
}

die() { echo "ERROR: $*" >&2; exit 1; }
