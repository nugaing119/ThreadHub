#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

BACKUP_SNAPSHOT_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=backup-common.sh
source "${BACKUP_SNAPSHOT_SCRIPT_DIR}/backup-common.sh"
# shellcheck source=backup-artifacts.sh
source "${BACKUP_SNAPSHOT_SCRIPT_DIR}/backup-artifacts.sh"

backup_snapshot_entry() {
    (($# == 1)) || return 20
    [[ "$(id -u)" -eq 0 ]] || return 20
    backup_validate_config || return 20
    backup_artifact_set_dir_is_valid "$1" || return 20
    init_docker
    backup_create_artifacts "$1"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    backup_snapshot_entry "$@"
fi
