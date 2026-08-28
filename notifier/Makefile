SHELL := /bin/sh

CONTAINER_CLI ?= docker
COMPOSE_COMMAND ?= docker compose
CONTAINER_COMMAND ?= $(CONTAINER_CLI)
CONTAINER_BUILD_FLAGS := $(if $(filter podman,$(notdir $(CONTAINER_CLI))),--format docker,)
VERSIONS_FILE := ../deploy/versions.env
include $(VERSIONS_FILE)

GO_BUILDER_IMAGE := $(GO_BUILDER_IMAGE_REPOSITORY):$(GO_BUILDER_IMAGE_TAG)@$(GO_BUILDER_IMAGE_DIGEST)
PLUGIN_BUNDLE := dist/$(NOTIFIER_PLUGIN_ID)-$(NOTIFIER_VERSION).tar.gz
PLUGIN_BUNDLE_IMAGE := threadhub/notifier-plugin-bundle:$(NOTIFIER_VERSION)
MAILER_IMAGE := threadhub/notifier-mailer:$(NOTIFIER_VERSION)
MAILER_BINARY := dist/threadhub-mailer
MAILER_PROBE_ENV := \
	-e NOTIFIER_LISTEN_ADDRESS=:8080 \
	-e THREADHUB_DOMAIN=threadhub.example.test \
	-e NOTIFIER_HMAC_SECRET=0000000000000000000000000000000000000000000000000000000000000000 \
	-e NOTIFIER_CONTROL_FILE=/run/threadhub-notifier/state.json \
	-e SMTP_SERVER=smtp.email.ap-singapore-1.oci.oraclecloud.com \
	-e SMTP_PORT=587 \
	-e SMTP_USERNAME=artifact-fixture \
	-e SMTP_PASSWORD=artifact-fixture \
	-e SMTP_FROM_ADDRESS=no-reply@example.test \
	-e SMTP_REPLY_TO_ADDRESS=feedback@example.test \
	-e SMTP_FEEDBACK_NAME=ThreadHub \
	-e NOTIFIER_RATE_PER_MINUTE=10

.PHONY: verify fmt-check mod-verify vet test integration verify-pins verify-dockerfile plugin-bundle mailer verify-artifacts verify-artifact-secrets verify-reproducible clean

verify:
	@$(MAKE) fmt-check
	@$(MAKE) mod-verify
	@$(MAKE) vet
	@$(MAKE) test
	@$(MAKE) plugin-bundle
	@$(MAKE) mailer
	@$(MAKE) verify-artifacts
	@$(MAKE) verify-artifact-secrets
	@$(MAKE) verify-reproducible

fmt-check:
	@files="$$(gofmt -l .)"; \
	if [ -n "$$files" ]; then printf '%s\n' "$$files" >&2; exit 1; fi

mod-verify:
	@go mod verify

vet:
	@go vet ./...

test:
	@go test -race ./...

integration:
	@COMPOSE_COMMAND="$(COMPOSE_COMMAND)" CONTAINER_COMMAND="$(CONTAINER_COMMAND)" ./integration/run.sh

verify-pins:
	@set -eu; \
	command -v "$(CONTAINER_CLI)" >/dev/null 2>&1; \
	history_pin="$$(LC_ALL=C awk -v key='NOTIFIER_MAILER_CREATED_BY_HISTORY_SHA256' ' \
		BEGIN { candidate = "^[ \\t]*(export[ \\t]+)?" key "([ \\t]*=|[ \\t]*$$)"; exact = "^" key "=[a-f0-9]{64}$$" } \
		$$0 ~ candidate { count++; if ($$0 !~ exact) malformed = 1; else value = substr($$0, length(key) + 2) } \
		END { if (count != 1 || malformed || value !~ /^[a-f0-9]{64}$$/) exit 1; print value }' "$(VERSIONS_FILE)")"; \
	test "$$history_pin" = "$(NOTIFIER_MAILER_CREATED_BY_HISTORY_SHA256)"; \
	test -n "$(NOTIFIER_VERSION)"; \
	test -n "$(NOTIFIER_PLUGIN_ID)"; \
	test -n "$(GO_BUILDER_IMAGE_REPOSITORY)"; \
	test -n "$(GO_BUILDER_IMAGE_TAG)"; \
	test "$(GO_BUILDER_IMAGE_TAG)" != latest; \
	for digest in "$(GO_BUILDER_IMAGE_DIGEST)" "$(GO_BUILDER_IMAGE_INDEX_DIGEST)"; do \
		test "$${#digest}" -eq 71; \
		test "$${digest#sha256:}" != "$$digest"; \
		case "$${digest#sha256:}" in *[!0-9a-f]*) exit 1;; esac; \
	done

verify-dockerfile:
	@awk 'BEGIN { shell=0; pipeline=0 } \
		$$0 == "SHELL [\"/bin/bash\", \"-o\", \"pipefail\", \"-c\"]" { shell=NR } \
		index($$0, "| gzip -n -9 > /out/bundle/com.threadhub.channel-email-notifier-0.1.0.tar.gz") { pipeline=NR } \
		END { if (shell == 0 || pipeline == 0 || shell >= pipeline) { print "Dockerfile bundle pipeline must use the exact bash pipefail SHELL" > "/dev/stderr"; exit 1 } }' Dockerfile

plugin-bundle: verify-pins
	@$(MAKE) verify-dockerfile
	@set -eu; \
	mkdir -p dist; \
	tmp="$$(mktemp -d "dist/.plugin-bundle.XXXXXX")"; \
	cid=""; \
	trap 'if [ -n "$$cid" ]; then "$(CONTAINER_CLI)" rm -f "$$cid" >/dev/null 2>&1 || true; fi; rm -rf "$$tmp"' EXIT HUP INT TERM; \
	"$(CONTAINER_CLI)" build $(CONTAINER_BUILD_FLAGS) --platform linux/amd64 \
		--build-arg "GO_BUILDER_IMAGE=$(GO_BUILDER_IMAGE)" \
		--target plugin-bundle \
		--tag "$(PLUGIN_BUNDLE_IMAGE)" .; \
	cid="$$($(CONTAINER_CLI) create "$(PLUGIN_BUNDLE_IMAGE)" /unused)"; \
	"$(CONTAINER_CLI)" cp "$$cid:/$(NOTIFIER_PLUGIN_ID)-$(NOTIFIER_VERSION).tar.gz" "$$tmp/bundle.tar.gz"; \
	test -f "$$tmp/bundle.tar.gz"; \
	install -m 0644 "$$tmp/bundle.tar.gz" "$(PLUGIN_BUNDLE)"

mailer: verify-pins
	@"$(CONTAINER_CLI)" build $(CONTAINER_BUILD_FLAGS) --platform linux/amd64 \
		--build-arg "GO_BUILDER_IMAGE=$(GO_BUILDER_IMAGE)" \
		--target mailer \
		--tag "$(MAILER_IMAGE)" .

verify-artifacts:
	@set -eu; \
	sha256_file() { \
		if command -v sha256sum >/dev/null 2>&1; then sha256sum "$$1" | awk '{print $$1}'; \
		elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$$1" | awk '{print $$1}'; \
		elif command -v openssl >/dev/null 2>&1; then openssl dgst -sha256 "$$1" | awk '{print $$NF}'; \
		else echo 'SHA-256 tool is required' >&2; return 1; fi; \
	}; \
	test -f "$(PLUGIN_BUNDLE)"; \
	tmp="$$(mktemp -d "dist/.verify.XXXXXX")"; \
	cid=""; \
	trap 'if [ -n "$$cid" ]; then "$(CONTAINER_CLI)" rm -f "$$cid" >/dev/null 2>&1 || true; fi; rm -rf "$$tmp"' EXIT HUP INT TERM; \
	tar -tzf "$(PLUGIN_BUNDLE)" > "$$tmp/entries"; \
	printf '%s\n' \
		'$(NOTIFIER_PLUGIN_ID)/' \
		'$(NOTIFIER_PLUGIN_ID)/plugin.json' \
		'$(NOTIFIER_PLUGIN_ID)/server/' \
		'$(NOTIFIER_PLUGIN_ID)/server/dist/' \
		'$(NOTIFIER_PLUGIN_ID)/server/dist/plugin-linux-amd64' > "$$tmp/expected"; \
	diff -u "$$tmp/expected" "$$tmp/entries"; \
	awk 'BEGIN { bad=0 } /^\// { bad=1 } { n=split($$0,p,"/"); for (i=1;i<=n;i++) if (p[i]=="..") bad=1 } END { exit bad }' "$$tmp/entries"; \
	tar -tvzf "$(PLUGIN_BUNDLE)" | awk '{ type=substr($$1,1,1); if (type!="-" && type!="d") exit 1 }'; \
	mkdir "$$tmp/extracted"; \
	tar -xzf "$(PLUGIN_BUNDLE)" -C "$$tmp/extracted"; \
	plugin_root="$$tmp/extracted/$(NOTIFIER_PLUGIN_ID)"; \
	test -x "$$plugin_root/server/dist/plugin-linux-amd64"; \
	cmp -s "$$plugin_root/plugin.json" plugin/plugin.json; \
	printf '%s\n' \
		'package main' \
		'import ("encoding/json"; "io"; "os")' \
		'type manifest struct { ID string `json:"id"`; Name string `json:"name"`; Description string `json:"description"`; HomepageURL string `json:"homepage_url"`; SupportURL string `json:"support_url"`; Version string `json:"version"`; MinServerVersion string `json:"min_server_version"`; Server struct { Executables struct { LinuxAMD64 string `json:"linux-amd64"` } `json:"executables"` } `json:"server"` }' \
		'func main() { f,e:=os.Open(os.Args[1]); if e!=nil { os.Exit(1) }; defer f.Close(); d:=json.NewDecoder(f); d.DisallowUnknownFields(); var m manifest; if d.Decode(&m)!=nil { os.Exit(1) }; var extra any; if d.Decode(&extra)!=io.EOF { os.Exit(1) }; if m.ID!="com.threadhub.channel-email-notifier" || m.Version!="0.1.0" || m.MinServerVersion!="11.7.7" || m.Server.Executables.LinuxAMD64!="server/dist/plugin-linux-amd64" { os.Exit(1) } }' \
		> "$$tmp/verify-manifest.go"; \
	go run "$$tmp/verify-manifest.go" "$$plugin_root/plugin.json"; \
	go version -m "$$plugin_root/server/dist/plugin-linux-amd64" > "$$tmp/plugin-buildinfo"; \
	grep -F 'github.com/mattermost/mattermost/server/public' "$$tmp/plugin-buildinfo" | grep -F 'v0.3.0' >/dev/null; \
	grep -F 'GOOS=linux' "$$tmp/plugin-buildinfo" >/dev/null; \
	grep -F 'GOARCH=amd64' "$$tmp/plugin-buildinfo" >/dev/null; \
	grep -F 'CGO_ENABLED=0' "$$tmp/plugin-buildinfo" >/dev/null; \
	platform="$$($(CONTAINER_CLI) image inspect --format '{{.Os}}/{{.Architecture}}' "$(MAILER_IMAGE)")"; \
	test "$$platform" = 'linux/amd64'; \
	user="$$($(CONTAINER_CLI) image inspect --format '{{.Config.User}}' "$(MAILER_IMAGE)")"; \
	test "$$user" = '65532:65532'; \
	entrypoint="$$($(CONTAINER_CLI) image inspect --format '{{json .Config.Entrypoint}}' "$(MAILER_IMAGE)")"; \
	test "$$entrypoint" = '["/threadhub-mailer"]'; \
	command="$$($(CONTAINER_CLI) image inspect --format '{{json .Config.Cmd}}' "$(MAILER_IMAGE)")"; \
	test "$$command" = '["serve"]'; \
	cid="$$($(CONTAINER_CLI) create "$(MAILER_IMAGE)")"; \
	"$(CONTAINER_CLI)" cp "$$cid:/threadhub-mailer" "$$tmp/threadhub-mailer"; \
	mkdir -p "$$tmp/ca"; \
	"$(CONTAINER_CLI)" cp "$$cid:/etc/ssl/certs/ca-certificates.crt" "$$tmp/ca/ca-certificates.crt"; \
	test -s "$$tmp/ca/ca-certificates.crt"; \
	go version -m "$$tmp/threadhub-mailer" > "$$tmp/mailer-buildinfo"; \
	grep -F 'GOOS=linux' "$$tmp/mailer-buildinfo" >/dev/null; \
	grep -F 'GOARCH=amd64' "$$tmp/mailer-buildinfo" >/dev/null; \
	grep -F 'CGO_ENABLED=0' "$$tmp/mailer-buildinfo" >/dev/null; \
	"$(CONTAINER_CLI)" run --rm --tmpfs /writable:rw,mode=1777 \
		$(MAILER_PROBE_ENV) \
		-e NOTIFIER_QUEUE_PATH=/writable/queue.sqlite \
		"$(MAILER_IMAGE)" status --json >/dev/null; \
	if "$(CONTAINER_CLI)" run --rm \
		$(MAILER_PROBE_ENV) \
		-e NOTIFIER_QUEUE_PATH=/threadhub-write-probe.sqlite \
		"$(MAILER_IMAGE)" status --json >/dev/null 2>&1; then \
		echo 'Mailer image user unexpectedly wrote to the root filesystem' >&2; exit 1; \
	fi; \
	install -m 0755 "$$tmp/threadhub-mailer" "$(MAILER_BINARY)"; \
	plugin_sha="$$(sha256_file "$(PLUGIN_BUNDLE)")"; \
	mailer_sha="$$(sha256_file "$(MAILER_BINARY)")"; \
	image_id="$$($(CONTAINER_CLI) image inspect --format '{{.Id}}' "$(MAILER_IMAGE)")"; \
	printf 'plugin_bundle=%s\nplugin_bundle_sha256=%s\nmailer_binary=%s\nmailer_binary_sha256=%s\nmailer_image=%s\nmailer_image_id=%s\n' \
		'$(PLUGIN_BUNDLE)' "$$plugin_sha" '$(MAILER_BINARY)' "$$mailer_sha" '$(MAILER_IMAGE)' "$$image_id"

verify-artifact-secrets:
	@GITLEAKS_BIN="$${GITLEAKS_BIN:?set GITLEAKS_BIN to verified Gitleaks 8.30.1}" \
		CONTAINER_COMMAND="$(CONTAINER_COMMAND)" \
		../deploy/scripts/verify-notifier-artifacts.sh "$(PLUGIN_BUNDLE)" "$(MAILER_IMAGE)"

verify-reproducible: verify-pins
	@set -eu; \
	sha256_file() { \
		if command -v sha256sum >/dev/null 2>&1; then sha256sum "$$1" | awk '{print $$1}'; \
		elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$$1" | awk '{print $$1}'; \
		elif command -v openssl >/dev/null 2>&1; then openssl dgst -sha256 "$$1" | awk '{print $$NF}'; \
		else echo 'SHA-256 tool is required' >&2; return 1; fi; \
	}; \
	mkdir -p dist; \
	tmp="$$(mktemp -d "dist/.reproducible.XXXXXX")"; \
	cid=""; \
	trap 'if [ -n "$$cid" ]; then "$(CONTAINER_CLI)" rm -f "$$cid" >/dev/null 2>&1 || true; fi; rm -rf "$$tmp"' EXIT HUP INT TERM; \
	for build in first second; do \
		"$(CONTAINER_CLI)" build $(CONTAINER_BUILD_FLAGS) --no-cache --platform linux/amd64 \
			--build-arg "GO_BUILDER_IMAGE=$(GO_BUILDER_IMAGE)" \
			--target plugin-bundle \
			--tag "threadhub/notifier-plugin-bundle:reproducible-$$build" .; \
		cid="$$($(CONTAINER_CLI) create "threadhub/notifier-plugin-bundle:reproducible-$$build" /unused)"; \
		"$(CONTAINER_CLI)" cp "$$cid:/$(NOTIFIER_PLUGIN_ID)-$(NOTIFIER_VERSION).tar.gz" "$$tmp/$$build.tar.gz"; \
		"$(CONTAINER_CLI)" rm -f "$$cid" >/dev/null; \
		cid=""; \
	done; \
	first="$$(sha256_file "$$tmp/first.tar.gz")"; \
	second="$$(sha256_file "$$tmp/second.tar.gz")"; \
	test "$$first" = "$$second"; \
	printf 'reproducible_plugin_bundle_sha256=%s\n' "$$first"

clean:
	@rm -f "$(PLUGIN_BUNDLE)" "$(MAILER_BINARY)"
