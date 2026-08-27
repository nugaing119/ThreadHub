#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"
# shellcheck source=notifier-lib.sh
source "${SCRIPT_DIR}/notifier-lib.sh"

[[ "$#" -eq 0 ]] || die "Usage: $0"
validate_runtime_env
init_docker
init_sudo
require_command jq

data_root="$(env_value THREADHUB_DATA_ROOT "${ENV_FILE}")"
validate_notifier_host_path "${data_root}"
control_dir="${data_root}/notifier/control"
state_file="${control_dir}/state.json"
marker_file="${control_dir}/smtp-acceptance.json"
notifier_print_control_status "${state_file}"

if notifier_smtp_marker_is_current "${marker_file}"; then
    printf 'smtp_acceptance=current\n'
else
    printf 'smtp_acceptance=missing_or_stale\n'
fi

status_file="$(mktemp)"
cleanup_status() {
    rm -f "${status_file}"
}
trap cleanup_status EXIT
compose exec -T threadhub-mailer /threadhub-mailer status --json > "${status_file}"
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
