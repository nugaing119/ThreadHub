#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=existing-notifier-v010-v020-preflight.sh
source "${SCRIPT_DIR}/existing-notifier-v010-v020-preflight.sh"
# shellcheck source=existing-notifier-v010-v020-transaction.sh
source "${SCRIPT_DIR}/existing-notifier-v010-v020-transaction.sh"
# shellcheck source=notifier-artifact-build-lib.sh
source "${SCRIPT_DIR}/notifier-artifact-build-lib.sh"
# shellcheck source=existing-notifier-overlay.sh
source "${SCRIPT_DIR}/existing-notifier-overlay.sh"

existing_notifier_v010_v020_upgrade_action_required() {
    printf '[ACTION REQUIRED] %s\n' "$1" >&2
    return 20
}

existing_notifier_v010_v020_upgrade_record_halt() {
    printf '[threadhub] ERROR: notifier upgrade halted at stage: %s\n' "$1" >&2
}

existing_notifier_v010_v020_upgrade_initialize() {
    local temporary_dir
    local model_file

    require_ubuntu_amd64
    require_command git
    require_command jq
    require_command tar
    require_command cmp
    require_command stat
    require_command mv
    require_command ln
    runtime_env_require_atomic_tools
    init_docker
    init_sudo
    existing_notifier_v010_v020_init_compose
    temporary_dir="$(mktemp -d)" || return 1
    chmod 0700 "${temporary_dir}"
    model_file="${temporary_dir}/model.json"
    if ! existing_notifier_v010_v020_compose_combined config --format json > "${model_file}"; then
        rm -rf -- "${temporary_dir}"
        return 1
    fi
    EXISTING_NOTIFIER_V010_V020_POSTGRES_SERVICE="$(
        existing_notifier_v010_v020_postgres_service "${model_file}"
    )" || {
        rm -rf -- "${temporary_dir}"
        return 1
    }
    export EXISTING_NOTIFIER_V010_V020_POSTGRES_SERVICE
    rm -rf -- "${temporary_dir}"
}

v010_v020_upgrade_preflight() {
    existing_notifier_v010_v020_preflight || return $?
    existing_notifier_v010_v020_upgrade_initialize
}

existing_notifier_v010_v020_validate_target_bundle() (
    local release_dir="$1"
    local temporary_dir
    local release_copy
    local bundle_relative
    local bundle_path
    local bundle_sha
    local extracted_root

    temporary_dir="$(mktemp -d)" || return 1
    trap 'rm -rf -- "${temporary_dir}"' EXIT HUP INT TERM
    chmod 0700 "${temporary_dir}"
    release_copy="${temporary_dir}/release.env"
    "${SUDO_COMMAND[@]}" cat "${release_dir}/release.env" > "${release_copy}" || return 1
    chmod 0600 "${release_copy}"
    bundle_relative="$(existing_notifier_v010_v020_release_value "${release_copy}" NOTIFIER_PLUGIN_BUNDLE)" || return 1
    bundle_sha="$(existing_notifier_v010_v020_release_value "${release_copy}" NOTIFIER_PLUGIN_BUNDLE_SHA256)" || return 1
    bundle_path="${REPOSITORY_ROOT}/${bundle_relative}"
    [[ "${bundle_relative}" == "notifier/dist/com.threadhub.channel-email-notifier-${EXISTING_NOTIFIER_V020_VERSION}.tar.gz" \
        && "${bundle_sha}" =~ ^[a-f0-9]{64}$ \
        && -f "${bundle_path}" && ! -L "${bundle_path}" \
        && "$(sha256_file "${bundle_path}")" == "${bundle_sha}" ]] || return 1
    tar -tzf "${bundle_path}" > "${temporary_dir}/entries" || return 1
    notifier_plugin_bundle_entries_are_valid \
        "${temporary_dir}/entries" com.threadhub.channel-email-notifier current || return 1
    tar -tvzf "${bundle_path}" > "${temporary_dir}/verbose-entries" || return 1
    awk '{ type=substr($1,1,1); if (type != "-" && type != "d") exit 1 }' \
        "${temporary_dir}/verbose-entries" || return 1
    mkdir -m 0700 "${temporary_dir}/extracted"
    tar --extract --gzip --file "${bundle_path}" --directory "${temporary_dir}/extracted" \
        --no-same-owner --no-same-permissions || return 1
    extracted_root="${temporary_dir}/extracted/com.threadhub.channel-email-notifier"
    [[ -d "${extracted_root}" && ! -L "${extracted_root}" ]] || return 1
    jq -e --arg version "${EXISTING_NOTIFIER_V020_VERSION}" '
      type == "object" and
      (keys == ["description","homepage_url","id","min_server_version","name","server","support_url","version"]) and
      .id == "com.threadhub.channel-email-notifier" and .version == $version and
      .min_server_version == "11.7.7" and
      (.server | keys == ["executables"]) and
      (.server.executables | keys == ["linux-amd64"]) and
      .server.executables["linux-amd64"] == "server/dist/plugin-linux-amd64"
    ' "${extracted_root}/plugin.json" >/dev/null
)

existing_notifier_v010_v020_preserved_target_bundle_is_exact() (
    local release_dir="$1"
    local preserved_bundle="$2"
    local temporary_dir
    local release_copy
    local bundle_relative
    local bundle_sha

    [[ "$#" -eq 2 ]] || return 2
    temporary_dir="$(mktemp -d)" || return 1
    trap 'rm -rf -- "${temporary_dir}"' EXIT HUP INT TERM
    chmod 0700 "${temporary_dir}"
    release_copy="${temporary_dir}/release.env"
    "${SUDO_COMMAND[@]}" cat "${release_dir}/release.env" > "${release_copy}" || return 1
    chmod 0600 "${release_copy}"
    bundle_relative="$(existing_notifier_v010_v020_release_value \
        "${release_copy}" NOTIFIER_PLUGIN_BUNDLE)" || return 1
    bundle_sha="$(existing_notifier_v010_v020_release_value \
        "${release_copy}" NOTIFIER_PLUGIN_BUNDLE_SHA256)" || return 1
    [[ "${bundle_relative}" == "notifier/dist/com.threadhub.channel-email-notifier-${EXISTING_NOTIFIER_V020_VERSION}.tar.gz" \
        && "${bundle_sha}" =~ ^[a-f0-9]{64}$ ]] || return 1
    "${SUDO_COMMAND[@]}" test -f "${preserved_bundle}" \
        && "${SUDO_COMMAND[@]}" test ! -L "${preserved_bundle}" \
        && [[ "$(existing_notifier_v010_v020_capture_identity "${preserved_bundle}")" == 0:0:600 ]] \
        && [[ "$(notifier_plugin_privileged_sha256 "${preserved_bundle}")" == "${bundle_sha}" ]]
)

existing_notifier_v010_v020_preserve_target_bundle() (
    local release_dir="$1"
    local preserved_bundle="$2"
    local temporary_dir
    local release_copy
    local bundle_relative
    local bundle_sha
    local source_bundle

    [[ "$#" -eq 2 ]] || return 2
    temporary_dir="$(mktemp -d)" || return 1
    trap 'rm -rf -- "${temporary_dir}"' EXIT HUP INT TERM
    chmod 0700 "${temporary_dir}"
    release_copy="${temporary_dir}/release.env"
    "${SUDO_COMMAND[@]}" cat "${release_dir}/release.env" > "${release_copy}" || return 1
    chmod 0600 "${release_copy}"
    bundle_relative="$(existing_notifier_v010_v020_release_value \
        "${release_copy}" NOTIFIER_PLUGIN_BUNDLE)" || return 1
    bundle_sha="$(existing_notifier_v010_v020_release_value \
        "${release_copy}" NOTIFIER_PLUGIN_BUNDLE_SHA256)" || return 1
    source_bundle="${REPOSITORY_ROOT}/${bundle_relative}"
    [[ "${bundle_relative}" == "notifier/dist/com.threadhub.channel-email-notifier-${EXISTING_NOTIFIER_V020_VERSION}.tar.gz" \
        && "${bundle_sha}" =~ ^[a-f0-9]{64}$ \
        && -f "${source_bundle}" && ! -L "${source_bundle}" \
        && "$(sha256_file "${source_bundle}")" == "${bundle_sha}" ]] || return 1
    if "${SUDO_COMMAND[@]}" test -e "${preserved_bundle}" \
        || "${SUDO_COMMAND[@]}" test -L "${preserved_bundle}"; then
        return 1
    fi
    "${SUDO_COMMAND[@]}" install -o 0 -g 0 -m 0600 \
        "${source_bundle}" "${preserved_bundle}" || return 1
    existing_notifier_v010_v020_preserved_target_bundle_is_exact \
        "${release_dir}" "${preserved_bundle}"
)

existing_notifier_v010_v020_verify_target_stage() (
    local target_root
    local temporary_dir
    local target_env
    local target_override
    local queue_inspection
    local previous_env
    local project_dir
    local compose_file
    local compose_env
    local model_file
    local result
    local -a privileged_docker=()
    local -a target_compose=()

    target_root="$(existing_notifier_v010_v020_target_root)"
    "${SUDO_COMMAND[@]}" test -d "${target_root}" \
        && "${SUDO_COMMAND[@]}" test ! -L "${target_root}" \
        && [[ "$(existing_notifier_v010_v020_capture_identity "${target_root}")" == 0:0:700 ]] \
        || return 1
    notifier_artifact_release_is_current "${target_root}/release" || return 1
    existing_notifier_v010_v020_validate_target_bundle "${target_root}/release" || return 1
    existing_notifier_v010_v020_preserved_target_bundle_is_exact \
        "${target_root}/release" "${target_root}/plugin-bundle.tar.gz" || return 1
    temporary_dir="$(mktemp -d)" || return 1
    trap 'rm -rf -- "${temporary_dir}"' EXIT HUP INT TERM
    chmod 0700 "${temporary_dir}"
    target_env="${temporary_dir}/existing-notifier.env"
    target_override="${temporary_dir}/compose.override.yml"
    queue_inspection="${temporary_dir}/queue-inspection.json"
    "${SUDO_COMMAND[@]}" cat "${target_root}/existing-notifier.env" > "${target_env}" || return 1
    "${SUDO_COMMAND[@]}" cat "${target_root}/compose.override.yml" > "${target_override}" || return 1
    "${SUDO_COMMAND[@]}" cat "${target_root}/queue-inspection-before.json" > "${queue_inspection}" || return 1
    chmod 0600 "${target_env}" "${target_override}" "${queue_inspection}"
    [[ "$(existing_notifier_v010_v020_config_state "${target_env}")" == target ]] || return 1
    existing_notifier_v010_v020_queue_inspection_is_valid "${queue_inspection}" || return 1
    [[ "$(jq -er '.schema_version' "${queue_inspection}")" == 1 ]] || return 1
    previous_env="${EXISTING_NOTIFIER_ENV_FILE}"
    EXISTING_NOTIFIER_ENV_FILE="${target_env}"
    existing_notifier_render_override "${temporary_dir}/expected.override.yml" || return 1
    cmp -s "${temporary_dir}/expected.override.yml" "${target_override}" || return 1
    project_dir="$(existing_notifier_v010_v020_value THN_COMPOSE_PROJECT_DIR)"
    compose_file="$(existing_notifier_v010_v020_value THN_COMPOSE_FILE)"
    compose_env="$(existing_notifier_v010_v020_value THN_COMPOSE_ENV_FILE)"
    if [[ "${#SUDO_COMMAND[@]}" -gt 0 && "${DOCKER_COMMAND[0]:-}" != "${SUDO_COMMAND[0]}" ]]; then
        privileged_docker=("${SUDO_COMMAND[@]}" docker)
    else
        privileged_docker=("${DOCKER_COMMAND[@]}")
    fi
    target_compose=(
        "${privileged_docker[@]}" compose --project-directory "${project_dir}"
        --env-file "${compose_env}" -f "${compose_file}"
        --env-file "${target_env}" -f "${target_override}"
    )
    model_file="${temporary_dir}/model.json"
    "${target_compose[@]}" config --quiet \
        && "${target_compose[@]}" config --format json > "${model_file}" \
        && existing_notifier_verify_combined_model "${model_file}"
    result=$?
    EXISTING_NOTIFIER_ENV_FILE="${previous_env}"
    return "${result}"
)

v010_v020_upgrade_prepare_target_release() (
    local target_root
    local migration_root
    local temporary_dir
    local target_env
    local target_override
    local queue_inspection

    target_root="$(existing_notifier_v010_v020_target_root)"
    migration_root="$(dirname "${target_root}")"
    if "${SUDO_COMMAND[@]}" test -e "${target_root}" \
        || "${SUDO_COMMAND[@]}" test -L "${target_root}"; then
        existing_notifier_v010_v020_upgrade_action_required \
            "Target release staging already exists and was not overwritten"
        return $?
    fi
    [[ "$(env_value NOTIFIER_VERSION "${VERSIONS_FILE}")" == "${EXISTING_NOTIFIER_V020_VERSION}" ]] \
        || return 1
    notifier_require_clean_source_commit >/dev/null \
        || return 1
    [[ "$(existing_notifier_v010_v020_capture_identity "${migration_root}")" == 0:0:700 ]] \
        || return 1
    "${SUDO_COMMAND[@]}" install -d -o 0 -g 0 -m 0700 "${target_root}" \
        && "${SUDO_COMMAND[@]}" install -d -o 0 -g 0 -m 0750 "${target_root}/release" \
        || return 1
    temporary_dir="$(mktemp -d)" || return 1
    trap 'rm -rf -- "${temporary_dir}"' EXIT HUP INT TERM
    chmod 0700 "${temporary_dir}"
    target_env="${temporary_dir}/existing-notifier.env"
    target_override="${temporary_dir}/compose.override.yml"
    queue_inspection="${temporary_dir}/queue-inspection-before.json"
    existing_notifier_v010_v020_prepare_target_config \
        "${EXISTING_NOTIFIER_V010_V020_ENV_FILE}" "${target_env}" || return 1
    (
        EXISTING_NOTIFIER_ENV_FILE="${target_env}"
        existing_notifier_render_override "${target_override}"
    ) || return 1
    notifier_build_artifacts "${target_root}/release" || return $?
    existing_notifier_v010_v020_preserve_target_bundle \
        "${target_root}/release" "${target_root}/plugin-bundle.tar.gz" || return 1
    existing_notifier_v010_v020_run_queue_inspector "${queue_inspection}" || return 1
    existing_notifier_v010_v020_queue_inspection_is_valid "${queue_inspection}" || return 1
    [[ "$(jq -er '.schema_version' "${queue_inspection}")" == 1 ]] || return 1
    "${SUDO_COMMAND[@]}" install -o 0 -g 0 -m 0600 "${target_env}" "${target_root}/existing-notifier.env" \
        && "${SUDO_COMMAND[@]}" install -o 0 -g 0 -m 0600 "${target_override}" "${target_root}/compose.override.yml" \
        && "${SUDO_COMMAND[@]}" install -o 0 -g 0 -m 0600 "${queue_inspection}" "${target_root}/queue-inspection-before.json" \
        || return 1
    existing_notifier_v010_v020_verify_target_stage
)

v010_v020_upgrade_recheck_preflight() {
    existing_notifier_v010_v020_preflight
}

v010_v020_upgrade_drain() {
    local state_file
    state_file="$(existing_notifier_v010_v020_value THN_DATA_ROOT)/control/state.json"
    notifier_transition_control_state "${state_file}" drain \
        && notifier_wait_for_control_reload
}

v010_v020_upgrade_require_queue_zero() (
    local temporary_dir
    local status_file
    local attempt

    temporary_dir="$(mktemp -d)" || return 1
    trap 'rm -rf -- "${temporary_dir}"' EXIT HUP INT TERM
    chmod 0700 "${temporary_dir}"
    status_file="${temporary_dir}/status.json"
    attempt=1
    while ((attempt <= 60)); do
        existing_notifier_v010_v020_compose_combined exec -T threadhub-mailer \
            /threadhub-mailer status --json > "${status_file}" || return 1
        existing_notifier_v010_v020_mailer_status_is_valid "${status_file}" || return 1
        if jq -e '.failed > 0' "${status_file}" >/dev/null; then
            existing_notifier_v010_v020_upgrade_action_required \
                "Failed deliveries require an explicit operator decision before transition"
            return $?
        fi
        if jq -e '.pending == 0 and .sending == 0 and .failed == 0' "${status_file}" >/dev/null; then
            return 0
        fi
        sleep 2
        attempt=$((attempt + 1))
    done
    existing_notifier_v010_v020_upgrade_action_required \
        "Notifier queue did not drain to zero before the approved window"
)

v010_v020_upgrade_disable() {
    local state_file
    state_file="$(existing_notifier_v010_v020_value THN_DATA_ROOT)/control/state.json"
    notifier_transition_control_state "${state_file}" disable \
        && notifier_wait_for_control_reload
}

v010_v020_upgrade_verify_control_loaded_disabled() {
    local state_file
    local temporary_file
    state_file="$(existing_notifier_v010_v020_value THN_DATA_ROOT)/control/state.json"
    temporary_file="$(mktemp)" || return 1
    if ! v010_v020_capture_control_is_disabled \
        "$(existing_notifier_v010_v020_attempt_root)" \
        || ! existing_notifier_v010_v020_compose_combined exec -T threadhub-mailer \
            /threadhub-mailer status --json > "${temporary_file}" \
        || ! existing_notifier_v010_v020_mailer_status_is_valid "${temporary_file}"; then
        rm -f -- "${temporary_file}"
        return 1
    fi
    rm -f -- "${temporary_file}"
    "${SUDO_COMMAND[@]}" jq -e '.enabled == false and .delivery_enabled == false' \
        "${state_file}" >/dev/null 2>&1
}

v010_v020_upgrade_stop_mailer() {
    existing_notifier_v010_v020_compose_combined stop threadhub-mailer
}

v010_v020_upgrade_capture_evidence() {
    existing_notifier_v010_v020_capture_evidence \
        "$(existing_notifier_v010_v020_attempt_root)"
}

v010_v020_upgrade_transaction() {
    existing_notifier_v010_v020_transaction \
        "$(existing_notifier_v010_v020_attempt_root)"
}

v010_v020_upgrade_post_status_disabled() {
    v010_v020_tx_verify_target_pair "$(existing_notifier_v010_v020_attempt_root)" \
        && v010_v020_tx_verify_disabled "$(existing_notifier_v010_v020_attempt_root)"
}

v010_v020_upgrade_action_required_smtp() {
    printf '[ACTION REQUIRED] Run ./deploy/scripts/existing-notifier-smtp-test.sh, then activate a public/private test-channel allowlist.\n' >&2
    return 20
}

existing_notifier_v010_v020_move_no_clobber() {
    local source_path="$1"
    local destination_path="$2"

    [[ "$#" -eq 2 ]] || return 2
    "${SUDO_COMMAND[@]}" test -e "${source_path}" \
        && "${SUDO_COMMAND[@]}" test ! -L "${source_path}" \
        && "${SUDO_COMMAND[@]}" test ! -e "${destination_path}" \
        && "${SUDO_COMMAND[@]}" test ! -L "${destination_path}" \
        && "${SUDO_COMMAND[@]}" mv -T -n -- "${source_path}" "${destination_path}" \
        && "${SUDO_COMMAND[@]}" test ! -e "${source_path}" \
        && "${SUDO_COMMAND[@]}" test -e "${destination_path}"
}

existing_notifier_v010_v020_prepare_disposition_roots() {
    local attempt_root="$1"
    "${SUDO_COMMAND[@]}" install -d -o 0 -g 0 -m 0700 \
        "${attempt_root}/displaced" "${attempt_root}/quarantine"
}

v010_v020_tx_verify_source_capture() {
    existing_notifier_v010_v020_source_capture_is_complete "$1"
}

v010_v020_tx_verify_target_release() {
    existing_notifier_v010_v020_verify_target_stage \
        && existing_notifier_v010_v020_prepare_disposition_roots "$1"
}

v010_v020_tx_publish_target_env() (
    local attempt_root="$1"
    local target_root
    local destination
    local candidate
    local expected_identity
    local expected_hash
    local captured_hash

    target_root="$(existing_notifier_v010_v020_target_root)"
    destination="${EXISTING_NOTIFIER_V010_V020_ENV_FILE}"
    candidate="$(dirname "${destination}")/.existing-notifier.v020.$$"
    trap 'rm -f -- "${candidate}"' EXIT HUP INT TERM
    [[ ! -e "${candidate}" && ! -L "${candidate}" ]] || return 1
    expected_identity="$(runtime_env_identity "${destination}")" || return 1
    expected_hash="$(sha256_file "${destination}")" || return 1
    captured_hash="$(existing_notifier_v010_v020_capture_hash \
        "${attempt_root}/source/existing-notifier.env")" || return 1
    [[ "${expected_hash}" == "${captured_hash}" ]] || return 1
    "${SUDO_COMMAND[@]}" cat "${target_root}/existing-notifier.env" > "${candidate}" || return 1
    chmod 0600 "${candidate}"
    runtime_env_replace_if_unchanged \
        "${candidate}" "${destination}" "${expected_identity}" "${expected_hash}" || return $?
    trap - EXIT HUP INT TERM
    [[ "$(existing_notifier_v010_v020_config_state "${destination}")" == target ]]
)

v010_v020_tx_publish_target_release() {
    local attempt_root="$1"
    local target_release
    local live_release
    local displaced_release

    target_release="$(existing_notifier_v010_v020_target_root)/release"
    live_release="$(existing_notifier_v010_v020_value THN_DATA_ROOT)/release"
    displaced_release="${attempt_root}/displaced/release-v010"
    existing_notifier_v010_v020_move_no_clobber "${live_release}" "${displaced_release}" \
        || return 1
    if ! existing_notifier_v010_v020_move_no_clobber "${target_release}" "${live_release}"; then
        existing_notifier_v010_v020_move_no_clobber \
            "${displaced_release}" "${live_release}" >/dev/null 2>&1 || true
        return 1
    fi
    notifier_artifact_release_is_current "${live_release}"
}

v010_v020_tx_publish_target_override() {
    local attempt_root="$1"
    local target_override
    local live_override
    local displaced_override

    target_override="$(existing_notifier_v010_v020_target_root)/compose.override.yml"
    live_override="$(existing_notifier_v010_v020_value THN_DATA_ROOT)/compose.override.yml"
    displaced_override="${attempt_root}/displaced/compose-v010.override.yml"
    existing_notifier_v010_v020_move_no_clobber "${live_override}" "${displaced_override}" \
        || return 1
    if ! existing_notifier_v010_v020_move_no_clobber "${target_override}" "${live_override}"; then
        existing_notifier_v010_v020_move_no_clobber \
            "${displaced_override}" "${live_override}" >/dev/null 2>&1 || true
        return 1
    fi
    EXISTING_NOTIFIER_ENV_FILE="${EXISTING_NOTIFIER_V010_V020_ENV_FILE}"
    existing_notifier_init_compose
    existing_notifier_compose_combined config --quiet
}

existing_notifier_v010_v020_extract_target_plugin() {
    local scratch_root="$1"
    local output_bundle_name="$2"
    local output_sha_name="$3"
    local output_root_name="$4"
    local release_copy
    local bundle_relative
    local bundle_sha
    local preserved_bundle
    local reviewed_bundle
    local reviewed_root

    [[ "$#" -eq 4 \
        && "${output_bundle_name}" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ \
        && "${output_sha_name}" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ \
        && "${output_root_name}" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]] || return 2
    release_copy="${scratch_root}/release.env"
    "${SUDO_COMMAND[@]}" cat \
        "$(existing_notifier_v010_v020_value THN_DATA_ROOT)/release/release.env" \
        > "${release_copy}" || return 1
    chmod 0600 "${release_copy}"
    bundle_relative="$(existing_notifier_v010_v020_release_value "${release_copy}" NOTIFIER_PLUGIN_BUNDLE)" || return 1
    bundle_sha="$(existing_notifier_v010_v020_release_value "${release_copy}" NOTIFIER_PLUGIN_BUNDLE_SHA256)" || return 1
    preserved_bundle="$(existing_notifier_v010_v020_target_root)/plugin-bundle.tar.gz"
    reviewed_bundle="${scratch_root}/target-plugin-bundle.tar.gz"
    existing_notifier_v010_v020_preserved_target_bundle_is_exact \
        "$(existing_notifier_v010_v020_value THN_DATA_ROOT)/release" \
        "${preserved_bundle}" || return 1
    [[ "${bundle_relative}" == "notifier/dist/com.threadhub.channel-email-notifier-${EXISTING_NOTIFIER_V020_VERSION}.tar.gz" \
        && "${bundle_sha}" =~ ^[a-f0-9]{64}$ \
        && ! -e "${reviewed_bundle}" && ! -L "${reviewed_bundle}" \
        && "$(notifier_plugin_privileged_sha256 "${preserved_bundle}")" == "${bundle_sha}" ]] \
        || return 1
    "${SUDO_COMMAND[@]}" cat "${preserved_bundle}" > "${reviewed_bundle}" || return 1
    chmod 0600 "${reviewed_bundle}"
    [[ -f "${reviewed_bundle}" && ! -L "${reviewed_bundle}" \
        && "$(sha256_file "${reviewed_bundle}")" == "${bundle_sha}" ]] || return 1
    tar -tzf "${reviewed_bundle}" > "${scratch_root}/entries" || return 1
    notifier_plugin_bundle_entries_are_valid \
        "${scratch_root}/entries" com.threadhub.channel-email-notifier current || return 1
    tar -tvzf "${reviewed_bundle}" > "${scratch_root}/verbose-entries" || return 1
    awk '{ type=substr($1,1,1); if (type != "-" && type != "d") exit 1 }' \
        "${scratch_root}/verbose-entries" || return 1
    mkdir -m 0700 "${scratch_root}/reviewed"
    tar --extract --gzip --file "${reviewed_bundle}" --directory "${scratch_root}/reviewed" \
        --no-same-owner --no-same-permissions || return 1
    reviewed_root="${scratch_root}/reviewed/com.threadhub.channel-email-notifier"
    jq -e --arg version "${EXISTING_NOTIFIER_V020_VERSION}" '
      .id == "com.threadhub.channel-email-notifier" and .version == $version and
      .min_server_version == "11.7.7" and
      .server.executables["linux-amd64"] == "server/dist/plugin-linux-amd64"
    ' "${reviewed_root}/plugin.json" >/dev/null || return 1
    printf -v "${output_bundle_name}" '%s' "${preserved_bundle}"
    printf -v "${output_sha_name}" '%s' "${bundle_sha}"
    printf -v "${output_root_name}" '%s' "${reviewed_root}"
}

existing_notifier_v010_v020_plugin_publish_record_halt() {
    case "$1" in
        target-extracted|source-hashed|source-verified|target-staged|filesystem-verified|mattermost-stopped|pair-transacted) ;;
        *) return 2 ;;
    esac
    printf '[threadhub] ERROR: notifier plugin publication halted at stage: %s\n' "$1" >&2
}

v010_v020_tx_publish_target_plugin_pair() (
    local attempt_root="$1"
    local target_root
    local plugin_id=com.threadhub.channel-email-notifier
    local live_runtime
    local live_bundle
    local stage_runtime
    local stage_bundle
    local displaced_runtime
    local displaced_bundle
    local failed_runtime
    local failed_bundle
    local source_scratch_root
    local target_scratch_root
    local source_sha
    local source_runtime
    local source_bundle
    local service
    local runtime_device
    local bundle_device
    local stage_device
    local stage_status
    local target_bundle=""
    local target_bundle_sha=""
    local target_reviewed_root=""

    target_root="$(existing_notifier_v010_v020_target_root)"
    live_runtime="$(existing_notifier_v010_v020_value THN_MATTERMOST_PLUGINS_ROOT)/${plugin_id}"
    live_bundle="$(existing_notifier_v010_v020_value THN_MATTERMOST_DATA_ROOT)/plugins/${plugin_id}.tar.gz"
    stage_runtime="${target_root}/plugin-runtime-stage"
    stage_bundle="${target_root}/plugin-bundle-stage.tar.gz"
    displaced_runtime="${attempt_root}/displaced/plugin-runtime-v010"
    displaced_bundle="${attempt_root}/displaced/plugin-bundle-v010.tar.gz"
    failed_runtime="${attempt_root}/quarantine/plugin-runtime-v020"
    failed_bundle="${attempt_root}/quarantine/plugin-bundle-v020.tar.gz"
    source_runtime="${attempt_root}/source/plugin-runtime"
    source_bundle="${attempt_root}/source/plugin-bundle.tar.gz"
    service="$(existing_notifier_v010_v020_value THN_MATTERMOST_SERVICE)"
    source_scratch_root="$(mktemp -d)" || return 1
    target_scratch_root="$(mktemp -d)" || {
        notifier_plugin_cleanup_scratch_root "${source_scratch_root}"
        return 1
    }
    trap 'notifier_plugin_cleanup_scratch_root "${source_scratch_root}"; notifier_plugin_cleanup_scratch_root "${target_scratch_root}"' EXIT HUP INT TERM
    chmod 0700 "${source_scratch_root}" "${target_scratch_root}"
    source_sha="$(existing_notifier_v010_v020_capture_hash "${source_bundle}")" || {
        stage_status=$?
        existing_notifier_v010_v020_plugin_publish_record_halt source-hashed
        return "${stage_status}"
    }
    notifier_plugin_pair_is_exact \
        "${live_runtime}" "${live_bundle}" "${source_runtime}" "${source_sha}" "${source_scratch_root}" \
        || {
            stage_status=$?
            existing_notifier_v010_v020_plugin_publish_record_halt source-verified
            return "${stage_status}"
        }
    existing_notifier_v010_v020_extract_target_plugin \
        "${target_scratch_root}" target_bundle target_bundle_sha target_reviewed_root || {
        stage_status=$?
        existing_notifier_v010_v020_plugin_publish_record_halt target-extracted
        return "${stage_status}"
    }
    notifier_plugin_stage_pair \
        "${target_bundle}" \
        "${target_reviewed_root}" \
        "${stage_runtime}" "${stage_bundle}" \
        "${target_bundle_sha}" "${target_scratch_root}" || {
            stage_status=$?
            existing_notifier_v010_v020_plugin_publish_record_halt target-staged
            return "${stage_status}"
        }
    runtime_device="$("${SUDO_COMMAND[@]}" stat -c '%d' "$(dirname "${live_runtime}")")" || stage_status=$?
    if [[ -n "${stage_status:-}" ]]; then
        existing_notifier_v010_v020_plugin_publish_record_halt filesystem-verified
        return "${stage_status}"
    fi
    bundle_device="$("${SUDO_COMMAND[@]}" stat -c '%d' "$(dirname "${live_bundle}")")" || stage_status=$?
    if [[ -n "${stage_status:-}" ]]; then
        existing_notifier_v010_v020_plugin_publish_record_halt filesystem-verified
        return "${stage_status}"
    fi
    stage_device="$("${SUDO_COMMAND[@]}" stat -c '%d' "${target_root}")" || stage_status=$?
    if [[ -n "${stage_status:-}" ]]; then
        existing_notifier_v010_v020_plugin_publish_record_halt filesystem-verified
        return 1
    fi
    if [[ "${runtime_device}" != "${bundle_device}" ]] \
        || [[ "${runtime_device}" != "${stage_device}" ]]; then
        existing_notifier_v010_v020_plugin_publish_record_halt filesystem-verified
        return 1
    fi

    printf '[threadhub] Mattermost will reconnect for approximately 30-60 seconds during the reviewed plugin transition.\n' >&2
    existing_notifier_v010_v020_compose_combined stop "${service}" || {
        stage_status=$?
        existing_notifier_v010_v020_plugin_publish_record_halt mattermost-stopped
        return "${stage_status}"
    }

    plugin_tx_path_exists() { "${SUDO_COMMAND[@]}" test -e "$1" || "${SUDO_COMMAND[@]}" test -L "$1"; }
    plugin_tx_move() { notifier_plugin_move_no_clobber "$1" "$2"; }
    plugin_tx_disable_control() { v010_v020_capture_control_is_disabled "${attempt_root}"; }
    plugin_tx_prepare_targets() {
        [[ "$(notifier_plugin_pair_presence "${live_runtime}" "${live_bundle}")" == present ]] \
            && notifier_plugin_pair_is_exact \
                "${live_runtime}" "${live_bundle}" "${source_runtime}" "${source_sha}" "${source_scratch_root}" \
            && notifier_plugin_pair_is_exact \
                "${stage_runtime}" "${stage_bundle}" \
                "${target_reviewed_root}" \
                "${target_bundle_sha}" "${target_scratch_root}"
    }
    plugin_tx_stop_service() { return 0; }
    plugin_tx_start_service() { return 0; }
    plugin_tx_enable_plugin() { return 0; }
    plugin_tx_verify_plugin() {
        notifier_plugin_pair_is_exact \
            "${live_runtime}" "${live_bundle}" \
            "${target_reviewed_root}" \
            "${target_bundle_sha}" "${target_scratch_root}"
    }
    # shellcheck disable=SC2329 # invoked indirectly by notifier_plugin_transaction
    plugin_tx_verify_previous_objects() {
        notifier_plugin_pair_is_exact \
            "${live_runtime}" "${live_bundle}" "${source_runtime}" "${source_sha}" "${source_scratch_root}"
    }
    existing_notifier_v010_v020_tx_plugin_pair_transaction \
        "${live_runtime}" "${stage_runtime}" "${displaced_runtime}" "${failed_runtime}" \
        "${live_bundle}" "${stage_bundle}" "${displaced_bundle}" "${failed_bundle}" \
        false false || {
            stage_status=$?
            existing_notifier_v010_v020_plugin_publish_record_halt pair-transacted
            return "${stage_status}"
        }
)

v010_v020_tx_start_target_mailer() {
    EXISTING_NOTIFIER_ENV_FILE="${EXISTING_NOTIFIER_V010_V020_ENV_FILE}"
    existing_notifier_init_compose
    existing_notifier_compose_combined up -d --no-deps --wait --wait-timeout 120 threadhub-mailer \
        && existing_notifier_compose_combined exec -T threadhub-mailer \
            /threadhub-mailer healthcheck >/dev/null
}

v010_v020_tx_inspect_target_queue_v2() (
    local attempt_root="$1"
    local temporary_dir
    local current_file
    local source_file

    temporary_dir="$(mktemp -d)" || return 1
    trap 'rm -rf -- "${temporary_dir}"' EXIT HUP INT TERM
    chmod 0700 "${temporary_dir}"
    current_file="${temporary_dir}/current.json"
    source_file="${temporary_dir}/source.json"
    existing_notifier_compose_combined exec -T threadhub-mailer \
        /threadhub-mailer queue-inspect --json > "${current_file}" || return 1
    "${SUDO_COMMAND[@]}" cat "${attempt_root}/queue-inspection.json" > "${source_file}" || return 1
    chmod 0600 "${current_file}" "${source_file}"
    existing_notifier_v010_v020_queue_inspection_is_valid "${current_file}" \
        && existing_notifier_v010_v020_queue_inspection_is_valid "${source_file}" \
        && [[ "$(jq -er '.schema_version' "${current_file}")" == 2 ]] \
        && [[ "$(jq -S 'del(.schema_version)' "${current_file}")" \
            == "$(jq -S 'del(.schema_version)' "${source_file}")" ]] \
        && "${SUDO_COMMAND[@]}" test ! -e "${attempt_root}/target-queue-inspection.json" \
        && "${SUDO_COMMAND[@]}" test ! -L "${attempt_root}/target-queue-inspection.json" \
        && "${SUDO_COMMAND[@]}" install -o 0 -g 0 -m 0600 \
            "${current_file}" "${attempt_root}/target-queue-inspection.json"
)

v010_v020_tx_recreate_target_mattermost() {
    existing_notifier_compose_combined up -d --no-deps --wait --wait-timeout 240 \
        "$(existing_notifier_v010_v020_value THN_MATTERMOST_SERVICE)"
}

v010_v020_tx_verify_target_pair() (
    local attempt_root="$1"
    local temporary_dir
    local plugin_list
    local service
    local runtime
    local bundle
    local mailer_id
    local expected_mailer_id
    local target_bundle=""
    local target_bundle_sha=""
    local target_reviewed_root=""

    temporary_dir="$(mktemp -d)" || return 1
    trap 'rm -rf -- "${temporary_dir}"' EXIT HUP INT TERM
    chmod 0700 "${temporary_dir}"
    existing_notifier_v010_v020_extract_target_plugin \
        "${temporary_dir}" target_bundle target_bundle_sha target_reviewed_root || return 1
    service="$(existing_notifier_v010_v020_value THN_MATTERMOST_SERVICE)"
    runtime="$(existing_notifier_v010_v020_value THN_MATTERMOST_PLUGINS_ROOT)/com.threadhub.channel-email-notifier"
    bundle="$(existing_notifier_v010_v020_value THN_MATTERMOST_DATA_ROOT)/plugins/com.threadhub.channel-email-notifier.tar.gz"
    notifier_plugin_pair_is_exact \
        "${runtime}" "${bundle}" "${target_reviewed_root}" \
        "${target_bundle_sha}" "${temporary_dir}" || return 1
    plugin_list="${temporary_dir}/plugins.json"
    existing_notifier_compose_combined exec -T "${service}" \
        mmctl plugin list --local --suppress-warnings --json > "${plugin_list}" || return 1
    if ! notifier_plugin_list_is_exact_active "${plugin_list}" \
        com.threadhub.channel-email-notifier "${EXISTING_NOTIFIER_V020_VERSION}"; then
        [[ "$(notifier_plugin_list_target_state "${plugin_list}" com.threadhub.channel-email-notifier)" \
            == $'inactive\t'"${EXISTING_NOTIFIER_V020_VERSION}" ]] || return 1
        existing_notifier_compose_combined exec -T "${service}" \
            mmctl plugin enable com.threadhub.channel-email-notifier \
                --local --suppress-warnings >/dev/null || return 1
        existing_notifier_compose_combined exec -T "${service}" \
            mmctl plugin list --local --suppress-warnings --json > "${plugin_list}" || return 1
        notifier_plugin_list_is_exact_active "${plugin_list}" \
            com.threadhub.channel-email-notifier "${EXISTING_NOTIFIER_V020_VERSION}" || return 1
    fi
    mailer_id="$(existing_notifier_v010_v020_compose_combined ps -q threadhub-mailer)" || return 1
    expected_mailer_id="$(existing_notifier_v010_v020_release_value \
        "${temporary_dir}/release.env" NOTIFIER_MAILER_IMAGE_ID)" || return 1
    [[ "${mailer_id}" =~ ^[a-f0-9]{64}$ \
        && "$(existing_notifier_v010_v020_running_image_id "${mailer_id}")" == "${expected_mailer_id}" ]] \
        && existing_notifier_v010_v020_compose_combined exec -T threadhub-mailer \
            /threadhub-mailer healthcheck >/dev/null \
        && v010_v020_capture_control_is_disabled "${attempt_root}"
)

v010_v020_tx_capture_after_baseline() {
    existing_notifier_v010_v020_capture_baseline "$1/after-baseline.json"
}

v010_v020_tx_compare_baseline() (
    local attempt_root="$1"
    local temporary_dir
    local before
    local after

    temporary_dir="$(mktemp -d)" || return 1
    trap 'rm -rf -- "${temporary_dir}"' EXIT HUP INT TERM
    chmod 0700 "${temporary_dir}"
    before="${temporary_dir}/before.json"
    after="${temporary_dir}/after.json"
    "${SUDO_COMMAND[@]}" cat "${attempt_root}/baseline.json" > "${before}" || return 1
    "${SUDO_COMMAND[@]}" cat "${attempt_root}/after-baseline.json" > "${after}" || return 1
    chmod 0600 "${before}" "${after}"
    existing_notifier_v010_v020_baseline_is_valid "${before}" \
        && existing_notifier_v010_v020_baseline_is_valid "${after}" \
        && jq -e --slurp '.[0] == .[1]' "${before}" "${after}" >/dev/null
)

v010_v020_tx_verify_disabled() {
    v010_v020_capture_control_is_disabled "$1"
}

v010_v020_tx_mark_target_ready() {
    return 0
}

existing_notifier_v010_v020_objects_match() {
    local first="$1"
    local second="$2"
    local object_type="$3"

    case "${object_type}" in
        file)
            "${SUDO_COMMAND[@]}" test -f "${first}" \
                && "${SUDO_COMMAND[@]}" test ! -L "${first}" \
                && "${SUDO_COMMAND[@]}" test -f "${second}" \
                && "${SUDO_COMMAND[@]}" test ! -L "${second}" \
                && [[ "$(existing_notifier_v010_v020_capture_identity "${first}")" \
                    == "$(existing_notifier_v010_v020_capture_identity "${second}")" ]] \
                && [[ "$(existing_notifier_v010_v020_capture_hash "${first}")" \
                    == "$(existing_notifier_v010_v020_capture_hash "${second}")" ]]
            ;;
        directory)
            "${SUDO_COMMAND[@]}" test -d "${first}" \
                && "${SUDO_COMMAND[@]}" test ! -L "${first}" \
                && "${SUDO_COMMAND[@]}" test -d "${second}" \
                && "${SUDO_COMMAND[@]}" test ! -L "${second}" \
                && [[ "$(existing_notifier_v010_v020_capture_identity "${first}")" \
                    == "$(existing_notifier_v010_v020_capture_identity "${second}")" ]] \
                && "${SUDO_COMMAND[@]}" diff -qr -- "${first}" "${second}" >/dev/null
            ;;
        *) return 2 ;;
    esac
}

existing_notifier_v010_v020_restore_source_plugin_pair() (
    local attempt_root="$1"
    local plugin_id=com.threadhub.channel-email-notifier
    local live_runtime
    local live_bundle
    local captured_runtime
    local captured_bundle
    local displaced_runtime
    local displaced_bundle
    local quarantine_runtime
    local quarantine_bundle
    local source_sha
    local scratch_root
    local live_presence
    local displaced_presence

    live_runtime="$(existing_notifier_v010_v020_value THN_MATTERMOST_PLUGINS_ROOT)/${plugin_id}"
    live_bundle="$(existing_notifier_v010_v020_value THN_MATTERMOST_DATA_ROOT)/plugins/${plugin_id}.tar.gz"
    captured_runtime="${attempt_root}/source/plugin-runtime"
    captured_bundle="${attempt_root}/source/plugin-bundle.tar.gz"
    displaced_runtime="${attempt_root}/displaced/plugin-runtime-v010"
    displaced_bundle="${attempt_root}/displaced/plugin-bundle-v010.tar.gz"
    quarantine_runtime="${attempt_root}/quarantine/plugin-runtime-v020"
    quarantine_bundle="${attempt_root}/quarantine/plugin-bundle-v020.tar.gz"
    scratch_root="$(mktemp -d)" || return 1
    trap 'notifier_plugin_cleanup_scratch_root "${scratch_root}"' EXIT HUP INT TERM
    chmod 0700 "${scratch_root}"
    source_sha="$(existing_notifier_v010_v020_capture_hash "${captured_bundle}")" || return 1
    live_presence="$(notifier_plugin_pair_presence "${live_runtime}" "${live_bundle}")" || return 1
    if [[ "${live_presence}" == present ]] \
        && notifier_plugin_pair_is_exact \
            "${live_runtime}" "${live_bundle}" "${captured_runtime}" "${source_sha}" "${scratch_root}"; then
        return 0
    fi
    if [[ "${live_presence}" == present ]]; then
        existing_notifier_v010_v020_move_no_clobber \
            "${live_runtime}" "${quarantine_runtime}" || return 1
        if ! existing_notifier_v010_v020_move_no_clobber \
            "${live_bundle}" "${quarantine_bundle}"; then
            existing_notifier_v010_v020_move_no_clobber \
                "${quarantine_runtime}" "${live_runtime}" >/dev/null 2>&1 || true
            return 1
        fi
    elif [[ "${live_presence}" != absent ]]; then
        return 1
    fi
    displaced_presence="$(notifier_plugin_pair_presence \
        "${displaced_runtime}" "${displaced_bundle}")" || return 1
    if [[ "${displaced_presence}" == present ]]; then
        notifier_plugin_pair_is_exact \
            "${displaced_runtime}" "${displaced_bundle}" \
            "${captured_runtime}" "${source_sha}" "${scratch_root}" || return 1
        existing_notifier_v010_v020_move_no_clobber \
            "${displaced_runtime}" "${live_runtime}" || return 1
        if ! existing_notifier_v010_v020_move_no_clobber \
            "${displaced_bundle}" "${live_bundle}"; then
            existing_notifier_v010_v020_move_no_clobber \
                "${live_runtime}" "${displaced_runtime}" >/dev/null 2>&1 || true
            return 1
        fi
    elif [[ "${displaced_presence}" == absent ]]; then
        notifier_plugin_stage_pair \
            "${captured_bundle}" "${captured_runtime}" \
            "${live_runtime}" "${live_bundle}" "${source_sha}" "${scratch_root}" || return 1
    else
        return 1
    fi
    notifier_plugin_pair_is_exact \
        "${live_runtime}" "${live_bundle}" "${captured_runtime}" "${source_sha}" "${scratch_root}"
)

existing_notifier_v010_v020_restore_object() {
    local live="$1"
    local captured="$2"
    local displaced="$3"
    local quarantine="$4"
    local object_type="$5"

    [[ "$#" -eq 5 ]] || return 2
    if existing_notifier_v010_v020_objects_match "${live}" "${captured}" "${object_type}"; then
        return 0
    fi
    if "${SUDO_COMMAND[@]}" test -e "${live}" \
        || "${SUDO_COMMAND[@]}" test -L "${live}"; then
        existing_notifier_v010_v020_move_no_clobber "${live}" "${quarantine}" || return 1
    fi
    if "${SUDO_COMMAND[@]}" test -e "${displaced}" \
        || "${SUDO_COMMAND[@]}" test -L "${displaced}"; then
        existing_notifier_v010_v020_objects_match \
            "${displaced}" "${captured}" "${object_type}" || return 1
        existing_notifier_v010_v020_move_no_clobber "${displaced}" "${live}" || return 1
    elif [[ "${object_type}" == file ]]; then
        "${SUDO_COMMAND[@]}" cp -p "${captured}" "${live}" || return 1
    else
        "${SUDO_COMMAND[@]}" cp -a "${captured}" "${live}" || return 1
    fi
    existing_notifier_v010_v020_objects_match "${live}" "${captured}" "${object_type}"
}

existing_notifier_v010_v020_live_queue_matches_capture() (
    local live_root="$1"
    local captured_root="$2"
    local entries_file=""
    local path
    local name

    [[ "$(existing_notifier_v010_v020_capture_identity "${live_root}")" == 65532:65532:700 ]] \
        || return 1
    entries_file="$(mktemp)" || return 1
    trap 'rm -f -- "${entries_file}"' EXIT
    "${SUDO_COMMAND[@]}" find "${live_root}" -mindepth 1 -maxdepth 1 -print > "${entries_file}" || {
        return 1
    }
    while IFS= read -r path; do
        name="${path##*/}"
        case "${name}" in queue.db|queue.db-wal|queue.db-shm) ;; *) return 1 ;; esac
        if [[ "$(existing_notifier_v010_v020_capture_identity "${path}")" != 65532:65532:600 ]] \
            || ! "${SUDO_COMMAND[@]}" test -f "${captured_root}/${name}" \
            || ! "${SUDO_COMMAND[@]}" cmp -s "${path}" "${captured_root}/${name}"; then
            return 1
        fi
    done < "${entries_file}"
    "${SUDO_COMMAND[@]}" test -f "${live_root}/queue.db"
)

existing_notifier_v010_v020_restore_queue() {
    local attempt_root="$1"
    local live_root
    local captured_root
    local quarantine_root
    local name

    live_root="$(existing_notifier_v010_v020_value THN_DATA_ROOT)/mailer"
    captured_root="${attempt_root}/source/mailer"
    quarantine_root="${attempt_root}/quarantine/mailer-v020"
    if existing_notifier_v010_v020_live_queue_matches_capture "${live_root}" "${captured_root}"; then
        return 0
    fi
    if "${SUDO_COMMAND[@]}" test -e "${live_root}" \
        || "${SUDO_COMMAND[@]}" test -L "${live_root}"; then
        existing_notifier_v010_v020_move_no_clobber "${live_root}" "${quarantine_root}" || return 1
    fi
    "${SUDO_COMMAND[@]}" install -d -o 65532 -g 65532 -m 0700 "${live_root}" || return 1
    for name in queue.db queue.db-wal queue.db-shm; do
        if "${SUDO_COMMAND[@]}" test -e "${captured_root}/${name}"; then
            "${SUDO_COMMAND[@]}" test -f "${captured_root}/${name}" \
                && "${SUDO_COMMAND[@]}" test ! -L "${captured_root}/${name}" \
                && "${SUDO_COMMAND[@]}" install -o 65532 -g 65532 -m 0600 \
                    "${captured_root}/${name}" "${live_root}/${name}" || return 1
        fi
    done
    "${SUDO_COMMAND[@]}" test -f "${live_root}/queue.db" \
        && "${SUDO_COMMAND[@]}" cmp -s "${captured_root}/queue.db" "${live_root}/queue.db"
}

existing_notifier_v010_v020_restore_source_image() (
    local attempt_root="$1"
    local temporary_dir
    local expected_id
    local actual_id

    temporary_dir="$(mktemp -d)" || return 1
    trap 'rm -rf -- "${temporary_dir}"' EXIT HUP INT TERM
    chmod 0700 "${temporary_dir}"
    "${SUDO_COMMAND[@]}" cat "${attempt_root}/source/mailer-image-id" \
        > "${temporary_dir}/image-id" || return 1
    expected_id="$(tr -d '\r\n' < "${temporary_dir}/image-id")"
    [[ "${expected_id}" =~ ^sha256:[a-f0-9]{64}$ ]] || return 1
    actual_id="$("${DOCKER_COMMAND[@]}" image inspect --format '{{.Id}}' \
        "threadhub/notifier-mailer:${EXISTING_NOTIFIER_V010_VERSION}" 2>/dev/null || true)"
    if [[ "${actual_id}" != "${expected_id}" ]]; then
        "${SUDO_COMMAND[@]}" cat "${attempt_root}/source/mailer-image.tar" \
            | "${DOCKER_COMMAND[@]}" image load >/dev/null || return 1
        actual_id="$("${DOCKER_COMMAND[@]}" image inspect --format '{{.Id}}' \
            "threadhub/notifier-mailer:${EXISTING_NOTIFIER_V010_VERSION}")" || return 1
    fi
    [[ "${actual_id}" == "${expected_id}" ]]
)

existing_notifier_v010_v020_verify_source_runtime() (
    local attempt_root="$1"
    local temporary_dir
    local queue_file
    local source_queue
    local source_sha
    local service
    local plugin_list
    local mailer_id
    local expected_mailer_id
    local recovery_baseline
    local expected_baseline

    temporary_dir="$(mktemp -d)" || return 1
    trap 'rm -rf -- "${temporary_dir}"' EXIT HUP INT TERM
    chmod 0700 "${temporary_dir}"
    queue_file="${temporary_dir}/queue.json"
    source_queue="${temporary_dir}/source-queue.json"
    existing_notifier_v010_v020_run_queue_inspector "${queue_file}" || return 1
    "${SUDO_COMMAND[@]}" cat "${attempt_root}/queue-inspection.json" > "${source_queue}" || return 1
    chmod 0600 "${queue_file}" "${source_queue}"
    [[ "$(jq -er '.schema_version' "${queue_file}")" == 1 \
        && "$(jq -S . "${queue_file}")" == "$(jq -S . "${source_queue}")" ]] || return 1
    source_sha="$(existing_notifier_v010_v020_capture_hash \
        "${attempt_root}/source/plugin-bundle.tar.gz")" || return 1
    notifier_plugin_pair_is_exact \
        "$(existing_notifier_v010_v020_value THN_MATTERMOST_PLUGINS_ROOT)/com.threadhub.channel-email-notifier" \
        "$(existing_notifier_v010_v020_value THN_MATTERMOST_DATA_ROOT)/plugins/com.threadhub.channel-email-notifier.tar.gz" \
        "${attempt_root}/source/plugin-runtime" "${source_sha}" "${temporary_dir}" || return 1
    service="$(existing_notifier_v010_v020_value THN_MATTERMOST_SERVICE)"
    plugin_list="${temporary_dir}/plugins.json"
    existing_notifier_v010_v020_compose_combined exec -T "${service}" \
        mmctl plugin list --local --suppress-warnings --json > "${plugin_list}" || return 1
    if ! notifier_plugin_list_is_exact_active "${plugin_list}" \
        com.threadhub.channel-email-notifier "${EXISTING_NOTIFIER_V010_VERSION}"; then
        [[ "$(notifier_plugin_list_target_state "${plugin_list}" com.threadhub.channel-email-notifier)" \
            == $'inactive\t'"${EXISTING_NOTIFIER_V010_VERSION}" ]] || return 1
        existing_notifier_v010_v020_compose_combined exec -T "${service}" \
            mmctl plugin enable com.threadhub.channel-email-notifier \
                --local --suppress-warnings >/dev/null || return 1
        existing_notifier_v010_v020_compose_combined exec -T "${service}" \
            mmctl plugin list --local --suppress-warnings --json > "${plugin_list}" || return 1
        notifier_plugin_list_is_exact_active "${plugin_list}" \
            com.threadhub.channel-email-notifier "${EXISTING_NOTIFIER_V010_VERSION}" || return 1
    fi
    mailer_id="$(existing_notifier_v010_v020_compose_combined ps -q threadhub-mailer)" || return 1
    "${SUDO_COMMAND[@]}" cat "${attempt_root}/source/mailer-image-id" \
        > "${temporary_dir}/source-image-id" || return 1
    expected_mailer_id="$(tr -d '\r\n' < "${temporary_dir}/source-image-id")"
    [[ "${mailer_id}" =~ ^[a-f0-9]{64}$ \
        && "$(existing_notifier_v010_v020_running_image_id "${mailer_id}")" == "${expected_mailer_id}" ]] \
        || return 1
    v010_v020_capture_control_is_disabled "${attempt_root}" || return 1
    recovery_baseline="${attempt_root}/recovery-baseline.json"
    if "${SUDO_COMMAND[@]}" test -e "${recovery_baseline}"; then
        "${SUDO_COMMAND[@]}" test -f "${recovery_baseline}" \
            && "${SUDO_COMMAND[@]}" test ! -L "${recovery_baseline}" || return 1
    else
        existing_notifier_v010_v020_capture_baseline "${recovery_baseline}" || return 1
    fi
    expected_baseline="$(existing_notifier_v010_v020_expected_recovery_baseline "${attempt_root}")" \
        || return 1
    "${SUDO_COMMAND[@]}" cat "${expected_baseline}" > "${temporary_dir}/before.json" || return 1
    "${SUDO_COMMAND[@]}" cat "${recovery_baseline}" > "${temporary_dir}/after.json" || return 1
    jq -e --slurp '.[0] == .[1]' \
        "${temporary_dir}/before.json" "${temporary_dir}/after.json" >/dev/null
)

existing_notifier_v010_v020_expected_recovery_baseline() {
    local attempt_root="$1"
    local candidate="${attempt_root}/rollback-before-baseline.json"

    [[ "$#" -eq 1 ]] || return 2
    if "${SUDO_COMMAND[@]}" test -e "${candidate}" \
        || "${SUDO_COMMAND[@]}" test -L "${candidate}"; then
        "${SUDO_COMMAND[@]}" test -f "${candidate}" \
            && "${SUDO_COMMAND[@]}" test ! -L "${candidate}" \
            && printf '%s\n' "${candidate}"
        return
    fi
    candidate="${attempt_root}/baseline.json"
    "${SUDO_COMMAND[@]}" test -f "${candidate}" \
        && "${SUDO_COMMAND[@]}" test ! -L "${candidate}" \
        && printf '%s\n' "${candidate}"
}

existing_notifier_v010_v020_recover_source_runtime() (
    local attempt_root="$1"
    local notifier_root
    local service

    existing_notifier_v010_v020_source_capture_is_complete "${attempt_root}" || return 1
    notifier_root="$(existing_notifier_v010_v020_value THN_DATA_ROOT)"
    service="$(existing_notifier_v010_v020_value THN_MATTERMOST_SERVICE)"
    existing_notifier_v010_v020_prepare_disposition_roots "${attempt_root}" || return 1
    existing_notifier_v010_v020_compose_combined stop threadhub-mailer >/dev/null 2>&1 || true
    existing_notifier_v010_v020_compose_combined stop "${service}" >/dev/null 2>&1 || true

    existing_notifier_v010_v020_restore_queue "${attempt_root}" || return 1
    existing_notifier_v010_v020_restore_object \
        "${EXISTING_NOTIFIER_V010_V020_ENV_FILE}" \
        "${attempt_root}/source/existing-notifier.env" \
        "${attempt_root}/displaced/env-not-used" \
        "${attempt_root}/quarantine/existing-notifier-v020.env" file || return 1
    existing_notifier_v010_v020_restore_object \
        "${notifier_root}/release" "${attempt_root}/source/release" \
        "${attempt_root}/displaced/release-v010" \
        "${attempt_root}/quarantine/release-v020" directory || return 1
    existing_notifier_v010_v020_restore_object \
        "${notifier_root}/compose.override.yml" "${attempt_root}/source/compose.override.yml" \
        "${attempt_root}/displaced/compose-v010.override.yml" \
        "${attempt_root}/quarantine/compose-v020.override.yml" file || return 1
    existing_notifier_v010_v020_restore_source_plugin_pair "${attempt_root}" || return 1
    existing_notifier_v010_v020_restore_object \
        "${notifier_root}/control/state.json" "${attempt_root}/source/control-state.json" \
        "${attempt_root}/displaced/control-not-used" \
        "${attempt_root}/quarantine/control-v020.json" file || return 1
    existing_notifier_v010_v020_restore_source_image "${attempt_root}" || return 1

    EXISTING_NOTIFIER_ENV_FILE="${EXISTING_NOTIFIER_V010_V020_ENV_FILE}"
    existing_notifier_init_compose
    existing_notifier_compose_combined up -d --no-deps --wait --wait-timeout 240 \
        "${service}" || return 1
    existing_notifier_compose_combined up -d --no-deps --wait --wait-timeout 120 \
        threadhub-mailer || return 1
    existing_notifier_v010_v020_verify_source_runtime "${attempt_root}"
)

v010_v020_tx_recover_source() {
    existing_notifier_v010_v020_recover_source_runtime "$1"
}

v010_v020_upgrade_recover_disabled_source() {
    local attempt_root
    attempt_root="$(existing_notifier_v010_v020_attempt_root)"
    if "${SUDO_COMMAND[@]}" test -e "${attempt_root}/manifest.json"; then
        existing_notifier_v010_v020_recover_source_runtime "${attempt_root}"
    else
        EXISTING_NOTIFIER_ENV_FILE="${EXISTING_NOTIFIER_V010_V020_ENV_FILE}"
        existing_notifier_init_compose
        existing_notifier_v010_v020_compose_combined up -d --no-deps --wait --wait-timeout 120 \
            threadhub-mailer \
            && v010_v020_capture_control_is_disabled "${attempt_root}"
    fi
}

existing_notifier_v010_v020_upgrade() (
    set -Eeuo pipefail

    [[ "$#" -eq 0 ]] || return 2
    disabled_boundary=false
    upgrade_complete=false
    stage_status=0

    # shellcheck disable=SC2329 # invoked by EXIT after a post-disable failure
    recover_upgrade() {
        original_result=$?
        trap - EXIT HUP INT TERM
        if [[ "${upgrade_complete}" == true || "${disabled_boundary}" != true ]]; then
            exit "${original_result}"
        fi
        set +e
        if v010_v020_upgrade_recover_disabled_source; then
            printf '[threadhub] ERROR: notifier upgrade stopped; exact source state is disabled and available\n' >&2
            if ((original_result == 0)); then
                exit 1
            fi
            exit "${original_result}"
        fi
        printf '[threadhub] ERROR: notifier upgrade stopped and source recovery is incomplete; delivery remains disabled\n' >&2
        exit 70
    }
    trap recover_upgrade EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM

    v010_v020_upgrade_preflight || {
        stage_status=$?
        existing_notifier_v010_v020_upgrade_record_halt preflight
        return "${stage_status}"
    }
    v010_v020_upgrade_prepare_target_release || {
        stage_status=$?
        existing_notifier_v010_v020_upgrade_record_halt prepare-target-release
        return "${stage_status}"
    }
    v010_v020_upgrade_recheck_preflight || {
        stage_status=$?
        existing_notifier_v010_v020_upgrade_record_halt recheck-preflight
        return "${stage_status}"
    }
    v010_v020_upgrade_drain || {
        stage_status=$?
        existing_notifier_v010_v020_upgrade_record_halt drain
        return "${stage_status}"
    }
    v010_v020_upgrade_require_queue_zero || {
        stage_status=$?
        existing_notifier_v010_v020_upgrade_record_halt queue-zero
        return "${stage_status}"
    }
    disabled_boundary=true
    v010_v020_upgrade_disable || {
        stage_status=$?
        existing_notifier_v010_v020_upgrade_record_halt disable
        return "${stage_status}"
    }
    v010_v020_upgrade_verify_control_loaded_disabled || {
        stage_status=$?
        existing_notifier_v010_v020_upgrade_record_halt control-loaded-disabled
        return "${stage_status}"
    }
    v010_v020_upgrade_stop_mailer || {
        stage_status=$?
        existing_notifier_v010_v020_upgrade_record_halt stop-mailer
        return "${stage_status}"
    }
    v010_v020_upgrade_capture_evidence || {
        stage_status=$?
        existing_notifier_v010_v020_upgrade_record_halt capture-evidence
        return "${stage_status}"
    }
    v010_v020_upgrade_transaction || {
        stage_status=$?
        existing_notifier_v010_v020_upgrade_record_halt transaction
        return "${stage_status}"
    }
    v010_v020_upgrade_post_status_disabled || {
        stage_status=$?
        existing_notifier_v010_v020_upgrade_record_halt post-status-disabled
        return "${stage_status}"
    }
    upgrade_complete=true
    v010_v020_upgrade_action_required_smtp
)

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    existing_notifier_v010_v020_upgrade "$@"
fi
