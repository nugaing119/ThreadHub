package protocol

import (
	"fmt"
	"strings"
	"testing"

	"github.com/mattermost/mattermost/server/public/model"
)

const (
	testID     = "0123456789abcdef0123456789"
	testDomain = "threadhub.test"
)

func validEvent() Event {
	return Event{
		EventID:    testID,
		PostID:     testID,
		Permalink:  "https://" + testDomain + "/pl/" + testID,
		OccurredAt: 1787790000000,
		Recipients: []Recipient{{
			UserID: testID,
			Email:  "recipient@example.com",
		}},
	}
}

func addRecipients(n int) func(*Event) {
	return func(e *Event) {
		e.Recipients = make([]Recipient, n)
		for i := range e.Recipients {
			id := fmt.Sprintf("%026x", i+1)
			e.Recipients[i] = Recipient{UserID: id, Email: fmt.Sprintf("recipient+%d@example.com", i)}
		}
	}
}

func duplicateRecipient(e *Event) {
	e.Recipients = append(e.Recipients, Recipient{UserID: e.Recipients[0].UserID, Email: "other@example.com"})
}

func injectCRLF(e *Event) {
	e.Recipients[0].Email = "recipient@example.com\r\nBcc: injected@example.com"
}

func TestEventValidate(t *testing.T) {
	tests := []struct {
		name    string
		mutate  func(*Event)
		wantErr bool
	}{
		{name: "valid minimal event"},
		{name: "event and post ids differ", mutate: func(e *Event) { e.EventID = model.NewId() }, wantErr: true},
		{name: "http permalink", mutate: func(e *Event) { e.Permalink = "http://threadhub.test/pl/" + e.PostID }, wantErr: true},
		{name: "percent-encoded permalink path", mutate: func(e *Event) { e.Permalink = "https://threadhub.test/pl%2f" + e.PostID }, wantErr: true},
		{name: "foreign host", mutate: func(e *Event) { e.Permalink = "https://other.test/pl/" + e.PostID }, wantErr: true},
		{name: "unknown post path", mutate: func(e *Event) { e.Permalink = "https://threadhub.test/channels/town-square" }, wantErr: true},
		{name: "no recipients", mutate: func(e *Event) { e.Recipients = nil }, wantErr: true},
		{name: "more than two hundred fifty recipients", mutate: addRecipients(251), wantErr: true},
		{name: "duplicate user", mutate: duplicateRecipient, wantErr: true},
		{name: "header injection email", mutate: injectCRLF, wantErr: true},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			e := validEvent()
			if tt.mutate != nil {
				tt.mutate(&e)
			}
			if err := e.Validate(testDomain); (err != nil) != tt.wantErr {
				t.Fatalf("Validate() error = %v, wantErr %v", err, tt.wantErr)
			}
		})
	}
}

func TestValidateEmail(t *testing.T) {
	valid := []string{"recipient@example.com", "first.last+tag@example.co.uk"}
	for _, email := range valid {
		t.Run("accepts "+email, func(t *testing.T) {
			if err := ValidateEmail(email); err != nil {
				t.Fatalf("ValidateEmail() error = %v", err)
			}
		})
	}

	invalid := []string{"", "not-an-email", "Display Name <recipient@example.com>", "recipient@example.com\r\nBcc: x@example.com"}
	for _, email := range invalid {
		t.Run("rejects "+strings.ReplaceAll(email, "\r\n", "_"), func(t *testing.T) {
			if err := ValidateEmail(email); err == nil {
				t.Fatal("ValidateEmail() accepted invalid address")
			}
		})
	}
}

func TestDecodeSecretHex(t *testing.T) {
	secretText := "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
	secret, err := DecodeSecretHex(secretText)
	if err != nil {
		t.Fatalf("DecodeSecretHex() error = %v", err)
	}
	if len(secret) != 32 {
		t.Fatalf("decoded secret length = %d, want 32", len(secret))
	}

	for _, input := range []string{"", "xyz", "00", secretText + "00"} {
		t.Run("rejects malformed secret", func(t *testing.T) {
			if _, err := DecodeSecretHex(input); err == nil {
				t.Fatal("DecodeSecretHex() accepted malformed secret")
			}
		})
	}
}
