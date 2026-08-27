package server

import "github.com/nugaing119/ThreadHub/notifier/control"

// Control provides the plugin with a fail-closed snapshot of shared runtime state.
type Control struct {
	watcher *control.Watcher
}

func NewControl(watcher *control.Watcher) *Control {
	return &Control{watcher: watcher}
}

func (c *Control) Current() control.State {
	if c == nil || c.watcher == nil {
		return control.State{}
	}
	return c.watcher.Current()
}
