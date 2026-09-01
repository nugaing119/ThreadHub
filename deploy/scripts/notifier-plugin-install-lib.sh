#!/usr/bin/env bash

# Trap callbacks and transaction hooks are invoked indirectly by name.
# shellcheck disable=SC2329

# Shared high-level notifier plugin installation. Callers source common.sh,
# notifier-lib.sh, notifier-plugin-files.sh, and notifier-plugin-transaction.sh
# before this library.

notifier_install_directory_identity_is() {
    local path="$1"
    local expected="$2"
    local identity

    "${SUDO_COMMAND[@]}" test -d "${path}" || return 1
    "${SUDO_COMMAND[@]}" test ! -L "${path}" || return 1
    identity="$("${SUDO_COMMAND[@]}" stat -c '%u:%g:%a' "${path}")" || return 1
    [[ "${identity}" == "${expected}" ]]
}

notifier_install_clean_absolute_path() {
    local path="$1"

    [[ "${path}" == /* && "${path}" != / && "${path}" != *'//'* \
        && "${path}" != */./* && "${path}" != */../* \
        && "${path}" != */. && "${path}" != */.. && "${path}" != */ ]]
}

notifier_install_reviewed_pair() (
    set -Eeuo pipefail

    [[ "$#" -eq 5 ]] || return 2
    release_dir="$1"
    plugins_root="$2"
    filestore_plugins_root="$3"
    compose_function="$4"
    mattermost_service="$5"
    plugin_id=com.threadhub.channel-email-notifier
    notifier_runtime_root="$(dirname "${release_dir}")"
    control_dir="${notifier_runtime_root}/control"
    state_file="${control_dir}/state.json"
    release_file="${release_dir}/release.env"
    tmp_dir="$(mktemp -d)"

    cleanup_notifier_install() {
        local original_status=$?
        trap - EXIT HUP INT TERM
        "${SUDO_COMMAND[@]}" rm -rf -- "${tmp_dir}" >/dev/null 2>&1 || true
        exit "${original_status}"
    }
    trap cleanup_notifier_install EXIT HUP INT TERM

    for path in "${release_dir}" "${plugins_root}" "${filestore_plugins_root}"; do
        notifier_install_clean_absolute_path "${path}" \
            || die "Notifier installation path is not a clean absolute path"
    done
    if [[ ! "${compose_function}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] \
        || ! declare -F "${compose_function}" >/dev/null; then
        die "Notifier Compose function is invalid"
    fi
    [[ "${mattermost_service}" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] \
        || die "Notifier Mattermost service is invalid"
    notifier_install_directory_identity_is "${release_dir}" 0:0:750 \
        || die "Notifier release directory must be root:root with mode 0750"
    notifier_install_directory_identity_is "${control_dir}" 0:3000:750 \
        || die "Notifier control directory must be root:3000 with mode 0750"
    notifier_install_directory_identity_is "${plugins_root}" 2000:2000:750 \
        || die "Mattermost plugin directory must be 2000:2000 with mode 0750"
    notifier_install_directory_identity_is "${filestore_plugins_root}" 2000:2000:750 \
        || die "Mattermost filestore plugin directory must be 2000:2000 with mode 0750"
    "${SUDO_COMMAND[@]}" test ! -L "${state_file}" \
        || die "Refusing symbolic-link notifier control state"
    "${SUDO_COMMAND[@]}" test -f "${release_file}" \
        || die "Notifier release identity is missing"
    "${SUDO_COMMAND[@]}" test ! -L "${release_file}" \
        || die "Refusing symbolic-link notifier release identity"
    "${SUDO_COMMAND[@]}" cat "${release_file}" > "${tmp_dir}/release.env"
    chmod 0600 "${tmp_dir}/release.env"

    release_value() {
        local key="$1"
        local value

        value="$(awk -F= -v key="${key}" '$1 == key { count++; value = substr($0, index($0, "=") + 1) } END { if (count != 1 || value == "") exit 1; print value }' "${tmp_dir}/release.env")" \
            || die "Notifier release identity has a missing or duplicate field"
        printf '%s' "${value}"
    }

    line_count="$(wc -l < "${tmp_dir}/release.env" | tr -d '[:space:]')"
    [[ "${line_count}" == 7 ]] \
        || die "Notifier release identity must contain exactly seven fields"
    while IFS='=' read -r key value; do
        case "${key}" in
            NOTIFIER_VERSION|NOTIFIER_PLUGIN_ID|NOTIFIER_PLUGIN_BUNDLE|NOTIFIER_PLUGIN_BUNDLE_SHA256|NOTIFIER_MAILER_IMAGE|NOTIFIER_MAILER_IMAGE_ID|NOTIFIER_SOURCE_COMMIT) ;;
            *) die "Notifier release identity contains an unknown field" ;;
        esac
        [[ -n "${value}" && "${value}" != *$'\r'* && "${value}" != *$'\n'* ]] \
            || die "Notifier release identity contains an invalid value"
    done < "${tmp_dir}/release.env"

    notifier_version="$(release_value NOTIFIER_VERSION)"
    release_plugin_id="$(release_value NOTIFIER_PLUGIN_ID)"
    bundle_relative="$(release_value NOTIFIER_PLUGIN_BUNDLE)"
    bundle_sha256="$(release_value NOTIFIER_PLUGIN_BUNDLE_SHA256)"
    mailer_image="$(release_value NOTIFIER_MAILER_IMAGE)"
    mailer_image_id="$(release_value NOTIFIER_MAILER_IMAGE_ID)"
    source_commit="$(release_value NOTIFIER_SOURCE_COMMIT)"

    [[ "${notifier_version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
        || die "Invalid notifier release version"
    [[ "${release_plugin_id}" == "${plugin_id}" ]] || die "Invalid notifier plugin ID"
    [[ "${bundle_relative}" == "notifier/dist/${plugin_id}-${notifier_version}.tar.gz" ]] \
        || die "Invalid notifier bundle path"
    [[ "${bundle_sha256}" =~ ^[a-f0-9]{64}$ ]] || die "Invalid notifier bundle hash"
    [[ "${mailer_image}" == "threadhub/notifier-mailer:${notifier_version}" ]] \
        || die "Invalid notifier Mailer image reference"
    [[ "${mailer_image_id}" =~ ^sha256:[a-f0-9]{64}$ ]] \
        || die "Invalid notifier Mailer image ID"
    [[ "${source_commit}" =~ ^[a-f0-9]{40,64}$ ]] || die "Invalid notifier source commit"
    [[ "$(git -C "${REPOSITORY_ROOT}" rev-parse --verify 'HEAD^{commit}')" == "${source_commit}" ]] \
        || die "Release identity does not match the checked-out source commit"

    bundle_path="${REPOSITORY_ROOT}/${bundle_relative}"
    [[ ! -L "${REPOSITORY_ROOT}/notifier/dist" && ! -L "${bundle_path}" ]] \
        || die "Refusing symbolic-link notifier artifact path"
    require_file "${bundle_path}"
    [[ "$(sha256_file "${bundle_path}")" == "${bundle_sha256}" ]] \
        || die "Notifier bundle SHA-256 does not match the release identity"
    [[ "$("${DOCKER_COMMAND[@]}" image inspect --format '{{.Id}}' "${mailer_image}")" == "${mailer_image_id}" ]] \
        || die "Notifier Mailer image ID does not match the release identity"

    tar -tzf "${bundle_path}" > "${tmp_dir}/entries"
    printf '%s\n' \
        "${plugin_id}/" \
        "${plugin_id}/plugin.json" \
        "${plugin_id}/server/" \
        "${plugin_id}/server/dist/" \
        "${plugin_id}/server/dist/plugin-linux-amd64" \
        > "${tmp_dir}/expected-entries"
    LC_ALL=C sort "${tmp_dir}/entries" > "${tmp_dir}/entries.sorted"
    LC_ALL=C sort "${tmp_dir}/expected-entries" > "${tmp_dir}/expected-entries.sorted"
    cmp -s "${tmp_dir}/entries.sorted" "${tmp_dir}/expected-entries.sorted" \
        || die "Notifier bundle contains unexpected paths"
    tar -tvzf "${bundle_path}" > "${tmp_dir}/verbose-entries"
    awk '{ type = substr($1, 1, 1); if (type != "-" && type != "d") exit 1 }' \
        "${tmp_dir}/verbose-entries" || die "Notifier bundle contains a non-regular archive type"

    mkdir -m 0700 "${tmp_dir}/extracted"
    tar --extract --gzip --file "${bundle_path}" \
        --directory "${tmp_dir}/extracted" --no-same-owner --no-same-permissions
    extracted_root="${tmp_dir}/extracted/${plugin_id}"
    manifest="${extracted_root}/plugin.json"
    executable="${extracted_root}/server/dist/plugin-linux-amd64"
    [[ -d "${extracted_root}" && ! -L "${extracted_root}" ]] \
        || die "Notifier bundle root is invalid"
    [[ -f "${manifest}" && ! -L "${manifest}" ]] || die "Notifier manifest is invalid"
    [[ -f "${executable}" && ! -L "${executable}" ]] \
        || die "Notifier server executable is invalid"
    jq -e --arg id "${plugin_id}" --arg version "${notifier_version}" '
        type == "object" and
        (keys == ["description", "homepage_url", "id", "min_server_version", "name", "server", "support_url", "version"]) and
        .id == $id and .version == $version and .min_server_version == "11.7.7" and
        (.server | keys == ["executables"]) and
        (.server.executables | keys == ["linux-amd64"]) and
        .server.executables["linux-amd64"] == "server/dist/plugin-linux-amd64"
    ' "${manifest}" >/dev/null || die "Notifier manifest does not match the reviewed release"

    target_root="${plugins_root}/${plugin_id}"
    bundle_target="${filestore_plugins_root}/${plugin_id}.tar.gz"
    for path in "${target_root}" "${bundle_target}"; do
        "${SUDO_COMMAND[@]}" test ! -L "${path}" \
            || die "Refusing symbolic-link notifier plugin production object"
    done
    if "${SUDO_COMMAND[@]}" test -e "${target_root}" \
        && ! "${SUDO_COMMAND[@]}" test -d "${target_root}"; then
        die "Refusing non-directory notifier plugin target"
    fi
    if "${SUDO_COMMAND[@]}" test -e "${bundle_target}" \
        && ! "${SUDO_COMMAND[@]}" test -f "${bundle_target}"; then
        die "Refusing non-regular notifier filestore bundle"
    fi

    previous_pair_presence="$(notifier_plugin_pair_presence "${target_root}" "${bundle_target}")" \
        || die "Notifier runtime and filestore objects must both exist or both be absent"
    previous_pair_present=false
    previous_plugin_version=""
    previous_bundle_sha=""
    previous_reviewed_root=""
    if [[ "${previous_pair_presence}" == present ]]; then
        previous_pair_present=true
        previous_capture_dir="${tmp_dir}/previous-pair"
        previous_metadata="$(notifier_plugin_capture_pair \
            "${target_root}" "${bundle_target}" "${plugin_id}" \
            "${previous_capture_dir}" "${tmp_dir}")" \
            || die "Existing notifier runtime and filestore pair is unsafe or incoherent"
        metadata_extra=""
        IFS=$'\t' read -r previous_plugin_version previous_bundle_sha metadata_extra \
            <<< "${previous_metadata}"
        [[ "${previous_plugin_version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ \
            && "${previous_bundle_sha}" =~ ^[a-f0-9]{64}$ \
            && -z "${metadata_extra}" ]] \
            || die "Existing notifier pair returned invalid verified metadata"
        previous_reviewed_root="${previous_capture_dir}/${plugin_id}"
    fi

    mattermost_id="$("${compose_function}" ps -q "${mattermost_service}")"
    was_running=false
    [[ -z "${mattermost_id}" ]] || was_running=true

    plugin_list_json() {
        "${compose_function}" exec -T "${mattermost_service}" \
            mmctl plugin list --local --suppress-warnings --json
    }

    enable_plugin_version() {
        local expected_version="$1"
        local state_file_path="$2"
        local state

        [[ "${expected_version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
        plugin_list_json > "${state_file_path}" || return 1
        if notifier_plugin_list_is_exact_active \
            "${state_file_path}" "${plugin_id}" "${expected_version}"; then
            return 0
        fi
        state="$(notifier_plugin_list_target_state \
            "${state_file_path}" "${plugin_id}")" || return 1
        [[ "${state}" == $'inactive\t'"${expected_version}" ]] || return 1
        "${compose_function}" exec -T "${mattermost_service}" \
            mmctl plugin enable "${plugin_id}" --local --suppress-warnings >/dev/null
    }

    enable_expected_plugin() {
        enable_plugin_version "${notifier_version}" "${tmp_dir}/plugin-list-enable.json"
    }

    ensure_plugin_active() {
        "${compose_function}" up -d --no-deps --wait --wait-timeout 240 \
            "${mattermost_service}" || return 1
        enable_expected_plugin || return 1
        plugin_list_json > "${tmp_dir}/plugin-list.json" || return 1
        notifier_plugin_list_is_exact_active \
            "${tmp_dir}/plugin-list.json" "${plugin_id}" "${notifier_version}" \
            || return 1
        notifier_plugin_pair_is_exact \
            "${target_root}" "${bundle_target}" "${extracted_root}" \
            "${bundle_sha256}" "${tmp_dir}"
    }

    notifier_write_control_state "${state_file}" false false all_channels '' 0 \
        || die "Notifier control could not be disabled"
    if notifier_plugin_tree_is_exact "${target_root}" "${extracted_root}" "${tmp_dir}" \
        && notifier_plugin_bundle_is_exact "${bundle_target}" "${bundle_sha256}"; then
        ensure_plugin_active || die "Exact notifier plugin ID and version could not be activated"
        log "Exact notifier plugin bundle is already installed and active"
        return 0
    fi

    plugin_was_active=false
    previous_plugin_state=$'missing\t-'
    if [[ "${was_running}" == true ]]; then
        plugin_list_json > "${tmp_dir}/plugin-list-before.json" \
            || die "Mattermost plugin state could not be read"
        previous_plugin_state="$(notifier_plugin_list_target_state \
            "${tmp_dir}/plugin-list-before.json" "${plugin_id}")" \
            || die "Mattermost returned ambiguous notifier plugin state"
        if [[ "${previous_pair_present}" == true ]]; then
            case "${previous_plugin_state}" in
                $'active\t'"${previous_plugin_version}") plugin_was_active=true ;;
                $'inactive\t'"${previous_plugin_version}") ;;
                *) die "Mattermost plugin state does not match the verified notifier pair" ;;
            esac
        elif [[ "${previous_plugin_state}" != $'missing\t-' ]]; then
            die "Mattermost reports notifier state without a production plugin pair"
        fi
    fi

    transaction_suffix="$(date -u +%Y%m%dT%H%M%SZ)-$$"
    stage_root="${release_dir}/.${plugin_id}.runtime.stage.$$"
    bundle_stage="${release_dir}/.${plugin_id}.bundle.stage.$$.tar.gz"
    backup_dir="${release_dir}/plugin-backups"
    backup_root="${backup_dir}/${plugin_id}-runtime-${transaction_suffix}"
    failed_root="${backup_dir}/${plugin_id}-runtime-failed-${transaction_suffix}"
    bundle_backup="${backup_dir}/${plugin_id}-bundle-${transaction_suffix}.tar.gz"
    bundle_failed="${backup_dir}/${plugin_id}-bundle-failed-${transaction_suffix}.tar.gz"
    for path in \
        "${backup_dir}" "${stage_root}" "${bundle_stage}" \
        "${backup_root}" "${failed_root}" "${bundle_backup}" "${bundle_failed}"; do
        "${SUDO_COMMAND[@]}" test ! -L "${path}" \
            || die "Refusing symbolic-link notifier plugin staging or backup path"
    done
    for path in \
        "${stage_root}" "${bundle_stage}" \
        "${backup_root}" "${failed_root}" "${bundle_backup}" "${bundle_failed}"; do
        "${SUDO_COMMAND[@]}" test ! -e "${path}" \
            || die "Refusing existing notifier plugin staging or backup path"
    done
    if "${SUDO_COMMAND[@]}" test -e "${backup_dir}" \
        && ! "${SUDO_COMMAND[@]}" test -d "${backup_dir}"; then
        die "Refusing non-directory notifier plugin backup path"
    fi

    plugins_device="$("${SUDO_COMMAND[@]}" stat -c '%d' "${plugins_root}")"
    filestore_device="$("${SUDO_COMMAND[@]}" stat -c '%d' "${filestore_plugins_root}")"
    release_device="$("${SUDO_COMMAND[@]}" stat -c '%d' "${release_dir}")"
    [[ "${plugins_device}" =~ ^[0-9]+$ \
        && "${filestore_device}" =~ ^[0-9]+$ \
        && "${release_device}" =~ ^[0-9]+$ \
        && "${plugins_device}" == "${release_device}" \
        && "${filestore_device}" == "${release_device}" ]] \
        || die "Notifier runtime, filestore and staging paths must share one filesystem"

    "${SUDO_COMMAND[@]}" install -d -o root -g root -m 0750 "${backup_dir}"
    notifier_plugin_stage_pair \
        "${bundle_path}" "${extracted_root}" "${stage_root}" "${bundle_stage}" \
        "${bundle_sha256}" "${tmp_dir}" \
        || die "Notifier runtime and filestore stages could not be materialized exactly"

    plugin_tx_disable_control() {
        notifier_write_control_state "${state_file}" false false all_channels '' 0
    }
    plugin_tx_disable_plugin() {
        "${compose_function}" exec -T "${mattermost_service}" \
            mmctl plugin disable "${plugin_id}" --local --suppress-warnings >/dev/null
    }
    plugin_tx_stop_service() {
        "${compose_function}" stop "${mattermost_service}" >/dev/null
    }
    plugin_tx_prepare_targets() {
        local path identity current_presence

        notifier_install_directory_identity_is "${release_dir}" 0:0:750 || return 1
        notifier_install_directory_identity_is "${plugins_root}" 2000:2000:750 || return 1
        notifier_install_directory_identity_is "${filestore_plugins_root}" 2000:2000:750 || return 1
        identity="$("${SUDO_COMMAND[@]}" stat -c '%u:%g:%a' "${backup_dir}")" || return 1
        [[ "${identity}" == 0:0:750 ]] || return 1
        notifier_plugin_tree_is_exact "${stage_root}" "${extracted_root}" "${tmp_dir}" || return 1
        notifier_plugin_bundle_is_exact "${bundle_stage}" "${bundle_sha256}" || return 1
        for path in \
            "${target_root}" "${bundle_target}" "${stage_root}" "${bundle_stage}" \
            "${backup_root}" "${failed_root}" "${bundle_backup}" "${bundle_failed}"; do
            "${SUDO_COMMAND[@]}" test ! -L "${path}" || return 1
        done
        current_presence="$(notifier_plugin_pair_presence \
            "${target_root}" "${bundle_target}")" || return 1
        [[ "${current_presence}" == "${previous_pair_presence}" ]] || return 1
        if [[ "${previous_pair_present}" == true ]]; then
            notifier_plugin_pair_is_exact \
                "${target_root}" "${bundle_target}" "${previous_reviewed_root}" \
                "${previous_bundle_sha}" "${tmp_dir}" || return 1
        fi
        for path in "${backup_root}" "${failed_root}" "${bundle_backup}" "${bundle_failed}"; do
            "${SUDO_COMMAND[@]}" test ! -e "${path}" || return 1
        done
    }
    plugin_tx_start_service() {
        "${compose_function}" up -d --no-deps --wait --wait-timeout 240 \
            "${mattermost_service}" >/dev/null
    }
    plugin_tx_enable_plugin() { enable_expected_plugin; }
    plugin_tx_enable_previous_plugin() {
        [[ "${previous_pair_present}" == true && "${plugin_was_active}" == true ]] || return 1
        enable_plugin_version \
            "${previous_plugin_version}" "${tmp_dir}/plugin-list-rollback-enable.json"
    }
    plugin_tx_verify_plugin() {
        notifier_plugin_pair_is_exact \
            "${target_root}" "${bundle_target}" "${extracted_root}" \
            "${bundle_sha256}" "${tmp_dir}" \
            && plugin_list_json > "${tmp_dir}/plugin-list-transaction.json" \
            && notifier_plugin_list_is_exact_active \
                "${tmp_dir}/plugin-list-transaction.json" "${plugin_id}" "${notifier_version}"
    }
    plugin_tx_verify_previous_objects() {
        local current_presence evidence_presence
        current_presence="$(notifier_plugin_pair_presence \
            "${target_root}" "${bundle_target}")" || return 1
        [[ "${current_presence}" == "${previous_pair_presence}" ]] || return 1
        if [[ "${previous_pair_present}" == true ]]; then
            notifier_plugin_preserve_pair \
                "${target_root}" "${bundle_target}" "${backup_root}" "${bundle_backup}" \
                "${previous_reviewed_root}" "${previous_bundle_sha}" "${tmp_dir}"
        else
            evidence_presence="$(notifier_plugin_pair_presence \
                "${backup_root}" "${bundle_backup}")" || return 1
            [[ "${evidence_presence}" == absent ]]
        fi
    }
    plugin_tx_verify_previous_plugin() {
        local state
        plugin_list_json > "${tmp_dir}/plugin-list-rollback.json" || return 1
        state="$(notifier_plugin_list_target_state \
            "${tmp_dir}/plugin-list-rollback.json" "${plugin_id}")" || return 1
        if [[ "${previous_pair_present}" != true ]]; then
            [[ "${state}" == $'missing\t-' ]]
        elif [[ "${plugin_was_active}" == true ]]; then
            [[ "${state}" == $'active\t'"${previous_plugin_version}" ]]
        else
            [[ "${state}" == $'inactive\t'"${previous_plugin_version}" ]]
        fi
    }
    plugin_tx_path_exists() {
        "${SUDO_COMMAND[@]}" test -e "$1" || "${SUDO_COMMAND[@]}" test -L "$1"
    }
    plugin_tx_move() { notifier_plugin_move_no_clobber "$1" "$2"; }

    set +e
    notifier_plugin_transaction \
        "${target_root}" "${stage_root}" "${backup_root}" "${failed_root}" \
        "${bundle_target}" "${bundle_stage}" "${bundle_backup}" "${bundle_failed}" \
        "${was_running}" "${plugin_was_active}"
    transaction_result=$?
    set -e
    ((transaction_result == 0)) \
        || die "Notifier plugin replacement transaction failed; review the rollback result above"

    log "Notifier plugin ${plugin_id} ${notifier_version} is installed and active; runtime delivery remains controlled by state.json"
)
