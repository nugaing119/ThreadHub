#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

[[ "${1:-}" == "--confirm-stop" && "$#" -eq 1 ]] || {
    printf 'Usage: %s --confirm-stop\n' "$0" >&2
    printf 'This stops and removes containers but intentionally retains all bind-mount data.\n' >&2
    exit 2
}

require_file "${ENV_FILE}"
require_file "${VERSIONS_FILE}"
init_docker

compose down --remove-orphans

log "Containers and the Compose network were removed"
log "Persistent data under /srv/threadhub was retained; this script never uses down -v or deletes data"
