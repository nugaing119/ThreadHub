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
    local postgres_password_key=POSTGRES_PASSWORD
    local smtp_username_key=SMTP_USERNAME
    local smtp_password_key=SMTP_PASSWORD
    cat > "${path}" <<EOF
COMPOSE_PROJECT_NAME=threadhub
TZ=Asia/Seoul
THREADHUB_DOMAIN=threadhub.internal
LETSENCRYPT_EMAIL=admin@threadhub.internal
THREADHUB_DATA_ROOT=/srv/threadhub
MATTERMOST_BIND_ADDRESS=127.0.0.1
MATTERMOST_BIND_PORT=8065
POSTGRES_USER=mmuser
${postgres_password_key}=0000000000000000000000000000000000000000000000000000000000000000
POSTGRES_DB=mattermost
SMTP_SERVER=smtp.email.ap-seoul-1.oci.oraclecloud.com
SMTP_PORT=587
${smtp_username_key}=${FIXTURE_USERNAME}
${smtp_password_key}=${FIXTURE_PASSWORD}
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

make_gnu_publication_fakes() {
    local fake_bin="$1"

    mkdir -p "${fake_bin}"
    cat > "${fake_bin}/uname" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == -s ]] || exit 2
printf '%s\n' Linux
EOF
    cat > "${fake_bin}/mv" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
if [[ "${1:-}" == --help ]]; then
    printf '%s\n' '--no-target-directory --no-clobber'
    exit 0
fi
[[ "${1:-}" != -T ]] || shift
exec "${THREADHUB_TEST_REAL_MV}" "$@"
EOF
    cat > "${fake_bin}/ln" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
if [[ "${1:-}" == --help ]]; then
    printf '%s\n' '--no-target-directory'
    exit 0
fi
if [[ "${1:-}" == -T ]]; then
    shift
    [[ "${1:-}" == -- ]] && shift
    destination="${@: -1}"
    [[ ! -d "${destination}" && ! -L "${destination}" ]] || exit 1
fi
exec "${THREADHUB_TEST_REAL_LN}" "$@"
EOF
    chmod 0700 "${fake_bin}/uname" "${fake_bin}/mv" "${fake_bin}/ln"
}

assert_private_output() {
    local output="$1"
    local generated_hmac="${2:-}"
    local needle
    local pattern_file

    pattern_file="$(mktemp)"
    chmod 0600 "${pattern_file}"
    for needle in \
        "${FIXTURE_USERNAME}" \
        "${FIXTURE_PASSWORD}" \
        "${FIXTURE_SENDER}" \
        "${FIXTURE_RECIPIENT}" \
        "${FIXTURE_CHANNEL_A}" \
        "${FIXTURE_CHANNEL_B}" \
        "${generated_hmac}"; do
        [[ -z "${needle}" ]] && continue
        builtin printf '%s\n' "${needle}" >> "${pattern_file}"
    done
    if grep -F -q -f "${pattern_file}" "${output}"; then
        rm -f "${pattern_file}"
        return 1
    fi
    rm -f "${pattern_file}"
}

test_configure_adds_complete_defaults_without_disclosure() (
    fixture="$(mktemp -d)"
    trap 'rm -rf "${fixture}"' EXIT
    env_file="${fixture}/runtime.env"
    output="${fixture}/output"
    fake_bin="${fixture}/bin"
    real_mv="$(command -v mv)"
    real_ln="$(command -v ln)"
    write_base_env "${env_file}"
    make_gnu_publication_fakes "${fake_bin}"

    PATH="${fake_bin}:${PATH}" \
        THREADHUB_ENV_FILE="${env_file}" \
        THREADHUB_TEST_REAL_MV="${real_mv}" \
        THREADHUB_TEST_REAL_LN="${real_ln}" \
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
    fake_bin="${fixture}/bin"
    real_mv="$(command -v mv)"
    real_ln="$(command -v ln)"
    write_base_env "${env_file}"
    append_complete_notifier_env "${env_file}"
    make_gnu_publication_fakes "${fake_bin}"
    before="$(openssl dgst -sha256 "${env_file}" | awk '{ print $NF }')"

    PATH="${fake_bin}:${PATH}" \
        THREADHUB_ENV_FILE="${env_file}" \
        THREADHUB_TEST_REAL_MV="${real_mv}" \
        THREADHUB_TEST_REAL_LN="${real_ln}" \
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
    fake_bin="${fixture}/bin"
    real_mv="$(command -v mv)"
    real_ln="$(command -v ln)"
    write_base_env "${env_file}"
    printf '%s\n' 'NOTIFIER_ENABLED=true' >> "${env_file}"
    before="$(openssl dgst -sha256 "${env_file}" | awk '{ print $NF }')"
    make_gnu_publication_fakes "${fake_bin}"

    set +e
    PATH="${fake_bin}:${PATH}" \
        THREADHUB_ENV_FILE="${env_file}" \
        THREADHUB_TEST_REAL_MV="${real_mv}" \
        THREADHUB_TEST_REAL_LN="${real_ln}" \
        "${TEST_DEPLOY_DIR}/scripts/configure-notifier.sh" > "${output}" 2>&1
    result=$?
    set -e

    [[ "${result}" == 20 ]] || return 1
    [[ "${before}" == "$(openssl dgst -sha256 "${env_file}" | awk '{ print $NF }')" ]] || return 1
    grep -F '[ACTION REQUIRED] Notifier configuration is partial;' \
        "${output}" >/dev/null || return 1
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

test_smtp_marker_tracks_target_container_fingerprint_without_pii() (
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
    SUDO_COMMAND=(notifier_test_privileged)
    compose() {
        if [[ "${THREADHUB_ENV_FILE}" == "${env_file}" ]]; then
            printf '%s\n' '{"config_fingerprint":"806cc2a3463b7b29a0e62eef78a08879c492ebd781059b82e7cd51c4d55542c1"}'
        else
            printf '%s\n' '{"config_fingerprint":"fb86fe31f59c02f5907b182c20137f54f7af6de1c34efd0e3225e7e3ab26cc96"}'
        fi
    }

    original="$(notifier_target_config_fingerprint)"
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

test_privacy_detection_never_places_secret_in_grep_argv_or_output() (
    fixture="$(mktemp -d)"
    trap 'rm -rf "${fixture}"' EXIT
    fake_bin="${fixture}/bin"
    output="${fixture}/deliberate-leak"
    capture="${fixture}/capture"
    trace="${fixture}/grep-argv"
    secret='generated-hmac-deliberate-leak-should-remain-private'
    real_grep="$(command -v grep)"
    mkdir "${fake_bin}"
    cat > "${fake_bin}/grep" <<'EOF'
#!/usr/bin/env bash
printf '%s\0' "$@" >> "${THREADHUB_GREP_ARGV_TRACE}"
exec "${THREADHUB_REAL_GREP}" "$@"
EOF
    chmod 0700 "${fake_bin}/grep"
    : > "${trace}"
    chmod 0600 "${trace}"
    printf '%s\n' "${secret}" > "${output}"

    set +e
    PATH="${fake_bin}:${PATH}" \
        THREADHUB_GREP_ARGV_TRACE="${trace}" \
        THREADHUB_REAL_GREP="${real_grep}" \
        assert_private_output "${output}" "${secret}" > "${capture}" 2>&1
    result=$?
    set -e

    [[ "${result}" -ne 0 ]] || return 1
    inspect_pattern="${fixture}/inspect-pattern"
    : > "${inspect_pattern}"
    chmod 0600 "${inspect_pattern}"
    builtin printf '%s\n' "${secret}" >> "${inspect_pattern}"
    ! "${real_grep}" -F -q -f "${inspect_pattern}" "${capture}" || return 1
    ! "${real_grep}" -F -q -f "${inspect_pattern}" "${trace}"
)

test_plugin_state_normalizes_real_mmctl_shape_and_rejects_ambiguity() (
    fixture="$(mktemp -d)"
    trap 'rm -rf "${fixture}"' EXIT
    plugin_id=com.threadhub.channel-email-notifier
    version=0.1.0
    # shellcheck source=../scripts/common.sh
    source "${TEST_DEPLOY_DIR}/scripts/common.sh"
    # shellcheck source=../scripts/notifier-lib.sh
    source "${TEST_DEPLOY_DIR}/scripts/notifier-lib.sh"

    printf '%s\n' \
        '{"active":[{"id":"other","version":"2.0.0"},{"id":"com.threadhub.channel-email-notifier","version":"0.1.0"}],"inactive":[]}' \
        > "${fixture}/object.json"
    printf '%s\n' \
        '[{"active":[{"id":"com.threadhub.channel-email-notifier","version":"0.1.0"}],"inactive":[]}]' \
        > "${fixture}/singleton.json"
    notifier_plugin_list_is_exact_active "${fixture}/object.json" "${plugin_id}" "${version}" \
        || return 1
    notifier_plugin_list_is_exact_active "${fixture}/singleton.json" "${plugin_id}" "${version}" \
        || return 1
    [[ "$(notifier_plugin_list_target_state "${fixture}/singleton.json" "${plugin_id}")" == $'active\t0.1.0' ]] \
        || return 1

    while IFS='|' read -r name payload; do
        printf '%s\n' "${payload}" > "${fixture}/${name}.json"
        if notifier_plugin_list_is_exact_active \
            "${fixture}/${name}.json" "${plugin_id}" "${version}" >/dev/null 2>&1; then
            return 1
        fi
    done <<'EOF'
empty-input|
empty-wrapper|[]
multi-wrapper|[{"active":[],"inactive":[]},{"active":[],"inactive":[]}]
wrong-top-type|"not-an-object"
unknown-envelope-key|{"active":[{"id":"com.threadhub.channel-email-notifier","version":"0.1.0"}],"inactive":[],"extra":true}
wrong-entry-type|{"active":["com.threadhub.channel-email-notifier"],"inactive":[]}
duplicate|{"active":[{"id":"com.threadhub.channel-email-notifier","version":"0.1.0"},{"id":"com.threadhub.channel-email-notifier","version":"0.1.0"}],"inactive":[]}
wrong-version|{"active":[{"id":"com.threadhub.channel-email-notifier","version":"0.2.0"}],"inactive":[]}
inactive|{"active":[],"inactive":[{"id":"com.threadhub.channel-email-notifier","version":"0.1.0"}]}
malformed|{"active":
EOF
    printf '%s\n' \
        '{"active":[{"id":"com.threadhub.channel-email-notifier","version":"0.1.0"}],"inactive":[]} {}' \
        > "${fixture}/trailing.json"
    ! notifier_plugin_list_is_exact_active \
        "${fixture}/trailing.json" "${plugin_id}" "${version}" >/dev/null 2>&1
)

test_successful_notifier_status_exits_zero_and_removes_temporary_diagnostics() (
    fixture="$(command mktemp -d)"
    trap 'rm -rf "${fixture}"' EXIT
    output="${fixture}/output"
    status_temp="${fixture}/status-temp"
    # shellcheck source=../scripts/notifier-status.sh
    source "${TEST_DEPLOY_DIR}/scripts/notifier-status.sh"
    SUDO_COMMAND=(env)

    validate_runtime_env() { :; }
    init_docker() { :; }
    init_sudo() { SUDO_COMMAND=(env); }
    validate_notifier_emergency_control_path() { :; }
    notifier_smtp_marker_is_current() { return 1; }
    env_value() {
        case "$1" in
            NOTIFIER_PLUGIN_ID) printf '%s' com.threadhub.channel-email-notifier ;;
            NOTIFIER_VERSION) printf '%s' 0.1.0 ;;
            *) return 1 ;;
        esac
    }
    mktemp() {
        [[ "$#" -eq 1 && "$1" == -d ]] || return 2
        mkdir "${status_temp}"
        printf '%s\n' "${status_temp}"
    }
    compose() {
        if [[ "$*" == *'threadhub-mailer'* ]]; then
            printf '%s\n' \
                '{"pending":0,"sending":0,"sent":0,"failed":0,"oldest_pending_seconds":0,"last_success_at":0,"last_error_class":"","last_smtp_code":0}'
        else
            printf '%s\n' \
                '{"active":[{"id":"com.threadhub.channel-email-notifier","version":"0.1.0"}],"inactive":[]}'
        fi
    }

    set +e
    notifier_status_entry > "${output}" 2>&1
    result=$?
    set -e

    if [[ "${result}" -ne 0 ]]; then
        sed -n '1,120p' "${output}" >&2
        return 1
    fi
    grep -F 'plugin=active' "${output}" >/dev/null || return 1
    grep -F 'pending=0' "${output}" >/dev/null || return 1
    if grep -F 'unbound variable' "${output}" >/dev/null; then
        sed -n '1,120p' "${output}" >&2
        return 1
    fi
    if [[ -e "${status_temp}" ]]; then
        printf 'temporary notifier status directory was not removed\n' >&2
        return 1
    fi
)

test_successful_notifier_activation_exits_zero_and_removes_temporary_diagnostics() (
    fixture="$(command mktemp -d)"
    trap 'rm -rf "${fixture}"' EXIT
    output="${fixture}/output"
    control_temp="${fixture}/control-temp"
    state_file="${fixture}/state.json"
    fake_scripts="${fixture}/scripts"
    mkdir "${fake_scripts}"
    printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "${fake_scripts}/health-check.sh"
    chmod 0700 "${fake_scripts}/health-check.sh"
    # shellcheck source=../scripts/notifier-control.sh
    source "${TEST_DEPLOY_DIR}/scripts/notifier-control.sh"
    SCRIPT_DIR="${fake_scripts}"
    SUDO_COMMAND=(notifier_test_privileged)

    validate_runtime_env() { :; }
    init_docker() { :; }
    notifier_smtp_marker_is_current() { return 0; }
    env_value() {
        case "$1" in
            NOTIFIER_ENABLED) printf '%s' true ;;
            NOTIFIER_MODE) printf '%s' all_channels ;;
            NOTIFIER_CHANNEL_IDS) printf '%s' '' ;;
            NOTIFIER_PLUGIN_ID) printf '%s' com.threadhub.channel-email-notifier ;;
            NOTIFIER_VERSION) printf '%s' 0.1.0 ;;
            *) return 1 ;;
        esac
    }
    env_optional_value() { printf '%s' ''; }
    mktemp() {
        if [[ "$#" -eq 1 && "$1" == -d ]]; then
            mkdir "${control_temp}"
            printf '%s\n' "${control_temp}"
        elif [[ "$#" -eq 0 ]]; then
            temporary_state="${fixture}/temporary-state.json"
            : > "${temporary_state}"
            printf '%s\n' "${temporary_state}"
        else
            return 2
        fi
    }
    compose() {
        if [[ "${1:-}" == port ]]; then
            return 0
        fi
        if [[ "$*" == *'mattermost'* ]]; then
            printf '%s\n' \
                '{"active":[{"id":"com.threadhub.channel-email-notifier","version":"0.1.0"}],"inactive":[]}'
        elif [[ "$*" == *'status --json'* ]]; then
            printf '%s\n' \
                '{"pending":0,"sending":0,"sent":0,"failed":0,"oldest_pending_seconds":0,"last_success_at":0,"last_error_class":"","last_smtp_code":0}'
        fi
    }
    notifier_test_control_entry() {
        notifier_control_dispatch "${state_file}" "$@"
    }

    set +e
    notifier_test_control_entry activate --from-env > "${output}" 2>&1
    result=$?
    set -e

    if [[ "${result}" -ne 0 ]]; then
        sed -n '1,120p' "${output}" >&2
        return 1
    fi
    notifier_control_is_valid "${state_file}" || return 1
    jq -e '.enabled == true and .delivery_enabled == true and .activated_at > 0' \
        "${state_file}" >/dev/null || return 1
    if grep -F 'unbound variable' "${output}" >/dev/null; then
        sed -n '1,120p' "${output}" >&2
        return 1
    fi
    if [[ -e "${control_temp}" ]]; then
        printf 'temporary notifier control directory was not removed\n' >&2
        return 1
    fi
)

test_all_plugin_state_consumers_use_the_shared_fail_closed_parser() (
    for script_name in \
        readiness-check.sh notifier-control.sh notifier-status.sh; do
        script="${TEST_DEPLOY_DIR}/scripts/${script_name}"
        # Match the literal source expression; expansion is not intended.
        # shellcheck disable=SC2016
        grep -F 'source "${SCRIPT_DIR}/notifier-lib.sh"' "${script}" >/dev/null \
            || return 1
        grep -F 'notifier_plugin_list_is_exact_active' "${script}" >/dev/null \
            || return 1
    done
    grep -F 'source "${SCRIPT_DIR}/notifier-lib.sh"' \
        "${TEST_DEPLOY_DIR}/scripts/install-notifier-plugin.sh" >/dev/null || return 1
    grep -F 'source "${SCRIPT_DIR}/notifier-plugin-install-lib.sh"' \
        "${TEST_DEPLOY_DIR}/scripts/install-notifier-plugin.sh" >/dev/null || return 1
    grep -F 'notifier_plugin_list_is_exact_active' \
        "${TEST_DEPLOY_DIR}/scripts/notifier-plugin-install-lib.sh" >/dev/null
)

notifier_test_plugin_files_privileged() {
    local command_name="$1"
    shift
    local filtered=()

    if [[ "${command_name}" == stat && "${1:-}" == -c && "${2:-}" == '%u:%g:%a' ]]; then
        printf '2000:2000:%s\n' "$(portable_mode "$3")"
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
    if [[ "${command_name}" == mv ]]; then
        while (($# > 0)); do
            case "$1" in
                -T|--) shift ;;
                *) filtered+=("$1"); shift ;;
            esac
        done
        command mv "${filtered[@]}"
        return
    fi
    command "${command_name}" "$@"
}

make_reviewed_plugin_pair_fixture() {
    local fixture="$1"
    local version="$2"
    local plugin_id=com.threadhub.channel-email-notifier
    local reviewed_root="${fixture}/reviewed/${plugin_id}"
    local reviewed_bundle="${fixture}/reviewed.tar.gz"
    local runtime_root="${fixture}/runtime/${plugin_id}"
    local bundle_target="${fixture}/filestore/${plugin_id}.tar.gz"
    local expected_sha

    mkdir -p \
        "${reviewed_root}/server/dist" \
        "${fixture}/runtime" \
        "${fixture}/filestore" \
        "${fixture}/scratch"
    printf '%s\n' \
        "{\"description\":\"reviewed\",\"homepage_url\":\"https://threadhub.invalid\",\"id\":\"${plugin_id}\",\"min_server_version\":\"11.7.7\",\"name\":\"ThreadHub Notifier\",\"server\":{\"executables\":{\"linux-amd64\":\"server/dist/plugin-linux-amd64\"}},\"support_url\":\"https://threadhub.invalid\",\"version\":\"${version}\"}" \
        > "${reviewed_root}/plugin.json"
    printf 'reviewed-executable-%s\n' "${version}" \
        > "${reviewed_root}/server/dist/plugin-linux-amd64"
    COPYFILE_DISABLE=1 tar -czf "${reviewed_bundle}" \
        -C "${fixture}/reviewed" "${plugin_id}"
    expected_sha="$(openssl dgst -sha256 "${reviewed_bundle}" | awk '{print $NF}')"
    notifier_plugin_stage_pair \
        "${reviewed_bundle}" "${reviewed_root}" "${runtime_root}" "${bundle_target}" \
        "${expected_sha}" "${fixture}/scratch"
}

test_plugin_filestore_bundle_requires_exact_sha_identity_and_mode() (
    fixture="$(mktemp -d)"
    trap 'rm -rf "${fixture}"' EXIT
    library="${TEST_DEPLOY_DIR}/scripts/notifier-plugin-files.sh"
    [[ -f "${library}" ]] || return 1
    # shellcheck source=/dev/null
    source "${library}"
    SUDO_COMMAND=(notifier_test_plugin_files_privileged)
    bundle="${fixture}/com.threadhub.channel-email-notifier.tar.gz"
    printf 'reviewed-bundle-bytes\n' > "${bundle}"
    chmod 0640 "${bundle}"
    expected_sha="$(openssl dgst -sha256 "${bundle}" | awk '{print $NF}')"

    notifier_plugin_bundle_is_exact "${bundle}" "${expected_sha}" || return 1
    chmod 0644 "${bundle}"
    if notifier_plugin_bundle_is_exact "${bundle}" "${expected_sha}" >/dev/null 2>&1; then
        return 1
    fi
    chmod 0640 "${bundle}"
    if notifier_plugin_bundle_is_exact "${bundle}" "$(printf '0%.0s' {1..64})" >/dev/null 2>&1; then
        return 1
    fi
    mv "${bundle}" "${fixture}/referent"
    ln -s "${fixture}/referent" "${bundle}"
    ! notifier_plugin_bundle_is_exact "${bundle}" "${expected_sha}" >/dev/null 2>&1
)

test_plugin_pair_presence_requires_both_objects_or_neither() (
    fixture="$(mktemp -d)"
    trap 'rm -rf "${fixture}"' EXIT
    # shellcheck source=/dev/null
    source "${TEST_DEPLOY_DIR}/scripts/notifier-plugin-files.sh"
    SUDO_COMMAND=(env)

    runtime="${fixture}/plugins/com.threadhub.channel-email-notifier"
    bundle="${fixture}/data/plugins/com.threadhub.channel-email-notifier.tar.gz"
    mkdir -p "$(dirname "${runtime}")" "$(dirname "${bundle}")"

    [[ "$(notifier_plugin_pair_presence "${runtime}" "${bundle}")" == absent ]] \
        || return 1
    mkdir "${runtime}"
    if notifier_plugin_pair_presence "${runtime}" "${bundle}" >/dev/null 2>&1; then
        return 1
    fi
    rmdir "${runtime}"
    printf 'bundle-only\n' > "${bundle}"
    if notifier_plugin_pair_presence "${runtime}" "${bundle}" >/dev/null 2>&1; then
        return 1
    fi
    mkdir "${runtime}"
    [[ "$(notifier_plugin_pair_presence "${runtime}" "${bundle}")" == present ]]
)

test_prior_plugin_pair_capture_validates_archive_tree_identity_and_metadata() (
    fixture="$(mktemp -d)"
    trap 'rm -rf "${fixture}"' EXIT
    # shellcheck source=/dev/null
    source "${TEST_DEPLOY_DIR}/scripts/notifier-plugin-files.sh"
    SUDO_COMMAND=(notifier_test_plugin_files_privileged)
    plugin_id=com.threadhub.channel-email-notifier
    version=0.0.9
    runtime_root="${fixture}/runtime/${plugin_id}"
    bundle_target="${fixture}/filestore/${plugin_id}.tar.gz"
    reviewed_root="${fixture}/reviewed/${plugin_id}"
    scratch="${fixture}/scratch"

    make_reviewed_plugin_pair_fixture "${fixture}" "${version}" || return 1
    expected_sha="$(openssl dgst -sha256 "${bundle_target}" | awk '{print $NF}')"
    metadata="$(notifier_plugin_capture_pair \
        "${runtime_root}" "${bundle_target}" "${plugin_id}" \
        "${fixture}/captured-good" "${scratch}")" || return 1
    [[ "${metadata}" == $'0.0.9\t'"${expected_sha}" ]] || return 1
    notifier_plugin_pair_is_exact \
        "${runtime_root}" "${bundle_target}" "${fixture}/captured-good/${plugin_id}" \
        "${expected_sha}" "${scratch}" || return 1

    printf 'tampered-runtime\n' \
        > "${runtime_root}/server/dist/plugin-linux-amd64"
    chmod 0755 "${runtime_root}/server/dist/plugin-linux-amd64"
    if notifier_plugin_capture_pair \
        "${runtime_root}" "${bundle_target}" "${plugin_id}" \
        "${fixture}/captured-mismatch" "${scratch}" >/dev/null 2>&1; then
        return 1
    fi
    install -m 0755 "${reviewed_root}/server/dist/plugin-linux-amd64" \
        "${runtime_root}/server/dist/plugin-linux-amd64"

    chmod 0640 "${runtime_root}/server/dist/plugin-linux-amd64"
    if notifier_plugin_capture_pair \
        "${runtime_root}" "${bundle_target}" "${plugin_id}" \
        "${fixture}/captured-mode" "${scratch}" >/dev/null 2>&1; then
        return 1
    fi
    chmod 0755 "${runtime_root}/server/dist/plugin-linux-amd64"

    rm "${runtime_root}/server/dist/plugin-linux-amd64"
    ln -s "${fixture}/referent" "${runtime_root}/server/dist/plugin-linux-amd64"
    printf 'do-not-follow\n' > "${fixture}/referent"
    if notifier_plugin_capture_pair \
        "${runtime_root}" "${bundle_target}" "${plugin_id}" \
        "${fixture}/captured-runtime-link" "${scratch}" >/dev/null 2>&1; then
        return 1
    fi
    rm "${runtime_root}/server/dist/plugin-linux-amd64"
    install -m 0755 "${reviewed_root}/server/dist/plugin-linux-amd64" \
        "${runtime_root}/server/dist/plugin-linux-amd64"

    unsafe_root="${fixture}/unsafe/${plugin_id}"
    mkdir -p "${unsafe_root}/server/dist"
    cp "${reviewed_root}/plugin.json" "${unsafe_root}/plugin.json"
    ln -s /etc/passwd "${unsafe_root}/server/dist/plugin-linux-amd64"
    COPYFILE_DISABLE=1 tar -czf "${fixture}/unsafe.tar.gz" \
        -C "${fixture}/unsafe" "${plugin_id}"
    install -m 0640 "${fixture}/unsafe.tar.gz" "${bundle_target}"
    if notifier_plugin_capture_pair \
        "${runtime_root}" "${bundle_target}" "${plugin_id}" \
        "${fixture}/captured-archive-link" "${scratch}" >/dev/null 2>&1; then
        return 1
    fi

    wrong_root="${fixture}/wrong/${plugin_id}"
    mkdir -p "${wrong_root}/server/dist"
    printf '%s\n' \
        "{\"description\":\"reviewed\",\"homepage_url\":\"https://threadhub.invalid\",\"id\":\"wrong.plugin.id\",\"min_server_version\":\"11.7.7\",\"name\":\"ThreadHub Notifier\",\"server\":{\"executables\":{\"linux-amd64\":\"server/dist/plugin-linux-amd64\"}},\"support_url\":\"https://threadhub.invalid\",\"version\":\"${version}\"}" \
        > "${wrong_root}/plugin.json"
    cp "${reviewed_root}/server/dist/plugin-linux-amd64" \
        "${wrong_root}/server/dist/plugin-linux-amd64"
    COPYFILE_DISABLE=1 tar -czf "${fixture}/wrong.tar.gz" \
        -C "${fixture}/wrong" "${plugin_id}"
    install -m 0640 "${fixture}/wrong.tar.gz" "${bundle_target}"
    ! notifier_plugin_capture_pair \
        "${runtime_root}" "${bundle_target}" "${plugin_id}" \
        "${fixture}/captured-wrong-id" "${scratch}" >/dev/null 2>&1
)

test_post_start_pair_verification_rejects_deleted_or_replaced_objects() (
    fixture="$(mktemp -d)"
    trap 'rm -rf "${fixture}"' EXIT
    # shellcheck source=/dev/null
    source "${TEST_DEPLOY_DIR}/scripts/notifier-plugin-files.sh"
    SUDO_COMMAND=(notifier_test_plugin_files_privileged)
    plugin_id=com.threadhub.channel-email-notifier
    runtime_root="${fixture}/runtime/${plugin_id}"
    bundle_target="${fixture}/filestore/${plugin_id}.tar.gz"
    reviewed_root="${fixture}/reviewed/${plugin_id}"
    scratch="${fixture}/scratch"

    make_reviewed_plugin_pair_fixture "${fixture}" 0.1.0 || return 1
    expected_sha="$(openssl dgst -sha256 "${bundle_target}" | awk '{print $NF}')"
    notifier_plugin_pair_is_exact \
        "${runtime_root}" "${bundle_target}" "${reviewed_root}" \
        "${expected_sha}" "${scratch}" || return 1

    mv "${bundle_target}" "${fixture}/saved-bundle"
    if notifier_plugin_pair_is_exact \
        "${runtime_root}" "${bundle_target}" "${reviewed_root}" \
        "${expected_sha}" "${scratch}" >/dev/null 2>&1; then
        return 1
    fi
    mv "${fixture}/saved-bundle" "${bundle_target}"

    mv "${runtime_root}" "${fixture}/saved-runtime"
    mkdir -p "${runtime_root}/server/dist"
    printf 'replacement\n' > "${runtime_root}/plugin.json"
    printf 'replacement\n' > "${runtime_root}/server/dist/plugin-linux-amd64"
    chmod 0744 "${runtime_root}" "${runtime_root}/server" "${runtime_root}/server/dist"
    chmod 0755 "${runtime_root}/server/dist/plugin-linux-amd64"
    chmod 0644 "${runtime_root}/plugin.json"
    ! notifier_plugin_pair_is_exact \
        "${runtime_root}" "${bundle_target}" "${reviewed_root}" \
        "${expected_sha}" "${scratch}" >/dev/null 2>&1
)

test_prior_pair_recovery_evidence_survives_post_start_deletion() (
    fixture="$(mktemp -d)"
    trap 'rm -rf "${fixture}"' EXIT
    # shellcheck source=/dev/null
    source "${TEST_DEPLOY_DIR}/scripts/notifier-plugin-files.sh"
    SUDO_COMMAND=(notifier_test_plugin_files_privileged)
    plugin_id=com.threadhub.channel-email-notifier
    runtime_root="${fixture}/runtime/${plugin_id}"
    bundle_target="${fixture}/filestore/${plugin_id}.tar.gz"
    reviewed_root="${fixture}/reviewed/${plugin_id}"
    evidence_root="${fixture}/evidence/runtime"
    evidence_bundle="${fixture}/evidence/bundle.tar.gz"
    scratch="${fixture}/scratch"

    make_reviewed_plugin_pair_fixture "${fixture}" 0.1.0 || return 1
    mkdir "${fixture}/evidence"
    expected_sha="$(openssl dgst -sha256 "${bundle_target}" | awk '{print $NF}')"
    notifier_plugin_preserve_pair \
        "${runtime_root}" "${bundle_target}" \
        "${evidence_root}" "${evidence_bundle}" \
        "${reviewed_root}" "${expected_sha}" "${scratch}" || return 1
    notifier_plugin_pair_is_exact \
        "${evidence_root}" "${evidence_bundle}" "${reviewed_root}" \
        "${expected_sha}" "${scratch}" || return 1

    rm "${bundle_target}"
    notifier_plugin_pair_is_exact \
        "${evidence_root}" "${evidence_bundle}" "${reviewed_root}" \
        "${expected_sha}" "${scratch}"
)

test_plugin_pair_staging_materializes_only_the_reviewed_objects() (
    fixture="$(mktemp -d)"
    trap 'rm -rf "${fixture}"' EXIT
    library="${TEST_DEPLOY_DIR}/scripts/notifier-plugin-files.sh"
    [[ -f "${library}" ]] || return 1
    # shellcheck source=/dev/null
    source "${library}"
    SUDO_COMMAND=(notifier_test_plugin_files_privileged)

    reviewed_root="${fixture}/reviewed/com.threadhub.channel-email-notifier"
    bundle="${fixture}/reviewed/plugin.tar.gz"
    runtime_stage="${fixture}/release/runtime.stage"
    bundle_stage="${fixture}/release/bundle.stage.tar.gz"
    scratch="${fixture}/scratch"
    mkdir -p "${reviewed_root}/server/dist" "${fixture}/release" "${scratch}"
    printf '%s\n' '{"reviewed":true}' > "${reviewed_root}/plugin.json"
    printf '%s\n' 'reviewed-executable' > "${reviewed_root}/server/dist/plugin-linux-amd64"
    printf '%s\n' 'reviewed-bundle-bytes' > "${bundle}"
    expected_sha="$(openssl dgst -sha256 "${bundle}" | awk '{print $NF}')"

    notifier_plugin_stage_pair \
        "${bundle}" "${reviewed_root}" "${runtime_stage}" "${bundle_stage}" \
        "${expected_sha}" "${scratch}" || return 1
    notifier_plugin_tree_is_exact "${runtime_stage}" "${reviewed_root}" "${scratch}" \
        || return 1
    notifier_plugin_bundle_is_exact "${bundle_stage}" "${expected_sha}" || return 1
    [[ "$(portable_mode "${runtime_stage}")" == 744 ]] || return 1
    [[ "$(portable_mode "${runtime_stage}/plugin.json")" == 644 ]] || return 1
    [[ "$(portable_mode "${runtime_stage}/server/dist/plugin-linux-amd64")" == 755 ]] \
        || return 1

    rm -rf "${runtime_stage}"
    rm -f "${bundle_stage}"
    referent="${fixture}/bundle-referent"
    printf '%s\n' 'must-not-change' > "${referent}"
    referent_sha="$(openssl dgst -sha256 "${referent}" | awk '{print $NF}')"
    ln -s "${referent}" "${bundle_stage}"
    if notifier_plugin_stage_pair \
        "${bundle}" "${reviewed_root}" "${runtime_stage}" "${bundle_stage}" \
        "${expected_sha}" "${scratch}" >/dev/null 2>&1; then
        return 1
    fi
    [[ -L "${bundle_stage}" ]] || return 1
    [[ "${referent_sha}" == "$(openssl dgst -sha256 "${referent}" | awk '{print $NF}')" ]]
)

test_plugin_move_rejects_symlink_and_directory_races_without_clobber() (
    fixture="$(mktemp -d)"
    trap 'rm -rf "${fixture}"' EXIT
    # shellcheck source=/dev/null
    source "${TEST_DEPLOY_DIR}/scripts/notifier-plugin-files.sh"
    SUDO_COMMAND=(notifier_test_plugin_files_privileged)

    printf '%s\n' reviewed > "${fixture}/source"
    notifier_plugin_move_no_clobber "${fixture}/source" "${fixture}/published" || return 1
    [[ ! -e "${fixture}/source" && "$(<"${fixture}/published")" == reviewed ]] || return 1

    printf '%s\n' second > "${fixture}/source"
    printf '%s\n' sentinel > "${fixture}/referent"
    referent_sha="$(openssl dgst -sha256 "${fixture}/referent" | awk '{print $NF}')"
    ln -s "${fixture}/referent" "${fixture}/destination"
    if notifier_plugin_move_no_clobber \
        "${fixture}/source" "${fixture}/destination" >/dev/null 2>&1; then
        return 1
    fi
    [[ -f "${fixture}/source" && -L "${fixture}/destination" ]] || return 1
    [[ "${referent_sha}" == "$(openssl dgst -sha256 "${fixture}/referent" | awk '{print $NF}')" ]] \
        || return 1

    rm "${fixture}/destination"
    mkdir "${fixture}/destination"
    if notifier_plugin_move_no_clobber \
        "${fixture}/source" "${fixture}/destination" >/dev/null 2>&1; then
        return 1
    fi
    [[ -f "${fixture}/source" ]] || return 1
    [[ -z "$(find "${fixture}/destination" -mindepth 1 -print -quit)" ]]
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
    'SMTP acceptance marker tracks the target container fingerprint and stays PII-free' \
    test_smtp_marker_tracks_target_container_fingerprint_without_pii
run_test \
    'activation rejects pre-activation work and records a fresh millisecond cutoff' \
    test_activation_requires_empty_queue_and_uses_fresh_cutoff
run_test \
    'drain and disable preserve queue data while status hides channel IDs' \
    test_drain_and_disable_preserve_data_and_hide_ids
run_test \
    'non-interactive SMTP acceptance prints the exact safe handoff' \
    test_noninteractive_smtp_test_prints_exact_handoff
run_test \
    'privacy leak detection keeps secrets out of grep argv and diagnostics' \
    test_privacy_detection_never_places_secret_in_grep_argv_or_output
run_test \
    'plugin state normalizes real mmctl singleton output and rejects ambiguity' \
    test_plugin_state_normalizes_real_mmctl_shape_and_rejects_ambiguity
run_test \
    'successful notifier status exits zero and removes temporary diagnostics' \
    test_successful_notifier_status_exits_zero_and_removes_temporary_diagnostics
run_test \
    'successful notifier activation exits zero and removes temporary diagnostics' \
    test_successful_notifier_activation_exits_zero_and_removes_temporary_diagnostics
run_test \
    'all production plugin-state consumers use the shared fail-closed parser' \
    test_all_plugin_state_consumers_use_the_shared_fail_closed_parser
run_test \
    'plugin filestore bundle requires exact SHA ownership and mode' \
    test_plugin_filestore_bundle_requires_exact_sha_identity_and_mode
run_test \
    'plugin pair presence requires both runtime and filestore objects or neither' \
    test_plugin_pair_presence_requires_both_objects_or_neither
run_test \
    'prior plugin pair capture validates archive tree identity and verified metadata' \
    test_prior_plugin_pair_capture_validates_archive_tree_identity_and_metadata
run_test \
    'post-start pair verification rejects deleted or replaced production objects' \
    test_post_start_pair_verification_rejects_deleted_or_replaced_objects
run_test \
    'verified prior pair recovery evidence survives post-start deletion' \
    test_prior_pair_recovery_evidence_survives_post_start_deletion
run_test \
    'plugin pair staging materializes only the reviewed runtime tree and filestore bundle' \
    test_plugin_pair_staging_materializes_only_the_reviewed_objects
run_test \
    'plugin publication rejects symlink and directory races without clobbering' \
    test_plugin_move_rejects_symlink_and_directory_races_without_clobber

((failures == 0))
