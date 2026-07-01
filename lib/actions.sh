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
# Path utilities
# ----------------------------------------------------------------------
resolve_path() {
    local base_dir="$1"
    local path="$2"
    case "$path" in
        /*) printf '%s\n' "$path" ;;
        *)  printf '%s\n' "$base_dir/${path#./}" ;;
    esac
}

assert_nonempty_value() {
    local label="$1" value="$2"
    [[ -n "$value" ]] || die "$label must not be empty"
}

assert_safe_directory_value() {
    local label="$1" value="$2"
    assert_nonempty_value "$label" "$value"
    case "$value" in
        /|.|..) die "$label has unsafe value: $value" ;;
    esac
    if [[ "$value" == */../* || "$value" == */./* || "$value" == */.. || "$value" == */. ]]; then
        die "$label contains path traversal sequence: $value"
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

prepare_effective_settings() {
    assert_safe_directory_value "Install directory" "$INSTALL_DIR"
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
        validate_domain "$DOMAIN"
        [[ "$DOMAIN" != "localhost" ]] || die "Domain must not be localhost in acme mode"
    else
        DOMAIN="localhost"
    fi
    assert_safe_directory_value "Bin directory" "$BIN_DIR"
    assert_safe_directory_value "Data directory" "$DATA_DIR"
    assert_safe_directory_value "Certificate directory" "$CERT_DIR"
    assert_safe_directory_value "ACME directory" "$ACME_DIR"
    assert_safe_directory_value "Systemd directory" "$SYSTEMD_DST_DIR"
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
    local install_dir="$1"
    local config_file="$install_dir/$CONFIG_FILE_NAME"
    # Reset to defaults before applying config values so stale globals do not bleed through.
    INSTALL_DIR="$DEFAULT_INSTALL_DIR"
    DOMAIN="$DEFAULT_DOMAIN"
    TZ="$DEFAULT_TZ"
    DATA_DIR="$DEFAULT_DATA_DIR"
    CERT_DIR="$DEFAULT_CERT_DIR"
    ACME_DIR="$DEFAULT_ACME_DIR"
    BIN_DIR="$DEFAULT_BIN_DIR"
    SYSTEMD_DST_DIR="$DEFAULT_SYSTEMD_DST_DIR"
    TIMER_ON_CALENDAR="$DEFAULT_TIMER_ON_CALENDAR"
    TIMER_RANDOM_DELAY="$DEFAULT_TIMER_RANDOM_DELAY"
    CERT_MODE="$DEFAULT_CERT_MODE"
    SELF_SIGNED_DAYS="$DEFAULT_SELF_SIGNED_DAYS"
    SUI_PANEL_PORT="$DEFAULT_SUI_PANEL_PORT"
    SUI_SUBSCRIPTION_PORT="$DEFAULT_SUI_SUBSCRIPTION_PORT"
    SUI_PANEL_PATH="$DEFAULT_SUI_PANEL_PATH"
    SUI_SUBSCRIPTION_PATH="$DEFAULT_SUI_SUBSCRIPTION_PATH"
    parse_config_file "$config_file"
    RUNTIME_INSTALL_DIR="$INSTALL_DIR"
    prepare_effective_settings
}

ensure_config_loaded() {
    [[ -n "${RUNTIME_INSTALL_DIR:-}" ]] || load_install_config "$1"
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
                command_exists systemctl \
                    || log_warn "systemctl not found; install will continue but the automatic renewal timer cannot be installed"
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

prompt_domain_if_needed() {
    if [[ "$CERT_MODE" == "acme" ]]; then
        DOMAIN="$(prompt_with_default 'Domain for ACME certificate' "${DOMAIN:-panel.example.com}")"
        validate_domain "$DOMAIN"
    else
        DOMAIN="localhost"
    fi
}

show_install_defaults() {
    echo 'Current installation values:'
    echo "  1. Install directory  : $INSTALL_DIR"
    echo "  2. Certificate mode   : $CERT_MODE"
    echo "  3. Domain             : ${DOMAIN:-(empty)}"
    echo "  4. Time zone          : ${TZ:-(empty)}"
    echo "  5. Panel port         : $SUI_PANEL_PORT"
    echo "  6. Subscription port  : $SUI_SUBSCRIPTION_PORT"
    echo "  7. Panel path         : /$SUI_PANEL_PATH/"
    echo "  8. Subscription path  : /$SUI_SUBSCRIPTION_PATH/"
}

edit_install_option() {
    local option="$1"
    case "$option" in
        1) INSTALL_DIR="$(prompt_with_default 'Install directory' "$INSTALL_DIR")" ;;
        2) CERT_MODE="$(prompt_certificate_mode "$CERT_MODE")"
           [[ "$CERT_MODE" == "selfsigned" ]] && DOMAIN='' ;;
        3) [[ "$CERT_MODE" == "acme" ]] && prompt_domain_if_needed || echo 'Domain is used only in ACME mode.' ;;
        4) TZ="$(prompt_with_default 'Time zone (optional)' "$TZ")" ;;
        5) SUI_PANEL_PORT="$(prompt_with_default 'Panel port' "$SUI_PANEL_PORT")" ;;
        6) SUI_SUBSCRIPTION_PORT="$(prompt_with_default 'Subscription port' "$SUI_SUBSCRIPTION_PORT")" ;;
        7) SUI_PANEL_PATH="$(prompt_with_default 'Panel path' "$SUI_PANEL_PATH")" ;;
        8) SUI_SUBSCRIPTION_PATH="$(prompt_with_default 'Subscription path' "$SUI_SUBSCRIPTION_PATH")" ;;
        *) return 1 ;;
    esac
}

run_interactive_installation_dialog() {
    local action
    while true; do
        echo
        show_install_defaults
        echo
        echo '  1) Change install directory'
        echo '  2) Change certificate mode'
        echo '  3) Change domain'
        echo '  4) Change time zone'
        echo '  5) Change panel port'
        echo '  6) Change subscription port'
        echo '  7) Change panel path'
        echo '  8) Change subscription path'
        echo '  9) Continue installation'
        read -r -p 'Choose action [9]: ' action || true
        action="${action:-9}"
        case "$action" in
            1|2|3|4|5|6|7|8) edit_install_option "$action" ;;
            9)
                if [[ "$CERT_MODE" == "acme" ]]; then
                    if [[ -z "$DOMAIN" ]]; then
                        prompt_domain_if_needed
                    else
                        validate_domain "$DOMAIN"
                    fi
                else
                    DOMAIN='localhost'
                fi
                break
                ;;
            *) echo 'Enter 1..9.' ;;
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
    local install_dir="$1"
    local cert_root cert_cn tmp_conf
    require_command openssl
    cert_root="$(resolve_path "$install_dir" "$CERT_DIR")/$SELF_SIGNED_DIR_NAME"
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
# Systemd timer management
# ----------------------------------------------------------------------
install_systemd_timer() {
    local install_dir="$1"
    ensure_config_loaded "$install_dir"
    if [[ "$CERT_MODE" != "acme" ]]; then
        log_warn "Systemd renewal service is only needed in acme mode"
        return
    fi
    local service_dir="$INSTALL_DIR/$SYSTEMD_DIR_NAME"
    local service_file="$service_dir/$SYSTEMD_SERVICE_NAME"
    local timer_file="$service_dir/$SYSTEMD_TIMER_NAME"
    local resolved_bin_dir
    resolved_bin_dir="$(resolve_path "$INSTALL_DIR" "$BIN_DIR")"
    mkdir -p "$service_dir"
    cat > "$service_file" <<EOF_SERVICE
[Unit]
Description=s-ui certificate renewal
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$resolved_bin_dir/$ACME_CERT_SCRIPT_NAME renew
User=root

[Install]
WantedBy=multi-user.target
EOF_SERVICE
    cat > "$timer_file" <<EOF_TIMER
[Unit]
Description=Run s-ui certificate renewal periodically

[Timer]
OnCalendar=$TIMER_ON_CALENDAR
RandomizedDelaySec=$TIMER_RANDOM_DELAY
Persistent=true
Unit=$SYSTEMD_SERVICE_NAME

[Install]
WantedBy=timers.target
EOF_TIMER
    if ! command_exists systemctl; then
        log_warn "systemctl not found; unit files written to $service_dir but not activated"
        return
    fi
    local service_link="$SYSTEMD_DST_DIR/$SYSTEMD_SERVICE_NAME"
    local timer_link="$SYSTEMD_DST_DIR/$SYSTEMD_TIMER_NAME"
    mkdir -p "$SYSTEMD_DST_DIR"
    ln -sfn "$service_file" "$service_link"
    ln -sfn "$timer_file"   "$timer_link"
    systemctl daemon-reload
    systemctl enable --now "$SYSTEMD_TIMER_NAME"
}

remove_systemd_timer() {
    local install_dir="$1"
    local service_link timer_link
    ensure_config_loaded "$install_dir"
    service_link="$SYSTEMD_DST_DIR/$SYSTEMD_SERVICE_NAME"
    timer_link="$SYSTEMD_DST_DIR/$SYSTEMD_TIMER_NAME"
    if ! command_exists systemctl; then
        rm -f "$service_link" "$timer_link"
        return
    fi
    systemctl disable --now "$SYSTEMD_TIMER_NAME"  >/dev/null 2>&1 || true
    systemctl stop         "$SYSTEMD_SERVICE_NAME" >/dev/null 2>&1 || true
    rm -f "$service_link" "$timer_link"
    systemctl daemon-reload
}

# ----------------------------------------------------------------------
# Runtime artifact initialization and certificate renewal
# ----------------------------------------------------------------------
initialize_runtime_artifacts() {
    local install_dir="$1"
    local resolved_bin_dir
    ensure_config_loaded "$install_dir"
    cd "$INSTALL_DIR" || die "Cannot cd to $INSTALL_DIR"
    [[ -f "$COMPOSE_FILE_NAME" ]] || die "Compose file not found: $INSTALL_DIR/$COMPOSE_FILE_NAME"
    resolved_bin_dir="$(resolve_path "$INSTALL_DIR" "$BIN_DIR")"
    if [[ "$CERT_MODE" == "selfsigned" ]]; then
        generate_self_signed_cert "$INSTALL_DIR"
        restart_sui_container "$INSTALL_DIR"
    elif [[ "$CERT_MODE" == "acme" ]]; then
        "$resolved_bin_dir/$ACME_CERT_SCRIPT_NAME" issue
    fi
}

renew_certificate() {
    local install_dir="$1"
    local resolved_bin_dir
    ensure_config_loaded "$install_dir"
    resolved_bin_dir="$(resolve_path "$INSTALL_DIR" "$BIN_DIR")"
    if [[ "$CERT_MODE" == "selfsigned" ]]; then
        generate_self_signed_cert "$INSTALL_DIR"
        restart_sui_container "$INSTALL_DIR"
        return
    fi
    "$resolved_bin_dir/$ACME_CERT_SCRIPT_NAME" renew
}

# ----------------------------------------------------------------------
# Status display
# ----------------------------------------------------------------------
get_runtime_install_dir() {
    if [[ -n "${RUNTIME_INSTALL_DIR:-}" ]]; then
        printf '%s\n' "$RUNTIME_INSTALL_DIR"
    else
        printf '%s\n' "$SCRIPT_DIR"
    fi
}

print_path_status() {
    local label="$1" path="$2"
    if [[ -e "$path" ]]; then
        echo "$label: present ($path)"
    else
        echo "$label: missing ($path)"
    fi
}
