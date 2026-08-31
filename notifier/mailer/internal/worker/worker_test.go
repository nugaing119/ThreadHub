package worker

import (
	"bytes"
	"context"
	"errors"
	"log/slog"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/nugaing119/ThreadHub/notifier/control"
	"github.com/nugaing119/ThreadHub/notifier/mailer/internal/message"
	"github.com/nugaing119/ThreadHub/notifier/mailer/internal/smtpclient"
	storepkg "github.com/nugaing119/ThreadHub/notifier/mailer/internal/store"
	"github.com/nugaing119/ThreadHub/notifier/protocol"
)

var workerTestNow = time.Date(2026, 8, 27, 4, 0, 0, 0, time.UTC)

func TestWorkerSignalsReadyOnlyFromInsideRun(t *testing.T) {
	w := New(newFakeStore(), renderDelivery, &sequenceSender{}, newFakeControls(control.State{}), realClock{}, Config{})
	select {
	case <-w.Ready():
		t.Fatal("worker reported ready before Run entered")
	default:
	}

	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- w.Run(ctx) }()
	select {
	case <-w.Ready():
	case <-time.After(time.Second):
		t.Fatal("worker did not report readiness from Run")
	}
	cancel()
	if err := <-done; err != nil {
		t.Fatalf("Run() error = %v", err)
	}
}

func TestRetryOffsetsAreExactCumulativeSchedule(t *testing.T) {
	wants := []time.Duration{
		0,
		30 * time.Second,
		2 * time.Minute,
		10 * time.Minute,
		30 * time.Minute,
		2 * time.Hour,
		6 * time.Hour,
		24 * time.Hour,
	}
	for attempt, want := range wants {
		if got := retryOffset(attempt + 1); got != want {
			t.Errorf("retryOffset(attempt %d) = %s, want %s", attempt+1, got, want)
		}
	}
}

func TestSMTPResultsUseOnlyTemporaryFailuresForRetry(t *testing.T) {
	tests := []struct {
		name          string
		result        smtpclient.Result
		wantTemporary bool
		wantClass     string
	}{
		{name: "network", result: smtpclient.Result{Class: smtpclient.ClassTemporary}, wantTemporary: true, wantClass: "temporary"},
		{name: "timeout", result: smtpclient.Result{Class: smtpclient.ClassTimeout}, wantTemporary: true, wantClass: "timeout"},
		{name: "smtp four hundred", result: smtpclient.Result{Class: smtpclient.ClassProtocol, Code: 421}, wantTemporary: true, wantClass: "temporary"},
		{name: "smtp five hundred", result: smtpclient.Result{Class: smtpclient.ClassTemporary, Code: 550}, wantClass: "permanent"},
		{name: "protocol", result: smtpclient.Result{Class: smtpclient.ClassProtocol}, wantClass: "protocol"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			temporary, class := retryable(tt.result)
			if temporary != tt.wantTemporary || class != tt.wantClass {
				t.Fatalf("retryable(%+v) = %v, %q; want %v, %q", tt.result, temporary, class, tt.wantTemporary, tt.wantClass)
			}
		})
	}
}

func TestTemporaryFailureOnAttemptEightBecomesExhausted(t *testing.T) {
	queue, err := storepkg.Open(filepath.Join(t.TempDir(), "queue.sqlite3"), bytes.Repeat([]byte{0x42}, 32))
	if err != nil {
		t.Fatal(err)
	}
	defer queue.Close()
	event := protocol.Event{
		EventID:    "0123456789abcdef0123456789",
		PostID:     "0123456789abcdef0123456789",
		Permalink:  "https://threadhub.test/_redirect/pl/0123456789abcdef0123456789",
		OccurredAt: workerTestNow.Add(-time.Minute).UnixMilli(),
		Recipients: []protocol.Recipient{{UserID: "abcdef0123456789abcdef0123", Email: "recipient@example.test"}},
	}
	if _, err := queue.Accept(context.Background(), strings.Repeat("a", 64), event, workerTestNow); err != nil {
		t.Fatal(err)
	}
	for attempt := 1; attempt <= 7; attempt++ {
		delivery, err := queue.ClaimDue(context.Background(), workerTestNow, 2*time.Minute)
		if err != nil || delivery == nil || delivery.AttemptCount != attempt {
			t.Fatalf("ClaimDue(attempt %d) = %+v, %v", attempt, delivery, err)
		}
		if err := queue.MarkTemporary(context.Background(), delivery.Key, "temporary", 421, workerTestNow); err != nil {
			t.Fatal(err)
		}
	}

	ctx, cancel := context.WithCancel(context.Background())
	wrapped := &cancelAfterTemporaryStore{SQLiteStore: queue, cancel: cancel}
	w := New(wrapped, renderDelivery, senderFunc(func(context.Context, message.Message) smtpclient.Result {
		return smtpclient.Result{Class: smtpclient.ClassTemporary, Code: 421}
	}), newFakeControls(activeState(1000)), newManualClock(workerTestNow), Config{})
	runWorker(t, ctx, w)
	status, err := queue.Status(context.Background(), workerTestNow)
	if err != nil {
		t.Fatal(err)
	}
	if status.FailedExhausted != 1 || status.Pending != 0 || status.Sending != 0 {
		t.Fatalf("status after attempt eight = %+v, want one failed_exhausted", status)
	}
}

func TestRecipientFailureDoesNotBlockNextRecipient(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	queue := newFakeStore(delivery("first@example.test", 1), delivery("second@example.test", 1))
	queue.onMark = func() {
		if queue.markCount() == 2 {
			cancel()
		}
	}
	sender := &sequenceSender{results: []smtpclient.Result{
		{Class: smtpclient.ClassPermanent, Code: 550},
		{Accepted: true, Code: 250},
	}}
	w := New(queue, renderDelivery, sender, newFakeControls(activeState(1000)), newManualClock(workerTestNow), Config{})
	runWorker(t, ctx, w)
	if sender.callCount() != 2 || queue.permanentCount() != 1 || queue.sentCount() != 1 {
		t.Fatalf("calls/permanent/sent = %d/%d/%d, want 2/1/1", sender.callCount(), queue.permanentCount(), queue.sentCount())
	}
}

func TestTimeoutRetriesFirstRecipientAndDoesNotBlockNextRecipient(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	queue := newFakeStore(delivery("first@example.test", 1), delivery("second@example.test", 1))
	queue.onMark = func() {
		if queue.markCount() == 2 {
			cancel()
		}
	}
	sender := &sequenceSender{results: []smtpclient.Result{
		{Class: smtpclient.ClassTimeout},
		{Accepted: true, Code: 250},
	}}
	w := New(queue, renderDelivery, sender, newFakeControls(activeState(1000)), newManualClock(workerTestNow), Config{})
	runWorker(t, ctx, w)
	if sender.callCount() != 2 || queue.kindCount("temporary") != 1 || queue.sentCount() != 1 {
		t.Fatalf("calls/temporary/sent = %d/%d/%d, want 2/1/1", sender.callCount(), queue.kindCount("temporary"), queue.sentCount())
	}
}

func TestDefaultRateIsTenPerMinuteWithBurstOne(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	clock := newManualClock(workerTestNow)
	queue := newFakeStore(delivery("first@example.test", 1), delivery("second@example.test", 1))
	queue.onMark = func() {
		if queue.markCount() == 2 {
			cancel()
		}
	}
	w := New(queue, renderDelivery, &sequenceSender{}, newFakeControls(activeState(1000)), clock, Config{})
	runWorker(t, ctx, w)
	claims := queue.claimedAt()
	if len(claims) != 2 {
		t.Fatalf("claim count = %d, want 2", len(claims))
	}
	if got := claims[1].Sub(claims[0]); got != 6*time.Second {
		t.Fatalf("claim spacing = %s, want 6s", got)
	}
}

func TestRunCancellationStopsClaimsAndCancelsCurrentSMTP(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	queue := newFakeStore(delivery("recipient@example.test", 1), delivery("next@example.test", 1))
	sender := newBlockingSender()
	w := New(queue, renderDelivery, sender, newFakeControls(activeState(1000)), realClock{}, Config{})
	done := startWorker(ctx, w)
	waitSignal(t, sender.started, "SMTP start")
	cancel()
	waitSignal(t, sender.cancelled, "SMTP cancellation")
	waitRun(t, done)
	if got := queue.claimCount(); got != 1 {
		t.Fatalf("claim count = %d, want 1", got)
	}
}

func TestDisabledControlPreventsClaims(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	queue := newFakeStore(delivery("recipient@example.test", 1))
	w := New(queue, renderDelivery, &sequenceSender{}, newFakeControls(control.State{}), realClock{}, Config{})
	done := startWorker(ctx, w)
	time.Sleep(20 * time.Millisecond)
	cancel()
	waitRun(t, done)
	if got := queue.claimCount(); got != 0 {
		t.Fatalf("claim count = %d, want 0", got)
	}
}

func TestDisableCancelsInflightSMTPAndStopsFurtherClaims(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	controls := newFakeControls(activeState(1000))
	queue := newFakeStore(delivery("recipient@example.test", 1), delivery("next@example.test", 1))
	sender := newBlockingSender()
	w := New(queue, renderDelivery, sender, controls, realClock{}, Config{})
	done := startWorker(ctx, w)
	waitSignal(t, sender.started, "SMTP start")
	controls.set(control.State{})
	waitSignal(t, sender.cancelled, "SMTP cancellation")
	time.Sleep(20 * time.Millisecond)
	cancel()
	waitRun(t, done)
	if got := queue.claimCount(); got != 1 {
		t.Fatalf("claim count = %d, want 1", got)
	}
}

func TestDisableWaitsForInflightSMTPToReturnBeforeAdvancing(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	controls := newFakeControls(activeState(1000))
	queue := newFakeStore(delivery("recipient@example.test", 1))
	marked := make(chan struct{})
	queue.onMark = func() {
		close(marked)
		cancel()
	}
	sender := newTwoPhaseSender()
	w := New(queue, renderDelivery, sender, controls, realClock{}, Config{})
	done := startWorker(ctx, w)
	waitSignal(t, sender.started, "SMTP start")

	controls.set(control.State{})
	waitSignal(t, sender.cancelAcknowledged, "SMTP cancellation acknowledgement")
	select {
	case <-sender.returned:
		t.Fatal("sender returned before explicit release")
	default:
	}
	select {
	case <-marked:
		t.Fatal("worker advanced delivery state before SMTP returned")
	default:
	}

	close(sender.release)
	waitSignal(t, sender.returned, "SMTP return")
	waitSignal(t, marked, "delivery state update")
	waitRun(t, done)
}

func TestDrainContinuesPendingDelivery(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	queue := newFakeStore(delivery("recipient@example.test", 1))
	queue.onMark = cancel
	drain := control.State{Enabled: false, DeliveryEnabled: true, Mode: "all_channels", ActivatedAt: 1000}
	w := New(queue, renderDelivery, &sequenceSender{}, newFakeControls(drain), newManualClock(workerTestNow), Config{})
	runWorker(t, ctx, w)
	if queue.sentCount() != 1 {
		t.Fatalf("sent count = %d, want 1", queue.sentCount())
	}
}

func TestNewActivationCutoffResumesWorker(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	controls := newFakeControls(control.State{})
	queue := newFakeStore(delivery("recipient@example.test", 1))
	queue.onMark = cancel
	w := New(queue, renderDelivery, &sequenceSender{}, controls, realClock{}, Config{})
	done := startWorker(ctx, w)
	time.Sleep(10 * time.Millisecond)
	controls.set(activeState(2000))
	waitRun(t, done)
	if queue.sentCount() != 1 {
		t.Fatalf("sent count = %d, want 1", queue.sentCount())
	}
}

func TestExpiredLeasesRecoverAtStartupAndEveryMinute(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	clock := newManualClock(workerTestNow)
	queue := newFakeStore()
	queue.onReset = func(count int) {
		if count == 2 {
			cancel()
		}
	}
	w := New(queue, renderDelivery, &sequenceSender{}, newFakeControls(activeState(1000)), clock, Config{})
	runWorker(t, ctx, w)
	resets := queue.resetAt()
	if len(resets) != 2 {
		t.Fatalf("reset count = %d, want 2", len(resets))
	}
	if got := resets[1].Sub(resets[0]); got != time.Minute {
		t.Fatalf("reset spacing = %s, want 1m", got)
	}
}

func TestPruneRunsAtStartupAndEveryMinuteWhileDeliveryIsDisabled(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	clock := newManualClock(workerTestNow)
	queue := newFakeStore()
	queue.onPrune = func(count int) {
		if count == 2 {
			cancel()
		}
	}
	w := New(queue, renderDelivery, &sequenceSender{}, newFakeControls(control.State{}), clock, Config{})
	runWorker(t, ctx, w)
	prunes := queue.prunedAt()
	if len(prunes) != 2 {
		t.Fatalf("prune count = %d, want startup plus one periodic call", len(prunes))
	}
	if got := prunes[1].Sub(prunes[0]); got != time.Minute {
		t.Fatalf("prune spacing = %s, want 1m", got)
	}
	if got := queue.claimCount(); got != 0 {
		t.Fatalf("claim count while delivery disabled = %d, want 0", got)
	}
}

func TestPruneFailureIsSafeAndDoesNotSuppressFutureAttempts(t *testing.T) {
	const privateDetail = "private-recipient@example.test prune detail"
	var output bytes.Buffer
	previous := slog.Default()
	slog.SetDefault(slog.New(slog.NewTextHandler(&output, nil)))
	t.Cleanup(func() { slog.SetDefault(previous) })

	ctx, cancel := context.WithCancel(context.Background())
	queue := newFakeStore()
	queue.pruneErrors = []error{errors.New(privateDetail)}
	queue.onPrune = func(count int) {
		if count == 2 {
			cancel()
		}
	}
	w := New(queue, renderDelivery, &sequenceSender{}, newFakeControls(control.State{}), newManualClock(workerTestNow), Config{})
	runWorker(t, ctx, w)
	if got := len(queue.prunedAt()); got != 2 {
		t.Fatalf("prune attempts after first error = %d, want 2", got)
	}
	logText := output.String()
	if strings.Contains(logText, privateDetail) || strings.Contains(logText, "@") {
		t.Fatalf("prune log exposed private error detail: %s", logText)
	}
	for _, allowed := range []string{"queue_prune_failed", "error_class=protocol", "count=1"} {
		if !strings.Contains(logText, allowed) {
			t.Fatalf("prune log missing safe aggregate %q: %s", allowed, logText)
		}
	}
}

func TestWorkerPruneEnforcesRealStoreNonceBoundary(t *testing.T) {
	queue, err := storepkg.Open(filepath.Join(t.TempDir(), "queue.sqlite3"), bytes.Repeat([]byte{0x53}, 32))
	if err != nil {
		t.Fatal(err)
	}
	defer queue.Close()
	event := retentionEvent("0123456789abcdef0123456789", "abcdef0123456789abcdef0123", "nonce-recipient@example.test", workerTestNow)
	nonce := strings.Repeat("a", 64)
	if _, err := queue.Accept(context.Background(), nonce, event, workerTestNow); err != nil {
		t.Fatal(err)
	}

	runMaintenanceOnce(t, queue, workerTestNow.Add(10*time.Minute-time.Millisecond))
	if _, err := queue.Accept(context.Background(), nonce, event, workerTestNow.Add(10*time.Minute-time.Millisecond)); !errors.Is(err, storepkg.ErrReplay) {
		t.Fatalf("nonce before 10m boundary error = %v, want replay", err)
	}

	runMaintenanceOnce(t, queue, workerTestNow.Add(10*time.Minute))
	if result, err := queue.Accept(context.Background(), nonce, event, workerTestNow.Add(10*time.Minute)); err != nil || result.Duplicate != 1 {
		t.Fatalf("nonce at 10m boundary = %+v, %v; want accepted duplicate after prune", result, err)
	}
}

func TestWorkerPruneEnforcesRealStoreExhaustedAndTerminalBoundaries(t *testing.T) {
	queue, err := storepkg.Open(filepath.Join(t.TempDir(), "queue.sqlite3"), bytes.Repeat([]byte{0x54}, 32))
	if err != nil {
		t.Fatal(err)
	}
	defer queue.Close()
	event := retentionEvent("fedcba9876543210fedcba9876", "0123456789abcdef0123456789", "retained-recipient@example.test", workerTestNow)
	if _, err := queue.Accept(context.Background(), strings.Repeat("b", 64), event, workerTestNow); err != nil {
		t.Fatal(err)
	}
	exhaustRealDelivery(t, queue, workerTestNow)

	runMaintenanceOnce(t, queue, workerTestNow.Add(24*time.Hour-time.Millisecond))
	status, err := queue.Status(context.Background(), workerTestNow.Add(24*time.Hour-time.Millisecond))
	if err != nil || status.FailedExhausted != 1 || status.Cancelled != 0 {
		t.Fatalf("status before 24h boundary = %+v, %v", status, err)
	}

	cancelledAt := workerTestNow.Add(24 * time.Hour)
	runMaintenanceOnce(t, queue, cancelledAt)
	status, err = queue.Status(context.Background(), cancelledAt)
	if err != nil || status.FailedExhausted != 0 || status.Cancelled != 1 {
		t.Fatalf("status at 24h boundary = %+v, %v", status, err)
	}

	runMaintenanceOnce(t, queue, cancelledAt.Add(7*24*time.Hour-time.Millisecond))
	status, err = queue.Status(context.Background(), cancelledAt.Add(7*24*time.Hour-time.Millisecond))
	if err != nil || status.Cancelled != 1 {
		t.Fatalf("status before 7d boundary = %+v, %v", status, err)
	}

	runMaintenanceOnce(t, queue, cancelledAt.Add(7*24*time.Hour))
	status, err = queue.Status(context.Background(), cancelledAt.Add(7*24*time.Hour))
	if err != nil || status.Cancelled != 0 {
		t.Fatalf("status at 7d boundary = %+v, %v", status, err)
	}
}

func TestAcceptedSMTPStoreFailureCanDuplicateAfterLeaseRecovery(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	clock := newManualClock(workerTestNow)
	queue := &leaseFailureStore{cancel: cancel}
	sender := &sequenceSender{}
	w := New(queue, renderDelivery, sender, newFakeControls(activeState(1000)), clock, Config{})
	runWorker(t, ctx, w)
	if sender.callCount() != 2 {
		t.Fatalf("SMTP calls = %d, want 2 to preserve at-least-once duplicate path", sender.callCount())
	}
	claims := queue.claimedAt()
	if len(claims) != 2 || claims[1].Sub(claims[0]) < 2*time.Minute {
		t.Fatalf("claim times = %v, want retry only after two-minute lease expiry", claims)
	}
}

func TestBlankStoreEmailNeverInvokesRenderer(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	queue := newFakeStore(delivery(" \t\n", 1))
	queue.onMark = cancel
	renderCalls := 0
	sender := &sequenceSender{}
	w := New(queue, func(storepkg.Delivery) (message.Message, error) {
		renderCalls++
		return message.Message{EnvelopeTo: "recipient@example.test", Data: []byte("message")}, nil
	}, sender, newFakeControls(activeState(1000)), newManualClock(workerTestNow), Config{})
	runWorker(t, ctx, w)
	if renderCalls != 0 {
		t.Fatalf("render calls = %d, want 0", renderCalls)
	}
	if sender.callCount() != 0 {
		t.Fatalf("SMTP calls = %d, want 0", sender.callCount())
	}
}

func TestWhitespaceRenderedRecipientNeverReachesSender(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	queue := newFakeStore(delivery("recipient@example.test", 1))
	queue.onMark = cancel
	sender := &sequenceSender{}
	w := New(queue, func(storepkg.Delivery) (message.Message, error) {
		return message.Message{EnvelopeFrom: "sender@example.test", EnvelopeTo: " \t\n", Data: []byte("message")}, nil
	}, sender, newFakeControls(activeState(1000)), newManualClock(workerTestNow), Config{})
	runWorker(t, ctx, w)
	if sender.callCount() != 0 {
		t.Fatalf("SMTP calls = %d, want 0", sender.callCount())
	}
	if queue.permanentCount() != 1 {
		t.Fatalf("permanent count = %d, want 1", queue.permanentCount())
	}
}

func TestEmptyEmailNeverReachesSenderAndLogsContainOnlySafeAggregates(t *testing.T) {
	var output bytes.Buffer
	previous := slog.Default()
	slog.SetDefault(slog.New(slog.NewTextHandler(&output, nil)))
	t.Cleanup(func() { slog.SetDefault(previous) })

	ctx, cancel := context.WithCancel(context.Background())
	d := delivery("", 1)
	d.Key.EventHash = "sensitive-event-hash"
	d.Key.RecipientHash = "sensitive-recipient-hash"
	d.Permalink = "https://threadhub.test/_redirect/pl/sensitive-post-id"
	queue := newFakeStore(d)
	queue.onMark = cancel
	sender := &sequenceSender{}
	w := New(queue, renderDelivery, sender, newFakeControls(activeState(1000)), newManualClock(workerTestNow), Config{})
	runWorker(t, ctx, w)
	if sender.callCount() != 0 {
		t.Fatalf("SMTP calls = %d, want 0", sender.callCount())
	}
	logText := output.String()
	for _, forbidden := range []string{"sensitive-event-hash", "sensitive-recipient-hash", "sensitive-post-id", "@"} {
		if strings.Contains(logText, forbidden) {
			t.Fatalf("log contains forbidden value %q: %s", forbidden, logText)
		}
	}
	for _, allowed := range []string{"error_class", "smtp_code", "count"} {
		if !strings.Contains(logText, allowed) {
			t.Fatalf("log missing safe aggregate %q: %s", allowed, logText)
		}
	}
}

func activeState(cutoff int64) control.State {
	return control.State{Enabled: true, DeliveryEnabled: true, Mode: "all_channels", ActivatedAt: cutoff}
}

func delivery(email string, attempt int) storepkg.Delivery {
	return storepkg.Delivery{
		Key:          storepkg.DeliveryKey{EventHash: "event-hash", RecipientHash: "recipient-hash"},
		Email:        email,
		Permalink:    "https://threadhub.test/_redirect/pl/0123456789abcdef0123456789",
		AttemptCount: attempt,
		AcceptedAt:   workerTestNow,
		OccurredAt:   workerTestNow.Add(-time.Minute),
	}
}

func renderDelivery(d storepkg.Delivery) (message.Message, error) {
	return message.Message{EnvelopeFrom: "sender@example.test", EnvelopeTo: d.Email, Data: []byte("message")}, nil
}

type senderFunc func(context.Context, message.Message) smtpclient.Result

func (f senderFunc) Send(ctx context.Context, msg message.Message) smtpclient.Result {
	return f(ctx, msg)
}

type sequenceSender struct {
	mu      sync.Mutex
	results []smtpclient.Result
	calls   int
}

func (s *sequenceSender) Send(context.Context, message.Message) smtpclient.Result {
	s.mu.Lock()
	defer s.mu.Unlock()
	result := smtpclient.Result{Accepted: true, Code: 250}
	if s.calls < len(s.results) {
		result = s.results[s.calls]
	}
	s.calls++
	return result
}

func (s *sequenceSender) callCount() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.calls
}

type blockingSender struct {
	started   chan struct{}
	cancelled chan struct{}
	onceStart sync.Once
	onceStop  sync.Once
}

type twoPhaseSender struct {
	started            chan struct{}
	cancelAcknowledged chan struct{}
	release            chan struct{}
	returned           chan struct{}
}

func newTwoPhaseSender() *twoPhaseSender {
	return &twoPhaseSender{
		started:            make(chan struct{}),
		cancelAcknowledged: make(chan struct{}),
		release:            make(chan struct{}),
		returned:           make(chan struct{}),
	}
}

func (s *twoPhaseSender) Send(ctx context.Context, _ message.Message) smtpclient.Result {
	close(s.started)
	<-ctx.Done()
	close(s.cancelAcknowledged)
	<-s.release
	close(s.returned)
	return smtpclient.Result{Class: smtpclient.ClassTemporary}
}

func newBlockingSender() *blockingSender {
	return &blockingSender{started: make(chan struct{}), cancelled: make(chan struct{})}
}

func (s *blockingSender) Send(ctx context.Context, _ message.Message) smtpclient.Result {
	s.onceStart.Do(func() { close(s.started) })
	<-ctx.Done()
	s.onceStop.Do(func() { close(s.cancelled) })
	return smtpclient.Result{Class: smtpclient.ClassTemporary}
}

type fakeControls struct {
	mu      sync.RWMutex
	current control.State
	changes chan control.State
}

func newFakeControls(state control.State) *fakeControls {
	return &fakeControls{current: state, changes: make(chan control.State, 8)}
}

func (c *fakeControls) Current() control.State {
	c.mu.RLock()
	defer c.mu.RUnlock()
	return c.current
}

func (c *fakeControls) Changes() <-chan control.State { return c.changes }

func (c *fakeControls) set(state control.State) {
	c.mu.Lock()
	c.current = state
	c.mu.Unlock()
	c.changes <- state
}

type manualClock struct {
	mu    sync.Mutex
	now   time.Time
	waits []time.Duration
}

func newManualClock(now time.Time) *manualClock { return &manualClock{now: now} }

func (c *manualClock) Now() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.now
}

func (c *manualClock) Wait(ctx context.Context, duration time.Duration) error {
	select {
	case <-ctx.Done():
		return ctx.Err()
	default:
	}
	c.mu.Lock()
	c.now = c.now.Add(duration)
	c.waits = append(c.waits, duration)
	c.mu.Unlock()
	return nil
}

type realClock struct{}

func (realClock) Now() time.Time { return time.Now() }
func (realClock) Wait(ctx context.Context, duration time.Duration) error {
	timer := time.NewTimer(duration)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-timer.C:
		return nil
	}
}

type markRecord struct {
	kind  string
	next  time.Time
	class string
	code  int
}

type fakeStore struct {
	mu          sync.Mutex
	deliveries  []storepkg.Delivery
	claims      []time.Time
	marks       []markRecord
	resets      []time.Time
	prunes      []time.Time
	pruneErrors []error
	onMark      func()
	onReset     func(int)
	onPrune     func(int)
}

func newFakeStore(deliveries ...storepkg.Delivery) *fakeStore {
	return &fakeStore{deliveries: append([]storepkg.Delivery(nil), deliveries...)}
}

func (s *fakeStore) ClaimDue(_ context.Context, now time.Time, _ time.Duration) (*storepkg.Delivery, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if len(s.deliveries) == 0 {
		return nil, nil
	}
	d := s.deliveries[0]
	s.deliveries = s.deliveries[1:]
	s.claims = append(s.claims, now)
	return &d, nil
}

func (s *fakeStore) MarkSent(context.Context, storepkg.DeliveryKey, time.Time) error {
	return s.mark(markRecord{kind: "sent"})
}

func (s *fakeStore) MarkTemporary(_ context.Context, _ storepkg.DeliveryKey, class string, code int, next time.Time) error {
	return s.mark(markRecord{kind: "temporary", class: class, code: code, next: next})
}

func (s *fakeStore) MarkPermanent(_ context.Context, _ storepkg.DeliveryKey, class string, code int, _ time.Time) error {
	return s.mark(markRecord{kind: "permanent", class: class, code: code})
}

func (s *fakeStore) mark(record markRecord) error {
	s.mu.Lock()
	s.marks = append(s.marks, record)
	callback := s.onMark
	s.mu.Unlock()
	if callback != nil {
		callback()
	}
	return nil
}

func (s *fakeStore) ResetExpiredLeases(_ context.Context, now time.Time) (int64, error) {
	s.mu.Lock()
	s.resets = append(s.resets, now)
	count := len(s.resets)
	callback := s.onReset
	s.mu.Unlock()
	if callback != nil {
		callback(count)
	}
	return 0, nil
}

func (s *fakeStore) Prune(_ context.Context, now time.Time) (storepkg.PruneResult, error) {
	s.mu.Lock()
	s.prunes = append(s.prunes, now)
	count := len(s.prunes)
	var err error
	if count <= len(s.pruneErrors) {
		err = s.pruneErrors[count-1]
	}
	callback := s.onPrune
	s.mu.Unlock()
	if callback != nil {
		callback(count)
	}
	return storepkg.PruneResult{}, err
}

func (s *fakeStore) markCount() int  { s.mu.Lock(); defer s.mu.Unlock(); return len(s.marks) }
func (s *fakeStore) claimCount() int { s.mu.Lock(); defer s.mu.Unlock(); return len(s.claims) }
func (s *fakeStore) claimedAt() []time.Time {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]time.Time(nil), s.claims...)
}
func (s *fakeStore) resetAt() []time.Time {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]time.Time(nil), s.resets...)
}
func (s *fakeStore) prunedAt() []time.Time {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]time.Time(nil), s.prunes...)
}
func (s *fakeStore) sentCount() int      { return s.kindCount("sent") }
func (s *fakeStore) permanentCount() int { return s.kindCount("permanent") }
func (s *fakeStore) kindCount(kind string) int {
	s.mu.Lock()
	defer s.mu.Unlock()
	count := 0
	for _, mark := range s.marks {
		if mark.kind == kind {
			count++
		}
	}
	return count
}

type cancelAfterTemporaryStore struct {
	*storepkg.SQLiteStore
	cancel context.CancelFunc
}

func (s *cancelAfterTemporaryStore) MarkTemporary(ctx context.Context, key storepkg.DeliveryKey, class string, code int, next time.Time) error {
	err := s.SQLiteStore.MarkTemporary(ctx, key, class, code, next)
	s.cancel()
	return err
}

type leaseFailureStore struct {
	mu         sync.Mutex
	status     string
	leaseUntil time.Time
	claims     []time.Time
	markCalls  int
	cancel     context.CancelFunc
}

func (s *leaseFailureStore) ClaimDue(_ context.Context, now time.Time, lease time.Duration) (*storepkg.Delivery, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.status == "sent" || s.status == "sending" {
		return nil, nil
	}
	s.status = "sending"
	s.leaseUntil = now.Add(lease)
	s.claims = append(s.claims, now)
	d := delivery("recipient@example.test", len(s.claims))
	return &d, nil
}

func (s *leaseFailureStore) MarkSent(context.Context, storepkg.DeliveryKey, time.Time) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.markCalls++
	if s.markCalls == 1 {
		return errors.New("fixture commit failure")
	}
	s.status = "sent"
	s.cancel()
	return nil
}

func (s *leaseFailureStore) MarkTemporary(context.Context, storepkg.DeliveryKey, string, int, time.Time) error {
	return nil
}
func (s *leaseFailureStore) MarkPermanent(context.Context, storepkg.DeliveryKey, string, int, time.Time) error {
	return nil
}
func (s *leaseFailureStore) ResetExpiredLeases(_ context.Context, now time.Time) (int64, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.status == "sending" && !now.Before(s.leaseUntil) {
		s.status = "pending"
		return 1, nil
	}
	return 0, nil
}
func (s *leaseFailureStore) Prune(context.Context, time.Time) (storepkg.PruneResult, error) {
	return storepkg.PruneResult{}, nil
}
func (s *leaseFailureStore) claimedAt() []time.Time {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]time.Time(nil), s.claims...)
}

func startWorker(ctx context.Context, worker *Worker) <-chan error {
	done := make(chan error, 1)
	go func() { done <- worker.Run(ctx) }()
	return done
}

func runWorker(t *testing.T, ctx context.Context, worker *Worker) {
	t.Helper()
	waitRun(t, startWorker(ctx, worker))
}

func waitRun(t *testing.T, done <-chan error) {
	t.Helper()
	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("Run() error = %v", err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("timed out waiting for worker")
	}
}

func waitSignal(t *testing.T, signal <-chan struct{}, name string) {
	t.Helper()
	select {
	case <-signal:
	case <-time.After(time.Second):
		t.Fatalf("timed out waiting for %s", name)
	}
}

type cancelAfterPruneStore struct {
	*storepkg.SQLiteStore
	cancel context.CancelFunc
}

func (s *cancelAfterPruneStore) Prune(ctx context.Context, now time.Time) (storepkg.PruneResult, error) {
	result, err := s.SQLiteStore.Prune(ctx, now)
	s.cancel()
	return result, err
}

func runMaintenanceOnce(t *testing.T, queue *storepkg.SQLiteStore, now time.Time) {
	t.Helper()
	ctx, cancel := context.WithCancel(context.Background())
	wrapped := &cancelAfterPruneStore{SQLiteStore: queue, cancel: cancel}
	w := New(wrapped, renderDelivery, &sequenceSender{}, newFakeControls(control.State{}), newManualClock(now), Config{})
	runWorker(t, ctx, w)
}

func retentionEvent(postID, userID, email string, acceptedAt time.Time) protocol.Event {
	return protocol.Event{
		EventID: postID, PostID: postID,
		Permalink:  "https://threadhub.test/_redirect/pl/" + postID,
		OccurredAt: acceptedAt.Add(-time.Minute).UnixMilli(),
		Recipients: []protocol.Recipient{{UserID: userID, Email: email}},
	}
}

func exhaustRealDelivery(t *testing.T, queue *storepkg.SQLiteStore, now time.Time) {
	t.Helper()
	for attempt := 1; attempt <= 8; attempt++ {
		delivery, err := queue.ClaimDue(context.Background(), now, 2*time.Minute)
		if err != nil || delivery == nil || delivery.AttemptCount != attempt {
			t.Fatalf("ClaimDue(attempt %d) = %+v, %v", attempt, delivery, err)
		}
		if err := queue.MarkTemporary(context.Background(), delivery.Key, "temporary", 421, now); err != nil {
			t.Fatalf("MarkTemporary(attempt %d) error = %v", attempt, err)
		}
	}
}
