package message

import (
	"bytes"
	"io"
	"mime"
	"mime/multipart"
	"net/mail"
	"strings"
	"testing"
	"time"
)

func TestRenderCreatesPrivateGenericMultipartNotice(t *testing.T) {
	t.Parallel()
	msg, err := Render(testInput())
	if err != nil {
		t.Fatalf("Render() error = %v", err)
	}
	data := string(msg.Data)
	for _, required := range []string{
		"ThreadHub에 새 메시지가 등록되었습니다.",
		"로그인하여 확인해 주세요.",
		"https://threadhub.example.test/_redirect/pl/abcdefghijklmnopqrstuvwxyz",
		"Content-Type: multipart/alternative;",
	} {
		if !strings.Contains(data, required) {
			t.Fatalf("rendered message missing %q", required)
		}
	}
	for _, name := range []string{"Subject", "From"} {
		value := header(msg.Data, name)
		if !strings.Contains(strings.ToUpper(value), "=?UTF-8?") {
			t.Fatalf("%s is not RFC 2047 encoded: %q", name, value)
		}
		decoded, err := new(mime.WordDecoder).DecodeHeader(value)
		if err != nil {
			t.Fatalf("DecodeHeader(%s) error = %v", name, err)
		}
		if name == "Subject" && decoded != "[ThreadHub] 새 메시지가 등록되었습니다" {
			t.Fatalf("Subject = %q", decoded)
		}
	}
	for _, forbidden := range []string{"SENTINEL post content", "private-channel", "SENTINEL Team", "SENTINEL author"} {
		if strings.Contains(data, forbidden) {
			t.Fatalf("rendered message leaked %q", forbidden)
		}
	}
	if strings.Count(data, "\r\nTo:") != 1 || msg.EnvelopeTo != "recipient@example.test" || msg.EnvelopeFrom != "no-reply@example.test" {
		t.Fatalf("Render() envelope/header recipients are not exactly one: %q", data)
	}
	if bytes.Contains(bytes.ReplaceAll(msg.Data, []byte("\r\n"), nil), []byte("\n")) {
		t.Fatal("Render() emitted a non-CRLF line ending")
	}
}

func TestRenderProducesParseableMultipartBody(t *testing.T) {
	t.Parallel()
	rendered, err := Render(testInput())
	if err != nil {
		t.Fatalf("Render() error = %v", err)
	}
	parsed, err := mail.ReadMessage(bytes.NewReader(rendered.Data))
	if err != nil {
		t.Fatalf("mail.ReadMessage() error = %v", err)
	}
	mediaType, params, err := mime.ParseMediaType(parsed.Header.Get("Content-Type"))
	if err != nil || mediaType != "multipart/alternative" || params["boundary"] == "" {
		t.Fatalf("Content-Type = %q (%v), want multipart/alternative boundary", parsed.Header.Get("Content-Type"), err)
	}
	reader := multipart.NewReader(parsed.Body, params["boundary"])
	plain, err := reader.NextPart()
	if err != nil {
		t.Fatalf("plain NextPart() error = %v", err)
	}
	plainBody, err := io.ReadAll(plain)
	if err != nil || !strings.Contains(string(plainBody), "ThreadHub에 새 메시지가 등록되었습니다.") {
		t.Fatalf("plain body = %q, error = %v", plainBody, err)
	}
	html, err := reader.NextPart()
	if err != nil {
		t.Fatalf("HTML NextPart() error = %v", err)
	}
	htmlBody, err := io.ReadAll(html)
	if err != nil || !strings.Contains(string(htmlBody), "메시지 확인") {
		t.Fatalf("HTML body = %q, error = %v", htmlBody, err)
	}
	if _, err := reader.NextPart(); err != io.EOF {
		t.Fatalf("NextPart() error = %v, want EOF", err)
	}
}

func TestRenderIncludesProjectTeamChannelAndReplyTypeWithoutMessageContent(t *testing.T) {
	t.Parallel()
	in := testInput()
	in.ContentMode = ModeProjectContext
	in.TeamName = "All <운영>"
	in.ChannelName = "Mentor & Mentee"
	in.EventType = "thread_reply"
	rendered, err := Render(in)
	if err != nil {
		t.Fatalf("Render() error = %v", err)
	}
	decodedSubject, err := new(mime.WordDecoder).DecodeHeader(header(rendered.Data, "Subject"))
	if err != nil {
		t.Fatalf("DecodeHeader() error = %v", err)
	}
	if want := "[ThreadHub][threadhub.example.test] All <운영> / Mentor & Mentee · 스레드 답글"; decodedSubject != want {
		t.Fatalf("Subject = %q, want %q", decodedSubject, want)
	}
	data := string(rendered.Data)
	for _, required := range []string{"프로젝트: threadhub.example.test", "팀: All <운영>", "채널: Mentor & Mentee", "스레드 답글"} {
		if !strings.Contains(data, required) {
			t.Fatalf("rendered message missing %q", required)
		}
	}
	if strings.Contains(data, "<dd>All <운영></dd>") || !strings.Contains(data, "<dd>All &lt;운영&gt;</dd>") {
		t.Fatal("HTML context was not escaped")
	}
	for _, forbidden := range []string{"SENTINEL post content", "SENTINEL author", "attachment.pdf"} {
		if strings.Contains(data, forbidden) {
			t.Fatalf("rendered message leaked %q", forbidden)
		}
	}
}

func TestRenderFallsBackToGenericForLegacyQueuedEvent(t *testing.T) {
	t.Parallel()
	in := testInput()
	in.ContentMode = ModeProjectContext
	rendered, err := Render(in)
	if err != nil {
		t.Fatalf("Render() error = %v", err)
	}
	decodedSubject, err := new(mime.WordDecoder).DecodeHeader(header(rendered.Data, "Subject"))
	if err != nil || decodedSubject != genericSubject {
		t.Fatalf("legacy Subject = %q, %v; want generic", decodedSubject, err)
	}
}

func TestRenderUsesDeterministicOpaqueMessageID(t *testing.T) {
	t.Parallel()
	in := testInput()
	first, err := Render(in)
	if err != nil {
		t.Fatal(err)
	}
	second, err := Render(in)
	if err != nil {
		t.Fatal(err)
	}
	firstID := header(first.Data, "Message-ID")
	if firstID == "" || firstID != header(second.Data, "Message-ID") {
		t.Fatalf("Message-ID is not deterministic: %q", firstID)
	}
	for _, forbidden := range []string{"original-post-id", "original-user-id"} {
		if strings.Contains(firstID, forbidden) {
			t.Fatalf("Message-ID leaked %q", forbidden)
		}
	}
}

func TestRenderRejectsHeaderInjection(t *testing.T) {
	t.Parallel()
	in := testInput()
	in.FromName = "ThreadHub\r\nBcc: attacker@example.test"
	if _, err := Render(in); err == nil {
		t.Fatal("Render() accepted header injection")
	}
}

func header(data []byte, name string) string {
	for _, line := range strings.Split(string(data), "\r\n") {
		if strings.HasPrefix(line, name+": ") {
			return strings.TrimPrefix(line, name+": ")
		}
	}
	return ""
}

func testInput() Input {
	return Input{FromName: "ThreadHub 고객지원", FromAddress: "no-reply@example.test", ReplyTo: "feedback@example.test", ToAddress: "recipient@example.test", Domain: "threadhub.example.test", EventHash: "event-hash-original-post-id", RecipientHash: "recipient-hash-original-user-id", Permalink: "https://threadhub.example.test/_redirect/pl/abcdefghijklmnopqrstuvwxyz", Date: time.Date(2026, 8, 27, 1, 2, 3, 0, time.UTC)}
}
