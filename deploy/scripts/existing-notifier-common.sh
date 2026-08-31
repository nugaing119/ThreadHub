#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

EXISTING_NOTIFIER_ENV_FILE="${THREADHUB_EXISTING_NOTIFIER_ENV_FILE:-${DEPLOY_DIR}/existing-notifier.env}"
EXISTING_NOTIFIER_BASE_COMPOSE=()
EXISTING_NOTIFIER_COMBINED_COMPOSE=()

readonly EXISTING_NOTIFIER_KEYS=(
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
    THN_SMTP_USERNAME
    THN_SMTP_PASSWORD
    THN_SMTP_FROM_ADDRESS
    THN_SMTP_REPLY_TO_ADDRESS
    THN_SMTP_FEEDBACK_NAME
    THN_HMAC_SECRET
    THN_RATE_PER_MINUTE
)

existing_notifier_validate_exact_keys() {
    local config_file="$1"
    local expected_file

    expected_file="$(mktemp)"
    printf '%s\n' "${EXISTING_NOTIFIER_KEYS[@]}" > "${expected_file}"
    if ! awk -v expected_file="${expected_file}" '
        BEGIN {
            while ((getline expected_key < expected_file) > 0) {
                expected[expected_key] = 1
            }
            close(expected_file)
        }
        /\r/ { exit 1 }
        /^[[:space:]]*$/ || /^[[:space:]]*#/ { next }
        {
            separator = index($0, "=")
            if (separator < 2) exit 1
            key = substr($0, 1, separator - 1)
            value = substr($0, separator + 1)
            if (!(key in expected) || value == "") exit 1
            count[key]++
            if (count[key] != 1) exit 1
        }
        END {
            if (NR == 0) exit 1
            for (key in expected) {
                if (count[key] != 1) exit 1
            }
        }
    ' "${config_file}"; then
        rm -f -- "${expected_file}"
        die "Existing notifier configuration has missing, duplicate, unknown, or malformed keys"
    fi
    rm -f -- "${expected_file}"
}

existing_notifier_value() {
    local key="$1"

    env_optional_value "${key}" "${EXISTING_NOTIFIER_ENV_FILE}"
}

existing_notifier_validate_clean_absolute_path() {
    local label="$1"
    local path="$2"

    [[ "${path}" == /* && "${path}" != / && "${path}" != *'//'*
        && "${path}" != */./* && "${path}" != */../*
        && "${path}" != */. && "${path}" != */.. && "${path}" != */ ]] \
        || die "${label} must be a clean non-root absolute path"
}

existing_notifier_path_contains() {
    local parent="$1"
    local candidate="$2"

    [[ "${candidate}" == "${parent}" || "${candidate}" == "${parent}/"* ]]
}

existing_notifier_validate_disjoint_roots() {
    local notifier_root
    local mattermost_plugins_root
    local mattermost_data_root

    notifier_root="$(existing_notifier_value THN_DATA_ROOT)"
    mattermost_plugins_root="$(existing_notifier_value THN_MATTERMOST_PLUGINS_ROOT)"
    mattermost_data_root="$(existing_notifier_value THN_MATTERMOST_DATA_ROOT)"

    if existing_notifier_path_contains "${mattermost_plugins_root}" "${notifier_root}" \
        || existing_notifier_path_contains "${notifier_root}" "${mattermost_plugins_root}" \
        || existing_notifier_path_contains "${mattermost_data_root}" "${notifier_root}" \
        || existing_notifier_path_contains "${notifier_root}" "${mattermost_data_root}" \
        || existing_notifier_path_contains "${mattermost_plugins_root}" "${mattermost_data_root}" \
        || existing_notifier_path_contains "${mattermost_data_root}" "${mattermost_plugins_root}"; then
        die "Notifier, Mattermost plugin, and Mattermost data roots must be disjoint"
    fi
}

existing_notifier_validate_config() {
    local key
    local rate_per_minute
    local feedback_name

    runtime_env_require_secure "${EXISTING_NOTIFIER_ENV_FILE}" || return $?
    existing_notifier_validate_exact_keys "${EXISTING_NOTIFIER_ENV_FILE}"

    for key in \
        THN_COMPOSE_PROJECT_DIR \
        THN_COMPOSE_FILE \
        THN_COMPOSE_ENV_FILE \
        THN_MATTERMOST_PLUGINS_ROOT \
        THN_MATTERMOST_DATA_ROOT \
        THN_DATA_ROOT; do
        existing_notifier_validate_clean_absolute_path "${key}" "$(existing_notifier_value "${key}")"
    done

    [[ "$(existing_notifier_value THN_MATTERMOST_SERVICE)" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] \
        || die "THN_MATTERMOST_SERVICE is invalid"
    validate_domain "$(existing_notifier_value THN_DOMAIN)"
    validate_domain "$(existing_notifier_value THN_SMTP_SERVER)"
    validate_email THN_SMTP_FROM_ADDRESS "$(existing_notifier_value THN_SMTP_FROM_ADDRESS)"
    validate_email THN_SMTP_REPLY_TO_ADDRESS "$(existing_notifier_value THN_SMTP_REPLY_TO_ADDRESS)"
    [[ "$(existing_notifier_value THN_SMTP_PORT)" == 587 ]] \
        || die "THN_SMTP_PORT must be 587"
    is_placeholder "$(existing_notifier_value THN_SMTP_USERNAME)" \
        && die "THN_SMTP_USERNAME still contains an example value"
    is_placeholder "$(existing_notifier_value THN_SMTP_PASSWORD)" \
        && die "THN_SMTP_PASSWORD still contains an example value"
    [[ "$(existing_notifier_value THN_HMAC_SECRET)" =~ ^[A-Fa-f0-9]{64}$ ]] \
        || die "THN_HMAC_SECRET must contain exactly 64 hexadecimal characters"

    rate_per_minute="$(existing_notifier_value THN_RATE_PER_MINUTE)"
    [[ "${rate_per_minute}" =~ ^[0-9]+$ ]] \
        || die "THN_RATE_PER_MINUTE must be an integer from 1 through 60"
    ((rate_per_minute >= 1 && rate_per_minute <= 60)) \
        || die "THN_RATE_PER_MINUTE must be an integer from 1 through 60"

    feedback_name="$(existing_notifier_value THN_SMTP_FEEDBACK_NAME)"
    ((${#feedback_name} >= 1 && ${#feedback_name} <= 64)) \
        || die "THN_SMTP_FEEDBACK_NAME must contain from 1 through 64 characters"
    existing_notifier_validate_disjoint_roots
}

existing_notifier_init_compose() {
    local project_dir
    local compose_file
    local compose_env_file
    local override_file

    project_dir="$(existing_notifier_value THN_COMPOSE_PROJECT_DIR)"
    compose_file="$(existing_notifier_value THN_COMPOSE_FILE)"
    compose_env_file="$(existing_notifier_value THN_COMPOSE_ENV_FILE)"
    override_file="$(existing_notifier_value THN_DATA_ROOT)/compose.override.yml"

    EXISTING_NOTIFIER_BASE_COMPOSE=(
        "${DOCKER_COMMAND[@]}" compose
        --project-directory "${project_dir}"
        --env-file "${compose_env_file}"
        -f "${compose_file}"
    )
    EXISTING_NOTIFIER_COMBINED_COMPOSE=(
        "${EXISTING_NOTIFIER_BASE_COMPOSE[@]}"
        --env-file "${EXISTING_NOTIFIER_ENV_FILE}"
        -f "${override_file}"
    )
}

existing_notifier_compose_base() {
    "${EXISTING_NOTIFIER_BASE_COMPOSE[@]}" "$@"
}

existing_notifier_compose_combined() {
    "${EXISTING_NOTIFIER_COMBINED_COMPOSE[@]}" "$@"
}
