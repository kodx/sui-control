# shellcheck shell=bash
# shellcheck disable=SC2034
# .editorconfig hint: indent_style = space, indent_size = 4
# SPDX-License-Identifier: GPL-3.0-or-later
# CLI commands and entry point

# ----------------------------------------------------------------------
# Usage
# ----------------------------------------------------------------------
show_usage() {
    local ver="?"
    [[ -f "$PACKAGE_DIR/VERSION" ]] && ver="$(cat "$PACKAGE_DIR/VERSION")"
    printf 'SUI-Control version %s\n\n' "$ver"
    cat <<'EOF_USAGE'
SUI-Control installs, configures and maintains an s-ui deployment with Docker Compose.

Usage:
  sui-control.sh <command> [options]

Commands:
  start                         Start containers.
  stop                          Stop containers.
  restart                       Restart containers.
  renew                         Renew certificates immediately.
  status                        Show current installation status.
  init                          Re-initialize runtime artifacts (regenerate certs, restart).
  service-install               Install and enable timer/service for certificate renewal.
  service-remove                Remove renewal timer/service.
  update                        Pull newer container images and restart services.
  cleanup                       Remove unused Docker containers and dangling images.
  cleanup-all                   Remove unused Docker containers and all unused images.
  uninstall                     Stop containers and remove installed files.

Options:
  --domain DOMAIN               Public domain for ACME mode; ignored for selfsigned.
  --ip IP                       Public IP for ACME (~6-day short-lived cert).
  --tz TZ                       Time zone written to s-ui settings, optional.
  --timer-on-calendar SPEC      systemd OnCalendar value for renew timer.
  --timer-random-delay SPEC     systemd RandomizedDelaySec value for renew timer.
  --cert-mode MODE              Certificate mode: selfsigned or acme.
  --panel-port PORT             Panel port exposed by docker-compose.
  --subscription-port PORT      Subscription port exposed by docker-compose.
  --panel-path PATH             URL path prefix for panel, without leading slash.
  --subscription-path PATH      URL path prefix for subscriptions, without leading slash.
  --yes                         Skip confirmation prompts where possible.
  -h, --help                    Show this help message.
EOF_USAGE
}

# ----------------------------------------------------------------------
# Status display
# ----------------------------------------------------------------------
show_status() {
    ensure_config_loaded
    echo 'Installation:'
    echo "Config dir: $CONFIG_DIR"
    echo "Runtime dir: $RUNTIME_DIR"
    echo "Package dir: $PACKAGE_DIR"
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
    print_path_status 'Config file'           "$CONFIG_DIR/$CONFIG_FILE_NAME"
    print_path_status 'Compose file'          "$CONFIG_DIR/$COMPOSE_FILE_NAME"
    print_path_status 'Control script'        "$PACKAGE_DIR/$SELF_SCRIPT_NAME"
    print_path_status 'Lib constants'         "$PACKAGE_DIR/lib/constants.sh"
    print_path_status 'Lib utils'             "$PACKAGE_DIR/lib/utils.sh"
    print_path_status 'DB config script'      "$RUNTIME_BIN_DIR/$DB_CONFIG_SCRIPT_NAME"
    print_path_status 'Data directory'        "$RUNTIME_DATA_DIR"
    print_path_status 'Certificate directory' "$RUNTIME_CERT_DIR"
    if [[ "$CERT_MODE" == "acme" ]]; then
        print_path_status 'ACME cert script'  "$RUNTIME_BIN_DIR/$ACME_CERT_SCRIPT_NAME"
        print_path_status 'ACME directory'    "$RUNTIME_ACME_DIR"
    fi
    echo
    echo 'Certificate:'
    local cert_base cert_self key_file crt_file
    cert_base="$RUNTIME_CERT_DIR"
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
            if [[ -f "$CONFIG_DIR/$COMPOSE_FILE_NAME" ]]; then
                echo
                echo 'Docker compose config:'
                (cd "$CONFIG_DIR" && docker compose config --services) || true
                echo
                echo 'Docker compose status:'
                (cd "$CONFIG_DIR" && docker compose ps -a) || true
            fi
        else
            echo 'Docker compose: unavailable'
        fi
    fi
    echo
    echo 'Service status:'
    detect_init_system
    echo "Init system: $INIT_SYSTEM"
    case "$INIT_SYSTEM" in
        systemd)
            if command_exists systemctl; then
                echo "Control service: $(systemctl is-active "$SYSTEMD_CONTROL_SERVICE_NAME" 2>/dev/null || echo unknown)"
                echo "Renew timer (enabled): $(systemctl is-enabled "$SYSTEMD_RENEW_TIMER_NAME" 2>/dev/null || echo unknown)"
                echo "Renew timer (active):  $(systemctl is-active  "$SYSTEMD_RENEW_TIMER_NAME" 2>/dev/null || echo unknown)"
            fi
            ;;
        openrc)
            if command_exists rc-service; then
                echo "Service: $(rc-service sui-control status 2>/dev/null || echo 'check rc-service')"
            fi
            ;;
        runit)
            if command_exists sv; then
                echo "Service: $(sv status sui-control 2>/dev/null || echo 'check sv status')"
            fi
            ;;
        s6)
            if command_exists s6-svstat; then
                echo "Service: $(s6-svstat "$S6_SERVICE_DIR" 2>/dev/null || echo 'check s6-svstat')"
            fi
            ;;
        dinit)
            if command_exists dinitctl; then
                echo "Service: $(dinitctl status sui-control 2>/dev/null || echo 'check dinitctl')"
            fi
            ;;
        *)
            echo "Service: no supported init system detected"
            ;;
    esac
}

# ----------------------------------------------------------------------
# Container and image lifecycle
# ----------------------------------------------------------------------
update_containers() {
    ensure_config_loaded
    compose_in_dir "$CONFIG_DIR"
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
    [[ -d "$CONFIG_DIR" ]]   || die "Config directory not found: $CONFIG_DIR"
    [[ -f "$CONFIG_DIR/$CONFIG_FILE_NAME" ]] || die "Config file not found: $CONFIG_DIR/$CONFIG_FILE_NAME"
    [[ -f "$CONFIG_DIR/$COMPOSE_FILE_NAME" ]] || die "Compose file not found: $CONFIG_DIR/$COMPOSE_FILE_NAME"
    load_install_config "$CONFIG_DIR/$CONFIG_FILE_NAME"
    if [[ "$AUTO_CONFIRM" != "1" ]]; then
        prompt_yes_no "Remove s-ui installation?" 'n' \
            || { log_info "Uninstall cancelled"; return; }
    fi
    if docker info >/dev/null 2>&1; then
        (cd "$CONFIG_DIR" && docker compose down -v --remove-orphans) || true
    else
        log_warn "Docker daemon not reachable — skip container cleanup"
    fi
    rm -rf -- "$RUNTIME_DIR" "$CONFIG_DIR"
    remove_renewal_timer
    log_info "Installation data removed"
    log_info "Package at $PACKAGE_DIR was not removed (remove manually if desired)"
}

# ----------------------------------------------------------------------
# Entry point
# ----------------------------------------------------------------------
dispatch_command() {
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
    PACKAGE_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
    resolve_layout

    if [[ $# -lt 1 ]]; then
        show_usage
        exit 1
    fi

    local original_args=("$@")

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
    if [[ "$CLI_IP_CERT_SET" == "1" && "$CERT_MODE" != "acme" ]]; then
        die "Option --ip is allowed only together with --cert-mode acme"
    fi
    if [[ "$domain_option_set" == "1" && "$CLI_IP_CERT_SET" == "1" ]]; then
        die "Options --domain and --ip are mutually exclusive"
    fi

    case "$COMMAND" in
        start)
            CURRENT_COMMAND="start"
            require_docker_access
            ensure_config_loaded
            start_containers
            ;;
        stop)
            CURRENT_COMMAND="stop"
            require_docker_access
            ensure_config_loaded
            stop_containers
            ;;
        restart)
            CURRENT_COMMAND="restart"
            require_docker_access
            ensure_config_loaded
            restart_containers
            ;;
        renew)
            CURRENT_COMMAND="renew"
            require_docker_access
            ensure_config_loaded
            check_requirements
            renew_certificate
            ;;
        renew-now)
            log_warn "renew-now is deprecated; use 'renew' instead"
            CURRENT_COMMAND="renew"
            require_docker_access
            ensure_config_loaded
            check_requirements
            renew_certificate
            ;;
        init)
            CURRENT_COMMAND="init"
            require_docker_access
            ensure_config_loaded
            check_requirements
            initialize_runtime_artifacts
            ;;
        status)
            CURRENT_COMMAND="status"
            show_status
            ;;
        service-install)
            CURRENT_COMMAND="service-install"
            if [[ "$(id -u)" -ne 0 ]]; then
                maybe_escalate_privileges "${original_args[@]}"
            fi
            ensure_config_loaded
            install_renewal_timer
            ;;
        service-remove)
            CURRENT_COMMAND="service-remove"
            if [[ "$(id -u)" -ne 0 ]]; then
                maybe_escalate_privileges "${original_args[@]}"
            fi
            ensure_config_loaded
            remove_renewal_timer
            ;;
        update)
            CURRENT_COMMAND="update"
            require_docker_access
            ensure_config_loaded
            check_requirements
            update_containers
            ;;
        cleanup)
            CURRENT_COMMAND="cleanup"
            require_docker_access
            require_command docker
            cleanup_docker_artifacts
            ;;
        cleanup-all)
            CURRENT_COMMAND="cleanup-all"
            require_docker_access
            require_command docker
            cleanup_docker_artifacts 1
            ;;
        uninstall)
            CURRENT_COMMAND="uninstall"
            if [[ "$(id -u)" -ne 0 ]]; then
                maybe_escalate_privileges "${original_args[@]}"
            fi
            uninstall_control_script
            ;;
        *)
            log_error "Unknown command: $COMMAND"
            show_usage
            exit 1
            ;;
    esac
}
