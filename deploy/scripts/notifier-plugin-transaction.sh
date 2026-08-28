#!/usr/bin/env bash

# This library is sourced by install-notifier-plugin.sh and its behavioral
# fixture. The caller supplies plugin_tx_* operations so the transaction can be
# exercised without a live Mattermost service or privileged host paths.

notifier_plugin_transaction() (
    set -Eeuo pipefail

    [[ "$#" -eq 10 ]] || return 2

    # This function already runs in a dedicated subshell. Keep transaction
    # state in that subshell's environment rather than function-local storage:
    # Bash 3.2 tears down function locals before invoking an EXIT trap.
    target_root="$1"
    stage_root="$2"
    backup_root="$3"
    failed_root="$4"
    bundle_target="$5"
    bundle_stage="$6"
    bundle_backup="$7"
    bundle_failed="$8"
    was_running="$9"
    was_active="${10}"
    transaction_started=false
    transaction_complete=false
    had_target=false
    had_bundle=false
    target_backup_done=false
    bundle_backup_done=false
    target_published=false
    bundle_published=false
    start_attempted=false
    rollback_failures=""
    object_restore_complete=true
    object_transaction_started=false
    rollback_service_started=false
    rollback_recovery_failed=false

    [[ "${was_running}" == true || "${was_running}" == false ]] || return 2
    [[ "${was_active}" == true || "${was_active}" == false ]] || return 2
    plugin_tx_path_exists "${stage_root}" || return 2
    plugin_tx_path_exists "${bundle_stage}" || return 2
    if plugin_tx_path_exists "${target_root}"; then
        had_target=true
    fi
    if plugin_tx_path_exists "${bundle_target}"; then
        had_bundle=true
    fi
    [[ "${had_target}" == "${had_bundle}" ]] || return 2
    # The caller's production-specific preflight verifies either the complete
    # prior pair or the complete fresh-install absence before control/service
    # state is changed.
    plugin_tx_prepare_targets || return $?

    # shellcheck disable=SC2329 # called indirectly by the EXIT rollback guard
    record_rollback_failure() {
        local label="$1"
        if [[ -n "${rollback_failures}" ]]; then
            rollback_failures+=","
        fi
        rollback_failures+="${label}"
    }

    # shellcheck disable=SC2329 # called indirectly by the EXIT rollback guard
    record_object_rollback_failure() {
        object_restore_complete=false
        record_rollback_failure "$1"
    }

    # shellcheck disable=SC2329 # invoked by the EXIT trap below
    rollback_transaction() {
        local original_status=$?
        local target_present=false
        local stage_present=false
        local bundle_target_present=false
        local bundle_stage_present=false

        trap - EXIT
        if [[ "${transaction_complete}" == true || "${transaction_started}" != true ]]; then
            exit "${original_status}"
        fi

        set +e
        (plugin_tx_disable_control) || record_rollback_failure control_disable
        if (plugin_tx_path_exists "${backup_root}"); then
            target_backup_done=true
        fi
        if (plugin_tx_path_exists "${bundle_backup}"); then
            bundle_backup_done=true
        fi
        if (plugin_tx_path_exists "${target_root}"); then
            target_present=true
        fi
        if (plugin_tx_path_exists "${stage_root}"); then
            stage_present=true
        elif [[ "${target_present}" == true && ("${target_backup_done}" == true || "${had_target}" == false) ]]; then
            target_published=true
        fi
        if (plugin_tx_path_exists "${bundle_target}"); then
            bundle_target_present=true
        fi
        if (plugin_tx_path_exists "${bundle_stage}"); then
            bundle_stage_present=true
        elif [[ "${bundle_target_present}" == true && ("${bundle_backup_done}" == true || "${had_bundle}" == false) ]]; then
            bundle_published=true
        fi
        if [[ "${object_transaction_started}" == true \
            && "${had_target}" == false \
            && "${stage_present}" == true \
            && "${target_present}" == true ]]; then
            record_object_rollback_failure target_publish_conflict
        fi
        if [[ "${object_transaction_started}" == true \
            && "${had_bundle}" == false \
            && "${bundle_stage_present}" == true \
            && "${bundle_target_present}" == true ]]; then
            record_object_rollback_failure bundle_publish_conflict
        fi

        if [[ "${start_attempted}" == true ]]; then
            (plugin_tx_stop_service) || record_rollback_failure service_stop
        fi
        if [[ "${target_published}" == true ]]; then
            if (plugin_tx_path_exists "${failed_root}"); then
                record_object_rollback_failure failed_target_conflict
            elif ! (plugin_tx_path_exists "${target_root}"); then
                record_object_rollback_failure target_missing
            else
                (plugin_tx_move "${target_root}" "${failed_root}") \
                    || record_object_rollback_failure target_quarantine
            fi
        elif [[ "${stage_present}" == true ]]; then
            if (plugin_tx_path_exists "${failed_root}"); then
                record_object_rollback_failure failed_stage_conflict
            else
                (plugin_tx_move "${stage_root}" "${failed_root}") \
                    || record_object_rollback_failure stage_quarantine
            fi
        fi
        if [[ "${bundle_published}" == true ]]; then
            if (plugin_tx_path_exists "${bundle_failed}"); then
                record_object_rollback_failure failed_bundle_conflict
            elif ! (plugin_tx_path_exists "${bundle_target}"); then
                record_object_rollback_failure bundle_missing
            else
                (plugin_tx_move "${bundle_target}" "${bundle_failed}") \
                    || record_object_rollback_failure bundle_quarantine
            fi
        elif [[ "${bundle_stage_present}" == true ]]; then
            if (plugin_tx_path_exists "${bundle_failed}"); then
                record_object_rollback_failure failed_bundle_stage_conflict
            else
                (plugin_tx_move "${bundle_stage}" "${bundle_failed}") \
                    || record_object_rollback_failure bundle_stage_quarantine
            fi
        fi
        if [[ "${target_backup_done}" == true ]]; then
            if (plugin_tx_path_exists "${target_root}"); then
                record_object_rollback_failure target_not_empty
            else
                (plugin_tx_move "${backup_root}" "${target_root}") \
                    || record_object_rollback_failure backup_restore
            fi
        fi
        if [[ "${bundle_backup_done}" == true ]]; then
            if (plugin_tx_path_exists "${bundle_target}"); then
                record_object_rollback_failure bundle_target_not_empty
            else
                (plugin_tx_move "${bundle_backup}" "${bundle_target}") \
                    || record_object_rollback_failure bundle_backup_restore
            fi
        fi

        (plugin_tx_verify_previous_objects) \
            || record_object_rollback_failure object_verify

        if [[ "${was_running}" == true && "${object_restore_complete}" == true ]]; then
            if (plugin_tx_start_service); then
                rollback_service_started=true
            else
                rollback_recovery_failed=true
                record_rollback_failure service_start
            fi
            if [[ "${rollback_service_started}" == true ]]; then
                if [[ "${was_active}" == true ]] \
                    && ! (plugin_tx_enable_previous_plugin); then
                    rollback_recovery_failed=true
                    record_rollback_failure plugin_enable
                fi
                if ! (plugin_tx_verify_previous_plugin); then
                    rollback_recovery_failed=true
                    record_rollback_failure plugin_verify
                fi
                if ! (plugin_tx_verify_previous_objects); then
                    rollback_recovery_failed=true
                    record_object_rollback_failure object_post_start_verify
                fi
            fi
        fi
        if [[ "${rollback_recovery_failed}" == true \
            && "${rollback_service_started}" == true ]]; then
            (plugin_tx_stop_service) \
                || record_rollback_failure recovery_service_stop
        fi

        if [[ -n "${rollback_failures}" ]]; then
            printf '[threadhub] ERROR: notifier plugin transaction failed and rollback is incomplete (%s); control remains disabled\n' \
                "${rollback_failures}" >&2
            exit 70
        fi
        printf '[threadhub] ERROR: notifier plugin transaction failed; previous plugin objects and runtime state were restored and control remains disabled\n' >&2
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
    plugin_tx_prepare_targets || return $?
    current_target_present=false
    current_bundle_present=false
    if plugin_tx_path_exists "${target_root}"; then
        current_target_present=true
    fi
    if plugin_tx_path_exists "${bundle_target}"; then
        current_bundle_present=true
    fi
    [[ "${current_target_present}" == "${current_bundle_present}" \
        && "${current_target_present}" == "${had_target}" ]] || return 1
    object_transaction_started=true
    if [[ "${had_target}" == true && "${target_backup_done}" == false ]]; then
        plugin_tx_move "${target_root}" "${backup_root}" || return $?
        target_backup_done=true
    fi
    if [[ "${had_bundle}" == true ]]; then
        plugin_tx_move "${bundle_target}" "${bundle_backup}" || return $?
        bundle_backup_done=true
    fi
    plugin_tx_move "${stage_root}" "${target_root}" || return $?
    target_published=true
    plugin_tx_move "${bundle_stage}" "${bundle_target}" || return $?
    bundle_published=true
    start_attempted=true
    plugin_tx_start_service || return $?
    plugin_tx_enable_plugin || return $?
    plugin_tx_verify_plugin || return $?
    transaction_complete=true
)
