package control

import (
	"os"
	"path/filepath"
	"testing"
)

const validChannelID = "0123456789abcdef0123456789"

func TestLoadAcceptsOnlyCompleteValidControlStates(t *testing.T) {
	tests := []struct {
		name       string
		raw        string
		wantAllows bool
	}{
		{
			name:       "active all channels",
			raw:        `{"enabled":true,"delivery_enabled":true,"mode":"all_channels","channel_ids":[],"activated_at":1787790000000}`,
			wantAllows: true,
		},
		{
			name:       "active allowlist member",
			raw:        `{"enabled":true,"delivery_enabled":true,"mode":"allowlist","channel_ids":["` + validChannelID + `"],"activated_at":1787790000000}`,
			wantAllows: true,
		},
		{
			name: "drain does not allow new channel ingest",
			raw:  `{"enabled":false,"delivery_enabled":true,"mode":"all_channels","channel_ids":[],"activated_at":1787790000000}`,
		},
		{
			name: "disabled does not allow new channel ingest",
			raw:  `{"enabled":false,"delivery_enabled":false,"mode":"all_channels","channel_ids":[],"activated_at":0}`,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			path := filepath.Join(t.TempDir(), "state.json")
			if err := os.WriteFile(path, []byte(tt.raw), 0o600); err != nil {
				t.Fatal(err)
			}
			state, err := Load(path)
			if err != nil {
				t.Fatalf("Load() error = %v", err)
			}
			if got := state.AllowsChannel(validChannelID); got != tt.wantAllows {
				t.Fatalf("AllowsChannel(valid) = %v, want %v", got, tt.wantAllows)
			}
			if state.Mode == "allowlist" && state.AllowsChannel("zyxwvutsrqponmlkjihgfedcba") {
				t.Fatal("AllowsChannel() accepted a channel outside the allowlist")
			}
		})
	}
}

func TestLoadRejectsMalformedOrUnsafeStates(t *testing.T) {
	tests := []struct {
		name string
		raw  string
	}{
		{name: "missing field", raw: `{"enabled":false}`},
		{name: "unknown field", raw: `{"enabled":false,"delivery_enabled":false,"mode":"all_channels","channel_ids":[],"activated_at":0,"extra":true}`},
		{name: "trailing document", raw: `{"enabled":false,"delivery_enabled":false,"mode":"all_channels","channel_ids":[],"activated_at":0} {}`},
		{name: "unknown mode", raw: `{"enabled":false,"delivery_enabled":false,"mode":"unknown","channel_ids":[],"activated_at":0}`},
		{name: "all channels with ids", raw: `{"enabled":true,"delivery_enabled":true,"mode":"all_channels","channel_ids":["` + validChannelID + `"],"activated_at":1}`},
		{name: "empty allowlist", raw: `{"enabled":true,"delivery_enabled":true,"mode":"allowlist","channel_ids":[],"activated_at":1}`},
		{name: "malformed channel id", raw: `{"enabled":true,"delivery_enabled":true,"mode":"allowlist","channel_ids":["channel"],"activated_at":1}`},
		{name: "duplicate channel id", raw: `{"enabled":true,"delivery_enabled":true,"mode":"allowlist","channel_ids":["` + validChannelID + `","` + validChannelID + `"],"activated_at":1}`},
		{name: "active without delivery", raw: `{"enabled":true,"delivery_enabled":false,"mode":"all_channels","channel_ids":[],"activated_at":1}`},
		{name: "active without cutoff", raw: `{"enabled":true,"delivery_enabled":true,"mode":"all_channels","channel_ids":[],"activated_at":0}`},
		{name: "negative cutoff", raw: `{"enabled":false,"delivery_enabled":false,"mode":"all_channels","channel_ids":[],"activated_at":-1}`},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			path := filepath.Join(t.TempDir(), "state.json")
			if err := os.WriteFile(path, []byte(tt.raw), 0o600); err != nil {
				t.Fatal(err)
			}
			if _, err := Load(path); err == nil {
				t.Fatal("Load() accepted invalid control state")
			}
		})
	}

	if _, err := Load(filepath.Join(t.TempDir(), "missing.json")); err == nil {
		t.Fatal("Load() accepted a missing control file")
	}
}
