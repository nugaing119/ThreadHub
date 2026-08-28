// Package logsafe restricts mailer telemetry to a fixed, non-sensitive schema.
package logsafe

import (
	"log/slog"
	"time"
)

type Logger struct{ base *slog.Logger }

func New(base *slog.Logger) *Logger {
	if base == nil {
		base = slog.Default()
	}
	return &Logger{base: base}
}

func (l *Logger) DeliveryFailure(class string, smtpCode int) {
	l.base.Error("delivery_failed", slog.String("error_class", safeClass(class)), slog.Int("smtp_code", safeCode(smtpCode)))
}
func (l *Logger) DeliverySuccess(duration time.Duration) {
	l.base.Info("delivery_succeeded", slog.Int64("duration_ms", duration.Milliseconds()))
}
func (l *Logger) QueueDepth(count int) { l.base.Info("queue_depth", slog.Int("count", count)) }

func safeClass(value string) string {
	switch value {
	case "temporary", "permanent", "timeout", "protocol":
		return value
	default:
		return "protocol"
	}
}
func safeCode(value int) int {
	if value >= 100 && value <= 999 {
		return value
	}
	return 0
}
