# SUI-Control — Agent instructions

## Build & verify
- Build: `bash build/build.sh` → produces `sui-control-install.sh` (available in GitHub Releases). Run whenever `lib/`, `templates/`, or `sui-control.sh` changes.
- Version bump: `bash build/bump-version.sh <major|minor|patch>` — bumps semver, creates annotated tag. Add `--dry-run` to preview.
- Pre-commit: `.githooks/pre-commit` runs shellcheck on staged `.sh` files and actionlint on workflows. Set up via `git config core.hooksPath .githooks`.
- `build.sh` also runs shellcheck on source files and the built artifact. A failing build means shellcheck errors.

## Architecture
- **Two entry points**: `sui-control.sh` (development/manager) and `sui-control-install.sh` (self-contained installer, available from GitHub Releases)
- **FHS layout**:
  - Package (`lib/`, `templates/`, `sui-control.sh`, `VERSION`): auto-detected from `$(dirname "$(realpath "$0")")`, or `/opt/s-ui` when installed
  - Config: `/etc/sui-control/sui-control.conf`
  - Runtime data: `/var/lib/sui-control/` (`bin/`, `db/`, `cert/`, `acme/`, `systemd/`)
- **Init system abstraction**: `install_renewal_timer`/`remove_renewal_timer` dispatch to 5 backends (systemd, OpenRC, runit, s6, dinit). Non-systemd backends create cron job for renewal.
- **Service commands** (`start`, `stop`, `restart`) allow `sui-control.sh` to be used as a system service script by any init system.

## Conventions
- `templates/*.conf.tpl`: no SPDX (config template, not a script)
- `lib/*.sh`: no shebang (sourced), SPDX header (GPL-3.0-or-later), `.editorconfig` hint
- `sui-control.sh`: `#!/usr/bin/env bash`, reads `VERSION` at runtime, sets `PACKAGE_DIR`
- `build/build.sh`: `#!/usr/bin/env bash`, auto-generates `VERSION` from git tag or defaults to `0.0.0-dev`, embeds as `readonly BUILT_VERSION`
- `# shellcheck disable=SCxxxx` on specific lines only; file-wide only for cross-file variables (SC2034, SC2154, SC2153 in built artifact)
- ACME: `--domain` for FQDN (~90-day cert, weekly timer), `--ip` for IP (~6-day cert, daily timer). Mutually exclusive.
- Self-signed cert mode handled entirely by `generate_self_signed_cert()` in actions.sh; no ACME interaction.
- Docker images (`SUI_IMAGE`, `CURL_TEST_IMAGE`, `ACME_IMAGE`) default to `:latest` intentionally — they are overridable via `sui-control.conf`. Pinning is left to the user.
- GitHub Actions: `actions/checkout@v7` — bump when newer major versions are released

## Commits
- Types: feat:, fix:, build:, chore:, ci:, docs:, perf:, refactor:, style:, test:, revert:
- Format: `type: short description` + blank line + bullet points
- Always show the proposed message for approval first. Never push.
