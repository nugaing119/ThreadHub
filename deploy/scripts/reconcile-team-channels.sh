#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

[[ "$#" -ge 1 ]] || die "Usage: $0 TEAM_URL_NAME [CHANNEL_URL_NAME ...]"
team_name="$1"
shift

if [[ "$#" -gt 0 ]]; then
    channel_names=("$@")
else
    channel_names=(
        01-project-general
        02-progress-issues
        03-decisions
    )
fi

validate_name() {
    local label="$1"
    local value="$2"

    [[ "${value}" =~ ^[a-z0-9][a-z0-9_-]{0,63}$ ]] \
        || die "${label} contains an invalid Mattermost URL name: ${value}"
}

query_postgres() {
    local sql="$1"
    local postgres_user
    local postgres_db

    postgres_user="$(env_value POSTGRES_USER "${ENV_FILE}")"
    postgres_db="$(env_value POSTGRES_DB "${ENV_FILE}")"
    compose exec -T postgres \
        psql -X -v ON_ERROR_STOP=1 -At \
        -U "${postgres_user}" -d "${postgres_db}" -c "${sql}"
}

validate_name Team "${team_name}"
for channel_name in "${channel_names[@]}"; do
    validate_name Channel "${channel_name}"
done

validate_runtime_env
init_docker
compose config --quiet

team_user_count="$(query_postgres "
SELECT COUNT(*)
FROM users u
JOIN teammembers tm ON tm.userid = u.id
JOIN teams t ON t.id = tm.teamid
WHERE t.name = '${team_name}'
  AND t.deleteat = 0
  AND tm.deleteat = 0
  AND u.deleteat = 0;")"

[[ "${team_user_count}" =~ ^[0-9]+$ ]] \
    || die "Unable to determine active member count for Team ${team_name}"
[[ "${team_user_count}" -gt 0 ]] \
    || die "No active members found in Team ${team_name}"

for channel_name in "${channel_names[@]}"; do
    missing_output="$(query_postgres "
SELECT u.username
FROM users u
JOIN teammembers tm ON tm.userid = u.id
JOIN teams t ON t.id = tm.teamid
JOIN channels c ON c.teamid = t.id
LEFT JOIN channelmembers cm
  ON cm.channelid = c.id AND cm.userid = u.id
WHERE t.name = '${team_name}'
  AND c.name = '${channel_name}'
  AND t.deleteat = 0
  AND tm.deleteat = 0
  AND c.deleteat = 0
  AND u.deleteat = 0
  AND cm.userid IS NULL
ORDER BY u.username;")"

    if [[ -n "${missing_output}" ]]; then
        while IFS= read -r username; do
            [[ -n "${username}" ]] || continue
            log "Adding ${username} to ${team_name}:${channel_name}"
            compose exec -T mattermost \
                mmctl channel users add "${team_name}:${channel_name}" \
                "${username}" --local --suppress-warnings
        done <<< "${missing_output}"
    fi

    channel_user_count="$(query_postgres "
SELECT COUNT(*)
FROM users u
JOIN teammembers tm ON tm.userid = u.id
JOIN teams t ON t.id = tm.teamid
JOIN channels c ON c.teamid = t.id
JOIN channelmembers cm
  ON cm.channelid = c.id AND cm.userid = u.id
WHERE t.name = '${team_name}'
  AND c.name = '${channel_name}'
  AND t.deleteat = 0
  AND tm.deleteat = 0
  AND c.deleteat = 0
  AND u.deleteat = 0;")"

    [[ "${channel_user_count}" == "${team_user_count}" ]] \
        || die "Membership reconciliation failed for ${team_name}:${channel_name} (${channel_user_count}/${team_user_count})"
    log "${team_name}:${channel_name} includes all ${team_user_count} active Team members"
done

log "Team channel membership reconciliation passed"
