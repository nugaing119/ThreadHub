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
    local image_root="${temporary_dir}/image-root"
    local layer_root="${temporary_dir}/layer-root"

    rm -rf "${image_root}" "${layer_root}"
    mkdir -p "${image_root}" "${layer_root}/app"
    printf '%s\n' "${content}" >"${layer_root}/app/threadhub-mailer"
    tar -cf "${image_root}/layer.tar" -C "${layer_root}" app
    cat >"${image_root}/config.json" <<'EOF'
{"architecture":"amd64","os":"linux","config":{"Env":[]}}
EOF
    cat >"${image_root}/manifest.json" <<'EOF'
[{"Config":"config.json","RepoTags":["threadhub/notifier-mailer:0.1.0"],"Layers":["layer.tar"]}]
EOF
    tar -cf "${temporary_dir}/image.tar" -C "${image_root}" \
        manifest.json config.json layer.tar
}

mkdir -p "${temporary_dir}/bin"
cat >"${temporary_dir}/bin/docker" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
case "$1 $2 $3" in
    'image inspect --format')
        case "$4" in
            '{{.Id}}') printf '%s\n' 'sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' ;;
            '{{.Os}}/{{.Architecture}}') printf '%s\n' "${FIXTURE_PLATFORM:-linux/amd64}" ;;
            '{{json .Config.Env}}') cat "${FIXTURE_ENV_JSON}" ;;
            *) exit 64 ;;
        esac
        ;;
    'image save --output')
        cp "${FIXTURE_IMAGE_ARCHIVE}" "$4"
        ;;
    'history --no-trunc --format')
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

make_bundle "${planted_secret}"
assert_safe_failure bundle-content run_gate
make_bundle 'safe plugin fixture'

make_image "${planted_secret}"
assert_safe_failure image-content run_gate
make_image 'safe mailer fixture'

printf '{"architecture":"amd64","os":"linux","config":{"Env":["APP_TOKEN=%s"]}}\n' \
    "${planted_secret}" >"${temporary_dir}/image-root/config.json"
tar -cf "${temporary_dir}/image.tar" -C "${temporary_dir}/image-root" \
    manifest.json config.json layer.tar
assert_safe_failure image-content run_gate
make_image 'safe mailer fixture'

printf '["SMTP_PASSWORD=%s"]\n' "${planted_secret}" >"${temporary_dir}/env.json"
assert_safe_failure image-metadata run_gate
printf '%s\n' '[]' >"${temporary_dir}/env.json"

printf '%s\n' "RUN SMTP_PASSWORD=${planted_secret}" >"${temporary_dir}/history"
assert_safe_failure image-metadata run_gate
: >"${temporary_dir}/history"

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
grep -F -- "--log-opts='--all'" \
    "${REPOSITORY_ROOT}/.github/workflows/validate.yml" >/dev/null \
    || fail 'CI history scan does not cover all reachable refs'

printf 'ok - notifier artifact gate rejects content, metadata, archive, platform and scanner failures safely\n'
