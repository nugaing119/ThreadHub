#!/usr/bin/env bash

# Stub callbacks and sourced globals are invoked indirectly by the transport.
# Negative assertions intentionally use `! command` inside isolated test shells.
# shellcheck disable=SC2034,SC2251,SC2329

set -Eeuo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(cd "${TEST_DIR}/.." && pwd)"
BACKUP_COMMON="${DEPLOY_DIR}/scripts/backup-common.sh"
BACKUP_OCI="${DEPLOY_DIR}/scripts/backup-oci.sh"
failures=0
readonly PRIVATE_OCI_MARKER='ocid1''.''instance.oc1..private'

fail() { printf 'not ok - %s\n' "$1" >&2; failures=$((failures + 1)); }
pass() { printf 'ok - %s\n' "$1"; }

run_test() {
    local name="$1" function_name="$2" status
    set +e
    ( set -Eeuo pipefail; "${function_name}" )
    status=$?
    set -e
    if ((status == 0)); then pass "${name}"; else fail "${name}"; fi
}

write_config() {
    printf '%s\n' \
        'BACKUP_REGION=ap-singapore-1' \
        'BACKUP_NAMESPACE=namespace123' \
        'BACKUP_BUCKET=threadhub-backup-01' \
        'BACKUP_ALERT_EMAIL=backup-admin@threadhub.invalid' \
        'BACKUP_SCHEDULE=03:00' \
        'BACKUP_DAILY_RETENTION_DAYS=7' \
        'BACKUP_WEEKLY_RETENTION_DAYS=28' > "$1"
    chmod 0600 "$1"
}

arg_value() {
    local wanted="$1"
    shift
    while (($# > 0)); do
        if [[ "$1" == "${wanted}" && $# -ge 2 ]]; then
            printf '%s\n' "$2"
            return
        fi
        shift
    done
    return 1
}

oci_stub() {
    local destination

    printf '%q ' "$@" >> "${OCI_STUB_TRACE}"
    printf '\n' >> "${OCI_STUB_TRACE}"
    [[ " $* " == *' --auth instance_principal '* ]]
    [[ " $* " == *' --region ap-singapore-1 '* ]]
    [[ " $* " == *' --output json '* ]]
    if [[ "${OCI_STUB_FAIL:-}" == yes ]]; then
        printf 'private failure %s user@example.invalid\n' "${PRIVATE_OCI_MARKER}" >&2
        return 42
    fi
    case "$1 $2 $3" in
        'os ns get')
            printf '{"data":"%s"}\n' "${OCI_STUB_NAMESPACE:-namespace123}"
            ;;
        'os bucket get')
            [[ "$(arg_value --namespace-name "$@")" == namespace123 ]]
            [[ "$(arg_value --name "$@")" == threadhub-backup-01 ]]
            printf '{"data":{"name":"threadhub-backup-01","public-access-type":"NoPublicAccess"}}\n'
            ;;
        'os object put')
            printf '{"etag":"fixture"}\n'
            ;;
        'os object head')
            printf '{"content-length":%s,"opc-content-sha256":"fixture","opc-meta-threadhub-sha256":"%s"}\n' \
                "${OCI_STUB_HEAD_LENGTH}" "${OCI_STUB_HEAD_SHA256}"
            ;;
        'os object list')
            oci_stub_list "$@"
            ;;
        'os object get')
            destination="$(arg_value --file "$@")"
            cp "${OCI_STUB_DOWNLOAD_SOURCE}" "${destination}"
            printf '{}\n'
            ;;
        *) return 43 ;;
    esac
}

oci_stub_list() {
    local prefix page
    prefix="$(arg_value --prefix "$@")"
    page="$(arg_value --page "$@" 2>/dev/null || true)"
    case "${OCI_STUB_LIST_MODE:-paginated}:${prefix}:${page}" in
        paginated:daily/:)
            printf '{"data":[{"name":"daily/not-a-date/private-name"},{"name":"daily/2026/09/01/%s/manifest.json"}],"opc-next-page":"page-2"}\n' "${VALID_ID}"
            ;;
        paginated:daily/:page-2)
            printf '{"data":[{"name":"daily/2026/09/01/%s/database.dump"}]}\n' "${VALID_ID}"
            ;;
        weekly-only:daily/:)
            printf '{"data":[]}\n'
            ;;
        weekly-only:weekly/:)
            printf '{"data":[{"name":"weekly/2026/08/30/%s/manifest.json"}]}\n' "${VALID_ID}"
            ;;
        duplicate:daily/:)
            printf '{"data":[{"name":"daily/2026/09/01/%s/manifest.json"},{"name":"daily/2026/09/02/%s/manifest.json"}]}\n' "${VALID_ID}" "${VALID_ID}"
            ;;
        *)
            printf '{"data":[]}\n'
            ;;
    esac
}

backup_test_link_no_clobber() {
    [[ ! -e "$2" && ! -L "$2" ]] || return 1
    command ln "$1" "$2"
}

load_fixture() {
    local fixture="$1"
    write_config "${fixture}/backup.env"
    THREADHUB_BACKUP_ENV_FILE="${fixture}/backup.env"
    export THREADHUB_BACKUP_ENV_FILE
    [[ -f "${BACKUP_COMMON}" && -f "${BACKUP_OCI}" ]] || return 1
    # shellcheck source=/dev/null
    source "${BACKUP_COMMON}"
    # shellcheck source=/dev/null
    source "${BACKUP_OCI}"
    backup_expected_uid() { id -u; }
    backup_expected_gid() { id -g; }
    backup_link_no_clobber() { backup_test_link_no_clobber "$@"; }
    OCI_COMMAND=(oci_stub)
    OCI_STUB_TRACE="${fixture}/oci.trace"
    export OCI_STUB_TRACE
    : > "${OCI_STUB_TRACE}"
}

readonly VALID_ID='20260901T030000Z-0123456789abcdef0123456789abcdef'
readonly VALID_KEY="daily/2026/09/01/${VALID_ID}/database.dump"

test_preflight_uses_only_fixed_instance_principal_target() (
    fixture="$(mktemp -d)"
    trap 'rm -rf "${fixture}"' EXIT
    load_fixture "${fixture}"

    backup_oci_preflight >"${fixture}/stdout" 2>"${fixture}/stderr"
    [[ "$(wc -l < "${OCI_STUB_TRACE}" | tr -d ' ')" == 2 ]]
    grep -F 'os ns get' "${OCI_STUB_TRACE}" >/dev/null
    grep -F 'os bucket get' "${OCI_STUB_TRACE}" >/dev/null
    ! grep -F 'other-bucket' "${OCI_STUB_TRACE}"
    [[ ! -s "${fixture}/stdout" && ! -s "${fixture}/stderr" ]]
)

test_upload_is_immutable_checksummed_and_exact_bucket() (
    fixture="$(mktemp -d)"
    trap 'rm -rf "${fixture}"' EXIT
    load_fixture "${fixture}"
    artifact="${fixture}/database.dump"
    printf 'logical-backup\n' > "${artifact}"
    chmod 0600 "${artifact}"
    sha="$(sha256_file "${artifact}")"

    backup_oci_upload "${artifact}" "${VALID_KEY}" "${sha}"
    grep -F -- '--bucket-name threadhub-backup-01' "${OCI_STUB_TRACE}" >/dev/null
    grep -F -- '--no-overwrite' "${OCI_STUB_TRACE}" >/dev/null
    grep -F -- '--verify-checksum' "${OCI_STUB_TRACE}" >/dev/null
    grep -F -- '--opc-checksum-algorithm SHA256' "${OCI_STUB_TRACE}" >/dev/null
    grep -F -- "threadhub-sha256" "${OCI_STUB_TRACE}" >/dev/null
    ! grep -E ' object delete | bulk-delete | bucket delete ' "${OCI_STUB_TRACE}"

    : > "${OCI_STUB_TRACE}"
    ! backup_oci_upload "${artifact}" '../other-bucket/object' "${sha}"
    [[ ! -s "${OCI_STUB_TRACE}" ]]
)

test_head_verification_rejects_size_or_metadata_mismatch() (
    fixture="$(mktemp -d)"
    trap 'rm -rf "${fixture}"' EXIT
    load_fixture "${fixture}"
    artifact="${fixture}/database.dump"
    printf 'logical-backup\n' > "${artifact}"
    sha="$(sha256_file "${artifact}")"
    size="$(wc -c < "${artifact}" | tr -d ' ')"
    OCI_STUB_HEAD_LENGTH="${size}"
    OCI_STUB_HEAD_SHA256="${sha}"
    export OCI_STUB_HEAD_LENGTH OCI_STUB_HEAD_SHA256

    backup_oci_verify "${VALID_KEY}" "${size}" "${sha}"
    OCI_STUB_HEAD_LENGTH=1
    export OCI_STUB_HEAD_LENGTH
    ! backup_oci_verify "${VALID_KEY}" "${size}" "${sha}"
    OCI_STUB_HEAD_LENGTH="${size}"
    OCI_STUB_HEAD_SHA256=wrong
    export OCI_STUB_HEAD_LENGTH OCI_STUB_HEAD_SHA256
    ! backup_oci_verify "${VALID_KEY}" "${size}" "${sha}"
)

test_set_discovery_paginates_and_falls_back_to_weekly() (
    fixture="$(mktemp -d)"
    trap 'rm -rf "${fixture}"' EXIT
    load_fixture "${fixture}"
    export VALID_ID

    OCI_STUB_LIST_MODE=paginated
    export OCI_STUB_LIST_MODE
    prefix="$(backup_oci_find_set "${VALID_ID}")"
    [[ "${prefix}" == "daily/2026/09/01/${VALID_ID}" ]]
    grep -F -- '--page page-2' "${OCI_STUB_TRACE}" >/dev/null

    : > "${OCI_STUB_TRACE}"
    OCI_STUB_LIST_MODE=weekly-only
    export OCI_STUB_LIST_MODE
    prefix="$(backup_oci_find_set "${VALID_ID}")"
    [[ "${prefix}" == "weekly/2026/08/30/${VALID_ID}" ]]
    grep -F -- '--prefix daily/' "${OCI_STUB_TRACE}" >/dev/null
    grep -F -- '--prefix weekly/' "${OCI_STUB_TRACE}" >/dev/null

    OCI_STUB_LIST_MODE=duplicate
    export OCI_STUB_LIST_MODE
    ! backup_oci_find_set "${VALID_ID}" >"${fixture}/stdout" 2>"${fixture}/stderr"
    [[ ! -s "${fixture}/stdout" && ! -s "${fixture}/stderr" ]]
)

test_download_is_no_clobber_and_failures_are_private() (
    fixture="$(mktemp -d)"
    trap 'rm -rf "${fixture}"' EXIT
    load_fixture "${fixture}"
    download_dir="${fixture}/download"
    install -d -m 0700 "${download_dir}"
    OCI_STUB_DOWNLOAD_SOURCE="${fixture}/remote-object"
    export OCI_STUB_DOWNLOAD_SOURCE
    printf 'remote-data\n' > "${OCI_STUB_DOWNLOAD_SOURCE}"
    destination="${download_dir}/database.dump"

    backup_oci_download "${VALID_KEY}" "${destination}"
    [[ "$(<"${destination}")" == remote-data ]]
    printf 'sentinel\n' > "${destination}"
    ! backup_oci_download "${VALID_KEY}" "${destination}"
    [[ "$(<"${destination}")" == sentinel ]]

    rm -f "${destination}"
    OCI_STUB_FAIL=yes
    export OCI_STUB_FAIL
    ! backup_oci_download "${VALID_KEY}" "${destination}" >"${fixture}/stdout" 2>"${fixture}/stderr"
    [[ ! -e "${destination}" ]]
    ! grep -F "${PRIVATE_OCI_MARKER}" "${fixture}/stdout" "${fixture}/stderr"
    ! grep -F 'user@example.invalid' "${fixture}/stdout" "${fixture}/stderr"
)

test_namespace_mismatch_is_rejected_without_diagnostics() (
    fixture="$(mktemp -d)"
    trap 'rm -rf "${fixture}"' EXIT
    load_fixture "${fixture}"
    OCI_STUB_NAMESPACE=othernamespace
    export OCI_STUB_NAMESPACE
    ! backup_oci_preflight >"${fixture}/stdout" 2>"${fixture}/stderr"
    [[ ! -s "${fixture}/stdout" && ! -s "${fixture}/stderr" ]]
)

run_test 'OCI preflight uses only the configured Instance Principal target' test_preflight_uses_only_fixed_instance_principal_target
run_test 'OCI upload is immutable checksummed and exact-bucket' test_upload_is_immutable_checksummed_and_exact_bucket
run_test 'OCI head verification rejects size and metadata mismatch' test_head_verification_rejects_size_or_metadata_mismatch
run_test 'OCI set discovery paginates and falls back to weekly' test_set_discovery_paginates_and_falls_back_to_weekly
run_test 'OCI download is no-clobber and diagnostics stay private' test_download_is_no_clobber_and_failures_are_private
run_test 'OCI preflight rejects a namespace mismatch privately' test_namespace_mismatch_is_rejected_without_diagnostics

if ((failures > 0)); then
    printf '%d OCI backup transport test(s) failed\n' "${failures}" >&2
    exit 1
fi
