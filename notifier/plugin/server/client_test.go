package server

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"reflect"
	"sort"
	"strconv"
	"sync/atomic"
	"testing"
	"time"

	"github.com/nugaing119/ThreadHub/notifier/protocol"
)

func TestMailerClientSendsOneMinimalSignedRequest(t *testing.T) {
	secret := bytes.Repeat([]byte{0x42}, 32)
	now := time.Date(2026, 8, 27, 5, 6, 7, 0, time.UTC)
	var requestCount int
	server := httptest.NewServer(http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		requestCount++
		if request.Method != http.MethodPost || request.URL.RequestURI() != "/v1/events" {
			t.Errorf("request target = %s %s, want POST /v1/events", request.Method, request.URL.RequestURI())
		}
		if got := request.Header.Get("Content-Type"); got != "application/json" {
			t.Errorf("Content-Type = %q, want application/json", got)
		}
		body, err := io.ReadAll(request.Body)
		if err != nil {
			t.Errorf("read request: %v", err)
			response.WriteHeader(http.StatusInternalServerError)
			return
		}
		var fields map[string]json.RawMessage
		if err := json.Unmarshal(body, &fields); err != nil {
			t.Errorf("decode body: %v", err)
		}
		wantFields := []string{"event_id", "occurred_at", "permalink", "post_id", "recipients"}
		gotFields := make([]string, 0, len(fields))
		for key := range fields {
			gotFields = append(gotFields, key)
		}
		sort.Strings(gotFields)
		if !reflect.DeepEqual(gotFields, wantFields) {
			t.Errorf("JSON fields = %v, want %v", gotFields, wantFields)
		}
		timestamp, err := strconv.ParseInt(request.Header.Get("X-ThreadHub-Timestamp"), 10, 64)
		if err != nil || timestamp != now.Unix() {
			t.Errorf("timestamp = %d, %v, want %d", timestamp, err, now.Unix())
		}
		nonce := request.Header.Get("X-ThreadHub-Nonce")
		if err := protocol.Verify(secret, timestamp, nonce, body, request.Header.Get("X-ThreadHub-Signature")); err != nil {
			t.Errorf("signature verification: %v", err)
		}
		var event protocol.Event
		if err := json.Unmarshal(body, &event); err != nil {
			t.Errorf("decode event: %v", err)
		}
		if event.EventID != testPostID || event.PostID != testPostID || event.Permalink != "https://threadhub.example.test/pl/"+testPostID || event.OccurredAt != 1787790000000 {
			t.Errorf("event = %#v, want exact outbox projection", event)
		}
		response.WriteHeader(http.StatusAccepted)
	}))
	defer server.Close()

	client := newTestMailerClient(t, server.URL, secret, now)
	recipients := []protocol.Recipient{{UserID: testRecipientID(1), Email: "recipient-001@example.test"}}
	if err := client.Enqueue(context.Background(), testOutboxEvent(testPostID), recipients); err != nil {
		t.Fatalf("Enqueue() error = %v", err)
	}
	if requestCount != 1 {
		t.Fatalf("request count = %d, want 1", requestCount)
	}
}

func TestMailerClientUsesFreshNonceForEveryEnqueueAttempt(t *testing.T) {
	secret := bytes.Repeat([]byte{0x42}, 32)
	now := time.Date(2026, 8, 27, 5, 6, 7, 0, time.UTC)
	var nonces []string
	server := httptest.NewServer(http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		nonces = append(nonces, request.Header.Get("X-ThreadHub-Nonce"))
		response.WriteHeader(http.StatusServiceUnavailable)
	}))
	defer server.Close()
	client := newTestMailerClient(t, server.URL, secret, now)
	client.nonceReader = bytes.NewReader(append(bytes.Repeat([]byte{0x11}, 16), bytes.Repeat([]byte{0x22}, 16)...))
	recipients := []protocol.Recipient{{UserID: testRecipientID(1), Email: "recipient-001@example.test"}}

	for range 2 {
		if err := client.Enqueue(context.Background(), testOutboxEvent(testPostID), recipients); err == nil {
			t.Fatal("Enqueue() accepted a 503 response")
		}
	}
	if want := []string{"11111111111111111111111111111111", "22222222222222222222222222222222"}; !reflect.DeepEqual(nonces, want) {
		t.Fatalf("nonces = %v, want fresh nonce per attempt %v", nonces, want)
	}
}

func TestMailerClientSendsOneRequestForOneThroughTwoHundredFiftyRecipients(t *testing.T) {
	for _, count := range []int{1, 250} {
		t.Run(strconv.Itoa(count), func(t *testing.T) {
			var requests int
			server := httptest.NewServer(http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
				requests++
				var event protocol.Event
				if err := json.NewDecoder(request.Body).Decode(&event); err != nil {
					t.Errorf("decode event: %v", err)
				}
				if len(event.Recipients) != count {
					t.Errorf("recipient count = %d, want %d", len(event.Recipients), count)
				}
				response.WriteHeader(http.StatusAccepted)
			}))
			defer server.Close()
			client := newTestMailerClient(t, server.URL, bytes.Repeat([]byte{0x42}, 32), time.Now())
			if err := client.Enqueue(context.Background(), testOutboxEvent(testPostID), testRecipients(count)); err != nil {
				t.Fatalf("Enqueue() error = %v", err)
			}
			if requests != 1 {
				t.Fatalf("request count = %d, want one request", requests)
			}
		})
	}
}

func TestMailerClientSkipsZeroRecipientsAndRejectsMoreThanTwoHundredFifty(t *testing.T) {
	var requests int
	server := httptest.NewServer(http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		requests++
		response.WriteHeader(http.StatusAccepted)
	}))
	defer server.Close()
	client := newTestMailerClient(t, server.URL, bytes.Repeat([]byte{0x42}, 32), time.Now())

	if err := client.Enqueue(context.Background(), testOutboxEvent(testPostID), nil); err != nil {
		t.Fatalf("zero-recipient Enqueue() error = %v, want no-op", err)
	}
	if err := client.Enqueue(context.Background(), testOutboxEvent(testPostID), testRecipients(251)); !errors.Is(err, ErrRecipientLimit) {
		t.Fatalf("251-recipient Enqueue() error = %v, want ErrRecipientLimit", err)
	}
	if requests != 0 {
		t.Fatalf("request count = %d, want no mailer calls", requests)
	}
}

func TestMailerClientAcknowledgesOnlyTwoHundredResponses(t *testing.T) {
	for _, test := range []struct {
		status  int
		wantErr bool
	}{{199, true}, {200, false}, {202, false}, {204, false}, {299, false}, {300, true}, {500, true}} {
		t.Run(strconv.Itoa(test.status), func(t *testing.T) {
			provided := &http.Client{Transport: roundTripperFunc(func(request *http.Request) (*http.Response, error) {
				return &http.Response{StatusCode: test.status, Header: make(http.Header), Body: io.NopCloser(bytes.NewReader(nil)), Request: request}, nil
			})}
			baseURL, err := url.Parse("http://mailer.test")
			if err != nil {
				t.Fatal(err)
			}
			client := NewMailerClient(baseURL, "threadhub.example.test", bytes.Repeat([]byte{0x42}, 32), provided)
			err = client.Enqueue(context.Background(), testOutboxEvent(testPostID), testRecipients(1))
			if (err != nil) != test.wantErr {
				t.Fatalf("Enqueue() error = %v, wantErr %v", err, test.wantErr)
			}
		})
	}
}

func TestMailerClientDoesNotFollowRedirects(t *testing.T) {
	var redirectedRequests int
	target := httptest.NewServer(http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		redirectedRequests++
		response.WriteHeader(http.StatusAccepted)
	}))
	defer target.Close()
	redirector := httptest.NewServer(http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		http.Redirect(response, request, target.URL+"/v1/events", http.StatusTemporaryRedirect)
	}))
	defer redirector.Close()

	client := newTestMailerClient(t, redirector.URL, bytes.Repeat([]byte{0x42}, 32), time.Now())
	if err := client.Enqueue(context.Background(), testOutboxEvent(testPostID), testRecipients(1)); err == nil {
		t.Fatal("Enqueue() acknowledged a redirect")
	}
	if redirectedRequests != 0 {
		t.Fatalf("redirect target requests = %d, want 0", redirectedRequests)
	}
}

func TestMailerClientClonesTransportAndEnforcesThreeSecondTimeout(t *testing.T) {
	transport := roundTripperFunc(func(*http.Request) (*http.Response, error) {
		return nil, context.DeadlineExceeded
	})
	provided := &http.Client{Transport: transport, Timeout: time.Minute}
	baseURL, err := url.Parse("http://mailer.test")
	if err != nil {
		t.Fatal(err)
	}
	client := NewMailerClient(baseURL, "threadhub.example.test", bytes.Repeat([]byte{0x42}, 32), provided)
	if client.httpClient == provided {
		t.Fatal("NewMailerClient reused caller-owned client instead of cloning it")
	}
	if _, ok := client.httpClient.Transport.(roundTripperFunc); !ok || client.httpClient.Timeout != 3*time.Second {
		t.Fatalf("client transport/timeout = %T/%s, want injected transport/3s", client.httpClient.Transport, client.httpClient.Timeout)
	}
	if provided.Timeout != time.Minute {
		t.Fatalf("provided client timeout mutated to %s", provided.Timeout)
	}
}

func TestMailerClientDisablesAmbientProxyForDefaultTransports(t *testing.T) {
	defaultTransport, ok := http.DefaultTransport.(*http.Transport)
	if !ok {
		t.Fatalf("http.DefaultTransport type = %T, want *http.Transport", http.DefaultTransport)
	}
	var proxyCalls atomic.Int32
	ambientTransport := defaultTransport.Clone()
	ambientTransport.Proxy = func(*http.Request) (*url.URL, error) {
		proxyCalls.Add(1)
		return nil, nil
	}
	previousDefault := http.DefaultTransport
	http.DefaultTransport = ambientTransport
	t.Cleanup(func() { http.DefaultTransport = previousDefault })

	server := httptest.NewServer(http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		response.WriteHeader(http.StatusAccepted)
	}))
	defer server.Close()
	probe, err := http.Get(server.URL)
	if err != nil {
		t.Fatalf("ambient proxy probe: %v", err)
	}
	_ = probe.Body.Close()
	if calls := proxyCalls.Swap(0); calls != 1 {
		t.Fatalf("ambient default proxy callback calls = %d, want 1 before hardening", calls)
	}

	providedTransport := ambientTransport.Clone()
	providedTransport.Proxy = ambientTransport.Proxy
	for _, test := range []struct {
		name      string
		provided  *http.Client
		transport *http.Transport
	}{
		{name: "nil client"},
		{name: "nil transport", provided: &http.Client{}},
		{name: "explicit http transport", provided: &http.Client{Transport: providedTransport}, transport: providedTransport},
	} {
		t.Run(test.name, func(t *testing.T) {
			baseURL, err := url.Parse(server.URL)
			if err != nil {
				t.Fatal(err)
			}
			client := NewMailerClient(baseURL, "threadhub.example.test", bytes.Repeat([]byte{0x42}, 32), test.provided)
			direct, ok := client.httpClient.Transport.(*http.Transport)
			if !ok {
				t.Fatalf("Mailer transport type = %T, want cloned *http.Transport", client.httpClient.Transport)
			}
			if direct == ambientTransport || direct == test.transport {
				t.Fatal("Mailer client reused a caller-owned or ambient transport")
			}
			if direct.Proxy != nil {
				t.Fatal("Mailer client retained ambient proxy selection")
			}
			if err := client.Enqueue(context.Background(), testOutboxEvent(testPostID), testRecipients(1)); err != nil {
				t.Fatalf("Enqueue() error = %v", err)
			}
			if calls := proxyCalls.Load(); calls != 0 {
				t.Fatalf("proxy callback calls during Enqueue() = %d, want 0", calls)
			}
			if test.transport != nil && test.transport.Proxy == nil {
				t.Fatal("NewMailerClient mutated caller-owned transport Proxy")
			}
		})
	}
}

func TestMailerClientReturnsErrorWhenTransportDoesNotAcknowledge(t *testing.T) {
	for _, transportErr := range []error{context.DeadlineExceeded, errors.New("recipient@example.test private-channel secret")} {
		provided := &http.Client{Transport: roundTripperFunc(func(*http.Request) (*http.Response, error) {
			return nil, transportErr
		})}
		baseURL, err := url.Parse("http://mailer.test")
		if err != nil {
			t.Fatal(err)
		}
		client := NewMailerClient(baseURL, "threadhub.example.test", bytes.Repeat([]byte{0x42}, 32), provided)
		err = client.Enqueue(context.Background(), testOutboxEvent(testPostID), testRecipients(1))
		if err == nil {
			t.Fatal("Enqueue() returned nil without a mailer acknowledgement")
		}
		for _, forbidden := range []string{"recipient@example.test", "private-channel", "secret"} {
			if bytes.Contains([]byte(err.Error()), []byte(forbidden)) {
				t.Fatalf("Enqueue() error exposed forbidden transport detail %q", forbidden)
			}
		}
	}
}

type roundTripperFunc func(*http.Request) (*http.Response, error)

func (f roundTripperFunc) RoundTrip(request *http.Request) (*http.Response, error) {
	return f(request)
}

func newTestMailerClient(t *testing.T, rawURL string, secret []byte, now time.Time) *MailerClient {
	t.Helper()
	baseURL, err := url.Parse(rawURL)
	if err != nil {
		t.Fatal(err)
	}
	client := NewMailerClient(baseURL, "threadhub.example.test", secret, &http.Client{})
	client.now = func() time.Time { return now }
	client.nonceReader = bytes.NewReader(bytes.Repeat([]byte{0x11}, 256))
	return client
}

func testRecipients(count int) []protocol.Recipient {
	recipients := make([]protocol.Recipient, count)
	for i := range recipients {
		recipients[i] = protocol.Recipient{UserID: testRecipientID(i + 1), Email: "recipient-" + strconv.Itoa(i+1) + "@example.test"}
	}
	return recipients
}
