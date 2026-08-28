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
	ClassNone                 ErrorClass = ""
	ClassTemporary            ErrorClass = "temporary"
	ClassPermanent            ErrorClass = "permanent"
	ClassTimeout              ErrorClass = "timeout"
	ClassProtocol             ErrorClass = "protocol"
	DefaultTransactionTimeout            = 30 * time.Second
)

func (c ErrorClass) String() string { return string(c) }

type Config struct {
	Host, Username, Password string
	Port                     int
	DialTimeout              time.Duration
	TransactionTimeout       time.Duration
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
	transactionTimeout := c.config.TransactionTimeout
	if transactionTimeout <= 0 {
		transactionTimeout = DefaultTransactionTimeout
	}
	transactionCtx, cancelTransaction := context.WithTimeout(ctx, transactionTimeout)
	defer cancelTransaction()
	timeout := c.config.DialTimeout
	if timeout <= 0 {
		timeout = 10 * time.Second
	}
	conn, err := (&net.Dialer{Timeout: timeout}).DialContext(transactionCtx, "tcp", net.JoinHostPort(c.config.Host, strconv.Itoa(c.config.Port)))
	if err != nil {
		return classify(err)
	}
	defer conn.Close()
	if deadline, ok := transactionCtx.Deadline(); ok {
		if err := conn.SetDeadline(deadline); err != nil {
			return classify(contextErr(transactionCtx, err))
		}
	}
	done := make(chan struct{})
	defer close(done)
	go func() {
		select {
		case <-transactionCtx.Done():
			_ = conn.Close()
		case <-done:
		}
	}()

	client, err := smtp.NewClient(conn, c.config.Host)
	if err != nil {
		return classify(contextErr(transactionCtx, err))
	}
	defer client.Close()
	if err := client.Hello(c.config.Host); err != nil {
		return classify(contextErr(transactionCtx, err))
	}
	ok, _ := client.Extension("STARTTLS")
	if !ok {
		return Result{Class: ClassPermanent}
	}
	if err := client.StartTLS(&tls.Config{ServerName: c.config.Host, MinVersion: tls.VersionTLS12, RootCAs: c.roots}); err != nil {
		return classify(contextErr(transactionCtx, err))
	}
	if err := client.Auth(smtp.PlainAuth("", c.config.Username, c.config.Password, c.config.Host)); err != nil {
		return classify(contextErr(transactionCtx, err))
	}
	if err := client.Mail(message.EnvelopeFrom); err != nil {
		return classify(contextErr(transactionCtx, err))
	}
	if err := client.Rcpt(message.EnvelopeTo); err != nil {
		return classify(contextErr(transactionCtx, err))
	}
	writer, err := client.Data()
	if err != nil {
		return classify(contextErr(transactionCtx, err))
	}
	if _, err := writer.Write(message.Data); err != nil {
		_ = writer.Close()
		return classify(contextErr(transactionCtx, err))
	}
	if err := writer.Close(); err != nil {
		return classify(contextErr(transactionCtx, err))
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
	if errors.Is(err, context.DeadlineExceeded) {
		return Result{Class: ClassTimeout}
	}
	if errors.Is(err, context.Canceled) {
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
	if strings.Contains(err.Error(), "certificate") || strings.Contains(err.Error(), "x509") {
		return Result{Class: ClassPermanent}
	}
	var netErr net.Error
	if errors.As(err, &netErr) {
		if netErr.Timeout() {
			return Result{Class: ClassTimeout}
		}
		return Result{Class: ClassTemporary}
	}
	return Result{Class: ClassProtocol}
}
