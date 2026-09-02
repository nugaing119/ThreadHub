#!/usr/bin/env bash

set -Eeuo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(cd "${TEST_DIR}/.." && pwd)"

test_compose_rejects_an_uninitialized_docker_command() (
    local output result

    # shellcheck source=../scripts/common.sh
    source "${DEPLOY_DIR}/scripts/common.sh"
    FUNCNEST=8

    set +e
    output="$(compose config --quiet 2>&1)"
    result=$?
    set -e

    [[ "${result}" -eq 1 ]] || {
        printf 'not ok - uninitialized compose exited %s\n' "${result}" >&2
        return 1
    }
    [[ "${output}" == \
        '[threadhub] ERROR: Docker command is not initialized; call init_docker before compose' ]] \
        || {
            printf 'not ok - uninitialized compose did not fail closed\n' >&2
            return 1
        }
)

test_compose_rejects_an_uninitialized_docker_command
printf 'ok - compose rejects an uninitialized Docker command without recursion\n'
