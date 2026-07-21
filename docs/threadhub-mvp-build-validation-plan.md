# ThreadHub MVP 구축 및 검증 계획서

> 외부 LLM 및 기술 검토자 피드백용 초안<br>
> 문서 버전: v0.2 Verified Review Draft<br>
> 기준일: 2026년 7월 21일

---

# 0. 외부 검토 요청

이 계획서는 프로젝트별 독립 OCI VM에 무료 Mattermost Team Edition을 배포하여 고객 프로젝트 대화 공간으로 사용하는 ThreadHub MVP의 구축·검증 계획이다.

검토자는 다음 관점에서 피드백해 주기 바란다.

1. 기술적으로 잘못되거나 현재 공식 문서와 불일치하는 내용
2. 실제 구축 또는 고객 파일럿에서 장애·보안사고로 이어질 수 있는 누락
3. MVP 범위에 비해 과도하거나 부족한 요구사항
4. Mattermost Team Edition 11.7.7에서 실제 지원 여부를 확인해야 하는 기능
5. 고객 파일럿의 Go/No-Go 조건이 적절한지
6. 프로젝트별 독립 인스턴스 구조가 적절한지
7. 더 단순하거나 안전한 대안
8. 반드시 PRD에 포함할 내용과 운영절차·테스트계획으로 분리할 내용

피드백은 가능하면 다음 형식으로 작성해 주기 바란다.

    [심각도] Critical / High / Medium / Low
    [구분] 사실 오류 / 설계 위험 / 요구사항 누락 / 과도한 요구 / 운영 개선
    [대상] 관련 절 또는 항목
    [의견] 문제 또는 개선점
    [근거] 공식 문서 또는 기술적 이유
    [권장 수정] 최소한의 수정안
    [신뢰도] High / Medium / Low

검토 시 Enterprise 수준의 일반적인 모범 사례를 무조건 MVP 출시 차단조건으로 확대하지 말고, 다음 세 가지를 구분해 판단해 주기 바란다.

- 필수 기능 미충족
- 명시적으로 수용한 MVP 제약
- 운영 안정화 이후 강화할 항목

---

# 1. 계획 개요

| 항목 | 내용 |
| --- | --- |
| 프로젝트명 | ThreadHub |
| 문서 목적 | MVP 구축·검증 및 고객 파일럿 준비 |
| 기준일 | 2026년 7월 21일 |
| 제품 기반 | Mattermost Team Edition |
| 배포 환경 | Oracle Cloud Infrastructure |
| 기본 배포 단위 | 정보 공유 경계당 독립 OCI VM 1개 |
| 운영 규모 | 인스턴스당 활성 사용자 최대 50명 |
| 주요 사용자 | 내부 프로젝트 담당자와 외부 고객 |
| 지원 클라이언트 | 웹, 데스크톱, iOS, Android |
| 모바일 푸시 | MVP 기본 비활성화 |
| 인증 | 이메일 또는 사용자명과 비밀번호 |
| 데이터베이스 | 동일 VM의 PostgreSQL 컨테이너 |
| 파일 저장 | VM Boot Volume의 영구 저장 경로 |
| 백업·복구 | MVP 미제공 |
| 고가용성 | 미제공 |
| SLA | 미제공 |
| 목표 상태 | 제한된 고객 파일럿 운영 가능 |

---

# 2. 목표와 성공 기준

## 2.1 목표

ThreadHub는 프로젝트 기간 동안 고객과 내부 담당자가 다음 정보를 한곳에서 관리할 수 있도록 한다.

- 프로젝트 공지
- 일반 대화
- 진행 상황
- 질문과 답변
- 결정사항과 근거
- 파일 및 외부 링크
- 채널 메시지와 스레드
- 1:1 DM과 그룹 DM
- 과거 메시지 검색

## 2.2 핵심 성공 기준

MVP는 다음 조건을 만족해야 한다.

1. 외부 이메일 사용자를 초대할 수 있다.
2. 초대받지 않은 사용자는 가입할 수 없다.
3. 채널, 스레드, DM, 멘션 및 파일 공유가 동작한다.
4. 한글 메시지를 합의된 시험 말뭉치로 검색할 수 있다.
5. 컨테이너 재생성 후 계정·메시지·첨부파일이 유지된다.
6. 웹·데스크톱·모바일 앱으로 접속할 수 있다.
7. 모바일 앱은 푸시 없이 사용할 수 있다.
8. Mattermost와 PostgreSQL 내부 포트가 인터넷에 노출되지 않는다.
9. VM 재부팅 후 서비스가 자동으로 시작된다.
10. 동일한 배포 패키지로 새 프로젝트 인스턴스를 만들 수 있다.

## 2.3 제품의 한계

ThreadHub는 다음을 보장하지 않는다.

- 인프라 장애 이후 데이터 복구
- 운영자 실수로 삭제된 데이터 복구
- 영구 기록보관
- 무중단 서비스
- 실시간 모바일 푸시 알림
- 규제 산업용 컴플라이언스
- 고급 감사 및 접근제어
- 고객 기기에 저장된 파일의 원격 삭제
- 서비스 수준 계약

ThreadHub는 운영 중 프로젝트 대화 이력을 제공하지만, 영구 기록보관 또는 재해복구 시스템은 아니다.

---

# 3. 확정 범위

## 3.1 포함 범위

- OCI Compute VM
- Ubuntu Server 24.04 LTS
- Docker Engine 및 Docker Compose Plugin
- Mattermost Team Edition
- PostgreSQL
- NGINX
- Let’s Encrypt 및 Certbot
- OCI Email Delivery
- 영구 DB 및 첨부파일 저장 경로
- 웹·데스크톱·모바일 접속
- Team과 기본 채널 구성
- 사용자 초대·비활성화
- 채널 보관·복원
- 배포·운영·종료 절차서
- 기본 로컬 운영 점검

## 3.2 제외 범위

- Mattermost 유료 라이선스
- Enterprise Trial
- SSO
- 유료 Guest
- Mattermost Calls
- 모바일 푸시
- 자체 모바일 앱
- 자체 Push Proxy
- 채널 Export
- Elasticsearch 및 OpenSearch
- 자동 백업
- 복구 자동화
- OCI Logging
- OCI Monitoring
- 자동 장애 알림
- 관리형 PostgreSQL
- Load Balancer
- 다중 VM
- 고가용성
- Kubernetes
- 중앙 로그 수집
- 악성코드 검사
- MDM 및 모바일 원격 삭제

---

# 4. 기술 기준선

| 구성요소 | 기준 |
| --- | --- |
| Ubuntu | Ubuntu Server 24.04 LTS |
| Mattermost | mattermost/mattermost-team-edition:11.7.7 |
| PostgreSQL | postgres:18.4 또는 고정된 명시적 변형 태그 |
| Docker Engine | 29.6.2 |
| Docker Compose | Docker Compose Plugin |
| NGINX | Ubuntu 저장소 버전 |
| TLS | Let’s Encrypt |
| SMTP | OCI Email Delivery |
| CPU | x86_64(AMD) |
| VM | 2 OCPU, 16GB RAM |
| Boot Volume | 50GB 이상 |
| 데이터 저장 | VM의 명시적 영구 경로 |
| 이미지 정책 | 태그와 Digest 모두 기록 |

Mattermost Team Edition은 무료 MIT 라이선스의 셀프호스팅 제품이지만, 공식 문서는 민감한 상업 워크로드에는 권장하지 않는다. ThreadHub는 이를 고려해 일반 프로젝트 대화만 취급하고 고위험·규제 데이터를 제외한다. 자세한 내용은 [Mattermost Editions and Offerings](https://docs.mattermost.com/product-overview/editions-and-offerings.html)를 참고한다.

---

# 5. 인스턴스 분리 원칙

## 5.1 기본 원칙

하나의 ThreadHub 인스턴스에는 서로의 존재와 프로젝트 참여 사실이 노출되어도 되는 사용자만 포함한다.

    Project A
    └── OCI VM A
        ├── Mattermost A
        ├── PostgreSQL A
        ├── Internal Team
        └── Project A Team

    Project B
    └── OCI VM B
        ├── Mattermost B
        ├── PostgreSQL B
        ├── Internal Team
        └── Project B Team

프로젝트 A와 B는 다음 항목을 공유하지 않는다.

- 사용자 계정
- 메시지와 첨부파일
- PostgreSQL 데이터
- 실제 환경변수 파일
- DB 및 SMTP 비밀번호
- Mattermost 관리자 계정
- 도메인 또는 서브도메인
- 프로젝트 종료 시점

## 5.2 실제 분리 기준

분리 기준은 프로젝트명 자체보다 정보 공유 경계다.

    같은 프로젝트이고 모든 참여자가 서로의 존재를 알아도 됨
    → 동일 인스턴스 사용 가능

    같은 프로젝트지만 고객 조직 간 사용자·대화 노출이 금지됨
    → 고객 조직 또는 보안 경계별 인스턴스 분리

Team이나 비공개 채널만으로 서로 신뢰하지 않는 고객 조직을 격리하지 않는다.

## 5.3 공통 재사용 항목

- 동일한 Git 배포 저장소
- Docker Compose 템플릿
- 버전 정의 파일
- NGINX 템플릿
- 설치·배포 스크립트
- 운영·종료 절차
- OCI VCN 및 NSG 설계
- OCI Email Delivery 서비스

---

# 6. 시스템 아키텍처

    웹·데스크톱·모바일 사용자
                  │
                  │ HTTPS 443
                  ▼
           OCI 예약 공인 IP
                  │
                  ▼
                OCI NSG
                  │
                  ▼
    ┌────────────────────────────────┐
    │ OCI Compute VM                 │
    │ Ubuntu Server 24.04 LTS        │
    │                                │
    │ NGINX + Certbot                │
    │        │ 127.0.0.1:8065        │
    │        ▼                       │
    │ Mattermost Team Edition        │
    │        │ Docker 내부 네트워크   │
    │        ▼                       │
    │ PostgreSQL 18.4                │
    │                                │
    │ /srv/threadhub/...             │
    │ DB·설정·첨부파일 영구 저장      │
    └────────────────────────────────┘
                  │
                  └── OCI Email Delivery

## 6.1 네트워크 정책

외부 공개:

- TCP 80: 인증서 발급 및 HTTPS 전환
- TCP 443: ThreadHub
- TCP 22: 관리자 고정 IP만 허용

외부 비공개:

- Mattermost 8065
- PostgreSQL 5432
- Calls 8443
- Docker API

Mattermost는 로컬 인터페이스에만 연결한다.

    ports:
      - "127.0.0.1:8065:8065"

PostgreSQL 서비스에는 호스트 포트 설정을 추가하지 않는다.

---

# 7. 영구 데이터 설계

## 7.1 저장 대상

- PostgreSQL 데이터
- Mattermost 설정
- 첨부파일
- Mattermost 로컬 로그
- 이미지 동작상 필요한 추가 영구 디렉터리

## 7.2 PostgreSQL 18 경로

PostgreSQL 공식 이미지는 18부터 볼륨 정의를 /var/lib/postgresql로 변경했다. 자세한 내용은 [PostgreSQL 공식 Docker 이미지](https://hub.docker.com/_/postgres/)를 참고한다.

기본 설계:

    services:
      postgres:
        image: postgres:18.4
        volumes:
          - /srv/threadhub/postgres:/var/lib/postgresql

과거 PostgreSQL 이미지에서 사용하던 /var/lib/postgresql/data를 무조건 재사용하지 않는다.

PostgreSQL 서비스에 임의의 `user:` 값을 지정하지 않고 공식 entrypoint가 최초 기동 시 데이터 경로를 초기화하고 권한을 설정하도록 한다. 고정한 이미지 Digest에서 실제 `PGDATA`, mount 경로와 소유권을 확인한다. PostgreSQL 18.x에서 이후 메이저 버전으로 전환할 때는 단순 이미지 태그 교체를 금지하고 `pg_dump/restore` 또는 `pg_upgrade` 절차를 사용한다.

## 7.3 Mattermost 경로 예시

    /srv/threadhub/
    ├── postgres/
    └── mattermost/
        ├── config/
        ├── data/
        ├── logs/
        ├── plugins/
        ├── client/
        │   └── plugins/
        └── bleve-indexes/

Mattermost 공식 컨테이너 배포 구성과 동일하게 다음 경로를 모두 명시적 bind mount로 연결한다.

    services:
      mattermost:
        image: mattermost/mattermost-team-edition:11.7.7
        volumes:
          - /srv/threadhub/mattermost/config:/mattermost/config:rw
          - /srv/threadhub/mattermost/data:/mattermost/data:rw
          - /srv/threadhub/mattermost/logs:/mattermost/logs:rw
          - /srv/threadhub/mattermost/plugins:/mattermost/plugins:rw
          - /srv/threadhub/mattermost/client/plugins:/mattermost/client/plugins:rw
          - /srv/threadhub/mattermost/bleve-indexes:/mattermost/bleve-indexes:rw

공식 Mattermost Team Edition 11.7.7 이미지는 기본적으로 `mattermost` 사용자로 실행한다. 최초 기동 전에 위 디렉터리를 생성하고 UID/GID `2000:2000`으로 설정한다.

    sudo mkdir -p /srv/threadhub/mattermost/{config,data,logs,plugins,client/plugins,bleve-indexes}
    sudo chown -R 2000:2000 /srv/threadhub/mattermost

UID/GID와 이미지의 선언 볼륨은 고정한 이미지 Digest에서 다시 확인하고 배포 기록에 남긴다. 공식 사전 빌드 이미지를 사용하는 MVP에서는 PUID/PGID를 변경하기 위한 사용자 정의 이미지 빌드를 수행하지 않는다. 자세한 내용은 [Mattermost 공식 컨테이너 배포](https://docs.mattermost.com/deployment-guide/server/deploy-containers.html)와 [공식 Docker Compose](https://github.com/mattermost/docker/blob/main/docker-compose.yml)를 참고한다.

## 7.4 데이터 유지 범위

보장:

- 컨테이너 재시작
- docker compose down 후 재생성
- Mattermost 이미지 교체
- VM 재부팅
- 채널 보관
- 사용자 비활성화

보장하지 않음:

- 영구 저장 경로 수동 삭제
- Boot Volume 손상
- VM과 Boot Volume 동시 삭제
- 운영자 오삭제
- 보안사고로 인한 데이터 훼손

`docker compose down -v`는 호스트 bind mount 데이터를 삭제하지 않지만 Compose named volume과 컨테이너의 anonymous volume을 삭제한다. ThreadHub의 PostgreSQL과 Mattermost 중요 경로는 모두 bind mount로 구성하며, `docker compose config`와 `docker inspect`에서 mount 유형·source·destination을 확인한다. 정상 운영에서는 향후 구성 변경으로 인한 오삭제를 방지하기 위해 `down -v`를 사용하지 않는다. 자세한 내용은 [Docker Compose down](https://docs.docker.com/reference/cli/docker/compose/down/)을 참고한다.

데이터 삭제 시험은 고객 파일럿 환경이 아닌 폐기 가능한 테스트 인스턴스에서만 수행한다.

---

# 8. 보안 및 데이터 취급 정책

## 8.1 허용 데이터

- 일반 프로젝트 질문과 답변
- 진행 상황
- 결정사항
- 일반 업무 문서
- 공개 또는 프로젝트 공유가 허가된 링크
- 고객이 ThreadHub 참여자에게 공유하도록 승인한 자료

## 8.2 금지 데이터

- 비밀번호
- API 키
- SSH 및 TLS 개인키
- 클라우드 자격 증명
- 주민등록번호 등 고위험 식별정보
- 결제카드 정보
- 의료·금융 규제정보
- 별도 컴플라이언스가 요구되는 자료
- ThreadHub 참여자 전체에게 공개해서는 안 되는 타 고객 정보

## 8.3 관리자 통제

- System Admin 1~2명
- 관리자 비밀번호 16자 이상 권장
- 일반 사용자 최소 비밀번호 12자
- 로그인 실패 횟수 제한
- 계정 공유 금지
- Mattermost System Admin 계정 MFA 등록 필수
- OCI 콘솔 관리자 MFA 필수
- SSH 공개키 인증
- SSH 관리자 IP 제한
- SSH root 직접 로그인 금지
- SSH 비밀번호 로그인 금지
- 실제 환경변수 파일 권한 최소화
- 비밀값 Git 저장 금지

Mattermost Team Edition 11.7.7은 사용자별 선택적 MFA 등록을 지원한다. 모든 사용자에게 MFA를 강제하는 기능은 유료 라이선스 대상이므로 ThreadHub에서는 System Admin 1~2명에 대해 운영 절차로 MFA 등록을 필수화하고 파일럿 시작 전에 등록 상태와 복구 절차를 확인한다. 이 판단은 [Mattermost v11.7.7 MFA 등록 코드](https://github.com/mattermost/mattermost/blob/v11.7.7/server/channels/app/user.go#L870-L925)와 [전역 MFA 강제 검사 코드](https://github.com/mattermost/mattermost/blob/v11.7.7/server/channels/app/authentication.go#L306-L370)를 기준으로 한다. 설정 경로는 [Mattermost MFA 설정](https://docs.mattermost.com/administration-guide/configure/authentication-configuration-settings.html#mfa)을 참고한다.

---

# 9. Mattermost 후보 설정 기준

다음은 초기 설정 후보이며, 실제 적용 여부는 11.7.7 이미지에서 확인한다.

## 9.1 인증

    MM_TEAMSETTINGS_ENABLEUSERCREATION=true
    MM_TEAMSETTINGS_ENABLEOPENSERVER=false
    MM_SERVICESETTINGS_ENABLEEMAILINVITATIONS=true

    MM_EMAILSETTINGS_ENABLESIGNUPWITHEMAIL=true
    MM_EMAILSETTINGS_REQUIREEMAILVERIFICATION=true
    MM_EMAILSETTINGS_ENABLESIGNINWITHEMAIL=true
    MM_EMAILSETTINGS_ENABLESIGNINWITHUSERNAME=true

    MM_PASSWORDSETTINGS_MINIMUMLENGTH=12
    MM_SERVICESETTINGS_MAXIMUMLOGINATTEMPTS=10
    MM_SERVICESETTINGS_ENABLEMULTIFACTORAUTHENTICATION=true
    MM_SERVICESETTINGS_TERMINATESESSIONSONPASSWORDCHANGE=true

의도:

- 이메일 계정 생성을 허용한다.
- 초대 없는 계정 생성은 금지한다.
- 이메일 초대를 허용한다.
- 이메일 확인을 요구한다.
- 로그인 실패 제한을 적용한다.
- 사용자별 MFA 등록 기능을 활성화하고 System Admin 계정에 운영 절차로 적용한다.
- 비밀번호 변경 또는 재설정 시 기존 세션을 종료한다.

설정 근거는 [Mattermost 인증 설정](https://docs.mattermost.com/administration-guide/configure/authentication-configuration-settings.html)을 따른다.

## 9.2 모바일 푸시

    MM_EMAILSETTINGS_SENDPUSHNOTIFICATIONS=false

무료 TPNS는 비상업적 셀프호스팅 고객용이므로 상업용 고객 프로젝트에서는 사용하지 않는다. 자세한 내용은 [Mattermost 푸시 설정](https://docs.mattermost.com/administration-guide/configure/push-notification-server-configuration-settings.html)을 참고한다.

향후 적합한 푸시 방식이 마련된 경우에만 다음 설정을 검토한다.

    MM_EMAILSETTINGS_PUSHNOTIFICATIONCONTENTS=generic_no_channel

이 값은 푸시를 비활성화하는 값이 아니라, 활성화된 푸시에서 본문과 채널명을 제외하는 값이다.

## 9.3 일반 이메일 알림

    MM_EMAILSETTINGS_SENDEMAILNOTIFICATIONS=false
    MM_EMAILSETTINGS_ENABLEPREVIEWMODEBANNER=false

일반 메시지 이메일 알림을 끄더라도 초대·인증·비밀번호 재설정 등 계정 관련 이메일은 발송할 수 있다. 자세한 내용은 [Mattermost 사이트 설정](https://docs.mattermost.com/administration-guide/configure/site-configuration-settings.html)을 참고한다.

## 9.4 사용자와 채널 한도

    MM_TEAMSETTINGS_MAXUSERSPERTEAM=250
    MM_TEAMSETTINGS_MAXCHANNELSPERTEAM=2000

MaxUsersPerTeam은 활성 및 비활성 사용자를 모두 포함하므로 사용자 교체를 고려해 250으로 설정한다. 실제 활성 사용자 수는 운영정책으로 50명 이하를 유지한다.

MaxChannelsPerTeam 2,000은 활성 및 보관 채널을 모두 포함하는 셀프호스팅 기본값이며, 재현 가능한 기준선을 위해 명시적으로 고정한다.

## 9.5 파일 크기

    MM_FILESETTINGS_MAXFILESIZE=26214400

25MiB는 26,214,400바이트다. NGINX의 client_max_body_size는 multipart 요청 여유를 고려해 Mattermost 제한보다 약간 크게 설정하고, 실제 파일 제한은 Mattermost가 적용하도록 한다.

Mattermost 공식 문서도 프록시의 업로드 제한을 함께 조정하도록 안내한다. 자세한 내용은 [Mattermost 파일 저장 설정](https://docs.mattermost.com/administration-guide/configure/environment-configuration-settings.html)을 참고한다.

## 9.6 한글 검색 후보

    MM_FEATUREFLAGS_CJKSEARCH=true

Mattermost v11.7.7 소스에서 CJK 검색 분기는 별도 라이선스 검사 없이 활성화되며, CJK 검색어를 PostgreSQL full-text search가 아닌 `LIKE '%검색어%'` 방식으로 처리한다. 따라서 Team Edition에서도 동작할 가능성이 높고 한글 부분 문자열 검색을 기대할 수 있지만, 공식 CJK 문서는 Team Edition을 지원 플랜에 명시하지 않는다. 정확한 이미지에서 기능과 누적 게시물 수에 따른 성능을 모두 시험한다. 자세한 내용은 [Mattermost CJK 검색](https://docs.mattermost.com/administration-guide/configure/enabling-chinese-japanese-korean-search.html), [v11.7.7 feature flag](https://github.com/mattermost/mattermost/blob/v11.7.7/server/public/model/feature_flags.go#L90-L165), [v11.7.7 검색 구현](https://github.com/mattermost/mattermost/blob/v11.7.7/server/channels/store/sqlstore/post_store.go#L2097-L2218)을 참고한다.

## 9.7 기능 비활성화

다음 기능을 비활성화하거나 미구성한다.

- Calls
- Enterprise Trial
- 유료 라이선스
- 공개 파일 링크
- 사용자 플러그인 업로드
- 불필요한 플러그인
- Incoming Webhook
- Outgoing Webhook
- 외부 링크 미리보기
- 텔레메트리
- 일반 메시지 이메일 알림
- 모바일 푸시

정확한 환경변수와 콘솔 설정 경로는 배포 설계서에서 별도로 검증한다.

---

# 10. Member 권한 검증 계획

Mattermost는 System Permission Scheme을 Team Edition에 제공하며, v11.7.7 웹 애플리케이션 소스에도 라이선스 게이트 없이 System Scheme 편집 경로와 Member 권한 항목이 포함되어 있다. ThreadHub는 System Scheme으로 전역 Member 권한을 제한하는 방식을 1순위로 적용하고 정확한 이미지에서 실제 차단 동작을 확인한다. Team Override Scheme, 채널별 고급 제어 및 supplementary role은 무료 기능으로 전제하지 않는다. 자세한 내용은 [Mattermost System Scheme 공지](https://forum.mattermost.com/t/granular-permissions-coming-soon-to-team-edition/11929), [v11.7.7 관리 콘솔 경로](https://github.com/mattermost/mattermost/blob/v11.7.7/webapp/channels/src/components/admin_console/admin_definition.tsx#L498-L540), [권한 목록 구현](https://github.com/mattermost/mattermost/blob/v11.7.7/webapp/channels/src/components/admin_console/permission_schemes_settings/permissions_tree/permissions_tree.tsx#L55-L115)을 참고한다.

## 10.1 확인 대상

고객 Member 계정으로 다음 권한을 확인한다.

- 사용자 이메일 초대
- Team 사용자 추가
- Team 생성
- 공개 채널 생성
- 비공개 채널 생성
- 비공개 채널 사용자 추가·제거
- 다른 Team 사용자 검색
- 다른 Team 사용자와 DM
- 플러그인 및 Webhook 생성
- Team 설정 변경
- System Console 접근

## 10.2 System Scheme 적용

전역으로 제한 가능한 권한을 제거한다.

우선 검토 대상:

- 사용자 초대
- Team 사용자 추가
- Team 생성
- 공개 채널 생성
- 비공개 채널 생성
- Webhook 및 통합 생성

전역 제한은 내부 일반 Member에게도 적용될 수 있으므로, 채널·Team 생성은 관리자 요청 방식으로 운영한다.

## 10.3 정확한 이미지에서 일부 권한을 제한할 수 없는 경우

운영 통제를 적용한다.

    초대 기간 시작
    → 이메일 초대 활성화
    → 관리자가 사용자 초대
    → 사용자 명단 확인
    → 이메일 초대 비활성화
    → Team 초대 코드 폐기 또는 재생성
    → 미수락 초대 확인
    → 비초대 이메일 가입 실패 시험

이 방식은 완전한 기술적 접근제어가 아니라 소규모·단기 프로젝트를 위한 보완 통제다.

---

# 11. 구축 단계

## Phase 0. 계획 승인

### 작업

- 프로젝트와 정보 공유 경계 확인
- 예상 사용자 수 확인
- 고객 조직 간 격리 필요 여부 확인
- 허용 데이터와 금지 데이터 확인
- 장애 복구 미보장 합의
- 도메인과 서브도메인 결정
- OCI 리전 결정
- 시스템 관리자 지정
- 프로젝트 종료 후 데이터 유지 여부 결정

### 산출물

- 승인된 프로젝트 범위
- 인스턴스 분리 결정
- 데이터 취급 기준
- 운영 책임자
- 고객 파일럿 대상 명단

### 완료 조건

- 하나의 인스턴스에 포함될 사용자 범위가 명확하다.
- 서로 격리되어야 하는 고객 조직이 같은 인스턴스에 들어가지 않는다.
- 백업과 장애 복구 미제공이 합의된다.

## Phase 1. 배포 패키지 준비

### 저장소 구조

    threadhub-deploy/
    ├── docker-compose.yml
    ├── .env.example
    ├── versions.env
    ├── .gitignore
    ├── nginx/
    │   └── threadhub.conf
    ├── scripts/
    │   ├── install-docker.sh
    │   ├── deploy.sh
    │   ├── status.sh
    │   └── destroy.sh
    └── docs/
        ├── setup.md
        ├── test-plan.md
        ├── admin-guide.md
        ├── operations-checklist.md
        └── project-close.md

### 작업

- 이미지 태그 명시
- 실제 Digest 기록 방식 정의
- PostgreSQL 18 볼륨 경로 적용
- Mattermost 공식 영구 디렉터리 6개 정의
- Mattermost 이미지 실행 UID/GID와 선언 볼륨 확인
- 컨테이너 재시작 정책 설정
- PostgreSQL health check 추가
- Mattermost 시작 순서 정의
- 환경변수 예제 작성
- 실제 환경변수 파일 Git 제외
- 배포·상태 확인·종료 명령 표준화

### 완료 조건

- 비밀정보 없이 저장소를 공유할 수 있다.
- docker compose config가 성공한다.
- 모든 이미지에 명시적 태그가 있다.
- PostgreSQL 볼륨이 /var/lib/postgresql에 연결된다.
- Mattermost 중요 경로가 모두 명시적 bind mount에 연결된다.
- Mattermost bind mount가 UID/GID 2000:2000으로 설정된다.

## Phase 2. OCI 인프라 구성

### 작업

- OCI Compute VM 생성
- Ubuntu 24.04 LTS 적용
- AMD 기반 x86_64, 2 OCPU·16GB RAM 구성
- Boot Volume 50GB 이상 구성
- 예약 공인 IP 연결
- Public Subnet 연결
- NSG 구성
- SSH 공개키 등록
- SSH 관리자 IP 제한
- DNS A 레코드 등록

### 완료 조건

- SSH 키로만 접속할 수 있다.
- 관리자 IP 외의 TCP 22 접근이 차단된다.
- TCP 80과 443만 인터넷에 공개된다.
- TCP 8065와 5432가 외부에서 차단된다.
- DNS가 VM 공인 IP를 가리킨다.

## Phase 3. Docker 및 애플리케이션 배포

### 작업

- Docker Engine 설치
- Docker Compose Plugin 설치
- 배포 저장소 복제
- PostgreSQL과 Mattermost 영구 디렉터리 생성
- Mattermost 6개 영구 디렉터리의 소유권을 2000:2000으로 설정
- 프로젝트별 환경변수 파일 생성
- PostgreSQL 시작
- Mattermost 시작
- DB 연결 확인
- 컨테이너 재시작 정책 확인

### 완료 조건

- PostgreSQL health check가 정상이다.
- Mattermost가 PostgreSQL에 연결된다.
- Mattermost 8065는 127.0.0.1에서만 열린다.
- PostgreSQL은 호스트 포트로 공개되지 않는다.
- `docker inspect`에서 PostgreSQL과 Mattermost 중요 경로가 예상한 bind mount로 표시된다.
- Mattermost 로그에 영구 경로 `permission denied` 오류가 없다.
- VM 재부팅 후 컨테이너가 자동 시작된다.

## Phase 4. NGINX와 HTTPS

### 작업

- NGINX 설치
- Mattermost 공식 프록시 요구사항 반영
- WebSocket 프록시 구성
- HTTP에서 HTTPS 전환
- Certbot 설치
- 인증서 발급
- 자동 갱신 타이머 확인
- 인증서 갱신 시험
- 업로드 제한 및 timeout 조정

### 완료 조건

- 지정 도메인으로 HTTPS 접속할 수 있다.
- HTTP 접속이 HTTPS로 전환된다.
- 브라우저 인증서 경고가 없다.
- WebSocket 연결이 정상이다.
- 인증서 자동 갱신 설정이 활성화돼 있다.

## Phase 5. OCI Email Delivery

### 작업

- SMTP Credentials 생성
- Approved Sender 등록
- SPF 구성
- DKIM 구성
- 리전별 SMTP 엔드포인트 확인
- SMTP 587·STARTTLS 구성
- Mattermost SMTP 연결시험
- OCI suppression 목록 확인 절차 작성

### 시험 대상

- 사용자 초대
- 이메일 주소 확인
- 비밀번호 재설정
- 계정 비활성화 관련 메일
- Gmail
- 네이버 메일
- 다음 메일
- 가능하면 고객사 업무 이메일

OCI Email Delivery의 기본 절차는 [OCI Email Delivery 시작 안내](https://docs.oracle.com/en-us/iaas/Content/Email/Reference/gettingstarted.htm)를 참고한다.

### 완료 조건

- 초대 메일이 수신된다.
- 이메일 확인 링크가 동작한다.
- 비밀번호 재설정 링크가 동작한다.
- Gmail·네이버·다음 시험 메일에서 SPF와 DKIM 결과가 `pass`다.
- 받은편지함 또는 스팸함의 수신 위치를 기록한다.
- 일반 메시지 이메일 알림은 발송되지 않는다.
- SMTP 비밀번호가 Git에 저장되지 않는다.

## Phase 6. Mattermost 기본 설정

### 작업

- Site URL 설정
- 초대 전용 가입 설정
- 이메일 확인 활성화
- 최소 비밀번호 길이 설정
- 로그인 실패 제한
- 비밀번호 변경·재설정 시 기존 세션 종료
- 사용자별 MFA 활성화
- System Admin 계정 MFA 등록
- System Scheme에서 일반 Member의 초대·Team 생성·공개/비공개 채널 생성 권한 제한
- Team 초대 URL 비배포 및 초대 기간 종료 후 코드 재생성
- 모바일 푸시 비활성화
- 일반 메시지 이메일 알림 비활성화
- Calls 비활성화
- Enterprise Trial 비활성 확인
- 파일 크기 25MiB 설정
- 공개 파일 링크 비활성화
- 외부 링크 미리보기 비활성화
- 사용자 플러그인 업로드 비활성화
- 불필요한 통합과 Webhook 비활성화
- Team 최대 사용자 250
- Team 최대 채널 2,000
- 활성 사용자 운영 상한 50명

### 완료 조건

- 초대받지 않은 이메일은 가입할 수 없다.
- 초대받은 사용자는 이메일 확인 후 가입할 수 있다.
- 유효한 Team 초대 URL은 가입에 사용할 수 있고, 코드 재생성 후 이전 URL은 사용할 수 없다.
- System Admin 계정이 MFA로 로그인할 수 있다.
- 비밀번호 재설정 후 기존 웹·데스크톱·모바일 세션이 종료된다.
- 고객 Member는 사용자 초대·Team 생성·공개/비공개 채널 생성을 할 수 없다.
- 모바일 푸시가 비활성화돼 있다.
- Calls를 시작할 수 없다.
- Enterprise Trial이 활성화되지 않는다.
- 25MiB 초과 파일이 거부된다.

## Phase 7. Team과 채널 구성

### Team

    Internal
    Project

### 기본 채널

    00-공지
    01-프로젝트-일반
    02-진행상황
    03-결정사항
    04-질문-답변
    05-자료공유

### 작업

- Internal Team 생성
- Project Team 생성
- 기본 채널 생성
- 고객 Member 추가
- 내부 담당자 추가
- 고객에게 관리자 권한이 없는지 확인
- 채널별 목적과 운영규칙 게시
- 중요한 결정을 DM에만 남기지 않는 규칙 게시
- 모바일 푸시 미제공 안내 게시
- 장애 복구 미보장 안내 게시

### 완료 조건

- 고객은 Project Team의 허용된 채널만 사용할 수 있다.
- 고객에게 Team Admin 및 System Admin 권한이 없다.
- Internal Team의 채널 내용에 접근할 수 없다.
- 사용자 검색·DM·초대 권한의 실제 동작이 기록된다.

---

# 12. 상세 검증 계획

## 12.1 인증

| ID | 시험 | 기대 결과 |
| --- | --- | --- |
| AUTH-01 | 유효한 이메일 초대 토큰으로 외부 사용자 가입 | 성공 |
| AUTH-02 | 초대 토큰과 Team InviteId 없이 직접 가입 | 실패 |
| AUTH-03 | 이메일 확인 전 로그인 | 실패 |
| AUTH-04 | 이메일 확인 후 로그인 | 성공 |
| AUTH-05 | 사용자명 로그인 | 성공 |
| AUTH-06 | 이메일 로그인 | 성공 |
| AUTH-07 | 12자 미만 비밀번호 | 거부 |
| AUTH-08 | 로그인 연속 실패 | 설정 횟수에서 잠금 |
| AUTH-09 | 비밀번호 재설정 | 성공 |
| AUTH-10 | 계정 비활성화 후 로그인 | 실패 |
| AUTH-11 | 계정 재활성화 후 로그인 | 성공 |
| AUTH-12 | 사용 완료된 이메일 초대 토큰 재사용 | 실패 |
| AUTH-13 | 관리자가 무효화한 미수락 이메일 초대 토큰 사용 | 실패 |
| AUTH-14 | 유효한 Team 초대 URL로 가입 | 성공 |
| AUTH-15 | Team 초대 코드 재생성 후 이전 URL 사용 | 실패 |
| AUTH-16 | 재생성된 새 Team 초대 URL 사용 | 성공 |
| AUTH-17 | System Admin MFA 등록 및 정상 OTP 로그인 | 성공 |
| AUTH-18 | 잘못된 OTP로 System Admin 로그인 | 실패 |
| AUTH-19 | System Admin MFA 복구 절차 확인 | 절차와 결과 기록 |
| AUTH-20 | 비밀번호 재설정 후 기존 웹·데스크톱·모바일 세션 사용 | 모두 종료되며 새 비밀번호와 MFA 로그인이 필요 |

`EnableOpenServer=false`는 초대가 없는 직접 가입을 차단하지만 유효한 Team InviteId를 정상 초대로 처리한다. Team 초대 URL은 링크를 가진 사람이 사용할 수 있는 bearer invitation이므로 고객에게 배포하지 않고 노출 가능성이 있거나 초대 기간이 끝나면 코드를 재생성한다. 분기 동작은 [Mattermost v11.7.7 사용자 생성 핸들러](https://github.com/mattermost/mattermost/blob/v11.7.7/server/channels/api4/user.go)와 [초대 URL 안내](https://docs.mattermost.com/end-user-guide/collaborate/invite-people.html)를 기준으로 한다.

## 12.2 권한

| ID | 시험 | 기대 결과 또는 기록 |
| --- | --- | --- |
| PERM-01 | 고객의 System Console 접근 | 실패 |
| PERM-02 | 고객의 Team Admin 기능 접근 | 실패 |
| PERM-03 | 고객의 사용자 초대 | 실패 |
| PERM-04 | 고객의 Team 생성 | 실패 |
| PERM-05 | 고객의 공개 채널 생성 | 실패 |
| PERM-06 | 고객의 비공개 채널 생성 | 실패 |
| PERM-07 | 비공개 채널 멤버 변경 | 실제 동작 기록 |
| PERM-08 | Internal Team 사용자 검색 | 실제 노출 범위 기록 |
| PERM-09 | 다른 Team 사용자 DM | 실제 동작 기록 |
| PERM-10 | Webhook 및 통합 생성 | 실패 또는 비활성 확인 |

System Scheme 적용 후 고객 Member 계정으로 다시 시험한다. 정확한 이미지에서 일부 권한을 기술적으로 제한할 수 없는 경우에만 운영정책과 인스턴스 분리로 수용 가능한지 별도 판단한다.

## 12.3 한글 검색

다음 메시지를 서로 다른 채널과 스레드에 작성한다.

    오류
    로그인 오류
    고객로그인오류
    고객 로그인 오류가 발생했습니다
    로그인오류를 확인했습니다
    API 오류 401
    고객-A 로그인 2026
    데이터베이스 연결 실패
    결정사항: 다음 주에 배포한다

| ID | 시험 |
| --- | --- |
| SEARCH-01 | 오류 검색 |
| SEARCH-02 | 로그인 오류 검색 |
| SEARCH-03 | 고객로그인오류 검색 |
| SEARCH-04 | 조사가 붙은 단어 검색 |
| SEARCH-05 | 한글·영문·숫자 혼합 검색 |
| SEARCH-06 | 채널 필터 |
| SEARCH-07 | 작성자 필터 |
| SEARCH-08 | 스레드 답글 검색 |
| SEARCH-09 | 수정된 메시지 검색 |
| SEARCH-10 | 파일명 검색 |
| SEARCH-11 | 검색 결과에서 원문 이동 |
| SEARCH-12 | 검색 결과에서 스레드 이동 |
| SEARCH-13 | 대표 누적 게시물 수에서 반복 검색 응답시간 기록 |

필수 부분 문자열 시험으로 `오류` 검색 시 `로그인 오류`, `고객로그인오류`, `로그인오류를 확인했습니다` 게시물이 모두 반환되는지 확인한다. 검색 성능은 활성 사용자 수가 아니라 누적 게시물 수의 영향을 받을 수 있으므로 파일럿을 대표하는 데이터 규모에서 측정한다.

판정:

- 합의된 시나리오 전체 통과: Go
- 일부 제한이 있으나 업무상 수용 가능: 제한을 문서화하고 재판정
- 핵심 한글 검색 불가: 고객 파일럿 No-Go

## 12.4 데이터 영속성

| ID | 시험 | 기대 결과 |
| --- | --- | --- |
| DATA-01 | Mattermost 재시작 | 데이터 유지 |
| DATA-02 | PostgreSQL 재시작 | 데이터 유지 |
| DATA-03 | docker compose down 후 재생성 | 데이터 유지 |
| DATA-04 | Mattermost 이미지 재생성 | 데이터 유지 |
| DATA-05 | PostgreSQL 컨테이너 재생성 | 데이터 유지 |
| DATA-06 | VM 재부팅 | 자동 시작 및 데이터 유지 |
| DATA-07 | 파일 다운로드 | 기존 파일 다운로드 성공 |
| DATA-08 | 사용자 비활성화 | 기존 메시지 유지 |
| DATA-09 | 채널 보관 | 기록 유지 |
| DATA-10 | 채널 복원 | 다시 메시지 작성 가능 |
| DATA-11 | PostgreSQL 및 Mattermost 컨테이너 mount 검사 | 모든 중요 경로가 예상한 bind mount |
| DATA-12 | Mattermost 영구 경로 소유권과 쓰기 시험 | UID/GID 2000:2000, 쓰기 성공 |
| DATA-13 | config·plugins·client/plugins 경로 재생성 시험 | 경로와 시험 파일 유지 |
| DATA-14 | Mattermost anonymous volume 검사 | 중요 경로에 anonymous volume 없음 |
| DATA-15 | PostgreSQL 최초 초기화와 mount 검사 | 권한 오류 없음, `/var/lib/postgresql` bind mount와 실제 `PGDATA` 기록 |

`docker compose down -v`는 고객 파일럿 또는 실제 프로젝트 환경의 영속성 시험에 사용하지 않는다. 폐기 가능한 기술 시험 환경에서는 bind mount 데이터가 유지되고 named·anonymous volume만 제거되는지 별도로 확인할 수 있다.

## 12.5 모바일

| ID | 시험 | 기대 결과 |
| --- | --- | --- |
| MOB-01 | iOS 공식 앱 로그인 | 성공 |
| MOB-02 | Android 공식 앱 로그인 | 성공 |
| MOB-03 | 채널 메시지 | 성공 |
| MOB-04 | 스레드 답글 | 성공 |
| MOB-05 | DM | 성공 |
| MOB-06 | 파일 업로드 | 성공 |
| MOB-07 | 파일 다운로드 | 성공 |
| MOB-08 | 앱 종료 중 새 메시지 작성 | 푸시 미수신 |
| MOB-09 | 앱을 다시 열기 | 최신 메시지 동기화 |
| MOB-10 | 계정 비활성화 후 재로그인 | 실패 |

## 12.6 파일

| ID | 시험 | 기대 결과 |
| --- | --- | --- |
| FILE-01 | 25MiB 미만 파일 | 성공 |
| FILE-02 | 경계 크기 파일 | 정의된 기준에 따라 성공 |
| FILE-03 | 25MiB 초과 파일 | 거부 |
| FILE-04 | 채널 파일 다운로드 | 성공 |
| FILE-05 | DM 파일 다운로드 | 성공 |
| FILE-06 | 공개 파일 링크 생성 | 불가 |
| FILE-07 | 컨테이너 재생성 후 파일 | 유지 |

## 12.7 네트워크와 보안

| ID | 시험 | 기대 결과 |
| --- | --- | --- |
| NET-01 | 외부 TCP 80 | 접근 후 HTTPS 전환 |
| NET-02 | 외부 TCP 443 | 성공 |
| NET-03 | 외부 TCP 8065 | 실패 |
| NET-04 | 외부 TCP 5432 | 실패 |
| NET-05 | 외부 TCP 8443 | 실패 |
| NET-06 | 비관리자 IP의 SSH | 실패 |
| NET-07 | SSH 비밀번호 로그인 | 실패 |
| NET-08 | SSH root 로그인 | 실패 |
| NET-09 | HTTPS 인증서 검증 | 성공 |
| NET-10 | WebSocket 연결 | 성공 |

---

# 13. 운영 점검 계획

중앙 모니터링 시스템은 구축하지 않지만 다음 항목을 수동 점검한다.

## 13.1 정기 점검

- Boot Volume 사용률
- /srv/threadhub 사용량
- Docker 컨테이너 상태
- 컨테이너 재시작 횟수
- Mattermost health 상태
- PostgreSQL health 상태
- NGINX 상태
- HTTPS 인증서 만료일
- Certbot 갱신 타이머
- SMTP 실패 로그
- OCI suppression 목록
- Docker 로그 크기
- NGINX 로그 크기
- 시스템 로그 회전 상태

## 13.2 권장 점검 주기

| 시점 | 점검 |
| --- | --- |
| 배포 직후 | 전체 항목 |
| 설정 변경 후 | 관련 서비스 및 기능 |
| VM 재부팅 후 | 컨테이너·HTTPS·데이터 |
| 주 1회 | 디스크·컨테이너·인증서·SMTP |
| 프로젝트 종료 전 | 사용자·채널·데이터 유지 결정 |

## 13.3 확장 기준

초기 사양은 2 OCPU·16GB로 운영한다. 다음 중 하나가 반복되면 CPU·메모리·Boot Volume 사용량을 확인하고 더 큰 AMD 기반 x86_64 Flex Shape 또는 더 큰 볼륨으로 수직 확장한다.

- 메모리 부족으로 컨테이너 종료
- 응답 지연
- 검색 지연
- 파일 업로드 중 전체 서비스 지연
- 디스크 사용률 지속 증가
- PostgreSQL 또는 Mattermost의 반복 재시작

---

# 14. 파일럿 계획

## 14.1 내부 기술 파일럿

참여자:

- 시스템 관리자 1명
- 내부 담당자 1~2명

사용 데이터:

- 가상 고객 및 테스트 데이터
- 실제 중요 고객자료 사용 금지

목적:

- 설치 및 재배포
- 영속성
- 가입 및 이메일
- 권한
- 한글 검색
- 모바일 푸시 비활성화
- 종료 절차

판정:

- 내부 파일럿은 현재 계획으로 Go
- 핵심 기능 실패 시 수정 후 반복

## 14.2 제한된 고객 파일럿

참여자:

- 시스템 관리자 1명
- 내부 담당자 1~2명
- 고객 사용자 1~2명

권장 기간:

- 1~2주
- 프로젝트 특성에 따라 조정

고객 안내:

- 모바일 푸시가 제공되지 않음
- 긴급 연락은 별도 수단 사용
- 백업 및 장애 복구가 보장되지 않음
- 고위험·규제 데이터 업로드 금지
- 고객 기기에 저장한 파일은 원격 회수되지 않음
- 고객에게 관리자 권한이 없음

---

# 15. 고객 파일럿 Go/No-Go 조건

## 15.1 Go 조건

1. 정보 공유 경계별 독립 인스턴스를 사용한다.
2. 유효한 이메일 초대 사용자의 가입이 성공하고 초대 없는 직접 가입이 실패한다.
3. Team 초대 URL의 사용·재생성·이전 URL 무효화 시험이 기대 결과와 일치한다.
4. System Scheme 적용 후 고객 Member의 초대·Team 생성·공개/비공개 채널 생성이 차단된다.
5. 정확한 이미지에서 제한할 수 없는 권한이 있다면 위험과 운영 통제를 별도로 승인한다.
6. System Admin 계정 1~2명이 MFA 등록·로그인·복구 시험을 통과한다.
7. 한글 부분 문자열 검색과 대표 데이터 규모의 검색 시험을 통과한다.
8. PostgreSQL 재생성 후 데이터가 유지된다.
9. Mattermost 설정·첨부파일·플러그인 관련 경로가 모두 명시적 bind mount이며 재생성 후 유지된다.
10. Mattermost 영구 경로가 UID/GID 2000:2000으로 설정되고 쓰기 시험을 통과한다.
11. 모바일 푸시가 비활성화돼 있다.
12. 앱을 열면 최신 메시지가 동기화된다.
13. OCI 초대·확인·비밀번호 재설정 메일이 Gmail·네이버·다음에서 동작하고 SPF·DKIM이 통과한다.
14. 8065와 5432가 외부에 노출되지 않는다.
15. VM 재부팅 후 서비스가 자동 시작된다.
16. 디스크·컨테이너·인증서·SMTP 점검 절차가 준비된다.
17. 고객에게 복구 미보장과 데이터 취급 제한이 안내된다.

## 15.2 No-Go 조건

- 초대 없이 누구나 계정을 만들 수 있음
- 재생성한 Team 초대 코드의 이전 URL로 가입할 수 있음
- 고객이 관리자 권한을 획득할 수 있음
- 고객 Member가 사용자 초대·Team 생성·공개/비공개 채널 생성을 할 수 있음
- 서로 격리되어야 하는 고객이 같은 인스턴스에 포함됨
- 핵심 한글 검색이 실질적으로 동작하지 않음
- 컨테이너 재생성 후 DB 또는 파일이 사라짐
- Mattermost 중요 경로가 익명 볼륨에 연결되거나 권한 오류로 쓰기 실패
- System Admin MFA가 등록되지 않거나 복구 절차가 확인되지 않음
- PostgreSQL 또는 Mattermost 포트가 인터넷에 노출됨
- HTTPS 없이 서비스가 공개됨
- 모바일 푸시가 의도치 않게 활성화됨
- 초대·확인·비밀번호 재설정 이메일이 동작하지 않거나 SPF·DKIM 검증에 실패함

---

# 16. 프로젝트 종료 계획

## 16.1 기록 유지

    종료 일정 안내
    → 최종 논의 확인
    → 고객 계정 비활성화
    → 채널 보관
    → DNS 및 SMTP 정책 확인
    → VM 또는 Boot Volume 유지

## 16.2 완전 폐기

    폐기 대상 프로젝트 확인
    → 필요한 자료 확인
    → 고객 계정 비활성화
    → DNS 레코드 제거
    → SMTP 자격 증명 폐기 또는 교체
    → OCI VM 삭제
    → Boot Volume 삭제
    → 예약 공인 IP 해제 또는 재사용

완전 폐기 후 프로젝트 메시지와 첨부파일은 복구되지 않는다.

파괴적 종료 절차는 다음을 기록한다.

- 대상 프로젝트명
- OCI 인스턴스 OCID
- 도메인
- Boot Volume OCID
- 종료 방식
- 실행자
- 실행 일시
- 볼륨 유지 또는 삭제 결과

---

# 17. 주요 위험과 대응

| 위험 | 영향 | 대응 | 출시 차단 |
| --- | --- | --- | --- |
| CJK 검색 기능 또는 성능 미달 | 핵심 검색 기능 실패·지연 | 정확한 이미지와 대표 데이터 규모 시험 | 예 |
| 초대 없는 가입 또는 초대 URL 관리 실패 | 비인가 사용자 접근 | 가입 경로별 시험과 초대 코드 재생성 | 예 |
| System Scheme 설정 누락 또는 일부 Member 권한 제한 불가 | 임의 초대·Team·채널 생성 | System Scheme 적용과 고객 Member 시험, 필요 시 운영 통제 | 예 또는 조건부 |
| PostgreSQL 볼륨 경로 오류 | 데이터 손실 | PG18 경로와 재생성 시험 | 예 |
| Mattermost bind mount 누락 또는 권한 오류 | 시작 실패·숨은 익명 볼륨·상태 손실 | 공식 6개 경로 bind mount와 UID/GID 2000:2000 검증 | 예 |
| 백업 없음 | 장애 시 전체 데이터 손실 | 명시적 위험 수용과 고객 안내 | 아니오 |
| System Admin MFA 미등록 | 관리자 계정 탈취 위험 증가 | 선택적 MFA 활성화와 관리자 등록·복구 시험 | 예 |
| 모바일 푸시 없음 | 메시지 확인 지연 | 사용자 안내와 별도 긴급 연락 | 아니오 |
| 디스크 고갈 | DB 및 서비스 장애 | 주기적 디스크 점검 | 조건부 |
| 인증서 만료 | 접속 장애 | Certbot 갱신 확인 | 조건부 |
| SMTP 차단·억제 | 초대·재설정 실패 | 발송시험 및 suppression 점검 | 예 |
| 복수 고객 조직의 오배치 | 고객 간 정보 노출 | 정보 공유 경계별 인스턴스 | 예 |
| 환경변수 파일 유출 | DB·SMTP 탈취 | Git 제외와 파일 권한 제한 | 예 |
| VM 사양 부족 | 응답 지연 | 파일럿 측정 후 수직 확장 | 아니오 |
| 버전 취약점 | 보안사고 | 배포 전 패치 확인 | 조건부 |

---

# 18. 예상 산출물

- docker-compose.yml
- .env.example
- versions.env
- NGINX 설정
- Docker 설치 스크립트
- 배포 스크립트
- 상태 점검 스크립트
- 프로젝트 종료 스크립트 또는 절차
- 설치 가이드
- 관리자 가이드
- 사용자 초대 절차
- 운영 체크리스트
- 테스트 계획 및 결과
- 프로젝트 종료 절차
- 이미지 태그와 Digest 기록
- 실제 적용 설정 목록
- 고객 파일럿 Go/No-Go 기록

---

# 19. 예상 일정

다음 일정은 숙련된 담당자 1명이 수행하고 OCI·DNS·메일 승인 대기시간을 제외한 대략적인 작업량이다.

| 단계 | 예상 작업량 |
| --- | ---: |
| 계획·보안 경계 확정 | 0.5~1일 |
| 배포 패키지 작성 | 1~2일 |
| OCI 및 네트워크 | 0.5~1일 |
| Docker·Mattermost·PostgreSQL | 1~2일 |
| NGINX·HTTPS | 0.5~1일 |
| OCI Email Delivery | 0.5~1.5일 |
| Mattermost 기본 설정 | 0.5~1일 |
| Team·채널 구성 | 0.5일 |
| 기술 검증 | 2~3일 |
| 내부 파일럿 | 2~3일 |
| 고객 파일럿 | 1~2주 |
| 종료·재배포 시험 | 1일 |

실제 일정은 OCI Email Delivery 한도·발신자 승인, DNS 전파 및 발견된 Team Edition 제한에 따라 달라질 수 있다.

---

# 20. 집중 피드백 요청사항

검토자는 특히 다음 질문에 답해 주기 바란다.

1. 프로젝트가 아니라 정보 공유 경계별로 VM을 분리하는 원칙이 충분한가?
2. 최대 50명·단기·일반 대화라는 조건에서 Team Edition 선택이 합리적인가?
3. Mattermost Team Edition 11.7.7의 System Scheme에서 계획한 Member 권한이 실제로 모두 차단되는가?
4. 일부 Member 권한을 System Scheme으로 제한할 수 없다면 초대 기능 일시 활성화 방식이 충분한가?
5. 한글 검색 기능 또는 성능이 합의 기준에 미달할 경우 무료 범위 안의 현실적인 대안이 있는가?
6. PostgreSQL 18.4 볼륨 설계에 누락된 부분이 있는가?
7. 백업과 장애 복구 미보장을 명시하면 고객 파일럿 출시가 가능한가?
8. 전 사용자 MFA 강제 없이 System Admin 계정에 운영 절차로 MFA를 적용하는 방식이 충분한가?
9. 모바일 푸시 비활성화 방식에 누락된 설정이 있는가?
10. 로컬 운영 점검 항목이 단일 VM MVP에 충분한가?
11. 현재 Go/No-Go 조건 중 과도하거나 부족한 항목은 무엇인가?
12. PRD에 남길 내용과 배포설계·테스트계획·운영절차로 이동할 내용을 구분해 달라.
13. 현재 버전 조합에서 알려진 호환성 문제가 있는가?
14. 실제 고객 파일럿 전에 반드시 추가해야 할 최소 조건이 있는가?

---

# 21. 검토 결과 반영 원칙

외부 피드백은 다음 기준으로 분류한다.

| 분류 | 처리 |
| --- | --- |
| 사실 오류 | 공식 문서를 확인한 뒤 즉시 수정 |
| 필수 기능 실패 가능성 | 고객 파일럿 출시 게이트에 반영 |
| 합의된 제약의 위험 | 위험 수용 문구와 보완 통제 검토 |
| 운영 모범 사례 | 운영 절차서 또는 후속 단계로 이동 |
| Enterprise 기능 전제 | 무료 Team Edition에서 가능한지 재검증 |
| 과도한 범위 확대 | MVP 목표에 직접 필요하지 않으면 제외 |

최종 판단은 기술적 위험의 존재 여부만으로 결정하지 않고 다음을 함께 고려한다.

- 프로젝트 기간
- 사용자 수
- 취급 데이터의 민감도
- 인스턴스 격리 수준
- 고객에게 고지된 서비스 제약
- 보완 통제의 실행 가능성
- 필수 기능의 실제 시험 결과
