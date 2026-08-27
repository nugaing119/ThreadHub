package server

import (
	"testing"

	"github.com/mattermost/mattermost/server/public/model"
	"github.com/nugaing119/ThreadHub/notifier/control"
)

const (
	testPostID    = "abcdefghijklmnopqrstuvwx12"
	testChannelID = "0123456789abcdef0123456789"
	testAuthorID  = "zyxwvutsrqponmlkjihgfedcba"
)

func TestEligibleAtHookFiltersOnlyUsingControlStateAndPost(t *testing.T) {
	activeAll := control.State{Enabled: true, DeliveryEnabled: true, Mode: "all_channels", ActivatedAt: 100}
	activeAllowlist := control.State{Enabled: true, DeliveryEnabled: true, Mode: "allowlist", ChannelIDs: []string{testChannelID}, ActivatedAt: 100}
	base := &model.Post{Id: testPostID, ChannelId: testChannelID, UserId: testAuthorID, CreateAt: 100}

	tests := []struct {
		name  string
		state control.State
		post  *model.Post
		want  bool
	}{
		{name: "active all channels root", state: activeAll, post: base, want: true},
		{name: "active all channels reply", state: activeAll, post: &model.Post{Id: testPostID, ChannelId: testChannelID, UserId: testAuthorID, RootId: testPostID, CreateAt: 100}, want: true},
		{name: "disabled", state: control.State{}, post: base},
		{name: "before activation cutoff", state: activeAll, post: &model.Post{Id: testPostID, ChannelId: testChannelID, UserId: testAuthorID, CreateAt: 99}},
		{name: "allowlist member", state: activeAllowlist, post: base, want: true},
		{name: "outside allowlist", state: activeAllowlist, post: &model.Post{Id: testPostID, ChannelId: "aaaaaaaaaaaaaaaaaaaaaaaaaa", UserId: testAuthorID, CreateAt: 100}},
		{name: "system message", state: activeAll, post: &model.Post{Id: testPostID, ChannelId: testChannelID, UserId: testAuthorID, Type: model.PostTypeJoinLeave, CreateAt: 100}},
		{name: "empty post ID", state: activeAll, post: &model.Post{ChannelId: testChannelID, UserId: testAuthorID, CreateAt: 100}},
		{name: "empty channel ID", state: activeAll, post: &model.Post{Id: testPostID, UserId: testAuthorID, CreateAt: 100}},
		{name: "deleted post", state: activeAll, post: &model.Post{Id: testPostID, ChannelId: testChannelID, UserId: testAuthorID, CreateAt: 100, DeleteAt: 101}},
		{name: "bot ordinary post", state: activeAll, post: &model.Post{Id: testPostID, ChannelId: testChannelID, UserId: testAuthorID, Type: model.PostTypeDefault, CreateAt: 100, Props: model.StringInterface{"from_bot": "true"}}, want: true},
		{name: "webhook ordinary post", state: activeAll, post: &model.Post{Id: testPostID, ChannelId: testChannelID, UserId: testAuthorID, Type: model.PostTypeDefault, CreateAt: 100, Props: model.StringInterface{"webhook": "true"}}, want: true},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			if got := EligibleAtHook(test.state, test.post); got != test.want {
				t.Fatalf("EligibleAtHook() = %v, want %v", got, test.want)
			}
		})
	}
}
