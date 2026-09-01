#!/usr/bin/env bash

# Restore orchestration hooks are replaced by deterministic fault fixtures.
# Negative assertions intentionally use `! command` inside isolated tests.
# shellcheck disable=SC2034,SC2251,SC2329

set -Eeuo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(cd "${TEST_DIR}/.." && pwd)"
RESTORE_SCRIPT="${DEPLOY_DIR}/scripts/restore.sh"
failures=0

fail() { printf 'not ok - %s\n' "$1" >&2; failures=$((failures + 1)); }
pass() { printf 'ok - %s\n' "$1"; }

portable_mode() {
    if stat -c '%a' "$1" >/dev/null 2>&1; then stat -c '%a' "$1"; else stat -f '%Lp' "$1"; fi
}

run_test() {
    local name="$1" function_name="$2" test_status

    set +e
    ( set -Eeuo pipefail; "${function_name}" )
    test_status=$?
    set -e
    if ((test_status == 0)); then pass "${name}"; else fail "${name}"; fi
}

event() {
    printf '%s\n' "$1" >> "${RESTORE_TEST_EVENTS}"
}

load_fixture() {
    local fixture="$1"

    [[ -f "${RESTORE_SCRIPT}" ]] || return 1
    # shellcheck source=/dev/null
    source "${RESTORE_SCRIPT}"
    RESTORE_TARGET_ROOT="${fixture}/target"
    RESTORE_STATE_ROOT="${fixture}/state/restore"
    RESTORE_TEST_EVENTS="${fixture}/events"
    RESTORE_TEST_FAIL_AT=''
    RESTORE_TEST_PREFIX='daily/2026/09/01/20260901T030000Z-0123456789abcdef0123456789abcdef'
    RESTORE_TEST_POSTGRES_STARTED=false
    RESTORE_LOCK_FILE="${fixture}/restore.lock"
    export RESTORE_TEST_EVENTS RESTORE_TEST_FAIL_AT RESTORE_TEST_PREFIX
    : > "${RESTORE_TEST_EVENTS}"

    restore_acquire_lock() { event lock; [[ "${RESTORE_TEST_FAIL_AT}" != lock-busy ]] || return 75; }

    restore_preflight() {
        event preflight
        [[ ! -L "${RESTORE_TARGET_ROOT}" ]] || return 20
        if [[ -e "${RESTORE_TARGET_ROOT}" ]]; then
            [[ -d "${RESTORE_TARGET_ROOT}" ]] || return 20
            [[ -z "$(find "${RESTORE_TARGET_ROOT}" -mindepth 1 -print -quit)" ]] || return 20
        fi
        event oci-preflight
    }
    restore_prepare_state() {
        event state
        RESTORE_RUN_ROOT="${RESTORE_STATE_ROOT}/${1}"
        RESTORE_DOWNLOAD_DIR="${RESTORE_RUN_ROOT}/download/${1}"
        RESTORE_MATTERMOST_STAGING="${RESTORE_RUN_ROOT}/mattermost-data"
        RESTORE_QUEUE_QUARANTINE="${RESTORE_RUN_ROOT}/notifier-queue"
        mkdir -p "${RESTORE_DOWNLOAD_DIR}"
    }
    restore_find_set() { event find; printf '%s\n' "${RESTORE_TEST_PREFIX}"; }
    restore_download_manifest() { event download-manifest; }
    restore_validate_downloaded_manifest() {
        event validate-manifest
        [[ "${RESTORE_TEST_FAIL_AT}" != manifest ]]
    }
    restore_download_manifest_artifacts() { event download-artifacts; }
    restore_validate_downloaded_set() {
        event validate-set
        [[ "${RESTORE_TEST_FAIL_AT}" != complete-set ]]
    }
    restore_extract_archives_to_staging() { event extract-staging; }
    restore_recheck_target() { event recheck-target; }
    restore_claim_target() { event claim-target; }
    restore_prepare_target() {
        event prepare-target
        mkdir -p "${RESTORE_TARGET_ROOT}"
    }
    restore_build_notifier() { event build-notifier; }
    restore_verify_built_mailer() {
        event verify-mailer
        [[ "${RESTORE_TEST_FAIL_AT}" != mailer-image ]]
    }
    restore_start_postgres() {
        event start-postgres
        RESTORE_POSTGRES_STARTED=true
    }
    restore_assert_empty_database() {
        event empty-database
        [[ "${RESTORE_TEST_FAIL_AT}" != nonempty-database ]]
    }
    restore_database() {
        event restore-database
        [[ "${RESTORE_TEST_FAIL_AT}" != database ]]
    }
    restore_publish_mattermost() { event publish-mattermost; }
    restore_start_application() {
        event deploy
        [[ "${RESTORE_TEST_FAIL_AT}" != deploy ]]
    }
    restore_verify_disabled_readiness() {
        event verify-disabled
        [[ "${RESTORE_TEST_FAIL_AT}" != disabled-readiness ]]
    }
    restore_release_claim() { event release-claim; }
    restore_stop_partial_postgres() { event stop-postgres; }
}

readonly VALID_ID='20260901T030000Z-0123456789abcdef0123456789abcdef'

test_nonempty_target_is_rejected_before_download() (
    fixture="$(mktemp -d)"
    trap 'rm -rf "${fixture}"' EXIT
    load_fixture "${fixture}"
    mkdir -p "${RESTORE_TARGET_ROOT}"
    printf 'sentinel\n' > "${RESTORE_TARGET_ROOT}/existing"

    ! restore_entry "${VALID_ID}" >"${fixture}/stdout" 2>"${fixture}/stderr"
    [[ "$(<"${RESTORE_TARGET_ROOT}/existing")" == sentinel ]]
    ! grep -Eq '^(find|download-|prepare-target|start-postgres)$' "${RESTORE_TEST_EVENTS}"
)

test_busy_restore_lock_fails_before_preflight() (
    fixture="$(mktemp -d)"
    trap 'rm -rf "${fixture}"' EXIT
    load_fixture "${fixture}"
    RESTORE_TEST_FAIL_AT=lock-busy

    ! restore_entry "${VALID_ID}" >"${fixture}/stdout" 2>"${fixture}/stderr"
    [[ "$(<"${RESTORE_TEST_EVENTS}")" == lock ]]
)

test_unsafe_restore_lock_fails_before_preflight() (
    fixture="$(mktemp -d)"
    trap 'rm -rf "${fixture}"' EXIT
    load_fixture "${fixture}"
    restore_acquire_lock() { return 20; }

    ! restore_entry "${VALID_ID}" >"${fixture}/stdout" 2>"${fixture}/stderr"
    [[ ! -s "${RESTORE_TEST_EVENTS}" ]]
    grep -F '[ACTION REQUIRED] Restore lock is unavailable or unsafe; no target change was made.' \
        "${fixture}/stderr" >/dev/null
)

test_force_option_does_not_exist() (
    fixture="$(mktemp -d)"
    trap 'rm -rf "${fixture}"' EXIT
    load_fixture "${fixture}"

    ! restore_entry --force "${VALID_ID}" >"${fixture}/stdout" 2>"${fixture}/stderr"
    ! restore_entry "${VALID_ID}" --force >>"${fixture}/stdout" 2>>"${fixture}/stderr"
    [[ ! -s "${RESTORE_TEST_EVENTS}" ]]
)

test_invalid_manifest_never_creates_target_root() (
    fixture="$(mktemp -d)"
    trap 'rm -rf "${fixture}"' EXIT
    load_fixture "${fixture}"
    RESTORE_TEST_FAIL_AT=manifest

    ! restore_entry "${VALID_ID}" >"${fixture}/stdout" 2>"${fixture}/stderr"
    [[ ! -e "${RESTORE_TARGET_ROOT}" && ! -L "${RESTORE_TARGET_ROOT}" ]]
    grep -Fx validate-manifest "${RESTORE_TEST_EVENTS}" >/dev/null
    ! grep -Fx download-artifacts "${RESTORE_TEST_EVENTS}" >/dev/null
)

test_valid_restore_orders_every_mutation_and_starts_disabled() (
    fixture="$(mktemp -d)"
    trap 'rm -rf "${fixture}"' EXIT
    load_fixture "${fixture}"

    restore_entry "${VALID_ID}" >"${fixture}/stdout" 2>"${fixture}/stderr"
    expected=$'lock\npreflight\noci-preflight\nstate\nfind\ndownload-manifest\nvalidate-manifest\ndownload-artifacts\nvalidate-set\nextract-staging\nclaim-target\nprepare-target\nbuild-notifier\nverify-mailer\nstart-postgres\nempty-database\nrestore-database\npublish-mattermost\ndeploy\nverify-disabled\nrelease-claim'
    [[ "$(<"${RESTORE_TEST_EVENTS}")" == "${expected}" ]]
    grep -F '[READY] Restore completed with notifier delivery disabled.' "${fixture}/stdout" >/dev/null
    [[ ! -s "${fixture}/stderr" ]]
)

test_target_claim_is_atomic_and_no_clobber() (
    local RESTORE_TARGET_PARENT RESTORE_TARGET_ROOT RESTORE_TARGET_PARENT_IDENTITY
    fixture="$(mktemp -d)"
    trap 'rm -rf "${fixture}"' EXIT
    # shellcheck source=/dev/null
    source "${RESTORE_SCRIPT}"
    RESTORE_TARGET_PARENT="${fixture}/srv"
    # The test intentionally overrides this sourced global inside its isolated subshell.
    # shellcheck disable=SC2030
    RESTORE_TARGET_ROOT="${RESTORE_TARGET_PARENT}/threadhub"
    RESTORE_TARGET_PARENT_IDENTITY='fixture-parent'
    mkdir -p "${RESTORE_TARGET_PARENT}"
    restore_recheck_target() {
        [[ ! -e "${RESTORE_TARGET_ROOT}" ]] || backup_directory_is_empty "${RESTORE_TARGET_ROOT}"
    }
    backup_expected_uid() { id -u; }
    backup_expected_gid() { id -g; }
    backup_link_no_clobber() {
        [[ ! -e "$2" && ! -L "$2" ]] || return 1
        command ln "$1" "$2"
    }

    restore_claim_target
    [[ -f "${RESTORE_TARGET_ROOT}/.threadhub-restore-claim" \
        && ! -L "${RESTORE_TARGET_ROOT}/.threadhub-restore-claim" ]]
    ! restore_claim_target
    restore_release_claim
    [[ ! -e "${RESTORE_TARGET_ROOT}/.threadhub-restore-claim" ]]
)

test_failures_stop_before_the_next_mutation_boundary() (
    for failure in complete-set mailer-image nonempty-database database deploy disabled-readiness; do
        fixture="$(mktemp -d)"
        load_fixture "${fixture}"
        RESTORE_TEST_FAIL_AT="${failure}"
        ! restore_entry "${VALID_ID}" >"${fixture}/stdout" 2>"${fixture}/stderr"
        case "${failure}" in
            complete-set)
                # A prior isolated fixture overrides the same sourced test global.
                # shellcheck disable=SC2031
                [[ ! -e "${RESTORE_TARGET_ROOT}" ]]
                ! grep -Fx prepare-target "${RESTORE_TEST_EVENTS}" >/dev/null
                ;;
            mailer-image)
                ! grep -Fx start-postgres "${RESTORE_TEST_EVENTS}" >/dev/null
                ;;
            nonempty-database)
                ! grep -Fx restore-database "${RESTORE_TEST_EVENTS}" >/dev/null
                grep -Fx stop-postgres "${RESTORE_TEST_EVENTS}" >/dev/null
                ;;
            database)
                ! grep -Fx publish-mattermost "${RESTORE_TEST_EVENTS}" >/dev/null
                grep -Fx stop-postgres "${RESTORE_TEST_EVENTS}" >/dev/null
                ;;
            deploy)
                ! grep -Fx verify-disabled "${RESTORE_TEST_EVENTS}" >/dev/null
                grep -Fx stop-postgres "${RESTORE_TEST_EVENTS}" >/dev/null
                ;;
            disabled-readiness)
                grep -Fx stop-postgres "${RESTORE_TEST_EVENTS}" >/dev/null
                ;;
        esac
        [[ -z "$(grep -E 'customer|@example|channel|threadhub\.internal' \
            "${fixture}/stdout" "${fixture}/stderr" || true)" ]]
        rm -rf "${fixture}"
    done
)

test_manifest_artifact_downloads_are_fixed_and_no_clobber() (
    fixture="$(mktemp -d)"
    trap 'rm -rf "${fixture}"' EXIT
    load_fixture "${fixture}"
    # Reload the concrete helper after the orchestration fixture replaced it.
    # shellcheck source=/dev/null
    source "${RESTORE_SCRIPT}"
    install -d -m 0700 "${fixture}/download"
    backup_oci_download() {
        printf '%s|%s\n' "$1" "$2" >> "${fixture}/downloads"
    }

    restore_download_manifest_artifacts "${RESTORE_TEST_PREFIX}" "${fixture}/download"
    expected="$(printf '%s\n' \
        "${RESTORE_TEST_PREFIX}/database.dump|${fixture}/download/database.dump" \
        "${RESTORE_TEST_PREFIX}/mattermost-data.tar.zst|${fixture}/download/mattermost-data.tar.zst" \
        "${RESTORE_TEST_PREFIX}/notifier-queue.tar.zst|${fixture}/download/notifier-queue.tar.zst")"
    [[ "$(<"${fixture}/downloads")" == "${expected}" ]]
)

test_mailer_image_identity_must_match_manifest() (
    fixture="$(mktemp -d)"
    trap 'rm -rf "${fixture}"' EXIT
    load_fixture "${fixture}"
    mkdir -p "${fixture}/release"
    printf '%s\n' \
        'NOTIFIER_MAILER_IMAGE_ID=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' \
        > "${fixture}/release/release.env"
    printf '%s\n' \
        '{"notifier":{"mailer_image_id":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}' \
        > "${fixture}/manifest.json"

    restore_verify_mailer_image "${fixture}/manifest.json" "${fixture}/release/release.env"
    sed -i.bak 's/aaaaaaaa/bbbbbbbb/' "${fixture}/manifest.json"
    ! restore_verify_mailer_image "${fixture}/manifest.json" "${fixture}/release/release.env"
)

test_prepare_target_rejects_unknown_mailer_emptiness() (
    fixture="$(mktemp -d)"
    trap 'rm -rf "${fixture}"' EXIT
    # shellcheck source=/dev/null
    source "${RESTORE_SCRIPT}"
    RESTORE_TARGET_ROOT="${fixture}/target"
    prepare_threadhub_data_layout() {
        mkdir -p "$1/notifier/mailer"
    }
    ensure_disabled_notifier_control() { return 0; }
    find() { return 2; }

    ! restore_prepare_target
)

test_publish_rejects_unknown_destination_emptiness() (
    fixture="$(mktemp -d)"
    trap 'rm -rf "${fixture}"' EXIT
    # shellcheck source=/dev/null
    source "${RESTORE_SCRIPT}"
    RESTORE_TARGET_ROOT="${fixture}/target"
    RESTORE_BACKUP_ID="${VALID_ID}"
    RESTORE_RUN_ROOT="${fixture}/state/${VALID_ID}"
    RESTORE_MATTERMOST_STAGING="${RESTORE_RUN_ROOT}/mattermost-data"
    mkdir -p "${RESTORE_TARGET_ROOT}/mattermost/data/plugins" \
        "${RESTORE_MATTERMOST_STAGING}"
    printf 'must-not-publish\n' > "${RESTORE_MATTERMOST_STAGING}/attachment.txt"
    find() { return 2; }
    restore_canonicalize_mattermost_publish_roots() { return 0; }
    normalize_threadhub_restored_data() { return 0; }

    ! restore_publish_mattermost
    [[ ! -e "${RESTORE_TARGET_ROOT}/mattermost/data/attachment.txt" ]]
)

test_live_queue_check_rejects_find_failure() (
    fixture="$(mktemp -d)"
    trap 'rm -rf "${fixture}"' EXIT
    # shellcheck source=/dev/null
    source "${RESTORE_SCRIPT}"
    RESTORE_TARGET_ROOT="${fixture}/target"
    RESTORE_QUEUE_QUARANTINE="${fixture}/quarantine"
    mkdir -p "${RESTORE_TARGET_ROOT}/notifier/mailer" "${RESTORE_QUEUE_QUARANTINE}"
    printf 'queue\n' > "${RESTORE_TARGET_ROOT}/notifier/mailer/queue.db"
    find() { return 2; }

    ! restore_live_queue_is_separate
)

test_publish_restores_canonical_data_root_metadata() (
    fixture="$(mktemp -d)"
    trap 'rm -rf "${fixture}"' EXIT
    # shellcheck source=/dev/null
    source "${RESTORE_SCRIPT}"
    RESTORE_TARGET_ROOT="${fixture}/target"
    RESTORE_STATE_ROOT="${fixture}/state/restore"
    RESTORE_BACKUP_ID="${VALID_ID}"
    RESTORE_RUN_ROOT="${RESTORE_STATE_ROOT}/${VALID_ID}"
    RESTORE_MATTERMOST_STAGING="${RESTORE_RUN_ROOT}/mattermost-data"
    install -d -m 0700 \
        "${RESTORE_RUN_ROOT}" \
        "${RESTORE_MATTERMOST_STAGING}/plugins"
    install -d -m 0750 \
        "${RESTORE_TARGET_ROOT}/mattermost/data/plugins"
    printf 'attachment\n' > "${RESTORE_MATTERMOST_STAGING}/attachment.txt"
    chmod 0600 "${RESTORE_MATTERMOST_STAGING}/attachment.txt"
    SUDO_COMMAND=(restore_test_privileged)
    restore_test_privileged() {
        local command_name="$1"
        shift
        case "${command_name}" in
            chown) return 0 ;;
            *) command "${command_name}" "$@" ;;
        esac
    }
    data_layout_validate_root() {
        [[ "$1" == "${RESTORE_TARGET_ROOT}" ]] || return 1
        data_layout_assert_no_symlink_components "$1" || return 1
        [[ "$(portable_mode "${RESTORE_TARGET_ROOT}/mattermost/data")" == 750 \
            && "$(portable_mode "${RESTORE_TARGET_ROOT}/mattermost/data/plugins")" == 750 ]]
    }

    restore_publish_mattermost

    [[ "$(<"${RESTORE_TARGET_ROOT}/mattermost/data/attachment.txt")" == attachment ]]
    [[ "$(portable_mode "${RESTORE_TARGET_ROOT}/mattermost/data")" == 750 ]]
    [[ "$(portable_mode "${RESTORE_TARGET_ROOT}/mattermost/data/plugins")" == 750 ]]
    [[ "$(portable_mode "${RESTORE_TARGET_ROOT}/mattermost/data/attachment.txt")" == 640 ]]
)

test_restore_has_no_remote_or_destructive_escape_hatch() (
    [[ -f "${RESTORE_SCRIPT}" ]]
    ! grep -Eq 'backup_oci_(upload|delete)|os object (put|delete)|--force|rm -rf.*threadhub' \
        "${RESTORE_SCRIPT}"
    grep -F 'notifier-queue' "${RESTORE_SCRIPT}" >/dev/null
    grep -F 'delivery_enabled == false' "${RESTORE_SCRIPT}" >/dev/null
)

run_test 'nonempty target is rejected before remote download' test_nonempty_target_is_rejected_before_download
run_test 'busy restore lock fails before preflight' test_busy_restore_lock_fails_before_preflight
run_test 'unsafe restore lock fails before preflight' test_unsafe_restore_lock_fails_before_preflight
run_test 'restore has no force option' test_force_option_does_not_exist
run_test 'invalid manifest never creates the target root' test_invalid_manifest_never_creates_target_root
run_test 'valid restore orders mutations and starts disabled' test_valid_restore_orders_every_mutation_and_starts_disabled
run_test 'restore target claim is atomic and no-clobber' test_target_claim_is_atomic_and_no_clobber
run_test 'faults stop before the next restore boundary' test_failures_stop_before_the_next_mutation_boundary
run_test 'manifest artifacts use fixed no-clobber download names' test_manifest_artifact_downloads_are_fixed_and_no_clobber
run_test 'rebuilt Mailer identity must match the manifest' test_mailer_image_identity_must_match_manifest
run_test 'target preparation rejects unknown Mailer emptiness' \
    test_prepare_target_rejects_unknown_mailer_emptiness
run_test 'Mattermost publish rejects unknown destination emptiness' \
    test_publish_rejects_unknown_destination_emptiness
run_test 'live queue validation rejects find failures' test_live_queue_check_rejects_find_failure
run_test 'publish restores canonical Mattermost data-root metadata' \
    test_publish_restores_canonical_data_root_metadata
run_test 'restore has no remote mutation or destructive escape hatch' test_restore_has_no_remote_or_destructive_escape_hatch

if ((failures > 0)); then
    printf '%d backup restore test(s) failed\n' "${failures}" >&2
    exit 1
fi
