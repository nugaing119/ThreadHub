# ThreadHub

ThreadHub는 프로젝트별 고객 커뮤니케이션과 의사결정 이력을 채널과 스레드로 관리하기 위한 셀프호스팅 협업 환경입니다.

Mattermost Team Edition을 기반으로 하며, 정보 공유 경계마다 독립된 Oracle Cloud Infrastructure VM을 배포하는 방식을 기본으로 합니다.

## 현재 상태

현재 저장소에는 ThreadHub MVP의 요구사항, 구축·검증 기준과 재사용 가능한 배포 패키지가 포함되어 있습니다. 기준 배포의 핵심 서버·인증·권한·데이터 영속성·CJK 검색 결과는 공개 요약으로 제공하며, 사이트별 상세 증거와 Go/No-Go 판정은 비공개 운영 기록에서 관리합니다.

프로덕션 운영이 검증된 완성 배포본이 아니므로 실제 고객 데이터로 사용하기 전에 구축·검증 계획의 필수 시험을 수행해야 합니다.

## 핵심 기준

- 정보 공유 경계당 독립 OCI Compute VM 1대
- AMD 기반 x86_64, 2 OCPU, 16GB RAM
- Ubuntu Server 24.04 LTS
- Mattermost Team Edition 11.7.7
- PostgreSQL 18.4
- NGINX와 Let’s Encrypt
- OCI Email Delivery
- 즉시 채널 이메일 알림(프로젝트 도메인·Team·채널·새 글/답글 유형, 수신자별 단일 SMTP envelope)
- 인스턴스당 활성 사용자 최대 50명
- 웹, 데스크톱, 공식 iOS·Android 앱 지원
- 모바일 푸시 기본 비활성화
- 일일 OCI Object Storage 백업과 수동 복구(선택적·별도 인수 gate)
- 중앙 로깅, 모니터링과 고가용성 미구성

## 문서

- [ThreadHub 제품 요구사항 정의서 v4.3 Final](./docs/threadhub-prd-v4.3-final.md)
- [ThreadHub MVP 구축 및 검증 계획서](./docs/threadhub-mvp-build-validation-plan.md)
- [배포 모델과 신규 프로젝트 표준](./deploy/docs/deployment-models.md)

제품 범위와 인수조건은 PRD를 기준으로 하며, 배포 단계와 시험 절차는 구축·검증 계획서를 따릅니다.

## 예정 저장소 구조

```text
ThreadHub/
├── README.md
├── LICENSE
├── docs/
├── deploy/
│   ├── docker-compose.yml
│   ├── .env.example
│   ├── versions.env
│   ├── nginx/
│   ├── scripts/
│   └── docs/
└── .github/workflows/
```

## 배포 패키지

배포 구성과 VM 설치 순서는 [deploy/README.md](./deploy/README.md)에서 확인할 수 있습니다.

새 프로젝트는 통합 Compose와 `/srv/threadhub` 데이터 루트를 사용하는 canonical fresh
모델로 설치합니다. 기존 운영 Mattermost는 데이터를 보존하기 위해 별도의 existing
adoption 경로를 사용하며, 단순한 구조 통일을 위한 in-place migration은 하지 않습니다.
선택 기준과 프로젝트별 OCI 리소스 경계는
[배포 모델과 신규 프로젝트 표준](./deploy/docs/deployment-models.md)을 따릅니다.

새 Ubuntu 24.04 AMD64 VM에서는 설치 마법사가 프로젝트 도메인과 OCI SMTP 값을
안전하게 입력받고, PostgreSQL 비밀번호 생성부터 Docker·Mattermost·NGINX·HTTPS
검증까지 순서대로 진행합니다.

```bash
git clone https://github.com/nugaing119/ThreadHub.git
cd ThreadHub
./deploy/scripts/setup-wizard.sh
```

DNS 또는 OCI Email Delivery가 아직 준비되지 않았다면 기존 작업과 데이터를
유지한 채 `[ACTION REQUIRED]`를 출력하며, 준비 후 `--resume`으로 계속할 수
있습니다. 자세한 절차는 [빠른 설치 가이드](./deploy/docs/quick-install.md)를
따릅니다.

이미 운영 중인 지원 대상 Mattermost에 알림만 추가할 때는 신규 설치 마법사를
사용하지 않습니다. base Compose와 기존 환경파일을 수정하지 않는 별도
[기존 Mattermost notifier 적용 가이드](./deploy/docs/existing-mattermost-notifier.md)를
따릅니다.

프로젝트 Team의 사용자 운영 절차는 [프로젝트 Team 운영 절차](./deploy/docs/project-team-runbook.md)를 사용합니다.
즉시 채널 이메일 알림의 설치, 운영, 개인정보와 종료 절차는
[알림 아키텍처](./deploy/docs/notifier-architecture.md),
[빠른 설치](./deploy/docs/quick-install.md), [운영 점검표](./deploy/docs/operations-checklist.md),
[프로젝트 종료](./deploy/docs/project-close.md), [시험계획](./deploy/docs/test-plan.md)를 함께 따릅니다.

Mattermost 플러그인은 새 글·스레드 이벤트와 채널 멤버십을 판단하고, 별도 Mailer는
HMAC으로 인증된 최소 이벤트를 영구 큐에 저장한 뒤 OCI Email Delivery로 발송합니다.
커스텀 플러그인은 SMTP 자격 증명을 읽거나 전달하지 않으며, Mailer 분리는 알림 발송
큐·재시도·장애를 Mattermost의 글 작성 경로에서 격리합니다. 계정 메일을 보내는
Mattermost 본체와 Mailer는 같은 프로젝트 SMTP 설정을 사용합니다. Mattermost 기본
일반 메시지 이메일 알림은 중복을 막기 위해 비활성화합니다.

신규 설치의 notifier는 여러 프로젝트를 구분할 수 있도록 프로젝트 도메인과
Team·채널 표시명을 이메일에 포함하고 메시지 본문·작성자·첨부파일명은 제외합니다.
비공개 채널명도 OCI Email Delivery와 수신자 메일함에 남으므로, 채널명 자체가 기밀인
배포는 문서화된 `generic` 모드를 선택해야 합니다.

백업은 기본 서비스 설치와 분리된 승인 단계입니다. 최초 수동 백업의 원격 검증과
폐기 가능한 새 VM 복구시험을 마치기 전에는 예약 타이머를 활성화하지 않습니다.
전체 절차와 RPO·RTO 한계는 [백업 및 복구 운영 가이드](./deploy/docs/backup-restore.md)를
따릅니다.

```bash
sudo apt-get update
sudo apt-get install -y ruby
./deploy/scripts/validate.sh
```

`validate.sh`의 정확한 Compose 모델 검증에는 Docker Compose 또는 Ruby 중 하나가
필요합니다. 깨끗한 Ubuntu 24.04에서는 위 `ruby` 패키지를 먼저 설치합니다. 이미 Docker
Compose가 있는 호스트에는 Ruby가 필요하지 않습니다. GitHub Actions에서는 Docker
Compose, ShellCheck, 고정 이미지 manifest와 NGINX 설정을 추가 검증합니다.

## 보안

다음 정보는 저장소에 커밋하지 않습니다.

- 실제 `.env`
- 데이터베이스와 SMTP 자격 증명
- OCI OCID, 실제 공인 IP와 관리자 IP
- 실제 고객 도메인과 이메일
- SSH·TLS 개인키
- MFA 복구정보
- 운영 로그, 메시지, 첨부파일과 PostgreSQL 데이터

공개 저장소의 구성 예시는 반드시 placeholder와 `.env.example`만 사용해야 합니다.

## 라이선스와 상표

이 저장소의 자체 문서와 배포 구성은 [MIT License](./LICENSE)로 제공합니다.

즉시 채널 이메일 알림은 Mattermost Team Edition에서 공식 지원하는 공개 플러그인
API만 사용하며, Enterprise 전용 기능을 활성화하거나 라이선스 검사를 우회하지
않습니다. 플러그인·Mailer의 자체 라이선스, 전체 Go 의존성, MPL 소스 제공 안내와
원문 고지는 [notifier 라이선스 및 제3자 고지](./notifier/THIRD_PARTY_NOTICES.md)에서
확인할 수 있습니다.

Mattermost 소프트웨어는 Mattermost의 라이선스와 상표정책을 따릅니다. ThreadHub는
Mattermost, Inc.의 공식 제품이 아니며 Mattermost와 제휴하거나 보증받은 프로젝트가
아닙니다. 고지는 기술적 준수 기준이며 개별 고객 계약에 대한 법률 자문을 대신하지
않습니다.
