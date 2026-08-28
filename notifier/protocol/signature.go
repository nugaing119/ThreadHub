package protocol

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
)

var (
	ErrInvalidSecret    = errors.New("invalid secret")
	ErrInvalidSignature = errors.New("invalid signature")
)

func DecodeSecretHex(value string) ([]byte, error) {
	secret, err := hex.DecodeString(value)
	if err != nil || len(secret) != 32 {
		return nil, ErrInvalidSecret
	}
	return secret, nil
}

func NewNonce(reader io.Reader) (string, error) {
	nonce := make([]byte, 16)
	if _, err := io.ReadFull(reader, nonce); err != nil {
		return "", err
	}
	return hex.EncodeToString(nonce), nil
}

func Sign(secret []byte, timestamp int64, nonce string, body []byte) string {
	mac := hmac.New(sha256.New, deriveKey(secret, "request-signing"))
	_, _ = fmt.Fprintf(mac, "%d\n%s\n", timestamp, nonce)
	_, _ = mac.Write(body)
	return "sha256=" + hex.EncodeToString(mac.Sum(nil))
}

func Verify(secret []byte, timestamp int64, nonce string, body []byte, signature string) error {
	if len(secret) != 32 || len(signature) != len("sha256=")+sha256.Size*2 || len(signature) < len("sha256=") || signature[:len("sha256=")] != "sha256=" {
		return ErrInvalidSignature
	}
	provided, err := hex.DecodeString(signature[len("sha256="):])
	if err != nil || len(provided) != sha256.Size {
		return ErrInvalidSignature
	}
	expected, err := hex.DecodeString(Sign(secret, timestamp, nonce, body)[len("sha256="):])
	if err != nil || !hmac.Equal(provided, expected) {
		return ErrInvalidSignature
	}
	return nil
}

func HashIdentifier(secret []byte, purpose, value string) string {
	mac := hmac.New(sha256.New, deriveKey(secret, purpose))
	_, _ = mac.Write([]byte(value))
	return hex.EncodeToString(mac.Sum(nil))
}

func deriveKey(secret []byte, label string) []byte {
	mac := hmac.New(sha256.New, secret)
	_, _ = mac.Write([]byte("threadhub/" + label + "/v1"))
	return mac.Sum(nil)
}
