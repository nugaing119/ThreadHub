#!/usr/bin/env bash

# Shared variables and functions are consumed by later backup entry points.
# shellcheck disable=SC2034

set -Eeuo pipefail

BACKUP_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${BACKUP_SCRIPT_DIR}/common.sh"

BACKUP_ENV_FILE="${THREADHUB_BACKUP_ENV_FILE:-/etc/threadhub/backup.env}"
BACKUP_STATE_ROOT=/var/lib/threadhub-backup
BACKUP_STAGING_ROOT=${BACKUP_STATE_ROOT}/staging
BACKUP_STATUS_ROOT=${BACKUP_STATE_ROOT}/status
BACKUP_STATUS_FILE=${BACKUP_STATUS_ROOT}/latest.json
BACKUP_LATEST_SUCCESS_FILE=${BACKUP_STATUS_ROOT}/latest-success.json
BACKUP_LOCK_FILE=${BACKUP_STATE_ROOT}/backup.lock

backup_expected_uid() {
    printf '0\n'
}

backup_expected_gid() {
    printf '0\n'
}

backup_path_mode() {
    if stat -c '%a' "$1" >/dev/null 2>&1; then
        stat -c '%a' "$1"
    else
        stat -f '%Lp' "$1"
    fi
}

backup_path_owner() {
    if stat -c '%u:%g' "$1" >/dev/null 2>&1; then
        stat -c '%u:%g' "$1"
    else
        stat -f '%u:%g' "$1"
    fi
}

backup_path_identity() {
    [[ -e "$1" && ! -L "$1" ]] || return 1
    if stat -c '%d:%i' "$1" >/dev/null 2>&1; then
        stat -c '%d:%i' "$1"
    else
        stat -f '%d:%i' "$1"
    fi
}

backup_require_regular_mode_owner() {
    local path="$1"
    local expected_mode="$2"
    local expected_uid="$3"
    local expected_gid="$4"

    [[ -f "${path}" && ! -L "${path}" ]] || return 20
    [[ "$(backup_path_mode "${path}")" == "${expected_mode}" ]] || return 20
    [[ "$(backup_path_owner "${path}")" == "${expected_uid}:${expected_gid}" ]] || return 20
}

backup_require_directory_mode_owner() {
    local path="$1"
    local expected_mode="$2"
    local expected_uid="$3"
    local expected_gid="$4"

    [[ -d "${path}" && ! -L "${path}" ]] || return 20
    [[ "$(backup_path_mode "${path}")" == "${expected_mode}" ]] || return 20
    [[ "$(backup_path_owner "${path}")" == "${expected_uid}:${expected_gid}" ]] || return 20
}

backup_require_exact_keys() {
    local path="$1"
    shift
    local expected_keys

    expected_keys="$(IFS=,; printf '%s' "$*")"
    LC_ALL=C awk -v expected="${expected_keys}" '
        BEGIN {
            count = split(expected, keys, ",")
            for (i = 1; i <= count; i++) allowed[keys[i]] = 1
        }
        {
            if ($0 !~ /^[A-Z0-9_]+=[!-~]+$/) exit 1
            separator = index($0, "=")
            key = substr($0, 1, separator - 1)
            value = substr($0, separator + 1)
            if (!(key in allowed) || value == "" || ++seen[key] != 1) exit 1
        }
        END {
            if (NR != count) exit 1
            for (i = 1; i <= count; i++) if (seen[keys[i]] != 1) exit 1
        }
    ' "${path}" >/dev/null 2>&1
}

backup_env_value() {
    local key="$1"

    LC_ALL=C awk -v key="${key}" '
        index($0, key "=") == 1 {
            count++
            value = substr($0, length(key) + 2)
        }
        END {
            if (count != 1 || value == "") exit 1
            print value
        }
    ' "${BACKUP_ENV_FILE}"
}

backup_validate_namespace() {
    [[ "$1" =~ ^[a-z0-9]{1,64}$ ]]
}

backup_validate_bucket() {
    [[ "$1" =~ ^[a-z0-9][a-z0-9._-]{0,62}$ ]]
}

backup_validate_email() {
    [[ "$1" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]]
}

backup_validate_config() {
    local uid gid

    uid="$(backup_expected_uid)"
    gid="$(backup_expected_gid)"
    backup_require_regular_mode_owner "${BACKUP_ENV_FILE}" 600 "${uid}" "${gid}" || return 20
    backup_require_exact_keys "${BACKUP_ENV_FILE}" \
        BACKUP_REGION BACKUP_NAMESPACE BACKUP_BUCKET BACKUP_ALERT_EMAIL \
        BACKUP_SCHEDULE BACKUP_DAILY_RETENTION_DAYS BACKUP_WEEKLY_RETENTION_DAYS || return 20
    [[ "$(backup_env_value BACKUP_REGION)" == ap-singapore-1 ]] || return 20
    [[ "$(backup_env_value BACKUP_SCHEDULE)" == 03:00 ]] || return 20
    [[ "$(backup_env_value BACKUP_DAILY_RETENTION_DAYS)" == 7 ]] || return 20
    [[ "$(backup_env_value BACKUP_WEEKLY_RETENTION_DAYS)" == 28 ]] || return 20
    backup_validate_namespace "$(backup_env_value BACKUP_NAMESPACE)" || return 20
    backup_validate_bucket "$(backup_env_value BACKUP_BUCKET)" || return 20
    backup_validate_email "$(backup_env_value BACKUP_ALERT_EMAIL)" || return 20
}

backup_validate_id() {
    [[ "${1:-}" =~ ^[0-9]{8}T[0-9]{6}Z-[a-f0-9]{32}$ ]]
}

backup_assert_empty_target() {
    local target="$1"

    [[ "${target}" == /srv/threadhub ]] || return 20
    [[ ! -L "${target}" ]] || return 20
    if [[ ! -e "${target}" ]]; then
        return 0
    fi
    [[ -d "${target}" ]] || return 20
    ! find "${target}" -mindepth 1 -print -quit | grep -q .
}

backup_prepare_state_root() {
    local uid gid path

    uid="$(backup_expected_uid)"
    gid="$(backup_expected_gid)"
    umask 077
    for path in "${BACKUP_STATE_ROOT}" "${BACKUP_STAGING_ROOT}" "${BACKUP_STATUS_ROOT}"; do
        [[ ! -L "${path}" ]] || return 20
        if [[ ! -e "${path}" ]]; then
            "${SUDO_COMMAND[@]}" install -d -o root -g root -m 0700 "${path}" || return 20
        fi
        backup_require_directory_mode_owner "${path}" 700 "${uid}" "${gid}" || return 20
    done
}

backup_validate_status_values() {
    [[ "$#" -eq 14 ]] || return 20
    local status="$1" phase="$2" backup_id="$3" started_at="$4" completed_at="$5"
    local downtime="$6" bundle_bytes="$7" object_count="$8" verification="$9"
    local snapshot="${10}" recovery="${11}" upload="${12}" failure="${13}" alert="${14}"

    [[ "${status}" == running || "${status}" == success || "${status}" == failed ]] || return 20
    [[ "${phase}" == preflight || "${phase}" == snapshot || "${phase}" == service_recovery \
        || "${phase}" == manifest || "${phase}" == upload || "${phase}" == remote_verify \
        || "${phase}" == complete ]] || return 20
    backup_validate_id "${backup_id}" || return 20
    for value in "${started_at}" "${completed_at}" "${downtime}" "${bundle_bytes}" "${object_count}"; do
        [[ "${value}" =~ ^[0-9]+$ ]] || return 20
    done
    [[ "${verification}" == pending || "${verification}" == ok || "${verification}" == failed || "${verification}" == not_run ]] || return 20
    [[ "${snapshot}" == pending || "${snapshot}" == ok || "${snapshot}" == failed || "${snapshot}" == not_run ]] || return 20
    [[ "${recovery}" == pending || "${recovery}" == ok || "${recovery}" == failed || "${recovery}" == not_needed ]] || return 20
    [[ "${upload}" == pending || "${upload}" == ok || "${upload}" == failed || "${upload}" == not_run ]] || return 20
    [[ "${failure}" == none || "${failure}" == preflight || "${failure}" == snapshot \
        || "${failure}" == service_recovery || "${failure}" == manifest \
        || "${failure}" == upload || "${failure}" == remote_verify ]] || return 20
    [[ "${alert}" == not_needed || "${alert}" == pending || "${alert}" == sent || "${alert}" == failed ]] || return 20
    if [[ "${status}" == success ]]; then
        [[ "${phase}" == complete && "${completed_at}" -gt 0 && "${verification}" == ok \
            && "${snapshot}" == ok && "${recovery}" == ok && "${upload}" == ok \
            && "${failure}" == none ]] || return 20
    elif [[ "${status}" == failed ]]; then
        [[ "${failure}" != none ]] || return 20
    fi
}

backup_status_json() {
    backup_validate_status_values "$@" || return 20
    jq -cn \
        --arg status "$1" --arg phase "$2" --arg backup_id "$3" \
        --argjson started_at "$4" --argjson completed_at "$5" \
        --argjson service_downtime_seconds "$6" --argjson local_bundle_bytes "$7" \
        --argjson uploaded_object_count "$8" --arg verification_result "$9" \
        --arg snapshot_result "${10}" --arg service_recovery_result "${11}" \
        --arg upload_result "${12}" --arg failure_class "${13}" --arg alert_delivery "${14}" '
        {
          status:$status,
          phase:$phase,
          backup_id:$backup_id,
          started_at:$started_at,
          completed_at:$completed_at,
          service_downtime_seconds:$service_downtime_seconds,
          local_bundle_bytes:$local_bundle_bytes,
          uploaded_object_count:$uploaded_object_count,
          verification_result:$verification_result,
          snapshot_result:$snapshot_result,
          service_recovery_result:$service_recovery_result,
          upload_result:$upload_result,
          failure_class:$failure_class,
          alert_delivery:$alert_delivery
        }
    '
}

backup_status_file_is_valid() {
    local path="$1"
    local uid gid

    uid="$(backup_expected_uid)"
    gid="$(backup_expected_gid)"
    backup_require_regular_mode_owner "${path}" 600 "${uid}" "${gid}" || return 20
    jq -e '
        type == "object" and
        keys == ["alert_delivery","backup_id","completed_at","failure_class","local_bundle_bytes","phase","service_downtime_seconds","service_recovery_result","snapshot_result","started_at","status","upload_result","uploaded_object_count","verification_result"] and
        (.status == "running" or .status == "success" or .status == "failed") and
        (.phase == "preflight" or .phase == "snapshot" or .phase == "service_recovery" or .phase == "manifest" or .phase == "upload" or .phase == "remote_verify" or .phase == "complete") and
        (.backup_id | type == "string" and test("^[0-9]{8}T[0-9]{6}Z-[a-f0-9]{32}$")) and
        ([.started_at,.completed_at,.service_downtime_seconds,.local_bundle_bytes,.uploaded_object_count] | all(type == "number" and floor == . and . >= 0)) and
        (.verification_result == "pending" or .verification_result == "ok" or .verification_result == "failed" or .verification_result == "not_run") and
        (.snapshot_result == "pending" or .snapshot_result == "ok" or .snapshot_result == "failed" or .snapshot_result == "not_run") and
        (.service_recovery_result == "pending" or .service_recovery_result == "ok" or .service_recovery_result == "failed" or .service_recovery_result == "not_needed") and
        (.upload_result == "pending" or .upload_result == "ok" or .upload_result == "failed" or .upload_result == "not_run") and
        (.failure_class == "none" or .failure_class == "preflight" or .failure_class == "snapshot" or .failure_class == "service_recovery" or .failure_class == "manifest" or .failure_class == "upload" or .failure_class == "remote_verify") and
        (.alert_delivery == "not_needed" or .alert_delivery == "pending" or .alert_delivery == "sent" or .alert_delivery == "failed") and
        (if .status == "success" then (.phase == "complete" and .completed_at > 0 and .verification_result == "ok" and .snapshot_result == "ok" and .service_recovery_result == "ok" and .upload_result == "ok" and .failure_class == "none") elif .status == "failed" then .failure_class != "none" else true end)
    ' "${path}" >/dev/null 2>&1
}

backup_write_status_file() {
    local destination="$1"
    shift
    local status_identity temporary uid gid

    [[ "${destination}" == "${BACKUP_STATUS_FILE}" || "${destination}" == "${BACKUP_LATEST_SUCCESS_FILE}" ]] || return 20
    backup_prepare_state_root || return 20
    [[ ! -L "${destination}" ]] || return 20
    status_identity="$(backup_path_identity "${BACKUP_STATUS_ROOT}")" || return 20
    temporary="$(mktemp "${BACKUP_STATUS_ROOT}/.status.tmp.XXXXXX")" || return 20
    if ! backup_status_json "$@" > "${temporary}" \
        || ! chmod 0600 "${temporary}"; then
        "${SUDO_COMMAND[@]}" rm -f "${temporary}" >/dev/null 2>&1 || true
        return 20
    fi
    uid="$(backup_expected_uid)"
    gid="$(backup_expected_gid)"
    if [[ "$(backup_path_owner "${temporary}")" != "${uid}:${gid}" ]]; then
        "${SUDO_COMMAND[@]}" rm -f "${temporary}" >/dev/null 2>&1 || true
        return 20
    fi
    if sync -f "${temporary}" >/dev/null 2>&1; then
        :
    fi
    if [[ "$(backup_path_identity "${BACKUP_STATUS_ROOT}")" != "${status_identity}" ]] \
        || [[ -L "${destination}" ]] \
        || ! "${SUDO_COMMAND[@]}" mv -fT "${temporary}" "${destination}"; then
        "${SUDO_COMMAND[@]}" rm -f "${temporary}" >/dev/null 2>&1 || true
        return 20
    fi
    backup_status_file_is_valid "${destination}"
}

backup_write_status() {
    backup_write_status_file "${BACKUP_STATUS_FILE}" "$@"
}

backup_write_latest_success() {
    [[ "${1:-}" == success && "${9:-}" == ok ]] || return 20
    backup_write_status_file "${BACKUP_LATEST_SUCCESS_FILE}" "$@"
}

backup_read_status() {
    local path="${1:-${BACKUP_STATUS_FILE}}"

    [[ "${path}" == "${BACKUP_STATUS_FILE}" || "${path}" == "${BACKUP_LATEST_SUCCESS_FILE}" ]] || return 20
    backup_status_file_is_valid "${path}" || return 20
    jq -c . "${path}" 2>/dev/null
}

backup_safe_remove_set() {
    local target="$1"
    local backup_id uid gid

    backup_id="${target##*/}"
    backup_validate_id "${backup_id}" || return 20
    [[ "${target}" == "${BACKUP_STAGING_ROOT}/${backup_id}" ]] || return 20
    uid="$(backup_expected_uid)"
    gid="$(backup_expected_gid)"
    backup_require_directory_mode_owner "${BACKUP_STAGING_ROOT}" 700 "${uid}" "${gid}" || return 20
    backup_require_directory_mode_owner "${target}" 700 "${uid}" "${gid}" || return 20
    "${SUDO_COMMAND[@]}" rm -rf -- "${target}" || return 20
    [[ ! -e "${target}" && ! -L "${target}" ]]
}

backup_send_alert() {
    local failure_class="$1"

    adminnotice_failure_class_is_valid "${failure_class}" || return 20
    jq -cn \
        --arg recipient "$(backup_env_value BACKUP_ALERT_EMAIL)" \
        --arg failure_class "${failure_class}" \
        '{recipient:$recipient,failure_class:$failure_class}' \
        | compose run --rm --no-deps -T --entrypoint /threadhub-mailer \
            threadhub-mailer backup-alert --json-stdin >/dev/null 2>&1
}

adminnotice_failure_class_is_valid() {
    [[ "$1" == preflight || "$1" == snapshot || "$1" == service_recovery \
        || "$1" == manifest || "$1" == upload || "$1" == remote_verify ]]
}
