#!/usr/bin/env bash

# Installer phase functions are replaced by deterministic test hooks.
# Negative assertions intentionally use `! command` inside isolated tests.
# shellcheck disable=SC2016,SC2034,SC2235,SC2251,SC2329

set -Eeuo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(cd "${TEST_DIR}/.." && pwd)"
INSTALLER="${DEPLOY_DIR}/scripts/install-backup.sh"
CONFIGURATOR="${DEPLOY_DIR}/scripts/configure-backup.sh"
VERSIONS="${DEPLOY_DIR}/versions.env"
SERVICE_TEMPLATE="${DEPLOY_DIR}/systemd/threadhub-backup.service.template"
TIMER_TEMPLATE="${DEPLOY_DIR}/systemd/threadhub-backup.timer"
failures=0

fail() { printf 'not ok - %s\n' "$1" >&2; failures=$((failures + 1)); }
pass() { printf 'ok - %s\n' "$1"; }

run_test() {
    local name="$1" function_name="$2" status

    set +e
    ( set -Eeuo pipefail; "${function_name}" )
    status=$?
    set -e
    if ((status == 0)); then pass "${name}"; else fail "${name}"; fi
}

event() { printf '%s\n' "$1" >> "${BACKUP_INSTALLER_TEST_EVENTS}"; }

portable_mode() {
    if stat -c '%a' "$1" >/dev/null 2>&1; then stat -c '%a' "$1"; else stat -f '%Lp' "$1"; fi
}

load_installer_fixture() {
    local fixture="$1"

    [[ -f "${INSTALLER}" ]] || return 1
    # shellcheck source=/dev/null
    source "${INSTALLER}"
    BACKUP_INSTALLER_TEST_EVENTS="${fixture}/events"
    BACKUP_INSTALLER_TEST_TTY=false
    BACKUP_INSTALLER_TEST_STATUS_MATCH=true
    BACKUP_INSTALLER_TEST_TIMER_ACTIVE=false
    : > "${BACKUP_INSTALLER_TEST_EVENTS}"

    backup_installer_preflight() { event preflight; }
    backup_installer_install_dependencies() { event dependencies; }
    backup_installer_install_oci_cli() { event oci-cli; }
    backup_installer_install_docker() { event docker; }
    backup_installer_assert_empty_restore_target() { event empty-target; }
    backup_installer_timer_is_active() { [[ "${BACKUP_INSTALLER_TEST_TIMER_ACTIVE}" == true ]]; }
    backup_installer_register_units() { event register-units; }
    backup_installer_has_tty() { [[ "${BACKUP_INSTALLER_TEST_TTY}" == true ]]; }
    backup_installer_validate_activation() {
        event validate-activation
        [[ "${BACKUP_INSTALLER_TEST_STATUS_MATCH}" == true ]]
    }
    backup_installer_enable_timer() { event enable-timer; }
}

test_versions_pin_an_upstream_archive() (
    [[ "$(awk -F= '$1 == "OCI_CLI_VERSION" { print $2 }' "${VERSIONS}")" == 3.90.3 ]]
    [[ "$(awk -F= '$1 == "OCI_CLI_ARCHIVE_SHA256" { print $2 }' "${VERSIONS}")" \
        == 098a9470ad4f097d505b8dbab6ec7e7d4397d2d5db2ed19ef402ca39cdfdd35d ]]
    [[ "$(awk -F= '$1 == "OCI_CLI_WHEEL_SHA256" { print $2 }' "${VERSIONS}")" \
        == 15a05190a96666e0aa4f029d361563608cae5c66ae28ca51d96186f9d007a3b5 ]]
    grep -F 'oci==2.184.2' "${DEPLOY_DIR}/oci-cli-requirements.lock" >/dev/null
    ! grep -F 'oci-cli==' "${DEPLOY_DIR}/oci-cli-requirements.lock" >/dev/null
)

test_restore_host_bootstrap_installs_without_deploying_or_registering() (
    fixture="$(mktemp -d)"
    trap 'rm -rf "${fixture}"' EXIT
    load_installer_fixture "${fixture}"

    install_backup_entry --prepare-restore-host >"${fixture}/stdout" 2>"${fixture}/stderr"
    [[ "$(<"${BACKUP_INSTALLER_TEST_EVENTS}")" \
        == $'preflight\nempty-target\ndocker\ndependencies\noci-cli\nempty-target' ]]
    ! grep -E 'register-units|enable-timer' "${BACKUP_INSTALLER_TEST_EVENTS}"
    grep -F '[OK] Restore host dependencies are ready; /srv/threadhub remains new or empty.' \
        "${fixture}/stdout" >/dev/null
)

test_registration_refuses_an_already_active_timer() (
    fixture="$(mktemp -d)"
    trap 'rm -rf "${fixture}"' EXIT
    load_installer_fixture "${fixture}"
    BACKUP_INSTALLER_TEST_TIMER_ACTIVE=true

    ! install_backup_entry --register >"${fixture}/stdout" 2>"${fixture}/stderr"
    [[ "$(<"${BACKUP_INSTALLER_TEST_EVENTS}")" == preflight ]]
    grep -F '[ACTION REQUIRED] Backup timer is already active or enabled; registration made no changes.' \
        "${fixture}/stderr" >/dev/null
)

test_register_installs_but_does_not_enable_timer() (
    fixture="$(mktemp -d)"
    trap 'rm -rf "${fixture}"' EXIT
    load_installer_fixture "${fixture}"

    install_backup_entry --register >"${fixture}/stdout" 2>"${fixture}/stderr"
    [[ "$(<"${BACKUP_INSTALLER_TEST_EVENTS}")" \
        == $'preflight\ndependencies\noci-cli\nregister-units' ]]
    ! grep -F enable-timer "${BACKUP_INSTALLER_TEST_EVENTS}" >/dev/null
    grep -F '[OK] Backup systemd units are installed; the timer was not enabled.' \
        "${fixture}/stdout" >/dev/null
)

test_enable_requires_tty_and_verified_success() (
    fixture="$(mktemp -d)"
    trap 'rm -rf "${fixture}"' EXIT
    load_installer_fixture "${fixture}"

    ! install_backup_entry --enable-after-acceptance \
        20260901T030000Z-0123456789abcdef0123456789abcdef \
        >"${fixture}/stdout" 2>"${fixture}/stderr"
    grep -F '[ACTION REQUIRED] Run ./deploy/scripts/install-backup.sh --enable-after-acceptance BACKUP_ID in an interactive terminal.' \
        "${fixture}/stderr" >/dev/null
    [[ ! -s "${BACKUP_INSTALLER_TEST_EVENTS}" ]]

    BACKUP_INSTALLER_TEST_TTY=true
    BACKUP_INSTALLER_TEST_STATUS_MATCH=false
    ! install_backup_entry --enable-after-acceptance \
        20260901T030000Z-0123456789abcdef0123456789abcdef \
        </dev/null >>"${fixture}/stdout" 2>>"${fixture}/stderr"
    grep -Fx validate-activation "${BACKUP_INSTALLER_TEST_EVENTS}" >/dev/null
    ! grep -Fx enable-timer "${BACKUP_INSTALLER_TEST_EVENTS}" >/dev/null
)

test_enable_requires_exact_confirmation() (
    fixture="$(mktemp -d)"
    trap 'rm -rf "${fixture}"' EXIT
    load_installer_fixture "${fixture}"
    BACKUP_INSTALLER_TEST_TTY=true

    ! printf 'yes\n' | install_backup_entry --enable-after-acceptance \
        20260901T030000Z-0123456789abcdef0123456789abcdef \
        >"${fixture}/stdout" 2>"${fixture}/stderr"
    ! grep -Fx enable-timer "${BACKUP_INSTALLER_TEST_EVENTS}" >/dev/null

    : > "${BACKUP_INSTALLER_TEST_EVENTS}"
    printf 'ENABLE BACKUP TIMER\n' | install_backup_entry --enable-after-acceptance \
        20260901T030000Z-0123456789abcdef0123456789abcdef \
        >>"${fixture}/stdout" 2>>"${fixture}/stderr"
    [[ "$(<"${BACKUP_INSTALLER_TEST_EVENTS}")" \
        == $'validate-activation\nenable-timer' ]]
)

test_units_are_hardened_and_disabled_by_registration_contract() (
    [[ -f "${SERVICE_TEMPLATE}" && -f "${TIMER_TEMPLATE}" ]]
    for setting in \
        'Type=oneshot' 'UMask=0077' 'NoNewPrivileges=true' 'PrivateTmp=true' \
        'ProtectSystem=full' 'ProtectHome=read-only' 'RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6'; do
        grep -Fx "${setting}" "${SERVICE_TEMPLATE}" >/dev/null
    done
    grep -Fx 'ExecStart=__REPOSITORY_ROOT__/deploy/scripts/backup.sh' \
        "${SERVICE_TEMPLATE}" >/dev/null
    grep -Fx 'OnCalendar=*-*-* 03:00:00 Asia/Seoul' "${TIMER_TEMPLATE}" >/dev/null
    ! grep -Eq 'WantedBy=.*service|OnBootSec|RandomizedDelaySec' "${SERVICE_TEMPLATE}" "${TIMER_TEMPLATE}"
)

test_installer_and_configurator_are_no_clobber_and_value_safe() (
    [[ -f "${INSTALLER}" && -f "${CONFIGURATOR}" ]]
    grep -F 'oci-cli-${oci_cli_version}.zip' "${INSTALLER}" >/dev/null
    grep -F 'oci_cli-${oci_cli_version}-py3-none-any.whl' "${INSTALLER}" >/dev/null
    grep -F 'OCI_CLI_ARCHIVE_SHA256' "${INSTALLER}" >/dev/null
    grep -F -- '--require-hashes' "${INSTALLER}" >/dev/null
    grep -F -- '--no-index' "${INSTALLER}" >/dev/null
    grep -F 'oci-cli-requirements.lock' "${INSTALLER}" >/dev/null
    grep -F 'ln -T --' "${CONFIGURATOR}" >/dev/null
    ! grep -Eq 'mv -f|install .*backup\.env|systemctl (start|enable) threadhub-backup' \
        "${CONFIGURATOR}"
)

test_configurator_creates_reuses_and_refuses_unsafe_state() (
    fixture="$(mktemp -d)"
    trap 'rm -rf "${fixture}"' EXIT
    [[ -f "${CONFIGURATOR}" ]]
    # shellcheck source=/dev/null
    source "${CONFIGURATOR}"
    BACKUP_ENV_FILE="${fixture}/etc/threadhub/backup.env"
    backup_expected_uid() { id -u; }
    backup_expected_gid() { id -g; }
    backup_configuration_is_privileged() { :; }
    backup_configuration_platform_is_supported() { :; }
    backup_configuration_path_is_supported() { :; }
    backup_configuration_has_tty() { :; }
    backup_configuration_publish_no_clobber() {
        [[ ! -e "$2" && ! -L "$2" ]] || return 1
        ln "$1" "$2"
    }

    printf '%s\n' namespace1 project-backups admin@threadhub.invalid \
        | configure_backup_entry >"${fixture}/stdout" 2>"${fixture}/stderr"
    backup_validate_config
    [[ "$(portable_mode "${BACKUP_ENV_FILE}")" == 600 ]]
    before="$(openssl dgst -sha256 "${BACKUP_ENV_FILE}" | awk '{print $NF}')"
    configure_backup_entry >>"${fixture}/stdout" 2>>"${fixture}/stderr"
    [[ "${before}" == "$(openssl dgst -sha256 "${BACKUP_ENV_FILE}" | awk '{print $NF}')" ]]

    chmod 0644 "${BACKUP_ENV_FILE}"
    ! printf '%s\n' replacement replacement admin@threadhub.invalid \
        | configure_backup_entry >>"${fixture}/stdout" 2>>"${fixture}/stderr"
    [[ "$(awk -F= '$1 == "BACKUP_BUCKET" { print $2 }' "${BACKUP_ENV_FILE}")" \
        == project-backups ]]
    ! grep -Eq 'namespace1|project-backups|admin@threadhub' \
        "${fixture}/stdout" "${fixture}/stderr"
)

test_configurator_adds_existing_source_without_replacing_backup_config() (
    stage=fixture
    trap 'printf "existing-source diagnostic: preconfigure stage=%s failed\n" "${stage}" >&2' ERR
    fixture="$(mktemp -d)"
    trap 'rm -rf "${fixture}"' EXIT
    stage=directory
    mkdir -p "${fixture}/etc/threadhub"
    stage=backup-fixture
    printf '%s\n' \
        'BACKUP_REGION=ap-singapore-1' \
        'BACKUP_NAMESPACE=namespace1' \
        'BACKUP_BUCKET=project-backups' \
        'BACKUP_ALERT_EMAIL=admin@threadhub.invalid' \
        'BACKUP_SCHEDULE=03:00' \
        'BACKUP_DAILY_RETENTION_DAYS=7' \
        'BACKUP_WEEKLY_RETENTION_DAYS=28' > "${fixture}/etc/threadhub/backup.env"
    chmod 0600 "${fixture}/etc/threadhub/backup.env"
    stage=existing-fixture
    printf '%s\n' \
        "THN_COMPOSE_PROJECT_DIR=${fixture}/project" \
        "THN_COMPOSE_FILE=${fixture}/project/compose.yml" \
        "THN_COMPOSE_ENV_FILE=${fixture}/project/base.env" \
        'THN_MATTERMOST_SERVICE=mattermost' \
        "THN_MATTERMOST_PLUGINS_ROOT=${fixture}/mattermost/plugins" \
        "THN_MATTERMOST_DATA_ROOT=${fixture}/mattermost/data" \
        "THN_DATA_ROOT=${fixture}/notifier" \
        'THN_DOMAIN=threadhub.example.test' \
        'THN_SMTP_SERVER=smtp.example.test' \
        'THN_SMTP_PORT=587' \
        'THN_SMTP_CA_FILE=/etc/ssl/certs/ca-certificates.crt' \
        'THN_SMTP_USERNAME=protected-user' \
        'THN_SMTP_PASSWORD=protected-password' \
        'THN_SMTP_FROM_ADDRESS=no-reply@example.test' \
        'THN_SMTP_REPLY_TO_ADDRESS=reply@example.test' \
        'THN_SMTP_FEEDBACK_NAME=ThreadHub' \
        'THN_HMAC_SECRET=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' \
        'THN_RATE_PER_MINUTE=10' > "${fixture}/existing-notifier.env"
    chmod 0600 "${fixture}/existing-notifier.env"

    stage=source-configurator
    [[ -f "${CONFIGURATOR}" ]]
    # shellcheck source=/dev/null
    source "${CONFIGURATOR}"
    BACKUP_ENV_FILE="${fixture}/etc/threadhub/backup.env"
    BACKUP_SOURCE_ENV_FILE="${fixture}/etc/threadhub/backup-source.env"
    THREADHUB_EXISTING_NOTIFIER_ENV_FILE="${fixture}/existing-notifier.env"
    export THREADHUB_EXISTING_NOTIFIER_ENV_FILE
    backup_expected_uid() { id -u; }
    backup_expected_gid() { id -g; }
    backup_configuration_is_privileged() { :; }
    backup_configuration_platform_is_supported() { :; }
    backup_configuration_path_is_supported() { :; }
    backup_configuration_publish_no_clobber() {
        [[ ! -e "$2" && ! -L "$2" ]] || return 1
        ln "$1" "$2"
    }

    stage=backup-hash
    before="$(openssl dgst -sha256 "${BACKUP_ENV_FILE}" | awk '{print $NF}')"
    if ! configure_backup_entry --source-mode existing-notifier \
        >"${fixture}/stdout" 2>"${fixture}/stderr"; then
        printf 'existing-source diagnostic: initial configure failed\n' >&2
        return 1
    fi
    [[ "${before}" == "$(openssl dgst -sha256 "${BACKUP_ENV_FILE}" | awk '{print $NF}')" ]] || {
        printf 'existing-source diagnostic: backup config changed\n' >&2
        return 1
    }
    backup_validate_source_config || {
        printf 'existing-source diagnostic: source config validation failed\n' >&2
        return 1
    }
    [[ "$(portable_mode "${BACKUP_SOURCE_ENV_FILE}")" == 600 ]] || {
        printf 'existing-source diagnostic: source config mode is invalid\n' >&2
        return 1
    }
    source_before="$(openssl dgst -sha256 "${BACKUP_SOURCE_ENV_FILE}" | awk '{print $NF}')"
    if ! configure_backup_entry --source-mode existing-notifier \
        >>"${fixture}/stdout" 2>>"${fixture}/stderr"; then
        printf 'existing-source diagnostic: idempotent configure failed\n' >&2
        return 1
    fi
    [[ "${source_before}" == "$(openssl dgst -sha256 "${BACKUP_SOURCE_ENV_FILE}" | awk '{print $NF}')" ]] || {
        printf 'existing-source diagnostic: source config changed\n' >&2
        return 1
    }
    if grep -F 'protected-password' "${fixture}/stdout" "${fixture}/stderr" >/dev/null; then
        printf 'existing-source diagnostic: protected value was disclosed\n' >&2
        return 1
    fi
)

test_unit_publication_is_idempotent_and_never_overwrites_differences() (
    fixture="$(mktemp -d)"
    trap 'rm -rf "${fixture}"' EXIT
    [[ -f "${INSTALLER}" ]]
    # shellcheck source=/dev/null
    source "${INSTALLER}"
    BACKUP_SYSTEMD_DIR="${fixture}/systemd"
    mkdir -m 0700 "${BACKUP_SYSTEMD_DIR}"
    backup_installer_expected_uid() { id -u; }
    backup_installer_expected_gid() { id -g; }
    backup_installer_link_no_clobber() {
        [[ ! -e "$2" && ! -L "$2" ]] || return 1
        ln "$1" "$2"
    }
    printf '%s\n' '[Unit]' 'Description=fixture' > "${fixture}/source"
    chmod 0644 "${fixture}/source"

    backup_installer_publish_unit "${fixture}/source" threadhub-backup.service
    before="$(openssl dgst -sha256 \
        "${BACKUP_SYSTEMD_DIR}/threadhub-backup.service" | awk '{print $NF}')"
    backup_installer_publish_unit "${fixture}/source" threadhub-backup.service
    printf '%s\n' 'changed' >> "${fixture}/source"
    ! backup_installer_publish_unit "${fixture}/source" threadhub-backup.service
    [[ "${before}" == "$(openssl dgst -sha256 \
        "${BACKUP_SYSTEMD_DIR}/threadhub-backup.service" | awk '{print $NF}')" ]]
    [[ -z "$(find "${BACKUP_SYSTEMD_DIR}" -name '*.tmp.*' -print -quit)" ]]
)

test_oci_installer_verifies_archive_and_exact_wheel_before_linking() (
    fixture="$(mktemp -d)"
    trap 'rm -rf "${fixture}"' EXIT
    [[ -f "${INSTALLER}" ]]
    real_python="$(command -v python3)"
    mkdir -p "${fixture}/bin" "${fixture}/link" "${fixture}/archive/oci-cli"
    printf 'fixture-wheel\n' > "${fixture}/archive/oci-cli/oci_cli-3.90.3-py3-none-any.whl"
    "${real_python}" - "${fixture}/oci.zip" "${fixture}/archive" <<'PY'
import os
import sys
import zipfile

target, source = sys.argv[1:]
with zipfile.ZipFile(target, "w", compression=zipfile.ZIP_STORED) as bundle:
    member = "oci-cli/oci_cli-3.90.3-py3-none-any.whl"
    bundle.write(os.path.join(source, member), member)
PY
    archive_sha="$(openssl dgst -sha256 "${fixture}/oci.zip" | awk '{print $NF}')"
    wheel_sha="$(openssl dgst -sha256 \
        "${fixture}/archive/oci-cli/oci_cli-3.90.3-py3-none-any.whl" | awk '{print $NF}')"
    printf '%s\n' \
        'OCI_CLI_VERSION=3.90.3' \
        "OCI_CLI_ARCHIVE_SHA256=${archive_sha}" \
        "OCI_CLI_WHEEL_SHA256=${wheel_sha}" \
        > "${fixture}/versions.env"
    cat > "${fixture}/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
destination=''
while (($# > 0)); do
    if [[ "$1" == --output ]]; then destination="$2"; shift 2; else shift; fi
done
[[ -n "${destination}" ]]
cp "${OCI_INSTALLER_TEST_ARCHIVE}" "${destination}"
EOF
    cat > "${fixture}/bin/python3" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
if [[ "$1" == -m && "$2" == venv ]]; then
    mkdir -p "$3/bin"
    cp "$0" "$3/bin/python3"
    exit 0
fi
if [[ "$1" == -m && "$2" == pip ]]; then
    printf '%s\n' "${*:3}" >> "${OCI_INSTALLER_TEST_PIP_TRACE}"
    [[ "$3" == install ]] || exit 0
    executable="$(dirname "$0")/oci"
    printf '%s\n' '#!/usr/bin/env bash' \
        '[[ "${1:-}" == --version ]] || exit 2' \
        'printf "%s\\n" "${OCI_INSTALLER_TEST_VERSION}"' > "${executable}"
    chmod 0755 "${executable}"
    exit 0
fi
exit 2
EOF
    cat > "${fixture}/bin/unzip" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
"${OCI_INSTALLER_TEST_REAL_PYTHON}" - "$@" <<'PY'
import sys
import zipfile

arguments = sys.argv[1:]
if len(arguments) == 2 and arguments[0] == "-Z1":
    with zipfile.ZipFile(arguments[1]) as bundle:
        print("\n".join(bundle.namelist()))
elif len(arguments) == 5 and arguments[0] == "-q" and arguments[3] == "-d":
    with zipfile.ZipFile(arguments[1]) as bundle:
        bundle.extract(arguments[2], arguments[4])
else:
    raise SystemExit(2)
PY
EOF
    chmod 0755 "${fixture}/bin/curl" "${fixture}/bin/python3" \
        "${fixture}/bin/unzip"

    # shellcheck source=/dev/null
    source "${INSTALLER}"
    VERSIONS_FILE="${fixture}/versions.env"
    BACKUP_OCI_INSTALL_BASE="${fixture}/opt"
    BACKUP_OCI_LINK="${fixture}/link/oci"
    backup_installer_expected_uid() { id -u; }
    backup_installer_expected_gid() { id -g; }
    backup_installer_symlink_no_clobber() {
        [[ ! -e "$2" && ! -L "$2" ]] || return 1
        ln -s "$1" "$2"
    }
    backup_installer_resolve_path() { realpath "$1"; }
    OCI_INSTALLER_TEST_ARCHIVE="${fixture}/oci.zip"
    OCI_INSTALLER_TEST_VERSION=3.90.3
    OCI_INSTALLER_TEST_PIP_TRACE="${fixture}/pip.trace"
    OCI_INSTALLER_TEST_REAL_PYTHON="${real_python}"
    export OCI_INSTALLER_TEST_ARCHIVE OCI_INSTALLER_TEST_VERSION \
        OCI_INSTALLER_TEST_PIP_TRACE OCI_INSTALLER_TEST_REAL_PYTHON

    PATH="${fixture}/bin:${PATH}" backup_installer_install_oci_cli
    [[ -L "${BACKUP_OCI_LINK}" ]]
    [[ "$("${BACKUP_OCI_LINK}" --version)" == 3.90.3 ]]
    grep -F 'download --disable-pip-version-check --no-input --no-cache-dir --require-hashes --only-binary=:all:' \
        "${OCI_INSTALLER_TEST_PIP_TRACE}" >/dev/null
    grep -F 'install --disable-pip-version-check --no-input --no-cache-dir --no-index --require-hashes --only-binary=:all:' \
        "${OCI_INSTALLER_TEST_PIP_TRACE}" >/dev/null

    rm "${BACKUP_OCI_LINK}"
    rm -rf "${BACKUP_OCI_INSTALL_BASE}"
    sed 's/^OCI_CLI_ARCHIVE_SHA256=.*/OCI_CLI_ARCHIVE_SHA256=ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff/' \
        "${fixture}/versions.env" > "${fixture}/wrong.env"
    VERSIONS_FILE="${fixture}/wrong.env"
    ! PATH="${fixture}/bin:${PATH}" backup_installer_install_oci_cli
    [[ ! -e "${BACKUP_OCI_LINK}" && ! -L "${BACKUP_OCI_LINK}" ]]
)

test_wizard_registers_and_status_separates_backup_readiness() (
    grep -F 'install-backup.sh" --register' "${DEPLOY_DIR}/scripts/setup-wizard.sh" >/dev/null
    grep -F 'ok "Backup systemd units are installed and disabled pending acceptance"' \
        "${DEPLOY_DIR}/scripts/install-status.sh" >/dev/null
    grep -F '[MANUAL] Configure the exact project bucket and complete backup/restore acceptance before enabling the timer.' \
        "${DEPLOY_DIR}/scripts/install-status.sh" >/dev/null
)

test_activation_reverifies_the_exact_remote_set() (
    grep -F 'backup_oci_verify_remote_set "${remote_prefix}" "${requested_id}"' \
        "${INSTALLER}" >/dev/null
)

run_test 'versions pin the verified upstream OCI CLI archive' test_versions_pin_an_upstream_archive
run_test 'registration installs without enabling the timer' test_register_installs_but_does_not_enable_timer
run_test 'restore-host bootstrap installs no application or units' test_restore_host_bootstrap_installs_without_deploying_or_registering
run_test 'registration refuses an already-active timer' test_registration_refuses_an_already_active_timer
run_test 'activation requires a TTY and verified latest success' test_enable_requires_tty_and_verified_success
run_test 'activation requires exact interactive confirmation' test_enable_requires_exact_confirmation
run_test 'backup units are hardened and registration-safe' test_units_are_hardened_and_disabled_by_registration_contract
run_test 'installer and configurator preserve no-clobber contracts' test_installer_and_configurator_are_no_clobber_and_value_safe
run_test 'configurator creates, reuses and refuses unsafe state' test_configurator_creates_reuses_and_refuses_unsafe_state
run_test 'configurator adds existing source without replacing backup config' \
    test_configurator_adds_existing_source_without_replacing_backup_config
run_test 'unit publication is idempotent and no-clobber' test_unit_publication_is_idempotent_and_never_overwrites_differences
run_test 'OCI installer verifies the archive and exact wheel' test_oci_installer_verifies_archive_and_exact_wheel_before_linking
run_test 'wizard and status keep backup readiness separate' test_wizard_registers_and_status_separates_backup_readiness
run_test 'activation reverifies the exact remote set' test_activation_reverifies_the_exact_remote_set

if ((failures > 0)); then
    printf '%d backup installer test(s) failed\n' "${failures}" >&2
    exit 1
fi
