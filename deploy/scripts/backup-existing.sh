#!/usr/bin/env bash

# Adapter globals are consumed by libraries sourced below.
# shellcheck disable=SC2034

set -Eeuo pipefail
umask 077

BACKUP_EXISTING_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=backup-common.sh
source "${BACKUP_EXISTING_SCRIPT_DIR}/backup-common.sh"

backup_validate_source_config >/dev/null 2>&1 || exit 20
[[ "$(backup_source_mode)" == existing_notifier ]] || exit 20
export THREADHUB_EXISTING_NOTIFIER_ENV_FILE
THREADHUB_EXISTING_NOTIFIER_ENV_FILE="$(backup_existing_notifier_env_file)" || exit 20

# shellcheck source=existing-notifier-common.sh
source "${BACKUP_EXISTING_SCRIPT_DIR}/existing-notifier-common.sh"
BACKUP_ARTIFACT_MATTERMOST_DATA_ROOT="$(existing_notifier_value THN_MATTERMOST_DATA_ROOT)"
BACKUP_ARTIFACT_NOTIFIER_ROOT="$(existing_notifier_value THN_DATA_ROOT)"
BACKUP_ARTIFACT_RELEASE_FILE="${BACKUP_ARTIFACT_NOTIFIER_ROOT}/release/release.env"
BACKUP_ARTIFACT_SOURCE_COMMIT_MODE=release

# Sourcing keeps the canonical orchestrator and replaces only deployment-specific
# Compose, path, snapshot, and health adapters below.
# shellcheck source=backup.sh
source "${BACKUP_EXISTING_SCRIPT_DIR}/backup.sh"
ENV_FILE="$(existing_notifier_value THN_COMPOSE_ENV_FILE)"
BACKUP_EXISTING_MATTERMOST_SERVICE="$(existing_notifier_value THN_MATTERMOST_SERVICE)"

backup_existing_validate_runtime() {
    local required service services

    backup_validate_source_config >/dev/null 2>&1 || return 20
    (existing_notifier_validate_config) >/dev/null 2>&1 || return 20
    runtime_env_require_secure "${ENV_FILE}" >/dev/null 2>&1 || return 20
    for required in POSTGRES_USER POSTGRES_DB; do
        env_value "${required}" "${ENV_FILE}" >/dev/null 2>&1 || return 20
    done
    [[ -d "${BACKUP_ARTIFACT_MATTERMOST_DATA_ROOT}" \
        && ! -L "${BACKUP_ARTIFACT_MATTERMOST_DATA_ROOT}" \
        && -d "${BACKUP_ARTIFACT_NOTIFIER_ROOT}/mailer" \
        && ! -L "${BACKUP_ARTIFACT_NOTIFIER_ROOT}/mailer" ]] || return 20
    backup_require_regular_mode_owner \
        "${BACKUP_ARTIFACT_RELEASE_FILE}" 640 "$(backup_expected_uid)" "$(backup_expected_gid)" \
        || return 20
    existing_notifier_compose_combined config --quiet >/dev/null 2>&1 || return 20
    services="$(existing_notifier_compose_combined config --services)" || return 20
    for service in postgres "${BACKUP_EXISTING_MATTERMOST_SERVICE}" threadhub-mailer; do
        printf '%s\n' "${services}" | grep -Fx -- "${service}" >/dev/null || return 20
    done
    backup_artifact_provenance_json >/dev/null 2>&1 || return 20
}

backup_initialize_docker() {
    [[ "$(id -u)" == 0 ]] || return 20
    command -v docker >/dev/null 2>&1 || return 20
    docker info >/dev/null 2>&1 || return 20
    DOCKER_COMMAND=(docker)
    SUDO_COMMAND=()
    existing_notifier_init_compose
}

compose() {
    existing_notifier_compose_combined "$@"
}

backup_preflight() {
    local required

    (require_ubuntu_amd64) >/dev/null 2>&1 || return 20
    backup_validate_config >/dev/null 2>&1 || return 20
    backup_prepare_state_root >/dev/null 2>&1 || return 20
    backup_cleanup_expired_sets || return 20
    backup_initialize_docker || return 20
    for required in jq tar zstd openssl flock stat git du df awk find timeout grep; do
        command -v "${required}" >/dev/null 2>&1 || return 20
    done
    backup_require_gnu_tar || return 20
    backup_existing_validate_runtime || return 20
    backup_require_capacity || return 20
    backup_oci_preflight >/dev/null 2>&1
}

backup_resume_validate() {
    local backup_id="$1" set_dir required

    backup_validate_id "${backup_id}" || return 20
    (require_ubuntu_amd64) >/dev/null 2>&1 || return 20
    backup_validate_config >/dev/null 2>&1 || return 20
    backup_prepare_state_root >/dev/null 2>&1 || return 20
    backup_initialize_docker || return 20
    for required in jq tar zstd openssl flock stat git grep; do
        command -v "${required}" >/dev/null 2>&1 || return 20
    done
    backup_require_gnu_tar || return 20
    backup_existing_validate_runtime || return 20
    backup_oci_preflight >/dev/null 2>&1 || return 20
    backup_prepare_resume_root || return 20
    backup_resume_marker_is_valid "${backup_id}" || return 20
    set_dir="${BACKUP_STAGING_ROOT}/${backup_id}"
    backup_validate_local_set "${set_dir}" "${backup_id}"
}

backup_compose_with_timeout() {
    local timeout_seconds="$1"
    shift

    backup_run_with_timeout "${timeout_seconds}" \
        "${EXISTING_NOTIFIER_COMBINED_COMPOSE[@]}" "$@"
}

backup_stop_mattermost() {
    local remaining="$1" stop_timeout

    stop_timeout="$(backup_container_stop_timeout "${remaining}")" || return 20
    backup_compose_with_timeout "${remaining}" stop --timeout "${stop_timeout}" \
        "${BACKUP_EXISTING_MATTERMOST_SERVICE}" >/dev/null 2>&1
}

backup_start_mattermost() {
    local remaining="$1"

    backup_compose_with_timeout "${remaining}" up -d --no-deps --wait \
        --wait-timeout "${remaining}" "${BACKUP_EXISTING_MATTERMOST_SERVICE}" >/dev/null 2>&1
}

backup_snapshot() {
    local set_dir="$1" remaining="$2"

    backup_run_with_timeout "${remaining}" \
        "${BACKUP_EXISTING_SCRIPT_DIR}/backup-existing-snapshot.sh" "${set_dir}"
}

backup_health() {
    "${BACKUP_EXISTING_SCRIPT_DIR}/backup-existing-health.sh" >/dev/null 2>&1
}

backup_health_before_deadline() {
    local remaining="$1"

    backup_run_with_timeout "${remaining}" \
        "${BACKUP_EXISTING_SCRIPT_DIR}/backup-existing-health.sh" >/dev/null 2>&1
}

backup_initialize_docker || exit 20
backup_main "$@"
