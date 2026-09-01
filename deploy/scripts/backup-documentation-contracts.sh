#!/usr/bin/env bash

# This library is sourced by validate.sh and backup-documentation-test.sh.

if ! declare -F notifier_docs_require_file >/dev/null 2>&1; then
    # shellcheck source=notifier-documentation-contracts.sh
    # shellcheck disable=SC1091
    source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/notifier-documentation-contracts.sh"
fi

backup_docs_validate_public_schema() {
    local document="$1"

    awk '
        $0 == "## backup·restore 공개 자동 증거" { in_section = 1; next }
        in_section && /^## / { exit }
        in_section && NF { lines[++count] = $0 }
        END {
            header = "| test date | source commit | Mattermost image digest | PostgreSQL image digest | notifier version | backup scenario count | result |"
            separator = "| --- | --- | --- | --- | --- | ---: | --- |"
            if (!in_section || count < 2 || count > 3 || lines[1] != header || lines[2] != separator) exit 1
            if (count == 2) exit 0
            fields = split(lines[3], row, "|")
            if (fields != 9 || row[2] !~ /^ [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] $/ ||
                row[3] !~ /^ `[a-f0-9]+` $/ || (length(row[3]) != 44 && length(row[3]) != 68) ||
                row[4] !~ /^ `sha256:[a-f0-9]+` $/ || length(row[4]) != 75 ||
                row[5] !~ /^ `sha256:[a-f0-9]+` $/ || length(row[5]) != 75 ||
                row[6] !~ /^ `[0-9]+\.[0-9]+\.[0-9]+` $/ ||
                row[7] !~ /^ [0-9]+ $/ || row[8] !~ /^ (pass|fail) $/) exit 1
        }
    ' "${document}" \
        || notifier_docs_fail "Backup public evidence must use only the approved fixed schema"
}

validate_backup_documentation_contracts() {
    local repository_root="$1"
    local deploy_dir="${repository_root}/deploy"
    local guide="${deploy_dir}/docs/backup-restore.md"
    local prd="${repository_root}/docs/threadhub-prd-v4.2-final.md"
    local documents=(
        "${repository_root}/README.md"
        "${repository_root}/AGENTS.md"
        "${repository_root}/SECURITY.md"
        "${deploy_dir}/README.md"
        "${deploy_dir}/docs/quick-install.md"
        "${deploy_dir}/docs/setup.md"
        "${deploy_dir}/docs/admin-guide.md"
        "${deploy_dir}/docs/operations-checklist.md"
        "${deploy_dir}/docs/project-close.md"
        "${deploy_dir}/docs/oci-provisioning.md"
        "${deploy_dir}/docs/test-plan.md"
        "${deploy_dir}/docs/test-results-public.md"
        "${guide}"
        "${prd}"
    )
    local document

    for document in "${documents[@]}"; do
        notifier_docs_require_file "${document}" || return 1
    done

    notifier_docs_require_terms "${guide}" 'backup service objectives and exclusions' \
        'RPO' '24시간' 'RTO' '4시간' '5분' 'HA' 'PITR' '리전 간 복제' || return 1
    notifier_docs_require_terms "${guide}" 'exact OCI least-privilege boundary' \
        'ap-singapore-1' 'Public Access' 'AES-256' 'Instance Principal' \
        'OBJECT_CREATE' 'OBJECT_INSPECT' 'OBJECT_READ' 'OBJECT_DELETE' \
        'explicit user authorization' || return 1
    notifier_docs_require_terms "${guide}" 'retention and lifecycle boundary' \
        'daily/' '7일' 'weekly/' '28일' 'Lifecycle service authorization' || return 1
    # Backticks below are required literal Markdown delimiters.
    # shellcheck disable=SC2016
    notifier_docs_require_terms "${guide}" 'safe restore and notifier quarantine' \
        'new or empty `/srv/threadhub`' 'queue quarantine' 'enabled=false' \
        'delivery_enabled=false' || return 1
    notifier_docs_require_section_order "${guide}" \
        '## 5. 설정 및 비활성 등록' 'backup registration sequence' \
        'configure-backup.sh' 'install-backup.sh --register' 'timer remains disabled' || return 1
    notifier_docs_require_section_order "${guide}" \
        '## 8. 증거 검토 후 타이머 활성화' 'acceptance-gated activation' \
        '최초 원격 검증 성공' '폐기 가능한 VM 복구 증거' \
        'install-backup.sh --enable-after-acceptance' 'ENABLE BACKUP TIMER' || return 1

    local configure_line register_line manual_line restore_line activate_line
    configure_line="$(grep -n -m1 'configure-backup\.sh' "${guide}" | cut -d: -f1)"
    register_line="$(grep -n -m1 'install-backup\.sh --register' "${guide}" | cut -d: -f1)"
    manual_line="$(grep -n -m1 'sudo ./deploy/scripts/backup\.sh$' "${guide}" | cut -d: -f1)"
    restore_line="$(grep -n -m1 'restore\.sh <BACKUP_ID>' "${guide}" | cut -d: -f1)"
    activate_line="$(grep -n -m1 'install-backup\.sh --enable-after-acceptance' "${guide}" | cut -d: -f1)"
    [[ -n "${configure_line}" && -n "${register_line}" && -n "${manual_line}" && \
       -n "${restore_line}" && -n "${activate_line}" && \
       "${configure_line}" -lt "${register_line}" && \
       "${register_line}" -lt "${manual_line}" && \
       "${manual_line}" -lt "${restore_line}" && \
       "${restore_line}" -lt "${activate_line}" ]] \
        || notifier_docs_fail "Backup documentation activates the timer before backup and restore acceptance" \
        || return 1

    notifier_docs_require_link "${repository_root}/README.md" \
        './deploy/docs/backup-restore.md' || return 1
    notifier_docs_require_link "${deploy_dir}/README.md" \
        './docs/backup-restore.md' || return 1
    for document in \
        "${deploy_dir}/docs/quick-install.md" \
        "${deploy_dir}/docs/setup.md" \
        "${deploy_dir}/docs/admin-guide.md" \
        "${deploy_dir}/docs/operations-checklist.md" \
        "${deploy_dir}/docs/project-close.md" \
        "${deploy_dir}/docs/oci-provisioning.md"; do
        notifier_docs_require_link "${document}" './backup-restore.md' || return 1
    done

    # Backticks below are required literal Markdown delimiters.
    # shellcheck disable=SC2016
    notifier_docs_require_terms "${repository_root}/AGENTS.md" \
        'backup agent safety contract' 'explicit user authorization' \
        'timer remains disabled' 'new or empty `/srv/threadhub`' 'queue quarantine' || return 1
    notifier_docs_require_terms "${repository_root}/SECURITY.md" \
        'backup privacy boundary' 'backup manifest' 'backup status' 'diagnostic' \
        'Object Storage' 'public' || return 1
    notifier_docs_require_terms "${deploy_dir}/docs/quick-install.md" \
        'base readiness and backup readiness separation' '[READY]' \
        'timer remains disabled' 'backup-restore.md' || return 1
    notifier_docs_require_terms "${deploy_dir}/docs/operations-checklist.md" \
        'backup daily operations' '24시간' '정확히 5개' 'staging' \
        'failure email' 'resume-upload' || return 1
    notifier_docs_require_section_order "${deploy_dir}/docs/project-close.md" \
        '### 백업 보존·삭제 gate' 'backup close sequence' \
        'notifier 종료 gate' '마지막 수동 백업' '원격 검증' \
        'explicit user authorization' 'Object Storage' || return 1
    notifier_docs_require_terms "${deploy_dir}/docs/test-plan.md" \
        'backup test families' 'BK-UNIT-' 'BK-INT-' 'BK-LIVE-' || return 1
    backup_docs_validate_public_schema "${deploy_dir}/docs/test-results-public.md" || return 1
    notifier_docs_require_terms "${prd}" 'PRD backup baseline' \
        'v4.2 Final' 'G-12' 'RPO 24시간' 'RTO 4시간' \
        'OCI Object Storage' '복구시험' 'R-10' || return 1
}
