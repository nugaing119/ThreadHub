#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"
# shellcheck source=notifier-lib.sh
source "${SCRIPT_DIR}/notifier-lib.sh"

usage() {
    cat <<'EOF'
Usage: notifier-control.sh activate [--from-env]
       notifier-control.sh drain
       notifier-control.sh disable
       notifier-control.sh status

activate --from-env applies the complete notifier target in deploy/.env.
Interactive activate reads mode and allowlist IDs from the terminal so they do
not appear in argv or shell history. drain and disable never delete queue data.
EOF
}

notifier_control_dispatch() {
    local state_file="$1"
    shift
    local command_name="${1:-}"
    local marker_file="${state_file%/state.json}/smtp-acceptance.json"
    local transition_label
    local from_env=false
    local target_enabled
    local target_mode
    local target_channel_ids
    local temporary_dir
    local plugin_list_file
    local mailer_status_file
    local plugin_id
    local notifier_version

    [[ -n "${command_name}" ]] || {
        usage >&2
        return 1
    }
    shift
    require_command jq

    case "${command_name}" in
        status)
            [[ "$#" -eq 0 ]] || die "Usage: $0 status"
            notifier_print_control_status "${state_file}"
            return
            ;;
        drain|disable)
            [[ "$#" -eq 0 ]] || die "Usage: $0 ${command_name}"
            notifier_transition_control_state "${state_file}" "${command_name}" \
                || die "Notifier ${command_name} transition failed"
            if [[ "${command_name}" == drain ]]; then
                transition_label=draining
            else
                transition_label=disabled
            fi
            log "Notifier control is ${transition_label}; queue data was preserved"
            return
            ;;
        activate)
            ;;
        *)
            usage >&2
            return 1
            ;;
    esac

    validate_runtime_env
    if [[ "${1:-}" == --from-env ]]; then
        from_env=true
        shift
    fi
    [[ "$#" -eq 0 ]] || die "Usage: $0 activate [--from-env]"

    if [[ "${from_env}" == true ]]; then
        target_enabled="$(env_value NOTIFIER_ENABLED "${ENV_FILE}")"
        target_mode="$(env_value NOTIFIER_MODE "${ENV_FILE}")"
        target_channel_ids="$(env_optional_value NOTIFIER_CHANNEL_IDS "${ENV_FILE}")"
        if [[ "${target_enabled}" == false ]]; then
            notifier_write_control_state \
                "${state_file}" false false "${target_mode}" "${target_channel_ids}" 0
            log "Notifier target is explicitly disabled; delivery remains physically disabled"
            return
        fi
    else
        [[ -t 0 ]] || die "Interactive activation requires a terminal"
        read -r -p 'Notifier mode [all_channels]: ' target_mode
        target_mode="${target_mode:-all_channels}"
        target_channel_ids=
        if [[ "${target_mode}" == allowlist ]]; then
            read -r -s -p 'Comma-separated Mattermost channel IDs: ' target_channel_ids
            printf '\n' >&2
        fi
        notifier_validate_mode_channels "${target_mode}" "${target_channel_ids}" \
            || die "Notifier mode or channel allowlist is invalid"
    fi

    init_docker
    "${SCRIPT_DIR}/health-check.sh" >/dev/null
    compose exec -T threadhub-mailer /threadhub-mailer healthcheck >/dev/null
    [[ -z "$(compose port threadhub-mailer)" ]] \
        || die "Notifier Mailer unexpectedly publishes a host port"
    notifier_smtp_marker_is_current "${marker_file}" \
        || die "Current SMTP credentials have not passed notifier SMTP acceptance"

    temporary_dir="$(mktemp -d)"
    cleanup_control() {
        rm -rf "${temporary_dir}"
    }
    trap cleanup_control RETURN
    plugin_list_file="${temporary_dir}/plugin-list.json"
    mailer_status_file="${temporary_dir}/mailer-status.json"
    plugin_id="$(env_value NOTIFIER_PLUGIN_ID "${VERSIONS_FILE}")"
    notifier_version="$(env_value NOTIFIER_VERSION "${VERSIONS_FILE}")"
    compose exec -T mattermost \
        mmctl plugin list --local --suppress-warnings --json > "${plugin_list_file}"
    notifier_plugin_list_is_exact_active \
        "${plugin_list_file}" "${plugin_id}" "${notifier_version}" \
        || die "Exact notifier plugin ID and version are not active"
    compose exec -T threadhub-mailer \
        /threadhub-mailer status --json > "${mailer_status_file}"
    notifier_activate_state \
        "${state_file}" "${target_mode}" "${target_channel_ids}" "${mailer_status_file}" \
        || die "Notifier activation requires zero pre-activation pending and sending deliveries"
    log "Notifier delivery is active"
}

notifier_control_entry() {
    local state_file=/srv/threadhub/notifier/control/state.json

    init_sudo
    require_command jq
    validate_notifier_emergency_control_path "${state_file}"
    notifier_control_dispatch "${state_file}" "$@"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    notifier_control_entry "$@"
fi
