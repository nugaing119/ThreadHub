#!/usr/bin/env bash

set -Eeuo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
repository_root="$(cd -- "${script_dir}/../.." && pwd -P)"
notifier_root="${repository_root}/notifier"
temporary_dir="$(mktemp -d)"
trap 'rm -rf -- "${temporary_dir}"' EXIT HUP INT TERM

module_version="$(
    cd "${notifier_root}"
    go list -m -f '{{.Path}} {{.Version}}' golang.org/x/crypto
)"
[[ "${module_version}" == 'golang.org/x/crypto v0.56.0' ]]

(
    cd "${notifier_root}"
    go list -deps ./...
) | LC_ALL=C awk '/^golang\.org\/x\/crypto\// { print }' | LC_ALL=C sort -u \
    >"${temporary_dir}/actual"
printf '%s\n' \
    'golang.org/x/crypto/pbkdf2' \
    'golang.org/x/crypto/scrypt' \
    >"${temporary_dir}/expected"
diff -u "${temporary_dir}/expected" "${temporary_dir}/actual"
printf '%s\n' 'ok - notifier x/crypto dependency scope is exact'
