#!/usr/bin/env bash
# .editorconfig hint: indent_style = space, indent_size = 4
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

source "$SCRIPT_DIR/lib/constants.sh"

_gen_lib() {
    cat "$SCRIPT_DIR/lib/utils.sh"
}

eval "$(_gen_lib)"

[[ -f "$SCRIPT_DIR/config.conf" ]] && parse_config_file "$SCRIPT_DIR/config.conf"

init_config() {
    local install_dir cert_mode domain panel_port sub_port ans

    if [[ -f "$SCRIPT_DIR/config.conf" ]]; then
        read -r -p "config.conf already exists. Overwrite? [y/N] " ans
        [[ "$ans" =~ ^[yY] ]] || { echo "Aborted."; exit 0; }
    fi

    read -r -p "Install directory [/opt/s-ui]: " install_dir
    install_dir="${install_dir:-/opt/s-ui}"

    while true; do
        read -r -p "Certificate mode (selfsigned/acme) [selfsigned]: " cert_mode
        cert_mode="${cert_mode:-selfsigned}"
        case "$cert_mode" in selfsigned|acme) break ;; *) echo "Enter selfsigned or acme." ;; esac
    done

    domain=""
    if [[ "$cert_mode" == "acme" ]]; then
        read -r -p "Domain for ACME: " domain
    fi

    read -r -p "Panel port [2095]: " panel_port
    panel_port="${panel_port:-2095}"

    read -r -p "Subscription port [2096]: " sub_port
    sub_port="${sub_port:-2096}"

    cat > "$SCRIPT_DIR/config.conf" <<EOF
# sui-control user overrides
install_dir=$install_dir
cert_mode=$cert_mode
panel_port=$panel_port
subscription_port=$sub_port
EOF

    if [[ -n "$domain" ]]; then
        echo "domain=$domain" >> "$SCRIPT_DIR/config.conf"
    fi

    echo "Created $SCRIPT_DIR/config.conf"
}

prompt_create_config() {
    local ans
    echo "config.conf not found — create one with your preferred defaults?"
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
        [[ -f "$SCRIPT_DIR/config.conf" ]] || prompt_create_config
        ;;
esac

source "$SCRIPT_DIR/lib/actions.sh"
source "$SCRIPT_DIR/lib/commands.sh"

main "$@"
