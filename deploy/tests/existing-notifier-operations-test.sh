#!/usr/bin/env bash

# Tests intentionally replace sourced functions and isolate fixture state in subshells.
# shellcheck disable=SC2030,SC2031,SC2034,SC2329

set -Eeuo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_DEPLOY_DIR="$(cd "${TEST_DIR}/.." && pwd)"
CONTROL_SCRIPT="${TEST_DEPLOY_DIR}/scripts/existing-notifier-control.sh"
STATUS_SCRIPT="${TEST_DEPLOY_DIR}/scripts/existing-notifier-status.sh"
SMTP_SCRIPT="${TEST_DEPLOY_DIR}/scripts/existing-notifier-smtp-test.sh"
ROLLBACK_SCRIPT="${TEST_DEPLOY_DIR}/scripts/existing-notifier-rollback.sh"
failures=0

fail() { printf 'not ok - %s\n' "$1" >&2; failures=$((failures + 1)); }
pass() { printf 'ok - %s\n' "$1"; }
run_test() { if "$2"; then pass "$1"; else fail "$1"; fi; }

portable_hash() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'; else shasum -a 256 "$1" | awk '{print $1}'; fi
}

operations_privileged() {
    local command_name="$1"
    shift
    local filtered=()
    local path
    local uid=0
    local gid=0
    if [[ "${command_name}" == stat && "${1:-}" == -c && "${2:-}" == '%u:%g:%a' ]]; then
        path="$3"
        case "${path}" in
            */control|*/control/state.json|*/control/smtp-acceptance.json) gid=3000 ;;
            */mailer|*/mailer/queue.db) uid=65532; gid=65532 ;;
        esac
        printf '%s:%s:%s\n' "${uid}" "${gid}" "$(portable_mode "${path}")"
        return
    fi
    if [[ "${command_name}" == install ]]; then
        while (($# > 0)); do
            case "$1" in -o|-g) shift 2 ;; *) filtered+=("$1"); shift ;; esac
        done
        command install "${filtered[@]}"
        return
    fi
    if [[ "${command_name}" == mv ]]; then
        while (($# > 0)); do
            case "$1" in -T|--) shift ;; -fT) filtered+=(-f); shift ;; *) filtered+=("$1"); shift ;; esac
        done
        command mv "${filtered[@]}"
        return
    fi
    command "${command_name}" "$@"
}

portable_mode() {
    if stat -c '%a' "$1" >/dev/null 2>&1; then stat -c '%a' "$1"; else stat -f '%Lp' "$1"; fi
}

prepare_operations_fixture() {
    fixture="$(mktemp -d)"
    runtime_root="${fixture}/runtime"
    state_file="${runtime_root}/control/state.json"
    queue_file="${runtime_root}/mailer/queue.db"
    calls="${fixture}/calls"
    output="${fixture}/output"
    mkdir -p "${runtime_root}/control" "${runtime_root}/mailer"
    : > "${calls}"
    printf 'queue-must-survive\n' > "${queue_file}"
    SUDO_COMMAND=(operations_privileged)
    notifier_write_control_state "${state_file}" false false all_channels '' 0
}

test_all_channels_requires_tty_and_exact_confirmation() (
    prepare_operations_fixture
    trap 'rm -rf "${fixture}"' EXIT
    before="$(portable_hash "${state_file}")"
    set +e
    printf 'ENABLE ALL CHANNEL EMAILS\n' \
        | existing_notifier_control_dispatch "${state_file}" activate-all-channels \
            > "${output}" 2>&1
    result=$?
    set -e
    [[ "${result}" == 20 ]] || return 1
    [[ "${before}" == "$(portable_hash "${state_file}")" ]] || return 1
    jq -e '.enabled == false and .delivery_enabled == false' "${state_file}" >/dev/null
)

test_allowlist_channel_stdin_uses_the_same_activation_path() (
    fixture="$(mktemp -d)"
    trap 'rm -rf "${fixture}"' EXIT
    state_file="${fixture}/state.json"
    channel_ids='aaaaaaaaaaaaaaaaaaaaaaaaaa,bbbbbbbbbbbbbbbbbbbbbbbbbb'

    existing_notifier_control_activate() {
        printf '%s\t%s\t%s\n' "$1" "$2" "$3" > "${fixture}/activation"
    }

    printf '%s\n' "${channel_ids}" \
        | existing_notifier_control_dispatch \
            "${state_file}" activate-allowlist --channel-ids-stdin
    [[ "$(<"${fixture}/activation")" == \
        "${state_file}"$'\t'allowlist$'\t'"${channel_ids}" ]]
)

test_drain_then_disable_preserves_queue_and_target() (
    prepare_operations_fixture
    trap 'rm -rf "${fixture}"' EXIT
    channel_id=aaaaaaaaaaaaaaaaaaaaaaaaaa
    notifier_write_control_state "${state_file}" true true allowlist "${channel_id}" 1000
    queue_before="$(portable_hash "${queue_file}")"
    existing_notifier_control_dispatch "${state_file}" drain > "${output}" 2>&1 || return 1
    jq -e --arg id "${channel_id}" '
        .enabled == false and .delivery_enabled == true and
        .mode == "allowlist" and .channel_ids == [$id] and .activated_at == 1000
    ' "${state_file}" >/dev/null || return 1
    existing_notifier_control_dispatch "${state_file}" disable >> "${output}" 2>&1 || return 1
    jq -e --arg id "${channel_id}" '
        .enabled == false and .delivery_enabled == false and
        .mode == "allowlist" and .channel_ids == [$id] and .activated_at == 1000
    ' "${state_file}" >/dev/null || return 1
    [[ "${queue_before}" == "$(portable_hash "${queue_file}")" ]]
)

test_activation_failure_preserves_disabled_state() (
    prepare_operations_fixture
    trap 'rm -rf "${fixture}"' EXIT
    before="$(portable_hash "${state_file}")"
    existing_notifier_control_assert_runtime() { return 20; }
    set +e
    existing_notifier_control_activate "${state_file}" all_channels '' > "${output}" 2>&1
    result=$?
    set -e
    [[ "${result}" == 20 && "${before}" == "$(portable_hash "${state_file}")" ]]
)

test_activation_waits_for_control_reload_before_success() (
    prepare_operations_fixture
    trap 'rm -rf "${fixture}"' EXIT
    existing_notifier_control_assert_runtime() {
        printf '%s\n' '{"pending":0,"sending":0,"sent":0,"failed":0,"oldest_pending_seconds":0,"last_success_at":0,"last_error_class":"","last_smtp_code":0}'
    }
    notifier_activate_state() { printf '%s\n' activate >> "${calls}"; }
    notifier_wait_for_control_reload() { printf '%s\n' wait >> "${calls}"; }
    log() { printf '%s\n' log >> "${calls}"; }

    existing_notifier_control_activate "${state_file}" all_channels '' > "${output}" 2>&1
    [[ "$(<"${calls}")" == $'activate\nwait\nlog' ]]
)

test_runtime_gate_rejects_stale_smtp_before_plugin_check() (
    fixture="$(mktemp -d)"
    trap 'rm -rf "${fixture}"' EXIT
    calls="${fixture}/calls"
    : > "${calls}"
    existing_notifier_setup_require_current_smtp_marker() { printf 'smtp\n' >> "${calls}"; return 20; }
    existing_notifier_setup_verify_mailer() { printf 'mailer\n' >> "${calls}"; }
    existing_notifier_setup_verify_plugin() { printf 'plugin\n' >> "${calls}"; }
    set +e
    existing_notifier_control_assert_runtime > "${fixture}/output" 2>&1
    result=$?
    set -e
    [[ "${result}" == 20 && "$(<"${calls}")" == smtp ]]
)

test_runtime_gate_rejects_plugin_mismatch() (
    fixture="$(mktemp -d)"
    trap 'rm -rf "${fixture}"' EXIT
    calls="${fixture}/calls"
    : > "${calls}"
    existing_notifier_setup_require_current_smtp_marker() { printf 'smtp\n' >> "${calls}"; }
    existing_notifier_setup_verify_mailer() { printf 'mailer\n' >> "${calls}"; }
    existing_notifier_compose_combined() {
        if [[ "$1" == port ]]; then return 0; fi
        return 1
    }
    existing_notifier_setup_verify_plugin() { printf 'plugin-mismatch\n' >> "${calls}"; return 1; }
    set +e
    existing_notifier_control_assert_runtime > "${fixture}/output" 2>&1
    result=$?
    set -e
    [[ "${result}" == 1 ]] || return 1
    [[ "$(<"${calls}")" == $'smtp\nmailer\nplugin-mismatch' ]]
)

test_rollback_rejects_incomplete_capture() (
    fixture="$(mktemp -d)"
    trap 'rm -rf "${fixture}"' EXIT
    runtime_root="${fixture}/runtime"
    mkdir -p "${runtime_root}/rollback"
    printf '%s\n' '{"schema":1,"previous_pair":"absent"}' \
        > "${runtime_root}/rollback/capture.json"
    chmod 0600 "${runtime_root}/rollback/capture.json"
    existing_notifier_value() {
        case "$1" in
            THN_DATA_ROOT) printf '%s\n' "${runtime_root}" ;;
            THN_MATTERMOST_SERVICE) printf '%s\n' existing-mm ;;
            THN_MATTERMOST_PLUGINS_ROOT) printf '%s\n' "${fixture}/plugins" ;;
            THN_MATTERMOST_DATA_ROOT) printf '%s\n' "${fixture}/data" ;;
            *) return 1 ;;
        esac
    }
    SUDO_COMMAND=(operations_privileged)
    set +e
    existing_notifier_rollback_require_verified_capture > "${fixture}/output" 2>&1
    result=$?
    set -e
    [[ "${result}" == 20 ]]
)

test_control_path_validation_rejects_queue_symlink() (
    prepare_operations_fixture
    trap 'rm -rf "${fixture}"' EXIT
    chmod 0750 "${runtime_root}" "${runtime_root}/control"
    chmod 0700 "${runtime_root}/mailer"
    chmod 0640 "${state_file}"
    chmod 0600 "${queue_file}"
    existing_notifier_value() {
        [[ "$1" == THN_DATA_ROOT ]] || return 1
        printf '%s\n' "${runtime_root}"
    }
    existing_notifier_validate_control_path "${state_file}" || return 1
    rm -f "${queue_file}"
    printf 'outside\n' > "${fixture}/outside"
    ln -s "${fixture}/outside" "${queue_file}"
    set +e
    (existing_notifier_validate_control_path "${state_file}") > "${output}" 2>&1
    result=$?
    set -e
    [[ "${result}" == 1 ]]
)

rollback_status_json() {
    printf '%s\n' "${ROLLBACK_STATUS_JSON}"
}

test_rollback_queue_and_failed_disposition_gates() (
    fixture="$(mktemp -d)"
    trap 'rm -rf "${fixture}"' EXIT
    calls="${fixture}/calls"
    : > "${calls}"
    existing_notifier_compose_combined() {
        printf '%s\n' "$*" >> "${calls}"
        if [[ "$*" == *'status --json' ]]; then rollback_status_json; fi
    }

    ROLLBACK_STATUS_JSON='{"pending":1,"sending":0,"sent":0,"failed":0,"oldest_pending_seconds":1,"last_success_at":0,"last_error_class":"","last_smtp_code":0}'
    set +e
    existing_notifier_rollback_require_quiescent_queue > "${fixture}/pending-output" 2>&1
    pending_result=$?
    set -e
    [[ "${pending_result}" == 20 ]] || return 1

    ROLLBACK_STATUS_JSON='{"pending":0,"sending":0,"sent":0,"failed":1,"oldest_pending_seconds":0,"last_success_at":0,"last_error_class":"permanent","last_smtp_code":550}'
    EXISTING_NOTIFIER_ROLLBACK_FAILED_DISPOSITION=''
    set +e
    existing_notifier_rollback_require_quiescent_queue > "${fixture}/failed-output" 2>&1
    failed_result=$?
    set -e
    [[ "${failed_result}" == 20 ]] || return 1

    status_calls=0
    existing_notifier_compose_combined() {
        printf '%s\n' "$*" >> "${calls}"
        if [[ "$*" == *'status --json' ]]; then
            status_calls=$((status_calls + 1))
            if ((status_calls == 1)); then
                printf '%s\n' '{"pending":0,"sending":0,"sent":0,"failed":1,"oldest_pending_seconds":0,"last_success_at":0,"last_error_class":"permanent","last_smtp_code":550}'
            else
                printf '%s\n' '{"pending":0,"sending":0,"sent":0,"failed":0,"oldest_pending_seconds":0,"last_success_at":0,"last_error_class":"","last_smtp_code":0}'
            fi
        fi
    }
    EXISTING_NOTIFIER_ROLLBACK_FAILED_DISPOSITION=cancel
    existing_notifier_rollback_require_quiescent_queue > "${fixture}/cancel-output" 2>&1 \
        || return 1
    grep -F 'cancel-failed' "${calls}" >/dev/null
)

test_status_is_pii_free() (
    prepare_operations_fixture
    trap 'rm -rf "${fixture}"' EXIT
    private_channel=zzzzzzzzzzzzzzzzzzzzzzzzzz
    private_secret='private-operation-secret'
    notifier_write_control_state "${state_file}" true true allowlist "${private_channel}" 1000
    existing_notifier_setup_require_current_smtp_marker() { return 0; }
    existing_notifier_setup_verify_plugin() { return 0; }
    existing_notifier_compose_combined() {
        printf '%s\n' '{"pending":0,"sending":0,"sent":2,"failed":0,"oldest_pending_seconds":0,"last_success_at":1000,"last_error_class":"","last_smtp_code":250}'
    }
    THN_HMAC_SECRET="${private_secret}"
    existing_notifier_status_dispatch "${state_file}" > "${output}" 2>&1 || return 1
    grep -Fx 'allowlist_count=1' "${output}" >/dev/null || return 1
    ! grep -F "${private_channel}" "${output}" >/dev/null || return 1
    ! grep -F "${private_secret}" "${output}" >/dev/null
)

test_rollback_preserves_queue_and_uses_base_compose() (
    prepare_operations_fixture
    trap 'rm -rf "${fixture}"' EXIT
    queue_before="$(portable_hash "${queue_file}")"
    existing_notifier_rollback_validate() { printf 'validate\n' >> "${calls}"; }
    existing_notifier_rollback_require_disabled() { printf 'disabled\n' >> "${calls}"; }
    existing_notifier_rollback_require_quiescent_queue() { printf 'quiescent\n' >> "${calls}"; }
    existing_notifier_rollback_require_verified_capture() { printf 'capture\n' >> "${calls}"; }
    existing_notifier_rollback_stop_mailer() { printf 'combined stop threadhub-mailer\n' >> "${calls}"; }
    existing_notifier_rollback_restore_pair() { printf 'restore-pair\n' >> "${calls}"; }
    existing_notifier_rollback_recreate_base() { printf 'base up -d --no-deps --wait existing-mm\n' >> "${calls}"; }
    existing_notifier_rollback_verify_base() { printf 'verify-base\n' >> "${calls}"; }

    existing_notifier_rollback_dispatch > "${output}" 2>&1 || return 1
    [[ "${queue_before}" == "$(portable_hash "${queue_file}")" ]] || return 1
    [[ "$(<"${calls}")" == $'validate\ndisabled\nquiescent\ncapture\ncombined stop threadhub-mailer\nrestore-pair\nbase up -d --no-deps --wait existing-mm\nverify-base' ]]
)

test_rollback_failure_restores_combined_service_disabled() (
    prepare_operations_fixture
    trap 'rm -rf "${fixture}"' EXIT
    existing_notifier_rollback_validate() { printf 'validate\n' >> "${calls}"; }
    existing_notifier_rollback_require_disabled() { printf 'disabled\n' >> "${calls}"; }
    existing_notifier_rollback_require_quiescent_queue() { printf 'quiescent\n' >> "${calls}"; }
    existing_notifier_rollback_require_verified_capture() { printf 'capture\n' >> "${calls}"; }
    existing_notifier_rollback_stop_mailer() { printf 'stop-mailer\n' >> "${calls}"; }
    existing_notifier_rollback_restore_pair() { printf 'remove-pair\n' >> "${calls}"; }
    existing_notifier_rollback_recreate_base() { printf 'base-failed\n' >> "${calls}"; return 1; }
    existing_notifier_rollback_verify_base() { printf 'unexpected-verify\n' >> "${calls}"; }
    existing_notifier_rollback_recover_combined() { printf 'recover-combined-disabled\n' >> "${calls}"; }

    set +e
    existing_notifier_rollback_dispatch > "${output}" 2>&1
    result=$?
    set -e
    [[ "${result}" == 1 ]] || return 1
    [[ "$(<"${calls}")" == $'validate\ndisabled\nquiescent\ncapture\nstop-mailer\nremove-pair\nbase-failed\nrecover-combined-disabled' ]]
)

test_noninteractive_smtp_prints_exact_handoff() (
    fixture="$(mktemp -d)"
    trap 'rm -rf "${fixture}"' EXIT
    set +e
    (existing_notifier_smtp_test_entry) </dev/null > "${fixture}/output" 2>&1
    result=$?
    set -e
    [[ "${result}" == 20 ]] || return 1
    grep -Fx '[ACTION REQUIRED] Run ./deploy/scripts/existing-notifier-smtp-test.sh in an interactive terminal.' \
        "${fixture}/output" >/dev/null || return 1
    grep -Fx 'Then rerun: ./deploy/scripts/existing-notifier-setup.sh --resume' \
        "${fixture}/output" >/dev/null
)

test_noninteractive_smtp_recipient_stdin_uses_the_same_acceptance_path() (
    fixture="$(mktemp -d)"
    trap 'rm -rf "${fixture}"' EXIT
    recipient='acceptance@threadhub.invalid'
    fingerprint='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
    marker_file="${fixture}/runtime/control/smtp-acceptance.json"
    mkdir -p "${fixture}/runtime/control"
    : > "${fixture}/runtime/control/state.json"

    existing_notifier_setup_validate_config() { :; }
    existing_notifier_init_compose() { :; }
    existing_notifier_value() {
        [[ "$1" == THN_DATA_ROOT ]] || return 91
        printf '%s\n' "${fixture}/runtime"
    }
    existing_notifier_validate_control_path() { :; }
    existing_notifier_smtp_acceptance_fingerprint() {
        [[ "$1" == "${recipient}" ]] || return 92
        printf '%s\n' 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
    }
    notifier_write_smtp_marker() {
        [[ "$1" == "${marker_file}" && "$2" == "${fingerprint}" && "$3" =~ ^[0-9]+$ ]]
    }
    log() { :; }
    warn() { :; }

    printf '%s\n' "${recipient}" \
        | existing_notifier_smtp_test_entry --recipient-stdin \
            > "${fixture}/output" 2> "${fixture}/error"
    [[ ! -s "${fixture}/output" && ! -s "${fixture}/error" ]]
)

test_smtp_acceptance_executes_in_running_mailer() (
    fixture="$(mktemp -d)"
    trap 'rm -rf "${fixture}"' EXIT
    trace_file="${fixture}/compose.trace"
    recipient='acceptance@threadhub.invalid'
    fingerprint='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'

    existing_notifier_compose_combined() {
        printf '%s\n' "$*" > "${trace_file}"
        IFS= read -r actual_recipient
        [[ "${actual_recipient}" == "${recipient}" ]] || return 91
        printf '{"config_fingerprint":"%s"}\n' "${fingerprint}"
    }

    actual="$(printf '%s\n' "${recipient}" | existing_notifier_run_smtp_acceptance)" || return 1
    [[ "${actual}" == "{\"config_fingerprint\":\"${fingerprint}\"}" ]] || return 1
    [[ "$(<"${trace_file}")" == \
        'exec -T threadhub-mailer /threadhub-mailer smtp-test --recipient-stdin' ]]
)

test_smtp_acceptance_reports_only_safe_mailer_failure() (
    fixture="$(mktemp -d)"
    trap 'rm -rf "${fixture}"' EXIT
    recipient='private-recipient@threadhub.invalid'

    existing_notifier_run_smtp_acceptance() {
        IFS= read -r actual_recipient
        [[ "${actual_recipient}" == "${recipient}" ]] || return 91
        printf '%s\n' 'private upstream diagnostic' >&2
        printf '%s\n' 'threadhub-mailer: command failed error_class=temporary smtp_code=451' >&2
        return 1
    }

    set +e
    existing_notifier_smtp_acceptance_fingerprint "${recipient}" \
        > "${fixture}/output" 2> "${fixture}/error"
    result=$?
    set -e
    [[ "${result}" == 1 ]] || return 1
    [[ ! -s "${fixture}/output" ]] || return 1
    [[ "$(<"${fixture}/error")" == \
        'threadhub-notifier: smtp_acceptance_phase=mailer error_class=temporary smtp_code=451' ]] \
        || return 1
    ! grep -F "${recipient}" "${fixture}/error" >/dev/null
)

test_smtp_acceptance_reports_unavailable_without_leaking_diagnostics() (
    fixture="$(mktemp -d)"
    trap 'rm -rf "${fixture}"' EXIT
    recipient='private-recipient@threadhub.invalid'

    existing_notifier_run_smtp_acceptance() {
        IFS= read -r actual_recipient
        [[ "${actual_recipient}" == "${recipient}" ]] || return 91
        printf '%s\n' 'private upstream diagnostic' >&2
        return 1
    }

    set +e
    existing_notifier_smtp_acceptance_fingerprint "${recipient}" \
        > "${fixture}/output" 2> "${fixture}/error"
    result=$?
    set -e
    [[ "${result}" == 1 ]] || return 1
    [[ "$(<"${fixture}/error")" == \
        'threadhub-notifier: smtp_acceptance_phase=mailer error_class=unavailable smtp_code=0' ]] \
        || return 1
    ! grep -F 'private upstream diagnostic' "${fixture}/error" >/dev/null
)

test_operation_scripts_exist() {
    [[ -f "${CONTROL_SCRIPT}" && -f "${STATUS_SCRIPT}" \
        && -f "${SMTP_SCRIPT}" && -f "${ROLLBACK_SCRIPT}" ]]
}

run_test 'existing notifier operation scripts exist' test_operation_scripts_exist
if [[ -f "${CONTROL_SCRIPT}" && -f "${SMTP_SCRIPT}" && -f "${ROLLBACK_SCRIPT}" ]]; then
    # shellcheck source=/dev/null
    source "${CONTROL_SCRIPT}"
    # shellcheck source=/dev/null
    source "${SMTP_SCRIPT}"
    # shellcheck source=/dev/null
    source "${ROLLBACK_SCRIPT}"
    # shellcheck source=/dev/null
    source "${STATUS_SCRIPT}"
    run_test 'all-channels activation requires a real TTY confirmation' test_all_channels_requires_tty_and_exact_confirmation
    run_test 'allowlist channel stdin uses the same activation path' test_allowlist_channel_stdin_uses_the_same_activation_path
    run_test 'drain then disable preserves queue and the configured target' test_drain_then_disable_preserves_queue_and_target
    run_test 'activation failure preserves the disabled control state' test_activation_failure_preserves_disabled_state
    run_test 'activation waits for plugin control reload before success' test_activation_waits_for_control_reload_before_success
    run_test 'stale SMTP acceptance blocks activation before plugin checks' test_runtime_gate_rejects_stale_smtp_before_plugin_check
    run_test 'plugin mismatch blocks activation after SMTP and Mailer checks' test_runtime_gate_rejects_plugin_mismatch
    run_test 'rollback rejects an incomplete pre-adoption capture' test_rollback_rejects_incomplete_capture
    run_test 'operation path validation rejects a symbolic-link queue' test_control_path_validation_rejects_queue_symlink
    run_test 'rollback gates pending work and requires failed-delivery disposition' test_rollback_queue_and_failed_disposition_gates
    run_test 'existing notifier status omits channel IDs and protected values' test_status_is_pii_free
    run_test 'rollback preserves queue and recreates only the base Mattermost service' test_rollback_preserves_queue_and_uses_base_compose
    run_test 'rollback failure restores the reviewed combined service disabled' test_rollback_failure_restores_combined_service_disabled
    run_test 'noninteractive SMTP test prints the exact secure handoff' test_noninteractive_smtp_prints_exact_handoff
    run_test 'SMTP recipient stdin uses the same acceptance path' test_noninteractive_smtp_recipient_stdin_uses_the_same_acceptance_path
    run_test 'SMTP acceptance executes in the running Mailer container' test_smtp_acceptance_executes_in_running_mailer
    run_test 'SMTP acceptance reports only a safe Mailer failure class' test_smtp_acceptance_reports_only_safe_mailer_failure
    run_test 'SMTP acceptance hides unavailable upstream diagnostics' test_smtp_acceptance_reports_unavailable_without_leaking_diagnostics
fi

((failures == 0))
