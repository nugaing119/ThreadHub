#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

validate_base_env
require_ubuntu_amd64
init_sudo
require_command sed
require_command nginx
require_command systemctl

domain="$(env_value THREADHUB_DOMAIN "${ENV_FILE}")"
template="${DEPLOY_DIR}/nginx/threadhub.conf.template"
site_available=/etc/nginx/sites-available/threadhub.conf
site_enabled=/etc/nginx/sites-enabled/threadhub.conf
certificate_dir="/etc/letsencrypt/live/${domain}"

require_file "${template}"
"${SUDO_COMMAND[@]}" test -f "${certificate_dir}/fullchain.pem" \
    || die "TLS full chain not found for ${domain}"
"${SUDO_COMMAND[@]}" test -f "${certificate_dir}/privkey.pem" \
    || die "TLS private key not found for ${domain}"

rendered_config="$(mktemp)"
backup_config="$(mktemp)"
had_existing_config=false

cleanup() {
    rm -f "${rendered_config}"
    "${SUDO_COMMAND[@]}" rm -f "${backup_config}"
}
trap cleanup EXIT

sed "s/__THREADHUB_DOMAIN__/${domain}/g" \
    "${template}" \
    > "${rendered_config}"

if "${SUDO_COMMAND[@]}" test -f "${site_available}"; then
    "${SUDO_COMMAND[@]}" cp "${site_available}" "${backup_config}"
    had_existing_config=true
fi

restore_previous_config() {
    if [[ "${had_existing_config}" == "true" ]]; then
        "${SUDO_COMMAND[@]}" install -m 0644 "${backup_config}" "${site_available}"
        "${SUDO_COMMAND[@]}" ln -sfn "${site_available}" "${site_enabled}"
    else
        "${SUDO_COMMAND[@]}" rm -f "${site_enabled}" "${site_available}"
    fi
}

"${SUDO_COMMAND[@]}" install -m 0644 "${rendered_config}" "${site_available}"
"${SUDO_COMMAND[@]}" ln -sfn "${site_available}" "${site_enabled}"

if ! "${SUDO_COMMAND[@]}" nginx -t; then
    restore_previous_config
    "${SUDO_COMMAND[@]}" nginx -t \
        || die "Candidate NGINX configuration failed and the previous configuration is also invalid"
    die "Candidate NGINX configuration failed; the previous configuration was restored without reload"
fi

if ! "${SUDO_COMMAND[@]}" systemctl reload nginx; then
    restore_previous_config
    "${SUDO_COMMAND[@]}" nginx -t \
        || die "NGINX reload failed and the previous configuration is invalid"
    "${SUDO_COMMAND[@]}" systemctl reload nginx \
        || die "NGINX reload failed and the previous configuration could not be reloaded"
    die "Candidate NGINX reload failed; the previous configuration was restored"
fi

"${SUDO_COMMAND[@]}" systemctl is-active --quiet nginx \
    || die "NGINX is not active after reload"

log "NGINX configuration passed syntax validation and was reloaded without restarting application containers"
