#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"
# shellcheck source=notifier-documentation-contracts.sh
source "${SCRIPT_DIR}/notifier-documentation-contracts.sh"

require_file "${COMPOSE_FILE}"
require_file "${ENV_EXAMPLE_FILE}"
require_file "${VERSIONS_FILE}"
ssh_hardening_file="${DEPLOY_DIR}/ssh/99-threadhub-hardening.conf"
require_file "${ssh_hardening_file}"

for script in "${SCRIPT_DIR}"/*.sh; do
    bash -n "${script}"
done
log "Bash syntax is valid"

for variable in \
    MATTERMOST_IMAGE_REPOSITORY \
    MATTERMOST_IMAGE_TAG \
    MATTERMOST_IMAGE_DIGEST \
    POSTGRES_IMAGE_REPOSITORY \
    POSTGRES_IMAGE_TAG \
    POSTGRES_IMAGE_DIGEST \
    NOTIFIER_VERSION \
    NOTIFIER_PLUGIN_ID \
    GO_BUILDER_IMAGE_REPOSITORY \
    GO_BUILDER_IMAGE_TAG \
    GO_BUILDER_IMAGE_DIGEST \
    GO_BUILDER_IMAGE_INDEX_DIGEST \
    DOCKER_CE_VERSION \
    DOCKER_CLI_VERSION \
    CONTAINERD_VERSION \
    DOCKER_COMPOSE_PLUGIN_VERSION; do
    env_value "${variable}" "${VERSIONS_FILE}" >/dev/null
done

mattermost_digest="$(env_value MATTERMOST_IMAGE_DIGEST "${VERSIONS_FILE}")"
postgres_digest="$(env_value POSTGRES_IMAGE_DIGEST "${VERSIONS_FILE}")"
go_builder_digest="$(env_value GO_BUILDER_IMAGE_DIGEST "${VERSIONS_FILE}")"
go_builder_index_digest="$(env_value GO_BUILDER_IMAGE_INDEX_DIGEST "${VERSIONS_FILE}")"
[[ "${mattermost_digest}" =~ ^sha256:[a-f0-9]{64}$ ]] \
    || die "MATTERMOST_IMAGE_DIGEST is invalid"
[[ "${postgres_digest}" =~ ^sha256:[a-f0-9]{64}$ ]] \
    || die "POSTGRES_IMAGE_DIGEST is invalid"
[[ "${go_builder_digest}" =~ ^sha256:[a-f0-9]{64}$ ]] \
    || die "GO_BUILDER_IMAGE_DIGEST is invalid"
[[ "${go_builder_index_digest}" =~ ^sha256:[a-f0-9]{64}$ ]] \
    || die "GO_BUILDER_IMAGE_INDEX_DIGEST is invalid"

validation_tmp_dir="$(mktemp -d)"
cleanup() {
    rm -rf "${validation_tmp_dir}"
}
trap cleanup EXIT
runtime_env_fixture="${validation_tmp_dir}/runtime.env"
sed \
    -e 's#^THREADHUB_DOMAIN=.*#THREADHUB_DOMAIN=threadhub.internal#' \
    -e 's#^LETSENCRYPT_EMAIL=.*#LETSENCRYPT_EMAIL=admin@threadhub.internal#' \
    -e 's#^POSTGRES_PASSWORD=.*#POSTGRES_PASSWORD=0000000000000000000000000000000000000000000000000000000000000000#' \
    -e 's#^SMTP_SERVER=.*#SMTP_SERVER=smtp.email.ap-singapore-1.oci.oraclecloud.com#' \
    -e 's#^SMTP_USERNAME=.*#SMTP_USERNAME=fixture_user#' \
    -e 's#^SMTP_PASSWORD=.*#SMTP_PASSWORD=fixture_password#' \
    -e 's#^SMTP_FROM_ADDRESS=.*#SMTP_FROM_ADDRESS=no-reply@threadhub.internal#' \
    -e 's#^SMTP_REPLY_TO_ADDRESS=.*#SMTP_REPLY_TO_ADDRESS=admin@threadhub.internal#' \
    -e 's#^NOTIFIER_HMAC_SECRET=.*#NOTIFIER_HMAC_SECRET=0000000000000000000000000000000000000000000000000000000000000000#' \
    "${ENV_EXAMPLE_FILE}" > "${runtime_env_fixture}"
chmod 0600 "${runtime_env_fixture}"

if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    require_command jq
    docker compose \
        --env-file "${runtime_env_fixture}" \
        --env-file "${VERSIONS_FILE}" \
        -f "${COMPOSE_FILE}" \
        config --quiet
    docker compose \
        --env-file "${runtime_env_fixture}" \
        --env-file "${VERSIONS_FILE}" \
        -f "${COMPOSE_FILE}" \
        config --format json > "${validation_tmp_dir}/compose.json"
    jq -e \
        --arg builder "$(env_value GO_BUILDER_IMAGE_REPOSITORY "${VERSIONS_FILE}"):$(env_value GO_BUILDER_IMAGE_TAG "${VERSIONS_FILE}")@${go_builder_digest}" \
        --arg build_context "${REPOSITORY_ROOT}/notifier" \
        --arg hmac '0000000000000000000000000000000000000000000000000000000000000000' \
        --arg mailer_image "threadhub/notifier-mailer:$(env_value NOTIFIER_VERSION "${VERSIONS_FILE}")" '
        .services as $services |
        $services.postgres as $postgres |
        $services.mattermost as $mattermost |
        $services["threadhub-mailer"] as $mailer |
        ($mattermost.environment.MM_PLUGINSETTINGS_ENABLE == "true") and
        ([
          "MM_PLUGINSETTINGS_ENABLEUPLOADS",
          "MM_PLUGINSETTINGS_ENABLEMARKETPLACE",
          "MM_PLUGINSETTINGS_ENABLEREMOTEMARKETPLACE",
          "MM_PLUGINSETTINGS_AUTOMATICPREPACKAGEDPLUGINS",
          "MM_EMAILSETTINGS_SENDEMAILNOTIFICATIONS",
          "MM_EMAILSETTINGS_SENDPUSHNOTIFICATIONS",
          "MM_SERVICESETTINGS_ENABLEINCOMINGWEBHOOKS",
          "MM_SERVICESETTINGS_ENABLEOUTGOINGWEBHOOKS",
          "MM_SERVICESETTINGS_ENABLEBOTACCOUNTCREATION",
          "MM_SERVICESETTINGS_ENABLEUSERACCESSTOKENS"
        ] | all(. as $key | $mattermost.environment[$key] == "false")) and
        (($mailer.ports // []) | length == 0) and
        (.networks.notifier.internal == true) and
        (($postgres.networks | keys) == ["database"]) and
        (($mailer.networks | keys | sort) == ["notifier", "outbound"]) and
        (($mattermost.networks | keys | sort) == ["database", "notifier", "outbound"]) and
        ([$mailer.volumes[] | select(.type == "bind" and .source == "/srv/threadhub/notifier/mailer" and .target == "/var/lib/threadhub-notifier" and ((.read_only // false) == false))] | length == 1) and
        ([$mailer.volumes[] | select(.type == "bind" and .source == "/srv/threadhub/notifier/control" and .target == "/run/threadhub-notifier" and .read_only == true)] | length == 1) and
        ([$mattermost.volumes[] | select(.type == "bind" and .source == "/srv/threadhub/notifier/control" and .target == "/run/threadhub-notifier" and .read_only == true)] | length == 1) and
        ($mattermost.group_add == ["3000"]) and
        ($mailer.group_add == ["3000"]) and
        ([($services | to_entries[]) | select(.key != "mattermost" and .key != "threadhub-mailer") | (.value.group_add // [])[] | select(. == "3000")] | length == 0) and
        ($mailer.user == "65532:65532") and
        ($mailer.read_only == true) and
        ($mailer.cap_drop == ["ALL"]) and
        ($mailer.security_opt == ["no-new-privileges:true"]) and
        ($mailer.platform == "linux/amd64") and
        ($mailer.image == $mailer_image) and
        ($mailer.build.context == $build_context) and
        ($mailer.build.target == "mailer") and
        ($mailer.build.args.GO_BUILDER_IMAGE == $builder) and
        ($mailer.healthcheck.test == ["CMD", "/threadhub-mailer", "healthcheck"]) and
        ($mailer.logging.driver == "json-file") and
        ($mailer.logging.options == {"max-file":"3", "max-size":"10m"}) and
        ($mattermost.environment.THREADHUB_DOMAIN == "threadhub.internal") and
        ($mattermost.environment.NOTIFIER_MAILER_URL == "http://threadhub-mailer:8080") and
        ($mattermost.environment.NOTIFIER_HMAC_SECRET == $hmac) and
        ($mattermost.environment.NOTIFIER_CONTROL_FILE == "/run/threadhub-notifier/state.json") and
        ($mattermost.environment.NOTIFIER_POLL_EVERY == "1s") and
        ($mailer.environment == {
          "NOTIFIER_CONTROL_FILE":"/run/threadhub-notifier/state.json",
          "NOTIFIER_HMAC_SECRET":$hmac,
          "NOTIFIER_LISTEN_ADDRESS":":8080",
          "NOTIFIER_QUEUE_PATH":"/var/lib/threadhub-notifier/queue.db",
          "NOTIFIER_RATE_PER_MINUTE":"10",
          "SMTP_FEEDBACK_NAME":"ThreadHub",
          "SMTP_FROM_ADDRESS":"no-reply@threadhub.internal",
          "SMTP_PASSWORD":"fixture_password",
          "SMTP_PORT":"587",
          "SMTP_REPLY_TO_ADDRESS":"admin@threadhub.internal",
          "SMTP_SERVER":"smtp.email.ap-singapore-1.oci.oraclecloud.com",
          "SMTP_USERNAME":"fixture_user",
          "THREADHUB_DOMAIN":"threadhub.internal"
        })
    ' "${validation_tmp_dir}/compose.json" >/dev/null \
        || die "Canonical Docker Compose model violates notifier security invariants"
    log "Docker Compose canonical JSON satisfies notifier security invariants"
elif command -v ruby >/dev/null 2>&1; then
    ruby - "${COMPOSE_FILE}" <<'RUBY'
require "yaml"

def assert(condition, message)
  abort("[threadhub] ERROR: #{message}") unless condition
end

compose = YAML.safe_load(File.read(ARGV.fetch(0)), permitted_classes: [], aliases: false)
services = compose.fetch("services")
postgres = services.fetch("postgres")
mattermost = services.fetch("mattermost")
mailer = services.fetch("threadhub-mailer")
mm_env = mattermost.fetch("environment")
mailer_env = mailer.fetch("environment")

assert(mm_env["MM_PLUGINSETTINGS_ENABLE"] == "true", "Mattermost plugin execution must be enabled")
%w[
  MM_PLUGINSETTINGS_ENABLEUPLOADS
  MM_PLUGINSETTINGS_ENABLEMARKETPLACE
  MM_PLUGINSETTINGS_ENABLEREMOTEMARKETPLACE
  MM_PLUGINSETTINGS_AUTOMATICPREPACKAGEDPLUGINS
  MM_EMAILSETTINGS_SENDEMAILNOTIFICATIONS
  MM_EMAILSETTINGS_SENDPUSHNOTIFICATIONS
  MM_SERVICESETTINGS_ENABLEINCOMINGWEBHOOKS
  MM_SERVICESETTINGS_ENABLEOUTGOINGWEBHOOKS
  MM_SERVICESETTINGS_ENABLEBOTACCOUNTCREATION
  MM_SERVICESETTINGS_ENABLEUSERACCESSTOKENS
].each do |key|
  assert(mm_env[key] == "false", "#{key} must remain disabled")
end

assert(!mailer.key?("ports"), "Mailer must not publish a host port")
assert(compose.dig("networks", "notifier", "internal") == true, "notifier network must be internal")
assert(postgres.fetch("networks") == ["database"], "PostgreSQL must use only the database network")
assert(mailer.fetch("networks").sort == %w[notifier outbound], "Mailer networks must be notifier and outbound")
assert(mattermost.fetch("networks").sort == %w[database notifier outbound], "Mattermost networks must be database, notifier and outbound")

control_mount = "${THREADHUB_DATA_ROOT}/notifier/control:/run/threadhub-notifier:ro"
queue_mount = "${THREADHUB_DATA_ROOT}/notifier/mailer:/var/lib/threadhub-notifier:rw"
assert(mailer.fetch("volumes").include?(queue_mount), "Mailer queue bind mount is missing")
assert(mailer.fetch("volumes").include?(control_mount), "Mailer read-only control mount is missing")
assert(mattermost.fetch("volumes").include?(control_mount), "Mattermost read-only control mount is missing")

%w[mattermost threadhub-mailer].each do |name|
  assert(services.fetch(name).fetch("group_add") == ["3000"], "#{name} must have only supplemental GID 3000")
end
(services.keys - %w[mattermost threadhub-mailer]).each do |name|
  assert(!Array(services.fetch(name)["group_add"]).include?("3000"), "#{name} must not receive notifier control GID")
end

assert(mailer["user"] == "65532:65532", "Mailer must use numeric non-root UID/GID")
assert(mailer["platform"] == "linux/amd64", "Mailer platform must be linux/amd64")
assert(mailer["image"] == "threadhub/notifier-mailer:${NOTIFIER_VERSION:?load deploy/versions.env}", "Mailer image reference must use the fixed notifier version")
assert(mailer.dig("build", "context") == "../notifier", "Mailer build context is invalid")
assert(mailer.dig("build", "target") == "mailer", "Mailer build target is invalid")
assert(mailer.dig("build", "args", "GO_BUILDER_IMAGE") == "${GO_BUILDER_IMAGE_REPOSITORY:?load deploy/versions.env}:${GO_BUILDER_IMAGE_TAG:?load deploy/versions.env}@${GO_BUILDER_IMAGE_DIGEST:?load deploy/versions.env}", "Mailer builder must use the pinned digest")
assert(mailer["read_only"] == true, "Mailer root filesystem must be read-only")
assert(mailer.fetch("cap_drop") == ["ALL"], "Mailer must drop every Linux capability")
assert(mailer.fetch("security_opt") == ["no-new-privileges:true"], "Mailer must set no-new-privileges")
assert(mailer.dig("healthcheck", "test") == ["CMD", "/threadhub-mailer", "healthcheck"], "Mailer healthcheck is invalid")
assert(mailer.dig("logging", "driver") == "json-file", "Mailer logging driver is invalid")
assert(mailer.dig("logging", "options") == {"max-size" => "10m", "max-file" => "3"}, "Mailer log rotation is invalid")

assert(mm_env["THREADHUB_DOMAIN"] == "${THREADHUB_DOMAIN:?set THREADHUB_DOMAIN in deploy/.env}", "Plugin must receive THREADHUB_DOMAIN")
assert(mm_env["NOTIFIER_MAILER_URL"] == "http://threadhub-mailer:8080", "Plugin Mailer URL must be fixed")
assert(mm_env["NOTIFIER_HMAC_SECRET"] == "${NOTIFIER_HMAC_SECRET:?set NOTIFIER_HMAC_SECRET in deploy/.env}", "Plugin HMAC must fail closed when absent")
assert(mm_env["NOTIFIER_CONTROL_FILE"] == "/run/threadhub-notifier/state.json", "Plugin control path must be fixed")
assert(mm_env["NOTIFIER_POLL_EVERY"] == "1s", "Plugin control poll interval must be fixed")

expected_mailer_env = {
  "NOTIFIER_LISTEN_ADDRESS" => ":8080",
  "THREADHUB_DOMAIN" => "${THREADHUB_DOMAIN:?set THREADHUB_DOMAIN in deploy/.env}",
  "NOTIFIER_HMAC_SECRET" => "${NOTIFIER_HMAC_SECRET:?set NOTIFIER_HMAC_SECRET in deploy/.env}",
  "NOTIFIER_CONTROL_FILE" => "/run/threadhub-notifier/state.json",
  "NOTIFIER_QUEUE_PATH" => "/var/lib/threadhub-notifier/queue.db",
  "NOTIFIER_RATE_PER_MINUTE" => "${NOTIFIER_RATE_PER_MINUTE:-10}",
  "SMTP_SERVER" => "${SMTP_SERVER:?set SMTP_SERVER in deploy/.env}",
  "SMTP_PORT" => "${SMTP_PORT:-587}",
  "SMTP_USERNAME" => "${SMTP_USERNAME:?set SMTP_USERNAME in deploy/.env}",
  "SMTP_PASSWORD" => "${SMTP_PASSWORD:?set SMTP_PASSWORD in deploy/.env}",
  "SMTP_FROM_ADDRESS" => "${SMTP_FROM_ADDRESS:?set SMTP_FROM_ADDRESS in deploy/.env}",
  "SMTP_REPLY_TO_ADDRESS" => "${SMTP_REPLY_TO_ADDRESS:?set SMTP_REPLY_TO_ADDRESS in deploy/.env}",
  "SMTP_FEEDBACK_NAME" => "${SMTP_FEEDBACK_NAME:-ThreadHub}",
}
assert(mailer_env == expected_mailer_env, "Mailer environment must contain only the required runtime values")
RUBY
else
    die "Docker Compose or Ruby is required for exact notifier Compose-model validation; CI must provide Docker Compose"
fi
log "Notifier Compose isolation, mounts, settings and hardening are valid"

for script in \
    "${SCRIPT_DIR}/build-notifier.sh" \
    "${SCRIPT_DIR}/verify-notifier-artifacts.sh" \
    "${SCRIPT_DIR}/install-notifier-plugin.sh" \
    "${SCRIPT_DIR}/configure-notifier.sh" \
    "${SCRIPT_DIR}/notifier-control.sh" \
    "${SCRIPT_DIR}/notifier-smtp-test.sh" \
    "${SCRIPT_DIR}/notifier-status.sh"; do
    require_file "${script}"
    [[ -x "${script}" ]] || die "Notifier deployment script must be executable: ${script}"
done
require_file "${SCRIPT_DIR}/notifier-plugin-transaction.sh"
require_file "${SCRIPT_DIR}/notifier-plugin-files.sh"
require_file "${DEPLOY_DIR}/tests/notifier-artifact-security-test.sh"
[[ -x "${DEPLOY_DIR}/tests/notifier-artifact-security-test.sh" ]] \
    || die "Notifier artifact security fixture test must be executable"
# Match the literal build-script expression; expansion is not intended.
# shellcheck disable=SC2016
grep -F -- '--build-arg "GO_BUILDER_IMAGE=${builder_image}"' \
    "${SCRIPT_DIR}/build-notifier.sh" >/dev/null \
    || die "Notifier builds must consume the pinned builder digest"
grep -F 'NOTIFIER_PLUGIN_BUNDLE_SHA256=' "${SCRIPT_DIR}/build-notifier.sh" >/dev/null \
    || die "Notifier release identity must record the bundle SHA-256"
grep -F 'NOTIFIER_SOURCE_COMMIT=' "${SCRIPT_DIR}/build-notifier.sh" >/dev/null \
    || die "Notifier release identity must record the clean source commit"
# Match a forbidden literal source expression; expansion is not intended.
# shellcheck disable=SC2016
if grep -F 'source "${release_file}"' "${SCRIPT_DIR}/install-notifier-plugin.sh" >/dev/null; then
    die "Notifier release identity must never be sourced as shell code"
fi
for archive_option in --no-same-owner --no-same-permissions; do
    grep -F -- "${archive_option}" "${SCRIPT_DIR}/install-notifier-plugin.sh" >/dev/null \
        || die "Notifier plugin extraction is missing ${archive_option}"
done
grep -F 'mmctl plugin list --local --suppress-warnings --json' \
    "${SCRIPT_DIR}/install-notifier-plugin.sh" >/dev/null \
    || die "Notifier plugin activation must use stable JSON mmctl output"
# The single-quoted values are literal installer expressions, not shell code.
# shellcheck disable=SC2016
for paired_install_contract in \
    'notifier_plugin_stage_pair' \
    'bundle_target="${filestore_plugins_root}/${plugin_id}.tar.gz"' \
    'notifier_plugin_transaction'; do
    grep -F "${paired_install_contract}" \
        "${SCRIPT_DIR}/install-notifier-plugin.sh" >/dev/null \
        || die "Notifier plugin installation must publish the reviewed runtime and filestore pair"
done
grep -F 'compose pull postgres mattermost' "${SCRIPT_DIR}/deploy.sh" >/dev/null \
    || die "Deployment must pull only immutable external services"
if grep -Fx 'compose pull' "${SCRIPT_DIR}/deploy.sh" >/dev/null; then
    die "Deployment must not pull the locally built Mailer image"
fi
if grep -E 'compose down([^[:alnum:]]|$).*(-v|--volumes)' "${SCRIPT_DIR}/destroy.sh" >/dev/null; then
    die "Destroy must never delete ThreadHub volumes"
fi

if command -v ruby >/dev/null 2>&1; then
    ruby -rjson - "${REPOSITORY_ROOT}/notifier/plugin/plugin.json" <<'RUBY'
manifest = JSON.parse(File.read(ARGV.fetch(0)))
abort("[threadhub] ERROR: notifier manifest ID is invalid") unless manifest["id"] == "com.threadhub.channel-email-notifier"
abort("[threadhub] ERROR: notifier manifest version is invalid") unless manifest["version"] == "0.1.0"
abort("[threadhub] ERROR: notifier manifest server executable is invalid") unless manifest.dig("server", "executables") == {"linux-amd64" => "server/dist/plugin-linux-amd64"}
RUBY
else
    grep -F '"id": "com.threadhub.channel-email-notifier"' \
        "${REPOSITORY_ROOT}/notifier/plugin/plugin.json" >/dev/null \
        || die "Notifier manifest ID is invalid"
    grep -F '"version": "0.1.0"' \
        "${REPOSITORY_ROOT}/notifier/plugin/plugin.json" >/dev/null \
        || die "Notifier manifest version is invalid"
    grep -F '"linux-amd64": "server/dist/plugin-linux-amd64"' \
        "${REPOSITORY_ROOT}/notifier/plugin/plugin.json" >/dev/null \
        || die "Notifier manifest server executable is invalid"
fi
log "Notifier build, release and manual plugin installation invariants are valid"

require_file "${SCRIPT_DIR}/notifier-lib.sh"
require_file "${DEPLOY_DIR}/tests/notifier-installer-test.sh"
require_file "${DEPLOY_DIR}/tests/notifier-installer-security-test.sh"
require_file "${DEPLOY_DIR}/tests/notifier-documentation-test.sh"
[[ -x "${DEPLOY_DIR}/tests/notifier-installer-test.sh" ]] \
    || die "Notifier installer behavioral test must be executable"
[[ -x "${DEPLOY_DIR}/tests/notifier-installer-security-test.sh" ]] \
    || die "Notifier installer security regression test must be executable"
[[ -x "${DEPLOY_DIR}/tests/notifier-documentation-test.sh" ]] \
    || die "Notifier documentation contract test must be executable"
"${DEPLOY_DIR}/tests/notifier-installer-test.sh"
"${DEPLOY_DIR}/tests/notifier-installer-security-test.sh"
"${DEPLOY_DIR}/tests/notifier-documentation-test.sh"
log "Notifier installer configuration, state and SMTP acceptance behaviors are valid"

require_command mv
require_command ln
if [[ "$(uname -s)" == Linux ]]; then
    mv --help 2>&1 | grep -F -- '--no-target-directory' >/dev/null \
        || die "Target mv must support GNU --no-target-directory for atomic env publication"
    mv --help 2>&1 | grep -F -- '--no-clobber' >/dev/null \
        || die "Target mv must support GNU --no-clobber for atomic env publication"
    ln --help 2>&1 | grep -F -- '--no-target-directory' >/dev/null \
        || die "Target ln must support GNU --no-target-directory for exact env publication"
    publication_fixture="${validation_tmp_dir}/env-publication"
    mkdir -m 0700 "${publication_fixture}"
    printf '%s\n' 'replacement' > "${publication_fixture}/source"
    printf '%s\n' 'concurrent-target' > "${publication_fixture}/destination"
    set +e
    mv -T -n \
        "${publication_fixture}/source" "${publication_fixture}/destination" \
        >/dev/null 2>&1
    set -e
    [[ "$(<"${publication_fixture}/source")" == replacement ]] \
        || die "GNU mv -T -n must preserve its source when the target exists"
    [[ "$(<"${publication_fixture}/destination")" == concurrent-target ]] \
        || die "GNU mv -T -n overwrote a concurrent target"
    rm -f "${publication_fixture}/destination"
    mv -T -n \
        "${publication_fixture}/source" "${publication_fixture}/destination"
    [[ ! -e "${publication_fixture}/source" ]] \
        || die "GNU mv -T -n did not move into an absent target"
    [[ "$(<"${publication_fixture}/destination")" == replacement ]] \
        || die "GNU mv -T -n published unexpected content"
    mkdir "${publication_fixture}/directory-target"
    set +e
    ln -T -- \
        "${publication_fixture}/destination" "${publication_fixture}/directory-target" \
        >/dev/null 2>&1
    directory_link_result=$?
    set -e
    ((directory_link_result != 0)) \
        || die "GNU ln -T must reject a directory target"
    [[ -z "$(find "${publication_fixture}/directory-target" -mindepth 1 -print -quit)" ]] \
        || die "GNU ln -T created a nested link under a directory target"
    ln -s "${publication_fixture}/directory-target" \
        "${publication_fixture}/symlink-directory-target"
    set +e
    ln -T -- \
        "${publication_fixture}/destination" \
        "${publication_fixture}/symlink-directory-target" >/dev/null 2>&1
    symlink_directory_link_result=$?
    set -e
    ((symlink_directory_link_result != 0)) \
        || die "GNU ln -T must reject a symlink-to-directory target"
    [[ -z "$(find "${publication_fixture}/directory-target" -mindepth 1 -print -quit)" ]] \
        || die "GNU ln -T created a nested link through a directory symlink"
    [[ -L "${publication_fixture}/symlink-directory-target" ]] \
        || die "GNU ln -T replaced a symlink-to-directory target"
    [[ "$(<"${publication_fixture}/destination")" == replacement ]] \
        || die "GNU ln -T changed its source while rejecting a directory target"
    ln -T -- "${publication_fixture}/destination" "${publication_fixture}/linked"
    [[ "$(stat -c '%d:%i' "${publication_fixture}/destination")" \
        == "$(stat -c '%d:%i' "${publication_fixture}/linked")" ]] \
        || die "Target ln must create a same-filesystem hard link"
fi
log "Target env publication tools provide no-clobber move and hard-link primitives"
grep -F 'GNU Coreutils' "${DEPLOY_DIR}/docs/quick-install.md" >/dev/null \
    || die "Quick-install guide must document atomic env publication prerequisites"

if grep -F '[READY]' "${SCRIPT_DIR}/setup-wizard.sh" >/dev/null; then
    die "The setup wizard must delegate the final READY verdict to install-status.sh"
fi
# Match the literal setup-wizard expression; expansion is not intended.
# shellcheck disable=SC2016
grep -F '"${SCRIPT_DIR}/install-status.sh"' "${SCRIPT_DIR}/setup-wizard.sh" >/dev/null \
    || die "The setup wizard must finish through install-status.sh"

if grep -R -n -E 'image:[[:space:]]+[^#]*:latest([[:space:]]|$)' "${DEPLOY_DIR}"; then
    die "Floating latest image tag found"
fi

original_env_file="${ENV_FILE}"
ENV_FILE="${runtime_env_fixture}"
validate_runtime_env
ENV_FILE="${original_env_file}"
log "Runtime environment validation accepts a complete non-placeholder configuration"

# Match the literal deployment-script expression; expansion is not intended.
# shellcheck disable=SC2016
grep -F 'install -d -m 0755 "${data_root}/postgres"' \
    "${SCRIPT_DIR}/deploy.sh" >/dev/null \
    || die "PostgreSQL bind-mount root permission regression detected"
log "PostgreSQL bind-mount root remains traversable after the entrypoint drops privileges"

grep -F 'ensure_tcp_input_rule 80' "${SCRIPT_DIR}/configure-nginx.sh" >/dev/null \
    || die "Host HTTP firewall rule regression detected"
grep -F 'ensure_tcp_input_rule 443' "${SCRIPT_DIR}/configure-nginx.sh" >/dev/null \
    || die "Host HTTPS firewall rule regression detected"
grep -F 'netfilter-persistent save' "${SCRIPT_DIR}/configure-nginx.sh" >/dev/null \
    || die "Persistent host firewall save regression detected"
log "Host HTTP and HTTPS firewall rules remain persistent"

for directive in \
    'PasswordAuthentication no' \
    'PubkeyAuthentication yes' \
    'PermitRootLogin no'; do
    grep -Fx "${directive}" "${ssh_hardening_file}" >/dev/null \
        || die "SSH hardening directive is missing: ${directive}"
done
log "SSH password and root login hardening directives are present"

grep -F 'MM_TEAMSETTINGS_EXPERIMENTALDEFAULTCHANNELS: "01-project-general 02-progress-issues 03-decisions"' \
    "${COMPOSE_FILE}" >/dev/null \
    || die "Default project channel membership configuration is missing"
require_file "${SCRIPT_DIR}/reconcile-team-channels.sh"
require_file "${SCRIPT_DIR}/reload-nginx.sh"
require_file "${SCRIPT_DIR}/certbot-deploy-hook.sh"
require_file "${SCRIPT_DIR}/setup-wizard.sh"
require_file "${SCRIPT_DIR}/install-status.sh"
log "Default project channels and membership reconciliation are configured"

for guide in \
    "${DEPLOY_DIR}/docs/quick-install.md" \
    "${DEPLOY_DIR}/docs/oci-provisioning.md" \
    "${DEPLOY_DIR}/docs/oci-email-delivery.md"; do
    require_file "${guide}"
done
"${SCRIPT_DIR}/setup-wizard.sh" --help >/dev/null
"${SCRIPT_DIR}/install-status.sh" --help >/dev/null
grep -F './deploy/scripts/setup-wizard.sh' "${REPOSITORY_ROOT}/README.md" >/dev/null \
    || die "Top-level README must expose the guided installation entry point"
# Match the literal documentation text; command substitution is not intended.
# shellcheck disable=SC2016
grep -F 'exit code `20`' "${DEPLOY_DIR}/docs/quick-install.md" >/dev/null \
    || die "Quick-install guide must document action-required exit behavior"
log "Guided installation entry point and OCI setup guides are present"

# The notifier’s operational and isolation guarantees are intentionally
# documented in the public runbooks. Keep these assertions tolerant of normal
# Markdown wrapping while preventing the safety-critical contracts from
# silently disappearing.
validate_notifier_documentation_contracts "${REPOSITORY_ROOT}" \
    || die "Notifier documentation contracts are invalid"

log "Notifier documentation links, operational safety and OCI isolation contracts are present"

for script in \
    "${SCRIPT_DIR}/configure-nginx.sh" \
    "${SCRIPT_DIR}/reload-nginx.sh"; do
    grep -F 'secure_nginx_logs' "${script}" >/dev/null \
        || die "NGINX setup must protect access and error log permissions: ${script}"
done

# Match the literal deployment-script expression; expansion is not intended.
# shellcheck disable=SC2016
grep -F 'install -m 0755 "${renewal_hook}" "${renewal_hook_target}"' \
    "${SCRIPT_DIR}/configure-nginx.sh" >/dev/null \
    || die "Certbot deploy hook installation is missing"
grep -F 'systemctl enable --now certbot.timer' \
    "${SCRIPT_DIR}/configure-nginx.sh" >/dev/null \
    || die "Certbot renewal timer activation is missing"
grep -F -- '--run-deploy-hooks' \
    "${SCRIPT_DIR}/configure-nginx.sh" >/dev/null \
    || die "Certbot deploy hook dry-run execution is missing"
grep -F -- '--no-random-sleep-on-renew' \
    "${SCRIPT_DIR}/configure-nginx.sh" >/dev/null \
    || die "Certbot deploy hook immediate dry-run validation is missing"
grep -F '/usr/sbin/nginx -t' "${SCRIPT_DIR}/certbot-deploy-hook.sh" >/dev/null \
    || die "Certbot deploy hook must validate NGINX before reload"
grep -F '/usr/bin/systemctl reload nginx' \
    "${SCRIPT_DIR}/certbot-deploy-hook.sh" >/dev/null \
    || die "Certbot deploy hook must reload NGINX after renewal"
grep -F '/etc/letsencrypt/renewal-hooks/deploy/threadhub-reload-nginx' \
    "${SCRIPT_DIR}/install-status.sh" >/dev/null \
    || die "Install status must verify the Certbot deploy hook"
log "Certbot renewal installs and validates the NGINX deploy hook"

# Match literal deployment-script expressions; expansion is not intended.
# shellcheck disable=SC2016
grep -F 'chmod 0640 "${log_file}"' "${SCRIPT_DIR}/common.sh" >/dev/null \
    || die "ThreadHub NGINX logs must not be world-readable"
# shellcheck disable=SC2016
grep -F 'test ! -L "${log_file}"' "${SCRIPT_DIR}/common.sh" >/dev/null \
    || die "NGINX log permission management must reject symbolic links"
log "NGINX log files are protected from world-readable and symbolic-link regressions"

for template in \
    "${DEPLOY_DIR}/nginx/threadhub-bootstrap.conf.template" \
    "${DEPLOY_DIR}/nginx/threadhub.conf.template"; do
    require_file "${template}"
    [[ "$(grep -c '__THREADHUB_DOMAIN__' "${template}")" -gt 0 ]] \
        || die "NGINX template is missing the domain placeholder: ${template}"
    grep -F 'access_log /var/log/nginx/threadhub.access.log threadhub_safe;' \
        "${template}" >/dev/null \
        || die "NGINX template must use the query-free ThreadHub access log format: ${template}"
done

grep -F "\"\$request_method \$uri \$server_protocol\"" \
    "${DEPLOY_DIR}/nginx/threadhub.conf.template" >/dev/null \
    || die "NGINX safe access log format is missing"
for unsafe_host in "\$http_host" "\$host"; do
    if grep -R -n -F "proxy_set_header Host ${unsafe_host}" "${DEPLOY_DIR}/nginx"; then
        die "NGINX must not forward an untrusted request Host header"
    fi
done

grep -F 'config --quiet' "${DEPLOY_DIR}/README.md" >/dev/null \
    || die "Compose documentation must not print interpolated runtime secrets"
grep -F 'chmod 600 deploy/.env' "${DEPLOY_DIR}/README.md" >/dev/null \
    || die "Quick-start documentation must protect deploy/.env before editing"
grep -F "chmod 0600 \"\${ENV_FILE}\"" "${SCRIPT_DIR}/deploy.sh" >/dev/null \
    || die "Deployment must protect the runtime environment before reading secrets"
grep -F "Usage: \$0 TEAM_URL_NAME [CHANNEL_URL_NAME ...]" \
    "${SCRIPT_DIR}/reconcile-team-channels.sh" >/dev/null \
    || die "Channel reconciliation must require an explicit Team target"

if command -v git >/dev/null 2>&1 && git -C "${REPOSITORY_ROOT}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    secret_pattern='AKIA[0-9A-Z]{16}|ASIA[0-9A-Z]{16}|gh[opusr]_[A-Za-z0-9_]{20,}|github_pat_[A-Za-z0-9_]{20,}|xox[baprs]-[A-Za-z0-9-]{10,}|sk-[A-Za-z0-9]{20,}|ocid1\.|BEGIN ([A-Z]+ )*PRIVATE KEY'
    secret_files="$(git -C "${REPOSITORY_ROOT}" grep -Il -E "${secret_pattern}" -- . || true)"
    if [[ -n "${secret_files}" ]]; then
        printf '%s\n' "${secret_files}" >&2
        die "Potential credential material found in tracked files"
    fi

    credential_files="$(git -C "${REPOSITORY_ROOT}" grep -Il -E \
        '^[[:space:]]*(POSTGRES_PASSWORD|SMTP_PASSWORD|SMTP_USERNAME|AWS_SECRET_ACCESS_KEY|GITHUB_TOKEN)=' \
        -- . ':!deploy/.env.example' || true)"
    if [[ -n "${credential_files}" ]]; then
        printf '%s\n' "${credential_files}" >&2
        die "A runtime credential assignment was found outside deploy/.env.example"
    fi

    sensitive_names="$(git -C "${REPOSITORY_ROOT}" ls-files \
        | grep -E '(^|/)(\.env($|\.)|id_(rsa|ed25519)$|.*\.(key|pem|p12|pfx|ppk|jks|keystore|tfstate|tfplan)$)' \
        | grep -v -E '(^|/)\.env\.example$' || true)"
    if [[ -n "${sensitive_names}" ]]; then
        printf '%s\n' "${sensitive_names}" >&2
        die "Sensitive filename is tracked"
    fi

    history_secret_files="$(
        git -C "${REPOSITORY_ROOT}" rev-list --all \
            | while IFS= read -r revision; do
                git -C "${REPOSITORY_ROOT}" grep -Il -E \
                    "${secret_pattern}" "${revision}" -- . || true
            done \
            | sort -u
    )"
    if [[ -n "${history_secret_files}" ]]; then
        printf '%s\n' "${history_secret_files}" >&2
        die "Potential credential material found in reachable Git history"
    fi
fi

log "ThreadHub deployment package static validation passed"
