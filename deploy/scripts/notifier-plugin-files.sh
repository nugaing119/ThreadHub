#!/usr/bin/env bash

# Shared filesystem helpers for the notifier plugin runtime tree and the
# Mattermost filestore bundle. Callers source common.sh first so SUDO_COMMAND
# is an initialized command array.

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
        "${root}|2000:2000:750" \
        "${root}/server|2000:2000:750" \
        "${root}/server/dist|2000:2000:750" \
        "${root}/plugin.json|2000:2000:640" \
        "${root}/server/dist/plugin-linux-amd64|2000:2000:750"; do
        path="${expected%%|*}"
        identity="$("${SUDO_COMMAND[@]}" stat -c '%u:%g:%a' "${path}")" || return 1
        [[ "${identity}" == "${expected#*|}" ]] || return 1
    done
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
    "${SUDO_COMMAND[@]}" install -d -o 2000 -g 2000 -m 0750 \
        "${runtime_stage}" \
        "${runtime_stage}/server" \
        "${runtime_stage}/server/dist"
    "${SUDO_COMMAND[@]}" install -o 2000 -g 2000 -m 0640 \
        "${reviewed_root}/plugin.json" "${runtime_stage}/plugin.json"
    "${SUDO_COMMAND[@]}" install -o 2000 -g 2000 -m 0750 \
        "${reviewed_root}/server/dist/plugin-linux-amd64" \
        "${runtime_stage}/server/dist/plugin-linux-amd64"
    "${SUDO_COMMAND[@]}" install -o 2000 -g 2000 -m 0640 \
        "${reviewed_bundle}" "${bundle_stage}"
    notifier_plugin_tree_is_exact "${runtime_stage}" "${reviewed_root}" "${scratch_root}"
    notifier_plugin_bundle_is_exact "${bundle_stage}" "${expected_sha}"
    stage_complete=true
)

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
