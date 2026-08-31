#!/usr/bin/env bash

set -Eeuo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_DEPLOY_DIR="$(cd "${TEST_DIR}/.." && pwd)"
PREFLIGHT="${TEST_DEPLOY_DIR}/scripts/existing-notifier-preflight.sh"
failures=0

fail() {
    printf 'not ok - %s\n' "$1" >&2
    failures=$((failures + 1))
}

pass() {
    printf 'ok - %s\n' "$1"
}

run_test() {
    local name="$1" function_name="$2"
    if "${function_name}"; then pass "${name}"; else fail "${name}"; fi
}

portable_hash() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        shasum -a 256 "$1" | awk '{print $1}'
    fi
}

prepare_fixture() {
    fixture="$(mktemp -d)"
    project_dir="${fixture}/existing"
    compose_file="${project_dir}/compose.yml"
    existing_env="${project_dir}/.env"
    plugins_root="${fixture}/mattermost/plugins"
    data_root="${fixture}/mattermost/data"
    notifier_root="${fixture}/notifier"
    config="${fixture}/existing-notifier.env"
    model="${fixture}/model.json"
    calls="${fixture}/calls"
    output="${fixture}/output"
    mkdir -p "${project_dir}" "${plugins_root}" "${data_root}"
    printf '%s\n' 'services:' '  mattermost:' '    image: mattermost/mattermost-team-edition:11.7.7' > "${compose_file}"
    printf '%s\n' 'EXISTING_VALUE=preserved' > "${existing_env}"
    chmod 0600 "${existing_env}"
    cat > "${config}" <<EOF
THN_COMPOSE_PROJECT_DIR=${project_dir}
THN_COMPOSE_FILE=${compose_file}
THN_COMPOSE_ENV_FILE=${existing_env}
THN_MATTERMOST_SERVICE=mattermost
THN_MATTERMOST_PLUGINS_ROOT=${plugins_root}
THN_MATTERMOST_DATA_ROOT=${data_root}
THN_DATA_ROOT=${notifier_root}
THN_DOMAIN=mattermost.valid.test
THN_SMTP_SERVER=smtp.email.ap-singapore-1.oci.oraclecloud.com
THN_SMTP_PORT=587
THN_SMTP_USERNAME=fixture-private-user
THN_SMTP_PASSWORD=fixture-private-password
THN_SMTP_FROM_ADDRESS=no-reply@valid.test
THN_SMTP_REPLY_TO_ADDRESS=admin@valid.test
THN_SMTP_FEEDBACK_NAME=ThreadHub
THN_HMAC_SECRET=1111111111111111111111111111111111111111111111111111111111111111
THN_RATE_PER_MINUTE=10
EOF
    chmod 0600 "${config}"
    write_supported_model
    : > "${calls}"
    fixture_version=11.7.7
    fixture_site_url=https://mattermost.valid.test
    fixture_plugin_json='{"active":[],"inactive":[]}'
}

write_supported_model() {
    jq -n \
        --arg plugins "${plugins_root}" \
        --arg data "${data_root}" '
        {
          services:{
            mattermost:{
              image:"mattermost/mattermost-team-edition:11.7.7",
              environment:{EXISTING_VALUE:"preserved"},
              volumes:[
                {type:"bind",source:$plugins,target:"/mattermost/plugins",read_only:false},
                {type:"bind",source:$data,target:"/mattermost/data",read_only:false}
              ],
              networks:{existing:{}},
              healthcheck:{test:["CMD","curl","-f","http://localhost:8065/api/v4/system/ping"]},
              restart:"unless-stopped"
            }
          },
          networks:{existing:{}}
        }
    ' > "${model}"
}

fake_compose() {
    printf '%s\n' "$*" >> "${calls}"
    case "$*" in
        'config --quiet') return 0 ;;
        'config --format json') cat "${model}" ;;
        'ps -q mattermost') printf '%s\n' aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ;;
        'exec -T mattermost mattermost version')
            printf 'Version: %s\nBuild Enterprise Ready: false\n' "${fixture_version}"
            ;;
        'exec -T mattermost mmctl config get ServiceSettings.SiteURL --local --suppress-warnings')
            printf '%s\n' "${fixture_site_url}"
            ;;
        'exec -T mattermost mmctl plugin list --local --suppress-warnings --json')
            printf '%s\n' "${fixture_plugin_json}"
            ;;
        *) return 2 ;;
    esac
}

run_preflight() {
    THREADHUB_EXISTING_NOTIFIER_ENV_FILE="${config}"
    export THREADHUB_EXISTING_NOTIFIER_ENV_FILE
    # shellcheck source=../scripts/existing-notifier-preflight.sh
    source "${PREFLIGHT}"
    require_ubuntu_amd64() { :; }
    init_docker() { DOCKER_COMMAND=(docker); }
    init_sudo() { SUDO_COMMAND=(env); }
    existing_notifier_init_compose() { :; }
    existing_notifier_compose_base() { fake_compose "$@"; }
    if [[ "${fixture_installed_reviewed:-false}" == true ]]; then
        existing_notifier_installed_target_plugin_is_reviewed() { return 0; }
    fi
    existing_notifier_preflight_entry "$@"
}

assert_private_output() {
    ! grep -F -e fixture-private-user -e fixture-private-password \
        -e 1111111111111111111111111111111111111111111111111111111111111111 \
        "${output}" >/dev/null 2>&1
}

assert_action_required_result() {
    local result="$1"

    if [[ "${result}" != 20 ]]; then
        printf 'unexpected preflight exit=%s\n' "${result}" >&2
        return 1
    fi
}

test_preflight_exists() {
    [[ -f "${PREFLIGHT}" ]]
}

test_supported_model_is_read_only() (
    prepare_fixture
    trap 'rm -rf "${fixture}"' EXIT
    compose_before="$(portable_hash "${compose_file}")"
    env_before="$(portable_hash "${existing_env}")"
    run_preflight > "${output}" 2>&1 || return 1
    [[ "${compose_before}" == "$(portable_hash "${compose_file}")" ]] || return 1
    [[ "${env_before}" == "$(portable_hash "${existing_env}")" ]] || return 1
    [[ ! -e "${notifier_root}" ]] || return 1
    ! grep -Eq '(^| )(up|create|start|restart|cp|rm)( |$)' "${calls}" || return 1
    grep -F '[OK] Mattermost Team Edition 11.7.7 single-node Compose model' "${output}" >/dev/null || return 1
    assert_private_output
)

test_unsupported_version_exits_twenty_before_writes() (
    prepare_fixture
    trap 'rm -rf "${fixture}"' EXIT
    fixture_version=11.8.0
    set +e
    run_preflight > "${output}" 2>&1
    result=$?
    set -e
    assert_action_required_result "${result}" || return 1
    [[ ! -e "${notifier_root}" ]] || return 1
    assert_private_output
)

test_multiple_replicas_are_rejected() (
    prepare_fixture
    trap 'rm -rf "${fixture}"' EXIT
    jq '.services.mattermost.deploy={replicas:2}' "${model}" > "${model}.new"
    mv "${model}.new" "${model}"
    set +e
    run_preflight > "${output}" 2>&1
    result=$?
    set -e
    assert_action_required_result "${result}" && [[ ! -e "${notifier_root}" ]] && assert_private_output
)

test_named_plugin_volume_is_rejected() (
    prepare_fixture
    trap 'rm -rf "${fixture}"' EXIT
    jq '(.services.mattermost.volumes[] | select(.target=="/mattermost/plugins")) |= {type:"volume",source:"plugins",target:"/mattermost/plugins",read_only:false}' "${model}" > "${model}.new"
    mv "${model}.new" "${model}"
    set +e
    run_preflight > "${output}" 2>&1
    result=$?
    set -e
    assert_action_required_result "${result}" && assert_private_output
)

test_site_url_mismatch_is_rejected() (
    prepare_fixture
    trap 'rm -rf "${fixture}"' EXIT
    fixture_site_url=https://other.valid.test
    set +e
    run_preflight > "${output}" 2>&1
    result=$?
    set -e
    assert_action_required_result "${result}" && assert_private_output
)

test_existing_notifier_collision_is_rejected() (
    prepare_fixture
    trap 'rm -rf "${fixture}"' EXIT
    jq '.services["threadhub-mailer"]={image:"unexpected"}' "${model}" > "${model}.new"
    mv "${model}.new" "${model}"
    set +e
    run_preflight > "${output}" 2>&1
    result=$?
    set -e
    assert_action_required_result "${result}" && assert_private_output
)

test_symlinked_compose_is_rejected_before_docker() (
    prepare_fixture
    trap 'rm -rf "${fixture}"' EXIT
    mv "${compose_file}" "${compose_file}.real"
    ln -s "${compose_file}.real" "${compose_file}"
    set +e
    run_preflight > "${output}" 2>&1
    result=$?
    set -e
    assert_action_required_result "${result}" || return 1
    [[ ! -s "${calls}" ]] || return 1
    assert_private_output
)

test_invalid_adoption_config_exits_twenty_before_docker() (
    prepare_fixture
    trap 'rm -rf "${fixture}"' EXIT
    sed -i.bak 's/THN_MATTERMOST_SERVICE=mattermost/THN_MATTERMOST_SERVICE=mattermost:unsafe/' "${config}"
    rm -f "${config}.bak"
    set +e
    run_preflight > "${output}" 2>&1
    result=$?
    set -e
    assert_action_required_result "${result}" || return 1
    [[ ! -s "${calls}" ]] || return 1
    assert_private_output
)

test_world_readable_existing_env_is_rejected() (
    prepare_fixture
    trap 'rm -rf "${fixture}"' EXIT
    chmod 0644 "${existing_env}"
    set +e
    run_preflight > "${output}" 2>&1
    result=$?
    set -e
    assert_action_required_result "${result}" || return 1
    [[ ! -s "${calls}" ]] || return 1
    assert_private_output
)

test_missing_data_bind_is_rejected() (
    prepare_fixture
    trap 'rm -rf "${fixture}"' EXIT
    jq 'del(.services.mattermost.volumes[] | select(.target=="/mattermost/data"))' "${model}" > "${model}.new"
    mv "${model}.new" "${model}"
    set +e
    run_preflight > "${output}" 2>&1
    result=$?
    set -e
    assert_action_required_result "${result}" && assert_private_output
)

test_notifier_environment_and_network_collisions_are_rejected() (
    prepare_fixture
    trap 'rm -rf "${fixture}"' EXIT
    jq '.services.mattermost.environment.NOTIFIER_HMAC_SECRET="collision" | .networks["threadhub-notifier-internal"]={internal:true}' "${model}" > "${model}.new"
    mv "${model}.new" "${model}"
    set +e
    run_preflight > "${output}" 2>&1
    result=$?
    set -e
    assert_action_required_result "${result}" && assert_private_output
)

test_existing_target_plugin_is_rejected() (
    prepare_fixture
    trap 'rm -rf "${fixture}"' EXIT
    fixture_plugin_json='{"active":[{"id":"com.threadhub.channel-email-notifier","version":"0.1.0"}],"inactive":[]}'
    set +e
    run_preflight > "${output}" 2>&1
    result=$?
    set -e
    assert_action_required_result "${result}" && assert_private_output
)

test_reviewed_installed_plugin_is_accepted_only_for_resume() (
    prepare_fixture
    trap 'rm -rf "${fixture}"' EXIT
    mkdir -p "${plugins_root}/com.threadhub.channel-email-notifier" "${data_root}/plugins"
    printf 'reviewed\n' > "${data_root}/plugins/com.threadhub.channel-email-notifier.tar.gz"
    fixture_plugin_json='{"active":[{"id":"com.threadhub.channel-email-notifier","version":"0.1.0"}],"inactive":[]}'
    fixture_installed_reviewed=true
    run_preflight --resume > "${output}" 2>&1 || return 1
    grep -F '[OK] Reviewed installed notifier pair is safe to resume' "${output}" >/dev/null \
        && assert_private_output
)

run_test 'existing notifier preflight script exists' test_preflight_exists
if [[ -f "${PREFLIGHT}" ]]; then
    run_test 'supported preflight is read-only and PII-free' test_supported_model_is_read_only
    run_test 'unsupported Mattermost version stops before writes' test_unsupported_version_exits_twenty_before_writes
    run_test 'multiple Mattermost replicas are rejected' test_multiple_replicas_are_rejected
    run_test 'named plugin volumes are rejected' test_named_plugin_volume_is_rejected
    run_test 'Site URL mismatch is rejected' test_site_url_mismatch_is_rejected
    run_test 'existing notifier service collisions are rejected' test_existing_notifier_collision_is_rejected
    run_test 'symlinked base Compose is rejected before Docker' test_symlinked_compose_is_rejected_before_docker
    run_test 'invalid adoption configuration exits 20 before Docker' test_invalid_adoption_config_exits_twenty_before_docker
    run_test 'world-readable existing environment is rejected before Docker' test_world_readable_existing_env_is_rejected
    run_test 'missing Mattermost data bind is rejected' test_missing_data_bind_is_rejected
    run_test 'notifier environment and network collisions are rejected' test_notifier_environment_and_network_collisions_are_rejected
    run_test 'existing target plugin requires manual review' test_existing_target_plugin_is_rejected
    run_test 'reviewed installed plugin is accepted only for resume' test_reviewed_installed_plugin_is_accepted_only_for_resume
fi

if ((failures > 0)); then
    exit 1
fi
