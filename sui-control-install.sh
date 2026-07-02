#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2154,SC2153
# SPDX-License-Identifier: GPL-3.0-or-later
# Built by sui-control build.sh — v1.4.0
set -euo pipefail

readonly BUILT_VERSION='1.4.0'

# === EMBEDDED PROJECT FILES ===
_embed_lib_constants() {
    cat <<'EOF__lib_constants'
# shellcheck shell=bash
# .editorconfig hint: indent_style = space, indent_size = 4
# SPDX-License-Identifier: GPL-3.0-or-later
# shellcheck disable=SC2034
# Constants, defaults, version, globals

# --- File and directory name constants ---
SELF_SCRIPT_NAME="sui-control.sh"
CONFIG_FILE_NAME="sui-control.conf"
COMPOSE_FILE_NAME="docker-compose.yml"
ACME_CERT_SCRIPT_NAME="acme-cert.sh"
DB_CONFIG_SCRIPT_NAME="s-ui-db-configure.sh"

# --- FHS paths (set by resolve_layout() in utils.sh) ---
CONFIG_DIR=""
RUNTIME_DIR=""
RUNTIME_BIN_DIR=""
RUNTIME_SYSTEMD_DIR=""
RUNTIME_DATA_DIR=""
RUNTIME_CERT_DIR=""
RUNTIME_ACME_DIR=""

# --- System integration ---
SYSTEMD_DST_DIR="/etc/systemd/system"
SYSTEMD_CONTROL_SERVICE_NAME="sui-control.service"
SYSTEMD_RENEW_SERVICE_NAME="sui-control-renew.service"
SYSTEMD_RENEW_TIMER_NAME="sui-control-renew.timer"
CRON_DST_DIR="/etc/cron.d"
CRON_FILE_NAME="sui-control-renew"

# --- Default configuration values ---
DEFAULT_DOMAIN=""
DEFAULT_TZ=""
DEFAULT_TIMER_ON_CALENDAR="Mon *-*-* 03:00:00"
DEFAULT_TIMER_RANDOM_DELAY="1h"
DEFAULT_TIMER_ON_CALENDAR_IP="daily"
DEFAULT_TIMER_RANDOM_DELAY_IP="2h"
DEFAULT_CERT_MODE="selfsigned"
DEFAULT_SELF_SIGNED_DAYS="825"
DEFAULT_SUI_PANEL_PORT="2095"
DEFAULT_SUI_SUBSCRIPTION_PORT="2096"
DEFAULT_SUI_PANEL_PATH="panel"
DEFAULT_SUI_SUBSCRIPTION_PATH="sub"
SELF_SIGNED_DIR_NAME="selfsigned"
DEFAULT_INIT_SYSTEM="auto"
SUPPORTED_INIT_SYSTEMS=("systemd" "openrc" "runit" "s6" "dinit")

# --- Terminal color codes (interpreted by printf %b) ---
COLOR_INFO='\033[0;32m'
COLOR_WARN='\033[1;33m'
COLOR_ERROR='\033[0;31m'
COLOR_RESET='\033[0m'

# --- Runtime state ---
SCRIPT_ARG0="$0"
SCRIPT_PATH=""
PACKAGE_DIR=""
CURRENT_COMMAND=""
COMMAND=""
AUTO_CONFIRM="0"
BATCH_INSTALL="0"
INSTALL_GENERATED_USERNAME=""
INSTALL_GENERATED_PASSWORD=""

# --- Configuration (may be overridden by env vars, CLI args, or config file) ---
DOMAIN="${DOMAIN:-$DEFAULT_DOMAIN}"
TZ="${TZ:-$DEFAULT_TZ}"
TIMER_ON_CALENDAR="${TIMER_ON_CALENDAR:-$DEFAULT_TIMER_ON_CALENDAR}"
TIMER_RANDOM_DELAY="${TIMER_RANDOM_DELAY:-$DEFAULT_TIMER_RANDOM_DELAY}"
CERT_MODE="${CERT_MODE:-$DEFAULT_CERT_MODE}"
SELF_SIGNED_DAYS="${SELF_SIGNED_DAYS:-$DEFAULT_SELF_SIGNED_DAYS}"
SUI_PANEL_PORT="${SUI_PANEL_PORT:-$DEFAULT_SUI_PANEL_PORT}"
SUI_SUBSCRIPTION_PORT="${SUI_SUBSCRIPTION_PORT:-$DEFAULT_SUI_SUBSCRIPTION_PORT}"
SUI_PANEL_PATH="${SUI_PANEL_PATH:-$DEFAULT_SUI_PANEL_PATH}"
SUI_SUBSCRIPTION_PATH="${SUI_SUBSCRIPTION_PATH:-$DEFAULT_SUI_SUBSCRIPTION_PATH}"
CLI_PANEL_PORT_SET=""
CLI_SUBSCRIPTION_PORT_SET=""
CLI_PANEL_PATH_SET=""
CLI_SUBSCRIPTION_PATH_SET=""
CLI_IP_CERT_SET=""
INIT_SYSTEM="${INIT_SYSTEM:-$DEFAULT_INIT_SYSTEM}"
EOF__lib_constants
}
_embed_lib_utils() {
    cat <<'EOF__lib_utils'
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
        init_system)         INIT_SYSTEM="$value" ;;
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

compose_in_dir() {
    local dir="$1"
    cd "$dir" || die "Cannot cd to $dir"
    [[ -f "$COMPOSE_FILE_NAME" ]] || die "Compose file not found: $dir/$COMPOSE_FILE_NAME"
}

restart_sui_container() {
    compose_in_dir "$CONFIG_DIR"
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
    compose_in_dir "$CONFIG_DIR"
    docker compose stop s-ui >/dev/null 2>&1 || true
}

ensure_acme_mode() {
    [[ "$CERT_MODE" == "acme" ]] || die "This script requires acme certificate mode; current mode: $CERT_MODE"
}
EOF__lib_utils
}
_embed_lib_actions() {
    cat <<'EOF__lib_actions'
# shellcheck shell=bash
# .editorconfig hint: indent_style = space, indent_size = 4
# SPDX-License-Identifier: GPL-3.0-or-later
# Project-specific actions

# ----------------------------------------------------------------------
# CLI utilities
# ----------------------------------------------------------------------
require_option_value() {
    local option_name="$1"
    local option_value="${2-}"
    local allow_empty="${3:-0}"
    if [[ -z "${2+x}" || "$option_value" == --* ]]; then
        die "Option $option_name requires a value"
    fi
    if [[ "$allow_empty" != "1" && -z "$option_value" ]]; then
        die "Option $option_name requires a non-empty value"
    fi
}

# ----------------------------------------------------------------------
# Validation
# ----------------------------------------------------------------------
validate_domain() {
    local domain="$1"
    local label
    [[ -n "$domain" ]]                          || die "Domain must not be empty"
    [[ ${#domain} -le 253 ]]                    || die "Domain is too long (max 253 chars): $domain"
    [[ "$domain" =~ ^[A-Za-z0-9.-]+$ ]]         || die "Domain contains unsupported characters: $domain"
    [[ "$domain" != .* ]]                        || die "Domain must not start with a dot: $domain"
    [[ "$domain" != *..* ]]                      || die "Domain must not contain consecutive dots: $domain"
    [[ "$domain" == *.* ]]                       || die "Domain must contain at least one dot: $domain"
    IFS='.' read -r -a labels <<< "$domain"
    for label in "${labels[@]}"; do
        [[ -n "$label" ]]       || die "Domain has an empty label: $domain"
        [[ ${#label} -le 63 ]]  || die "Domain label is too long (max 63 chars): $label"
        [[ "$label" != -* ]]    || die "Domain label must not start with a hyphen: $label"
        [[ "$label" != *- ]]    || die "Domain label must not end with a hyphen: $label"
    done
}

validate_port() {
    local label="$1" port="$2"
    [[ "$port" =~ ^[0-9]+$ ]] || die "$label must be a number: $port"
    (( port >= 1 && port <= 65535 )) || die "$label must be between 1 and 65535: $port"
}

validate_url_path_segment() {
    local label="$1" value="$2"
    [[ -n "$value" ]]             || die "$label must not be empty"
    [[ "$value" != /* ]]          || die "$label must not start with slash: $value"
    [[ "$value" != */ ]]          || die "$label must not end with slash: $value"
    [[ "$value" != *"//"* ]]      || die "$label must not contain double slash: $value"
    [[ "$value" =~ ^[A-Za-z0-9._~-]+(/[A-Za-z0-9._~-]+)*$ ]] \
        || die "$label contains unsupported characters: $value"
}

# ----------------------------------------------------------------------
# Init system detection
# ----------------------------------------------------------------------
detect_init_system() {
    [[ "$INIT_SYSTEM" != "auto" ]] && return
    if command_exists systemctl;   then INIT_SYSTEM="systemd"; return; fi
    if command_exists rc-update;   then INIT_SYSTEM="openrc";  return; fi
    if command_exists runsvdir;    then INIT_SYSTEM="runit";   return; fi
    if command_exists s6-svscan;   then INIT_SYSTEM="s6";      return; fi
    if command_exists dinitctl;    then INIT_SYSTEM="dinit";   return; fi
    INIT_SYSTEM="unsupported"
}

# ----------------------------------------------------------------------
# Effective settings
# ----------------------------------------------------------------------
prepare_effective_settings() {
    case "$CERT_MODE" in
        selfsigned|acme) ;;
        *) die "Unsupported certificate mode: $CERT_MODE" ;;
    esac
    if [[ "$CERT_MODE" == "acme" ]]; then
        assert_nonempty_value "Timer OnCalendar" "$TIMER_ON_CALENDAR"
        assert_nonempty_value "Timer RandomizedDelaySec" "$TIMER_RANDOM_DELAY"
        if command_exists systemd-analyze; then
            systemd-analyze calendar "$TIMER_ON_CALENDAR" >/dev/null 2>&1 \
                || die "Invalid systemd OnCalendar value: $TIMER_ON_CALENDAR"
            systemd-analyze timespan "$TIMER_RANDOM_DELAY" >/dev/null 2>&1 \
                || die "Invalid systemd RandomizedDelaySec value: $TIMER_RANDOM_DELAY"
        fi
        if is_ip "$DOMAIN"; then
            is_ipv4 "$DOMAIN" || is_ipv6 "$DOMAIN" || die "Invalid IP address: $DOMAIN"
            if [[ "$TIMER_ON_CALENDAR" == "$DEFAULT_TIMER_ON_CALENDAR" && "$TIMER_RANDOM_DELAY" == "$DEFAULT_TIMER_RANDOM_DELAY" ]]; then
                TIMER_ON_CALENDAR="$DEFAULT_TIMER_ON_CALENDAR_IP"
                TIMER_RANDOM_DELAY="$DEFAULT_TIMER_RANDOM_DELAY_IP"
            fi
        else
            validate_domain "$DOMAIN"
            [[ "$DOMAIN" != "localhost" ]] || die "Domain must not be localhost in acme mode"
        fi
    else
        DOMAIN="localhost"
    fi
    validate_port "Panel port" "$SUI_PANEL_PORT"
    validate_port "Subscription port" "$SUI_SUBSCRIPTION_PORT"
    [[ "$SUI_PANEL_PORT" != "$SUI_SUBSCRIPTION_PORT" ]] \
        || die "Panel port and subscription port must be different"
    validate_url_path_segment "Panel path" "$SUI_PANEL_PATH"
    validate_url_path_segment "Subscription path" "$SUI_SUBSCRIPTION_PATH"
    [[ "$SUI_PANEL_PATH" != "$SUI_SUBSCRIPTION_PATH" ]] \
        || die "Panel path and subscription path must be different"
}

# ----------------------------------------------------------------------
# Config loading (bootstrap version)
# ----------------------------------------------------------------------
load_install_config() {
    local config_file="$1"
    # Reset to defaults before applying config values so stale globals do not bleed through.
    DOMAIN="$DEFAULT_DOMAIN"
    TZ="$DEFAULT_TZ"
    TIMER_ON_CALENDAR="$DEFAULT_TIMER_ON_CALENDAR"
    TIMER_RANDOM_DELAY="$DEFAULT_TIMER_RANDOM_DELAY"
    CERT_MODE="$DEFAULT_CERT_MODE"
    SELF_SIGNED_DAYS="$DEFAULT_SELF_SIGNED_DAYS"
    SUI_PANEL_PORT="$DEFAULT_SUI_PANEL_PORT"
    SUI_SUBSCRIPTION_PORT="$DEFAULT_SUI_SUBSCRIPTION_PORT"
    SUI_PANEL_PATH="$DEFAULT_SUI_PANEL_PATH"
    SUI_SUBSCRIPTION_PATH="$DEFAULT_SUI_SUBSCRIPTION_PATH"
    parse_config_file "$config_file"
    prepare_effective_settings
}

ensure_config_loaded() {
    local config_file="${1:-$CONFIG_DIR/$CONFIG_FILE_NAME}"
    if [[ -z "${CONFIG_LOADED:-}" ]]; then
        load_install_config "$config_file"
        CONFIG_LOADED="1"
    fi
}

# ----------------------------------------------------------------------
# Requirement checks
# ----------------------------------------------------------------------
check_requirements() {
    require_command docker stat
    docker compose version >/dev/null 2>&1 || die "docker compose plugin is required"
    case "$CURRENT_COMMAND" in
        install)
            require_command sqlite3 tr head grep awk
            [[ "$CERT_MODE" != "selfsigned" ]] || require_command openssl
            if [[ "$CERT_MODE" == "acme" ]]; then
                detect_init_system
                [[ "$INIT_SYSTEM" != "unsupported" ]] \
                    || log_warn "No supported init system found; renewal timer will not be auto-activated"
            fi
            ;;
        init)
            [[ "$CERT_MODE" != "selfsigned" ]] || require_command openssl
            ;;
    esac
}

# ----------------------------------------------------------------------
# Random value generators (bootstrap-specific)
# ----------------------------------------------------------------------
generate_random_port() {
    local min="$1" max="$2" range num
    range=$(( max - min + 1 ))
    num="$(od -An -N4 -tu4 /dev/urandom | tr -d ' \n')"
    printf '%s\n' $(( num % range + min ))
}

_randomize_if_default() {
    local -n _rnd_ref="$1"
    local default_val="$2" flag_name="$3" exclude="$4"
    shift 4
    [[ -n "${!flag_name:-}" ]] && return
    [[ "$_rnd_ref" == "$default_val" ]] || return
    local new
    while true; do
        new="$("$@")"
        [[ -z "$exclude" || "$new" != "$exclude" ]] && break
    done
    _rnd_ref="$new"
}

# ----------------------------------------------------------------------
# Interactive install dialog
# ----------------------------------------------------------------------
prompt_with_default() {
    local prompt="$1"
    local default="$2"
    local value
    if [[ -n "$default" ]]; then
        read -r -p "$prompt [$default]: " value || true
        printf '%s\n' "${value:-$default}"
    else
        read -r -p "$prompt: " value || true
        printf '%s\n' "$value"
    fi
}

prompt_yes_no() {
    local prompt="$1"
    local default_answer="${2:-n}"
    local answer hint
    case "$default_answer" in
        y|Y) hint='[Y/n]' ;;
        *)   hint='[y/N]' ;;
    esac
    while true; do
        read -r -p "$prompt $hint: " answer || true
        answer="${answer:-$default_answer}"
        case "$answer" in
            y|Y|yes|YES) return 0 ;;
            n|N|no|NO)   return 1 ;;
            *) echo 'Enter y or n.' ;;
        esac
    done
}

prompt_certificate_mode() {
    local current="$1"
    local default_choice="1"
    local answer
    [[ "$current" == "acme" ]] && default_choice="2"
    while true; do
        printf '%s\n' 'Certificate mode:' >&2
        printf '%s\n' '  1) selfsigned - create a local self-signed certificate and start s-ui immediately.' >&2
        printf '%s\n' '  2) acme       - obtain a public certificate via ACME.' >&2
        printf 'Choose certificate mode [%s]: ' "$default_choice" >&2
        read -r answer || true
        answer="${answer:-$default_choice}"
        case "$answer" in
            1) printf '%s\n' 'selfsigned'; return ;;
            2) printf '%s\n' 'acme';       return ;;
            *) printf '%s\n' 'Enter 1 or 2.' >&2 ;;
        esac
    done
}

prompt_acme_identifier() {
    if [[ "$CERT_MODE" == "acme" ]]; then
        DOMAIN="$(prompt_with_default 'Domain or IP for ACME (domain ~90 days, IP ~6 days)' "${DOMAIN:-panel.example.com}")"
        if is_ip "$DOMAIN"; then
            is_ipv4 "$DOMAIN" || is_ipv6 "$DOMAIN" || die "Invalid IP address: $DOMAIN"
        else
            validate_domain "$DOMAIN"
        fi
    else
        DOMAIN="localhost"
    fi
}

show_install_defaults() {
    echo 'Current installation values:'
    echo "  1. Certificate mode   : $CERT_MODE"
    echo "  2. ACME identifier    : ${DOMAIN:-(empty)}"
    echo "  3. Time zone          : ${TZ:-(empty)}"
    echo "  4. Panel port         : $SUI_PANEL_PORT"
    echo "  5. Subscription port  : $SUI_SUBSCRIPTION_PORT"
    echo "  6. Panel path         : /$SUI_PANEL_PATH/"
    echo "  7. Subscription path  : /$SUI_SUBSCRIPTION_PATH/"
}

edit_install_option() {
    local option="$1"
    case "$option" in
        1) CERT_MODE="$(prompt_certificate_mode "$CERT_MODE")"
           [[ "$CERT_MODE" == "selfsigned" ]] && DOMAIN='' ;;
        2) [[ "$CERT_MODE" == "acme" ]] && prompt_acme_identifier || echo 'Domain is used only in ACME mode.' ;;
        3) TZ="$(prompt_with_default 'Time zone (optional)' "$TZ")" ;;
        4) SUI_PANEL_PORT="$(prompt_with_default 'Panel port' "$SUI_PANEL_PORT")" ;;
        5) SUI_SUBSCRIPTION_PORT="$(prompt_with_default 'Subscription port' "$SUI_SUBSCRIPTION_PORT")" ;;
        6) SUI_PANEL_PATH="$(prompt_with_default 'Panel path' "$SUI_PANEL_PATH")" ;;
        7) SUI_SUBSCRIPTION_PATH="$(prompt_with_default 'Subscription path' "$SUI_SUBSCRIPTION_PATH")" ;;
        *) return 1 ;;
    esac
}

run_interactive_installation_dialog() {
    local action
    while true; do
        echo
        show_install_defaults
        echo
        echo '  1) Change certificate mode'
        echo '  2) Change ACME identifier'
        echo '  3) Change time zone'
        echo '  4) Change panel port'
        echo '  5) Change subscription port'
        echo '  6) Change panel path'
        echo '  7) Change subscription path'
        echo '  8) Continue installation'
        read -r -p 'Choose action [8]: ' action || true
        action="${action:-8}"
        case "$action" in
            1|2|3|4|5|6|7) edit_install_option "$action" ;;
            8)
                if [[ "$CERT_MODE" == "acme" ]]; then
                    if [[ -z "$DOMAIN" ]]; then
                        prompt_acme_identifier
                    else
                        if is_ip "$DOMAIN"; then
                            is_ipv4 "$DOMAIN" || is_ipv6 "$DOMAIN" || die "Invalid IP address: $DOMAIN"
                        else
                            validate_domain "$DOMAIN"
                        fi
                    fi
                else
                    DOMAIN='localhost'
                fi
                break
                ;;
            *) echo 'Enter 1..8.' ;;
        esac
    done
}

# ----------------------------------------------------------------------
# Certificate management
# ----------------------------------------------------------------------
sanitize_conf_value() {
    local value="$1"
    value="${value//$'\n'/ }"
    printf '%s' "$value"
}

generate_self_signed_cert() {
    local cert_root cert_cn tmp_conf
    require_command openssl
    cert_root="$RUNTIME_CERT_DIR/$SELF_SIGNED_DIR_NAME"
    cert_cn="${DOMAIN:-localhost}"
    tmp_conf="$(mktemp)"
    # shellcheck disable=SC2064
    trap "rm -f '$tmp_conf'" EXIT
    mkdir -p "$cert_root"
    cat > "$tmp_conf" <<EOF_SSL
[req]
distinguished_name=req_distinguished_name
x509_extensions=v3_req
prompt=no

[req_distinguished_name]
CN=$cert_cn

[v3_req]
subjectAltName=@alt_names
keyUsage=digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth

[alt_names]
DNS.1=$cert_cn
EOF_SSL
    openssl req -x509 -nodes -newkey rsa:2048 -days "$SELF_SIGNED_DAYS" \
        -keyout "$cert_root/privkey.pem" \
        -out    "$cert_root/fullchain.pem" \
        -config "$tmp_conf" >/dev/null 2>&1
    chmod 0600 "$cert_root/privkey.pem"
    chmod 0644 "$cert_root/fullchain.pem"
    rm -f "$tmp_conf"
    trap - EXIT
}

# ----------------------------------------------------------------------
# File generation helpers
# ----------------------------------------------------------------------
create_generated_file() {
    local base_dir="$1"
    local file_name="$2"
    local generator="$3"
    local mode="${4:-}"
    local label="${5:-file}"
    local path="$base_dir/$file_name"
    local old_umask
    log_info "Creating $label at: $path"
    old_umask="$(umask)"
    umask 077
    "$generator" > "$path"
    umask "$old_umask"
    [[ -n "$mode" ]] && chmod "$mode" "$path"
}

# ----------------------------------------------------------------------
# Container lifecycle (service commands)
# ----------------------------------------------------------------------
assert_nonempty_value() {
    local label="$1" value="$2"
    [[ -n "$value" ]] || die "$label must not be empty"
}

start_containers() {
    compose_in_dir "$CONFIG_DIR"
    docker compose up -d --remove-orphans
}

stop_containers() {
    compose_in_dir "$CONFIG_DIR"
    docker compose stop
}

restart_containers() {
    compose_in_dir "$CONFIG_DIR"
    docker compose restart
}

# ----------------------------------------------------------------------
# Timer system — systemd
# ----------------------------------------------------------------------
_install_timer_systemd() {
    local service_dir="$RUNTIME_SYSTEMD_DIR"
    local control_service_file="$service_dir/$SYSTEMD_CONTROL_SERVICE_NAME"
    local renew_service_file="$service_dir/$SYSTEMD_RENEW_SERVICE_NAME"
    local timer_file="$service_dir/$SYSTEMD_RENEW_TIMER_NAME"
    mkdir -p "$service_dir"

    # Control service (start/stop at boot)
    cat > "$control_service_file" <<EOF_CONTROL
[Unit]
Description=SUI-Control
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$PACKAGE_DIR/sui-control.sh start
ExecStop=$PACKAGE_DIR/sui-control.sh stop
User=root

[Install]
WantedBy=multi-user.target
EOF_CONTROL

    # Renew service (called by timer)
    cat > "$renew_service_file" <<EOF_RENEW
[Unit]
Description=SUI-Control certificate renewal
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$PACKAGE_DIR/sui-control.sh renew
User=root

[Install]
WantedBy=multi-user.target
EOF_RENEW

    # Timer
    cat > "$timer_file" <<EOF_TIMER
[Unit]
Description=Run s-ui certificate renewal periodically

[Timer]
OnCalendar=$TIMER_ON_CALENDAR
RandomizedDelaySec=$TIMER_RANDOM_DELAY
Persistent=true
Unit=$SYSTEMD_RENEW_SERVICE_NAME

[Install]
WantedBy=timers.target
EOF_TIMER

    if ! command_exists systemctl; then
        log_warn "systemctl not found; unit files written to $service_dir but not activated"
        return
    fi
    local control_link="$SYSTEMD_DST_DIR/$SYSTEMD_CONTROL_SERVICE_NAME"
    local renew_svc_link="$SYSTEMD_DST_DIR/$SYSTEMD_RENEW_SERVICE_NAME"
    local timer_link="$SYSTEMD_DST_DIR/$SYSTEMD_RENEW_TIMER_NAME"
    mkdir -p "$SYSTEMD_DST_DIR"
    ln -sfn "$control_service_file" "$control_link"
    ln -sfn "$renew_service_file"   "$renew_svc_link"
    ln -sfn "$timer_file"           "$timer_link"
    systemctl daemon-reload
    systemctl enable --now "$SYSTEMD_CONTROL_SERVICE_NAME"  >/dev/null 2>&1 || true
    systemctl enable --now "$SYSTEMD_RENEW_TIMER_NAME"
}

_remove_timer_systemd() {
    local control_link="$SYSTEMD_DST_DIR/$SYSTEMD_CONTROL_SERVICE_NAME"
    local renew_svc_link="$SYSTEMD_DST_DIR/$SYSTEMD_RENEW_SERVICE_NAME"
    local timer_link="$SYSTEMD_DST_DIR/$SYSTEMD_RENEW_TIMER_NAME"
    if command_exists systemctl; then
        systemctl disable --now "$SYSTEMD_CONTROL_SERVICE_NAME" >/dev/null 2>&1 || true
        systemctl disable --now "$SYSTEMD_RENEW_TIMER_NAME"     >/dev/null 2>&1 || true
        systemctl stop "$SYSTEMD_RENEW_SERVICE_NAME"            >/dev/null 2>&1 || true
    fi
    rm -f "$control_link" "$renew_svc_link" "$timer_link"
    command_exists systemctl && systemctl daemon-reload || true
}

# ----------------------------------------------------------------------
# Timer system — OpenRC
# ----------------------------------------------------------------------
_install_timer_openrc() {
    local init_file="/etc/init.d/sui-control"
    cat > "$init_file" <<'OPENRC_INIT'
#!/sbin/openrc-run
# SPDX-License-Identifier: GPL-3.0-or-later

description="SUI-Control"

command="/opt/s-ui/sui-control.sh"
command_args=""
pidfile="/run/${RC_SVCNAME}.pid"

depend() {
    need net
    use docker
}

start() {
    ebegin "Starting s-ui"
    start-stop-daemon --start --exec /opt/s-ui/sui-control.sh -- start
    eend $?
}

stop() {
    ebegin "Stopping s-ui"
    start-stop-daemon --stop --exec /opt/s-ui/sui-control.sh
    /opt/s-ui/sui-control.sh stop
    eend $?
}
OPENRC_INIT
    chmod 0755 "$init_file"

    _create_cron_job
    command_exists rc-update && rc-update add sui-control default || true
}

_remove_timer_openrc() {
    command_exists rc-update && rc-update del sui-control default >/dev/null 2>&1 || true
    rm -f "/etc/init.d/sui-control"
    _remove_cron_job
}

# ----------------------------------------------------------------------
# Timer system — runit
# ----------------------------------------------------------------------
_install_timer_runit() {
    local sv_dir="/etc/sv/sui-control"
    mkdir -p "$sv_dir"
    cat > "$sv_dir/run" <<'RUNIT_RUN'
#!/bin/sh
exec /opt/s-ui/sui-control.sh start
RUNIT_RUN
    chmod 0755 "$sv_dir/run"

    cat > "$sv_dir/finish" <<'RUNIT_FINISH'
#!/bin/sh
exec /opt/s-ui/sui-control.sh stop
RUNIT_FINISH
    chmod 0755 "$sv_dir/finish"

    _create_cron_job
    mkdir -p /etc/service
    ln -sfn "$sv_dir" "/etc/service/sui-control" 2>/dev/null || true
}

_remove_timer_runit() {
    rm -f "/etc/service/sui-control"
    rm -rf "/etc/sv/sui-control"
    _remove_cron_job
}

# ----------------------------------------------------------------------
# Timer system — s6
# ----------------------------------------------------------------------
_install_timer_s6() {
    local sv_dir="/etc/s6/sui-control"
    mkdir -p "$sv_dir"
    cat > "$sv_dir/run" <<'S6_RUN'
#!/bin/execlineb -P
/opt/s-ui/sui-control.sh start
S6_RUN
    chmod 0755 "$sv_dir/run"

    _create_cron_job
    mkdir -p /etc/s6
    ln -sfn "$sv_dir" "/etc/s6/service" 2>/dev/null || true
}

_remove_timer_s6() {
    rm -rf "/etc/s6/sui-control"
    _remove_cron_job
}

# ----------------------------------------------------------------------
# Timer system — dinit
# ----------------------------------------------------------------------
_install_timer_dinit() {
    local sv_file="/etc/dinit.d/sui-control"
    cat > "$sv_file" <<DINIT_SVC
type = process
command = /opt/s-ui/sui-control.sh start
stop-command = /opt/s-ui/sui-control.sh stop
restart-command = /opt/s-ui/sui-control.sh restart

depends-on = docker
waits-for = docker
DINIT_SVC

    _create_cron_job
    command_exists dinitctl && dinitctl enable sui-control || true
}

_remove_timer_dinit() {
    command_exists dinitctl && dinitctl disable sui-control >/dev/null 2>&1 || true
    rm -f "/etc/dinit.d/sui-control"
    _remove_cron_job
}

# ----------------------------------------------------------------------
# Cron helper
# ----------------------------------------------------------------------
_systemd_oncalendar_to_cron() {
    local cal="$1" day_part time_part hour min
    case "$cal" in
        daily|weekly|monthly|yearly|annually|@*)
            case "$cal" in
                daily)     printf '%s\n' '@daily' ;;
                weekly)    printf '%s\n' '@weekly' ;;
                monthly)   printf '%s\n' '@monthly' ;;
                yearly|annually) printf '%s\n' '@yearly' ;;
                *)         printf '%s\n' "$cal" ;;
            esac
            return ;;
    esac
    day_part="${cal%% *}"
    time_part="${cal##* }"
    hour="${time_part%%:*}"
    min="${time_part#*:}"; min="${min%%:*}"
    case "$day_part" in
        Mon)     printf '%s %s * * 1\n' "$min" "$hour" ;;
        Sat,Sun) printf '%s %s * * 0,6\n' "$min" "$hour" ;;
        *)       printf '%s %s * * *\n' "$min" "$hour" ;;
    esac
}

_create_cron_job() {
    local cron_file="$CRON_DST_DIR/$CRON_FILE_NAME"
    local cron_schedule
    cron_schedule="$(_systemd_oncalendar_to_cron "$TIMER_ON_CALENDAR")"
    mkdir -p "$CRON_DST_DIR"
    cat > "$cron_file" <<CRONEOF
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

$cron_schedule root $PACKAGE_DIR/sui-control.sh renew
CRONEOF
    chmod 0644 "$cron_file"
}

_remove_cron_job() {
    rm -f "$CRON_DST_DIR/$CRON_FILE_NAME"
}

# ----------------------------------------------------------------------
# Timer dispatcher
# ----------------------------------------------------------------------
install_renewal_timer() {
    detect_init_system
    case "$INIT_SYSTEM" in
        systemd) _install_timer_systemd ;;
        openrc)  _install_timer_openrc  ;;
        runit)   _install_timer_runit   ;;
        s6)      _install_timer_s6      ;;
        dinit)   _install_timer_dinit   ;;
        *)
            log_warn "No supported init system found; creating cron job only"
            _create_cron_job
            ;;
    esac
}

remove_renewal_timer() {
    detect_init_system
    case "$INIT_SYSTEM" in
        systemd) _remove_timer_systemd ;;
        openrc)  _remove_timer_openrc  ;;
        runit)   _remove_timer_runit   ;;
        s6)      _remove_timer_s6      ;;
        dinit)   _remove_timer_dinit   ;;
        *)       _remove_cron_job      ;;
    esac
}

# ----------------------------------------------------------------------
# Runtime artifact initialization and certificate renewal
# ----------------------------------------------------------------------
initialize_runtime_artifacts() {
    local resolved_bin_dir
    ensure_config_loaded
    compose_in_dir "$CONFIG_DIR"
    resolved_bin_dir="$RUNTIME_BIN_DIR"
    if [[ "$CERT_MODE" == "selfsigned" ]]; then
        generate_self_signed_cert
        restart_sui_container
    elif [[ "$CERT_MODE" == "acme" ]]; then
        "$resolved_bin_dir/$ACME_CERT_SCRIPT_NAME" issue
    fi
}

renew_certificate() {
    local resolved_bin_dir
    ensure_config_loaded
    resolved_bin_dir="$RUNTIME_BIN_DIR"
    if [[ "$CERT_MODE" == "selfsigned" ]]; then
        generate_self_signed_cert
        restart_sui_container
        return
    fi
    "$resolved_bin_dir/$ACME_CERT_SCRIPT_NAME" renew
}

# ----------------------------------------------------------------------
# Status display helpers
# ----------------------------------------------------------------------
print_path_status() {
    local label="$1" path="$2"
    if [[ -e "$path" ]]; then
        echo "$label: present ($path)"
    else
        echo "$label: missing ($path)"
    fi
}
EOF__lib_actions
}
_embed_lib_commands() {
    cat <<'EOF__lib_commands'
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
                echo "Renew timer:     $(systemctl is-enabled "$SYSTEMD_RENEW_TIMER_NAME"     2>/dev/null || echo unknown)"
                echo "Renew timer:     $(systemctl is-active  "$SYSTEMD_RENEW_TIMER_NAME"     2>/dev/null || echo unknown)"
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
                echo "Service: $(s6-svstat /etc/s6/sui-control 2>/dev/null || echo 'check s6-svstat')"
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
    remove_renewal_timer
    (cd "$CONFIG_DIR" && docker compose down -v --remove-orphans) || true
    rm -rf -- "$RUNTIME_DIR" "$CONFIG_DIR"
    log_info "Installation removed"
    log_info "Package at $PACKAGE_DIR was not removed (remove manually if desired)"
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
    PACKAGE_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
    resolve_layout

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

    [[ "$(id -u)" -eq 0 ]] || die "This script must be run as root"

    case "$COMMAND" in
        start)
            CURRENT_COMMAND="start"
            ensure_config_loaded
            start_containers
            ;;
        stop)
            CURRENT_COMMAND="stop"
            ensure_config_loaded
            stop_containers
            ;;
        restart)
            CURRENT_COMMAND="restart"
            ensure_config_loaded
            restart_containers
            ;;
        renew)
            CURRENT_COMMAND="renew"
            ensure_config_loaded
            check_requirements
            renew_certificate
            ;;
        renew-now)
            log_warn "renew-now is deprecated; use 'renew' instead"
            CURRENT_COMMAND="renew"
            ensure_config_loaded
            check_requirements
            renew_certificate
            ;;
        init)
            CURRENT_COMMAND="init"
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
            ensure_config_loaded
            install_renewal_timer
            ;;
        service-remove)
            CURRENT_COMMAND="service-remove"
            ensure_config_loaded
            remove_renewal_timer
            ;;
        update)
            CURRENT_COMMAND="update"
            ensure_config_loaded
            check_requirements
            update_containers
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
            CURRENT_COMMAND="uninstall"
            uninstall_control_script
            ;;
        *)
            log_error "Unknown command: $COMMAND"
            show_usage
            exit 1
            ;;
    esac
}
EOF__lib_commands
}
_embed_entry_point() {
    cat <<'EOF__entry_point'
#!/usr/bin/env bash
# .editorconfig hint: indent_style = space, indent_size = 4
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/constants.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/utils.sh"

PACKAGE_DIR="$SCRIPT_DIR"
resolve_layout

# Dev config overrides (optional, for local testing)
[[ -f "$SCRIPT_DIR/config.conf" ]] && parse_config_file "$SCRIPT_DIR/config.conf"

init_config() {
    local cert_mode domain panel_port sub_port ans

    if [[ -f "$CONFIG_DIR/$CONFIG_FILE_NAME" ]]; then
        read -r -p "$CONFIG_DIR/$CONFIG_FILE_NAME already exists. Overwrite? [y/N] " ans
        [[ "$ans" =~ ^[yY] ]] || { echo "Aborted."; exit 0; }
    fi

    while true; do
        read -r -p "Certificate mode (selfsigned/acme) [selfsigned]: " cert_mode
        cert_mode="${cert_mode:-selfsigned}"
        case "$cert_mode" in selfsigned|acme) break ;; *) echo "Enter selfsigned or acme." ;; esac
    done

    domain=""
    if [[ "$cert_mode" == "acme" ]]; then
        read -r -p "Domain or IP for ACME (domain ~90 days, IP ~6 days): " domain
    fi

    read -r -p "Panel port [2095]: " panel_port
    panel_port="${panel_port:-2095}"

    read -r -p "Subscription port [2096]: " sub_port
    sub_port="${sub_port:-2096}"

    mkdir -p "$CONFIG_DIR"
    cat > "$CONFIG_DIR/$CONFIG_FILE_NAME" <<EOF
# sui-control configuration
cert_mode=$cert_mode
panel_port=$panel_port
subscription_port=$sub_port
EOF

    if [[ -n "$domain" ]]; then
        echo "domain=$domain" >> "$CONFIG_DIR/$CONFIG_FILE_NAME"
    fi

    echo "Created $CONFIG_DIR/$CONFIG_FILE_NAME"
}

prompt_create_config() {
    local ans
    echo "$CONFIG_DIR/$CONFIG_FILE_NAME not found — create one with your preferred defaults?"
    echo "  (You can also run './sui-control.sh init-config' later)"
    read -r -p "Create config.conf now? [y/N] " ans
    if [[ "$ans" =~ ^[yY] ]]; then
        init_config
    else
        echo "Using built-in defaults."
    fi
}

case "${1:-}" in
    init-config)
        init_config
        exit 0
        ;;
    help|-h|--help)
        ;;
    *)
        [[ -f "$CONFIG_DIR/$CONFIG_FILE_NAME" ]] || prompt_create_config
        ;;
esac

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/actions.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/commands.sh"

main "$@"
EOF__entry_point
}
# --- Template files ---
_embed_tpl_acme_cert() {
    cat <<'EOF__tpl_acme_cert'
#!/usr/bin/env bash
# shellcheck disable=SC2154
set -euo pipefail
PACKAGE_DIR="${PACKAGE_DIR}"
# shellcheck disable=SC1091
. "$PACKAGE_DIR/lib/constants.sh"
# shellcheck disable=SC1091
. "$PACKAGE_DIR/lib/utils.sh"
require_command docker
ensure_config_loaded
ensure_acme_mode
compose_in_dir "$CONFIG_DIR"
check_port_80_free
stop_sui_container_if_running
MODE="${1:-renew}"
case "$MODE" in
    renew)
        log_info "Running scheduled ACME renewal check"
        docker compose run --rm -p 80:80 --entrypoint sh acme-sh -c 'set -e; acme.sh --cron --home /acme.sh'
        ;;
    issue)
        acme_flags=""
        if is_ip "$DOMAIN"; then
            acme_flags="--server letsencrypt --certificate-profile shortlived --days 6"
            log_info "Issuing short-lived IP certificate (valid ~6 days)"
        fi
        log_info "Issuing ACME certificate for $DOMAIN"
        if docker compose run --rm -p 80:80 --entrypoint sh acme-sh \
                -c "set -e; acme.sh --issue --standalone -d '$DOMAIN' $acme_flags --key-file /certs/server.key --fullchain-file /certs/server.crt --home /acme.sh"; then
            log_info "Certificate issued successfully"
        else
            die "ACME certificate issuance failed"
        fi
        ;;
    *)
        die "Unknown mode: $MODE (expected: renew or issue)"
        ;;
esac
restart_sui_container
EOF__tpl_acme_cert
}
_embed_tpl_db_config() {
    cat <<'EOF__tpl_db_config'
#!/usr/bin/env bash
# shellcheck disable=SC2154
set -euo pipefail

PACKAGE_DIR="${PACKAGE_DIR}"
. "$PACKAGE_DIR/lib/constants.sh"
. "$PACKAGE_DIR/lib/utils.sh"

require_command sqlite3
ensure_config_loaded

DB_PATH="$RUNTIME_DATA_DIR/s-ui.db"
[[ -f "$DB_PATH" ]] || die "Database file not found: $DB_PATH"

USERNAME="${1:-}"
PASSWORD="${2:-}"
PANEL_PORT="$SUI_PANEL_PORT"
SUB_PORT="$SUI_SUBSCRIPTION_PORT"
PANEL_PATH="$SUI_PANEL_PATH"
SUB_PATH="$SUI_SUBSCRIPTION_PATH"
TIME_LOCATION="$TZ"

[[ -n "$USERNAME" ]]   || die "username argument is required"
[[ -n "$PASSWORD" ]]   || die "password argument is required"
[[ -n "$PANEL_PORT" ]] || die "panel_port is not set in config"
[[ -n "$SUB_PORT" ]]   || die "subscription_port is not set in config"
[[ -n "$PANEL_PATH" ]] || die "panel_path is not set in config"
[[ -n "$SUB_PATH" ]]   || die "subscription_path is not set in config"

settings_table_exists="$(sqlite3 "$DB_PATH" "SELECT 1 FROM sqlite_master WHERE type='table' AND name='settings' LIMIT 1;")"
users_table_exists="$(sqlite3 "$DB_PATH" "SELECT 1 FROM sqlite_master WHERE type='table' AND name='users' LIMIT 1;")"
first_user_rowid="$(sqlite3 "$DB_PATH" "SELECT rowid FROM users ORDER BY rowid LIMIT 1;")"
[[ "$settings_table_exists" == "1" ]] || die "settings table not found in database: $DB_PATH"
[[ "$users_table_exists" == "1" ]]    || die "users table not found in database: $DB_PATH"
[[ -n "$first_user_rowid" ]]          || die "users table is empty: $DB_PATH"

USERNAME_SQL="${USERNAME//\'/\'\'}"
PASSWORD_SQL="${PASSWORD//\'/\'\'}"
TIME_LOCATION_SQL="${TIME_LOCATION//\'/\'\'}"

if [[ "$CERT_MODE" == "selfsigned" ]]; then
    CERT_FILE="/certs/selfsigned/fullchain.pem"
    KEY_FILE="/certs/selfsigned/privkey.pem"
else
    CERT_FILE="/certs/server.crt"
    KEY_FILE="/certs/server.key"
fi

sqlite3 "$DB_PATH" <<SQL
BEGIN TRANSACTION;
UPDATE settings SET value = '$PANEL_PORT' WHERE key = 'webPort';
UPDATE settings SET value = '$PANEL_PATH' WHERE key = 'webPath';
UPDATE settings SET value = '$SUB_PORT'   WHERE key = 'subPort';
UPDATE settings SET value = '$SUB_PATH'   WHERE key = 'subPath';
UPDATE settings SET value = '$TIME_LOCATION_SQL' WHERE '$TIME_LOCATION_SQL' <> '' AND key = 'timeLocation';
UPDATE settings SET value = '$CERT_FILE'  WHERE key = 'webCertFile';
UPDATE settings SET value = '$KEY_FILE'   WHERE key = 'webKeyFile';
UPDATE users SET username = '$USERNAME_SQL', password = '$PASSWORD_SQL' WHERE rowid = $first_user_rowid;
COMMIT;
SQL

log_info "Database updated: $DB_PATH"
log_info "Panel path: $PANEL_PATH"
log_info "Subscription path: $SUB_PATH"
EOF__tpl_db_config
}
_embed_tpl_compose() {
    cat <<'EOF__tpl_compose'
services:
  s-ui:
    image: alireza7/s-ui:latest
    container_name: s-ui
    restart: unless-stopped
    networks:
      - s-ui
    ports:
      - "${SUI_PANEL_PORT}:${SUI_PANEL_PORT}"
      - "${SUI_SUBSCRIPTION_PORT}:${SUI_SUBSCRIPTION_PORT}"
    environment:
      TZ: "${TZ}"
    volumes:
      - "${RUNTIME_DATA_DIR}:/app/db"
      - "${RUNTIME_CERT_DIR}:/certs"

  acme-sh:
    image: neilpang/acme.sh:latest
    container_name: acme-sh
    profiles: ["tools"]
    networks:
      - s-ui
    volumes:
      - "${RUNTIME_ACME_DIR}:/acme.sh"
      - "${RUNTIME_CERT_DIR}:/certs"

networks:
  s-ui:
    driver: bridge
EOF__tpl_compose
}
_embed_tpl_config() {
    cat <<'EOF__tpl_config'
domain=$(sanitize_conf_value "$DOMAIN")
tz=$(sanitize_conf_value "$TZ")
timer_on_calendar=$(sanitize_conf_value "$TIMER_ON_CALENDAR")
timer_random_delay=$(sanitize_conf_value "$TIMER_RANDOM_DELAY")
cert_mode=$(sanitize_conf_value "$CERT_MODE")
self_signed_days=$(sanitize_conf_value "$SELF_SIGNED_DAYS")
panel_port=$(sanitize_conf_value "$SUI_PANEL_PORT")
subscription_port=$(sanitize_conf_value "$SUI_SUBSCRIPTION_PORT")
panel_path=$(sanitize_conf_value "$SUI_PANEL_PATH")
subscription_path=$(sanitize_conf_value "$SUI_SUBSCRIPTION_PATH")
init_system=$(sanitize_conf_value "$INIT_SYSTEM")
EOF__tpl_config
}

# === INSTALLER RUNTIME ===
eval "$(_embed_lib_constants)"
eval "$(_embed_lib_utils)"
eval "$(_embed_lib_actions)"

# shellcheck disable=SC2154
# === RUNTIME FILE GENERATORS ===

_gen_compose() {
    cat <<EOF__compose
services:
  s-ui:
    image: alireza7/s-ui:latest
    container_name: s-ui
    restart: unless-stopped
    networks:
      - s-ui
    ports:
      - "${SUI_PANEL_PORT}:${SUI_PANEL_PORT}"
      - "${SUI_SUBSCRIPTION_PORT}:${SUI_SUBSCRIPTION_PORT}"
    environment:
      TZ: "${TZ}"
    volumes:
      - "${RUNTIME_DATA_DIR}:/app/db"
      - "${RUNTIME_CERT_DIR}:/certs"

  acme-sh:
    image: neilpang/acme.sh:latest
    container_name: acme-sh
    profiles: ["tools"]
    networks:
      - s-ui
    volumes:
      - "${RUNTIME_ACME_DIR}:/acme.sh"
      - "${RUNTIME_CERT_DIR}:/certs"

networks:
  s-ui:
    driver: bridge
EOF__compose
}

_gen_config() {
    cat <<EOF__config
domain=$(sanitize_conf_value "$DOMAIN")
tz=$(sanitize_conf_value "$TZ")
timer_on_calendar=$(sanitize_conf_value "$TIMER_ON_CALENDAR")
timer_random_delay=$(sanitize_conf_value "$TIMER_RANDOM_DELAY")
cert_mode=$(sanitize_conf_value "$CERT_MODE")
self_signed_days=$(sanitize_conf_value "$SELF_SIGNED_DAYS")
panel_port=$(sanitize_conf_value "$SUI_PANEL_PORT")
subscription_port=$(sanitize_conf_value "$SUI_SUBSCRIPTION_PORT")
panel_path=$(sanitize_conf_value "$SUI_PANEL_PATH")
subscription_path=$(sanitize_conf_value "$SUI_SUBSCRIPTION_PATH")
init_system=$(sanitize_conf_value "$INIT_SYSTEM")
EOF__config
}

_gen_acme() {
    cat <<EOF__acme
#!/usr/bin/env bash
# shellcheck disable=SC2154
set -euo pipefail
PACKAGE_DIR="${PACKAGE_DIR}"
# shellcheck disable=SC1091
. "$PACKAGE_DIR/lib/constants.sh"
# shellcheck disable=SC1091
. "$PACKAGE_DIR/lib/utils.sh"
require_command docker
ensure_config_loaded
ensure_acme_mode
compose_in_dir "$CONFIG_DIR"
check_port_80_free
stop_sui_container_if_running
MODE="${1:-renew}"
case "$MODE" in
    renew)
        log_info "Running scheduled ACME renewal check"
        docker compose run --rm -p 80:80 --entrypoint sh acme-sh -c 'set -e; acme.sh --cron --home /acme.sh'
        ;;
    issue)
        acme_flags=""
        if is_ip "$DOMAIN"; then
            acme_flags="--server letsencrypt --certificate-profile shortlived --days 6"
            log_info "Issuing short-lived IP certificate (valid ~6 days)"
        fi
        log_info "Issuing ACME certificate for $DOMAIN"
        if docker compose run --rm -p 80:80 --entrypoint sh acme-sh \
                -c "set -e; acme.sh --issue --standalone -d '$DOMAIN' $acme_flags --key-file /certs/server.key --fullchain-file /certs/server.crt --home /acme.sh"; then
            log_info "Certificate issued successfully"
        else
            die "ACME certificate issuance failed"
        fi
        ;;
    *)
        die "Unknown mode: $MODE (expected: renew or issue)"
        ;;
esac
restart_sui_container
EOF__acme
}

_gen_db() {
    cat <<EOF__db
#!/usr/bin/env bash
# shellcheck disable=SC2154
set -euo pipefail

PACKAGE_DIR="${PACKAGE_DIR}"
. "$PACKAGE_DIR/lib/constants.sh"
. "$PACKAGE_DIR/lib/utils.sh"

require_command sqlite3
ensure_config_loaded

DB_PATH="$RUNTIME_DATA_DIR/s-ui.db"
[[ -f "$DB_PATH" ]] || die "Database file not found: $DB_PATH"

USERNAME="${1:-}"
PASSWORD="${2:-}"
PANEL_PORT="$SUI_PANEL_PORT"
SUB_PORT="$SUI_SUBSCRIPTION_PORT"
PANEL_PATH="$SUI_PANEL_PATH"
SUB_PATH="$SUI_SUBSCRIPTION_PATH"
TIME_LOCATION="$TZ"

[[ -n "$USERNAME" ]]   || die "username argument is required"
[[ -n "$PASSWORD" ]]   || die "password argument is required"
[[ -n "$PANEL_PORT" ]] || die "panel_port is not set in config"
[[ -n "$SUB_PORT" ]]   || die "subscription_port is not set in config"
[[ -n "$PANEL_PATH" ]] || die "panel_path is not set in config"
[[ -n "$SUB_PATH" ]]   || die "subscription_path is not set in config"

settings_table_exists="$(sqlite3 "$DB_PATH" "SELECT 1 FROM sqlite_master WHERE type='table' AND name='settings' LIMIT 1;")"
users_table_exists="$(sqlite3 "$DB_PATH" "SELECT 1 FROM sqlite_master WHERE type='table' AND name='users' LIMIT 1;")"
first_user_rowid="$(sqlite3 "$DB_PATH" "SELECT rowid FROM users ORDER BY rowid LIMIT 1;")"
[[ "$settings_table_exists" == "1" ]] || die "settings table not found in database: $DB_PATH"
[[ "$users_table_exists" == "1" ]]    || die "users table not found in database: $DB_PATH"
[[ -n "$first_user_rowid" ]]          || die "users table is empty: $DB_PATH"

USERNAME_SQL="${USERNAME//\'/\'\'}"
PASSWORD_SQL="${PASSWORD//\'/\'\'}"
TIME_LOCATION_SQL="${TIME_LOCATION//\'/\'\'}"

if [[ "$CERT_MODE" == "selfsigned" ]]; then
    CERT_FILE="/certs/selfsigned/fullchain.pem"
    KEY_FILE="/certs/selfsigned/privkey.pem"
else
    CERT_FILE="/certs/server.crt"
    KEY_FILE="/certs/server.key"
fi

sqlite3 "$DB_PATH" <<SQL
BEGIN TRANSACTION;
UPDATE settings SET value = '$PANEL_PORT' WHERE key = 'webPort';
UPDATE settings SET value = '$PANEL_PATH' WHERE key = 'webPath';
UPDATE settings SET value = '$SUB_PORT'   WHERE key = 'subPort';
UPDATE settings SET value = '$SUB_PATH'   WHERE key = 'subPath';
UPDATE settings SET value = '$TIME_LOCATION_SQL' WHERE '$TIME_LOCATION_SQL' <> '' AND key = 'timeLocation';
UPDATE settings SET value = '$CERT_FILE'  WHERE key = 'webCertFile';
UPDATE settings SET value = '$KEY_FILE'   WHERE key = 'webKeyFile';
UPDATE users SET username = '$USERNAME_SQL', password = '$PASSWORD_SQL' WHERE rowid = $first_user_rowid;
COMMIT;
SQL

log_info "Database updated: $DB_PATH"
log_info "Panel path: $PANEL_PATH"
log_info "Subscription path: $SUB_PATH"
EOF__db
}

# === INSTALL LOGIC ===
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

# === ENTRY POINT ===
parse_install_options "$@"
[[ "$(id -u)" -eq 0 ]] || die "This script must be run as root"
install_control_script
