#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=existing-notifier-common.sh
source "${SCRIPT_DIR}/existing-notifier-common.sh"
# shellcheck source=notifier-lib.sh
source "${SCRIPT_DIR}/notifier-lib.sh"
# shellcheck source=notifier-plugin-files.sh
source "${SCRIPT_DIR}/notifier-plugin-files.sh"

existing_notifier_action_required() {
    printf '[ACTION REQUIRED] %s\n' "$1" >&2
    return 20
}

existing_notifier_mode_is_not_writable_by_group_or_other() {
    local path="$1"
    local mode

    mode="$(existing_notifier_privileged_mode "${path}")" || return 1
    [[ "${mode}" =~ ^[0-7]{3,4}$ ]] || return 1
    (( (8#${mode} & 0022) == 0 ))
}

existing_notifier_privileged_mode() {
    local path="$1"

    if "${SUDO_COMMAND[@]}" stat -c '%a' "${path}" >/dev/null 2>&1; then
        "${SUDO_COMMAND[@]}" stat -c '%a' "${path}"
    else
        "${SUDO_COMMAND[@]}" stat -f '%Lp' "${path}"
    fi
}

existing_notifier_assert_input_paths() {
    local project_dir
    local compose_file
    local compose_env_file
    local plugins_root
    local data_root
    local smtp_ca_file
    local path

    project_dir="$(existing_notifier_value THN_COMPOSE_PROJECT_DIR)"
    compose_file="$(existing_notifier_value THN_COMPOSE_FILE)"
    compose_env_file="$(existing_notifier_value THN_COMPOSE_ENV_FILE)"
    plugins_root="$(existing_notifier_value THN_MATTERMOST_PLUGINS_ROOT)"
    data_root="$(existing_notifier_value THN_MATTERMOST_DATA_ROOT)"
    smtp_ca_file="$(existing_notifier_value THN_SMTP_CA_FILE)"

    "${SUDO_COMMAND[@]}" test -d "${project_dir}" \
        && "${SUDO_COMMAND[@]}" test ! -L "${project_dir}" || return 1
    for path in "${compose_file}" "${compose_env_file}"; do
        "${SUDO_COMMAND[@]}" test -f "${path}" \
            && "${SUDO_COMMAND[@]}" test ! -L "${path}" || return 1
        existing_notifier_mode_is_not_writable_by_group_or_other "${path}" || return 1
    done
    [[ "$(existing_notifier_privileged_mode "${compose_env_file}")" == 600 ]] || return 1
    for path in "${plugins_root}" "${data_root}"; do
        "${SUDO_COMMAND[@]}" test -d "${path}" \
            && "${SUDO_COMMAND[@]}" test ! -L "${path}" || return 1
        existing_notifier_mode_is_not_writable_by_group_or_other "${path}" || return 1
    done
    "${SUDO_COMMAND[@]}" test -f "${smtp_ca_file}" \
        && "${SUDO_COMMAND[@]}" test ! -L "${smtp_ca_file}" || return 1
    existing_notifier_mode_is_not_writable_by_group_or_other "${smtp_ca_file}" || return 1

}

existing_notifier_target_objects_presence() {
    notifier_plugin_pair_presence \
        "$(existing_notifier_value THN_MATTERMOST_PLUGINS_ROOT)/com.threadhub.channel-email-notifier" \
        "$(existing_notifier_value THN_MATTERMOST_DATA_ROOT)/plugins/com.threadhub.channel-email-notifier.tar.gz"
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
    local enable_file="${output_file}.plugin-enable"
    local states_file="${output_file}.plugin-states"
    local state

    if existing_notifier_compose_base exec -T "${service}" \
        mmctl plugin list --local --suppress-warnings --json > "${output_file}"; then
        state="$(notifier_plugin_list_target_state \
            "${output_file}" com.threadhub.channel-email-notifier)" || return 1
        [[ "${state}" == $'missing\t-' \
            && "$(existing_notifier_target_objects_presence)" == absent ]]
        return
    fi

    [[ "$(existing_notifier_target_objects_presence)" == absent ]] || return 1
    existing_notifier_compose_base exec -T "${service}" \
        mmctl config get PluginSettings.Enable --local --suppress-warnings > "${enable_file}" \
        || return 1
    [[ "$(tr -d '\r\n' < "${enable_file}")" == false ]] || return 1
    existing_notifier_compose_base exec -T "${service}" \
        mmctl config get PluginSettings.PluginStates --local --suppress-warnings > "${states_file}" \
        || return 1
    jq -e --arg plugin_id com.threadhub.channel-email-notifier '
        type == "object" and (has($plugin_id) | not)
    ' "${states_file}" >/dev/null 2>&1
}

existing_notifier_installed_target_plugin_is_reviewed() {
    local service="$1"
    local scratch_root="$2"
    local plugin_id=com.threadhub.channel-email-notifier
    local target_root
    local bundle_target
    local release_file
    local release_copy
    local plugin_list_file
    local capture_dir
    local metadata
    local installed_version
    local installed_sha
    local metadata_extra
    local release_version
    local release_plugin_id
    local release_sha
    local release_source_commit
    local bundle_relative
    local bundle_path

    target_root="$(existing_notifier_value THN_MATTERMOST_PLUGINS_ROOT)/${plugin_id}"
    bundle_target="$(existing_notifier_value THN_MATTERMOST_DATA_ROOT)/plugins/${plugin_id}.tar.gz"
    release_file="$(existing_notifier_value THN_DATA_ROOT)/release/release.env"
    release_copy="${scratch_root}/release.env"
    plugin_list_file="${scratch_root}/installed-plugins.json"
    capture_dir="${scratch_root}/installed-pair"

    [[ "$(existing_notifier_target_objects_presence)" == present ]] || return 1
    "${SUDO_COMMAND[@]}" test -f "${release_file}" || return 1
    "${SUDO_COMMAND[@]}" test ! -L "${release_file}" || return 1
    "${SUDO_COMMAND[@]}" cat "${release_file}" > "${release_copy}" || return 1
    chmod 0600 "${release_copy}"
    [[ "$(wc -l < "${release_copy}" | tr -d '[:space:]')" == 7 ]] || return 1
    while IFS='=' read -r key value; do
        case "${key}" in
            NOTIFIER_VERSION|NOTIFIER_PLUGIN_ID|NOTIFIER_PLUGIN_BUNDLE|NOTIFIER_PLUGIN_BUNDLE_SHA256|NOTIFIER_MAILER_IMAGE|NOTIFIER_MAILER_IMAGE_ID|NOTIFIER_SOURCE_COMMIT) ;;
            *) return 1 ;;
        esac
        [[ -n "${value}" ]] || return 1
    done < "${release_copy}"
    release_value() {
        awk -F= -v key="$1" '
            $1 == key { count++; value = substr($0, index($0, "=") + 1) }
            END { if (count != 1 || value == "") exit 1; print value }
        ' "${release_copy}"
    }
    release_version="$(release_value NOTIFIER_VERSION)" || return 1
    release_plugin_id="$(release_value NOTIFIER_PLUGIN_ID)" || return 1
    release_sha="$(release_value NOTIFIER_PLUGIN_BUNDLE_SHA256)" || return 1
    release_source_commit="$(release_value NOTIFIER_SOURCE_COMMIT)" || return 1
    bundle_relative="$(release_value NOTIFIER_PLUGIN_BUNDLE)" || return 1
    [[ "${release_version}" == "$(env_value NOTIFIER_VERSION "${VERSIONS_FILE}")" \
        && "${release_plugin_id}" == "${plugin_id}" \
        && "${release_sha}" =~ ^[a-f0-9]{64}$ \
        && "${release_source_commit}" == "$(git -C "${REPOSITORY_ROOT}" rev-parse --verify 'HEAD^{commit}')" \
        && "${bundle_relative}" == "notifier/dist/${plugin_id}-${release_version}.tar.gz" ]] \
        || return 1
    bundle_path="${REPOSITORY_ROOT}/${bundle_relative}"
    [[ -f "${bundle_path}" && ! -L "${bundle_path}" \
        && "$(sha256_file "${bundle_path}")" == "${release_sha}" ]] || return 1

    metadata="$(notifier_plugin_capture_pair \
        "${target_root}" "${bundle_target}" "${plugin_id}" \
        "${capture_dir}" "${scratch_root}")" || return 1
    metadata_extra=""
    IFS=$'\t' read -r installed_version installed_sha metadata_extra <<< "${metadata}"
    [[ "${installed_version}" == "${release_version}" \
        && "${installed_sha}" == "${release_sha}" \
        && -z "${metadata_extra}" ]] || return 1
    existing_notifier_compose_base exec -T "${service}" \
        mmctl plugin list --local --suppress-warnings --json > "${plugin_list_file}" \
        || return 1
    notifier_plugin_list_is_exact_active \
        "${plugin_list_file}" "${plugin_id}" "${release_version}"
}

existing_notifier_preflight_dispatch() (
    local temporary_dir
    local model_file
    local service
    local target_mode="${1:-initial}"

    [[ "${target_mode}" == initial || "${target_mode}" == installed ]] || return 2

    temporary_dir="$(mktemp -d)"
    trap 'notifier_plugin_cleanup_scratch_root "${temporary_dir}"' EXIT
    chmod 0700 "${temporary_dir}"
    umask 077
    model_file="${temporary_dir}/compose.json"

    if ! (existing_notifier_validate_config); then
        existing_notifier_action_required "Existing notifier configuration is invalid or unsafe"
        return $?
    fi
    require_ubuntu_amd64
    require_command jq
    init_sudo
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
    if [[ "${target_mode}" == initial ]]; then
        if ! existing_notifier_target_plugin_is_absent "${service}" "${temporary_dir}/plugins.json"; then
            existing_notifier_action_required "Existing ThreadHub notifier plugin state requires manual review"
            return $?
        fi
    else
        require_command git
        if ! existing_notifier_installed_target_plugin_is_reviewed \
            "${service}" "${temporary_dir}"; then
            existing_notifier_action_required "Installed ThreadHub notifier pair is not the reviewed release"
            return $?
        fi
        printf '[OK] Reviewed installed notifier pair is safe to resume\n'
    fi

    printf '[OK] Existing Compose inputs are read-only and structurally supported\n'
    printf '[OK] Mattermost Team Edition 11.7.7 single-node Compose model\n'
    printf '[OK] Mattermost Site URL and notifier collision checks passed\n'
)

existing_notifier_preflight_entry() {
    local mode=initial
    if [[ "${1:-}" == --resume ]]; then
        mode=installed
        shift
    fi
    [[ "$#" -eq 0 ]] || die "Usage: $0 [--resume]"
    existing_notifier_preflight_dispatch "${mode}"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    existing_notifier_preflight_entry "$@"
fi
