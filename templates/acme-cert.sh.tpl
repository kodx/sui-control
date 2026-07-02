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
