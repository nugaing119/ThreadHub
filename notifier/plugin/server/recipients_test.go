package server

import (
	"errors"
	"fmt"
	"reflect"
	"testing"

	"github.com/mattermost/mattermost/server/public/model"
	"github.com/nugaing119/ThreadHub/notifier/protocol"
)

func TestRecipientResolverProcessesOnlyOpenAndPrivateChannels(t *testing.T) {
	for _, channelType := range []model.ChannelType{model.ChannelTypeOpen, model.ChannelTypePrivate} {
		t.Run(string(channelType), func(t *testing.T) {
			api := newRecipientTestAPI(channelType)
			api.memberPages[0] = model.ChannelMembers{{ChannelId: testChannelID, UserId: testRecipientID(1)}}
			api.users[testRecipientID(1)] = eligibleTestUser(1)

			got, err := NewRecipientResolver(api).Resolve(testOutboxEvent(testPostID))
			if err != nil {
				t.Fatalf("Resolve() error = %v", err)
			}
			want := []protocol.Recipient{{UserID: testRecipientID(1), Email: "recipient-001@example.test"}}
			if !reflect.DeepEqual(got, want) {
				t.Fatalf("Resolve() = %#v, want %#v", got, want)
			}
		})
	}

	for _, channelType := range []model.ChannelType{model.ChannelTypeDirect, model.ChannelTypeGroup} {
		t.Run(string(channelType), func(t *testing.T) {
			api := newRecipientTestAPI(channelType)
			api.memberPages[0] = model.ChannelMembers{{ChannelId: testChannelID, UserId: testRecipientID(1)}}
			got, err := NewRecipientResolver(api).Resolve(testOutboxEvent(testPostID))
			if err != nil {
				t.Fatalf("Resolve() error = %v", err)
			}
			if len(got) != 0 || len(api.memberCalls) != 0 || len(api.userCalls) != 0 {
				t.Fatalf("unsupported channel Resolve() = %#v, member calls=%v user calls=%v", got, api.memberCalls, api.userCalls)
			}
		})
	}
}

func TestRecipientResolverPagesMembersAndFetchesUsersInChunksOfTwoHundred(t *testing.T) {
	api := newRecipientTestAPI(model.ChannelTypeOpen)
	firstPage := make(model.ChannelMembers, 200)
	for i := range firstPage {
		id := testRecipientID(i + 1)
		firstPage[i] = model.ChannelMember{ChannelId: testChannelID, UserId: id}
		api.users[id] = eligibleTestUser(i + 1)
	}
	lastID := testRecipientID(201)
	api.memberPages[0] = firstPage
	api.memberPages[1] = model.ChannelMembers{{ChannelId: testChannelID, UserId: lastID}}
	api.users[lastID] = eligibleTestUser(201)

	got, err := NewRecipientResolver(api).Resolve(testOutboxEvent(testPostID))
	if err != nil {
		t.Fatalf("Resolve() error = %v", err)
	}
	if len(got) != 201 {
		t.Fatalf("Resolve() recipient count = %d, want 201", len(got))
	}
	if want := []memberCall{{page: 0, perPage: 200}, {page: 1, perPage: 200}}; !reflect.DeepEqual(api.memberCalls, want) {
		t.Fatalf("GetChannelMembers calls = %#v, want %#v", api.memberCalls, want)
	}
	if len(api.userCalls) != 2 || len(api.userCalls[0]) != 200 || len(api.userCalls[1]) != 1 {
		t.Fatalf("GetUsersByIds chunk sizes = %v, want [200 1]", userCallSizes(api.userCalls))
	}
}

func TestRecipientResolverFiltersIneligibleUsersAndUsesOnlyChannelMembership(t *testing.T) {
	api := newRecipientTestAPI(model.ChannelTypePrivate)
	eligible := eligibleTestUser(1)
	deleted := eligibleTestUser(2)
	deleted.DeleteAt = 1
	bot := eligibleTestUser(3)
	bot.IsBot = true
	emailEmpty := eligibleTestUser(4)
	emailEmpty.Email = ""
	unverified := eligibleTestUser(5)
	unverified.EmailVerified = false
	author := eligibleTestUser(6)
	author.Id = testAuthorID
	for _, user := range []*model.User{eligible, deleted, bot, emailEmpty, unverified, author} {
		api.users[user.Id] = user
	}
	teamOnly := eligibleTestUser(7)
	api.users[teamOnly.Id] = teamOnly
	api.memberPages[0] = model.ChannelMembers{
		{ChannelId: testChannelID, UserId: eligible.Id},
		{ChannelId: testChannelID, UserId: deleted.Id},
		{ChannelId: testChannelID, UserId: bot.Id},
		{ChannelId: testChannelID, UserId: emailEmpty.Id},
		{ChannelId: testChannelID, UserId: unverified.Id},
		{ChannelId: testChannelID, UserId: author.Id},
	}

	got, err := NewRecipientResolver(api).Resolve(testOutboxEvent(testPostID))
	if err != nil {
		t.Fatalf("Resolve() error = %v", err)
	}
	want := []protocol.Recipient{{UserID: eligible.Id, Email: eligible.Email}}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("Resolve() = %#v, want only eligible channel member %#v", got, want)
	}
}

func TestRecipientResolverSortsAndDeduplicatesCurrentChannelMembers(t *testing.T) {
	api := newRecipientTestAPI(model.ChannelTypeOpen)
	first := eligibleTestUser(1)
	second := eligibleTestUser(2)
	api.users[first.Id] = first
	api.users[second.Id] = second
	api.memberPages[0] = model.ChannelMembers{
		{ChannelId: testChannelID, UserId: second.Id},
		{ChannelId: testChannelID, UserId: first.Id},
		{ChannelId: testChannelID, UserId: second.Id},
	}

	got, err := NewRecipientResolver(api).Resolve(testOutboxEvent(testPostID))
	if err != nil {
		t.Fatalf("Resolve() error = %v", err)
	}
	want := []protocol.Recipient{
		{UserID: first.Id, Email: first.Email},
		{UserID: second.Id, Email: second.Email},
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("Resolve() = %#v, want sorted unique %#v", got, want)
	}
}

func TestRecipientResolverTreatsRootAndReplyAsTheSameCurrentChannelAudience(t *testing.T) {
	api := newRecipientTestAPI(model.ChannelTypeOpen)
	user := eligibleTestUser(1)
	api.users[user.Id] = user
	api.memberPages[0] = model.ChannelMembers{{ChannelId: testChannelID, UserId: user.Id}}
	resolver := NewRecipientResolver(api)

	root, err := resolver.Resolve(testOutboxEvent(testPostID))
	if err != nil {
		t.Fatalf("root Resolve() error = %v", err)
	}
	reply, err := resolver.Resolve(testOutboxEvent("bcdefghijklmnopqrstuvwx123"))
	if err != nil {
		t.Fatalf("reply Resolve() error = %v", err)
	}
	if !reflect.DeepEqual(root, reply) {
		t.Fatalf("root recipients = %#v, reply recipients = %#v", root, reply)
	}
}

func TestRecipientResolverReturnsAnExplicitErrorAboveTheDeliveryLimit(t *testing.T) {
	api := newRecipientTestAPI(model.ChannelTypeOpen)
	firstPage := make(model.ChannelMembers, 200)
	secondPage := make(model.ChannelMembers, 51)
	for i := 1; i <= 251; i++ {
		id := testRecipientID(i)
		member := model.ChannelMember{ChannelId: testChannelID, UserId: id}
		if i <= 200 {
			firstPage[i-1] = member
		} else {
			secondPage[i-201] = member
		}
		api.users[id] = eligibleTestUser(i)
	}
	api.memberPages[0] = firstPage
	api.memberPages[1] = secondPage

	got, err := NewRecipientResolver(api).Resolve(testOutboxEvent(testPostID))
	if !errors.Is(err, ErrRecipientLimit) || got != nil {
		t.Fatalf("Resolve() = %#v, %v; want nil, ErrRecipientLimit", got, err)
	}
}

func TestRecipientResolverReturnsSanitizedMattermostErrors(t *testing.T) {
	api := newRecipientTestAPI(model.ChannelTypeOpen)
	api.channelErr = &model.AppError{Id: "channel_lookup_failed", DetailedError: "private-channel-name"}
	_, err := NewRecipientResolver(api).Resolve(testOutboxEvent(testPostID))
	if err == nil || err.Error() != "get channel failed: channel_lookup_failed" {
		t.Fatalf("Resolve() error = %v, want sanitized channel lookup class", err)
	}
}

type memberCall struct {
	page    int
	perPage int
}

type recipientTestAPI struct {
	channel       *model.Channel
	channelErr    *model.AppError
	memberPages   map[int]model.ChannelMembers
	memberErrPage map[int]*model.AppError
	users         map[string]*model.User
	usersErr      *model.AppError
	memberCalls   []memberCall
	userCalls     [][]string
}

func newRecipientTestAPI(channelType model.ChannelType) *recipientTestAPI {
	return &recipientTestAPI{
		channel:       &model.Channel{Id: testChannelID, Type: channelType},
		memberPages:   make(map[int]model.ChannelMembers),
		memberErrPage: make(map[int]*model.AppError),
		users:         make(map[string]*model.User),
	}
}

func (f *recipientTestAPI) GetChannel(string) (*model.Channel, *model.AppError) {
	return f.channel, f.channelErr
}

func (f *recipientTestAPI) GetTeam(string) (*model.Team, *model.AppError) { return nil, nil }

func (f *recipientTestAPI) GetChannelMembers(_ string, page, perPage int) (model.ChannelMembers, *model.AppError) {
	f.memberCalls = append(f.memberCalls, memberCall{page: page, perPage: perPage})
	return append(model.ChannelMembers(nil), f.memberPages[page]...), f.memberErrPage[page]
}

func (f *recipientTestAPI) GetUsersByIds(ids []string) ([]*model.User, *model.AppError) {
	f.userCalls = append(f.userCalls, append([]string(nil), ids...))
	if f.usersErr != nil {
		return nil, f.usersErr
	}
	users := make([]*model.User, 0, len(ids))
	for i := len(ids) - 1; i >= 0; i-- {
		if user := f.users[ids[i]]; user != nil {
			copyUser := *user
			users = append(users, &copyUser)
		}
	}
	return users, nil
}

func (f *recipientTestAPI) KVSetWithOptions(string, []byte, model.PluginKVSetOptions) (bool, *model.AppError) {
	return false, nil
}
func (f *recipientTestAPI) KVGet(string) ([]byte, *model.AppError)      { return nil, nil }
func (f *recipientTestAPI) KVList(int, int) ([]string, *model.AppError) { return nil, nil }
func (f *recipientTestAPI) KVCompareAndDelete(string, []byte) (bool, *model.AppError) {
	return false, nil
}

func eligibleTestUser(index int) *model.User {
	return &model.User{Id: testRecipientID(index), Email: fmt.Sprintf("recipient-%03d@example.test", index), EmailVerified: true}
}

func testRecipientID(index int) string {
	return fmt.Sprintf("%026d", index)
}

func testOutboxEvent(postID string) OutboxEvent {
	return OutboxEvent{PostID: postID, ChannelID: testChannelID, AuthorUserID: testAuthorID, CreateAt: 1787790000000}
}

func userCallSizes(calls [][]string) []int {
	sizes := make([]int, len(calls))
	for i := range calls {
		sizes[i] = len(calls[i])
	}
	return sizes
}
