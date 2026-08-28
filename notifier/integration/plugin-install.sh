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
plugin_id="${NOTIFIER_PLUGIN_ID:?notifier plugin ID is required}"
notifier_version="${NOTIFIER_VERSION:?notifier version is required}"
[[ "${plugin_id}" == com.threadhub.channel-email-notifier ]] || exit 2
[[ "${notifier_version}" == 0.1.0 ]] || exit 2

data_root=/threadhub-data
reviewed_bundle=/reviewed/plugin.tar.gz
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
tmp_dir="$(mktemp -d /tmp/threadhub-plugin-install.XXXXXX)"

cleanup_plugin_install() {
    rm -rf -- "${tmp_dir}"
}
trap cleanup_plugin_install EXIT HUP INT TERM

for parent in "${runtime_parent}" "${filestore_parent}" "${release_dir}"; do
    [[ -d "${parent}" && ! -L "${parent}" ]] || exit 1
done
for mattermost_parent in "${runtime_parent}" "${filestore_parent}"; do
    [[ "$(stat -c '%u:%g:%a' "${mattermost_parent}")" == 2000:2000:750 ]] || exit 1
done
[[ "$(stat -c '%u:%g:%a' "${release_dir}")" == 0:0:750 ]] || exit 1
for path in \
    "${target_root}" "${bundle_target}" "${stage_root}" "${bundle_stage}" \
    "${backup_dir}" "${backup_root}" "${failed_root}" \
    "${bundle_backup}" "${bundle_failed}"; do
    [[ ! -L "${path}" ]] || exit 1
done
for path in \
    "${stage_root}" "${bundle_stage}" "${backup_root}" "${failed_root}" \
    "${bundle_backup}" "${bundle_failed}"; do
    [[ ! -e "${path}" ]] || exit 1
done

tar -tzf "${reviewed_bundle}" > "${tmp_dir}/entries"
printf '%s\n' \
    "${plugin_id}/" \
    "${plugin_id}/plugin.json" \
    "${plugin_id}/server/" \
    "${plugin_id}/server/dist/" \
    "${plugin_id}/server/dist/plugin-linux-amd64" \
    > "${tmp_dir}/expected-entries"
cmp -s "${tmp_dir}/entries" "${tmp_dir}/expected-entries"
tar -tvzf "${reviewed_bundle}" > "${tmp_dir}/verbose-entries"
awk '{ type = substr($1, 1, 1); if (type != "-" && type != "d") exit 1 }' \
    "${tmp_dir}/verbose-entries"
mkdir -m 0700 "${tmp_dir}/extracted"
tar --extract --gzip --file "${reviewed_bundle}" \
    --directory "${tmp_dir}/extracted" \
    --no-same-owner --no-same-permissions
reviewed_root="${tmp_dir}/extracted/${plugin_id}"
bundle_sha="$(notifier_plugin_privileged_sha256 "${reviewed_bundle}")"
[[ "${bundle_sha}" =~ ^[a-f0-9]{64}$ ]] || exit 1

install -d -o root -g root -m 0750 "${backup_dir}"
notifier_plugin_stage_pair \
    "${reviewed_bundle}" "${reviewed_root}" "${stage_root}" "${bundle_stage}" \
    "${bundle_sha}" "${tmp_dir}"

plugin_tx_disable_control() { :; }
plugin_tx_disable_plugin() { :; }
plugin_tx_stop_service() { :; }
plugin_tx_start_service() { :; }
plugin_tx_enable_plugin() { :; }
plugin_tx_verify_previous_plugin() { :; }

plugin_tx_prepare_targets() {
    local path

    notifier_plugin_tree_is_exact "${stage_root}" "${reviewed_root}" "${tmp_dir}" \
        || return 1
    notifier_plugin_bundle_is_exact "${bundle_stage}" "${bundle_sha}" || return 1
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
