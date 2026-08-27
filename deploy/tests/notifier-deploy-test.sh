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
    mkdir -p "${target}" "${stage}"
    printf 'old\n' > "${target}/generation"
    printf 'new\n' > "${stage}/generation"
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
    plugin_tx_start_service() { printf 'running\n' > "${fixture}/service"; }
    # shellcheck disable=SC2329 # transaction callback fixture
    plugin_tx_enable_plugin() { printf 'active\n' > "${fixture}/plugin"; }
    # shellcheck disable=SC2329 # transaction callback fixture
    plugin_tx_verify_plugin() { [[ "$(<"${fixture}/plugin")" == active ]]; }
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
        "${target}" "${stage}" "${backup}" "${failed}" true true \
        > "${fixture}/stdout" 2> "${fixture}/stderr"; then
        return 1
    fi
    if [[ ! -f "${target}/generation" || "$(<"${target}/generation")" != old ]] \
        || [[ "$(<"${fixture}/service")" != running ]] \
        || [[ "$(<"${fixture}/plugin")" != active ]] \
        || [[ "$(<"${fixture}/control")" != disabled ]] \
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
    mkdir -p "${target}" "${stage}"
    printf 'old\n' > "${target}/generation"
    printf 'new\n' > "${stage}/generation"
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
    plugin_tx_start_service() { printf 'running\n' > "${fixture}/service"; }
    # shellcheck disable=SC2329 # transaction callback fixture
    plugin_tx_enable_plugin() { printf 'active\n' > "${fixture}/plugin"; }
    # shellcheck disable=SC2329 # transaction callback fixture
    plugin_tx_verify_plugin() { [[ "$(<"${fixture}/plugin")" == active ]]; }
    # shellcheck disable=SC2329 # transaction callback fixture
    plugin_tx_verify_previous_plugin() { [[ "$(<"${fixture}/plugin")" == active ]]; }
    # shellcheck disable=SC2329 # transaction callback fixture
    plugin_tx_path_exists() { [[ -e "$1" ]]; }
    # shellcheck disable=SC2329 # transaction callback fixture
    plugin_tx_move() { mv "$1" "$2"; }

    if notifier_plugin_transaction \
        "${target}" "${stage}" "${backup}" "${failed}" true true \
        > "${fixture}/stdout" 2> "${fixture}/stderr"; then
        return 1
    fi
    [[ "$(<"${fixture}/control")" == disabled ]] || return 1
    [[ "$(<"${fixture}/disable-attempts")" == 2 ]] || return 1
    [[ -f "${target}/generation" && "$(<"${target}/generation")" == old ]] || return 1
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
    mkdir -p "${target}" "${stage}"
    printf 'old\n' > "${target}/generation"
    printf 'new\n' > "${stage}/generation"
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
    plugin_tx_start_service() { printf 'running\n' > "${fixture}/service"; }
    # shellcheck disable=SC2329 # transaction callback fixture
    plugin_tx_enable_plugin() { printf 'active\n' > "${fixture}/plugin"; }
    # shellcheck disable=SC2329 # transaction callback fixture
    plugin_tx_verify_plugin() { [[ "$(<"${fixture}/plugin")" == active ]]; }
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
        "${target}" "${stage}" "${backup}" "${failed}" true true \
        > "${fixture}/stdout" 2> "${fixture}/stderr"
    transaction_result=$?
    set -e
    [[ "${transaction_result}" == 70 ]] || return 1
    grep -F 'rollback is incomplete (control_disable)' "${fixture}/stderr" >/dev/null \
        || return 1
    [[ -f "${target}/generation" && "$(<"${target}/generation")" == old ]] || return 1
    [[ "$(<"${fixture}/service")" == running ]] || return 1
    [[ "$(<"${fixture}/plugin")" == active ]] || return 1
    [[ "$(<"${fixture}/control")" == disabled ]] || return 1
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

if test_symlink_referents_unchanged; then
    pass "notifier host layout rejects child symlinks without changing referents"
else
    fail "notifier host layout rejects child symlinks without changing referents"
fi

if test_no_validator_does_not_claim_success; then
    pass "missing Compose and Ruby validators fails before a security-success claim"
else
    fail "missing Compose and Ruby validators fails before a security-success claim"
fi

((failures == 0))
