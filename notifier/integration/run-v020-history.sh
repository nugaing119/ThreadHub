#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
repository_root="$(cd -- "${script_dir}/../.." && pwd -P)"
historical_commit=7602555a21fe5e110eafa1d685a61c95d53969d8

case "${1:-}" in
    existing-adoption) runner=run-existing-adoption.sh ;;
    existing-upgrade) runner=run-existing-upgrade.sh ;;
    *)
        printf '%s\n' \
            'usage: run-v020-history.sh existing-adoption|existing-upgrade' >&2
        exit 2
        ;;
esac
[[ "$#" -eq 1 ]] || exit 2

temporary_parent="$(mktemp -d)"
historical_root="${temporary_parent}/threadhub-v020"
worktree_added=false

cleanup() {
    if [[ "${worktree_added}" == true ]]; then
        git -C "${repository_root}" worktree remove --force \
            "${historical_root}" >/dev/null 2>&1 || true
    fi
    rm -rf -- "${temporary_parent}"
}
trap cleanup EXIT HUP INT TERM

git -C "${repository_root}" cat-file -e "${historical_commit}^{commit}"
git -C "${repository_root}" worktree add --detach \
    "${historical_root}" "${historical_commit}" >/dev/null
worktree_added=true

"${historical_root}/notifier/integration/${runner}"
