#!/usr/bin/env bash

# Real-image proof: Mattermost Team Edition 11.7.7 and PostgreSQL 18.4.
# The only successful public result is BK-INTEGRATION-pass.
# Run only on a disposable Ubuntu 24.04 AMD64 runner with no ThreadHub state.

set -Eeuo pipefail
umask 077

INTEGRATION_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(cd "${INTEGRATION_DIR}/../.." && pwd)"
REPOSITORY_ROOT="$(cd "${DEPLOY_DIR}/.." && pwd)"
ENV_FILE="${DEPLOY_DIR}/.env"
VERSIONS_FILE="${DEPLOY_DIR}/versions.env"
COMPOSE_FILE="${DEPLOY_DIR}/docker-compose.yml"
OCI_STUB="${INTEGRATION_DIR}/oci-stub.sh"
MATTERMOST_SEED="${INTEGRATION_DIR}/seed-mattermost.sh"
QUEUE_SEED_PACKAGE=./mailer/integration/backup-seed
TARGET_ROOT=/srv/threadhub
SOURCE_ROOT=/srv/threadhub-backup-integration-source
BACKUP_STATE_ROOT=/var/lib/threadhub-backup
BACKUP_CONFIG_ROOT=/etc/threadhub
BACKUP_CONFIG=/etc/threadhub/backup.env
COMPOSE_PROJECT_NAME=threadhub-backup-integration
INTEGRATION_PORT=8065
INTEGRATION_SENTINEL=.threadhub-backup-integration-sentinel
WORK_ROOT=''
PRIVATE_ROOT=''
EVIDENCE_ROOT=''
OBJECT_ROOT=''
FIXTURE_ROOT=''
PRIVATE_LOG=''
PUBLIC_OUTPUT=''
OCI_AUDIT=''
SENTINEL_VALUE=''
CURRENT_FAILURE=preflight
INTEGRATION_SUCCESS=false
ENV_CREATED=false

exec 3>&1

emit_result() {
    local result="$1"

    [[ "${result}" =~ ^(pass|preflight|deploy|deploy-layout|deploy-image|deploy-start|deploy-postgres|deploy-mattermost|deploy-mailer|deploy-plugin|deploy-health|seed|backup|remote-verify|source-root-unchanged|restore|notifier-old-mail-not-sent|service-downtime-at-most-300|restore-rto-at-most-14400|privacy|cleanup)$ ]] \
        || result=preflight
    printf 'BK-INTEGRATION-%s\n' "${result}" >&3
}

require_root() {
    [[ "$(id -u)" -eq 0 ]]
}

require_ubuntu_amd64() {
    [[ -r /etc/os-release ]]
    # shellcheck disable=SC1091
    source /etc/os-release
    [[ "${ID:-}" == ubuntu && "${VERSION_ID:-}" == 24.04 \
        && "$(dpkg --print-architecture)" == amd64 ]]
}

require_command() {
    command -v "$1" >/dev/null 2>&1
}

sha256_file() {
    sha256sum "$1" | awk '{print $1}'
}

env_value() {
    local key="$1" file="$2"

    LC_ALL=C awk -v key="${key}" '
        index($0, key "=") == 1 { count++; value=substr($0,length(key)+2) }
        END { if (count != 1 || value == "") exit 1; print value }
    ' "${file}"
}

integration_compose() {
    docker compose \
        --project-name "${COMPOSE_PROJECT_NAME}" \
        --env-file "${ENV_FILE}" \
        --env-file "${VERSIONS_FILE}" \
        -f "${COMPOSE_FILE}" "$@"
}

backup_assert_empty_target() {
    local target="$1"

    [[ "${target}" == /srv/threadhub && ! -L "${target}" ]]
    [[ ! -e "${target}" ]]
}

guarded_remove_root() {
    local target="$1"

    [[ "${target}" == "${TARGET_ROOT}" || "${target}" == "${SOURCE_ROOT}" \
        || "${target}" == "${BACKUP_STATE_ROOT}" || "${target}" == "${BACKUP_CONFIG_ROOT}" ]] \
        || return 1
    [[ -d "${target}" && ! -L "${target}" \
        && -f "${target}/${INTEGRATION_SENTINEL}" \
        && ! -L "${target}/${INTEGRATION_SENTINEL}" \
        && "$(<"${target}/${INTEGRATION_SENTINEL}")" == "${SENTINEL_VALUE}" ]] || return 1
    rm -rf --one-file-system -- "${target}"
}

mark_root() {
    local target="$1"

    [[ -d "${target}" && ! -L "${target}" \
        && ! -e "${target}/${INTEGRATION_SENTINEL}" \
        && ! -L "${target}/${INTEGRATION_SENTINEL}" ]] || return 1
    printf '%s\n' "${SENTINEL_VALUE}" > "${target}/${INTEGRATION_SENTINEL}"
    chmod 0600 "${target}/${INTEGRATION_SENTINEL}"
}

cleanup() {
    local cleanup_ok=true

    if [[ "${ENV_CREATED}" == true && -f "${ENV_FILE}" && ! -L "${ENV_FILE}" ]]; then
        integration_compose down --remove-orphans >/dev/null 2>&1 || cleanup_ok=false
    fi
    if [[ -e "${TARGET_ROOT}" || -L "${TARGET_ROOT}" ]]; then
        guarded_remove_root "${TARGET_ROOT}" || cleanup_ok=false
    fi
    if [[ -e "${SOURCE_ROOT}" || -L "${SOURCE_ROOT}" ]]; then
        guarded_remove_root "${SOURCE_ROOT}" || cleanup_ok=false
    fi
    if [[ -e "${BACKUP_STATE_ROOT}" || -L "${BACKUP_STATE_ROOT}" ]]; then
        guarded_remove_root "${BACKUP_STATE_ROOT}" || cleanup_ok=false
    fi
    if [[ -e "${BACKUP_CONFIG_ROOT}" || -L "${BACKUP_CONFIG_ROOT}" ]]; then
        guarded_remove_root "${BACKUP_CONFIG_ROOT}" || cleanup_ok=false
    fi
    if [[ "${ENV_CREATED}" == true ]]; then
        if [[ -f "${ENV_FILE}" && ! -L "${ENV_FILE}" \
            && "$(sha256_file "${ENV_FILE}")" == "$(<"${PRIVATE_ROOT}/active-env.sha256")" ]]; then
            rm -f -- "${ENV_FILE}" || cleanup_ok=false
        elif [[ -e "${ENV_FILE}" || -L "${ENV_FILE}" ]]; then
            cleanup_ok=false
        fi
    fi
    [[ "${cleanup_ok}" == true ]]
}

classify_deploy_failure() {
    local postgres_id mattermost_id mailer_id service_state service_health

    if grep -Fq '[threadhub] Notifier plugin ' "${PRIVATE_LOG}"; then
        printf '%s\n' deploy-health
    elif grep -Fq '[threadhub] Starting ThreadHub' "${PRIVATE_LOG}"; then
        postgres_id="$(integration_compose ps -q postgres 2>/dev/null || true)"
        if [[ -z "${postgres_id}" ]]; then
            printf '%s\n' deploy-postgres
            return
        fi
        service_health="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' \
            "${postgres_id}" 2>/dev/null || true)"
        if [[ "${service_health}" != healthy ]]; then
            printf '%s\n' deploy-postgres
            return
        fi

        mattermost_id="$(integration_compose ps -q mattermost 2>/dev/null || true)"
        if [[ -z "${mattermost_id}" ]]; then
            printf '%s\n' deploy-mattermost
            return
        fi
        service_state="$(docker inspect --format '{{.State.Status}}' \
            "${mattermost_id}" 2>/dev/null || true)"
        if [[ "${service_state}" != running ]]; then
            printf '%s\n' deploy-mattermost
            return
        fi

        mailer_id="$(integration_compose ps -q threadhub-mailer 2>/dev/null || true)"
        if [[ -z "${mailer_id}" ]]; then
            printf '%s\n' deploy-mailer
            return
        fi
        service_health="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' \
            "${mailer_id}" 2>/dev/null || true)"
        if [[ "${service_health}" != healthy ]]; then
            printf '%s\n' deploy-mailer
            return
        fi
        printf '%s\n' deploy-plugin
    elif grep -Fq '[threadhub] Pulling immutable external linux/amd64 image manifests' \
        "${PRIVATE_LOG}"; then
        printf '%s\n' deploy-image
    elif grep -Fq '[threadhub] Creating explicit PostgreSQL, Mattermost and notifier bind-mount paths' \
        "${PRIVATE_LOG}"; then
        printf '%s\n' deploy-layout
    else
        printf '%s\n' deploy
    fi
}

collect_privacy_evidence() {
    local path destination index=0

    install -d -m 0700 "${EVIDENCE_ROOT}"
    for path in \
        "${BACKUP_STATE_ROOT}/status/latest.json" \
        "${BACKUP_STATE_ROOT}/status/latest-success.json" \
        "${OCI_AUDIT}" \
        "${PUBLIC_OUTPUT}"; do
        if [[ -f "${path}" && ! -L "${path}" ]]; then
            destination="${EVIDENCE_ROOT}/evidence-${index}"
            cp -- "${path}" "${destination}"
            chmod 0600 "${destination}"
            index=$((index + 1))
        fi
    done
    if [[ -d "${BACKUP_STATE_ROOT}" && ! -L "${BACKUP_STATE_ROOT}" ]]; then
        while IFS= read -r -d '' path; do
            destination="${EVIDENCE_ROOT}/evidence-${index}"
            cp -- "${path}" "${destination}"
            chmod 0600 "${destination}"
            index=$((index + 1))
        done < <(find -P "${BACKUP_STATE_ROOT}" -type f \
            \( -name '*.diagnostic' -o -name manifest.json -o -name manifest.sha256 \) -print0)
    fi
}

privacy_scan() {
    local privacy_patterns="${PRIVATE_ROOT}/privacy-patterns" pattern

    collect_privacy_evidence || return 1
    require_private_file "${privacy_patterns}" || return 1
    while IFS= read -r pattern; do
        [[ -n "${pattern}" ]] || return 1
        if grep -R -F -q -- "${pattern}" "${EVIDENCE_ROOT}"; then
            return 1
        fi
    done < "${privacy_patterns}"
}

finish() {
    local status=$? result

    trap - EXIT HUP INT TERM
    if [[ "${INTEGRATION_SUCCESS}" == true && "${status}" == 0 ]]; then
        result=pass
    else
        result="${CURRENT_FAILURE}"
    fi
    if [[ -n "${PUBLIC_OUTPUT}" ]]; then
        printf 'BK-INTEGRATION-%s\n' "${result}" > "${PUBLIC_OUTPUT}"
        chmod 0600 "${PUBLIC_OUTPUT}"
    fi
    if [[ -n "${PRIVATE_ROOT}" && -d "${PRIVATE_ROOT}" ]] && ! privacy_scan; then
        result=privacy
    fi
    if ! cleanup && [[ "${result}" == pass ]]; then
        result=cleanup
    fi
    emit_result "${result}"
    if [[ -n "${WORK_ROOT}" && -d "${WORK_ROOT}" && ! -L "${WORK_ROOT}" \
        && "${WORK_ROOT}" == /var/tmp/threadhub-backup-integration.* ]]; then
        rm -rf --one-file-system -- "${WORK_ROOT}"
    fi
    [[ "${result}" == pass ]]
}

require_private_file() {
    [[ -f "$1" && ! -L "$1" && "$(stat -c '%a' "$1")" == 600 ]]
}

write_runtime_env() {
    local database_password="$1" hmac_secret="$2" temporary

    [[ "${database_password}" =~ ^[a-f0-9]{64}$ \
        && "${hmac_secret}" =~ ^[a-f0-9]{64}$ ]] || return 1
    temporary="$(mktemp "${DEPLOY_DIR}/.env.integration.XXXXXX")"
    export INTEGRATION_DATABASE_PASSWORD="${database_password}"
    export INTEGRATION_HMAC_SECRET="${hmac_secret}"
    LC_ALL=C awk '
        BEGIN {
          replacement["COMPOSE_PROJECT_NAME"]="threadhub-backup-integration"
          replacement["THREADHUB_DOMAIN"]="threadhub.integration.test"
          replacement["LETSENCRYPT_EMAIL"]="admin@integration.invalid"
          replacement["POSTGRES_PASSWORD"]=ENVIRON["INTEGRATION_DATABASE_PASSWORD"]
          replacement["SMTP_SERVER"]="127.0.0.1"
          replacement["SMTP_USERNAME"]="integration-smtp-user"
          replacement["SMTP_PASSWORD"]="integration-smtp-password"
          replacement["SMTP_FROM_ADDRESS"]="no-reply@integration.invalid"
          replacement["SMTP_REPLY_TO_ADDRESS"]="reply@integration.invalid"
          replacement["NOTIFIER_ENABLED"]="false"
          replacement["NOTIFIER_HMAC_SECRET"]=ENVIRON["INTEGRATION_HMAC_SECRET"]
        }
        {
          key=$0
          sub(/=.*/, "", key)
          if (key in replacement) print key "=" replacement[key]
          else print
        }
    ' "${DEPLOY_DIR}/.env.example" > "${temporary}"
    unset INTEGRATION_DATABASE_PASSWORD INTEGRATION_HMAC_SECRET
    chmod 0600 "${temporary}"
    [[ ! -e "${ENV_FILE}" && ! -L "${ENV_FILE}" ]] || return 1
    ln -T -- "${temporary}" "${ENV_FILE}" || return 1
    rm -f -- "${temporary}"
    ENV_CREATED=true
    sha256_file "${ENV_FILE}" > "${PRIVATE_ROOT}/active-env.sha256"
    chmod 0600 "${PRIVATE_ROOT}/active-env.sha256"
}

replace_runtime_env() {
    local database_password="$1" hmac_secret="$2" old_hash temporary

    old_hash="$(sha256_file "${ENV_FILE}")"
    [[ "${old_hash}" == "$(<"${PRIVATE_ROOT}/active-env.sha256")" ]] || return 1
    temporary="$(mktemp "${DEPLOY_DIR}/.env.integration.XXXXXX")"
    export INTEGRATION_DATABASE_PASSWORD="${database_password}"
    export INTEGRATION_HMAC_SECRET="${hmac_secret}"
    LC_ALL=C awk '
        /^POSTGRES_PASSWORD=/ { print "POSTGRES_PASSWORD=" ENVIRON["INTEGRATION_DATABASE_PASSWORD"]; next }
        /^NOTIFIER_HMAC_SECRET=/ { print "NOTIFIER_HMAC_SECRET=" ENVIRON["INTEGRATION_HMAC_SECRET"]; next }
        { print }
    ' "${ENV_FILE}" > "${temporary}"
    unset INTEGRATION_DATABASE_PASSWORD INTEGRATION_HMAC_SECRET
    chmod 0600 "${temporary}"
    mv -T -- "${temporary}" "${ENV_FILE}"
    sha256_file "${ENV_FILE}" > "${PRIVATE_ROOT}/active-env.sha256"
    chmod 0600 "${PRIVATE_ROOT}/active-env.sha256"
}

write_backup_config() {
    install -d -m 0750 "${BACKUP_CONFIG_ROOT}"
    {
        printf '%s\n' \
            'BACKUP_REGION=ap-singapore-1' \
            'BACKUP_NAMESPACE=integrationnamespace' \
            'BACKUP_BUCKET=integration-project-backups' \
            'BACKUP_ALERT_EMAIL=backup-alert@integration.invalid' \
            'BACKUP_SCHEDULE=03:00' \
            'BACKUP_DAILY_RETENTION_DAYS=7' \
            'BACKUP_WEEKLY_RETENTION_DAYS=28'
    } > "${BACKUP_CONFIG}"
    chmod 0600 "${BACKUP_CONFIG}"
    mark_root "${BACKUP_CONFIG_ROOT}"
}

initialize_fixture() {
    local database_password hmac_secret restore_database_password restore_hmac_secret

    require_root && require_ubuntu_amd64 || return 1
    for command_name in docker jq curl git go openssl sha256sum tar zstd find flock; do
        require_command "${command_name}" || return 1
    done
    docker info >/dev/null 2>&1 || return 1
    docker compose version >/dev/null 2>&1 || return 1
    backup_assert_empty_target /srv/threadhub || return 1
    [[ -x "${OCI_STUB}" && -x "${MATTERMOST_SEED}" \
        && -f "${REPOSITORY_ROOT}/notifier/mailer/integration/backup-seed/main.go" \
        && -f "${DEPLOY_DIR}/.env.example" \
        && ! -e "${ENV_FILE}" && ! -L "${ENV_FILE}" \
        && ! -e "${SOURCE_ROOT}" && ! -L "${SOURCE_ROOT}" \
        && ! -e "${BACKUP_STATE_ROOT}" && ! -L "${BACKUP_STATE_ROOT}" \
        && ! -e "${BACKUP_CONFIG_ROOT}" && ! -L "${BACKUP_CONFIG_ROOT}" \
        && -z "$(git -C "${REPOSITORY_ROOT}" status --porcelain=v1 --untracked-files=all)" ]] || return 1

    WORK_ROOT="$(mktemp -d /var/tmp/threadhub-backup-integration.XXXXXX)"
    chmod 0700 "${WORK_ROOT}"
    PRIVATE_ROOT="${WORK_ROOT}/private"
    EVIDENCE_ROOT="${WORK_ROOT}/evidence"
    OBJECT_ROOT="${PRIVATE_ROOT}/object-storage"
    FIXTURE_ROOT="${PRIVATE_ROOT}/fixture"
    PRIVATE_LOG="${PRIVATE_ROOT}/integration.log"
    PUBLIC_OUTPUT="${PRIVATE_ROOT}/public-output"
    OCI_AUDIT="${PRIVATE_ROOT}/oci-audit"
    install -d -m 0700 "${PRIVATE_ROOT}" "${OBJECT_ROOT}" "${FIXTURE_ROOT}"
    : > "${PRIVATE_LOG}"
    : > "${OCI_AUDIT}"
    chmod 0600 "${PRIVATE_LOG}" "${OCI_AUDIT}"
    exec >"${PRIVATE_LOG}" 2>&1
    SENTINEL_VALUE="$(openssl rand -hex 32)"
    database_password="$(openssl rand -hex 32)"
    hmac_secret="$(openssl rand -hex 32)"
    restore_database_password="$(openssl rand -hex 32)"
    restore_hmac_secret="$(openssl rand -hex 32)"
    {
        printf '%s\n' \
            "${database_password}" "${hmac_secret}" \
            "${restore_database_password}" "${restore_hmac_secret}" \
            'admin@integration.invalid' 'member@integration.invalid' \
            'backup-alert@integration.invalid' 'no-reply@integration.invalid' \
            'reply@integration.invalid' 'threadhub.integration.test' \
            'queue@integration.invalid' 'integration-smtp-user' \
            'integration-smtp-password' \
            'integration public root' 'integration private root' \
            'integration thread reply' 'integration attachment post' \
            'integration attachment body' 'integration-attachment.txt'
        printf '%s%s\n' 'ocid1' '.integration.fixture'
    } > "${PRIVATE_ROOT}/privacy-patterns"
    chmod 0600 "${PRIVATE_ROOT}/privacy-patterns"
    printf '%s\n%s\n' "${restore_database_password}" "${restore_hmac_secret}" \
        > "${PRIVATE_ROOT}/restore-secrets"
    chmod 0600 "${PRIVATE_ROOT}/restore-secrets"
    write_runtime_env "${database_password}" "${hmac_secret}"
    write_backup_config
    install -d -m 0750 "${TARGET_ROOT}"
    mark_root "${TARGET_ROOT}"
    install -d -m 0700 "${BACKUP_STATE_ROOT}"
    mark_root "${BACKUP_STATE_ROOT}"
    export OCI_STUB_NAMESPACE=integrationnamespace
    export OCI_STUB_BUCKET=integration-project-backups
    export OCI_STUB_OBJECT_ROOT="${OBJECT_ROOT}"
    export OCI_STUB_AUDIT_FILE="${OCI_AUDIT}"
    export THREADHUB_INTEGRATION_FIXTURE_ROOT="${FIXTURE_ROOT}"
    export THREADHUB_INTEGRATION_BASE_URL="http://127.0.0.1:${INTEGRATION_PORT}"
}

run_backup() {
    bash -Eeuo pipefail -c '
        source "$1"
        OCI_COMMAND=("$2")
        backup_main
    ' integration "${DEPLOY_DIR}/scripts/backup.sh" "${OCI_STUB}"
}

run_restore() {
    local backup_id="$1"

    bash -Eeuo pipefail -c '
        source "$1"
        OCI_COMMAND=("$2")
        restore_entry "$3"
    ' integration "${DEPLOY_DIR}/scripts/restore.sh" "${OCI_STUB}" "${backup_id}"
}

validate_remote_set() {
    local backup_id="$1" set_dir

    set_dir="${OBJECT_ROOT}/objects/daily/${backup_id:0:4}/${backup_id:4:2}/${backup_id:6:2}/${backup_id}"
    [[ -d "${set_dir}" && ! -L "${set_dir}" ]]
    bash -Eeuo pipefail -c '
        source "$1"
        backup_validate_set "$2" "$3"
    ' integration "${DEPLOY_DIR}/scripts/backup-artifacts.sh" "${set_dir}" "${backup_id}"
    printf '%s\n' "${set_dir}" > "${PRIVATE_ROOT}/remote-set-path"
    chmod 0600 "${PRIVATE_ROOT}/remote-set-path"
}

database_projection_sha() {
    integration_compose exec -T postgres psql --username mmuser --dbname mattermost -At \
        --command "
            select jsonb_build_object(
              'users',(select coalesce(jsonb_agg(jsonb_build_array(id,username,email,roles,deleteat) order by id),'[]'::jsonb) from users where username like 'integration%'),
              'teams',(select coalesce(jsonb_agg(jsonb_build_array(id,name,type,deleteat) order by id),'[]'::jsonb) from teams where name='backup-integration'),
              'channels',(select coalesce(jsonb_agg(jsonb_build_array(id,teamid,name,type,deleteat) order by id),'[]'::jsonb) from channels where name like 'integration-%'),
              'posts',(select coalesce(jsonb_agg(jsonb_build_array(id,channelid,rootid,message,fileids,deleteat) order by id),'[]'::jsonb) from posts where message like 'integration %'),
              'files',(select coalesce(jsonb_agg(jsonb_build_array(id,postid,name,size,deleteat) order by id),'[]'::jsonb) from fileinfo where name='integration-attachment.txt')
            );" \
        | sha256sum | awk '{print $1}'
}

tree_sha() {
    local root="$1"

    [[ -d "${root}" && ! -L "${root}" ]]
    (
        cd "${root}"
        find -P . -type f -print0 | LC_ALL=C sort -z \
            | xargs -0 -r sha256sum
    ) | sha256sum | awk '{print $1}'
}

queue_snapshot_sha() {
    local set_dir="$1" extraction

    extraction="${PRIVATE_ROOT}/queue-snapshot"
    install -d -m 0700 "${extraction}"
    zstd -q -d -c "${set_dir}/notifier-queue.tar.zst" | tar -xf - -C "${extraction}"
    tree_sha "${extraction}"
}

seed_queue() {
    local hmac_secret

    hmac_secret="$(env_value NOTIFIER_HMAC_SECRET "${ENV_FILE}")"
    (
        cd "${REPOSITORY_ROOT}/notifier"
        NOTIFIER_QUEUE_PATH="${TARGET_ROOT}/notifier/mailer/queue.db" \
            NOTIFIER_HMAC_SECRET="${hmac_secret}" go run "${QUEUE_SEED_PACKAGE}"
    )
}

append_seed_privacy_patterns() {
    local credentials="${FIXTURE_ROOT}/mattermost-credentials.env"
    local auth_config="${FIXTURE_ROOT}/mattermost-curl-auth.conf"
    local patterns="${PRIVATE_ROOT}/privacy-patterns" key token

    require_private_file "${credentials}"
    require_private_file "${auth_config}"
    require_private_file "${patterns}"
    for key in ADMIN_PASSWORD MEMBER_PASSWORD; do
        env_value "${key}" "${credentials}" >> "${patterns}"
    done
    token="$(LC_ALL=C sed -n 's/^header = "Authorization: Bearer \([A-Za-z0-9_-]*\)"$/\1/p' \
        "${auth_config}")"
    [[ "${token}" =~ ^[A-Za-z0-9_-]{20,256}$ ]]
    printf '%s\n' "${token}" >> "${patterns}"
    chmod 0600 "${patterns}"
}

verify_restored_mailer_is_empty() {
    local status="${PRIVATE_ROOT}/restored-mailer-status.json"

    integration_compose exec -T threadhub-mailer /threadhub-mailer status --json > "${status}"
    chmod 0600 "${status}"
    jq -e '.pending == 0 and .sending == 0 and .sent == 0 and .failed == 0' \
        "${status}" >/dev/null
    [[ ! -e "${PRIVATE_ROOT}/smtp-capture" ]]
}

main() {
    local backup_id status_file set_dir source_projection restored_projection
    local queue_before queue_after source_before source_after
    local restore_started restore_completed
    local restore_database_password restore_hmac_secret

    trap finish EXIT HUP INT TERM
    CURRENT_FAILURE=preflight
    initialize_fixture

    CURRENT_FAILURE=deploy
    if ! "${DEPLOY_DIR}/scripts/deploy.sh"; then
        CURRENT_FAILURE="$(classify_deploy_failure)"
        return 1
    fi

    CURRENT_FAILURE=seed
    "${MATTERMOST_SEED}" --seed
    append_seed_privacy_patterns
    integration_compose stop --timeout 60 threadhub-mailer
    seed_queue
    integration_compose up -d --no-deps --wait --wait-timeout 120 threadhub-mailer
    source_projection="$(database_projection_sha)"

    CURRENT_FAILURE=backup
    run_backup
    status_file="${BACKUP_STATE_ROOT}/status/latest-success.json"
    require_private_file "${status_file}"
    backup_id="$(jq -er '.backup_id | select(type == "string")' "${status_file}")"
    jq -e '.status == "success" and .phase == "complete" and .verification_result == "ok"' \
        "${status_file}" >/dev/null
    if ! jq -e '.service_downtime_seconds <= 300' "${status_file}" >/dev/null; then
        CURRENT_FAILURE=service-downtime-at-most-300
        return 1
    fi

    CURRENT_FAILURE=remote-verify
    validate_remote_set "${backup_id}"
    set_dir="$(<"${PRIVATE_ROOT}/remote-set-path")"
    queue_before="$(queue_snapshot_sha "${set_dir}")"

    CURRENT_FAILURE=source-root-unchanged
    integration_compose down --remove-orphans
    mv -T -- "${TARGET_ROOT}" "${SOURCE_ROOT}"
    source_before="$(tree_sha "${SOURCE_ROOT}")"

    restore_database_password="$(sed -n '1p' "${PRIVATE_ROOT}/restore-secrets")"
    restore_hmac_secret="$(sed -n '2p' "${PRIVATE_ROOT}/restore-secrets")"
    replace_runtime_env "${restore_database_password}" "${restore_hmac_secret}"

    CURRENT_FAILURE=restore
    restore_started="$(date +%s)"
    run_restore "${backup_id}"
    restore_completed="$(date +%s)"
    mark_root "${TARGET_ROOT}"
    if ((restore_completed - restore_started > 14400)); then
        CURRENT_FAILURE=restore-rto-at-most-14400
        return 1
    fi
    restored_projection="$(database_projection_sha)"
    [[ "${restored_projection}" == "${source_projection}" ]]
    queue_after="$(tree_sha "${BACKUP_STATE_ROOT}/restore/${backup_id}/notifier-queue")"
    [[ "${queue_after}" == "${queue_before}" ]]

    CURRENT_FAILURE=notifier-old-mail-not-sent
    verify_restored_mailer_is_empty
    "${MATTERMOST_SEED}" --verify
    append_seed_privacy_patterns

    CURRENT_FAILURE=source-root-unchanged
    source_after="$(tree_sha "${SOURCE_ROOT}")"
    [[ "${source_after}" == "${source_before}" ]]

    CURRENT_FAILURE=privacy
    INTEGRATION_SUCCESS=true
}

main "$@"
