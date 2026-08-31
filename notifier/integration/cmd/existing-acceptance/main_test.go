package main

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestAcceptanceFailurePhaseIsSafeAndBounded(t *testing.T) {
	t.Parallel()

	for _, test := range []struct {
		name string
		err  error
		want string
	}{
		{name: "known", err: phaseError("public-root", errors.New("private upstream detail")), want: "public-root"},
		{name: "unknown phase", err: phaseError("private-value", errors.New("private upstream detail")), want: "unavailable"},
		{name: "plain error", err: errors.New("private upstream detail"), want: "unavailable"},
	} {
		test := test
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			if got := safeFailurePhase(test.err); got != test.want {
				t.Fatalf("safeFailurePhase() = %q, want %q", got, test.want)
			}
		})
	}
}

func TestStateRoundTripContainsOnlySchemaAndMattermostIDs(t *testing.T) {
	directory := t.TempDir()
	path := filepath.Join(directory, "state.json")
	want := state{
		Schema: 1, TeamID: strings.Repeat("a", 26), PublicChannelID: strings.Repeat("b", 26),
		PrivateChannelID: strings.Repeat("c", 26), ExcludedChannelID: strings.Repeat("d", 26),
		DirectChannelID: strings.Repeat("e", 26), SystemUserID: strings.Repeat("f", 26),
		BaselinePostID: strings.Repeat("g", 26),
	}
	if err := writeJSON(path, want); err != nil {
		t.Fatal(err)
	}
	got, err := readState(path)
	if err != nil {
		t.Fatal(err)
	}
	if got != want {
		t.Fatalf("state round trip = %#v, want %#v", got, want)
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	for _, forbidden := range []string{"@", "password", "secret", "message", "channel_name", "team_name"} {
		if strings.Contains(string(raw), forbidden) {
			t.Fatalf("state contains forbidden field or value %q", forbidden)
		}
	}
}

func TestReadJSONRejectsLooseModeAndUnknownFields(t *testing.T) {
	path := filepath.Join(t.TempDir(), "state.json")
	if err := os.WriteFile(path, []byte(`{"schema":1,"unexpected":true}`), 0o644); err != nil {
		t.Fatal(err)
	}
	var value state
	if err := readJSON(path, &value); err == nil {
		t.Fatal("readJSON accepted a world-readable state file")
	}
	if err := os.Chmod(path, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := readJSON(path, &value); err == nil {
		t.Fatal("readJSON accepted an unknown field")
	}
}

func TestCaptureCountsUsesOnlyRecipientHashes(t *testing.T) {
	snapshot := captureSnapshot{Captures: []capture{
		{RecipientHash: strings.Repeat("a", 64), EnvelopeCount: 2, GenericContent: true, LastAttemptMS: 1},
		{RecipientHash: strings.Repeat("b", 64), EnvelopeCount: 5, GenericContent: true, LastAttemptMS: 2},
	}}
	counts := captureCounts(snapshot)
	if len(counts) != 2 || counts[strings.Repeat("a", 64)] != 2 || counts[strings.Repeat("b", 64)] != 5 {
		t.Fatalf("capture counts = %#v", counts)
	}
}
