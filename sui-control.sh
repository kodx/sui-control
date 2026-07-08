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
# shellcheck disable=SC1091

init_config() {
    run_interactive_config_menu
}

prompt_create_config() {
    echo "$CONFIG_DIR/$CONFIG_FILE_NAME not found."
    echo "Run '$0 setup' to configure your deployment."
    exit 1
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
    setup)
        dispatch_command "$@"
        ;;
    *)
        [[ -f "$CONFIG_DIR/$CONFIG_FILE_NAME" ]] || prompt_create_config
        dispatch_command "$@"
        ;;
esac
