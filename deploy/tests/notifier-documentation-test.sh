#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPOSITORY_ROOT="$(cd "${DEPLOY_DIR}/.." && pwd)"
# shellcheck source=../scripts/notifier-documentation-contracts.sh
source "${DEPLOY_DIR}/scripts/notifier-documentation-contracts.sh"

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

    if validate_notifier_documentation_contracts "${fixture_root}" >/dev/null 2>&1; then
        fail "${description}"
    fi
}

reset_fixture() {
    rm -rf "${fixture_root}"
    mkdir -p "${fixture_root}/deploy"
    cp "${REPOSITORY_ROOT}/README.md" "${fixture_root}/README.md"
    cp "${REPOSITORY_ROOT}/SECURITY.md" "${fixture_root}/SECURITY.md"
    cp "${DEPLOY_DIR}/README.md" "${fixture_root}/deploy/README.md"
    cp -R "${DEPLOY_DIR}/docs" "${fixture_root}/deploy/docs"
}

reset_fixture
validate_notifier_documentation_contracts "${fixture_root}" \
    || fail 'real notifier documentation does not satisfy the production contract helper'

sed -i.bak 's/threadhub-mailer retry-failed/retry-after-disable/g' \
    "${fixture_root}/deploy/docs/operations-checklist.md"
rm -f "${fixture_root}/deploy/docs/operations-checklist.md.bak"
assert_contract_failure 'unsafe close order was accepted'

reset_fixture
perl -0pi -e 's/(1\. `\.\/deploy\/scripts\/notifier-control\.sh drain`.*?4\. `\.\/deploy\/scripts\/notifier-control\.sh disable`.*?)(5\. 그 뒤에만 서버의 보호된 `deploy\/\.env`)/$2$1/s' \
    "${fixture_root}/deploy/docs/oci-email-delivery.md"
assert_contract_failure 'OCI env-before-disable rotation order was accepted'

reset_fixture
sed -i.bak 's/build\/install/build-missing/g' "${fixture_root}/deploy/docs/quick-install.md"
rm -f "${fixture_root}/deploy/docs/quick-install.md.bak"
assert_contract_failure 'missing quick-install step was accepted'

reset_fixture
sed -i.bak 's/failed=0/failed-missing/g' "${fixture_root}/deploy/docs/project-close.md"
rm -f "${fixture_root}/deploy/docs/project-close.md.bak"
assert_contract_failure 'missing project-close failure gate was accepted'

reset_fixture
sed -i.bak 's#\./project-close\.md#./project-close-missing.md#' \
    "${fixture_root}/deploy/docs/operations-checklist.md"
rm -f "${fixture_root}/deploy/docs/operations-checklist.md.bak"
assert_contract_failure 'missing operational close link was accepted'

reset_fixture
sed -i.bak 's/NF-FN-13/NF-FN-missing/' "${fixture_root}/deploy/docs/test-plan.md"
rm -f "${fixture_root}/deploy/docs/test-plan.md.bak"
assert_contract_failure 'missing NF classification was accepted'

reset_fixture
perl -0pi -e 's/(\| 15 \| pass \|\n)/$1| unexpected | schema | row |\n/' \
    "${fixture_root}/deploy/docs/test-results-public.md"
assert_contract_failure 'extra public evidence schema row was accepted'

printf 'ok - shared notifier documentation contracts reject unsafe mutation fixtures\n'
