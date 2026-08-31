package main

import (
	"bytes"
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"encoding/pem"
	"net"
	"net/http"
	"net/http/httptest"
	"net/smtp"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestRunCommandHealthcheckIsStrictAndLoopbackOnly(t *testing.T) {
	t.Parallel()

	healthy := httptest.NewServer(http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		if request.URL.Path != "/healthz" {
			t.Fatalf("healthcheck path = %q", request.URL.Path)
		}
		_, _ = response.Write([]byte("ok"))
	}))
	defer healthy.Close()
	healthyAddress := strings.TrimPrefix(healthy.URL, "http://")
	getenv := func(key string) string {
		if key == "FIXTURE_API_ADDRESS" {
			return healthyAddress
		}
		return ""
	}
	if err := runCommand(context.Background(), []string{"healthcheck"}, getenv); err != nil {
		t.Fatalf("healthcheck command error = %v", err)
	}

	for name, args := range map[string][]string{
		"missing": nil,
		"unknown": {"unknown"},
		"extra":   {"healthcheck", "extra"},
	} {
		t.Run(name, func(t *testing.T) {
			if err := runCommand(context.Background(), args, getenv); err == nil {
				t.Fatal("runCommand() accepted invalid arguments")
			}
		})
	}
	if err := runCommand(context.Background(), []string{"healthcheck"}, func(string) string { return "192.0.2.1:8081" }); err == nil {
		t.Fatal("healthcheck accepted a non-loopback endpoint")
	}
}

func TestProbeHealthRejectsWrongStatusAndBody(t *testing.T) {
	t.Parallel()

	for name, handler := range map[string]http.Handler{
		"status": http.HandlerFunc(func(response http.ResponseWriter, _ *http.Request) {
			response.WriteHeader(http.StatusServiceUnavailable)
		}),
		"body": http.HandlerFunc(func(response http.ResponseWriter, _ *http.Request) {
			_, _ = response.Write([]byte("not-ok"))
		}),
	} {
		t.Run(name, func(t *testing.T) {
			server := httptest.NewServer(handler)
			defer server.Close()
			if err := probeHealth(context.Background(), strings.TrimPrefix(server.URL, "http://")); err == nil {
				t.Fatal("probeHealth() accepted an invalid response")
			}
		})
	}
}

func TestSMTPRequiresSTARTTLSAndAuthAndInjectsOneTemporaryFailure(t *testing.T) {
	dir := t.TempDir()
	host := "smtp.email.ap-singapore-1.oci.oraclecloud.com"
	if err := ensureCertificate(dir, host, time.Now().UTC()); err != nil {
		t.Fatal(err)
	}
	certificate, err := tls.LoadX509KeyPair(filepath.Join(dir, "server.crt"), filepath.Join(dir, "server.key"))
	if err != nil {
		t.Fatal(err)
	}
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(func() {
		cancel()
		_ = listener.Close()
	})
	store := newCaptureStore([]byte("0123456789abcdef0123456789abcdef"), "threadhub.integration.test")
	cfg := fixtureConfig{host: host, username: "fixture-user", password: "fixture-password"}
	go func() {
		_ = serveSMTP(ctx, listener, &tls.Config{Certificates: []tls.Certificate{certificate}, MinVersion: tls.VersionTLS12}, cfg, store)
	}()

	roots := x509.NewCertPool()
	caPEM, err := os.ReadFile(filepath.Join(dir, "ca.crt"))
	if err != nil || !roots.AppendCertsFromPEM(caPEM) {
		t.Fatal("failed to load fixture CA")
	}
	store.failNext()
	if result := sendTestNotice(listener.Addr().String(), host, roots); result == nil || !strings.HasPrefix(result.Error(), "450") {
		t.Fatalf("first SMTP result = %v, want injected 450", result)
	}
	if got := len(store.snapshot().Captures); got != 0 {
		t.Fatalf("captures after 450 = %d, want 0", got)
	}
	if err := sendTestNotice(listener.Addr().String(), host, roots); err != nil {
		t.Fatalf("second SMTP result = %v", err)
	}
	snapshot := store.snapshot()
	if len(snapshot.Captures) != 1 || snapshot.Captures[0].EnvelopeCount != 1 || !snapshot.Captures[0].GenericContent {
		t.Fatalf("capture snapshot = %#v", snapshot)
	}
}

func TestInspectGenericMessageRejectsAdditionalContent(t *testing.T) {
	t.Parallel()

	valid := testNotice("https://threadhub.integration.test/_redirect/pl/abcdefghijklmnopqrstuvwxyz", "")
	if !inspectGenericMessage(valid, "threadhub.integration.test") {
		t.Fatal("inspectGenericMessage() rejected the exact generic notice")
	}

	leaked := testNotice("https://threadhub.integration.test/_redirect/pl/abcdefghijklmnopqrstuvwxyz", "private channel marker")
	if inspectGenericMessage(leaked, "threadhub.integration.test") {
		t.Fatal("inspectGenericMessage() accepted additional message content")
	}
}

func TestInspectGenericMessageAcceptsMattermostIDsContainingDigits(t *testing.T) {
	t.Parallel()

	valid := testNotice("https://threadhub.integration.test/_redirect/pl/abcd1234efgh5678ijkl9012mn", "")
	if !inspectGenericMessage(valid, "threadhub.integration.test") {
		t.Fatal("inspectGenericMessage() rejected a valid lowercase alphanumeric Mattermost ID")
	}
}

func TestInspectGenericMessageRejectsInvalidMattermostIDs(t *testing.T) {
	t.Parallel()

	for name, postID := range map[string]string{
		"uppercase":   "Abcd1234efgh5678ijkl9012mn",
		"punctuation": "abcd1234efgh5678ijkl9012m-",
		"short":       "abcd1234efgh5678ijkl9012m",
		"long":        "abcd1234efgh5678ijkl9012mno",
	} {
		postID := postID
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			if inspectGenericMessage(testNotice("https://threadhub.integration.test/_redirect/pl/"+postID, ""), "threadhub.integration.test") {
				t.Fatalf("inspectGenericMessage() accepted invalid post ID %q", postID)
			}
		})
	}
}

func TestCaptureStoreSnapshotContainsHashesAndAggregatesOnly(t *testing.T) {
	t.Parallel()

	store := newCaptureStore([]byte("0123456789abcdef0123456789abcdef"), "threadhub.integration.test")
	attemptAt := time.UnixMilli(1787790000123)
	if generic, err := store.recordAt("recipient-one@integration.invalid", testNotice("https://threadhub.integration.test/_redirect/pl/abcdefghijklmnopqrstuvwxyz", ""), attemptAt); err != nil || !generic {
		t.Fatal("recordAt() rejected a valid capture")
	}
	if got := store.snapshot().Captures[0].LastAttemptAtMS; got != attemptAt.UnixMilli() {
		t.Fatalf("last attempt timestamp = %d, want %d", got, attemptAt.UnixMilli())
	}

	raw, err := json.Marshal(store.snapshot())
	if err != nil {
		t.Fatal(err)
	}
	got := string(raw)
	for _, forbidden := range []string{
		"recipient-one@integration.invalid",
		"ThreadHub에 새 메시지가 등록되었습니다.",
		"abcdefghijklmnopqrstuvwxyz",
	} {
		if strings.Contains(got, forbidden) {
			t.Fatalf("snapshot disclosed protected capture data: %q", forbidden)
		}
	}
	if !strings.Contains(got, `"recipient_hash":"`) || !strings.Contains(got, `"envelope_count":1`) || !strings.Contains(got, `"generic_content":true`) || !strings.Contains(got, `"last_attempt_at_ms":1787790000123`) {
		t.Fatalf("snapshot = %s, want hash/count/generic/timing aggregate", got)
	}
}

func TestCaptureStorePersistsOnlyAggregatesAcrossRestart(t *testing.T) {
	t.Parallel()

	statePath := filepath.Join(t.TempDir(), "captures.json")
	secret := []byte("0123456789abcdef0123456789abcdef")
	store, err := newPersistentCaptureStore(secret, "threadhub.integration.test", statePath)
	if err != nil {
		t.Fatal(err)
	}
	recipient := "persisted-recipient@integration.invalid"
	notice := testNotice("https://threadhub.integration.test/_redirect/pl/abcd1234efgh5678ijkl9012mn", "")
	if generic, err := store.record(recipient, notice); err != nil || !generic {
		t.Fatalf("record() = %v, %v", generic, err)
	}

	reloaded, err := newPersistentCaptureStore(secret, "threadhub.integration.test", statePath)
	if err != nil {
		t.Fatal(err)
	}
	if got := reloaded.snapshot(); len(got.Captures) != 1 || got.Captures[0].EnvelopeCount != 1 || !got.Captures[0].GenericContent {
		t.Fatalf("reloaded snapshot = %#v", got)
	}
	raw, err := os.ReadFile(statePath)
	if err != nil {
		t.Fatal(err)
	}
	for _, forbidden := range []string{recipient, "abcd1234efgh5678ijkl9012mn", "ThreadHub에 새 메시지"} {
		if bytes.Contains(raw, []byte(forbidden)) {
			t.Fatalf("persisted aggregate disclosed protected content %q", forbidden)
		}
	}
	info, err := os.Stat(statePath)
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0o600 {
		t.Fatalf("persisted aggregate mode = %v", info.Mode().Perm())
	}

	validHash := strings.Repeat("a", 64)
	for name, malformed := range map[string]string{
		"invalid hash":      `{"captures":[{"recipient_hash":"bad","envelope_count":1,"generic_content":true,"last_attempt_at_ms":1}]}`,
		"negative count":    `{"captures":[{"recipient_hash":"` + validHash + `","envelope_count":-1,"generic_content":true,"last_attempt_at_ms":1}]}`,
		"missing timestamp": `{"captures":[{"recipient_hash":"` + validHash + `","envelope_count":1,"generic_content":true}]}`,
		"negative timestamp": `{"captures":[{"recipient_hash":"` + validHash + `","envelope_count":1,"generic_content":true,
			"last_attempt_at_ms":-1}]}`,
		"duplicate hash": `{"captures":[{"recipient_hash":"` + validHash + `","envelope_count":1,"generic_content":true,"last_attempt_at_ms":1},{"recipient_hash":"` + validHash + `","envelope_count":2,"generic_content":true,"last_attempt_at_ms":2}]}`,
	} {
		t.Run(name, func(t *testing.T) {
			if err := os.WriteFile(statePath, []byte(malformed), 0o600); err != nil {
				t.Fatal(err)
			}
			if _, err := newPersistentCaptureStore(secret, "threadhub.integration.test", statePath); err == nil {
				t.Fatal("newPersistentCaptureStore() accepted malformed persisted state")
			}
		})
	}
}

func TestLoadConfigRequiresPrivateCaptureStatePath(t *testing.T) {
	t.Parallel()

	values := map[string]string{
		"FIXTURE_SMTP_ADDRESS":     ":587",
		"FIXTURE_API_ADDRESS":      ":8081",
		"FIXTURE_SMTP_HOST":        "smtp.email.ap-singapore-1.oci.oraclecloud.com",
		"FIXTURE_SMTP_USERNAME":    "fixture-user",
		"FIXTURE_SMTP_PASSWORD":    "fixture-password",
		"FIXTURE_HASH_SECRET":      strings.Repeat("01", 32),
		"FIXTURE_CERT_DIR":         "/run/smtp-private",
		"FIXTURE_CA_PATH":          "/run/smtp-ca/ca.crt",
		"FIXTURE_STATE_PATH":       "/run/smtp-private/captures.json",
		"FIXTURE_THREADHUB_DOMAIN": "threadhub.integration.test",
	}
	getenv := func(key string) string { return values[key] }
	cfg, err := loadConfig(getenv)
	if err != nil {
		t.Fatal(err)
	}
	if cfg.statePath != values["FIXTURE_STATE_PATH"] {
		t.Fatalf("state path = %q", cfg.statePath)
	}

	for name, value := range map[string]string{
		"missing":         "",
		"relative":        "captures.json",
		"wrong file":      "/run/smtp-private/state.json",
		"wrong directory": "/run/smtp-ca/captures.json",
	} {
		t.Run(name, func(t *testing.T) {
			values["FIXTURE_STATE_PATH"] = value
			if _, err := loadConfig(getenv); err == nil {
				t.Fatal("loadConfig() accepted an invalid capture state path")
			}
		})
	}
}

func TestEnsureCertificateCreatesTrustableRuntimeMaterial(t *testing.T) {
	t.Parallel()

	dir := t.TempDir()
	host := "smtp.email.ap-singapore-1.oci.oraclecloud.com"
	now := time.Date(2026, 8, 27, 1, 2, 3, 0, time.UTC)
	if err := ensureCertificate(dir, host, now); err != nil {
		t.Fatalf("ensureCertificate() error = %v", err)
	}

	keyInfo, err := os.Stat(filepath.Join(dir, "server.key"))
	if err != nil {
		t.Fatal(err)
	}
	if got := keyInfo.Mode().Perm(); got != 0o600 {
		t.Fatalf("server.key mode = %o, want 600", got)
	}

	caPEM, err := os.ReadFile(filepath.Join(dir, "ca.crt"))
	if err != nil {
		t.Fatal(err)
	}
	serverPEM, err := os.ReadFile(filepath.Join(dir, "server.crt"))
	if err != nil {
		t.Fatal(err)
	}
	block, _ := pem.Decode(serverPEM)
	if block == nil {
		t.Fatal("server.crt is not PEM")
	}
	certificate, err := x509.ParseCertificate(block.Bytes)
	if err != nil {
		t.Fatal(err)
	}
	roots := x509.NewCertPool()
	if !roots.AppendCertsFromPEM(caPEM) {
		t.Fatal("ca.crt is not a certificate")
	}
	if _, err := certificate.Verify(x509.VerifyOptions{DNSName: host, Roots: roots, CurrentTime: now.Add(time.Minute)}); err != nil {
		t.Fatalf("runtime certificate does not verify: %v", err)
	}
}

func TestPublishCAUsesSeparateReadablePublicCertificate(t *testing.T) {
	t.Parallel()

	privateDir := t.TempDir()
	publicDir := t.TempDir()
	if err := ensureCertificate(privateDir, "smtp.email.ap-singapore-1.oci.oraclecloud.com", time.Now().UTC()); err != nil {
		t.Fatal(err)
	}
	destination := filepath.Join(publicDir, "ca.crt")
	if err := publishCA(filepath.Join(privateDir, "ca.crt"), destination); err != nil {
		t.Fatalf("publishCA() error = %v", err)
	}
	info, err := os.Stat(destination)
	if err != nil {
		t.Fatal(err)
	}
	if got := info.Mode().Perm(); got != 0o644 {
		t.Fatalf("published CA mode = %o, want 644", got)
	}
	privateCA, _ := os.ReadFile(filepath.Join(privateDir, "ca.crt"))
	publicCA, _ := os.ReadFile(destination)
	if !bytes.Equal(privateCA, publicCA) {
		t.Fatal("published CA differs from runtime CA")
	}
}

func testNotice(permalink, extra string) []byte {
	plain := "ThreadHub에 새 메시지가 등록되었습니다.\r\n로그인하여 확인해 주세요.\r\n\r\n[메시지 확인]\r\n" + permalink + "\r\n" + extra
	html := "<p>ThreadHub에 새 메시지가 등록되었습니다.<br>로그인하여 확인해 주세요.</p><p><a href=\"" + permalink + "\">메시지 확인</a></p>\r\n"
	var message bytes.Buffer
	message.WriteString("From: ThreadHub <no-reply@integration.invalid>\r\n")
	message.WriteString("To: recipient-one@integration.invalid\r\n")
	message.WriteString("Reply-To: feedback@integration.invalid\r\n")
	message.WriteString("Subject: =?UTF-8?b?W1RocmVhZEh1Yl0g7IOIIOuplOyLnOyngOqwgCDrk7HroZ3rkJjsl4jsirXri4jri6Q=?=\r\n")
	message.WriteString("Date: Thu, 27 Aug 2026 01:02:03 +0000\r\n")
	message.WriteString("Message-ID: <opaque@threadhub.integration.test>\r\n")
	message.WriteString("MIME-Version: 1.0\r\n")
	message.WriteString("Content-Type: multipart/alternative; boundary=fixture-boundary\r\n\r\n")
	message.WriteString("--fixture-boundary\r\nContent-Transfer-Encoding: 8bit\r\nContent-Type: text/plain; charset=UTF-8\r\n\r\n")
	message.WriteString(plain)
	message.WriteString("\r\n--fixture-boundary\r\nContent-Transfer-Encoding: 8bit\r\nContent-Type: text/html; charset=UTF-8\r\n\r\n")
	message.WriteString(html)
	message.WriteString("\r\n--fixture-boundary--\r\n")
	return message.Bytes()
}

func sendTestNotice(address, host string, roots *x509.CertPool) error {
	networkConnection, err := net.Dial("tcp", address)
	if err != nil {
		return err
	}
	connection, err := smtp.NewClient(networkConnection, host)
	if err != nil {
		_ = networkConnection.Close()
		return err
	}
	defer connection.Close()
	if err := connection.Hello(host); err != nil {
		return err
	}
	if err := connection.StartTLS(&tls.Config{ServerName: host, RootCAs: roots, MinVersion: tls.VersionTLS12}); err != nil {
		return err
	}
	if err := connection.Auth(smtp.PlainAuth("", "fixture-user", "fixture-password", host)); err != nil {
		return err
	}
	if err := connection.Mail("no-reply@integration.invalid"); err != nil {
		return err
	}
	if err := connection.Rcpt("recipient-one@integration.invalid"); err != nil {
		return err
	}
	writer, err := connection.Data()
	if err != nil {
		return err
	}
	if _, err := writer.Write(testNotice("https://threadhub.integration.test/_redirect/pl/abcdefghijklmnopqrstuvwxyz", "")); err != nil {
		return err
	}
	return writer.Close()
}
