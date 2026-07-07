#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# shellcheck disable=SC2154
set -Eeuo pipefail

. "$PACKAGE_DIR/lib/constants.sh"
. "$PACKAGE_DIR/lib/utils.sh"

require_command docker
require_command sqlite3

DB_PATH="$RUNTIME_DATA_DIR/s-ui.db"
[[ -f "$DB_PATH" ]] || die "Database file not found: $DB_PATH"

USERNAME="${1:-}"
PASSWORD="${2:-}"

[[ -n "$USERNAME" ]] || die "username argument is required"
[[ -n "$PASSWORD" ]] || die "password argument is required"

# Part 1 — Docker CLI (admin + setting — upstream CLI supports)
docker run --rm -v "$RUNTIME_DATA_DIR:/app/db" --entrypoint sh "$SUI_IMAGE" \
    -c '
        ./sui admin -username "$1" -password "$2"
        ./sui setting -port "$3" -path "$4" -subPort "$5" -subPath "$6"
    ' _ "$USERNAME" "$PASSWORD" \
    "$SUI_PANEL_PORT" "$SUI_PANEL_PATH" \
    "$SUI_SUBSCRIPTION_PORT" "$SUI_SUBSCRIPTION_PATH"

# Part 2 — Host sqlite3 (cert files + TZ — upstream CLI does not support these)
if [[ "$CERT_MODE" == "selfsigned" ]]; then
    CERT_FILE="/certs/selfsigned/fullchain.pem"
    KEY_FILE="/certs/selfsigned/privkey.pem"
else
    CERT_FILE="/certs/server.crt"
    KEY_FILE="/certs/server.key"
fi

cert_file_safe="${CERT_FILE//\'/\'\'}"
key_file_safe="${KEY_FILE//\'/\'\'}"
tz_safe="${TZ//\'/\'\'}"

sqlite3 "$DB_PATH" "
    UPDATE settings SET value = '$cert_file_safe' WHERE key = 'webCertFile';
    UPDATE settings SET value = '$key_file_safe'  WHERE key = 'webKeyFile';
    UPDATE settings SET value = '$tz_safe'         WHERE key = 'timeLocation';
"

# Part 3 — Sync inbound ports to config file
INBOUND_PORTS="$(sqlite3 "$DB_PATH" \
    "SELECT DISTINCT json_extract(options, '$.listen_port') FROM inbounds \
     WHERE json_extract(options, '$.listen_port') IS NOT NULL ORDER BY 1;" \
    2>/dev/null | tr '\n' ',' | sed 's/,$//')"
if grep -q '^inbound_ports=' "$CONFIG_DIR/$CONFIG_FILE_NAME" 2>/dev/null; then
    sed -i "s/^inbound_ports=.*/inbound_ports=$INBOUND_PORTS/" "$CONFIG_DIR/$CONFIG_FILE_NAME"
else
    echo "inbound_ports=$INBOUND_PORTS" >> "$CONFIG_DIR/$CONFIG_FILE_NAME"
fi

log_info "Database updated: $DB_PATH"
