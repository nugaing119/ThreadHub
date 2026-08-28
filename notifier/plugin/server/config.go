package server

import (
	"errors"
	"fmt"
	"net/url"
	"path/filepath"
	"strings"
	"time"

	"github.com/nugaing119/ThreadHub/notifier/protocol"
)

var errInvalidConfig = errors.New("invalid plugin configuration")

const internalMailerURL = "http://threadhub-mailer:8080"

type Config struct {
	Domain      string
	MailerURL   *url.URL
	HMACSecret  []byte
	ControlFile string
	PollEvery   time.Duration
}

func LoadConfig(getenv func(string) string) (Config, error) {
	if getenv == nil {
		return Config{}, errInvalidConfig
	}

	cfg := Config{
		Domain:      getenv("THREADHUB_DOMAIN"),
		ControlFile: getenv("NOTIFIER_CONTROL_FILE"),
	}
	if cfg.ControlFile == "" {
		cfg.ControlFile = "/run/threadhub-notifier/state.json"
	}
	var err error
	if cfg.HMACSecret, err = protocol.DecodeSecretHex(getenv("NOTIFIER_HMAC_SECRET")); err != nil {
		return Config{}, errInvalidConfig
	}
	if cfg.PollEvery, err = time.ParseDuration(getenv("NOTIFIER_POLL_EVERY")); err != nil || cfg.PollEvery <= 0 {
		return Config{}, errInvalidConfig
	}
	if cfg.MailerURL, err = parseInternalMailerURL(getenv("NOTIFIER_MAILER_URL")); err != nil {
		return Config{}, errInvalidConfig
	}
	if cfg.Domain == "" || strings.ContainsAny(cfg.Domain, "\r\n") || !filepath.IsAbs(cfg.ControlFile) || filepath.Clean(cfg.ControlFile) != cfg.ControlFile {
		return Config{}, errInvalidConfig
	}
	return cfg, nil
}

func parseInternalMailerURL(value string) (*url.URL, error) {
	u, err := url.Parse(value)
	if err != nil || value != internalMailerURL || u.Scheme != "http" || u.Host != "threadhub-mailer:8080" || u.User != nil || u.RawQuery != "" || u.Fragment != "" || u.ForceQuery || u.Path != "" {
		return nil, errInvalidConfig
	}
	return u, nil
}

func (c Config) String() string {
	mailerURL := ""
	if c.MailerURL != nil {
		mailerURL = c.MailerURL.String()
	}
	return fmt.Sprintf("plugin{domain=%q mailer_url=%q control=%q poll=%s}", c.Domain, mailerURL, c.ControlFile, c.PollEvery)
}
