# shellcheck shell=bash
# .editorconfig hint: indent_style = space, indent_size = 4
# SPDX-License-Identifier: GPL-3.0-or-later
# CLI commands and entry point

# ----------------------------------------------------------------------
# Usage
# ----------------------------------------------------------------------
show_usage() {
    printf 'SUI-Control version %s\n\n' "$SCRIPT_VERSION"
    cat <<'EOF_USAGE'
SUI-Control installs, configures and maintains an s-ui deployment with Docker Compose.

Usage:
  sui-control.sh <command> [options]

Commands:
  install                       Install or reinstall s-ui into the target directory.
  init                          Re-initialize runtime artifacts for an existing installation (regenerate certs, restart).
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
  --domain DOMAIN               Public domain for ACME mode; ignored for selfsigned.
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
EOF_USAGE
}

# ----------------------------------------------------------------------
# Status display
# ----------------------------------------------------------------------
show_status() {
    local install_dir="$1"
    local resolved_bin_dir resolved_data_dir resolved_cert_dir resolved_acme_dir
    ensure_config_loaded "$install_dir"
# shellcheck disable=SC2153
    resolved_bin_dir="$(resolve_path "$INSTALL_DIR" "$BIN_DIR")"
    resolved_data_dir="$(resolve_path "$INSTALL_DIR" "$DATA_DIR")"
    resolved_cert_dir="$(resolve_path "$INSTALL_DIR" "$CERT_DIR")"
    resolved_acme_dir="$(resolve_path "$INSTALL_DIR" "$ACME_DIR")"
    echo 'Installation:'
    echo "Install dir: $INSTALL_DIR"
    echo "Certificate mode: $CERT_MODE"
    echo "Domain: $DOMAIN"
    echo "Time zone: $TZ"
    echo "Timer OnCalendar: $TIMER_ON_CALENDAR"
    echo "Timer RandomizedDelaySec: $TIMER_RANDOM_DELAY"
    echo "Panel port: $SUI_PANEL_PORT"
    echo "Subscription port: $SUI_SUBSCRIPTION_PORT"
    echo "Panel path: /$SUI_PANEL_PATH/"
    echo "Subscription path: /$SUI_SUBSCRIPTION_PATH/"
    echo "Panel URL: https://$DOMAIN:$SUI_PANEL_PORT/$SUI_PANEL_PATH/"
    echo "Subscription base URL: https://$DOMAIN:$SUI_SUBSCRIPTION_PORT/$SUI_SUBSCRIPTION_PATH/"
    echo
    echo 'Files and directories:'
    print_path_status 'Install directory'      "$INSTALL_DIR"
    print_path_status 'Compose file'           "$INSTALL_DIR/$COMPOSE_FILE_NAME"
    print_path_status 'Config file'            "$INSTALL_DIR/$CONFIG_FILE_NAME"
    print_path_status 'Control script'         "$INSTALL_DIR/$SELF_SCRIPT_NAME"
    print_path_status 'Helper library'         "$resolved_bin_dir/$HELPER_LIB_NAME"
    print_path_status 'DB config script'       "$resolved_bin_dir/$DB_CONFIG_SCRIPT_NAME"
    print_path_status 'Data directory'         "$resolved_data_dir"
    print_path_status 'Certificate directory'  "$resolved_cert_dir"
    if [[ "$CERT_MODE" == "acme" ]]; then
        print_path_status 'ACME cert script'   "$resolved_bin_dir/$ACME_CERT_SCRIPT_NAME"
        print_path_status 'ACME directory'     "$resolved_acme_dir"
        print_path_status 'Local timer unit'   "$INSTALL_DIR/$SYSTEMD_DIR_NAME/$SYSTEMD_TIMER_NAME"
        print_path_status 'Local service unit' "$INSTALL_DIR/$SYSTEMD_DIR_NAME/$SYSTEMD_SERVICE_NAME"
    fi
    echo
    echo 'Certificate:'
    local cert_base cert_self key_file crt_file
    cert_base="$resolved_cert_dir"
    cert_self="$cert_base/$SELF_SIGNED_DIR_NAME"
    echo "Certificate directory: $cert_base"
    echo "Certificate storage mode: $CERT_MODE"
    if [[ "$CERT_MODE" == "selfsigned" ]]; then
        key_file="$cert_self/privkey.pem"
        crt_file="$cert_self/fullchain.pem"
    else
        key_file="$cert_base/server.key"
        crt_file="$cert_base/server.crt"
    fi
    echo "Certificate key: $key_file"
    echo "Certificate crt: $crt_file"
    if [[ -f "$crt_file" ]]; then
        echo 'Certificate present: yes'
    else
        echo 'Certificate present: no'
    fi
    echo
    echo 'Docker status:'
    if ! docker info >/dev/null 2>&1; then
        echo 'Docker daemon: unavailable'
    else
        echo 'Docker daemon: reachable'
        if docker compose version >/dev/null 2>&1; then
            echo 'Docker compose: available'
            if [[ -f "$install_dir/$COMPOSE_FILE_NAME" ]]; then
                echo
                echo 'Docker compose config:'
                (cd "$install_dir" && docker compose config --services) || true
                echo
                echo 'Docker compose status:'
                (cd "$install_dir" && docker compose ps -a) || true
            fi
        else
            echo 'Docker compose: unavailable'
        fi
    fi
    if [[ "$CERT_MODE" == "acme" ]]; then
        echo
        echo 'Systemd renewal status:'
        if ! command_exists systemctl; then
            echo 'systemctl: unavailable'
        else
            echo "Timer enabled:  $(systemctl is-enabled "$SYSTEMD_TIMER_NAME"  2>/dev/null || echo unknown)"
            echo "Timer active:   $(systemctl is-active  "$SYSTEMD_TIMER_NAME"  2>/dev/null || echo unknown)"
            echo "Service active: $(systemctl is-active  "$SYSTEMD_SERVICE_NAME" 2>/dev/null || echo unknown)"
        fi
    fi
}

# ----------------------------------------------------------------------
# Container and image lifecycle
# ----------------------------------------------------------------------
update_containers() {
    local install_dir="$1"
    ensure_config_loaded "$install_dir"
    cd "$INSTALL_DIR" || die "Cannot cd to $INSTALL_DIR"
    docker compose pull
    docker compose up -d --remove-orphans
}

cleanup_docker_artifacts() {
    local prune_all="${1:-0}"
    docker container prune -f
    if [[ "$prune_all" == "1" ]]; then
        docker image prune -a -f
    else
        docker image prune -f
    fi
}

# ----------------------------------------------------------------------
# Uninstall
# ----------------------------------------------------------------------
uninstall_control_script() {
    local install_dir="$1"
    [[ -d "$install_dir" ]]                         || die "Install directory not found: $install_dir"
    [[ -f "$install_dir/$CONFIG_FILE_NAME" ]]        || die "Config file not found: $install_dir/$CONFIG_FILE_NAME"
    [[ "$install_dir" != "/" ]]                      || die "Refusing to uninstall from /"
    [[ -f "$install_dir/$COMPOSE_FILE_NAME" ]]       || die "Compose file not found: $install_dir/$COMPOSE_FILE_NAME"
    [[ -f "$install_dir/$SELF_SCRIPT_NAME" ]]        || die "Control script not found: $install_dir/$SELF_SCRIPT_NAME"
    load_install_config "$install_dir"
    if [[ "$AUTO_CONFIRM" != "1" ]]; then
        prompt_yes_no "Remove installation from $INSTALL_DIR?" 'n' \
            || { log_info "Uninstall cancelled"; return; }
    fi
    remove_systemd_timer "$INSTALL_DIR"
    (cd "$INSTALL_DIR" && docker compose down -v --remove-orphans) || true
    rm -rf -- "$INSTALL_DIR"
    log_info "Installation removed: $INSTALL_DIR"
}

# ----------------------------------------------------------------------
# Install
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

    local bin_dir
    bin_dir="$(resolve_path "$INSTALL_DIR" "$BIN_DIR")"
    mkdir -p "$INSTALL_DIR" \
        "$bin_dir" \
        "$(resolve_path "$INSTALL_DIR" "$DATA_DIR")" \
        "$(resolve_path "$INSTALL_DIR" "$CERT_DIR")" \
        "$(resolve_path "$INSTALL_DIR" "$ACME_DIR")"

    create_generated_file "$INSTALL_DIR" "$COMPOSE_FILE_NAME" _gen_compose ""     "compose file"
    create_generated_file "$INSTALL_DIR" "$CONFIG_FILE_NAME"  _gen_config  "0600" "config file"

    local self_file="$INSTALL_DIR/$SELF_SCRIPT_NAME"
    log_info "Installing control script at: $self_file"
    if [[ -r "$SCRIPT_PATH" && ! -d "$SCRIPT_PATH" ]]; then
        cat "$SCRIPT_PATH" > "$self_file"
    elif [[ -r "/proc/$$/fd/255" ]]; then
        cat "/proc/$$/fd/255" > "$self_file"
    elif [[ -r "/dev/fd/255" ]]; then
        cat "/dev/fd/255" > "$self_file"
    else
        die "Cannot access the running script contents to copy itself"
    fi
    [[ -s "$self_file" ]] || die "Failed to copy script to $self_file (empty file)"
    chmod 0755 "$self_file"

    create_generated_file "$bin_dir" "$HELPER_LIB_NAME"     _gen_lib  "0755" "helper library"

    if [[ "$CERT_MODE" == "acme" ]]; then
        create_generated_file "$bin_dir" "$ACME_CERT_SCRIPT_NAME" _gen_acme "0755" "acme cert script"
    else
        rm -f "$bin_dir/$ACME_CERT_SCRIPT_NAME"
    fi

    create_generated_file "$bin_dir" "$DB_CONFIG_SCRIPT_NAME" _gen_db "0755" "db config script"

    ensure_config_loaded "$INSTALL_DIR"

    local db_script="$bin_dir/$DB_CONFIG_SCRIPT_NAME"
    local db_path
    db_path="$(resolve_path "$INSTALL_DIR" "$DATA_DIR")/s-ui.db"
    [[ -x "$db_script" ]] || die "Database configuration script not found: $db_script"

    cd "$INSTALL_DIR" || die "Cannot cd to $INSTALL_DIR"
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

    initialize_runtime_artifacts "$INSTALL_DIR"
    install_systemd_timer "$INSTALL_DIR"

    log_info "Installation completed"
    log_info "Generated username: $INSTALL_GENERATED_USERNAME"
    log_info "Generated password: $INSTALL_GENERATED_PASSWORD"
}

# ----------------------------------------------------------------------
# Entry point
# ----------------------------------------------------------------------
main() {
    local source_path="$SCRIPT_ARG0"
    if [[ ! -r "$source_path" || -d "$source_path" ]]; then
        if [[ -r "/proc/$$/fd/255" ]]; then
            source_path="/proc/$$/fd/255"
        elif [[ -r "/dev/fd/255" ]]; then
            source_path="/dev/fd/255"
        fi
    fi
    [[ "$source_path" == /* ]] || source_path="$PWD/$source_path"
    SCRIPT_PATH="$source_path"
    # shellcheck disable=SC2034
    SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"

    if [[ $# -lt 1 ]]; then
        show_usage
        exit 1
    fi

    COMMAND="$1"
    if [[ "$COMMAND" == "help" ]]; then
        shift
        [[ $# -eq 0 ]] || die "Help does not accept additional arguments"
        show_usage
        exit 0
    fi
    shift

    local domain_option_set="0"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --install-dir)
                require_option_value "$1" "${2-}"
                INSTALL_DIR="$2"; shift 2 ;;
            --domain)
                require_option_value "$1" "${2-}"
                DOMAIN="$2"; domain_option_set="1"; shift 2 ;;
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
                # shellcheck disable=SC2034
                CLI_PANEL_PORT_SET="1"
                shift 2 ;;
            --subscription-port)
                require_option_value "$1" "${2-}"
                SUI_SUBSCRIPTION_PORT="$2"
                # shellcheck disable=SC2034
                CLI_SUBSCRIPTION_PORT_SET="1"
                shift 2 ;;
            --panel-path)
                require_option_value "$1" "${2-}"
                SUI_PANEL_PATH="$2"
                # shellcheck disable=SC2034
                CLI_PANEL_PATH_SET="1"
                shift 2 ;;
            --subscription-path)
                require_option_value "$1" "${2-}"
                SUI_SUBSCRIPTION_PATH="$2"
                # shellcheck disable=SC2034
                CLI_SUBSCRIPTION_PATH_SET="1"
                shift 2 ;;
            --batch)
                BATCH_INSTALL="1"; shift ;;
            --yes)
                AUTO_CONFIRM="1"; shift ;;
            -h|--help)
                show_usage; exit 0 ;;
            *)
                die "Unknown option: $1" ;;
        esac
    done

    if [[ "$domain_option_set" == "1" && "$CERT_MODE" != "acme" ]]; then
        die "Option --domain is allowed only together with --cert-mode acme"
    fi
    if [[ "$COMMAND" == "install" && "$BATCH_INSTALL" == "1" \
            && "$CERT_MODE" == "acme" && "$domain_option_set" != "1" ]]; then
        die "Non-interactive install with --cert-mode acme requires explicit --domain"
    fi

    [[ "$(id -u)" -eq 0 ]] || die "This script must be run as root"

    case "$COMMAND" in
        install)
            install_control_script
            ;;
        init)
            CURRENT_COMMAND="init"
            ensure_config_loaded "$(get_runtime_install_dir)"
            check_requirements
            initialize_runtime_artifacts "$(get_runtime_install_dir)"
            ;;
        renew-now)
            CURRENT_COMMAND="renew-now"
            ensure_config_loaded "$(get_runtime_install_dir)"
            check_requirements
            renew_certificate "$(get_runtime_install_dir)"
            ;;
        status)
            CURRENT_COMMAND="status"
            show_status "$(get_runtime_install_dir)"
            ;;
        service-install)
            CURRENT_COMMAND="service-install"
            install_systemd_timer "$(get_runtime_install_dir)"
            ;;
        service-remove)
            CURRENT_COMMAND="service-remove"
            remove_systemd_timer "$(get_runtime_install_dir)"
            ;;
        update)
            CURRENT_COMMAND="update"
            ensure_config_loaded "$(get_runtime_install_dir)"
            check_requirements
            update_containers "$(get_runtime_install_dir)"
            ;;
        cleanup)
            CURRENT_COMMAND="cleanup"
            require_command docker
            cleanup_docker_artifacts
            ;;
        cleanup-all)
            CURRENT_COMMAND="cleanup-all"
            require_command docker
            cleanup_docker_artifacts 1
            ;;
        uninstall)
            # shellcheck disable=SC2034
            CURRENT_COMMAND="uninstall"
            uninstall_control_script "$(get_runtime_install_dir)"
            ;;
        *)
            log_error "Unknown command: $COMMAND"
            show_usage
            exit 1
            ;;
    esac
}
