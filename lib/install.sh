# shellcheck shell=bash
# shellcheck disable=SC2034
# .editorconfig hint: indent_style = space, indent_size = 4
# SPDX-License-Identifier: GPL-3.0-or-later
# Install-only functions — not deployed to target

# ----------------------------------------------------------------------
# Installer help
# ----------------------------------------------------------------------
show_install_help() {
    cat <<'EOF'
Usage: sui-control-install.sh [options]

Installs s-ui with Docker Compose. Running without options starts an
interactive installation dialog.

Options:
  --domain DOMAIN               Public domain for ACME mode; ignored for selfsigned.
  --ip IP                       Public IP for ACME (~6-day short-lived cert; domain ~90 days); ignored for selfsigned.
  --tz TZ                       Time zone written to s-ui settings, optional.
  --timer-on-calendar SPEC      systemd OnCalendar value for renew timer.
  --timer-random-delay SPEC     systemd RandomizedDelaySec value for renew timer.
  --cert-mode MODE              Certificate mode: selfsigned or acme.
  --panel-port PORT             Panel port exposed by docker-compose.
  --subscription-port PORT      Subscription port exposed by docker-compose.
  --panel-path PATH             URL path prefix for panel, without leading slash.
  --subscription-path PATH      URL path prefix for subscriptions, without leading slash.
  --batch                       Non-interactive install using provided/default values.
  --yes                         Skip confirmation prompts where possible.
  -h, --help                    Show this help message.
EOF
}

# ----------------------------------------------------------------------
# CLI option parsing (install-only)
# ----------------------------------------------------------------------
parse_install_options() {
    local domain_option_set="0"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --domain)
                require_option_value "$1" "${2-}"
                DOMAIN="$2"; domain_option_set="1"; shift 2 ;;
            --ip)
                require_option_value "$1" "${2-}"
                DOMAIN="$2"; CLI_IP_CERT_SET="1"; shift 2 ;;
            --tz)
                require_option_value "$1" "${2-}" 1
                TZ="$2"; shift 2 ;;
            --timer-on-calendar)
                require_option_value "$1" "${2-}"
                TIMER_ON_CALENDAR="$2"; shift 2 ;;
            --timer-random-delay)
                require_option_value "$1" "${2-}"
                TIMER_RANDOM_DELAY="$2"; shift 2 ;;
            --cert-mode)
                require_option_value "$1" "${2-}"
                CERT_MODE="$2"; shift 2 ;;
            --panel-port)
                require_option_value "$1" "${2-}"
                SUI_PANEL_PORT="$2"
                CLI_PANEL_PORT_SET="1"
                shift 2 ;;
            --subscription-port)
                require_option_value "$1" "${2-}"
                SUI_SUBSCRIPTION_PORT="$2"
                CLI_SUBSCRIPTION_PORT_SET="1"
                shift 2 ;;
            --panel-path)
                require_option_value "$1" "${2-}"
                SUI_PANEL_PATH="$2"
                CLI_PANEL_PATH_SET="1"
                shift 2 ;;
            --subscription-path)
                require_option_value "$1" "${2-}"
                SUI_SUBSCRIPTION_PATH="$2"
                CLI_SUBSCRIPTION_PATH_SET="1"
                shift 2 ;;
            --batch)
                BATCH_INSTALL="1"; shift ;;
            --yes)
                AUTO_CONFIRM="1"; shift ;;
            -h|--help)
                show_install_help; exit 0 ;;
            *)
                echo "Unknown option: $1"
                show_install_help
                exit 1
                ;;
        esac
    done

    if [[ "$domain_option_set" == "1" && "$CERT_MODE" != "acme" ]]; then
        die "Option --domain is allowed only together with --cert-mode acme"
    fi
    if [[ "$CLI_IP_CERT_SET" == "1" && "$CERT_MODE" != "acme" ]]; then
        die "Option --ip is allowed only together with --cert-mode acme"
    fi
    if [[ "$domain_option_set" == "1" && "$CLI_IP_CERT_SET" == "1" ]]; then
        die "Options --domain and --ip are mutually exclusive"
    fi
    if [[ "$BATCH_INSTALL" == "1" && "$CERT_MODE" == "acme" && "$domain_option_set" != "1" && "$CLI_IP_CERT_SET" != "1" ]]; then
        die "Non-interactive install with --cert-mode acme requires --domain or --ip"
    fi
}

# ----------------------------------------------------------------------
# Install logic
# ----------------------------------------------------------------------
install_control_script() {
    CURRENT_COMMAND="install"

    _randomize_if_default SUI_PANEL_PORT        "$DEFAULT_SUI_PANEL_PORT"        CLI_PANEL_PORT_SET        ""               generate_random_port 20000 40000
    _randomize_if_default SUI_SUBSCRIPTION_PORT "$DEFAULT_SUI_SUBSCRIPTION_PORT" CLI_SUBSCRIPTION_PORT_SET "$SUI_PANEL_PORT" generate_random_port 20000 40000
    _randomize_if_default SUI_PANEL_PATH        "$DEFAULT_SUI_PANEL_PATH"        CLI_PANEL_PATH_SET        ""               generate_random_path_segment
    _randomize_if_default SUI_SUBSCRIPTION_PATH "$DEFAULT_SUI_SUBSCRIPTION_PATH" CLI_SUBSCRIPTION_PATH_SET "$SUI_PANEL_PATH" generate_random_path_segment

    if [[ "$BATCH_INSTALL" != "1" ]]; then
        cat <<'EOF_BANNER'
 ____  _   _ ___     ____            _             _
/ ___|| | | |_ _|   / ___|___  _ __ | |_ _ __ ___ | |
\___ \| | | || |   | |   / _ \| '_ \| __| '__/ _ \| |
 ___) | |_| || |   | |__| (_) | | | | |_| | | (_) | |
|____/ \___/|___|   \____\___/|_| |_|\__|_|  \___/|_|
EOF_BANNER
        run_interactive_installation_dialog
    fi

    [[ -n "$INSTALL_GENERATED_USERNAME" ]] || INSTALL_GENERATED_USERNAME="$(generate_random_alnum 20)"
    [[ -n "$INSTALL_GENERATED_PASSWORD" ]] || INSTALL_GENERATED_PASSWORD="$(generate_random_alnum 20)"

    prepare_effective_settings
    check_requirements

    check_tcp_port_free "$SUI_PANEL_PORT"        || die "Panel TCP port is already in use: $SUI_PANEL_PORT"
    check_tcp_port_free "$SUI_SUBSCRIPTION_PORT" || die "Subscription TCP port is already in use: $SUI_SUBSCRIPTION_PORT"

    if [[ "$CERT_MODE" == "acme" ]]; then
        local test_image="curlimages/curl:latest"
        local urls=("https://acme-v02.api.letsencrypt.org/directory" "https://www.google.com/generate_204")
        local url connected="0"
        for url in "${urls[@]}"; do
            if docker run --rm "$test_image" -fsSL --connect-timeout 10 --max-time 20 "$url" >/dev/null 2>&1; then
                connected="1"
                break
            fi
        done
        [[ "$connected" == "1" ]] || die "Docker network connectivity check failed for all test endpoints"
    fi

    PACKAGE_DIR="/opt/s-ui"
    resolve_layout

    mkdir -p "$PACKAGE_DIR" \
        "$PACKAGE_DIR/lib" \
        "$PACKAGE_DIR/templates" \
        "$CONFIG_DIR" \
        "$RUNTIME_BIN_DIR" \
        "$RUNTIME_DATA_DIR" \
        "$RUNTIME_CERT_DIR" \
        "$RUNTIME_ACME_DIR" \
        "$RUNTIME_SYSTEMD_DIR"

    # Deploy package files (embedded)
    create_generated_file "$PACKAGE_DIR" "lib/constants.sh"              _embed_lib_constants   "0644" "lib constants"
    create_generated_file "$PACKAGE_DIR" "lib/utils.sh"                  _embed_lib_utils       "0644" "lib utils"
    create_generated_file "$PACKAGE_DIR" "lib/actions.sh"                _embed_lib_actions     "0644" "lib actions"
    create_generated_file "$PACKAGE_DIR" "lib/commands.sh"               _embed_lib_commands    "0644" "lib commands"
    create_generated_file "$PACKAGE_DIR" "sui-control.sh"                _embed_entry_point     "0755" "control script"
    create_generated_file "$PACKAGE_DIR" "templates/acme-cert.sh.tpl"         _embed_tpl_acme_cert "0644" "acme template"
    create_generated_file "$PACKAGE_DIR" "templates/s-ui-db-configure.sh.tpl" _embed_tpl_db_config "0644" "db template"
    create_generated_file "$PACKAGE_DIR" "templates/docker-compose.yml.tpl"   _embed_tpl_compose   "0644" "compose template"
    create_generated_file "$PACKAGE_DIR" "templates/sui-control.conf.tpl"    _embed_tpl_config    "0644" "config template"

    # Write VERSION
    printf '%s\n' "$BUILT_VERSION" > "$PACKAGE_DIR/VERSION"

    # Generate runtime files to CONFIG_DIR / RUNTIME_DIR
    create_generated_file "$CONFIG_DIR" "$COMPOSE_FILE_NAME" _gen_compose ""     "compose file"
    create_generated_file "$CONFIG_DIR" "$CONFIG_FILE_NAME"  _gen_config  "0600" "config file"

    # Generate bin scripts to RUNTIME_BIN_DIR
    if [[ "$CERT_MODE" == "acme" ]]; then
        create_generated_file "$RUNTIME_BIN_DIR" "$ACME_CERT_SCRIPT_NAME" _gen_acme "0755" "acme cert script"
    fi
    create_generated_file "$RUNTIME_BIN_DIR" "$DB_CONFIG_SCRIPT_NAME" _gen_db "0755" "db config script"

    ensure_config_loaded "$CONFIG_DIR/$CONFIG_FILE_NAME"

    local db_script="$RUNTIME_BIN_DIR/$DB_CONFIG_SCRIPT_NAME"
    local db_path="$RUNTIME_DATA_DIR/s-ui.db"
    [[ -x "$db_script" ]] || die "Database configuration script not found: $db_script"

    compose_in_dir "$CONFIG_DIR"
    docker compose up -d --remove-orphans s-ui

    local db_timeout=60 db_elapsed=0
    log_info "Waiting for s-ui to initialize database (up to ${db_timeout}s)..."
    while (( db_elapsed < db_timeout )); do
        [[ -f "$db_path" && -s "$db_path" ]] && break
        sleep 2
        db_elapsed=$(( db_elapsed + 2 ))
    done
    if [[ ! -f "$db_path" || ! -s "$db_path" ]]; then
        docker compose logs --no-color s-ui | tail -n 50 >&2 || true
        die "Database file was not created in time: $db_path"
    fi

    docker compose stop s-ui
    [[ -f "$db_path" ]] || die "Database file not found after first start: $db_path"
    "$db_script" "$INSTALL_GENERATED_USERNAME" "$INSTALL_GENERATED_PASSWORD"
    docker compose up -d --remove-orphans s-ui

    initialize_runtime_artifacts
    install_renewal_timer

    log_info "Installation completed"
    log_info "Generated username: $INSTALL_GENERATED_USERNAME"
    log_info "Generated password: $INSTALL_GENERATED_PASSWORD"
}
