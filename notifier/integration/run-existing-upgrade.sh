#!/usr/bin/env bash

set -Eeuo pipefail

exec 3>&1
exec >/dev/null 2>&1
umask 077

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
notifier_root="$(cd -- "${script_dir}/.." && pwd -P)"
repository_root="$(cd -- "${notifier_root}/.." && pwd -P)"
compose_file="${script_dir}/existing/docker-compose.yml"
scenario_file="${script_dir}/existing-upgrade-scenario-ids.txt"
primary_diagnostic="${repository_root}/deploy/scripts/existing-notifier-v010-v020-diagnostic.sh"
source_commit=c193155eeb6298771d4366d6af4cae81499487b8
source_version=0.1.0
target_version=0.2.0
result_output_path="${INTEGRATION_RESULT_FILE:-}"
public_evidence_output_path="${INTEGRATION_PUBLIC_EVIDENCE_FILE:-}"
safe_diagnostic_output_path="${INTEGRATION_SAFE_DIAGNOSTIC_FILE:-}"
progress_output_path="${INTEGRATION_PROGRESS_FILE:-}"

suite_root=""
source_root=""
integration_root=""
runtime_parent=""
integration_env=""
notifier_env=""
project_name=""
diagnostic_file=""
acceptance_binary=""
result_kind=failure
result_assertion=NF-UPGRADE-01
result_stage=bootstrap
case_active=false
source_bundle_created=false
target_bundle_created=false

declare -a docker_command=()
declare -a privileged_docker_command=()

fail() {
    result_assertion="$1"
    exit 1
}

record_stage() {
    local stage="$1"
    local temporary=""

    [[ "${stage}" =~ ^[a-z0-9-]+$ ]] || return 1
    result_stage="${stage}"
    [[ -n "${progress_output_path}" ]] || return 0
    temporary="${progress_output_path}.tmp.$$"
    [[ "${progress_output_path}" == /* && -d "$(dirname -- "${progress_output_path}")" \
        && ! -e "${temporary}" && ! -L "${temporary}" ]] || return 1
    printf 'stage=%s\nelapsed_seconds=%s\n' "${stage}" "${SECONDS}" >"${temporary}"
    chmod 0644 "${temporary}"
    mv -f -- "${temporary}" "${progress_output_path}"
}

record_scenario() {
    local scenario="$1"
    grep -Fxq "${scenario}" "${scenario_file}" || return 1
    grep -Fxq "${scenario}" "${suite_root}/passed-scenarios" 2>/dev/null && return 1
    printf '%s\n' "${scenario}" >>"${suite_root}/passed-scenarios"
}

private() {
    "$@" >>"${diagnostic_file}" 2>&1
}

portable_hash() {
    sha256sum "$1" | awk '{print $1}'
}

privileged_hash() {
    sudo sha256sum "$1" | awk '{print $1}'
}

version_value() {
    awk -F= -v key="$1" '
        $1 == key { count++; value=substr($0,index($0,"=")+1) }
        END { if (count != 1 || value == "") exit 1; print value }
    ' "${repository_root}/deploy/versions.env"
}

compose_base() {
    "${docker_command[@]}" compose \
        --project-directory "${script_dir}/existing" \
        --env-file "${integration_env}" -f "${compose_file}" "$@"
}

compose_combined() {
    "${privileged_docker_command[@]}" compose \
        --project-directory "${script_dir}/existing" \
        --env-file "${integration_env}" -f "${compose_file}" \
        --env-file "${notifier_env}" -f "${runtime_parent}/notifier/compose.override.yml" "$@"
}

run_source() {
    timeout --foreground --kill-after=10s 300s env \
        "THREADHUB_EXISTING_NOTIFIER_ENV_FILE=${notifier_env}" \
        "${source_root}/deploy/scripts/$1" "${@:2}"
}

run_current() {
    timeout --foreground --kill-after=10s 300s env \
        "THREADHUB_EXISTING_NOTIFIER_ENV_FILE=${notifier_env}" \
        "${repository_root}/deploy/scripts/$1" "${@:2}"
}

run_current_stdin() {
    local input_file="$1"
    shift
    timeout --foreground --kill-after=10s 300s env \
        "THREADHUB_EXISTING_NOTIFIER_ENV_FILE=${notifier_env}" \
        "$@" <"${input_file}"
}

acceptance() {
    EXISTING_ACCEPTANCE_STATE_FILE="${integration_root}/acceptance-state.json" \
    EXISTING_ACCEPTANCE_SNAPSHOT_FILE="${integration_root}/capture-before.json" \
    EXISTING_ACCEPTANCE_ADMIN_PASSWORD="${admin_password}" \
    EXISTING_ACCEPTANCE_USER_PASSWORD="${user_password}" \
    EXISTING_ACCEPTANCE_HASH_SECRET="${hash_secret}" \
        "${acceptance_binary}" "$@"
}

acceptance_outage_failure_class() {
    local output="$1"

    if [[ "${output}" =~ ^existing\ adoption\ acceptance\ failed\ phase=(delivery-delta|unavailable)\ reason=(capture-unavailable|no-deliveries|under-delivery|over-delivery|mixed-count|content-mismatch)$ ]]; then
        printf '%s' "${BASH_REMATCH[2]}"
    else
        printf '%s' unavailable
    fi
}

acceptance_assert_outage() {
    local output=""
    local status=0
    local failure_class=""

    set +e
    output="$(acceptance assert-outage 2>&1)"
    status=$?
    set -e
    [[ -z "${output}" ]] || printf '%s\n' "${output}" >>"${diagnostic_file}"
    if [[ "${status}" -eq 0 ]]; then
        return 0
    fi
    failure_class="$(acceptance_outage_failure_class "${output}")"
    record_stage "successful-transition-outage-recovery-${failure_class}" || true
    return 1
}

preflight_failure_class() {
    local output="$1"

    case "${output}" in
        *"Legacy notifier configuration is not the exact v0.1.0 source"*) printf '%s' source-config ;;
        *"Legacy notifier configuration could not be validated safely"*) printf '%s' target-config ;;
        *"Legacy notifier runtime paths are incomplete or unsafe"*) printf '%s' runtime-paths ;;
        *"Legacy notifier inputs could not be fingerprinted"*) printf '%s' input-fingerprint ;;
        *"Legacy Compose configuration could not be inspected"*) printf '%s' compose ;;
        *"Legacy Compose model is not the exact supported source"*) printf '%s' source-model ;;
        *"PostgreSQL service is ambiguous"*) printf '%s' postgres-service ;;
        *"Exactly one Mattermost container is required"*) printf '%s' mattermost-count ;;
        *"Exactly one PostgreSQL container is required"*) printf '%s' postgres-count ;;
        *"Exactly one legacy Mailer container is required"*) printf '%s' mailer-count ;;
        *"All exact source containers must be running and healthy"*) printf '%s' container-health ;;
        *"Live Mattermost, PostgreSQL, or Site URL identity is unsupported"*) printf '%s' runtime-identity ;;
        *"Legacy notifier release identity is not exact"*) printf '%s' release-identity ;;
        *"Legacy notifier plugin pair is incomplete, inactive, or unreviewed"*) printf '%s' plugin-pair ;;
        *"Running legacy Mailer image does not match its release"*) printf '%s' mailer-image ;;
        *"Legacy Mailer aggregate status is unavailable or unsafe"*) printf '%s' mailer-status ;;
        *"Current remote-backup and disposable-restore review is required"*) printf '%s' recovery-gate ;;
        *"Compose inputs changed during preflight"*) printf '%s' compose-changed ;;
        *"Legacy notifier inputs changed during preflight"*) printf '%s' input-changed ;;
        *"Legacy notifier identity changed during preflight"*) printf '%s' identity-changed ;;
        *) printf '%s' unavailable ;;
    esac
}

run_transition_preflight() {
    local output=""
    local status=0
    local failure_class=""

    set +e
    output="$(run_current existing-notifier-v010-v020-preflight.sh 2>&1)"
    status=$?
    set -e
    [[ -z "${output}" ]] || printf '%s\n' "${output}" >>"${diagnostic_file}"
    if [[ "${status}" -eq 0 ]]; then
        return 0
    fi
    failure_class="$(preflight_failure_class "${output}")"
    record_stage "transition-evidence-preflight-${failure_class}" || true
    return 1
}

evidence_capture_failure_class() {
    local output_file="$1"
    local stage=""

    for stage in \
        attempt-created control-disabled mailer-stopped queue-inspected-v1 queue-captured \
        source-plugin-pair-captured source-mailer-image-saved source-release-captured \
        source-override-captured source-env-captured source-control-captured baseline-captured \
        evidence-verified; do
        if grep -Fxq "[threadhub] ERROR: notifier evidence capture halted at stage: ${stage}" \
            "${output_file}"; then
            printf '%s' "${stage}"
            return 0
        fi
    done
    printf '%s' unavailable
}

transaction_failure_class() {
    local output_file="$1"
    local phase=""

    for phase in \
        source_captured target_release_verified target_env_published target_release_published \
        target_override_published target_plugin_pair_published target_mailer_started \
        target_queue_v2_verified target_mattermost_recreated target_pair_verified \
        after_baseline_captured baseline_matched disabled_verified; do
        if grep -Fxq "[threadhub] ERROR: notifier transition halted after phase: ${phase}" \
            "${output_file}"; then
            printf '%s' "transaction-after-${phase//_/-}"
            return 0
        fi
    done
    printf '%s' unavailable
}

plugin_publish_failure_class() {
    local output_file="$1"
    local stage=""

    for stage in target-extracted source-hashed source-verified target-staged \
        filesystem-verified mattermost-stopped pair-transacted; do
        if grep -Fxq "[threadhub] ERROR: notifier plugin publication halted at stage: ${stage}" \
            "${output_file}"; then
            printf '%s' "plugin-publish-${stage}"
            return 0
        fi
    done
    printf '%s' unavailable
}

plugin_staging_failure_class() {
    local output_file="$1"
    local phase=""

    for phase in checksum-validation reviewed-bundle-validation \
        reviewed-runtime-validation reviewed-runtime-empty reviewed-runtime-missing \
        reviewed-runtime-not-directory reviewed-runtime-privileged-only \
        reviewed-runtime-symlink scratch-root-validation \
        bundle-integrity-validation destination-absence-validation \
        runtime-root-creation entry-listing runtime-materialization \
        bundle-materialization runtime-verification bundle-verification; do
        if grep -Fxq "[threadhub] ERROR: notifier plugin staging halted at phase: ${phase}" \
            "${output_file}"; then
            printf '%s' "${phase}"
            return 0
        fi
    done
    printf '%s' unavailable
}

upgrade_failure_class() {
    local status="$1"
    local output_file="$2"
    local stage=""
    local capture_class=""
    local transaction_class=""
    local plugin_publish_class=""
    local plugin_staging_class=""

    capture_class="$(evidence_capture_failure_class "${output_file}")"
    if [[ "${capture_class}" != unavailable ]]; then
        printf '%s' "capture-${capture_class}"
        return 0
    fi
    plugin_staging_class="$(plugin_staging_failure_class "${output_file}")"
    if [[ "${plugin_staging_class}" != unavailable ]]; then
        printf '%s' "plugin-staging-${plugin_staging_class}"
        return 0
    fi
    plugin_publish_class="$(plugin_publish_failure_class "${output_file}")"
    if [[ "${plugin_publish_class}" != unavailable ]]; then
        printf '%s' "${plugin_publish_class}"
        return 0
    fi
    transaction_class="$(transaction_failure_class "${output_file}")"
    if [[ "${transaction_class}" != unavailable ]]; then
        printf '%s' "${transaction_class}"
        return 0
    fi

    for stage in \
        preflight prepare-target-release recheck-preflight drain queue-zero disable \
        control-loaded-disabled stop-mailer capture-evidence transaction post-status-disabled; do
        if grep -Fxq "[threadhub] ERROR: notifier upgrade halted at stage: ${stage}" \
            "${output_file}"; then
            printf '%s' "${stage}"
            return 0
        fi
    done

    case "${status}" in
        1) printf '%s' failed ;;
        70) printf '%s' recovery-incomplete ;;
        124|137) printf '%s' timeout ;;
        *) printf '%s' unexpected ;;
    esac
}

upgrade_reached_acceptance_handoff() {
    grep -Fxq \
        '[ACTION REQUIRED] Run ./deploy/scripts/existing-notifier-smtp-test.sh, then activate a public/private test-channel allowlist.' \
        "$1"
}

wait_http() {
    local endpoint="$1"
    local deadline=$((SECONDS + $2))
    until curl --noproxy '*' --fail --silent --max-time 2 "${endpoint}" >/dev/null 2>&1; do
        ((SECONDS < deadline)) || return 1
        sleep 1
    done
}

queue_status_matches() {
    local expression="$1"
    local output="${integration_root}/queue-status.json"
    compose_combined exec -T threadhub-mailer /threadhub-mailer status --json \
        >"${output}" 2>>"${diagnostic_file}" || return 1
    jq -e "${expression}" "${output}" >/dev/null 2>&1
}

wait_queue_idle() {
    local deadline=$((SECONDS + 210))
    local failure_class=""
    local idle_stage_prefix="${result_stage}"
    until queue_status_matches '.pending == 0 and .sending == 0 and .failed == 0'; do
        if ((SECONDS >= deadline)); then
            failure_class="$(queue_idle_failure_class)"
            record_stage "${idle_stage_prefix}-${failure_class}" || true
            return 1
        fi
        sleep 1
    done
}

queue_idle_failure_class() {
    local output="${integration_root}/queue-status.json"

    if [[ ! -f "${output}" ]] || ! jq -e '
        type == "object" and
        (.pending | type == "number" and floor == . and . >= 0) and
        (.sending | type == "number" and floor == . and . >= 0) and
        (.failed | type == "number" and floor == . and . >= 0)
    ' "${output}" >/dev/null 2>&1; then
        printf '%s' status-unavailable
    elif jq -e '.failed > 0' "${output}" >/dev/null 2>&1; then
        printf '%s' failed
    elif jq -e '.sending > 0' "${output}" >/dev/null 2>&1; then
        printf '%s' sending
    elif jq -e '.pending > 0' "${output}" >/dev/null 2>&1; then
        printf '%s' pending
    else
        printf '%s' unexpected
    fi
}

queue_pending_failure_class() {
    local output="${integration_root}/queue-status.json"

    if [[ ! -f "${output}" ]] || ! jq -e '
        type == "object" and
        (.pending | type == "number" and floor == . and . >= 0) and
        (.sending | type == "number" and floor == . and . >= 0) and
        (.failed | type == "number" and floor == . and . >= 0)
    ' "${output}" >/dev/null 2>&1; then
        printf '%s' status-unavailable
    elif jq -e '.failed > 0' "${output}" >/dev/null 2>&1; then
        printf '%s' failed
    elif jq -e '.sending > 0' "${output}" >/dev/null 2>&1; then
        printf '%s' sending
    elif jq -e '.pending == 0' "${output}" >/dev/null 2>&1; then
        printf '%s' empty
    else
        printf '%s' unexpected
    fi
}

wait_queue_pending() {
    local deadline=$((SECONDS + 45))
    local failure_class=""
    local failure_stage=""
    until queue_status_matches '.pending > 0 and .sending == 0 and .failed == 0'; do
        if ((SECONDS >= deadline)); then
            failure_class="$(queue_pending_failure_class)"
            case "${failure_class}" in
                status-unavailable) failure_stage=successful-transition-queue-pending-status-unavailable ;;
                empty) failure_stage=successful-transition-queue-pending-empty ;;
                sending) failure_stage=successful-transition-queue-pending-sending ;;
                failed) failure_stage=successful-transition-queue-pending-failed ;;
                *) failure_stage=successful-transition-queue-pending-unexpected ;;
            esac
            record_stage "${failure_stage}" || true
            return 1
        fi
        sleep 1
    done
}

inject_smtp_failures() {
    local count="$1"
    local attempt=0
    local code=""
    while ((attempt < count)); do
        code="$(curl --noproxy '*' --silent --max-time 2 --output /dev/null \
            --write-out '%{http_code}' --request POST 'http://127.0.0.1:49353/v1/fail-next')" || return 1
        [[ "${code}" == 204 ]] || return 1
        attempt=$((attempt + 1))
    done
}

db_counts() {
    local output="$1"
    compose_base exec -T postgres psql -X -A -t -U threadhub -d threadhub -c \
        "SELECT json_build_object('teams',(SELECT count(*) FROM teams),'channels',(SELECT count(*) FROM channels),'channel_members',(SELECT count(*) FROM channelmembers),'active_users',(SELECT count(*) FROM users WHERE deleteat = 0 AND username <> 'system-bot'),'inactive_users',(SELECT count(*) FROM users WHERE deleteat <> 0 AND username <> 'system-bot'),'posts',(SELECT count(*) FROM posts),'files',(SELECT count(*) FROM fileinfo));" \
        >"${output}" 2>>"${diagnostic_file}"
    jq -e 'type == "object" and ([.teams,.channels,.channel_members,.active_users,.inactive_users,.posts,.files] | all(type == "number" and floor == . and . >= 0))' \
        "${output}" >/dev/null 2>&1
}

queue_inspect() {
    local output="$1"
    "${privileged_docker_command[@]}" run --rm --pull never --network none --read-only \
        --cap-drop ALL --security-opt no-new-privileges --user 65532:65532 \
        --mount "type=bind,src=${runtime_parent}/notifier/mailer,dst=/var/lib/threadhub-notifier,readonly" \
        "threadhub/notifier-mailer:${target_version}" queue-inspect --json >"${output}"
}

release_value() {
    sudo awk -F= -v key="$1" '
        $1 == key { count++; value=substr($0,index($0,"=")+1) }
        END { if (count != 1 || value == "") exit 1; print value }
    ' "$2"
}

verify_source_runtime() {
    local inspection="${integration_root}/source-queue-inspection.json"
    [[ "$(release_value NOTIFIER_VERSION "${runtime_parent}/notifier/release/release.env")" == "${source_version}" ]] \
        && [[ "$(release_value NOTIFIER_SOURCE_COMMIT "${runtime_parent}/notifier/release/release.env")" == "${source_commit}" ]] \
        && [[ "$(awk -F= '$1 == "THN_CONTENT_MODE" { count++ } END { print count+0 }' "${notifier_env}")" == 0 ]] \
        || return 1
    compose_combined exec -T threadhub-mailer /threadhub-mailer healthcheck >/dev/null \
        || return 1
    if "${docker_command[@]}" image inspect "threadhub/notifier-mailer:${target_version}" >/dev/null 2>&1; then
        queue_inspect "${inspection}" || return 1
        jq -e '.schema_version == 1' "${inspection}" >/dev/null
    fi
}

verify_target_runtime() {
    local inspection="${integration_root}/target-queue-inspection.json"
    local control="${runtime_parent}/notifier/control/state.json"
    [[ "$(release_value NOTIFIER_VERSION "${runtime_parent}/notifier/release/release.env")" == "${target_version}" ]] \
        && [[ "$(release_value NOTIFIER_SOURCE_COMMIT "${runtime_parent}/notifier/release/release.env")" == "$(git -C "${repository_root}" rev-parse --verify 'HEAD^{commit}')" ]] \
        && [[ "$(awk -F= '$1 == "THN_CONTENT_MODE" { count++; value=$2 } END { if (count != 1) exit 1; print value }' "${notifier_env}")" == project_team_channel ]] \
        || return 1
    compose_combined exec -T threadhub-mailer /threadhub-mailer queue-inspect --json >"${inspection}" || return 1
    jq -e '.schema_version == 2' "${inspection}" >/dev/null \
        && sudo jq -e '.enabled == false and .delivery_enabled == false' "${control}" >/dev/null
}

write_recovery_gate() {
    local migration="${runtime_parent}/notifier/migration"
    local temporary="${integration_root}/recovery-gate.json"
    sudo install -d -o 0 -g 0 -m 0700 "${migration}" || return 1
    jq -n --arg profile existing-notifier-v010-v020 --arg commit "${source_commit}" \
        --arg reviewed "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" '{
          schema:1,profile:$profile,source_release_commit:$commit,
          remote_backup_verified:true,disposable_restore_verified:true,
          aggregate_match_verified:true,restored_queue_quarantined:true,
          reviewed_at_utc:$reviewed
        }' >"${temporary}"
    sudo install -o 0 -g 0 -m 0600 "${temporary}" "${migration}/recovery-gate-v010-v020.json"
    private run_current existing-notifier-v010-v020-recovery-gate.sh check
}

activate_source_all_channels() {
    local state="${integration_root}/source-active-state.json"
    jq -n --argjson now "$(( $(date -u +%s) * 1000 ))" \
        '{enabled:true,delivery_enabled:true,mode:"all_channels",channel_ids:[],activated_at:$now}' >"${state}"
    sudo install -o 0 -g 3000 -m 0640 "${state}" "${runtime_parent}/notifier/control/state.json"
    sleep 2
}

connect_smtp_fixture() {
    local container
    container="$(compose_base ps -q smtp-fixture)"
    [[ "${container}" =~ ^[a-f0-9]{12,64}$ ]] || return 1
    "${docker_command[@]}" network connect \
        --alias smtp.email.ap-singapore-1.oci.oraclecloud.com \
        "${project_name}_threadhub-notifier-outbound" "${container}"
}

case_teardown() {
    local cleanup_ok=true
    set +e
    if [[ "${case_active}" == true ]]; then
        if sudo test -f "${runtime_parent}/notifier/compose.override.yml"; then
            compose_combined down --volumes --remove-orphans --timeout 10 >/dev/null 2>&1 || cleanup_ok=false
        else
            compose_base down --volumes --remove-orphans --timeout 10 >/dev/null 2>&1 || cleanup_ok=false
        fi
        case "${runtime_parent}" in
            /var/tmp/threadhub-existing-upgrade-[a-z0-9_-]*)
                sudo test ! -e "${runtime_parent}" || sudo rm -rf -- "${runtime_parent}" || cleanup_ok=false ;;
            *) cleanup_ok=false ;;
        esac
        case "${integration_root}" in
            "${suite_root}"/case-*)
                sudo test ! -e "${integration_root}" || sudo rm -rf -- "${integration_root}" || cleanup_ok=false ;;
            *) cleanup_ok=false ;;
        esac
    fi
    case_active=false
    set -e
    [[ "${cleanup_ok}" == true ]]
}

case_setup() {
    local label="$1"
    local setup_status=0
    local smtp_container=""
    local source_bundle=""
    local current_source_bundle="${repository_root}/notifier/dist/com.threadhub.channel-email-notifier-${source_version}.tar.gz"

    integration_root="${suite_root}/case-${label}"
    project_name="threadhub-upgrade-${label}-$(openssl rand -hex 4)"
    runtime_parent="/var/tmp/threadhub-existing-upgrade-${project_name}"
    integration_env="${integration_root}/.env"
    notifier_env="${integration_root}/existing-notifier.env"
    mkdir -p "${integration_root}/data/postgres" \
        "${integration_root}/data/mattermost/config" "${integration_root}/data/mattermost/data" \
        "${integration_root}/data/mattermost/logs" "${integration_root}/data/mattermost/plugins" \
        "${integration_root}/data/mattermost/client/plugins" "${integration_root}/data/mattermost/bleve-indexes" \
        "${integration_root}/data/smtp-private" "${integration_root}/data/smtp-ca"
    sudo chown -R 999:999 "${integration_root}/data/postgres"
    sudo chown -R 2000:2000 "${integration_root}/data/mattermost"
    sudo chmod 0750 "${integration_root}/data/mattermost/plugins" "${integration_root}/data/mattermost/data"
    sudo chown -R 65532:65532 "${integration_root}/data/smtp-private" "${integration_root}/data/smtp-ca"
    sudo install -d -o 0 -g 0 -m 0750 "${runtime_parent}"
    case_active=true

    db_password="$(openssl rand -hex 32)"
    hmac_secret="$(openssl rand -hex 32)"
    hash_secret="$(openssl rand -hex 32)"
    smtp_password="$(openssl rand -hex 32)"
    admin_password="Aa1!$(openssl rand -hex 24)"
    user_password="Bb2!$(openssl rand -hex 24)"
    printf '%s\n' "${db_password}" "${hmac_secret}" "${hash_secret}" "${smtp_password}" \
        "${admin_password}" "${user_password}" >>"${suite_root}/privacy-patterns"
    cat >"${integration_env}" <<EOF
COMPOSE_PROJECT_NAME=${project_name}
MATTERMOST_IMAGE_REPOSITORY=mattermost/mattermost-team-edition
MATTERMOST_IMAGE_TAG=11.7.7
MATTERMOST_IMAGE_DIGEST=sha256:d23471992cb1e3b57807bdc0b45aa7a7982e290ac310a7dc4b85a7ccacdbdff1
POSTGRES_IMAGE_REPOSITORY=postgres
POSTGRES_IMAGE_TAG=18.4
POSTGRES_IMAGE_DIGEST=sha256:d93de42662696f278fb34354b06fdaa90ad7ca3106d6f72fbd01d16da006d2cf
GO_BUILDER_IMAGE_REPOSITORY=${go_repository}
GO_BUILDER_IMAGE_TAG=${go_tag}
GO_BUILDER_IMAGE_DIGEST=${go_digest}
NOTIFIER_VERSION=${target_version}
INTEGRATION_DATA_ROOT=${integration_root}/data
INTEGRATION_DB_PASSWORD=${db_password}
INTEGRATION_SMTP_PASSWORD=${smtp_password}
INTEGRATION_HASH_SECRET=${hash_secret}
EOF
    chmod 0600 "${integration_env}"
    cat >"${notifier_env}" <<EOF
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
    chmod 0600 "${notifier_env}"
    portable_hash "${compose_file}" >"${integration_root}/base-compose-before.sha256"
    portable_hash "${integration_env}" >"${integration_root}/base-env-before.sha256"

    private compose_base config --quiet
    private compose_base up -d --no-build --wait --wait-timeout 180 postgres smtp-fixture
    private compose_base up -d --no-build mattermost
    private wait_http 'http://127.0.0.1:49153/api/v4/system/ping' 180
    sudo chown root:root "${integration_root}/data/smtp-ca/ca.crt"
    sudo chmod 0644 "${integration_root}/data/smtp-ca/ca.crt"
    sudo chown root:root "${integration_root}/data/smtp-ca"
    sudo chmod 0755 "${integration_root}/data/smtp-ca"
    private compose_base exec -T mattermost mmctl user create \
        --local --suppress-warnings --username existing-admin \
        --email admin@integration.invalid --password "${admin_password}" \
        --system-admin --email-verified
    private acceptance bootstrap
    private compose_base exec -T mattermost mmctl user verify existing-recipient-a --local --suppress-warnings
    private compose_base exec -T mattermost mmctl user verify existing-recipient-b --local --suppress-warnings

    set +e
    private run_source existing-notifier-setup.sh --resume --non-interactive
    setup_status=$?
    set -e
    [[ "${setup_status}" == 20 ]] || return 1
    source_bundle="${source_root}/$(release_value NOTIFIER_PLUGIN_BUNDLE "${runtime_parent}/notifier/release/release.env")"
    if [[ -e "${current_source_bundle}" ]]; then
        cmp -s "${source_bundle}" "${current_source_bundle}" || return 1
    else
        install -d -m 0755 "$(dirname "${current_source_bundle}")"
        install -m 0644 "${source_bundle}" "${current_source_bundle}"
        source_bundle_created=true
    fi
    private connect_smtp_fixture
    printf '%s\n' probe@integration.invalid >"${integration_root}/smtp-recipient"
    private run_current_stdin "${integration_root}/smtp-recipient" \
        "${source_root}/deploy/scripts/existing-notifier-smtp-test.sh" --recipient-stdin
    private activate_source_all_channels
    private verify_source_runtime
    smtp_container="$(compose_base ps -q smtp-fixture)"
    [[ "${smtp_container}" =~ ^[a-f0-9]{12,64}$ ]]
}

seed_source_queue_history() {
    record_stage successful-transition-queue-snapshot
    private acceptance snapshot || return 1
    record_stage successful-transition-smtp-failure-injection
    private inject_smtp_failures 2 || return 1
    record_stage successful-transition-outage-post
    private acceptance outage-post || return 1
    record_stage successful-transition-queue-pending
    private wait_queue_pending || return 1
    record_stage successful-transition-outage-recovery
    acceptance_assert_outage || return 1
    record_stage successful-transition-queue-idle
    private wait_queue_idle || return 1
}

prepare_transition_evidence() {
    record_stage transition-evidence-env-hash
    portable_hash "${notifier_env}" >"${integration_root}/source-env-before.sha256"
    record_stage transition-evidence-release-hash
    sudo find "${runtime_parent}/notifier/release" -type f -exec sha256sum {} + | sort \
        >"${integration_root}/source-release-before.sha256"
    record_stage transition-evidence-override-hash
    privileged_hash "${runtime_parent}/notifier/compose.override.yml" >"${integration_root}/source-override-before.sha256"
    record_stage transition-evidence-db-counts
    db_counts "${integration_root}/counts-before-transition"
    record_stage transition-evidence-recovery-gate
    write_recovery_gate
    record_stage transition-evidence-preflight
    private run_transition_preflight
}

run_successful_transition() {
    local status=0
    local failure_class=""
    local upgrade_output="${integration_root}/upgrade-output"

    record_stage successful-transition-upgrade
    set +e
    run_current existing-notifier-v010-v020-upgrade.sh >"${upgrade_output}" 2>&1
    status=$?
    set -e
    cat "${upgrade_output}" >>"${diagnostic_file}"
    if [[ "${status}" != 20 ]] || ! upgrade_reached_acceptance_handoff "${upgrade_output}"; then
        failure_class="$("${primary_diagnostic}" primary-failure "${status}" "${upgrade_output}")" \
            || failure_class="$(upgrade_failure_class "${status}" "${upgrade_output}")"
        record_stage "successful-transition-upgrade-${failure_class}" || true
        return 1
    fi
    record_stage successful-transition-target-runtime
    verify_target_runtime
    record_stage successful-transition-db-counts
    db_counts "${integration_root}/counts-after-transition"
    record_stage successful-transition-db-count-compare
    cmp -s "${integration_root}/counts-before-transition" "${integration_root}/counts-after-transition"
    record_stage successful-transition-base-compose-hash
    [[ "$(portable_hash "${compose_file}")" == "$(<"${integration_root}/base-compose-before.sha256")" ]]
    record_stage successful-transition-base-env-hash
    [[ "$(portable_hash "${integration_env}")" == "$(<"${integration_root}/base-env-before.sha256")" ]]
    record_stage successful-transition-source-queue-schema
    sudo jq -e '.schema_version == 1' "${runtime_parent}/notifier/migration/existing-notifier-v010-v020/queue-inspection.json" >/dev/null
    record_stage successful-transition-target-queue-schema
    sudo jq -e '.schema_version == 2' "${runtime_parent}/notifier/migration/existing-notifier-v010-v020/target-queue-inspection.json" >/dev/null
}

accept_target_context() {
    local channels="${integration_root}/allowlist-channels"
    private run_current_stdin "${integration_root}/smtp-recipient" \
        "${repository_root}/deploy/scripts/existing-notifier-smtp-test.sh" --recipient-stdin
    jq -r '[.public_channel_id,.private_channel_id] | join(",")' \
        "${integration_root}/acceptance-state.json" >"${channels}"
    private run_current_stdin "${channels}" \
        "${repository_root}/deploy/scripts/existing-notifier-control.sh" \
        activate-allowlist --channel-ids-stdin
    record_stage public-root
    record_stage public-thread
    record_stage private-root
    record_stage private-thread
    private acceptance exercise-context
    private wait_queue_idle
}

explicit_rollback() {
    local rollback_before="${integration_root}/counts-before-explicit-rollback"
    local rollback_driver="${integration_root}/explicit-rollback.sh"
    local rollback_output="${integration_root}/rollback-output"
    local recovery_stage=""
    local rollback_stage=""
    local status=0
    db_counts "${rollback_before}"
    private run_current existing-notifier-control.sh drain
    private wait_queue_idle
    private run_current existing-notifier-control.sh disable
    # The production TTY and exact-confirmation gates are covered by the
    # operations tests. Keep this real-image test non-interactive so Docker or
    # sudo pre-review checks cannot consume a pre-buffered pseudo-TTY response.
    cat >"${rollback_driver}" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
source "${repository_root}/deploy/scripts/existing-notifier-v010-v020-rollback.sh"
existing_notifier_v010_v020_rollback_stdin_is_tty() { return 0; }
existing_notifier_v010_v020_rollback_read_confirmation() {
    printf '%s\n' 'I REVIEWED V0.2.0 PILOT DELIVERY ROLLBACK'
}
existing_notifier_v010_v020_rollback
EOF
    chmod 0700 "${rollback_driver}"
    set +e
    timeout --foreground --kill-after=10s 480s env \
        "THREADHUB_EXISTING_NOTIFIER_ENV_FILE=${notifier_env}" \
        "${rollback_driver}" >"${rollback_output}" 2>&1
    status=$?
    set -e
    cat "${rollback_output}" >>"${diagnostic_file}"
    if [[ "${status}" != 0 ]]; then
        rollback_stage="$(sed -n \
            's/^\[threadhub\] notifier rollback stage: \([a-z0-9-]*\)\r*$/\1/p' \
            "${rollback_output}" | tail -n 1)"
        if [[ "${rollback_stage}" == recover-source ]]; then
            recovery_stage="$(sed -n \
                's/^\[threadhub\] notifier source recovery stage: \([a-z0-9-]*\)\r*$/\1/p' \
                "${rollback_output}" | tail -n 1)"
            case "${recovery_stage}" in
                capture-validation|disposition-roots|queue|environment|release|override|plugin-pair|control|mailer-image|compose-init|mattermost-start|mailer-start|source-runtime-verify)
                    rollback_stage="recover-source-${recovery_stage}"
                    ;;
            esac
        fi
        case "${rollback_stage}" in
            validate-capture|validate-phase|require-disabled|require-quiescent-target|require-pilot-review|capture-current-baseline|stop-target-mailer|recover-source|recover-source-capture-validation|recover-source-disposition-roots|recover-source-queue|recover-source-environment|recover-source-release|recover-source-override|recover-source-plugin-pair|recover-source-control|recover-source-mailer-image|recover-source-compose-init|recover-source-mattermost-start|recover-source-mailer-start|recover-source-source-runtime-verify|verify-source-disabled|compare-source-baseline|mark-source-recovered)
                record_stage "explicit-rollback-${rollback_stage}" || true
                ;;
            *) record_stage explicit-rollback-unavailable || true ;;
        esac
        return 1
    fi
    verify_source_runtime
    [[ "$(portable_hash "${notifier_env}")" == "$(<"${integration_root}/source-env-before.sha256")" ]]
    [[ "$(privileged_hash "${runtime_parent}/notifier/compose.override.yml")" == "$(<"${integration_root}/source-override-before.sha256")" ]]
    sudo find "${runtime_parent}/notifier/release" -type f -exec sha256sum {} + | sort \
        >"${integration_root}/source-release-after.sha256"
    cmp -s "${integration_root}/source-release-before.sha256" "${integration_root}/source-release-after.sha256"
    db_counts "${integration_root}/counts-after-explicit-rollback"
    cmp -s "${rollback_before}" "${integration_root}/counts-after-explicit-rollback"
    private acceptance verify-baseline
}

run_fault_transition() {
    local hook="$1"
    local renamed="$2"
    local status=0
    local fault_script="${integration_root}/fault-transition.sh"
    cat >"${fault_script}" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
source "${repository_root}/deploy/scripts/existing-notifier-v010-v020-upgrade.sh"
eval "\$(declare -f ${hook} | sed '1s/${hook}/${renamed}/')"
${hook}() {
    ${renamed} "\$@" || return \$?
    return 42
}
existing_notifier_v010_v020_upgrade
EOF
    chmod 0700 "${fault_script}"
    set +e
    private timeout --foreground --kill-after=10s 300s env \
        "THREADHUB_EXISTING_NOTIFIER_ENV_FILE=${notifier_env}" "${fault_script}"
    status=$?
    set -e
    [[ "${status}" == 42 ]] || return 1
    # shellcheck disable=SC2016 # the nested bash, not this harness, expands the sourced helper call
    private env "THREADHUB_EXISTING_NOTIFIER_ENV_FILE=${notifier_env}" bash -c \
        'source "$1"; existing_notifier_v010_v020_upgrade_initialize; existing_notifier_v010_v020_verify_source_runtime "$(existing_notifier_v010_v020_attempt_root)"' \
        bash "${repository_root}/deploy/scripts/existing-notifier-v010-v020-upgrade.sh"
}

cleanup() {
    local incoming=$?
    local cleanup_ok=true
    local safe_result="${result_assertion}"
    trap - EXIT HUP INT TERM
    set +e
    case_teardown || cleanup_ok=false
    if [[ "${source_bundle_created}" == true ]]; then
        rm -f -- "${repository_root}/notifier/dist/com.threadhub.channel-email-notifier-${source_version}.tar.gz" || cleanup_ok=false
    fi
    if [[ "${target_bundle_created}" == true ]]; then
        rm -f -- "${repository_root}/notifier/dist/com.threadhub.channel-email-notifier-${target_version}.tar.gz" || cleanup_ok=false
    fi
    rmdir "${repository_root}/notifier/dist" >/dev/null 2>&1 || true
    if [[ "${result_kind}" == success && -f "${suite_root}/passed-scenarios" ]] \
        && diff -u "${scenario_file}" "${suite_root}/passed-scenarios" >/dev/null 2>&1; then
        safe_result="$(<"${scenario_file}")"
    else
        incoming=1
        result_kind=failure
    fi
    if [[ -n "${suite_root}" && -d "${suite_root}" ]]; then
        for protected in "${db_password:-}" "${hmac_secret:-}" "${hash_secret:-}" "${smtp_password:-}" \
            "${admin_password:-}" "${user_password:-}" integration-post '@integration.invalid'; do
            [[ -n "${protected}" ]] && printf '%s\n' "${protected}" >>"${suite_root}/privacy-patterns"
        done
        if grep -F -q -f "${suite_root}/privacy-patterns" "${diagnostic_file}" 2>/dev/null; then
            cleanup_ok=false
            incoming=1
            result_kind=failure
            safe_result=NF-UPGRADE-12
        fi
    fi
    if [[ "${cleanup_ok}" != true ]]; then
        incoming=1
        result_kind=failure
        safe_result=NF-UPGRADE-12
    fi
    if [[ -n "${result_output_path}" && ! -e "${result_output_path}" && ! -L "${result_output_path}" ]]; then
        printf '%s\n' "${safe_result}" >"${result_output_path}"
        chmod 0644 "${result_output_path}"
    fi
    if [[ -n "${public_evidence_output_path}" && "${result_kind}" == success \
        && ! -e "${public_evidence_output_path}" && ! -L "${public_evidence_output_path}" ]]; then
        {
            printf 'test_date=%s\n' "$(date -u +%F)"
            printf 'source_release_commit=%s\n' "${source_commit}"
            printf 'target_release_commit=%s\n' "$(git -C "${repository_root}" rev-parse --verify 'HEAD^{commit}')"
            printf 'nf_scenario_count=12\n'
            printf 'result=pass\n'
        } >"${public_evidence_output_path}"
        chmod 0644 "${public_evidence_output_path}"
    fi
    if [[ -n "${safe_diagnostic_output_path}" && ! -e "${safe_diagnostic_output_path}" \
        && ! -L "${safe_diagnostic_output_path}" ]]; then
        printf 'stage=%s\nresult=%s\n' "${result_stage}" "${result_kind}" >"${safe_diagnostic_output_path}"
        chmod 0644 "${safe_diagnostic_output_path}"
    fi
    case "${suite_root}" in
        "${temporary_base}"/threadhub-existing-upgrade.*)
            rm -rf -- "${suite_root}" || cleanup_ok=false ;;
        "") ;;
        *) cleanup_ok=false ;;
    esac
    if [[ "${result_kind}" == success && "${incoming}" == 0 && "${cleanup_ok}" == true ]]; then
        printf '%s\n' "${safe_result}" >&3
        exit 0
    fi
    printf '%s\n' "${safe_result}" >&3
    exit 1
}

trap cleanup EXIT
trap 'result_kind=failure; result_assertion=NF-UPGRADE-12; exit 130' HUP INT TERM

for required in awk bash cat chmod cmp cp curl date diff dirname docker env find git go grep id install jq mkdir mktemp mv openssl rm sed sha256sum sleep sort sudo tar timeout xargs; do
    command -v "${required}" >/dev/null 2>&1 || fail NF-UPGRADE-01
done
[[ "$(uname -s)" == Linux && "$(uname -m)" == x86_64 ]] || fail NF-UPGRADE-01
grep -Eq '^ID=ubuntu$' /etc/os-release || fail NF-UPGRADE-01
grep -Eq '^VERSION_ID="?24\.04"?$' /etc/os-release || fail NF-UPGRADE-01
[[ -f "${compose_file}" && -f "${scenario_file}" ]] || fail NF-UPGRADE-01
[[ "$(wc -l <"${scenario_file}" | tr -d '[:space:]')" == 12 ]] || fail NF-UPGRADE-01
[[ -z "$(git -C "${repository_root}" status --porcelain=v1 --untracked-files=all --ignore-submodules=none)" ]] || fail NF-UPGRADE-01
git -C "${repository_root}" cat-file -e "${source_commit}^{commit}" || fail NF-UPGRADE-01

if docker info >/dev/null 2>&1; then
    docker_command=(docker)
    privileged_docker_command=(sudo docker)
elif sudo docker info >/dev/null 2>&1; then
    docker_command=(sudo docker)
    privileged_docker_command=(sudo docker)
else
    fail NF-UPGRADE-01
fi

temporary_base="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
temporary_base="$(cd -- "${temporary_base}" && pwd -P)"
suite_root="$(mktemp -d "${temporary_base}/threadhub-existing-upgrade.XXXXXX")"
diagnostic_file="${suite_root}/diagnostic"
acceptance_binary="${suite_root}/existing-acceptance"
: >"${diagnostic_file}"
: >"${suite_root}/passed-scenarios"
: >"${suite_root}/privacy-patterns"
chmod 0600 "${diagnostic_file}" "${suite_root}/privacy-patterns"
source_root="${suite_root}/source-v010"
mkdir -p "${source_root}"
git -C "${repository_root}" archive --format=tar \
    "${source_commit}" | tar -xf - -C "${source_root}"
git -C "${source_root}" init --quiet
common_objects="$(git -C "${repository_root}" rev-parse --git-path objects)"
case "${common_objects}" in /*) ;; *) common_objects="${repository_root}/${common_objects}" ;; esac
mkdir -p "${source_root}/.git/objects/info"
printf '%s\n' "${common_objects}" >"${source_root}/.git/objects/info/alternates"
git -C "${source_root}" update-ref refs/heads/source "${source_commit}"
git -C "${source_root}" symbolic-ref HEAD refs/heads/source
git -C "${source_root}" read-tree "${source_commit}"
[[ -z "$(git -C "${source_root}" status --porcelain=v1 --untracked-files=all)" ]] || fail NF-UPGRADE-02

go_repository="$(version_value GO_BUILDER_IMAGE_REPOSITORY)" || fail NF-UPGRADE-01
go_tag="$(version_value GO_BUILDER_IMAGE_TAG)" || fail NF-UPGRADE-01
go_digest="$(version_value GO_BUILDER_IMAGE_DIGEST)" || fail NF-UPGRADE-01
[[ "$(version_value NOTIFIER_VERSION)" == "${target_version}" ]] || fail NF-UPGRADE-01
target_bundle_path="${repository_root}/notifier/dist/com.threadhub.channel-email-notifier-${target_version}.tar.gz"
[[ -e "${target_bundle_path}" ]] || target_bundle_created=true
private "${docker_command[@]}" build --platform linux/amd64 \
    --build-arg "GO_BUILDER_IMAGE=${go_repository}:${go_tag}@${go_digest}" \
    --target smtp-fixture --tag "threadhub/notifier-smtp-fixture:${target_version}" "${notifier_root}"
private env GOCACHE="${suite_root}/go-cache" go -C "${notifier_root}" build \
    -trimpath -o "${acceptance_binary}" ./integration/cmd/existing-acceptance
record_scenario NF-UPGRADE-01

record_stage successful-transition
case_setup success || fail NF-UPGRADE-02
record_scenario NF-UPGRADE-02
seed_source_queue_history || fail NF-UPGRADE-03
record_scenario NF-UPGRADE-03
prepare_transition_evidence || fail NF-UPGRADE-04
record_scenario NF-UPGRADE-04
run_successful_transition || fail NF-UPGRADE-05
record_scenario NF-UPGRADE-05
record_scenario NF-UPGRADE-06
accept_target_context || fail NF-UPGRADE-07
record_scenario NF-UPGRADE-07
record_stage explicit-rollback
explicit_rollback || fail NF-UPGRADE-08
record_scenario NF-UPGRADE-08
case_teardown || fail NF-UPGRADE-12

record_stage failure-after-plugin-publication
case_setup plugin-fault || fail NF-UPGRADE-09
prepare_transition_evidence || fail NF-UPGRADE-09
run_fault_transition v010_v020_tx_publish_target_plugin_pair v010_v020_real_publish_target_plugin_pair \
    || fail NF-UPGRADE-09
sudo test -d "${runtime_parent}/notifier/migration/existing-notifier-v010-v020/quarantine/plugin-runtime-v020" \
    || fail NF-UPGRADE-09
record_scenario NF-UPGRADE-09
case_teardown || fail NF-UPGRADE-12

record_stage failure-after-schema-migration
case_setup schema-fault || fail NF-UPGRADE-10
prepare_transition_evidence || fail NF-UPGRADE-10
run_fault_transition v010_v020_tx_inspect_target_queue_v2 v010_v020_real_inspect_target_queue_v2 \
    || fail NF-UPGRADE-10
sudo test -d "${runtime_parent}/notifier/migration/existing-notifier-v010-v020/quarantine/mailer-v020" \
    || fail NF-UPGRADE-10
record_scenario NF-UPGRADE-10
case_teardown || fail NF-UPGRADE-12

record_stage second-transition
case_setup second || fail NF-UPGRADE-11
prepare_transition_evidence || fail NF-UPGRADE-11
run_successful_transition || fail NF-UPGRADE-11
accept_target_context || fail NF-UPGRADE-11
private run_current existing-notifier-control.sh drain
private wait_queue_idle
private run_current existing-notifier-control.sh disable
record_scenario NF-UPGRADE-11
case_teardown || fail NF-UPGRADE-12

record_scenario NF-UPGRADE-12
result_kind=success
result_assertion=NF-UPGRADE-12
record_stage complete
