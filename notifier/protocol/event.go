package protocol

import (
	"errors"
	"fmt"
	"net/mail"
	"net/url"
	"regexp"
)

var (
	ErrInvalidPostID      = errors.New("invalid post id")
	ErrRecipientCount     = errors.New("invalid recipient count")
	ErrInvalidPermalink   = errors.New("invalid permalink")
	ErrDuplicateRecipient = errors.New("duplicate recipient")
	ErrInvalidRecipient   = errors.New("invalid recipient")
	ErrInvalidEmail       = errors.New("invalid email")
)

var mattermostID = regexp.MustCompile(`^[a-z0-9]{26}$`)

type Event struct {
	EventID    string      `json:"event_id"`
	PostID     string      `json:"post_id"`
	Permalink  string      `json:"permalink"`
	OccurredAt int64       `json:"occurred_at"`
	Recipients []Recipient `json:"recipients"`
}

type Recipient struct {
	UserID string `json:"user_id"`
	Email  string `json:"email"`
}

func (e Event) Validate(domain string) error {
	if e.EventID != e.PostID || !mattermostID.MatchString(e.PostID) {
		return ErrInvalidPostID
	}
	if len(e.Recipients) < 1 || len(e.Recipients) > 250 {
		return ErrRecipientCount
	}

	u, err := url.Parse(e.Permalink)
	if err != nil || u.Scheme != "https" || u.Host != domain || u.User != nil || u.RawQuery != "" || u.Fragment != "" || u.ForceQuery || u.Path != "/pl/"+e.PostID {
		return ErrInvalidPermalink
	}

	seen := make(map[string]struct{}, len(e.Recipients))
	for _, recipient := range e.Recipients {
		if !mattermostID.MatchString(recipient.UserID) {
			return fmt.Errorf("%w: user id", ErrInvalidRecipient)
		}
		if _, ok := seen[recipient.UserID]; ok {
			return ErrDuplicateRecipient
		}
		seen[recipient.UserID] = struct{}{}
		if err := ValidateEmail(recipient.Email); err != nil {
			return fmt.Errorf("%w: %v", ErrInvalidRecipient, err)
		}
	}
	return nil
}

func ValidateEmail(value string) error {
	if value == "" || containsCRLF(value) {
		return ErrInvalidEmail
	}
	parsed, err := mail.ParseAddress(value)
	if err != nil || parsed.Address != value {
		return ErrInvalidEmail
	}
	return nil
}

func containsCRLF(value string) bool {
	for _, r := range value {
		if r == '\r' || r == '\n' {
			return true
		}
	}
	return false
}
