#!/usr/bin/env bash

# This file is sourced by several entry-point scripts; each caller uses a
# different subset of these shared path variables.
# shellcheck disable=SC2034

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPOSITORY_ROOT="$(cd "${DEPLOY_DIR}/.." && pwd)"

ENV_FILE="${THREADHUB_ENV_FILE:-${DEPLOY_DIR}/.env}"
ENV_EXAMPLE_FILE="${DEPLOY_DIR}/.env.example"
VERSIONS_FILE="${THREADHUB_VERSIONS_FILE:-${DEPLOY_DIR}/versions.env}"
COMPOSE_FILE="${DEPLOY_DIR}/docker-compose.yml"

DOCKER_COMMAND=()
SUDO_COMMAND=()

log() {
    printf '[threadhub] %s\n' "$*"
}

warn() {
    printf '[threadhub] WARNING: %s\n' "$*" >&2
}

die() {
    printf '[threadhub] ERROR: %s\n' "$*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

require_file() {
    [[ -f "$1" ]] || die "Required file not found: $1"
}

runtime_env_mode() {
    local path="$1"

    if stat -c '%a' "${path}" >/dev/null 2>&1; then
        stat -c '%a' "${path}"
    else
        stat -f '%Lp' "${path}"
    fi
}

runtime_env_identity() {
    local path="$1"

    [[ -f "${path}" && ! -L "${path}" ]] || return 1
    if stat -c '%d:%i' "${path}" >/dev/null 2>&1; then
        stat -c '%d:%i' "${path}"
    else
        stat -f '%d:%i' "${path}"
    fi
}

runtime_env_require_secure() {
    local path="$1"
    local mode

    if [[ -L "${path}" || ! -f "${path}" ]]; then
        printf '[ACTION REQUIRED] %s must be an existing regular file, not a symbolic link.\n' \
            "${path}" >&2
        return 20
    fi
    mode="$(runtime_env_mode "${path}")" || return 20
    if [[ "${mode}" != 600 ]]; then
        printf '[ACTION REQUIRED] Protect %s with mode 0600 before continuing; no value was read or changed.\n' \
            "${path}" >&2
        return 20
    fi
}

runtime_env_atomic_tools_available() {
    [[ "$(uname -s)" == Linux ]] || return 1
    command -v mv >/dev/null 2>&1 || return 1
    command -v ln >/dev/null 2>&1 || return 1
    command -v stat >/dev/null 2>&1 || return 1
    mv --help 2>&1 | grep -F -- '--no-target-directory' >/dev/null 2>&1 \
        || return 1
    mv --help 2>&1 | grep -F -- '--no-clobber' >/dev/null 2>&1 \
        || return 1
    ln --help 2>&1 | grep -F -- '--no-target-directory' >/dev/null 2>&1
}

runtime_env_require_atomic_tools() {
    if ! runtime_env_atomic_tools_available; then
        printf '[ACTION REQUIRED] Atomic runtime environment publication requires Ubuntu GNU Coreutils.\n' >&2
        return 20
    fi
}

runtime_env_recovery_path() {
    printf '%s.configure-displaced\n' "$1"
}

runtime_env_require_no_recovery() {
    local env_file="$1"
    local recovery_file

    recovery_file="$(runtime_env_recovery_path "${env_file}")"
    if [[ -e "${recovery_file}" || -L "${recovery_file}" ]]; then
        printf '[ACTION REQUIRED] An interrupted notifier configuration recovery entry is present at %s; no value was read or changed.\n' \
            "${recovery_file}" >&2
        return 20
    fi
}

runtime_env_link_exact_no_clobber() {
    local source_path="$1"
    local destination_path="$2"
    local source_identity

    [[ -f "${source_path}" && ! -L "${source_path}" ]] || return 1
    [[ ! -e "${destination_path}" && ! -L "${destination_path}" ]] || return 1
    source_identity="$(runtime_env_identity "${source_path}")" || return 1
    ln -T -- "${source_path}" "${destination_path}" >/dev/null 2>&1 || return 1
    [[ "$(runtime_env_identity "${destination_path}")" == "${source_identity}" ]]
}

runtime_env_publish_no_clobber() {
    local temporary_env="$1"
    local destination="$2"
    local published_identity
    local temporary_identity

    [[ -f "${temporary_env}" && ! -L "${temporary_env}" ]] || return 1
    [[ "$(runtime_env_mode "${temporary_env}")" == 600 ]] || return 1
    [[ "$(dirname "${temporary_env}")" == "$(dirname "${destination}")" ]] || return 1
    [[ ! -e "${destination}" && ! -L "${destination}" ]] || return 1
    temporary_identity="$(runtime_env_identity "${temporary_env}")" || return 1
    runtime_env_link_exact_no_clobber "${temporary_env}" "${destination}" || return 1
    published_identity="$(runtime_env_identity "${destination}")" || return 1
    if [[ "${published_identity}" != "${temporary_identity}" ]]; then
        return 1
    fi
    rm -f "${temporary_env}"
}

runtime_env_replace_if_unchanged() {
    local replacement="$1"
    local destination="$2"
    local expected_identity="$3"
    local expected_hash="$4"
    local displaced="${destination}.configure-displaced"
    local replacement_identity
    local published_identity

    [[ -f "${replacement}" && ! -L "${replacement}" ]] || return 1
    [[ "$(runtime_env_mode "${replacement}")" == 600 ]] || return 1
    [[ "$(dirname "${replacement}")" == "$(dirname "${destination}")" ]] || return 1
    [[ ! -e "${displaced}" && ! -L "${displaced}" ]] || return 2
    runtime_env_require_secure "${destination}" >/dev/null 2>&1 || return 1
    [[ "$(runtime_env_identity "${destination}")" == "${expected_identity}" ]] || return 1
    [[ "$(sha256_file "${destination}")" == "${expected_hash}" ]] || return 1
    replacement_identity="$(runtime_env_identity "${replacement}")" || return 1

    runtime_env_move_no_clobber "${destination}" "${displaced}" || return 1
    if ! runtime_env_require_secure "${displaced}" >/dev/null 2>&1 \
        || [[ "$(runtime_env_identity "${displaced}")" != "${expected_identity}" ]] \
        || [[ "$(sha256_file "${displaced}")" != "${expected_hash}" ]]; then
        runtime_env_restore_no_clobber "${displaced}" "${destination}" || return 2
        return 1
    fi

    if [[ ! -f "${replacement}" || -L "${replacement}" ]] \
        || [[ "$(runtime_env_mode "${replacement}")" != 600 ]] \
        || [[ "$(runtime_env_identity "${replacement}")" != "${replacement_identity}" ]]; then
        runtime_env_restore_no_clobber "${displaced}" "${destination}" || return 2
        return 1
    fi

    if ! runtime_env_link_exact_no_clobber "${replacement}" "${destination}"; then
        if [[ -e "${destination}" || -L "${destination}" ]]; then
            return 2
        else
            runtime_env_restore_no_clobber "${displaced}" "${destination}" || return 2
        fi
        return 1
    fi
    if ! published_identity="$(runtime_env_identity "${destination}")"; then
        if [[ -e "${destination}" || -L "${destination}" ]]; then
            return 2
        else
            runtime_env_restore_no_clobber "${displaced}" "${destination}" || return 2
        fi
        return 1
    fi
    if [[ "${published_identity}" != "${replacement_identity}" ]]; then
        return 2
    fi
    rm -f "${replacement}" "${displaced}"
}

runtime_env_move_no_clobber() {
    local source_path="$1"
    local destination_path="$2"

    [[ -e "${source_path}" || -L "${source_path}" ]] || return 1
    [[ ! -e "${destination_path}" && ! -L "${destination_path}" ]] || return 1
    mv -T -n "${source_path}" "${destination_path}" >/dev/null 2>&1 || return 1
    [[ ! -e "${source_path}" && ! -L "${source_path}" ]] || return 1
    [[ -e "${destination_path}" || -L "${destination_path}" ]]
}

runtime_env_restore_no_clobber() {
    local displaced="$1"
    local destination="$2"

    [[ -f "${displaced}" && ! -L "${displaced}" ]] || return 1
    [[ ! -e "${destination}" && ! -L "${destination}" ]] || return 1
    runtime_env_link_exact_no_clobber "${displaced}" "${destination}" || return 1
    rm -f "${displaced}"
}

env_value() {
    local key="$1"
    local file="$2"
    local line
    local value

    line="$(awk -v key="${key}" 'index($0, key "=") == 1 { value = substr($0, length(key) + 2) } END { if (value == "") exit 1; print value }' "${file}")" \
        || die "Missing or empty ${key} in ${file}"
    value="${line%$'\r'}"

    if [[ "${value}" == \"*\" && "${value}" == *\" ]]; then
        value="${value:1:${#value}-2}"
    elif [[ "${value}" == \'*\' && "${value}" == *\' ]]; then
        value="${value:1:${#value}-2}"
    fi

    printf '%s' "${value}"
}

env_optional_value() {
    local key="$1"
    local file="$2"
    local value

    value="$(awk -v key="${key}" '
        index($0, key "=") == 1 {
            count++
            value = substr($0, length(key) + 2)
        }
        END {
            if (count != 1) exit 1
            print value
        }
    ' "${file}")" || die "Missing or duplicate ${key} in ${file}"
    value="${value%$'\r'}"

    if [[ "${value}" == \"*\" && "${value}" == *\" ]]; then
        value="${value:1:${#value}-2}"
    elif [[ "${value}" == \'*\' && "${value}" == *\' ]]; then
        value="${value:1:${#value}-2}"
    fi

    printf '%s' "${value}"
}

is_placeholder() {
    local value="$1"
    [[ "${value}" == *REPLACE* || "${value}" == *example.com* || "${value}" == *REGION* ]]
}

validate_domain() {
    local domain="$1"
    [[ "${domain}" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]] \
        || die "THREADHUB_DOMAIN is not a valid DNS hostname"
    is_placeholder "${domain}" && die "THREADHUB_DOMAIN still contains an example value"
    return 0
}

validate_email() {
    local label="$1"
    local email="$2"
    [[ "${email}" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]] \
        || die "${label} is not a valid email address"
    is_placeholder "${email}" && die "${label} still contains an example value"
    return 0
}

validate_base_env() {
    require_file "${ENV_FILE}"
    require_file "${VERSIONS_FILE}"

    local domain
    local letsencrypt_email
    local data_root
    local bind_address
    local bind_port
    local postgres_password

    domain="$(env_value THREADHUB_DOMAIN "${ENV_FILE}")"
    letsencrypt_email="$(env_value LETSENCRYPT_EMAIL "${ENV_FILE}")"
    data_root="$(env_value THREADHUB_DATA_ROOT "${ENV_FILE}")"
    bind_address="$(env_value MATTERMOST_BIND_ADDRESS "${ENV_FILE}")"
    bind_port="$(env_value MATTERMOST_BIND_PORT "${ENV_FILE}")"
    postgres_password="$(env_value POSTGRES_PASSWORD "${ENV_FILE}")"

    validate_domain "${domain}"
    validate_email LETSENCRYPT_EMAIL "${letsencrypt_email}"

    [[ "${data_root}" == "/srv/threadhub" ]] \
        || die "THREADHUB_DATA_ROOT must be exactly /srv/threadhub for the MVP baseline"
    [[ "${bind_address}" == "127.0.0.1" ]] \
        || die "MATTERMOST_BIND_ADDRESS must be 127.0.0.1"
    [[ "${bind_port}" == "8065" ]] \
        || die "MATTERMOST_BIND_PORT must be 8065"
    [[ "${postgres_password}" =~ ^[A-Fa-f0-9]{64}$ ]] \
        || die "POSTGRES_PASSWORD must contain exactly 64 hexadecimal characters"
}

validate_smtp_env() {
    local smtp_server
    local smtp_username
    local smtp_password
    local smtp_from
    local smtp_reply_to

    smtp_server="$(env_value SMTP_SERVER "${ENV_FILE}")"
    smtp_username="$(env_value SMTP_USERNAME "${ENV_FILE}")"
    smtp_password="$(env_value SMTP_PASSWORD "${ENV_FILE}")"
    smtp_from="$(env_value SMTP_FROM_ADDRESS "${ENV_FILE}")"
    smtp_reply_to="$(env_value SMTP_REPLY_TO_ADDRESS "${ENV_FILE}")"

    validate_email SMTP_FROM_ADDRESS "${smtp_from}"
    validate_email SMTP_REPLY_TO_ADDRESS "${smtp_reply_to}"

    is_placeholder "${smtp_server}" && die "SMTP_SERVER still contains an example value"
    is_placeholder "${smtp_username}" && die "SMTP_USERNAME still contains an example value"
    is_placeholder "${smtp_password}" && die "SMTP_PASSWORD still contains an example value"
    return 0
}

validate_notifier_env() {
    local enabled
    local mode
    local channel_ids
    local hmac_secret
    local rate_per_minute
    local channel_id
    local seen_channel_ids=','

    enabled="$(env_value NOTIFIER_ENABLED "${ENV_FILE}")"
    mode="$(env_value NOTIFIER_MODE "${ENV_FILE}")"
    channel_ids="$(env_optional_value NOTIFIER_CHANNEL_IDS "${ENV_FILE}")"
    hmac_secret="$(env_value NOTIFIER_HMAC_SECRET "${ENV_FILE}")"
    rate_per_minute="$(env_value NOTIFIER_RATE_PER_MINUTE "${ENV_FILE}")"

    [[ "${enabled}" == "true" || "${enabled}" == "false" ]] \
        || die "NOTIFIER_ENABLED must be true or false"
    [[ "${mode}" == "all_channels" || "${mode}" == "allowlist" ]] \
        || die "NOTIFIER_MODE must be all_channels or allowlist"
    if [[ -n "${channel_ids}" ]]; then
        [[ "${channel_ids}" =~ ^[a-z0-9]{26}(,[a-z0-9]{26})*$ ]] \
            || die "NOTIFIER_CHANNEL_IDS must contain comma-separated Mattermost channel IDs"
        IFS=',' read -r -a notifier_channel_id_values <<< "${channel_ids}"
        for channel_id in "${notifier_channel_id_values[@]}"; do
            [[ "${channel_id}" =~ ^[a-z0-9]{26}$ ]] \
                || die "NOTIFIER_CHANNEL_IDS must contain comma-separated Mattermost channel IDs"
            [[ "${seen_channel_ids}" != *",${channel_id},"* ]] \
                || die "NOTIFIER_CHANNEL_IDS must not contain duplicates"
            seen_channel_ids+="${channel_id},"
        done
    fi
    if [[ "${mode}" == "all_channels" ]]; then
        [[ -z "${channel_ids}" ]] \
            || die "NOTIFIER_CHANNEL_IDS must be empty in all_channels mode"
    else
        [[ -n "${channel_ids}" ]] \
            || die "NOTIFIER_CHANNEL_IDS must contain at least one ID in allowlist mode"
    fi
    [[ "${hmac_secret}" =~ ^[A-Fa-f0-9]{64}$ ]] \
        || die "NOTIFIER_HMAC_SECRET must contain exactly 64 hexadecimal characters"
    [[ "${rate_per_minute}" =~ ^[0-9]+$ ]] \
        || die "NOTIFIER_RATE_PER_MINUTE must be an integer from 1 through 60"
    ((rate_per_minute >= 1 && rate_per_minute <= 60)) \
        || die "NOTIFIER_RATE_PER_MINUTE must be an integer from 1 through 60"
}

validate_runtime_env() {
    validate_base_env
    validate_smtp_env
    validate_notifier_env
}

sha256_file() {
    local path="$1"

    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "${path}" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "${path}" | awk '{print $1}'
    elif command -v openssl >/dev/null 2>&1; then
        openssl dgst -sha256 "${path}" | awk '{print $NF}'
    else
        die "A SHA-256 command is required"
    fi
}

notifier_control_is_valid() {
    local path="$1"

    require_command jq
    "${SUDO_COMMAND[@]}" test -f "${path}" || return 1
    "${SUDO_COMMAND[@]}" test ! -L "${path}" || return 1
    "${SUDO_COMMAND[@]}" jq -e '
        type == "object" and
        (keys == ["activated_at", "channel_ids", "delivery_enabled", "enabled", "mode"]) and
        (.enabled | type == "boolean") and
        (.delivery_enabled | type == "boolean") and
        (.mode == "all_channels" or .mode == "allowlist") and
        (.channel_ids | type == "array") and
        ([.channel_ids[] | type == "string" and test("^[a-z0-9]{26}$")] | all) and
        (.channel_ids | length == (unique | length)) and
        (.activated_at | type == "number" and floor == . and . >= 0) and
        (if .mode == "all_channels" then (.channel_ids | length == 0) else (.channel_ids | length > 0) end) and
        (if .enabled then (.delivery_enabled and .activated_at > 0) else true end)
    ' "${path}" >/dev/null 2>&1
}

notifier_assert_no_symlink_components() {
    local data_root="$1"
    local path

    for path in \
        "${data_root}" \
        "${data_root}/notifier" \
        "${data_root}/notifier/control" \
        "${data_root}/notifier/mailer" \
        "${data_root}/notifier/release" \
        "${data_root}/mattermost" \
        "${data_root}/mattermost/data" \
        "${data_root}/mattermost/data/plugins" \
        "${data_root}/mattermost/plugins"; do
        "${SUDO_COMMAND[@]}" test ! -L "${path}" \
            || return 1
    done
}

notifier_assert_existing_directory_policy() {
    local path="$1"
    local expected_uid="$2"
    local expected_gid="$3"
    local expected_mode="$4"
    local identity

    "${SUDO_COMMAND[@]}" test ! -e "${path}" && return 0
    "${SUDO_COMMAND[@]}" test -d "${path}" || return 1
    identity="$("${SUDO_COMMAND[@]}" stat -c '%u:%g:%a' "${path}")" || return 1
    [[ "${identity}" == "${expected_uid}:${expected_gid}:${expected_mode}" ]]
}

validate_notifier_host_path() {
    local data_root="$1"
    local srv_identity
    local srv_mode

    [[ "${data_root}" == "/srv/threadhub" ]] \
        || die "Refusing notifier state outside /srv/threadhub"
    notifier_assert_no_symlink_components "${data_root}" \
        || die "Refusing a symbolic-link notifier host path"
    "${SUDO_COMMAND[@]}" test -d /srv || die "/srv must be an existing directory"
    srv_identity="$("${SUDO_COMMAND[@]}" stat -c '%u' /srv)"
    srv_mode="$("${SUDO_COMMAND[@]}" stat -c '%a' /srv)"
    [[ "${srv_identity}" == "0" && "${srv_mode}" =~ ^[0-7]{3,4}$ ]] \
        || die "/srv must be owned by root with a valid mode"
    (( (8#${srv_mode} & 0022) == 0 )) \
        || die "/srv must not be writable by group or other users"
    notifier_assert_existing_directory_policy "${data_root}" 0 0 750 \
        || die "Existing ThreadHub data root must be root:root with mode 0750"
    notifier_assert_existing_directory_policy "${data_root}/notifier" 0 0 750 \
        || die "Existing notifier root must be root:root with mode 0750"
    notifier_assert_existing_directory_policy "${data_root}/notifier/control" 0 3000 750 \
        || die "Existing notifier control directory must be root:3000 with mode 0750"
    notifier_assert_existing_directory_policy "${data_root}/notifier/mailer" 65532 65532 700 \
        || die "Existing notifier Mailer directory must be 65532:65532 with mode 0700"
    notifier_assert_existing_directory_policy "${data_root}/notifier/release" 0 0 750 \
        || die "Existing notifier release directory must be root:root with mode 0750"
    notifier_assert_existing_directory_policy "${data_root}/mattermost" 2000 2000 750 \
        || die "Existing Mattermost root must be 2000:2000 with mode 0750"
    notifier_assert_existing_directory_policy "${data_root}/mattermost/data" 2000 2000 750 \
        || die "Existing Mattermost data directory must be 2000:2000 with mode 0750"
    notifier_assert_existing_directory_policy "${data_root}/mattermost/data/plugins" 2000 2000 750 \
        || die "Existing Mattermost filestore plugin directory must be 2000:2000 with mode 0750"
    notifier_assert_existing_directory_policy "${data_root}/mattermost/plugins" 2000 2000 750 \
        || die "Existing Mattermost runtime plugin directory must be 2000:2000 with mode 0750"
}

validate_notifier_emergency_control_path() {
    local state_file="$1"
    local data_root=/srv/threadhub
    local notifier_root="${data_root}/notifier"
    local control_dir="${notifier_root}/control"
    local srv_identity
    local srv_mode

    [[ "${state_file}" == "${control_dir}/state.json" ]] \
        || die "Refusing emergency control outside the fixed notifier state path"
    for path in "${data_root}" "${notifier_root}" "${control_dir}" "${state_file}"; do
        "${SUDO_COMMAND[@]}" test ! -L "${path}" \
            || die "Refusing a symbolic-link emergency control path"
    done
    "${SUDO_COMMAND[@]}" test -d /srv || die "/srv must be an existing directory"
    srv_identity="$("${SUDO_COMMAND[@]}" stat -c '%u' /srv)"
    srv_mode="$("${SUDO_COMMAND[@]}" stat -c '%a' /srv)"
    [[ "${srv_identity}" == 0 && "${srv_mode}" =~ ^[0-7]{3,4}$ ]] \
        || die "/srv must be owned by root with a valid mode"
    (( (8#${srv_mode} & 0022) == 0 )) \
        || die "/srv must not be writable by group or other users"
    notifier_assert_existing_directory_policy "${data_root}" 0 0 750 \
        || die "Existing ThreadHub data root must be root:root with mode 0750"
    notifier_assert_existing_directory_policy "${notifier_root}" 0 0 750 \
        || die "Existing notifier root must be root:root with mode 0750"
    notifier_assert_existing_directory_policy "${control_dir}" 0 3000 750 \
        || die "Existing notifier control directory must be root:3000 with mode 0750"
}

install_disabled_notifier_control() {
    local data_root="$1"
    local control_dir="${data_root}/notifier/control"
    local state_file="${control_dir}/state.json"
    local staged_file="${control_dir}/.state.json.tmp.$$"
    local local_file

    validate_notifier_host_path "${data_root}"
    "${SUDO_COMMAND[@]}" test -d "${control_dir}" \
        || die "Notifier control directory does not exist"
    "${SUDO_COMMAND[@]}" test ! -L "${state_file}" \
        || die "Refusing symbolic-link notifier control state"
    "${SUDO_COMMAND[@]}" test ! -e "${staged_file}" \
        || die "Refusing existing notifier control staging path"

    local_file="$(mktemp)"
    printf '%s\n' '{"enabled":false,"delivery_enabled":false,"mode":"all_channels","channel_ids":[],"activated_at":0}' \
        > "${local_file}"
    chmod 0600 "${local_file}"
    "${SUDO_COMMAND[@]}" install -o root -g 3000 -m 0640 "${local_file}" "${staged_file}"
    rm -f "${local_file}"
    "${SUDO_COMMAND[@]}" mv -fT "${staged_file}" "${state_file}"
}

ensure_disabled_notifier_control() {
    local data_root="$1"
    local state_file="${data_root}/notifier/control/state.json"

    validate_notifier_host_path "${data_root}"
    if "${SUDO_COMMAND[@]}" test -e "${state_file}"; then
        "${SUDO_COMMAND[@]}" test ! -L "${state_file}" \
            || die "Refusing symbolic-link notifier control state"
        notifier_control_is_valid "${state_file}" \
            || die "Existing notifier control state is invalid and was not overwritten"
        "${SUDO_COMMAND[@]}" chown root:3000 "${state_file}"
        "${SUDO_COMMAND[@]}" chmod 0640 "${state_file}"
        return
    fi
    install_disabled_notifier_control "${data_root}"
}

init_sudo() {
    if [[ "$(id -u)" -eq 0 ]]; then
        SUDO_COMMAND=()
    else
        require_command sudo
        SUDO_COMMAND=(sudo)
    fi
}

secure_nginx_logs() {
    local log_file

    for log_file in \
        /var/log/nginx/threadhub.access.log \
        /var/log/nginx/threadhub.error.log; do
        "${SUDO_COMMAND[@]}" test ! -L "${log_file}" \
            || die "Refusing to manage symbolic-link NGINX log: ${log_file}"
        if ! "${SUDO_COMMAND[@]}" test -e "${log_file}"; then
            "${SUDO_COMMAND[@]}" touch "${log_file}"
        fi
        "${SUDO_COMMAND[@]}" chown www-data:adm "${log_file}"
        "${SUDO_COMMAND[@]}" chmod 0640 "${log_file}"
    done
}

init_docker() {
    require_command docker

    if docker info >/dev/null 2>&1; then
        DOCKER_COMMAND=(docker)
        return
    fi

    init_sudo
    if "${SUDO_COMMAND[@]}" docker info >/dev/null 2>&1; then
        DOCKER_COMMAND=("${SUDO_COMMAND[@]}" docker)
        return
    fi

    die "Docker daemon is unavailable or the current administrator cannot access it"
}

compose() {
    ((${#DOCKER_COMMAND[@]} > 0)) \
        || die "Docker command is not initialized; call init_docker before compose"
    "${DOCKER_COMMAND[@]}" compose \
        --env-file "${ENV_FILE}" \
        --env-file "${VERSIONS_FILE}" \
        -f "${COMPOSE_FILE}" \
        "$@"
}

require_ubuntu_amd64() {
    [[ "$(uname -s)" == "Linux" ]] || die "This operation must run on the target Linux VM"
    require_file /etc/os-release

    # shellcheck disable=SC1091
    source /etc/os-release
    [[ "${ID:-}" == "ubuntu" && "${VERSION_ID:-}" == "24.04" ]] \
        || die "Ubuntu 24.04 LTS is required"

    require_command dpkg
    [[ "$(dpkg --print-architecture)" == "amd64" ]] \
        || die "The target VM must use the amd64 architecture"
}
