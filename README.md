# ThreadHub

ThreadHub는 프로젝트별 고객 커뮤니케이션과 의사결정 이력을 채널과 스레드로 관리하기 위한 셀프호스팅 협업 환경입니다.

Mattermost Team Edition을 기반으로 하며, 정보 공유 경계마다 독립된 Oracle Cloud Infrastructure VM을 배포하는 방식을 기본으로 합니다.

## 현재 상태

현재 저장소는 ThreadHub MVP의 요구사항과 구축·검증 기준을 확정한 문서 중심 단계입니다. Docker Compose, NGINX 설정과 배포 스크립트는 문서의 인수조건에 맞춰 순차적으로 추가할 예정입니다.

프로덕션 운영이 검증된 완성 배포본이 아니므로 실제 고객 데이터로 사용하기 전에 구축·검증 계획의 필수 시험을 수행해야 합니다.

## 핵심 기준

- 정보 공유 경계당 독립 OCI Compute VM 1대
- AMD 기반 x86_64, 2 OCPU, 16GB RAM
- Ubuntu Server 24.04 LTS
- Mattermost Team Edition 11.7.7
- PostgreSQL 18.4
- NGINX와 Let’s Encrypt
- OCI Email Delivery
- 인스턴스당 활성 사용자 최대 50명
- 웹, 데스크톱, 공식 iOS·Android 앱 지원
- 모바일 푸시 기본 비활성화
- 자동 백업, 중앙 로깅, 모니터링과 고가용성 미구성

## 문서

- [ThreadHub 제품 요구사항 정의서 v4.1 Final](./docs/threadhub-prd-v4.1-final.md)
- [ThreadHub MVP 구축 및 검증 계획서](./docs/threadhub-mvp-build-validation-plan.md)

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
│   └── scripts/
└── tests/
```

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

Mattermost 소프트웨어는 Mattermost의 라이선스와 상표정책을 따릅니다. ThreadHub는 Mattermost, Inc.의 공식 제품이 아니며 Mattermost와 제휴하거나 보증받은 프로젝트가 아닙니다.
