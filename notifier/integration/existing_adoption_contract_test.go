package integration_test

import (
	"os"
	"strings"
	"testing"
)

func TestExistingAdoptionHarnessCoversFailClosedLifecycle(t *testing.T) {
	t.Parallel()

	scenarios := []string{
		"NF-ADOPT-01", "NF-ADOPT-02", "NF-ADOPT-03", "NF-ADOPT-04", "NF-ADOPT-05",
		"NF-ADOPT-06", "NF-ADOPT-07", "NF-ADOPT-08", "NF-ADOPT-09", "NF-ADOPT-10",
	}
	for _, path := range []string{
		"run-existing-adoption.sh",
		"existing/docker-compose.yml",
		"cmd/existing-acceptance/main.go",
		"cmd/existing-acceptance/scenario-ids.txt",
	} {
		if _, err := os.Stat(path); err != nil {
			t.Fatalf("existing-adoption harness path %q is missing: %v", path, err)
		}
	}

	runner := readContractFile(t, "run-existing-adoption.sh")
	compose := readContractFile(t, "existing/docker-compose.yml")
	ids := readContractFile(t, "cmd/existing-acceptance/scenario-ids.txt")
	workflow := readContractFile(t, "../../.github/workflows/validate.yml")
	testPlan := readContractFile(t, "../../deploy/docs/test-plan.md")
	publicResults := readContractFile(t, "../../deploy/docs/test-results-public.md")
	freshRunner := readContractFile(t, "run.sh")

	for _, id := range scenarios {
		if !strings.Contains(runner, id) || !strings.Contains(ids, id) || !strings.Contains(testPlan, id) {
			t.Fatalf("existing-adoption scenario contract %q is incomplete", id)
		}
	}
	for _, required := range []string{
		"existing-notifier-preflight.sh",
		"existing-notifier-setup.sh",
		"--resume --non-interactive",
		"existing-notifier-smtp-test.sh",
		"existing-notifier-control.sh",
		"activate-allowlist",
		"existing-notifier-rollback.sh",
		"base-compose-before.sha256",
		"base-env-before.sha256",
		"queue-before-rollback.sha256",
		"down --volumes --remove-orphans",
		"timeout --foreground --kill-after=10s 180s env",
		"elapsed_seconds=%s",
		"smtp_acceptance_failure=",
		"smtp_acceptance_phase=",
		"run_smtp_stdin",
		"--recipient-stdin",
		"--channel-ids-stdin",
		"acceptance_exercise_failure=",
		"acceptance_exercise_reason=",
		"mailer_queue_state=",
		"safe_mailer_queue_state",
		"error_class-",
		"under-delivery | over-delivery | mixed-count",
		"[HARNESS] acceptance-exercise-start",
		"compose_base up -d --no-build --no-deps smtp-fixture",
		"wait_http 'http://127.0.0.1:49353/healthz' 60",
		".pending > 0 and .sending == 0 and .failed == 0",
	} {
		if !strings.Contains(runner, required) {
			t.Fatalf("existing-adoption runner contract is missing %q", required)
		}
	}
	for _, required := range []string{
		`username <> 'system-bot'`,
		"db_system_bot_valid",
		"record_stage disabled-system-bot",
	} {
		if !strings.Contains(runner, required) {
			t.Fatalf("existing-adoption runner does not isolate Mattermost's system bot: missing %q", required)
		}
	}
	for _, forbidden := range []string{"source deploy/.env", "docker compose config\n", "rm -rf /srv"} {
		if strings.Contains(runner, forbidden) {
			t.Fatalf("existing-adoption runner contains forbidden contract %q", forbidden)
		}
	}
	for _, required := range []string{
		"MATTERMOST_IMAGE_REPOSITORY",
		"/mattermost/plugins",
		"/mattermost/data",
		"127.0.0.1",
		"smtp-fixture",
	} {
		if !strings.Contains(compose, required) {
			t.Fatalf("existing-adoption Compose contract is missing %q", required)
		}
	}
	for _, required := range []string{
		"notifier-existing-adoption:",
		"timeout-minutes: 45",
		"run-existing-adoption.sh",
	} {
		if !strings.Contains(workflow, required) {
			t.Fatalf("existing-adoption CI contract is missing %q", required)
		}
	}
	if !strings.Contains(publicResults, "existing-adoption") || !strings.Contains(publicResults, "10") {
		t.Fatal("public results omit privacy-safe existing-adoption evidence")
	}
	if !strings.Contains(freshRunner, `== 15`) || !strings.Contains(freshRunner, `scenario_ids_file`) {
		t.Fatal("fresh integration no longer pins its established 15-scenario result")
	}
}
