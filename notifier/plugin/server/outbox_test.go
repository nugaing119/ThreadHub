package server

import (
	"bytes"
	"errors"
	"reflect"
	"testing"

	"github.com/mattermost/mattermost/server/public/model"
)

func TestOutboxPutAtomicallyInsertsAndIgnoresDuplicates(t *testing.T) {
	api := newFakeMattermostAPI()
	outbox := NewOutbox(api)
	event := OutboxEvent{PostID: testPostID, ChannelID: testChannelID, AuthorUserID: testAuthorID, CreateAt: 100}

	if err := outbox.Put(event); err != nil {
		t.Fatalf("first Put() error = %v", err)
	}
	if err := outbox.Put(event); err != nil {
		t.Fatalf("duplicate Put() error = %v", err)
	}
	if got, want := api.setKeys, []string{"outbox:" + testPostID, "outbox:" + testPostID}; !reflect.DeepEqual(got, want) {
		t.Fatalf("KVSetWithOptions keys = %v, want %v", got, want)
	}
	for _, options := range api.setOptions {
		if !options.Atomic || options.OldValue != nil {
			t.Fatalf("KVSetWithOptions options = %#v, want atomic nil-old-value insert", options)
		}
	}
}

func TestOutboxPutReturnsOnlyKVErrorClass(t *testing.T) {
	api := newFakeMattermostAPI()
	api.setErr = &model.AppError{Id: "store_failure", DetailedError: "raw value must never escape"}
	err := NewOutbox(api).Put(OutboxEvent{PostID: testPostID, ChannelID: testChannelID, AuthorUserID: testAuthorID, CreateAt: 100})
	if err == nil || err.Error() != "plugin kv set failed: store_failure" {
		t.Fatalf("Put() error = %v, want fixed error class", err)
	}
}

func TestOutboxListReadsEveryPageAndIgnoresOtherPrefixes(t *testing.T) {
	api := newFakeMattermostAPI()
	first := `{"post_id":"abcdefghijklmnopqrstuvwx12","channel_id":"0123456789abcdef0123456789","author_user_id":"zyxwvutsrqponmlkjihgfedcba","create_at":100}`
	second := `{"post_id":"bcdefghijklmnopqrstuvwx123","channel_id":"0123456789abcdef0123456789","author_user_id":"zyxwvutsrqponmlkjihgfedcba","create_at":101}`
	firstPage := make([]string, 200)
	for i := range firstPage {
		firstPage[i] = "other:key"
	}
	firstPage[199] = "outbox:" + testPostID
	api.pages = map[int][]string{0: firstPage, 1: {"outbox:bcdefghijklmnopqrstuvwx123"}}
	api.values["outbox:"+testPostID] = []byte(first)
	api.values["outbox:bcdefghijklmnopqrstuvwx123"] = []byte(second)

	stored, err := NewOutbox(api).List()
	if err != nil {
		t.Fatalf("List() error = %v", err)
	}
	if got, want := api.listCalls, []int{0, 1}; !reflect.DeepEqual(got, want) {
		t.Fatalf("KVList pages = %v, want %v", got, want)
	}
	if len(stored) != 2 || stored[0].Event.PostID != testPostID || stored[1].Event.CreateAt != 101 {
		t.Fatalf("List() = %#v, want decoded outbox events", stored)
	}
}

func TestOutboxListContainsMalformedValueWithoutExposingRawContents(t *testing.T) {
	for _, raw := range [][]byte{
		[]byte(`{"post_id":`),
		[]byte(`null`),
		[]byte(`{"post_id":"abcdefghijklmnopqrstuvwx12"}`),
		[]byte(`{"post_id":"abcdefghijklmnopqrstuvwx12","channel_id":"0123456789abcdef0123456789","author_user_id":"zyxwvutsrqponmlkjihgfedcba","create_at":100,"unexpected":true}`),
	} {
		api := newFakeMattermostAPI()
		api.pages = map[int][]string{0: {"outbox:" + testPostID}}
		api.values["outbox:"+testPostID] = raw

		stored, err := NewOutbox(api).List()
		if len(stored) != 0 || !errors.Is(err, ErrMalformedOutbox) || bytes.Contains([]byte(err.Error()), raw) {
			t.Fatalf("List() did not isolate malformed data without exposing its raw value")
		}
	}
}

func TestOutboxCompleteUsesExactOriginalRawBytesForCASDelete(t *testing.T) {
	api := newFakeMattermostAPI()
	raw := []byte("{\n\t\"post_id\":\"" + testPostID + "\",\"channel_id\":\"" + testChannelID + "\",\"author_user_id\":\"" + testAuthorID + "\",\"create_at\":100\n}")
	event := OutboxEvent{PostID: testPostID, ChannelID: testChannelID, AuthorUserID: testAuthorID, CreateAt: 100}
	api.values["outbox:"+testPostID] = append([]byte(nil), raw...)
	if err := NewOutbox(api).Complete(StoredEvent{Key: "outbox:" + testPostID, Raw: raw, Event: event}); err != nil {
		t.Fatalf("Complete() error = %v", err)
	}
	if !bytes.Equal(api.deletedRaw, raw) {
		t.Fatalf("KVCompareAndDelete raw = %q, want original %q", api.deletedRaw, raw)
	}
}

type fakeMattermostAPI struct {
	values     map[string][]byte
	pages      map[int][]string
	setKeys    []string
	setOptions []model.PluginKVSetOptions
	listCalls  []int
	deletedKey string
	deletedRaw []byte
	setErr     *model.AppError
}

func newFakeMattermostAPI() *fakeMattermostAPI {
	return &fakeMattermostAPI{values: make(map[string][]byte), pages: make(map[int][]string)}
}

func (f *fakeMattermostAPI) GetChannel(string) (*model.Channel, *model.AppError) { return nil, nil }
func (f *fakeMattermostAPI) GetChannelMembers(string, int, int) (model.ChannelMembers, *model.AppError) {
	return nil, nil
}
func (f *fakeMattermostAPI) GetUsersByIds([]string) ([]*model.User, *model.AppError) { return nil, nil }
func (f *fakeMattermostAPI) KVSetWithOptions(key string, value []byte, options model.PluginKVSetOptions) (bool, *model.AppError) {
	f.setKeys = append(f.setKeys, key)
	f.setOptions = append(f.setOptions, options)
	if f.setErr != nil {
		return false, f.setErr
	}
	if _, exists := f.values[key]; exists {
		return false, nil
	}
	f.values[key] = append([]byte(nil), value...)
	return true, nil
}
func (f *fakeMattermostAPI) KVGet(key string) ([]byte, *model.AppError) {
	return append([]byte(nil), f.values[key]...), nil
}
func (f *fakeMattermostAPI) KVList(page, perPage int) ([]string, *model.AppError) {
	if perPage != 200 {
		return nil, &model.AppError{Id: "wrong_page_size"}
	}
	f.listCalls = append(f.listCalls, page)
	return append([]string(nil), f.pages[page]...), nil
}
func (f *fakeMattermostAPI) KVCompareAndDelete(key string, value []byte) (bool, *model.AppError) {
	current, exists := f.values[key]
	if !exists || !bytes.Equal(current, value) {
		return false, nil
	}
	delete(f.values, key)
	f.deletedKey = key
	f.deletedRaw = append([]byte(nil), value...)
	return true, nil
}
