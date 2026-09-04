#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

# The fixture delegates the filesystem publication and rollback contract to the
# same libraries used by install-notifier-plugin.sh. Only service lifecycle
# callbacks are fixture-specific because Mattermost is deliberately stopped by
# the outer harness before this isolated, networkless container runs.
# shellcheck source=/dev/null
source /threadhub-deploy/notifier-plugin-files.sh
# shellcheck source=/dev/null
source /threadhub-deploy/notifier-plugin-transaction.sh

# shellcheck disable=SC2034 # consumed by the sourced production helper functions
SUDO_COMMAND=()
mode="${1:-install}"
[[ "$#" -le 1 ]] || exit 2
[[ "${mode}" == install || "${mode}" == verify || "${mode}" == tamper-bundle ]] || exit 2
plugin_id="${NOTIFIER_PLUGIN_ID:?notifier plugin ID is required}"
notifier_version="${NOTIFIER_VERSION:?notifier version is required}"
[[ "${plugin_id}" == com.threadhub.channel-email-notifier ]] || exit 2
[[ "${notifier_version}" == 0.1.0 ]] || exit 2

data_root=/threadhub-data
reviewed_bundle=/reviewed/plugin.tar.gz
reviewed_manifest=/reviewed/plugin.json
runtime_parent="${data_root}/mattermost/plugins"
filestore_parent="${data_root}/mattermost/data/plugins"
release_dir="${data_root}/notifier/release"
target_root="${runtime_parent}/${plugin_id}"
bundle_target="${filestore_parent}/${plugin_id}.tar.gz"
stage_root="${release_dir}/.${plugin_id}.runtime.stage.$$"
bundle_stage="${release_dir}/.${plugin_id}.bundle.stage.$$.tar.gz"
backup_dir="${release_dir}/plugin-backups"
backup_root="${backup_dir}/${plugin_id}-runtime-$$"
failed_root="${backup_dir}/${plugin_id}-runtime-failed-$$"
bundle_backup="${backup_dir}/${plugin_id}-bundle-$$.tar.gz"
bundle_failed="${backup_dir}/${plugin_id}-bundle-failed-$$.tar.gz"
tampered_bundle="${release_dir}/.${plugin_id}.integration-tampered-bundle"
tmp_dir="$(mktemp -d /tmp/threadhub-plugin-install.XXXXXX)"

cleanup_plugin_install() {
    rm -rf -- "${tmp_dir}"
}
trap cleanup_plugin_install EXIT HUP INT TERM

for parent in "${runtime_parent}" "${filestore_parent}" "${release_dir}"; do
    [[ -d "${parent}" && ! -L "${parent}" ]] || exit 1
done
[[ -f "${reviewed_manifest}" && ! -L "${reviewed_manifest}" ]] || exit 1
for mattermost_parent in "${runtime_parent}" "${filestore_parent}"; do
    [[ "$(stat -c '%u:%g:%a' "${mattermost_parent}")" == 2000:2000:750 ]] || exit 1
done
[[ "$(stat -c '%u:%g:%a' "${release_dir}")" == 0:0:750 ]] || exit 1
for path in \
    "${target_root}" "${bundle_target}" "${stage_root}" "${bundle_stage}" \
    "${backup_dir}" "${backup_root}" "${failed_root}" \
    "${bundle_backup}" "${bundle_failed}" "${tampered_bundle}"; do
    [[ ! -L "${path}" ]] || exit 1
done
for path in \
    "${stage_root}" "${bundle_stage}" "${backup_root}" "${failed_root}" \
    "${bundle_backup}" "${bundle_failed}"; do
    [[ ! -e "${path}" ]] || exit 1
done

tar -tzf "${reviewed_bundle}" > "${tmp_dir}/entries"
notifier_plugin_bundle_entries_are_valid \
    "${tmp_dir}/entries" "${plugin_id}" current
tar -tvzf "${reviewed_bundle}" > "${tmp_dir}/verbose-entries"
awk '{ type = substr($1, 1, 1); if (type != "-" && type != "d") exit 1 }' \
    "${tmp_dir}/verbose-entries"
mkdir -m 0700 "${tmp_dir}/extracted"
tar --extract --gzip --file "${reviewed_bundle}" \
    --directory "${tmp_dir}/extracted" \
    --no-same-owner --no-same-permissions
reviewed_root="${tmp_dir}/extracted/${plugin_id}"
cmp -s "${reviewed_manifest}" "${reviewed_root}/plugin.json"
bundle_sha="$(notifier_plugin_privileged_sha256 "${reviewed_bundle}")"
[[ "${bundle_sha}" =~ ^[a-f0-9]{64}$ ]] || exit 1

if [[ "${mode}" == verify ]]; then
    if notifier_plugin_pair_is_exact \
        "${target_root}" "${bundle_target}" "${reviewed_root}" \
        "${bundle_sha}" "${tmp_dir}"; then
        exit 0
    fi
    exit 42
fi

if [[ "${mode}" == tamper-bundle ]]; then
    notifier_plugin_pair_is_exact \
        "${target_root}" "${bundle_target}" "${reviewed_root}" \
        "${bundle_sha}" "${tmp_dir}" || exit 1
    [[ -d "${backup_dir}" && ! -L "${backup_dir}" ]] || exit 1
    [[ ! -e "${tampered_bundle}" && ! -L "${tampered_bundle}" ]] || exit 1
    notifier_plugin_move_no_clobber "${bundle_target}" "${tampered_bundle}" \
        || exit 1
    notifier_plugin_tree_is_exact "${target_root}" "${reviewed_root}" "${tmp_dir}" \
        || exit 1
    notifier_plugin_bundle_is_exact "${tampered_bundle}" "${bundle_sha}" || exit 1
    if notifier_plugin_pair_presence \
        "${target_root}" "${bundle_target}" >/dev/null 2>&1; then
        exit 1
    fi
    [[ -d "${target_root}" && ! -e "${bundle_target}" && ! -L "${bundle_target}" ]] \
        || exit 1
    exit 0
fi

previous_pair_presence="$(notifier_plugin_pair_presence \
    "${target_root}" "${bundle_target}")" || exit 1
if [[ "${previous_pair_presence}" == present ]]; then
    # The isolated real-image run starts from a fresh data volume. A repeated
    # exact invocation is idempotent; any different prior pair must be handled
    # by the production installer, whose validated rollback path has service
    # and plugin-state callbacks unavailable in this stopped-service fixture.
    notifier_plugin_pair_is_exact \
        "${target_root}" "${bundle_target}" "${reviewed_root}" \
        "${bundle_sha}" "${tmp_dir}"
    exit 0
fi

install -d -o root -g root -m 0750 "${backup_dir}"
notifier_plugin_stage_pair \
    "${reviewed_bundle}" "${reviewed_root}" "${stage_root}" "${bundle_stage}" \
    "${bundle_sha}" "${tmp_dir}"

plugin_tx_disable_control() { :; }
plugin_tx_disable_plugin() { :; }
plugin_tx_stop_service() { :; }
plugin_tx_start_service() { :; }
plugin_tx_enable_plugin() { :; }
plugin_tx_enable_previous_plugin() { :; }
plugin_tx_verify_previous_objects() {
    [[ "$(notifier_plugin_pair_presence \
        "${target_root}" "${bundle_target}")" == "${previous_pair_presence}" ]]
}
plugin_tx_verify_previous_plugin() { :; }

plugin_tx_prepare_targets() {
    local path
    local current_presence

    notifier_plugin_tree_is_exact "${stage_root}" "${reviewed_root}" "${tmp_dir}" \
        || return 1
    notifier_plugin_bundle_is_exact "${bundle_stage}" "${bundle_sha}" || return 1
    current_presence="$(notifier_plugin_pair_presence \
        "${target_root}" "${bundle_target}")" || return 1
    [[ "${current_presence}" == "${previous_pair_presence}" ]] || return 1
    for path in \
        "${target_root}" "${bundle_target}" "${stage_root}" "${bundle_stage}" \
        "${backup_root}" "${failed_root}" "${bundle_backup}" "${bundle_failed}"; do
        [[ ! -L "${path}" ]] || return 1
    done
    for path in "${backup_root}" "${failed_root}" "${bundle_backup}" "${bundle_failed}"; do
        [[ ! -e "${path}" ]] || return 1
    done
}

plugin_tx_verify_plugin() {
    notifier_plugin_tree_is_exact "${target_root}" "${reviewed_root}" "${tmp_dir}" \
        && notifier_plugin_bundle_is_exact "${bundle_target}" "${bundle_sha}"
}

plugin_tx_path_exists() {
    [[ -e "$1" || -L "$1" ]]
}

plugin_tx_move() {
    notifier_plugin_move_no_clobber "$1" "$2"
}

notifier_plugin_transaction \
    "${target_root}" "${stage_root}" "${backup_root}" "${failed_root}" \
    "${bundle_target}" "${bundle_stage}" "${bundle_backup}" "${bundle_failed}" \
    false false
plugin_tx_verify_plugin
