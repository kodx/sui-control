#!/usr/bin/env bash
# .editorconfig hint: indent_style = space, indent_size = 4
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Rebuild the monolithic installer first
"$SCRIPT_DIR/build.sh"

cd "$PROJECT_DIR"
dpkg-buildpackage -us -uc

echo "Debian package built. Output in $(dirname "$PROJECT_DIR")"
