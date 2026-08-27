// Package smtpclient sends rendered notices only over verified STARTTLS SMTP.
package smtpclient

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"errors"
	"net"
	"net/smtp"
	"net/textproto"
	"strconv"
	"strings"
	"time"

	"github.com/nugaing119/ThreadHub/notifier/mailer/internal/message"
)

type ErrorClass string

const (
	ClassNone      ErrorClass = ""
	ClassTemporary ErrorClass = "temporary"
	ClassPermanent ErrorClass = "permanent"
	ClassTimeout   ErrorClass = "timeout"
	ClassProtocol  ErrorClass = "protocol"
)

func (c ErrorClass) String() string { return string(c) }

type Config struct {
	Host, Username, Password string
	Port                     int
	DialTimeout              time.Duration
}
type Result struct {
	Accepted bool
	Class    ErrorClass
	Code     int
}
type Client struct {
	config Config
	roots  *x509.CertPool
}

func New(config Config, roots *x509.CertPool) *Client { return &Client{config: config, roots: roots} }

func (c *Client) Send(ctx context.Context, message message.Message) Result {
	if ctx == nil {
		ctx = context.Background()
	}
	if c == nil || c.config.Host == "" || c.config.Port < 1 || c.config.Port > 65535 || message.EnvelopeFrom == "" || message.EnvelopeTo == "" || len(message.Data) == 0 {
		return Result{Class: ClassProtocol}
	}
	timeout := c.config.DialTimeout
	if timeout <= 0 {
		timeout = 10 * time.Second
	}
	conn, err := (&net.Dialer{Timeout: timeout}).DialContext(ctx, "tcp", net.JoinHostPort(c.config.Host, strconv.Itoa(c.config.Port)))
	if err != nil {
		return classify(err)
	}
	defer conn.Close()
	done := make(chan struct{})
	defer close(done)
	go func() {
		select {
		case <-ctx.Done():
			_ = conn.Close()
		case <-done:
		}
	}()

	client, err := smtp.NewClient(conn, c.config.Host)
	if err != nil {
		return classify(contextErr(ctx, err))
	}
	defer client.Close()
	if err := client.Hello(c.config.Host); err != nil {
		return classify(contextErr(ctx, err))
	}
	ok, _ := client.Extension("STARTTLS")
	if !ok {
		return Result{Class: ClassPermanent}
	}
	if err := client.StartTLS(&tls.Config{ServerName: c.config.Host, MinVersion: tls.VersionTLS12, RootCAs: c.roots}); err != nil {
		return classify(contextErr(ctx, err))
	}
	if err := client.Auth(smtp.PlainAuth("", c.config.Username, c.config.Password, c.config.Host)); err != nil {
		return classify(contextErr(ctx, err))
	}
	if err := client.Mail(message.EnvelopeFrom); err != nil {
		return classify(contextErr(ctx, err))
	}
	if err := client.Rcpt(message.EnvelopeTo); err != nil {
		return classify(contextErr(ctx, err))
	}
	writer, err := client.Data()
	if err != nil {
		return classify(contextErr(ctx, err))
	}
	if _, err := writer.Write(message.Data); err != nil {
		_ = writer.Close()
		return classify(contextErr(ctx, err))
	}
	if err := writer.Close(); err != nil {
		return classify(contextErr(ctx, err))
	}
	return Result{Accepted: true, Class: ClassNone, Code: 250}
}

func contextErr(ctx context.Context, err error) error {
	if ctx.Err() != nil {
		return ctx.Err()
	}
	return err
}
func classify(err error) Result {
	if errors.Is(err, context.DeadlineExceeded) || errors.Is(err, context.Canceled) {
		return Result{Class: ClassTemporary}
	}
	var smtpErr *textproto.Error
	if errors.As(err, &smtpErr) {
		if smtpErr.Code >= 500 {
			return Result{Class: ClassPermanent, Code: smtpErr.Code}
		}
		if smtpErr.Code >= 400 {
			return Result{Class: ClassTemporary, Code: smtpErr.Code}
		}
		return Result{Class: ClassProtocol, Code: smtpErr.Code}
	}
	var netErr net.Error
	if errors.As(err, &netErr) && netErr.Timeout() {
		return Result{Class: ClassTemporary}
	}
	if strings.Contains(err.Error(), "certificate") || strings.Contains(err.Error(), "x509") {
		return Result{Class: ClassPermanent}
	}
	return Result{Class: ClassProtocol}
}
