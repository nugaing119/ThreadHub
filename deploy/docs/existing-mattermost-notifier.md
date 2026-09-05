# 기존 Mattermost에 ThreadHub 이메일 notifier 적용

이 문서는 이미 운영 중인 Mattermost에 공개·비공개 채널 새 글과 스레드 답글의
프로젝트 컨텍스트 안내 이메일을 추가하는 절차입니다. 새 ThreadHub 설치 절차가 아닙니다. 신규
VM은 [배포 모델과 신규 프로젝트 표준](./deployment-models.md)의 canonical fresh와
[빠른 설치 가이드](./quick-install.md)를 사용합니다.
신규·기존 인스턴스의 공통 목표 상태와 운영 데이터 보호 gate는
[CRS-1 표준](./canonical-runtime-standard.md)을 따릅니다.

플러그인과 Mailer의 역할, 분리 이유, 데이터·장애·라이선스 경계는 적용 전에
[알림 아키텍처](./notifier-architecture.md)에서 확인합니다.

기본 `project_team_channel` 모드는 프로젝트 도메인, Team 표시명, 채널 표시명과
새 글/스레드 답글 유형을 이메일에 포함합니다. 메시지 본문, 작성자명과 첨부파일명은
포함하지 않습니다. 비공개 채널명 자체가 이메일 시스템에 남으면 안 되는 배포는
`THN_CONTENT_MODE=generic`을 선택합니다. 수신자는 게시 시점의 채널 멤버 중
작성자·비활성 사용자·봇을 제외한
이메일 확인 사용자입니다. DM, 그룹 DM, 시스템 글, 수정·삭제와 Webhook·봇 작성
글은 발송 대상이 아닙니다.

## 지원 범위

| 항목 | 지원 기준 |
| --- | --- |
| 운영체제 | Ubuntu 24.04 AMD64 |
| Mattermost | Mattermost Team Edition 11.7.7 정확한 이미지 |
| 배포 | single-node Compose, 실행 중 Mattermost 컨테이너 정확히 1개 |
| 데이터 | `/mattermost/plugins`와 `/mattermost/data`가 쓰기 가능한 명시적 bind mount |
| Site URL | `https://` 도메인과 채택 설정의 도메인이 일치 |
| 기존 notifier | 같은 서비스·network·환경변수·plugin ID가 없어야 함 |
| SMTP | STARTTLS 587, 별도 프로젝트 SMTP Credential과 Approved Sender 권장 |

다중 Mattermost replica, named plugin/data volume, 다른 Mattermost 버전, 이미 설치된
동일 plugin, 충돌하는 notifier service/network 또는 안전성을 입증할 수 없는 Compose는
자동 채택 대상이 아닙니다. preflight가 exit code 20을 반환하면 중지하고 원인을
검토합니다. 지원 기준을 우회해 계속하지 않습니다.

## 변경·비변경 경계

`existing-notifier-preflight.sh`는 base Compose, base environment, 컨테이너와 데이터를
변경하지 않습니다. SHA와 데이터 개수를 비교하는 real-image 시험으로 이 경계를
검증합니다.

setup은 다음 항목만 추가합니다.

- 보호된 별도 설정 `deploy/existing-notifier.env`
- 기본 `/srv/threadhub-notifier` 아래 control, Mailer queue, release와 rollback 증거
- 별도 `compose.override.yml`
- 검토된 notifier plugin runtime·filestore pair
- 내부 plugin↔Mailer network와 SMTP 전용 outbound network

setup과 rollback은 base Compose file과 base environment file을 덮어쓰거나 수정하지
않습니다. 기존 Team·채널·사용자·게시물·파일 행은 유지합니다. plugin 전용 KV와
rollback 격리 증거는 별도 운영 데이터로 남을 수 있습니다.

기존 배포를 단순히 경로 통일 목적으로 in-place layout migration하지 않습니다.
향후 검증된 백업을 new or empty `/srv/threadhub`의 새 VM에 복구할 때만 canonical fresh
레이아웃으로 전환합니다.

plugin pair 설치와 rollback 중 Mattermost 컨테이너가 한 번 재생성되므로 사용자는
보통 30–60초 동안 연결이 끊겼다가 다시 연결될 수 있습니다. PostgreSQL과 SMTP
fixture가 아니라 Mattermost 서비스만 필요한 단계에서 재생성하며, 작업 전 사용자에게
짧은 재연결 시간을 공지합니다. 무중단 변경이나 SLA를 보장하지 않습니다.

## 준비와 보호값

먼저 저장소가 깨끗한 검토 commit인지 확인하고 정적 검증을 실행합니다.

```bash
./deploy/scripts/validate.sh
```

다음 값을 확인해야 합니다.

- 기존 Compose project directory, Compose file과 mode `0600` environment file
- Mattermost service name
- `/mattermost/plugins`, `/mattermost/data`에 연결된 실제 host bind mount 경로
- HTTPS 도메인
- notifier 전용 root 경로
- SMTP server, username, password, Approved Sender, Reply-To와 CA bundle
- 이메일 컨텍스트 모드 `project_team_channel` 또는 `generic`

SMTP password와 HMAC은 채팅, 명령행 인수, 로그 또는 Git에 넣지 않습니다. 설정은
대화형 숨김 입력으로 만들고 mode `0600`을 유지합니다. OCI IAM user, group, policy,
SMTP Credential, Approved Sender, DNS와 공인 IP를 만들거나 바꾸려면 대상 compartment와
region을 밝히고 별도 명시 승인을 받습니다.

`project_team_channel`은 비공개 Team·채널 표시명을 OCI Email Delivery와 각 수신자의
메일함에 전달한다는 점을 데이터 취급 범위에 포함해야 합니다. 채널명에는 고객명,
사건번호, 장애 상세나 기타 비밀정보를 넣지 않는 명명 규칙을 권장합니다.

## 적용 순서

v0.1.0이 이미 운영 중인 인스턴스는 아래의 최초 적용 순서를 다시 실행해 덮어쓰지
않습니다. v0.2.0의 별도 통제된 플러그인·Mailer 업그레이드 전에 보호된
`deploy/existing-notifier.env`를 `sudoedit`으로 열어 다음 중 정확히 한 줄을 추가합니다.
설정 파일 전체를 출력하거나 새 파일로 덮어쓰지 않습니다.

```text
THN_CONTENT_MODE=project_team_channel
```

비공개 Team·채널명 외부 노출을 허용하지 않으면 값은 `generic`으로 둡니다. 이 키가
없거나 중복되거나 알 수 없는 값이면 preflight는 기존 서비스를 변경하지 않고
exit code 20으로 중단합니다. 이 설정만 추가해도 실행 중인 v0.1.0의 메일 형식은
바뀌지 않으며, 검증된 v0.2.0 release pair의 통제된 교체 전에는 새 형식을 기대하지
않습니다.

안전 gate의 고정 순서는 `existing-notifier-preflight.sh` → `disabled` →
`existing-notifier-setup.sh` → `SMTP acceptance` → `allowlist` →
`manual acceptance` → `explicit all_channels approval`입니다.

1. 다음 read-only 검사부터 실행합니다.

   ```bash
   THREADHUB_EXISTING_NOTIFIER_ENV_FILE=deploy/existing-notifier.env \
     ./deploy/scripts/existing-notifier-preflight.sh
   ```

   설정이 아직 없으면 아래 명령을 실제 터미널에서 실행합니다. SMTP password는 hidden
   prompt로만 입력합니다.

   ```bash
   ./deploy/scripts/existing-notifier-setup.sh --configure-only
   ```

2. preflight가 통과한 뒤 notifier를 disabled 상태로 설치합니다.

   ```bash
   ./deploy/scripts/existing-notifier-setup.sh --resume --non-interactive
   ```

   이 단계는 발송을 켜지 않습니다. 정상적인 첫 실행은 구성요소를 disabled 상태로
   설치한 뒤 SMTP acceptance가 필요하다는 `[ACTION REQUIRED]`와 exit code 20으로
   멈춥니다.

3. 실제 터미널에서 일회성 SMTP acceptance를 수행합니다.

   ```bash
   ./deploy/scripts/existing-notifier-smtp-test.sh
   ```

   수신 주소는 숨김 입력입니다. 자동 시험은 SMTP 서버의 최종 접수와 현재 설정
   fingerprint만 확인합니다. 받은편지함 도착, 링크, SPF와 DKIM은 별도 수동 인수
   항목입니다.

4. 공개·비공개 시험 채널 ID만 넣어 allowlist 파일럿을 활성화합니다.

   ```bash
   ./deploy/scripts/existing-notifier-control.sh activate-allowlist
   ```

   public/private root and thread 글을 각각 작성해 대상 멤버만 컨텍스트 안내 이메일을 받고,
   비allowlist 채널·DM·시스템 글·작성자·비멤버가 제외되는지 확인합니다.

5. 다음 상태와 manual acceptance 결과를 함께 기록합니다.

   ```bash
   ./deploy/scripts/existing-notifier-status.sh
   ./deploy/scripts/existing-notifier-control.sh status
   ```

6. 전체 채널 전환은 파일럿 완료와 운영 책임자의 별도 명시 승인이 있어야 합니다.
   이것이 explicit all_channels approval입니다. 승인 후 실제 터미널에서만 실행하고
   정확한 확인 문구를 입력합니다.

   ```bash
   ./deploy/scripts/existing-notifier-control.sh activate-all-channels
   ```

## 수동 인수시험

- allowlist 공개 채널 루트 글과 스레드 답글
- allowlist 비공개 채널 루트 글과 스레드 답글
- 게시 작성자 제외
- 현재 채널 비멤버, 비활성 사용자와 봇 제외
- 비allowlist 채널, DM, 그룹 DM과 시스템 글 제외
- `project_team_channel`이면 제목·본문의 도메인, Team, 채널과 새 글/답글 유형이 정확함
- `generic`이면 Team·채널 표시명이 없음
- 두 모드 모두 메시지 본문·작성자명·첨부파일명과 다른 수신자 주소가 없음
- 링크가 `https://<domain>/_redirect/pl/<post-id>`이며 권한 있는 사용자만 원문 접근
- SMTP 중단 중 Mattermost 글 작성 성공과 복구 후 queue 처리
- 받은편지함 도착, SPF/DKIM, 모바일·웹 링크

자동 `NF-ADOPT-01`~`NF-ADOPT-10`은 설치·rollback 경계를 검증하지만 실제 OCI inbox,
조직별 수신정책과 사용자의 링크 권한을 대체하지 않습니다.

## 기존 배포의 자동 백업 연결

기존 notifier 적용형 배포는 정규 신규 설치와 Compose project 및 데이터 경로가
다르므로, `/srv/threadhub`로 옮기거나 `deploy/.env`에 자격증명을 합치지 않습니다.
`existing-notifier-status.sh`가 정상이고 `deploy/existing-notifier.env`가 mode 0600인
상태에서 [백업 및 복구 운영 가이드](./backup-restore.md)의 OCI 전용 버킷과 최소 권한을
먼저 준비한 뒤 다음처럼 연결합니다.

```bash
sudo ./deploy/scripts/configure-backup.sh --source-mode existing-notifier
sudo ./deploy/scripts/install-backup.sh --register
sudo ./deploy/scripts/backup.sh
sudo ./deploy/scripts/backup-status.sh
```

`configure-backup.sh`는 기존 backup 설정을 덮어쓰지 않고 보호된
`/etc/threadhub/backup-source.env`만 추가합니다. `backup.sh`는 이 source mode를 보고
기존 base+override Compose를 사용해 PostgreSQL dump, 실제 Mattermost data bind mount,
`/srv/threadhub-notifier/mailer` queue를 하나의 검증 세트로 만듭니다. 운영 release의
commit을 provenance로 사용하며 현재 저장소에 그 commit이 없거나 working tree가
dirty하면 실패합니다. Mattermost와 Mailer는 snapshot 구간에만 중지하며, 실패
trap에서도 재시작과 health를 검증합니다.
systemd의 root 실행에서 저장소 소유자가 달라도 provenance를 읽을 수 있도록 정확한
저장소 물리 경로만 command-scoped Git `safe.directory`로 지정하며, 전역 Git 설정은
변경하지 않습니다.

최초 수동 백업과 분리된 폐기 VM 복구시험이 끝날 때까지 timer remains disabled입니다.
복구는 기존 base Compose 경로에 덮어쓰지 않고 정규 신규 설치의 new or empty
`/srv/threadhub`에서만 수행합니다.

## 상태·중지와 rollback

평상시 상태는 다음 명령으로 확인합니다.

```bash
./deploy/scripts/existing-notifier-status.sh
```

변경이나 rollback 전에는 새 수집을 drain하고 `pending=0`, `sending=0`을 확인합니다.
실패 건은 운영 판단에 따라 재시도하거나 명시적으로 취소한 뒤 `failed=0`을 확인하고
disable합니다.

```bash
./deploy/scripts/existing-notifier-control.sh drain
./deploy/scripts/existing-notifier-control.sh disable
./deploy/scripts/existing-notifier-rollback.sh
```

failed delivery가 있으면 rollback은 자동으로 선택하지 않고 멈춥니다. 필요한 경우에만
`--retry-failed` 또는 `--cancel-failed`를 명시합니다. rollback은 base Compose와 base
environment를 다시 사용해 Mattermost를 재생성하고 검토된 plugin pair를 운영 경로에서
격리합니다. Mailer의 queue data와 격리된 plugin 증거는 삭제하지 않습니다. rollback
후 기존 Team·채널·사용자·게시물·파일과 기준 글을 다시 확인합니다. Mattermost는
플러그인을 제거할 때 재설치 후 자동 활성화를 막기 위한 비활성 `PluginStates` 표지를
남길 수 있습니다. rollback은 실행 파일과 filestore bundle이 모두 격리되고, 이 표지가
`Enable=false`인 경우만 안전한 비실행 상태로 인정합니다. 이 동작은 Mattermost v11.7.7의
[`RemovePlugin`](https://github.com/mattermost/mattermost/blob/v11.7.7/server/channels/app/plugin_install.go#L521-L562)이
제거 전에 플러그인을 명시적으로 비활성화하는 공식 구현과 일치합니다.

rollback 중 실패하면 스크립트는 reviewed combined service를 disabled 상태로 복구하려고
시도합니다. 자동 복구도 실패하면 Mattermost와 notifier 상태를 임의로 수정하지 말고
운영 책임자에게 전달합니다.

## 운영 종료 조건

다음 중 하나면 고객 채널 전체 활성화나 작업 완료를 선언하지 않습니다.

- preflight 또는 setup의 exit code 20 원인이 미해결
- SMTP acceptance marker가 없거나 현재 credential fingerprint와 불일치
- plugin이 정확한 reviewed version으로 Running이 아님
- queue에 pending, sending 또는 미처리 failed가 남음
- public/private root and thread 수신 경계가 수동 검증되지 않음
- inbox/link/SPF/DKIM이 확인되지 않음
- base Compose·환경파일 hash 또는 기존 데이터 검증이 달라짐

상세 일상 점검과 queue 처리 순서는 [운영 점검표](./operations-checklist.md), 기능·보안
시험 ID는 [시험계획](./test-plan.md)을 사용합니다.
