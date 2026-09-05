# ThreadHub 관리자 가이드

## 1. 관리자 계정

- System Admin은 1~2개만 운영합니다.
- 비밀번호는 16자 이상을 권장합니다.
- 모든 System Admin이 사용자별 MFA를 등록해야 합니다.
- 정상 OTP, 잘못된 OTP와 복구 절차를 시험해 결과를 기록합니다.
- System Admin 계정을 고객 또는 일반 내부 사용자와 공유하지 않습니다.
- 비밀번호 변경 또는 재설정 시 기존 웹·데스크톱·모바일 세션을 모두 종료하고 새 비밀번호와 MFA로 다시 로그인하게 합니다.

전 사용자 MFA 강제 기능은 사용하지 않으며 관리자 계정에 운영절차로 강제합니다.

기존 세션 종료는 `MM_SERVICESETTINGS_TERMINATESESSIONSONPASSWORDCHANGE=true`로 적용합니다. 로그인 중 비밀번호를 변경하면 현재 세션을 제외한 나머지 세션이 종료되고, 로그인하지 않은 상태의 재설정 링크로 변경하면 기존 세션이 모두 종료되어야 합니다.

MFA 기기를 분실한 System Admin은 서버 접근권한을 가진 운영자가 본인 확인 후 다음과 같이 MFA를 해제합니다.

```bash
sudo docker exec threadhub-mattermost-1 \
  mmctl user resetmfa USERNAME --local
```

복구 직후 사용자는 비밀번호로 로그인하고 새 MFA 기기를 다시 등록합니다. 복구 작업자, 대상 계정, 실행시각과 재등록 결과를 운영 기록에 남깁니다. 임시 관리자 시험에서 잘못된 OTP 거부, 정상 OTP 로그인과 이 복구 절차를 확인했습니다.

## 2. System Scheme

정확한 Team Edition 11.7.7 이미지의 System Console에서 System Scheme을 편집합니다.

일반 Member에게서 우선 제거할 권한:

- 사용자 초대
- Team에 사용자 추가
- Team 생성
- 공개 채널 생성
- 비공개 채널 생성
- 공개 채널 삭제·보관
- 비공개 채널 삭제·보관
- Incoming·Outgoing Webhook과 사용자 통합 생성

System Scheme은 내부 일반 Member에도 전역 적용됩니다. Team과 채널 생성 요청은 ThreadHub 관리자가 처리합니다.

ThreadHub MVP에서는 일반 Member의 채널 멤버 관리, 채널 이름·설명 변경과 채널 북마크 관리는 허용합니다. 본인 메시지 삭제 권한도 유지합니다. 공개 파일 링크는 역할 권한과 별개로 서버 설정에서 비활성화합니다.

변경 후 고객 시험계정으로 다음 동작이 실패하는지 확인합니다.

1. 사용자 초대
2. Team 생성
3. 공개 채널 생성
4. 비공개 채널 생성
5. Webhook 또는 통합 생성
6. System Console 접근
7. 공개·비공개 채널 삭제 또는 보관

## 3. 초대 정책

- 기본 초대 방식은 관리자가 발송하는 이메일 초대입니다.
- Team 초대 URL을 고객에게 배포하지 않습니다.
- Team 초대 URL은 링크 소지자가 사용할 수 있는 bearer invitation으로 취급합니다.
- 초대 기간 종료 또는 링크 노출 가능성이 있으면 Team Invite Code를 재생성합니다.
- 재생성 후 이전 URL 가입이 실패하는지 확인합니다.
- 미수락 이메일 초대가 불필요해지면 전체 무효화 기능을 사용합니다.

## 4. Team과 채널

기본 배포 모델의 Team:

```text
Internal
Project
```

Project Team 기본 채널:

```text
00-공지
01-프로젝트-일반
02-진행상황
03-결정사항
04-질문-답변
05-자료공유
```

서로 존재나 참여 사실이 노출되면 안 되는 고객 조직은 같은 인스턴스에 넣지 않습니다.

프로젝트 Team을 최소 네 채널로 운영하는 경우 다음 구조를 사용합니다.

```text
00-공지            # 이름을 바꾼 기본 Town Square, Team 가입 시 자동 참여
01-프로젝트-일반   # Team 가입 시 자동 참여
02-진행-이슈       # Team 가입 시 자동 참여
03-결정사항        # Team 가입 시 자동 참여
```

네 채널은 모두 Team 공개 채널입니다. 해당 프로젝트 Team 멤버에게만 공개되며 다른 Team의 사용자는 볼 수 없습니다. 새 사용자는 Team에 가입할 때 네 채널에 자동 참여합니다. 기존 멤버의 누락된 가입은 `reconcile-team-channels.sh`로 보완합니다. 자세한 절차는 [프로젝트 Team 운영 절차](./project-team-runbook.md)를 따릅니다.

## 5. 이메일 시험

Gmail, 네이버와 다음 주소에 대해 각각 다음 메일을 시험합니다.

- 사용자 초대
- 이메일 주소 확인
- 비밀번호 재설정

메일 원문에서 SPF와 DKIM이 `pass`인지 확인하고, 수신 위치와 링크 동작을 기록합니다. 받은편지함 수신은 보장하지 않으므로 스팸함도 확인합니다.

## 6. 즉시 채널 이메일 알림

신규 ThreadHub는 빠른 설치 절차를 사용합니다. 이미 운영 중인 지원 대상
Mattermost에 notifier를 채택할 때는 base Compose를 수정하지 않는
[기존 Mattermost notifier 적용 가이드](./existing-mattermost-notifier.md)를 먼저
따릅니다.

플러그인은 Mattermost의 새 글·스레드 이벤트와 채널 멤버십을 판단하고 plugin KV
outbox에 기록합니다. 별도 Mailer는 HMAC 서명 입력을 검증하고 SQLite 영구 큐,
재시도·속도 제한과 OCI SMTP 발송을 담당합니다. 커스텀 플러그인은 SMTP 자격 증명을
읽거나 전달하지 않으며, 발송 큐·재시도·장애가 Mattermost의 글 작성 경로에서
분리됩니다. 계정 메일을 보내는 Mattermost 본체와 Mailer는 같은 프로젝트 SMTP 설정을
사용합니다. 상세 흐름과 Mattermost 기본 이메일 알림과의 차이는
[알림 아키텍처](./notifier-architecture.md)를 따릅니다.

이 notifier는 Mattermost Team Edition에서 공식 지원하는 공개 플러그인 API만
사용합니다. 유료 기능을 활성화하거나 라이선스 검사를 우회하지 않습니다. 구현 기준,
제3자 모듈 목록과 라이선스 원문은
[notifier 라이선스 및 제3자 고지](../../notifier/THIRD_PARTY_NOTICES.md)를 따릅니다.
의존성을 추가하거나 버전을 변경하면 고지와 자동 검증도 같은 변경에서 갱신해야
합니다.

공개·비공개 채널의 새 글과 스레드 답글에서 작성자를 제외한 현재 채널 멤버에게
안내문을 보냅니다. 기본 `project_team_channel` 모드는 프로젝트 도메인, Team·채널
표시명과 새 글/답글 유형을 포함하고, `generic` 모드는 이 컨텍스트를 제외합니다.
DM과 group DM은 제외하며 두 모드 모두 메시지 본문·작성자명·첨부파일명은 포함하지
않습니다. Team·채널명과 수신자 주소는 상태 출력·로그에 넣지 않습니다.

전달은 at-least-once이며 SMTP가 수락한 뒤 상태 기록 전에 프로세스가 중단되면 드물게
duplicate 이메일이 생길 수 있습니다. exactly-once 전달은 보장하지 않습니다. 실제
수신 권한, inbox, 링크, SPF/DKIM은 [빠른 설치 가이드](./quick-install.md)의 수동
인수시험으로 기록합니다. drain, 즉시 disable, 재시도와 개인정보 보존은
[운영 점검표](./operations-checklist.md)를 따릅니다. `cancel-failed`는
`failed_permanent`와 `failed_exhausted`를 한 트랜잭션에서 취소하고 recipient address와
lease를 scrub한 뒤 완료된 event metadata도 가명화합니다. pending/sending은 변경하거나
scrub하지 않으므로 먼저 둘을 0으로 만들고, 명령 뒤 `failed=0`을 확인해야 합니다.
pending/sending이 남았거나 원시 recipient-address queue backup이 남아 있으면 전체 email
scrub 또는 프로젝트 종료를 주장하지 않습니다.

## 7. CJK 검색 시험

다음 시험 메시지를 서로 다른 채널과 스레드에 작성합니다.

```text
오류
로그인 오류
고객로그인오류
고객 로그인 오류가 발생했습니다
로그인오류를 확인했습니다
API 오류 401
고객-A 로그인 2026
```

`오류` 검색이 `로그인 오류`, `고객로그인오류`, `로그인오류를 확인했습니다`를 모두 반환해야 합니다. 채널·작성자 필터, 스레드 답글, 수정 메시지와 원문 이동도 시험합니다.

## 8. 모바일 정책

- 공식 Mattermost iOS·Android 앱만 지원합니다.
- 모바일 푸시는 비활성화되어 있습니다.
- 앱이 종료된 동안 푸시가 오지 않고 앱 재실행 시 최신 메시지가 동기화되는지 확인합니다.
- 긴급 요청은 전화 또는 별도 이메일을 사용합니다.
- 고객 기기에 저장된 파일은 서버에서 원격 회수할 수 없습니다.

## 9. 사용자 교체

1. 진행 중 업무를 확인합니다.
2. 사용자를 Project Team에서 제거합니다.
3. 계정을 비활성화합니다.
4. 기존 메시지가 유지되는지 확인합니다.
5. 신규 사용자를 이메일로 초대합니다.
6. 동일 사용자가 재참여하면 기존 계정을 재활성화합니다.

## 10. 백업 수동 인수

[백업 및 복구 운영 가이드](./backup-restore.md)의 최초 수동 백업과 복구시험을
관리자와 함께 검토합니다. 자동 상태만으로 인수하지 않고 원격 5개 객체의 크기와
SHA-256, 강제된 서비스 중단 deadline 5분 이내, 공개·비공개 채널·스레드·첨부파일 복구, notifier
queue quarantine, 새 live queue와 delivery 비활성 상태를 확인합니다. 검토한 성공
백업 ID만 타이머 활성화 명령에 사용하며 운영 식별자와 증거는 비공개로 보관합니다.
