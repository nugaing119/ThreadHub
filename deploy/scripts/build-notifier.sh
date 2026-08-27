#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

require_file "${ENV_FILE}"
require_file "${VERSIONS_FILE}"
require_file "${REPOSITORY_ROOT}/notifier/Dockerfile"
require_file "${REPOSITORY_ROOT}/notifier/plugin/plugin.json"
require_command git
require_command tar
require_ubuntu_amd64
validate_base_env
init_docker
init_sudo

notifier_version="$(env_value NOTIFIER_VERSION "${VERSIONS_FILE}")"
plugin_id="$(env_value NOTIFIER_PLUGIN_ID "${VERSIONS_FILE}")"
builder_repository="$(env_value GO_BUILDER_IMAGE_REPOSITORY "${VERSIONS_FILE}")"
builder_tag="$(env_value GO_BUILDER_IMAGE_TAG "${VERSIONS_FILE}")"
builder_digest="$(env_value GO_BUILDER_IMAGE_DIGEST "${VERSIONS_FILE}")"
data_root="$(env_value THREADHUB_DATA_ROOT "${ENV_FILE}")"

[[ "${notifier_version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || die "NOTIFIER_VERSION is invalid"
[[ "${plugin_id}" == "com.threadhub.channel-email-notifier" ]] \
    || die "Unexpected notifier plugin ID"
[[ "${builder_repository}" == "golang" ]] \
    || die "Unexpected Go builder repository"
[[ "${builder_tag}" =~ ^[0-9]+\.[0-9]+\.[0-9]+-bookworm$ ]] \
    || die "Go builder tag must be a fixed bookworm release"
[[ "${builder_digest}" =~ ^sha256:[a-f0-9]{64}$ ]] \
    || die "Go builder digest is invalid"

source_commit="$(git -C "${REPOSITORY_ROOT}" rev-parse --verify 'HEAD^{commit}')"
[[ "${source_commit}" =~ ^[a-f0-9]{40,64}$ ]] \
    || die "Notifier source is not at a versioned Git commit"
if [[ -n "$(git -C "${REPOSITORY_ROOT}" status --porcelain=v1 --untracked-files=all --ignore-submodules=none)" ]]; then
    die "Refusing to build notifier artifacts from dirty or untracked source"
fi

builder_image="${builder_repository}:${builder_tag}@${builder_digest}"
bundle_relative="notifier/dist/${plugin_id}-${notifier_version}.tar.gz"
bundle_path="${REPOSITORY_ROOT}/${bundle_relative}"
bundle_dir="${REPOSITORY_ROOT}/notifier/dist"
bundle_image="threadhub/notifier-plugin-bundle:${notifier_version}"
mailer_image="threadhub/notifier-mailer:${notifier_version}"
release_dir="${data_root}/notifier/release"
release_file="${release_dir}/release.env"
release_staging="${release_dir}/.release.env.tmp.$$"
tmp_dir="$(mktemp -d)"
bundle_container=""

cleanup() {
    if [[ -n "${bundle_container}" ]]; then
        "${DOCKER_COMMAND[@]}" rm -f "${bundle_container}" >/dev/null 2>&1 || true
    fi
    rm -rf "${tmp_dir}"
}
trap cleanup EXIT HUP INT TERM

[[ ! -L "${bundle_dir}" ]] || die "Refusing symbolic-link notifier artifact directory"
[[ ! -e "${bundle_dir}" || -d "${bundle_dir}" ]] || die "Notifier artifact path is not a directory"
[[ ! -L "${bundle_path}" ]] || die "Refusing symbolic-link notifier bundle output"
install -d -m 0755 "${tmp_dir}/context"
git -C "${REPOSITORY_ROOT}" archive --format=tar "${source_commit}:notifier" \
    | tar --extract --file - --directory "${tmp_dir}/context" \
        --no-same-owner --no-same-permissions

log "Building the reviewed linux/amd64 notifier plugin bundle"
"${DOCKER_COMMAND[@]}" build \
    --platform linux/amd64 \
    --build-arg "GO_BUILDER_IMAGE=${builder_image}" \
    --target plugin-bundle \
    --tag "${bundle_image}" \
    "${tmp_dir}/context"
bundle_container="$("${DOCKER_COMMAND[@]}" create "${bundle_image}" /unused)"
[[ "${bundle_container}" =~ ^[a-f0-9]{12,64}$ ]] \
    || die "Container engine returned an invalid bundle container ID"
"${DOCKER_COMMAND[@]}" cp \
    "${bundle_container}:/${plugin_id}-${notifier_version}.tar.gz" \
    "${tmp_dir}/bundle.tar.gz"
"${DOCKER_COMMAND[@]}" rm -f "${bundle_container}" >/dev/null
bundle_container=""
install -d -m 0755 "${bundle_dir}"
install -m 0644 "${tmp_dir}/bundle.tar.gz" "${bundle_path}"

log "Building the reviewed linux/amd64 notifier Mailer image"
"${DOCKER_COMMAND[@]}" build \
    --platform linux/amd64 \
    --build-arg "GO_BUILDER_IMAGE=${builder_image}" \
    --target mailer \
    --tag "${mailer_image}" \
    "${tmp_dir}/context"

bundle_sha256="$(sha256_file "${bundle_path}")"
mailer_image_id="$("${DOCKER_COMMAND[@]}" image inspect --format '{{.Id}}' "${mailer_image}")"
[[ "${bundle_sha256}" =~ ^[a-f0-9]{64}$ ]] \
    || die "Notifier bundle SHA-256 is invalid"
[[ "${mailer_image_id}" =~ ^sha256:[a-f0-9]{64}$ ]] \
    || die "Notifier Mailer image ID is invalid"

validate_notifier_host_path "${data_root}"
"${SUDO_COMMAND[@]}" test -d "${release_dir}" \
    || die "Notifier release directory does not exist"
"${SUDO_COMMAND[@]}" test ! -L "${release_file}" \
    || die "Refusing symbolic-link notifier release file"
"${SUDO_COMMAND[@]}" test ! -e "${release_staging}" \
    || die "Refusing existing notifier release staging path"

cat > "${tmp_dir}/release.env" <<EOF
NOTIFIER_VERSION=${notifier_version}
NOTIFIER_PLUGIN_ID=${plugin_id}
NOTIFIER_PLUGIN_BUNDLE=${bundle_relative}
NOTIFIER_PLUGIN_BUNDLE_SHA256=${bundle_sha256}
NOTIFIER_MAILER_IMAGE=${mailer_image}
NOTIFIER_MAILER_IMAGE_ID=${mailer_image_id}
NOTIFIER_SOURCE_COMMIT=${source_commit}
EOF
chmod 0600 "${tmp_dir}/release.env"
"${SUDO_COMMAND[@]}" install -o root -g root -m 0640 \
    "${tmp_dir}/release.env" "${release_staging}"
"${SUDO_COMMAND[@]}" mv -fT "${release_staging}" "${release_file}"

log "Notifier bundle, Mailer image and non-secret release identity were recorded"
