# shellcheck shell=bash
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
    [[ -n "$domain" ]] || die "Domain must not be empty"
    [[ ${#domain} -le 253 ]] || die "Domain is too long (max 253 chars): $domain"
    [[ "$domain" =~ ^[A-Za-z0-9.-]+$ ]] || die "Domain contains unsupported characters: $domain"
    [[ "$domain" != .* ]] || die "Domain must not start with a dot: $domain"
    [[ "$domain" != *..* ]] || die "Domain must not contain consecutive dots: $domain"
    [[ "$domain" == *.* ]] || die "Domain must contain at least one dot: $domain"
    IFS='.' read -r -a labels <<<"$domain"
    for label in "${labels[@]}"; do
        [[ -n "$label" ]] || die "Domain has an empty label: $domain"
        [[ ${#label} -le 63 ]] || die "Domain label is too long (max 63 chars): $label"
        [[ "$label" != -* ]] || die "Domain label must not start with a hyphen: $label"
        [[ "$label" != *- ]] || die "Domain label must not end with a hyphen: $label"
    done
}

is_valid_port() {
    local label="$1" port="$2"
    [[ "$port" =~ ^[0-9]+$ ]] || { log_warn "$label must be a number: $port"; return 1; }
    ((port >= 1 && port <= 65535)) || { log_warn "$label must be between 1 and 65535: $port"; return 1; }
    return 0
}

validate_port() {
    local label="$1" port="$2"
    is_valid_port "$label" "$port" || die "$label must be a number: $port"
}

is_valid_url_path_segment() {
    local label="$1" value="$2"
    [[ -n "$value" ]] || { log_warn "$label must not be empty"; return 1; }
    [[ "$value" != /* ]] || { log_warn "$label must not start with slash: $value"; return 1; }
    [[ "$value" != */ ]] || { log_warn "$label must not end with slash: $value"; return 1; }
    [[ "$value" != *"//"* ]] || { log_warn "$label must not contain double slash: $value"; return 1; }
    [[ "$value" =~ ^[A-Za-z0-9._~-]+(/[A-Za-z0-9._~-]+)*$ ]] || {
        log_warn "$label contains unsupported characters: $value"; return 1; }
    return 0
}

validate_url_path_segment() {
    local label="$1" value="$2"
    is_valid_url_path_segment "$label" "$value" ||
        die "$label contains unsupported characters: $value"
}

# ----------------------------------------------------------------------
# Init system detection
# ----------------------------------------------------------------------
detect_init_system() {
    [[ "$INIT_SYSTEM" != "auto" ]] && return
    if command_exists systemctl; then
        INIT_SYSTEM="systemd"
        return
    fi
    if command_exists rc-update; then
        INIT_SYSTEM="openrc"
        return
    fi
    if command_exists runsvdir; then
        INIT_SYSTEM="runit"
        return
    fi
    if command_exists s6-svscan; then
        INIT_SYSTEM="s6"
        return
    fi
    if command_exists dinitctl; then
        INIT_SYSTEM="dinit"
        return
    fi
    INIT_SYSTEM="unsupported"
}

detect_os_id() {
    [[ "$OS_ID" != "auto" ]] && return
    if [[ -f /etc/os-release ]]; then
        OS_ID="$(grep -oP '(?<=^ID=).*' /etc/os-release | tr -d '"')"
    else
        OS_ID="unknown"
    fi
}

# ----------------------------------------------------------------------
# Effective settings
# ----------------------------------------------------------------------
prepare_effective_settings() {
    detect_os_id
    case "$CERT_MODE" in
    selfsigned | acme) ;;
    *) die "Unsupported certificate mode: $CERT_MODE" ;;
    esac
    if [[ "$CERT_MODE" == "acme" ]]; then
        assert_nonempty_value "Timer OnCalendar" "$TIMER_ON_CALENDAR"
        assert_nonempty_value "Timer RandomizedDelaySec" "$TIMER_RANDOM_DELAY"
        if command_exists systemd-analyze; then
            systemd-analyze calendar "$TIMER_ON_CALENDAR" >/dev/null 2>&1 ||
                die "Invalid systemd OnCalendar value: $TIMER_ON_CALENDAR"
            systemd-analyze timespan "$TIMER_RANDOM_DELAY" >/dev/null 2>&1 ||
                die "Invalid systemd RandomizedDelaySec value: $TIMER_RANDOM_DELAY"
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
    [[ "$SELF_SIGNED_DAYS" =~ ^[0-9]+$ ]] || die "self_signed_days must be a positive integer: $SELF_SIGNED_DAYS"
    validate_port "Panel port" "$SUI_PANEL_PORT"
    validate_port "Subscription port" "$SUI_SUBSCRIPTION_PORT"
    [[ "$SUI_PANEL_PORT" != "$SUI_SUBSCRIPTION_PORT" ]] ||
        die "Panel port and subscription port must be different"
    validate_url_path_segment "Panel path" "$SUI_PANEL_PATH"
    validate_url_path_segment "Subscription path" "$SUI_SUBSCRIPTION_PATH"
    [[ "$SUI_PANEL_PATH" != "$SUI_SUBSCRIPTION_PATH" ]] ||
        die "Panel path and subscription path must be different"
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
    INIT_SYSTEM="$DEFAULT_INIT_SYSTEM"
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
# Install-specific requirement checks
# ----------------------------------------------------------------------
check_install_requirements() {
    require_command sqlite3 tr head grep awk
    [[ "$CERT_MODE" != "selfsigned" ]] || require_command openssl
    if [[ "$CERT_MODE" == "acme" ]]; then
        detect_init_system
        [[ "$INIT_SYSTEM" != "unsupported" ]] ||
            log_warn "No supported init system found; renewal timer will not be auto-activated"
    fi
}

# ----------------------------------------------------------------------
# Random value generators (bootstrap-specific)
# ----------------------------------------------------------------------
generate_random_port() {
    local min="$1" max="$2" range num
    range=$((max - min + 1))
    num="$(od -An -N4 -tu4 /dev/urandom | tr -d ' \n')"
    printf '%s\n' $((num % range + min))
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
# Interactive config menu
# ----------------------------------------------------------------------
_menu_item() {
    local num="$1" label="$2" value="$3"
    printf " %s) %b%-20s%b %b%s%b\n"         "$num" "$COLOR_LABEL" "$label" "$COLOR_RESET"         "$COLOR_INFO" "$value" "$COLOR_RESET"
}

run_interactive_config_menu() {
    local cert_mode domain panel_port sub_port panel_path sub_path tz choice ans
    local acme_ca="letsencrypt" acme_email=""

    cert_mode="selfsigned"
    domain=""
    tz="${TZ:-}"
    if [[ -z "$tz" && -f /etc/timezone ]]; then
        tz="$(cat /etc/timezone)"
    fi
    if [[ -z "$tz" && -L /etc/localtime ]]; then
        tz="$(readlink -f /etc/localtime | sed 's|/usr/share/zoneinfo/||' | sed 's|^./||')"
    fi
    while true; do
        panel_port=$(generate_random_port 1024 65535)
        check_tcp_port_free "$panel_port" && break
    done
    while true; do
        sub_port=$(generate_random_port 1024 65535)
        [[ "$sub_port" -ne "$panel_port" ]] && check_tcp_port_free "$sub_port" && break
    done
    panel_path="${SUI_PANEL_PATH:-panel}"
    sub_path="${SUI_SUBSCRIPTION_PATH:-sub}"

    printf "%b\n" "${COLOR_BANNER}┌─────────────────────────────────────────┐${COLOR_RESET}"
    printf "%b│         s-ui Control Setup              │%b\n" "${COLOR_BANNER}" "${COLOR_RESET}"
    printf "%b│                                         │%b\n" "${COLOR_BANNER}" "${COLOR_RESET}"
    printf "%b│  This wizard will guide you through     │%b\n" "${COLOR_BANNER}" "${COLOR_RESET}"
    printf "%b│  configuring your s-ui deployment.      │%b\n" "${COLOR_BANNER}" "${COLOR_RESET}"
    printf "%b│  You can accept defaults or enter your  │%b\n" "${COLOR_BANNER}" "${COLOR_RESET}"
    printf "%b│  own values for each setting.           │%b\n" "${COLOR_BANNER}" "${COLOR_RESET}"
    printf "%b└─────────────────────────────────────────┘%b\n" "${COLOR_BANNER}" "${COLOR_RESET}"

    while true; do
        echo
        echo "sui-control configuration"
        echo "========================="

        menu_data=(
            "Certificate mode"  "$cert_mode"
            "ACME CA"           "$acme_ca"
            "ACME Email"        "${acme_email:-<none>}"
            "Domain/IP"         "${domain:-<none>}"
            "Panel port"        "$panel_port"
            "Subscription port" "$sub_port"
            "Panel path"        "$panel_path"
            "Subscription path" "$sub_path"
            "Timezone"          "${tz:-<none>}"
        )
        for ((i = 0; i < ${#menu_data[@]}; i += 2)); do
            _menu_item "$((i / 2 + 1))" "${menu_data[i]}" "${menu_data[i+1]}"
        done

        local proto="https"
        local host="${domain:-localhost}"
        echo " ─────────────────────────────────────"
        printf "    %bPanel:%b %s://%s:%s/%s\n" "$COLOR_LABEL" "$COLOR_RESET" "$proto" "$host" "$panel_port" "$panel_path"
        printf "    %bSub:%b   %s://%s:%s/%s\n" "$COLOR_LABEL" "$COLOR_RESET" "$proto" "$host" "$sub_port" "$sub_path"
        echo
        echo " a) Accept and continue"
        echo " q) Quit without saving"
        echo
        printf "%bSelect option: %b" "$COLOR_QUESTION" "$COLOR_RESET" >&2
        read -r choice
        case "$choice" in
        1)
            echo "Certificate mode:"
            echo "  1) selfsigned"
            echo "  2) acme"
            printf "%bSelect [1]: %b" "$COLOR_QUESTION" "$COLOR_RESET" >&2
            read -r ans
            case "${ans:-1}" in
            1)
                cert_mode="selfsigned"
                domain=""
                ;;
            2)
                cert_mode="acme"
                echo "ACME CA:"
                echo "  1) letsencrypt"
                echo "  2) zerossl"
                printf "%bSelect [1]: %b" "$COLOR_QUESTION" "$COLOR_RESET" >&2
                read -r ans
                case "${ans:-1}" in
                1) acme_ca="letsencrypt" ;;
                2) acme_ca="zerossl"
                   printf "%bEmail for ZeroSSL registration (optional, change CA later to skip): %b" "$COLOR_QUESTION" "$COLOR_RESET" >&2
                   read -r ans
                   acme_email="$ans"
                   ;;
                esac
                printf "%bDomain or IP for ACME: %b" "$COLOR_QUESTION" "$COLOR_RESET" >&2
                read -r domain
                ;;
            *) log_warn "Invalid selection." ;;
            esac
            ;;
        2)
            echo "ACME CA:"
            echo "  1) letsencrypt"
            echo "  2) zerossl"
            printf "%bSelect [${acme_ca}]: %b" "$COLOR_QUESTION" "$COLOR_RESET" >&2
            read -r ans
            case "${ans:-1}" in
            1) acme_ca="letsencrypt" ;;
            2) acme_ca="zerossl" ;;
            *) log_warn "Invalid selection." ;;
            esac
            ;;
        3)
            printf "%bEmail for ACME registration (optional, required for ZeroSSL): %b" "$COLOR_QUESTION" "$COLOR_RESET" >&2
            read -r ans
            acme_email="$ans"
            ;;
        4)
            if [[ "$cert_mode" == "acme" ]]; then
                printf "%bDomain or IP for ACME: %b" "$COLOR_QUESTION" "$COLOR_RESET" >&2
                read -r domain
            else
                log_warn "Domain is only used in acme mode. Change certificate mode first."
            fi
            ;;
        5)
            printf "%bPanel port [$panel_port]: %b" "$COLOR_QUESTION" "$COLOR_RESET" >&2
            read -r ans
            panel_port="${ans:-$panel_port}"
            is_valid_port "Panel port" "$panel_port" || { log_warn "Invalid port"; continue; }
            ;;
        6)
            printf "%bSubscription port [$sub_port]: %b" "$COLOR_QUESTION" "$COLOR_RESET" >&2
            read -r ans
            sub_port="${ans:-$sub_port}"
            is_valid_port "Subscription port" "$sub_port" || { log_warn "Invalid port"; continue; }
            ;;
        7)
            printf "%bPanel path [$panel_path]: %b" "$COLOR_QUESTION" "$COLOR_RESET" >&2
            read -r ans
            panel_path="${ans:-$panel_path}"
            is_valid_url_path_segment "Panel path" "$panel_path" || { log_warn "Invalid path"; continue; }
            ;;
        8)
            printf "%bSubscription path [$sub_path]: %b" "$COLOR_QUESTION" "$COLOR_RESET" >&2
            read -r ans
            sub_path="${ans:-$sub_path}"
            is_valid_url_path_segment "Subscription path" "$sub_path" || { log_warn "Invalid path"; continue; }
            ;;
        9)
            printf "%bTimezone [$tz]: %b" "$COLOR_QUESTION" "$COLOR_RESET" >&2
            read -r ans
            tz="${ans:-$tz}"
            ;;
        a | A)
            if [[ "$cert_mode" == "acme" ]]; then
                if [[ -z "$domain" ]]; then
                    log_warn "Domain/IP is required for acme mode."
                    continue
                fi
                if [[ "$acme_ca" == "zerossl" && -z "$acme_email" ]]; then
                    log_warn "ZeroSSL requires an email for account registration. Switch to letsencrypt or provide an email (option 3)."
                    continue
                fi
            fi
            break
            ;;
        q | Q)
            echo "Aborted."
            exit 0
            ;;
        *)
            log_warn "Invalid option: $choice"
            ;;
        esac
    done

    mkdir -p "$CONFIG_DIR"
    cat >"$CONFIG_DIR/$CONFIG_FILE_NAME" <<EOF
# sui-control configuration
cert_mode=$cert_mode
panel_port=$panel_port
subscription_port=$sub_port
panel_path=$panel_path
subscription_path=$sub_path
EOF
    if [[ -n "$domain" ]]; then
        echo "domain=$domain" >>"$CONFIG_DIR/$CONFIG_FILE_NAME"
    fi
    if [[ -n "$acme_ca" ]]; then
        echo "acme_ca=$acme_ca" >>"$CONFIG_DIR/$CONFIG_FILE_NAME"
    fi
    if [[ -n "$acme_email" ]]; then
        echo "acme_email=$acme_email" >>"$CONFIG_DIR/$CONFIG_FILE_NAME"
    fi
    if [[ -n "$tz" ]]; then
        echo "tz=$tz" >>"$CONFIG_DIR/$CONFIG_FILE_NAME"
    fi

    CERT_MODE="$cert_mode"
    DOMAIN="${domain:-}"
    TZ="$tz"
    ACME_CA="$acme_ca"
    ACME_EMAIL="$acme_email"
    SUI_PANEL_PORT="$panel_port"
    SUI_SUBSCRIPTION_PORT="$sub_port"
    SUI_PANEL_PATH="$panel_path"
    SUI_SUBSCRIPTION_PATH="$sub_path"

}

# ----------------------------------------------------------------------
# Self-signed certificate generation
# ----------------------------------------------------------------------
generate_self_signed_cert() {
    local cert_root cert_cn tmp_conf
    require_command openssl
    cert_root="$RUNTIME_CERT_DIR/$SELF_SIGNED_DIR_NAME"
    cert_cn="${DOMAIN:-localhost}"
    tmp_conf="$(mktemp)"
    # shellcheck disable=SC2064
    trap "rm -f '$tmp_conf'" EXIT
    mkdir -p "$cert_root"
    cat >"$tmp_conf" <<EOF_SSL
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
    openssl req -x509 -nodes -newkey rsa:2048 -days "$SELF_SIGNED_DAYS"         -keyout "$cert_root/privkey.pem"         -out "$cert_root/fullchain.pem"         -config "$tmp_conf" >/dev/null 2>&1
    chmod 0600 "$cert_root/privkey.pem"
    chmod 0644 "$cert_root/fullchain.pem"
    rm -f "$tmp_conf"
    trap - EXIT
}

# ----------------------------------------------------------------------
# Container lifecycle (service commands)
# ----------------------------------------------------------------------
assert_nonempty_value() {
    local label="$1" value="$2"
    [[ -n "$value" ]] || die "$label must not be empty"
}

_compute_container_stamp() {
    printf '%s' "v2|${SUI_PANEL_PORT}|${SUI_SUBSCRIPTION_PORT}|${SUI_IMAGE}|${TZ}"
}

_update_config_stamp() {
    local new_stamp="$1"
    local escaped_stamp
    local config_file="$CONFIG_DIR/$CONFIG_FILE_NAME"
    [[ -f "$config_file" ]] || return
    escaped_stamp="$(printf '%s\n' "$new_stamp" | sed 's/[#/&\\]/\\&/g')"
    if grep -q '^container_stamp=' "$config_file" 2>/dev/null; then
        sed -i "s/^container_stamp=.*/container_stamp=$escaped_stamp/" "$config_file"
    else
        echo "container_stamp=$new_stamp" >>"$config_file"
    fi
}


start_containers() {
    local new_stamp

    if [[ -n "${TZ:-}" && ! "$TZ" =~ ^[A-Za-z0-9_+/-]+$ ]]; then
        log_warn "Invalid TZ value, skipping timezone configuration: $TZ"
        unset TZ
    fi

    new_stamp="$(_compute_container_stamp)"

    if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$CONTAINER_NAME" &&
        [[ "$CONTAINER_STAMP" == "$new_stamp" ]]; then
        return 0
    fi

    docker stop "$CONTAINER_NAME" >/dev/null 2>&1 || true
    docker rm "$CONTAINER_NAME" >/dev/null 2>&1 || true
    docker run -d --restart=unless-stopped --network host --name "$CONTAINER_NAME" ${TZ:+-e TZ="$TZ"} -v "$RUNTIME_DATA_DIR:/app/db" -v "$RUNTIME_CERT_DIR:/certs:ro" "$SUI_IMAGE" >/dev/null
    _update_config_stamp "$new_stamp"
    CONTAINER_STAMP="$new_stamp"
}

# ----------------------------------------------------------------------
# Container lifecycle helpers
# ----------------------------------------------------------------------
stop_containers() {
    docker stop "$CONTAINER_NAME" >/dev/null 2>&1 || true
}

restart_containers() {
    stop_containers
    start_containers
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
    cat >"$control_service_file" <<EOF_CONTROL
[Unit]
Description=SUI-Control
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStartPre=+/sbin/sysctl -q -w net.core.default_qdisc=fq
ExecStartPre=+/sbin/sysctl -q -w net.ipv4.tcp_congestion_control=bbr
ExecStart=$PACKAGE_DIR/sui-control.sh start
ExecStop=$PACKAGE_DIR/sui-control.sh stop
User=$SUI_CONTROL_USER
Group=$SUI_CONTROL_USER

[Install]
WantedBy=multi-user.target
EOF_CONTROL

    # Renew service (called by timer)
    cat >"$renew_service_file" <<EOF_RENEW
[Unit]
Description=SUI-Control certificate renewal
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$PACKAGE_DIR/sui-control.sh renew
User=$SUI_CONTROL_USER
Group=$SUI_CONTROL_USER

[Install]
WantedBy=multi-user.target
EOF_RENEW

    # Timer
    cat >"$timer_file" <<EOF_TIMER
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
    if [[ $EUID -eq 0 ]]; then
        ln -sfn "$control_service_file" "$control_link"
        ln -sfn "$renew_service_file" "$renew_svc_link"
        ln -sfn "$timer_file" "$timer_link"
        systemctl daemon-reload
        systemctl enable --now "$SYSTEMD_CONTROL_SERVICE_NAME" >/dev/null 2>&1 || true
        systemctl enable --now "$SYSTEMD_RENEW_TIMER_NAME" >/dev/null 2>&1 || true
    else
        ACTIVATION_CMD="systemctl daemon-reload && systemctl enable --now $SYSTEMD_CONTROL_SERVICE_NAME $SYSTEMD_RENEW_TIMER_NAME"
    fi
}
_remove_timer_systemd() {
    local control_link="$SYSTEMD_DST_DIR/$SYSTEMD_CONTROL_SERVICE_NAME"
    local renew_svc_link="$SYSTEMD_DST_DIR/$SYSTEMD_RENEW_SERVICE_NAME"
    local timer_link="$SYSTEMD_DST_DIR/$SYSTEMD_RENEW_TIMER_NAME"
    if command_exists systemctl; then
        systemctl disable --now "$SYSTEMD_CONTROL_SERVICE_NAME" >/dev/null 2>&1 || true
        systemctl disable --now "$SYSTEMD_RENEW_TIMER_NAME" >/dev/null 2>&1 || true
        systemctl stop "$SYSTEMD_RENEW_SERVICE_NAME" >/dev/null 2>&1 || true
    fi
    rm -f "$control_link" "$renew_svc_link" "$timer_link"
    if command_exists systemctl; then systemctl daemon-reload || true; fi
}

# ----------------------------------------------------------------------
# Timer system — OpenRC
# ----------------------------------------------------------------------
_install_timer_openrc() {
    local init_file="/etc/init.d/sui-control"
    cat >"$init_file" <<OPENRC_INIT
#!/sbin/openrc-run
# SPDX-License-Identifier: GPL-3.0-or-later

description="SUI-Control"

command="$PACKAGE_DIR/sui-control.sh"
command_args=""
pidfile="/run/\${RC_SVCNAME}.pid"

depend() {
    need net
    use docker
}

start() {
    ebegin "Starting s-ui"
    start-stop-daemon --start --user $SUI_CONTROL_USER --exec $PACKAGE_DIR/sui-control.sh -- start
    eend \$?
}

stop() {
    ebegin "Stopping s-ui"
    $PACKAGE_DIR/sui-control.sh stop
    eend \$?
}
OPENRC_INIT
    chmod 0755 "$init_file"

    chmod 0755 "$init_file"

    _create_cron_job
    if command_exists rc-update; then
        if [[ $EUID -eq 0 ]]; then
            rc-update add sui-control default || true
        else
            ACTIVATION_CMD="rc-update add sui-control default"
        fi
    fi
}

_remove_timer_openrc() {
    if command_exists rc-update; then rc-update del sui-control default >/dev/null 2>&1 || true; fi
    rm -f "/etc/init.d/sui-control"
    _remove_cron_job
}

# ----------------------------------------------------------------------
# Timer system — runit
# ----------------------------------------------------------------------
_install_timer_runit() {
    local sv_dir="/etc/sv/sui-control"
    mkdir -p "$sv_dir"
    cat >"$sv_dir/run" <<RUNIT_RUN
#!/bin/sh
exec chpst -u $SUI_CONTROL_USER $PACKAGE_DIR/sui-control.sh start
RUNIT_RUN
    chmod 0755 "$sv_dir/run"

    cat >"$sv_dir/finish" <<RUNIT_FINISH
#!/bin/sh
exec $PACKAGE_DIR/sui-control.sh stop
RUNIT_FINISH
    chmod 0755 "$sv_dir/finish"

    _create_cron_job
    if [[ $EUID -eq 0 ]]; then
        ln -sfn "$sv_dir" "/etc/service/sui-control" 2>/dev/null || true
    else
        ACTIVATION_CMD="ln -sfn $sv_dir /etc/service/sui-control"
    fi
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
    mkdir -p "$S6_SERVICE_DIR"
    cat >"$S6_SERVICE_DIR/run" <<S6_RUN
#!/bin/execlineb -P
s6-setuidgid $SUI_CONTROL_USER
$PACKAGE_DIR/sui-control.sh start
S6_RUN
    chmod 0755 "$S6_SERVICE_DIR/run"

    _create_cron_job
    if [[ $EUID -eq 0 ]]; then
        ln -sfn "$S6_SERVICE_DIR" "/etc/s6/service/sui-control" 2>/dev/null || true
    else
        ACTIVATION_CMD="ln -sfn $S6_SERVICE_DIR /etc/s6/service/sui-control"
    fi
}

_remove_timer_s6() {
    rm -rf "$S6_SERVICE_DIR"
    rm -f "/etc/s6/service/sui-control"
    _remove_cron_job
}

# ----------------------------------------------------------------------
# Timer system — dinit
# ----------------------------------------------------------------------
_install_timer_dinit() {
    local sv_file="/etc/dinit.d/sui-control"
    cat >"$sv_file" <<DINIT_SVC
type = process
command = $PACKAGE_DIR/sui-control.sh start
stop-command = $PACKAGE_DIR/sui-control.sh stop
restart-command = $PACKAGE_DIR/sui-control.sh restart
run-as-user = $SUI_CONTROL_USER

depends-on = docker
waits-for = docker
DINIT_SVC

    _create_cron_job
    if command_exists dinitctl; then
        if [[ $EUID -eq 0 ]]; then
            dinitctl enable sui-control || true
        else
            ACTIVATION_CMD="dinitctl enable sui-control"
        fi
    fi
}

_remove_timer_dinit() {
    if command_exists dinitctl; then dinitctl disable sui-control >/dev/null 2>&1 || true; fi
    rm -f "/etc/dinit.d/sui-control"
    _remove_cron_job
}

# ----------------------------------------------------------------------
# Cron helper
# ----------------------------------------------------------------------
# NOTE: supports only simple OnCalendar patterns. Complex expressions
# (ranges like Mon..Fri, wildcards like *-*-*) may produce incorrect cron
# output. Test your pattern if using custom --timer-on-calendar.

_systemd_oncalendar_to_cron() {
    local cal="$1" day_part time_part hour min d nums days
    case "$cal" in
    daily | weekly | monthly | yearly | annually | @*)
        case "$cal" in
        daily) printf '%s\n' '@daily' ;;
        weekly) printf '%s\n' '@weekly' ;;
        monthly) printf '%s\n' '@monthly' ;;
        yearly | annually) printf '%s\n' '@yearly' ;;
        *) printf '%s\n' "$cal" ;;
        esac
        return
        ;;
    esac
    day_part="${cal%% *}"
    time_part="${cal##* }"
    hour="${time_part%%:*}"
    min="${time_part#*:}"
    min="${min%%:*}"
    if [[ "$day_part" == *,* ]]; then
        nums=""
        IFS=',' read -r -a days <<<"$day_part"
        for d in "${days[@]}"; do
            case "$d" in
            Sun) nums="${nums},0" ;;
            Mon) nums="${nums},1" ;;
            Tue) nums="${nums},2" ;;
            Wed) nums="${nums},3" ;;
            Thu) nums="${nums},4" ;;
            Fri) nums="${nums},5" ;;
            Sat) nums="${nums},6" ;;
            *)
                nums=""
                break
                ;;
            esac
        done
        if [[ -n "$nums" ]]; then
            printf '%s %s * * %s\n' "$min" "$hour" "${nums#,}"
            return
        fi
    fi
    case "$day_part" in
    Mon) printf '%s %s * * 1\n' "$min" "$hour" ;;
    Sat,Sun) printf '%s %s * * 0,6\n' "$min" "$hour" ;;
    *) printf '%s %s * * *\n' "$min" "$hour" ;;
    esac
}

_create_cron_job() {
    local cron_file="$CRON_DST_DIR/$CRON_FILE_NAME"
    local cron_schedule
    cron_schedule="$(_systemd_oncalendar_to_cron "$TIMER_ON_CALENDAR")"
    mkdir -p "$CRON_DST_DIR"
    cat >"$cron_file" <<CRONEOF
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

$cron_schedule $SUI_CONTROL_USER $PACKAGE_DIR/sui-control.sh renew
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
    ACTIVATION_CMD=""
    detect_init_system
    case "$INIT_SYSTEM" in
    systemd) _install_timer_systemd ;;
    openrc) _install_timer_openrc ;;
    runit) _install_timer_runit ;;
    s6) _install_timer_s6 ;;
    dinit) _install_timer_dinit ;;
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
    openrc) _remove_timer_openrc ;;
    runit) _remove_timer_runit ;;
    s6) _remove_timer_s6 ;;
    dinit) _remove_timer_dinit ;;
    *) _remove_cron_job ;;
    esac
}

# ----------------------------------------------------------------------
# Runtime artifact initialization and certificate renewal
# ----------------------------------------------------------------------
issue_certificate() {
    local resolved_bin_dir
    ensure_config_loaded

    resolved_bin_dir="$RUNTIME_BIN_DIR"
    if [[ "$CERT_MODE" == "selfsigned" ]]; then
        generate_self_signed_cert
        restart_sui_container
    elif [[ "$CERT_MODE" == "acme" ]]; then
        [[ -x "$resolved_bin_dir/$ACME_CERT_SCRIPT_NAME" ]] || die "ACME cert script not found: $resolved_bin_dir/$ACME_CERT_SCRIPT_NAME"
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

# ----------------------------------------------------------------------
# Template variable whitelist (derived from sui-control.conf.tpl)
# ----------------------------------------------------------------------
_get_shell_fmt_from_config_tpl() {
    local tpl="$PACKAGE_DIR/templates/sui-control.conf.tpl"
    [[ -f "$tpl" ]] || die "Config template not found: $tpl"
    grep -oP '\$\{[A-Z_][A-Z0-9_]*\}' "$tpl" | sort -u | tr '\n' ' '
}

# ----------------------------------------------------------------------
# Template substitution for FHS-mode setup
# ----------------------------------------------------------------------
substitute_template() {
    local template="$1" output="$2"
    [[ -f "$template" ]] || die "Template not found: $template"
    local shell_fmt entry v
    shell_fmt="$(_get_shell_fmt_from_config_tpl)"
    (
        for entry in $shell_fmt; do
            [[ -z "$entry" ]] && continue
            v="${entry#\$\{}"
            v="${v%\}}"
            export "${v}=${!v:-}"
        done
        envsubst "$shell_fmt" <"$template" >"$output"
    )
}

# ----------------------------------------------------------------------

# ----------------------------------------------------------------------
# Shared core for bootstrap_installation and install_control_script
# ----------------------------------------------------------------------
_run_installation_core() {
    local db_script="$RUNTIME_BIN_DIR/$DB_CONFIG_SCRIPT_NAME"
    local db_path="$RUNTIME_DATA_DIR/s-ui.db"
    [[ -x "$db_script" ]] || die "Database configuration script not found: $db_script"

    ensure_config_loaded "$CONFIG_DIR/$CONFIG_FILE_NAME"

    start_containers

    # shellcheck disable=SC2153
    local db_timeout="$DB_TIMEOUT" db_elapsed=0
    log_info "Waiting for s-ui to initialize database (up to ${db_timeout}s)..."
    while ((db_elapsed < db_timeout)); do
        [[ -f "$db_path" && -s "$db_path" ]] && break
        sleep "$DB_POLL_INTERVAL"
        db_elapsed=$((db_elapsed + DB_POLL_INTERVAL))
    done
    if [[ ! -f "$db_path" || ! -s "$db_path" ]]; then
        docker logs "$CONTAINER_NAME" 2>/dev/null | tail -n 50 >&2 || true
        die "Database file was not created in time: $db_path"
    fi

    stop_containers
    [[ -f "$db_path" ]] || die "Database file not found after first start: $db_path"

    export PACKAGE_DIR TZ
    "$db_script" "$INSTALL_GENERATED_USERNAME" "$INSTALL_GENERATED_PASSWORD"
    start_containers

    issue_certificate
    install_renewal_timer
    if [[ -n "${ACTIVATION_CMD:-}" ]]; then
        echo
        log_info "Service activation requires root."
        echo "  Command: sudo $ACTIVATION_CMD"
        printf "%bActivate now with sudo? [y/N]: %b" "$COLOR_QUESTION" "$COLOR_RESET" >&2
        read -r ans
        case "${ans,,}" in
        y | yes)
            if sudo bash -c "$ACTIVATION_CMD"; then
                log_info "Activated"
            else
                log_warn "Activation failed"
            fi
            ;;
        esac
    fi
    ensure_file_ownership "$CONFIG_DIR" "$RUNTIME_DIR"

    echo
    echo "============================================"
    echo "       SUI-Control Setup Complete"
    echo "============================================"
    local _proto="https"
    local _host="${DOMAIN:-localhost}"
    printf "  Panel:      %s://%s:%s/%s\n" "$_proto" "$_host" "$SUI_PANEL_PORT" "$SUI_PANEL_PATH"
    printf "  Sub:        %s://%s:%s/%s\n" "$_proto" "$_host" "$SUI_SUBSCRIPTION_PORT" "$SUI_SUBSCRIPTION_PATH"
    echo "  Username:   $INSTALL_GENERATED_USERNAME"
    echo "  Password:   $INSTALL_GENERATED_PASSWORD"
    echo "============================================"
}

setup_sui_user() {
    if ! getent group "$SUI_CONTROL_USER" &>/dev/null; then
        log_info "Creating system group $SUI_CONTROL_USER"
        groupadd --system "$SUI_CONTROL_USER"
    fi
    if id "$SUI_CONTROL_USER" &>/dev/null; then
        log_info "User $SUI_CONTROL_USER already exists"
    else
        log_info "Creating system user $SUI_CONTROL_USER"
        useradd --system --gid "$SUI_CONTROL_USER" --no-create-home --shell /usr/sbin/nologin "$SUI_CONTROL_USER"
    fi
    if ! groups "$SUI_CONTROL_USER" 2>/dev/null | grep -qw "$SUI_CONTROL_USER"; then
        log_info "Adding $SUI_CONTROL_USER to $SUI_CONTROL_USER group"
        usermod -aG "$SUI_CONTROL_USER" "$SUI_CONTROL_USER" 2>/dev/null || true
    fi
    if ! groups "$SUI_CONTROL_USER" 2>/dev/null | grep -qw docker; then
        log_info "Adding $SUI_CONTROL_USER to docker group"
        usermod -aG docker "$SUI_CONTROL_USER"
    fi
}

# ----------------------------------------------------------------------
# Bootstrap setup (FHS mode — first-time or re-configuration)
# ----------------------------------------------------------------------
bootstrap_installation() {
    setup_sui_user
    _randomize_if_default SUI_PANEL_PORT "$DEFAULT_SUI_PANEL_PORT" CLI_PANEL_PORT_SET "" generate_random_port 20000 40000
    _randomize_if_default SUI_SUBSCRIPTION_PORT "$DEFAULT_SUI_SUBSCRIPTION_PORT" CLI_SUBSCRIPTION_PORT_SET "$SUI_PANEL_PORT" generate_random_port 20000 40000
    _randomize_if_default SUI_PANEL_PATH "$DEFAULT_SUI_PANEL_PATH" CLI_PANEL_PATH_SET "" generate_random_path_segment
    _randomize_if_default SUI_SUBSCRIPTION_PATH "$DEFAULT_SUI_SUBSCRIPTION_PATH" CLI_SUBSCRIPTION_PATH_SET "$SUI_PANEL_PATH" generate_random_path_segment

    [[ "$BATCH_INSTALL" != "1" ]] && run_interactive_config_menu

    [[ -n "$INSTALL_GENERATED_USERNAME" ]] || INSTALL_GENERATED_USERNAME="$(generate_random_alnum 20)"
    [[ -n "$INSTALL_GENERATED_PASSWORD" ]] || INSTALL_GENERATED_PASSWORD="$(generate_random_alnum 20)"

    prepare_effective_settings
    check_install_requirements

    check_tcp_port_free "$SUI_PANEL_PORT" || die "Panel TCP port is already in use: $SUI_PANEL_PORT"
    check_tcp_port_free "$SUI_SUBSCRIPTION_PORT" || die "Subscription TCP port is already in use: $SUI_SUBSCRIPTION_PORT"

    if [[ "$CERT_MODE" == "acme" ]]; then
        local urls=("https://acme-v02.api.letsencrypt.org/directory" "https://www.google.com/generate_204")
        local url connected="0"
        for url in "${urls[@]}"; do
            if docker run --rm "$CURL_TEST_IMAGE" -fsSL --connect-timeout 10 --max-time 20 "$url" >/dev/null 2>&1; then
                connected="1"
                break
            fi
        done
        [[ "$connected" == "1" ]] || die "Docker network connectivity check failed for all test endpoints"
    fi

    mkdir -p "$RUNTIME_BIN_DIR" "$RUNTIME_DATA_DIR" "$RUNTIME_CERT_DIR" "$RUNTIME_ACME_DIR" "$RUNTIME_SYSTEMD_DIR"
    chmod -R g+w "$RUNTIME_DIR" 2>/dev/null || true

    substitute_template "$PACKAGE_DIR/templates/sui-control.conf.tpl" "$CONFIG_DIR/$CONFIG_FILE_NAME"
    chmod 0660 "$CONFIG_DIR/$CONFIG_FILE_NAME"
    chgrp "$SUI_CONTROL_USER" "$CONFIG_DIR/$CONFIG_FILE_NAME" 2>/dev/null || true
    log_info "Config written to $CONFIG_DIR/$CONFIG_FILE_NAME"

    if [[ "$CERT_MODE" == "acme" ]]; then
        substitute_template "$PACKAGE_DIR/templates/acme-cert.sh.tpl" "$RUNTIME_BIN_DIR/$ACME_CERT_SCRIPT_NAME"
        chmod 0770 "$RUNTIME_BIN_DIR/$ACME_CERT_SCRIPT_NAME"
        chgrp "$SUI_CONTROL_USER" "$RUNTIME_BIN_DIR/$ACME_CERT_SCRIPT_NAME" 2>/dev/null || true
    fi
    substitute_template "$PACKAGE_DIR/templates/s-ui-db-configure.sh.tpl" "$RUNTIME_BIN_DIR/$DB_CONFIG_SCRIPT_NAME"
    chmod 0770 "$RUNTIME_BIN_DIR/$DB_CONFIG_SCRIPT_NAME"
    chgrp "$SUI_CONTROL_USER" "$RUNTIME_BIN_DIR/$DB_CONFIG_SCRIPT_NAME" 2>/dev/null || true

    _run_installation_core "Setup completed"
}
