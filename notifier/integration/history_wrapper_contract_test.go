package integration_test

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

const historicalV020Commit = "7602555a21fe5e110eafa1d685a61c95d53969d8"

func TestV020HistoricalRunnerExecutesOnlyTheSelectedSuiteAtThePinnedCommit(t *testing.T) {
	t.Parallel()

	for _, suite := range []string{"existing-adoption", "existing-upgrade"} {
		suite := suite
		t.Run(suite, func(t *testing.T) {
			t.Parallel()
			fixture := t.TempDir()
			logPath := filepath.Join(fixture, "git-and-runner.log")
			fakeGit := filepath.Join(fixture, "git")
			writeExecutable(t, fakeGit, `#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$*" >>"${HISTORY_TEST_LOG}"
[[ "$1" == -C ]]
case "$3 $4" in
    'cat-file -e')
        [[ "$5" == '`+historicalV020Commit+`^{commit}' ]]
        ;;
    'worktree add')
        [[ "$5" == --detach && "$7" == '`+historicalV020Commit+`' ]]
        historical_root="$6"
        install -d -m 0755 "${historical_root}/notifier/integration"
        for runner in run-existing-adoption.sh run-existing-upgrade.sh; do
            printf '%s\n' \
                '#!/usr/bin/env bash' \
                'set -Eeuo pipefail' \
                'printf "runner=%s\\n" "${0##*/}" >>"${HISTORY_TEST_LOG}"' \
                'printf "result=%s\\n" "${INTEGRATION_RESULT_FILE:-}" >>"${HISTORY_TEST_LOG}"' \
                >"${historical_root}/notifier/integration/${runner}"
            chmod 0755 "${historical_root}/notifier/integration/${runner}"
        done
        ;;
    'worktree remove')
        [[ "$5" == --force ]]
        ;;
    *)
        exit 64
        ;;
esac
`)

			evidencePath := filepath.Join(fixture, "evidence", "results.txt")
			command := exec.Command("bash", "run-v020-history.sh", suite)
			command.Env = append(os.Environ(),
				"PATH="+fixture+":"+os.Getenv("PATH"),
				"HISTORY_TEST_LOG="+logPath,
				"INTEGRATION_RESULT_FILE="+evidencePath,
			)
			output, err := command.CombinedOutput()
			if err != nil {
				t.Fatalf("historical runner failed: %v\n%s", err, output)
			}

			log := readContractFile(t, logPath)
			for _, required := range []string{
				"cat-file -e " + historicalV020Commit + "^{commit}",
				"worktree add --detach",
				" " + historicalV020Commit,
				"runner=run-" + suite + ".sh",
				"result=" + evidencePath,
				"worktree remove --force",
			} {
				if !strings.Contains(log, required) {
					t.Fatalf("historical runner log is missing %q:\n%s", required, log)
				}
			}
			otherSuite := "existing-adoption"
			if suite == otherSuite {
				otherSuite = "existing-upgrade"
			}
			if strings.Contains(log, "runner=run-"+otherSuite+".sh") {
				t.Fatalf("historical runner executed unselected suite %q", otherSuite)
			}
		})
	}
}

func TestV020HistoricalRunnerRejectsUnknownOrExtraArgumentsBeforeGit(t *testing.T) {
	t.Parallel()

	for _, arguments := range [][]string{{}, {"unknown"}, {"existing-adoption", "extra"}} {
		fixture := t.TempDir()
		logPath := filepath.Join(fixture, "git.log")
		fakeGit := filepath.Join(fixture, "git")
		writeExecutable(t, fakeGit, `#!/usr/bin/env bash
printf '%s\n' "$*" >>"${HISTORY_TEST_LOG}"
exit 99
`)

		command := exec.Command("bash", append([]string{"run-v020-history.sh"}, arguments...)...)
		command.Env = append(os.Environ(),
			"PATH="+fixture+":"+os.Getenv("PATH"),
			"HISTORY_TEST_LOG="+logPath,
		)
		err := command.Run()
		if err == nil {
			t.Fatalf("arguments %q unexpectedly succeeded", arguments)
		}
		exitError, ok := err.(*exec.ExitError)
		if !ok || exitError.ExitCode() != 2 {
			t.Fatalf("arguments %q exit = %v, want 2", arguments, err)
		}
		if _, statErr := os.Stat(logPath); !os.IsNotExist(statErr) {
			t.Fatalf("arguments %q reached git before rejection", arguments)
		}
	}
}

func writeExecutable(t *testing.T, path, content string) {
	t.Helper()
	if err := os.WriteFile(path, []byte(content), 0o755); err != nil {
		t.Fatal(err)
	}
}
