#!/usr/bin/env bash

set -Eeuo pipefail

[[ "$#" -eq 3 ]] || exit 2
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=../../deploy/scripts/notifier-lib.sh
source "${script_dir}/../../deploy/scripts/notifier-lib.sh"

notifier_plugin_list_is_exact_active "$1" "$2" "$3"
