#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
temporary_dir="$(mktemp -d)"

cleanup() {
    rm -rf "${temporary_dir}"
}
trap cleanup EXIT

fail() {
    printf 'not ok - %s\n' "$*" >&2
    exit 1
}

assert_false() {
    local description="$1"
    shift

    if "$@"; then
        fail "${description}"
    fi
}

operation_sequence_is_valid() {
    local document="$1"

    awk '
        {
            text = text "\n" $0
        }
        END {
            split("notifier-control.sh drain\034pending=0\034sending=0\034notifier-control.sh disable\034threadhub-mailer retry-failed\034threadhub-mailer cancel-failed", required, "\034")
            offset = 1
            for (index_value = 1; index_value <= length(required); index_value++) {
                position = index(substr(text, offset), required[index_value])
                if (position == 0) exit 1
                offset += position + length(required[index_value]) - 1
            }
        }
    ' "${document}"
}

nf_classification_is_complete() {
    local document="$1"
    local identifier

    for identifier in NF-FN-09 NF-FN-13 NF-SEC-03 NF-SEC-09 NF-REL-02 NF-REL-09 NF-INS-05 NF-IAM-07; do
        grep -Eq "^\\|[[:space:]]*${identifier}[[:space:]]*\\|[[:space:]]*(자동|수동|라이브 승인 필요)[[:space:]]*\\|" "${document}" \
            || return 1
    done
}

public_schema_is_fixed() {
    local document="$1"

    awk '
        $0 == "## notifier 공개 자동 증거" { in_section = 1; next }
        in_section && /^## / { exit }
        in_section && NF { count++ }
        END { exit !(in_section && count == 3) }
    ' "${document}"
}

operations_fixture="${temporary_dir}/operations.md"
test_plan_fixture="${temporary_dir}/test-plan.md"
public_results_fixture="${temporary_dir}/test-results.md"
cp "${DEPLOY_DIR}/docs/operations-checklist.md" "${operations_fixture}"
cp "${DEPLOY_DIR}/docs/test-plan.md" "${test_plan_fixture}"
cp "${DEPLOY_DIR}/docs/test-results-public.md" "${public_results_fixture}"

operation_sequence_is_valid "${operations_fixture}" \
    || fail 'real operational document does not satisfy the drain-zero-disable-retry-cancel contract'
nf_classification_is_complete "${test_plan_fixture}" \
    || fail 'real test plan does not classify every required notifier NF family'
public_schema_is_fixed "${public_results_fixture}" \
    || fail 'real public notifier evidence does not use the fixed schema'

sed -i.bak 's/pending=0/pending-zero/g' "${operations_fixture}"
rm -f "${operations_fixture}.bak"
assert_false 'missing zero-queue gate was accepted' operation_sequence_is_valid "${operations_fixture}"

cp "${DEPLOY_DIR}/docs/operations-checklist.md" "${operations_fixture}"
sed -i.bak 's/retry-failed/retry-placeholder/g; s/cancel-failed/retry-failed/g; s/retry-placeholder/cancel-failed/g' "${operations_fixture}"
rm -f "${operations_fixture}.bak"
assert_false 'reordered retry/cancel steps were accepted' operation_sequence_is_valid "${operations_fixture}"

sed -i.bak 's/NF-FN-13/NF-FN-missing/' "${test_plan_fixture}"
rm -f "${test_plan_fixture}.bak"
assert_false 'missing NF classification was accepted' nf_classification_is_complete "${test_plan_fixture}"

perl -0pi -e 's/(\| 15 \| pass \|\n)/$1| unexpected | schema | row |\n/' "${public_results_fixture}"
assert_false 'extra public evidence schema row was accepted' public_schema_is_fixed "${public_results_fixture}"

printf 'ok - notifier documentation contracts reject missing, reordered and extra schema fixtures\n'
