#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"
# shellcheck source=existing-notifier-common.sh
source "${SCRIPT_DIR}/existing-notifier-common.sh"
# shellcheck source=notifier-lib.sh
source "${SCRIPT_DIR}/notifier-lib.sh"
# shellcheck source=notifier-plugin-files.sh
source "${SCRIPT_DIR}/notifier-plugin-files.sh"
# shellcheck source=notifier-plugin-transaction.sh
source "${SCRIPT_DIR}/notifier-plugin-transaction.sh"
# shellcheck source=notifier-plugin-install-lib.sh
source "${SCRIPT_DIR}/notifier-plugin-install-lib.sh"

existing_notifier_install_plugin() {
    local notifier_root
    local release_dir
    local plugins_root
    local filestore_plugins_root
    local mattermost_service

    existing_notifier_validate_config || return $?
    require_ubuntu_amd64
    require_command git
    require_command jq
    require_command tar
    require_command cmp
    require_command sort
    init_docker
    init_sudo
    existing_notifier_init_compose

    notifier_root="$(existing_notifier_value THN_DATA_ROOT)"
    release_dir="${notifier_root}/release"
    plugins_root="$(existing_notifier_value THN_MATTERMOST_PLUGINS_ROOT)"
    filestore_plugins_root="$(existing_notifier_value THN_MATTERMOST_DATA_ROOT)/plugins"
    mattermost_service="$(existing_notifier_value THN_MATTERMOST_SERVICE)"
    notifier_install_reviewed_pair \
        "${release_dir}" "${plugins_root}" "${filestore_plugins_root}" \
        existing_notifier_compose_combined "${mattermost_service}" \
        existing_notifier_compose_base
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    [[ "$#" -eq 0 ]] || die "Usage: $0"
    existing_notifier_install_plugin
fi
