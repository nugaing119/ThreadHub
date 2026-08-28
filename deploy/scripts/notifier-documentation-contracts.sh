#!/usr/bin/env bash

# This library is sourced by validate.sh and notifier-documentation-test.sh.

notifier_docs_fail() {
    printf '%s\n' "[threadhub] ERROR: $*" >&2
    return 1
}

notifier_docs_require_file() {
    [[ -f "$1" ]] || notifier_docs_fail "Notifier documentation file is missing: $1"
}

notifier_docs_require_link() {
    local document="$1"
    local link="$2"

    grep -F -- "${link}" "${document}" >/dev/null \
        || notifier_docs_fail "Notifier documentation link is missing: ${document} -> ${link}"
}

notifier_docs_require_order() {
    local document="$1"
    local description="$2"
    shift 2
    local terms=()
    local term
    local serialized
    local original_ifs

    for term in "$@"; do
        terms+=("${term}")
    done
    original_ifs="${IFS}"
    IFS=$'\034'
    serialized="${terms[*]}"
    IFS="${original_ifs}"
    awk -v terms="${serialized}" '
        { text = text "\n" $0 }
        END {
            split(terms, required, "\034")
            offset = 1
            for (item = 1; item <= length(required); item++) {
                position = index(substr(text, offset), required[item])
                if (position == 0) exit 1
                offset += position + length(required[item]) - 1
            }
        }
    ' "${document}" \
        || notifier_docs_fail "Notifier documentation has missing or reordered ${description}: ${document}"
}

notifier_docs_require_section_order() {
    local document="$1"
    local heading="$2"
    local description="$3"
    shift 3
    local terms=()
    local term
    local serialized
    local original_ifs

    for term in "$@"; do
        terms+=("${term}")
    done
    original_ifs="${IFS}"
    IFS=$'\034'
    serialized="${terms[*]}"
    IFS="${original_ifs}"
    awk -v heading="${heading}" -v terms="${serialized}" '
        $0 == heading { in_section = 1; next }
        in_section && (/^## / || /^### /) { exit }
        in_section { text = text "\n" $0 }
        END {
            if (!in_section) exit 1
            split(terms, required, "\034")
            offset = 1
            for (item = 1; item <= length(required); item++) {
                position = index(substr(text, offset), required[item])
                if (position == 0) exit 1
                offset += position + length(required[item]) - 1
            }
        }
    ' "${document}" \
        || notifier_docs_fail "Notifier documentation has missing or reordered ${description}: ${document}"
}

notifier_docs_validate_public_schema() {
    local document="$1"

    awk '
        $0 == "## notifier 공개 자동 증거" { in_section = 1; next }
        in_section && /^## / { exit }
        in_section && NF { lines[++count] = $0 }
        END {
            header = "| test date | source commit | Mattermost image digest | PostgreSQL image digest | notifier version | plugin bundle SHA-256 | NF scenario count | result |"
            separator = "| --- | --- | --- | --- | --- | --- | ---: | --- |"
            if (!in_section || count != 3 || lines[1] != header || lines[2] != separator) exit 1
            fields = split(lines[3], row, "|")
            if (fields != 10 || row[2] !~ /^ [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] $/ ||
                row[3] !~ /^ `[a-f0-9]+` $/ || (length(row[3]) != 44 && length(row[3]) != 68) ||
                row[4] !~ /^ `sha256:[a-f0-9]+` $/ || length(row[4]) != 75 ||
                row[5] !~ /^ `sha256:[a-f0-9]+` $/ || length(row[5]) != 75 ||
                row[6] !~ /^ `[0-9]+\.[0-9]+\.[0-9]+` $/ ||
                row[7] !~ /^ `[a-f0-9]+` $/ || length(row[7]) != 68 ||
                row[8] !~ /^ [0-9]+ $/ || row[9] !~ /^ (pass|fail) $/) exit 1
        }
    ' "${document}" \
        || notifier_docs_fail "Notifier public evidence must use only the approved fixed schema"
}

notifier_docs_validate_nf_matrix() {
    local document="$1"
    local identifier
    local row

    for identifier in \
        NF-FN-01 NF-FN-02 NF-FN-03 NF-FN-04 NF-FN-05 NF-FN-06 NF-FN-07 \
        NF-FN-08 NF-FN-09 NF-FN-10 NF-FN-11 NF-FN-12 NF-FN-13 \
        NF-SEC-01 NF-SEC-02 NF-SEC-03 NF-SEC-04 NF-SEC-05 NF-SEC-06 \
        NF-SEC-07 NF-SEC-08 NF-SEC-09 \
        NF-REL-01 NF-REL-02 NF-REL-03 NF-REL-04 NF-REL-05 NF-REL-06 \
        NF-REL-07 NF-REL-08 NF-REL-09 \
        NF-INS-01 NF-INS-02 NF-INS-03 NF-INS-04 NF-INS-05 \
        NF-IAM-01 NF-IAM-02 NF-IAM-03 NF-IAM-04 NF-IAM-05 NF-IAM-06 NF-IAM-07; do
        row="$(grep -m1 -E "^\\|[[:space:]]*${identifier}[[:space:]]*\\|" "${document}" || true)"
        [[ -n "${row}" && ( "${row}" == *'| 자동 |'* || "${row}" == *'| 수동 |'* || "${row}" == *'| 라이브 승인 필요 |'* ) ]] \
            || {
                notifier_docs_fail "Notifier test plan must classify ${identifier} individually"
                return 1
            }
    done
}

validate_notifier_documentation_contracts() {
    local repository_root="$1"
    local deploy_dir="${repository_root}/deploy"
    local documents=(
        "${repository_root}/README.md"
        "${repository_root}/SECURITY.md"
        "${deploy_dir}/README.md"
        "${deploy_dir}/docs/quick-install.md"
        "${deploy_dir}/docs/setup.md"
        "${deploy_dir}/docs/admin-guide.md"
        "${deploy_dir}/docs/oci-email-delivery.md"
        "${deploy_dir}/docs/operations-checklist.md"
        "${deploy_dir}/docs/project-close.md"
        "${deploy_dir}/docs/test-plan.md"
        "${deploy_dir}/docs/test-results-public.md"
    )
    local document

    for document in "${documents[@]}"; do
        notifier_docs_require_file "${document}" || return 1
    done
    notifier_docs_require_link "${repository_root}/README.md" './deploy/docs/quick-install.md' || return 1
    notifier_docs_require_link "${deploy_dir}/docs/operations-checklist.md" './project-close.md' || return 1
    notifier_docs_require_link "${deploy_dir}/docs/project-close.md" './oci-email-delivery.md' || return 1
    notifier_docs_require_link "${deploy_dir}/docs/test-plan.md" './test-results-public.md' || return 1

    notifier_docs_require_order "${deploy_dir}/docs/quick-install.md" 'quick-install safety sequence' \
        'fresh Ubuntu 24.04 AMD64 VM' './deploy/scripts/validate.sh' \
        '프로젝트 DNS와 Email Delivery' '숨김 SMTP 입력' 'build/install' \
        '일회성 SMTP acceptance' 'activation cutoff' '[READY]' 'inbox/link/SPF/DKIM' || return 1

    notifier_docs_require_section_order "${deploy_dir}/docs/operations-checklist.md" \
        '### 종료·credential 교체 전 queue 처리' 'close delivery sequence' \
        'notifier-control.sh drain' 'threadhub-mailer retry-failed' 'pending=0' 'sending=0' \
        'threadhub-mailer cancel-failed' 'failed=0' 'notifier-control.sh disable' 'delivery_enabled=false' || return 1
    notifier_docs_require_section_order "${deploy_dir}/docs/operations-checklist.md" \
        '### SMTP Credential 교체' 'SMTP credential rotation sequence' \
        'notifier-control.sh drain' 'threadhub-mailer retry-failed' 'pending=0' 'sending=0' \
        'threadhub-mailer cancel-failed' 'failed=0' 'notifier-control.sh disable' 'deploy/.env' \
        'deploy/scripts/deploy.sh' 'notifier-smtp-test.sh' 'notifier-control.sh activate --from-env' \
        'notifier-status.sh' || return 1
    notifier_docs_require_section_order "${deploy_dir}/docs/project-close.md" \
        '### notifier 종료 gate' 'project-close delivery gate' \
        'notifier-control.sh drain' 'threadhub-mailer retry-failed' 'pending=0' 'sending=0' \
        'threadhub-mailer cancel-failed' 'failed=0' 'notifier-control.sh disable' 'project close is blocked' \
        'recipient addresses' 'securely removed' || return 1
    notifier_docs_require_section_order "${deploy_dir}/docs/oci-email-delivery.md" \
        '## 10. SMTP Credential 교체' 'OCI SMTP credential rotation sequence' \
        'notifier-control.sh drain' 'threadhub-mailer retry-failed' 'pending=0' 'sending=0' \
        'threadhub-mailer cancel-failed' 'failed=0' 'notifier-control.sh disable' 'deploy/.env' \
        'deploy/scripts/deploy.sh' 'notifier-smtp-test.sh' 'notifier-control.sh activate --from-env' \
        'notifier-status.sh' '이전 credential을 삭제' || return 1
    notifier_docs_validate_nf_matrix "${deploy_dir}/docs/test-plan.md" || return 1
    notifier_docs_validate_public_schema "${deploy_dir}/docs/test-results-public.md" || return 1
}
