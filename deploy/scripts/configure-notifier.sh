#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"
# shellcheck source=notifier-lib.sh
source "${SCRIPT_DIR}/notifier-lib.sh"

[[ "$#" -eq 0 ]] || die "Usage: $0"
require_file "${ENV_FILE}"
[[ ! -L "${ENV_FILE}" ]] || die "Refusing symbolic-link runtime environment"
require_command openssl

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
        cleanup_env() {
            rm -f "${temporary_env}"
        }
        trap cleanup_env EXIT
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
        mv "${temporary_env}" "${ENV_FILE}"
        trap - EXIT
        log "Added a complete notifier configuration with a generated protected HMAC secret"
        ;;
    *)
        printf '[ACTION REQUIRED] Notifier configuration is partial; restore a complete set or remove every NOTIFIER_* key.\n' >&2
        printf 'Then run: ./deploy/scripts/configure-notifier.sh\n' >&2
        exit 20
        ;;
esac
