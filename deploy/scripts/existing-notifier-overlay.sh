#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=existing-notifier-common.sh
declare -F existing_notifier_validate_config >/dev/null \
    || source "${SCRIPT_DIR}/existing-notifier-common.sh"

existing_notifier_overlay_action_required() {
    printf '[ACTION REQUIRED] %s\n' "$1" >&2
    return 20
}

if ! declare -F existing_notifier_publish_override >/dev/null; then
    existing_notifier_publish_override() {
        runtime_env_publish_no_clobber "$1" "$2"
    }
fi

if ! declare -F existing_notifier_override_parent_is_safe >/dev/null; then
    existing_notifier_override_parent_is_safe() {
        [[ -d "$1" && ! -L "$1" ]]
    }
fi

if ! declare -F existing_notifier_override_exists >/dev/null; then
    existing_notifier_override_exists() {
        [[ -e "$1" || -L "$1" ]]
    }
fi

if ! declare -F existing_notifier_override_is_exact >/dev/null; then
    existing_notifier_override_is_exact() {
        local destination="$1"
        local expected_hash="$2"
        [[ -f "${destination}" && ! -L "${destination}" \
            && "$(runtime_env_mode "${destination}")" == 600 \
            && "$(sha256_file "${destination}")" == "${expected_hash}" ]]
    }
fi

existing_notifier_render_override() {
    local output_file="$1"
    local service
    local notifier_version

    service="$(existing_notifier_value THN_MATTERMOST_SERVICE)"
    notifier_version="$(env_value NOTIFIER_VERSION "${VERSIONS_FILE}")"
    [[ "${service}" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || return 1
    [[ "${notifier_version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1

    {
        printf '%s\n' 'services:' "  ${service}:"
        cat <<'YAML'
    environment:
      MM_PLUGINSETTINGS_ENABLE: "true"
      THREADHUB_DOMAIN: "${THN_DOMAIN:?set THN_DOMAIN}"
      NOTIFIER_MAILER_URL: http://threadhub-mailer:8080
      NOTIFIER_HMAC_SECRET: "${THN_HMAC_SECRET:?set THN_HMAC_SECRET}"
      NOTIFIER_CONTROL_FILE: /run/threadhub-notifier/state.json
      NOTIFIER_POLL_EVERY: 1s
    volumes:
      - type: bind
        source: "${THN_DATA_ROOT:?set THN_DATA_ROOT}/control"
        target: /run/threadhub-notifier
        read_only: true
    group_add:
      - "3000"
    networks:
      - threadhub-notifier-internal

  threadhub-mailer:
YAML
        printf '    image: "threadhub/notifier-mailer:%s"\n' "${notifier_version}"
        cat <<'YAML'
    pull_policy: never
    platform: linux/amd64
    user: "65532:65532"
    group_add:
      - "3000"
    read_only: true
    cap_drop:
      - ALL
    security_opt:
      - no-new-privileges:true
    restart: unless-stopped
    mem_limit: 512m
    tmpfs:
      - /tmp:rw,noexec,nosuid,nodev,size=32m
    environment:
      NOTIFIER_LISTEN_ADDRESS: ":8080"
      THREADHUB_DOMAIN: "${THN_DOMAIN:?set THN_DOMAIN}"
      NOTIFIER_HMAC_SECRET: "${THN_HMAC_SECRET:?set THN_HMAC_SECRET}"
      NOTIFIER_CONTROL_FILE: /run/threadhub-notifier/state.json
      NOTIFIER_QUEUE_PATH: /var/lib/threadhub-notifier/queue.db
      NOTIFIER_RATE_PER_MINUTE: "${THN_RATE_PER_MINUTE:?set THN_RATE_PER_MINUTE}"
      SMTP_SERVER: "${THN_SMTP_SERVER:?set THN_SMTP_SERVER}"
      SMTP_PORT: "${THN_SMTP_PORT:?set THN_SMTP_PORT}"
      SMTP_USERNAME: "${THN_SMTP_USERNAME:?set THN_SMTP_USERNAME}"
      SMTP_PASSWORD: "${THN_SMTP_PASSWORD:?set THN_SMTP_PASSWORD}"
      SMTP_FROM_ADDRESS: "${THN_SMTP_FROM_ADDRESS:?set THN_SMTP_FROM_ADDRESS}"
      SMTP_REPLY_TO_ADDRESS: "${THN_SMTP_REPLY_TO_ADDRESS:?set THN_SMTP_REPLY_TO_ADDRESS}"
      SMTP_FEEDBACK_NAME: "${THN_SMTP_FEEDBACK_NAME:?set THN_SMTP_FEEDBACK_NAME}"
      SSL_CERT_FILE: /run/threadhub-smtp-ca/ca.crt
    volumes:
      - type: bind
        source: "${THN_DATA_ROOT:?set THN_DATA_ROOT}/mailer"
        target: /var/lib/threadhub-notifier
        read_only: false
      - type: bind
        source: "${THN_DATA_ROOT:?set THN_DATA_ROOT}/control"
        target: /run/threadhub-notifier
        read_only: true
      - type: bind
        source: "${THN_SMTP_CA_FILE:?set THN_SMTP_CA_FILE}"
        target: /run/threadhub-smtp-ca/ca.crt
        read_only: true
    networks:
      - threadhub-notifier-internal
      - threadhub-notifier-outbound
    healthcheck:
      test: [CMD, /threadhub-mailer, healthcheck]
      interval: 10s
      timeout: 5s
      retries: 10
      start_period: 30s
    logging:
      driver: json-file
      options:
        max-size: 10m
        max-file: "3"

networks:
  threadhub-notifier-internal:
    internal: true
  threadhub-notifier-outbound: {}
YAML
    } > "${output_file}"
    chmod 0600 "${output_file}"
}

existing_notifier_verify_combined_model() {
    local model_file="$1"
    local service
    local notifier_root
    local notifier_version
    local domain
    local hmac
    local smtp_ca_file

    service="$(existing_notifier_value THN_MATTERMOST_SERVICE)"
    notifier_root="$(existing_notifier_value THN_DATA_ROOT)"
    notifier_version="$(env_value NOTIFIER_VERSION "${VERSIONS_FILE}")"
    domain="$(existing_notifier_value THN_DOMAIN)"
    hmac="$(existing_notifier_value THN_HMAC_SECRET)"
    smtp_ca_file="$(existing_notifier_value THN_SMTP_CA_FILE)"

    jq -e \
        --arg service "${service}" \
        --arg notifier_root "${notifier_root}" \
        --arg mailer_image "threadhub/notifier-mailer:${notifier_version}" \
        --arg domain "${domain}" \
        --arg hmac "${hmac}" \
        --arg smtp_ca_file "${smtp_ca_file}" '
        .services[$service] as $mm |
        .services["threadhub-mailer"] as $mailer |
        ($mm.environment.THREADHUB_DOMAIN == $domain) and
        ($mm.environment.MM_PLUGINSETTINGS_ENABLE == "true") and
        ($mm.environment.NOTIFIER_MAILER_URL == "http://threadhub-mailer:8080") and
        ($mm.environment.NOTIFIER_HMAC_SECRET == $hmac) and
        ($mm.environment.NOTIFIER_CONTROL_FILE == "/run/threadhub-notifier/state.json") and
        ($mm.environment.NOTIFIER_POLL_EVERY == "1s") and
        ([$mm.volumes[] | select(.type == "bind" and .source == ($notifier_root + "/control") and .target == "/run/threadhub-notifier" and .read_only == true)] | length == 1) and
        (($mm.group_add | index("3000")) != null) and
        (($mm.networks | keys | index("threadhub-notifier-internal")) != null) and
        ($mailer.image == $mailer_image) and
        ($mailer.pull_policy == "never") and
        ($mailer.platform == "linux/amd64") and
        ($mailer.user == "65532:65532") and
        ($mailer.group_add == ["3000"]) and
        ($mailer.read_only == true) and
        ($mailer.cap_drop == ["ALL"]) and
        ($mailer.security_opt == ["no-new-privileges:true"]) and
        ($mailer.environment.SSL_CERT_FILE == "/run/threadhub-smtp-ca/ca.crt") and
        (($mailer.ports // []) | length == 0) and
        ([$mailer.volumes[] | select(.type == "bind" and .source == ($notifier_root + "/mailer") and .target == "/var/lib/threadhub-notifier" and ((.read_only // false) == false))] | length == 1) and
        ([$mailer.volumes[] | select(.type == "bind" and .source == ($notifier_root + "/control") and .target == "/run/threadhub-notifier" and .read_only == true)] | length == 1) and
        ([$mailer.volumes[] | select(.type == "bind" and .source == $smtp_ca_file and .target == "/run/threadhub-smtp-ca/ca.crt" and .read_only == true)] | length == 1) and
        (($mailer.networks | keys | sort) == ["threadhub-notifier-internal", "threadhub-notifier-outbound"]) and
        (.networks["threadhub-notifier-internal"].internal == true) and
        ((.networks["threadhub-notifier-outbound"].internal // false) == false)
    ' "${model_file}" >/dev/null 2>&1
}

existing_notifier_write_override() (
    local destination="$1"
    local destination_dir
    local temporary_dir
    local candidate
    local model_file
    local diagnostics
    local candidate_hash
    local candidate_compose=()

    existing_notifier_validate_config || return $?
    existing_notifier_validate_clean_absolute_path destination "${destination}"
    if [[ "${destination}" != "$(existing_notifier_value THN_DATA_ROOT)/compose.override.yml" ]]; then
        existing_notifier_overlay_action_required "Override destination is not the configured notifier path"
        return $?
    fi
    destination_dir="$(dirname "${destination}")"
    if ! existing_notifier_override_parent_is_safe "${destination_dir}"; then
        existing_notifier_overlay_action_required "Notifier runtime directory is missing or unsafe"
        return $?
    fi

    temporary_dir="$(mktemp -d)"
    trap 'rm -rf -- "${temporary_dir}"' EXIT
    chmod 0700 "${temporary_dir}"
    candidate="${temporary_dir}/compose.override.yml"
    model_file="${temporary_dir}/combined.json"
    diagnostics="${temporary_dir}/compose.diagnostics"
    umask 077
    if ! existing_notifier_render_override "${candidate}"; then
        existing_notifier_overlay_action_required "Notifier override could not be rendered"
        return $?
    fi

    init_docker
    existing_notifier_init_compose
    candidate_compose=(
        "${EXISTING_NOTIFIER_BASE_COMPOSE[@]}"
        --env-file "${EXISTING_NOTIFIER_ENV_FILE}"
        -f "${candidate}"
    )
    if ! "${candidate_compose[@]}" config --quiet > "${diagnostics}" 2>&1; then
        existing_notifier_overlay_action_required "Notifier override does not compose with the existing model"
        return $?
    fi
    if ! "${candidate_compose[@]}" config --format json > "${model_file}" 2> "${diagnostics}"; then
        existing_notifier_overlay_action_required "Combined Compose model could not be inspected"
        return $?
    fi
    chmod 0600 "${model_file}" "${diagnostics}"
    if ! existing_notifier_verify_combined_model "${model_file}"; then
        existing_notifier_overlay_action_required "Combined Compose model violates notifier isolation"
        return $?
    fi

    candidate_hash="$(sha256_file "${candidate}")"
    if existing_notifier_override_exists "${destination}"; then
        if existing_notifier_override_is_exact "${destination}" "${candidate_hash}"; then
            log "Reusing the exact existing notifier override"
            return 0
        fi
        existing_notifier_overlay_action_required "Existing notifier override differs and was not overwritten"
        return $?
    fi

    if ! existing_notifier_publish_override "${candidate}" "${destination}"; then
        existing_notifier_overlay_action_required "Notifier override publication lost a no-clobber race"
        return $?
    fi
    existing_notifier_override_is_exact "${destination}" "${candidate_hash}" \
        || die "Published notifier override identity is invalid"
    log "Published the protected existing Mattermost notifier override"
)

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    [[ "$#" -eq 1 ]] || die "Usage: $0 ABSOLUTE_OVERRIDE_PATH"
    existing_notifier_write_override "$1"
fi
