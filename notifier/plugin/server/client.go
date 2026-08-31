package server

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"time"

	"github.com/nugaing119/ThreadHub/notifier/protocol"
)

const mailerTimeout = 3 * time.Second

var (
	ErrMailerConfiguration = errors.New("invalid mailer client configuration")
	ErrMailerRequest       = errors.New("mailer request failed")
	ErrMailerRejected      = errors.New("mailer request not acknowledged")
)

type MailerClient struct {
	endpoint    *url.URL
	domain      string
	secret      []byte
	httpClient  *http.Client
	now         func() time.Time
	nonceReader io.Reader
}

func NewMailerClient(baseURL *url.URL, domain string, secret []byte, client *http.Client) *MailerClient {
	var clonedClient http.Client
	if client == nil {
		clonedClient = http.Client{}
	} else {
		clonedClient = *client
	}
	clonedClient.Transport = directMailerTransport(clonedClient.Transport)
	clonedClient.Timeout = mailerTimeout
	clonedClient.CheckRedirect = func(*http.Request, []*http.Request) error {
		return http.ErrUseLastResponse
	}

	var endpoint *url.URL
	if baseURL != nil {
		copyURL := *baseURL
		endpoint = copyURL.ResolveReference(&url.URL{Path: "/v1/events"})
	}
	return &MailerClient{
		endpoint: endpoint, domain: domain, secret: append([]byte(nil), secret...),
		httpClient: &clonedClient, now: time.Now, nonceReader: rand.Reader,
	}
}

func directMailerTransport(roundTripper http.RoundTripper) http.RoundTripper {
	if roundTripper == nil {
		if defaultTransport, ok := http.DefaultTransport.(*http.Transport); ok {
			roundTripper = defaultTransport
		} else {
			return &http.Transport{}
		}
	}
	if transport, ok := roundTripper.(*http.Transport); ok {
		direct := transport.Clone()
		// Never route signed recipient payloads through environment proxies.
		direct.Proxy = nil
		return direct
	}
	// A non-Transport RoundTripper is an explicit dependency injection seam;
	// ambient production clients never reach this branch.
	return roundTripper
}

func (c *MailerClient) Enqueue(ctx context.Context, event OutboxEvent, recipients []protocol.Recipient) error {
	if len(recipients) == 0 {
		return nil
	}
	if len(recipients) > 250 {
		return ErrRecipientLimit
	}
	if c == nil || c.endpoint == nil || c.httpClient == nil || c.now == nil || c.nonceReader == nil {
		return ErrMailerConfiguration
	}

	payload := protocol.Event{
		EventID:    event.PostID,
		PostID:     event.PostID,
		Permalink:  "https://" + c.domain + "/_redirect/pl/" + event.PostID,
		OccurredAt: event.CreateAt,
		Recipients: recipients,
	}
	if err := payload.Validate(c.domain); err != nil {
		return ErrMailerRequest
	}
	body, err := json.Marshal(payload)
	if err != nil {
		return ErrMailerRequest
	}
	nonce, err := protocol.NewNonce(c.nonceReader)
	if err != nil {
		return ErrMailerRequest
	}
	timestamp := c.now().Unix()
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, c.endpoint.String(), bytes.NewReader(body))
	if err != nil {
		return ErrMailerRequest
	}
	request.Header.Set("Content-Type", "application/json")
	request.Header.Set("X-ThreadHub-Timestamp", strconv.FormatInt(timestamp, 10))
	request.Header.Set("X-ThreadHub-Nonce", nonce)
	request.Header.Set("X-ThreadHub-Signature", protocol.Sign(c.secret, timestamp, nonce, body))

	response, err := c.httpClient.Do(request)
	if err != nil {
		return ErrMailerRequest
	}
	defer response.Body.Close()
	if response.StatusCode < http.StatusOK || response.StatusCode >= http.StatusMultipleChoices {
		return ErrMailerRejected
	}
	return nil
}
