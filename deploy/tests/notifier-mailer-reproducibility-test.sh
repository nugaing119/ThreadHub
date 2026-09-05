#!/usr/bin/env bash

# The Docker wrapper and command arrays are consumed indirectly by the sourced
# production artifact builder.
# shellcheck disable=SC2034,SC2329

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPOSITORY_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd -P)"

command -v docker >/dev/null 2>&1
command -v git >/dev/null 2>&1
command -v sudo >/dev/null 2>&1
sudo -n true

fixture_root="$(mktemp -d)"
first_mailer_id=""
second_mailer_id=""
first_bundle_id=""
second_bundle_id=""

cleanup() {
    sudo docker image rm -f \
        "${first_mailer_id}" "${second_mailer_id}" \
        "${first_bundle_id}" "${second_bundle_id}" >/dev/null 2>&1 || true
    sudo rm -rf -- "${fixture_root}"
}
trap cleanup EXIT HUP INT TERM

create_repository() {
    local destination="$1" commit_epoch="$2"

    install -d -m 0755 "${destination}"
    git -C "${REPOSITORY_ROOT}" archive --format=tar HEAD \
        | tar -xf - -C "${destination}"
    git -C "${destination}" init -q
    git -C "${destination}" add .
    GIT_AUTHOR_DATE="@${commit_epoch} +0000" \
        GIT_COMMITTER_DATE="@${commit_epoch} +0000" \
        git -C "${destination}" \
            -c user.name=ThreadHub \
            -c user.email=threadhub@example.invalid \
            commit -q -m fixture
}

build_repository() (
    local repository="$1" release_dir="$2"

    # shellcheck source=/dev/null
    source "${repository}/deploy/scripts/common.sh"
    # shellcheck source=/dev/null
    source "${repository}/deploy/scripts/notifier-artifact-build-lib.sh"
    docker_without_cache() {
        if [[ "$1" == build ]]; then
            shift
            sudo docker build --no-cache "$@"
        else
            sudo docker "$@"
        fi
    }
    DOCKER_COMMAND=(docker_without_cache)
    SUDO_COMMAND=(sudo)
    "${SUDO_COMMAND[@]}" install -d -o root -g root -m 0750 "${release_dir}"
    notifier_build_artifacts "${release_dir}" >/dev/null
)

read_release_value() {
    local release_file="$1" key="$2"

    sudo awk -F= -v key="${key}" '
        $1 == key { count++; value = substr($0, index($0, "=") + 1) }
        END { if (count != 1 || value == "") exit 1; print value }
    ' "${release_file}"
}

first_repository="${fixture_root}/first"
second_repository="${fixture_root}/second"
first_release="${fixture_root}/first-release"
second_release="${fixture_root}/second-release"

# The trees are identical, while the commit timestamps and IDs are different.
create_repository "${first_repository}" 1577836800
create_repository "${second_repository}" 1893456000
[[ "$(git -C "${first_repository}" rev-parse 'HEAD^{tree}')" \
    == "$(git -C "${second_repository}" rev-parse 'HEAD^{tree}')" ]]
[[ "$(git -C "${first_repository}" rev-parse HEAD)" \
    != "$(git -C "${second_repository}" rev-parse HEAD)" ]]

build_repository "${first_repository}" "${first_release}"
first_mailer_id="$(read_release_value \
    "${first_release}/release.env" NOTIFIER_MAILER_IMAGE_ID)"
first_bundle_id="$(sudo docker image inspect --format '{{.Id}}' \
    threadhub/notifier-plugin-bundle:0.2.0)"

build_repository "${second_repository}" "${second_release}"
second_mailer_id="$(read_release_value \
    "${second_release}/release.env" NOTIFIER_MAILER_IMAGE_ID)"
second_bundle_id="$(sudo docker image inspect --format '{{.Id}}' \
    threadhub/notifier-plugin-bundle:0.2.0)"

[[ "${first_mailer_id}" == "${second_mailer_id}" ]]
printf '%s\n' 'ok - Mailer image identity is independent of source commit time'
