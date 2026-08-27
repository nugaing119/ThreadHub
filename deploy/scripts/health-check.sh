#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

validate_base_env
validate_notifier_env
init_docker
init_sudo
require_command curl
require_command jq

postgres_id="$(compose ps -q postgres)"
mattermost_id="$(compose ps -q mattermost)"
mailer_id="$(compose ps -q threadhub-mailer)"
[[ -n "${postgres_id}" ]] || die "PostgreSQL container is not running"
[[ -n "${mattermost_id}" ]] || die "Mattermost container is not running"
[[ -n "${mailer_id}" ]] || die "Notifier Mailer container is not running"

container_health() {
    "${DOCKER_COMMAND[@]}" inspect \
        --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' \
        "$1"
}

[[ "$(container_health "${postgres_id}")" == "healthy" ]] \
    || die "PostgreSQL container is not healthy"
[[ "$(container_health "${mattermost_id}")" == "healthy" ]] \
    || die "Mattermost container is not healthy"
[[ "$(container_health "${mailer_id}")" == "healthy" ]] \
    || die "Notifier Mailer container is not healthy"

data_root="$(env_value THREADHUB_DATA_ROOT "${ENV_FILE}")"
postgres_root_mode="$("${SUDO_COMMAND[@]}" stat -c '%a' "${data_root}/postgres")"
[[ "${postgres_root_mode}" == "755" ]] \
    || die "PostgreSQL bind-mount root must have mode 0755"

check_bind_mount() {
    local container_id="$1"
    local expected_source="$2"
    local expected_destination="$3"
    local expected_rw="$4"
    local actual

    actual="$("${DOCKER_COMMAND[@]}" inspect \
        --format '{{range .Mounts}}{{printf "%s\t%s\t%s\t%t\n" .Type .Source .Destination .RW}}{{end}}' \
        "${container_id}" \
        | awk -F '\t' -v destination="${expected_destination}" '$3 == destination { print $1 "\t" $2 "\t" $4; exit }')"

    [[ "${actual}" == $'bind\t'"${expected_source}"$'\t'"${expected_rw}" ]] \
        || die "Expected bind mount ${expected_source} -> ${expected_destination} with RW=${expected_rw} was not found"
}

check_bind_mount "${postgres_id}" \
    "${data_root}/postgres" \
    /var/lib/postgresql \
    true
check_bind_mount "${mattermost_id}" \
    "${data_root}/mattermost/config" \
    /mattermost/config \
    true
check_bind_mount "${mattermost_id}" \
    "${data_root}/mattermost/data" \
    /mattermost/data \
    true
check_bind_mount "${mattermost_id}" \
    "${data_root}/mattermost/logs" \
    /mattermost/logs \
    true
check_bind_mount "${mattermost_id}" \
    "${data_root}/mattermost/plugins" \
    /mattermost/plugins \
    true
check_bind_mount "${mattermost_id}" \
    "${data_root}/mattermost/client/plugins" \
    /mattermost/client/plugins \
    true
check_bind_mount "${mattermost_id}" \
    "${data_root}/mattermost/bleve-indexes" \
    /mattermost/bleve-indexes \
    true
check_bind_mount "${mattermost_id}" \
    "${data_root}/notifier/control" \
    /run/threadhub-notifier \
    false
check_bind_mount "${mailer_id}" \
    "${data_root}/notifier/mailer" \
    /var/lib/threadhub-notifier \
    true
check_bind_mount "${mailer_id}" \
    "${data_root}/notifier/control" \
    /run/threadhub-notifier \
    false

postgres_ports="$("${DOCKER_COMMAND[@]}" port "${postgres_id}")"
[[ -z "${postgres_ports}" ]] || die "PostgreSQL unexpectedly publishes a host port"
mailer_ports="$("${DOCKER_COMMAND[@]}" port "${mailer_id}")"
[[ -z "${mailer_ports}" ]] || die "Notifier Mailer unexpectedly publishes a host port"

for container_id in "${mattermost_id}" "${mailer_id}"; do
    group_add="$("${DOCKER_COMMAND[@]}" inspect --format '{{json .HostConfig.GroupAdd}}' "${container_id}")"
    [[ "${group_add}" == '["3000"]' ]] \
        || die "Notifier control supplemental group is invalid"
done

mailer_parent_identity="$("${SUDO_COMMAND[@]}" stat -c '%u:%g:%a' "${data_root}/notifier/mailer")"
[[ "${mailer_parent_identity}" == "65532:65532:700" ]] \
    || die "Notifier queue parent must be owned by 65532:65532 with mode 0700"
control_identity="$("${SUDO_COMMAND[@]}" stat -c '%u:%g:%a' "${data_root}/notifier/control")"
[[ "${control_identity}" == "0:3000:750" ]] \
    || die "Notifier control directory must be owned by root:3000 with mode 0750"
state_identity="$("${SUDO_COMMAND[@]}" stat -c '%u:%g:%a' "${data_root}/notifier/control/state.json")"
[[ "${state_identity}" == "0:3000:640" ]] \
    || die "Notifier control state must be owned by root:3000 with mode 0640"
notifier_control_is_valid "${data_root}/notifier/control/state.json" \
    || die "Notifier control state is invalid"

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

log "Container health, notifier isolation, host permissions, loopback port binding, PG18 path and all explicit bind mounts are valid"
compose ps
