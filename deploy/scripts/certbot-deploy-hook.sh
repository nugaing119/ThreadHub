#!/bin/sh

set -eu

# Certbot runs deploy hooks as root after a certificate was renewed
# successfully. Validate the candidate NGINX configuration before reloading
# so the currently running service is never replaced by an invalid config.
# NGINX writes a successful syntax check to stderr, which Certbot labels as
# hook error output, so only emit the captured diagnostics when validation
# actually fails.
if ! nginx_test_output="$(/usr/sbin/nginx -t 2>&1)"; then
    printf '%s\n' "${nginx_test_output}" >&2
    exit 1
fi
/usr/bin/systemctl reload nginx
/usr/bin/systemctl is-active --quiet nginx
