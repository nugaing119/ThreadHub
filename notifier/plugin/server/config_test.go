package server

import (
	"strings"
	"testing"
	"time"
)

func TestLoadConfigAcceptsOnlyTheFixedInternalMailerEndpoint(t *testing.T) {
	cfg, err := LoadConfig(testConfigEnvironment)
	if err != nil {
		t.Fatalf("LoadConfig() error = %v", err)
	}
	if cfg.Domain != "threadhub.example.test" || cfg.MailerURL.String() != "http://threadhub-mailer:8080" || cfg.PollEvery != time.Second {
		t.Fatalf("LoadConfig() = %#v, want validated configuration", cfg)
	}
	if got, want := string(cfg.HMACSecret), strings.Repeat("\x01", 32); got != want {
		t.Fatalf("HMACSecret = %q, want decoded secret", got)
	}
}

func TestLoadConfigRejectsUnsafeValuesWithoutLeakingSecret(t *testing.T) {
	const secret = "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff"
	for _, test := range []struct {
		name  string
		key   string
		value string
	}{
		{name: "mailer host", key: "NOTIFIER_MAILER_URL", value: "http://other:8080"},
		{name: "mailer userinfo", key: "NOTIFIER_MAILER_URL", value: "http://user@threadhub-mailer:8080"},
		{name: "mailer query", key: "NOTIFIER_MAILER_URL", value: "http://threadhub-mailer:8080/?next=x"},
		{name: "mailer fragment", key: "NOTIFIER_MAILER_URL", value: "http://threadhub-mailer:8080/#x"},
		{name: "invalid HMAC", key: "NOTIFIER_HMAC_SECRET", value: "not-hex"},
		{name: "relative control file", key: "NOTIFIER_CONTROL_FILE", value: "state.json"},
		{name: "nonpositive poll interval", key: "NOTIFIER_POLL_EVERY", value: "0s"},
	} {
		t.Run(test.name, func(t *testing.T) {
			values := testConfigValues()
			values["NOTIFIER_HMAC_SECRET"] = secret
			values[test.key] = test.value
			cfg, err := LoadConfig(func(key string) string { return values[key] })
			if err == nil {
				t.Fatal("LoadConfig() error = nil, want validation error")
			}
			if strings.Contains(err.Error(), secret) || strings.Contains(cfg.String(), secret) {
				t.Fatal("LoadConfig() exposed the HMAC secret")
			}
		})
	}
}

func testConfigEnvironment(key string) string { return testConfigValues()[key] }

func testConfigValues() map[string]string {
	return map[string]string{
		"THREADHUB_DOMAIN":      "threadhub.example.test",
		"NOTIFIER_MAILER_URL":   "http://threadhub-mailer:8080",
		"NOTIFIER_HMAC_SECRET":  strings.Repeat("01", 32),
		"NOTIFIER_CONTROL_FILE": "/run/threadhub-notifier/state.json",
		"NOTIFIER_POLL_EVERY":   "1s",
	}
}
