# SUI-Control

Install, configure and maintain an [s-ui](https://github.com/alireza0/s-ui) deployment with Docker Compose.

## Quick start

```bash
curl -sSL https://raw.githubusercontent.com/.../sui-control-install.sh | bash
```

Or clone the repo and run:

```bash
git clone https://github.com/.../sui-control.git
cd sui-control
./sui-control.sh install
```

## Usage

```
sui-control.sh <command> [options]

Commands:
  install                       Install or reinstall s-ui into the target directory.
  init                          Re-initialize runtime artifacts for an existing
                                installation (regenerate certs, restart).
  renew-now                     Renew certificates immediately.
  status                        Show current installation status.
  service-install               Install and enable the systemd renewal timer.
  service-remove                Remove the systemd renewal timer.
  update                        Pull newer container images and restart services.
  cleanup                       Remove unused Docker containers and dangling images.
  cleanup-all                   Remove unused Docker containers and all unused images.
  uninstall                     Stop containers and remove installed files.

Options:
  --install-dir PATH            Installation directory, default: /opt/s-ui
  --domain DOMAIN               Public domain for ACME mode
  --tz TZ                       Time zone
  --cert-mode MODE              Certificate mode: selfsigned or acme
  --panel-port PORT             Panel port
  --subscription-port PORT      Subscription port
  --panel-path PATH             Panel URL path prefix
  --subscription-path PATH      Subscription URL path prefix
  --batch                       Non-interactive install
  --yes                         Skip confirmation prompts
  -h, --help                    Show this help message
```

## Development

### Project structure

```
sui-control/
├── config.conf              User overrides (not tracked by git)
├── sui-control.sh              Entry point (sources lib/* during development)
├── sui-control-install.sh      Self-contained installer (built artifact, committed)
├── build/build.sh              Build script: assembles sui-control-install.sh
├── lib/
│   ├── constants.sh               Constants, defaults, globals
│   ├── utils.sh                Reusable toolkit (logging, validation, docker helpers)
│   ├── actions.sh              s-ui-specific actions (prompts, cert, systemd)
│   └── commands.sh             CLI command implementations + main()
├── templates/
│   ├── docker-compose.yml.tpl  Docker Compose template
│   ├── sui-control.conf.tpl    Config file template
│   ├── acme-cert.sh.tpl        ACME certificate script template
│   └── s-ui-db-configure.sh.tpl Database configuration script template
└── build.sh
```

### Build

### Developer config

Create a `config.conf` in the project root to override defaults without touching `lib/constants.sh`:

```bash
./sui-control.sh init-config
```

This file is not tracked by git. If absent, `sui-control.sh` prompts to create it on first real command.


```bash
./build/build.sh    # produces sui-control-install.sh
```

### Conventions

- Shared functionality lives in `lib/utils.sh` — single source of truth.
  This file is also used as `lib-sui-control.sh` for installed scripts.
- Templates in `templates/` are plain files with `${VARIABLE}` placeholders.
  The build script wraps each template in a heredoc-based generator function.
- Adding a new init system (OpenRC, supervisord, etc.):
  1. Add functions in `lib/actions.sh`
  2. Add the interface call in the appropriate command handler
  3. (Optional) Add templates in `templates/init/<name>/`

## License

GPL-3.0-or-later
