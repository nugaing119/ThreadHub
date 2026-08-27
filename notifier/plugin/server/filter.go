package server

import (
	"github.com/mattermost/mattermost/server/public/model"
	"github.com/nugaing119/ThreadHub/notifier/control"
)

// EligibleAtHook performs only the synchronous, data-minimising hook filter.
func EligibleAtHook(state control.State, post *model.Post) bool {
	if !state.Enabled || post == nil || post.Id == "" || post.ChannelId == "" || post.UserId == "" || post.DeleteAt != 0 || post.CreateAt < state.ActivatedAt || post.IsSystemMessage() {
		return false
	}
	return allowsChannel(state, post.ChannelId)
}

func allowsChannel(state control.State, channelID string) bool {
	switch state.Mode {
	case "all_channels":
		return true
	case "allowlist":
		allowed := make(map[string]struct{}, len(state.ChannelIDs))
		for _, id := range state.ChannelIDs {
			allowed[id] = struct{}{}
		}
		_, found := allowed[channelID]
		return found
	default:
		return false
	}
}
