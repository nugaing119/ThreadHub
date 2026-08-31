# Existing Mattermost Notifier Adoption Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Preserve the fresh ThreadHub installer while adding a fail-closed, reversible path that attaches the reviewed notifier to a supported existing Mattermost Docker Compose deployment.

**Architecture:** A protected adoption environment file describes the existing Compose project without modifying it. Read-only preflight inspects the base model, then a generated override adds only the Mailer, notifier networks, plugin environment, and control mount. Setup starts disabled, installs reviewed artifacts transactionally, recreates only the Mattermost service, and requires SMTP acceptance plus an allowlisted pilot before explicit all-channel activation.

**Tech Stack:** Bash 5, Docker Engine and Compose v2, `jq`, Mattermost Team Edition 11.7.7 AMD64, Go notifier plugin and Mailer, SQLite, SMTP 587 STARTTLS, GitHub Actions Ubuntu 24.04 AMD64.

**Spec:** `docs/superpowers/specs/2026-08-31-existing-mattermost-notifier-adoption-design.md`

## Global Constraints

- Fresh installs keep the current pinned Ubuntu 24.04 AMD64 ThreadHub Compose model.
- Adoption v1 supports one Mattermost Team Edition 11.7.7 replica with official `/mattermost/plugins` and `/mattermost/data` host bind mounts.
- Do not modify the base Compose file, its interpolation environment, PostgreSQL, Mattermost data, NGINX, DNS, TLS, Teams, channels, memberships, or messages.
- Do not display SMTP credentials, HMAC, recipient addresses, channel IDs, post IDs, or non-quiet canonical Compose output built from protected files.
- The mode-0600 adoption file uses only `THN_*` keys and is never committed.
- Unsupported or ambiguous input returns exit `20` with `[ACTION REQUIRED]` before persistent writes or container changes.
- Adoption starts disabled, proceeds through an allowlist and activation cutoff, and requires a separate interactive confirmation for `all_channels`.
- Mailer has no host port, runs non-root with read-only rootfs, drops capabilities, uses `no-new-privileges`, and persists its queue.
- Artifacts remain tied to a clean source commit, exact version, image ID, and SHA-256.
- Rollback preserves the queue and all existing Mattermost data and recreates only the selected Mattermost service from the base Compose invocation.

---

### Task 1: Define and validate the protected adoption configuration

**Files:**
- Create: `deploy/existing-notifier.env.example`
- Create: `deploy/scripts/existing-notifier-common.sh`
- Create: `deploy/tests/existing-notifier-config-test.sh`
- Modify: `.gitignore`
- Modify: `deploy/scripts/validate.sh`

**Interfaces:**
- Consumes: secure environment, hostname, email, hash, Docker, and Ubuntu helpers from `deploy/scripts/common.sh`.
- Produces: `EXISTING_NOTIFIER_ENV_FILE`, `EXISTING_NOTIFIER_BASE_COMPOSE`, `EXISTING_NOTIFIER_COMBINED_COMPOSE`, `existing_notifier_value KEY`, `existing_notifier_validate_config`, `existing_notifier_init_compose`, `existing_notifier_compose_base`, and `existing_notifier_compose_combined`.

- [ ] **Step 1: Write failing configuration tests**

Create a valid fixture and cases for symlinks, mode 0644, duplicate/unknown/missing keys, relative paths, invalid service names, nested roots, SMTP port other than 587, malformed HMAC, and accidental `NOTIFIER_*` keys. Every case asserts fixture secrets are absent from output.

```bash
write_valid_config() {
    local path="$1"
    cat >"${path}" <<'EOF'
THN_COMPOSE_PROJECT_DIR=/opt/existing-mm
THN_COMPOSE_FILE=/opt/existing-mm/compose.yml
THN_COMPOSE_ENV_FILE=/opt/existing-mm/.env
THN_MATTERMOST_SERVICE=mattermost
THN_MATTERMOST_PLUGINS_ROOT=/srv/existing-mm/plugins
THN_MATTERMOST_DATA_ROOT=/srv/existing-mm/data
THN_DATA_ROOT=/srv/threadhub-notifier
THN_DOMAIN=mattermost.example.com
THN_SMTP_SERVER=smtp.email.ap-singapore-1.oci.oraclecloud.com
THN_SMTP_PORT=587
THN_SMTP_USERNAME=fixture-private-user
THN_SMTP_PASSWORD=fixture-private-password
THN_SMTP_FROM_ADDRESS=no-reply@example.com
THN_SMTP_REPLY_TO_ADDRESS=admin@example.com
THN_SMTP_FEEDBACK_NAME=ThreadHub
THN_HMAC_SECRET=1111111111111111111111111111111111111111111111111111111111111111
THN_RATE_PER_MINUTE=10
EOF
    chmod 0600 "${path}"
}

test_nested_root_is_rejected() (
    prepare_config_fixture
    sed -i.bak 's#THN_DATA_ROOT=/srv/threadhub-notifier#THN_DATA_ROOT=/srv/existing-mm/data/notifier#' "${config}"
    rm -f "${config}.bak"
    ! run_config_validation >"${output}" 2>&1
    assert_private_output "${output}"
)
```

- [ ] **Step 2: Run the test and verify RED**

Run: `bash deploy/tests/existing-notifier-config-test.sh`

Expected: FAIL because `existing-notifier-common.sh` does not exist.

- [ ] **Step 3: Implement exact-key validation and Compose command arrays**

Ignore `deploy/existing-notifier.env` and its recovery forms while keeping the example tracked. Reject blank, duplicate, unknown, CR/LF-containing, non-`THN_*`, or unsafe values before returning one.

```bash
EXISTING_NOTIFIER_ENV_FILE="${THREADHUB_EXISTING_NOTIFIER_ENV_FILE:-${DEPLOY_DIR}/existing-notifier.env}"
EXISTING_NOTIFIER_BASE_COMPOSE=()
EXISTING_NOTIFIER_COMBINED_COMPOSE=()

existing_notifier_value() {
    env_optional_value "$1" "${EXISTING_NOTIFIER_ENV_FILE}"
}

existing_notifier_validate_config() {
    runtime_env_require_secure "${EXISTING_NOTIFIER_ENV_FILE}" || return $?
    existing_notifier_validate_exact_keys "${EXISTING_NOTIFIER_ENV_FILE}"
    [[ "$(existing_notifier_value THN_MATTERMOST_SERVICE)" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || die 'THN_MATTERMOST_SERVICE is invalid'
    validate_domain "$(existing_notifier_value THN_DOMAIN)"
    validate_email THN_SMTP_FROM_ADDRESS "$(existing_notifier_value THN_SMTP_FROM_ADDRESS)"
    validate_email THN_SMTP_REPLY_TO_ADDRESS "$(existing_notifier_value THN_SMTP_REPLY_TO_ADDRESS)"
    [[ "$(existing_notifier_value THN_SMTP_PORT)" == 587 ]] || die 'THN_SMTP_PORT must be 587'
    [[ "$(existing_notifier_value THN_HMAC_SECRET)" =~ ^[A-Fa-f0-9]{64}$ ]] || die 'THN_HMAC_SECRET must contain exactly 64 hexadecimal characters'
    existing_notifier_validate_disjoint_roots
}
```

`existing_notifier_init_compose` puts the existing env first and protected adoption env second, never echoes arrays, and adds the generated override only to the combined command.

- [ ] **Step 4: Verify GREEN and repository validation**

Run:

```bash
bash deploy/tests/existing-notifier-config-test.sh
./deploy/scripts/validate.sh
```

Expected: PASS and no protected fixture value in output.

- [ ] **Step 5: Commit**

```bash
git add .gitignore deploy/existing-notifier.env.example deploy/scripts/existing-notifier-common.sh deploy/tests/existing-notifier-config-test.sh deploy/scripts/validate.sh
git commit -m "feat(deploy): define existing notifier adoption config"
```

---

### Task 2: Implement read-only existing Mattermost preflight

**Files:**
- Create: `deploy/scripts/existing-notifier-preflight.sh`
- Create: `deploy/tests/existing-notifier-preflight-test.sh`
- Modify: `deploy/scripts/validate.sh`

**Interfaces:**
- Consumes: Task 1 config/base Compose command plus read-only `mattermost version`, local SiteURL config, and plugin list commands.
- Produces: `existing_notifier_preflight_dispatch` and an entry point returning `0`, `1`, or `20`, with fixed `[OK]` labels only.

- [ ] **Step 1: Write failing fake-Docker preflight tests**

```bash
test_supported_model_is_read_only() (
    prepare_fixture supported
    compose_before="$(sha256_file "${fixture}/compose.yml")"
    env_before="$(sha256_file "${fixture}/existing.env")"
    run_preflight >"${fixture}/output" 2>&1
    [[ "${compose_before}" == "$(sha256_file "${fixture}/compose.yml")" ]]
    [[ "${env_before}" == "$(sha256_file "${fixture}/existing.env")" ]]
    ! grep -Eq '(^| )(up|create|start|restart|cp|rm)( |$)' "${fixture}/docker.calls"
)

test_unsupported_version_stops_before_writes() (
    prepare_fixture version-11.8.0
    set +e
    run_preflight >"${fixture}/output" 2>&1
    result=$?
    set -e
    [[ "${result}" == 20 ]]
    [[ ! -e "${fixture}/runtime" ]]
)
```

Add cases for replicas greater than one, named/missing bind mounts, SiteURL mismatch, symlink inputs, conflicting Mailer/network/environment/mount, and incoherent existing plugin pairs.

- [ ] **Step 2: Run and verify RED**

Run: `bash deploy/tests/existing-notifier-preflight-test.sh`

Expected: FAIL because the preflight script does not exist.

- [ ] **Step 3: Implement temporary, non-printing model inspection**

```bash
existing_notifier_preflight_dispatch() (
    local temporary_dir model_file
    temporary_dir="$(mktemp -d)"
    trap 'rm -rf -- "${temporary_dir}"' EXIT
    chmod 0700 "${temporary_dir}"
    model_file="${temporary_dir}/compose.json"
    umask 077
    existing_notifier_validate_config || return $?
    require_ubuntu_amd64
    init_docker
    existing_notifier_init_compose
    existing_notifier_compose_base config --quiet
    existing_notifier_compose_base config --format json >"${model_file}"
    chmod 0600 "${model_file}"
    existing_notifier_assert_model "${model_file}" || return 20
    existing_notifier_assert_live_server || return 20
    printf '[OK] Mattermost Team Edition 11.7.7 single-node Compose model\n'
)
```

Use `jq -e` to prove exact service, one replica, exact host bind sources, and no collision. Raw JSON stays in the temporary directory and never reaches output.

- [ ] **Step 4: Verify GREEN and no mutation**

Run:

```bash
bash deploy/tests/existing-notifier-preflight-test.sh
bash deploy/tests/existing-notifier-config-test.sh
./deploy/scripts/validate.sh
```

Expected: PASS; unsupported fixtures return `20`; fake Docker logs contain no mutation.

- [ ] **Step 5: Commit**

```bash
git add deploy/scripts/existing-notifier-preflight.sh deploy/tests/existing-notifier-preflight-test.sh deploy/scripts/validate.sh
git commit -m "feat(deploy): preflight existing Mattermost notifier adoption"
```

---

### Task 3: Generate and verify the notifier Compose override

**Files:**
- Create: `deploy/scripts/existing-notifier-overlay.sh`
- Create: `deploy/tests/existing-notifier-overlay-test.sh`
- Modify: `deploy/scripts/existing-notifier-common.sh`
- Modify: `deploy/scripts/validate.sh`

**Interfaces:**
- Consumes: Task 1 config, selected service, and `versions.env`.
- Produces: `existing_notifier_write_override DESTINATION` and `existing_notifier_verify_combined_model MODEL_JSON`.

- [ ] **Step 1: Write failing override preservation/security tests**

Use a base fixture with existing ports, volumes, environment, healthcheck, restart policy, and networks. Assert the combined model preserves them and adds only notifier resources.

```bash
jq -e --arg service mattermost '
  .services[$service] as $mm |
  .services["threadhub-mailer"] as $mailer |
  ($mm.environment.EXISTING_VALUE == "preserved") and
  ($mm.environment.NOTIFIER_MAILER_URL == "http://threadhub-mailer:8080") and
  ([$mm.volumes[] | select(.target == "/run/threadhub-notifier" and .read_only == true)] | length == 1) and
  (($mailer.ports // []) | length == 0) and
  ($mailer.user == "65532:65532") and ($mailer.read_only == true) and
  ($mailer.cap_drop == ["ALL"]) and
  ($mailer.security_opt == ["no-new-privileges:true"]) and
  (.networks["threadhub-notifier-internal"].internal == true)
' "${combined_model}" >/dev/null
```

Assert the override contains a literal `${THN_HMAC_SECRET:?set THN_HMAC_SECRET}` placeholder but none of the resolved HMAC/SMTP values.

- [ ] **Step 2: Run and verify RED**

Run: `bash deploy/tests/existing-notifier-overlay-test.sh`

Expected: FAIL because the generator does not exist.

- [ ] **Step 3: Implement atomic placeholder-only generation**

Validate the service name, write a mode-0600 temporary file in the destination directory, validate base+override with `config --quiet`, verify the combined structure, then no-clobber publish. The selected Mattermost service receives only plugin environment, the control read-only mount, and the internal notifier network.

```yaml
services:
  # The generator prints the already validated THN_MATTERMOST_SERVICE value as this key.
  mattermost:
    environment:
      THREADHUB_DOMAIN: "${THN_DOMAIN:?set THN_DOMAIN}"
      NOTIFIER_MAILER_URL: http://threadhub-mailer:8080
      NOTIFIER_HMAC_SECRET: "${THN_HMAC_SECRET:?set THN_HMAC_SECRET}"
      NOTIFIER_CONTROL_FILE: /run/threadhub-notifier/state.json
      NOTIFIER_POLL_EVERY: 1s
    volumes:
      - "${THN_DATA_ROOT:?set THN_DATA_ROOT}/control:/run/threadhub-notifier:ro"
    networks:
      - threadhub-notifier-internal
```

Mailer maps `THN_SMTP_*` to its existing `SMTP_*` names, mounts queue/control, joins internal+outbound networks, and preserves all current hardening.

- [ ] **Step 4: Verify GREEN and regression**

Run:

```bash
bash deploy/tests/existing-notifier-overlay-test.sh
bash deploy/tests/existing-notifier-preflight-test.sh
./deploy/scripts/validate.sh
```

Expected: PASS; input hashes remain unchanged; no resolved secret appears.

- [ ] **Step 5: Commit**

```bash
git add deploy/scripts/existing-notifier-overlay.sh deploy/scripts/existing-notifier-common.sh deploy/tests/existing-notifier-overlay-test.sh deploy/scripts/validate.sh
git commit -m "feat(deploy): generate safe existing notifier override"
```

---

### Task 4: Reuse artifacts and install the plugin transactionally

**Files:**
- Create: `deploy/scripts/notifier-artifact-build-lib.sh`
- Create: `deploy/scripts/existing-notifier-plugin.sh`
- Create: `deploy/tests/existing-notifier-plugin-test.sh`
- Modify: `deploy/scripts/build-notifier.sh`
- Modify: `deploy/scripts/install-notifier-plugin.sh`
- Modify: `deploy/scripts/notifier-plugin-transaction.sh`
- Modify: `deploy/tests/notifier-deploy-test.sh`
- Modify: `deploy/tests/notifier-installer-test.sh`

**Interfaces:**
- Consumes: clean Git commit, `versions.env`, validated notifier data root, arbitrary validated plugin/filestore roots, and caller-supplied Compose function/service.
- Produces: `notifier_validate_artifact_release_dir RELEASE_DIR`, `notifier_build_artifacts RELEASE_DIR`, and `notifier_install_reviewed_pair RELEASE_DIR PLUGINS_ROOT FILESTORE_ROOT COMPOSE_FUNCTION MATTERMOST_SERVICE`.

- [ ] **Step 1: Write failing external-layout and rollback tests**

```bash
test_external_layout_installs_only_target_service() (
    prepare_external_plugin_fixture
    notifier_install_reviewed_pair "${release_dir}" "${plugins_root}" "${filestore_root}" fixture_compose existing-mm
    notifier_plugin_tree_is_exact "${plugins_root}/${PLUGIN_ID}" "${expected_root}" "${fixture}/tmp"
    notifier_plugin_bundle_is_exact "${filestore_root}/${PLUGIN_ID}.tar.gz" "${BUNDLE_SHA}"
    grep -Fx 'up -d --no-deps --wait --wait-timeout 240 existing-mm' "${fixture}/compose.calls" >/dev/null
)

test_failed_activation_restores_previous_pair() (
    prepare_previous_pair_fixture
    FIXTURE_FAIL_PLUGIN_ENABLE=true
    ! notifier_install_reviewed_pair "${release_dir}" "${plugins_root}" "${filestore_root}" fixture_compose existing-mm
    cmp -s "${fixture}/before/plugin.json" "${plugins_root}/${PLUGIN_ID}/plugin.json"
    cmp -s "${fixture}/before/bundle.tar.gz" "${filestore_root}/${PLUGIN_ID}.tar.gz"
)
```

- [ ] **Step 2: Run and verify RED**

Run:

```bash
bash deploy/tests/existing-notifier-plugin-test.sh
bash deploy/tests/notifier-deploy-test.sh
```

Expected: external-layout test FAILs because reusable interfaces do not exist; fresh test stays green.

- [ ] **Step 3: Extract build logic while preserving fresh behavior**

```bash
notifier_build_artifacts() {
    local release_dir="$1"
    notifier_validate_artifact_release_dir "${release_dir}"
    notifier_require_clean_source_commit
    notifier_build_plugin_bundle
    notifier_build_mailer_image
    notifier_publish_release_identity "${release_dir}"
}
```

Fresh `build-notifier.sh` validates its current full environment and calls this function with `/srv/threadhub/notifier/release`; adoption calls it with validated `${THN_DATA_ROOT}/release`. `notifier_validate_artifact_release_dir` accepts only a caller-proven, root-owned, mode-0750, non-symlink absolute directory beneath the caller's already validated root; it does not weaken the existing `/srv/threadhub` validator. Artifact names, hashes, image IDs, source commit, and release schema do not change.

- [ ] **Step 4: Parameterize the verified pair transaction**

Keep every archive entry, manifest, symlink, owner, mode, hash, version, prior-pair coherence, atomic publication, exact plugin-active, and rollback check. Replace hardcoded roots/function/service with explicit parameters.

```bash
notifier_install_reviewed_pair() (
    local release_dir="$1" plugins_root="$2" filestore_root="$3" compose_function="$4" mattermost_service="$5"
    notifier_verify_release_and_bundle "${release_dir}"
    notifier_capture_existing_pair_or_absent "${plugins_root}" "${filestore_root}"
    notifier_publish_pair_atomically "${plugins_root}" "${filestore_root}"
    if ! "${compose_function}" up -d --no-deps --wait --wait-timeout 240 "${mattermost_service}" || ! notifier_enable_exact_plugin "${compose_function}" "${mattermost_service}"; then
        notifier_restore_captured_pair
        "${compose_function}" up -d --no-deps --wait --wait-timeout 240 "${mattermost_service}" || true
        return 1
    fi
    notifier_assert_exact_active_pair
)
```

- [ ] **Step 5: Run fresh and external suites**

Run:

```bash
bash deploy/tests/existing-notifier-plugin-test.sh
bash deploy/tests/notifier-deploy-test.sh
bash deploy/tests/notifier-installer-test.sh
bash deploy/tests/notifier-installer-security-test.sh
```

Expected: PASS and exact prior-pair restoration on failure.

- [ ] **Step 6: Commit**

```bash
git add deploy/scripts/notifier-artifact-build-lib.sh deploy/scripts/existing-notifier-plugin.sh deploy/scripts/build-notifier.sh deploy/scripts/install-notifier-plugin.sh deploy/scripts/notifier-plugin-transaction.sh deploy/tests/existing-notifier-plugin-test.sh deploy/tests/notifier-deploy-test.sh deploy/tests/notifier-installer-test.sh
git commit -m "refactor(deploy): support transactional notifier adoption"
```

---

### Task 5: Implement fail-closed setup and allowlist pilot activation

**Files:**
- Create: `deploy/scripts/existing-notifier-setup.sh`
- Create: `deploy/tests/existing-notifier-setup-test.sh`
- Modify: `deploy/scripts/existing-notifier-common.sh`
- Modify: `deploy/scripts/existing-notifier-preflight.sh`
- Modify: `deploy/scripts/validate.sh`

**Interfaces:**
- Consumes: Tasks 1–4, atomic environment helpers, disabled control installation, Mailer health, plugin-active verification, and SMTP acceptance.
- Produces: `existing_notifier_setup_dispatch --configure-only|--resume|--non-interactive`, protected runtime state under `THN_DATA_ROOT`, and exit `0`, `1`, or `20`.

- [ ] **Step 1: Write failing setup state-machine tests**

```bash
test_setup_orders_disabled_components_before_plugin_transaction() (
    prepare_setup_fixture
    run_setup --resume --non-interactive
    [[ "$(<"${fixture}/calls")" == $'preflight\nwrite-disabled-control\nbuild-artifacts\nwrite-override\nmailer-up\nmailer-health\ninstall-plugin\nplugin-active\naction-required-smtp\n' ]]
    jq -e '.enabled == false and .delivery_enabled == false and .activated_at == 0' "${fixture}/runtime/control/state.json" >/dev/null
)

test_failure_never_enables_delivery() (
    prepare_setup_fixture
    FIXTURE_FAIL_STEP=install-plugin
    ! run_setup --resume --non-interactive
    jq -e '.enabled == false and .delivery_enabled == false' "${fixture}/runtime/control/state.json" >/dev/null
    ! grep -F activate "${fixture}/calls" >/dev/null
)
```

Add cases for no TTY with missing config, no-clobber publication, recovery-file detection, preflight exit 20 before runtime creation, idempotent resume, stale SMTP marker, nonempty pre-activation queue, and interactive allowlist cutoff.

- [ ] **Step 2: Run and verify RED**

Run: `bash deploy/tests/existing-notifier-setup-test.sh`

Expected: FAIL because the setup script does not exist.

- [ ] **Step 3: Implement protected interactive configuration**

`--configure-only` prompts for paths and addresses, reads SMTP password with hidden input, generates a 64-character HMAC, validates a mode-0600 temporary file, and publishes without clobber. It accepts no secret command-line arguments.

```bash
read -r -s -p 'SMTP password: ' smtp_password
printf '\n' >&2
hmac_secret="$(openssl rand -hex 32)"
umask 077
existing_notifier_write_config "${temporary_env}"
smtp_password=
hmac_secret=
unset smtp_password hmac_secret
runtime_env_publish_no_clobber "${temporary_env}" "${EXISTING_NOTIFIER_ENV_FILE}" || action_required 'Existing notifier configuration was not overwritten'
```

- [ ] **Step 4: Implement resumable disabled-first setup**

Acquire a mode-0700 lock and recheck config identity/hash before each persistent phase. Run preflight, create only `THN_DATA_ROOT/{control,mailer,release,rollback}`, write disabled control, build artifacts, write override, start only Mailer, install the plugin transactionally, and stop with an exact SMTP acceptance command when needed.

```bash
existing_notifier_require_disabled "${state_file}"
existing_notifier_compose_combined up -d --no-deps --wait threadhub-mailer
existing_notifier_compose_combined exec -T threadhub-mailer /threadhub-mailer healthcheck
existing_notifier_install_plugin
existing_notifier_assert_exact_plugin_active
existing_notifier_require_current_smtp_marker || action_required 'Run ./deploy/scripts/existing-notifier-setup.sh --smtp-test in an interactive terminal'
existing_notifier_activate_allowlist_interactively
```

The setup path never invokes `all_channels`. Allowlist IDs are hidden terminal input and activation requires zero pending/sending pre-activation deliveries.

- [ ] **Step 5: Verify GREEN and lower-level regression**

Run:

```bash
bash deploy/tests/existing-notifier-setup-test.sh
bash deploy/tests/existing-notifier-plugin-test.sh
bash deploy/tests/existing-notifier-overlay-test.sh
bash deploy/tests/existing-notifier-preflight-test.sh
./deploy/scripts/validate.sh
```

Expected: PASS and delivery remains disabled in every failure fixture.

- [ ] **Step 6: Commit**

```bash
git add deploy/scripts/existing-notifier-setup.sh deploy/scripts/existing-notifier-common.sh deploy/scripts/existing-notifier-preflight.sh deploy/tests/existing-notifier-setup-test.sh deploy/scripts/validate.sh
git commit -m "feat(deploy): add fail-closed existing notifier setup"
```

---

### Task 6: Add safe status, control, SMTP test, and rollback

**Files:**
- Create: `deploy/scripts/existing-notifier-status.sh`
- Create: `deploy/scripts/existing-notifier-control.sh`
- Create: `deploy/scripts/existing-notifier-smtp-test.sh`
- Create: `deploy/scripts/existing-notifier-rollback.sh`
- Create: `deploy/tests/existing-notifier-operations-test.sh`
- Modify: `deploy/scripts/notifier-lib.sh`
- Modify: `deploy/scripts/notifier-control.sh`
- Modify: `deploy/scripts/notifier-status.sh`
- Modify: `deploy/scripts/notifier-smtp-test.sh`

**Interfaces:**
- Consumes: generalized Compose function, selected Mattermost service, fixed Mailer service, protected state/marker/queue, and Task 4 rollback capture.
- Produces: `existing_notifier_validate_control_path STATE_FILE`, PII-free status, allowlist activation, interactive all-channel activation, drain, disable, SMTP acceptance, and data-preserving rollback.

- [ ] **Step 1: Write failing operation tests**

```bash
test_all_channels_requires_tty_and_exact_confirmation() (
    prepare_operations_fixture
    set +e
    printf 'ENABLE ALL CHANNEL EMAILS\n' | run_control activate-all-channels >"${fixture}/output" 2>&1
    result=$?
    set -e
    [[ "${result}" == 20 ]]
    jq -e '.enabled == false' "${fixture}/control/state.json" >/dev/null
)

test_rollback_preserves_queue_and_uses_base_compose() (
    prepare_installed_fixture
    queue_before="$(sha256_file "${fixture}/runtime/mailer/queue.db")"
    run_rollback
    [[ "${queue_before}" == "$(sha256_file "${fixture}/runtime/mailer/queue.db")" ]]
    grep -Fx 'combined stop threadhub-mailer' "${fixture}/calls" >/dev/null
    grep -Fx 'base up -d --no-deps --wait mattermost' "${fixture}/calls" >/dev/null
)
```

Add cases for drain-before-disable, pending/sending/failed rollback gates, retry/cancel decision, stale marker, plugin mismatch, incomplete capture, and redaction.

- [ ] **Step 2: Run and verify RED**

Run: `bash deploy/tests/existing-notifier-operations-test.sh`

Expected: FAIL because wrappers do not exist and helpers hardcode service names.

- [ ] **Step 3: Parameterize current helpers with unchanged defaults**

```bash
notifier_mailer_service="${NOTIFIER_MAILER_SERVICE:-threadhub-mailer}"
notifier_mattermost_service="${NOTIFIER_MATTERMOST_SERVICE:-mattermost}"
```

Use these names in SMTP, fingerprint, control, status, and plugin-list calls. Fresh wrappers set no overrides. Adoption wrappers override `compose` with `existing_notifier_compose_combined` and set the selected service.

Keep `validate_notifier_emergency_control_path` unchanged for fresh `/srv/threadhub`. The adoption wrapper uses a separate `existing_notifier_validate_control_path` that proves the state file is exactly `${THN_DATA_ROOT}/control/state.json`, every component is non-symlink, and root/control ownership and modes match the adoption contract.

- [ ] **Step 4: Implement gated, data-preserving rollback**

Require disabled control, zero pending/sending, explicit failed-delivery disposition, and verified capture. Stop Mailer, restore/remove only the reviewed plugin pair, recreate the selected service with base Compose, and verify health. Never remove `THN_DATA_ROOT`.

```bash
existing_notifier_require_disabled "${state_file}"
existing_notifier_require_quiescent_queue
existing_notifier_require_verified_rollback_capture
existing_notifier_compose_combined stop threadhub-mailer
existing_notifier_restore_plugin_pair
existing_notifier_compose_base up -d --no-deps --wait --wait-timeout 240 "${mattermost_service}"
existing_notifier_verify_base_health
```

- [ ] **Step 5: Verify GREEN and fresh regression**

Run:

```bash
bash deploy/tests/existing-notifier-operations-test.sh
bash deploy/tests/notifier-installer-test.sh
bash deploy/tests/notifier-installer-security-test.sh
./deploy/scripts/validate.sh
```

Expected: PASS; fresh status/control/SMTP behavior is unchanged.

- [ ] **Step 6: Commit**

```bash
git add deploy/scripts/existing-notifier-status.sh deploy/scripts/existing-notifier-control.sh deploy/scripts/existing-notifier-smtp-test.sh deploy/scripts/existing-notifier-rollback.sh deploy/scripts/notifier-lib.sh deploy/scripts/notifier-control.sh deploy/scripts/notifier-status.sh deploy/scripts/notifier-smtp-test.sh deploy/tests/existing-notifier-operations-test.sh
git commit -m "feat(deploy): operate and roll back adopted notifier"
```

---

### Task 7: Prove existing adoption and fresh-install regression with real images

**Files:**
- Create: `notifier/integration/existing/docker-compose.yml`
- Create: `notifier/integration/run-existing-adoption.sh`
- Create: `notifier/integration/cmd/existing-acceptance/main.go`
- Modify: `notifier/integration/run.sh`
- Modify: `.github/workflows/validate.yml`
- Modify: `deploy/docs/test-plan.md`
- Modify: `deploy/docs/test-results-public.md`

**Interfaces:**
- Consumes: all adoption commands and current pinned Mattermost/PostgreSQL/Mailer images.
- Produces: real-image evidence for baseline data, adoption, allowlist, SMTP failure, restart, permalink, rollback, and fresh regression.

- [ ] **Step 1: Add failing automatic scenario contracts**

Add and classify these rows before the runner exists:

```text
NF-ADOPT-01 supported preflight is read-only
NF-ADOPT-02 unsupported version exits 20 before writes
NF-ADOPT-03 disabled adoption preserves baseline data
NF-ADOPT-04 public/private root and thread allowlist delivery
NF-ADOPT-05 non-allowlisted/DM/system/author/nonmember exclusion
NF-ADOPT-06 SMTP failure does not fail Mattermost posting
NF-ADOPT-07 restart preserves queue without loss
NF-ADOPT-08 team-independent permalink
NF-ADOPT-09 rollback restores base Compose and baseline data
NF-ADOPT-10 fresh integration remains green
```

Run: `./deploy/scripts/validate.sh`

Expected: FAIL because documentation contracts and runner do not cover these IDs.

- [ ] **Step 2: Build the isolated base fixture**

Give it independent Compose/env files, paths, networks, and healthcheck. Before adoption, the Go helper creates a Team, public/private channels, users, memberships, and baseline post, then stores non-secret IDs only in a mode-0600 temporary state file. Record input hashes and database counts for Teams, channels, memberships, users, posts, and file metadata.

- [ ] **Step 3: Implement end-to-end adoption and rollback assertions**

```bash
THREADHUB_EXISTING_NOTIFIER_ENV_FILE="${fixture}/existing-notifier.env" ./deploy/scripts/existing-notifier-preflight.sh
THREADHUB_EXISTING_NOTIFIER_ENV_FILE="${fixture}/existing-notifier.env" ./deploy/scripts/existing-notifier-setup.sh --resume --non-interactive
```

Accept SMTP through the fixture server, activate two test channels, post included and excluded cases, and assert queue counts, generic fields, no body/channel/Team/author leakage, `/_redirect/pl/` URLs, and post success during SMTP outage. Restart Mailer/Mattermost, drain, rollback, and compare base hashes/database counts while preserving queue data.

- [ ] **Step 4: Run both real-image integrations**

Run:

```bash
./notifier/integration/run-existing-adoption.sh
./notifier/integration/run.sh
```

Expected: both PASS; the adoption runner reports 10 scenarios and fresh behavior/count remains unchanged.

- [ ] **Step 5: Add CI and non-secret public evidence**

Add a separate `notifier-existing-adoption` job with a 15-minute timeout. Public evidence contains only date, source commit, pinned digests, notifier version, bundle SHA, count, and result.

- [ ] **Step 6: Commit**

```bash
git add notifier/integration/existing notifier/integration/run-existing-adoption.sh notifier/integration/cmd/existing-acceptance notifier/integration/run.sh .github/workflows/validate.yml deploy/docs/test-plan.md deploy/docs/test-results-public.md
git commit -m "test: cover existing Mattermost notifier adoption"
```

---

### Task 8: Publish operator and agent contracts

**Files:**
- Create: `deploy/docs/existing-mattermost-notifier.md`
- Modify: `README.md`
- Modify: `AGENTS.md`
- Modify: `deploy/README.md`
- Modify: `deploy/docs/quick-install.md`
- Modify: `deploy/docs/admin-guide.md`
- Modify: `deploy/docs/operations-checklist.md`
- Modify: `deploy/docs/test-plan.md`
- Modify: `deploy/scripts/notifier-documentation-contracts.sh`
- Modify: `deploy/tests/notifier-documentation-test.sh`

**Interfaces:**
- Consumes: final commands and support contract from Tasks 1–7.
- Produces: separate fresh/adoption entry points, exact runbook, impact/support boundaries, manual acceptance, and agent fail-closed rules.

- [ ] **Step 1: Write failing documentation contracts and mutation tests**

```bash
notifier_docs_require_link "${repository_root}/README.md" './deploy/docs/existing-mattermost-notifier.md'
notifier_docs_require_section_order "${deploy_dir}/docs/existing-mattermost-notifier.md" '## 적용 순서' 'existing adoption safety sequence' 'existing-notifier-preflight.sh' 'disabled' 'existing-notifier-setup.sh' 'SMTP acceptance' 'allowlist' 'manual acceptance' 'explicit all_channels approval'
notifier_docs_require_terms "${repository_root}/AGENTS.md" 'existing Mattermost fail-closed agent contract' 'existing-notifier-preflight.sh' 'do not modify the base Compose file' 'exit code 20' 'never enable all_channels without explicit approval'
```

Mutation fixtures remove/reorder SMTP-before-activation, 30–60 second impact, rollback queue preservation, fresh/adoption separation, or explicit all-channel approval.

- [ ] **Step 2: Run and verify RED**

Run: `bash deploy/tests/notifier-documentation-test.sh`

Expected: FAIL because the guide/contracts do not exist.

- [ ] **Step 3: Write the guide and README separation**

The new guide includes support matrix, no-change guarantees, 30–60 second reconnect, protected values, preflight, configure/resume, disabled install, SMTP acceptance, public/private root/thread allowlist, explicit all-channel approval, status, drain/disable/rollback, and automatic/manual evidence. README routes fresh installs to `quick-install.md` and supported existing deployments to the new guide.

- [ ] **Step 4: Extend `AGENTS.md`**

Require evidence for version/OS/architecture/Compose/service/paths, preflight before writes, no base Compose/env modification, no secret/non-quiet output, stop on exit 20, disabled-first setup, allowlist, explicit all-channel approval, and explicit OCI approval.

- [ ] **Step 5: Run documentation and full validation**

Run:

```bash
bash deploy/tests/notifier-documentation-test.sh
./deploy/scripts/validate.sh
cd notifier
go test ./... -count=1
cd ..
./notifier/integration/run-existing-adoption.sh
./notifier/integration/run.sh
git diff --check
```

Expected: all PASS without protected fixture output.

- [ ] **Step 6: Commit**

```bash
git add README.md AGENTS.md deploy/README.md deploy/docs/existing-mattermost-notifier.md deploy/docs/quick-install.md deploy/docs/admin-guide.md deploy/docs/operations-checklist.md deploy/docs/test-plan.md deploy/scripts/notifier-documentation-contracts.sh deploy/tests/notifier-documentation-test.sh
git commit -m "docs: publish existing Mattermost notifier adoption"
```

---

## Final Verification and GitHub Handoff

- [ ] Run every shell test:

```bash
for test_script in deploy/tests/*.sh; do
  bash "${test_script}"
done
```

- [ ] Run repository ShellCheck against deployment and integration shell files:

```bash
shellcheck --version
shellcheck deploy/scripts/*.sh deploy/tests/*.sh notifier/integration/*.sh
```

- [ ] Run Go formatting, module, race, and package checks:

```bash
test -z "$(gofmt -l notifier)"
cd notifier
go mod verify
go test -race ./...
cd ..
```

- [ ] Run validation and both real-image integrations:

```bash
./deploy/scripts/validate.sh
./notifier/integration/run-existing-adoption.sh
./notifier/integration/run.sh
```

- [ ] Confirm hygiene and absence of tracked runtime secrets:

```bash
git status --short
git diff --check
git ls-files | grep -E '(^|/)(\.env|existing-notifier\.env|queue\.db|state\.json|smtp-acceptance\.json)$' && exit 1 || true
```

- [ ] Use `superpowers:requesting-code-review`, resolve findings through RED/GREEN tests, and rerun the full verification set.
- [ ] Use `superpowers:verification-before-completion` before claiming success.
- [ ] Push a feature branch and open a pull request. Do not deploy to production VMs in this implementation task; live adoption requires separate approval after CI and review.
