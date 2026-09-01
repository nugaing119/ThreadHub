#!/usr/bin/env bash

# Literal shell fragments below are executable documentation contracts.
# shellcheck disable=SC2016,SC2251

set -Eeuo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(cd "${TEST_DIR}/.." && pwd)"
REPOSITORY_ROOT="$(cd "${DEPLOY_DIR}/.." && pwd)"
HARNESS="${DEPLOY_DIR}/integration/backup/run.sh"
OCI_STUB="${DEPLOY_DIR}/integration/backup/oci-stub.sh"
MATTERMOST_SEED="${DEPLOY_DIR}/integration/backup/seed-mattermost.sh"
QUEUE_SEED="${REPOSITORY_ROOT}/notifier/mailer/integration/backup-seed/main.go"
failures=0

pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'not ok - %s\n' "$1" >&2; failures=$((failures + 1)); }

run_test() {
    local name="$1" function_name="$2" status

    set +e
    ( set -Eeuo pipefail; "${function_name}" )
    status=$?
    set -e
    if ((status == 0)); then pass "${name}"; else fail "${name}"; fi
}

test_harness_has_real_image_and_acceptance_contracts() {
    [[ -x "${HARNESS}" ]]
    [[ "$(awk -F= '$1 == "MATTERMOST_IMAGE_TAG" { print $2 }' "${DEPLOY_DIR}/versions.env")" == 11.7.7 ]]
    [[ "$(awk -F= '$1 == "POSTGRES_IMAGE_TAG" { print $2 }' "${DEPLOY_DIR}/versions.env")" == 18.4 ]]
    for contract in \
        'Mattermost Team Edition 11.7.7' \
        'PostgreSQL 18.4' \
        'source-root-unchanged' \
        'notifier-old-mail-not-sent' \
        'service-downtime-at-most-300' \
        'restore-rto-at-most-14400' \
        'smtp.email.ap-singapore-1.oci.oraclecloud.com' \
        'privacy_patterns' \
        'grep -R -F -q' \
        'BK-INTEGRATION-pass'; do
        grep -F "${contract}" "${HARNESS}" >/dev/null
    done
}

test_harness_is_ephemeral_and_guards_cleanup() {
    local target_mark_line deploy_line

    grep -F 'require_ubuntu_amd64' "${HARNESS}" >/dev/null
    grep -F 'INTEGRATION_SENTINEL' "${HARNESS}" >/dev/null
    grep -F 'COMPOSE_PROJECT_NAME=threadhub-backup-integration' "${HARNESS}" >/dev/null
    grep -F 'backup_assert_empty_target /srv/threadhub' "${HARNESS}" >/dev/null
    grep -F 'docker compose' "${HARNESS}" >/dev/null
    grep -F 'install -d -m 0750 "${TARGET_ROOT}"' "${HARNESS}" >/dev/null
    for deploy_result in deploy-postgres deploy-mattermost deploy-mailer deploy-plugin; do
        grep -F "${deploy_result}" "${HARNESS}" >/dev/null
    done
    grep -F 'integration_compose ps -q' "${HARNESS}" >/dev/null
    grep -F "docker inspect --format '{{.State.Status}}'" "${HARNESS}" >/dev/null
    target_mark_line="$(grep -nF 'mark_root "${TARGET_ROOT}"' "${HARNESS}" | head -n 1 | cut -d: -f1)"
    deploy_line="$(grep -nF '"${DEPLOY_DIR}/scripts/deploy.sh"' "${HARNESS}" | head -n 1 | cut -d: -f1)"
    [[ -n "${target_mark_line}" && -n "${deploy_line}" && "${target_mark_line}" -lt "${deploy_line}" ]]
    grep -F 'CURRENT_FAILURE="$(classify_deploy_failure)"' "${HARNESS}" >/dev/null
    ! grep -Eq 'docker (system|volume|network) prune|rm -rf /srv($|/[^t])' "${HARNESS}"
}

test_oci_stub_is_exact_bucket_instance_principal_and_no_delete() {
    [[ -x "${OCI_STUB}" ]]
    for contract in \
        'instance_principal' \
        'ap-singapore-1' \
        'NoPublicAccess' \
        'opc-meta-threadhub-sha256' \
        'opc-content-sha256' \
        'OCI_STUB_OBJECT_ROOT' \
        'OCI_STUB_AUDIT_FILE'; do
        grep -F "${contract}" "${OCI_STUB}" >/dev/null
    done
    grep -F 'delete)' "${OCI_STUB}" >/dev/null
    grep -F 'exit 64' "${OCI_STUB}" >/dev/null
}

test_oci_stub_round_trip_and_rejections() (
    fixture="$(mktemp -d)"
    trap 'rm -rf "${fixture}"' EXIT
    install -d -m 0700 "${fixture}/objects"
    : > "${fixture}/audit"
    chmod 0600 "${fixture}/audit"
    printf '%s\n' 'manifest-fixture' > "${fixture}/source"
    chmod 0600 "${fixture}/source"
    sha="$(sha256sum "${fixture}/source" | awk '{print $1}')"
    key='daily/2026/09/01/20260901T030000Z-0123456789abcdef0123456789abcdef/manifest.json'
    export OCI_STUB_NAMESPACE=integrationnamespace
    export OCI_STUB_BUCKET=integration-project-backups
    export OCI_STUB_OBJECT_ROOT="${fixture}/objects"
    export OCI_STUB_AUDIT_FILE="${fixture}/audit"
    common=(--auth instance_principal --region ap-singapore-1 --output json)
    stub_put() {
        local object_key="$1" source_file="$2" object_sha object_content_sha

        object_sha="$(sha256sum "${source_file}" | awk '{print $1}')"
        object_content_sha="$(openssl dgst -sha256 -binary "${source_file}" | openssl base64 -A)"
        "${OCI_STUB}" os object put --namespace-name integrationnamespace \
            --bucket-name integration-project-backups --name "${object_key}" \
            --file "${source_file}" --no-overwrite --verify-checksum \
            --opc-checksum-algorithm SHA256 --opc-content-sha256 "${object_content_sha}" \
            --metadata "{\"threadhub-sha256\":\"${object_sha}\"}" "${common[@]}" >/dev/null
    }

    "${OCI_STUB}" os ns get "${common[@]}" \
        | jq -e '.data == "integrationnamespace"' >/dev/null
    "${OCI_STUB}" os bucket get --namespace-name integrationnamespace \
        --name integration-project-backups "${common[@]}" \
        | jq -e '.data["public-access-type"] == "NoPublicAccess"' >/dev/null
    stub_put "${key}" "${fixture}/source"
    "${OCI_STUB}" os object head --namespace-name integrationnamespace \
        --bucket-name integration-project-backups --name "${key}" "${common[@]}" \
        | jq -e --arg sha "${sha}" '.["opc-meta-threadhub-sha256"] == $sha' >/dev/null
    for name in database.dump mattermost-data.tar.zst notifier-queue.tar.zst manifest.sha256; do
        printf '%s\n' "${name}" > "${fixture}/${name}"
        chmod 0600 "${fixture}/${name}"
        stub_put "${key%/*}/${name}" "${fixture}/${name}"
    done
    first_page="${fixture}/first-page.json"
    second_page="${fixture}/second-page.json"
    "${OCI_STUB}" os object list --namespace-name integrationnamespace \
        --bucket-name integration-project-backups --prefix daily/ "${common[@]}" \
        > "${first_page}"
    page_token="$(jq -er '.["opc-next-page"]' "${first_page}")"
    [[ "$(jq '.data | length' "${first_page}")" == 3 && "${page_token}" == page-3 ]]
    "${OCI_STUB}" os object list --namespace-name integrationnamespace \
        --bucket-name integration-project-backups --prefix daily/ --page "${page_token}" \
        "${common[@]}" > "${second_page}"
    [[ "$(jq '.data | length' "${second_page}")" == 2 ]]
    ! jq -e 'has("opc-next-page")' "${second_page}" >/dev/null
    : > "${fixture}/download"
    chmod 0600 "${fixture}/download"
    "${OCI_STUB}" os object get --namespace-name integrationnamespace \
        --bucket-name integration-project-backups --name "${key}" \
        --file "${fixture}/download" --force "${common[@]}" >/dev/null
    cmp -s "${fixture}/source" "${fixture}/download"

    ! "${OCI_STUB}" os object delete --namespace-name integrationnamespace \
        --bucket-name integration-project-backups --name "${key}" "${common[@]}" >/dev/null 2>&1
    ! "${OCI_STUB}" os object head --namespace-name integrationnamespace \
        --bucket-name another-bucket --name "${key}" "${common[@]}" >/dev/null 2>&1
    ! "${OCI_STUB}" os object head --namespace-name integrationnamespace \
        --bucket-name integration-project-backups --name '../manifest.json' \
        "${common[@]}" >/dev/null 2>&1
    ! "${OCI_STUB}" os ns get --auth api_key --region ap-singapore-1 \
        --output json >/dev/null 2>&1
)

test_seeders_use_supported_api_and_real_queue_store() {
    [[ -x "${MATTERMOST_SEED}" && -f "${QUEUE_SEED}" ]]
    for endpoint in \
        '/api/v4/users' '/api/v4/teams' '/api/v4/channels' \
        '/api/v4/posts' '/api/v4/files'; do
        grep -F "${endpoint}" "${MATTERMOST_SEED}" >/dev/null
    done
    grep -F 'store.Open' "${QUEUE_SEED}" >/dev/null
    grep -F 'queue.Accept' "${QUEUE_SEED}" >/dev/null
    grep -F 'protocol.HashIdentifier' "${QUEUE_SEED}" >/dev/null
    grep -F 'seeded=1' "${QUEUE_SEED}" >/dev/null
}

test_public_output_is_allowlisted() {
    grep -F 'BK-INTEGRATION-' "${HARNESS}" >/dev/null
    grep -F 'exec 3>&1' "${HARNESS}" >/dev/null
    grep -F 'exec >"${PRIVATE_LOG}" 2>&1' "${HARNESS}" >/dev/null
    ! grep -Eq 'set -x|cat .*\.env|echo .*PASSWORD|echo .*HMAC' \
        "${HARNESS}" "${OCI_STUB}" "${MATTERMOST_SEED}"
}

run_test 'integration harness has real-image acceptance contracts' \
    test_harness_has_real_image_and_acceptance_contracts
run_test 'integration harness is ephemeral with guarded cleanup' \
    test_harness_is_ephemeral_and_guards_cleanup
run_test 'OCI stub is exact-bucket instance-principal and no-delete' \
    test_oci_stub_is_exact_bucket_instance_principal_and_no_delete
run_test 'OCI stub round-trips and rejects unsafe operations' \
    test_oci_stub_round_trip_and_rejections
run_test 'seeders use supported APIs and the real queue store' \
    test_seeders_use_supported_api_and_real_queue_store
run_test 'integration public output is allowlisted' test_public_output_is_allowlisted

if ((failures > 0)); then
    printf '%d backup integration contract test(s) failed\n' "${failures}" >&2
    exit 1
fi
