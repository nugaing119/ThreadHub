#!/usr/bin/env bash

# The cleanup callback is invoked indirectly by trap.
# shellcheck disable=SC2329

# Shared reviewed notifier artifact builder. Callers initialize Docker and
# sudo, then pass an already provisioned release directory.

notifier_artifact_clean_absolute_path() {
    local path="$1"

    [[ "${path}" == /* && "${path}" != / && "${path}" != *'//'* \
        && "${path}" != */./* && "${path}" != */../* \
        && "${path}" != */. && "${path}" != */.. && "${path}" != */ ]]
}

notifier_validate_artifact_release_dir() {
    local release_dir="$1"
    local identity

    notifier_artifact_clean_absolute_path "${release_dir}" || return 1
    "${SUDO_COMMAND[@]}" test -d "${release_dir}" || return 1
    "${SUDO_COMMAND[@]}" test ! -L "${release_dir}" || return 1
    identity="$("${SUDO_COMMAND[@]}" stat -c '%u:%g:%a' "${release_dir}")" || return 1
    [[ "${identity}" == 0:0:750 ]]
}

notifier_require_clean_source_commit() {
    local source_commit

    source_commit="$(GIT_OPTIONAL_LOCKS=0 git -C "${REPOSITORY_ROOT}" \
        rev-parse --verify 'HEAD^{commit}')" \
        || return 1
    [[ "${source_commit}" =~ ^[a-f0-9]{40,64}$ ]] || return 1
    [[ -z "$(GIT_OPTIONAL_LOCKS=0 git -C "${REPOSITORY_ROOT}" status --porcelain=v1 \
        --untracked-files=all --ignore-submodules=none)" ]] || return 1
    printf '%s\n' "${source_commit}"
}

notifier_artifact_release_is_current() (
    set -Eeuo pipefail

    [[ "$#" -eq 1 ]] || return 2
    release_dir="$1"
    release_file="${release_dir}/release.env"
    temporary_dir="$(mktemp -d)"
    trap 'rm -rf -- "${temporary_dir}"' EXIT HUP INT TERM
    notifier_validate_artifact_release_dir "${release_dir}" || return 1
    "${SUDO_COMMAND[@]}" test -f "${release_file}" || return 1
    "${SUDO_COMMAND[@]}" test ! -L "${release_file}" || return 1
    identity="$("${SUDO_COMMAND[@]}" stat -c '%u:%g:%a' "${release_file}")" || return 1
    [[ "${identity}" == 0:0:640 ]] || return 1
    "${SUDO_COMMAND[@]}" cat "${release_file}" > "${temporary_dir}/release.env" \
        || return 1
    chmod 0600 "${temporary_dir}/release.env"
    [[ "$(wc -l < "${temporary_dir}/release.env" | tr -d '[:space:]')" == 7 ]] \
        || return 1
    while IFS='=' read -r key value; do
        case "${key}" in
            NOTIFIER_VERSION|NOTIFIER_PLUGIN_ID|NOTIFIER_PLUGIN_BUNDLE|NOTIFIER_PLUGIN_BUNDLE_SHA256|NOTIFIER_MAILER_IMAGE|NOTIFIER_MAILER_IMAGE_ID|NOTIFIER_SOURCE_COMMIT) ;;
            *) return 1 ;;
        esac
        [[ -n "${value}" ]] || return 1
    done < "${temporary_dir}/release.env"
    current_release_value() {
        awk -F= -v key="$1" '
            $1 == key { count++; value = substr($0, index($0, "=") + 1) }
            END { if (count != 1 || value == "") exit 1; print value }
        ' "${temporary_dir}/release.env"
    }

    notifier_version="$(current_release_value NOTIFIER_VERSION)" || return 1
    plugin_id="$(current_release_value NOTIFIER_PLUGIN_ID)" || return 1
    bundle_relative="$(current_release_value NOTIFIER_PLUGIN_BUNDLE)" || return 1
    bundle_sha="$(current_release_value NOTIFIER_PLUGIN_BUNDLE_SHA256)" || return 1
    mailer_image="$(current_release_value NOTIFIER_MAILER_IMAGE)" || return 1
    mailer_image_id="$(current_release_value NOTIFIER_MAILER_IMAGE_ID)" || return 1
    source_commit="$(current_release_value NOTIFIER_SOURCE_COMMIT)" || return 1
    [[ "${notifier_version}" == "$(env_value NOTIFIER_VERSION "${VERSIONS_FILE}")" \
        && "${plugin_id}" == "$(env_value NOTIFIER_PLUGIN_ID "${VERSIONS_FILE}")" \
        && "${bundle_relative}" == "notifier/dist/${plugin_id}-${notifier_version}.tar.gz" \
        && "${bundle_sha}" =~ ^[a-f0-9]{64}$ \
        && "${mailer_image}" == "threadhub/notifier-mailer:${notifier_version}" \
        && "${mailer_image_id}" =~ ^sha256:[a-f0-9]{64}$ \
        && "${source_commit}" == "$(GIT_OPTIONAL_LOCKS=0 git -C "${REPOSITORY_ROOT}" \
            rev-parse --verify 'HEAD^{commit}')" ]] \
        || return 1
    bundle_path="${REPOSITORY_ROOT}/${bundle_relative}"
    [[ -f "${bundle_path}" && ! -L "${bundle_path}" \
        && "$(sha256_file "${bundle_path}")" == "${bundle_sha}" ]] || return 1
    [[ "$("${DOCKER_COMMAND[@]}" image inspect --format '{{.Id}}' "${mailer_image}")" \
        == "${mailer_image_id}" ]]
)

notifier_build_artifacts() (
    set -Eeuo pipefail

    [[ "$#" -eq 1 ]] || return 2
    release_dir="$1"
    notifier_validate_artifact_release_dir "${release_dir}" \
        || die "Notifier release directory must be root:root with mode 0750 and not a symbolic link"
    require_file "${VERSIONS_FILE}"
    require_file "${REPOSITORY_ROOT}/notifier/Dockerfile"
    require_file "${REPOSITORY_ROOT}/notifier/plugin/plugin.json"
    require_command git
    require_command tar

    notifier_version="$(env_value NOTIFIER_VERSION "${VERSIONS_FILE}")"
    plugin_id="$(env_value NOTIFIER_PLUGIN_ID "${VERSIONS_FILE}")"
    builder_repository="$(env_value GO_BUILDER_IMAGE_REPOSITORY "${VERSIONS_FILE}")"
    builder_tag="$(env_value GO_BUILDER_IMAGE_TAG "${VERSIONS_FILE}")"
    builder_digest="$(env_value GO_BUILDER_IMAGE_DIGEST "${VERSIONS_FILE}")"
    [[ "${notifier_version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
        || die "NOTIFIER_VERSION is invalid"
    [[ "${plugin_id}" == com.threadhub.channel-email-notifier ]] \
        || die "Unexpected notifier plugin ID"
    [[ "${builder_repository}" == golang ]] || die "Unexpected Go builder repository"
    [[ "${builder_tag}" =~ ^[0-9]+\.[0-9]+\.[0-9]+-bookworm$ ]] \
        || die "Go builder tag must be a fixed bookworm release"
    [[ "${builder_digest}" =~ ^sha256:[a-f0-9]{64}$ ]] \
        || die "Go builder digest is invalid"

    source_commit="$(notifier_require_clean_source_commit)" \
        || die "Refusing to build notifier artifacts from dirty, untracked, or unversioned source"
    source_epoch="$(GIT_OPTIONAL_LOCKS=0 git -C "${REPOSITORY_ROOT}" show -s --format=%ct "${source_commit}")" \
        || die "Unable to derive the notifier source timestamp"
    [[ "${source_epoch}" =~ ^[0-9]{1,12}$ && "${source_epoch}" -gt 0 ]] \
        || die "Notifier source timestamp is invalid"
    builder_image="${builder_repository}:${builder_tag}@${builder_digest}"
    bundle_relative="notifier/dist/${plugin_id}-${notifier_version}.tar.gz"
    bundle_path="${REPOSITORY_ROOT}/${bundle_relative}"
    bundle_dir="${REPOSITORY_ROOT}/notifier/dist"
    bundle_image="threadhub/notifier-plugin-bundle:${notifier_version}"
    mailer_image="threadhub/notifier-mailer:${notifier_version}"
    release_file="${release_dir}/release.env"
    release_staging="${release_dir}/.release.env.tmp.$$"
    tmp_dir="$(mktemp -d)"
    bundle_container=""

    cleanup_notifier_build() {
        local original_status=$?
        trap - EXIT HUP INT TERM
        if [[ -n "${bundle_container}" ]]; then
            "${DOCKER_COMMAND[@]}" rm -f "${bundle_container}" >/dev/null 2>&1 || true
        fi
        rm -rf -- "${tmp_dir}"
        exit "${original_status}"
    }
    trap cleanup_notifier_build EXIT HUP INT TERM

    [[ ! -L "${bundle_dir}" ]] || die "Refusing symbolic-link notifier artifact directory"
    [[ ! -e "${bundle_dir}" || -d "${bundle_dir}" ]] \
        || die "Notifier artifact path is not a directory"
    [[ ! -L "${bundle_path}" ]] || die "Refusing symbolic-link notifier bundle output"
    install -d -m 0755 "${tmp_dir}/context"
    GIT_OPTIONAL_LOCKS=0 git -C "${REPOSITORY_ROOT}" \
        archive --format=tar "${source_commit}:notifier" \
        | tar --extract --file - --directory "${tmp_dir}/context" \
            --no-same-owner --no-same-permissions

    log "Building the reviewed linux/amd64 notifier plugin bundle"
    "${DOCKER_COMMAND[@]}" build \
        --provenance=false \
        --platform linux/amd64 \
        --build-arg "SOURCE_DATE_EPOCH=${source_epoch}" \
        --build-arg "THREADHUB_ROOTFS_EPOCH=${source_epoch}" \
        --build-arg "GO_BUILDER_IMAGE=${builder_image}" \
        --target plugin-bundle --tag "${bundle_image}" "${tmp_dir}/context"
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
        --provenance=false \
        --platform linux/amd64 \
        --build-arg "SOURCE_DATE_EPOCH=${source_epoch}" \
        --build-arg "THREADHUB_ROOTFS_EPOCH=${source_epoch}" \
        --build-arg "GO_BUILDER_IMAGE=${builder_image}" \
        --target mailer --tag "${mailer_image}" "${tmp_dir}/context"

    bundle_sha256="$(sha256_file "${bundle_path}")"
    mailer_image_id="$("${DOCKER_COMMAND[@]}" image inspect --format '{{.Id}}' "${mailer_image}")"
    [[ "${bundle_sha256}" =~ ^[a-f0-9]{64}$ ]] \
        || die "Notifier bundle SHA-256 is invalid"
    [[ "${mailer_image_id}" =~ ^sha256:[a-f0-9]{64}$ ]] \
        || die "Notifier Mailer image ID is invalid"

    notifier_validate_artifact_release_dir "${release_dir}" \
        || die "Notifier release directory identity changed during the build"
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
)
