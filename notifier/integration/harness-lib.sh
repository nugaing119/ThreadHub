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

notifier_harness_is_private_ipv4() {
    [[ "$#" -eq 1 ]] || return 1

    local address="$1"
    local first=""
    local second=""
    local third=""
    local fourth=""

    [[ "${address}" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
    IFS=. read -r first second third fourth <<<"${address}"
    for octet in "${first}" "${second}" "${third}" "${fourth}"; do
        ((10#${octet} <= 255)) || return 1
    done
    if ((10#${first} == 10)); then
        return 0
    fi
    if ((10#${first} == 172 && 10#${second} >= 16 && 10#${second} <= 31)); then
        return 0
    fi
    ((10#${first} == 192 && 10#${second} == 168))
}
