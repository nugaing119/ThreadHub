package server

import (
	"context"
	"errors"
	"net/http"
	"os"
	"sync"
	"time"

	"github.com/mattermost/mattermost/server/public/model"
	"github.com/mattermost/mattermost/server/public/plugin"
	"github.com/nugaing119/ThreadHub/notifier/control"
	"github.com/nugaing119/ThreadHub/notifier/protocol"
)

var (
	ErrPluginAlreadyActive   = errors.New("plugin is already active")
	ErrPluginAPIUnavailable  = errors.New("mattermost plugin API is unavailable")
	ErrPluginRuntime         = errors.New("plugin runtime failed")
	ErrPluginShutdownTimeout = errors.New("plugin shutdown timed out")
)

const defaultPluginShutdownTimeout = 5 * time.Second

type controlReloader interface {
	Run(context.Context) error
	Ready() <-chan struct{}
	Current() control.State
}

type outboxQueue interface {
	Put(OutboxEvent) error
	List() ([]StoredEvent, error)
	Complete(StoredEvent) error
	Quarantine(StoredEvent, time.Time) error
}

type recipientResolver interface {
	Resolve(OutboxEvent) ([]protocol.Recipient, error)
}

type mailerEnqueuer interface {
	Enqueue(context.Context, OutboxEvent, []protocol.Recipient) error
}

type errorClassLogger interface {
	ErrorClass(string)
}

type runtimeComponents struct {
	controls   controlReloader
	outbox     outboxQueue
	recipients recipientResolver
	mailer     mailerEnqueuer
	logger     errorClassLogger
}

type runtimeBuilder func(Config, MattermostAPI, errorClassLogger) (runtimeComponents, error)

type pluginOptions struct {
	getenv          func(string) string
	api             MattermostAPI
	httpClient      *http.Client
	logger          errorClassLogger
	buildRuntime    runtimeBuilder
	shutdownTimeout time.Duration
	now             func() time.Time
}

type activeRuntime struct {
	components  runtimeComponents
	cancel      context.CancelFunc
	controlDone <-chan struct{}
	workerDone  <-chan struct{}

	hookMu      sync.Mutex
	acceptHooks bool
	hookCount   int
	hookDrained chan struct{}
}

type Plugin struct {
	plugin.MattermostPlugin

	lifecycleMu sync.RWMutex
	active      *activeRuntime

	getenv          func(string) string
	api             MattermostAPI
	httpClient      *http.Client
	logger          errorClassLogger
	buildRuntime    runtimeBuilder
	shutdownTimeout time.Duration
	now             func() time.Time
}

func New() *Plugin {
	return newPlugin(pluginOptions{})
}

func newPlugin(options pluginOptions) *Plugin {
	p := &Plugin{
		getenv:          options.getenv,
		api:             options.api,
		httpClient:      options.httpClient,
		logger:          options.logger,
		buildRuntime:    options.buildRuntime,
		shutdownTimeout: options.shutdownTimeout,
		now:             options.now,
	}
	if p.getenv == nil {
		p.getenv = os.Getenv
	}
	if p.shutdownTimeout <= 0 {
		p.shutdownTimeout = defaultPluginShutdownTimeout
	}
	if p.now == nil {
		p.now = time.Now
	}
	if p.buildRuntime == nil {
		p.buildRuntime = p.defaultRuntime
	}
	return p
}

func (p *Plugin) defaultRuntime(cfg Config, api MattermostAPI, logger errorClassLogger) (runtimeComponents, error) {
	watcher := control.NewWatcher(cfg.ControlFile, cfg.PollEvery)
	return runtimeComponents{
		controls:   watcher,
		outbox:     NewOutbox(api),
		recipients: NewRecipientResolver(api),
		mailer:     NewMailerClient(cfg.MailerURL, cfg.Domain, cfg.HMACSecret, p.httpClient),
		logger:     logger,
	}, nil
}

func (p *Plugin) OnActivate() error {
	p.lifecycleMu.Lock()
	defer p.lifecycleMu.Unlock()

	if p.active != nil {
		return ErrPluginAlreadyActive
	}
	cfg, err := LoadConfig(p.getenv)
	if err != nil {
		return err
	}
	api := p.api
	if api == nil {
		if p.API == nil {
			return ErrPluginAPIUnavailable
		}
		api = p.API
	}
	logger := p.logger
	if logger == nil {
		if p.API != nil {
			logger = mattermostErrorLogger{api: p.API}
		} else {
			logger = discardErrorLogger{}
		}
	}
	components, err := p.buildRuntime(cfg, api, logger)
	if err != nil || !components.valid() {
		return ErrPluginRuntime
	}

	ctx, cancel := context.WithCancel(context.Background())
	controlDone := startBackground(ctx, components.controls.Run)
	select {
	case <-components.controls.Ready():
	case <-controlDone:
		cancel()
		return ErrPluginRuntime
	}
	workerDone := startBackground(ctx, func(ctx context.Context) error {
		p.runWorker(ctx, components, cfg.PollEvery)
		return nil
	})
	p.active = &activeRuntime{
		components: components, cancel: cancel,
		controlDone: controlDone, workerDone: workerDone,
		acceptHooks: true,
	}
	return nil
}

func (p *Plugin) OnDeactivate() error {
	p.lifecycleMu.Lock()
	active := p.active
	if active == nil {
		p.lifecycleMu.Unlock()
		return nil
	}
	p.active = nil
	hookDrained := active.stopHooks()
	active.cancel()
	p.lifecycleMu.Unlock()

	timer := time.NewTimer(p.shutdownTimeout)
	defer timer.Stop()
	for _, done := range []<-chan struct{}{hookDrained, active.controlDone, active.workerDone} {
		select {
		case <-done:
		case <-timer.C:
			return ErrPluginShutdownTimeout
		}
	}
	return nil
}

func (p *Plugin) MessageHasBeenPosted(_ *plugin.Context, post *model.Post) {
	p.lifecycleMu.RLock()
	active := p.active
	if active == nil || !active.beginHook() {
		p.lifecycleMu.RUnlock()
		return
	}
	p.lifecycleMu.RUnlock()
	defer active.endHook()

	components := active.components
	if !EligibleAtHook(components.controls.Current(), post) {
		return
	}
	if err := components.outbox.Put(NewOutboxEvent(post)); err != nil {
		components.logger.ErrorClass("outbox_write")
	}
}

func (active *activeRuntime) beginHook() bool {
	active.hookMu.Lock()
	defer active.hookMu.Unlock()
	if !active.acceptHooks {
		return false
	}
	active.hookCount++
	return true
}

func (active *activeRuntime) endHook() {
	active.hookMu.Lock()
	defer active.hookMu.Unlock()
	active.hookCount--
	if !active.acceptHooks && active.hookCount == 0 && active.hookDrained != nil {
		close(active.hookDrained)
		active.hookDrained = nil
	}
}

func (active *activeRuntime) stopHooks() <-chan struct{} {
	active.hookMu.Lock()
	defer active.hookMu.Unlock()
	active.acceptHooks = false
	done := make(chan struct{})
	if active.hookCount == 0 {
		close(done)
		return done
	}
	active.hookDrained = done
	return done
}

func (p *Plugin) runWorker(ctx context.Context, components runtimeComponents, pollEvery time.Duration) {
	if pollEvery <= 0 {
		pollEvery = time.Second
	}
	timer := time.NewTimer(0)
	defer timer.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-timer.C:
		}
		p.processBatch(ctx, components)
		timer.Reset(pollEvery)
	}
}

func (p *Plugin) processBatch(ctx context.Context, components runtimeComponents) {
	if !components.controls.Current().Enabled {
		return
	}
	events, err := components.outbox.List()
	if err != nil {
		var malformed *malformedOutboxError
		if errors.As(err, &malformed) {
			components.logger.ErrorClass("malformed_outbox")
			if quarantineErr := components.outbox.Quarantine(malformed.stored, p.now()); quarantineErr != nil {
				components.logger.ErrorClass("outbox_quarantine")
			}
		} else {
			components.logger.ErrorClass("outbox_list")
		}
	}
	for _, stored := range events {
		select {
		case <-ctx.Done():
			return
		default:
		}
		p.processOne(ctx, components, stored)
	}
}

func (p *Plugin) processOne(ctx context.Context, components runtimeComponents, stored StoredEvent) {
	state := components.controls.Current()
	if !state.Enabled {
		return
	}
	if stored.Event.CreateAt < state.ActivatedAt || !state.AllowsChannel(stored.Event.ChannelID) {
		p.complete(components, stored)
		return
	}
	recipients, err := components.recipients.Resolve(stored.Event)
	if err != nil {
		components.logger.ErrorClass("recipient_resolve")
		return
	}

	// Re-read the shared state immediately before the durable handoff. A disable
	// that arrives while membership is being resolved retains the plugin outbox.
	state = components.controls.Current()
	if !state.Enabled {
		return
	}
	if stored.Event.CreateAt < state.ActivatedAt || !state.AllowsChannel(stored.Event.ChannelID) {
		p.complete(components, stored)
		return
	}
	if len(recipients) > 0 {
		if err := components.mailer.Enqueue(ctx, stored.Event, recipients); err != nil {
			components.logger.ErrorClass("mailer_enqueue")
			return
		}
	}
	p.complete(components, stored)
}

func (p *Plugin) complete(components runtimeComponents, stored StoredEvent) {
	if err := components.outbox.Complete(stored); err != nil {
		components.logger.ErrorClass("outbox_complete")
	}
}

func (components runtimeComponents) valid() bool {
	return components.controls != nil && components.outbox != nil && components.recipients != nil && components.mailer != nil && components.logger != nil
}

func startBackground(ctx context.Context, run func(context.Context) error) <-chan struct{} {
	done := make(chan struct{})
	go func() {
		_ = run(ctx)
		close(done)
	}()
	return done
}

type mattermostErrorLogger struct {
	api interface {
		LogError(string, ...any)
	}
}

func (l mattermostErrorLogger) ErrorClass(class string) {
	if l.api != nil {
		l.api.LogError("threadhub_notifier_error", "error_class", safePluginErrorClass(class))
	}
}

type discardErrorLogger struct{}

func (discardErrorLogger) ErrorClass(string) {}

func safePluginErrorClass(class string) string {
	switch class {
	case "outbox_write", "outbox_list", "malformed_outbox", "outbox_quarantine", "recipient_resolve", "mailer_enqueue", "outbox_complete":
		return class
	default:
		return "plugin_runtime"
	}
}
