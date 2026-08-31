package httpapi

import (
	"bytes"
	"context"
	"encoding/json"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/nugaing119/ThreadHub/notifier/control"
	"github.com/nugaing119/ThreadHub/notifier/mailer/internal/logsafe"
	"github.com/nugaing119/ThreadHub/notifier/mailer/internal/store"
	"github.com/nugaing119/ThreadHub/notifier/protocol"
)

const (
	testPostID = "0123456789abcdefghijklmnop"
	testUserID = "ponmlkjihgfedcba9876543210"
	testNonce  = "00112233445566778899aabbccddeeff"
)

var (
	testNow    = time.Date(2026, 8, 27, 5, 6, 7, 0, time.UTC)
	testSecret = bytes.Repeat([]byte{0x42}, 32)
)

func TestAcceptEventCommitsBeforeReturningAccepted(t *testing.T) {
	handler, queue, _ := newTestHandler(t, true)
	response := performSignedRequest(t, handler, http.MethodPost, "application/json", validEventBody(), testNow.Unix(), testNonce, "")

	if response.Code != http.StatusAccepted {
		t.Fatalf("status = %d, want 202; body=%q", response.Code, response.Body.String())
	}
	if response.Body.Len() != 0 {
		t.Fatalf("accepted response body = %q, want empty", response.Body.String())
	}
	status, err := queue.Status(context.Background(), testNow)
	if err != nil {
		t.Fatalf("Status() error = %v", err)
	}
	if status.Pending != 1 {
		t.Fatalf("pending after 202 = %d, want committed delivery", status.Pending)
	}
}

func TestAcceptEventAuthenticatesRawBodyBeforeJSONDecode(t *testing.T) {
	handler, _, _ := newTestHandler(t, true)
	malformed := []byte(`{"event_id":`)

	badSignature := performSignedRequest(t, handler, http.MethodPost, "application/json", malformed, testNow.Unix(), testNonce, "sha256="+strings.Repeat("0", 64))
	if badSignature.Code != http.StatusUnauthorized {
		t.Fatalf("malformed body with bad signature status = %d, want 401", badSignature.Code)
	}
	validSignature := performSignedRequest(t, handler, http.MethodPost, "application/json", malformed, testNow.Unix(), testNonce, "")
	if validSignature.Code != http.StatusBadRequest {
		t.Fatalf("malformed body with valid signature status = %d, want 400", validSignature.Code)
	}
}

func TestAcceptEventRejectsAuthenticationFailures(t *testing.T) {
	handler, _, _ := newTestHandler(t, true)
	for _, test := range []struct {
		name      string
		timestamp int64
		nonce     string
		signature string
		omit      string
	}{
		{name: "missing signature", timestamp: testNow.Unix(), nonce: testNonce, omit: "signature"},
		{name: "bad signature", timestamp: testNow.Unix(), nonce: testNonce, signature: "sha256=" + strings.Repeat("0", 64)},
		{name: "too old", timestamp: testNow.Add(-301 * time.Second).Unix(), nonce: testNonce},
		{name: "too far future", timestamp: testNow.Add(301 * time.Second).Unix(), nonce: testNonce},
		{name: "malformed timestamp", timestamp: testNow.Unix(), nonce: testNonce, omit: "timestamp"},
		{name: "malformed nonce", timestamp: testNow.Unix(), nonce: "not-a-32-byte-hex-nonce"},
	} {
		t.Run(test.name, func(t *testing.T) {
			req := signedRequest(t, http.MethodPost, "application/json", validEventBody(), test.timestamp, test.nonce, test.signature)
			switch test.omit {
			case "signature":
				req.Header.Del("X-ThreadHub-Signature")
			case "timestamp":
				req.Header.Set("X-ThreadHub-Timestamp", "invalid")
			}
			response := httptest.NewRecorder()
			handler.ServeHTTP(response, req)
			if response.Code != http.StatusUnauthorized {
				t.Fatalf("status = %d, want 401", response.Code)
			}
		})
	}
}

func TestAcceptEventRejectsNonceReplay(t *testing.T) {
	handler, queue, _ := newTestHandler(t, true)
	first := performSignedRequest(t, handler, http.MethodPost, "application/json", validEventBody(), testNow.Unix(), testNonce, "")
	second := performSignedRequest(t, handler, http.MethodPost, "application/json", validEventBody(), testNow.Unix(), testNonce, "")
	if first.Code != http.StatusAccepted || second.Code != http.StatusConflict {
		t.Fatalf("replay statuses = %d, %d; want 202, 409", first.Code, second.Code)
	}
	status, err := queue.Status(context.Background(), testNow)
	if err != nil || status.Pending != 1 {
		t.Fatalf("Status() = %+v, %v; want one delivery", status, err)
	}
}

func TestAcceptEventRejectsInvalidJSONAndUnknownFields(t *testing.T) {
	handler, _, _ := newTestHandler(t, true)
	for index, body := range [][]byte{
		[]byte(`{"event_id":`),
		[]byte(strings.TrimSuffix(string(validEventBody()), "}") + `,"message":"private sentinel"}`),
		append(append([]byte(nil), validEventBody()...), []byte(` {}`)...),
	} {
		nonce := "00112233445566778899aabbccddee" + string("0123456789abcdef"[index:index+1]) + "f"
		response := performSignedRequest(t, handler, http.MethodPost, "application/json", body, testNow.Unix(), nonce, "")
		if response.Code != http.StatusBadRequest {
			t.Errorf("case %d status = %d, want 400", index, response.Code)
		}
	}
}

func TestAcceptEventEnforcesExactMethodContentTypeAndBodyLimit(t *testing.T) {
	handler, _, _ := newTestHandler(t, true)

	wrongMethod := performSignedRequest(t, handler, http.MethodGet, "application/json", validEventBody(), testNow.Unix(), testNonce, "")
	if wrongMethod.Code != http.StatusMethodNotAllowed {
		t.Fatalf("GET /v1/events status = %d, want 405", wrongMethod.Code)
	}
	wrongType := performSignedRequest(t, handler, http.MethodPost, "application/json; charset=utf-8", validEventBody(), testNow.Unix(), testNonce, "")
	if wrongType.Code != http.StatusUnsupportedMediaType {
		t.Fatalf("parameterized content type status = %d, want 415", wrongType.Code)
	}
	duplicateTypeRequest := signedRequest(t, http.MethodPost, "application/json", validEventBody(), testNow.Unix(), testNonce, "")
	duplicateTypeRequest.Header.Add("Content-Type", "text/plain")
	duplicateType := httptest.NewRecorder()
	handler.ServeHTTP(duplicateType, duplicateTypeRequest)
	if duplicateType.Code != http.StatusUnsupportedMediaType {
		t.Fatalf("duplicate content type status = %d, want 415", duplicateType.Code)
	}
	tooLarge := bytes.Repeat([]byte("x"), (1<<20)+1)
	oversize := performSignedRequest(t, handler, http.MethodPost, "application/json", tooLarge, testNow.Unix(), testNonce, "")
	if oversize.Code != http.StatusRequestEntityTooLarge {
		t.Fatalf("oversize status = %d, want 413", oversize.Code)
	}
}

func TestAcceptEventDisabledOrDrainStoresNeitherNonceNorEvent(t *testing.T) {
	for _, deliveryEnabled := range []bool{false, true} {
		t.Run(map[bool]string{false: "disabled", true: "drain"}[deliveryEnabled], func(t *testing.T) {
			dir := t.TempDir()
			controlPath := filepath.Join(dir, "state.json")
			writeControl(t, controlPath, false, deliveryEnabled)
			watcher, stop := runWatcher(t, controlPath)
			defer stop()
			queue := openQueue(t, filepath.Join(dir, "queue.db"))
			t.Setenv("THREADHUB_DOMAIN", "threadhub.example.test")
			handler := NewHandler(queue, watcher, testSecret, func() time.Time { return testNow }, logsafe.New(nil))

			locked := performSignedRequest(t, handler, http.MethodPost, "application/json", validEventBody(), testNow.Unix(), testNonce, "")
			if locked.Code != http.StatusLocked {
				t.Fatalf("disabled ingest status = %d, want 423", locked.Code)
			}
			status, err := queue.Status(context.Background(), testNow)
			if err != nil || status.Pending != 0 {
				t.Fatalf("disabled Status() = %+v, %v; want empty", status, err)
			}

			writeControl(t, controlPath, true, true)
			waitForControl(t, watcher, true)
			accepted := performSignedRequest(t, handler, http.MethodPost, "application/json", validEventBody(), testNow.Unix(), testNonce, "")
			if accepted.Code != http.StatusAccepted {
				t.Fatalf("same nonce after enable status = %d, want 202 proving nonce was not stored", accepted.Code)
			}
		})
	}
}

func TestAcceptEventUnavailableStoreReturnsNoAcknowledgement(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "queue.db")
	handler, queue, watcher := newTestHandlerAt(t, path, true)
	if err := queue.Close(); err != nil {
		t.Fatalf("Close() error = %v", err)
	}
	response := performSignedRequest(t, handler, http.MethodPost, "application/json", validEventBody(), testNow.Unix(), testNonce, "")
	if response.Code != http.StatusServiceUnavailable {
		t.Fatalf("closed store status = %d, want 503", response.Code)
	}

	reopened := openQueue(t, path)
	handler = NewHandler(reopened, watcher, testSecret, func() time.Time { return testNow }, logsafe.New(nil))
	response = performSignedRequest(t, handler, http.MethodPost, "application/json", validEventBody(), testNow.Unix(), testNonce, "")
	if response.Code != http.StatusAccepted {
		t.Fatalf("same nonce after store recovery status = %d, want 202", response.Code)
	}
}

func TestHealthIsExactAndFailsWhenStoreIsUnavailable(t *testing.T) {
	handler, queue, _ := newTestHandler(t, true)
	healthy := httptest.NewRecorder()
	handler.ServeHTTP(healthy, httptest.NewRequest(http.MethodGet, "/healthz", nil))
	if healthy.Code != http.StatusOK || healthy.Body.String() != "ok" {
		t.Fatalf("healthy response = %d %q, want 200 ok", healthy.Code, healthy.Body.String())
	}
	if err := queue.Close(); err != nil {
		t.Fatalf("Close() error = %v", err)
	}
	unhealthy := httptest.NewRecorder()
	handler.ServeHTTP(unhealthy, httptest.NewRequest(http.MethodGet, "/healthz", nil))
	if unhealthy.Code != http.StatusServiceUnavailable {
		t.Fatalf("unhealthy response status = %d, want 503", unhealthy.Code)
	}
}

func TestHandlerRoutesOnlyExactMethodAndRequestTargetWithoutRedirects(t *testing.T) {
	handler, _, _ := newTestHandler(t, true)
	for _, test := range []struct {
		name, method, target string
		want                 int
	}{
		{name: "head health", method: http.MethodHead, target: "/healthz", want: http.StatusMethodNotAllowed},
		{name: "post health", method: http.MethodPost, target: "/healthz", want: http.StatusMethodNotAllowed},
		{name: "get events", method: http.MethodGet, target: "/v1/events", want: http.StatusMethodNotAllowed},
		{name: "unknown event method", method: http.MethodTrace, target: "/v1/events", want: http.StatusMethodNotAllowed},
		{name: "unclean health alias", method: http.MethodGet, target: "/x/../healthz", want: http.StatusNotFound},
		{name: "encoded health suffix", method: http.MethodGet, target: "/health%7a", want: http.StatusNotFound},
		{name: "encoded health prefix", method: http.MethodGet, target: "/%68ealthz", want: http.StatusNotFound},
		{name: "health query", method: http.MethodGet, target: "/healthz?probe=1", want: http.StatusNotFound},
		{name: "empty health query", method: http.MethodGet, target: "/healthz?", want: http.StatusNotFound},
		{name: "event query", method: http.MethodPost, target: "/v1/events?probe=1", want: http.StatusNotFound},
		{name: "encoded event slash", method: http.MethodPost, target: "/v1%2fevents", want: http.StatusNotFound},
		{name: "unknown path", method: http.MethodGet, target: "/metrics", want: http.StatusNotFound},
		{name: "trailing slash", method: http.MethodGet, target: "/healthz/", want: http.StatusNotFound},
	} {
		t.Run(test.name, func(t *testing.T) {
			response := httptest.NewRecorder()
			handler.ServeHTTP(response, httptest.NewRequest(test.method, test.target, nil))
			if response.Code != test.want {
				t.Errorf("%s %s status = %d, want %d", test.method, test.target, response.Code, test.want)
			}
			if location := response.Header().Get("Location"); location != "" {
				t.Errorf("%s %s redirected to %q", test.method, test.target, location)
			}
			if response.Body.Len() != 0 {
				t.Errorf("%s %s error body = %q, want status-only", test.method, test.target, response.Body.String())
			}
		})
	}
}

func TestResponsesAndLogsExcludeRequestSecretsAndContent(t *testing.T) {
	var captured bytes.Buffer
	logger := logsafe.New(slog.New(slog.NewTextHandler(&captured, nil)))
	handler, _, _ := newTestHandlerWithLogger(t, true, logger)
	body := validEventBody()
	req := signedRequest(t, http.MethodPost, "application/json", body, testNow.Unix(), testNonce, "")
	signature := req.Header.Get("X-ThreadHub-Signature")
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, req)

	combined := response.Body.String() + captured.String()
	for _, forbidden := range []string{string(body), "recipient@example.test", testPostID, testUserID, testNonce, signature, "ThreadHub 고객지원", "private-channel"} {
		if strings.Contains(combined, forbidden) {
			t.Fatalf("response/log exposed forbidden request value %q in %q", forbidden, combined)
		}
	}
}

func newTestHandler(t *testing.T, enabled bool) (http.Handler, *store.SQLiteStore, *control.Watcher) {
	t.Helper()
	return newTestHandlerAt(t, filepath.Join(t.TempDir(), "queue.db"), enabled)
}

func newTestHandlerAt(t *testing.T, path string, enabled bool) (http.Handler, *store.SQLiteStore, *control.Watcher) {
	t.Helper()
	return newTestHandlerAtWithLogger(t, path, enabled, logsafe.New(nil))
}

func newTestHandlerWithLogger(t *testing.T, enabled bool, logger *logsafe.Logger) (http.Handler, *store.SQLiteStore, *control.Watcher) {
	t.Helper()
	return newTestHandlerAtWithLogger(t, filepath.Join(t.TempDir(), "queue.db"), enabled, logger)
}

func newTestHandlerAtWithLogger(t *testing.T, path string, enabled bool, logger *logsafe.Logger) (http.Handler, *store.SQLiteStore, *control.Watcher) {
	t.Helper()
	t.Setenv("THREADHUB_DOMAIN", "threadhub.example.test")
	controlPath := filepath.Join(filepath.Dir(path), "state.json")
	writeControl(t, controlPath, enabled, enabled)
	watcher, stop := runWatcher(t, controlPath)
	t.Cleanup(stop)
	queue := openQueue(t, path)
	return NewHandler(queue, watcher, testSecret, func() time.Time { return testNow }, logger), queue, watcher
}

func openQueue(t *testing.T, path string) *store.SQLiteStore {
	t.Helper()
	queue, err := store.Open(path, testSecret)
	if err != nil {
		t.Fatalf("store.Open() error = %v", err)
	}
	t.Cleanup(func() { _ = queue.Close() })
	return queue
}

func validEventBody() []byte {
	event := protocol.Event{
		EventID: testPostID, PostID: testPostID,
		Permalink:  "https://threadhub.example.test/_redirect/pl/" + testPostID,
		OccurredAt: testNow.UnixMilli(),
		Recipients: []protocol.Recipient{{UserID: testUserID, Email: "recipient@example.test"}},
	}
	body, err := json.Marshal(event)
	if err != nil {
		panic(err)
	}
	return body
}

func performSignedRequest(t *testing.T, handler http.Handler, method, contentType string, body []byte, timestamp int64, nonce, signature string) *httptest.ResponseRecorder {
	t.Helper()
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, signedRequest(t, method, contentType, body, timestamp, nonce, signature))
	return response
}

func signedRequest(t *testing.T, method, contentType string, body []byte, timestamp int64, nonce, signature string) *http.Request {
	t.Helper()
	req := httptest.NewRequest(method, "/v1/events", bytes.NewReader(body))
	req.Header.Set("Content-Type", contentType)
	req.Header.Set("X-ThreadHub-Timestamp", strconv.FormatInt(timestamp, 10))
	req.Header.Set("X-ThreadHub-Nonce", nonce)
	if signature == "" {
		signature = protocol.Sign(testSecret, timestamp, nonce, body)
	}
	req.Header.Set("X-ThreadHub-Signature", signature)
	return req
}

func writeControl(t *testing.T, path string, enabled, deliveryEnabled bool) {
	t.Helper()
	data := []byte(`{"enabled":` + boolJSON(enabled) + `,"delivery_enabled":` + boolJSON(deliveryEnabled) + `,"mode":"all_channels","channel_ids":[],"activated_at":1}`)
	if err := os.WriteFile(path, data, 0o600); err != nil {
		t.Fatalf("write control: %v", err)
	}
}

func boolJSON(value bool) string {
	if value {
		return "true"
	}
	return "false"
}

func runWatcher(t *testing.T, path string) (*control.Watcher, func()) {
	t.Helper()
	watcher := control.NewWatcher(path, 5*time.Millisecond)
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() {
		defer close(done)
		_ = watcher.Run(ctx)
	}()
	waitForControl(t, watcher, controlEnabledOnDisk(t, path))
	return watcher, func() {
		cancel()
		<-done
	}
}

func controlEnabledOnDisk(t *testing.T, path string) bool {
	t.Helper()
	state, err := control.Load(path)
	if err != nil {
		t.Fatalf("control.Load() error = %v", err)
	}
	return state.Enabled
}

func waitForControl(t *testing.T, watcher *control.Watcher, enabled bool) {
	t.Helper()
	deadline := time.Now().Add(time.Second)
	for time.Now().Before(deadline) {
		if watcher.Current().Enabled == enabled {
			return
		}
		time.Sleep(time.Millisecond)
	}
	t.Fatalf("watcher Enabled = %t, want %t", watcher.Current().Enabled, enabled)
}
