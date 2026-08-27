package protocol

import (
	"bytes"
	"errors"
	"strings"
	"testing"
)

type failingReader struct{}

func (failingReader) Read([]byte) (int, error) { return 0, errors.New("reader failed") }

func TestNewNonce(t *testing.T) {
	reader := bytes.NewReader(bytes.Repeat([]byte{0xab}, 16))
	nonce, err := NewNonce(reader)
	if err != nil {
		t.Fatalf("NewNonce() error = %v", err)
	}
	if nonce != "abababababababababababababababab" {
		t.Fatalf("NewNonce() = %q, want deterministic 32-digit hex", nonce)
	}
	if _, err := NewNonce(failingReader{}); err == nil {
		t.Fatal("NewNonce() accepted a failing reader")
	}
}

func TestSignAndVerify(t *testing.T) {
	secret := []byte("0123456789abcdef0123456789abcdef")
	timestamp := int64(1700000000)
	nonce := "00112233445566778899aabbccddeeff"
	body := []byte(`{"event_id":"signed-event"}`)
	want := "sha256=82e8223e40460390d2d180220f659fd7e184396e563491853035ede57e255803"

	if got := Sign(secret, timestamp, nonce, body); got != want {
		t.Fatalf("Sign() = %q, want %q", got, want)
	}
	if err := Verify(secret, timestamp, nonce, body, want); err != nil {
		t.Fatalf("Verify() error = %v", err)
	}

	for name, changed := range map[string]struct {
		timestamp int64
		nonce     string
		body      []byte
		signature string
	}{
		"body changed":      {timestamp: timestamp, nonce: nonce, body: []byte(`{"event_id":"changed-event"}`), signature: want},
		"timestamp changed": {timestamp: timestamp + 1, nonce: nonce, body: body, signature: want},
		"nonce changed":     {timestamp: timestamp, nonce: "ffeeddccbbaa99887766554433221100", body: body, signature: want},
	} {
		t.Run(name, func(t *testing.T) {
			if err := Verify(secret, changed.timestamp, changed.nonce, changed.body, changed.signature); err == nil {
				t.Fatal("Verify() accepted changed signed input")
			}
		})
	}

	for _, malformed := range []string{"", "sha256=not-hex", "sha256=00", "sha512=" + strings.Repeat("0", 64), "SHA256=" + strings.Repeat("0", 64)} {
		t.Run("malformed signature", func(t *testing.T) {
			if err := Verify(secret, timestamp, nonce, body, malformed); err == nil {
				t.Fatal("Verify() accepted malformed signature")
			}
		})
	}
	if err := Verify([]byte("too-short"), timestamp, nonce, body, want); err == nil {
		t.Fatal("Verify() accepted short secret")
	}
}

func TestHashIdentifierSeparatesPurpose(t *testing.T) {
	secret := []byte("0123456789abcdef0123456789abcdef")
	first := HashIdentifier(secret, "event", "opaque-id")
	second := HashIdentifier(secret, "recipient", "opaque-id")
	if first == second {
		t.Fatal("HashIdentifier() reused the same value across purposes")
	}
	if len(first) != 64 || len(second) != 64 {
		t.Fatalf("HashIdentifier() lengths = %d and %d, want 64", len(first), len(second))
	}
	if first != HashIdentifier(secret, "event", "opaque-id") {
		t.Fatal("HashIdentifier() is not deterministic")
	}
}
