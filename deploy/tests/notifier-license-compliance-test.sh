#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd -P)"
NOTIFIER_ROOT="${REPOSITORY_ROOT}/notifier"
INVENTORY="${NOTIFIER_ROOT}/third_party/modules.tsv"

fail() {
    printf 'not ok - notifier license compliance: %s\n' "$1" >&2
    exit 1
}

for required_file in \
    "${REPOSITORY_ROOT}/LICENSE" \
    "${NOTIFIER_ROOT}/LICENSE" \
    "${NOTIFIER_ROOT}/THIRD_PARTY_NOTICES.md" \
    "${NOTIFIER_ROOT}/third_party/README.md" \
    "${INVENTORY}"; do
    [[ -f "${required_file}" && ! -L "${required_file}" && -s "${required_file}" ]] \
        || fail "missing required notice: ${required_file#"${REPOSITORY_ROOT}/"}"
done

cmp -s "${REPOSITORY_ROOT}/LICENSE" "${NOTIFIER_ROOT}/LICENSE" \
    || fail 'notifier/LICENSE must be an exact copy of the repository MIT license'

temporary_dir="$(mktemp -d)"
cleanup() {
    rm -rf "${temporary_dir}"
}
trap cleanup EXIT HUP INT TERM

awk '
    $1 == "require" && $2 == "(" { inside = 1; next }
    inside && $1 == ")" { inside = 0; next }
    inside && NF >= 2 && $1 !~ /^\/\// { print $1 "\t" $2 }
    $1 == "require" && $2 != "(" && NF >= 3 { print $2 "\t" $3 }
' "${NOTIFIER_ROOT}/go.mod" | LC_ALL=C sort -u > "${temporary_dir}/go-modules"

awk -F '\t' '
    NR == 1 {
        if ($0 != "module\tversion\tlicense\tlicense_file\tsource") exit 1
        next
    }
    NF != 5 { exit 1 }
    $1 !~ /^[A-Za-z0-9._~+\/-]+$/ { exit 1 }
    $2 !~ /^v[0-9]/ { exit 1 }
    $3 !~ /^(Apache-2.0|BSD-2-Clause|BSD-3-Clause|ISC|MIT|MPL-2.0)$/ { exit 1 }
    $4 !~ /^third_party\/licenses\/[A-Za-z0-9._~+\/-]+$/ { exit 1 }
    $4 ~ /(^|\/)\.\.($|\/)/ { exit 1 }
    $5 !~ /^https:\/\// { exit 1 }
    {
        key = $1 "\t" $2
        if (seen[key]++) exit 1
        print key
    }
' "${INVENTORY}" | LC_ALL=C sort -u > "${temporary_dir}/notice-modules" \
    || fail 'third-party module inventory is malformed'

diff -u "${temporary_dir}/go-modules" "${temporary_dir}/notice-modules" >/dev/null \
    || fail 'go.mod and the third-party module inventory differ'

tail -n +2 "${INVENTORY}" | while IFS=$'\t' read -r module version license license_file source; do
    [[ -n "${module}" && -n "${version}" && -n "${license}" \
        && -n "${license_file}" && -n "${source}" ]] \
        || fail 'third-party module inventory contains an empty field'
    notice_path="${NOTIFIER_ROOT}/${license_file}"
    [[ -f "${notice_path}" && ! -L "${notice_path}" && -s "${notice_path}" ]] \
        || fail "missing dependency license for ${module}@${version}"
done

grep -F 'Plugins are fully supported in both Team Edition and Enterprise Edition' \
    "${NOTIFIER_ROOT}/THIRD_PARTY_NOTICES.md" >/dev/null \
    || fail 'Team Edition plugin basis is not documented'
grep -F '유료 기능을 활성화하거나 라이선스 검사를 우회하지 않습니다' \
    "${NOTIFIER_ROOT}/THIRD_PARTY_NOTICES.md" >/dev/null \
    || fail 'paid-feature non-circumvention rule is not documented'
grep -F '법률 자문을 대신하지 않습니다' \
    "${NOTIFIER_ROOT}/THIRD_PARTY_NOTICES.md" >/dev/null \
    || fail 'legal-review limitation is not documented'
grep -F './notifier/THIRD_PARTY_NOTICES.md' "${REPOSITORY_ROOT}/README.md" >/dev/null \
    || fail 'top-level README does not link the notifier notices'
grep -F '../../notifier/THIRD_PARTY_NOTICES.md' \
    "${REPOSITORY_ROOT}/deploy/docs/admin-guide.md" >/dev/null \
    || fail 'admin guide does not link the notifier notices'

if grep -R -n -E 'server/enterprise|GetLicense[[:space:]]*\(' \
    --include='*.go' "${NOTIFIER_ROOT}/plugin" "${NOTIFIER_ROOT}/mailer"; then
    fail 'enterprise-only package or license-bypass hook found in notifier source'
fi

for packaging_contract in \
    '/out/plugin/com.threadhub.channel-email-notifier/third_party' \
    '/out/mailer-rootfs/licenses/threadhub-notifier/third_party'; do
    grep -F "${packaging_contract}" "${NOTIFIER_ROOT}/Dockerfile" >/dev/null \
        || fail "notifier artifact omits license payload: ${packaging_contract}"
done

printf 'ok - notifier license notices cover every declared Go module\n'
