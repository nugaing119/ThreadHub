package pluginstate

import (
	"bytes"
	"encoding/json"
	"io"
)

type State uint8

const (
	Invalid State = iota
	Inactive
	Active
)

type listedPlugin struct {
	ID      string `json:"id"`
	Version string `json:"version"`
}

func Classify(raw []byte, pluginID, version string) State {
	if pluginID == "" || version == "" {
		return Invalid
	}
	decoder := json.NewDecoder(bytes.NewReader(raw))
	var payload json.RawMessage
	if err := decoder.Decode(&payload); err != nil {
		return Invalid
	}
	var extra any
	if err := decoder.Decode(&extra); err != io.EOF {
		return Invalid
	}
	trimmed := bytes.TrimSpace(payload)
	if len(trimmed) == 0 {
		return Invalid
	}
	if trimmed[0] == '[' {
		var nodes []json.RawMessage
		if err := json.Unmarshal(trimmed, &nodes); err != nil || len(nodes) != 1 {
			return Invalid
		}
		trimmed = bytes.TrimSpace(nodes[0])
	}
	if len(trimmed) == 0 || trimmed[0] != '{' {
		return Invalid
	}
	var envelope map[string]json.RawMessage
	if err := json.Unmarshal(trimmed, &envelope); err != nil || len(envelope) != 2 {
		return Invalid
	}
	activeRaw, hasActive := envelope["active"]
	inactiveRaw, hasInactive := envelope["inactive"]
	if !hasActive || !hasInactive {
		return Invalid
	}
	var active, inactive []listedPlugin
	if err := json.Unmarshal(activeRaw, &active); err != nil || active == nil {
		return Invalid
	}
	if err := json.Unmarshal(inactiveRaw, &inactive); err != nil || inactive == nil {
		return Invalid
	}

	activeMatches, inactiveMatches := 0, 0
	for _, plugin := range active {
		if plugin.ID != pluginID {
			continue
		}
		if plugin.Version != version {
			return Invalid
		}
		activeMatches++
	}
	for _, plugin := range inactive {
		if plugin.ID != pluginID {
			continue
		}
		if plugin.Version != version {
			return Invalid
		}
		inactiveMatches++
	}
	if activeMatches == 1 && inactiveMatches == 0 {
		return Active
	}
	if activeMatches == 0 && inactiveMatches == 1 {
		return Inactive
	}
	return Invalid
}
