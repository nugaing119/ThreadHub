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

existing_notifier_v010_v020_attempt_root() {
    printf '%s\n' "$(existing_notifier_v010_v020_value THN_DATA_ROOT)/migration/${EXISTING_NOTIFIER_V010_V020_ID}"
}

existing_notifier_v010_v020_target_root() {
    printf '%s\n' "$(existing_notifier_v010_v020_value THN_DATA_ROOT)/migration/${EXISTING_NOTIFIER_V010_V020_ID}-target"
}

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

existing_notifier_v010_v020_capture_identity() {
    local path="$1"

    if "${SUDO_COMMAND[@]}" stat -c '%u:%g:%a' "${path}" >/dev/null 2>&1; then
        "${SUDO_COMMAND[@]}" stat -c '%u:%g:%a' "${path}"
    else
        "${SUDO_COMMAND[@]}" stat -f '%u:%g:%Lp' "${path}"
    fi
}

existing_notifier_v010_v020_capture_create_attempt() {
    "${SUDO_COMMAND[@]}" install -d -o root -g root -m 0700 "$1"
}

existing_notifier_v010_v020_capture_record_phase() {
    local attempt_root="$1"
    local phase="$2"
    local temporary_file

    case "${phase}" in
        attempt-created|control-disabled|mailer-stopped|queue-inspected-v1|queue-captured|source-plugin-pair-captured|source-mailer-image-saved|source-release-captured|source-override-captured|source-env-captured|source-control-captured|baseline-captured|complete) ;;
        *) return 2 ;;
    esac
    temporary_file="$(mktemp)" || return 1
    jq -n --arg profile "${EXISTING_NOTIFIER_V010_V020_ID}" --arg phase "${phase}" \
        '{schema:1,profile:$profile,phase:$phase,rollback_disposition:"not_started"}' \
        > "${temporary_file}" || { rm -f -- "${temporary_file}"; return 1; }
    chmod 0600 "${temporary_file}"
    if ! "${SUDO_COMMAND[@]}" install -m 0600 "${temporary_file}" "${attempt_root}/phase.json"; then
        rm -f -- "${temporary_file}"
        return 1
    fi
    rm -f -- "${temporary_file}"
}

existing_notifier_v010_v020_capture_prepare_attempt() {
    local attempt_root="$1"
    local migration_root

    migration_root="$(dirname "${attempt_root}")"
    "${SUDO_COMMAND[@]}" test -d "${migration_root}" \
        && "${SUDO_COMMAND[@]}" test ! -L "${migration_root}" \
        && [[ "$(existing_notifier_v010_v020_capture_identity "${migration_root}")" == 0:0:700 ]] \
        || return 1
    "${SUDO_COMMAND[@]}" test ! -e "${attempt_root}" \
        && "${SUDO_COMMAND[@]}" test ! -L "${attempt_root}" || return 1
    existing_notifier_v010_v020_capture_create_attempt "${attempt_root}"
}

v010_v020_capture_control_is_disabled() {
    local control_file

    control_file="$(existing_notifier_v010_v020_value THN_DATA_ROOT)/control/state.json"
    "${SUDO_COMMAND[@]}" test -f "${control_file}" \
        && "${SUDO_COMMAND[@]}" test ! -L "${control_file}" \
        && [[ "$(existing_notifier_v010_v020_capture_identity "${control_file}")" == 0:3000:640 ]] \
        && "${SUDO_COMMAND[@]}" jq -e '
          type == "object" and
          (keys == ["activated_at","channel_ids","delivery_enabled","enabled","mode"]) and
          .enabled == false and .delivery_enabled == false and
          (.mode == "all_channels" or .mode == "allowlist") and
          (.channel_ids | type == "array") and
          (.activated_at | type == "number" and floor == . and . >= 0)
        ' "${control_file}" >/dev/null 2>&1
}

v010_v020_capture_mailer_is_stopped() {
    local output_file

    output_file="$(mktemp)" || return 1
    chmod 0600 "${output_file}"
    if ! existing_notifier_v010_v020_compose_combined ps -q threadhub-mailer > "${output_file}"; then
        rm -f -- "${output_file}"
        return 1
    fi
    if [[ -s "${output_file}" ]]; then
        rm -f -- "${output_file}"
        return 1
    fi
    rm -f -- "${output_file}"
}

existing_notifier_v010_v020_queue_inspection_is_valid() {
    local inspection_file="$1"

    [[ -f "${inspection_file}" && ! -L "${inspection_file}" ]] || return 1
    jq -e '
      type == "object" and
      (keys == ["cancelled","events","failed","nonces","pending","schema_version","sending","sent"]) and
      ([.schema_version,.events,.nonces,.pending,.sending,.sent,.failed,.cancelled] |
        all(type == "number" and floor == . and . >= 0)) and
      (.schema_version == 1 or .schema_version == 2)
    ' "${inspection_file}" >/dev/null 2>&1
}

existing_notifier_v010_v020_run_queue_inspector() {
    local output_file="$1"
    local source_mailer

    source_mailer="$(existing_notifier_v010_v020_value THN_DATA_ROOT)/mailer"
    "${DOCKER_COMMAND[@]}" run --rm --pull never --network none --read-only \
        --cap-drop ALL --security-opt no-new-privileges --user 65532:65532 \
        --mount "type=bind,src=${source_mailer},dst=/var/lib/threadhub-notifier,readonly" \
        "threadhub/notifier-mailer:${EXISTING_NOTIFIER_V020_VERSION}" \
        queue-inspect --json > "${output_file}"
}

v010_v020_capture_inspect_queue_v1() {
    local attempt_root="$1"
    local temporary_dir
    local inspection_file
    local destination

    temporary_dir="$(mktemp -d)" || return 1
    chmod 0700 "${temporary_dir}"
    inspection_file="${temporary_dir}/queue-inspection.json"
    destination="${attempt_root}/queue-inspection.json"
    if ! existing_notifier_v010_v020_run_queue_inspector "${inspection_file}"; then
        rm -rf -- "${temporary_dir}"
        return 1
    fi
    chmod 0600 "${inspection_file}"
    if ! existing_notifier_v010_v020_queue_inspection_is_valid "${inspection_file}" \
        || [[ "$(jq -er '.schema_version' "${inspection_file}")" != 1 ]] \
        || "${SUDO_COMMAND[@]}" test -e "${destination}" \
        || "${SUDO_COMMAND[@]}" test -L "${destination}" \
        || ! "${SUDO_COMMAND[@]}" install -m 0600 "${inspection_file}" "${destination}"; then
        rm -rf -- "${temporary_dir}"
        return 1
    fi
    rm -rf -- "${temporary_dir}"
}

v010_v020_capture_queue() {
    local attempt_root="$1"
    local source_mailer
    local destination
    local entries_file
    local path
    local name
    local failed=0

    source_mailer="$(existing_notifier_v010_v020_value THN_DATA_ROOT)/mailer"
    destination="${attempt_root}/source/mailer"
    "${SUDO_COMMAND[@]}" test -d "${source_mailer}" \
        && "${SUDO_COMMAND[@]}" test ! -L "${source_mailer}" \
        && [[ "$(existing_notifier_v010_v020_capture_identity "${source_mailer}")" == 65532:65532:700 ]] \
        || return 1
    "${SUDO_COMMAND[@]}" test ! -e "${destination}" \
        && "${SUDO_COMMAND[@]}" test ! -L "${destination}" || return 1
    entries_file="$(mktemp)" || return 1
    chmod 0600 "${entries_file}"
    "${SUDO_COMMAND[@]}" find "${source_mailer}" -mindepth 1 -maxdepth 1 -print > "${entries_file}" || {
        rm -f -- "${entries_file}"
        return 1
    }
    while IFS= read -r path; do
        name="${path##*/}"
        case "${name}" in queue.db|queue.db-wal|queue.db-shm) ;; *) failed=1; break ;; esac
        "${SUDO_COMMAND[@]}" test -f "${path}" \
            && "${SUDO_COMMAND[@]}" test ! -L "${path}" \
            && [[ "$(existing_notifier_v010_v020_capture_identity "${path}")" == 65532:65532:600 ]] \
            || { failed=1; break; }
    done < "${entries_file}"
    if (( failed != 0 )); then
        rm -f -- "${entries_file}"
        return 1
    fi
    grep -Fx "${source_mailer}/queue.db" "${entries_file}" >/dev/null || {
        rm -f -- "${entries_file}"
        return 1
    }
    "${SUDO_COMMAND[@]}" install -d -m 0700 "${destination}" || {
        rm -f -- "${entries_file}"
        return 1
    }
    while IFS= read -r path; do
        name="${path##*/}"
        if ! "${SUDO_COMMAND[@]}" install -m 0600 "${path}" "${destination}/${name}" \
            || ! "${SUDO_COMMAND[@]}" cmp -s "${path}" "${destination}/${name}"; then
            failed=1
            break
        fi
    done < "${entries_file}"
    rm -f -- "${entries_file}"
    (( failed == 0 ))
}

existing_notifier_v010_v020_capture_copy_file() {
    local source_file="$1"
    local destination="$2"

    "${SUDO_COMMAND[@]}" test -f "${source_file}" \
        && "${SUDO_COMMAND[@]}" test ! -L "${source_file}" \
        && "${SUDO_COMMAND[@]}" test ! -e "${destination}" \
        && "${SUDO_COMMAND[@]}" test ! -L "${destination}" \
        && "${SUDO_COMMAND[@]}" cp -p "${source_file}" "${destination}" \
        && "${SUDO_COMMAND[@]}" cmp -s "${source_file}" "${destination}"
}

existing_notifier_v010_v020_capture_copy_tree() {
    local source_root="$1"
    local destination="$2"
    local symlinks

    "${SUDO_COMMAND[@]}" test -d "${source_root}" \
        && "${SUDO_COMMAND[@]}" test ! -L "${source_root}" \
        && "${SUDO_COMMAND[@]}" test ! -e "${destination}" \
        && "${SUDO_COMMAND[@]}" test ! -L "${destination}" || return 1
    symlinks="$("${SUDO_COMMAND[@]}" find "${source_root}" -type l -print -quit)" || return 1
    [[ -z "${symlinks}" ]] || return 1
    "${SUDO_COMMAND[@]}" cp -a "${source_root}" "${destination}"
}

v010_v020_capture_source_plugin_pair() {
    local attempt_root="$1"
    local plugin_id=com.threadhub.channel-email-notifier
    local runtime_root
    local bundle_path
    local scratch_root
    local captured_runtime
    local destination_runtime
    local destination_bundle
    local metadata
    local version
    local sha
    local extra

    runtime_root="$(existing_notifier_v010_v020_value THN_MATTERMOST_PLUGINS_ROOT)/${plugin_id}"
    bundle_path="$(existing_notifier_v010_v020_value THN_MATTERMOST_DATA_ROOT)/plugins/${plugin_id}.tar.gz"
    destination_runtime="${attempt_root}/source/plugin-runtime"
    destination_bundle="${attempt_root}/source/plugin-bundle.tar.gz"
    scratch_root="$(mktemp -d)" || return 1
    chmod 0700 "${scratch_root}"
    captured_runtime="${scratch_root}/runtime"
    if [[ -z "${EXISTING_NOTIFIER_V010_RELEASE_BUNDLE_SHA:-}" ]]; then
        existing_notifier_v010_v020_read_source_release \
            "$(existing_notifier_v010_v020_value THN_DATA_ROOT)/release/release.env" \
            "${scratch_root}" || { rm -rf -- "${scratch_root}"; return 1; }
    fi
    metadata="$(notifier_plugin_capture_pair "${runtime_root}" "${bundle_path}" "${plugin_id}" "${captured_runtime}" "${scratch_root}")" \
        || { rm -rf -- "${scratch_root}"; return 1; }
    extra=""
    IFS=$'\t' read -r version sha extra <<< "${metadata}"
    if [[ "${version}" != "${EXISTING_NOTIFIER_V010_VERSION}" \
        || "${sha}" != "${EXISTING_NOTIFIER_V010_RELEASE_BUNDLE_SHA}" \
        || -n "${extra}" ]] \
        || ! existing_notifier_v010_v020_capture_copy_tree "${captured_runtime}" "${destination_runtime}" \
        || ! existing_notifier_v010_v020_capture_copy_file "${bundle_path}" "${destination_bundle}"; then
        notifier_plugin_cleanup_scratch_root "${scratch_root}"
        return 1
    fi
    notifier_plugin_cleanup_scratch_root "${scratch_root}"
}

existing_notifier_v010_v020_save_source_image() {
    local output_file="$1"
    local image="threadhub/notifier-mailer:${EXISTING_NOTIFIER_V010_VERSION}"
    local image_id

    image_id="$("${DOCKER_COMMAND[@]}" image inspect --format '{{.Id}}' "${image}")" || return 1
    [[ "${image_id}" == "${EXISTING_NOTIFIER_V010_RELEASE_MAILER_IMAGE_ID:-}" ]] || return 1
    "${DOCKER_COMMAND[@]}" image save --output "${output_file}" "${image}"
}

v010_v020_capture_source_mailer_image() {
    local attempt_root="$1"
    local temporary_dir
    local image_archive
    local image_id_file
    local archive_size

    temporary_dir="$(mktemp -d)" || return 1
    chmod 0700 "${temporary_dir}"
    image_archive="${temporary_dir}/mailer-image.tar"
    image_id_file="${temporary_dir}/mailer-image-id"
    if [[ -z "${EXISTING_NOTIFIER_V010_RELEASE_MAILER_IMAGE_ID:-}" ]]; then
        existing_notifier_v010_v020_read_source_release \
            "$(existing_notifier_v010_v020_value THN_DATA_ROOT)/release/release.env" \
            "${temporary_dir}" || { rm -rf -- "${temporary_dir}"; return 1; }
    fi
    if ! existing_notifier_v010_v020_save_source_image "${image_archive}"; then
        rm -rf -- "${temporary_dir}"
        return 1
    fi
    chmod 0600 "${image_archive}"
    archive_size="$(wc -c < "${image_archive}" | tr -d '[:space:]')"
    if [[ ! "${archive_size}" =~ ^[0-9]+$ ]] || ((archive_size < 1024)) \
        || ! tar -tf "${image_archive}" >/dev/null 2>&1; then
        rm -rf -- "${temporary_dir}"
        return 1
    fi
    printf '%s\n' "${EXISTING_NOTIFIER_V010_RELEASE_MAILER_IMAGE_ID}" > "${image_id_file}"
    chmod 0600 "${image_id_file}"
    if ! existing_notifier_v010_v020_capture_copy_file "${image_archive}" "${attempt_root}/source/mailer-image.tar" \
        || ! existing_notifier_v010_v020_capture_copy_file "${image_id_file}" "${attempt_root}/source/mailer-image-id"; then
        rm -rf -- "${temporary_dir}"
        return 1
    fi
    rm -rf -- "${temporary_dir}"
}

v010_v020_capture_source_release() {
    existing_notifier_v010_v020_capture_copy_tree \
        "$(existing_notifier_v010_v020_value THN_DATA_ROOT)/release" \
        "$1/source/release"
}

v010_v020_capture_source_override() {
    existing_notifier_v010_v020_capture_copy_file \
        "$(existing_notifier_v010_v020_value THN_DATA_ROOT)/compose.override.yml" \
        "$1/source/compose.override.yml"
}

v010_v020_capture_source_env() {
    existing_notifier_v010_v020_capture_copy_file \
        "${EXISTING_NOTIFIER_V010_V020_ENV_FILE}" \
        "$1/source/existing-notifier.env"
}

v010_v020_capture_source_control() {
    existing_notifier_v010_v020_capture_copy_file \
        "$(existing_notifier_v010_v020_value THN_DATA_ROOT)/control/state.json" \
        "$1/source/control-state.json"
}
existing_notifier_v010_v020_baseline_is_valid() {
    local baseline_file="$1"

    [[ "$#" -eq 1 && -f "${baseline_file}" && ! -L "${baseline_file}" ]] || return 2
    jq -e '
      type == "object" and
      (keys == ["active_users","channel_members","channels","files","inactive_users","posts","teams"]) and
      ([.teams,.channels,.channel_members,.active_users,.inactive_users,.posts,.files] |
        all(type == "number" and floor == . and . >= 0))
    ' "${baseline_file}" >/dev/null 2>&1
}

existing_notifier_v010_v020_capture_baseline() {
    local destination="$1"
    local postgres_service="${EXISTING_NOTIFIER_V010_V020_POSTGRES_SERVICE:-}"
    local temporary_dir
    local baseline_file
    local query

    [[ "$#" -eq 1 && "${destination}" == /* && "${destination}" != / \
        && "${destination}" != *$'\n'* && "${destination}" != *$'\r'* ]] || return 2
    [[ "${postgres_service}" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || return 1
    temporary_dir="$(mktemp -d)" || return 1
    chmod 0700 "${temporary_dir}"
    baseline_file="${temporary_dir}/baseline.json"
    query="SELECT json_build_object('teams',(SELECT count(*) FROM teams),'channels',(SELECT count(*) FROM channels),'channel_members',(SELECT count(*) FROM channelmembers),'active_users',(SELECT count(*) FROM users WHERE deleteat = 0 AND username <> 'system-bot'),'inactive_users',(SELECT count(*) FROM users WHERE deleteat <> 0 AND username <> 'system-bot'),'posts',(SELECT count(*) FROM posts),'files',(SELECT count(*) FROM fileinfo));"
    # POSTGRES_USER and POSTGRES_DB are intentionally expanded by the container shell.
    # shellcheck disable=SC2016
    if ! existing_notifier_v010_v020_compose_combined exec -T "${postgres_service}" \
        sh -ceu 'exec psql --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" --tuples-only --no-align --command "$1"' sh "${query}" \
        > "${baseline_file}"; then
        rm -rf -- "${temporary_dir}"
        return 1
    fi
    chmod 0600 "${baseline_file}"
    if ! existing_notifier_v010_v020_baseline_is_valid "${baseline_file}" \
        || "${SUDO_COMMAND[@]}" test -e "${destination}" \
        || "${SUDO_COMMAND[@]}" test -L "${destination}" \
        || ! "${SUDO_COMMAND[@]}" install -m 0600 "${baseline_file}" "${destination}"; then
        rm -rf -- "${temporary_dir}"
        return 1
    fi
    rm -rf -- "${temporary_dir}"
}

v010_v020_capture_baseline() {
    [[ "$#" -eq 1 ]] || return 2
    existing_notifier_v010_v020_capture_baseline "$1/baseline.json"
}
existing_notifier_v010_v020_capture_hash() {
    local path="$1"

    if command -v sha256sum >/dev/null 2>&1; then
        "${SUDO_COMMAND[@]}" sha256sum "${path}" | awk '{print $1}'
    else
        "${SUDO_COMMAND[@]}" shasum -a 256 "${path}" | awk '{print $1}'
    fi
}

existing_notifier_v010_v020_build_manifest() {
    local attempt_root="$1"
    local output_file="$2"
    local temporary_dir
    local paths_file
    local entries_file
    local path
    local relative
    local identity
    local digest

    temporary_dir="$(mktemp -d)" || return 1
    chmod 0700 "${temporary_dir}"
    paths_file="${temporary_dir}/paths"
    entries_file="${temporary_dir}/entries.jsonl"
    "${SUDO_COMMAND[@]}" find "${attempt_root}" -mindepth 1 -print > "${paths_file}" || {
        rm -rf -- "${temporary_dir}"; return 1;
    }
    LC_ALL=C sort -o "${paths_file}" "${paths_file}"
    : > "${entries_file}"
    chmod 0600 "${paths_file}" "${entries_file}"
    while IFS= read -r path; do
        relative="${path#"${attempt_root}/"}"
        [[ -n "${relative}" && "${relative}" != "${path}" ]] || { rm -rf -- "${temporary_dir}"; return 1; }
        case "${relative}" in manifest.json|phase.json) continue ;; esac
        "${SUDO_COMMAND[@]}" test ! -L "${path}" || { rm -rf -- "${temporary_dir}"; return 1; }
        identity="$(existing_notifier_v010_v020_capture_identity "${path}")" || { rm -rf -- "${temporary_dir}"; return 1; }
        if "${SUDO_COMMAND[@]}" test -f "${path}"; then
            digest="$(existing_notifier_v010_v020_capture_hash "${path}")" || { rm -rf -- "${temporary_dir}"; return 1; }
            jq -cn --arg path "${relative}" --arg identity "${identity}" --arg digest "${digest}" \
                '{path:$path,type:"file",identity:$identity,sha256:$digest}' >> "${entries_file}"
        elif "${SUDO_COMMAND[@]}" test -d "${path}"; then
            jq -cn --arg path "${relative}" --arg identity "${identity}" \
                '{path:$path,type:"directory",identity:$identity,sha256:null}' >> "${entries_file}"
        else
            rm -rf -- "${temporary_dir}"
            return 1
        fi
    done < "${paths_file}"
    jq -s --arg profile "${EXISTING_NOTIFIER_V010_V020_ID}" \
        '{schema:1,profile:$profile,entries:.}' "${entries_file}" > "${output_file}" || {
        rm -rf -- "${temporary_dir}"; return 1;
    }
    chmod 0600 "${output_file}"
    rm -rf -- "${temporary_dir}"
}

v010_v020_capture_verify_evidence() {
    local attempt_root="$1"
    local temporary_dir
    local manifest
    local verification
    local installed_copy
    local required
    local inspection_copy
    local baseline_copy

    for required in \
        queue-inspection.json baseline.json \
        source/mailer/queue.db source/plugin-runtime source/plugin-bundle.tar.gz \
        source/mailer-image.tar source/mailer-image-id source/release \
        source/compose.override.yml source/existing-notifier.env source/control-state.json; do
        "${SUDO_COMMAND[@]}" test -e "${attempt_root}/${required}" || return 1
        "${SUDO_COMMAND[@]}" test ! -L "${attempt_root}/${required}" || return 1
    done
    temporary_dir="$(mktemp -d)" || return 1
    chmod 0700 "${temporary_dir}"
    inspection_copy="${temporary_dir}/queue-inspection.json"
    baseline_copy="${temporary_dir}/baseline.json"
    if ! "${SUDO_COMMAND[@]}" cat "${attempt_root}/queue-inspection.json" > "${inspection_copy}" \
        || ! "${SUDO_COMMAND[@]}" cat "${attempt_root}/baseline.json" > "${baseline_copy}"; then
        rm -rf -- "${temporary_dir}"
        return 1
    fi
    chmod 0600 "${inspection_copy}" "${baseline_copy}"
    if ! existing_notifier_v010_v020_queue_inspection_is_valid "${inspection_copy}" \
        || [[ "$(jq -er '.schema_version' "${inspection_copy}")" != 1 ]] \
        || ! existing_notifier_v010_v020_baseline_is_valid "${baseline_copy}" \
        || ! "${SUDO_COMMAND[@]}" tar -tf "${attempt_root}/source/mailer-image.tar" >/dev/null 2>&1 \
        || ! "${SUDO_COMMAND[@]}" grep -Eq '^sha256:[a-f0-9]{64}$' "${attempt_root}/source/mailer-image-id"; then
        rm -rf -- "${temporary_dir}"
        return 1
    fi
    manifest="${temporary_dir}/manifest.json"
    verification="${temporary_dir}/verification.json"
    installed_copy="${temporary_dir}/installed.json"
    if ! existing_notifier_v010_v020_build_manifest "${attempt_root}" "${manifest}" \
        || ! existing_notifier_v010_v020_capture_copy_file "${manifest}" "${attempt_root}/manifest.json" \
        || ! existing_notifier_v010_v020_build_manifest "${attempt_root}" "${verification}" \
        || ! "${SUDO_COMMAND[@]}" cat "${attempt_root}/manifest.json" > "${installed_copy}" \
        || ! cmp -s "${installed_copy}" "${verification}"; then
        rm -rf -- "${temporary_dir}"
        return 1
    fi
    if ! existing_notifier_v010_v020_capture_record_phase "${attempt_root}" complete; then
        rm -rf -- "${temporary_dir}"
        return 1
    fi
    rm -rf -- "${temporary_dir}"
}

existing_notifier_v010_v020_source_capture_is_complete() {
    local attempt_root="$1"
    local expected_root
    local temporary_dir
    local manifest_copy
    local phase_copy
    local entries_file
    local relative
    local object_type
    local expected_identity
    local expected_digest
    local path

    [[ "$#" -eq 1 ]] || return 2
    expected_root="$(existing_notifier_v010_v020_value THN_DATA_ROOT)/migration/${EXISTING_NOTIFIER_V010_V020_ID}"
    [[ "${attempt_root}" == "${expected_root}" ]] || return 1
    "${SUDO_COMMAND[@]}" test -d "${attempt_root}" \
        && "${SUDO_COMMAND[@]}" test ! -L "${attempt_root}" \
        && [[ "$(existing_notifier_v010_v020_capture_identity "${attempt_root}")" == 0:0:700 ]] \
        || return 1
    for path in manifest.json phase.json queue-inspection.json baseline.json; do
        "${SUDO_COMMAND[@]}" test -f "${attempt_root}/${path}" \
            && "${SUDO_COMMAND[@]}" test ! -L "${attempt_root}/${path}" || return 1
    done
    temporary_dir="$(mktemp -d)" || return 1
    chmod 0700 "${temporary_dir}"
    manifest_copy="${temporary_dir}/manifest.json"
    phase_copy="${temporary_dir}/phase.json"
    entries_file="${temporary_dir}/entries"
    if ! "${SUDO_COMMAND[@]}" cat "${attempt_root}/manifest.json" > "${manifest_copy}" \
        || ! "${SUDO_COMMAND[@]}" cat "${attempt_root}/phase.json" > "${phase_copy}"; then
        rm -rf -- "${temporary_dir}"
        return 1
    fi
    chmod 0600 "${manifest_copy}" "${phase_copy}"
    if ! jq -e --arg profile "${EXISTING_NOTIFIER_V010_V020_ID}" '
          type == "object" and keys == ["entries","profile","schema"] and
          .schema == 1 and .profile == $profile and
          (.entries | type == "array" and length > 0) and
          (.entries | all(
            type == "object" and keys == ["identity","path","sha256","type"] and
            (.path | type == "string" and length > 0) and
            (.identity | type == "string" and test("^[0-9]+:[0-9]+:[0-7]{3,4}$")) and
            ((.type == "file" and (.sha256 | type == "string" and test("^[a-f0-9]{64}$"))) or
             (.type == "directory" and .sha256 == null))
          ))
        ' "${manifest_copy}" >/dev/null \
        || ! jq -e --arg profile "${EXISTING_NOTIFIER_V010_V020_ID}" '
          type == "object" and
          keys == ["phase","profile","rollback_disposition","schema"] and
          .schema == 1 and .profile == $profile and .phase == "complete" and
          .rollback_disposition == "not_started"
        ' "${phase_copy}" >/dev/null \
        || ! jq -r '.entries[] | [.path,.type,.identity,(.sha256 // "-")] | @tsv' \
            "${manifest_copy}" > "${entries_file}"; then
        rm -rf -- "${temporary_dir}"
        return 1
    fi
    while IFS=$'\t' read -r relative object_type expected_identity expected_digest; do
        [[ -n "${relative}" && "${relative}" != /* && "${relative}" != *$'\n'* \
            && "${relative}" != *$'\r'* && "/${relative}/" != *'/../'* \
            && "/${relative}/" != *'/./'* ]] || { rm -rf -- "${temporary_dir}"; return 1; }
        path="${attempt_root}/${relative}"
        "${SUDO_COMMAND[@]}" test ! -L "${path}" \
            && [[ "$(existing_notifier_v010_v020_capture_identity "${path}")" == "${expected_identity}" ]] \
            || { rm -rf -- "${temporary_dir}"; return 1; }
        if [[ "${object_type}" == file ]]; then
            "${SUDO_COMMAND[@]}" test -f "${path}" \
                && [[ "$(existing_notifier_v010_v020_capture_hash "${path}")" == "${expected_digest}" ]] \
                || { rm -rf -- "${temporary_dir}"; return 1; }
        elif [[ "${object_type}" == directory ]]; then
            "${SUDO_COMMAND[@]}" test -d "${path}" \
                || { rm -rf -- "${temporary_dir}"; return 1; }
        else
            rm -rf -- "${temporary_dir}"
            return 1
        fi
    done < "${entries_file}"
    rm -rf -- "${temporary_dir}"
}

existing_notifier_v010_v020_capture_evidence() {
    local attempt_root="$1"
    local expected_root

    [[ "$#" -eq 1 ]] || return 2
    expected_root="$(existing_notifier_v010_v020_value THN_DATA_ROOT)/migration/${EXISTING_NOTIFIER_V010_V020_ID}"
    [[ "${attempt_root}" == "${expected_root}" ]] || return 1
    existing_notifier_v010_v020_capture_prepare_attempt "${attempt_root}" || return 1
    existing_notifier_v010_v020_capture_record_phase "${attempt_root}" attempt-created || return 1
    v010_v020_capture_control_is_disabled "${attempt_root}" || return 1
    existing_notifier_v010_v020_capture_record_phase "${attempt_root}" control-disabled || return 1
    v010_v020_capture_mailer_is_stopped "${attempt_root}" || return 1
    existing_notifier_v010_v020_capture_record_phase "${attempt_root}" mailer-stopped || return 1
    v010_v020_capture_inspect_queue_v1 "${attempt_root}" || return 1
    existing_notifier_v010_v020_capture_record_phase "${attempt_root}" queue-inspected-v1 || return 1
    v010_v020_capture_queue "${attempt_root}" || return 1
    existing_notifier_v010_v020_capture_record_phase "${attempt_root}" queue-captured || return 1
    v010_v020_capture_source_plugin_pair "${attempt_root}" || return 1
    existing_notifier_v010_v020_capture_record_phase "${attempt_root}" source-plugin-pair-captured || return 1
    v010_v020_capture_source_mailer_image "${attempt_root}" || return 1
    existing_notifier_v010_v020_capture_record_phase "${attempt_root}" source-mailer-image-saved || return 1
    v010_v020_capture_source_release "${attempt_root}" || return 1
    existing_notifier_v010_v020_capture_record_phase "${attempt_root}" source-release-captured || return 1
    v010_v020_capture_source_override "${attempt_root}" || return 1
    existing_notifier_v010_v020_capture_record_phase "${attempt_root}" source-override-captured || return 1
    v010_v020_capture_source_env "${attempt_root}" || return 1
    existing_notifier_v010_v020_capture_record_phase "${attempt_root}" source-env-captured || return 1
    v010_v020_capture_source_control "${attempt_root}" || return 1
    existing_notifier_v010_v020_capture_record_phase "${attempt_root}" source-control-captured || return 1
    v010_v020_capture_baseline "${attempt_root}" || return 1
    existing_notifier_v010_v020_capture_record_phase "${attempt_root}" baseline-captured || return 1
    v010_v020_capture_verify_evidence "${attempt_root}"
}

existing_notifier_v010_v020_tx_state_file() {
    [[ "$#" -eq 1 ]] || return 2
    printf '%s\n' "$1/transaction-state.json"
}

existing_notifier_v010_v020_tx_phase_is_valid() {
    case "${1:-}" in
        source_captured|target_release_verified|target_env_published|target_release_published|target_override_published|target_plugin_pair_published|target_mailer_started|target_queue_v2_verified|target_mattermost_recreated|target_pair_verified|after_baseline_captured|baseline_matched|disabled_verified|target_ready|source_recovered|recovery_failed) return 0 ;;
        *) return 1 ;;
    esac
}

existing_notifier_v010_v020_tx_state_is_valid() {
    local state_file="$1"

    [[ "$#" -eq 1 && -f "${state_file}" && ! -L "${state_file}" ]] || return 2
    jq -e --arg transition "${EXISTING_NOTIFIER_V010_V020_ID}" \
        --arg source "${EXISTING_NOTIFIER_V010_VERSION}" \
        --arg target "${EXISTING_NOTIFIER_V020_VERSION}" '
      type == "object" and
      (keys == ["delivery_enabled","phase","schema","source_version","target_version","transition"]) and
      .schema == 1 and .transition == $transition and
      .source_version == $source and .target_version == $target and
      .delivery_enabled == false and (.phase | type == "string")
    ' "${state_file}" >/dev/null 2>&1 || return 1
    existing_notifier_v010_v020_tx_phase_is_valid "$(jq -er '.phase' "${state_file}")"
}

existing_notifier_v010_v020_tx_state_identity_is_private() {
    [[ "$#" -eq 1 ]] || return 2
    [[ "$(existing_notifier_v010_v020_capture_identity "$1")" == 0:0:600 ]]
}

existing_notifier_v010_v020_tx_state_current() {
    local attempt_root="$1"
    local state_file
    local temporary_dir
    local state_copy
    local phase

    [[ "$#" -eq 1 ]] || return 2
    state_file="$(existing_notifier_v010_v020_tx_state_file "${attempt_root}")" || return 1
    "${SUDO_COMMAND[@]}" test -f "${state_file}" \
        && "${SUDO_COMMAND[@]}" test ! -L "${state_file}" \
        && existing_notifier_v010_v020_tx_state_identity_is_private "${state_file}" || return 1
    temporary_dir="$(mktemp -d)" || return 1
    chmod 0700 "${temporary_dir}"
    state_copy="${temporary_dir}/state.json"
    if ! "${SUDO_COMMAND[@]}" cat "${state_file}" > "${state_copy}"; then
        rm -rf -- "${temporary_dir}"
        return 1
    fi
    chmod 0600 "${state_copy}"
    if ! existing_notifier_v010_v020_tx_state_is_valid "${state_copy}"; then
        rm -rf -- "${temporary_dir}"
        return 1
    fi
    phase="$(jq -er '.phase' "${state_copy}")" || {
        rm -rf -- "${temporary_dir}"
        return 1
    }
    rm -rf -- "${temporary_dir}"
    printf '%s\n' "${phase}"
}

existing_notifier_v010_v020_tx_install_private() {
    [[ "$#" -eq 2 ]] || return 2
    "${SUDO_COMMAND[@]}" install -o 0 -g 0 -m 0600 "$1" "$2"
}

existing_notifier_v010_v020_tx_state_write() {
    local attempt_root="$1"
    local phase="$2"
    local expected_previous="${3:-}"
    local state_file
    local candidate
    local temporary_file
    local current

    [[ "$#" -ge 2 && "$#" -le 3 ]] || return 2
    existing_notifier_v010_v020_tx_phase_is_valid "${phase}" || return 2
    state_file="$(existing_notifier_v010_v020_tx_state_file "${attempt_root}")" || return 1
    candidate="${state_file}.next.$$"
    "${SUDO_COMMAND[@]}" test ! -e "${candidate}" \
        && "${SUDO_COMMAND[@]}" test ! -L "${candidate}" || return 1
    if [[ -z "${expected_previous}" ]]; then
        "${SUDO_COMMAND[@]}" test ! -e "${state_file}" \
            && "${SUDO_COMMAND[@]}" test ! -L "${state_file}" || return 1
    else
        current="$(existing_notifier_v010_v020_tx_state_current "${attempt_root}")" || return 1
        [[ "${current}" == "${expected_previous}" ]] || return 1
    fi
    temporary_file="$(mktemp)" || return 1
    jq -n --arg transition "${EXISTING_NOTIFIER_V010_V020_ID}" \
        --arg phase "${phase}" --arg source "${EXISTING_NOTIFIER_V010_VERSION}" \
        --arg target "${EXISTING_NOTIFIER_V020_VERSION}" \
        '{schema:1,transition:$transition,phase:$phase,source_version:$source,target_version:$target,delivery_enabled:false}' \
        > "${temporary_file}" || { rm -f -- "${temporary_file}"; return 1; }
    chmod 0600 "${temporary_file}"
    if ! existing_notifier_v010_v020_tx_install_private "${temporary_file}" "${candidate}" \
        || ! "${SUDO_COMMAND[@]}" mv -f -- "${candidate}" "${state_file}"; then
        "${SUDO_COMMAND[@]}" rm -f -- "${candidate}" >/dev/null 2>&1 || true
        rm -f -- "${temporary_file}"
        return 1
    fi
    rm -f -- "${temporary_file}"
    [[ "$(existing_notifier_v010_v020_tx_state_current "${attempt_root}")" == "${phase}" ]]
}

existing_notifier_v010_v020_tx_create_lock() {
    [[ "$#" -eq 1 ]] || return 2
    "${SUDO_COMMAND[@]}" mkdir -- "$1" \
        && "${SUDO_COMMAND[@]}" chown 0:0 "$1" \
        && "${SUDO_COMMAND[@]}" chmod 0700 "$1"
}

existing_notifier_v010_v020_tx_acquire_lock() {
    local attempt_root="$1"
    local lock_root="${attempt_root}/transaction.lock"

    [[ "$#" -eq 1 ]] || return 2
    "${SUDO_COMMAND[@]}" test ! -e "${lock_root}" \
        && "${SUDO_COMMAND[@]}" test ! -L "${lock_root}" \
        && existing_notifier_v010_v020_tx_create_lock "${lock_root}" \
        && [[ "$(existing_notifier_v010_v020_capture_identity "${lock_root}")" == 0:0:700 ]]
}
