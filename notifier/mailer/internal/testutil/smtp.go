// Package testutil provides a local STARTTLS SMTP boundary fixture for tests.
package testutil

import (
	"bufio"
	"crypto/rand"
	"crypto/rsa"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/base64"
	"encoding/pem"
	"fmt"
	"math/big"
	"net"
	"strings"
	"sync"
	"testing"
	"time"
)

type SMTPOptions struct {
	STARTTLS           bool
	Username, Password string
	AuthCode, RCPTCode int
	Stall              bool
}
type SMTPServer struct {
	listener            net.Listener
	options             SMTPOptions
	config              *tls.Config
	roots               *x509.CertPool
	mu                  sync.Mutex
	messages            [][]byte
	authenticated       bool
	plaintextAuthOrMail bool
}

func StartSMTP(t testing.TB, options SMTPOptions) *SMTPServer {
	t.Helper()
	cert, roots := certificate(t)
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	s := &SMTPServer{listener: listener, options: options, config: &tls.Config{Certificates: []tls.Certificate{cert}, MinVersion: tls.VersionTLS12}, roots: roots}
	go s.serve()
	t.Cleanup(func() { _ = listener.Close() })
	return s
}
func (s *SMTPServer) Port() int             { return s.listener.Addr().(*net.TCPAddr).Port }
func (s *SMTPServer) Roots() *x509.CertPool { return s.roots }
func (s *SMTPServer) Authenticated() bool   { s.mu.Lock(); defer s.mu.Unlock(); return s.authenticated }
func (s *SMTPServer) Messages() [][]byte {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([][]byte(nil), s.messages...)
}
func (s *SMTPServer) SawPlaintextAuthOrMail() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.plaintextAuthOrMail
}
func (s *SMTPServer) serve() {
	for {
		conn, err := s.listener.Accept()
		if err != nil {
			return
		}
		go s.handle(conn)
	}
}

func (s *SMTPServer) handle(conn net.Conn) {
	defer conn.Close()
	r := bufio.NewReader(conn)
	w := bufio.NewWriter(conn)
	write := func(code int, text string) bool {
		_, err := fmt.Fprintf(w, "%d %s\r\n", code, text)
		if err == nil {
			err = w.Flush()
		}
		return err == nil
	}
	if !write(220, "fixture smtp") {
		return
	}
	tlsActive := false
	for {
		line, err := r.ReadString('\n')
		if err != nil {
			return
		}
		if s.options.Stall {
			for {
				if _, err := r.ReadByte(); err != nil {
					return
				}
			}
		}
		command := strings.TrimSpace(line)
		upper := strings.ToUpper(command)
		switch {
		case strings.HasPrefix(upper, "EHLO"):
			if s.options.STARTTLS && !tlsActive {
				_, _ = fmt.Fprint(w, "250-fixture\r\n250-STARTTLS\r\n250 AUTH PLAIN\r\n")
				_ = w.Flush()
			} else {
				_, _ = fmt.Fprint(w, "250-fixture\r\n250 AUTH PLAIN\r\n")
				_ = w.Flush()
			}
		case upper == "STARTTLS":
			if !s.options.STARTTLS || tlsActive {
				_ = write(454, "TLS unavailable")
				continue
			}
			if !write(220, "go ahead") {
				return
			}
			tlsConn := tls.Server(conn, s.config)
			if err := tlsConn.Handshake(); err != nil {
				return
			}
			conn = tlsConn
			r = bufio.NewReader(conn)
			w = bufio.NewWriter(conn)
			tlsActive = true
		case strings.HasPrefix(upper, "AUTH "):
			if !tlsActive {
				s.mu.Lock()
				s.plaintextAuthOrMail = true
				s.mu.Unlock()
			}
			if s.options.AuthCode != 0 || !s.validPlainAuth(command) {
				code := s.options.AuthCode
				if code == 0 {
					code = 535
				}
				_ = write(code, "authentication failed")
				continue
			}
			s.mu.Lock()
			s.authenticated = true
			s.mu.Unlock()
			_ = write(235, "authenticated")
		case strings.HasPrefix(upper, "MAIL FROM:"), strings.HasPrefix(upper, "RCPT TO:"):
			if !tlsActive {
				s.mu.Lock()
				s.plaintextAuthOrMail = true
				s.mu.Unlock()
			}
			if strings.HasPrefix(upper, "RCPT TO:") && s.options.RCPTCode != 0 {
				_ = write(s.options.RCPTCode, "recipient rejected")
				continue
			}
			_ = write(250, "ok")
		case upper == "DATA":
			if !write(354, "end with dot") {
				return
			}
			var data strings.Builder
			for {
				row, err := r.ReadString('\n')
				if err != nil {
					return
				}
				if row == ".\r\n" {
					break
				}
				data.WriteString(row)
			}
			s.mu.Lock()
			s.messages = append(s.messages, []byte(data.String()))
			s.mu.Unlock()
			_ = write(250, "queued")
		case upper == "QUIT":
			_ = write(221, "bye")
			return
		default:
			_ = write(250, "ok")
		}
	}
}

func (s *SMTPServer) validPlainAuth(command string) bool {
	parts := strings.Fields(command)
	if len(parts) != 3 || !strings.EqualFold(parts[1], "PLAIN") {
		return false
	}
	decoded, err := base64.StdEncoding.DecodeString(parts[2])
	if err != nil {
		return false
	}
	return string(decoded) == "\x00"+s.options.Username+"\x00"+s.options.Password
}

func certificate(t testing.TB) (tls.Certificate, *x509.CertPool) {
	t.Helper()
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	template := &x509.Certificate{SerialNumber: big.NewInt(1), Subject: pkix.Name{CommonName: "localhost"}, DNSNames: []string{"localhost"}, NotBefore: time.Now().Add(-time.Minute), NotAfter: time.Now().Add(time.Hour), KeyUsage: x509.KeyUsageDigitalSignature | x509.KeyUsageKeyEncipherment, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth}, IsCA: true, BasicConstraintsValid: true}
	der, err := x509.CreateCertificate(rand.Reader, template, template, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	cert, err := tls.X509KeyPair(pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}), pem.EncodeToMemory(&pem.Block{Type: "RSA PRIVATE KEY", Bytes: x509.MarshalPKCS1PrivateKey(key)}))
	if err != nil {
		t.Fatal(err)
	}
	parsed, err := x509.ParseCertificate(der)
	if err != nil {
		t.Fatal(err)
	}
	roots := x509.NewCertPool()
	roots.AddCert(parsed)
	return cert, roots
}
