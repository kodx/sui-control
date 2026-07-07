#!/usr/bin/env bash
# .editorconfig hint: indent_style = space, indent_size = 4
# SPDX-License-Identifier: GPL-3.0-or-later
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/constants.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/utils.sh"

# shellcheck disable=SC2034
PACKAGE_DIR="$SCRIPT_DIR"
resolve_layout

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/actions.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/commands.sh"

init_config() {
    run_interactive_config_menu
}

prompt_create_config() {
    local ans
    echo "$CONFIG_DIR/$CONFIG_FILE_NAME not found — create one with your preferred defaults?"
    echo "  (You can also run './sui-control.sh init-config' later)"
    read -r -p "Create config.conf now? [y/N] " ans
    if [[ "$ans" =~ ^[yY] ]]; then
        run_interactive_config_menu
    else
        mkdir -p "$CONFIG_DIR"
        cat > "$CONFIG_DIR/$CONFIG_FILE_NAME" <<EOF_CONFIG
# sui-control configuration — auto-generated defaults
cert_mode=$DEFAULT_CERT_MODE
panel_port=$DEFAULT_SUI_PANEL_PORT
subscription_port=$DEFAULT_SUI_SUBSCRIPTION_PORT
EOF_CONFIG
        echo "Using built-in defaults."
    fi
}

case "${1:-}" in
    init-config)
        init_config
        exit 0
        ;;
    help|-h|--help)
        show_usage
        exit 0
        ;;
    *)
        [[ -f "$CONFIG_DIR/$CONFIG_FILE_NAME" ]] || prompt_create_config
        dispatch_command "$@"
        ;;
esac
