package adminnotice

import (
	"bytes"
	"io"
	"mime"
	"net/mail"
	"strings"
	"testing"
	"time"
)

func TestRenderCreatesOnlyGenericBackupFailureContent(t *testing.T) {
	t.Parallel()
	in := validNoticeInput()
	rendered, err := Render(in)
	if err != nil {
		t.Fatalf("Render() error = %v", err)
	}
	if rendered.EnvelopeFrom != in.FromAddress || rendered.EnvelopeTo != in.ToAddress {
		t.Fatalf("envelope = %q -> %q, want %q -> %q", rendered.EnvelopeFrom, rendered.EnvelopeTo, in.FromAddress, in.ToAddress)
	}
	parsed, err := mail.ReadMessage(bytes.NewReader(rendered.Data))
	if err != nil {
		t.Fatalf("mail.ReadMessage() error = %v", err)
	}
	subject, err := new(mime.WordDecoder).DecodeHeader(parsed.Header.Get("Subject"))
	if err != nil {
		t.Fatalf("DecodeHeader(Subject) error = %v", err)
	}
	if subject != "[ThreadHub] 백업 실패 (upload)" {
		t.Fatalf("Subject = %q, want exact generic subject", subject)
	}
	if got, want := parsed.Header.Get("Message-ID"), "<"+in.OpaqueID+"@"+in.Domain+">"; got != want {
		t.Fatalf("Message-ID = %q, want %q", got, want)
	}
	body, err := io.ReadAll(parsed.Body)
	if err != nil {
		t.Fatalf("ReadAll(body) error = %v", err)
	}
	for _, required := range []string{
		"ThreadHub 자동 백업이 실패했습니다.",
		"서버에서 backup-status를 확인해 주세요.",
	} {
		if !bytes.Contains(body, []byte(required)) {
			t.Fatalf("body missing %q: %q", required, body)
		}
	}
	for _, forbidden := range []string{
		in.Domain,
		in.ToAddress,
		"/srv/threadhub",
		"customer",
		"channel",
		"object-key",
	} {
		if bytes.Contains(body, []byte(forbidden)) {
			t.Fatalf("body leaked %q: %q", forbidden, body)
		}
	}
	if bytes.Contains(bytes.ReplaceAll(rendered.Data, []byte("\r\n"), nil), []byte("\n")) {
		t.Fatal("Render() emitted a non-CRLF line ending")
	}
}

func TestValidFailureClassUsesClosedAllowlist(t *testing.T) {
	t.Parallel()
	for _, value := range []string{"preflight", "snapshot", "service_recovery", "manifest", "upload", "remote_verify"} {
		if !ValidFailureClass(value) {
			t.Fatalf("ValidFailureClass(%q) = false", value)
		}
	}
	for _, value := range []string{"", "verify", "customer@example.test", "upload\r\nBcc: attacker@example.test"} {
		if ValidFailureClass(value) {
			t.Fatalf("ValidFailureClass(%q) = true", value)
		}
	}
}

func TestRenderRejectsUnsafeInput(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name   string
		mutate func(*Input)
	}{
		{name: "empty from name", mutate: func(in *Input) { in.FromName = "" }},
		{name: "from name header injection", mutate: func(in *Input) { in.FromName = "ThreadHub\r\nBcc: attacker@example.test" }},
		{name: "display-name address", mutate: func(in *Input) { in.ToAddress = "Admin <admin@example.test>" }},
		{name: "invalid reply-to", mutate: func(in *Input) { in.ReplyTo = "not-an-address" }},
		{name: "empty domain", mutate: func(in *Input) { in.Domain = "" }},
		{name: "domain header injection", mutate: func(in *Input) { in.Domain = "example.test\r\nBcc: attacker@example.test" }},
		{name: "unknown failure class", mutate: func(in *Input) { in.FailureClass = "database.dump" }},
		{name: "short opaque ID", mutate: func(in *Input) { in.OpaqueID = strings.Repeat("a", 63) }},
		{name: "non-hex opaque ID", mutate: func(in *Input) { in.OpaqueID = strings.Repeat("z", 64) }},
		{name: "zero date", mutate: func(in *Input) { in.Date = time.Time{} }},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			in := validNoticeInput()
			test.mutate(&in)
			if _, err := Render(in); err == nil {
				t.Fatal("Render() error = nil")
			}
		})
	}
}

func validNoticeInput() Input {
	return Input{
		FromName: "ThreadHub 고객지원", FromAddress: "no-reply@example.test",
		ReplyTo: "feedback@example.test", ToAddress: "admin@example.test",
		Domain: "threadhub.example.test", FailureClass: "upload",
		OpaqueID: strings.Repeat("a", 64), Date: time.Date(2026, 9, 1, 3, 4, 5, 0, time.UTC),
	}
}
