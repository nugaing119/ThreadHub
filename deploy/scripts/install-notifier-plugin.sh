#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"
# shellcheck source=notifier-lib.sh
source "${SCRIPT_DIR}/notifier-lib.sh"
# shellcheck source=notifier-plugin-files.sh
source "${SCRIPT_DIR}/notifier-plugin-files.sh"
# shellcheck source=notifier-plugin-transaction.sh
source "${SCRIPT_DIR}/notifier-plugin-transaction.sh"
# shellcheck source=notifier-plugin-install-lib.sh
source "${SCRIPT_DIR}/notifier-plugin-install-lib.sh"

require_file "${ENV_FILE}"
require_file "${VERSIONS_FILE}"
require_command git
require_command jq
require_command tar
require_command cmp
require_command sort
require_ubuntu_amd64
validate_base_env
validate_notifier_env
init_docker
init_sudo

data_root="$(env_value THREADHUB_DATA_ROOT "${ENV_FILE}")"
validate_notifier_host_path "${data_root}"
notifier_install_reviewed_pair \
    "${data_root}/notifier/release" \
    "${data_root}/mattermost/plugins" \
    "${data_root}/mattermost/data/plugins" \
    compose mattermost
