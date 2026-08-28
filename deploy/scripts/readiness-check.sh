#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"
# shellcheck source=notifier-lib.sh
source "${SCRIPT_DIR}/notifier-lib.sh"

validate_runtime_env
init_docker
init_sudo
require_command curl
require_command jq

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
assert_container_setting MM_PLUGINSETTINGS_ENABLE true

temporary_dir="$(mktemp -d)"
cleanup_readiness() {
    rm -rf "${temporary_dir}"
}
trap cleanup_readiness EXIT
plugin_list_file="${temporary_dir}/plugin-list.json"
mailer_status_file="${temporary_dir}/mailer-status.json"
plugin_id="$(env_value NOTIFIER_PLUGIN_ID "${VERSIONS_FILE}")"
notifier_version="$(env_value NOTIFIER_VERSION "${VERSIONS_FILE}")"
compose exec -T mattermost \
    mmctl plugin list --local --suppress-warnings --json > "${plugin_list_file}"
notifier_plugin_list_is_exact_active \
    "${plugin_list_file}" "${plugin_id}" "${notifier_version}" \
    || die "Exact notifier plugin ID and version are not active"
compose exec -T threadhub-mailer /threadhub-mailer healthcheck >/dev/null
compose exec -T threadhub-mailer \
    /threadhub-mailer status --json > "${mailer_status_file}"
notifier_mailer_status_is_valid "${mailer_status_file}" \
    || die "Notifier Mailer returned invalid status JSON"

data_root="$(env_value THREADHUB_DATA_ROOT "${ENV_FILE}")"
state_file="${data_root}/notifier/control/state.json"
smtp_marker="${data_root}/notifier/control/smtp-acceptance.json"
target_enabled="$(env_value NOTIFIER_ENABLED "${ENV_FILE}")"
target_mode="$(env_value NOTIFIER_MODE "${ENV_FILE}")"
target_channel_ids="$(env_optional_value NOTIFIER_CHANNEL_IDS "${ENV_FILE}")"
notifier_control_matches_target \
    "${state_file}" "${target_enabled}" "${target_mode}" "${target_channel_ids}" \
    || die "Actual notifier control state does not match the configured target"
if [[ "${target_enabled}" == true ]]; then
    notifier_smtp_marker_is_current "${smtp_marker}" \
        || die "Current SMTP credentials have not passed notifier SMTP acceptance"
fi

domain="$(env_value THREADHUB_DOMAIN "${ENV_FILE}")"
https_url="https://${domain}/api/v4/system/ping"
http_url="http://${domain}/"

curl --fail --silent --show-error "${https_url}" >/dev/null

redirect_headers="$(curl --silent --show-error --head "${http_url}")"
printf '%s\n' "${redirect_headers}" | grep -Eq '^HTTP/[0-9.]+ 30(1|8)' \
    || die "HTTP endpoint did not return a permanent redirect"
printf '%s\n' "${redirect_headers}" | grep -Eiq "^location: https://${domain}/" \
    || die "HTTP endpoint did not redirect to the expected HTTPS domain"

log "Runtime environment, notifier activation, critical Mattermost settings, HTTPS and HTTP redirect are ready"
warn "Client UI/mobile and external mailbox tests still require the documented manual acceptance tests"
