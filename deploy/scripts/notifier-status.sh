#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"
# shellcheck source=notifier-lib.sh
source "${SCRIPT_DIR}/notifier-lib.sh"

notifier_status_dispatch() (
    local state_file="$1"
    local marker_file="${state_file%/state.json}/smtp-acceptance.json"
    local temporary_dir
    local status_file
    local plugin_list_file
    local plugin_id
    local notifier_version
    local plugin_state=missing_or_mismatched
    local requested_env="${THREADHUB_ENV_FILE:-${ENV_FILE}}"

    notifier_print_control_status "${state_file}"
    if ! (ENV_FILE="${requested_env}"; validate_runtime_env) >/dev/null 2>&1; then
        printf 'live_diagnostics=unavailable\n'
        return 20
    fi
    ENV_FILE="${requested_env}"
    init_docker
    if notifier_smtp_marker_is_current "${marker_file}"; then
        printf 'smtp_acceptance=current\n'
    else
        printf 'smtp_acceptance=missing_or_stale\n'
    fi

    temporary_dir="$(mktemp -d)"
    status_file="${temporary_dir}/mailer-status.json"
    plugin_list_file="${temporary_dir}/plugin-list.json"
    trap 'rm -rf -- "${temporary_dir}"' EXIT
    plugin_id="$(env_value NOTIFIER_PLUGIN_ID "${VERSIONS_FILE}")"
    notifier_version="$(env_value NOTIFIER_VERSION "${VERSIONS_FILE}")"
    if notifier_compose exec -T "$(notifier_mattermost_service)" \
        mmctl plugin list --local --suppress-warnings --json > "${plugin_list_file}" \
        && notifier_plugin_list_is_exact_active \
            "${plugin_list_file}" "${plugin_id}" "${notifier_version}"; then
        plugin_state=active
    fi
    printf 'plugin=%s\n' "${plugin_state}"
    notifier_compose exec -T "$(notifier_mailer_service)" \
        /threadhub-mailer status --json > "${status_file}"
    notifier_mailer_status_is_valid "${status_file}" \
        || die "Notifier Mailer returned invalid status JSON"
    jq -r '
        "pending=\(.pending)",
        "sending=\(.sending)",
        "sent=\(.sent)",
        "failed=\(.failed)",
        "oldest_pending_seconds=\(.oldest_pending_seconds)",
        "last_success_at=\(.last_success_at)",
        "last_error_class=\(.last_error_class)",
        "last_smtp_code=\(.last_smtp_code)"
    ' "${status_file}"
)

notifier_status_entry() {
    local state_file=/srv/threadhub/notifier/control/state.json

    [[ "$#" -eq 0 ]] || die "Usage: $0"
    init_sudo
    require_command jq
    validate_notifier_emergency_control_path "${state_file}"
    notifier_status_dispatch "${state_file}"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    notifier_status_entry "$@"
fi
