#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

validate_runtime_env
init_docker
require_command curl

"${SCRIPT_DIR}/health-check.sh" >/dev/null

mattermost_id="$(compose ps -q mattermost)"
[[ -n "${mattermost_id}" ]] || die "Mattermost container is not running"

container_env_value() {
    local key="$1"
    "${DOCKER_COMMAND[@]}" inspect \
        --format '{{range .Config.Env}}{{println .}}{{end}}' \
        "${mattermost_id}" \
        | awk -F '=' -v key="${key}" '$1 == key { print substr($0, length(key) + 2); exit }'
}

assert_container_setting() {
    local key="$1"
    local expected="$2"
    local actual
    actual="$(container_env_value "${key}")"
    [[ "${actual}" == "${expected}" ]] \
        || die "Unexpected ${key} setting"
}

assert_container_setting MM_TEAMSETTINGS_ENABLEOPENSERVER false
assert_container_setting MM_EMAILSETTINGS_SENDPUSHNOTIFICATIONS false
assert_container_setting MM_FILESETTINGS_ENABLEPUBLICLINK false
assert_container_setting MM_FEATUREFLAGS_CJKSEARCH true
assert_container_setting MM_SERVICESETTINGS_TERMINATESESSIONSONPASSWORDCHANGE true
assert_container_setting MM_LOGSETTINGS_ENABLEDIAGNOSTICS false
assert_container_setting MM_PLUGINSETTINGS_ENABLE false

domain="$(env_value THREADHUB_DOMAIN "${ENV_FILE}")"
https_url="https://${domain}/api/v4/system/ping"
http_url="http://${domain}/"

curl --fail --silent --show-error "${https_url}" >/dev/null

redirect_headers="$(curl --silent --show-error --head "${http_url}")"
printf '%s\n' "${redirect_headers}" | grep -Eq '^HTTP/[0-9.]+ 30(1|8)' \
    || die "HTTP endpoint did not return a permanent redirect"
printf '%s\n' "${redirect_headers}" | grep -Eiq "^location: https://${domain}/" \
    || die "HTTP endpoint did not redirect to the expected HTTPS domain"

log "Runtime environment, critical Mattermost settings, HTTPS and HTTP redirect are ready"
warn "Email delivery, System Scheme, MFA, CJK corpus and client tests still require the documented manual acceptance tests"
