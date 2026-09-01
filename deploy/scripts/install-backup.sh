#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

INSTALL_BACKUP_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=backup-common.sh
source "${INSTALL_BACKUP_SCRIPT_DIR}/backup-common.sh"
# shellcheck source=backup-oci.sh
source "${INSTALL_BACKUP_SCRIPT_DIR}/backup-oci.sh"
# shellcheck source=backup-status.sh
source "${INSTALL_BACKUP_SCRIPT_DIR}/backup-status.sh"

BACKUP_SYSTEMD_DIR=/etc/systemd/system
BACKUP_OCI_INSTALL_BASE=/opt/threadhub
BACKUP_OCI_LINK=/usr/local/bin/oci
BACKUP_SERVICE_TEMPLATE=${DEPLOY_DIR}/systemd/threadhub-backup.service.template
BACKUP_TIMER_TEMPLATE=${DEPLOY_DIR}/systemd/threadhub-backup.timer

backup_installer_has_tty() {
    [[ -t 0 && -t 1 ]]
}

backup_installer_expected_uid() {
    printf '0\n'
}

backup_installer_expected_gid() {
    printf '0\n'
}

backup_installer_link_no_clobber() {
    ln -T -- "$1" "$2"
}

backup_installer_symlink_no_clobber() {
    ln -sT -- "$1" "$2"
}

backup_installer_resolve_path() {
    readlink -f "$1"
}

backup_installer_version_value() {
    local key="$1" value

    value="$(env_value "${key}" "${VERSIONS_FILE}")" || return 20
    case "${key}" in
        OCI_CLI_VERSION) [[ "${value}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] ;;
        OCI_CLI_ARCHIVE_SHA256) [[ "${value}" =~ ^[a-f0-9]{64}$ ]] ;;
        *) return 20 ;;
    esac || return 20
    printf '%s\n' "${value}"
}

backup_installer_preflight() {
    [[ "$(id -u)" -eq 0 ]] || return 20
    (require_ubuntu_amd64) >/dev/null 2>&1 || return 20
    [[ -f "${VERSIONS_FILE}" && ! -L "${VERSIONS_FILE}" ]] || return 20
    backup_installer_version_value OCI_CLI_VERSION >/dev/null || return 20
    backup_installer_version_value OCI_CLI_ARCHIVE_SHA256 >/dev/null || return 20
    command -v apt-get >/dev/null 2>&1 || return 20
}

backup_installer_install_dependencies() {
    apt-get update
    env DEBIAN_FRONTEND=noninteractive apt-get install -y \
        ca-certificates curl unzip python3 python3-venv zstd
}

backup_installer_installed_oci_is_exact() {
    local version="$1" install_root executable expected resolved

    install_root="${BACKUP_OCI_INSTALL_BASE}/oci-cli-${version}"
    executable="${install_root}/bin/oci"
    [[ -d "${install_root}" && ! -L "${install_root}" \
        && -x "${executable}" && ! -L "${executable}" \
        && -L "${BACKUP_OCI_LINK}" ]] || return 1
    expected="$(backup_installer_resolve_path "${executable}")" || return 1
    resolved="$(backup_installer_resolve_path "${BACKUP_OCI_LINK}")" || return 1
    [[ "${resolved}" == "${expected}" \
        && "$("${BACKUP_OCI_LINK}" --version 2>/dev/null)" == "${version}" ]]
}

backup_installer_install_oci_cli() (
    local oci_cli_version archive_sha install_root executable archive_url
    local temporary archive extraction wheel expected_wheel archive_names actual_sha uid gid

    oci_cli_version="$(backup_installer_version_value OCI_CLI_VERSION)" || return 20
    archive_sha="$(backup_installer_version_value OCI_CLI_ARCHIVE_SHA256)" || return 20
    uid="$(backup_installer_expected_uid)"
    gid="$(backup_installer_expected_gid)"
    install_root="${BACKUP_OCI_INSTALL_BASE}/oci-cli-${oci_cli_version}"
    executable="${install_root}/bin/oci"
    archive_url="https://github.com/oracle/oci-cli/releases/download/v${oci_cli_version}/oci-cli-${oci_cli_version}.zip"

    if backup_installer_installed_oci_is_exact "${oci_cli_version}"; then
        return 0
    fi
    [[ ! -e "${BACKUP_OCI_LINK}" && ! -L "${BACKUP_OCI_LINK}" ]] || return 20
    [[ ! -e "${install_root}" && ! -L "${install_root}" ]] || return 20
    for command_name in curl unzip python3 readlink; do
        command -v "${command_name}" >/dev/null 2>&1 || return 20
    done
    if [[ ! -e "${BACKUP_OCI_INSTALL_BASE}" && ! -L "${BACKUP_OCI_INSTALL_BASE}" ]]; then
        install -d -o "${uid}" -g "${gid}" -m 0755 "${BACKUP_OCI_INSTALL_BASE}" || return 20
    fi
    [[ -d "${BACKUP_OCI_INSTALL_BASE}" && ! -L "${BACKUP_OCI_INSTALL_BASE}" \
        && "$(backup_path_owner "${BACKUP_OCI_INSTALL_BASE}")" == "${uid}:${gid}" ]] || return 20

    temporary="$(mktemp -d)" || return 30
    archive="${temporary}/oci-cli-${oci_cli_version}.zip"
    extraction="${temporary}/extracted"
    trap 'rm -rf -- "${temporary}"' EXIT
    mkdir -m 0700 "${extraction}"
    curl --proto '=https' --tlsv1.2 --fail --silent --show-error --location \
        "${archive_url}" --output "${archive}" || return 30
    chmod 0600 "${archive}"
    actual_sha="$(sha256_file "${archive}")" || return 30
    [[ "${actual_sha}" == "${archive_sha}" ]] || return 20
    archive_names="${temporary}/archive-names"
    unzip -Z1 "${archive}" > "${archive_names}" || return 30
    chmod 0600 "${archive_names}"
    if awk '
        $0 == "" || $0 ~ /^\// || $0 ~ /(^|\/)\.\.?($|\/)/ || $0 ~ /\\/ { exit 1 }
    ' "${archive_names}"; then
        :
    else
        return 20
    fi
    expected_wheel="oci-cli/oci_cli-${oci_cli_version}-py3-none-any.whl"
    [[ "$(grep -Fxc "${expected_wheel}" "${archive_names}")" == 1 \
        && "$(grep -Ec '^oci-cli/oci_cli-.*\.whl$' "${archive_names}")" == 1 ]] || return 20
    unzip -q "${archive}" "${expected_wheel}" -d "${extraction}" || return 30
    wheel="${extraction}/${expected_wheel}"
    [[ -f "${wheel}" && ! -L "${wheel}" ]] || return 20
    python3 -m venv "${install_root}" || return 30
    "${install_root}/bin/python3" -m pip install \
        --disable-pip-version-check --no-input --no-cache-dir "${wheel}" || return 30
    [[ -x "${executable}" && ! -L "${executable}" \
        && "$("${executable}" --version 2>/dev/null)" == "${oci_cli_version}" ]] || return 20
    backup_installer_symlink_no_clobber "${executable}" "${BACKUP_OCI_LINK}" || return 20
    backup_installer_installed_oci_is_exact "${oci_cli_version}"
)

backup_installer_repository_path() {
    local repository_path physical_path

    repository_path="$(GIT_OPTIONAL_LOCKS=0 git -C "${REPOSITORY_ROOT}" \
        rev-parse --show-toplevel 2>/dev/null)" || return 20
    physical_path="$(cd "${REPOSITORY_ROOT}" && pwd -P)" || return 20
    [[ "${repository_path}" == "${physical_path}" \
        && "${repository_path}" =~ ^/[A-Za-z0-9._/-]+$ \
        && "${repository_path}" != *'//'* \
        && "${repository_path}" != */./* \
        && "${repository_path}" != */../* \
        && "${repository_path}" != */. \
        && "${repository_path}" != */.. \
        && -z "$(GIT_OPTIONAL_LOCKS=0 git -C "${repository_path}" status --porcelain=v1 \
            --untracked-files=all --ignore-submodules=none 2>/dev/null)" ]] || return 20
    printf '%s\n' "${repository_path}"
}

backup_installer_render_units() {
    local destination="$1" repository_path="$2"

    [[ -d "${destination}" && ! -L "${destination}" \
        && "${repository_path}" =~ ^/[A-Za-z0-9._/-]+$ ]] || return 20
    [[ -f "${BACKUP_SERVICE_TEMPLATE}" && ! -L "${BACKUP_SERVICE_TEMPLATE}" \
        && -f "${BACKUP_TIMER_TEMPLATE}" && ! -L "${BACKUP_TIMER_TEMPLATE}" ]] || return 20
    sed "s#__REPOSITORY_ROOT__#${repository_path}#g" \
        "${BACKUP_SERVICE_TEMPLATE}" > "${destination}/threadhub-backup.service" || return 20
    cp "${BACKUP_TIMER_TEMPLATE}" "${destination}/threadhub-backup.timer" || return 20
    chmod 0644 "${destination}/threadhub-backup.service" \
        "${destination}/threadhub-backup.timer"
}

backup_installer_publish_unit() {
    local source="$1" unit_name="$2" destination staged uid gid

    [[ "${unit_name}" == threadhub-backup.service \
        || "${unit_name}" == threadhub-backup.timer ]] || return 20
    [[ -f "${source}" && ! -L "${source}" ]] || return 20
    uid="$(backup_installer_expected_uid)"
    gid="$(backup_installer_expected_gid)"
    destination="${BACKUP_SYSTEMD_DIR}/${unit_name}"
    if [[ -e "${destination}" || -L "${destination}" ]]; then
        [[ -f "${destination}" && ! -L "${destination}" \
            && "$(backup_path_mode "${destination}")" == 644 \
            && "$(backup_path_owner "${destination}")" == "${uid}:${gid}" ]] || return 20
        cmp -s "${source}" "${destination}"
        return
    fi
    staged="${BACKUP_SYSTEMD_DIR}/.${unit_name}.tmp.$$.$RANDOM"
    [[ ! -e "${staged}" && ! -L "${staged}" ]] || return 20
    install -o "${uid}" -g "${gid}" -m 0644 "${source}" "${staged}" || return 20
    if ! backup_installer_link_no_clobber "${staged}" "${destination}"; then
        rm -f -- "${staged}"
        return 20
    fi
    rm -f -- "${staged}"
    [[ -f "${destination}" && ! -L "${destination}" \
        && "$(backup_path_mode "${destination}")" == 644 \
        && "$(backup_path_owner "${destination}")" == "${uid}:${gid}" ]]
}

backup_installer_register_units() (
    local repository_path temporary unit_name

    repository_path="$(backup_installer_repository_path)" || return 20
    [[ -d "${BACKUP_SYSTEMD_DIR}" && ! -L "${BACKUP_SYSTEMD_DIR}" ]] || return 20
    temporary="$(mktemp -d)" || return 30
    trap 'rm -rf -- "${temporary}"' EXIT
    backup_installer_render_units "${temporary}" "${repository_path}" || return 20
    systemd-analyze verify \
        "${temporary}/threadhub-backup.service" \
        "${temporary}/threadhub-backup.timer" >/dev/null 2>&1 || return 20
    for unit_name in threadhub-backup.service threadhub-backup.timer; do
        backup_installer_publish_unit "${temporary}/${unit_name}" "${unit_name}" || return 20
    done
    systemctl daemon-reload
)

backup_installer_validate_activation() {
    local requested_id="$1" remote_prefix

    backup_validate_id "${requested_id}" || return 20
    backup_installer_preflight || return 20
    backup_validate_config || return 20
    backup_prepare_state_root || return 20
    backup_status_file_is_valid "${BACKUP_LATEST_SUCCESS_FILE}" || return 20
    backup_status_main --json >/dev/null 2>&1 || return 20
    jq -e --arg backup_id "${requested_id}" '
        .status == "success" and .phase == "complete" and
        .backup_id == $backup_id and .verification_result == "ok" and
        .snapshot_result == "ok" and .service_recovery_result == "ok" and
        .upload_result == "ok" and .failure_class == "none"
    ' "${BACKUP_LATEST_SUCCESS_FILE}" >/dev/null 2>&1 || return 20
    for unit_name in threadhub-backup.service threadhub-backup.timer; do
        [[ -f "${BACKUP_SYSTEMD_DIR}/${unit_name}" \
            && ! -L "${BACKUP_SYSTEMD_DIR}/${unit_name}" ]] || return 20
    done
    backup_oci_preflight || return 30
    remote_prefix="$(backup_oci_find_set "${requested_id}")" || return 30
    [[ -n "${remote_prefix}" ]]
}

backup_installer_enable_timer() {
    systemctl enable --now threadhub-backup.timer
    systemctl is-enabled --quiet threadhub-backup.timer
    systemctl is-active --quiet threadhub-backup.timer
}

install_backup_entry() {
    local requested_id confirmation

    case "${1:-}" in
        --register)
            (($# == 1)) || return 20
            backup_installer_preflight || return $?
            backup_installer_install_dependencies || return $?
            backup_installer_install_oci_cli || return $?
            backup_installer_register_units || return $?
            printf '[OK] Backup systemd units are installed; the timer was not enabled.\n'
            ;;
        --enable-after-acceptance)
            (($# == 2)) || return 20
            requested_id="$2"
            backup_validate_id "${requested_id}" || return 20
            if ! backup_installer_has_tty; then
                printf '[ACTION REQUIRED] Run ./deploy/scripts/install-backup.sh --enable-after-acceptance BACKUP_ID in an interactive terminal.\n' >&2
                return 20
            fi
            backup_installer_validate_activation "${requested_id}" || return $?
            printf 'Type ENABLE BACKUP TIMER to activate the daily schedule: ' >&2
            read -r confirmation || return 20
            [[ "${confirmation}" == 'ENABLE BACKUP TIMER' ]] || {
                printf '[ACTION REQUIRED] Confirmation did not match; the timer remains unchanged.\n' >&2
                return 20
            }
            backup_installer_enable_timer || return 30
            printf '[OK] Backup timer is enabled and active.\n'
            ;;
        *)
            printf 'Usage: %s --register | --enable-after-acceptance BACKUP_ID\n' "$0" >&2
            return 20
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    install_backup_entry "$@"
fi
