# ThreadHub agent installation contract

This repository is designed so a coding agent can install a fresh ThreadHub
instance without guessing deployment values or exposing credentials.

## When the user asks to install ThreadHub

1. Confirm the target is a fresh Ubuntu 24.04 AMD64 VM with 2 OCPU, 16GB RAM,
   and at least 50GB of boot storage.
2. Read `deploy/docs/quick-install.md`, then run
   `./deploy/scripts/validate.sh` before changing the target VM.
3. Never display, copy into chat, commit, or run `docker compose config` without
   `--quiet` against `deploy/.env`.
4. If `deploy/.env` does not exist, use an interactive terminal to run
   `./deploy/scripts/setup-wizard.sh --configure-only`. SMTP secrets must be
   typed through the hidden prompt, not supplied as command-line arguments.
5. If a secure interactive terminal is unavailable, stop with the exact command
   the user must run. Continue afterward with
   `./deploy/scripts/setup-wizard.sh --resume --non-interactive`.
6. Do not overwrite an existing `deploy/.env`, attach new credentials to an
   existing `/srv/threadhub`, or delete persistent data.
7. Do not create or modify OCI tenancy-wide IAM users, groups, policies, or SMTP
   credentials without explicit user authorization. DNS, public IP, and Email
   Delivery changes also require the target compartment and region to be stated.
8. Add DNS records without replacing unrelated RRsets. Never point one hostname
   at two independent ThreadHub VMs.
9. Finish with `./deploy/scripts/install-status.sh` and report automated checks
   separately from manual admin, email, permissions, CJK, and mobile tests.

The installation is complete only when the wizard reports `[READY]` and the
manual acceptance tests linked from `deploy/docs/admin-guide.md` are complete.
