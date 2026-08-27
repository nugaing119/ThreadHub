// Package config loads the mailer runtime configuration without exposing secrets.
package config

import (
	"errors"
	"fmt"
	"net"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"

	"github.com/nugaing119/ThreadHub/notifier/protocol"
)

var errInvalidConfig = errors.New("invalid mailer configuration")

var ociSMTPHost = regexp.MustCompile(`^smtp\.email\.[a-z0-9-]+\.oci\.oraclecloud\.com$`)

var placeholderOCIHosts = map[string]struct{}{
	"smtp.email.region.oci.oraclecloud.com":      {},
	"smtp.email.your-region.oci.oraclecloud.com": {},
}

type Config struct {
	ListenAddress string
	Domain        string
	HMACSecret    []byte
	QueuePath     string
	ControlFile   string
	SMTPHost      string
	SMTPPort      int
	SMTPUsername  string
	SMTPPassword  string
	FromAddress   string
	ReplyTo       string
	FeedbackName  string
	RatePerMinute int
}

func Load(getenv func(string) string) (Config, error) {
	if getenv == nil {
		return Config{}, errInvalidConfig
	}
	cfg := Config{
		ListenAddress: getenv("NOTIFIER_LISTEN_ADDRESS"), Domain: getenv("THREADHUB_DOMAIN"), QueuePath: getenv("NOTIFIER_QUEUE_PATH"),
		ControlFile: getenv("NOTIFIER_CONTROL_FILE"),
		SMTPHost:    getenv("SMTP_SERVER"), SMTPUsername: getenv("SMTP_USERNAME"), SMTPPassword: getenv("SMTP_PASSWORD"),
		FromAddress: getenv("SMTP_FROM_ADDRESS"), ReplyTo: getenv("SMTP_REPLY_TO_ADDRESS"), FeedbackName: getenv("SMTP_FEEDBACK_NAME"),
	}
	if cfg.ControlFile == "" {
		cfg.ControlFile = "/run/threadhub-notifier/state.json"
	}
	var err error
	if cfg.HMACSecret, err = protocol.DecodeSecretHex(getenv("NOTIFIER_HMAC_SECRET")); err != nil {
		return Config{}, errInvalidConfig
	}
	if cfg.SMTPPort, err = strconv.Atoi(getenv("SMTP_PORT")); err != nil || cfg.SMTPPort != 587 {
		return Config{}, errInvalidConfig
	}
	if cfg.RatePerMinute, err = strconv.Atoi(getenv("NOTIFIER_RATE_PER_MINUTE")); err != nil || cfg.RatePerMinute < 1 || cfg.RatePerMinute > 60 {
		return Config{}, errInvalidConfig
	}
	if _, _, err := net.SplitHostPort(cfg.ListenAddress); err != nil || cfg.Domain == "" || strings.ContainsAny(cfg.Domain, "\r\n") || !filepath.IsAbs(cfg.QueuePath) || !filepath.IsAbs(cfg.ControlFile) || filepath.Clean(cfg.ControlFile) != cfg.ControlFile || !ociSMTPHost.MatchString(cfg.SMTPHost) || isPlaceholderOCIHost(cfg.SMTPHost) || cfg.SMTPUsername == "" || cfg.SMTPPassword == "" || cfg.FeedbackName == "" || strings.ContainsAny(cfg.FeedbackName, "\r\n") {
		return Config{}, errInvalidConfig
	}
	if protocol.ValidateEmail(cfg.FromAddress) != nil || protocol.ValidateEmail(cfg.ReplyTo) != nil {
		return Config{}, errInvalidConfig
	}
	return cfg, nil
}

func isPlaceholderOCIHost(host string) bool {
	_, found := placeholderOCIHosts[host]
	return found
}

func (c Config) String() string {
	return fmt.Sprintf("mailer{listen=%q domain=%q queue=%q control=%q smtp_host=%q smtp_port=%d from=%q reply_to=%q feedback_name=%q rate_per_minute=%d}", c.ListenAddress, c.Domain, c.QueuePath, c.ControlFile, c.SMTPHost, c.SMTPPort, c.FromAddress, c.ReplyTo, c.FeedbackName, c.RatePerMinute)
}
