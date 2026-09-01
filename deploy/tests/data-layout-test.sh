#!/usr/bin/env bash

# The privileged fixture wrapper records production ownership intent while
# applying portable ownership to a temporary, user-owned test tree.
# shellcheck disable=SC2034,SC2251,SC2329

set -Eeuo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(cd "${TEST_DIR}/.." && pwd)"
COMMON="${DEPLOY_DIR}/scripts/common.sh"
DATA_LAYOUT="${DEPLOY_DIR}/scripts/data-layout.sh"
failures=0

fail() { printf 'not ok - %s\n' "$1" >&2; failures=$((failures + 1)); }
pass() { printf 'ok - %s\n' "$1"; }

run_test() {
    local name="$1" function_name="$2" test_status

    set +e
    ( set -Eeuo pipefail; "${function_name}" )
    test_status=$?
    set -e
    if ((test_status == 0)); then pass "${name}"; else fail "${name}"; fi
}

portable_mode() {
    if stat -c '%a' "$1" >/dev/null 2>&1; then stat -c '%a' "$1"; else stat -f '%Lp' "$1"; fi
}

layout_test_privileged() {
    local command_name="$1"
    shift
    printf '%q ' "${command_name}" "$@" >> "${LAYOUT_TEST_TRACE}"
    printf '\n' >> "${LAYOUT_TEST_TRACE}"
    case "${command_name}" in
        install)
            local -a filtered=()
            while (($# > 0)); do
                case "$1" in
                    -o|-g) shift 2 ;;
                    *) filtered+=("$1"); shift ;;
                esac
            done
            command install "${filtered[@]}"
            ;;
        chown) return 0 ;;
        chmod) command chmod "$@" ;;
        *) command "${command_name}" "$@" ;;
    esac
}

load_fixture() {
    local fixture="$1"

    [[ -f "${COMMON}" && -f "${DATA_LAYOUT}" ]] || return 1
    # shellcheck source=/dev/null
    source "${COMMON}"
    # shellcheck source=/dev/null
    source "${DATA_LAYOUT}"
    LAYOUT_TEST_ROOT="${fixture}/srv/threadhub"
    LAYOUT_TEST_TRACE="${fixture}/privileged.trace"
    export LAYOUT_TEST_TRACE
    mkdir -p "${fixture}/srv"
    : > "${LAYOUT_TEST_TRACE}"
    SUDO_COMMAND=(layout_test_privileged)
    data_layout_validate_root() {
        [[ "$1" == "${LAYOUT_TEST_ROOT}" ]] && data_layout_assert_no_symlink_components "$1"
    }
}

test_production_validator_accepts_only_fixed_root() (
    [[ -f "${COMMON}" && -f "${DATA_LAYOUT}" ]] || return 1
    # shellcheck source=/dev/null
    source "${COMMON}"
    # shellcheck source=/dev/null
    source "${DATA_LAYOUT}"
    ! data_layout_validate_root /tmp/threadhub-fixture
)

test_layout_has_canonical_modes_and_ownership_intent() (
    fixture="$(mktemp -d)"
    trap 'rm -rf "${fixture}"' EXIT
    load_fixture "${fixture}"

    prepare_threadhub_data_layout "${LAYOUT_TEST_ROOT}"
    [[ "$(portable_mode "${LAYOUT_TEST_ROOT}")" == 750 ]]
    [[ "$(portable_mode "${LAYOUT_TEST_ROOT}/postgres")" == 755 ]]
    [[ "$(portable_mode "${LAYOUT_TEST_ROOT}/mattermost/data")" == 750 ]]
    [[ "$(portable_mode "${LAYOUT_TEST_ROOT}/notifier/mailer")" == 700 ]]
    [[ "$(portable_mode "${LAYOUT_TEST_ROOT}/notifier/control")" == 750 ]]
    grep -F 'install -d -o root -g root -m 0750' "${LAYOUT_TEST_TRACE}" >/dev/null
    grep -F 'install -d -o root -g 3000 -m 0750' "${LAYOUT_TEST_TRACE}" >/dev/null
    grep -F 'install -d -o 65532 -g 65532 -m 0700' "${LAYOUT_TEST_TRACE}" >/dev/null
    grep -F 'chown 2000:2000' "${LAYOUT_TEST_TRACE}" >/dev/null
)

test_repeated_prepare_preserves_existing_content() (
    fixture="$(mktemp -d)"
    trap 'rm -rf "${fixture}"' EXIT
    load_fixture "${fixture}"
    prepare_threadhub_data_layout "${LAYOUT_TEST_ROOT}"
    printf 'preserve-me\n' > "${LAYOUT_TEST_ROOT}/mattermost/data/sentinel"
    before="$(sha256_file "${LAYOUT_TEST_ROOT}/mattermost/data/sentinel")"

    prepare_threadhub_data_layout "${LAYOUT_TEST_ROOT}"
    [[ "$(sha256_file "${LAYOUT_TEST_ROOT}/mattermost/data/sentinel")" == "${before}" ]]
)

test_prepare_rejects_symlink_without_replacing_it() (
    fixture="$(mktemp -d)"
    trap 'rm -rf "${fixture}"' EXIT
    load_fixture "${fixture}"
    mkdir -p "${LAYOUT_TEST_ROOT}/mattermost" "${fixture}/outside"
    ln -s "${fixture}/outside" "${LAYOUT_TEST_ROOT}/mattermost/data"

    ! prepare_threadhub_data_layout "${LAYOUT_TEST_ROOT}" >"${fixture}/stdout" 2>"${fixture}/stderr"
    [[ -L "${LAYOUT_TEST_ROOT}/mattermost/data" ]]
    [[ ! -s "${LAYOUT_TEST_TRACE}" ]]
)

test_restore_normalization_touches_only_regular_mattermost_data() (
    fixture="$(mktemp -d)"
    trap 'rm -rf "${fixture}"' EXIT
    load_fixture "${fixture}"
    prepare_threadhub_data_layout "${LAYOUT_TEST_ROOT}"
    printf 'attachment\n' > "${LAYOUT_TEST_ROOT}/mattermost/data/file"
    printf 'postgres\n' > "${LAYOUT_TEST_ROOT}/postgres/sentinel"
    printf 'queue\n' > "${LAYOUT_TEST_ROOT}/notifier/mailer/queue.db"
    chmod 0777 "${LAYOUT_TEST_ROOT}/mattermost/data/file"
    postgres_before="$(sha256_file "${LAYOUT_TEST_ROOT}/postgres/sentinel")"
    queue_before="$(sha256_file "${LAYOUT_TEST_ROOT}/notifier/mailer/queue.db")"
    : > "${LAYOUT_TEST_TRACE}"

    normalize_threadhub_restored_data "${LAYOUT_TEST_ROOT}"
    [[ "$(portable_mode "${LAYOUT_TEST_ROOT}/mattermost/data/file")" == 640 ]]
    grep -F "chown -R 2000:2000 ${LAYOUT_TEST_ROOT}/mattermost/data" "${LAYOUT_TEST_TRACE}" >/dev/null
    [[ "$(sha256_file "${LAYOUT_TEST_ROOT}/postgres/sentinel")" == "${postgres_before}" ]]
    [[ "$(sha256_file "${LAYOUT_TEST_ROOT}/notifier/mailer/queue.db")" == "${queue_before}" ]]

    ln -s "${fixture}/outside" "${LAYOUT_TEST_ROOT}/mattermost/data/link"
    : > "${LAYOUT_TEST_TRACE}"
    ! normalize_threadhub_restored_data "${LAYOUT_TEST_ROOT}"
    [[ ! -s "${LAYOUT_TEST_TRACE}" ]]
)

run_test 'production layout validator accepts only the fixed root' test_production_validator_accepts_only_fixed_root
run_test 'layout has canonical modes and ownership intent' test_layout_has_canonical_modes_and_ownership_intent
run_test 'repeated layout preparation preserves existing content' test_repeated_prepare_preserves_existing_content
run_test 'layout preparation rejects symlinks without replacement' test_prepare_rejects_symlink_without_replacing_it
run_test 'restore normalization touches only regular Mattermost data' test_restore_normalization_touches_only_regular_mattermost_data

if ((failures > 0)); then
    printf '%d data layout test(s) failed\n' "${failures}" >&2
    exit 1
fi
