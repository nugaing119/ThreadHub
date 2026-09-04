ARG GO_BUILDER_IMAGE
FROM ${GO_BUILDER_IMAGE} AS build
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download && go mod verify
COPY . .

RUN install -d -m 0755 \
        /out/plugin/com.threadhub.channel-email-notifier/server/dist \
        /out/bundle
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build \
        -trimpath -buildvcs=false \
        -ldflags='-s -w' \
        -o /out/plugin/com.threadhub.channel-email-notifier/server/dist/plugin-linux-amd64 \
        ./plugin
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build \
        -trimpath -buildvcs=false \
        -ldflags='-s -w' \
        -o /out/threadhub-mailer \
        ./mailer/cmd/threadhub-mailer
RUN install -m 0644 plugin/plugin.json LICENSE THIRD_PARTY_NOTICES.md \
        /out/plugin/com.threadhub.channel-email-notifier/ \
    && cp -R third_party \
        /out/plugin/com.threadhub.channel-email-notifier/third_party \
    && find /out/plugin/com.threadhub.channel-email-notifier/third_party \
        -type d -exec chmod 0755 {} + \
    && find /out/plugin/com.threadhub.channel-email-notifier/third_party \
        -type f -exec chmod 0644 {} + \
    && tar --sort=name --mtime='UTC 2020-01-01' \
        --owner=0 --group=0 --numeric-owner \
        -C /out/plugin -cf - com.threadhub.channel-email-notifier \
    | gzip -n -9 > /out/bundle/com.threadhub.channel-email-notifier-0.1.0.tar.gz
RUN install -d -m 0755 \
        /out/mailer-rootfs/etc/ssl/certs \
        /out/mailer-rootfs/licenses/threadhub-notifier \
    && install -m 0644 /etc/ssl/certs/ca-certificates.crt \
        /out/mailer-rootfs/etc/ssl/certs/ca-certificates.crt \
    && install -m 0644 LICENSE THIRD_PARTY_NOTICES.md \
        /out/mailer-rootfs/licenses/threadhub-notifier/ \
    && cp -R third_party \
        /out/mailer-rootfs/licenses/threadhub-notifier/third_party \
    && find /out/mailer-rootfs/licenses/threadhub-notifier/third_party \
        -type d -exec chmod 0755 {} + \
    && find /out/mailer-rootfs/licenses/threadhub-notifier/third_party \
        -type f -exec chmod 0644 {} + \
    && install -m 0755 /out/threadhub-mailer /out/mailer-rootfs/threadhub-mailer \
    && find /out/mailer-rootfs -exec touch -h -d '@1577836800' {} +

FROM scratch AS plugin-bundle
COPY --from=build /out/bundle/ /

FROM scratch AS mailer
COPY --chown=0:0 --from=build /out/mailer-rootfs/ /
USER 65532:65532
ENTRYPOINT ["/threadhub-mailer"]
CMD ["serve"]

FROM ${GO_BUILDER_IMAGE} AS smtp-fixture-build
WORKDIR /src
COPY go.mod go.sum ./
COPY protocol ./protocol
COPY integration/cmd/smtp-fixture/main.go ./integration/cmd/smtp-fixture/main.go
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 GOPROXY=off GOSUMDB=off go build \
        -trimpath -buildvcs=false \
        -ldflags='-s -w' \
        -o /out/smtp-fixture \
        ./integration/cmd/smtp-fixture

FROM scratch AS smtp-fixture
COPY --from=smtp-fixture-build /out/smtp-fixture /smtp-fixture
USER 65532:65532
ENTRYPOINT ["/smtp-fixture"]
CMD ["serve"]
