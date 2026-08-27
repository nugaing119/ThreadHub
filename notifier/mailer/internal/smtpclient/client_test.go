package smtpclient_test

import (
	"context"
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
	if result.Accepted {
		t.Fatalf("Send() = %+v, accepted an untrusted certificate", result)
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
	if result.Accepted || result.Class != smtpclient.ClassTemporary || result.Code != 0 {
		t.Fatalf("Send() = %+v, want temporary timeout", result)
	}
	if strings.Contains(result.Class.String(), "localhost") {
		t.Fatal("Send() result leaked address")
	}
}

func newClient(server *testutil.SMTPServer) *smtpclient.Client {
	return smtpclient.New(smtpclient.Config{Host: "localhost", Port: server.Port(), Username: "fixture-user", Password: "fixture-password", DialTimeout: time.Second}, server.Roots())
}

func testMessage(t *testing.T) message.Message {
	t.Helper()
	msg, err := message.Render(message.Input{FromName: "ThreadHub", FromAddress: "no-reply@example.test", ReplyTo: "feedback@example.test", ToAddress: "recipient@example.test", Domain: "threadhub.example.test", EventHash: "event", RecipientHash: "recipient", Permalink: "https://threadhub.example.test/pl/abcdefghijklmnopqrstuvwxyz", Date: time.Now().UTC()})
	if err != nil {
		t.Fatal(err)
	}
	return msg
}
