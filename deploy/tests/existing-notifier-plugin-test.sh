#!/usr/bin/env bash

# Sourced plugin helpers consume these fixture command arrays dynamically.
# shellcheck disable=SC2034

set -Eeuo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_DEPLOY_DIR="$(cd "${TEST_DIR}/.." && pwd)"
INSTALL_LIBRARY="${TEST_DEPLOY_DIR}/scripts/notifier-plugin-install-lib.sh"
ARTIFACT_LIBRARY="${TEST_DEPLOY_DIR}/scripts/notifier-artifact-build-lib.sh"
EXISTING_WRAPPER="${TEST_DEPLOY_DIR}/scripts/existing-notifier-plugin.sh"
failures=0

fail() { printf 'not ok - %s\n' "$1" >&2; failures=$((failures + 1)); }
pass() { printf 'ok - %s\n' "$1"; }
run_test() { if "$2"; then pass "$1"; else fail "$1"; fi; }

portable_mode() {
    if stat -c '%a' "$1" >/dev/null 2>&1; then stat -c '%a' "$1"; else stat -f '%Lp' "$1"; fi
}

fixture_privileged() {
    local command_name="$1"
    shift
    local filtered=()
    local path
    local uid=2000
    local gid=2000

    if [[ "${command_name}" == stat && "${1:-}" == -c && "${2:-}" == '%u:%g:%a' ]]; then
        path="$3"
        case "${path}" in
            "${notifier_root}"|"${release_dir}"|"${release_dir}/plugin-backups") uid=0; gid=0 ;;
            "${release_dir}/release.env") uid=0; gid=0 ;;
            "${notifier_root}/control") uid=0; gid=3000 ;;
        esac
        printf '%s:%s:%s\n' "${uid}" "${gid}" "$(portable_mode "${path}")"
        return
    fi
    if [[ "${command_name}" == stat && "${1:-}" == -c && "${2:-}" == '%d' ]]; then
        if [[ "${FIXTURE_INVALID_DEVICE:-false}" == true ]]; then
            printf 'not-a-device\n'
            return
        fi
        if stat -c '%d' "$3" >/dev/null 2>&1; then
            stat -c '%d' "$3"
        else
            stat -f '%d' "$3"
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
    if [[ "${command_name}" == mv ]]; then
        while (($# > 0)); do
            case "$1" in
                -T|--) shift ;;
                -fT) filtered+=(-f); shift ;;
                *) filtered+=("$1"); shift ;;
            esac
        done
        command mv "${filtered[@]}"
        return
    fi
    command "${command_name}" "$@"
}

fixture_docker_engine() {
    [[ "$1" == image && "$2" == inspect && "$3" == --format ]] || return 1
    printf 'sha256:%064d\n' 0
}

fixture_compose() {
    local command_name="$1"
    shift
    printf '%s' "${command_name}" >> "${compose_calls}"
    if (($# > 0)); then printf ' %s' "$@" >> "${compose_calls}"; fi
    printf '\n' >> "${compose_calls}"

    case "${command_name}" in
        ps)
            [[ "$1" == -q && "$2" == "${mattermost_service}" ]] || return 1
            [[ "$(${REAL_CAT} "${service_state}")" == running ]] && printf '%064d\n' 1
            ;;
        stop)
            [[ "$1" == "${mattermost_service}" ]] || return 1
            printf 'stopped\n' > "${service_state}"
            ;;
        up)
            [[ "$*" == "-d --no-deps --wait --wait-timeout 240 ${mattermost_service}" ]] || return 1
            printf 'running\n' > "${service_state}"
            if [[ -f "${target_root}/plugin.json" ]]; then
                printf 'inactive\n' > "${plugin_state}"
            else
                printf 'missing\n' > "${plugin_state}"
            fi
            if [[ "${FIXTURE_DELETE_BUNDLE_ON_UP:-false}" == true ]]; then
                rm -f "${bundle_target}"
            fi
            ;;
        exec)
            [[ "$1" == -T && "$2" == "${mattermost_service}" && "$3" == mmctl && "$4" == plugin ]] || return 1
            action="$5"
            case "${action}" in
                list)
                    if [[ ! -f "${target_root}/plugin.json" ]]; then
                        printf '%s\n' '{"active":[],"inactive":[]}'
                        return
                    fi
                    version="$(jq -er '.version' "${target_root}/plugin.json")" || return 1
                    state="$(${REAL_CAT} "${plugin_state}")"
                    if [[ "${state}" == active ]]; then
                        jq -cn --arg version "${version}" \
                            '{active:[{id:"com.threadhub.channel-email-notifier",version:$version}],inactive:[]}'
                    else
                        jq -cn --arg version "${version}" \
                            '{active:[],inactive:[{id:"com.threadhub.channel-email-notifier",version:$version}]}'
                    fi
                    ;;
                enable)
                    version="$(jq -er '.version' "${target_root}/plugin.json")" || return 1
                    if [[ "${FIXTURE_FAIL_NEW_ENABLE:-false}" == true && "${version}" == 0.1.0 ]]; then
                        return 91
                    fi
                    printf 'active\n' > "${plugin_state}"
                    ;;
                disable)
                    printf 'inactive\n' > "${plugin_state}"
                    ;;
                *) return 1 ;;
            esac
            ;;
        *) return 1 ;;
    esac
}

fixture_disabled_compose() {
    local config_key=""

    if [[ "$1" == exec && "$2" == -T && "$3" == "${mattermost_service}" \
        && "$4" == mmctl ]]; then
        if [[ "$5" == plugin && "$6" == list \
            && "$("${REAL_CAT}" "${plugin_runtime_state}")" == disabled ]]; then
            printf '%s\n' 'exec -T existing-mm mmctl plugin list --local --suppress-warnings --json' \
                >> "${compose_calls}"
            return 92
        fi
        if [[ "$5" == config && "$6" == get ]]; then
            config_key="$7"
            printf '%s' "$1" >> "${compose_calls}"
            shift
            printf ' %s' "$@" >> "${compose_calls}"
            printf '\n' >> "${compose_calls}"
            case "${config_key}" in
                PluginSettings.Enable)
                    [[ "$("${REAL_CAT}" "${plugin_runtime_state}")" == enabled ]] \
                        && printf 'true\n' || printf 'false\n'
                    ;;
                PluginSettings.PluginStates) printf '{}\n' ;;
                *) return 1 ;;
            esac
            return
        fi
    fi
    if [[ "$1" == up ]]; then
        printf 'enabled\n' > "${plugin_runtime_state}"
    fi
    fixture_compose "$@"
}

fixture_base_compose() {
    printf '%s' "$1" >> "${base_compose_calls}"
    if (($# > 1)); then printf ' %s' "${@:2}" >> "${base_compose_calls}"; fi
    printf '\n' >> "${base_compose_calls}"
    if [[ "$1" == up ]]; then
        printf 'disabled\n' > "${plugin_runtime_state}"
    fi
    fixture_compose "$@"
}

create_reviewed_tree() {
    local root="$1"
    local version="$2"
    mkdir -p "${root}/server/dist"
    printf '%s\n' \
        "{\"description\":\"reviewed\",\"homepage_url\":\"https://threadhub.invalid\",\"id\":\"${plugin_id}\",\"min_server_version\":\"11.7.7\",\"name\":\"ThreadHub Notifier\",\"server\":{\"executables\":{\"linux-amd64\":\"server/dist/plugin-linux-amd64\"}},\"support_url\":\"https://threadhub.invalid\",\"version\":\"${version}\"}" \
        > "${root}/plugin.json"
    printf 'reviewed-executable-%s\n' "${version}" > "${root}/server/dist/plugin-linux-amd64"
    chmod 0755 "${root}/server/dist/plugin-linux-amd64"
}

create_reviewed_bundle() {
    local reviewed_parent="$1"
    local bundle="$2"
    COPYFILE_DISABLE=1 tar -czf "${bundle}" -C "${reviewed_parent}" "${plugin_id}"
}

write_release_identity() {
    local bundle_sha="$1"
    local source_commit
    source_commit="$(git -C "${REPOSITORY_ROOT}" rev-parse --verify 'HEAD^{commit}')"
    cat > "${release_dir}/release.env" <<EOF
NOTIFIER_VERSION=0.1.0
NOTIFIER_PLUGIN_ID=${plugin_id}
NOTIFIER_PLUGIN_BUNDLE=notifier/dist/${plugin_id}-0.1.0.tar.gz
NOTIFIER_PLUGIN_BUNDLE_SHA256=${bundle_sha}
NOTIFIER_MAILER_IMAGE=threadhub/notifier-mailer:0.1.0
NOTIFIER_MAILER_IMAGE_ID=sha256:0000000000000000000000000000000000000000000000000000000000000000
NOTIFIER_SOURCE_COMMIT=${source_commit}
EOF
    chmod 0640 "${release_dir}/release.env"
}

prepare_fixture() {
    fixture="$(mktemp -d)"
    REPOSITORY_ROOT="${fixture}/repository"
    notifier_root="${fixture}/notifier-runtime"
    release_dir="${notifier_root}/release"
    plugins_root="${fixture}/external-mattermost/plugins"
    filestore_root="${fixture}/external-mattermost/data/plugins"
    target_root="${plugins_root}/com.threadhub.channel-email-notifier"
    bundle_target="${filestore_root}/com.threadhub.channel-email-notifier.tar.gz"
    mattermost_service=existing-mm
    compose_calls="${fixture}/compose.calls"
    base_compose_calls="${fixture}/base-compose.calls"
    service_state="${fixture}/service.state"
    plugin_state="${fixture}/plugin.state"
    plugin_runtime_state="${fixture}/plugin-runtime.state"
    reviewed_parent="${fixture}/reviewed"
    reviewed_root="${reviewed_parent}/com.threadhub.channel-email-notifier"
    repository_bundle="${REPOSITORY_ROOT}/notifier/dist/com.threadhub.channel-email-notifier-0.1.0.tar.gz"
    mkdir -p \
        "${release_dir}" "${notifier_root}/control" \
        "${plugins_root}" "${filestore_root}" "${reviewed_parent}" \
        "$(dirname "${repository_bundle}")"
    git -C "${REPOSITORY_ROOT}" init -q
    git -C "${REPOSITORY_ROOT}" config user.name ThreadHub-Test
    git -C "${REPOSITORY_ROOT}" config user.email threadhub-test@invalid.example
    printf 'fixture\n' > "${REPOSITORY_ROOT}/fixture.txt"
    git -C "${REPOSITORY_ROOT}" add fixture.txt
    git -C "${REPOSITORY_ROOT}" commit -qm fixture
    chmod 0750 "${notifier_root}" "${release_dir}" "${notifier_root}/control" "${plugins_root}" "${filestore_root}"
    : > "${compose_calls}"
    : > "${base_compose_calls}"
    printf 'running\n' > "${service_state}"
    printf 'missing\n' > "${plugin_state}"
    printf 'enabled\n' > "${plugin_runtime_state}"
    create_reviewed_tree "${reviewed_root}" 0.1.0
    create_reviewed_bundle "${reviewed_parent}" "${repository_bundle}"
    bundle_sha="$(sha256_file "${repository_bundle}")"
    write_release_identity "${bundle_sha}"
    SUDO_COMMAND=(fixture_privileged)
    DOCKER_COMMAND=(fixture_docker_engine)
}

cleanup_fixture() {
    rm -rf "${fixture}"
}

test_external_layout_installs_exact_pair_and_only_selected_service() (
    prepare_fixture
    trap cleanup_fixture EXIT
    notifier_install_reviewed_pair \
        "${release_dir}" "${plugins_root}" "${filestore_root}" \
        fixture_compose "${mattermost_service}" || return 1
    notifier_plugin_tree_is_exact "${target_root}" "${reviewed_root}" "${fixture}" || return 1
    notifier_plugin_bundle_is_exact "${bundle_target}" "${bundle_sha}" || return 1
    grep -Fx 'up -d --no-deps --wait --wait-timeout 240 existing-mm' "${compose_calls}" >/dev/null || return 1
    ! grep -E '(^| )mattermost($| )' "${compose_calls}" >/dev/null || return 1
    jq -e '.enabled == false and .delivery_enabled == false and .activated_at == 0' \
        "${notifier_root}/control/state.json" >/dev/null
)

test_disabled_plugin_runtime_accepts_only_verified_absence_before_install() (
    prepare_fixture
    trap cleanup_fixture EXIT
    printf 'disabled\n' > "${plugin_runtime_state}"
    notifier_install_reviewed_pair \
        "${release_dir}" "${plugins_root}" "${filestore_root}" \
        fixture_disabled_compose "${mattermost_service}" || return 1
    [[ "$("${REAL_CAT}" "${plugin_runtime_state}")" == enabled ]] || return 1
    notifier_plugin_tree_is_exact "${target_root}" "${reviewed_root}" "${fixture}" || return 1
    notifier_plugin_bundle_is_exact "${bundle_target}" "${bundle_sha}"
)

test_failed_disabled_runtime_install_restores_base_plugin_setting() (
    prepare_fixture
    trap cleanup_fixture EXIT
    printf 'disabled\n' > "${plugin_runtime_state}"
    FIXTURE_FAIL_NEW_ENABLE=true
    export FIXTURE_FAIL_NEW_ENABLE
    set +e
    notifier_install_reviewed_pair \
        "${release_dir}" "${plugins_root}" "${filestore_root}" \
        fixture_disabled_compose "${mattermost_service}" fixture_base_compose \
        >/dev/null 2>&1
    result=$?
    set -e
    unset FIXTURE_FAIL_NEW_ENABLE
    [[ "${result}" -ne 0 ]] || return 1
    [[ "$("${REAL_CAT}" "${service_state}")" == running ]] || return 1
    [[ "$("${REAL_CAT}" "${plugin_runtime_state}")" == disabled ]] || return 1
    [[ ! -e "${target_root}" && ! -e "${bundle_target}" ]]
    grep -Fx 'up -d --no-deps --wait --wait-timeout 240 existing-mm' \
        "${base_compose_calls}" >/dev/null
)

test_failed_activation_restores_previous_pair() (
    prepare_fixture
    trap cleanup_fixture EXIT
    previous_parent="${fixture}/previous-reviewed"
    previous_root="${previous_parent}/${plugin_id}"
    previous_bundle="${fixture}/previous.tar.gz"
    mkdir -p "${previous_parent}"
    create_reviewed_tree "${previous_root}" 0.0.9
    create_reviewed_bundle "${previous_parent}" "${previous_bundle}"
    previous_sha="$(sha256_file "${previous_bundle}")"
    notifier_plugin_stage_pair \
        "${previous_bundle}" "${previous_root}" "${target_root}" "${bundle_target}" \
        "${previous_sha}" "${fixture}" || return 1
    printf 'active\n' > "${plugin_state}"

    FIXTURE_FAIL_NEW_ENABLE=true
    export FIXTURE_FAIL_NEW_ENABLE
    set +e
    notifier_install_reviewed_pair \
        "${release_dir}" "${plugins_root}" "${filestore_root}" \
        fixture_compose "${mattermost_service}" >/dev/null 2>&1
    result=$?
    set -e
    unset FIXTURE_FAIL_NEW_ENABLE

    [[ "${result}" -ne 0 ]] || return 1
    notifier_plugin_tree_is_exact "${target_root}" "${previous_root}" "${fixture}" || return 1
    notifier_plugin_bundle_is_exact "${bundle_target}" "${previous_sha}" || return 1
    [[ "$(<"${service_state}")" == running && "$(<"${plugin_state}")" == active ]] || return 1
    jq -e '.enabled == false and .delivery_enabled == false' \
        "${notifier_root}/control/state.json" >/dev/null
)

test_invalid_device_identity_fails_before_service_mutation() (
    prepare_fixture
    trap cleanup_fixture EXIT
    FIXTURE_INVALID_DEVICE=true
    export FIXTURE_INVALID_DEVICE
    set +e
    notifier_install_reviewed_pair \
        "${release_dir}" "${plugins_root}" "${filestore_root}" \
        fixture_compose "${mattermost_service}" >/dev/null 2>&1
    result=$?
    set -e
    unset FIXTURE_INVALID_DEVICE

    [[ "${result}" -ne 0 ]] || return 1
    [[ ! -e "${target_root}" && ! -e "${bundle_target}" ]] || return 1
    ! grep -E '^(stop|up) ' "${compose_calls}" >/dev/null
)

test_exact_pair_is_rechecked_after_service_synchronization() (
    prepare_fixture
    trap cleanup_fixture EXIT
    notifier_install_reviewed_pair \
        "${release_dir}" "${plugins_root}" "${filestore_root}" \
        fixture_compose "${mattermost_service}" >/dev/null || return 1
    FIXTURE_DELETE_BUNDLE_ON_UP=true
    export FIXTURE_DELETE_BUNDLE_ON_UP
    set +e
    notifier_install_reviewed_pair \
        "${release_dir}" "${plugins_root}" "${filestore_root}" \
        fixture_compose "${mattermost_service}" >/dev/null 2>&1
    result=$?
    set -e
    unset FIXTURE_DELETE_BUNDLE_ON_UP

    [[ "${result}" -ne 0 && ! -e "${bundle_target}" ]]
)

test_required_scripts_exist() {
    [[ -f "${INSTALL_LIBRARY}" && -f "${ARTIFACT_LIBRARY}" && -f "${EXISTING_WRAPPER}" ]]
}

test_artifact_release_directory_validation_is_external_and_fail_closed() (
    prepare_fixture
    trap cleanup_fixture EXIT
    notifier_validate_artifact_release_dir "${release_dir}" || return 1
    chmod 0755 "${release_dir}"
    if notifier_validate_artifact_release_dir "${release_dir}" >/dev/null 2>&1; then
        return 1
    fi
    chmod 0750 "${release_dir}"
    mv "${release_dir}" "${release_dir}.real"
    ln -s "${release_dir}.real" "${release_dir}"
    ! notifier_validate_artifact_release_dir "${release_dir}" >/dev/null 2>&1
)

test_current_artifact_release_requires_exact_bundle_and_image() (
    prepare_fixture
    trap cleanup_fixture EXIT
    notifier_artifact_release_is_current "${release_dir}" || return 1
    printf 'tampered\n' >> "${repository_bundle}"
    ! notifier_artifact_release_is_current "${release_dir}" >/dev/null 2>&1
)

REAL_CAT="$(command -v cat)"
plugin_id=com.threadhub.channel-email-notifier

run_test 'existing notifier plugin installer interfaces exist' test_required_scripts_exist
if [[ -f "${INSTALL_LIBRARY}" ]]; then
    # shellcheck source=/dev/null
    source "${TEST_DEPLOY_DIR}/scripts/common.sh"
    # shellcheck source=/dev/null
    source "${TEST_DEPLOY_DIR}/scripts/notifier-lib.sh"
    # shellcheck source=/dev/null
    source "${TEST_DEPLOY_DIR}/scripts/notifier-plugin-files.sh"
    # shellcheck source=/dev/null
    source "${TEST_DEPLOY_DIR}/scripts/notifier-plugin-transaction.sh"
    # shellcheck source=/dev/null
    source "${INSTALL_LIBRARY}"
    if [[ -f "${ARTIFACT_LIBRARY}" ]]; then
        # shellcheck source=/dev/null
        source "${ARTIFACT_LIBRARY}"
        run_test 'artifact release validation supports an external root and fails closed' test_artifact_release_directory_validation_is_external_and_fail_closed
        run_test 'current artifact release requires the exact bundle and image' test_current_artifact_release_requires_exact_bundle_and_image
    fi
    run_test 'external layout installs exact pair and only the selected service' test_external_layout_installs_exact_pair_and_only_selected_service
    run_test 'disabled plugin runtime accepts only verified absence before install' test_disabled_plugin_runtime_accepts_only_verified_absence_before_install
    run_test 'failed disabled-runtime install restores the base plugin setting' test_failed_disabled_runtime_install_restores_base_plugin_setting
    run_test 'failed activation restores the verified previous pair' test_failed_activation_restores_previous_pair
    run_test 'invalid filesystem identity fails before service mutation' test_invalid_device_identity_fails_before_service_mutation
    run_test 'exact plugin pair is rechecked after service synchronization' test_exact_pair_is_rechecked_after_service_synchronization
fi

((failures == 0))
