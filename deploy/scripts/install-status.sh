#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    cat <<'EOF'
Usage: install-status.sh

Reports installation readiness without printing deploy/.env or credential values.
Exit codes: 0 ready, 1 failed validation, 20 user or external action required.
EOF
    exit 0
fi
[[ "$#" -eq 0 ]] || die "Usage: $0"

failure=false
action_required=false

ok() {
    printf '[OK] %s\n' "$*"
}

fail() {
    printf '[FAILED] %s\n' "$*" >&2
    failure=true
}

action() {
    printf '[ACTION REQUIRED] %s\n' "$*" >&2
    action_required=true
}

if (require_ubuntu_amd64) >/dev/null 2>&1; then
    ok "Ubuntu 24.04 AMD64 target"
else
    action "Run the installer on an Ubuntu 24.04 AMD64 VM"
    exit 20
fi

if [[ ! -f "${ENV_FILE}" ]]; then
    action "Create deploy/.env with ./deploy/scripts/setup-wizard.sh --configure-only"
    exit 20
fi

env_mode="$(stat -c '%a' "${ENV_FILE}")"
if [[ "${env_mode}" == "600" ]]; then
    ok "deploy/.env is protected with mode 0600"
else
    fail "deploy/.env mode is ${env_mode}; run chmod 600 deploy/.env"
fi

if (validate_runtime_env) >/dev/null 2>&1; then
    ok "Runtime domain, database and SMTP configuration"
    runtime_valid=true
else
    fail "Runtime configuration is incomplete or contains placeholders"
    runtime_valid=false
fi

if command -v docker >/dev/null 2>&1; then
    if "${SCRIPT_DIR}/health-check.sh" >/dev/null 2>&1; then
        ok "Mattermost and PostgreSQL container health and persistence checks"
        containers_ready=true
    else
        action "Run ./deploy/scripts/setup-wizard.sh --resume to install or repair containers"
        containers_ready=false
    fi
else
    action "Docker is not installed; run ./deploy/scripts/setup-wizard.sh --resume"
    containers_ready=false
fi

if [[ "${runtime_valid}" == "true" ]]; then
    domain="$(env_value THREADHUB_DOMAIN "${ENV_FILE}")"
    if getent ahostsv4 "${domain}" | awk '{ print $1 }' | grep -q .; then
        ok "Public IPv4 DNS record for the configured hostname"
        dns_ready=true
    else
        action "Publish an A record for the configured hostname, then rerun the wizard"
        dns_ready=false
    fi

    init_sudo
    if "${SUDO_COMMAND[@]}" systemctl is-active --quiet nginx \
        && "${SUDO_COMMAND[@]}" test -f "/etc/letsencrypt/live/${domain}/fullchain.pem" \
        && "${SUDO_COMMAND[@]}" test -f "/etc/letsencrypt/live/${domain}/privkey.pem"; then
        ok "NGINX and Let's Encrypt certificate"
        https_ready=true
    else
        action "Run ./deploy/scripts/setup-wizard.sh --resume after DNS is ready"
        https_ready=false
    fi
else
    dns_ready=false
    https_ready=false
fi

if [[ "${containers_ready}" == "true" && "${dns_ready}" == "true" \
    && "${https_ready}" == "true" && "${runtime_valid}" == "true" ]]; then
    if "${SCRIPT_DIR}/readiness-check.sh" >/dev/null 2>&1; then
        ok "HTTPS, redirect and critical Mattermost security settings"
    else
        fail "Automated readiness check failed"
    fi
fi

printf '[MANUAL] Create or verify the first System Admin and enable MFA.\n'
printf '[MANUAL] Test invitation, verification and password-reset email delivery.\n'
printf '[MANUAL] Complete permissions, CJK search and mobile acceptance tests.\n'

if [[ "${failure}" == "true" ]]; then
    exit 1
fi
if [[ "${action_required}" == "true" ]]; then
    exit 20
fi

printf '[READY] Automated installation checks passed.\n'
