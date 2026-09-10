#!/usr/bin/env bash

# The production-facing upgrade entry point supplies the v010_v020_tx_* hooks.
# This library owns phase persistence, interruption handling, and recovery.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! declare -F existing_notifier_v010_v020_config_state >/dev/null 2>&1; then
    # shellcheck source=existing-notifier-v010-v020-common.sh
    source "${SCRIPT_DIR}/existing-notifier-v010-v020-common.sh"
fi
if ! declare -F notifier_plugin_transaction >/dev/null 2>&1; then
    # shellcheck source=notifier-plugin-transaction.sh
    source "${SCRIPT_DIR}/notifier-plugin-transaction.sh"
fi

existing_notifier_v010_v020_tx_action_required() {
    printf '[ACTION REQUIRED] Run ./deploy/scripts/existing-notifier-v010-v020-rollback.sh; implicit transition resume is forbidden\n' >&2
    return 20
}

existing_notifier_v010_v020_tx_plugin_pair_transaction() {
    [[ "$#" -eq 10 ]] || return 2
    notifier_plugin_transaction "$@"
}

existing_notifier_v010_v020_tx_record_halt() {
    case "$1" in
        source_captured|target_release_verified|target_env_published|target_release_published|target_override_published|target_plugin_pair_published|target_mailer_started|target_queue_v2_verified|target_mattermost_recreated|target_pair_verified|after_baseline_captured|baseline_matched|disabled_verified) ;;
        *) return 2 ;;
    esac
    printf '[threadhub] ERROR: notifier transition halted after phase: %s\n' "$1" >&2
}

existing_notifier_v010_v020_tx_require_new_attempt() {
    local attempt_root="$1"
    local state_file
    local lock_root

    state_file="$(existing_notifier_v010_v020_tx_state_file "${attempt_root}")" || return 1
    lock_root="${attempt_root}/transaction.lock"
    if "${SUDO_COMMAND[@]}" test -e "${state_file}" \
        || "${SUDO_COMMAND[@]}" test -L "${state_file}" \
        || "${SUDO_COMMAND[@]}" test -e "${lock_root}" \
        || "${SUDO_COMMAND[@]}" test -L "${lock_root}"; then
        existing_notifier_v010_v020_tx_action_required
        return $?
    fi
}

existing_notifier_v010_v020_transaction() (
    set -Eeuo pipefail

    [[ "$#" -eq 1 ]] || return 2
    attempt_root="$1"
    expected_root="$(existing_notifier_v010_v020_value THN_DATA_ROOT)/migration/${EXISTING_NOTIFIER_V010_V020_ID}"
    [[ "${attempt_root}" == "${expected_root}" ]] || return 2
    transaction_started=false
    transaction_complete=false
    current_phase=''

    existing_notifier_v010_v020_tx_require_new_attempt "${attempt_root}" || return $?
    v010_v020_tx_verify_source_capture "${attempt_root}" || return $?
    if ! existing_notifier_v010_v020_tx_acquire_lock "${attempt_root}"; then
        existing_notifier_v010_v020_tx_action_required
        return $?
    fi
    existing_notifier_v010_v020_tx_state_write "${attempt_root}" source_captured || return $?
    current_phase=source_captured
    transaction_started=true

    # shellcheck disable=SC2329 # invoked by EXIT after any failed boundary or signal
    recover_transaction() {
        original_result=$?
        trap - EXIT HUP INT TERM
        if [[ "${transaction_complete}" == true || "${transaction_started}" != true ]]; then
            exit "${original_result}"
        fi
        existing_notifier_v010_v020_tx_record_halt "${current_phase}" || true
        set +e
        if v010_v020_tx_recover_source "${attempt_root}"; then
            if ! existing_notifier_v010_v020_tx_state_write \
                "${attempt_root}" source_recovered "${current_phase}"; then
                printf '[threadhub] ERROR: notifier transition failed and recovery state could not be recorded; delivery remains disabled\n' >&2
                exit 70
            fi
            printf '[threadhub] ERROR: notifier transition failed; exact v0.1.0 source state was recovered and delivery remains disabled\n' >&2
            if ((original_result == 0)); then
                exit 1
            fi
            exit "${original_result}"
        fi
        existing_notifier_v010_v020_tx_state_write \
            "${attempt_root}" recovery_failed "${current_phase}" >/dev/null 2>&1 || true
        printf '[threadhub] ERROR: notifier transition failed and automatic recovery is incomplete; delivery remains disabled\n' >&2
        exit 70
    }
    trap recover_transaction EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM

    v010_v020_tx_verify_target_release "${attempt_root}" || return $?
    existing_notifier_v010_v020_tx_state_write "${attempt_root}" target_release_verified "${current_phase}" || return $?
    current_phase=target_release_verified
    v010_v020_tx_publish_target_env "${attempt_root}" || return $?
    existing_notifier_v010_v020_tx_state_write "${attempt_root}" target_env_published "${current_phase}" || return $?
    current_phase=target_env_published
    v010_v020_tx_publish_target_release "${attempt_root}" || return $?
    existing_notifier_v010_v020_tx_state_write "${attempt_root}" target_release_published "${current_phase}" || return $?
    current_phase=target_release_published
    v010_v020_tx_publish_target_override "${attempt_root}" || return $?
    existing_notifier_v010_v020_tx_state_write "${attempt_root}" target_override_published "${current_phase}" || return $?
    current_phase=target_override_published
    v010_v020_tx_publish_target_plugin_pair "${attempt_root}" || return $?
    existing_notifier_v010_v020_tx_state_write "${attempt_root}" target_plugin_pair_published "${current_phase}" || return $?
    current_phase=target_plugin_pair_published
    v010_v020_tx_start_target_mailer "${attempt_root}" || return $?
    existing_notifier_v010_v020_tx_state_write "${attempt_root}" target_mailer_started "${current_phase}" || return $?
    current_phase=target_mailer_started
    v010_v020_tx_inspect_target_queue_v2 "${attempt_root}" || return $?
    existing_notifier_v010_v020_tx_state_write "${attempt_root}" target_queue_v2_verified "${current_phase}" || return $?
    current_phase=target_queue_v2_verified
    v010_v020_tx_recreate_target_mattermost "${attempt_root}" || return $?
    existing_notifier_v010_v020_tx_state_write "${attempt_root}" target_mattermost_recreated "${current_phase}" || return $?
    current_phase=target_mattermost_recreated
    v010_v020_tx_verify_target_pair "${attempt_root}" || return $?
    existing_notifier_v010_v020_tx_state_write "${attempt_root}" target_pair_verified "${current_phase}" || return $?
    current_phase=target_pair_verified
    v010_v020_tx_capture_after_baseline "${attempt_root}" || return $?
    existing_notifier_v010_v020_tx_state_write "${attempt_root}" after_baseline_captured "${current_phase}" || return $?
    current_phase=after_baseline_captured
    v010_v020_tx_compare_baseline "${attempt_root}" || return $?
    existing_notifier_v010_v020_tx_state_write "${attempt_root}" baseline_matched "${current_phase}" || return $?
    current_phase=baseline_matched
    v010_v020_tx_verify_disabled "${attempt_root}" || return $?
    existing_notifier_v010_v020_tx_state_write "${attempt_root}" disabled_verified "${current_phase}" || return $?
    current_phase=disabled_verified
    v010_v020_tx_mark_target_ready "${attempt_root}" || return $?
    existing_notifier_v010_v020_tx_state_write "${attempt_root}" target_ready "${current_phase}" || return $?
    current_phase=target_ready
    transaction_complete=true
)

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    die "This transaction library is invoked by the version-specific upgrade command"
fi
