package control

import (
	"context"
	"slices"
	"sync/atomic"
	"time"
)

type Watcher struct {
	path    string
	poll    time.Duration
	current atomic.Pointer[State]
	changes chan State
}

func NewWatcher(path string, poll time.Duration) *Watcher {
	if poll <= 0 {
		poll = time.Second
	}
	watcher := &Watcher{path: path, poll: poll, changes: make(chan State, 1)}
	disabled := State{}
	watcher.current.Store(&disabled)
	return watcher
}

func (w *Watcher) Run(ctx context.Context) error {
	w.reload()
	ticker := time.NewTicker(w.poll)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return nil
		case <-ticker.C:
			w.reload()
		}
	}
}

func (w *Watcher) Current() State {
	if w == nil {
		return State{}
	}
	state := w.current.Load()
	if state == nil {
		return State{}
	}
	return cloneState(*state)
}

func (w *Watcher) Changes() <-chan State {
	if w == nil {
		return nil
	}
	return w.changes
}

func (w *Watcher) reload() {
	state, err := Load(w.path)
	if err != nil {
		state = State{}
	}
	previous := w.Current()
	if equalState(previous, state) {
		return
	}
	stored := cloneState(state)
	w.current.Store(&stored)
	w.publish(cloneState(state))
}

func (w *Watcher) publish(state State) {
	select {
	case w.changes <- state:
		return
	default:
	}
	var unread State
	select {
	case unread = <-w.changes:
	default:
	}
	if moreRestrictive(unread, state) {
		state = unread
	}
	select {
	case w.changes <- state:
	default:
	}
}

func moreRestrictive(left, right State) bool {
	return !left.Enabled && right.Enabled ||
		!left.DeliveryEnabled && right.DeliveryEnabled
}

func cloneState(state State) State {
	state.ChannelIDs = append([]string(nil), state.ChannelIDs...)
	return state
}

func equalState(left, right State) bool {
	return left.Enabled == right.Enabled &&
		left.DeliveryEnabled == right.DeliveryEnabled &&
		left.Mode == right.Mode &&
		left.ActivatedAt == right.ActivatedAt &&
		slices.Equal(left.ChannelIDs, right.ChannelIDs)
}
