package server

import (
	"errors"
	"sort"

	"github.com/mattermost/mattermost/server/public/model"
	"github.com/nugaing119/ThreadHub/notifier/protocol"
)

const recipientPageSize = 200

var ErrRecipientLimit = errors.New("recipient limit exceeded")

type RecipientResolver struct {
	api MattermostAPI
}

func NewRecipientResolver(api MattermostAPI) *RecipientResolver {
	return &RecipientResolver{api: api}
}

func (r *RecipientResolver) Resolve(event OutboxEvent) ([]protocol.Recipient, error) {
	channel, appErr := r.api.GetChannel(event.ChannelID)
	if appErr != nil {
		return nil, appError("get channel failed", appErr)
	}
	if channel == nil {
		return nil, errors.New("get channel failed")
	}
	if channel.Type != model.ChannelTypeOpen && channel.Type != model.ChannelTypePrivate {
		return nil, nil
	}

	memberIDs := make(map[string]struct{})
	for page := 0; ; page++ {
		members, appErr := r.api.GetChannelMembers(event.ChannelID, page, recipientPageSize)
		if appErr != nil {
			return nil, appError("get channel members failed", appErr)
		}
		for _, member := range members {
			if member.UserId != "" {
				memberIDs[member.UserId] = struct{}{}
			}
		}
		if len(members) < recipientPageSize {
			break
		}
	}

	userIDs := make([]string, 0, len(memberIDs))
	for userID := range memberIDs {
		userIDs = append(userIDs, userID)
	}
	sort.Strings(userIDs)

	eligible := make(map[string]protocol.Recipient)
	for start := 0; start < len(userIDs); start += recipientPageSize {
		end := min(start+recipientPageSize, len(userIDs))
		users, appErr := r.api.GetUsersByIds(userIDs[start:end])
		if appErr != nil {
			return nil, appError("get channel users failed", appErr)
		}
		for _, user := range users {
			if eligibleRecipient(event.AuthorUserID, user) {
				eligible[user.Id] = protocol.Recipient{UserID: user.Id, Email: user.Email}
			}
		}
	}

	if len(eligible) > 250 {
		return nil, ErrRecipientLimit
	}
	recipients := make([]protocol.Recipient, 0, len(eligible))
	for _, recipient := range eligible {
		recipients = append(recipients, recipient)
	}
	sort.Slice(recipients, func(i, j int) bool {
		return recipients[i].UserID < recipients[j].UserID
	})
	return recipients, nil
}

func eligibleRecipient(authorID string, user *model.User) bool {
	return user != nil && user.Id != authorID && user.DeleteAt == 0 &&
		!user.IsBot && user.EmailVerified && user.Email != ""
}
