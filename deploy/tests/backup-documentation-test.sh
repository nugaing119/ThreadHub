#!/usr/bin/env bash

set -Eeuo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(cd "${TEST_DIR}/.." && pwd)"
REPOSITORY_ROOT="$(cd "${DEPLOY_DIR}/.." && pwd)"
CONTRACTS="${DEPLOY_DIR}/scripts/backup-documentation-contracts.sh"

[[ -f "${CONTRACTS}" ]] || {
    printf 'not ok - backup documentation contract helper is missing\n' >&2
    exit 1
}
# shellcheck source=../scripts/backup-documentation-contracts.sh
# shellcheck disable=SC1091
source "${CONTRACTS}"

temporary_dir="$(mktemp -d)"
fixture_root="${temporary_dir}/repository"

cleanup() {
    rm -rf "${temporary_dir}"
}
trap cleanup EXIT

fail() {
    printf 'not ok - %s\n' "$*" >&2
    exit 1
}

assert_contract_failure() {
    local description="$1"

    if validate_backup_documentation_contracts "${fixture_root}" >/dev/null 2>&1; then
        fail "${description}"
    fi
}

reset_fixture() {
    rm -rf "${fixture_root}"
    mkdir -p "${fixture_root}/deploy" "${fixture_root}/docs"
    cp "${REPOSITORY_ROOT}/README.md" "${fixture_root}/README.md"
    cp "${REPOSITORY_ROOT}/AGENTS.md" "${fixture_root}/AGENTS.md"
    cp "${REPOSITORY_ROOT}/SECURITY.md" "${fixture_root}/SECURITY.md"
    cp "${DEPLOY_DIR}/README.md" "${fixture_root}/deploy/README.md"
    cp -R "${DEPLOY_DIR}/docs" "${fixture_root}/deploy/docs"
    cp "${REPOSITORY_ROOT}/docs/threadhub-prd-v4.2-final.md" \
        "${fixture_root}/docs/threadhub-prd-v4.2-final.md"
}

reset_fixture
validate_backup_documentation_contracts "${fixture_root}" \
    || fail 'real backup documentation does not satisfy the production contract helper'

rm -f "${fixture_root}/deploy/docs/backup-restore.md"
assert_contract_failure 'missing backup and restore guide was accepted'

reset_fixture
# Backticks below are required literal Markdown delimiters.
# shellcheck disable=SC2016
sed -i.bak 's/new or empty `\/srv\/threadhub`/nonempty target allowed/g' \
    "${fixture_root}/deploy/docs/backup-restore.md"
rm -f "${fixture_root}/deploy/docs/backup-restore.md.bak"
assert_contract_failure 'non-empty restore prohibition was removed'

reset_fixture
sed -i.bak 's/explicit user authorization/automatic IAM creation/g' \
    "${fixture_root}/AGENTS.md"
rm -f "${fixture_root}/AGENTS.md.bak"
assert_contract_failure 'OCI approval boundary was removed'

reset_fixture
sed -i.bak 's/timer remains disabled/timer starts immediately/g' \
    "${fixture_root}/deploy/docs/quick-install.md"
rm -f "${fixture_root}/deploy/docs/quick-install.md.bak"
assert_contract_failure 'acceptance-before-timer order was removed'

reset_fixture
sed -i.bak 's/queue quarantine/queue replay/g' \
    "${fixture_root}/deploy/docs/backup-restore.md"
rm -f "${fixture_root}/deploy/docs/backup-restore.md.bak"
assert_contract_failure 'notifier queue quarantine requirement was removed'

reset_fixture
sed -i.bak 's/BK-LIVE-/BK-UNSAFE-/g' "${fixture_root}/deploy/docs/test-plan.md"
rm -f "${fixture_root}/deploy/docs/test-plan.md.bak"
assert_contract_failure 'live backup test identifiers were removed'

reset_fixture
perl -0pi -e 's/(configure-backup\.sh.*?install-backup\.sh --register)/(install-backup.sh --enable-after-acceptance BACKUP_ID\n$1)/s' \
    "${fixture_root}/deploy/docs/backup-restore.md"
assert_contract_failure 'timer activation before manual backup and restore was accepted'

printf 'ok - backup documentation contracts reject unsafe mutation fixtures\n'
