# SUI-Control

Install, configure and maintain an [s-ui](https://github.com/alireza0/s-ui) deployment with Docker.

## Quick start

Download from the [latest release](https://github.com/kodx/sui-control/releases/latest):

```bash
# Install script (any Linux with Docker)
curl -sSLo sui-control-install.sh \
  https://github.com/kodx/sui-control/releases/latest/download/sui-control-install.sh
chmod +x sui-control-install.sh && ./sui-control-install.sh

# Or deb package (Debian/Ubuntu)
curl -sSLo /tmp/sui-control.deb \
  https://github.com/kodx/sui-control/releases/latest/download/sui-control_all.deb
sudo dpkg -i /tmp/sui-control.deb
```

Or clone and build locally:

```bash
git clone https://github.com/kodx/sui-control.git
cd sui-control
bash build/build.sh
./sui-control-install.sh
```

## Usage

### Installer (`sui-control-install.sh`)

```bash
./sui-control-install.sh [options]
```

Interactive dialog by default. Use `--batch` for non-interactive.

Options:
| Option | Description |
|--------|-------------|
| `--domain DOMAIN` | Public domain for ACME mode (~90-day cert) |
| `--ip IP` | Public IP for ACME short-lived cert (~6 days) |
| `--tz TZ` | Time zone for s-ui (optional) |
| `--timer-on-calendar SPEC` | systemd OnCalendar for renew timer |
| `--timer-random-delay SPEC` | systemd RandomizedDelaySec for renew timer |
| `--cert-mode MODE` | `selfsigned` (default) or `acme` |
| `--panel-port PORT` | Panel port |
| `--subscription-port PORT` | Subscription port |
| `--panel-path PATH` | URL path prefix for panel |
| `--subscription-path PATH` | URL path prefix for subscriptions |
| `--batch` | Non-interactive install using provided/default values |
| `--yes` | Skip confirmation prompts where possible |
| `-h, --help` | Show help |

Installs everything under `/opt/s-ui/` (flat layout). For package-managed installs
see [Architecture](#architecture).

### Manager (`sui-control.sh`)

```bash
sui-control.sh <command> [options]
```

| Command | Description |
|---------|-------------|
| `start` | Start s-ui container |
| `stop` | Stop s-ui container |
| `restart` | Restart s-ui container (stops, removes, re-creates) |
| `renew` | Renew certificates immediately |
| `status` | Show installation status |
| `setup` | Configure deployment interactively (FHS mode) |
| `issue-cert` | Issue certificate (force) |
| `service-install` | Install and enable renewal timer |
| `service-remove` | Remove renewal timer |
| `update` | Pull newer image and restart |
| `cleanup` | Remove unused containers and dangling images |
| `cleanup-all` | Remove unused containers and all unused images |
| `uninstall` | Stop containers and remove installed files |

Options: `--domain`, `--ip`, `--tz`, `--timer-on-calendar`, `--timer-random-delay`,
`--cert-mode`, `--panel-port`, `--subscription-port`, `--panel-path`,
`--subscription-path`, `--yes`, `-h`, `--help`.

Inbound ports created via the s-ui panel are picked up automatically at every
`start`/`restart` — no manual sync needed. `sqlite3` is required at runtime.

## Architecture

### Dual layout

SUI-Control supports two deployment layouts, auto-detected by `resolve_layout()`:

**Flat mode** (installer default, `/opt/s-ui/`):
```
/opt/s-ui/
├── sui-control.sh        ← PACKAGE_DIR = CONFIG_DIR = RUNTIME_DIR
├── sui-control.conf
├── lib/, templates/
├── bin/, db/, cert/, acme/, systemd/
```

**FHS mode** (package-managed install):
| Path | Contents |
|------|----------|
| `/usr/lib/sui-control/` | `sui-control.sh`, `lib/`, `templates/` |
| `/etc/sui-control/` | `sui-control.conf` |
| `/var/lib/sui-control/` | `bin/`, `db/`, `cert/`, `acme/`, `systemd/` |

Detection is automatic based on `PACKAGE_DIR` being under `/usr/lib/` or
`/usr/local/lib/`.

### Init system abstraction

Supports 5 init systems plus cron fallback, auto-detected in order:

| Backend | Service | Renewal |
|---------|---------|---------|
| systemd | `.service` unit | `.timer` unit (native) |
| OpenRC | `/etc/init.d/sui-control` | cron |
| runit | `/etc/sv/sui-control` | cron |
| s6 | `/etc/s6/sui-control` | cron |
| dinit | `/etc/dinit.d/sui-control` | cron |

Set `init_system` in config to override auto-detection.

### Certificate modes

- **selfsigned** (default): OpenSSL self-signed cert, 825-day validity
- **acme**: Let's Encrypt via acme.sh
  - `--domain` FQDN: ~90-day cert, weekly renewal
  - `--ip` address: short-lived profile (~6-day cert), daily renewal

## Development

```
sui-control/
├── config.conf              User overrides (not tracked)
├── sui-control.sh           Entry point (sources lib/ during dev)
├── build/build.sh           Build script
├── lib/
│   ├── constants.sh             Constants, defaults, globals
│   ├── utils.sh                 Shared toolkit (logging, validation, etc.)
│   ├── actions.sh               Project actions (prompts, certs, timer system)
│   ├── commands.sh              CLI commands + main()
│   └── install.sh               Install-only logic (not deployed)
├── templates/
│   ├── sui-control.conf.tpl
│   ├── acme-cert.sh.tpl
│   └── s-ui-db-configure.sh.tpl
└── .githooks/pre-commit         Run shellcheck + actionlint on staged files
```

### Build

```bash
./build/build.sh    # produces sui-control-install.sh
```

### Developer config

Create `config.conf` in the project root to override defaults without touching
`lib/constants.sh`. This file is not tracked by git (listed in `.gitignore`).

```bash
echo "SUI_PANEL_PORT=3000" >> config.conf
```

### Commit hooks

```bash
git config core.hooksPath .githooks
```

### Conventions

- `lib/*.sh` have no shebang (sourced), SPDX header, `.editorconfig` hint
- Templates use `${VARIABLE}` placeholders; generators may use quoted or unquoted
  heredocs depending on whether shell expansion is desired at build time
- `lib/install.sh` is NOT deployed to target — embed-only in the installer
- All timer backends dispatch from a single `install_renewal_timer()` / `remove_renewal_timer()`
- Adding a new init system: add `_install_timer_$name` / `_remove_timer_$name` in `actions.sh`

## License

GPL-3.0-or-later
