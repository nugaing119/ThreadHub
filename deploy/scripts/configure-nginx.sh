#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

validate_base_env
require_ubuntu_amd64
init_sudo
require_command sed

domain="$(env_value THREADHUB_DOMAIN "${ENV_FILE}")"
email="$(env_value LETSENCRYPT_EMAIL "${ENV_FILE}")"
bootstrap_template="${DEPLOY_DIR}/nginx/threadhub-bootstrap.conf.template"
final_template="${DEPLOY_DIR}/nginx/threadhub.conf.template"
site_available=/etc/nginx/sites-available/threadhub.conf
site_enabled=/etc/nginx/sites-enabled/threadhub.conf

require_file "${bootstrap_template}"
require_file "${final_template}"

log "Installing NGINX and Certbot"
"${SUDO_COMMAND[@]}" apt-get update
"${SUDO_COMMAND[@]}" apt-get install -y nginx certbot
"${SUDO_COMMAND[@]}" install -d -m 0755 /var/www/letsencrypt

rendered_config="$(mktemp)"
cleanup() {
    rm -f "${rendered_config}"
}
trap cleanup EXIT

sed "s/__THREADHUB_DOMAIN__/${domain}/g" \
    "${bootstrap_template}" \
    > "${rendered_config}"
"${SUDO_COMMAND[@]}" install -m 0644 "${rendered_config}" "${site_available}"
"${SUDO_COMMAND[@]}" ln -sfn "${site_available}" "${site_enabled}"
"${SUDO_COMMAND[@]}" rm -f /etc/nginx/sites-enabled/default
"${SUDO_COMMAND[@]}" nginx -t
"${SUDO_COMMAND[@]}" systemctl enable --now nginx
"${SUDO_COMMAND[@]}" systemctl reload nginx

log "Requesting a Let's Encrypt certificate for ${domain}"
"${SUDO_COMMAND[@]}" certbot certonly \
    --non-interactive \
    --agree-tos \
    --email "${email}" \
    --webroot \
    --webroot-path /var/www/letsencrypt \
    --domain "${domain}" \
    --keep-until-expiring

sed "s/__THREADHUB_DOMAIN__/${domain}/g" \
    "${final_template}" \
    > "${rendered_config}"
"${SUDO_COMMAND[@]}" install -m 0644 "${rendered_config}" "${site_available}"
"${SUDO_COMMAND[@]}" nginx -t
"${SUDO_COMMAND[@]}" systemctl reload nginx
"${SUDO_COMMAND[@]}" certbot renew --dry-run

log "NGINX, HTTPS redirect, certificate renewal and WebSocket proxy configuration are valid"
