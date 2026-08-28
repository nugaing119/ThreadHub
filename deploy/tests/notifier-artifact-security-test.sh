#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPOSITORY_ROOT="$(cd "${DEPLOY_DIR}/.." && pwd)"
VERIFY_SCRIPT="${DEPLOY_DIR}/scripts/verify-notifier-artifacts.sh"
GITLEAKS_BIN="${GITLEAKS_BIN:?set GITLEAKS_BIN to the verified Gitleaks 8.30.1 binary}"

temporary_dir="$(mktemp -d)"
cleanup() {
    rm -rf "${temporary_dir}"
}
trap cleanup EXIT HUP INT TERM

fail() {
    printf 'not ok - %s\n' "$*" >&2
    exit 1
}

fixture_sha256() {
    local path="$1"

    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "${path}" | awk '{print $1}'
    else
        shasum -a 256 "${path}" | awk '{print $1}'
    fi
}

assert_safe_failure() {
    local expected_class="$1"
    shift
    local output_file="${temporary_dir}/failure-output"

    if "$@" >"${output_file}" 2>&1; then
        fail "expected ${expected_class} rejection"
    fi
    grep -Fx "not ok - notifier artifact secret gate: ${expected_class}" \
        "${output_file}" >/dev/null \
        || fail "${expected_class} rejection did not use the fixed safe diagnostic"
    if grep -Fq "${planted_secret}" "${output_file}"; then
        fail "${expected_class} rejection disclosed planted fixture material"
    fi
    if [[ -n "${history_planted_value:-}" ]] \
        && grep -Fq "${history_planted_value}" "${output_file}"; then
        fail "${expected_class} rejection disclosed planted history material"
    fi
}

make_bundle() {
    local content="$1"
    local bundle_root="${temporary_dir}/bundle-root"

    rm -rf "${bundle_root}"
    mkdir -p "${bundle_root}/com.threadhub.channel-email-notifier/server/dist"
    printf '%s\n' '{"id":"com.threadhub.channel-email-notifier"}' \
        >"${bundle_root}/com.threadhub.channel-email-notifier/plugin.json"
    printf '%s\n' "${content}" \
        >"${bundle_root}/com.threadhub.channel-email-notifier/server/dist/plugin-linux-amd64"
    tar -czf "${temporary_dir}/bundle.tar.gz" -C "${bundle_root}" \
        com.threadhub.channel-email-notifier
}

make_image() {
    local content="$1"
    local env_json="${2:-[]}"
    local history_json="${3:-[]}"
    local document=""

    document="$(jq -cn --argjson env "${env_json}" --argjson history "${history_json}" \
        '{architecture:"amd64",os:"linux",config:{Env:$env},history:$history}')"
    make_image_document "${content}" "${document}" "${env_json}"
}

make_image_document() {
    local content="$1"
    local document="$2"
    local engine_env_json="${3:-[]}"
    local image_root="${temporary_dir}/image-root"
    local layer_root="${temporary_dir}/layer-root"
    local config_digest=""
    local config_name=""

    rm -rf "${image_root}" "${layer_root}"
    mkdir -p "${image_root}" "${layer_root}/app"
    printf '%s\n' "${content}" >"${layer_root}/app/threadhub-mailer"
    tar -cf "${image_root}/layer.tar" -C "${layer_root}" app
    printf '%s\n' "${document}" >"${image_root}/config-pending.json"
    config_digest="$(fixture_sha256 "${image_root}/config-pending.json")"
    config_name="${config_digest}.json"
    mv "${image_root}/config-pending.json" "${image_root}/${config_name}"
    jq -cn --arg config "${config_name}" \
        '[{Config:$config,RepoTags:["threadhub/notifier-mailer:0.1.0"],Layers:["layer.tar"]}]' \
        >"${image_root}/manifest.json"
    tar -cf "${temporary_dir}/image.tar" -C "${image_root}" \
        manifest.json "${config_name}" layer.tar
    FIXTURE_IMAGE_ID="sha256:${config_digest}"
    FIXTURE_EXPECTED_OPERATION_ID="${FIXTURE_IMAGE_ID}"
    printf '%s\n' "${engine_env_json}" >"${temporary_dir}/env.json"
}

mkdir -p "${temporary_dir}/bin"
cat >"${temporary_dir}/bin/docker" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
case "$1 $2 $3" in
    'image inspect --format')
        case "$4" in
            '{{.Id}}')
                [[ "$5" == 'threadhub/notifier-mailer:0.1.0' ]] || exit 65
                printf '%s\n' "${FIXTURE_IMAGE_ID}"
                ;;
            '{{.Os}}/{{.Architecture}}'|'{{json .Config.Env}}')
                if [[ "${FIXTURE_REQUIRE_IMMUTABLE_REF:-false}" == true ]]; then
                    [[ "$5" == "${FIXTURE_EXPECTED_OPERATION_ID}" ]] || exit 65
                fi
                if [[ "$4" == '{{.Os}}/{{.Architecture}}' ]]; then
                    printf '%s\n' "${FIXTURE_PLATFORM:-linux/amd64}"
                else
                    cat "${FIXTURE_ENV_JSON}"
                fi
                ;;
            *) exit 64 ;;
        esac
        ;;
    'image save --output')
        if [[ "${FIXTURE_REQUIRE_IMMUTABLE_REF:-false}" == true ]]; then
            [[ "$5" == "${FIXTURE_EXPECTED_OPERATION_ID}" ]] || exit 65
        fi
        cp "${FIXTURE_IMAGE_ARCHIVE}" "$4"
        ;;
    'history --no-trunc --format')
        if [[ "${FIXTURE_REQUIRE_IMMUTABLE_REF:-false}" == true ]]; then
            [[ "$5" == "${FIXTURE_EXPECTED_OPERATION_ID}" ]] || exit 65
        fi
        cat "${FIXTURE_HISTORY}"
        ;;
    *) exit 64 ;;
esac
EOF
chmod 0755 "${temporary_dir}/bin/docker"
printf '%s\n' '[]' >"${temporary_dir}/env.json"
: >"${temporary_dir}/history"

planted_secret="github_$(printf '%s' 'pat_')$(openssl rand -hex 41)"
history_planted_value='round4-private-history-marker'
make_bundle 'safe plugin fixture'
make_image 'safe mailer fixture'

run_gate() {
    PATH="${temporary_dir}/bin:${PATH}" \
        GITLEAKS_BIN="${GITLEAKS_BIN}" \
        FIXTURE_IMAGE_ARCHIVE="${temporary_dir}/image.tar" \
        FIXTURE_IMAGE_ID="${FIXTURE_IMAGE_ID}" \
        FIXTURE_EXPECTED_OPERATION_ID="${FIXTURE_EXPECTED_OPERATION_ID}" \
        FIXTURE_REQUIRE_IMMUTABLE_REF="${FIXTURE_REQUIRE_IMMUTABLE_REF:-false}" \
        FIXTURE_ENV_JSON="${temporary_dir}/env.json" \
        FIXTURE_HISTORY="${temporary_dir}/history" \
        CONTAINER_COMMAND=docker \
        "${VERIFY_SCRIPT}" \
        "${temporary_dir}/bundle.tar.gz" \
        threadhub/notifier-mailer:0.1.0
}

(
    GITLEAKS_BIN="${temporary_dir}/missing"
    assert_safe_failure scanner run_gate
)
cat >"${temporary_dir}/wrong-scanner" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' '0.0.0'
EOF
chmod 0755 "${temporary_dir}/wrong-scanner"
(
    GITLEAKS_BIN="${temporary_dir}/wrong-scanner"
    assert_safe_failure scanner run_gate
)

if ! run_gate >"${temporary_dir}/clean-output" 2>&1; then
    clean_class="$(sed -n 's/^not ok - notifier artifact secret gate: //p' \
        "${temporary_dir}/clean-output")"
    case "${clean_class}" in
        scanner|bundle|bundle-archive|bundle-content|image|image-platform|image-metadata|image-archive|image-content) ;;
        *) clean_class=unknown ;;
    esac
    fail "clean bundle and Mailer image fixture was rejected (${clean_class})"
fi
grep -Fx 'ok - notifier artifact secret gate: bundle and image passed' \
    "${temporary_dir}/clean-output" >/dev/null \
    || fail 'clean scan did not emit the fixed success diagnostic'

FIXTURE_REQUIRE_IMMUTABLE_REF=true
run_gate >"${temporary_dir}/immutable-output" 2>&1 \
    || fail 'scanner did not bind every image operation to the one resolved immutable ID'
FIXTURE_REQUIRE_IMMUTABLE_REF=false

original_image_id="${FIXTURE_IMAGE_ID}"
FIXTURE_EXPECTED_OPERATION_ID="sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
FIXTURE_REQUIRE_IMMUTABLE_REF=true
assert_safe_failure image run_gate
FIXTURE_REQUIRE_IMMUTABLE_REF=false
FIXTURE_IMAGE_ID="${original_image_id}"
FIXTURE_EXPECTED_OPERATION_ID="${original_image_id}"

FIXTURE_IMAGE_ID='sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc'
FIXTURE_EXPECTED_OPERATION_ID="${FIXTURE_IMAGE_ID}"
assert_safe_failure image-archive run_gate
make_image 'safe mailer fixture'

make_bundle "${planted_secret}"
assert_safe_failure bundle-content run_gate
make_bundle 'safe plugin fixture'

make_image "${planted_secret}"
assert_safe_failure image-content run_gate
make_image 'safe mailer fixture'

planted_env="$(jq -cn --arg value "${planted_secret}" '["APP_TOKEN=" + $value]')"
make_image 'safe mailer fixture' "${planted_env}"
assert_safe_failure image-content run_gate
make_image 'safe mailer fixture'

printf '["SMTP_PASSWORD=%s"]\n' "${planted_secret}" >"${temporary_dir}/env.json"
assert_safe_failure image-metadata run_gate
printf '%s\n' '[]' >"${temporary_dir}/env.json"

printf '%s\n' "RUN SMTP_PASSWORD=${planted_secret}" >"${temporary_dir}/history"
assert_safe_failure image-content run_gate
: >"${temporary_dir}/history"

make_image 'safe mailer fixture' '[]' '[{"created_by":"ENV SMTP_PASSWORD=x"}]'
assert_safe_failure image-metadata run_gate
make_image 'safe mailer fixture' '[]' '[{"created_by":"ENV SMTP_PASSWORD=   x"}]'
assert_safe_failure image-metadata run_gate
make_image 'safe mailer fixture' '[]' '[{"created_by":"ENV SMTP_PASSWORD=   "}]'
assert_safe_failure image-metadata run_gate
make_image 'safe mailer fixture' '[]' \
    '[{"created_by":"ENV SMTP_PASSWORD=x"},{"created_by":"ENV SMTP_PASSWORD="}]'
assert_safe_failure image-metadata run_gate
make_image 'safe mailer fixture' '[]' \
    '[{"created_by":"ENV SMTP_PASSWORD=x; ENV SMTP_PASSWORD="}]'
assert_safe_failure image-metadata run_gate
make_image 'safe mailer fixture' '[]' \
    '[{"created_by":"export \"SMTP_PASSWORD=x\""}]'
assert_safe_failure image-metadata run_gate

assert_history_rejected() {
    local created_by="$1"
    local history_json=""

    history_json="$(jq -cn --arg created_by "${created_by}" \
        '[{created_by:$created_by}]')"
    make_image 'safe mailer fixture' '[]' "${history_json}"
    assert_safe_failure image-metadata run_gate
}

assert_history_accepted() {
    local created_by="$1"
    local history_json=""

    history_json="$(jq -cn --arg created_by "${created_by}" \
        '[{created_by:$created_by}]')"
    make_image 'safe mailer fixture' '[]' "${history_json}"
    if ! run_gate >"${temporary_dir}/accepted-history-output" 2>&1; then
        fail 'statically safe history metadata was rejected'
    fi
    grep -Fx 'ok - notifier artifact secret gate: bundle and image passed' \
        "${temporary_dir}/accepted-history-output" >/dev/null \
        || fail 'accepted history scan did not emit the fixed success diagnostic'
}

for created_by in \
    'export "SMTP_PASSWORD"=x' \
    'export SMTP_"PASSWORD"=x' \
    'export SMTP_PASSWORD\=x' \
    'export SMTP\_PASSWORD=x'; do
    assert_history_rejected "${created_by}"
    assert_history_rejected "${created_by}; SMTP_PASSWORD="
done

for created_by in \
    "export 'SMTP_'PASSWORD=x" \
    'export "SMTP_"PASSWORD=x' \
    "export $'SMTP_'PASSWORD=x" \
    "export SMTP_'PASS'WORD=x" \
    'export SMTP_"PASS"WORD=x' \
    "export SMTP_$'PASS'WORD=x" \
    "export 'SMTP_'\"PASSWORD\"=x" \
    "export \"SMTP_\"'PASSWORD'=x" \
    "export $'SMTP_'$'PASSWORD'=x" \
    "export 'NOTIFIER_HMAC_'SECRET=x" \
    'export NOTIFIER_"HMAC_"SECRET=x' \
    'export NOTIFIER_HMAC\_SECRET=x' \
    'export NOTIFIER_HMAC_SECRET\=x'; do
    assert_history_rejected "${created_by}"
done

for created_by in \
    'RUN true&&export "SMTP_PASSWORD"=x' \
    'RUN false||SMTP_"PASSWORD"=x' \
    'RUN true;SMTP_PASSWORD\=x' \
    'RUN (SMTP\_PASSWORD=x)'; do
    assert_history_rejected "${created_by}"
done

# A backslash-newline is removed by the shell before token recognition. Both
# placements below therefore create a nonempty protected assignment even
# though a later assignment in the same history entry clears the key.
assert_history_rejected $'export SMTP_\\\nPASSWORD=x; SMTP_PASSWORD='
assert_history_rejected $'export SMTP_PASSWORD\\\n=x; SMTP_PASSWORD='

# These are literal shell-history fixtures; expansion is not intended.
# shellcheck disable=SC2016
for created_by in \
    'export SMTP_$PART=x' \
    'export SMTP_${PART}=x' \
    'export SMTP_${PART:-${OTHER}}=x' \
    'export SMTP_$(printf PASSWORD)=x' \
    'export SMTP_$(printf $(echo $(printf PASSWORD)))=x' \
    'export "SMTP_${PART}"=x' \
    'export NOTIFIER_HMAC_$PART=x' \
    'export NOTIFIER_HMAC_${PART}=x' \
    'export NOTIFIER_HMAC_${PART:-${OTHER}}=x' \
    'export NOTIFIER_HMAC_$(printf SECRET)=x' \
    'export SMTP_${PART}=' \
    'export NOTIFIER_HMAC_${PART}=; NOTIFIER_HMAC_SECRET='; do
    assert_history_rejected "${created_by}"
done

# Fully dynamic export arguments can expand to protected assignments without a
# literal key or equals sign in the history text. The release grammar must fail
# closed and must still inspect an earlier occurrence when the key is cleared
# later in the same entry.
# shellcheck disable=SC2016
for created_by in \
    'export ${X:-${Y}}SMTP_PASSWORD=x; SMTP_PASSWORD=' \
    'export $PAIR; SMTP_PASSWORD=' \
    'export ${PAIR}; SMTP_PASSWORD=' \
    'export $(printf %s%s SMTP_ PASSWORD=x); SMTP_PASSWORD=' \
    'export `printf %s%s SMTP_ PASSWORD=x`; SMTP_PASSWORD='; do
    assert_history_rejected "${created_by}"
done
assert_history_rejected "export SMTP_PASSWORD\$'\\x3d'x; SMTP_PASSWORD="

# Bash assignment append, brace expansion and pathname expansion are also
# ambiguous export forms. Keep the strings as metadata only: this suite never
# evaluates history.
assert_history_rejected \
    "export SMTP_PASSWORD+=${history_planted_value}; SMTP_PASSWORD="
assert_history_rejected \
    "export {SMTP_PASSWORD,FOO}=${history_planted_value}; SMTP_PASSWORD="
# shellcheck disable=SC2016
for created_by in \
    'export *; SMTP_PASSWORD=' \
    'export [S]MTP_PASSWORD=x; SMTP_PASSWORD='; do
    assert_history_rejected "${created_by}"
done

# CR, vertical tab and form feed are ordinary token characters in the shell,
# not lexical separators. They keep the protected text inside a larger literal
# token on either side and are therefore statically safe nonmatches.
for non_separator in $'\r' $'\v' $'\f'; do
    assert_history_accepted "RUN X${non_separator}SMTP_PASSWORD=x"
    assert_history_accepted "RUN SMTP_PASSWORD${non_separator}=x"
done

# Space, tab, newline and the shell operators remain real token boundaries.
assert_history_rejected $'RUN\tSMTP_PASSWORD=x; SMTP_PASSWORD='
assert_history_rejected $'RUN true\nSMTP_PASSWORD=x; SMTP_PASSWORD='

# Policy: this gate deliberately does not interpret quote state. Assignment-
# looking quoted data and unrelated dynamic export/assignment forms fail closed
# even when a complete shell evaluation might prove a particular use harmless.
assert_history_rejected "RUN printf '%s' 'SMTP_PASSWORD=x'"
assert_history_rejected "RUN printf '%s' 'export FOO=x'"
assert_history_rejected 'RUN export SMTP_PASSWORD=""'
assert_history_rejected "RUN SMTP_USERNAME=''"
# shellcheck disable=SC2016
assert_history_rejected 'export FOO_$BAR=x'

# The allowlist still admits demonstrably plain static history, including
# protected key-only/explicit-empty forms and literal larger identifiers.
assert_history_accepted \
    'RUN FOO=bar; export BAR=baz; SMTP_PASSWORD=; export SMTP_USERNAME'
assert_history_accepted \
    'RUN XSMTP_PASSWORD=x SMTP_PASSWORDX=x éSMTP_PASSWORD=x SMTP_PASSWORDé=x 变量SMTP_PASSWORD=x'

assert_history_rejected \
    "export SMTP_\"PASSWORD\"=${history_planted_value}; SMTP_PASSWORD="

for created_by in \
    'RUN true&&SMTP_PASSWORD=x' \
    'RUN false||SMTP_PASSWORD=x' \
    'RUN true;SMTP_PASSWORD=x' \
    'RUN (SMTP_PASSWORD=x)'; do
    history_json="$(jq -cn --arg created_by "${created_by}" '[{created_by:$created_by}]')"
    make_image 'safe mailer fixture' '[]' "${history_json}"
    assert_safe_failure image-metadata run_gate
done
make_image 'safe mailer fixture' \
    '["SMTP_PASSWORD=","SMTP_USERNAME","NOTIFIER_HMAC_SECRET="]' \
    '[{"created_by":"ENV SMTP_PASSWORD="},{"created_by":"ENV NOTIFIER_HMAC_SECRET"},{"created_by":"SMTP_PASSWORD_SUFFIX=x MY_SMTP_PASSWORD=x"},{"created_by":"XSMTP_PASSWORD=x SMTP_PASSWORDX=x"},{"created_by":"éSMTP_PASSWORD=x SMTP_PASSWORDé=x"},{"created_by":"变量SMTP_PASSWORD=x SMTP_PASSWORD变量=x"},{"created_by":"RUN SMTP_PASSWORD"},{"created_by":"RUN export SMTP_PASSWORD"},{"created_by":"RUN SMTP_PASSWORD= SMTP_USERNAME= NOTIFIER_HMAC_SECRET="},{"created_by":"RUN export SMTP_PASSWORD= SMTP_USERNAME="}]'
run_gate >"${temporary_dir}/empty-key-only-output" 2>&1 \
    || fail 'absent, empty or key-only credential metadata was rejected'
assert_history_rejected 'RUN SMTP_PASSWORD="x"'
assert_history_rejected 'RUN SMTP_PASSWORD=" "'
assert_history_rejected "RUN SMTP_PASSWORD=' '"
make_image 'safe mailer fixture' '["SMTP_PASSWORD=   "]' '[]'
assert_safe_failure image-metadata run_gate
make_image 'safe mailer fixture'

for malformed_document in \
    '{"architecture":"amd64","os":"linux","config":null,"history":[]}' \
    '{"architecture":"amd64","os":"linux","config":false,"history":[]}' \
    '{"architecture":"amd64","os":"linux","config":1,"history":[]}' \
    '{"architecture":"amd64","os":"linux","config":[],"history":[]}' \
    '{"architecture":"amd64","os":"linux","config":"bad","history":[]}' \
    '{"architecture":"amd64","os":"linux","config":{"Env":false},"history":[]}' \
    '{"architecture":"amd64","os":"linux","config":{"Env":1},"history":[]}' \
    '{"architecture":"amd64","os":"linux","config":{"Env":"bad"},"history":[]}' \
    '{"architecture":"amd64","os":"linux","config":{"Env":{}},"history":[]}' \
    '{"architecture":"amd64","os":"linux","config":{"Env":[1]},"history":[]}' \
    '{"architecture":"amd64","os":"linux","config":{"Env":[]},"history":false}' \
    '{"architecture":"amd64","os":"linux","config":{"Env":[]},"history":1}' \
    '{"architecture":"amd64","os":"linux","config":{"Env":[]},"history":"bad"}' \
    '{"architecture":"amd64","os":"linux","config":{"Env":[]},"history":{}}' \
    '{"architecture":"amd64","os":"linux","config":{"Env":[]},"history":[1]}' \
    '{"architecture":"amd64","os":"linux","config":{"Env":[]},"history":[{"created_by":false}]}' \
    '{"architecture":"amd64","os":"linux","config":{"Env":[]},"history":[{"created_by":{}}]}' \
    '{"architecture":"amd64","os":"linux","config":{"Env":[]},"history":[{"created_by":[]}]}' \
    '{"architecture":"amd64","os":"linux","config":{"Env":[]},"history":[{"created_by":1}]}'; do
    make_image_document 'safe mailer fixture' "${malformed_document}" '[]'
    assert_safe_failure image-metadata run_gate
done
for accepted_document in \
    '{"architecture":"amd64","os":"linux","config":{},"history":null}' \
    '{"architecture":"amd64","os":"linux","config":{"Env":null}}' \
    '{"architecture":"amd64","os":"linux","config":{"Env":[]},"history":[{}, {"created_by":null}]}'; do
    make_image_document 'safe mailer fixture' "${accepted_document}" '[]'
    run_gate >"${temporary_dir}/accepted-null-output" 2>&1 \
        || fail 'explicitly accepted absent or null metadata was rejected'
done
make_image 'safe mailer fixture'

ln -s plugin.json \
    "${temporary_dir}/bundle-root/com.threadhub.channel-email-notifier/link"
tar -czf "${temporary_dir}/bundle.tar.gz" -C "${temporary_dir}/bundle-root" \
    com.threadhub.channel-email-notifier
assert_safe_failure bundle-archive run_gate
make_bundle 'safe plugin fixture'

FIXTURE_PLATFORM=linux/arm64 assert_safe_failure image-platform run_gate

cat >"${temporary_dir}/validate-workflow.rb" <<'RUBY'
require "yaml"

workflow = YAML.safe_load(File.read(ARGV.fetch(0)), permitted_classes: [], aliases: true)
steps = workflow.fetch("jobs").fetch("notifier-integration").fetch("steps")
names = [
  "Install pinned notifier artifact scanner",
  "Test privacy-safe notifier artifact scanner",
  "Build notifier artifacts",
  "Scan exact notifier artifacts for embedded secrets",
  "Clean pinned notifier artifact scanner",
]
indexes = names.map do |name|
  matches = steps.each_index.select { |index| steps[index]["name"] == name }
  abort("workflow contract") unless matches.length == 1
  matches.fetch(0)
end
abort("workflow contract") unless indexes == indexes.sort && indexes.uniq.length == names.length

install, fixture, build, scan, cleanup = indexes.map { |index| steps.fetch(index) }
abort("workflow contract") unless install.fetch("env").fetch("GITLEAKS_VERSION") == "8.30.1"
abort("workflow contract") unless fixture.fetch("run").include?('GITLEAKS_BIN="${install_dir}/gitleaks" ./deploy/tests/notifier-artifact-security-test.sh')
abort("workflow contract") unless build.fetch("run") == "make plugin-bundle mailer"
abort("workflow contract") unless scan.fetch("run").include?('GITLEAKS_BIN="${install_dir}/gitleaks" ./deploy/scripts/verify-notifier-artifacts.sh')
abort("workflow contract") unless cleanup.fetch("if") == "always()"
cleanup_lines = cleanup.fetch("run").lines.map(&:strip)
expected_cleanup = 'rm -rf "${RUNNER_TEMP}/gitleaks.tar.gz" "${RUNNER_TEMP}/gitleaks"'
abort("workflow contract") unless cleanup_lines.count(expected_cleanup) == 1
RUBY

ruby "${temporary_dir}/validate-workflow.rb" \
    "${REPOSITORY_ROOT}/.github/workflows/validate.yml" \
    || fail 'real notifier CI ordering and cleanup contract is invalid'
cp "${REPOSITORY_ROOT}/.github/workflows/validate.yml" \
    "${temporary_dir}/workflow-missing-cleanup.yml"
# Match the literal workflow expression; expansion is not intended.
# shellcheck disable=SC2016
sed -i.bak \
    's#rm -rf "${RUNNER_TEMP}/gitleaks.tar.gz" "${RUNNER_TEMP}/gitleaks"#:#' \
    "${temporary_dir}/workflow-missing-cleanup.yml"
rm -f "${temporary_dir}/workflow-missing-cleanup.yml.bak"
if ruby "${temporary_dir}/validate-workflow.rb" \
    "${temporary_dir}/workflow-missing-cleanup.yml" >/dev/null 2>&1; then
    fail 'CI contract accepted missing scanner cleanup command'
fi
ruby - "${REPOSITORY_ROOT}/.github/workflows/validate.yml" \
    "${temporary_dir}/workflow-reordered.yml" <<'RUBY'
require "yaml"
source, target = ARGV
workflow = YAML.safe_load(File.read(source), permitted_classes: [], aliases: true)
steps = workflow.fetch("jobs").fetch("notifier-integration").fetch("steps")
scan = steps.index { |step| step["name"] == "Scan exact notifier artifacts for embedded secrets" }
cleanup = steps.index { |step| step["name"] == "Clean pinned notifier artifact scanner" }
steps[scan], steps[cleanup] = steps[cleanup], steps[scan]
File.write(target, YAML.dump(workflow))
RUBY
if ruby "${temporary_dir}/validate-workflow.rb" \
    "${temporary_dir}/workflow-reordered.yml" >/dev/null 2>&1; then
    fail 'CI contract accepted cleanup before the artifact scan consumer'
fi
grep -F -- "--log-opts='--all'" \
    "${REPOSITORY_ROOT}/.github/workflows/validate.yml" >/dev/null \
    || fail 'CI history scan does not cover all reachable refs'

printf 'ok - notifier artifact gate rejects content, metadata, archive, platform and scanner failures safely\n'
