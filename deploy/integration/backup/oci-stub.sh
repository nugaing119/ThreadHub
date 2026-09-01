#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

fail() {
    exit 64
}

sha256_file() {
    sha256sum "$1" | awk '{print $1}'
}

path_mode() {
    if stat -c '%a' "$1" >/dev/null 2>&1; then
        stat -c '%a' "$1"
    else
        stat -f '%Lp' "$1"
    fi
}

file_size() {
    if stat -c '%s' "$1" >/dev/null 2>&1; then
        stat -c '%s' "$1"
    else
        stat -f '%z' "$1"
    fi
}

link_no_clobber() {
    [[ ! -e "$2" && ! -L "$2" ]] || return 1
    if ln --help 2>&1 | grep -F -- '--no-target-directory' >/dev/null 2>&1; then
        ln -T -- "$1" "$2"
    else
        ln "$1" "$2"
    fi
}

require_safe_environment() {
    [[ "${OCI_STUB_NAMESPACE:-}" =~ ^[a-z0-9]{1,64}$ \
        && "${OCI_STUB_BUCKET:-}" =~ ^[a-z0-9][a-z0-9._-]{0,62}$ \
        && "${OCI_STUB_OBJECT_ROOT:-}" == /* \
        && "${OCI_STUB_AUDIT_FILE:-}" == /* ]] || fail
    [[ -d "${OCI_STUB_OBJECT_ROOT}" && ! -L "${OCI_STUB_OBJECT_ROOT}" \
        && -f "${OCI_STUB_AUDIT_FILE}" && ! -L "${OCI_STUB_AUDIT_FILE}" \
        && "$(path_mode "${OCI_STUB_OBJECT_ROOT}")" == 700 \
        && "$(path_mode "${OCI_STUB_AUDIT_FILE}")" == 600 ]] || fail
    DATA_ROOT="${OCI_STUB_OBJECT_ROOT}/objects"
    META_ROOT="${OCI_STUB_OBJECT_ROOT}/metadata"
    for path in "${DATA_ROOT}" "${META_ROOT}"; do
        if [[ ! -e "${path}" && ! -L "${path}" ]]; then
            install -d -m 0700 "${path}" || fail
        fi
        [[ -d "${path}" && ! -L "${path}" \
            && "$(path_mode "${path}")" == 700 ]] || fail
    done
}

audit_argv() {
    {
        printf 'argv'
        printf ' %q' "$@"
        printf '\n'
    } >> "${OCI_STUB_AUDIT_FILE}" || fail
}

validate_key() {
    [[ "$1" =~ ^(daily|weekly)/[0-9]{4}/[0-9]{2}/[0-9]{2}/[0-9]{8}T[0-9]{6}Z-[a-f0-9]{32}/(database\.dump|mattermost-data\.tar\.zst|notifier-queue\.tar\.zst|manifest\.json|manifest\.sha256)$ ]]
}

object_path() {
    local root="$1" key="$2"

    validate_key "${key}" || fail
    printf '%s/%s\n' "${root}" "${key}"
}

take_value() {
    (($# >= 2)) || fail
    [[ -n "$2" ]] || fail
    printf '%s\n' "$2"
}

require_target() {
    [[ "${namespace_name:-}" == "${OCI_STUB_NAMESPACE}" \
        && "${bucket_name:-}" == "${OCI_STUB_BUCKET}" ]]
}

parse_globals() {
    local -a remaining=()

    auth=''
    region=''
    output=''
    while (($# > 0)); do
        case "$1" in
            --auth)
                auth="$(take_value "$@")"
                shift 2
                ;;
            --region)
                region="$(take_value "$@")"
                shift 2
                ;;
            --output)
                output="$(take_value "$@")"
                shift 2
                ;;
            *)
                remaining+=("$1")
                shift
                ;;
        esac
    done
    [[ "${auth}" == instance_principal \
        && "${region}" == ap-singapore-1 \
        && "${output}" == json ]] || fail
    GLOBAL_REMAINING=("${remaining[@]}")
}

parse_target_options() {
    namespace_name=''
    bucket_name=''
    object_name=''
    file=''
    prefix=''
    page=''
    metadata=''
    content_sha=''
    no_overwrite=false
    force=false
    verify_checksum=false
    checksum_algorithm=''
    while (($# > 0)); do
        case "$1" in
            --namespace-name) namespace_name="$(take_value "$@")"; shift 2 ;;
            --bucket-name|--name)
                if [[ "$1" == --bucket-name ]]; then
                    bucket_name="$(take_value "$@")"
                elif [[ -z "${bucket_name}" && "${operation}" == get \
                    && "${resource}" == bucket ]]; then
                    bucket_name="$(take_value "$@")"
                else
                    object_name="$(take_value "$@")"
                fi
                shift 2
                ;;
            --file) file="$(take_value "$@")"; shift 2 ;;
            --prefix) prefix="$(take_value "$@")"; shift 2 ;;
            --page) page="$(take_value "$@")"; shift 2 ;;
            --metadata) metadata="$(take_value "$@")"; shift 2 ;;
            --opc-content-sha256) content_sha="$(take_value "$@")"; shift 2 ;;
            --opc-checksum-algorithm) checksum_algorithm="$(take_value "$@")"; shift 2 ;;
            --no-overwrite) no_overwrite=true; shift ;;
            --force) force=true; shift ;;
            --verify-checksum) verify_checksum=true; shift ;;
            *) fail ;;
        esac
    done
}

namespace_get() {
    (($# == 0)) || fail
    jq -cn --arg namespace "${OCI_STUB_NAMESPACE}" '{data:$namespace}'
}

bucket_get() {
    parse_target_options "$@"
    require_target || fail
    [[ -z "${object_name}${file}${prefix}${page}${metadata}${content_sha}${checksum_algorithm}" \
        && "${no_overwrite}" == false && "${force}" == false \
        && "${verify_checksum}" == false ]] || fail
    jq -cn --arg name "${OCI_STUB_BUCKET}" \
        '{data:{name:$name,"public-access-type":"NoPublicAccess"}}'
}

object_put() {
    local destination meta_destination parent temporary meta_temporary sha actual_b64 requested_sha

    parse_target_options "$@"
    require_target || fail
    validate_key "${object_name}" || fail
    [[ "${file}" == /* && -f "${file}" && ! -L "${file}" \
        && "${no_overwrite}" == true && "${force}" == false \
        && "${verify_checksum}" == true && "${checksum_algorithm}" == SHA256 \
        && -n "${metadata}" && -n "${content_sha}" \
        && -z "${prefix}${page}" ]] || fail
    requested_sha="$(jq -er 'select(keys == ["threadhub-sha256"]) | .["threadhub-sha256"] | select(type == "string" and test("^[a-f0-9]{64}$"))' \
        <<<"${metadata}" 2>/dev/null)" || fail
    sha="$(sha256_file "${file}")" || fail
    actual_b64="$(openssl dgst -sha256 -binary "${file}" | openssl base64 -A)" || fail
    [[ "${sha}" == "${requested_sha}" && "${actual_b64}" == "${content_sha}" ]] || fail
    destination="$(object_path "${DATA_ROOT}" "${object_name}")"
    meta_destination="$(object_path "${META_ROOT}" "${object_name}")"
    [[ ! -e "${destination}" && ! -L "${destination}" \
        && ! -e "${meta_destination}" && ! -L "${meta_destination}" ]] || fail
    parent="$(dirname "${destination}")"
    install -d -m 0700 "${parent}" "$(dirname "${meta_destination}")" || fail
    temporary="$(mktemp "${parent}/.object.XXXXXX")" || fail
    meta_temporary="$(mktemp "$(dirname "${meta_destination}")/.metadata.XXXXXX")" || {
        rm -f -- "${temporary}"
        fail
    }
    cp -- "${file}" "${temporary}" || fail
    chmod 0600 "${temporary}"
    printf '%s\n' "${sha}" > "${meta_temporary}"
    chmod 0600 "${meta_temporary}"
    link_no_clobber "${temporary}" "${destination}" || fail
    link_no_clobber "${meta_temporary}" "${meta_destination}" || fail
    rm -f -- "${temporary}" "${meta_temporary}"
    jq -cn '{}'
}

object_head() {
    local source meta sha size content_b64

    parse_target_options "$@"
    require_target || fail
    validate_key "${object_name}" || fail
    [[ -z "${file}${prefix}${page}${metadata}${content_sha}${checksum_algorithm}" \
        && "${no_overwrite}" == false && "${force}" == false \
        && "${verify_checksum}" == false ]] || fail
    source="$(object_path "${DATA_ROOT}" "${object_name}")"
    meta="$(object_path "${META_ROOT}" "${object_name}")"
    [[ -f "${source}" && ! -L "${source}" && -f "${meta}" && ! -L "${meta}" ]] || fail
    sha="$(<"${meta}")"
    [[ "${sha}" =~ ^[a-f0-9]{64}$ && "$(sha256_file "${source}")" == "${sha}" ]] || fail
    size="$(file_size "${source}")"
    content_b64="$(openssl dgst -sha256 -binary "${source}" | openssl base64 -A)"
    jq -cn --argjson size "${size}" --arg sha "${sha}" --arg content "${content_b64}" \
        '{"content-length":$size,"opc-content-sha256":$content,"opc-meta-threadhub-sha256":$sha}'
}

object_list() {
    local names offset limit=3 total next=''

    parse_target_options "$@"
    require_target || fail
    [[ "${prefix}" == daily/ || "${prefix}" == weekly/ ]] || fail
    [[ -z "${object_name}${file}${metadata}${content_sha}${checksum_algorithm}" \
        && "${no_overwrite}" == false && "${force}" == false \
        && "${verify_checksum}" == false ]] || fail
    case "${page}" in
        '') offset=0 ;;
        page-[0-9]*) offset="${page#page-}" ;;
        *) fail ;;
    esac
    [[ "${offset}" =~ ^[0-9]+$ ]] || fail
    names="$(mktemp)" || fail
    if [[ -d "${DATA_ROOT}/${prefix%/}" ]]; then
        (
            cd "${DATA_ROOT}"
            find "./${prefix%/}" -type f -print | sed 's#^\./##'
        ) | LC_ALL=C sort > "${names}" || fail
    else
        : > "${names}"
    fi
    total="$(wc -l < "${names}" | tr -d ' ')"
    if ((offset + limit < total)); then
        next="page-$((offset + limit))"
    fi
    if ! jq -Rsc --argjson offset "${offset}" --argjson limit "${limit}" --arg next "${next}" '
        split("\n") | map(select(length > 0)) as $all |
        {data:($all[$offset:$offset+$limit] | map({name:.}))} +
        (if $next == "" then {} else {"opc-next-page":$next} end)
    ' "${names}"; then
        rm -f -- "${names}"
        fail
    fi
    rm -f -- "${names}"
}

object_get() {
    local source

    parse_target_options "$@"
    require_target || fail
    validate_key "${object_name}" || fail
    [[ "${file}" == /* && -f "${file}" && ! -L "${file}" \
        && "${force}" == true && "${no_overwrite}" == false \
        && "${verify_checksum}" == false \
        && -z "${prefix}${page}${metadata}${content_sha}${checksum_algorithm}" ]] || fail
    source="$(object_path "${DATA_ROOT}" "${object_name}")"
    [[ -f "${source}" && ! -L "${source}" ]] || fail
    cp -- "${source}" "${file}" || fail
    chmod 0600 "${file}"
    jq -cn '{}'
}

main() {
    local service resource operation

    require_safe_environment
    audit_argv "$@"
    parse_globals "$@"
    set -- "${GLOBAL_REMAINING[@]}"
    (($# >= 3)) || fail
    service="$1"
    resource="$2"
    operation="$3"
    shift 3
    [[ "${service}" == os ]] || fail
    case "${operation}" in
        delete) fail ;;
    esac
    case "${resource}:${operation}" in
        ns:get) namespace_get "$@" ;;
        bucket:get) bucket_get "$@" ;;
        object:put) object_put "$@" ;;
        object:head) object_head "$@" ;;
        object:list) object_list "$@" ;;
        object:get) object_get "$@" ;;
        *) fail ;;
    esac
}

main "$@"
