# Existing Notifier v0.1.0 to v0.2.0 Transition Design

**Date:** 2026-09-10

**Status:** Approved design

**Scope:** One supported legacy existing-adoption instance; no live deployment is authorized by this document

## 1. Purpose

Provide a fail-closed, reversible transition from the reviewed existing-adoption
Notifier v0.1.0 pair to Notifier v0.2.0 for the one active supported legacy
ThreadHub instance.

The transition adds project context to notification email by setting:

```text
THN_CONTENT_MODE=project_team_channel
```

The email may contain the server/project identifier, Team name, and channel
name. It must not contain message bodies, author names, attachment names, or
attachment contents.

This work does not upgrade Mattermost or PostgreSQL, normalize the existing
filesystem layout, or create a general multi-profile migration framework.

## 2. Supported source and target

The transition tool supports exactly one source profile:

- Ubuntu 24.04 AMD64
- single-node Docker Compose
- Mattermost Team Edition 11.7.7
- PostgreSQL 18.4
- Notifier plugin and Mailer 0.1.0
- explicit existing-adoption bind mounts
- a complete reviewed plugin runtime and filestore bundle pair
- a release identity matching the accepted v0.1.0 source fingerprint

The target profile is:

- the same Ubuntu, Compose, Mattermost, PostgreSQL, and persistent-data layout
- Notifier plugin and Mailer 0.2.0
- `THN_CONTENT_MODE=project_team_channel`
- installation completed while notification delivery is disabled

The tool must select behavior from profile and version evidence, never from a
hostname. Any source, target, release, layout, queue schema, mount, or Compose
ambiguity is an `[ACTION REQUIRED]` result and must not be bypassed.

## 3. Approaches considered

### 3.1 Exact single-profile transition tool — selected

Build a version-specific preflight, transition, and rollback path. Reuse the
existing notifier control, release identity, Compose, plugin-pair transaction,
SMTP acceptance, and status libraries where their contracts already match.

This gives the active legacy instance an automated, tested path without adding
an unnecessary general migration framework.

### 3.2 Manual runbook only — rejected

A manual procedure has less implementation cost but cannot reliably protect
the SQLite queue schema boundary, paired plugin artifacts, configuration
preimage, and recovery order. It creates unacceptable opportunities for a
partial transition.

### 3.3 General multi-profile migration framework — deferred

The repository currently has exactly one active legacy profile requiring this
transition. A general framework would increase state and test complexity
without an active second consumer. Shared migration tooling becomes mandatory
if multiple active legacy instances or profiles later require transition.

## 4. Safety boundaries

The transition must not:

- modify the base Compose file or base environment file;
- change Mattermost or PostgreSQL images;
- move, merge, or normalize `/srv/threadhub` or another live data root;
- overwrite `deploy/existing-notifier.env` without first capturing and
  verifying its exact preimage;
- print secrets, queue contents, customer identifiers, message content, or
  privacy-sensitive baseline data;
- delete pending, sending, failed, sent, or quarantined delivery evidence;
- continue after exit code 20 or reinterpret it as success;
- activate `all_channels` as part of the transition;
- make OCI, DNS, SMTP Credential, Email Delivery, or other infrastructure
  changes.

A repository change does not authorize access to or mutation of a live VM.
Production execution requires a separate approval for the exact instance after
all repository and real-image gates pass.

## 5. Components

The implementation should provide three user-facing operations backed by a
shared version-specific library:

1. **Preflight:** read-only validation of the exact source state.
2. **Transition:** capture, disable, replace, migrate, and verify while leaving
   delivery disabled.
3. **Rollback:** restore the exact v0.1.0 plugin/Mailer/configuration/queue set
   and leave delivery disabled.

Suggested names are:

```text
deploy/scripts/existing-notifier-v010-v020-preflight.sh
deploy/scripts/existing-notifier-v010-v020-upgrade.sh
deploy/scripts/existing-notifier-v010-v020-rollback.sh
deploy/scripts/existing-notifier-v010-v020-common.sh
```

The final implementation plan may refine filenames, but it must retain the
separation between read-only preflight, mutation, and rollback.

## 6. Transition evidence

Each attempt creates a root-only, no-clobber evidence directory beneath the
existing notifier data root. It contains only the minimum data needed for
recovery and privacy-safe review:

- source and target release identities;
- hashes and metadata for the complete plugin runtime and bundle pair;
- the exact v0.1.0 release directory and Compose override preimages;
- a protected `docker image save` archive and image ID for the v0.1.0 Mailer;
- an exact protected preimage of the notifier environment file;
- notifier control-state preimage;
- a consistent SQLite queue snapshot, including required WAL/SHM state;
- queue schema version and SQLite integrity result;
- privacy-safe aggregate baselines;
- step status and rollback disposition.

Evidence filenames and status output must not contain Team names, channel
names, user names, email addresses, post identifiers, or message content.
Permissions must prevent non-administrative access.

The tool must refuse to overwrite an existing attempt or recovery capture.

## 7. Preflight

Preflight runs before any runtime, network, secret, plugin, queue, or persistent
data change. It must verify:

- repository validation succeeds;
- host, architecture, Compose model, services, images, and bind mounts match
  the exact supported source profile;
- the Mattermost and PostgreSQL containers are healthy;
- the installed plugin runtime and filestore bundle form a complete reviewed
  v0.1.0 pair;
- the running Mailer is the reviewed v0.1.0 release;
- the notifier environment and control files are regular, protected files;
- the current content mode is compatible with the v0.1.0 source;
- queue status is available and valid;
- no stale transition lock or ambiguous prior attempt exists;
- a verified remote backup and successful disposable-VM restore exist for the
  exact production instance;
- privacy-safe Team, user, channel, post, and file baselines can be recorded.

Failure before the first mutation leaves the target unchanged.

## 8. Transition sequence

The production transition sequence is:

1. Re-run preflight immediately before the approved window.
2. Build and verify the reviewed v0.2.0 release in a protected staging path
   while the existing Mattermost and v0.1.0 notifier remain active.
3. Drain the notifier and require `pending=0`, `sending=0`, and `failed=0`.
4. Disable notification collection and delivery.
5. Verify the disabled state has been loaded by both plugin and Mailer.
6. Stop the Mailer.
7. Capture the v0.1.0 plugin pair, Mailer image, release directory, Compose
   override, environment preimage, control state, and a consistent schema-v1
   queue snapshot.
8. Reverify the staged v0.2.0 release identity before publishing it.
9. Add `THN_CONTENT_MODE=project_team_channel` through a no-clobber,
   permission-preserving configuration transaction.
10. Publish the v0.2.0 release directory, Compose override, plugin runtime, and
    filestore bundle through their reviewed transactions.
11. Start the v0.2.0 Mailer while notification delivery remains disabled.
12. Let the Mailer perform its transactional queue v1-to-v2 migration.
13. Verify SQLite integrity, schema version 2, and preservation of all existing
    queue rows and delivery states.
14. Recreate Mattermost only through the supported Compose override path. This
    may cause a 30–60 second client reconnect window.
15. Verify the reviewed v0.2.0 plugin/Mailer pair is installed and active while
    control remains disabled.
16. Record post-transition aggregate baselines and compare them with the
    pre-transition values.
17. Stop with `[ACTION REQUIRED]` for SMTP acceptance and pilot activation.

The transition operation does not enable a pilot allowlist or `all_channels`.

## 9. Queue schema and event preservation

Notifier v0.2.0 opens schema-v1 queues using its existing transactional
migration, adds nullable project-context columns, and records schema version 2.
Existing v0.1.0 events remain valid and render using the generic fallback when
project context is absent.

Before opening the queue with v0.2.0, the transition must preserve an exact
schema-v1 snapshot. The snapshot is the only queue accepted by the automated
v0.1.0 rollback path. A schema-v2 queue must never be opened by the v0.1.0
Mailer.

No queue database may be copied while its writer is running unless the SQLite
backup mechanism being used guarantees a consistent snapshot. Copying only
`queue.db` while WAL mode is active is forbidden.

## 10. Failure handling and rollback

Every mutating phase has an explicit rollback boundary. On failure, the tool
must first keep notifier control disabled, then recover the last complete
reviewed state.

Before pilot activation, automatic rollback may:

- stop and quarantine the failed v0.2.0 Mailer queue;
- restore the protected schema-v1 queue snapshot;
- restore the exact v0.1.0 plugin runtime and bundle pair;
- restore the exact v0.1.0 Mailer image, release directory, and Compose
  override;
- restore the notifier environment and control preimages;
- recreate the prior Mattermost and Mailer services;
- verify v0.1.0 health with delivery still disabled.

The failed v0.2.0 queue and plugin artifacts remain quarantined as evidence and
are not deleted.

After any v0.2.0 pilot event has been accepted, rollback requires the notifier
to be drained and disabled again. If pending, sending, or failed work remains,
the tool returns `[ACTION REQUIRED]`. It must not silently cancel, replay, or
discard work. Delivery is at-least-once, so a reviewed rollback may retain a
duplicate-email risk even when no event is lost.

The two rollback contexts use different, explicit aggregate baselines. An
automatic recovery before pilot activation compares the restored source state
with the original pre-transition aggregate. An operator-approved rollback after
pilot activation first captures an immediate pre-rollback privacy-safe
aggregate, then compares the restored state with that aggregate. This preserves
legitimate pilot posts instead of misclassifying them as production-data drift.

If automated recovery cannot prove the restored plugin pair, queue, control,
and service state, Mattermost recovery takes priority and notifications remain
disabled. The result must be a hard failure, not success with warnings.

## 11. Acceptance sequence

After the disabled installation succeeds:

1. Run the one-time SMTP acceptance against the installed v0.2.0 Mailer.
2. Activate only an explicitly selected test-channel allowlist.
3. Test a public-channel root post and thread reply.
4. Test a private-channel root post and thread reply.
5. Verify eligible recipients, exclusions, links, and generic fallback.
6. Confirm the email shows the project/server identifier, Team, and channel.
7. Confirm it excludes message body, author, and attachment information.
8. Re-run privacy-safe Team, user, channel, post, and file aggregates.
9. Review queue status and require zero pending, sending, and failed delivery.
10. Obtain separate explicit approval before restoring `all_channels`.

The existing production mode being `all_channels` does not waive the required
pilot and approval gates after the version transition.

## 12. Testing strategy

Implementation follows test-driven development and includes:

### 12.1 Shell behavior tests

- accepts only the exact source profile and release fingerprint;
- rejects unsupported versions, incomplete plugin pairs, ambiguous layouts,
  unsafe paths, symbolic links, weak permissions, and altered configuration;
- treats exit code 20 as `[ACTION REQUIRED]`;
- verifies lock, no-clobber, disabled-state, queue-drain, and evidence rules;
- injects failure at every mutating boundary and proves the expected recovery;
- proves the base Compose and base environment files remain byte-identical.

### 12.2 Queue migration tests

- seeds a schema-v1 database with all delivery states;
- migrates once to schema v2;
- preserves existing rows and state counts;
- renders legacy rows through the generic fallback;
- rejects unsupported or corrupt schemas;
- proves rollback restores the exact schema-v1 snapshot;
- proves interrupted migrations remain atomic.

### 12.3 Exact real-image integration test

The integration test must use the exact supported existing-adoption profile:

- Mattermost Team Edition 11.7.7;
- PostgreSQL 18.4;
- reviewed v0.1.0 source plugin/Mailer pair;
- explicit bind mounts matching the supported profile.

It seeds non-sensitive Team, user, channel, root-post, thread, and file fixture
data; installs v0.1.0; creates a schema-v1 queue; transitions to v0.2.0
disabled; verifies schema and aggregate preservation; rolls back to v0.1.0;
verifies the original queue and pair; then repeats the transition to prove a
clean second attempt.

The test must not require or exercise paid Mattermost features.

## 13. Documentation changes

The implementation must update:

- `deploy/docs/canonical-runtime-standard.md` with the supported transition;
- `deploy/docs/existing-mattermost-notifier.md` with the exact preflight,
  transition, acceptance, and rollback commands;
- relevant validation and status documentation;
- the release/version record for the reviewed target artifacts.

Documentation must distinguish repository readiness from live authorization.

## 14. Completion criteria

The repository implementation now includes the exact source-profile gate,
protected evidence capture, transactional upgrade and rollback commands, and
the `notifier-existing-upgrade` real-image CI contract. This status does not
claim that an unexecuted commit has passed the real-image scenarios and does not
authorize access to or mutation of a live instance.

Repository readiness is complete only when:

- all unit, behavioral, failure-injection, validation, and real-image tests pass;
- the exact v0.1.0-to-v0.2.0 transition and rollback are documented;
- source and target release identities are pinned and verified;
- no hostname-specific code or third deployment profile is introduced;
- repository status is clean after the reviewed commit.

Production completion is a later, separately authorized operation. It requires:

- current backup and disposable-restore evidence;
- privacy-safe pre/post baselines with no mismatch;
- successful disabled installation and SMTP acceptance;
- successful public/private allowlist tests;
- explicit approval to activate `all_channels`;
- final healthy container, queue, HTTPS, and user-access checks.
