# ThreadHub agent installation contract

This repository is designed so a coding agent can install a fresh ThreadHub
instance without guessing deployment values or exposing credentials.

## When the user asks to install ThreadHub

1. Read `deploy/docs/deployment-models.md` and select `canonical fresh` for every
   new project. Use `existing adoption` only for an already-running supported
   Mattermost, and never perform an in-place layout migration merely to make
   paths uniform.
2. Confirm the target is a fresh Ubuntu 24.04 AMD64 VM with 2 OCPU, 16GB RAM,
   and at least 50GB of boot storage.
3. Read `deploy/docs/quick-install.md`. If a fresh Ubuntu target has neither
   Docker Compose nor Ruby, the only target change allowed before validation is
   installing the documented Ubuntu `ruby` validator dependency. Then run
   `./deploy/scripts/validate.sh` before any ThreadHub runtime, network, secret,
   or persistent-data change.
4. Never display, copy into chat, commit, or run `docker compose config` without
   `--quiet` against `deploy/.env`.
5. If `deploy/.env` does not exist, use an interactive terminal to run
   `./deploy/scripts/setup-wizard.sh --configure-only`. SMTP secrets must be
   typed through the hidden prompt, not supplied as command-line arguments.
6. If a secure interactive terminal is unavailable, stop with the exact command
   the user must run. Continue afterward with
   `./deploy/scripts/setup-wizard.sh --resume --non-interactive`.
7. Do not overwrite an existing `deploy/.env`, attach new credentials to an
   existing `/srv/threadhub`, or delete persistent data.
8. Do not create or modify OCI tenancy-wide IAM users, groups, policies, or SMTP
   credentials without explicit user authorization. DNS, public IP, and Email
   Delivery changes also require the target compartment and region to be stated.
9. Add DNS records without replacing unrelated RRsets. Never point one hostname
   at two independent ThreadHub VMs.
10. Finish with `./deploy/scripts/install-status.sh` and report automated checks
   separately from manual admin, email, permissions, CJK, and mobile tests.

The installation is complete only when the wizard reports `[READY]` and the
manual acceptance tests linked from `deploy/docs/admin-guide.md` are complete.

## Existing Mattermost fail-closed agent contract

When the user asks to add the notifier to an already running Mattermost:

1. Read `deploy/docs/existing-mattermost-notifier.md` and run
   `./deploy/scripts/existing-notifier-preflight.sh` before any target change.
2. Support only the documented Ubuntu 24.04 AMD64, Mattermost Team Edition
   11.7.7, single-node Compose, explicit bind-mount topology. Stop on any
   ambiguity; do not modify the base Compose file or base environment file.
3. Treat exit code 20 as `[ACTION REQUIRED]`, never as success, and do not
   bypass the failed gate.
4. Install disabled, complete the one-time SMTP acceptance, activate only a
   test-channel allowlist, and finish the public/private root and thread manual
   acceptance tests before broader delivery.
5. Never enable all_channels without explicit approval from the user after the
   allowlist evidence has been reviewed.
6. Warn that setup and rollback recreate the Mattermost container and can cause
   a 30–60 second reconnect window. Preserve queue data and rollback evidence;
   do not delete or silently cancel pending or failed delivery.
7. OCI IAM, SMTP Credential, Approved Sender, DNS, public IP, and Email Delivery
   changes still require explicit authorization with the compartment and region
   stated. A repository request alone does not authorize live infrastructure or
   a production Mattermost change.

## Existing production convergence contract

When the user asks to standardize or upgrade existing ThreadHub instances:

1. Read `deploy/docs/canonical-runtime-standard.md`. Classify the instance by
   supported profile and lifecycle state; never create hostname-specific code,
   copied scripts, or an undocumented third deployment profile.
2. Repository documentation or tooling work does not authorize access to or
   mutation of any live VM, OCI resource, DNS record, SMTP credential, container,
   or persistent data. Obtain separate explicit approval for one exact instance.
3. Perform read-only inventory first and stop on any ambiguous Compose merge,
   volume, release, plugin, queue schema, or data path. Never normalize a live
   layout merely to make paths uniform.
4. Do not upgrade a production v0.1.0 notifier until a version-and-profile-specific
   transition and rollback path is merged and has passed the real-image test for
   the exact supported profile. With exactly one active legacy instance, do not
   require a general multi-profile migration utility, but never select behavior by
   hostname. If multiple active legacy instances or profiles require transition,
   require shared migration tooling instead of copied procedures.
5. Before an approved production mutation, require a verified remote backup and
   a successful disposable-VM restore for that instance. Never restore over the
   production data root.
6. Record privacy-safe Team, user, channel, post, and file baselines before and
   after the change. Any mismatch blocks broad notifier activation and requires
   rollback review.
7. Change one instance at a time: drain, reach zero pending/sending/failed,
   disable, install disabled, run SMTP acceptance, test a public/private
   allowlist, and require separate approval for all_channels.

## Backup agent safety contract

When the user asks to configure, test, restore, or remove ThreadHub backups:

1. Read `deploy/docs/backup-restore.md` and run `./deploy/scripts/validate.sh`
   before any target change. Never bypass `backup.sh`'s built-in non-writer
   preflight; it must pass before either application writer is stopped.
   Repository work alone never authorizes live OCI or production VM changes.
2. OCI bucket, lifecycle, Dynamic Group, and IAM policy changes require
   explicit user authorization after stating the exact compartment and
   `ap-singapore-1` region.
3. Register backup units disabled. The timer remains disabled until a manual
   remote backup and a disposable-VM restore have been reviewed and accepted.
4. Restore only to a new or empty `/srv/threadhub`; never overwrite or merge
   existing persistent data and never add a force bypass.
5. Keep restored notifier data in queue quarantine. Never replay a restored
   queue into live SMTP delivery.
6. Do not print, commit, or paste backup manifests, status files, diagnostics,
   bucket names, backup IDs, customer data, or credentials into public output.
7. Prefer one exact-instance Dynamic Group per project. If an approved quota
   constraint requires a shared Dynamic Group, enumerate only exact active VM
   OCIDs, restrict every project policy by both exact bucket and exact principal,
   and require the cross-project deny matrix before acceptance.
