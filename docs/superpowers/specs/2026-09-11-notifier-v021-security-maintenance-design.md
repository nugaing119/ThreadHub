# Notifier v0.2.1 Fresh-Install Security Baseline Design

**Date:** 2026-09-11

**Status:** Approved for implementation

**Scope:** Canonical fresh installations only; existing v0.2.0 instances remain unchanged and no live deployment is authorized

## 1. Purpose

Publish an immutable Notifier v0.2.1 maintenance release for future ThreadHub
installations. The release moves the notifier build from Go 1.25.14 to Go
1.26.8 and from `golang.org/x/crypto` v0.55.0 to v0.56.0.

The change removes two module-level `x/crypto/ssh` findings fixed in v0.56.0
and returns future builds to a supported Go release line. It does not add
features or change notification recipients, content, queue schema, SMTP
behavior, control state, or Mattermost licensing.

Existing notifier v0.2.0 deployments are not exposed through the affected SSH
or OpenPGP packages. They remain pinned to their reviewed release and are not
rebuilt, redeployed, or migrated by this work.

## 2. Decision and alternatives

### 2.1 Fresh-install-only v0.2.1 release — selected

Update the canonical repository release used by new installations. Record the
existing v0.2.0 production profile as `legacy-held` and defer its transition
until a separately justified maintenance event.

This removes unsupported toolchain debt from future projects without exposing
the current service and customer data to an unnecessary maintenance window.

### 2.2 Fresh release plus immediate v0.2.0 transition — deferred

An exact transition could update the existing notifier, but the current
findings have no reachable notifier call path. Building and operating a
version-specific transition, rollback, recovery, and pilot path now would add
more risk and work than the non-reachable findings justify.

### 2.3 Rebuild under the existing v0.2.0 version — rejected

Reusing v0.2.0 for binaries produced with another toolchain and dependency
graph would make the same version identify different plugin bundles and Mailer
images. That violates the repository's immutable release and rollback
contracts.

### 2.4 Permanent document-only risk acceptance — rejected

Go 1.25 is outside the supported release window and `x/crypto` v0.56.0
requires Go 1.26. Continuing to create new builds on Go 1.25 would leave new
projects on an unsupported baseline. Deferral applies only to already-reviewed
v0.2.0 runtime artifacts, not to future builds.

### 2.5 Go 1.27 adoption — deferred

Go 1.27 is supported but introduces a larger toolchain change than required.
Go 1.26.8 is supported, satisfies `x/crypto` v0.56.0, and passed the notifier
Go test suite in an isolated compatibility probe. A later Go 1.27 upgrade is a
separate maintenance decision.

## 3. Fixed target release

Notifier v0.2.1 uses:

```text
NOTIFIER_VERSION=0.2.1
Go language version=1.26.0
Go builder release=1.26.8-bookworm
golang.org/x/crypto=v0.56.0
govulncheck=v1.8.0
```

The implementation must resolve and record the exact Linux AMD64 manifest
digest and multi-platform index digest for the official Go builder image. It
must regenerate the Mailer created-by history checksum from the reviewed
v0.2.1 build. Tags without digests and `latest` are forbidden.

All other module changes must be explained by Go minimal-version selection or
`go mod tidy`. Unrelated dependency upgrades are outside this release.

## 4. Security finding disposition

The release distinguishes module presence from runtime reachability.

1. `GO-2026-6355` affects `golang.org/x/crypto/ssh` before v0.56.0. The
   notifier does not import this package. Updating the fresh-build dependency
   graph to v0.56.0 removes the module-level finding.
2. `GO-2026-6354` affects the same unimported SSH package before v0.56.0.
   Updating to v0.56.0 removes the module-level finding.
3. `GO-2026-5932` affects OpenPGP packages in every `x/crypto` version and has
   no fixed release. The notifier's built dependency list contains only
   `golang.org/x/crypto/pbkdf2` and `golang.org/x/crypto/scrypt`. The OpenPGP
   finding remains a documented module-level non-applicability. The project
   does not add an unused alternative OpenPGP dependency.

The fresh-release gate requires zero vulnerable symbol calls and zero
vulnerable imported packages from `govulncheck`. A module-only result may
remain only when its non-applicability and built-package evidence are recorded.

## 5. Licensing boundary

The maintenance release does not enable a Mattermost paid feature or alter a
Mattermost license gate. It rebuilds the existing ThreadHub plugin and Mailer
with supported Go components.

The implementation must:

- retain Mattermost Team Edition and the no-license-key policy;
- include `x/crypto` v0.56.0 and its license in the generated third-party
  inventory and notices;
- keep every declared Go module covered by the license compliance test;
- avoid adding ProtonMail OpenPGP or another unused cryptographic dependency;
- retain the existing policy that disables plugin Marketplace, plugin upload,
  and unreviewed prepackaged plugin installation.

## 6. Canonical fresh-install behavior

After v0.2.1 is merged, a new installation from the reviewed commit builds and
installs the v0.2.1 plugin/Mailer pair by default. The setup wizard continues
to require project-specific secrets and leaves delivery behind the existing
SMTP acceptance and activation gates.

The release changes no fresh-install data path, volume, queue schema, email
content mode, default `all_channels` policy, or OCI resource model. It never
attaches a new installation to an existing `/srv/threadhub` tree.

An installation from an older commit remains tied to that commit's exact
release. Pulling new source does not automatically update an installed
runtime.

## 7. Existing v0.2.0 instance policy

Existing v0.2.0 notifier instances remain `legacy-held`:

- their plugin, Mailer image, release identity, Compose overlay, queue, and
  source commit remain unchanged;
- no v0.2.0-to-v0.2.1 transition script is created in this scope;
- no Mattermost container is recreated and no notifier service is restarted;
- no production data, user, Team, channel, post, file, or membership is read
  or changed;
- no SMTP Credential, DNS, IAM, OCI, certificate, backup, logging, or
  monitoring resource is changed;
- the two SSH findings and the OpenPGP finding are recorded as non-reachable
  for the reviewed notifier build.

The existing v0.1.0-to-v0.2.0 transition and rollback tools remain in the
repository for their exact historical contract. This work does not rename,
generalize, or repurpose them.

A legacy-held instance is reconsidered only when at least one trigger occurs:

1. a vulnerability becomes reachable through a package actually imported by
   the notifier;
2. notifier behavior or source code must be changed;
3. the notifier must be rebuilt for another operational reason;
4. the operator approves a scheduled maintenance upgrade despite the current
   non-reachability finding.

At that point, the project creates a separate version-specific design with an
exact source profile, current backup and disposable-restore evidence,
fail-closed preflight, disabled transition, rollback, SMTP acceptance, and
allowlist pilot. This fresh-install design does not authorize that work.

## 8. Repository change boundary

The implementation may update only the surfaces needed to produce and verify
the fresh v0.2.1 release:

- `deploy/versions.env` notifier and Go builder fields;
- `notifier/go.mod` and `notifier/go.sum`;
- Go-version and `govulncheck` pins in CI;
- tests that assert the exact builder, scanner, dependency, and release
  versions;
- notifier third-party module inventory and generated notices;
- Dockerfile artifact paths that embed the immutable notifier version;
- fresh-install validation, build, artifact, and integration contracts;
- security, canonical runtime, installation, and test-result documentation.

The implementation must not add v0.2.0-to-v0.2.1 preflight, upgrade, rollback,
recovery-gate, or live-operation scripts. Existing version-specific transition
fixtures must continue to test their historical v0.2.0 target without being
rewritten to v0.2.1.

## 9. Testing strategy

Implementation follows test-driven development.

### 9.1 Dependency and toolchain contracts

- Go source directive is exactly 1.26.0;
- CI and the Docker builder use exactly Go 1.26.8;
- the builder uses reviewed AMD64 and index digests;
- `x/crypto` resolves to exactly v0.56.0;
- `govulncheck` v1.8.0 reports zero vulnerable symbols and imported packages;
- the OpenPGP module-only disposition is present and no OpenPGP package enters
  the built dependency list;
- module, license, and third-party notice inventories are synchronized.

### 9.2 Build and regression tests

- formatting, module verification, vet, and `go test -race ./...` pass with
  Go 1.26.8;
- plugin bundle and Mailer image build for Linux AMD64 from the pinned builder;
- artifact secret, history, rootfs, checksum, and reproducibility gates pass;
- the canonical fresh real-image integration retains all existing functional,
  security, delivery, queue, and privacy contracts;
- setup, installation, health, status, backup, and restore static contracts
  continue to pass without a live deployment.

### 9.3 Scope-regression tests

- existing v0.1.0-to-v0.2.0 transition constants and fixtures remain fixed at
  their historical source and target versions;
- no test or script claims that a repository update changes a legacy-held
  runtime;
- no production hostname, credential, customer identifier, or private
  operational evidence enters artifacts or logs;
- no paid Mattermost feature is required or exercised.

## 10. Documentation changes

The implementation updates:

- the notifier release and Go builder records;
- the notifier license inventory and notices;
- the runtime security review with a notifier-specific finding disposition
  dated 2026-09-11;
- the canonical runtime standard with v0.2.1 as the future fresh-install
  default and v0.2.0 as an allowed legacy-held release;
- quick-install and notifier documentation so fresh installation and existing
  runtime maintenance cannot be confused;
- the test plan and public result summary with planned and executed evidence
  kept separate.

Documentation must not claim that the unfixable OpenPGP module-only warning is
absent or that repository readiness updates a live instance.

## 11. Completion criteria

Repository readiness requires:

- immutable v0.2.1 release metadata and exact artifact provenance;
- successful static, unit, race, vulnerability, license, artifact,
  reproducibility, and canonical fresh real-image CI at one reviewed commit;
- removal of the two SSH module findings from the fresh dependency graph;
- explicit disposition of the remaining OpenPGP module-only finding;
- unchanged historical v0.1.0-to-v0.2.0 transition contracts;
- explicit documentation that existing v0.2.0 instances remain legacy-held;
- a clean branch containing no secrets or private operational evidence.

This design has no production completion stage. Updating any live instance is
a different project requiring a new design and separate explicit approval.
