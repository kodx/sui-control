#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# ---- Shared: determine VERSION -----------------------------------------------
tag="$(git -C "$PROJECT_DIR" describe --tags --match 'v*' --abbrev=0 2>/dev/null)" || true
if [[ -n "$tag" ]]; then
    VERSION="${tag#v}"
elif [[ -f "$PROJECT_DIR/VERSION" ]]; then
    VERSION="$(cat "$PROJECT_DIR/VERSION")"
else
    VERSION='0.0.0-dev'
fi

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9.]+)?$ ]] \
    || { echo "ERROR: VERSION does not match semver: $VERSION" >&2; exit 1; }

# Generate a VERSION file at the project root. It is a build artifact (gitignored),
# derived from the current tag, consumed by the deb packaging
# (build/debian/sui-control.install) and read by sui-control.sh at runtime.
printf '%s\n' "$VERSION" > "$PROJECT_DIR/VERSION"

# ---- Helper functions for installer build ------------------------------------
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

# ---- Debian package build ----------------------------------------------------
build_deb() {
    local LOCAL_BUILD=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --local) LOCAL_BUILD=1; shift ;;
            *) echo "Unknown option: $1" >&2; exit 1 ;;
        esac
    done

    if [[ "$LOCAL_BUILD" == "1" ]]; then
        # --- Docker-based build ---
        if ! command -v docker &>/dev/null; then
            echo "Error: docker is required for --local mode" >&2
            echo "  Install: https://docs.docker.com/engine/install/" >&2
            exit 1
        fi
        if ! docker buildx version &>/dev/null; then
            echo "Error: docker buildx is required for --local mode" >&2
            echo "  Install:" >&2
            echo "    mkdir -p ~/.docker/cli-plugins" >&2
            echo "    curl -sSL https://github.com/docker/buildx/releases/latest/download/buildx-$(uname -s | tr '[:upper:]' '[:lower:]')-$(uname -m) -o ~/.docker/cli-plugins/docker-buildx" >&2
            echo "    chmod +x ~/.docker/cli-plugins/docker-buildx" >&2
            exit 1
        fi

        local local_image="sui-control/deb-builder"
        if ! docker image inspect "$local_image" &>/dev/null; then
            echo "Building builder image..."
            DOCKER_BUILDKIT=1 docker build -t "$local_image" - <<-DOCKERFILE
	FROM debian:stable-slim
	RUN apt-get update && apt-get install -y --no-install-recommends \
	        build-essential dpkg-dev debhelper ca-certificates git \
	    && rm -rf /var/lib/apt/lists/*
	WORKDIR /build
	DOCKERFILE
        fi

        echo "Building Debian package via Docker..."
        docker run --rm -i \
            -e VERSION="$VERSION" \
            -e HOST_UID="$(id -u)" \
            -e HOST_GID="$(id -g)" \
            -v "$PROJECT_DIR:/build:rw" \
            -w /build "$local_image" bash <<-SCRIPT
	set -Eeuo pipefail

	ln -sf build/debian debian
	trap 'rm -f /build/debian' EXIT

	date_rfc="\$(date -R)"
	cat > build/debian/changelog <<-EOF
	sui-control (${VERSION}-1) stable; urgency=medium

	  * see git log

	 -- kodx <dev@kodx.org>  \${date_rfc}

	EOF

	dpkg-buildpackage -us -uc -b

	deb_version="\$(dpkg-parsechangelog -S Version)"

	mkdir -p build/artifacts
	mv "/sui-control_\${deb_version}_all.deb" build/artifacts/
	chown -R "\${HOST_UID}:\${HOST_GID}" build/artifacts/
	echo "Debian package built: build/artifacts/sui-control_\${deb_version}_all.deb"
	if [[ -n "\${GITHUB_OUTPUT:-}" ]]; then
	    echo "version=\$deb_version" >> "\$GITHUB_OUTPUT"
	fi
	rm -rf /build/build/debian/sui-control/
	# Clean up remaining root-owned build artifacts
	rm -f /build/build/debian/changelog /build/build/debian/files /build/build/debian/sui-control.substvars /build/build/debian/debhelper-build-stamp
	rm -rf /build/build/debian/.debhelper
	SCRIPT

    else

        # --- Native build ---
        cd "$PROJECT_DIR"
        trap 'rm -f "$PROJECT_DIR/debian"' EXIT

        date_rfc="$(date -R)"
        cat > build/debian/changelog <<EOF
sui-control (${VERSION}-1) stable; urgency=medium

  * see git log

 -- kodx <dev@kodx.org>  ${date_rfc}

EOF

        ln -sf build/debian debian
        dpkg-buildpackage -us -uc -b

        deb_version="$(dpkg-parsechangelog -S Version)"
        mkdir -p build/artifacts
        mv "../sui-control_${deb_version}_all.deb" build/artifacts/

        # Remove staging directory after successful build
        rm -rf "$PROJECT_DIR/build/debian/sui-control/"

        echo "Debian package built: build/artifacts/sui-control_${deb_version}_all.deb"
        if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
            echo "version=$deb_version" >> "$GITHUB_OUTPUT"
        fi
    fi
}

# ---- Dispatch ----------------------------------------------------------------
case "${1:-}" in
    deb)
        shift
        build_deb "$@"
        exit 0
        ;;
esac

# === Default: build sui-control-install.sh ===
OUTPUT="$PROJECT_DIR/sui-control-install.sh"

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
