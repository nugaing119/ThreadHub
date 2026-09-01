#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

RESTORE_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=backup-common.sh
source "${RESTORE_SCRIPT_DIR}/backup-common.sh"
# shellcheck source=backup-oci.sh
source "${RESTORE_SCRIPT_DIR}/backup-oci.sh"
# shellcheck source=backup-artifacts.sh
source "${RESTORE_SCRIPT_DIR}/backup-artifacts.sh"
# shellcheck source=data-layout.sh
source "${RESTORE_SCRIPT_DIR}/data-layout.sh"
# shellcheck source=notifier-lib.sh
source "${RESTORE_SCRIPT_DIR}/notifier-lib.sh"

RESTORE_TARGET_ROOT=/srv/threadhub
RESTORE_STATE_ROOT=${BACKUP_STATE_ROOT}/restore
RESTORE_TARGET_PARENT=/srv
RESTORE_BACKUP_ID=''
RESTORE_RUN_ROOT=''
RESTORE_DOWNLOAD_DIR=''
RESTORE_MATTERMOST_STAGING=''
RESTORE_QUEUE_QUARANTINE=''
RESTORE_TARGET_PARENT_IDENTITY=''
RESTORE_POSTGRES_STARTED=false
RESTORE_LOCK_FILE=${THREADHUB_RESTORE_LOCK_FILE:-/run/lock/threadhub-restore.lock}
RESTORE_TARGET_CLAIM=''

restore_acquire_lock() {
    local uid gid

    command -v flock >/dev/null 2>&1 || return 20
    [[ "${RESTORE_LOCK_FILE}" == /* && ! -L "${RESTORE_LOCK_FILE}" ]] || return 20
    umask 077
    exec 8>"${RESTORE_LOCK_FILE}" || return 20
    chmod 0600 "${RESTORE_LOCK_FILE}" || return 20
    uid="$(backup_expected_uid)"
    gid="$(backup_expected_gid)"
    backup_require_regular_mode_owner "${RESTORE_LOCK_FILE}" 600 "${uid}" "${gid}" || return 20
    flock -n 8 || return 75
}

restore_private_diagnostic() {
    local phase="$1"

    [[ "${phase}" =~ ^[a-z][a-z0-9-]{0,31}$ \
        && -n "${RESTORE_RUN_ROOT}" \
        && "${RESTORE_RUN_ROOT}" == "${RESTORE_STATE_ROOT}/${RESTORE_BACKUP_ID}" ]] || return 20
    printf '%s/%s.diagnostic\n' "${RESTORE_RUN_ROOT}" "${phase}"
}

restore_run_private() {
    local phase="$1" diagnostic
    shift

    diagnostic="$(restore_private_diagnostic "${phase}")" || return 20
    [[ ! -e "${diagnostic}" && ! -L "${diagnostic}" ]] || return 20
    if ! "$@" >"${diagnostic}" 2>&1; then
        chmod 0600 "${diagnostic}" >/dev/null 2>&1 || true
        return 30
    fi
    chmod 0600 "${diagnostic}" || return 30
}

restore_preflight() {
    local backup_id="$1"

    backup_validate_id "${backup_id}" || return 20
    [[ "$(id -u)" -eq 0 ]] || return 20
    (require_ubuntu_amd64) >/dev/null 2>&1 || return 20
    runtime_env_require_secure "${ENV_FILE}" >/dev/null 2>&1 || return 20
    (validate_runtime_env) >/dev/null 2>&1 || return 20
    backup_validate_config || return 20
    for command_name in jq git openssl tar zstd; do
        command -v "${command_name}" >/dev/null 2>&1 || return 20
    done
    init_docker
    compose config --quiet >/dev/null 2>&1 || return 20
    backup_assert_empty_target "${RESTORE_TARGET_ROOT}" || return 20
    RESTORE_TARGET_PARENT_IDENTITY="$(backup_path_identity "${RESTORE_TARGET_PARENT}")" || return 20
    backup_oci_preflight || return 30
}

restore_prepare_state() {
    local backup_id="$1" uid gid download_parent path

    backup_validate_id "${backup_id}" || return 20
    uid="$(backup_expected_uid)"
    gid="$(backup_expected_gid)"
    backup_prepare_state_root || return 20
    if [[ ! -e "${RESTORE_STATE_ROOT}" && ! -L "${RESTORE_STATE_ROOT}" ]]; then
        install -d -o root -g root -m 0700 "${RESTORE_STATE_ROOT}" || return 20
    fi
    backup_require_directory_mode_owner "${RESTORE_STATE_ROOT}" 700 "${uid}" "${gid}" || return 20

    RESTORE_RUN_ROOT="${RESTORE_STATE_ROOT}/${backup_id}"
    download_parent="${RESTORE_RUN_ROOT}/download"
    RESTORE_DOWNLOAD_DIR="${download_parent}/${backup_id}"
    RESTORE_MATTERMOST_STAGING="${RESTORE_RUN_ROOT}/mattermost-data"
    RESTORE_QUEUE_QUARANTINE="${RESTORE_RUN_ROOT}/notifier-queue"
    for path in "${RESTORE_RUN_ROOT}" "${download_parent}" "${RESTORE_DOWNLOAD_DIR}"; do
        [[ ! -e "${path}" && ! -L "${path}" ]] || return 20
        install -d -o root -g root -m 0700 "${path}" || return 20
        backup_require_directory_mode_owner "${path}" 700 "${uid}" "${gid}" || return 20
    done
}

restore_find_set() {
    backup_oci_find_set "$1"
}

restore_download_manifest() {
    local prefix="$1" download_dir="$2"

    backup_oci_download "${prefix}/manifest.sha256" "${download_dir}/manifest.sha256" \
        || return 30
    backup_oci_download "${prefix}/manifest.json" "${download_dir}/manifest.json" \
        || return 30
}

restore_validate_downloaded_manifest() {
    backup_validate_manifest_compatibility "$1" "$2"
}

restore_download_manifest_artifacts() {
    local prefix="$1" download_dir="$2" name

    for name in database.dump mattermost-data.tar.zst notifier-queue.tar.zst; do
        backup_oci_download "${prefix}/${name}" "${download_dir}/${name}" || return 30
    done
}

restore_validate_downloaded_set() {
    backup_validate_set_compatibility "$1" "$2"
}

restore_extract_archives_to_staging() {
    local path uid gid

    uid="$(backup_expected_uid)"
    gid="$(backup_expected_gid)"
    for path in "${RESTORE_MATTERMOST_STAGING}" "${RESTORE_QUEUE_QUARANTINE}"; do
        [[ ! -e "${path}" && ! -L "${path}" ]] || return 20
        install -d -o root -g root -m 0700 "${path}" || return 20
        backup_require_directory_mode_owner "${path}" 700 "${uid}" "${gid}" || return 20
    done
    backup_extract_archive \
        "${RESTORE_DOWNLOAD_DIR}/mattermost-data.tar.zst" "${RESTORE_MATTERMOST_STAGING}" \
        || return 20
    backup_extract_archive \
        "${RESTORE_DOWNLOAD_DIR}/notifier-queue.tar.zst" "${RESTORE_QUEUE_QUARANTINE}" \
        || return 20
    chmod -R u=rwX,go= "${RESTORE_MATTERMOST_STAGING}" "${RESTORE_QUEUE_QUARANTINE}" \
        || return 20
    chown -R root:root "${RESTORE_MATTERMOST_STAGING}" "${RESTORE_QUEUE_QUARANTINE}" \
        || return 20
    [[ -f "${RESTORE_QUEUE_QUARANTINE}/queue.db" \
        && ! -L "${RESTORE_QUEUE_QUARANTINE}/queue.db" ]] || return 20
}

restore_recheck_target() {
    [[ -n "${RESTORE_TARGET_PARENT_IDENTITY}" \
        && "$(backup_path_identity "${RESTORE_TARGET_PARENT}")" == "${RESTORE_TARGET_PARENT_IDENTITY}" ]] \
        || return 20
    backup_assert_empty_target "${RESTORE_TARGET_ROOT}"
}

restore_claim_target() {
    local claim entries temporary uid gid

    restore_recheck_target || return 20
    if [[ ! -e "${RESTORE_TARGET_ROOT}" && ! -L "${RESTORE_TARGET_ROOT}" ]]; then
        mkdir -m 0700 -- "${RESTORE_TARGET_ROOT}" || return 20
    fi
    [[ -d "${RESTORE_TARGET_ROOT}" && ! -L "${RESTORE_TARGET_ROOT}" ]] || return 20
    claim="${RESTORE_TARGET_ROOT}/.threadhub-restore-claim"
    [[ ! -e "${claim}" && ! -L "${claim}" ]] || return 20
    umask 077
    temporary="$(mktemp "${RESTORE_TARGET_ROOT}/.restore-claim.tmp.XXXXXX")" || return 20
    if ! chmod 0600 "${temporary}" \
        || ! backup_link_no_clobber "${temporary}" "${claim}"; then
        rm -f -- "${temporary}"
        return 20
    fi
    rm -f -- "${temporary}" || return 20
    uid="$(backup_expected_uid)"
    gid="$(backup_expected_gid)"
    backup_require_regular_mode_owner "${claim}" 600 "${uid}" "${gid}" || return 20
    entries="$(find -P "${RESTORE_TARGET_ROOT}" -mindepth 1 -maxdepth 1 -print)" || return 20
    [[ "${entries}" == "${claim}" ]] || return 20
    chown "${uid}:${gid}" "${RESTORE_TARGET_ROOT}" || return 20
    chmod 0750 "${RESTORE_TARGET_ROOT}" || return 20
    backup_require_directory_mode_owner "${RESTORE_TARGET_ROOT}" 750 "${uid}" "${gid}" \
        || return 20
    RESTORE_TARGET_CLAIM="${claim}"
}

restore_release_claim() {
    local uid gid

    [[ -n "${RESTORE_TARGET_CLAIM}" \
        && "${RESTORE_TARGET_CLAIM}" == "${RESTORE_TARGET_ROOT}/.threadhub-restore-claim" ]] \
        || return 20
    uid="$(backup_expected_uid)"
    gid="$(backup_expected_gid)"
    backup_require_regular_mode_owner "${RESTORE_TARGET_CLAIM}" 600 "${uid}" "${gid}" || return 20
    rm -f -- "${RESTORE_TARGET_CLAIM}" || return 20
    [[ ! -e "${RESTORE_TARGET_CLAIM}" && ! -L "${RESTORE_TARGET_CLAIM}" ]]
}

restore_prepare_target() {
    (prepare_threadhub_data_layout "${RESTORE_TARGET_ROOT}") >/dev/null 2>&1 || return 20
    (ensure_disabled_notifier_control "${RESTORE_TARGET_ROOT}") >/dev/null 2>&1 || return 20
    backup_directory_is_empty "${RESTORE_TARGET_ROOT}/notifier/mailer"
}

restore_build_notifier() {
    restore_run_private build-notifier "${RESTORE_SCRIPT_DIR}/build-notifier.sh"
}

restore_verify_mailer_image() {
    local manifest="$1" release_file="$2" expected actual occurrences

    [[ -f "${manifest}" && ! -L "${manifest}" \
        && -f "${release_file}" && ! -L "${release_file}" ]] || return 20
    expected="$(jq -er '.notifier.mailer_image_id | select(type == "string")' \
        "${manifest}" 2>/dev/null)" || return 20
    occurrences="$(awk -F= '$1 == "NOTIFIER_MAILER_IMAGE_ID" { count++ } END { print count + 0 }' \
        "${release_file}")" || return 20
    [[ "${occurrences}" == 1 ]] || return 20
    actual="$(backup_artifact_release_value "${release_file}" NOTIFIER_MAILER_IMAGE_ID)" || return 20
    [[ "${expected}" =~ ^sha256:[a-f0-9]{64}$ \
        && "${actual}" =~ ^sha256:[a-f0-9]{64}$ \
        && "${actual}" == "${expected}" ]]
}

restore_verify_built_mailer() {
    local release_file="${RESTORE_TARGET_ROOT}/notifier/release/release.env"
    local uid gid

    uid="$(backup_expected_uid)"
    gid="$(backup_expected_gid)"
    backup_require_regular_mode_owner "${release_file}" 640 "${uid}" "${gid}" || return 20
    restore_verify_mailer_image "${RESTORE_DOWNLOAD_DIR}/manifest.json" "${release_file}"
}

restore_start_postgres() {
    restore_run_private start-postgres compose up -d --wait --wait-timeout 120 postgres
}

restore_assert_empty_database() {
    local db_user db_name output diagnostic relation_count

    db_user="$(env_value POSTGRES_USER "${ENV_FILE}")" || return 20
    db_name="$(env_value POSTGRES_DB "${ENV_FILE}")" || return 20
    [[ "${db_user}" =~ ^[A-Za-z_][A-Za-z0-9_.-]{0,62}$ \
        && "${db_name}" =~ ^[A-Za-z_][A-Za-z0-9_.-]{0,62}$ ]] || return 20
    output="${RESTORE_RUN_ROOT}/database-relation-count"
    diagnostic="$(restore_private_diagnostic database-empty-check)" || return 20
    [[ ! -e "${output}" && ! -L "${output}" \
        && ! -e "${diagnostic}" && ! -L "${diagnostic}" ]] || return 20
    if ! compose exec -T postgres psql --username "${db_user}" --dbname "${db_name}" -Atc \
        "select count(*) from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relkind in ('r','p','v','m','S','f');" \
        >"${output}" 2>"${diagnostic}"; then
        chmod 0600 "${output}" "${diagnostic}" >/dev/null 2>&1 || true
        return 30
    fi
    chmod 0600 "${output}" "${diagnostic}" || return 30
    relation_count="$(<"${output}")"
    [[ "${relation_count}" == 0 ]]
}

restore_database() {
    local db_user db_name diagnostic dump

    db_user="$(env_value POSTGRES_USER "${ENV_FILE}")" || return 20
    db_name="$(env_value POSTGRES_DB "${ENV_FILE}")" || return 20
    dump="${RESTORE_DOWNLOAD_DIR}/database.dump"
    diagnostic="$(restore_private_diagnostic database-restore)" || return 20
    backup_artifact_file_is_private "${dump}" || return 20
    [[ ! -e "${diagnostic}" && ! -L "${diagnostic}" ]] || return 20
    if ! compose exec -T postgres pg_restore \
        --exit-on-error --no-owner --no-acl \
        --username "${db_user}" --dbname "${db_name}" \
        <"${dump}" >"${diagnostic}" 2>&1; then
        chmod 0600 "${diagnostic}" >/dev/null 2>&1 || true
        return 30
    fi
    chmod 0600 "${diagnostic}" || return 30
}

restore_canonicalize_mattermost_publish_roots() {
    local destination="${RESTORE_TARGET_ROOT}/mattermost/data"
    local plugins="${destination}/plugins"

    [[ -d "${destination}" && ! -L "${destination}" \
        && -d "${plugins}" && ! -L "${plugins}" ]] || return 20
    "${SUDO_COMMAND[@]}" chown 2000:2000 "${destination}" "${plugins}" || return 20
    "${SUDO_COMMAND[@]}" chmod 0750 "${destination}" "${plugins}" || return 20
}

restore_publish_mattermost() {
    local destination="${RESTORE_TARGET_ROOT}/mattermost/data" diagnostic unexpected

    [[ -d "${RESTORE_MATTERMOST_STAGING}" && ! -L "${RESTORE_MATTERMOST_STAGING}" \
        && -d "${destination}" && ! -L "${destination}" \
        && -d "${destination}/plugins" && ! -L "${destination}/plugins" ]] || return 20
    unexpected="$(find -P "${destination}" -mindepth 1 -maxdepth 1 \
        ! -name plugins -print -quit)" || return 20
    [[ -z "${unexpected}" ]] || return 20
    backup_directory_is_empty "${destination}/plugins" || return 20
    if [[ -e "${RESTORE_MATTERMOST_STAGING}/plugins" ]]; then
        [[ -d "${RESTORE_MATTERMOST_STAGING}/plugins" \
            && ! -L "${RESTORE_MATTERMOST_STAGING}/plugins" ]] || return 20
    fi
    diagnostic="$(restore_private_diagnostic mattermost-publish)" || return 20
    [[ ! -e "${diagnostic}" && ! -L "${diagnostic}" ]] || return 20
    if ! cp -a -- "${RESTORE_MATTERMOST_STAGING}/." "${destination}/" \
        >"${diagnostic}" 2>&1; then
        chmod 0600 "${diagnostic}" >/dev/null 2>&1 || true
        return 30
    fi
    chmod 0600 "${diagnostic}" || return 30
    restore_canonicalize_mattermost_publish_roots || return $?
    (normalize_threadhub_restored_data "${RESTORE_TARGET_ROOT}") >/dev/null 2>&1
}

restore_start_application() {
    restore_run_private deploy "${RESTORE_SCRIPT_DIR}/deploy.sh"
}

restore_live_queue_is_separate() {
    local live_dir="${RESTORE_TARGET_ROOT}/notifier/mailer" name live quarantined
    local unexpected live_identity quarantined_identity

    [[ -d "${live_dir}" && ! -L "${live_dir}" ]] || return 20
    unexpected="$(find -P "${live_dir}" -mindepth 1 -maxdepth 1 \
        ! -name queue.db ! -name queue.db-wal ! -name queue.db-shm -print -quit)" || return 20
    [[ -z "${unexpected}" ]] || return 20
    for name in queue.db queue.db-wal queue.db-shm; do
        live="${live_dir}/${name}"
        quarantined="${RESTORE_QUEUE_QUARANTINE}/${name}"
        if [[ "${name}" != queue.db && ! -e "${live}" && ! -L "${live}" ]]; then
            continue
        fi
        [[ -f "${live}" && ! -L "${live}" ]] || return 20
        if [[ -e "${quarantined}" || -L "${quarantined}" ]]; then
            [[ -f "${quarantined}" && ! -L "${quarantined}" ]] || return 20
            live_identity="$(backup_path_identity "${live}")" || return 20
            quarantined_identity="$(backup_path_identity "${quarantined}")" || return 20
            [[ "${live_identity}" != "${quarantined_identity}" ]] || return 20
        fi
    done
}

restore_verify_disabled_readiness() {
    local state_file="${RESTORE_TARGET_ROOT}/notifier/control/state.json"
    local status_file diagnostic

    notifier_control_is_valid "${state_file}" || return 20
    jq -e '.enabled == false and .delivery_enabled == false' "${state_file}" \
        >/dev/null 2>&1 || return 20
    restore_live_queue_is_separate || return 20
    status_file="${RESTORE_RUN_ROOT}/mailer-status.json"
    diagnostic="$(restore_private_diagnostic disabled-readiness)" || return 20
    [[ ! -e "${status_file}" && ! -L "${status_file}" \
        && ! -e "${diagnostic}" && ! -L "${diagnostic}" ]] || return 20
    if ! compose exec -T threadhub-mailer /threadhub-mailer status --json \
        >"${status_file}" 2>"${diagnostic}"; then
        chmod 0600 "${status_file}" "${diagnostic}" >/dev/null 2>&1 || true
        return 30
    fi
    chmod 0600 "${status_file}" "${diagnostic}" || return 30
    notifier_mailer_status_is_valid "${status_file}" || return 20
    jq -e '.pending == 0 and .sending == 0 and .sent == 0 and .failed == 0' \
        "${status_file}" >/dev/null 2>&1
}

restore_stop_partial_postgres() {
    compose stop --timeout 60 mattermost threadhub-mailer postgres >/dev/null 2>&1 || true
}

restore_main() {
    local backup_id="$1" prefix

    restore_preflight "${backup_id}" || return $?
    restore_prepare_state "${backup_id}" || return $?
    prefix="$(restore_find_set "${backup_id}")" || return $?
    restore_download_manifest "${prefix}" "${RESTORE_DOWNLOAD_DIR}" || return $?
    restore_validate_downloaded_manifest "${RESTORE_DOWNLOAD_DIR}" "${backup_id}" || return $?
    restore_download_manifest_artifacts "${prefix}" "${RESTORE_DOWNLOAD_DIR}" || return $?
    restore_validate_downloaded_set "${RESTORE_DOWNLOAD_DIR}" "${backup_id}" || return $?
    restore_extract_archives_to_staging || return $?
    restore_claim_target || return $?
    restore_prepare_target || return $?
    restore_build_notifier || return $?
    restore_verify_built_mailer || return $?
    RESTORE_POSTGRES_STARTED=true
    restore_start_postgres || return $?
    restore_assert_empty_database || return $?
    restore_database || return $?
    restore_publish_mattermost || return $?
    restore_start_application || return $?
    restore_verify_disabled_readiness || return $?
    restore_release_claim || return $?
    RESTORE_POSTGRES_STARTED=false
}

restore_report_failure() {
    if [[ "${RESTORE_POSTGRES_STARTED}" == true ]]; then
        restore_stop_partial_postgres
    fi
    printf '[FAILED] Restore stopped; no target data was deleted.\n' >&2
    if [[ -n "${RESTORE_RUN_ROOT}" && -d "${RESTORE_RUN_ROOT}" \
        && ! -L "${RESTORE_RUN_ROOT}" ]]; then
        printf '[ACTION REQUIRED] Inspect protected restore state: %s\n' \
            "${RESTORE_RUN_ROOT}" >&2
    fi
}

restore_entry() {
    local result

    if (($# != 1)) || ! backup_validate_id "${1:-}"; then
        printf 'Usage: %s BACKUP_ID\n' "$0" >&2
        return 20
    fi
    RESTORE_BACKUP_ID="$1"
    result=0
    restore_acquire_lock || result=$?
    if [[ "${result}" != 0 ]]; then
        if [[ "${result}" == 75 ]]; then
            printf '[ACTION REQUIRED] Another restore owns the restore lock; no target change was made.\n' >&2
        else
            printf '[ACTION REQUIRED] Restore lock is unavailable or unsafe; no target change was made.\n' >&2
        fi
        return "${result}"
    fi
    if restore_main "${RESTORE_BACKUP_ID}"; then
        printf '[READY] Restore completed with notifier delivery disabled.\n'
        printf '[MANUAL] Complete HTTPS, administrator, email, permissions, CJK, mobile, and notifier acceptance tests.\n'
        return 0
    else
        result=$?
    fi
    restore_report_failure
    return "${result}"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    restore_entry "$@"
fi
