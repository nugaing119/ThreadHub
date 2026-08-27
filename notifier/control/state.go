// Package control loads the shared fail-closed runtime notification state.
package control

import (
	"encoding/json"
	"errors"
	"io"
	"os"
	"regexp"
)

var (
	errInvalidState = errors.New("invalid notifier control state")
	channelID       = regexp.MustCompile(`^[a-z0-9]{26}$`)
)

type State struct {
	Enabled         bool     `json:"enabled"`
	DeliveryEnabled bool     `json:"delivery_enabled"`
	Mode            string   `json:"mode"`
	ChannelIDs      []string `json:"channel_ids"`
	ActivatedAt     int64    `json:"activated_at"`
}

func (s State) AllowsChannel(candidate string) bool {
	if !s.Enabled || !channelID.MatchString(candidate) {
		return false
	}
	if s.Mode == "all_channels" {
		return true
	}
	if s.Mode != "allowlist" {
		return false
	}
	for _, allowed := range s.ChannelIDs {
		if candidate == allowed {
			return true
		}
	}
	return false
}

func Load(path string) (State, error) {
	file, err := os.Open(path)
	if err != nil {
		return State{}, err
	}
	defer file.Close()

	type encodedState struct {
		Enabled         *bool     `json:"enabled"`
		DeliveryEnabled *bool     `json:"delivery_enabled"`
		Mode            *string   `json:"mode"`
		ChannelIDs      *[]string `json:"channel_ids"`
		ActivatedAt     *int64    `json:"activated_at"`
	}
	var encoded encodedState
	decoder := json.NewDecoder(file)
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&encoded); err != nil {
		return State{}, errInvalidState
	}
	if err := requireJSONEnd(decoder); err != nil {
		return State{}, errInvalidState
	}
	if encoded.Enabled == nil || encoded.DeliveryEnabled == nil || encoded.Mode == nil || encoded.ChannelIDs == nil || encoded.ActivatedAt == nil {
		return State{}, errInvalidState
	}
	state := State{
		Enabled:         *encoded.Enabled,
		DeliveryEnabled: *encoded.DeliveryEnabled,
		Mode:            *encoded.Mode,
		ChannelIDs:      append([]string(nil), (*encoded.ChannelIDs)...),
		ActivatedAt:     *encoded.ActivatedAt,
	}
	if !validState(state) {
		return State{}, errInvalidState
	}
	return state, nil
}

func requireJSONEnd(decoder *json.Decoder) error {
	var trailing any
	err := decoder.Decode(&trailing)
	if errors.Is(err, io.EOF) {
		return nil
	}
	return errInvalidState
}

func validState(state State) bool {
	if state.ActivatedAt < 0 || state.Enabled && (!state.DeliveryEnabled || state.ActivatedAt == 0) {
		return false
	}
	switch state.Mode {
	case "all_channels":
		return len(state.ChannelIDs) == 0
	case "allowlist":
		if len(state.ChannelIDs) == 0 {
			return false
		}
		seen := make(map[string]struct{}, len(state.ChannelIDs))
		for _, id := range state.ChannelIDs {
			if !channelID.MatchString(id) {
				return false
			}
			if _, exists := seen[id]; exists {
				return false
			}
			seen[id] = struct{}{}
		}
		return true
	default:
		return false
	}
}
