package main

import (
	"github.com/mattermost/mattermost/server/public/plugin"
	"github.com/nugaing119/ThreadHub/notifier/plugin/server"
)

func main() {
	plugin.ClientMain(server.New())
}
