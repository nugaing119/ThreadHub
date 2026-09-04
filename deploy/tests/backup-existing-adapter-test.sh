#!/usr/bin/env bash

set -Eeuo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(cd "${TEST_DIR}/.." && pwd)"
SCRIPTS="${DEPLOY_DIR}/scripts"

for path in \
    "${SCRIPTS}/backup-existing.sh" \
    "${SCRIPTS}/backup-existing-snapshot.sh" \
    "${SCRIPTS}/backup-existing-health.sh"; do
    [[ -x "${path}" ]] || {
        printf 'not ok - existing backup adapter is missing or not executable: %s\n' "${path}" >&2
        exit 1
    }
done

grep -F 'source_mode="$(backup_source_mode)"' "${SCRIPTS}/backup.sh" >/dev/null
grep -F 'exec "${BACKUP_COMMAND_DIR}/backup-existing.sh" "$@"' "${SCRIPTS}/backup.sh" >/dev/null
grep -F 'BACKUP_ARTIFACT_SOURCE_COMMIT_MODE=release' \
    "${SCRIPTS}/backup-existing.sh" "${SCRIPTS}/backup-existing-snapshot.sh" >/dev/null
grep -F 'THN_MATTERMOST_DATA_ROOT' "${SCRIPTS}/backup-existing.sh" >/dev/null
grep -F 'THN_DATA_ROOT' "${SCRIPTS}/backup-existing.sh" >/dev/null
grep -F 'existing_notifier_compose_combined config --quiet' \
    "${SCRIPTS}/backup-existing.sh" "${SCRIPTS}/backup-existing-health.sh" >/dev/null
grep -F -- '--source-mode existing-notifier' "${SCRIPTS}/configure-backup.sh" >/dev/null
grep -F 'backup_configuration_publish_no_clobber' "${SCRIPTS}/configure-backup.sh" >/dev/null

if grep -Eq 'docker[[:space:]]+(compose[[:space:]]+)?down|volume[[:space:]]+rm|rm[[:space:]]+-rf' \
    "${SCRIPTS}/backup-existing.sh" \
    "${SCRIPTS}/backup-existing-snapshot.sh" \
    "${SCRIPTS}/backup-existing-health.sh"; then
    printf 'not ok - existing backup adapter contains a destructive deployment operation\n' >&2
    exit 1
fi

printf 'ok - existing deployment backup adapter is fail-closed and non-destructive\n'
