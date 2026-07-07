#!/usr/bin/env bash
# .editorconfig hint: indent_style = space, indent_size = 4
# SPDX-License-Identifier: GPL-3.0-or-later
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DRY_RUN=0
SEGMENT=""

usage() {
    cat <<'EOF'
Usage: bump-version.sh <major|minor|patch> [--dry-run]

Bump the project version and create an annotated git tag.

Examples:
  bash build/bump-version.sh patch     # 1.4.0 → 1.4.1
  bash build/bump-version.sh minor     # 1.4.0 → 1.5.0
  bash build/bump-version.sh major     # 1.4.0 → 2.0.0
  bash build/bump-version.sh minor --dry-run  # preview only
EOF
}

parse_args() {
    [[ $# -ge 1 ]] || { usage; exit 1; }
    case "$1" in
        major|minor|patch) SEGMENT="$1" ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Error: expected major|minor|patch, got: $1" >&2; usage; exit 1 ;;
    esac
    shift
    [[ "${1:-}" == "--dry-run" ]] && { DRY_RUN=1; shift; }
    [[ $# -eq 0 ]] || { echo "Error: unexpected argument: $1" >&2; usage; exit 1; }
}

get_current_version() {
    local tag
    tag="$(git -C "$PROJECT_DIR" describe --tags --match 'v*' --abbrev=0 2>/dev/null)" || {
        echo "Error: no git tag matching v* found" >&2
        exit 1
    }
    echo "${tag#v}"
}

bump_version() {
    local current="$1" segment="$2" major minor patch
    IFS='.' read -r major minor patch <<< "$current"
    case "$segment" in
        major) major=$(( major + 1 )); minor=0; patch=0 ;;
        minor) minor=$(( minor + 1 )); patch=0 ;;
        patch) patch=$(( patch + 1 )) ;;
    esac
    printf '%s.%s.%s' "$major" "$minor" "$patch"
}


create_tag() {
    local new_version="$1"
    local tag="v${new_version}"
    if [[ "$DRY_RUN" == "1" ]]; then
        echo "    [dry-run] would create tag: git tag -a '$tag' -m '$tag'"
    else
        git -C "$PROJECT_DIR" tag -a "$tag" -m "$tag"
        echo "    tag: $tag created"
    fi
    :
}

main() {
    parse_args "$@"
    local current new_version tag
    current="$(get_current_version)"
    new_version="$(bump_version "$current" "$SEGMENT")"
    tag="v${new_version}"

    echo "Current: $current"
    echo "Bump:    ${SEGMENT}"
    echo "New:     $new_version"
    echo "Tag:     $tag"
    echo

    create_tag "$new_version"

    echo
    if [[ "$DRY_RUN" == "0" ]]; then
        echo "Done. To publish:"
        echo "  git push origin master --follow-tags"
    fi
}

main "$@"
