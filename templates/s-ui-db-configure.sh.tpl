#!/usr/bin/env bash
# shellcheck disable=SC2154
set -euo pipefail

# shellcheck disable=SC1091
. "$PACKAGE_DIR/lib/constants.sh"
# shellcheck disable=SC1091
. "$PACKAGE_DIR/lib/utils.sh"

require_command sqlite3
ensure_config_loaded

DB_PATH="$RUNTIME_DATA_DIR/s-ui.db"
[[ -f "$DB_PATH" ]] || die "Database file not found: $DB_PATH"

USERNAME="${1:-}"
PASSWORD="${2:-}"
PANEL_PORT="$SUI_PANEL_PORT"
SUB_PORT="$SUI_SUBSCRIPTION_PORT"
PANEL_PATH="$SUI_PANEL_PATH"
SUB_PATH="$SUI_SUBSCRIPTION_PATH"
TIME_LOCATION="$TZ"

[[ -n "$USERNAME" ]]   || die "username argument is required"
[[ -n "$PASSWORD" ]]   || die "password argument is required"
[[ -n "$PANEL_PORT" ]] || die "panel_port is not set in config"
[[ -n "$SUB_PORT" ]]   || die "subscription_port is not set in config"
[[ -n "$PANEL_PATH" ]] || die "panel_path is not set in config"
[[ -n "$SUB_PATH" ]]   || die "subscription_path is not set in config"

settings_table_exists="$(sqlite3 "$DB_PATH" "SELECT 1 FROM sqlite_master WHERE type='table' AND name='settings' LIMIT 1;")"
users_table_exists="$(sqlite3 "$DB_PATH" "SELECT 1 FROM sqlite_master WHERE type='table' AND name='users' LIMIT 1;")"
first_user_rowid="$(sqlite3 "$DB_PATH" "SELECT rowid FROM users ORDER BY rowid LIMIT 1;")"
[[ "$settings_table_exists" == "1" ]] || die "settings table not found in database: $DB_PATH"
[[ "$users_table_exists" == "1" ]]    || die "users table not found in database: $DB_PATH"
[[ -n "$first_user_rowid" ]]          || die "users table is empty: $DB_PATH"

USERNAME_SQL="${USERNAME//\'/\'\'}"
PASSWORD_SQL="${PASSWORD//\'/\'\'}"
TIME_LOCATION_SQL="${TIME_LOCATION//\'/\'\'}"

if [[ "$CERT_MODE" == "selfsigned" ]]; then
    CERT_FILE="/certs/selfsigned/fullchain.pem"
    KEY_FILE="/certs/selfsigned/privkey.pem"
else
    CERT_FILE="/certs/server.crt"
    KEY_FILE="/certs/server.key"
fi

sqlite3 "$DB_PATH" <<SQL
BEGIN TRANSACTION;
UPDATE settings SET value = '$PANEL_PORT' WHERE key = 'webPort';
UPDATE settings SET value = '$PANEL_PATH' WHERE key = 'webPath';
UPDATE settings SET value = '$SUB_PORT'   WHERE key = 'subPort';
UPDATE settings SET value = '$SUB_PATH'   WHERE key = 'subPath';
UPDATE settings SET value = '$TIME_LOCATION_SQL' WHERE '$TIME_LOCATION_SQL' <> '' AND key = 'timeLocation';
UPDATE settings SET value = '$CERT_FILE'  WHERE key = 'webCertFile';
UPDATE settings SET value = '$KEY_FILE'   WHERE key = 'webKeyFile';
UPDATE users SET username = '$USERNAME_SQL', password = '$PASSWORD_SQL' WHERE rowid = $first_user_rowid;
COMMIT;
SQL

log_info "Database updated: $DB_PATH"
log_info "Panel path: $PANEL_PATH"
log_info "Subscription path: $SUB_PATH"
