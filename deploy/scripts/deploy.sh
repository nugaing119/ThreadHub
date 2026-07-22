#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

mode="${1:-deploy}"
[[ "${mode}" == "deploy" || "${mode}" == "--validate-only" ]] \
    || die "Usage: $0 [--validate-only]"

require_file "${ENV_FILE}"
chmod 0600 "${ENV_FILE}"
validate_runtime_env
init_docker
compose config --quiet
log "Docker Compose configuration is valid"

if [[ "${mode}" == "--validate-only" ]]; then
    exit 0
fi

require_ubuntu_amd64
init_sudo

data_root="$(env_value THREADHUB_DATA_ROOT "${ENV_FILE}")"
mattermost_root="${data_root}/mattermost"

log "Creating explicit PostgreSQL and Mattermost bind-mount paths"
"${SUDO_COMMAND[@]}" install -d -m 0750 "${data_root}"
# PostgreSQL 18 initializes a versioned PGDATA directory as root, then drops
# to the postgres user. The bind-mount root must remain traversable afterward.
"${SUDO_COMMAND[@]}" install -d -m 0755 "${data_root}/postgres"
"${SUDO_COMMAND[@]}" install -d -m 0750 \
    "${mattermost_root}/config" \
    "${mattermost_root}/data" \
    "${mattermost_root}/logs" \
    "${mattermost_root}/plugins" \
    "${mattermost_root}/client/plugins" \
    "${mattermost_root}/bleve-indexes"
"${SUDO_COMMAND[@]}" chown -R 2000:2000 "${mattermost_root}"
"${SUDO_COMMAND[@]}" chmod -R u=rwX,g=rX,o= "${mattermost_root}"

if [[ -f "${DEPLOY_DIR}/logrotate/threadhub" ]]; then
    "${SUDO_COMMAND[@]}" install -m 0644 \
        "${DEPLOY_DIR}/logrotate/threadhub" \
        /etc/logrotate.d/threadhub
fi

log "Pulling immutable linux/amd64 image manifests"
compose pull

log "Starting ThreadHub"
compose up -d --remove-orphans --wait --wait-timeout 240

"${SCRIPT_DIR}/health-check.sh"
log "ThreadHub containers are running. Configure NGINX and HTTPS next."
