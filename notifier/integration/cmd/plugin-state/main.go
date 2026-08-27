package main

import (
	"io"
	"os"

	"github.com/nugaing119/ThreadHub/notifier/integration/pluginstate"
)

const maxPluginListBytes = 1 << 20

type pluginState = pluginstate.State

const (
	pluginInvalid  = pluginstate.Invalid
	pluginInactive = pluginstate.Inactive
	pluginActive   = pluginstate.Active
)

func main() {
	if len(os.Args) != 3 {
		os.Exit(1)
	}
	raw, err := io.ReadAll(io.LimitReader(os.Stdin, maxPluginListBytes+1))
	if err != nil || len(raw) > maxPluginListBytes {
		os.Exit(1)
	}
	switch classifyPluginState(raw, os.Args[1], os.Args[2]) {
	case pluginActive:
		os.Exit(0)
	case pluginInactive:
		os.Exit(10)
	default:
		os.Exit(1)
	}
}

func classifyPluginState(raw []byte, pluginID, version string) pluginState {
	return pluginstate.Classify(raw, pluginID, version)
}
