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

notifier_docs_require_regex() {
    local document="$1"
    local expression="$2"
    local description="$3"

    grep -Eiq -- "${expression}" "${document}" \
        || notifier_docs_fail "Notifier documentation is missing ${description}: ${document}"
}

notifier_docs_require_terms() {
    local document="$1"
    local description="$2"
    shift 2
    local term

    for term in "$@"; do
        grep -Fiq -- "${term}" "${document}" \
            || {
                notifier_docs_fail "Notifier documentation is missing ${description}: ${document}"
                return 1
            }
    done
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
        NF-IAM-01 NF-IAM-02 NF-IAM-03 NF-IAM-04 NF-IAM-05 NF-IAM-06 NF-IAM-07 \
        NF-ADOPT-01 NF-ADOPT-02 NF-ADOPT-03 NF-ADOPT-04 NF-ADOPT-05 \
        NF-ADOPT-06 NF-ADOPT-07 NF-ADOPT-08 NF-ADOPT-09 NF-ADOPT-10; do
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
    local architecture="${deploy_dir}/docs/notifier-architecture.md"
    local prd="${repository_root}/docs/threadhub-prd-v4.3-final.md"
    local documents=(
        "${repository_root}/README.md"
        "${repository_root}/SECURITY.md"
        "${deploy_dir}/README.md"
        "${deploy_dir}/docs/quick-install.md"
        "${deploy_dir}/docs/existing-mattermost-notifier.md"
        "${deploy_dir}/docs/setup.md"
        "${deploy_dir}/docs/admin-guide.md"
        "${deploy_dir}/docs/oci-email-delivery.md"
        "${deploy_dir}/docs/operations-checklist.md"
        "${deploy_dir}/docs/project-close.md"
        "${deploy_dir}/docs/test-plan.md"
        "${deploy_dir}/docs/test-results-public.md"
        "${architecture}"
        "${prd}"
    )
    local document

    for document in "${documents[@]}"; do
        notifier_docs_require_file "${document}" || return 1
    done
    notifier_docs_require_link "${repository_root}/README.md" './deploy/docs/quick-install.md' || return 1
    notifier_docs_require_link "${repository_root}/README.md" './deploy/docs/existing-mattermost-notifier.md' || return 1
    notifier_docs_require_link "${repository_root}/README.md" './deploy/docs/notifier-architecture.md' || return 1
    notifier_docs_require_link "${deploy_dir}/README.md" './docs/quick-install.md' || return 1
    notifier_docs_require_link "${deploy_dir}/README.md" './docs/existing-mattermost-notifier.md' || return 1
    notifier_docs_require_link "${deploy_dir}/README.md" './docs/notifier-architecture.md' || return 1
    notifier_docs_require_link "${deploy_dir}/docs/quick-install.md" './oci-email-delivery.md' || return 1
    notifier_docs_require_link "${deploy_dir}/docs/quick-install.md" './admin-guide.md' || return 1
    notifier_docs_require_link "${deploy_dir}/docs/quick-install.md" './existing-mattermost-notifier.md' || return 1
    notifier_docs_require_link "${deploy_dir}/docs/admin-guide.md" './existing-mattermost-notifier.md' || return 1
    for document in \
        "${deploy_dir}/docs/quick-install.md" \
        "${deploy_dir}/docs/existing-mattermost-notifier.md" \
        "${deploy_dir}/docs/setup.md" \
        "${deploy_dir}/docs/admin-guide.md"; do
        notifier_docs_require_link "${document}" './notifier-architecture.md' || return 1
    done
    notifier_docs_require_link "${deploy_dir}/docs/setup.md" './oci-email-delivery.md' || return 1
    notifier_docs_require_link "${deploy_dir}/docs/admin-guide.md" './operations-checklist.md' || return 1
    notifier_docs_require_link "${deploy_dir}/docs/operations-checklist.md" './project-close.md' || return 1
    notifier_docs_require_link "${deploy_dir}/docs/project-close.md" './oci-email-delivery.md' || return 1
    notifier_docs_require_link "${deploy_dir}/docs/test-plan.md" './test-results-public.md' || return 1

    notifier_docs_require_section_order "${deploy_dir}/docs/quick-install.md" \
        '## 1. 설치 순서와 준비해야 할 값' 'quick-install safety sequence' \
        'fresh Ubuntu 24.04 AMD64 VM' './deploy/scripts/validate.sh' \
        '프로젝트 DNS와 Email Delivery' '숨김 SMTP 입력' 'build/install' \
        '일회성 SMTP acceptance' 'activation cutoff' '[READY]' 'inbox/link/SPF/DKIM' || return 1

    notifier_docs_require_section_order "${deploy_dir}/docs/existing-mattermost-notifier.md" \
        '## 적용 순서' 'existing adoption safety sequence' \
        'existing-notifier-preflight.sh' 'disabled' 'existing-notifier-setup.sh' \
        'SMTP acceptance' 'allowlist' 'manual acceptance' 'explicit all_channels approval' || return 1
    # Backticks below are required literal Markdown delimiters.
    # shellcheck disable=SC2016
    notifier_docs_require_terms "${deploy_dir}/docs/existing-mattermost-notifier.md" \
        'existing adoption support and impact boundary' \
        'Mattermost Team Edition 11.7.7' 'Ubuntu 24.04 AMD64' 'single-node Compose' \
        'bind mount' '30–60초' 'base Compose' 'base environment' 'exit code 20' \
        'queue data' 'rollback' 'public/private root and thread' \
        '`existing-notifier-setup.sh` → `SMTP acceptance` → `allowlist`' || return 1
    notifier_docs_require_terms "${repository_root}/AGENTS.md" \
        'existing Mattermost fail-closed agent contract' \
        'existing-notifier-preflight.sh' 'do not modify the base Compose file' \
        'exit code 20' 'never enable all_channels without explicit approval' || return 1
    notifier_docs_require_terms "${deploy_dir}/docs/quick-install.md" \
        'fresh and existing adoption separation' \
        'fresh installation only' 'existing-mattermost-notifier.md' || return 1

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
        'threadhub-mailer cancel-failed' 'failed=0' 'notifier-control.sh disable' 'delivery_enabled=false' \
        'ANY of pending, sending, or failed is nonzero' 'project close is blocked' \
        'recipient addresses' 'securely removed' || return 1
    notifier_docs_require_section_order "${deploy_dir}/docs/oci-email-delivery.md" \
        '## 10. SMTP Credential 교체' 'OCI SMTP credential rotation sequence' \
        'notifier-control.sh drain' 'threadhub-mailer retry-failed' 'pending=0' 'sending=0' \
        'threadhub-mailer cancel-failed' 'failed=0' 'notifier-control.sh disable' 'deploy/.env' \
        'deploy/scripts/deploy.sh' 'notifier-smtp-test.sh' 'notifier-control.sh activate --from-env' \
        'notifier-status.sh' '이전 credential을 삭제' || return 1
    for document in \
        "${deploy_dir}/docs/admin-guide.md" \
        "${deploy_dir}/docs/operations-checklist.md" \
        "${deploy_dir}/docs/project-close.md" \
        "${deploy_dir}/docs/oci-email-delivery.md"; do
        notifier_docs_require_terms "${document}" \
            'cancel-failed both-state aggregate contract' \
            'cancel-failed' 'failed_permanent' 'failed_exhausted' 'pending' 'sending' 'failed=0' || return 1
    done
    notifier_docs_validate_nf_matrix "${deploy_dir}/docs/test-plan.md" || return 1
    notifier_docs_validate_public_schema "${deploy_dir}/docs/test-results-public.md" || return 1

    local notifier_script
    for notifier_script in \
        './deploy/scripts/build-notifier.sh' \
        './deploy/scripts/configure-notifier.sh' \
        './deploy/scripts/install-notifier-plugin.sh' \
        './deploy/scripts/notifier-control.sh' \
        './deploy/scripts/notifier-smtp-test.sh' \
        './deploy/scripts/notifier-status.sh' \
        './deploy/scripts/install-status.sh'; do
        grep -R -F -- "${notifier_script}" \
            "${repository_root}/README.md" "${deploy_dir}/README.md" "${deploy_dir}/docs" >/dev/null \
            || {
                notifier_docs_fail "Notifier documentation must name ${notifier_script}"
                return 1
            }
    done

    notifier_docs_require_regex "${deploy_dir}/docs/oci-email-delivery.md" \
        'project-specific[[:space:]]+IAM[[:space:]]+user/group/SMTP[[:space:]]+Credential/exact[[:space:]]+Approved[[:space:]]+Sender' \
        'project-specific IAM user/group/SMTP Credential/exact Approved Sender isolation' || return 1
    local policy_line
    for policy_line in \
        "Allow group '<identity-domain>'/'<project-smtp-group>'" \
        'to use approved-senders' \
        'in compartment <project-compartment>' \
        "where target.approved-sender.id = '<project-approved-sender-ocid>'"; do
        notifier_docs_require_terms "${deploy_dir}/docs/oci-email-delivery.md" \
            "OCI isolation policy line ${policy_line}" "${policy_line}" || return 1
    done
    notifier_docs_require_regex "${deploy_dir}/docs/oci-email-delivery.md" \
        'same[[:space:]]+sending[[:space:]]+domain[[:space:]]+and[[:space:]]+region' \
        'shared Email Domain/DKIM/SPF same-domain-and-region limit' || return 1
    notifier_docs_require_regex "${deploy_dir}/docs/oci-email-delivery.md" \
        'additive[[:space:]]+IAM[[:space:]]+policy[[:space:]]+audit' \
        'additive IAM policy audit' || return 1
    notifier_docs_require_regex "${deploy_dir}/docs/oci-email-delivery.md" \
        'A/A[[:space:]]+success,[[:space:]]+A/B[[:space:]]+deny,[[:space:]]+B/B[[:space:]]+success,[[:space:]]+B/A[[:space:]]+deny' \
        'cross-send IAM acceptance matrix' || return 1
    notifier_docs_require_terms "${deploy_dir}/docs/oci-email-delivery.md" \
        'tenancy-and-region Email Delivery cost recheck' \
        'tenancy and region total sending volume' 'before deployment' 'OCI Email Delivery cost' || return 1
    notifier_docs_require_regex "${deploy_dir}/docs/quick-install.md" \
        'actual[[:space:]]+inbox/link/SPF/DKIM[[:space:]]+remains[[:space:]]+manual' \
        'manual inbox/link/SPF/DKIM acceptance boundary' || return 1
    notifier_docs_require_terms "${deploy_dir}/docs/admin-guide.md" \
        'at-least-once duplicate caveat' 'at-least-once' 'duplicate' 'exactly-once' || return 1
    notifier_docs_require_terms "${deploy_dir}/docs/operations-checklist.md" \
        'immediate disable and 24h/7d privacy retention' 'immediate disable' '24h/7d privacy retention' || return 1
    notifier_docs_require_terms "${deploy_dir}/docs/admin-guide.md" \
        'Team Edition plugin and license boundary' 'Mattermost Team Edition' '공개 플러그인 API' \
        '유료 기능' '라이선스 검사를 우회하지 않습니다' \
        '../../notifier/THIRD_PARTY_NOTICES.md' || return 1
    notifier_docs_require_terms "${architecture}" \
        'plugin and Mailer architecture boundary' \
        'MessageHasBeenPosted' 'plugin KV outbox' 'HMAC' 'SQLite' 'STARTTLS' \
        'Mattermost 본체와 Mailer에는 같은' '커스텀 플러그인 구현은 SMTP 자격 증명을 읽거나' \
        'SMTP 또는 Mailer가 일시 중단돼도 Mattermost의 글 작성은 계속 성공' \
        'NOTIFIER_CONTENT_MODE=project_team_channel' 'NOTIFIER_CONTENT_MODE=generic' \
        '비공개 Team·채널 표시명도 OCI Email Delivery' \
        '메시지 본문, 작성자명, 첨부파일명' 'MM_EMAILSETTINGS_SENDEMAILNOTIFICATIONS=false' \
        'Persistent Notification' '라이선스 검사를 활성화·우회하지 않는다' \
        '../../notifier/THIRD_PARTY_NOTICES.md' || return 1
    notifier_docs_require_terms "${prd}" \
        'notifier PRD baseline' 'v4.3 Final' 'G-13' 'FR-NOT-001' 'FR-NOT-012' \
        'AC-NOT-001' 'AC-NOT-010' 'notifier-architecture.md' || return 1
    notifier_docs_require_terms "${deploy_dir}/docs/setup.md" \
        'safe project DNS A-record isolation' 'DNS A record' 'unrelated RRsets' 'two independent VM' || return 1
    notifier_docs_require_regex "${deploy_dir}/docs/oci-email-delivery.md" \
        'no[[:space:]]+unauthorized[[:space:]]+OCI[[:space:]]+automation' \
        'no unauthorized OCI automation' || return 1

    if ! declare -F validate_backup_documentation_contracts >/dev/null 2>&1; then
        # shellcheck source=backup-documentation-contracts.sh
        # shellcheck disable=SC1091
        source "${deploy_dir}/scripts/backup-documentation-contracts.sh"
    fi
    validate_backup_documentation_contracts "${repository_root}" || return 1
}
