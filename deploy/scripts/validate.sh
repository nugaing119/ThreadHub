#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

require_file "${COMPOSE_FILE}"
require_file "${ENV_EXAMPLE_FILE}"
require_file "${VERSIONS_FILE}"

for script in "${SCRIPT_DIR}"/*.sh; do
    bash -n "${script}"
done
log "Bash syntax is valid"

for variable in \
    MATTERMOST_IMAGE_REPOSITORY \
    MATTERMOST_IMAGE_TAG \
    MATTERMOST_IMAGE_DIGEST \
    POSTGRES_IMAGE_REPOSITORY \
    POSTGRES_IMAGE_TAG \
    POSTGRES_IMAGE_DIGEST \
    DOCKER_CE_VERSION \
    DOCKER_CLI_VERSION \
    CONTAINERD_VERSION \
    DOCKER_COMPOSE_PLUGIN_VERSION; do
    env_value "${variable}" "${VERSIONS_FILE}" >/dev/null
done

mattermost_digest="$(env_value MATTERMOST_IMAGE_DIGEST "${VERSIONS_FILE}")"
postgres_digest="$(env_value POSTGRES_IMAGE_DIGEST "${VERSIONS_FILE}")"
[[ "${mattermost_digest}" =~ ^sha256:[a-f0-9]{64}$ ]] \
    || die "MATTERMOST_IMAGE_DIGEST is invalid"
[[ "${postgres_digest}" =~ ^sha256:[a-f0-9]{64}$ ]] \
    || die "POSTGRES_IMAGE_DIGEST is invalid"

if grep -R -n -E 'image:[[:space:]]+[^#]*:latest([[:space:]]|$)' "${DEPLOY_DIR}"; then
    die "Floating latest image tag found"
fi

if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    docker compose \
        --env-file "${ENV_EXAMPLE_FILE}" \
        --env-file "${VERSIONS_FILE}" \
        -f "${COMPOSE_FILE}" \
        config --quiet
    log "Docker Compose configuration is valid"
elif command -v ruby >/dev/null 2>&1; then
    ruby -e 'require "yaml"; YAML.load_file(ARGV.fetch(0))' "${COMPOSE_FILE}"
    warn "Docker Compose is unavailable; only generic YAML parsing was performed"
else
    die "Docker Compose or Ruby is required to validate docker-compose.yml"
fi

for template in \
    "${DEPLOY_DIR}/nginx/threadhub-bootstrap.conf.template" \
    "${DEPLOY_DIR}/nginx/threadhub.conf.template"; do
    require_file "${template}"
    [[ "$(grep -c '__THREADHUB_DOMAIN__' "${template}")" -gt 0 ]] \
        || die "NGINX template is missing the domain placeholder: ${template}"
done

if command -v git >/dev/null 2>&1 && git -C "${REPOSITORY_ROOT}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    if git -C "${REPOSITORY_ROOT}" grep -n -E \
        'AKIA[0-9A-Z]{16}|gh[opusr]_[A-Za-z0-9_]{20,}|ocid1\.|BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY'; then
        die "Potential credential material found in tracked files"
    fi
fi

log "ThreadHub deployment package static validation passed"
