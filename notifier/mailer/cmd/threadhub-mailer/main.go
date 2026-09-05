package main

import (
	"bufio"
	"bytes"
	"context"
	"crypto/x509"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"mime"
	"net"
	"net/http"
	"net/mail"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/nugaing119/ThreadHub/notifier/control"
	"github.com/nugaing119/ThreadHub/notifier/mailer/internal/adminnotice"
	"github.com/nugaing119/ThreadHub/notifier/mailer/internal/config"
	"github.com/nugaing119/ThreadHub/notifier/mailer/internal/httpapi"
	"github.com/nugaing119/ThreadHub/notifier/mailer/internal/logsafe"
	"github.com/nugaing119/ThreadHub/notifier/mailer/internal/message"
	"github.com/nugaing119/ThreadHub/notifier/mailer/internal/smtpclient"
	"github.com/nugaing119/ThreadHub/notifier/mailer/internal/store"
	"github.com/nugaing119/ThreadHub/notifier/mailer/internal/worker"
	"github.com/nugaing119/ThreadHub/notifier/protocol"
)

var (
	errUsage          = errors.New("invalid command")
	errRecipientInput = errors.New("recipient is required on stdin")
	errBackupAlert    = errors.New("invalid backup alert input")
	errSMTPAcceptance = errors.New("SMTP server did not return final 250 acceptance")
)

type smtpAcceptanceError struct {
	result smtpclient.Result
}

func (e *smtpAcceptanceError) Error() string { return errSMTPAcceptance.Error() }

type commandOperations struct {
	serve          func(context.Context, config.Config) error
	healthcheck    func(context.Context, config.Config) error
	status         func(context.Context, config.Config) (store.Status, error)
	smtpAcceptance func(context.Context, config.Config, string) smtpclient.Result
	backupAlert    func(context.Context, config.Config, string, string) smtpclient.Result
	retryFailed    func(context.Context, config.Config) (int64, error)
	cancelFailed   func(context.Context, config.Config) (int64, error)
}

type statusOutput struct {
	Pending              int64  `json:"pending"`
	Sending              int64  `json:"sending"`
	Sent                 int64  `json:"sent"`
	Failed               int64  `json:"failed"`
	OldestPendingSeconds int64  `json:"oldest_pending_seconds"`
	LastSuccessAt        int64  `json:"last_success_at"`
	LastErrorClass       string `json:"last_error_class"`
	LastSMTPCode         int    `json:"last_smtp_code"`
}

type configFingerprintOutput struct {
	ConfigFingerprint string `json:"config_fingerprint"`
}

type backupAlertInput struct {
	Recipient    string `json:"recipient"`
	FailureClass string `json:"failure_class"`
}

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	if exitCode := runMain(ctx, os.Args[1:], os.Stdin, os.Stdout, os.Stderr, os.Getenv, productionOperations()); exitCode != 0 {
		os.Exit(exitCode)
	}
}

func runMain(ctx context.Context, args []string, stdin io.Reader, stdout, stderr io.Writer, getenv func(string) string, operations commandOperations) int {
	if err := runCommand(ctx, args, stdin, stdout, getenv, operations); err != nil {
		var acceptanceError *smtpAcceptanceError
		if errors.As(err, &acceptanceError) {
			class := safeErrorClass(acceptanceError.result.Class.String())
			if class == "" {
				class = "protocol"
			}
			_, _ = fmt.Fprintf(stderr, "threadhub-mailer: command failed error_class=%s smtp_code=%d\n", class, safeSMTPCode(acceptanceError.result.Code))
		} else {
			_, _ = fmt.Fprintln(stderr, "threadhub-mailer: command failed")
		}
		return 1
	}
	return 0
}

func runCommand(ctx context.Context, args []string, stdin io.Reader, stdout io.Writer, getenv func(string) string, operations commandOperations) error {
	command, err := parseCommand(args)
	if err != nil {
		return err
	}
	if getenv == nil {
		return errUsage
	}
	cfg, err := config.Load(func(key string) string {
		value := getenv(key)
		if key == "NOTIFIER_LISTEN_ADDRESS" && value == "" {
			return ":8080"
		}
		return value
	})
	if err != nil {
		return err
	}

	switch command {
	case "serve":
		if operations.serve == nil {
			return errUsage
		}
		return operations.serve(ctx, cfg)
	case "healthcheck":
		if operations.healthcheck == nil {
			return errUsage
		}
		if err := operations.healthcheck(ctx, cfg); err != nil {
			return err
		}
		_, err := io.WriteString(stdout, "ok\n")
		return err
	case "status":
		if operations.status == nil {
			return errUsage
		}
		status, err := operations.status(ctx, cfg)
		if err != nil {
			return err
		}
		return writeStatus(stdout, status)
	case "smtp-test":
		if operations.smtpAcceptance == nil {
			return errUsage
		}
		recipient, err := readRecipient(stdin)
		if err != nil {
			return err
		}
		result := operations.smtpAcceptance(ctx, cfg, recipient)
		if !result.Accepted || result.Code != 250 {
			return &smtpAcceptanceError{result: result}
		}
		return writeConfigFingerprint(stdout, cfg)
	case "backup-alert":
		if operations.backupAlert == nil {
			return errUsage
		}
		input, err := readBackupAlertInput(stdin)
		if err != nil {
			return err
		}
		result := operations.backupAlert(ctx, cfg, input.Recipient, input.FailureClass)
		if !result.Accepted || result.Code != 250 {
			return &smtpAcceptanceError{result: result}
		}
		return nil
	case "config-fingerprint":
		return writeConfigFingerprint(stdout, cfg)
	case "retry-failed":
		if operations.retryFailed == nil {
			return errUsage
		}
		count, err := operations.retryFailed(ctx, cfg)
		if err != nil {
			return err
		}
		_, err = fmt.Fprintf(stdout, "{\"retried\":%d}\n", count)
		return err
	case "cancel-failed":
		if operations.cancelFailed == nil {
			return errUsage
		}
		count, err := operations.cancelFailed(ctx, cfg)
		if err != nil {
			return err
		}
		_, err = fmt.Fprintf(stdout, "{\"cancelled\":%d}\n", count)
		return err
	default:
		return errUsage
	}
}

func parseCommand(args []string) (string, error) {
	switch {
	case len(args) == 1 && args[0] == "serve":
		return "serve", nil
	case len(args) == 1 && args[0] == "healthcheck":
		return "healthcheck", nil
	case len(args) == 2 && args[0] == "status" && args[1] == "--json":
		return "status", nil
	case len(args) == 2 && args[0] == "smtp-test" && args[1] == "--recipient-stdin":
		return "smtp-test", nil
	case len(args) == 2 && args[0] == "backup-alert" && args[1] == "--json-stdin":
		return "backup-alert", nil
	case len(args) == 2 && args[0] == "config-fingerprint" && args[1] == "--json":
		return "config-fingerprint", nil
	case len(args) == 1 && args[0] == "retry-failed":
		return "retry-failed", nil
	case len(args) == 1 && args[0] == "cancel-failed":
		return "cancel-failed", nil
	default:
		return "", errUsage
	}
}

func writeConfigFingerprint(output io.Writer, cfg config.Config) error {
	return json.NewEncoder(output).Encode(configFingerprintOutput{
		ConfigFingerprint: cfg.SMTPConfigFingerprint(),
	})
}

func readRecipient(stdin io.Reader) (string, error) {
	if stdin == nil {
		return "", errRecipientInput
	}
	scanner := bufio.NewScanner(io.LimitReader(stdin, 513))
	scanner.Buffer(make([]byte, 64), 512)
	if !scanner.Scan() {
		return "", errRecipientInput
	}
	recipient := strings.TrimSpace(scanner.Text())
	if scanner.Scan() || scanner.Err() != nil || protocol.ValidateEmail(recipient) != nil {
		return "", errRecipientInput
	}
	return recipient, nil
}

func readBackupAlertInput(stdin io.Reader) (backupAlertInput, error) {
	if stdin == nil {
		return backupAlertInput{}, errBackupAlert
	}
	data, err := io.ReadAll(io.LimitReader(stdin, 1025))
	if err != nil || len(data) == 0 || len(data) > 1024 {
		return backupAlertInput{}, errBackupAlert
	}
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	var input backupAlertInput
	if err := decoder.Decode(&input); err != nil {
		return backupAlertInput{}, errBackupAlert
	}
	var trailing any
	if err := decoder.Decode(&trailing); !errors.Is(err, io.EOF) {
		return backupAlertInput{}, errBackupAlert
	}
	if protocol.ValidateEmail(input.Recipient) != nil || !adminnotice.ValidFailureClass(input.FailureClass) {
		return backupAlertInput{}, errBackupAlert
	}
	return input, nil
}

func writeStatus(output io.Writer, status store.Status) error {
	value := statusOutput{
		Pending: status.Pending, Sending: status.Sending, Sent: status.Sent,
		Failed:               status.FailedPermanent + status.FailedExhausted,
		OldestPendingSeconds: status.OldestPendingSeconds, LastSuccessAt: status.LastSuccessAt,
		LastErrorClass: safeErrorClass(status.LastErrorClass), LastSMTPCode: safeSMTPCode(status.LastSMTPCode),
	}
	return json.NewEncoder(output).Encode(value)
}

func safeErrorClass(value string) string {
	if value == "" {
		return ""
	}
	switch value {
	case "temporary", "permanent", "timeout", "protocol":
		return value
	default:
		return "protocol"
	}
}

func safeSMTPCode(value int) int {
	if value >= 100 && value <= 999 {
		return value
	}
	return 0
}

func productionOperations() commandOperations {
	return commandOperations{
		serve: defaultServe, healthcheck: defaultHealthcheck, status: defaultStatus,
		smtpAcceptance: defaultSMTPAcceptance, backupAlert: defaultBackupAlert,
		retryFailed: defaultRetryFailed, cancelFailed: defaultCancelFailed,
	}
}

func defaultStatus(ctx context.Context, cfg config.Config) (store.Status, error) {
	queue, err := store.Open(cfg.QueuePath, cfg.HMACSecret)
	if err != nil {
		return store.Status{}, err
	}
	defer queue.Close()
	return queue.Status(ctx, time.Now())
}

func defaultRetryFailed(ctx context.Context, cfg config.Config) (int64, error) {
	queue, err := store.Open(cfg.QueuePath, cfg.HMACSecret)
	if err != nil {
		return 0, err
	}
	defer queue.Close()
	return queue.RetryExhausted(ctx, time.Now())
}

func defaultCancelFailed(ctx context.Context, cfg config.Config) (int64, error) {
	queue, err := store.Open(cfg.QueuePath, cfg.HMACSecret)
	if err != nil {
		return 0, err
	}
	defer queue.Close()
	return queue.CancelFailed(ctx, time.Now())
}

func defaultHealthcheck(ctx context.Context, cfg config.Config) error {
	_, port, err := net.SplitHostPort(cfg.ListenAddress)
	if err != nil {
		return errors.New("healthcheck unavailable")
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, "http://127.0.0.1:"+port+"/healthz", nil)
	if err != nil {
		return errors.New("healthcheck unavailable")
	}
	client := &http.Client{
		Timeout:       3 * time.Second,
		Transport:     &http.Transport{Proxy: nil, DialContext: (&net.Dialer{Timeout: 3 * time.Second}).DialContext},
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
	}
	response, err := client.Do(request)
	if err != nil {
		return errors.New("healthcheck unavailable")
	}
	defer response.Body.Close()
	body, err := io.ReadAll(io.LimitReader(response.Body, 3))
	if err != nil || response.StatusCode != http.StatusOK || string(body) != "ok" {
		return errors.New("healthcheck unavailable")
	}
	return nil
}

func defaultSMTPAcceptance(ctx context.Context, cfg config.Config, recipient string) smtpclient.Result {
	return sendSMTPAcceptance(ctx, cfg, recipient, time.Now(), smtpclient.DefaultTransactionTimeout)
}

func defaultBackupAlert(ctx context.Context, cfg config.Config, recipient, failureClass string) smtpclient.Result {
	return sendBackupAlert(ctx, cfg, recipient, failureClass, time.Now(), smtpclient.DefaultTransactionTimeout, nil)
}

func sendBackupAlert(ctx context.Context, cfg config.Config, recipient, failureClass string, now time.Time, transactionTimeout time.Duration, roots *x509.CertPool) smtpclient.Result {
	opaqueID := protocol.HashIdentifier(
		cfg.HMACSecret,
		"backup-alert",
		recipient+"\n"+failureClass+"\n"+strconv.FormatInt(now.UnixNano(), 10),
	)
	rendered, err := adminnotice.Render(adminnotice.Input{
		FromName: cfg.FeedbackName, FromAddress: cfg.FromAddress, ReplyTo: cfg.ReplyTo,
		ToAddress: recipient, Domain: cfg.Domain, FailureClass: failureClass,
		OpaqueID: opaqueID, Date: now,
	})
	if err != nil {
		return smtpclient.Result{Class: smtpclient.ClassProtocol}
	}
	client := smtpclient.New(smtpclient.Config{
		Host: cfg.SMTPHost, Port: cfg.SMTPPort, Username: cfg.SMTPUsername,
		Password: cfg.SMTPPassword, DialTimeout: 10 * time.Second,
		TransactionTimeout: transactionTimeout,
	}, roots)
	return client.Send(ctx, rendered)
}

func sendSMTPAcceptance(ctx context.Context, cfg config.Config, recipient string, now time.Time, transactionTimeout time.Duration) smtpclient.Result {
	rendered, err := smtpTestMessage(cfg, recipient, now)
	if err != nil {
		return smtpclient.Result{Class: smtpclient.ClassProtocol}
	}
	client := smtpclient.New(smtpclient.Config{
		Host: cfg.SMTPHost, Port: cfg.SMTPPort, Username: cfg.SMTPUsername,
		Password: cfg.SMTPPassword, DialTimeout: 10 * time.Second,
		TransactionTimeout: transactionTimeout,
	}, nil)
	return client.Send(ctx, rendered)
}

func smtpTestMessage(cfg config.Config, recipient string, now time.Time) (message.Message, error) {
	if protocol.ValidateEmail(recipient) != nil || now.IsZero() {
		return message.Message{}, errRecipientInput
	}
	from := (&mail.Address{Name: cfg.FeedbackName, Address: cfg.FromAddress}).String()
	to := (&mail.Address{Address: recipient}).String()
	subject := mime.BEncoding.Encode("UTF-8", "[ThreadHub] 알림 SMTP 테스트")
	opaque := protocol.HashIdentifier(cfg.HMACSecret, "smtp-test", recipient+"\n"+strconv.FormatInt(now.UnixNano(), 10))
	headers := []string{
		"From: " + from,
		"To: " + to,
		"Reply-To: " + cfg.ReplyTo,
		"Subject: " + subject,
		"Date: " + now.UTC().Format(time.RFC1123Z),
		"Message-ID: <" + opaque + "@" + cfg.Domain + ">",
		"MIME-Version: 1.0",
		"Content-Type: text/plain; charset=UTF-8",
		"Content-Transfer-Encoding: 8bit",
	}
	body := "ThreadHub 알림 SMTP 테스트입니다.\r\nSMTP 서버의 최종 접수 여부만 확인하며 받은편지함 도착, SPF, DKIM은 별도로 확인해 주세요.\r\n"
	data := []byte(strings.Join(headers, "\r\n") + "\r\n\r\n" + body)
	return message.Message{EnvelopeFrom: cfg.FromAddress, EnvelopeTo: recipient, Data: data}, nil
}

func newHTTPServer(address string, handler http.Handler) *http.Server {
	if address == "" {
		address = ":8080"
	}
	return &http.Server{
		Addr: address, Handler: handler,
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       10 * time.Second,
		WriteTimeout:      10 * time.Second,
		IdleTimeout:       30 * time.Second,
	}
}

func defaultServe(ctx context.Context, cfg config.Config) error {
	queue, err := store.Open(cfg.QueuePath, cfg.HMACSecret)
	if err != nil {
		return err
	}
	controls := control.NewWatcher(cfg.ControlFile, time.Second)
	sender := smtpclient.New(smtpclient.Config{
		Host: cfg.SMTPHost, Port: cfg.SMTPPort, Username: cfg.SMTPUsername,
		Password: cfg.SMTPPassword, DialTimeout: 10 * time.Second,
		TransactionTimeout: smtpclient.DefaultTransactionTimeout,
	}, nil)
	deliveryWorker := worker.New(queue, func(delivery store.Delivery) (message.Message, error) {
		return message.Render(message.Input{
			FromName: cfg.FeedbackName, FromAddress: cfg.FromAddress, ReplyTo: cfg.ReplyTo,
			ToAddress: delivery.Email, Domain: cfg.Domain, EventHash: delivery.Key.EventHash,
			RecipientHash: delivery.Key.RecipientHash, Permalink: delivery.Permalink, Date: time.Now(),
			ContentMode: cfg.ContentMode, TeamName: delivery.TeamName, ChannelName: delivery.ChannelName,
			EventType: delivery.EventType,
		})
	}, sender, controls, nil, worker.Config{RatePerMinute: cfg.RatePerMinute})
	handler := httpapi.NewHandler(queue, controls, cfg.HMACSecret, cfg.Domain, cfg.ContentMode, time.Now, logsafe.New(nil))
	server := newHTTPServer(cfg.ListenAddress, handler)
	return serve(ctx, server, queue, controls, deliveryWorker)
}

type runner interface {
	Run(context.Context) error
	Ready() <-chan struct{}
}

func serve(ctx context.Context, server *http.Server, queue *store.SQLiteStore, controls runner, deliveryWorker runner) error {
	listener, err := net.Listen("tcp", server.Addr)
	if err != nil {
		_ = queue.Close()
		return err
	}
	return serveOnListener(ctx, server, queue, controls, deliveryWorker, listener)
}

func serveOnListener(ctx context.Context, server *http.Server, queue *store.SQLiteStore, controls runner, deliveryWorker runner, listener net.Listener) error {
	serviceCtx, cancel := context.WithCancel(context.Background())
	var closeOnce bool
	closeQueue := func() error {
		if closeOnce {
			return nil
		}
		closeOnce = true
		return queue.Close()
	}

	watcherDone := make(chan error, 1)
	go func() { watcherDone <- controls.Run(serviceCtx) }()
	workerDone := make(chan error, 1)
	go func() { workerDone <- deliveryWorker.Run(serviceCtx) }()

	watcherReady := controls.Ready()
	workerReady := deliveryWorker.Ready()
	var lifecycleErr error
	var watcherFinished, workerFinished bool
	for watcherReady != nil || workerReady != nil {
		select {
		case <-watcherReady:
			watcherReady = nil
		case <-workerReady:
			workerReady = nil
		case err := <-watcherDone:
			watcherFinished = true
			lifecycleErr = unexpectedRunnerExit("watcher", err)
		case err := <-workerDone:
			workerFinished = true
			lifecycleErr = unexpectedRunnerExit("worker", err)
		case <-ctx.Done():
			lifecycleErr = nil
		}
		if lifecycleErr != nil || ctx.Err() != nil {
			break
		}
	}

	serverDone := make(chan error, 1)
	serverStarted := lifecycleErr == nil && ctx.Err() == nil
	serverFinished := false
	if serverStarted {
		go func() { serverDone <- server.Serve(listener) }()
		select {
		case err := <-serverDone:
			serverFinished = true
			lifecycleErr = unexpectedServerExit(err)
		case err := <-watcherDone:
			watcherFinished = true
			lifecycleErr = unexpectedRunnerExit("watcher", err)
		case err := <-workerDone:
			workerFinished = true
			lifecycleErr = unexpectedRunnerExit("worker", err)
		case <-ctx.Done():
			lifecycleErr = nil
		}
	}

	_ = listener.Close() // Stop HTTP accepts before cancelling delivery work.
	cancel()
	drainCtx, drainCancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer drainCancel()
	var shutdownErr error
	if serverStarted {
		shutdownErr = server.Shutdown(drainCtx)
		if !serverFinished {
			select {
			case err := <-serverDone:
				serverFinished = true
				if lifecycleErr == nil {
					lifecycleErr = expectedServerShutdownError(err)
				}
			case <-drainCtx.Done():
				shutdownErr = errors.Join(shutdownErr, drainCtx.Err())
			}
		}
	}
	if !workerFinished {
		select {
		case err := <-workerDone:
			workerFinished = true
			if lifecycleErr == nil && err != nil {
				lifecycleErr = fmt.Errorf("worker shutdown: %w", err)
			}
		case <-drainCtx.Done():
			shutdownErr = errors.Join(shutdownErr, drainCtx.Err())
		}
	}
	if !watcherFinished {
		select {
		case err := <-watcherDone:
			watcherFinished = true
			if lifecycleErr == nil && err != nil {
				lifecycleErr = fmt.Errorf("watcher shutdown: %w", err)
			}
		case <-drainCtx.Done():
			shutdownErr = errors.Join(shutdownErr, drainCtx.Err())
		}
	}
	closeErr := closeQueue()
	return errors.Join(lifecycleErr, shutdownErr, closeErr)
}

func unexpectedRunnerExit(name string, err error) error {
	if err == nil {
		return fmt.Errorf("%s exited unexpectedly", name)
	}
	return fmt.Errorf("%s exited unexpectedly: %w", name, err)
}

func unexpectedServerExit(err error) error {
	if err == nil {
		return errors.New("HTTP server exited unexpectedly")
	}
	if errors.Is(err, http.ErrServerClosed) || errors.Is(err, net.ErrClosed) {
		return nil
	}
	return err
}

func expectedServerShutdownError(err error) error {
	if errors.Is(err, http.ErrServerClosed) || errors.Is(err, net.ErrClosed) {
		return nil
	}
	return err
}
