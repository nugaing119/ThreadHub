# ThreadHub 채널 새 글 즉시 이메일 알림 설계

## 1. 문서 정보

| 항목 | 내용 |
| --- | --- |
| 문서 상태 | 승인됨 — 구현 계획 작성 전 설계 기준선 |
| 작성일 | 2026-08-27 |
| 대상 제품 | ThreadHub / Mattermost Team Edition 11.7.7 |
| 최초 적용 대상 | `https://threadhub-mentor.stillwhy.com` |
| 배포 형태 | OCI Compute VM 단일 노드 셀프호스팅 |
| 구현 상태 | 미구현 |

이 문서는 공개·비공개 채널에 새 글이나 스레드 답글이 등록될 때 실제 채널 멤버에게 즉시 일반 안내 이메일을 발송하는 기능의 확정 설계다. 구현 계획, 코드 변경, 라이브 배포는 이 문서에 대한 최종 검토 이후 별도로 진행한다.

## 2. 배경과 목표

ThreadHub MVP는 모바일 앱을 지원하지만 상업적 셀프호스팅 환경에서 무료 TPNS를 사용하지 않기 때문에 모바일 푸시를 비활성화한다. Mattermost 기본 이메일 알림은 사용자 상태·개인 설정·멘션 여부에 따라 발송 시점과 대상이 달라져, 모든 새 채널 글을 실제 채널 멤버에게 즉시 알리는 요구사항을 충족하지 않는다.

이 설계의 목표는 다음과 같다.

- 공개·비공개 채널의 새 루트 글과 스레드 답글을 감지한다.
- 글 작성자를 제외한 현재 채널 멤버에게 개별 이메일을 발송한다.
- 이메일과 알림 시스템에 메시지 본문, 채널명, Team명, 작성자명을 노출하지 않는다.
- SMTP 장애가 Mattermost의 메시지 작성 성공 여부나 응답 시간에 영향을 주지 않게 한다.
- 프로젝트별 OCI Email Delivery SMTP 자격 증명과 Approved Sender를 사용하고 Mattermost 유료 기능을 활성화하지 않는다.
- 저장소에는 재사용 가능한 기능으로 포함하며, 신규 설치에서는 인수 조건을 통과한 뒤 기본 활성화한다.

## 3. 비목표

다음 항목은 이번 기능에 포함하지 않는다.

- iOS·Android 푸시 알림
- DM 및 그룹 DM 이메일 알림
- 메시지 수정, 삭제, 반응 추가 알림
- 입장, 퇴장, 채널 생성 등 Mattermost 시스템 글 알림
- 확인할 때까지 반복하는 Persistent Notification
- 예약 메시지 또는 메시지 Reminder 대체
- 이메일 내 메시지 본문, 채널명, Team명 또는 작성자명 표시
- 사용자별 알림 주기나 Digest 설정
- 외부 SaaS 스케줄러 또는 GitHub Actions 사용
- Mattermost 소스 코드나 라이선스 검사 변경
- 설치 프로그램이 사용자 승인 없이 OCI IAM 사용자, 그룹, 정책, SMTP 자격 증명, DNS 또는 네트워크 리소스를 자동 생성하는 기능

## 4. 확정 동작

### 4.1 알림 대상 이벤트

| 이벤트 | 발송 여부 |
| --- | --- |
| 공개 채널의 새 루트 글 | 발송 |
| 비공개 채널의 새 루트 글 | 발송 |
| 공개 채널의 스레드 답글 | 발송 |
| 비공개 채널의 스레드 답글 | 발송 |
| 사용자 작성 글 | 발송 |
| Webhook 또는 봇이 작성한 일반 글 | 발송 |
| 1:1 DM | 미발송 |
| 그룹 DM | 미발송 |
| 메시지 수정·삭제 | 미발송 |
| 이모지 반응 | 미발송 |
| 시스템 글 | 미발송 |

Webhook 및 봇이 작성한 일반 글은 향후 연동 메시지가 채널 알림에서 누락되지 않게 포함한다. 단, 봇 계정 자체는 수신자에서 제외한다.

### 4.2 수신자 계산

비동기 워커가 이벤트를 처리하면서 Mattermost에서 조회한 **해당 채널의 현재 실제 멤버**를 수신 후보로 삼는다. 정상 상태에서는 글 등록 후 수 초 안에 조회한다. Team 멤버라는 이유만으로는 수신하지 않는다.

다음 조건을 모두 충족하는 사용자만 수신한다.

- 수신자 계산 시 해당 채널의 멤버다.
- 글 작성자가 아니다.
- 비활성화 또는 삭제된 계정이 아니다.
- 봇 계정이 아니다.
- 이메일 주소가 존재한다.
- 이메일 확인이 완료된 계정이다.

스레드 답글도 스레드 참여자만이 아니라 위 조건을 충족하는 채널 멤버 전체에게 발송한다. 공개 채널이라도 채널에 가입하지 않은 Team 멤버에게는 발송하지 않는다.

### 4.3 이메일 내용

각 수신자에게 한 통씩 별도로 발송한다. To/Cc/Bcc로 여러 수신자를 묶지 않는다.

제목:

```text
[ThreadHub] 새 메시지가 등록되었습니다
```

본문:

```text
ThreadHub에 새 메시지가 등록되었습니다.
로그인하여 확인해 주세요.

[메시지 확인]
```

`메시지 확인` 링크는 다음 형식을 사용한다.

```text
https://{threadhub-domain}/_redirect/pl/{post_id}
```

Mattermost v11.7.7의 팀 독립 permalink 리디렉션 경로를 사용한다. 루트의 `/pl/{post_id}`는 `pl`을 Team 이름으로 해석하므로 사용하지 않으며, 이메일에 Team 이름을 포함하지 않은 채 Mattermost가 게시물의 실제 Team과 채널을 확인해 이동하도록 한다.

최초 적용 대상에서는 `threadhub-domain`이 `threadhub-mentor.stillwhy.com`이다. 다른 프로젝트는 자신의 `THREADHUB_DOMAIN`으로 링크를 생성한다.

Mattermost가 링크 접근 시 로그인과 채널 권한을 다시 검증한다. 채널에서 제거된 사용자는 이메일 링크를 가지고 있어도 해당 글을 열람할 수 없어야 한다.

### 4.4 정보 최소화

다음 정보는 이메일 제목·본문, 플러그인 전송 payload, Mailer 로그 및 영구 큐에 포함하지 않는다.

- 메시지 본문 및 첨부파일 정보
- 채널명 및 채널 목적
- Team명
- 작성자 이름, 사용자명 및 이메일

수신자 이메일은 SMTP 발송에 필요한 동안만 Mailer 큐에 보관하고 성공 직후 제거한다. 운영 통계를 위해 남기는 레코드는 가명화된 사용자 식별자, 이벤트 식별자, 상태, 시각 및 오류 분류만 포함한다.

## 5. 현재 설정과 변경 경계

다음 기존 설정은 그대로 유지한다.

```text
MM_EMAILSETTINGS_SENDEMAILNOTIFICATIONS=false
MM_EMAILSETTINGS_SENDPUSHNOTIFICATIONS=false
MM_SERVICESETTINGS_ENABLEINCOMINGWEBHOOKS=false
MM_SERVICESETTINGS_ENABLEOUTGOINGWEBHOOKS=false
MM_SERVICESETTINGS_ENABLEUSERACCESSTOKENS=false
MM_SERVICESETTINGS_ENABLEBOTACCOUNTCREATION=false
```

Mattermost 기본 일반 메시지 이메일 알림은 중복 발송과 내용 노출 가능성을 피하기 위해 활성화하지 않는다. 모바일 푸시도 계속 비활성화한다. 라이브 Webhook과 봇 기능은 이번 구현을 시험하기 위해 활성화하지 않는다.

플러그인 관련 설정은 다음 원칙으로 변경한다.

- 플러그인 실행 기능만 활성화한다.
- 사용자 플러그인 업로드는 비활성 상태를 유지한다.
- Marketplace 및 원격 Marketplace는 비활성 상태를 유지한다.
- 사전 패키지 플러그인 자동 설치는 비활성 상태를 유지한다.
- 검토·고정된 ThreadHub 알림 플러그인 한 개만 관리자가 설치한다.

## 6. 아키텍처

```text
사용자·Webhook·봇
        │
        │ 새 채널 글 또는 스레드 답글
        ▼
Mattermost Team Edition
        │
        │ MessageHasBeenPosted 서버 플러그인 훅
        ▼
ThreadHub Notifier Plugin
        │  1. 최소 이벤트를 플러그인 KV에 기록
        │  2. 채널·사용자 상태 조회 및 수신자 계산
        │  3. HMAC 서명된 최소 payload 전송
        ▼
Docker 내부 전용 네트워크
        │
        ▼
ThreadHub Mailer Container
        │  SQLite 내구성 큐
        │  개별 이메일 생성 및 재시도
        ▼
OCI Email Delivery SMTP :587 STARTTLS
        │
        ▼
채널 멤버 이메일 계정
```

### 6.1 Mattermost 서버 플러그인

플러그인은 Mattermost 공식 서버 플러그인 API와 `MessageHasBeenPosted` 훅을 사용한다. 메시지 작성 요청 경로에서 SMTP나 외부 네트워크 작업을 수행하지 않는다.

훅 처리 순서는 다음과 같다.

1. 이벤트가 새 글인지 확인한다.
2. DM, 그룹 DM, 시스템 글과 지원하지 않는 이벤트를 제외한다.
3. `{post_id, channel_id, author_user_id, create_at}`만 플러그인 KV에 기록한다.
4. 즉시 훅 처리를 반환한다.
5. 별도 워커가 KV 이벤트를 읽어 채널 유형과 현재 채널 멤버를 조회한다.
6. 확정 수신자를 계산해 Mailer로 최소 payload를 전송한다.
7. Mailer가 내구성 큐 저장을 확인한 뒤에만 해당 KV 이벤트를 제거한다.

플러그인은 Mattermost 서버 내부 데이터에 폭넓게 접근할 수 있으므로 코드 크기와 권한 사용을 최소화하고, 빌드 산출물 버전과 SHA-256을 기록한다.

### 6.2 Mailer 서비스

Mailer는 Mattermost와 분리된 전용 Docker 컨테이너로 실행한다.

- 호스트와 인터넷에 포트를 공개하지 않는다.
- Mattermost 플러그인만 접근 가능한 Docker 내부 네트워크를 사용한다.
- 수신 이벤트를 SQLite 트랜잭션으로 저장한 뒤 ACK한다.
- SMTP 발송은 큐 워커가 비동기로 처리한다.
- 신규 설치는 해당 프로젝트 전용 OCI SMTP 자격 증명을 사용한다.
- 기존 인스턴스는 현재 자격 증명이 프로젝트 전용인지 확인하고, 공용 또는 개인 관리자 자격 증명이면 전용 자격 증명으로 교체한다.
- 발신 주소는 해당 프로젝트의 정확한 주소로 등록한 OCI Approved Sender를 사용한다.
- SMTP는 587 포트와 STARTTLS 인증서 검증을 사용하며 평문 폴백을 허용하지 않는다.
- 컨테이너 재생성 뒤에도 큐가 유지되도록 전용 영구 경로를 마운트한다.

### 6.3 플러그인–Mailer payload

개념적 payload는 다음 정보만 포함한다.

```json
{
  "event_id": "opaque-event-id",
  "post_id": "mattermost-post-id",
  "permalink": "https://project-threadhub.example.com/_redirect/pl/mattermost-post-id",
  "occurred_at": 1787790000000,
  "recipients": [
    {
      "user_id": "mattermost-user-id",
      "email": "recipient@example.com"
    }
  ]
}
```

실제 요청에는 HMAC 서명, timestamp 및 nonce를 추가한다. 메시지, 채널, Team 또는 작성자 정보는 넣지 않는다.

### 6.4 내부 요청 인증

플러그인과 Mailer 사이 요청은 다음 방식으로 보호한다.

- 로컬 `.env`에서 생성한 전용 HMAC 비밀값을 사용한다.
- 요청 본문과 timestamp·nonce를 함께 서명한다.
- Mailer는 서명, 허용 시간 오차 및 nonce 재사용 여부를 검증한다.
- 유효하지 않은 서명, 오래된 timestamp 및 replay 요청은 거부한다.
- HMAC 비밀값은 출력, 로그, 이미지 또는 Git에 포함하지 않는다.
- `.env`는 서버 관리자만 읽을 수 있게 유지한다.

### 6.5 프로젝트별 Email Delivery 권한 경계

같은 발신 도메인과 OCI Email Delivery 리전을 사용하는 프로젝트는 Email Domain, DKIM, SPF 및 SMTP endpoint를 공유한다. 다음 리소스와 비밀값은 프로젝트별로 분리한다.

- 고유 ThreadHub hostname과 DNS A 레코드
- 전용 IAM 사용자
- 전용 IAM 그룹
- 전용 SMTP Credential
- 정확한 이메일 주소로 등록한 Approved Sender
- 해당 Approved Sender만 사용할 수 있는 조건부 IAM 정책
- `deploy/.env`
- 플러그인–Mailer HMAC 비밀값
- Mailer SQLite 큐

프로젝트별 SMTP 사용자는 전용 IAM 그룹에만 포함한다. 발송 정책은 광범위한 `email-family`가 아니라 `approved-senders`의 `use` 권한만 부여하고, `target.approved-sender.id`로 해당 프로젝트의 Approved Sender OCID를 제한한다.

개념적 정책 형태는 다음과 같다. 실제 identity domain, 그룹, Compartment 및 OCID는 프로젝트 준비 단계에서 확인한다.

```text
Allow group '<identity-domain>'/'<project-smtp-group>'
to use approved-senders
in compartment <project-compartment>
where target.approved-sender.id = '<project-approved-sender-ocid>'
```

다음과 같은 도메인 단위 Approved Sender는 프로젝트별 주소 격리를 약화하므로 사용하지 않는다.

```text
@stillwhy.com
```

대신 프로젝트마다 정확한 주소를 등록한다.

```text
threadhub-project-a@stillwhy.com
threadhub-project-b@stillwhy.com
```

OCI IAM 허용 정책은 다른 그룹과 상위 범위 정책을 통해 누적될 수 있다. 따라서 전용 사용자의 그룹 멤버십과 적용되는 모든 정책을 확인해 tenancy 또는 Compartment 범위의 광범위한 `use email-family`, `manage email-family`, `use approved-senders` 권한이 추가로 부여되지 않았음을 검증한다.

프로젝트별 사용자·Credential·그룹·정책은 독립적인 교체와 폐기를 가능하게 한다. Email Domain·DKIM·SPF 공유는 발신 도메인 인증을 공동 운영한다는 뜻이며, 프로젝트별 Approved Sender 사용 권한은 위 조건부 정책에서 별도로 강제한다.

## 7. 내구성, 중복 방지 및 장애 처리

### 7.1 전달 의미

전체 파이프라인은 **at-least-once** 전달을 사용한다. 정상 처리 중복은 Mailer의 고유키로 차단하지만 SMTP 서버가 메일을 수락한 직후 상태 기록 전에 프로세스가 종료되면 드물게 중복 이메일이 생길 수 있다. 외부 SMTP의 원자적 전달 확인이 없으므로 exactly-once는 보장하지 않는다.

Mailer 큐는 `(post_id, user_id)`를 고유키로 사용해 동일 사용자에 대한 일반적인 중복 이벤트를 한 건으로 유지한다. 이메일 `Message-ID`도 원문 식별자를 노출하지 않는 결정적 해시로 생성해 메일 클라이언트의 중복 판단을 돕는다.

### 7.2 재시도 정책

발송 시도 시점은 최초 시도를 포함해 다음과 같다.

```text
즉시 → 30초 → 2분 → 10분 → 30분 → 2시간 → 6시간 → 24시간
```

- 네트워크 오류, timeout, SMTP 4xx 등 일시적 오류는 재시도한다.
- 잘못된 주소 등 영구 오류와 SMTP 5xx는 실패로 분류한다.
- 24시간 재시도 후에도 성공하지 못한 항목은 `failed`로 두고 관리자 수동 재시도 대상으로 표시한다.
- 한 수신자의 실패가 다른 수신자의 발송을 막지 않는다.
- Mailer 장애나 SMTP 지연이 Mattermost 메시지 작성 성공을 취소하거나 지연시키지 않는다.

### 7.3 성능 목표

- 플러그인 이벤트 내구성 기록: 글 등록 후 3초 이내
- 정상 상태의 최초 SMTP 시도: 글 등록 후 10초 이내
- 전체 수신자 완료 시간: OCI Email Delivery의 실제 발송 한도에 따름
- 예시: 분당 10건 한도에서 20명에게 발송하면 약 2분이 필요할 수 있음

출시 전에 현재 OCI tenancy의 Email Delivery 발송 속도와 일일 제한을 읽기 전용으로 확인하고 워커 동시성과 속도를 그 이하로 설정한다.

### 7.4 데이터 보존

- 대기·재시도 중인 수신자 이메일: SMTP 처리에 필요한 기간만 보존
- 성공한 항목의 이메일: 성공 기록 직후 제거
- 가명화된 성공·실패 메타데이터: 7일 보존 후 삭제
- 로그: 메시지·채널·Team·작성자·수신자 이메일을 기록하지 않음

SQLite 파일은 OCI 암호화 Boot Volume 위의 관리자 제한 경로에 저장한다. 이는 저장 볼륨 암호화와 파일 권한에 의존하며, SQLite 자체 암호화를 주장하지 않는다.

## 8. 활성화 정책

### 8.1 저장소 기본값

새 ThreadHub 설치에서는 이 기능의 목표 상태를 기본 활성화로 둔다.

```text
NOTIFIER_ENABLED=true
NOTIFIER_MODE=all_channels
NOTIFIER_CHANNEL_IDS=
```

설치 마법사는 외부 준비와 자동 인수 조건이 끝나기 전에는 실제 이벤트 전달을 열지 않는다. 모든 조건을 통과한 시각을 `NOTIFIER_ACTIVATED_AT`으로 기록한 뒤 공개·비공개 채널 전역 알림을 시작한다. 이 시각보다 오래된 이벤트는 처리하지 않는다.

알림이 필요 없는 별도 설치는 운영자가 `NOTIFIER_ENABLED=false`를 명시해 비활성화할 수 있다. 기본 설치 경로와 `[READY]` 기준은 활성 상태다.

### 8.2 신규 설치 활성화 순서

1. 새 Ubuntu 24.04 AMD64 VM, 고유 hostname 및 예약 공인 IP를 준비한다.
2. 기존 DNS Zone에 다른 RRset을 덮어쓰지 않고 프로젝트 hostname의 A 레코드를 추가한다.
3. 같은 발신 도메인과 리전을 공유하는 Email Domain·DKIM·SPF 상태를 확인한다.
4. 명시적 승인을 받은 뒤 프로젝트 전용 IAM 사용자·그룹·SMTP Credential·Approved Sender·조건부 정책을 준비한다.
5. 설치 마법사에서 프로젝트 전용 SMTP username과 password를 숨김 입력하고 시험 메일 수신 주소를 입력한다.
6. 설치 마법사가 프로젝트 전용 HMAC 비밀값을 생성하고 출력하지 않은 채 `.env`에 저장한다.
7. Mattermost, PostgreSQL, 알림 플러그인 및 Mailer를 배포한다.
8. 자동 인수 조건을 검증한다.
9. 활성화 시각을 기록하고 `NOTIFIER_ENABLED=true`, `NOTIFIER_MODE=all_channels`로 전환한다.
10. `[READY]`를 출력한 뒤 수동 이메일·권한·CJK·모바일 인수시험을 안내한다.

자동 `[READY]` 조건은 다음과 같다.

- Mattermost, PostgreSQL 및 Mailer health 정상
- 검토된 알림 플러그인 설치·활성 상태
- Mailer 포트가 호스트와 인터넷에 노출되지 않음
- OCI SMTP 587 STARTTLS 연결, 인증서 검증 및 AUTH 성공
- 프로젝트 Approved Sender를 사용한 일반 시험 이메일을 OCI가 접수
- 활성화 시각 이전 이벤트가 Mailer 큐에 없음
- 알림 목표 상태가 `enabled/all_channels`임

자동 검사는 OCI가 시험 이메일을 접수한 사실까지만 판정한다. 실제 받은편지함 도착, 링크, SPF 및 DKIM `pass`는 수동 인수시험으로 별도 확인한다. OCI 리소스나 SMTP 설정이 준비되지 않았으면 마법사는 `[READY]`를 출력하지 않고 `[ACTION REQUIRED]`와 안전한 재개 명령을 제공한다. 기존 `.env`와 영구 데이터는 보존한다.

시험 메일 수신 주소는 설치 중 한 번만 사용하고 `.env`에 저장하지 않는다. 대화형 설치에서는 Let's Encrypt 연락 이메일을 기본값으로 제안하되 운영자가 다른 관리 이메일을 입력할 수 있게 한다. 비대화형 설치는 승인된 일회성 시험 주소를 안전한 런타임 입력으로 제공하지 못하면 수동 시험 단계로 중단한다.

설치 마법사는 OCI IAM, SMTP Credential, Approved Sender 또는 DNS를 사용자 승인 없이 생성하지 않는다. 비대화형 환경에서 SMTP 비밀값을 안전하게 입력할 수 없으면 설치 계약에 따라 중단한다.

### 8.3 기존 라이브 인스턴스 단계적 활성화

`threadhub-mentor.stillwhy.com`에서는 다음 순서를 지킨다.

1. 현재 IAM 사용자·SMTP Credential·Approved Sender가 이 프로젝트 전용인지 확인한다.
2. 전용 IAM 그룹과 Approved Sender OCID 조건 정책을 적용하고 교차 발신 거부를 검증한다.
3. Mailer를 `NOTIFIER_ENABLED=false`로 배포한다.
4. 플러그인을 설치하되 기존 채널에 전역 발송하지 않는다.
5. 관리자 2명만 있는 임시 Team에 공개·비공개 시험 채널을 만든다.
6. `NOTIFIER_MODE=allowlist`와 시험 채널 ID만 설정한다.
7. `NOTIFIER_ACTIVATED_AT`을 시험 시작 시각으로 설정해 이전 이벤트 발송을 막는다.
8. 승인 시험을 모두 통과한다.
9. 운영자의 명시적 승인 후 공개·비공개 채널 전역 모드로 전환한다.

과거 글은 발송하지 않는다. 활성화 시각 이후 생성된 이벤트만 처리한다.

## 9. 배포 및 롤백

### 9.1 배포 전 조건

- 로컬 빌드와 자동화 시험 통과
- 플러그인과 Mailer 이미지·바이너리의 고정 버전 및 SHA-256 기록
- Docker Compose 최종 검증 시 비밀값을 출력하지 않는 방식 사용
- Mattermost 데이터베이스, 설정 및 파일의 수동 안전 복사본 확보
- Mailer 영구 경로 생성과 권한 확인
- 프로젝트 전용 IAM 사용자·그룹·SMTP Credential·Approved Sender와 조건부 정책 확인
- 다른 프로젝트의 Approved Sender를 사용한 교차 발신이 거부되는지 확인
- 현재 SMTP 발송 한도 확인
- 운영자에게 예상되는 30~60초 재연결 가능성 안내

### 9.2 예상 영향

플러그인 설정 반영을 위한 Mattermost 컨테이너 재생성 중 사용자에게 약 30~60초의 연결 끊김이나 자동 재연결이 발생할 수 있다. 로그인 세션, 채널 메시지, 첨부파일 및 PostgreSQL 데이터는 유지된다.

다음 구성은 변경하지 않는다.

- NGINX 및 TLS 인증서
- DNS
- OCI NSG와 Security List
- SSH 허용 IP
- PostgreSQL 데이터 경로
- 기존 Team, 채널 및 멤버십

### 9.3 롤백

1. Mailer 발송을 비활성화한다.
2. ThreadHub 알림 플러그인을 비활성화한다.
3. 기존 Docker Compose 구성을 복원해 Mattermost를 재생성한다.
4. Mattermost 채팅, 데이터베이스 및 첨부파일이 정상인지 확인한다.
5. 남은 큐는 발송하지 않고 격리해 수신자와 원인을 확인한다.

롤백은 PostgreSQL, 메시지 또는 첨부파일을 삭제하지 않는다.

### 9.4 자격 증명 교체

SMTP Credential은 프로젝트별로 독립 교체한다.

1. 같은 프로젝트 IAM 사용자에 두 번째 SMTP Credential을 생성한다.
2. 해당 프로젝트의 `deploy/.env`만 새 username과 password로 변경한다.
3. Mattermost와 Mailer를 새 자격 증명으로 재생성한다.
4. 초대·이메일 확인·비밀번호 재설정 메일과 새 글 알림을 시험한다.
5. 성공을 확인한 뒤 이전 SMTP Credential을 삭제한다.

이 과정에서 다른 프로젝트의 VM, `.env`, Approved Sender, SMTP Credential 및 큐를 변경하지 않는다.

### 9.5 프로젝트 종료

프로젝트별 자원 회수 순서는 다음과 같다.

1. `NOTIFIER_ENABLED=false`로 새 알림 생성을 중지한다.
2. 정상 대기 큐를 최대 10분 동안 처리한다.
3. 남은 실패·재시도 큐를 취소하고 수신자 이메일을 제거한다.
4. 추가 이메일이 발송되지 않는지 확인한다.
5. 프로젝트 SMTP Credential을 삭제한다.
6. 프로젝트 Approved Sender를 삭제한다.
7. IAM 사용자를 전용 그룹에서 제거한다.
8. 전용 IAM 사용자를 비활성화한 뒤 삭제한다.
9. Approved Sender 조건부 정책을 삭제한다.
10. 전용 IAM 그룹을 삭제한다.
11. 프로젝트 DNS A 레코드만 제거한다.
12. 보존정책에 따라 VM과 Boot Volume을 유지하거나 삭제한다.
13. 남아 있는 다른 프로젝트에서 SMTP 발송이 정상인지 확인한다.

Email Domain, DKIM, SPF 및 공용 DNS Zone은 같은 발신 도메인을 사용하는 프로젝트가 하나라도 남아 있으면 유지한다. 마지막 프로젝트 종료 후에도 공유 자원 삭제는 일반 프로젝트 종료에 포함하지 않으며 별도의 영향 분석과 명시적 승인을 받는다.

IAM 사용자·그룹·정책·SMTP Credential은 리전 비종속 또는 tenancy 범위에 영향을 줄 수 있으므로 생성·교체·삭제마다 명시적 승인을 받는다. DNS, Approved Sender 및 Email Delivery 변경에는 대상 Compartment와 리전을 기록한다.

## 10. 시험 계획

### 10.1 기능 시험

| ID | 시험 | 기대 결과 |
| --- | --- | --- |
| NF-FN-01 | 공개 채널 새 루트 글 | 작성자를 제외한 현재 채널 멤버에게 발송 |
| NF-FN-02 | 비공개 채널 새 루트 글 | 작성자를 제외한 현재 비공개 채널 멤버에게만 발송 |
| NF-FN-03 | 공개 채널 스레드 답글 | 작성자를 제외한 현재 채널 멤버에게 발송 |
| NF-FN-04 | 비공개 채널 스레드 답글 | 작성자를 제외한 현재 비공개 채널 멤버에게만 발송 |
| NF-FN-05 | Team 멤버지만 공개 채널 미가입 사용자 | 미발송 |
| NF-FN-06 | 비활성·삭제 사용자 | 미발송 |
| NF-FN-07 | 봇 계정 수신자 | 미발송 |
| NF-FN-08 | DM 및 그룹 DM | 미발송 |
| NF-FN-09 | 수정·삭제·반응 | 미발송 |
| NF-FN-10 | 시스템 글 | 미발송 |
| NF-FN-11 | Webhook·봇 작성 일반 글 | 채널 멤버에게 발송 |
| NF-FN-12 | 이메일 링크 클릭 | 권한 있는 사용자는 원문으로 이동 |
| NF-FN-13 | 채널에서 제거된 사용자의 링크 클릭 | Mattermost에서 접근 거부 |

라이브 Webhook·봇 기능을 시험 목적으로 활성화하지 않는다. Webhook·봇 이벤트는 로컬 통합 시험으로 검증한다.

### 10.2 개인정보 및 보안 시험

| ID | 시험 | 기대 결과 |
| --- | --- | --- |
| NF-SEC-01 | 이메일 원문 검사 | 본문·채널·Team·작성자 정보 없음 |
| NF-SEC-02 | 복수 수신자 발송 | 각 이메일에 한 수신자만 노출 |
| NF-SEC-03 | 로그와 SQLite 검사 | 허용된 최소 데이터만 존재 |
| NF-SEC-04 | 잘못된 HMAC | 요청 거부 |
| NF-SEC-05 | 오래된 timestamp | 요청 거부 |
| NF-SEC-06 | nonce replay | 요청 거부 |
| NF-SEC-07 | 외부에서 Mailer 포트 접근 | 연결 불가 |
| NF-SEC-08 | Mattermost 플러그인 설정 | 업로드·Marketplace·자동 설치 비활성 |
| NF-SEC-09 | 저장소와 이미지 비밀 검사 | SMTP·HMAC 비밀값 없음 |

### 10.3 내구성과 장애 시험

| ID | 시험 | 기대 결과 |
| --- | --- | --- |
| NF-REL-01 | Mailer 중지 중 새 글 후 재시작 | 보존된 이벤트가 재개·발송됨 |
| NF-REL-02 | SMTP 일시 장애 후 복구 | 정책에 따라 재시도 후 발송됨 |
| NF-REL-03 | 동일 이벤트 중복 제출 | 정상 상황에서 사용자당 한 통 |
| NF-REL-04 | Mailer 컨테이너 재생성 | SQLite 큐가 유지됨 |
| NF-REL-05 | Mattermost 컨테이너 재생성 | 플러그인 KV 이벤트가 유지됨 |
| NF-REL-06 | VM 재부팅 | 큐 워커가 자동 시작하고 처리를 재개함 |
| NF-REL-07 | 영구 주소 오류 | 다른 수신자에 영향 없이 실패 처리 |
| NF-REL-08 | 발송 성공 | 큐의 이메일 주소가 즉시 제거됨 |
| NF-REL-09 | 롤백 실행 | 채팅 데이터 유지, 추가 이메일 중단 |

### 10.4 신규 설치와 프로젝트 격리 시험

| ID | 시험 | 기대 결과 |
| --- | --- | --- |
| NF-INS-01 | 신규 설치 기본 설정 확인 | `enabled/all_channels`가 목표 상태 |
| NF-INS-02 | SMTP 외부 준비 없이 설치 | `[READY]` 없이 `[ACTION REQUIRED]` 반환 |
| NF-INS-03 | 올바른 프로젝트 SMTP로 설치 | STARTTLS·AUTH 및 OCI 접수 성공 |
| NF-INS-04 | 신규 설치 완료 후 첫 공개·비공개 글 | 활성화 시각 이후 글만 정상 발송 |
| NF-INS-05 | 자동 설치 결과와 실제 받은편지함 비교 | 자동 접수와 수동 수신·SPF·DKIM 결과가 분리 보고됨 |
| NF-IAM-01 | Credential A + Sender A | 발송 성공 |
| NF-IAM-02 | Credential A + Sender B | OCI 권한 거부 |
| NF-IAM-03 | Credential B + Sender B | 발송 성공 |
| NF-IAM-04 | Credential B + Sender A | OCI 권한 거부 |
| NF-IAM-05 | Credential A 삭제 후 Project B 발송 | Project B는 정상 성공 |
| NF-IAM-06 | Project A 종료 후 공유 DNS 검사 | Email Domain·DKIM·SPF 변경 없음 |
| NF-IAM-07 | Project A IAM 사용자 그룹·정책 감사 | 전용 조건부 정책 외 광범위한 이메일 권한 없음 |

## 11. 출시 판정

### 11.1 Go 조건

- 대상 및 제외 이벤트 시험이 모두 통과한다.
- 공개·비공개 채널 수신자 경계가 정확하다.
- 이메일·로그·큐에 메시지, 채널, Team 및 작성자 정보가 없다.
- 정상 상태에서 최초 SMTP 시도가 10초 이내 시작된다.
- Mattermost 메시지 작성 성능과 성공 여부에 의미 있는 영향이 없다.
- Mailer·Mattermost·VM 재시작 후 대기 큐가 복구된다.
- 신규 설치가 알림 활성 상태로 `[READY]`에 도달한다.
- 프로젝트 Credential은 자기 Approved Sender만 사용할 수 있다.
- 프로젝트 자격 증명 교체·폐기가 다른 프로젝트 발송에 영향을 주지 않는다.
- 관리자 수신 이메일과 원문 링크를 수동으로 확인한다.
- SPF와 DKIM `pass`를 수동으로 확인한다.
- 롤백 절차를 시험한다.

### 11.2 No-Go 및 즉시 롤백 조건

- 채널 멤버가 아닌 사용자나 잘못된 사용자에게 이메일이 발송된다.
- 비공개 채널 또는 DM의 정보가 잘못된 대상에게 노출된다.
- 이메일에 메시지 본문, 채널명, Team명 또는 작성자명이 포함된다.
- 같은 이벤트에 대한 대량 중복 발송이 발생한다.
- 다른 프로젝트의 Credential로 현재 프로젝트 Approved Sender 발송이 성공한다.
- SMTP 또는 알림 기능이 준비되지 않았는데 신규 설치가 `[READY]`를 출력한다.
- 플러그인 또는 Mailer 장애 때문에 채팅 글 등록이 실패하거나 현저히 지연된다.
- SMTP 자격 증명, HMAC 비밀값 또는 수신자 이메일이 로그에 노출된다.

## 12. 운영 관측 항목

`deploy/scripts/install-status.sh`와 운영 문서에 다음 상태를 추가한다.

- ThreadHub 알림 플러그인 설치·활성 상태
- Mailer 컨테이너 health
- 대기·성공·실패 건수
- 가장 오래된 대기 항목의 경과 시간
- 마지막 SMTP 성공 시각
- 마지막 실패 분류와 오류 코드
- 알림 기능 활성 모드와 활성화 시각
- 프로젝트 전용 SMTP 자격 증명 사용 여부
- Approved Sender OCID 조건 정책의 외부 수동 검증 기록

상태 출력에는 메시지, 채널, Team, 작성자, 수신자 이메일 및 비밀값을 포함하지 않는다.

## 13. 저장소 반영 범위

구현 단계에서는 다음 구조를 기준으로 한다.

```text
notifier/
├── plugin/
│   ├── server/
│   ├── plugin.json
│   └── tests/
└── mailer/
    ├── src/
    ├── migrations/
    └── tests/

deploy/
├── docker-compose.yml
├── .env.example
├── scripts/
│   ├── setup-wizard.sh
│   └── install-status.sh
└── docs/
    ├── quick-install.md
    ├── oci-email-delivery.md
    ├── setup.md
    ├── admin-guide.md
    ├── operations-checklist.md
    ├── project-close.md
    └── test-plan.md
```

실제 구현 언어, 라이브러리 버전, 빌드 명령, SQLite schema 및 Compose health check는 후속 구현 계획에서 고정한다.

## 14. 라이선스와 비용

Mattermost Team Edition의 오픈소스 서버와 공식 플러그인 API를 사용하고, 독립적인 ThreadHub 플러그인과 Mailer를 추가하는 방식이다. Professional·Enterprise 기능을 활성화하거나 라이선스 검사를 변경하지 않는다. Mattermost 기본 이메일 알림은 계속 비활성화한다.

OCI Email Delivery는 수신자별 이메일을 각각 한 건으로 계산한다. 공식 공개 가격 기준 월 3,000건까지 무료 구간이 있고 초과분은 1,000건당 USD 0.085다. 실제 청구는 tenancy, 리전, 서비스 정책 및 당시 가격에 따라 달라질 수 있으므로 배포 전 OCI Console에서 다시 확인한다.

프로젝트별 IAM 사용자·SMTP Credential·Approved Sender 분리는 프로젝트마다 별도의 무료 발송 구간을 생성하지 않는다. 발송량, quota 및 비용은 OCI tenancy·리전·Compartment 기준을 확인하고 전체 프로젝트 합계로 관리한다.

예시:

```text
하루 20개 채널 글 × 글당 20명 수신 × 30일 = 월 12,000건
무료 3,000건 제외 = 9,000건
예상 초과 비용 = 약 USD 0.77/월
```

작성자는 제외되므로 실제 수신자 수에 따라 달라진다.

## 15. 잔여 위험과 수용 기준

| 위험 | 완화 및 수용 기준 |
| --- | --- |
| SMTP 수락 직후 Mailer 장애에 따른 드문 중복 | 고유키와 결정적 Message-ID 적용, exactly-once 미보장 문서화 |
| 채널 멤버 수 증가에 따른 이메일 증가 | OCI 발송 한도 이하 rate limit, 큐 적체 관측 |
| 플러그인의 광범위한 서버 접근 | 최소 코드, 고정 빌드, SHA-256 기록, 사용자 업로드 차단 |
| SQLite 파일 손상 또는 Boot Volume 장애 | 컨테이너와 분리된 영구 경로, 운영 백업 절차에 포함 |
| 알림 폭주 | 사용자당 이벤트 고유키, 워커 rate limit, 즉시 비활성화 스위치 |
| 공개 채널 멤버십 오해 | Team 멤버가 아닌 실제 채널 멤버만 수신한다는 운영 안내 |
| 수신자 계산 후 발송 전 멤버십 변경 | 이메일은 일반 안내만 포함하고 원문 접근은 Mattermost가 다시 검사함; 정상 처리 지연을 최소화하고 이 시간차를 운영 제약으로 문서화 |
| SMTP 사용자에게 다른 광범위한 허용 정책이 누적됨 | 전용 그룹만 사용하고 사용자 그룹 멤버십·상위 정책을 감사하며 교차 발신 거부 시험 수행 |
| 공유 발신 도메인의 평판 영향 | 프로젝트별 Credential·Sender·rate limit으로 제한하고 bounce·complaint 발생 프로젝트를 즉시 중지 |
| 프로젝트 종료 중 공유 DKIM·SPF 오삭제 | 공유 자원은 일반 종료 대상에서 제외하고 마지막 프로젝트 이후에도 별도 명시적 승인 요구 |
| 비용 예측 오차 | 활성화 전 현재 채널 인원과 OCI 가격·한도 재확인 |

현재 2 OCPU·16GB VM은 이 규모의 플러그인, SQLite 큐 및 단일 Mailer 워커를 수용할 여유가 있다고 판단한다. 실제 리소스 사용량은 단계적 시험에서 확인한다.

## 16. 근거 자료

- [Mattermost server plugin API reference](https://developers.mattermost.com/integrate/reference/server/server-reference/)
- [Mattermost webhooks documentation](https://developers.mattermost.com/integrate/webhooks/)
- [Mattermost plans](https://docs.mattermost.com/product-overview/plans.html)
- [Mattermost open source license](https://github.com/mattermost/mattermost/blob/master/LICENSE.txt)
- [Oracle Cloud price list](https://www.oracle.com/cloud/price-list/)
- [OCI Email Delivery FAQ](https://www.oracle.com/application-development/email-delivery/faq/)
- [OCI Email Delivery IAM policy reference](https://docs.oracle.com/en-us/iaas/Content/Identity/policyreference/emailpolicyreference.htm)
- [OCI IAM policies overview](https://docs.oracle.com/en-us/iaas/Content/Identity/policysyntax/policy-syntax.htm)
- [OCI Approved Sender](https://docs.oracle.com/en-us/iaas/Content/Email/Reference/gettingstarted_topic-Create_an_approved_sender.htm)
- [OCI SMTP Credentials](https://docs.oracle.com/en-us/iaas/Content/Identity/access/working-with-smtp-credentials.htm)
- [OCI Email Delivery compartment quotas](https://docs.oracle.com/en-us/iaas/Content/Email/Reference/compartment-quotas.htm)

## 17. 확정 사항 요약

이 기능은 Mattermost 서버 플러그인과 내부 Mailer 컨테이너로 구성한다. 공개·비공개 채널의 새 글과 스레드 답글만 처리하고, 실제 채널 멤버 중 작성자와 부적격 계정을 제외해 개별 이메일을 즉시 큐잉한다. 이메일에는 일반 안내와 Mattermost 원문 링크만 포함한다. 메시지 본문·채널명·Team명·작성자명은 알림 경로 밖으로 보내지 않는다.

기능은 신규 설치에서 기본 활성화하며, 설치 마법사가 SMTP·플러그인·Mailer 자동 인수 조건을 통과하고 활성화 시각을 기록한 뒤에만 실제 발송을 시작한다. 프로젝트마다 전용 IAM 사용자·그룹·SMTP Credential·Approved Sender·OCID 조건 정책·`.env`·HMAC 비밀값을 사용한다. 같은 발신 도메인과 리전의 Email Domain·DKIM·SPF는 공동 사용한다.

`threadhub-mentor.stillwhy.com`과 같은 기존 운영 인스턴스에서는 관리자 전용 시험 채널 allowlist로 검증한 후에만 전역 활성화한다. SMTP 장애는 채팅 기능과 분리하며, 잘못된 수신자, 프로젝트 간 교차 발신 또는 비공개 정보 노출이 확인되면 즉시 비활성화하고 롤백한다.
