#!/usr/bin/env bash

# Hook replacements are invoked indirectly by the tested orchestration.
# shellcheck disable=SC2030,SC2031,SC2034,SC2329

set -Eeuo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_DEPLOY_DIR="$(cd "${TEST_DIR}/.." && pwd)"
COMMON="${TEST_DEPLOY_DIR}/scripts/existing-notifier-v010-v020-common.sh"
GATE_SCRIPT="${TEST_DEPLOY_DIR}/scripts/existing-notifier-v010-v020-recovery-gate.sh"
failures=0

fail() { printf 'not ok - %s\n' "$1" >&2; failures=$((failures + 1)); }
pass() { printf 'ok - %s\n' "$1"; }
run_test() { if "$2"; then pass "$1"; else fail "$1"; fi; }

test_gate_script_exists() { [[ -f "${GATE_SCRIPT}" ]]; }

write_gate_config() {
    cat > "${config}" <<EOF
THN_COMPOSE_PROJECT_DIR=${fixture}/project
THN_COMPOSE_FILE=${fixture}/project/compose.yml
THN_COMPOSE_ENV_FILE=${fixture}/project/.env
THN_MATTERMOST_SERVICE=mattermost
THN_MATTERMOST_PLUGINS_ROOT=${fixture}/mattermost/plugins
THN_MATTERMOST_DATA_ROOT=${fixture}/mattermost/data
THN_DATA_ROOT=${notifier_root}
THN_DOMAIN=threadhub.valid.test
THN_SMTP_SERVER=smtp.email.ap-singapore-1.oci.oraclecloud.com
THN_SMTP_PORT=587
THN_SMTP_CA_FILE=${fixture}/ca.crt
THN_SMTP_USERNAME=fixture-smtp-user
THN_SMTP_PASSWORD=fixture-private-password
THN_SMTP_FROM_ADDRESS=no-reply@valid.test
THN_SMTP_REPLY_TO_ADDRESS=admin@valid.test
THN_SMTP_FEEDBACK_NAME=ThreadHub
THN_HMAC_SECRET=1111111111111111111111111111111111111111111111111111111111111111
THN_RATE_PER_MINUTE=10
EOF
    chmod 0600 "${config}"
}

prepare_gate_fixture() {
    fixture="$(mktemp -d)"
    notifier_root="${fixture}/notifier"
    migration_root="${notifier_root}/migration"
    gate_file="${migration_root}/recovery-gate-v010-v020.json"
    config="${fixture}/existing-notifier.env"
    output="${fixture}/output"
    mkdir -p "${notifier_root}"
    write_gate_config
    fixture_tty=true
    fixture_confirmation='I REVIEWED THE BACKUP AND DISPOSABLE RESTORE'
}

run_gate_fixture() {
    THREADHUB_EXISTING_NOTIFIER_ENV_FILE="${config}"
    export THREADHUB_EXISTING_NOTIFIER_ENV_FILE
    # shellcheck source=../scripts/existing-notifier-v010-v020-recovery-gate.sh
    declare -F existing_notifier_v010_v020_recovery_gate_entry >/dev/null || source "${GATE_SCRIPT}"
    EXISTING_NOTIFIER_V010_V020_ENV_FILE="${config}"
    init_sudo() { SUDO_COMMAND=(env); }
    existing_notifier_v010_v020_gate_stdin_is_tty() { [[ "${fixture_tty}" == true ]]; }
    existing_notifier_v010_v020_gate_read_confirmation() { printf '%s\n' "${fixture_confirmation}"; }
    existing_notifier_v010_v020_gate_validate_runtime_root() { [[ "$1" == "${notifier_root}" ]]; }
    existing_notifier_v010_v020_gate_prepare_parent() {
        [[ "$1" == "${migration_root}" && ! -L "$1" ]] || return 1
        mkdir -p "$1" && chmod 0700 "$1"
    }
    existing_notifier_v010_v020_gate_publish() {
        [[ "$2" == "${gate_file}" ]] || return 1
        install -m 0600 "$1" "${migration_root}/.gate-candidate"
        ln "${migration_root}/.gate-candidate" "$2" || return 1
        rm -f "${migration_root}/.gate-candidate"
    }
    existing_notifier_v010_v020_privileged_identity() {
        if [[ "$1" == "${migration_root}" ]]; then printf '%s\n' 0:0:700; else printf '%s\n' 0:0:600; fi
    }
    existing_notifier_v010_v020_recovery_gate_entry "$@"
}

test_record_requires_tty_and_exact_confirmation() (
    prepare_gate_fixture
    trap 'rm -rf -- "${fixture}"' EXIT

    fixture_tty=false
    set +e; run_gate_fixture record > "${output}" 2>&1; result=$?; set -e
    [[ "${result}" == 20 && ! -e "${gate_file}" ]] || return 1

    fixture_tty=true
    fixture_confirmation='I REVIEWED SOMETHING ELSE'
    set +e; run_gate_fixture record > "${output}" 2>&1; result=$?; set -e
    [[ "${result}" == 20 && ! -e "${gate_file}" ]] || return 1

    fixture_confirmation='I REVIEWED THE BACKUP AND DISPOSABLE RESTORE'
    run_gate_fixture record > "${output}" 2>&1 || return 1
    [[ -f "${gate_file}" && ! -L "${gate_file}" ]] || return 1
    jq -e '
      type == "object" and
      (keys == ["aggregate_match_verified","disposable_restore_verified","profile","remote_backup_verified","restored_queue_quarantined","reviewed_at_utc","schema","source_release_commit"]) and
      .schema == 1 and .profile == "existing-notifier-v010-v020" and
      .source_release_commit == "c193155eeb6298771d4366d6af4cae81499487b8" and
      .remote_backup_verified == true and .disposable_restore_verified == true and
      .aggregate_match_verified == true and .restored_queue_quarantined == true and
      (.reviewed_at_utc | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
    ' "${gate_file}" >/dev/null
)

test_record_is_no_clobber_and_check_is_read_only() (
    prepare_gate_fixture
    trap 'rm -rf -- "${fixture}"' EXIT
    run_gate_fixture record > "${output}" 2>&1 || return 1
    before="$(shasum -a 256 "${gate_file}" | awk '{print $1}')"

    set +e; run_gate_fixture record > "${output}" 2>&1; result=$?; set -e
    [[ "${result}" == 20 && "${before}" == "$(shasum -a 256 "${gate_file}" | awk '{print $1}')" ]] || return 1
    run_gate_fixture check > "${output}" 2>&1 || return 1
    [[ "${before}" == "$(shasum -a 256 "${gate_file}" | awk '{print $1}')" ]] || return 1
    ! grep -F fixture-private-password "${output}" >/dev/null
)

prepare_capture_fixture() {
    fixture="$(mktemp -d)"
    notifier_root="${fixture}/notifier"
    migration_root="${notifier_root}/migration"
    attempt_root="${migration_root}/existing-notifier-v010-v020"
    calls="${fixture}/calls"
    mkdir -p "${migration_root}"
    chmod 0700 "${migration_root}"
    : > "${calls}"
    fixture_fail_step=''
}

run_capture_fixture() {
    # shellcheck source=../scripts/existing-notifier-v010-v020-common.sh
    declare -F existing_notifier_v010_v020_capture_evidence >/dev/null || source "${COMMON}"
    SUDO_COMMAND=(env)
    existing_notifier_v010_v020_value() {
        [[ "$1" == THN_DATA_ROOT ]] || return 1
        printf '%s\n' "${notifier_root}"
    }
    existing_notifier_v010_v020_capture_prepare_attempt() { mkdir -m 0700 "$1"; }
    capture_hook() {
        printf '%s\n' "$1" >> "${calls}"
        [[ "${fixture_fail_step}" != "$1" ]]
    }
    v010_v020_capture_control_is_disabled() { capture_hook control-disabled; }
    v010_v020_capture_mailer_is_stopped() { capture_hook mailer-stopped; }
    v010_v020_capture_inspect_queue_v1() { capture_hook queue-inspected-v1; }
    v010_v020_capture_queue() { capture_hook queue-captured; }
    v010_v020_capture_source_plugin_pair() { capture_hook source-plugin-pair-captured; }
    v010_v020_capture_source_mailer_image() { capture_hook source-mailer-image-saved; }
    v010_v020_capture_source_release() { capture_hook source-release-captured; }
    v010_v020_capture_source_override() { capture_hook source-override-captured; }
    v010_v020_capture_source_env() { capture_hook source-env-captured; }
    v010_v020_capture_source_control() { capture_hook source-control-captured; }
    v010_v020_capture_baseline() { capture_hook baseline-captured; }
    v010_v020_capture_verify_evidence() { capture_hook evidence-verified; }
    existing_notifier_v010_v020_capture_evidence "${attempt_root}"
}

test_capture_uses_exact_order_and_refuses_second_attempt() (
    prepare_capture_fixture
    trap 'rm -rf -- "${fixture}"' EXIT
    run_capture_fixture || return 1
    expected=$'control-disabled\nmailer-stopped\nqueue-inspected-v1\nqueue-captured\nsource-plugin-pair-captured\nsource-mailer-image-saved\nsource-release-captured\nsource-override-captured\nsource-env-captured\nsource-control-captured\nbaseline-captured\nevidence-verified'
    [[ "$(<"${calls}")" == "${expected}" ]] || return 1
    set +e; run_capture_fixture > "${fixture}/second-output" 2>&1; result=$?; set -e
    [[ "${result}" != 0 ]] || return 1
    [[ "$(<"${calls}")" == "${expected}" ]]
)

test_capture_stops_at_every_failed_safety_gate() (
    for failed_step in \
        control-disabled mailer-stopped queue-inspected-v1 queue-captured \
        source-plugin-pair-captured source-mailer-image-saved source-release-captured \
        source-override-captured source-env-captured source-control-captured \
        baseline-captured evidence-verified; do
        prepare_capture_fixture
        fixture_fail_step="${failed_step}"
        set +e; run_capture_fixture > "${fixture}/output" 2>&1; result=$?; set -e
        [[ "${result}" != 0 ]] || return 1
        [[ "$(tail -n 1 "${calls}")" == "${failed_step}" ]] || return 1
        grep -Fx "[threadhub] ERROR: notifier evidence capture halted at stage: ${failed_step}" \
            "${fixture}/output" >/dev/null || return 1
        rm -rf -- "${fixture}"
    done
)

test_queue_capture_includes_only_database_wal_and_shm() (
    fixture="$(mktemp -d)"
    trap 'rm -rf -- "${fixture}"' EXIT
    notifier_root="${fixture}/notifier"
    source_mailer="${notifier_root}/mailer"
    attempt_root="${notifier_root}/migration/existing-notifier-v010-v020"
    mkdir -p "${source_mailer}" "${attempt_root}/source"
    for name in queue.db queue.db-wal queue.db-shm; do
        printf '%s\n' "${name}-content" > "${source_mailer}/${name}"
        chmod 0600 "${source_mailer}/${name}"
    done
    # shellcheck source=../scripts/existing-notifier-v010-v020-common.sh
    source "${COMMON}"
    SUDO_COMMAND=(env)
    existing_notifier_v010_v020_value() {
        [[ "$1" == THN_DATA_ROOT ]] || return 1
        printf '%s\n' "${notifier_root}"
    }
    existing_notifier_v010_v020_capture_identity() {
        if [[ "$1" == "${source_mailer}" ]]; then printf '%s\n' 65532:65532:700; else printf '%s\n' 65532:65532:600; fi
    }

    v010_v020_capture_queue "${attempt_root}" || return 1
    for name in queue.db queue.db-wal queue.db-shm; do
        cmp -s "${source_mailer}/${name}" "${attempt_root}/source/mailer/${name}" || return 1
    done
    printf '%s\n' unexpected > "${source_mailer}/unexpected"
    ! v010_v020_capture_queue "${fixture}/second-attempt" || return 1
    rm -f "${source_mailer}/unexpected"
    ln -s "${fixture}/outside" "${source_mailer}/linked"
    ! v010_v020_capture_queue "${fixture}/third-attempt" || return 1
    rm -f "${source_mailer}/linked"
    existing_notifier_v010_v020_capture_identity() {
        if [[ "$1" == "${source_mailer}" ]]; then printf '%s\n' 65532:65532:750; else printf '%s\n' 65532:65532:600; fi
    }
    ! v010_v020_capture_queue "${fixture}/unsafe-mode-attempt"
)

test_baseline_contains_only_nonnegative_aggregate_counts() (
    fixture="$(mktemp -d)"
    trap 'rm -rf -- "${fixture}"' EXIT
    baseline="${fixture}/baseline.json"
    printf '%s\n' '{"teams":2,"channels":3,"channel_members":4,"active_users":5,"inactive_users":1,"posts":7,"files":8}' > "${baseline}"
    # shellcheck source=../scripts/existing-notifier-v010-v020-common.sh
    source "${COMMON}"
    existing_notifier_v010_v020_baseline_is_valid "${baseline}" || return 1
    jq '.email="private@valid.test"' "${baseline}" > "${baseline}.new"
    mv "${baseline}.new" "${baseline}"
    ! existing_notifier_v010_v020_baseline_is_valid "${baseline}" || return 1
    printf '%s\n' '{"teams":-1,"channels":3,"channel_members":4,"active_users":5,"inactive_users":1,"posts":7,"files":8}' > "${baseline}"
    ! existing_notifier_v010_v020_baseline_is_valid "${baseline}"
)

test_control_mailer_and_queue_schema_gates() (
    fixture="$(mktemp -d)"
    trap 'rm -rf -- "${fixture}"' EXIT
    notifier_root="${fixture}/notifier"
    attempt_root="${notifier_root}/migration/existing-notifier-v010-v020"
    control_file="${notifier_root}/control/state.json"
    mkdir -p "${notifier_root}/control" "${notifier_root}/mailer" "${attempt_root}"
    printf '%s\n' '{"enabled":false,"delivery_enabled":false,"mode":"all_channels","channel_ids":[],"activated_at":1}' > "${control_file}"
    chmod 0640 "${control_file}"
    # shellcheck source=../scripts/existing-notifier-v010-v020-common.sh
    source "${COMMON}"
    SUDO_COMMAND=(env)
    existing_notifier_v010_v020_value() {
        [[ "$1" == THN_DATA_ROOT ]] || return 1
        printf '%s\n' "${notifier_root}"
    }
    existing_notifier_v010_v020_capture_identity() { printf '%s\n' 0:3000:640; }
    fixture_mailer_id=''
    existing_notifier_v010_v020_compose_combined() {
        [[ "$*" == 'ps -q threadhub-mailer' ]] || return 2
        printf '%s' "${fixture_mailer_id}"
    }
    fixture_queue_inspection='{"schema_version":1,"events":2,"nonces":3,"pending":1,"sending":0,"sent":1,"failed":0,"cancelled":0}'
    existing_notifier_v010_v020_run_queue_inspector() { return 1; }
    existing_notifier_v010_v020_run_offline_queue_inspector() {
        printf '%s\n' "${fixture_queue_inspection}" > "$1"
    }

    v010_v020_capture_control_is_disabled "${attempt_root}" || return 1
    v010_v020_capture_mailer_is_stopped "${attempt_root}" || return 1
    v010_v020_capture_inspect_queue_v1 "${attempt_root}" || return 1
    jq -e '.schema_version == 1 and .events == 2' "${attempt_root}/queue-inspection.json" >/dev/null || return 1

    printf '%s\n' '{"enabled":true,"delivery_enabled":true,"mode":"all_channels","channel_ids":[],"activated_at":1}' > "${control_file}"
    ! v010_v020_capture_control_is_disabled "${attempt_root}" || return 1
    printf '%s\n' '{"enabled":false,"delivery_enabled":false,"mode":"all_channels","channel_ids":[],"activated_at":1}' > "${control_file}"
    fixture_mailer_id=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
    ! v010_v020_capture_mailer_is_stopped "${attempt_root}" || return 1
    fixture_mailer_id=''
    fixture_queue_inspection='{"schema_version":2,"events":2,"nonces":3,"pending":1,"sending":0,"sent":1,"failed":0,"cancelled":0}'
    ! v010_v020_capture_inspect_queue_v1 "${fixture}/schema2-attempt"
)

test_source_files_and_mailer_image_are_captured_privately() (
    fixture="$(mktemp -d)"
    trap 'rm -rf -- "${fixture}"' EXIT
    notifier_root="${fixture}/notifier"
    attempt_root="${notifier_root}/migration/existing-notifier-v010-v020"
    config="${fixture}/existing-notifier.env"
    mattermost_data="${fixture}/mattermost/data"
    mkdir -p "${notifier_root}/release" "${notifier_root}/control" "${attempt_root}/source" "${mattermost_data}/plugins"
    printf '%s\n' 'release-data' > "${notifier_root}/release/release.env"
    printf '%s\n' 'override-data' > "${notifier_root}/compose.override.yml"
    printf '%s\n' 'SMTP_PASSWORD=private-source-secret' > "${config}"
    printf '%s\n' '{"enabled":false,"delivery_enabled":false,"mode":"all_channels","channel_ids":[],"activated_at":1}' > "${notifier_root}/control/state.json"
    chmod 0600 "${notifier_root}/compose.override.yml" "${config}"
    chmod 0640 "${notifier_root}/release/release.env" "${notifier_root}/control/state.json"
    # shellcheck source=../scripts/existing-notifier-v010-v020-common.sh
    source "${COMMON}"
    SUDO_COMMAND=(env)
    EXISTING_NOTIFIER_V010_V020_ENV_FILE="${config}"
    EXISTING_NOTIFIER_V010_RELEASE_MAILER_IMAGE_ID=sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
    existing_notifier_v010_v020_value() {
        case "$1" in
          THN_DATA_ROOT) printf '%s\n' "${notifier_root}" ;;
          THN_MATTERMOST_DATA_ROOT) printf '%s\n' "${mattermost_data}" ;;
          *) return 1 ;;
        esac
    }
    fixture_image_valid=true
    existing_notifier_v010_v020_save_source_image() {
        if [[ "${fixture_image_valid}" == true ]]; then
            mkdir -p "${fixture}/image-content"
            printf '%s\n' layer > "${fixture}/image-content/layer"
            tar -cf "$1" -C "${fixture}/image-content" layer
        else
            printf x > "$1"
        fi
    }

    v010_v020_capture_source_mailer_image "${attempt_root}" || return 1
    v010_v020_capture_source_release "${attempt_root}" || return 1
    v010_v020_capture_source_override "${attempt_root}" || return 1
    v010_v020_capture_source_env "${attempt_root}" || return 1
    v010_v020_capture_source_control "${attempt_root}" || return 1
    tar -tf "${attempt_root}/source/mailer-image.tar" >/dev/null || return 1
    cmp -s "${config}" "${attempt_root}/source/existing-notifier.env" || return 1

    second="${fixture}/second"
    mkdir -p "${second}/source"
    fixture_image_valid=false
    ! v010_v020_capture_source_mailer_image "${second}"
)

test_source_plugin_capture_preserves_the_plugin_root_layout() (
    fixture="$(mktemp -d)"
    trap 'rm -rf -- "${fixture}"' EXIT
    plugin_id=com.threadhub.channel-email-notifier
    attempt_root="${fixture}/attempt"
    live_runtime="${fixture}/live/plugins/${plugin_id}"
    live_data="${fixture}/live/data"
    live_bundle="${live_data}/plugins/${plugin_id}.tar.gz"
    mkdir -p "${attempt_root}/source" "${live_runtime}" "$(dirname "${live_bundle}")"
    printf '%s\n' live-bundle > "${live_bundle}"
    # shellcheck source=../scripts/existing-notifier-v010-v020-common.sh
    source "${COMMON}"
    # shellcheck source=../scripts/notifier-plugin-files.sh
    source "${TEST_DEPLOY_DIR}/scripts/notifier-plugin-files.sh"
    SUDO_COMMAND=(env)
    EXISTING_NOTIFIER_V010_RELEASE_BUNDLE_SHA="$(printf 'a%.0s' {1..64})"
    existing_notifier_v010_v020_value() {
        case "$1" in
            THN_MATTERMOST_PLUGINS_ROOT) printf '%s\n' "${fixture}/live/plugins" ;;
            THN_MATTERMOST_DATA_ROOT) printf '%s\n' "${live_data}" ;;
            *) return 1 ;;
        esac
    }
    notifier_plugin_capture_pair() {
        local captured_plugin_root="$4/${3}"
        mkdir -p "${captured_plugin_root}/server/dist"
        printf '%s\n' plugin-manifest > "${captured_plugin_root}/plugin.json"
        printf '%s\n' plugin-binary > "${captured_plugin_root}/server/dist/plugin-linux-amd64"
        printf '0.1.0\t%s\n' "${EXISTING_NOTIFIER_V010_RELEASE_BUNDLE_SHA}"
    }

    v010_v020_capture_source_plugin_pair "${attempt_root}" || return 1
    [[ -f "${attempt_root}/source/plugin-runtime/plugin.json" \
        && -f "${attempt_root}/source/plugin-runtime/server/dist/plugin-linux-amd64" \
        && ! -e "${attempt_root}/source/plugin-runtime/${plugin_id}" ]]
)

test_evidence_manifest_is_complete_and_contains_no_payload_values() (
    fixture="$(mktemp -d)"
    trap 'rm -rf -- "${fixture}"' EXIT
    attempt_root="${fixture}/attempt"
    mkdir -p "${attempt_root}/source/mailer" "${attempt_root}/source/plugin-runtime" "${attempt_root}/source/release"
    printf '%s\n' '{"schema_version":1,"events":0,"nonces":0,"pending":0,"sending":0,"sent":0,"failed":0,"cancelled":0}' > "${attempt_root}/queue-inspection.json"
    printf '%s\n' queue > "${attempt_root}/source/mailer/queue.db"
    printf '%s\n' plugin > "${attempt_root}/source/plugin-runtime/plugin.json"
    printf '%s\n' bundle > "${attempt_root}/source/plugin-bundle.tar.gz"
    mkdir -p "${fixture}/image-content" && printf '%s\n' layer > "${fixture}/image-content/layer"
    tar -cf "${attempt_root}/source/mailer-image.tar" -C "${fixture}/image-content" layer
    printf '%s\n' 'sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' > "${attempt_root}/source/mailer-image-id"
    printf '%s\n' release > "${attempt_root}/source/release/release.env"
    printf '%s\n' override > "${attempt_root}/source/compose.override.yml"
    printf '%s\n' 'SMTP_PASSWORD=payload-must-not-appear' > "${attempt_root}/source/existing-notifier.env"
    printf '%s\n' control > "${attempt_root}/source/control-state.json"
    printf '%s\n' '{"teams":1,"channels":2,"channel_members":3,"active_users":4,"inactive_users":0,"posts":5,"files":6}' > "${attempt_root}/baseline.json"
    find "${attempt_root}" -type f -exec chmod 0600 {} \;
    # shellcheck source=../scripts/existing-notifier-v010-v020-common.sh
    source "${COMMON}"
    SUDO_COMMAND=(env)

    v010_v020_capture_verify_evidence "${attempt_root}" || return 1
    jq -e '.schema == 1 and .profile == "existing-notifier-v010-v020" and (.entries | length >= 11)' "${attempt_root}/manifest.json" >/dev/null || return 1
    [[ "$(jq -r '.phase' "${attempt_root}/phase.json")" == complete ]] || return 1
    ! grep -R -F -e payload-must-not-appear -e private@valid.test "${attempt_root}/manifest.json" "${attempt_root}/phase.json" >/dev/null
)

test_complete_source_capture_is_reverified_without_mutation() (
    fixture="$(mktemp -d)"
    trap 'rm -rf -- "${fixture}"' EXIT
    notifier_root="${fixture}/notifier"
    attempt_root="${notifier_root}/migration/existing-notifier-v010-v020"
    mkdir -p "${attempt_root}/source/mailer" "${attempt_root}/source/plugin-runtime" "${attempt_root}/source/release"
    printf '%s\n' '{"schema_version":1,"events":0,"nonces":0,"pending":0,"sending":0,"sent":0,"failed":0,"cancelled":0}' > "${attempt_root}/queue-inspection.json"
    printf '%s\n' queue > "${attempt_root}/source/mailer/queue.db"
    printf '%s\n' plugin > "${attempt_root}/source/plugin-runtime/plugin.json"
    printf '%s\n' bundle > "${attempt_root}/source/plugin-bundle.tar.gz"
    mkdir -p "${fixture}/image" && printf '%s\n' layer > "${fixture}/image/layer"
    tar -cf "${attempt_root}/source/mailer-image.tar" -C "${fixture}/image" layer
    printf '%s\n' 'sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' > "${attempt_root}/source/mailer-image-id"
    printf '%s\n' release > "${attempt_root}/source/release/release.env"
    printf '%s\n' override > "${attempt_root}/source/compose.override.yml"
    printf '%s\n' source-env > "${attempt_root}/source/existing-notifier.env"
    printf '%s\n' control > "${attempt_root}/source/control-state.json"
    printf '%s\n' '{"teams":1,"channels":2,"channel_members":3,"active_users":4,"inactive_users":0,"posts":5,"files":6}' > "${attempt_root}/baseline.json"
    find "${attempt_root}" -type f -exec chmod 0600 {} \;
    # shellcheck source=../scripts/existing-notifier-v010-v020-common.sh
    source "${COMMON}"
    SUDO_COMMAND=(env)
    v010_v020_capture_verify_evidence "${attempt_root}" || return 1
    existing_notifier_v010_v020_value() {
        [[ "$1" == THN_DATA_ROOT ]] || return 1
        printf '%s\n' "${notifier_root}"
    }
    existing_notifier_v010_v020_capture_identity() {
        local relative
        if [[ "$1" == "${attempt_root}" ]]; then
            printf '%s\n' 0:0:700
            return
        fi
        relative="${1#"${attempt_root}/"}"
        jq -er --arg path "${relative}" '.entries[] | select(.path == $path) | .identity' \
            "${attempt_root}/manifest.json"
    }
    before="$(shasum -a 256 "${attempt_root}/manifest.json" "${attempt_root}/phase.json")"
    existing_notifier_v010_v020_source_capture_is_complete "${attempt_root}" || return 1
    [[ "${before}" == "$(shasum -a 256 "${attempt_root}/manifest.json" "${attempt_root}/phase.json")" ]] || return 1
    printf '%s\n' tampered > "${attempt_root}/source/mailer/queue.db"
    ! existing_notifier_v010_v020_source_capture_is_complete "${attempt_root}"
)

test_attempt_root_is_exact_private_and_no_clobber() (
    fixture="$(mktemp -d)"
    trap 'rm -rf -- "${fixture}"' EXIT
    migration_root="${fixture}/migration"
    attempt_root="${migration_root}/existing-notifier-v010-v020"
    mkdir -m 0700 "${migration_root}"
    # shellcheck source=../scripts/existing-notifier-v010-v020-common.sh
    source "${COMMON}"
    SUDO_COMMAND=(env)
    existing_notifier_v010_v020_capture_identity() { printf '%s\n' 0:0:700; }
    existing_notifier_v010_v020_capture_create_attempt() { mkdir -m 0700 "$1"; }

    existing_notifier_v010_v020_capture_prepare_attempt "${attempt_root}" || return 1
    [[ -d "${attempt_root}" && ! -L "${attempt_root}" ]] || return 1
    ! existing_notifier_v010_v020_capture_prepare_attempt "${attempt_root}" || return 1
    linked="${fixture}/linked-attempt"
    ln -s "${fixture}/outside" "${linked}"
    ! existing_notifier_v010_v020_capture_prepare_attempt "${linked}" || return 1
    mkdir "${fixture}/bad-parent"
    existing_notifier_v010_v020_capture_identity() { printf '%s\n' 0:0:750; }
    ! existing_notifier_v010_v020_capture_prepare_attempt "${fixture}/bad-parent/attempt"
)

test_baseline_capture_uses_only_fixed_count_query() (
    fixture="$(mktemp -d)"
    trap 'rm -rf -- "${fixture}"' EXIT
    attempt_root="${fixture}/attempt"
    mkdir -p "${attempt_root}"
    calls="${fixture}/calls"
    : > "${calls}"
    # shellcheck source=../scripts/existing-notifier-v010-v020-common.sh
    source "${COMMON}"
    SUDO_COMMAND=(env)
    EXISTING_NOTIFIER_V010_V020_POSTGRES_SERVICE=postgres
    existing_notifier_v010_v020_compose_combined() {
        printf '%s\n' "$*" > "${calls}"
        printf '%s\n' '{"teams":2,"channels":3,"channel_members":4,"active_users":5,"inactive_users":1,"posts":7,"files":8}'
    }

    v010_v020_capture_baseline "${attempt_root}" || return 1
    existing_notifier_v010_v020_baseline_is_valid "${attempt_root}/baseline.json" || return 1
    grep -F 'SELECT json_build_object' "${calls}" >/dev/null || return 1
    grep -F 'count(*) FROM channelmembers' "${calls}" >/dev/null || return 1
    ! grep -E -i 'select[[:space:]]+(email|username|name|message|path|filename)' "${calls}" >/dev/null
)

run_test 'recovery-gate command exists' test_gate_script_exists
if [[ -f "${GATE_SCRIPT}" ]]; then
    run_test 'record requires a TTY and exact human confirmation' test_record_requires_tty_and_exact_confirmation
    run_test 'record is no-clobber and check is read-only' test_record_is_no_clobber_and_check_is_read_only
    run_test 'capture uses the exact order and refuses a second attempt' test_capture_uses_exact_order_and_refuses_second_attempt
    run_test 'capture stops at every failed safety gate' test_capture_stops_at_every_failed_safety_gate
    run_test 'queue capture includes only database, WAL, and SHM' test_queue_capture_includes_only_database_wal_and_shm
    run_test 'baseline contains only nonnegative aggregate counts' test_baseline_contains_only_nonnegative_aggregate_counts
    run_test 'control, stopped Mailer, and schema-v1 queue gates are enforced' test_control_mailer_and_queue_schema_gates
    run_test 'source files and Mailer image are captured privately' test_source_files_and_mailer_image_are_captured_privately
    run_test 'source plugin capture preserves the plugin root layout' test_source_plugin_capture_preserves_the_plugin_root_layout
    run_test 'evidence manifest is complete and contains no payload values' test_evidence_manifest_is_complete_and_contains_no_payload_values
    run_test 'complete source capture is reverified without mutation' test_complete_source_capture_is_reverified_without_mutation
    run_test 'attempt root is exact, private, and no-clobber' test_attempt_root_is_exact_private_and_no_clobber
    run_test 'baseline capture uses only the fixed aggregate-count query' test_baseline_capture_uses_only_fixed_count_query
fi

if ((failures > 0)); then
    exit 1
fi
