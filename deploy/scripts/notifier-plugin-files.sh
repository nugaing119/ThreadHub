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

notifier_plugin_bundle_entries_are_valid() {
    local entries_file="$1"
    local plugin_id="$2"
    local profile="${3:-current}"

    [[ -f "${entries_file}" && ! -L "${entries_file}" \
        && "${plugin_id}" == com.threadhub.channel-email-notifier \
        && ( "${profile}" == current || "${profile}" == legacy-or-current ) ]] \
        || return 2
    LC_ALL=C awk -v root="${plugin_id}/" -v profile="${profile}" '
        BEGIN {
            base[root] = 1
            base[root "plugin.json"] = 1
            base[root "server/"] = 1
            base[root "server/dist/"] = 1
            base[root "server/dist/plugin-linux-amd64"] = 1
            current[root "LICENSE"] = 1
            current[root "THIRD_PARTY_NOTICES.md"] = 1
            current[root "third_party/"] = 1
            current[root "third_party/README.md"] = 1
            current[root "third_party/modules.tsv"] = 1
            current[root "third_party/licenses/"] = 1
            sdk = root "third_party/licenses/github.com/mattermost/mattermost/server/public/LICENSE.txt"
        }
        {
            if (seen[$0]++) duplicate = 1
            if ($0 in base) {
                base_seen[$0] = 1
                next
            }
            legacy_bad = 1
            if (($0 in current) || index($0, root "third_party/licenses/") == 1) {
                current_seen[$0] = 1
                next
            }
            current_bad = 1
        }
        END {
            for (path in base) {
                if (!base_seen[path]) {
                    current_bad = 1
                    legacy_bad = 1
                }
            }
            for (path in current) if (!current_seen[path]) current_bad = 1
            if (!current_seen[sdk]) current_bad = 1
            if (duplicate) {
                current_bad = 1
                legacy_bad = 1
            }
            if (!current_bad || (profile == "legacy-or-current" && !legacy_bad)) exit 0
            exit 1
        }
    ' "${entries_file}"
}

notifier_plugin_relative_path_is_allowed() {
    local relative="$1"

    case "${relative}" in
        plugin.json|server|server/dist|server/dist/plugin-linux-amd64|LICENSE|THIRD_PARTY_NOTICES.md|third_party|third_party/README.md|third_party/modules.tsv|third_party/licenses|third_party/licenses/*) ;;
        *) return 1 ;;
    esac
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
    comparison_dir="$(mktemp -d "${scratch_root}/.plugin-tree.XXXXXX")" || return 1
    # shellcheck disable=SC2329 # invoked by the EXIT/signal trap below
    cleanup_tree_comparison() {
        "${SUDO_COMMAND[@]}" rm -rf -- "${comparison_dir}" >/dev/null 2>&1 || true
    }
    trap cleanup_tree_comparison EXIT HUP INT TERM
    find "${reviewed_root}" -mindepth 1 -print \
        | awk -v prefix="${reviewed_root}/" '{ print substr($0, length(prefix) + 1) }' \
        | LC_ALL=C sort > "${comparison_dir}/reviewed-entries" || return 1
    "${SUDO_COMMAND[@]}" find "${root}" -mindepth 1 -print \
        | awk -v prefix="${root}/" '{ print substr($0, length(prefix) + 1) }' \
        | LC_ALL=C sort > "${comparison_dir}/runtime-entries" || return 1
    cmp -s "${comparison_dir}/reviewed-entries" \
        "${comparison_dir}/runtime-entries" || return 1

    root_identity="$("${SUDO_COMMAND[@]}" stat -c '%u:%g:%a' "${root}")" || return 1
    [[ "${root_identity}" == 2000:2000:744 ]] || return 1
    while IFS= read -r relative; do
        [[ -n "${relative}" ]] || return 1
        notifier_plugin_relative_path_is_allowed "${relative}" || return 1
        reviewed_path="${reviewed_root}/${relative}"
        runtime_path="${root}/${relative}"
        [[ ! -L "${reviewed_path}" ]] || return 1
        "${SUDO_COMMAND[@]}" test ! -L "${runtime_path}" || return 1
        if [[ -d "${reviewed_path}" ]]; then
            "${SUDO_COMMAND[@]}" test -d "${runtime_path}" || return 1
            expected_identity=2000:2000:744
        elif [[ -f "${reviewed_path}" ]]; then
            "${SUDO_COMMAND[@]}" test -f "${runtime_path}" || return 1
            "${SUDO_COMMAND[@]}" cmp -s "${reviewed_path}" "${runtime_path}" \
                || return 1
            if [[ "${relative}" == server/dist/plugin-linux-amd64 ]]; then
                expected_identity=2000:2000:755
            else
                expected_identity=2000:2000:644
            fi
        else
            return 1
        fi
        identity="$("${SUDO_COMMAND[@]}" stat -c '%u:%g:%a' "${runtime_path}")" \
            || return 1
        [[ "${identity}" == "${expected_identity}" ]] || return 1
    done < "${comparison_dir}/reviewed-entries"
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
    notifier_plugin_bundle_entries_are_valid \
        "${inspection_dir}/entries" "${plugin_id}" legacy-or-current || return 1
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
    stage_entries=""

    # shellcheck disable=SC2329 # invoked by the EXIT/signal trap below
    cleanup_partial_stage() {
        local original_status=$?

        trap - EXIT HUP INT TERM
        if [[ "${stage_started}" == true && "${stage_complete}" != true ]]; then
            "${SUDO_COMMAND[@]}" rm -rf -- "${runtime_stage}" >/dev/null 2>&1 || true
            "${SUDO_COMMAND[@]}" rm -f -- "${bundle_stage}" >/dev/null 2>&1 || true
        fi
        if [[ -n "${stage_entries}" ]]; then
            rm -f -- "${stage_entries}" >/dev/null 2>&1 || true
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
    "${SUDO_COMMAND[@]}" install -d -o 2000 -g 2000 -m 0744 "${runtime_stage}"
    stage_entries="$(mktemp "${scratch_root}/.plugin-stage.XXXXXX")" || return 1
    find "${reviewed_root}" -mindepth 1 -print \
        | LC_ALL=C sort > "${stage_entries}" || return 1
    while IFS= read -r reviewed_path; do
        relative="${reviewed_path#"${reviewed_root}/"}"
        [[ -n "${relative}" && "${relative}" != "${reviewed_path}" ]] || return 1
        notifier_plugin_relative_path_is_allowed "${relative}" || return 1
        [[ ! -L "${reviewed_path}" ]] || return 1
        if [[ -d "${reviewed_path}" ]]; then
            "${SUDO_COMMAND[@]}" install -d -o 2000 -g 2000 -m 0744 \
                "${runtime_stage}/${relative}"
        elif [[ -f "${reviewed_path}" ]]; then
            file_mode=0644
            [[ "${relative}" != server/dist/plugin-linux-amd64 ]] || file_mode=0755
            "${SUDO_COMMAND[@]}" install -o 2000 -g 2000 -m "${file_mode}" \
                "${reviewed_path}" "${runtime_stage}/${relative}"
        else
            return 1
        fi
    done < "${stage_entries}"
    rm -f -- "${stage_entries}"
    stage_entries=""
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
