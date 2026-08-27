package server

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"os"
	"reflect"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/mattermost/mattermost/server/public/model"
	"github.com/mattermost/mattermost/server/public/plugin"
	"github.com/nugaing119/ThreadHub/notifier/control"
	"github.com/nugaing119/ThreadHub/notifier/protocol"
)

func TestPluginActivationRejectsInvalidConfigurationBeforeStartingBackgroundWork(t *testing.T) {
	var builds atomic.Int32
	p := newPlugin(pluginOptions{
		getenv: func(string) string { return "" },
		api:    newFakeMattermostAPI(),
		buildRuntime: func(Config, MattermostAPI, errorClassLogger) (runtimeComponents, error) {
			builds.Add(1)
			return runtimeComponents{}, nil
		},
	})

	if err := p.OnActivate(); err == nil {
		t.Fatal("OnActivate() error = nil, want invalid configuration rejection")
	}
	if builds.Load() != 0 {
		t.Fatalf("runtime builds = %d, want 0 before configuration validation", builds.Load())
	}
	if err := p.OnDeactivate(); err != nil {
		t.Fatalf("OnDeactivate() after failed activation error = %v", err)
	}
}

func TestPluginActivationFailureLeavesNoControlOrWorkerGoroutine(t *testing.T) {
	controls := newTestRuntimeControls(activeControlState(1))
	p := newPlugin(pluginOptions{
		getenv: testConfigEnvironment,
		api:    newFakeMattermostAPI(),
		buildRuntime: func(Config, MattermostAPI, errorClassLogger) (runtimeComponents, error) {
			return runtimeComponents{controls: controls}, errors.New("runtime unavailable")
		},
	})

	if err := p.OnActivate(); err == nil {
		t.Fatal("OnActivate() error = nil, want runtime construction failure")
	}
	if got := controls.runs.Load(); got != 0 {
		t.Fatalf("control Run() calls = %d, want 0", got)
	}
}

func TestPluginLifecycleStartsOneControlReloaderAndOneWorkerThenJoinsThem(t *testing.T) {
	controls := newTestRuntimeControls(activeControlState(1))
	queue := newTestRuntimeOutbox()
	p := newPlugin(pluginOptions{
		getenv:          testConfigEnvironment,
		api:             newFakeMattermostAPI(),
		shutdownTimeout: time.Second,
		buildRuntime: func(Config, MattermostAPI, errorClassLogger) (runtimeComponents, error) {
			return runtimeComponents{
				controls: controls,
				outbox:   queue,
				recipients: recipientResolverFunc(func(OutboxEvent) ([]protocol.Recipient, error) {
					return nil, nil
				}),
				mailer: mailerEnqueuerFunc(func(context.Context, OutboxEvent, []protocol.Recipient) error {
					return nil
				}),
				logger: &testErrorLogger{},
			}, nil
		},
	})

	if err := p.OnActivate(); err != nil {
		t.Fatalf("OnActivate() error = %v", err)
	}
	waitForSignal(t, controls.started, "control reloader start")
	waitForSignal(t, queue.listed, "outbox worker first poll")
	if err := p.OnActivate(); !errors.Is(err, ErrPluginAlreadyActive) {
		t.Fatalf("second OnActivate() error = %v, want ErrPluginAlreadyActive", err)
	}
	if got := controls.runs.Load(); got != 1 {
		t.Fatalf("control Run() calls = %d, want exactly 1", got)
	}

	if err := p.OnDeactivate(); err != nil {
		t.Fatalf("OnDeactivate() error = %v", err)
	}
	if !controls.stopped.Load() {
		t.Fatal("OnDeactivate() returned before the control reloader stopped")
	}
	listCalls := queue.listCalls.Load()
	p.MessageHasBeenPosted(nil, eligibleTestPost())
	if got := queue.putCalls.Load(); got != 0 {
		t.Fatalf("hook writes after deactivation = %d, want 0", got)
	}
	if got := queue.listCalls.Load(); got != listCalls {
		t.Fatalf("worker polls after bounded join = %d, want unchanged %d", got, listCalls)
	}
	if err := p.OnDeactivate(); err != nil {
		t.Fatalf("second OnDeactivate() error = %v", err)
	}
}

func TestPluginDeactivationUsesABoundedJoin(t *testing.T) {
	controls := newTestRuntimeControls(activeControlState(1))
	controls.ignoreCancellation = true
	p := newPlugin(pluginOptions{
		getenv:          testConfigEnvironment,
		api:             newFakeMattermostAPI(),
		shutdownTimeout: 20 * time.Millisecond,
		buildRuntime: func(Config, MattermostAPI, errorClassLogger) (runtimeComponents, error) {
			return runtimeComponents{
				controls:   controls,
				outbox:     newTestRuntimeOutbox(),
				recipients: recipientResolverFunc(func(OutboxEvent) ([]protocol.Recipient, error) { return nil, nil }),
				mailer:     mailerEnqueuerFunc(func(context.Context, OutboxEvent, []protocol.Recipient) error { return nil }),
				logger:     &testErrorLogger{},
			}, nil
		},
	})
	if err := p.OnActivate(); err != nil {
		t.Fatalf("OnActivate() error = %v", err)
	}
	waitForSignal(t, controls.started, "control reloader start")
	started := time.Now()
	if err := p.OnDeactivate(); !errors.Is(err, ErrPluginShutdownTimeout) {
		t.Fatalf("OnDeactivate() error = %v, want ErrPluginShutdownTimeout", err)
	}
	if elapsed := time.Since(started); elapsed > 250*time.Millisecond {
		t.Fatalf("OnDeactivate() elapsed = %s, want bounded return", elapsed)
	}
	close(controls.release)
}

func TestPluginHookIsPureFastAndSerializesOnlyMinimalPostMetadata(t *testing.T) {
	controls := newTestRuntimeControls(activeControlState(1))
	queue := newTestRuntimeOutbox()
	var recipientCalls atomic.Int32
	var mailerCalls atomic.Int32
	p := activateTestPlugin(t, controls, queue,
		recipientResolverFunc(func(OutboxEvent) ([]protocol.Recipient, error) {
			recipientCalls.Add(1)
			return nil, nil
		}),
		mailerEnqueuerFunc(func(context.Context, OutboxEvent, []protocol.Recipient) error {
			mailerCalls.Add(1)
			return nil
		}),
		&testErrorLogger{},
	)
	deactivateAtCleanup(t, p)

	post := eligibleTestPost()
	post.Message = "SENTINEL message body"
	post.Props = model.StringInterface{"secret": "SENTINEL property"}
	post.FileIds = []string{"SENTINEL filename"}
	p.MessageHasBeenPosted(&plugin.Context{}, post)

	events := queue.putEventsSnapshot()
	if len(events) != 1 || events[0] != (OutboxEvent{PostID: testPostID, ChannelID: testChannelID, AuthorUserID: testAuthorID, CreateAt: 100}) {
		t.Fatalf("hook outbox events = %#v, want one minimal projection", events)
	}
	encoded, err := json.Marshal(events[0])
	if err != nil {
		t.Fatal(err)
	}
	for _, forbidden := range []string{"SENTINEL", "message", "props", "filename"} {
		if bytes.Contains(bytes.ToLower(encoded), bytes.ToLower([]byte(forbidden))) {
			t.Fatalf("hook outbox payload exposed forbidden %q", forbidden)
		}
	}
	if got := recipientCalls.Load(); got != 0 {
		t.Fatalf("hook recipient/channel/user calls = %d, want 0", got)
	}
	if got := mailerCalls.Load(); got != 0 {
		t.Fatalf("hook HTTP/SMTP calls = %d, want 0", got)
	}
}

func TestPluginHookKVFailureCannotRejectTheCommittedPost(t *testing.T) {
	controls := newTestRuntimeControls(activeControlState(1))
	queue := newTestRuntimeOutbox()
	queue.putErr = errors.New("recipient@example.test raw private data")
	logger := &testErrorLogger{}
	p := activateTestPlugin(t, controls, queue,
		recipientResolverFunc(func(OutboxEvent) ([]protocol.Recipient, error) { return nil, nil }),
		mailerEnqueuerFunc(func(context.Context, OutboxEvent, []protocol.Recipient) error { return nil }),
		logger,
	)
	deactivateAtCleanup(t, p)

	p.MessageHasBeenPosted(nil, eligibleTestPost())
	if got, want := logger.classesSnapshot(), []string{"outbox_write"}; !reflect.DeepEqual(got, want) {
		t.Fatalf("safe error classes = %v, want %v", got, want)
	}
	if strings.Contains(strings.Join(logger.classesSnapshot(), " "), "recipient@example.test") {
		t.Fatal("hook logger exposed the KV error detail")
	}
}

func TestPluginHookAndDeactivationAreSafeWhenConcurrent(t *testing.T) {
	controls := newTestRuntimeControls(activeControlState(1))
	queue := newTestRuntimeOutbox()
	p := activateTestPlugin(t, controls, queue,
		recipientResolverFunc(func(OutboxEvent) ([]protocol.Recipient, error) { return nil, nil }),
		mailerEnqueuerFunc(func(context.Context, OutboxEvent, []protocol.Recipient) error { return nil }),
		&testErrorLogger{},
	)

	var hooks sync.WaitGroup
	for range 64 {
		hooks.Add(1)
		go func() {
			defer hooks.Done()
			p.MessageHasBeenPosted(nil, eligibleTestPost())
		}()
	}
	if err := p.OnDeactivate(); err != nil {
		t.Fatalf("OnDeactivate() error = %v", err)
	}
	hooks.Wait()
	writesAfterJoin := queue.putCalls.Load()
	p.MessageHasBeenPosted(nil, eligibleTestPost())
	if got := queue.putCalls.Load(); got != writesAfterJoin {
		t.Fatalf("writes after deactivation = %d, want unchanged %d", got, writesAfterJoin)
	}
}

func TestPluginDeactivationBoundsAConcurrentStalledHook(t *testing.T) {
	controls := newTestRuntimeControls(activeControlState(1))
	queue := newTestRuntimeOutbox()
	queue.putStarted = make(chan struct{})
	queue.putRelease = make(chan struct{})
	p := newPlugin(pluginOptions{
		getenv:          testConfigEnvironment,
		api:             newFakeMattermostAPI(),
		shutdownTimeout: 20 * time.Millisecond,
		buildRuntime: func(Config, MattermostAPI, errorClassLogger) (runtimeComponents, error) {
			return runtimeComponents{
				controls:   controls,
				outbox:     queue,
				recipients: recipientResolverFunc(func(OutboxEvent) ([]protocol.Recipient, error) { return nil, nil }),
				mailer:     mailerEnqueuerFunc(func(context.Context, OutboxEvent, []protocol.Recipient) error { return nil }),
				logger:     &testErrorLogger{},
			}, nil
		},
	})
	if err := p.OnActivate(); err != nil {
		t.Fatalf("OnActivate() error = %v", err)
	}
	hookDone := make(chan struct{})
	go func() {
		defer close(hookDone)
		p.MessageHasBeenPosted(nil, eligibleTestPost())
	}()
	waitForSignal(t, queue.putStarted, "stalled hook KV write")

	deactivated := make(chan error, 1)
	go func() { deactivated <- p.OnDeactivate() }()
	select {
	case err := <-deactivated:
		if !errors.Is(err, ErrPluginShutdownTimeout) {
			close(queue.putRelease)
			t.Fatalf("OnDeactivate() error = %v, want ErrPluginShutdownTimeout", err)
		}
	case <-time.After(100 * time.Millisecond):
		close(queue.putRelease)
		<-deactivated
		t.Fatal("OnDeactivate() blocked on a stalled hook beyond its shutdown bound")
	}
	close(queue.putRelease)
	waitForSignal(t, hookDone, "stalled hook release")
}

func TestPluginOverridesOnlyTheApprovedLifecycleAndPostedHook(t *testing.T) {
	pluginType := reflect.TypeOf(New())
	for _, forbidden := range []string{
		"MessageWillBePosted", "MessageHasBeenUpdated", "MessageHasBeenDeleted",
		"ReactionHasBeenAdded", "ReactionHasBeenRemoved", "NotificationWillBePushed",
		"EmailNotificationWillBeSent",
	} {
		if _, found := pluginType.MethodByName(forbidden); found {
			t.Fatalf("Plugin unexpectedly overrides %s", forbidden)
		}
	}
	for _, required := range []string{"OnActivate", "OnDeactivate", "MessageHasBeenPosted"} {
		if _, found := pluginType.MethodByName(required); !found {
			t.Fatalf("Plugin does not implement required hook %s", required)
		}
	}
}

func TestPluginWorkerRetainsPendingWhileDisabledThenDiscardsBeforeNewActivationCutoff(t *testing.T) {
	stored := StoredEvent{Key: "outbox:" + testPostID, Raw: []byte("safe raw"), Event: OutboxEvent{
		PostID: testPostID, ChannelID: testChannelID, AuthorUserID: testAuthorID, CreateAt: 100,
	}}
	controls := newTestRuntimeControls(control.State{Mode: "all_channels"})
	queue := newTestRuntimeOutbox()
	queue.events = []StoredEvent{stored}
	var recipientCalls atomic.Int32
	var mailerCalls atomic.Int32
	components := runtimeComponents{
		controls: controls,
		outbox:   queue,
		recipients: recipientResolverFunc(func(OutboxEvent) ([]protocol.Recipient, error) {
			recipientCalls.Add(1)
			return testRecipients(1), nil
		}),
		mailer: mailerEnqueuerFunc(func(context.Context, OutboxEvent, []protocol.Recipient) error {
			mailerCalls.Add(1)
			return nil
		}),
		logger: &testErrorLogger{},
	}
	p := New()

	p.processBatch(t.Context(), components)
	if got := queue.completeCalls.Load(); got != 0 {
		t.Fatalf("disabled Complete() calls = %d, want pending retained", got)
	}
	if queue.listCalls.Load() != 0 {
		t.Fatal("disabled worker read the pending outbox")
	}

	controls.Set(activeControlState(101))
	p.processBatch(t.Context(), components)
	if got := queue.completeCalls.Load(); got != 1 {
		t.Fatalf("reactivated cutoff Complete() calls = %d, want stale event discarded", got)
	}
	if recipientCalls.Load() != 0 || mailerCalls.Load() != 0 {
		t.Fatalf("stale event recipient/mailer calls = %d/%d, want 0/0", recipientCalls.Load(), mailerCalls.Load())
	}
}

func TestPluginWorkerCompletesOnlyAfterMailerAcknowledgement(t *testing.T) {
	stored := StoredEvent{Key: "outbox:" + testPostID, Raw: []byte("safe raw"), Event: testOutboxEvent(testPostID)}
	controls := newTestRuntimeControls(activeControlState(1))
	queue := newTestRuntimeOutbox()
	queue.events = []StoredEvent{stored}
	mailerErr := atomic.Bool{}
	mailerErr.Store(true)
	components := runtimeComponents{
		controls: controls,
		outbox:   queue,
		recipients: recipientResolverFunc(func(OutboxEvent) ([]protocol.Recipient, error) {
			return testRecipients(1), nil
		}),
		mailer: mailerEnqueuerFunc(func(context.Context, OutboxEvent, []protocol.Recipient) error {
			if mailerErr.Load() {
				return errors.New("no durable acknowledgement")
			}
			return nil
		}),
		logger: &testErrorLogger{},
	}
	p := New()

	p.processBatch(t.Context(), components)
	if got := queue.completeCalls.Load(); got != 0 {
		t.Fatalf("Complete() calls after failed enqueue = %d, want 0", got)
	}
	mailerErr.Store(false)
	p.processBatch(t.Context(), components)
	if got := queue.completeCalls.Load(); got != 1 {
		t.Fatalf("Complete() calls after ACK = %d, want 1", got)
	}
}

func TestPluginWorkerCompletesZeroRecipientEventsWithoutMailerCall(t *testing.T) {
	queue := newTestRuntimeOutbox()
	queue.events = []StoredEvent{{Key: "outbox:" + testPostID, Raw: []byte("safe raw"), Event: testOutboxEvent(testPostID)}}
	var mailerCalls atomic.Int32
	components := runtimeComponents{
		controls: newTestRuntimeControls(activeControlState(1)),
		outbox:   queue,
		recipients: recipientResolverFunc(func(OutboxEvent) ([]protocol.Recipient, error) {
			return nil, nil
		}),
		mailer: mailerEnqueuerFunc(func(context.Context, OutboxEvent, []protocol.Recipient) error {
			mailerCalls.Add(1)
			return nil
		}),
		logger: &testErrorLogger{},
	}
	New().processBatch(t.Context(), components)
	if queue.completeCalls.Load() != 1 || mailerCalls.Load() != 0 {
		t.Fatalf("zero-recipient Complete/mailer calls = %d/%d, want 1/0", queue.completeCalls.Load(), mailerCalls.Load())
	}
}

func TestPluginWorkerQuarantinesMalformedOutboxWithoutPIIAndCASDeletesOriginal(t *testing.T) {
	api := newFakeMattermostAPI()
	key := "outbox:" + testPostID
	raw := []byte(`{"post_id":"` + testPostID + `","email":"recipient@example.test","message":"raw private body"}`)
	api.pages[0] = []string{key}
	api.values[key] = append([]byte(nil), raw...)
	logger := &testErrorLogger{}
	components := runtimeComponents{
		controls:   newTestRuntimeControls(activeControlState(1)),
		outbox:     NewOutbox(api),
		recipients: recipientResolverFunc(func(OutboxEvent) ([]protocol.Recipient, error) { return nil, nil }),
		mailer:     mailerEnqueuerFunc(func(context.Context, OutboxEvent, []protocol.Recipient) error { return nil }),
		logger:     logger,
	}
	p := New()
	p.now = func() time.Time { return time.UnixMilli(1787790000123) }
	p.processBatch(t.Context(), components)

	hash := sha256.Sum256([]byte(key))
	deadKey := "dead:" + hex.EncodeToString(hash[:])
	deadRaw, found := api.values[deadKey]
	if !found {
		t.Fatalf("dead letter %q was not stored", deadKey)
	}
	var dead map[string]any
	if err := json.Unmarshal(deadRaw, &dead); err != nil {
		t.Fatalf("dead letter decode: %v", err)
	}
	if len(dead) != 2 || dead["error_class"] != "malformed_outbox" || dead["quarantined_at"] != float64(1787790000123) {
		t.Fatalf("dead letter = %#v, want only safe class and time", dead)
	}
	if _, found := api.values[key]; found {
		t.Fatal("malformed original remained after successful dead-letter CAS")
	}
	if got := api.setKeys; len(got) != 1 || got[0] != deadKey {
		t.Fatalf("dead-letter writes = %v, want one hashed key", got)
	}
	if options := api.setOptions[0]; !options.Atomic || options.OldValue != nil {
		t.Fatalf("dead-letter options = %#v, want atomic first-write-only insert", options)
	}
	joined := string(deadRaw) + strings.Join(logger.classesSnapshot(), " ")
	for _, forbidden := range []string{string(raw), key, testPostID, "recipient@example.test", "raw private body"} {
		if strings.Contains(joined, forbidden) {
			t.Fatalf("quarantine output exposed forbidden value %q", forbidden)
		}
	}
	if got, want := logger.classesSnapshot(), []string{"malformed_outbox"}; !reflect.DeepEqual(got, want) {
		t.Fatalf("quarantine log classes = %v, want %v", got, want)
	}
}

func TestPluginWorkerWaitsForPollIntervalAfterAnOutboxError(t *testing.T) {
	controls := newTestRuntimeControls(activeControlState(1))
	queue := newTestRuntimeOutbox()
	queue.listErr = errors.New("temporary KV failure")
	components := runtimeComponents{
		controls:   controls,
		outbox:     queue,
		recipients: recipientResolverFunc(func(OutboxEvent) ([]protocol.Recipient, error) { return nil, nil }),
		mailer:     mailerEnqueuerFunc(func(context.Context, OutboxEvent, []protocol.Recipient) error { return nil }),
		logger:     &testErrorLogger{},
	}
	ctx, cancel := context.WithCancel(t.Context())
	done := make(chan struct{})
	go func() {
		defer close(done)
		New().runWorker(ctx, components, 200*time.Millisecond)
	}()
	waitForSignal(t, queue.listed, "first failing worker poll")
	select {
	case <-queue.listed:
		t.Fatal("worker repeated a failed outbox poll without waiting")
	case <-time.After(40 * time.Millisecond):
	}
	cancel()
	waitForSignal(t, done, "worker cancellation")
}

func TestPluginManifestIsServerOnlyAndPinsTheApprovedContract(t *testing.T) {
	raw, err := os.ReadFile("../plugin.json")
	if err != nil {
		t.Fatal(err)
	}
	var manifest map[string]any
	if err := json.Unmarshal(raw, &manifest); err != nil {
		t.Fatalf("decode plugin manifest: %v", err)
	}
	wantKeys := []string{"description", "homepage_url", "id", "min_server_version", "name", "server", "support_url", "version"}
	gotKeys := make([]string, 0, len(manifest))
	for key := range manifest {
		gotKeys = append(gotKeys, key)
	}
	sort.Strings(gotKeys)
	if !reflect.DeepEqual(gotKeys, wantKeys) {
		t.Fatalf("manifest keys = %v, want server-only %v", gotKeys, wantKeys)
	}
	if manifest["id"] != "com.threadhub.channel-email-notifier" || manifest["version"] != "0.1.0" || manifest["min_server_version"] != "11.7.7" {
		t.Fatalf("manifest identity = %#v, want approved plugin/version baseline", manifest)
	}
	if manifest["name"] != "ThreadHub Channel Email Notifier" ||
		manifest["description"] != "Queues generic email notices for new public and private channel posts." ||
		manifest["homepage_url"] != "https://github.com/nugaing119/ThreadHub" ||
		manifest["support_url"] != "https://github.com/nugaing119/ThreadHub/issues" {
		t.Fatalf("manifest metadata = %#v, want approved fixed values", manifest)
	}
	server, ok := manifest["server"].(map[string]any)
	if !ok {
		t.Fatalf("manifest server = %#v", manifest["server"])
	}
	executables, ok := server["executables"].(map[string]any)
	if !ok || len(executables) != 1 || executables["linux-amd64"] != "server/dist/plugin-linux-amd64" {
		t.Fatalf("manifest executables = %#v, want exact linux-amd64 binary", executables)
	}
}

func activeControlState(activatedAt int64) control.State {
	return control.State{Enabled: true, DeliveryEnabled: true, Mode: "all_channels", ActivatedAt: activatedAt}
}

func eligibleTestPost() *model.Post {
	return &model.Post{Id: testPostID, ChannelId: testChannelID, UserId: testAuthorID, CreateAt: 100}
}

func activateTestPlugin(t *testing.T, controls *testRuntimeControls, queue *testRuntimeOutbox, recipients recipientResolver, mailer mailerEnqueuer, logger errorClassLogger) *Plugin {
	t.Helper()
	p := newPlugin(pluginOptions{
		getenv:          testConfigEnvironment,
		api:             newFakeMattermostAPI(),
		shutdownTimeout: time.Second,
		buildRuntime: func(Config, MattermostAPI, errorClassLogger) (runtimeComponents, error) {
			return runtimeComponents{controls: controls, outbox: queue, recipients: recipients, mailer: mailer, logger: logger}, nil
		},
	})
	if err := p.OnActivate(); err != nil {
		t.Fatalf("OnActivate() error = %v", err)
	}
	return p
}

func deactivateAtCleanup(t *testing.T, p *Plugin) {
	t.Helper()
	t.Cleanup(func() {
		if err := p.OnDeactivate(); err != nil {
			t.Errorf("OnDeactivate() cleanup error = %v", err)
		}
	})
}

func waitForSignal(t *testing.T, signal <-chan struct{}, name string) {
	t.Helper()
	select {
	case <-signal:
	case <-time.After(time.Second):
		t.Fatalf("timed out waiting for %s", name)
	}
}

type testRuntimeControls struct {
	state              atomic.Pointer[control.State]
	runs               atomic.Int32
	stopped            atomic.Bool
	started            chan struct{}
	ready              chan struct{}
	release            chan struct{}
	startOnce          sync.Once
	readyOnce          sync.Once
	ignoreCancellation bool
}

func newTestRuntimeControls(state control.State) *testRuntimeControls {
	controls := &testRuntimeControls{started: make(chan struct{}), ready: make(chan struct{}), release: make(chan struct{})}
	controls.Set(state)
	return controls
}

func (c *testRuntimeControls) Set(state control.State) {
	copyState := state
	copyState.ChannelIDs = append([]string(nil), state.ChannelIDs...)
	c.state.Store(&copyState)
}

func (c *testRuntimeControls) Current() control.State {
	state := c.state.Load()
	if state == nil {
		return control.State{}
	}
	copyState := *state
	copyState.ChannelIDs = append([]string(nil), state.ChannelIDs...)
	return copyState
}

func (c *testRuntimeControls) Ready() <-chan struct{} { return c.ready }

func (c *testRuntimeControls) Run(ctx context.Context) error {
	c.runs.Add(1)
	c.startOnce.Do(func() { close(c.started) })
	c.readyOnce.Do(func() { close(c.ready) })
	if c.ignoreCancellation {
		<-c.release
	} else {
		<-ctx.Done()
	}
	c.stopped.Store(true)
	return nil
}

type testRuntimeOutbox struct {
	mu              sync.Mutex
	events          []StoredEvent
	putEvents       []OutboxEvent
	putErr          error
	listErr         error
	putCalls        atomic.Int32
	listCalls       atomic.Int32
	completeCalls   atomic.Int32
	quarantineCalls atomic.Int32
	listed          chan struct{}
	putStarted      chan struct{}
	putRelease      chan struct{}
	putStartOnce    sync.Once
}

func newTestRuntimeOutbox() *testRuntimeOutbox {
	return &testRuntimeOutbox{listed: make(chan struct{}, 16)}
}

func (q *testRuntimeOutbox) Put(event OutboxEvent) error {
	q.putCalls.Add(1)
	if q.putStarted != nil {
		q.putStartOnce.Do(func() { close(q.putStarted) })
	}
	if q.putRelease != nil {
		<-q.putRelease
	}
	q.mu.Lock()
	defer q.mu.Unlock()
	q.putEvents = append(q.putEvents, event)
	return q.putErr
}

func (q *testRuntimeOutbox) List() ([]StoredEvent, error) {
	q.listCalls.Add(1)
	select {
	case q.listed <- struct{}{}:
	default:
	}
	q.mu.Lock()
	defer q.mu.Unlock()
	return append([]StoredEvent(nil), q.events...), q.listErr
}

func (q *testRuntimeOutbox) Complete(StoredEvent) error {
	q.completeCalls.Add(1)
	return nil
}

func (q *testRuntimeOutbox) Quarantine(StoredEvent, time.Time) error {
	q.quarantineCalls.Add(1)
	return nil
}

func (q *testRuntimeOutbox) putEventsSnapshot() []OutboxEvent {
	q.mu.Lock()
	defer q.mu.Unlock()
	return append([]OutboxEvent(nil), q.putEvents...)
}

type recipientResolverFunc func(OutboxEvent) ([]protocol.Recipient, error)

func (f recipientResolverFunc) Resolve(event OutboxEvent) ([]protocol.Recipient, error) {
	return f(event)
}

type mailerEnqueuerFunc func(context.Context, OutboxEvent, []protocol.Recipient) error

func (f mailerEnqueuerFunc) Enqueue(ctx context.Context, event OutboxEvent, recipients []protocol.Recipient) error {
	return f(ctx, event, recipients)
}

type testErrorLogger struct {
	mu      sync.Mutex
	classes []string
}

func (l *testErrorLogger) ErrorClass(class string) {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.classes = append(l.classes, class)
}

func (l *testErrorLogger) classesSnapshot() []string {
	l.mu.Lock()
	defer l.mu.Unlock()
	return append([]string(nil), l.classes...)
}
