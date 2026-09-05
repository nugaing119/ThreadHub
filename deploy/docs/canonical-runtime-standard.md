# ThreadHub 표준 목표 상태와 기존 인스턴스 수렴 기준

이 문서는 신규 ThreadHub와 서로 다른 시점에 구축된 기존 인스턴스가 따라야 할 하나의
논리적 목표 상태를 정의한다. 목적은 운영 중인 Team·사용자·채널·게시물·파일을 보존하면서
공통 코드와 공통 검증 절차로 관리하는 것이다.

이 문서나 저장소 변경은 운영 VM, OCI, DNS, SMTP 또는 데이터를 변경할 권한을 부여하지
않는다. 기존 인스턴스 작업은 정확한 대상과 영향, 복구 증거를 제시한 뒤 사용자의 별도
명시 승인을 받아 한 인스턴스씩 수행한다.

## 1. 표준 식별자와 기준 소스

이 표준의 식별자는 **ThreadHub Canonical Runtime Standard 1(CRS-1)**이다.

- 실행 이미지의 정확한 태그·Digest와 notifier release는 `deploy/versions.env`가
  유일한 기준이다. 문서에 복사된 버전보다 이 파일의 검증된 값이 우선한다.
- 신규 설치의 물리 레이아웃은 `deploy/docker-compose.yml`과
  [배포 모델](./deployment-models.md)의 `canonical fresh`가 기준이다.
- 기존 Mattermost의 보호된 후설치 레이아웃은
  [existing adoption](./existing-mattermost-notifier.md)이 기준이다.
- 설치·채택·백업 스크립트와 문서가 서로 다르면 작업을 중단한다. 운영 호스트에서
  임의로 문서나 검증기를 우회하지 않는다.
- `latest`, floating tag, 호스트별 fork와 운영 서버에서 직접 수정한 미추적 파일을
  표준 산출물로 인정하지 않는다.

CRS-1의 변경은 저장소 PR, 전체 `./deploy/scripts/validate.sh`, 관련 real-image CI와
문서화된 수동 인수시험을 통과한 commit으로만 이루어진다.

## 2. 하나의 표준과 두 개의 지원 프로필

경로와 Compose 파일을 억지로 같게 만드는 것은 운영 데이터에 불필요한 위험을 만든다.
CRS-1은 다음 두 프로필만 지원한다. hostname이나 고객 이름별 특수 프로필을 만들지 않는다.

| 프로필 | 적용 대상 | 물리 구성 | 최종 요구 결과 |
| --- | --- | --- | --- |
| `canonical-fresh` | 새 VM·새 프로젝트 | 저장소 Compose와 `/srv/threadhub` | CRS-1 전체 준수 |
| `existing-adoption` | 지원 조건을 만족하는 기존 Mattermost | 기존 base Compose + 검증된 override, 기존 데이터 경로 보존 | CRS-1의 동일한 기능·보안·운영 결과 |

`existing-adoption`은 hostname별 예외가 아니라 기존 데이터를 보호하기 위한 표준
프로필이다. base Compose, base environment와 기존 bind mount를 그대로 보존한다.
경로를 통일하려는 in-place migration은 하지 않는다. 향후 검증된 백업을 new or empty
`/srv/threadhub`의 새 VM에 복구할 때만 `canonical-fresh` 물리 레이아웃으로 수렴한다.

지원 프로필로 설명할 수 없는 차이가 발견되면 다음 중 하나로 처리한다.

1. 안전한 공통 요구라면 PR과 CI를 거쳐 CRS-1의 새 revision으로 반영한다.
2. 일회성 데이터 변환이라면 별도의 검증된 migration 단계로 처리하고 목표 상태에는
   남기지 않는다.
3. 둘 다 아니면 unsupported로 중단한다. hostname 조건문이나 복사된 전용 스크립트로
   우회하지 않는다.

## 3. 모든 프로젝트의 공통 목표 상태

### 플랫폼과 데이터

- Ubuntu 24.04 AMD64, 2 OCPU, 16GB RAM, Boot Volume 50GB 이상
- `deploy/versions.env`의 Mattermost Team Edition, PostgreSQL과 Docker 고정 버전
- PostgreSQL과 Mattermost의 명시적 영구 bind mount
- PostgreSQL host port 없음, Mattermost 8065는 `127.0.0.1`에만 bind
- 인터넷 진입점은 NGINX HTTPS 443이며 HTTP 80은 인증서와 HTTPS 전환에만 사용
- SSH는 승인된 관리자 source와 공개키 인증만 허용
- 컨테이너 재생성·VM 재부팅 후 Team·사용자·채널·게시물·파일 유지
- Docker와 Mattermost 로그 크기 제한 및 인증서 자동 갱신 상태 확인

### 인증과 Mattermost 운영

- 초대 기반 이메일 가입, 이메일 확인과 비밀번호 재설정
- 공개 가입·Calls·모바일 푸시·사용자 플러그인 업로드·공개 파일 링크 비활성
- ThreadHub notifier 외의 임의 플러그인과 Webhook 비활성
- 고객에게 System Admin 또는 Team Admin 권한을 부여하지 않음
- 인스턴스당 활성 사용자 운영 상한 50명
- Mattermost 일반 메시지 이메일 알림은 중복 방지를 위해 비활성

### 즉시 채널 이메일 notifier

- 정확한 release의 ThreadHub plugin과 Mailer를 한 쌍으로 사용
- 공개·비공개 채널의 사용자 작성 새 글과 스레드 답글만 처리
- 게시 시점의 현재 채널 멤버 중 작성자·비활성 사용자·봇을 제외한 이메일 확인 사용자만
  수신
- DM·그룹 DM·시스템 글·수정·삭제·Webhook·봇 작성 글 제외
- HMAC 입력 검증, plugin KV outbox, bind-mounted SQLite queue와 at-least-once 전달
- 신규 프로젝트의 표준 content mode는 `project_team_channel`
- 도메인·Team·채널·새 글/답글 유형·permalink만 이메일에 포함
- 메시지 본문·작성자명·첨부파일명·다른 수신자 주소 제외
- Team·채널명 자체가 기밀인 프로젝트는 사전 데이터 취급 결정으로 `generic`을 선택할
  수 있다. 이는 코드 분기가 아닌 CRS-1에 포함된 두 번째 개인정보 프로필이다.
- SMTP acceptance와 공개·비공개 allowlist 인수시험 전에는 전체 채널 발송 금지

### OCI와 프로젝트 분리

- VM·Boot Volume·공인 IP·hostname·보호 환경파일·DB 비밀번호·HMAC은 프로젝트별
- SMTP IAM 사용자·그룹·Credential과 exact Approved Sender는 프로젝트별
- Email Domain·DKIM·SPF와 DNS zone은 같은 발신 도메인·리전의 검증된 공동 자원만 공유
- 백업을 사용하는 고객 운영 프로젝트는 프로젝트별 private bucket·lifecycle·최소 권한
  policy 사용
- Dynamic Group은 프로젝트 전용이 기본이다. quota 때문에 승인된 공유 그룹을 쓰면
  정확한 VM OCID 열거, bucket+principal 이중 제한과 cross-project deny matrix가 필수
- 어떤 프로젝트의 credential, 데이터, queue, bucket 또는 HMAC도 다른 프로젝트에 연결하지
  않음

### 백업 상태

고객 또는 장기 운영 인스턴스는 `backup-enabled` 상태를 CRS-1 운영 기준으로 사용한다.
일회성 폐기 POC가 백업을 사용하지 않으면 고객 운영과 혼동되지 않도록 비공개 운영
기록에 `disposable-no-backup`으로 명시한다.

- 최초 원격 백업의 크기·checksum·manifest 검증
- 폐기 가능한 별도 VM의 new or empty `/srv/threadhub`에 실제 복구시험
- 복구된 Mattermost 데이터와 격리된 notifier queue 검증
- 위 증거 검토 전에는 backup timer 비활성
- 기존 배포는 데이터 경로를 옮기지 않고 `backup-source.env` 어댑터 사용

## 4. 프로젝트마다 달라도 되는 값

다음 값만 프로젝트별 입력 또는 보호된 운영 상태로 달라질 수 있다.

- hostname, Let’s Encrypt 연락처와 TLS 인증서
- OCI compartment·region·VM·public IP·DNS·bucket 관련 식별자
- SMTP endpoint·username·password·Approved Sender·Reply-To
- PostgreSQL password와 notifier HMAC
- Team·채널·사용자·메시지·파일 같은 프로젝트 데이터
- notifier `project_team_channel`/`generic` 개인정보 프로필
- notifier `disabled`/`allowlist`/`all_channels` 운영 상태와 allowlist channel ID
- 백업 보존 상태와 최신 검증 증거
- SSH 관리자 source CIDR

실제 값은 공개 저장소에 기록하지 않는다. 인스턴스 간 차이 조사표도 고객명, 이메일,
OCID, IP, hostname, 채널 ID와 credential fingerprint를 제거한 비공개 change record로
관리한다.

다음은 허용되는 프로젝트 차이가 아니다.

- 서로 다른 Compose 소스 또는 임의 이미지 태그·Digest
- hostname을 기준으로 동작이 달라지는 코드
- 운영 VM에서만 존재하는 수정 스크립트
- 다른 프로젝트의 SMTP Credential·HMAC·DB password 재사용
- 공통 문서에 없는 포트 노출·플러그인·자동화
- 기존 데이터를 새 표준 경로로 추정 복사하거나 기존 `/srv/threadhub`에 연결

## 5. 기존 인스턴스 상태 분류

기존 인스턴스는 hostname이 아니라 다음 상태로만 분류한다.

| 상태 | 의미 | 허용 작업 |
| --- | --- | --- |
| `crs1-conformant` | 현재 검증된 commit과 목표 상태 일치 | 일상 운영과 문서화된 rotation |
| `legacy-held` | 정상 운영 중이나 이전 notifier 또는 설치 revision | 읽기 전용 조사와 기존 운영만 허용 |
| `migration-ready` | 공통 migration 지원 범위, 백업·복구·preflight 통과 | 별도 승인 후 한 인스턴스 적용 |
| `retirement-candidate` | 사용이 종료됐거나 종료 예정이며 업그레이드 효익이 없음 | 업그레이드 금지, 보존·폐기 결정과 종료 절차만 수행 |
| `unsupported` | topology·버전·volume·데이터 상태가 지원 범위 밖 | 자동 변경 금지, 별도 설계 필요 |

notifier v0.1.0 인스턴스는 현재 `legacy-held`다. `NOTIFIER_CONTENT_MODE` 키만 추가해도
실행 중인 plugin·Mailer 또는 queue schema는 v0.2.0으로 바뀌지 않는다. 신규 설치
마법사나 최초 adoption 절차로 덮어쓰지 않는다.

`legacy-held`를 `migration-ready`로 바꾸려면 공통 v0.1.0→v0.2.0 migration이 다음을
모두 자동 검증해야 한다.

- canonical-fresh와 existing-adoption 두 프로필의 정확한 사전 상태 식별
- 알 수 없는 파일·service·volume·plugin·queue schema 발견 시 변경 전 중단
- Mattermost Team·사용자·채널·게시물·파일 비변경 증거
- v1 queue의 pending·sending·failed 보존과 v2 schema migration
- disabled 설치, SMTP acceptance, allowlist와 명시적 all_channels 승인
- 실패 지점별 기존 plugin/Mailer pair와 control 상태 복원
- real-image 통합 시험과 disposable restore 시험

이 공통 migration 도구와 시험이 저장소에 병합되기 전에는 운영 v0.1.0을 v0.2.0으로
올리지 않는다. 서버별 수동 명령을 조합해 같은 결과라고 추정하지 않는다.

`retirement-candidate`는 표준화를 이유로 upgrade하지 않는다. 먼저 notifier를 안전하게
drain·disable하고 기록 유지 또는 완전 폐기를 결정한 뒤 [프로젝트 종료 절차](./project-close.md)를
따른다. 기록 유지 중에는 필요한 보안 패치와 인증서·계정 보호만 수행하며 새 기능을
추가하지 않는다. 실제 폐기 역시 별도 승인 없이는 실행하지 않는다.

## 6. 운영 인스턴스 보호 게이트

### Gate 0 — 저장소 준비

1. 깨끗한 검토 commit과 고정 release를 선택한다.
2. `./deploy/scripts/validate.sh`와 관련 CI가 모두 통과해야 한다.
3. 실행 절차가 현재 인스턴스의 상태 프로필을 명시적으로 지원해야 한다.

이 단계는 로컬 저장소 작업이며 운영 대상 변경을 허가하지 않는다.

### Gate 1 — 대상과 승인

1. 비공개 change record에 정확한 hostname, VM OCID, 공인 IP, compartment와 region을
   기록한다.
2. 예상되는 컨테이너 재생성, 30–60초 재연결 가능성, SMTP 발송 변화와 rollback 한계를
   사용자에게 제시한다.
3. 해당 인스턴스와 작업 범위에 대한 별도 명시 승인을 받는다.

한 승인으로 여러 운영 인스턴스를 일괄 변경하지 않는다.

### Gate 2 — 읽기 전용 inventory와 기준선

변경 전에 다음을 비밀값이나 고객 내용을 출력하지 않는 방식으로 기록한다.

- OS·architecture·CPU·memory·storage와 시간 동기화
- 실행 중인 Compose project/file/environment 경계
- 이미지 ID·Digest, 컨테이너 health와 restart count
- host port와 Docker network
- bind mount source/destination/type과 소유권
- Mattermost Site URL·edition·version과 plugin 상태
- notifier release·content mode·control state와 queue 상태 집계
- Team·활성/비활성 사용자·채널·게시물·파일의 기준 집계
- 인증서 갱신, SMTP acceptance와 backup 상태

예상과 다른 값, symlink, named data volume, 불명확한 Compose merge, dirty release 또는
둘 이상의 Mattermost replica가 있으면 변경하지 않고 `unsupported`로 중단한다.

### Gate 3 — 복구 가능성

운영 데이터나 컨테이너 구성을 변경할 수 있는 작업은 다음 증거가 없으면 시작하지
않는다.

1. 최신 수동 원격 백업이 immutable set으로 검증됨
2. 별도의 폐기 가능한 VM에서 해당 set의 복구가 성공함
3. 복구된 Team·사용자·채널·게시물·파일 기준이 원본의 비밀정보 비노출 집계와 일치함
4. notifier queue는 복구 대상에서 발송 격리됨
5. rollback이 무엇을 복원하고 무엇을 복원하지 못하는지 기록됨

백업 성공 로그만으로 복구 가능성을 가정하지 않는다. 운영 인스턴스 자체에 restore를
실행하지 않는다.

### Gate 4 — 변경 전 정지 조건

- 운영 공지와 승인된 작업 시간을 확인한다.
- notifier를 `drain`하고 pending=0, sending=0을 확인한다.
- failed delivery를 명시적으로 재시도 또는 취소해 failed=0을 확인한다.
- notifier를 `disable`하고 `delivery_enabled=false`를 확인한다.
- 적용 직전 Mattermost/PostgreSQL health와 기준 집계를 다시 확인한다.

하나라도 충족되지 않으면 작업을 연기한다. 큐를 삭제해 gate를 통과하지 않는다.

### Gate 5 — 통제된 적용

- 한 인스턴스에서 문서화된 공통 명령만 실행한다.
- base Compose, base environment, PostgreSQL data와 Mattermost data를 덮어쓰지 않는다.
- destructive Docker volume 옵션, 데이터 경로 이동과 PostgreSQL major 변경을 금지한다.
- notifier는 항상 disabled 상태로 먼저 설치한다.
- 실패 시 추가 수정을 중단하고 검증된 rollback 경로만 사용한다.

### Gate 6 — 적용 후 비교와 파일럿

1. 컨테이너 health, restart count, HTTPS, 로그인과 Site URL을 확인한다.
2. 변경 전후 Team·사용자·채널·게시물·파일 집계를 비교한다.
3. 기준 게시물과 첨부파일을 읽고 새 시험 글을 작성한다.
4. 비밀번호 재설정 등 계정 메일을 확인한다.
5. SMTP acceptance 후 공개·비공개 시험 채널 allowlist만 활성화한다.
6. root/thread, 수신자 경계, 컨텍스트, permalink와 비대상 이벤트를 수동 검증한다.

기준 데이터 불일치, 로그인 실패, 파일 누락, 예상 밖 메일 발송 또는 plugin mismatch가
있으면 전체 채널을 활성화하지 않고 rollback 판단으로 이동한다.

### Gate 7 — 완료

운영 책임자의 별도 명시 승인 후에만 `all_channels`를 활성화한다. 상태와 queue를 다시
확인하고 비공개 change record를 닫는다. 실제 고객 데이터, 사용자 주소, channel ID,
OCID, IP, bucket명, backup ID와 진단 원문은 공개 PR이나 채팅에 남기지 않는다.

## 7. rollback의 보장 범위

rollback은 검증된 이전 plugin/Mailer pair, notifier control 상태와 기존 Compose 실행
형태를 복원하기 위한 것이다. 기존 PostgreSQL과 Mattermost bind mount를 삭제하거나
과거 시점으로 되돌리지 않는다. queue와 격리 증거도 임의 삭제하지 않는다.

SMTP 서버가 이미 접수한 이메일은 회수할 수 없고 at-least-once 경계에서 중복 메일이
발생할 수 있다. 그래서 변경 전 drain·disable과 변경 후 allowlist가 필수다.

자동 rollback이 실패하면 반복적인 임의 명령을 실행하지 않는다. 현재 상태, 마지막
성공 gate와 비밀정보를 제거한 오류 분류만 운영 책임자에게 전달하고 수동 복구 판단을
기다린다.

## 8. 표준 준수 완료 조건

다음 조건을 모두 만족할 때만 인스턴스를 `crs1-conformant`로 기록한다.

- 지원 프로필과 검증된 source commit이 식별됨
- `deploy/versions.env`와 실행 artifact pair 일치
- 포트·bind mount·HTTPS·인증·데이터 영속성 기준 통과
- notifier disabled→SMTP acceptance→allowlist 수동시험 통과
- 선택한 content mode가 데이터 취급 결정과 일치
- 변경 전후 Team·사용자·채널·게시물·파일 집계 일치
- 고객/장기 운영이면 최근 원격 백업과 별도 VM 복구 증거가 유효
- 전체 채널 활성화에 대한 별도 승인이 기록됨

표준 미준수 항목이 남아 있어도 정상 운영 중인 기존 인스턴스를 서둘러 변경하지 않는다.
`legacy-held` 또는 `unsupported` 상태와 차이를 기록하고, 검증된 공통 경로가 준비될
때까지 현재 데이터를 우선 보호한다.
