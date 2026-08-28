#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"
# shellcheck source=notifier-lib.sh
source "${SCRIPT_DIR}/notifier-lib.sh"

configure_only=false
non_interactive=false
threadhub_domain=
letsencrypt_email=
oci_email_region=
smtp_server=
smtp_username=
smtp_password=
smtp_from_address=
smtp_reply_to_address=
smtp_feedback_name=
postgres_password=
notifier_hmac_secret=

usage() {
    cat <<'EOF'
Usage: setup-wizard.sh [--resume] [--configure-only] [--non-interactive]

  --resume           Continue an interrupted installation without replacing deploy/.env.
  --configure-only   Create and validate deploy/.env, then stop before installing packages.
  --non-interactive  Never prompt. A complete protected deploy/.env must already exist.

The wizard never creates OCI, DNS, IAM, or SMTP resources. It prints an exact
action-required message when an external prerequisite is missing.
EOF
}

while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --resume)
            ;;
        --configure-only)
            configure_only=true
            ;;
        --non-interactive)
            non_interactive=true
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            usage >&2
            die "Unknown argument: $1"
            ;;
    esac
    shift
done

require_ubuntu_amd64
init_sudo
require_command openssl
require_command stat
require_command mv
require_command ln
set +e
runtime_env_require_atomic_tools
atomic_tools_result=$?
set -e
((atomic_tools_result == 0)) || exit "${atomic_tools_result}"
set +e
runtime_env_require_no_recovery "${ENV_FILE}"
recovery_result=$?
set -e
((recovery_result == 0)) || exit "${recovery_result}"

prompt_required() {
    local variable_name="$1"
    local label="$2"
    local default_value="${3:-}"
    local secret="${4:-false}"
    local prompt
    local value

    while true; do
        prompt="${label}"
        if [[ -n "${default_value}" ]]; then
            prompt+=" [${default_value}]"
        fi
        prompt+=": "

        if [[ "${secret}" == "true" ]]; then
            read -r -s -p "${prompt}" value
            printf '\n'
        else
            read -r -p "${prompt}" value
        fi

        value="${value:-${default_value}}"
        if [[ -z "${value}" ]]; then
            warn "A value is required for ${label}"
            continue
        fi
        if [[ "${value}" == *$'\n'* || "${value}" == *$'\r'* || "${value}" == *"'"* ]]; then
            warn "${label} must be a single line and cannot contain a single quote"
            continue
        fi

        printf -v "${variable_name}" '%s' "${value}"
        return
    done
}

prompt_domain() {
    local variable_name="$1"
    local label="$2"
    local candidate

    while true; do
        prompt_required candidate "${label}"
        if (validate_domain "${candidate}") >/dev/null 2>&1; then
            printf -v "${variable_name}" '%s' "${candidate}"
            return
        fi
        warn "Enter a public fully qualified domain name that does not use example placeholders"
    done
}

prompt_email() {
    local variable_name="$1"
    local label="$2"
    local default_value="${3:-}"
    local candidate

    while true; do
        prompt_required candidate "${label}" "${default_value}"
        if (validate_email "${label}" "${candidate}") >/dev/null 2>&1; then
            printf -v "${variable_name}" '%s' "${candidate}"
            return
        fi
        warn "Enter a complete email address that does not use example placeholders"
    done
}

write_env_value() {
    local key="$1"
    local value="$2"
    printf "%s='%s'\n" "${key}" "${value}"
}

data_root=/srv/threadhub

if [[ -e "${ENV_FILE}" || -L "${ENV_FILE}" ]]; then
    set +e
    runtime_env_require_secure "${ENV_FILE}"
    secure_env_result=$?
    set -e
    ((secure_env_result == 0)) || exit "${secure_env_result}"
    case "$(notifier_env_key_state "${ENV_FILE}")" in
        complete)
            validate_runtime_env
            log "Reusing the existing protected runtime environment; no value was replaced"
            ;;
        none)
            printf '[ACTION REQUIRED] Run ./deploy/scripts/configure-notifier.sh\n' >&2
            exit 20
            ;;
        *)
            printf '[ACTION REQUIRED] Notifier configuration is partial; restore either all or none of the notifier keys, then run ./deploy/scripts/configure-notifier.sh\n' >&2
            exit 20
            ;;
    esac
else
    if [[ "${non_interactive}" == "true" ]]; then
        printf '[ACTION REQUIRED] Create %s from deploy/.env.example and protect it with mode 0600.\n' \
            "${ENV_FILE}" >&2
        printf 'Then rerun: ./deploy/scripts/setup-wizard.sh --resume --non-interactive\n' >&2
        exit 20
    fi
    [[ -t 0 ]] || {
        printf '[ACTION REQUIRED] A terminal is required to enter SMTP credentials without echo.\n' >&2
        printf 'Run: ./deploy/scripts/setup-wizard.sh --configure-only\n' >&2
        exit 20
    }

    if "${SUDO_COMMAND[@]}" test -d "${data_root}" \
        && "${SUDO_COMMAND[@]}" find "${data_root}" -mindepth 1 -maxdepth 1 -print -quit \
            | grep -q .; then
        die "Existing data was found under ${data_root} without a matching deploy/.env; refusing to attach new credentials"
    fi

    log "Collecting project-owned values. SMTP secrets are hidden while typed."
    prompt_domain threadhub_domain "ThreadHub public domain"
    prompt_email letsencrypt_email "Let's Encrypt contact email"

    while true; do
        prompt_required oci_email_region "OCI Email Delivery region (for example ap-singapore-1)"
        if [[ "${oci_email_region}" =~ ^[a-z0-9]+(-[a-z0-9]+)+-[0-9]+$ ]]; then
            break
        fi
        warn "Enter an OCI commercial region identifier such as ap-singapore-1"
    done

    smtp_server="smtp.email.${oci_email_region}.oci.oraclecloud.com"
    prompt_required smtp_username "OCI SMTP username"
    prompt_required smtp_password "OCI SMTP password" "" true
    prompt_email smtp_from_address "Approved sender address"
    prompt_email smtp_reply_to_address "Reply-to address" "${letsencrypt_email}"
    prompt_required smtp_feedback_name "Sender display name" "ThreadHub"
    postgres_password="$(openssl rand -hex 32)"
    notifier_hmac_secret="$(openssl rand -hex 32)"

    umask 077
    temporary_env="$(mktemp "${DEPLOY_DIR}/.env.tmp.XXXXXX")"
    cleanup_env() {
        rm -f "${temporary_env}"
    }
    trap cleanup_env EXIT

    {
        printf '%s\n' 'COMPOSE_PROJECT_NAME=threadhub' 'TZ=Asia/Seoul'
        write_env_value THREADHUB_DOMAIN "${threadhub_domain}"
        write_env_value LETSENCRYPT_EMAIL "${letsencrypt_email}"
        printf '%s\n' \
            'THREADHUB_DATA_ROOT=/srv/threadhub' \
            'MATTERMOST_BIND_ADDRESS=127.0.0.1' \
            'MATTERMOST_BIND_PORT=8065' \
            'POSTGRES_USER=mmuser'
        write_env_value POSTGRES_PASSWORD "${postgres_password}"
        printf '%s\n' 'POSTGRES_DB=mattermost'
        write_env_value SMTP_SERVER "${smtp_server}"
        printf '%s\n' 'SMTP_PORT=587'
        write_env_value SMTP_USERNAME "${smtp_username}"
        write_env_value SMTP_PASSWORD "${smtp_password}"
        write_env_value SMTP_FROM_ADDRESS "${smtp_from_address}"
        write_env_value SMTP_REPLY_TO_ADDRESS "${smtp_reply_to_address}"
        write_env_value SMTP_FEEDBACK_NAME "${smtp_feedback_name}"
        printf '%s\n' \
            'NOTIFIER_ENABLED=true' \
            'NOTIFIER_MODE=all_channels' \
            'NOTIFIER_CHANNEL_IDS='
        write_env_value NOTIFIER_HMAC_SECRET "${notifier_hmac_secret}"
        printf '%s\n' 'NOTIFIER_RATE_PER_MINUTE=10'
    } > "${temporary_env}"
    chmod 0600 "${temporary_env}"

    original_env_file="${ENV_FILE}"
    ENV_FILE="${temporary_env}"
    validate_runtime_env
    ENV_FILE="${original_env_file}"

    if ! runtime_env_publish_no_clobber "${temporary_env}" "${ENV_FILE}"; then
        printf '[ACTION REQUIRED] Runtime environment appeared during configuration; it was not overwritten.\n' >&2
        exit 20
    fi
    trap - EXIT
    log "Created ${ENV_FILE} with mode 0600 and automatically generated protected secrets"
fi

if [[ "${configure_only}" == "true" ]]; then
    log "Runtime configuration is ready. Continue with ./deploy/scripts/setup-wizard.sh --resume"
    exit 0
fi

docker_versions_match() {
    local actual_engine
    local actual_compose
    local expected_engine
    local expected_compose

    command -v docker >/dev/null 2>&1 || return 1
    actual_engine="$("${SUDO_COMMAND[@]}" docker version --format '{{.Server.Version}}' 2>/dev/null)" \
        || return 1
    actual_compose="$("${SUDO_COMMAND[@]}" docker compose version --short 2>/dev/null)" \
        || return 1
    expected_engine="$(env_value DOCKER_CE_VERSION "${VERSIONS_FILE}")"
    expected_engine="${expected_engine#*:}"
    expected_engine="${expected_engine%%-*}"
    expected_compose="$(env_value DOCKER_COMPOSE_PLUGIN_VERSION "${VERSIONS_FILE}")"
    expected_compose="${expected_compose%%-*}"

    [[ "${actual_engine}" == "${expected_engine}" && "${actual_compose}" == "${expected_compose}" ]]
}

if docker_versions_match; then
    log "Pinned Docker Engine and Compose versions are already installed"
else
    "${SCRIPT_DIR}/install-docker.sh"
fi

"${SCRIPT_DIR}/deploy.sh"

domain="$(env_value THREADHUB_DOMAIN "${ENV_FILE}")"
if ! getent ahostsv4 "${domain}" | awk '{ print $1 }' | grep -q .; then
    printf '\n[ACTION REQUIRED] DNS does not currently publish an IPv4 A record for %s.\n' \
        "${domain}" >&2
    printf 'Add an A record that points this hostname to the VM reserved public IP.\n' >&2
    printf 'Do not overwrite unrelated records. After DNS propagation, rerun:\n' >&2
    printf '  ./deploy/scripts/setup-wizard.sh --resume\n' >&2
    exit 20
fi

certificate_dir="/etc/letsencrypt/live/${domain}"
if "${SUDO_COMMAND[@]}" test -f "${certificate_dir}/fullchain.pem" \
    && "${SUDO_COMMAND[@]}" test -f "${certificate_dir}/privkey.pem" \
    && "${SUDO_COMMAND[@]}" systemctl is-active --quiet nginx; then
    "${SCRIPT_DIR}/reload-nginx.sh"
else
    "${SCRIPT_DIR}/configure-nginx.sh"
fi

target_notifier_enabled="$(env_value NOTIFIER_ENABLED "${ENV_FILE}")"
data_root="$(env_value THREADHUB_DATA_ROOT "${ENV_FILE}")"
smtp_marker="${data_root}/notifier/control/smtp-acceptance.json"
if [[ "${target_notifier_enabled}" == true ]]; then
    init_docker
    if ! notifier_smtp_marker_is_current "${smtp_marker}"; then
        notifier_require_smtp_handoff "${non_interactive}"
        "${SCRIPT_DIR}/notifier-smtp-test.sh"
    fi
fi
"${SCRIPT_DIR}/notifier-control.sh" activate --from-env
"${SCRIPT_DIR}/readiness-check.sh"
"${SCRIPT_DIR}/install-status.sh"
