#!/usr/bin/env bash

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

is_placeholder() {
    local value="$1"
    [[ "${value}" == *REPLACE* || "${value}" == *example.com* || "${value}" == *REGION* ]]
}

validate_domain() {
    local domain="$1"
    [[ "${domain}" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]] \
        || die "THREADHUB_DOMAIN is not a valid DNS hostname"
    is_placeholder "${domain}" && die "THREADHUB_DOMAIN still contains an example value"
}

validate_email() {
    local label="$1"
    local email="$2"
    [[ "${email}" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]] \
        || die "${label} is not a valid email address"
    is_placeholder "${email}" && die "${label} still contains an example value"
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
}

validate_runtime_env() {
    validate_base_env
    validate_smtp_env
}

init_sudo() {
    if [[ "$(id -u)" -eq 0 ]]; then
        SUDO_COMMAND=()
    else
        require_command sudo
        SUDO_COMMAND=(sudo)
    fi
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
