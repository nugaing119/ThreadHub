#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! declare -F existing_notifier_setup_dispatch >/dev/null 2>&1; then
    # shellcheck source=existing-notifier-setup.sh
    source "${SCRIPT_DIR}/existing-notifier-setup.sh"
fi

existing_notifier_run_smtp_acceptance() {
    existing_notifier_compose_combined exec -T threadhub-mailer \
        /threadhub-mailer smtp-test --recipient-stdin
}

existing_notifier_smtp_test_entry() {
    local state_file
    local marker_file
    local recipient
    local fingerprint

    [[ "$#" -eq 0 ]] || die "Usage: $0"
    if [[ ! -t 0 ]]; then
        printf '[ACTION REQUIRED] Run ./deploy/scripts/existing-notifier-smtp-test.sh in an interactive terminal.\n' >&2
        printf 'Then rerun: ./deploy/scripts/existing-notifier-setup.sh --resume\n' >&2
        return 20
    fi
    existing_notifier_setup_validate_config || return $?
    existing_notifier_init_compose
    state_file="$(existing_notifier_value THN_DATA_ROOT)/control/state.json"
    marker_file="${state_file%/state.json}/smtp-acceptance.json"
    existing_notifier_validate_control_path "${state_file}"

    read -r -s -p 'SMTP acceptance test recipient: ' recipient
    printf '\n' >&2
    validate_email recipient "${recipient}"
    if ! fingerprint="$(printf '%s\n' "${recipient}" \
        | existing_notifier_run_smtp_acceptance \
        | jq -er '
            if type == "object" and keys == ["config_fingerprint"] and
               (.config_fingerprint | type == "string" and test("^[a-f0-9]{64}$"))
            then .config_fingerprint else error("invalid fingerprint") end
        ')"; then
        recipient=""
        unset recipient
        die "OCI SMTP did not accept the generic existing notifier test message"
    fi
    recipient=""
    unset recipient
    notifier_write_smtp_marker "${marker_file}" "${fingerprint}" "$(notifier_epoch_millis)"
    log "OCI SMTP accepted the generic existing notifier test message"
    warn "Inbox arrival, links, SPF and DKIM still require manual verification"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    existing_notifier_smtp_test_entry "$@"
fi
