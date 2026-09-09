#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=existing-notifier-v010-v020-common.sh
source "${SCRIPT_DIR}/existing-notifier-v010-v020-common.sh"
# shellcheck source=notifier-lib.sh
source "${SCRIPT_DIR}/notifier-lib.sh"
# shellcheck source=notifier-plugin-files.sh
source "${SCRIPT_DIR}/notifier-plugin-files.sh"

existing_notifier_v010_v020_privileged_identity() {
    local path="$1"

    if "${SUDO_COMMAND[@]}" stat -c '%u:%g:%a' "${path}" >/dev/null 2>&1; then
        "${SUDO_COMMAND[@]}" stat -c '%u:%g:%a' "${path}"
    else
        "${SUDO_COMMAND[@]}" stat -f '%u:%g:%Lp' "${path}"
    fi
}

existing_notifier_v010_v020_release_value() {
    local release_file="$1"
    local key="$2"

    awk -F= -v key="${key}" '
      $1 == key { count++; value=substr($0,index($0,"=")+1) }
      END { if (count != 1 || value == "") exit 1; print value }
    ' "${release_file}"
}

existing_notifier_v010_v020_read_source_release() {
    local release_file="$1"
    local scratch_root="$2"
    local release_copy
    local release_version
    local release_plugin_id
    local release_bundle
    local release_bundle_sha
    local release_mailer_image
    local release_mailer_image_id
    local release_source_commit

    [[ "$#" -eq 2 && -d "${scratch_root}" && ! -L "${scratch_root}" ]] || return 2
    "${SUDO_COMMAND[@]}" test -f "${release_file}" || return 1
    "${SUDO_COMMAND[@]}" test ! -L "${release_file}" || return 1
    [[ "$(existing_notifier_v010_v020_privileged_identity "${release_file}")" == 0:0:640 ]] || return 1
    release_copy="$(mktemp "${scratch_root}/.source-release.XXXXXX")" || return 1
    chmod 0600 "${release_copy}"
    "${SUDO_COMMAND[@]}" cat "${release_file}" > "${release_copy}" || return 1
    [[ "$(wc -l < "${release_copy}" | tr -d '[:space:]')" == 7 ]] || return 1
    awk '
      /\r/ { exit 1 }
      {
        separator=index($0,"=")
        if (separator < 2) exit 1
        key=substr($0,1,separator-1)
        value=substr($0,separator+1)
        if (value == "" || ++seen[key] != 1) exit 1
        expected[key]=1
      }
      END {
        if (length(expected) != 7) exit 1
        if (!("NOTIFIER_VERSION" in expected) || !("NOTIFIER_PLUGIN_ID" in expected) ||
            !("NOTIFIER_PLUGIN_BUNDLE" in expected) || !("NOTIFIER_PLUGIN_BUNDLE_SHA256" in expected) ||
            !("NOTIFIER_MAILER_IMAGE" in expected) || !("NOTIFIER_MAILER_IMAGE_ID" in expected) ||
            !("NOTIFIER_SOURCE_COMMIT" in expected)) exit 1
      }
    ' "${release_copy}" || return 1
    release_version="$(existing_notifier_v010_v020_release_value "${release_copy}" NOTIFIER_VERSION)" || return 1
    release_plugin_id="$(existing_notifier_v010_v020_release_value "${release_copy}" NOTIFIER_PLUGIN_ID)" || return 1
    release_bundle="$(existing_notifier_v010_v020_release_value "${release_copy}" NOTIFIER_PLUGIN_BUNDLE)" || return 1
    release_bundle_sha="$(existing_notifier_v010_v020_release_value "${release_copy}" NOTIFIER_PLUGIN_BUNDLE_SHA256)" || return 1
    release_mailer_image="$(existing_notifier_v010_v020_release_value "${release_copy}" NOTIFIER_MAILER_IMAGE)" || return 1
    release_mailer_image_id="$(existing_notifier_v010_v020_release_value "${release_copy}" NOTIFIER_MAILER_IMAGE_ID)" || return 1
    release_source_commit="$(existing_notifier_v010_v020_release_value "${release_copy}" NOTIFIER_SOURCE_COMMIT)" || return 1
    [[ "${release_version}" == "${EXISTING_NOTIFIER_V010_VERSION}" \
        && "${release_plugin_id}" == com.threadhub.channel-email-notifier \
        && "${release_bundle}" == "notifier/dist/com.threadhub.channel-email-notifier-${EXISTING_NOTIFIER_V010_VERSION}.tar.gz" \
        && "${release_bundle_sha}" =~ ^[a-f0-9]{64}$ \
        && "${release_mailer_image}" == "threadhub/notifier-mailer:${EXISTING_NOTIFIER_V010_VERSION}" \
        && "${release_mailer_image_id}" =~ ^sha256:[a-f0-9]{64}$ \
        && "${release_source_commit}" == "${EXISTING_NOTIFIER_V010_SOURCE_COMMIT}" ]] || return 1

    EXISTING_NOTIFIER_V010_RELEASE_BUNDLE_SHA="${release_bundle_sha}"
    EXISTING_NOTIFIER_V010_RELEASE_MAILER_IMAGE_ID="${release_mailer_image_id}"
}

existing_notifier_v010_v020_recovery_gate_is_valid() {
    local gate_file="$1"
    local now_epoch="${2:-$(date -u +%s)}"
    local temporary_dir
    local gate_copy
    local result=0
    local gate_parent

    [[ "$#" -ge 1 && "$#" -le 2 && "${now_epoch}" =~ ^[0-9]+$ ]] || return 2
    gate_parent="$(dirname "${gate_file}")"
    "${SUDO_COMMAND[@]}" test -d "${gate_parent}" || return 1
    "${SUDO_COMMAND[@]}" test ! -L "${gate_parent}" || return 1
    [[ "$(existing_notifier_v010_v020_privileged_identity "${gate_parent}")" == 0:0:700 ]] || return 1
    "${SUDO_COMMAND[@]}" test -f "${gate_file}" || return 1
    "${SUDO_COMMAND[@]}" test ! -L "${gate_file}" || return 1
    [[ "$(existing_notifier_v010_v020_privileged_identity "${gate_file}")" == 0:0:600 ]] || return 1
    temporary_dir="$(mktemp -d)" || return 1
    chmod 0700 "${temporary_dir}"
    gate_copy="${temporary_dir}/gate.json"
    if ! "${SUDO_COMMAND[@]}" cat "${gate_file}" > "${gate_copy}"; then
        rm -rf -- "${temporary_dir}"
        return 1
    fi
    chmod 0600 "${gate_copy}"
    jq -e --arg profile "${EXISTING_NOTIFIER_V010_V020_ID}" \
        --arg commit "${EXISTING_NOTIFIER_V010_SOURCE_COMMIT}" \
        --argjson now "${now_epoch}" '
      type == "object" and
      (keys == [
        "aggregate_match_verified", "disposable_restore_verified", "profile",
        "remote_backup_verified", "restored_queue_quarantined", "reviewed_at_utc",
        "schema", "source_release_commit"
      ]) and
      .schema == 1 and .profile == $profile and .source_release_commit == $commit and
      .remote_backup_verified == true and .disposable_restore_verified == true and
      .aggregate_match_verified == true and .restored_queue_quarantined == true and
      (.reviewed_at_utc | type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$") and
        (fromdateiso8601 as $reviewed | ($now - $reviewed) >= 0 and ($now - $reviewed) <= 604800))
    ' "${gate_copy}" >/dev/null 2>&1 || result=$?
    rm -rf -- "${temporary_dir}"
    return "${result}"
}

existing_notifier_v010_v020_mailer_status_is_valid() {
    local status_file="$1"

    [[ "$#" -eq 1 && -f "${status_file}" && ! -L "${status_file}" ]] || return 2
    jq -e '
      type == "object" and
      (keys == [
        "failed", "last_error_class", "last_smtp_code", "last_success_at",
        "oldest_pending_seconds", "pending", "sending", "sent"
      ]) and
      ([.pending,.sending,.sent,.failed,.oldest_pending_seconds,.last_success_at] |
        all(type == "number" and floor == . and . >= 0)) and
      (.last_error_class | type == "string" and
        (. == "" or . == "temporary" or . == "permanent" or . == "timeout" or . == "protocol")) and
      (.last_smtp_code | type == "number" and floor == . and (. == 0 or (. >= 100 and . <= 599)))
    ' "${status_file}" >/dev/null 2>&1
}

existing_notifier_v010_v020_postgres_service() {
    local model_file="$1"

    jq -er --arg version "${EXISTING_NOTIFIER_V010_POSTGRES_VERSION}" '
      [
        .services | to_entries[] |
        select(.value.image | type == "string" and
          test("^postgres:" + ($version | gsub("\\."; "\\.")) + "@sha256:[a-f0-9]{64}$"))
      ] as $postgres |
      if ($postgres | length) == 1 then $postgres[0].key else error("ambiguous postgres service") end
    ' "${model_file}" 2>/dev/null
}

existing_notifier_v010_v020_assert_source_model() {
    local model_file="$1"
    local service
    local plugins_root
    local mattermost_data_root
    local notifier_root
    local domain
    local hmac
    local postgres_service

    [[ "$#" -eq 1 && -f "${model_file}" && ! -L "${model_file}" ]] || return 2
    service="$(existing_notifier_v010_v020_value THN_MATTERMOST_SERVICE)" || return 1
    plugins_root="$(existing_notifier_v010_v020_value THN_MATTERMOST_PLUGINS_ROOT)" || return 1
    mattermost_data_root="$(existing_notifier_v010_v020_value THN_MATTERMOST_DATA_ROOT)" || return 1
    notifier_root="$(existing_notifier_v010_v020_value THN_DATA_ROOT)" || return 1
    domain="$(existing_notifier_v010_v020_value THN_DOMAIN)" || return 1
    hmac="$(existing_notifier_v010_v020_value THN_HMAC_SECRET)" || return 1
    postgres_service="$(existing_notifier_v010_v020_postgres_service "${model_file}")" || return 1

    jq -e \
        --arg service "${service}" \
        --arg postgres "${postgres_service}" \
        --arg plugins_root "${plugins_root}" \
        --arg mattermost_data_root "${mattermost_data_root}" \
        --arg notifier_root "${notifier_root}" \
        --arg domain "${domain}" \
        --arg hmac "${hmac}" \
        --arg mm_version "${EXISTING_NOTIFIER_V010_MATTERMOST_VERSION}" \
        --arg pg_version "${EXISTING_NOTIFIER_V010_POSTGRES_VERSION}" \
        --arg notifier_version "${EXISTING_NOTIFIER_V010_VERSION}" '
      type == "object" and (.services | type == "object") and
      ([.services | to_entries[] | select(.value.image | type == "string" and
        test("^mattermost/mattermost-team-edition:" + ($mm_version | gsub("\\."; "\\.")) + "@sha256:[a-f0-9]{64}$"))] | length == 1) and
      ([.services | to_entries[] | select(.value.image | type == "string" and
        test("^postgres:" + ($pg_version | gsub("\\."; "\\.")) + "@sha256:[a-f0-9]{64}$"))] | length == 1) and
      ([.services | to_entries[] | select(.value.image == ("threadhub/notifier-mailer:" + $notifier_version))] | length == 1) and
      (.services[$service] as $mm |
        ($mm | type == "object") and
        ($mm.image | type == "string" and
          test("^mattermost/mattermost-team-edition:" + ($mm_version | gsub("\\."; "\\.")) + "@sha256:[a-f0-9]{64}$")) and
        (($mm.deploy.replicas // 1) == 1) and
        ($mm.environment.MM_PLUGINSETTINGS_ENABLE == "true") and
        ($mm.environment.THREADHUB_DOMAIN == $domain) and
        ($mm.environment.NOTIFIER_MAILER_URL == "http://threadhub-mailer:8080") and
        ($mm.environment.NOTIFIER_HMAC_SECRET == $hmac) and
        ($mm.environment.NOTIFIER_CONTROL_FILE == "/run/threadhub-notifier/state.json") and
        ($mm.environment.NOTIFIER_POLL_EVERY == "1s") and
        (($mm.environment // {}) | has("NOTIFIER_CONTENT_MODE") | not) and
        ([$mm.volumes[]? | select(.type == "bind" and .source == $plugins_root and .target == "/mattermost/plugins" and ((.read_only // false) == false))] | length == 1) and
        ([$mm.volumes[]? | select(.type == "bind" and .source == $mattermost_data_root and .target == "/mattermost/data" and ((.read_only // false) == false))] | length == 1) and
        ([$mm.volumes[]? | select(.type == "bind" and .source == ($notifier_root + "/control") and .target == "/run/threadhub-notifier" and .read_only == true)] | length == 1)
      ) and
      (.services[$postgres] as $pg |
        ($pg | type == "object") and (($pg.deploy.replicas // 1) == 1) and
        ([$pg.volumes[]? | select(.type == "bind" and .target == "/var/lib/postgresql" and ((.read_only // false) == false))] | length == 1) and
        ([$pg.volumes[]? | select(.target == "/var/lib/postgresql")] | length == 1)
      ) and
      (.services["threadhub-mailer"] as $mailer |
        ($mailer | type == "object") and
        ($mailer.image == ("threadhub/notifier-mailer:" + $notifier_version)) and
        (($mailer.deploy.replicas // 1) == 1) and
        ($mailer.environment.THREADHUB_DOMAIN == $domain) and
        ($mailer.environment.NOTIFIER_HMAC_SECRET == $hmac) and
        ($mailer.environment.NOTIFIER_QUEUE_PATH == "/var/lib/threadhub-notifier/queue.db") and
        ($mailer.environment.NOTIFIER_CONTROL_FILE == "/run/threadhub-notifier/state.json") and
        (($mailer.environment // {}) | has("NOTIFIER_CONTENT_MODE") | not) and
        ([$mailer.volumes[]? | select(.type == "bind" and .source == ($notifier_root + "/mailer") and .target == "/var/lib/threadhub-notifier" and ((.read_only // false) == false))] | length == 1) and
        ([$mailer.volumes[]? | select(.type == "bind" and .source == ($notifier_root + "/control") and .target == "/run/threadhub-notifier" and .read_only == true)] | length == 1) and
        (($mailer.ports // []) | length == 0)
      )
    ' "${model_file}" >/dev/null 2>&1
}

existing_notifier_v010_v020_assert_runtime_paths() {
    local notifier_root
    local override_file
    local release_dir
    local release_file

    existing_notifier_v010_v020_assert_base_input_paths || return 1
    notifier_root="$(existing_notifier_v010_v020_value THN_DATA_ROOT)" || return 1
    override_file="${notifier_root}/compose.override.yml"
    release_dir="${notifier_root}/release"
    release_file="${release_dir}/release.env"
    existing_notifier_validate_control_path "${notifier_root}/control/state.json" || return 1
    "${SUDO_COMMAND[@]}" test -f "${override_file}" \
        && "${SUDO_COMMAND[@]}" test ! -L "${override_file}" \
        && [[ "$(existing_notifier_v010_v020_privileged_identity "${override_file}")" == 0:0:600 ]] \
        && "${SUDO_COMMAND[@]}" test -d "${release_dir}" \
        && "${SUDO_COMMAND[@]}" test ! -L "${release_dir}" \
        && [[ "$(existing_notifier_v010_v020_privileged_identity "${release_dir}")" == 0:0:750 ]] \
        && "${SUDO_COMMAND[@]}" test -f "${release_file}" \
        && "${SUDO_COMMAND[@]}" test ! -L "${release_file}"
}

existing_notifier_v010_v020_mode_is_not_writable_by_group_or_other() {
    local identity
    local mode

    identity="$(existing_notifier_v010_v020_privileged_identity "$1")" || return 1
    mode="${identity##*:}"
    [[ "${mode}" =~ ^[0-7]{3,4}$ ]] || return 1
    (( (8#${mode} & 0022) == 0 ))
}

existing_notifier_v010_v020_assert_base_input_paths() {
    local project_dir
    local compose_file
    local compose_env
    local plugins_root
    local data_root
    local smtp_ca
    local path

    project_dir="$(existing_notifier_v010_v020_value THN_COMPOSE_PROJECT_DIR)"
    compose_file="$(existing_notifier_v010_v020_value THN_COMPOSE_FILE)"
    compose_env="$(existing_notifier_v010_v020_value THN_COMPOSE_ENV_FILE)"
    plugins_root="$(existing_notifier_v010_v020_value THN_MATTERMOST_PLUGINS_ROOT)"
    data_root="$(existing_notifier_v010_v020_value THN_MATTERMOST_DATA_ROOT)"
    smtp_ca="$(existing_notifier_v010_v020_value THN_SMTP_CA_FILE)"
    "${SUDO_COMMAND[@]}" test -d "${project_dir}" \
        && "${SUDO_COMMAND[@]}" test ! -L "${project_dir}" || return 1
    for path in "${compose_file}" "${compose_env}"; do
        "${SUDO_COMMAND[@]}" test -f "${path}" \
            && "${SUDO_COMMAND[@]}" test ! -L "${path}" \
            && existing_notifier_v010_v020_mode_is_not_writable_by_group_or_other "${path}" || return 1
    done
    [[ "${compose_env##*/}" == .env \
        && "$(existing_notifier_v010_v020_privileged_identity "${compose_env}")" == *:600 ]] || return 1
    for path in "${plugins_root}" "${data_root}"; do
        "${SUDO_COMMAND[@]}" test -d "${path}" \
            && "${SUDO_COMMAND[@]}" test ! -L "${path}" \
            && existing_notifier_v010_v020_mode_is_not_writable_by_group_or_other "${path}" || return 1
    done
    "${SUDO_COMMAND[@]}" test -f "${smtp_ca}" \
        && "${SUDO_COMMAND[@]}" test ! -L "${smtp_ca}" \
        && existing_notifier_v010_v020_mode_is_not_writable_by_group_or_other "${smtp_ca}"
}

existing_notifier_v010_v020_init_compose() {
    existing_notifier_init_compose
}

existing_notifier_v010_v020_compose_base() {
    existing_notifier_compose_base "$@"
}

existing_notifier_v010_v020_compose_combined() {
    existing_notifier_compose_combined "$@"
}

existing_notifier_v010_v020_single_container_id() {
    local service="$1"
    local output_file="$2"

    existing_notifier_v010_v020_compose_combined ps -q "${service}" > "${output_file}" || return 1
    [[ "$(wc -l < "${output_file}" | tr -d '[:space:]')" == 1 ]] || return 1
    grep -Eq '^[a-f0-9]{64}$' "${output_file}"
}

existing_notifier_v010_v020_container_is_healthy() {
    local container_id="$1"
    local state

    state="$("${DOCKER_COMMAND[@]}" inspect --format '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{end}}' "${container_id}")" || return 1
    [[ "${state}" == 'running healthy' ]]
}

existing_notifier_v010_v020_live_mattermost_is_supported() {
    local service="$1"
    local output_file="$2"

    existing_notifier_v010_v020_compose_combined exec -T "${service}" mattermost version > "${output_file}" || return 1
    [[ "$(awk -F': ' '$1 == "Version" { count++; value=$2 } END { if (count != 1) exit 1; print value }' "${output_file}")" == "${EXISTING_NOTIFIER_V010_MATTERMOST_VERSION}" ]] || return 1
    [[ "$(awk -F': ' '$1 == "Build Enterprise Ready" { count++; value=$2 } END { if (count != 1) exit 1; print value }' "${output_file}")" == false ]]
}

existing_notifier_v010_v020_live_postgres_is_supported() {
    local service="$1"
    local output_file="$2"

    existing_notifier_v010_v020_compose_combined exec -T "${service}" psql --version > "${output_file}" || return 1
    [[ "$(tr -d '\r\n' < "${output_file}")" == "psql (PostgreSQL) ${EXISTING_NOTIFIER_V010_POSTGRES_VERSION}" ]]
}

existing_notifier_v010_v020_live_site_url_matches() {
    local service="$1"
    local output_file="$2"
    local actual

    existing_notifier_v010_v020_compose_combined exec -T "${service}" \
        mmctl config get ServiceSettings.SiteURL --local --suppress-warnings > "${output_file}" || return 1
    [[ "$(wc -l < "${output_file}" | tr -d '[:space:]')" == 1 ]] || return 1
    actual="$(tr -d '\r' < "${output_file}")"
    actual="${actual%/}"
    if [[ "${actual}" == \"*\" ]]; then actual="${actual:1:${#actual}-2}"; fi
    [[ "${actual}" == "https://$(existing_notifier_v010_v020_value THN_DOMAIN)" ]]
}

existing_notifier_v010_v020_review_source_pair() {
    local service="$1"
    local scratch_root="$2"
    local expected_sha="$3"
    local plugin_id=com.threadhub.channel-email-notifier
    local runtime_root
    local bundle_path
    local capture_dir
    local metadata
    local version
    local sha
    local extra
    local plugin_list

    runtime_root="$(existing_notifier_v010_v020_value THN_MATTERMOST_PLUGINS_ROOT)/${plugin_id}"
    bundle_path="$(existing_notifier_v010_v020_value THN_MATTERMOST_DATA_ROOT)/plugins/${plugin_id}.tar.gz"
    capture_dir="$(mktemp -d "${scratch_root}/.pair-parent.XXXXXX")"
    rmdir "${capture_dir}"
    metadata="$(notifier_plugin_capture_pair "${runtime_root}" "${bundle_path}" "${plugin_id}" "${capture_dir}" "${scratch_root}")" || return 1
    extra=""
    IFS=$'\t' read -r version sha extra <<< "${metadata}"
    [[ "${version}" == "${EXISTING_NOTIFIER_V010_VERSION}" && "${sha}" == "${expected_sha}" && -z "${extra}" ]] || return 1
    plugin_list="$(mktemp "${scratch_root}/.plugin-list.XXXXXX")"
    existing_notifier_v010_v020_compose_combined exec -T "${service}" \
        mmctl plugin list --local --suppress-warnings --json > "${plugin_list}" || return 1
    notifier_plugin_list_is_exact_active "${plugin_list}" "${plugin_id}" "${EXISTING_NOTIFIER_V010_VERSION}" || return 1
    EXISTING_NOTIFIER_V010_PAIR_SHA="${sha}"
}

existing_notifier_v010_v020_running_image_id() {
    "${DOCKER_COMMAND[@]}" inspect --format '{{.Image}}' "$1"
}

existing_notifier_v010_v020_privileged_hash() {
    local path="$1"
    local scratch_root="$2"
    local copy

    "${SUDO_COMMAND[@]}" test -f "${path}" || return 1
    "${SUDO_COMMAND[@]}" test ! -L "${path}" || return 1
    copy="$(mktemp "${scratch_root}/.fingerprint.XXXXXX")" || return 1
    chmod 0600 "${copy}"
    "${SUDO_COMMAND[@]}" cat "${path}" > "${copy}" || return 1
    sha256_file "${copy}"
}

existing_notifier_v010_v020_input_fingerprint() {
    local scratch_root="$1"
    local notifier_root
    local paths_file
    local hashes_file
    local path

    notifier_root="$(existing_notifier_v010_v020_value THN_DATA_ROOT)" || return 1
    paths_file="$(mktemp "${scratch_root}/.paths.XXXXXX")"
    hashes_file="$(mktemp "${scratch_root}/.hashes.XXXXXX")"
    chmod 0600 "${paths_file}" "${hashes_file}"
    printf '%s\n' \
        "${EXISTING_NOTIFIER_V010_V020_ENV_FILE}" \
        "$(existing_notifier_v010_v020_value THN_COMPOSE_FILE)" \
        "$(existing_notifier_v010_v020_value THN_COMPOSE_ENV_FILE)" \
        "${notifier_root}/compose.override.yml" \
        "${notifier_root}/release/release.env" \
        "${notifier_root}/mailer/queue.db" \
        "${notifier_root}/control/state.json" \
        "$(existing_notifier_v010_v020_value THN_MATTERMOST_DATA_ROOT)/plugins/com.threadhub.channel-email-notifier.tar.gz" \
        > "${paths_file}"
    while IFS= read -r path; do
        existing_notifier_v010_v020_privileged_hash "${path}" "${scratch_root}" >> "${hashes_file}" || return 1
    done < "${paths_file}"
    sha256_file "${hashes_file}"
}

existing_notifier_v010_v020_action_required() {
    printf '[ACTION REQUIRED] %s\n' "$1" >&2
    return 20
}

existing_notifier_v010_v020_preflight() (
    local temporary_dir
    local target_config
    local model_file
    local final_model_file
    local status_file
    local release_file
    local gate_file
    local service
    local postgres_service
    local mattermost_id
    local postgres_id
    local mailer_id
    local initial_inputs
    local final_inputs
    local initial_model
    local final_model
    local initial_pair_sha

    temporary_dir="$(mktemp -d)"
    trap 'notifier_plugin_cleanup_scratch_root "${temporary_dir}"' EXIT HUP INT TERM
    chmod 0700 "${temporary_dir}"
    umask 077
    target_config="${temporary_dir}/target.env"
    model_file="${temporary_dir}/compose.json"
    final_model_file="${temporary_dir}/compose-final.json"
    status_file="${temporary_dir}/mailer-status.json"

    if [[ "$(existing_notifier_v010_v020_config_state "${EXISTING_NOTIFIER_V010_V020_ENV_FILE}" 2>/dev/null)" != source ]]; then
        existing_notifier_v010_v020_action_required "Legacy notifier configuration is not the exact v0.1.0 source"
        return $?
    fi
    if ! existing_notifier_v010_v020_prepare_target_config "${EXISTING_NOTIFIER_V010_V020_ENV_FILE}" "${target_config}"; then
        existing_notifier_v010_v020_action_required "Legacy notifier configuration could not be validated safely"
        return $?
    fi
    EXISTING_NOTIFIER_ENV_FILE="${target_config}"
    export EXISTING_NOTIFIER_ENV_FILE

    require_ubuntu_amd64
    require_command jq
    init_sudo
    if ! existing_notifier_v010_v020_assert_runtime_paths; then
        existing_notifier_v010_v020_action_required "Legacy notifier runtime paths are incomplete or unsafe"
        return $?
    fi
    initial_inputs="$(existing_notifier_v010_v020_input_fingerprint "${temporary_dir}")" || {
        existing_notifier_v010_v020_action_required "Legacy notifier inputs could not be fingerprinted"
        return $?
    }

    init_docker
    existing_notifier_v010_v020_init_compose
    if ! existing_notifier_v010_v020_compose_base config --quiet \
        || ! existing_notifier_v010_v020_compose_combined config --quiet \
        || ! existing_notifier_v010_v020_compose_combined config --format json > "${model_file}"; then
        existing_notifier_v010_v020_action_required "Legacy Compose configuration could not be inspected"
        return $?
    fi
    chmod 0600 "${model_file}"
    if ! existing_notifier_v010_v020_assert_source_model "${model_file}"; then
        existing_notifier_v010_v020_action_required "Legacy Compose model is not the exact supported source"
        return $?
    fi
    initial_model="$(sha256_file "${model_file}")"
    service="$(existing_notifier_v010_v020_value THN_MATTERMOST_SERVICE)"
    postgres_service="$(existing_notifier_v010_v020_postgres_service "${model_file}")" || {
        existing_notifier_v010_v020_action_required "PostgreSQL service is ambiguous"
        return $?
    }
    existing_notifier_v010_v020_single_container_id "${service}" "${temporary_dir}/mattermost-id" || {
        existing_notifier_v010_v020_action_required "Exactly one Mattermost container is required"
        return $?
    }
    existing_notifier_v010_v020_single_container_id "${postgres_service}" "${temporary_dir}/postgres-id" || {
        existing_notifier_v010_v020_action_required "Exactly one PostgreSQL container is required"
        return $?
    }
    existing_notifier_v010_v020_single_container_id threadhub-mailer "${temporary_dir}/mailer-id" || {
        existing_notifier_v010_v020_action_required "Exactly one legacy Mailer container is required"
        return $?
    }
    mattermost_id="$(<"${temporary_dir}/mattermost-id")"
    postgres_id="$(<"${temporary_dir}/postgres-id")"
    mailer_id="$(<"${temporary_dir}/mailer-id")"
    if ! existing_notifier_v010_v020_container_is_healthy "${mattermost_id}" \
        || ! existing_notifier_v010_v020_container_is_healthy "${postgres_id}" \
        || ! existing_notifier_v010_v020_container_is_healthy "${mailer_id}"; then
        existing_notifier_v010_v020_action_required "All exact source containers must be running and healthy"
        return $?
    fi
    if ! existing_notifier_v010_v020_live_mattermost_is_supported "${service}" "${temporary_dir}/mattermost-version" \
        || ! existing_notifier_v010_v020_live_postgres_is_supported "${postgres_service}" "${temporary_dir}/postgres-version" \
        || ! existing_notifier_v010_v020_live_site_url_matches "${service}" "${temporary_dir}/site-url"; then
        existing_notifier_v010_v020_action_required "Live Mattermost, PostgreSQL, or Site URL identity is unsupported"
        return $?
    fi

    release_file="$(existing_notifier_v010_v020_value THN_DATA_ROOT)/release/release.env"
    if ! existing_notifier_v010_v020_read_source_release "${release_file}" "${temporary_dir}"; then
        existing_notifier_v010_v020_action_required "Legacy notifier release identity is not exact"
        return $?
    fi
    if ! existing_notifier_v010_v020_review_source_pair "${service}" "${temporary_dir}" "${EXISTING_NOTIFIER_V010_RELEASE_BUNDLE_SHA}"; then
        existing_notifier_v010_v020_action_required "Legacy notifier plugin pair is incomplete, inactive, or unreviewed"
        return $?
    fi
    initial_pair_sha="${EXISTING_NOTIFIER_V010_PAIR_SHA}"
    if [[ "$(existing_notifier_v010_v020_running_image_id "${mailer_id}")" != "${EXISTING_NOTIFIER_V010_RELEASE_MAILER_IMAGE_ID}" ]]; then
        existing_notifier_v010_v020_action_required "Running legacy Mailer image does not match its release"
        return $?
    fi
    if ! existing_notifier_v010_v020_compose_combined exec -T threadhub-mailer \
        /threadhub-mailer status --json > "${status_file}" \
        || ! existing_notifier_v010_v020_mailer_status_is_valid "${status_file}"; then
        existing_notifier_v010_v020_action_required "Legacy Mailer aggregate status is unavailable or unsafe"
        return $?
    fi
    chmod 0600 "${status_file}"
    gate_file="$(existing_notifier_v010_v020_value THN_DATA_ROOT)/migration/recovery-gate-v010-v020.json"
    if ! existing_notifier_v010_v020_recovery_gate_is_valid "${gate_file}"; then
        existing_notifier_v010_v020_action_required "Current remote-backup and disposable-restore review is required"
        return $?
    fi

    if ! existing_notifier_v010_v020_compose_base config --quiet \
        || ! existing_notifier_v010_v020_compose_combined config --quiet \
        || ! existing_notifier_v010_v020_compose_combined config --format json > "${final_model_file}"; then
        existing_notifier_v010_v020_action_required "Compose inputs changed during preflight"
        return $?
    fi
    chmod 0600 "${final_model_file}"
    final_model="$(sha256_file "${final_model_file}")"
    final_inputs="$(existing_notifier_v010_v020_input_fingerprint "${temporary_dir}")" || {
        existing_notifier_v010_v020_action_required "Legacy notifier inputs changed during preflight"
        return $?
    }
    if ! existing_notifier_v010_v020_review_source_pair "${service}" "${temporary_dir}" "${EXISTING_NOTIFIER_V010_RELEASE_BUNDLE_SHA}" \
        || [[ "${EXISTING_NOTIFIER_V010_PAIR_SHA}" != "${initial_pair_sha}" \
            || "${final_inputs}" != "${initial_inputs}" \
            || "${final_model}" != "${initial_model}" ]]; then
        existing_notifier_v010_v020_action_required "Legacy notifier identity changed during preflight"
        return $?
    fi

    printf '[OK] Exact notifier v0.1.0 source profile is read-only and supported\n'
    printf '[OK] Remote backup and disposable restore review is current\n'
    printf '[OK] Preflight made no runtime or persistent-data change\n'
)

existing_notifier_v010_v020_preflight_entry() {
    [[ "$#" -eq 0 ]] || die "Usage: $0"
    existing_notifier_v010_v020_preflight
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    existing_notifier_v010_v020_preflight_entry "$@"
fi
