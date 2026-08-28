#!/usr/bin/env bash

set -Eeuo pipefail

umask 077

fail() {
    printf 'not ok - notifier artifact secret gate: %s\n' "$1" >&2
    exit 1
}

archive_entries_are_safe() {
    local entries_file="$1"

    LC_ALL=C awk '
        /^\// { exit 1 }
        {
            count = split($0, parts, "/")
            for (i = 1; i <= count; i++) {
                if (parts[i] == "..") exit 1
            }
        }
    ' "${entries_file}" || return 1
    ! LC_ALL=C grep -q '[[:cntrl:]]' "${entries_file}"
}

archive_types_are_safe() {
    local listing_file="$1"
    local allow_links="${2:-false}"

    if [[ "${allow_links}" == true ]]; then
        LC_ALL=C awk 'substr($0, 1, 1) != "-" && substr($0, 1, 1) != "d" && substr($0, 1, 1) != "l" { exit 1 }' \
            "${listing_file}"
    else
        LC_ALL=C awk 'substr($0, 1, 1) != "-" && substr($0, 1, 1) != "d" { exit 1 }' \
            "${listing_file}"
    fi
}

relative_archive_path_is_safe() {
    local candidate="$1"

    [[ "${candidate}" =~ ^[A-Za-z0-9._/-]+$ \
        && "${candidate}" != /* \
        && "${candidate}" != ../* \
        && "${candidate}" != */../* \
        && "${candidate}" != */.. \
        && "${candidate}" != *//* ]]
}

bundle_path="${1:-notifier/dist/com.threadhub.channel-email-notifier-0.1.0.tar.gz}"
mailer_image="${2:-threadhub/notifier-mailer:0.1.0}"
gitleaks_bin="${GITLEAKS_BIN:-}"
container_command="${CONTAINER_COMMAND:-docker}"
temporary_dir="$(mktemp -d)"
cleanup() {
    rm -rf "${temporary_dir}"
}
trap cleanup EXIT HUP INT TERM

[[ -n "${gitleaks_bin}" && -f "${gitleaks_bin}" && ! -L "${gitleaks_bin}" \
    && -x "${gitleaks_bin}" ]] || fail scanner
if ! "${gitleaks_bin}" version >"${temporary_dir}/scanner-version" 2>&1; then
    fail scanner
fi
[[ "$(tr -d '\r\n' <"${temporary_dir}/scanner-version")" == '8.30.1' ]] \
    || fail scanner

read -r -a container_parts <<<"${container_command}"
case "${#container_parts[@]}" in
    1)
        [[ "${container_parts[0]}" == docker || "${container_parts[0]}" == podman ]] \
            || fail image
        ;;
    4)
        [[ "${container_parts[0]}" == podman \
            && "${container_parts[1]}" == --remote \
            && "${container_parts[2]}" == --url \
            && "${container_parts[3]}" == unix:///* ]] || fail image
        ;;
    *) fail image ;;
esac
command -v "${container_parts[0]}" >/dev/null 2>&1 || fail image

[[ -f "${bundle_path}" && ! -L "${bundle_path}" ]] || fail bundle
if ! tar -tzf "${bundle_path}" >"${temporary_dir}/bundle-entries" 2>/dev/null \
    || ! tar -tvzf "${bundle_path}" >"${temporary_dir}/bundle-listing" 2>/dev/null; then
    fail bundle-archive
fi
archive_entries_are_safe "${temporary_dir}/bundle-entries" \
    || fail bundle-archive
archive_types_are_safe "${temporary_dir}/bundle-listing" \
    || fail bundle-archive
mkdir "${temporary_dir}/bundle"
tar -xzf "${bundle_path}" -C "${temporary_dir}/bundle" \
    --no-same-owner --no-same-permissions 2>/dev/null \
    || fail bundle-archive
if ! "${gitleaks_bin}" dir --redact --no-banner "${temporary_dir}/bundle" \
    >"${temporary_dir}/bundle-scan" 2>&1; then
    fail bundle-content
fi

if ! image_id="$("${container_parts[@]}" image inspect --format '{{.Id}}' \
    "${mailer_image}" 2>"${temporary_dir}/image-inspect-error")"; then
    fail image
fi
[[ "${image_id}" =~ ^(sha256:)?[a-f0-9]{64}$ ]] || fail image
if ! image_platform="$("${container_parts[@]}" image inspect \
    --format '{{.Os}}/{{.Architecture}}' "${mailer_image}" \
    2>"${temporary_dir}/image-platform-error")"; then
    fail image
fi
[[ "${image_platform}" == linux/amd64 ]] || fail image-platform

if ! "${container_parts[@]}" image inspect --format '{{json .Config.Env}}' \
    "${mailer_image}" >"${temporary_dir}/image-env.json" \
    2>"${temporary_dir}/image-env-error"; then
    fail image
fi
if ! jq -e '
    type == "array" and
    all(.[]; type == "string") and
    all(.[];
      if test("^(SMTP_[A-Z0-9_]+|NOTIFIER_HMAC_SECRET)(=|$)")
      then test("^(SMTP_[A-Z0-9_]+|NOTIFIER_HMAC_SECRET)=$")
      else true
      end)
  ' "${temporary_dir}/image-env.json" >/dev/null 2>&1; then
    fail image-metadata
fi
if ! "${container_parts[@]}" history --no-trunc --format '{{json .}}' \
    "${mailer_image}" >"${temporary_dir}/image-history.jsonl" \
    2>"${temporary_dir}/image-history-error"; then
    fail image
fi
if LC_ALL=C grep -E -q \
    "(SMTP_[A-Z0-9_]+|NOTIFIER_HMAC_SECRET)=([^[:space:]\"]+|\"[^\"]+\")" \
    "${temporary_dir}/image-history.jsonl"; then
    fail image-metadata
fi

if ! "${container_parts[@]}" image save --output "${temporary_dir}/image.tar" \
    "${mailer_image}" >"${temporary_dir}/image-save-output" \
    2>"${temporary_dir}/image-save-error"; then
    fail image
fi
[[ -f "${temporary_dir}/image.tar" && ! -L "${temporary_dir}/image.tar" ]] \
    || fail image-archive
if ! tar -tf "${temporary_dir}/image.tar" >"${temporary_dir}/image-entries" 2>/dev/null \
    || ! tar -tvf "${temporary_dir}/image.tar" >"${temporary_dir}/image-listing" 2>/dev/null; then
    fail image-archive
fi
archive_entries_are_safe "${temporary_dir}/image-entries" || fail image-archive
archive_types_are_safe "${temporary_dir}/image-listing" true || fail image-archive
mkdir "${temporary_dir}/image"
manifest_file="${temporary_dir}/image/manifest.json"
[[ "$(grep -Fxc 'manifest.json' "${temporary_dir}/image-entries")" == 1 ]] \
    || fail image-archive
tar -xOf "${temporary_dir}/image.tar" manifest.json >"${manifest_file}" 2>/dev/null \
    || fail image-archive
[[ -s "${manifest_file}" && ! -L "${manifest_file}" ]] || fail image-archive
if ! jq -e '
    type == "array" and length == 1 and
    (.[0].Config | type == "string")
  ' "${manifest_file}" >/dev/null 2>&1 \
    || ! jq -e '(.[0].Layers | type == "array") and (.[0].Layers | length > 0) and (.[0].Layers | all(.[]; type == "string"))' \
        "${manifest_file}" >/dev/null 2>&1; then
    fail image-archive
fi
config_path="$(jq -r '.[0].Config' "${manifest_file}")"
relative_archive_path_is_safe "${config_path}" || fail image-archive
[[ "$(grep -Fxc "${config_path}" "${temporary_dir}/image-entries")" == 1 ]] \
    || fail image-archive
mkdir -p "$(dirname "${temporary_dir}/image/${config_path}")"
tar -xOf "${temporary_dir}/image.tar" "${config_path}" \
    >"${temporary_dir}/image/${config_path}" 2>/dev/null || fail image-archive
[[ -s "${temporary_dir}/image/${config_path}" ]] || fail image-archive
if ! jq -e --arg id "${image_id#sha256:}" \
    '(.architecture == "amd64") and (.os == "linux")' \
    "${temporary_dir}/image/${config_path}" >/dev/null 2>&1; then
    fail image-platform
fi

mkdir "${temporary_dir}/layers"
layer_number=0
while IFS= read -r layer_path; do
    relative_archive_path_is_safe "${layer_path}" || fail image-archive
    layer_archive="${temporary_dir}/image/${layer_path}"
    [[ "$(grep -Fxc "${layer_path}" "${temporary_dir}/image-entries")" == 1 ]] \
        || fail image-archive
    mkdir -p "$(dirname "${layer_archive}")"
    tar -xOf "${temporary_dir}/image.tar" "${layer_path}" \
        >"${layer_archive}" 2>/dev/null || fail image-archive
    [[ -s "${layer_archive}" ]] || fail image-archive
    layer_number=$((layer_number + 1))
    layer_dir="${temporary_dir}/layers/${layer_number}"
    mkdir "${layer_dir}"
    if ! tar -tf "${layer_archive}" >"${temporary_dir}/layer-entries" 2>/dev/null \
        || ! tar -tvf "${layer_archive}" >"${temporary_dir}/layer-listing" 2>/dev/null; then
        fail image-archive
    fi
    archive_entries_are_safe "${temporary_dir}/layer-entries" || fail image-archive
    archive_types_are_safe "${temporary_dir}/layer-listing" || fail image-archive
    tar -xf "${layer_archive}" -C "${layer_dir}" \
        --no-same-owner --no-same-permissions 2>/dev/null \
        || fail image-archive
done < <(jq -r '.[0].Layers[]' "${manifest_file}")
[[ "${layer_number}" -gt 0 ]] || fail image-archive

mkdir "${temporary_dir}/image-scan"
cp "${temporary_dir}/image/${config_path}" "${temporary_dir}/image-scan/config.json"
cp "${manifest_file}" "${temporary_dir}/image-scan/manifest.json"
cp "${temporary_dir}/image-history.jsonl" "${temporary_dir}/image-scan/history.jsonl"
cp -R "${temporary_dir}/layers" "${temporary_dir}/image-scan/layers"
if ! "${gitleaks_bin}" dir --redact --no-banner "${temporary_dir}/image-scan" \
    >"${temporary_dir}/image-scan-output" 2>&1; then
    fail image-content
fi

printf 'ok - notifier artifact secret gate: bundle and image passed\n'
