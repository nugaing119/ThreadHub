#!/usr/bin/env bash

set -Eeuo pipefail

v010_v020_primary_transaction_failure() {
    local output_file="$1"
    local phase=""

    [[ -f "${output_file}" && ! -L "${output_file}" ]] || return 2
    for phase in \
        source_captured target_release_verified target_env_published target_release_published \
        target_override_published target_plugin_pair_published target_mailer_started \
        target_queue_v2_verified target_mattermost_recreated target_pair_verified \
        after_baseline_captured baseline_matched disabled_verified; do
        if grep -Fxq "[threadhub] ERROR: notifier transition halted after phase: ${phase}" \
            "${output_file}"; then
            printf '%s\n' "transaction-after-${phase//_/-}"
            return 0
        fi
    done
    return 1
}

main() {
    local operation="${1:-}"
    local status="${2:-}"
    local output_file="${3:-}"

    [[ "$#" -eq 3 && "${operation}" == primary-failure \
        && "${status}" =~ ^[0-9]+$ ]] || return 2
    v010_v020_primary_transaction_failure "${output_file}"
}

main "$@"
