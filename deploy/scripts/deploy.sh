#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"
# shellcheck source=data-layout.sh
source "${SCRIPT_DIR}/data-layout.sh"

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

require_command jq
log "Creating explicit PostgreSQL, Mattermost and notifier bind-mount paths"
prepare_threadhub_data_layout "${data_root}" \
    || die "ThreadHub data layout preparation failed"
ensure_disabled_notifier_control "${data_root}"

if [[ -f "${DEPLOY_DIR}/logrotate/threadhub" ]]; then
    "${SUDO_COMMAND[@]}" install -m 0644 \
        "${DEPLOY_DIR}/logrotate/threadhub" \
        /etc/logrotate.d/threadhub
fi

log "Pulling immutable external linux/amd64 image manifests"
compose pull postgres mattermost

"${SCRIPT_DIR}/build-notifier.sh"

log "Starting ThreadHub"
compose up -d --remove-orphans --wait --wait-timeout 240

"${SCRIPT_DIR}/install-notifier-plugin.sh"

"${SCRIPT_DIR}/health-check.sh"
log "ThreadHub containers are running. Configure NGINX and HTTPS next."
