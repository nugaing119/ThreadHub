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

existing_notifier_smtp_acceptance_fingerprint() {
    local recipient="$1"
    local temporary_dir
    local response_file
    local diagnostic_file
    local safe_failure
    local status=0

    temporary_dir="$(mktemp -d)"
    response_file="${temporary_dir}/response.json"
    diagnostic_file="${temporary_dir}/diagnostic"
    trap 'rm -rf -- "${temporary_dir}"' RETURN
    chmod 0700 "${temporary_dir}"
    : > "${response_file}"
    : > "${diagnostic_file}"
    chmod 0600 "${response_file}" "${diagnostic_file}"

    printf '%s\n' "${recipient}" \
        | existing_notifier_run_smtp_acceptance \
            >"${response_file}" 2>"${diagnostic_file}" || status=$?
    if [[ "${status}" -ne 0 ]]; then
        safe_failure="$(grep -Eo \
            'error_class=(temporary|permanent|timeout|protocol) smtp_code=[0-9]{1,3}' \
            "${diagnostic_file}" | tail -n 1)" || safe_failure=""
        if [[ ! "${safe_failure}" =~ ^error_class=(temporary|permanent|timeout|protocol)\ smtp_code=[0-9]{1,3}$ ]]; then
            safe_failure='error_class=unavailable smtp_code=0'
        fi
        printf 'threadhub-notifier: smtp_acceptance_phase=mailer %s\n' \
            "${safe_failure}" >&2
        return "${status}"
    fi

    jq -er '
        if type == "object" and keys == ["config_fingerprint"] and
           (.config_fingerprint | type == "string" and test("^[a-f0-9]{64}$"))
        then .config_fingerprint else error("invalid fingerprint") end
    ' "${response_file}" 2>/dev/null || {
        printf '%s\n' \
            'threadhub-notifier: smtp_acceptance_phase=mailer error_class=unavailable smtp_code=0' >&2
        return 1
    }
}

existing_notifier_smtp_test_entry() {
    local state_file
    local marker_file
    local recipient
    local fingerprint
    local recipient_input=interactive

    case "$#:${1:-}" in
        0:) ;;
        1:--recipient-stdin) recipient_input=stdin ;;
        *) die "Usage: $0 [--recipient-stdin]" ;;
    esac
    if [[ "${recipient_input}" == interactive && ! -t 0 ]]; then
        printf '[ACTION REQUIRED] Run ./deploy/scripts/existing-notifier-smtp-test.sh in an interactive terminal.\n' >&2
        printf 'Then rerun: ./deploy/scripts/existing-notifier-setup.sh --resume\n' >&2
        return 20
    fi
    existing_notifier_setup_validate_config || return $?
    existing_notifier_init_compose
    state_file="$(existing_notifier_value THN_DATA_ROOT)/control/state.json"
    marker_file="${state_file%/state.json}/smtp-acceptance.json"
    existing_notifier_validate_control_path "${state_file}"

    if [[ "${recipient_input}" == stdin ]]; then
        IFS= read -r recipient || die "A valid test recipient is required"
    else
        read -r -s -p 'SMTP acceptance test recipient: ' recipient
        printf '\n' >&2
    fi
    validate_email recipient "${recipient}"
    if ! fingerprint="$(existing_notifier_smtp_acceptance_fingerprint "${recipient}")"; then
        recipient=""
        unset recipient
        die "OCI SMTP did not accept the generic existing notifier test message"
    fi
    recipient=""
    unset recipient
    if ! notifier_write_smtp_marker \
        "${marker_file}" "${fingerprint}" "$(notifier_epoch_millis)"; then
        printf '%s\n' \
            'threadhub-notifier: smtp_acceptance_phase=marker error_class=unavailable smtp_code=0' >&2
        return 1
    fi
    log "OCI SMTP accepted the generic existing notifier test message"
    warn "Inbox arrival, links, SPF and DKIM still require manual verification"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    existing_notifier_smtp_test_entry "$@"
fi
