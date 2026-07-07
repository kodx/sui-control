#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# shellcheck disable=SC2154
set -Eeuo pipefail
# shellcheck disable=SC1091
. "$PACKAGE_DIR/lib/constants.sh"
# shellcheck disable=SC1091
. "$PACKAGE_DIR/lib/actions.sh"
# shellcheck disable=SC1091
. "$PACKAGE_DIR/lib/utils.sh"
require_command docker
ensure_config_loaded
ensure_acme_mode
check_port_80_free
stop_sui_container_if_running
MODE="${1:-renew}"
case "$MODE" in
    renew)
        log_info "Running scheduled ACME renewal check"
        docker run --rm -p 80:80 \
            -v "$RUNTIME_ACME_DIR:/acme.sh" \
            -v "$RUNTIME_CERT_DIR:/certs" \
            --entrypoint sh \
            "$ACME_IMAGE" \
            -c 'set -e; acme.sh --cron --home /acme.sh'
        ;;
    issue)
        if is_ip "$DOMAIN"; then
            log_info "Issuing short-lived IP certificate (valid ~6 days)"
            log_info "Issuing ACME certificate for $DOMAIN"
            if docker run --rm -p 80:80 \
                    -v "$RUNTIME_ACME_DIR:/acme.sh" \
                    -v "$RUNTIME_CERT_DIR:/certs" \
                    --entrypoint sh \
                    "$ACME_IMAGE" \
                    -c "set -e; acme.sh --issue --standalone --server letsencrypt --certificate-profile shortlived --days 6 -d '$DOMAIN' --key-file /certs/server.key --fullchain-file /certs/server.crt --home /acme.sh"; then
                log_info "Certificate issued successfully"
            else
                die "ACME certificate issuance failed"
            fi
        else
            log_info "Issuing ACME certificate for $DOMAIN"
            if docker run --rm -p 80:80 \
                    -v "$RUNTIME_ACME_DIR:/acme.sh" \
                    -v "$RUNTIME_CERT_DIR:/certs" \
                    --entrypoint sh \
                    "$ACME_IMAGE" \
                    -c "set -e; acme.sh --issue --standalone -d '$DOMAIN' --key-file /certs/server.key --fullchain-file /certs/server.crt --home /acme.sh"; then
                log_info "Certificate issued successfully"
            else
                die "ACME certificate issuance failed"
            fi
        fi
        ;;
    *)
        die "Unknown mode: $MODE (expected: renew or issue)"
        ;;
esac
restart_sui_container
