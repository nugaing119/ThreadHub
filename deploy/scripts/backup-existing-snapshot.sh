#!/usr/bin/env bash

# Snapshot adapter globals are consumed by libraries sourced below.
# shellcheck disable=SC2034

set -Eeuo pipefail
umask 077

BACKUP_EXISTING_SNAPSHOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=backup-common.sh
source "${BACKUP_EXISTING_SNAPSHOT_DIR}/backup-common.sh"
backup_validate_source_config >/dev/null 2>&1 || exit 20
export THREADHUB_EXISTING_NOTIFIER_ENV_FILE
THREADHUB_EXISTING_NOTIFIER_ENV_FILE="$(backup_existing_notifier_env_file)" || exit 20
# shellcheck source=existing-notifier-common.sh
source "${BACKUP_EXISTING_SNAPSHOT_DIR}/existing-notifier-common.sh"

BACKUP_ARTIFACT_MATTERMOST_DATA_ROOT="$(existing_notifier_value THN_MATTERMOST_DATA_ROOT)"
BACKUP_ARTIFACT_NOTIFIER_ROOT="$(existing_notifier_value THN_DATA_ROOT)"
BACKUP_ARTIFACT_RELEASE_FILE="${BACKUP_ARTIFACT_NOTIFIER_ROOT}/release/release.env"
BACKUP_ARTIFACT_SOURCE_COMMIT_MODE=release
# shellcheck source=backup-artifacts.sh
source "${BACKUP_EXISTING_SNAPSHOT_DIR}/backup-artifacts.sh"
ENV_FILE="$(existing_notifier_value THN_COMPOSE_ENV_FILE)"

backup_existing_snapshot_entry() {
    (($# == 1)) || return 20
    [[ "$(id -u)" -eq 0 ]] || return 20
    backup_validate_config || return 20
    (existing_notifier_validate_config) >/dev/null 2>&1 || return 20
    runtime_env_require_secure "${ENV_FILE}" >/dev/null 2>&1 || return 20
    backup_artifact_set_dir_is_valid "$1" || return 20
    DOCKER_COMMAND=(docker)
    SUDO_COMMAND=()
    docker info >/dev/null 2>&1 || return 20
    existing_notifier_init_compose
    backup_create_artifacts "$1"
}

backup_existing_snapshot_entry "$@"
