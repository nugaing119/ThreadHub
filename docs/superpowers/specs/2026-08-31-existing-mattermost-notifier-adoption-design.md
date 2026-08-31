# Existing Mattermost Notifier Adoption Design

## 1. 문서 정보

| 항목 | 내용 |
| --- | --- |
| 문서 유형 | 구조 설계 기준선 |
| 기준일 | 2026-08-31 |
| 대상 기능 | ThreadHub 즉시 채널 이메일 알림을 기존 Mattermost에 안전하게 추가 |
| 신규 설치 기준 | 기존 `deploy/scripts/setup-wizard.sh` 흐름 유지 |
| 기존 설치 기준 | 별도 사전점검·Compose override·단계적 활성화 흐름 추가 |
| 검증 기준 | Ubuntu 24.04 AMD64, Docker Compose v2, Mattermost Team Edition 11.7.7, 단일 노드 |

## 2. 목적

ThreadHub 저장소는 새 프로젝트용 전체 Mattermost 설치와 이미 운영 중인 별도
Mattermost에 notifier만 추가하는 작업을 모두 지원한다. 두 경로는 같은 플러그인과
Mailer를 사용하지만 설치 계약은 분리한다.

- 신규 프로젝트는 현재의 고정 Docker Compose 구성을 처음부터 배포한다.
- 기존 Mattermost는 기존 Compose 파일, 데이터베이스, Team, 채널, 사용자, 메시지,
  첨부파일, NGINX, DNS와 TLS를 소유하거나 다시 구성하지 않는다.
- 기존 Mattermost 적용은 지원 조건을 모두 확인한 경우에만 진행한다.
- 불확실하거나 지원하지 않는 구성에서는 변경 전에 exit code `20`과
  `[ACTION REQUIRED]`를 반환한다.
- 적용 후에도 운영자의 명시적 승인 전에는 전역 채널 알림을 활성화하지 않는다.

이 설계는 임의의 Mattermost 배포 방식을 모두 자동화하는 것이 아니다. 검증된 단일
노드 Docker Compose 구성을 안전하게 지원하는 것이 목적이다.

## 3. 범위

### 3.1 포함 범위

- 새 ThreadHub 프로젝트의 notifier 포함 전체 설치 회귀 보호
- 기존 Mattermost용 읽기 전용 사전점검
- 기존 Compose 파일을 수정하지 않는 notifier override 생성
- 기존 Mattermost 서비스에 notifier 환경변수, 내부 네트워크와 읽기 전용 control
  mount 추가
- 별도 Mailer 컨테이너와 영구 SQLite queue 추가
- 고정 버전·SHA-256으로 검토된 서버 플러그인 설치
- 기본 비활성, 시험 채널 allowlist, 전역 활성화의 3단계 제어
- SMTP 접수, 공개·비공개 채널, 루트 글·스레드 답글과 링크 수동 인수시험
- 적용 전 상태 기록과 데이터 비삭제 롤백
- 설치·상태·롤백 절차와 지원 범위를 GitHub 문서에 공개

### 3.2 제외 범위

- Kubernetes, Mattermost Operator 또는 다중 노드 배포
- bare-metal/systemd Mattermost 자동 적용
- ARM64
- Mattermost Cloud
- 검증되지 않은 Mattermost 버전 자동 적용
- 기존 Mattermost 데이터베이스, NGINX, DNS, 인증서 또는 SMTP 설정의 자동 변경
- 기존 Compose 원본 파일 또는 기존 비밀 환경파일의 재작성
- 과거 메시지 소급 발송
- DM, 그룹 DM, 시스템 글, 봇 또는 Webhook 글 알림
- Professional·Enterprise 기능 활성화 또는 라이선스 검사 변경

## 4. 지원 매트릭스

| 구성 | 신규 ThreadHub | 기존 Mattermost 적용 |
| --- | --- | --- |
| Ubuntu 24.04 LTS AMD64 | 필수 | 필수 |
| Docker Compose v2 | 필수 | 필수 |
| Mattermost Team Edition 11.7.7 | 고정 | 최초 지원 버전 |
| 단일 Mattermost replica | 필수 | 필수 |
| 공식 Mattermost 컨테이너 레이아웃 | 고정 | 필수 |
| `/mattermost/plugins` host bind mount | 고정 | 필수 |
| `/mattermost/data` host bind mount | 고정 | 필수 |
| 기존 Compose service 선택 | `mattermost` | 안전한 service 이름을 구성으로 지정 |
| 정상 HTTPS Site URL | 설치기가 구성 | 적용 전 필수 |
| SMTP 587 STARTTLS | OCI Email Delivery | OCI 또는 동등한 검증된 SMTP relay |
| 기타 버전·배포 방식 | 미지원 | 변경 없이 중단하고 수동 검토 |

`plugin.json`의 `min_server_version`만으로 미래 Mattermost 호환성을 보장하지 않는다.
11.7.7 이외 버전은 해당 서버 이미지로 자동 통합시험을 추가하고, 플러그인 API와
영구 경로를 재검토한 뒤 지원 매트릭스에 명시적으로 추가한다.

## 5. 검토한 접근법

### 5.1 전체 ThreadHub Compose로 교체

기존 Mattermost를 ThreadHub의 `deploy/docker-compose.yml`로 재구성하면 구현은
단순하지만 기존 데이터 경로, 네트워크, 환경변수와 운영 책임을 침범한다. 기존
서비스의 안전한 notifier 추가라는 목적에 맞지 않아 채택하지 않는다.

### 5.2 모든 배포 방식을 추상화하는 범용 설치기

Docker Compose, systemd, Kubernetes와 다중 노드를 한 번에 지원하면 사용 범위는
넓지만 검증 조합과 롤백 복잡도가 급격히 증가한다. MVP 범위를 넘어 채택하지 않는다.

### 5.3 사전점검과 생성형 Compose override

기존 Compose를 읽기 전용 입력으로 사용하고, 검증된 notifier override와 전용 비밀
환경파일을 별도로 생성한다. 불일치 시 변경 전에 중단하고 기존 Mattermost 서비스만
통제된 방식으로 한 번 재생성한다. 기존 자산의 소유권을 보존하고 자동시험 가능한
경계가 명확하므로 이 방식을 채택한다.

## 6. 구성요소

### 6.1 기존 설치용 구성파일

Git에 포함하지 않는 mode `0600` 구성파일에 다음 값을 저장한다.

- 기존 Compose 프로젝트 절대경로
- 기존 Compose 파일 절대경로
- Compose interpolation에 사용하는 기존 환경파일 절대경로
- Mattermost service 이름
- Mattermost plugins와 data의 검증된 host bind 경로
- notifier 전용 데이터 루트(기본 `/srv/threadhub-notifier`)
- HTTPS hostname
- SMTP hostname, port, username, password, From, Reply-To와 표시 이름
- 생성된 64자 hexadecimal HMAC secret
- rate limit

SMTP password와 HMAC은 명령행 인수, 로그, 상태 출력, Git 또는 생성된 Compose
canonical output에 표시하지 않는다. 설정은 숨김 입력으로만 받으며 기존 Mattermost
환경파일에 notifier 키를 덧붙이지 않는다.

### 6.2 읽기 전용 사전점검

사전점검은 다음 항목을 확인하고 파일 생성, 컨테이너 재생성, 플러그인 복사 또는
runtime state 변경을 하지 않는다.

1. Ubuntu 24.04, AMD64와 Docker Compose v2
2. 기존 Compose 원본과 환경파일의 일반 파일·소유권·권한·symlink 경계
3. `docker compose config --quiet` 성공
4. 지정 Mattermost service가 정확히 하나 존재하고 replica가 하나임
5. 실행 이미지가 Mattermost Team Edition 11.7.7임
6. `/mattermost/plugins`와 `/mattermost/data`가 안전한 절대 host bind mount임
7. notifier service, network, mount, plugin ID 또는 환경변수와 충돌하지 않음
8. HTTPS hostname이 현재 Mattermost Site URL과 일치함
9. notifier 데이터 루트가 기존 Mattermost와 PostgreSQL 데이터 루트 안에 있지 않음
10. 예상 Compose 변경 모델에 기존 service, port, volume과 network가 보존됨

비밀 환경파일을 대상으로 canonical Compose를 출력하는 명령은 금지한다. 자동화가
구조 검사를 위해 JSON을 필요로 하면 값이 치환된 출력 전체를 디스크나 로그에 남기지
않고, 비밀값을 출력하지 않는 전용 검사기로 필요한 구조만 판정한다.

### 6.3 생성된 Compose override

원본 Compose 파일은 수정하지 않는다. 설치기가 notifier 전용 runtime 디렉터리에
override를 원자적으로 생성하고 mode `0600`으로 보호한다. override는 다음 변경만
표현한다.

- 지정 Mattermost service에 `THREADHUB_DOMAIN`, `NOTIFIER_MAILER_URL`,
  `NOTIFIER_HMAC_SECRET`, `NOTIFIER_CONTROL_FILE`, `NOTIFIER_POLL_EVERY` 추가
- Mattermost service에 notifier 내부 network와 control read-only mount 추가
- `threadhub-mailer` service 추가
- Mailer에 notifier 내부 network와 SMTP 전용 outbound network만 연결
- Mailer queue와 control bind mount 추가
- Mailer host port 미노출, non-root, read-only root filesystem, capability 제거,
  `no-new-privileges`, healthcheck와 로그 회전 적용

Mailer 주소는 검토된 플러그인의 고정값인 `http://threadhub-mailer:8080`을 유지한다.
기존 Mattermost service가 가진 database, public network, port, volume, healthcheck와
restart policy는 덮어쓰거나 제거하지 않는다.

### 6.4 설치 오케스트레이션

설치기는 다음 순서를 지킨다.

1. 전체 사전점검 통과
2. notifier가 disabled인 control state 생성
3. 기존 Compose·이미지 ID·Mattermost container ID·mount·network·plugin 상태를
   비밀값 없이 기록
4. notifier 전용 데이터 루트와 queue/control/release 디렉터리 생성
5. 고정 builder와 source commit으로 plugin bundle과 Mailer image 빌드
6. bundle entry, manifest, version과 SHA-256 검증
7. Mailer만 시작하고 health 확인; 발송은 disabled 유지
8. 기존 플러그인 pair가 없거나 검토된 동일 ID·버전인지 확인 후 원자 설치
9. base Compose와 override를 함께 사용해 Mattermost service만 `--no-deps` 재생성
10. Mattermost health와 exact plugin active 상태 확인
11. SMTP acceptance 실행
12. 시험 채널 ID를 입력받아 allowlist와 activation cutoff 기록

어느 단계에서든 실패하면 새 이벤트 수집과 SMTP delivery는 disabled로 유지한다.
기존 PostgreSQL, NGINX와 다른 Compose service를 재생성하지 않는다.

### 6.5 제어와 활성화

신규 프로젝트와 기존 Mattermost의 목표 상태를 구분한다.

- 신규 프로젝트: 설치 마법사의 모든 자동조건과 수동 인수시험을 통과한 뒤 구성된
  목표에 따라 활성화한다.
- 기존 Mattermost: 설치가 성공해도 `disabled`가 기본이며, 시험 채널 allowlist를
  먼저 사용한다.
- 기존 Mattermost의 `all_channels` 전환은 별도의 명시적 명령과 운영자 확인 문구를
  요구한다.
- activation cutoff 이전 글은 어떤 모드에서도 발송하지 않는다.

알림 대상과 개인정보 최소화 규칙은 기존 설계와 동일하다. 공개·비공개 채널의 새
루트 글과 스레드 답글만 처리하고, 실제 채널 멤버 중 작성자와 부적격 계정을 제외한다.
메일에는 일반 안내문과 `/_redirect/pl/{post_id}` 링크만 포함한다.

## 7. 장애 격리와 롤백

### 7.1 예상 영향

기존 Mattermost service를 override와 함께 재생성하는 동안 약 30~60초의 연결 끊김
또는 자동 재연결이 발생할 수 있다. 데이터베이스 service, Team, 채널, 멤버십,
메시지, 첨부파일, 로그인 데이터, NGINX, DNS와 인증서는 변경하지 않는다.

Mailer와 plugin worker는 Mattermost 메시지 commit 경로에서 SMTP를 실행하지 않는다.
Mailer 장애, SMTP 지연 또는 queue 장애는 채팅 작성 성공 여부와 분리한다.

### 7.2 롤백 순서

1. control state를 disabled로 변경
2. 새 이벤트 수집이 멈췄는지 확인
3. Mailer를 중지하되 queue 파일은 삭제하지 않음
4. 적용 전 플러그인 pair가 있었다면 검증된 복사본으로 복원하고, 없었다면 ThreadHub
   plugin pair만 제거
5. override 없이 기존 base Compose로 Mattermost service만 `--no-deps` 재생성
6. 기존 container health, plugin 상태와 채팅 기능 확인
7. 실패 queue와 notifier 데이터 루트는 자동 삭제하지 않고 격리

롤백은 기존 Compose 원본, 환경파일, PostgreSQL volume, Mattermost data 또는 queue를
삭제하지 않는다. 복구 정보가 불완전하면 자동 롤백을 추측하지 않고
`[ACTION REQUIRED]`로 중단한다.

## 8. 사용자 인터페이스와 산출물

기존 Mattermost 적용은 신규 설치 명령과 혼동되지 않는 별도 진입점을 제공한다.

```text
./deploy/scripts/existing-notifier-preflight.sh
./deploy/scripts/existing-notifier-setup.sh
./deploy/scripts/existing-notifier-status.sh
./deploy/scripts/existing-notifier-rollback.sh
```

대화형 설정이 필요한 값은 숨김 입력을 사용한다. 비대화형 실행에 안전한 비밀 입력이
없으면 exact resume 명령과 함께 exit code `20`으로 중단한다.

GitHub에는 다음 산출물을 포함한다.

- 기존 Mattermost notifier 적용 가이드
- 지원 매트릭스와 예상 영향
- 사전점검·설정·상태·롤백 명령
- 생성 파일과 비밀파일의 `.gitignore` 규칙
- 자동시험과 수동 인수시험 목록
- 신규 설치와 기존 설치를 구분한 README
- agent가 기존 서비스에 추측으로 적용하지 못하게 하는 `AGENTS.md` 계약

## 9. 시험 전략

### 9.1 정적·단위 시험

- shell syntax와 ShellCheck
- 구성 parser의 필수값, 중복값, 경로 traversal, symlink와 permission 거부
- Compose service 이름과 절대경로 검증
- unsupported OS, architecture, Mattermost version과 replica 거부
- 기존 notifier 충돌과 데이터 루트 중첩 거부
- 비밀값이 stdout, stderr, 상태파일과 생성 override 진단에 나타나지 않음
- 원본 Compose와 기존 환경파일 hash가 모든 성공·실패 경로에서 동일함

### 9.2 Compose fixture 시험

- 최소 지원 기존 Mattermost Compose fixture에 override 결합
- 기존 port, volume, environment, network와 healthcheck 보존
- Mattermost에 notifier environment, control mount와 internal network만 추가
- Mailer port 미노출과 security hardening 확인
- preflight 실패 시 파일·container·plugin state 변경 없음
- 동일 입력 재실행의 idempotency

### 9.3 실제 이미지 통합시험

Mattermost Team Edition 11.7.7과 PostgreSQL 18.4 임시 fixture에서 다음을 검증한다.

1. 기존 Team, 공개·비공개 채널, 사용자와 기준 메시지 생성
2. disabled 상태 적용 후 기준 데이터 유지
3. allowlist 공개·비공개 채널의 루트 글과 스레드 답글만 queue 생성
4. 비허용 채널, DM, 시스템 글, 작성자와 비멤버 제외
5. SMTP 장애 중 채팅 작성 성공과 queue 유지
6. 재시작 후 queue 복구와 중복 방지
7. `/_redirect/pl/{post_id}` 링크 생성
8. rollback 후 기존 Compose 모델과 기준 데이터 유지

### 9.4 수동 인수시험

- 실제 받은편지함 도착
- SPF와 DKIM `pass`
- 공개·비공개 채널의 실제 멤버만 수신
- 루트 글과 스레드 답글 링크가 로그인 후 원문으로 이동
- 채널에서 제거된 사용자의 링크 접근 거부
- 약 30~60초 재연결 후 웹·데스크톱·모바일 채팅 정상
- 전역 활성화 전 운영자 승인 기록

## 10. 완료 조건

다음 조건이 모두 충족되면 보완 작업을 완료한 것으로 판단한다.

1. 기존 신규 설치 자동·통합시험이 모두 통과한다.
2. 지원되는 기존 Mattermost fixture에서 사전점검, 설치, allowlist, 상태와 롤백이
   반복 가능하다.
3. 지원하지 않는 구성은 변경 없이 exit code `20`으로 중단한다.
4. 기존 Compose 원본·환경파일과 Mattermost 데이터 hash가 적용·롤백 전후 동일하다.
5. notifier 장애가 Mattermost 메시지 작성 성공을 방해하지 않는다.
6. 기존 Mattermost 적용 후 자동으로 `all_channels`가 활성화되지 않는다.
7. Git에 runtime 구성, SMTP 비밀값, HMAC, queue, plugin bundle 또는 생성 override가
   포함되지 않는다.
8. 설치 상태가 자동검사와 inbox/link/SPF/DKIM·권한·모바일 수동검사를 구분한다.
9. README와 agent 계약이 신규 설치와 기존 적용 절차를 혼동하지 않게 안내한다.
