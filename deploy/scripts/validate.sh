#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

require_file "${COMPOSE_FILE}"
require_file "${ENV_EXAMPLE_FILE}"
require_file "${VERSIONS_FILE}"
ssh_hardening_file="${DEPLOY_DIR}/ssh/99-threadhub-hardening.conf"
require_file "${ssh_hardening_file}"

for script in "${SCRIPT_DIR}"/*.sh; do
    bash -n "${script}"
done
log "Bash syntax is valid"

for variable in \
    MATTERMOST_IMAGE_REPOSITORY \
    MATTERMOST_IMAGE_TAG \
    MATTERMOST_IMAGE_DIGEST \
    POSTGRES_IMAGE_REPOSITORY \
    POSTGRES_IMAGE_TAG \
    POSTGRES_IMAGE_DIGEST \
    DOCKER_CE_VERSION \
    DOCKER_CLI_VERSION \
    CONTAINERD_VERSION \
    DOCKER_COMPOSE_PLUGIN_VERSION; do
    env_value "${variable}" "${VERSIONS_FILE}" >/dev/null
done

mattermost_digest="$(env_value MATTERMOST_IMAGE_DIGEST "${VERSIONS_FILE}")"
postgres_digest="$(env_value POSTGRES_IMAGE_DIGEST "${VERSIONS_FILE}")"
[[ "${mattermost_digest}" =~ ^sha256:[a-f0-9]{64}$ ]] \
    || die "MATTERMOST_IMAGE_DIGEST is invalid"
[[ "${postgres_digest}" =~ ^sha256:[a-f0-9]{64}$ ]] \
    || die "POSTGRES_IMAGE_DIGEST is invalid"

if grep -R -n -E 'image:[[:space:]]+[^#]*:latest([[:space:]]|$)' "${DEPLOY_DIR}"; then
    die "Floating latest image tag found"
fi

if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    docker compose \
        --env-file "${ENV_EXAMPLE_FILE}" \
        --env-file "${VERSIONS_FILE}" \
        -f "${COMPOSE_FILE}" \
        config --quiet
    log "Docker Compose configuration is valid"
elif command -v ruby >/dev/null 2>&1; then
    ruby -e 'require "yaml"; YAML.load_file(ARGV.fetch(0))' "${COMPOSE_FILE}"
    warn "Docker Compose is unavailable; only generic YAML parsing was performed"
else
    die "Docker Compose or Ruby is required to validate docker-compose.yml"
fi

runtime_env_fixture="$(mktemp)"
cleanup() {
    rm -f "${runtime_env_fixture}"
}
trap cleanup EXIT

sed \
    -e 's#^THREADHUB_DOMAIN=.*#THREADHUB_DOMAIN=threadhub.internal#' \
    -e 's#^LETSENCRYPT_EMAIL=.*#LETSENCRYPT_EMAIL=admin@threadhub.internal#' \
    -e 's#^POSTGRES_PASSWORD=.*#POSTGRES_PASSWORD=0000000000000000000000000000000000000000000000000000000000000000#' \
    -e 's#^SMTP_SERVER=.*#SMTP_SERVER=smtp.email.ap-singapore-1.oci.oraclecloud.com#' \
    -e 's#^SMTP_USERNAME=.*#SMTP_USERNAME=fixture_user#' \
    -e 's#^SMTP_PASSWORD=.*#SMTP_PASSWORD=fixture_password#' \
    -e 's#^SMTP_FROM_ADDRESS=.*#SMTP_FROM_ADDRESS=no-reply@threadhub.internal#' \
    -e 's#^SMTP_REPLY_TO_ADDRESS=.*#SMTP_REPLY_TO_ADDRESS=admin@threadhub.internal#' \
    "${ENV_EXAMPLE_FILE}" > "${runtime_env_fixture}"

original_env_file="${ENV_FILE}"
ENV_FILE="${runtime_env_fixture}"
validate_runtime_env
ENV_FILE="${original_env_file}"
log "Runtime environment validation accepts a complete non-placeholder configuration"

# Match the literal deployment-script expression; expansion is not intended.
# shellcheck disable=SC2016
grep -F 'install -d -m 0755 "${data_root}/postgres"' \
    "${SCRIPT_DIR}/deploy.sh" >/dev/null \
    || die "PostgreSQL bind-mount root permission regression detected"
log "PostgreSQL bind-mount root remains traversable after the entrypoint drops privileges"

grep -F 'ensure_tcp_input_rule 80' "${SCRIPT_DIR}/configure-nginx.sh" >/dev/null \
    || die "Host HTTP firewall rule regression detected"
grep -F 'ensure_tcp_input_rule 443' "${SCRIPT_DIR}/configure-nginx.sh" >/dev/null \
    || die "Host HTTPS firewall rule regression detected"
grep -F 'netfilter-persistent save' "${SCRIPT_DIR}/configure-nginx.sh" >/dev/null \
    || die "Persistent host firewall save regression detected"
log "Host HTTP and HTTPS firewall rules remain persistent"

for directive in \
    'PasswordAuthentication no' \
    'PubkeyAuthentication yes' \
    'PermitRootLogin no'; do
    grep -Fx "${directive}" "${ssh_hardening_file}" >/dev/null \
        || die "SSH hardening directive is missing: ${directive}"
done
log "SSH password and root login hardening directives are present"

grep -F 'MM_TEAMSETTINGS_EXPERIMENTALDEFAULTCHANNELS: "01-project-general 02-progress-issues 03-decisions"' \
    "${COMPOSE_FILE}" >/dev/null \
    || die "Default project channel membership configuration is missing"
require_file "${SCRIPT_DIR}/reconcile-team-channels.sh"
require_file "${SCRIPT_DIR}/reload-nginx.sh"
log "Default project channels and membership reconciliation are configured"

for script in \
    "${SCRIPT_DIR}/configure-nginx.sh" \
    "${SCRIPT_DIR}/reload-nginx.sh"; do
    grep -F 'secure_nginx_logs' "${script}" >/dev/null \
        || die "NGINX setup must protect access and error log permissions: ${script}"
done
grep -F 'chmod 0640 "${log_file}"' "${SCRIPT_DIR}/common.sh" >/dev/null \
    || die "ThreadHub NGINX logs must not be world-readable"
grep -F 'test ! -L "${log_file}"' "${SCRIPT_DIR}/common.sh" >/dev/null \
    || die "NGINX log permission management must reject symbolic links"
log "NGINX log files are protected from world-readable and symbolic-link regressions"

for template in \
    "${DEPLOY_DIR}/nginx/threadhub-bootstrap.conf.template" \
    "${DEPLOY_DIR}/nginx/threadhub.conf.template"; do
    require_file "${template}"
    [[ "$(grep -c '__THREADHUB_DOMAIN__' "${template}")" -gt 0 ]] \
        || die "NGINX template is missing the domain placeholder: ${template}"
    grep -F 'access_log /var/log/nginx/threadhub.access.log threadhub_safe;' \
        "${template}" >/dev/null \
        || die "NGINX template must use the query-free ThreadHub access log format: ${template}"
done

grep -F "\"\$request_method \$uri \$server_protocol\"" \
    "${DEPLOY_DIR}/nginx/threadhub.conf.template" >/dev/null \
    || die "NGINX safe access log format is missing"
for unsafe_host in "\$http_host" "\$host"; do
    if grep -R -n -F "proxy_set_header Host ${unsafe_host}" "${DEPLOY_DIR}/nginx"; then
        die "NGINX must not forward an untrusted request Host header"
    fi
done

grep -F 'config --quiet' "${DEPLOY_DIR}/README.md" >/dev/null \
    || die "Compose documentation must not print interpolated runtime secrets"
grep -F 'chmod 600 deploy/.env' "${DEPLOY_DIR}/README.md" >/dev/null \
    || die "Quick-start documentation must protect deploy/.env before editing"
grep -F "chmod 0600 \"\${ENV_FILE}\"" "${SCRIPT_DIR}/deploy.sh" >/dev/null \
    || die "Deployment must protect the runtime environment before reading secrets"
grep -F "Usage: \$0 TEAM_URL_NAME [CHANNEL_URL_NAME ...]" \
    "${SCRIPT_DIR}/reconcile-team-channels.sh" >/dev/null \
    || die "Channel reconciliation must require an explicit Team target"

if command -v git >/dev/null 2>&1 && git -C "${REPOSITORY_ROOT}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    secret_pattern='AKIA[0-9A-Z]{16}|ASIA[0-9A-Z]{16}|gh[opusr]_[A-Za-z0-9_]{20,}|github_pat_[A-Za-z0-9_]{20,}|xox[baprs]-[A-Za-z0-9-]{10,}|sk-[A-Za-z0-9]{20,}|ocid1\.|BEGIN ([A-Z]+ )*PRIVATE KEY'
    secret_files="$(git -C "${REPOSITORY_ROOT}" grep -Il -E "${secret_pattern}" -- . || true)"
    if [[ -n "${secret_files}" ]]; then
        printf '%s\n' "${secret_files}" >&2
        die "Potential credential material found in tracked files"
    fi

    credential_files="$(git -C "${REPOSITORY_ROOT}" grep -Il -E \
        '^[[:space:]]*(POSTGRES_PASSWORD|SMTP_PASSWORD|SMTP_USERNAME|AWS_SECRET_ACCESS_KEY|GITHUB_TOKEN)=' \
        -- . ':!deploy/.env.example' || true)"
    if [[ -n "${credential_files}" ]]; then
        printf '%s\n' "${credential_files}" >&2
        die "A runtime credential assignment was found outside deploy/.env.example"
    fi

    sensitive_names="$(git -C "${REPOSITORY_ROOT}" ls-files \
        | grep -E '(^|/)(\.env($|\.)|id_(rsa|ed25519)$|.*\.(key|pem|p12|pfx|ppk|jks|keystore|tfstate|tfplan)$)' \
        | grep -v -E '(^|/)\.env\.example$' || true)"
    if [[ -n "${sensitive_names}" ]]; then
        printf '%s\n' "${sensitive_names}" >&2
        die "Sensitive filename is tracked"
    fi

    history_secret_files="$(
        git -C "${REPOSITORY_ROOT}" rev-list --all \
            | while IFS= read -r revision; do
                git -C "${REPOSITORY_ROOT}" grep -Il -E \
                    "${secret_pattern}" "${revision}" -- . || true
            done \
            | sort -u
    )"
    if [[ -n "${history_secret_files}" ]]; then
        printf '%s\n' "${history_secret_files}" >&2
        die "Potential credential material found in reachable Git history"
    fi
fi

log "ThreadHub deployment package static validation passed"
