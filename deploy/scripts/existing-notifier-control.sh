#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! declare -F existing_notifier_setup_dispatch >/dev/null 2>&1; then
    # shellcheck source=existing-notifier-setup.sh
    source "${SCRIPT_DIR}/existing-notifier-setup.sh"
fi

existing_notifier_control_usage() {
    cat <<'EOF'
Usage: existing-notifier-control.sh status
       existing-notifier-control.sh drain
       existing-notifier-control.sh disable
       existing-notifier-control.sh activate-allowlist [--channel-ids-stdin]
       existing-notifier-control.sh activate-all-channels

Channel IDs are read from a hidden interactive prompt by default. The explicit
--channel-ids-stdin option supports protected automation without placing IDs in
argv. The all-channel confirmation still requires a real interactive terminal.
Control changes never delete queued delivery data.
EOF
}

existing_notifier_control_action_required() {
    printf '[ACTION REQUIRED] %s\n' "$1" >&2
    return 20
}

existing_notifier_control_assert_runtime() (
    local temporary_dir
    local status_file

    existing_notifier_setup_require_current_smtp_marker || {
        existing_notifier_control_action_required \
            "Current SMTP credentials have not passed existing notifier acceptance"
        return $?
    }
    existing_notifier_setup_verify_mailer \
        || die "Existing notifier Mailer health check failed"
    [[ -z "$(existing_notifier_compose_combined port threadhub-mailer)" ]] \
        || die "Existing notifier Mailer unexpectedly publishes a host port"
    existing_notifier_setup_verify_plugin \
        || die "Exact reviewed notifier plugin pair is not active"

    temporary_dir="$(mktemp -d)"
    trap 'rm -rf -- "${temporary_dir}"' EXIT HUP INT TERM
    status_file="${temporary_dir}/mailer-status.json"
    existing_notifier_compose_combined exec -T threadhub-mailer \
        /threadhub-mailer status --json > "${status_file}"
    notifier_mailer_status_is_valid "${status_file}" \
        || die "Existing notifier Mailer returned invalid status JSON"
    cat "${status_file}"
)

existing_notifier_control_activate() (
    local state_file="$1"
    local mode="$2"
    local channel_ids="$3"
    local status_file

    notifier_validate_mode_channels "${mode}" "${channel_ids}" \
        || die "Notifier mode or channel allowlist is invalid"
    status_file="$(mktemp)"
    trap 'rm -f -- "${status_file}"' EXIT HUP INT TERM
    existing_notifier_control_assert_runtime > "${status_file}" || return $?
    notifier_activate_state "${state_file}" "${mode}" "${channel_ids}" "${status_file}" \
        || die "Activation requires zero pending and sending deliveries"
    notifier_wait_for_control_reload
    rm -f -- "${status_file}"
    trap - EXIT HUP INT TERM
    log "Existing notifier delivery is active in ${mode} mode"
)

existing_notifier_control_dispatch() (
    local state_file="$1"
    local command_name="${2:-}"
    local input_mode=interactive
    local channel_ids
    local confirmation

    [[ "$#" -ge 2 && -n "${command_name}" ]] || {
        existing_notifier_control_usage >&2
        return 1
    }
    case "${command_name}" in
        status)
            [[ "$#" -eq 2 ]] || {
                existing_notifier_control_usage >&2
                return 1
            }
            notifier_print_control_status "${state_file}"
            ;;
        drain|disable)
            [[ "$#" -eq 2 ]] || {
                existing_notifier_control_usage >&2
                return 1
            }
            notifier_transition_control_state "${state_file}" "${command_name}" \
                || die "Notifier ${command_name} transition failed"
            if [[ "${command_name}" == drain ]]; then
                log "Existing notifier is draining; queue data was preserved"
            else
                log "Existing notifier is disabled; queue data was preserved"
            fi
            ;;
        activate-allowlist)
            case "$#:${3:-}" in
                2:) ;;
                3:--channel-ids-stdin) input_mode=stdin ;;
                *)
                    existing_notifier_control_usage >&2
                    return 1
                    ;;
            esac
            if [[ "${input_mode}" == interactive && ! -t 0 ]]; then
                existing_notifier_control_action_required \
                    "Run ./deploy/scripts/existing-notifier-control.sh activate-allowlist in an interactive terminal"
                return $?
            fi
            if [[ "${input_mode}" == stdin ]]; then
                IFS= read -r channel_ids \
                    || die "Notifier channel allowlist is required on stdin"
            else
                read -r -s -p 'Comma-separated Mattermost channel IDs: ' channel_ids
                printf '\n' >&2
            fi
            existing_notifier_control_activate "${state_file}" allowlist "${channel_ids}"
            channel_ids=""
            unset channel_ids
            ;;
        activate-all-channels)
            [[ "$#" -eq 2 ]] || {
                existing_notifier_control_usage >&2
                return 1
            }
            [[ -t 0 ]] || {
                existing_notifier_control_action_required \
                    "Run ./deploy/scripts/existing-notifier-control.sh activate-all-channels in an interactive terminal"
                return $?
            }
            read -r -p 'Type ENABLE ALL CHANNEL EMAILS to continue: ' confirmation
            [[ "${confirmation}" == 'ENABLE ALL CHANNEL EMAILS' ]] || {
                existing_notifier_control_action_required \
                    "All-channel confirmation did not match; delivery state was not changed"
                return $?
            }
            existing_notifier_control_activate "${state_file}" all_channels ''
            ;;
        *)
            existing_notifier_control_usage >&2
            return 1
            ;;
    esac
)

existing_notifier_control_entry() {
    local state_file

    existing_notifier_setup_validate_config || return $?
    existing_notifier_init_compose
    state_file="$(existing_notifier_value THN_DATA_ROOT)/control/state.json"
    existing_notifier_validate_control_path "${state_file}"
    existing_notifier_control_dispatch "${state_file}" "$@"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    existing_notifier_control_entry "$@"
fi
