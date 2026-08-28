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

notifier_harness_classify_published_address() {
    [[ "$#" -eq 1 ]] || return 1

    local address="$1"

    if [[ -z "${address}" ]]; then
        printf '%s' empty
    elif [[ "${address}" == *$'\n'* || "${address}" == *$'\r'* ]]; then
        printf '%s' multiple
    elif [[ "${address}" =~ ^127\.0\.0\.1:[0-9]+$ ]]; then
        printf '%s' ok
    elif [[ "${address}" =~ ^0\.0\.0\.0:[0-9]+$ ]]; then
        printf '%s' all-interfaces
    elif [[ "${address}" =~ ^\[::1\]:[0-9]+$ \
        || "${address}" =~ ^::1:[0-9]+$ ]]; then
        printf '%s' ipv6
    else
        printf '%s' format
    fi
}
