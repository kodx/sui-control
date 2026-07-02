#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../lib/constants.sh"
. "$SCRIPT_DIR/../lib/utils.sh"
require_command docker
load_config_relative "$SCRIPT_DIR"
ensure_acme_mode
compose_in_install_dir
check_port_80_free
stop_sui_container_if_running
MODE="${1:-renew}"
case "$MODE" in
    renew)
        log_info "Running scheduled ACME renewal check"
        docker compose run --rm -p 80:80 --entrypoint sh acme-sh -c 'set -e; acme.sh --cron --home /acme.sh'
        ;;
    issue)
        log_info "Issuing ACME certificate for $DOMAIN"
        if docker compose run --rm -p 80:80 --entrypoint sh acme-sh \
                -c "set -e; acme.sh --issue --standalone -d '$DOMAIN' --key-file /certs/server.key --fullchain-file /certs/server.crt --home /acme.sh"; then
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
