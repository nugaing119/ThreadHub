#!/usr/bin/env bash

set -Eeuo pipefail

BACKUP_STATUS_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! declare -F backup_read_status >/dev/null 2>&1; then
    # shellcheck source=backup-common.sh
    source "${BACKUP_STATUS_SCRIPT_DIR}/backup-common.sh"
fi

backup_status_now_epoch() {
    date +%s
}

backup_status_main() {
    [[ "$#" -le 1 ]] || return 20
    local format="${1:-human}"
    local current latest_success now latest_success_at healthy=true

    [[ "${format}" == human || "${format}" == --json ]] || return 20
    backup_validate_config || return 20
    current="$(backup_read_status "${BACKUP_STATUS_FILE}")" || return 1
    latest_success="$(backup_read_status "${BACKUP_LATEST_SUCCESS_FILE}")" || return 1
    now="$(backup_status_now_epoch)" || return 1
    latest_success_at="$(jq -er '.backup_id' <<< "${latest_success}")" || return 1
    latest_success_at="$(backup_id_epoch "${latest_success_at}")" || return 1
    if ! jq -e '.status == "success" and .verification_result == "ok"' <<< "${current}" >/dev/null \
        || ! jq -e '.status == "success" and .verification_result == "ok"' <<< "${latest_success}" >/dev/null \
        || ((latest_success_at > now || now - latest_success_at > 86400)); then
        healthy=false
    fi

    if [[ "${format}" == --json ]]; then
        printf '%s\n' "${current}"
    else
        jq -r 'to_entries[] | "\(.key)=\(.value)"' <<< "${current}"
    fi
    [[ "${healthy}" == true ]]
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    backup_status_main "$@"
fi
