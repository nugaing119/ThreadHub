# Notifier v0.2.1 Fresh-Install Security Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Publish an immutable Notifier v0.2.1 security-maintenance release for future canonical fresh ThreadHub installations without changing any installed v0.2.0 runtime or rewriting the historical v0.1.0-to-v0.2.0 transition contract.

**Architecture:** Keep the current fresh-install build and integration path on the repository's current release while moving the old adoption and transition CI suites behind a commit-pinned historical runner. Update only the notifier toolchain, `x/crypto`, immutable artifact identity, security/license evidence, and fresh-install documentation; retain every production-facing v0.2.0 transition script unchanged. Prove source reachability, binary/artifact provenance, reproducibility, and functional behavior in Linux AMD64 CI before declaring repository readiness.

**Tech Stack:** Go 1.26.8 with `go 1.26.0`, `golang.org/x/crypto` v0.56.0, Mattermost Team Edition plugin API, Bash 3.2-compatible validation scripts, Docker BuildKit on Linux AMD64, GitHub Actions Ubuntu 24.04, govulncheck v1.8.0, Gitleaks 8.30.1.

**Spec:** `docs/superpowers/specs/2026-09-11-notifier-v021-security-maintenance-design.md`

## Global Constraints

- The canonical fresh release is exactly `NOTIFIER_VERSION=0.2.1`.
- The Go source directive is exactly `1.26.0`; CI and the Docker builder use exactly `1.26.8`.
- The builder reference is `golang:1.26.8-bookworm@sha256:bc6beb46032d45f421cf400036bf031cdc64f683ba9cdc124e31d063e71670bd`; the corresponding multi-platform index digest is `sha256:9fdc884aacc3bec89b20ffc69f4bb369c78210e3e4f600387b5128b12c199f81`.
- `golang.org/x/crypto` resolves to exactly `v0.56.0`; unrelated module upgrades are forbidden.
- govulncheck is pinned to exactly `v1.8.0` and must report zero vulnerable symbols and zero vulnerable imported packages.
- The built notifier dependency set may contain only `golang.org/x/crypto/pbkdf2` and `golang.org/x/crypto/scrypt` from `x/crypto`; OpenPGP and SSH packages must not enter the built dependency graph.
- Mattermost remains Team Edition with no paid license key or paid-feature bypass. Plugin Marketplace, plugin upload, and unreviewed prepackaged plugin installation remain disabled.
- Existing v0.2.0 runtimes are `legacy-held`: do not connect to, inspect, rebuild, restart, migrate, or redeploy a live instance in this work.
- Do not add v0.2.0-to-v0.2.1 preflight, upgrade, rollback, recovery-gate, adoption, or live-operation scripts.
- The historical v0.1.0-to-v0.2.0 source commit, target version, scripts, fixtures, and scenario IDs remain unchanged.
- Never display or commit credentials, protected environment values, queue contents, user data, Team/channel/post identifiers, production hostnames, OCI identifiers, or private operational evidence.
- Never run `docker compose config` against `deploy/.env` without `--quiet`; never attach a fresh build to an existing `/srv/threadhub` tree.
- Use `apply_patch` for repository edits, preserve unrelated work, and commit each task independently.

---

## File and Interface Map

### New files

- `notifier/integration/run-v020-history.sh`: CI-only, argument-bounded runner that checks out the accepted v0.2.0 merge commit in a temporary detached worktree and runs either the historical existing-adoption or existing-upgrade suite.
- `notifier/integration/history_wrapper_contract_test.go`: static contract for the pinned historical commit, allowed suite names, cleanup behavior, workflow wiring, and legacy/current separation.
- `deploy/tests/notifier-dependency-security-test.sh`: exact current-release module and built-package reachability gate for `x/crypto`.

### Modified current-release files

- `deploy/versions.env`: v0.2.1 release, Go builder tag, AMD64 digest, index digest, and confirmed Mailer history checksum.
- `notifier/go.mod`, `notifier/go.sum`: Go 1.26.0 and `x/crypto` v0.56.0 only.
- `notifier/Dockerfile`: immutable v0.2.1 plugin bundle filename.
- `notifier/Makefile`: v0.2.1 Dockerfile/manifest assertions and dependency-scope target.
- `notifier/plugin/plugin.json`, `notifier/plugin/server/plugin_test.go`: v0.2.1 manifest identity.
- `notifier/integration/run.sh`, `notifier/integration/plugin-install.sh`: current fresh real-image v0.2.1 guards.
- `notifier/integration/cmd/acceptance/main.go`, `notifier/integration/cmd/acceptance/main_test.go`: current fresh acceptance verifier identity.
- `notifier/integration/contract_test.go`: current release, Go, scanner, dependency, artifact, and CI assertions.
- `notifier/integration/existing_adoption_contract_test.go`, `notifier/integration/existing_upgrade_contract_test.go`: historical wrapper wiring while retaining the exact old runner assertions.
- `deploy/scripts/validate.sh`: current manifest version and dependency-security test registration.
- `deploy/scripts/verify-notifier-artifacts.sh`: current v0.2.1 default bundle and Mailer references.
- `deploy/tests/notifier-mailer-reproducibility-test.sh`: current v0.2.1 image identity.
- `notifier/third_party/modules.tsv`, `notifier/THIRD_PARTY_NOTICES.md`: synchronized `x/crypto` v0.56.0 inventory and release date/security scope.
- `.github/workflows/validate.yml`: Go 1.26.8, govulncheck v1.8.0, current dependency gate, and commit-pinned historical jobs.
- `deploy/scripts/notifier-documentation-contracts.sh`: fresh v0.2.1, legacy-held v0.2.0, historical runner, and non-live-update documentation contracts.
- `deploy/docs/canonical-runtime-standard.md`, `deploy/docs/quick-install.md`, `deploy/docs/notifier-architecture.md`, `deploy/docs/existing-mattermost-notifier.md`, `deploy/docs/security-image-review-2026-09-07.md`, `deploy/docs/test-plan.md`, `deploy/docs/test-results-public.md`: release, security disposition, installation boundary, and evidence status.

### Historical files that must not be edited

```text
notifier/integration/run-existing-adoption.sh
notifier/integration/run-existing-upgrade.sh
notifier/integration/existing-upgrade-scenario-ids.txt
deploy/scripts/existing-notifier-v010-v020-*.sh
deploy/tests/existing-notifier-v010-v020-*.sh
docs/superpowers/specs/2026-09-10-existing-notifier-v010-to-v020-transition-design.md
docs/superpowers/plans/2026-09-10-existing-notifier-v010-v020-transition.md
```

Generic installer, backup, and artifact-security fixtures may continue to use `0.2.0` when the number is test data rather than the canonical current release. Do not perform a repository-wide replacement.

### Stable interfaces produced by this plan

```text
./notifier/integration/run-v020-history.sh existing-adoption
./notifier/integration/run-v020-history.sh existing-upgrade
./deploy/tests/notifier-dependency-security-test.sh
make -C notifier dependency-scope-check
```

---

### Task 1: Isolate the historical v0.2.0 integration suites

**Files:**
- Create: `notifier/integration/run-v020-history.sh`
- Create: `notifier/integration/history_wrapper_contract_test.go`
- Modify: `notifier/integration/existing_adoption_contract_test.go`
- Modify: `notifier/integration/existing_upgrade_contract_test.go`
- Modify: `.github/workflows/validate.yml`

**Interfaces:**
- Consumes: Git history containing accepted merge commit `7602555a21fe5e110eafa1d685a61c95d53969d8` and one exact argument, `existing-adoption` or `existing-upgrade`.
- Produces: a temporary detached worktree that executes the selected historical runner with the caller's absolute privacy-safe evidence paths, then removes only that temporary worktree.

- [ ] **Step 1: Add failing historical-wrapper contract tests**

Create `notifier/integration/history_wrapper_contract_test.go` with these exact invariants:

```go
package integration_test

import (
	"strings"
	"testing"
)

func TestV020HistoricalRunnerIsCommitPinnedAndArgumentBounded(t *testing.T) {
	t.Parallel()
	wrapper := readContractFile(t, "run-v020-history.sh")
	for _, required := range []string{
		"7602555a21fe5e110eafa1d685a61c95d53969d8",
		"existing-adoption)",
		"existing-upgrade)",
		"git -C \"${repository_root}\" worktree add --detach",
		"git -C \"${repository_root}\" worktree remove --force",
		"run-existing-adoption.sh",
		"run-existing-upgrade.sh",
	} {
		if !strings.Contains(wrapper, required) {
			t.Fatalf("historical wrapper is missing %q", required)
		}
	}
	for _, forbidden := range []string{"HEAD^{commit}", "git checkout", "git reset", "deploy/.env"} {
		if strings.Contains(wrapper, forbidden) {
			t.Fatalf("historical wrapper contains forbidden contract %q", forbidden)
		}
	}
}

func TestV020HistoricalJobsUseOnlyThePinnedWrapper(t *testing.T) {
	t.Parallel()
	workflow := readContractFile(t, "../../.github/workflows/validate.yml")
	for _, required := range []string{
		"./notifier/integration/run-v020-history.sh existing-adoption",
		"./notifier/integration/run-v020-history.sh existing-upgrade",
		"fetch-depth: 0",
	} {
		if !strings.Contains(workflow, required) {
			t.Fatalf("historical workflow is missing %q", required)
		}
	}
	for _, forbidden := range []string{
		"./notifier/integration/run-existing-adoption.sh",
		"./notifier/integration/run-existing-upgrade.sh",
	} {
		if strings.Contains(workflow, forbidden) {
			t.Fatalf("workflow bypasses the pinned historical wrapper with %q", forbidden)
		}
	}
}
```

Change the workflow assertions in `existing_adoption_contract_test.go` and `existing_upgrade_contract_test.go` to require the corresponding `run-v020-history.sh` command while continuing to read and validate the unchanged historical runners themselves.

- [ ] **Step 2: Run the focused tests and confirm the wrapper is absent**

Run:

```bash
GOTOOLCHAIN=go1.25.14 go -C notifier test ./integration \
  -run 'TestV020Historical|TestExistingAdoptionHarness|TestExistingUpgradeHarness' -count=1
```

Expected: FAIL because `run-v020-history.sh` does not exist and the workflow still calls both historical runners directly.

- [ ] **Step 3: Implement the bounded CI-only historical runner**

Create executable `notifier/integration/run-v020-history.sh` with this control flow:

```bash
#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
repository_root="$(cd -- "${script_dir}/../.." && pwd -P)"
historical_commit=7602555a21fe5e110eafa1d685a61c95d53969d8

case "${1:-}" in
    existing-adoption) runner=run-existing-adoption.sh ;;
    existing-upgrade) runner=run-existing-upgrade.sh ;;
    *) printf '%s\n' 'usage: run-v020-history.sh existing-adoption|existing-upgrade' >&2; exit 2 ;;
esac
[[ "$#" -eq 1 ]] || exit 2

temporary_parent="$(mktemp -d)"
historical_root="${temporary_parent}/threadhub-v020"
worktree_added=false
cleanup() {
    if [[ "${worktree_added}" == true ]]; then
        git -C "${repository_root}" worktree remove --force "${historical_root}" >/dev/null 2>&1 || true
    fi
    rm -rf -- "${temporary_parent}"
}
trap cleanup EXIT HUP INT TERM

git -C "${repository_root}" cat-file -e "${historical_commit}^{commit}"
git -C "${repository_root}" worktree add --detach "${historical_root}" "${historical_commit}" >/dev/null
worktree_added=true
"${historical_root}/notifier/integration/${runner}"
```

The script inherits only the caller's already-defined integration evidence environment variables; it neither reads `deploy/.env` nor accepts a commit from input.

- [ ] **Step 4: Route both historical jobs through the wrapper**

In `.github/workflows/validate.yml` keep `fetch-depth: 0` and replace only the runner command in each job:

```yaml
./notifier/integration/run-v020-history.sh existing-adoption
```

```yaml
./notifier/integration/run-v020-history.sh existing-upgrade
```

Do not change the historical runner source or its `0.1.0`/`0.2.0` constants.

- [ ] **Step 5: Run wrapper contracts and shell validation**

Run:

```bash
bash -n notifier/integration/run-v020-history.sh
GOTOOLCHAIN=go1.25.14 go -C notifier test ./integration \
  -run 'TestV020Historical|TestExistingAdoptionHarness|TestExistingUpgradeHarness' -count=1
```

Expected: PASS. Do not run the Docker-backed historical suites locally in this step.

- [ ] **Step 6: Commit Task 1**

```bash
git add .github/workflows/validate.yml \
  notifier/integration/run-v020-history.sh \
  notifier/integration/history_wrapper_contract_test.go \
  notifier/integration/existing_adoption_contract_test.go \
  notifier/integration/existing_upgrade_contract_test.go
git commit -m "test: freeze historical notifier v0.2.0 integration"
```

---

### Task 2: Publish the immutable v0.2.1 toolchain and release identity

**Files:**
- Modify: `deploy/versions.env`
- Modify: `notifier/go.mod`
- Modify: `notifier/go.sum`
- Modify: `notifier/Dockerfile`
- Modify: `notifier/Makefile`
- Modify: `notifier/plugin/plugin.json`
- Modify: `notifier/plugin/server/plugin_test.go`
- Modify: `notifier/integration/run.sh`
- Modify: `notifier/integration/plugin-install.sh`
- Modify: `notifier/integration/cmd/acceptance/main.go`
- Modify: `notifier/integration/cmd/acceptance/main_test.go`
- Modify: `notifier/integration/contract_test.go`
- Modify: `notifier/integration/existing_upgrade_contract_test.go`
- Modify: `deploy/scripts/validate.sh`
- Modify: `deploy/scripts/verify-notifier-artifacts.sh`
- Modify: `.github/workflows/validate.yml`

**Interfaces:**
- Consumes: current canonical fresh build paths and the exact version/digest constants in the global constraints.
- Produces: v0.2.1 bundle/image identities and a Go 1.26.8 source/build/CI contract. Historical CI continues to consume the v0.2.0 wrapper from Task 1.

- [ ] **Step 1: Add a failing current-release identity test**

Add this test to `notifier/integration/contract_test.go`:

```go
func TestFreshReleaseIdentityIsV021(t *testing.T) {
	t.Parallel()
	files := map[string][]string{
		"../../deploy/versions.env": {
			"NOTIFIER_VERSION=0.2.1",
			"GO_BUILDER_IMAGE_TAG=1.26.8-bookworm",
			"GO_BUILDER_IMAGE_DIGEST=sha256:bc6beb46032d45f421cf400036bf031cdc64f683ba9cdc124e31d063e71670bd",
			"GO_BUILDER_IMAGE_INDEX_DIGEST=sha256:9fdc884aacc3bec89b20ffc69f4bb369c78210e3e4f600387b5128b12c199f81",
		},
		"../go.mod": {"go 1.26.0", "golang.org/x/crypto v0.56.0"},
		"../plugin/plugin.json": {`"version": "0.2.1"`},
		"../Dockerfile": {"com.threadhub.channel-email-notifier-0.2.1.tar.gz"},
	}
	for path, required := range files {
		content := readContractFile(t, path)
		for _, term := range required {
			if !strings.Contains(content, term) {
				t.Fatalf("%s is missing %q", path, term)
			}
		}
	}
	workflow := readContractFile(t, "../../.github/workflows/validate.yml")
	if got := strings.Count(workflow, "go-version: 1.26.8"); got != 4 {
		t.Fatalf("Go 1.26.8 setup count = %d, want 4", got)
	}
	if !strings.Contains(workflow, "golang.org/x/vuln/cmd/govulncheck@v1.8.0 ./...") {
		t.Fatal("CI does not pin govulncheck v1.8.0")
	}
}
```

Update the existing current-integration expectations from Go `1.25.14`/govulncheck `v1.7.0` to Go `1.26.8`/govulncheck `v1.8.0`. Update the existing-upgrade workflow assertion to Go `1.26.8`; the wrapper still runs the frozen v0.2.0 tree.

- [ ] **Step 2: Run the release contract and verify it fails on the old baseline**

Run:

```bash
GOTOOLCHAIN=go1.25.14 go -C notifier test ./integration \
  -run 'TestFreshReleaseIdentityIsV021|TestCIHasBoundedPrivacySafeIntegrationArtifact|TestExistingUpgradeHarness' -count=1
```

Expected: FAIL with missing v0.2.1, Go 1.26.8, and govulncheck v1.8.0 terms.

- [ ] **Step 3: Update the exact release and builder pins**

Change the notifier portion of `deploy/versions.env` to:

```text
NOTIFIER_VERSION=0.2.1
NOTIFIER_PLUGIN_ID=com.threadhub.channel-email-notifier
NOTIFIER_MAILER_CREATED_BY_HISTORY_SHA256=dd3c3ef0e8b6b4d52bb2ee833d83f409fb4485875d3069ec5a75976c48dff82c
GO_BUILDER_IMAGE_REPOSITORY=golang
GO_BUILDER_IMAGE_TAG=1.26.8-bookworm
GO_BUILDER_IMAGE_DIGEST=sha256:bc6beb46032d45f421cf400036bf031cdc64f683ba9cdc124e31d063e71670bd
GO_BUILDER_IMAGE_INDEX_DIGEST=sha256:9fdc884aacc3bec89b20ffc69f4bb369c78210e3e4f600387b5128b12c199f81
```

The history checksum remains fixed at the current value only provisionally; Task 4 regenerates it from the v0.2.1 image and fails if the actual `created_by` array differs.

- [ ] **Step 4: Update the Go directive and only `x/crypto`**

Run in the notifier module:

```bash
cd notifier
GOTOOLCHAIN=go1.26.8 go mod edit -go=1.26.0
GOTOOLCHAIN=go1.26.8 go get golang.org/x/crypto@v0.56.0
GOTOOLCHAIN=go1.26.8 go mod tidy
GOTOOLCHAIN=go1.26.8 go mod verify
cd ..
git diff -- notifier/go.mod notifier/go.sum
```

Expected: the `go` directive changes to `1.26.0`, `x/crypto` changes to `v0.56.0`, and `go.sum` reflects that module. If another module version changes, stop and use `GOTOOLCHAIN=go1.26.8 go mod graph` to prove it is required by minimal-version selection before retaining it; otherwise restore that unrelated change.

- [ ] **Step 5: Update every current-release hardcoded identity**

Change `0.2.0` to `0.2.1` only in these current-release checks:

```text
notifier/Dockerfile bundle output
notifier/Makefile verify-dockerfile pipeline and manifest verification
notifier/plugin/plugin.json
notifier/plugin/server/plugin_test.go manifest expectation
notifier/integration/run.sh current notifier guard
notifier/integration/plugin-install.sh current notifier guard
notifier/integration/cmd/acceptance/main.go plugin verifier and classification
notifier/integration/cmd/acceptance/main_test.go current acceptance fixtures
deploy/scripts/validate.sh manifest checks
deploy/scripts/verify-notifier-artifacts.sh default bundle and image arguments
```

Do not change `run-existing-adoption.sh`, `run-existing-upgrade.sh`, any `existing-notifier-v010-v020-*` file, or generic parser/backup fixtures that use `0.2.0` as data.

- [ ] **Step 6: Update CI toolchain pins**

In `.github/workflows/validate.yml` change all four setup-go steps to:

```yaml
- name: Set up Go 1.26.8
  uses: actions/setup-go@924ae3a1cded613372ab5595356fb5720e22ba16 # v6.5.0
  with:
    go-version: 1.26.8
    cache-dependency-path: notifier/go.sum
```

Change the current notifier scan command to:

```yaml
run: go run golang.org/x/vuln/cmd/govulncheck@v1.8.0 ./...
```

- [ ] **Step 7: Run source and static release tests**

Run:

```bash
GOTOOLCHAIN=go1.26.8 go -C notifier fmt ./...
GOTOOLCHAIN=go1.26.8 go -C notifier vet ./...
GOTOOLCHAIN=go1.26.8 go -C notifier test -race ./... -count=1
./deploy/scripts/validate.sh
```

Expected: PASS. `validate.sh` must not read or print a protected `deploy/.env`.

- [ ] **Step 8: Commit Task 2**

```bash
git add .github/workflows/validate.yml deploy/versions.env \
  deploy/scripts/validate.sh deploy/scripts/verify-notifier-artifacts.sh \
  notifier/go.mod notifier/go.sum notifier/Dockerfile notifier/Makefile \
  notifier/plugin/plugin.json notifier/plugin/server/plugin_test.go \
  notifier/integration/run.sh notifier/integration/plugin-install.sh \
  notifier/integration/cmd/acceptance/main.go \
  notifier/integration/cmd/acceptance/main_test.go \
  notifier/integration/contract_test.go \
  notifier/integration/existing_upgrade_contract_test.go
git commit -m "build: publish notifier v0.2.1 baseline"
```

---

### Task 3: Prove dependency reachability and synchronize license inventory

**Files:**
- Create: `deploy/tests/notifier-dependency-security-test.sh`
- Modify: `notifier/Makefile`
- Modify: `notifier/integration/contract_test.go`
- Modify: `notifier/third_party/modules.tsv`
- Modify: `notifier/THIRD_PARTY_NOTICES.md`
- Modify: `deploy/scripts/validate.sh`
- Modify: `.github/workflows/validate.yml`

**Interfaces:**
- Consumes: the current notifier module graph and Go 1.26.8 `go list` output.
- Produces: a fail-closed `dependency-scope-check` that accepts only `x/crypto` v0.56.0 and the two reviewed built packages.

- [ ] **Step 1: Add a failing dependency-gate contract**

Add this test to `notifier/integration/contract_test.go`:

```go
func TestNotifierDependencySecurityGateIsWired(t *testing.T) {
	t.Parallel()
	gate := readContractFile(t, "../../deploy/tests/notifier-dependency-security-test.sh")
	for _, required := range []string{
		"golang.org/x/crypto v0.56.0",
		"golang.org/x/crypto/pbkdf2",
		"golang.org/x/crypto/scrypt",
		"go list -deps ./...",
	} {
		if !strings.Contains(gate, required) {
			t.Fatalf("dependency gate is missing %q", required)
		}
	}
	makefile := readContractFile(t, "../Makefile")
	workflow := readContractFile(t, "../../.github/workflows/validate.yml")
	if !strings.Contains(makefile, "dependency-scope-check:") ||
		!strings.Contains(workflow, "make dependency-scope-check") {
		t.Fatal("dependency gate is not wired into Make and CI")
	}
}
```

- [ ] **Step 2: Run the focused test and confirm the gate is absent**

Run:

```bash
GOTOOLCHAIN=go1.26.8 go -C notifier test ./integration \
  -run TestNotifierDependencySecurityGateIsWired -count=1
```

Expected: FAIL because the dependency-security script and Make target do not exist.

- [ ] **Step 3: Implement the exact package-scope gate**

Create executable `deploy/tests/notifier-dependency-security-test.sh`:

```bash
#!/usr/bin/env bash

set -Eeuo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
repository_root="$(cd -- "${script_dir}/../.." && pwd -P)"
notifier_root="${repository_root}/notifier"
temporary_dir="$(mktemp -d)"
trap 'rm -rf -- "${temporary_dir}"' EXIT HUP INT TERM

module_version="$(cd "${notifier_root}" && go list -m -f '{{.Path}} {{.Version}}' golang.org/x/crypto)"
[[ "${module_version}" == 'golang.org/x/crypto v0.56.0' ]]

(
    cd "${notifier_root}"
    go list -deps ./...
) | LC_ALL=C awk '/^golang\.org\/x\/crypto\// { print }' | LC_ALL=C sort -u \
    >"${temporary_dir}/actual"
printf '%s\n' \
    'golang.org/x/crypto/pbkdf2' \
    'golang.org/x/crypto/scrypt' \
    >"${temporary_dir}/expected"
diff -u "${temporary_dir}/expected" "${temporary_dir}/actual"
printf '%s\n' 'ok - notifier x/crypto dependency scope is exact'
```

Add `dependency-scope-check` to `.PHONY` and implement it as:

```make
dependency-scope-check:
	@../deploy/tests/notifier-dependency-security-test.sh
```

Invoke it from `make verify`, `deploy/scripts/validate.sh` only when `go` is available, and the notifier CI job before govulncheck. The explicit CI invocation is mandatory even if a minimal install host lacks Go.

- [ ] **Step 4: Synchronize license metadata**

Change the `golang.org/x/crypto` row in `notifier/third_party/modules.tsv` to:

```text
golang.org/x/crypto	v0.56.0	BSD-3-Clause	third_party/licenses/golang.org/x/crypto/LICENSE	https://cs.opensource.google/go/x/crypto/+/v0.56.0:LICENSE
```

Keep the existing BSD-3-Clause license file because the upstream license text is unchanged. Set the notice basis date to `2026-09-11` and add this factual release note to `notifier/THIRD_PARTY_NOTICES.md`:

```markdown
Notifier v0.2.1은 `golang.org/x/crypto` v0.56.0을 사용합니다. 실제 빌드 의존성은
`pbkdf2`와 `scrypt`뿐이며 SSH와 OpenPGP 패키지를 가져오지 않습니다.
```

- [ ] **Step 5: Run license, reachability, and vulnerability gates**

Run:

```bash
GOTOOLCHAIN=go1.26.8 make -C notifier dependency-scope-check
./deploy/tests/notifier-license-compliance-test.sh
GOTOOLCHAIN=go1.26.8 go -C notifier run \
  golang.org/x/vuln/cmd/govulncheck@v1.8.0 ./...
```

Expected: dependency scope PASS; license inventory PASS; govulncheck reports zero vulnerable symbols and zero vulnerable imported packages. A module-only `GO-2026-5932` OpenPGP finding may remain, but the command must exit successfully and Task 5 must document its non-applicability.

- [ ] **Step 6: Commit Task 3**

```bash
git add .github/workflows/validate.yml deploy/scripts/validate.sh \
  deploy/tests/notifier-dependency-security-test.sh notifier/Makefile \
  notifier/integration/contract_test.go notifier/third_party/modules.tsv \
  notifier/THIRD_PARTY_NOTICES.md
git commit -m "security: verify notifier crypto dependency scope"
```

---

### Task 4: Verify v0.2.1 artifact provenance and reproducibility

**Files:**
- Modify: `deploy/tests/notifier-mailer-reproducibility-test.sh`
- Modify: `notifier/integration/contract_test.go`
- Modify if and only if the reviewed history array changes: `deploy/versions.env`

**Interfaces:**
- Consumes: exact v0.2.1 source, builder digest, Gitleaks 8.30.1, and Linux AMD64 Docker BuildKit.
- Produces: reproducible v0.2.1 plugin/Mailer artifacts, a verified created-by history checksum, and the unchanged 15-scenario fresh real-image result contract.

- [ ] **Step 1: Add a failing v0.2.1 reproducibility contract**

Extend `TestFreshReleaseIdentityIsV021` so it also requires these terms in `deploy/tests/notifier-mailer-reproducibility-test.sh`:

```go
repro := readContractFile(t, "../../deploy/tests/notifier-mailer-reproducibility-test.sh")
if got := strings.Count(repro, "threadhub/notifier-plugin-bundle:0.2.1"); got != 2 {
	t.Fatalf("v0.2.1 reproducibility image count = %d, want 2", got)
}
if strings.Contains(repro, "threadhub/notifier-plugin-bundle:0.2.0") {
	t.Fatal("current reproducibility test still targets v0.2.0")
}
```

- [ ] **Step 2: Run the focused test and confirm the old image tag fails**

Run:

```bash
GOTOOLCHAIN=go1.26.8 go -C notifier test ./integration \
  -run TestFreshReleaseIdentityIsV021 -count=1
```

Expected: FAIL because the current reproducibility test still inspects the v0.2.0 plugin-bundle image.

- [ ] **Step 3: Update only the current reproducibility image references**

In `deploy/tests/notifier-mailer-reproducibility-test.sh`, change both inspected plugin-bundle tags from `0.2.0` to `0.2.1`. Do not change `deploy/tests/notifier-artifact-security-test.sh`; it deliberately passes an explicit fixture image reference and does not represent the canonical release.

- [ ] **Step 4: Build exact Linux AMD64 artifacts**

On an Ubuntu 24.04 AMD64 runner with Docker BuildKit, run:

```bash
GOTOOLCHAIN=go1.26.8 make -C notifier plugin-bundle mailer
```

Expected artifacts:

```text
notifier/dist/com.threadhub.channel-email-notifier-0.2.1.tar.gz
threadhub/notifier-plugin-bundle:0.2.1
threadhub/notifier-mailer:0.2.1
```

- [ ] **Step 5: Regenerate and compare the Mailer created-by checksum**

Run on the same Linux Docker runner:

```bash
set -Eeuo pipefail
image_id="$(docker image inspect --format '{{.Id}}' threadhub/notifier-mailer:0.2.1)"
temporary_dir="$(mktemp -d)"
trap 'rm -rf -- "${temporary_dir}"' EXIT HUP INT TERM
docker image save --output "${temporary_dir}/image.tar" "${image_id}"
tar -xf "${temporary_dir}/image.tar" -C "${temporary_dir}"
config_name="$(jq -er '.[0].Config' "${temporary_dir}/manifest.json")"
history_sha="$(jq -c '[.history[].created_by]' "${temporary_dir}/${config_name}" \
  | sha256sum | awk '{print $1}')"
test "${history_sha}" = dd3c3ef0e8b6b4d52bb2ee833d83f409fb4485875d3069ec5a75976c48dff82c
```

Expected: PASS because the final scratch-stage instruction history is unchanged. If it fails, stop the release and inspect the compact `created_by` array for an unintended Dockerfile or engine change; do not refresh the pin automatically.

- [ ] **Step 6: Run artifact, secret, reproducibility, and fresh real-image gates**

Use the pinned Gitleaks 8.30.1 binary installed by the CI workflow, then run:

```bash
GOTOOLCHAIN=go1.26.8 make -C notifier verify-artifacts
GITLEAKS_BIN="${RUNNER_TEMP}/gitleaks/gitleaks" \
  ./deploy/scripts/verify-notifier-artifacts.sh
./deploy/tests/notifier-mailer-reproducibility-test.sh
GOTOOLCHAIN=go1.26.8 make -C notifier integration
```

Expected: artifact rootfs/history/license/secret checks PASS, two clean-tree builds produce the same Mailer and plugin-bundle identities, and all 15 fresh notifier scenarios PASS.

- [ ] **Step 7: Commit Task 4**

```bash
git add deploy/tests/notifier-mailer-reproducibility-test.sh \
  notifier/integration/contract_test.go deploy/versions.env
git commit -m "test: verify notifier v0.2.1 artifacts"
```

If `deploy/versions.env` is byte-identical after checksum verification, omit it from `git add`.

---

### Task 5: Document fresh v0.2.1 and legacy-held v0.2.0 without ambiguity

**Files:**
- Modify: `deploy/scripts/notifier-documentation-contracts.sh`
- Modify: `deploy/docs/canonical-runtime-standard.md`
- Modify: `deploy/docs/quick-install.md`
- Modify: `deploy/docs/notifier-architecture.md`
- Modify: `deploy/docs/existing-mattermost-notifier.md`
- Modify: `deploy/docs/security-image-review-2026-09-07.md`
- Modify: `deploy/docs/test-plan.md`
- Modify: `deploy/docs/test-results-public.md`
- Modify: `docs/superpowers/specs/2026-09-11-notifier-v021-security-maintenance-design.md`

**Interfaces:**
- Consumes: verified release identities and security results from Tasks 2–4.
- Produces: one unambiguous operator rule: new canonical fresh installs use v0.2.1; installed v0.2.0 services remain legacy-held; the old v0.1.0-to-v0.2.0 tools are historical and do not authorize v0.2.1 deployment.

- [ ] **Step 1: Add failing documentation contracts**

Add these required terms to `validate_notifier_documentation_contracts`:

```bash
notifier_docs_require_terms "${canonical_standard}" \
    'fresh v0.2.1 and legacy-held v0.2.0 boundary' \
    '신규 canonical fresh 설치는 notifier v0.2.1' \
    '기존 v0.2.0 인스턴스는 `legacy-held`' \
    '저장소 갱신만으로 실행 중인 notifier가 바뀌지 않는다' \
    'v0.2.0에서 v0.2.1로 전환하는 도구를 제공하지 않는다' || return 1

notifier_docs_require_terms "${deploy_dir}/docs/test-plan.md" \
    'notifier v0.2.1 security evidence' \
    'Go 1.26.8' 'govulncheck v1.8.0' \
    'golang.org/x/crypto v0.56.0' \
    'run-v020-history.sh existing-adoption' \
    'run-v020-history.sh existing-upgrade' || return 1
```

Also require `quick-install.md` to say `NOTIFIER_VERSION=0.2.1`, `existing-mattermost-notifier.md` to call its v0.2.0 flow historical, and the security review to distinguish notifier source-build OpenPGP non-reachability from Mattermost's plugin-signature OpenPGP path.

- [ ] **Step 2: Run documentation validation and verify it fails**

Run:

```bash
./deploy/tests/notifier-documentation-test.sh
```

Expected: FAIL because the fresh v0.2.1/legacy-held v0.2.0 language is absent.

- [ ] **Step 3: Update the canonical and installation documents**

Make these exact policy statements:

- `canonical-runtime-standard.md`: canonical fresh uses notifier v0.2.1; existing v0.2.0 is `legacy-held`; no v0.2.0-to-v0.2.1 tool exists; reconsider only for a reachable finding, behavior/source change, required rebuild, or separately approved maintenance.
- `quick-install.md`: a clean checkout builds v0.2.1 only for a fresh empty `/srv/threadhub`; pulling source never mutates an installed runtime; operators must not use the quick installer on an existing instance.
- `notifier-architecture.md`: v0.2.1 changes no recipients, content, queue schema, SMTP behavior, `all_channels` default, or Mattermost license boundary.
- `existing-mattermost-notifier.md`: the v0.1.0-to-v0.2.0 section is an exact historical procedure; it neither installs nor upgrades to v0.2.1.

Retain the existing historical source commit and all v0.1.0/v0.2.0 scenario language.

- [ ] **Step 4: Add the dated notifier-specific security disposition**

Append a `2026-09-11 notifier v0.2.1 source-build review` subsection to `security-image-review-2026-09-07.md` that records:

```text
Go directive: 1.26.0
Go builder: 1.26.8-bookworm, exact AMD64 and index digests from deploy/versions.env
golang.org/x/crypto: v0.56.0
govulncheck: v1.8.0
GO-2026-6355: removed from the fresh module graph
GO-2026-6354: removed from the fresh module graph
GO-2026-5932: module-only; no notifier OpenPGP import
built x/crypto packages: pbkdf2, scrypt
existing v0.2.0 runtime: legacy-held and not changed by this review
```

Do not rewrite the earlier Mattermost 11.10.1 OpenPGP analysis: that path concerns Mattermost plugin-signature verification, not notifier source reachability.

- [ ] **Step 5: Update test planning and public evidence wording**

In `test-plan.md`, identify the current fresh commands and the two historical wrapper commands separately. In `test-results-public.md`, add a planned v0.2.1 evidence paragraph without adding a `pass` row before the exact CI commit succeeds. State that the final CI artifact, not a live instance, is the evidence and that no production deployment was performed.

- [ ] **Step 6: Run documentation and full static validation**

Run:

```bash
./deploy/tests/notifier-documentation-test.sh
./deploy/scripts/validate.sh
```

Expected: PASS while all exact historical transition documentation contracts remain present.

- [ ] **Step 7: Commit Task 5**

```bash
git add deploy/scripts/notifier-documentation-contracts.sh \
  deploy/docs/canonical-runtime-standard.md deploy/docs/quick-install.md \
  deploy/docs/notifier-architecture.md deploy/docs/existing-mattermost-notifier.md \
  deploy/docs/security-image-review-2026-09-07.md deploy/docs/test-plan.md \
  deploy/docs/test-results-public.md \
  docs/superpowers/specs/2026-09-11-notifier-v021-security-maintenance-design.md
git commit -m "docs: define notifier v0.2.1 fresh release boundary"
```

---

### Task 6: Run the complete repository and CI release gate

**Files:**
- Modify only if validation exposes a defect in Tasks 1–5: the owning task's files and tests.
- Verify: entire repository and Git history.

**Interfaces:**
- Consumes: all prior task commits.
- Produces: one reviewed commit with local/static evidence, Linux Docker evidence, preserved historical v0.2.0 evidence, and no live deployment side effect.

- [ ] **Step 1: Prove the worktree and historical scripts are cleanly scoped**

Run:

```bash
git status --short
git diff 7602555a21fe5e110eafa1d685a61c95d53969d8 -- \
  notifier/integration/run-existing-adoption.sh \
  notifier/integration/run-existing-upgrade.sh \
  notifier/integration/existing-upgrade-scenario-ids.txt \
  deploy/scripts/existing-notifier-v010-v020-common.sh \
  deploy/scripts/existing-notifier-v010-v020-preflight.sh \
  deploy/scripts/existing-notifier-v010-v020-upgrade.sh \
  deploy/scripts/existing-notifier-v010-v020-rollback.sh
```

Expected: the first command is clean after task commits; the second command has no output for the protected historical files.

- [ ] **Step 2: Run complete non-container validation**

Run:

```bash
./deploy/scripts/validate.sh
test -z "$(cd notifier && gofmt -l .)"
GOTOOLCHAIN=go1.26.8 go -C notifier mod verify
GOTOOLCHAIN=go1.26.8 go -C notifier vet ./...
GOTOOLCHAIN=go1.26.8 go -C notifier test -race ./... -count=1
GOTOOLCHAIN=go1.26.8 make -C notifier dependency-scope-check
./deploy/tests/notifier-license-compliance-test.sh
GOTOOLCHAIN=go1.26.8 go -C notifier run \
  golang.org/x/vuln/cmd/govulncheck@v1.8.0 ./...
```

Expected: every command exits 0; govulncheck has no vulnerable symbol or imported-package findings.

- [ ] **Step 3: Scan repository history for secrets**

With the pinned Gitleaks 8.30.1 binary, run:

```bash
gitleaks git --redact --no-banner --exit-code 1 .
```

Expected: exit 0 and no finding. Do not upload a raw report containing matched values.

- [ ] **Step 4: Run all required GitHub Actions jobs**

After receiving approval to publish the branch, push it and open a pull request. Require these jobs to pass at the exact head commit:

```text
validate
backup-restore-integration
notifier-integration
notifier-mailer-reproducibility
notifier-existing-adoption
notifier-existing-upgrade
```

The first four exercise the current v0.2.1 repository. The last two must report evidence from the pinned v0.2.0 historical worktree and must not build current v0.2.1 as an existing-instance transition.

- [ ] **Step 5: Review CI evidence without publishing private diagnostics**

Confirm:

```text
fresh notifier scenario count = 15
historical existing-adoption scenario count = 10
historical existing-upgrade scenario count = 12
artifact paths contain only approved aggregate/status files
notifier version in fresh artifact evidence = 0.2.1
source/target versions in historical upgrade evidence = 0.1.0/0.2.0
```

Do not copy raw diagnostic, queue, environment, recipient, Team/channel/post, or SMTP data into the repository or pull request.

- [ ] **Step 6: Record the verified public evidence state**

Only after the exact head commit's CI succeeds, update `deploy/docs/test-results-public.md` with the privacy-safe fresh artifact values generated by that run, rerun `./deploy/scripts/validate.sh`, and commit:

```bash
git add deploy/docs/test-results-public.md
git commit -m "docs: record notifier v0.2.1 verification evidence"
```

If the evidence commit changes a CI-consumed file, require the complete job set to pass again at the new head commit before merge.

- [ ] **Step 7: Final scope check**

Run:

```bash
git status --short
git log --oneline --decorate -8
git diff --check origin/main...HEAD
```

Expected: clean worktree, no whitespace errors, and only repository changes described by this plan. No OCI, DNS, SMTP, certificate, VM, container, user, Team, channel, post, file, backup, or production runtime operation is part of completion.

---

## Completion Gate

The implementation is complete only when all six tasks pass at one reviewed commit, the current fresh evidence identifies notifier v0.2.1, the historical evidence remains v0.1.0-to-v0.2.0, and the branch contains no secret or private operational evidence. Repository readiness does not authorize deployment to `threadhub.stillwhy.com`, any other live hostname, or any existing `/srv/threadhub` tree.
