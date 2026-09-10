#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=existing-notifier-v010-v020-upgrade.sh
source "${SCRIPT_DIR}/existing-notifier-v010-v020-upgrade.sh"

existing_notifier_v010_v020_rollback_action_required() {
    printf '[ACTION REQUIRED] %s\n' "$1" >&2
    return 20
}

v010_v020_rollback_validate_capture() {
    existing_notifier_v010_v020_upgrade_initialize \
        && existing_notifier_v010_v020_source_capture_is_complete \
            "$(existing_notifier_v010_v020_attempt_root)"
}

v010_v020_rollback_validate_phase() {
    local attempt_root
    local phase

    attempt_root="$(existing_notifier_v010_v020_attempt_root)"
    phase="$(existing_notifier_v010_v020_tx_state_current "${attempt_root}")" || {
        existing_notifier_v010_v020_rollback_action_required \
            "Transition phase is missing or ambiguous; no rollback object was changed"
        return $?
    }
    case "${phase}" in
        source_recovered)
            existing_notifier_v010_v020_rollback_action_required \
                "The exact source state is already recovered"
            return $?
            ;;
        recovery_failed|source_captured|target_release_verified|target_env_published|target_release_published|target_override_published|target_plugin_pair_published|target_mailer_started|target_queue_v2_verified|target_mattermost_recreated|target_pair_verified|after_baseline_captured|baseline_matched|disabled_verified|target_ready) ;;
        *) return 20 ;;
    esac
    if [[ "${phase}" == target_ready ]]; then
        v010_v020_tx_verify_target_pair "${attempt_root}" || return 1
    fi
}

v010_v020_rollback_require_disabled() {
    v010_v020_capture_control_is_disabled \
        "$(existing_notifier_v010_v020_attempt_root)" || {
        existing_notifier_v010_v020_rollback_action_required \
            "Disable notifier collection and delivery before rollback"
        return $?
    }
}

existing_notifier_v010_v020_inspect_live_queue() {
    local output_file="$1"
    existing_notifier_v010_v020_run_queue_inspector "${output_file}"
}

v010_v020_rollback_require_quiescent_target() (
    local temporary_dir
    local inspection

    temporary_dir="$(mktemp -d)" || return 1
    trap 'rm -rf -- "${temporary_dir}"' EXIT HUP INT TERM
    chmod 0700 "${temporary_dir}"
    inspection="${temporary_dir}/inspection.json"
    existing_notifier_v010_v020_inspect_live_queue "${inspection}" || return 1
    existing_notifier_v010_v020_queue_inspection_is_valid "${inspection}" || return 1
    if ! jq -e '.pending == 0 and .sending == 0 and .failed == 0' \
        "${inspection}" >/dev/null; then
        existing_notifier_v010_v020_rollback_action_required \
            "Rollback requires zero pending, sending, and failed deliveries; no force shortcut exists"
        return $?
    fi
)

existing_notifier_v010_v020_rollback_stdin_is_tty() {
    [[ -t 0 ]]
}

existing_notifier_v010_v020_rollback_read_confirmation() {
    local confirmation
    IFS= read -r confirmation || return 1
    printf '%s\n' "${confirmation}"
}

v010_v020_rollback_require_pilot_review() (
    local attempt_root
    local temporary_dir
    local current
    local source
    local confirmation

    attempt_root="$(existing_notifier_v010_v020_attempt_root)"
    temporary_dir="$(mktemp -d)" || return 1
    trap 'rm -rf -- "${temporary_dir}"' EXIT HUP INT TERM
    chmod 0700 "${temporary_dir}"
    current="${temporary_dir}/current.json"
    source="${temporary_dir}/source.json"
    existing_notifier_v010_v020_inspect_live_queue "${current}" || return 1
    "${SUDO_COMMAND[@]}" cat "${attempt_root}/queue-inspection.json" > "${source}" || return 1
    if [[ "$(jq -S 'del(.schema_version)' "${current}")" \
        == "$(jq -S 'del(.schema_version)' "${source}")" ]]; then
        return 0
    fi
    existing_notifier_v010_v020_rollback_stdin_is_tty || {
        existing_notifier_v010_v020_rollback_action_required \
            "Pilot events exist; review quarantined v0.2.0 delivery evidence in an interactive terminal"
        return $?
    }
    printf '%s\n' 'Type exactly: I REVIEWED V0.2.0 PILOT DELIVERY ROLLBACK' >&2
    confirmation="$(existing_notifier_v010_v020_rollback_read_confirmation)" || return 20
    [[ "${confirmation}" == 'I REVIEWED V0.2.0 PILOT DELIVERY ROLLBACK' ]] || {
        existing_notifier_v010_v020_rollback_action_required \
            "Pilot rollback confirmation did not match"
        return $?
    }
)

v010_v020_rollback_stop_target_mailer() {
    existing_notifier_v010_v020_compose_combined stop threadhub-mailer
}

v010_v020_rollback_capture_current_baseline() (
    local attempt_root
    local destination
    local temporary_dir
    local candidate

    attempt_root="$(existing_notifier_v010_v020_attempt_root)"
    destination="${attempt_root}/rollback-before-baseline.json"
    temporary_dir="$(mktemp -d)" || return 1
    trap 'rm -rf -- "${temporary_dir}"' EXIT HUP INT TERM
    chmod 0700 "${temporary_dir}"
    candidate="${temporary_dir}/baseline.json"
    existing_notifier_v010_v020_capture_baseline "${candidate}" || return 1
    if "${SUDO_COMMAND[@]}" test -e "${destination}" \
        || "${SUDO_COMMAND[@]}" test -L "${destination}"; then
        "${SUDO_COMMAND[@]}" test -f "${destination}" \
            && "${SUDO_COMMAND[@]}" test ! -L "${destination}" \
            && "${SUDO_COMMAND[@]}" cmp -s "${candidate}" "${destination}"
        return
    fi
    "${SUDO_COMMAND[@]}" install -o 0 -g 0 -m 0600 "${candidate}" "${destination}"
)

v010_v020_rollback_recover_source() {
    if ! existing_notifier_v010_v020_recover_source_runtime \
        "$(existing_notifier_v010_v020_attempt_root)"; then
        printf '[threadhub] ERROR: exact source recovery is incomplete; Mattermost recovery takes priority and delivery remains disabled\n' >&2
        return 70
    fi
}

v010_v020_rollback_verify_source_disabled() {
    existing_notifier_v010_v020_verify_source_runtime \
        "$(existing_notifier_v010_v020_attempt_root)"
}

v010_v020_rollback_compare_source_baseline() (
    local attempt_root
    local expected
    local recovered
    local temporary_dir
    local expected_copy
    local recovered_copy

    attempt_root="$(existing_notifier_v010_v020_attempt_root)"
    expected="$(existing_notifier_v010_v020_expected_recovery_baseline "${attempt_root}")" \
        || return 1
    recovered="${attempt_root}/recovery-baseline.json"
    temporary_dir="$(mktemp -d)" || return 1
    trap 'rm -rf -- "${temporary_dir}"' EXIT HUP INT TERM
    chmod 0700 "${temporary_dir}"
    expected_copy="${temporary_dir}/expected.json"
    recovered_copy="${temporary_dir}/recovered.json"
    "${SUDO_COMMAND[@]}" cat "${expected}" > "${expected_copy}" || return 1
    "${SUDO_COMMAND[@]}" cat "${recovered}" > "${recovered_copy}" || return 1
    chmod 0600 "${expected_copy}" "${recovered_copy}"
    existing_notifier_v010_v020_baseline_is_valid "${expected_copy}" \
        && existing_notifier_v010_v020_baseline_is_valid "${recovered_copy}" \
        && jq -e --slurp '.[0] == .[1]' \
            "${expected_copy}" "${recovered_copy}" >/dev/null
)

v010_v020_rollback_mark_source_recovered() {
    local attempt_root
    local phase
    attempt_root="$(existing_notifier_v010_v020_attempt_root)"
    phase="$(existing_notifier_v010_v020_tx_state_current "${attempt_root}")" || return 1
    existing_notifier_v010_v020_tx_state_write "${attempt_root}" source_recovered "${phase}" \
        && printf '[OK] Exact notifier v0.1.0 source state was restored disabled; v0.2.0 evidence remains quarantined\n'
}

existing_notifier_v010_v020_rollback_step() {
    local stage="$1"
    local status=0

    shift
    printf '[threadhub] notifier rollback stage: %s\n' "${stage}" >&2
    "$@" || {
        status=$?
        printf '[threadhub] ERROR: notifier rollback halted at stage: %s\n' \
            "${stage}" >&2
        return "${status}"
    }
}

existing_notifier_v010_v020_rollback() (
    set -Eeuo pipefail

    [[ "$#" -eq 0 ]] || return 2
    existing_notifier_v010_v020_rollback_step validate-capture \
        v010_v020_rollback_validate_capture || return $?
    existing_notifier_v010_v020_rollback_step validate-phase \
        v010_v020_rollback_validate_phase || return $?
    existing_notifier_v010_v020_rollback_step require-disabled \
        v010_v020_rollback_require_disabled || return $?
    existing_notifier_v010_v020_rollback_step require-quiescent-target \
        v010_v020_rollback_require_quiescent_target || return $?
    existing_notifier_v010_v020_rollback_step require-pilot-review \
        v010_v020_rollback_require_pilot_review || return $?
    existing_notifier_v010_v020_rollback_step capture-current-baseline \
        v010_v020_rollback_capture_current_baseline || return $?
    existing_notifier_v010_v020_rollback_step stop-target-mailer \
        v010_v020_rollback_stop_target_mailer || return $?
    existing_notifier_v010_v020_rollback_step recover-source \
        v010_v020_rollback_recover_source || return $?
    existing_notifier_v010_v020_rollback_step verify-source-disabled \
        v010_v020_rollback_verify_source_disabled || return $?
    existing_notifier_v010_v020_rollback_step compare-source-baseline \
        v010_v020_rollback_compare_source_baseline || return $?
    existing_notifier_v010_v020_rollback_step mark-source-recovered \
        v010_v020_rollback_mark_source_recovered || return $?
)

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    existing_notifier_v010_v020_rollback "$@"
fi
