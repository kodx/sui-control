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
      - "${DATA_DIR}:/app/db"
      - "${CERT_DIR}:/certs"

  acme-sh:
    image: neilpang/acme.sh:latest
    container_name: acme-sh
    profiles: ["tools"]
    networks:
      - s-ui
    volumes:
      - "${ACME_DIR}:/acme.sh"
      - "${CERT_DIR}:/certs"

networks:
  s-ui:
    driver: bridge
