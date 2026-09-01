#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

CONFIGURE_BACKUP_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=backup-common.sh
source "${CONFIGURE_BACKUP_SCRIPT_DIR}/backup-common.sh"

backup_configuration_has_tty() {
    [[ -t 0 && -t 1 ]]
}

backup_configuration_is_privileged() {
    [[ "$(id -u)" -eq 0 ]]
}

backup_configuration_platform_is_supported() {
    (require_ubuntu_amd64) >/dev/null 2>&1
}

backup_configuration_path_is_supported() {
    [[ "${BACKUP_ENV_FILE}" == /etc/threadhub/backup.env ]]
}

backup_configuration_publish_no_clobber() {
    ln -T -- "$1" "$2"
}

backup_configuration_prompt() {
    local label="$1" validator="$2" value

    while true; do
        read -r -p "${label}: " value || return 20
        [[ -n "${value}" && "${value}" != *$'\r'* && "${value}" != *$'\n'* ]] || {
            warn "A single-line value is required"
            continue
        }
        if "${validator}" "${value}"; then
            printf '%s\n' "${value}"
            return 0
        fi
        warn "The value does not match the required format"
    done
}

configure_backup_entry() {
    local config_parent original_config temporary namespace bucket alert_email uid gid

    if (($# != 0)); then
        printf 'Usage: %s\n' "$0" >&2
        return 20
    fi
    backup_configuration_is_privileged || {
        printf '[ACTION REQUIRED] Run sudo ./deploy/scripts/configure-backup.sh in an interactive terminal.\n' >&2
        return 20
    }
    backup_configuration_platform_is_supported || return 20
    config_parent="$(dirname "${BACKUP_ENV_FILE}")"
    backup_configuration_path_is_supported || return 20
    uid="$(backup_expected_uid)"
    gid="$(backup_expected_gid)"

    if [[ -e "${BACKUP_ENV_FILE}" || -L "${BACKUP_ENV_FILE}" ]]; then
        if backup_validate_config; then
            log "Reusing the existing protected backup configuration; no value was replaced"
            return 0
        fi
        printf '[ACTION REQUIRED] Existing backup configuration is unsafe or incomplete and was not changed.\n' >&2
        return 20
    fi
    backup_configuration_has_tty || {
        printf '[ACTION REQUIRED] Run sudo ./deploy/scripts/configure-backup.sh in an interactive terminal.\n' >&2
        return 20
    }

    if [[ ! -e "${config_parent}" && ! -L "${config_parent}" ]]; then
        install -d -o "${uid}" -g "${gid}" -m 0750 "${config_parent}" || return 20
    fi
    backup_require_directory_mode_owner "${config_parent}" 750 "${uid}" "${gid}" || return 20
    namespace="$(backup_configuration_prompt 'OCI Object Storage namespace' backup_validate_namespace)" \
        || return 20
    bucket="$(backup_configuration_prompt 'Project-private backup bucket' backup_validate_bucket)" \
        || return 20
    alert_email="$(backup_configuration_prompt 'Backup failure recipient' backup_validate_email)" \
        || return 20

    temporary="$(mktemp "${config_parent}/.backup.env.tmp.XXXXXX")" || return 20
    cleanup_backup_configuration() {
        rm -f -- "${temporary}"
    }
    trap cleanup_backup_configuration EXIT
    {
        printf '%s\n' 'BACKUP_REGION=ap-singapore-1'
        printf 'BACKUP_NAMESPACE=%s\n' "${namespace}"
        printf 'BACKUP_BUCKET=%s\n' "${bucket}"
        printf 'BACKUP_ALERT_EMAIL=%s\n' "${alert_email}"
        printf '%s\n' \
            'BACKUP_SCHEDULE=03:00' \
            'BACKUP_DAILY_RETENTION_DAYS=7' \
            'BACKUP_WEEKLY_RETENTION_DAYS=28'
    } > "${temporary}"
    chown "${uid}:${gid}" "${temporary}"
    chmod 0600 "${temporary}"

    original_config="${BACKUP_ENV_FILE}"
    BACKUP_ENV_FILE="${temporary}"
    if ! backup_validate_config; then
        BACKUP_ENV_FILE="${original_config}"
        return 20
    fi
    BACKUP_ENV_FILE="${original_config}"
    if ! backup_configuration_publish_no_clobber "${temporary}" "${BACKUP_ENV_FILE}"; then
        printf '[ACTION REQUIRED] Backup configuration appeared concurrently and was not overwritten.\n' >&2
        return 20
    fi
    rm -f -- "${temporary}"
    trap - EXIT
    backup_validate_config || return 20
    log "Created protected project backup configuration; values were not printed"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    configure_backup_entry "$@"
fi
