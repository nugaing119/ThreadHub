package server

import "github.com/mattermost/mattermost/server/public/plugin"

// This assertion pins the narrow adapter to the exact Mattermost public API
// dependency used by this module.
var _ MattermostAPI = plugin.API(nil)
