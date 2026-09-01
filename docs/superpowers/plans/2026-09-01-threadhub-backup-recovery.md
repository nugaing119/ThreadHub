# ThreadHub Backup and Recovery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add fail-closed, application-consistent daily ThreadHub backups to a per-project private OCI Object Storage bucket and a guarded restore path for a fresh VM.

**Architecture:** Root-owned host scripts stop only the two application writers, create one checksummed logical backup set, restart and verify service before upload, then use OCI CLI Instance Principal authentication for exact-bucket storage. Restore downloads and validates the set before touching an empty `/srv/threadhub`, rebuilds the pinned notifier, restores PostgreSQL and attachments, and starts with the old notifier queue quarantined and delivery disabled.

**Tech Stack:** Bash 5, Docker Engine 29.x, Docker Compose Plugin, Mattermost Team Edition 11.7.7, PostgreSQL 18.4 (`pg_dump`/`pg_restore`), jq, GNU tar + zstd, OCI CLI 3.90.3, systemd, Go 1.25.14 for the Mailer admin-alert command, GitHub Actions on Ubuntu 24.04 AMD64.

**Spec:** `docs/superpowers/specs/2026-09-01-threadhub-backup-recovery-design.md`

## Global Constraints

- The supported target is Ubuntu 24.04 AMD64 with 2 OCPU, 16GB RAM, and at least 50GB boot storage.
- The only supported runtime data root is `/srv/threadhub`; never attach new credentials to an existing unrelated root.
- Backup storage is a per-project private bucket in `ap-singapore-1` with daily retention 7 days and weekly Sunday retention 28 days.
- RPO is 24 hours, manual RTO is 4 hours, and measured Mattermost/Mailer interruption must remain at or below 5 minutes.
- OCI access uses `--auth instance_principal`; do not create or read a user API-key configuration.
- VM permissions are exact-bucket object create/inspect/read only. VM object delete, bucket update, and bucket delete are forbidden.
- OCI Dynamic Group, IAM Policy, bucket, lifecycle, DNS, public-IP, Email Delivery, and live-VM changes require a new explicit user authorization naming the target compartment and `ap-singapore-1`.
- Never display or commit `deploy/.env`, `/etc/threadhub/backup.env`, SMTP credentials, HMAC secrets, OCI OCIDs, customer domains, email addresses, messages, filenames, or raw logs.
- Never run `docker compose config` without `--quiet` against the real `deploy/.env`.
- Backup artifacts and state files are root-owned mode `0600`; their directories are root-owned mode `0700`.
- Object keys contain only `daily|weekly`, UTC date/time, a random backup ID, and fixed artifact basenames.
- Restore accepts only a fresh Ubuntu VM and an absent or empty `/srv/threadhub`; there is no `--force` and no in-place restore.
- Restored notifier queue data stays quarantined. Live notifier delivery starts disabled and old queued email is never sent automatically.
- Follow TDD for each task: failing focused test, observed failure, minimal implementation, focused pass, broader regression pass, commit.

## File and responsibility map

| File | Responsibility |
| --- | --- |
| `notifier/mailer/internal/adminnotice/notice.go` | Render the sole generic backup-failure email format and validate stable failure classes. |
| `notifier/mailer/cmd/threadhub-mailer/main.go` | Expose exact `backup-alert --json-stdin` CLI without leaking recipient or SMTP data. |
| `deploy/backup.env.example` | Public non-secret backup configuration schema. |
| `deploy/scripts/backup-common.sh` | Fixed paths, secure config, status schema, locks, safe cleanup, Compose and alert helpers. |
| `deploy/scripts/backup-oci.sh` | Instance Principal Object Storage preflight, immutable upload, head verification, list, and download. |
| `deploy/scripts/backup-artifacts.sh` | Backup ID, PostgreSQL dump, archives, strict manifest, checksum, and archive-entry validation. |
| `deploy/scripts/backup.sh` | Application-consistent backup orchestration and `--resume-upload`. |
| `deploy/scripts/backup-status.sh` | Privacy-safe status and 24-hour freshness exit code. |
| `deploy/scripts/data-layout.sh` | Shared canonical `/srv/threadhub` ownership and directory creation used by deploy and restore. |
| `deploy/scripts/restore.sh` | Empty-target, version-locked download and restore with queue quarantine. |
| `deploy/scripts/configure-backup.sh` | Interactive no-clobber creation of `/etc/threadhub/backup.env`. |
| `deploy/scripts/install-backup.sh` | Pinned OCI CLI/zstd installation and disabled systemd unit registration. |
| `deploy/systemd/threadhub-backup.service.template` | Hardened oneshot service bound to the reviewed repository path. |
| `deploy/systemd/threadhub-backup.timer` | 03:00 Asia/Seoul persistent daily schedule, installed disabled. |
| `deploy/tests/backup-*.sh` | Static, security, fault-injection, installer, restore, and documentation contract tests. |
| `deploy/integration/backup/*` | Real Mattermost 11.7.7/PostgreSQL 18.4 seed-backup-restore fixture with deterministic OCI stub. |
| `.github/workflows/validate.yml` | Unit/static job plus isolated real-image backup/restore job. |
| `deploy/docs/backup-restore.md` | OCI prerequisites, backup, restore, acceptance, failure, and approval boundaries. |

---

### Task 1: Add a privacy-safe Mailer backup-failure command

**Files:**
- Create: `notifier/mailer/internal/adminnotice/notice.go`
- Create: `notifier/mailer/internal/adminnotice/notice_test.go`
- Modify: `notifier/mailer/cmd/threadhub-mailer/main.go`
- Modify: `notifier/mailer/cmd/threadhub-mailer/main_test.go`

**Interfaces:**
- Consumes: existing `config.Config`, `message.Message`, `smtpclient.Client`.
- Produces: `adminnotice.Input`, `adminnotice.Render(Input) (message.Message, error)`, `adminnotice.ValidFailureClass(string) bool`, and exact CLI `threadhub-mailer backup-alert --json-stdin`.
- The CLI reads one JSON object with exactly `recipient` and `failure_class`, writes no success output, and returns the existing classified safe SMTP failure format on failure.

- [ ] **Step 1: Write failing renderer tests**

```go
func TestRenderContainsOnlyGenericBackupFailureContent(t *testing.T) {
	in := Input{
		FromName: "ThreadHub", FromAddress: "no-reply@example.test",
		ReplyTo: "support@example.test", ToAddress: "admin@example.test",
		Domain: "threadhub.example.test", FailureClass: "upload",
		OpaqueID: strings.Repeat("a", 64), Date: time.Unix(1788200000, 0),
	}
	got, err := Render(in)
	if err != nil { t.Fatal(err) }
	for _, want := range []string{"[ThreadHub] 백업 실패 (upload)", "자동 백업이 실패했습니다", "backup-status"} {
		if !bytes.Contains(got.Data, []byte(want)) { t.Fatalf("message missing %q", want) }
	}
	for _, forbidden := range []string{"threadhub.example.test", "/srv/threadhub", "customer", "channel"} {
		if bytes.Contains(got.Data, []byte(forbidden)) { t.Fatalf("message leaked %q", forbidden) }
	}
}

func TestValidFailureClassUsesClosedAllowlist(t *testing.T) {
	for _, value := range []string{"preflight", "snapshot", "service_recovery", "manifest", "upload", "remote_verify"} {
		if !ValidFailureClass(value) { t.Fatalf("rejected %q", value) }
	}
	}
	if ValidFailureClass("admin@example.test") { t.Fatal("accepted unbounded class") }
}
```

- [ ] **Step 2: Run the focused renderer test and observe the missing package failure**

Run: `cd notifier && go test ./mailer/internal/adminnotice -run 'Test(Render|ValidFailureClass)' -count=1`

Expected: FAIL because `mailer/internal/adminnotice` does not exist.

- [ ] **Step 3: Implement the minimal renderer**

```go
var allowed = map[string]struct{}{
	"preflight": {}, "snapshot": {}, "service_recovery": {},
	"manifest": {}, "upload": {}, "remote_verify": {},
}

func ValidFailureClass(value string) bool { _, ok := allowed[value]; return ok }

func Render(in Input) (message.Message, error) {
	if !ValidFailureClass(in.FailureClass) || in.Date.IsZero() || len(in.OpaqueID) != 64 {
		return message.Message{}, errInvalidInput
	}
	// Validate all addresses with mail.ParseAddress and reject CR/LF exactly as message.Render does.
	// Subject: [ThreadHub] 백업 실패 (<allowed class>)
	// Body: ThreadHub 자동 백업이 실패했습니다. 서버에서 backup-status를 확인해 주세요.
	// Do not include Domain in subject or body; use it only in Message-ID.
}
```

- [ ] **Step 4: Run renderer tests and verify they pass**

Run: `cd notifier && go test ./mailer/internal/adminnotice -count=1`

Expected: PASS.

- [ ] **Step 5: Write failing exact-CLI and privacy tests**

```go
func TestBackupAlertAcceptsStrictJSONStdin(t *testing.T) {
	var calledRecipient, calledClass string
	ops := commandOperations{backupAlert: func(_ context.Context, _ config.Config, recipient, class string) smtpclient.Result {
		calledRecipient, calledClass = recipient, class
		return smtpclient.Result{Accepted: true, Code: 250}
	}}
	err := runCommand(context.Background(), []string{"backup-alert", "--json-stdin"},
		strings.NewReader(`{"recipient":"admin@example.test","failure_class":"upload"}`),
		io.Discard, testEnvironment, ops)
	if err != nil || calledRecipient != "admin@example.test" || calledClass != "upload" { t.Fatalf("backup alert contract failed") }
}

func TestBackupAlertRejectsUnknownFieldsAndPIIClass(t *testing.T) {
	for _, input := range []string{
		`{"recipient":"admin@example.test","failure_class":"upload","extra":true}`,
		`{"recipient":"admin@example.test","failure_class":"customer@example.test"}`,
	} {
		if err := runCommand(context.Background(), []string{"backup-alert", "--json-stdin"}, strings.NewReader(input), io.Discard, testEnvironment, commandOperations{}); err == nil {
			t.Fatalf("accepted %s", input)
		}
	}
}
```

- [ ] **Step 6: Run the CLI tests and observe the exact-command failure**

Run: `cd notifier && go test ./mailer/cmd/threadhub-mailer -run 'TestBackupAlert' -count=1`

Expected: FAIL because `backup-alert` and `commandOperations.backupAlert` are undefined.

- [ ] **Step 7: Implement strict JSON input and SMTP send**

```go
type backupAlertInput struct {
	Recipient    string `json:"recipient"`
	FailureClass string `json:"failure_class"`
}

// parseCommand accepts only: backup-alert --json-stdin
// decode with json.Decoder.DisallowUnknownFields over io.LimitReader(stdin, 1025),
// require EOF after the first value, validate the recipient and allowed class,
// hash recipient+class+time with the HMAC secret for an opaque Message-ID,
// render through adminnotice.Render, and send with the existing STARTTLS client.
```

- [ ] **Step 8: Run Mailer and notifier regression tests**

Run: `cd notifier && gofmt -w mailer/internal/adminnotice mailer/cmd/threadhub-mailer && make fmt-check mod-verify vet test`

Expected: all commands exit 0 and all race tests pass.

- [ ] **Step 9: Commit the alert primitive**

```bash
git add notifier/mailer/internal/adminnotice notifier/mailer/cmd/threadhub-mailer
git commit -m "feat: add privacy-safe backup failure alert"
```

---

### Task 2: Define secure backup configuration and status contracts

**Files:**
- Create: `deploy/backup.env.example`
- Create: `deploy/scripts/backup-common.sh`
- Create: `deploy/scripts/backup-status.sh`
- Create: `deploy/tests/backup-config-test.sh`
- Modify: `.gitignore`

**Interfaces:**
- Consumes: `deploy/scripts/common.sh`, protected `deploy/.env`, and root-owned `/etc/threadhub/backup.env`.
- Produces: `backup_validate_id`, `backup_validate_config`, `backup_prepare_state_root`, `backup_assert_empty_target`, `backup_write_status`, `backup_read_status`, `backup_safe_remove_set`, `backup_send_alert`, and `backup-status.sh [--json]`.
- `status/latest.json` records the most recent attempt. `status/latest-success.json` is replaced only after every required remote object has been verified and is the sole freshness source.
- Stable status JSON keys are exactly: `status`, `phase`, `backup_id`, `started_at`, `completed_at`, `service_downtime_seconds`, `local_bundle_bytes`, `uploaded_object_count`, `verification_result`, `snapshot_result`, `service_recovery_result`, `upload_result`, `failure_class`, `alert_delivery`.

- [ ] **Step 1: Add the public configuration schema and failing validation tests**

```dotenv
BACKUP_REGION=ap-singapore-1
BACKUP_NAMESPACE=REPLACE_WITH_OCI_OBJECT_STORAGE_NAMESPACE
BACKUP_BUCKET=REPLACE_WITH_PROJECT_PRIVATE_BUCKET_NAME
BACKUP_ALERT_EMAIL=admin@example.com
BACKUP_SCHEDULE=03:00
BACKUP_DAILY_RETENTION_DAYS=7
BACKUP_WEEKLY_RETENTION_DAYS=28
```

```bash
test_rejects_wrong_region() {
    make_fixture BACKUP_REGION=ap-seoul-1
    ! BACKUP_ENV_FILE="${fixture}" backup_validate_config
}

test_rejects_symlink_or_mode_0644() {
    ln -s "${fixture}" "${fixture}.link"
    ! BACKUP_ENV_FILE="${fixture}.link" backup_validate_config
    chmod 0644 "${fixture}"
    ! BACKUP_ENV_FILE="${fixture}" backup_validate_config
}

test_production_config_requires_root_owner() {
    BACKUP_EXPECTED_CONFIG_UID=0
    ! backup_validate_config
}

test_status_schema_is_exact_and_private() {
    backup_write_status failed upload safeid 1 2 3 4 5 failed ok ok failed upload failed
    jq -e 'keys == ["alert_delivery","backup_id","completed_at","failure_class","local_bundle_bytes","phase","service_downtime_seconds","service_recovery_result","snapshot_result","started_at","status","upload_result","uploaded_object_count","verification_result"]' "${BACKUP_STATUS_FILE}"
    ! grep -F -f "${private_patterns}" "${BACKUP_STATUS_FILE}"
}
```

- [ ] **Step 2: Run the configuration test and observe the missing library failure**

Run: `./deploy/tests/backup-config-test.sh`

Expected: FAIL because `backup-common.sh` and the config schema do not exist.

- [ ] **Step 3: Implement fixed paths, exact parser, and atomic status**

```bash
BACKUP_ENV_FILE="${THREADHUB_BACKUP_ENV_FILE:-/etc/threadhub/backup.env}"
BACKUP_STATE_ROOT=/var/lib/threadhub-backup
BACKUP_STAGING_ROOT=${BACKUP_STATE_ROOT}/staging
BACKUP_STATUS_FILE=${BACKUP_STATE_ROOT}/status/latest.json
BACKUP_LATEST_SUCCESS_FILE=${BACKUP_STATE_ROOT}/status/latest-success.json
BACKUP_LOCK_FILE=${BACKUP_STATE_ROOT}/backup.lock

backup_validate_config() {
    backup_require_regular_mode_owner "${BACKUP_ENV_FILE}" 0600 "${BACKUP_EXPECTED_CONFIG_UID:-0}" || return 20
    backup_require_exact_keys "${BACKUP_ENV_FILE}" \
        BACKUP_REGION BACKUP_NAMESPACE BACKUP_BUCKET BACKUP_ALERT_EMAIL \
        BACKUP_SCHEDULE BACKUP_DAILY_RETENTION_DAYS BACKUP_WEEKLY_RETENTION_DAYS
    [[ "$(backup_env_value BACKUP_REGION)" == ap-singapore-1 ]]
    [[ "$(backup_env_value BACKUP_SCHEDULE)" == 03:00 ]]
    [[ "$(backup_env_value BACKUP_DAILY_RETENTION_DAYS)" == 7 ]]
    [[ "$(backup_env_value BACKUP_WEEKLY_RETENTION_DAYS)" == 28 ]]
    backup_validate_namespace "$(backup_env_value BACKUP_NAMESPACE)"
    backup_validate_bucket "$(backup_env_value BACKUP_BUCKET)"
    validate_email BACKUP_ALERT_EMAIL "$(backup_env_value BACKUP_ALERT_EMAIL)"
}

backup_validate_id() {
    [[ "$1" =~ ^[0-9]{8}T[0-9]{6}Z-[a-f0-9]{32}$ ]]
}

backup_assert_empty_target() {
    local target="$1"
    [[ "${target}" == /srv/threadhub ]]
    [[ ! -L "${target}" ]]
    [[ ! -e "${target}" ]] || { [[ -d "${target}" ]] && ! find "${target}" -mindepth 1 -print -quit | grep -q .; }
}
```

Implement `backup_write_status` with `jq -cn`, a mode-0600 temporary file in the status directory, `fsync` where available, and `mv -fT` after rechecking directory identity. Reject unknown status/phase/result/failure values rather than serializing caller text.

- [ ] **Step 4: Implement the status CLI and freshness exit contract**

```bash
case "${1:-}" in
    "") jq -r 'to_entries[] | "\(.key)=\(.value)"' "${BACKUP_STATUS_FILE}" ;;
    --json) jq -c . "${BACKUP_STATUS_FILE}" ;;
    *) die "Usage: $0 [--json]" ;;
esac

latest_success_at="$(jq -er '.completed_at | select(type == "number")' "${BACKUP_LATEST_SUCCESS_FILE}")"
(( $(date +%s) - latest_success_at <= 86400 )) || exit 1
jq -e '.status == "success" and .verification_result == "ok"' "${BACKUP_STATUS_FILE}" >/dev/null
jq -e '.status == "success" and .verification_result == "ok"' "${BACKUP_LATEST_SUCCESS_FILE}" >/dev/null
```

Validate both files with the exact status schema before reading them. A missing or malformed latest-success file, a current failed attempt, a verification result other than `ok`, or a last successful completion older than 24 hours returns non-zero. Human and JSON output still describe `latest.json`; do not merge or print remote object keys.

- [ ] **Step 5: Implement generic alert invocation without reading SMTP secrets into argv**

```bash
backup_send_alert() {
    local failure_class="$1" payload
    payload="$(jq -cn --arg recipient "$(backup_env_value BACKUP_ALERT_EMAIL)" --arg failure_class "${failure_class}" '{recipient:$recipient,failure_class:$failure_class}')"
    printf '%s\n' "${payload}" | compose run --rm --no-deps -T \
        --entrypoint /threadhub-mailer threadhub-mailer backup-alert --json-stdin \
        >/dev/null 2>&1
}
```

Only call this once for the primary failure. On alert failure, preserve the original `failure_class` and set `alert_delivery=failed`.

- [ ] **Step 6: Protect runtime files from Git and complete security fixtures**

Add these exact ignore rules:

```gitignore
deploy/backup.env
deploy/backup.env.*
!deploy/backup.env.example
backup-staging/
restore-staging/
```

Test path traversal, duplicate/unknown keys, newline values, unsafe backup IDs, symlinked status/staging paths, status redaction, safe cleanup constrained to `${BACKUP_STAGING_ROOT}/<valid-id>`, and alert failure preserving the original failure class.

- [ ] **Step 7: Run focused and broad shell validation**

Run: `./deploy/tests/backup-config-test.sh && bash -n deploy/scripts/backup-common.sh deploy/scripts/backup-status.sh && ./deploy/scripts/validate.sh`

Expected: all commands exit 0; no protected fixture value appears in output.

- [ ] **Step 8: Commit configuration and status contracts**

```bash
git add .gitignore deploy/backup.env.example deploy/scripts/backup-common.sh deploy/scripts/backup-status.sh deploy/tests/backup-config-test.sh
git commit -m "feat: add backup configuration and status contracts"
```

---

### Task 3: Add the exact-bucket OCI Object Storage transport

**Files:**
- Create: `deploy/scripts/backup-oci.sh`
- Create: `deploy/tests/backup-oci-test.sh`

**Interfaces:**
- Consumes: validated `BACKUP_REGION`, `BACKUP_NAMESPACE`, and `BACKUP_BUCKET` from Task 2.
- Produces: `backup_oci_preflight`, `backup_oci_upload FILE KEY SHA256`, `backup_oci_verify KEY SIZE SHA256`, `backup_oci_find_set BACKUP_ID`, and `backup_oci_download KEY FILE`.
- Tests inject `OCI_COMMAND=(/absolute/path/to/stub)`; production always resolves the pinned `/usr/local/bin/oci` installed in Task 8.

- [ ] **Step 1: Write a deterministic OCI command recorder and failing tests**

```bash
test_upload_uses_instance_principal_and_no_overwrite() {
    backup_oci_upload "${artifact}" 'daily/2026/09/01/20260901T030000Z-0123456789abcdef0123456789abcdef/database.dump' "${sha}"
    assert_argv_contains '--auth' 'instance_principal'
    assert_argv_contains '--region' 'ap-singapore-1'
    assert_argv_contains '--no-overwrite' '--verify-checksum'
    assert_argv_contains '--opc-checksum-algorithm' 'SHA256'
    assert_argv_not_contains 'delete' 'bulk-delete' 'bucket delete'
}

test_head_mismatch_is_rejected() {
    OCI_STUB_HEAD_LENGTH=1
    OCI_STUB_HEAD_SHA256=wrong
    ! backup_oci_verify "${key}" "$(stat -c %s "${artifact}")" "${sha}"
}

test_cross_bucket_cannot_be_selected_from_arguments() {
    ! backup_oci_upload "${artifact}" '../other-bucket/object' "${sha}"
}
```

- [ ] **Step 2: Run the OCI tests and observe the missing transport failure**

Run: `./deploy/tests/backup-oci-test.sh`

Expected: FAIL because `backup-oci.sh` does not exist.

- [ ] **Step 3: Implement one fixed OCI invocation boundary**

```bash
backup_oci() {
    "${OCI_COMMAND[@]}" "$@" \
        --auth instance_principal \
        --region "$(backup_env_value BACKUP_REGION)" \
        --output json
}

backup_oci_upload() {
    local file="$1" key="$2" sha256="$3" sha256_b64 metadata
    backup_validate_object_key "${key}"
    [[ "$(sha256_file "${file}")" == "${sha256}" ]]
    sha256_b64="$(openssl dgst -sha256 -binary "${file}" | openssl base64 -A)"
    metadata="$(jq -cn --arg sha "${sha256}" '{"threadhub-sha256":$sha}')"
    backup_oci os object put \
        --namespace-name "$(backup_env_value BACKUP_NAMESPACE)" \
        --bucket-name "$(backup_env_value BACKUP_BUCKET)" \
        --name "${key}" --file "${file}" --no-overwrite --verify-checksum \
        --opc-checksum-algorithm SHA256 --opc-content-sha256 "${sha256_b64}" \
        --metadata "${metadata}" >"${response_file}"
}
```

Never expose a generic pass-through subcommand. Every public function constructs the bucket, namespace, auth, and region itself.

- [ ] **Step 4: Implement remote head verification and exact set discovery**

```bash
backup_oci_verify() {
    local key="$1" expected_size="$2" expected_sha="$3" response
    response="$(mktemp)"
    backup_oci os object head --namespace-name "$(backup_env_value BACKUP_NAMESPACE)" \
        --bucket-name "$(backup_env_value BACKUP_BUCKET)" --name "${key}" >"${response}"
    [[ "$(jq -er '.["content-length"]' "${response}")" == "${expected_size}" ]]
    [[ "$(jq -er '.["opc-meta-threadhub-sha256"]' "${response}")" == "${expected_sha}" ]]
}
```

`backup_oci_find_set` first lists `daily/` and, when no matching daily set remains, falls back to `weekly/`. Within each tier it filters keys matching the strict fixed-artifact suffix for the requested backup ID, requires exactly one directory prefix, and prints only that prefix to its caller. This preserves restore access after the shorter daily lifecycle expires while rejecting ambiguous duplicate prefixes. Do not print the selected prefix in status or user-facing logs.

- [ ] **Step 5: Cover list pagination, immutable upload, and private output**

Add fixtures for two-page list responses, duplicate IDs under two dates, malformed object names, remote metadata mismatch, OCI diagnostics containing a fake OCID/domain/email, and download no-clobber. Assert user-facing stderr contains only a stable error class.

- [ ] **Step 6: Run focused tests and ShellCheck**

Run: `./deploy/tests/backup-oci-test.sh && shellcheck -x -P deploy/scripts deploy/scripts/backup-oci.sh deploy/tests/backup-oci-test.sh`

Expected: PASS with the stub showing no delete operation and no non-configured bucket.

- [ ] **Step 7: Commit the OCI transport**

```bash
git add deploy/scripts/backup-oci.sh deploy/tests/backup-oci-test.sh
git commit -m "feat: add exact-bucket OCI backup transport"
```

---

### Task 4: Build and strictly validate backup sets

**Files:**
- Create: `deploy/scripts/backup-artifacts.sh`
- Create: `deploy/tests/backup-artifacts-test.sh`

**Interfaces:**
- Consumes: `compose`, `sha256_file`, pinned `versions.env`, and notifier `release.env`.
- Produces: `backup_generate_id`, `backup_create_artifacts SET_DIR`, `backup_write_manifest SET_DIR`, `backup_validate_manifest_identity SET_DIR EXPECTED_ID`, `backup_validate_set SET_DIR EXPECTED_ID`, and `backup_extract_archive ARCHIVE DESTINATION`.
- Backup ID format: `YYYYMMDDTHHMMSSZ-` plus exactly 32 lowercase hexadecimal characters.

- [ ] **Step 1: Write failing ID, manifest, and archive-safety tests**

```bash
test_generated_id_is_private_and_strict() {
    id="$(backup_generate_id)"
    [[ "${id}" =~ ^[0-9]{8}T[0-9]{6}Z-[a-f0-9]{32}$ ]]
    [[ "${id}" != *threadhub* && "${id}" != *@* ]]
}

test_manifest_has_exact_schema() {
    backup_write_manifest "${set_dir}"
    jq -e '
      keys == ["artifacts","backup_id","created_at","images","notifier","schema_version","source_commit"] and
      .schema_version == 1 and
      (.artifacts | map(.name) == ["database.dump","mattermost-data.tar.zst","notifier-queue.tar.zst"])
    ' "${set_dir}/manifest.json"
}

test_archive_rejects_parent_and_symlink_entries() {
    make_malicious_archive '../escape'
    ! backup_validate_archive "${malicious_archive}"
    make_malicious_symlink_archive 'safe/link' '/etc/shadow'
    ! backup_validate_archive "${malicious_archive}"
}
```

- [ ] **Step 2: Run artifact tests and observe the missing implementation failure**

Run: `./deploy/tests/backup-artifacts-test.sh`

Expected: FAIL because `backup-artifacts.sh` is absent.

- [ ] **Step 3: Implement ID generation and the three fixed artifacts**

```bash
backup_generate_id() {
    printf '%s-%s\n' "$(date -u +%Y%m%dT%H%M%SZ)" "$(openssl rand -hex 16)"
}

backup_create_database_dump() {
    local output="$1" db_user db_name
    db_user="$(env_value POSTGRES_USER "${ENV_FILE}")"
    db_name="$(env_value POSTGRES_DB "${ENV_FILE}")"
    compose exec -T postgres pg_dump --format=custom --no-owner --no-acl \
        --username "${db_user}" --dbname "${db_name}" >"${output}"
    chmod 0600 "${output}"
}

backup_create_archive "${data_root}/mattermost/data" "${set_dir}/mattermost-data.tar.zst"
backup_create_archive "${data_root}/notifier/mailer" "${set_dir}/notifier-queue.tar.zst" \
    queue.db queue.db-wal queue.db-shm
```

The queue archive includes only existing fixed basenames and fails if `queue.db` is absent. Use GNU tar with relative names, `--numeric-owner`, no absolute paths, and zstd; do not enumerate customer filenames in stdout or manifest.

- [ ] **Step 4: Implement exact provenance and manifest generation**

```json
{
  "schema_version": 1,
  "backup_id": "20260901T030000Z-0123456789abcdef0123456789abcdef",
  "created_at": "2026-09-01T03:00:00Z",
  "source_commit": "<40-or-64-lowercase-hex>",
  "images": {
    "mattermost": {"repository":"mattermost/mattermost-team-edition","tag":"11.7.7","digest":"sha256:<64-hex>"},
    "postgres": {"repository":"postgres","tag":"18.4","digest":"sha256:<64-hex>"}
  },
  "notifier": {"version":"0.1.0","mailer_image_id":"sha256:<64-hex>"},
  "artifacts": [
    {"name":"database.dump","bytes":1,"sha256":"<64-hex>"},
    {"name":"mattermost-data.tar.zst","bytes":1,"sha256":"<64-hex>"},
    {"name":"notifier-queue.tar.zst","bytes":1,"sha256":"<64-hex>"}
  ]
}
```

Require clean tracked Git state, `git rev-parse HEAD == NOTIFIER_SOURCE_COMMIT`, exact image fields from `versions.env`, and exact Mailer ID from `/srv/threadhub/notifier/release/release.env`. Generate compact, sorted JSON through jq and then `manifest.sha256` containing only `<hash>  manifest.json`.

- [ ] **Step 5: Implement strict validation before any extraction**

Validation order is: manifest checksum, strict JSON keys/types, requested backup ID, exact three artifact names, file type/no symlink, size, SHA-256, then tar listing. Reject absolute names, empty names, `.`/`..` components, hard links, symbolic links, devices, FIFOs, sockets, and any queue member outside the three allowed SQLite names.

```bash
backup_extract_archive() {
    local archive="$1" destination="$2"
    backup_validate_archive "${archive}"
    tar --extract --zstd --file "${archive}" --directory "${destination}" \
        --no-same-owner --no-same-permissions
}
```

- [ ] **Step 6: Run artifact, privacy, and corrupted-input tests**

Run: `./deploy/tests/backup-artifacts-test.sh && shellcheck -x -P deploy/scripts deploy/scripts/backup-artifacts.sh deploy/tests/backup-artifacts-test.sh`

Expected: valid fixture passes; every corrupt manifest, size/hash mismatch, extra artifact, and unsafe archive fails before extraction.

- [ ] **Step 7: Commit backup-set construction**

```bash
git add deploy/scripts/backup-artifacts.sh deploy/tests/backup-artifacts-test.sh
git commit -m "feat: build and validate ThreadHub backup sets"
```

---

### Task 5: Orchestrate application-consistent backup and resume-upload

**Files:**
- Create: `deploy/scripts/backup.sh`
- Create: `deploy/tests/backup-orchestration-test.sh`

**Interfaces:**
- Consumes: Tasks 1-4, production service names `mattermost`, `threadhub-mailer`, and `postgres`.
- Produces: `backup.sh` and `backup.sh --resume-upload BACKUP_ID`.
- Injectable test seams: `backup_health`, `backup_stop_writers`, `backup_start_writers`, `backup_snapshot`, `backup_upload_set`, `backup_alert_once`.

- [ ] **Step 1: Write failing happy-path order and preflight tests**

```bash
test_backup_restarts_before_upload() {
    run_backup_with_recording_hooks
    assert_exact_events \
        lock preflight health stop:mattermost stop:threadhub-mailer snapshot \
        start:threadhub-mailer start:mattermost health manifest upload verify status:success cleanup
}

test_preflight_failure_never_stops_services() {
    BACKUP_FAIL_AT=preflight run_backup_expect_failure
    assert_event_absent stop:mattermost stop:threadhub-mailer
    assert_status '.failure_class == "preflight" and .service_recovery_result == "not_needed"'
}

test_upload_resume_never_touches_services_or_snapshot() {
    run_backup --resume-upload "${valid_id}"
    assert_event_absent stop:mattermost snapshot
    assert_exact_events lock validate-local-set upload verify status:success cleanup
}
```

- [ ] **Step 2: Run orchestration tests and observe the missing command failure**

Run: `./deploy/tests/backup-orchestration-test.sh`

Expected: FAIL because `backup.sh` does not exist.

- [ ] **Step 3: Implement preflight and lock before mutation**

```bash
backup_preflight() {
    require_ubuntu_amd64
    validate_runtime_env
    backup_validate_config
    backup_prepare_state_root
    init_docker
    require_command jq tar zstd openssl flock stat git
    compose config --quiet
    "${SCRIPT_DIR}/health-check.sh" >/dev/null
    backup_require_capacity
    backup_oci_preflight
}

exec {BACKUP_LOCK_FD}>"${BACKUP_LOCK_FILE}"
flock -n "${BACKUP_LOCK_FD}" || exit 0
```

`backup_require_capacity` computes the byte size of the fixed Mattermost attachment directory and Mailer queue directory with `du -sb` while suppressing filenames, then requires free bytes in the staging filesystem from `df --output=avail -B1` to be at least `2 * estimated_input_bytes + 1 GiB`. Treat command, overflow, or capacity uncertainty as `preflight` failure before stopping either writer.

A concurrent timer run exits without an alert because the active run owns responsibility for status.

- [ ] **Step 4: Implement the service-recovery trap and snapshot boundary**

```bash
mattermost_stopped=false
mailer_stopped=false
recover_writers_and_exit() {
    local original=$?
    local recovery_failed=false
    trap - EXIT HUP INT TERM
    if [[ "${mailer_stopped}" == true ]]; then
        backup_start_mailer || recovery_failed=true
    fi
    if [[ "${mattermost_stopped}" == true ]]; then
        backup_start_mattermost || recovery_failed=true
    fi
    if [[ "${recovery_failed}" == true ]]; then
        service_recovery_result=failed
        backup_record_failure service_recovery || true
        backup_alert_once service_recovery || true
        exit 1
    fi
    exit "${original}"
}
trap recover_writers_and_exit EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

downtime_started="$(date +%s)"
backup_stop_mattermost    # compose stop --timeout 60 mattermost
mattermost_stopped=true
backup_stop_mailer        # compose stop --timeout 60 threadhub-mailer
mailer_stopped=true
backup_snapshot "${set_dir}"
backup_start_mailer
mailer_stopped=false
backup_start_mattermost
mattermost_stopped=false
backup_health
service_downtime_seconds=$(( $(date +%s) - downtime_started ))
```

The EXIT/signal handler records the original exit status, clears its own traps, attempts Mailer and Mattermost recovery independently for every service whose flag is true, records any recovery failure, and then exits with the original failure unless service recovery failed. `backup_alert_once` is idempotent per run, including when called from this handler. If snapshot fails, leave no uploadable manifest, write `snapshot_result=failed`, and alert once. If restart fails, record `failure_class=service_recovery` while retaining the original snapshot result. Add a fault test where Mattermost stops but Mailer stop fails; Mattermost must still restart.

- [ ] **Step 5: Implement upload after service health and Sunday duplication**

Generate the manifest only after service recovery. Upload each fixed file to the daily prefix, verify each head response, then repeat the exact same set under weekly when `TZ=Asia/Seoul date +%u` is `7`. Update `latest-success.json` only after every required object verifies.

```bash
daily_prefix="daily/$(date -u +%Y/%m/%d)/${backup_id}"
weekly_required=false
[[ "$(TZ=Asia/Seoul date +%u)" == 7 ]] && weekly_required=true
backup_upload_prefix "${set_dir}" "${daily_prefix}"
if [[ "${weekly_required}" == true ]]; then
    backup_upload_prefix "${set_dir}" "weekly/$(date -u +%Y/%m/%d)/${backup_id}"
fi
```

- [ ] **Step 6: Implement 24-hour failed-set retention and safe resume**

On upload/verify failure, retain only a complete validated set and write its expiry in private state. `--resume-upload` requires a valid ID, exact root-owned mode-0700 directory, valid set, and unexpired marker; it never calls stop, start, dump, tar, or manifest generation. Cleanup removes only a validated direct child of the fixed staging root.

- [ ] **Step 7: Exercise every fault-injection boundary**

Add cases for dump failure, data archive failure, queue archive failure, restart failure, manifest failure, daily upload failure, Sunday weekly failure, head length/hash mismatch, alert failure, interrupted signal, stale resume, malformed backup ID, and cleanup path substitution. For each case assert service events, exact status fields, local set disposition, and absence of private fixture strings.

- [ ] **Step 8: Run focused orchestration and full static validation**

Run: `./deploy/tests/backup-orchestration-test.sh && shellcheck -x -P deploy/scripts deploy/scripts/backup.sh deploy/tests/backup-orchestration-test.sh && ./deploy/scripts/validate.sh`

Expected: all fault cases produce their exact safe classification; success order matches the contract.

- [ ] **Step 9: Commit backup orchestration**

```bash
git add deploy/scripts/backup.sh deploy/tests/backup-orchestration-test.sh
git commit -m "feat: orchestrate application-consistent backups"
```

---

### Task 6: Extract the canonical data-layout operation for deploy and restore

**Files:**
- Create: `deploy/scripts/data-layout.sh`
- Create: `deploy/tests/data-layout-test.sh`
- Modify: `deploy/scripts/deploy.sh`

**Interfaces:**
- Consumes: initialized `SUDO_COMMAND`, fixed `/srv/threadhub`, and existing notifier path validators.
- Produces: `prepare_threadhub_data_layout DATA_ROOT` and `normalize_threadhub_restored_data DATA_ROOT`.
- `prepare_threadhub_data_layout` is idempotent and never removes or replaces existing content.

- [ ] **Step 1: Write failing metadata and no-clobber tests**

```bash
test_layout_has_canonical_metadata() {
    prepare_threadhub_data_layout "${fixture_root}"
    assert_identity "${fixture_root}" 0:0:750
    assert_identity "${fixture_root}/postgres" 0:0:755
    assert_identity "${fixture_root}/mattermost/data" 2000:2000:750
    assert_identity "${fixture_root}/notifier/mailer" 65532:65532:700
    assert_identity "${fixture_root}/notifier/control" 0:3000:750
}

test_existing_sentinel_is_preserved() {
    install -m 0600 /dev/null "${fixture_root}/mattermost/data/sentinel"
    before="$(sha256sum "${fixture_root}/mattermost/data/sentinel")"
    prepare_threadhub_data_layout "${fixture_root}"
    [[ "$(sha256sum "${fixture_root}/mattermost/data/sentinel")" == "${before}" ]]
}
```

- [ ] **Step 2: Run the layout test and observe the missing function failure**

Run: `./deploy/tests/data-layout-test.sh`

Expected: FAIL because `data-layout.sh` is absent.

- [ ] **Step 3: Move the exact directory creation logic without changing behavior**

```bash
prepare_threadhub_data_layout() {
    local data_root="$1" mattermost_root notifier_root
    data_layout_validate_root "${data_root}" || die "Refusing data layout outside /srv/threadhub"
    mattermost_root="${data_root}/mattermost"
    notifier_root="${data_root}/notifier"
    # Use the current deploy.sh install/chown/chmod sequence verbatim:
    # root 0750, postgres 0755, Mattermost 2000:2000 0750,
    # Mailer 65532:65532 0700, notifier control root:3000 0750.
    # Recheck symlink and identity boundaries before every privileged write.
}
```

Production `data_layout_validate_root` accepts only `/srv/threadhub`. The test sources the library and replaces that single validator function with one accepting only its canonical `mktemp` fixture; do not add a production environment-variable bypass.

Replace the corresponding block in `deploy.sh` with `prepare_threadhub_data_layout "${data_root}"`; keep `ensure_disabled_notifier_control` after layout preparation.

- [ ] **Step 4: Add restored-tree normalization without following symlinks**

`normalize_threadhub_restored_data` accepts only the fixed Mattermost data directory and applies `2000:2000`, `u=rwX,g=rX,o=` to regular files/directories after the archive validator has rejected links and special entries. It must not touch PostgreSQL or the quarantined queue.

- [ ] **Step 5: Run data-layout and deployment regressions**

Run: `./deploy/tests/data-layout-test.sh && ./deploy/tests/notifier-deploy-test.sh && ./deploy/scripts/validate.sh`

Expected: all existing ownership, mount, and notifier tests continue to pass.

- [ ] **Step 6: Commit the shared layout**

```bash
git add deploy/scripts/data-layout.sh deploy/scripts/deploy.sh deploy/tests/data-layout-test.sh
git commit -m "refactor: share ThreadHub data layout preparation"
```

---

### Task 7: Add a fail-closed fresh-VM restore command

**Files:**
- Create: `deploy/scripts/restore.sh`
- Create: `deploy/tests/backup-restore-test.sh`

**Interfaces:**
- Consumes: Tasks 2-4 and 6, a complete protected `deploy/.env`, protected backup config, OCI Instance Principal access, and `restore.sh BACKUP_ID`.
- Produces: `restore_download_manifest_artifacts PREFIX DOWNLOAD_DIR`, restored PostgreSQL and Mattermost data under a formerly empty `/srv/threadhub`, quarantined queue under `/var/lib/threadhub-backup/restore/BACKUP_ID/notifier-queue`, and disabled live notifier state.
- Does not consume or offer `--force`; does not touch DNS, NGINX, certificates, SMTP, IAM, public IP, or the source backup objects.

- [ ] **Step 1: Write failing empty-target and no-force tests**

```bash
test_nonempty_target_is_rejected_before_download() {
    mkdir -p "${target_root}"
    printf sentinel >"${target_root}/existing"
    ! run_restore "${valid_id}"
    assert_event_absent oci-download compose-up extract
    [[ "$(cat "${target_root}/existing")" == sentinel ]]
}

test_force_option_does_not_exist() {
    ! "${RESTORE_SCRIPT}" --force "${valid_id}"
    ! "${RESTORE_SCRIPT}" "${valid_id}" --force
}

test_invalid_manifest_never_creates_target_root() {
    OCI_STUB_SET=bad-checksum
    ! run_restore "${valid_id}"
    [[ ! -e "${target_root}" ]]
}
```

- [ ] **Step 2: Run restore tests and observe the missing command failure**

Run: `./deploy/tests/backup-restore-test.sh`

Expected: FAIL because `restore.sh` does not exist.

- [ ] **Step 3: Implement read-only preflight and complete download validation**

```bash
restore_preflight() {
    [[ "$#" -eq 1 ]] || die "Usage: $0 BACKUP_ID"
    backup_validate_id "$1"
    require_ubuntu_amd64
    runtime_env_require_secure "${ENV_FILE}"
    validate_runtime_env
    backup_validate_config
    backup_assert_empty_target /srv/threadhub
    backup_oci_preflight
}

prefix="$(backup_oci_find_set "${backup_id}")"
backup_oci_download "${prefix}/manifest.sha256" "${download}/manifest.sha256"
backup_oci_download "${prefix}/manifest.json" "${download}/manifest.json"
backup_validate_manifest_identity "${download}" "${backup_id}"
restore_download_manifest_artifacts "${prefix}" "${download}"
backup_validate_set "${download}" "${backup_id}"
```

All downloads are no-clobber regular files mode `0600`; OCI stderr goes to a protected diagnostic file and only a stable class reaches the terminal.

- [ ] **Step 4: Enforce exact source and version compatibility before target mutation**

Compare `git rev-parse HEAD`, clean tracked state, Mattermost repository/tag/digest, PostgreSQL repository/tag/digest, and notifier version to the manifest. Refuse mismatch; do not migrate or select a newer image automatically.

```bash
jq -e --arg commit "$(git rev-parse HEAD)" '.source_commit == $commit' manifest.json
jq -e --arg digest "$(env_value MATTERMOST_IMAGE_DIGEST "${VERSIONS_FILE}")" '.images.mattermost.digest == $digest' manifest.json
jq -e --arg digest "$(env_value POSTGRES_IMAGE_DIGEST "${VERSIONS_FILE}")" '.images.postgres.digest == $digest' manifest.json
```

- [ ] **Step 5: Prepare the empty root, rebuild notifier, and verify the Mailer ID**

Call `prepare_threadhub_data_layout /srv/threadhub`, keep notifier disabled, build reviewed notifier artifacts, and require `/srv/threadhub/notifier/release/release.env` `NOTIFIER_MAILER_IMAGE_ID` to equal the manifest before restoring customer data. A mismatch stops with the partially prepared empty layout preserved for explicit cleanup.

Immediately before `prepare_threadhub_data_layout`, recheck that `/srv/threadhub` is still absent or empty, is not a symlink, and its parent identity has not changed since preflight.

- [ ] **Step 6: Restore PostgreSQL and Mattermost attachments**

```bash
compose up -d --wait --wait-timeout 120 postgres
relation_count="$(compose exec -T postgres psql -U "${db_user}" -d "${db_name}" -Atc \
  "select count(*) from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relkind in ('r','p','v','m','S','f');")"
[[ "${relation_count}" == 0 ]] || die "Target database is not empty"
compose exec -T postgres pg_restore --exit-on-error --no-owner --no-acl \
    -U "${db_user}" -d "${db_name}" <"${download}/database.dump"
backup_extract_archive "${download}/mattermost-data.tar.zst" "/srv/threadhub/mattermost/data"
normalize_threadhub_restored_data /srv/threadhub
```

Do not use `--clean`, `--create`, or owner restoration.

- [ ] **Step 7: Quarantine the old queue and start disabled**

Extract `notifier-queue.tar.zst` only into `${BACKUP_STATE_ROOT}/restore/${backup_id}/notifier-queue`, mode `0700/0600`. Create a new empty live Mailer directory and the canonical disabled control JSON, then run `deploy.sh`. Assert `notifier-status.sh` reports delivery disabled and live queue aggregates are zero.

- [ ] **Step 8: Add failure and privacy fixtures**

Cover duplicate remote IDs, missing artifact, wrong source commit, image mismatch, non-empty DB, pg_restore failure, unsafe archive, Mailer image mismatch, deploy health failure, and attempted old queue connection. Assert source objects are never changed, the target is never auto-deleted, exact safe cleanup path is printed, and no private string is emitted.

- [ ] **Step 9: Run restore and full static tests**

Run: `./deploy/tests/backup-restore-test.sh && shellcheck -x -P deploy/scripts deploy/scripts/restore.sh deploy/tests/backup-restore-test.sh && ./deploy/scripts/validate.sh`

Expected: every fail-closed case stops before the next mutation boundary; valid stub restore reaches disabled readiness.

- [ ] **Step 10: Commit restore**

```bash
git add deploy/scripts/restore.sh deploy/tests/backup-restore-test.sh
git commit -m "feat: add fail-closed ThreadHub restore"
```

---

### Task 8: Install pinned backup dependencies and a gated systemd timer

**Files:**
- Create: `deploy/scripts/configure-backup.sh`
- Create: `deploy/scripts/install-backup.sh`
- Create: `deploy/systemd/threadhub-backup.service.template`
- Create: `deploy/systemd/threadhub-backup.timer`
- Create: `deploy/tests/backup-installer-test.sh`
- Modify: `deploy/versions.env`
- Modify: `deploy/scripts/setup-wizard.sh`
- Modify: `deploy/scripts/install-status.sh`

**Interfaces:**
- Consumes: Task 2 config schema, current absolute repository root, Ubuntu root privilege, and pinned OCI CLI archive.
- Produces: `configure-backup.sh`, `install-backup.sh --register`, and `install-backup.sh --enable-after-acceptance BACKUP_ID`.
- `--register` never enables or starts the timer. Activation is interactive and requires a matching verified latest-success backup.

- [ ] **Step 1: Pin the OCI CLI release and write failing installer tests**

Add exact values to `deploy/versions.env`:

```dotenv
OCI_CLI_VERSION=3.90.3
OCI_CLI_ARCHIVE_SHA256=098a9470ad4f097d505b8dbab6ec7e7d4397d2d5db2ed19ef402ca39cdfdd35d
```

```bash
test_register_installs_but_does_not_enable_timer() {
    run_installer --register
    assert_installed_unit threadhub-backup.service
    assert_installed_unit threadhub-backup.timer
    assert_systemctl_not_called enable
    assert_systemctl_not_called start
}

test_enable_requires_tty_confirmation_and_verified_id() {
    ! run_noninteractive --enable-after-acceptance "${valid_id}"
    assert_output_exact '[ACTION REQUIRED] Run ./deploy/scripts/install-backup.sh --enable-after-acceptance BACKUP_ID in an interactive terminal.'
}
```

- [ ] **Step 2: Run installer tests and observe missing scripts/units**

Run: `./deploy/tests/backup-installer-test.sh`

Expected: FAIL because the configuration, installer, and units are absent.

- [ ] **Step 3: Implement interactive, no-clobber backup configuration**

`configure-backup.sh` accepts no values on the command line. It prompts for OCI namespace, exact project bucket name, and alert email; writes fixed region/schedule/retention; validates through a temporary mode-0600 file; then publishes `/etc/threadhub/backup.env` without replacing an existing file.

```bash
printf 'OCI Object Storage namespace: '; read -r namespace
printf 'Project-private backup bucket: '; read -r bucket
printf 'Backup failure recipient: '; read -r alert_email
# Write through mktemp under /etc/threadhub, install root:root 0600, and link/move no-clobber.
# Existing valid configuration is reused without printing values; unsafe/partial state returns 20.
```

- [ ] **Step 4: Install OCI CLI from the pinned archive and zstd**

Download `https://github.com/oracle/oci-cli/releases/download/v${OCI_CLI_VERSION}/oci-cli-${OCI_CLI_VERSION}.zip` to a root-only temporary directory, verify the exact SHA-256, require the single exact `oci_cli-${OCI_CLI_VERSION}-py3-none-any.whl` member, and install that wheel into a dedicated venv at `/opt/threadhub/oci-cli-${OCI_CLI_VERSION}` with executable link `/usr/local/bin/oci`. Reuse an exact installed version; refuse to overwrite a different `/usr/local/bin/oci`. Install Ubuntu `zstd`, `python3`, `python3-venv`, and `unzip` through apt.

- [ ] **Step 5: Add hardened units with a rendered exact repository path**

```ini
[Unit]
Description=ThreadHub application-consistent backup
After=docker.service network-online.target
Wants=network-online.target
ConditionPathExists=/etc/threadhub/backup.env

[Service]
Type=oneshot
WorkingDirectory=__REPOSITORY_ROOT__
ExecStart=__REPOSITORY_ROOT__/deploy/scripts/backup.sh
UMask=0077
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=read-only
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
LockPersonality=true
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
```

```ini
[Unit]
Description=Run ThreadHub backup daily at 03:00 Asia/Seoul

[Timer]
OnCalendar=*-*-* 03:00:00 Asia/Seoul
Persistent=true
AccuracySec=1min
Unit=threadhub-backup.service

[Install]
WantedBy=timers.target
```

Render only an absolute canonical Git worktree path with no newline or systemd metacharacters. Run `systemd-analyze verify`; install units mode `0644`; `daemon-reload`; leave disabled.

- [ ] **Step 6: Implement explicit activation after acceptance**

`--enable-after-acceptance BACKUP_ID` requires a TTY, valid protected config, `latest-success.json` with the same ID and remote verification success, and exact input `ENABLE BACKUP TIMER`. It then runs `systemctl enable --now threadhub-backup.timer` and verifies active/enabled. It does not claim a restore test occurred; the operator must follow the documented disposable-VM evidence checklist before typing the phrase.

- [ ] **Step 7: Integrate registration without broadening base `[READY]`**

Call `install-backup.sh --register` from the fresh setup wizard after base service readiness. `install-status.sh` reports separate lines:

```text
[OK] Backup systemd units are installed and disabled pending acceptance
[MANUAL] Configure the exact project bucket and complete backup/restore acceptance before enabling the timer.
```

If a valid config and active timer already exist, report `[OK] Backup configuration and timer`; otherwise do not turn the existing ThreadHub base readiness into a false failure.

- [ ] **Step 8: Run installer, wizard, systemd, and no-clobber tests**

Run: `./deploy/tests/backup-installer-test.sh && ./deploy/tests/notifier-installer-test.sh && ./deploy/scripts/validate.sh`

Expected: registration is idempotent and disabled; existing config/unit/OCI binaries are never silently replaced.

- [ ] **Step 9: Commit the gated installer**

```bash
git add deploy/versions.env deploy/scripts/configure-backup.sh deploy/scripts/install-backup.sh deploy/scripts/setup-wizard.sh deploy/scripts/install-status.sh deploy/systemd deploy/tests/backup-installer-test.sh
git commit -m "feat: install gated ThreadHub backup scheduling"
```

---

### Task 9: Prove backup and restore with the real pinned images

**Files:**
- Create: `deploy/integration/backup/run.sh`
- Create: `deploy/integration/backup/oci-stub.sh`
- Create: `deploy/integration/backup/seed-mattermost.sh`
- Create: `notifier/mailer/integration/backup-seed/main.go`
- Create: `deploy/tests/backup-integration-contract-test.sh`

**Interfaces:**
- Consumes: production `deploy/docker-compose.yml`, all backup/restore scripts, pinned images, and an ephemeral Ubuntu 24.04 runner.
- Produces: one safe line `BK-INTEGRATION-pass` or one allowlisted `BK-INTEGRATION-*` failure ID.
- The OCI stub implements only namespace/bucket get, object put/head/list/get and rejects every delete or non-configured bucket operation.

- [ ] **Step 1: Write failing integration-harness contract tests**

```bash
grep -F 'Mattermost Team Edition 11.7.7' deploy/integration/backup/run.sh
grep -F 'PostgreSQL 18.4' deploy/integration/backup/run.sh
grep -F 'source-root-unchanged' deploy/integration/backup/run.sh
grep -F 'notifier-old-mail-not-sent' deploy/integration/backup/run.sh
grep -F 'service-downtime-at-most-300' deploy/integration/backup/run.sh
grep -F 'restore-rto-at-most-14400' deploy/integration/backup/run.sh
grep -F 'privacy_patterns' deploy/integration/backup/run.sh
grep -F 'grep -R -F -q' deploy/integration/backup/run.sh
```

- [ ] **Step 2: Run the contract test and observe missing harness failure**

Run: `./deploy/tests/backup-integration-contract-test.sh`

Expected: FAIL because the integration files do not exist.

- [ ] **Step 3: Implement a real SQLite pending-queue seed helper**

Create a test-only Go command under `notifier/mailer/integration`, so Go internal-package rules permit importing `mailer/internal/store`. It accepts queue path and HMAC from protected environment, inserts one valid event with one pending recipient through `store.Accept`, and prints only `seeded=1`.

```go
event := protocol.Event{
	EventID: strings.Repeat("a", 26), PostID: strings.Repeat("b", 26),
	Permalink: "https://threadhub.integration.test/_redirect/pl/" + strings.Repeat("b", 26),
	OccurredAt: time.Now().Add(-time.Hour).UnixMilli(),
	Recipients: []protocol.Recipient{{UserID: strings.Repeat("c", 26), Email: "queue@integration.invalid"}},
}
_, err = queue.Accept(ctx, protocol.HashIdentifier(secret, "nonce", "backup-seed"), event, time.Now())
```

- [ ] **Step 4: Implement a deterministic no-delete OCI stub**

The stub records argv to a protected file, maps the configured namespace/bucket/object key into a temporary object root, supports paginated list JSON, and returns head keys `content-length`, `opc-content-sha256`, and `opc-meta-threadhub-sha256`. It rejects `delete`, path traversal, unknown bucket, missing `--auth instance_principal`, or a region other than `ap-singapore-1`.

- [ ] **Step 5: Seed Mattermost through supported APIs**

`seed-mattermost.sh` creates one admin and one member, one Team, one public channel, one private channel, root posts, one thread reply, and one uploaded file. Passwords and token stay in mode-0600 temporary files. The script writes only opaque IDs to a protected fixture file and emits no API response body.

- [ ] **Step 6: Implement the source backup half of the harness**

1. Require an ephemeral Ubuntu 24.04 GitHub runner and an absent `/srv/threadhub`.
2. Create protected fixture `deploy/.env` with a loopback-invalid SMTP host; never contact real SMTP.
3. Run `deploy.sh`, seed Mattermost, stop Mailer briefly, and seed one pending queue entry.
4. Run `backup.sh` through the OCI stub.
5. Assert remote daily set completeness, manifest/hash validity, status success, and downtime `<=300`.
6. Hash the source database logical projection, attachments, and queue; stop Compose; rename source root to an exact guarded temporary source path.

- [ ] **Step 7: Implement the fresh-root restore half**

1. Generate a new protected `.env` with a different DB password and HMAC.
2. Run `restore.sh BACKUP_ID` with the same OCI stub and an absent `/srv/threadhub`.
3. Log in with the restored Mattermost admin and compare users, Team, public/private channels, posts, thread, and downloaded file hash.
4. Confirm the quarantined queue hash equals the source queue hash.
5. Confirm the live queue is empty, control state is disabled, Mailer has no sent/failed aggregate, and the SMTP stub captured no old notification.
6. Re-hash the renamed source and assert it did not change.
7. Assert total restore time `<=14400` seconds.

- [ ] **Step 8: Add guarded cleanup and privacy scanning**

Cleanup only paths created under the harness's `mktemp` root plus exact `/srv/threadhub` after verifying an integration sentinel. Stop/remove only the unique Compose project name. Scan diagnostics, status, manifest, and public output for fixture passwords, HMAC, email, domain, message text, filenames, and fake OCIDs; translate any failure to an allowlisted ID.

- [ ] **Step 9: Run the real-image integration locally or in Linux Docker CI**

Run: `sudo --preserve-env=PATH ./deploy/integration/backup/run.sh`

Expected: exactly `BK-INTEGRATION-pass`; Mattermost 11.7.7 and PostgreSQL 18.4 containers are removed and no `/srv/threadhub` fixture remains.

- [ ] **Step 10: Run Go and harness regressions**

Run: `cd notifier && make fmt-check mod-verify vet test`, then `cd .. && ./deploy/tests/backup-integration-contract-test.sh && ./deploy/scripts/validate.sh`

Expected: all commands exit 0.

- [ ] **Step 11: Commit real-image proof**

```bash
git add deploy/integration/backup deploy/tests/backup-integration-contract-test.sh notifier/mailer/integration/backup-seed
git commit -m "test: prove ThreadHub backup and restore with pinned images"
```

---

### Task 10: Align public requirements, operations, and agent safety contracts

**Files:**
- Create: `deploy/docs/backup-restore.md`
- Create: `deploy/scripts/backup-documentation-contracts.sh`
- Create: `deploy/tests/backup-documentation-test.sh`
- Rename: `docs/threadhub-prd-v4.1-final.md` to `docs/threadhub-prd-v4.2-final.md`
- Modify: `README.md`
- Modify: `deploy/README.md`
- Modify: `AGENTS.md`
- Modify: `SECURITY.md`
- Modify: `deploy/docs/quick-install.md`
- Modify: `deploy/docs/setup.md`
- Modify: `deploy/docs/admin-guide.md`
- Modify: `deploy/docs/operations-checklist.md`
- Modify: `deploy/docs/project-close.md`
- Modify: `deploy/docs/oci-provisioning.md`
- Modify: `deploy/docs/test-plan.md`
- Modify: `deploy/scripts/notifier-documentation-contracts.sh`

**Interfaces:**
- Consumes: the approved design and implemented CLI names.
- Produces: one authoritative operator guide, PRD v4.2 alignment, and executable documentation contracts.
- Documentation uses placeholders only and never authorizes live OCI work.

- [ ] **Step 1: Write failing documentation contract fixtures**

```bash
reset_fixture
validate_backup_documentation_contracts "${fixture_root}"

reset_fixture
sed -i 's/new or empty \/srv\/threadhub/nonempty target allowed/' "${fixture_root}/deploy/docs/backup-restore.md"
assert_contract_failure 'non-empty restore prohibition was removed'

reset_fixture
sed -i 's/explicit user authorization/automatic IAM creation/' "${fixture_root}/AGENTS.md"
assert_contract_failure 'OCI approval boundary was removed'

reset_fixture
sed -i 's/timer remains disabled/timer starts immediately/' "${fixture_root}/deploy/docs/quick-install.md"
assert_contract_failure 'acceptance-before-timer order was removed'
```

- [ ] **Step 2: Run documentation tests and observe missing guide/contracts**

Run: `./deploy/tests/backup-documentation-test.sh`

Expected: FAIL because the backup guide and contract helper do not exist.

- [ ] **Step 3: Write the operator guide in exact operational order**

`deploy/docs/backup-restore.md` must contain these ordered sections:

1. Scope and guarantees: RPO 24h, RTO 4h, downtime 5m, no HA/PITR/cross-region.
2. OCI prerequisites: project-private bucket, Public Access blocked, default AES-256, exact-instance Dynamic Group, exact-bucket create/inspect/read policy, no VM delete.
3. Explicit authorization: tenancy-wide Dynamic Group/IAM and all live bucket/lifecycle work requires target compartment and `ap-singapore-1` approval.
4. Lifecycle: `daily/` 7 days, `weekly/` 28 days, incomplete multipart cleanup, best-effort deletion.
5. Configure and register: `configure-backup.sh`, `install-backup.sh --register`, timer disabled.
6. Manual first backup and `backup-status.sh`.
7. Disposable fresh-VM restore and queue-quarantine checks.
8. Interactive `--enable-after-acceptance BACKUP_ID` only after evidence review.
9. Daily/weekly checks, `--resume-upload`, stable failure classes, and generic email.
10. Project close and exact delete-approval boundary.

Include this policy template while labeling every value as a placeholder:

```text
ALL {instance.id = '<project-threadhub-instance-ocid>'}

Allow dynamic-group '<identity-domain>'/'<project-backup-dynamic-group>' to inspect buckets in compartment <project-compartment> where target.bucket.name = '<project-backup-bucket>'
Allow dynamic-group '<identity-domain>'/'<project-backup-dynamic-group>' to manage objects in compartment <project-compartment> where all {target.bucket.name = '<project-backup-bucket>', any {request.permission = 'OBJECT_CREATE', request.permission = 'OBJECT_INSPECT', request.permission = 'OBJECT_READ'}}
```

State that lifecycle service authorization is separate from the VM policy and must be generated/reviewed against current Oracle documentation before an approved live change.

- [ ] **Step 4: Add the backup-specific AGENTS.md contract**

Append an exact section requiring agents to read `backup-restore.md`, run `validate.sh` and backup preflight before VM changes, never show configs/data/status diagnostics, never restore a non-empty root, never enable the timer before manual restore evidence, and obtain explicit approval for every OCI/DNS/live-VM mutation. State that repository implementation work alone grants no live authorization.

- [ ] **Step 5: Update PRD to v4.2 without leaving contradictory backup claims**

Rename the file and make these semantic replacements:

- document version `v4.2 Final`; backup row `일일 Object Storage 백업, 수동 복구`;
- NG-12/13/14 become `무중단 백업`, `시점 복구(PITR)`, `리전 간 자동 복제`; NG-15 becomes `RPO 0·자동 장애복구 보장`;
- add goal G-12 for one daily application-consistent backup and fresh-VM recovery;
- replace `NFR-DATA-007` through `010` with remote-verified RPO, exact backup set, empty-target restore, queue quarantine, and post-backup data-loss caveats;
- replace section 17.5 with the approved daily/weekly retention, Instance Principal, 5-minute interruption, manual 4-hour RTO, and timer activation gate;
- change R-10 to `백업 실패·24시간 초과` with status/email/manual remediation and customer-file-pilot blocking;
- add acceptance conditions for remote verification, no-delete IAM, disposable restore, source immutability, and old-mail non-delivery;
- change Definition of Done item 45 so backup is implemented while central logging, monitoring, HA, cross-region, PITR, and mobile push remain later scope;
- add a v4.2 change table naming this design document as the controlling backup specification.

Update every repository link from `threadhub-prd-v4.1-final.md` to `threadhub-prd-v4.2-final.md`.

- [ ] **Step 6: Update installation and operational docs**

Make backup a separately gated post-install capability: base `[READY]` remains distinct, units register disabled, OCI prep/config/manual backup/disposable restore precede timer activation. Operations checklist must include last success `<24h`, daily/weekly object counts, staging use, timer result, and failure email. Project close must drain notifier first, then choose backup retention or explicitly approved complete bucket/IAM deletion.

- [ ] **Step 7: Implement executable documentation contracts**

`validate_backup_documentation_contracts` must verify all required files/links, ordered safety sequence, exact commands, RPO/RTO/downtime values, no-delete/empty-target/queue-quarantine language, OCI explicit-approval wording, and test IDs `BK-UNIT-*`, `BK-INT-*`, `BK-LIVE-*`. Source it from the existing documentation validation rather than duplicating shared helper logic.

- [ ] **Step 8: Run documentation mutation tests and global validation**

Run: `./deploy/tests/backup-documentation-test.sh && ./deploy/tests/notifier-documentation-test.sh && ./deploy/scripts/validate.sh && git grep -n 'v4.1\|자동 백업.*미구성\|백업·복구.*미제공' -- README.md deploy docs ':!docs/superpowers/specs/*' ':!docs/superpowers/plans/*'`

Expected: contract tests pass and the final grep returns no stale public product claim.

- [ ] **Step 9: Commit public documentation and contracts**

```bash
git add AGENTS.md README.md SECURITY.md deploy/README.md deploy/docs deploy/scripts/backup-documentation-contracts.sh deploy/scripts/notifier-documentation-contracts.sh deploy/tests/backup-documentation-test.sh docs/threadhub-prd-v4.2-final.md
git add -u docs/threadhub-prd-v4.1-final.md
git commit -m "docs: publish ThreadHub backup and recovery operations"
```

---

### Task 11: Wire CI gates and record privacy-safe automated evidence

**Files:**
- Modify: `deploy/scripts/validate.sh`
- Modify: `.github/workflows/validate.yml`
- Modify: `deploy/docs/test-results-public.md`

**Interfaces:**
- Consumes: every task above.
- Produces: required static/unit backup gates on all PRs and a separate Ubuntu real-image backup/restore job.
- Does not run live OCI acceptance in GitHub Actions.

- [ ] **Step 1: Write a failing validation-presence test**

```bash
for test in \
    backup-config-test.sh backup-oci-test.sh backup-artifacts-test.sh \
    backup-orchestration-test.sh data-layout-test.sh backup-restore-test.sh \
    backup-installer-test.sh backup-documentation-test.sh backup-integration-contract-test.sh; do
    grep -F "${test}" deploy/scripts/validate.sh >/dev/null || exit 1
done
grep -F 'backup-restore-integration' .github/workflows/validate.yml >/dev/null
```

- [ ] **Step 2: Run the presence test and observe missing validation wiring**

Run: `bash -c '<the Step 1 loop>'`

Expected: FAIL because `validate.sh` and CI do not invoke the backup tests.

- [ ] **Step 3: Add all static/fault tests to `validate.sh`**

Require every new production script executable, every example/unit/doc present, Bash syntax valid, config schema valid, timer installed disabled by default, and invoke the nine backup shell tests. Keep real-image integration out of local static validation.

- [ ] **Step 4: Extend ShellCheck and add the isolated CI job**

The existing ShellCheck glob already covers `deploy/scripts/*.sh` and `deploy/tests/*.sh`; add `deploy/integration/backup/*.sh`. Add job `backup-restore-integration` on `ubuntu-24.04`, timeout 40 minutes, checkout with history, set Go 1.25.14, install `zstd`, `jq`, `expect`, run unit/static validation, then execute the harness with sudo. Always run its guarded cleanup step.

```yaml
backup-restore-integration:
  runs-on: ubuntu-24.04
  timeout-minutes: 40
  steps:
    - uses: actions/checkout@fbc6f3992d24b796d5a048ff273f7fcc4a7b6c09
      with: {fetch-depth: 0}
    - uses: actions/setup-go@924ae3a1cded613372ab5595356fb5720e22ba16
      with: {go-version: 1.25.14, cache-dependency-path: notifier/go.sum}
    - run: sudo apt-get update && sudo apt-get install -y jq zstd
    - run: ./deploy/scripts/validate.sh
    - run: sudo --preserve-env=PATH ./deploy/integration/backup/run.sh
```

- [ ] **Step 5: Add a fixed public automated-evidence schema**

Add a `backup·restore 공개 자동 증거` table containing only test date, source commit, Mattermost digest, PostgreSQL digest, notifier version, backup scenario count, result. Never include bucket, namespace, OCID, domain, email, backup ID, object key, data size, user count, or filenames. Extend the documentation contract to reject extra columns.

- [ ] **Step 6: Run the full local verification suite**

Run:

```bash
./deploy/scripts/validate.sh
shellcheck -x -P deploy/scripts deploy/scripts/*.sh deploy/tests/*.sh deploy/integration/backup/*.sh
cd notifier
GOTOOLCHAIN=go1.25.14 make fmt-check mod-verify vet test
```

Expected: every command exits 0 with zero test failures and no private fixture value in output.

- [ ] **Step 7: Run the real-image integration and inspect its sole public result**

Run: `sudo --preserve-env=PATH ./deploy/integration/backup/run.sh`

Expected: exactly `BK-INTEGRATION-pass` and exit 0.

- [ ] **Step 8: Commit CI and evidence wiring**

```bash
git add deploy/scripts/validate.sh .github/workflows/validate.yml deploy/docs/test-results-public.md
git commit -m "ci: gate ThreadHub backup and restore"
```

- [ ] **Step 9: Perform final branch verification before review**

Run:

```bash
git diff --check origin/main...HEAD
git status --short --branch
git log --oneline --decorate origin/main..HEAD
./deploy/scripts/validate.sh
cd notifier && GOTOOLCHAIN=go1.25.14 make fmt-check mod-verify vet test
```

Expected: clean worktree, the planned commits only, and all validation commands exit 0.

Do not provision the bucket, alter Dynamic Groups/IAM Policies, enable an operational timer, run against any live ThreadHub hostname, or perform a live restore as part of repository implementation. Those are separate `BK-LIVE-*` acceptance steps requiring explicit authorization with the exact compartment and `ap-singapore-1` stated immediately before execution.

## Post-implementation live acceptance gate

This gate is deliberately not a repository commit task. Stop after Task 11 and obtain a new explicit authorization before every live mutation group.

- [ ] State the exact target compartment, `ap-singapore-1`, source VM, disposable restore VM, proposed private bucket name, Dynamic Group name, and IAM Policy name without writing those identifiers to Git.
- [ ] Obtain explicit permission for the regional bucket and lifecycle change separately from the region-independent Dynamic Group and IAM Policy change.
- [ ] Resolve the exact source instance OCID read-only; create a Dynamic Group matching that instance only; apply exact-bucket create/inspect/read policy with no delete.
- [ ] Create or verify the private Standard bucket, blocked Public Access, Oracle-managed AES-256 encryption, daily 7-day/weekly 28-day lifecycle, and multipart cleanup.
- [ ] Run `configure-backup.sh`, `install-backup.sh --register`, one manual `backup.sh`, `backup-status.sh --json`, exact-bucket success, cross-bucket deny, object-delete deny, bucket-delete deny, and generic failure-email acceptance.
- [ ] Obtain explicit permission to authorize the disposable restore VM through Instance Principal, then run the documented fresh-VM restore and manual account/Team/channel/message/thread/file checks.
- [ ] Confirm old notifier queue quarantine, no old email, source VM/data unchanged, downtime at most 300 seconds, and manual RTO at most 14,400 seconds in a private change record.
- [ ] Review the evidence with the user. Only then run `install-backup.sh --enable-after-acceptance BACKUP_ID` on the source VM.
- [ ] Check status daily for the first 7 days; after that, switch to the documented weekly operational review.
