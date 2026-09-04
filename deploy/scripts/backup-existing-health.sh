#!/usr/bin/env bash

# Compose command globals are consumed by existing-notifier-common.sh.
# shellcheck disable=SC2034

set -Eeuo pipefail

BACKUP_EXISTING_HEALTH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=backup-common.sh
source "${BACKUP_EXISTING_HEALTH_DIR}/backup-common.sh"
backup_validate_source_config >/dev/null 2>&1 || exit 20
export THREADHUB_EXISTING_NOTIFIER_ENV_FILE
THREADHUB_EXISTING_NOTIFIER_ENV_FILE="$(backup_existing_notifier_env_file)" || exit 20
# shellcheck source=existing-notifier-common.sh
source "${BACKUP_EXISTING_HEALTH_DIR}/existing-notifier-common.sh"

backup_existing_health_entry() {
    local service container_id health state_file notifier_root

    (($# == 0)) || return 20
    [[ "$(id -u)" -eq 0 ]] || return 20
    (existing_notifier_validate_config) >/dev/null 2>&1 || return 20
    DOCKER_COMMAND=(docker)
    SUDO_COMMAND=()
    docker info >/dev/null 2>&1 || return 20
    existing_notifier_init_compose
    existing_notifier_compose_combined config --quiet >/dev/null 2>&1 || return 20
    for service in postgres "$(existing_notifier_value THN_MATTERMOST_SERVICE)" threadhub-mailer; do
        container_id="$(existing_notifier_compose_combined ps -q "${service}")" || return 20
        [[ -n "${container_id}" ]] || return 20
        health="$(docker inspect --format \
            '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' \
            "${container_id}")" || return 20
        [[ "${health}" == healthy ]] || return 20
    done
    notifier_root="$(existing_notifier_value THN_DATA_ROOT)"
    state_file="${notifier_root}/control/state.json"
    existing_notifier_validate_control_path "${state_file}" >/dev/null 2>&1 || return 20
    existing_notifier_compose_combined exec -T threadhub-mailer \
        /threadhub-mailer status --json | jq -e '
            type == "object" and
            (.pending | type == "number") and
            (.sending | type == "number") and
            (.sent | type == "number") and
            (.failed | type == "number")
        ' >/dev/null 2>&1
}

backup_existing_health_entry "$@"
