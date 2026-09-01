#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! declare -F existing_notifier_setup_dispatch >/dev/null 2>&1; then
    # shellcheck source=existing-notifier-setup.sh
    source "${SCRIPT_DIR}/existing-notifier-setup.sh"
fi

existing_notifier_status_dispatch() (
    local state_file="$1"
    local temporary_dir
    local status_file
    local plugin_state=missing_or_mismatched
    local smtp_state=missing_or_stale

    notifier_print_control_status "${state_file}"
    existing_notifier_setup_require_current_smtp_marker >/dev/null 2>&1 \
        && smtp_state=current
    printf 'smtp_acceptance=%s\n' "${smtp_state}"

    temporary_dir="$(mktemp -d)"
    trap 'rm -rf -- "${temporary_dir}"' EXIT HUP INT TERM
    status_file="${temporary_dir}/mailer-status.json"
    if existing_notifier_setup_verify_plugin >/dev/null 2>&1; then
        plugin_state=active
    fi
    printf 'plugin=%s\n' "${plugin_state}"
    existing_notifier_compose_combined exec -T threadhub-mailer \
        /threadhub-mailer status --json > "${status_file}"
    notifier_mailer_status_is_valid "${status_file}" \
        || die "Existing notifier Mailer returned invalid status JSON"
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

existing_notifier_status_entry() {
    local state_file

    [[ "$#" -eq 0 ]] || die "Usage: $0"
    existing_notifier_setup_validate_config || return $?
    existing_notifier_init_compose
    state_file="$(existing_notifier_value THN_DATA_ROOT)/control/state.json"
    existing_notifier_validate_control_path "${state_file}"
    existing_notifier_status_dispatch "${state_file}"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    existing_notifier_status_entry "$@"
fi
