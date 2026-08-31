#!/usr/bin/env bash

set -Eeuo pipefail

exec 3>&1
exec >/dev/null 2>&1
umask 077

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
notifier_root="$(cd -- "${script_dir}/.." && pwd -P)"
repository_root="$(cd -- "${notifier_root}/.." && pwd -P)"
compose_file="${script_dir}/existing/docker-compose.yml"
versions_file="${repository_root}/deploy/versions.env"
scenario_file="${script_dir}/cmd/existing-acceptance/scenario-ids.txt"
result_output_path="${INTEGRATION_RESULT_FILE:-}"
public_evidence_output_path="${INTEGRATION_PUBLIC_EVIDENCE_FILE:-}"
safe_diagnostic_output_path="${INTEGRATION_SAFE_DIAGNOSTIC_FILE:-}"
progress_output_path="${INTEGRATION_PROGRESS_FILE:-}"

integration_root=""
runtime_parent=""
integration_env=""
adoption_env=""
project_name=""
diagnostic_file=""
acceptance_binary=""
project_touched=false
runtime_touched=false
result_kind=failure
result_assertion=NF-ADOPT-01
result_stage=bootstrap
generated_bundle=false
bundle_sha_public=""
setup_status=""

declare -a docker_command=()
declare -a privileged_docker_command=()

fail() {
    result_assertion="$1"
    exit 1
}

record_stage() {
    local stage="$1"
    local progress_parent=""
    local progress_temporary=""

    [[ "${stage}" =~ ^[a-z0-9-]+$ ]] || return 1
    result_stage="${stage}"
    [[ -n "${progress_output_path}" ]] || return 0
    progress_parent="$(dirname -- "${progress_output_path}")"
    progress_temporary="${progress_output_path}.tmp.$$"
    [[ "${progress_output_path}" == /* && -d "${progress_parent}" \
        && ! -L "${progress_output_path}" \
        && ! -e "${progress_temporary}" && ! -L "${progress_temporary}" ]] || return 1
    printf 'stage=%s\nelapsed_seconds=%s\n' "${stage}" "${SECONDS}" >"${progress_temporary}"
    chmod 0644 "${progress_temporary}"
    mv -f -- "${progress_temporary}" "${progress_output_path}"
}

version_value() {
    awk -F= -v key="$1" '
        $1 == key { count++; value = substr($0, index($0, "=") + 1) }
        END { if (count != 1 || value == "") exit 1; print value }
    ' "${versions_file}"
}

portable_hash() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        shasum -a 256 "$1" | awk '{print $1}'
    fi
}

compose_base() {
    "${docker_command[@]}" compose \
        --project-directory "${script_dir}/existing" \
        --env-file "${integration_env}" \
        -f "${compose_file}" "$@"
}

compose_combined() {
    "${privileged_docker_command[@]}" compose \
        --project-directory "${script_dir}/existing" \
        --env-file "${integration_env}" \
        -f "${compose_file}" \
        --env-file "${adoption_env}" \
        -f "${runtime_parent}/notifier/compose.override.yml" "$@"
}

safe_service_state() {
    local service="$1"
    local container_id=""
    local state="unknown"
    local health="unknown"

    container_id="$(compose_base ps --all --quiet "${service}" 2>/dev/null)" || container_id=""
    if [[ "${container_id}" =~ ^[a-f0-9]{12,64}$ ]]; then
        read -r state health < <("${docker_command[@]}" inspect \
            --format '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' \
            "${container_id}" 2>/dev/null) || {
            state=unknown
            health=unknown
        }
    else
        state=missing
        health=none
    fi

    case "${state}" in
        created | running | paused | restarting | removing | exited | dead | missing) ;;
        *) state=unknown ;;
    esac
    case "${health}" in
        starting | healthy | unhealthy | none) ;;
        *) health=unknown ;;
    esac
    printf '%s,%s\n' "${state}" "${health}"
}

safe_http_probe() {
    local endpoint="$1"
    local http_code=""
    local probe_status=0

    http_code="$(curl --noproxy '*' --silent --max-time 2 --output /dev/null \
        --write-out '%{http_code}' "${endpoint}" 2>/dev/null)" || probe_status=$?
    if [[ "${probe_status}" -eq 0 && "${http_code}" =~ ^[0-9]{3}$ ]]; then
        printf 'http-%s\n' "${http_code}"
    elif [[ "${probe_status}" =~ ^[0-9]+$ && "${probe_status}" -le 255 ]]; then
        printf 'curl-exit-%s\n' "${probe_status}"
    else
        printf '%s\n' unknown
    fi
}

safe_container_http_probe() {
    local service="$1"
    local endpoint="$2"
    local container_id=""
    local http_code=""
    local probe_status=0

    container_id="$(compose_base ps --all --quiet "${service}" 2>/dev/null)" || container_id=""
    if [[ ! "${container_id}" =~ ^[a-f0-9]{12,64}$ ]]; then
        printf '%s\n' container-missing
        return 0
    fi
    http_code="$("${docker_command[@]}" exec "${container_id}" curl --silent --max-time 2 \
        --output /dev/null --write-out '%{http_code}' "${endpoint}" 2>/dev/null)" || probe_status=$?
    if [[ "${probe_status}" -eq 0 && "${http_code}" =~ ^[0-9]{3}$ ]]; then
        printf 'http-%s\n' "${http_code}"
    elif [[ "${probe_status}" =~ ^[0-9]+$ && "${probe_status}" -le 255 ]]; then
        printf 'curl-exit-%s\n' "${probe_status}"
    else
        printf '%s\n' unknown
    fi
}

safe_mattermost_restart_count() {
    local container_id=""
    local restart_count=""

    container_id="$(compose_base ps --all --quiet mattermost 2>/dev/null)" || container_id=""
    [[ "${container_id}" =~ ^[a-f0-9]{12,64}$ ]] || {
        printf '%s\n' missing
        return 0
    }
    restart_count="$("${docker_command[@]}" inspect --format '{{.RestartCount}}' \
        "${container_id}" 2>/dev/null)" || restart_count=""
    [[ "${restart_count}" =~ ^[0-9]+$ ]] && printf '%s\n' "${restart_count}" || printf '%s\n' unknown
}

safe_mattermost_local_status() {
    local container_id=""
    local local_status=0

    container_id="$(compose_base ps --all --quiet mattermost 2>/dev/null)" || container_id=""
    [[ "${container_id}" =~ ^[a-f0-9]{12,64}$ ]] || {
        printf '%s\n' container-missing
        return 0
    }
    "${docker_command[@]}" exec "${container_id}" /mattermost/bin/mmctl \
        system status --local >/dev/null 2>&1 || local_status=$?
    if [[ "${local_status}" =~ ^[0-9]+$ && "${local_status}" -le 255 ]]; then
        printf 'exit-%s\n' "${local_status}"
    else
        printf '%s\n' unknown
    fi
}

safe_mattermost_log_flags() {
    local container_id=""
    local logs=""
    local file_logs=""
    local flags=""
    local label=""
    local pattern=""

    container_id="$(compose_base ps --all --quiet mattermost 2>/dev/null)" || container_id=""
    [[ "${container_id}" =~ ^[a-f0-9]{12,64}$ ]] || {
        printf '%s\n' container-missing
        return 0
    }
    logs="$("${docker_command[@]}" logs --tail 200 "${container_id}" 2>/dev/null)" || logs=""
    if [[ -n "${integration_root}" ]] \
        && sudo test -f "${integration_root}/data/mattermost/logs/mattermost.log"; then
        file_logs="$(sudo tail -n 200 "${integration_root}/data/mattermost/logs/mattermost.log" 2>/dev/null)" \
            || file_logs=""
        logs="${logs}"$'\n'"${file_logs}"
    fi
    while IFS='|' read -r label pattern; do
        if grep -Eiq -- "${pattern}" <<<"${logs}"; then
            flags="${flags:+${flags},}${label}"
        fi
    done <<'EOF'
permission|permission denied|operation not permitted
database|database|postgres|sqlstore|migration
configuration|configuration|config.json|failed to load config
listener|listen tcp|address already in use
fatal|panic|fatal|failed to start|unable to start
EOF
    printf '%s\n' "${flags:-none}"
}

safe_harness_log_flags() {
    local logs=""
    local flags=""
    local label=""
    local pattern=""

    [[ -n "${diagnostic_file}" && -f "${diagnostic_file}" ]] || {
        printf '%s\n' unavailable
        return 0
    }
    logs="$(tail -n 200 "${diagnostic_file}" 2>/dev/null)" || logs=""
    while IFS='|' read -r label pattern; do
        if grep -Eiq -- "${pattern}" <<<"${logs}"; then
            flags="${flags:+${flags},}${label}"
        fi
    done <<'EOF'
go-cache|build cache|GOCACHE
go-network|proxy\.golang\.org|TLS handshake|connection reset|dial tcp|i/o timeout
go-compile|undefined:|syntax error|cannot use|build constraints exclude
permission|permission denied|operation not permitted
no-space|no space left on device
timeout|timed out|timeout
EOF
    printf '%s\n' "${flags:-none}"
}

safe_supported_preflight_failure() {
    local logs=""
    local classification=unavailable

    [[ -n "${diagnostic_file}" && -f "${diagnostic_file}" ]] || {
        printf '%s\n' "${classification}"
        return 0
    }
    logs="$(awk '
        $0 == "[HARNESS] supported-preflight-start" { capture = 1; next }
        capture { print }
    ' "${diagnostic_file}" 2>/dev/null)" || logs=""
    case "${logs}" in
        *'Existing notifier configuration is invalid or unsafe'*) classification=config ;;
        *'Existing Compose inputs or Mattermost bind roots are unsafe'*) classification=input-paths ;;
        *'Existing Compose configuration is invalid'*) classification=compose-config ;;
        *'Existing Compose model could not be inspected'*) classification=compose-inspection ;;
        *'Existing Compose model is unsupported or conflicts with notifier resources'*) classification=compose-model ;;
        *'Exactly one running Mattermost container is required'*) classification=container-count ;;
        *'Mattermost Team Edition 11.7.7 is required'*) classification=live-version ;;
        *'Mattermost Site URL must match THN_DOMAIN over HTTPS'*) classification=site-url ;;
        *'Existing ThreadHub notifier plugin state requires manual review'*) classification=plugin-state ;;
        *'[OK] Mattermost Site URL and notifier collision checks passed'*) classification=none ;;
        *)
            if [[ -n "${logs}" ]]; then
                classification=unclassified
            fi
            ;;
    esac
    printf '%s\n' "${classification}"
}

safe_input_path_failures() {
    local failures=""
    local mode=""
    local label=""
    local path=""
    local kind=""

    safe_add_input_failure() {
        failures="${failures:+${failures},}$1"
    }
    safe_check_input_path() {
        label="$1"
        path="$2"
        kind="$3"
        if sudo test -L "${path}"; then
            safe_add_input_failure "${label}-symlink"
            return
        fi
        if [[ "${kind}" == file ]] && ! sudo test -f "${path}"; then
            safe_add_input_failure "${label}-not-file"
            return
        fi
        if [[ "${kind}" == directory ]] && ! sudo test -d "${path}"; then
            safe_add_input_failure "${label}-not-directory"
            return
        fi
        mode="$(sudo stat -c '%a' "${path}" 2>/dev/null)" || {
            safe_add_input_failure "${label}-mode-unavailable"
            return
        }
        if [[ ! "${mode}" =~ ^[0-7]{3,4}$ ]] || (( (8#${mode} & 0022) != 0 )); then
            safe_add_input_failure "${label}-writable"
        fi
    }

    if ! sudo test -d "${script_dir}/existing" || sudo test -L "${script_dir}/existing"; then
        safe_add_input_failure project-dir
    fi
    safe_check_input_path compose-file "${compose_file}" file
    safe_check_input_path compose-env "${integration_env}" file
    [[ "$(sudo stat -c '%a' "${integration_env}" 2>/dev/null)" == 600 ]] \
        || safe_add_input_failure compose-env-not-0600
    safe_check_input_path plugins-root "${integration_root}/data/mattermost/plugins" directory
    safe_check_input_path data-root "${integration_root}/data/mattermost/data" directory
    safe_check_input_path smtp-ca "${integration_root}/data/smtp-ca/ca.crt" file
    printf '%s\n' "${failures:-none}"
}

safe_disabled_setup_failure() {
    local logs=""
    local classification=unavailable

    [[ -n "${diagnostic_file}" && -f "${diagnostic_file}" ]] || {
        printf '%s\n' "${classification}"
        return 0
    }
    logs="$(awk '
        $0 == "[HARNESS] disabled-setup-start" { capture = 1; next }
        capture { print }
    ' "${diagnostic_file}" 2>/dev/null)" || logs=""
    case "${logs}" in
        *'Run ./deploy/scripts/existing-notifier-smtp-test.sh'*) classification=smtp-handoff ;;
        *'Existing notifier configuration changed during setup'*) classification=config-changed ;;
        *'Notifier runtime parent is missing or unsafe'*) classification=runtime-parent ;;
        *'Notifier runtime parent must be owned by root'*) classification=runtime-parent-owner ;;
        *'Notifier runtime parent must not be writable by group or other users'*) classification=runtime-parent-mode ;;
        *'Notifier runtime directory identity is invalid'*) classification=runtime-identity ;;
        *'rollback capture'*) classification=rollback-capture ;;
        *'disabled control state could not be installed'*) classification=disabled-control ;;
        *'notifier release identity differs'*) classification=release-conflict ;;
        *'Notifier runtime and filestore plugin objects are asymmetric'*) classification=plugin-pair ;;
        *)
            if [[ -n "${logs}" ]]; then
                classification=unclassified
            fi
            ;;
    esac
    printf '%s\n' "${classification}"
}

safe_disabled_setup_phase() {
    local phase=""

    [[ -n "${diagnostic_file}" && -f "${diagnostic_file}" ]] || {
        printf '%s\n' unavailable
        return 0
    }
    phase="$(awk -F': ' '
        $0 == "[HARNESS] disabled-setup-start" { capture = 1; next }
        capture && $1 == "[threadhub] Existing notifier setup phase" { value = $2 }
        END { print value }
    ' "${diagnostic_file}" 2>/dev/null)" || phase=""
    case "${phase}" in
        preflight|prepare_runtime|record_rollback_capture|write_disabled_control|build_artifacts|write_override|start_mailer|verify_mailer|install_plugin|verify_plugin)
            printf '%s\n' "${phase}"
            ;;
        *) printf '%s\n' unavailable ;;
    esac
}

safe_writable_state() {
    local path="$1"

    if [[ -d "${path}" && -w "${path}" ]]; then
        printf '%s\n' yes
    elif [[ -d "${path}" ]]; then
        printf '%s\n' no
    else
        printf '%s\n' missing
    fi
}

safe_disabled_count_differences() {
    local baseline_file="${integration_root}/counts-baseline"
    local disabled_file="${integration_root}/counts-disabled"

    [[ -f "${baseline_file}" && -f "${disabled_file}" ]] || {
        printf '%s\n' unavailable
        return 0
    }
    awk -F '\t' '
        NR == 1 {
            if (NF != 6) exit 2
            for (field = 1; field <= 6; field++) {
                if ($field !~ /^[0-9]+$/) exit 2
                baseline[field] = $field
            }
            next
        }
        NR == 2 {
            if (NF != 6) exit 2
            for (field = 1; field <= 6; field++) {
                if ($field !~ /^[0-9]+$/) exit 2
                current[field] = $field
            }
            next
        }
        END {
            if (NR != 2) exit 2
            labels[1] = "teams"
            labels[2] = "channels"
            labels[3] = "channelmembers"
            labels[4] = "users"
            labels[5] = "posts"
            labels[6] = "fileinfo"
            output = ""
            for (field = 1; field <= 6; field++) {
                if (current[field] == baseline[field]) continue
                direction = current[field] > baseline[field] ? "increased" : "decreased"
                output = output (output == "" ? "" : ",") labels[field] "-" direction
            }
            print output == "" ? "none" : output
        }
    ' "${baseline_file}" "${disabled_file}" 2>/dev/null || printf '%s\n' unavailable
}

write_safe_diagnostic() {
    local evidence_parent=""
    local postgres_state=""
    local smtp_state=""
    local mattermost_state=""
    local mattermost_host_probe=""
    local mattermost_container_probe=""
    local mattermost_restart_count=""
    local mattermost_local_status=""
    local mattermost_log_flags=""
    local harness_log_flags=""
    local supported_preflight_failure=""
    local input_path_failures=""
    local disabled_setup_failure=""
    local disabled_setup_phase=""
    local setup_exit=""
    local disabled_count_differences=""
    local integration_root_writable=""
    local go_cache_writable=""

    [[ -n "${safe_diagnostic_output_path}" && "${result_kind}" != success ]] || return 0
    evidence_parent="$(dirname -- "${safe_diagnostic_output_path}")"
    [[ "${safe_diagnostic_output_path}" == /* && -d "${evidence_parent}" \
        && ! -e "${safe_diagnostic_output_path}" && ! -L "${safe_diagnostic_output_path}" \
        && "${result_stage}" =~ ^[a-z0-9-]+$ ]] || return 0

    postgres_state="$(safe_service_state postgres)"
    smtp_state="$(safe_service_state smtp-fixture)"
    mattermost_state="$(safe_service_state mattermost)"
    mattermost_host_probe="$(safe_http_probe 'http://127.0.0.1:49153/api/v4/system/ping')"
    mattermost_container_probe="$(safe_container_http_probe mattermost 'http://localhost:8065/api/v4/system/ping')"
    mattermost_restart_count="$(safe_mattermost_restart_count)"
    mattermost_local_status="$(safe_mattermost_local_status)"
    mattermost_log_flags="$(safe_mattermost_log_flags)"
    harness_log_flags="$(safe_harness_log_flags)"
    supported_preflight_failure="$(safe_supported_preflight_failure)"
    input_path_failures="$(safe_input_path_failures)"
    disabled_setup_failure="$(safe_disabled_setup_failure)"
    disabled_setup_phase="$(safe_disabled_setup_phase)"
    disabled_count_differences="$(safe_disabled_count_differences)"
    if [[ "${setup_status}" =~ ^[0-9]+$ && "${setup_status}" -le 255 ]]; then
        setup_exit="${setup_status}"
    else
        setup_exit=unavailable
    fi
    integration_root_writable="$(safe_writable_state "${integration_root}")"
    go_cache_writable="$(safe_writable_state "${integration_root}/go-cache")"
    (set -o noclobber; {
        printf 'failure_stage=%s\n' "${result_stage}"
        printf 'postgres=%s\n' "${postgres_state}"
        printf 'smtp_fixture=%s\n' "${smtp_state}"
        printf 'mattermost=%s\n' "${mattermost_state}"
        printf 'mattermost_host_probe=%s\n' "${mattermost_host_probe}"
        printf 'mattermost_container_probe=%s\n' "${mattermost_container_probe}"
        printf 'mattermost_restart_count=%s\n' "${mattermost_restart_count}"
        printf 'mattermost_local_status=%s\n' "${mattermost_local_status}"
        printf 'mattermost_log_flags=%s\n' "${mattermost_log_flags}"
        printf 'harness_log_flags=%s\n' "${harness_log_flags}"
        printf 'supported_preflight_failure=%s\n' "${supported_preflight_failure}"
        printf 'input_path_failures=%s\n' "${input_path_failures}"
        printf 'disabled_setup_failure=%s\n' "${disabled_setup_failure}"
        printf 'disabled_setup_phase=%s\n' "${disabled_setup_phase}"
        printf 'disabled_setup_exit=%s\n' "${setup_exit}"
        printf 'disabled_count_differences=%s\n' "${disabled_count_differences}"
        printf 'integration_root_writable=%s\n' "${integration_root_writable}"
        printf 'go_cache_writable=%s\n' "${go_cache_writable}"
    } >"${safe_diagnostic_output_path}") || return 0
    chmod 0644 "${safe_diagnostic_output_path}" || true
}

private() {
    "$@" >>"${diagnostic_file}" 2>&1
}

db_counts() {
    local output_file="$1"
    # Mattermost can lazily create its built-in system-bot during background
    # work once a system administrator exists. Validate that reserved identity
    # separately so its timing cannot mask tenant-user drift.
    db_system_bot_valid || return 1
    compose_base exec -T postgres psql -X -A -t -U threadhub -d threadhub \
        -c "SELECT (SELECT count(*) FROM teams)||E'\\t'||(SELECT count(*) FROM channels)||E'\\t'||(SELECT count(*) FROM channelmembers)||E'\\t'||(SELECT count(*) FROM users WHERE username <> 'system-bot')||E'\\t'||(SELECT count(*) FROM posts)||E'\\t'||(SELECT count(*) FROM fileinfo);" \
        >"${output_file}" 2>>"${diagnostic_file}"
    [[ "$(wc -l < "${output_file}" | tr -d '[:space:]')" == 1 ]]
    awk -F '\t' '
        NF != 6 { exit 1 }
        { for (field = 1; field <= NF; field++) if ($field !~ /^[0-9]+$/) exit 1 }
    ' "${output_file}"
}

db_system_bot_valid() {
    local result=""

    result="$(compose_base exec -T postgres psql -X -A -t -U threadhub -d threadhub \
        -c "SELECT CASE WHEN (SELECT count(*) FROM users WHERE username = 'system-bot') = 0 THEN 'absent' WHEN (SELECT count(*) FROM users u JOIN bots b ON b.userid = u.id WHERE u.username = 'system-bot' AND u.roles = 'system_user' AND u.deleteat = 0) = 1 AND (SELECT count(*) FROM users WHERE username = 'system-bot') = 1 THEN 'valid' ELSE 'invalid' END;" \
        2>>"${diagnostic_file}")" || return 1
    result="$(tr -d '[:space:]' <<<"${result}")"
    [[ "${result}" == absent || "${result}" == valid ]]
}

acceptance() {
    EXISTING_ACCEPTANCE_STATE_FILE="${integration_root}/acceptance-state.json" \
    EXISTING_ACCEPTANCE_SNAPSHOT_FILE="${integration_root}/capture-before.json" \
    EXISTING_ACCEPTANCE_ADMIN_PASSWORD="${admin_password}" \
    EXISTING_ACCEPTANCE_USER_PASSWORD="${user_password}" \
    EXISTING_ACCEPTANCE_HASH_SECRET="${hash_secret}" \
        "${acceptance_binary}" "$@"
}

run_pty() {
    local input_file="$1"
    shift
    local command_string=""
    printf -v command_string '%q ' env \
        "THREADHUB_EXISTING_NOTIFIER_ENV_FILE=${adoption_env}" "$@"
    timeout --foreground --kill-after=10s 180s script -q -e -c "${command_string}" /dev/null \
        <"${input_file}" >/dev/null 2>&1
}

queue_is_idle() {
    local status_file="${integration_root}/mailer-status.json"
    compose_combined exec -T threadhub-mailer /threadhub-mailer status --json \
        >"${status_file}" 2>>"${diagnostic_file}" || return 1
    jq -e '.pending == 0 and .sending == 0 and .failed == 0' \
        "${status_file}" >/dev/null 2>&1
}

wait_queue_idle() {
    local deadline=$((SECONDS + 90))
    until queue_is_idle; do
        ((SECONDS < deadline)) || return 1
        sleep 1
    done
}

queue_has_pending() {
    local status_file="${integration_root}/mailer-pending.json"
    compose_combined exec -T threadhub-mailer /threadhub-mailer status --json \
        >"${status_file}" 2>>"${diagnostic_file}" || return 1
    jq -e '.pending > 0 or .sending > 0' "${status_file}" >/dev/null 2>&1
}

wait_queue_pending() {
    local deadline=$((SECONDS + 30))
    until queue_has_pending; do
        ((SECONDS < deadline)) || return 1
        sleep 1
    done
}

wait_http() {
    local endpoint="$1"
    local attempts="$2"
    local attempt=0

    while ((attempt < attempts)); do
        if curl --noproxy '*' --fail --silent --max-time 2 "${endpoint}" >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
        ((attempt += 1))
    done
    return 1
}

cleanup() {
    local incoming_status=$?
    local safe_output="${result_assertion}"
    local cleanup_ok=true
    local privacy_patterns=""
    local artifact_parent=""
    local evidence_parent=""

    trap - EXIT HUP INT TERM
    set +e

    write_safe_diagnostic

    if [[ "${result_kind}" == success && -f "${scenario_file}" ]]; then
        safe_output="$(<"${scenario_file}")"
    fi

    if [[ -n "${integration_root}" && -d "${integration_root}" ]]; then
        privacy_patterns="${integration_root}/privacy-patterns"
        : >"${privacy_patterns}"
        chmod 0600 "${privacy_patterns}"
        for protected in "${db_password:-}" "${hmac_secret:-}" "${hash_secret:-}" "${smtp_password:-}" "${admin_password:-}" "${user_password:-}" '@integration.invalid' integration-post; do
            [[ -n "${protected}" ]] && printf '%s\n' "${protected}" >>"${privacy_patterns}"
        done
        if grep -R -F -q -f "${privacy_patterns}" "${diagnostic_file:-/dev/null}" 2>/dev/null; then
            cleanup_ok=false
            safe_output=NF-ADOPT-05
        fi
        if [[ -n "${integration_root}/data/mattermost/logs" ]] \
            && sudo grep -R -F -q -f "${privacy_patterns}" "${integration_root}/data/mattermost/logs" 2>/dev/null; then
            cleanup_ok=false
            safe_output=NF-ADOPT-05
        fi
    fi

    if [[ "${project_touched}" == true ]]; then
        if [[ -n "${runtime_parent}" ]] && sudo test -f "${runtime_parent}/notifier/compose.override.yml"; then
            compose_combined down --volumes --remove-orphans --timeout 10 >/dev/null 2>&1 || cleanup_ok=false
        else
            compose_base down --volumes --remove-orphans --timeout 10 >/dev/null 2>&1 || cleanup_ok=false
        fi
    fi

    if [[ "${runtime_touched}" == true ]]; then
        case "${runtime_parent}" in
            /var/tmp/threadhub-existing-adoption-[a-z0-9_-]*)
                [[ -d "${runtime_parent}" && ! -L "${runtime_parent}" ]] \
                    && sudo rm -rf -- "${runtime_parent}" || cleanup_ok=false
                ;;
            *) cleanup_ok=false ;;
        esac
    fi

    if [[ "${generated_bundle}" == true ]]; then
        rm -f -- "${repository_root}/notifier/dist/com.threadhub.channel-email-notifier-0.1.0.tar.gz" \
            || cleanup_ok=false
        rmdir "${repository_root}/notifier/dist" >/dev/null 2>&1 || true
    fi

    if [[ -n "${integration_root}" ]]; then
        case "${integration_root}" in
            "${temporary_base}"/threadhub-existing-adoption.*)
                [[ -d "${integration_root}" && ! -L "${integration_root}" ]] \
                    && sudo rm -rf -- "${integration_root}" || cleanup_ok=false
                ;;
            *) cleanup_ok=false ;;
        esac
    fi

    if [[ "${cleanup_ok}" != true ]]; then
        safe_output=NF-ADOPT-09
        result_kind=failure
        incoming_status=1
    fi

    if [[ -n "${public_evidence_output_path}" && "${result_kind}" == success ]]; then
        evidence_parent="$(dirname -- "${public_evidence_output_path}")"
        if [[ "${public_evidence_output_path}" != /* || ! -d "${evidence_parent}" \
            || -e "${public_evidence_output_path}" || -L "${public_evidence_output_path}" \
            || ! "${bundle_sha_public}" =~ ^[a-f0-9]{64}$ ]]; then
            safe_output=NF-ADOPT-09
            result_kind=failure
            incoming_status=1
        elif ! (set -o noclobber; {
            printf 'test_date=%s\n' "$(date -u +%F)"
            printf 'source_commit=%s\n' "$(git -C "${repository_root}" rev-parse --verify 'HEAD^{commit}')"
            printf 'mattermost_image_digest=%s\n' "${mattermost_digest}"
            printf 'postgres_image_digest=%s\n' "${postgres_digest}"
            printf 'notifier_version=%s\n' "${notifier_version}"
            printf 'plugin_bundle_sha256=%s\n' "${bundle_sha_public}"
            printf 'nf_scenario_count=10\n'
            printf 'result=pass\n'
        } >"${public_evidence_output_path}") || ! chmod 0644 "${public_evidence_output_path}"; then
            safe_output=NF-ADOPT-09
            result_kind=failure
            incoming_status=1
        fi
    fi

    if [[ -n "${result_output_path}" ]]; then
        artifact_parent="$(dirname -- "${result_output_path}")"
        if [[ "${result_output_path}" != /* || ! -d "${artifact_parent}" || -e "${result_output_path}" || -L "${result_output_path}" ]]; then
            safe_output=NF-ADOPT-01
            result_kind=failure
            incoming_status=1
        elif ! (set -o noclobber; printf '%s\n' "${safe_output}" >"${result_output_path}") \
            || ! chmod 0644 "${result_output_path}"; then
            safe_output=NF-ADOPT-01
            result_kind=failure
            incoming_status=1
        fi
    fi

    if [[ "${result_kind}" == success && "${incoming_status}" -eq 0 ]]; then
        printf '%s\n' "${safe_output}" >&3
        exit 0
    fi
    printf '%s\n' "${safe_output}" >&3
    exit 1
}

trap cleanup EXIT
trap 'result_kind=failure; result_assertion=NF-ADOPT-09; exit 130' HUP INT TERM

for required in awk cat chmod cmp cp curl date dirname docker git go grep id jq mkdir mktemp openssl rm script sed sleep sort stat sudo tail timeout tr wc; do
    command -v "${required}" >/dev/null 2>&1 || fail NF-ADOPT-01
done
[[ "$(uname -s)" == Linux && "$(uname -m)" == x86_64 ]] || fail NF-ADOPT-01
grep -Eq '^ID=ubuntu$' /etc/os-release || fail NF-ADOPT-01
grep -Eq '^VERSION_ID="?24\.04"?$' /etc/os-release || fail NF-ADOPT-01
[[ -f "${compose_file}" && -f "${versions_file}" && -f "${scenario_file}" ]] || fail NF-ADOPT-01
[[ "$(wc -l <"${scenario_file}" | tr -d '[:space:]')" == 10 \
    && "$(sort -u "${scenario_file}" | wc -l | tr -d '[:space:]')" == 10 ]] || fail NF-ADOPT-01
! grep -Evq '^NF-ADOPT-(0[1-9]|10)$' "${scenario_file}" || fail NF-ADOPT-01
[[ -z "$(git -C "${repository_root}" status --porcelain=v1 --untracked-files=all --ignore-submodules=none)" ]] || fail NF-ADOPT-01
cd "${repository_root}"

if docker info >/dev/null 2>&1; then
    docker_command=(docker)
    privileged_docker_command=(sudo docker)
elif sudo docker info >/dev/null 2>&1; then
    docker_command=(sudo docker)
    privileged_docker_command=(sudo docker)
else
    fail NF-ADOPT-01
fi

temporary_base="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
temporary_base="$(cd -- "${temporary_base}" && pwd -P)"
integration_root="$(mktemp -d "${temporary_base}/threadhub-existing-adoption.XXXXXX")"
diagnostic_file="${integration_root}/diagnostic"
integration_env="${integration_root}/base.env"
adoption_env="${integration_root}/existing-notifier.env"
acceptance_binary="${integration_root}/existing-acceptance"
project_name="threadhub-adopt-$(openssl rand -hex 6)"
runtime_parent="/var/tmp/threadhub-existing-adoption-${project_name}"
[[ "${project_name}" =~ ^[a-z0-9][a-z0-9_-]{0,62}$ ]] || fail NF-ADOPT-01
: >"${diagnostic_file}"
chmod 0600 "${diagnostic_file}"

mattermost_repository="$(version_value MATTERMOST_IMAGE_REPOSITORY)" || fail NF-ADOPT-01
mattermost_tag="$(version_value MATTERMOST_IMAGE_TAG)" || fail NF-ADOPT-01
mattermost_digest="$(version_value MATTERMOST_IMAGE_DIGEST)" || fail NF-ADOPT-01
postgres_repository="$(version_value POSTGRES_IMAGE_REPOSITORY)" || fail NF-ADOPT-01
postgres_tag="$(version_value POSTGRES_IMAGE_TAG)" || fail NF-ADOPT-01
postgres_digest="$(version_value POSTGRES_IMAGE_DIGEST)" || fail NF-ADOPT-01
go_repository="$(version_value GO_BUILDER_IMAGE_REPOSITORY)" || fail NF-ADOPT-01
go_tag="$(version_value GO_BUILDER_IMAGE_TAG)" || fail NF-ADOPT-01
go_digest="$(version_value GO_BUILDER_IMAGE_DIGEST)" || fail NF-ADOPT-01
notifier_version="$(version_value NOTIFIER_VERSION)" || fail NF-ADOPT-01
[[ "${mattermost_repository}:${mattermost_tag}" == mattermost/mattermost-team-edition:11.7.7 ]] || fail NF-ADOPT-01
[[ "${postgres_repository}:${postgres_tag}" == postgres:18.4 && "${notifier_version}" == 0.1.0 ]] || fail NF-ADOPT-01

db_password="$(openssl rand -hex 32)"
hmac_secret="$(openssl rand -hex 32)"
hash_secret="$(openssl rand -hex 32)"
smtp_password="$(openssl rand -hex 32)"
admin_password="Aa1!$(openssl rand -hex 24)"
user_password="Bb2!$(openssl rand -hex 24)"

mkdir -p \
    "${integration_root}/data/postgres" \
    "${integration_root}/data/mattermost/config" \
    "${integration_root}/data/mattermost/data/plugins" \
    "${integration_root}/data/mattermost/logs" \
    "${integration_root}/data/mattermost/plugins" \
    "${integration_root}/data/mattermost/client/plugins" \
    "${integration_root}/data/mattermost/bleve-indexes" \
    "${integration_root}/data/smtp-private" \
    "${integration_root}/data/smtp-ca" \
    "${integration_root}/go-cache" || fail NF-ADOPT-01
sudo chown -R 999:999 "${integration_root}/data/postgres" || fail NF-ADOPT-01
sudo chown -R 2000:2000 "${integration_root}/data/mattermost" || fail NF-ADOPT-01
sudo chown -R 65532:65532 "${integration_root}/data/smtp-private" "${integration_root}/data/smtp-ca" || fail NF-ADOPT-01
sudo chmod 0750 \
    "${integration_root}/data/mattermost/plugins" \
    "${integration_root}/data/mattermost/data" \
    "${integration_root}/data/mattermost/data/plugins" || fail NF-ADOPT-01
sudo install -d -o root -g root -m 0750 "${runtime_parent}" || fail NF-ADOPT-01
runtime_touched=true

cat >"${integration_env}" <<EOF
COMPOSE_PROJECT_NAME=${project_name}
MATTERMOST_IMAGE_REPOSITORY=${mattermost_repository}
MATTERMOST_IMAGE_TAG=${mattermost_tag}
MATTERMOST_IMAGE_DIGEST=${mattermost_digest}
POSTGRES_IMAGE_REPOSITORY=${postgres_repository}
POSTGRES_IMAGE_TAG=${postgres_tag}
POSTGRES_IMAGE_DIGEST=${postgres_digest}
GO_BUILDER_IMAGE_REPOSITORY=${go_repository}
GO_BUILDER_IMAGE_TAG=${go_tag}
GO_BUILDER_IMAGE_DIGEST=${go_digest}
NOTIFIER_VERSION=${notifier_version}
INTEGRATION_DATA_ROOT=${integration_root}/data
INTEGRATION_DB_PASSWORD=${db_password}
INTEGRATION_SMTP_PASSWORD=${smtp_password}
INTEGRATION_HASH_SECRET=${hash_secret}
EOF
chmod 0600 "${integration_env}"

cat >"${adoption_env}" <<EOF
THN_COMPOSE_PROJECT_DIR=${script_dir}/existing
THN_COMPOSE_FILE=${compose_file}
THN_COMPOSE_ENV_FILE=${integration_env}
THN_MATTERMOST_SERVICE=mattermost
THN_MATTERMOST_PLUGINS_ROOT=${integration_root}/data/mattermost/plugins
THN_MATTERMOST_DATA_ROOT=${integration_root}/data/mattermost/data
THN_DATA_ROOT=${runtime_parent}/notifier
THN_DOMAIN=threadhub-existing.integration.test
THN_SMTP_SERVER=smtp.email.ap-singapore-1.oci.oraclecloud.com
THN_SMTP_PORT=587
THN_SMTP_CA_FILE=${integration_root}/data/smtp-ca/ca.crt
THN_SMTP_USERNAME=integration-smtp-user
THN_SMTP_PASSWORD=${smtp_password}
THN_SMTP_FROM_ADDRESS=no-reply@integration.invalid
THN_SMTP_REPLY_TO_ADDRESS=feedback@integration.invalid
THN_SMTP_FEEDBACK_NAME=ThreadHub
THN_HMAC_SECRET=${hmac_secret}
THN_RATE_PER_MINUTE=60
EOF
chmod 0600 "${adoption_env}"

record_stage base-compose-validate
private compose_base config --quiet || fail NF-ADOPT-01
record_stage base-image-pull
private compose_base pull --quiet postgres mattermost || fail NF-ADOPT-01
record_stage smtp-fixture-build
private "${docker_command[@]}" build --platform linux/amd64 \
    --build-arg "GO_BUILDER_IMAGE=${go_repository}:${go_tag}@${go_digest}" \
    --target smtp-fixture --tag "threadhub/notifier-smtp-fixture:${notifier_version}" \
    "${notifier_root}" || fail NF-ADOPT-01
project_touched=true
record_stage base-dependencies-start
private compose_base up -d --no-build --wait --wait-timeout 180 postgres smtp-fixture || fail NF-ADOPT-01
record_stage base-mattermost-start
private compose_base up -d --no-build mattermost || fail NF-ADOPT-01
private wait_http 'http://127.0.0.1:49153/api/v4/system/ping' 180 || fail NF-ADOPT-01
record_stage smtp-ca-permissions
sudo chown root:root "${integration_root}/data/smtp-ca/ca.crt" || fail NF-ADOPT-01
sudo chmod 0644 "${integration_root}/data/smtp-ca/ca.crt" || fail NF-ADOPT-01
sudo chown root:root "${integration_root}/data/smtp-ca" || fail NF-ADOPT-01
sudo chmod 0755 "${integration_root}/data/smtp-ca" || fail NF-ADOPT-01

record_stage acceptance-build
private env GOCACHE="${integration_root}/go-cache" go -C "${notifier_root}" build \
    -o "${acceptance_binary}" ./integration/cmd/existing-acceptance || fail NF-ADOPT-01
record_stage admin-create
private compose_base exec -T mattermost mmctl user create --local --suppress-warnings \
    --email admin@integration.invalid --username existing-admin --password "${admin_password}" \
    --system-admin --email-verified || fail NF-ADOPT-03
record_stage acceptance-bootstrap
private acceptance bootstrap || fail NF-ADOPT-03
record_stage recipient-verify
private compose_base exec -T mattermost mmctl user verify existing-recipient-a --local --suppress-warnings || fail NF-ADOPT-03
private compose_base exec -T mattermost mmctl user verify existing-recipient-b --local --suppress-warnings || fail NF-ADOPT-03
record_stage baseline-counts
db_counts "${integration_root}/counts-baseline" || fail NF-ADOPT-03

record_stage unsupported-fixture-prepare
portable_hash "${compose_file}" >"${integration_root}/base-compose-before.sha256" || fail NF-ADOPT-01
portable_hash "${integration_env}" >"${integration_root}/base-env-before.sha256" || fail NF-ADOPT-01
cp "${integration_env}" "${integration_root}/unsupported.env" || fail NF-ADOPT-01
sed -i 's/^MATTERMOST_IMAGE_TAG=11\.7\.7$/MATTERMOST_IMAGE_TAG=11.8.0/' \
    "${integration_root}/unsupported.env" || fail NF-ADOPT-01
chmod 0600 "${integration_root}/unsupported.env" || fail NF-ADOPT-01
sed "s|^THN_COMPOSE_ENV_FILE=.*$|THN_COMPOSE_ENV_FILE=${integration_root}/unsupported.env|" \
    "${adoption_env}" >"${integration_root}/unsupported-notifier.env" || fail NF-ADOPT-01
chmod 0600 "${integration_root}/unsupported-notifier.env" || fail NF-ADOPT-01
record_stage unsupported-preflight
set +e
THREADHUB_EXISTING_NOTIFIER_ENV_FILE="${integration_root}/unsupported-notifier.env" \
    "${repository_root}/deploy/scripts/existing-notifier-preflight.sh" \
    >>"${diagnostic_file}" 2>&1
unsupported_status=$?
set -e
[[ "${unsupported_status}" -eq 20 && ! -e "${runtime_parent}/notifier" ]] || fail NF-ADOPT-02

record_stage supported-preflight
printf '%s\n' '[HARNESS] supported-preflight-start' >>"${diagnostic_file}"
private env THREADHUB_EXISTING_NOTIFIER_ENV_FILE="${adoption_env}" \
    "${repository_root}/deploy/scripts/existing-notifier-preflight.sh" || fail NF-ADOPT-01
record_stage post-preflight-integrity
[[ "$(portable_hash "${compose_file}")" == "$(<"${integration_root}/base-compose-before.sha256")" ]] || fail NF-ADOPT-01
[[ "$(portable_hash "${integration_env}")" == "$(<"${integration_root}/base-env-before.sha256")" ]] || fail NF-ADOPT-01
record_stage post-preflight-counts
db_counts "${integration_root}/counts-after-preflight" || fail NF-ADOPT-01
cmp -s "${integration_root}/counts-baseline" "${integration_root}/counts-after-preflight" || fail NF-ADOPT-01

record_stage disabled-setup
printf '%s\n' '[HARNESS] disabled-setup-start' >>"${diagnostic_file}"
set +e
generated_bundle=true
THREADHUB_EXISTING_NOTIFIER_ENV_FILE="${adoption_env}" \
    "${repository_root}/deploy/scripts/existing-notifier-setup.sh" --resume --non-interactive \
    >>"${diagnostic_file}" 2>&1
setup_status=$?
set -e
[[ "${setup_status}" -eq 20 ]] || fail NF-ADOPT-03
record_stage disabled-system-bot
db_system_bot_valid || fail NF-ADOPT-03
record_stage disabled-counts
db_counts "${integration_root}/counts-disabled" || fail NF-ADOPT-03
cmp -s "${integration_root}/counts-baseline" "${integration_root}/counts-disabled" || fail NF-ADOPT-03
record_stage disabled-baseline
private acceptance verify-baseline || fail NF-ADOPT-03

record_stage smtp-network-connect
smtp_container="$(compose_base ps -q smtp-fixture)"
[[ "${smtp_container}" =~ ^[a-f0-9]{64}$ ]] || fail NF-ADOPT-04
private "${docker_command[@]}" network connect \
    --alias smtp.email.ap-singapore-1.oci.oraclecloud.com \
    "${project_name}_threadhub-notifier-outbound" "${smtp_container}" || fail NF-ADOPT-04

record_stage smtp-acceptance
printf '%s\n' 'probe@integration.invalid' >"${integration_root}/smtp-recipient"
run_pty "${integration_root}/smtp-recipient" "${repository_root}/deploy/scripts/existing-notifier-smtp-test.sh" || fail NF-ADOPT-04
rm -f -- "${integration_root}/smtp-recipient"
public_channel="$(jq -r '.public_channel_id' "${integration_root}/acceptance-state.json")"
private_channel="$(jq -r '.private_channel_id' "${integration_root}/acceptance-state.json")"
[[ "${public_channel}" =~ ^[a-z0-9]{26}$ && "${private_channel}" =~ ^[a-z0-9]{26}$ ]] || fail NF-ADOPT-04
record_stage allowlist-activation
printf '%s,%s\n' "${public_channel}" "${private_channel}" >"${integration_root}/allowlist-input"
run_pty "${integration_root}/allowlist-input" \
    "${repository_root}/deploy/scripts/existing-notifier-control.sh" activate-allowlist || fail NF-ADOPT-04
rm -f -- "${integration_root}/allowlist-input"

record_stage acceptance-exercise
private acceptance exercise || fail NF-ADOPT-05
record_stage initial-queue-drain
wait_queue_idle || fail NF-ADOPT-04
bundle_sha_public="$(sudo awk -F= '$1 == "NOTIFIER_PLUGIN_BUNDLE_SHA256" { count++; value=$2 } END { if (count != 1 || value !~ /^[a-f0-9]{64}$/) exit 1; print value }' "${runtime_parent}/notifier/release/release.env")" || fail NF-ADOPT-04

record_stage outage-snapshot
private acceptance snapshot || fail NF-ADOPT-06
record_stage smtp-outage
private compose_base stop smtp-fixture || fail NF-ADOPT-06
private acceptance outage-post || fail NF-ADOPT-06
record_stage outage-queue-pending
wait_queue_pending || fail NF-ADOPT-06
record_stage mailer-restart
private compose_combined restart threadhub-mailer || fail NF-ADOPT-07
record_stage smtp-recovery
private compose_base start smtp-fixture || fail NF-ADOPT-07
record_stage outage-delivery
private acceptance assert-outage || fail NF-ADOPT-07
record_stage recovery-queue-drain
wait_queue_idle || fail NF-ADOPT-07

record_stage rollback-baseline
db_counts "${integration_root}/counts-before-rollback" || fail NF-ADOPT-09
record_stage rollback-drain
private env THREADHUB_EXISTING_NOTIFIER_ENV_FILE="${adoption_env}" \
    "${repository_root}/deploy/scripts/existing-notifier-control.sh" drain || fail NF-ADOPT-09
wait_queue_idle || fail NF-ADOPT-09
record_stage rollback-disable
private env THREADHUB_EXISTING_NOTIFIER_ENV_FILE="${adoption_env}" \
    "${repository_root}/deploy/scripts/existing-notifier-control.sh" disable || fail NF-ADOPT-09
private compose_combined stop threadhub-mailer || fail NF-ADOPT-09
sudo sha256sum "${runtime_parent}/notifier/mailer/queue.db" \
    | awk '{print $1}' >"${integration_root}/queue-before-rollback.sha256" || fail NF-ADOPT-09
private compose_combined up -d --no-deps --wait --wait-timeout 120 threadhub-mailer || fail NF-ADOPT-09
record_stage rollback-execute
private env THREADHUB_EXISTING_NOTIFIER_ENV_FILE="${adoption_env}" \
    "${repository_root}/deploy/scripts/existing-notifier-rollback.sh" || fail NF-ADOPT-09

record_stage rollback-verify
[[ "$(portable_hash "${compose_file}")" == "$(<"${integration_root}/base-compose-before.sha256")" ]] || fail NF-ADOPT-09
[[ "$(portable_hash "${integration_env}")" == "$(<"${integration_root}/base-env-before.sha256")" ]] || fail NF-ADOPT-09
db_counts "${integration_root}/counts-after-rollback" || fail NF-ADOPT-09
cmp -s "${integration_root}/counts-before-rollback" "${integration_root}/counts-after-rollback" || fail NF-ADOPT-09
[[ "$(sudo sha256sum "${runtime_parent}/notifier/mailer/queue.db" | awk '{print $1}')" == "$(<"${integration_root}/queue-before-rollback.sha256")" ]] || fail NF-ADOPT-09
private acceptance verify-baseline || fail NF-ADOPT-09
private compose_base exec -T mattermost mmctl plugin list --local --suppress-warnings --json || fail NF-ADOPT-09
if ! sudo test -d "${runtime_parent}/notifier/rollback/removed-runtime" \
    || ! sudo test -f "${runtime_parent}/notifier/rollback/removed-bundle.tar.gz"; then
    fail NF-ADOPT-09
fi

# NF-ADOPT-08 is proven by the SMTP fixture's generic-content parser, which
# accepts only https://<domain>/_redirect/pl/<post-id> and no Team URL segment.
grep -Fq 'NF-ADOPT-08' "${scenario_file}" || fail NF-ADOPT-08

# CI sets this only on a job that depends on the fresh real-image integration.
# Standalone runs execute the fresh harness directly.
if [[ "${FRESH_INTEGRATION_VERIFIED:-false}" != true ]]; then
    private "${script_dir}/run.sh" || fail NF-ADOPT-10
fi

result_kind=success
result_assertion=NF-ADOPT-10
