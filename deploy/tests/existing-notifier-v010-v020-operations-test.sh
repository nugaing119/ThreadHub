#!/usr/bin/env bash

# Orchestration hooks are invoked indirectly by the entry points under test.
# shellcheck disable=SC2030,SC2031,SC2034,SC2329

set -Eeuo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_DEPLOY_DIR="$(cd "${TEST_DIR}/.." && pwd)"
UPGRADE_SCRIPT="${TEST_DEPLOY_DIR}/scripts/existing-notifier-v010-v020-upgrade.sh"
ROLLBACK_SCRIPT="${TEST_DEPLOY_DIR}/scripts/existing-notifier-v010-v020-rollback.sh"
DIAGNOSTIC_SCRIPT="${TEST_DEPLOY_DIR}/scripts/existing-notifier-v010-v020-diagnostic.sh"
failures=0

fail() { printf 'not ok - %s\n' "$1" >&2; failures=$((failures + 1)); }
pass() { printf 'ok - %s\n' "$1"; }
run_test() { if "$2"; then pass "$1"; else fail "$1"; fi; }

v010_v020_test_privileged() {
    local command_name="$1"
    shift
    local filtered=()
    if [[ "${command_name}" == stat && "${1:-}" == -c && "${2:-}" == '%u:%g:%a' ]]; then
        if stat -c '%a' "$3" >/dev/null 2>&1; then
            printf '0:0:%s\n' "$(stat -c '%a' "$3")"
        else
            printf '0:0:%s\n' "$(stat -f '%Lp' "$3")"
        fi
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
    command "${command_name}" "$@"
}

v010_v020_publish_test_privileged() {
    if [[ "$1" == stat && "${2:-}" == -c && "${3:-}" == '%d' ]]; then
        printf '1\n'
        return
    fi
    v010_v020_test_privileged "$@"
}

test_entry_points_exist() {
    [[ -x "${UPGRADE_SCRIPT}" && -x "${ROLLBACK_SCRIPT}" ]]
}

prepare_upgrade_fixture() {
    fixture="$(mktemp -d)"
    calls="${fixture}/calls"
    output="${fixture}/output"
    control="${fixture}/control"
    printf '%s\n' enabled > "${control}"
    : > "${calls}"
    fail_step=''
    recovery_fails=false
}

run_upgrade_fixture() {
    # shellcheck source=../scripts/existing-notifier-v010-v020-upgrade.sh
    declare -F existing_notifier_v010_v020_upgrade >/dev/null || source "${UPGRADE_SCRIPT}"
    upgrade_hook() {
        local step="$1"
        printf '%s\n' "${step}" >> "${calls}"
        if [[ "${step}" == disable ]]; then
            printf '%s\n' disabled > "${control}"
        fi
        [[ "${fail_step}" != "${step}" ]] || return 42
    }
    v010_v020_upgrade_preflight() { upgrade_hook preflight; }
    v010_v020_upgrade_prepare_target_release() { upgrade_hook prepare-target-release; }
    v010_v020_upgrade_recheck_preflight() { upgrade_hook recheck-preflight; }
    v010_v020_upgrade_drain() { upgrade_hook drain; }
    v010_v020_upgrade_require_queue_zero() { upgrade_hook queue-zero; }
    v010_v020_upgrade_disable() { upgrade_hook disable; }
    v010_v020_upgrade_verify_control_loaded_disabled() { upgrade_hook control-loaded-disabled; }
    v010_v020_upgrade_stop_mailer() { upgrade_hook stop-mailer; }
    v010_v020_upgrade_capture_evidence() { upgrade_hook capture-evidence; }
    v010_v020_upgrade_transaction() { upgrade_hook transaction; }
    v010_v020_upgrade_post_status_disabled() { upgrade_hook post-status-disabled; }
    v010_v020_upgrade_action_required_smtp() { upgrade_hook action-required-smtp; return 20; }
    v010_v020_upgrade_recover_disabled_source() {
        printf '%s\n' recover-disabled-source >> "${calls}"
        printf '%s\n' disabled > "${control}"
        [[ "${recovery_fails}" == false ]]
    }
    existing_notifier_v010_v020_upgrade
}

test_upgrade_uses_exact_order_and_stops_for_acceptance() (
    prepare_upgrade_fixture
    trap 'rm -rf -- "${fixture}"' EXIT
    set +e
    run_upgrade_fixture > "${output}" 2>&1
    result=$?
    set -e
    expected=$'preflight\nprepare-target-release\nrecheck-preflight\ndrain\nqueue-zero\ndisable\ncontrol-loaded-disabled\nstop-mailer\ncapture-evidence\ntransaction\npost-status-disabled\naction-required-smtp'
    [[ "${result}" == 20 && "$(<"${calls}")" == "${expected}" && "$(<"${control}")" == disabled ]]
)

test_build_failure_leaves_live_notifier_untouched() (
    prepare_upgrade_fixture
    trap 'rm -rf -- "${fixture}"' EXIT
    fail_step=prepare-target-release
    set +e
    run_upgrade_fixture > "${output}" 2>&1
    result=$?
    set -e
    [[ "${result}" == 42 && "$(<"${control}")" == enabled ]] || return 1
    [[ "$(<"${calls}")" == $'preflight\nprepare-target-release' ]] || return 1
    grep -Fx '[threadhub] ERROR: notifier upgrade halted at stage: prepare-target-release' \
        "${output}" >/dev/null
)

test_post_disable_failures_recover_or_fail_hard() (
    steps=(
        disable control-loaded-disabled stop-mailer capture-evidence
        transaction post-status-disabled
    )
    for failed in "${steps[@]}"; do
        prepare_upgrade_fixture
        fail_step="${failed}"
        set +e
        run_upgrade_fixture > "${output}" 2>&1
        result=$?
        set -e
        [[ "${result}" == 42 && "$(<"${control}")" == disabled ]] || return 1
        [[ "$(tail -n 1 "${calls}")" == recover-disabled-source ]] || return 1
        ! grep -F -e fixture-private-secret -e aaaaaaaaaaaaaaaaaaaaaaaaaa "${output}" >/dev/null || return 1
        rm -rf -- "${fixture}"
    done

    prepare_upgrade_fixture
    fail_step=transaction
    recovery_fails=true
    set +e
    run_upgrade_fixture > "${output}" 2>&1
    result=$?
    set -e
    [[ "${result}" == 70 && "$(<"${control}")" == disabled ]]
)

prepare_rollback_fixture() {
    fixture="$(mktemp -d)"
    calls="${fixture}/calls"
    output="${fixture}/output"
    : > "${calls}"
    fail_step=''
}

run_rollback_fixture() {
    # shellcheck source=../scripts/existing-notifier-v010-v020-rollback.sh
    declare -F existing_notifier_v010_v020_rollback >/dev/null || source "${ROLLBACK_SCRIPT}"
    rollback_hook() {
        printf '%s\n' "$1" >> "${calls}"
        [[ "${fail_step}" != "$1" ]] || return 42
    }
    v010_v020_rollback_validate_capture() { rollback_hook validate-capture; }
    v010_v020_rollback_validate_phase() { rollback_hook validate-phase; }
    v010_v020_rollback_require_disabled() { rollback_hook require-disabled; }
    v010_v020_rollback_require_quiescent_target() { rollback_hook require-quiescent-target; }
    v010_v020_rollback_require_pilot_review() { rollback_hook require-pilot-review; }
    v010_v020_rollback_capture_current_baseline() { rollback_hook capture-current-baseline; }
    v010_v020_rollback_stop_target_mailer() { rollback_hook stop-target-mailer; }
    v010_v020_rollback_recover_source() { rollback_hook recover-source; }
    v010_v020_rollback_verify_source_disabled() { rollback_hook verify-source-disabled; }
    v010_v020_rollback_compare_source_baseline() { rollback_hook compare-source-baseline; }
    v010_v020_rollback_mark_source_recovered() { rollback_hook mark-source-recovered; }
    existing_notifier_v010_v020_rollback "$@"
}

test_rollback_uses_exact_order_and_accepts_no_force() (
    prepare_rollback_fixture
    trap 'rm -rf -- "${fixture}"' EXIT
    run_rollback_fixture > "${output}" 2>&1 || return 1
    expected=$'validate-capture\nvalidate-phase\nrequire-disabled\nrequire-quiescent-target\nrequire-pilot-review\ncapture-current-baseline\nstop-target-mailer\nrecover-source\nverify-source-disabled\ncompare-source-baseline\nmark-source-recovered'
    [[ "$(<"${calls}")" == "${expected}" ]] || return 1
    : > "${calls}"
    set +e
    run_rollback_fixture --force > "${output}" 2>&1
    result=$?
    set -e
    [[ "${result}" == 2 && ! -s "${calls}" ]]
)

test_operations_have_no_unsafe_shortcuts() {
    ! grep -E 'down[[:space:]]+-v|activate-all-channels|threadhub\.stillwhy\.com|threadhub-mentor' \
        "${UPGRADE_SCRIPT}" "${ROLLBACK_SCRIPT}" >/dev/null
}

test_production_contracts_are_wired() (
    grep -F 'notifier_build_artifacts' "${UPGRADE_SCRIPT}" >/dev/null || return 1
    grep -F 'runtime_env_replace_if_unchanged' "${UPGRADE_SCRIPT}" >/dev/null || return 1
    grep -F 'existing_notifier_v010_v020_tx_plugin_pair_transaction' "${UPGRADE_SCRIPT}" >/dev/null || return 1
    grep -F '30-60 seconds' "${UPGRADE_SCRIPT}" >/dev/null || return 1
    grep -F 'pending == 0 and .sending == 0 and .failed == 0' "${UPGRADE_SCRIPT}" "${ROLLBACK_SCRIPT}" >/dev/null || return 1
    ! grep -E '(^|[[:space:]])(rm|unlink)[[:space:]].*(queue|quarantine|failed)' \
        "${UPGRADE_SCRIPT}" "${ROLLBACK_SCRIPT}" >/dev/null
)

test_plugin_publish_halt_diagnostics_are_fixed() (
    # shellcheck source=../scripts/existing-notifier-v010-v020-upgrade.sh
    source "${UPGRADE_SCRIPT}"
    output="$(mktemp)"
    trap 'rm -f -- "${output}"' EXIT
    for stage in target-extracted source-hashed source-verified target-staged \
        filesystem-verified mattermost-stopped pair-transacted; do
        existing_notifier_v010_v020_plugin_publish_record_halt "${stage}" \
            > "${output}" 2>&1 || return 1
        grep -Fx "[threadhub] ERROR: notifier plugin publication halted at stage: ${stage}" \
            "${output}" >/dev/null || return 1
    done
    ! existing_notifier_v010_v020_plugin_publish_record_halt private-value \
        > "${output}" 2>&1
)

test_target_plugin_extraction_uses_preserved_stage_bundle() (
    fixture="$(mktemp -d)"
    trap 'rm -rf -- "${fixture}"' EXIT
    # shellcheck source=../scripts/existing-notifier-v010-v020-upgrade.sh
    source "${UPGRADE_SCRIPT}"
    SUDO_COMMAND=(v010_v020_test_privileged)
    REPOSITORY_ROOT="${fixture}/repository"
    live_data="${fixture}/live-data"
    target_root="${fixture}/target"
    bundle_source="${fixture}/bundle-source"
    plugin_id=com.threadhub.channel-email-notifier
    plugin_root="${bundle_source}/${plugin_id}"
    preserved_bundle="${target_root}/plugin-bundle.tar.gz"
    source_bundle="${REPOSITORY_ROOT}/notifier/dist/${plugin_id}-0.2.0.tar.gz"
    scratch="${fixture}/scratch"
    mkdir -p \
        "$(dirname "${source_bundle}")" "${live_data}/release" "${target_root}" "${scratch}" \
        "${plugin_root}/server/dist" \
        "${plugin_root}/third_party/licenses/github.com/mattermost/mattermost/server/public"
    printf '%s\n' \
        '{"description":"reviewed","homepage_url":"https://threadhub.invalid","id":"com.threadhub.channel-email-notifier","min_server_version":"11.7.7","name":"ThreadHub Notifier","server":{"executables":{"linux-amd64":"server/dist/plugin-linux-amd64"}},"support_url":"https://threadhub.invalid","version":"0.2.0"}' \
        > "${plugin_root}/plugin.json"
    printf '%s\n' executable > "${plugin_root}/server/dist/plugin-linux-amd64"
    printf '%s\n' license > "${plugin_root}/LICENSE"
    printf '%s\n' notices > "${plugin_root}/THIRD_PARTY_NOTICES.md"
    printf '%s\n' readme > "${plugin_root}/third_party/README.md"
    printf '%s\n' modules > "${plugin_root}/third_party/modules.tsv"
    printf '%s\n' sdk-license \
        > "${plugin_root}/third_party/licenses/github.com/mattermost/mattermost/server/public/LICENSE.txt"
    COPYFILE_DISABLE=1 tar -czf "${source_bundle}" -C "${bundle_source}" "${plugin_id}"
    bundle_sha="$(sha256_file "${source_bundle}")"
    cat > "${live_data}/release/release.env" <<EOF
NOTIFIER_PLUGIN_BUNDLE=notifier/dist/${plugin_id}-0.2.0.tar.gz
NOTIFIER_PLUGIN_BUNDLE_SHA256=${bundle_sha}
EOF
    existing_notifier_v010_v020_preserve_target_bundle \
        "${live_data}/release" "${preserved_bundle}" || return 1
    rm -f -- "${source_bundle}"

    existing_notifier_v010_v020_value() {
        [[ "$1" == THN_DATA_ROOT ]] || return 1
        printf '%s\n' "${live_data}"
    }
    existing_notifier_v010_v020_target_root() {
        printf '%s\n' "${target_root}"
    }

    extracted_bundle=""
    extracted_sha=""
    extracted_root=""
    existing_notifier_v010_v020_extract_target_plugin \
        "${scratch}" extracted_bundle extracted_sha extracted_root || return 1
    [[ "${extracted_bundle}" == "${preserved_bundle}" \
        && "${extracted_sha}" == "${bundle_sha}" \
        && -f "${extracted_bundle}" && ! -L "${extracted_bundle}" \
        && "$(sha256_file "${extracted_bundle}")" == "${bundle_sha}" \
        && "${extracted_root}" == "${scratch}/reviewed/${plugin_id}" \
        && -f "${extracted_root}/plugin.json" ]]
)

test_target_bundle_is_preserved_before_repository_artifact_disappears() (
    fixture="$(mktemp -d)"
    trap 'rm -rf -- "${fixture}"' EXIT
    # shellcheck source=../scripts/existing-notifier-v010-v020-upgrade.sh
    source "${UPGRADE_SCRIPT}"
    REPOSITORY_ROOT="${fixture}/repository"
    release_dir="${fixture}/release"
    target_root="${fixture}/target"
    source_bundle="${REPOSITORY_ROOT}/notifier/dist/com.threadhub.channel-email-notifier-0.2.0.tar.gz"
    preserved_bundle="${target_root}/plugin-bundle.tar.gz"
    mkdir -p "$(dirname "${source_bundle}")" "${release_dir}" "${target_root}"
    printf '%s\n' reviewed-bundle > "${source_bundle}"
    bundle_sha="$(sha256_file "${source_bundle}")"
    cat > "${release_dir}/release.env" <<EOF
NOTIFIER_PLUGIN_BUNDLE=notifier/dist/com.threadhub.channel-email-notifier-0.2.0.tar.gz
NOTIFIER_PLUGIN_BUNDLE_SHA256=${bundle_sha}
EOF

    SUDO_COMMAND=(v010_v020_test_privileged)

    existing_notifier_v010_v020_preserve_target_bundle \
        "${release_dir}" "${preserved_bundle}" || return 1
    rm -f -- "${source_bundle}"
    [[ -f "${preserved_bundle}" && ! -L "${preserved_bundle}" \
        && "$(sha256_file "${preserved_bundle}")" == "${bundle_sha}" \
        && "$(v010_v020_test_privileged stat -c '%u:%g:%a' "${preserved_bundle}")" == 0:0:600 ]]
)

test_source_verification_cannot_invalidate_target_review() (
    fixture="$(mktemp -d)"
    trap 'rm -rf -- "${fixture}"' EXIT
    # shellcheck source=../scripts/existing-notifier-v010-v020-upgrade.sh
    source "${UPGRADE_SCRIPT}"
    calls="${fixture}/calls"
    : > "${calls}"
    fixture_target_root="${fixture}/target"
    live_plugins="${fixture}/live/plugins"
    live_data="${fixture}/live/data"
    mkdir -p "${fixture_target_root}" "${live_plugins}" "${live_data}/plugins" \
        "${fixture}/attempt/source" "${fixture}/attempt/displaced" \
        "${fixture}/attempt/quarantine"
    SUDO_COMMAND=(v010_v020_publish_test_privileged)

    existing_notifier_v010_v020_target_root() { printf '%s\n' "${fixture_target_root}"; }
    existing_notifier_v010_v020_value() {
        case "$1" in
            THN_MATTERMOST_PLUGINS_ROOT) printf '%s\n' "${live_plugins}" ;;
            THN_MATTERMOST_DATA_ROOT) printf '%s\n' "${live_data}" ;;
            THN_MATTERMOST_SERVICE) printf '%s\n' mattermost ;;
            *) return 1 ;;
        esac
    }
    existing_notifier_v010_v020_capture_hash() {
        printf '%s\n' source-hashed >> "${calls}"
        printf '%064d\n' 1
    }
    notifier_plugin_pair_is_exact() {
        printf '%s\n' source-verified >> "${calls}"
        rm -rf -- "$5"
    }
    existing_notifier_v010_v020_extract_target_plugin() {
        local scratch_root="$1"
        local output_bundle_name="$2"
        local output_sha_name="$3"
        local output_root_name="$4"
        local bundle="${scratch_root}/bundle.tar.gz"
        local reviewed="${scratch_root}/reviewed/com.threadhub.channel-email-notifier"
        printf '%s\n' target-extracted >> "${calls}"
        mkdir -p "${reviewed}"
        printf '%s\n' bundle > "${bundle}"
        printf -v "${output_bundle_name}" '%s' "${bundle}"
        printf -v "${output_sha_name}" '%064d' 2
        printf -v "${output_root_name}" '%s' "${reviewed}"
    }
    notifier_plugin_stage_pair() {
        printf '%s\n' target-staged >> "${calls}"
        [[ -f "$1" && -d "$2" && -d "$6" ]] || return 1
        mkdir -p "$3"
        printf '%s\n' staged > "$4"
    }
    existing_notifier_v010_v020_compose_combined() { return 0; }
    existing_notifier_v010_v020_tx_plugin_pair_transaction() { return 0; }

    v010_v020_tx_publish_target_plugin_pair "${fixture}/attempt" || return 1
    [[ "$(<"${calls}")" == $'source-hashed\nsource-verified\ntarget-extracted\ntarget-staged' ]]
)

test_outer_transaction_failure_cannot_be_masked_by_recovery_staging() (
    fixture="$(mktemp -d)"
    trap 'rm -rf -- "${fixture}"' EXIT
    output="${fixture}/upgrade-output"
    cat > "${output}" <<'EOF'
[threadhub] ERROR: notifier transition halted after phase: target_mailer_started
[threadhub] ERROR: notifier plugin staging halted at phase: reviewed-runtime-validation
EOF

    [[ -x "${DIAGNOSTIC_SCRIPT}" ]] || return 1
    [[ "$("${DIAGNOSTIC_SCRIPT}" primary-failure 1 "${output}")" \
        == transaction-after-target-mailer-started ]]
)

test_acceptance_handoff_is_exact() (
    # shellcheck source=../scripts/existing-notifier-v010-v020-upgrade.sh
    source "${UPGRADE_SCRIPT}"
    output="$(mktemp)"
    trap 'rm -f -- "${output}"' EXIT
    set +e
    v010_v020_upgrade_action_required_smtp > "${output}" 2>&1
    result=$?
    set -e
    [[ "${result}" == 20 ]] || return 1
    grep -Fx '[ACTION REQUIRED] Run ./deploy/scripts/existing-notifier-smtp-test.sh, then activate a public/private test-channel allowlist.' \
        "${output}" >/dev/null
)

test_failed_or_pending_work_blocks_without_disposition() (
    # shellcheck source=../scripts/existing-notifier-v010-v020-rollback.sh
    source "${ROLLBACK_SCRIPT}"
    fixture="$(mktemp -d)"
    trap 'rm -rf -- "${fixture}"' EXIT
    output="${fixture}/output"
    fixture_inspection='{"schema_version":2,"events":1,"nonces":1,"pending":1,"sending":0,"sent":0,"failed":0,"cancelled":0}'
    existing_notifier_v010_v020_inspect_live_queue() { printf '%s\n' "${fixture_inspection}" > "$1"; }
    set +e
    v010_v020_rollback_require_quiescent_target > "${output}" 2>&1
    result=$?
    set -e
    [[ "${result}" == 20 ]] || return 1
    fixture_inspection='{"schema_version":2,"events":1,"nonces":1,"pending":0,"sending":0,"sent":0,"failed":1,"cancelled":0}'
    set +e
    v010_v020_rollback_require_quiescent_target > "${output}" 2>&1
    result=$?
    set -e
    [[ "${result}" == 20 ]] || return 1
    ! grep -E 'retry-failed|cancel-failed' "${output}" >/dev/null
)

test_pilot_work_requires_exact_interactive_review() (
    # shellcheck source=../scripts/existing-notifier-v010-v020-rollback.sh
    source "${ROLLBACK_SCRIPT}"
    fixture="$(mktemp -d)"
    trap 'rm -rf -- "${fixture}"' EXIT
    notifier_root="${fixture}/notifier"
    attempt_root="${notifier_root}/migration/existing-notifier-v010-v020"
    mkdir -p "${attempt_root}"
    source_inspection='{"schema_version":1,"events":1,"nonces":1,"pending":0,"sending":0,"sent":1,"failed":0,"cancelled":0}'
    current_inspection='{"schema_version":2,"events":2,"nonces":2,"pending":0,"sending":0,"sent":2,"failed":0,"cancelled":0}'
    printf '%s\n' "${source_inspection}" > "${attempt_root}/queue-inspection.json"
    SUDO_COMMAND=(env)
    existing_notifier_v010_v020_value() {
        [[ "$1" == THN_DATA_ROOT ]] || return 1
        printf '%s\n' "${notifier_root}"
    }
    existing_notifier_v010_v020_inspect_live_queue() { printf '%s\n' "${current_inspection}" > "$1"; }
    fixture_tty=false
    fixture_confirmation=''
    existing_notifier_v010_v020_rollback_stdin_is_tty() { [[ "${fixture_tty}" == true ]]; }
    existing_notifier_v010_v020_rollback_read_confirmation() { printf '%s\n' "${fixture_confirmation}"; }
    set +e
    v010_v020_rollback_require_pilot_review > "${fixture}/output" 2>&1
    result=$?
    set -e
    [[ "${result}" == 20 ]] || return 1
    fixture_tty=true
    fixture_confirmation='I REVIEWED SOMETHING ELSE'
    set +e
    v010_v020_rollback_require_pilot_review > "${fixture}/output" 2>&1
    result=$?
    set -e
    [[ "${result}" == 20 ]] || return 1
    fixture_confirmation='I REVIEWED V0.2.0 PILOT DELIVERY ROLLBACK'
    v010_v020_rollback_require_pilot_review > "${fixture}/output" 2>&1
)

test_recovery_quarantines_target_and_restores_exact_source() (
    # shellcheck source=../scripts/existing-notifier-v010-v020-upgrade.sh
    source "${UPGRADE_SCRIPT}"
    fixture="$(mktemp -d)"
    trap 'rm -rf -- "${fixture}"' EXIT
    live="${fixture}/live.env"
    captured="${fixture}/captured.env"
    displaced="${fixture}/displaced.env"
    quarantine="${fixture}/quarantine.env"
    real_mv="$(command -v mv)"
    mkdir -p "${fixture}/bin"
    # The following single-quoted line is literal source for the fixture wrapper.
    # shellcheck disable=SC2016
    printf '%s\n' \
        '#!/usr/bin/env bash' \
        'set -eu' \
        '[[ "${1:-}" == -T ]] && shift' \
        "exec ${real_mv} \"\$@\"" > "${fixture}/bin/mv"
    chmod 0700 "${fixture}/bin/mv"
    PATH="${fixture}/bin:${PATH}"
    printf '%s\n' target-state > "${live}"
    printf '%s\n' source-state > "${captured}"
    cp -p "${captured}" "${displaced}"
    chmod 0600 "${live}" "${captured}" "${displaced}"
    SUDO_COMMAND=(env)
    existing_notifier_v010_v020_capture_identity() { printf '%s\n' 1000:1000:600; }

    existing_notifier_v010_v020_restore_object \
        "${live}" "${captured}" "${displaced}" "${quarantine}" file || return 1
    cmp -s "${live}" "${captured}" || return 1
    grep -Fx target-state "${quarantine}" >/dev/null || return 1
    [[ ! -e "${displaced}" ]] || return 1
    existing_notifier_v010_v020_restore_object \
        "${live}" "${captured}" "${displaced}" "${quarantine}" file || return 1

    printf '%s\n' target-again > "${live}"
    [[ ! -e "${displaced}" ]]
    ! existing_notifier_v010_v020_restore_object \
        "${live}" "${captured}" "${displaced}" "${quarantine}" file
)

run_test 'version-specific upgrade and rollback entry points exist' test_entry_points_exist
if [[ -x "${UPGRADE_SCRIPT}" && -x "${ROLLBACK_SCRIPT}" ]]; then
    run_test 'upgrade uses exact order and stops for acceptance' test_upgrade_uses_exact_order_and_stops_for_acceptance
    run_test 'build failure leaves live notifier untouched' test_build_failure_leaves_live_notifier_untouched
    run_test 'post-disable failures recover or fail hard' test_post_disable_failures_recover_or_fail_hard
    run_test 'rollback uses exact order and accepts no force' test_rollback_uses_exact_order_and_accepts_no_force
    run_test 'operations have no unsafe shortcuts' test_operations_have_no_unsafe_shortcuts
    run_test 'production contracts are wired' test_production_contracts_are_wired
    run_test 'plugin publication halt diagnostics are fixed' test_plugin_publish_halt_diagnostics_are_fixed
    run_test 'target plugin extraction uses the preserved stage bundle' test_target_plugin_extraction_uses_preserved_stage_bundle
    run_test 'target bundle is preserved before the repository artifact disappears' test_target_bundle_is_preserved_before_repository_artifact_disappears
    run_test 'source verification cannot invalidate target review' test_source_verification_cannot_invalidate_target_review
    run_test 'outer transaction failure cannot be masked by recovery staging' test_outer_transaction_failure_cannot_be_masked_by_recovery_staging
    run_test 'acceptance handoff is exact' test_acceptance_handoff_is_exact
    run_test 'failed or pending work blocks without disposition' test_failed_or_pending_work_blocks_without_disposition
    run_test 'pilot work requires exact interactive review' test_pilot_work_requires_exact_interactive_review
    run_test 'recovery quarantines target and restores exact source' test_recovery_quarantines_target_and_restores_exact_source
fi

if ((failures > 0)); then
    exit 1
fi
