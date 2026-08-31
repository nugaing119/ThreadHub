#!/usr/bin/env bash

set -Eeuo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_DEPLOY_DIR="$(cd "${TEST_DIR}/.." && pwd)"
LIBRARY="${TEST_DEPLOY_DIR}/scripts/existing-notifier-common.sh"
failures=0

readonly FIXTURE_USERNAME='fixture-existing-private-user'
readonly FIXTURE_PASSWORD='fixture-existing-private-password'
readonly FIXTURE_HMAC='1111111111111111111111111111111111111111111111111111111111111111'

fail() {
    printf 'not ok - %s\n' "$1" >&2
    failures=$((failures + 1))
}

pass() {
    printf 'ok - %s\n' "$1"
}

run_test() {
    local name="$1" function_name="$2"

    if "${function_name}"; then
        pass "${name}"
    else
        fail "${name}"
    fi
}

write_valid_config() {
    local path="$1"

    cat > "${path}" <<EOF
THN_COMPOSE_PROJECT_DIR=/opt/existing-mm
THN_COMPOSE_FILE=/opt/existing-mm/compose.yml
THN_COMPOSE_ENV_FILE=/opt/existing-mm/.env
THN_MATTERMOST_SERVICE=mattermost
THN_MATTERMOST_PLUGINS_ROOT=/srv/existing-mm/plugins
THN_MATTERMOST_DATA_ROOT=/srv/existing-mm/data
THN_DATA_ROOT=/srv/threadhub-notifier
THN_DOMAIN=mattermost.valid.test
THN_SMTP_SERVER=smtp.email.ap-singapore-1.oci.oraclecloud.com
THN_SMTP_PORT=587
THN_SMTP_CA_FILE=/etc/ssl/certs/ca-certificates.crt
THN_SMTP_USERNAME=${FIXTURE_USERNAME}
THN_SMTP_PASSWORD=${FIXTURE_PASSWORD}
THN_SMTP_FROM_ADDRESS=no-reply@valid.test
THN_SMTP_REPLY_TO_ADDRESS=admin@valid.test
THN_SMTP_FEEDBACK_NAME=ThreadHub
THN_HMAC_SECRET=${FIXTURE_HMAC}
THN_RATE_PER_MINUTE=10
EOF
    chmod 0600 "${path}"
}

assert_private_output() {
    local output="$1"

    ! grep -F -e "${FIXTURE_USERNAME}" -e "${FIXTURE_PASSWORD}" -e "${FIXTURE_HMAC}" \
        "${output}" >/dev/null 2>&1
}

run_validation() {
    local config="$1" output="$2"

    set +e
    THREADHUB_EXISTING_NOTIFIER_ENV_FILE="${config}" \
        bash -c 'set -Eeuo pipefail; source "$1"; existing_notifier_validate_config' \
        bash "${LIBRARY}" > "${output}" 2>&1
    result=$?
    set -e
    return "${result}"
}

prepare_fixture() {
    fixture="$(mktemp -d)"
    config="${fixture}/existing-notifier.env"
    output="${fixture}/output"
    write_valid_config "${config}"
}

test_library_exists() {
    [[ -f "${LIBRARY}" ]]
}

test_valid_config_and_compose_order() (
    prepare_fixture
    trap 'rm -rf "${fixture}"' EXIT
    run_validation "${config}" "${output}" || return 1
    assert_private_output "${output}" || return 1

    THREADHUB_EXISTING_NOTIFIER_ENV_FILE="${config}"
    export THREADHUB_EXISTING_NOTIFIER_ENV_FILE
    # shellcheck source=../scripts/existing-notifier-common.sh
    source "${LIBRARY}"
    DOCKER_COMMAND=(docker)
    existing_notifier_init_compose
    [[ "${EXISTING_NOTIFIER_BASE_COMPOSE[*]}" == \
        'docker compose --project-directory /opt/existing-mm --env-file /opt/existing-mm/.env -f /opt/existing-mm/compose.yml' ]] || return 1
    [[ "${EXISTING_NOTIFIER_COMBINED_COMPOSE[*]}" == \
        "docker compose --project-directory /opt/existing-mm --env-file /opt/existing-mm/.env -f /opt/existing-mm/compose.yml --env-file ${config} -f /srv/threadhub-notifier/compose.override.yml" ]]
)

test_mode_0644_returns_action_required_without_disclosure() (
    prepare_fixture
    trap 'rm -rf "${fixture}"' EXIT
    chmod 0644 "${config}"
    set +e
    run_validation "${config}" "${output}"
    result=$?
    set -e
    [[ "${result}" == 20 ]] || return 1
    assert_private_output "${output}"
)

test_symlink_config_returns_action_required_without_disclosure() (
    prepare_fixture
    trap 'rm -rf "${fixture}"' EXIT
    mv "${config}" "${config}.real"
    ln -s "${config}.real" "${config}"
    set +e
    run_validation "${config}" "${output}"
    result=$?
    set -e
    [[ "${result}" == 20 ]] || return 1
    assert_private_output "${output}"
)

test_unknown_and_duplicate_keys_are_rejected() (
    prepare_fixture
    trap 'rm -rf "${fixture}"' EXIT
    printf '%s\n' 'THN_UNKNOWN=value' "THN_SMTP_USERNAME=${FIXTURE_USERNAME}" >> "${config}"
    ! run_validation "${config}" "${output}" || return 1
    assert_private_output "${output}"
)

test_relative_paths_are_rejected() (
    prepare_fixture
    trap 'rm -rf "${fixture}"' EXIT
    sed -i.bak 's#THN_COMPOSE_FILE=/opt/existing-mm/compose.yml#THN_COMPOSE_FILE=compose.yml#' "${config}"
    rm -f "${config}.bak"
    ! run_validation "${config}" "${output}" || return 1
    assert_private_output "${output}"
)

test_nested_notifier_root_is_rejected() (
    prepare_fixture
    trap 'rm -rf "${fixture}"' EXIT
    sed -i.bak 's#THN_DATA_ROOT=/srv/threadhub-notifier#THN_DATA_ROOT=/srv/existing-mm/data/notifier#' "${config}"
    rm -f "${config}.bak"
    ! run_validation "${config}" "${output}" || return 1
    assert_private_output "${output}"
)

test_service_name_injection_is_rejected() (
    prepare_fixture
    trap 'rm -rf "${fixture}"' EXIT
    sed -i.bak 's/THN_MATTERMOST_SERVICE=mattermost/THN_MATTERMOST_SERVICE=mattermost:evil/' "${config}"
    rm -f "${config}.bak"
    ! run_validation "${config}" "${output}" || return 1
    assert_private_output "${output}"
)

test_smtp_port_hmac_and_rate_boundaries_are_rejected() (
    prepare_fixture
    trap 'rm -rf "${fixture}"' EXIT
    sed -i.bak -e 's/THN_SMTP_PORT=587/THN_SMTP_PORT=25/' \
        -e 's/^THN_HMAC_SECRET=.*/THN_HMAC_SECRET=abcd/' \
        -e 's/THN_RATE_PER_MINUTE=10/THN_RATE_PER_MINUTE=61/' "${config}"
    rm -f "${config}.bak"
    ! run_validation "${config}" "${output}" || return 1
    assert_private_output "${output}"
)

test_unprefixed_notifier_key_is_rejected() (
    prepare_fixture
    trap 'rm -rf "${fixture}"' EXIT
    printf '%s\n' 'NOTIFIER_MODE=all_channels' >> "${config}"
    ! run_validation "${config}" "${output}" || return 1
    assert_private_output "${output}"
)

run_test 'existing notifier configuration library exists' test_library_exists
if [[ -f "${LIBRARY}" ]]; then
    run_test 'valid configuration produces ordered base and combined Compose commands' test_valid_config_and_compose_order
    run_test 'mode 0644 configuration stops with action required without disclosure' test_mode_0644_returns_action_required_without_disclosure
    run_test 'symbolic-link configuration stops with action required without disclosure' test_symlink_config_returns_action_required_without_disclosure
    run_test 'unknown and duplicate keys are rejected without disclosure' test_unknown_and_duplicate_keys_are_rejected
    run_test 'relative Compose paths are rejected without disclosure' test_relative_paths_are_rejected
    run_test 'notifier root nested in Mattermost data is rejected' test_nested_notifier_root_is_rejected
    run_test 'unsafe Mattermost service names are rejected' test_service_name_injection_is_rejected
    run_test 'SMTP port HMAC and rate boundaries are enforced' test_smtp_port_hmac_and_rate_boundaries_are_rejected
    run_test 'unprefixed notifier keys are rejected' test_unprefixed_notifier_key_is_rejected
fi

if ((failures > 0)); then
    exit 1
fi
