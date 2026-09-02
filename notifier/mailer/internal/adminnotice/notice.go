// Package adminnotice renders privacy-safe administrative email notices.
package adminnotice

import (
	"encoding/hex"
	"errors"
	"mime"
	"net/mail"
	"strings"
	"time"

	"github.com/nugaing119/ThreadHub/notifier/mailer/internal/message"
)

var errInvalidInput = errors.New("invalid administrative notice input")

var allowedFailureClasses = map[string]struct{}{
	"preflight":        {},
	"snapshot":         {},
	"service_recovery": {},
	"manifest":         {},
	"upload":           {},
	"remote_verify":    {},
}

type Input struct {
	FromName     string
	FromAddress  string
	ReplyTo      string
	ToAddress    string
	Domain       string
	FailureClass string
	OpaqueID     string
	Date         time.Time
}

func ValidFailureClass(value string) bool {
	_, ok := allowedFailureClasses[value]
	return ok
}

func Render(in Input) (message.Message, error) {
	if !validInput(in) {
		return message.Message{}, errInvalidInput
	}
	from := (&mail.Address{Name: in.FromName, Address: in.FromAddress}).String()
	to := (&mail.Address{Address: in.ToAddress}).String()
	subject := mime.BEncoding.Encode("UTF-8", "[ThreadHub] 백업 실패 ("+in.FailureClass+")")
	headers := []string{
		"From: " + from,
		"To: " + to,
		"Reply-To: " + in.ReplyTo,
		"Subject: " + subject,
		"Date: " + in.Date.UTC().Format(time.RFC1123Z),
		"Message-ID: <" + in.OpaqueID + "@" + in.Domain + ">",
		"MIME-Version: 1.0",
		"Content-Type: text/plain; charset=UTF-8",
		"Content-Transfer-Encoding: 8bit",
	}
	body := "ThreadHub 자동 백업이 실패했습니다.\r\n서버에서 backup-status를 확인해 주세요.\r\n"
	data := []byte(strings.Join(headers, "\r\n") + "\r\n\r\n" + body)
	return message.Message{EnvelopeFrom: in.FromAddress, EnvelopeTo: in.ToAddress, Data: data}, nil
}

func validInput(in Input) bool {
	if in.Date.IsZero() || in.FromName == "" || containsCRLF(in.FromName) || !validDomain(in.Domain) || !ValidFailureClass(in.FailureClass) || !validOpaqueID(in.OpaqueID) {
		return false
	}
	for _, address := range []string{in.FromAddress, in.ReplyTo, in.ToAddress} {
		parsed, err := mail.ParseAddress(address)
		if err != nil || parsed.Address != address || containsCRLF(address) {
			return false
		}
	}
	return true
}

func validOpaqueID(value string) bool {
	if len(value) != 64 || value != strings.ToLower(value) {
		return false
	}
	decoded, err := hex.DecodeString(value)
	return err == nil && len(decoded) == 32
}

func validDomain(value string) bool {
	if value == "" || len(value) > 253 || containsCRLF(value) || value != strings.ToLower(value) {
		return false
	}
	for _, label := range strings.Split(value, ".") {
		if label == "" || len(label) > 63 || label[0] == '-' || label[len(label)-1] == '-' {
			return false
		}
		for _, char := range label {
			if (char < 'a' || char > 'z') && (char < '0' || char > '9') && char != '-' {
				return false
			}
		}
	}
	return true
}

func containsCRLF(value string) bool {
	return strings.ContainsAny(value, "\r\n")
}
