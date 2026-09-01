#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

MODE="${1:-}"
INTEGRATION_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(cd "${INTEGRATION_DIR}/../.." && pwd)"
FIXTURE_ROOT="${THREADHUB_INTEGRATION_FIXTURE_ROOT:-}"
BASE_URL="${THREADHUB_INTEGRATION_BASE_URL:-http://127.0.0.1:8065}"
CREDENTIALS_FILE="${FIXTURE_ROOT}/mattermost-credentials.env"
IDS_FILE="${FIXTURE_ROOT}/mattermost-ids.env"
AUTH_CONFIG="${FIXTURE_ROOT}/mattermost-curl-auth.conf"
API_ROOT="${FIXTURE_ROOT}/api"
COMPOSE_PROJECT_NAME=threadhub-backup-integration

fail() {
    printf 'mattermost-seed failed\n' >&2
    exit 1
}

require_fixture_root() {
    [[ "${FIXTURE_ROOT}" == /* \
        && -d "${FIXTURE_ROOT}" && ! -L "${FIXTURE_ROOT}" \
        && "$(stat -c '%a' "${FIXTURE_ROOT}")" == 700 \
        && "${BASE_URL}" == http://127.0.0.1:[0-9]* ]] || fail
    if [[ ! -e "${API_ROOT}" && ! -L "${API_ROOT}" ]]; then
        install -d -m 0700 "${API_ROOT}" || fail
    fi
    [[ -d "${API_ROOT}" && ! -L "${API_ROOT}" \
        && "$(stat -c '%a' "${API_ROOT}")" == 700 ]] || fail
}

require_private_file() {
    [[ -f "$1" && ! -L "$1" && "$(stat -c '%a' "$1")" == 600 ]]
}

env_file_value() {
    local key="$1" file="$2"

    LC_ALL=C awk -v key="${key}" '
        index($0, key "=") == 1 { count++; value=substr($0, length(key)+2) }
        END { if (count != 1 || value == "") exit 1; print value }
    ' "${file}"
}

write_json() {
    local destination="$1" filter="$2"

    [[ ! -e "${destination}" && ! -L "${destination}" ]] || fail
    jq -cn "${filter}" > "${destination}" || fail
    chmod 0600 "${destination}"
}

api_request() {
    local method="$1" path="$2" response="$3" request="${4:-}" auth="${5:-true}"
    local -a args=(
        --fail-with-body --silent --show-error
        --request "${method}"
        --output "${response}"
    )

    [[ "${path}" == /api/v4/* \
        && "${response}" == "${API_ROOT}/"* \
        && ! -e "${response}" && ! -L "${response}" ]] || fail
    if [[ "${auth}" == true ]]; then
        require_private_file "${AUTH_CONFIG}" || fail
        args+=(--config "${AUTH_CONFIG}")
    elif [[ "${auth}" != false ]]; then
        fail
    fi
    if [[ -n "${request}" ]]; then
        require_private_file "${request}" || fail
        args+=(--header 'Content-Type: application/json' --data-binary "@${request}")
    fi
    curl "${args[@]}" "${BASE_URL}${path}" || fail
    chmod 0600 "${response}"
}

create_auth_config() {
    local token="$1" temporary

    [[ "${token}" =~ ^[A-Za-z0-9_-]{20,256}$ ]] || fail
    temporary="$(mktemp "${FIXTURE_ROOT}/.curl-auth.XXXXXX")" || fail
    printf 'header = "Authorization: Bearer %s"\n' "${token}" > "${temporary}"
    chmod 0600 "${temporary}"
    [[ ! -e "${AUTH_CONFIG}" && ! -L "${AUTH_CONFIG}" ]] || fail
    ln -T -- "${temporary}" "${AUTH_CONFIG}" || fail
    rm -f -- "${temporary}"
}

verify_user_email_locally() {
    local username="$1"

    [[ "${username}" =~ ^[a-z][a-z0-9._-]{2,63}$ ]] || fail
    docker compose \
        --project-name "${COMPOSE_PROJECT_NAME}" \
        --env-file "${DEPLOY_DIR}/.env" \
        --env-file "${DEPLOY_DIR}/versions.env" \
        -f "${DEPLOY_DIR}/docker-compose.yml" \
        exec -T mattermost mmctl user verify "${username}" \
            --local --suppress-warnings >/dev/null || fail
}

login() {
    local request response headers token

    request="${API_ROOT}/login-request.json"
    response="${API_ROOT}/login-response.json"
    headers="${API_ROOT}/login-headers"
    rm -f -- "${request}" "${response}" "${headers}" "${AUTH_CONFIG}"
    export ADMIN_USERNAME ADMIN_PASSWORD
    write_json "${request}" \
        '{login_id:env.ADMIN_USERNAME,password:env.ADMIN_PASSWORD}'
    curl --fail-with-body --silent --show-error \
        --request POST --header 'Content-Type: application/json' \
        --data-binary "@${request}" --dump-header "${headers}" \
        --output "${response}" "${BASE_URL}/api/v4/users/login" || fail
    chmod 0600 "${headers}" "${response}"
    token="$(awk 'tolower($1) == "token:" { gsub("\\r", "", $2); count++; value=$2 }
        END { if (count != 1 || value == "") exit 1; print value }' "${headers}")" || fail
    create_auth_config "${token}"
}

create_user() {
    local label="$1" auth="$2" username="$3" email="$4" password="$5"
    local request="${API_ROOT}/${label}-request.json" response="${API_ROOT}/${label}-response.json"

    export INTEGRATION_USERNAME="${username}" INTEGRATION_EMAIL="${email}" \
        INTEGRATION_PASSWORD="${password}"
    write_json "${request}" \
        '{username:env.INTEGRATION_USERNAME,email:env.INTEGRATION_EMAIL,password:env.INTEGRATION_PASSWORD,locale:"ko"}'
    api_request POST /api/v4/users "${response}" "${request}" "${auth}"
    jq -er '.id | select(type == "string" and test("^[a-z0-9]{26}$"))' "${response}" || fail
}

create_team() {
    local request="${API_ROOT}/team-request.json" response="${API_ROOT}/team-response.json"

    write_json "${request}" '{name:"backup-integration",display_name:"Backup Integration",type:"I"}'
    api_request POST /api/v4/teams "${response}" "${request}"
    jq -er '.id | select(type == "string" and test("^[a-z0-9]{26}$"))' "${response}" || fail
}

create_channel() {
    local label="$1" team_id="$2" name="$3" display="$4" type="$5"
    local request="${API_ROOT}/${label}-channel-request.json"
    local response="${API_ROOT}/${label}-channel-response.json"

    export INTEGRATION_TEAM_ID="${team_id}" INTEGRATION_CHANNEL_NAME="${name}" \
        INTEGRATION_CHANNEL_DISPLAY="${display}" INTEGRATION_CHANNEL_TYPE="${type}"
    write_json "${request}" \
        '{team_id:env.INTEGRATION_TEAM_ID,name:env.INTEGRATION_CHANNEL_NAME,display_name:env.INTEGRATION_CHANNEL_DISPLAY,type:env.INTEGRATION_CHANNEL_TYPE}'
    api_request POST /api/v4/channels "${response}" "${request}"
    jq -er '.id | select(type == "string" and test("^[a-z0-9]{26}$"))' "${response}" || fail
}

add_team_member() {
    local team_id="$1" user_id="$2" request response

    request="${API_ROOT}/team-member-request.json"
    response="${API_ROOT}/team-member-response.json"
    export INTEGRATION_TEAM_ID="${team_id}" INTEGRATION_USER_ID="${user_id}"
    write_json "${request}" '{team_id:env.INTEGRATION_TEAM_ID,user_id:env.INTEGRATION_USER_ID}'
    api_request POST "/api/v4/teams/${team_id}/members" "${response}" "${request}"
}

add_channel_member() {
    local label="$1" channel_id="$2" user_id="$3" request response

    request="${API_ROOT}/${label}-member-request.json"
    response="${API_ROOT}/${label}-member-response.json"
    export INTEGRATION_CHANNEL_ID="${channel_id}" INTEGRATION_USER_ID="${user_id}"
    write_json "${request}" '{channel_id:env.INTEGRATION_CHANNEL_ID,user_id:env.INTEGRATION_USER_ID}'
    api_request POST "/api/v4/channels/${channel_id}/members" "${response}" "${request}"
}

create_post() {
    local label="$1" channel_id="$2" message="$3" root_id="${4:-}" file_id="${5:-}"
    local request="${API_ROOT}/${label}-post-request.json" response="${API_ROOT}/${label}-post-response.json"

    export INTEGRATION_CHANNEL_ID="${channel_id}" INTEGRATION_MESSAGE="${message}" \
        INTEGRATION_ROOT_ID="${root_id}" INTEGRATION_FILE_ID="${file_id}"
    if [[ -n "${file_id}" ]]; then
        write_json "${request}" \
            '{channel_id:env.INTEGRATION_CHANNEL_ID,message:env.INTEGRATION_MESSAGE,file_ids:[env.INTEGRATION_FILE_ID]}'
    elif [[ -n "${root_id}" ]]; then
        write_json "${request}" \
            '{channel_id:env.INTEGRATION_CHANNEL_ID,message:env.INTEGRATION_MESSAGE,root_id:env.INTEGRATION_ROOT_ID}'
    else
        write_json "${request}" \
            '{channel_id:env.INTEGRATION_CHANNEL_ID,message:env.INTEGRATION_MESSAGE}'
    fi
    api_request POST /api/v4/posts "${response}" "${request}"
    jq -er '.id | select(type == "string" and test("^[a-z0-9]{26}$"))' "${response}" || fail
}

upload_file() {
    local channel_id="$1" source="$2" response="${API_ROOT}/file-upload-response.json"

    require_private_file "${AUTH_CONFIG}" || fail
    [[ -f "${source}" && ! -L "${source}" && ! -e "${response}" ]] || fail
    curl --fail-with-body --silent --show-error --config "${AUTH_CONFIG}" \
        --request POST --form "channel_id=${channel_id}" --form "files=@${source}" \
        --output "${response}" "${BASE_URL}/api/v4/files" || fail
    chmod 0600 "${response}"
    jq -er '.file_infos | select(length == 1) | .[0].id | select(type == "string" and test("^[a-z0-9]{26}$"))' \
        "${response}" || fail
}

write_credentials() {
    local temporary

    temporary="$(mktemp "${FIXTURE_ROOT}/.credentials.XXXXXX")" || fail
    {
        printf 'ADMIN_USERNAME=%s\n' "${ADMIN_USERNAME}"
        printf 'ADMIN_PASSWORD=%s\n' "${ADMIN_PASSWORD}"
        printf 'MEMBER_USERNAME=%s\n' "${MEMBER_USERNAME}"
        printf 'MEMBER_PASSWORD=%s\n' "${MEMBER_PASSWORD}"
    } > "${temporary}"
    chmod 0600 "${temporary}"
    [[ ! -e "${CREDENTIALS_FILE}" && ! -L "${CREDENTIALS_FILE}" ]] || fail
    ln -T -- "${temporary}" "${CREDENTIALS_FILE}" || fail
    rm -f -- "${temporary}"
}

write_ids() {
    local temporary

    temporary="$(mktemp "${FIXTURE_ROOT}/.ids.XXXXXX")" || fail
    {
        printf 'ADMIN_ID=%s\n' "${ADMIN_ID}"
        printf 'MEMBER_ID=%s\n' "${MEMBER_ID}"
        printf 'TEAM_ID=%s\n' "${TEAM_ID}"
        printf 'PUBLIC_CHANNEL_ID=%s\n' "${PUBLIC_CHANNEL_ID}"
        printf 'PRIVATE_CHANNEL_ID=%s\n' "${PRIVATE_CHANNEL_ID}"
        printf 'PUBLIC_POST_ID=%s\n' "${PUBLIC_POST_ID}"
        printf 'PRIVATE_POST_ID=%s\n' "${PRIVATE_POST_ID}"
        printf 'THREAD_REPLY_ID=%s\n' "${THREAD_REPLY_ID}"
        printf 'FILE_ID=%s\n' "${FILE_ID}"
        printf 'FILE_POST_ID=%s\n' "${FILE_POST_ID}"
        printf 'FILE_SHA256=%s\n' "${FILE_SHA256}"
    } > "${temporary}"
    chmod 0600 "${temporary}"
    [[ ! -e "${IDS_FILE}" && ! -L "${IDS_FILE}" ]] || fail
    ln -T -- "${temporary}" "${IDS_FILE}" || fail
    rm -f -- "${temporary}"
}

seed() {
    local attachment

    [[ ! -e "${CREDENTIALS_FILE}" && ! -L "${CREDENTIALS_FILE}" \
        && ! -e "${IDS_FILE}" && ! -L "${IDS_FILE}" ]] || fail
    ADMIN_USERNAME=integrationadmin
    MEMBER_USERNAME=integrationmember
    ADMIN_PASSWORD="$(openssl rand -hex 24)"
    MEMBER_PASSWORD="$(openssl rand -hex 24)"
    write_credentials

    ADMIN_ID="$(create_user admin false integrationadmin admin@integration.invalid "${ADMIN_PASSWORD}")"
    verify_user_email_locally "${ADMIN_USERNAME}"
    login
    MEMBER_ID="$(create_user member true integrationmember member@integration.invalid "${MEMBER_PASSWORD}")"
    verify_user_email_locally "${MEMBER_USERNAME}"
    TEAM_ID="$(create_team)"
    add_team_member "${TEAM_ID}" "${MEMBER_ID}"
    PUBLIC_CHANNEL_ID="$(create_channel public "${TEAM_ID}" integration-public 'Integration Public' O)"
    PRIVATE_CHANNEL_ID="$(create_channel private "${TEAM_ID}" integration-private 'Integration Private' P)"
    add_channel_member public "${PUBLIC_CHANNEL_ID}" "${MEMBER_ID}"
    add_channel_member private "${PRIVATE_CHANNEL_ID}" "${MEMBER_ID}"
    PUBLIC_POST_ID="$(create_post public "${PUBLIC_CHANNEL_ID}" 'integration public root')"
    PRIVATE_POST_ID="$(create_post private "${PRIVATE_CHANNEL_ID}" 'integration private root')"
    THREAD_REPLY_ID="$(create_post thread "${PUBLIC_CHANNEL_ID}" 'integration thread reply' "${PUBLIC_POST_ID}")"
    attachment="${FIXTURE_ROOT}/integration-attachment.txt"
    printf '%s\n' 'integration attachment body' > "${attachment}"
    chmod 0600 "${attachment}"
    FILE_SHA256="$(sha256sum "${attachment}" | awk '{print $1}')"
    FILE_ID="$(upload_file "${PUBLIC_CHANNEL_ID}" "${attachment}")"
    FILE_POST_ID="$(create_post file "${PUBLIC_CHANNEL_ID}" 'integration attachment post' '' "${FILE_ID}")"
    write_ids
    printf 'seeded=1\n'
}

verify_json_id() {
    local label="$1" path="$2" expected="$3" response

    response="${API_ROOT}/verify-${label}.json"

    rm -f -- "${response}"
    api_request GET "${path}" "${response}"
    jq -e --arg expected "${expected}" '.id == $expected' "${response}" >/dev/null || fail
}

verify() {
    local downloaded="${API_ROOT}/verify-file" root_id

    require_private_file "${CREDENTIALS_FILE}" || fail
    require_private_file "${IDS_FILE}" || fail
    ADMIN_USERNAME="$(env_file_value ADMIN_USERNAME "${CREDENTIALS_FILE}")"
    ADMIN_PASSWORD="$(env_file_value ADMIN_PASSWORD "${CREDENTIALS_FILE}")"
    login
    for key in ADMIN_ID MEMBER_ID TEAM_ID PUBLIC_CHANNEL_ID PRIVATE_CHANNEL_ID \
        PUBLIC_POST_ID PRIVATE_POST_ID THREAD_REPLY_ID FILE_ID FILE_POST_ID FILE_SHA256; do
        printf -v "${key}" '%s' "$(env_file_value "${key}" "${IDS_FILE}")"
    done
    verify_json_id admin "/api/v4/users/${ADMIN_ID}" "${ADMIN_ID}"
    verify_json_id member "/api/v4/users/${MEMBER_ID}" "${MEMBER_ID}"
    verify_json_id team "/api/v4/teams/${TEAM_ID}" "${TEAM_ID}"
    verify_json_id public-channel "/api/v4/channels/${PUBLIC_CHANNEL_ID}" "${PUBLIC_CHANNEL_ID}"
    verify_json_id private-channel "/api/v4/channels/${PRIVATE_CHANNEL_ID}" "${PRIVATE_CHANNEL_ID}"
    verify_json_id public-post "/api/v4/posts/${PUBLIC_POST_ID}" "${PUBLIC_POST_ID}"
    verify_json_id private-post "/api/v4/posts/${PRIVATE_POST_ID}" "${PRIVATE_POST_ID}"
    verify_json_id file-post "/api/v4/posts/${FILE_POST_ID}" "${FILE_POST_ID}"
    response="${API_ROOT}/verify-thread.json"
    rm -f -- "${response}"
    api_request GET "/api/v4/posts/${THREAD_REPLY_ID}" "${response}"
    root_id="$(jq -er '.root_id | select(type == "string")' "${response}")" || fail
    [[ "${root_id}" == "${PUBLIC_POST_ID}" ]] || fail
    rm -f -- "${downloaded}"
    curl --fail-with-body --silent --show-error --config "${AUTH_CONFIG}" \
        --output "${downloaded}" "${BASE_URL}/api/v4/files/${FILE_ID}" || fail
    chmod 0600 "${downloaded}"
    [[ "$(sha256sum "${downloaded}" | awk '{print $1}')" == "${FILE_SHA256}" ]] || fail
    printf 'verified=1\n'
}

require_fixture_root
case "${MODE}" in
    --seed) seed ;;
    --verify) verify ;;
    *) fail ;;
esac
