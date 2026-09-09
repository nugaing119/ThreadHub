#!/usr/bin/env bash

# Constants in this library are consumed by scripts that source it.
# shellcheck disable=SC2034

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=existing-notifier-common.sh
source "${SCRIPT_DIR}/existing-notifier-common.sh"

EXISTING_NOTIFIER_V010_V020_ENV_FILE="${THREADHUB_EXISTING_NOTIFIER_ENV_FILE:-${DEPLOY_DIR}/existing-notifier.env}"

readonly EXISTING_NOTIFIER_V010_V020_ID=existing-notifier-v010-v020
readonly EXISTING_NOTIFIER_V010_VERSION=0.1.0
readonly EXISTING_NOTIFIER_V010_SOURCE_COMMIT=c193155eeb6298771d4366d6af4cae81499487b8
readonly EXISTING_NOTIFIER_V020_VERSION=0.2.0
readonly EXISTING_NOTIFIER_V010_MATTERMOST_VERSION=11.7.7
readonly EXISTING_NOTIFIER_V010_POSTGRES_VERSION=18.4
readonly EXISTING_NOTIFIER_V020_CONTENT_MODE=project_team_channel

EXISTING_NOTIFIER_V010_KEYS=(
    THN_COMPOSE_PROJECT_DIR
    THN_COMPOSE_FILE
    THN_COMPOSE_ENV_FILE
    THN_MATTERMOST_SERVICE
    THN_MATTERMOST_PLUGINS_ROOT
    THN_MATTERMOST_DATA_ROOT
    THN_DATA_ROOT
    THN_DOMAIN
    THN_SMTP_SERVER
    THN_SMTP_PORT
    THN_SMTP_CA_FILE
    THN_SMTP_USERNAME
    THN_SMTP_PASSWORD
    THN_SMTP_FROM_ADDRESS
    THN_SMTP_REPLY_TO_ADDRESS
    THN_SMTP_FEEDBACK_NAME
    THN_HMAC_SECRET
    THN_RATE_PER_MINUTE
)
readonly EXISTING_NOTIFIER_V010_KEYS

existing_notifier_v010_v020_value() {
    env_optional_value "$1" "${EXISTING_NOTIFIER_V010_V020_ENV_FILE}"
}

existing_notifier_v010_v020_validate_keyset() {
    local config_file="$1"
    local profile="$2"
    local expected_file

    expected_file="$(mktemp)" || return 1
    if [[ "${profile}" == source ]]; then
        printf '%s\n' "${EXISTING_NOTIFIER_V010_KEYS[@]}" > "${expected_file}"
    elif [[ "${profile}" == target ]]; then
        printf '%s\n' "${EXISTING_NOTIFIER_V010_KEYS[@]}" THN_CONTENT_MODE > "${expected_file}"
    else
        rm -f -- "${expected_file}"
        return 2
    fi
    if ! awk -v expected_file="${expected_file}" '
        BEGIN {
            while ((getline expected_key < expected_file) > 0) expected[expected_key] = 1
            close(expected_file)
        }
        /\r/ { exit 1 }
        /^[[:space:]]*$/ || /^[[:space:]]*#/ { next }
        {
            separator = index($0, "=")
            if (separator < 2) exit 1
            key = substr($0, 1, separator - 1)
            value = substr($0, separator + 1)
            if (!(key in expected) || value == "" || ++count[key] != 1) exit 1
        }
        END {
            if (NR == 0) exit 1
            for (key in expected) if (count[key] != 1) exit 1
        }
    ' "${config_file}"; then
        rm -f -- "${expected_file}"
        return 1
    fi
    rm -f -- "${expected_file}"
}

existing_notifier_v010_v020_config_state() (
    set -Eeuo pipefail

    [[ "$#" -eq 1 ]] || return 2
    config_file="$1"
    runtime_env_require_secure "${config_file}" >/dev/null 2>&1 || return 1

    if existing_notifier_v010_v020_validate_keyset "${config_file}" source; then
        state=source
    elif existing_notifier_v010_v020_validate_keyset "${config_file}" target; then
        state=target
    else
        return 1
    fi

    temporary_dir="$(mktemp -d)"
    trap 'rm -rf -- "${temporary_dir}"' EXIT HUP INT TERM
    chmod 0700 "${temporary_dir}"
    validated_file="${temporary_dir}/existing-notifier.env"
    install -m 0600 "${config_file}" "${validated_file}"
    if [[ "${state}" == source ]]; then
        printf '%s\n' "THN_CONTENT_MODE=${EXISTING_NOTIFIER_V020_CONTENT_MODE}" >> "${validated_file}"
    elif [[ "$(env_optional_value THN_CONTENT_MODE "${validated_file}")" != "${EXISTING_NOTIFIER_V020_CONTENT_MODE}" ]]; then
        return 1
    fi

    EXISTING_NOTIFIER_ENV_FILE="${validated_file}"
    export EXISTING_NOTIFIER_ENV_FILE
    existing_notifier_validate_config >/dev/null 2>&1 || return 1
    printf '%s\n' "${state}"
)

existing_notifier_v010_v020_prepare_target_config() (
    set -Eeuo pipefail

    [[ "$#" -eq 2 ]] || return 2
    source_file="$1"
    destination="$2"
    [[ "$(existing_notifier_v010_v020_config_state "${source_file}")" == source ]] || return 1
    [[ ! -e "${destination}" && ! -L "${destination}" ]] || return 1
    install -m 0600 "${source_file}" "${destination}"
    printf '%s\n' "THN_CONTENT_MODE=${EXISTING_NOTIFIER_V020_CONTENT_MODE}" >> "${destination}"
    [[ "$(existing_notifier_v010_v020_config_state "${destination}")" == target ]]
)
