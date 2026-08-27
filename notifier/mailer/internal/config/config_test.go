package config

import (
	"strings"
	"testing"
)

func TestLoadAcceptsValidatedRuntimeConfiguration(t *testing.T) {
	t.Parallel()
	cfg, err := Load(testEnvironment)
	if err != nil {
		t.Fatalf("Load() error = %v", err)
	}
	if cfg.SMTPPort != 587 || cfg.RatePerMinute != 10 || string(cfg.HMACSecret) != strings.Repeat("\x01", 32) {
		t.Fatalf("Load() = %#v, want validated values", cfg)
	}
}

func TestLoadRejectsUnsafeConfigurationWithoutSecretLeakage(t *testing.T) {
	t.Parallel()
	const password = "password-that-must-not-escape"
	const username = "username-that-must-not-escape"
	const secret = "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff"
	for _, test := range []struct{ name, key, value string }{
		{"invalid HMAC", "NOTIFIER_HMAC_SECRET", "not-hex"},
		{"relative queue path", "NOTIFIER_QUEUE_PATH", "relative/queue.db"},
		{"non-587 port", "SMTP_PORT", "25"},
		{"uppercase region placeholder", "SMTP_SERVER", "smtp.email.REGION.oci.oraclecloud.com"},
		{"lowercase region placeholder", "SMTP_SERVER", "smtp.email.region.oci.oraclecloud.com"},
		{"lowercase your-region placeholder", "SMTP_SERVER", "smtp.email.your-region.oci.oraclecloud.com"},
		{"injected From address", "SMTP_FROM_ADDRESS", "from@example.test\r\nBcc: attacker@example.test"},
		{"rate over maximum", "NOTIFIER_RATE_PER_MINUTE", "61"},
	} {
		t.Run(test.name, func(t *testing.T) {
			env := testValues()
			env["SMTP_PASSWORD"] = password
			env["SMTP_USERNAME"] = username
			env["NOTIFIER_HMAC_SECRET"] = secret
			env[test.key] = test.value
			cfg, err := Load(func(key string) string { return env[key] })
			if err == nil {
				t.Fatal("Load() error = nil, want validation error")
			}
			combined := err.Error() + cfg.String()
			for _, forbidden := range []string{password, username, secret} {
				if strings.Contains(combined, forbidden) {
					t.Fatalf("Load() leaked secret %q", forbidden)
				}
			}
		})
	}
}

func testEnvironment(key string) string { return testValues()[key] }

func testValues() map[string]string {
	return map[string]string{
		"NOTIFIER_LISTEN_ADDRESS":  ":8080",
		"THREADHUB_DOMAIN":         "threadhub.example.test",
		"NOTIFIER_HMAC_SECRET":     strings.Repeat("01", 32),
		"NOTIFIER_QUEUE_PATH":      "/var/lib/threadhub-notifier/queue.db",
		"SMTP_SERVER":              "smtp.email.ap-singapore-1.oci.oraclecloud.com",
		"SMTP_PORT":                "587",
		"SMTP_USERNAME":            "fixture-user",
		"SMTP_PASSWORD":            "fixture-password",
		"SMTP_FROM_ADDRESS":        "no-reply@example.test",
		"SMTP_REPLY_TO_ADDRESS":    "feedback@example.test",
		"SMTP_FEEDBACK_NAME":       "ThreadHub 고객지원",
		"NOTIFIER_RATE_PER_MINUTE": "10",
	}
}
