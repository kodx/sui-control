# shellcheck shell=bash
# .editorconfig hint: indent_style = space, indent_size = 4
# SPDX-License-Identifier: GPL-3.0-or-later
# Shared utility functions (single source of truth for installed scripts)

# ----------------------------------------------------------------------
# Layout resolution
# ----------------------------------------------------------------------
# shellcheck disable=SC2034
resolve_layout() {
    if [[ "$PACKAGE_DIR" == /usr/lib/* ]] || [[ "$PACKAGE_DIR" == /usr/local/lib/* ]]; then
        CONFIG_DIR="/etc/sui-control"
        RUNTIME_DIR="/var/lib/sui-control"
    else
        CONFIG_DIR="$PACKAGE_DIR"
        RUNTIME_DIR="$PACKAGE_DIR"
    fi
    RUNTIME_BIN_DIR="$RUNTIME_DIR/bin"
    RUNTIME_SYSTEMD_DIR="$RUNTIME_DIR/systemd"
    RUNTIME_DATA_DIR="$RUNTIME_DIR/db"
    RUNTIME_CERT_DIR="$RUNTIME_DIR/cert"
    RUNTIME_ACME_DIR="$RUNTIME_DIR/acme"
}

# ----------------------------------------------------------------------
# Core requirement checks
# ----------------------------------------------------------------------
check_core_requirements() {
    require_command docker sqlite3
}

# ----------------------------------------------------------------------
# Privilege escalation
# ----------------------------------------------------------------------
maybe_escalate_privileges() {
    [[ "$(id -u)" -eq 0 ]] && return 0
    if command_exists sudo; then
        log_info "Escalating privileges via sudo"
        exec sudo "$0" "$@"
    elif command_exists doas; then
        log_info "Escalating privileges via doas"
        exec doas "$0" "$@"
    else
        die "This command requires root privileges. Run with sudo/doas or as root."
    fi
}


# ----------------------------------------------------------------------
# Logging
# ----------------------------------------------------------------------
log_message() {
    local level="$1"
    local color="$2"
    local stream="$3"
    shift 3
    if [[ "$stream" == "stderr" ]]; then
        printf '%b[%s]%b %s\n' "$color" "$level" "$COLOR_RESET" "$*" >&2
    else
        printf '%b[%s]%b %s\n' "$color" "$level" "$COLOR_RESET" "$*"
    fi
}

log_info() {
    log_message "INFO" "$COLOR_INFO" "stdout" "$@"
}

log_warn() {
    log_message "WARN" "$COLOR_WARN" "stderr" "$@"
}

log_error() {
    log_message "ERROR" "$COLOR_ERROR" "stderr" "$@"
}

die() {
    log_error "$@"
    exit 1
}

on_error() {
    local exit_code="$1" line_no="$2" command_text="$3"
    log_error "Command failed in '${CURRENT_COMMAND:-unknown}' at line $line_no: $command_text"
    exit "$exit_code"
}
trap 'on_error $? $LINENO "$BASH_COMMAND"' ERR

# ----------------------------------------------------------------------
# Generic utilities
# ----------------------------------------------------------------------
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

require_command() {
    local cmd
    for cmd in "$@"; do
        command_exists "$cmd" || die "Required command not found: $cmd"
    done
}

is_ipv4() {
    [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && return 0 || return 1
}

is_ipv6() {
    local s="$1" part colons
    [[ -n "$s" ]] || return 1
    [[ "$s" =~ ^[0-9a-fA-F:]+$ ]] || return 1
    [[ "$s" != *:::* ]] || return 1
    colons="${s//[^:]/}"
    if [[ "$s" == *::* ]]; then
        (( ${#colons} <= 7 )) || return 1
    else
        (( ${#colons} == 7 )) || return 1
    fi
    IFS=':' read -r -a parts <<< "$s"
    for part in "${parts[@]}"; do
        [[ -z "$part" || ${#part} -le 4 ]] || return 1
    done
    return 0
}

is_ip() {
    is_ipv4 "$1" || is_ipv6 "$1"
}

get_file_owner_uid() {
    local path="$1"
    local owner_uid=""
    if ! command_exists stat; then
        printf '%s\n' ''
        return
    fi
    owner_uid="$(stat -c %u "$path" 2>/dev/null || true)"
    if [[ -n "$owner_uid" ]]; then
        printf '%s\n' "$owner_uid"
        return
    fi
    owner_uid="$(stat -f %u "$path" 2>/dev/null || true)"
    printf '%s\n' "$owner_uid"
}

trim_ascii_whitespace() {
    local -n _trim_ref="$1"
    _trim_ref="${_trim_ref#"${_trim_ref%%[![:space:]]*}"}"
    _trim_ref="${_trim_ref%"${_trim_ref##*[![:space:]]}"}"
}

# ----------------------------------------------------------------------
# Config parsing
# ----------------------------------------------------------------------
validate_simple_conf_value() {
    local key="$1"
    local value="$2"
    [[ "$value" != *=* ]]      || die "Unsupported '=' in config value for $key"
    [[ "$value" != *$'\n'* ]]  || die "Unsupported newline in config value for $key"
}

# shellcheck disable=SC2034
assign_config_value() {
    local key="$1" value="$2"
    case "$key" in
        domain)              DOMAIN="$value" ;;
        tz)                  TZ="$value" ;;
        timer_on_calendar)   TIMER_ON_CALENDAR="$value" ;;
        timer_random_delay)  TIMER_RANDOM_DELAY="$value" ;;
        cert_mode)           CERT_MODE="$value" ;;
        self_signed_days)    SELF_SIGNED_DAYS="$value" ;;
        panel_port)          SUI_PANEL_PORT="$value" ;;
        subscription_port)   SUI_SUBSCRIPTION_PORT="$value" ;;
        panel_path)          SUI_PANEL_PATH="$value" ;;
        subscription_path)   SUI_SUBSCRIPTION_PATH="$value" ;;
        init_system)
            case "$value" in
                auto|systemd|openrc|runit|s6|dinit) INIT_SYSTEM="$value" ;;
                *) die "Unsupported init_system in config: $value (expected: auto, systemd, openrc, runit, s6, dinit)" ;;
            esac
            ;;
        inbound_ports)      INBOUND_PORTS="$value" ;;
        sui_image)           SUI_IMAGE="$value" ;;
        curl_test_image)     CURL_TEST_IMAGE="$value" ;;
        container_stamp)     CONTAINER_STAMP="$value" ;;
        *) die "Unsupported config key in $CONFIG_FILE_NAME: $key" ;;
    esac
}

# ----------------------------------------------------------------------
# File ownership helper
# ----------------------------------------------------------------------
ensure_file_ownership() {
    [[ "$(id -u)" -eq 0 ]] || return 0
    log_info "Setting ownership of runtime files to $SUI_CONTROL_USER:$SUI_CONTROL_USER"
    chown -R "$SUI_CONTROL_USER:$SUI_CONTROL_USER" "$@" 2>/dev/null || true
}

parse_config_file() {
    local config_file="$1"
    local line key value
    [[ -f "$config_file" ]]  || die "Config file not found: $config_file"
    [[ ! -L "$config_file" ]] || die "Refusing to load symlinked config file: $config_file"
    local owner_uid
    owner_uid="$(get_file_owner_uid "$config_file")"
    if [[ -n "$owner_uid" && "$owner_uid" != "0" ]]; then
        local expected_uid
        expected_uid="$(id -u "$SUI_CONTROL_USER" 2>/dev/null || echo '')"
        [[ -n "$expected_uid" && "$owner_uid" == "$expected_uid" ]] \
            || die "Config file must be owned by root or $SUI_CONTROL_USER: $config_file"
    fi
    while IFS= read -r line || [[ -n "$line" ]]; do
        trim_ascii_whitespace line
        [[ -n "$line" ]]      || continue
        [[ "$line" == \#* ]]  && continue
        key="${line%%=*}"
        value="${line#*=}"
        trim_ascii_whitespace key
        trim_ascii_whitespace value
        [[ -n "$key" ]] || continue
        validate_simple_conf_value "$key" "$value"
        assign_config_value "$key" "$value"
    done < "$config_file"
}

# ----------------------------------------------------------------------
# Random value generators
# ----------------------------------------------------------------------
generate_random_alnum() {
    local length="$1"
    local value status
    set +o pipefail
    value="$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c "$length")"
    status=$?
    set -o pipefail
    [[ "$status" -eq 0 && -n "$value" ]] || die "Failed to generate random value"
    printf '%s\n' "$value"
}

generate_random_path_segment() {
    local value
    set +o pipefail
    value="$(LC_ALL=C tr -dc 'a-z0-9' < /dev/urandom | head -c 20)"
    set -o pipefail
    [[ -n "$value" ]] || die "Failed to generate random path segment"
    printf '%s\n' "$value"
}

# ----------------------------------------------------------------------
# Docker helpers
# ----------------------------------------------------------------------
check_tcp_port_free() {
    local port="$1"
    if command_exists ss; then
        if ss -ltn | awk -v p=":$port" 'NR>1 && $4 ~ p "$" {found=1} END{exit found?0:1}'; then
            return 1
        fi
        return 0
    fi
    if command_exists lsof; then
        if lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; then
            return 1
        fi
        return 0
    fi
    return 0
}

check_port_80_free() {
    check_tcp_port_free 80 || die "TCP port 80 is already in use"
}


restart_sui_container() {
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx 's-ui'; then
        log_info "Restarting s-ui container"
        docker stop s-ui >/dev/null 2>&1 || true
        docker rm s-ui >/dev/null 2>&1 || true
    else
        log_info "Starting s-ui container"
    fi
    start_containers
    if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -qx 's-ui'; then
        docker logs s-ui 2>/dev/null | tail -n 50 >&2 || true
        die "s-ui container is not running after restart"
    fi
}

stop_sui_container_if_running() {
    docker stop s-ui >/dev/null 2>&1 || true
}

ensure_acme_mode() {
    [[ "$CERT_MODE" == "acme" ]] || die "This script requires acme certificate mode; current mode: $CERT_MODE"
}
