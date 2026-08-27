#!/usr/bin/env bash

set -Eeuo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_DEPLOY_DIR="$(cd "${TEST_DIR}/.." && pwd)"
failures=0

readonly TARGET_FINGERPRINT='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
readonly STALE_FINGERPRINT='bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
readonly FIXTURE_HMAC='1111111111111111111111111111111111111111111111111111111111111111'
readonly FIXTURE_RECIPIENT='security-recipient@threadhub.invalid'
readonly FIXTURE_CHANNEL='cccccccccccccccccccccccccc'

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

    if "${function_name}"; then
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

file_hash() {
    openssl dgst -sha256 "$1" | awk '{ print $NF }'
}

write_runtime_env() {
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
${smtp_username_key}=security-fixture-user
${smtp_password_key}=security-fixture-password
SMTP_FROM_ADDRESS=sender@threadhub.invalid
SMTP_REPLY_TO_ADDRESS=reply@threadhub.invalid
SMTP_FEEDBACK_NAME=ThreadHub
NOTIFIER_ENABLED=true
NOTIFIER_MODE=all_channels
NOTIFIER_CHANNEL_IDS=
NOTIFIER_HMAC_SECRET=${FIXTURE_HMAC}
NOTIFIER_RATE_PER_MINUTE=10
EOF
    chmod 0600 "${path}"
}

notifier_test_privileged() {
    local command_name="$1"
    shift
    local filtered=()

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
                -fT) filtered+=(-f); shift ;;
                *) filtered+=("$1"); shift ;;
            esac
        done
        command mv "${filtered[@]}"
        return
    fi
    command "${command_name}" "$@"
}

test_target_bound_smtp_uses_one_shot_strict_json_without_secret_process_state() (
    fixture="$(mktemp -d)"
    trap 'rm -rf "${fixture}"' EXIT
    env_file="${fixture}/runtime.env"
    marker_file="${fixture}/smtp-acceptance.json"
    trace_file="${fixture}/compose.trace"
    write_runtime_env "${env_file}"
    # shellcheck disable=SC2030 # isolated fixture environment in this subshell
    THREADHUB_ENV_FILE="${env_file}"
    export THREADHUB_ENV_FILE
    # shellcheck source=../scripts/common.sh
    source "${TEST_DEPLOY_DIR}/scripts/common.sh"
    # shellcheck source=../scripts/notifier-lib.sh
    source "${TEST_DEPLOY_DIR}/scripts/notifier-lib.sh"
    SUDO_COMMAND=(notifier_test_privileged)
    NOTIFIER_FAKE_FINGERPRINT="${TARGET_FINGERPRINT}"

    compose() {
        local arg
        for arg in "$@"; do
            [[ "${arg}" != *"${FIXTURE_HMAC}"* ]] || return 91
        done
        while IFS= read -r environment_line; do
            [[ "${environment_line}" != *"${FIXTURE_HMAC}"* ]] || return 92
        done < <(env)
        printf '%s\n' "$*" >> "${trace_file}"
        case "$*" in
            'run --rm --no-deps -T --entrypoint /threadhub-mailer threadhub-mailer config-fingerprint --json')
                printf '{"config_fingerprint":"%s"}\n' "${NOTIFIER_FAKE_FINGERPRINT}"
                ;;
            'run --rm --no-deps -T --entrypoint /threadhub-mailer threadhub-mailer smtp-test --recipient-stdin')
                IFS= read -r smtp_recipient
                [[ "${smtp_recipient}" == "${FIXTURE_RECIPIENT}" ]] || return 93
                printf '{"config_fingerprint":"%s"}\n' "${NOTIFIER_FAKE_FINGERPRINT}"
                ;;
            *) return 94 ;;
        esac
    }

    fingerprint="$(notifier_target_config_fingerprint)" || return 1
    [[ "${fingerprint}" == "${TARGET_FINGERPRINT}" ]] || return 1
    accepted="$(printf '%s\n' "${FIXTURE_RECIPIENT}" | notifier_run_smtp_acceptance)" || return 1
    [[ "${accepted}" == "${TARGET_FINGERPRINT}" ]] || return 1
    notifier_write_smtp_marker "${marker_file}" "${accepted}" 1700000000123
    notifier_smtp_marker_is_current "${marker_file}" || return 1

    NOTIFIER_FAKE_FINGERPRINT="${STALE_FINGERPRINT}"
    if notifier_smtp_marker_is_current "${marker_file}" >/dev/null 2>&1; then
        return 1
    fi
    if grep -F ' exec ' "${trace_file}" >/dev/null; then
        return 1
    fi

    compose() {
        printf '%s\n' '{"config_fingerprint":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","extra":true}'
    }
    if notifier_target_config_fingerprint >/dev/null 2>&1; then
        return 1
    fi
)

test_emergency_control_and_status_ignore_broken_runtime_env() (
    fixture="$(mktemp -d)"
    trap 'rm -rf "${fixture}"' EXIT
    state_file="${fixture}/state.json"
    queue_file="${fixture}/queue.db"
    broken_env="${fixture}/missing.env"
    output="${fixture}/output"
    printf '%s\n' 'queue-preserved' > "${queue_file}"
    queue_hash="$(file_hash "${queue_file}")"
    # shellcheck source=../scripts/common.sh
    source "${TEST_DEPLOY_DIR}/scripts/common.sh"
    # shellcheck source=../scripts/notifier-lib.sh
    source "${TEST_DEPLOY_DIR}/scripts/notifier-lib.sh"
    SUDO_COMMAND=(notifier_test_privileged)
    notifier_write_control_state \
        "${state_file}" true true allowlist "${FIXTURE_CHANNEL}" 1700000000123

    # shellcheck source=../scripts/notifier-control.sh
    source "${TEST_DEPLOY_DIR}/scripts/notifier-control.sh" >/dev/null 2>&1 || return 1
    declare -F notifier_control_dispatch >/dev/null || return 1
    SUDO_COMMAND=(notifier_test_privileged)
    THREADHUB_ENV_FILE="${broken_env}" notifier_control_dispatch \
        "${state_file}" status > "${output}" 2>&1 || return 1
    grep -F 'mode=allowlist' "${output}" >/dev/null || return 1
    grep -F 'allowlist_count=1' "${output}" >/dev/null || return 1
    ! grep -F "${FIXTURE_CHANNEL}" "${output}" >/dev/null || return 1
    THREADHUB_ENV_FILE="${broken_env}" notifier_control_dispatch \
        "${state_file}" disable >/dev/null 2>&1 || return 1
    THREADHUB_ENV_FILE="${broken_env}" notifier_control_dispatch \
        "${state_file}" drain >/dev/null 2>&1 || return 1
    jq -e '.enabled == false and .delivery_enabled == true' "${state_file}" >/dev/null || return 1
    [[ "${queue_hash}" == "$(file_hash "${queue_file}")" ]] || return 1

    # shellcheck source=../scripts/notifier-status.sh
    source "${TEST_DEPLOY_DIR}/scripts/notifier-status.sh" >/dev/null 2>&1 || return 1
    declare -F notifier_status_dispatch >/dev/null || return 1
    SUDO_COMMAND=(notifier_test_privileged)
    set +e
    THREADHUB_ENV_FILE="${broken_env}" notifier_status_dispatch \
        "${state_file}" > "${output}" 2>&1
    status_result=$?
    set -e
    [[ "${status_result}" == 20 ]] || return 1
    grep -F 'delivery_enabled=true' "${output}" >/dev/null || return 1
    grep -F 'live_diagnostics=unavailable' "${output}" >/dev/null || return 1
    ! grep -F "${FIXTURE_CHANNEL}" "${output}" >/dev/null
)

test_existing_env_checks_preserve_symlink_and_unsafe_mode() (
    fixture="$(mktemp -d)"
    trap 'rm -rf "${fixture}"' EXIT
    target="${fixture}/target.env"
    link="${fixture}/runtime.env"
    write_runtime_env "${target}"
    target_hash="$(file_hash "${target}")"
    target_mode="$(portable_mode "${target}")"
    ln -s "${target}" "${link}"
    # shellcheck source=../scripts/common.sh
    source "${TEST_DEPLOY_DIR}/scripts/common.sh"

    set +e
    runtime_env_require_secure "${link}" >/dev/null 2>&1
    link_result=$?
    set -e
    [[ "${link_result}" == 20 && -L "${link}" ]] || return 1
    [[ "${target_hash}" == "$(file_hash "${target}")" ]] || return 1
    [[ "${target_mode}" == "$(portable_mode "${target}")" ]] || return 1

    rm "${link}"
    cp "${target}" "${link}"
    chmod 0644 "${link}"
    unsafe_hash="$(file_hash "${link}")"
    set +e
    runtime_env_require_secure "${link}" >/dev/null 2>&1
    mode_result=$?
    set -e
    [[ "${mode_result}" == 20 ]] || return 1
    [[ "${unsafe_hash}" == "$(file_hash "${link}")" ]] || return 1
    [[ "$(portable_mode "${link}")" == 644 ]]
)

test_env_publication_never_clobbers_fresh_or_concurrent_sentinel() (
    fixture="$(mktemp -d)"
    trap 'rm -rf "${fixture}"' EXIT
    destination="${fixture}/runtime.env"
    temporary="${fixture}/runtime.tmp"
    sentinel="${fixture}/sentinel"
    # shellcheck source=../scripts/common.sh
    source "${TEST_DEPLOY_DIR}/scripts/common.sh"
    printf '%s\n' 'fresh-content' > "${temporary}"
    chmod 0600 "${temporary}"
    printf '%s\n' 'sentinel-content' > "${sentinel}"
    sentinel_hash="$(file_hash "${sentinel}")"
    ln -s "${sentinel}" "${destination}"
    if runtime_env_publish_no_clobber "${temporary}" "${destination}" >/dev/null 2>&1; then
        return 1
    fi
    [[ -L "${destination}" && "${sentinel_hash}" == "$(file_hash "${sentinel}")" ]] || return 1

    rm "${destination}"
    write_runtime_env "${destination}"
    original_identity="$(runtime_env_identity "${destination}")" || return 1
    original_hash="$(file_hash "${destination}")"
    replacement="${fixture}/replacement.tmp"
    cp "${destination}" "${replacement}"
    printf '%s\n' 'NOTIFIER_ENABLED=true' >> "${replacement}"
    rm "${destination}"
    printf '%s\n' 'concurrent-sentinel' > "${destination}"
    concurrent_hash="$(file_hash "${destination}")"
    if runtime_env_replace_if_unchanged \
        "${replacement}" "${destination}" "${original_identity}" "${original_hash}" \
        >/dev/null 2>&1; then
        return 1
    fi
    [[ "${concurrent_hash}" == "$(file_hash "${destination}")" ]]
)

test_noninteractive_smtp_handoff_wins_even_with_tty() (
    fixture="$(mktemp -d)"
    trap 'rm -rf "${fixture}"' EXIT
    driver="${fixture}/driver.sh"
    output="${fixture}/output"
    cat > "${driver}" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
source '${TEST_DEPLOY_DIR}/scripts/common.sh'
source '${TEST_DEPLOY_DIR}/scripts/notifier-lib.sh'
set +e
notifier_require_smtp_handoff true
result=\$?
set -e
exit "\${result}"
EOF
    chmod 0700 "${driver}"

    set +e
    python3 - "${driver}" "${output}" <<'PY'
import os
import pty
import sys

driver, output = sys.argv[1:]
pid, fd = pty.fork()
if pid == 0:
    os.execv("/bin/bash", ["bash", driver])
chunks = []
while True:
    try:
        chunk = os.read(fd, 4096)
    except OSError:
        break
    if not chunk:
        break
    chunks.append(chunk)
_, status = os.waitpid(pid, 0)
with open(output, "wb") as handle:
    handle.write(b"".join(chunks))
sys.exit(os.waitstatus_to_exitcode(status))
PY
    result=$?
    set -e
    [[ "${result}" == 20 ]] || return 1
    tr -d '\r' < "${output}" > "${output}.normalized"
    [[ "$(<"${output}.normalized")" == $'[ACTION REQUIRED] Run ./deploy/scripts/notifier-smtp-test.sh in an interactive terminal.\nThen rerun: ./deploy/scripts/setup-wizard.sh --resume --non-interactive' ]]
)

run_test \
    'target-bound SMTP uses one-shot strict JSON without secret process state' \
    test_target_bound_smtp_uses_one_shot_strict_json_without_secret_process_state
run_test \
    'emergency control and actual status remain available with broken runtime env' \
    test_emergency_control_and_status_ignore_broken_runtime_env
run_test \
    'existing env safety rejects symlink and unsafe mode without mutation' \
    test_existing_env_checks_preserve_symlink_and_unsafe_mode
run_test \
    'fresh and configured env publication preserves concurrent sentinels' \
    test_env_publication_never_clobbers_fresh_or_concurrent_sentinel
run_test \
    'non-interactive SMTP handoff wins even when stdin is a TTY' \
    test_noninteractive_smtp_handoff_wins_even_with_tty

((failures == 0))
