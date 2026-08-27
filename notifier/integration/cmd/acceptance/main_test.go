package main

import (
	"bytes"
	"encoding/hex"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/nugaing119/ThreadHub/notifier/protocol"
)

func TestLoadConfigRequiresLoopbackEndpointsAndPrivateFiles(t *testing.T) {
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
	if cfg.mattermostURL.Hostname() != "127.0.0.1" || cfg.mailerURL.Hostname() != "127.0.0.1" || cfg.captureURL.Hostname() != "127.0.0.1" {
		t.Fatal("loadConfig() did not preserve loopback endpoints")
	}

	values["INTEGRATION_MAILER_URL"] = "http://192.0.2.10:8080"
	if _, err := loadConfig(func(key string) string { return values[key] }); err == nil {
		t.Fatal("loadConfig() accepted a non-loopback Mailer endpoint")
	}
}

func TestNewSignedRequestCoversTimestampNonceAndBody(t *testing.T) {
	t.Parallel()

	secret, _ := hex.DecodeString(strings.Repeat("12", 32))
	event := protocol.Event{
		EventID: "abcdefghijklmnopqrstuvwxyz", PostID: "abcdefghijklmnopqrstuvwxyz",
		Permalink: "https://threadhub.integration.test/pl/abcdefghijklmnopqrstuvwxyz", OccurredAt: 1234,
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

func TestPluginListRequiresOneExactActivePluginFromOneNode(t *testing.T) {
	t.Parallel()

	const pluginID = "com.threadhub.channel-email-notifier"
	const version = "0.1.0"
	valid := `[{"active":[{"id":"other","version":"2.0.0"},{"id":"com.threadhub.channel-email-notifier","version":"0.1.0"}],"inactive":[]}]`
	if err := verifyExactActivePluginList([]byte(valid), pluginID, version); err != nil {
		t.Fatalf("verifyExactActivePluginList() error = %v", err)
	}

	for name, raw := range map[string]string{
		"multiple nodes": `[{"active":[{"id":"com.threadhub.channel-email-notifier","version":"0.1.0"}],"inactive":[]},{"active":[],"inactive":[]}]`,
		"wrong version":  `[{"active":[{"id":"com.threadhub.channel-email-notifier","version":"0.2.0"}],"inactive":[]}]`,
		"inactive":       `[{"active":[],"inactive":[{"id":"com.threadhub.channel-email-notifier","version":"0.1.0"}]}]`,
		"duplicate":      `[{"active":[{"id":"com.threadhub.channel-email-notifier","version":"0.1.0"},{"id":"com.threadhub.channel-email-notifier","version":"0.1.0"}],"inactive":[]}]`,
		"trailing":       `[{"active":[],"inactive":[]}] {}`,
	} {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			if err := verifyExactActivePluginList([]byte(raw), pluginID, version); err == nil {
				t.Fatal("verifyExactActivePluginList() accepted invalid plugin state")
			}
		})
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
		"NF-REL-05-mattermost-recreate",
		"NF-REL-05-control-disable",
		"NF-REL-05-activation-cutoff",
		"NF-SEC-04-bad-hmac",
		"NF-SEC-05-stale-timestamp",
		"NF-SEC-06-nonce-replay",
	}
	if !reflect.DeepEqual(allowedFailureAssertions, wantAssertions) {
		t.Fatalf("allowedFailureAssertions = %#v", allowedFailureAssertions)
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
	before := captureSnapshot{Captures: []capture{{RecipientHash: hashA, EnvelopeCount: 2, GenericContent: true}}}
	after := captureSnapshot{Captures: []capture{
		{RecipientHash: hashA, EnvelopeCount: 3, GenericContent: true},
		{RecipientHash: hashB, EnvelopeCount: 1, GenericContent: true},
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
		"bad hash":  {Captures: []capture{{RecipientHash: "recipient@integration.invalid", EnvelopeCount: 1}}},
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
		"INTEGRATION_ROOT":            root,
		"INTEGRATION_ENV_FILE":        envFile,
		"INTEGRATION_CONTROL_FILE":    controlFile,
		"INTEGRATION_MATTERMOST_URL":  "http://127.0.0.1:18065",
		"INTEGRATION_MAILER_URL":      "http://127.0.0.1:18080",
		"INTEGRATION_CAPTURE_URL":     "http://127.0.0.1:18081",
		"INTEGRATION_COMPOSE_COMMAND": "docker compose",
		"INTEGRATION_COMPOSE_FILE":    filepath.Join(root, "docker-compose.yml"),
		"INTEGRATION_PROJECT_NAME":    "threadhub-integration-test",
		"INTEGRATION_HMAC_SECRET":     strings.Repeat("12", 32),
		"INTEGRATION_HASH_SECRET":     strings.Repeat("34", 32),
		"INTEGRATION_ADMIN_PASSWORD":  "integration-password-12345",
		"INTEGRATION_USER_PASSWORD":   "integration-password-67890",
		"INTEGRATION_DOMAIN":          "threadhub.integration.test",
	}
}
