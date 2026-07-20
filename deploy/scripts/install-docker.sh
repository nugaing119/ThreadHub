#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

require_ubuntu_amd64
require_file "${VERSIONS_FILE}"
init_sudo

docker_ce_version="$(env_value DOCKER_CE_VERSION "${VERSIONS_FILE}")"
docker_cli_version="$(env_value DOCKER_CLI_VERSION "${VERSIONS_FILE}")"
containerd_version="$(env_value CONTAINERD_VERSION "${VERSIONS_FILE}")"
compose_version="$(env_value DOCKER_COMPOSE_PLUGIN_VERSION "${VERSIONS_FILE}")"

log "Installing Docker packages from Docker's official Ubuntu repository"
"${SUDO_COMMAND[@]}" apt-get update
"${SUDO_COMMAND[@]}" apt-get install -y ca-certificates curl gnupg jq

key_file="$(mktemp)"
source_file="$(mktemp)"
cleanup() {
    rm -f "${key_file}" "${source_file}"
}
trap cleanup EXIT

curl --fail --silent --show-error --location \
    https://download.docker.com/linux/ubuntu/gpg \
    --output "${key_file}"

"${SUDO_COMMAND[@]}" install -d -m 0755 /etc/apt/keyrings
"${SUDO_COMMAND[@]}" install -m 0644 "${key_file}" /etc/apt/keyrings/docker.asc

printf '%s\n' \
    'deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu noble stable' \
    > "${source_file}"
"${SUDO_COMMAND[@]}" install -m 0644 "${source_file}" /etc/apt/sources.list.d/docker.list

"${SUDO_COMMAND[@]}" apt-get update
"${SUDO_COMMAND[@]}" apt-get install -y \
    "docker-ce=${docker_ce_version}" \
    "docker-ce-cli=${docker_cli_version}" \
    "containerd.io=${containerd_version}" \
    "docker-compose-plugin=${compose_version}"

"${SUDO_COMMAND[@]}" apt-mark hold \
    docker-ce docker-ce-cli containerd.io docker-compose-plugin
"${SUDO_COMMAND[@]}" systemctl enable --now docker

installed_engine="$("${SUDO_COMMAND[@]}" docker version --format '{{.Server.Version}}')"
installed_compose="$("${SUDO_COMMAND[@]}" docker compose version --short)"
expected_engine="${docker_ce_version#*:}"
expected_engine="${expected_engine%%-*}"
expected_compose="${compose_version%%-*}"

[[ "${installed_engine}" == "${expected_engine}" ]] \
    || die "Docker Engine version mismatch: expected ${expected_engine}, got ${installed_engine}"
[[ "${installed_compose}" == "${expected_compose}" ]] \
    || die "Docker Compose version mismatch: expected ${expected_compose}, got ${installed_compose}"

log "Docker Engine ${installed_engine} and Compose ${installed_compose} are installed and pinned"
