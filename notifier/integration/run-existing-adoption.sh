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
generated_bundle=false
bundle_sha_public=""

declare -a docker_command=()
declare -a privileged_docker_command=()

fail() {
    result_assertion="$1"
    exit 1
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

private() {
    "$@" >>"${diagnostic_file}" 2>&1
}

db_counts() {
    local output_file="$1"
    compose_base exec -T postgres psql -X -A -t -U threadhub -d threadhub \
        -c "SELECT (SELECT count(*) FROM teams)||E'\\t'||(SELECT count(*) FROM channels)||E'\\t'||(SELECT count(*) FROM channelmembers)||E'\\t'||(SELECT count(*) FROM users)||E'\\t'||(SELECT count(*) FROM posts)||E'\\t'||(SELECT count(*) FROM fileinfo);" \
        >"${output_file}" 2>>"${diagnostic_file}"
    [[ "$(wc -l < "${output_file}" | tr -d '[:space:]')" == 1 ]]
    awk -F '\t' '
        NF != 6 { exit 1 }
        { for (field = 1; field <= NF; field++) if ($field !~ /^[0-9]+$/) exit 1 }
    ' "${output_file}"
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
    script -q -e -c "${command_string}" /dev/null \
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

cleanup() {
    local incoming_status=$?
    local safe_output="${result_assertion}"
    local cleanup_ok=true
    local privacy_patterns=""
    local artifact_parent=""
    local evidence_parent=""

    trap - EXIT HUP INT TERM
    set +e

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

for required in awk cat chmod cmp cp date dirname docker git go grep id jq mkdir mktemp openssl rm script sed sleep sort stat sudo tr wc; do
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
sudo chmod 0750 "${integration_root}/data/mattermost/plugins" "${integration_root}/data/mattermost/data" || fail NF-ADOPT-01
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

private compose_base config --quiet || fail NF-ADOPT-01
private compose_base pull --quiet postgres mattermost || fail NF-ADOPT-01
private "${docker_command[@]}" build --platform linux/amd64 \
    --build-arg "GO_BUILDER_IMAGE=${go_repository}:${go_tag}@${go_digest}" \
    --target smtp-fixture --tag "threadhub/notifier-smtp-fixture:${notifier_version}" \
    "${notifier_root}" || fail NF-ADOPT-01
project_touched=true
private compose_base up -d --no-build --wait --wait-timeout 180 postgres smtp-fixture mattermost || fail NF-ADOPT-01
sudo chown root:root "${integration_root}/data/smtp-ca/ca.crt" || fail NF-ADOPT-01
sudo chmod 0644 "${integration_root}/data/smtp-ca/ca.crt" || fail NF-ADOPT-01
sudo chown root:root "${integration_root}/data/smtp-ca" || fail NF-ADOPT-01
sudo chmod 0755 "${integration_root}/data/smtp-ca" || fail NF-ADOPT-01

private env GOCACHE="${integration_root}/go-cache" go build -o "${acceptance_binary}" ./notifier/integration/cmd/existing-acceptance || fail NF-ADOPT-01
private compose_base exec -T mattermost mmctl user create --local --suppress-warnings \
    --email admin@integration.invalid --username existing-admin --password "${admin_password}" \
    --system-admin --email-verified || fail NF-ADOPT-03
private acceptance bootstrap || fail NF-ADOPT-03
private compose_base exec -T mattermost mmctl user verify existing-recipient-a --local --suppress-warnings || fail NF-ADOPT-03
private compose_base exec -T mattermost mmctl user verify existing-recipient-b --local --suppress-warnings || fail NF-ADOPT-03
db_counts "${integration_root}/counts-baseline" || fail NF-ADOPT-03

portable_hash "${compose_file}" >"${integration_root}/base-compose-before.sha256"
portable_hash "${integration_env}" >"${integration_root}/base-env-before.sha256"
cp "${integration_env}" "${integration_root}/unsupported.env"
sed -i 's/^MATTERMOST_IMAGE_TAG=11\.7\.7$/MATTERMOST_IMAGE_TAG=11.8.0/' "${integration_root}/unsupported.env"
chmod 0600 "${integration_root}/unsupported.env"
sed "s|^THN_COMPOSE_ENV_FILE=.*$|THN_COMPOSE_ENV_FILE=${integration_root}/unsupported.env|" \
    "${adoption_env}" >"${integration_root}/unsupported-notifier.env"
chmod 0600 "${integration_root}/unsupported-notifier.env"
set +e
THREADHUB_EXISTING_NOTIFIER_ENV_FILE="${integration_root}/unsupported-notifier.env" \
    "${repository_root}/deploy/scripts/existing-notifier-preflight.sh" \
    >>"${diagnostic_file}" 2>&1
unsupported_status=$?
set -e
[[ "${unsupported_status}" -eq 20 && ! -e "${runtime_parent}/notifier" ]] || fail NF-ADOPT-02

private env THREADHUB_EXISTING_NOTIFIER_ENV_FILE="${adoption_env}" \
    "${repository_root}/deploy/scripts/existing-notifier-preflight.sh" || fail NF-ADOPT-01
[[ "$(portable_hash "${compose_file}")" == "$(<"${integration_root}/base-compose-before.sha256")" ]] || fail NF-ADOPT-01
[[ "$(portable_hash "${integration_env}")" == "$(<"${integration_root}/base-env-before.sha256")" ]] || fail NF-ADOPT-01
db_counts "${integration_root}/counts-after-preflight" || fail NF-ADOPT-01
cmp -s "${integration_root}/counts-baseline" "${integration_root}/counts-after-preflight" || fail NF-ADOPT-01

set +e
generated_bundle=true
THREADHUB_EXISTING_NOTIFIER_ENV_FILE="${adoption_env}" \
    "${repository_root}/deploy/scripts/existing-notifier-setup.sh" --resume --non-interactive \
    >>"${diagnostic_file}" 2>&1
setup_status=$?
set -e
[[ "${setup_status}" -eq 20 ]] || fail NF-ADOPT-03
db_counts "${integration_root}/counts-disabled" || fail NF-ADOPT-03
cmp -s "${integration_root}/counts-baseline" "${integration_root}/counts-disabled" || fail NF-ADOPT-03
private acceptance verify-baseline || fail NF-ADOPT-03

smtp_container="$(compose_base ps -q smtp-fixture)"
[[ "${smtp_container}" =~ ^[a-f0-9]{64}$ ]] || fail NF-ADOPT-04
private "${docker_command[@]}" network connect \
    --alias smtp.email.ap-singapore-1.oci.oraclecloud.com \
    "${project_name}_threadhub-notifier-outbound" "${smtp_container}" || fail NF-ADOPT-04

printf '%s\n' 'probe@integration.invalid' >"${integration_root}/smtp-recipient"
run_pty "${integration_root}/smtp-recipient" "${repository_root}/deploy/scripts/existing-notifier-smtp-test.sh" || fail NF-ADOPT-04
rm -f -- "${integration_root}/smtp-recipient"
public_channel="$(jq -r '.public_channel_id' "${integration_root}/acceptance-state.json")"
private_channel="$(jq -r '.private_channel_id' "${integration_root}/acceptance-state.json")"
[[ "${public_channel}" =~ ^[a-z0-9]{26}$ && "${private_channel}" =~ ^[a-z0-9]{26}$ ]] || fail NF-ADOPT-04
printf '%s,%s\n' "${public_channel}" "${private_channel}" >"${integration_root}/allowlist-input"
run_pty "${integration_root}/allowlist-input" \
    "${repository_root}/deploy/scripts/existing-notifier-control.sh" activate-allowlist || fail NF-ADOPT-04
rm -f -- "${integration_root}/allowlist-input"

private acceptance exercise || fail NF-ADOPT-05
wait_queue_idle || fail NF-ADOPT-04
bundle_sha_public="$(sudo awk -F= '$1 == "NOTIFIER_PLUGIN_BUNDLE_SHA256" { count++; value=$2 } END { if (count != 1 || value !~ /^[a-f0-9]{64}$/) exit 1; print value }' "${runtime_parent}/notifier/release/release.env")" || fail NF-ADOPT-04

private acceptance snapshot || fail NF-ADOPT-06
private compose_base stop smtp-fixture || fail NF-ADOPT-06
private acceptance outage-post || fail NF-ADOPT-06
wait_queue_pending || fail NF-ADOPT-06
private compose_combined restart threadhub-mailer || fail NF-ADOPT-07
private compose_base start smtp-fixture || fail NF-ADOPT-07
private acceptance assert-outage || fail NF-ADOPT-07
wait_queue_idle || fail NF-ADOPT-07

db_counts "${integration_root}/counts-before-rollback" || fail NF-ADOPT-09
private env THREADHUB_EXISTING_NOTIFIER_ENV_FILE="${adoption_env}" \
    "${repository_root}/deploy/scripts/existing-notifier-control.sh" drain || fail NF-ADOPT-09
wait_queue_idle || fail NF-ADOPT-09
private env THREADHUB_EXISTING_NOTIFIER_ENV_FILE="${adoption_env}" \
    "${repository_root}/deploy/scripts/existing-notifier-control.sh" disable || fail NF-ADOPT-09
private compose_combined stop threadhub-mailer || fail NF-ADOPT-09
sudo sha256sum "${runtime_parent}/notifier/mailer/queue.db" \
    | awk '{print $1}' >"${integration_root}/queue-before-rollback.sha256" || fail NF-ADOPT-09
private compose_combined up -d --no-deps --wait --wait-timeout 120 threadhub-mailer || fail NF-ADOPT-09
private env THREADHUB_EXISTING_NOTIFIER_ENV_FILE="${adoption_env}" \
    "${repository_root}/deploy/scripts/existing-notifier-rollback.sh" || fail NF-ADOPT-09

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
