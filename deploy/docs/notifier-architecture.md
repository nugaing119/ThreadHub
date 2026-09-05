# ThreadHub 즉시 채널 이메일 알림 아키텍처

이 문서는 ThreadHub Channel Email Notifier 플러그인과 Mailer를 함께 사용하는 이유,
각 구성요소의 책임, 데이터 경계와 Mattermost Team Edition 라이선스 경계를 설명한다.
설치 명령은 [빠른 설치](./quick-install.md), 기존 Mattermost 적용은
[기존 Mattermost notifier 적용](./existing-mattermost-notifier.md), 일상 운영은
[운영 점검표](./operations-checklist.md)를 따른다.

## 1. 왜 플러그인과 Mailer가 모두 필요한가

Mattermost Team Edition에서 플러그인을 실행할 수 있다는 것은 공개 플러그인 API를
사용한 통합 기능이 지원된다는 뜻이다. ThreadHub가 요구하는 즉시 이메일 알림을
제공하는 플러그인이 Mattermost에 기본 포함된다는 뜻은 아니다.

ThreadHub는 다음 요구사항을 동시에 충족하기 위해 두 구성요소를 사용한다.

- 공개·비공개 채널의 새 글과 스레드 답글을 게시 직후 감지한다.
- 게시 시점의 채널 멤버에게만 수신자별 이메일을 보낸다.
- 프로젝트 도메인, Team 표시명, 채널 표시명과 새 글/스레드 답글 유형을 이메일에
  포함해 여러 프로젝트 알림을 구분한다.
- 메시지 본문, 작성자명, 첨부파일명과 수신자 목록은 이메일에 포함하지 않는다.
- DM, 그룹 DM, 시스템 글, 수정·삭제와 Webhook·봇 작성 글은 제외한다.
- SMTP 장애가 Mattermost의 글 작성 성공 여부에 영향을 주지 않게 한다.
- 커스텀 플러그인 코드에서 SMTP 처리와 자격 증명 접근을 제거한다.
- 알림 발송 재시도와 영구 큐를 Mattermost의 글 작성 경로에서 분리한다.

플러그인은 Mattermost 안에서만 알 수 있는 메시지 이벤트와 채널 멤버십을 처리하고,
Mailer는 OCI Email Delivery로 안전하고 재시도 가능한 SMTP 전송을 담당한다. Mailer는
플러그인을 대신하는 제품이 아니라 플러그인의 전송 전용 백엔드다.

## 2. 구성요소별 책임

| 구성요소 | 책임 | 보유하지 않는 책임 |
| --- | --- | --- |
| Mattermost 플러그인 | `MessageHasBeenPosted` 감지, 대상 이벤트 필터, 현재 채널 멤버와 적격 수신자 확인, plugin KV outbox 기록, HMAC 서명 요청 | SMTP 연결·자격 증명 사용, 장기 재시도, 이메일 발송 큐 |
| Mailer | 서명·재전송 입력 검증, SQLite 영구 큐와 중복 방지, 수신자별 컨텍스트 안내문 생성, 속도 제한·재시도·실패 분류, STARTTLS SMTP 발송 | Mattermost 메시지 본문 조회, 채널 권한 결정, Mattermost 유료 기능 활성화 |
| OCI Email Delivery | 승인된 발신자의 SMTP 메시지 접수와 인터넷 메일 전달 | Mattermost 이벤트 감지, 채널 멤버십 판단 |

## 3. 이벤트 흐름

```text
사용자가 채널에 새 글 또는 스레드 답글 작성
  → Mattermost가 글을 저장하고 플러그인 훅 호출
  → 플러그인이 대상 여부·현재 채널 멤버·Team/채널 표시명 확인
  → 최소 이벤트를 plugin KV outbox에 기록
  → 내부 Docker network로 HMAC 서명 요청 전송
  → Mailer가 SQLite에 원자적으로 저장한 뒤 접수 응답
  → Mailer가 수신자별 프로젝트 컨텍스트 안내 이메일을 STARTTLS로 발송
  → 사용자는 ThreadHub에 로그인해 원문 확인
```

플러그인과 Mailer 사이의 HTTP 인터페이스는 호스트 포트를 갖지 않는 내부 Docker
network에만 존재한다. Mailer가 이벤트를 영구 큐에 저장하기 전에 응답하지 않으며,
접수되지 않은 이벤트는 plugin KV outbox에 남아 다시 처리된다.

## 4. 분리 설계의 효과

### SMTP 책임과 비밀정보 경계

사용자 초대·이메일 확인·비밀번호 재설정 때문에 Mattermost 본체와 Mailer에는 같은
프로젝트 SMTP 설정이 주입된다. 커스텀 플러그인 구현은 SMTP 자격 증명을 읽거나
plugin→Mailer 요청에 포함하지 않는다. 요청은 프로젝트별 HMAC으로 인증하며 HMAC과
SMTP 비밀번호는 보호된 환경파일에만 저장한다. 따라서 분리의 보안 효과는 Mattermost
컨테이너로부터 자격 증명을 완전히 제거하는 것이 아니라, 커스텀 플러그인의 책임과
내부 이벤트 payload에서 SMTP 비밀값을 제외하는 데 있다.

### 장애 격리

SMTP 또는 Mailer가 일시 중단돼도 Mattermost의 글 작성은 계속 성공한다. 미접수
이벤트는 plugin KV outbox에, Mailer가 접수한 발송 작업은 bind mount의 SQLite 큐에
남는다. Mailer 재시작이나 컨테이너 재생성 뒤에도 큐를 이어서 처리한다.

### 운영 제어

`activate`, `drain`, `disable` 상태로 신규 이벤트 수집과 기존 큐 발송을 분리 제어한다.
Mailer만 중지하거나 notifier를 비활성화해도 Mattermost 채널, 사용자, 게시물과 파일은
계속 유지된다. 전달 방식은 at-least-once이므로 SMTP 접수 직후 상태 기록 전에 프로세스가
중단되면 드물게 중복 이메일이 발생할 수 있다.

### 개인정보 최소화와 컨텍스트 노출 선택

`NOTIFIER_CONTENT_MODE=project_team_channel`은 이메일 제목과 본문에 다음 값만 포함한다.

- `THREADHUB_DOMAIN` 프로젝트 도메인
- Mattermost Team 표시명
- 공개 또는 비공개 채널 표시명
- `새 글` 또는 `스레드 답글` 유형
- 권한 확인을 거치는 Mattermost permalink

메시지 본문, 작성자명, 첨부파일명과 다른 수신자 주소는 plugin→Mailer 요청이나
이메일에 포함하지 않는다. Mailer 상태와 로그에는 Team·채널명과 수신 주소를 출력하지
않는다. 표시명은 길이와 제어문자를 검증하고, 제목은 RFC 2047로 인코딩하며 HTML 본문은
escape한다.

예를 들어 `project-a.example.test`의 `Customer-A` Team, `Support` 채널에
스레드 답글이 등록되면 제목은 다음 형식이다.

```text
[ThreadHub][project-a.example.test] Customer-A / Support · 스레드 답글
```

본문에는 같은 도메인·Team·채널과 이벤트 유형, 원문 확인 링크만 표시한다.

이 모드는 **비공개 Team·채널 표시명도 OCI Email Delivery와 수신자의 메일함에
남긴다.** 채널명 자체가 기밀인 프로젝트는 `NOTIFIER_CONTENT_MODE=generic`을 사용한다.
`generic`은 기존처럼 새 메시지 안내와 permalink만 보낸다. 신규 설치 마법사는 여러
프로젝트 구분을 위해 `project_team_channel`을 명시적으로 기록하지만, v0.1.0에서
업그레이드되어 새 필드가 없는 기존 큐 항목은 일반형으로 안전하게 발송한다.

Mailer SQLite schema v2는 전송 대기 중에만 Team·채널명과 이벤트 유형을 보존한다.
모든 수신자의 발송이 끝나거나 실패 건을 취소하면 permalink와 함께 이 컨텍스트도
즉시 `NULL`로 scrub하고, 가명화된 종료 행은 기존 7일 정책에 따라 제거한다.

## 5. Mattermost 기본 이메일 알림과의 관계

`MM_EMAILSETTINGS_SENDEMAILNOTIFICATIONS=false`는 Mattermost가 제공하는 일반 메시지
이메일 알림을 끄는 설정이다. 사용자 초대·이메일 확인·비밀번호 재설정 메일과 별도
ThreadHub notifier의 발송을 끄는 설정은 아니다.

Mattermost 기본 알림은 사용자 상태·개인 설정·멘션 조건 등에 따라 동작한다.
ThreadHub notifier는 그 기능을 확장하거나 우회하지 않고, 합의된 채널 이벤트를 별도
통합 경로로 OCI Email Delivery에 제출한다. 두 종류의 메시지 알림을 동시에 사용해
중복 발송하지 않도록 Mattermost 기본 일반 메시지 이메일 알림은 비활성화한다.

## 6. 라이선스 경계

Mattermost 공식 문서는 플러그인을 Team Edition과 Enterprise Edition 모두에서
지원한다고 명시한다. ThreadHub notifier는 공개 `server/public` 플러그인 API와
`MessageHasBeenPosted` 훅만 사용한다.

- Enterprise 코드를 포함하거나 Mattermost 서버를 패치하지 않는다.
- 유료 기능 또는 라이선스 검사를 활성화·우회하지 않는다.
- Persistent Notification, 확인 강제, Reminder와 Scheduled Message를 구현하지 않는다.
- 플러그인과 Mailer는 ThreadHub의 MIT 라이선스 코드이며, 산출물에 자체 라이선스와
  제3자 의존성 고지를 포함한다.

상세 근거와 의존성 고지는
[notifier 라이선스 및 제3자 고지](../../notifier/THIRD_PARTY_NOTICES.md)를 따른다.

## 7. 선택 기준

즉시 채널 이메일이 필요하지 않으면 notifier 전체를 비활성 상태로 둘 수 있다. 멘션과
DM 중심의 지연 가능한 알림만 필요하다면 Mattermost 기본 이메일 알림을 별도로 평가할
수 있다. 모든 채널 새 글을 게시 직후, 채널 멤버에게, 프로젝트를 구분할 수 있는
최소 컨텍스트 안내문으로 보내야 하는
ThreadHub 기준에서는 플러그인과 Mailer를 함께 사용한다.
