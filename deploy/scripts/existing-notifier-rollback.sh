#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! declare -F existing_notifier_setup_dispatch >/dev/null 2>&1; then
    # shellcheck source=existing-notifier-setup.sh
    source "${SCRIPT_DIR}/existing-notifier-setup.sh"
fi

EXISTING_NOTIFIER_ROLLBACK_STATE_FILE=""
EXISTING_NOTIFIER_ROLLBACK_FAILED_DISPOSITION=""

existing_notifier_rollback_action_required() {
    printf '[ACTION REQUIRED] %s\n' "$1" >&2
    return 20
}

existing_notifier_rollback_validate() {
    existing_notifier_setup_validate_config || return $?
    existing_notifier_init_compose
    EXISTING_NOTIFIER_ROLLBACK_STATE_FILE="$(existing_notifier_value THN_DATA_ROOT)/control/state.json"
    existing_notifier_validate_control_path "${EXISTING_NOTIFIER_ROLLBACK_STATE_FILE}"
}

existing_notifier_rollback_require_disabled() {
    local state_file="${EXISTING_NOTIFIER_ROLLBACK_STATE_FILE}"

    notifier_control_is_valid "${state_file}" \
        || die "Existing notifier control state is invalid"
    "${SUDO_COMMAND[@]}" jq -e \
        '.enabled == false and .delivery_enabled == false' \
        "${state_file}" >/dev/null 2>&1 \
        || {
            existing_notifier_rollback_action_required \
                "Disable the notifier before rollback"
            return $?
        }
}

existing_notifier_rollback_require_quiescent_queue() (
    local status_file
    local failed

    status_file="$(mktemp)"
    trap 'rm -f -- "${status_file}"' EXIT HUP INT TERM
    existing_notifier_compose_combined exec -T threadhub-mailer \
        /threadhub-mailer status --json > "${status_file}" \
        || die "Existing notifier Mailer status is unavailable"
    notifier_mailer_status_is_valid "${status_file}" \
        || die "Existing notifier Mailer returned invalid status JSON"
    jq -e '.pending == 0 and .sending == 0' "${status_file}" >/dev/null \
        || {
            existing_notifier_rollback_action_required \
                "Rollback requires zero pending and sending deliveries"
            return $?
        }
    failed="$(jq -r '.failed' "${status_file}")"
    if ((failed > 0)); then
        case "${EXISTING_NOTIFIER_ROLLBACK_FAILED_DISPOSITION}" in
            retry)
                existing_notifier_compose_combined exec -T threadhub-mailer \
                    /threadhub-mailer retry-failed >/dev/null
                ;;
            cancel)
                existing_notifier_compose_combined exec -T threadhub-mailer \
                    /threadhub-mailer cancel-failed >/dev/null
                ;;
            *)
                existing_notifier_rollback_action_required \
                    "Failed deliveries exist; choose --retry-failed or --cancel-failed explicitly"
                return $?
                ;;
        esac
        existing_notifier_compose_combined exec -T threadhub-mailer \
            /threadhub-mailer status --json > "${status_file}" \
            || die "Existing notifier Mailer status is unavailable after failed-delivery disposition"
        notifier_mailer_status_is_valid "${status_file}" \
            && jq -e '.pending == 0 and .sending == 0 and .failed == 0' \
                "${status_file}" >/dev/null \
            || {
                existing_notifier_rollback_action_required \
                    "Failed-delivery disposition is incomplete; drain the queue and retry rollback"
                return $?
            }
    fi
)

existing_notifier_rollback_require_verified_capture() {
    local capture_file

    capture_file="$(existing_notifier_value THN_DATA_ROOT)/rollback/capture.json"
    existing_notifier_setup_rollback_capture_is_valid "${capture_file}" \
        || {
            existing_notifier_rollback_action_required \
                "Verified pre-adoption rollback capture is missing or mismatched"
            return $?
        }
}

existing_notifier_rollback_stop_mailer() {
    existing_notifier_compose_combined stop threadhub-mailer
}

existing_notifier_rollback_restore_pair() (
    local plugin_id=com.threadhub.channel-email-notifier
    local service
    local target_root
    local bundle_target
    local rollback_root
    local removed_root
    local removed_bundle
    local temporary_dir
    local capture_dir
    local metadata
    local version
    local sha
    local extra

    service="$(existing_notifier_value THN_MATTERMOST_SERVICE)"
    target_root="$(existing_notifier_value THN_MATTERMOST_PLUGINS_ROOT)/${plugin_id}"
    bundle_target="$(existing_notifier_value THN_MATTERMOST_DATA_ROOT)/plugins/${plugin_id}.tar.gz"
    rollback_root="$(existing_notifier_value THN_DATA_ROOT)/rollback"
    removed_root="${rollback_root}/removed-runtime"
    removed_bundle="${rollback_root}/removed-bundle.tar.gz"
    temporary_dir="$(mktemp -d)"
    capture_dir="${temporary_dir}/installed-pair"
    trap 'rm -rf -- "${temporary_dir}"' EXIT HUP INT TERM

    mkdir -m 0700 "${temporary_dir}/review"
    existing_notifier_installed_target_plugin_is_reviewed "${service}" "${temporary_dir}/review" \
        || die "Installed notifier pair is no longer the reviewed release"
    mkdir -m 0700 "${temporary_dir}/review-capture"
    metadata="$(notifier_plugin_capture_pair \
        "${target_root}" "${bundle_target}" "${plugin_id}" \
        "${capture_dir}" "${temporary_dir}/review-capture")" \
        || die "Installed notifier pair could not be captured before rollback"
    extra=""
    IFS=$'\t' read -r version sha extra <<< "${metadata}"
    [[ "${version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ \
        && "${sha}" =~ ^[a-f0-9]{64}$ && -z "${extra}" ]] \
        || die "Installed notifier pair capture returned invalid metadata"
    for path in "${removed_root}" "${removed_bundle}"; do
        "${SUDO_COMMAND[@]}" test ! -e "${path}" \
            && "${SUDO_COMMAND[@]}" test ! -L "${path}" \
            || die "Rollback quarantine already exists; no plugin object was moved"
    done
    existing_notifier_compose_combined exec -T "${service}" \
        mmctl plugin disable "${plugin_id}" --local --suppress-warnings >/dev/null \
        || die "Notifier plugin could not be disabled before rollback"
    existing_notifier_compose_combined stop "${service}" \
        || die "Mattermost could not be stopped for plugin rollback"
    notifier_plugin_pair_is_exact \
        "${target_root}" "${bundle_target}" "${capture_dir}/${plugin_id}" \
        "${sha}" "${temporary_dir}/review-capture" \
        || die "Notifier pair changed after capture; Mattermost remains stopped"
    notifier_plugin_move_no_clobber "${target_root}" "${removed_root}" \
        || die "Notifier runtime could not be moved to rollback quarantine"
    if ! notifier_plugin_move_no_clobber "${bundle_target}" "${removed_bundle}"; then
        notifier_plugin_move_no_clobber "${removed_root}" "${target_root}" >/dev/null 2>&1 || true
        die "Notifier filestore bundle could not be moved to rollback quarantine"
    fi
    [[ "$(notifier_plugin_pair_presence "${target_root}" "${bundle_target}")" == absent ]] \
        || die "Notifier production pair remains after rollback quarantine"
)

existing_notifier_rollback_recreate_base() {
    existing_notifier_compose_base up -d --no-deps --wait --wait-timeout 240 \
        "$(existing_notifier_value THN_MATTERMOST_SERVICE)"
}

existing_notifier_rollback_verify_base() (
    local temporary_dir
    local service

    temporary_dir="$(mktemp -d)"
    trap 'rm -rf -- "${temporary_dir}"' EXIT HUP INT TERM
    service="$(existing_notifier_value THN_MATTERMOST_SERVICE)"
    existing_notifier_single_container_id "${service}" "${temporary_dir}/container-id" \
        && existing_notifier_live_version_is_supported "${service}" "${temporary_dir}/version" \
        && existing_notifier_live_site_url_matches "${service}" "${temporary_dir}/site-url" \
        && existing_notifier_target_plugin_is_absent "${service}" "${temporary_dir}/plugins.json" \
        || die "Base Mattermost verification failed after rollback"
    log "Existing notifier was rolled back; queue and quarantined plugin evidence were preserved"
)

existing_notifier_rollback_recover_combined() {
    local plugin_id=com.threadhub.channel-email-notifier
    local service
    local target_root
    local bundle_target
    local rollback_root
    local removed_root
    local removed_bundle
    local target_presence
    local removed_presence

    service="$(existing_notifier_value THN_MATTERMOST_SERVICE)"
    target_root="$(existing_notifier_value THN_MATTERMOST_PLUGINS_ROOT)/${plugin_id}"
    bundle_target="$(existing_notifier_value THN_MATTERMOST_DATA_ROOT)/plugins/${plugin_id}.tar.gz"
    rollback_root="$(existing_notifier_value THN_DATA_ROOT)/rollback"
    removed_root="${rollback_root}/removed-runtime"
    removed_bundle="${rollback_root}/removed-bundle.tar.gz"
    target_presence="$(notifier_plugin_pair_presence "${target_root}" "${bundle_target}")" \
        || return 1
    removed_presence="$(notifier_plugin_pair_presence "${removed_root}" "${removed_bundle}")" \
        || return 1
    if [[ "${target_presence}" == absent && "${removed_presence}" == present ]]; then
        notifier_plugin_move_no_clobber "${removed_root}" "${target_root}" || return 1
        if ! notifier_plugin_move_no_clobber "${removed_bundle}" "${bundle_target}"; then
            notifier_plugin_move_no_clobber "${target_root}" "${removed_root}" >/dev/null 2>&1 || true
            return 1
        fi
    elif [[ "${target_presence}" != present || "${removed_presence}" != absent ]]; then
        return 1
    fi
    existing_notifier_compose_combined up -d --no-deps --wait --wait-timeout 240 \
        "${service}" || return 1
    existing_notifier_compose_combined exec -T "${service}" \
        mmctl plugin enable "${plugin_id}" --local --suppress-warnings >/dev/null \
        || return 1
    existing_notifier_setup_verify_plugin || return 1
    existing_notifier_compose_combined up -d --no-deps --wait --wait-timeout 120 \
        threadhub-mailer
}

existing_notifier_rollback_recover_after_failure() {
    local original_result="$1"

    if existing_notifier_rollback_recover_combined; then
        warn "Rollback did not complete; the reviewed notifier pair and combined service were restored disabled"
        return "${original_result}"
    fi
    printf '[threadhub] ERROR: rollback failed and automatic service recovery is incomplete; control remains disabled\n' >&2
    return 70
}

existing_notifier_rollback_dispatch() {
    local result

    existing_notifier_rollback_validate || return $?
    existing_notifier_rollback_require_disabled || return $?
    existing_notifier_rollback_require_quiescent_queue || return $?
    existing_notifier_rollback_require_verified_capture || return $?
    existing_notifier_rollback_stop_mailer || return $?
    set +e
    existing_notifier_rollback_restore_pair
    result=$?
    set -e
    if ((result != 0)); then
        existing_notifier_rollback_recover_after_failure "${result}"
        return $?
    fi
    set +e
    existing_notifier_rollback_recreate_base
    result=$?
    set -e
    if ((result != 0)); then
        existing_notifier_rollback_recover_after_failure "${result}"
        return $?
    fi
    set +e
    existing_notifier_rollback_verify_base
    result=$?
    set -e
    if ((result != 0)); then
        existing_notifier_rollback_recover_after_failure "${result}"
        return $?
    fi
}

existing_notifier_rollback_entry() {
    [[ "$#" -le 1 ]] || die "Usage: $0 [--retry-failed|--cancel-failed]"
    case "${1:-}" in
        --retry-failed) EXISTING_NOTIFIER_ROLLBACK_FAILED_DISPOSITION=retry; shift ;;
        --cancel-failed) EXISTING_NOTIFIER_ROLLBACK_FAILED_DISPOSITION=cancel; shift ;;
    esac
    [[ "$#" -eq 0 ]] || die "Usage: $0 [--retry-failed|--cancel-failed]"
    existing_notifier_rollback_dispatch
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    existing_notifier_rollback_entry "$@"
fi
