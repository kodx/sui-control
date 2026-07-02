#!/usr/bin/env bash
# .editorconfig hint: indent_style = space, indent_size = 4
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/constants.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/utils.sh"

PACKAGE_DIR="$SCRIPT_DIR"
resolve_layout

# Dev config overrides (optional, for local testing)
[[ -f "$SCRIPT_DIR/config.conf" ]] && parse_config_file "$SCRIPT_DIR/config.conf"

init_config() {
    local cert_mode domain panel_port sub_port ans

    if [[ -f "$CONFIG_DIR/$CONFIG_FILE_NAME" ]]; then
        read -r -p "$CONFIG_DIR/$CONFIG_FILE_NAME already exists. Overwrite? [y/N] " ans
        [[ "$ans" =~ ^[yY] ]] || { echo "Aborted."; exit 0; }
    fi

    while true; do
        read -r -p "Certificate mode (selfsigned/acme) [selfsigned]: " cert_mode
        cert_mode="${cert_mode:-selfsigned}"
        case "$cert_mode" in selfsigned|acme) break ;; *) echo "Enter selfsigned or acme." ;; esac
    done

    domain=""
    if [[ "$cert_mode" == "acme" ]]; then
        read -r -p "Domain or IP for ACME (domain ~90 days, IP ~6 days): " domain
    fi

    read -r -p "Panel port [2095]: " panel_port
    panel_port="${panel_port:-2095}"

    read -r -p "Subscription port [2096]: " sub_port
    sub_port="${sub_port:-2096}"

    mkdir -p "$CONFIG_DIR"
    cat > "$CONFIG_DIR/$CONFIG_FILE_NAME" <<EOF
# sui-control configuration
cert_mode=$cert_mode
panel_port=$panel_port
subscription_port=$sub_port
EOF

    if [[ -n "$domain" ]]; then
        echo "domain=$domain" >> "$CONFIG_DIR/$CONFIG_FILE_NAME"
    fi

    echo "Created $CONFIG_DIR/$CONFIG_FILE_NAME"
}

prompt_create_config() {
    local ans
    echo "$CONFIG_DIR/$CONFIG_FILE_NAME not found — create one with your preferred defaults?"
    echo "  (You can also run './sui-control.sh init-config' later)"
    read -r -p "Create config.conf now? [y/N] " ans
    if [[ "$ans" =~ ^[yY] ]]; then
        init_config
    else
        echo "Using built-in defaults."
    fi
}

case "${1:-}" in
    init-config)
        init_config
        exit 0
        ;;
    help|-h|--help)
        ;;
    *)
        [[ -f "$CONFIG_DIR/$CONFIG_FILE_NAME" ]] || prompt_create_config
        ;;
esac

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/actions.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/commands.sh"

dispatch_command "$@"
