package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"mime"
	"net"
	"net/http"
	"net/mail"
	"path/filepath"
	"reflect"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/nugaing119/ThreadHub/notifier/mailer/internal/config"
	"github.com/nugaing119/ThreadHub/notifier/mailer/internal/smtpclient"
	"github.com/nugaing119/ThreadHub/notifier/mailer/internal/store"
	"github.com/nugaing119/ThreadHub/notifier/mailer/internal/testutil"
	"github.com/nugaing119/ThreadHub/notifier/protocol"
)

func TestRunCommandAcceptsOnlyExactSubcommandContracts(t *testing.T) {
	for _, test := range []struct {
		name string
		args []string
		want string
	}{
		{name: "serve", args: []string{"serve"}, want: "serve"},
		{name: "healthcheck", args: []string{"healthcheck"}, want: "healthcheck"},
		{name: "status json", args: []string{"status", "--json"}, want: "status"},
		{name: "smtp recipient stdin", args: []string{"smtp-test", "--recipient-stdin"}, want: "smtp-test"},
		{name: "backup alert json stdin", args: []string{"backup-alert", "--json-stdin"}, want: "backup-alert"},
		{name: "retry failed", args: []string{"retry-failed"}, want: "retry-failed"},
		{name: "cancel failed", args: []string{"cancel-failed"}, want: "cancel-failed"},
	} {
		t.Run(test.name, func(t *testing.T) {
			var called string
			operations := commandOperations{
				serve:       func(context.Context, config.Config) error { called = "serve"; return nil },
				healthcheck: func(context.Context, config.Config) error { called = "healthcheck"; return nil },
				status: func(context.Context, config.Config) (store.Status, error) {
					called = "status"
					return store.Status{}, nil
				},
				smtpAcceptance: func(context.Context, config.Config, string) smtpclient.Result {
					called = "smtp-test"
					return smtpclient.Result{Accepted: true, Code: 250}
				},
				backupAlert: func(context.Context, config.Config, string, string) smtpclient.Result {
					called = "backup-alert"
					return smtpclient.Result{Accepted: true, Code: 250}
				},
				retryFailed:  func(context.Context, config.Config) (int64, error) { called = "retry-failed"; return 0, nil },
				cancelFailed: func(context.Context, config.Config) (int64, error) { called = "cancel-failed"; return 0, nil },
			}
			input := "recipient@example.test\n"
			if test.want == "backup-alert" {
				input = `{"recipient":"admin@example.test","failure_class":"upload"}`
			}
			stdin := strings.NewReader(input)
			if err := runCommand(context.Background(), test.args, stdin, io.Discard, testEnvironment, operations); err != nil {
				t.Fatalf("runCommand(%v) error = %v", test.args, err)
			}
			if called != test.want {
				t.Fatalf("runCommand(%v) called %q, want %q", test.args, called, test.want)
			}
		})
	}

	for _, args := range [][]string{
		nil, {"unknown"}, {"serve", "extra"}, {"healthcheck", "--json"}, {"status"},
		{"status", "--json", "extra"}, {"smtp-test"}, {"smtp-test", "recipient@example.test"},
		{"smtp-test", "--recipient-stdin", "recipient@example.test"}, {"config-fingerprint"},
		{"backup-alert"}, {"backup-alert", "--recipient-stdin"}, {"backup-alert", "--json-stdin", "extra"},
		{"config-fingerprint", "--json", "extra"}, {"retry-failed", "extra"}, {"cancel-failed", "extra"},
	} {
		if err := runCommand(context.Background(), args, strings.NewReader("recipient@example.test\n"), io.Discard, testEnvironment, commandOperations{}); err == nil {
			t.Errorf("runCommand(%v) error = nil, want exact syntax rejection", args)
		}
	}
}

func TestBackupAlertAcceptsStrictJSONStdinWithoutOutput(t *testing.T) {
	const input = `{"recipient":"admin@example.test","failure_class":"upload"}`
	var calledRecipient, calledClass string
	operations := commandOperations{backupAlert: func(_ context.Context, _ config.Config, recipient, failureClass string) smtpclient.Result {
		calledRecipient, calledClass = recipient, failureClass
		return smtpclient.Result{Accepted: true, Code: 250}
	}}
	var stdout bytes.Buffer
	if err := runCommand(context.Background(), []string{"backup-alert", "--json-stdin"}, strings.NewReader(input), &stdout, testEnvironment, operations); err != nil {
		t.Fatalf("runCommand(backup-alert) error = %v", err)
	}
	if calledRecipient != "admin@example.test" || calledClass != "upload" {
		t.Fatalf("backup alert operation received recipient=%q class=%q", calledRecipient, calledClass)
	}
	if stdout.Len() != 0 {
		t.Fatalf("backup-alert stdout = %q, want empty", stdout.String())
	}
}

func TestBackupAlertRejectsMalformedOrPrivateInputBeforeSending(t *testing.T) {
	tests := []struct {
		name  string
		input string
	}{
		{name: "unknown field", input: `{"recipient":"admin@example.test","failure_class":"upload","extra":true}`},
		{name: "private failure class", input: `{"recipient":"admin@example.test","failure_class":"customer@example.test"}`},
		{name: "invalid recipient", input: `{"recipient":"not-an-address","failure_class":"upload"}`},
		{name: "second JSON value", input: `{"recipient":"admin@example.test","failure_class":"upload"}{}`},
		{name: "empty object", input: `{}`},
		{name: "oversized", input: `{"recipient":"admin@example.test","failure_class":"` + strings.Repeat("a", 1025) + `"}`},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			called := false
			operations := commandOperations{backupAlert: func(context.Context, config.Config, string, string) smtpclient.Result {
				called = true
				return smtpclient.Result{Accepted: true, Code: 250}
			}}
			err := runCommand(context.Background(), []string{"backup-alert", "--json-stdin"}, strings.NewReader(test.input), io.Discard, testEnvironment, operations)
			if err == nil {
				t.Fatal("runCommand(backup-alert) error = nil")
			}
			if called {
				t.Fatal("backup alert operation was called for invalid input")
			}
			for _, private := range []string{"admin@example.test", "customer@example.test", strings.Repeat("a", 64)} {
				if strings.Contains(err.Error(), private) {
					t.Fatalf("backup-alert error exposed private input: %v", err)
				}
			}
		})
	}
}

func TestBackupAlertRequiresFinal250Acceptance(t *testing.T) {
	for _, result := range []smtpclient.Result{
		{Accepted: false, Class: smtpclient.ClassTemporary, Code: 451},
		{Accepted: true, Code: 0},
		{Accepted: true, Code: 251},
	} {
		operations := commandOperations{backupAlert: func(context.Context, config.Config, string, string) smtpclient.Result { return result }}
		input := `{"recipient":"admin@example.test","failure_class":"upload"}`
		if err := runCommand(context.Background(), []string{"backup-alert", "--json-stdin"}, strings.NewReader(input), io.Discard, testEnvironment, operations); err == nil {
			t.Errorf("SMTP result %+v accepted as final 250", result)
		}
	}
}

func TestBackupAlertOperationSendsOneGenericMessageOverSTARTTLS(t *testing.T) {
	server := testutil.StartSMTP(t, testutil.SMTPOptions{
		STARTTLS: true,
		Username: testEnvironment("SMTP_USERNAME"),
		Password: testEnvironment("SMTP_PASSWORD"),
	})
	cfg, err := config.Load(testEnvironment)
	if err != nil {
		t.Fatalf("config.Load() error = %v", err)
	}
	cfg.SMTPHost = "localhost"
	cfg.SMTPPort = server.Port()
	const recipient = "admin@example.test"
	result := sendBackupAlert(
		context.Background(), cfg, recipient, "snapshot",
		time.Date(2026, 9, 1, 3, 4, 5, 6, time.UTC), time.Second, server.Roots(),
	)
	if !result.Accepted || result.Code != 250 || result.Class != smtpclient.ClassNone {
		t.Fatalf("sendBackupAlert() = %+v, want final 250 acceptance", result)
	}
	if !server.Authenticated() || server.SawPlaintextAuthOrMail() {
		t.Fatal("backup alert was not authenticated exclusively after STARTTLS")
	}
	messages := server.Messages()
	if len(messages) != 1 {
		t.Fatalf("SMTP message count = %d, want 1", len(messages))
	}
	parsed, err := mail.ReadMessage(bytes.NewReader(messages[0]))
	if err != nil {
		t.Fatalf("mail.ReadMessage() error = %v", err)
	}
	subject, err := new(mime.WordDecoder).DecodeHeader(parsed.Header.Get("Subject"))
	if err != nil || subject != "[ThreadHub] 백업 실패 (snapshot)" {
		t.Fatalf("backup alert Subject = %q, error = %v", subject, err)
	}
	body, err := io.ReadAll(parsed.Body)
	if err != nil {
		t.Fatalf("ReadAll(body) error = %v", err)
	}
	for _, forbidden := range []string{recipient, cfg.Domain, cfg.SMTPUsername, cfg.SMTPPassword} {
		if bytes.Contains(body, []byte(forbidden)) {
			t.Fatalf("backup alert body exposed %q", forbidden)
		}
	}
}

func TestProductionOperationsRegistersBackupAlert(t *testing.T) {
	if productionOperations().backupAlert == nil {
		t.Fatal("production backup-alert operation is nil")
	}
}

func TestConfigFingerprintJSONContainsOnlyTargetDigest(t *testing.T) {
	var stdout bytes.Buffer
	if err := runCommand(context.Background(), []string{"config-fingerprint", "--json"}, strings.NewReader(""), &stdout, testEnvironment, commandOperations{}); err != nil {
		t.Fatalf("runCommand(config-fingerprint) error = %v", err)
	}
	const want = "{\"config_fingerprint\":\"fb86fe31f59c02f5907b182c20137f54f7af6de1c34efd0e3225e7e3ab26cc96\"}\n"
	if got := stdout.String(); got != want {
		t.Fatalf("config fingerprint output = %q, want strict JSON %q", got, want)
	}
	for _, forbidden := range []string{"fixture-user", "fixture-password", "no-reply@example.test"} {
		if strings.Contains(stdout.String(), forbidden) {
			t.Fatalf("config fingerprint output leaked %q", forbidden)
		}
	}
}

func TestStatusJSONContainsOnlyApprovedAggregates(t *testing.T) {
	fixture := store.Status{
		Pending: 2, Sending: 3, Sent: 5, FailedPermanent: 7, FailedExhausted: 11, Cancelled: 13,
		OldestPendingSeconds: 17, LastSuccessAt: 1787800000123, LastErrorClass: "temporary", LastSMTPCode: 451,
	}
	operations := commandOperations{status: func(context.Context, config.Config) (store.Status, error) { return fixture, nil }}
	var stdout bytes.Buffer
	if err := runCommand(context.Background(), []string{"status", "--json"}, strings.NewReader(""), &stdout, testEnvironment, operations); err != nil {
		t.Fatalf("runCommand(status) error = %v", err)
	}
	var got map[string]any
	if err := json.Unmarshal(stdout.Bytes(), &got); err != nil {
		t.Fatalf("status output is not JSON: %v; output=%q", err, stdout.String())
	}
	want := map[string]any{
		"pending": float64(2), "sending": float64(3), "sent": float64(5), "failed": float64(18),
		"oldest_pending_seconds": float64(17), "last_success_at": float64(1787800000123),
		"last_error_class": "temporary", "last_smtp_code": float64(451),
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("status JSON = %#v, want exact approved fields %#v", got, want)
	}
}

func TestStatusJSONNormalizesCorruptErrorMetadata(t *testing.T) {
	fixture := store.Status{LastErrorClass: "recipient@example.test", LastSMTPCode: 123456789}
	operations := commandOperations{status: func(context.Context, config.Config) (store.Status, error) { return fixture, nil }}
	var stdout bytes.Buffer
	if err := runCommand(context.Background(), []string{"status", "--json"}, strings.NewReader(""), &stdout, testEnvironment, operations); err != nil {
		t.Fatalf("runCommand(status) error = %v", err)
	}
	if strings.Contains(stdout.String(), fixture.LastErrorClass) {
		t.Fatalf("status output exposed unapproved error metadata: %q", stdout.String())
	}
	var got statusOutput
	if err := json.Unmarshal(stdout.Bytes(), &got); err != nil {
		t.Fatalf("status output is not JSON: %v", err)
	}
	if got.LastErrorClass != "protocol" || got.LastSMTPCode != 0 {
		t.Fatalf("normalized error metadata = %q/%d, want protocol/0", got.LastErrorClass, got.LastSMTPCode)
	}
}

func TestCancelFailedCLILeavesNoFailedAggregateAndPreservesActiveWork(t *testing.T) {
	queuePath := filepath.Join(t.TempDir(), "queue.db")
	environment := func(key string) string {
		if key == "NOTIFIER_QUEUE_PATH" {
			return queuePath
		}
		return testEnvironment(key)
	}
	cfg, err := config.Load(environment)
	if err != nil {
		t.Fatalf("config.Load() error = %v", err)
	}
	queue, err := store.Open(queuePath, cfg.HMACSecret)
	if err != nil {
		t.Fatalf("store.Open() error = %v", err)
	}
	makeEvent := func(id, userID, email string, now time.Time) protocol.Event {
		return protocol.Event{
			EventID: id, PostID: id, Permalink: "https://threadhub.example.test/_redirect/pl/" + id,
			OccurredAt: now.Add(-time.Minute).UnixMilli(),
			Recipients: []protocol.Recipient{{UserID: userID, Email: email}},
		}
	}
	accept := func(label string, event protocol.Event, now time.Time) {
		t.Helper()
		if _, err := queue.Accept(context.Background(), protocol.HashIdentifier(cfg.HMACSecret, "nonce", label), event, now); err != nil {
			t.Fatalf("Accept(%s) error = %v", label, err)
		}
	}
	claim := func(label string, now time.Time, lease time.Duration) store.Delivery {
		t.Helper()
		delivery, err := queue.ClaimDue(context.Background(), now, lease)
		if err != nil || delivery == nil {
			t.Fatalf("ClaimDue(%s) = %+v, %v", label, delivery, err)
		}
		return *delivery
	}
	base := time.Now().Add(-4 * time.Hour)
	accept("cli-permanent", makeEvent("11111111111111111111111111", "11111111111111111111111111", "cli-permanent@example.test", base), base)
	permanent := claim("permanent", base, 2*time.Minute)
	if err := queue.MarkPermanent(context.Background(), permanent.Key, "smtp_5xx", 550, base); err != nil {
		t.Fatalf("MarkPermanent() error = %v", err)
	}
	exhaustedAt := base.Add(time.Hour)
	accept("cli-exhausted", makeEvent("22222222222222222222222222", "22222222222222222222222222", "cli-exhausted@example.test", exhaustedAt), exhaustedAt)
	for attempt := 1; attempt <= 8; attempt++ {
		exhausted := claim("exhausted", exhaustedAt, 2*time.Minute)
		if err := queue.MarkTemporary(context.Background(), exhausted.Key, "smtp_4xx", 421, exhaustedAt); err != nil {
			t.Fatalf("MarkTemporary(attempt %d) error = %v", attempt, err)
		}
	}
	sendingAt := base.Add(2 * time.Hour)
	accept("cli-sending", makeEvent("33333333333333333333333333", "33333333333333333333333333", "cli-sending@example.test", sendingAt), sendingAt)
	_ = claim("sending", sendingAt, 24*time.Hour)
	pendingAt := base.Add(3 * time.Hour)
	accept("cli-pending", makeEvent("44444444444444444444444444", "44444444444444444444444444", "cli-pending@example.test", pendingAt), pendingAt)
	if err := queue.Close(); err != nil {
		t.Fatalf("Close(prepared queue) error = %v", err)
	}

	var cancelOutput bytes.Buffer
	if err := runCommand(context.Background(), []string{"cancel-failed"}, strings.NewReader(""), &cancelOutput, environment,
		commandOperations{cancelFailed: defaultCancelFailed}); err != nil {
		t.Fatalf("runCommand(cancel-failed) error = %v", err)
	}
	if got, want := cancelOutput.String(), "{\"cancelled\":2}\n"; got != want {
		t.Fatalf("cancel-failed output = %q, want %q", got, want)
	}
	var statusBuffer bytes.Buffer
	if err := runCommand(context.Background(), []string{"status", "--json"}, strings.NewReader(""), &statusBuffer, environment,
		commandOperations{status: defaultStatus}); err != nil {
		t.Fatalf("runCommand(status) error = %v", err)
	}
	var got statusOutput
	if err := json.Unmarshal(statusBuffer.Bytes(), &got); err != nil {
		t.Fatalf("status output is not JSON: %v", err)
	}
	if got.Failed != 0 || got.Pending != 1 || got.Sending != 1 {
		t.Fatalf("status after cancel-failed = %+v, want exact failed=0 pending=1 sending=1", got)
	}
}

func TestSMTPTestReadsOneBoundedRecipientOnlyFromStdin(t *testing.T) {
	const recipient = "one-time-recipient@example.test"
	var captured string
	operations := commandOperations{smtpAcceptance: func(_ context.Context, _ config.Config, got string) smtpclient.Result {
		captured = got
		return smtpclient.Result{Accepted: true, Code: 250}
	}}
	var stdout bytes.Buffer
	err := runCommand(context.Background(), []string{"smtp-test", "--recipient-stdin"}, strings.NewReader("  "+recipient+"  \n"), &stdout, testEnvironment, operations)
	if err != nil {
		t.Fatalf("runCommand(smtp-test) error = %v", err)
	}
	if captured != recipient {
		t.Fatalf("SMTP recipient = %q, want trimmed stdin value", captured)
	}
	if strings.Contains(stdout.String(), recipient) {
		t.Fatalf("SMTP output exposed recipient: %q", stdout.String())
	}
	const want = "{\"config_fingerprint\":\"fb86fe31f59c02f5907b182c20137f54f7af6de1c34efd0e3225e7e3ab26cc96\"}\n"
	if got := stdout.String(); got != want {
		t.Fatalf("SMTP acceptance output = %q, want strict fingerprint JSON %q", got, want)
	}

	for _, test := range []struct {
		name  string
		stdin string
	}{
		{name: "empty", stdin: ""},
		{name: "invalid", stdin: "not-an-address\n"},
		{name: "second line", stdin: recipient + "\nsecond@example.test\n"},
		{name: "over limit", stdin: strings.Repeat("a", 513) + "@example.test\n"},
	} {
		t.Run(test.name, func(t *testing.T) {
			err := runCommand(context.Background(), []string{"smtp-test", "--recipient-stdin"}, strings.NewReader(test.stdin), io.Discard, testEnvironment, operations)
			if err == nil {
				t.Fatal("smtp-test error = nil")
			}
			if strings.Contains(err.Error(), recipient) || strings.Contains(err.Error(), "second@example.test") {
				t.Fatalf("smtp-test error exposed recipient: %v", err)
			}
		})
	}
}

func TestSMTPTestRequiresFinal250Acceptance(t *testing.T) {
	for _, result := range []smtpclient.Result{
		{Accepted: false, Class: smtpclient.ClassTemporary, Code: 451},
		{Accepted: true, Code: 0},
		{Accepted: true, Code: 251},
	} {
		operations := commandOperations{smtpAcceptance: func(context.Context, config.Config, string) smtpclient.Result { return result }}
		if err := runCommand(context.Background(), []string{"smtp-test", "--recipient-stdin"}, strings.NewReader("recipient@example.test\n"), io.Discard, testEnvironment, operations); err == nil {
			t.Errorf("smtp result %+v accepted as final 250", result)
		}
	}
}

func TestSMTPTestCommandUsesBoundedTransactionAndSafeFailure(t *testing.T) {
	server := testutil.StartSMTP(t, testutil.SMTPOptions{Stall: true})
	const recipient = "private-smtp-test-recipient@example.test"
	operations := commandOperations{smtpAcceptance: func(ctx context.Context, cfg config.Config, gotRecipient string) smtpclient.Result {
		cfg.SMTPHost = "localhost"
		cfg.SMTPPort = server.Port()
		return sendSMTPAcceptance(ctx, cfg, gotRecipient, time.Now(), 80*time.Millisecond)
	}}
	var stderr bytes.Buffer
	started := time.Now()
	exitCode := runMain(context.Background(), []string{"smtp-test", "--recipient-stdin"}, strings.NewReader(recipient+"\n"), io.Discard, &stderr, testEnvironment, operations)
	if exitCode != 1 {
		t.Fatalf("smtp-test exit code = %d, want 1 for stalled peer", exitCode)
	}
	if elapsed := time.Since(started); elapsed >= 500*time.Millisecond {
		t.Fatalf("smtp-test stalled transaction elapsed = %s, want bounded return", elapsed)
	}
	if got := stderr.String(); got != "threadhub-mailer: command failed error_class=timeout smtp_code=0\n" {
		t.Fatalf("smtp-test stderr = %q, want classified safe failure", got)
	}
	for _, forbidden := range []string{recipient, testEnvironment("SMTP_USERNAME"), testEnvironment("SMTP_PASSWORD")} {
		if strings.Contains(stderr.String(), forbidden) {
			t.Fatalf("smtp-test stderr exposed private sentinel %q", forbidden)
		}
	}
}

func TestSMTPTestFailureClassificationIsBoundedAndSafe(t *testing.T) {
	tests := []struct {
		name   string
		result smtpclient.Result
		want   string
	}{
		{"temporary", smtpclient.Result{Class: smtpclient.ClassTemporary, Code: 451}, "temporary smtp_code=451"},
		{"permanent", smtpclient.Result{Class: smtpclient.ClassPermanent, Code: 550}, "permanent smtp_code=550"},
		{"invalid success", smtpclient.Result{Accepted: true, Code: 251}, "protocol smtp_code=251"},
		{"unknown values", smtpclient.Result{Class: smtpclient.ErrorClass("private-detail"), Code: 1234}, "protocol smtp_code=0"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			operations := commandOperations{smtpAcceptance: func(context.Context, config.Config, string) smtpclient.Result {
				return test.result
			}}
			var stderr bytes.Buffer
			exitCode := runMain(context.Background(), []string{"smtp-test", "--recipient-stdin"}, strings.NewReader("recipient@example.test\n"), io.Discard, &stderr, testEnvironment, operations)
			if exitCode != 1 {
				t.Fatalf("smtp-test exit code = %d, want 1", exitCode)
			}
			want := "threadhub-mailer: command failed error_class=" + test.want + "\n"
			if got := stderr.String(); got != want {
				t.Fatalf("smtp-test stderr = %q, want %q", got, want)
			}
		})
	}
}

func TestSMTPTestMessageIsGenericAndUsesAcceptanceSubject(t *testing.T) {
	cfg, err := config.Load(testEnvironment)
	if err != nil {
		t.Fatalf("config.Load() error = %v", err)
	}
	message, err := smtpTestMessage(cfg, "recipient@example.test", time.Date(2026, 8, 27, 5, 6, 7, 0, time.UTC))
	if err != nil {
		t.Fatalf("smtpTestMessage() error = %v", err)
	}
	data := string(message.Data)
	for _, required := range []string{"Subject: =?UTF-8?b?", "ThreadHub", "SMTP"} {
		if !strings.Contains(data, required) {
			t.Errorf("test message missing %q", required)
		}
	}
	for _, forbidden := range []string{"private message sentinel", "private-channel", "author-user-id", "post-id"} {
		if strings.Contains(data, forbidden) {
			t.Errorf("test message exposed %q", forbidden)
		}
	}
	var encodedSubject string
	for _, line := range strings.Split(data, "\r\n") {
		if strings.HasPrefix(line, "Subject: ") {
			encodedSubject = strings.TrimPrefix(line, "Subject: ")
			break
		}
	}
	decodedSubject, err := new(mime.WordDecoder).DecodeHeader(encodedSubject)
	if err != nil || decodedSubject != "[ThreadHub] 알림 SMTP 테스트" {
		t.Fatalf("decoded Subject = %q, %v; want exact acceptance subject", decodedSubject, err)
	}
}

func TestNewHTTPServerUsesHardenedTimeouts(t *testing.T) {
	server := newHTTPServer(":9090", http.NotFoundHandler())
	if server.Addr != ":9090" || server.ReadHeaderTimeout != 5*time.Second || server.ReadTimeout != 10*time.Second || server.WriteTimeout != 10*time.Second || server.IdleTimeout != 30*time.Second {
		t.Fatalf("server = %+v, want exact address/timeouts", server)
	}
	defaultServer := newHTTPServer("", http.NotFoundHandler())
	if defaultServer.Addr != ":8080" {
		t.Fatalf("default server Addr = %q, want :8080", defaultServer.Addr)
	}
}

func TestServeShutdownStopsAcceptsCancelsWorkerDrainsHTTPThenClosesStore(t *testing.T) {
	queue, err := store.Open(filepath.Join(t.TempDir(), "queue.db"), bytes.Repeat([]byte{0x42}, 32))
	if err != nil {
		t.Fatalf("store.Open() error = %v", err)
	}
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("net.Listen() error = %v", err)
	}
	acceptStopped := make(chan struct{})
	tracked := &trackingListener{Listener: listener, closed: acceptStopped}
	workerStarted := make(chan struct{})
	workerCancelled := make(chan struct{})
	worker := runnerFunc(func(ctx context.Context) error {
		close(workerStarted)
		<-ctx.Done()
		select {
		case <-acceptStopped:
		default:
			t.Error("worker cancelled before HTTP accepts stopped")
		}
		if _, err := queue.Status(context.Background(), time.Now()); err != nil {
			t.Errorf("database closed before worker exited: %v", err)
		}
		close(workerCancelled)
		return nil
	})
	watcher := runnerFunc(func(ctx context.Context) error { <-ctx.Done(); return nil })
	handlerStarted := make(chan struct{})
	releaseHandler := make(chan struct{})
	server := newHTTPServer(listener.Addr().String(), http.HandlerFunc(func(response http.ResponseWriter, _ *http.Request) {
		close(handlerStarted)
		<-releaseHandler
		response.WriteHeader(http.StatusNoContent)
	}))
	ctx, cancel := context.WithCancel(context.Background())
	serveDone := make(chan error, 1)
	go func() { serveDone <- serveOnListener(ctx, server, queue, watcher, worker, tracked) }()
	<-workerStarted

	requestDone := make(chan error, 1)
	go func() {
		response, err := http.Get("http://" + listener.Addr().String())
		if err == nil {
			_ = response.Body.Close()
		}
		requestDone <- err
	}()
	<-handlerStarted
	cancel()
	<-acceptStopped
	<-workerCancelled
	select {
	case err := <-serveDone:
		t.Fatalf("serve returned before active HTTP request drained: %v", err)
	default:
	}
	if _, err := queue.Status(context.Background(), time.Now()); err != nil {
		t.Fatalf("database closed before HTTP drain: %v", err)
	}

	close(releaseHandler)
	if err := <-requestDone; err != nil {
		t.Fatalf("active HTTP request failed during drain: %v", err)
	}
	if err := <-serveDone; err != nil {
		t.Fatalf("serveOnListener() error = %v", err)
	}
	if _, err := queue.Status(context.Background(), time.Now()); err == nil {
		t.Fatal("database remained open after shutdown completed")
	}
}

func TestServeDoesNotEnterHTTPServeUntilWatcherAndWorkerSignalReadyFromRun(t *testing.T) {
	queue, err := store.Open(filepath.Join(t.TempDir(), "queue.db"), bytes.Repeat([]byte{0x42}, 32))
	if err != nil {
		t.Fatalf("store.Open() error = %v", err)
	}
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("net.Listen() error = %v", err)
	}
	acceptEntered := make(chan struct{})
	observed := &acceptTrackingListener{Listener: listener, entered: acceptEntered}
	watcher := newGatedReadyRunner()
	deliveryWorker := newGatedReadyRunner()
	server := newHTTPServer(listener.Addr().String(), http.NotFoundHandler())
	ctx, cancel := context.WithCancel(context.Background())
	serveDone := make(chan error, 1)
	go func() { serveDone <- serveOnListener(ctx, server, queue, watcher, deliveryWorker, observed) }()

	<-watcher.entered
	<-deliveryWorker.entered
	select {
	case <-acceptEntered:
		t.Fatal("HTTP Serve entered before either runner signalled readiness")
	case <-time.After(50 * time.Millisecond):
	}
	close(deliveryWorker.allowReady)
	<-deliveryWorker.Ready()
	select {
	case <-acceptEntered:
		t.Fatal("HTTP Serve entered before watcher signalled readiness")
	case <-time.After(50 * time.Millisecond):
	}
	close(watcher.allowReady)
	<-watcher.Ready()
	select {
	case <-acceptEntered:
	case <-time.After(time.Second):
		t.Fatal("HTTP Serve did not start after both runners signalled readiness")
	}
	cancel()
	if err := <-serveDone; err != nil {
		t.Fatalf("serveOnListener() error = %v", err)
	}
}

func TestUnexpectedRunnerExitStopsAcceptsCancelsPeerDrainsAndClosesStore(t *testing.T) {
	for _, failedRunner := range []string{"worker", "watcher"} {
		t.Run(failedRunner, func(t *testing.T) {
			queue, err := store.Open(filepath.Join(t.TempDir(), "queue.db"), bytes.Repeat([]byte{0x42}, 32))
			if err != nil {
				t.Fatalf("store.Open() error = %v", err)
			}
			base, err := net.Listen("tcp", "127.0.0.1:0")
			if err != nil {
				t.Fatalf("net.Listen() error = %v", err)
			}
			acceptStopped := make(chan struct{})
			tracked := &trackingListener{Listener: base, closed: acceptStopped}
			acceptEntered := make(chan struct{})
			listener := &acceptTrackingListener{Listener: tracked, entered: acceptEntered}
			runnerErr := errors.New("synthetic runner detail that must not be logged")
			failing := newExitReadyRunner(runnerErr)
			peer := newExitReadyRunner(nil)
			var watcher, deliveryWorker runner
			if failedRunner == "worker" {
				watcher, deliveryWorker = peer, failing
			} else {
				watcher, deliveryWorker = failing, peer
			}
			server := newHTTPServer(base.Addr().String(), http.HandlerFunc(func(response http.ResponseWriter, _ *http.Request) {
				response.WriteHeader(http.StatusNoContent)
			}))
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			serveDone := make(chan error, 1)
			go func() { serveDone <- serveOnListener(ctx, server, queue, watcher, deliveryWorker, listener) }()
			<-failing.Ready()
			<-peer.Ready()
			<-acceptEntered

			close(failing.exit)
			var serveErr error
			select {
			case serveErr = <-serveDone:
			case <-time.After(250 * time.Millisecond):
				cancel()
				serveErr = <-serveDone
				t.Fatalf("service continued accepting after unexpected %s exit; shutdown result = %v", failedRunner, serveErr)
			}
			select {
			case <-acceptStopped:
			default:
				t.Fatal("HTTP accepts were not stopped")
			}
			select {
			case <-peer.cancelled:
			default:
				t.Fatal("peer runner was not cancelled")
			}
			if !errors.Is(serveErr, runnerErr) {
				t.Fatalf("serve error = %v, want propagated runner error", serveErr)
			}
			if _, err := queue.Status(context.Background(), time.Now()); err == nil {
				t.Fatal("database remained open after runner-exit shutdown")
			}
		})
	}
}

func TestRunCommandReturnsSafeErrors(t *testing.T) {
	const recipient = "secret-recipient@example.test"
	operations := commandOperations{smtpAcceptance: func(context.Context, config.Config, string) smtpclient.Result {
		return smtpclient.Result{Class: smtpclient.ClassPermanent, Code: 550}
	}}
	err := runCommand(context.Background(), []string{"smtp-test", "--recipient-stdin"}, strings.NewReader(recipient+"\n"), io.Discard, testEnvironment, operations)
	if err == nil {
		t.Fatal("smtp-test error = nil")
	}
	if strings.Contains(err.Error(), recipient) || strings.Contains(err.Error(), testEnvironment("SMTP_PASSWORD")) || strings.Contains(err.Error(), testEnvironment("SMTP_USERNAME")) {
		t.Fatalf("error exposed sensitive input: %v", err)
	}
}

func TestRunCommandPropagatesAggregateOperationFailure(t *testing.T) {
	sentinel := errors.New("fixture unavailable")
	operations := commandOperations{status: func(context.Context, config.Config) (store.Status, error) { return store.Status{}, sentinel }}
	err := runCommand(context.Background(), []string{"status", "--json"}, strings.NewReader(""), io.Discard, testEnvironment, operations)
	if !errors.Is(err, sentinel) {
		t.Fatalf("runCommand() error = %v, want operation failure", err)
	}
}

func TestTopLevelOutputKeepsPropagatedRunnerErrorDetailsPrivate(t *testing.T) {
	const privateDetail = "synthetic runner private detail"
	operations := commandOperations{serve: func(context.Context, config.Config) error { return errors.New(privateDetail) }}
	var stderr bytes.Buffer
	exitCode := runMain(context.Background(), []string{"serve"}, strings.NewReader(""), io.Discard, &stderr, testEnvironment, operations)
	if exitCode != 1 {
		t.Fatalf("exit code = %d, want 1", exitCode)
	}
	if got, want := stderr.String(), "threadhub-mailer: command failed\n"; got != want {
		t.Fatalf("stderr = %q, want fixed %q", got, want)
	}
	if strings.Contains(stderr.String(), privateDetail) {
		t.Fatalf("stderr exposed runner error: %q", stderr.String())
	}
}

func testEnvironment(key string) string {
	values := map[string]string{
		"NOTIFIER_LISTEN_ADDRESS":  ":8080",
		"THREADHUB_DOMAIN":         "threadhub.example.test",
		"NOTIFIER_HMAC_SECRET":     strings.Repeat("42", 32),
		"NOTIFIER_QUEUE_PATH":      "/tmp/threadhub-task5-test-queue.db",
		"NOTIFIER_CONTROL_FILE":    "/tmp/threadhub-task5-test-state.json",
		"SMTP_SERVER":              "smtp.email.ap-singapore-1.oci.oraclecloud.com",
		"SMTP_PORT":                "587",
		"SMTP_USERNAME":            "fixture-user",
		"SMTP_PASSWORD":            "fixture-password",
		"SMTP_FROM_ADDRESS":        "no-reply@example.test",
		"SMTP_REPLY_TO_ADDRESS":    "feedback@example.test",
		"SMTP_FEEDBACK_NAME":       "ThreadHub 고객지원",
		"NOTIFIER_RATE_PER_MINUTE": "10",
	}
	return values[key]
}

type runnerFunc func(context.Context) error

func (run runnerFunc) Run(ctx context.Context) error { return run(ctx) }
func (run runnerFunc) Ready() <-chan struct{} {
	ready := make(chan struct{})
	close(ready)
	return ready
}

type gatedReadyRunner struct {
	ready      chan struct{}
	entered    chan struct{}
	allowReady chan struct{}
}

type exitReadyRunner struct {
	ready     chan struct{}
	exit      chan struct{}
	cancelled chan struct{}
	err       error
}

func newExitReadyRunner(err error) *exitReadyRunner {
	return &exitReadyRunner{ready: make(chan struct{}), exit: make(chan struct{}), cancelled: make(chan struct{}), err: err}
}

func (runner *exitReadyRunner) Ready() <-chan struct{} { return runner.ready }

func (runner *exitReadyRunner) Run(ctx context.Context) error {
	close(runner.ready)
	select {
	case <-runner.exit:
		return runner.err
	case <-ctx.Done():
		close(runner.cancelled)
		return nil
	}
}

func newGatedReadyRunner() *gatedReadyRunner {
	return &gatedReadyRunner{ready: make(chan struct{}), entered: make(chan struct{}), allowReady: make(chan struct{})}
}

func (runner *gatedReadyRunner) Ready() <-chan struct{} { return runner.ready }

func (runner *gatedReadyRunner) Run(ctx context.Context) error {
	close(runner.entered)
	<-runner.allowReady
	close(runner.ready)
	<-ctx.Done()
	return nil
}

type acceptTrackingListener struct {
	net.Listener
	entered chan struct{}
	once    sync.Once
}

func (listener *acceptTrackingListener) Accept() (net.Conn, error) {
	listener.once.Do(func() { close(listener.entered) })
	return listener.Listener.Accept()
}

type trackingListener struct {
	net.Listener
	closed chan struct{}
	once   sync.Once
}

func (listener *trackingListener) Close() error {
	err := listener.Listener.Close()
	listener.once.Do(func() { close(listener.closed) })
	return err
}
