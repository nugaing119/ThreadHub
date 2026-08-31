package main

import (
	"context"
	"errors"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/nugaing119/ThreadHub/notifier/protocol"
)

type roundTripFunc func(*http.Request) (*http.Response, error)

func (fn roundTripFunc) RoundTrip(request *http.Request) (*http.Response, error) {
	return fn(request)
}

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

func TestDeliveryDeltaFailureReasonIsSafeAndBounded(t *testing.T) {
	t.Parallel()

	for _, test := range []struct {
		name string
		err  error
		want string
	}{
		{name: "known", err: phaseError("delivery-delta", &deliveryDeltaError{reason: "no-deliveries"}), want: "no-deliveries"},
		{name: "unknown reason", err: phaseError("delivery-delta", &deliveryDeltaError{reason: "private-value"}), want: "unavailable"},
		{name: "plain error", err: errors.New("private upstream detail"), want: "unavailable"},
	} {
		test := test
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			if got := safeFailureReason(test.err); got != test.want {
				t.Fatalf("safeFailureReason() = %q, want %q", got, test.want)
			}
		})
	}
}

func TestDeliveryDeltaReasonClassifiesSafeAggregateState(t *testing.T) {
	t.Parallel()

	hashA := strings.Repeat("a", 64)
	hashB := strings.Repeat("b", 64)
	before := captureSnapshot{Captures: []capture{{RecipientHash: hashA, EnvelopeCount: 1, LastAttemptMS: 1}}}
	expected := map[string]int{hashA: 2, hashB: 1}
	for _, test := range []struct {
		name  string
		after *captureSnapshot
		want  string
	}{
		{name: "capture unavailable", after: nil, want: "capture-unavailable"},
		{name: "no deliveries", after: &captureSnapshot{Captures: []capture{{RecipientHash: hashA, EnvelopeCount: 1, LastAttemptMS: 1}}}, want: "no-deliveries"},
		{name: "count mismatch", after: &captureSnapshot{Captures: []capture{{RecipientHash: hashA, EnvelopeCount: 2, GenericContent: true, LastAttemptMS: 2}}}, want: "count-mismatch"},
		{name: "content mismatch", after: &captureSnapshot{Captures: []capture{
			{RecipientHash: hashA, EnvelopeCount: 3, GenericContent: true, LastAttemptMS: 2},
			{RecipientHash: hashB, EnvelopeCount: 1, GenericContent: false, LastAttemptMS: 2},
		}}, want: "content-mismatch"},
	} {
		test := test
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			if got := deliveryDeltaReason(before, test.after, expected); got != test.want {
				t.Fatalf("deliveryDeltaReason() = %q, want %q", got, test.want)
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

func TestGetCapturesAcceptsNonGenericSMTPAcceptanceBaseline(t *testing.T) {
	t.Parallel()

	wantHash := strings.Repeat("a", 64)
	c := &client{http: &http.Client{Transport: roundTripFunc(func(request *http.Request) (*http.Response, error) {
		if request.Method != http.MethodGet || request.URL.String() != captureURL+"/v1/captures" {
			t.Fatalf("unexpected capture request: %s %s", request.Method, request.URL)
		}
		return &http.Response{
			StatusCode: http.StatusOK,
			Body: io.NopCloser(strings.NewReader(`{"captures":[{"recipient_hash":"` + wantHash +
				`","envelope_count":1,"generic_content":false,"last_attempt_at_ms":1}]}`)),
			Header: make(http.Header),
		}, nil
	})}}

	snapshot, err := getCaptures(context.Background(), c)
	if err != nil {
		t.Fatalf("getCaptures() rejected a structurally valid SMTP acceptance baseline: %v", err)
	}
	if len(snapshot.Captures) != 1 || snapshot.Captures[0].RecipientHash != wantHash || snapshot.Captures[0].GenericContent {
		t.Fatalf("getCaptures() = %#v, want preserved non-generic SMTP acceptance capture", snapshot)
	}
}

func TestWaitDeltaRejectsNonGenericNotification(t *testing.T) {
	t.Parallel()

	secret := []byte("0123456789abcdef0123456789abcdef")
	recipient := "recipient@integration.invalid"
	recipientHash := protocol.HashIdentifier(secret, "integration-recipient", recipient)
	c := &client{http: &http.Client{Transport: roundTripFunc(func(*http.Request) (*http.Response, error) {
		return &http.Response{
			StatusCode: http.StatusOK,
			Body: io.NopCloser(strings.NewReader(`{"captures":[{"recipient_hash":"` + recipientHash +
				`","envelope_count":1,"generic_content":false,"last_attempt_at_ms":1}]}`)),
			Header: make(http.Header),
		}, nil
	})}}

	err := waitDelta(context.Background(), c, secret, captureSnapshot{Captures: []capture{}}, map[string]int{recipient: 1}, 5*time.Millisecond)
	if err == nil {
		t.Fatal("waitDelta() accepted a non-generic notification delivery")
	}
}
