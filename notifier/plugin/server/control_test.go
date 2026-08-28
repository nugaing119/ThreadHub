package server

import (
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/nugaing119/ThreadHub/notifier/control"
)

func TestControlSnapshotDoesNotRetainEnabledStateAfterControlBecomesInvalid(t *testing.T) {
	path := filepath.Join(t.TempDir(), "state.json")
	if err := os.WriteFile(path, []byte(`{"enabled":true,"delivery_enabled":true,"mode":"all_channels","channel_ids":[],"activated_at":1}`), 0o600); err != nil {
		t.Fatal(err)
	}
	w := control.NewWatcher(path, time.Millisecond)
	ctx, cancel := context.WithCancel(t.Context())
	defer cancel()
	go func() { _ = w.Run(ctx) }()
	<-w.Ready()

	controls := NewControl(w)
	if !controls.Current().Enabled {
		t.Fatal("Current() disabled a valid active state")
	}
	if err := os.WriteFile(path, []byte(`{`), 0o600); err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(time.Second)
	for controls.Current().Enabled && time.Now().Before(deadline) {
		time.Sleep(time.Millisecond)
	}
	if controls.Current().Enabled {
		t.Fatal("Current() retained the last valid enabled state after invalid control")
	}
}

func TestControlSnapshotNilWatcherIsDisabled(t *testing.T) {
	if NewControl(nil).Current().Enabled {
		t.Fatal("Current() enabled a nil watcher")
	}
}
