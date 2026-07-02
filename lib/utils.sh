# shellcheck shell=bash
# .editorconfig hint: indent_style = space, indent_size = 4
# SPDX-License-Identifier: GPL-3.0-or-later
# Shared utility functions (single source of truth for installed scripts)

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
    [[ "$1" =~ : ]] && return 0 || return 1
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
        install_dir)       INSTALL_DIR="$value" ;;
        domain)            DOMAIN="$value" ;;
        tz)                TZ="$value" ;;
        data_dir)          DATA_DIR="$value" ;;
        cert_dir)          CERT_DIR="$value" ;;
        acme_dir)          ACME_DIR="$value" ;;
        bin_dir)           BIN_DIR="$value" ;;
        systemd_dst_dir)   SYSTEMD_DST_DIR="$value" ;;
        timer_on_calendar) TIMER_ON_CALENDAR="$value" ;;
        timer_random_delay) TIMER_RANDOM_DELAY="$value" ;;
        cert_mode)         CERT_MODE="$value" ;;
        self_signed_days)  SELF_SIGNED_DAYS="$value" ;;
        panel_port)        SUI_PANEL_PORT="$value" ;;
        subscription_port) SUI_SUBSCRIPTION_PORT="$value" ;;
        panel_path)        SUI_PANEL_PATH="$value" ;;
        subscription_path) SUI_SUBSCRIPTION_PATH="$value" ;;
        *) die "Unsupported config key in $CONFIG_FILE_NAME: $key" ;;
    esac
}

parse_config_file() {
    local config_file="$1"
    local line key value
    [[ -f "$config_file" ]]  || die "Config file not found: $config_file"
    [[ ! -L "$config_file" ]] || die "Refusing to load symlinked config file: $config_file"
    local owner_uid
    owner_uid="$(get_file_owner_uid "$config_file")"
    [[ -z "$owner_uid" || "$owner_uid" == "0" ]] \
        || die "Config file must be owned by root: $config_file"
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

load_config_relative() {
    local script_dir="$1"
    local config_file="$script_dir/../$CONFIG_FILE_NAME"
    [[ -f "$config_file" ]] || config_file="$script_dir/$CONFIG_FILE_NAME"
    parse_config_file "$config_file"
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

compose_in_install_dir() {
    cd "$INSTALL_DIR" || die "Cannot cd to $INSTALL_DIR"
    [[ -f "$COMPOSE_FILE_NAME" ]] || die "Compose file not found: $INSTALL_DIR/$COMPOSE_FILE_NAME"
}

restart_sui_container() {
    cd "$INSTALL_DIR" || die "Cannot cd to $INSTALL_DIR"
    if docker compose ps --status running --services 2>/dev/null | grep -qx 's-ui'; then
        log_info "Restarting s-ui container"
        docker compose restart s-ui
    else
        log_info "Starting s-ui container"
        docker compose up -d --remove-orphans s-ui
    fi
    if ! docker compose ps --status running --services 2>/dev/null | grep -qx 's-ui'; then
        docker compose logs --no-color s-ui | tail -n 50 >&2 || true
        die "s-ui container is not running after restart"
    fi
}

stop_sui_container_if_running() {
    cd "$INSTALL_DIR" || die "Cannot cd to $INSTALL_DIR"
    docker compose stop s-ui >/dev/null 2>&1 || true
}

ensure_acme_mode() {
    [[ "$CERT_MODE" == "acme" ]] || die "This script requires acme certificate mode; current mode: $CERT_MODE"
}
