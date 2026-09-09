#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=existing-notifier-v010-v020-preflight.sh
source "${SCRIPT_DIR}/existing-notifier-v010-v020-preflight.sh"

existing_notifier_v010_v020_recovery_gate_action_required() {
    printf '[ACTION REQUIRED] %s\n' "$1" >&2
    return 20
}

existing_notifier_v010_v020_gate_stdin_is_tty() {
    [[ -t 0 ]]
}

existing_notifier_v010_v020_gate_read_confirmation() {
    local confirmation

    IFS= read -r confirmation || return 1
    printf '%s\n' "${confirmation}"
}

existing_notifier_v010_v020_gate_validate_runtime_root() {
    local notifier_root="$1"

    "${SUDO_COMMAND[@]}" test -d "${notifier_root}" \
        && "${SUDO_COMMAND[@]}" test ! -L "${notifier_root}" \
        && [[ "$(existing_notifier_v010_v020_privileged_identity "${notifier_root}")" == 0:0:750 ]]
}

existing_notifier_v010_v020_gate_prepare_parent() {
    local migration_root="$1"
    local notifier_root

    notifier_root="$(dirname "${migration_root}")"
    existing_notifier_v010_v020_gate_validate_runtime_root "${notifier_root}" || return 1
    if "${SUDO_COMMAND[@]}" test -e "${migration_root}" \
        || "${SUDO_COMMAND[@]}" test -L "${migration_root}"; then
        "${SUDO_COMMAND[@]}" test -d "${migration_root}" \
            && "${SUDO_COMMAND[@]}" test ! -L "${migration_root}" \
            && [[ "$(existing_notifier_v010_v020_privileged_identity "${migration_root}")" == 0:0:700 ]]
        return
    fi
    "${SUDO_COMMAND[@]}" install -d -o root -g root -m 0700 "${migration_root}"
}

existing_notifier_v010_v020_gate_publish() {
    local source_file="$1"
    local destination="$2"
    local candidate="${destination}.tmp.$$"

    "${SUDO_COMMAND[@]}" test ! -e "${candidate}" \
        && "${SUDO_COMMAND[@]}" test ! -L "${candidate}" || return 1
    "${SUDO_COMMAND[@]}" install -o root -g root -m 0600 "${source_file}" "${candidate}" || return 1
    if ! "${SUDO_COMMAND[@]}" ln "${candidate}" "${destination}"; then
        "${SUDO_COMMAND[@]}" rm -f -- "${candidate}" >/dev/null 2>&1 || true
        return 1
    fi
    "${SUDO_COMMAND[@]}" rm -f -- "${candidate}" || return 1
}

existing_notifier_v010_v020_recovery_gate_record() (
    local notifier_root
    local migration_root
    local gate_file
    local confirmation
    local temporary_dir
    local candidate

    if [[ "$(existing_notifier_v010_v020_config_state "${EXISTING_NOTIFIER_V010_V020_ENV_FILE}" 2>/dev/null)" != source ]]; then
        existing_notifier_v010_v020_recovery_gate_action_required "Exact v0.1.0 source configuration is required"
        return $?
    fi
    init_sudo
    notifier_root="$(existing_notifier_v010_v020_value THN_DATA_ROOT)"
    migration_root="${notifier_root}/migration"
    gate_file="${migration_root}/recovery-gate-v010-v020.json"
    if ! existing_notifier_v010_v020_gate_prepare_parent "${migration_root}"; then
        existing_notifier_v010_v020_recovery_gate_action_required "Recovery-gate parent is missing or unsafe"
        return $?
    fi
    if "${SUDO_COMMAND[@]}" test -e "${gate_file}" \
        || "${SUDO_COMMAND[@]}" test -L "${gate_file}"; then
        existing_notifier_v010_v020_recovery_gate_action_required "Recovery gate already exists and was not overwritten"
        return $?
    fi
    if ! existing_notifier_v010_v020_gate_stdin_is_tty; then
        existing_notifier_v010_v020_recovery_gate_action_required "Recording recovery review requires an interactive terminal"
        return $?
    fi
    printf '%s\n' 'Type exactly: I REVIEWED THE BACKUP AND DISPOSABLE RESTORE' >&2
    confirmation="$(existing_notifier_v010_v020_gate_read_confirmation)" || {
        existing_notifier_v010_v020_recovery_gate_action_required "Recovery review confirmation was not read"
        return $?
    }
    if [[ "${confirmation}" != 'I REVIEWED THE BACKUP AND DISPOSABLE RESTORE' ]]; then
        existing_notifier_v010_v020_recovery_gate_action_required "Recovery review confirmation did not match"
        return $?
    fi

    temporary_dir="$(mktemp -d)"
    trap 'rm -rf -- "${temporary_dir}"' EXIT HUP INT TERM
    chmod 0700 "${temporary_dir}"
    candidate="${temporary_dir}/gate.json"
    jq -n --arg profile "${EXISTING_NOTIFIER_V010_V020_ID}" \
        --arg commit "${EXISTING_NOTIFIER_V010_SOURCE_COMMIT}" \
        --arg reviewed_at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" '
      {
        schema:1,
        profile:$profile,
        source_release_commit:$commit,
        remote_backup_verified:true,
        disposable_restore_verified:true,
        aggregate_match_verified:true,
        restored_queue_quarantined:true,
        reviewed_at_utc:$reviewed_at
      }
    ' > "${candidate}"
    chmod 0600 "${candidate}"
    if ! existing_notifier_v010_v020_gate_publish "${candidate}" "${gate_file}" \
        || ! existing_notifier_v010_v020_recovery_gate_is_valid "${gate_file}"; then
        existing_notifier_v010_v020_recovery_gate_action_required "Recovery gate could not be published or verified"
        return $?
    fi
    printf '[OK] Recovery review gate recorded without replacing an existing gate\n'
)

existing_notifier_v010_v020_recovery_gate_check() {
    local state
    local notifier_root
    local gate_file

    state="$(existing_notifier_v010_v020_config_state "${EXISTING_NOTIFIER_V010_V020_ENV_FILE}" 2>/dev/null)" || {
        existing_notifier_v010_v020_recovery_gate_action_required "Notifier configuration is invalid"
        return $?
    }
    [[ "${state}" == source || "${state}" == target ]] || return 20
    init_sudo
    notifier_root="$(existing_notifier_v010_v020_value THN_DATA_ROOT)"
    gate_file="${notifier_root}/migration/recovery-gate-v010-v020.json"
    if ! existing_notifier_v010_v020_recovery_gate_is_valid "${gate_file}"; then
        existing_notifier_v010_v020_recovery_gate_action_required "Recovery review gate is missing, expired, or unsafe"
        return $?
    fi
    printf '[OK] Recovery review gate is current\n'
}

existing_notifier_v010_v020_recovery_gate_entry() {
    [[ "$#" -eq 1 && ( "$1" == record || "$1" == check ) ]] \
        || die "Usage: $0 {record|check}"
    case "$1" in
        record) existing_notifier_v010_v020_recovery_gate_record ;;
        check) existing_notifier_v010_v020_recovery_gate_check ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    existing_notifier_v010_v020_recovery_gate_entry "$@"
fi
