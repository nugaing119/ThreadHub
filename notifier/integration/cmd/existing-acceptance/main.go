package main

import (
	"bytes"
	"context"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"

	"github.com/nugaing119/ThreadHub/notifier/protocol"
)

const (
	mattermostURL = "http://127.0.0.1:49153"
	captureURL    = "http://127.0.0.1:49353"
)

var (
	mattermostIDPattern  = regexp.MustCompile(`^[a-z0-9]{26}$`)
	recipientHashPattern = regexp.MustCompile(`^[a-f0-9]{64}$`)
)

type config struct {
	statePath, snapshotPath, adminPassword, userPassword string
	hashSecret                                           []byte
}

type state struct {
	Schema            int    `json:"schema"`
	TeamID            string `json:"team_id"`
	PublicChannelID   string `json:"public_channel_id"`
	PrivateChannelID  string `json:"private_channel_id"`
	ExcludedChannelID string `json:"excluded_channel_id"`
	DirectChannelID   string `json:"direct_channel_id"`
	SystemUserID      string `json:"system_user_id"`
	BaselinePostID    string `json:"baseline_post_id"`
}

type user struct {
	ID       string `json:"id"`
	Username string `json:"username"`
	Email    string `json:"email"`
}

type team struct {
	ID string `json:"id"`
}

type channel struct {
	ID string `json:"id"`
}

type post struct {
	ID       string `json:"id"`
	CreateAt int64  `json:"create_at"`
}

type capture struct {
	RecipientHash  string `json:"recipient_hash"`
	EnvelopeCount  int    `json:"envelope_count"`
	GenericContent bool   `json:"generic_content"`
	LastAttemptMS  int64  `json:"last_attempt_at_ms"`
}

type captureSnapshot struct {
	Captures []capture `json:"captures"`
}

type client struct {
	http  *http.Client
	token string
}

func main() {
	if err := run(context.Background(), os.Args[1:]); err != nil {
		_, _ = fmt.Fprintln(os.Stderr, "existing adoption acceptance failed")
		os.Exit(1)
	}
}

func run(ctx context.Context, args []string) error {
	if len(args) != 1 {
		return errors.New("invalid command")
	}
	cfg, err := loadConfig()
	if err != nil {
		return err
	}
	c := &client{http: &http.Client{Timeout: 8 * time.Second}}
	switch args[0] {
	case "bootstrap":
		return bootstrap(ctx, cfg, c)
	case "verify-baseline":
		return verifyBaseline(ctx, cfg, c)
	case "exercise":
		return exercise(ctx, cfg, c)
	case "snapshot":
		snapshot, err := getCaptures(ctx, c)
		if err != nil {
			return err
		}
		return writeJSON(cfg.snapshotPath, snapshot)
	case "outage-post":
		if err := login(ctx, cfg, c); err != nil {
			return err
		}
		current, err := readState(cfg.statePath)
		if err != nil {
			return err
		}
		started := time.Now()
		_, err = createPost(ctx, c, current.PublicChannelID, "")
		if err != nil || time.Since(started) > 3*time.Second {
			return errors.New("outage post failed")
		}
		return nil
	case "assert-outage":
		before, err := readSnapshot(cfg.snapshotPath)
		if err != nil {
			return err
		}
		return waitDelta(ctx, c, cfg.hashSecret, before, map[string]int{
			"recipient-a@integration.invalid": 1,
			"recipient-b@integration.invalid": 1,
		}, 60*time.Second)
	default:
		return errors.New("invalid command")
	}
}

func loadConfig() (config, error) {
	cfg := config{
		statePath:     os.Getenv("EXISTING_ACCEPTANCE_STATE_FILE"),
		snapshotPath:  os.Getenv("EXISTING_ACCEPTANCE_SNAPSHOT_FILE"),
		adminPassword: os.Getenv("EXISTING_ACCEPTANCE_ADMIN_PASSWORD"),
		userPassword:  os.Getenv("EXISTING_ACCEPTANCE_USER_PASSWORD"),
	}
	secret, err := hex.DecodeString(os.Getenv("EXISTING_ACCEPTANCE_HASH_SECRET"))
	if err != nil || len(secret) != 32 {
		return config{}, errors.New("invalid hash secret")
	}
	cfg.hashSecret = secret
	for _, path := range []string{cfg.statePath, cfg.snapshotPath} {
		if !filepath.IsAbs(path) || filepath.Clean(path) != path || filepath.Base(path) == "." {
			return config{}, errors.New("invalid state path")
		}
	}
	if filepath.Dir(cfg.statePath) != filepath.Dir(cfg.snapshotPath) || cfg.adminPassword == "" || cfg.userPassword == "" || strings.ContainsAny(cfg.adminPassword+cfg.userPassword, "\r\n") {
		return config{}, errors.New("invalid configuration")
	}
	return cfg, nil
}

func (c *client) request(ctx context.Context, method, path string, input, output any, statuses ...int) (*http.Response, error) {
	var body io.Reader
	if input != nil {
		raw, err := json.Marshal(input)
		if err != nil {
			return nil, err
		}
		body = bytes.NewReader(raw)
	}
	req, err := http.NewRequestWithContext(ctx, method, mattermostURL+"/api/v4"+path, body)
	if err != nil {
		return nil, err
	}
	if input != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	if c.token != "" {
		req.Header.Set("Authorization", "Bearer "+c.token)
	}
	response, err := c.http.Do(req)
	if err != nil {
		return nil, err
	}
	defer response.Body.Close()
	accepted := false
	for _, status := range statuses {
		accepted = accepted || response.StatusCode == status
	}
	limited := io.LimitReader(response.Body, 2<<20)
	if !accepted {
		_, _ = io.Copy(io.Discard, limited)
		return response, errors.New("Mattermost request rejected")
	}
	if output != nil {
		decoder := json.NewDecoder(limited)
		if err := decoder.Decode(output); err != nil {
			return response, err
		}
	} else {
		_, _ = io.Copy(io.Discard, limited)
	}
	return response, nil
}

func login(ctx context.Context, cfg config, c *client) error {
	var loggedIn user
	response, err := c.request(ctx, http.MethodPost, "/users/login", map[string]string{
		"login_id": "existing-admin", "password": cfg.adminPassword,
	}, &loggedIn, http.StatusOK, http.StatusCreated)
	if err != nil || loggedIn.ID == "" || response.Header.Get("Token") == "" {
		return errors.New("login failed")
	}
	c.token = response.Header.Get("Token")
	return nil
}

func bootstrap(ctx context.Context, cfg config, c *client) error {
	if _, err := os.Lstat(cfg.statePath); !errors.Is(err, os.ErrNotExist) {
		return errors.New("state already exists")
	}
	if err := login(ctx, cfg, c); err != nil {
		return err
	}
	var fixtureTeam team
	if _, err := c.request(ctx, http.MethodPost, "/teams", map[string]string{
		"name": "existing-adoption", "display_name": "Existing Adoption", "type": "O",
	}, &fixtureTeam, http.StatusCreated); err != nil || fixtureTeam.ID == "" {
		return errors.New("team create failed")
	}
	users := make(map[string]user)
	for _, value := range []struct{ username, email string }{
		{"existing-recipient-a", "recipient-a@integration.invalid"},
		{"existing-recipient-b", "recipient-b@integration.invalid"},
		{"existing-non-member", "non-member@integration.invalid"},
		{"existing-system-user", "system-user@integration.invalid"},
	} {
		var created user
		if _, err := c.request(ctx, http.MethodPost, "/users", map[string]string{
			"username": value.username, "email": value.email, "password": cfg.userPassword,
		}, &created, http.StatusCreated); err != nil || created.ID == "" {
			return errors.New("user create failed")
		}
		users[value.username] = created
		if value.username != "existing-non-member" {
			if _, err := c.request(ctx, http.MethodPost, "/teams/"+fixtureTeam.ID+"/members", map[string]string{
				"team_id": fixtureTeam.ID, "user_id": created.ID,
			}, nil, http.StatusCreated); err != nil {
				return errors.New("team membership failed")
			}
		}
	}
	createChannel := func(name, display, channelType string) (channel, error) {
		var result channel
		_, err := c.request(ctx, http.MethodPost, "/channels", map[string]string{
			"team_id": fixtureTeam.ID, "name": name, "display_name": display, "type": channelType,
		}, &result, http.StatusCreated)
		return result, err
	}
	publicChannel, err := createChannel("existing-public", "Existing Public", "O")
	if err != nil {
		return err
	}
	privateChannel, err := createChannel("existing-private", "Existing Private", "P")
	if err != nil {
		return err
	}
	excludedChannel, err := createChannel("existing-excluded", "Existing Excluded", "O")
	if err != nil {
		return err
	}
	for _, membership := range []struct{ channelID, userID string }{
		{publicChannel.ID, users["existing-recipient-a"].ID},
		{publicChannel.ID, users["existing-recipient-b"].ID},
		{privateChannel.ID, users["existing-recipient-a"].ID},
		{excludedChannel.ID, users["existing-recipient-a"].ID},
		{excludedChannel.ID, users["existing-recipient-b"].ID},
	} {
		if _, err := c.request(ctx, http.MethodPost, "/channels/"+membership.channelID+"/members", map[string]string{"user_id": membership.userID}, nil, http.StatusCreated); err != nil {
			return errors.New("channel membership failed")
		}
	}
	var admin user
	if _, err := c.request(ctx, http.MethodGet, "/users/username/existing-admin", nil, &admin, http.StatusOK); err != nil {
		return err
	}
	var direct channel
	if _, err := c.request(ctx, http.MethodPost, "/channels/direct", []string{admin.ID, users["existing-recipient-a"].ID}, &direct, http.StatusCreated); err != nil {
		return err
	}
	baseline, err := createPost(ctx, c, publicChannel.ID, "")
	if err != nil {
		return err
	}
	return writeJSON(cfg.statePath, state{
		Schema: 1, TeamID: fixtureTeam.ID, PublicChannelID: publicChannel.ID,
		PrivateChannelID: privateChannel.ID, ExcludedChannelID: excludedChannel.ID,
		DirectChannelID: direct.ID, SystemUserID: users["existing-system-user"].ID,
		BaselinePostID: baseline.ID,
	})
}

func verifyBaseline(ctx context.Context, cfg config, c *client) error {
	if err := login(ctx, cfg, c); err != nil {
		return err
	}
	current, err := readState(cfg.statePath)
	if err != nil {
		return err
	}
	var found post
	_, err = c.request(ctx, http.MethodGet, "/posts/"+current.BaselinePostID, nil, &found, http.StatusOK)
	if err != nil || found.ID != current.BaselinePostID {
		return errors.New("baseline missing")
	}
	return nil
}

func exercise(ctx context.Context, cfg config, c *client) error {
	if err := login(ctx, cfg, c); err != nil {
		return err
	}
	current, err := readState(cfg.statePath)
	if err != nil {
		return err
	}
	before, err := getCaptures(ctx, c)
	if err != nil {
		return err
	}
	publicRoot, err := createPost(ctx, c, current.PublicChannelID, "")
	if err != nil {
		return err
	}
	privateRoot, err := createPost(ctx, c, current.PrivateChannelID, "")
	if err != nil {
		return err
	}
	if _, err = createPost(ctx, c, current.PublicChannelID, publicRoot.ID); err != nil {
		return err
	}
	if _, err = createPost(ctx, c, current.PrivateChannelID, privateRoot.ID); err != nil {
		return err
	}
	if _, err = createPost(ctx, c, current.ExcludedChannelID, ""); err != nil {
		return err
	}
	if _, err = createPost(ctx, c, current.DirectChannelID, ""); err != nil {
		return err
	}
	if _, err = c.request(ctx, http.MethodPost, "/channels/"+current.PublicChannelID+"/members", map[string]string{"user_id": current.SystemUserID}, nil, http.StatusCreated); err != nil {
		return err
	}
	return waitDelta(ctx, c, cfg.hashSecret, before, map[string]int{
		"recipient-a@integration.invalid": 4,
		"recipient-b@integration.invalid": 2,
		"non-member@integration.invalid":  0,
		"system-user@integration.invalid": 0,
		"admin@integration.invalid":       0,
	}, 60*time.Second)
}

func createPost(ctx context.Context, c *client, channelID, rootID string) (post, error) {
	input := map[string]string{"channel_id": channelID, "message": "integration-post"}
	if rootID != "" {
		input["root_id"] = rootID
	}
	var result post
	_, err := c.request(ctx, http.MethodPost, "/posts", input, &result, http.StatusCreated)
	if err != nil || result.ID == "" {
		return post{}, errors.New("post failed")
	}
	return result, nil
}

func getCaptures(ctx context.Context, c *client) (captureSnapshot, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, captureURL+"/v1/captures", nil)
	if err != nil {
		return captureSnapshot{}, err
	}
	response, err := c.http.Do(req)
	if err != nil {
		return captureSnapshot{}, err
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return captureSnapshot{}, errors.New("capture unavailable")
	}
	decoder := json.NewDecoder(io.LimitReader(response.Body, 1<<20))
	decoder.DisallowUnknownFields()
	var snapshot captureSnapshot
	if decoder.Decode(&snapshot) != nil || snapshot.Captures == nil {
		return captureSnapshot{}, errors.New("invalid capture")
	}
	var extra any
	if err := decoder.Decode(&extra); !errors.Is(err, io.EOF) {
		return captureSnapshot{}, errors.New("invalid capture")
	}
	seen := make(map[string]struct{}, len(snapshot.Captures))
	for _, item := range snapshot.Captures {
		if !recipientHashPattern.MatchString(item.RecipientHash) || item.EnvelopeCount < 1 || !item.GenericContent || item.LastAttemptMS <= 0 {
			return captureSnapshot{}, errors.New("invalid capture")
		}
		if _, duplicate := seen[item.RecipientHash]; duplicate {
			return captureSnapshot{}, errors.New("invalid capture")
		}
		seen[item.RecipientHash] = struct{}{}
	}
	return snapshot, nil
}

func waitDelta(ctx context.Context, c *client, secret []byte, before captureSnapshot, expected map[string]int, timeout time.Duration) error {
	beforeCounts := captureCounts(before)
	expectedHashes := make(map[string]int, len(expected))
	for email, count := range expected {
		expectedHashes[protocol.HashIdentifier(secret, "integration-recipient", strings.ToLower(email))] = count
	}
	deadline := time.NewTimer(timeout)
	defer deadline.Stop()
	ticker := time.NewTicker(250 * time.Millisecond)
	defer ticker.Stop()
	for {
		after, err := getCaptures(ctx, c)
		if err == nil {
			afterCounts := captureCounts(after)
			matched := true
			for hash, count := range expectedHashes {
				matched = matched && afterCounts[hash]-beforeCounts[hash] == count
			}
			if matched {
				return nil
			}
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-deadline.C:
			return errors.New("capture timeout")
		case <-ticker.C:
		}
	}
}

func captureCounts(snapshot captureSnapshot) map[string]int {
	result := make(map[string]int, len(snapshot.Captures))
	for _, item := range snapshot.Captures {
		result[item.RecipientHash] = item.EnvelopeCount
	}
	return result
}

func writeJSON(path string, value any) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	temporary, err := os.CreateTemp(filepath.Dir(path), ".existing-acceptance.*")
	if err != nil {
		return err
	}
	temporaryPath := temporary.Name()
	defer os.Remove(temporaryPath)
	if err := temporary.Chmod(0o600); err != nil {
		_ = temporary.Close()
		return err
	}
	encoder := json.NewEncoder(temporary)
	encoder.SetEscapeHTML(false)
	if err := encoder.Encode(value); err != nil {
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

func readState(path string) (state, error) {
	var result state
	if err := readJSON(path, &result); err != nil {
		return state{}, err
	}
	if result.Schema != 1 || !validMattermostID(result.TeamID) || !validMattermostID(result.PublicChannelID) || !validMattermostID(result.PrivateChannelID) || !validMattermostID(result.ExcludedChannelID) || !validMattermostID(result.DirectChannelID) || !validMattermostID(result.SystemUserID) || !validMattermostID(result.BaselinePostID) {
		return state{}, errors.New("invalid state")
	}
	return result, nil
}

func validMattermostID(value string) bool {
	return mattermostIDPattern.MatchString(value)
}

func readSnapshot(path string) (captureSnapshot, error) {
	var result captureSnapshot
	if err := readJSON(path, &result); err != nil || result.Captures == nil {
		return captureSnapshot{}, errors.New("invalid snapshot")
	}
	return result, nil
}

func readJSON(path string, output any) error {
	info, err := os.Lstat(path)
	if err != nil || !info.Mode().IsRegular() || info.Mode().Perm() != 0o600 || info.Size() <= 0 || info.Size() > 1<<20 {
		return errors.New("invalid state file")
	}
	file, err := os.Open(path)
	if err != nil {
		return err
	}
	defer file.Close()
	decoder := json.NewDecoder(io.LimitReader(file, 1<<20))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(output); err != nil {
		return err
	}
	var extra any
	if err := decoder.Decode(&extra); !errors.Is(err, io.EOF) {
		return errors.New("trailing state")
	}
	return nil
}
