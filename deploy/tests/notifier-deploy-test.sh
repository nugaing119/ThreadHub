#!/usr/bin/env bash

set -Eeuo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(cd "${TEST_DIR}/.." && pwd)"
REPOSITORY_ROOT="$(cd "${DEPLOY_DIR}/.." && pwd)"
failures=0

fail() {
    printf 'not ok - %s\n' "$1" >&2
    failures=$((failures + 1))
}

pass() {
    printf 'ok - %s\n' "$1"
}

portable_identity() {
    if stat -c '%u:%g:%a' "$1" >/dev/null 2>&1; then
        stat -c '%u:%g:%a' "$1"
    else
        stat -f '%u:%g:%Lp' "$1"
    fi
}

test_transaction_rollback_after_backup() (
    transaction_library="${DEPLOY_DIR}/scripts/notifier-plugin-transaction.sh"
    [[ -f "${transaction_library}" ]] || return 1
    # shellcheck source=/dev/null
    source "${transaction_library}"
    declare -F notifier_plugin_transaction >/dev/null || return 1

    fixture="$(mktemp -d)"
    trap 'rm -rf "${fixture}"' EXIT
    target="${fixture}/plugins/notifier"
    stage="${fixture}/release/stage"
    backup="${fixture}/release/backup"
    failed="${fixture}/release/failed"
    mkdir -p "${target}" "${stage}"
    printf 'old\n' > "${target}/generation"
    printf 'new\n' > "${stage}/generation"
    printf 'running\n' > "${fixture}/service"
    printf 'active\n' > "${fixture}/plugin"
    printf 'enabled\n' > "${fixture}/control"

    # shellcheck disable=SC2329 # transaction callback fixture
    plugin_tx_disable_control() { printf 'disabled\n' > "${fixture}/control"; }
    # shellcheck disable=SC2329 # transaction callback fixture
    plugin_tx_disable_plugin() { printf 'inactive\n' > "${fixture}/plugin"; }
    # shellcheck disable=SC2329 # transaction callback fixture
    plugin_tx_stop_service() { printf 'stopped\n' > "${fixture}/service"; }
    # shellcheck disable=SC2329 # transaction callback fixture
    plugin_tx_start_service() { printf 'running\n' > "${fixture}/service"; }
    # shellcheck disable=SC2329 # transaction callback fixture
    plugin_tx_enable_plugin() { printf 'active\n' > "${fixture}/plugin"; }
    # shellcheck disable=SC2329 # transaction callback fixture
    plugin_tx_verify_plugin() { [[ "$(<"${fixture}/plugin")" == active ]]; }
    # shellcheck disable=SC2329 # transaction callback fixture
    plugin_tx_verify_previous_plugin() { [[ "$(<"${fixture}/plugin")" == active ]]; }
    # shellcheck disable=SC2329 # transaction callback fixture
    plugin_tx_path_exists() { [[ -e "$1" ]]; }
    # shellcheck disable=SC2329 # transaction callback fixture
    plugin_tx_move() {
        if [[ "$1" == "${stage}" && "$2" == "${target}" ]]; then
            return 91
        fi
        mv "$1" "$2"
    }

    if notifier_plugin_transaction \
        "${target}" "${stage}" "${backup}" "${failed}" true true \
        > "${fixture}/stdout" 2> "${fixture}/stderr"; then
        return 1
    fi
    if [[ ! -f "${target}/generation" || "$(<"${target}/generation")" != old ]] \
        || [[ "$(<"${fixture}/service")" != running ]] \
        || [[ "$(<"${fixture}/plugin")" != active ]] \
        || [[ "$(<"${fixture}/control")" != disabled ]] \
        || [[ -e "${backup}" ]]; then
        sed 's/^/[transaction stderr] /' "${fixture}/stderr" >&2
        find "${fixture}" -mindepth 1 -maxdepth 4 -print >&2
        return 1
    fi
)

test_transaction_retries_control_disable_during_rollback() (
    transaction_library="${DEPLOY_DIR}/scripts/notifier-plugin-transaction.sh"
    [[ -f "${transaction_library}" ]] || return 1
    # shellcheck source=/dev/null
    source "${transaction_library}"

    fixture="$(mktemp -d)"
    trap 'rm -rf "${fixture}"' EXIT
    target="${fixture}/plugins/notifier"
    stage="${fixture}/release/stage"
    backup="${fixture}/release/backup"
    failed="${fixture}/release/failed"
    mkdir -p "${target}" "${stage}"
    printf 'old\n' > "${target}/generation"
    printf 'new\n' > "${stage}/generation"
    printf 'running\n' > "${fixture}/service"
    printf 'active\n' > "${fixture}/plugin"
    printf 'enabled\n' > "${fixture}/control"
    printf '0\n' > "${fixture}/disable-attempts"

    # shellcheck disable=SC2329 # transaction callback fixture
    plugin_tx_disable_control() {
        disable_attempts="$(<"${fixture}/disable-attempts")"
        disable_attempts=$((disable_attempts + 1))
        printf '%s\n' "${disable_attempts}" > "${fixture}/disable-attempts"
        if ((disable_attempts == 1)); then
            # Production validation helpers fail with exit, not return. The
            # transaction must contain that exit and still run its rollback.
            exit 88
        fi
        printf 'disabled\n' > "${fixture}/control"
    }
    # shellcheck disable=SC2329 # transaction callback fixture
    plugin_tx_disable_plugin() { printf 'inactive\n' > "${fixture}/plugin"; }
    # shellcheck disable=SC2329 # transaction callback fixture
    plugin_tx_stop_service() { printf 'stopped\n' > "${fixture}/service"; }
    # shellcheck disable=SC2329 # transaction callback fixture
    plugin_tx_start_service() { printf 'running\n' > "${fixture}/service"; }
    # shellcheck disable=SC2329 # transaction callback fixture
    plugin_tx_enable_plugin() { printf 'active\n' > "${fixture}/plugin"; }
    # shellcheck disable=SC2329 # transaction callback fixture
    plugin_tx_verify_plugin() { [[ "$(<"${fixture}/plugin")" == active ]]; }
    # shellcheck disable=SC2329 # transaction callback fixture
    plugin_tx_verify_previous_plugin() { [[ "$(<"${fixture}/plugin")" == active ]]; }
    # shellcheck disable=SC2329 # transaction callback fixture
    plugin_tx_path_exists() { [[ -e "$1" ]]; }
    # shellcheck disable=SC2329 # transaction callback fixture
    plugin_tx_move() { mv "$1" "$2"; }

    if notifier_plugin_transaction \
        "${target}" "${stage}" "${backup}" "${failed}" true true \
        > "${fixture}/stdout" 2> "${fixture}/stderr"; then
        return 1
    fi
    [[ "$(<"${fixture}/control")" == disabled ]] || return 1
    [[ "$(<"${fixture}/disable-attempts")" == 2 ]] || return 1
    [[ -f "${target}/generation" && "$(<"${target}/generation")" == old ]] || return 1
    [[ "$(<"${fixture}/service")" == running ]] || return 1
    [[ "$(<"${fixture}/plugin")" == active ]] || return 1
)

test_transaction_reports_rollback_failure_and_continues_restore() (
    transaction_library="${DEPLOY_DIR}/scripts/notifier-plugin-transaction.sh"
    [[ -f "${transaction_library}" ]] || return 1
    # shellcheck source=/dev/null
    source "${transaction_library}"

    fixture="$(mktemp -d)"
    trap 'rm -rf "${fixture}"' EXIT
    target="${fixture}/plugins/notifier"
    stage="${fixture}/release/stage"
    backup="${fixture}/release/backup"
    failed="${fixture}/release/failed"
    mkdir -p "${target}" "${stage}"
    printf 'old\n' > "${target}/generation"
    printf 'new\n' > "${stage}/generation"
    printf 'running\n' > "${fixture}/service"
    printf 'active\n' > "${fixture}/plugin"
    printf 'enabled\n' > "${fixture}/control"
    printf '0\n' > "${fixture}/disable-attempts"

    # shellcheck disable=SC2329 # transaction callback fixture
    plugin_tx_disable_control() {
        disable_attempts="$(<"${fixture}/disable-attempts")"
        disable_attempts=$((disable_attempts + 1))
        printf '%s\n' "${disable_attempts}" > "${fixture}/disable-attempts"
        if ((disable_attempts > 1)); then
            exit 89
        fi
        printf 'disabled\n' > "${fixture}/control"
    }
    # shellcheck disable=SC2329 # transaction callback fixture
    plugin_tx_disable_plugin() { printf 'inactive\n' > "${fixture}/plugin"; }
    # shellcheck disable=SC2329 # transaction callback fixture
    plugin_tx_stop_service() { printf 'stopped\n' > "${fixture}/service"; }
    # shellcheck disable=SC2329 # transaction callback fixture
    plugin_tx_start_service() { printf 'running\n' > "${fixture}/service"; }
    # shellcheck disable=SC2329 # transaction callback fixture
    plugin_tx_enable_plugin() { printf 'active\n' > "${fixture}/plugin"; }
    # shellcheck disable=SC2329 # transaction callback fixture
    plugin_tx_verify_plugin() { [[ "$(<"${fixture}/plugin")" == active ]]; }
    # shellcheck disable=SC2329 # transaction callback fixture
    plugin_tx_verify_previous_plugin() { [[ "$(<"${fixture}/plugin")" == active ]]; }
    # shellcheck disable=SC2329 # transaction callback fixture
    plugin_tx_path_exists() { [[ -e "$1" ]]; }
    # shellcheck disable=SC2329 # transaction callback fixture
    plugin_tx_move() {
        if [[ "$1" == "${stage}" && "$2" == "${target}" ]]; then
            return 91
        fi
        mv "$1" "$2"
    }

    set +e
    notifier_plugin_transaction \
        "${target}" "${stage}" "${backup}" "${failed}" true true \
        > "${fixture}/stdout" 2> "${fixture}/stderr"
    transaction_result=$?
    set -e
    [[ "${transaction_result}" == 70 ]] || return 1
    grep -F 'rollback is incomplete (control_disable)' "${fixture}/stderr" >/dev/null \
        || return 1
    [[ -f "${target}/generation" && "$(<"${target}/generation")" == old ]] || return 1
    [[ "$(<"${fixture}/service")" == running ]] || return 1
    [[ "$(<"${fixture}/plugin")" == active ]] || return 1
    [[ "$(<"${fixture}/control")" == disabled ]] || return 1
)

test_symlink_referents_unchanged() (
    # shellcheck source=../scripts/common.sh
    source "${DEPLOY_DIR}/scripts/common.sh"
    declare -F notifier_assert_no_symlink_components >/dev/null || return 1
    SUDO_COMMAND=(env)

    fixture="$(mktemp -d)"
    trap 'rm -rf "${fixture}"' EXIT
    for child in control mailer release; do
        root="${fixture}/${child}/threadhub"
        referent="${fixture}/${child}/referent"
        mkdir -p "${root}/notifier" "${referent}"
        chmod 0711 "${referent}"
        printf 'do-not-change-%s\n' "${child}" > "${referent}/marker"
        before_identity="$(portable_identity "${referent}")"
        before_hash="$(sha256_file "${referent}/marker")"
        ln -s "${referent}" "${root}/notifier/${child}"

        if notifier_assert_no_symlink_components "${root}" >/dev/null 2>&1; then
            return 1
        fi
        [[ "$(portable_identity "${referent}")" == "${before_identity}" ]] || return 1
        [[ "$(sha256_file "${referent}/marker")" == "${before_hash}" ]] || return 1
    done
)

test_writable_notifier_parent_is_rejected_without_mutation() (
    # shellcheck source=../scripts/common.sh
    # shellcheck disable=SC2031 # each test function executes in its own subshell
    source "${DEPLOY_DIR}/scripts/common.sh"

    fixture="$(mktemp -d)"
    trap 'rm -rf "${fixture}"' EXIT
    parent="${fixture}/threadhub"
    referent="${fixture}/referent"
    mkdir -p "${parent}" "${referent}"
    printf 'do-not-change-parent-policy\n' > "${referent}/marker"
    ln -s "${referent}" "${parent}/notifier"
    before_identity="$(portable_identity "${referent}")"
    before_hash="$(sha256_file "${referent}/marker")"

    # shellcheck disable=SC2329 # invoked through the SUDO_COMMAND callback array
    notifier_test_command() {
        if [[ "$1" == stat && "$2" == -c ]]; then
            requested_format="$3"
            requested_path="$4"
            actual_mode="$(portable_identity "${requested_path}")"
            actual_mode="${actual_mode##*:}"
            case "${requested_format}" in
                '%u:%g') printf '0:0\n' ;;
                '%u:%g:%a') printf '0:0:%s\n' "${actual_mode}" ;;
                *) return 97 ;;
            esac
            return
        fi
        command "$@"
    }
    SUDO_COMMAND=(notifier_test_command)

    for unsafe_mode in 0777 0775; do
        chmod "${unsafe_mode}" "${parent}"
        if notifier_assert_existing_directory_policy "${parent}" 0 0 750; then
            return 1
        fi
        [[ "$(portable_identity "${referent}")" == "${before_identity}" ]] || return 1
        [[ "$(sha256_file "${referent}/marker")" == "${before_hash}" ]] || return 1
    done
)

test_deploy_validates_notifier_layout_top_down() (
    # shellcheck disable=SC2031 # each test function executes in its own subshell
    awk '
        index($0, "install -d -o root -g root -m 0750 \"${data_root}\"") { if (state != 0) exit 1; state = 1; next }
        state == 1 && index($0, "validate_notifier_host_path \"${data_root}\"") { state = 2; next }
        state == 2 && index($0, "install -d -o root -g root -m 0750 \"${notifier_root}\"") { state = 3; next }
        state == 3 && index($0, "validate_notifier_host_path \"${data_root}\"") { state = 4; next }
        state == 4 && index($0, "${notifier_root}/control") { state = 5; next }
        state == 5 && index($0, "${notifier_root}/mailer") { state = 6; next }
        state == 6 && index($0, "${notifier_root}/release") { state = 7; next }
        state == 7 && index($0, "validate_notifier_host_path \"${data_root}\"") { state = 8; next }
        END { exit(state == 8 ? 0 : 1) }
    ' "${DEPLOY_DIR}/scripts/deploy.sh"
)

test_compose_v531_canonical_model() (
    # shellcheck source=../scripts/common.sh
    # shellcheck disable=SC2031 # each test function executes in its own subshell
    source "${DEPLOY_DIR}/scripts/common.sh"
    command -v jq >/dev/null || return 1

    fixture="$(mktemp -d)"
    trap 'rm -rf "${fixture}"' EXIT
    compose_model="${fixture}/compose-v5.3.1.json"
    fake_bin="${fixture}/bin"
    mkdir "${fake_bin}"
    builder_image="$(env_value GO_BUILDER_IMAGE_REPOSITORY "${VERSIONS_FILE}"):$(env_value GO_BUILDER_IMAGE_TAG "${VERSIONS_FILE}")@$(env_value GO_BUILDER_IMAGE_DIGEST "${VERSIONS_FILE}")"
    notifier_version="$(env_value NOTIFIER_VERSION "${VERSIONS_FILE}")"

    jq -n \
        --arg builder "${builder_image}" \
        --arg context "${REPOSITORY_ROOT}/notifier" \
        --arg image "threadhub/notifier-mailer:${notifier_version}" '
        {
          services: {
            postgres: {networks:{database:null}},
            mattermost: {
              environment: {
                MM_PLUGINSETTINGS_ENABLE:"true",
                MM_PLUGINSETTINGS_ENABLEUPLOADS:"false",
                MM_PLUGINSETTINGS_ENABLEMARKETPLACE:"false",
                MM_PLUGINSETTINGS_ENABLEREMOTEMARKETPLACE:"false",
                MM_PLUGINSETTINGS_AUTOMATICPREPACKAGEDPLUGINS:"false",
                MM_EMAILSETTINGS_SENDEMAILNOTIFICATIONS:"false",
                MM_EMAILSETTINGS_SENDPUSHNOTIFICATIONS:"false",
                MM_SERVICESETTINGS_ENABLEINCOMINGWEBHOOKS:"false",
                MM_SERVICESETTINGS_ENABLEOUTGOINGWEBHOOKS:"false",
                MM_SERVICESETTINGS_ENABLEBOTACCOUNTCREATION:"false",
                MM_SERVICESETTINGS_ENABLEUSERACCESSTOKENS:"false",
                THREADHUB_DOMAIN:"threadhub.internal",
                NOTIFIER_MAILER_URL:"http://threadhub-mailer:8080",
                NOTIFIER_HMAC_SECRET:("0" * 64),
                NOTIFIER_CONTROL_FILE:"/run/threadhub-notifier/state.json",
                NOTIFIER_POLL_EVERY:"1s"
              },
              group_add:["3000"],
              networks:{database:null,notifier:null,outbound:null},
              volumes:[
                {type:"bind",source:"/srv/threadhub/notifier/control",target:"/run/threadhub-notifier",read_only:true,bind:{}}
              ]
            },
            "threadhub-mailer": {
              image:$image,
              build:{context:$context,dockerfile:"Dockerfile",args:{GO_BUILDER_IMAGE:$builder},target:"mailer"},
              platform:"linux/amd64",
              user:"65532:65532",
              group_add:["3000"],
              read_only:true,
              cap_drop:["ALL"],
              security_opt:["no-new-privileges:true"],
              networks:{notifier:null,outbound:null},
              volumes:[
                {type:"bind",source:"/srv/threadhub/notifier/mailer",target:"/var/lib/threadhub-notifier",bind:{}},
                {type:"bind",source:"/srv/threadhub/notifier/control",target:"/run/threadhub-notifier",read_only:true,bind:{}}
              ],
              healthcheck:{test:["CMD","/threadhub-mailer","healthcheck"],timeout:"5s",interval:"10s",retries:10,start_period:"30s"},
              logging:{driver:"json-file",options:{"max-file":"3","max-size":"10m"}},
              environment: {
                NOTIFIER_CONTROL_FILE:"/run/threadhub-notifier/state.json",
                NOTIFIER_HMAC_SECRET:("0" * 64),
                NOTIFIER_LISTEN_ADDRESS:":8080",
                NOTIFIER_QUEUE_PATH:"/var/lib/threadhub-notifier/queue.db",
                NOTIFIER_RATE_PER_MINUTE:"10",
                SMTP_FEEDBACK_NAME:"ThreadHub",
                SMTP_FROM_ADDRESS:"no-reply@threadhub.internal",
                SMTP_PASSWORD:"fixture_password",
                SMTP_PORT:"587",
                SMTP_REPLY_TO_ADDRESS:"admin@threadhub.internal",
                SMTP_SERVER:"smtp.email.ap-singapore-1.oci.oraclecloud.com",
                SMTP_USERNAME:"fixture_user",
                THREADHUB_DOMAIN:"threadhub.internal"
              }
            }
          },
          networks:{database:{internal:true},notifier:{internal:true},outbound:{}}
        }
    ' > "${compose_model}"

    # The single-quoted expressions are emitted into the fake Docker script.
    # shellcheck disable=SC2016
    printf '%s\n' \
        '#!/usr/bin/env bash' \
        'set -Eeuo pipefail' \
        '[[ "${1:-}" == compose ]] || exit 97' \
        'shift' \
        'if [[ "${1:-}" == version ]]; then printf "Docker Compose version v5.3.1\\n"; exit 0; fi' \
        'case " $* " in' \
        '  *" config --format json "*) printf "json\\n" >> "${THREADHUB_TEST_COMPOSE_TRACE}"; /bin/cat "${THREADHUB_TEST_COMPOSE_JSON}" ;;' \
        '  *" config --quiet "*) printf "quiet\\n" >> "${THREADHUB_TEST_COMPOSE_TRACE}"; exit 0 ;;' \
        '  *) exit 98 ;;' \
        'esac' \
        > "${fake_bin}/docker"
    chmod 0700 "${fake_bin}/docker"

    PATH="${fake_bin}:${PATH}" \
        THREADHUB_TEST_COMPOSE_JSON="${compose_model}" \
        THREADHUB_TEST_COMPOSE_TRACE="${fixture}/compose.trace" \
        /bin/bash "${DEPLOY_DIR}/scripts/validate.sh" \
        > "${fixture}/output" 2>&1
    [[ "$(<"${fixture}/compose.trace")" == $'quiet\njson' ]]
)

test_no_validator_does_not_claim_success() (
    fixture="$(mktemp -d)"
    trap 'rm -rf "${fixture}"' EXIT
    command_dir="${fixture}/bin"
    mkdir "${command_dir}"
    for command_name in bash dirname awk grep mktemp rm sed chmod; do
        command_path="$(command -v "${command_name}")"
        ln -s "${command_path}" "${command_dir}/${command_name}"
    done

    set +e
    # shellcheck disable=SC2031 # each test function executes in its own subshell
    PATH="${command_dir}" /bin/bash "${DEPLOY_DIR}/scripts/validate.sh" \
        > "${fixture}/output" 2>&1
    result=$?
    set -e
    ((result != 0)) || return 1
    if grep -F 'Notifier Compose isolation, mounts, settings and hardening are valid' \
        "${fixture}/output" >/dev/null; then
        return 1
    fi
)

if test_transaction_rollback_after_backup; then
    pass "plugin transaction restores old target and runtime state after stage rename failure"
else
    fail "plugin transaction restores old target and runtime state after stage rename failure"
fi

if test_transaction_retries_control_disable_during_rollback; then
    pass "plugin rollback best-effort disables control after an initial disable failure"
else
    fail "plugin rollback best-effort disables control after an initial disable failure"
fi

if test_transaction_reports_rollback_failure_and_continues_restore; then
    pass "plugin rollback reports a failed step and continues restoring other state"
else
    fail "plugin rollback reports a failed step and continues restoring other state"
fi

if test_symlink_referents_unchanged; then
    pass "notifier host layout rejects child symlinks without changing referents"
else
    fail "notifier host layout rejects child symlinks without changing referents"
fi

if test_writable_notifier_parent_is_rejected_without_mutation; then
    pass "notifier parent policy rejects root-owned writable directories without mutating referents"
else
    fail "notifier parent policy rejects root-owned writable directories without mutating referents"
fi

if test_deploy_validates_notifier_layout_top_down; then
    pass "deployment validates each notifier parent before privileged child creation"
else
    fail "deployment validates each notifier parent before privileged child creation"
fi

if test_compose_v531_canonical_model; then
    pass "Docker Compose v5.3.1 canonical model accepts omitted RW read_only and exact Mailer metadata"
else
    fail "Docker Compose v5.3.1 canonical model accepts omitted RW read_only and exact Mailer metadata"
fi

if test_no_validator_does_not_claim_success; then
    pass "missing Compose and Ruby validators fails before a security-success claim"
else
    fail "missing Compose and Ruby validators fails before a security-success claim"
fi

((failures == 0))
