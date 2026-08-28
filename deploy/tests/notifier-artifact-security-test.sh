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
    local image_root="${temporary_dir}/image-root"
    local layer_root="${temporary_dir}/layer-root"
    local config_digest=""
    local config_name=""

    rm -rf "${image_root}" "${layer_root}"
    mkdir -p "${image_root}" "${layer_root}/app"
    printf '%s\n' "${content}" >"${layer_root}/app/threadhub-mailer"
    tar -cf "${image_root}/layer.tar" -C "${layer_root}" app
    jq -cn --argjson env "${env_json}" --argjson history "${history_json}" \
        '{architecture:"amd64",os:"linux",config:{Env:$env},history:$history}' \
        >"${image_root}/config-pending.json"
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
    printf '%s\n' "${env_json}" >"${temporary_dir}/env.json"
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
make_image 'safe mailer fixture' \
    '["SMTP_PASSWORD=","SMTP_USERNAME","NOTIFIER_HMAC_SECRET="]' \
    '[{"created_by":"ENV SMTP_PASSWORD="},{"created_by":"ENV NOTIFIER_HMAC_SECRET"}]'
run_gate >"${temporary_dir}/empty-key-only-output" 2>&1 \
    || fail 'absent, empty or key-only credential metadata was rejected'
make_image 'safe mailer fixture' '["SMTP_PASSWORD=   "]' '[]'
assert_safe_failure image-metadata run_gate
make_image 'safe mailer fixture'

ln -s plugin.json \
    "${temporary_dir}/bundle-root/com.threadhub.channel-email-notifier/link"
tar -czf "${temporary_dir}/bundle.tar.gz" -C "${temporary_dir}/bundle-root" \
    com.threadhub.channel-email-notifier
assert_safe_failure bundle-archive run_gate
make_bundle 'safe plugin fixture'

FIXTURE_PLATFORM=linux/arm64 assert_safe_failure image-platform run_gate

grep -F 'GITLEAKS_VERSION: 8.30.1' \
    "${REPOSITORY_ROOT}/.github/workflows/validate.yml" >/dev/null \
    || fail 'CI does not pin the artifact scanner version'
grep -F "GITLEAKS_BIN=\"\${install_dir}/gitleaks\" ./deploy/tests/notifier-artifact-security-test.sh" \
    "${REPOSITORY_ROOT}/.github/workflows/validate.yml" >/dev/null \
    || fail 'CI does not run artifact scanner rejection fixtures'
grep -F "GITLEAKS_BIN=\"\${install_dir}/gitleaks\" ./deploy/scripts/verify-notifier-artifacts.sh" \
    "${REPOSITORY_ROOT}/.github/workflows/validate.yml" >/dev/null \
    || fail 'CI does not scan the exact built notifier artifacts'
grep -F 'if: always() # scanner cleanup must run after install, fixture, build or scan failure' \
    "${REPOSITORY_ROOT}/.github/workflows/validate.yml" >/dev/null \
    || fail 'CI does not clean the pinned scanner after every preceding outcome'
grep -F -- "--log-opts='--all'" \
    "${REPOSITORY_ROOT}/.github/workflows/validate.yml" >/dev/null \
    || fail 'CI history scan does not cover all reachable refs'

printf 'ok - notifier artifact gate rejects content, metadata, archive, platform and scanner failures safely\n'
