package main

import (
	"bytes"
	"context"
	"encoding/hex"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"reflect"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/nugaing119/ThreadHub/notifier/protocol"
)

func TestLoadConfigRequiresPrivateIntegrationEndpointsAndPrivateFiles(t *testing.T) {
	t.Parallel()

	root := t.TempDir()
	envFile := filepath.Join(root, "integration.env")
	if err := os.WriteFile(envFile, []byte("fixture\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	controlFile := filepath.Join(root, "state.json")
	if err := os.WriteFile(controlFile, []byte("{}\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "docker-compose.yml"), []byte("services: {}\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	values := validConfigValues(root, envFile, controlFile)
	cfg, err := loadConfig(func(key string) string { return values[key] })
	if err != nil {
		t.Fatalf("loadConfig() error = %v", err)
	}
	if cfg.mattermostURL.Hostname() != "172.20.0.10" || cfg.mailerURL.Hostname() != "172.20.0.11" || cfg.captureURL.Hostname() != "172.20.0.12" {
		t.Fatal("loadConfig() did not preserve private integration endpoints")
	}

	values["INTEGRATION_MAILER_URL"] = "http://8.8.8.8:8080"
	if _, err := loadConfig(func(key string) string { return values[key] }); err == nil {
		t.Fatal("loadConfig() accepted a public Mailer endpoint")
	}
}

func TestParseContainerIPv4AcceptsOnePrivateAddress(t *testing.T) {
	t.Parallel()

	if got, err := parseContainerIPv4([]byte("172.20.0.10\n")); err != nil || got != "172.20.0.10" {
		t.Fatalf("parseContainerIPv4() = %q, %v", got, err)
	}
	for _, value := range []string{"", "8.8.8.8\n", "127.0.0.1\n", "172.20.0.10\n172.20.0.11\n", "::1\n", "not-an-ip\n"} {
		if _, err := parseContainerIPv4([]byte(value)); err == nil {
			t.Fatalf("parseContainerIPv4(%q) unexpectedly succeeded", value)
		}
	}
}

func TestParseIntegrationURLSupportsPrivateDockerAndLoopbackPodmanEndpoints(t *testing.T) {
	t.Parallel()

	for _, value := range []string{"http://172.20.0.10:8065", "http://127.0.0.1:49152"} {
		if _, err := parseIntegrationURL(value); err != nil {
			t.Fatalf("parseIntegrationURL(%q): %v", value, err)
		}
	}
	for _, value := range []string{"https://172.20.0.10:8065", "http://8.8.8.8:8065", "http://[::1]:8065", "http://localhost:8065"} {
		if _, err := parseIntegrationURL(value); err == nil {
			t.Fatalf("parseIntegrationURL(%q) unexpectedly succeeded", value)
		}
	}
}

func TestNewSignedRequestCoversTimestampNonceAndBody(t *testing.T) {
	t.Parallel()

	secret, _ := hex.DecodeString(strings.Repeat("12", 32))
	event := protocol.Event{
		EventID: "abcdefghijklmnopqrstuvwxyz", PostID: "abcdefghijklmnopqrstuvwxyz",
		Permalink: "https://threadhub.integration.test/_redirect/pl/abcdefghijklmnopqrstuvwxyz", OccurredAt: 1234,
		Recipients: []protocol.Recipient{{UserID: "bcdefghijklmnopqrstuvwxyza", Email: "recipient@integration.invalid"}},
	}
	request, body, err := newSignedRequest("http://127.0.0.1:8080", secret, event, 1787790000, "00112233445566778899aabbccddeeff")
	if err != nil {
		t.Fatal(err)
	}
	if got := request.Header.Get("X-ThreadHub-Timestamp"); got != "1787790000" {
		t.Fatalf("timestamp header = %q", got)
	}
	if got := request.Header.Get("X-ThreadHub-Nonce"); got != "00112233445566778899aabbccddeeff" {
		t.Fatalf("nonce header = %q", got)
	}
	if err := protocol.Verify(secret, 1787790000, "00112233445566778899aabbccddeeff", body, request.Header.Get("X-ThreadHub-Signature")); err != nil {
		t.Fatalf("signature did not cover request metadata/body: %v", err)
	}
}

func TestRESTClientDoesNotFollowRedirects(t *testing.T) {
	t.Parallel()

	server := httptest.NewServer(http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		http.Redirect(response, request, "http://example.com/", http.StatusFound)
	}))
	defer server.Close()
	client := newHTTPClient(2 * time.Second)
	response, err := client.Get(server.URL)
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	_, _ = io.Copy(io.Discard, response.Body)
	if response.StatusCode != http.StatusFound {
		t.Fatalf("status = %d, want redirect response without following", response.StatusCode)
	}
}

func TestRequiredScenarioAndFailureAllowListsAreComplete(t *testing.T) {
	t.Parallel()

	wantScenarios := []string{
		"NF-FN-01", "NF-FN-02", "NF-FN-03", "NF-FN-04", "NF-FN-05", "NF-FN-06", "NF-FN-07", "NF-FN-08",
		"NF-SEC-01", "NF-SEC-02", "NF-REL-01", "NF-REL-03", "NF-REL-04", "NF-REL-05", "NF-SEC-04/05/06",
	}
	if !reflect.DeepEqual(requiredScenarioIDs, wantScenarios) {
		t.Fatalf("requiredScenarioIDs = %#v", requiredScenarioIDs)
	}
	wantAssertions := []string{
		"NF-HARNESS-config",
		"NF-HARNESS-bootstrap",
		"NF-HARNESS-compose-pull",
		"NF-HARNESS-compose-build",
		"NF-HARNESS-compose-bundle",
		"NF-HARNESS-compose-bundle-create",
		"NF-HARNESS-compose-bundle-copy",
		"NF-HARNESS-compose-bundle-shape",
		"NF-HARNESS-compose-start",
		"NF-HARNESS-compose-start-init",
		"NF-HARNESS-compose-start-services",
		"NF-HARNESS-compose-start-postgres",
		"NF-HARNESS-compose-start-smtp",
		"NF-HARNESS-compose-start-mailer",
		"NF-HARNESS-compose-start-mattermost",
		"NF-HARNESS-compose-cleanup",
		"NF-HARNESS-compose-cleanup-privacy",
		"NF-HARNESS-compose-cleanup-container",
		"NF-HARNESS-compose-cleanup-project-down",
		"NF-HARNESS-compose-cleanup-project-residue",
		"NF-HARNESS-compose-cleanup-workspace",
		"NF-HARNESS-published-mattermost",
		"NF-HARNESS-published-mailer",
		"NF-HARNESS-acceptance-run",
		"NF-HARNESS-acceptance-output",
		"NF-HARNESS-bootstrap-admin-create",
		"NF-HARNESS-bootstrap-admin-login",
		"NF-HARNESS-bootstrap-team-create",
		"NF-HARNESS-bootstrap-user-create",
		"NF-HARNESS-bootstrap-user-verify-command",
		"NF-HARNESS-bootstrap-team-membership",
		"NF-HARNESS-bootstrap-channel-create",
		"NF-HARNESS-bootstrap-channel-membership",
		"NF-HARNESS-bootstrap-bot-convert",
		"NF-HARNESS-bootstrap-inactive-user",
		"NF-HARNESS-bootstrap-direct-channel",
		"NF-HARNESS-bootstrap-group-direct-channel",
		"NF-HARNESS-plugin-stop",
		"NF-HARNESS-plugin-install",
		"NF-HARNESS-plugin-reinit",
		"NF-HARNESS-plugin-restart",
		"NF-HARNESS-plugin-enable",
		"NF-HARNESS-plugin-active-list",
		"NF-HARNESS-plugin-runtime",
		"NF-HARNESS-plugin-pair",
		"NF-HARNESS-plugin-pair-tamper",
		"NF-HARNESS-plugin-pair-negative",
		"NF-HARNESS-capture-api",
		"NF-HARNESS-compose",
		"NF-FN-01-public-root",
		"NF-FN-01-first-attempt-latency",
		"NF-FN-02-private-root",
		"NF-FN-03-public-thread-reply",
		"NF-FN-04-private-thread-reply",
		"NF-FN-05-non-member-excluded",
		"NF-FN-06-inactive-user-excluded",
		"NF-FN-07-bot-recipient-excluded",
		"NF-FN-08-direct-excluded",
		"NF-FN-08-group-direct-excluded",
		"NF-SEC-01-generic-content",
		"NF-SEC-02-single-recipient-envelope",
		"NF-REL-01-mailer-restart",
		"NF-REL-01-mailer-replay",
		"NF-REL-01-smtp-pending",
		"NF-REL-01-smtp-restart",
		"NF-REL-01-smtp-resume",
		"NF-REL-01-mailer-down-post-latency",
		"NF-REL-01-smtp-down-post-latency",
		"NF-REL-03-duplicate-event-dedupe",
		"NF-REL-04-temporary-retry",
		"NF-REL-04-mailer-recreate",
		"NF-REL-05-mattermost-recreate-post",
		"NF-REL-05-mattermost-recreate-start",
		"NF-REL-05-mattermost-recreate-endpoint",
		"NF-REL-05-mattermost-recreate-ping",
		"NF-REL-05-mattermost-recreate-plugin-active",
		"NF-REL-05-mattermost-recreate-plugin-runtime",
		"NF-REL-05-mattermost-recreate-mailer-start",
		"NF-REL-05-mattermost-recreate-delivery",
		"NF-REL-05-control-disable-write",
		"NF-REL-05-control-disable-restart",
		"NF-REL-05-control-disable-wait",
		"NF-REL-05-control-disable-post",
		"NF-REL-05-control-disable-enable",
		"NF-REL-05-control-disable-post-enabled",
		"NF-REL-05-control-disable-delivery",
		"NF-REL-05-activation-cutoff",
		"NF-SEC-04-bad-hmac",
		"NF-SEC-05-stale-timestamp",
		"NF-SEC-06-nonce-replay",
	}
	if !reflect.DeepEqual(allowedFailureAssertions, wantAssertions) {
		t.Fatalf("allowedFailureAssertions = %#v", allowedFailureAssertions)
	}
}

func TestMattermostRecreateScenarioHasPrivacySafeStageFailures(t *testing.T) {
	t.Parallel()

	source, err := os.ReadFile("main.go")
	if err != nil {
		t.Fatal(err)
	}
	for _, assertion := range []string{
		"NF-REL-05-mattermost-recreate-post",
		"NF-REL-05-mattermost-recreate-start",
		"NF-REL-05-mattermost-recreate-endpoint",
		"NF-REL-05-mattermost-recreate-ping",
		"NF-REL-05-mattermost-recreate-plugin-active",
		"NF-REL-05-mattermost-recreate-plugin-runtime",
		"NF-REL-05-mattermost-recreate-mailer-start",
		"NF-REL-05-mattermost-recreate-delivery",
	} {
		if !bytes.Contains(source, []byte(`return "`+assertion+`"`)) {
			t.Fatalf("mattermost recreate stage failure is missing %q", assertion)
		}
	}
}

func TestStartMailerRefreshesItsInternalBridgeEndpoint(t *testing.T) {
	t.Parallel()

	source, err := os.ReadFile("main.go")
	if err != nil {
		t.Fatal(err)
	}
	start := bytes.Index(source, []byte("func (a *acceptance) startMailer"))
	end := bytes.Index(source, []byte("func (a *acceptance) serviceURL"))
	if start < 0 || end <= start {
		t.Fatal("startMailer source boundary is missing")
	}
	body := source[start:end]
	for _, required := range [][]byte{
		[]byte(`a.serviceURL(ctx, "threadhub-mailer", "8080")`),
		[]byte(`a.cfg.mailerURL = mailerURL`),
		[]byte(`mailerURL.String()+"/healthz"`),
	} {
		if !bytes.Contains(body, required) {
			t.Fatalf("startMailer endpoint refresh contract is missing %q", required)
		}
	}
}

func TestControlDisableScenarioHasPrivacySafeStageFailures(t *testing.T) {
	t.Parallel()

	source, err := os.ReadFile("main.go")
	if err != nil {
		t.Fatal(err)
	}
	for _, assertion := range []string{
		"NF-REL-05-control-disable-write",
		"NF-REL-05-control-disable-restart",
		"NF-REL-05-control-disable-wait",
		"NF-REL-05-control-disable-post",
		"NF-REL-05-control-disable-enable",
		"NF-REL-05-control-disable-post-enabled",
		"NF-REL-05-control-disable-delivery",
	} {
		if !bytes.Contains(source, []byte(`return "`+assertion+`"`)) {
			t.Fatalf("control-disable stage failure is missing %q", assertion)
		}
	}
}

func TestVerifyPluginPairPropagatesPostStartDeletionOrReplacement(t *testing.T) {
	root := t.TempDir()
	composeCommand := filepath.Join(root, "compose-fixture")
	fixture := `#!/usr/bin/env bash
set -Eeuo pipefail
[[ " $* " == *" run --rm --no-deps plugin-install verify "* ]] || exit 97
[[ "${THREADHUB_TEST_PAIR_STATE:-}" == exact ]]
`
	if err := os.WriteFile(composeCommand, []byte(fixture), 0o700); err != nil {
		t.Fatal(err)
	}
	client := composeClient{
		command: []string{composeCommand}, composeFile: filepath.Join(root, "compose.yml"),
		envFile: filepath.Join(root, "integration.env"), projectName: "threadhub-test",
	}
	acceptance := acceptance{compose: client}
	for _, test := range []struct {
		state string
		ok    bool
	}{
		{state: "exact", ok: true},
		{state: "deleted", ok: false},
		{state: "replaced", ok: false},
	} {
		t.Run(test.state, func(t *testing.T) {
			t.Setenv("THREADHUB_TEST_PAIR_STATE", test.state)
			err := acceptance.verifyPluginPair(context.Background())
			if (err == nil) != test.ok {
				t.Fatalf("verifyPluginPair() error = %v, want success %t", err, test.ok)
			}
		})
	}
}

func TestPluginRuntimeReadyRequiresExactlyOneRunningTarget(t *testing.T) {
	t.Parallel()

	running := mmPluginStatus{
		PluginID: "com.threadhub.channel-email-notifier",
		State:    mattermostPluginStateRunning,
		Version:  "0.2.0",
	}
	if !pluginRuntimeReady([]mmPluginStatus{running}) {
		t.Fatal("pluginRuntimeReady() rejected the exact running plugin")
	}
	if got := pluginRuntimeClassification([]mmPluginStatus{running}); got != "running" {
		t.Fatalf("pluginRuntimeClassification() = %q, want running", got)
	}

	for name, statuses := range map[string][]mmPluginStatus{
		"missing":       nil,
		"duplicate":     {running, running},
		"starting":      {{PluginID: running.PluginID, State: 1, Version: running.Version}},
		"failed":        {{PluginID: running.PluginID, State: 3, Version: running.Version}},
		"wrong version": {{PluginID: running.PluginID, State: running.State, Version: "0.1.1"}},
		"reported error": {{
			PluginID: running.PluginID, State: running.State, Version: running.Version, Error: "startup failed",
		}},
	} {
		statuses := statuses
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			if pluginRuntimeReady(statuses) {
				t.Fatalf("pluginRuntimeReady() accepted %s state", name)
			}
			if got := pluginRuntimeClassification(statuses); got != "not-ready" {
				t.Fatalf("pluginRuntimeClassification() = %q, want not-ready", got)
			}
		})
	}
}

func TestWaitPluginRuntimeDoesNotTreatPingOrConfiguredActiveAsReady(t *testing.T) {
	t.Parallel()

	requests := 0
	server := httptest.NewServer(http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		if request.URL.Path != "/api/v4/plugins/statuses" || request.Header.Get("Authorization") != "Bearer integration-token" {
			http.Error(response, "rejected", http.StatusUnauthorized)
			return
		}
		requests++
		state := 1
		if requests >= 2 {
			state = mattermostPluginStateRunning
		}
		response.Header().Set("Content-Type", "application/json")
		_, _ = io.WriteString(response, `[{"plugin_id":"com.threadhub.channel-email-notifier","state":`+strconv.Itoa(state)+`,"version":"0.2.0","error":""}]`)
	}))
	defer server.Close()

	var diagnostic bytes.Buffer
	acceptance := acceptance{mattermost: &mattermostClient{
		baseURL: server.URL, token: "integration-token", client: newHTTPClient(time.Second),
	}, diagnostic: &diagnostic}
	if err := acceptance.waitPluginRuntime(context.Background(), time.Second); err != nil {
		t.Fatalf("waitPluginRuntime() error = %v", err)
	}
	if requests < 2 {
		t.Fatalf("plugin runtime status requests = %d, want at least 2", requests)
	}
	if got := diagnostic.String(); got != "plugin-runtime=not-ready\nplugin-runtime=running\n" {
		t.Fatalf("private diagnostic = %q", got)
	}
}

func TestIntegrationRestartTimeoutAllowsSlowRealImageRecovery(t *testing.T) {
	t.Parallel()

	if integrationRestartTimeout < 180*time.Second {
		t.Fatalf("integration restart timeout = %s, want at least 180s", integrationRestartTimeout)
	}
}

func TestReporterEmitsOnlyAllowlistedSuccessIDs(t *testing.T) {
	t.Parallel()

	var output bytes.Buffer
	report := reporter{output: &output}
	for _, id := range requiredScenarioIDs {
		if err := report.success(id); err != nil {
			t.Fatalf("success(%q) error = %v", id, err)
		}
	}
	if lines := strings.Split(strings.TrimSpace(output.String()), "\n"); len(lines) != len(requiredScenarioIDs) {
		t.Fatalf("success output lines = %d, want %d", len(lines), len(requiredScenarioIDs))
	}

	before := output.String()
	if err := report.success("recipient-one@integration.invalid"); err == nil {
		t.Fatal("success() accepted a non-scenario output line")
	}
	if output.String() != before {
		t.Fatal("success() wrote rejected data")
	}
}

func TestReporterSanitizesFailureAssertions(t *testing.T) {
	t.Parallel()

	var output bytes.Buffer
	report := reporter{output: &output}
	if err := report.failure("NF-FN-01-public-root"); err != nil {
		t.Fatalf("failure() error = %v", err)
	}
	if got := output.String(); got != "NF-FN-01-public-root\n" {
		t.Fatalf("failure output = %q", got)
	}
	for _, unsafe := range []string{
		"recipient-one@integration.invalid",
		"NF-FN-01 message body",
		"NF-FN-01_delivery_count",
	} {
		if err := report.failure(unsafe); err == nil {
			t.Fatalf("failure() accepted unsafe assertion %q", unsafe)
		}
	}
}

func TestCaptureDeltaRequiresExactRecipientCountsAndGenericContent(t *testing.T) {
	t.Parallel()

	hashA := strings.Repeat("a", 64)
	hashB := strings.Repeat("b", 64)
	before := captureSnapshot{Captures: []capture{{RecipientHash: hashA, EnvelopeCount: 2, GenericContent: true, LastAttemptAtMS: 100}}}
	after := captureSnapshot{Captures: []capture{
		{RecipientHash: hashA, EnvelopeCount: 3, GenericContent: true, LastAttemptAtMS: 200},
		{RecipientHash: hashB, EnvelopeCount: 1, GenericContent: true, LastAttemptAtMS: 201},
	}}
	if !hasExactDelta(before, after, map[string]int{hashA: 1, hashB: 1}) {
		t.Fatal("hasExactDelta() rejected exact per-recipient increments")
	}
	after.Captures[1].GenericContent = false
	if hasExactDelta(before, after, map[string]int{hashA: 1, hashB: 1}) {
		t.Fatal("hasExactDelta() accepted a non-generic capture")
	}

	if hasExactDelta(before, captureSnapshot{}, map[string]int{}) {
		t.Fatal("hasExactDelta() accepted a hash that disappeared after the baseline")
	}
}

func TestValidateCaptureSnapshotRejectsDuplicateHashesAndNegativeCounts(t *testing.T) {
	t.Parallel()

	for name, snapshot := range map[string]captureSnapshot{
		"duplicate": {Captures: []capture{{RecipientHash: strings.Repeat("a", 64)}, {RecipientHash: strings.Repeat("a", 64)}}},
		"negative":  {Captures: []capture{{RecipientHash: strings.Repeat("b", 64), EnvelopeCount: -1}}},
		"bad hash":  {Captures: []capture{{RecipientHash: "recipient@integration.invalid", EnvelopeCount: 1, LastAttemptAtMS: 1}}},
		"missing attempt timestamp": {Captures: []capture{{
			RecipientHash: strings.Repeat("d", 64), EnvelopeCount: 1, GenericContent: true,
		}}},
	} {
		snapshot := snapshot
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			if validateCaptureSnapshot(snapshot) {
				t.Fatalf("validateCaptureSnapshot() accepted %#v", snapshot)
			}
		})
	}
	if !validateCaptureSnapshot(captureSnapshot{Captures: []capture{{RecipientHash: strings.Repeat("c", 64), EnvelopeCount: 0, GenericContent: true}}}) {
		t.Fatal("validateCaptureSnapshot() rejected a valid aggregate")
	}
}

func TestFirstCaptureLatencyUsesServerCreationAndSMTPAttemptTimestamps(t *testing.T) {
	t.Parallel()

	hashA := strings.Repeat("a", 64)
	hashB := strings.Repeat("b", 64)
	createdAtMS := int64(1787790000000)
	before := captureSnapshot{Captures: []capture{}}
	after := captureSnapshot{Captures: []capture{
		{RecipientHash: hashA, EnvelopeCount: 1, GenericContent: true, LastAttemptAtMS: createdAtMS + 9999},
		{RecipientHash: hashB, EnvelopeCount: 1, GenericContent: true, LastAttemptAtMS: createdAtMS + 10001},
	}}
	latency, ok := firstCaptureLatency(createdAtMS, before, after, []string{hashA, hashB})
	if !ok || latency != 9999*time.Millisecond {
		t.Fatalf("firstCaptureLatency() = %s, %t, want 9.999s, true", latency, ok)
	}

	late := captureSnapshot{Captures: []capture{{
		RecipientHash: hashB, EnvelopeCount: 1, GenericContent: true, LastAttemptAtMS: createdAtMS + 10001,
	}}}
	if latency, ok := firstCaptureLatency(createdAtMS, before, late, []string{hashA, hashB}); !ok || latency != 10001*time.Millisecond {
		t.Fatalf("firstCaptureLatency() = %s, %t, want measurable late attempt", latency, ok)
	}
	beforeCreation := captureSnapshot{Captures: []capture{{
		RecipientHash: hashA, EnvelopeCount: 1, GenericContent: true, LastAttemptAtMS: createdAtMS - 1,
	}}}
	if _, ok := firstCaptureLatency(createdAtMS, before, beforeCreation, []string{hashA}); ok {
		t.Fatal("firstCaptureLatency() accepted an SMTP timestamp before post creation")
	}
	mixedImpossibleAndValid := captureSnapshot{Captures: []capture{
		{RecipientHash: hashA, EnvelopeCount: 1, GenericContent: true, LastAttemptAtMS: createdAtMS - 1},
		{RecipientHash: hashB, EnvelopeCount: 1, GenericContent: true, LastAttemptAtMS: createdAtMS + 100},
	}}
	if _, ok := firstCaptureLatency(createdAtMS, before, mixedImpossibleAndValid, []string{hashA, hashB}); ok {
		t.Fatal("firstCaptureLatency() accepted another recipient after an impossible new timestamp")
	}
}

func TestValidateMailerStatusRejectsMalformedAggregates(t *testing.T) {
	t.Parallel()

	valid := mailerStatus{Pending: 1, LastErrorClass: "temporary", LastSMTPCode: 450}
	if !validateMailerStatus(valid) {
		t.Fatal("validateMailerStatus() rejected valid status")
	}
	for name, status := range map[string]mailerStatus{
		"negative count":      {Pending: -1},
		"unknown error class": {LastErrorClass: "recipient@integration.invalid"},
		"short SMTP code":     {LastSMTPCode: 99},
		"oversize SMTP code":  {LastSMTPCode: 1000},
	} {
		status := status
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			if validateMailerStatus(status) {
				t.Fatalf("validateMailerStatus() accepted %#v", status)
			}
		})
	}
}

func TestWriteControlUsesSharedReadOnlyGroupMode(t *testing.T) {
	t.Parallel()

	path := filepath.Join(t.TempDir(), "state.json")
	if err := writeControl(path, controlState{Mode: "all_channels", ChannelIDs: []string{}}); err != nil {
		t.Fatal(err)
	}
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if got := info.Mode().Perm(); got != 0o640 {
		t.Fatalf("control mode = %#o, want 0640", got)
	}
}

func validConfigValues(root, envFile, controlFile string) map[string]string {
	return map[string]string{
		"INTEGRATION_ROOT":              root,
		"INTEGRATION_ENV_FILE":          envFile,
		"INTEGRATION_CONTROL_FILE":      controlFile,
		"INTEGRATION_MATTERMOST_URL":    "http://172.20.0.10:8065",
		"INTEGRATION_MAILER_URL":        "http://172.20.0.11:8080",
		"INTEGRATION_CAPTURE_URL":       "http://172.20.0.12:8081",
		"INTEGRATION_COMPOSE_COMMAND":   "docker compose",
		"INTEGRATION_CONTAINER_COMMAND": "docker",
		"INTEGRATION_COMPOSE_FILE":      filepath.Join(root, "docker-compose.yml"),
		"INTEGRATION_PROJECT_NAME":      "threadhub-integration-test",
		"INTEGRATION_HMAC_SECRET":       strings.Repeat("12", 32),
		"INTEGRATION_HASH_SECRET":       strings.Repeat("34", 32),
		"INTEGRATION_ADMIN_PASSWORD":    "integration-password-12345",
		"INTEGRATION_USER_PASSWORD":     "integration-password-67890",
		"INTEGRATION_DOMAIN":            "threadhub.integration.test",
	}
}
