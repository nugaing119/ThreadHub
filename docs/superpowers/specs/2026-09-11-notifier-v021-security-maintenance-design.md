# Notifier v0.2.1 Security Maintenance Design

**Date:** 2026-09-11

**Status:** Proposed for review

**Scope:** Repository release preparation, canonical fresh-install update, and one exact existing-notifier v0.2.0 transition path; no live deployment is authorized by this document

## 1. Purpose

Publish an immutable Notifier v0.2.1 maintenance release that moves the
ThreadHub notifier build from Go 1.25.14 to Go 1.26.8 and from
`golang.org/x/crypto` v0.55.0 to v0.56.0.

The change removes the two module-level `x/crypto/ssh` findings fixed in
v0.56.0 and returns the build to a supported Go release line. It does not add
features or change notification recipients, content, queue schema, SMTP
behavior, control state, or Mattermost licensing.

The release also updates the repository's vulnerability scanner from
`govulncheck` v1.7.0 to v1.8.0. The remaining module-level OpenPGP finding is
recorded as not applicable to the notifier because neither
`golang.org/x/crypto/openpgp` nor any of its subpackages is imported or built.

## 2. Decision and alternatives

### 2.1 Coupled v0.2.1 maintenance release — selected

Update the Go toolchain, `x/crypto`, scanner, release identity, artifact
provenance, license inventory, fresh-install default, and the exact existing
v0.2.0 transition path together.

This keeps one reviewed dependency graph and prevents a new artifact from
being published under the already-used v0.2.0 identity.

### 2.2 Dependency-only rebuild under v0.2.0 — rejected

Reusing v0.2.0 for binaries built with a different toolchain and dependency
graph would make the same version identify different plugin bundles and Mailer
images. That violates the repository's immutable release and rollback
contracts.

### 2.3 Document-only risk acceptance — rejected as a steady state

The vulnerable SSH symbols are not reachable, so an emergency production
change is unnecessary. However, Go 1.25 is outside the supported release
window and `x/crypto` v0.56.0 requires Go 1.26. Keeping the old build
indefinitely would leave future compiler and standard-library security fixes
without a supported landing path.

### 2.4 Go 1.27 adoption — deferred

Go 1.27 is supported but introduces a larger toolchain change than needed.
Go 1.26.8 is supported, satisfies `x/crypto` v0.56.0, and has already passed
the notifier Go test suite in an isolated compatibility probe. A later Go 1.27
upgrade remains a separate maintenance decision.

## 3. Fixed target release

Notifier v0.2.1 uses the following source-level versions:

```text
NOTIFIER_VERSION=0.2.1
Go language version=1.26.0
Go builder release=1.26.8-bookworm
golang.org/x/crypto=v0.56.0
govulncheck=v1.8.0
```

The implementation must resolve and record the exact Linux AMD64 manifest
digest and multi-platform index digest for the selected official Go builder
image. It must also regenerate the Mailer created-by history checksum from the
reviewed v0.2.1 build. Tags without digests and `latest` are forbidden.

All other module changes must be explained by Go minimal-version selection or
`go mod tidy`. The implementation must not opportunistically upgrade unrelated
dependencies.

## 4. Security finding disposition

The release records three separate findings rather than treating a module
match as proof of runtime reachability.

1. `GO-2026-6355` affects `golang.org/x/crypto/ssh` before v0.56.0. The
   notifier does not import this package. Updating to v0.56.0 removes the
   module-level finding.
2. `GO-2026-6354` affects the same unimported SSH package before v0.56.0.
   Updating to v0.56.0 removes the module-level finding.
3. `GO-2026-5932` affects OpenPGP packages in every `x/crypto` version and has
   no fixed release. The notifier's built dependency list contains only
   `golang.org/x/crypto/pbkdf2` and `golang.org/x/crypto/scrypt`. The OpenPGP
   finding remains a documented module-level non-applicability, not a reason
   to add an unused alternative OpenPGP implementation.

The release gate requires zero vulnerable symbol calls and zero vulnerable
imported packages from `govulncheck`. A module-only finding may remain only
when its non-applicability, imported-package evidence, and compensating build
boundary are documented.

## 5. Licensing boundary

The maintenance release does not enable a Mattermost paid feature or alter a
Mattermost license gate. It rebuilds the existing ThreadHub plugin and Mailer
with supported Go components.

The implementation must:

- retain Mattermost Team Edition and the existing no-license-key policy;
- include the exact `x/crypto` v0.56.0 module and license in the generated
  third-party inventory and notices;
- update the inventory test so every declared Go module remains covered;
- avoid adding ProtonMail OpenPGP or another unused cryptographic dependency;
- keep plugin Marketplace, plugin upload, and unreviewed prepackaged plugin
  installation disabled under the existing deployment policy.

## 6. Fresh installation behavior

After v0.2.1 is merged, a new installation from the reviewed commit builds and
installs the v0.2.1 plugin/Mailer pair by default. The setup wizard and
installer continue to require project-specific secrets and leave notification
delivery behind the existing SMTP acceptance and activation gates.

The release changes no fresh-install data path, volume, queue schema, email
content mode, default `all_channels` policy, or OCI resource model. It does not
attach a new installation to an existing `/srv/threadhub` tree.

An installation from an older commit remains tied to that commit's exact
release. Documentation must not imply that pulling new source automatically
updates an installed runtime.

## 7. Supported existing-instance transition

The repository provides a version-specific transition for the one active,
reviewed existing-notifier profile that is already running the exact v0.2.0
plugin/Mailer pair produced by the accepted v0.1.0-to-v0.2.0 transition.

That supported source topology remains Ubuntu 24.04 AMD64, single-node Docker
Compose, Mattermost Team Edition 11.7.7, PostgreSQL 18.4, explicit
existing-adoption bind mounts, notifier queue schema 2, and the protected
v0.2.0 release fingerprint recorded by the completed transition. The
maintenance operation does not upgrade or normalize any of those components.

The source profile must be identified by release, artifact, Compose, mount,
queue, control, and source-commit evidence. Hostname must not select behavior.
An arbitrary v0.2.0 installation, canonical fresh instance with a different
topology, unknown artifact, altered queue, or incomplete release identity is
unsupported and must fail before mutation.

Suggested version-specific entry points are:

```text
deploy/scripts/existing-notifier-v020-v021-preflight.sh
deploy/scripts/existing-notifier-v020-v021-upgrade.sh
deploy/scripts/existing-notifier-v020-v021-rollback.sh
deploy/scripts/existing-notifier-v020-v021-common.sh
```

The transition is intentionally not a general migration framework. If a
second active v0.2.0 profile later needs an upgrade, its exact topology must be
reviewed before extending the supported profile set.

## 8. Transition invariants

The v0.2.0-to-v0.2.1 transition changes only the plugin/Mailer release pair and
its release metadata. It must preserve:

- Mattermost and PostgreSQL image tags and digests;
- base Compose and base environment bytes;
- Team, user, channel, post, thread, file, and membership data;
- notifier queue schema v2 and every queue row and delivery state;
- notifier content mode, target mode, allowlist, and activation policy;
- project SMTP settings and protected secrets;
- existing backup, certificate, logging, monitoring, DNS, and OCI resources.

No database migration, queue schema migration, filesystem normalization,
credential rotation, DNS change, IAM change, or infrastructure mutation is
part of this release.

## 9. Read-only preflight

Preflight must run before any write and verify:

- Ubuntu 24.04 AMD64 and the exact supported existing-notifier profile;
- healthy Mattermost, PostgreSQL, and Mailer services;
- an exact active v0.2.0 plugin runtime and filestore bundle pair;
- an exact v0.2.0 Mailer image and release identity;
- protected regular configuration, control, release, and queue files;
- queue schema 2, SQLite integrity, and valid privacy-safe status aggregates;
- no stale transition lock, partial prior attempt, or ambiguous Compose model;
- a current verified remote backup and a successful disposable restore for
  the target production instance;
- a clean, reviewed v0.2.1 target release and matching CI evidence.

Any mismatch returns `[ACTION REQUIRED]` with exit code 20 and no mutation.
Diagnostics must not print secrets, email addresses, Team/channel names,
message content, post identifiers, or queue payloads.

## 10. Transition sequence

After separate authorization for one exact live instance, the transition
sequence is:

1. Re-run the read-only preflight in the approved maintenance window.
2. Stage and verify the complete v0.2.1 release before touching the runtime.
3. Drain v0.2.0 and require zero pending, sending, and failed work.
4. Disable collection and delivery and verify both processes loaded the state.
5. Capture a root-only, no-clobber recovery set containing the exact v0.2.0
   plugin pair, Mailer image, release identity, Compose override, environment,
   control state, and consistent schema-v2 queue.
6. Reverify the v0.2.1 source commit, bundle checksum, image ID, release
   metadata, and artifact provenance.
7. Publish the v0.2.1 release metadata, Compose image reference, plugin
   runtime, and filestore bundle through no-clobber transactions.
8. Start the v0.2.1 Mailer with delivery disabled and verify queue schema 2,
   SQLite integrity, row/state preservation, and exact image identity.
9. Recreate only the Mattermost service through the supported Compose overlay;
   clients may reconnect for approximately 30–60 seconds.
10. Verify the exact v0.2.1 plugin/Mailer pair, disabled control state, service
    health, queue state, and privacy-safe application-data aggregates.
11. Stop with `[ACTION REQUIRED]` for SMTP acceptance and allowlist pilot.

The transition never activates `all_channels` automatically.

## 11. Rollback

Before pilot activation, any failure after the first mutation must keep
delivery disabled and automatically attempt to restore the exact v0.2.0
release, plugin pair, Mailer image, Compose override, environment, control
state, and schema-v2 queue captured for that attempt.

The failed v0.2.1 queue and artifacts are quarantined rather than deleted.
Rollback succeeds only after it proves v0.2.0 service health, exact release
identity, SQLite integrity, queue-state preservation, and unchanged
privacy-safe Mattermost aggregates.

After pilot events have been accepted, rollback requires an interactive
review. The operator must drain and disable, resolve any pending or failed
work, capture a new pre-rollback aggregate, and acknowledge at-least-once
duplicate-email risk. There is no force option and no path that discards or
replays queue work implicitly.

If automated recovery cannot prove the complete v0.2.0 state, Mattermost
availability takes priority, notifications remain disabled, and the command
returns a hard failure.

## 12. Acceptance after installation

A successful disabled transition is followed by:

1. one-time SMTP acceptance using the installed v0.2.1 Mailer;
2. an explicit public/private test-channel allowlist;
3. public root-post and thread-reply delivery tests;
4. private root-post and thread-reply delivery tests;
5. recipient, membership, disabled-user, bot, and author-exclusion checks;
6. permalink authorization and privacy-content checks;
7. zero pending, sending, and failed queue work;
8. unchanged data aggregates except for approved pilot posts;
9. separate explicit authorization before restoring `all_channels`.

SMTP acceptance is retained even though SMTP logic is unchanged because the
Mailer binary and image identity are new.

## 13. Repository testing strategy

Implementation follows test-driven development and must cover:

### 13.1 Dependency and toolchain contracts

- Go source directive is exactly 1.26.0;
- CI and the Docker builder use exactly Go 1.26.8;
- the builder uses reviewed AMD64 and index digests;
- `x/crypto` resolves to exactly v0.56.0;
- `govulncheck` v1.8.0 reports zero vulnerable symbols and imported packages;
- the OpenPGP module-only disposition is present and no OpenPGP package enters
  the built dependency list;
- module, license, and third-party notice inventories are synchronized.

### 13.2 Build and regression tests

- `go test -race ./...`, formatting, module verification, vet, and license
  tests pass with Go 1.26.8;
- plugin bundle and Mailer image build for Linux AMD64 from the fixed builder;
- artifact secret, history, rootfs, checksum, and reproducibility gates pass;
- fresh real-image integration retains every v0.2.0 functional, security,
  delivery, queue, and privacy contract.

### 13.3 Existing v0.2.0 transition tests

- exact source profile and release fingerprint are required;
- all unsupported or ambiguous states fail before writes;
- fault injection at every mutation boundary either restores v0.2.0 or fails
  hard with delivery disabled;
- base Compose/env and application-data aggregates remain unchanged;
- schema-v2 queue rows and states survive upgrade and rollback;
- a clean second transition succeeds after an injected failure and recovery;
- the exact real-image test performs transition, disabled verification,
  rollback, and repeat transition without paid Mattermost features.

## 14. Documentation changes

The implementation updates:

- `deploy/versions.env` and every CI/toolchain contract;
- notifier module files, third-party module inventory, and notices;
- `deploy/docs/security-image-review-2026-09-07.md` with a separate notifier
  source-build finding disposition dated 2026-09-11;
- `deploy/docs/canonical-runtime-standard.md` with v0.2.1 as the fresh default;
- `deploy/docs/existing-mattermost-notifier.md` with the exact v0.2.0-to-v0.2.1
  preflight, transition, acceptance, rollback, and live-authorization boundary;
- `deploy/docs/test-plan.md` and the public result summary with planned versus
  actually executed evidence clearly separated.

Documentation must not claim that repository readiness updates a live
instance or that the unfixable module-only OpenPGP warning is absent.

## 15. Completion criteria

Repository readiness requires:

- the immutable v0.2.1 release and exact provenance are recorded;
- all static, unit, race, vulnerability, license, artifact, reproducibility,
  fresh real-image, and existing-transition CI jobs pass at one reviewed
  commit;
- the two SSH module findings are absent and the OpenPGP module-only finding is
  explicitly dispositioned;
- the exact v0.2.0-to-v0.2.1 transition and rollback are documented;
- no production hostname, credential, customer identifier, or private
  operational evidence is committed;
- the branch is clean after the reviewed commits.

Production completion is separate. It requires a new explicit authorization
for the exact instance, current backup and disposable-restore evidence, a
successful disabled transition, SMTP acceptance, public/private allowlist
pilot, data-preservation comparison, and explicit `all_channels` activation.
