#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=existing-notifier-preflight.sh
source "${SCRIPT_DIR}/existing-notifier-preflight.sh"
# shellcheck source=existing-notifier-overlay.sh
source "${SCRIPT_DIR}/existing-notifier-overlay.sh"
# shellcheck source=notifier-plugin-files.sh
source "${SCRIPT_DIR}/notifier-plugin-files.sh"
# shellcheck source=notifier-plugin-transaction.sh
source "${SCRIPT_DIR}/notifier-plugin-transaction.sh"
# shellcheck source=notifier-plugin-install-lib.sh
source "${SCRIPT_DIR}/notifier-plugin-install-lib.sh"
# shellcheck source=notifier-artifact-build-lib.sh
source "${SCRIPT_DIR}/notifier-artifact-build-lib.sh"

EXISTING_NOTIFIER_SETUP_CONFIG_IDENTITY=""
EXISTING_NOTIFIER_SETUP_CONFIG_HASH=""

existing_notifier_setup_action_required() {
    printf '[ACTION REQUIRED] %s\n' "$1" >&2
    return 20
}

existing_notifier_setup_validate_config() {
    existing_notifier_validate_config || return $?
    require_ubuntu_amd64
    require_command git
    require_command jq
    require_command tar
    require_command cmp
    require_command sort
    require_command openssl
    require_command stat
    require_command mv
    require_command ln
    runtime_env_require_atomic_tools || return $?
    init_docker
    init_sudo
}

existing_notifier_setup_capture_config_identity() {
    EXISTING_NOTIFIER_SETUP_CONFIG_IDENTITY="$(runtime_env_identity "${EXISTING_NOTIFIER_ENV_FILE}")" \
        || return 1
    EXISTING_NOTIFIER_SETUP_CONFIG_HASH="$(sha256_file "${EXISTING_NOTIFIER_ENV_FILE}")" \
        || return 1
    [[ "${EXISTING_NOTIFIER_SETUP_CONFIG_HASH}" =~ ^[a-f0-9]{64}$ ]]
}

existing_notifier_setup_recheck_config() {
    [[ "$(runtime_env_identity "${EXISTING_NOTIFIER_ENV_FILE}")" \
        == "${EXISTING_NOTIFIER_SETUP_CONFIG_IDENTITY}" ]] || return 1
    [[ "$(sha256_file "${EXISTING_NOTIFIER_ENV_FILE}")" \
        == "${EXISTING_NOTIFIER_SETUP_CONFIG_HASH}" ]]
}

existing_notifier_setup_preflight() {
    local presence
    presence="$(existing_notifier_target_objects_presence)" || {
        existing_notifier_setup_action_required \
            "Notifier runtime and filestore plugin objects are asymmetric"
        return $?
    }
    if [[ "${presence}" == present ]]; then
        existing_notifier_preflight_dispatch installed
    else
        existing_notifier_preflight_dispatch initial
    fi
}

existing_notifier_setup_directory_is() {
    local path="$1"
    local expected="$2"
    local identity

    "${SUDO_COMMAND[@]}" test -d "${path}" || return 1
    "${SUDO_COMMAND[@]}" test ! -L "${path}" || return 1
    identity="$("${SUDO_COMMAND[@]}" stat -c '%u:%g:%a' "${path}")" || return 1
    [[ "${identity}" == "${expected}" ]]
}

existing_notifier_setup_prepare_runtime() {
    local notifier_root
    local parent_root
    local existing_entry
    local identity
    local parent_uid
    local parent_gid
    local parent_mode

    notifier_root="$(existing_notifier_value THN_DATA_ROOT)"
    parent_root="$(dirname "${notifier_root}")"
    if ! "${SUDO_COMMAND[@]}" test -d "${parent_root}" \
        || "${SUDO_COMMAND[@]}" test -L "${parent_root}"; then
        die "Notifier runtime parent is missing or unsafe"
    fi
    identity="$("${SUDO_COMMAND[@]}" stat -c '%u:%g:%a' "${parent_root}")" \
        || die "Notifier runtime parent identity is unavailable"
    IFS=: read -r parent_uid parent_gid parent_mode <<< "${identity}"
    [[ "${parent_uid}" == 0 && "${parent_gid}" == 0 \
        && "${parent_mode}" =~ ^[0-7]{3,4}$ ]] \
        || die "Notifier runtime parent must be owned by root"
    (( (8#${parent_mode} & 0022) == 0 )) \
        || die "Notifier runtime parent must not be writable by group or other users"
    "${SUDO_COMMAND[@]}" test ! -L "${notifier_root}" \
        || die "Refusing symbolic-link notifier runtime root"
    if "${SUDO_COMMAND[@]}" test -e "${notifier_root}"; then
        existing_notifier_setup_directory_is "${notifier_root}" 0:0:750 \
            || die "Existing notifier runtime root is not managed safely"
        while IFS= read -r existing_entry; do
            case "${existing_entry}" in
                "${notifier_root}/control")
                    existing_notifier_setup_directory_is "${existing_entry}" 0:3000:750 \
                        || die "Existing notifier control directory is unsafe"
                    ;;
                "${notifier_root}/mailer")
                    existing_notifier_setup_directory_is "${existing_entry}" 65532:65532:700 \
                        || die "Existing notifier Mailer directory is unsafe"
                    ;;
                "${notifier_root}/release"|"${notifier_root}/rollback")
                    existing_notifier_setup_directory_is "${existing_entry}" 0:0:750 \
                        || die "Existing notifier managed directory is unsafe"
                    ;;
                "${notifier_root}/compose.override.yml")
                    if ! "${SUDO_COMMAND[@]}" test -f "${existing_entry}" \
                        || "${SUDO_COMMAND[@]}" test -L "${existing_entry}"; then
                        die "Existing notifier override is unsafe"
                    fi
                    identity="$("${SUDO_COMMAND[@]}" stat -c '%u:%g:%a' "${existing_entry}")" \
                        || die "Existing notifier override identity is unavailable"
                    [[ "${identity}" == 0:0:600 ]] \
                        || die "Existing notifier override must be root:root with mode 0600"
                    ;;
                *)
                    die "Existing notifier runtime contains an unmanaged entry"
                    ;;
            esac
        done < <("${SUDO_COMMAND[@]}" find "${notifier_root}" \
            -mindepth 1 -maxdepth 1 -print)
    fi
    "${SUDO_COMMAND[@]}" install -d -o root -g root -m 0750 \
        "${notifier_root}" "${notifier_root}/release" "${notifier_root}/rollback"
    "${SUDO_COMMAND[@]}" install -d -o root -g 3000 -m 0750 \
        "${notifier_root}/control"
    "${SUDO_COMMAND[@]}" install -d -o 65532 -g 65532 -m 0700 \
        "${notifier_root}/mailer"
    if ! existing_notifier_setup_directory_is "${notifier_root}" 0:0:750 \
        || ! existing_notifier_setup_directory_is "${notifier_root}/release" 0:0:750 \
        || ! existing_notifier_setup_directory_is "${notifier_root}/rollback" 0:0:750 \
        || ! existing_notifier_setup_directory_is "${notifier_root}/control" 0:3000:750 \
        || ! existing_notifier_setup_directory_is "${notifier_root}/mailer" 65532:65532:700; then
        die "Notifier runtime directory identity is invalid"
    fi
}

existing_notifier_setup_write_disabled_control() {
    local state_file
    state_file="$(existing_notifier_value THN_DATA_ROOT)/control/state.json"
    notifier_write_control_state "${state_file}" false false all_channels '' 0 \
        || die "Notifier disabled control state could not be installed"
}

existing_notifier_setup_rollback_capture_is_valid() {
    local capture_file="$1"
    local identity

    "${SUDO_COMMAND[@]}" test -f "${capture_file}" || return 1
    "${SUDO_COMMAND[@]}" test ! -L "${capture_file}" || return 1
    identity="$("${SUDO_COMMAND[@]}" stat -c '%u:%g:%a' "${capture_file}")" || return 1
    [[ "${identity}" == 0:0:600 ]] || return 1
    # The jq program intentionally uses jq variables inside a single-quoted filter.
    # shellcheck disable=SC2016
    "${SUDO_COMMAND[@]}" jq -e \
        --arg service "$(existing_notifier_value THN_MATTERMOST_SERVICE)" \
        --arg plugins_root "$(existing_notifier_value THN_MATTERMOST_PLUGINS_ROOT)" \
        --arg filestore_root "$(existing_notifier_value THN_MATTERMOST_DATA_ROOT)/plugins" '
        type == "object" and
        keys == ["captured_at", "filestore_root", "mattermost_service", "plugin_id", "plugins_root", "previous_pair", "schema"] and
        .schema == 1 and .previous_pair == "absent" and
        .plugin_id == "com.threadhub.channel-email-notifier" and
        .mattermost_service == $service and .plugins_root == $plugins_root and
        .filestore_root == $filestore_root and
        (.captured_at | type == "number" and floor == . and . > 0)
    ' "${capture_file}" >/dev/null 2>&1
}

existing_notifier_setup_record_rollback_capture() (
    local capture_file
    local temporary_file
    local staged_file
    local presence

    capture_file="$(existing_notifier_value THN_DATA_ROOT)/rollback/capture.json"
    if "${SUDO_COMMAND[@]}" test -e "${capture_file}" \
        || "${SUDO_COMMAND[@]}" test -L "${capture_file}"; then
        existing_notifier_setup_rollback_capture_is_valid "${capture_file}" \
            || die "Existing notifier rollback capture is invalid"
        return 0
    fi
    presence="$(existing_notifier_target_objects_presence)" \
        || die "Notifier runtime and filestore objects are asymmetric"
    if [[ "${presence}" != absent ]]; then
        existing_notifier_setup_action_required \
            "A verified pre-adoption rollback capture is missing; the installed pair was not changed"
        return $?
    fi
    temporary_file="$(mktemp)"
    staged_file="${capture_file}.tmp.$$"
    trap 'rm -f -- "${temporary_file}"' EXIT HUP INT TERM
    jq -cn \
        --arg service "$(existing_notifier_value THN_MATTERMOST_SERVICE)" \
        --arg plugins_root "$(existing_notifier_value THN_MATTERMOST_PLUGINS_ROOT)" \
        --arg filestore_root "$(existing_notifier_value THN_MATTERMOST_DATA_ROOT)/plugins" \
        --argjson captured_at "$(notifier_epoch_millis)" '
        {
          schema:1,
          previous_pair:"absent",
          plugin_id:"com.threadhub.channel-email-notifier",
          mattermost_service:$service,
          plugins_root:$plugins_root,
          filestore_root:$filestore_root,
          captured_at:$captured_at
        }
    ' > "${temporary_file}"
    chmod 0600 "${temporary_file}"
    if "${SUDO_COMMAND[@]}" test -e "${staged_file}" \
        || "${SUDO_COMMAND[@]}" test -L "${staged_file}"; then
        die "Refusing existing rollback capture staging path"
    fi
    "${SUDO_COMMAND[@]}" install -o root -g root -m 0600 \
        "${temporary_file}" "${staged_file}" \
        || die "Rollback capture could not be staged"
    if ! "${SUDO_COMMAND[@]}" ln -T -- "${staged_file}" "${capture_file}"; then
        "${SUDO_COMMAND[@]}" rm -f -- "${staged_file}" >/dev/null 2>&1 || true
        existing_notifier_setup_action_required \
            "Rollback capture appeared and was not overwritten"
        return $?
    fi
    "${SUDO_COMMAND[@]}" rm -f -- "${staged_file}"
    existing_notifier_setup_rollback_capture_is_valid "${capture_file}" \
        || die "Published rollback capture is invalid"
    rm -f -- "${temporary_file}"
    trap - EXIT HUP INT TERM
)

existing_notifier_setup_build_artifacts() {
    local release_dir
    local release_file
    release_dir="$(existing_notifier_value THN_DATA_ROOT)/release"
    release_file="${release_dir}/release.env"
    if notifier_artifact_release_is_current "${release_dir}"; then
        log "Reusing the exact reviewed notifier artifacts and Mailer image"
        return 0
    fi
    if "${SUDO_COMMAND[@]}" test -e "${release_file}" \
        || "${SUDO_COMMAND[@]}" test -L "${release_file}"; then
        existing_notifier_setup_action_required \
            "Existing notifier release identity differs and was not overwritten"
        return $?
    fi
    notifier_build_artifacts "${release_dir}"
}

existing_notifier_setup_publish_override() {
    local source_path="$1"
    local destination_path="$2"
    local staged_path="${destination_path}.tmp.$$"

    "${SUDO_COMMAND[@]}" test ! -e "${destination_path}" \
        && "${SUDO_COMMAND[@]}" test ! -L "${destination_path}" \
        && "${SUDO_COMMAND[@]}" test ! -e "${staged_path}" \
        && "${SUDO_COMMAND[@]}" test ! -L "${staged_path}" \
        || return 1
    "${SUDO_COMMAND[@]}" install -o root -g root -m 0600 "${source_path}" "${staged_path}" \
        || return 1
    if ! "${SUDO_COMMAND[@]}" ln -T -- "${staged_path}" "${destination_path}"; then
        "${SUDO_COMMAND[@]}" rm -f -- "${staged_path}" >/dev/null 2>&1 || true
        return 1
    fi
    "${SUDO_COMMAND[@]}" rm -f -- "${staged_path}" || return 1
}

existing_notifier_setup_write_override() {
    local destination
    destination="$(existing_notifier_value THN_DATA_ROOT)/compose.override.yml"
    existing_notifier_publish_override() {
        existing_notifier_setup_publish_override "$@"
    }
    existing_notifier_override_parent_is_safe() {
        "${SUDO_COMMAND[@]}" test -d "$1" && "${SUDO_COMMAND[@]}" test ! -L "$1"
    }
    existing_notifier_override_exists() {
        "${SUDO_COMMAND[@]}" test -e "$1" || "${SUDO_COMMAND[@]}" test -L "$1"
    }
    existing_notifier_override_is_exact() {
        local path="$1"
        local expected_hash="$2"
        local identity
        local actual_hash
        "${SUDO_COMMAND[@]}" test -f "${path}" || return 1
        "${SUDO_COMMAND[@]}" test ! -L "${path}" || return 1
        identity="$("${SUDO_COMMAND[@]}" stat -c '%u:%g:%a' "${path}")" || return 1
        [[ "${identity}" == 0:0:600 ]] || return 1
        actual_hash="$(notifier_plugin_privileged_sha256 "${path}")" || return 1
        [[ "${actual_hash}" == "${expected_hash}" ]]
    }
    existing_notifier_write_override "${destination}"
}

existing_notifier_setup_start_mailer() {
    existing_notifier_init_compose
    existing_notifier_compose_combined up -d --no-deps --wait --wait-timeout 120 \
        threadhub-mailer
}

existing_notifier_setup_verify_mailer() {
    existing_notifier_compose_combined exec -T threadhub-mailer \
        /threadhub-mailer healthcheck >/dev/null
}

existing_notifier_setup_prepare_filestore_plugins_root() {
    local data_root
    local filestore_plugins_root

    data_root="$(existing_notifier_value THN_MATTERMOST_DATA_ROOT)"
    filestore_plugins_root="${data_root}/plugins"
    existing_notifier_setup_directory_is "${data_root}" 2000:2000:750 \
        || die "Mattermost data directory must be 2000:2000 with mode 0750"
    if "${SUDO_COMMAND[@]}" test -e "${filestore_plugins_root}" \
        || "${SUDO_COMMAND[@]}" test -L "${filestore_plugins_root}"; then
        existing_notifier_setup_directory_is \
            "${filestore_plugins_root}" 2000:2000:750 \
            || die "Existing Mattermost filestore plugin directory is unsafe"
        return 0
    fi
    "${SUDO_COMMAND[@]}" mkdir -m 0750 -- "${filestore_plugins_root}" \
        || die "Mattermost filestore plugin directory appeared and was not changed"
    "${SUDO_COMMAND[@]}" chown 2000:2000 -- "${filestore_plugins_root}" \
        || die "Mattermost filestore plugin directory ownership could not be set"
    existing_notifier_setup_directory_is \
        "${filestore_plugins_root}" 2000:2000:750 \
        || die "Mattermost filestore plugin directory identity is invalid"
}

existing_notifier_setup_install_plugin() {
    local notifier_root
    local presence
    presence="$(existing_notifier_target_objects_presence)" || return 1
    if [[ "${presence}" == present ]]; then
        log "Reusing the reviewed installed notifier pair without recreating Mattermost"
        return 0
    fi
    notifier_root="$(existing_notifier_value THN_DATA_ROOT)"
    existing_notifier_setup_prepare_filestore_plugins_root
    notifier_install_reviewed_pair \
        "${notifier_root}/release" \
        "$(existing_notifier_value THN_MATTERMOST_PLUGINS_ROOT)" \
        "$(existing_notifier_value THN_MATTERMOST_DATA_ROOT)/plugins" \
        existing_notifier_compose_combined \
        "$(existing_notifier_value THN_MATTERMOST_SERVICE)"
}

existing_notifier_setup_verify_plugin() (
    temporary_dir="$(mktemp -d)"
    trap 'notifier_plugin_cleanup_scratch_root "${temporary_dir}"' EXIT HUP INT TERM
    existing_notifier_installed_target_plugin_is_reviewed \
        "$(existing_notifier_value THN_MATTERMOST_SERVICE)" "${temporary_dir}"
)

existing_notifier_setup_current_smtp_fingerprint() (
    temporary_file="$(mktemp)"
    trap 'rm -f -- "${temporary_file}"' EXIT HUP INT TERM
    existing_notifier_compose_combined run --rm --no-deps -T \
        --entrypoint /threadhub-mailer threadhub-mailer \
        config-fingerprint --json > "${temporary_file}" || return 1
    notifier_config_fingerprint_from_json "${temporary_file}"
)

existing_notifier_setup_require_current_smtp_marker() {
    local marker_file
    local expected
    local actual
    marker_file="$(existing_notifier_value THN_DATA_ROOT)/control/smtp-acceptance.json"
    expected="$(existing_notifier_setup_current_smtp_fingerprint)" || return 20
    "${SUDO_COMMAND[@]}" test -f "${marker_file}" \
        && "${SUDO_COMMAND[@]}" test ! -L "${marker_file}" || return 20
    actual="$("${SUDO_COMMAND[@]}" jq -er '
        if type == "object" and keys == ["accepted_at", "fingerprint"] and
           (.accepted_at | type == "number" and . > 0) and
           (.fingerprint | type == "string" and test("^[a-f0-9]{64}$"))
        then .fingerprint else error("invalid marker") end
    ' "${marker_file}" 2>/dev/null)" || return 20
    [[ "${actual}" == "${expected}" ]] || return 20
}

existing_notifier_setup_activate_allowlist_interactively() (
    [[ -t 0 ]] || {
        existing_notifier_setup_action_required \
            "Run ./deploy/scripts/existing-notifier-setup.sh --resume in an interactive terminal to enter pilot channel IDs"
        return $?
    }
    read -r -s -p 'Comma-separated pilot Mattermost channel IDs: ' channel_ids
    printf '\n' >&2
    notifier_validate_mode_channels allowlist "${channel_ids}" \
        || die "Pilot channel allowlist is invalid"
    status_file="$(mktemp)"
    trap 'rm -f -- "${status_file}"' EXIT HUP INT TERM
    existing_notifier_compose_combined exec -T threadhub-mailer \
        /threadhub-mailer status --json > "${status_file}" || return 1
    state_file="$(existing_notifier_value THN_DATA_ROOT)/control/state.json"
    notifier_activate_state "${state_file}" allowlist "${channel_ids}" "${status_file}" \
        || die "Allowlist activation requires an empty pre-activation queue"
    channel_ids=""
    unset channel_ids
    log "Existing Mattermost notifier pilot allowlist is active"
)

existing_notifier_setup_run() (
    non_interactive="$1"
    setup_lock="${EXISTING_NOTIFIER_ENV_FILE}.setup.lock"

    existing_notifier_setup_capture_config_identity \
        || die "Existing notifier configuration identity could not be captured"
    if ! mkdir "${setup_lock}" 2>/dev/null; then
        existing_notifier_setup_action_required \
            "Another setup or a stale setup lock exists at ${setup_lock}"
        return $?
    fi
    chmod 0700 "${setup_lock}"
    trap 'rmdir -- "${setup_lock}" >/dev/null 2>&1 || true' EXIT HUP INT TERM

    for phase in \
        existing_notifier_setup_preflight \
        existing_notifier_setup_prepare_runtime \
        existing_notifier_setup_record_rollback_capture \
        existing_notifier_setup_write_disabled_control \
        existing_notifier_setup_build_artifacts \
        existing_notifier_setup_write_override \
        existing_notifier_setup_start_mailer \
        existing_notifier_setup_verify_mailer \
        existing_notifier_setup_install_plugin \
        existing_notifier_setup_verify_plugin; do
        log "Existing notifier setup phase: ${phase#existing_notifier_setup_}"
        existing_notifier_setup_recheck_config \
            || die "Existing notifier configuration changed during setup"
        "${phase}" || return $?
    done
    existing_notifier_setup_recheck_config \
        || die "Existing notifier configuration changed during setup"
    if ! existing_notifier_setup_require_current_smtp_marker; then
        existing_notifier_setup_action_required \
            "Run ./deploy/scripts/existing-notifier-smtp-test.sh in an interactive terminal, then rerun ./deploy/scripts/existing-notifier-setup.sh --resume"
        return $?
    fi
    if [[ "${non_interactive}" == true ]]; then
        existing_notifier_setup_action_required \
            "Run ./deploy/scripts/existing-notifier-setup.sh --resume in an interactive terminal to activate a pilot allowlist"
        return $?
    fi
    existing_notifier_setup_activate_allowlist_interactively
)

existing_notifier_setup_prompt_value() {
    local variable_name="$1"
    local label="$2"
    local default_value="${3:-}"
    local secret="${4:-false}"
    local value
    local prompt="${label}"

    [[ -z "${default_value}" ]] || prompt+=" [${default_value}]"
    prompt+=': '
    if [[ "${secret}" == true ]]; then
        read -r -s -p "${prompt}" value
        printf '\n' >&2
    else
        read -r -p "${prompt}" value
    fi
    value="${value:-${default_value}}"
    [[ -n "${value}" && "${value}" != *$'\r'* && "${value}" != *$'\n'* \
        && "${value}" != *"'"* ]] \
        || die "${label} is invalid"
    printf -v "${variable_name}" '%s' "${value}"
}

existing_notifier_setup_write_env_value() {
    local key="$1"
    local value="$2"

    [[ "${key}" =~ ^THN_[A-Z0-9_]+$ \
        && -n "${value}" \
        && "${value}" != *$'\r'* \
        && "${value}" != *$'\n'* \
        && "${value}" != *"'"* ]] || return 1
    printf "%s='%s'\n" "${key}" "${value}"
}

existing_notifier_setup_configure_interactively() (
    local project_dir compose_file compose_env service selected_plugins_root data_root
    local notifier_root domain smtp_server smtp_ca_file smtp_username smtp_password
    local smtp_from smtp_reply feedback rate hmac temporary_env

    [[ -t 0 ]] || {
        existing_notifier_setup_action_required \
            "A terminal is required; run ./deploy/scripts/existing-notifier-setup.sh --configure-only"
        return $?
    }
    runtime_env_require_no_recovery "${EXISTING_NOTIFIER_ENV_FILE}" || return $?
    runtime_env_require_atomic_tools || return $?
    existing_notifier_setup_prompt_value project_dir 'Existing Compose project directory'
    existing_notifier_setup_prompt_value compose_file 'Existing Compose file'
    existing_notifier_setup_prompt_value compose_env 'Existing Compose environment file'
    existing_notifier_setup_prompt_value service 'Mattermost service name' mattermost
    existing_notifier_setup_prompt_value selected_plugins_root 'Mattermost plugins host root'
    existing_notifier_setup_prompt_value data_root 'Mattermost data host root'
    existing_notifier_setup_prompt_value notifier_root 'Notifier data root' /srv/threadhub-notifier
    existing_notifier_setup_prompt_value domain 'Mattermost HTTPS domain'
    existing_notifier_setup_prompt_value smtp_server 'OCI SMTP server'
    existing_notifier_setup_prompt_value smtp_ca_file 'SMTP CA bundle' /etc/ssl/certs/ca-certificates.crt
    existing_notifier_setup_prompt_value smtp_username 'OCI SMTP username'
    existing_notifier_setup_prompt_value smtp_password 'OCI SMTP password' '' true
    existing_notifier_setup_prompt_value smtp_from 'Approved sender address'
    existing_notifier_setup_prompt_value smtp_reply 'Reply-to address'
    existing_notifier_setup_prompt_value feedback 'Sender display name' ThreadHub
    existing_notifier_setup_prompt_value rate 'Maximum emails per minute' 10
    hmac="$(openssl rand -hex 32)"
    temporary_env="$(mktemp "${EXISTING_NOTIFIER_ENV_FILE}.tmp.XXXXXX")"
    trap 'rm -f -- "${temporary_env}"' EXIT HUP INT TERM
    umask 077
    {
        existing_notifier_setup_write_env_value THN_COMPOSE_PROJECT_DIR "${project_dir}"
        existing_notifier_setup_write_env_value THN_COMPOSE_FILE "${compose_file}"
        existing_notifier_setup_write_env_value THN_COMPOSE_ENV_FILE "${compose_env}"
        existing_notifier_setup_write_env_value THN_MATTERMOST_SERVICE "${service}"
        existing_notifier_setup_write_env_value THN_MATTERMOST_PLUGINS_ROOT "${selected_plugins_root}"
        existing_notifier_setup_write_env_value THN_MATTERMOST_DATA_ROOT "${data_root}"
        existing_notifier_setup_write_env_value THN_DATA_ROOT "${notifier_root}"
        existing_notifier_setup_write_env_value THN_DOMAIN "${domain}"
        existing_notifier_setup_write_env_value THN_SMTP_SERVER "${smtp_server}"
        existing_notifier_setup_write_env_value THN_SMTP_PORT 587
        existing_notifier_setup_write_env_value THN_SMTP_CA_FILE "${smtp_ca_file}"
        existing_notifier_setup_write_env_value THN_SMTP_USERNAME "${smtp_username}"
        existing_notifier_setup_write_env_value THN_SMTP_PASSWORD "${smtp_password}"
        existing_notifier_setup_write_env_value THN_SMTP_FROM_ADDRESS "${smtp_from}"
        existing_notifier_setup_write_env_value THN_SMTP_REPLY_TO_ADDRESS "${smtp_reply}"
        existing_notifier_setup_write_env_value THN_SMTP_FEEDBACK_NAME "${feedback}"
        existing_notifier_setup_write_env_value THN_HMAC_SECRET "${hmac}"
        existing_notifier_setup_write_env_value THN_RATE_PER_MINUTE "${rate}"
    } > "${temporary_env}"
    chmod 0600 "${temporary_env}"
    EXISTING_NOTIFIER_ENV_FILE="${temporary_env}" existing_notifier_validate_config
    if ! runtime_env_publish_no_clobber "${temporary_env}" "${EXISTING_NOTIFIER_ENV_FILE}"; then
        existing_notifier_setup_action_required \
            "Existing notifier configuration appeared and was not overwritten"
        return $?
    fi
    smtp_password=""
    hmac=""
    unset smtp_password hmac
    log "Created protected existing notifier configuration with mode 0600"
)

existing_notifier_setup_dispatch() {
    local configure_only=false
    local non_interactive=false

    while (($# > 0)); do
        case "$1" in
            --resume) ;;
            --configure-only) configure_only=true ;;
            --non-interactive) non_interactive=true ;;
            *) die "Usage: $0 [--configure-only] [--resume] [--non-interactive]" ;;
        esac
        shift
    done

    if [[ ! -e "${EXISTING_NOTIFIER_ENV_FILE}" && ! -L "${EXISTING_NOTIFIER_ENV_FILE}" ]]; then
        if [[ "${non_interactive}" == true ]]; then
            printf '[ACTION REQUIRED] Protected existing notifier configuration is missing.\n' >&2
            printf 'Run: ./deploy/scripts/existing-notifier-setup.sh --configure-only\n' >&2
            printf 'Then rerun: ./deploy/scripts/existing-notifier-setup.sh --resume --non-interactive\n' >&2
            return 20
        fi
        existing_notifier_setup_configure_interactively || return $?
    fi
    existing_notifier_setup_validate_config || return $?
    if [[ "${configure_only}" == true ]]; then
        log "Existing notifier configuration is ready; no service was changed"
        return 0
    fi
    existing_notifier_setup_run "${non_interactive}"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    existing_notifier_setup_dispatch "$@"
fi
