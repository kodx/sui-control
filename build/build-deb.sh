#!/usr/bin/env bash
# .editorconfig hint: indent_style = space, indent_size = 4
# SPDX-License-Identifier: GPL-3.0-or-later
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

cd "$PROJECT_DIR"
cleanup() { rm -f "$PROJECT_DIR/debian"; }
trap cleanup EXIT
version="$(git describe --tags --match 'v*' --abbrev=0 2>/dev/null | sed 's/^v//')"
[[ -z "$version" ]] && version="$(cat "$PROJECT_DIR/VERSION" 2>/dev/null)"
: "${version:=0.0.0-dev}"
date_rfc="$(date -R)"
cat > build/debian/changelog <<EOF
sui-control (${version}-1) stable; urgency=medium

  * see git log

 -- kodx <dev@kodx.org>  ${date_rfc}

EOF
ln -sf build/debian debian
dpkg-buildpackage -us -uc -b
deb_version="$(dpkg-parsechangelog -S Version)"

echo "Debian package built: sui-control_${deb_version}_all.deb"
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    echo "version=$deb_version" >> "$GITHUB_OUTPUT"
fi
