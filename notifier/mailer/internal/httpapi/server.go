// Package httpapi exposes the mailer's authenticated internal ingest surface.
package httpapi

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"regexp"
	"strconv"
	"time"

	"github.com/nugaing119/ThreadHub/notifier/control"
	"github.com/nugaing119/ThreadHub/notifier/mailer/internal/logsafe"
	"github.com/nugaing119/ThreadHub/notifier/mailer/internal/store"
	"github.com/nugaing119/ThreadHub/notifier/protocol"
)

const maxEventBody = 1 << 20

var noncePattern = regexp.MustCompile(`^[0-9a-f]{32}$`)

type handler struct {
	queue       *store.SQLiteStore
	controls    *control.Watcher
	secret      []byte
	now         func() time.Time
	domain      string
	contentMode string
}

// NewHandler returns the complete network surface for the internal mailer.
func NewHandler(queue *store.SQLiteStore, controls *control.Watcher, secret []byte, domain, contentMode string, now func() time.Time, logger *logsafe.Logger) http.Handler {
	if now == nil {
		now = time.Now
	}
	_ = logger // Requests are deliberately not logged; aggregate delivery telemetry is logged elsewhere.
	h := &handler{
		queue: queue, controls: controls, secret: append([]byte(nil), secret...),
		now: now, domain: domain, contentMode: contentMode,
	}
	return http.HandlerFunc(h.dispatch)
}

func (h *handler) dispatch(response http.ResponseWriter, request *http.Request) {
	switch {
	case exactTarget(request, "/healthz"):
		if request.Method != http.MethodGet {
			response.WriteHeader(http.StatusMethodNotAllowed)
			return
		}
		h.health(response, request)
	case exactTarget(request, "/v1/events"):
		if request.Method != http.MethodPost {
			response.WriteHeader(http.StatusMethodNotAllowed)
			return
		}
		h.acceptEvent(response, request)
	default:
		response.WriteHeader(http.StatusNotFound)
	}
}

func exactTarget(request *http.Request, path string) bool {
	return request.URL != nil && request.URL.Path == path && request.URL.RawPath == "" &&
		request.URL.RawQuery == "" && !request.URL.ForceQuery && request.RequestURI == path
}

func (h *handler) health(response http.ResponseWriter, request *http.Request) {
	if h.queue == nil {
		response.WriteHeader(http.StatusServiceUnavailable)
		return
	}
	if _, err := h.queue.Status(request.Context(), h.now()); err != nil {
		response.WriteHeader(http.StatusServiceUnavailable)
		return
	}
	response.Header().Set("Content-Type", "text/plain; charset=utf-8")
	response.WriteHeader(http.StatusOK)
	_, _ = io.WriteString(response, "ok")
}

func (h *handler) acceptEvent(response http.ResponseWriter, request *http.Request) {
	if len(request.Header.Values("Content-Type")) != 1 || request.Header.Get("Content-Type") != "application/json" {
		response.WriteHeader(http.StatusUnsupportedMediaType)
		return
	}
	body, err := readBody(response, request)
	if err != nil {
		var tooLarge *http.MaxBytesError
		if errors.As(err, &tooLarge) {
			response.WriteHeader(http.StatusRequestEntityTooLarge)
		} else {
			response.WriteHeader(http.StatusBadRequest)
		}
		return
	}

	timestamp, nonce, signature, ok := authenticationHeaders(request)
	now := h.now()
	if !ok || timestamp < now.Unix()-300 || timestamp > now.Unix()+300 || protocol.Verify(h.secret, timestamp, nonce, body, signature) != nil {
		response.WriteHeader(http.StatusUnauthorized)
		return
	}
	if h.controls == nil || !h.controls.Current().Enabled {
		response.WriteHeader(http.StatusLocked)
		return
	}

	var event protocol.Event
	decoder := json.NewDecoder(bytes.NewReader(body))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&event); err != nil || requireJSONEnd(decoder) != nil ||
		event.Validate(h.domain) != nil || event.ValidateContentMode(h.contentMode) != nil {
		response.WriteHeader(http.StatusBadRequest)
		return
	}
	if h.queue == nil {
		response.WriteHeader(http.StatusServiceUnavailable)
		return
	}
	_, err = h.queue.Accept(request.Context(), protocol.HashIdentifier(h.secret, "nonce", nonce), event, now)
	switch {
	case errors.Is(err, store.ErrReplay):
		response.WriteHeader(http.StatusConflict)
	case err != nil:
		response.WriteHeader(http.StatusServiceUnavailable)
	default:
		response.WriteHeader(http.StatusAccepted)
	}
}

func readBody(response http.ResponseWriter, request *http.Request) ([]byte, error) {
	request.Body = http.MaxBytesReader(response, request.Body, maxEventBody)
	defer request.Body.Close()
	return io.ReadAll(request.Body)
}

func authenticationHeaders(request *http.Request) (int64, string, string, bool) {
	if len(request.Header.Values("X-ThreadHub-Timestamp")) != 1 || len(request.Header.Values("X-ThreadHub-Nonce")) != 1 || len(request.Header.Values("X-ThreadHub-Signature")) != 1 {
		return 0, "", "", false
	}
	timestamp, err := strconv.ParseInt(request.Header.Get("X-ThreadHub-Timestamp"), 10, 64)
	nonce := request.Header.Get("X-ThreadHub-Nonce")
	signature := request.Header.Get("X-ThreadHub-Signature")
	return timestamp, nonce, signature, err == nil && noncePattern.MatchString(nonce)
}

func requireJSONEnd(decoder *json.Decoder) error {
	var trailing any
	if err := decoder.Decode(&trailing); errors.Is(err, io.EOF) {
		return nil
	}
	return errors.New("invalid trailing JSON")
}
