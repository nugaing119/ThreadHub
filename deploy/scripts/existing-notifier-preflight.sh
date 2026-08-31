#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=existing-notifier-common.sh
source "${SCRIPT_DIR}/existing-notifier-common.sh"
# shellcheck source=notifier-lib.sh
source "${SCRIPT_DIR}/notifier-lib.sh"

existing_notifier_action_required() {
    printf '[ACTION REQUIRED] %s\n' "$1" >&2
    return 20
}

existing_notifier_mode_is_not_writable_by_group_or_other() {
    local path="$1"
    local mode

    mode="$(runtime_env_mode "${path}")" || return 1
    [[ "${mode}" =~ ^[0-7]{3,4}$ ]] || return 1
    (( (8#${mode} & 0022) == 0 ))
}

existing_notifier_assert_input_paths() {
    local project_dir
    local compose_file
    local compose_env_file
    local plugins_root
    local data_root
    local path

    project_dir="$(existing_notifier_value THN_COMPOSE_PROJECT_DIR)"
    compose_file="$(existing_notifier_value THN_COMPOSE_FILE)"
    compose_env_file="$(existing_notifier_value THN_COMPOSE_ENV_FILE)"
    plugins_root="$(existing_notifier_value THN_MATTERMOST_PLUGINS_ROOT)"
    data_root="$(existing_notifier_value THN_MATTERMOST_DATA_ROOT)"

    [[ -d "${project_dir}" && ! -L "${project_dir}" ]] || return 1
    for path in "${compose_file}" "${compose_env_file}"; do
        [[ -f "${path}" && ! -L "${path}" ]] || return 1
        existing_notifier_mode_is_not_writable_by_group_or_other "${path}" || return 1
    done
    [[ "$(runtime_env_mode "${compose_env_file}")" == 600 ]] || return 1
    for path in "${plugins_root}" "${data_root}"; do
        [[ -d "${path}" && ! -L "${path}" ]] || return 1
        existing_notifier_mode_is_not_writable_by_group_or_other "${path}" || return 1
    done

    [[ ! -e "${plugins_root}/com.threadhub.channel-email-notifier"
        && ! -L "${plugins_root}/com.threadhub.channel-email-notifier" ]] || return 1
    [[ ! -e "${data_root}/plugins/com.threadhub.channel-email-notifier.tar.gz"
        && ! -L "${data_root}/plugins/com.threadhub.channel-email-notifier.tar.gz" ]] || return 1
}

existing_notifier_assert_model() {
    local model_file="$1"
    local service
    local plugins_root
    local data_root

    service="$(existing_notifier_value THN_MATTERMOST_SERVICE)"
    plugins_root="$(existing_notifier_value THN_MATTERMOST_PLUGINS_ROOT)"
    data_root="$(existing_notifier_value THN_MATTERMOST_DATA_ROOT)"

    jq -e \
        --arg service "${service}" \
        --arg plugins_root "${plugins_root}" \
        --arg data_root "${data_root}" '
        type == "object" and
        (.services | type == "object") and
        (.services | has($service)) and
        (.services | has("threadhub-mailer") | not) and
        ((.networks // {}) | has("threadhub-notifier-internal") | not) and
        ((.networks // {}) | has("threadhub-notifier-outbound") | not) and
        (.services[$service] as $mm |
          ($mm | type == "object") and
          ($mm.image | type == "string" and test("^mattermost/mattermost-team-edition:11\\.7\\.7(@sha256:[a-f0-9]{64})?$")) and
          (($mm.deploy.replicas // 1) == 1) and
          (($mm.environment // {}) | type == "object") and
          ([($mm.environment // {} | keys[]) | select(. == "THREADHUB_DOMAIN" or startswith("NOTIFIER_"))] | length == 0) and
          ([$mm.volumes[]? | select(.target == "/mattermost/plugins" and .type == "bind" and .source == $plugins_root and ((.read_only // false) == false))] | length == 1) and
          ([$mm.volumes[]? | select(.target == "/mattermost/data" and .type == "bind" and .source == $data_root and ((.read_only // false) == false))] | length == 1) and
          ([$mm.volumes[]? | select(.target == "/mattermost/plugins")] | length == 1) and
          ([$mm.volumes[]? | select(.target == "/mattermost/data")] | length == 1) and
          ([$mm.volumes[]? | select(.target == "/run/threadhub-notifier")] | length == 0) and
          (($mm.networks // {}) | has("threadhub-notifier-internal") | not)
        )
    ' "${model_file}" >/dev/null 2>&1
}

existing_notifier_single_container_id() {
    local service="$1"
    local output_file="$2"

    existing_notifier_compose_base ps -q "${service}" > "${output_file}" || return 1
    [[ "$(wc -l < "${output_file}" | tr -d '[:space:]')" == 1 ]] || return 1
    grep -Eq '^[a-f0-9]{64}$' "${output_file}"
}

existing_notifier_live_version_is_supported() {
    local service="$1"
    local output_file="$2"

    existing_notifier_compose_base exec -T "${service}" mattermost version > "${output_file}" \
        || return 1
    [[ "$(awk -F': ' '$1 == "Version" { count++; value=$2 } END { if (count != 1) exit 1; print value }' "${output_file}")" == 11.7.7 ]] \
        || return 1
    [[ "$(awk -F': ' '$1 == "Build Enterprise Ready" { count++; value=$2 } END { if (count != 1) exit 1; print value }' "${output_file}")" == false ]]
}

existing_notifier_live_site_url_matches() {
    local service="$1"
    local output_file="$2"
    local actual
    local expected

    existing_notifier_compose_base exec -T "${service}" \
        mmctl config get ServiceSettings.SiteURL --local --suppress-warnings > "${output_file}" \
        || return 1
    [[ "$(wc -l < "${output_file}" | tr -d '[:space:]')" == 1 ]] || return 1
    actual="$(tr -d '\r' < "${output_file}")"
    actual="${actual%/}"
    if [[ "${actual}" == \"*\" ]]; then
        actual="${actual:1:${#actual}-2}"
    fi
    expected="https://$(existing_notifier_value THN_DOMAIN)"
    [[ "${actual}" == "${expected}" ]]
}

existing_notifier_target_plugin_is_absent() {
    local service="$1"
    local output_file="$2"
    local state

    existing_notifier_compose_base exec -T "${service}" \
        mmctl plugin list --local --suppress-warnings --json > "${output_file}" \
        || return 1
    state="$(notifier_plugin_list_target_state \
        "${output_file}" com.threadhub.channel-email-notifier)" || return 1
    [[ "${state}" == $'missing\t-' ]]
}

existing_notifier_preflight_dispatch() (
    local temporary_dir
    local model_file
    local service

    temporary_dir="$(mktemp -d)"
    trap 'rm -rf -- "${temporary_dir}"' EXIT
    chmod 0700 "${temporary_dir}"
    umask 077
    model_file="${temporary_dir}/compose.json"

    if ! (existing_notifier_validate_config); then
        existing_notifier_action_required "Existing notifier configuration is invalid or unsafe"
        return $?
    fi
    require_ubuntu_amd64
    require_command jq
    if ! existing_notifier_assert_input_paths; then
        existing_notifier_action_required "Existing Compose inputs or Mattermost bind roots are unsafe"
        return $?
    fi
    init_docker
    existing_notifier_init_compose
    if ! existing_notifier_compose_base config --quiet; then
        existing_notifier_action_required "Existing Compose configuration is invalid"
        return $?
    fi
    if ! existing_notifier_compose_base config --format json > "${model_file}"; then
        existing_notifier_action_required "Existing Compose model could not be inspected"
        return $?
    fi
    chmod 0600 "${model_file}"
    if ! existing_notifier_assert_model "${model_file}"; then
        existing_notifier_action_required "Existing Compose model is unsupported or conflicts with notifier resources"
        return $?
    fi

    service="$(existing_notifier_value THN_MATTERMOST_SERVICE)"
    if ! existing_notifier_single_container_id "${service}" "${temporary_dir}/container-id"; then
        existing_notifier_action_required "Exactly one running Mattermost container is required"
        return $?
    fi
    if ! existing_notifier_live_version_is_supported "${service}" "${temporary_dir}/version"; then
        existing_notifier_action_required "Mattermost Team Edition 11.7.7 is required"
        return $?
    fi
    if ! existing_notifier_live_site_url_matches "${service}" "${temporary_dir}/site-url"; then
        existing_notifier_action_required "Mattermost Site URL must match THN_DOMAIN over HTTPS"
        return $?
    fi
    if ! existing_notifier_target_plugin_is_absent "${service}" "${temporary_dir}/plugins.json"; then
        existing_notifier_action_required "Existing ThreadHub notifier plugin state requires manual review"
        return $?
    fi

    printf '[OK] Existing Compose inputs are read-only and structurally supported\n'
    printf '[OK] Mattermost Team Edition 11.7.7 single-node Compose model\n'
    printf '[OK] Mattermost Site URL and notifier collision checks passed\n'
)

existing_notifier_preflight_entry() {
    [[ "$#" -eq 0 ]] || die "Usage: $0"
    existing_notifier_preflight_dispatch
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    existing_notifier_preflight_entry "$@"
fi
