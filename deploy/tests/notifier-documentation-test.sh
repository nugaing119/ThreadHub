#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPOSITORY_ROOT="$(cd "${DEPLOY_DIR}/.." && pwd)"
# shellcheck source=../scripts/notifier-documentation-contracts.sh
# shellcheck disable=SC1091
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
    mkdir -p "${fixture_root}/deploy/scripts" "${fixture_root}/docs"
    cp "${REPOSITORY_ROOT}/README.md" "${fixture_root}/README.md"
    cp "${REPOSITORY_ROOT}/AGENTS.md" "${fixture_root}/AGENTS.md"
    cp "${REPOSITORY_ROOT}/SECURITY.md" "${fixture_root}/SECURITY.md"
    cp "${DEPLOY_DIR}/README.md" "${fixture_root}/deploy/README.md"
    cp "${DEPLOY_DIR}/scripts/backup-documentation-contracts.sh" \
        "${fixture_root}/deploy/scripts/backup-documentation-contracts.sh"
    cp -R "${DEPLOY_DIR}/docs" "${fixture_root}/deploy/docs"
    cp "${REPOSITORY_ROOT}/docs/threadhub-prd-v4.3-final.md" \
        "${fixture_root}/docs/threadhub-prd-v4.3-final.md"
}

reset_fixture
validate_notifier_documentation_contracts "${fixture_root}" \
    || fail 'real notifier documentation does not satisfy the production contract helper'

rm -f "${fixture_root}/deploy/docs/notifier-architecture.md"
assert_contract_failure 'missing notifier architecture guide was accepted'

reset_fixture
sed -i.bak 's/커스텀 플러그인 구현은 SMTP 자격 증명을 읽거나/custom plugin reads SMTP credentials and/g' \
    "${fixture_root}/deploy/docs/notifier-architecture.md"
rm -f "${fixture_root}/deploy/docs/notifier-architecture.md.bak"
assert_contract_failure 'plugin and Mailer SMTP secret boundary was removed'

rm -f "${fixture_root}/deploy/docs/existing-mattermost-notifier.md"
assert_contract_failure 'missing existing Mattermost adoption guide was accepted'

reset_fixture
rm -f "${fixture_root}/deploy/docs/canonical-runtime-standard.md"
assert_contract_failure 'missing canonical runtime standard was accepted'

reset_fixture
sed -i.bak 's/hostname이나 고객 이름별 특수 프로필을 만들지 않는다/host-specific exceptions are allowed/g' \
    "${fixture_root}/deploy/docs/canonical-runtime-standard.md"
rm -f "${fixture_root}/deploy/docs/canonical-runtime-standard.md.bak"
assert_contract_failure 'hostname-specific production exceptions were accepted'

reset_fixture
sed -i.bak 's/별도의 폐기 가능한 VM/disposable restore omitted/g' \
    "${fixture_root}/deploy/docs/canonical-runtime-standard.md"
rm -f "${fixture_root}/deploy/docs/canonical-runtime-standard.md.bak"
assert_contract_failure 'missing disposable restore gate was accepted'

reset_fixture
perl -0pi -e 's/`existing-notifier-setup\.sh` → `SMTP acceptance` → `allowlist`/`existing-notifier-setup.sh` → `allowlist` → `SMTP acceptance`/' \
    "${fixture_root}/deploy/docs/existing-mattermost-notifier.md"
assert_contract_failure 'allowlist activation before SMTP acceptance was accepted'

reset_fixture
sed -i.bak 's/fresh installation only/fresh-and-adoption-mixed/g' \
    "${fixture_root}/deploy/docs/quick-install.md"
rm -f "${fixture_root}/deploy/docs/quick-install.md.bak"
assert_contract_failure 'fresh and existing adoption path separation was removed'

reset_fixture
sed -i.bak 's/30–60초/impact-window-missing/g' \
    "${fixture_root}/deploy/docs/existing-mattermost-notifier.md"
rm -f "${fixture_root}/deploy/docs/existing-mattermost-notifier.md.bak"
assert_contract_failure 'missing existing adoption impact window was accepted'

reset_fixture
sed -i.bak 's/explicit all_channels approval/all-channel-approval-missing/g' \
    "${fixture_root}/deploy/docs/existing-mattermost-notifier.md"
rm -f "${fixture_root}/deploy/docs/existing-mattermost-notifier.md.bak"
assert_contract_failure 'missing explicit all-channel approval was accepted'

reset_fixture
sed -i.bak 's/queue data/queue-preservation-missing/g' \
    "${fixture_root}/deploy/docs/existing-mattermost-notifier.md"
rm -f "${fixture_root}/deploy/docs/existing-mattermost-notifier.md.bak"
assert_contract_failure 'missing rollback queue preservation was accepted'

reset_fixture
sed -i.bak 's/do not modify the base Compose file/base-mutation-rule-missing/g' \
    "${fixture_root}/AGENTS.md"
rm -f "${fixture_root}/AGENTS.md.bak"
assert_contract_failure 'missing agent base Compose protection was accepted'

reset_fixture
sed -i.bak 's/NF-ADOPT-10/NF-ADOPT-missing/' "${fixture_root}/deploy/docs/test-plan.md"
rm -f "${fixture_root}/deploy/docs/test-plan.md.bak"
assert_contract_failure 'missing adoption NF classification was accepted'

reset_fixture
sed -i.bak 's/threadhub-mailer retry-failed/retry-placeholder/g' \
    "${fixture_root}/deploy/docs/operations-checklist.md"
rm -f "${fixture_root}/deploy/docs/operations-checklist.md.bak"
perl -0pi -e 's/(delivery_enabled=false.*?\n)/$1`threadhub-mailer retry-failed`를 disable 뒤에 실행합니다.\n/' \
    "${fixture_root}/deploy/docs/operations-checklist.md"
assert_contract_failure 'retry-failed after disable was accepted'

reset_fixture
perl -0pi -e 's/(1\. `\.\/deploy\/scripts\/notifier-control\.sh drain`.*?4\. `\.\/deploy\/scripts\/notifier-control\.sh disable`.*?)(5\. 그 뒤에만 서버의 보호된 `deploy\/\.env`)/$2$1/s' \
    "${fixture_root}/deploy/docs/oci-email-delivery.md"
assert_contract_failure 'OCI env-before-disable rotation order was accepted'

reset_fixture
perl -0pi -e 's/(6\. 일회성 SMTP acceptance를 실행합니다\.\n)(7\. activation cutoff 이후에만 notifier를 활성화합니다\.\n)/$2$1/' \
    "${fixture_root}/deploy/docs/quick-install.md"
assert_contract_failure 'activation before SMTP acceptance was accepted'

reset_fixture
sed -i.bak 's/failed=0/failed-missing/g' "${fixture_root}/deploy/docs/project-close.md"
rm -f "${fixture_root}/deploy/docs/project-close.md.bak"
assert_contract_failure 'missing project-close failure gate was accepted'

reset_fixture
sed -i.bak 's/failed_permanent/failed-permanent-missing/g' \
    "${fixture_root}/deploy/docs/operations-checklist.md"
rm -f "${fixture_root}/deploy/docs/operations-checklist.md.bak"
assert_contract_failure 'missing permanent-failure cancellation contract was accepted'

reset_fixture
sed -i.bak 's/failed_exhausted/failed-exhausted-missing/g' \
    "${fixture_root}/deploy/docs/project-close.md"
rm -f "${fixture_root}/deploy/docs/project-close.md.bak"
assert_contract_failure 'missing exhausted-failure cancellation contract was accepted'

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
