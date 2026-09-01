#!/usr/bin/env bash

# Fault hooks are called indirectly by the backup orchestrator.
# shellcheck disable=SC2034,SC2251,SC2329

set -Eeuo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(cd "${TEST_DIR}/.." && pwd)"
BACKUP_COMMAND="${DEPLOY_DIR}/scripts/backup.sh"
failures=0

fail() { printf 'not ok - %s\n' "$1" >&2; failures=$((failures + 1)); }
pass() { printf 'ok - %s\n' "$1"; }

run_test() {
    local name="$1" function_name="$2" test_status

    set +e
    ( set -Eeuo pipefail; "${function_name}" )
    test_status=$?
    set -e
    if ((test_status == 0)); then pass "${name}"; else fail "${name}"; fi
}

event() {
    printf '%s\n' "$1" >> "${BACKUP_TEST_EVENTS}"
}

test_privileged() {
    local command_name="$1"
    shift
    case "${command_name}" in
        install)
            local -a filtered=()
            while (($# > 0)); do
                case "$1" in
                    -o|-g) shift 2 ;;
                    *) filtered+=("$1"); shift ;;
                esac
            done
            command install "${filtered[@]}"
            ;;
        mv)
            local -a filtered=()
            while (($# > 0)); do
                case "$1" in
                    -fT) filtered+=(-f); shift ;;
                    *) filtered+=("$1"); shift ;;
                esac
            done
            command mv "${filtered[@]}"
            ;;
        *) command "${command_name}" "$@" ;;
    esac
}

load_fixture() {
    local fixture="$1"

    [[ -f "${BACKUP_COMMAND}" ]] || return 1
    # shellcheck source=/dev/null
    source "${BACKUP_COMMAND}"
    BACKUP_STATE_ROOT="${fixture}/state"
    BACKUP_STAGING_ROOT="${BACKUP_STATE_ROOT}/staging"
    BACKUP_STATUS_ROOT="${BACKUP_STATE_ROOT}/status"
    BACKUP_STATUS_FILE="${BACKUP_STATUS_ROOT}/latest.json"
    BACKUP_LATEST_SUCCESS_FILE="${BACKUP_STATUS_ROOT}/latest-success.json"
    BACKUP_LOCK_FILE="${BACKUP_STATE_ROOT}/backup.lock"
    BACKUP_TEST_EVENTS="${fixture}/events"
    BACKUP_TEST_STATUS="${fixture}/status.json"
    BACKUP_TEST_FAIL_AT=''
    BACKUP_TEST_WEEKLY=false
    BACKUP_TEST_ALERT_FAIL=false
    BACKUP_TEST_RESUME_VALID=true
    BACKUP_TEST_START_MAILER_ATTEMPTS="${fixture}/start-mailer-attempts"
    BACKUP_TEST_START_MATTERMOST_ATTEMPTS="${fixture}/start-mattermost-attempts"
    BACKUP_TEST_HEALTH_ATTEMPTS="${fixture}/health-attempts"
    BACKUP_TEST_UPLOAD_WEEKLY="${fixture}/upload-weekly"
    BACKUP_TEST_VERIFY_WEEKLY="${fixture}/verify-weekly"
    export BACKUP_TEST_EVENTS BACKUP_TEST_STATUS BACKUP_TEST_FAIL_AT BACKUP_TEST_WEEKLY
    export BACKUP_TEST_ALERT_FAIL BACKUP_TEST_RESUME_VALID
    : > "${BACKUP_TEST_EVENTS}"
    printf '0\n' > "${BACKUP_TEST_START_MAILER_ATTEMPTS}"
    printf '0\n' > "${BACKUP_TEST_START_MATTERMOST_ATTEMPTS}"
    printf '0\n' > "${BACKUP_TEST_HEALTH_ATTEMPTS}"
    SUDO_COMMAND=(test_privileged)
    backup_expected_uid() { id -u; }
    backup_expected_gid() { id -g; }

    backup_generate_id() { printf '%s\n' '20260901T030000Z-0123456789abcdef0123456789abcdef'; }
    backup_acquire_lock() { event lock; [[ "${BACKUP_TEST_FAIL_AT}" != lock-busy ]] || return 75; }
    backup_preflight() { event preflight; [[ "${BACKUP_TEST_FAIL_AT}" != preflight ]]; }
    backup_health() {
        local attempts
        event health
        attempts="$(( $(<"${BACKUP_TEST_HEALTH_ATTEMPTS}") + 1 ))"
        printf '%s\n' "${attempts}" > "${BACKUP_TEST_HEALTH_ATTEMPTS}"
        [[ "${BACKUP_TEST_FAIL_AT}" != health ]]
        [[ "${BACKUP_TEST_FAIL_AT}" != health-after-restart || "${attempts}" -eq 1 ]]
    }
    backup_create_set_dir() { install -d -m 0700 "$1"; }
    backup_stop_mattermost() { event stop:mattermost; [[ "${BACKUP_TEST_FAIL_AT}" != stop-mattermost ]]; }
    backup_stop_mailer() { event stop:threadhub-mailer; [[ "${BACKUP_TEST_FAIL_AT}" != stop-mailer ]]; }
    backup_snapshot() {
        event snapshot
        if [[ "${BACKUP_TEST_FAIL_AT}" == signal ]]; then
            kill -TERM "${BASHPID}"
            return 1
        fi
        [[ "${BACKUP_TEST_FAIL_AT}" != snapshot ]] || return 1
        printf 'database\n' > "$1/database.dump"
        printf 'data\n' > "$1/mattermost-data.tar.zst"
        printf 'queue\n' > "$1/notifier-queue.tar.zst"
        chmod 0600 "$1"/*
    }
    backup_start_mailer() {
        local attempts
        event start:threadhub-mailer
        attempts="$(( $(<"${BACKUP_TEST_START_MAILER_ATTEMPTS}") + 1 ))"
        printf '%s\n' "${attempts}" > "${BACKUP_TEST_START_MAILER_ATTEMPTS}"
        [[ "${BACKUP_TEST_FAIL_AT}" != start-mailer-always ]] || return 1
        [[ "${BACKUP_TEST_FAIL_AT}" != start-mailer-once || "${attempts}" -gt 1 ]]
    }
    backup_start_mattermost() {
        local attempts
        event start:mattermost
        attempts="$(( $(<"${BACKUP_TEST_START_MATTERMOST_ATTEMPTS}") + 1 ))"
        printf '%s\n' "${attempts}" > "${BACKUP_TEST_START_MATTERMOST_ATTEMPTS}"
        [[ "${BACKUP_TEST_FAIL_AT}" != start-mattermost-always ]] || return 1
        [[ "${BACKUP_TEST_FAIL_AT}" != start-mattermost-once || "${attempts}" -gt 1 ]]
    }
    backup_manifest() {
        event manifest
        [[ "${BACKUP_TEST_FAIL_AT}" != manifest ]] || return 1
        printf '{}\n' > "$1/manifest.json"
        printf 'hash  manifest.json\n' > "$1/manifest.sha256"
        chmod 0600 "$1/manifest.json" "$1/manifest.sha256"
    }
    backup_validate_local_set() {
        [[ "${BACKUP_TEST_FAIL_AT}" != local-set ]]
    }
    backup_bundle_size() { printf '128\n'; }
    backup_weekly_required() { [[ "${BACKUP_TEST_WEEKLY}" == true ]]; }
    backup_upload_set() {
        event upload
        printf '%s\n' "$2" > "${BACKUP_TEST_UPLOAD_WEEKLY}"
        [[ "${BACKUP_TEST_FAIL_AT}" != upload ]]
    }
    backup_verify_set() {
        event verify
        printf '%s\n' "$2" > "${BACKUP_TEST_VERIFY_WEEKLY}"
        [[ "${BACKUP_TEST_FAIL_AT}" != verify ]]
    }
    backup_resume_validate() {
        event validate-local-set
        [[ "${BACKUP_TEST_RESUME_VALID}" == true ]]
    }
    backup_resume_weekly_required() { [[ "${BACKUP_TEST_WEEKLY}" == true ]]; }
    backup_retain_set() { event retain; }
    backup_cleanup_set() { event cleanup; rm -rf -- "$1"; }
    backup_alert_once() { event alert; [[ "${BACKUP_TEST_ALERT_FAIL}" != true ]]; }
    backup_persist_status() {
        jq -cn \
            --arg status "${BACKUP_RUN_STATUS}" \
            --arg phase "${BACKUP_RUN_PHASE}" \
            --arg failure_class "${BACKUP_RUN_FAILURE_CLASS}" \
            --arg snapshot_result "${BACKUP_RUN_SNAPSHOT_RESULT}" \
            --arg service_recovery_result "${BACKUP_RUN_RECOVERY_RESULT}" \
            --arg upload_result "${BACKUP_RUN_UPLOAD_RESULT}" \
            --arg verification_result "${BACKUP_RUN_VERIFICATION_RESULT}" \
            --arg alert_delivery "${BACKUP_RUN_ALERT_DELIVERY}" \
            '{status:$status,phase:$phase,failure_class:$failure_class,
              snapshot_result:$snapshot_result,service_recovery_result:$service_recovery_result,
              upload_result:$upload_result,verification_result:$verification_result,
              alert_delivery:$alert_delivery}' > "${BACKUP_TEST_STATUS}"
        [[ "${BACKUP_RUN_STATUS}" == running ]] || event "status:${BACKUP_RUN_STATUS}"
    }
    backup_persist_latest_success() { cp "${BACKUP_TEST_STATUS}" "${fixture}/latest-success.json"; }
}

assert_events() {
    local expected="$1"
    [[ "$(paste -sd' ' "${BACKUP_TEST_EVENTS}")" == "${expected}" ]]
}

run_expect_failure() {
    local result
    set +e
    backup_main "$@" >"${BACKUP_TEST_STATUS}.stdout" 2>"${BACKUP_TEST_STATUS}.stderr"
    result=$?
    set -e
    ((result != 0))
}

test_happy_path_restarts_before_manifest_and_upload() (
    fixture="$(mktemp -d)"
    trap 'rm -rf "${fixture}"' EXIT
    load_fixture "${fixture}"

    backup_main
    assert_events 'lock preflight health stop:mattermost stop:threadhub-mailer snapshot start:threadhub-mailer start:mattermost health manifest upload verify status:success cleanup'
    jq -e '.status == "success" and .failure_class == "none" and
        .snapshot_result == "ok" and .service_recovery_result == "ok" and
        .upload_result == "ok" and .verification_result == "ok"' "${BACKUP_TEST_STATUS}" >/dev/null
)

test_restart_commands_wait_for_container_health() (
    fixture="$(mktemp -d)"
    trap 'rm -rf "${fixture}"' EXIT
    calls="${fixture}/compose-calls"
    export calls
    # shellcheck source=/dev/null
    source "${BACKUP_COMMAND}"
    compose() { printf '%s\n' "$*" >> "${calls}"; }

    backup_start_mailer
    backup_start_mattermost

    [[ "$(<"${calls}")" == $'up -d --no-deps --wait --wait-timeout 240 threadhub-mailer\nup -d --no-deps --wait --wait-timeout 240 mattermost' ]]
)

test_preflight_failure_never_stops_services() (
    fixture="$(mktemp -d)"
    trap 'rm -rf "${fixture}"' EXIT
    load_fixture "${fixture}"
    BACKUP_TEST_FAIL_AT=preflight
    export BACKUP_TEST_FAIL_AT

    run_expect_failure
    assert_events 'lock preflight alert status:failed'
    ! grep -F 'stop:' "${BACKUP_TEST_EVENTS}"
    jq -e '.failure_class == "preflight" and .service_recovery_result == "not_needed" and
        .snapshot_result == "not_run"' "${BACKUP_TEST_STATUS}" >/dev/null
)

test_mailer_stop_failure_recovers_mattermost() (
    fixture="$(mktemp -d)"
    trap 'rm -rf "${fixture}"' EXIT
    load_fixture "${fixture}"
    BACKUP_TEST_FAIL_AT=stop-mailer
    export BACKUP_TEST_FAIL_AT

    run_expect_failure
    assert_events 'lock preflight health stop:mattermost stop:threadhub-mailer start:mattermost health alert status:failed cleanup'
    jq -e '.failure_class == "snapshot" and .service_recovery_result == "ok"' \
        "${BACKUP_TEST_STATUS}" >/dev/null
)

test_snapshot_failure_recovers_both_and_alerts_once() (
    fixture="$(mktemp -d)"
    trap 'rm -rf "${fixture}"' EXIT
    load_fixture "${fixture}"
    BACKUP_TEST_FAIL_AT=snapshot
    export BACKUP_TEST_FAIL_AT

    run_expect_failure
    assert_events 'lock preflight health stop:mattermost stop:threadhub-mailer snapshot start:threadhub-mailer start:mattermost health alert status:failed cleanup'
    [[ "$(grep -c '^alert$' "${BACKUP_TEST_EVENTS}")" == 1 ]]
    jq -e '.failure_class == "snapshot" and .snapshot_result == "failed" and
        .service_recovery_result == "ok" and .upload_result == "not_run" and
        .verification_result == "not_run"' "${BACKUP_TEST_STATUS}" >/dev/null
)

test_signal_during_snapshot_recovers_writers() (
    fixture="$(mktemp -d)"
    trap 'rm -rf "${fixture}"' EXIT
    load_fixture "${fixture}"
    BACKUP_TEST_FAIL_AT=signal
    export BACKUP_TEST_FAIL_AT

    run_expect_failure
    grep -F 'start:threadhub-mailer' "${BACKUP_TEST_EVENTS}" >/dev/null
    grep -F 'start:mattermost' "${BACKUP_TEST_EVENTS}" >/dev/null
    [[ "$(grep -c '^alert$' "${BACKUP_TEST_EVENTS}")" == 1 ]]
    jq -e '.failure_class == "snapshot" and .service_recovery_result == "ok"' \
        "${BACKUP_TEST_STATUS}" >/dev/null
)

test_restart_failure_is_retried_and_classified() (
    fixture="$(mktemp -d)"
    trap 'rm -rf "${fixture}"' EXIT
    load_fixture "${fixture}"
    BACKUP_TEST_FAIL_AT=start-mailer-once
    export BACKUP_TEST_FAIL_AT

    run_expect_failure
    [[ "$(grep -c '^start:threadhub-mailer$' "${BACKUP_TEST_EVENTS}")" == 2 ]]
    grep -F 'start:mattermost' "${BACKUP_TEST_EVENTS}" >/dev/null
    jq -e '.failure_class == "service_recovery" and .snapshot_result == "ok" and
        .service_recovery_result == "ok"' "${BACKUP_TEST_STATUS}" >/dev/null
)

test_unrecoverable_mailer_restart_still_attempts_mattermost() (
    fixture="$(mktemp -d)"
    trap 'rm -rf "${fixture}"' EXIT
    load_fixture "${fixture}"
    BACKUP_TEST_FAIL_AT=start-mailer-always
    export BACKUP_TEST_FAIL_AT

    run_expect_failure
    [[ "$(grep -c '^start:threadhub-mailer$' "${BACKUP_TEST_EVENTS}")" == 2 ]]
    grep -F 'start:mattermost' "${BACKUP_TEST_EVENTS}" >/dev/null
    jq -e '.failure_class == "service_recovery" and .service_recovery_result == "failed"' \
        "${BACKUP_TEST_STATUS}" >/dev/null
)

test_post_restart_health_failure_remains_service_recovery_failure() (
    fixture="$(mktemp -d)"
    trap 'rm -rf "${fixture}"' EXIT
    load_fixture "${fixture}"
    BACKUP_TEST_FAIL_AT=health-after-restart
    export BACKUP_TEST_FAIL_AT

    run_expect_failure
    [[ "$(grep -c '^health$' "${BACKUP_TEST_EVENTS}")" == 2 ]]
    jq -e '.failure_class == "service_recovery" and .service_recovery_result == "failed"' \
        "${BACKUP_TEST_STATUS}" >/dev/null
)

test_manifest_failure_never_uploads_and_cleans_local_set() (
    fixture="$(mktemp -d)"
    trap 'rm -rf "${fixture}"' EXIT
    load_fixture "${fixture}"
    BACKUP_TEST_FAIL_AT=manifest
    export BACKUP_TEST_FAIL_AT

    run_expect_failure
    grep -F 'manifest' "${BACKUP_TEST_EVENTS}" >/dev/null
    ! grep -E '^(upload|verify|retain)$' "${BACKUP_TEST_EVENTS}"
    grep -F 'cleanup' "${BACKUP_TEST_EVENTS}" >/dev/null
    jq -e '.failure_class == "manifest" and .snapshot_result == "ok" and
        .service_recovery_result == "ok" and .upload_result == "not_run" and
        .verification_result == "not_run"' "${BACKUP_TEST_STATUS}" >/dev/null
)

test_upload_and_verify_failures_retain_complete_set() (
    for failure in upload verify; do
        fixture="$(mktemp -d)"
        load_fixture "${fixture}"
        BACKUP_TEST_FAIL_AT="${failure}"
        export BACKUP_TEST_FAIL_AT

        run_expect_failure
        grep -F 'retain' "${BACKUP_TEST_EVENTS}" >/dev/null
        ! grep -F 'cleanup' "${BACKUP_TEST_EVENTS}"
        jq -e --arg failure "${failure}" '.failure_class == (if $failure == "verify" then "remote_verify" else "upload" end)' \
            "${BACKUP_TEST_STATUS}" >/dev/null
        rm -rf "${fixture}"
    done
)

test_resume_upload_never_touches_services_or_snapshot() (
    fixture="$(mktemp -d)"
    trap 'rm -rf "${fixture}"' EXIT
    load_fixture "${fixture}"
    install -d -m 0700 "${BACKUP_STAGING_ROOT}/20260901T030000Z-0123456789abcdef0123456789abcdef"

    backup_main --resume-upload '20260901T030000Z-0123456789abcdef0123456789abcdef'
    assert_events 'lock validate-local-set upload verify status:success cleanup'
    ! grep -E '^(stop:|start:|snapshot|manifest|health)$' "${BACKUP_TEST_EVENTS}"
)

test_stale_resume_and_malformed_id_fail_without_service_mutation() (
    fixture="$(mktemp -d)"
    trap 'rm -rf "${fixture}"' EXIT
    load_fixture "${fixture}"
    BACKUP_TEST_RESUME_VALID=false
    export BACKUP_TEST_RESUME_VALID
    run_expect_failure --resume-upload '20260901T030000Z-0123456789abcdef0123456789abcdef'
    assert_events 'lock validate-local-set alert status:failed'
    ! grep -E '^(stop:|start:|snapshot|manifest)$' "${BACKUP_TEST_EVENTS}"

    : > "${BACKUP_TEST_EVENTS}"
    run_expect_failure --resume-upload '../invalid'
    assert_events 'lock alert status:failed'
)

test_alert_failure_preserves_original_failure_class() (
    fixture="$(mktemp -d)"
    trap 'rm -rf "${fixture}"' EXIT
    load_fixture "${fixture}"
    BACKUP_TEST_FAIL_AT=upload
    BACKUP_TEST_ALERT_FAIL=true
    export BACKUP_TEST_FAIL_AT BACKUP_TEST_ALERT_FAIL

    run_expect_failure
    jq -e '.failure_class == "upload" and .alert_delivery == "failed"' \
        "${BACKUP_TEST_STATUS}" >/dev/null
)

test_expired_resume_state_removes_only_its_staging_set() (
    fixture="$(mktemp -d)"
    trap 'rm -rf "${fixture}"' EXIT
    load_fixture "${fixture}"
    backup_prepare_state_root
    backup_prepare_resume_root
    backup_id='20260901T030000Z-0123456789abcdef0123456789abcdef'
    set_dir="${BACKUP_STAGING_ROOT}/${backup_id}"
    marker="$(backup_resume_marker_path "${backup_id}")"
    install -d -m 0700 "${set_dir}" "${fixture}/outside"
    printf 'preserve\n' > "${fixture}/outside/sentinel"
    jq -cn --arg id "${backup_id}" --argjson expires_at "$(( $(date +%s) - 1 ))" \
        '{backup_id:$id,expires_at:$expires_at,weekly_required:false}' > "${marker}"
    chmod 0600 "${marker}"

    backup_cleanup_expired_sets
    [[ ! -e "${set_dir}" && ! -e "${marker}" ]]
    [[ "$(<"${fixture}/outside/sentinel")" == preserve ]]
)

test_busy_lock_exits_without_status_or_alert() (
    fixture="$(mktemp -d)"
    trap 'rm -rf "${fixture}"' EXIT
    load_fixture "${fixture}"
    BACKUP_TEST_FAIL_AT=lock-busy
    export BACKUP_TEST_FAIL_AT

    backup_main
    assert_events 'lock'
    [[ ! -e "${BACKUP_TEST_STATUS}" ]]
)

test_sunday_policy_reaches_both_upload_and_verification() (
    fixture="$(mktemp -d)"
    trap 'rm -rf "${fixture}"' EXIT
    load_fixture "${fixture}"
    BACKUP_TEST_WEEKLY=true
    export BACKUP_TEST_WEEKLY

    backup_main
    [[ "$(<"${BACKUP_TEST_UPLOAD_WEEKLY}")" == true ]]
    [[ "$(<"${BACKUP_TEST_VERIFY_WEEKLY}")" == true ]]
)

run_test 'happy backup restarts before manifest and upload' test_happy_path_restarts_before_manifest_and_upload
run_test 'backup restart commands wait for container health' test_restart_commands_wait_for_container_health
run_test 'preflight failure never stops services' test_preflight_failure_never_stops_services
run_test 'Mailer stop failure recovers Mattermost' test_mailer_stop_failure_recovers_mattermost
run_test 'snapshot failure recovers both and alerts once' test_snapshot_failure_recovers_both_and_alerts_once
run_test 'signal during snapshot recovers both writers' test_signal_during_snapshot_recovers_writers
run_test 'restart failure is retried and classified' test_restart_failure_is_retried_and_classified
run_test 'unrecoverable Mailer restart still attempts Mattermost' test_unrecoverable_mailer_restart_still_attempts_mattermost
run_test 'post-restart health failure remains service-recovery failure' test_post_restart_health_failure_remains_service_recovery_failure
run_test 'manifest failure never uploads and cleans local set' test_manifest_failure_never_uploads_and_cleans_local_set
run_test 'upload and verification failures retain the complete set' test_upload_and_verify_failures_retain_complete_set
run_test 'resume upload never touches services or snapshot' test_resume_upload_never_touches_services_or_snapshot
run_test 'stale resume and malformed ID never mutate services' test_stale_resume_and_malformed_id_fail_without_service_mutation
run_test 'alert failure preserves the original failure class' test_alert_failure_preserves_original_failure_class
run_test 'expired resume state removes only its staging set' test_expired_resume_state_removes_only_its_staging_set
run_test 'busy lock exits without status or alert' test_busy_lock_exits_without_status_or_alert
run_test 'Sunday policy reaches both upload and verification' test_sunday_policy_reaches_both_upload_and_verification

if ((failures > 0)); then
    printf '%d backup orchestration test(s) failed\n' "${failures}" >&2
    exit 1
fi
