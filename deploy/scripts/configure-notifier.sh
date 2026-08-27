#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"
# shellcheck source=notifier-lib.sh
source "${SCRIPT_DIR}/notifier-lib.sh"

[[ "$#" -eq 0 ]] || die "Usage: $0"
require_command openssl
if [[ ! -e "${ENV_FILE}" && ! -L "${ENV_FILE}" ]]; then
    printf '[ACTION REQUIRED] Create %s with ./deploy/scripts/setup-wizard.sh --configure-only\n' \
        "${ENV_FILE}" >&2
    exit 20
fi
set +e
runtime_env_require_secure "${ENV_FILE}"
secure_env_result=$?
set -e
((secure_env_result == 0)) || exit "${secure_env_result}"

lock_dir="${ENV_FILE}.configure.lock"
if ! mkdir -m 0700 "${lock_dir}" 2>/dev/null; then
    printf '[ACTION REQUIRED] Another notifier configuration operation is in progress; no value was changed.\n' >&2
    exit 20
fi
temporary_env=
cleanup_configure() {
    [[ -z "${temporary_env}" ]] || rm -f "${temporary_env}"
    rmdir "${lock_dir}" >/dev/null 2>&1 || true
}
trap cleanup_configure EXIT
runtime_env_require_secure "${ENV_FILE}" >/dev/null 2>&1 || {
    printf '[ACTION REQUIRED] Runtime environment changed while notifier configuration was starting; no value was changed.\n' >&2
    exit 20
}
original_identity="$(runtime_env_identity "${ENV_FILE}")"
original_hash="$(sha256_file "${ENV_FILE}")"

case "$(notifier_env_key_state "${ENV_FILE}")" in
    complete)
        validate_notifier_env
        log "Reusing the complete notifier configuration; no value was changed"
        ;;
    none)
        validate_base_env
        validate_smtp_env
        hmac_secret="$(openssl rand -hex 32)"
        temporary_env="$(mktemp "${ENV_FILE}.tmp.XXXXXX")"
        chmod 0600 "${temporary_env}"
        cp "${ENV_FILE}" "${temporary_env}"
        {
            printf '%s\n' \
                'NOTIFIER_ENABLED=true' \
                'NOTIFIER_MODE=all_channels' \
                'NOTIFIER_CHANNEL_IDS='
            printf 'NOTIFIER_HMAC_SECRET=%s\n' "${hmac_secret}"
            printf '%s\n' 'NOTIFIER_RATE_PER_MINUTE=10'
        } >> "${temporary_env}"
        chmod 0600 "${temporary_env}"
        original_env_file="${ENV_FILE}"
        ENV_FILE="${temporary_env}"
        validate_runtime_env
        ENV_FILE="${original_env_file}"
        if ! runtime_env_replace_if_unchanged \
            "${temporary_env}" "${ENV_FILE}" "${original_identity}" "${original_hash}"; then
            printf '[ACTION REQUIRED] Runtime environment changed during notifier configuration; it was not overwritten.\n' >&2
            exit 20
        fi
        temporary_env=
        log "Added a complete notifier configuration with a generated protected HMAC secret"
        ;;
    *)
        printf '[ACTION REQUIRED] Notifier configuration is partial; restore a complete set or remove every NOTIFIER_* key.\n' >&2
        printf 'Then run: ./deploy/scripts/configure-notifier.sh\n' >&2
        exit 20
        ;;
esac
