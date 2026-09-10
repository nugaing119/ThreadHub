package integration_test

import (
	"os"
	"strings"
	"testing"
)

func TestExistingUpgradeHarnessCoversExactReversibleTransition(t *testing.T) {
	t.Parallel()

	scenarios := []string{
		"NF-UPGRADE-01", "NF-UPGRADE-02", "NF-UPGRADE-03", "NF-UPGRADE-04",
		"NF-UPGRADE-05", "NF-UPGRADE-06", "NF-UPGRADE-07", "NF-UPGRADE-08",
		"NF-UPGRADE-09", "NF-UPGRADE-10", "NF-UPGRADE-11", "NF-UPGRADE-12",
	}
	for _, path := range []string{
		"run-existing-upgrade.sh",
		"existing-upgrade-scenario-ids.txt",
		"existing/docker-compose.yml",
		"cmd/existing-acceptance/main.go",
	} {
		if _, err := os.Stat(path); err != nil {
			t.Fatalf("existing-upgrade harness path %q is missing: %v", path, err)
		}
	}

	runner := readContractFile(t, "run-existing-upgrade.sh")
	ids := readContractFile(t, "existing-upgrade-scenario-ids.txt")
	workflow := readContractFile(t, "../../.github/workflows/validate.yml")

	for _, id := range scenarios {
		if !strings.Contains(runner, id) || !strings.Contains(ids, id) {
			t.Fatalf("existing-upgrade scenario contract %q is incomplete", id)
		}
	}
	if got := len(strings.Fields(ids)); got != len(scenarios) {
		t.Fatalf("existing-upgrade scenario count = %d, want %d", got, len(scenarios))
	}

	for _, required := range []string{
		"c193155eeb6298771d4366d6af4cae81499487b8",
		"git -C \"${repository_root}\" archive --format=tar",
		"existing-notifier-v010-v020-recovery-gate.sh",
		"existing-notifier-v010-v020-preflight.sh",
		"existing-notifier-v010-v020-upgrade.sh",
		"existing-notifier-v010-v020-rollback.sh",
		"queue-inspect --json",
		"schema_version == 1",
		"schema_version == 2",
		"base-compose-before.sha256",
		"base-env-before.sha256",
		"source-release-before.sha256",
		"source-override-before.sha256",
		"project_team_channel",
		"counts-before-transition",
		"counts-after-transition",
		"failure-after-plugin-publication",
		"failure-after-schema-migration",
		"explicit-rollback",
		"second-transition",
		"successful-transition-queue-snapshot",
		"successful-transition-smtp-failure-injection",
		"successful-transition-outage-post",
		"successful-transition-queue-pending",
		"successful-transition-queue-pending-status-unavailable",
		"successful-transition-queue-pending-empty",
		"successful-transition-queue-pending-sending",
		"successful-transition-queue-pending-failed",
		"successful-transition-queue-pending-unexpected",
		"successful-transition-outage-recovery",
		"successful-transition-queue-idle",
		"existing-notifier-smtp-test.sh",
		"activate-allowlist",
		"public-root",
		"public-thread",
		"private-root",
		"private-thread",
		"enabled == false and .delivery_enabled == false",
		"nf_scenario_count=12",
		"down --volumes --remove-orphans",
	} {
		if !strings.Contains(runner, required) {
			t.Fatalf("existing-upgrade runner contract is missing %q", required)
		}
	}
	if !strings.Contains(runner, "queue_pending_failure_class") ||
		!strings.Contains(runner, `record_stage "${failure_stage}"`) {
		t.Fatal("queue pending timeout does not publish a bounded privacy-safe state class")
	}
	for _, required := range []string{
		"private acceptance snapshot || return 1",
		"private inject_smtp_failures 2 || return 1",
		"private acceptance outage-post || return 1",
		"private wait_queue_pending || return 1",
		"private acceptance assert-outage || return 1",
		"private wait_queue_idle || return 1",
	} {
		if !strings.Contains(runner, required) {
			t.Fatalf("source queue history fail-closed contract is missing %q", required)
		}
	}
	for _, forbidden := range []string{
		"git checkout", "git reset", "activate-all-channels", "source deploy/.env",
		"docker compose config\n", "rm -rf /srv", "--force", "--retry-failed", "--cancel-failed",
	} {
		if strings.Contains(runner, forbidden) {
			t.Fatalf("existing-upgrade runner contains forbidden contract %q", forbidden)
		}
	}

	for _, required := range []string{
		"notifier-existing-upgrade:",
		"needs: [notifier-integration, notifier-existing-adoption]",
		"timeout-minutes: 60",
		"fetch-depth: 0",
		"go-version: 1.25.14",
		"run-existing-upgrade.sh",
		"threadhub-existing-upgrade-evidence",
		"retention-days: 7",
	} {
		if !strings.Contains(workflow, required) {
			t.Fatalf("existing-upgrade CI contract is missing %q", required)
		}
	}
}
