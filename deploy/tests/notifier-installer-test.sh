#!/usr/bin/env bash

set -Eeuo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_DEPLOY_DIR="$(cd "${TEST_DIR}/.." && pwd)"
failures=0

readonly FIXTURE_USERNAME='fixture-smtp-username-private'
readonly FIXTURE_PASSWORD='fixture-smtp-password-private'
readonly FIXTURE_SENDER='sender@threadhub.invalid'
readonly FIXTURE_RECIPIENT='recipient@threadhub.invalid'
readonly FIXTURE_CHANNEL_A='aaaaaaaaaaaaaaaaaaaaaaaaaa'
readonly FIXTURE_CHANNEL_B='bbbbbbbbbbbbbbbbbbbbbbbbbb'

fail() {
    printf 'not ok - %s\n' "$1" >&2
    failures=$((failures + 1))
}

pass() {
    printf 'ok - %s\n' "$1"
}

portable_mode() {
    if stat -c '%a' "$1" >/dev/null 2>&1; then
        stat -c '%a' "$1"
    else
        stat -f '%Lp' "$1"
    fi
}

run_test() {
    local name="$1"
    local function_name="$2"

    if "${function_name}"; then
        pass "${name}"
    else
        fail "${name}"
    fi
}

write_base_env() {
    local path="$1"
    cat > "${path}" <<EOF
COMPOSE_PROJECT_NAME=threadhub
TZ=Asia/Seoul
THREADHUB_DOMAIN=threadhub.internal
LETSENCRYPT_EMAIL=admin@threadhub.internal
THREADHUB_DATA_ROOT=/srv/threadhub
MATTERMOST_BIND_ADDRESS=127.0.0.1
MATTERMOST_BIND_PORT=8065
POSTGRES_USER=mmuser
POSTGRES_PASSWORD=0000000000000000000000000000000000000000000000000000000000000000
POSTGRES_DB=mattermost
SMTP_SERVER=smtp.email.ap-seoul-1.oci.oraclecloud.com
SMTP_PORT=587
SMTP_USERNAME=${FIXTURE_USERNAME}
SMTP_PASSWORD=${FIXTURE_PASSWORD}
SMTP_FROM_ADDRESS=${FIXTURE_SENDER}
SMTP_REPLY_TO_ADDRESS=reply@threadhub.invalid
SMTP_FEEDBACK_NAME=ThreadHub
EOF
    chmod 0600 "${path}"
}

append_complete_notifier_env() {
    local path="$1"
    cat >> "${path}" <<'EOF'
NOTIFIER_ENABLED=true
NOTIFIER_MODE=all_channels
NOTIFIER_CHANNEL_IDS=
NOTIFIER_HMAC_SECRET=1111111111111111111111111111111111111111111111111111111111111111
NOTIFIER_RATE_PER_MINUTE=10
EOF
}

assert_private_output() {
    local output="$1"
    local generated_hmac="${2:-}"
    local needle

    for needle in \
        "${FIXTURE_USERNAME}" \
        "${FIXTURE_PASSWORD}" \
        "${FIXTURE_SENDER}" \
        "${FIXTURE_RECIPIENT}" \
        "${FIXTURE_CHANNEL_A}" \
        "${FIXTURE_CHANNEL_B}" \
        "${generated_hmac}"; do
        [[ -z "${needle}" ]] && continue
        if grep -F -- "${needle}" "${output}" >/dev/null; then
            return 1
        fi
    done
}

test_configure_adds_complete_defaults_without_disclosure() (
    fixture="$(mktemp -d)"
    trap 'rm -rf "${fixture}"' EXIT
    env_file="${fixture}/runtime.env"
    output="${fixture}/output"
    write_base_env "${env_file}"

    THREADHUB_ENV_FILE="${env_file}" \
        "${TEST_DEPLOY_DIR}/scripts/configure-notifier.sh" > "${output}" 2>&1 \
        || return 1

    [[ "$(portable_mode "${env_file}")" == 600 ]] || return 1
    [[ "$(grep -c '^NOTIFIER_' "${env_file}")" == 5 ]] || return 1
    [[ "$(awk -F= '$1 == "NOTIFIER_ENABLED" { print $2 }' "${env_file}")" == true ]] || return 1
    [[ "$(awk -F= '$1 == "NOTIFIER_MODE" { print $2 }' "${env_file}")" == all_channels ]] || return 1
    [[ -z "$(awk -F= '$1 == "NOTIFIER_CHANNEL_IDS" { print $2 }' "${env_file}")" ]] || return 1
    [[ "$(awk -F= '$1 == "NOTIFIER_RATE_PER_MINUTE" { print $2 }' "${env_file}")" == 10 ]] || return 1
    generated_hmac="$(awk -F= '$1 == "NOTIFIER_HMAC_SECRET" { print $2 }' "${env_file}")"
    [[ "${generated_hmac}" =~ ^[a-f0-9]{64}$ ]] || return 1
    assert_private_output "${output}" "${generated_hmac}"
)

test_configure_reuses_complete_env_byte_for_byte() (
    fixture="$(mktemp -d)"
    trap 'rm -rf "${fixture}"' EXIT
    env_file="${fixture}/runtime.env"
    output="${fixture}/output"
    write_base_env "${env_file}"
    append_complete_notifier_env "${env_file}"
    before="$(openssl dgst -sha256 "${env_file}" | awk '{ print $NF }')"

    THREADHUB_ENV_FILE="${env_file}" \
        "${TEST_DEPLOY_DIR}/scripts/configure-notifier.sh" > "${output}" 2>&1 \
        || return 1

    after="$(openssl dgst -sha256 "${env_file}" | awk '{ print $NF }')"
    [[ "${before}" == "${after}" ]] || return 1
    assert_private_output "${output}"
)

test_configure_rejects_partial_notifier_env_without_mutation() (
    fixture="$(mktemp -d)"
    trap 'rm -rf "${fixture}"' EXIT
    env_file="${fixture}/runtime.env"
    output="${fixture}/output"
    write_base_env "${env_file}"
    printf '%s\n' 'NOTIFIER_ENABLED=true' >> "${env_file}"
    before="$(openssl dgst -sha256 "${env_file}" | awk '{ print $NF }')"

    set +e
    THREADHUB_ENV_FILE="${env_file}" \
        "${TEST_DEPLOY_DIR}/scripts/configure-notifier.sh" > "${output}" 2>&1
    result=$?
    set -e

    [[ "${result}" == 20 ]] || return 1
    [[ "${before}" == "$(openssl dgst -sha256 "${env_file}" | awk '{ print $NF }')" ]] || return 1
    grep -F '[ACTION REQUIRED]' "${output}" >/dev/null || return 1
    assert_private_output "${output}"
)

test_notifier_env_validation_enforces_modes_and_unique_ids() (
    fixture="$(mktemp -d)"
    trap 'rm -rf "${fixture}"' EXIT
    env_file="${fixture}/runtime.env"
    write_base_env "${env_file}"
    append_complete_notifier_env "${env_file}"

    # shellcheck disable=SC2030 # isolated fixture environment in this subshell
    THREADHUB_ENV_FILE="${env_file}"
    export THREADHUB_ENV_FILE
    # shellcheck source=../scripts/common.sh
    source "${TEST_DEPLOY_DIR}/scripts/common.sh"
    declare -F validate_notifier_env >/dev/null || return 1
    validate_notifier_env >/dev/null 2>&1 || return 1

    sed -i.bak \
        -e 's/^NOTIFIER_MODE=.*/NOTIFIER_MODE=allowlist/' \
        -e "s/^NOTIFIER_CHANNEL_IDS=.*/NOTIFIER_CHANNEL_IDS=${FIXTURE_CHANNEL_A},${FIXTURE_CHANNEL_B}/" \
        "${env_file}"
    rm -f "${env_file}.bak"
    validate_notifier_env >/dev/null 2>&1 || return 1

    sed -i.bak \
        -e "s/^NOTIFIER_CHANNEL_IDS=.*/NOTIFIER_CHANNEL_IDS=${FIXTURE_CHANNEL_A},${FIXTURE_CHANNEL_A}/" \
        "${env_file}"
    rm -f "${env_file}.bak"
    if (validate_notifier_env) >/dev/null 2>&1; then
        return 1
    fi

    sed -i.bak \
        -e "s/^NOTIFIER_CHANNEL_IDS=.*/NOTIFIER_CHANNEL_IDS=${FIXTURE_CHANNEL_A},/" \
        "${env_file}"
    rm -f "${env_file}.bak"
    if (validate_notifier_env) >/dev/null 2>&1; then
        return 1
    fi

    sed -i.bak \
        -e 's/^NOTIFIER_MODE=.*/NOTIFIER_MODE=all_channels/' \
        "${env_file}"
    rm -f "${env_file}.bak"
    if (validate_notifier_env) >/dev/null 2>&1; then
        return 1
    fi
)

notifier_test_privileged() {
    local command_name="$1"
    shift
    local filtered=()

    if [[ "${command_name}" == install ]]; then
        while (($# > 0)); do
            case "$1" in
                -o|-g)
                    shift 2
                    ;;
                *)
                    filtered+=("$1")
                    shift
                    ;;
            esac
        done
        command install "${filtered[@]}"
        if [[ "${NOTIFIER_TEST_FAIL_INSTALL:-false}" == true ]]; then
            return 91
        fi
        return
    fi
    if [[ "${command_name}" == mv ]]; then
        while (($# > 0)); do
            case "$1" in
                -fT) filtered+=(-f); shift ;;
                *) filtered+=("$1"); shift ;;
            esac
        done
        command mv "${filtered[@]}"
        return
    fi
    command "${command_name}" "$@"
}

test_control_state_atomic_write_and_fail_closed_read() (
    fixture="$(mktemp -d)"
    trap 'rm -rf "${fixture}"' EXIT
    state_file="${fixture}/state.json"
    # shellcheck source=../scripts/common.sh
    source "${TEST_DEPLOY_DIR}/scripts/common.sh"
    [[ -f "${TEST_DEPLOY_DIR}/scripts/notifier-lib.sh" ]] || return 1
    # shellcheck source=../scripts/notifier-lib.sh
    source "${TEST_DEPLOY_DIR}/scripts/notifier-lib.sh"
    declare -F notifier_write_control_state >/dev/null || return 1
    SUDO_COMMAND=(notifier_test_privileged)

    notifier_write_control_state \
        "${state_file}" true true all_channels '' 1700000000123
    notifier_control_is_valid "${state_file}" || return 1
    [[ "$(jq -r '.enabled' "${state_file}")" == true ]] || return 1
    [[ -z "$(find "${fixture}" -name '.state.json.tmp.*' -print -quit)" ]] || return 1

    rm -f "${state_file}"
    notifier_read_control_state_or_disabled "${state_file}" \
        | jq -e '.enabled == false and .delivery_enabled == false and .activated_at == 0' >/dev/null \
        || return 1
    printf '%s\n' '{"enabled":true}' > "${state_file}"
    notifier_read_control_state_or_disabled "${state_file}" \
        | jq -e '.enabled == false and .delivery_enabled == false and .activated_at == 0' >/dev/null
)

test_control_validation_rejects_invalid_combinations() (
    fixture="$(mktemp -d)"
    trap 'rm -rf "${fixture}"' EXIT
    state_file="${fixture}/state.json"
    # shellcheck source=../scripts/common.sh
    source "${TEST_DEPLOY_DIR}/scripts/common.sh"
    [[ -f "${TEST_DEPLOY_DIR}/scripts/notifier-lib.sh" ]] || return 1
    # shellcheck source=../scripts/notifier-lib.sh
    source "${TEST_DEPLOY_DIR}/scripts/notifier-lib.sh"
    declare -F notifier_write_control_state >/dev/null || return 1
    SUDO_COMMAND=(notifier_test_privileged)

    if notifier_write_control_state "${state_file}" true false all_channels '' 1 >/dev/null 2>&1; then
        return 1
    fi
    if notifier_write_control_state "${state_file}" true true allowlist '' 1 >/dev/null 2>&1; then
        return 1
    fi
    if notifier_write_control_state \
        "${state_file}" true true allowlist \
        "${FIXTURE_CHANNEL_A},${FIXTURE_CHANNEL_A}" 1 >/dev/null 2>&1; then
        return 1
    fi
)

test_failed_control_stage_preserves_original_without_residue() (
    fixture="$(mktemp -d)"
    trap 'rm -rf "${fixture}"' EXIT
    state_file="${fixture}/state.json"
    # shellcheck source=../scripts/common.sh
    source "${TEST_DEPLOY_DIR}/scripts/common.sh"
    [[ -f "${TEST_DEPLOY_DIR}/scripts/notifier-lib.sh" ]] || return 1
    # shellcheck source=../scripts/notifier-lib.sh
    source "${TEST_DEPLOY_DIR}/scripts/notifier-lib.sh"
    SUDO_COMMAND=(notifier_test_privileged)
    notifier_write_control_state "${state_file}" false false all_channels '' 0
    original_hash="$(openssl dgst -sha256 "${state_file}" | awk '{ print $NF }')"

    NOTIFIER_TEST_FAIL_INSTALL=true
    export NOTIFIER_TEST_FAIL_INSTALL
    if notifier_write_control_state "${state_file}" true true all_channels '' 1700000000123 \
        >/dev/null 2>&1; then
        return 1
    fi
    unset NOTIFIER_TEST_FAIL_INSTALL

    [[ "${original_hash}" == "$(openssl dgst -sha256 "${state_file}" | awk '{ print $NF }')" ]] || return 1
    [[ -z "$(find "${fixture}" -name '.state.json.tmp.*' -print -quit)" ]]
)

test_smtp_marker_fingerprint_tracks_credentials_without_pii() (
    fixture="$(mktemp -d)"
    trap 'rm -rf "${fixture}"' EXIT
    env_file="${fixture}/runtime.env"
    marker_file="${fixture}/smtp-acceptance.json"
    write_base_env "${env_file}"
    append_complete_notifier_env "${env_file}"
    # shellcheck disable=SC2030 # isolated fixture environment in this subshell
    THREADHUB_ENV_FILE="${env_file}"
    export THREADHUB_ENV_FILE
    # shellcheck source=../scripts/common.sh
    source "${TEST_DEPLOY_DIR}/scripts/common.sh"
    [[ -f "${TEST_DEPLOY_DIR}/scripts/notifier-lib.sh" ]] || return 1
    # shellcheck source=../scripts/notifier-lib.sh
    source "${TEST_DEPLOY_DIR}/scripts/notifier-lib.sh"
    declare -F notifier_smtp_fingerprint >/dev/null || return 1
    SUDO_COMMAND=(notifier_test_privileged)

    original="$(notifier_smtp_fingerprint)"
    [[ "${original}" =~ ^[a-f0-9]{64}$ ]] || return 1
    notifier_write_smtp_marker "${marker_file}" "${original}" 1700000000123
    notifier_smtp_marker_is_current "${marker_file}" || return 1
    jq -e 'keys == ["accepted_at", "fingerprint"] and (.accepted_at == 1700000000123)' \
        "${marker_file}" >/dev/null || return 1
    assert_private_output "${marker_file}" || return 1

    for key in SMTP_SERVER SMTP_PORT SMTP_USERNAME SMTP_PASSWORD SMTP_FROM_ADDRESS; do
        changed="${fixture}/${key}.env"
        cp "${env_file}" "${changed}"
        sed -i.bak "s/^${key}=.*/${key}=changed-${key}/" "${changed}"
        rm -f "${changed}.bak"
        THREADHUB_ENV_FILE="${changed}" notifier_smtp_marker_is_current "${marker_file}" \
            >/dev/null 2>&1 && return 1
    done
    return 0
)

test_activation_requires_empty_queue_and_uses_fresh_cutoff() (
    fixture="$(mktemp -d)"
    trap 'rm -rf "${fixture}"' EXIT
    state_file="${fixture}/state.json"
    status_file="${fixture}/status.json"
    # shellcheck source=../scripts/common.sh
    source "${TEST_DEPLOY_DIR}/scripts/common.sh"
    [[ -f "${TEST_DEPLOY_DIR}/scripts/notifier-lib.sh" ]] || return 1
    # shellcheck source=../scripts/notifier-lib.sh
    source "${TEST_DEPLOY_DIR}/scripts/notifier-lib.sh"
    declare -F notifier_activate_state >/dev/null || return 1
    SUDO_COMMAND=(notifier_test_privileged)
    notifier_write_control_state "${state_file}" false false all_channels '' 0
    before_hash="$(openssl dgst -sha256 "${state_file}" | awk '{ print $NF }')"

    printf '%s\n' '{"pending":1,"sending":0,"sent":0,"failed":0,"oldest_pending_seconds":0,"last_success_at":0,"last_error_class":"","last_smtp_code":0}' \
        > "${status_file}"
    if notifier_activate_state "${state_file}" all_channels '' "${status_file}" >/dev/null 2>&1; then
        return 1
    fi
    [[ "${before_hash}" == "$(openssl dgst -sha256 "${state_file}" | awk '{ print $NF }')" ]] || return 1

    printf '%s\n' '{"pending":0,"sending":0,"sent":0,"failed":0,"oldest_pending_seconds":0,"last_success_at":0,"last_error_class":"","last_smtp_code":0}' \
        > "${status_file}"
    before_ms=$(( $(date +%s) * 1000 ))
    notifier_activate_state "${state_file}" all_channels '' "${status_file}"
    activated_at="$(jq -r '.activated_at' "${state_file}")"
    [[ "$(jq -r '.enabled and .delivery_enabled' "${state_file}")" == true ]] || return 1
    ((activated_at >= before_ms && activated_at <= before_ms + 10000))
)

test_drain_and_disable_preserve_data_and_hide_ids() (
    fixture="$(mktemp -d)"
    trap 'rm -rf "${fixture}"' EXIT
    state_file="${fixture}/state.json"
    queue_file="${fixture}/queue.db"
    output="${fixture}/output"
    # shellcheck source=../scripts/common.sh
    source "${TEST_DEPLOY_DIR}/scripts/common.sh"
    [[ -f "${TEST_DEPLOY_DIR}/scripts/notifier-lib.sh" ]] || return 1
    # shellcheck source=../scripts/notifier-lib.sh
    source "${TEST_DEPLOY_DIR}/scripts/notifier-lib.sh"
    declare -F notifier_transition_control_state >/dev/null || return 1
    SUDO_COMMAND=(notifier_test_privileged)
    printf '%s\n' 'queue-must-survive' > "${queue_file}"
    queue_hash="$(openssl dgst -sha256 "${queue_file}" | awk '{ print $NF }')"
    notifier_write_control_state \
        "${state_file}" true true allowlist \
        "${FIXTURE_CHANNEL_A},${FIXTURE_CHANNEL_B}" 1700000000123

    notifier_transition_control_state "${state_file}" drain
    jq -e '.enabled == false and .delivery_enabled == true and .mode == "allowlist" and (.channel_ids | length == 2)' \
        "${state_file}" >/dev/null || return 1
    notifier_print_control_status "${state_file}" > "${output}"
    grep -F 'mode=allowlist' "${output}" >/dev/null || return 1
    grep -F 'allowlist_count=2' "${output}" >/dev/null || return 1
    assert_private_output "${output}" || return 1

    notifier_transition_control_state "${state_file}" disable
    jq -e '.enabled == false and .delivery_enabled == false and .mode == "allowlist" and (.channel_ids | length == 2)' \
        "${state_file}" >/dev/null || return 1
    [[ "${queue_hash}" == "$(openssl dgst -sha256 "${queue_file}" | awk '{ print $NF }')" ]]
)

test_noninteractive_smtp_test_prints_exact_handoff() (
    fixture="$(mktemp -d)"
    trap 'rm -rf "${fixture}"' EXIT
    output="${fixture}/output"

    set +e
    "${TEST_DEPLOY_DIR}/scripts/notifier-smtp-test.sh" </dev/null > "${output}" 2>&1
    result=$?
    set -e

    [[ "${result}" == 20 ]] || return 1
    [[ "$(<"${output}")" == $'[ACTION REQUIRED] Run ./deploy/scripts/notifier-smtp-test.sh in an interactive terminal.\nThen rerun: ./deploy/scripts/setup-wizard.sh --resume --non-interactive' ]] \
        || return 1
    assert_private_output "${output}"
)

run_test \
    'fresh notifier configuration adds complete safe defaults without disclosure' \
    test_configure_adds_complete_defaults_without_disclosure
run_test \
    'complete notifier configuration is reused byte-for-byte' \
    test_configure_reuses_complete_env_byte_for_byte
run_test \
    'partial notifier configuration requires action without mutation' \
    test_configure_rejects_partial_notifier_env_without_mutation
run_test \
    'notifier target modes require valid unique channel IDs' \
    test_notifier_env_validation_enforces_modes_and_unique_ids
run_test \
    'control state writes atomically and missing or invalid state fails closed' \
    test_control_state_atomic_write_and_fail_closed_read
run_test \
    'control state rejects unsafe enabled, delivery and allowlist combinations' \
    test_control_validation_rejects_invalid_combinations
run_test \
    'failed privileged control staging preserves the original without residue' \
    test_failed_control_stage_preserves_original_without_residue
run_test \
    'SMTP acceptance fingerprint changes with credentials while marker stays PII-free' \
    test_smtp_marker_fingerprint_tracks_credentials_without_pii
run_test \
    'activation rejects pre-activation work and records a fresh millisecond cutoff' \
    test_activation_requires_empty_queue_and_uses_fresh_cutoff
run_test \
    'drain and disable preserve queue data while status hides channel IDs' \
    test_drain_and_disable_preserve_data_and_hide_ids
run_test \
    'non-interactive SMTP acceptance prints the exact safe handoff' \
    test_noninteractive_smtp_test_prints_exact_handoff

((failures == 0))
