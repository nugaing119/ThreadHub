# Existing Notifier v0.1.0 to v0.2.0 Transition Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build and prove a fail-closed, reversible transition from the one supported existing-adoption Notifier v0.1.0 profile to Notifier v0.2.0 with `project_team_channel` email context.

**Architecture:** Add a version-specific shell orchestration layer around the existing adoption, artifact, control, Compose, and plugin-pair libraries. Preserve the complete v0.1.0 runtime set before opening the queue with v0.2.0, use a read-only queue inspector and privacy-safe database aggregates for evidence, and leave the upgraded notifier disabled until SMTP and allowlist acceptance are complete.

**Tech Stack:** Bash 3.2-compatible orchestration and fixtures, Go 1.25.14, modernc SQLite, Docker Compose, Mattermost Team Edition 11.7.7, PostgreSQL 18.4, jq, GitHub Actions on Ubuntu 24.04 AMD64.

**Spec:** `docs/superpowers/specs/2026-09-10-existing-notifier-v010-to-v020-transition-design.md`

## Global Constraints

- Support only Ubuntu 24.04 AMD64, single-node Compose, Mattermost Team Edition 11.7.7, PostgreSQL 18.4, and the exact reviewed Notifier v0.1.0 source release.
- The accepted v0.1.0 source commit is `c193155eeb6298771d4366d6af4cae81499487b8`; the installed release metadata, plugin pair, and Mailer image ID must agree with it.
- The target is the clean checked-out reviewed Notifier v0.2.0 release and `THN_CONTENT_MODE=project_team_channel`.
- Never choose behavior by hostname and never introduce a third deployment profile.
- Never modify the base Compose file, base environment file, Mattermost image, PostgreSQL image, or existing persistent-data layout.
- Never display, copy into public output, or commit credentials, protected environment values, queue contents, Team or channel identifiers, user data, post data, file data, backup IDs, or diagnostics.
- Exit code 20 always means `[ACTION REQUIRED]`; no caller may convert it to success.
- Preserve pending, sending, failed, sent, cancelled, and quarantined delivery evidence. Do not silently retry, cancel, replay, or delete deliveries.
- Install v0.2.0 disabled. SMTP acceptance and a public/private allowlist pilot precede a separately approved `all_channels` activation.
- Production access and mutation are outside this repository implementation plan and require a separate exact-instance approval.
- Use `apply_patch` for repository edits, keep unrelated work untouched, and commit each completed task independently.

---

## File and Interface Map

### New files

- `deploy/scripts/existing-notifier-v010-v020-common.sh`: exact source/target constants, legacy configuration parsing, release-state checks, protected evidence paths, aggregate helpers, and shared fail-closed primitives.
- `deploy/scripts/existing-notifier-v010-v020-preflight.sh`: read-only source-profile and recovery-gate validation.
- `deploy/scripts/existing-notifier-v010-v020-recovery-gate.sh`: interactive creation and non-mutating validation of the private backup/restore review attestation.
- `deploy/scripts/existing-notifier-v010-v020-transaction.sh`: hook-driven transition and automatic recovery state machine.
- `deploy/scripts/existing-notifier-v010-v020-upgrade.sh`: production-facing upgrade entry point; prepares the target while live, then drains, disables, captures, transitions, and stops for acceptance.
- `deploy/scripts/existing-notifier-v010-v020-rollback.sh`: production-facing exact v0.1.0 recovery entry point.
- `deploy/tests/existing-notifier-v010-v020-preflight-test.sh`: config, profile, release, recovery-gate, and read-only behavior tests.
- `deploy/tests/existing-notifier-v010-v020-evidence-test.sh`: queue snapshot, configuration preimage, release/override/image capture, aggregate, permission, and privacy tests.
- `deploy/tests/existing-notifier-v010-v020-transaction-test.sh`: phase ordering and failure-injection recovery tests.
- `deploy/tests/existing-notifier-v010-v020-operations-test.sh`: upgrade/rollback entry-point and exit-code contracts.
- `notifier/integration/run-existing-upgrade.sh`: exact real-image v0.1.0-to-v0.2.0 transition and rollback harness.
- `notifier/integration/existing-upgrade-scenario-ids.txt`: fixed privacy-safe scenario IDs.
- `notifier/integration/existing_upgrade_contract_test.go`: static integration and CI contract.

### Modified files

- `notifier/mailer/internal/store/store.go`: add non-mutating queue inspection.
- `notifier/mailer/internal/store/store_test.go`: prove schema-v1/v2 inspection and no migration during inspection.
- `notifier/mailer/cmd/threadhub-mailer/main.go`: expose fixed-path `queue-inspect --json` before runtime configuration loading.
- `notifier/mailer/cmd/threadhub-mailer/main_test.go`: prove privacy-safe output and command isolation.
- `deploy/scripts/notifier-documentation-contracts.sh`: require the exact transition, rollback, acceptance, and safety language.
- `deploy/scripts/validate.sh`: run the new shell suites and require all new executable paths.
- `notifier/integration/existing_adoption_contract_test.go`: keep initial adoption contracts distinct from upgrade contracts.
- `.github/workflows/validate.yml`: add a real-image existing-upgrade job with privacy-safe evidence upload.
- `deploy/docs/canonical-runtime-standard.md`: promote the exact supported source from `legacy-held` to `migration-ready` only after repository gates pass.
- `deploy/docs/existing-mattermost-notifier.md`: replace the unsafe manual key addition/initial-setup wording with exact transition commands.
- `deploy/docs/test-plan.md`: add version-transition scenario definitions.
- `deploy/docs/test-results-public.md`: add only aggregate pass/fail evidence after CI succeeds.

### Stable interfaces produced by this plan

```text
store.Inspect(path string) (store.Inspection, error)
/threadhub-mailer queue-inspect --json
existing_notifier_v010_v020_preflight
existing_notifier_v010_v020_capture_evidence ATTEMPT_ROOT
existing_notifier_v010_v020_capture_baseline OUTPUT_FILE
existing_notifier_v010_v020_transaction ATTEMPT_ROOT
existing-notifier-v010-v020-preflight.sh
existing-notifier-v010-v020-upgrade.sh
existing-notifier-v010-v020-rollback.sh
```

---

### Task 1: Add a read-only, privacy-safe queue inspector

**Files:**
- Modify: `notifier/mailer/internal/store/store.go`
- Modify: `notifier/mailer/internal/store/store_test.go`
- Modify: `notifier/mailer/cmd/threadhub-mailer/main.go`
- Modify: `notifier/mailer/cmd/threadhub-mailer/main_test.go`

**Interfaces:**
- Consumes: the existing SQLite schema and fixed container queue path `/var/lib/threadhub-notifier/queue.db`.
- Produces: `store.Inspection`, `store.Inspect(path)`, and `/threadhub-mailer queue-inspect --json`.

- [ ] **Step 1: Write failing store inspection tests**

Add tests beside `TestOpenMigratesExistingSchemaV1WithoutDroppingQueuedData` that seed schema v1 directly, call `Inspect`, and then reopen the database with `database/sql` to prove the schema is still v1.

```go
func TestInspectReportsSchemaV1WithoutMigrating(t *testing.T) {
	path := filepath.Join(t.TempDir(), "queue.db")
	db, err := sql.Open("sqlite", path)
	if err != nil { t.Fatal(err) }
	if _, err = db.Exec(schemaBootstrap); err != nil { t.Fatal(err) }
	if _, err = db.Exec("INSERT INTO schema_version(version) VALUES (1)"); err != nil { t.Fatal(err) }
	if _, err = db.Exec(`INSERT INTO events(event_hash, occurred_at_ms, accepted_at_ms)
		VALUES(?, 1, 1)`, strings.Repeat("a", 64)); err != nil { t.Fatal(err) }
	if _, err = db.Exec(`INSERT INTO deliveries(
		event_hash, recipient_hash, status, next_attempt_at_ms, updated_at_ms)
		VALUES(?, ?, 'pending', 1, 1)`, strings.Repeat("a", 64), strings.Repeat("b", 64)); err != nil { t.Fatal(err) }
	if err = db.Close(); err != nil { t.Fatal(err) }
	if err = os.Chmod(path, 0o600); err != nil { t.Fatal(err) }

	got, err := Inspect(path)
	if err != nil { t.Fatalf("Inspect() error = %v", err) }
	if got.SchemaVersion != 1 || got.Events != 1 || got.Pending != 1 {
		t.Fatalf("Inspect() = %+v", got)
	}
	db, err = sql.Open("sqlite", path)
	if err != nil { t.Fatal(err) }
	defer db.Close()
	var version int
	if err = db.QueryRow("SELECT version FROM schema_version").Scan(&version); err != nil { t.Fatal(err) }
	if version != 1 { t.Fatalf("inspection migrated schema to %d", version) }
}
```

Also cover schema v2, corrupt schema, multiple version rows, symlink input, mode other than `0600`, and an unexpected delivery status.

- [ ] **Step 2: Run the store package test and confirm the new symbol is absent**

Run:

```bash
go -C notifier test ./mailer/internal/store -run 'TestInspect' -count=1
```

Expected: FAIL because `Inspect` and `Inspection` do not exist.

- [ ] **Step 3: Implement read-only inspection**

Add a fixed aggregate type and open with SQLite read-only/query-only settings. Do not call `Open` or `initialize`.

```go
type Inspection struct {
	SchemaVersion int   `json:"schema_version"`
	Events        int64 `json:"events"`
	Nonces        int64 `json:"nonces"`
	Pending       int64 `json:"pending"`
	Sending       int64 `json:"sending"`
	Sent          int64 `json:"sent"`
	Failed        int64 `json:"failed"`
	Cancelled     int64 `json:"cancelled"`
}

func Inspect(path string) (Inspection, error) {
	if !filepath.IsAbs(path) { return Inspection{}, ErrInvalidStore }
	if err := requirePrivateRegularDatabase(path); err != nil { return Inspection{}, err }
	dsn := (&url.URL{Scheme: "file", Path: path, RawQuery: "mode=ro&_pragma=query_only(1)&_pragma=busy_timeout(5000)"}).String()
	db, err := sql.Open("sqlite", dsn)
	if err != nil { return Inspection{}, fmt.Errorf("inspect sqlite: %w", err) }
	defer db.Close()
	// Query one schema-version row and aggregate only counts. Reject every
	// schema version except 1 and 2 and every status outside the fixed enum.
}
```

Factor the current path checks so both `Open` and `Inspect` enforce a regular
database, a non-symlink parent, and mode `0600`, while only `Open` may create a
missing database.

- [ ] **Step 4: Add failing CLI tests**

Extend `commandOperations` with:

```go
inspectQueue func(string) (store.Inspection, error)
```

Add tests asserting that `queue-inspect --json` works without loading SMTP or
HMAC configuration and emits exactly the `Inspection` JSON keys. Include a
protected string in the test environment and assert it is absent from stdout
and stderr.

- [ ] **Step 5: Run the CLI test and confirm command parsing fails**

Run:

```bash
go -C notifier test ./mailer/cmd/threadhub-mailer -run 'QueueInspect' -count=1
```

Expected: FAIL because `queue-inspect --json` is not accepted.

- [ ] **Step 6: Implement the fixed-path CLI command**

Handle the command before `config.Load`:

```go
const queuePath = "/var/lib/threadhub-notifier/queue.db"

if command == "queue-inspect" {
	inspection, err := operations.inspectQueue(queuePath)
	if err != nil { return err }
	return json.NewEncoder(stdout).Encode(inspection)
}
```

Accept only the exact two-argument form `queue-inspect --json`. Error output
continues to be the existing generic `threadhub-mailer: command failed` line.

- [ ] **Step 7: Run focused and full Go tests**

Run:

```bash
go -C notifier test ./mailer/internal/store ./mailer/cmd/threadhub-mailer -count=1
go -C notifier test ./... -count=1
```

Expected: PASS with no race, schema, or disclosure failure.

- [ ] **Step 8: Commit Task 1**

```bash
git add notifier/mailer/internal/store/store.go \
  notifier/mailer/internal/store/store_test.go \
  notifier/mailer/cmd/threadhub-mailer/main.go \
  notifier/mailer/cmd/threadhub-mailer/main_test.go
git commit -m "feat: add read-only notifier queue inspection"
```

---

### Task 2: Add the exact v0.1.0 profile and read-only preflight

**Files:**
- Create: `deploy/scripts/existing-notifier-v010-v020-common.sh`
- Create: `deploy/scripts/existing-notifier-v010-v020-preflight.sh`
- Create: `deploy/tests/existing-notifier-v010-v020-preflight-test.sh`

**Interfaces:**
- Consumes: the legacy 18-key `deploy/existing-notifier.env`, current v0.1.0 release metadata, live plugin pair, v0.1.0 Mailer status, current Compose model, and a protected recovery gate.
- Produces: `existing_notifier_v010_v020_preflight` and a read-only CLI that exits 0 only for the exact supported source.

- [ ] **Step 1: Write the failing profile/config tests**

Build the fixture by copying the existing preflight fixture shape but omit
`THN_CONTENT_MODE`. Assert:

```bash
test_legacy_config_has_exact_keyset() (
    prepare_upgrade_fixture
    [[ "$(existing_notifier_v010_v020_config_state "${legacy_env}")" == source ]]
)

test_partial_or_current_config_is_not_a_source() (
    prepare_upgrade_fixture
    printf '%s\n' 'THN_CONTENT_MODE=project_team_channel' >>"${legacy_env}"
    [[ "$(existing_notifier_v010_v020_config_state "${legacy_env}")" == target ]]
    sed -i.bak '/^THN_SMTP_PORT=/d' "${legacy_env}"
    ! existing_notifier_v010_v020_config_state "${legacy_env}"
)
```

Cover duplicate keys, unknown keys, CRLF, symlinks, mode `0644`, and changes to
the config identity between initial and final checks.

- [ ] **Step 2: Run the new suite and confirm it fails because files are absent**

Run:

```bash
./deploy/tests/existing-notifier-v010-v020-preflight-test.sh
```

Expected: FAIL because the common and preflight scripts do not exist.

- [ ] **Step 3: Implement exact constants and legacy-safe parsing**

Define immutable constants in the common library:

```bash
readonly EXISTING_NOTIFIER_V010_V020_ID=existing-notifier-v010-v020
readonly EXISTING_NOTIFIER_V010_VERSION=0.1.0
readonly EXISTING_NOTIFIER_V010_SOURCE_COMMIT=c193155eeb6298771d4366d6af4cae81499487b8
readonly EXISTING_NOTIFIER_V020_VERSION=0.2.0
readonly EXISTING_NOTIFIER_V010_MATTERMOST_VERSION=11.7.7
readonly EXISTING_NOTIFIER_V010_POSTGRES_VERSION=18.4
readonly EXISTING_NOTIFIER_V020_CONTENT_MODE=project_team_channel
```

Keep a separate `EXISTING_NOTIFIER_V010_KEYS` array matching the 18-key v0.1.0
file. `existing_notifier_v010_v020_config_state FILE` returns only `source` or
`target`; invalid input returns nonzero without printing values. Reuse path,
domain, email, rate, and root-disjoint validation from the existing common
library through a mode-specific wrapper, not by weakening the current 19-key
validator.

- [ ] **Step 4: Add source release, image, plugin, and queue-state tests**

Fixture the source release with version `0.1.0`, the exact source commit, a
valid bundle SHA, and a Mailer image ID. Assert the preflight rejects:

- any other source commit or version;
- release/plugin bundle SHA mismatch;
- release/Mailer image ID mismatch;
- incomplete runtime/bundle pairs;
- an inactive or duplicate plugin;
- nonzero pending, sending, or failed counts only when upgrade execution asks
  for the mutation gate; read-only inventory may report them without changing
  state;
- Mattermost other than Team Edition 11.7.7;
- PostgreSQL other than 18.4 or an ambiguous PostgreSQL service;
- a changed or unsupported Compose model.

- [ ] **Step 5: Implement the read-only preflight**

The entry point accepts no mutation flags:

```bash
existing_notifier_v010_v020_preflight_entry() {
    [[ "$#" -eq 0 ]] || die "Usage: $0"
    existing_notifier_v010_v020_preflight
}
```

The preflight must:

1. validate the legacy environment file without sourcing it;
2. create a mode-0600 temporary target-shaped copy only for reuse of topology
   validators;
3. run `docker compose config --quiet` and inspect JSON into a mode-0600 temp
   file;
4. require one Mattermost 11.7.7 Team Edition container and one PostgreSQL 18.4
   service with explicit bind mounts;
5. require the exact active v0.1.0 plugin pair and release metadata;
6. compare the running `threadhub/notifier-mailer:0.1.0` image ID to the release;
7. read only aggregate Mailer status;
8. validate a protected recovery gate with exactly the schema, profile, source
   commit, four true review booleans, and RFC3339 UTC timestamp defined below;
   a missing, expired, unsafe, or malformed gate returns exit 20;
9. recheck config, release, pair, and Compose input identities before success.

Public output is restricted to fixed `[OK]` labels and `[ACTION REQUIRED]`
classes.

The common library validator accepts exactly this envelope so Task 3 can add
the interactive creator without changing the preflight interface:

```json
{
  "schema": 1,
  "profile": "existing-notifier-v010-v020",
  "source_release_commit": "c193155eeb6298771d4366d6af4cae81499487b8",
  "remote_backup_verified": true,
  "disposable_restore_verified": true,
  "aggregate_match_verified": true,
  "restored_queue_quarantined": true,
  "reviewed_at_utc": "2026-09-10T00:00:00Z"
}
```

The default gate path is:

```text
${THN_DATA_ROOT}/migration/recovery-gate-v010-v020.json
```

It is separate from the no-clobber transition attempt directory.

- [ ] **Step 6: Prove read-only behavior**

Hash the fixture base Compose, base env, legacy notifier env, release,
plugin pair, queue, and control state before and after preflight. Assert all
hashes match and no migration/evidence directory was created.

- [ ] **Step 7: Run the focused suite**

Run:

```bash
./deploy/tests/existing-notifier-v010-v020-preflight-test.sh
```

Expected: every profile, privacy, and no-mutation assertion prints `ok` and the
script exits 0.

- [ ] **Step 8: Commit Task 2**

```bash
git add deploy/scripts/existing-notifier-v010-v020-common.sh \
  deploy/scripts/existing-notifier-v010-v020-preflight.sh \
  deploy/tests/existing-notifier-v010-v020-preflight-test.sh
git commit -m "feat: gate the exact legacy notifier profile"
```

---

### Task 3: Capture recovery attestation, queue evidence, and privacy-safe baselines

**Files:**
- Create: `deploy/scripts/existing-notifier-v010-v020-recovery-gate.sh`
- Modify: `deploy/scripts/existing-notifier-v010-v020-common.sh`
- Create: `deploy/tests/existing-notifier-v010-v020-evidence-test.sh`

**Interfaces:**
- Consumes: a human-reviewed remote backup/disposable restore, stopped v0.1.0 Mailer, source release/override/plugin/image/config/control objects, and the exact PostgreSQL service.
- Produces: a root-only recovery gate, a no-clobber transition evidence root, schema-v1 queue snapshot, source Mailer archive, and aggregate baseline JSON.

- [ ] **Step 1: Write failing recovery-gate tests**

Define the accepted JSON envelope:

```json
{
  "schema": 1,
  "profile": "existing-notifier-v010-v020",
  "source_release_commit": "c193155eeb6298771d4366d6af4cae81499487b8",
  "remote_backup_verified": true,
  "disposable_restore_verified": true,
  "aggregate_match_verified": true,
  "restored_queue_quarantined": true,
  "reviewed_at_utc": "2026-09-10T00:00:00Z"
}
```

Tests require exact keys, booleans, profile, commit, RFC3339 UTC timestamp,
root ownership in privileged fixtures, mode `0600`, regular file, no symlink,
and an age no greater than seven days. Extra keys and public identifiers fail.

- [ ] **Step 2: Run the evidence suite and confirm the gate command is absent**

Run:

```bash
./deploy/tests/existing-notifier-v010-v020-evidence-test.sh
```

Expected: FAIL because recovery-gate and evidence functions do not exist.

- [ ] **Step 3: Implement interactive attestation creation**

`existing-notifier-v010-v020-recovery-gate.sh record` requires a real TTY and
the exact confirmation:

```text
I REVIEWED THE BACKUP AND DISPOSABLE RESTORE
```

It writes the JSON through a mode-0600 same-directory temporary file and a
no-clobber hard-link publication. It never accepts the confirmation from an
argument, environment value, pipe, or non-interactive stdin. `check` performs
validation without mutation. The parent `${THN_DATA_ROOT}/migration` is
root-owned mode `0700`; the gate is
`${THN_DATA_ROOT}/migration/recovery-gate-v010-v020.json`.

- [ ] **Step 4: Write failing queue/evidence capture tests**

Use fixture operations and assert the required ordering:

```text
control-disabled
mailer-stopped
queue-inspected-v1
queue-captured
source-plugin-pair-captured
source-mailer-image-saved
source-release-captured
source-override-captured
source-env-captured
source-control-captured
baseline-captured
evidence-verified
```

Assert capture refuses a running Mailer, schema other than 1, unsafe ownership,
symlinks, existing destinations, insufficient image archive, and a second
attempt root. Include queue files `queue.db`, `queue.db-wal`, and `queue.db-shm`
when present.

- [ ] **Step 5: Implement protected evidence capture**

Use a fixed root derived from `THN_DATA_ROOT`:

```text
${THN_DATA_ROOT}/migration/existing-notifier-v010-v020
```

Create it root-owned mode `0700`; reject any existing path or symlink. Capture:

- full v0.1.0 plugin runtime and filestore bundle through
  `notifier_plugin_capture_pair`;
- `docker image save` of the exact v0.1.0 Mailer image plus expected image ID;
- complete v0.1.0 release directory;
- complete existing `compose.override.yml`;
- exact notifier environment and control-state preimages;
- the stopped Mailer directory containing the SQLite database and WAL/SHM;
- SHA-256 and mode/owner metadata for every captured object;
- the pre-transition aggregate baseline and phase state.

Expose the exact shell signature:

```bash
existing_notifier_v010_v020_capture_evidence ATTEMPT_ROOT
```

It derives every source path from the already validated legacy configuration;
no caller supplies plugin, queue, release, override, environment, or control
paths independently.

Do not tar or print secret-bearing files into diagnostics. Keep every capture
under mode `0700`/`0600` paths and verify it by reading from the protected copy.

- [ ] **Step 6: Implement privacy-safe database aggregate capture**

Require the exact `postgres` service and execute a fixed query inside the
container using its configured `POSTGRES_USER` and `POSTGRES_DB` environment:

```sql
SELECT json_build_object(
  'teams', (SELECT count(*) FROM teams),
  'channels', (SELECT count(*) FROM channels),
  'channel_members', (SELECT count(*) FROM channelmembers),
  'active_users', (SELECT count(*) FROM users WHERE deleteat = 0 AND username <> 'system-bot'),
  'inactive_users', (SELECT count(*) FROM users WHERE deleteat <> 0 AND username <> 'system-bot'),
  'posts', (SELECT count(*) FROM posts),
  'files', (SELECT count(*) FROM fileinfo)
);
```

Validate exact JSON keys and nonnegative integers. Store mode `0600`; do not
include names, IDs, email addresses, message text, paths, or filenames.

- [ ] **Step 7: Run the evidence tests**

Run:

```bash
./deploy/tests/existing-notifier-v010-v020-evidence-test.sh
```

Expected: PASS for capture, privacy, no-clobber, age, and aggregate contracts.

- [ ] **Step 8: Commit Task 3**

```bash
git add deploy/scripts/existing-notifier-v010-v020-common.sh \
  deploy/scripts/existing-notifier-v010-v020-recovery-gate.sh \
  deploy/tests/existing-notifier-v010-v020-evidence-test.sh
git commit -m "feat: capture protected notifier transition evidence"
```

---

### Task 4: Implement the hook-driven transition and automatic recovery transaction

**Files:**
- Create: `deploy/scripts/existing-notifier-v010-v020-transaction.sh`
- Create: `deploy/tests/existing-notifier-v010-v020-transaction-test.sh`
- Modify: `deploy/scripts/existing-notifier-v010-v020-common.sh`

**Interfaces:**
- Consumes: verified target release staging, a complete Task 3 source capture, and `v010_v020_tx_*` hook operations.
- Produces: `existing_notifier_v010_v020_transaction ATTEMPT_ROOT` and a disabled, verified v0.2.0 runtime or a disabled, verified v0.1.0 recovery.

- [ ] **Step 1: Write the phase-order test**

Stub each operation into a call log and assert this exact order:

```text
verify-source-capture
verify-target-release
publish-target-env
publish-target-release
publish-target-override
publish-target-plugin-pair
start-target-mailer
inspect-target-queue-v2
recreate-target-mattermost
verify-target-pair
capture-after-baseline
compare-baseline
verify-disabled
mark-target-ready
```

The fixture `v010_v020_tx_*` functions must be separate functions so each
boundary can be failed deterministically.

- [ ] **Step 2: Run the transaction test and confirm the function is absent**

Run:

```bash
./deploy/tests/existing-notifier-v010-v020-transaction-test.sh
```

Expected: FAIL because the transaction library does not exist.

- [ ] **Step 3: Implement atomic phase state**

Persist a strict state envelope after every successful boundary:

```json
{
  "schema": 1,
  "transition": "existing-notifier-v010-v020",
  "phase": "source_captured",
  "source_version": "0.1.0",
  "target_version": "0.2.0",
  "delivery_enabled": false
}
```

Allow only the documented phase enum. Write through same-directory temporary
files, mode `0600`, with no overwrite races. An unknown or partial state returns
exit 20 before additional mutation.

- [ ] **Step 4: Implement the transition function using existing pair transactions**

Source `notifier-plugin-transaction.sh` and adapt its hook interface rather
than implementing another plugin swap. The outer transaction owns environment,
release, override, Mailer image, and queue recovery; the existing inner
transaction owns the runtime/bundle plugin pair and Mattermost restart.

The target environment is produced by copying the exact source lines and
appending only:

```text
THN_CONTENT_MODE=project_team_channel
```

Publish it with `runtime_env_replace_if_unchanged`. Publish release and override
with no-clobber displaced paths kept inside the protected attempt root until
target verification completes.

- [ ] **Step 5: Write failure-injection assertions for every boundary**

For every `v010_v020_tx_*` hook, set `FIXTURE_FAIL_STEP` to that name and assert:

- control remains disabled;
- v0.1.0 plugin runtime and bundle hashes match the source capture;
- v0.1.0 environment, release, and override hashes match their preimages;
- schema-v1 queue hash and aggregate counts match the source snapshot;
- v0.1.0 Mailer image ID is available, loading the saved image if necessary;
- target objects are quarantined and not deleted;
- incomplete automatic recovery exits 70;
- complete automatic recovery returns the original nonzero result;
- no failure path prints fixture secrets or identifiers.

- [ ] **Step 6: Add signal and kill-recovery tests**

Exercise `TERM` at the target environment, release, queue migration, and plugin
publication boundaries. A normal signal invokes the rollback trap. A simulated
unclean interruption leaves a valid phase state and causes the next invocation
to return `[ACTION REQUIRED]` with the exact rollback command; it must not
resume implicitly.

- [ ] **Step 7: Run the transaction suite**

Run:

```bash
./deploy/tests/existing-notifier-v010-v020-transaction-test.sh
```

Expected: PASS for phase order, every injected fault, interruption, idempotent
rejection, and privacy scan.

- [ ] **Step 8: Commit Task 4**

```bash
git add deploy/scripts/existing-notifier-v010-v020-common.sh \
  deploy/scripts/existing-notifier-v010-v020-transaction.sh \
  deploy/tests/existing-notifier-v010-v020-transaction-test.sh
git commit -m "feat: transact legacy notifier upgrades"
```

---

### Task 5: Add production-facing upgrade and rollback commands

**Files:**
- Create: `deploy/scripts/existing-notifier-v010-v020-upgrade.sh`
- Create: `deploy/scripts/existing-notifier-v010-v020-rollback.sh`
- Create: `deploy/tests/existing-notifier-v010-v020-operations-test.sh`
- Modify: `deploy/scripts/existing-notifier-v010-v020-common.sh`

**Interfaces:**
- Consumes: Tasks 1–4 plus existing artifact build, overlay, control, status, SMTP, and plugin libraries.
- Produces: the two exact operator entry points and a safe `[ACTION REQUIRED]` handoff to SMTP/allowlist acceptance.

- [ ] **Step 1: Write failing upgrade orchestration tests**

Stub the upgrade phases and assert:

```text
preflight
prepare-target-release
recheck-preflight
drain
queue-zero
disable
control-loaded-disabled
stop-mailer
capture-evidence
transaction
post-status-disabled
action-required-smtp
```

The target release build occurs before drain so Docker build time does not
extend the Mattermost reconnect window. Assert an artifact build failure leaves
the live notifier enabled and untouched. Assert every later failure leaves it
disabled or restores the exact disabled v0.1.0 set.

- [ ] **Step 2: Run the operations suite and confirm entry points are absent**

Run:

```bash
./deploy/tests/existing-notifier-v010-v020-operations-test.sh
```

Expected: FAIL because upgrade and rollback entry points do not exist.

- [ ] **Step 3: Implement target release preparation**

Require a clean repository and current `NOTIFIER_VERSION=0.2.0`. Build into a
protected staging release directory using `notifier_build_artifacts`. Verify:

- target release source commit equals current `HEAD`;
- bundle SHA matches the built bundle;
- Mailer tag and image ID match the built image;
- plugin metadata is version 0.2.0 and min server version 11.7.7;
- the target Mailer supports `queue-inspect --json`;
- source release and live runtime identities have not changed during the build.

- [ ] **Step 4: Implement drain/disable/capture/transition**

Call the existing control primitives. Require `pending=0`, `sending=0`, and
`failed=0`; unlike the generic rollback command, this exact transition accepts
no `--cancel-failed` shortcut. Failed deliveries require an operator decision
before rerunning. Verify both plugin and Mailer loaded the disabled state before
stopping the Mailer and capturing evidence.

After a successful transaction, emit only:

```text
[ACTION REQUIRED] Run ./deploy/scripts/existing-notifier-smtp-test.sh, then activate a public/private test-channel allowlist.
```

Return exit 20. Do not activate an allowlist or `all_channels`.

- [ ] **Step 5: Implement exact rollback**

Rollback accepts no force flag. It requires:

- a valid complete capture and known phase;
- control disabled;
- zero pending, sending, and failed work in the current v0.2 queue;
- explicit review if pilot events have been accepted;
- exact target pair/release identity before quarantine;
- an empty no-clobber destination for each restored source object.

Restore queue, image, environment, release, override, and plugin pair as one
outer recovery operation. Start Mattermost and the v0.1.0 Mailer disabled,
verify health, compare the pre-transition aggregate, and keep all v0.2 objects
quarantined.

- [ ] **Step 6: Test user-facing exit and disclosure behavior**

Cover:

- exit 20 preflight and recovery-gate handoffs;
- exit 20 after a successful disabled target install;
- exit 70 for incomplete recovery;
- no secret values in argv, stdout, stderr, status, or diagnostics;
- a 30–60 second reconnect warning before the first Mattermost recreation;
- no base Compose/env writes;
- no destructive Docker volume flags;
- no hostname matching;
- no automatic `all_channels` activation.

- [ ] **Step 7: Run focused and existing regression suites**

Run:

```bash
./deploy/tests/existing-notifier-v010-v020-operations-test.sh
./deploy/tests/existing-notifier-operations-test.sh
./deploy/tests/existing-notifier-plugin-test.sh
./deploy/tests/existing-notifier-setup-test.sh
```

Expected: all tests pass and the initial adoption behavior is unchanged.

- [ ] **Step 8: Commit Task 5**

```bash
git add deploy/scripts/existing-notifier-v010-v020-common.sh \
  deploy/scripts/existing-notifier-v010-v020-upgrade.sh \
  deploy/scripts/existing-notifier-v010-v020-rollback.sh \
  deploy/tests/existing-notifier-v010-v020-operations-test.sh
git commit -m "feat: add controlled legacy notifier transition commands"
```

---

### Task 6: Prove the exact transition with real images

**Files:**
- Create: `notifier/integration/run-existing-upgrade.sh`
- Create: `notifier/integration/existing-upgrade-scenario-ids.txt`
- Create: `notifier/integration/existing_upgrade_contract_test.go`
- Modify: `notifier/integration/existing_adoption_contract_test.go`
- Modify: `.github/workflows/validate.yml`

**Interfaces:**
- Consumes: exact source commit, existing-adoption Compose fixture, existing acceptance binary, SMTP fixture, and Tasks 1–5.
- Produces: fixed scenario evidence proving forward transition, fault rollback, explicit rollback, and a clean second transition.

- [ ] **Step 1: Add failing integration contract tests**

Define 12 fixed scenarios:

```text
NF-UPGRADE-01
NF-UPGRADE-02
NF-UPGRADE-03
NF-UPGRADE-04
NF-UPGRADE-05
NF-UPGRADE-06
NF-UPGRADE-07
NF-UPGRADE-08
NF-UPGRADE-09
NF-UPGRADE-10
NF-UPGRADE-11
NF-UPGRADE-12
```

The Go contract test requires the runner to contain the exact source commit,
versions, `queue-inspect --json`, v1/v2 schema assertions, environment/release/
override hashes, aggregate comparison, failure injection, explicit rollback,
second transition, disabled target state, SMTP acceptance, allowlist activation,
and no `activate-all-channels` call.

- [ ] **Step 2: Run the integration contract test and confirm files are absent**

Run:

```bash
go -C notifier test ./integration -run 'ExistingUpgrade' -count=1
```

Expected: FAIL because the runner and scenario file do not exist.

- [ ] **Step 3: Build the exact v0.1.0 source fixture**

In the runner, require a clean full-history checkout, then export the source
commit without modifying the working tree:

```bash
git -C "${repository_root}" archive --format=tar \
  c193155eeb6298771d4366d6af4cae81499487b8 \
  | tar -xf - -C "${source_root}"
```

Create a protected v0.1 fixture `.env` pointing only to the integration temp
root and invoke the archived v0.1 artifact builder. Verify the resulting
release commit, bundle hash, and Mailer image ID before installing the v0.1
pair. Do not check out or reset the main worktree.

- [ ] **Step 4: Seed realistic non-sensitive state and schema-v1 work**

Use the existing acceptance binary to create Team, active/inactive users,
public/private channels, membership, root posts, thread replies, and a file.
Install and enable the v0.1 plugin/Mailer in `all_channels`, send fixture events,
and force a temporary SMTP failure so the schema-v1 queue contains at least one
pending delivery. Recover SMTP and drain to zero before the actual transition,
leaving sent history in the queue for preservation checks.

- [ ] **Step 5: Exercise the successful disabled transition**

Create the protected recovery gate fixture, capture base Compose/env hashes and
privacy-safe database aggregates, and run the upgrade. Assert exit 20 at the
SMTP handoff, schema version 2, preserved event/delivery counts, exact v0.2.0
release/pair/image, `project_team_channel`, disabled control, healthy
Mattermost/PostgreSQL/Mailer, and byte-identical base Compose/env files.

- [ ] **Step 6: Exercise context acceptance and explicit rollback**

Run SMTP acceptance, enable only the fixture public/private channels, and test
root/thread events. The SMTP fixture must confirm project/server, Team, channel,
and event type while rejecting body, author, filename, unrelated recipient,
and non-allowlist events. Drain and disable, run the exact rollback, then prove
the source v0.1.0 pair/image/config/override/release/schema-v1 queue and database
aggregates are restored.

- [ ] **Step 7: Exercise failure recovery and a second transition**

In a fresh integration root, inject failure after schema migration and after
plugin publication. Prove automatic v0.1 recovery and v0.2 quarantine. In a
third fresh integration root, repeat the full successful transition to show the
process is deterministic without reusing or deleting prior evidence.

- [ ] **Step 8: Add the CI job**

Add `notifier-existing-upgrade` after the existing adoption and fresh notifier
jobs. Use Ubuntu 24.04, full Git history, Go 1.25.14, a 60-minute timeout, and
privacy-safe artifact files under `${RUNNER_TEMP}/threadhub-existing-upgrade-evidence`.
Upload only fixed scenario results, public evidence, progress labels, and safe
diagnostics with seven-day retention.

- [ ] **Step 9: Run the static integration tests locally**

Run:

```bash
go -C notifier test ./integration/... -count=1
```

Expected: PASS for existing adoption and the new upgrade contracts.

- [ ] **Step 10: Run the real-image harness on Ubuntu 24.04 AMD64**

Run:

```bash
./notifier/integration/run-existing-upgrade.sh
```

Expected: 12 fixed scenarios pass; cleanup removes only the generated Compose
project and integration temp roots; privacy-safe result files remain.

- [ ] **Step 11: Commit Task 6**

```bash
git add notifier/integration/run-existing-upgrade.sh \
  notifier/integration/existing-upgrade-scenario-ids.txt \
  notifier/integration/existing_upgrade_contract_test.go \
  notifier/integration/existing_adoption_contract_test.go \
  .github/workflows/validate.yml
git commit -m "test: prove legacy notifier transition with real images"
```

---

### Task 7: Integrate validation and operator documentation

**Files:**
- Modify: `deploy/scripts/validate.sh`
- Modify: `deploy/scripts/notifier-documentation-contracts.sh`
- Modify: `deploy/tests/notifier-documentation-test.sh`
- Modify: `deploy/docs/canonical-runtime-standard.md`
- Modify: `deploy/docs/existing-mattermost-notifier.md`
- Modify: `deploy/docs/test-plan.md`
- Modify: `deploy/docs/test-results-public.md`
- Modify: `docs/superpowers/specs/2026-09-10-existing-notifier-v010-to-v020-transition-design.md`

**Interfaces:**
- Consumes: all implemented scripts and test evidence.
- Produces: a repository-wide validation gate and an exact operator runbook that cannot be confused with initial adoption.

- [ ] **Step 1: Write failing documentation and validation contracts**

Require the operator guide to contain this order:

```text
recovery-gate check
v010-v020 preflight
v010-v020 upgrade
disabled
SMTP acceptance
public/private allowlist
manual acceptance
privacy-safe baseline comparison
explicit all_channels approval
v010-v020 rollback
```

Require warnings for the 30–60 second reconnect, exact version/profile, no
Mattermost/PostgreSQL upgrade, no base Compose/env change, schema-v1 queue
capture, v2 quarantine, at-least-once duplicates, exit code 20, and separate
live authorization.

- [ ] **Step 2: Run documentation tests and confirm the new contract fails**

Run:

```bash
./deploy/tests/notifier-documentation-test.sh
```

Expected: FAIL because exact upgrade commands and ordered sections are absent.

- [ ] **Step 3: Update canonical and existing-adoption documentation**

In `canonical-runtime-standard.md`, define that the exact v0.1.0 profile becomes
`migration-ready` only after the merged transition commit and successful
real-image CI. Other v0.1.0 or unknown layouts remain `legacy-held` or
`unsupported`.

In `existing-mattermost-notifier.md`, remove instructions that manually add
`THN_CONTENT_MODE` and rerun initial setup for a live v0.1.0 pair. Document the
exact commands:

```bash
./deploy/scripts/existing-notifier-v010-v020-recovery-gate.sh check
./deploy/scripts/existing-notifier-v010-v020-preflight.sh
./deploy/scripts/existing-notifier-v010-v020-upgrade.sh
./deploy/scripts/existing-notifier-smtp-test.sh
./deploy/scripts/existing-notifier-control.sh activate-allowlist
./deploy/scripts/existing-notifier-status.sh
```

Keep `activate-all-channels` in a separately approved section and document the
exact rollback command without a force option.

- [ ] **Step 4: Register all scripts and tests in validation**

Ensure `validate.sh` executes the four new shell suites and syntax-checks every
new script. Extend documentation mutation fixtures to prove removal or
reordering of any safety gate fails the contract.

- [ ] **Step 5: Record only public-safe test evidence**

Update the public result document only after the exact real-image job succeeds.
Record scenario count, source/target versions, aggregate preservation result,
rollback result, and privacy scan result. Do not record instance details,
backup IDs, Team/channel/user/post/file values, queue contents, or diagnostics.

- [ ] **Step 6: Run the complete repository verification**

Run:

```bash
git diff --check
./deploy/scripts/validate.sh
go -C notifier test ./... -count=1
```

On Ubuntu 24.04 AMD64 with Docker, also run:

```bash
./notifier/integration/run-existing-upgrade.sh
```

Expected: all commands exit 0 and all 12 upgrade scenarios pass.

- [ ] **Step 7: Run ShellCheck with the repository-pinned version**

Run the same ShellCheck command used by `.github/workflows/validate.yml`:

```bash
shellcheck -x -P deploy/scripts deploy/scripts/*.sh deploy/tests/*.sh
```

Expected: exit 0 with no diagnostics.

- [ ] **Step 8: Review the final diff against the spec**

Verify line by line that every design section has an implementation and test:
supported profile, safety boundaries, evidence, preflight, transition sequence,
queue preservation, rollback, acceptance, real-image test, documentation, and
completion gates. Confirm no hostname appears in program logic.

- [ ] **Step 9: Commit Task 7**

```bash
git add deploy/scripts/validate.sh \
  deploy/scripts/notifier-documentation-contracts.sh \
  deploy/tests/notifier-documentation-test.sh \
  deploy/docs/canonical-runtime-standard.md \
  deploy/docs/existing-mattermost-notifier.md \
  deploy/docs/test-plan.md \
  deploy/docs/test-results-public.md \
  docs/superpowers/specs/2026-09-10-existing-notifier-v010-to-v020-transition-design.md
git commit -m "docs: publish the controlled notifier transition runbook"
```

---

## Repository Completion Gate

Before proposing any live execution:

- [ ] Confirm every task commit is present and the worktree is clean.
- [ ] Confirm the exact real-image transition and rollback CI job passed.
- [ ] Confirm the target release identity points to the reviewed clean commit.
- [ ] Confirm initial adoption and canonical fresh tests remain green.
- [ ] Confirm no protected evidence, credentials, customer identifiers, queue contents, backup identifiers, or diagnostics entered Git history.
- [ ] Request a separate approval naming the exact production instance and the 30–60 second reconnect window.
- [ ] Reverify the latest remote backup and disposable-restore evidence before the first production mutation.
- [ ] After upgrade, stop at the SMTP/allowlist gate and obtain separate approval before `all_channels`.
