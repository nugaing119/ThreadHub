// Package message renders the sole privacy-safe notification email format.
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
)

var errInvalidInput = errors.New("invalid email message input")

const subject = "[ThreadHub] 새 메시지가 등록되었습니다"

type Input struct {
	FromName, FromAddress, ReplyTo, ToAddress   string
	Domain, EventHash, RecipientHash, Permalink string
	Date                                        time.Time
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
	headers := []string{
		"From: " + from, "To: " + to, "Reply-To: " + in.ReplyTo,
		"Subject: " + mime.BEncoding.Encode("UTF-8", subject), "Date: " + in.Date.UTC().Format(time.RFC1123Z),
		"Message-ID: " + messageID, "MIME-Version: 1.0", "Content-Type: multipart/alternative; boundary=\"" + boundary + "\"", "",
	}
	body.WriteString(strings.Join(headers, "\r\n"))
	writer := multipart.NewWriter(&body)
	if err := writer.SetBoundary(boundary); err != nil {
		return Message{}, errInvalidInput
	}
	plain, html := content(in.Permalink)
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

func content(permalink string) (string, string) {
	plain := "ThreadHub에 새 메시지가 등록되었습니다.\r\n로그인하여 확인해 주세요.\r\n\r\n[메시지 확인]\r\n" + permalink + "\r\n"
	html := "<p>ThreadHub에 새 메시지가 등록되었습니다.<br>로그인하여 확인해 주세요.</p><p><a href=\"" + htmlEscape(permalink) + "\">메시지 확인</a></p>\r\n"
	return plain, html
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
