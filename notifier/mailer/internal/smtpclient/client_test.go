package smtpclient_test

import (
	"context"
	"fmt"
	"net"
	"strings"
	"testing"
	"time"

	"github.com/nugaing119/ThreadHub/notifier/mailer/internal/message"
	"github.com/nugaing119/ThreadHub/notifier/mailer/internal/smtpclient"
	"github.com/nugaing119/ThreadHub/notifier/mailer/internal/testutil"
)

func TestSendUsesTrustedSTARTTLSAndAUTH(t *testing.T) {
	server := testutil.StartSMTP(t, testutil.SMTPOptions{STARTTLS: true, Username: "fixture-user", Password: "fixture-password"})
	result := newClient(server).Send(context.Background(), testMessage(t))
	if !result.Accepted || result.Class != smtpclient.ClassNone || result.Code != 250 {
		t.Fatalf("Send() = %+v, want accepted 250", result)
	}
	if !server.Authenticated() || len(server.Messages()) != 1 {
		t.Fatal("Send() did not authenticate and deliver one message")
	}
}

func TestSendRejectsServerWithoutSTARTTLS(t *testing.T) {
	server := testutil.StartSMTP(t, testutil.SMTPOptions{})
	result := newClient(server).Send(context.Background(), testMessage(t))
	if result.Accepted || result.Class != smtpclient.ClassPermanent {
		t.Fatalf("Send() = %+v, want permanent STARTTLS failure", result)
	}
	if server.SawPlaintextAuthOrMail() {
		t.Fatal("Send() fell back to plaintext SMTP")
	}
}

func TestSendRejectsUntrustedOrWrongHostnameCertificate(t *testing.T) {
	server := testutil.StartSMTP(t, testutil.SMTPOptions{STARTTLS: true, Username: "fixture-user", Password: "fixture-password"})
	client := smtpclient.New(smtpclient.Config{Host: "localhost", Port: server.Port(), Username: "fixture-user", Password: "fixture-password", DialTimeout: time.Second}, nil)
	result := client.Send(context.Background(), testMessage(t))
	if result.Accepted || result.Class != smtpclient.ClassPermanent {
		t.Fatalf("Send() = %+v, want permanent untrusted certificate failure", result)
	}
}

func TestSendClassifiesNonTimeoutNetworkFailureAsTemporary(t *testing.T) {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	port := listener.Addr().(*net.TCPAddr).Port
	if err := listener.Close(); err != nil {
		t.Fatal(err)
	}

	client := smtpclient.New(smtpclient.Config{Host: "127.0.0.1", Port: port, DialTimeout: time.Second}, nil)
	result := client.Send(context.Background(), testMessage(t))
	if result.Accepted || result.Class != smtpclient.ClassTemporary || result.Code != 0 {
		t.Fatalf("Send(connection refused) = %+v, want temporary network failure", result)
	}
}

func TestSendClassifiesSMTPFailures(t *testing.T) {
	for _, tc := range []struct {
		name  string
		opts  testutil.SMTPOptions
		class smtpclient.ErrorClass
		code  int
	}{
		{"auth", testutil.SMTPOptions{STARTTLS: true, Username: "fixture-user", Password: "wrong", AuthCode: 535}, smtpclient.ClassPermanent, 535},
		{"temporary recipient", testutil.SMTPOptions{STARTTLS: true, Username: "fixture-user", Password: "fixture-password", RCPTCode: 450}, smtpclient.ClassTemporary, 450},
		{"permanent recipient", testutil.SMTPOptions{STARTTLS: true, Username: "fixture-user", Password: "fixture-password", RCPTCode: 550}, smtpclient.ClassPermanent, 550},
	} {
		t.Run(tc.name, func(t *testing.T) {
			server := testutil.StartSMTP(t, tc.opts)
			result := newClient(server).Send(context.Background(), testMessage(t))
			if result.Accepted || result.Class != tc.class || result.Code != tc.code {
				t.Fatalf("Send() = %+v, want class=%q code=%d", result, tc.class, tc.code)
			}
		})
	}
}

func TestSendHonorsContextCancellationWithoutLeakingAddress(t *testing.T) {
	server := testutil.StartSMTP(t, testutil.SMTPOptions{Stall: true})
	ctx, cancel := context.WithTimeout(context.Background(), 80*time.Millisecond)
	defer cancel()
	result := newClient(server).Send(ctx, testMessage(t))
	if result.Accepted || result.Class != smtpclient.ClassTimeout || result.Code != 0 {
		t.Fatalf("Send() = %+v, want classified timeout", result)
	}
	if strings.Contains(result.Class.String(), "localhost") {
		t.Fatal("Send() result leaked address")
	}
}

func TestSendBoundsTransactionBeforeServerGreeting(t *testing.T) {
	host, port := startSilentSMTPPeer(t)
	const (
		username = "private-username-sentinel"
		password = "private-password-sentinel"
	)
	client := smtpclient.New(smtpclient.Config{
		Host: host, Port: port, Username: username, Password: password,
		DialTimeout: time.Second, TransactionTimeout: 80 * time.Millisecond,
	}, nil)
	message := testMessage(t)
	message.EnvelopeTo = "private-recipient-sentinel@example.test"
	message.Data = []byte("private-body-sentinel")

	started := time.Now()
	result := client.Send(context.Background(), message)
	elapsed := time.Since(started)
	if result.Accepted || result.Class != smtpclient.ClassTimeout || result.Code != 0 {
		t.Fatalf("Send(silent greeting) = %+v, want timeout", result)
	}
	if elapsed >= 500*time.Millisecond {
		t.Fatalf("Send(silent greeting) elapsed = %s, want bounded transaction", elapsed)
	}
	serialized := fmt.Sprint(result)
	for _, forbidden := range []string{host, username, password, message.EnvelopeTo, string(message.Data)} {
		if strings.Contains(serialized, forbidden) {
			t.Fatalf("timeout result exposed private sentinel %q: %s", forbidden, serialized)
		}
	}
}

func TestSendCancellationRemainsPromptWithLongTransactionBound(t *testing.T) {
	host, port := startSilentSMTPPeer(t)
	client := smtpclient.New(smtpclient.Config{
		Host: host, Port: port, DialTimeout: time.Second, TransactionTimeout: time.Second,
	}, nil)
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan smtpclient.Result, 1)
	go func() { done <- client.Send(ctx, testMessage(t)) }()
	time.Sleep(20 * time.Millisecond)
	started := time.Now()
	cancel()
	select {
	case result := <-done:
		if result.Accepted || result.Class != smtpclient.ClassTemporary {
			t.Fatalf("Send(cancelled) = %+v, want retryable cancellation", result)
		}
		if elapsed := time.Since(started); elapsed >= 300*time.Millisecond {
			t.Fatalf("Send cancellation elapsed = %s, want prompt return", elapsed)
		}
	case <-time.After(500 * time.Millisecond):
		t.Fatal("Send did not return promptly after cancellation")
	}
}

func newClient(server *testutil.SMTPServer) *smtpclient.Client {
	return smtpclient.New(smtpclient.Config{Host: "localhost", Port: server.Port(), Username: "fixture-user", Password: "fixture-password", DialTimeout: time.Second}, server.Roots())
}

func testMessage(t *testing.T) message.Message {
	t.Helper()
	msg, err := message.Render(message.Input{FromName: "ThreadHub", FromAddress: "no-reply@example.test", ReplyTo: "feedback@example.test", ToAddress: "recipient@example.test", Domain: "threadhub.example.test", EventHash: "event", RecipientHash: "recipient", Permalink: "https://threadhub.example.test/_redirect/pl/abcdefghijklmnopqrstuvwxyz", Date: time.Now().UTC()})
	if err != nil {
		t.Fatal(err)
	}
	return msg
}

func startSilentSMTPPeer(t *testing.T) (string, int) {
	t.Helper()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	release := make(chan struct{})
	accepted := make(chan struct{})
	go func() {
		connection, acceptErr := listener.Accept()
		if acceptErr != nil {
			return
		}
		close(accepted)
		<-release
		_ = connection.Close()
	}()
	t.Cleanup(func() {
		close(release)
		_ = listener.Close()
	})
	address := listener.Addr().(*net.TCPAddr)
	return "127.0.0.1", address.Port
}
