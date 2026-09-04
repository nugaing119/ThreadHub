#!/usr/bin/env bash

set -Eeuo pipefail

BACKUP_ARTIFACT_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! declare -F backup_validate_id >/dev/null 2>&1; then
    # shellcheck source=backup-common.sh
    source "${BACKUP_ARTIFACT_SCRIPT_DIR}/backup-common.sh"
fi

BACKUP_ARTIFACT_MATTERMOST_DATA_ROOT="${BACKUP_ARTIFACT_MATTERMOST_DATA_ROOT:-/srv/threadhub/mattermost/data}"
BACKUP_ARTIFACT_NOTIFIER_ROOT="${BACKUP_ARTIFACT_NOTIFIER_ROOT:-/srv/threadhub/notifier}"
BACKUP_ARTIFACT_RELEASE_FILE="${BACKUP_ARTIFACT_RELEASE_FILE:-${BACKUP_ARTIFACT_NOTIFIER_ROOT}/release/release.env}"
BACKUP_ARTIFACT_SOURCE_COMMIT_MODE="${BACKUP_ARTIFACT_SOURCE_COMMIT_MODE:-current}"
BACKUP_TAR_COMMAND=(tar)
BACKUP_TAR_QUOTING_ARGS=(--quoting-style=escape)

backup_artifact_temporary() {
    umask 077
    mktemp "${TMPDIR:-/tmp}/threadhub-backup-artifact.XXXXXX"
}

backup_artifact_publish_no_clobber() {
    local source="$1" destination="$2" source_identity

    [[ -f "${source}" && ! -L "${source}" ]] || return 1
    [[ ! -e "${destination}" && ! -L "${destination}" ]] || return 1
    source_identity="$(backup_path_identity "${source}")" || return 1
    ln -- "${source}" "${destination}" >/dev/null 2>&1 || return 1
    [[ "$(backup_path_identity "${destination}")" == "${source_identity}" ]] || return 1
    rm -f -- "${source}"
}

backup_artifact_set_dir_is_valid() {
    local set_dir="$1" uid gid

    [[ "${set_dir}" == /* && "${set_dir}" != / && "${set_dir}" != *'//'* \
        && "${set_dir}" != */./* && "${set_dir}" != */../* \
        && "${set_dir}" != */. && "${set_dir}" != */.. && "${set_dir}" != */ ]] || return 20
    backup_validate_id "${set_dir##*/}" || return 20
    uid="$(backup_expected_uid)"
    gid="$(backup_expected_gid)"
    backup_require_directory_mode_owner "${set_dir}" 700 "${uid}" "${gid}"
}

backup_artifact_file_is_private() {
    local path="$1" uid gid

    uid="$(backup_expected_uid)"
    gid="$(backup_expected_gid)"
    backup_require_regular_mode_owner "${path}" 600 "${uid}" "${gid}"
}

backup_generate_id() {
    local timestamp random

    timestamp="$(date -u +%Y%m%dT%H%M%SZ)" || return 20
    random="$(openssl rand -hex 16 2>/dev/null)" || return 20
    backup_validate_id "${timestamp}-${random}" || return 20
    printf '%s-%s\n' "${timestamp}" "${random}"
}

backup_id_created_at() {
    local backup_id="$1" compact expected parsed

    backup_validate_id "${backup_id}" || return 20
    compact="${backup_id%%-*}"
    expected="${compact:0:4}-${compact:4:2}-${compact:6:2}T${compact:9:2}:${compact:11:2}:${compact:13:2}Z"
    if parsed="$(date -u -d "${expected}" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"; then
        :
    elif parsed="$(date -j -u -f '%Y%m%dT%H%M%SZ' "${compact}" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"; then
        :
    else
        return 20
    fi
    [[ "${parsed}" == "${expected}" ]] || return 20
    printf '%s\n' "${expected}"
}

backup_artifact_release_value() {
    local path="$1" key="$2"

    LC_ALL=C awk -F= -v key="${key}" '
        $1 == key {
            count++
            value = substr($0, index($0, "=") + 1)
        }
        END {
            if (count != 1 || value == "") exit 1
            print value
        }
    ' "${path}"
}

backup_artifact_copy_release() {
    local destination="$1" uid gid

    uid="$(backup_expected_uid)"
    gid="$(backup_expected_gid)"
    backup_require_regular_mode_owner "${BACKUP_ARTIFACT_RELEASE_FILE}" 640 "${uid}" "${gid}" || return 20
    if ! cat "${BACKUP_ARTIFACT_RELEASE_FILE}" > "${destination}" \
        || ! chmod 0600 "${destination}" \
        || ! backup_require_exact_keys "${destination}" \
            NOTIFIER_VERSION NOTIFIER_PLUGIN_ID NOTIFIER_PLUGIN_BUNDLE \
            NOTIFIER_PLUGIN_BUNDLE_SHA256 NOTIFIER_MAILER_IMAGE \
            NOTIFIER_MAILER_IMAGE_ID NOTIFIER_SOURCE_COMMIT; then
        return 20
    fi
}

backup_artifact_git_commit() {
    local source_commit

    case "${BACKUP_ARTIFACT_SOURCE_COMMIT_MODE}" in
        current)
            source_commit="$(GIT_OPTIONAL_LOCKS=0 git -C "${REPOSITORY_ROOT}" \
                rev-parse --verify 'HEAD^{commit}' 2>/dev/null)" || return 20
            ;;
        release)
            source_commit="$(backup_artifact_release_value \
                "${BACKUP_ARTIFACT_RELEASE_FILE}" NOTIFIER_SOURCE_COMMIT)" || return 20
            GIT_OPTIONAL_LOCKS=0 git -C "${REPOSITORY_ROOT}" \
                cat-file -e "${source_commit}^{commit}" 2>/dev/null || return 20
            ;;
        *) return 20 ;;
    esac
    [[ "${source_commit}" =~ ^[a-f0-9]{40}$|^[a-f0-9]{64}$ ]] || return 20
    [[ -z "$(GIT_OPTIONAL_LOCKS=0 git -C "${REPOSITORY_ROOT}" status --porcelain=v1 \
        --untracked-files=all --ignore-submodules=none 2>/dev/null)" ]] || return 20
    printf '%s\n' "${source_commit}"
}

backup_artifact_compatibility_json() {
    local source_commit notifier_version
    local mattermost_repository mattermost_tag mattermost_digest
    local postgres_repository postgres_tag postgres_digest

    source_commit="$(backup_artifact_git_commit)" || return 20
    mattermost_repository="$(env_value MATTERMOST_IMAGE_REPOSITORY "${VERSIONS_FILE}")" || return 20
    mattermost_tag="$(env_value MATTERMOST_IMAGE_TAG "${VERSIONS_FILE}")" || return 20
    mattermost_digest="$(env_value MATTERMOST_IMAGE_DIGEST "${VERSIONS_FILE}")" || return 20
    postgres_repository="$(env_value POSTGRES_IMAGE_REPOSITORY "${VERSIONS_FILE}")" || return 20
    postgres_tag="$(env_value POSTGRES_IMAGE_TAG "${VERSIONS_FILE}")" || return 20
    postgres_digest="$(env_value POSTGRES_IMAGE_DIGEST "${VERSIONS_FILE}")" || return 20
    notifier_version="$(env_value NOTIFIER_VERSION "${VERSIONS_FILE}")" || return 20

    [[ "${notifier_version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ \
        && "${mattermost_repository}" == mattermost/mattermost-team-edition \
        && "${mattermost_tag}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ \
        && "${mattermost_digest}" =~ ^sha256:[a-f0-9]{64}$ \
        && "${postgres_repository}" == postgres \
        && "${postgres_tag}" =~ ^[0-9]+\.[0-9]+$ \
        && "${postgres_digest}" =~ ^sha256:[a-f0-9]{64}$ ]] || return 20

    jq -S -c -n \
        --arg source_commit "${source_commit}" \
        --arg mattermost_repository "${mattermost_repository}" \
        --arg mattermost_tag "${mattermost_tag}" \
        --arg mattermost_digest "${mattermost_digest}" \
        --arg postgres_repository "${postgres_repository}" \
        --arg postgres_tag "${postgres_tag}" \
        --arg postgres_digest "${postgres_digest}" \
        --arg notifier_version "${notifier_version}" '
        {
          source_commit:$source_commit,
          images:{
            mattermost:{repository:$mattermost_repository,tag:$mattermost_tag,digest:$mattermost_digest},
            postgres:{repository:$postgres_repository,tag:$postgres_tag,digest:$postgres_digest}
          },
          notifier:{version:$notifier_version}
        }
    '
}

backup_artifact_provenance_json() {
    local compatibility release_copy source_commit release_commit notifier_version release_notifier_version
    local plugin_id plugin_bundle plugin_bundle_sha mailer_image mailer_image_id

    compatibility="$(backup_artifact_compatibility_json)" || return 20
    source_commit="$(jq -er '.source_commit' <<< "${compatibility}")" || return 20
    notifier_version="$(jq -er '.notifier.version' <<< "${compatibility}")" || return 20
    release_copy="$(backup_artifact_temporary)" || return 20
    if ! backup_artifact_copy_release "${release_copy}"; then
        rm -f -- "${release_copy}"
        return 20
    fi
    release_commit="$(backup_artifact_release_value "${release_copy}" NOTIFIER_SOURCE_COMMIT)" || {
        rm -f -- "${release_copy}"
        return 20
    }
    release_notifier_version="$(backup_artifact_release_value "${release_copy}" NOTIFIER_VERSION)" || {
        rm -f -- "${release_copy}"
        return 20
    }
    plugin_id="$(backup_artifact_release_value "${release_copy}" NOTIFIER_PLUGIN_ID)" || {
        rm -f -- "${release_copy}"
        return 20
    }
    plugin_bundle="$(backup_artifact_release_value "${release_copy}" NOTIFIER_PLUGIN_BUNDLE)" || {
        rm -f -- "${release_copy}"
        return 20
    }
    plugin_bundle_sha="$(backup_artifact_release_value "${release_copy}" NOTIFIER_PLUGIN_BUNDLE_SHA256)" || {
        rm -f -- "${release_copy}"
        return 20
    }
    mailer_image="$(backup_artifact_release_value "${release_copy}" NOTIFIER_MAILER_IMAGE)" || {
        rm -f -- "${release_copy}"
        return 20
    }
    mailer_image_id="$(backup_artifact_release_value "${release_copy}" NOTIFIER_MAILER_IMAGE_ID)" || {
        rm -f -- "${release_copy}"
        return 20
    }
    rm -f -- "${release_copy}"

    [[ "${release_commit}" == "${source_commit}" \
        && "${release_notifier_version}" == "${notifier_version}" \
        && "${notifier_version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ \
        && "${plugin_id}" == com.threadhub.channel-email-notifier \
        && "${plugin_bundle}" == "notifier/dist/${plugin_id}-${notifier_version}.tar.gz" \
        && "${plugin_bundle_sha}" =~ ^[a-f0-9]{64}$ \
        && "${mailer_image}" == "threadhub/notifier-mailer:${notifier_version}" \
        && "${mailer_image_id}" =~ ^sha256:[a-f0-9]{64}$ ]] || return 20

    jq -S -c --arg mailer_image_id "${mailer_image_id}" \
        '.notifier.mailer_image_id = $mailer_image_id' <<< "${compatibility}"
}

backup_create_database_dump() {
    local output="$1" db_user db_name

    [[ "${output}" == /* && "${output##*/}" == database.dump \
        && ! -e "${output}" && ! -L "${output}" ]] || return 20
    db_user="$(env_value POSTGRES_USER "${ENV_FILE}")" || return 20
    db_name="$(env_value POSTGRES_DB "${ENV_FILE}")" || return 20
    [[ "${db_user}" =~ ^[A-Za-z_][A-Za-z0-9_.-]{0,62}$ \
        && "${db_name}" =~ ^[A-Za-z_][A-Za-z0-9_.-]{0,62}$ ]] || return 20
    if ! ( umask 077; set -o noclobber; compose exec -T postgres pg_dump \
        --format=custom --no-owner --no-acl --username "${db_user}" --dbname "${db_name}" > "${output}" ); then
        rm -f -- "${output}"
        return 30
    fi
    chmod 0600 "${output}" || { rm -f -- "${output}"; return 30; }
    [[ -s "${output}" ]] || { rm -f -- "${output}"; return 30; }
    backup_artifact_file_is_private "${output}"
}

backup_create_archive() {
    local source_dir="$1" output="$2"
    shift 2
    local raw_list file_list temporary diagnostic path relative name invalid=false
    local -a fixed_names=("$@")

    [[ "${source_dir}" == /* && -d "${source_dir}" && ! -L "${source_dir}" \
        && "${output}" == /* && "${output}" == *.tar.zst \
        && ! -e "${output}" && ! -L "${output}" ]] || return 20
    raw_list="$(backup_artifact_temporary)" || return 30
    file_list="$(backup_artifact_temporary)" || { rm -f -- "${raw_list}"; return 30; }
    temporary="$(mktemp "${output}.tmp.XXXXXX")" || {
        rm -f -- "${raw_list}" "${file_list}"
        return 30
    }
    diagnostic="$(backup_artifact_temporary)" || {
        rm -f -- "${raw_list}" "${file_list}" "${temporary}"
        return 30
    }

    if ((${#fixed_names[@]} > 0)); then
        [[ "${fixed_names[0]}" == queue.db ]] || {
            rm -f -- "${raw_list}" "${file_list}" "${temporary}" "${diagnostic}"
            return 20
        }
        for name in "${fixed_names[@]}"; do
            [[ "${name}" == queue.db || "${name}" == queue.db-wal || "${name}" == queue.db-shm ]] || {
                rm -f -- "${raw_list}" "${file_list}" "${temporary}" "${diagnostic}"
                return 20
            }
            if [[ "${name}" == queue.db || -e "${source_dir}/${name}" || -L "${source_dir}/${name}" ]]; then
                [[ -f "${source_dir}/${name}" && ! -L "${source_dir}/${name}" ]] || {
                    rm -f -- "${raw_list}" "${file_list}" "${temporary}" "${diagnostic}"
                    return 20
                }
                printf '%s\0' "${name}" >> "${file_list}"
            fi
        done
    else
        if ! (cd "${source_dir}" && find -P . -mindepth 1 -print0 > "${raw_list}") 2>"${diagnostic}"; then
            rm -f -- "${raw_list}" "${file_list}" "${temporary}" "${diagnostic}"
            return 30
        fi
        while IFS= read -r -d '' path; do
            relative="${path#./}"
            if [[ -z "${relative}" || "${relative}" == "${path}" \
                || ( ! -f "${source_dir}/${relative}" && ! -d "${source_dir}/${relative}" ) \
                || -L "${source_dir}/${relative}" ]]; then
                invalid=true
                break
            fi
            printf '%s\0' "${relative}" >> "${file_list}"
        done < "${raw_list}"
        if [[ "${invalid}" == true ]]; then
            rm -f -- "${raw_list}" "${file_list}" "${temporary}" "${diagnostic}"
            return 20
        fi
    fi

    if ! "${BACKUP_TAR_COMMAND[@]}" --create --zstd --file "${temporary}" \
        --directory "${source_dir}" --no-recursion --numeric-owner --owner=0 --group=0 \
        --null --files-from "${file_list}" > /dev/null 2>"${diagnostic}" \
        || ! chmod 0600 "${temporary}" \
        || ! backup_artifact_file_is_private "${temporary}" \
        || ! backup_artifact_publish_no_clobber "${temporary}" "${output}"; then
        rm -f -- "${raw_list}" "${file_list}" "${temporary}" "${diagnostic}"
        return 30
    fi
    rm -f -- "${raw_list}" "${file_list}" "${diagnostic}"
}

backup_create_artifacts() {
    local set_dir="$1"
    local database_dump data_archive queue_archive

    backup_artifact_set_dir_is_valid "${set_dir}" || return 20
    database_dump="${set_dir}/database.dump"
    data_archive="${set_dir}/mattermost-data.tar.zst"
    queue_archive="${set_dir}/notifier-queue.tar.zst"
    [[ ! -e "${database_dump}" && ! -L "${database_dump}" \
        && ! -e "${data_archive}" && ! -L "${data_archive}" \
        && ! -e "${queue_archive}" && ! -L "${queue_archive}" ]] || return 20
    if ! backup_create_database_dump "${database_dump}" \
        || ! backup_create_archive "${BACKUP_ARTIFACT_MATTERMOST_DATA_ROOT}" "${data_archive}" \
        || ! backup_create_archive "${BACKUP_ARTIFACT_NOTIFIER_ROOT}/mailer" "${queue_archive}" \
            queue.db queue.db-wal queue.db-shm; then
        rm -f -- "${database_dump}" "${data_archive}" "${queue_archive}"
        return 30
    fi
}

backup_write_manifest() {
    local set_dir="$1" backup_id created_at provenance
    local manifest manifest_checksum temporary checksum_temporary name path bytes sha
    local artifacts_json='[]'

    backup_artifact_set_dir_is_valid "${set_dir}" || return 20
    backup_id="${set_dir##*/}"
    created_at="$(backup_id_created_at "${backup_id}")" || return 20
    provenance="$(backup_artifact_provenance_json)" || return 20
    manifest="${set_dir}/manifest.json"
    manifest_checksum="${set_dir}/manifest.sha256"
    [[ ! -e "${manifest}" && ! -L "${manifest}" \
        && ! -e "${manifest_checksum}" && ! -L "${manifest_checksum}" ]] || return 20

    for name in database.dump mattermost-data.tar.zst notifier-queue.tar.zst; do
        path="${set_dir}/${name}"
        backup_artifact_file_is_private "${path}" || return 20
        bytes="$(wc -c < "${path}" | tr -d ' ')" || return 20
        sha="$(sha256_file "${path}")" || return 20
        [[ "${bytes}" =~ ^[0-9]+$ && "${bytes}" -gt 0 && "${sha}" =~ ^[a-f0-9]{64}$ ]] || return 20
        artifacts_json="$(jq -c --arg name "${name}" --argjson bytes "${bytes}" --arg sha "${sha}" \
            '. + [{name:$name,bytes:$bytes,sha256:$sha}]' <<< "${artifacts_json}")" || return 20
    done

    temporary="$(mktemp "${set_dir}/.manifest.json.tmp.XXXXXX")" || return 30
    checksum_temporary="$(mktemp "${set_dir}/.manifest.sha256.tmp.XXXXXX")" || {
        rm -f -- "${temporary}"
        return 30
    }
    if ! jq -S -c -n \
        --argjson schema_version 1 --arg backup_id "${backup_id}" --arg created_at "${created_at}" \
        --arg source_commit "$(jq -er '.source_commit' <<< "${provenance}")" \
        --argjson images "$(jq -c '.images' <<< "${provenance}")" \
        --argjson notifier "$(jq -c '.notifier' <<< "${provenance}")" \
        --argjson artifacts "${artifacts_json}" '
          {
            schema_version:$schema_version,
            backup_id:$backup_id,
            created_at:$created_at,
            source_commit:$source_commit,
            images:$images,
            notifier:$notifier,
            artifacts:$artifacts
          }
        ' > "${temporary}" \
        || ! chmod 0600 "${temporary}" \
        || ! printf '%s  manifest.json\n' "$(sha256_file "${temporary}")" > "${checksum_temporary}" \
        || ! chmod 0600 "${checksum_temporary}" \
        || ! backup_artifact_publish_no_clobber "${temporary}" "${manifest}" \
        || ! backup_artifact_publish_no_clobber "${checksum_temporary}" "${manifest_checksum}"; then
        rm -f -- "${temporary}" "${checksum_temporary}"
        return 30
    fi
}

backup_validate_manifest_compatibility() {
    local set_dir="$1" expected_id="$2" manifest manifest_checksum checksum_line expected_line
    local expected_created_at compatibility source_commit images notifier_version

    backup_validate_id "${expected_id}" || return 20
    backup_artifact_set_dir_is_valid "${set_dir}" || return 20
    [[ "${set_dir##*/}" == "${expected_id}" ]] || return 20
    manifest="${set_dir}/manifest.json"
    manifest_checksum="${set_dir}/manifest.sha256"
    backup_artifact_file_is_private "${manifest}" || return 20
    backup_artifact_file_is_private "${manifest_checksum}" || return 20
    [[ "$(wc -l < "${manifest_checksum}" | tr -d ' ')" == 1 ]] || return 20
    checksum_line="$(<"${manifest_checksum}")"
    expected_line="$(sha256_file "${manifest}")  manifest.json" || return 20
    [[ "${checksum_line}" == "${expected_line}" ]] || return 20

    expected_created_at="$(backup_id_created_at "${expected_id}")" || return 20
    compatibility="$(backup_artifact_compatibility_json)" || return 20
    source_commit="$(jq -er '.source_commit' <<< "${compatibility}")" || return 20
    images="$(jq -cS '.images' <<< "${compatibility}")" || return 20
    notifier_version="$(jq -er '.notifier.version' <<< "${compatibility}")" || return 20
    jq -e --arg backup_id "${expected_id}" --arg created_at "${expected_created_at}" \
        --arg source_commit "${source_commit}" --argjson images "${images}" \
        --arg notifier_version "${notifier_version}" '
        type == "object" and
        keys == ["artifacts","backup_id","created_at","images","notifier","schema_version","source_commit"] and
        .schema_version == 1 and .backup_id == $backup_id and .created_at == $created_at and
        .source_commit == $source_commit and .images == $images and
        (.images | keys == ["mattermost","postgres"]) and
        (.images.mattermost | keys == ["digest","repository","tag"]) and
        (.images.postgres | keys == ["digest","repository","tag"]) and
        (.notifier | keys == ["mailer_image_id","version"]) and
        .notifier.version == $notifier_version and
        (.notifier.mailer_image_id | type == "string" and test("^sha256:[a-f0-9]{64}$")) and
        (.artifacts | type == "array" and length == 3) and
        (.artifacts | map(.name) == ["database.dump","mattermost-data.tar.zst","notifier-queue.tar.zst"]) and
        (.artifacts | all(
          type == "object" and keys == ["bytes","name","sha256"] and
          (.bytes | type == "number" and floor == . and . > 0) and
          (.sha256 | type == "string" and test("^[a-f0-9]{64}$"))
        ))
    ' "${manifest}" >/dev/null 2>&1
}

backup_validate_manifest_identity() {
    local set_dir="$1" expected_id="$2" provenance notifier

    backup_validate_manifest_compatibility "${set_dir}" "${expected_id}" || return 20
    provenance="$(backup_artifact_provenance_json)" || return 20
    notifier="$(jq -cS '.notifier' <<< "${provenance}")" || return 20
    jq -e --argjson notifier "${notifier}" '.notifier == $notifier' \
        "${set_dir}/manifest.json" >/dev/null 2>&1
}

backup_require_gnu_tar() {
    "${BACKUP_TAR_COMMAND[@]}" --version 2>/dev/null | head -n 1 | grep -F 'GNU tar' >/dev/null
}

backup_validate_archive() {
    local archive="$1" names listing diagnostic name entry_count listing_count invalid=false

    [[ "${archive##*/}" == mattermost-data.tar.zst || "${archive##*/}" == notifier-queue.tar.zst ]] || return 20
    backup_artifact_file_is_private "${archive}" || return 20
    [[ -s "${archive}" ]] || return 20
    backup_require_gnu_tar || return 20
    names="$(backup_artifact_temporary)" || return 20
    listing="$(backup_artifact_temporary)" || { rm -f -- "${names}"; return 20; }
    diagnostic="$(backup_artifact_temporary)" || { rm -f -- "${names}" "${listing}"; return 20; }
    if ! "${BACKUP_TAR_COMMAND[@]}" --list --zstd --file "${archive}" \
        "${BACKUP_TAR_QUOTING_ARGS[@]}" > "${names}" 2>"${diagnostic}" \
        || ! "${BACKUP_TAR_COMMAND[@]}" --list --verbose --zstd --file "${archive}" \
            "${BACKUP_TAR_QUOTING_ARGS[@]}" > "${listing}" 2>"${diagnostic}"; then
        rm -f -- "${names}" "${listing}" "${diagnostic}"
        return 20
    fi
    entry_count=0
    while IFS= read -r name; do
        entry_count=$((entry_count + 1))
        if [[ -z "${name}" || "${name}" == /* || "${name}" == *'//'* || "${name}" == *"\\"* \
            || "${name}" =~ (^|/)\.\.?(/|$) ]]; then
            invalid=true
            break
        fi
        if [[ "${archive##*/}" == notifier-queue.tar.zst ]]; then
            if [[ "${name}" != queue.db && "${name}" != queue.db-wal && "${name}" != queue.db-shm ]]; then
                invalid=true
                break
            fi
        fi
    done < "${names}"
    if [[ "${invalid}" == true \
        || ( "${archive##*/}" == notifier-queue.tar.zst && entry_count -eq 0 ) ]]; then
        rm -f -- "${names}" "${listing}" "${diagnostic}"
        return 20
    fi
    listing_count=0
    while IFS= read -r name; do
        listing_count=$((listing_count + 1))
        if [[ "${name:0:1}" != '-' && "${name:0:1}" != d ]]; then
            invalid=true
            break
        fi
    done < "${listing}"
    if [[ "${invalid}" == true || "${listing_count}" != "${entry_count}" ]]; then
        rm -f -- "${names}" "${listing}" "${diagnostic}"
        return 20
    fi
    if [[ -n "$(LC_ALL=C sort "${names}" | uniq -d)" ]]; then
        rm -f -- "${names}" "${listing}" "${diagnostic}"
        return 20
    fi
    if [[ "${archive##*/}" == notifier-queue.tar.zst ]]; then
        [[ "$(grep -Fxc queue.db "${names}")" == 1 ]] || {
            rm -f -- "${names}" "${listing}" "${diagnostic}"
            return 20
        }
    fi
    rm -f -- "${names}" "${listing}" "${diagnostic}"
}

backup_validate_set_with_manifest_validator() {
    local validator="$1" set_dir="$2" expected_id="$3" names name expected bytes sha path

    [[ "${validator}" == backup_validate_manifest_identity \
        || "${validator}" == backup_validate_manifest_compatibility ]] || return 20
    "${validator}" "${set_dir}" "${expected_id}" || return 20
    names="$(backup_artifact_temporary)" || return 20
    if ! find -P "${set_dir}" -mindepth 1 -maxdepth 1 -exec basename {} \; \
        | LC_ALL=C sort > "${names}"; then
        rm -f -- "${names}"
        return 20
    fi
    expected=$'database.dump\nmanifest.json\nmanifest.sha256\nmattermost-data.tar.zst\nnotifier-queue.tar.zst'
    [[ "$(<"${names}")" == "${expected}" ]] || { rm -f -- "${names}"; return 20; }
    rm -f -- "${names}"

    for name in database.dump mattermost-data.tar.zst notifier-queue.tar.zst; do
        path="${set_dir}/${name}"
        backup_artifact_file_is_private "${path}" || return 20
        bytes="$(jq -er --arg name "${name}" '.artifacts[] | select(.name == $name) | .bytes' \
            "${set_dir}/manifest.json" 2>/dev/null)" || return 20
        sha="$(jq -er --arg name "${name}" '.artifacts[] | select(.name == $name) | .sha256' \
            "${set_dir}/manifest.json" 2>/dev/null)" || return 20
        [[ "$(wc -c < "${path}" | tr -d ' ')" == "${bytes}" \
            && "$(sha256_file "${path}")" == "${sha}" ]] || return 20
    done
    backup_validate_archive "${set_dir}/mattermost-data.tar.zst" || return 20
    backup_validate_archive "${set_dir}/notifier-queue.tar.zst"
}

backup_validate_set() {
    backup_validate_set_with_manifest_validator backup_validate_manifest_identity "$@"
}

backup_validate_set_compatibility() {
    backup_validate_set_with_manifest_validator backup_validate_manifest_compatibility "$@"
}

backup_extract_archive() {
    local archive="$1" destination="$2" before after diagnostic uid gid

    backup_validate_archive "${archive}" || return 20
    [[ "${destination}" == /* ]] || return 20
    uid="$(backup_expected_uid)"
    gid="$(backup_expected_gid)"
    backup_require_directory_mode_owner "${destination}" 700 "${uid}" "${gid}" || return 20
    [[ -z "$(find -P "${destination}" -mindepth 1 -print -quit 2>/dev/null)" ]] || return 20
    before="$(sha256_file "${archive}")" || return 20
    diagnostic="$(backup_artifact_temporary)" || return 20
    if ! "${BACKUP_TAR_COMMAND[@]}" --extract --zstd --file "${archive}" \
        --directory "${destination}" --no-same-owner --no-same-permissions \
        > /dev/null 2>"${diagnostic}"; then
        rm -f -- "${diagnostic}"
        return 20
    fi
    rm -f -- "${diagnostic}"
    after="$(sha256_file "${archive}")" || return 20
    [[ "${after}" == "${before}" ]]
}
