# SUI-Control — Agent instructions

## Build & verify
- Build: `bash build/build.sh` → produces `sui-control-install.sh` (committed). Run whenever lib/, templates/, or sui-control.sh changes.
- Pre-commit: `.githooks/pre-commit` runs shellcheck on staged `.sh` files and actionlint on workflows. Set up via `git config core.hooksPath .githooks`.
- build.sh also runs shellcheck on source files and the built artifact. A failing build means shellcheck errors.

## Architecture
- **Two entry points**: `sui-control.sh` (development manager, sources lib/*.sh directly) and `sui-control-install.sh` (self-contained installer artifact)
- **Lib files** (`lib/`): `constants.sh` (defaults + globals), `utils.sh` (shared toolkit — single source of truth for installed scripts), `actions.sh` (s-ui-specific actions), `commands.sh` (CLI + main())
- **`lib/install.sh`**: install-only functions — NOT deployed to target, only embedded in the installer
- **Templates** (`templates/`): plain files with `${VARIABLE}` placeholders. Build wraps them into heredoc-based generator functions
- **`config.conf`** (gitignored): user overrides, created via `./sui-control.sh init-config`

## Conventions
- `lib/*.sh`: `# shellcheck shell=bash`, no shebang (sourced, not executed). `sui-control.sh` and `build/build.sh`: `#!/usr/bin/env bash`
- Every script: SPDX header (`GPL-3.0-or-later`) + `.editorconfig` hint
- Use `# shellcheck disable=SCxxxx` on specific lines, not file-wide (except `SC2034` for cross-file variables)
- `_randomize_if_default()` uses `local -n` (nameref) — requires bash 4.3+
- `lib/constants.sh` must NOT set `SCRIPT_DIR` — it's set by the entry point before sourcing
- `DEFAULT_*` = default values; runtime overrides are same name without prefix. `CLI_*_SET` flags track explicit user input
- ACME mode: `--domain` for FQDN (~90-day cert, weekly timer), `--ip` for IP (~6-day cert, daily timer). Mutually exclusive
- Self-signed cert mode handled entirely by `generate_self_signed_cert()` in `actions.sh`; no ACME interaction

## Commits
- Types: feat:, fix:, build:, chore:, ci:, docs:, perf:, refactor:, style:, test:, revert:
- Format: `type: short description` + blank line + bullet points
- Always show the proposed message for approval first. Never push.
