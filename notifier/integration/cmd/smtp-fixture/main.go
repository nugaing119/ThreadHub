package main

import (
	"bufio"
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"errors"
	"io"
	"log"
	"math/big"
	"mime"
	"mime/multipart"
	"net"
	"net/http"
	"net/mail"
	"net/textproto"
	"net/url"
	"os"
	"os/signal"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/nugaing119/ThreadHub/notifier/protocol"
)

const (
	maxMessageBytes      = 1 << 20
	maxCaptureStateBytes = 1 << 20
	noticeSubject        = "[ThreadHub] 새 메시지가 등록되었습니다"
)

type capture struct {
	RecipientHash   string `json:"recipient_hash"`
	EnvelopeCount   int    `json:"envelope_count"`
	GenericContent  bool   `json:"generic_content"`
	LastAttemptAtMS int64  `json:"last_attempt_at_ms"`
}

type captureSnapshot struct {
	Captures []capture `json:"captures"`
}

type captureStore struct {
	mu                sync.Mutex
	secret            []byte
	domain            string
	statePath         string
	captures          map[string]capture
	temporaryFailures int
}

func newCaptureStore(secret []byte, domain string) *captureStore {
	return &captureStore{
		secret: append([]byte(nil), secret...), domain: domain,
		captures: make(map[string]capture),
	}
}

func newPersistentCaptureStore(secret []byte, domain, statePath string) (*captureStore, error) {
	if !filepath.IsAbs(statePath) || filepath.Base(statePath) != "captures.json" {
		return nil, errors.New("invalid capture state path")
	}
	snapshot, err := loadCaptureSnapshot(statePath)
	if err != nil {
		return nil, err
	}
	store := newCaptureStore(secret, domain)
	store.statePath = statePath
	for _, value := range snapshot.Captures {
		store.captures[value.RecipientHash] = value
	}
	return store, nil
}

func (s *captureStore) record(recipient string, raw []byte) (bool, error) {
	return s.recordAt(recipient, raw, time.Now().UTC())
}

func (s *captureStore) recordAt(recipient string, raw []byte, attemptAt time.Time) (bool, error) {
	if attemptAt.UnixMilli() <= 0 {
		return false, errors.New("invalid capture time")
	}
	hash := protocol.HashIdentifier(s.secret, "integration-recipient", strings.ToLower(recipient))
	generic := inspectGenericMessage(raw, s.domain)
	s.mu.Lock()
	defer s.mu.Unlock()
	next := make(map[string]capture, len(s.captures)+1)
	for key, value := range s.captures {
		next[key] = value
	}
	current := next[hash]
	current.RecipientHash = hash
	current.EnvelopeCount++
	current.LastAttemptAtMS = attemptAt.UnixMilli()
	if current.EnvelopeCount == 1 {
		current.GenericContent = generic
	} else {
		current.GenericContent = current.GenericContent && generic
	}
	next[hash] = current
	if s.statePath != "" {
		if err := writeCaptureSnapshot(s.statePath, snapshotFromCaptures(next)); err != nil {
			return false, err
		}
	}
	s.captures = next
	return generic, nil
}

func (s *captureStore) snapshot() captureSnapshot {
	s.mu.Lock()
	defer s.mu.Unlock()
	return snapshotFromCaptures(s.captures)
}

func snapshotFromCaptures(values map[string]capture) captureSnapshot {
	result := captureSnapshot{Captures: make([]capture, 0, len(values))}
	for _, value := range values {
		result.Captures = append(result.Captures, value)
	}
	sort.Slice(result.Captures, func(i, j int) bool {
		return result.Captures[i].RecipientHash < result.Captures[j].RecipientHash
	})
	return result
}

func loadCaptureSnapshot(statePath string) (captureSnapshot, error) {
	info, err := os.Lstat(statePath)
	if errors.Is(err, os.ErrNotExist) {
		return captureSnapshot{Captures: []capture{}}, nil
	}
	if err != nil || !info.Mode().IsRegular() || info.Mode().Perm() != 0o600 || info.Size() <= 0 || info.Size() > maxCaptureStateBytes {
		return captureSnapshot{}, errors.New("invalid capture state")
	}
	file, err := os.Open(statePath)
	if err != nil {
		return captureSnapshot{}, errors.New("invalid capture state")
	}
	defer file.Close()
	decoder := json.NewDecoder(io.LimitReader(file, maxCaptureStateBytes+1))
	decoder.DisallowUnknownFields()
	var snapshot captureSnapshot
	if err := decoder.Decode(&snapshot); err != nil || snapshot.Captures == nil {
		return captureSnapshot{}, errors.New("invalid capture state")
	}
	var extra any
	if err := decoder.Decode(&extra); err != io.EOF || !validCaptureSnapshot(snapshot) {
		return captureSnapshot{}, errors.New("invalid capture state")
	}
	return snapshot, nil
}

func validCaptureSnapshot(snapshot captureSnapshot) bool {
	seen := make(map[string]struct{}, len(snapshot.Captures))
	for _, value := range snapshot.Captures {
		if len(value.RecipientHash) != 64 || value.EnvelopeCount < 1 || value.LastAttemptAtMS <= 0 {
			return false
		}
		for _, character := range value.RecipientHash {
			if (character < '0' || character > '9') && (character < 'a' || character > 'f') {
				return false
			}
		}
		if _, exists := seen[value.RecipientHash]; exists {
			return false
		}
		seen[value.RecipientHash] = struct{}{}
	}
	return true
}

func writeCaptureSnapshot(statePath string, snapshot captureSnapshot) error {
	if !validCaptureSnapshot(snapshot) {
		return errors.New("invalid capture state")
	}
	var encoded bytes.Buffer
	encoder := json.NewEncoder(&encoded)
	encoder.SetEscapeHTML(false)
	if err := encoder.Encode(snapshot); err != nil || encoded.Len() > maxCaptureStateBytes {
		return errors.New("invalid capture state")
	}
	temporary, err := os.CreateTemp(filepath.Dir(statePath), ".captures.*")
	if err != nil {
		return err
	}
	temporaryPath := temporary.Name()
	defer os.Remove(temporaryPath)
	if err := temporary.Chmod(0o600); err != nil {
		_ = temporary.Close()
		return err
	}
	if _, err := temporary.Write(encoded.Bytes()); err != nil {
		_ = temporary.Close()
		return err
	}
	if err := temporary.Sync(); err != nil {
		_ = temporary.Close()
		return err
	}
	if err := temporary.Close(); err != nil {
		return err
	}
	return os.Rename(temporaryPath, statePath)
}

func (s *captureStore) failNext() {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.temporaryFailures++
}

func (s *captureStore) consumeFailure() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.temporaryFailures == 0 {
		return false
	}
	s.temporaryFailures--
	return true
}

func inspectGenericMessage(raw []byte, domain string) bool {
	message, err := mail.ReadMessage(bytes.NewReader(raw))
	if err != nil || len(message.Header["To"]) != 1 || message.Header.Get("Cc") != "" || message.Header.Get("Bcc") != "" {
		return false
	}
	to, err := mail.ParseAddressList(message.Header.Get("To"))
	if err != nil || len(to) != 1 {
		return false
	}
	from, err := mail.ParseAddress(message.Header.Get("From"))
	if err != nil || from.Name != "ThreadHub" || from.Address != "no-reply@integration.invalid" || message.Header.Get("Reply-To") != "feedback@integration.invalid" {
		return false
	}
	decodedSubject, err := new(mime.WordDecoder).DecodeHeader(message.Header.Get("Subject"))
	if err != nil || decodedSubject != noticeSubject {
		return false
	}
	mediaType, params, err := mime.ParseMediaType(message.Header.Get("Content-Type"))
	if err != nil || mediaType != "multipart/alternative" || params["boundary"] == "" {
		return false
	}
	reader := multipart.NewReader(message.Body, params["boundary"])
	plainPart, err := reader.NextPart()
	if err != nil || !strings.HasPrefix(plainPart.Header.Get("Content-Type"), "text/plain") {
		return false
	}
	plain, err := io.ReadAll(io.LimitReader(plainPart, maxMessageBytes+1))
	if err != nil || len(plain) > maxMessageBytes {
		return false
	}
	htmlPart, err := reader.NextPart()
	if err != nil || !strings.HasPrefix(htmlPart.Header.Get("Content-Type"), "text/html") {
		return false
	}
	html, err := io.ReadAll(io.LimitReader(htmlPart, maxMessageBytes+1))
	if err != nil || len(html) > maxMessageBytes {
		return false
	}
	if _, err := reader.NextPart(); !errors.Is(err, io.EOF) {
		return false
	}
	plainText := canonicalCRLF(plain)
	htmlText := canonicalCRLF(html)
	permalink := noticePermalink(plainText, domain)
	if permalink == "" {
		return false
	}
	wantPlain := "ThreadHub에 새 메시지가 등록되었습니다.\r\n로그인하여 확인해 주세요.\r\n\r\n[메시지 확인]\r\n" + permalink + "\r\n"
	wantHTML := "<p>ThreadHub에 새 메시지가 등록되었습니다.<br>로그인하여 확인해 주세요.</p><p><a href=\"" + permalink + "\">메시지 확인</a></p>\r\n"
	postID := strings.TrimPrefix(permalink, "https://"+domain+"/_redirect/pl/")
	return plainText == wantPlain && htmlText == wantHTML &&
		!strings.Contains(message.Header.Get("Message-ID"), postID)
}

func canonicalCRLF(value []byte) string {
	normalized := strings.ReplaceAll(string(value), "\r\n", "\n")
	return strings.ReplaceAll(normalized, "\n", "\r\n")
}

func noticePermalink(plain, domain string) string {
	prefix := "ThreadHub에 새 메시지가 등록되었습니다.\r\n로그인하여 확인해 주세요.\r\n\r\n[메시지 확인]\r\n"
	if !strings.HasPrefix(plain, prefix) {
		return ""
	}
	value := strings.TrimSuffix(strings.TrimPrefix(plain, prefix), "\r\n")
	u, err := url.Parse(value)
	if err != nil || u.Scheme != "https" || u.Host != domain || u.User != nil || u.RawQuery != "" || u.Fragment != "" || u.ForceQuery {
		return ""
	}
	postID := strings.TrimPrefix(u.EscapedPath(), "/_redirect/pl/")
	if u.EscapedPath() != "/_redirect/pl/"+postID || len(postID) != 26 {
		return ""
	}
	for _, character := range postID {
		if (character < 'a' || character > 'z') && (character < '0' || character > '9') {
			return ""
		}
	}
	return value
}

func ensureCertificate(dir, host string, now time.Time) error {
	paths := []string{filepath.Join(dir, "ca.crt"), filepath.Join(dir, "server.crt"), filepath.Join(dir, "server.key")}
	allPresent := true
	for _, path := range paths {
		if _, err := os.Stat(path); err != nil {
			allPresent = false
			break
		}
	}
	if allPresent {
		return nil
	}
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	caKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return err
	}
	caTemplate := &x509.Certificate{
		SerialNumber: randomSerial(), Subject: pkix.Name{CommonName: "ThreadHub integration CA"},
		NotBefore: now.Add(-time.Minute), NotAfter: now.Add(2 * time.Hour), IsCA: true,
		BasicConstraintsValid: true, KeyUsage: x509.KeyUsageCertSign | x509.KeyUsageDigitalSignature,
	}
	caDER, err := x509.CreateCertificate(rand.Reader, caTemplate, caTemplate, &caKey.PublicKey, caKey)
	if err != nil {
		return err
	}
	serverKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return err
	}
	serverTemplate := &x509.Certificate{
		SerialNumber: randomSerial(), Subject: pkix.Name{CommonName: host}, DNSNames: []string{host},
		NotBefore: now.Add(-time.Minute), NotAfter: now.Add(2 * time.Hour),
		KeyUsage: x509.KeyUsageDigitalSignature, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
	}
	serverDER, err := x509.CreateCertificate(rand.Reader, serverTemplate, caTemplate, &serverKey.PublicKey, caKey)
	if err != nil {
		return err
	}
	keyDER, err := x509.MarshalPKCS8PrivateKey(serverKey)
	if err != nil {
		return err
	}
	files := []struct {
		path  string
		block *pem.Block
	}{
		{paths[0], &pem.Block{Type: "CERTIFICATE", Bytes: caDER}},
		{paths[1], &pem.Block{Type: "CERTIFICATE", Bytes: serverDER}},
		{paths[2], &pem.Block{Type: "PRIVATE KEY", Bytes: keyDER}},
	}
	for _, file := range files {
		if err := writePrivatePEM(file.path, file.block); err != nil {
			return err
		}
	}
	return nil
}

func randomSerial() *big.Int {
	var raw [16]byte
	_, _ = io.ReadFull(rand.Reader, raw[:])
	return new(big.Int).SetBytes(raw[:])
}

func writePrivatePEM(path string, block *pem.Block) error {
	file, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		return err
	}
	err = pem.Encode(file, block)
	return errors.Join(err, file.Close())
}

func publishCA(source, destination string) error {
	raw, err := os.ReadFile(source)
	if err != nil || len(raw) == 0 || len(raw) > 64<<10 {
		return errors.New("invalid runtime CA")
	}
	block, trailing := pem.Decode(raw)
	if block == nil || block.Type != "CERTIFICATE" || len(bytes.TrimSpace(trailing)) != 0 {
		return errors.New("invalid runtime CA")
	}
	if _, err := x509.ParseCertificate(block.Bytes); err != nil {
		return errors.New("invalid runtime CA")
	}
	temporary, err := os.CreateTemp(filepath.Dir(destination), ".ca.*")
	if err != nil {
		return err
	}
	temporaryPath := temporary.Name()
	defer os.Remove(temporaryPath)
	if err := temporary.Chmod(0o644); err != nil {
		_ = temporary.Close()
		return err
	}
	if _, err := temporary.Write(raw); err != nil {
		_ = temporary.Close()
		return err
	}
	if err := temporary.Sync(); err != nil {
		_ = temporary.Close()
		return err
	}
	if err := temporary.Close(); err != nil {
		return err
	}
	return os.Rename(temporaryPath, destination)
}

type fixtureConfig struct {
	smtpAddress, apiAddress, host, username, password, certDir, caPath, statePath, domain string
	hashSecret                                                                            []byte
}

func loadConfig(getenv func(string) string) (fixtureConfig, error) {
	secret, err := hex.DecodeString(getenv("FIXTURE_HASH_SECRET"))
	cfg := fixtureConfig{
		smtpAddress: getenv("FIXTURE_SMTP_ADDRESS"), apiAddress: getenv("FIXTURE_API_ADDRESS"),
		host: getenv("FIXTURE_SMTP_HOST"), username: getenv("FIXTURE_SMTP_USERNAME"),
		password: getenv("FIXTURE_SMTP_PASSWORD"), certDir: getenv("FIXTURE_CERT_DIR"), caPath: getenv("FIXTURE_CA_PATH"),
		statePath: getenv("FIXTURE_STATE_PATH"), domain: getenv("FIXTURE_THREADHUB_DOMAIN"), hashSecret: secret,
	}
	if err != nil || len(secret) != 32 || cfg.smtpAddress == "" || cfg.apiAddress == "" || cfg.host == "" || cfg.username == "" || cfg.password == "" || !filepath.IsAbs(cfg.certDir) || !filepath.IsAbs(cfg.caPath) || filepath.Base(cfg.caPath) != "ca.crt" || !filepath.IsAbs(cfg.statePath) || filepath.Clean(cfg.statePath) != filepath.Join(filepath.Clean(cfg.certDir), "captures.json") || cfg.domain == "" || strings.ContainsAny(cfg.username+cfg.password, "\r\n") {
		return fixtureConfig{}, errors.New("invalid fixture configuration")
	}
	return cfg, nil
}

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	if runCommand(ctx, os.Args[1:], os.Getenv) != nil {
		os.Exit(1)
	}
}

func runCommand(ctx context.Context, args []string, getenv func(string) string) error {
	if len(args) != 1 {
		return errors.New("invalid fixture command")
	}
	switch args[0] {
	case "serve":
		return run(ctx, getenv)
	case "healthcheck":
		probeContext, cancel := context.WithTimeout(ctx, 2*time.Second)
		defer cancel()
		return probeHealth(probeContext, getenv("FIXTURE_API_ADDRESS"))
	default:
		return errors.New("invalid fixture command")
	}
}

func probeHealth(ctx context.Context, address string) error {
	host, port, err := net.SplitHostPort(address)
	if err != nil || (host != "" && host != "127.0.0.1") {
		return errors.New("invalid healthcheck address")
	}
	portNumber, err := strconv.Atoi(port)
	if err != nil || portNumber < 1 || portNumber > 65535 {
		return errors.New("invalid healthcheck address")
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, "http://"+net.JoinHostPort("127.0.0.1", port)+"/healthz", nil)
	if err != nil {
		return errors.New("invalid healthcheck request")
	}
	client := &http.Client{
		Transport: &http.Transport{
			Proxy:             nil,
			DisableKeepAlives: true,
			DialContext:       (&net.Dialer{Timeout: time.Second}).DialContext,
		},
	}
	response, err := client.Do(request)
	if err != nil {
		return errors.New("healthcheck request failed")
	}
	defer response.Body.Close()
	body, err := io.ReadAll(io.LimitReader(response.Body, 3))
	if err != nil || response.StatusCode != http.StatusOK || !bytes.Equal(body, []byte("ok")) {
		return errors.New("healthcheck response invalid")
	}
	return nil
}

func run(ctx context.Context, getenv func(string) string) error {
	cfg, err := loadConfig(getenv)
	if err != nil {
		return err
	}
	if err := ensureCertificate(cfg.certDir, cfg.host, time.Now().UTC()); err != nil {
		return err
	}
	if err := publishCA(filepath.Join(cfg.certDir, "ca.crt"), cfg.caPath); err != nil {
		return err
	}
	certificate, err := tls.LoadX509KeyPair(filepath.Join(cfg.certDir, "server.crt"), filepath.Join(cfg.certDir, "server.key"))
	if err != nil {
		return err
	}
	store, err := newPersistentCaptureStore(cfg.hashSecret, cfg.domain, cfg.statePath)
	if err != nil {
		return err
	}
	smtpListener, err := net.Listen("tcp", cfg.smtpAddress)
	if err != nil {
		return err
	}
	apiListener, err := net.Listen("tcp", cfg.apiAddress)
	if err != nil {
		_ = smtpListener.Close()
		return err
	}
	smtpDone := make(chan error, 1)
	go func() {
		smtpDone <- serveSMTP(ctx, smtpListener, &tls.Config{Certificates: []tls.Certificate{certificate}, MinVersion: tls.VersionTLS12}, cfg, store)
	}()
	apiServer := &http.Server{
		Handler: apiHandler(store), ReadHeaderTimeout: 3 * time.Second,
		ReadTimeout: 3 * time.Second, WriteTimeout: 3 * time.Second, IdleTimeout: 10 * time.Second,
		ErrorLog: log.New(io.Discard, "", 0),
	}
	apiDone := make(chan error, 1)
	go func() { apiDone <- apiServer.Serve(apiListener) }()
	select {
	case <-ctx.Done():
		_ = smtpListener.Close()
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		defer cancel()
		_ = apiServer.Shutdown(shutdownCtx)
		return nil
	case err := <-smtpDone:
		_ = apiServer.Close()
		return err
	case err := <-apiDone:
		_ = smtpListener.Close()
		if errors.Is(err, http.ErrServerClosed) {
			return nil
		}
		return err
	}
}

func apiHandler(store *captureStore) http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", func(response http.ResponseWriter, _ *http.Request) {
		response.Header().Set("Content-Type", "text/plain; charset=utf-8")
		_, _ = io.WriteString(response, "ok")
	})
	mux.HandleFunc("GET /v1/captures", func(response http.ResponseWriter, _ *http.Request) {
		response.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(response).Encode(store.snapshot())
	})
	mux.HandleFunc("POST /v1/fail-next", func(response http.ResponseWriter, request *http.Request) {
		if request.ContentLength > 0 {
			response.WriteHeader(http.StatusBadRequest)
			return
		}
		store.failNext()
		response.WriteHeader(http.StatusNoContent)
	})
	return mux
}

func serveSMTP(ctx context.Context, listener net.Listener, tlsConfig *tls.Config, cfg fixtureConfig, store *captureStore) error {
	go func() {
		<-ctx.Done()
		_ = listener.Close()
	}()
	for {
		connection, err := listener.Accept()
		if err != nil {
			if ctx.Err() != nil || errors.Is(err, net.ErrClosed) {
				return nil
			}
			return err
		}
		go handleSMTP(connection, tlsConfig, cfg, store)
	}
}

func handleSMTP(connection net.Conn, tlsConfig *tls.Config, cfg fixtureConfig, store *captureStore) {
	defer connection.Close()
	_ = connection.SetDeadline(time.Now().Add(30 * time.Second))
	reader := bufio.NewReader(io.LimitReader(connection, 8<<20))
	writer := bufio.NewWriter(connection)
	writeSMTP(writer, "220 threadhub-fixture ESMTP")
	var tlsActive, authenticated bool
	var envelopeFrom string
	var attemptAt time.Time
	var recipients []string
	for {
		line, err := reader.ReadString('\n')
		if err != nil || len(line) > 8192 {
			return
		}
		line = strings.TrimSuffix(strings.TrimSuffix(line, "\n"), "\r")
		command, argument, _ := strings.Cut(line, " ")
		switch strings.ToUpper(command) {
		case "EHLO", "HELO":
			authenticated, envelopeFrom, recipients, attemptAt = false, "", nil, time.Time{}
			if tlsActive {
				writeSMTP(writer, "250-threadhub-fixture", "250 AUTH PLAIN")
			} else {
				writeSMTP(writer, "250-threadhub-fixture", "250 STARTTLS")
			}
		case "STARTTLS":
			if tlsActive || argument != "" {
				writeSMTP(writer, "503 bad sequence")
				continue
			}
			writeSMTP(writer, "220 ready for TLS")
			tlsConnection := tls.Server(connection, tlsConfig.Clone())
			if tlsConnection.Handshake() != nil {
				return
			}
			connection = tlsConnection
			reader = bufio.NewReader(io.LimitReader(connection, 8<<20))
			writer = bufio.NewWriter(connection)
			tlsActive, authenticated, envelopeFrom, recipients, attemptAt = true, false, "", nil, time.Time{}
		case "AUTH":
			if !tlsActive {
				writeSMTP(writer, "530 STARTTLS required")
				continue
			}
			fields := strings.Fields(argument)
			if len(fields) != 2 || strings.ToUpper(fields[0]) != "PLAIN" || !validPlainAuth(fields[1], cfg.username, cfg.password) {
				writeSMTP(writer, "535 authentication failed")
				continue
			}
			authenticated = true
			writeSMTP(writer, "235 authenticated")
		case "MAIL":
			if !tlsActive || !authenticated {
				writeSMTP(writer, "530 authentication required")
				continue
			}
			value, ok := smtpPath(argument, "FROM:")
			if !ok {
				writeSMTP(writer, "501 invalid sender")
				continue
			}
			envelopeFrom, recipients, attemptAt = value, nil, time.Now().UTC()
			writeSMTP(writer, "250 sender accepted")
		case "RCPT":
			if envelopeFrom == "" {
				writeSMTP(writer, "503 sender required")
				continue
			}
			value, ok := smtpPath(argument, "TO:")
			if !ok || len(recipients) != 0 {
				writeSMTP(writer, "550 exactly one recipient required")
				continue
			}
			recipients = append(recipients, value)
			writeSMTP(writer, "250 recipient accepted")
		case "DATA":
			if envelopeFrom == "" || len(recipients) != 1 {
				writeSMTP(writer, "503 envelope required")
				continue
			}
			writeSMTP(writer, "354 end with <CRLF>.<CRLF>")
			dataReader := textproto.NewReader(reader).DotReader()
			raw, err := io.ReadAll(io.LimitReader(dataReader, maxMessageBytes+1))
			if err != nil || len(raw) > maxMessageBytes {
				writeSMTP(writer, "552 message too large")
				envelopeFrom, recipients = "", nil
				continue
			}
			if store.consumeFailure() {
				writeSMTP(writer, "450 injected temporary failure")
			} else {
				if _, err := store.recordAt(recipients[0], raw, attemptAt); err != nil {
					writeSMTP(writer, "450 capture state unavailable")
				} else {
					writeSMTP(writer, "250 accepted")
				}
			}
			envelopeFrom, recipients, attemptAt = "", nil, time.Time{}
		case "RSET":
			envelopeFrom, recipients, attemptAt = "", nil, time.Time{}
			writeSMTP(writer, "250 reset")
		case "NOOP":
			writeSMTP(writer, "250 ok")
		case "QUIT":
			writeSMTP(writer, "221 bye")
			return
		default:
			writeSMTP(writer, "502 unsupported command")
		}
	}
}

func writeSMTP(writer *bufio.Writer, lines ...string) {
	for _, line := range lines {
		_, _ = writer.WriteString(line + "\r\n")
	}
	_ = writer.Flush()
}

func validPlainAuth(value, username, password string) bool {
	raw, err := base64.StdEncoding.DecodeString(value)
	if err != nil {
		return false
	}
	parts := bytes.Split(raw, []byte{0})
	return len(parts) == 3 && len(parts[0]) == 0 && string(parts[1]) == username && string(parts[2]) == password
}

func smtpPath(argument, prefix string) (string, bool) {
	if !strings.HasPrefix(strings.ToUpper(argument), prefix+"<") || !strings.HasSuffix(argument, ">") {
		return "", false
	}
	value := argument[len(prefix)+1 : len(argument)-1]
	parsed, err := mail.ParseAddress(value)
	return value, err == nil && parsed.Address == value
}
