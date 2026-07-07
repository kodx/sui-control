#!/usr/bin/env bash
# .editorconfig hint: indent_style = space, indent_size = 4
# SPDX-License-Identifier: GPL-3.0-or-later
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
OUTPUT="$PROJECT_DIR/sui-control-install.sh"

if tag="$(git -C "$PROJECT_DIR" describe --tags --match 'v*' --abbrev=0 2>/dev/null)"; then
    VERSION="${tag#v}"
elif [[ -f "$PROJECT_DIR/VERSION" ]]; then
    VERSION="$(cat "$PROJECT_DIR/VERSION")"
else
    VERSION='0.0.0-dev'
fi

# Validate VERSION is semver
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9.]+)?$ ]] \
    || { echo "ERROR: VERSION does not match semver: $VERSION" >&2; exit 1; }

generate_embed_func() {
    local func_name="$1"
    local file_path="$2"
    echo "${func_name}() {"
    echo "    cat <<'EOF_${func_name##_embed}'"
    cat "$file_path"
    echo "EOF_${func_name##_embed}"
    echo '}'
}

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
    echo '# shellcheck disable=SC2034,SC2154,SC2153'
    echo '# SPDX-License-Identifier: GPL-3.0-or-later'
    echo "# Built by sui-control build.sh — v${VERSION}"
    echo 'set -euo pipefail'
    echo
    echo "readonly BUILT_VERSION='${VERSION}'"
    echo

    echo '# === EMBEDDED PROJECT FILES ==='
    generate_embed_func _embed_lib_constants   "$PROJECT_DIR/lib/constants.sh"
    generate_embed_func _embed_lib_utils       "$PROJECT_DIR/lib/utils.sh"
    generate_embed_func _embed_lib_actions     "$PROJECT_DIR/lib/actions.sh"
    generate_embed_func _embed_lib_commands    "$PROJECT_DIR/lib/commands.sh"
    generate_embed_func _embed_entry_point     "$PROJECT_DIR/sui-control.sh"
    echo '# --- Template files ---'
    generate_embed_func _embed_tpl_acme_cert   "$PROJECT_DIR/templates/acme-cert.sh.tpl"
    generate_embed_func _embed_tpl_db_config   "$PROJECT_DIR/templates/s-ui-db-configure.sh.tpl"
    generate_embed_func _embed_tpl_config      "$PROJECT_DIR/templates/sui-control.conf.tpl"
    echo

    echo '# === INSTALLER RUNTIME ==='
# shellcheck disable=SC2016
    echo 'eval "$(_embed_lib_constants)"'
# shellcheck disable=SC2016
    echo 'eval "$(_embed_lib_utils)"'
# shellcheck disable=SC2016
    echo 'eval "$(_embed_lib_actions)"'
    echo

    echo '# shellcheck disable=SC2154'
    echo '# === RUNTIME FILE GENERATORS ==='
    generate_gen_func _gen_config  "$PROJECT_DIR/templates/sui-control.conf.tpl"  0
    generate_gen_func _gen_acme    "$PROJECT_DIR/templates/acme-cert.sh.tpl"       1
    generate_gen_func _gen_db      "$PROJECT_DIR/templates/s-ui-db-configure.sh.tpl" 1
    echo

    echo '# === INSTALL LOGIC ==='
    cat "$PROJECT_DIR/lib/install.sh"
    echo

    echo '# === ENTRY POINT ==='
    echo 'maybe_escalate_privileges "$@"'
    echo 'parse_install_options "$@"'
    echo 'install_control_script'

} > "$OUTPUT"

chmod +x "$OUTPUT"

# Verify source files and built artifact with shellcheck
if command -v shellcheck &>/dev/null; then
    if shellcheck "$PROJECT_DIR"/lib/*.sh "$PROJECT_DIR/sui-control.sh" \
            "$OUTPUT" 2>&1; then
        echo "   shellcheck: passed"
    else
        echo "   shellcheck: FAILED" >&2
        exit 1
    fi
fi

echo "Built: $OUTPUT ($(wc -c < "$OUTPUT") bytes, $(wc -l < "$OUTPUT") lines)"
