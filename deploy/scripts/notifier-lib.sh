#!/usr/bin/env bash

# Shared notifier installer helpers. Entry-point scripts source common.sh first.

notifier_env_key_state() {
    local file="$1"
    local key
    local present=0
    local occurrences
    local -a keys=(
        NOTIFIER_ENABLED
        NOTIFIER_MODE
        NOTIFIER_CHANNEL_IDS
        NOTIFIER_HMAC_SECRET
        NOTIFIER_RATE_PER_MINUTE
    )

    for key in "${keys[@]}"; do
        occurrences="$(awk -v key="${key}" 'index($0, key "=") == 1 { count++ } END { print count + 0 }' "${file}")"
        if ((occurrences > 1)); then
            printf '%s\n' partial
            return
        fi
        if ((occurrences == 1)); then
            present=$((present + 1))
        fi
    done

    if ((present == 0)); then
        printf '%s\n' none
    elif ((present == ${#keys[@]})); then
        printf '%s\n' complete
    else
        printf '%s\n' partial
    fi
}

notifier_validate_mode_channels() {
    local mode="$1"
    local channel_ids="$2"
    local channel_id
    local seen=','

    [[ "${mode}" == all_channels || "${mode}" == allowlist ]] || return 1
    if [[ -n "${channel_ids}" ]]; then
        [[ "${channel_ids}" =~ ^[a-z0-9]{26}(,[a-z0-9]{26})*$ ]] || return 1
        IFS=',' read -r -a values <<< "${channel_ids}"
        for channel_id in "${values[@]}"; do
            [[ "${channel_id}" =~ ^[a-z0-9]{26}$ ]] || return 1
            [[ "${seen}" != *",${channel_id},"* ]] || return 1
            seen+="${channel_id},"
        done
    fi
    if [[ "${mode}" == all_channels ]]; then
        [[ -z "${channel_ids}" ]]
    else
        [[ -n "${channel_ids}" ]]
    fi
}

notifier_epoch_millis() {
    local value

    value="$(date +%s%3N)"
    if [[ "${value}" =~ ^[0-9]{13}$ ]]; then
        printf '%s\n' "${value}"
    else
        printf '%s000\n' "$(date +%s)"
    fi
}

notifier_install_json_atomically() {
    local source_file="$1"
    local destination="$2"
    local destination_dir
    local staged_file

    destination_dir="$(dirname "${destination}")"
    staged_file="${destination_dir}/.${destination##*/}.tmp.$$"
    "${SUDO_COMMAND[@]}" test -d "${destination_dir}" || return 1
    "${SUDO_COMMAND[@]}" test ! -L "${destination}" || return 1
    "${SUDO_COMMAND[@]}" test ! -e "${staged_file}" || return 1
    if ! "${SUDO_COMMAND[@]}" install \
        -o root -g 3000 -m 0640 "${source_file}" "${staged_file}"; then
        "${SUDO_COMMAND[@]}" rm -f "${staged_file}" >/dev/null 2>&1 || true
        return 1
    fi
    if ! "${SUDO_COMMAND[@]}" mv -fT "${staged_file}" "${destination}"; then
        "${SUDO_COMMAND[@]}" rm -f "${staged_file}" >/dev/null 2>&1 || true
        return 1
    fi
}

notifier_control_json() {
    local enabled="$1"
    local delivery_enabled="$2"
    local mode="$3"
    local channel_ids="$4"
    local activated_at="$5"

    [[ "${enabled}" == true || "${enabled}" == false ]] || return 1
    [[ "${delivery_enabled}" == true || "${delivery_enabled}" == false ]] || return 1
    [[ "${activated_at}" =~ ^[0-9]+$ ]] || return 1
    notifier_validate_mode_channels "${mode}" "${channel_ids}" || return 1
    if [[ "${enabled}" == true ]]; then
        [[ "${delivery_enabled}" == true && "${activated_at}" -gt 0 ]] || return 1
    fi

    jq -cn \
        --argjson enabled "${enabled}" \
        --argjson delivery_enabled "${delivery_enabled}" \
        --arg mode "${mode}" \
        --arg channel_ids "${channel_ids}" \
        --argjson activated_at "${activated_at}" '
        {
          enabled:$enabled,
          delivery_enabled:$delivery_enabled,
          mode:$mode,
          channel_ids:(if $channel_ids == "" then [] else ($channel_ids | split(",")) end),
          activated_at:$activated_at
        }
    '
}

notifier_write_control_state() {
    local destination="$1"
    local enabled="$2"
    local delivery_enabled="$3"
    local mode="$4"
    local channel_ids="$5"
    local activated_at="$6"
    local local_file

    require_command jq
    local_file="$(mktemp)"
    trap 'rm -f "${local_file}"' RETURN
    notifier_control_json \
        "${enabled}" "${delivery_enabled}" "${mode}" "${channel_ids}" "${activated_at}" \
        > "${local_file}" || return 1
    chmod 0600 "${local_file}"
    notifier_install_json_atomically "${local_file}" "${destination}" || return 1
    trap - RETURN
    rm -f "${local_file}"
    notifier_control_is_valid "${destination}"
}

notifier_disabled_control_json() {
    printf '%s\n' '{"enabled":false,"delivery_enabled":false,"mode":"all_channels","channel_ids":[],"activated_at":0}'
}

notifier_read_control_state_or_disabled() {
    local state_file="$1"

    if notifier_control_is_valid "${state_file}"; then
        "${SUDO_COMMAND[@]}" jq -c . "${state_file}"
    else
        notifier_disabled_control_json
    fi
}

notifier_config_fingerprint_from_json() {
    local json_file="$1"

    jq -er '
        if type == "object" and
           (keys == ["config_fingerprint"]) and
           (.config_fingerprint | type == "string" and test("^[a-f0-9]{64}$"))
        then .config_fingerprint
        else error("invalid config fingerprint")
        end
    ' "${json_file}" 2>/dev/null
}

notifier_target_config_fingerprint() {
    local output_file

    require_command jq
    output_file="$(mktemp)"
    trap 'rm -f "${output_file}"' RETURN
    compose run --rm --no-deps -T \
        --entrypoint /threadhub-mailer \
        threadhub-mailer config-fingerprint --json > "${output_file}" \
        || return 1
    notifier_config_fingerprint_from_json "${output_file}"
}

notifier_run_smtp_acceptance() {
    local output_file

    require_command jq
    output_file="$(mktemp)"
    trap 'rm -f "${output_file}"' RETURN
    compose run --rm --no-deps -T \
        --entrypoint /threadhub-mailer \
        threadhub-mailer smtp-test --recipient-stdin > "${output_file}" \
        || return 1
    notifier_config_fingerprint_from_json "${output_file}"
}

notifier_write_smtp_marker() {
    local destination="$1"
    local fingerprint="$2"
    local accepted_at="$3"
    local local_file

    [[ "${fingerprint}" =~ ^[a-f0-9]{64}$ ]] || return 1
    [[ "${accepted_at}" =~ ^[0-9]+$ && "${accepted_at}" -gt 0 ]] || return 1
    local_file="$(mktemp)"
    trap 'rm -f "${local_file}"' RETURN
    jq -cn --arg fingerprint "${fingerprint}" --argjson accepted_at "${accepted_at}" \
        '{fingerprint:$fingerprint,accepted_at:$accepted_at}' > "${local_file}"
    chmod 0600 "${local_file}"
    notifier_install_json_atomically "${local_file}" "${destination}" || return 1
    trap - RETURN
    rm -f "${local_file}"
}

notifier_smtp_marker_is_current() {
    local marker_file="$1"
    local fingerprint

    "${SUDO_COMMAND[@]}" test -f "${marker_file}" || return 1
    "${SUDO_COMMAND[@]}" test ! -L "${marker_file}" || return 1
    fingerprint="$(notifier_target_config_fingerprint)" || return 1
    # The jq variable is intentionally expanded by jq, not by the shell.
    # shellcheck disable=SC2016
    "${SUDO_COMMAND[@]}" jq -e --arg fingerprint "${fingerprint}" '
        type == "object" and
        (keys == ["accepted_at", "fingerprint"]) and
        .fingerprint == $fingerprint and
        (.accepted_at | type == "number" and floor == . and . > 0)
    ' "${marker_file}" >/dev/null 2>&1
}

notifier_require_smtp_handoff() {
    local non_interactive="$1"

    [[ "${non_interactive}" == true ]] || return 0
    printf '[ACTION REQUIRED] Run ./deploy/scripts/notifier-smtp-test.sh in an interactive terminal.\n' >&2
    printf 'Then rerun: ./deploy/scripts/setup-wizard.sh --resume --non-interactive\n' >&2
    return 20
}

notifier_mailer_status_is_valid() {
    local status_file="$1"

    jq -e '
        type == "object" and
        (keys == ["failed", "last_error_class", "last_smtp_code", "last_success_at", "oldest_pending_seconds", "pending", "sending", "sent"]) and
        ([.pending, .sending, .sent, .failed, .oldest_pending_seconds, .last_success_at]
          | all(type == "number" and floor == . and . >= 0)) and
        (.last_error_class | type == "string") and
        (.last_smtp_code | type == "number" and floor == . and . >= 0 and . <= 999)
    ' "${status_file}" >/dev/null 2>&1
}

notifier_activate_state() {
    local state_file="$1"
    local mode="$2"
    local channel_ids="$3"
    local status_file="$4"
    local activated_at

    notifier_mailer_status_is_valid "${status_file}" || return 1
    jq -e '.pending == 0 and .sending == 0' "${status_file}" >/dev/null || return 1
    activated_at="$(notifier_epoch_millis)"
    notifier_write_control_state \
        "${state_file}" true true "${mode}" "${channel_ids}" "${activated_at}"
}

notifier_transition_control_state() {
    local state_file="$1"
    local transition="$2"
    local current
    local mode
    local channel_ids
    local activated_at
    local delivery_enabled

    [[ "${transition}" == drain || "${transition}" == disable ]] || return 1
    current="$(notifier_read_control_state_or_disabled "${state_file}")"
    mode="$(jq -r '.mode' <<< "${current}")"
    channel_ids="$(jq -r '.channel_ids | join(",")' <<< "${current}")"
    activated_at="$(jq -r '.activated_at' <<< "${current}")"
    if [[ "${transition}" == drain ]]; then
        delivery_enabled=true
    else
        delivery_enabled=false
    fi
    notifier_write_control_state \
        "${state_file}" false "${delivery_enabled}" "${mode}" "${channel_ids}" "${activated_at}"
}

notifier_print_control_status() {
    local state_file="$1"
    local current

    current="$(notifier_read_control_state_or_disabled "${state_file}")"
    jq -r '
        "enabled=\(.enabled)",
        "delivery_enabled=\(.delivery_enabled)",
        "mode=\(.mode)",
        "allowlist_count=\(.channel_ids | length)",
        "activated_at=\(.activated_at)"
    ' <<< "${current}"
}

notifier_control_matches_target() {
    local state_file="$1"
    local enabled="$2"
    local mode="$3"
    local channel_ids="$4"
    local expected_ids

    notifier_control_is_valid "${state_file}" || return 1
    expected_ids="$(notifier_control_json false false "${mode}" "${channel_ids}" 0 | jq -c '.channel_ids')" \
        || return 1
    if [[ "${enabled}" == true ]]; then
        # The jq variables are intentionally expanded by jq, not by the shell.
        # shellcheck disable=SC2016
        "${SUDO_COMMAND[@]}" jq -e \
            --arg mode "${mode}" --argjson ids "${expected_ids}" '
            .enabled == true and .delivery_enabled == true and
            .mode == $mode and .channel_ids == $ids and .activated_at > 0
        ' "${state_file}" >/dev/null 2>&1
    else
        # The jq variables are intentionally expanded by jq, not by the shell.
        # shellcheck disable=SC2016
        "${SUDO_COMMAND[@]}" jq -e \
            --arg mode "${mode}" --argjson ids "${expected_ids}" '
            .enabled == false and .delivery_enabled == false and
            .mode == $mode and .channel_ids == $ids
        ' "${state_file}" >/dev/null 2>&1
    fi
}

notifier_plugin_list_query() {
    local plugin_list_file="$1"
    local plugin_id="$2"
    local query="$3"
    local notifier_version="${4:-}"

    [[ -f "${plugin_list_file}" && ! -L "${plugin_list_file}" ]] || return 1
    [[ "${plugin_id}" == com.threadhub.channel-email-notifier ]] || return 1
    [[ "${query}" == exact-active || "${query}" == target-state ]] || return 1
    if [[ "${query}" == exact-active ]]; then
        [[ "${notifier_version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+([+-][A-Za-z0-9.-]+)?$ ]] || return 1
    fi

    jq --slurp --exit-status --raw-output \
        --arg id "${plugin_id}" \
        --arg query "${query}" \
        --arg version "${notifier_version}" '
        def normalized_envelope:
          if length != 1 then error("plugin list must contain one JSON document")
          elif (.[0] | type) == "object" then .[0]
          elif (.[0] | type) == "array" and (.[0] | length) == 1 and (.[0][0] | type) == "object"
          then .[0][0]
          else error("plugin list must be an object or singleton object array")
          end;

        normalized_envelope as $envelope
        | if ($envelope | keys) != ["active", "inactive"] or
             ($envelope.active | type) != "array" or
             ($envelope.inactive | type) != "array"
          then error("plugin list envelope is invalid") else $envelope end
        | [.active[], .inactive[]] as $plugins
        | if ($plugins | all(
              type == "object" and
              (.id | type) == "string" and
              (.version | type) == "string")) | not
          then error("plugin list entry is invalid") else . end
        | if ($plugins | map(.id) | length) != ($plugins | map(.id) | unique | length)
          then error("plugin list contains duplicate IDs") else . end
        | [.active[] | select(.id == $id)] as $active
        | [.inactive[] | select(.id == $id)] as $inactive
        | if (($active + $inactive) | all(.version | test("^[0-9]+\\.[0-9]+\\.[0-9]+([+-][A-Za-z0-9.-]+)?$"))) | not
          then error("target plugin version is invalid") else . end
        | if $query == "exact-active" then
            (($active | length) == 1 and
             ($inactive | length) == 0 and
             $active[0].version == $version)
          elif ($active | length) == 1 then
            "active\t" + $active[0].version
          elif ($inactive | length) == 1 then
            "inactive\t" + $inactive[0].version
          else
            "missing\t-"
          end
    ' "${plugin_list_file}" 2>/dev/null
}

notifier_plugin_list_is_exact_active() {
    notifier_plugin_list_query "$1" "$2" exact-active "$3" >/dev/null
}

notifier_plugin_list_target_state() {
    notifier_plugin_list_query "$1" "$2" target-state
}
