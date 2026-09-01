#!/usr/bin/env bash

set -Eeuo pipefail

BACKUP_OCI_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! declare -F backup_validate_config >/dev/null 2>&1; then
    # shellcheck source=backup-common.sh
    source "${BACKUP_OCI_SCRIPT_DIR}/backup-common.sh"
fi

if ! declare -p OCI_COMMAND >/dev/null 2>&1; then
    OCI_COMMAND=(/usr/local/bin/oci)
fi

backup_oci_temporary() {
    umask 077
    mktemp "${TMPDIR:-/tmp}/threadhub-backup-oci.XXXXXX"
}

backup_oci_capture() {
    local output="$1"
    shift
    local diagnostic

    diagnostic="$(backup_oci_temporary)" || return 30
    chmod 0600 "${output}" "${diagnostic}" || {
        rm -f "${diagnostic}"
        return 30
    }
    if ! "${OCI_COMMAND[@]}" "$@" \
        --auth instance_principal \
        --region "$(backup_env_value BACKUP_REGION)" \
        --output json > "${output}" 2> "${diagnostic}"; then
        rm -f "${diagnostic}"
        return 30
    fi
    rm -f "${diagnostic}"
}

backup_validate_object_key() {
    local key="$1"
    local backup_id

    [[ "${key}" =~ ^(daily|weekly)/[0-9]{4}/[0-9]{2}/[0-9]{2}/([0-9]{8}T[0-9]{6}Z-[a-f0-9]{32})/(database\.dump|mattermost-data\.tar\.zst|notifier-queue\.tar\.zst|manifest\.json|manifest\.sha256)$ ]] || return 20
    backup_id="${BASH_REMATCH[2]}"
    backup_validate_id "${backup_id}"
}

backup_oci_preflight() {
    local namespace_response bucket_response

    backup_validate_config || return 20
    namespace_response="$(backup_oci_temporary)" || return 30
    bucket_response="$(backup_oci_temporary)" || {
        rm -f "${namespace_response}"
        return 30
    }
    if ! backup_oci_capture "${namespace_response}" os ns get \
        || ! jq -e --arg expected "$(backup_env_value BACKUP_NAMESPACE)" '.data == $expected' "${namespace_response}" >/dev/null 2>&1 \
        || ! backup_oci_capture "${bucket_response}" os bucket get \
            --namespace-name "$(backup_env_value BACKUP_NAMESPACE)" \
            --name "$(backup_env_value BACKUP_BUCKET)" \
        || ! jq -e --arg expected "$(backup_env_value BACKUP_BUCKET)" \
            '.data.name == $expected and .data["public-access-type"] == "NoPublicAccess"' \
            "${bucket_response}" >/dev/null 2>&1; then
        rm -f "${namespace_response}" "${bucket_response}"
        return 30
    fi
    rm -f "${namespace_response}" "${bucket_response}"
}

backup_oci_upload() {
    local file="$1" key="$2" sha256="$3"
    local computed sha256_b64 metadata response

    backup_validate_object_key "${key}" || return 20
    [[ -f "${file}" && ! -L "${file}" && "${sha256}" =~ ^[a-f0-9]{64}$ ]] || return 20
    computed="$(sha256_file "${file}")" || return 20
    [[ "${computed}" == "${sha256}" ]] || return 20
    sha256_b64="$(openssl dgst -sha256 -binary "${file}" | openssl base64 -A)" || return 20
    [[ -n "${sha256_b64}" ]] || return 20
    metadata="$(jq -cn --arg sha "${sha256}" '{"threadhub-sha256":$sha}')" || return 20
    response="$(backup_oci_temporary)" || return 30
    if ! backup_oci_capture "${response}" os object put \
        --namespace-name "$(backup_env_value BACKUP_NAMESPACE)" \
        --bucket-name "$(backup_env_value BACKUP_BUCKET)" \
        --name "${key}" \
        --file "${file}" \
        --no-overwrite \
        --verify-checksum \
        --opc-checksum-algorithm SHA256 \
        --opc-content-sha256 "${sha256_b64}" \
        --metadata "${metadata}"; then
        rm -f "${response}"
        return 30
    fi
    rm -f "${response}"
}

backup_oci_verify() {
    local key="$1" expected_size="$2" expected_sha="$3" response

    backup_validate_object_key "${key}" || return 20
    [[ "${expected_size}" =~ ^[0-9]+$ && "${expected_sha}" =~ ^[a-f0-9]{64}$ ]] || return 20
    response="$(backup_oci_temporary)" || return 30
    if ! backup_oci_capture "${response}" os object head \
        --namespace-name "$(backup_env_value BACKUP_NAMESPACE)" \
        --bucket-name "$(backup_env_value BACKUP_BUCKET)" \
        --name "${key}" \
        || ! jq -e --arg size "${expected_size}" --arg sha "${expected_sha}" '
            (. ["content-length"] | tostring) == $size and
            .["opc-meta-threadhub-sha256"] == $sha
        ' "${response}" >/dev/null 2>&1; then
        rm -f "${response}"
        return 30
    fi
    rm -f "${response}"
}

backup_oci_page_token_is_valid() {
    (($# == 1 && ${#1} >= 1 && ${#1} <= 1024)) \
        && [[ "$1" =~ ^[-A-Za-z0-9_+=./]+$ ]]
}

backup_oci_find_tier() {
    local tier="$1" requested_id="$2"
    local response names prefixes page='' next='' page_count=0 key prefix count

    [[ "${tier}" == daily || "${tier}" == weekly ]] || return 20
    backup_validate_id "${requested_id}" || return 20
    response="$(backup_oci_temporary)" || return 30
    names="$(backup_oci_temporary)" || { rm -f "${response}"; return 30; }
    prefixes="$(backup_oci_temporary)" || { rm -f "${response}" "${names}"; return 30; }
    while :; do
        page_count=$((page_count + 1))
        if ((page_count > 100)); then
            rm -f "${response}" "${names}" "${prefixes}"
            return 30
        fi
        if [[ -n "${page}" ]]; then
            backup_oci_capture "${response}" os object list \
                --namespace-name "$(backup_env_value BACKUP_NAMESPACE)" \
                --bucket-name "$(backup_env_value BACKUP_BUCKET)" \
                --prefix "${tier}/" --page "${page}" || {
                    rm -f "${response}" "${names}" "${prefixes}"
                    return 30
                }
        else
            backup_oci_capture "${response}" os object list \
                --namespace-name "$(backup_env_value BACKUP_NAMESPACE)" \
                --bucket-name "$(backup_env_value BACKUP_BUCKET)" \
                --prefix "${tier}/" || {
                    rm -f "${response}" "${names}" "${prefixes}"
                    return 30
                }
        fi
        if ! jq -e '
                (.data | type == "array") and
                all(.data[]; type == "object" and (.name | type == "string"))
            ' "${response}" >/dev/null 2>&1 \
            || ! jq -r '.data[].name' "${response}" >> "${names}" 2>/dev/null; then
            rm -f "${response}" "${names}" "${prefixes}"
            return 30
        fi
        next="$(jq -er '.["opc-next-page"] // empty' "${response}" 2>/dev/null || true)"
        [[ -n "${next}" ]] || break
        backup_oci_page_token_is_valid "${next}" || {
            rm -f "${response}" "${names}" "${prefixes}"
            return 30
        }
        [[ "${next}" != "${page}" ]] || {
            rm -f "${response}" "${names}" "${prefixes}"
            return 30
        }
        page="${next}"
    done

    while IFS= read -r key; do
        if backup_validate_object_key "${key}" \
            && [[ "${key}" =~ ^${tier}/[0-9]{4}/[0-9]{2}/[0-9]{2}/(${requested_id})/ ]]; then
            prefix="${key%/*}"
            printf '%s\n' "${prefix}" >> "${prefixes}"
        fi
    done < "${names}"
    sort -u "${prefixes}" -o "${prefixes}"
    count="$(wc -l < "${prefixes}" | tr -d ' ')"
    if [[ "${count}" == 1 ]]; then
        cat "${prefixes}"
        rm -f "${response}" "${names}" "${prefixes}"
        return 0
    fi
    rm -f "${response}" "${names}" "${prefixes}"
    [[ "${count}" == 0 ]] && return 2
    return 30
}

backup_oci_find_set() {
    local requested_id="$1" prefix result

    backup_validate_id "${requested_id}" || return 20
    if prefix="$(backup_oci_find_tier daily "${requested_id}")"; then
        printf '%s\n' "${prefix}"
        return 0
    else
        result=$?
    fi
    ((result == 2)) || return "${result}"
    if prefix="$(backup_oci_find_tier weekly "${requested_id}")"; then
        printf '%s\n' "${prefix}"
        return 0
    else
        return $?
    fi
}

backup_oci_validate_set_prefix() {
    local prefix="$1" backup_id="$2"

    backup_validate_id "${backup_id}" || return 20
    [[ "${prefix}" =~ ^(daily|weekly)/[0-9]{4}/[0-9]{2}/[0-9]{2}/${backup_id}$ ]]
}

backup_oci_collect_prefix_names() {
    local prefix="$1" destination="$2" response page='' next='' page_count=0

    [[ -f "${destination}" && ! -L "${destination}" ]] || return 20
    response="$(backup_oci_temporary)" || return 30
    while :; do
        page_count=$((page_count + 1))
        if ((page_count > 100)); then
            rm -f -- "${response}"
            return 30
        fi
        if [[ -n "${page}" ]]; then
            backup_oci_capture "${response}" os object list \
                --namespace-name "$(backup_env_value BACKUP_NAMESPACE)" \
                --bucket-name "$(backup_env_value BACKUP_BUCKET)" \
                --prefix "${prefix}/" --page "${page}" || {
                    rm -f -- "${response}"
                    return 30
                }
        else
            backup_oci_capture "${response}" os object list \
                --namespace-name "$(backup_env_value BACKUP_NAMESPACE)" \
                --bucket-name "$(backup_env_value BACKUP_BUCKET)" \
                --prefix "${prefix}/" || {
                    rm -f -- "${response}"
                    return 30
                }
        fi
        if ! jq -e '
                (.data | type == "array") and
                all(.data[]; type == "object" and (.name | type == "string"))
            ' "${response}" >/dev/null 2>&1 \
            || ! jq -r '.data[].name' "${response}" >> "${destination}" 2>/dev/null; then
            rm -f -- "${response}"
            return 30
        fi
        next="$(jq -er '.["opc-next-page"] // empty' "${response}" 2>/dev/null || true)"
        [[ -n "${next}" ]] || break
        backup_oci_page_token_is_valid "${next}" || { rm -f -- "${response}"; return 30; }
        [[ "${next}" != "${page}" ]] || { rm -f -- "${response}"; return 30; }
        page="${next}"
    done
    rm -f -- "${response}"
}

backup_oci_prefix_is_exact_set() (
    local prefix="$1" backup_id="$2" names expected

    backup_oci_validate_set_prefix "${prefix}" "${backup_id}" || return 20
    names="$(backup_oci_temporary)" || return 30
    expected="$(backup_oci_temporary)" || { rm -f -- "${names}"; return 30; }
    trap 'rm -f -- "${names}" "${expected}"' EXIT
    : > "${names}"
    printf '%s\n' \
        "${prefix}/database.dump" \
        "${prefix}/manifest.json" \
        "${prefix}/manifest.sha256" \
        "${prefix}/mattermost-data.tar.zst" \
        "${prefix}/notifier-queue.tar.zst" \
        | LC_ALL=C sort > "${expected}"
    backup_oci_collect_prefix_names "${prefix}" "${names}" || return $?
    LC_ALL=C sort "${names}" -o "${names}" || return 30
    cmp -s "${expected}" "${names}"
)

backup_oci_verify_remote_set() (
    local prefix="$1" backup_id="$2" temporary set_dir name path size sha

    declare -F backup_validate_manifest_compatibility >/dev/null 2>&1 || return 20
    backup_oci_prefix_is_exact_set "${prefix}" "${backup_id}" || return $?
    temporary="$(mktemp -d)" || return 30
    trap 'rm -rf -- "${temporary}"' EXIT
    chmod 0700 "${temporary}" || return 30
    set_dir="${temporary}/${backup_id}"
    install -d -m 0700 "${set_dir}" || return 30
    backup_oci_download "${prefix}/manifest.sha256" "${set_dir}/manifest.sha256" || return $?
    backup_oci_download "${prefix}/manifest.json" "${set_dir}/manifest.json" || return $?
    backup_validate_manifest_compatibility "${set_dir}" "${backup_id}" || return 20

    for name in database.dump mattermost-data.tar.zst notifier-queue.tar.zst; do
        size="$(jq -er --arg name "${name}" \
            '.artifacts[] | select(.name == $name) | .bytes' \
            "${set_dir}/manifest.json" 2>/dev/null)" || return 20
        sha="$(jq -er --arg name "${name}" \
            '.artifacts[] | select(.name == $name) | .sha256' \
            "${set_dir}/manifest.json" 2>/dev/null)" || return 20
        backup_oci_verify "${prefix}/${name}" "${size}" "${sha}" || return 30
    done
    for name in manifest.json manifest.sha256; do
        path="${set_dir}/${name}"
        size="$(wc -c < "${path}" | tr -d ' ')" || return 20
        sha="$(sha256_file "${path}")" || return 20
        backup_oci_verify "${prefix}/${name}" "${size}" "${sha}" || return 30
    done
)

backup_link_no_clobber() {
    local source="$1" destination="$2" source_identity

    [[ -f "${source}" && ! -L "${source}" ]] || return 1
    [[ ! -e "${destination}" && ! -L "${destination}" ]] || return 1
    source_identity="$(backup_path_identity "${source}")" || return 1
    ln -T -- "${source}" "${destination}" >/dev/null 2>&1 || return 1
    [[ "$(backup_path_identity "${destination}")" == "${source_identity}" ]]
}

backup_oci_download() {
    local key="$1" destination="$2"
    local destination_dir temporary response uid gid

    backup_validate_object_key "${key}" || return 20
    [[ "${destination}" == /* && "${destination##*/}" == "${key##*/}" ]] || return 20
    destination_dir="$(dirname "${destination}")"
    uid="$(backup_expected_uid)"
    gid="$(backup_expected_gid)"
    backup_require_directory_mode_owner "${destination_dir}" 700 "${uid}" "${gid}" || return 20
    [[ ! -e "${destination}" && ! -L "${destination}" ]] || return 20
    temporary="$(mktemp "${destination_dir}/.${destination##*/}.download.XXXXXX")" || return 30
    response="$(backup_oci_temporary)" || { rm -f "${temporary}"; return 30; }
    if ! backup_oci_capture "${response}" os object get \
        --namespace-name "$(backup_env_value BACKUP_NAMESPACE)" \
        --bucket-name "$(backup_env_value BACKUP_BUCKET)" \
        --name "${key}" --file "${temporary}" --force \
        || ! chmod 0600 "${temporary}" \
        || ! backup_require_regular_mode_owner "${temporary}" 600 "${uid}" "${gid}" \
        || ! backup_link_no_clobber "${temporary}" "${destination}"; then
        rm -f "${temporary}" "${response}"
        return 30
    fi
    rm -f "${temporary}" "${response}"
    backup_require_regular_mode_owner "${destination}" 600 "${uid}" "${gid}"
}
