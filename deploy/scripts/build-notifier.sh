#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"
# shellcheck source=notifier-artifact-build-lib.sh
source "${SCRIPT_DIR}/notifier-artifact-build-lib.sh"

require_file "${ENV_FILE}"
require_file "${VERSIONS_FILE}"
require_ubuntu_amd64
validate_base_env
init_docker
init_sudo

data_root="$(env_value THREADHUB_DATA_ROOT "${ENV_FILE}")"
validate_notifier_host_path "${data_root}"
notifier_build_artifacts "${data_root}/notifier/release"
