#!/usr/bin/env bash

set -Eeuo pipefail

v010_v020_primary_transaction_failure() {
    local output_file="$1"
    local phase=""
    local primary=""
    local publish=""
    local staging=""

    [[ -f "${output_file}" && ! -L "${output_file}" ]] || return 2
    for phase in \
        source_captured target_release_verified target_env_published target_release_published \
        target_override_published target_plugin_pair_published target_mailer_started \
        target_queue_v2_verified target_mattermost_recreated target_pair_verified \
        after_baseline_captured baseline_matched disabled_verified; do
        if grep -Fxq "[threadhub] ERROR: notifier transition halted after phase: ${phase}" \
            "${output_file}"; then
            primary="transaction-after-${phase//_/-}"
            break
        fi
    done
    for phase in target-extracted source-hashed source-verified target-staged \
        filesystem-verified mattermost-stopped pair-transacted; do
        if grep -Fxq "[threadhub] ERROR: notifier plugin publication halted at stage: ${phase}" \
            "${output_file}"; then
            publish="plugin-publish-${phase}"
            break
        fi
    done
    for phase in checksum-validation reviewed-bundle-validation reviewed-runtime-validation \
        reviewed-runtime-empty reviewed-runtime-missing reviewed-runtime-not-directory \
        reviewed-runtime-privileged-only reviewed-runtime-symlink scratch-root-validation \
        bundle-integrity-validation destination-absence-validation runtime-root-creation \
        entry-listing runtime-materialization bundle-materialization runtime-verification \
        bundle-verification; do
        if grep -Fxq "[threadhub] ERROR: notifier plugin staging halted at phase: ${phase}" \
            "${output_file}"; then
            staging="plugin-staging-${phase}"
            break
        fi
    done
    [[ -n "${primary}" || -n "${publish}" || -n "${staging}" ]] || return 1
    primary="${primary:-${publish:-${staging}}}"
    if [[ -n "${publish}" && "${primary}" != "${publish}" ]]; then
        primary+="-plus-${publish}"
    fi
    if [[ -n "${staging}" && "${primary}" != "${staging}" ]]; then
        primary+="-plus-${staging}"
    fi
    printf '%s\n' "${primary}"
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
