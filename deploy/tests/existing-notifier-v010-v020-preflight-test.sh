#!/usr/bin/env bash

# Each fixture and assertion intentionally runs in an isolated subshell.
# shellcheck disable=SC2030,SC2031,SC2034,SC2329

set -Eeuo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_DEPLOY_DIR="$(cd "${TEST_DIR}/.." && pwd)"
COMMON="${TEST_DEPLOY_DIR}/scripts/existing-notifier-v010-v020-common.sh"
PREFLIGHT="${TEST_DEPLOY_DIR}/scripts/existing-notifier-v010-v020-preflight.sh"
failures=0

fail() { printf 'not ok - %s\n' "$1" >&2; failures=$((failures + 1)); }
pass() { printf 'ok - %s\n' "$1"; }
run_test() { if "$2"; then pass "$1"; else fail "$1"; fi; }

portable_mode() {
    if stat -c '%a' "$1" >/dev/null 2>&1; then stat -c '%a' "$1"; else stat -f '%Lp' "$1"; fi
}

portable_hash() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        shasum -a 256 "$1" | awk '{print $1}'
    fi
}

write_legacy_config() {
    local destination="$1"

    cat > "${destination}" <<'EOF'
THN_COMPOSE_PROJECT_DIR=/srv/threadhub-deploy
THN_COMPOSE_FILE=/srv/threadhub-deploy/docker-compose.yml
THN_COMPOSE_ENV_FILE=/srv/threadhub-deploy/.env
THN_MATTERMOST_SERVICE=mattermost
THN_MATTERMOST_PLUGINS_ROOT=/srv/threadhub/plugins
THN_MATTERMOST_DATA_ROOT=/srv/threadhub/data
THN_DATA_ROOT=/srv/threadhub-notifier
THN_DOMAIN=threadhub.valid.test
THN_SMTP_SERVER=smtp.email.ap-singapore-1.oci.oraclecloud.com
THN_SMTP_PORT=587
THN_SMTP_CA_FILE=/etc/ssl/certs/ca-certificates.crt
THN_SMTP_USERNAME=fixture-smtp-user
THN_SMTP_PASSWORD=fixture-private-password
THN_SMTP_FROM_ADDRESS=no-reply@valid.test
THN_SMTP_REPLY_TO_ADDRESS=admin@valid.test
THN_SMTP_FEEDBACK_NAME=ThreadHub
THN_HMAC_SECRET=1111111111111111111111111111111111111111111111111111111111111111
THN_RATE_PER_MINUTE=10
EOF
    chmod 0600 "${destination}"
}

prepare_config_fixture() {
    fixture="$(mktemp -d)"
    legacy_env="${fixture}/existing-notifier.env"
    write_legacy_config "${legacy_env}"
}

test_common_exists() { [[ -f "${COMMON}" ]]; }
test_preflight_exists() { [[ -f "${PREFLIGHT}" ]]; }

test_legacy_config_has_exact_keyset() (
    prepare_config_fixture
    trap 'rm -rf -- "${fixture}"' EXIT
    # shellcheck source=../scripts/existing-notifier-v010-v020-common.sh
    source "${COMMON}"

    [[ "$(existing_notifier_v010_v020_config_state "${legacy_env}")" == source ]]
)

test_target_config_has_exact_keyset() (
    prepare_config_fixture
    trap 'rm -rf -- "${fixture}"' EXIT
    printf '%s\n' 'THN_CONTENT_MODE=project_team_channel' >> "${legacy_env}"
    # shellcheck source=../scripts/existing-notifier-v010-v020-common.sh
    source "${COMMON}"

    [[ "$(existing_notifier_v010_v020_config_state "${legacy_env}")" == target ]]
)

test_target_copy_is_private_and_preserves_source() (
    prepare_config_fixture
    trap 'rm -rf -- "${fixture}"' EXIT
    # shellcheck source=../scripts/existing-notifier-v010-v020-common.sh
    source "${COMMON}"
    before="$(portable_hash "${legacy_env}")"
    target="${fixture}/target.env"

    existing_notifier_v010_v020_prepare_target_config "${legacy_env}" "${target}" || return 1
    [[ "$(portable_hash "${legacy_env}")" == "${before}" \
        && "$(portable_mode "${target}")" == 600 \
        && "$(existing_notifier_v010_v020_config_state "${target}")" == target ]]
)

test_partial_duplicate_unknown_or_crlf_config_is_rejected() (
    prepare_config_fixture
    trap 'rm -rf -- "${fixture}"' EXIT
    # shellcheck source=../scripts/existing-notifier-v010-v020-common.sh
    source "${COMMON}"

    cp "${legacy_env}" "${fixture}/partial"
    sed -i.bak '/^THN_SMTP_PORT=/d' "${fixture}/partial"
    rm -f "${fixture}/partial.bak"
    chmod 0600 "${fixture}/partial"
    ! existing_notifier_v010_v020_config_state "${fixture}/partial" >/dev/null || return 1

    cp "${legacy_env}" "${fixture}/duplicate"
    printf '%s\n' 'THN_SMTP_PORT=587' >> "${fixture}/duplicate"
    chmod 0600 "${fixture}/duplicate"
    ! existing_notifier_v010_v020_config_state "${fixture}/duplicate" >/dev/null || return 1

    cp "${legacy_env}" "${fixture}/unknown"
    printf '%s\n' 'THN_UNKNOWN=value' >> "${fixture}/unknown"
    chmod 0600 "${fixture}/unknown"
    ! existing_notifier_v010_v020_config_state "${fixture}/unknown" >/dev/null || return 1

    awk '{ printf "%s\r\n", $0 }' "${legacy_env}" > "${fixture}/crlf"
    chmod 0600 "${fixture}/crlf"
    ! existing_notifier_v010_v020_config_state "${fixture}/crlf" >/dev/null
)

test_unsafe_config_file_is_rejected_without_values() (
    prepare_config_fixture
    trap 'rm -rf -- "${fixture}"' EXIT
    # shellcheck source=../scripts/existing-notifier-v010-v020-common.sh
    source "${COMMON}"
    protected='fixture-private-password'

    chmod 0644 "${legacy_env}"
    set +e
    existing_notifier_v010_v020_config_state "${legacy_env}" > "${fixture}/mode-output" 2>&1
    mode_result=$?
    set -e
    [[ "${mode_result}" != 0 ]] || return 1
    ! grep -F "${protected}" "${fixture}/mode-output" >/dev/null || return 1

    chmod 0600 "${legacy_env}"
    ln -s "${legacy_env}" "${fixture}/linked.env"
    set +e
    existing_notifier_v010_v020_config_state "${fixture}/linked.env" > "${fixture}/link-output" 2>&1
    link_result=$?
    set -e
    [[ "${link_result}" != 0 ]] || return 1
    ! grep -F "${protected}" "${fixture}/link-output" >/dev/null
)

write_source_release() {
    local destination="$1"
    cat > "${destination}" <<EOF
NOTIFIER_VERSION=0.1.0
NOTIFIER_PLUGIN_ID=com.threadhub.channel-email-notifier
NOTIFIER_PLUGIN_BUNDLE=notifier/dist/com.threadhub.channel-email-notifier-0.1.0.tar.gz
NOTIFIER_PLUGIN_BUNDLE_SHA256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
NOTIFIER_MAILER_IMAGE=threadhub/notifier-mailer:0.1.0
NOTIFIER_MAILER_IMAGE_ID=sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
NOTIFIER_SOURCE_COMMIT=c193155eeb6298771d4366d6af4cae81499487b8
EOF
    chmod 0640 "${destination}"
}

test_source_release_requires_exact_version_commit_and_image_identity() (
    fixture="$(mktemp -d)"
    trap 'rm -rf -- "${fixture}"' EXIT
    release="${fixture}/release.env"
    write_source_release "${release}"
    # shellcheck source=../scripts/existing-notifier-v010-v020-preflight.sh
    source "${PREFLIGHT}"
    SUDO_COMMAND=(env)
    existing_notifier_v010_v020_privileged_identity() { printf '%s\n' 0:0:640; }

    existing_notifier_v010_v020_read_source_release "${release}" "${fixture}" || return 1
    [[ "${EXISTING_NOTIFIER_V010_RELEASE_BUNDLE_SHA}" == aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ]] || return 1
    [[ "${EXISTING_NOTIFIER_V010_RELEASE_MAILER_IMAGE_ID}" == sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb ]] || return 1

    sed -i.bak 's/NOTIFIER_VERSION=0.1.0/NOTIFIER_VERSION=0.1.1/' "${release}"
    rm -f "${release}.bak"
    ! existing_notifier_v010_v020_read_source_release "${release}" "${fixture}" || return 1
    write_source_release "${release}"
    sed -i.bak 's/c193155eeb6298771d4366d6af4cae81499487b8/ffffffffffffffffffffffffffffffffffffffff/' "${release}"
    rm -f "${release}.bak"
    ! existing_notifier_v010_v020_read_source_release "${release}" "${fixture}"
)

write_recovery_gate() {
    local destination="$1"
    local reviewed_at="$2"
    jq -n --arg reviewed_at "${reviewed_at}" '
      {
        schema:1,
        profile:"existing-notifier-v010-v020",
        source_release_commit:"c193155eeb6298771d4366d6af4cae81499487b8",
        remote_backup_verified:true,
        disposable_restore_verified:true,
        aggregate_match_verified:true,
        restored_queue_quarantined:true,
        reviewed_at_utc:$reviewed_at
      }
    ' > "${destination}"
    chmod 0600 "${destination}"
}

test_recovery_gate_is_exact_current_and_private() (
    fixture="$(mktemp -d)"
    trap 'rm -rf -- "${fixture}"' EXIT
    gate="${fixture}/gate.json"
    now=1789000000
    reviewed_at="$(date -u -r "${now}" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -d "@${now}" '+%Y-%m-%dT%H:%M:%SZ')"
    write_recovery_gate "${gate}" "${reviewed_at}"
    # shellcheck source=../scripts/existing-notifier-v010-v020-preflight.sh
    source "${PREFLIGHT}"
    SUDO_COMMAND=(env)
    existing_notifier_v010_v020_privileged_identity() {
      if [[ "$1" == "$(dirname "${gate}")" ]]; then printf '%s\n' 0:0:700; else printf '%s\n' 0:0:600; fi
    }

    existing_notifier_v010_v020_recovery_gate_is_valid "${gate}" "${now}" || return 1
    jq '.extra="public-identifier"' "${gate}" > "${gate}.new"
    mv "${gate}.new" "${gate}"
    chmod 0600 "${gate}"
    ! existing_notifier_v010_v020_recovery_gate_is_valid "${gate}" "${now}" || return 1
    write_recovery_gate "${gate}" '2026-08-01T00:00:00Z'
    ! existing_notifier_v010_v020_recovery_gate_is_valid "${gate}" "${now}"
)

test_mailer_status_accepts_only_safe_fixed_aggregates() (
    fixture="$(mktemp -d)"
    trap 'rm -rf -- "${fixture}"' EXIT
    status="${fixture}/status.json"
    printf '%s\n' '{"pending":2,"sending":1,"sent":7,"failed":3,"oldest_pending_seconds":9,"last_success_at":10,"last_error_class":"temporary","last_smtp_code":451}' > "${status}"
    # shellcheck source=../scripts/existing-notifier-v010-v020-preflight.sh
    source "${PREFLIGHT}"

    existing_notifier_v010_v020_mailer_status_is_valid "${status}" || return 1
    jq '.recipient="private@valid.test"' "${status}" > "${status}.new"
    mv "${status}.new" "${status}"
    ! existing_notifier_v010_v020_mailer_status_is_valid "${status}" || return 1
    printf '%s\n' '{"pending":-1,"sending":0,"sent":0,"failed":0,"oldest_pending_seconds":0,"last_success_at":0,"last_error_class":"","last_smtp_code":0}' > "${status}"
    ! existing_notifier_v010_v020_mailer_status_is_valid "${status}"
)

write_source_model() {
    local destination="$1"
    jq -n '
      {
        services:{
          mattermost:{
            image:"mattermost/mattermost-team-edition:11.7.7@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            deploy:{replicas:1},
            environment:{
              MM_PLUGINSETTINGS_ENABLE:"true",
              THREADHUB_DOMAIN:"threadhub.valid.test",
              NOTIFIER_MAILER_URL:"http://threadhub-mailer:8080",
              NOTIFIER_HMAC_SECRET:"1111111111111111111111111111111111111111111111111111111111111111",
              NOTIFIER_CONTROL_FILE:"/run/threadhub-notifier/state.json",
              NOTIFIER_POLL_EVERY:"1s"
            },
            volumes:[
              {type:"bind",source:"/srv/threadhub/plugins",target:"/mattermost/plugins",read_only:false},
              {type:"bind",source:"/srv/threadhub/data",target:"/mattermost/data",read_only:false},
              {type:"bind",source:"/srv/threadhub-notifier/control",target:"/run/threadhub-notifier",read_only:true}
            ],
            networks:{database:{},"threadhub-notifier-internal":{}}
          },
          postgres:{
            image:"postgres:18.4@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
            deploy:{replicas:1},
            volumes:[{type:"bind",source:"/srv/threadhub/postgres",target:"/var/lib/postgresql",read_only:false}],
            networks:{database:{}}
          },
          "threadhub-mailer":{
            image:"threadhub/notifier-mailer:0.1.0",
            deploy:{replicas:1},
            environment:{
              THREADHUB_DOMAIN:"threadhub.valid.test",
              NOTIFIER_HMAC_SECRET:"1111111111111111111111111111111111111111111111111111111111111111",
              NOTIFIER_QUEUE_PATH:"/var/lib/threadhub-notifier/queue.db",
              NOTIFIER_CONTROL_FILE:"/run/threadhub-notifier/state.json"
            },
            volumes:[
              {type:"bind",source:"/srv/threadhub-notifier/mailer",target:"/var/lib/threadhub-notifier",read_only:false},
              {type:"bind",source:"/srv/threadhub-notifier/control",target:"/run/threadhub-notifier",read_only:true}
            ],
            networks:{"threadhub-notifier-internal":{},"threadhub-notifier-outbound":{}}
          }
        },
        networks:{database:{internal:true},"threadhub-notifier-internal":{internal:true},"threadhub-notifier-outbound":{}}
      }
    ' > "${destination}"
}

test_source_model_is_exact_and_unambiguous() (
    prepare_config_fixture
    trap 'rm -rf -- "${fixture}"' EXIT
    model="${fixture}/model.json"
    write_source_model "${model}"
    # shellcheck source=../scripts/existing-notifier-v010-v020-preflight.sh
    source "${PREFLIGHT}"
    EXISTING_NOTIFIER_V010_V020_ENV_FILE="${legacy_env}"

    existing_notifier_v010_v020_assert_source_model "${model}" || return 1
    [[ "$(existing_notifier_v010_v020_postgres_service "${model}")" == postgres ]] || return 1

    jq '.services.mattermost.image="mattermost/mattermost-team-edition:11.7.8"' "${model}" > "${model}.new"
    mv "${model}.new" "${model}"
    ! existing_notifier_v010_v020_assert_source_model "${model}" || return 1
    write_source_model "${model}"
    jq '.services.postgres_copy=.services.postgres' "${model}" > "${model}.new"
    mv "${model}.new" "${model}"
    ! existing_notifier_v010_v020_assert_source_model "${model}" || return 1
    write_source_model "${model}"
    jq '.services.mattermost_copy=.services.mattermost' "${model}" > "${model}.new"
    mv "${model}.new" "${model}"
    ! existing_notifier_v010_v020_assert_source_model "${model}" || return 1
    write_source_model "${model}"
    jq '.services["threadhub-mailer"].environment.NOTIFIER_CONTENT_MODE="generic"' "${model}" > "${model}.new"
    mv "${model}.new" "${model}"
    ! existing_notifier_v010_v020_assert_source_model "${model}" || return 1
    write_source_model "${model}"
    jq '(.services.postgres.volumes[0].type)="volume"' "${model}" > "${model}.new"
    mv "${model}.new" "${model}"
    ! existing_notifier_v010_v020_assert_source_model "${model}"
)

write_preflight_config() {
    cat > "${config}" <<EOF
THN_COMPOSE_PROJECT_DIR=${project_dir}
THN_COMPOSE_FILE=${compose_file}
THN_COMPOSE_ENV_FILE=${compose_env}
THN_MATTERMOST_SERVICE=mattermost
THN_MATTERMOST_PLUGINS_ROOT=${plugins_root}
THN_MATTERMOST_DATA_ROOT=${mattermost_data_root}
THN_DATA_ROOT=${notifier_root}
THN_DOMAIN=threadhub.valid.test
THN_SMTP_SERVER=smtp.email.ap-singapore-1.oci.oraclecloud.com
THN_SMTP_PORT=587
THN_SMTP_CA_FILE=${smtp_ca}
THN_SMTP_USERNAME=fixture-smtp-user
THN_SMTP_PASSWORD=fixture-private-password
THN_SMTP_FROM_ADDRESS=no-reply@valid.test
THN_SMTP_REPLY_TO_ADDRESS=admin@valid.test
THN_SMTP_FEEDBACK_NAME=ThreadHub
THN_HMAC_SECRET=1111111111111111111111111111111111111111111111111111111111111111
THN_RATE_PER_MINUTE=10
EOF
    chmod 0600 "${config}"
}

write_preflight_model() {
    jq -n \
      --arg plugins "${plugins_root}" \
      --arg data "${mattermost_data_root}" \
      --arg postgres "${postgres_root}" \
      --arg notifier "${notifier_root}" '
      {
        services:{
          mattermost:{
            image:"mattermost/mattermost-team-edition:11.7.7@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            environment:{
              MM_PLUGINSETTINGS_ENABLE:"true",THREADHUB_DOMAIN:"threadhub.valid.test",
              NOTIFIER_MAILER_URL:"http://threadhub-mailer:8080",
              NOTIFIER_HMAC_SECRET:"1111111111111111111111111111111111111111111111111111111111111111",
              NOTIFIER_CONTROL_FILE:"/run/threadhub-notifier/state.json",NOTIFIER_POLL_EVERY:"1s"
            },
            volumes:[
              {type:"bind",source:$plugins,target:"/mattermost/plugins",read_only:false},
              {type:"bind",source:$data,target:"/mattermost/data",read_only:false},
              {type:"bind",source:($notifier+"/control"),target:"/run/threadhub-notifier",read_only:true}
            ]
          },
          postgres:{
            image:"postgres:18.4@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
            volumes:[{type:"bind",source:$postgres,target:"/var/lib/postgresql",read_only:false}]
          },
          "threadhub-mailer":{
            image:"threadhub/notifier-mailer:0.1.0",
            environment:{
              THREADHUB_DOMAIN:"threadhub.valid.test",
              NOTIFIER_HMAC_SECRET:"1111111111111111111111111111111111111111111111111111111111111111",
              NOTIFIER_QUEUE_PATH:"/var/lib/threadhub-notifier/queue.db",
              NOTIFIER_CONTROL_FILE:"/run/threadhub-notifier/state.json"
            },
            volumes:[
              {type:"bind",source:($notifier+"/mailer"),target:"/var/lib/threadhub-notifier",read_only:false},
              {type:"bind",source:($notifier+"/control"),target:"/run/threadhub-notifier",read_only:true}
            ]
          }
        }
      }
    ' > "${model}"
}

prepare_preflight_fixture() {
    umask 022
    fixture="$(mktemp -d)"
    project_dir="${fixture}/project"
    compose_file="${project_dir}/compose.yml"
    compose_env="${project_dir}/.env"
    plugins_root="${fixture}/mattermost/plugins"
    mattermost_data_root="${fixture}/mattermost/data"
    postgres_root="${fixture}/postgres"
    notifier_root="${fixture}/notifier"
    smtp_ca="${fixture}/ca.crt"
    config="${fixture}/existing-notifier.env"
    model="${fixture}/model.json"
    calls="${fixture}/calls"
    output="${fixture}/output"
    release_file="${notifier_root}/release/release.env"
    gate_file="${notifier_root}/migration/recovery-gate-v010-v020.json"
    queue_file="${notifier_root}/mailer/queue.db"
    control_file="${notifier_root}/control/state.json"
    override_file="${notifier_root}/compose.override.yml"
    bundle_file="${mattermost_data_root}/plugins/com.threadhub.channel-email-notifier.tar.gz"
    mkdir -p "${project_dir}" "${plugins_root}/com.threadhub.channel-email-notifier" \
      "${mattermost_data_root}/plugins" "${postgres_root}" \
      "${notifier_root}/release" "${notifier_root}/migration" \
      "${notifier_root}/mailer" "${notifier_root}/control"
    printf '%s\n' 'services: {}' > "${compose_file}"
    printf '%s\n' 'PRIVATE_BASE_ENV=preserved' > "${compose_env}"
    chmod 0600 "${compose_env}"
    printf '%s\n' 'fixture-ca' > "${smtp_ca}"
    printf '%s\n' 'source-override' > "${override_file}"
    chmod 0600 "${override_file}"
    printf '%s\n' 'source-queue' > "${queue_file}"
    chmod 0600 "${queue_file}"
    printf '%s\n' '{"enabled":true,"delivery_enabled":true,"mode":"all_channels","channel_ids":[],"activated_at":1}' > "${control_file}"
    chmod 0640 "${control_file}"
    printf '%s\n' 'source-bundle' > "${bundle_file}"
    chmod 0640 "${bundle_file}"
    write_preflight_config
    write_preflight_model
    write_source_release "${release_file}"
    write_recovery_gate "${gate_file}" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    : > "${calls}"
    fixture_version=11.7.7
    fixture_postgres_version=18.4
    fixture_postgres_suffix=' (Debian 18.4-1.pgdg13+2)'
    fixture_pair_presence=present
    fixture_pair_sha=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
    fixture_plugin_json='{"active":[{"id":"com.threadhub.channel-email-notifier","version":"0.1.0"}],"inactive":[]}'
    fixture_running_image_id=sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
    fixture_status='{"pending":2,"sending":0,"sent":7,"failed":1,"oldest_pending_seconds":9,"last_success_at":10,"last_error_class":"temporary","last_smtp_code":451}'
    fixture_change_config_on_status=false
    fixture_pair_change_after_first=false
    fixture_pair_calls=0
}

fake_preflight_base_compose() {
    printf 'base %s\n' "$*" >> "${calls}"
    case "$*" in
      'config --quiet') return 0 ;;
      *) return 2 ;;
    esac
}

fake_preflight_combined_compose() {
    printf 'combined %s\n' "$*" >> "${calls}"
    case "$*" in
      'config --quiet') return 0 ;;
      'config --format json') cat "${model}" ;;
      'ps -q mattermost') printf '%064d\n' 1 ;;
      'ps -q postgres') printf '%064d\n' 2 ;;
      'ps -q threadhub-mailer') printf '%064d\n' 3 ;;
      'exec -T mattermost mattermost version') printf 'Version: %s\nBuild Enterprise Ready: false\n' "${fixture_version}" ;;
      'exec -T postgres psql --version') printf 'psql (PostgreSQL) %s%s\n' "${fixture_postgres_version}" "${fixture_postgres_suffix}" ;;
      'exec -T mattermost mmctl config get ServiceSettings.SiteURL --local --suppress-warnings') printf '%s\n' 'https://threadhub.valid.test' ;;
      'exec -T mattermost mmctl plugin list --local --suppress-warnings --json') printf '%s\n' "${fixture_plugin_json}" ;;
      'exec -T threadhub-mailer /threadhub-mailer status --json')
        if [[ "${fixture_change_config_on_status}" == true ]]; then printf '%s\n' '# changed' >> "${config}"; fi
        printf '%s\n' "${fixture_status}"
        ;;
      *) return 2 ;;
    esac
}

run_preflight_fixture() {
    THREADHUB_EXISTING_NOTIFIER_ENV_FILE="${config}"
    export THREADHUB_EXISTING_NOTIFIER_ENV_FILE
    # shellcheck source=../scripts/existing-notifier-v010-v020-preflight.sh
    declare -F existing_notifier_v010_v020_preflight_entry >/dev/null || source "${PREFLIGHT}"
    EXISTING_NOTIFIER_V010_V020_ENV_FILE="${config}"
    require_ubuntu_amd64() { :; }
    require_command() { command -v "$1" >/dev/null; }
    init_sudo() { SUDO_COMMAND=(env); }
    init_docker() { DOCKER_COMMAND=(docker); }
    existing_notifier_v010_v020_assert_runtime_paths() { [[ "${fixture_pair_presence}" == present ]]; }
    existing_notifier_v010_v020_init_compose() { :; }
    existing_notifier_v010_v020_compose_base() { fake_preflight_base_compose "$@"; }
    existing_notifier_v010_v020_compose_combined() { fake_preflight_combined_compose "$@"; }
    existing_notifier_v010_v020_container_is_healthy() { return 0; }
    existing_notifier_v010_v020_privileged_identity() {
      case "$1" in
        "${release_file}") printf '%s\n' 0:0:640 ;;
        "${gate_file}") printf '%s\n' 0:0:600 ;;
        "$(dirname "${gate_file}")") printf '%s\n' 0:0:700 ;;
        *) printf '%s\n' 0:0:600 ;;
      esac
    }
    existing_notifier_v010_v020_review_source_pair() {
      fixture_pair_calls=$((fixture_pair_calls + 1))
      if [[ "${fixture_pair_change_after_first}" == true && "${fixture_pair_calls}" -gt 1 ]]; then
        fixture_pair_sha=dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd
      fi
      [[ "${fixture_pair_presence}" == present && "${fixture_pair_sha}" == "$3" ]] || return 1
      jq -e '
        type == "object" and
        ([.active[]? | select(.id == "com.threadhub.channel-email-notifier" and .version == "0.1.0")] | length == 1) and
        ([.inactive[]? | select(.id == "com.threadhub.channel-email-notifier")] | length == 0) and
        ([.active[]?,.inactive[]? | select(.id == "com.threadhub.channel-email-notifier")] | length == 1)
      ' <<< "${fixture_plugin_json}" >/dev/null || return 1
      EXISTING_NOTIFIER_V010_PAIR_SHA="${fixture_pair_sha}"
    }
    existing_notifier_v010_v020_running_image_id() { printf '%s\n' "${fixture_running_image_id}"; }
    existing_notifier_v010_v020_preflight_entry "$@"
}

test_supported_preflight_is_read_only_and_privacy_safe() (
    prepare_preflight_fixture
    trap 'rm -rf -- "${fixture}"' EXIT
    before="$(portable_hash "${config}") $(portable_hash "${compose_file}") $(portable_hash "${compose_env}") $(portable_hash "${release_file}") $(portable_hash "${override_file}") $(portable_hash "${queue_file}") $(portable_hash "${control_file}") $(portable_hash "${bundle_file}")"
    run_preflight_fixture > "${output}" 2>&1 || return 1
    after="$(portable_hash "${config}") $(portable_hash "${compose_file}") $(portable_hash "${compose_env}") $(portable_hash "${release_file}") $(portable_hash "${override_file}") $(portable_hash "${queue_file}") $(portable_hash "${control_file}") $(portable_hash "${bundle_file}")"
    [[ "${before}" == "${after}" ]] || return 1
    [[ ! -e "${notifier_root}/migration/existing-notifier-v010-v020" ]] || return 1
    grep -F '[OK] Exact notifier v0.1.0 source profile is read-only and supported' "${output}" >/dev/null || return 1
    ! grep -F -e fixture-private-password -e 1111111111111111111111111111111111111111111111111111111111111111 "${output}" >/dev/null || return 1
    ! grep -Eq '(^| )(up|create|start|restart|stop|rm|mv|cp)( |$)' "${calls}"
)

test_release_pair_image_and_plugin_mismatches_exit_twenty() (
    prepare_preflight_fixture
    trap 'rm -rf -- "${fixture}"' EXIT

    sed -i.bak 's/NOTIFIER_SOURCE_COMMIT=.*/NOTIFIER_SOURCE_COMMIT=ffffffffffffffffffffffffffffffffffffffff/' "${release_file}"
    rm -f "${release_file}.bak"
    set +e; run_preflight_fixture > "${output}" 2>&1; result=$?; set -e
    [[ "${result}" == 20 ]] || return 1

    write_source_release "${release_file}"
    fixture_pair_sha=cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
    set +e; run_preflight_fixture > "${output}" 2>&1; result=$?; set -e
    [[ "${result}" == 20 ]] || return 1

    fixture_pair_sha=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
    fixture_running_image_id=sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
    set +e; run_preflight_fixture > "${output}" 2>&1; result=$?; set -e
    [[ "${result}" == 20 ]] || return 1

    fixture_running_image_id=sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
    fixture_pair_presence=partial
    set +e; run_preflight_fixture > "${output}" 2>&1; result=$?; set -e
    [[ "${result}" == 20 ]] || return 1
    fixture_pair_presence=present

    fixture_plugin_json='{"active":[],"inactive":[{"id":"com.threadhub.channel-email-notifier","version":"0.1.0"}]}'
    set +e; run_preflight_fixture > "${output}" 2>&1; result=$?; set -e
    [[ "${result}" == 20 ]] || return 1
    fixture_plugin_json='{"active":[{"id":"com.threadhub.channel-email-notifier","version":"0.1.0"},{"id":"com.threadhub.channel-email-notifier","version":"0.1.0"}],"inactive":[]}'
    set +e; run_preflight_fixture > "${output}" 2>&1; result=$?; set -e
    [[ "${result}" == 20 ]] || return 1
    ! grep -F fixture-private-password "${output}" >/dev/null
)

test_model_version_queue_gate_and_identity_fail_closed() (
    prepare_preflight_fixture
    trap 'rm -rf -- "${fixture}"' EXIT

    fixture_version=11.7.8
    set +e; run_preflight_fixture > "${output}" 2>&1; result=$?; set -e
    [[ "${result}" == 20 ]] || return 1
    fixture_version=11.7.7

    fixture_postgres_version=18.5
    set +e; run_preflight_fixture > "${output}" 2>&1; result=$?; set -e
    [[ "${result}" == 20 ]] || return 1
    fixture_postgres_version=18.4

    fixture_status='{"pending":0,"sending":0,"sent":0,"failed":0,"oldest_pending_seconds":0,"last_success_at":0,"last_error_class":"","last_smtp_code":0,"recipient":"private@valid.test"}'
    set +e; run_preflight_fixture > "${output}" 2>&1; result=$?; set -e
    [[ "${result}" == 20 ]] || return 1
    fixture_status='{"pending":0,"sending":0,"sent":0,"failed":0,"oldest_pending_seconds":0,"last_success_at":0,"last_error_class":"","last_smtp_code":0}'

    rm -f "${gate_file}"
    set +e; run_preflight_fixture > "${output}" 2>&1; result=$?; set -e
    [[ "${result}" == 20 ]] || return 1
    write_recovery_gate "${gate_file}" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

    fixture_change_config_on_status=true
    set +e; run_preflight_fixture > "${output}" 2>&1; result=$?; set -e
    [[ "${result}" == 20 ]] || return 1
    fixture_change_config_on_status=false

    write_preflight_config
    fixture_pair_calls=0
    fixture_pair_change_after_first=true
    set +e; run_preflight_fixture > "${output}" 2>&1; result=$?; set -e
    [[ "${result}" == 20 ]] || return 1
    ! grep -F fixture-private-password "${output}" >/dev/null
)

test_preflight_accepts_no_mutation_flags() (
    prepare_preflight_fixture
    trap 'rm -rf -- "${fixture}"' EXIT
    set +e
    (run_preflight_fixture --force) > "${output}" 2>&1
    result=$?
    set -e
    [[ "${result}" == 1 ]] || return 1
    [[ ! -e "${notifier_root}/migration/existing-notifier-v010-v020" ]] || return 1
    ! grep -F fixture-private-password "${output}" >/dev/null
)

run_test 'v0.1-to-v0.2 common library exists' test_common_exists
if [[ -f "${COMMON}" ]]; then
    run_test 'legacy configuration has the exact source keyset' test_legacy_config_has_exact_keyset
    run_test 'target configuration has the exact target keyset' test_target_config_has_exact_keyset
    run_test 'target-shaped temporary copy is private and preserves the source' test_target_copy_is_private_and_preserves_source
    run_test 'partial, duplicate, unknown, and CRLF configurations are rejected' test_partial_duplicate_unknown_or_crlf_config_is_rejected
    run_test 'unsafe configuration files are rejected without value disclosure' test_unsafe_config_file_is_rejected_without_values
fi
run_test 'v0.1-to-v0.2 read-only preflight exists' test_preflight_exists
if [[ -f "${PREFLIGHT}" ]]; then
    run_test 'source release requires exact version, commit, and image identity' test_source_release_requires_exact_version_commit_and_image_identity
    run_test 'recovery gate is exact, current, and private' test_recovery_gate_is_exact_current_and_private
    run_test 'Mailer status accepts only fixed privacy-safe aggregates' test_mailer_status_accepts_only_safe_fixed_aggregates
    run_test 'source Compose model is exact and unambiguous' test_source_model_is_exact_and_unambiguous
    run_test 'supported preflight is read-only and privacy-safe' test_supported_preflight_is_read_only_and_privacy_safe
    run_test 'release, pair, image, and plugin mismatches exit 20' test_release_pair_image_and_plugin_mismatches_exit_twenty
    run_test 'model, version, queue, gate, and identity checks fail closed' test_model_version_queue_gate_and_identity_fail_closed
    run_test 'preflight accepts no mutation flags' test_preflight_accepts_no_mutation_flags
fi

if ((failures > 0)); then
    exit 1
fi
