#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"
# shellcheck source=notifier-lib.sh
source "${SCRIPT_DIR}/notifier-lib.sh"

[[ "$#" -eq 0 ]] || die "Usage: $0"
if [[ ! -t 0 ]]; then
    printf '[ACTION REQUIRED] Run ./deploy/scripts/notifier-smtp-test.sh in an interactive terminal.\n' >&2
    printf 'Then rerun: ./deploy/scripts/setup-wizard.sh --resume --non-interactive\n' >&2
    exit 20
fi

validate_runtime_env
init_docker
init_sudo
require_command jq

data_root="$(env_value THREADHUB_DATA_ROOT "${ENV_FILE}")"
validate_notifier_host_path "${data_root}"
control_dir="${data_root}/notifier/control"
marker_file="${control_dir}/smtp-acceptance.json"
"${SUDO_COMMAND[@]}" test -d "${control_dir}" \
    || die "Notifier control directory does not exist"

read -r -s -p 'SMTP acceptance test recipient: ' recipient
printf '\n' >&2
[[ "${recipient}" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]] \
    || die "A valid test recipient is required"

compose exec -T threadhub-mailer /threadhub-mailer healthcheck >/dev/null
printf '%s\n' "${recipient}" \
    | compose exec -T threadhub-mailer \
        /threadhub-mailer smtp-test --recipient-stdin >/dev/null
recipient=
unset recipient

fingerprint="$(notifier_smtp_fingerprint)"
notifier_write_smtp_marker \
    "${marker_file}" "${fingerprint}" "$(notifier_epoch_millis)"
log "OCI SMTP accepted the generic notifier test message"
warn "Inbox arrival, links, SPF and DKIM still require manual verification"
