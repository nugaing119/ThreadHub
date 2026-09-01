#!/usr/bin/env bash

# Recovery and signal callbacks are invoked indirectly by traps.
# shellcheck disable=SC2329

set -Eeuo pipefail

BACKUP_COMMAND_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=backup-common.sh
source "${BACKUP_COMMAND_DIR}/backup-common.sh"
# shellcheck source=backup-oci.sh
source "${BACKUP_COMMAND_DIR}/backup-oci.sh"
# shellcheck source=backup-artifacts.sh
source "${BACKUP_COMMAND_DIR}/backup-artifacts.sh"

backup_now_epoch() {
    date +%s
}

backup_acquire_lock() {
    backup_prepare_state_root || return 20
    command -v flock >/dev/null 2>&1 || return 20
    [[ ! -L "${BACKUP_LOCK_FILE}" ]] || return 20
    umask 077
    exec 9>"${BACKUP_LOCK_FILE}" || return 20
    chmod 0600 "${BACKUP_LOCK_FILE}" || return 20
    flock -n 9 || return 75
    backup_artifact_file_is_private "${BACKUP_LOCK_FILE}"
}

backup_require_capacity() {
    local data_bytes queue_bytes available total maximum_required required

    [[ -d "${BACKUP_ARTIFACT_DATA_ROOT}/mattermost/data" \
        && ! -L "${BACKUP_ARTIFACT_DATA_ROOT}/mattermost/data" \
        && -d "${BACKUP_ARTIFACT_DATA_ROOT}/notifier/mailer" \
        && ! -L "${BACKUP_ARTIFACT_DATA_ROOT}/notifier/mailer" ]] || return 20
    data_bytes="$(du -sb -- "${BACKUP_ARTIFACT_DATA_ROOT}/mattermost/data" 2>/dev/null | awk 'NR == 1 {print $1}')" \
        || return 20
    queue_bytes="$(du -sb -- "${BACKUP_ARTIFACT_DATA_ROOT}/notifier/mailer" 2>/dev/null | awk 'NR == 1 {print $1}')" \
        || return 20
    available="$(df --output=avail -B1 "${BACKUP_STAGING_ROOT}" 2>/dev/null | awk 'NR == 2 {print $1}')" \
        || return 20
    [[ "${data_bytes}" =~ ^[0-9]+$ && "${queue_bytes}" =~ ^[0-9]+$ \
        && "${available}" =~ ^[0-9]+$ ]] || return 20
    maximum_required=4611686017890516991
    ((data_bytes <= maximum_required && queue_bytes <= maximum_required - data_bytes)) || return 20
    total=$((data_bytes + queue_bytes))
    required=$((2 * total + 1073741824))
    ((available >= required))
}

backup_initialize_docker() {
    [[ "$(id -u)" == 0 ]] || return 20
    command -v docker >/dev/null 2>&1 || return 20
    docker info >/dev/null 2>&1 || return 20
    DOCKER_COMMAND=(docker)
}

backup_preflight() {
    local required

    (require_ubuntu_amd64) >/dev/null 2>&1 || return 20
    (validate_runtime_env) >/dev/null 2>&1 || return 20
    backup_validate_config >/dev/null 2>&1 || return 20
    backup_prepare_state_root >/dev/null 2>&1 || return 20
    backup_cleanup_expired_sets || return 20
    backup_initialize_docker || return 20
    for required in jq tar zstd openssl flock stat git du df awk find; do
        command -v "${required}" >/dev/null 2>&1 || return 20
    done
    backup_require_gnu_tar || return 20
    compose config --quiet >/dev/null 2>&1 || return 20
    backup_require_capacity || return 20
    backup_oci_preflight >/dev/null 2>&1
}

backup_health() {
    "${BACKUP_COMMAND_DIR}/health-check.sh" >/dev/null 2>&1
}

backup_create_set_dir() {
    local set_dir="$1" uid gid

    backup_prepare_state_root || return 20
    [[ "${set_dir}" == "${BACKUP_STAGING_ROOT}/"* \
        && "${set_dir}" == "${BACKUP_STAGING_ROOT}/${set_dir##*/}" ]] || return 20
    backup_validate_id "${set_dir##*/}" || return 20
    [[ ! -e "${set_dir}" && ! -L "${set_dir}" ]] || return 20
    install -d -o root -g root -m 0700 "${set_dir}" || return 20
    uid="$(backup_expected_uid)"
    gid="$(backup_expected_gid)"
    backup_require_directory_mode_owner "${set_dir}" 700 "${uid}" "${gid}"
}

backup_stop_mattermost() {
    compose stop --timeout 60 mattermost >/dev/null 2>&1
}

backup_stop_mailer() {
    compose stop --timeout 60 threadhub-mailer >/dev/null 2>&1
}

backup_start_mailer() {
    compose up -d --no-deps --wait --wait-timeout 240 threadhub-mailer >/dev/null 2>&1
}

backup_start_mattermost() {
    compose up -d --no-deps --wait --wait-timeout 240 mattermost >/dev/null 2>&1
}

backup_snapshot() {
    backup_create_artifacts "$1"
}

backup_manifest() {
    local set_dir="$1"

    backup_write_manifest "${set_dir}" || return 20
    backup_validate_set "${set_dir}" "${set_dir##*/}"
}

backup_validate_local_set() {
    local set_dir="$1" backup_id="$2"

    backup_validate_set "${set_dir}" "${backup_id}"
}

backup_bundle_size() {
    local set_dir="$1" total=0 name size

    for name in database.dump mattermost-data.tar.zst notifier-queue.tar.zst manifest.json manifest.sha256; do
        size="$(wc -c < "${set_dir}/${name}" | tr -d ' ')" || return 20
        [[ "${size}" =~ ^[0-9]+$ && "${size}" -ge 0 ]] || return 20
        ((total <= 9223372036854775807 - size)) || return 20
        total=$((total + size))
    done
    printf '%s\n' "${total}"
}

backup_weekly_required() {
    [[ "$(TZ=Asia/Seoul date +%u)" == 7 ]]
}

backup_prefix_for_set() {
    local tier="$1" backup_id="$2" compact

    [[ "${tier}" == daily || "${tier}" == weekly ]] || return 20
    backup_validate_id "${backup_id}" || return 20
    compact="${backup_id%%T*}"
    printf '%s/%s/%s/%s/%s\n' "${tier}" "${compact:0:4}" "${compact:4:2}" "${compact:6:2}" "${backup_id}"
}

backup_upload_prefix() {
    local set_dir="$1" prefix="$2" name path sha key size

    for name in database.dump mattermost-data.tar.zst notifier-queue.tar.zst manifest.json manifest.sha256; do
        path="${set_dir}/${name}"
        sha="$(sha256_file "${path}")" || return 31
        size="$(wc -c < "${path}" | tr -d ' ')" || return 31
        [[ "${sha}" =~ ^[a-f0-9]{64}$ && "${size}" =~ ^[0-9]+$ ]] || return 31
        key="${prefix}/${name}"
        if [[ "${BACKUP_RUN_IS_RESUME}" == true ]] \
            && backup_oci_verify "${key}" "${size}" "${sha}"; then
            BACKUP_RUN_OBJECT_COUNT=$((BACKUP_RUN_OBJECT_COUNT + 1))
            continue
        fi
        backup_oci_upload "${path}" "${key}" "${sha}" || return 31
        BACKUP_RUN_OBJECT_COUNT=$((BACKUP_RUN_OBJECT_COUNT + 1))
    done
}

backup_verify_prefix() {
    local set_dir="$1" prefix="$2" name path sha key size

    for name in database.dump mattermost-data.tar.zst notifier-queue.tar.zst manifest.json manifest.sha256; do
        path="${set_dir}/${name}"
        sha="$(sha256_file "${path}")" || return 32
        size="$(wc -c < "${path}" | tr -d ' ')" || return 32
        key="${prefix}/${name}"
        backup_oci_verify "${key}" "${size}" "${sha}" || return 32
    done
}

backup_upload_set() {
    local set_dir="$1" weekly_required="$2" backup_id daily_prefix weekly_prefix

    [[ "${weekly_required}" == true || "${weekly_required}" == false ]] || return 31
    backup_id="${set_dir##*/}"
    daily_prefix="$(backup_prefix_for_set daily "${backup_id}")" || return 31
    backup_upload_prefix "${set_dir}" "${daily_prefix}" || return 31
    if [[ "${weekly_required}" == true ]]; then
        weekly_prefix="$(backup_prefix_for_set weekly "${backup_id}")" || return 31
        backup_upload_prefix "${set_dir}" "${weekly_prefix}" || return 31
    fi
}

backup_verify_set() {
    local set_dir="$1" weekly_required="$2" backup_id daily_prefix weekly_prefix

    [[ "${weekly_required}" == true || "${weekly_required}" == false ]] || return 32
    backup_id="${set_dir##*/}"
    daily_prefix="$(backup_prefix_for_set daily "${backup_id}")" || return 32
    backup_verify_prefix "${set_dir}" "${daily_prefix}" || return 32
    if [[ "${weekly_required}" == true ]]; then
        weekly_prefix="$(backup_prefix_for_set weekly "${backup_id}")" || return 32
        backup_verify_prefix "${set_dir}" "${weekly_prefix}" || return 32
    fi
}

backup_resume_root() {
    printf '%s/resume\n' "${BACKUP_STATE_ROOT}"
}

backup_resume_marker_path() {
    local backup_id="$1"

    backup_validate_id "${backup_id}" || return 20
    printf '%s/%s.json\n' "$(backup_resume_root)" "${backup_id}"
}

backup_prepare_resume_root() {
    local root uid gid

    backup_prepare_state_root || return 20
    root="$(backup_resume_root)"
    [[ ! -L "${root}" ]] || return 20
    if [[ ! -e "${root}" ]]; then
        "${SUDO_COMMAND[@]}" install -d -o root -g root -m 0700 "${root}" || return 20
    fi
    uid="$(backup_expected_uid)"
    gid="$(backup_expected_gid)"
    backup_require_directory_mode_owner "${root}" 700 "${uid}" "${gid}"
}

backup_resume_marker_is_valid() {
    local backup_id="$1" marker now uid gid

    marker="$(backup_resume_marker_path "${backup_id}")" || return 20
    uid="$(backup_expected_uid)"
    gid="$(backup_expected_gid)"
    backup_require_regular_mode_owner "${marker}" 600 "${uid}" "${gid}" || return 20
    jq -e --arg id "${backup_id}" '
        type == "object" and keys == ["backup_id","expires_at","weekly_required"] and
        .backup_id == $id and
        (.expires_at | type == "number" and floor == . and . >= 0) and
        (.weekly_required | type == "boolean")
    ' "${marker}" >/dev/null 2>&1
    now="$(backup_now_epoch)" || return 20
    jq -e --argjson now "${now}" '
        .expires_at >= $now and .expires_at <= ($now + 86400)
    ' "${marker}" >/dev/null 2>&1
}

backup_cleanup_expired_sets() {
    local root marker filename backup_id expires now set_dir uid gid
    local -a markers=()

    root="$(backup_resume_root)"
    [[ ! -L "${root}" ]] || return 20
    [[ -e "${root}" ]] || return 0
    uid="$(backup_expected_uid)"
    gid="$(backup_expected_gid)"
    backup_require_directory_mode_owner "${root}" 700 "${uid}" "${gid}" || return 20
    shopt -s nullglob
    markers=("${root}"/*.json)
    shopt -u nullglob
    now="$(backup_now_epoch)" || return 20
    for marker in "${markers[@]}"; do
        filename="${marker##*/}"
        backup_id="${filename%.json}"
        [[ "${filename}" == "${backup_id}.json" ]] || return 20
        backup_validate_id "${backup_id}" || return 20
        backup_artifact_file_is_private "${marker}" || return 20
        jq -e --arg id "${backup_id}" '
            type == "object" and keys == ["backup_id","expires_at","weekly_required"] and
            .backup_id == $id and
            (.expires_at | type == "number" and floor == . and . >= 0) and
            (.weekly_required | type == "boolean")
        ' "${marker}" >/dev/null 2>&1 || return 20
        expires="$(jq -er '.expires_at' "${marker}" 2>/dev/null)" || return 20
        if ((expires < now)); then
            set_dir="${BACKUP_STAGING_ROOT}/${backup_id}"
            backup_safe_remove_set "${set_dir}" || return 20
            [[ ! -L "${marker}" ]] || return 20
            rm -f -- "${marker}" || return 20
        fi
    done
}

backup_retain_set() {
    local set_dir="$1" weekly_required="$2" backup_id marker temporary expires

    backup_id="${set_dir##*/}"
    backup_validate_local_set "${set_dir}" "${backup_id}" || return 20
    [[ "${weekly_required}" == true || "${weekly_required}" == false ]] || return 20
    backup_prepare_resume_root || return 20
    marker="$(backup_resume_marker_path "${backup_id}")" || return 20
    if [[ -e "${marker}" || -L "${marker}" ]]; then
        backup_resume_marker_is_valid "${backup_id}"
        return
    fi
    expires=$(( $(backup_now_epoch) + 86400 ))
    temporary="$(mktemp "$(backup_resume_root)/.${backup_id}.tmp.XXXXXX")" || return 20
    if ! jq -S -c -n --arg backup_id "${backup_id}" --argjson expires_at "${expires}" \
        --argjson weekly_required "${weekly_required}" \
        '{backup_id:$backup_id,expires_at:$expires_at,weekly_required:$weekly_required}' > "${temporary}" \
        || ! chmod 0600 "${temporary}" \
        || ! backup_artifact_publish_no_clobber "${temporary}" "${marker}"; then
        rm -f -- "${temporary}"
        return 20
    fi
}

backup_resume_validate() {
    local backup_id="$1" set_dir required

    backup_validate_id "${backup_id}" || return 20
    (require_ubuntu_amd64) >/dev/null 2>&1 || return 20
    (validate_runtime_env) >/dev/null 2>&1 || return 20
    backup_validate_config >/dev/null 2>&1 || return 20
    backup_prepare_state_root >/dev/null 2>&1 || return 20
    backup_initialize_docker || return 20
    for required in jq tar zstd openssl flock stat git; do
        command -v "${required}" >/dev/null 2>&1 || return 20
    done
    backup_require_gnu_tar || return 20
    compose config --quiet >/dev/null 2>&1 || return 20
    backup_oci_preflight >/dev/null 2>&1 || return 20
    backup_prepare_resume_root || return 20
    backup_resume_marker_is_valid "${backup_id}" || return 20
    set_dir="${BACKUP_STAGING_ROOT}/${backup_id}"
    backup_validate_local_set "${set_dir}" "${backup_id}"
}

backup_resume_weekly_required() {
    local backup_id="$1" marker

    backup_resume_marker_is_valid "${backup_id}" || return 20
    marker="$(backup_resume_marker_path "${backup_id}")" || return 20
    jq -e '.weekly_required == true' "${marker}" >/dev/null 2>&1
}

backup_cleanup_set() {
    local set_dir="$1" backup_id marker root uid gid

    backup_id="${set_dir##*/}"
    marker="$(backup_resume_marker_path "${backup_id}")" || return 20
    root="$(backup_resume_root)"
    [[ ! -L "${root}" && ! -L "${marker}" ]] || return 20
    if [[ -e "${root}" ]]; then
        uid="$(backup_expected_uid)"
        gid="$(backup_expected_gid)"
        backup_require_directory_mode_owner "${root}" 700 "${uid}" "${gid}" || return 20
    fi
    backup_safe_remove_set "${set_dir}" || return 20
    rm -f -- "${marker}"
}

backup_persist_status() {
    backup_write_status \
        "${BACKUP_RUN_STATUS}" "${BACKUP_RUN_PHASE}" "${BACKUP_RUN_ID}" \
        "${BACKUP_RUN_STARTED_AT}" "${BACKUP_RUN_COMPLETED_AT}" "${BACKUP_RUN_DOWNTIME}" \
        "${BACKUP_RUN_BUNDLE_BYTES}" "${BACKUP_RUN_OBJECT_COUNT}" "${BACKUP_RUN_VERIFICATION_RESULT}" \
        "${BACKUP_RUN_SNAPSHOT_RESULT}" "${BACKUP_RUN_RECOVERY_RESULT}" "${BACKUP_RUN_UPLOAD_RESULT}" \
        "${BACKUP_RUN_FAILURE_CLASS}" "${BACKUP_RUN_ALERT_DELIVERY}"
}

backup_persist_latest_success() {
    backup_write_latest_success \
        "${BACKUP_RUN_STATUS}" "${BACKUP_RUN_PHASE}" "${BACKUP_RUN_ID}" \
        "${BACKUP_RUN_STARTED_AT}" "${BACKUP_RUN_COMPLETED_AT}" "${BACKUP_RUN_DOWNTIME}" \
        "${BACKUP_RUN_BUNDLE_BYTES}" "${BACKUP_RUN_OBJECT_COUNT}" "${BACKUP_RUN_VERIFICATION_RESULT}" \
        "${BACKUP_RUN_SNAPSHOT_RESULT}" "${BACKUP_RUN_RECOVERY_RESULT}" "${BACKUP_RUN_UPLOAD_RESULT}" \
        "${BACKUP_RUN_FAILURE_CLASS}" "${BACKUP_RUN_ALERT_DELIVERY}"
}

backup_alert_once() {
    local failure_class="$1"

    if [[ "${BACKUP_RUN_ALERT_ATTEMPTED}" == true ]]; then
        [[ "${BACKUP_RUN_ALERT_DELIVERY}" == sent ]]
        return
    fi
    BACKUP_RUN_ALERT_ATTEMPTED=true
    backup_send_alert "${failure_class}"
}

backup_finish_failure() {
    local failure_class="$1"

    BACKUP_RUN_STATUS=failed
    BACKUP_RUN_FAILURE_CLASS="${failure_class}"
    BACKUP_RUN_PHASE="${failure_class}"
    [[ "${failure_class}" != remote_verify ]] || BACKUP_RUN_PHASE=remote_verify
    BACKUP_RUN_COMPLETED_AT="$(backup_now_epoch)"
    if [[ "${failure_class}" == preflight ]]; then
        BACKUP_RUN_SNAPSHOT_RESULT=not_run
        BACKUP_RUN_RECOVERY_RESULT=not_needed
        BACKUP_RUN_UPLOAD_RESULT=not_run
        BACKUP_RUN_VERIFICATION_RESULT=not_run
    elif [[ "${failure_class}" == snapshot || "${failure_class}" == service_recovery \
        || "${failure_class}" == manifest ]]; then
        BACKUP_RUN_UPLOAD_RESULT=not_run
        BACKUP_RUN_VERIFICATION_RESULT=not_run
    elif [[ "${failure_class}" == upload ]]; then
        BACKUP_RUN_VERIFICATION_RESULT=not_run
    fi
    BACKUP_RUN_ALERT_DELIVERY=pending
    if backup_alert_once "${failure_class}"; then
        BACKUP_RUN_ALERT_DELIVERY=sent
    else
        BACKUP_RUN_ALERT_DELIVERY=failed
    fi
    backup_persist_status || true

    if [[ -n "${BACKUP_RUN_SET_DIR}" && -d "${BACKUP_RUN_SET_DIR}" ]]; then
        if [[ "${failure_class}" == upload || "${failure_class}" == remote_verify ]]; then
            if [[ "${BACKUP_RUN_IS_RESUME}" == false ]]; then
                backup_retain_set "${BACKUP_RUN_SET_DIR}" "${BACKUP_RUN_WEEKLY_REQUIRED}" || true
            fi
        else
            backup_cleanup_set "${BACKUP_RUN_SET_DIR}" || true
        fi
    fi
    return 1
}

backup_recover_writers_and_exit() {
    local original_status=$? recovery_failed=false had_stopped=false

    trap - EXIT HUP INT TERM
    [[ "${BACKUP_RUN_RECOVERY_RESULT}" != failed ]] || recovery_failed=true
    if [[ "${BACKUP_RUN_MAILER_STOPPED}" == true ]]; then
        had_stopped=true
        if backup_start_mailer; then
            BACKUP_RUN_MAILER_STOPPED=false
        else
            recovery_failed=true
        fi
    fi
    if [[ "${BACKUP_RUN_MATTERMOST_STOPPED}" == true ]]; then
        had_stopped=true
        if backup_start_mattermost; then
            BACKUP_RUN_MATTERMOST_STOPPED=false
        else
            recovery_failed=true
        fi
    fi
    if [[ "${had_stopped}" == true ]]; then
        backup_health || recovery_failed=true
    fi
    if [[ "${BACKUP_RUN_DOWNTIME_STARTED}" -gt 0 ]]; then
        BACKUP_RUN_DOWNTIME=$(( $(backup_now_epoch) - BACKUP_RUN_DOWNTIME_STARTED ))
    fi
    if [[ "${recovery_failed}" == true ]]; then
        BACKUP_RUN_RECOVERY_RESULT=failed
        BACKUP_RUN_FAILURE_CLASS=service_recovery
    else
        if [[ "${had_stopped}" == true ]]; then
            BACKUP_RUN_RECOVERY_RESULT=ok
        else
            BACKUP_RUN_RECOVERY_RESULT=not_needed
        fi
        [[ "${BACKUP_RUN_FAILURE_CLASS}" != none ]] || BACKUP_RUN_FAILURE_CLASS=snapshot
    fi
    backup_finish_failure "${BACKUP_RUN_FAILURE_CLASS}" || true
    if [[ "${recovery_failed}" == true ]]; then
        exit 1
    fi
    ((original_status == 0)) && original_status=1
    exit "${original_status}"
}

backup_run_new() {
    backup_health || {
        backup_finish_failure preflight
        return 1
    }
    BACKUP_RUN_SET_DIR="${BACKUP_STAGING_ROOT}/${BACKUP_RUN_ID}"
    backup_create_set_dir "${BACKUP_RUN_SET_DIR}" || {
        backup_finish_failure preflight
        return 1
    }
    BACKUP_RUN_STATUS=running
    BACKUP_RUN_PHASE=snapshot
    backup_persist_status || return 1

    trap backup_recover_writers_and_exit EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    BACKUP_RUN_DOWNTIME_STARTED="$(backup_now_epoch)"
    BACKUP_RUN_FAILURE_CLASS=snapshot
    BACKUP_RUN_SNAPSHOT_RESULT=failed
    backup_stop_mattermost || return 1
    BACKUP_RUN_MATTERMOST_STOPPED=true
    backup_stop_mailer || return 1
    BACKUP_RUN_MAILER_STOPPED=true
    backup_snapshot "${BACKUP_RUN_SET_DIR}" || return 1
    BACKUP_RUN_SNAPSHOT_RESULT=ok

    BACKUP_RUN_PHASE=service_recovery
    BACKUP_RUN_FAILURE_CLASS=service_recovery
    backup_start_mailer || return 1
    BACKUP_RUN_MAILER_STOPPED=false
    backup_start_mattermost || return 1
    BACKUP_RUN_MATTERMOST_STOPPED=false
    if ! backup_health; then
        BACKUP_RUN_RECOVERY_RESULT=failed
        return 1
    fi
    BACKUP_RUN_RECOVERY_RESULT=ok
    BACKUP_RUN_DOWNTIME=$(( $(backup_now_epoch) - BACKUP_RUN_DOWNTIME_STARTED ))
    trap - EXIT HUP INT TERM

    BACKUP_RUN_PHASE=manifest
    BACKUP_RUN_FAILURE_CLASS=manifest
    if ! backup_manifest "${BACKUP_RUN_SET_DIR}"; then
        backup_finish_failure manifest
        return 1
    fi
    BACKUP_RUN_BUNDLE_BYTES="$(backup_bundle_size "${BACKUP_RUN_SET_DIR}")" || {
        backup_finish_failure manifest
        return 1
    }
    if backup_weekly_required; then
        BACKUP_RUN_WEEKLY_REQUIRED=true
    fi

    BACKUP_RUN_PHASE=upload
    BACKUP_RUN_FAILURE_CLASS=upload
    if ! backup_upload_set "${BACKUP_RUN_SET_DIR}" "${BACKUP_RUN_WEEKLY_REQUIRED}"; then
        BACKUP_RUN_UPLOAD_RESULT=failed
        BACKUP_RUN_VERIFICATION_RESULT=not_run
        backup_finish_failure upload
        return 1
    fi
    BACKUP_RUN_UPLOAD_RESULT=ok
    BACKUP_RUN_PHASE=remote_verify
    BACKUP_RUN_FAILURE_CLASS=remote_verify
    if ! backup_verify_set "${BACKUP_RUN_SET_DIR}" "${BACKUP_RUN_WEEKLY_REQUIRED}"; then
        BACKUP_RUN_VERIFICATION_RESULT=failed
        backup_finish_failure remote_verify
        return 1
    fi
    BACKUP_RUN_VERIFICATION_RESULT=ok
}

backup_run_resume() {
    BACKUP_RUN_SET_DIR="${BACKUP_STAGING_ROOT}/${BACKUP_RUN_ID}"
    if ! backup_resume_validate "${BACKUP_RUN_ID}"; then
        backup_finish_failure preflight
        return 1
    fi
    BACKUP_RUN_SNAPSHOT_RESULT=ok
    BACKUP_RUN_RECOVERY_RESULT=ok
    BACKUP_RUN_BUNDLE_BYTES="$(backup_bundle_size "${BACKUP_RUN_SET_DIR}")" || {
        backup_finish_failure preflight
        return 1
    }
    weekly_result=0
    backup_resume_weekly_required "${BACKUP_RUN_ID}" || weekly_result=$?
    if [[ "${weekly_result}" == 0 ]]; then
        BACKUP_RUN_WEEKLY_REQUIRED=true
    elif [[ "${weekly_result}" != 1 ]]; then
        backup_finish_failure preflight
        return 1
    fi
    BACKUP_RUN_PHASE=upload
    if ! backup_upload_set "${BACKUP_RUN_SET_DIR}" "${BACKUP_RUN_WEEKLY_REQUIRED}"; then
        BACKUP_RUN_UPLOAD_RESULT=failed
        BACKUP_RUN_VERIFICATION_RESULT=not_run
        backup_finish_failure upload
        return 1
    fi
    BACKUP_RUN_UPLOAD_RESULT=ok
    BACKUP_RUN_PHASE=remote_verify
    if ! backup_verify_set "${BACKUP_RUN_SET_DIR}" "${BACKUP_RUN_WEEKLY_REQUIRED}"; then
        BACKUP_RUN_VERIFICATION_RESULT=failed
        backup_finish_failure remote_verify
        return 1
    fi
    BACKUP_RUN_VERIFICATION_RESULT=ok
}

backup_finish_success() {
    BACKUP_RUN_STATUS=success
    BACKUP_RUN_PHASE=complete
    BACKUP_RUN_FAILURE_CLASS=none
    BACKUP_RUN_ALERT_DELIVERY=not_needed
    BACKUP_RUN_COMPLETED_AT="$(backup_now_epoch)"
    backup_persist_status || return 1
    backup_persist_latest_success || return 1
    backup_cleanup_set "${BACKUP_RUN_SET_DIR}"
}

backup_initialize_run_state() {
    BACKUP_RUN_STATUS=running
    BACKUP_RUN_PHASE=preflight
    BACKUP_RUN_STARTED_AT="$(backup_now_epoch)"
    BACKUP_RUN_COMPLETED_AT=0
    BACKUP_RUN_DOWNTIME=0
    BACKUP_RUN_DOWNTIME_STARTED=0
    BACKUP_RUN_BUNDLE_BYTES=0
    BACKUP_RUN_OBJECT_COUNT=0
    BACKUP_RUN_VERIFICATION_RESULT=pending
    BACKUP_RUN_SNAPSHOT_RESULT=pending
    BACKUP_RUN_RECOVERY_RESULT=pending
    BACKUP_RUN_UPLOAD_RESULT=pending
    BACKUP_RUN_FAILURE_CLASS=none
    BACKUP_RUN_ALERT_DELIVERY=not_needed
    BACKUP_RUN_ALERT_ATTEMPTED=false
    BACKUP_RUN_SET_DIR=''
    BACKUP_RUN_WEEKLY_REQUIRED=false
    BACKUP_RUN_IS_RESUME=false
    BACKUP_RUN_MATTERMOST_STOPPED=false
    BACKUP_RUN_MAILER_STOPPED=false
}

backup_main() (
    set -Eeuo pipefail
    umask 077

    if [[ "$#" -eq 0 ]]; then
        mode=new
    elif [[ "$#" -eq 2 && "$1" == --resume-upload ]]; then
        mode=resume
        requested_id="$2"
    else
        return 20
    fi

    backup_initialize_run_state
    lock_result=0
    backup_acquire_lock || lock_result=$?
    [[ "${lock_result}" != 75 ]] || return 0
    if [[ "${lock_result}" != 0 ]]; then
        BACKUP_RUN_ID="$(backup_generate_id)" || return 20
        backup_finish_failure preflight
        return 1
    fi

    if [[ "${mode}" == resume ]]; then
        BACKUP_RUN_ID="${requested_id}"
        if ! backup_validate_id "${BACKUP_RUN_ID}"; then
            BACKUP_RUN_ID="$(backup_generate_id)" || return 20
            backup_finish_failure preflight
            return 1
        fi
        BACKUP_RUN_IS_RESUME=true
        backup_run_resume || return 1
    else
        BACKUP_RUN_ID="$(backup_generate_id)" || return 20
        if ! backup_preflight; then
            backup_finish_failure preflight
            return 1
        fi
        backup_run_new || return 1
    fi
    backup_finish_success
)

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    backup_main "$@"
fi
