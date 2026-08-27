#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"
# shellcheck source=notifier-plugin-transaction.sh
source "${SCRIPT_DIR}/notifier-plugin-transaction.sh"

require_file "${ENV_FILE}"
require_file "${VERSIONS_FILE}"
require_command git
require_command jq
require_command tar
require_command cmp
require_ubuntu_amd64
validate_base_env
validate_notifier_env
init_docker
init_sudo

data_root="$(env_value THREADHUB_DATA_ROOT "${ENV_FILE}")"
release_dir="${data_root}/notifier/release"
release_file="${release_dir}/release.env"
plugins_root="${data_root}/mattermost/plugins"
tmp_dir="$(mktemp -d)"

cleanup() {
    rm -rf "${tmp_dir}"
}
trap cleanup EXIT HUP INT TERM

validate_notifier_host_path "${data_root}"
for path in "${release_dir}" "${plugins_root}"; do
    "${SUDO_COMMAND[@]}" test -d "${path}" || die "Required plugin installation directory is missing"
    "${SUDO_COMMAND[@]}" test ! -L "${path}" || die "Refusing symbolic-link plugin installation directory"
done
"${SUDO_COMMAND[@]}" test -f "${release_file}" || die "Notifier release identity is missing"
"${SUDO_COMMAND[@]}" test ! -L "${release_file}" || die "Refusing symbolic-link notifier release identity"
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
[[ "${line_count}" == "7" ]] || die "Notifier release identity must contain exactly seven fields"
while IFS='=' read -r key value; do
    case "${key}" in
        NOTIFIER_VERSION|NOTIFIER_PLUGIN_ID|NOTIFIER_PLUGIN_BUNDLE|NOTIFIER_PLUGIN_BUNDLE_SHA256|NOTIFIER_MAILER_IMAGE|NOTIFIER_MAILER_IMAGE_ID|NOTIFIER_SOURCE_COMMIT) ;;
        *) die "Notifier release identity contains an unknown field" ;;
    esac
    [[ -n "${value}" && "${value}" != *$'\r'* && "${value}" != *$'\n'* ]] \
        || die "Notifier release identity contains an invalid value"
done < "${tmp_dir}/release.env"

notifier_version="$(release_value NOTIFIER_VERSION)"
plugin_id="$(release_value NOTIFIER_PLUGIN_ID)"
bundle_relative="$(release_value NOTIFIER_PLUGIN_BUNDLE)"
bundle_sha256="$(release_value NOTIFIER_PLUGIN_BUNDLE_SHA256)"
mailer_image="$(release_value NOTIFIER_MAILER_IMAGE)"
mailer_image_id="$(release_value NOTIFIER_MAILER_IMAGE_ID)"
source_commit="$(release_value NOTIFIER_SOURCE_COMMIT)"

[[ "${notifier_version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "Invalid notifier release version"
[[ "${plugin_id}" == "com.threadhub.channel-email-notifier" ]] || die "Invalid notifier plugin ID"
[[ "${bundle_relative}" == "notifier/dist/${plugin_id}-${notifier_version}.tar.gz" ]] \
    || die "Invalid notifier bundle path"
[[ "${bundle_sha256}" =~ ^[a-f0-9]{64}$ ]] || die "Invalid notifier bundle hash"
[[ "${mailer_image}" == "threadhub/notifier-mailer:${notifier_version}" ]] || die "Invalid notifier Mailer image reference"
[[ "${mailer_image_id}" =~ ^sha256:[a-f0-9]{64}$ ]] || die "Invalid notifier Mailer image ID"
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
cmp -s "${tmp_dir}/entries" "${tmp_dir}/expected-entries" \
    || die "Notifier bundle contains unexpected paths"
tar -tvzf "${bundle_path}" > "${tmp_dir}/verbose-entries"
awk '{ type = substr($1, 1, 1); if (type != "-" && type != "d") exit 1 }' "${tmp_dir}/verbose-entries" \
    || die "Notifier bundle contains a non-regular archive type"

mkdir -m 0700 "${tmp_dir}/extracted"
tar --extract --gzip --file "${bundle_path}" \
    --directory "${tmp_dir}/extracted" \
    --no-same-owner --no-same-permissions
extracted_root="${tmp_dir}/extracted/${plugin_id}"
manifest="${extracted_root}/plugin.json"
executable="${extracted_root}/server/dist/plugin-linux-amd64"
[[ -d "${extracted_root}" && ! -L "${extracted_root}" ]] || die "Notifier bundle root is invalid"
[[ -f "${manifest}" && ! -L "${manifest}" ]] || die "Notifier manifest is invalid"
[[ -f "${executable}" && ! -L "${executable}" ]] || die "Notifier server executable is invalid"
jq -e --arg id "${plugin_id}" --arg version "${notifier_version}" '
    type == "object" and
    (keys == ["description", "homepage_url", "id", "min_server_version", "name", "server", "support_url", "version"]) and
    .id == $id and .version == $version and .min_server_version == "11.7.7" and
    (.server | keys == ["executables"]) and
    (.server.executables | keys == ["linux-amd64"]) and
    .server.executables["linux-amd64"] == "server/dist/plugin-linux-amd64"
' "${manifest}" >/dev/null || die "Notifier manifest does not match the reviewed release"

target_root="${plugins_root}/${plugin_id}"
"${SUDO_COMMAND[@]}" test ! -L "${target_root}" || die "Refusing symbolic-link notifier plugin target"
if "${SUDO_COMMAND[@]}" test -e "${target_root}" \
    && ! "${SUDO_COMMAND[@]}" test -d "${target_root}"; then
    die "Refusing non-directory notifier plugin target"
fi

mattermost_id="$(compose ps -q mattermost)"
was_running=false
if [[ -n "${mattermost_id}" ]]; then
    was_running=true
fi

plugin_list_json() {
    compose exec -T mattermost \
        mmctl plugin list --local --suppress-warnings --json
}

plugin_is_active() {
    local json_file="$1"
    local expected_version="$2"

    jq -e --arg id "${plugin_id}" --arg version "${expected_version}" '
        (.active | type == "array") and (.inactive | type == "array") and
        ([.active[] | select(.id == $id and .version == $version)] | length == 1) and
        ([.active[] | select(.id == $id and .version != $version)] | length == 0) and
        ([.inactive[] | select(.id == $id)] | length == 0)
    ' "${json_file}" >/dev/null
}

ensure_plugin_active() {
    compose up -d --wait --wait-timeout 240 mattermost || return 1
    compose exec -T mattermost \
        mmctl plugin enable "${plugin_id}" --local --suppress-warnings >/dev/null || return 1
    plugin_list_json > "${tmp_dir}/plugin-list.json" || return 1
    plugin_is_active "${tmp_dir}/plugin-list.json" "${notifier_version}" \
        || return 1
}

plugin_tree_exact() {
    local root="$1"
    local output_name="$2"

    "${SUDO_COMMAND[@]}" find "${root}" -mindepth 1 -printf '%P\t%y\n' \
        | LC_ALL=C sort > "${tmp_dir}/${output_name}"
    printf '%s\n' \
        $'plugin.json\tf' \
        $'server\td' \
        $'server/dist\td' \
        $'server/dist/plugin-linux-amd64\tf' \
        > "${tmp_dir}/expected-tree"
    cmp -s "${tmp_dir}/${output_name}" "${tmp_dir}/expected-tree"
}

if "${SUDO_COMMAND[@]}" test -d "${target_root}" \
    && "${SUDO_COMMAND[@]}" test ! -L "${target_root}" \
    && plugin_tree_exact "${target_root}" installed-tree \
    && "${SUDO_COMMAND[@]}" cmp -s "${manifest}" "${target_root}/plugin.json" \
    && "${SUDO_COMMAND[@]}" cmp -s "${executable}" "${target_root}/server/dist/plugin-linux-amd64"; then
    "${SUDO_COMMAND[@]}" chown -R 2000:2000 "${target_root}"
    "${SUDO_COMMAND[@]}" find "${target_root}" -type d -exec chmod 0750 {} +
    "${SUDO_COMMAND[@]}" find "${target_root}" -type f -exec chmod 0640 {} +
    "${SUDO_COMMAND[@]}" chmod 0750 "${target_root}/server/dist/plugin-linux-amd64"
    ensure_plugin_active || die "Exact notifier plugin ID and version could not be activated"
    log "Exact notifier plugin bundle is already installed and active"
    exit 0
fi

plugin_was_active=false
previous_plugin_version=""
if [[ "${was_running}" == true ]]; then
    plugin_list_json > "${tmp_dir}/plugin-list-before.json"
    active_count="$(jq -r --arg id "${plugin_id}" '[.active[] | select(.id == $id)] | length' \
        "${tmp_dir}/plugin-list-before.json")"
    [[ "${active_count}" =~ ^[0-9]+$ && "${active_count}" -le 1 ]] \
        || die "Mattermost reported duplicate active notifier plugin entries"
    if [[ "${active_count}" == "1" ]]; then
        plugin_was_active=true
        previous_plugin_version="$(jq -r --arg id "${plugin_id}" \
            '.active[] | select(.id == $id) | .version' \
            "${tmp_dir}/plugin-list-before.json")"
        [[ "${previous_plugin_version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+([+-][A-Za-z0-9.-]+)?$ ]] \
            || die "Existing active notifier plugin version is invalid"
    fi
fi

stage_root="${release_dir}/.${plugin_id}.stage.$$"
backup_dir="${release_dir}/plugin-backups"
backup_root="${backup_dir}/${plugin_id}-$(date -u +%Y%m%dT%H%M%SZ)-$$"
failed_root="${backup_dir}/${plugin_id}-failed-$(date -u +%Y%m%dT%H%M%SZ)-$$"
for path in "${backup_dir}" "${stage_root}" "${backup_root}" "${failed_root}"; do
    "${SUDO_COMMAND[@]}" test ! -L "${path}" \
        || die "Refusing symbolic-link notifier plugin staging or backup path"
done
for path in "${stage_root}" "${backup_root}" "${failed_root}"; do
    "${SUDO_COMMAND[@]}" test ! -e "${path}" || die "Refusing existing notifier plugin staging or backup path"
done
if "${SUDO_COMMAND[@]}" test -e "${backup_dir}" \
    && ! "${SUDO_COMMAND[@]}" test -d "${backup_dir}"; then
    die "Refusing non-directory notifier plugin backup path"
fi
plugins_device="$("${SUDO_COMMAND[@]}" stat -c '%d' "${plugins_root}")"
release_device="$("${SUDO_COMMAND[@]}" stat -c '%d' "${release_dir}")"
[[ "${plugins_device}" == "${release_device}" ]] \
    || die "Notifier plugin staging and target paths must share one filesystem"

"${SUDO_COMMAND[@]}" install -d -o root -g root -m 0750 "${backup_dir}"
"${SUDO_COMMAND[@]}" install -d -o 2000 -g 2000 -m 0750 \
    "${stage_root}" \
    "${stage_root}/server" \
    "${stage_root}/server/dist"
"${SUDO_COMMAND[@]}" install -o 2000 -g 2000 -m 0640 \
    "${manifest}" "${stage_root}/plugin.json"
"${SUDO_COMMAND[@]}" install -o 2000 -g 2000 -m 0750 \
    "${executable}" "${stage_root}/server/dist/plugin-linux-amd64"
"${SUDO_COMMAND[@]}" test ! -L "${stage_root}" \
    || die "Notifier plugin stage became a symbolic link"
plugin_tree_exact "${stage_root}" staged-tree \
    || die "Materialized notifier plugin stage is incomplete"
"${SUDO_COMMAND[@]}" cmp -s "${manifest}" "${stage_root}/plugin.json" \
    || die "Materialized notifier manifest differs from the reviewed bundle"
"${SUDO_COMMAND[@]}" cmp -s "${executable}" "${stage_root}/server/dist/plugin-linux-amd64" \
    || die "Materialized notifier executable differs from the reviewed bundle"

plugin_tx_disable_control() {
    install_disabled_notifier_control "${data_root}"
}

plugin_tx_disable_plugin() {
    compose exec -T mattermost \
        mmctl plugin disable "${plugin_id}" --local --suppress-warnings >/dev/null
}

plugin_tx_stop_service() {
    compose stop mattermost >/dev/null
}

plugin_tx_start_service() {
    compose up -d --wait --wait-timeout 240 mattermost >/dev/null
}

plugin_tx_enable_plugin() {
    compose exec -T mattermost \
        mmctl plugin enable "${plugin_id}" --local --suppress-warnings >/dev/null
}

plugin_tx_verify_plugin() {
    plugin_list_json > "${tmp_dir}/plugin-list-transaction.json" \
        && plugin_is_active "${tmp_dir}/plugin-list-transaction.json" "${notifier_version}"
}

plugin_tx_verify_previous_plugin() {
    plugin_list_json > "${tmp_dir}/plugin-list-rollback.json" \
        && plugin_is_active "${tmp_dir}/plugin-list-rollback.json" "${previous_plugin_version}"
}

plugin_tx_path_exists() {
    "${SUDO_COMMAND[@]}" test -e "$1"
}

plugin_tx_move() {
    "${SUDO_COMMAND[@]}" mv -T "$1" "$2"
}

set +e
notifier_plugin_transaction \
    "${target_root}" \
    "${stage_root}" \
    "${backup_root}" \
    "${failed_root}" \
    "${was_running}" \
    "${plugin_was_active}"
transaction_result=$?
set -e
if ((transaction_result != 0)); then
    die "Notifier plugin replacement transaction failed; review the rollback result above"
fi

log "Notifier plugin ${plugin_id} ${notifier_version} is installed and active; runtime delivery remains controlled by state.json"
