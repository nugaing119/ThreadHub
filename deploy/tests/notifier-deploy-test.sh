#!/usr/bin/env bash

set -Eeuo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(cd "${TEST_DIR}/.." && pwd)"
REPOSITORY_ROOT="$(cd "${DEPLOY_DIR}/.." && pwd)"
failures=0

fail() {
    printf 'not ok - %s\n' "$1" >&2
    failures=$((failures + 1))
}

pass() {
    printf 'ok - %s\n' "$1"
}

portable_identity() {
    if stat -c '%u:%g:%a' "$1" >/dev/null 2>&1; then
        stat -c '%u:%g:%a' "$1"
    else
        stat -f '%u:%g:%Lp' "$1"
    fi
}

test_transaction_rollback_after_backup() (
    transaction_library="${DEPLOY_DIR}/scripts/notifier-plugin-transaction.sh"
    [[ -f "${transaction_library}" ]] || return 1
    # shellcheck source=/dev/null
    source "${transaction_library}"
    declare -F notifier_plugin_transaction >/dev/null || return 1

    fixture="$(mktemp -d)"
    trap 'rm -rf "${fixture}"' EXIT
    target="${fixture}/plugins/notifier"
    stage="${fixture}/release/stage"
    backup="${fixture}/release/backup"
    failed="${fixture}/release/failed"
    bundle_target="${fixture}/data/plugins/notifier.tar.gz"
    bundle_stage="${fixture}/release/bundle-stage.tar.gz"
    bundle_backup="${fixture}/release/bundle-backup.tar.gz"
    bundle_failed="${fixture}/release/bundle-failed.tar.gz"
    mkdir -p "${target}" "${stage}" "$(dirname "${bundle_target}")"
    printf 'old\n' > "${target}/generation"
    printf 'new\n' > "${stage}/generation"
    printf 'old-bundle\n' > "${bundle_target}"
    printf 'new-bundle\n' > "${bundle_stage}"
    printf 'running\n' > "${fixture}/service"
    printf 'active\n' > "${fixture}/plugin"
    printf 'enabled\n' > "${fixture}/control"

    # shellcheck disable=SC2329 # transaction callback fixture
    plugin_tx_disable_control() { printf 'disabled\n' > "${fixture}/control"; }
    # shellcheck disable=SC2329 # transaction callback fixture
    plugin_tx_disable_plugin() { printf 'inactive\n' > "${fixture}/plugin"; }
    # shellcheck disable=SC2329 # transaction callback fixture
    plugin_tx_stop_service() { printf 'stopped\n' > "${fixture}/service"; }
    # shellcheck disable=SC2329 # transaction callback fixture
    plugin_tx_prepare_targets() { return 0; }
    # shellcheck disable=SC2329 # transaction callback fixture
    plugin_tx_start_service() { printf 'running\n' > "${fixture}/service"; }
    # shellcheck disable=SC2329 # transaction callback fixture
    plugin_tx_enable_plugin() { printf 'active\n' > "${fixture}/plugin"; }
    # shellcheck disable=SC2329 # transaction callback fixture
    plugin_tx_enable_previous_plugin() { plugin_tx_enable_plugin; }
    # shellcheck disable=SC2329 # transaction callback fixture
    plugin_tx_verify_plugin() { [[ "$(<"${fixture}/plugin")" == active ]]; }
    # shellcheck disable=SC2329 # transaction callback fixture
    plugin_tx_verify_previous_objects() { return 0; }
    # shellcheck disable=SC2329 # transaction callback fixture
    plugin_tx_verify_previous_plugin() { [[ "$(<"${fixture}/plugin")" == active ]]; }
    # shellcheck disable=SC2329 # transaction callback fixture
    plugin_tx_path_exists() { [[ -e "$1" ]]; }
    # shellcheck disable=SC2329 # transaction callback fixture
    plugin_tx_move() {
        if [[ "$1" == "${stage}" && "$2" == "${target}" ]]; then
            return 91
        fi
        mv "$1" "$2"
    }

    if notifier_plugin_transaction \
        "${target}" "${stage}" "${backup}" "${failed}" \
        "${bundle_target}" "${bundle_stage}" "${bundle_backup}" "${bundle_failed}" \
        true true \
        > "${fixture}/stdout" 2> "${fixture}/stderr"; then
        return 1
    fi
    if [[ ! -f "${target}/generation" || "$(<"${target}/generation")" != old ]] \
        || [[ "$(<"${fixture}/service")" != running ]] \
        || [[ "$(<"${fixture}/plugin")" != active ]] \
        || [[ "$(<"${fixture}/control")" != disabled ]] \
        || [[ "$(<"${bundle_target}")" != old-bundle ]] \
        || [[ -e "${backup}" ]]; then
        sed 's/^/[transaction stderr] /' "${fixture}/stderr" >&2
        find "${fixture}" -mindepth 1 -maxdepth 4 -print >&2
        return 1
    fi
)

test_transaction_retries_control_disable_during_rollback() (
    transaction_library="${DEPLOY_DIR}/scripts/notifier-plugin-transaction.sh"
    [[ -f "${transaction_library}" ]] || return 1
    # shellcheck source=/dev/null
    source "${transaction_library}"

    fixture="$(mktemp -d)"
    trap 'rm -rf "${fixture}"' EXIT
    target="${fixture}/plugins/notifier"
    stage="${fixture}/release/stage"
    backup="${fixture}/release/backup"
    failed="${fixture}/release/failed"
    bundle_target="${fixture}/data/plugins/notifier.tar.gz"
    bundle_stage="${fixture}/release/bundle-stage.tar.gz"
    bundle_backup="${fixture}/release/bundle-backup.tar.gz"
    bundle_failed="${fixture}/release/bundle-failed.tar.gz"
    mkdir -p "${target}" "${stage}" "$(dirname "${bundle_target}")"
    printf 'old\n' > "${target}/generation"
    printf 'new\n' > "${stage}/generation"
    printf 'old-bundle\n' > "${bundle_target}"
    printf 'new-bundle\n' > "${bundle_stage}"
    printf 'running\n' > "${fixture}/service"
    printf 'active\n' > "${fixture}/plugin"
    printf 'enabled\n' > "${fixture}/control"
    printf '0\n' > "${fixture}/disable-attempts"

    # shellcheck disable=SC2329 # transaction callback fixture
    plugin_tx_disable_control() {
        disable_attempts="$(<"${fixture}/disable-attempts")"
        disable_attempts=$((disable_attempts + 1))
        printf '%s\n' "${disable_attempts}" > "${fixture}/disable-attempts"
        if ((disable_attempts == 1)); then
            # Production validation helpers fail with exit, not return. The
            # transaction must contain that exit and still run its rollback.
            exit 88
        fi
        printf 'disabled\n' > "${fixture}/control"
    }
    # shellcheck disable=SC2329 # transaction callback fixture
    plugin_tx_disable_plugin() { printf 'inactive\n' > "${fixture}/plugin"; }
    # shellcheck disable=SC2329 # transaction callback fixture
    plugin_tx_stop_service() { printf 'stopped\n' > "${fixture}/service"; }
    # shellcheck disable=SC2329 # transaction callback fixture
    plugin_tx_prepare_targets() { return 0; }
    # shellcheck disable=SC2329 # transaction callback fixture
    plugin_tx_start_service() { printf 'running\n' > "${fixture}/service"; }
    # shellcheck disable=SC2329 # transaction callback fixture
    plugin_tx_enable_plugin() { printf 'active\n' > "${fixture}/plugin"; }
    # shellcheck disable=SC2329 # transaction callback fixture
    plugin_tx_enable_previous_plugin() { plugin_tx_enable_plugin; }
    # shellcheck disable=SC2329 # transaction callback fixture
    plugin_tx_verify_plugin() { [[ "$(<"${fixture}/plugin")" == active ]]; }
    # shellcheck disable=SC2329 # transaction callback fixture
    plugin_tx_verify_previous_objects() { return 0; }
    # shellcheck disable=SC2329 # transaction callback fixture
    plugin_tx_verify_previous_plugin() { [[ "$(<"${fixture}/plugin")" == active ]]; }
    # shellcheck disable=SC2329 # transaction callback fixture
    plugin_tx_path_exists() { [[ -e "$1" ]]; }
    # shellcheck disable=SC2329 # transaction callback fixture
    plugin_tx_move() { mv "$1" "$2"; }

    if notifier_plugin_transaction \
        "${target}" "${stage}" "${backup}" "${failed}" \
        "${bundle_target}" "${bundle_stage}" "${bundle_backup}" "${bundle_failed}" \
        true true \
        > "${fixture}/stdout" 2> "${fixture}/stderr"; then
        return 1
    fi
    [[ "$(<"${fixture}/control")" == disabled ]] || return 1
    [[ "$(<"${fixture}/disable-attempts")" == 2 ]] || return 1
    [[ -f "${target}/generation" && "$(<"${target}/generation")" == old ]] || return 1
    [[ "$(<"${bundle_target}")" == old-bundle ]] || return 1
    [[ "$(<"${fixture}/service")" == running ]] || return 1
    [[ "$(<"${fixture}/plugin")" == active ]] || return 1
)

test_transaction_reports_rollback_failure_and_continues_restore() (
    transaction_library="${DEPLOY_DIR}/scripts/notifier-plugin-transaction.sh"
    [[ -f "${transaction_library}" ]] || return 1
    # shellcheck source=/dev/null
    source "${transaction_library}"

    fixture="$(mktemp -d)"
    trap 'rm -rf "${fixture}"' EXIT
    target="${fixture}/plugins/notifier"
    stage="${fixture}/release/stage"
    backup="${fixture}/release/backup"
    failed="${fixture}/release/failed"
    bundle_target="${fixture}/data/plugins/notifier.tar.gz"
    bundle_stage="${fixture}/release/bundle-stage.tar.gz"
    bundle_backup="${fixture}/release/bundle-backup.tar.gz"
    bundle_failed="${fixture}/release/bundle-failed.tar.gz"
    mkdir -p "${target}" "${stage}" "$(dirname "${bundle_target}")"
    printf 'old\n' > "${target}/generation"
    printf 'new\n' > "${stage}/generation"
    printf 'old-bundle\n' > "${bundle_target}"
    printf 'new-bundle\n' > "${bundle_stage}"
    printf 'running\n' > "${fixture}/service"
    printf 'active\n' > "${fixture}/plugin"
    printf 'enabled\n' > "${fixture}/control"
    printf '0\n' > "${fixture}/disable-attempts"

    # shellcheck disable=SC2329 # transaction callback fixture
    plugin_tx_disable_control() {
        disable_attempts="$(<"${fixture}/disable-attempts")"
        disable_attempts=$((disable_attempts + 1))
        printf '%s\n' "${disable_attempts}" > "${fixture}/disable-attempts"
        if ((disable_attempts > 1)); then
            exit 89
        fi
        printf 'disabled\n' > "${fixture}/control"
    }
    # shellcheck disable=SC2329 # transaction callback fixture
    plugin_tx_disable_plugin() { printf 'inactive\n' > "${fixture}/plugin"; }
    # shellcheck disable=SC2329 # transaction callback fixture
    plugin_tx_stop_service() { printf 'stopped\n' > "${fixture}/service"; }
    # shellcheck disable=SC2329 # transaction callback fixture
    plugin_tx_prepare_targets() { return 0; }
    # shellcheck disable=SC2329 # transaction callback fixture
    plugin_tx_start_service() { printf 'running\n' > "${fixture}/service"; }
    # shellcheck disable=SC2329 # transaction callback fixture
    plugin_tx_enable_plugin() { printf 'active\n' > "${fixture}/plugin"; }
    # shellcheck disable=SC2329 # transaction callback fixture
    plugin_tx_enable_previous_plugin() { plugin_tx_enable_plugin; }
    # shellcheck disable=SC2329 # transaction callback fixture
    plugin_tx_verify_plugin() { [[ "$(<"${fixture}/plugin")" == active ]]; }
    # shellcheck disable=SC2329 # transaction callback fixture
    plugin_tx_verify_previous_objects() { return 0; }
    # shellcheck disable=SC2329 # transaction callback fixture
    plugin_tx_verify_previous_plugin() { [[ "$(<"${fixture}/plugin")" == active ]]; }
    # shellcheck disable=SC2329 # transaction callback fixture
    plugin_tx_path_exists() { [[ -e "$1" ]]; }
    # shellcheck disable=SC2329 # transaction callback fixture
    plugin_tx_move() {
        if [[ "$1" == "${stage}" && "$2" == "${target}" ]]; then
            return 91
        fi
        mv "$1" "$2"
    }

    set +e
    notifier_plugin_transaction \
        "${target}" "${stage}" "${backup}" "${failed}" \
        "${bundle_target}" "${bundle_stage}" "${bundle_backup}" "${bundle_failed}" \
        true true \
        > "${fixture}/stdout" 2> "${fixture}/stderr"
    transaction_result=$?
    set -e
    [[ "${transaction_result}" == 70 ]] || return 1
    grep -F 'rollback is incomplete (control_disable)' "${fixture}/stderr" >/dev/null \
        || return 1
    [[ -f "${target}/generation" && "$(<"${target}/generation")" == old ]] || return 1
    [[ "$(<"${bundle_target}")" == old-bundle ]] || return 1
    [[ "$(<"${fixture}/service")" == running ]] || return 1
    [[ "$(<"${fixture}/plugin")" == active ]] || return 1
    [[ "$(<"${fixture}/control")" == disabled ]] || return 1
)

test_transaction_restores_runtime_and_filestore_after_activation_failure() (
    transaction_library="${DEPLOY_DIR}/scripts/notifier-plugin-transaction.sh"
    # shellcheck source=/dev/null
    source "${transaction_library}"

    fixture="$(mktemp -d)"
    trap 'rm -rf "${fixture}"' EXIT
    target="${fixture}/plugins/notifier"
    stage="${fixture}/release/runtime-stage"
    backup="${fixture}/release/runtime-backup"
    failed="${fixture}/release/runtime-failed"
    bundle_target="${fixture}/data/plugins/notifier.tar.gz"
    bundle_stage="${fixture}/release/bundle-stage.tar.gz"
    bundle_backup="${fixture}/release/bundle-backup.tar.gz"
    bundle_failed="${fixture}/release/bundle-failed.tar.gz"
    mkdir -p "${target}" "${stage}" "$(dirname "${bundle_target}")"
    printf 'old-runtime\n' > "${target}/generation"
    printf 'new-runtime\n' > "${stage}/generation"
    printf 'old-bundle\n' > "${bundle_target}"
    printf 'new-bundle\n' > "${bundle_stage}"
    printf 'running\n' > "${fixture}/service"
    printf 'active\n' > "${fixture}/plugin"
    printf 'enabled\n' > "${fixture}/control"

    # shellcheck disable=SC2329
    plugin_tx_disable_control() { printf 'disabled\n' > "${fixture}/control"; }
    # shellcheck disable=SC2329
    plugin_tx_disable_plugin() { printf 'inactive\n' > "${fixture}/plugin"; }
    # shellcheck disable=SC2329
    plugin_tx_stop_service() { printf 'stopped\n' > "${fixture}/service"; }
    # shellcheck disable=SC2329
    plugin_tx_prepare_targets() { return 0; }
    # shellcheck disable=SC2329
    plugin_tx_start_service() { printf 'running\n' > "${fixture}/service"; }
    # shellcheck disable=SC2329
    plugin_tx_enable_plugin() { printf 'active\n' > "${fixture}/plugin"; }
    # shellcheck disable=SC2329
    plugin_tx_enable_previous_plugin() { plugin_tx_enable_plugin; }
    # shellcheck disable=SC2329
    plugin_tx_verify_plugin() { return 93; }
    # shellcheck disable=SC2329
    plugin_tx_verify_previous_objects() {
        [[ "$(<"${target}/generation")" == old-runtime ]] \
            && [[ "$(<"${bundle_target}")" == old-bundle ]]
    }
    # shellcheck disable=SC2329
    plugin_tx_verify_previous_plugin() {
        [[ "$(<"${target}/generation")" == old-runtime ]] \
            && [[ "$(<"${bundle_target}")" == old-bundle ]]
    }
    # shellcheck disable=SC2329
    plugin_tx_path_exists() { [[ -e "$1" ]]; }
    # shellcheck disable=SC2329
    plugin_tx_move() { mv "$1" "$2"; }

    if notifier_plugin_transaction \
        "${target}" "${stage}" "${backup}" "${failed}" \
        "${bundle_target}" "${bundle_stage}" "${bundle_backup}" "${bundle_failed}" \
        true true > "${fixture}/stdout" 2> "${fixture}/stderr"; then
        return 1
    fi
    [[ "$(<"${target}/generation")" == old-runtime ]] || return 1
    [[ "$(<"${bundle_target}")" == old-bundle ]] || return 1
    [[ "$(<"${failed}/generation")" == new-runtime ]] || return 1
    [[ "$(<"${bundle_failed}")" == new-bundle ]] || return 1
    [[ ! -e "${backup}" && ! -e "${bundle_backup}" ]] || return 1
    [[ "$(<"${fixture}/service")" == running ]] || return 1
    [[ "$(<"${fixture}/plugin")" == active ]] || return 1
    [[ "$(<"${fixture}/control")" == disabled ]]
)

test_transaction_restores_pair_after_bundle_publish_failure() (
    transaction_library="${DEPLOY_DIR}/scripts/notifier-plugin-transaction.sh"
    # shellcheck source=/dev/null
    source "${transaction_library}"

    fixture="$(mktemp -d)"
    trap 'rm -rf "${fixture}"' EXIT
    target="${fixture}/plugins/notifier"
    stage="${fixture}/release/runtime-stage"
    backup="${fixture}/release/runtime-backup"
    failed="${fixture}/release/runtime-failed"
    bundle_target="${fixture}/data/plugins/notifier.tar.gz"
    bundle_stage="${fixture}/release/bundle-stage.tar.gz"
    bundle_backup="${fixture}/release/bundle-backup.tar.gz"
    bundle_failed="${fixture}/release/bundle-failed.tar.gz"
    mkdir -p "${target}" "${stage}" "$(dirname "${bundle_target}")"
    printf 'old-runtime\n' > "${target}/generation"
    printf 'new-runtime\n' > "${stage}/generation"
    printf 'old-bundle\n' > "${bundle_target}"
    printf 'new-bundle\n' > "${bundle_stage}"
    printf 'running\n' > "${fixture}/service"
    printf 'active\n' > "${fixture}/plugin"
    printf 'enabled\n' > "${fixture}/control"

    # shellcheck disable=SC2329
    plugin_tx_disable_control() { printf 'disabled\n' > "${fixture}/control"; }
    # shellcheck disable=SC2329
    plugin_tx_disable_plugin() { printf 'inactive\n' > "${fixture}/plugin"; }
    # shellcheck disable=SC2329
    plugin_tx_stop_service() { printf 'stopped\n' > "${fixture}/service"; }
    # shellcheck disable=SC2329
    plugin_tx_prepare_targets() { return 0; }
    # shellcheck disable=SC2329
    plugin_tx_start_service() { printf 'running\n' > "${fixture}/service"; }
    # shellcheck disable=SC2329
    plugin_tx_enable_plugin() { printf 'active\n' > "${fixture}/plugin"; }
    # shellcheck disable=SC2329
    plugin_tx_enable_previous_plugin() { plugin_tx_enable_plugin; }
    # shellcheck disable=SC2329
    plugin_tx_verify_plugin() { return 0; }
    # shellcheck disable=SC2329
    plugin_tx_verify_previous_objects() { return 0; }
    # shellcheck disable=SC2329
    plugin_tx_verify_previous_plugin() { return 0; }
    # shellcheck disable=SC2329
    plugin_tx_path_exists() { [[ -e "$1" ]]; }
    # shellcheck disable=SC2329
    plugin_tx_move() {
        if [[ "$1" == "${bundle_stage}" && "$2" == "${bundle_target}" ]]; then
            return 94
        fi
        mv "$1" "$2"
    }

    if notifier_plugin_transaction \
        "${target}" "${stage}" "${backup}" "${failed}" \
        "${bundle_target}" "${bundle_stage}" "${bundle_backup}" "${bundle_failed}" \
        true true > "${fixture}/stdout" 2> "${fixture}/stderr"; then
        return 1
    fi
    [[ "$(<"${target}/generation")" == old-runtime ]] || return 1
    [[ "$(<"${bundle_target}")" == old-bundle ]] || return 1
    [[ "$(<"${failed}/generation")" == new-runtime ]] || return 1
    [[ "$(<"${bundle_failed}")" == new-bundle ]] || return 1
    [[ "$(<"${fixture}/service")" == running ]] || return 1
    [[ "$(<"${fixture}/plugin")" == active ]] || return 1
    [[ "$(<"${fixture}/control")" == disabled ]]
)

test_transaction_keeps_service_stopped_when_restore_loses_race() (
    transaction_library="${DEPLOY_DIR}/scripts/notifier-plugin-transaction.sh"
    # shellcheck source=/dev/null
    source "${transaction_library}"

    fixture="$(mktemp -d)"
    trap 'rm -rf "${fixture}"' EXIT
    target="${fixture}/plugins/notifier"
    stage="${fixture}/release/runtime-stage"
    backup="${fixture}/release/runtime-backup"
    failed="${fixture}/release/runtime-failed"
    bundle_target="${fixture}/data/plugins/notifier.tar.gz"
    bundle_stage="${fixture}/release/bundle-stage.tar.gz"
    bundle_backup="${fixture}/release/bundle-backup.tar.gz"
    bundle_failed="${fixture}/release/bundle-failed.tar.gz"
    mkdir -p "${target}" "${stage}" "$(dirname "${bundle_target}")"
    printf 'old-runtime\n' > "${target}/generation"
    printf 'new-runtime\n' > "${stage}/generation"
    printf 'old-bundle\n' > "${bundle_target}"
    printf 'new-bundle\n' > "${bundle_stage}"
    printf 'running\n' > "${fixture}/service"
    printf 'active\n' > "${fixture}/plugin"
    printf 'enabled\n' > "${fixture}/control"

    # shellcheck disable=SC2329
    plugin_tx_disable_control() { printf 'disabled\n' > "${fixture}/control"; }
    # shellcheck disable=SC2329
    plugin_tx_disable_plugin() { printf 'inactive\n' > "${fixture}/plugin"; }
    # shellcheck disable=SC2329
    plugin_tx_stop_service() { printf 'stopped\n' > "${fixture}/service"; }
    # shellcheck disable=SC2329
    plugin_tx_prepare_targets() { return 0; }
    # shellcheck disable=SC2329
    plugin_tx_start_service() { printf 'running\n' > "${fixture}/service"; }
    # shellcheck disable=SC2329
    plugin_tx_enable_plugin() { printf 'active\n' > "${fixture}/plugin"; }
    # shellcheck disable=SC2329
    plugin_tx_enable_previous_plugin() { plugin_tx_enable_plugin; }
    # shellcheck disable=SC2329
    plugin_tx_verify_plugin() { return 0; }
    # shellcheck disable=SC2329
    plugin_tx_verify_previous_objects() { return 0; }
    # shellcheck disable=SC2329
    plugin_tx_verify_previous_plugin() { return 0; }
    # shellcheck disable=SC2329
    plugin_tx_path_exists() { [[ -e "$1" ]]; }
    # shellcheck disable=SC2329
    plugin_tx_move() {
        if [[ "$1" == "${stage}" && "$2" == "${target}" ]]; then
            mkdir "${target}"
            printf 'race-winner\n' > "${target}/generation"
            return 95
        fi
        mv "$1" "$2"
    }

    set +e
    notifier_plugin_transaction \
        "${target}" "${stage}" "${backup}" "${failed}" \
        "${bundle_target}" "${bundle_stage}" "${bundle_backup}" "${bundle_failed}" \
        true true > "${fixture}/stdout" 2> "${fixture}/stderr"
    transaction_result=$?
    set -e
    [[ "${transaction_result}" == 70 ]] || return 1
    grep -F 'rollback is incomplete (target_not_empty)' "${fixture}/stderr" >/dev/null \
        || return 1
    [[ "$(<"${fixture}/service")" == stopped ]] || return 1
    [[ "$(<"${fixture}/plugin")" == inactive ]] || return 1
    [[ "$(<"${fixture}/control")" == disabled ]] || return 1
    [[ "$(<"${target}/generation")" == race-winner ]] || return 1
    [[ "$(<"${backup}/generation")" == old-runtime ]] || return 1
    [[ "$(<"${bundle_target}")" == old-bundle ]]
)

test_transaction_rejects_fresh_target_publish_race() (
    transaction_library="${DEPLOY_DIR}/scripts/notifier-plugin-transaction.sh"
    # shellcheck source=/dev/null
    source "${transaction_library}"

    fixture="$(mktemp -d)"
    trap 'rm -rf "${fixture}"' EXIT
    target="${fixture}/plugins/notifier"
    stage="${fixture}/release/runtime-stage"
    backup="${fixture}/release/runtime-backup"
    failed="${fixture}/release/runtime-failed"
    bundle_target="${fixture}/data/plugins/notifier.tar.gz"
    bundle_stage="${fixture}/release/bundle-stage.tar.gz"
    bundle_backup="${fixture}/release/bundle-backup.tar.gz"
    bundle_failed="${fixture}/release/bundle-failed.tar.gz"
    mkdir -p "${stage}" "$(dirname "${target}")" "$(dirname "${bundle_target}")"
    printf 'new-runtime\n' > "${stage}/generation"
    printf 'new-bundle\n' > "${bundle_stage}"
    printf 'running\n' > "${fixture}/service"
    printf 'inactive\n' > "${fixture}/plugin"
    printf 'enabled\n' > "${fixture}/control"

    # shellcheck disable=SC2329
    plugin_tx_disable_control() { printf 'disabled\n' > "${fixture}/control"; }
    # shellcheck disable=SC2329
    plugin_tx_disable_plugin() { printf 'inactive\n' > "${fixture}/plugin"; }
    # shellcheck disable=SC2329
    plugin_tx_stop_service() { printf 'stopped\n' > "${fixture}/service"; }
    # shellcheck disable=SC2329
    plugin_tx_prepare_targets() { return 0; }
    # shellcheck disable=SC2329
    plugin_tx_start_service() { printf 'running\n' > "${fixture}/service"; }
    # shellcheck disable=SC2329
    plugin_tx_enable_plugin() { printf 'active\n' > "${fixture}/plugin"; }
    # shellcheck disable=SC2329
    plugin_tx_enable_previous_plugin() { plugin_tx_enable_plugin; }
    # shellcheck disable=SC2329
    plugin_tx_verify_plugin() { return 0; }
    # shellcheck disable=SC2329
    plugin_tx_verify_previous_objects() { return 0; }
    # shellcheck disable=SC2329
    plugin_tx_verify_previous_plugin() { return 0; }
    # shellcheck disable=SC2329
    plugin_tx_path_exists() { [[ -e "$1" ]]; }
    # shellcheck disable=SC2329
    plugin_tx_move() {
        if [[ "$1" == "${stage}" && "$2" == "${target}" ]]; then
            mkdir "${target}"
            printf 'race-winner\n' > "${target}/generation"
            return 96
        fi
        mv "$1" "$2"
    }

    set +e
    notifier_plugin_transaction \
        "${target}" "${stage}" "${backup}" "${failed}" \
        "${bundle_target}" "${bundle_stage}" "${bundle_backup}" "${bundle_failed}" \
        true false > "${fixture}/stdout" 2> "${fixture}/stderr"
    transaction_result=$?
    set -e
    [[ "${transaction_result}" == 70 ]] || return 1
    grep -F 'rollback is incomplete (target_publish_conflict)' "${fixture}/stderr" >/dev/null \
        || return 1
    [[ "$(<"${fixture}/service")" == stopped ]] || return 1
    [[ "$(<"${fixture}/plugin")" == inactive ]] || return 1
    [[ "$(<"${fixture}/control")" == disabled ]] || return 1
    [[ "$(<"${target}/generation")" == race-winner ]] || return 1
    [[ ! -e "${backup}" && ! -e "${bundle_target}" ]]
)

test_transaction_rejects_asymmetric_prior_pair_before_mutation() (
    transaction_library="${DEPLOY_DIR}/scripts/notifier-plugin-transaction.sh"
    # shellcheck source=/dev/null
    source "${transaction_library}"

    fixture="$(mktemp -d)"
    trap 'rm -rf "${fixture}"' EXIT
    for asymmetry in runtime-only bundle-only; do
        case_dir="${fixture}/${asymmetry}"
        target="${case_dir}/plugins/notifier"
        stage="${case_dir}/release/runtime-stage"
        backup="${case_dir}/release/runtime-backup"
        failed="${case_dir}/release/runtime-failed"
        bundle_target="${case_dir}/data/plugins/notifier.tar.gz"
        bundle_stage="${case_dir}/release/bundle-stage.tar.gz"
        bundle_backup="${case_dir}/release/bundle-backup.tar.gz"
        bundle_failed="${case_dir}/release/bundle-failed.tar.gz"
        mkdir -p "${stage}" "$(dirname "${target}")" "$(dirname "${bundle_target}")"
        printf 'new-runtime\n' > "${stage}/generation"
        printf 'new-bundle\n' > "${bundle_stage}"
        if [[ "${asymmetry}" == runtime-only ]]; then
            mkdir "${target}"
            printf 'old-runtime\n' > "${target}/generation"
        else
            printf 'old-bundle\n' > "${bundle_target}"
        fi
        printf 'running\n' > "${case_dir}/service"
        printf 'active\n' > "${case_dir}/plugin"
        printf 'enabled\n' > "${case_dir}/control"

        # shellcheck disable=SC2329
        plugin_tx_disable_control() { printf 'disabled\n' > "${case_dir}/control"; }
        # shellcheck disable=SC2329
        plugin_tx_disable_plugin() { printf 'inactive\n' > "${case_dir}/plugin"; }
        # shellcheck disable=SC2329
        plugin_tx_stop_service() { printf 'stopped\n' > "${case_dir}/service"; }
        # shellcheck disable=SC2329
        plugin_tx_prepare_targets() { return 0; }
        # shellcheck disable=SC2329
        plugin_tx_start_service() { printf 'running\n' > "${case_dir}/service"; }
        # shellcheck disable=SC2329
        plugin_tx_enable_plugin() { printf 'active\n' > "${case_dir}/plugin"; }
        # shellcheck disable=SC2329
        plugin_tx_enable_previous_plugin() { plugin_tx_enable_plugin; }
        # shellcheck disable=SC2329
        plugin_tx_verify_plugin() { return 0; }
        # shellcheck disable=SC2329
        plugin_tx_verify_previous_objects() { return 0; }
        # shellcheck disable=SC2329
        plugin_tx_verify_previous_plugin() { return 0; }
        # shellcheck disable=SC2329
        plugin_tx_path_exists() { [[ -e "$1" ]]; }
        # shellcheck disable=SC2329
        plugin_tx_move() { mv "$1" "$2"; }

        if notifier_plugin_transaction \
            "${target}" "${stage}" "${backup}" "${failed}" \
            "${bundle_target}" "${bundle_stage}" "${bundle_backup}" "${bundle_failed}" \
            true true > "${case_dir}/stdout" 2> "${case_dir}/stderr"; then
            return 1
        fi
        [[ "$(<"${case_dir}/service")" == running ]] || return 1
        [[ "$(<"${case_dir}/plugin")" == active ]] || return 1
        [[ "$(<"${case_dir}/control")" == enabled ]] || return 1
        [[ -d "${stage}" && -f "${bundle_stage}" ]] || return 1
        [[ ! -e "${backup}" && ! -e "${bundle_backup}" ]] || return 1
        if [[ "${asymmetry}" == runtime-only ]]; then
            [[ "$(<"${target}/generation")" == old-runtime && ! -e "${bundle_target}" ]] \
                || return 1
        else
            [[ ! -e "${target}" && "$(<"${bundle_target}")" == old-bundle ]] \
                || return 1
        fi
    done
)

test_rollback_stops_service_after_enable_or_state_verification_failure() (
    transaction_library="${DEPLOY_DIR}/scripts/notifier-plugin-transaction.sh"
    # shellcheck source=/dev/null
    source "${transaction_library}"

    fixture="$(mktemp -d)"
    trap 'rm -rf "${fixture}"' EXIT
    for failure_mode in enable verify; do
        case_dir="${fixture}/${failure_mode}"
        target="${case_dir}/plugins/notifier"
        stage="${case_dir}/release/runtime-stage"
        backup="${case_dir}/release/runtime-backup"
        failed="${case_dir}/release/runtime-failed"
        bundle_target="${case_dir}/data/plugins/notifier.tar.gz"
        bundle_stage="${case_dir}/release/bundle-stage.tar.gz"
        bundle_backup="${case_dir}/release/bundle-backup.tar.gz"
        bundle_failed="${case_dir}/release/bundle-failed.tar.gz"
        mkdir -p "${target}" "${stage}" "$(dirname "${bundle_target}")"
        printf 'old-runtime\n' > "${target}/generation"
        printf 'new-runtime\n' > "${stage}/generation"
        printf 'old-bundle\n' > "${bundle_target}"
        printf 'new-bundle\n' > "${bundle_stage}"
        printf 'running\n' > "${case_dir}/service"
        printf 'active\n' > "${case_dir}/plugin"
        printf 'enabled\n' > "${case_dir}/control"
        printf '0\n' > "${case_dir}/enable-attempts"

        # shellcheck disable=SC2329
        plugin_tx_disable_control() { printf 'disabled\n' > "${case_dir}/control"; }
        # shellcheck disable=SC2329
        plugin_tx_disable_plugin() { printf 'inactive\n' > "${case_dir}/plugin"; }
        # shellcheck disable=SC2329
        plugin_tx_stop_service() { printf 'stopped\n' > "${case_dir}/service"; }
        # shellcheck disable=SC2329
        plugin_tx_prepare_targets() { return 0; }
        # shellcheck disable=SC2329
        plugin_tx_start_service() { printf 'running\n' > "${case_dir}/service"; }
        # shellcheck disable=SC2329
        plugin_tx_enable_plugin() {
            enable_attempts="$(<"${case_dir}/enable-attempts")"
            enable_attempts=$((enable_attempts + 1))
            printf '%s\n' "${enable_attempts}" > "${case_dir}/enable-attempts"
            if [[ "${failure_mode}" == enable && "${enable_attempts}" == 2 ]]; then
                printf 'enable-failed\n' > "${case_dir}/plugin"
                return 97
            fi
            printf 'active\n' > "${case_dir}/plugin"
        }
        # shellcheck disable=SC2329
        plugin_tx_enable_previous_plugin() { plugin_tx_enable_plugin; }
        # shellcheck disable=SC2329
        plugin_tx_verify_plugin() { return 93; }
        # shellcheck disable=SC2329
        plugin_tx_verify_previous_objects() {
            [[ "$(<"${target}/generation")" == old-runtime ]] \
                && [[ "$(<"${bundle_target}")" == old-bundle ]]
        }
        # shellcheck disable=SC2329
        plugin_tx_verify_previous_plugin() {
            [[ "${failure_mode}" != verify ]]
        }
        # shellcheck disable=SC2329
        plugin_tx_path_exists() { [[ -e "$1" ]]; }
        # shellcheck disable=SC2329
        plugin_tx_move() { mv "$1" "$2"; }

        set +e
        notifier_plugin_transaction \
            "${target}" "${stage}" "${backup}" "${failed}" \
            "${bundle_target}" "${bundle_stage}" "${bundle_backup}" "${bundle_failed}" \
            true true > "${case_dir}/stdout" 2> "${case_dir}/stderr"
        transaction_result=$?
        set -e
        [[ "${transaction_result}" == 70 ]] || return 1
        [[ "$(<"${case_dir}/service")" == stopped ]] || return 1
        [[ "$(<"${case_dir}/control")" == disabled ]] || return 1
        [[ "$(<"${target}/generation")" == old-runtime ]] || return 1
        [[ "$(<"${bundle_target}")" == old-bundle ]] || return 1
    done
)

test_rollback_stops_service_after_failed_start_attempt() (
    transaction_library="${DEPLOY_DIR}/scripts/notifier-plugin-transaction.sh"
    # shellcheck source=/dev/null
    source "${transaction_library}"

    fixture="$(mktemp -d)"
    trap 'rm -rf "${fixture}"' EXIT
    target="${fixture}/plugins/notifier"
    stage="${fixture}/release/runtime-stage"
    backup="${fixture}/release/runtime-backup"
    failed="${fixture}/release/runtime-failed"
    bundle_target="${fixture}/data/plugins/notifier.tar.gz"
    bundle_stage="${fixture}/release/bundle-stage.tar.gz"
    bundle_backup="${fixture}/release/bundle-backup.tar.gz"
    bundle_failed="${fixture}/release/bundle-failed.tar.gz"
    mkdir -p "${target}" "${stage}" "$(dirname "${bundle_target}")"
    printf 'old-runtime\n' > "${target}/generation"
    printf 'new-runtime\n' > "${stage}/generation"
    printf 'old-bundle\n' > "${bundle_target}"
    printf 'new-bundle\n' > "${bundle_stage}"
    printf 'running\n' > "${fixture}/service"
    printf 'active\n' > "${fixture}/plugin"
    printf 'enabled\n' > "${fixture}/control"
    printf '0\n' > "${fixture}/start-attempts"
    printf '0\n' > "${fixture}/stop-attempts"

    # shellcheck disable=SC2329
    plugin_tx_disable_control() { printf 'disabled\n' > "${fixture}/control"; }
    # shellcheck disable=SC2329
    plugin_tx_disable_plugin() { printf 'inactive\n' > "${fixture}/plugin"; }
    # shellcheck disable=SC2329
    plugin_tx_stop_service() {
        attempts="$(<"${fixture}/stop-attempts")"
        attempts=$((attempts + 1))
        printf '%s\n' "${attempts}" > "${fixture}/stop-attempts"
        printf 'stopped\n' > "${fixture}/service"
    }
    # shellcheck disable=SC2329
    plugin_tx_prepare_targets() { return 0; }
    # shellcheck disable=SC2329
    plugin_tx_start_service() {
        attempts="$(<"${fixture}/start-attempts")"
        attempts=$((attempts + 1))
        printf '%s\n' "${attempts}" > "${fixture}/start-attempts"
        printf 'running\n' > "${fixture}/service"
        if ((attempts == 2)); then
            return 99
        fi
    }
    # shellcheck disable=SC2329
    plugin_tx_enable_plugin() { printf 'active\n' > "${fixture}/plugin"; }
    # shellcheck disable=SC2329
    plugin_tx_enable_previous_plugin() { printf 'active\n' > "${fixture}/plugin"; }
    # shellcheck disable=SC2329
    plugin_tx_verify_plugin() { return 93; }
    # shellcheck disable=SC2329
    plugin_tx_verify_previous_objects() {
        [[ "$(<"${target}/generation")" == old-runtime ]] \
            && [[ "$(<"${bundle_target}")" == old-bundle ]]
    }
    # shellcheck disable=SC2329
    plugin_tx_verify_previous_plugin() { return 0; }
    # shellcheck disable=SC2329
    plugin_tx_path_exists() { [[ -e "$1" ]]; }
    # shellcheck disable=SC2329
    plugin_tx_move() { mv "$1" "$2"; }

    set +e
    notifier_plugin_transaction \
        "${target}" "${stage}" "${backup}" "${failed}" \
        "${bundle_target}" "${bundle_stage}" "${bundle_backup}" "${bundle_failed}" \
        true true > "${fixture}/stdout" 2> "${fixture}/stderr"
    transaction_result=$?
    set -e
    [[ "${transaction_result}" == 70 ]] || return 1
    grep -F 'service_start' "${fixture}/stderr" >/dev/null || return 1
    [[ "$(<"${fixture}/start-attempts")" == 2 ]] || return 1
    [[ "$(<"${fixture}/stop-attempts")" == 3 ]] || return 1
    [[ "$(<"${fixture}/service")" == stopped ]] || return 1
    [[ "$(<"${fixture}/control")" == disabled ]] || return 1
    [[ "$(<"${target}/generation")" == old-runtime ]] || return 1
    [[ "$(<"${bundle_target}")" == old-bundle ]]
)

test_rollback_verifies_restored_pair_before_service_start() (
    transaction_library="${DEPLOY_DIR}/scripts/notifier-plugin-transaction.sh"
    # shellcheck source=/dev/null
    source "${transaction_library}"

    fixture="$(mktemp -d)"
    trap 'rm -rf "${fixture}"' EXIT
    target="${fixture}/plugins/notifier"
    stage="${fixture}/release/runtime-stage"
    backup="${fixture}/release/runtime-backup"
    failed="${fixture}/release/runtime-failed"
    bundle_target="${fixture}/data/plugins/notifier.tar.gz"
    bundle_stage="${fixture}/release/bundle-stage.tar.gz"
    bundle_backup="${fixture}/release/bundle-backup.tar.gz"
    bundle_failed="${fixture}/release/bundle-failed.tar.gz"
    mkdir -p "${target}" "${stage}" "$(dirname "${bundle_target}")"
    printf 'old-runtime\n' > "${target}/generation"
    printf 'new-runtime\n' > "${stage}/generation"
    printf 'old-bundle\n' > "${bundle_target}"
    printf 'new-bundle\n' > "${bundle_stage}"
    printf 'running\n' > "${fixture}/service"
    printf 'active\n' > "${fixture}/plugin"
    printf 'enabled\n' > "${fixture}/control"

    # shellcheck disable=SC2329
    plugin_tx_disable_control() { printf 'disabled\n' > "${fixture}/control"; }
    # shellcheck disable=SC2329
    plugin_tx_disable_plugin() { printf 'inactive\n' > "${fixture}/plugin"; }
    # shellcheck disable=SC2329
    plugin_tx_stop_service() { printf 'stopped\n' > "${fixture}/service"; }
    # shellcheck disable=SC2329
    plugin_tx_prepare_targets() { return 0; }
    # shellcheck disable=SC2329
    plugin_tx_start_service() { printf 'running\n' > "${fixture}/service"; }
    # shellcheck disable=SC2329
    plugin_tx_enable_plugin() { printf 'active\n' > "${fixture}/plugin"; }
    # shellcheck disable=SC2329
    plugin_tx_enable_previous_plugin() { plugin_tx_enable_plugin; }
    # shellcheck disable=SC2329
    plugin_tx_verify_plugin() { return 93; }
    # shellcheck disable=SC2329
    plugin_tx_verify_previous_objects() { return 98; }
    # shellcheck disable=SC2329
    plugin_tx_verify_previous_plugin() { return 0; }
    # shellcheck disable=SC2329
    plugin_tx_path_exists() { [[ -e "$1" ]]; }
    # shellcheck disable=SC2329
    plugin_tx_move() { mv "$1" "$2"; }

    set +e
    notifier_plugin_transaction \
        "${target}" "${stage}" "${backup}" "${failed}" \
        "${bundle_target}" "${bundle_stage}" "${bundle_backup}" "${bundle_failed}" \
        true true > "${fixture}/stdout" 2> "${fixture}/stderr"
    transaction_result=$?
    set -e
    [[ "${transaction_result}" == 70 ]] || return 1
    grep -F 'object_verify' "${fixture}/stderr" >/dev/null || return 1
    [[ "$(<"${fixture}/service")" == stopped ]] || return 1
    [[ "$(<"${fixture}/control")" == disabled ]]
)

test_rollback_rechecks_pair_after_mattermost_synchronization() (
    transaction_library="${DEPLOY_DIR}/scripts/notifier-plugin-transaction.sh"
    # shellcheck source=/dev/null
    source "${transaction_library}"

    fixture="$(mktemp -d)"
    trap 'rm -rf "${fixture}"' EXIT
    target="${fixture}/plugins/notifier"
    stage="${fixture}/release/runtime-stage"
    backup="${fixture}/release/runtime-backup"
    failed="${fixture}/release/runtime-failed"
    bundle_target="${fixture}/data/plugins/notifier.tar.gz"
    bundle_stage="${fixture}/release/bundle-stage.tar.gz"
    bundle_backup="${fixture}/release/bundle-backup.tar.gz"
    bundle_failed="${fixture}/release/bundle-failed.tar.gz"
    mkdir -p "${target}" "${stage}" "$(dirname "${bundle_target}")"
    printf 'old-runtime\n' > "${target}/generation"
    printf 'new-runtime\n' > "${stage}/generation"
    printf 'old-bundle\n' > "${bundle_target}"
    printf 'new-bundle\n' > "${bundle_stage}"
    printf 'running\n' > "${fixture}/service"
    printf 'active\n' > "${fixture}/plugin"
    printf 'enabled\n' > "${fixture}/control"
    printf '0\n' > "${fixture}/start-attempts"

    # shellcheck disable=SC2329
    plugin_tx_disable_control() { printf 'disabled\n' > "${fixture}/control"; }
    # shellcheck disable=SC2329
    plugin_tx_disable_plugin() { printf 'inactive\n' > "${fixture}/plugin"; }
    # shellcheck disable=SC2329
    plugin_tx_stop_service() { printf 'stopped\n' > "${fixture}/service"; }
    # shellcheck disable=SC2329
    plugin_tx_prepare_targets() { return 0; }
    # shellcheck disable=SC2329
    plugin_tx_start_service() {
        attempts="$(<"${fixture}/start-attempts")"
        attempts=$((attempts + 1))
        printf '%s\n' "${attempts}" > "${fixture}/start-attempts"
        printf 'running\n' > "${fixture}/service"
        if ((attempts == 2)); then
            rm "${bundle_target}"
        fi
    }
    # shellcheck disable=SC2329
    plugin_tx_enable_plugin() { printf 'active\n' > "${fixture}/plugin"; }
    # shellcheck disable=SC2329
    plugin_tx_enable_previous_plugin() { plugin_tx_enable_plugin; }
    # shellcheck disable=SC2329
    plugin_tx_verify_plugin() { return 93; }
    # shellcheck disable=SC2329
    plugin_tx_verify_previous_objects() {
        [[ "$(<"${target}/generation")" == old-runtime \
            && -f "${bundle_target}" \
            && "$(<"${bundle_target}")" == old-bundle ]]
    }
    # shellcheck disable=SC2329
    plugin_tx_verify_previous_plugin() { return 0; }
    # shellcheck disable=SC2329
    plugin_tx_path_exists() { [[ -e "$1" ]]; }
    # shellcheck disable=SC2329
    plugin_tx_move() { mv "$1" "$2"; }

    set +e
    notifier_plugin_transaction \
        "${target}" "${stage}" "${backup}" "${failed}" \
        "${bundle_target}" "${bundle_stage}" "${bundle_backup}" "${bundle_failed}" \
        true true > "${fixture}/stdout" 2> "${fixture}/stderr"
    transaction_result=$?
    set -e
    [[ "${transaction_result}" == 70 ]] || return 1
    grep -F 'object_post_start_verify' "${fixture}/stderr" >/dev/null || return 1
    [[ "$(<"${fixture}/service")" == stopped ]] || return 1
    [[ "$(<"${fixture}/control")" == disabled ]]
)

test_symlink_referents_unchanged() (
    # shellcheck source=../scripts/common.sh
    source "${DEPLOY_DIR}/scripts/common.sh"
    declare -F notifier_assert_no_symlink_components >/dev/null || return 1
    SUDO_COMMAND=(env)

    fixture="$(mktemp -d)"
    trap 'rm -rf "${fixture}"' EXIT
    for child in control mailer release; do
        root="${fixture}/${child}/threadhub"
        referent="${fixture}/${child}/referent"
        mkdir -p "${root}/notifier" "${referent}"
        chmod 0711 "${referent}"
        printf 'do-not-change-%s\n' "${child}" > "${referent}/marker"
        before_identity="$(portable_identity "${referent}")"
        before_hash="$(sha256_file "${referent}/marker")"
        ln -s "${referent}" "${root}/notifier/${child}"

        if notifier_assert_no_symlink_components "${root}" >/dev/null 2>&1; then
            return 1
        fi
        [[ "$(portable_identity "${referent}")" == "${before_identity}" ]] || return 1
        [[ "$(sha256_file "${referent}/marker")" == "${before_hash}" ]] || return 1
    done
)

test_mattermost_plugin_path_symlinks_are_rejected_without_mutation() (
    # shellcheck source=../scripts/common.sh
    # shellcheck disable=SC2031 # each test function executes in its own subshell
    source "${DEPLOY_DIR}/scripts/common.sh"
    declare -F notifier_assert_no_symlink_components >/dev/null || return 1
    SUDO_COMMAND=(env)

    fixture="$(mktemp -d)"
    trap 'rm -rf "${fixture}"' EXIT
    for relative in mattermost mattermost/data mattermost/data/plugins mattermost/plugins; do
        case_name="${relative//\//-}"
        root="${fixture}/${case_name}/threadhub"
        link_path="${root}/${relative}"
        referent="${fixture}/${case_name}/referent"
        mkdir -p "$(dirname "${link_path}")" "${root}/notifier" "${referent}"
        printf 'do-not-change-%s\n' "${case_name}" > "${referent}/marker"
        before_identity="$(portable_identity "${referent}")"
        before_hash="$(sha256_file "${referent}/marker")"
        ln -s "${referent}" "${link_path}"

        if notifier_assert_no_symlink_components "${root}" >/dev/null 2>&1; then
            return 1
        fi
        [[ "$(portable_identity "${referent}")" == "${before_identity}" ]] || return 1
        [[ "$(sha256_file "${referent}/marker")" == "${before_hash}" ]] || return 1
    done
)

test_writable_notifier_parent_is_rejected_without_mutation() (
    # shellcheck source=../scripts/common.sh
    # shellcheck disable=SC2031 # each test function executes in its own subshell
    source "${DEPLOY_DIR}/scripts/common.sh"

    fixture="$(mktemp -d)"
    trap 'rm -rf "${fixture}"' EXIT
    parent="${fixture}/threadhub"
    referent="${fixture}/referent"
    mkdir -p "${parent}" "${referent}"
    printf 'do-not-change-parent-policy\n' > "${referent}/marker"
    ln -s "${referent}" "${parent}/notifier"
    before_identity="$(portable_identity "${referent}")"
    before_hash="$(sha256_file "${referent}/marker")"

    # shellcheck disable=SC2329 # invoked through the SUDO_COMMAND callback array
    notifier_test_command() {
        if [[ "$1" == stat && "$2" == -c ]]; then
            requested_format="$3"
            requested_path="$4"
            actual_mode="$(portable_identity "${requested_path}")"
            actual_mode="${actual_mode##*:}"
            case "${requested_format}" in
                '%u:%g') printf '0:0\n' ;;
                '%u:%g:%a') printf '0:0:%s\n' "${actual_mode}" ;;
                *) return 97 ;;
            esac
            return
        fi
        command "$@"
    }
    SUDO_COMMAND=(notifier_test_command)

    for unsafe_mode in 0777 0775; do
        chmod "${unsafe_mode}" "${parent}"
        if notifier_assert_existing_directory_policy "${parent}" 0 0 750; then
            return 1
        fi
        [[ "$(portable_identity "${referent}")" == "${before_identity}" ]] || return 1
        [[ "$(sha256_file "${referent}/marker")" == "${before_hash}" ]] || return 1
    done
)

test_deploy_validates_notifier_layout_top_down() (
    # shellcheck disable=SC2031 # each test function executes in its own subshell
    deploy_script="${DEPLOY_DIR}/scripts/deploy.sh"
    # shellcheck disable=SC2031 # each test function executes in its own subshell
    layout_script="${DEPLOY_DIR}/scripts/data-layout.sh"
    # Match literal deployment expressions; expansion is not intended.
    # shellcheck disable=SC2016
    grep -F 'source "${SCRIPT_DIR}/data-layout.sh"' "${deploy_script}" >/dev/null || return 1
    # shellcheck disable=SC2016
    grep -F 'prepare_threadhub_data_layout "${data_root}"' "${deploy_script}" >/dev/null || return 1
    awk '
        index($0, "install -d -o root -g root -m 0750 \"${data_root}\"") { if (state != 0) exit 1; state = 1; next }
        state == 1 && index($0, "data_layout_validate_root \"${data_root}\"") { state = 2; next }
        state == 2 && index($0, "install -d -o root -g root -m 0750 \"${notifier_root}\"") { state = 3; next }
        state == 3 && index($0, "data_layout_validate_root \"${data_root}\"") { state = 4; next }
        state == 4 && index($0, "${notifier_root}/control") { state = 5; next }
        state == 5 && index($0, "data_layout_validate_root \"${data_root}\"") { state = 6; next }
        state == 6 && index($0, "${notifier_root}/mailer") { state = 7; next }
        state == 7 && index($0, "data_layout_validate_root \"${data_root}\"") { state = 8; next }
        state == 8 && index($0, "${notifier_root}/release") { state = 9; next }
        state == 9 && index($0, "data_layout_validate_root \"${data_root}\"") { state = 10; next }
        END { exit(state == 10 ? 0 : 1) }
    ' "${layout_script}"
)

test_deploy_creates_and_validates_filestore_plugin_directory() (
    # shellcheck disable=SC2031 # each test function executes in its own subshell
    deploy_script="${DEPLOY_DIR}/scripts/deploy.sh"
    # shellcheck disable=SC2031 # each test function executes in its own subshell
    layout_script="${DEPLOY_DIR}/scripts/data-layout.sh"
    # shellcheck disable=SC2016
    grep -F 'prepare_threadhub_data_layout "${data_root}"' \
        "${deploy_script}" >/dev/null || return 1
    # Match literal deployment expressions; expansion is not intended.
    # shellcheck disable=SC2016,SC2031
    grep -F '"${mattermost_root}/data/plugins"' \
        "${layout_script}" >/dev/null || return 1

    # Existing production plugin files are transaction inputs. A repeated
    # deploy must not normalize their metadata before the installer captures
    # and verifies the prior runtime/filestore pair.
    # shellcheck disable=SC2016
    if grep -F 'chown -R 2000:2000 "${mattermost_root}"' \
        "${layout_script}" >/dev/null \
        || grep -F 'chmod -R u=rwX,g=rX,o= "${mattermost_root}"' \
            "${layout_script}" >/dev/null; then
        return 1
    fi

    # shellcheck disable=SC2016
    for required in \
        'mattermost_mutable_paths=(' \
        '"${mattermost_root}/config"' \
        '"${mattermost_root}/data"' \
        '"${mattermost_root}/logs"' \
        '"${mattermost_root}/client/plugins"' \
        '"${mattermost_root}/bleve-indexes"' \
        'chown 2000:2000 "${mattermost_root}" "${mattermost_root}/plugins"' \
        'chmod 0750 "${mattermost_root}" "${mattermost_root}/plugins"' \
        'chown -R 2000:2000 "${mattermost_mutable_paths[@]}"' \
        'chmod -R u=rwX,g=rX,o= "${mattermost_mutable_paths[@]}"'; do
        grep -F "${required}" "${layout_script}" >/dev/null || return 1
    done
)

test_validation_requires_shared_paired_plugin_install_contract() (
    # shellcheck disable=SC2031 # each test function executes in its own subshell
    validation="${DEPLOY_DIR}/scripts/validate.sh"
    # Match literal validation expressions; expansion is not intended.
    # shellcheck disable=SC2016
    for required in \
        'require_file "${SCRIPT_DIR}/notifier-plugin-files.sh"' \
        'notifier_plugin_stage_pair' \
        'bundle_target="${filestore_plugins_root}/${plugin_id}.tar.gz"' \
        'notifier_plugin_transaction'; do
        grep -F "${required}" "${validation}" >/dev/null || return 1
    done
)

test_compose_v531_canonical_model() (
    # shellcheck source=../scripts/common.sh
    # shellcheck disable=SC2031 # each test function executes in its own subshell
    source "${DEPLOY_DIR}/scripts/common.sh"
    command -v jq >/dev/null || return 1

    fixture="$(mktemp -d)"
    trap 'rm -rf "${fixture}"' EXIT
    compose_model="${fixture}/compose-v5.3.1.json"
    fake_bin="${fixture}/bin"
    mkdir "${fake_bin}"
    builder_image="$(env_value GO_BUILDER_IMAGE_REPOSITORY "${VERSIONS_FILE}"):$(env_value GO_BUILDER_IMAGE_TAG "${VERSIONS_FILE}")@$(env_value GO_BUILDER_IMAGE_DIGEST "${VERSIONS_FILE}")"
    notifier_version="$(env_value NOTIFIER_VERSION "${VERSIONS_FILE}")"

    jq -n \
        --arg builder "${builder_image}" \
        --arg context "${REPOSITORY_ROOT}/notifier" \
        --arg image "threadhub/notifier-mailer:${notifier_version}" '
        {
          services: {
            postgres: {networks:{database:null}},
            mattermost: {
              environment: {
                MM_PLUGINSETTINGS_ENABLE:"true",
                MM_PLUGINSETTINGS_ENABLEUPLOADS:"false",
                MM_PLUGINSETTINGS_ENABLEMARKETPLACE:"false",
                MM_PLUGINSETTINGS_ENABLEREMOTEMARKETPLACE:"false",
                MM_PLUGINSETTINGS_AUTOMATICPREPACKAGEDPLUGINS:"false",
                MM_EMAILSETTINGS_SENDEMAILNOTIFICATIONS:"false",
                MM_EMAILSETTINGS_SENDPUSHNOTIFICATIONS:"false",
                MM_SERVICESETTINGS_ENABLEINCOMINGWEBHOOKS:"false",
                MM_SERVICESETTINGS_ENABLEOUTGOINGWEBHOOKS:"false",
                MM_SERVICESETTINGS_ENABLEBOTACCOUNTCREATION:"false",
                MM_SERVICESETTINGS_ENABLEUSERACCESSTOKENS:"false",
                THREADHUB_DOMAIN:"threadhub.internal",
                NOTIFIER_MAILER_URL:"http://threadhub-mailer:8080",
                NOTIFIER_HMAC_SECRET:("0" * 64),
                NOTIFIER_CONTROL_FILE:"/run/threadhub-notifier/state.json",
                NOTIFIER_POLL_EVERY:"1s"
              },
              group_add:["3000"],
              networks:{database:null,notifier:null,outbound:null},
              volumes:[
                {type:"bind",source:"/srv/threadhub/notifier/control",target:"/run/threadhub-notifier",read_only:true,bind:{}}
              ]
            },
            "threadhub-mailer": {
              image:$image,
              build:{context:$context,dockerfile:"Dockerfile",args:{GO_BUILDER_IMAGE:$builder},target:"mailer"},
              platform:"linux/amd64",
              user:"65532:65532",
              group_add:["3000"],
              read_only:true,
              cap_drop:["ALL"],
              security_opt:["no-new-privileges:true"],
              networks:{notifier:null,outbound:null},
              volumes:[
                {type:"bind",source:"/srv/threadhub/notifier/mailer",target:"/var/lib/threadhub-notifier",bind:{}},
                {type:"bind",source:"/srv/threadhub/notifier/control",target:"/run/threadhub-notifier",read_only:true,bind:{}}
              ],
              healthcheck:{test:["CMD","/threadhub-mailer","healthcheck"],timeout:"5s",interval:"10s",retries:10,start_period:"30s"},
              logging:{driver:"json-file",options:{"max-file":"3","max-size":"10m"}},
              environment: {
                NOTIFIER_CONTROL_FILE:"/run/threadhub-notifier/state.json",
                NOTIFIER_HMAC_SECRET:("0" * 64),
                NOTIFIER_LISTEN_ADDRESS:":8080",
                NOTIFIER_QUEUE_PATH:"/var/lib/threadhub-notifier/queue.db",
                NOTIFIER_RATE_PER_MINUTE:"10",
                SMTP_FEEDBACK_NAME:"ThreadHub",
                SMTP_FROM_ADDRESS:"no-reply@threadhub.internal",
                SMTP_PASSWORD:"fixture_password",
                SMTP_PORT:"587",
                SMTP_REPLY_TO_ADDRESS:"admin@threadhub.internal",
                SMTP_SERVER:"smtp.email.ap-singapore-1.oci.oraclecloud.com",
                SMTP_USERNAME:"fixture_user",
                THREADHUB_DOMAIN:"threadhub.internal"
              }
            }
          },
          networks:{database:{internal:true},notifier:{internal:true},outbound:{}}
        }
    ' > "${compose_model}"

    # The single-quoted expressions are emitted into the fake Docker script.
    # shellcheck disable=SC2016
    printf '%s\n' \
        '#!/usr/bin/env bash' \
        'set -Eeuo pipefail' \
        '[[ "${1:-}" == compose ]] || exit 97' \
        'shift' \
        'if [[ "${1:-}" == version ]]; then printf "Docker Compose version v5.3.1\\n"; exit 0; fi' \
        'case " $* " in' \
        '  *" config --format json "*) printf "json\\n" >> "${THREADHUB_TEST_COMPOSE_TRACE}"; /bin/cat "${THREADHUB_TEST_COMPOSE_JSON}" ;;' \
        '  *" config --quiet "*) printf "quiet\\n" >> "${THREADHUB_TEST_COMPOSE_TRACE}"; exit 0 ;;' \
        '  *) exit 98 ;;' \
        'esac' \
        > "${fake_bin}/docker"
    chmod 0700 "${fake_bin}/docker"

    PATH="${fake_bin}:${PATH}" \
        THREADHUB_TEST_COMPOSE_JSON="${compose_model}" \
        THREADHUB_TEST_COMPOSE_TRACE="${fixture}/compose.trace" \
        /bin/bash "${DEPLOY_DIR}/scripts/validate.sh" \
        > "${fixture}/output" 2>&1
    [[ "$(<"${fixture}/compose.trace")" == $'quiet\njson' ]]
)

test_no_validator_does_not_claim_success() (
    fixture="$(mktemp -d)"
    trap 'rm -rf "${fixture}"' EXIT
    command_dir="${fixture}/bin"
    mkdir "${command_dir}"
    for command_name in bash dirname awk grep mktemp rm sed chmod; do
        command_path="$(command -v "${command_name}")"
        ln -s "${command_path}" "${command_dir}/${command_name}"
    done

    set +e
    # shellcheck disable=SC2031 # each test function executes in its own subshell
    PATH="${command_dir}" /bin/bash "${DEPLOY_DIR}/scripts/validate.sh" \
        > "${fixture}/output" 2>&1
    result=$?
    set -e
    ((result != 0)) || return 1
    if grep -F 'Notifier Compose isolation, mounts, settings and hardening are valid' \
        "${fixture}/output" >/dev/null; then
        return 1
    fi
)

if test_transaction_rollback_after_backup; then
    pass "plugin transaction restores old target and runtime state after stage rename failure"
else
    fail "plugin transaction restores old target and runtime state after stage rename failure"
fi

if test_transaction_retries_control_disable_during_rollback; then
    pass "plugin rollback best-effort disables control after an initial disable failure"
else
    fail "plugin rollback best-effort disables control after an initial disable failure"
fi

if test_transaction_reports_rollback_failure_and_continues_restore; then
    pass "plugin rollback reports a failed step and continues restoring other state"
else
    fail "plugin rollback reports a failed step and continues restoring other state"
fi

if test_transaction_restores_runtime_and_filestore_after_activation_failure; then
    pass "plugin transaction restores runtime tree and filestore bundle after activation failure"
else
    fail "plugin transaction restores runtime tree and filestore bundle after activation failure"
fi

if test_transaction_restores_pair_after_bundle_publish_failure; then
    pass "plugin transaction restores both objects after a partial filestore publish failure"
else
    fail "plugin transaction restores both objects after a partial filestore publish failure"
fi

if test_transaction_keeps_service_stopped_when_restore_loses_race; then
    pass "plugin rollback keeps the service stopped when a target race blocks restoration"
else
    fail "plugin rollback restarts the service after a target race blocks restoration"
fi

if test_transaction_rejects_fresh_target_publish_race; then
    pass "plugin transaction rejects a fresh target that wins the no-clobber publish race"
else
    fail "plugin transaction accepts a fresh target that wins the no-clobber publish race"
fi

if test_transaction_rejects_asymmetric_prior_pair_before_mutation; then
    pass "plugin transaction rejects asymmetric prior objects before mutation"
else
    fail "plugin transaction mutates an asymmetric prior plugin pair"
fi

if test_rollback_stops_service_after_enable_or_state_verification_failure; then
    pass "plugin rollback stops Mattermost after enable or state verification failure"
else
    fail "plugin rollback leaves Mattermost running after enable or state verification failure"
fi

if test_rollback_stops_service_after_failed_start_attempt; then
    pass "plugin rollback compensates every failed Mattermost start attempt"
else
    fail "plugin rollback can leave Mattermost running after a failed start attempt"
fi

if test_rollback_verifies_restored_pair_before_service_start; then
    pass "plugin rollback verifies the restored pair before restarting Mattermost"
else
    fail "plugin rollback starts Mattermost without verifying the restored pair"
fi

if test_rollback_rechecks_pair_after_mattermost_synchronization; then
    pass "plugin rollback rechecks the restored pair after Mattermost synchronization"
else
    fail "plugin rollback trusts a restored pair that Mattermost deletes or replaces"
fi

if test_symlink_referents_unchanged; then
    pass "notifier host layout rejects child symlinks without changing referents"
else
    fail "notifier host layout rejects child symlinks without changing referents"
fi

if test_mattermost_plugin_path_symlinks_are_rejected_without_mutation; then
    pass "Mattermost runtime and filestore plugin paths reject symlinks without changing referents"
else
    fail "Mattermost runtime and filestore plugin paths reject symlinks without changing referents"
fi

if test_writable_notifier_parent_is_rejected_without_mutation; then
    pass "notifier parent policy rejects root-owned writable directories without mutating referents"
else
    fail "notifier parent policy rejects root-owned writable directories without mutating referents"
fi

if test_deploy_validates_notifier_layout_top_down; then
    pass "deployment validates each notifier parent before privileged child creation"
else
    fail "deployment validates each notifier parent before privileged child creation"
fi

if test_deploy_creates_and_validates_filestore_plugin_directory; then
    pass "deployment creates and validates the exact Mattermost filestore plugin directory"
else
    fail "deployment creates and validates the exact Mattermost filestore plugin directory"
fi

if test_validation_requires_shared_paired_plugin_install_contract; then
    pass "validation requires the shared paired runtime and filestore installer contract"
else
    fail "validation does not require the shared paired runtime and filestore installer contract"
fi

if test_compose_v531_canonical_model; then
    pass "Docker Compose v5.3.1 canonical model accepts omitted RW read_only and exact Mailer metadata"
else
    fail "Docker Compose v5.3.1 canonical model accepts omitted RW read_only and exact Mailer metadata"
fi

if test_no_validator_does_not_claim_success; then
    pass "missing Compose and Ruby validators fails before a security-success claim"
else
    fail "missing Compose and Ruby validators fails before a security-success claim"
fi

((failures == 0))
