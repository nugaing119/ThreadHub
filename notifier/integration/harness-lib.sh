#!/usr/bin/env bash

notifier_harness_file_mode() {
    [[ "$#" -eq 1 ]] || return 1

    local path="$1"
    local mode=""

    if mode="$(stat -c '%a' -- "${path}" 2>/dev/null)" \
        && [[ "${mode}" =~ ^[0-7]{3,4}$ ]]; then
        printf '%s' "${mode}"
        return 0
    fi
    if mode="$(stat -f '%Lp' -- "${path}" 2>/dev/null)" \
        && [[ "${mode}" =~ ^[0-7]{3,4}$ ]]; then
        printf '%s' "${mode}"
        return 0
    fi
    return 1
}
