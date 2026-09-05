// Package message renders privacy-bounded notification email formats.
package message

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"mime"
	"mime/multipart"
	"net/mail"
	"net/url"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"

	"github.com/nugaing119/ThreadHub/notifier/protocol"
)

var errInvalidInput = errors.New("invalid email message input")

const (
	ModeGeneric        = protocol.ContentModeGeneric
	ModeProjectContext = protocol.ContentModeProjectContext
	genericSubject     = "[ThreadHub] 새 메시지가 등록되었습니다"
)

type Input struct {
	FromName, FromAddress, ReplyTo, ToAddress     string
	Domain, EventHash, RecipientHash, Permalink   string
	ContentMode, TeamName, ChannelName, EventType string
	Date                                          time.Time
}

type Message struct {
	EnvelopeFrom string
	EnvelopeTo   string
	Data         []byte
}

func Render(in Input) (Message, error) {
	if !validInput(in) {
		return Message{}, errInvalidInput
	}
	var body bytes.Buffer
	boundary := "threadhub-notice-" + opaqueID(in.EventHash, in.RecipientHash)[:24]
	from := (&mail.Address{Name: in.FromName, Address: in.FromAddress}).String()
	to := (&mail.Address{Address: in.ToAddress}).String()
	messageID := "<" + opaqueID(in.EventHash, in.RecipientHash) + "@" + in.Domain + ">"
	subject, plain, html := content(in)
	headers := []string{
		"From: " + from, "To: " + to, "Reply-To: " + in.ReplyTo,
		"Subject: " + mime.BEncoding.Encode("UTF-8", subject), "Date: " + in.Date.UTC().Format(time.RFC1123Z),
		"Message-ID: " + messageID, "MIME-Version: 1.0", "Content-Type: multipart/alternative; boundary=\"" + boundary + "\"",
	}
	body.WriteString(strings.Join(headers, "\r\n"))
	body.WriteString("\r\n\r\n")
	writer := multipart.NewWriter(&body)
	if err := writer.SetBoundary(boundary); err != nil {
		return Message{}, errInvalidInput
	}
	if err := writePart(writer, "text/plain; charset=UTF-8", plain); err != nil {
		return Message{}, errInvalidInput
	}
	if err := writePart(writer, "text/html; charset=UTF-8", html); err != nil {
		return Message{}, errInvalidInput
	}
	if err := writer.Close(); err != nil {
		return Message{}, errInvalidInput
	}
	data := bytes.ReplaceAll(body.Bytes(), []byte("\n"), []byte("\r\n"))
	data = bytes.ReplaceAll(data, []byte("\r\r\n"), []byte("\r\n"))
	return Message{EnvelopeFrom: in.FromAddress, EnvelopeTo: in.ToAddress, Data: data}, nil
}

func writePart(writer *multipart.Writer, contentType, content string) error {
	part, err := writer.CreatePart(map[string][]string{"Content-Type": {contentType}, "Content-Transfer-Encoding": {"8bit"}})
	if err != nil {
		return err
	}
	_, err = part.Write([]byte(content))
	return err
}

func content(in Input) (string, string, string) {
	if in.ContentMode != ModeProjectContext || in.TeamName == "" {
		plain := "ThreadHub에 새 메시지가 등록되었습니다.\r\n로그인하여 확인해 주세요.\r\n\r\n[메시지 확인]\r\n" + in.Permalink + "\r\n"
		html := "<p>ThreadHub에 새 메시지가 등록되었습니다.<br>로그인하여 확인해 주세요.</p><p><a href=\"" + htmlEscape(in.Permalink) + "\">메시지 확인</a></p>\r\n"
		return genericSubject, plain, html
	}
	kind := "새 글"
	if in.EventType == protocol.EventTypeThreadReply {
		kind = "스레드 답글"
	}
	subject := "[ThreadHub][" + in.Domain + "] " + truncateRunes(in.TeamName, 48) + " / " + truncateRunes(in.ChannelName, 48) + " · " + kind
	plain := "ThreadHub에 " + kind + "이 등록되었습니다.\r\n" +
		"프로젝트: " + in.Domain + "\r\n" +
		"팀: " + in.TeamName + "\r\n" +
		"채널: " + in.ChannelName + "\r\n" +
		"메시지 본문과 작성자 정보는 이메일에 포함하지 않습니다.\r\n\r\n" +
		"[메시지 확인]\r\n" + in.Permalink + "\r\n"
	html := "<p>ThreadHub에 " + kind + "이 등록되었습니다.</p>" +
		"<dl><dt>프로젝트</dt><dd>" + htmlEscape(in.Domain) + "</dd>" +
		"<dt>팀</dt><dd>" + htmlEscape(in.TeamName) + "</dd>" +
		"<dt>채널</dt><dd>" + htmlEscape(in.ChannelName) + "</dd></dl>" +
		"<p>메시지 본문과 작성자 정보는 이메일에 포함하지 않습니다.</p>" +
		"<p><a href=\"" + htmlEscape(in.Permalink) + "\">메시지 확인</a></p>\r\n"
	return subject, plain, html
}

func htmlEscape(value string) string {
	return strings.NewReplacer("&", "&amp;", "\"", "&quot;", "<", "&lt;", ">", "&gt;").Replace(value)
}
func opaqueID(eventHash, recipientHash string) string {
	sum := sha256.Sum256([]byte(eventHash + "\n" + recipientHash))
	return hex.EncodeToString(sum[:])
}

func validInput(in Input) bool {
	if in.Date.IsZero() || in.FromName == "" || in.Domain == "" || in.EventHash == "" || in.RecipientHash == "" || containsCRLF(in.FromName) || containsCRLF(in.Domain) || containsCRLF(in.EventHash) || containsCRLF(in.RecipientHash) {
		return false
	}
	if in.ContentMode != "" && in.ContentMode != ModeGeneric && in.ContentMode != ModeProjectContext {
		return false
	}
	if !validContext(in.TeamName, in.ChannelName, in.EventType) {
		return false
	}
	for _, address := range []string{in.FromAddress, in.ReplyTo, in.ToAddress} {
		parsed, err := mail.ParseAddress(address)
		if err != nil || parsed.Address != address || containsCRLF(address) {
			return false
		}
	}
	u, err := url.Parse(in.Permalink)
	return err == nil && u.Scheme == "https" && u.Host == in.Domain && u.User == nil && u.RawQuery == "" && u.Fragment == "" && !containsCRLF(in.Permalink)
}
func containsCRLF(value string) bool { return strings.ContainsAny(value, "\r\n") }

func validContext(teamName, channelName, eventType string) bool {
	if teamName == "" && channelName == "" && eventType == "" {
		return true
	}
	if !validDisplayName(teamName) || !validDisplayName(channelName) {
		return false
	}
	return eventType == protocol.EventTypeNewPost || eventType == protocol.EventTypeThreadReply
}

func validDisplayName(value string) bool {
	if value == "" || !utf8.ValidString(value) || utf8.RuneCountInString(value) > 128 {
		return false
	}
	for _, r := range value {
		if unicode.IsControl(r) {
			return false
		}
	}
	return true
}

func truncateRunes(value string, maximum int) string {
	runes := []rune(value)
	if len(runes) <= maximum {
		return value
	}
	return string(runes[:maximum-1]) + "…"
}
