# shellcheck shell=bash
# shellcheck disable=SC2034
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
    print_path_status 'Lib constants'          "$INSTALL_DIR/lib/constants.sh"
    print_path_status 'Lib utils'              "$INSTALL_DIR/lib/utils.sh"
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

    [[ "$(id -u)" -eq 0 ]] || die "This script must be run as root"

    case "$COMMAND" in
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
