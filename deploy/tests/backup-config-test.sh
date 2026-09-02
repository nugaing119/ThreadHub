#!/usr/bin/env bash

# Fixture callbacks and sourced globals are invoked indirectly. Negative
# assertions intentionally rely on `! command` under the test subshell's -e.
# shellcheck disable=SC2034,SC2251,SC2329

set -Eeuo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(cd "${TEST_DIR}/.." && pwd)"
BACKUP_COMMON="${DEPLOY_DIR}/scripts/backup-common.sh"
BACKUP_STATUS="${DEPLOY_DIR}/scripts/backup-status.sh"
failures=0

fail() {
    printf 'not ok - %s\n' "$1" >&2
    failures=$((failures + 1))
}

pass() {
    printf 'ok - %s\n' "$1"
}

run_test() {
    local name="$1"
    local function_name="$2"
    local status

    set +e
    ( set -Eeuo pipefail; "${function_name}" )
    status=$?
    set -e
    if ((status == 0)); then
        pass "${name}"
    else
        fail "${name}"
    fi
}

portable_mode() {
    if stat -c '%a' "$1" >/dev/null 2>&1; then
        stat -c '%a' "$1"
    else
        stat -f '%Lp' "$1"
    fi
}

write_valid_config() {
    local path="$1"

    printf '%s\n' \
        'BACKUP_REGION=ap-singapore-1' \
        'BACKUP_NAMESPACE=namespace123' \
        'BACKUP_BUCKET=threadhub-backup-01' \
        'BACKUP_ALERT_EMAIL=backup-admin@threadhub.invalid' \
        'BACKUP_SCHEDULE=03:00' \
        'BACKUP_DAILY_RETENTION_DAYS=7' \
        'BACKUP_WEEKLY_RETENTION_DAYS=28' > "${path}"
    chmod 0600 "${path}"
}

backup_test_privileged() {
    local command_name="$1"
    shift
    local filtered=()

    case "${command_name}" in
        install)
            while (($# > 0)); do
                case "$1" in
                    -o|-g) shift 2 ;;
                    *) filtered+=("$1"); shift ;;
                esac
            done
            command install "${filtered[@]}"
            ;;
        mv)
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

    THREADHUB_BACKUP_ENV_FILE="${fixture}/backup.env"
    export THREADHUB_BACKUP_ENV_FILE
    [[ -f "${BACKUP_COMMON}" ]] || return 1
    # shellcheck source=/dev/null
    source "${BACKUP_COMMON}" || return 1
    BACKUP_STATE_ROOT="${fixture}/state"
    BACKUP_STAGING_ROOT="${BACKUP_STATE_ROOT}/staging"
    BACKUP_STATUS_ROOT="${BACKUP_STATE_ROOT}/status"
    BACKUP_STATUS_FILE="${BACKUP_STATUS_ROOT}/latest.json"
    BACKUP_LATEST_SUCCESS_FILE="${BACKUP_STATUS_ROOT}/latest-success.json"
    BACKUP_LOCK_FILE="${BACKUP_STATE_ROOT}/backup.lock"
    SUDO_COMMAND=(backup_test_privileged)
    backup_expected_uid() { id -u; }
    backup_expected_gid() { id -g; }
}

test_valid_config_requires_exact_secure_contract() (
    fixture="$(mktemp -d)"
    trap 'rm -rf "${fixture}"' EXIT
    write_valid_config "${fixture}/backup.env"
    load_fixture "${fixture}"

    backup_validate_config
    [[ "$(backup_env_value BACKUP_REGION)" == ap-singapore-1 ]]
    [[ "$(backup_env_value BACKUP_BUCKET)" == threadhub-backup-01 ]]
)

test_production_config_requires_root_owner() (
    fixture="$(mktemp -d)"
    trap 'rm -rf "${fixture}"' EXIT
    write_valid_config "${fixture}/backup.env"
    THREADHUB_BACKUP_ENV_FILE="${fixture}/backup.env"
    export THREADHUB_BACKUP_ENV_FILE
    [[ -f "${BACKUP_COMMON}" ]] || return 1
    # shellcheck source=/dev/null
    source "${BACKUP_COMMON}" || return 1

    ! backup_validate_config >"${fixture}/stdout" 2>"${fixture}/stderr"
    ! grep -F 'backup-admin@threadhub.invalid' "${fixture}/stdout" "${fixture}/stderr"
)

test_config_rejects_wrong_mode_symlink_duplicate_unknown_and_region() (
    fixture="$(mktemp -d)"
    trap 'rm -rf "${fixture}"' EXIT
    write_valid_config "${fixture}/backup.env"
    load_fixture "${fixture}"

    chmod 0644 "${fixture}/backup.env"
    ! backup_validate_config
    chmod 0600 "${fixture}/backup.env"

    ln -s "${fixture}/backup.env" "${fixture}/backup-link.env"
    BACKUP_ENV_FILE="${fixture}/backup-link.env"
    ! backup_validate_config
    BACKUP_ENV_FILE="${fixture}/backup.env"

    printf '%s\n' 'BACKUP_REGION=ap-singapore-1' >> "${fixture}/backup.env"
    ! backup_validate_config
    write_valid_config "${fixture}/backup.env"
    printf '%s\n' 'UNKNOWN_KEY=private-value' >> "${fixture}/backup.env"
    ! backup_validate_config >"${fixture}/stdout" 2>"${fixture}/stderr"
    ! grep -F 'private-value' "${fixture}/stdout" "${fixture}/stderr"

    write_valid_config "${fixture}/backup.env"
    sed -i.bak 's/ap-singapore-1/ap-seoul-1/' "${fixture}/backup.env"
    rm -f "${fixture}/backup.env.bak"
    ! backup_validate_config
)

test_backup_ids_and_empty_restore_target_are_fail_closed() (
    fixture="$(mktemp -d)"
    trap 'rm -rf "${fixture}"' EXIT
    write_valid_config "${fixture}/backup.env"
    load_fixture "${fixture}"

    backup_validate_id '20260901T030000Z-0123456789abcdef0123456789abcdef'
    ! backup_validate_id '../20260901T030000Z-0123456789abcdef0123456789abcdef'
    ! backup_validate_id '20260901T030000Z-0123456789ABCDEF0123456789ABCDEF'
    ! backup_assert_empty_target "${fixture}"
    ! backup_assert_empty_target /srv/threadhub/../other
)

test_empty_target_rejects_find_failures() (
    fixture="$(mktemp -d)"
    trap 'rm -rf "${fixture}"' EXIT
    write_valid_config "${fixture}/backup.env"
    load_fixture "${fixture}"
    mkdir -p "${fixture}/target"

    declare -F backup_directory_is_empty >/dev/null
    find() { return 2; }
    ! backup_directory_is_empty "${fixture}/target"
)

test_backup_id_epoch_is_strict_and_utc() (
    fixture="$(mktemp -d)"
    trap 'rm -rf "${fixture}"' EXIT
    write_valid_config "${fixture}/backup.env"
    load_fixture "${fixture}"

    declare -F backup_id_epoch >/dev/null
    [[ "$(backup_id_epoch '20260901T030000Z-0123456789abcdef0123456789abcdef')" == 1788231600 ]]
    ! backup_id_epoch '20260230T030000Z-0123456789abcdef0123456789abcdef'
)

test_state_and_status_are_exact_private_and_atomic() (
    fixture="$(mktemp -d)"
    trap 'rm -rf "${fixture}"' EXIT
    write_valid_config "${fixture}/backup.env"
    load_fixture "${fixture}"
    backup_prepare_state_root

    [[ "$(portable_mode "${BACKUP_STATE_ROOT}")" == 700 ]]
    [[ "$(portable_mode "${BACKUP_STAGING_ROOT}")" == 700 ]]
    [[ "$(portable_mode "${BACKUP_STATUS_ROOT}")" == 700 ]]

    id='20260901T030000Z-0123456789abcdef0123456789abcdef'
    now="$(date +%s)"
    backup_write_status success complete "${id}" "$((now - 10))" "${now}" 3 2048 5 ok ok ok ok none not_needed
    backup_write_latest_success success complete "${id}" "$((now - 10))" "${now}" 3 2048 5 ok ok ok ok none not_needed
    [[ "$(portable_mode "${BACKUP_STATUS_FILE}")" == 600 ]]
    [[ "$(portable_mode "${BACKUP_LATEST_SUCCESS_FILE}")" == 600 ]]
    jq -e '
        keys == ["alert_delivery","backup_id","completed_at","failure_class","local_bundle_bytes","phase","service_downtime_seconds","service_recovery_result","snapshot_result","started_at","status","upload_result","uploaded_object_count","verification_result"] and
        .status == "success" and .verification_result == "ok" and
        .snapshot_result == "ok" and .service_recovery_result == "ok" and
        .upload_result == "ok" and .failure_class == "none"
    ' "${BACKUP_STATUS_FILE}" >/dev/null
    ! grep -F 'backup-admin@threadhub.invalid' "${BACKUP_STATUS_FILE}" "${BACKUP_LATEST_SUCCESS_FILE}"
    ! find "${BACKUP_STATUS_ROOT}" -maxdepth 1 -name '*.tmp.*' -print -quit | grep -q .
    backup_read_status "${BACKUP_STATUS_FILE}" >/dev/null
)

test_status_rejects_unknown_values_and_malformed_files() (
    fixture="$(mktemp -d)"
    trap 'rm -rf "${fixture}"' EXIT
    write_valid_config "${fixture}/backup.env"
    load_fixture "${fixture}"
    backup_prepare_state_root
    id='20260901T030000Z-0123456789abcdef0123456789abcdef'

    ! backup_write_status failed upload "${id}" 1 2 3 4 5 failed ok ok failed customer@example.test failed
    printf '%s\n' '{"status":"success","private":"customer@example.test"}' > "${BACKUP_STATUS_FILE}"
    chmod 0600 "${BACKUP_STATUS_FILE}"
    ! backup_read_status "${BACKUP_STATUS_FILE}" >"${fixture}/stdout" 2>"${fixture}/stderr"
    ! grep -F 'customer@example.test' "${fixture}/stdout" "${fixture}/stderr"
)

test_status_cli_uses_latest_success_freshness_and_current_result() (
    fixture="$(mktemp -d)"
    trap 'rm -rf "${fixture}"' EXIT
    write_valid_config "${fixture}/backup.env"
    load_fixture "${fixture}"
    [[ -f "${BACKUP_STATUS}" ]] || return 1
    # shellcheck source=/dev/null
    source "${BACKUP_STATUS}" || return 1
    backup_expected_uid() { id -u; }
    backup_expected_gid() { id -g; }
    backup_prepare_state_root
    id='20260901T030000Z-0123456789abcdef0123456789abcdef'
    created_at="$(backup_id_epoch "${id}")"
    BACKUP_TEST_STATUS_NOW=$((created_at + 10))
    backup_status_now_epoch() { printf '%s\n' "${BACKUP_TEST_STATUS_NOW}"; }
    now="${BACKUP_TEST_STATUS_NOW}"
    backup_write_status success complete "${id}" "$((now - 10))" "${now}" 3 2048 5 ok ok ok ok none not_needed
    backup_write_latest_success success complete "${id}" "$((now - 10))" "${now}" 3 2048 5 ok ok ok ok none not_needed

    backup_status_main --json > "${fixture}/status.json"
    jq -e '.status == "success" and .backup_id == $id' --arg id "${id}" "${fixture}/status.json" >/dev/null
    BACKUP_TEST_STATUS_NOW=$((created_at + 86401))
    now="${BACKUP_TEST_STATUS_NOW}"
    backup_write_latest_success success complete "${id}" "${created_at}" "${now}" 3 2048 5 ok ok ok ok none not_needed
    ! backup_status_main --json >/dev/null
)

test_safe_cleanup_removes_only_valid_direct_staging_child() (
    fixture="$(mktemp -d)"
    trap 'rm -rf "${fixture}"' EXIT
    write_valid_config "${fixture}/backup.env"
    load_fixture "${fixture}"
    backup_prepare_state_root
    id='20260901T030000Z-0123456789abcdef0123456789abcdef'
    target="${BACKUP_STAGING_ROOT}/${id}"
    outside="${fixture}/outside"
    install -d -m 0700 "${target}" "${outside}"
    printf 'preserve\n' > "${outside}/sentinel"

    ! backup_safe_remove_set "${target}/../${id}"
    [[ -d "${target}" ]]
    backup_safe_remove_set "${target}"
    [[ ! -e "${target}" && "$(<"${outside}/sentinel")" == preserve ]]

    install -d -m 0700 "${target}"
    ln -s "${target}" "${BACKUP_STAGING_ROOT}/link"
    ! backup_safe_remove_set "${BACKUP_STAGING_ROOT}/link"
)

test_alert_invocation_keeps_recipient_out_of_argv_and_output() (
    fixture="$(mktemp -d)"
    trap 'rm -rf "${fixture}"' EXIT
    write_valid_config "${fixture}/backup.env"
    load_fixture "${fixture}"
    trace="${fixture}/compose.trace"
    payload="${fixture}/payload.json"
    compose() {
        printf '%s\n' "$*" > "${trace}"
        IFS= read -r line
        printf '%s\n' "${line}" > "${payload}"
    }

    backup_send_alert upload >"${fixture}/stdout" 2>"${fixture}/stderr"
    [[ "$(<"${trace}")" == 'run --rm --no-deps -T --entrypoint /threadhub-mailer threadhub-mailer backup-alert --json-stdin' ]]
    ! grep -F 'backup-admin@threadhub.invalid' "${trace}" "${fixture}/stdout" "${fixture}/stderr"
    jq -e 'keys == ["failure_class","recipient"] and .failure_class == "upload" and .recipient == "backup-admin@threadhub.invalid"' "${payload}" >/dev/null
)

run_test 'valid backup configuration is exact and secure' test_valid_config_requires_exact_secure_contract
run_test 'production backup configuration requires root ownership' test_production_config_requires_root_owner
run_test 'backup configuration rejects mode links duplicate unknown and region drift' test_config_rejects_wrong_mode_symlink_duplicate_unknown_and_region
run_test 'backup identifiers and restore target checks fail closed' test_backup_ids_and_empty_restore_target_are_fail_closed
run_test 'empty-target checks reject find failures' test_empty_target_rejects_find_failures
run_test 'backup ID timestamps parse strictly in UTC' test_backup_id_epoch_is_strict_and_utc
run_test 'backup state and status are exact private and atomic' test_state_and_status_are_exact_private_and_atomic
run_test 'backup status rejects unknown values and malformed files' test_status_rejects_unknown_values_and_malformed_files
run_test 'backup status CLI uses latest-success freshness and current result' test_status_cli_uses_latest_success_freshness_and_current_result
run_test 'backup cleanup is constrained to a valid staging child' test_safe_cleanup_removes_only_valid_direct_staging_child
run_test 'backup alert keeps its recipient out of argv and output' test_alert_invocation_keeps_recipient_out_of_argv_and_output

if ((failures > 0)); then
    printf '%d backup configuration test(s) failed\n' "${failures}" >&2
    exit 1
fi
