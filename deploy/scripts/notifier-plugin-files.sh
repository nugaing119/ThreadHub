#!/usr/bin/env bash

# Shared filesystem helpers for the notifier plugin runtime tree and the
# Mattermost filestore bundle. Callers source common.sh first so SUDO_COMMAND
# is an initialized command array.

notifier_plugin_cleanup_scratch_root() {
    local scratch_root="${1:-}"

    [[ "$#" -eq 1 && "${scratch_root}" == /* && "${scratch_root}" != / \
        && "${scratch_root}" != *$'\n'* && "${scratch_root}" != *$'\r'* ]] || return 2
    rm -rf -- "${scratch_root}" >/dev/null 2>&1 && return 0
    "${SUDO_COMMAND[@]}" rm -rf -- "${scratch_root}" >/dev/null 2>&1
}

notifier_plugin_privileged_sha256() {
    local path="$1"

    if command -v sha256sum >/dev/null 2>&1; then
        "${SUDO_COMMAND[@]}" sha256sum "${path}" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        "${SUDO_COMMAND[@]}" shasum -a 256 "${path}" | awk '{print $1}'
    elif command -v openssl >/dev/null 2>&1; then
        "${SUDO_COMMAND[@]}" openssl dgst -sha256 "${path}" | awk '{print $NF}'
    else
        return 1
    fi
}

notifier_plugin_bundle_is_exact() {
    local bundle_path="$1"
    local expected_sha="$2"
    local identity
    local actual_sha

    [[ "${expected_sha}" =~ ^[a-f0-9]{64}$ ]] || return 1
    "${SUDO_COMMAND[@]}" test -f "${bundle_path}" || return 1
    "${SUDO_COMMAND[@]}" test ! -L "${bundle_path}" || return 1
    identity="$("${SUDO_COMMAND[@]}" stat -c '%u:%g:%a' "${bundle_path}")" || return 1
    [[ "${identity}" == 2000:2000:640 ]] || return 1
    actual_sha="$(notifier_plugin_privileged_sha256 "${bundle_path}")" || return 1
    [[ "${actual_sha}" == "${expected_sha}" ]]
}

notifier_plugin_pair_presence() {
    local runtime_root="$1"
    local bundle_path="$2"
    local runtime_present=false
    local bundle_present=false

    if "${SUDO_COMMAND[@]}" test -e "${runtime_root}" \
        || "${SUDO_COMMAND[@]}" test -L "${runtime_root}"; then
        runtime_present=true
    fi
    if "${SUDO_COMMAND[@]}" test -e "${bundle_path}" \
        || "${SUDO_COMMAND[@]}" test -L "${bundle_path}"; then
        bundle_present=true
    fi
    if [[ "${runtime_present}" != "${bundle_present}" ]]; then
        return 1
    fi
    if [[ "${runtime_present}" == true ]]; then
        printf 'present\n'
    else
        printf 'absent\n'
    fi
}

notifier_plugin_tree_is_exact() (
    set -Eeuo pipefail

    [[ "$#" -eq 3 ]] || return 2
    root="$1"
    reviewed_root="$2"
    scratch_root="$3"

    "${SUDO_COMMAND[@]}" test -d "${root}" || return 1
    "${SUDO_COMMAND[@]}" test ! -L "${root}" || return 1
    [[ -d "${reviewed_root}" && ! -L "${reviewed_root}" ]] || return 1
    [[ -d "${scratch_root}" && ! -L "${scratch_root}" ]] || return 1
    entry_count="$("${SUDO_COMMAND[@]}" find "${root}" -mindepth 1 -print \
        | wc -l | tr -d '[:space:]')" || return 1
    [[ "${entry_count}" == 4 ]] || return 1
    for directory in "${root}/server" "${root}/server/dist"; do
        "${SUDO_COMMAND[@]}" test -d "${directory}" || return 1
        "${SUDO_COMMAND[@]}" test ! -L "${directory}" || return 1
    done
    for regular_file in \
        "${root}/plugin.json" \
        "${root}/server/dist/plugin-linux-amd64"; do
        "${SUDO_COMMAND[@]}" test -f "${regular_file}" || return 1
        "${SUDO_COMMAND[@]}" test ! -L "${regular_file}" || return 1
    done
    "${SUDO_COMMAND[@]}" cmp -s \
        "${reviewed_root}/plugin.json" "${root}/plugin.json" || return 1
    "${SUDO_COMMAND[@]}" cmp -s \
        "${reviewed_root}/server/dist/plugin-linux-amd64" \
        "${root}/server/dist/plugin-linux-amd64" || return 1

    for expected in \
        "${root}|2000:2000:744" \
        "${root}/server|2000:2000:744" \
        "${root}/server/dist|2000:2000:744" \
        "${root}/plugin.json|2000:2000:644" \
        "${root}/server/dist/plugin-linux-amd64|2000:2000:755"; do
        path="${expected%%|*}"
        identity="$("${SUDO_COMMAND[@]}" stat -c '%u:%g:%a' "${path}")" || return 1
        [[ "${identity}" == "${expected#*|}" ]] || return 1
    done
)

notifier_plugin_pair_is_exact() {
    local runtime_root="$1"
    local bundle_path="$2"
    local reviewed_root="$3"
    local expected_sha="$4"
    local scratch_root="$5"
    local presence

    presence="$(notifier_plugin_pair_presence "${runtime_root}" "${bundle_path}")" \
        || return 1
    [[ "${presence}" == present ]] || return 1
    notifier_plugin_bundle_is_exact "${bundle_path}" "${expected_sha}" \
        && notifier_plugin_tree_is_exact \
            "${runtime_root}" "${reviewed_root}" "${scratch_root}"
}

notifier_plugin_capture_pair() (
    set -Eeuo pipefail

    [[ "$#" -eq 5 ]] || return 2
    runtime_root="$1"
    bundle_path="$2"
    plugin_id="$3"
    extraction_dir="$4"
    scratch_root="$5"
    inspection_dir=""
    capture_complete=false

    # shellcheck disable=SC2329 # invoked by the EXIT/signal trap below
    cleanup_pair_capture() {
        local original_status=$?

        trap - EXIT HUP INT TERM
        if [[ -n "${inspection_dir}" ]]; then
            "${SUDO_COMMAND[@]}" rm -rf -- "${inspection_dir}" >/dev/null 2>&1 || true
        fi
        if [[ "${capture_complete}" != true ]]; then
            "${SUDO_COMMAND[@]}" rm -rf -- "${extraction_dir}" >/dev/null 2>&1 || true
        fi
        exit "${original_status}"
    }
    trap cleanup_pair_capture EXIT HUP INT TERM

    [[ "${plugin_id}" == com.threadhub.channel-email-notifier ]] || return 1
    [[ -d "${scratch_root}" && ! -L "${scratch_root}" ]] || return 1
    if "${SUDO_COMMAND[@]}" test -e "${extraction_dir}" \
        || "${SUDO_COMMAND[@]}" test -L "${extraction_dir}"; then
        return 1
    fi
    [[ "$(notifier_plugin_pair_presence "${runtime_root}" "${bundle_path}")" == present ]] \
        || return 1

    inspection_dir="$(mktemp -d "${scratch_root}/.plugin-pair.XXXXXX")" || return 1
    chmod 0700 "${inspection_dir}"
    source_sha="$(notifier_plugin_privileged_sha256 "${bundle_path}")" || return 1
    [[ "${source_sha}" =~ ^[a-f0-9]{64}$ ]] || return 1
    notifier_plugin_bundle_is_exact "${bundle_path}" "${source_sha}" || return 1
    "${SUDO_COMMAND[@]}" install -m 0600 \
        "${bundle_path}" "${inspection_dir}/bundle.tar.gz"
    snapshot_sha="$(notifier_plugin_privileged_sha256 \
        "${inspection_dir}/bundle.tar.gz")" || return 1
    [[ "${snapshot_sha}" == "${source_sha}" ]] || return 1
    [[ "$(notifier_plugin_privileged_sha256 "${bundle_path}")" == "${source_sha}" ]] \
        || return 1

    "${SUDO_COMMAND[@]}" tar -tzf "${inspection_dir}/bundle.tar.gz" \
        > "${inspection_dir}/entries"
    printf '%s\n' \
        "${plugin_id}/" \
        "${plugin_id}/plugin.json" \
        "${plugin_id}/server/" \
        "${plugin_id}/server/dist/" \
        "${plugin_id}/server/dist/plugin-linux-amd64" \
        > "${inspection_dir}/expected-entries"
    LC_ALL=C sort "${inspection_dir}/entries" > "${inspection_dir}/entries.sorted"
    LC_ALL=C sort "${inspection_dir}/expected-entries" \
        > "${inspection_dir}/expected-entries.sorted"
    cmp -s "${inspection_dir}/entries.sorted" \
        "${inspection_dir}/expected-entries.sorted" \
        || return 1
    "${SUDO_COMMAND[@]}" tar -tvzf "${inspection_dir}/bundle.tar.gz" \
        > "${inspection_dir}/verbose-entries"
    awk '{ type = substr($1, 1, 1); if (type != "-" && type != "d") exit 1 }' \
        "${inspection_dir}/verbose-entries" || return 1

    mkdir -m 0700 "${extraction_dir}"
    # The review tree is root-owned when privilege is required, but the
    # unprivileged caller must still be able to traverse and compare it.
    # Normalize the extraction umask so a caller-wide umask 077 cannot turn
    # the reviewed directories into inaccessible mode 0700 objects.
    (
        umask 022
        "${SUDO_COMMAND[@]}" tar --extract --gzip \
            --file "${inspection_dir}/bundle.tar.gz" \
            --directory "${extraction_dir}" \
            --no-same-owner --no-same-permissions
    )
    reviewed_root="${extraction_dir}/${plugin_id}"
    manifest="${reviewed_root}/plugin.json"
    # shellcheck disable=SC2016 # jq variables are intentionally expanded by jq.
    "${SUDO_COMMAND[@]}" jq -e --arg id "${plugin_id}" '
        type == "object" and
        (keys == ["description", "homepage_url", "id", "min_server_version", "name", "server", "support_url", "version"]) and
        .id == $id and .min_server_version == "11.7.7" and
        (.version | type == "string" and test("^[0-9]+\\.[0-9]+\\.[0-9]+$")) and
        (.server | type == "object" and keys == ["executables"]) and
        (.server.executables | type == "object" and keys == ["linux-amd64"]) and
        .server.executables["linux-amd64"] == "server/dist/plugin-linux-amd64"
    ' "${manifest}" >/dev/null || return 1
    version="$("${SUDO_COMMAND[@]}" jq -er '.version' "${manifest}")" || return 1

    notifier_plugin_pair_is_exact \
        "${runtime_root}" "${bundle_path}" "${reviewed_root}" \
        "${source_sha}" "${scratch_root}" || return 1
    [[ "$(notifier_plugin_privileged_sha256 "${bundle_path}")" == "${source_sha}" ]] \
        || return 1
    capture_complete=true
    printf '%s\t%s\n' "${version}" "${source_sha}"
)

notifier_plugin_stage_pair() (
    set -Eeuo pipefail

    [[ "$#" -eq 6 ]] || return 2
    reviewed_bundle="$1"
    reviewed_root="$2"
    runtime_stage="$3"
    bundle_stage="$4"
    expected_sha="$5"
    scratch_root="$6"
    stage_started=false
    stage_complete=false

    # shellcheck disable=SC2329 # invoked by the EXIT/signal trap below
    cleanup_partial_stage() {
        local original_status=$?

        trap - EXIT HUP INT TERM
        if [[ "${stage_started}" == true && "${stage_complete}" != true ]]; then
            "${SUDO_COMMAND[@]}" rm -rf -- "${runtime_stage}" >/dev/null 2>&1 || true
            "${SUDO_COMMAND[@]}" rm -f -- "${bundle_stage}" >/dev/null 2>&1 || true
        fi
        exit "${original_status}"
    }
    trap cleanup_partial_stage EXIT HUP INT TERM

    [[ "${expected_sha}" =~ ^[a-f0-9]{64}$ ]] || return 1
    [[ -f "${reviewed_bundle}" && ! -L "${reviewed_bundle}" ]] || return 1
    [[ -d "${reviewed_root}" && ! -L "${reviewed_root}" ]] || return 1
    [[ -d "${scratch_root}" && ! -L "${scratch_root}" ]] || return 1
    [[ "$(notifier_plugin_privileged_sha256 "${reviewed_bundle}")" == "${expected_sha}" ]] \
        || return 1
    for path in "${runtime_stage}" "${bundle_stage}"; do
        if "${SUDO_COMMAND[@]}" test -e "${path}" \
            || "${SUDO_COMMAND[@]}" test -L "${path}"; then
            return 1
        fi
    done

    stage_started=true
    # Mattermost 11.7.7 canonicalizes an installed runtime tree to these
    # non-writable group/other modes when synchronizing the filestore bundle.
    "${SUDO_COMMAND[@]}" install -d -o 2000 -g 2000 -m 0744 \
        "${runtime_stage}" \
        "${runtime_stage}/server" \
        "${runtime_stage}/server/dist"
    "${SUDO_COMMAND[@]}" install -o 2000 -g 2000 -m 0644 \
        "${reviewed_root}/plugin.json" "${runtime_stage}/plugin.json"
    "${SUDO_COMMAND[@]}" install -o 2000 -g 2000 -m 0755 \
        "${reviewed_root}/server/dist/plugin-linux-amd64" \
        "${runtime_stage}/server/dist/plugin-linux-amd64"
    "${SUDO_COMMAND[@]}" install -o 2000 -g 2000 -m 0640 \
        "${reviewed_bundle}" "${bundle_stage}"
    notifier_plugin_tree_is_exact "${runtime_stage}" "${reviewed_root}" "${scratch_root}"
    notifier_plugin_bundle_is_exact "${bundle_stage}" "${expected_sha}"
    stage_complete=true
)

notifier_plugin_preserve_pair() {
    local runtime_root="$1"
    local bundle_path="$2"
    local evidence_root="$3"
    local evidence_bundle="$4"
    local reviewed_root="$5"
    local expected_sha="$6"
    local scratch_root="$7"
    local evidence_presence

    notifier_plugin_pair_is_exact \
        "${runtime_root}" "${bundle_path}" "${reviewed_root}" \
        "${expected_sha}" "${scratch_root}" || return 1
    evidence_presence="$(notifier_plugin_pair_presence \
        "${evidence_root}" "${evidence_bundle}")" || return 1
    if [[ "${evidence_presence}" == absent ]]; then
        notifier_plugin_stage_pair \
            "${bundle_path}" "${reviewed_root}" \
            "${evidence_root}" "${evidence_bundle}" \
            "${expected_sha}" "${scratch_root}" || return 1
    fi
    notifier_plugin_pair_is_exact \
        "${evidence_root}" "${evidence_bundle}" "${reviewed_root}" \
        "${expected_sha}" "${scratch_root}"
}

notifier_plugin_move_no_clobber() {
    local source_path="$1"
    local destination_path="$2"

    { "${SUDO_COMMAND[@]}" test -e "${source_path}" \
        || "${SUDO_COMMAND[@]}" test -L "${source_path}"; } || return 1
    "${SUDO_COMMAND[@]}" test ! -L "${source_path}" || return 1
    if "${SUDO_COMMAND[@]}" test -e "${destination_path}" \
        || "${SUDO_COMMAND[@]}" test -L "${destination_path}"; then
        return 1
    fi
    "${SUDO_COMMAND[@]}" mv -T -n -- "${source_path}" "${destination_path}" \
        || return 1
    ! "${SUDO_COMMAND[@]}" test -e "${source_path}" \
        && ! "${SUDO_COMMAND[@]}" test -L "${source_path}" \
        && "${SUDO_COMMAND[@]}" test -e "${destination_path}" \
        && "${SUDO_COMMAND[@]}" test ! -L "${destination_path}"
}
