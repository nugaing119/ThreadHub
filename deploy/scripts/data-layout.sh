#!/usr/bin/env bash

set -Eeuo pipefail

DATA_LAYOUT_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! declare -F validate_notifier_host_path >/dev/null 2>&1; then
    # shellcheck source=common.sh
    source "${DATA_LAYOUT_SCRIPT_DIR}/common.sh"
fi

data_layout_paths() {
    local data_root="$1" mattermost_root notifier_root

    mattermost_root="${data_root}/mattermost"
    notifier_root="${data_root}/notifier"
    printf '%s\n' \
        "${data_root}" \
        "${data_root}/postgres" \
        "${mattermost_root}" \
        "${mattermost_root}/config" \
        "${mattermost_root}/data" \
        "${mattermost_root}/data/plugins" \
        "${mattermost_root}/logs" \
        "${mattermost_root}/plugins" \
        "${mattermost_root}/client" \
        "${mattermost_root}/client/plugins" \
        "${mattermost_root}/bleve-indexes" \
        "${notifier_root}" \
        "${notifier_root}/control" \
        "${notifier_root}/mailer" \
        "${notifier_root}/release"
}

data_layout_assert_no_symlink_components() {
    local data_root="$1" path

    while IFS= read -r path; do
        [[ ! -L "${path}" ]] || return 1
        [[ ! -e "${path}" || -d "${path}" ]] || return 1
    done < <(data_layout_paths "${data_root}")
}

data_layout_validate_root() {
    local data_root="$1"

    [[ "${data_root}" == /srv/threadhub ]] || return 1
    data_layout_assert_no_symlink_components "${data_root}" || return 1
    validate_notifier_host_path "${data_root}"
}

prepare_threadhub_data_layout() {
    local data_root="$1" mattermost_root notifier_root
    local -a mattermost_mutable_paths

    data_layout_validate_root "${data_root}" || return 20
    mattermost_root="${data_root}/mattermost"
    notifier_root="${data_root}/notifier"

    "${SUDO_COMMAND[@]}" install -d -o root -g root -m 0750 "${data_root}" || return 20
    data_layout_validate_root "${data_root}" || return 20
    "${SUDO_COMMAND[@]}" install -d -o root -g root -m 0750 "${notifier_root}" || return 20
    data_layout_validate_root "${data_root}" || return 20
    "${SUDO_COMMAND[@]}" install -d -o root -g 3000 -m 0750 "${notifier_root}/control" || return 20
    data_layout_validate_root "${data_root}" || return 20
    "${SUDO_COMMAND[@]}" install -d -o 65532 -g 65532 -m 0700 "${notifier_root}/mailer" || return 20
    data_layout_validate_root "${data_root}" || return 20
    "${SUDO_COMMAND[@]}" install -d -o root -g root -m 0750 "${notifier_root}/release" || return 20
    data_layout_validate_root "${data_root}" || return 20

    # PostgreSQL 18 creates its versioned PGDATA below this traversable root.
    "${SUDO_COMMAND[@]}" install -d -m 0755 "${data_root}/postgres" || return 20
    data_layout_validate_root "${data_root}" || return 20
    "${SUDO_COMMAND[@]}" install -d -m 0750 \
        "${mattermost_root}/config" \
        "${mattermost_root}/data" \
        "${mattermost_root}/data/plugins" \
        "${mattermost_root}/logs" \
        "${mattermost_root}/plugins" \
        "${mattermost_root}/client/plugins" \
        "${mattermost_root}/bleve-indexes" || return 20
    data_layout_assert_no_symlink_components "${data_root}" || return 20

    # Preserve the plugin runtime tree's contents while restoring canonical
    # metadata on the mutable Mattermost paths used by the containers.
    mattermost_mutable_paths=(
        "${mattermost_root}/config"
        "${mattermost_root}/data"
        "${mattermost_root}/logs"
        "${mattermost_root}/client/plugins"
        "${mattermost_root}/bleve-indexes"
    )
    "${SUDO_COMMAND[@]}" chown 2000:2000 "${mattermost_root}" "${mattermost_root}/plugins" || return 20
    "${SUDO_COMMAND[@]}" chmod 0750 "${mattermost_root}" "${mattermost_root}/plugins" || return 20
    data_layout_assert_no_symlink_components "${data_root}" || return 20
    "${SUDO_COMMAND[@]}" chown -R 2000:2000 "${mattermost_mutable_paths[@]}" || return 20
    "${SUDO_COMMAND[@]}" chmod -R u=rwX,g=rX,o= "${mattermost_mutable_paths[@]}" || return 20
    data_layout_validate_root "${data_root}"
}

normalize_threadhub_restored_data() {
    local data_root="$1" mattermost_data

    data_layout_validate_root "${data_root}" || return 20
    mattermost_data="${data_root}/mattermost/data"
    [[ -d "${mattermost_data}" && ! -L "${mattermost_data}" ]] || return 20
    if find -P "${mattermost_data}" -mindepth 1 ! -type f ! -type d -print -quit 2>/dev/null \
        | grep -q .; then
        return 20
    fi
    data_layout_validate_root "${data_root}" || return 20
    "${SUDO_COMMAND[@]}" chown -R 2000:2000 "${mattermost_data}" || return 20
    "${SUDO_COMMAND[@]}" chmod -R u=rwX,g=rX,o= "${mattermost_data}" || return 20
    data_layout_validate_root "${data_root}"
}
