#!/usr/bin/env bash

set -Eeuo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_DEPLOY_DIR="$(cd "${TEST_DIR}/.." && pwd)"
OVERLAY_SCRIPT="${TEST_DEPLOY_DIR}/scripts/existing-notifier-overlay.sh"
failures=0

readonly FIXTURE_USERNAME='fixture-overlay-private-user'
readonly FIXTURE_PASSWORD='fixture-overlay-private-password'
readonly FIXTURE_HMAC='2222222222222222222222222222222222222222222222222222222222222222'

fail() { printf 'not ok - %s\n' "$1" >&2; failures=$((failures + 1)); }
pass() { printf 'ok - %s\n' "$1"; }
run_test() { if "$2"; then pass "$1"; else fail "$1"; fi; }

portable_mode() {
    if stat -c '%a' "$1" >/dev/null 2>&1; then stat -c '%a' "$1"; else stat -f '%Lp' "$1"; fi
}

prepare_fixture() {
    fixture="$(mktemp -d)"
    project_dir="${fixture}/existing"
    compose_file="${project_dir}/compose.yml"
    existing_env="${project_dir}/.env"
    plugins_root="${fixture}/mattermost/plugins"
    data_root="${fixture}/mattermost/data"
    notifier_root="${fixture}/notifier"
    config="${fixture}/existing-notifier.env"
    destination="${notifier_root}/compose.override.yml"
    output="${fixture}/output"
    base_model="${fixture}/base.json"
    combined_model="${fixture}/combined.json"
    mkdir -p "${project_dir}" "${plugins_root}" "${data_root}" "${notifier_root}"
    chmod 0750 "${notifier_root}"
    cat > "${compose_file}" <<EOF
services:
  mattermost:
    image: mattermost/mattermost-team-edition:11.7.7
    environment:
      EXISTING_VALUE: \${EXISTING_VALUE:?set EXISTING_VALUE}
    ports:
      - 127.0.0.1:8065:8065
    volumes:
      - ${plugins_root}:/mattermost/plugins:rw
      - ${data_root}:/mattermost/data:rw
    networks:
      - existing
    group_add:
      - "2001"
    healthcheck:
      test: [CMD, curl, -f, http://localhost:8065/api/v4/system/ping]
    restart: unless-stopped
networks:
  existing: {}
EOF
    printf '%s\n' 'EXISTING_VALUE=preserved' > "${existing_env}"
    chmod 0600 "${existing_env}"
    cat > "${config}" <<EOF
THN_COMPOSE_PROJECT_DIR=${project_dir}
THN_COMPOSE_FILE=${compose_file}
THN_COMPOSE_ENV_FILE=${existing_env}
THN_MATTERMOST_SERVICE=mattermost
THN_MATTERMOST_PLUGINS_ROOT=${plugins_root}
THN_MATTERMOST_DATA_ROOT=${data_root}
THN_DATA_ROOT=${notifier_root}
THN_DOMAIN=mattermost.valid.test
THN_SMTP_SERVER=smtp.email.ap-singapore-1.oci.oraclecloud.com
THN_SMTP_PORT=587
THN_SMTP_USERNAME=${FIXTURE_USERNAME}
THN_SMTP_PASSWORD=${FIXTURE_PASSWORD}
THN_SMTP_FROM_ADDRESS=no-reply@valid.test
THN_SMTP_REPLY_TO_ADDRESS=admin@valid.test
THN_SMTP_FEEDBACK_NAME=ThreadHub
THN_HMAC_SECRET=${FIXTURE_HMAC}
THN_RATE_PER_MINUTE=10
EOF
    chmod 0600 "${config}"
}

source_overlay() {
    THREADHUB_EXISTING_NOTIFIER_ENV_FILE="${config}"
    export THREADHUB_EXISTING_NOTIFIER_ENV_FILE
    # shellcheck source=../scripts/existing-notifier-overlay.sh
    source "${OVERLAY_SCRIPT}"
    init_docker() { DOCKER_COMMAND=(fixture_docker); }
    runtime_env_publish_no_clobber() {
        local source_path="$1" destination_path="$2"
        [[ ! -e "${destination_path}" && ! -L "${destination_path}" ]] || return 1
        mv "${source_path}" "${destination_path}"
    }
}

fixture_docker() {
    local compose_files=0
    local format_json=false
    local argument

    [[ "$1" == compose ]] || return 1
    shift
    while (($# > 0)); do
        argument="$1"
        shift
        case "${argument}" in
            -f)
                (($# > 0)) || return 1
                compose_files=$((compose_files + 1))
                shift
                ;;
            --project-directory|--env-file)
                (($# > 0)) || return 1
                shift
                ;;
            --format)
                [[ "${1:-}" == json ]] || return 1
                format_json=true
                shift
                ;;
            config|--quiet)
                ;;
            *)
                return 1
                ;;
        esac
    done

    if [[ "${format_json}" != true ]]; then
        return 0
    fi

    if ((compose_files == 1)); then
        jq -n --arg plugins_root "${plugins_root}" --arg data_root "${data_root}" '
            {
              services: {
                mattermost: {
                  image: "mattermost/mattermost-team-edition:11.7.7",
                  environment: {EXISTING_VALUE: "preserved"},
                  ports: [{target: 8065, published: "8065", host_ip: "127.0.0.1"}],
                  volumes: [
                    {type: "bind", source: $plugins_root, target: "/mattermost/plugins", read_only: false},
                    {type: "bind", source: $data_root, target: "/mattermost/data", read_only: false}
                  ],
                  networks: {existing: null},
                  group_add: ["2001"],
                  healthcheck: {test: ["CMD", "curl", "-f", "http://localhost:8065/api/v4/system/ping"]},
                  restart: "unless-stopped"
                }
              },
              networks: {existing: {}}
            }
        '
        return
    fi

    ((compose_files == 2)) || return 1
    jq -n \
        --arg plugins_root "${plugins_root}" \
        --arg data_root "${data_root}" \
        --arg notifier_root "${notifier_root}" \
        --arg hmac "${FIXTURE_HMAC}" '
        {
          services: {
            mattermost: {
              image: "mattermost/mattermost-team-edition:11.7.7",
              environment: {
                EXISTING_VALUE: "preserved",
                THREADHUB_DOMAIN: "mattermost.valid.test",
                NOTIFIER_MAILER_URL: "http://threadhub-mailer:8080",
                NOTIFIER_HMAC_SECRET: $hmac,
                NOTIFIER_CONTROL_FILE: "/run/threadhub-notifier/state.json",
                NOTIFIER_POLL_EVERY: "1s"
              },
              ports: [{target: 8065, published: "8065", host_ip: "127.0.0.1"}],
              volumes: [
                {type: "bind", source: $plugins_root, target: "/mattermost/plugins", read_only: false},
                {type: "bind", source: $data_root, target: "/mattermost/data", read_only: false},
                {type: "bind", source: ($notifier_root + "/control"), target: "/run/threadhub-notifier", read_only: true}
              ],
              networks: {existing: null, "threadhub-notifier-internal": null},
              group_add: ["2001", "3000"],
              healthcheck: {test: ["CMD", "curl", "-f", "http://localhost:8065/api/v4/system/ping"]},
              restart: "unless-stopped"
            },
            "threadhub-mailer": {
              image: "threadhub/notifier-mailer:0.1.0",
              pull_policy: "never",
              platform: "linux/amd64",
              user: "65532:65532",
              group_add: ["3000"],
              read_only: true,
              cap_drop: ["ALL"],
              security_opt: ["no-new-privileges:true"],
              volumes: [
                {type: "bind", source: ($notifier_root + "/mailer"), target: "/var/lib/threadhub-notifier", read_only: false},
                {type: "bind", source: ($notifier_root + "/control"), target: "/run/threadhub-notifier", read_only: true}
              ],
              networks: {"threadhub-notifier-internal": null, "threadhub-notifier-outbound": null}
            }
          },
          networks: {
            existing: {},
            "threadhub-notifier-internal": {internal: true},
            "threadhub-notifier-outbound": {}
          }
        }
    '
}

assert_no_private_output_or_file() {
    local target
    for target in "${output}" "${destination}"; do
        ! grep -F -e "${FIXTURE_USERNAME}" -e "${FIXTURE_PASSWORD}" -e "${FIXTURE_HMAC}" "${target}" >/dev/null 2>&1 || return 1
    done
}

run_override_or_report_stage() {
    local result
    set +e
    existing_notifier_write_override "${destination}" > "${output}" 2>&1
    result=$?
    set -e
    if ((result != 0)); then
        sed \
            -e "s/${FIXTURE_USERNAME}/[REDACTED-USERNAME]/g" \
            -e "s/${FIXTURE_PASSWORD}/[REDACTED-PASSWORD]/g" \
            -e "s/${FIXTURE_HMAC}/[REDACTED-HMAC]/g" \
            "${output}" >&2
        return "${result}"
    fi
}

test_overlay_script_exists() { [[ -f "${OVERLAY_SCRIPT}" ]]; }

test_generated_override_is_placeholder_only_and_hardened() (
    prepare_fixture
    trap 'rm -rf "${fixture}"' EXIT
    source_overlay
    run_override_or_report_stage || return 1
    [[ -f "${destination}" && ! -L "${destination}" ]] || { printf 'stage: destination identity\n' >&2; return 1; }
    [[ "$(portable_mode "${destination}")" == 600 ]] || { printf 'stage: destination mode\n' >&2; return 1; }
    grep -F '${THN_HMAC_SECRET:?set THN_HMAC_SECRET}' "${destination}" >/dev/null || { printf 'stage: hmac placeholder\n' >&2; return 1; }
    grep -F '${THN_SMTP_PASSWORD:?set THN_SMTP_PASSWORD}' "${destination}" >/dev/null || { printf 'stage: smtp placeholder\n' >&2; return 1; }
    assert_no_private_output_or_file || { printf 'stage: private material\n' >&2; return 1; }
)

test_combined_model_preserves_base_and_hardens_mailer() (
    prepare_fixture
    trap 'rm -rf "${fixture}"' EXIT
    source_overlay
    run_override_or_report_stage || return 1
    init_docker || return 1
    existing_notifier_init_compose || return 1
    existing_notifier_compose_base config --format json > "${base_model}" || return 1
    existing_notifier_compose_combined config --format json > "${combined_model}" || return 1
    jq -e --slurpfile base "${base_model}" --arg service mattermost '
        .services[$service] as $mm |
        .services["threadhub-mailer"] as $mailer |
        ($mm.image == $base[0].services[$service].image) and
        ($mm.ports == $base[0].services[$service].ports) and
        ($mm.healthcheck == $base[0].services[$service].healthcheck) and
        ($mm.restart == $base[0].services[$service].restart) and
        ($mm.environment.EXISTING_VALUE == "preserved") and
        ($mm.environment.NOTIFIER_MAILER_URL == "http://threadhub-mailer:8080") and
        ([$mm.volumes[] | select(.target == "/run/threadhub-notifier" and .read_only == true)] | length == 1) and
        (($mm.group_add | index("2001")) != null) and (($mm.group_add | index("3000")) != null) and
        (($mailer.ports // []) | length == 0) and
        ($mailer.user == "65532:65532") and ($mailer.read_only == true) and
        ($mailer.cap_drop == ["ALL"]) and
        ($mailer.security_opt == ["no-new-privileges:true"]) and
        (.networks["threadhub-notifier-internal"].internal == true)
    ' "${combined_model}" >/dev/null || return 1
    assert_no_private_output_or_file
)

test_same_override_is_idempotent_but_different_file_is_not_overwritten() (
    prepare_fixture
    trap 'rm -rf "${fixture}"' EXIT
    source_overlay
    run_override_or_report_stage || return 1
    before="$(sha256_file "${destination}")"
    run_override_or_report_stage || return 1
    [[ "${before}" == "$(sha256_file "${destination}")" ]] || return 1
    printf '%s\n' 'different' > "${destination}"
    chmod 0600 "${destination}"
    set +e
    existing_notifier_write_override "${destination}" > "${output}" 2>&1
    result=$?
    set -e
    [[ "${result}" == 20 ]] || return 1
    [[ "$(<"${destination}")" == different ]] || return 1
    assert_no_private_output_or_file
)

run_test 'existing notifier overlay generator exists' test_overlay_script_exists
if [[ -f "${OVERLAY_SCRIPT}" ]]; then
    run_test 'generated override is mode 0600 and placeholder-only' test_generated_override_is_placeholder_only_and_hardened
    run_test 'combined Compose preserves base and hardens Mailer' test_combined_model_preserves_base_and_hardens_mailer
    run_test 'override generation is idempotent and never overwrites differences' test_same_override_is_idempotent_but_different_file_is_not_overwritten
fi

if ((failures > 0)); then exit 1; fi
