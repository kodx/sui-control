#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
OUTPUT="$PROJECT_DIR/sui-control-install.sh"

generate_gen_func() {
    local func_name="$1"
    local template="$2"
    local quoted="${3:-0}"
    echo
    echo "${func_name}() {"
    if [[ "$quoted" == "1" ]]; then
        echo "    cat <<'EOF_${func_name##_gen}'"
    else
        echo "    cat <<EOF_${func_name##_gen}"
    fi
    cat "$template"
    echo "EOF_${func_name##_gen}"
    echo '}'
}

{
    echo '#!/usr/bin/env bash'
    echo '# shellcheck disable=SC2034'
    echo '# SPDX-License-Identifier: GPL-3.0-or-later'
    echo "# Built by sui-control build.sh"
    echo 'set -euo pipefail'
    echo
    cat "$PROJECT_DIR/lib/constants.sh"

    echo '# === SHARED LIBRARY GENERATOR ==='
    echo '_gen_lib() {'
    echo "    cat <<'EOF_LIB'"
    cat "$PROJECT_DIR/lib/utils.sh"
    echo 'EOF_LIB'
    echo '}'
    echo

    echo '# Load shared functions'
    # shellcheck disable=SC2016
    echo 'eval "$(_gen_lib)"'
    echo

    generate_gen_func _gen_compose "$PROJECT_DIR/templates/docker-compose.yml.tpl" 0
    generate_gen_func _gen_config  "$PROJECT_DIR/templates/sui-control.conf.tpl"  0
    generate_gen_func _gen_acme    "$PROJECT_DIR/templates/acme-cert.sh.tpl"       1
    generate_gen_func _gen_db      "$PROJECT_DIR/templates/s-ui-db-configure.sh.tpl" 1

    cat "$PROJECT_DIR/lib/actions.sh"
    echo
    cat "$PROJECT_DIR/lib/commands.sh"
    echo

    echo 'main "$@"'

} > "$OUTPUT"

chmod +x "$OUTPUT"
echo "Built: $OUTPUT ($(wc -c < "$OUTPUT") bytes, $(wc -l < "$OUTPUT") lines)"
