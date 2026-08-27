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
	"path/filepath"
	"reflect"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/nugaing119/ThreadHub/notifier/mailer/internal/config"
	"github.com/nugaing119/ThreadHub/notifier/mailer/internal/smtpclient"
	"github.com/nugaing119/ThreadHub/notifier/mailer/internal/store"
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
				retryFailed:  func(context.Context, config.Config) (int64, error) { called = "retry-failed"; return 0, nil },
				cancelFailed: func(context.Context, config.Config) (int64, error) { called = "cancel-failed"; return 0, nil },
			}
			stdin := strings.NewReader("recipient@example.test\n")
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
		{"smtp-test", "--recipient-stdin", "recipient@example.test"}, {"retry-failed", "extra"}, {"cancel-failed", "extra"},
	} {
		if err := runCommand(context.Background(), args, strings.NewReader("recipient@example.test\n"), io.Discard, testEnvironment, commandOperations{}); err == nil {
			t.Errorf("runCommand(%v) error = nil, want exact syntax rejection", args)
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

type trackingListener struct {
	net.Listener
	closed chan struct{}
	once   sync.Once
}

func (listener *trackingListener) Close() error {
	listener.once.Do(func() { close(listener.closed) })
	return listener.Listener.Close()
}
