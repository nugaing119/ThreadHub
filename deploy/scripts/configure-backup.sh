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
    [[ "${BACKUP_ENV_FILE}" == /etc/threadhub/backup.env \
        && "${BACKUP_SOURCE_ENV_FILE}" == /etc/threadhub/backup-source.env ]]
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
    local source_mode=canonical existing_env source_temporary original_source_config

    cleanup_backup_configuration() {
        [[ -z "${temporary:-}" ]] || rm -f -- "${temporary}"
        [[ -z "${source_temporary:-}" ]] || rm -f -- "${source_temporary}"
    }
    trap cleanup_backup_configuration EXIT

    if (($# == 2)) && [[ "$1" == --source-mode && "$2" == existing-notifier ]]; then
        source_mode=existing_notifier
    elif (($# != 0)); then
        printf 'Usage: %s [--source-mode existing-notifier]\n' "$0" >&2
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

    if [[ "${source_mode}" == existing_notifier ]]; then
        existing_env="${THREADHUB_EXISTING_NOTIFIER_ENV_FILE:-${DEPLOY_DIR}/existing-notifier.env}"
        export THREADHUB_EXISTING_NOTIFIER_ENV_FILE="${existing_env}"
        # shellcheck source=existing-notifier-common.sh
        source "${CONFIGURE_BACKUP_SCRIPT_DIR}/existing-notifier-common.sh"
        existing_notifier_validate_config >/dev/null 2>&1 || {
            printf '[ACTION REQUIRED] The protected existing-notifier configuration is invalid and was not changed.\n' >&2
            return 20
        }
    fi

    if [[ -e "${BACKUP_ENV_FILE}" || -L "${BACKUP_ENV_FILE}" ]]; then
        if backup_validate_config; then
            log "Reusing the existing protected backup configuration; no value was replaced"
        else
            printf '[ACTION REQUIRED] Existing backup configuration is unsafe or incomplete and was not changed.\n' >&2
            return 20
        fi
    else
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
        temporary=''
        backup_validate_config || return 20
        log "Created protected project backup configuration; values were not printed"
    fi

    if [[ "${source_mode}" == existing_notifier ]]; then
        if backup_source_config_is_present; then
            backup_validate_source_config || {
                printf '[ACTION REQUIRED] Existing backup source configuration is unsafe or incomplete and was not changed.\n' >&2
                return 20
            }
            [[ "$(backup_existing_notifier_env_file)" == "${existing_env}" ]] || return 20
            log "Reusing the existing protected backup source configuration; no value was replaced"
        else
            source_temporary="$(mktemp "${config_parent}/.backup-source.env.tmp.XXXXXX")" || return 20
            {
                printf '%s\n' 'BACKUP_SOURCE_MODE=existing_notifier'
                printf 'BACKUP_EXISTING_NOTIFIER_ENV_FILE=%s\n' "${existing_env}"
            } > "${source_temporary}"
            chown "${uid}:${gid}" "${source_temporary}"
            chmod 0600 "${source_temporary}"
            original_source_config="${BACKUP_SOURCE_ENV_FILE}"
            BACKUP_SOURCE_ENV_FILE="${source_temporary}"
            if ! backup_validate_source_config; then
                BACKUP_SOURCE_ENV_FILE="${original_source_config}"
                return 20
            fi
            BACKUP_SOURCE_ENV_FILE="${original_source_config}"
            if ! backup_configuration_publish_no_clobber \
                "${source_temporary}" "${BACKUP_SOURCE_ENV_FILE}"; then
                printf '[ACTION REQUIRED] Backup source configuration appeared concurrently and was not overwritten.\n' >&2
                return 20
            fi
            source_temporary=''
            backup_validate_source_config || return 20
            log "Created protected existing-notifier backup source configuration; paths were not printed"
        fi
    fi
    trap - EXIT
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    configure_backup_entry "$@"
fi
