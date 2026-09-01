#!/usr/bin/env bash

# Fixture callbacks are invoked indirectly by the backup artifact library.
# Negative assertions intentionally use `! command` inside isolated tests.
# shellcheck disable=SC2034,SC2251,SC2329

set -Eeuo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(cd "${TEST_DIR}/.." && pwd)"
BACKUP_COMMON="${DEPLOY_DIR}/scripts/backup-common.sh"
BACKUP_ARTIFACTS="${DEPLOY_DIR}/scripts/backup-artifacts.sh"
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

write_versions() {
    cat > "$1" <<'EOF'
MATTERMOST_IMAGE_REPOSITORY=mattermost/mattermost-team-edition
MATTERMOST_IMAGE_TAG=11.7.7
MATTERMOST_IMAGE_DIGEST=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
POSTGRES_IMAGE_REPOSITORY=postgres
POSTGRES_IMAGE_TAG=18.4
POSTGRES_IMAGE_DIGEST=sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
NOTIFIER_VERSION=0.1.0
EOF
}

write_release() {
    local path="$1" source_commit="$2"

    cat > "${path}" <<EOF
NOTIFIER_VERSION=0.1.0
NOTIFIER_PLUGIN_ID=com.threadhub.channel-email-notifier
NOTIFIER_PLUGIN_BUNDLE=notifier/dist/com.threadhub.channel-email-notifier-0.1.0.tar.gz
NOTIFIER_PLUGIN_BUNDLE_SHA256=cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
NOTIFIER_MAILER_IMAGE=threadhub/notifier-mailer:0.1.0
NOTIFIER_MAILER_IMAGE_ID=sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd
NOTIFIER_SOURCE_COMMIT=${source_commit}
EOF
    chmod 0640 "${path}"
}

create_git_fixture() {
    local repository="$1"

    mkdir -p "${repository}"
    git -C "${repository}" init -q
    printf 'tracked\n' > "${repository}/tracked.txt"
    git -C "${repository}" add tracked.txt
    git -C "${repository}" -c user.name=ThreadHub -c user.email=threadhub@example.invalid \
        commit -q -m fixture
}

fixture_compose() {
    printf '%s\n' "$*" >> "${BACKUP_TEST_COMPOSE_TRACE}"
    [[ "$*" == 'exec -T postgres pg_dump --format=custom --no-owner --no-acl --username threadhub --dbname threadhub' ]]
    printf 'PGDMPfixture\n'
}

load_fixture() {
    local fixture="$1" source_commit

    [[ -f "${BACKUP_COMMON}" && -f "${BACKUP_ARTIFACTS}" ]] || return 1
    create_git_fixture "${fixture}/repository"
    source_commit="$(git -C "${fixture}/repository" rev-parse HEAD)"
    mkdir -p \
        "${fixture}/data/mattermost/data/자료" \
        "${fixture}/data/notifier/mailer" \
        "${fixture}/release" \
        "${fixture}/sets"
    printf 'attachment\n' > "${fixture}/data/mattermost/data/자료/고객 파일.txt"
    printf 'queue\n' > "${fixture}/data/notifier/mailer/queue.db"
    printf 'wal\n' > "${fixture}/data/notifier/mailer/queue.db-wal"
    write_versions "${fixture}/versions.env"
    write_release "${fixture}/release/release.env" "${source_commit}"
    printf '%s\n' 'POSTGRES_USER=threadhub' 'POSTGRES_DB=threadhub' > "${fixture}/runtime.env"
    chmod 0600 "${fixture}/runtime.env"

    # shellcheck source=/dev/null
    source "${BACKUP_COMMON}"
    # shellcheck source=/dev/null
    source "${BACKUP_ARTIFACTS}"
    backup_expected_uid() { id -u; }
    backup_expected_gid() { id -g; }
    backup_require_gnu_tar() { :; }
    compose() { fixture_compose "$@"; }
    REPOSITORY_ROOT="${fixture}/repository"
    VERSIONS_FILE="${fixture}/versions.env"
    ENV_FILE="${fixture}/runtime.env"
    BACKUP_ARTIFACT_DATA_ROOT="${fixture}/data"
    BACKUP_ARTIFACT_RELEASE_FILE="${fixture}/release/release.env"
    # bsdtar lacks GNU --quoting-style; `--` is a no-op list terminator here.
    BACKUP_TAR_QUOTING_ARGS=(--)
    BACKUP_TEST_COMPOSE_TRACE="${fixture}/compose.trace"
    export BACKUP_TEST_COMPOSE_TRACE
    : > "${BACKUP_TEST_COMPOSE_TRACE}"
}

prepare_valid_set() {
    local fixture="$1" backup_id="$2" set_dir

    set_dir="${fixture}/sets/${backup_id}"
    install -d -m 0700 "${set_dir}"
    backup_create_artifacts "${set_dir}" >/dev/null 2>&1 || return
    backup_write_manifest "${set_dir}" >/dev/null 2>&1 || return
    printf '%s\n' "${set_dir}"
}

make_malicious_archive() {
    local archive="$1" kind="$2" raw_archive

    raw_archive="${archive%.zst}"
    python3 - "${raw_archive}" "${kind}" <<'PY'
import io
import sys
import tarfile

target, kind = sys.argv[1:]
with tarfile.open(target, "w", format=tarfile.PAX_FORMAT) as bundle:
    if kind == "parent":
        info = tarfile.TarInfo("../escape")
        payload = b"escape\n"
        info.size = len(payload)
        bundle.addfile(info, io.BytesIO(payload))
    elif kind == "absolute":
        info = tarfile.TarInfo("/absolute")
        payload = b"absolute\n"
        info.size = len(payload)
        bundle.addfile(info, io.BytesIO(payload))
    elif kind == "symlink":
        info = tarfile.TarInfo("safe/link")
        info.type = tarfile.SYMTYPE
        info.linkname = "/etc/shadow"
        bundle.addfile(info)
    elif kind == "hardlink":
        info = tarfile.TarInfo("safe/hard")
        info.type = tarfile.LNKTYPE
        info.linkname = "safe/file"
        bundle.addfile(info)
    elif kind == "fifo":
        info = tarfile.TarInfo("safe/fifo")
        info.type = tarfile.FIFOTYPE
        bundle.addfile(info)
    elif kind == "device":
        info = tarfile.TarInfo("safe/device")
        info.type = tarfile.CHRTYPE
        info.devmajor = 1
        info.devminor = 3
        bundle.addfile(info)
    elif kind == "socket":
        info = tarfile.TarInfo("safe/socket")
        info.type = b"s"
        bundle.addfile(info)
    elif kind == "duplicate":
        for payload in (b"first\n", b"second\n"):
            info = tarfile.TarInfo("safe/file")
            info.size = len(payload)
            bundle.addfile(info, io.BytesIO(payload))
    elif kind == "queue-extra":
        info = tarfile.TarInfo("customer-secret.txt")
        payload = b"secret\n"
        info.size = len(payload)
        bundle.addfile(info, io.BytesIO(payload))
    else:
        raise SystemExit("unknown fixture")
PY
    zstd -q -f "${raw_archive}" -o "${archive}"
    rm -f "${raw_archive}"
    chmod 0600 "${archive}"
}

readonly VALID_ID='20260901T030000Z-0123456789abcdef0123456789abcdef'

test_generated_id_is_private_and_strict() (
    fixture="$(mktemp -d)"
    trap 'rm -rf "${fixture}"' EXIT
    load_fixture "${fixture}"

    generated_id="$(backup_generate_id)"
    [[ "${generated_id}" =~ ^[0-9]{8}T[0-9]{6}Z-[a-f0-9]{32}$ ]]
    [[ "${generated_id}" != *threadhub* && "${generated_id}" != *@* ]]
)

test_gnu_tar_positional_options_precede_file_list() (
    local no_recursion_line files_from_line

    no_recursion_line="$(grep -n -m1 -- '--directory .* --no-recursion' \
        "${BACKUP_ARTIFACTS}" | cut -d: -f1)"
    files_from_line="$(grep -n -m1 -- '--null --files-from' \
        "${BACKUP_ARTIFACTS}" | cut -d: -f1)"
    [[ -n "${no_recursion_line}" && -n "${files_from_line}" \
        && "${no_recursion_line}" -lt "${files_from_line}" ]]
)

test_artifact_creation_uses_fixed_sources_and_names() (
    fixture="$(mktemp -d)"
    trap 'rm -rf "${fixture}"' EXIT
    load_fixture "${fixture}"
    set_dir="${fixture}/sets/${VALID_ID}"
    install -d -m 0700 "${set_dir}"

    backup_create_artifacts "${set_dir}" >"${fixture}/stdout" 2>"${fixture}/stderr"
    [[ ! -s "${fixture}/stdout" && ! -s "${fixture}/stderr" ]]
    [[ "$(find "${set_dir}" -mindepth 1 -maxdepth 1 -type f -exec basename {} \; | LC_ALL=C sort | paste -sd, -)" \
        == 'database.dump,mattermost-data.tar.zst,notifier-queue.tar.zst' ]]
    grep -F 'pg_dump --format=custom --no-owner --no-acl' "${BACKUP_TEST_COMPOSE_TRACE}" >/dev/null
    ! tar --list --zstd --file "${set_dir}/notifier-queue.tar.zst" | grep -vE '^(queue\.db|queue\.db-wal)$'
    ! grep -F '고객 파일.txt' "${fixture}/stdout" "${fixture}/stderr"
)

test_manifest_has_exact_schema_and_provenance() (
    fixture="$(mktemp -d)"
    trap 'rm -rf "${fixture}"' EXIT
    load_fixture "${fixture}"
    set_dir="$(prepare_valid_set "${fixture}" "${VALID_ID}")"
    source_commit="$(git -C "${REPOSITORY_ROOT}" rev-parse HEAD)"

    jq -e --arg id "${VALID_ID}" --arg commit "${source_commit}" '
      keys == ["artifacts","backup_id","created_at","images","notifier","schema_version","source_commit"] and
      .schema_version == 1 and .backup_id == $id and .created_at == "2026-09-01T03:00:00Z" and
      .source_commit == $commit and
      .images.mattermost == {
        repository:"mattermost/mattermost-team-edition", tag:"11.7.7",
        digest:"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
      } and
      .images.postgres == {
        repository:"postgres", tag:"18.4",
        digest:"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
      } and
      .notifier == {
        version:"0.1.0",
        mailer_image_id:"sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
      } and
      (.artifacts | map(.name) == ["database.dump","mattermost-data.tar.zst","notifier-queue.tar.zst"]) and
      (.artifacts | all(.bytes > 0 and (.sha256 | test("^[a-f0-9]{64}$"))))
    ' "${set_dir}/manifest.json" >/dev/null
    [[ "$(<"${set_dir}/manifest.sha256")" == "$(sha256_file "${set_dir}/manifest.json")  manifest.json" ]]
    backup_validate_manifest_identity "${set_dir}" "${VALID_ID}"
    backup_validate_set "${set_dir}" "${VALID_ID}"
)

test_git_provenance_never_takes_optional_repository_locks() (
    # shellcheck source=/dev/null
    source "${BACKUP_COMMON}"
    # shellcheck source=/dev/null
    source "${BACKUP_ARTIFACTS}"
    git() {
        [[ "${GIT_OPTIONAL_LOCKS:-}" == 0 ]] || return 1
        if [[ "$*" == *'rev-parse --verify HEAD^{commit}'* ]]; then
            printf '%s\n' aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
        fi
    }

    [[ "$(backup_artifact_git_commit)" == aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ]]
)

test_corrupt_extra_and_mismatched_sets_fail_closed() (
    fixture="$(mktemp -d)"
    trap 'rm -rf "${fixture}"' EXIT
    load_fixture "${fixture}"

    set_dir="$(prepare_valid_set "${fixture}" "${VALID_ID}")"
    printf 'tamper\n' >> "${set_dir}/manifest.json"
    ! backup_validate_set "${set_dir}" "${VALID_ID}" >"${fixture}/stdout" 2>"${fixture}/stderr"

    rm -rf "${set_dir}"
    set_dir="$(prepare_valid_set "${fixture}" "${VALID_ID}")"
    printf 'tamper\n' >> "${set_dir}/database.dump"
    ! backup_validate_set "${set_dir}" "${VALID_ID}" >>"${fixture}/stdout" 2>>"${fixture}/stderr"

    rm -rf "${set_dir}"
    set_dir="$(prepare_valid_set "${fixture}" "${VALID_ID}")"
    printf 'extra\n' > "${set_dir}/extra.txt"
    ! backup_validate_set "${set_dir}" "${VALID_ID}" >>"${fixture}/stdout" 2>>"${fixture}/stderr"

    ! backup_validate_set "${set_dir}" '20260901T030000Z-ffffffffffffffffffffffffffffffff' \
        >>"${fixture}/stdout" 2>>"${fixture}/stderr"

    rm -rf "${set_dir}"
    set_dir="$(prepare_valid_set "${fixture}" "${VALID_ID}")"
    jq '.unexpected = true' "${set_dir}/manifest.json" > "${set_dir}/manifest.replacement"
    chmod 0600 "${set_dir}/manifest.replacement"
    mv "${set_dir}/manifest.replacement" "${set_dir}/manifest.json"
    printf '%s  manifest.json\n' "$(sha256_file "${set_dir}/manifest.json")" > "${set_dir}/manifest.sha256"
    ! backup_validate_set "${set_dir}" "${VALID_ID}" >>"${fixture}/stdout" 2>>"${fixture}/stderr"
    [[ ! -s "${fixture}/stdout" && ! -s "${fixture}/stderr" ]]
)

test_dirty_or_mismatched_provenance_is_rejected() (
    fixture="$(mktemp -d)"
    trap 'rm -rf "${fixture}"' EXIT
    load_fixture "${fixture}"
    set_dir="${fixture}/sets/${VALID_ID}"
    install -d -m 0700 "${set_dir}"
    backup_create_artifacts "${set_dir}"

    printf 'dirty\n' >> "${REPOSITORY_ROOT}/tracked.txt"
    ! backup_write_manifest "${set_dir}" >"${fixture}/stdout" 2>"${fixture}/stderr"
    [[ ! -e "${set_dir}/manifest.json" && ! -e "${set_dir}/manifest.sha256" ]]
    git -C "${REPOSITORY_ROOT}" restore tracked.txt

    sed 's/^NOTIFIER_SOURCE_COMMIT=.*/NOTIFIER_SOURCE_COMMIT=ffffffffffffffffffffffffffffffffffffffff/' \
        "${BACKUP_ARTIFACT_RELEASE_FILE}" > "${fixture}/release/replacement"
    chmod 0640 "${fixture}/release/replacement"
    mv "${fixture}/release/replacement" "${BACKUP_ARTIFACT_RELEASE_FILE}"
    ! backup_write_manifest "${set_dir}" >>"${fixture}/stdout" 2>>"${fixture}/stderr"
    [[ ! -e "${set_dir}/manifest.json" && ! -e "${set_dir}/manifest.sha256" ]]
    [[ ! -s "${fixture}/stdout" && ! -s "${fixture}/stderr" ]]
)

test_restore_compatibility_does_not_require_live_release() (
    fixture="$(mktemp -d)"
    trap 'rm -rf "${fixture}"' EXIT
    load_fixture "${fixture}"
    set_dir="$(prepare_valid_set "${fixture}" "${VALID_ID}")"

    mv "${BACKUP_ARTIFACT_RELEASE_FILE}" "${BACKUP_ARTIFACT_RELEASE_FILE}.absent"
    backup_validate_manifest_compatibility "${set_dir}" "${VALID_ID}"
    backup_validate_set_compatibility "${set_dir}" "${VALID_ID}"
    ! backup_validate_manifest_identity "${set_dir}" "${VALID_ID}" \
        >"${fixture}/stdout" 2>"${fixture}/stderr"
    ! backup_validate_set "${set_dir}" "${VALID_ID}" \
        >>"${fixture}/stdout" 2>>"${fixture}/stderr"
    [[ ! -s "${fixture}/stdout" && ! -s "${fixture}/stderr" ]]
)

test_restore_compatibility_rejects_source_and_image_mismatch() (
    fixture="$(mktemp -d)"
    trap 'rm -rf "${fixture}"' EXIT
    load_fixture "${fixture}"

    for mutation in source mattermost postgres notifier; do
        rm -rf "${fixture}/sets/${VALID_ID}"
        set_dir="$(prepare_valid_set "${fixture}" "${VALID_ID}")"
        case "${mutation}" in
            source) jq '.source_commit = ("f" * 40)' "${set_dir}/manifest.json" ;;
            mattermost) jq '.images.mattermost.digest = ("sha256:" + ("e" * 64))' "${set_dir}/manifest.json" ;;
            postgres) jq '.images.postgres.tag = "18.5"' "${set_dir}/manifest.json" ;;
            notifier) jq '.notifier.version = "0.1.1"' "${set_dir}/manifest.json" ;;
        esac > "${set_dir}/replacement"
        chmod 0600 "${set_dir}/replacement"
        mv "${set_dir}/replacement" "${set_dir}/manifest.json"
        printf '%s  manifest.json\n' "$(sha256_file "${set_dir}/manifest.json")" \
            > "${set_dir}/manifest.sha256"
        ! backup_validate_manifest_compatibility "${set_dir}" "${VALID_ID}" \
            >"${fixture}/stdout" 2>"${fixture}/stderr"
    done
    [[ ! -s "${fixture}/stdout" && ! -s "${fixture}/stderr" ]]
)

test_restore_set_rejects_missing_artifact() (
    fixture="$(mktemp -d)"
    trap 'rm -rf "${fixture}"' EXIT
    load_fixture "${fixture}"
    set_dir="$(prepare_valid_set "${fixture}" "${VALID_ID}")"
    rm "${set_dir}/database.dump"

    ! backup_validate_set_compatibility "${set_dir}" "${VALID_ID}" \
        >"${fixture}/stdout" 2>"${fixture}/stderr"
    [[ ! -s "${fixture}/stdout" && ! -s "${fixture}/stderr" ]]
)

test_unsafe_archives_are_rejected_before_extraction() (
    fixture="$(mktemp -d)"
    trap 'rm -rf "${fixture}"' EXIT
    load_fixture "${fixture}"

    install -d -m 0700 "${fixture}/safe" "${fixture}/safe-extract"
    safe_archive="${fixture}/safe/mattermost-data.tar.zst"
    backup_create_archive "${BACKUP_ARTIFACT_DATA_ROOT}/mattermost/data" "${safe_archive}"
    backup_validate_archive "${safe_archive}"
    backup_extract_archive "${safe_archive}" "${fixture}/safe-extract"
    [[ "$(<"${fixture}/safe-extract/자료/고객 파일.txt")" == attachment ]]

    install -d -m 0700 "${fixture}/empty-source" "${fixture}/empty" "${fixture}/empty-extract"
    empty_archive="${fixture}/empty/mattermost-data.tar.zst"
    backup_create_archive "${fixture}/empty-source" "${empty_archive}"
    backup_validate_archive "${empty_archive}"
    backup_extract_archive "${empty_archive}" "${fixture}/empty-extract"
    [[ -z "$(find "${fixture}/empty-extract" -mindepth 1 -print -quit)" ]]

    for kind in parent absolute symlink hardlink fifo device socket duplicate; do
        install -d -m 0700 "${fixture}/${kind}" "${fixture}/${kind}-extract"
        archive="${fixture}/${kind}/mattermost-data.tar.zst"
        make_malicious_archive "${archive}" "${kind}"
        ! backup_validate_archive "${archive}" >"${fixture}/stdout" 2>"${fixture}/stderr"
        ! backup_extract_archive "${archive}" "${fixture}/${kind}-extract" \
            >>"${fixture}/stdout" 2>>"${fixture}/stderr"
        [[ -z "$(find "${fixture}/${kind}-extract" -mindepth 1 -print -quit)" ]]
    done
    [[ ! -s "${fixture}/stdout" && ! -s "${fixture}/stderr" ]]
)

test_queue_archive_rejects_any_non_sqlite_member() (
    fixture="$(mktemp -d)"
    trap 'rm -rf "${fixture}"' EXIT
    load_fixture "${fixture}"
    archive="${fixture}/notifier-queue.tar.zst"
    make_malicious_archive "${archive}" queue-extra

    ! backup_validate_archive "${archive}" >"${fixture}/stdout" 2>"${fixture}/stderr"
    [[ ! -s "${fixture}/stdout" && ! -s "${fixture}/stderr" ]]
)

run_test 'generated backup ID is private and strict' test_generated_id_is_private_and_strict
run_test 'GNU tar positional options precede the file list' test_gnu_tar_positional_options_precede_file_list
run_test 'artifact creation uses only fixed sources and names' test_artifact_creation_uses_fixed_sources_and_names
run_test 'manifest has exact schema provenance and a valid set' test_manifest_has_exact_schema_and_provenance
run_test 'Git provenance never takes optional repository locks' \
    test_git_provenance_never_takes_optional_repository_locks
run_test 'corrupt extra and mismatched sets fail closed' test_corrupt_extra_and_mismatched_sets_fail_closed
run_test 'dirty or mismatched provenance is rejected' test_dirty_or_mismatched_provenance_is_rejected
run_test 'restore compatibility does not require a live notifier release' test_restore_compatibility_does_not_require_live_release
run_test 'restore compatibility rejects source and image mismatch' test_restore_compatibility_rejects_source_and_image_mismatch
run_test 'restore set rejects a missing artifact' test_restore_set_rejects_missing_artifact
run_test 'unsafe archives fail before extraction' test_unsafe_archives_are_rejected_before_extraction
run_test 'queue archive rejects every non-SQLite member' test_queue_archive_rejects_any_non_sqlite_member

if ((failures > 0)); then
    printf '%d backup artifact test(s) failed\n' "${failures}" >&2
    exit 1
fi
