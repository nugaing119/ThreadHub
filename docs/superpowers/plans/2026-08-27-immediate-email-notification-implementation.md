# ThreadHub Immediate Channel Email Notifications Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Mattermost Team Edition 11.7.7의 공개·비공개 채널 새 글과 스레드 답글을 감지해, 작성자를 제외한 현재 채널 멤버에게 본문·채널·Team·작성자 정보를 포함하지 않는 일반 안내 이메일을 OCI Email Delivery로 즉시 발송한다.

**Architecture:** 서버 전용 Mattermost 플러그인이 `MessageHasBeenPosted` 훅에서 최소 이벤트를 플러그인 KV outbox에 먼저 기록한다. 단일 비동기 워커가 현재 채널 멤버를 조회하고 HMAC 서명 payload를 Docker 내부 전용 네트워크의 Go Mailer로 전송한다. Mailer는 SQLite에 커밋한 뒤 ACK하고, STARTTLS가 강제된 OCI SMTP로 수신자별 이메일을 발송한다. 신규 설치는 SMTP 접수시험과 자동 인수조건을 통과한 뒤에만 런타임 control state를 활성화한다.

**Tech Stack:** Go 1.25.10, Mattermost public plugin API v0.3.0, `modernc.org/sqlite` v1.48.0, Go 표준 `net/smtp`·`crypto/hmac`·`log/slog`, Docker Compose, Bash, OCI Email Delivery SMTP 587 STARTTLS, GitHub Actions Ubuntu 24.04 AMD64.

**Spec:** [승인된 설계 명세](../specs/2026-08-27-immediate-email-notification-design.md)

## Global Constraints

- 이 계획의 Task 1~14는 저장소 코드·문서·로컬/CI 시험만 변경한다. 운영 VM, DNS, 공인 IP, OCI Email Delivery, IAM 사용자·그룹·정책·SMTP Credential·Approved Sender는 변경하지 않는다.
- Task 15는 별도 라이브 배포 게이트다. 대상 Compartment와 `ap-singapore-1`을 다시 명시하고, 리전 비종속 IAM 변경은 사용자에게 명시적 승인을 받은 뒤에만 수행한다.
- 실제 `deploy/.env`, SMTP/HMAC/DB 비밀값, OCI OCID, 공인 IP, SSH 허용 IP, 운영 도메인·이메일·사용자명·채널 ID를 출력·커밋·로그 기록하지 않는다.
- 실제 `deploy/.env`에 대해 `docker compose config`를 실행할 때는 항상 `--quiet`를 붙인다.
- 기존 `deploy/.env`와 `/srv/threadhub` 데이터는 교체·삭제하지 않는다. 구형 설치에 알림 키가 없으면 전용 대화형 마이그레이션 스크립트가 **없는 키만 추가**하고 기존 행은 변경하지 않는다.
- 정상 배포·중지·롤백에서 `docker compose down -v`를 사용하지 않는다.
- 플러그인 업로드·Marketplace·원격 Marketplace·사전 패키지 자동 설치는 계속 비활성화한다. 검증한 서버 플러그인 번들만 호스트 bind mount에 수동 설치한다.
- 메시지 훅은 SMTP·HTTP·채널/사용자 조회를 호출하지 않는다. 활성화 상태 확인, 이벤트 필터, 플러그인 KV 원자 삽입만 수행한다.
- 이메일·payload·로그·성공 메타데이터에는 메시지 본문, 첨부정보, 채널명, Team명, 작성자 이름·사용자명·이메일을 포함하지 않는다.
- 테스트는 red → green → refactor 순서를 지키고, 각 작업의 시험을 통과한 뒤 해당 작업만 커밋한다.
- 새 설치 기준은 Ubuntu 24.04 AMD64, 2 OCPU, 16GB RAM, Boot Volume 50GB 이상이다.

---

## File Map

### 새 Go 알림 구성

| 경로 | 작업 | 책임 |
| --- | --- | --- |
| `notifier/go.mod` | 생성 | 단일 Go 모듈과 고정 직접 의존성 정의 |
| `notifier/go.sum` | 생성 | 의존성 checksum 고정 |
| `notifier/Makefile` | 생성 | format, unit, race, build, bundle 진입점 |
| `notifier/Dockerfile` | 생성 | linux/amd64 플러그인 번들과 non-root scratch Mailer 이미지 빌드 |
| `notifier/.dockerignore` | 생성 | 소스 외 빌드 산출물·비밀·Git 메타데이터 제외 |
| `notifier/protocol/event.go` | 생성 | 최소 이벤트·수신자 구조, 크기·도메인·ID 검증 |
| `notifier/protocol/signature.go` | 생성 | timestamp/nonce/body HMAC 서명과 도메인 분리 해시 |
| `notifier/protocol/*_test.go` | 생성 | payload 최소화, HMAC, replay 입력 경계 시험 |
| `notifier/control/state.go` | 생성 | plugin과 Mailer가 공유하는 fail-closed runtime state parser |
| `notifier/control/watcher.go` | 생성 | state file reload와 disable 시 in-flight context 취소 |
| `notifier/control/*_test.go` | 생성 | activate/drain/disable 전이와 invalid-file 시험 |
| `notifier/plugin/plugin.json` | 생성 | 서버 전용 플러그인 manifest |
| `notifier/plugin/main.go` | 생성 | `plugin.ClientMain` 진입점 |
| `notifier/plugin/server/config.go` | 생성 | 비밀 환경설정과 고정 Mailer URL 검증 |
| `notifier/plugin/server/control.go` | 생성 | shared control watcher를 plugin filter에 연결하는 adapter |
| `notifier/plugin/server/filter.go` | 생성 | 활성화 시각, 채널 allowlist, 시스템 글 필터 |
| `notifier/plugin/server/outbox.go` | 생성 | Mattermost plugin KV outbox 원자 삽입·열거·CAS 삭제 |
| `notifier/plugin/server/recipients.go` | 생성 | 현재 채널 멤버 조회와 수신자 적격성 판단 |
| `notifier/plugin/server/client.go` | 생성 | HMAC HTTP 요청과 단일 내구성 ACK 처리 |
| `notifier/plugin/server/plugin.go` | 생성 | 훅·워커·활성/비활성 lifecycle 조립 |
| `notifier/plugin/server/*_test.go` | 생성 | fake Mattermost API 기반 플러그인 단위·race 시험 |
| `notifier/mailer/cmd/threadhub-mailer/main.go` | 생성 | `serve`, `healthcheck`, `status`, `smtp-test`, `retry-failed`, `cancel-failed` 명령 |
| `notifier/mailer/internal/config/config.go` | 생성 | SMTP·HMAC·SQLite·rate limit 설정 검증 |
| `notifier/mailer/internal/message/message.go` | 생성 | 고정 제목, plain text/HTML, 결정적 Message-ID 생성 |
| `notifier/mailer/internal/smtpclient/client.go` | 생성 | 인증서 검증 STARTTLS/AUTH SMTP 전송과 오류 분류 |
| `notifier/mailer/internal/store/schema.sql` | 생성 | SQLite v1 schema |
| `notifier/mailer/internal/store/store.go` | 생성 | ACK 트랜잭션, dedupe, lease, scrub, 상태·보존 |
| `notifier/mailer/internal/worker/worker.go` | 생성 | 단일 rate-limited worker와 확정 retry schedule |
| `notifier/mailer/internal/httpapi/server.go` | 생성 | `/healthz`, HMAC 보호 `/v1/events`, request limit/timeouts |
| `notifier/mailer/internal/logsafe/logsafe.go` | 생성 | 허용된 오류 class·code·count만 구조화 로그로 기록 |
| `notifier/mailer/internal/testutil/smtp.go` | 생성 | STARTTLS·AUTH를 구현하는 테스트 SMTP fixture |
| `notifier/mailer/internal/**/*_test.go` | 생성 | 저장소·SMTP·worker·HTTP·개인정보 시험 |

### 배포·설치 통합

| 경로 | 작업 | 책임 |
| --- | --- | --- |
| `deploy/versions.env` | 수정 | Notifier 0.1.0과 Go builder 1.25.10 AMD64 digest 고정 |
| `deploy/.env.example` | 수정 | 신규 설치 기본 알림 목표값과 HMAC 예시 추가 |
| `deploy/docker-compose.yml` | 수정 | Mailer 서비스·내부 network·영구 큐·플러그인 환경 추가 |
| `deploy/scripts/common.sh` | 수정 | notifier env/control 검증 helper 추가 |
| `deploy/scripts/build-notifier.sh` | 생성 | 고정 builder로 번들·Mailer 이미지 빌드 및 SHA 기록 |
| `deploy/scripts/install-notifier-plugin.sh` | 생성 | 안전한 bundle 검사·원자 설치·mmctl 활성화 |
| `deploy/scripts/configure-notifier.sh` | 생성 | 기존 `.env`에 없는 notifier 키만 대화형으로 추가 |
| `deploy/scripts/notifier-lib.sh` | 생성 | control state·SMTP fingerprint·marker의 순수 helper |
| `deploy/scripts/notifier-control.sh` | 생성 | activate/disable/status와 activation cutoff 관리 |
| `deploy/scripts/notifier-smtp-test.sh` | 생성 | 수신 주소 일회 입력, OCI SMTP 접수 marker 생성 |
| `deploy/scripts/notifier-status.sh` | 생성 | PII 없는 큐·plugin·control 상태 출력 |
| `deploy/scripts/deploy.sh` | 수정 | 디렉터리 권한, build/install, Mailer 포함 배포 |
| `deploy/scripts/setup-wizard.sh` | 수정 | HMAC 생성, 외부 action-required, SMTP 시험, 활성화 gate |
| `deploy/scripts/health-check.sh` | 수정 | Mailer health·mount·network·host port 검사 |
| `deploy/scripts/readiness-check.sh` | 수정 | plugin·Mailer·SMTP marker·actual state 인수조건 검사 |
| `deploy/scripts/install-status.sh` | 수정 | 자동/수동 알림 상태 분리 보고 |
| `deploy/scripts/destroy.sh` | 수정 | 컨테이너 중지 전 notifier disable, 데이터 유지 |
| `deploy/scripts/validate.sh` | 수정 | 새 파일·설정·digest·보안 invariant 정적 검증 |
| `deploy/tests/notifier-installer-test.sh` | 생성 | env migration, control, marker helper 회귀시험 |

### 통합시험·문서

| 경로 | 작업 | 책임 |
| --- | --- | --- |
| `notifier/integration/docker-compose.yml` | 생성 | 실제 Mattermost 11.7.7·PostgreSQL 18.4·Mailer·SMTP fixture 시험 |
| `notifier/integration/run.sh` | 생성 | 임시 secret/cert/data 생성, 시나리오 실행, 정리 |
| `notifier/integration/cmd/smtp-fixture/main.go` | 생성 | 런타임 CA·STARTTLS SMTP와 PII 없는 test inspection API |
| `notifier/integration/cmd/acceptance/main.go` | 생성 | REST로 공개/비공개/스레드/DM 및 장애 시나리오 검증 |
| `.github/workflows/validate.yml` | 수정 | Go unit/race, bundle, container, integration job 추가 |
| `.gitignore` | 수정 | notifier 산출물·SQLite/WAL·runtime control 제외 |
| `README.md` | 수정 | 기본 알림 기능과 설치 완료 기준 안내 |
| `SECURITY.md` | 수정 | queue/control/release artifact와 이메일 개인정보 경계 추가 |
| `deploy/README.md` | 수정 | 알림 build/install/control 구조 안내 |
| `deploy/docs/quick-install.md` | 수정 | 신규 기본 활성화와 SMTP 시험 재개 절차 |
| `deploy/docs/setup.md` | 수정 | 수동 설치·롤백 순서 |
| `deploy/docs/admin-guide.md` | 수정 | 기능 범위·수신자·메일 링크·수동 인수시험 |
| `deploy/docs/oci-email-delivery.md` | 수정 | 프로젝트별 IAM/SMTP/Sender 격리와 교차 발신 시험 |
| `deploy/docs/operations-checklist.md` | 수정 | 큐·실패·rotation·즉시 disable 점검 |
| `deploy/docs/project-close.md` | 수정 | drain/cancel/scrub 및 프로젝트별 OCI 자원 회수 |
| `deploy/docs/test-plan.md` | 수정 | `NF-*` 승인시험과 자동/수동 구분 |
| `deploy/docs/test-results-public.md` | 수정 | 비식별화된 구현 검증 결과 기록 |

---

## Runtime Contracts

### Verified upstream baseline

- Mattermost tag `v11.7.7`의 [`MessageHasBeenPosted`](https://github.com/mattermost/mattermost/blob/v11.7.7/server/public/plugin/hooks.go)는 DB commit 이후 호출되며 signature가 `MessageHasBeenPosted(c *plugin.Context, post *model.Post)`다.
- 같은 tag의 [plugin API](https://github.com/mattermost/mattermost/blob/v11.7.7/server/public/plugin/api.go)에서 `GetChannelMembers`, `GetUsersByIds`, `KVSetWithOptions`, `KVList`, `KVCompareAndDelete` signature를 기준으로 컴파일한다.
- Mattermost 11.7.7의 [`server/go.mod`](https://github.com/mattermost/mattermost/blob/v11.7.7/server/go.mod)는 Go 1.25.10과 `github.com/mattermost/mattermost/server/public v0.3.0`을 사용한다.
- v11.7.7의 [plugin upload handler](https://github.com/mattermost/mattermost/blob/v11.7.7/server/channels/api4/plugin.go)는 `EnableUploads=false`일 때 bundle upload를 거부하므로 설치 자동화는 업로드 API를 쓰지 않는다.
- Mattermost 공식 [server plugin quick start](https://developers.mattermost.com/integrate/plugins/components/server/hello-world/)가 설명하는 plugin directory 수동 압축해제·server restart 방식을 고정 bundle SHA 검증과 함께 사용한다.

### 1. Plugin → Mailer request

```go
type Event struct {
	EventID    string      `json:"event_id"`
	PostID     string      `json:"post_id"`
	Permalink  string      `json:"permalink"`
	OccurredAt int64       `json:"occurred_at"`
	Recipients []Recipient `json:"recipients"`
}

type Recipient struct {
	UserID string `json:"user_id"`
	Email  string `json:"email"`
}
```

- `event_id == post_id`이며 Mattermost 26자 ID 형식이어야 한다.
- `permalink`는 정확히 `https://$THREADHUB_DOMAIN/pl/$POST_ID`여야 한다.
- 요청당 수신자는 1~250명이고 user ID가 중복되지 않아야 한다. ThreadHub 운영정책상 실제 active recipient는 50명 이하다.
- 요청 헤더는 `X-ThreadHub-Timestamp`, `X-ThreadHub-Nonce`, `X-ThreadHub-Signature: sha256=<64-hex>`다.
- canonical bytes는 `timestamp + "\n" + nonce + "\n" + rawBody`다.
- timestamp 허용 오차는 ±300초, nonce는 16 random bytes의 32자리 hex, replay 보존은 10분이다.
- HTTP body 상한은 1MiB이고 unknown JSON field는 거부한다.
- Mailer는 nonce claim과 event/delivery insert를 **한 SQLite 트랜잭션**으로 커밋한 뒤 `202 Accepted`를 반환한다.

### 2. Plugin KV outbox

```go
type OutboxEvent struct {
	PostID      string `json:"post_id"`
	ChannelID   string `json:"channel_id"`
	AuthorID    string `json:"author_user_id"`
	CreateAt    int64  `json:"create_at"`
}
```

- key는 `outbox:<post_id>`다.
- `KVSetWithOptions(..., model.PluginKVSetOptions{Atomic: true, OldValue: nil})`로 최초 한 번만 삽입한다.
- Mailer의 단일 event 요청이 ACK된 뒤 원본 JSON을 사용해 `KVCompareAndDelete`한다.
- 메시지 훅은 control state가 disabled, 미활성, cutoff 이전 또는 allowlist 밖이면 KV를 만들지 않는다.

### 3. Runtime control state

실제 수집·발송 제어는 비밀이 아닌 다음 파일로 분리한다.

```json
{
  "enabled": true,
  "delivery_enabled": true,
  "mode": "all_channels",
  "channel_ids": [],
  "activated_at": 1787790000000
}
```

- 호스트 경로: `/srv/threadhub/notifier/control/state.json`
- Mattermost와 Mailer 경로: `/run/threadhub-notifier/state.json:ro`
- 디렉터리 `0750 root:3000`, 파일 `0640 root:3000`으로 원자 교체하고 두 container에 supplemental GID 3000만 추가한다.
- 파일이 없거나 invalid면 fail-closed disabled다.
- `enabled`는 plugin의 새 outbox/HTTP ingest를, `delivery_enabled`는 Mailer의 queue claim/SMTP를 제어한다.
- `disable`은 두 값을 모두 false로 바꾸고 1초 이내 plugin과 Mailer가 감지해 신규 수집·발송을 중지한다. 진행 중 SMTP context도 취소하되 이미 OCI가 수락한 메일은 회수할 수 없다.
- `drain`은 `enabled=false`, `delivery_enabled=true`로 두어 새 이벤트를 막고 기존 Mailer queue만 처리한다.
- 재활성화는 항상 새 `activated_at`을 기록해 중지 기간의 backlog를 발송하지 않는다.
- `.env`의 `NOTIFIER_ENABLED`, `NOTIFIER_MODE`, `NOTIFIER_CHANNEL_IDS`는 신규 설치의 목표 기본값이며, 운영 중 실제 상태는 control file이 기준이다.
- 승인 설계의 `NOTIFIER_ACTIVATED_AT` 값은 기존 `.env`를 재작성하지 않기 위해 control file의 `activated_at` 필드로 기록하며, status 출력에서는 `NOTIFIER_ACTIVATED_AT`이라는 이름으로 보고한다.

### 4. SQLite v1

```sql
CREATE TABLE schema_version (
    version INTEGER PRIMARY KEY
);

CREATE TABLE events (
    event_hash TEXT PRIMARY KEY CHECK(length(event_hash) = 64),
    post_id TEXT,
    permalink TEXT,
    occurred_at_ms INTEGER NOT NULL,
    accepted_at_ms INTEGER NOT NULL,
    terminal_at_ms INTEGER
);

CREATE TABLE deliveries (
    event_hash TEXT NOT NULL REFERENCES events(event_hash) ON DELETE CASCADE,
    recipient_hash TEXT NOT NULL CHECK(length(recipient_hash) = 64),
    email TEXT,
    status TEXT NOT NULL CHECK(status IN (
        'pending', 'sending', 'sent', 'failed_permanent',
        'failed_exhausted', 'cancelled'
    )),
    attempt_count INTEGER NOT NULL DEFAULT 0,
    next_attempt_at_ms INTEGER NOT NULL,
    lease_until_ms INTEGER,
    last_error_class TEXT,
    last_smtp_code INTEGER,
    sent_at_ms INTEGER,
    updated_at_ms INTEGER NOT NULL,
    PRIMARY KEY (event_hash, recipient_hash)
);

CREATE INDEX deliveries_due_idx
    ON deliveries(status, next_attempt_at_ms);

CREATE TABLE nonces (
    nonce_hash TEXT PRIMARY KEY CHECK(length(nonce_hash) = 64),
    expires_at_ms INTEGER NOT NULL
);

CREATE TABLE service_state (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL
);
```

- `event_hash`, `recipient_hash`, Message-ID는 HMAC secret에서 domain-separated key를 파생해 만든다.
- 성공 또는 영구 실패 직후 해당 delivery의 `email`을 `NULL`로 만든다.
- 모든 delivery에서 이메일이 제거되면 event의 `post_id`와 `permalink`도 `NULL`로 만든다.
- `failed_exhausted`의 원본 이메일은 운영자 수동 재시도를 위해 최대 24시간만 유지하고, 이후 `cancelled`로 scrub한다.
- scrub된 성공·실패 메타데이터는 terminal 시각부터 7일 뒤 삭제한다.
- SQLite는 WAL, foreign keys, `secure_delete=ON`, busy timeout 5초를 설정하고 DB 파일 mode를 `0600`으로 확인한다.

### 5. Retry and rate limits

```go
var RetrySchedule = []time.Duration{
	0,
	30 * time.Second,
	2 * time.Minute,
	10 * time.Minute,
	30 * time.Minute,
	2 * time.Hour,
	6 * time.Hour,
	24 * time.Hour,
}
```

- 단일 worker, 기본 분당 10건, burst 1이다.
- schedule 값은 이전 실패 뒤 추가 대기시간이 아니라 `accepted_at` 기준 누적 시점이다. 다음 계산값이 이미 과거면 rate limiter를 지키며 즉시 재시도한다.
- network/timeout/SMTP 4xx는 temporary, SMTP 5xx는 permanent다.
- 여덟 번째 temporary 실패 뒤 `failed_exhausted`로 둔다.
- `sending` lease는 2분이며 시작 또는 주기적 reaper가 만료 lease를 `pending`으로 되돌린다.
- SMTP가 수락한 뒤 DB 기록 전에 죽으면 중복 가능하다는 at-least-once 제약을 유지한다.

### 6. Environment and host-path contract

`deploy/.env`의 notifier 관련 키는 다음으로 고정한다.

```text
NOTIFIER_ENABLED=true
NOTIFIER_MODE=all_channels
NOTIFIER_CHANNEL_IDS=
NOTIFIER_RATE_PER_MINUTE=10
```

`NOTIFIER_HMAC_SECRET`는 `^[0-9A-Fa-f]{64}$`를 만족해야 하며 wizard가 `openssl rand -hex 32`로 생성한다.

Compose가 추가로 고정하는 비밀이 아닌 container 값은 다음과 같다.

```text
NOTIFIER_MAILER_URL=http://threadhub-mailer:8080
NOTIFIER_CONTROL_FILE=/run/threadhub-notifier/state.json
NOTIFIER_LISTEN_ADDRESS=:8080
NOTIFIER_QUEUE_PATH=/var/lib/threadhub-notifier/queue.db
```

Mailer는 기존 `THREADHUB_DOMAIN`, `SMTP_SERVER`, `SMTP_PORT`, `SMTP_USERNAME`, `SMTP_PASSWORD`, `SMTP_FROM_ADDRESS`, `SMTP_REPLY_TO_ADDRESS`, `SMTP_FEEDBACK_NAME`을 재사용한다. 새 SMTP secret 사본이나 두 번째 runtime secret file을 만들지 않는다.

호스트·컨테이너 경로는 다음으로 고정한다.

| 용도 | 호스트 | 컨테이너 |
| --- | --- | --- |
| actual control | `/srv/threadhub/notifier/control/state.json` | Mattermost·Mailer `/run/threadhub-notifier/state.json` read-only |
| SMTP acceptance marker | `/srv/threadhub/notifier/control/smtp-accepted.json` | host scripts only |
| durable queue | `/srv/threadhub/notifier/mailer/queue.db` | Mailer `/var/lib/threadhub-notifier/queue.db` |
| release identity | `/srv/threadhub/notifier/release/release.env` | host scripts only |

실제 HMAC 값은 wizard가 생성해 mode 0600의 `deploy/.env`에만 저장한다. 저장소 예제에는 실제 값이 들어가지 않는다.

---

## Task 1: Bootstrap the Go module and signed minimal protocol

**Files:**

- Create: `notifier/go.mod`
- Create: `notifier/go.sum`
- Create: `notifier/protocol/event.go`
- Create: `notifier/protocol/event_test.go`
- Create: `notifier/protocol/signature.go`
- Create: `notifier/protocol/signature_test.go`

**Interfaces:**

- Consumes: 승인 설계의 최소 JSON field, `THREADHUB_DOMAIN`, 32-byte master secret.
- Produces: `Event.Validate(domain string) error`, `ValidateEmail(string) error`, `DecodeSecretHex(string) ([]byte, error)`, `NewNonce(io.Reader) (string, error)`, `Sign(secret []byte, timestamp int64, nonce string, body []byte) string`, `Verify(secret []byte, timestamp int64, nonce string, body []byte, signature string) error`, `HashIdentifier(secret []byte, purpose, value string) string`.

- [ ] **Step 1: Write failing protocol validation tests**

  `event_test.go`에 다음 표를 먼저 작성한다.

  ```go
  tests := []struct {
      name    string
      mutate  func(*Event)
      wantErr bool
  }{
      {name: "valid minimal event"},
      {name: "event and post ids differ", mutate: func(e *Event) { e.EventID = model.NewId() }, wantErr: true},
      {name: "http permalink", mutate: func(e *Event) { e.Permalink = "http://threadhub.test/pl/" + e.PostID }, wantErr: true},
      {name: "foreign host", mutate: func(e *Event) { e.Permalink = "https://other.test/pl/" + e.PostID }, wantErr: true},
      {name: "unknown post path", mutate: func(e *Event) { e.Permalink = "https://threadhub.test/channels/town-square" }, wantErr: true},
      {name: "no recipients", mutate: func(e *Event) { e.Recipients = nil }, wantErr: true},
      {name: "more than two hundred fifty recipients", mutate: addRecipients(251), wantErr: true},
      {name: "duplicate user", mutate: duplicateRecipient, wantErr: true},
      {name: "header injection email", mutate: injectCRLF, wantErr: true},
  }
  ```

- [ ] **Step 2: Write failing signature tests**

  고정 secret/body/timestamp/nonce로 deterministic signature를 검증하고, body 한 byte 변경, 다른 timestamp, 다른 nonce, malformed header, 짧은 secret이 실패하는 시험을 추가한다. 파생 hash는 label이 다르면 값도 달라야 한다.

- [ ] **Step 3: Run tests and confirm the expected compile failure**

  Run: `cd notifier && go test ./protocol`

  Expected: `package .../protocol is not in std` 또는 정의되지 않은 `Event`, `Sign` 오류로 실패.

- [ ] **Step 4: Add the pinned module definition**

  ```go
  module github.com/nugaing119/ThreadHub/notifier

  go 1.25.10

  require (
      github.com/mattermost/mattermost/server/public v0.3.0
      modernc.org/sqlite v1.48.0
  )
  ```

  Mattermost 11.7.7의 `server/go.mod`가 사용하는 public module v0.3.0과 Go 1.25.10을 그대로 맞춘다.

- [ ] **Step 5: Implement the minimal protocol**

  ```go
  func (e Event) Validate(domain string) error {
      if e.EventID != e.PostID || !mattermostID.MatchString(e.PostID) {
          return ErrInvalidPostID
      }
      if len(e.Recipients) < 1 || len(e.Recipients) > 250 {
          return ErrRecipientCount
      }
      return validatePermalinkAndUniqueRecipients(e, domain)
  }

  func Sign(secret []byte, timestamp int64, nonce string, body []byte) string {
      mac := hmac.New(sha256.New, deriveKey(secret, "request-signing"))
      _, _ = fmt.Fprintf(mac, "%d\n%s\n", timestamp, nonce)
      _, _ = mac.Write(body)
      return "sha256=" + hex.EncodeToString(mac.Sum(nil))
  }

  func deriveKey(secret []byte, label string) []byte {
      mac := hmac.New(sha256.New, secret)
      _, _ = mac.Write([]byte("threadhub/" + label + "/v1"))
      return mac.Sum(nil)
  }
  ```

  - Mattermost ID는 `^[a-z0-9]{26}$`로 검증한다.
  - `url.URL`을 사용해 scheme, host, query/fragment 부재와 정확한 `/pl/<post_id>`를 검사한다.
  - 이메일은 `net/mail.ParseAddress` 후 parsed address가 입력과 같고 CR/LF가 없는지 검사한다.
  - HMAC key는 `HMAC-SHA256(master, "threadhub/<label>/v1")`로 domain separation 한다.
  - signature 비교는 `hmac.Equal`만 사용한다.

- [ ] **Step 6: Run and normalize dependencies**

  Run: `cd notifier && go fmt ./protocol && go mod tidy && go mod verify && go test ./protocol`

  Expected: 모두 성공.

- [ ] **Step 7: Commit**

  ```bash
  git add notifier/go.mod notifier/go.sum notifier/protocol
  git commit -m "feat: define notifier signed event protocol"
  ```

---

## Task 2: Build generic email rendering and strict STARTTLS SMTP

**Files:**

- Create: `notifier/mailer/internal/config/config.go`
- Create: `notifier/mailer/internal/config/config_test.go`
- Create: `notifier/mailer/internal/message/message.go`
- Create: `notifier/mailer/internal/message/message_test.go`
- Create: `notifier/mailer/internal/smtpclient/client.go`
- Create: `notifier/mailer/internal/smtpclient/client_test.go`
- Create: `notifier/mailer/internal/logsafe/logsafe.go`
- Create: `notifier/mailer/internal/logsafe/logsafe_test.go`
- Create: `notifier/mailer/internal/testutil/smtp.go`

**Interfaces:**

- Consumes: `protocol.HashIdentifier`, validated runtime env values, one recipient email and one permalink.
- Produces: `config.Load(getenv func(string) string) (config.Config, error)`, `message.Render(message.Input) (message.Message, error)`, `smtpclient.New(smtpclient.Config, *x509.CertPool) *smtpclient.Client`, `(*smtpclient.Client).Send(context.Context, message.Message) smtpclient.Result`; `Result` exposes only `Accepted bool`, `Class ErrorClass`, `Code int`.

- [ ] **Step 1: Write failing configuration tests**

  다음 production config contract를 고정한다.

  ```go
  type Config struct {
      ListenAddress string
      Domain        string
      HMACSecret    []byte
      QueuePath     string
      SMTPHost      string
      SMTPPort      int
      SMTPUsername  string
      SMTPPassword  string
      FromAddress   string
      ReplyTo       string
      FeedbackName  string
      RatePerMinute int
  }
  ```

  64자리 hex HMAC, 587 port, non-placeholder OCI hostname, 올바른 From/Reply-To, 1~60 rate, 절대 queue path를 검증한다. config formatter와 오류에는 password/username/HMAC이 없어야 한다.

- [ ] **Step 2: Write exact content/privacy tests**

  제목은 `[ThreadHub] 새 메시지가 등록되었습니다`, 본문은 승인된 두 문장과 원문 링크만 포함한다. plain text와 HTML 각각에서 sentinel message, channel, Team, author 문자열이 없고 To가 한 명뿐인지 검사한다. 한국어 Subject/From display name은 RFC 2047로 encode되고 모든 MIME line ending은 CRLF여야 한다. Message-ID는 동일 `(event_hash, recipient_hash)`에 결정적이고 원본 post/user ID를 포함하지 않아야 한다.

  ```go
  type Input struct {
      FromName, FromAddress, ReplyTo, ToAddress string
      Domain, EventHash, RecipientHash, Permalink string
      Date time.Time
  }

  type Message struct {
      EnvelopeFrom string
      EnvelopeTo   string
      Data         []byte
  }
  ```

- [ ] **Step 3: Write STARTTLS fixture tests**

  테스트 SMTP 서버가 다음 케이스를 제공하게 한다.

  - trusted CA + STARTTLS + AUTH 성공
  - STARTTLS extension 없음 → 실패, 평문 fallback 없음
  - hostname mismatch 또는 unknown CA → 실패
  - AUTH 실패 535 → permanent/code 535
  - RCPT 450 → temporary/code 450
  - RCPT 550 → permanent/code 550
  - timeout → temporary/no raw address in result

- [ ] **Step 4: Confirm tests fail before implementation**

  Run: `cd notifier && go test ./mailer/internal/config ./mailer/internal/message ./mailer/internal/smtpclient ./mailer/internal/logsafe`

  Expected: 새 package 또는 symbol 부재로 실패.

- [ ] **Step 5: Implement renderer and SMTP client**

  `net/smtp`를 다음 순서로만 사용한다.

  ```go
  type Config struct {
      Host, Username, Password string
      Port int
      DialTimeout time.Duration
  }

  type Result struct {
      Accepted bool
      Class ErrorClass
      Code int
  }

  conn, err := dialer.DialContext(ctx, "tcp", net.JoinHostPort(cfg.Host, strconv.Itoa(cfg.Port)))
  client, err := smtp.NewClient(conn, cfg.Host)
  ok, _ := client.Extension("STARTTLS")
  if !ok { return Result{Class: ClassPermanent}, ErrSTARTTLSRequired }
  err = client.StartTLS(&tls.Config{
      ServerName: cfg.Host,
      MinVersion: tls.VersionTLS12,
      RootCAs:    roots,
  })
  err = client.Auth(smtp.PlainAuth("", cfg.Username, cfg.Password, cfg.Host))
  ```

  SMTP 오류 문자열 전체를 log로 전달하지 않고 `temporary|permanent|timeout|protocol` class와 3자리 code만 반환한다. `DATA` writer의 `Close`에서 받은 최종 SMTP 응답까지 성공 판정에 포함하고, MIME header의 CR/LF injection을 거부한다. context 취소 시 underlying `net.Conn`을 닫아 진행 중 AUTH/MAIL/RCPT/DATA가 bounded time 안에 종료되게 한다.

- [ ] **Step 6: Implement safe structured logging**

  logger API가 `event`, `count`, `duration_ms`, `error_class`, `smtp_code`만 받도록 만들고 arbitrary string/error attr를 허용하지 않는다. 테스트 buffer에 secret/email/sentinel이 한 번도 나타나지 않게 한다.

  ```go
  func (l *Logger) DeliveryFailure(class string, smtpCode int) {
      l.base.Error("delivery_failed",
          slog.String("error_class", class),
          slog.Int("smtp_code", smtpCode))
  }
  ```

- [ ] **Step 7: Run tests including race**

  Run: `cd notifier && go fmt ./mailer/internal/... && go test -race ./mailer/internal/config ./mailer/internal/message ./mailer/internal/smtpclient ./mailer/internal/logsafe`

  Expected: 모두 성공.

- [ ] **Step 8: Commit**

  ```bash
  git add notifier/mailer/internal
  git commit -m "feat: send generic notices over strict smtp"
  ```

---

## Task 3: Implement the durable SQLite queue and privacy lifecycle

**Files:**

- Create: `notifier/mailer/internal/store/schema.sql`
- Create: `notifier/mailer/internal/store/store.go`
- Create: `notifier/mailer/internal/store/store_test.go`

**Interfaces:**

- Consumes: validated `protocol.Event`, `protocol.HashIdentifier`, nonce hash, injected current time.
- Produces: `store.Open(path string, secret []byte) (*store.SQLiteStore, error)` and the `Store` methods defined in Step 4; `Delivery` supplies only hashes, recipient email, permalink, attempt metadata needed by Task 4.

- [ ] **Step 1: Write failing schema and transaction tests**

  시험은 temporary directory의 실제 SQLite 파일을 사용한다.

  - schema v1 생성과 두 번째 open idempotency
  - DB file `0600`, parent directory symlink 거부
  - nonce와 event/deliveries가 한 transaction으로 commit
  - 동일 nonce replay 거부
  - 새 nonce로 동일 `(post,user)` 재전송 시 delivery 한 건
  - 같은 event를 새 nonce로 다시 제출해도 동일 delivery set 유지
  - 동일 event ID에 다른 permalink/occurred_at가 오면 conflict 거부
  - due claim이 `sending` lease를 원자 획득
  - expired lease만 pending으로 복귀

- [ ] **Step 2: Write failing scrub/retention tests**

  fake clock을 주입해 다음을 검증한다.

  - sent/failed_permanent 직후 email `NULL`
  - 다른 pending recipient가 있으면 event permalink 유지
  - 모든 recipient scrub 후 post ID/permalink `NULL`
  - failed_exhausted는 24시간 동안 수동 retry 가능
  - 24시간 뒤 cancel+email scrub
  - terminal metadata는 7일 후 삭제
  - nonce는 10분 뒤 삭제

- [ ] **Step 3: Confirm tests fail**

  Run: `cd notifier && go test ./mailer/internal/store`

  Expected: store package 구현 부재로 실패.

- [ ] **Step 4: Implement schema and store API**

  ```go
  type DeliveryKey struct {
      EventHash, RecipientHash string
  }

  type Delivery struct {
      Key DeliveryKey
      Email, Permalink string
      AttemptCount int
      AcceptedAt, OccurredAt time.Time
  }

  type AcceptResult struct { Inserted, Duplicate int }
  type PruneResult struct { Nonces, Deliveries, Events int64 }
  type Status struct {
      Pending, Sending, Sent, FailedPermanent, FailedExhausted, Cancelled int64
      OldestPendingSeconds int64
      LastSuccessAt int64
      LastErrorClass string
      LastSMTPCode int
  }

  type Store interface {
      Accept(ctx context.Context, nonceHash string, e protocol.Event, now time.Time) (AcceptResult, error)
      ClaimDue(ctx context.Context, now time.Time, lease time.Duration) (*Delivery, error)
      MarkSent(ctx context.Context, key DeliveryKey, now time.Time) error
      MarkTemporary(ctx context.Context, key DeliveryKey, class string, code int, next time.Time) error
      MarkPermanent(ctx context.Context, key DeliveryKey, class string, code int, now time.Time) error
      ResetExpiredLeases(ctx context.Context, now time.Time) (int64, error)
      RetryExhausted(ctx context.Context, now time.Time) (int64, error)
      CancelExhausted(ctx context.Context, now time.Time) (int64, error)
      Prune(ctx context.Context, now time.Time) (PruneResult, error)
      Status(ctx context.Context, now time.Time) (Status, error)
  }
  ```

  transaction은 `BEGIN IMMEDIATE`에 해당하는 modernc SQLite 동작을 사용하고, `PRAGMA journal_mode=WAL`, `foreign_keys=ON`, `secure_delete=ON`, `busy_timeout=5000`을 open 직후 확인한다. SQLite driver가 파일을 열기 전에 `O_CREATE|O_RDWR`와 mode 0600으로 파일을 준비하고 symlink를 거부한다.

- [ ] **Step 5: Add raw-file privacy assertions**

  성공 scrub/checkpoint 뒤 DB, `-wal`, `-shm`을 읽어 test recipient email, post ID, permalink가 남지 않았는지 검사한다. 테스트 종료 전 `PRAGMA wal_checkpoint(TRUNCATE)`와 `VACUUM`을 실행해 SQLite free page에 원문이 남는 문제도 검증한다. 운영 prune은 하루 한 번 `wal_checkpoint(TRUNCATE)`와 `PRAGMA optimize`를 수행한다.

- [ ] **Step 6: Run store tests and race detector**

  Run: `cd notifier && go fmt ./mailer/internal/store && go test -race ./mailer/internal/store`

  Expected: 모두 성공.

- [ ] **Step 7: Commit**

  ```bash
  git add notifier/mailer/internal/store
  git commit -m "feat: persist notifier deliveries in sqlite"
  ```

---

## Task 4: Add retry, rate limiting, recovery, and status

**Files:**

- Create: `notifier/control/state.go`
- Create: `notifier/control/state_test.go`
- Create: `notifier/control/watcher.go`
- Create: `notifier/control/watcher_test.go`
- Create: `notifier/mailer/internal/worker/worker.go`
- Create: `notifier/mailer/internal/worker/worker_test.go`

**Interfaces:**

- Consumes: Task 3 `Store`, Task 2 `message.Render`/`smtpclient.Result`, shared runtime control file.
- Produces: `control.Load(path string) (control.State, error)`, `control.NewWatcher(path string, poll time.Duration) *control.Watcher`, `(*control.Watcher).Run(context.Context) error`, `(*control.Watcher).Current() control.State`, `(*control.Watcher).Changes() <-chan control.State`, `worker.New(store Store, render RenderFunc, sender Sender, controls ControlReader, clock Clock, cfg Config) *worker.Worker`, `(*worker.Worker).Run(context.Context) error`.

  ```go
  type State struct {
      Enabled         bool     `json:"enabled"`
      DeliveryEnabled bool     `json:"delivery_enabled"`
      Mode            string   `json:"mode"`
      ChannelIDs      []string `json:"channel_ids"`
      ActivatedAt     int64    `json:"activated_at"`
  }

  func (s State) AllowsChannel(channelID string) bool
  ```

- [ ] **Step 1: Write failing schedule table tests**

  시도 1~8의 정확한 offset을 비교하고 attempt 8 temporary 실패가 `failed_exhausted`가 되는지 검사한다. 4xx/network/timeout만 retry하고 5xx는 즉시 permanent여야 한다.

- [ ] **Step 2: Write failing worker behavior tests**

  `Sender`, `Store`, `Clock` fake로 다음을 검증한다.

  - 수신자 한 명 실패가 다음 수신자를 막지 않음
  - 분당 10건, burst 1에서 fake time 기준 6초 간격
  - graceful cancellation은 새 claim을 중지하고 현재 SMTP context를 종료
  - control missing/invalid/disabled → 새 claim 없음, 진행 중 SMTP context 취소
  - drain state → 새 HTTP ingest 거부, 기존 pending delivery는 계속 처리
  - active state로 새 cutoff를 쓰면 worker가 다시 처리 시작
  - startup과 매분 expired lease recovery
  - SMTP 수락 뒤 store 실패 시 lease expiry 후 중복 가능 경로가 유지됨
  - 로그에는 class/code/count만 있고 email/post ID 없음

- [ ] **Step 3: Confirm tests fail**

  Run: `cd notifier && go test ./control ./mailer/internal/worker`

  Expected: worker symbol 부재로 실패.

- [ ] **Step 4: Implement single-worker orchestration**

  ```go
  type Sender interface {
      Send(context.Context, message.Message) smtpclient.Result
  }

  type RenderFunc func(store.Delivery) (message.Message, error)

  type ControlReader interface {
      Current() control.State
      Changes() <-chan control.State
  }

  type Clock interface {
      Now() time.Time
      Wait(context.Context, time.Duration) error
  }

  type Config struct {
      RatePerMinute int
      LeaseDuration time.Duration
  }
  ```

  DB에 email이 없는 delivery는 절대 Sender로 전달하지 않는다. worker는 event/recipient hash를 log에 남기지 않고 aggregate counter만 갱신한다.

  shared control watcher는 1초마다 strict JSON을 reload한다. invalid/missing state는 `{enabled:false, delivery_enabled:false}`로 바꾼다. worker는 SMTP `Send`를 child context로 실행하면서 `controls.Changes()`도 select하고, `delivery_enabled`가 true→false로 전이하면 child context를 cancel한 뒤 SMTP goroutine 종료를 기다린다.

- [ ] **Step 5: Run tests**

  Run: `cd notifier && go fmt ./control ./mailer/internal/worker && go test -race ./control ./mailer/internal/worker`

  Expected: 모두 성공.

- [ ] **Step 6: Commit**

  ```bash
  git add notifier/control notifier/mailer/internal/worker
  git commit -m "feat: retry and rate limit email delivery"
  ```

---

## Task 5: Expose the internal ingest API and Mailer CLI

**Files:**

- Create: `notifier/mailer/internal/httpapi/server.go`
- Create: `notifier/mailer/internal/httpapi/server_test.go`
- Create: `notifier/mailer/cmd/threadhub-mailer/main.go`
- Create: `notifier/mailer/cmd/threadhub-mailer/main_test.go`

**Interfaces:**

- Consumes: Task 1 HMAC verification, Task 3 transactional store, Task 4 control watcher/worker, Task 2 SMTP client.
- Produces: `httpapi.NewHandler(queue *store.SQLiteStore, controls *control.Watcher, secret []byte, now func() time.Time, logger *logsafe.Logger) http.Handler` and the six CLI subcommands listed in Step 2. Only `/healthz` and `/v1/events` are network routes.

- [ ] **Step 1: Write failing HTTP security tests**

  - valid signed event → 202 only after store commit
  - bad/missing signature → 401
  - timestamp outside ±300초 → 401
  - nonce replay → 409
  - invalid/unknown JSON field → 400
  - body >1MiB → 413
  - method/content-type mismatch → 405/415
  - control disabled 또는 drain → 423, nonce/event 미저장
  - store unavailable → 503 and no ACK
  - `/healthz` returns only `ok` when DB and worker are ready
  - access log/captured response never contains raw body, email, post/channel data

- [ ] **Step 2: Write failing CLI tests**

  subcommand contract를 다음으로 고정한다.

  ```text
  threadhub-mailer serve
  threadhub-mailer healthcheck
  threadhub-mailer status --json
  threadhub-mailer smtp-test --recipient-stdin
  threadhub-mailer retry-failed
  threadhub-mailer cancel-failed
  ```

  `smtp-test`는 stdin 한 줄로만 주소를 받고 argv/env/log에 남기지 않는다. `status --json`에는 pending/sending/sent/failed count, oldest pending seconds, last success timestamp, last error class/code만 있어야 한다.

- [ ] **Step 3: Confirm tests fail**

  Run: `cd notifier && go test ./mailer/internal/httpapi ./mailer/cmd/threadhub-mailer`

  Expected: handler/command 구현 부재로 실패.

- [ ] **Step 4: Implement hardened HTTP server**

  ```go
  mux := http.NewServeMux()
  mux.HandleFunc("GET /healthz", h.health)
  mux.HandleFunc("POST /v1/events", h.acceptEvent)
  server := &http.Server{
      Addr: cfg.ListenAddress, Handler: mux,
      ReadHeaderTimeout: 5 * time.Second,
      ReadTimeout: 10 * time.Second,
      WriteTimeout: 10 * time.Second,
      IdleTimeout: 30 * time.Second,
  }
  ```

  - listen 기본값 `:8080`
  - `ReadHeaderTimeout=5s`, `ReadTimeout=10s`, `WriteTimeout=10s`, `IdleTimeout=30s`
  - HMAC 검증은 JSON decode 전에 수행
  - valid HMAC 뒤에도 shared control의 `enabled=true`가 아니면 ingest하지 않음
  - nonce claim과 enqueue는 store의 단일 transaction 사용
  - redirect, debug, pprof, metrics 외부 endpoint는 만들지 않음
  - SIGTERM은 HTTP accept 중단 → worker cancel → 최대 30초 drain → DB close 순서

- [ ] **Step 5: Implement SMTP acceptance marker input path**

  `smtp-test` 제목은 `[ThreadHub] 알림 SMTP 테스트`, 본문은 일반 안내와 동일하게 민감정보가 없도록 한다. 성공은 SMTP 최종 250 응답까지만 의미하며 받은편지함 도착/SPF/DKIM은 수동시험으로 남긴다.

  ```go
  scanner := bufio.NewScanner(io.LimitReader(os.Stdin, 512))
  if !scanner.Scan() { return errors.New("recipient is required on stdin") }
  recipient := strings.TrimSpace(scanner.Text())
  if err := protocol.ValidateEmail(recipient); err != nil { return err }
  return runSMTPAcceptance(ctx, cfg, recipient)
  ```

- [ ] **Step 6: Run all Mailer tests**

  Run: `cd notifier && go fmt ./mailer/... && go test -race ./mailer/...`

  Expected: 모두 성공.

- [ ] **Step 7: Commit**

  ```bash
  git add notifier/mailer
  git commit -m "feat: serve durable notifier mailer"
  ```

---

## Task 6: Implement plugin control, event filtering, and KV outbox

**Files:**

- Create: `notifier/plugin/server/config.go`
- Create: `notifier/plugin/server/config_test.go`
- Create: `notifier/plugin/server/control.go`
- Create: `notifier/plugin/server/control_test.go`
- Create: `notifier/plugin/server/filter.go`
- Create: `notifier/plugin/server/filter_test.go`
- Create: `notifier/plugin/server/outbox.go`
- Create: `notifier/plugin/server/outbox_test.go`

**Interfaces:**

- Consumes: Task 4 `control.Watcher`, Mattermost public `model.Post`, plugin KV API v0.3.0.
- Produces: `LoadConfig(getenv func(string) string) (Config, error)`, `EligibleAtHook(control.State, *model.Post) bool`, `NewOutbox(api MattermostAPI) *Outbox`, `(*Outbox).Put(OutboxEvent) error`, `(*Outbox).List() ([]StoredEvent, error)`, `(*Outbox).Complete(StoredEvent) error`, `NewOutboxEvent(*model.Post) OutboxEvent`.

  ```go
  type MattermostAPI interface {
      GetChannel(channelID string) (*model.Channel, *model.AppError)
      GetChannelMembers(channelID string, page, perPage int) (model.ChannelMembers, *model.AppError)
      GetUsersByIds(userIDs []string) ([]*model.User, *model.AppError)
      KVSetWithOptions(string, []byte, model.PluginKVSetOptions) (bool, *model.AppError)
      KVGet(string) ([]byte, *model.AppError)
      KVList(page, perPage int) ([]string, *model.AppError)
      KVCompareAndDelete(string, []byte) (bool, *model.AppError)
  }

  type StoredEvent struct {
      Key string
      Raw []byte
      Event OutboxEvent
  }
  ```

- [ ] **Step 1: Write failing config/control tests**

  plugin config는 다음 값만 읽는다.

  ```go
  type Config struct {
      Domain      string
      MailerURL   *url.URL
      HMACSecret  []byte
      ControlFile string
      PollEvery   time.Duration
  }
  ```

  production Mailer URL은 userinfo/query/fragment가 없는 `http://threadhub-mailer:8080`만 허용한다. 테스트에서는 explicit dependency injection으로 `httptest.Server`를 사용한다. control file missing/invalid/권한 오류는 disabled로 처리하고 마지막 valid enabled state를 계속 쓰지 않는다.

- [ ] **Step 2: Write the full filter matrix first**

  다음을 table test로 고정한다.

  - enabled + activated 이후 + all_channels → 후보
  - disabled/missing state → 제외
  - create_at < activated_at → 제외
  - allowlist 내 channel → 후보, 밖 → 제외
  - `post.IsSystemMessage()` → 제외
  - 빈 ID 또는 DeleteAt 설정 post → 제외
  - root와 reply → 모두 후보
  - bot/webhook 일반 post type → 후보

  DM/group 여부는 hook에서 API 조회하지 않고 worker의 channel type 단계에서 제외한다.

- [ ] **Step 3: Write failing atomic outbox tests**

  fake KV API로 최초 atomic insert 성공, 동일 key 중복 무시, DB error 반환, page 0부터 200개씩 열거, 다른 prefix 무시, malformed value 격리, 정확한 bytes로 CAS delete를 검증한다.

- [ ] **Step 4: Confirm tests fail**

  Run: `cd notifier && go test ./plugin/server`

  Expected: package symbol 부재로 실패.

- [ ] **Step 5: Implement control snapshot and outbox**

  Task 4의 shared control watcher가 제공하는 atomic snapshot을 plugin adapter에서 사용한다. state file의 channel IDs는 set으로 정규화하되 log에 출력하지 않는다.

  ```go
  func (o *Outbox) Put(event OutboxEvent) error {
      raw, err := json.Marshal(event)
      if err != nil { return err }
      stored, appErr := o.api.KVSetWithOptions(
          "outbox:"+event.PostID, raw,
          model.PluginKVSetOptions{Atomic: true, OldValue: nil},
      )
      if appErr != nil { return fmt.Errorf("plugin kv set failed: %s", appErr.Id) }
      _ = stored // false means an idempotent duplicate
      return nil
  }
  ```

- [ ] **Step 6: Run tests**

  Run: `cd notifier && go fmt ./plugin/server && go test -race ./plugin/server`

  Expected: 모두 성공.

- [ ] **Step 7: Commit**

  ```bash
  git add notifier/plugin/server
  git commit -m "feat: persist eligible plugin events"
  ```

---

## Task 7: Resolve current channel recipients and send one signed event

**Files:**

- Create: `notifier/plugin/server/recipients.go`
- Create: `notifier/plugin/server/recipients_test.go`
- Create: `notifier/plugin/server/client.go`
- Create: `notifier/plugin/server/client_test.go`
- Create: `notifier/plugin/server/testapi_test.go`

**Interfaces:**

- Consumes: Task 6 `OutboxEvent`/`MattermostAPI`, Task 1 `protocol.Event`/HMAC helpers, current Mattermost channel membership.
- Produces: `NewRecipientResolver(api MattermostAPI) *RecipientResolver`, `(*RecipientResolver).Resolve(OutboxEvent) ([]protocol.Recipient, error)`, `NewMailerClient(baseURL *url.URL, domain string, secret []byte, client *http.Client) *MailerClient`, `(*MailerClient).Enqueue(context.Context, OutboxEvent, []protocol.Recipient) error`.

- [ ] **Step 1: Compile the exact Mattermost API seam against v0.3.0**

  ```go
  var _ MattermostAPI = (plugin.API)(nil)
  ```

  이 compile-time assertion이 Mattermost public API v0.3.0의 정확한 signature와 맞는지 확인한다. `plugin.API`가 interface이므로 구현 시 assertion 문법이 컴파일되지 않으면 `var _ MattermostAPI = plugin.API(nil)`로 동일 assignability를 검사한다.

- [ ] **Step 2: Write failing recipient matrix tests**

  - `model.ChannelTypeOpen`/`model.ChannelTypePrivate`만 처리하고 `model.ChannelTypeDirect`/`model.ChannelTypeGroup` 제외
  - channel members page 0,1,..., page size 200을 모두 조회
  - member user IDs를 200개씩 `GetUsersByIds`
  - author 제외
  - `DeleteAt != 0`, `IsBot`, email empty, `EmailVerified=false` 제외
  - Team 멤버지만 channel membership 없음 → 포함되지 않음
  - 결과는 UserID 오름차순 정렬, 중복 제거
  - 스레드 reply도 채널 전체 멤버 결과와 동일

- [ ] **Step 3: Write failing signed-client tests**

  `httptest.Server`에서 exact JSON field set, retry마다 fresh nonce, 1~250명 단일 요청, signature 검증, no redirect, 3초 timeout, 2xx만 ACK를 검사한다. server가 500 또는 timeout이면 outbox delete를 호출하지 않아야 한다.

- [ ] **Step 4: Confirm tests fail**

  Run: `cd notifier && go test ./plugin/server -run 'Recipient|MailerClient'`

  Expected: resolver/client symbol 부재로 실패.

- [ ] **Step 5: Implement recipient resolution and one-request enqueue**

  각 처리 시점에 멤버십을 다시 조회한다. eligible recipient가 0명이면 Mailer를 호출하지 않고 outbox를 완료할 수 있다. 1명 이상이면 정렬·중복 제거한 전체 recipient를 한 번 제출하고 ACK돼야 완료한다. 250명을 초과하면 조용히 누락하지 않고 오류로 남겨 운영 상한 위반을 드러낸다.

  ```go
  func eligibleRecipient(authorID string, u *model.User) bool {
      return u != nil && u.Id != authorID && u.DeleteAt == 0 &&
          !u.IsBot && u.EmailVerified && u.Email != ""
  }

  func (c *MailerClient) Enqueue(ctx context.Context, event OutboxEvent, recipients []protocol.Recipient) error {
      payload := protocol.Event{
          EventID: event.PostID, PostID: event.PostID,
          Permalink: c.permalink(event.PostID),
          OccurredAt: event.CreateAt, Recipients: recipients,
      }
      return c.postSigned(ctx, payload)
  }
  ```

- [ ] **Step 6: Run tests**

  Run: `cd notifier && go fmt ./plugin/server && go test -race ./plugin/server`

  Expected: 모두 성공.

- [ ] **Step 7: Commit**

  ```bash
  git add notifier/plugin/server
  git commit -m "feat: resolve channel notification recipients"
  ```

---

## Task 8: Wire the Mattermost hook and resilient plugin worker

**Files:**

- Create: `notifier/plugin/plugin.json`
- Create: `notifier/plugin/main.go`
- Create: `notifier/plugin/server/plugin.go`
- Create: `notifier/plugin/server/plugin_test.go`

**Interfaces:**

- Consumes: Tasks 6~7 plugin components and Mattermost framework injection of `plugin.MattermostPlugin.API`.
- Produces: `server.New() *Plugin`, `(*Plugin).OnActivate() error`, `(*Plugin).OnDeactivate() error`, `(*Plugin).MessageHasBeenPosted(*plugin.Context, *model.Post)`; `plugin/main.go` calls `plugin.ClientMain(server.New())`.

- [ ] **Step 1: Write lifecycle tests before the plugin implementation**

  - `OnActivate` invalid config → error, no goroutine
  - valid config → control reloader와 outbox worker 각각 한 개
  - `OnDeactivate` → cancel 후 bounded wait, 새 work 없음
  - concurrent `MessageHasBeenPosted` → race 없음
  - hook 실행 중 HTTP/SMTP/GetChannel/GetUsers 호출 0회
  - plugin은 `MessageHasBeenPosted`, `OnActivate`, `OnDeactivate` 외 update/delete/reaction/push/email-notification hook을 custom override하지 않음
  - hook KV insert error가 Mattermost post를 거부하지 않음
  - worker disabled → 발송 없음
  - disable 후 pending outbox 유지, 새 activation cutoff 후 과거 outbox 삭제·미발송
  - Mailer ACK 뒤에만 CAS delete
  - malformed outbox는 email/raw value 없이 오류 class만 기록하고 `dead:<sha256(key)>`에 class·시각만 한 번 격리한 뒤 원본을 CAS 삭제

- [ ] **Step 2: Confirm lifecycle tests fail**

  Run: `cd notifier && go test -race ./plugin/server -run 'Plugin|Lifecycle|Hook|Worker'`

  Expected: plugin 구현 부재로 실패.

- [ ] **Step 3: Implement the hook**

  ```go
  func (p *Plugin) MessageHasBeenPosted(_ *plugin.Context, post *model.Post) {
      state := p.control.Current()
      if !EligibleAtHook(state, post) {
          return
      }
      if err := p.outbox.Put(NewOutboxEvent(post)); err != nil {
          p.log.ErrorClass("outbox_write")
      }
  }
  ```

  `post.Message`, props, filenames, channel/team/author name을 읽거나 serialize하지 않는다.

- [ ] **Step 4: Implement the worker lifecycle**

  worker는 1초 간격으로 outbox를 읽고 각 항목마다 최신 control → channel type → current members → signed event 순서로 처리한다. API/HTTP 오류에는 exponential busy loop를 만들지 않고 다음 poll까지 기다린다.

  ```go
  func (p *Plugin) processOne(ctx context.Context, stored StoredEvent) error {
      state := p.controls.Current()
      if !state.Enabled || stored.Event.CreateAt < state.ActivatedAt ||
          !state.AllowsChannel(stored.Event.ChannelID) {
          return p.outbox.Complete(stored)
      }
      recipients, err := p.recipients.Resolve(stored.Event)
      if err != nil { return err }
      if len(recipients) > 0 {
          if err := p.mailer.Enqueue(ctx, stored.Event, recipients); err != nil { return err }
      }
      return p.outbox.Complete(stored)
  }
  ```

- [ ] **Step 5: Add the server-only manifest**

  ```json
  {
    "id": "com.threadhub.channel-email-notifier",
    "name": "ThreadHub Channel Email Notifier",
    "description": "Queues generic email notices for new public and private channel posts.",
    "homepage_url": "https://github.com/nugaing119/ThreadHub",
    "support_url": "https://github.com/nugaing119/ThreadHub/issues",
    "version": "0.1.0",
    "min_server_version": "11.7.7",
    "server": {
      "executables": {
        "linux-amd64": "server/dist/plugin-linux-amd64"
      }
    }
  }
  ```

- [ ] **Step 6: Run all Go tests**

  Run: `cd notifier && go fmt ./plugin/... && go test -race ./...`

  Expected: 모두 성공.

- [ ] **Step 7: Commit**

  ```bash
  git add notifier/plugin
  git commit -m "feat: hook mattermost channel posts"
  ```

---

## Task 9: Produce reproducible AMD64 artifacts and a hardened Mailer image

**Files:**

- Create: `notifier/Makefile`
- Create: `notifier/Dockerfile`
- Create: `notifier/.dockerignore`
- Modify: `deploy/versions.env`
- Modify: `.gitignore`

**Interfaces:**

- Consumes: all Task 1~8 Go packages and pinned builder manifest.
- Produces: target `plugin-bundle`, target `mailer`, `dist/com.threadhub.channel-email-notifier-0.1.0.tar.gz`, Mailer image `threadhub/notifier-mailer:0.1.0`, SHA-256 values consumed by Task 10.

- [ ] **Step 1: Add failing artifact checks to the Makefile**

  `make verify`가 다음을 순서대로 실행하게 작성하되 아직 Dockerfile target이 없어 실패하는 상태를 먼저 확인한다.

  ```text
  gofmt check
  go mod verify
  go vet ./...
  go test -race ./...
  linux/amd64 plugin bundle build
  linux/amd64 mailer image build
  bundle path/type/manifest validation
  ```

- [ ] **Step 2: Pin the builder image**

  `deploy/versions.env`에 다음 exact baseline을 추가한다.

  ```text
  NOTIFIER_VERSION=0.1.0
  NOTIFIER_PLUGIN_ID=com.threadhub.channel-email-notifier
  GO_BUILDER_IMAGE_REPOSITORY=golang
  GO_BUILDER_IMAGE_TAG=1.25.10-bookworm
  GO_BUILDER_IMAGE_DIGEST=sha256:c99705d76da262268a7d29ff9638b2ad51d141512fea8489f5bad3e4a6e95d07
  GO_BUILDER_IMAGE_INDEX_DIGEST=sha256:154bd7001b6eb339e88c964442c0ad6ed5e53f09844cc818a41ce4ecb3ce3b43
  ```

  첫 digest는 linux/amd64 runtime manifest, 두 번째는 multi-platform provenance다.

- [ ] **Step 3: Implement a multi-target Dockerfile**

  ```dockerfile
  ARG GO_BUILDER_IMAGE
  FROM ${GO_BUILDER_IMAGE} AS build
  WORKDIR /src
  COPY go.mod go.sum ./
  RUN go mod download && go mod verify
  COPY . .
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

  FROM scratch AS plugin-bundle
  COPY --from=build /out/bundle/ /

  FROM scratch AS mailer
  COPY --from=build /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
  COPY --from=build /out/threadhub-mailer /threadhub-mailer
  USER 65532:65532
  ENTRYPOINT ["/threadhub-mailer"]
  CMD ["serve"]
  ```

  실제 build stage에서 manifest를 복사하고 top-level plugin ID directory를 다음과 같은 deterministic stream으로 묶는다.

  ```dockerfile
  SHELL ["/bin/bash", "-o", "pipefail", "-c"]
  RUN cp plugin/plugin.json /out/plugin/com.threadhub.channel-email-notifier/plugin.json \
      && tar --sort=name --mtime='UTC 2020-01-01' \
          --owner=0 --group=0 --numeric-owner \
          -C /out/plugin -cf - com.threadhub.channel-email-notifier \
      | gzip -n -9 > /out/bundle/com.threadhub.channel-email-notifier-0.1.0.tar.gz
  ```

- [ ] **Step 4: Test artifact properties**

  - bundle에는 정확히 plugin ID top-level 하나와 `plugin.json`, linux-amd64 executable만 존재
  - tar에 absolute path, `..`, symlink, hardlink 없음
  - binary `go version -m`이 public API v0.3.0을 표시
  - Mailer image user가 `65532:65532`, root filesystem write가 실패
  - Mailer binary와 plugin bundle SHA-256 생성
  - 동일 source commit 두 번 build한 bundle SHA-256 동일

- [ ] **Step 5: Run verification**

  Run: `cd notifier && make verify`

  Expected: Go 시험과 두 AMD64 artifact 검증 성공.

- [ ] **Step 6: Commit**

  ```bash
  git add notifier/Makefile notifier/Dockerfile notifier/.dockerignore deploy/versions.env .gitignore
  git commit -m "build: package notifier artifacts reproducibly"
  ```

---

## Task 10: Integrate Mailer and the reviewed plugin into Docker Compose

**Files:**

- Modify: `deploy/docker-compose.yml`
- Modify: `deploy/scripts/common.sh`
- Modify: `deploy/scripts/deploy.sh`
- Modify: `deploy/scripts/health-check.sh`
- Modify: `deploy/scripts/destroy.sh`
- Modify: `deploy/scripts/validate.sh`
- Create: `deploy/scripts/build-notifier.sh`
- Create: `deploy/scripts/install-notifier-plugin.sh`

**Interfaces:**

- Consumes: Task 9 bundle/image, existing `compose()` helper, protected `deploy/.env`, `/srv/threadhub` bind mounts.
- Produces: active `com.threadhub.channel-email-notifier` plugin, healthy `threadhub-mailer` Compose service, `/srv/threadhub/notifier/release/release.env`; no host Mailer port and no changed persistent chat data.

- [ ] **Step 1: Add failing static invariants to `validate.sh`**

  먼저 다음 grep/YAML checks를 추가하고 실패를 확인한다.

  - `MM_PLUGINSETTINGS_ENABLE: "true"`
  - uploads/Marketplace/remote/automatic은 모두 false
  - `MM_EMAILSETTINGS_SENDEMAILNOTIFICATIONS=false`와 `MM_EMAILSETTINGS_SENDPUSHNOTIFICATIONS=false` 유지
  - `MM_SERVICESETTINGS_ENABLEINCOMINGWEBHOOKS=false`, `MM_SERVICESETTINGS_ENABLEOUTGOINGWEBHOOKS=false`, `MM_SERVICESETTINGS_ENABLEBOTACCOUNTCREATION=false`, `MM_SERVICESETTINGS_ENABLEUSERACCESSTOKENS=false` 유지
  - Mailer에 host `ports` 없음
  - `notifier` network는 `internal: true`
  - Mailer는 `notifier`+`outbound`, Mattermost는 `database`+`notifier`+`outbound`
  - Mailer queue bind mount와 Mattermost·Mailer 양쪽 control read-only mount 존재
  - 두 container에 control read 전용 supplemental GID 3000이 있고 다른 서비스에는 없음
  - Mailer `read_only`, `cap_drop: ALL`, `no-new-privileges`, numeric non-root user
  - plugin bundle build/install scripts 존재
  - Go builder digest 형식과 manifest 검증

  Run: `./deploy/scripts/validate.sh`

  Expected: 새 Compose/service/script가 없어 실패.

- [ ] **Step 2: Add the Mailer service**

  Compose 핵심 형태는 다음과 같다.

  ```yaml
  threadhub-mailer:
    image: "threadhub/notifier-mailer:${NOTIFIER_VERSION}"
    build:
      context: ../notifier
      target: mailer
      args:
        GO_BUILDER_IMAGE: "${GO_BUILDER_IMAGE_REPOSITORY}:${GO_BUILDER_IMAGE_TAG}@${GO_BUILDER_IMAGE_DIGEST}"
    platform: linux/amd64
    user: "65532:65532"
    group_add: ["3000"]
    read_only: true
    cap_drop: [ALL]
    security_opt: [no-new-privileges:true]
    restart: unless-stopped
    mem_limit: 512m
    tmpfs:
      - /tmp:rw,noexec,nosuid,nodev,size=32m
    volumes:
      - "${THREADHUB_DATA_ROOT}/notifier/mailer:/var/lib/threadhub-notifier:rw"
      - "${THREADHUB_DATA_ROOT}/notifier/control:/run/threadhub-notifier:ro"
    networks: [notifier, outbound]
    healthcheck:
      test: [CMD, /threadhub-mailer, healthcheck]
    logging:
      driver: json-file
      options:
        max-size: 10m
        max-file: "3"
  ```

  SMTP와 HMAC 환경값은 Compose가 `.env`에서 container env로 전달하되 어떤 상태 명령도 전체 env를 출력하지 않게 한다.

- [ ] **Step 3: Update Mattermost settings and mounts**

  - `MM_PLUGINSETTINGS_ENABLE=true`
  - 업로드/Marketplace/remote/automatic은 계속 false
  - `NOTIFIER_DOMAIN`, `NOTIFIER_MAILER_URL`, `NOTIFIER_HMAC_SECRET`, `NOTIFIER_CONTROL_FILE` 전달
  - control directory read-only mount
  - supplemental group `3000` 추가
  - plugin directory 기존 explicit bind mount 유지

- [ ] **Step 4: Implement secure build/release recording**

  `build-notifier.sh`는 실제 `.env`를 출력하지 않고 다음을 수행한다.

  1. pinned builder digest로 plugin bundle export
  2. Compose Mailer image build
  3. bundle SHA-256, image ID, source commit, notifier version을 `/srv/threadhub/notifier/release/release.env`에 기록
  4. release file에는 domain, email, username, credential, channel ID를 기록하지 않음

- [ ] **Step 5: Implement manual filesystem plugin installation**

  업로드 API는 `EnableUploads=false`이면 공식 v11.7.7 코드에서 거부되므로 사용하지 않는다. 공식 지원 수동 경로에 따라 번들을 검사·압축 해제한다.

  1. SHA-256을 release manifest와 비교
  2. tar entry가 plugin ID 아래 regular file/directory뿐인지 확인
  3. temp directory에 `--no-same-owner --no-same-permissions`로 추출
  4. manifest ID/version/server executable 검증
  5. `2000:2000`, directory 0750, files 0640, executable 0750 적용
  6. 기존 같은 hash면 no-op
  7. 다른 hash면 control disable → plugin disable → Mattermost stop → 기존 bundle backup → atomic rename
  8. Mattermost start 후 `mmctl plugin enable ... --local --suppress-warnings`
  9. `mmctl plugin list`에서 exact ID/version/active 검증

- [ ] **Step 6: Extend deployment and health checks**

  `deploy.sh`는 directory를 다음 권한으로 만든다.

  ```text
  /srv/threadhub/notifier/control  root:3000   0750
  /srv/threadhub/notifier/mailer   65532:65532 0700
  /srv/threadhub/notifier/release  root:root   0750
  ```

  `health-check.sh`는 Mailer container health, queue bind mount type/source/destination, control mount read-only, host published port 부재, SQLite parent ownership을 검사한다. `destroy.sh`는 control을 disable한 뒤 Compose를 내리고 `/srv/threadhub`를 보존한다.

- [ ] **Step 7: Run static and Compose checks**

  Run: `./deploy/scripts/validate.sh`

  Run when Docker is available: `docker compose --env-file deploy/.env.example --env-file deploy/versions.env -f deploy/docker-compose.yml config --quiet`

  Expected: 성공하며 어떤 secret도 출력하지 않음.

- [ ] **Step 8: Commit**

  ```bash
  git add deploy/docker-compose.yml deploy/scripts
  git commit -m "feat: deploy internal notifier services"
  ```

---

## Task 11: Gate fresh installs on SMTP acceptance and notifier activation

**Files:**

- Modify: `deploy/.env.example`
- Modify: `deploy/scripts/common.sh`
- Modify: `deploy/scripts/setup-wizard.sh`
- Modify: `deploy/scripts/readiness-check.sh`
- Modify: `deploy/scripts/install-status.sh`
- Modify: `deploy/scripts/validate.sh`
- Create: `deploy/scripts/configure-notifier.sh`
- Create: `deploy/scripts/notifier-lib.sh`
- Create: `deploy/scripts/notifier-control.sh`
- Create: `deploy/scripts/notifier-smtp-test.sh`
- Create: `deploy/scripts/notifier-status.sh`
- Create: `deploy/tests/notifier-installer-test.sh`
- Modify: `.github/workflows/validate.yml`

**Interfaces:**

- Consumes: Task 10 running services, existing wizard exit-code 20 contract, target defaults from `.env`.
- Produces: `notifier-control.sh activate|drain|disable|status`, `notifier-smtp-test.sh`, PII-free SMTP acceptance marker, actual state file, and `[READY]` only after automated notification gates.

- [ ] **Step 1: Write failing installer helper tests**

  temporary files만 사용해 다음을 먼저 고정한다.

  - fresh env default: enabled=true, mode=all_channels, empty IDs, rate=10
  - HMAC secret 자동 생성은 64 hex이며 stdout/stderr에 없음
  - existing complete notifier keys는 재사용하고 어떤 행도 변경하지 않음
  - existing env에 notifier keys가 전혀 없으면 configure script가 없는 key만 append
  - 일부 notifier key만 있으면 자동 추측하지 않고 `[ACTION REQUIRED]`
  - control JSON atomic write와 enabled/delivery-enabled/mode/ID validation
  - missing/invalid state는 disabled
  - SMTP marker fingerprint가 server/port/username/password/from 변경 시 invalid
  - marker에는 test recipient, username, sender가 없음
  - activation은 새 millisecond cutoff를 기록하고 pre-activation queue count가 0일 때만 성공
  - drain은 enabled=false/delivery-enabled=true, disable은 두 값 false를 기록하되 data/queue를 삭제하지 않음

  Run: `./deploy/tests/notifier-installer-test.sh`

  Expected: helper/scripts 부재로 실패.

- [ ] **Step 2: Add notifier environment defaults**

  ```text
  NOTIFIER_ENABLED=true
  NOTIFIER_MODE=all_channels
  NOTIFIER_CHANNEL_IDS=
  NOTIFIER_HMAC_SECRET=REPLACE_WITH_64_HEX_CHARACTER_HMAC_SECRET
  NOTIFIER_RATE_PER_MINUTE=10
  ```

  `common.sh`에는 빈 값을 허용하는 `env_optional_value`와 `validate_notifier_env`를 추가한다. allowlist 모드에서는 쉼표로 구분한 unique Mattermost channel ID가 하나 이상이어야 한다.

- [ ] **Step 3: Extend the fresh setup wizard safely**

  새 `.env`를 만드는 동일 invocation 안에서 `openssl rand -hex 32`로 HMAC을 생성해 temp file에 기록한다. 값을 화면에 출력하지 않는다. 기존 `.env`에는 setup wizard가 값을 append/replace하지 않고, 누락 시 정확히 `./deploy/scripts/configure-notifier.sh`를 안내하고 exit 20 한다.

- [ ] **Step 4: Implement one-time SMTP acceptance**

  `notifier-smtp-test.sh`는 TTY에서 test recipient를 한 번 입력받아 stdin으로 Mailer CLI에 전달한다. 성공 시 HMAC으로 계산한 SMTP config fingerprint와 accepted timestamp만 control directory marker에 기록한다. fingerprint 입력에는 server, port, username, `HMAC(password)`, From을 포함해 credential rotation을 감지하되 원문 값은 marker에 남기지 않는다. non-interactive이면 다음만 출력하고 exit 20 한다.

  ```text
  [ACTION REQUIRED] Run ./deploy/scripts/notifier-smtp-test.sh in an interactive terminal.
  Then rerun: ./deploy/scripts/setup-wizard.sh --resume --non-interactive
  ```

- [ ] **Step 5: Implement actual-state activation**

  `notifier-control.sh activate --from-env`는 다음 조건을 모두 확인한다.

  - Mailer/Mattermost/PostgreSQL healthy
  - exact plugin ID/version active
  - Mailer host port 없음
  - current SMTP fingerprint marker valid
  - Mailer pre-activation pending/sending count 0
  - target enabled/all_channels 또는 명시적 disabled opt-out

  조건 통과 후에만 `enabled=true`, `delivery_enabled=true`와 current milliseconds를 state file에 원자 기록한다. 대화형 `activate`는 기존 live rollout용으로 mode와 allowlist ID를 prompt에서 받아 argv/history에 남기지 않는다. `drain`과 `disable`은 별도 subcommand로 제공한다.

  `notifier-control.sh status`와 `notifier-status.sh`는 mode와 allowlist **개수**만 표시하고 실제 channel ID는 출력하지 않는다.

- [ ] **Step 6: Update readiness and status semantics**

  `readiness-check.sh`는 기존 `MM_PLUGINSETTINGS_ENABLE=false` 기대값을 true로 바꾸고 plugin/mailer/marker/actual state를 검사한다. `install-status.sh`는 자동 검사를 `[OK]`, 받은편지함·링크·SPF/DKIM·공개/비공개 수신자·CJK·모바일을 `[MANUAL]`로 분리한다. PII는 출력하지 않는다. setup wizard의 마지막 판정은 별도 `[READY]` 문자열을 직접 만들지 않고 `./deploy/scripts/install-status.sh`를 호출해 그 exit code와 `[READY]`를 그대로 사용한다.

- [ ] **Step 7: Update CI wizard exercise**

  configure-only expect flow가 notifier secret을 묻지 않고 자동 생성하는지, 생성된 `.env` mode가 0600인지, 출력에 generated secret/fixture SMTP password가 없는지 검사한다. CI는 실제 OCI SMTP가 없으므로 full wizard `[READY]`를 기대하지 않는다.

- [ ] **Step 8: Run installer and repository validations**

  Run: `./deploy/tests/notifier-installer-test.sh`

  Run: `./deploy/scripts/validate.sh`

  Run: `shellcheck -x -P deploy/scripts deploy/scripts/*.sh deploy/tests/*.sh`

  Expected: 모두 성공.

- [ ] **Step 9: Commit**

  ```bash
  git add deploy/.env.example deploy/scripts deploy/tests .github/workflows/validate.yml
  git commit -m "feat: gate notifier activation during install"
  ```

---

## Task 12: Add real-image integration and fault-injection coverage

**Files:**

- Create: `notifier/integration/docker-compose.yml`
- Create: `notifier/integration/run.sh`
- Create: `notifier/integration/cmd/smtp-fixture/main.go`
- Create: `notifier/integration/cmd/acceptance/main.go`
- Modify: `.github/workflows/validate.yml`
- Modify: `notifier/Makefile`

**Interfaces:**

- Consumes: Tasks 1~11 production artifacts and pinned Mattermost/PostgreSQL images.
- Produces: `make integration` and deterministic `NF-*` pass/fail output with no dependency on OCI, production `/srv/threadhub`, or actual credentials.

- [ ] **Step 1: Write the acceptance scenario list before the harness**

  `acceptance` 명령은 실패하는 assertion 이름만 출력하고 다음 ID를 수행한다.

  ```text
  NF-FN-01 public root
  NF-FN-02 private root
  NF-FN-03 public thread reply
  NF-FN-04 private thread reply
  NF-FN-05 non-member excluded
  NF-FN-06 inactive user excluded
  NF-FN-07 bot recipient excluded
  NF-FN-08 direct/group direct excluded
  NF-SEC-01 generic content only
  NF-SEC-02 one recipient per envelope
  NF-REL-01 mailer down then resume
  NF-REL-03 duplicate event dedupe
  NF-REL-04 mailer recreate queue persistence
  NF-REL-05 mattermost recreate KV persistence
  NF-SEC-04/05/06 HMAC timestamp replay rejection
  ```

- [ ] **Step 2: Confirm the absent harness fails**

  Run: `cd notifier && make integration`

  Expected: integration target/script 부재로 실패.

- [ ] **Step 3: Build an isolated runtime-only SMTP fixture**

  fixture는 컨테이너 시작 때 ephemeral CA/server cert를 생성하고 STARTTLS와 AUTH를 강제한다. certificate/private key는 tmpfs 또는 temporary Docker volume에만 존재하고 Git artifact로 남기지 않는다. Mailer는 integration Compose에서만 `SSL_CERT_FILE`로 이 CA를 신뢰하며 production에 인증서 검증 우회 옵션을 추가하지 않는다. capture API는 test recipient hash, envelope count, generic-content boolean만 제공하고 원문 email/body를 log로 출력하지 않는다.

- [ ] **Step 4: Start real pinned Mattermost/PostgreSQL images**

  integration Compose는 production digest를 그대로 사용하고 host port는 loopback ephemeral만 사용한다. `run.sh`가 temp data root, DB password, HMAC, SMTP fixture password를 생성해 mode 0600 임시 env에 기록하고 EXIT trap에서 Compose와 temp data를 정리한다. production `/srv/threadhub`와 실제 `deploy/.env`는 참조하지 않는다.

- [ ] **Step 5: Install the real plugin bundle manually**

  Task 10과 동일한 filesystem layout으로 번들을 넣고 Mattermost를 재시작한 뒤 local mmctl로 exact plugin active를 확인한다. 이 시험이 uploads=false 상태의 수동 설치 경로를 실제 11.7.7 이미지에서 검증한다.

- [ ] **Step 6: Drive the Mattermost REST scenarios**

  acceptance program은 test admin/session을 만들고 공개·비공개 채널, thread, DM/group DM, membership 변경, inactive user를 생성한다. fixture의 hash/count만 조회해 expected envelope를 검증한다. webhook/bot-origin post filter는 unit test로 유지하며 integration을 위해 운영 설정을 활성화하지 않는다.

- [ ] **Step 7: Add fault injection**

  - Mailer stop 중 post 후 restart → KV 재처리
  - Mailer/SMTP 중지 상태에서도 Mattermost post API가 3초 이내 성공
  - 정상 상태에서 첫 SMTP 시도가 post 생성 후 10초 이내 시작
  - fixture 450 후 정상 → retry
  - Mailer container recreate → SQLite pending 유지
  - Mattermost recreate → KV pending 유지
  - duplicate signed event → recipient당 한 delivery
  - control disable → 새 post 미발송
  - 새 activation cutoff → disable 기간 post 미발송

- [ ] **Step 8: Add CI job**

  Ubuntu 24.04 AMD64 runner에서 Go 1.25.10 unit/race → artifact build → integration 순서로 실행하고 timeout을 25분으로 설정한다. CI artifact에는 bundle SHA와 PII 없는 결과만 업로드하며 임시 env/SQLite/cert는 업로드하지 않는다.

- [ ] **Step 9: Run integration locally where Docker is available**

  Run: `cd notifier && make integration`

  Expected: 모든 `NF-*` 자동 시나리오 성공, EXIT 뒤 test containers/volumes 없음.

- [ ] **Step 10: Commit**

  ```bash
  git add notifier/integration notifier/Makefile .github/workflows/validate.yml
  git commit -m "test: exercise notifier with mattermost image"
  ```

---

## Task 13: Document project isolation, operations, privacy, and acceptance

**Files:**

- Modify: `README.md`
- Modify: `SECURITY.md`
- Modify: `deploy/README.md`
- Modify: `deploy/docs/quick-install.md`
- Modify: `deploy/docs/setup.md`
- Modify: `deploy/docs/admin-guide.md`
- Modify: `deploy/docs/oci-email-delivery.md`
- Modify: `deploy/docs/operations-checklist.md`
- Modify: `deploy/docs/project-close.md`
- Modify: `deploy/docs/test-plan.md`
- Modify: `deploy/docs/test-results-public.md`
- Modify: `deploy/scripts/validate.sh`

**Interfaces:**

- Consumes: approved spec, all user-facing commands and test IDs from Tasks 1~12.
- Produces: linked installation/operation/close/test runbooks and static assertions that prevent those contracts from silently disappearing.

- [ ] **Step 1: Add failing documentation-link and policy assertions**

  `validate.sh`에서 모든 문서 링크·새 script 이름·다음 핵심 문구가 있어야 통과하도록 먼저 추가한다.

  - project-specific IAM user/group/SMTP Credential/exact Approved Sender
  - exact `target.approved-sender.id` condition
  - shared Email Domain/DKIM/SPF only when same domain+region
  - additive IAM policy audit
  - cross-send A/A success, A/B deny, B/B success, B/A deny
  - actual inbox/SPF/DKIM remains manual
  - at-least-once duplicate caveat
  - immediate disable and 24h/7d privacy retention
  - Mattermost Team Edition 정상 plugin API 사용이며 유료 기능·라이선스 검사 변경 없음
  - OCI Email Delivery 비용은 tenancy·region 전체 발송량 기준으로 배포 전에 재확인
  - DNS A record는 unrelated RRset을 덮어쓰지 않고 추가하며 한 hostname을 두 독립 VM에 동시에 연결하지 않음
  - no unauthorized OCI automation

  Run: `./deploy/scripts/validate.sh`

  Expected: 문서 미반영으로 실패.

- [ ] **Step 2: Update installation documentation**

  quick install은 다음 순서를 명시한다.

  1. fresh VM baseline 확인
  2. `./deploy/scripts/validate.sh`
  3. project DNS/Email Delivery 준비
  4. hidden SMTP input과 generated HMAC
  5. build/install
  6. one-time SMTP acceptance
  7. activation cutoff
  8. `[READY]` 자동 항목
  9. inbox/link/SPF/DKIM/permissions/CJK/mobile 수동 항목

- [ ] **Step 3: Document exact OCI isolation without secrets**

  다음 조건부 policy를 그대로 설명하되 실제 identity domain, group, Compartment, Approved Sender OCID는 공개 저장소에 기록하지 않는다.

  ```text
  Allow group '<identity-domain>'/'<project-smtp-group>'
  to use approved-senders
  in compartment <project-compartment>
  where target.approved-sender.id = '<project-approved-sender-ocid>'
  ```

  위 표기의 angle-bracket 값은 사용자가 승인한 비공개 change record에서만 해석한다. domain-wide sender나 broad `email-family` policy는 금지한다.

- [ ] **Step 4: Document operations and close behavior**

  - status counters와 oldest pending 기준
  - `drain`으로 새 수집만 중지 → 최대 10분 queue 처리 → `disable`로 SMTP까지 중지 → retry/cancel 순서와 queue backup 범위
  - SMTP credential rotation 시 marker 재시험
  - HMAC rotation은 notifier disable+queue drain/cancel 뒤 수행
  - project close 시 email scrub → SMTP credential → exact sender → membership/user/policy/group → project A record 순서
  - 공유 Email Domain/DKIM/SPF/DNS zone은 별도 영향분석·명시적 승인 없이는 삭제하지 않음

- [ ] **Step 5: Expand test plan**

  설계의 `NF-FN-*`, `NF-SEC-*`, `NF-REL-*`, `NF-INS-*`, `NF-IAM-*`를 자동/수동/라이브 승인 필요로 구분한다. `test-results-public.md`에는 test date, source commit, image/plugin SHA, pass/fail만 두고 실제 운영 식별자를 넣지 않는다.

- [ ] **Step 6: Run link/policy validation**

  Run: `./deploy/scripts/validate.sh`

  Run: `rg -n 'REPLACE_WITH_(?!64_HEX)' README.md SECURITY.md deploy/docs deploy/scripts --pcre2`

  Expected: validation 성공, 허용된 `.env.example` placeholder 외 미결 표기 없음.

- [ ] **Step 7: Commit**

  ```bash
  git add README.md SECURITY.md deploy/README.md deploy/docs deploy/scripts/validate.sh
  git commit -m "docs: operate isolated channel email notices"
  ```

---

## Task 14: Run the complete release verification from a clean checkout

**Files:**

- Modify: `deploy/docs/test-results-public.md`
- Modify only if a verification defect is found: files introduced in Tasks 1~13

**Interfaces:**

- Consumes: clean committed outputs of Tasks 1~13.
- Produces: reproducible release evidence and a code-review gate; it does not deploy or mutate OCI/live resources.

- [ ] **Step 1: Run formatting, module, unit, and race checks**

  ```bash
  cd notifier
  unformatted="$(gofmt -l $(rg --files -g '*.go'))"
  test -z "${unformatted}"
  go mod verify
  go vet ./...
  go test -race ./...
  cd ..
  ```

  Expected: 모든 명령 exit 0.

- [ ] **Step 2: Run deployment package checks**

  ```bash
  ./deploy/tests/notifier-installer-test.sh
  ./deploy/scripts/validate.sh
  shellcheck -x -P deploy/scripts deploy/scripts/*.sh deploy/tests/*.sh
  git diff --check
  ```

  Expected: 모두 성공하고 stdout/stderr에 fixture secret이 없음.

- [ ] **Step 3: Build twice and compare reproducibility**

  clean temporary directories 두 곳에서 같은 commit을 build하고 plugin bundle SHA-256을 비교한다. Mailer의 OCI image ID는 build metadata에 따라 달라질 수 있으므로 binary SHA와 `go version -m` dependency list를 비교한다.

- [ ] **Step 4: Run real-image integration**

  Run: `cd notifier && make integration`

  Expected: Task 12의 모든 자동 `NF-*` 시나리오 성공.

- [ ] **Step 5: Re-run public repository security scans**

  ```bash
  if git grep -Il -E 'AKIA[0-9A-Z]{16}|ASIA[0-9A-Z]{16}|gh[opusr]_[A-Za-z0-9_]{20,}|github_pat_[A-Za-z0-9_]{20,}|xox[baprs]-[A-Za-z0-9-]{10,}|ocid1\.|BEGIN ([A-Z]+ )*PRIVATE KEY' -- .; then
      exit 1
  fi
  if git ls-files | rg '(^|/)(\.env$|.*\.(key|pem|p12|pfx|tfstate|db|sqlite)(-|$|\.))'; then
      exit 1
  fi
  ```

  Expected: 두 조건 모두 match 없이 통과하고 GitHub Actions gitleaks history scan도 성공.

- [ ] **Step 6: Record only non-sensitive evidence**

  `test-results-public.md`에 source commit, Mattermost/PostgreSQL digest, notifier version, plugin/binary SHA, 자동시험 pass count만 기록한다. SMTP 주소, 수신자, 도메인, channel/user ID, raw log는 비공개 운영 기록에만 둔다.

- [ ] **Step 7: Review against every approved-spec clause**

  설계 4~13장의 항목마다 구현 파일 또는 수동시험 ID가 하나 이상 연결되는 coverage 표를 로컬 review note에 작성한다. 연결되지 않은 항목이 있으면 출시 준비를 중단하고 해당 Task로 돌아간다.

- [ ] **Step 8: Commit final verification evidence**

  ```bash
  git add deploy/docs/test-results-public.md
  git commit -m "test: record notifier release verification"
  ```

- [ ] **Step 9: Request code review before any live change**

  `superpowers:requesting-code-review`로 spec coverage, security boundary, retry/privacy behavior, installer non-overwrite contract를 검토받고 High/Critical 이슈를 모두 해결한다.

---

## Task 15: Gated rollout to an existing project instance

**This task is not authorized by approval of this plan or Tasks 1~14. It starts only after a new explicit user approval for the named target and OCI scope.**

**Files:** None in the public repository. Actual values and evidence belong in the private operations record.

**Interfaces:**

- Consumes: reviewed Task 14 release, a separately approved target/scope, private project identifiers and credentials entered outside chat/Git.
- Produces: allowlist acceptance evidence first and, only after a second explicit approval, actual all-channel activation or a documented rollback.

- [ ] **Step 1: Reconfirm scope and authority**

  사용자에게 대상 VM/hostname, target Compartment, `ap-singapore-1`, 허용 downtime을 확인한다. 리전 비종속 IAM 사용자·그룹·정책·SMTP Credential 생성/변경과 DNS/Approved Sender 변경은 각각 명시적 승인을 받는다.

- [ ] **Step 2: Perform read-only preflight**

  - Ubuntu 24.04 AMD64, 2 OCPU, 16GB, storage 여유
  - repository commit and clean deployment package
  - existing `/srv/threadhub`와 `.env` presence/mode
  - Mattermost/PostgreSQL health
  - current plugin settings and mount types
  - current SMTP credential이 project-specific인지 여부
  - 적용되는 모든 group membership/upstream IAM email policy
  - Email Delivery quota/rate와 suppression 상태

  어떤 secret도 terminal/chat에 표시하지 않는다.

- [ ] **Step 3: Establish project-specific SMTP isolation after approval**

  전용 IAM user/group/SMTP credential/exact-address Approved Sender/OCID condition policy를 준비하고 다음을 비공개 기록으로 검증한다.

  ```text
  Credential A + Sender A -> accepted
  Credential A + Sender B -> denied
  Credential B + Sender B -> accepted
  Credential B + Sender A -> denied
  ```

  광범위한 상위 policy가 하나라도 교차 발신을 허용하면 No-Go다.

- [ ] **Step 4: Take a recoverable pre-change safety copy**

  Mattermost를 일관되게 중지할 수 있는 window에서 database, config, local data와 현재 Compose/release manifest의 수동 안전 복사본을 만든다. 백업 경로·권한·복구 확인을 비공개 기록에 남긴다.

- [ ] **Step 5: Deploy with actual notification disabled**

  먼저 저장소 `quick-install.md`와 `validate.sh`를 읽고 실행한다. Mailer와 plugin을 배포하되 control state를 disabled/missing으로 유지해 신규 수집과 SMTP 발송을 모두 막는다. 예상 30~60초 Mattermost 재연결 외 로그인·메시지·파일·Team/channel membership에 영향이 없는지 확인한다.

- [ ] **Step 6: Run SMTP acceptance and activate an admin-only allowlist**

  관리자 2명만 있는 임시 Team의 공개·비공개 test channel ID를 대화형 `notifier-control.sh activate`에 입력한다. activation cutoff 이전 글이 발송되지 않는지 먼저 확인한다.

- [ ] **Step 7: Complete manual acceptance**

  - public/private root와 thread reply
  - author excluded/current members only
  - non-member/inactive/bot excluded
  - generic email only, one recipient per email
  - permalink login/authorization
  - actual inbox arrival and spam folder
  - SPF/DKIM pass
  - Mailer stop/restart, container recreate, VM reboot
  - duplicate, temporary failure, permanent failure
  - logs/SQLite privacy inspection
  - immediate disable and rollback

- [ ] **Step 8: Apply Go/No-Go gate**

  잘못된 수신자, private/DM 정보 노출, cross-project sender 성공, secret/PII log, SMTP 장애의 채팅 영향, 대량 중복, pre-activation 발송 중 하나라도 있으면 즉시 disable하고 rollback한다.

- [ ] **Step 9: Ask for a second explicit approval before all-channels mode**

  allowlist 결과, 예상 일 발송량·비용, OCI rate/quota, 잔여 위험을 사용자에게 보고한다. 별도 승인을 받은 뒤에만 새 activation cutoff로 `all_channels`를 적용한다.

- [ ] **Step 10: Finish with separate automated and manual reports**

  `./deploy/scripts/install-status.sh` 결과와 수동 inbox/permissions/CJK/mobile/notification 결과를 구분해 보고한다. wizard가 `[READY]`이고 승인된 수동시험이 끝나기 전에는 설치 완료라고 선언하지 않는다.

---

## Definition of Done

- Go unit/race, shell/static, artifact reproducibility, 실제 Mattermost 11.7.7 integration 시험이 모두 통과한다.
- plugin 훅은 KV write 외 blocking/network/API 조회를 하지 않는다.
- 공개·비공개 root/thread만 현재 채널 멤버에게 전달되고 author/비활성/봇/미확인 이메일은 제외된다.
- DM/group DM/system/edit/delete/reaction은 전달되지 않는다.
- 이메일·payload·로그·scrub 후 SQLite에 금지된 콘텐츠가 없다.
- Mailer ACK 이전에는 plugin KV가 삭제되지 않고 재시작 후 queue/outbox가 복구된다.
- strict STARTTLS/AUTH, HMAC timestamp/nonce/replay, no host port, non-root/read-only container가 검증된다.
- runtime `disable`이 신규 수집과 SMTP를 모두 멈추고 `drain`이 기존 queue만 처리한다.
- 신규 설치는 OCI SMTP 접수시험 뒤 activation cutoff를 기록해야만 `[READY]`가 된다.
- existing `.env`와 `/srv/threadhub`를 자동 교체·삭제하지 않는다.
- project-specific IAM/SMTP/Sender 격리와 교차 발신 거부 절차가 문서화된다.
- 운영 인스턴스 전역 활성화는 별도 명시적 승인 전에는 수행되지 않는다.
