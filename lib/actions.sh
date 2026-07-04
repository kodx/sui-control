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
        [[ "$INIT_SYSTEM" != "unsupported" ]] \
            || log_warn "No supported init system found; renewal timer will not be auto-activated"
    fi
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
    "$generator" > "$path" || { umask "$old_umask"; die "Failed to create $label: $path"; }
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

_compute_container_stamp() {
    local ports
    ports="$(get_inbound_ports | tr '\n' ',' | sed 's/,$//')"
    printf '%s' "v1|${ports}|${SUI_PANEL_PORT}|${SUI_SUBSCRIPTION_PORT}|${SUI_IMAGE}|${TZ}"
}

get_inbound_ports() {
    local db_path="$RUNTIME_DATA_DIR/s-ui.db"
    [[ -f "$db_path" ]] || return
    sqlite3 "$db_path" \
      "SELECT DISTINCT json_extract(options, '$.listen_port') FROM inbounds \
       WHERE json_extract(options, '$.listen_port') IS NOT NULL ORDER BY 1;"
}

_update_config_stamp() {
    local new_stamp="$1"
    local config_file="$CONFIG_DIR/$CONFIG_FILE_NAME"
    [[ -f "$config_file" ]] || return
    if grep -q '^container_stamp=' "$config_file" 2>/dev/null; then
        sed -i "s#^container_stamp=.*#container_stamp=$new_stamp#" "$config_file"
    else
        echo "container_stamp=$new_stamp" >> "$config_file"
    fi
}

start_containers() {
    local port db_path new_stamp
    local ports_args=()

    db_path="$RUNTIME_DATA_DIR/s-ui.db"
    if [[ -f "$db_path" ]]; then
        while IFS= read -r port; do
            [[ -z "$port" ]] && continue
            ports_args+=(-p "$port:$port")
        done < <(get_inbound_ports)
    fi

    ports_args+=(-p "$SUI_PANEL_PORT:$SUI_PANEL_PORT")
    ports_args+=(-p "$SUI_SUBSCRIPTION_PORT:$SUI_SUBSCRIPTION_PORT")

    new_stamp="$(_compute_container_stamp)"

    if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$CONTAINER_NAME" && \
       [[ "$CONTAINER_STAMP" == "$new_stamp" ]]; then
        return 0
    fi

    docker network inspect "$DOCKER_NETWORK" >/dev/null 2>&1 || docker network create "$DOCKER_NETWORK" >/dev/null
    docker stop "$CONTAINER_NAME" 2>/dev/null || true
    docker rm "$CONTAINER_NAME" 2>/dev/null || true

    docker run -d --restart=unless-stopped --network "$DOCKER_NETWORK" --name "$CONTAINER_NAME" "${ports_args[@]}" -e "TZ=${TZ}" -v "$RUNTIME_DATA_DIR:/app/db" -v "$RUNTIME_CERT_DIR:/certs" "$SUI_IMAGE" >/dev/null

    _update_config_stamp "$new_stamp"
    CONTAINER_STAMP="$new_stamp"
}

stop_containers() {
    docker stop "$CONTAINER_NAME" 2>/dev/null || true
}

restart_containers() {
    stop_containers
    docker rm "$CONTAINER_NAME" 2>/dev/null || true
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
User=$SUI_CONTROL_USER

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
User=$SUI_CONTROL_USER

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
    cat > "$init_file" <<OPENRC_INIT
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
    start-stop-daemon --stop --user $SUI_CONTROL_USER --exec $PACKAGE_DIR/sui-control.sh
    $PACKAGE_DIR/sui-control.sh stop
    eend \$?
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
    cat > "$sv_dir/run" <<RUNIT_RUN
#!/bin/sh
exec chpst -u $SUI_CONTROL_USER $PACKAGE_DIR/sui-control.sh start
RUNIT_RUN
    chmod 0755 "$sv_dir/run"

    cat > "$sv_dir/finish" <<RUNIT_FINISH
#!/bin/sh
exec $PACKAGE_DIR/sui-control.sh stop
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
    mkdir -p "$S6_SERVICE_DIR"
    cat > "$S6_SERVICE_DIR/run" <<S6_RUN
#!/bin/execlineb -P
s6-setuidgid $SUI_CONTROL_USER
$PACKAGE_DIR/sui-control.sh start
S6_RUN
    chmod 0755 "$S6_SERVICE_DIR/run"

    _create_cron_job
    mkdir -p /etc/s6
    ln -sfn "$S6_SERVICE_DIR" "/etc/s6/service" 2>/dev/null || true
}

_remove_timer_s6() {
    rm -rf "$S6_SERVICE_DIR"
    _remove_cron_job
}

# ----------------------------------------------------------------------
# Timer system — dinit
# ----------------------------------------------------------------------
_install_timer_dinit() {
    local sv_file="/etc/dinit.d/sui-control"
    cat > "$sv_file" <<DINIT_SVC
type = process
command = $PACKAGE_DIR/sui-control.sh start
stop-command = $PACKAGE_DIR/sui-control.sh stop
restart-command = $PACKAGE_DIR/sui-control.sh restart
run-as-user = $SUI_CONTROL_USER

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
    local cal="$1" day_part time_part hour min d nums days
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
    if [[ "$day_part" == *,* ]]; then
        nums=""
        IFS=',' read -r -a days <<< "$day_part"
        for d in "${days[@]}"; do
            case "$d" in
                Sun) nums="${nums},0" ;;
                Mon) nums="${nums},1" ;;
                Tue) nums="${nums},2" ;;
                Wed) nums="${nums},3" ;;
                Thu) nums="${nums},4" ;;
                Fri) nums="${nums},5" ;;
                Sat) nums="${nums},6" ;;
                *)   nums=""; break ;;
            esac
        done
        if [[ -n "$nums" ]]; then
            printf '%s %s * * %s\n' "$min" "$hour" "${nums#,}"
            return
        fi
    fi
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
issue_certificate() {
    local resolved_bin_dir
    ensure_config_loaded

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

# ----------------------------------------------------------------------
# Template substitution for FHS-mode setup
# ----------------------------------------------------------------------
substitute_template() {
    local template="$1" output="$2"
    [[ -f "$template" ]] || die "Template not found: $template"
    local vars
    vars="DOMAIN TZ TIMER_ON_CALENDAR TIMER_RANDOM_DELAY CERT_MODE"
    vars="$vars SELF_SIGNED_DAYS SUI_PANEL_PORT SUI_SUBSCRIPTION_PORT"
    vars="$vars SUI_PANEL_PATH SUI_SUBSCRIPTION_PATH"
    vars="$vars PACKAGE_DIR RUNTIME_CERT_DIR RUNTIME_BIN_DIR RUNTIME_DATA_DIR RUNTIME_ACME_DIR"
    vars="$vars CONFIG_DIR SELF_SIGNED_DIR_NAME SUI_CONTROL_USER"
    vars="$vars ACME_CERT_SCRIPT_NAME DB_CONFIG_SCRIPT_NAME"
    vars="$vars INBOUND_PORTS INIT_SYSTEM SUI_IMAGE CURL_TEST_IMAGE CONTAINER_STAMP ACME_IMAGE"
    vars="$vars SYSTEMD_CONTROL_SERVICE_NAME SYSTEMD_RENEW_SERVICE_NAME SYSTEMD_RENEW_TIMER_NAME"
    vars="$vars SYSTEMD_DST_DIR CRON_DST_DIR CRON_FILE_NAME"
    vars="$vars INSTALL_GENERATED_USERNAME INSTALL_GENERATED_PASSWORD"
    (
        for v in $vars; do
            export "${v}=${!v:-}"
        done
        envsubst < "$template" > "$output"
    )
}

# ----------------------------------------------------------------------
# Bootstrap setup (FHS mode — first-time or re-configuration)
# ----------------------------------------------------------------------
bootstrap_installation() {
    setup_sui_user
    _randomize_if_default SUI_PANEL_PORT        "$DEFAULT_SUI_PANEL_PORT"        CLI_PANEL_PORT_SET        ""               generate_random_port 20000 40000
    _randomize_if_default SUI_SUBSCRIPTION_PORT "$DEFAULT_SUI_SUBSCRIPTION_PORT" CLI_SUBSCRIPTION_PORT_SET "$SUI_PANEL_PORT" generate_random_port 20000 40000
    _randomize_if_default SUI_PANEL_PATH        "$DEFAULT_SUI_PANEL_PATH"        CLI_PANEL_PATH_SET        ""               generate_random_path_segment
    _randomize_if_default SUI_SUBSCRIPTION_PATH "$DEFAULT_SUI_SUBSCRIPTION_PATH" CLI_SUBSCRIPTION_PATH_SET "$SUI_PANEL_PATH" generate_random_path_segment

    [[ "$BATCH_INSTALL" != "1" ]] && run_interactive_installation_dialog

    [[ -n "$INSTALL_GENERATED_USERNAME" ]] || INSTALL_GENERATED_USERNAME="$(generate_random_alnum 20)"
    [[ -n "$INSTALL_GENERATED_PASSWORD" ]] || INSTALL_GENERATED_PASSWORD="$(generate_random_alnum 20)"

    prepare_effective_settings
    check_install_requirements

    check_tcp_port_free "$SUI_PANEL_PORT"        || die "Panel TCP port is already in use: $SUI_PANEL_PORT"
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

    substitute_template "$PACKAGE_DIR/templates/sui-control.conf.tpl"  "$CONFIG_DIR/$CONFIG_FILE_NAME"
    chmod 0600 "$CONFIG_DIR/$CONFIG_FILE_NAME"

    if [[ "$CERT_MODE" == "acme" ]]; then
        substitute_template "$PACKAGE_DIR/templates/acme-cert.sh.tpl" "$RUNTIME_BIN_DIR/$ACME_CERT_SCRIPT_NAME"
        chmod 0755 "$RUNTIME_BIN_DIR/$ACME_CERT_SCRIPT_NAME"
    fi
    substitute_template "$PACKAGE_DIR/templates/s-ui-db-configure.sh.tpl" "$RUNTIME_BIN_DIR/$DB_CONFIG_SCRIPT_NAME"
    chmod 0755 "$RUNTIME_BIN_DIR/$DB_CONFIG_SCRIPT_NAME"

    ensure_config_loaded "$CONFIG_DIR/$CONFIG_FILE_NAME"

    local db_script="$RUNTIME_BIN_DIR/$DB_CONFIG_SCRIPT_NAME"
    local db_path="$RUNTIME_DATA_DIR/s-ui.db"
    [[ -x "$db_script" ]] || die "Database configuration script not found: $db_script"

    start_containers

    # shellcheck disable=SC2153
    local db_timeout="$DB_TIMEOUT" db_elapsed=0
    log_info "Waiting for s-ui to initialize database (up to ${db_timeout}s)..."
    while (( db_elapsed < db_timeout )); do
        [[ -f "$db_path" && -s "$db_path" ]] && break
        sleep "$DB_POLL_INTERVAL"
        db_elapsed=$(( db_elapsed + DB_POLL_INTERVAL ))
    done
    if [[ ! -f "$db_path" || ! -s "$db_path" ]]; then
        docker logs "$CONTAINER_NAME" 2>/dev/null | tail -n 50 >&2 || true
        die "Database file was not created in time: $db_path"
    fi

    stop_containers
    [[ -f "$db_path" ]] || die "Database file not found after first start: $db_path"
    "$db_script" "$INSTALL_GENERATED_USERNAME" "$INSTALL_GENERATED_PASSWORD"
    start_containers

    issue_certificate
    install_renewal_timer
    ensure_file_ownership "$CONFIG_DIR" "$RUNTIME_DIR"

    log_info "Setup completed"
    log_info "Generated username: $INSTALL_GENERATED_USERNAME"
    log_info "Generated password: $INSTALL_GENERATED_PASSWORD"
}
