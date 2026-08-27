package main

import "testing"

func TestClassifyPluginStateRequiresOneExactTarget(t *testing.T) {
	t.Parallel()

	const pluginID = "com.threadhub.channel-email-notifier"
	const version = "0.1.0"
	for name, test := range map[string]struct {
		raw  string
		want pluginState
	}{
		"active": {
			raw:  `{"active":[{"id":"other","version":"2"},{"id":"com.threadhub.channel-email-notifier","version":"0.1.0"}],"inactive":[]}`,
			want: pluginActive,
		},
		"active singleton node response": {
			raw:  `[{"active":[{"id":"com.threadhub.channel-email-notifier","version":"0.1.0"}],"inactive":[]}]`,
			want: pluginActive,
		},
		"inactive": {
			raw:  `{"active":[],"inactive":[{"id":"com.threadhub.channel-email-notifier","version":"0.1.0"}]}`,
			want: pluginInactive,
		},
		"inactive singleton node response": {
			raw:  `[{"active":[],"inactive":[{"id":"com.threadhub.channel-email-notifier","version":"0.1.0"}]}]`,
			want: pluginInactive,
		},
		"multiple node responses": {
			raw:  `[{"active":[],"inactive":[]},{"active":[],"inactive":[]}]`,
			want: pluginInvalid,
		},
		"wrong version": {
			raw:  `{"active":[{"id":"com.threadhub.channel-email-notifier","version":"0.2.0"}],"inactive":[]}`,
			want: pluginInvalid,
		},
		"duplicate": {
			raw:  `{"active":[{"id":"com.threadhub.channel-email-notifier","version":"0.1.0"},{"id":"com.threadhub.channel-email-notifier","version":"0.1.0"}],"inactive":[]}`,
			want: pluginInvalid,
		},
		"both states": {
			raw:  `{"active":[{"id":"com.threadhub.channel-email-notifier","version":"0.1.0"}],"inactive":[{"id":"com.threadhub.channel-email-notifier","version":"0.1.0"}]}`,
			want: pluginInvalid,
		},
		"missing": {
			raw:  `{"active":[],"inactive":[]}`,
			want: pluginInvalid,
		},
		"trailing": {
			raw:  `{"active":[],"inactive":[]} {}`,
			want: pluginInvalid,
		},
		"malformed": {
			raw:  `{"active":`,
			want: pluginInvalid,
		},
	} {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			if got := classifyPluginState([]byte(test.raw), pluginID, version); got != test.want {
				t.Fatalf("classifyPluginState() = %v, want %v", got, test.want)
			}
		})
	}
}
