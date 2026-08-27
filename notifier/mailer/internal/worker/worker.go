// Package worker runs the mailer's single rate-limited delivery loop.
package worker

import (
	"context"
	"log/slog"
	"strings"
	"sync"
	"time"

	"github.com/nugaing119/ThreadHub/notifier/control"
	"github.com/nugaing119/ThreadHub/notifier/mailer/internal/message"
	"github.com/nugaing119/ThreadHub/notifier/mailer/internal/smtpclient"
	"github.com/nugaing119/ThreadHub/notifier/mailer/internal/store"
)

var retryOffsets = [...]time.Duration{
	0,
	30 * time.Second,
	2 * time.Minute,
	10 * time.Minute,
	30 * time.Minute,
	2 * time.Hour,
	6 * time.Hour,
	24 * time.Hour,
}

type Store interface {
	ClaimDue(context.Context, time.Time, time.Duration) (*store.Delivery, error)
	MarkSent(context.Context, store.DeliveryKey, time.Time) error
	MarkTemporary(context.Context, store.DeliveryKey, string, int, time.Time) error
	MarkPermanent(context.Context, store.DeliveryKey, string, int, time.Time) error
	ResetExpiredLeases(context.Context, time.Time) (int64, error)
}

type Sender interface {
	Send(context.Context, message.Message) smtpclient.Result
}

type RenderFunc func(store.Delivery) (message.Message, error)

type ControlReader interface {
	Current() control.State
	Changes() <-chan control.State
}

type Clock interface {
	Now() time.Time
	Wait(context.Context, time.Duration) error
}

type Config struct {
	RatePerMinute int
	LeaseDuration time.Duration
}

type Worker struct {
	store         Store
	render        RenderFunc
	sender        Sender
	controls      ControlReader
	clock         Clock
	rateInterval  time.Duration
	leaseDuration time.Duration
	ready         chan struct{}
	readyDo       sync.Once
}

func New(queue Store, render RenderFunc, sender Sender, controls ControlReader, clock Clock, cfg Config) *Worker {
	rate := cfg.RatePerMinute
	if rate <= 0 {
		rate = 10
	}
	lease := cfg.LeaseDuration
	if lease <= 0 {
		lease = 2 * time.Minute
	}
	if clock == nil {
		clock = systemClock{}
	}
	return &Worker{
		store:         queue,
		render:        render,
		sender:        sender,
		controls:      controls,
		clock:         clock,
		rateInterval:  time.Minute / time.Duration(rate),
		leaseDuration: lease,
		ready:         make(chan struct{}),
	}
}

func (w *Worker) Run(ctx context.Context) error {
	if ctx == nil {
		ctx = context.Background()
	}
	w.readyDo.Do(func() { close(w.ready) })
	nextRecovery := w.clock.Now()
	var nextClaim time.Time
	for {
		if ctx.Err() != nil {
			return nil
		}

		now := w.clock.Now()
		if !now.Before(nextRecovery) {
			w.recoverLeases(ctx, now)
			nextRecovery = now.Add(time.Minute)
		}

		if !w.deliveryEnabled() {
			if err := w.waitOrControl(ctx, positiveDuration(nextRecovery.Sub(w.clock.Now()))); err != nil {
				return nil
			}
			continue
		}

		if now = w.clock.Now(); now.Before(nextClaim) {
			if err := w.waitOrControl(ctx, nextClaim.Sub(now)); err != nil {
				return nil
			}
			continue
		}
		if !w.deliveryEnabled() {
			continue
		}

		claimAt := w.clock.Now()
		delivery, err := w.store.ClaimDue(ctx, claimAt, w.leaseDuration)
		if err != nil {
			logAggregate("protocol", 0, 1)
			if err := w.waitOrControl(ctx, time.Second); err != nil {
				return nil
			}
			continue
		}
		if delivery == nil {
			if err := w.waitOrControl(ctx, time.Second); err != nil {
				return nil
			}
			continue
		}
		nextClaim = claimAt.Add(w.rateInterval)
		if !w.deliveryEnabled() {
			continue
		}
		if strings.TrimSpace(delivery.Email) == "" {
			w.markPermanent(ctx, *delivery, "protocol", 0)
			continue
		}

		rendered, err := w.render(*delivery)
		if err != nil || strings.TrimSpace(rendered.EnvelopeTo) == "" {
			w.markPermanent(ctx, *delivery, "protocol", 0)
			continue
		}

		result, finish := w.send(ctx, rendered)
		if !finish {
			return nil
		}
		if result.Accepted {
			if err := w.store.MarkSent(ctx, delivery.Key, w.clock.Now()); err != nil {
				logAggregate("protocol", 0, 1)
			}
			continue
		}
		temporary, class := retryable(result)
		if temporary {
			next := delivery.AcceptedAt.Add(nextRetryOffset(delivery.AttemptCount))
			if err := w.store.MarkTemporary(ctx, delivery.Key, class, result.Code, next); err != nil {
				logAggregate("protocol", 0, 1)
			} else {
				logAggregate(class, result.Code, 1)
			}
			continue
		}
		w.markPermanent(ctx, *delivery, class, result.Code)
	}
}

func (w *Worker) Ready() <-chan struct{} {
	if w == nil {
		return nil
	}
	return w.ready
}

func (w *Worker) recoverLeases(ctx context.Context, now time.Time) {
	count, err := w.store.ResetExpiredLeases(ctx, now)
	if err != nil {
		logAggregate("protocol", 0, 1)
		return
	}
	if count > 0 {
		slog.Info("expired_leases_recovered", slog.Int64("count", count))
	}
}

func (w *Worker) markPermanent(ctx context.Context, delivery store.Delivery, class string, code int) {
	if err := w.store.MarkPermanent(ctx, delivery.Key, class, code, w.clock.Now()); err != nil {
		logAggregate("protocol", 0, 1)
		return
	}
	logAggregate(class, code, 1)
}

func (w *Worker) send(ctx context.Context, rendered message.Message) (smtpclient.Result, bool) {
	sendCtx, cancel := context.WithCancel(ctx)
	defer cancel()
	done := make(chan smtpclient.Result, 1)
	go func() {
		done <- w.sender.Send(sendCtx, rendered)
	}()
	changes := w.controlChanges()
	for {
		select {
		case result := <-done:
			return result, true
		case state, ok := <-changes:
			if !ok {
				changes = nil
				continue
			}
			if !state.DeliveryEnabled {
				cancel()
				return <-done, true
			}
		case <-ctx.Done():
			cancel()
			<-done
			return smtpclient.Result{}, false
		}
	}
}

func (w *Worker) deliveryEnabled() bool {
	return w.controls != nil && w.controls.Current().DeliveryEnabled
}

func (w *Worker) controlChanges() <-chan control.State {
	if w.controls == nil {
		return nil
	}
	return w.controls.Changes()
}

func (w *Worker) waitOrControl(ctx context.Context, duration time.Duration) error {
	if duration <= 0 {
		return nil
	}
	waitCtx, cancel := context.WithCancel(ctx)
	done := make(chan error, 1)
	go func() { done <- w.clock.Wait(waitCtx, duration) }()
	select {
	case err := <-done:
		cancel()
		return err
	case <-w.controlChanges():
		cancel()
		<-done
		return nil
	case <-ctx.Done():
		cancel()
		<-done
		return ctx.Err()
	}
}

func retryOffset(attempt int) time.Duration {
	if attempt <= 1 {
		return retryOffsets[0]
	}
	if attempt >= len(retryOffsets) {
		return retryOffsets[len(retryOffsets)-1]
	}
	return retryOffsets[attempt-1]
}

func nextRetryOffset(attempt int) time.Duration {
	if attempt >= len(retryOffsets) {
		return retryOffsets[len(retryOffsets)-1]
	}
	return retryOffsets[attempt]
}

func retryable(result smtpclient.Result) (bool, string) {
	if result.Code >= 500 && result.Code <= 599 {
		return false, "permanent"
	}
	if result.Code >= 400 && result.Code <= 499 {
		return true, "temporary"
	}
	switch result.Class {
	case smtpclient.ClassTemporary:
		return true, "temporary"
	case smtpclient.ClassTimeout:
		return true, "timeout"
	case smtpclient.ClassPermanent:
		return false, "permanent"
	default:
		return false, "protocol"
	}
}

func logAggregate(class string, code, count int) {
	switch class {
	case "temporary", "permanent", "timeout", "protocol":
	default:
		class = "protocol"
	}
	if code < 100 || code > 999 {
		code = 0
	}
	slog.Error("delivery_result",
		slog.String("error_class", class),
		slog.Int("smtp_code", code),
		slog.Int("count", count),
	)
}

func positiveDuration(duration time.Duration) time.Duration {
	if duration <= 0 {
		return time.Second
	}
	return duration
}

type systemClock struct{}

func (systemClock) Now() time.Time { return time.Now() }
func (systemClock) Wait(ctx context.Context, duration time.Duration) error {
	timer := time.NewTimer(duration)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-timer.C:
		return nil
	}
}
