package logsafe

import (
	"bytes"
	"log/slog"
	"strings"
	"testing"
	"time"
)

func TestLoggerEmitsOnlySafeDeliveryFields(t *testing.T) {
	t.Parallel()
	var output bytes.Buffer
	logger := New(slog.New(slog.NewJSONHandler(&output, nil)))
	logger.DeliveryFailure("temporary", 450)
	logger.DeliverySuccess(12 * time.Millisecond)
	logger.QueueDepth(3)
	got := output.String()
	for _, required := range []string{"delivery_failed", "error_class", "smtp_code", "delivery_succeeded", "duration_ms", "queue_depth", "count"} {
		if !strings.Contains(got, required) {
			t.Fatalf("log output missing %q: %s", required, got)
		}
	}
	for _, forbidden := range []string{"fixture-password", "recipient@example.test", "SENTINEL post content"} {
		if strings.Contains(got, forbidden) {
			t.Fatalf("log output leaked %q", forbidden)
		}
	}
}
