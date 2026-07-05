#!/usr/bin/env bash
# .editorconfig hint: indent_style = space, indent_size = 4
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

cd "$PROJECT_DIR"
ln -sf build/debian debian
dpkg-buildpackage -us -uc -b
deb_version="$(dpkg-parsechangelog -S Version)"
rm -f debian

echo "Debian package built: sui-control_${deb_version}_all.deb"
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    echo "version=$deb_version" >> "$GITHUB_OUTPUT"
fi
