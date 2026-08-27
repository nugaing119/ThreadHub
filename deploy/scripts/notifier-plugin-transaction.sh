#!/usr/bin/env bash

# This library is sourced by install-notifier-plugin.sh and its behavioral
# fixture. The caller supplies plugin_tx_* operations so the transaction can be
# exercised without a live Mattermost service or privileged host paths.

notifier_plugin_transaction() (
    set -Eeuo pipefail

    # This function already runs in a dedicated subshell. Keep transaction
    # state in that subshell's environment rather than function-local storage:
    # Bash 3.2 tears down function locals before invoking an EXIT trap.
    target_root="$1"
    stage_root="$2"
    backup_root="$3"
    failed_root="$4"
    was_running="$5"
    was_active="$6"
    transaction_started=false
    transaction_complete=false
    had_target=false
    start_attempted=false
    rollback_failures=""

    [[ "${was_running}" == true || "${was_running}" == false ]] || return 2
    [[ "${was_active}" == true || "${was_active}" == false ]] || return 2
    plugin_tx_path_exists "${stage_root}" || return 2
    if plugin_tx_path_exists "${target_root}"; then
        had_target=true
    fi

    # shellcheck disable=SC2329 # called indirectly by the EXIT rollback guard
    record_rollback_failure() {
        local label="$1"
        if [[ -n "${rollback_failures}" ]]; then
            rollback_failures+=","
        fi
        rollback_failures+="${label}"
    }

    # shellcheck disable=SC2329 # invoked by the EXIT trap below
    rollback_transaction() {
        local original_status=$?
        local replacement_present=false
        local backup_present=false
        local stage_present=false

        trap - EXIT
        if [[ "${transaction_complete}" == true || "${transaction_started}" != true ]]; then
            exit "${original_status}"
        fi

        set +e
        (plugin_tx_disable_control) || record_rollback_failure control_disable
        if (plugin_tx_path_exists "${backup_root}"); then
            backup_present=true
        fi
        if (plugin_tx_path_exists "${stage_root}"); then
            stage_present=true
        fi
        if (plugin_tx_path_exists "${target_root}"); then
            if [[ "${backup_present}" == true || "${had_target}" == false && "${stage_present}" == false ]]; then
                replacement_present=true
            fi
        fi

        if [[ "${backup_present}" == true || "${replacement_present}" == true ]]; then
            (plugin_tx_stop_service) || record_rollback_failure service_stop
        fi
        if [[ "${replacement_present}" == true ]]; then
            if (plugin_tx_path_exists "${failed_root}"); then
                record_rollback_failure failed_target_conflict
            else
                (plugin_tx_move "${target_root}" "${failed_root}") \
                    || record_rollback_failure target_quarantine
            fi
        elif [[ "${stage_present}" == true ]]; then
            if (plugin_tx_path_exists "${failed_root}"); then
                record_rollback_failure failed_stage_conflict
            else
                (plugin_tx_move "${stage_root}" "${failed_root}") \
                    || record_rollback_failure stage_quarantine
            fi
        fi
        if [[ "${backup_present}" == true ]]; then
            if (plugin_tx_path_exists "${target_root}"); then
                record_rollback_failure target_not_empty
            else
                (plugin_tx_move "${backup_root}" "${target_root}") \
                    || record_rollback_failure backup_restore
            fi
        fi

        if [[ "${was_running}" == true ]]; then
            (plugin_tx_start_service) || record_rollback_failure service_start
            if [[ "${was_active}" == true ]]; then
                (plugin_tx_enable_plugin) || record_rollback_failure plugin_enable
                (plugin_tx_verify_previous_plugin) || record_rollback_failure plugin_verify
            fi
        elif [[ "${start_attempted}" == true ]]; then
            (plugin_tx_stop_service) || record_rollback_failure service_stop
        fi

        if [[ -n "${rollback_failures}" ]]; then
            printf '[threadhub] ERROR: notifier plugin transaction failed and rollback is incomplete (%s); control remains disabled\n' \
                "${rollback_failures}" >&2
            exit 70
        fi
        printf '[threadhub] ERROR: notifier plugin transaction failed; previous target and runtime state were restored and control remains disabled\n' >&2
        if ((original_status == 0)); then
            exit 1
        fi
        exit "${original_status}"
    }
    trap rollback_transaction EXIT

    transaction_started=true
    plugin_tx_disable_control || return $?
    if [[ "${was_active}" == true ]]; then
        plugin_tx_disable_plugin || return $?
    fi
    if [[ "${was_running}" == true ]]; then
        plugin_tx_stop_service || return $?
    fi
    if [[ "${had_target}" == true ]]; then
        plugin_tx_move "${target_root}" "${backup_root}" || return $?
    fi
    plugin_tx_move "${stage_root}" "${target_root}" || return $?
    start_attempted=true
    plugin_tx_start_service || return $?
    plugin_tx_enable_plugin || return $?
    plugin_tx_verify_plugin || return $?
    transaction_complete=true
)
