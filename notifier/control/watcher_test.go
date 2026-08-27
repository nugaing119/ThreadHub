package control

import (
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestWatcherFailsClosedAndPublishesEveryControlTransition(t *testing.T) {
	path := filepath.Join(t.TempDir(), "state.json")
	watcher := NewWatcher(path, 5*time.Millisecond)
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- watcher.Run(ctx) }()
	t.Cleanup(func() {
		cancel()
		if err := <-done; err != nil {
			t.Errorf("Run() error = %v", err)
		}
	})

	waitForState(t, watcher, func(state State) bool {
		return !state.Enabled && !state.DeliveryEnabled
	})

	writeState(t, path, `{"enabled":true,"delivery_enabled":true,"mode":"all_channels","channel_ids":[],"activated_at":1000}`)
	waitForState(t, watcher, func(state State) bool {
		return state.Enabled && state.DeliveryEnabled && state.ActivatedAt == 1000
	})

	writeState(t, path, `{"enabled":false,"delivery_enabled":true,"mode":"all_channels","channel_ids":[],"activated_at":1000}`)
	waitForState(t, watcher, func(state State) bool {
		return !state.Enabled && state.DeliveryEnabled
	})

	writeState(t, path, `{invalid`)
	waitForState(t, watcher, func(state State) bool {
		return !state.Enabled && !state.DeliveryEnabled && state.Mode == ""
	})

	writeState(t, path, `{"enabled":true,"delivery_enabled":true,"mode":"all_channels","channel_ids":[],"activated_at":2000}`)
	waitForState(t, watcher, func(state State) bool {
		return state.Enabled && state.DeliveryEnabled && state.ActivatedAt == 2000
	})
}

func TestWatcherTreatsPermissionFailureAsDisabled(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("root can read mode 000 files")
	}
	path := filepath.Join(t.TempDir(), "state.json")
	writeState(t, path, `{"enabled":true,"delivery_enabled":true,"mode":"all_channels","channel_ids":[],"activated_at":1000}`)
	watcher := NewWatcher(path, 5*time.Millisecond)
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- watcher.Run(ctx) }()
	t.Cleanup(func() {
		_ = os.Chmod(path, 0o600)
		cancel()
		<-done
	})
	waitForState(t, watcher, func(state State) bool { return state.Enabled })
	if err := os.Chmod(path, 0); err != nil {
		t.Fatal(err)
	}
	waitForState(t, watcher, func(state State) bool {
		return !state.Enabled && !state.DeliveryEnabled
	})
}

func TestWatcherDoesNotDropDisableDuringRapidReactivation(t *testing.T) {
	path := filepath.Join(t.TempDir(), "state.json")
	writeState(t, path, `{"enabled":true,"delivery_enabled":true,"mode":"all_channels","channel_ids":[],"activated_at":1000}`)
	watcher := NewWatcher(path, time.Second)
	watcher.reload()

	writeState(t, path, `{"enabled":false,"delivery_enabled":false,"mode":"all_channels","channel_ids":[],"activated_at":1000}`)
	watcher.reload()
	writeState(t, path, `{"enabled":true,"delivery_enabled":true,"mode":"all_channels","channel_ids":[],"activated_at":2000}`)
	watcher.reload()

	select {
	case state := <-watcher.Changes():
		if state.Enabled || state.DeliveryEnabled {
			t.Fatalf("first unread transition = %+v, want fail-closed disable", state)
		}
	default:
		t.Fatal("Changes() did not retain the disable transition")
	}
	if current := watcher.Current(); !current.Enabled || current.ActivatedAt != 2000 {
		t.Fatalf("Current() = %+v, want latest reactivation", current)
	}
}

func writeState(t *testing.T, path, raw string) {
	t.Helper()
	temporary := path + ".new"
	if err := os.WriteFile(temporary, []byte(raw), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Rename(temporary, path); err != nil {
		t.Fatal(err)
	}
}

func waitForState(t *testing.T, watcher *Watcher, matches func(State) bool) {
	t.Helper()
	deadline := time.NewTimer(time.Second)
	defer deadline.Stop()
	for {
		state := watcher.Current()
		if matches(state) {
			return
		}
		select {
		case <-watcher.Changes():
		case <-deadline.C:
			t.Fatalf("timed out waiting for state; current = %+v", watcher.Current())
		}
	}
}
