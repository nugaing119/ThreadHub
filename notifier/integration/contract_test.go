package integration_test

import (
	"os"
	"os/exec"
	"strings"
	"testing"
)

func TestHarnessFileModeDetectionIsCrossPlatform(t *testing.T) {
	t.Parallel()

	temporaryFile, err := os.CreateTemp(t.TempDir(), "mode-test-")
	if err != nil {
		t.Fatal(err)
	}
	if err := temporaryFile.Close(); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(temporaryFile.Name(), 0o600); err != nil {
		t.Fatal(err)
	}

	command := exec.Command(
		"bash",
		"-c",
		`source ./harness-lib.sh; notifier_harness_file_mode "$1"`,
		"bash",
		temporaryFile.Name(),
	)
	output, err := command.CombinedOutput()
	if err != nil {
		t.Fatalf("cross-platform mode probe failed: %v: %s", err, output)
	}
	if got := string(output); got != "600" {
		t.Fatalf("cross-platform mode probe = %q, want 600", got)
	}

	runner := readContractFile(t, "run.sh")
	for _, required := range []string{
		`source "${script_dir}/harness-lib.sh"`,
		`notifier_harness_file_mode "${integration_env}"`,
		`notifier_harness_file_mode "${diagnostic_file}"`,
	} {
		if !strings.Contains(runner, required) {
			t.Fatalf("runner cross-platform mode contract is missing %q", required)
		}
	}
	if strings.Contains(runner, `stat -f '%Lp' "${integration_env}" 2>/dev/null || stat -c '%a'`) {
		t.Fatal("runner combines failed BSD stat output with GNU stat output")
	}
}

func TestHarnessPinsIsolationAndNoImplicitBuildContracts(t *testing.T) {
	t.Parallel()

	compose := readContractFile(t, "docker-compose.yml")
	for _, required := range []string{
		"${MATTERMOST_IMAGE_REPOSITORY:",
		"${MATTERMOST_IMAGE_DIGEST:",
		"${POSTGRES_IMAGE_REPOSITORY:",
		"${POSTGRES_IMAGE_DIGEST:",
		`"127.0.0.1::8065"`,
		`"127.0.0.1::8080"`,
		`"127.0.0.1::8081"`,
		"internal: true",
		"pull_policy: never",
		"SSL_CERT_FILE: /run/smtp-ca/ca.crt",
	} {
		if !strings.Contains(compose, required) {
			t.Fatalf("Compose contract is missing %q", required)
		}
	}
	if strings.Contains(compose, ":latest") {
		t.Fatal("Compose contract contains a latest tag")
	}
	for _, required := range []string{
		`/threadhub-deploy/notifier-plugin-files.sh:ro`,
		`/threadhub-deploy/notifier-plugin-transaction.sh:ro`,
		`/threadhub-install/plugin-install.sh:ro`,
		`../plugin/plugin.json:/reviewed/plugin.json:ro`,
		`threadhub-data:/threadhub-data:rw`,
		`MM_FILESETTINGS_DIRECTORY: /threadhub-data/mattermost/data`,
		`MM_PLUGINSETTINGS_DIRECTORY: /threadhub-data/mattermost/plugins`,
		`MM_PLUGINSETTINGS_CLIENTDIRECTORY: /threadhub-data/mattermost/client/plugins`,
	} {
		if !strings.Contains(compose, required) {
			t.Fatalf("shared production plugin install contract is missing %q", required)
		}
	}
	if strings.Contains(compose, "/filestore/plugins/${NOTIFIER_PLUGIN_ID}.tar.gz") {
		t.Fatal("Compose retains the harness-only direct filestore installer")
	}

	runner := readContractFile(t, "run.sh")
	for _, required := range []string{
		`compose_private config --quiet`,
		`--platform linux/amd64`,
		`"${container_command[1]}" == --remote`,
		`"${container_command[2]}" == --url`,
		`[[ "${container_socket}" == /* && -S "${container_socket}" ]]`,
		`--label "com.docker.compose.project=${project_name}"`,
		`--label com.docker.compose.service=plugin-bundle`,
		`up -d --no-build --wait --wait-timeout 120 smtp-fixture`,
		`up -d --no-build --wait --wait-timeout 120 threadhub-mailer`,
		`result_assertion=NF-HARNESS-plugin-stop`,
		`result_assertion=NF-HARNESS-plugin-install`,
		`result_assertion=NF-HARNESS-plugin-reinit`,
		`result_assertion=NF-HARNESS-plugin-restart`,
		`result_assertion=NF-HARNESS-plugin-enable`,
		`result_assertion=NF-HARNESS-plugin-active-list`,
		`result_assertion=NF-HARNESS-plugin-pair`,
		`result_assertion=NF-HARNESS-plugin-pair-tamper`,
		`result_assertion=NF-HARNESS-plugin-pair-negative`,
		`compose_private run --rm --no-deps plugin-install verify`,
		`compose_private run --rm --no-deps plugin-install tamper-bundle`,
		`tamper_verify_status=$?`,
		`[[ "${tamper_verify_status}" -eq 42 ]]`,
		`mmctl plugin list --local --suppress-warnings --json`,
		`source "${repository_root}/deploy/scripts/notifier-lib.sh"`,
		`notifier_plugin_list_target_state`,
		`rm -rf -- "${integration_root}"`,
		`compose_run stop --timeout 10`,
		`compose_run run --rm --no-deps volume-cleanup`,
	} {
		if !strings.Contains(runner, required) {
			t.Fatalf("runner contract is missing %q", required)
		}
	}
	if strings.Count(runner, "compose_private up -d --no-build") < 5 {
		t.Fatal("runner does not forbid implicit builds for every runtime start")
	}
	if strings.Contains(runner, "./integration/cmd/plugin-state") {
		t.Fatal("runner builds a harness-only plugin-state parser")
	}
	stopIndex := strings.Index(runner, `compose_run stop --timeout 10`)
	ownershipIndex := strings.Index(runner, `compose_run run --rm --no-deps volume-cleanup`)
	downIndex := strings.Index(runner, `compose_run down --volumes --remove-orphans --timeout 10`)
	if stopIndex < 0 || ownershipIndex <= stopIndex || downIndex <= ownershipIndex {
		t.Fatal("runner does not stop services, restore host ownership, then remove the project")
	}

	for _, required := range []string{
		"  volume-cleanup:\n",
		`chown -R ${INTEGRATION_HOST_UID:?set INTEGRATION_HOST_UID}:${INTEGRATION_HOST_UID}`,
		`/integration/postgres`,
		`/integration/mattermost-host`,
		`/integration/mailer`,
		`/integration/control`,
	} {
		if !strings.Contains(compose, required) {
			t.Fatalf("host ownership cleanup contract is missing %q", required)
		}
	}

	installer := readContractFile(t, "plugin-install.sh")
	for _, required := range []string{
		`source /threadhub-deploy/notifier-plugin-files.sh`,
		`source /threadhub-deploy/notifier-plugin-transaction.sh`,
		`notifier_plugin_stage_pair`,
		`notifier_plugin_transaction`,
		`runtime_parent="${data_root}/mattermost/plugins"`,
		`filestore_parent="${data_root}/mattermost/data/plugins"`,
		`target_root="${runtime_parent}/${plugin_id}"`,
		`bundle_target="${filestore_parent}/${plugin_id}.tar.gz"`,
		`tampered_bundle="${release_dir}/.${plugin_id}.integration-tampered-bundle"`,
		`[[ "${mode}" == install || "${mode}" == verify || "${mode}" == tamper-bundle ]]`,
		`if [[ "${mode}" == tamper-bundle ]]`,
		`notifier_plugin_pair_is_exact`,
		`plugin_tx_verify_previous_objects`,
	} {
		if !strings.Contains(installer, required) {
			t.Fatalf("integration installer does not exercise shared production behavior %q", required)
		}
	}
	if strings.Contains(installer, `notifier_plugin_move_no_clobber "${bundle_target}" "${bundle_failed}"`) {
		t.Fatal("integration tamper reuses a transaction PID-scoped failure slot")
	}
}

func TestProductionBuildContextExcludesIntegrationHarness(t *testing.T) {
	t.Parallel()

	dockerignore := readContractFile(t, "../.dockerignore")
	for _, required := range []string{
		"integration\n",
		"!integration/\n",
		"integration/*\n",
		"!integration/cmd/\n",
		"integration/cmd/*\n",
		"!integration/cmd/smtp-fixture/\n",
		"integration/cmd/smtp-fixture/*\n",
		"!integration/cmd/smtp-fixture/main.go\n",
	} {
		if !strings.Contains(dockerignore, required) {
			t.Fatalf("Docker build context contract is missing %q", required)
		}
	}
	for _, forbidden := range []string{
		"!integration/run.sh",
		"!integration/docker-compose.yml",
		"!integration/cmd/acceptance",
		"!integration/cmd/smtp-fixture/main_test.go",
	} {
		if strings.Contains(dockerignore, forbidden) {
			t.Fatalf("production Docker build context includes harness-only path %q", forbidden)
		}
	}
}

func TestSMTPFixtureUsesMinimalNonRootRuntimeImage(t *testing.T) {
	t.Parallel()

	compose := readContractFile(t, "docker-compose.yml")
	start := strings.Index(compose, "  smtp-fixture:\n")
	end := strings.Index(compose, "  mattermost:\n")
	if start < 0 || end <= start {
		t.Fatal("could not isolate smtp-fixture Compose service")
	}
	service := compose[start:end]
	for _, required := range []string{
		`image: "threadhub/notifier-smtp-fixture:${NOTIFIER_VERSION:`,
		"pull_policy: never",
		`user: "65532:65532"`,
		"cap_drop:\n      - ALL",
		"cap_add:\n      - NET_BIND_SERVICE",
		"no-new-privileges:true",
		"read_only: true",
		"FIXTURE_STATE_PATH: /run/smtp-private/captures.json",
		"- /smtp-fixture\n        - healthcheck",
	} {
		if !strings.Contains(service, required) {
			t.Fatalf("smtp-fixture runtime contract is missing %q", required)
		}
	}
	for _, forbidden := range []string{"go run", "/bin/bash", "/src", "GOCACHE"} {
		if strings.Contains(service, forbidden) {
			t.Fatalf("smtp-fixture runtime contains forbidden toolchain/source contract %q", forbidden)
		}
	}

	composeInit := compose[:strings.Index(compose, "  plugin-bundle:\n")]
	for _, required := range []string{
		"chown -R 65532:65532 /integration/smtp-private",
		"chown -R 65532:65532 /integration/smtp-ca",
		"chmod 0700 /integration/smtp-private",
		"chmod 0700 /integration/smtp-ca",
		"smtp-private:/integration/smtp-private:rw",
		"smtp-ca:/integration/smtp-ca:rw",
	} {
		if !strings.Contains(composeInit, required) {
			t.Fatalf("volume-init SMTP ownership contract is missing %q", required)
		}
	}

	dockerfile := readContractFile(t, "../Dockerfile")
	for _, required := range []string{
		"AS smtp-fixture-build",
		"./integration/cmd/smtp-fixture",
		"FROM scratch AS smtp-fixture",
		"COPY --from=smtp-fixture-build /out/smtp-fixture /smtp-fixture",
		"USER 65532:65532",
		`ENTRYPOINT ["/smtp-fixture"]`,
		`CMD ["serve"]`,
	} {
		if !strings.Contains(dockerfile, required) {
			t.Fatalf("SMTP fixture image contract is missing %q", required)
		}
	}

	runner := readContractFile(t, "run.sh")
	for _, required := range []string{
		`smtp_image="threadhub/notifier-smtp-fixture:${notifier_version}"`,
		"--target smtp-fixture --tag \"${smtp_image}\"",
		`image inspect --format '{{.Config.User}}' "${smtp_image}"`,
		`image inspect --format '{{json .Config.Entrypoint}}' "${smtp_image}"`,
		`image inspect --format '{{json .Config.Cmd}}' "${smtp_image}"`,
	} {
		if !strings.Contains(runner, required) {
			t.Fatalf("SMTP fixture build verification is missing %q", required)
		}
	}
	if strings.Contains(runner, "pull --quiet postgres mattermost smtp-fixture") {
		t.Fatal("runner attempts to pull the locally built SMTP fixture image")
	}
}

func TestCIHasBoundedPrivacySafeIntegrationArtifact(t *testing.T) {
	t.Parallel()

	workflow := readContractFile(t, "../../.github/workflows/validate.yml")
	for _, required := range []string{
		"notifier-integration:",
		"timeout-minutes: 25",
		"go-version: 1.25.10",
		"make test",
		"make plugin-bundle mailer",
		"make integration",
		"threadhub-notifier-integration-artifacts/results.txt",
		`"${artifact_dir}/bundle-sha256.txt"`,
	} {
		if !strings.Contains(workflow, required) {
			t.Fatalf("CI contract is missing %q", required)
		}
	}
	for _, forbidden := range []string{"integration.env", "queue.db", "ca.crt", "compose-diagnostic"} {
		if strings.Contains(workflow, "path: "+forbidden) {
			t.Fatalf("CI artifact path exposes %q", forbidden)
		}
	}
}

func readContractFile(t *testing.T, path string) string {
	t.Helper()
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	return string(raw)
}
