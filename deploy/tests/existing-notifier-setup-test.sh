#!/usr/bin/env bash

# Tests intentionally replace setup hooks that are dispatched dynamically.
# shellcheck disable=SC2034,SC2329

set -Eeuo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_DEPLOY_DIR="$(cd "${TEST_DIR}/.." && pwd)"
SETUP_SCRIPT="${TEST_DEPLOY_DIR}/scripts/existing-notifier-setup.sh"
failures=0

fail() { printf 'not ok - %s\n' "$1" >&2; failures=$((failures + 1)); }
pass() { printf 'ok - %s\n' "$1"; }
run_test() { if "$2"; then pass "$1"; else fail "$1"; fi; }

report_setup_failure() {
    printf '%s\n' 'setup call trace:' >&2
    sed -n '1,80p' "${calls}" >&2
    printf '%s\n' 'setup output:' >&2
    sed -n '1,80p' "${output}" >&2
}

setup_fixture_privileged() {
    local command_name="$1"
    shift
    local filtered=()
    local path uid=0 gid=0

    if [[ "${command_name}" == stat && "${1:-}" == -c && "${2:-}" == '%u:%g:%a' ]]; then
        path="$3"
        case "${path}" in
            */control) gid=3000 ;;
            */mailer) uid=65532; gid=65532 ;;
            */mattermost-data|*/mattermost-data/plugins) uid=2000; gid=2000 ;;
        esac
        printf '%s:%s:%s\n' "${uid}" "${gid}" "$(portable_mode "${path}")"
        return
    fi
    if [[ "${command_name}" == install ]]; then
        while (($# > 0)); do
            case "$1" in
                -o|-g) shift 2 ;;
                *) filtered+=("$1"); shift ;;
            esac
        done
        command install "${filtered[@]}"
        return
    fi
    if [[ "${command_name}" == ln ]]; then
        while (($# > 0)); do
            case "$1" in -T|--) shift ;; *) filtered+=("$1"); shift ;; esac
        done
        command ln "${filtered[@]}"
        return
    fi
    if [[ "${command_name}" == chown ]]; then
        return 0
    fi
    command "${command_name}" "$@"
}

portable_mode() {
    if stat -c '%a' "$1" >/dev/null 2>&1; then stat -c '%a' "$1"; else stat -f '%Lp' "$1"; fi
}

prepare_setup_fixture() {
    fixture="$(mktemp -d)"
    runtime_root="${fixture}/runtime"
    control_file="${runtime_root}/control/state.json"
    calls="${fixture}/calls"
    output="${fixture}/output"
    config="${fixture}/existing-notifier.env"
    : > "${calls}"
    printf 'protected fixture\n' > "${config}"
    chmod 0600 "${config}"
    THREADHUB_EXISTING_NOTIFIER_ENV_FILE="${config}"
    export THREADHUB_EXISTING_NOTIFIER_ENV_FILE
    EXISTING_NOTIFIER_ENV_FILE="${config}"

    existing_notifier_setup_validate_config() { printf 'config\n' >> "${calls}"; }
    existing_notifier_setup_preflight() {
        printf 'preflight\n' >> "${calls}"
        [[ "${FIXTURE_FAIL_STEP:-}" != preflight ]] || return 20
    }
    existing_notifier_setup_prepare_runtime() {
        printf 'prepare-runtime\n' >> "${calls}"
        mkdir -p "${runtime_root}/control"
    }
    existing_notifier_setup_record_rollback_capture() {
        printf 'rollback-capture\n' >> "${calls}"
    }
    existing_notifier_setup_write_disabled_control() {
        printf 'write-disabled-control\n' >> "${calls}"
        printf '%s\n' '{"enabled":false,"delivery_enabled":false,"mode":"all_channels","channel_ids":[],"activated_at":0}' \
            > "${control_file}"
    }
    existing_notifier_setup_build_artifacts() { printf 'build-artifacts\n' >> "${calls}"; }
    existing_notifier_setup_write_override() { printf 'write-override\n' >> "${calls}"; }
    existing_notifier_setup_start_mailer() { printf 'mailer-up\n' >> "${calls}"; }
    existing_notifier_setup_verify_mailer() { printf 'mailer-health\n' >> "${calls}"; }
    existing_notifier_setup_install_plugin() {
        printf 'install-plugin\n' >> "${calls}"
        [[ "${FIXTURE_FAIL_STEP:-}" != install-plugin ]]
    }
    existing_notifier_setup_verify_plugin() { printf 'plugin-active\n' >> "${calls}"; }
    existing_notifier_setup_require_current_smtp_marker() {
        printf 'action-required-smtp\n' >> "${calls}"
        return 20
    }
    existing_notifier_setup_activate_allowlist_interactively() {
        printf 'activate-allowlist\n' >> "${calls}"
        return 1
    }
}

test_setup_orders_disabled_components_before_plugin_transaction() (
    prepare_setup_fixture
    trap 'rm -rf "${fixture}"' EXIT
    set +e
    (existing_notifier_setup_dispatch --resume --non-interactive) > "${output}" 2>&1
    result=$?
    set -e
    [[ "${result}" == 20 ]] || { report_setup_failure; return 1; }
    [[ "$(<"${calls}")" == $'config\npreflight\nprepare-runtime\nrollback-capture\nwrite-disabled-control\nbuild-artifacts\nwrite-override\nmailer-up\nmailer-health\ninstall-plugin\nplugin-active\naction-required-smtp' ]] \
        || { report_setup_failure; return 1; }
    jq -e '.enabled == false and .delivery_enabled == false and .activated_at == 0' \
        "${control_file}" >/dev/null || { report_setup_failure; return 1; }
)

test_failure_never_enables_delivery() (
    prepare_setup_fixture
    trap 'rm -rf "${fixture}"' EXIT
    FIXTURE_FAIL_STEP=install-plugin
    export FIXTURE_FAIL_STEP
    set +e
    (existing_notifier_setup_dispatch --resume --non-interactive) > "${output}" 2>&1
    result=$?
    set -e
    unset FIXTURE_FAIL_STEP
    [[ "${result}" -ne 0 ]] || { report_setup_failure; return 1; }
    jq -e '.enabled == false and .delivery_enabled == false' "${control_file}" >/dev/null || { report_setup_failure; return 1; }
    ! grep -F activate-allowlist "${calls}" >/dev/null || { report_setup_failure; return 1; }
)

test_preflight_action_required_stops_before_runtime_creation() (
    prepare_setup_fixture
    trap 'rm -rf "${fixture}"' EXIT
    FIXTURE_FAIL_STEP=preflight
    export FIXTURE_FAIL_STEP
    set +e
    (existing_notifier_setup_dispatch --resume --non-interactive) > "${output}" 2>&1
    result=$?
    set -e
    unset FIXTURE_FAIL_STEP
    [[ "${result}" == 20 ]] || { report_setup_failure; return 1; }
    [[ ! -e "${runtime_root}" ]] || { report_setup_failure; return 1; }
    [[ "$(<"${calls}")" == $'config\npreflight' ]] || { report_setup_failure; return 1; }
)

test_missing_noninteractive_config_prints_exact_handoff() (
    fixture="$(mktemp -d)"
    trap 'rm -rf "${fixture}"' EXIT
    config="${fixture}/missing.env"
    THREADHUB_EXISTING_NOTIFIER_ENV_FILE="${config}"
    export THREADHUB_EXISTING_NOTIFIER_ENV_FILE
    EXISTING_NOTIFIER_ENV_FILE="${config}"
    set +e
    (existing_notifier_setup_dispatch --resume --non-interactive) </dev/null > "${fixture}/output" 2>&1
    result=$?
    set -e
    [[ "${result}" == 20 ]] || return 1
    grep -F 'Run: ./deploy/scripts/existing-notifier-setup.sh --configure-only' \
        "${fixture}/output" >/dev/null || return 1
    grep -F 'Then rerun: ./deploy/scripts/existing-notifier-setup.sh --resume --non-interactive' \
        "${fixture}/output" >/dev/null
)

test_unknown_runtime_content_is_rejected_without_mutation() (
    fixture="$(mktemp -d)"
    trap 'rm -rf "${fixture}"' EXIT
    runtime_root="${fixture}/runtime"
    mkdir "${runtime_root}"
    chmod 0750 "${runtime_root}"
    printf 'must-survive\n' > "${runtime_root}/unrelated.data"
    before="$(sha256_file "${runtime_root}/unrelated.data")"
    existing_notifier_value() {
        [[ "$1" == THN_DATA_ROOT ]] || return 1
        printf '%s' "${runtime_root}"
    }
    SUDO_COMMAND=(setup_fixture_privileged)
    set +e
    (existing_notifier_setup_prepare_runtime) >/dev/null 2>&1
    result=$?
    set -e
    [[ "${result}" -ne 0 ]] || return 1
    [[ "${before}" == "$(sha256_file "${runtime_root}/unrelated.data")" ]] || return 1
    [[ -z "$(find "${runtime_root}" -mindepth 1 -maxdepth 1 ! -name unrelated.data -print -quit)" ]]
)

test_env_writer_preserves_compose_sensitive_characters() (
    value='pa$$ word#fragment'
    rendered="$(existing_notifier_setup_write_env_value THN_SMTP_PASSWORD "${value}")" \
        || return 1
    [[ "${rendered}" == "THN_SMTP_PASSWORD='pa\$\$ word#fragment'" ]] || return 1
    ! existing_notifier_setup_write_env_value THN_SMTP_PASSWORD "cannot'quote" \
        >/dev/null 2>&1
)

test_resume_skips_plugin_replacement_when_pair_is_already_present() (
    install_called=false
    existing_notifier_target_objects_presence() { printf 'present\n'; }
    notifier_install_reviewed_pair() { install_called=true; }
    existing_notifier_setup_install_plugin || return 1
    [[ "${install_called}" == false ]]
)

test_missing_filestore_plugin_directory_is_created_with_mattermost_policy() (
    fixture="$(mktemp -d)"
    trap 'rm -rf "${fixture}"' EXIT
    fixture_data_root="${fixture}/mattermost-data"
    mkdir "${fixture_data_root}"
    chmod 0750 "${fixture_data_root}"
    existing_notifier_value() {
        [[ "$1" == THN_MATTERMOST_DATA_ROOT ]] || return 1
        printf '%s' "${fixture_data_root}"
    }
    SUDO_COMMAND=(setup_fixture_privileged)
    existing_notifier_setup_prepare_filestore_plugins_root || return 1
    [[ -d "${fixture_data_root}/plugins" && ! -L "${fixture_data_root}/plugins" ]] || return 1
    [[ "$(portable_mode "${fixture_data_root}/plugins")" == 750 ]]
)

test_existing_unsafe_filestore_plugin_directory_is_not_changed() (
    fixture="$(mktemp -d)"
    trap 'rm -rf "${fixture}"' EXIT
    fixture_data_root="${fixture}/mattermost-data"
    mkdir -p "${fixture_data_root}/plugins"
    chmod 0750 "${fixture_data_root}"
    chmod 0777 "${fixture_data_root}/plugins"
    existing_notifier_value() {
        [[ "$1" == THN_MATTERMOST_DATA_ROOT ]] || return 1
        printf '%s' "${fixture_data_root}"
    }
    SUDO_COMMAND=(setup_fixture_privileged)
    set +e
    (existing_notifier_setup_prepare_filestore_plugins_root) >/dev/null 2>&1
    result=$?
    set -e
    [[ "${result}" -ne 0 ]] || return 1
    [[ "$(portable_mode "${fixture_data_root}/plugins")" == 777 ]]
)

test_filestore_plugin_symlink_is_rejected_without_target_mutation() (
    fixture="$(mktemp -d)"
    trap 'rm -rf "${fixture}"' EXIT
    fixture_data_root="${fixture}/mattermost-data"
    target="${fixture}/target"
    mkdir "${fixture_data_root}" "${target}"
    chmod 0750 "${fixture_data_root}" "${target}"
    printf 'must-survive\n' > "${target}/sentinel"
    before="$(sha256_file "${target}/sentinel")"
    ln -s "${target}" "${fixture_data_root}/plugins"
    existing_notifier_value() {
        [[ "$1" == THN_MATTERMOST_DATA_ROOT ]] || return 1
        printf '%s' "${fixture_data_root}"
    }
    SUDO_COMMAND=(setup_fixture_privileged)
    set +e
    (existing_notifier_setup_prepare_filestore_plugins_root) >/dev/null 2>&1
    result=$?
    set -e
    [[ "${result}" -ne 0 ]] || return 1
    [[ -L "${fixture_data_root}/plugins" ]] || return 1
    [[ "${before}" == "$(sha256_file "${target}/sentinel")" ]]
)

test_rollback_absence_capture_is_atomic_and_idempotent() (
    fixture="$(mktemp -d)"
    trap 'rm -rf "${fixture}"' EXIT
    runtime_root="${fixture}/runtime"
    mkdir -p "${runtime_root}/rollback"
    chmod 0750 "${runtime_root}" "${runtime_root}/rollback"
    existing_notifier_value() {
        case "$1" in
            THN_DATA_ROOT) printf '%s\n' "${runtime_root}" ;;
            THN_MATTERMOST_SERVICE) printf '%s\n' existing-mm ;;
            THN_MATTERMOST_PLUGINS_ROOT) printf '%s\n' "${fixture}/plugins" ;;
            THN_MATTERMOST_DATA_ROOT) printf '%s\n' "${fixture}/data" ;;
            *) return 1 ;;
        esac
    }
    existing_notifier_target_objects_presence() { printf 'absent\n'; }
    SUDO_COMMAND=(setup_fixture_privileged)
    existing_notifier_setup_record_rollback_capture || return 1
    capture="${runtime_root}/rollback/capture.json"
    before="$(sha256_file "${capture}")"
    jq -e '
        .schema == 1 and .previous_pair == "absent" and
        .plugin_id == "com.threadhub.channel-email-notifier" and
        .mattermost_service == "existing-mm"
    ' "${capture}" >/dev/null || return 1
    existing_notifier_setup_record_rollback_capture || return 1
    [[ "${before}" == "$(sha256_file "${capture}")" ]]
)

test_writable_runtime_parent_is_rejected_before_creation() (
    fixture="$(mktemp -d)"
    trap 'chmod 0700 "${fixture}"; rm -rf "${fixture}"' EXIT
    runtime_root="${fixture}/runtime"
    chmod 0777 "${fixture}"
    existing_notifier_value() {
        [[ "$1" == THN_DATA_ROOT ]] || return 1
        printf '%s' "${runtime_root}"
    }
    SUDO_COMMAND=(setup_fixture_privileged)
    set +e
    (existing_notifier_setup_prepare_runtime) >/dev/null 2>&1
    result=$?
    set -e
    [[ "${result}" -ne 0 && ! -e "${runtime_root}" ]]
)

test_setup_script_exists() { [[ -f "${SETUP_SCRIPT}" ]]; }

run_test 'existing notifier setup script exists' test_setup_script_exists
if [[ -f "${SETUP_SCRIPT}" ]]; then
    # shellcheck source=/dev/null
    source "${SETUP_SCRIPT}"
    run_test 'setup orders disabled state before component and plugin changes' test_setup_orders_disabled_components_before_plugin_transaction
    run_test 'setup failures never enable delivery' test_failure_never_enables_delivery
    run_test 'preflight action required stops before runtime creation' test_preflight_action_required_stops_before_runtime_creation
    run_test 'missing noninteractive config prints the exact secure handoff' test_missing_noninteractive_config_prints_exact_handoff
    run_test 'unknown runtime content is rejected without mutation' test_unknown_runtime_content_is_rejected_without_mutation
    run_test 'env writer preserves Compose-sensitive characters safely' test_env_writer_preserves_compose_sensitive_characters
    run_test 'resume skips replacement for an already present plugin pair' test_resume_skips_plugin_replacement_when_pair_is_already_present
    run_test 'missing filestore plugin directory is created with Mattermost policy' test_missing_filestore_plugin_directory_is_created_with_mattermost_policy
    run_test 'existing unsafe filestore plugin directory is not changed' test_existing_unsafe_filestore_plugin_directory_is_not_changed
    run_test 'filestore plugin symlink is rejected without target mutation' test_filestore_plugin_symlink_is_rejected_without_target_mutation
    run_test 'pre-adoption absence capture is atomic and idempotent' test_rollback_absence_capture_is_atomic_and_idempotent
    run_test 'writable runtime parent is rejected before creation' test_writable_runtime_parent_is_rejected_before_creation
fi

((failures == 0))
