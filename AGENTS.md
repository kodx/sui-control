# SUI-Control — Agent instructions

## Build & verify
- Build: `bash build/build.sh` → produces `sui-control-install.sh` (committed). Run whenever `lib/`, `templates/`, `sui-control.sh`, or `VERSION` changes.
- Pre-commit: `.githooks/pre-commit` runs shellcheck on staged `.sh` files and actionlint on workflows. Set up via `git config core.hooksPath .githooks`.
- `build.sh` also runs shellcheck on source files and the built artifact. A failing build means shellcheck errors.

## Architecture
- **Two entry points**: `sui-control.sh` (development/manager) and `sui-control-install.sh` (self-contained installer)
- **FHS layout**:
  - Package (`lib/`, `templates/`, `sui-control.sh`, `VERSION`): auto-detected from `$(dirname "$(realpath "$0")")`, or `/opt/s-ui` when installed
  - Config: `/etc/sui-control/sui-control.conf`
  - Runtime data: `/var/lib/sui-control/` (`bin/`, `db/`, `cert/`, `acme/`, `systemd/`)
- **Init system abstraction**: `install_renewal_timer`/`remove_renewal_timer` dispatch to 5 backends (systemd, OpenRC, runit, s6, dinit). Non-systemd backends create cron job for renewal.
- **Service commands** (`start`, `stop`, `restart`) allow `sui-control.sh` to be used as a system service script by any init system.
- **`VERSION` file** in repo root — single source of version truth.

## Conventions
- `lib/*.sh`: no shebang (sourced), SPDX header (GPL-3.0-or-later), `.editorconfig` hint
- `sui-control.sh`: `#!/usr/bin/env bash`, reads `VERSION` at runtime, sets `PACKAGE_DIR`
- `build/build.sh`: `#!/usr/bin/env bash`, reads `VERSION`, embeds as `readonly BUILT_VERSION`
- `# shellcheck disable=SCxxxx` on specific lines only; file-wide only for cross-file variables (SC2034, SC2154, SC2153 in built artifact)
- ACME: `--domain` for FQDN (~90-day cert, weekly timer), `--ip` for IP (~6-day cert, daily timer). Mutually exclusive.
- Self-signed cert mode handled entirely by `generate_self_signed_cert()` in actions.sh; no ACME interaction.

## Commits
- Types: feat:, fix:, build:, chore:, ci:, docs:, perf:, refactor:, style:, test:, revert:
- Format: `type: short description` + blank line + bullet points
- Always show the proposed message for approval first. Never push.
