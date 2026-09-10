#!/usr/bin/env bash

# Transaction hooks are invoked indirectly by the orchestration under test.
# shellcheck disable=SC2030,SC2031,SC2034,SC2329

set -Eeuo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_DEPLOY_DIR="$(cd "${TEST_DIR}/.." && pwd)"
TRANSACTION_SCRIPT="${TEST_DEPLOY_DIR}/scripts/existing-notifier-v010-v020-transaction.sh"
failures=0

fail() { printf 'not ok - %s\n' "$1" >&2; failures=$((failures + 1)); }
pass() { printf 'ok - %s\n' "$1"; }
run_test() { if "$2"; then pass "$1"; else fail "$1"; fi; }

file_mode() {
    if stat -c '%a' "$1" >/dev/null 2>&1; then
        stat -c '%a' "$1"
    else
        stat -f '%Lp' "$1"
    fi
}

test_transaction_script_exists() { [[ -x "${TRANSACTION_SCRIPT}" ]]; }

prepare_transaction_fixture() {
    fixture="$(mktemp -d)"
    notifier_root="${fixture}/notifier"
    attempt_root="${notifier_root}/migration/existing-notifier-v010-v020"
    calls="${fixture}/calls"
    output="${fixture}/output"
    source_state="${fixture}/source-state"
    live_state="${fixture}/live-state"
    quarantine="${fixture}/quarantine"
    target_stage="${fixture}/target-stage"
    control_file="${fixture}/control.json"
    mkdir -p "${attempt_root}" "${source_state}" "${live_state}" "${target_stage}"
    chmod 0700 "${attempt_root}" "${source_state}" "${live_state}" "${target_stage}"
    for component in env release override plugin queue; do
        printf 'source-%s\n' "${component}" > "${source_state}/${component}"
        install -m 0600 "${source_state}/${component}" "${live_state}/${component}"
    done
    printf '%s\n' fixture-target-release > "${target_stage}/release"
    printf '%s\n' fixture-source-image-available > "${source_state}/mailer-image-id"
    printf '%s\n' '{"enabled":false,"delivery_enabled":false}' > "${control_file}"
    : > "${calls}"
    fail_step=''
    fail_result=42
    recovery_fails=false
    signal_step=''
}

run_transaction_fixture() {
    # shellcheck source=../scripts/existing-notifier-v010-v020-transaction.sh
    declare -F existing_notifier_v010_v020_transaction >/dev/null || source "${TRANSACTION_SCRIPT}"
    SUDO_COMMAND=(env)
    existing_notifier_v010_v020_value() {
        [[ "$1" == THN_DATA_ROOT ]] || return 1
        printf '%s\n' "${notifier_root}"
    }
    existing_notifier_v010_v020_tx_install_private() { install -m 0600 "$1" "$2"; }
    existing_notifier_v010_v020_tx_create_lock() { mkdir "$1" && chmod 0700 "$1"; }
    existing_notifier_v010_v020_capture_identity() {
        case "$1" in
            */transaction.lock) printf '%s\n' 0:0:700 ;;
            *) printf '%s\n' 0:0:600 ;;
        esac
    }
    tx_hook() {
        local step="$1"
        printf '%s\n' "${step}" >> "${calls}"
        case "${step}" in
            publish-target-env) printf '%s\n' target-env > "${live_state}/env" ;;
            publish-target-release) printf '%s\n' target-release > "${live_state}/release" ;;
            publish-target-override) printf '%s\n' target-override > "${live_state}/override" ;;
            publish-target-plugin-pair) printf '%s\n' target-plugin > "${live_state}/plugin" ;;
            start-target-mailer) printf '%s\n' target-schema-v2-queue > "${live_state}/queue" ;;
        esac
        if [[ "${signal_step}" == "${step}" ]]; then
            sh -c 'kill -TERM "$PPID"'
        fi
        [[ "${fail_step}" != "${step}" ]] || return "${fail_result}"
    }
    v010_v020_tx_verify_source_capture() { tx_hook verify-source-capture; }
    v010_v020_tx_verify_target_release() { tx_hook verify-target-release; }
    v010_v020_tx_publish_target_env() { tx_hook publish-target-env; }
    v010_v020_tx_publish_target_release() { tx_hook publish-target-release; }
    v010_v020_tx_publish_target_override() { tx_hook publish-target-override; }
    v010_v020_tx_publish_target_plugin_pair() { tx_hook publish-target-plugin-pair; }
    v010_v020_tx_start_target_mailer() { tx_hook start-target-mailer; }
    v010_v020_tx_inspect_target_queue_v2() { tx_hook inspect-target-queue-v2; }
    v010_v020_tx_recreate_target_mattermost() { tx_hook recreate-target-mattermost; }
    v010_v020_tx_verify_target_pair() { tx_hook verify-target-pair; }
    v010_v020_tx_capture_after_baseline() { tx_hook capture-after-baseline; }
    v010_v020_tx_compare_baseline() { tx_hook compare-baseline; }
    v010_v020_tx_verify_disabled() { tx_hook verify-disabled; }
    v010_v020_tx_mark_target_ready() { tx_hook mark-target-ready; }
    v010_v020_tx_recover_source() {
        printf '%s\n' recover-source >> "${calls}"
        [[ "${recovery_fails}" == false ]] || return 1
        mkdir -m 0700 "${quarantine}"
        for component in env release override plugin queue; do
            if ! cmp -s "${source_state}/${component}" "${live_state}/${component}"; then
                install -m 0600 "${live_state}/${component}" "${quarantine}/${component}"
                install -m 0600 "${source_state}/${component}" "${live_state}/${component}"
            fi
        done
        jq -e '.enabled == false and .delivery_enabled == false' "${control_file}" >/dev/null
    }
    existing_notifier_v010_v020_transaction "${attempt_root}"
}

test_transaction_uses_exact_phase_order() (
    prepare_transaction_fixture
    trap 'rm -rf -- "${fixture}"' EXIT
    if ! run_transaction_fixture > "${output}" 2>&1; then
        sed -e 's/fixture-private-secret/[redacted]/g' \
            -e 's/aaaaaaaaaaaaaaaaaaaaaaaaaa/[redacted]/g' "${output}" >&2
        return 1
    fi
    expected=$'verify-source-capture\nverify-target-release\npublish-target-env\npublish-target-release\npublish-target-override\npublish-target-plugin-pair\nstart-target-mailer\ninspect-target-queue-v2\nrecreate-target-mattermost\nverify-target-pair\ncapture-after-baseline\ncompare-baseline\nverify-disabled\nmark-target-ready'
    [[ "$(<"${calls}")" == "${expected}" ]] || return 1
    [[ "$(existing_notifier_v010_v020_tx_state_current "${attempt_root}")" == target_ready ]]
)

test_transaction_state_is_strict_and_no_clobber() (
    prepare_transaction_fixture
    trap 'rm -rf -- "${fixture}"' EXIT
    # shellcheck source=../scripts/existing-notifier-v010-v020-transaction.sh
    source "${TRANSACTION_SCRIPT}"
    SUDO_COMMAND=(env)
    existing_notifier_v010_v020_tx_install_private() { install -m 0600 "$1" "$2"; }
    existing_notifier_v010_v020_capture_identity() { printf '%s\n' 0:0:600; }

    existing_notifier_v010_v020_tx_state_write "${attempt_root}" source_captured || return 1
    state_file="$(existing_notifier_v010_v020_tx_state_file "${attempt_root}")"
    [[ "$(file_mode "${state_file}")" == 600 ]] || return 1
    jq -e '
      type == "object" and
      (keys == ["delivery_enabled","phase","schema","source_version","target_version","transition"]) and
      .schema == 1 and .transition == "existing-notifier-v010-v020" and
      .phase == "source_captured" and .source_version == "0.1.0" and
      .target_version == "0.2.0" and .delivery_enabled == false
    ' "${state_file}" >/dev/null || return 1
    ! existing_notifier_v010_v020_tx_state_write "${attempt_root}" target_release_verified wrong_phase || return 1
    existing_notifier_v010_v020_tx_state_write "${attempt_root}" target_release_verified source_captured || return 1
    [[ "$(existing_notifier_v010_v020_tx_state_current "${attempt_root}")" == target_release_verified ]] || return 1
    existing_notifier_v010_v020_capture_identity() { printf '%s\n' 0:0:644; }
    ! existing_notifier_v010_v020_tx_state_current "${attempt_root}" >/dev/null || return 1
    existing_notifier_v010_v020_capture_identity() { printf '%s\n' 0:0:600; }
    jq '.unexpected=true' "${state_file}" > "${state_file}.bad"
    mv "${state_file}.bad" "${state_file}"
    ! existing_notifier_v010_v020_tx_state_current "${attempt_root}" >/dev/null
)

test_plugin_pair_boundary_uses_reviewed_transaction() (
    # shellcheck source=../scripts/existing-notifier-v010-v020-transaction.sh
    source "${TRANSACTION_SCRIPT}"
    captured=''
    notifier_plugin_transaction() { captured="$*"; }
    existing_notifier_v010_v020_tx_plugin_pair_transaction \
        one two three four five six seven eight true false || return 1
    [[ "${captured}" == 'one two three four five six seven eight true false' ]]
)

test_every_boundary_recovers_or_fails_hard() (
    steps=(
        verify-source-capture verify-target-release publish-target-env
        publish-target-release publish-target-override publish-target-plugin-pair
        start-target-mailer inspect-target-queue-v2 recreate-target-mattermost
        verify-target-pair capture-after-baseline compare-baseline verify-disabled
        mark-target-ready
    )
    for failed in "${steps[@]}"; do
        prepare_transaction_fixture
        fail_step="${failed}"
        set +e
        run_transaction_fixture > "${output}" 2>&1
        result=$?
        set -e
        [[ "${result}" == "${fail_result}" ]] || return 1
        jq -e '.enabled == false and .delivery_enabled == false' "${control_file}" >/dev/null || return 1
        [[ -f "${target_stage}/release" ]] || return 1
        for component in env release override plugin queue; do
            cmp -s "${source_state}/${component}" "${live_state}/${component}" || return 1
        done
        [[ -f "${source_state}/mailer-image-id" ]] || return 1
        if [[ "${failed}" == verify-source-capture ]]; then
            [[ ! -e "${attempt_root}/transaction-state.json" ]] || return 1
            ! grep -Fx recover-source "${calls}" >/dev/null || return 1
        else
            case "${failed}" in
                verify-target-release) expected_halt_phase=source_captured ;;
                publish-target-env) expected_halt_phase=target_release_verified ;;
                publish-target-release) expected_halt_phase=target_env_published ;;
                publish-target-override) expected_halt_phase=target_release_published ;;
                publish-target-plugin-pair) expected_halt_phase=target_override_published ;;
                start-target-mailer) expected_halt_phase=target_plugin_pair_published ;;
                inspect-target-queue-v2) expected_halt_phase=target_mailer_started ;;
                recreate-target-mattermost) expected_halt_phase=target_queue_v2_verified ;;
                verify-target-pair) expected_halt_phase=target_mattermost_recreated ;;
                capture-after-baseline) expected_halt_phase=target_pair_verified ;;
                compare-baseline) expected_halt_phase=after_baseline_captured ;;
                verify-disabled) expected_halt_phase=baseline_matched ;;
                mark-target-ready) expected_halt_phase=disabled_verified ;;
                *) return 1 ;;
            esac
            grep -Fx "[threadhub] ERROR: notifier transition halted after phase: ${expected_halt_phase}" \
                "${output}" >/dev/null || return 1
            [[ "$(existing_notifier_v010_v020_tx_state_current "${attempt_root}")" == source_recovered ]] || return 1
            [[ "$(tail -n 1 "${calls}")" == recover-source ]] || return 1
            if grep -Fx publish-target-env "${calls}" >/dev/null; then
                [[ -f "${quarantine}/env" ]] || return 1
            fi
        fi
        ! grep -F -e fixture-private-secret -e aaaaaaaaaaaaaaaaaaaaaaaaaa "${output}" >/dev/null || return 1
        rm -rf -- "${fixture}"
    done

    prepare_transaction_fixture
    fail_step=publish-target-plugin-pair
    recovery_fails=true
    set +e
    run_transaction_fixture > "${output}" 2>&1
    result=$?
    set -e
    [[ "${result}" == 70 ]] || return 1
    [[ "$(existing_notifier_v010_v020_tx_state_current "${attempt_root}")" == recovery_failed ]]
)

test_signal_recovers_and_stale_state_never_resumes() (
    for signalled in publish-target-env publish-target-release start-target-mailer publish-target-plugin-pair; do
        prepare_transaction_fixture
        signal_step="${signalled}"
        set +e
        run_transaction_fixture > "${output}" 2>&1
        result=$?
        set -e
        [[ "${result}" == 143 ]] || return 1
        [[ "$(existing_notifier_v010_v020_tx_state_current "${attempt_root}")" == source_recovered ]] || return 1
        [[ "$(tail -n 1 "${calls}")" == recover-source ]] || return 1
        rm -rf -- "${fixture}"
    done

    prepare_transaction_fixture
    # shellcheck source=../scripts/existing-notifier-v010-v020-transaction.sh
    declare -F existing_notifier_v010_v020_transaction >/dev/null || source "${TRANSACTION_SCRIPT}"
    SUDO_COMMAND=(env)
    existing_notifier_v010_v020_tx_install_private() { install -m 0600 "$1" "$2"; }
    existing_notifier_v010_v020_capture_identity() { printf '%s\n' 0:0:600; }
    existing_notifier_v010_v020_tx_state_write "${attempt_root}" target_env_published || return 1
    : > "${calls}"
    set +e
    run_transaction_fixture > "${output}" 2>&1
    result=$?
    set -e
    [[ "${result}" == 20 && ! -s "${calls}" ]] || return 1
    grep -Fx '[ACTION REQUIRED] Run ./deploy/scripts/existing-notifier-v010-v020-rollback.sh; implicit transition resume is forbidden' "${output}" >/dev/null
)

run_test 'v0.1-to-v0.2 transaction command exists' test_transaction_script_exists
if [[ -x "${TRANSACTION_SCRIPT}" ]]; then
    run_test 'transaction uses the exact phase order' test_transaction_uses_exact_phase_order
    run_test 'transaction state is strict and no-clobber' test_transaction_state_is_strict_and_no_clobber
    run_test 'plugin pair boundary uses the reviewed transaction' test_plugin_pair_boundary_uses_reviewed_transaction
    run_test 'every boundary recovers or fails hard' test_every_boundary_recovers_or_fails_hard
    run_test 'signals recover and stale state never resumes' test_signal_recovers_and_stale_state_never_resumes
fi

if ((failures > 0)); then
    exit 1
fi
