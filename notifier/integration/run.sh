#!/usr/bin/env bash

set -Eeuo pipefail

exec 3>&1
exec >/dev/null 2>&1
umask 077

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
notifier_root="$(cd -- "${script_dir}/.." && pwd -P)"
repository_root="$(cd -- "${notifier_root}/.." && pwd -P)"
# shellcheck source=./harness-lib.sh
source "${script_dir}/harness-lib.sh"
# shellcheck source=../../deploy/scripts/notifier-lib.sh
source "${repository_root}/deploy/scripts/notifier-lib.sh"
compose_file="${script_dir}/docker-compose.yml"
versions_file="${repository_root}/deploy/versions.env"
scenario_ids_file="${script_dir}/cmd/acceptance/scenario-ids.txt"
failure_assertions_file="${script_dir}/cmd/acceptance/failure-assertions.txt"
compose_command_value="${COMPOSE_COMMAND:-docker compose}"
container_command_value="${CONTAINER_COMMAND:-docker}"
result_output_path="${INTEGRATION_RESULT_FILE:-}"

integration_root=""
integration_env=""
control_file=""
project_name=""
project_touched=false
result_kind=failure
result_assertion=NF-HARNESS-config
result_source=""
diagnostic_file=""
bundle_container_id=""

declare -a compose_command=()
declare -a container_command=()
declare -a container_build_flags=()

is_failure_assertion() {
    [[ -f "${failure_assertions_file}" ]] && grep -F -x -q -- "$1" "${failure_assertions_file}"
}

abort_run() {
    if is_failure_assertion "$1"; then
        result_assertion="$1"
    else
        result_assertion=NF-HARNESS-compose
    fi
    result_kind=failure
    exit 1
}

compose_run() {
    "${compose_command[@]}" \
        --file "${compose_file}" \
        --env-file "${integration_env}" \
        --project-name "${project_name}" \
        "$@"
}

compose_private() {
    compose_run "$@" >>"${diagnostic_file}" 2>&1
}

container_private() {
    "${container_command[@]}" "$@" >>"${diagnostic_file}" 2>&1
}

# shellcheck disable=SC2329 # invoked by the EXIT/signal trap below
cleanup() {
    local incoming_status=$?
    local cleanup_ok=true
    local safe_output="${result_assertion}"
    local primary_failure=""
    local cleanup_assertion=""
    local cleanup_listing=""
    local artifact_parent=""

    trap - EXIT HUP INT TERM
    set +e

    if [[ "${result_kind}" == success && -f "${result_source}" ]]; then
        safe_output="$(<"${result_source}")"
    fi

    if [[ -n "${integration_root}" && -d "${integration_root}" ]]; then
        for protected in "${db_password:-}" "${hmac_secret:-}" "${hash_secret:-}" "${smtp_password:-}" "${admin_password:-}" "${user_password:-}" '@integration.invalid' integration-post; do
            [[ -n "${protected}" ]] || continue
            if grep -R -F -q -- "${protected}" \
                "${diagnostic_file:-/dev/null}" \
                "${integration_root}/acceptance-stderr" \
                "${integration_root}/data/mattermost/logs" 2>/dev/null; then
                cleanup_ok=false
                [[ -n "${cleanup_assertion}" ]] \
                    || cleanup_assertion=NF-HARNESS-compose-cleanup-privacy
            fi
        done
    fi

    if [[ -n "${bundle_container_id}" ]]; then
        if [[ "${bundle_container_id}" =~ ^[a-f0-9]{12,64}$ ]]; then
            if ! container_private container rm --force "${bundle_container_id}"; then
                cleanup_ok=false
                [[ -n "${cleanup_assertion}" ]] \
                    || cleanup_assertion=NF-HARNESS-compose-cleanup-container
            fi
        else
            cleanup_ok=false
            [[ -n "${cleanup_assertion}" ]] \
                || cleanup_assertion=NF-HARNESS-compose-cleanup-container
        fi
        bundle_container_id=""
    fi

    if [[ "${project_touched}" == true ]]; then
        if ! compose_run stop --timeout 10 >/dev/null 2>&1; then
            cleanup_ok=false
            [[ -n "${cleanup_assertion}" ]] \
                || cleanup_assertion=NF-HARNESS-compose-cleanup-project-down
        fi
        if ! compose_run run --rm --no-deps volume-cleanup >/dev/null 2>&1; then
            cleanup_ok=false
            [[ -n "${cleanup_assertion}" ]] \
                || cleanup_assertion=NF-HARNESS-compose-cleanup-workspace
        fi
        if ! compose_run down --volumes --remove-orphans --timeout 10 >/dev/null 2>&1; then
            cleanup_ok=false
            [[ -n "${cleanup_assertion}" ]] \
                || cleanup_assertion=NF-HARNESS-compose-cleanup-project-down
        fi
        cleanup_listing="${integration_root}/cleanup-ps"
        if ! compose_run ps --all --quiet >"${cleanup_listing}" 2>/dev/null \
            || [[ -s "${cleanup_listing}" ]]; then
            cleanup_ok=false
            [[ -n "${cleanup_assertion}" ]] \
                || cleanup_assertion=NF-HARNESS-compose-cleanup-project-residue
        fi
        if ! compose_run ls --format json >"${integration_root}/cleanup-projects" 2>/dev/null; then
            cleanup_ok=false
            [[ -n "${cleanup_assertion}" ]] \
                || cleanup_assertion=NF-HARNESS-compose-cleanup-project-residue
        fi
        if grep -F -q "${project_name}" "${integration_root}/cleanup-projects" 2>/dev/null; then
            cleanup_ok=false
            [[ -n "${cleanup_assertion}" ]] \
                || cleanup_assertion=NF-HARNESS-compose-cleanup-project-residue
        fi
    fi

    if [[ -n "${integration_root}" ]]; then
        case "${integration_root}" in
            "${temporary_base}"/threadhub-integration.*)
                if [[ -d "${integration_root}" && ! -L "${integration_root}" ]]; then
                    if ! rm -rf -- "${integration_root}"; then
                        cleanup_ok=false
                        [[ -n "${cleanup_assertion}" ]] \
                            || cleanup_assertion=NF-HARNESS-compose-cleanup-workspace
                    fi
                else
                    cleanup_ok=false
                    [[ -n "${cleanup_assertion}" ]] \
                        || cleanup_assertion=NF-HARNESS-compose-cleanup-workspace
                fi
                ;;
            *)
                cleanup_ok=false
                [[ -n "${cleanup_assertion}" ]] \
                    || cleanup_assertion=NF-HARNESS-compose-cleanup-workspace
                ;;
        esac
    fi

    if [[ "${cleanup_ok}" != true ]]; then
        if is_failure_assertion "${safe_output}"; then
            primary_failure="${safe_output}"
        else
            primary_failure=NF-HARNESS-compose
        fi
        safe_output="${cleanup_assertion:-NF-HARNESS-compose-cleanup}"
        result_kind=failure
        incoming_status=1
        printf 'primary_failure=%s\n' "${primary_failure}" >&3
    fi

    if [[ -n "${result_output_path}" ]]; then
        artifact_parent="$(dirname -- "${result_output_path}")"
        if [[ "${result_output_path}" != /* || ! -d "${artifact_parent}" || -L "${result_output_path}" || -e "${result_output_path}" ]]; then
            safe_output=NF-HARNESS-config
            result_kind=failure
            incoming_status=1
        else
            if ! (set -o noclobber; printf '%s\n' "${safe_output}" >"${result_output_path}"); then
                safe_output=NF-HARNESS-config
                result_kind=failure
                incoming_status=1
            elif ! chmod 0644 "${result_output_path}" || [[ ! -f "${result_output_path}" || -L "${result_output_path}" || "$(<"${result_output_path}")" != "${safe_output}" ]]; then
                rm -f -- "${result_output_path}"
                safe_output=NF-HARNESS-config
                result_kind=failure
                incoming_status=1
            fi
        fi
    fi

    if [[ "${result_kind}" == success && "${incoming_status}" -eq 0 ]]; then
        printf '%s\n' "${safe_output}" >&3
        exit 0
    fi
    if ! is_failure_assertion "${safe_output}"; then
        safe_output=NF-HARNESS-compose
    fi
    printf '%s\n' "${safe_output}" >&3
    exit 1
}

trap cleanup EXIT
trap 'result_kind=failure; result_assertion=NF-HARNESS-compose; exit 130' HUP INT TERM

for required_command in awk chmod cmp curl dirname find go grep id jq mkdir mktemp openssl rm sleep stat tar tr wc; do
    command -v "${required_command}" >/dev/null 2>&1 || abort_run NF-HARNESS-config
done
[[ -f "${compose_file}" && -f "${versions_file}" && -f "${scenario_ids_file}" && -f "${failure_assertions_file}" ]] || abort_run NF-HARNESS-config
[[ "${compose_command_value}" != *$'\n'* && "${compose_command_value}" != *$'\r'* ]] || abort_run NF-HARNESS-config
read -r -a compose_command <<<"${compose_command_value}"
if [[ "${#compose_command[@]}" -eq 2 ]]; then
    [[ "${compose_command[1]}" == compose && "${compose_command[0]##*/}" == docker ]] || abort_run NF-HARNESS-config
elif [[ "${#compose_command[@]}" -ne 1 ]]; then
    abort_run NF-HARNESS-config
fi
command -v "${compose_command[0]}" >/dev/null 2>&1 || abort_run NF-HARNESS-config
"${compose_command[@]}" version >/dev/null 2>&1 || abort_run NF-HARNESS-config

[[ "${container_command_value}" != *$'\n'* && "${container_command_value}" != *$'\r'* ]] || abort_run NF-HARNESS-config
read -r -a container_command <<<"${container_command_value}"
if [[ "${#container_command[@]}" -eq 1 ]]; then
    case "${container_command[0]##*/}" in
        docker)
            container_build_flags=(--pull --platform linux/amd64)
            ;;
        podman)
            container_build_flags=(--pull=always --format docker --platform linux/amd64)
            ;;
        *)
            abort_run NF-HARNESS-config
            ;;
    esac
elif [[ "${#container_command[@]}" -eq 4 && "${container_command[0]##*/}" == podman && "${container_command[1]}" == --remote && "${container_command[2]}" == --url && "${container_command[3]}" == unix:///* ]]; then
    container_socket="${container_command[3]#unix://}"
    [[ "${container_socket}" == /* && -S "${container_socket}" ]] || abort_run NF-HARNESS-config
    container_build_flags=(--pull=always --format docker --platform linux/amd64)
else
    abort_run NF-HARNESS-config
fi
command -v "${container_command[0]}" >/dev/null 2>&1 || abort_run NF-HARNESS-config
"${container_command[@]}" version >/dev/null 2>&1 || abort_run NF-HARNESS-config

temporary_base="${TMPDIR:-/tmp}"
temporary_base="$(cd -- "${temporary_base}" && pwd -P)"
integration_root="$(mktemp -d "${temporary_base}/threadhub-integration.XXXXXX")"
[[ -d "${integration_root}" && ! -L "${integration_root}" ]] || abort_run NF-HARNESS-config
integration_env="${integration_root}/integration.env"
control_file="${integration_root}/data/control/state.json"
bundle_file="${integration_root}/plugin-bundle.tar.gz"
acceptance_output="${integration_root}/acceptance-result"
diagnostic_file="${integration_root}/compose-diagnostic"
plugin_list_file="${integration_root}/plugin-list.json"
project_name="threadhub-int-$(openssl rand -hex 6)"
[[ "${project_name}" =~ ^[a-z0-9][a-z0-9_-]{0,62}$ ]] || abort_run NF-HARNESS-config

version_value() {
    awk -F= -v key="$1" '
        $1 == key { count++; value = substr($0, index($0, "=") + 1) }
        END { if (count != 1 || value == "") exit 1; print value }
    ' "${versions_file}"
}

normalize_image_id() {
    local value="${1#sha256:}"
    [[ "${value}" =~ ^[a-f0-9]{64}$ ]] || return 1
    printf '%s' "${value}"
}

mattermost_repository="$(version_value MATTERMOST_IMAGE_REPOSITORY)" || abort_run NF-HARNESS-config
mattermost_tag="$(version_value MATTERMOST_IMAGE_TAG)" || abort_run NF-HARNESS-config
mattermost_digest="$(version_value MATTERMOST_IMAGE_DIGEST)" || abort_run NF-HARNESS-config
postgres_repository="$(version_value POSTGRES_IMAGE_REPOSITORY)" || abort_run NF-HARNESS-config
postgres_tag="$(version_value POSTGRES_IMAGE_TAG)" || abort_run NF-HARNESS-config
postgres_digest="$(version_value POSTGRES_IMAGE_DIGEST)" || abort_run NF-HARNESS-config
go_repository="$(version_value GO_BUILDER_IMAGE_REPOSITORY)" || abort_run NF-HARNESS-config
go_tag="$(version_value GO_BUILDER_IMAGE_TAG)" || abort_run NF-HARNESS-config
go_digest="$(version_value GO_BUILDER_IMAGE_DIGEST)" || abort_run NF-HARNESS-config
notifier_version="$(version_value NOTIFIER_VERSION)" || abort_run NF-HARNESS-config
plugin_id="$(version_value NOTIFIER_PLUGIN_ID)" || abort_run NF-HARNESS-config

[[ "${mattermost_repository}" == mattermost/mattermost-team-edition && "${mattermost_tag}" == 11.7.7 ]] || abort_run NF-HARNESS-config
[[ "${postgres_repository}" == postgres && "${postgres_tag}" == 18.4 ]] || abort_run NF-HARNESS-config
[[ "${go_repository}" == golang && "${go_tag}" == 1.25.10-bookworm ]] || abort_run NF-HARNESS-config
[[ "${notifier_version}" == 0.1.0 && "${plugin_id}" == com.threadhub.channel-email-notifier ]] || abort_run NF-HARNESS-config
for digest in "${mattermost_digest}" "${postgres_digest}" "${go_digest}"; do
    [[ "${digest}" =~ ^sha256:[a-f0-9]{64}$ ]] || abort_run NF-HARNESS-config
done

db_password="$(openssl rand -hex 32)"
hmac_secret="$(openssl rand -hex 32)"
hash_secret="$(openssl rand -hex 32)"
smtp_password="$(openssl rand -hex 32)"
admin_password="Aa1!$(openssl rand -hex 24)"
user_password="Bb2!$(openssl rand -hex 24)"
host_uid="$(id -u)"
[[ "${db_password}" =~ ^[a-f0-9]{64}$ && "${hmac_secret}" =~ ^[a-f0-9]{64}$ && "${hash_secret}" =~ ^[a-f0-9]{64}$ && "${smtp_password}" =~ ^[a-f0-9]{64}$ ]] || abort_run NF-HARNESS-config
[[ "${host_uid}" =~ ^[0-9]+$ ]] || abort_run NF-HARNESS-config

mkdir -p \
    "${integration_root}/data/postgres" \
    "${integration_root}/data/mattermost/config" \
    "${integration_root}/data/mattermost/data" \
    "${integration_root}/data/mattermost/data/plugins" \
    "${integration_root}/data/mattermost/logs" \
    "${integration_root}/data/mattermost/plugins" \
    "${integration_root}/data/mattermost/client/plugins" \
    "${integration_root}/data/mattermost/bleve-indexes" \
    "${integration_root}/data/mailer" \
    "${integration_root}/data/control" \
    "${integration_root}/data/notifier/release" \
    "${integration_root}/go-cache" || abort_run NF-HARNESS-config
: >"${diagnostic_file}"
chmod 0600 "${diagnostic_file}"
printf '%s\n' '{"enabled":false,"delivery_enabled":false,"mode":"all_channels","channel_ids":[],"activated_at":0}' >"${control_file}"
chmod 0640 "${control_file}"

{
    printf 'COMPOSE_PROJECT_NAME=%s\n' "${project_name}"
    printf 'MATTERMOST_IMAGE_REPOSITORY=%s\n' "${mattermost_repository}"
    printf 'MATTERMOST_IMAGE_TAG=%s\n' "${mattermost_tag}"
    printf 'MATTERMOST_IMAGE_DIGEST=%s\n' "${mattermost_digest}"
    printf 'POSTGRES_IMAGE_REPOSITORY=%s\n' "${postgres_repository}"
    printf 'POSTGRES_IMAGE_TAG=%s\n' "${postgres_tag}"
    printf 'POSTGRES_IMAGE_DIGEST=%s\n' "${postgres_digest}"
    printf 'GO_BUILDER_IMAGE_REPOSITORY=%s\n' "${go_repository}"
    printf 'GO_BUILDER_IMAGE_TAG=%s\n' "${go_tag}"
    printf 'GO_BUILDER_IMAGE_DIGEST=%s\n' "${go_digest}"
    printf 'NOTIFIER_VERSION=%s\n' "${notifier_version}"
    printf 'NOTIFIER_PLUGIN_ID=%s\n' "${plugin_id}"
    printf 'INTEGRATION_DATA_ROOT=%s\n' "${integration_root}/data"
    printf 'INTEGRATION_PLUGIN_BUNDLE=%s\n' "${bundle_file}"
    printf 'INTEGRATION_HOST_UID=%s\n' "${host_uid}"
    printf 'INTEGRATION_DB_PASSWORD=%s\n' "${db_password}"
    printf 'INTEGRATION_HMAC_SECRET=%s\n' "${hmac_secret}"
    printf 'INTEGRATION_HASH_SECRET=%s\n' "${hash_secret}"
    printf 'INTEGRATION_SMTP_PASSWORD=%s\n' "${smtp_password}"
} >"${integration_env}"
chmod 0600 "${integration_env}"
[[ "$(notifier_harness_file_mode "${integration_env}")" == 600 ]] || abort_run NF-HARNESS-config
[[ "$(notifier_harness_file_mode "${diagnostic_file}")" == 600 ]] || abort_run NF-HARNESS-config

result_assertion=NF-HARNESS-config
compose_private config --quiet || abort_run NF-HARNESS-config
result_assertion=NF-HARNESS-compose-pull
compose_private pull --quiet postgres mattermost plugin-install volume-init || abort_run NF-HARNESS-compose-pull
result_assertion=NF-HARNESS-compose-build
bundle_image="threadhub/notifier-plugin-bundle:${notifier_version}"
mailer_image="threadhub/notifier-mailer:${notifier_version}"
smtp_image="threadhub/notifier-smtp-fixture:${notifier_version}"
container_private build "${container_build_flags[@]}" \
    --build-arg "GO_BUILDER_IMAGE=${go_repository}:${go_tag}@${go_digest}" \
    --target plugin-bundle --tag "${bundle_image}" "${notifier_root}" || abort_run NF-HARNESS-compose-build
container_private build "${container_build_flags[@]}" \
    --build-arg "GO_BUILDER_IMAGE=${go_repository}:${go_tag}@${go_digest}" \
    --target mailer --tag "${mailer_image}" "${notifier_root}" || abort_run NF-HARNESS-compose-build
container_private build "${container_build_flags[@]}" \
    --build-arg "GO_BUILDER_IMAGE=${go_repository}:${go_tag}@${go_digest}" \
    --target smtp-fixture --tag "${smtp_image}" "${notifier_root}" || abort_run NF-HARNESS-compose-build
[[ "$("${container_command[@]}" image inspect --format '{{.Os}}/{{.Architecture}}' "${bundle_image}" 2>>"${diagnostic_file}")" == linux/amd64 ]] || abort_run NF-HARNESS-compose-build
[[ "$("${container_command[@]}" image inspect --format '{{.Os}}/{{.Architecture}}' "${mailer_image}" 2>>"${diagnostic_file}")" == linux/amd64 ]] || abort_run NF-HARNESS-compose-build
[[ "$("${container_command[@]}" image inspect --format '{{.Os}}/{{.Architecture}}' "${smtp_image}" 2>>"${diagnostic_file}")" == linux/amd64 ]] || abort_run NF-HARNESS-compose-build
[[ "$("${container_command[@]}" image inspect --format '{{.Config.User}}' "${mailer_image}" 2>>"${diagnostic_file}")" == 65532:65532 ]] || abort_run NF-HARNESS-compose-build
[[ "$("${container_command[@]}" image inspect --format '{{json .Config.Entrypoint}}' "${mailer_image}" 2>>"${diagnostic_file}")" == '["/threadhub-mailer"]' ]] || abort_run NF-HARNESS-compose-build
[[ "$("${container_command[@]}" image inspect --format '{{json .Config.Cmd}}' "${mailer_image}" 2>>"${diagnostic_file}")" == '["serve"]' ]] || abort_run NF-HARNESS-compose-build
[[ "$("${container_command[@]}" image inspect --format '{{.Config.User}}' "${smtp_image}" 2>>"${diagnostic_file}")" == 65532:65532 ]] || abort_run NF-HARNESS-compose-build
[[ "$("${container_command[@]}" image inspect --format '{{json .Config.Entrypoint}}' "${smtp_image}" 2>>"${diagnostic_file}")" == '["/smtp-fixture"]' ]] || abort_run NF-HARNESS-compose-build
[[ "$("${container_command[@]}" image inspect --format '{{json .Config.Cmd}}' "${smtp_image}" 2>>"${diagnostic_file}")" == '["serve"]' ]] || abort_run NF-HARNESS-compose-build
result_assertion=NF-HARNESS-compose-bundle
bundle_image_id_raw="$("${container_command[@]}" image inspect --format '{{.Id}}' "${bundle_image}" 2>>"${diagnostic_file}")" || abort_run NF-HARNESS-compose-bundle-create
bundle_image_id="$(normalize_image_id "${bundle_image_id_raw}")" || abort_run NF-HARNESS-compose-bundle-create
bundle_container_name="${project_name}-bundle-export"
bundle_container_id="$("${container_command[@]}" container create \
    --name "${bundle_container_name}" \
    --label "com.docker.compose.project=${project_name}" \
    --label com.docker.compose.service=plugin-bundle \
    "${bundle_image}" /unused 2>>"${diagnostic_file}")" || abort_run NF-HARNESS-compose-bundle-create
[[ "${bundle_container_id}" =~ ^[a-f0-9]{12,64}$ ]] || abort_run NF-HARNESS-compose-bundle-create
bundle_container_image_raw="$("${container_command[@]}" container inspect --format '{{.Image}}' "${bundle_container_id}" 2>>"${diagnostic_file}")" || abort_run NF-HARNESS-compose-bundle-create
bundle_container_image="$(normalize_image_id "${bundle_container_image_raw}")" || abort_run NF-HARNESS-compose-bundle-create
[[ "${bundle_container_image}" == "${bundle_image_id}" ]] || abort_run NF-HARNESS-compose-bundle-create
[[ "$("${container_command[@]}" container inspect --format '{{ index .Config.Labels "com.docker.compose.project" }}' "${bundle_container_id}" 2>>"${diagnostic_file}")" == "${project_name}" ]] || abort_run NF-HARNESS-compose-bundle-create
[[ "$("${container_command[@]}" container inspect --format '{{ index .Config.Labels "com.docker.compose.service" }}' "${bundle_container_id}" 2>>"${diagnostic_file}")" == plugin-bundle ]] || abort_run NF-HARNESS-compose-bundle-create
container_private container cp "${bundle_container_id}:/${plugin_id}-${notifier_version}.tar.gz" "${bundle_file}" || abort_run NF-HARNESS-compose-bundle-copy
[[ -f "${bundle_file}" && ! -L "${bundle_file}" ]] || abort_run NF-HARNESS-compose-bundle-copy
container_private container rm "${bundle_container_id}" || abort_run NF-HARNESS-compose-bundle-copy
bundle_container_id=""
chmod 0600 "${bundle_file}"

tar -tzf "${bundle_file}" >"${integration_root}/bundle-entries" || abort_run NF-HARNESS-compose-bundle-shape
printf '%s\n' \
    "${plugin_id}/" \
    "${plugin_id}/plugin.json" \
    "${plugin_id}/server/" \
    "${plugin_id}/server/dist/" \
    "${plugin_id}/server/dist/plugin-linux-amd64" \
    >"${integration_root}/expected-bundle-entries"
cmp -s "${integration_root}/expected-bundle-entries" "${integration_root}/bundle-entries" || abort_run NF-HARNESS-compose-bundle-shape
tar -tvzf "${bundle_file}" | awk '{ type=substr($1,1,1); if (type != "-" && type != "d") exit 1 }' || abort_run NF-HARNESS-compose-bundle-shape

result_assertion=NF-HARNESS-compose-start
project_touched=true
compose_private run --rm --no-deps volume-init || abort_run NF-HARNESS-compose-start-init
compose_private up -d --no-build --wait --wait-timeout 120 postgres || abort_run NF-HARNESS-compose-start-postgres
compose_private up -d --no-build --wait --wait-timeout 120 smtp-fixture || abort_run NF-HARNESS-compose-start-smtp
compose_private up -d --no-build --wait --wait-timeout 120 threadhub-mailer || abort_run NF-HARNESS-compose-start-mailer
compose_private up -d --no-build mattermost || abort_run NF-HARNESS-compose-start-mattermost

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

mattermost_address="127.0.0.1:49152"
capture_address="127.0.0.1:49352"
mailer_address="127.0.0.1:49252"
wait_http "http://${mattermost_address}/api/v4/system/ping" 180 || abort_run NF-HARNESS-bootstrap
wait_http "http://${capture_address}/healthz" 120 || abort_run NF-HARNESS-capture-api
wait_http "http://${mailer_address}/healthz" 120 || abort_run NF-HARNESS-compose-start-mailer

result_assertion=NF-HARNESS-plugin-stop
compose_private stop --timeout 60 mattermost || abort_run NF-HARNESS-plugin-stop
result_assertion=NF-HARNESS-plugin-install
compose_private run --rm --no-deps plugin-install || abort_run NF-HARNESS-plugin-install
result_assertion=NF-HARNESS-plugin-reinit
compose_private run --rm --no-deps volume-init || abort_run NF-HARNESS-plugin-reinit
result_assertion=NF-HARNESS-plugin-restart
compose_private up -d --no-build --no-deps mattermost || abort_run NF-HARNESS-plugin-restart
wait_http "http://${mattermost_address}/api/v4/system/ping" 180 || abort_run NF-HARNESS-plugin-restart
result_assertion=NF-HARNESS-plugin-pair
compose_private run --rm --no-deps plugin-install verify || abort_run NF-HARNESS-plugin-pair

result_assertion=NF-HARNESS-plugin-active-list
read_plugin_state() {
    local state

    compose_run exec -T mattermost mmctl plugin list --local --suppress-warnings --json \
        >"${plugin_list_file}" 2>>"${diagnostic_file}" || return 1
    if notifier_plugin_list_is_exact_active \
        "${plugin_list_file}" "${plugin_id}" "${notifier_version}"; then
        return 0
    fi
    state="$(notifier_plugin_list_target_state \
        "${plugin_list_file}" "${plugin_id}")" || return 1
    case "${state}" in
        $'inactive\t'"${notifier_version}") return 10 ;;
        $'missing\t-') return 11 ;;
        *) return 1 ;;
    esac
}

set +e
read_plugin_state
plugin_state_status=$?
set -e
case "${plugin_state_status}" in
    0)
        ;;
    10)
        result_assertion=NF-HARNESS-plugin-enable
        compose_private exec -T mattermost mmctl plugin enable "${plugin_id}" --local --suppress-warnings || abort_run NF-HARNESS-plugin-enable
        result_assertion=NF-HARNESS-plugin-active-list
        read_plugin_state || abort_run NF-HARNESS-plugin-active-list
        ;;
    11)
        abort_run NF-HARNESS-plugin-install
        ;;
    *)
        abort_run NF-HARNESS-plugin-active-list
        ;;
esac

result_assertion=NF-HARNESS-acceptance-run
set +e
(
    cd -- "${notifier_root}" || exit 1
    GOCACHE="${integration_root}/go-cache" \
    INTEGRATION_ROOT="${integration_root}" \
    INTEGRATION_ENV_FILE="${integration_env}" \
    INTEGRATION_CONTROL_FILE="${control_file}" \
    INTEGRATION_MATTERMOST_URL="http://${mattermost_address}" \
    INTEGRATION_MAILER_URL="http://${mailer_address}" \
    INTEGRATION_CAPTURE_URL="http://${capture_address}" \
    INTEGRATION_COMPOSE_COMMAND="${compose_command_value}" \
    INTEGRATION_COMPOSE_FILE="${compose_file}" \
    INTEGRATION_PROJECT_NAME="${project_name}" \
    INTEGRATION_HMAC_SECRET="${hmac_secret}" \
    INTEGRATION_HASH_SECRET="${hash_secret}" \
    INTEGRATION_ADMIN_PASSWORD="${admin_password}" \
    INTEGRATION_USER_PASSWORD="${user_password}" \
    INTEGRATION_DOMAIN=threadhub.integration.test \
        go run ./integration/cmd/acceptance
) >"${acceptance_output}" 2>"${integration_root}/acceptance-stderr"
acceptance_status=$?
set -e

if [[ "${acceptance_status}" -eq 0 ]]; then
    cmp -s "${scenario_ids_file}" "${acceptance_output}" || abort_run NF-HARNESS-acceptance-output
    result_assertion=NF-HARNESS-plugin-pair-tamper
    compose_private stop --timeout 60 mattermost || abort_run NF-HARNESS-plugin-pair-tamper
    compose_private run --rm --no-deps plugin-install tamper-bundle \
        || abort_run NF-HARNESS-plugin-pair-tamper
    result_assertion=NF-HARNESS-plugin-pair-negative
    set +e
    compose_private run --rm --no-deps plugin-install verify
    tamper_verify_status=$?
    set -e
    [[ "${tamper_verify_status}" -eq 42 ]] || abort_run NF-HARNESS-plugin-pair-negative
    result_kind=success
    result_source="${acceptance_output}"
    exit 0
fi

[[ "$(wc -l <"${acceptance_output}" | tr -d '[:space:]')" == 1 ]] || abort_run NF-HARNESS-acceptance-output
result_assertion="$(<"${acceptance_output}")"
is_failure_assertion "${result_assertion}" || abort_run NF-HARNESS-acceptance-output
result_kind=failure
exit 1
