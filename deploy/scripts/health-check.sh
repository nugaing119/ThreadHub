#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

validate_base_env
init_docker
require_command curl

postgres_id="$(compose ps -q postgres)"
mattermost_id="$(compose ps -q mattermost)"
[[ -n "${postgres_id}" ]] || die "PostgreSQL container is not running"
[[ -n "${mattermost_id}" ]] || die "Mattermost container is not running"

container_health() {
    "${DOCKER_COMMAND[@]}" inspect \
        --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' \
        "$1"
}

[[ "$(container_health "${postgres_id}")" == "healthy" ]] \
    || die "PostgreSQL container is not healthy"
[[ "$(container_health "${mattermost_id}")" == "healthy" ]] \
    || die "Mattermost container is not healthy"

data_root="$(env_value THREADHUB_DATA_ROOT "${ENV_FILE}")"
postgres_root_mode="$("${SUDO_COMMAND[@]}" stat -c '%a' "${data_root}/postgres")"
[[ "${postgres_root_mode}" == "755" ]] \
    || die "PostgreSQL bind-mount root must have mode 0755"

check_bind_mount() {
    local container_id="$1"
    local expected_source="$2"
    local expected_destination="$3"
    local actual

    actual="$("${DOCKER_COMMAND[@]}" inspect \
        --format '{{range .Mounts}}{{printf "%s\t%s\t%s\n" .Type .Source .Destination}}{{end}}' \
        "${container_id}" \
        | awk -F '\t' -v destination="${expected_destination}" '$3 == destination { print $1 "\t" $2; exit }')"

    [[ "${actual}" == $'bind\t'"${expected_source}" ]] \
        || die "Expected bind mount ${expected_source} -> ${expected_destination} was not found"
}

check_bind_mount "${postgres_id}" \
    "${data_root}/postgres" \
    /var/lib/postgresql
check_bind_mount "${mattermost_id}" \
    "${data_root}/mattermost/config" \
    /mattermost/config
check_bind_mount "${mattermost_id}" \
    "${data_root}/mattermost/data" \
    /mattermost/data
check_bind_mount "${mattermost_id}" \
    "${data_root}/mattermost/logs" \
    /mattermost/logs
check_bind_mount "${mattermost_id}" \
    "${data_root}/mattermost/plugins" \
    /mattermost/plugins
check_bind_mount "${mattermost_id}" \
    "${data_root}/mattermost/client/plugins" \
    /mattermost/client/plugins
check_bind_mount "${mattermost_id}" \
    "${data_root}/mattermost/bleve-indexes" \
    /mattermost/bleve-indexes

postgres_ports="$("${DOCKER_COMMAND[@]}" port "${postgres_id}")"
[[ -z "${postgres_ports}" ]] || die "PostgreSQL unexpectedly publishes a host port"

bind_address="$(env_value MATTERMOST_BIND_ADDRESS "${ENV_FILE}")"
bind_port="$(env_value MATTERMOST_BIND_PORT "${ENV_FILE}")"
published_port="$("${DOCKER_COMMAND[@]}" port "${mattermost_id}" 8065/tcp)"
[[ "${published_port}" == "${bind_address}:${bind_port}" ]] \
    || die "Mattermost is not bound only to ${bind_address}:${bind_port}"

# PGDATA must expand inside the container, not in this host shell.
# shellcheck disable=SC2016
pgdata="$("${DOCKER_COMMAND[@]}" exec "${postgres_id}" sh -c 'printf "%s" "$PGDATA"')"
[[ "${pgdata}" == "/var/lib/postgresql/18/docker" ]] \
    || die "Unexpected PostgreSQL 18 PGDATA: ${pgdata}"

curl --fail --silent --show-error \
    "http://${bind_address}:${bind_port}/api/v4/system/ping" \
    >/dev/null

log "Container health, host permissions, loopback port binding, PG18 path and all explicit bind mounts are valid"
compose ps
