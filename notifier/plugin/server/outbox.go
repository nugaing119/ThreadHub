package server

import (
	"bytes"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"strings"
	"time"

	"github.com/mattermost/mattermost/server/public/model"
)

const (
	outboxPrefix   = "outbox:"
	outboxPageSize = 200
)

var ErrMalformedOutbox = errors.New("malformed outbox event")

type malformedOutboxError struct {
	stored StoredEvent
}

func (e *malformedOutboxError) Error() string { return ErrMalformedOutbox.Error() }

func (e *malformedOutboxError) Unwrap() error { return ErrMalformedOutbox }

type MattermostAPI interface {
	GetChannel(channelID string) (*model.Channel, *model.AppError)
	GetChannelMembers(channelID string, page, perPage int) (model.ChannelMembers, *model.AppError)
	GetUsersByIds(userIDs []string) ([]*model.User, *model.AppError)
	KVSetWithOptions(string, []byte, model.PluginKVSetOptions) (bool, *model.AppError)
	KVGet(string) ([]byte, *model.AppError)
	KVList(page, perPage int) ([]string, *model.AppError)
	KVCompareAndDelete(string, []byte) (bool, *model.AppError)
}

type OutboxEvent struct {
	PostID       string `json:"post_id"`
	ChannelID    string `json:"channel_id"`
	AuthorUserID string `json:"author_user_id"`
	CreateAt     int64  `json:"create_at"`
}

type StoredEvent struct {
	Key   string
	Raw   []byte
	Event OutboxEvent
}

type Outbox struct {
	api MattermostAPI
}

func NewOutbox(api MattermostAPI) *Outbox {
	return &Outbox{api: api}
}

func NewOutboxEvent(post *model.Post) OutboxEvent {
	if post == nil {
		return OutboxEvent{}
	}
	return OutboxEvent{PostID: post.Id, ChannelID: post.ChannelId, AuthorUserID: post.UserId, CreateAt: post.CreateAt}
}

func (o *Outbox) Put(event OutboxEvent) error {
	raw, err := json.Marshal(event)
	if err != nil {
		return err
	}
	_, appErr := o.api.KVSetWithOptions(outboxPrefix+event.PostID, raw, model.PluginKVSetOptions{Atomic: true, OldValue: nil})
	if appErr != nil {
		return appError("plugin kv set failed", appErr)
	}
	return nil
}

func (o *Outbox) List() ([]StoredEvent, error) {
	var events []StoredEvent
	for page := 0; ; page++ {
		keys, appErr := o.api.KVList(page, outboxPageSize)
		if appErr != nil {
			return events, appError("plugin kv list failed", appErr)
		}
		for _, key := range keys {
			if !strings.HasPrefix(key, outboxPrefix) {
				continue
			}
			raw, appErr := o.api.KVGet(key)
			if appErr != nil {
				return events, appError("plugin kv get failed", appErr)
			}
			event, err := decodeOutboxEvent(key, raw)
			if err != nil {
				return events, &malformedOutboxError{stored: StoredEvent{Key: key, Raw: raw}}
			}
			events = append(events, StoredEvent{Key: key, Raw: raw, Event: event})
		}
		if len(keys) < outboxPageSize {
			return events, nil
		}
	}
}

func (o *Outbox) Quarantine(stored StoredEvent, at time.Time) error {
	type deadLetter struct {
		ErrorClass    string `json:"error_class"`
		QuarantinedAt int64  `json:"quarantined_at"`
	}
	raw, err := json.Marshal(deadLetter{ErrorClass: "malformed_outbox", QuarantinedAt: at.UnixMilli()})
	if err != nil {
		return errors.New("dead letter encoding failed")
	}
	hash := sha256.Sum256([]byte(stored.Key))
	deadKey := fmt.Sprintf("dead:%x", hash[:])
	if _, appErr := o.api.KVSetWithOptions(deadKey, raw, model.PluginKVSetOptions{Atomic: true, OldValue: nil}); appErr != nil {
		return appError("dead letter write failed", appErr)
	}
	return o.Complete(stored)
}

func decodeOutboxEvent(key string, raw []byte) (OutboxEvent, error) {
	type encodedEvent struct {
		PostID       *string `json:"post_id"`
		ChannelID    *string `json:"channel_id"`
		AuthorUserID *string `json:"author_user_id"`
		CreateAt     *int64  `json:"create_at"`
	}
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.DisallowUnknownFields()
	var encoded encodedEvent
	if err := decoder.Decode(&encoded); err != nil {
		return OutboxEvent{}, ErrMalformedOutbox
	}
	var trailing any
	if err := decoder.Decode(&trailing); !errors.Is(err, io.EOF) {
		return OutboxEvent{}, ErrMalformedOutbox
	}
	if encoded.PostID == nil || encoded.ChannelID == nil || encoded.AuthorUserID == nil || encoded.CreateAt == nil || *encoded.PostID == "" || *encoded.ChannelID == "" || *encoded.AuthorUserID == "" || key != outboxPrefix+*encoded.PostID {
		return OutboxEvent{}, ErrMalformedOutbox
	}
	return OutboxEvent{PostID: *encoded.PostID, ChannelID: *encoded.ChannelID, AuthorUserID: *encoded.AuthorUserID, CreateAt: *encoded.CreateAt}, nil
}

func (o *Outbox) Complete(stored StoredEvent) error {
	deleted, appErr := o.api.KVCompareAndDelete(stored.Key, stored.Raw)
	if appErr != nil {
		return appError("plugin kv compare-and-delete failed", appErr)
	}
	if !deleted {
		return errors.New("plugin kv compare-and-delete conflict")
	}
	return nil
}

func appError(prefix string, appErr *model.AppError) error {
	if appErr == nil || appErr.Id == "" {
		return errors.New(prefix)
	}
	return fmt.Errorf("%s: %s", prefix, appErr.Id)
}
