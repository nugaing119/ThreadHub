package main

import (
	"bytes"
	"context"
	"crypto/rand"
	_ "embed"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/nugaing119/ThreadHub/notifier/protocol"
)

//go:embed scenario-ids.txt
var requiredScenarioData string

//go:embed failure-assertions.txt
var failureAssertionData string

var requiredScenarioIDs = mustResultList(requiredScenarioData)

var allowedFailureAssertions = mustResultList(failureAssertionData)

// Real Mattermost image restarts can spend more than 90 seconds restoring the
// plugin runtime on a shared CI runner. Match the harness's initial startup
// allowance so a slow, healthy restart is not classified as a reliability bug.
const integrationRestartTimeout = 180 * time.Second

func mustResultList(raw string) []string {
	if raw == "" || !strings.HasSuffix(raw, "\n") || strings.Contains(raw, "\r") {
		panic("invalid integration result allowlist")
	}
	values := strings.Split(strings.TrimSuffix(raw, "\n"), "\n")
	seen := make(map[string]struct{}, len(values))
	for _, value := range values {
		if value == "" {
			panic("invalid integration result allowlist")
		}
		if _, exists := seen[value]; exists {
			panic("duplicate integration result allowlist entry")
		}
		seen[value] = struct{}{}
	}
	return values
}

var assertionName = regexp.MustCompile(`^NF-[A-Z0-9/-]+-[a-z0-9]+(?:-[a-z0-9]+)*$`)

type reporter struct {
	output io.Writer
	seen   map[string]struct{}
}

func (r *reporter) success(id string) error {
	allowed := false
	for _, candidate := range requiredScenarioIDs {
		if candidate == id {
			allowed = true
			break
		}
	}
	if !allowed {
		return errors.New("invalid result identifier")
	}
	if r.seen == nil {
		r.seen = make(map[string]struct{})
	}
	if _, exists := r.seen[id]; exists {
		return errors.New("duplicate result identifier")
	}
	r.seen[id] = struct{}{}
	_, err := fmt.Fprintln(r.output, id)
	return err
}

func (r *reporter) failure(assertion string) error {
	allowed := false
	for _, candidate := range allowedFailureAssertions {
		if candidate == assertion {
			allowed = true
			break
		}
	}
	if !allowed || !assertionName.MatchString(assertion) {
		return errors.New("invalid assertion name")
	}
	_, err := fmt.Fprintln(r.output, assertion)
	return err
}

type capture struct {
	RecipientHash   string `json:"recipient_hash"`
	EnvelopeCount   int    `json:"envelope_count"`
	GenericContent  bool   `json:"generic_content"`
	LastAttemptAtMS int64  `json:"last_attempt_at_ms"`
}

type captureSnapshot struct {
	Captures []capture `json:"captures"`
}

type integrationConfig struct {
	root, envFile, controlFile, composeFile, projectName string
	composeCommand, containerCommand                     []string
	mattermostURL, mailerURL, captureURL                 *url.URL
	hmacSecret, hashSecret                               []byte
	adminPassword, userPassword, domain                  string
}

func loadConfig(getenv func(string) string) (integrationConfig, error) {
	if getenv == nil {
		return integrationConfig{}, errors.New("invalid integration configuration")
	}
	cfg := integrationConfig{
		root: getenv("INTEGRATION_ROOT"), envFile: getenv("INTEGRATION_ENV_FILE"),
		controlFile: getenv("INTEGRATION_CONTROL_FILE"), composeFile: getenv("INTEGRATION_COMPOSE_FILE"),
		projectName: getenv("INTEGRATION_PROJECT_NAME"), adminPassword: getenv("INTEGRATION_ADMIN_PASSWORD"),
		userPassword: getenv("INTEGRATION_USER_PASSWORD"), domain: getenv("INTEGRATION_DOMAIN"),
	}
	var err error
	if cfg.composeCommand, err = parseComposeCommand(getenv("INTEGRATION_COMPOSE_COMMAND")); err != nil {
		return integrationConfig{}, err
	}
	if cfg.containerCommand, err = parseContainerCommand(getenv("INTEGRATION_CONTAINER_COMMAND")); err != nil {
		return integrationConfig{}, err
	}
	if cfg.mattermostURL, err = parseIntegrationURL(getenv("INTEGRATION_MATTERMOST_URL")); err != nil {
		return integrationConfig{}, err
	}
	if cfg.mailerURL, err = parseIntegrationURL(getenv("INTEGRATION_MAILER_URL")); err != nil {
		return integrationConfig{}, err
	}
	if cfg.captureURL, err = parseIntegrationURL(getenv("INTEGRATION_CAPTURE_URL")); err != nil {
		return integrationConfig{}, err
	}
	if cfg.hmacSecret, err = decodeSecret(getenv("INTEGRATION_HMAC_SECRET")); err != nil {
		return integrationConfig{}, err
	}
	if cfg.hashSecret, err = decodeSecret(getenv("INTEGRATION_HASH_SECRET")); err != nil {
		return integrationConfig{}, err
	}
	if !absoluteClean(cfg.root) || !absoluteClean(cfg.envFile) || !absoluteClean(cfg.controlFile) || !absoluteClean(cfg.composeFile) ||
		!withinRoot(cfg.root, cfg.envFile) || !withinRoot(cfg.root, cfg.controlFile) ||
		!regexp.MustCompile(`^[a-z0-9][a-z0-9_-]{0,62}$`).MatchString(cfg.projectName) ||
		cfg.domain != "threadhub.integration.test" || cfg.adminPassword == "" || cfg.userPassword == "" ||
		strings.ContainsAny(cfg.adminPassword+cfg.userPassword, "\r\n") {
		return integrationConfig{}, errors.New("invalid integration configuration")
	}
	for _, path := range []string{cfg.root, cfg.envFile, cfg.controlFile, cfg.composeFile} {
		if _, err := os.Stat(path); err != nil {
			return integrationConfig{}, errors.New("invalid integration configuration")
		}
	}
	info, err := os.Stat(cfg.envFile)
	if err != nil || info.Mode().Perm() != 0o600 || !info.Mode().IsRegular() {
		return integrationConfig{}, errors.New("invalid integration configuration")
	}
	return cfg, nil
}

func parseComposeCommand(value string) ([]string, error) {
	fields := strings.Fields(value)
	if len(fields) == 0 || len(fields) > 2 || len(fields) == 2 && fields[1] != "compose" {
		return nil, errors.New("invalid Compose command")
	}
	for _, field := range fields {
		if strings.ContainsAny(field, "\x00\r\n") {
			return nil, errors.New("invalid Compose command")
		}
	}
	return append([]string(nil), fields...), nil
}

func parseContainerCommand(value string) ([]string, error) {
	fields := strings.Fields(value)
	for _, field := range fields {
		if strings.ContainsAny(field, "\x00\r\n") {
			return nil, errors.New("invalid container command")
		}
	}
	if len(fields) == 1 && (filepath.Base(fields[0]) == "docker" || filepath.Base(fields[0]) == "podman") {
		return append([]string(nil), fields...), nil
	}
	if len(fields) == 4 && filepath.Base(fields[0]) == "podman" && fields[1] == "--remote" && fields[2] == "--url" && strings.HasPrefix(fields[3], "unix:///") {
		return append([]string(nil), fields...), nil
	}
	return nil, errors.New("invalid container command")
}

func parseIntegrationURL(value string) (*url.URL, error) {
	parsed, err := url.Parse(value)
	if err != nil || parsed.Scheme != "http" || parsed.User != nil || parsed.Path != "" || parsed.RawPath != "" || parsed.RawQuery != "" || parsed.Fragment != "" || parsed.ForceQuery {
		return nil, errors.New("invalid integration endpoint")
	}
	host, port, err := net.SplitHostPort(parsed.Host)
	ip := net.ParseIP(host)
	if err != nil || ip == nil || ip.To4() == nil || (!ip.IsLoopback() && !ip.IsPrivate()) || port == "" {
		return nil, errors.New("invalid integration endpoint")
	}
	return parsed, nil
}

func parseContainerIPv4(output []byte) (string, error) {
	value := strings.TrimSpace(string(output))
	if value == "" || strings.ContainsAny(value, " \t\r\n") {
		return "", errors.New("invalid container address")
	}
	ip := net.ParseIP(value)
	if ip == nil || ip.To4() == nil || ip.IsLoopback() || !ip.IsPrivate() {
		return "", errors.New("invalid container address")
	}
	return value, nil
}

func decodeSecret(value string) ([]byte, error) {
	secret, err := hex.DecodeString(value)
	if err != nil || len(secret) != 32 {
		return nil, errors.New("invalid integration secret")
	}
	return secret, nil
}

func absoluteClean(path string) bool {
	return filepath.IsAbs(path) && filepath.Clean(path) == path
}

func withinRoot(root, path string) bool {
	relative, err := filepath.Rel(root, path)
	return err == nil && relative != ".." && !strings.HasPrefix(relative, ".."+string(filepath.Separator))
}

func newHTTPClient(timeout time.Duration) *http.Client {
	return &http.Client{
		Timeout: timeout,
		Transport: &http.Transport{
			Proxy:               nil,
			DialContext:         (&net.Dialer{Timeout: minDuration(timeout, 3*time.Second), KeepAlive: 10 * time.Second}).DialContext,
			TLSHandshakeTimeout: 3 * time.Second,
		},
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
	}
}

func minDuration(left, right time.Duration) time.Duration {
	if left < right {
		return left
	}
	return right
}

func newSignedRequest(baseURL string, secret []byte, event protocol.Event, timestamp int64, nonce string) (*http.Request, []byte, error) {
	body, err := json.Marshal(event)
	if err != nil {
		return nil, nil, err
	}
	endpoint, err := url.Parse(baseURL)
	if err != nil {
		return nil, nil, err
	}
	endpoint.Path = "/v1/events"
	request, err := http.NewRequest(http.MethodPost, endpoint.String(), bytes.NewReader(body))
	if err != nil {
		return nil, nil, err
	}
	request.Header.Set("Content-Type", "application/json")
	request.Header.Set("X-ThreadHub-Timestamp", strconv.FormatInt(timestamp, 10))
	request.Header.Set("X-ThreadHub-Nonce", nonce)
	request.Header.Set("X-ThreadHub-Signature", protocol.Sign(secret, timestamp, nonce, body))
	return request, body, nil
}

type composeClient struct {
	command                           []string
	composeFile, envFile, projectName string
}

type containerClient struct {
	command []string
}

func newContainerClient(cfg integrationConfig) containerClient {
	return containerClient{command: append([]string(nil), cfg.containerCommand...)}
}

func (c containerClient) privateIPv4(ctx context.Context, containerID, networkName string) (string, error) {
	if len(c.command) == 0 || !regexp.MustCompile(`^[a-f0-9]{12,64}$`).MatchString(containerID) ||
		!regexp.MustCompile(`^[a-z0-9][a-z0-9_-]{0,127}$`).MatchString(networkName) {
		return "", errors.New("invalid container inspection")
	}
	format := `{{with index .NetworkSettings.Networks "` + networkName + `"}}{{.IPAddress}}{{end}}`
	arguments := append([]string(nil), c.command[1:]...)
	arguments = append(arguments, "inspect", "--format", format, containerID)
	command := exec.CommandContext(ctx, c.command[0], arguments...)
	command.Env = os.Environ()
	command.Stderr = io.Discard
	output, err := command.Output()
	if err != nil || len(output) > 1024 {
		return "", errors.New("container inspection failed")
	}
	return parseContainerIPv4(output)
}

func newComposeClient(cfg integrationConfig) composeClient {
	return composeClient{
		command: append([]string(nil), cfg.composeCommand...), composeFile: cfg.composeFile,
		envFile: cfg.envFile, projectName: cfg.projectName,
	}
}

func (c composeClient) run(ctx context.Context, arguments ...string) ([]byte, error) {
	return c.runWithInput(ctx, nil, arguments...)
}

func (c composeClient) runWithInput(ctx context.Context, input []byte, arguments ...string) ([]byte, error) {
	if len(c.command) == 0 {
		return nil, errors.New("Compose command unavailable")
	}
	args := append([]string(nil), c.command[1:]...)
	args = append(args, "--file", c.composeFile, "--env-file", c.envFile, "--project-name", c.projectName)
	args = append(args, arguments...)
	command := exec.CommandContext(ctx, c.command[0], args...)
	command.Env = os.Environ()
	if input != nil {
		command.Stdin = bytes.NewReader(input)
	}
	var stdout bytes.Buffer
	command.Stdout = &stdout
	command.Stderr = io.Discard
	if err := command.Run(); err != nil {
		return nil, errors.New("Compose command failed")
	}
	if stdout.Len() > 1<<20 {
		return nil, errors.New("Compose output exceeded limit")
	}
	return stdout.Bytes(), nil
}

func randomNonce() (string, error) {
	var raw [16]byte
	if _, err := io.ReadFull(rand.Reader, raw[:]); err != nil {
		return "", err
	}
	return hex.EncodeToString(raw[:]), nil
}

func hasExactDelta(before, after captureSnapshot, expected map[string]int) bool {
	if !validateCaptureSnapshot(before) || !validateCaptureSnapshot(after) {
		return false
	}
	beforeMap := captureMap(before)
	afterMap := captureMap(after)
	hashes := make(map[string]struct{}, len(beforeMap)+len(afterMap)+len(expected))
	for hash := range beforeMap {
		hashes[hash] = struct{}{}
	}
	for hash := range afterMap {
		hashes[hash] = struct{}{}
	}
	for hash := range expected {
		hashes[hash] = struct{}{}
	}
	for hash := range hashes {
		value := afterMap[hash]
		want := expected[hash]
		if value.EnvelopeCount-beforeMap[hash].EnvelopeCount != want {
			return false
		}
		if want > 0 && !value.GenericContent {
			return false
		}
	}
	return true
}

func validateCaptureSnapshot(snapshot captureSnapshot) bool {
	seen := make(map[string]struct{}, len(snapshot.Captures))
	for _, value := range snapshot.Captures {
		if len(value.RecipientHash) != 64 || value.EnvelopeCount < 0 || value.EnvelopeCount == 0 && value.LastAttemptAtMS != 0 || value.EnvelopeCount > 0 && value.LastAttemptAtMS <= 0 {
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

func captureMap(snapshot captureSnapshot) map[string]capture {
	result := make(map[string]capture, len(snapshot.Captures))
	for _, value := range snapshot.Captures {
		result[value.RecipientHash] = value
	}
	return result
}

type mattermostClient struct {
	baseURL string
	token   string
	client  *http.Client
}

func newMattermostClient(base *url.URL) *mattermostClient {
	return &mattermostClient{baseURL: base.String(), client: newHTTPClient(8 * time.Second)}
}

func (c *mattermostClient) request(ctx context.Context, method, path string, input, output any, expectedStatuses ...int) (*http.Response, error) {
	var body io.Reader
	if input != nil {
		raw, err := json.Marshal(input)
		if err != nil {
			return nil, err
		}
		body = bytes.NewReader(raw)
	}
	request, err := http.NewRequestWithContext(ctx, method, c.baseURL+"/api/v4"+path, body)
	if err != nil {
		return nil, err
	}
	if input != nil {
		request.Header.Set("Content-Type", "application/json")
	}
	if c.token != "" {
		request.Header.Set("Authorization", "Bearer "+c.token)
	}
	response, err := c.client.Do(request)
	if err != nil {
		return nil, err
	}
	defer response.Body.Close()
	limited := io.LimitReader(response.Body, 2<<20)
	accepted := false
	for _, status := range expectedStatuses {
		if response.StatusCode == status {
			accepted = true
			break
		}
	}
	if !accepted {
		_, _ = io.Copy(io.Discard, limited)
		return response, errors.New("Mattermost API rejected request")
	}
	if output != nil {
		if err := json.NewDecoder(limited).Decode(output); err != nil {
			return response, err
		}
	} else {
		_, _ = io.Copy(io.Discard, limited)
	}
	return response, nil
}

type mmUser struct {
	ID            string `json:"id"`
	Username      string `json:"username"`
	Email         string `json:"email"`
	EmailVerified bool   `json:"email_verified"`
	DeleteAt      int64  `json:"delete_at"`
	IsBot         bool   `json:"is_bot"`
}

type mmTeam struct {
	ID string `json:"id"`
}

type mmChannel struct {
	ID string `json:"id"`
}

type mmPost struct {
	ID        string `json:"id"`
	ChannelID string `json:"channel_id"`
	CreateAt  int64  `json:"create_at"`
}

const mattermostPluginStateRunning = 2

type mmPluginStatus struct {
	PluginID string `json:"plugin_id"`
	State    int    `json:"state"`
	Error    string `json:"error"`
	Version  string `json:"version"`
}

type fixtureUsers struct {
	admin, recipientA, recipientB, nonMember, inactive, bot mmUser
}

type fixtureChannels struct {
	public, private, direct, group mmChannel
}

type mailerStatus struct {
	Pending              int64  `json:"pending"`
	Sending              int64  `json:"sending"`
	Sent                 int64  `json:"sent"`
	Failed               int64  `json:"failed"`
	OldestPendingSeconds int64  `json:"oldest_pending_seconds"`
	LastSuccessAt        int64  `json:"last_success_at"`
	LastErrorClass       string `json:"last_error_class"`
	LastSMTPCode         int    `json:"last_smtp_code"`
}

type controlState struct {
	Enabled         bool     `json:"enabled"`
	DeliveryEnabled bool     `json:"delivery_enabled"`
	Mode            string   `json:"mode"`
	ChannelIDs      []string `json:"channel_ids"`
	ActivatedAt     int64    `json:"activated_at"`
}

type acceptance struct {
	cfg        integrationConfig
	compose    composeClient
	container  containerClient
	mattermost *mattermostClient
	http       *http.Client
	diagnostic io.Writer
	users      fixtureUsers
	channels   fixtureChannels
	team       mmTeam
}

func newAcceptance(cfg integrationConfig) *acceptance {
	return &acceptance{
		cfg: cfg, compose: newComposeClient(cfg), container: newContainerClient(cfg), mattermost: newMattermostClient(cfg.mattermostURL),
		http: newHTTPClient(8 * time.Second), diagnostic: os.Stderr,
	}
}

func (a *acceptance) run(ctx context.Context) string {
	if err := a.verifyPluginPair(ctx); err != nil {
		return "NF-HARNESS-plugin-pair"
	}
	if err := a.verifyPluginActive(ctx); err != nil {
		return "NF-HARNESS-plugin-active-list"
	}
	if assertion := a.bootstrap(ctx); assertion != "" {
		return assertion
	}
	if err := a.enableAndRestart(ctx, time.Now().Add(-time.Minute).UnixMilli()); err != nil {
		return "NF-HARNESS-compose"
	}
	if err := a.verifyPluginPair(ctx); err != nil {
		return "NF-HARNESS-plugin-pair"
	}
	if err := a.verifyPluginActive(ctx); err != nil {
		return "NF-HARNESS-plugin-active-list"
	}
	if err := a.smtpTrustProbe(ctx); err != nil {
		return "NF-HARNESS-capture-api"
	}
	if _, err := a.captureSnapshot(ctx); err != nil {
		return "NF-HARNESS-capture-api"
	}
	if assertion := a.functionalScenarios(ctx); assertion != "" {
		return assertion
	}
	if assertion := a.mailerAndSMTPFaults(ctx); assertion != "" {
		return assertion
	}
	if assertion := a.duplicateScenario(ctx); assertion != "" {
		return assertion
	}
	if assertion := a.mailerRecreateScenario(ctx); assertion != "" {
		return assertion
	}
	if assertion := a.mattermostRecreateScenario(ctx); assertion != "" {
		return assertion
	}
	if assertion := a.hmacScenarios(ctx); assertion != "" {
		return assertion
	}
	if assertion := a.controlScenarios(ctx); assertion != "" {
		return assertion
	}
	return ""
}

func (a *acceptance) bootstrap(ctx context.Context) string {
	if _, err := a.compose.run(ctx, "exec", "-T", "mattermost", "mmctl", "user", "create",
		"--local", "--suppress-warnings", "--email", "admin@integration.invalid", "--username", "integration-admin",
		"--password", a.cfg.adminPassword, "--system-admin", "--email-verified"); err != nil {
		return "NF-HARNESS-bootstrap-admin-create"
	}
	var loggedIn mmUser
	response, err := a.mattermost.request(ctx, http.MethodPost, "/users/login", map[string]string{
		"login_id": "integration-admin", "password": a.cfg.adminPassword,
	}, &loggedIn, http.StatusOK, http.StatusCreated)
	if err != nil || loggedIn.ID == "" || response.Header.Get("Token") == "" {
		return "NF-HARNESS-bootstrap-admin-login"
	}
	a.mattermost.token = response.Header.Get("Token")
	a.users.admin = loggedIn
	if err := a.waitPluginRuntime(ctx, 60*time.Second); err != nil {
		return "NF-HARNESS-plugin-runtime"
	}

	var team mmTeam
	if _, err := a.mattermost.request(ctx, http.MethodPost, "/teams", map[string]string{
		"name": "integration-team", "display_name": "Integration Team", "type": "O",
	}, &team, http.StatusCreated); err != nil || team.ID == "" {
		return "NF-HARNESS-bootstrap-team-create"
	}
	a.team = team

	users := []struct {
		target   *mmUser
		username string
		email    string
	}{
		{&a.users.recipientA, "integration-recipient-a", "recipient-a@integration.invalid"},
		{&a.users.recipientB, "integration-recipient-b", "recipient-b@integration.invalid"},
		{&a.users.nonMember, "integration-non-member", "non-member@integration.invalid"},
		{&a.users.inactive, "integration-inactive", "inactive@integration.invalid"},
		{&a.users.bot, "integration-bot", "bot@integration.invalid"},
	}
	for _, fixture := range users {
		created, assertion := a.createVerifiedUser(ctx, fixture.username, fixture.email)
		if assertion != "" {
			return assertion
		}
		*fixture.target = created
		if _, err := a.mattermost.request(ctx, http.MethodPost, "/teams/"+team.ID+"/members", map[string]string{
			"team_id": team.ID, "user_id": created.ID,
		}, nil, http.StatusCreated); err != nil {
			return "NF-HARNESS-bootstrap-team-membership"
		}
	}

	var publicChannel, privateChannel mmChannel
	if _, err := a.mattermost.request(ctx, http.MethodPost, "/channels", map[string]string{
		"team_id": team.ID, "name": "integration-public", "display_name": "Integration Public", "type": "O",
	}, &publicChannel, http.StatusCreated); err != nil {
		return "NF-HARNESS-bootstrap-channel-create"
	}
	if _, err := a.mattermost.request(ctx, http.MethodPost, "/channels", map[string]string{
		"team_id": team.ID, "name": "integration-private", "display_name": "Integration Private", "type": "P",
	}, &privateChannel, http.StatusCreated); err != nil {
		return "NF-HARNESS-bootstrap-channel-create"
	}
	a.channels.public, a.channels.private = publicChannel, privateChannel
	for _, channel := range []mmChannel{publicChannel, privateChannel} {
		for _, user := range []mmUser{a.users.recipientA, a.users.recipientB, a.users.inactive, a.users.bot} {
			if _, err := a.mattermost.request(ctx, http.MethodPost, "/channels/"+channel.ID+"/members", map[string]string{"user_id": user.ID}, nil, http.StatusCreated); err != nil {
				return "NF-HARNESS-bootstrap-channel-membership"
			}
		}
	}
	if _, err := a.compose.run(ctx, "exec", "-T", "mattermost", "mmctl", "user", "convert", a.users.bot.Username, "--bot", "--local", "--suppress-warnings"); err != nil {
		return "NF-HARNESS-bootstrap-bot-convert"
	}
	if _, err := a.mattermost.request(ctx, http.MethodPut, "/users/"+a.users.inactive.ID+"/active", map[string]bool{"active": false}, nil, http.StatusOK); err != nil {
		return "NF-HARNESS-bootstrap-inactive-user"
	}
	if err := a.refreshUser(ctx, &a.users.bot); err != nil || !a.users.bot.IsBot {
		return "NF-HARNESS-bootstrap-bot-convert"
	}
	if err := a.refreshUser(ctx, &a.users.inactive); err != nil || a.users.inactive.DeleteAt == 0 {
		return "NF-HARNESS-bootstrap-inactive-user"
	}

	if _, err := a.mattermost.request(ctx, http.MethodPost, "/channels/direct", []string{a.users.admin.ID, a.users.recipientA.ID}, &a.channels.direct, http.StatusCreated); err != nil {
		return "NF-HARNESS-bootstrap-direct-channel"
	}
	if _, err := a.mattermost.request(ctx, http.MethodPost, "/channels/group", []string{a.users.admin.ID, a.users.recipientA.ID, a.users.recipientB.ID}, &a.channels.group, http.StatusCreated); err != nil {
		return "NF-HARNESS-bootstrap-group-direct-channel"
	}
	return ""
}

func (a *acceptance) createVerifiedUser(ctx context.Context, username, email string) (mmUser, string) {
	var user mmUser
	if _, err := a.mattermost.request(ctx, http.MethodPost, "/users", map[string]string{
		"username": username, "email": email, "password": a.cfg.userPassword,
	}, &user, http.StatusCreated); err != nil {
		return mmUser{}, "NF-HARNESS-bootstrap-user-create"
	}
	if _, err := a.compose.run(ctx, "exec", "-T", "mattermost", "mmctl", "user", "verify", username, "--local", "--suppress-warnings"); err != nil {
		return mmUser{}, "NF-HARNESS-bootstrap-user-verify-command"
	}
	return user, ""
}

func (a *acceptance) refreshUser(ctx context.Context, user *mmUser) error {
	var refreshed mmUser
	if _, err := a.mattermost.request(ctx, http.MethodGet, "/users/"+user.ID, nil, &refreshed, http.StatusOK); err != nil {
		return err
	}
	*user = refreshed
	return nil
}

func (a *acceptance) verifyPluginActive(ctx context.Context) error {
	raw, err := a.compose.run(ctx, "exec", "-T", "mattermost", "mmctl", "plugin", "list", "--local", "--suppress-warnings", "--json")
	if err != nil {
		return err
	}
	pluginList, err := os.CreateTemp(a.cfg.root, ".plugin-list.*")
	if err != nil {
		return err
	}
	pluginListPath := pluginList.Name()
	defer os.Remove(pluginListPath)
	if err := pluginList.Chmod(0o600); err != nil {
		_ = pluginList.Close()
		return err
	}
	if _, err := pluginList.Write(raw); err != nil {
		_ = pluginList.Close()
		return err
	}
	if err := pluginList.Close(); err != nil {
		return err
	}
	verifier := filepath.Join(filepath.Dir(a.cfg.composeFile), "verify-plugin-state.sh")
	info, err := os.Lstat(verifier)
	if err != nil || !info.Mode().IsRegular() || info.Mode()&os.ModeSymlink != 0 {
		return errors.New("plugin verifier is unavailable")
	}
	command := exec.CommandContext(ctx, "bash", verifier, pluginListPath, "com.threadhub.channel-email-notifier", "0.2.0")
	command.Stdout = io.Discard
	command.Stderr = io.Discard
	return command.Run()
}

func (a *acceptance) verifyPluginPair(ctx context.Context) error {
	_, err := a.compose.run(ctx, "run", "--rm", "--no-deps", "plugin-install", "verify")
	return err
}

func pluginRuntimeReady(statuses []mmPluginStatus) bool {
	return pluginRuntimeClassification(statuses) == "running"
}

func pluginRuntimeClassification(statuses []mmPluginStatus) string {
	const pluginID = "com.threadhub.channel-email-notifier"
	const pluginVersion = "0.2.0"
	targets := 0
	for _, status := range statuses {
		if status.PluginID != pluginID {
			continue
		}
		targets++
		if status.State != mattermostPluginStateRunning || status.Version != pluginVersion || status.Error != "" {
			return "not-ready"
		}
	}
	if targets != 1 {
		return "not-ready"
	}
	return "running"
}

func (a *acceptance) waitPluginRuntime(ctx context.Context, timeout time.Duration) error {
	lastClassification := ""
	return waitCondition(ctx, timeout, func() bool {
		var statuses []mmPluginStatus
		_, err := a.mattermost.request(ctx, http.MethodGet, "/plugins/statuses", nil, &statuses, http.StatusOK)
		classification := "api-unavailable"
		if err == nil {
			classification = pluginRuntimeClassification(statuses)
		}
		if classification != lastClassification {
			if a.diagnostic != nil {
				_, _ = fmt.Fprintf(a.diagnostic, "plugin-runtime=%s\n", classification)
			}
			lastClassification = classification
		}
		return classification == "running"
	})
}

func (a *acceptance) enableAndRestart(ctx context.Context, activatedAt int64) error {
	if err := writeControl(a.cfg.controlFile, controlState{Enabled: true, DeliveryEnabled: true, Mode: "all_channels", ChannelIDs: []string{}, ActivatedAt: activatedAt}); err != nil {
		return err
	}
	return a.restartMattermostThenMailer(ctx, integrationRestartTimeout)
}

func (a *acceptance) restartMattermostThenMailer(ctx context.Context, timeout time.Duration) error {
	if _, err := a.compose.run(ctx, "restart", "mattermost"); err != nil {
		return err
	}
	if err := waitHTTP(ctx, a.mattermost.client, a.mattermost.baseURL+"/api/v4/system/ping", timeout); err != nil {
		return err
	}
	if err := a.waitPluginRuntime(ctx, timeout); err != nil {
		return err
	}
	if _, err := a.compose.run(ctx, "restart", "threadhub-mailer"); err != nil {
		return err
	}
	return waitHTTP(ctx, a.http, a.cfg.mailerURL.String()+"/healthz", timeout)
}

func writeControl(path string, state controlState) error {
	directory := filepath.Dir(path)
	temporary, err := os.CreateTemp(directory, ".state.*")
	if err != nil {
		return err
	}
	temporaryPath := temporary.Name()
	defer os.Remove(temporaryPath)
	if err := temporary.Chmod(0o640); err != nil {
		_ = temporary.Close()
		return err
	}
	encoder := json.NewEncoder(temporary)
	encoder.SetEscapeHTML(false)
	if err := encoder.Encode(state); err != nil {
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
	return os.Rename(temporaryPath, path)
}

func waitHTTP(ctx context.Context, client *http.Client, endpoint string, timeout time.Duration) error {
	return waitCondition(ctx, timeout, func() bool {
		request, err := http.NewRequestWithContext(ctx, http.MethodGet, endpoint, nil)
		if err != nil {
			return false
		}
		response, err := client.Do(request)
		if err != nil {
			return false
		}
		defer response.Body.Close()
		_, _ = io.Copy(io.Discard, io.LimitReader(response.Body, 1024))
		return response.StatusCode >= 200 && response.StatusCode < 300
	})
}

func waitCondition(ctx context.Context, timeout time.Duration, check func() bool) error {
	deadline := time.NewTimer(timeout)
	defer deadline.Stop()
	ticker := time.NewTicker(250 * time.Millisecond)
	defer ticker.Stop()
	for {
		if check() {
			return nil
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-deadline.C:
			return errors.New("condition timeout")
		case <-ticker.C:
		}
	}
}

func (a *acceptance) smtpTrustProbe(ctx context.Context) error {
	raw, err := a.compose.runWithInput(ctx, []byte("probe@integration.invalid\n"), "exec", "-T", "threadhub-mailer", "/threadhub-mailer", "smtp-test", "--recipient-stdin")
	if err != nil || bytes.Contains(raw, []byte("@")) {
		return errors.New("SMTP trust probe failed")
	}
	var output struct {
		Fingerprint string `json:"config_fingerprint"`
	}
	if json.Unmarshal(raw, &output) != nil || len(output.Fingerprint) != 64 {
		return errors.New("SMTP trust probe failed")
	}
	return nil
}

func (a *acceptance) captureSnapshot(ctx context.Context) (captureSnapshot, error) {
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, a.cfg.captureURL.String()+"/v1/captures", nil)
	if err != nil {
		return captureSnapshot{}, err
	}
	response, err := a.http.Do(request)
	if err != nil {
		return captureSnapshot{}, err
	}
	defer response.Body.Close()
	raw, err := io.ReadAll(io.LimitReader(response.Body, 1<<20))
	if err != nil || response.StatusCode != http.StatusOK || bytes.Contains(raw, []byte("@")) {
		return captureSnapshot{}, errors.New("invalid capture response")
	}
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.DisallowUnknownFields()
	var snapshot captureSnapshot
	if err := decoder.Decode(&snapshot); err != nil || requireJSONEnd(decoder) != nil || !validateCaptureSnapshot(snapshot) {
		return captureSnapshot{}, errors.New("invalid capture response")
	}
	return snapshot, nil
}

func requireJSONEnd(decoder *json.Decoder) error {
	var extra any
	if err := decoder.Decode(&extra); errors.Is(err, io.EOF) {
		return nil
	}
	return errors.New("trailing JSON")
}

func (a *acceptance) mailerStatus(ctx context.Context) (mailerStatus, error) {
	raw, err := a.compose.run(ctx, "exec", "-T", "threadhub-mailer", "/threadhub-mailer", "status", "--json")
	if err != nil {
		return mailerStatus{}, err
	}
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.DisallowUnknownFields()
	var status mailerStatus
	if err := decoder.Decode(&status); err != nil || requireJSONEnd(decoder) != nil || !validateMailerStatus(status) {
		return mailerStatus{}, errors.New("invalid Mailer status")
	}
	return status, nil
}

func validateMailerStatus(status mailerStatus) bool {
	if status.Pending < 0 || status.Sending < 0 || status.Sent < 0 || status.Failed < 0 ||
		status.OldestPendingSeconds < 0 || status.LastSuccessAt < 0 || status.LastSMTPCode < 0 ||
		status.LastSMTPCode > 999 || status.LastSMTPCode > 0 && status.LastSMTPCode < 100 {
		return false
	}
	switch status.LastErrorClass {
	case "", "temporary", "permanent", "timeout", "protocol":
		return true
	default:
		return false
	}
}

func (a *acceptance) waitMailerIdle(ctx context.Context, timeout time.Duration) error {
	return waitCondition(ctx, timeout, func() bool {
		status, err := a.mailerStatus(ctx)
		return err == nil && status.Pending == 0 && status.Sending == 0
	})
}

func (a *acceptance) waitExactDelta(ctx context.Context, before captureSnapshot, expected map[string]int, timeout time.Duration) error {
	return waitCondition(ctx, timeout, func() bool {
		after, err := a.captureSnapshot(ctx)
		if err != nil || !hasExactDelta(before, after, expected) {
			return false
		}
		status, err := a.mailerStatus(ctx)
		return err == nil && status.Pending == 0 && status.Sending == 0
	})
}

func firstCaptureLatency(createdAtMS int64, before, after captureSnapshot, hashes []string) (time.Duration, bool) {
	if createdAtMS <= 0 || len(hashes) == 0 || !validateCaptureSnapshot(before) || !validateCaptureSnapshot(after) {
		return 0, false
	}
	beforeMap, afterMap := captureMap(before), captureMap(after)
	var first time.Duration
	found := false
	seen := make(map[string]struct{}, len(hashes))
	for _, hash := range hashes {
		if _, duplicate := seen[hash]; duplicate {
			return 0, false
		}
		seen[hash] = struct{}{}
		prior, current := beforeMap[hash], afterMap[hash]
		delta := current.EnvelopeCount - prior.EnvelopeCount
		if delta < 0 || delta > 1 {
			return 0, false
		}
		if delta == 0 {
			continue
		}
		if prior.EnvelopeCount > 0 && current.LastAttemptAtMS <= prior.LastAttemptAtMS {
			return 0, false
		}
		latencyMS := current.LastAttemptAtMS - createdAtMS
		if latencyMS < 0 {
			return 0, false
		}
		latency := time.Duration(latencyMS) * time.Millisecond
		if !found || latency < first {
			first, found = latency, true
		}
	}
	return first, found
}

func (a *acceptance) waitFirstCapture(ctx context.Context, createdAtMS int64, before captureSnapshot, hashes []string, timeout time.Duration) (time.Duration, error) {
	var latency time.Duration
	err := waitCondition(ctx, timeout, func() bool {
		after, err := a.captureSnapshot(ctx)
		if err != nil {
			return false
		}
		measured, ok := firstCaptureLatency(createdAtMS, before, after, hashes)
		if ok {
			latency = measured
		}
		return ok
	})
	return latency, err
}

func (a *acceptance) post(ctx context.Context, channelID, rootID string) (mmPost, time.Duration, error) {
	input := map[string]string{"channel_id": channelID, "message": "integration-post"}
	if rootID != "" {
		input["root_id"] = rootID
	}
	started := time.Now()
	var post mmPost
	_, err := a.mattermost.request(ctx, http.MethodPost, "/posts", input, &post, http.StatusCreated)
	return post, time.Since(started), err
}

func (a *acceptance) recipientHash(email string) string {
	return protocol.HashIdentifier(a.cfg.hashSecret, "integration-recipient", strings.ToLower(email))
}

func (a *acceptance) expectedAB() map[string]int {
	return map[string]int{
		a.recipientHash(a.users.recipientA.Email): 1,
		a.recipientHash(a.users.recipientB.Email): 1,
		a.recipientHash(a.users.nonMember.Email):  0,
		a.recipientHash(a.users.inactive.Email):   0,
		a.recipientHash(a.users.bot.Email):        0,
	}
}

func (a *acceptance) functionalScenarios(ctx context.Context) string {
	before, err := a.captureSnapshot(ctx)
	if err != nil {
		return "NF-HARNESS-capture-api"
	}
	publicRoot, postResponseLatency, err := a.post(ctx, a.channels.public.ID, "")
	if err != nil {
		return "NF-FN-01-public-root"
	}
	if a.diagnostic != nil {
		_, _ = fmt.Fprintf(a.diagnostic, "first-post-response-ms=%d\n", postResponseLatency.Milliseconds())
	}
	firstLatency, err := a.waitFirstCapture(ctx, publicRoot.CreateAt, before, []string{a.recipientHash(a.users.recipientA.Email), a.recipientHash(a.users.recipientB.Email)}, 10*time.Second)
	if a.diagnostic != nil && err == nil {
		_, _ = fmt.Fprintf(a.diagnostic, "first-smtp-attempt-ms=%d\n", firstLatency.Milliseconds())
	}
	if err != nil || firstLatency > 10*time.Second {
		return "NF-FN-01-first-attempt-latency"
	}
	if err := a.waitMailerIdle(ctx, 30*time.Second); err != nil {
		return "NF-FN-01-public-root"
	}
	after, err := a.captureSnapshot(ctx)
	if err != nil {
		return "NF-HARNESS-capture-api"
	}
	deltas := captureDeltas(before, after)
	if deltas[a.recipientHash(a.users.nonMember.Email)] != 0 {
		return "NF-FN-05-non-member-excluded"
	}
	if deltas[a.recipientHash(a.users.inactive.Email)] != 0 {
		return "NF-FN-06-inactive-user-excluded"
	}
	if deltas[a.recipientHash(a.users.bot.Email)] != 0 {
		return "NF-FN-07-bot-recipient-excluded"
	}
	if deltas[a.recipientHash(a.users.recipientA.Email)] != 1 || deltas[a.recipientHash(a.users.recipientB.Email)] != 1 {
		return "NF-FN-01-public-root"
	}
	if !captureMap(after)[a.recipientHash(a.users.recipientA.Email)].GenericContent || !captureMap(after)[a.recipientHash(a.users.recipientB.Email)].GenericContent {
		return "NF-SEC-01-generic-content"
	}

	before, _ = a.captureSnapshot(ctx)
	privateRoot, _, err := a.post(ctx, a.channels.private.ID, "")
	if err != nil || a.waitExactDelta(ctx, before, a.expectedAB(), 30*time.Second) != nil {
		return "NF-FN-02-private-root"
	}
	before, _ = a.captureSnapshot(ctx)
	if _, _, err := a.post(ctx, a.channels.public.ID, publicRoot.ID); err != nil || a.waitExactDelta(ctx, before, a.expectedAB(), 30*time.Second) != nil {
		return "NF-FN-03-public-thread-reply"
	}
	before, _ = a.captureSnapshot(ctx)
	if _, _, err := a.post(ctx, a.channels.private.ID, privateRoot.ID); err != nil || a.waitExactDelta(ctx, before, a.expectedAB(), 30*time.Second) != nil {
		return "NF-FN-04-private-thread-reply"
	}

	before, _ = a.captureSnapshot(ctx)
	if _, _, err := a.post(ctx, a.channels.direct.ID, ""); err != nil {
		return "NF-FN-08-direct-excluded"
	}
	if _, _, err := a.post(ctx, a.channels.public.ID, ""); err != nil || a.waitExactDelta(ctx, before, a.expectedAB(), 30*time.Second) != nil {
		return "NF-FN-08-direct-excluded"
	}
	before, _ = a.captureSnapshot(ctx)
	if _, _, err := a.post(ctx, a.channels.group.ID, ""); err != nil {
		return "NF-FN-08-group-direct-excluded"
	}
	if _, _, err := a.post(ctx, a.channels.public.ID, ""); err != nil || a.waitExactDelta(ctx, before, a.expectedAB(), 30*time.Second) != nil {
		return "NF-FN-08-group-direct-excluded"
	}
	return ""
}

func captureDeltas(before, after captureSnapshot) map[string]int {
	result := make(map[string]int)
	beforeMap, afterMap := captureMap(before), captureMap(after)
	for hash, value := range beforeMap {
		result[hash] = afterMap[hash].EnvelopeCount - value.EnvelopeCount
	}
	for hash, value := range afterMap {
		if _, exists := beforeMap[hash]; !exists {
			result[hash] = value.EnvelopeCount
		}
	}
	return result
}

func (a *acceptance) mailerAndSMTPFaults(ctx context.Context) string {
	before, err := a.captureSnapshot(ctx)
	if err != nil {
		return "NF-HARNESS-capture-api"
	}
	if _, err := a.compose.run(ctx, "stop", "threadhub-mailer"); err != nil {
		return "NF-HARNESS-compose"
	}
	if _, latency, err := a.post(ctx, a.channels.public.ID, ""); err != nil || latency > 3*time.Second {
		return "NF-REL-01-mailer-down-post-latency"
	}
	if err := a.startMailer(ctx); err != nil {
		return "NF-REL-01-mailer-restart"
	}
	if err := a.waitExactDelta(ctx, before, a.expectedAB(), 35*time.Second); err != nil {
		return "NF-REL-01-mailer-replay"
	}

	before, err = a.captureSnapshot(ctx)
	if err != nil {
		return "NF-HARNESS-capture-api"
	}
	if _, err := a.compose.run(ctx, "stop", "smtp-fixture"); err != nil {
		return "NF-HARNESS-compose"
	}
	if _, latency, err := a.post(ctx, a.channels.public.ID, ""); err != nil || latency > 3*time.Second {
		return "NF-REL-01-smtp-down-post-latency"
	}
	if err := waitCondition(ctx, 15*time.Second, func() bool {
		status, statusErr := a.mailerStatus(ctx)
		return statusErr == nil && status.Pending > 0 && status.LastErrorClass == "temporary"
	}); err != nil {
		return "NF-REL-01-smtp-pending"
	}
	if _, err := a.compose.run(ctx, "up", "-d", "--no-build", "--no-deps", "smtp-fixture"); err != nil {
		return "NF-REL-01-smtp-restart"
	}
	if err := waitHTTP(ctx, a.http, a.cfg.captureURL.String()+"/healthz", 60*time.Second); err != nil {
		return "NF-REL-01-smtp-restart"
	}
	if err := a.waitExactDelta(ctx, before, a.expectedAB(), 50*time.Second); err != nil {
		return "NF-REL-01-smtp-resume"
	}
	return ""
}

func (a *acceptance) duplicateScenario(ctx context.Context) string {
	before, err := a.captureSnapshot(ctx)
	if err != nil {
		return "NF-HARNESS-capture-api"
	}
	event := a.syntheticEvent(1, a.users.recipientA)
	for range 2 {
		nonce, err := randomNonce()
		if err != nil {
			return "NF-REL-03-duplicate-event-dedupe"
		}
		status, err := a.sendSignedEvent(ctx, event, time.Now().Unix(), nonce, "")
		if err != nil || status != http.StatusAccepted {
			return "NF-REL-03-duplicate-event-dedupe"
		}
	}
	if err := a.waitExactDelta(ctx, before, a.expectedA(), 35*time.Second); err != nil {
		return "NF-REL-03-duplicate-event-dedupe"
	}
	return ""
}

func (a *acceptance) mailerRecreateScenario(ctx context.Context) string {
	before, err := a.captureSnapshot(ctx)
	if err != nil {
		return "NF-HARNESS-capture-api"
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, a.cfg.captureURL.String()+"/v1/fail-next", http.NoBody)
	if err != nil {
		return "NF-REL-04-temporary-retry"
	}
	response, err := a.http.Do(request)
	if err != nil {
		return "NF-REL-04-temporary-retry"
	}
	_, _ = io.Copy(io.Discard, io.LimitReader(response.Body, 1024))
	_ = response.Body.Close()
	if response.StatusCode != http.StatusNoContent {
		return "NF-REL-04-temporary-retry"
	}
	if _, _, err := a.post(ctx, a.channels.public.ID, ""); err != nil {
		return "NF-REL-04-temporary-retry"
	}
	if err := waitCondition(ctx, 15*time.Second, func() bool {
		status, statusErr := a.mailerStatus(ctx)
		return statusErr == nil && status.Pending > 0 && status.LastSMTPCode == 450
	}); err != nil {
		return "NF-REL-04-temporary-retry"
	}
	if _, err := a.compose.run(ctx, "up", "-d", "--no-build", "--no-deps", "--force-recreate", "threadhub-mailer"); err != nil {
		return "NF-REL-04-mailer-recreate"
	}
	mailerURL, err := a.serviceURL(ctx, "threadhub-mailer", "8080")
	if err != nil {
		return "NF-REL-04-mailer-recreate"
	}
	a.cfg.mailerURL = mailerURL
	if err := waitHTTP(ctx, a.http, mailerURL.String()+"/healthz", 60*time.Second); err != nil {
		return "NF-REL-04-mailer-recreate"
	}
	if err := a.waitExactDelta(ctx, before, a.expectedAB(), 50*time.Second); err != nil {
		return "NF-REL-04-mailer-recreate"
	}
	return ""
}

func (a *acceptance) mattermostRecreateScenario(ctx context.Context) string {
	before, err := a.captureSnapshot(ctx)
	if err != nil {
		return "NF-HARNESS-capture-api"
	}
	if _, err := a.compose.run(ctx, "stop", "threadhub-mailer"); err != nil {
		return "NF-HARNESS-compose"
	}
	if _, _, err := a.post(ctx, a.channels.public.ID, ""); err != nil {
		return "NF-REL-05-mattermost-recreate-post"
	}
	if _, err := a.compose.run(ctx, "up", "-d", "--no-build", "--no-deps", "--force-recreate", "mattermost"); err != nil {
		return "NF-REL-05-mattermost-recreate-start"
	}
	mattermostURL, err := a.serviceURL(ctx, "mattermost", "8065")
	if err != nil {
		return "NF-REL-05-mattermost-recreate-endpoint"
	}
	a.cfg.mattermostURL = mattermostURL
	a.mattermost.baseURL = mattermostURL.String()
	if err := waitHTTP(ctx, a.mattermost.client, mattermostURL.String()+"/api/v4/system/ping", 120*time.Second); err != nil {
		return "NF-REL-05-mattermost-recreate-ping"
	}
	if err := a.verifyPluginActive(ctx); err != nil {
		return "NF-REL-05-mattermost-recreate-plugin-active"
	}
	if err := a.waitPluginRuntime(ctx, 120*time.Second); err != nil {
		return "NF-REL-05-mattermost-recreate-plugin-runtime"
	}
	if err := a.verifyPluginPair(ctx); err != nil {
		return "NF-HARNESS-plugin-pair"
	}
	if err := a.startMailer(ctx); err != nil {
		return "NF-REL-05-mattermost-recreate-mailer-start"
	}
	if err := a.waitExactDelta(ctx, before, a.expectedAB(), 40*time.Second); err != nil {
		return "NF-REL-05-mattermost-recreate-delivery"
	}
	return ""
}

func (a *acceptance) hmacScenarios(ctx context.Context) string {
	now := time.Now().Unix()
	badEvent := a.syntheticEvent(2, a.users.recipientA)
	nonce, _ := randomNonce()
	badSignature := "sha256=" + strings.Repeat("0", 64)
	if status, err := a.sendSignedEvent(ctx, badEvent, now, nonce, badSignature); err != nil || status != http.StatusUnauthorized {
		return "NF-SEC-04-bad-hmac"
	}
	staleEvent := a.syntheticEvent(3, a.users.recipientA)
	nonce, _ = randomNonce()
	if status, err := a.sendSignedEvent(ctx, staleEvent, now-301, nonce, ""); err != nil || status != http.StatusUnauthorized {
		return "NF-SEC-05-stale-timestamp"
	}
	before, err := a.captureSnapshot(ctx)
	if err != nil {
		return "NF-HARNESS-capture-api"
	}
	replayEvent := a.syntheticEvent(4, a.users.recipientA)
	nonce, _ = randomNonce()
	if status, err := a.sendSignedEvent(ctx, replayEvent, now, nonce, ""); err != nil || status != http.StatusAccepted {
		return "NF-SEC-06-nonce-replay"
	}
	if status, err := a.sendSignedEvent(ctx, replayEvent, now, nonce, ""); err != nil || status != http.StatusConflict {
		return "NF-SEC-06-nonce-replay"
	}
	if err := a.waitExactDelta(ctx, before, a.expectedA(), 35*time.Second); err != nil {
		return "NF-SEC-06-nonce-replay"
	}
	return ""
}

func (a *acceptance) controlScenarios(ctx context.Context) string {
	before, err := a.captureSnapshot(ctx)
	if err != nil {
		return "NF-HARNESS-capture-api"
	}
	if err := writeControl(a.cfg.controlFile, controlState{Enabled: false, DeliveryEnabled: false, Mode: "all_channels", ChannelIDs: []string{}, ActivatedAt: time.Now().UnixMilli()}); err != nil {
		return "NF-REL-05-control-disable-write"
	}
	if _, err := a.compose.run(ctx, "restart", "mattermost"); err != nil {
		return "NF-REL-05-control-disable-restart"
	}
	if err := waitHTTP(ctx, a.mattermost.client, a.mattermost.baseURL+"/api/v4/system/ping", integrationRestartTimeout); err != nil {
		return "NF-REL-05-control-disable-wait"
	}
	if err := a.waitPluginRuntime(ctx, integrationRestartTimeout); err != nil {
		return "NF-REL-05-control-disable-wait"
	}
	if _, err := a.compose.run(ctx, "restart", "threadhub-mailer"); err != nil {
		return "NF-REL-05-control-disable-restart"
	}
	if err := waitHTTP(ctx, a.http, a.cfg.mailerURL.String()+"/healthz", integrationRestartTimeout); err != nil {
		return "NF-REL-05-control-disable-wait"
	}
	if err := a.verifyPluginPair(ctx); err != nil {
		return "NF-HARNESS-plugin-pair"
	}
	disabledPost, _, err := a.post(ctx, a.channels.public.ID, "")
	if err != nil {
		return "NF-REL-05-control-disable-post"
	}
	if err := a.enableAndRestart(ctx, disabledPost.CreateAt+1); err != nil {
		return "NF-REL-05-control-disable-enable"
	}
	if err := a.verifyPluginPair(ctx); err != nil {
		return "NF-HARNESS-plugin-pair"
	}
	if _, _, err := a.post(ctx, a.channels.public.ID, ""); err != nil {
		return "NF-REL-05-control-disable-post-enabled"
	}
	if err := a.waitExactDelta(ctx, before, a.expectedAB(), 35*time.Second); err != nil {
		return "NF-REL-05-control-disable-delivery"
	}

	before, err = a.captureSnapshot(ctx)
	if err != nil {
		return "NF-HARNESS-capture-api"
	}
	if _, err := a.compose.run(ctx, "stop", "threadhub-mailer"); err != nil {
		return "NF-HARNESS-compose"
	}
	cutoffPost, _, err := a.post(ctx, a.channels.public.ID, "")
	if err != nil {
		return "NF-REL-05-activation-cutoff"
	}
	if err := writeControl(a.cfg.controlFile, controlState{Enabled: true, DeliveryEnabled: true, Mode: "all_channels", ChannelIDs: []string{}, ActivatedAt: cutoffPost.CreateAt + 1}); err != nil {
		return "NF-REL-05-activation-cutoff"
	}
	if _, err := a.compose.run(ctx, "restart", "mattermost"); err != nil {
		return "NF-REL-05-activation-cutoff"
	}
	if err := waitHTTP(ctx, a.mattermost.client, a.mattermost.baseURL+"/api/v4/system/ping", integrationRestartTimeout); err != nil || a.verifyPluginActive(ctx) != nil || a.waitPluginRuntime(ctx, integrationRestartTimeout) != nil {
		return "NF-REL-05-activation-cutoff"
	}
	if err := a.verifyPluginPair(ctx); err != nil {
		return "NF-HARNESS-plugin-pair"
	}
	if err := a.startMailer(ctx); err != nil {
		return "NF-REL-05-activation-cutoff"
	}
	if _, _, err := a.post(ctx, a.channels.public.ID, ""); err != nil || a.waitExactDelta(ctx, before, a.expectedAB(), 35*time.Second) != nil {
		return "NF-REL-05-activation-cutoff"
	}
	return ""
}

func (a *acceptance) expectedA() map[string]int {
	return map[string]int{
		a.recipientHash(a.users.recipientA.Email): 1,
		a.recipientHash(a.users.recipientB.Email): 0,
		a.recipientHash(a.users.nonMember.Email):  0,
		a.recipientHash(a.users.inactive.Email):   0,
		a.recipientHash(a.users.bot.Email):        0,
	}
}

func (a *acceptance) syntheticEvent(sequence int, recipient mmUser) protocol.Event {
	id := fmt.Sprintf("%026x", sequence)
	return protocol.Event{
		EventID: id, PostID: id, Permalink: "https://" + a.cfg.domain + "/_redirect/pl/" + id,
		OccurredAt: time.Now().UnixMilli(), Recipients: []protocol.Recipient{{UserID: recipient.ID, Email: recipient.Email}},
	}
}

func (a *acceptance) sendSignedEvent(ctx context.Context, event protocol.Event, timestamp int64, nonce, signatureOverride string) (int, error) {
	request, _, err := newSignedRequest(a.cfg.mailerURL.String(), a.cfg.hmacSecret, event, timestamp, nonce)
	if err != nil {
		return 0, err
	}
	request = request.WithContext(ctx)
	if signatureOverride != "" {
		request.Header.Set("X-ThreadHub-Signature", signatureOverride)
	}
	response, err := a.http.Do(request)
	if err != nil {
		return 0, err
	}
	defer response.Body.Close()
	_, _ = io.Copy(io.Discard, io.LimitReader(response.Body, 1024))
	return response.StatusCode, nil
}

func (a *acceptance) startMailer(ctx context.Context) error {
	if _, err := a.compose.run(ctx, "up", "-d", "--no-build", "--no-deps", "threadhub-mailer"); err != nil {
		return err
	}
	mailerURL, err := a.serviceURL(ctx, "threadhub-mailer", "8080")
	if err != nil {
		return err
	}
	a.cfg.mailerURL = mailerURL
	return waitHTTP(ctx, a.http, mailerURL.String()+"/healthz", 60*time.Second)
}

func (a *acceptance) serviceURL(ctx context.Context, service, port string) (*url.URL, error) {
	var current *url.URL
	switch service + ":" + port {
	case "mattermost:8065":
		current = a.cfg.mattermostURL
	case "threadhub-mailer:8080":
		current = a.cfg.mailerURL
	default:
		return nil, errors.New("invalid integration service")
	}
	if filepath.Base(a.cfg.containerCommand[0]) == "podman" {
		return current, nil
	}
	rawID, err := a.compose.run(ctx, "ps", "--status", "running", "--quiet", service)
	if err != nil {
		return nil, err
	}
	containerID := strings.TrimSpace(string(rawID))
	address, err := a.container.privateIPv4(ctx, containerID, a.cfg.projectName+"_notifier")
	if err != nil {
		return nil, err
	}
	return parseIntegrationURL("http://" + net.JoinHostPort(address, port))
}

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	os.Exit(runMain(ctx, os.Getenv, os.Stdout))
}

func runMain(ctx context.Context, getenv func(string) string, output io.Writer) int {
	report := &reporter{output: output}
	cfg, err := loadConfig(getenv)
	if err != nil {
		_ = report.failure("NF-HARNESS-config")
		return 1
	}
	result := newAcceptance(cfg).run(ctx)
	if result != "" {
		if report.failure(result) != nil {
			_ = report.failure("NF-HARNESS-compose")
		}
		return 1
	}
	for _, id := range requiredScenarioIDs {
		if report.success(id) != nil {
			return 1
		}
	}
	return 0
}
