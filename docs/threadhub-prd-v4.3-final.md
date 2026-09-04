# ThreadHub 제품 요구사항 정의서

> 문서 유형: Product Requirements Document<br>
> 문서 버전: v4.3 Final<br>
> 기준일: 2026년 9월 4일<br>
> 상태: MVP 요구사항 기준선<br>
> 이전 기준선: v4.2 Final<br>
> 관련 문서: [ThreadHub MVP 구축 및 검증 계획서](./threadhub-mvp-build-validation-plan.md)

---

# 1. 문서 목적과 적용 범위

## 1.1 목적

이 문서는 ThreadHub MVP가 제공해야 하는 제품 기능, 운영 경계, 기술 제약, 보안 통제, 고객 파일럿 인수조건을 정의한다.

이 문서는 다음 질문에 답하는 기준선이다.

- ThreadHub가 해결하려는 문제는 무엇인가?
- 어떤 사용자에게 어떤 기능을 제공하는가?
- 어떤 기능과 운영 수준을 제공하지 않는가?
- 프로젝트와 고객 데이터를 어떤 경계로 분리하는가?
- 고객 파일럿을 시작하기 전에 무엇을 검증해야 하는가?
- MVP 완료를 어떤 조건으로 판단하는가?

## 1.2 문서 간 역할

| 문서 | 역할 |
| --- | --- |
| 본 PRD | 충족해야 하는 제품 요구사항과 제약 정의 |
| 구축 및 검증 계획서 | 배포 단계, 시험 항목, Go/No-Go 판정 방법 정의 |
| 배포 설계서 | Docker Compose, NGINX, 환경변수, 경로와 스크립트 정의 |
| 운영 절차서 | 점검, 사용자 관리, 장애 대응과 프로젝트 종료 절차 정의 |

본 PRD와 구축·검증 계획서가 충돌하면 제품 범위와 요구사항은 본 PRD를 기준으로 하되, 공식 제품 동작에 관한 사실 오류는 최신 공식 근거를 확인한 뒤 두 문서를 함께 수정한다.

## 1.3 요구사항 우선순위

| 우선순위 | 의미 |
| --- | --- |
| 필수 | MVP 출시 또는 고객 파일럿에 필요 |
| 권장 | MVP 범위 안에서 가능하면 적용 |
| 운영 규칙 | 기술 기능이 아닌 관리자·사용자 절차로 준수 |
| 조건부 | 특정 조건이 충족될 때 적용 |
| 제약 | 제품이 보장하지 않거나 사용자가 인지해야 하는 한계 |
| 제외 | MVP에서 제공하지 않음 |

---

# 2. 문서 정보

| 항목 | 내용 |
| --- | --- |
| 문서명 | ThreadHub 제품 요구사항 정의서 |
| 제품명 | ThreadHub |
| 제품 단계 | MVP |
| 제품 기반 | Mattermost Team Edition |
| 기본 배포 단위 | 정보 공유 경계당 독립 OCI VM 1개 |
| 기본 운영 모델 | 프로젝트당 독립 인스턴스 1개 |
| 배포 환경 | Oracle Cloud Infrastructure |
| 운영 방식 | OCI Compute VM 단일 노드 셀프호스팅 |
| 운영 상한 | 인스턴스당 활성 사용자 최대 50명 |
| 주요 사용자 | 내부 프로젝트 담당자와 외부 고객 |
| 지원 클라이언트 | 웹, 데스크톱, iOS, Android |
| 인증 | 이메일 또는 사용자명과 비밀번호 |
| 모바일 푸시 | MVP 기본 비활성화 |
| 채널 이메일 알림 | 별도 ThreadHub notifier로 즉시 일반 안내문 발송 |
| 백업·복구 | 일일 OCI Object Storage 백업, 수동 복구 |
| 가용성 | 단일 VM, 별도 SLA 없음 |
| 데이터 범위 | 일반 프로젝트 대화와 공유가 승인된 자료 |
| 목표 상태 | 내부 기술 파일럿과 제한된 고객 파일럿 운영 가능 |

---

# 3. 제품 개요

## 3.1 제품명

제품명은 **ThreadHub**로 한다.

- `Thread`: 주제별 대화와 논의 흐름
- `Hub`: 고객, 담당자와 프로젝트 정보가 모이는 협업 공간

## 3.2 제품 정의

ThreadHub는 고객과 내부 프로젝트 담당자가 프로젝트 기간 동안 사용하는 채널 기반 협업 서비스다.

내부 담당자는 고객의 개인 또는 회사 이메일 주소를 초대하고, 고객은 지정된 프로젝트 공간에서 다음 기능을 사용한다.

- 채널 메시지
- 주제별 스레드
- 사용자 멘션
- 1:1 DM
- 소규모 그룹 DM
- 파일 및 링크 공유
- 고객 질문과 담당자 답변
- 진행 상황 공유
- 결정사항 기록
- 과거 메시지 검색
- 웹·데스크톱·모바일 접속

ThreadHub는 음성회의, 화상회의, 이슈 추적, 전자결재 또는 영구 문서보관 시스템으로 사용하지 않는다.

## 3.3 가치 제안

ThreadHub는 프로젝트 커뮤니케이션을 개인 이메일과 메신저에서 분리해 다음 가치를 제공한다.

1. 프로젝트 대화를 한 서비스에서 확인한다.
2. 후속 논의를 스레드로 연결해 맥락을 유지한다.
3. 질문·답변·결정사항을 검색한다.
4. 담당자 변경 시 과거 흐름을 인계한다.
5. 프로젝트 기간에만 외부 사용자를 초대한다.
6. 정보 공유 경계별 독립 인스턴스로 고객 간 노출 위험을 줄인다.
7. 표준 배포 패키지로 다음 프로젝트 환경을 반복 생성한다.

## 3.4 기반 제품 선택

ThreadHub는 무료 셀프호스팅 제품인 Mattermost Team Edition을 사용한다.

선택 이유:

- 채널, 스레드, DM, 파일과 검색 기능 제공
- 공식 웹·데스크톱·모바일 클라이언트 제공
- PostgreSQL과 로컬 파일 저장 지원
- 단일 VM Docker 배포 가능
- 프로젝트별 독립 인스턴스 재배포 가능
- 활성 사용자 최대 50명의 일반 프로젝트 협업에 적합

ThreadHub는 Mattermost Team Edition을 민감하거나 규제된 상업 워크로드의 일반 플랫폼으로 사용하지 않는다. 일반 프로젝트 대화만 취급하며 고위험·규제 데이터를 제외한다. 제품 에디션과 라이선스 기준은 [Mattermost Editions and Offerings](https://docs.mattermost.com/product-overview/editions-and-offerings.html)를 참고한다.

---

# 4. 배경과 문제 정의

## 4.1 현재 문제

고객 프로젝트 대화가 이메일, 개인 메신저, 전화와 문서 댓글에 분산되면 다음 문제가 발생한다.

- 프로젝트 논의를 한곳에서 확인하기 어렵다.
- 과거 질문과 답변을 다시 찾기 어렵다.
- 결정사항이 언제 어떤 맥락에서 만들어졌는지 확인하기 어렵다.
- 담당자가 변경될 때 프로젝트 맥락을 인계하기 어렵다.
- 고객과 내부 담당자의 대화가 개인 계정에만 남을 수 있다.
- 동일한 질문과 답변이 반복된다.
- 진행 상황과 차단사항이 일관된 형식으로 관리되지 않는다.
- 서로 다른 고객 조직의 정보가 잘못 공유될 위험이 있다.

## 4.2 해결 방향

ThreadHub는 정보 공유 경계마다 독립 Mattermost 인스턴스를 제공한다.

기본 프로젝트 구조:

```text
ThreadHub Project Instance
├── Team: Internal
│   ├── 내부공지
│   └── 내부운영
│
└── Team: Project
    ├── 00-공지
    ├── 01-프로젝트-일반
    ├── 02-진행상황
    ├── 03-결정사항
    ├── 04-질문-답변
    └── 05-자료공유
```

같은 프로젝트라도 서로의 존재나 대화가 노출되면 안 되는 고객 조직은 동일 인스턴스에 배치하지 않는다.

## 4.3 제품 가설

ThreadHub를 프로젝트 기본 대화 공간으로 사용하면 다음 결과를 기대한다.

- 주요 고객 요청의 90% 이상이 ThreadHub에 기록된다.
- 주요 결정사항의 90% 이상이 지정 채널에 기록된다.
- 파일럿 참여자가 과거 대화를 한글 검색으로 찾을 수 있다.
- 사용자 교체 후에도 기존 대화 맥락이 유지된다.
- 프로젝트 종료 후 기록 유지 또는 완전 폐기를 선택할 수 있다.
- 새 프로젝트 인스턴스를 동일 배포 패키지로 재구성할 수 있다.

---

# 5. 제품 목표

## G-01. 채널 기반 고객 협업

고객과 내부 담당자가 프로젝트 채널에서 메시지, 파일과 링크를 공유할 수 있어야 한다.

## G-02. 스레드 기반 논의

새로운 주제는 채널의 새 메시지로 시작하고 후속 논의는 해당 메시지의 스레드에서 이어갈 수 있어야 한다.

## G-03. 초대 기반 외부 사용자 등록

관리자는 고객사 업무 이메일, Gmail, 네이버, 다음과 기타 정상 이메일 서비스 주소로 사용자를 초대할 수 있어야 한다.

고객은 유료 Guest가 아닌 일반 Member 계정으로 등록한다.

## G-04. 프로젝트 이력 유지

VM과 영구 저장 경로가 정상 유지되는 동안 메시지, 스레드, DM, 사용자 정보, 채널 정보와 첨부파일이 유지되어야 한다.

## G-05. 활성 사용자 최대 50명

ThreadHub 인스턴스당 활성 사용자는 최대 50명으로 운영한다. 이는 Mattermost 라이선스 제한이 아니라 ThreadHub의 제품·운영 기준이다.

## G-06. 사용자 교체

프로젝트에서 빠진 사용자를 Team에서 제거하고 계정을 비활성화할 수 있어야 한다. 비활성화 후에도 기존 메시지는 유지되어야 하며 필요하면 계정을 다시 활성화할 수 있어야 한다.

## G-07. 공식 모바일 앱 지원

사용자는 공식 Mattermost iOS와 Android 앱에 ThreadHub 서버 주소를 입력해 접속할 수 있어야 한다.

## G-08. 단일 VM 운영

초기 ThreadHub는 하나의 OCI Compute VM에 NGINX, Mattermost, PostgreSQL과 영구 저장 경로를 배치해야 한다.

## G-09. 반복 배포

프로젝트 종료 후 데이터가 없는 새 ThreadHub를 동일한 배포 패키지로 만들 수 있어야 한다.

## G-10. 무료 기능만 사용

Mattermost Professional·Enterprise 기능, 유료 Guest, SSO, 유료 고급 접근제어, 감사·컴플라이언스 기능과 Calls를 사용하지 않아야 한다.

## G-11. 명시적 보안 경계

서로 신뢰하지 않는 사용자 집단을 Team 또는 비공개 채널만으로 격리하지 않고 정보 공유 경계별 독립 인스턴스로 분리해야 한다.

## G-12. 검증 가능한 백업과 수동 복구

PostgreSQL 논리 덤프, Mattermost 첨부파일과 notifier queue를 매일 프로젝트 전용
OCI Object Storage 버킷에 백업하고, 원격 객체 검증과 폐기 가능한 신규 VM
복구시험을 통해 최근 성공 백업까지의 수동 복구 경로를 유지해야 한다.

## G-13. 즉시 채널 이메일 알림

공개·비공개 채널의 새 글과 스레드 답글이 게시되면 작성자를 제외한 현재 채널 멤버에게
메시지 본문·채널·Team·작성자명을 포함하지 않는 일반 안내 이메일을 즉시 발송해야
한다. Mattermost 플러그인은 이벤트와 멤버십을 판단하고, 별도 Mailer는 영구 큐,
재시도와 OCI SMTP 발송을 담당해야 한다.

---

# 6. 비목표와 명시적 제외 범위

| ID | 비목표 또는 제외 범위 |
| --- | --- |
| NG-01 | 음성회의 및 화상회의 |
| NG-02 | Mattermost Calls |
| NG-03 | Zoom·Google Meet 등의 회의 연동 |
| NG-04 | Mattermost 유료 라이선스 기능 |
| NG-05 | 유료 Guest 계정 |
| NG-06 | SAML·LDAP·OpenID Connect SSO |
| NG-07 | Team Override와 채널별 유료 고급 권한제어 |
| NG-08 | 프로젝트 일정 관리 |
| NG-09 | 이슈 추적 시스템 |
| NG-10 | 전자결재 |
| NG-11 | 채널·Team 데이터 Export |
| NG-12 | 무중단 백업과 온라인 정합성 snapshot |
| NG-13 | PostgreSQL 시점 복구(PITR) |
| NG-14 | 리전 간 백업 복제와 자동 재해복구 |
| NG-15 | RPO·RTO 목표를 초과하지 않는다는 SLA 보장 |
| NG-16 | OCI Logging |
| NG-17 | OCI Monitoring |
| NG-18 | 자동 장애 알림 |
| NG-19 | OCI 관리형 PostgreSQL |
| NG-20 | OCI Load Balancer |
| NG-21 | 다중 VM 및 고가용성 |
| NG-22 | Kubernetes |
| NG-23 | 영구 고객 포털 |
| NG-24 | 공식 문서 관리 시스템 대체 |
| NG-25 | 자체 모바일 앱 및 자체 Push Proxy |
| NG-26 | 고위험·규제 데이터 처리 |
| NG-27 | 고객 기기에 저장된 파일의 원격 삭제 |
| NG-28 | Persistent Notification, 확인 강제, Reminder와 Scheduled Message |

중앙 로깅, 통합 모니터링, 고가용성과 자동 장애조치는 MVP 안정화 이후 별도 제품
결정으로 검토한다. 백업은 최근 원격 검증 성공 시점까지의 수동 복구 경로이며
무중단·무손실 또는 자동 복구를 의미하지 않는다.

---

# 7. 사용자 유형과 책임

## 7.1 시스템 관리자

OCI와 서버 인프라를 관리한다.

주요 책임:

- OCI Compute VM 생성·확장·삭제
- 운영체제와 Docker 관리
- Mattermost와 PostgreSQL 관리
- NGINX와 HTTPS 관리
- OCI Email Delivery 관리
- 배포 버전과 이미지 Digest 관리
- 기본 운영 점검
- 프로젝트 종료 후 인프라 정리

## 7.2 ThreadHub 관리자

Mattermost 내부 설정, 권한과 사용자를 관리한다.

주요 책임:

- 외부 이메일 사용자 초대
- Team과 채널 생성
- System Scheme 적용
- 사용자 계정 비활성화·재활성화
- Team 초대 URL 비배포와 코드 재생성
- 공개 회원가입 차단
- 관리자 MFA 등록 상태 확인
- 기본 운영정책 게시
- 프로젝트 종료 후 채널과 계정 정리

시스템 관리자와 ThreadHub 관리자는 동일인일 수 있다.

## 7.3 내부 프로젝트 담당자

고객과 프로젝트 대화를 수행한다.

주요 활동:

- 고객 요청 확인과 답변
- 진행 상황 및 차단사항 공유
- 스레드 토론
- 파일과 링크 공유
- 결정사항 기록
- 이전 논의 검색

## 7.4 고객 사용자

외부 이메일로 초대되는 일반 Member다.

주요 활동:

- Project Team 접속
- 채널 메시지와 스레드 작성
- 담당자 멘션
- 파일과 링크 공유
- 이전 대화 검색
- 내부 담당자와 DM

고객에게 다음 권한을 부여하지 않는다.

- System Admin
- Team Admin
- System Console 접근
- 사용자 초대
- Team 생성
- 공개·비공개 채널 생성
- 라이선스 설정
- 플러그인 및 Webhook 관리

## 7.5 사용자 책임

모든 사용자는 다음 운영 규칙을 준수해야 한다.

- 계정을 공유하지 않는다.
- 비밀번호·API 키·개인키를 업로드하지 않는다.
- 중요한 결정을 DM에만 남기지 않는다.
- 대용량 파일은 승인된 외부 저장소 링크로 공유한다.
- 고위험·규제 데이터를 업로드하지 않는다.
- 긴급 연락이 필요한 경우 별도 연락 수단을 사용한다.

---

# 8. 인스턴스와 정보 공유 경계

## 8.1 기본 원칙

ThreadHub의 기본 배포 단위는 프로젝트당 독립 인스턴스 1개다.

```text
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
```

## 8.2 실제 분리 기준

프로젝트명보다 정보 공유 경계를 우선한다.

```text
같은 프로젝트이고 모든 참여자가 서로의 존재와 참여 사실을 알아도 됨
→ 동일 인스턴스 사용 가능

같은 프로젝트지만 고객 조직 간 사용자·대화 노출이 금지됨
→ 고객 조직 또는 보안 경계별 별도 인스턴스
```

Team과 비공개 채널은 동일 신뢰 경계 내부의 정보 구성 수단이며, 서로 신뢰하지 않는 고객 조직을 격리하는 보안 경계로 사용하지 않는다.

## 8.3 인스턴스 간 비공유 항목

서로 다른 인스턴스는 다음 항목을 공유하지 않는다.

- 사용자 계정
- 메시지와 첨부파일
- PostgreSQL 데이터
- 실제 환경변수 파일
- DB와 SMTP 자격 증명
- Mattermost 관리자 계정
- 도메인 또는 서브도메인
- 프로젝트 종료 시점

## 8.4 공통 재사용 항목

다음 항목은 프로젝트 간 재사용할 수 있다.

- Git 배포 저장소
- Docker Compose 템플릿
- 버전 정의 파일
- NGINX 템플릿
- 설치·배포 스크립트
- 운영·종료 절차
- OCI VCN·NSG 설계
- OCI Email Delivery 서비스

실제 비밀번호, 프로젝트 데이터, 고객 도메인 설정과 관리자 계정은 재사용하지 않는다.

---

# 9. 프로젝트 생명주기

## 9.1 프로젝트 시작

1. 정보 공유 경계를 확인한다.
2. OCI VM과 예약 공인 IP를 생성한다.
3. DNS를 프로젝트 인스턴스에 연결한다.
4. 표준 배포 패키지로 ThreadHub를 배포한다.
5. HTTPS와 OCI Email Delivery를 구성한다.
6. System Admin 계정을 생성하고 MFA를 등록한다.
7. System Scheme과 가입정책을 적용한다.
8. Internal·Project Team과 기본 채널을 생성한다.
9. 내부 담당자와 고객을 이메일로 초대한다.
10. 프로젝트 전용 백업을 비활성 상태로 등록한다.
11. 최초 수동 백업의 원격 검증과 폐기 가능한 신규 VM 복구시험을 완료한다.
12. 증거 승인 후 일일 백업 타이머를 활성화한다.
13. 내부 기술 검증 후 고객 파일럿 Go/No-Go를 판정한다.

## 9.2 프로젝트 진행

- 공식 프로젝트 대화는 채널에서 진행한다.
- 새 주제는 새 메시지로 시작한다.
- 후속 논의는 스레드에서 이어간다.
- 최종 결론은 결정사항 채널에 정리한다.
- 대용량 파일은 승인된 외부 저장소 링크로 공유한다.
- 중요한 내용을 DM에만 남기지 않는다.
- 프로젝트 참여가 종료된 사용자는 지체 없이 제거·비활성화한다.

## 9.3 프로젝트 종료 방식 A: 기록 유지

1. 고객에게 종료 일정을 안내한다.
2. 최종 논의와 작업을 확인한다.
3. 고객 계정을 비활성화한다.
4. 프로젝트 채널을 보관한다.
5. DNS와 SMTP 상태를 확인한다.
6. VM 또는 Boot Volume과 승인된 Object Storage 백업을 유지한다.

기록 유지 방식은 최근 원격 검증 성공 백업까지의 수동 복구 경로를 유지한다.
마지막 성공 이후 최대 24시간의 데이터 손실과 수동 복구 4시간 목표를 수용하며,
HA·PITR·복구시간 SLA는 제공하지 않는다.

## 9.4 프로젝트 종료 방식 B: 완전 폐기

1. 폐기 대상과 필요한 자료를 확인한다.
2. 고객 계정을 비활성화한다.
3. DNS 레코드를 제거한다.
4. SMTP 자격 증명을 폐기하거나 교체한다.
5. OCI VM을 삭제한다.
6. Boot Volume을 삭제한다.
7. 예약 공인 IP를 해제하거나 재사용한다.
8. 별도 승인 후 Object Storage 백업과 전용 IAM 리소스를 삭제한다.
9. 대상·실행자·실행시각과 결과를 기록한다.

VM과 Boot Volume만 삭제해도 Object Storage 백업은 자동 삭제되지 않는다. 승인된
완전 폐기 절차로 백업까지 삭제한 이후에는 프로젝트 메시지와 첨부파일을 복구할 수 없다.

## 9.5 다음 프로젝트 재배포

다음 프로젝트는 기존 데이터를 복사하지 않고 새 환경으로 시작한다.

재사용 대상:

- Docker Compose 구성
- 환경변수 예제
- 버전 정의
- NGINX 설정
- 설치·배포 스크립트
- 운영·검증·종료 절차

새 프로젝트마다 새로운 환경변수 파일, 비밀번호, 관리자 계정, 도메인과 데이터 저장 경로를 생성해야 한다.

---

# 10. Team과 채널 정보 구조

## 10.1 기본 Team

각 인스턴스에는 다음 Team을 생성한다.

```text
Internal
Project
```

- `Internal`: 내부 담당자만 참여하는 운영·준비 공간
- `Project`: 고객과 내부 담당자가 함께 참여하는 공식 프로젝트 공간

서로 신뢰하지 않는 여러 고객 조직을 하나의 인스턴스 안에서 Team으로만 구분하지 않는다.

## 10.2 기본 채널

| 채널명 | 유형 | 목적 |
| --- | --- | --- |
| `00-공지` | Team 공개 | 프로젝트 공지와 운영 안내 |
| `01-프로젝트-일반` | Team 공개 | 일반 프로젝트 대화 |
| `02-진행상황` | Team 공개 | 진행상황과 차단사항 |
| `03-결정사항` | Team 공개 | 최종 결정과 근거 |
| `04-질문-답변` | Team 공개 | 고객 질문과 담당자 답변 |
| `05-자료공유` | Team 공개 | 파일과 참고 링크 |
| `project-세부영역` | 필요 시 비공개 | 동일 정보 공유 경계 안의 제한된 논의 |

## 10.3 채널 운영 원칙

- 동일 목적의 중복 채널을 만들지 않는다.
- 채널 목적이 드러나는 이름을 사용한다.
- 새 주제는 채널의 새 메시지로 시작한다.
- 후속 논의는 원 메시지의 스레드를 사용한다.
- 종료된 채널은 삭제보다 보관을 우선한다.
- 관리자가 기본 채널 구조를 유지한다.
- 고객 Member의 공개·비공개 채널 생성 권한을 System Scheme으로 제한한다.

## 10.4 채널 한도

Mattermost 셀프호스팅의 Team당 채널 기본 한도인 2,000개를 유지한다. 이 값은 활성 채널과 보관 채널을 모두 포함한다.

```text
MM_TEAMSETTINGS_MAXCHANNELSPERTEAM=2000
```

ThreadHub의 실제 채널 수는 기본 채널 구조와 관리자 중심 생성정책으로 제한한다.

---

# 11. 기능 요구사항

## 11.1 사용자 등록과 인증

| ID | 요구사항 | 우선순위 |
| --- | --- | --- |
| FR-AUTH-001 | 사용자는 이메일 또는 사용자명과 비밀번호로 로그인할 수 있어야 한다. | 필수 |
| FR-AUTH-002 | 관리자는 외부 이메일 주소로 사용자를 초대할 수 있어야 한다. | 필수 |
| FR-AUTH-003 | 초대 토큰 또는 유효한 Team InviteId가 없는 직접 가입을 차단해야 한다. | 필수 |
| FR-AUTH-004 | 이메일 기반 계정 생성을 허용해야 한다. | 필수 |
| FR-AUTH-005 | 이메일 주소 확인 후 로그인을 허용해야 한다. | 필수 |
| FR-AUTH-006 | 이메일 기반 비밀번호 재설정을 지원하고 변경 후 기존 세션을 종료해야 한다. | 필수 |
| FR-AUTH-007 | 비밀번호 최소 길이를 12자로 설정해야 한다. | 필수 |
| FR-AUTH-008 | 로그인 실패 허용 횟수를 제한해야 한다. | 필수 |
| FR-AUTH-009 | 관리자는 사용자 계정을 비활성화하고 재활성화할 수 있어야 한다. | 필수 |
| FR-AUTH-010 | System Admin 계정은 1~2개로 제한해야 한다. | 필수 |
| FR-AUTH-011 | Mattermost 사용자별 MFA 기능을 활성화해야 한다. | 필수 |
| FR-AUTH-012 | 모든 System Admin 계정은 MFA를 등록해야 한다. | 필수 |
| FR-AUTH-013 | System Admin MFA 복구 절차를 문서화하고 시험해야 한다. | 필수 |
| FR-AUTH-014 | SSO를 사용하지 않아야 한다. | 제외 |
| FR-AUTH-015 | 유료 Guest 계정을 사용하지 않아야 한다. | 제외 |

필수 인증 기준:

```text
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
```

Team Edition 11.7.7은 사용자별 선택적 MFA를 지원한다. 전 사용자 MFA 강제는 무료 기능으로 전제하지 않으며, System Admin 계정에 대해 운영 절차로 등록을 강제한다. 구현 근거는 [MFA 등록 코드](https://github.com/mattermost/mattermost/blob/v11.7.7/server/channels/app/user.go#L870-L925)와 [전역 MFA 강제 검사 코드](https://github.com/mattermost/mattermost/blob/v11.7.7/server/channels/app/authentication.go#L306-L370)를 따른다.

## 11.2 초대 링크 정책

| ID | 요구사항 | 우선순위 |
| --- | --- | --- |
| FR-INV-001 | 기본 초대 방식은 관리자가 발송하는 이메일 초대여야 한다. | 필수 |
| FR-INV-002 | 일반 Member의 사용자 초대 권한을 제한해야 한다. | 필수 |
| FR-INV-003 | Team 초대 URL을 고객에게 배포하지 않아야 한다. | 운영 규칙 |
| FR-INV-004 | 초대 기간 종료 또는 링크 노출 가능성이 있으면 Team 초대 코드를 재생성해야 한다. | 필수 |
| FR-INV-005 | 사용 완료된 이메일 초대 토큰은 재사용할 수 없어야 한다. | 필수 |
| FR-INV-006 | 관리자가 미수락 이메일 초대를 무효화할 수 있어야 한다. | 필수 |
| FR-INV-007 | 코드 재생성 후 기존 Team 초대 URL을 사용할 수 없어야 한다. | 필수 |

`EnableOpenServer=false`는 초대 없는 직접 가입을 차단하지만 유효한 Team InviteId를 정상 초대로 처리한다. Team 초대 URL은 링크를 가진 사용자가 사용할 수 있는 bearer invitation으로 취급한다. 자세한 분기 동작은 [Mattermost v11.7.7 사용자 생성 핸들러](https://github.com/mattermost/mattermost/blob/v11.7.7/server/channels/api4/user.go)를 기준으로 한다.

## 11.3 Member 권한

| ID | 요구사항 | 우선순위 |
| --- | --- | --- |
| FR-PERM-001 | 고객은 일반 Member로 등록해야 한다. | 필수 |
| FR-PERM-002 | 고객에게 System Admin을 부여하지 않아야 한다. | 필수 |
| FR-PERM-003 | 고객에게 Team Admin을 부여하지 않아야 한다. | 필수 |
| FR-PERM-004 | 고객의 System Console 접근을 차단해야 한다. | 필수 |
| FR-PERM-005 | 일반 Member의 사용자 초대 권한을 System Scheme으로 제거해야 한다. | 필수 |
| FR-PERM-006 | 일반 Member의 Team 생성 권한을 System Scheme으로 제거해야 한다. | 필수 |
| FR-PERM-007 | 일반 Member의 공개 채널 생성 권한을 System Scheme으로 제거해야 한다. | 필수 |
| FR-PERM-008 | 일반 Member의 비공개 채널 생성 권한을 System Scheme으로 제거해야 한다. | 필수 |
| FR-PERM-009 | 일반 Member의 Webhook 및 통합 생성 권한을 제한해야 한다. | 필수 |
| FR-PERM-010 | System Scheme 적용 결과를 고객 Member 계정으로 시험해야 한다. | 필수 |
| FR-PERM-011 | 정확한 이미지에서 제한할 수 없는 권한은 고객 파일럿 전에 위험을 별도 승인해야 한다. | 조건부 |
| FR-PERM-012 | Team Override와 채널별 유료 고급 권한은 사용하지 않아야 한다. | 제외 |

Mattermost는 System Permission Scheme을 Team Edition에 제공한다. ThreadHub는 글로벌 System Scheme을 사용하며, 전역 제한이 내부 일반 Member에도 적용된다는 점을 수용하고 Team·채널 생성은 관리자 요청 방식으로 운영한다. 근거는 [System Scheme 공지](https://forum.mattermost.com/t/granular-permissions-coming-soon-to-team-edition/11929)와 [v11.7.7 권한 구현](https://github.com/mattermost/mattermost/blob/v11.7.7/webapp/channels/src/components/admin_console/permission_schemes_settings/permissions_tree/permissions_tree.tsx#L55-L115)을 따른다.

## 11.4 채널과 스레드

| ID | 요구사항 | 우선순위 |
| --- | --- | --- |
| FR-CH-001 | 관리자는 공개 및 비공개 채널을 생성할 수 있어야 한다. | 필수 |
| FR-CH-002 | 비공개 채널은 참여자에게만 표시되어야 한다. | 필수 |
| FR-CH-003 | 메시지에 스레드 답글을 작성할 수 있어야 한다. | 필수 |
| FR-CH-004 | 사용자 멘션을 지원해야 한다. | 필수 |
| FR-CH-005 | 메시지와 스레드 링크를 복사할 수 있어야 한다. | 필수 |
| FR-CH-006 | 중요 메시지를 저장하거나 고정할 수 있어야 한다. | 권장 |
| FR-CH-007 | 채널을 보관하고 다시 활성화할 수 있어야 한다. | 필수 |
| FR-CH-008 | 채널 보관 후 기존 메시지와 파일을 열람할 수 있어야 한다. | 필수 |
| FR-CH-009 | 최종 결정은 `03-결정사항` 채널에 기록해야 한다. | 운영 규칙 |
| FR-CH-010 | 채널 Export 기능을 제공하지 않아야 한다. | 제외 |

## 11.5 DM과 그룹 DM

| ID | 요구사항 | 우선순위 |
| --- | --- | --- |
| FR-DM-001 | 1:1 DM을 지원해야 한다. | 필수 |
| FR-DM-002 | 소규모 그룹 DM을 지원해야 한다. | 필수 |
| FR-DM-003 | 그룹 DM은 최대 8명 범위에서 사용해야 한다. | 필수 |
| FR-DM-004 | 8명을 초과하는 대화는 채널을 사용해야 한다. | 운영 규칙 |
| FR-DM-005 | 공식 결정과 중요한 정보는 관련 채널에 다시 기록해야 한다. | 운영 규칙 |

## 11.6 파일과 링크

| ID | 요구사항 | 우선순위 |
| --- | --- | --- |
| FR-FILE-001 | 채널과 DM에 파일을 첨부할 수 있어야 한다. | 필수 |
| FR-FILE-002 | 권한이 있는 사용자는 파일을 다운로드할 수 있어야 한다. | 필수 |
| FR-FILE-003 | 첨부파일을 VM의 명시적 영구 경로에 저장해야 한다. | 필수 |
| FR-FILE-004 | 단일 파일 업로드 크기를 25MiB로 제한해야 한다. | 필수 |
| FR-FILE-005 | 외부 문서 링크를 공유할 수 있어야 한다. | 필수 |
| FR-FILE-006 | 대용량 파일은 승인된 외부 저장소 링크로 공유해야 한다. | 운영 규칙 |
| FR-FILE-007 | 비밀번호·API 키·개인키를 업로드하지 않아야 한다. | 운영 규칙 |
| FR-FILE-008 | 공개 파일 링크 기능을 비활성화해야 한다. | 필수 |
| FR-FILE-009 | 컨테이너 재생성 후 기존 파일을 다운로드할 수 있어야 한다. | 필수 |
| FR-FILE-010 | 악성코드 검사를 제공하지 않아야 한다. | 제외 |

파일 제한 기준:

```text
MM_FILESETTINGS_MAXFILESIZE=26214400
```

NGINX 요청 크기 제한은 multipart 여유를 고려해 Mattermost 제한보다 크게 설정하고, 실제 제품 제한은 Mattermost가 적용해야 한다.

## 11.7 검색과 이력

| ID | 요구사항 | 우선순위 |
| --- | --- | --- |
| FR-HIST-001 | 키워드로 메시지를 검색할 수 있어야 한다. | 필수 |
| FR-HIST-002 | 채널 기준 검색을 지원해야 한다. | 필수 |
| FR-HIST-003 | 작성자 기준 검색을 지원해야 한다. | 필수 |
| FR-HIST-004 | 스레드 답글을 검색할 수 있어야 한다. | 필수 |
| FR-HIST-005 | 검색 결과에서 원 메시지와 스레드로 이동할 수 있어야 한다. | 필수 |
| FR-HIST-006 | 한글 입력과 한글 부분 문자열 검색을 지원해야 한다. | 필수 |
| FR-HIST-007 | 한글·영문·숫자 혼합 메시지를 검색할 수 있어야 한다. | 필수 |
| FR-HIST-008 | 파일명 검색의 실제 동작을 확인해야 한다. | 필수 |
| FR-HIST-009 | Elasticsearch와 OpenSearch를 사용하지 않아야 한다. | 제외 |

CJK 검색 후보 설정:

```text
MM_FEATUREFLAGS_CJKSEARCH=true
```

Mattermost v11.7.7 소스의 CJK 검색 분기는 별도 라이선스 검사 없이 PostgreSQL `LIKE '%검색어%'` 방식으로 동작한다. Team Edition에서의 공식 지원 표기는 명확하지 않으므로 정확한 이미지와 대표 누적 게시물 규모에서 기능과 성능을 검증한 후 고객 파일럿을 시작한다. 근거는 [CJK feature flag](https://github.com/mattermost/mattermost/blob/v11.7.7/server/public/model/feature_flags.go#L90-L165)와 [CJK 검색 구현](https://github.com/mattermost/mattermost/blob/v11.7.7/server/channels/store/sqlstore/post_store.go#L2097-L2218)을 따른다.

필수 검색 예시:

```text
검색어: 오류
기대 게시물:
- 로그인 오류
- 고객로그인오류
- 로그인오류를 확인했습니다
```

## 11.8 모바일 앱

| ID | 요구사항 | 우선순위 |
| --- | --- | --- |
| FR-MOB-001 | iOS 공식 Mattermost 앱에서 접속할 수 있어야 한다. | 필수 |
| FR-MOB-002 | Android 공식 Mattermost 앱에서 접속할 수 있어야 한다. | 필수 |
| FR-MOB-003 | 모바일에서 채널과 스레드를 사용할 수 있어야 한다. | 필수 |
| FR-MOB-004 | 모바일에서 DM을 사용할 수 있어야 한다. | 필수 |
| FR-MOB-005 | 모바일에서 파일을 업로드하고 다운로드할 수 있어야 한다. | 필수 |
| FR-MOB-006 | 모바일에서 메시지를 검색할 수 있어야 한다. | 필수 |
| FR-MOB-007 | 모바일에서 사용자 멘션을 사용할 수 있어야 한다. | 필수 |
| FR-MOB-008 | 비활성 계정은 다시 로그인할 수 없어야 한다. | 필수 |
| FR-MOB-009 | 사용자가 기기에 별도로 저장한 파일은 서버에서 원격 회수하지 않아야 한다. | 제약 |

## 11.9 모바일 푸시

ThreadHub는 상업적 고객 프로젝트에 무료 TPNS를 사용하지 않는다. MVP에서는 모바일 푸시를 비활성화한다.

| ID | 요구사항 | 우선순위 |
| --- | --- | --- |
| FR-PUSH-001 | 모바일 앱은 푸시 없이 정상 동작해야 한다. | 필수 |
| FR-PUSH-002 | 사용자가 앱을 열면 최신 메시지를 동기화해야 한다. | 필수 |
| FR-PUSH-003 | 무료 TPNS를 고객 프로젝트에 사용하지 않아야 한다. | 필수 |
| FR-PUSH-004 | 유료 HPNS를 MVP에서 사용하지 않아야 한다. | 제외 |
| FR-PUSH-005 | 자체 모바일 앱과 Push Proxy를 MVP에서 구축하지 않아야 한다. | 제외 |
| FR-PUSH-006 | 향후 푸시를 활성화할 경우 메시지 본문과 채널명을 제외해야 한다. | 조건부 |

필수 설정:

```text
MM_EMAILSETTINGS_SENDPUSHNOTIFICATIONS=false
```

향후 적합한 푸시 방식이 마련된 경우에만 다음 설정을 함께 적용한다.

```text
MM_EMAILSETTINGS_PUSHNOTIFICATIONCONTENTS=generic_no_channel
```

`generic_no_channel`은 푸시를 끄는 설정이 아니라 활성화된 푸시의 표시 내용을 제한하는 설정이다. 자세한 내용은 [Mattermost 푸시 설정](https://docs.mattermost.com/administration-guide/configure/push-notification-server-configuration-settings.html)을 참고한다.

## 11.10 계정 이메일

OCI Email Delivery를 계정 관련 SMTP 릴레이로 사용한다.

이메일 용도:

- 사용자 초대
- 이메일 주소 확인
- 비밀번호 재설정

| ID | 요구사항 | 우선순위 |
| --- | --- | --- |
| FR-MAIL-001 | OCI Email Delivery를 사용해야 한다. | 필수 |
| FR-MAIL-002 | 사용자 초대 이메일을 발송할 수 있어야 한다. | 필수 |
| FR-MAIL-003 | 이메일 확인 메일을 발송할 수 있어야 한다. | 필수 |
| FR-MAIL-004 | 비밀번호 재설정 메일을 발송할 수 있어야 한다. | 필수 |
| FR-MAIL-005 | SMTP 587과 STARTTLS를 사용해야 한다. | 필수 |
| FR-MAIL-006 | 발신 주소를 Approved Sender로 등록해야 한다. | 필수 |
| FR-MAIL-007 | SPF를 구성해야 한다. | 필수 |
| FR-MAIL-008 | DKIM을 구성해야 한다. | 필수 |
| FR-MAIL-009 | Mattermost 기본 일반 메시지 이메일 알림을 비활성화해야 한다. | 필수 |
| FR-MAIL-010 | Gmail·네이버·다음에서 초대·확인·재설정 메일을 시험해야 한다. | 필수 |
| FR-MAIL-011 | 시험 메일의 SPF·DKIM 결과가 `pass`여야 한다. | 필수 |
| FR-MAIL-012 | 수신 위치와 OCI suppression 상태를 기록해야 한다. | 필수 |

Mattermost 기본 일반 메시지 알림 비활성화 기준:

```text
MM_EMAILSETTINGS_SENDEMAILNOTIFICATIONS=false
```

스팸함 분류 여부는 수신 사업자와 발신 평판에 따라 달라질 수 있으므로 받은편지함 수신을 보장하지 않는다. 계정 관련 메일이 실제로 도착하고 링크가 정상 동작하는 것을 인수기준으로 한다.

## 11.11 즉시 채널 이메일 알림

Mattermost 기본 이메일 알림 대신 별도 ThreadHub notifier를 사용한다. 플러그인은
`MessageHasBeenPosted` 훅에서 새 글과 스레드 답글을 감지하고, 현재 채널 멤버와 수신
적격성을 판단한 뒤 최소 이벤트를 plugin KV outbox에 기록한다. 별도 Mailer는 내부
Docker network에서 HMAC 서명 요청을 받아 SQLite 영구 큐에 저장하고 OCI Email
Delivery SMTP 587·STARTTLS로 수신자별 이메일을 발송한다.

| ID | 요구사항 | 우선순위 |
| --- | --- | --- |
| FR-NOT-001 | 공개·비공개 채널의 새 글과 스레드 답글을 게시 직후 감지해야 한다. | 필수 |
| FR-NOT-002 | 게시 시점의 현재 채널 멤버 중 작성자·비활성 사용자·봇·이메일 미확인 사용자를 제외하고 발송해야 한다. | 필수 |
| FR-NOT-003 | DM, 그룹 DM, 시스템 글, 수정·삭제와 Webhook·봇 작성 글을 발송 대상에서 제외해야 한다. | 필수 |
| FR-NOT-004 | 이메일·Mailer 요청·상태 출력·로그에 메시지 본문, 채널명, Team명과 작성자명을 포함하지 않아야 한다. | 필수 |
| FR-NOT-005 | 수신자별로 분리된 SMTP envelope와 일반 안내문을 사용해야 한다. | 필수 |
| FR-NOT-006 | plugin→Mailer 요청은 호스트 포트가 없는 내부 network와 프로젝트별 HMAC으로 보호해야 한다. | 필수 |
| FR-NOT-007 | 계정 메일을 위한 Mattermost 본체와 Mailer는 같은 프로젝트 SMTP 설정을 사용할 수 있으나, 커스텀 플러그인은 SMTP 자격 증명을 읽거나 plugin→Mailer 요청에 포함하지 않아야 한다. | 필수 |
| FR-NOT-008 | Mailer 또는 SMTP 장애 중에도 Mattermost 글 작성은 정상 완료되고 미처리 작업이 영구 큐에 유지돼야 한다. | 필수 |
| FR-NOT-009 | notifier는 `activate`, `drain`, `disable` 상태로 신규 수집과 기존 큐 발송을 분리 제어해야 한다. | 필수 |
| FR-NOT-010 | 전달은 at-least-once이며 드문 중복 가능성과 exactly-once 미보장을 운영 문서에 명시해야 한다. | 제약 |
| FR-NOT-011 | 공개 플러그인 API만 사용하고 유료 기능 또는 라이선스 검사를 활성화·우회하지 않아야 한다. | 필수 |
| FR-NOT-012 | 플러그인 번들과 Mailer 이미지에 자체 라이선스와 제3자 의존성 고지를 포함해야 한다. | 필수 |

`MM_EMAILSETTINGS_SENDEMAILNOTIFICATIONS=false`는 Mattermost 기본 일반 메시지 이메일
알림만 끈다. 계정 이메일과 별도 ThreadHub notifier 발송은 계속 사용할 수 있다.
상세 구성과 경계는
[즉시 채널 이메일 알림 아키텍처](../deploy/docs/notifier-architecture.md)를 따른다.

## 11.12 관리자 기능과 프로젝트 종료

| ID | 요구사항 | 우선순위 |
| --- | --- | --- |
| FR-ADM-001 | 관리자는 사용자 목록과 활성 상태를 확인할 수 있어야 한다. | 필수 |
| FR-ADM-002 | 관리자는 사용자를 Team에서 제거할 수 있어야 한다. | 필수 |
| FR-ADM-003 | 관리자는 계정을 비활성화하고 재활성화할 수 있어야 한다. | 필수 |
| FR-ADM-004 | 관리자는 채널을 보관하고 복원할 수 있어야 한다. | 필수 |
| FR-ADM-005 | 관리자는 System Scheme을 설정할 수 있어야 한다. | 필수 |
| FR-ADM-006 | 관리자는 미수락 이메일 초대를 무효화할 수 있어야 한다. | 필수 |
| FR-ADM-007 | 관리자는 Team 초대 코드를 재생성할 수 있어야 한다. | 필수 |
| FR-ADM-008 | 프로젝트 종료 시 기록 유지 또는 완전 폐기를 선택할 수 있어야 한다. | 필수 |
| FR-ADM-009 | 완전 폐기 대상을 식별하고 실행 결과를 기록해야 한다. | 필수 |
| FR-ADM-010 | 채널·Team Export를 제공하지 않아야 한다. | 제외 |

---

# 12. 비기능 요구사항

## 12.1 성능과 용량

| ID | 요구사항 | 검증 기준 |
| --- | --- | --- |
| NFR-PERF-001 | 인스턴스당 활성 사용자 최대 50명을 지원해야 한다. | 관리자 사용자 목록과 운영대장에서 활성 사용자 수 확인 |
| NFR-PERF-002 | 일반 운영의 목표 동시 접속자 수는 10~20명으로 한다. | 내부·고객 파일럿에서 실제 동시 사용 시 주요 기능 확인 |
| NFR-PERF-003 | 정상 부하에서 일반 메시지가 3초 이내 표시되는 것을 목표로 한다. | 파일럿에서 대표 메시지 송수신 시간을 기록 |
| NFR-PERF-004 | 정상 부하에서 채널 전환이 3초 이내 완료되는 것을 목표로 한다. | 웹과 모바일에서 대표 채널 전환 시간을 기록 |
| NFR-PERF-005 | 25MiB 이하 파일의 업로드와 다운로드가 정상 동작해야 한다. | 경계값 전후 파일 시험 |
| NFR-PERF-006 | 합의된 한글 검색 말뭉치에서 검색 결과가 정확해야 한다. | `SEARCH-01`~`SEARCH-12` 통과 |
| NFR-PERF-007 | 대표 누적 게시물 규모에서 CJK 검색 응답시간을 기록해야 한다. | `SEARCH-13` 결과와 수용 여부 기록 |
| NFR-PERF-008 | 반복적인 메모리 부족, 컨테이너 종료 또는 사용자 체감 지연이 없어야 한다. | 시스템 지표·컨테이너 재시작 횟수·파일럿 피드백 확인 |
| NFR-PERF-009 | 용량 부족이 반복되면 동일 아키텍처 안에서 VM 또는 Boot Volume을 수직 확장해야 한다. | 확장 전후 사양과 사유 기록 |

3초 기준은 고객에게 제공하는 SLA가 아니라 파일럿 품질 목표다. 일시적인 네트워크 지연 한 건만으로 출시를 차단하지 않으며, 동일 조건에서 반복되는 지연과 기능 사용 불가 여부를 함께 판단한다.

## 12.2 가용성

| ID | 요구사항 |
| --- | --- |
| NFR-AVL-001 | VM 재부팅 후 ThreadHub 서비스가 자동으로 시작되어야 한다. |
| NFR-AVL-002 | Mattermost와 PostgreSQL 컨테이너에 적절한 Docker 재시작 정책을 적용해야 한다. |
| NFR-AVL-003 | NGINX가 호스트 재부팅 후 자동으로 시작되어야 한다. |
| NFR-AVL-004 | 인증서 자동 갱신 타이머가 활성화되어야 한다. |
| NFR-AVL-005 | 계획된 업데이트 중 일시적인 서비스 중단을 허용한다. |
| NFR-AVL-006 | 별도 가용성 SLA를 제공하지 않는다. |
| NFR-AVL-007 | 자동 장애조치, 다중 노드와 무중단 배포를 제공하지 않는다. |

단일 VM, 로컬 PostgreSQL과 Boot Volume은 공통 장애 지점이다. 이 제약은 고객 파일럿 전에 안내해야 한다.

## 12.3 보안

| ID | 요구사항 |
| --- | --- |
| NFR-SEC-001 | 모든 사용자 접속을 HTTPS로 제공해야 한다. |
| NFR-SEC-002 | HTTP 요청을 HTTPS로 전환해야 한다. |
| NFR-SEC-003 | SSH는 승인된 관리자 IP에서만 허용해야 한다. |
| NFR-SEC-004 | SSH 공개키 인증만 사용해야 한다. |
| NFR-SEC-005 | SSH 비밀번호 로그인과 root 직접 로그인을 비활성화해야 한다. |
| NFR-SEC-006 | Mattermost 8065 포트를 인터넷에 공개하지 않아야 한다. |
| NFR-SEC-007 | PostgreSQL 5432 포트를 호스트와 인터넷에 공개하지 않아야 한다. |
| NFR-SEC-008 | Calls 8443 포트를 공개하지 않아야 한다. |
| NFR-SEC-009 | Docker API와 Docker Socket을 네트워크에 공개하지 않아야 한다. |
| NFR-SEC-010 | 초대 없는 직접 회원가입을 차단해야 한다. |
| NFR-SEC-011 | Team 초대 URL을 비밀 초대 링크로 취급해야 한다. |
| NFR-SEC-012 | System Admin 계정을 1~2개로 제한하고 MFA를 등록해야 한다. |
| NFR-SEC-013 | 일반 Member에게 관리자·초대·Team 생성·채널 생성·통합 생성 권한을 부여하지 않아야 한다. |
| NFR-SEC-014 | 실제 `.env`, 비밀번호, 자격 증명과 개인키를 Git에 저장하지 않아야 한다. |
| NFR-SEC-015 | 실제 `.env`는 서버 관리자만 읽을 수 있도록 최소 권한을 적용해야 한다. |
| NFR-SEC-016 | 사용자 플러그인 업로드와 불필요한 Webhook·통합을 비활성화해야 한다. |
| NFR-SEC-017 | Enterprise Trial과 유료 라이선스를 활성화하지 않아야 한다. |
| NFR-SEC-018 | 공개 파일 링크와 외부 링크 미리보기를 비활성화해야 한다. |
| NFR-SEC-019 | 서로 신뢰하지 않는 고객 집단을 독립 인스턴스로 분리해야 한다. |
| NFR-SEC-020 | 고위험·규제 데이터의 업로드를 금지하고 고객에게 데이터 취급 범위를 안내해야 한다. |
| NFR-SEC-021 | Mattermost 진단 텔레메트리를 비활성화하고 실제 적용 상태를 확인해야 한다. |

## 12.4 데이터 유지와 복구 한계

| ID | 요구사항 |
| --- | --- |
| NFR-DATA-001 | PostgreSQL과 Mattermost 중요 경로를 컨테이너 임시 파일시스템과 분리해야 한다. |
| NFR-DATA-002 | 컨테이너 재시작·재생성 후 계정, 메시지와 첨부파일이 유지되어야 한다. |
| NFR-DATA-003 | VM 재부팅 후 데이터가 유지되어야 한다. |
| NFR-DATA-004 | 채널 보관과 사용자 비활성화 후 기존 이력이 유지되어야 한다. |
| NFR-DATA-005 | 모든 중요 저장 경로가 예상한 bind mount인지 검사해야 한다. |
| NFR-DATA-006 | 중요 경로에 의도하지 않은 anonymous volume이 없어야 한다. |
| NFR-DATA-007 | PostgreSQL 논리 덤프, Mattermost 첨부파일과 notifier queue를 하나의 검증 가능한 backup set으로 매일 생성해야 한다. |
| NFR-DATA-008 | 마지막 원격 검증 성공 세트의 변경 불가능한 backup ID 생성시각을 기준으로 RPO 24시간, 수동 복구 RTO 4시간을 목표로 해야 한다. |
| NFR-DATA-009 | 백업 중 Mattermost와 notifier의 쓰기 중단 단계 전체에 절대 300초 deadline을 적용하고 timeout·초과 세트를 업로드하지 않아야 한다. |
| NFR-DATA-010 | 프로젝트 전용 비공개 OCI Object Storage 버킷에서 원격 객체 크기와 SHA-256을 검증해야 한다. |
| NFR-DATA-011 | 최근 daily 백업을 7일, 일요일 weekly 백업을 28일 보존해야 한다. |
| NFR-DATA-012 | 복구는 동일 커밋·고정 이미지의 신규 VM과 new or empty `/srv/threadhub`에서만 허용하고 host lock과 원자적 no-clobber target claim을 적용해야 한다. |
| NFR-DATA-013 | 복구한 notifier queue는 격리하고 새 live queue와 delivery를 비활성 상태로 시작해야 한다. |
| NFR-DATA-014 | 최초 타이머 활성화 전에 원격 수동 백업과 폐기 가능한 신규 VM 복구시험을 통과하고 승인 ID의 정확한 5개 원격 객체를 다시 검증해야 한다. |
| NFR-DATA-015 | 데이터 삭제 시험과 복구시험은 폐기 가능한 기술 시험 인스턴스에서만 수행해야 한다. |
| NFR-DATA-016 | 프로젝트 완전 폐기 후 데이터가 복구되지 않음을 안내해야 한다. |

ThreadHub의 “이력 유지”는 정상 영속성과 최근 검증 성공 backup set까지의 수동
복구를 의미한다. 마지막 성공 이후 데이터, 자동 장애조치, 무손실 복구, PITR와
법적 보존은 보장하지 않는다.

## 12.5 유지보수성과 재현성

| ID | 요구사항 |
| --- | --- |
| NFR-MNT-001 | 운영체제, Docker, Compose, NGINX, Mattermost와 PostgreSQL 버전을 기록해야 한다. |
| NFR-MNT-002 | Docker 이미지에 `latest` 태그를 사용하지 않아야 한다. |
| NFR-MNT-003 | Mattermost ESR 패치 버전을 명시적으로 고정해야 한다. |
| NFR-MNT-004 | PostgreSQL 메이저·패치 버전을 명시적으로 고정해야 한다. |
| NFR-MNT-005 | 사용한 Docker 이미지 태그와 Digest를 모두 기록해야 한다. |
| NFR-MNT-006 | Docker Compose와 NGINX 설정을 버전 관리해야 한다. |
| NFR-MNT-007 | 실제 `.env`를 버전 관리에서 제외하고 `.env.example`을 제공해야 한다. |
| NFR-MNT-008 | 메이저 버전을 자동 업그레이드하지 않아야 한다. |
| NFR-MNT-009 | PostgreSQL 메이저 업그레이드를 단순 이미지 태그 교체로 수행하지 않아야 한다. |
| NFR-MNT-010 | 새 OCI VM에 배포 패키지로 동일한 논리 구성을 반복 배포할 수 있어야 한다. |
| NFR-MNT-011 | 배포 전 `docker compose config`와 이미지 가용성을 확인해야 한다. |
| NFR-MNT-012 | 설정 변경, 업데이트와 프로젝트 종료 절차를 문서화해야 한다. |

## 12.6 사용성과 호환성

| ID | 요구사항 |
| --- | --- |
| NFR-UX-001 | 웹, 공식 데스크톱 앱, 공식 iOS 앱과 공식 Android 앱에서 동일 서버 주소로 접속할 수 있어야 한다. |
| NFR-UX-002 | 한글 메시지 입력, 표시와 검색이 가능해야 한다. |
| NFR-UX-003 | 사용자는 채널 목적과 스레드 사용 규칙을 쉽게 확인할 수 있어야 한다. |
| NFR-UX-004 | 모바일 푸시가 없다는 사실과 긴급 연락 대안을 온보딩 시 안내해야 한다. |
| NFR-UX-005 | 파일 크기 제한과 금지 데이터 정책을 사용자가 확인할 수 있어야 한다. |
| NFR-UX-006 | 단일 VM 중단, RPO 24시간·수동 RTO 4시간 목표와 프로젝트 종료 정책을 고객 파일럿 전에 안내해야 한다. |

---

# 13. 기술 기준선

## 13.1 확정 기술 스택

| 구성요소 | 기준 버전 또는 정책 |
| --- | --- |
| 클라우드 | Oracle Cloud Infrastructure |
| VM | OCI Compute VM 1대 |
| CPU 아키텍처 | AMD 기반 x86_64 |
| 초기 VM 사양 | 2 OCPU, 16GB RAM |
| Boot Volume | 50GB 이상 |
| 운영체제 | Ubuntu Server 24.04 LTS |
| Mattermost | `mattermost/mattermost-team-edition:11.7.7` |
| PostgreSQL | `postgres:18.4` 또는 승인된 명시적 18.4 변형 태그 |
| Docker Engine | 29.6.2 목표 기준 |
| Docker Compose | Docker Compose Plugin |
| 리버스 프록시 | Ubuntu 저장소 NGINX, 호스트 설치 |
| TLS | Let’s Encrypt |
| 인증서 관리 | Certbot |
| SMTP | OCI Email Delivery |
| 데이터베이스 배치 | Mattermost와 동일 VM의 컨테이너 |
| 데이터 저장 | Boot Volume의 `/srv/threadhub` bind mount |
| 모바일 푸시 | 비활성화 |
| 백업·복구 | 일일 OCI Object Storage backup set, 수동 신규 VM 복구 |
| 중앙 로깅·모니터링 | 미구성 |
| 고가용성 | 미구성 |

Ubuntu 24.04 LTS의 수명주기 기준은 [Ubuntu 24.04 LTS 릴리스 정보](https://documentation.ubuntu.com/release-notes/24.04/)를 따른다.

## 13.2 버전 고정 정책

- Ubuntu 24.04 LTS 계열을 유지한다.
- Mattermost 11.7.x ESR 계열에서 검증된 패치 버전을 사용한다.
- PostgreSQL 18.x 계열에서 검증된 패치 버전을 사용한다.
- Docker Engine은 배포 시점에 공식 저장소에서 설치 가능한 명시적 29.x 패치 버전을 사용한다.
- 기준 버전과 다른 패치 버전을 채택하면 변경 사유, 보안 검토와 재시험 결과를 기록한다.
- 메이저 버전 변경은 별도 설계와 데이터 이전 검증 없이는 수행하지 않는다.
- 모든 컨테이너 이미지의 태그와 실제 pull된 Digest를 `versions.env` 또는 배포 기록에 남긴다.

Docker Engine 29.6.2가 대상 Ubuntu 저장소에서 제공되지 않으면 임의 설치 파일이나 `latest`로 대체하지 않는다. 공식 Docker 저장소에서 제공되는 승인된 29.x 패치 버전을 명시하고 배포 전 검증 결과를 기록한다.

## 13.3 자원 기준과 확장

초기 자원은 AMD 기반 x86_64, 2 OCPU, 16GB RAM, Boot Volume 50GB 이상으로 한다.

수직 확장 검토 신호:

- 메모리 부족 또는 OOM으로 컨테이너가 종료됨
- Mattermost 또는 PostgreSQL이 반복 재시작됨
- 채널 전환, 검색 또는 파일 업로드 지연이 반복됨
- Boot Volume 또는 `/srv/threadhub` 사용률이 지속 증가함
- 파일럿 이후 사용자 또는 누적 게시물 규모가 계획보다 증가함

확장은 CPU·메모리 또는 Boot Volume 용량을 늘리는 방식으로 수행한다. MVP에서는 ARM 전환, 다중 VM 또는 데이터베이스 분리를 확장 기본안으로 사용하지 않는다.

## 13.4 핵심 설정 기준

| 영역 | 필수 결과 | 주요 설정 후보 |
| --- | --- | --- |
| 가입 | 초대 없는 직접 가입 차단 | `MM_TEAMSETTINGS_ENABLEOPENSERVER=false` |
| 이메일 초대 | 관리자의 이메일 초대 허용 | `MM_SERVICESETTINGS_ENABLEEMAILINVITATIONS=true` |
| 이메일 확인 | 확인 전 로그인 차단 | `MM_EMAILSETTINGS_REQUIREEMAILVERIFICATION=true` |
| 비밀번호 | 최소 12자 | `MM_PASSWORDSETTINGS_MINIMUMLENGTH=12` |
| 비밀번호 세션 | 변경·재설정 후 기존 세션 종료 | `MM_SERVICESETTINGS_TERMINATESESSIONSONPASSWORDCHANGE=true` |
| MFA | 사용자별 MFA 활성화, System Admin 등록 | `MM_SERVICESETTINGS_ENABLEMULTIFACTORAUTHENTICATION=true` |
| 모바일 푸시 | 비활성화 | `MM_EMAILSETTINGS_SENDPUSHNOTIFICATIONS=false` |
| Mattermost 기본 일반 이메일 알림 | 비활성화 | `MM_EMAILSETTINGS_SENDEMAILNOTIFICATIONS=false` |
| ThreadHub 채널 이메일 알림 | 별도 plugin·Mailer, 초기 fail-closed | SMTP acceptance와 명시적 activation |
| 활성 사용자 | 운영정책상 최대 50명 | 운영대장 확인 |
| Team 사용자 한도 | 사용자 교체 여유 250명 | `MM_TEAMSETTINGS_MAXUSERSPERTEAM=250` |
| 채널 한도 | Team당 2,000개 | `MM_TEAMSETTINGS_MAXCHANNELSPERTEAM=2000` |
| 파일 크기 | 25MiB | `MM_FILESETTINGS_MAXFILESIZE=26214400` |
| CJK 검색 | 정확한 이미지에서 부분 문자열 검색 | `MM_FEATUREFLAGS_CJKSEARCH=true` |
| 진단 텔레메트리 | 비활성화 | 정확한 이미지의 설정 키와 적용 상태 확인 |

환경변수 이름과 실제 적용 결과는 고정한 Mattermost 이미지에서 확인한다. 환경변수가 설정되어 있다는 사실만으로 요구사항 충족을 판정하지 않고, 사용자 관점의 동작 시험을 통과해야 한다.

## 13.5 라이선스와 제품 에디션 정책

- Mattermost Team Edition만 사용한다.
- 유료 라이선스 키를 설치하지 않는다.
- Enterprise Trial을 활성화하지 않는다.
- 유료 Guest, SSO, Team Override, 유료 감사·보존·접근제어 기능을 사용하지 않는다.
- Mattermost Calls를 사용하지 않는다.
- 상업적 고객 프로젝트에 무료 TPNS를 사용하지 않는다.
- ThreadHub notifier는 Mattermost 공개 플러그인 API만 사용하고 Enterprise 코드,
  유료 기능 활성화 또는 라이선스 검사 우회를 포함하지 않는다.
- notifier 플러그인 번들과 Mailer 이미지에 ThreadHub MIT 라이선스와 제3자 의존성
  고지를 포함한다.
- 무료 기능인지 불명확한 기능은 정확한 이미지와 공식 근거를 확인한 뒤 채택한다.

---

# 14. 시스템 아키텍처와 네트워크

## 14.1 논리 아키텍처

```text
웹·데스크톱·모바일 사용자
             │
             │ HTTPS 443
             ▼
      OCI 예약 공인 IP
             │
             ▼
        OCI NSG / VCN
             │
             ▼
┌────────────────────────────────────┐
│ OCI Compute VM                     │
│ Ubuntu Server 24.04 LTS            │
│ AMD x86_64 · 2 OCPU · 16GB RAM     │
│                                    │
│ Host                               │
│ ├── NGINX                          │
│ └── Certbot                        │
│        │ 127.0.0.1:8065            │
│        ▼                           │
│ Docker Compose                     │
│ ├── Mattermost Team Edition        │
│ │   └── ThreadHub notifier plugin  │
│ ├── PostgreSQL                     │
│ └── ThreadHub Mailer               │
│        │                           │
│        ▼                           │
│ /srv/threadhub 영구 bind mounts    │
└────────────────────────────────────┘
             │
             └── OCI Email Delivery SMTP 587/STARTTLS
```

## 14.2 요청 경로

1. 사용자는 프로젝트별 도메인으로 접속한다.
2. TCP 80 요청은 HTTPS로 전환된다.
3. TCP 443 요청은 NGINX에서 TLS를 종료한다.
4. NGINX는 HTTP와 WebSocket 요청을 `127.0.0.1:8065`의 Mattermost로 전달한다.
5. Mattermost는 Docker 내부 네트워크를 통해 PostgreSQL에 접속한다.
6. PostgreSQL은 호스트 포트를 공개하지 않는다.
7. 계정 관련 이메일은 OCI Email Delivery를 통해 발송한다.
8. 새 채널 글·스레드 답글은 플러그인이 감지하고 최소 이벤트를 plugin KV outbox에
   기록한다.
9. 플러그인은 HMAC 서명 요청을 호스트 포트가 없는 내부 network의 Mailer로 보낸다.
10. Mailer는 수신자별 작업을 SQLite 영구 큐에 저장한 뒤 OCI Email Delivery로
    일반 안내 이메일을 발송한다.

## 14.3 포트와 접근정책

| 포트 또는 인터페이스 | 접근 범위 | 목적 | 정책 |
| --- | --- | --- | --- |
| TCP 80 | 인터넷 | 인증서 발급과 HTTPS 전환 | 공개 |
| TCP 443 | 인터넷 | ThreadHub 웹·앱 접속 | 공개 |
| TCP 22 | 승인된 관리자 IP | SSH 관리 | 제한 공개 |
| TCP 8065 | `127.0.0.1` | NGINX에서 Mattermost 연결 | 인터넷 비공개 |
| TCP 5432 | Docker 내부 네트워크 | Mattermost에서 PostgreSQL 연결 | 호스트·인터넷 비공개 |
| TCP/UDP 8443 | 없음 | Mattermost Calls | 공개 금지 |
| Docker API/Socket | 로컬 관리자만 | Docker 관리 | 네트워크 공개 금지 |

Mattermost 포트 바인딩 기준:

```yaml
ports:
  - "127.0.0.1:8065:8065"
```

PostgreSQL 서비스에는 호스트 `ports` 항목을 두지 않는다.

## 14.4 신뢰 경계

| 경계 | 신뢰 수준 | 보호 방법 |
| --- | --- | --- |
| 인터넷 ↔ OCI VM | 비신뢰 | NSG, HTTPS, 제한된 공개 포트 |
| NGINX ↔ Mattermost | 동일 호스트 내부 | loopback 바인딩 |
| Mattermost ↔ PostgreSQL | 전용 Compose 네트워크 | DB 호스트 포트 미공개, DB 자격 증명 |
| 관리자 ↔ VM | 제한된 고신뢰 | 고정 IP, SSH 키, root·비밀번호 로그인 금지 |
| 프로젝트 A ↔ 프로젝트 B | 상호 비신뢰 | 별도 VM·DB·도메인·자격 증명 |
| Internal Team ↔ Project Team | 동일 인스턴스 신뢰 경계 | Team과 채널 권한, 운영정책 |

## 14.5 장애 모델

다음 구성요소는 단일 장애 지점이다.

- OCI Compute VM
- Boot Volume
- 호스트 NGINX
- Mattermost 컨테이너
- PostgreSQL 컨테이너
- 프로젝트 도메인과 인증서
- OCI Email Delivery 설정

ThreadHub는 자동 장애조치나 별도 복구 인프라를 제공하지 않는다. 컨테이너 또는 VM 재시작으로 해결되지 않는 장애는 서비스 중단 또는 데이터 손실로 이어질 수 있다.

---

# 15. 데이터 저장과 영속성

## 15.1 저장 대상과 경로

| 구성요소 | 컨테이너 경로 | 호스트 경로 | 방식 |
| --- | --- | --- | --- |
| PostgreSQL | `/var/lib/postgresql` | `/srv/threadhub/postgres` | bind mount |
| Mattermost 설정 | `/mattermost/config` | `/srv/threadhub/mattermost/config` | bind mount |
| 첨부파일 | `/mattermost/data` | `/srv/threadhub/mattermost/data` | bind mount |
| Mattermost 로그 | `/mattermost/logs` | `/srv/threadhub/mattermost/logs` | bind mount |
| 서버 플러그인 경로 | `/mattermost/plugins` | `/srv/threadhub/mattermost/plugins` | bind mount |
| 클라이언트 플러그인 경로 | `/mattermost/client/plugins` | `/srv/threadhub/mattermost/client/plugins` | bind mount |
| Bleve 인덱스 경로 | `/mattermost/bleve-indexes` | `/srv/threadhub/mattermost/bleve-indexes` | bind mount |

플러그인을 비활성화하더라도 공식 이미지가 선언하거나 사용하는 경로가 anonymous volume으로 남지 않도록 위 6개 Mattermost 경로를 모두 명시적으로 연결한다.

## 15.2 PostgreSQL 18 저장 규칙

PostgreSQL 공식 이미지는 18부터 볼륨 정의 기준을 `/var/lib/postgresql`로 변경했다. ThreadHub는 다음 규칙을 적용한다.

- 호스트 `/srv/threadhub/postgres`를 컨테이너 `/var/lib/postgresql`에 연결한다.
- 과거 버전의 `/var/lib/postgresql/data` 경로를 관성적으로 사용하지 않는다.
- PostgreSQL 서비스에 임의의 `user:` 값을 지정하지 않는다.
- 공식 entrypoint가 최초 기동 시 초기화와 권한 설정을 수행하게 한다.
- 고정한 이미지 Digest에서 실제 `PGDATA`, mount와 쓰기 가능 여부를 확인한다.
- 메이저 버전 변경은 `pg_dump/restore` 또는 `pg_upgrade` 계획과 검증 후 수행한다.

기준 예시:

```yaml
services:
  postgres:
    image: postgres:18.4
    volumes:
      - /srv/threadhub/postgres:/var/lib/postgresql
```

자세한 기준은 [PostgreSQL 공식 Docker 이미지](https://hub.docker.com/_/postgres/)를 따른다.

## 15.3 Mattermost 저장 규칙

Mattermost Team Edition 11.7.7 공식 이미지는 기본적으로 UID/GID `2000:2000`의 `mattermost` 사용자로 실행한다. 최초 기동 전에 다음 조건을 충족해야 한다.

- `/srv/threadhub/mattermost` 아래 6개 영구 디렉터리를 생성한다.
- 고정 이미지 Digest의 실행 UID/GID를 확인한다.
- 공식 이미지 기준 UID/GID `2000:2000`으로 호스트 디렉터리 소유권을 설정한다.
- 각 경로의 읽기·쓰기 시험을 통과한다.
- 공식 사전 빌드 이미지를 사용하는 MVP에서 UID/GID 변경용 사용자 정의 이미지를 만들지 않는다.

기준 예시:

```yaml
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
```

구성 기준은 [Mattermost 공식 컨테이너 배포](https://docs.mattermost.com/deployment-guide/server/deploy-containers.html)와 [Mattermost 공식 Docker Compose](https://github.com/mattermost/docker/blob/main/docker-compose.yml)를 따른다.

## 15.4 작업별 데이터 유지 계약

| 작업 또는 사건 | 기대 결과 |
| --- | --- |
| Mattermost 컨테이너 재시작 | 유지 |
| PostgreSQL 컨테이너 재시작 | 유지 |
| `docker compose down` 후 재생성 | bind mount 데이터 유지 |
| Mattermost 컨테이너 재생성 | 유지 |
| PostgreSQL 컨테이너 재생성 | 유지 |
| 검증된 동일 메이저 패치 이미지 교체 | 유지, 사전 호환성 검증 필요 |
| VM 중지 후 다시 시작 | 유지 |
| VM 재부팅 | 자동 시작 및 유지 |
| 채널 보관 | 기존 기록 유지, 새 메시지 작성 중지 |
| 사용자 비활성화 | 기존 메시지 유지, 로그인 차단 |
| VM 삭제·Boot Volume 유지 | Boot Volume 재연결 또는 최근 검증 backup set으로 수동 복구 |
| 영구 bind mount 경로 수동 삭제 | 최근 검증 backup set까지만 신규 VM 수동 복구 가능 |
| Boot Volume 손상 | 최근 검증 backup set까지만 신규 VM 수동 복구 가능 |
| VM과 Boot Volume 모두 삭제 | Object Storage backup set이 유지된 경우에만 수동 복구 가능 |
| VM·Boot Volume·Object Storage 백업 완전 삭제 | 복구 불가 |

## 15.5 `docker compose down -v` 정책

`docker compose down -v`는 호스트 bind mount의 원본 데이터를 삭제하지 않지만 Compose named volume과 컨테이너 anonymous volume을 삭제한다.

ThreadHub는 다음 통제를 적용한다.

- PostgreSQL과 Mattermost 중요 경로를 모두 bind mount로 구성한다.
- `docker compose config`와 `docker inspect`로 mount 유형, source와 destination을 확인한다.
- 중요 경로에 anonymous volume이 없는지 확인한다.
- 정상 운영 절차에서는 `down -v`를 사용하지 않는다.
- 삭제 동작 검증은 폐기 가능한 기술 시험 인스턴스에서만 수행한다.

이 명령의 동작 기준은 [Docker Compose `down`](https://docs.docker.com/reference/cli/docker/compose/down/)을 따른다.

## 15.6 보존과 폐기의 의미

채널 메시지와 첨부파일은 VM과 영구 저장 경로가 정상 유지되는 동안 보존되고,
원격 검증된 backup set이 있으면 해당 시점까지 신규 VM에서 수동 복구할 수 있다.
ThreadHub는 영구 기록보관 시스템이 아니며 다음을 보장하지 않는다.

- 마지막 검증 성공 이후 데이터의 복구
- 무중단·무손실 복구와 자동 장애조치
- 임의 시점 복구(PITR)와 리전 장애 시 자동 전환
- 악성 행위나 보안사고 이전의 안전한 상태 판별
- 프로젝트 완전 폐기 후 복구
- 고객 기기로 내려받은 파일의 원격 회수

---

# 16. 보안과 데이터 거버넌스

## 16.1 허용 데이터

ThreadHub에는 다음 범주의 정보만 저장한다.

- 일반 프로젝트 질문과 답변
- 진행 상황과 차단사항
- 결정사항과 근거
- 일반 업무 문서
- 공개되었거나 프로젝트 참여자 간 공유가 승인된 링크
- 고객이 해당 ThreadHub 참여자에게 공유하도록 승인한 자료

## 16.2 금지 데이터

다음 정보는 메시지, 파일, 코드 블록 또는 링크 접근정보의 형태로 업로드하지 않는다.

- 비밀번호
- API 키와 액세스 토큰
- SSH·TLS 개인키
- OCI, 데이터베이스와 SMTP 자격 증명
- 주민등록번호 등 고위험 식별정보
- 결제카드 정보
- 의료·금융 규제정보
- 별도 컴플라이언스나 법정 보존이 필요한 자료
- 참여자 전체에게 공개해서는 안 되는 다른 고객 정보
- 유출 시 중대한 피해를 일으키는 운영 비밀

## 16.3 신원과 접근 통제

ThreadHub의 접근 통제는 다음 계층으로 구성한다.

```text
정보 공유 경계별 독립 인스턴스
→ 관리자 이메일 초대
→ 이메일 주소 확인
→ 비밀번호 인증
→ System Admin MFA
→ System Scheme의 Member 권한 제한
→ Team·채널 멤버십
→ 프로젝트 종료 시 제거·비활성화
```

핵심 원칙:

- 인스턴스 분리가 고객 간 최상위 보안 경계다.
- Team과 비공개 채널은 동일 신뢰 경계 내부의 접근 구성 수단이다.
- Team 초대 URL은 공개 가입 주소가 아니라 bearer invitation으로 취급한다.
- System Scheme의 제한 결과를 고객 Member 계정으로 직접 시험한다.
- System Admin의 사용자별 MFA 등록은 관리자 운영정책으로 강제한다.
- 관리자 권한 부여·회수와 MFA 복구 결과를 기록한다.

## 16.4 비밀정보 관리

| 비밀 또는 민감 설정 | 저장 위치 | 관리 원칙 |
| --- | --- | --- |
| PostgreSQL 비밀번호 | 서버의 실제 `.env` | Git 제외, 최소 파일 권한, 프로젝트별 신규 생성 |
| SMTP 사용자명·비밀번호 | 서버의 실제 `.env` | Git 제외, 프로젝트 종료 시 폐기 또는 교체 |
| Mattermost System Admin 비밀번호 | 비밀번호 관리자 | 계정 공유 금지, 16자 이상 권장, MFA 등록 |
| SSH 개인키 | 승인된 관리자 기기 | 서버·Git 업로드 금지 |
| TLS 개인키 | Certbot 관리 경로 | 서버 관리자 외 접근 제한 |
| OCI API·콘솔 자격 증명 | OCI 및 승인된 관리자 저장소 | MFA와 최소 권한 적용 |

`.env.example`에는 변수명, 형식과 설명만 포함하고 실제 값이나 재사용 가능한 예시 비밀번호를 포함하지 않는다.

## 16.5 로그와 개인정보

- Mattermost, PostgreSQL, NGINX와 시스템 로그는 로컬 운영 점검 목적으로만 사용한다.
- MVP에서는 OCI Logging 또는 중앙 로그 수집을 사용하지 않는다.
- 로그 접근은 시스템 관리자로 제한한다.
- 로그에 비밀번호, 토큰 또는 메시지 본문을 의도적으로 추가 기록하지 않는다.
- 로그 크기와 회전 상태를 점검해 디스크 고갈을 방지한다.
- 별도 감사로그와 컴플라이언스 증적을 제공하지 않는다.

## 16.6 고객 사전 고지

제한된 고객 파일럿 시작 전 다음 내용을 서면 또는 공지 채널로 안내한다.

1. 모바일 푸시는 제공되지 않는다.
2. 긴급 연락에는 전화·이메일 등 별도 수단을 사용한다.
3. 단일 VM 서비스이며 별도 SLA와 자동 장애조치가 없다.
4. 백업 RPO는 24시간, 수동 복구 RTO는 4시간 목표이며 HA·PITR·SLA가 아니다.
5. 고위험·규제 데이터와 비밀정보를 업로드하지 않는다.
6. 고객에게 관리자 권한과 임의 초대·Team·채널 생성 권한을 부여하지 않는다.
7. 고객 기기에 저장한 파일은 계정 비활성화나 서버 폐기로 회수되지 않는다.
8. 프로젝트 종료 시 기록 유지 또는 완전 폐기 방식을 선택한다.

## 16.7 주요 보안 시나리오와 통제

| 시나리오 | 예방·완화 통제 | 잔여 위험 |
| --- | --- | --- |
| 초대 없는 외부인 가입 | Open Server 비활성화, 직접 가입 시험 | 설정 변경 시 재노출 가능 |
| Team 초대 URL 유출 | URL 비배포, 코드 재생성, 이전 URL 무효화 시험 | 재생성 전에는 링크 소지자 가입 가능 |
| 관리자 계정 탈취 | 1~2개 계정, 강한 비밀번호, 사용자별 MFA | 전 사용자 MFA 강제 기능은 사용하지 않음 |
| 고객의 임의 사용자 초대 | System Scheme 권한 제거와 Member 시험 | 관리자 설정 회귀 가능 |
| 고객 간 정보 노출 | 정보 공유 경계별 독립 VM | 운영자가 잘못된 인스턴스에 초대할 위험 |
| DB·SMTP 자격 증명 유출 | `.env` Git 제외, 파일 권한, 프로젝트별 자격 증명 | 호스트 관리자 계정 침해 시 노출 가능 |
| 내부 포트 노출 | NSG, loopback, DB host port 미설정, 외부 스캔 | 설정 변경 시 노출 가능 |
| 악성 또는 민감 파일 업로드 | 사용정책과 허용 데이터 제한 | 악성코드 자동 검사가 없음 |
| 데이터 손실 | bind mount, 일일 원격 검증 백업과 신규 VM 복구시험 | 마지막 성공 이후 최대 24시간 손실, 수동 복구와 단일 리전 한계 |

---

# 17. 운영 요구사항

## 17.1 운영 모델

ThreadHub는 소규모·단기 프로젝트용 단일 인스턴스로 운영한다.

- 시스템 관리자는 인프라, 버전, 인증서, SMTP와 서비스 상태를 관리한다.
- ThreadHub 관리자는 사용자, 권한, Team, 채널과 종료 절차를 관리한다.
- 내부 담당자는 고객 커뮤니케이션 품질과 결정사항 기록을 책임진다.
- 고객은 허용된 프로젝트 공간에서 일반 Member로 참여한다.
- 야간·휴일 상시 대응과 별도 SLA는 제공하지 않는다.

## 17.2 최소 운영 점검

중앙 모니터링을 구축하지 않더라도 다음 점검은 기본 서버 관리로 수행한다.

| 점검 항목 | 권장 시점 | 이상 기준 | 기본 조치 |
| --- | --- | --- | --- |
| Boot Volume 사용률 | 주 1회, 변경 후 | 지속 증가 또는 여유 부족 | 큰 파일·로그 확인, 용량 확장 검토 |
| `/srv/threadhub` 사용량 | 주 1회 | 예상보다 빠른 증가 | DB·첨부파일·로그 원인 분리 |
| 컨테이너 상태 | 배포·재부팅 후, 주 1회 | 비정상 종료·unhealthy | 로그 확인, 원인 수정 후 재시작 |
| 컨테이너 재시작 횟수 | 주 1회 | 반복 증가 | OOM·설정·DB 연결 확인 |
| Mattermost health | 배포·변경·주 1회 | health 실패 | 애플리케이션·DB 연결 확인 |
| PostgreSQL health | 배포·변경·주 1회 | health 실패 | 저장 경로·권한·DB 로그 확인 |
| NGINX 상태 | 배포·인증서 변경 후 | 서비스 실패·502 | 설정 검사와 upstream 확인 |
| HTTPS 인증서 만료일 | 주 1회 | 갱신 실패 또는 임박 | Certbot 로그와 DNS·포트 확인 |
| Certbot 갱신 타이머 | 배포·주 1회 | 비활성·실패 | 타이머 복구 후 dry-run |
| SMTP 실패 로그 | 초대 작업 후, 주 1회 | 발송 실패·반송 | 자격 증명·Approved Sender 확인 |
| OCI suppression 목록 | 메일 실패 시, 주 1회 | 대상 주소 억제 | 원인 확인 후 정책에 따라 해제 |
| 로그 크기·회전 | 주 1회 | 무제한 증가 | 로그 회전 설정과 보존량 조정 |
| 마지막 원격 백업 검증 | 매일 | 24시간 초과 | 신규 변경 중지, 수동 백업·원격 검증 복구 |
| daily·weekly 객체 세트 | 매일·일요일 | prefix별 5개 미만·초과 | 불완전 세트를 성공 처리하지 않고 원인 확인 |
| 백업 staging | 매일 | 실패 세트 무제한 증가 | 실패 원인·보존시간 확인 후 안전한 정리 |
| 백업 실패 이메일 | 매일 | 미수신 또는 민감정보 포함 | SMTP·redaction 확인, 상태를 서버에서 직접 점검 |

## 17.3 변경과 업데이트

운영 중 설정 또는 버전을 변경할 때 다음 절차를 적용한다.

1. 변경 목적과 대상 인스턴스를 식별한다.
2. 현재 이미지 태그·Digest와 설정 버전을 기록한다.
3. 공식 릴리스 정보와 호환성 요구사항을 확인한다.
4. 메이저 버전 자동 업그레이드를 금지한다.
5. 배포 구성을 정적 검증한다.
6. 허용된 중단시간에 변경한다.
7. 컨테이너, HTTPS, WebSocket, 로그인, 메시지와 데이터 유지 여부를 확인한다.
8. 변경 결과와 발견된 제한을 기록한다.

변경 전 수동 backup set을 생성하고 원격 검증을 확인한다. 이는 마지막 성공 이후
데이터의 무손실 복구를 보장하지 않는다. 데이터 이전이 필요한 변경은 일반 패치와
분리해 별도 계획으로 승인한다.

## 17.4 장애 대응

| 장애 유형 | 기본 대응 | 제품 보장 |
| --- | --- | --- |
| 단일 컨테이너 중지 | 상태·로그 확인 후 재시작 | 재시작 정책과 운영 대응 |
| VM 재부팅 필요 | 재부팅 후 자동 시작·데이터 확인 | 자동 시작 시험 |
| 인증서 갱신 실패 | Certbot·DNS·포트 확인 후 갱신 | 절차 제공, 복구시간 SLA 없음 |
| SMTP 발송 실패 | OCI 설정·suppression·로그 확인 | 계정 메일 동작 전까지 신규 초대 중지 |
| 디스크 고갈 위험 | 로그·파일 점검과 볼륨 확장 | 수동 점검·확장 |
| 보안 자격 증명 노출 | 자격 증명 폐기·교체, 접근 차단 | 수동 대응 |
| Boot Volume 손상·데이터 삭제 | 영향 확인, 마지막 성공 확인, 신규 VM 수동 복구 | RPO 24시간·RTO 4시간 목표, SLA 없음 |

보안사고 또는 데이터 손실이 의심되면 신규 사용자 초대와 변경 작업을 중지하고, 접근 차단과 자격 증명 교체를 우선한다.

## 17.5 백업과 복구 정책

- 매일 KST 새벽 PostgreSQL 논리 덤프, Mattermost 첨부파일과 notifier queue의
  애플리케이션 정합성 backup set을 생성한다.
- Mattermost와 notifier 쓰기 중단의 정지·snapshot·재시작·health 전체에 하나의 절대
  300초 deadline을 적용하고, timeout이나 초과 시 artifact를 업로드하지 않는다.
- backup set은 `database.dump`, `mattermost-data.tar.zst`,
  `notifier-queue.tar.zst`, `manifest.json`, `manifest.sha256`의 정확한 5개 객체다.
- `ap-singapore-1`의 프로젝트별 전용 비공개 OCI Object Storage 버킷을 사용하고
  기본 AES-256 서버 암호화와 TLS를 적용한다.
- VM은 Instance Principal로 정확한 버킷의 object create·inspect·read만 수행하며
  delete 권한을 갖지 않는다.
- daily 백업은 7일, 일요일 weekly 백업은 28일 보존한다.
- RPO는 마지막 원격 검증 성공 세트의 backup ID 생성시각으로부터 최대 24시간,
  수동 RTO는 필요한 승인과 백업 ID가 준비된 뒤 새 HTTPS 인수 완료까지 4시간을
  목표로 한다. 지연된 resume upload의 완료시각으로 RPO를 연장하지 않는다.
- unit은 비활성 상태로 등록하고, 최초 수동 원격 백업과 폐기 가능한 신규 VM
  복구시험의 증거를 검토한 뒤에만 타이머를 활성화한다.
- 복구 VM은 일반 배포 전에 전용 restore-host bootstrap으로 의존성만 설치한다. 복구
  대상은 동일 commit·고정 이미지의 new or empty `/srv/threadhub`로 제한하고,
  host-wide lock과 원자적 no-clobber claim으로 동시 실행·선점 race를 거부한다.
- 복구한 notifier queue는 격리하고 live delivery를 비활성화해 과거 이메일 재발송을 막는다.
- Dynamic Group, IAM policy, 실제 버킷·lifecycle 생성·변경·삭제는 대상 compartment와
  리전을 명시한 별도 사용자 승인 후 수행한다.

이 정책은 HA, PITR, 무중단·무손실 백업, 리전 간 복제, 자동 장애조치, 법적 보존과
복구시간 SLA를 제공하지 않는다.

## 17.6 지원과 긴급 연락

- 관리자 문의 경로를 `00-공지` 채널에 게시한다.
- ThreadHub 장애 시 사용할 별도 이메일 또는 전화 연락 경로를 안내한다.
- 모바일 푸시가 없으므로 긴급한 요청은 ThreadHub 메시지만으로 전달하지 않는다.
- 지원시간과 응답시간을 별도 SLA로 약속하지 않는다.

---

# 18. 출시와 파일럿 계획

## 18.1 단계별 출시 계획

| 단계 | 주요 작업 | 완료 조건 |
| --- | --- | --- |
| Phase 0. 기준선 확정 | PRD, 정보 공유 경계, 위험 수용, 버전 기준 승인 | 본 PRD 승인, 미결 결정사항에 책임자 지정 |
| Phase 1. 배포 패키지 | Compose, 환경변수 예제, 버전 파일, NGINX, 스크립트 작성 | `docker compose config` 성공, 비밀정보 없음 |
| Phase 2. OCI 인프라 | VM, Boot Volume, 예약 IP, NSG, DNS, SSH 구성 | 80·443과 제한된 22만 외부 접근 가능 |
| Phase 3. 애플리케이션 | Docker, PostgreSQL, Mattermost, bind mount 배포 | health 정상, 6개 Mattermost 경로와 PG18 경로 검증 |
| Phase 4. HTTPS | NGINX, Let’s Encrypt, Certbot, WebSocket 구성 | HTTPS·전환·WebSocket·갱신 시험 통과 |
| Phase 5. 이메일·알림 | OCI SMTP, Approved Sender, SPF, DKIM, notifier plugin·Mailer 구성 | 계정 메일과 공개·비공개 채널 notifier 시험 통과 |
| Phase 6. 기본 설정 | 가입, MFA, 권한, 파일, 검색, 푸시와 제외 기능 설정 | 정확한 이미지에서 설정 동작 시험 통과 |
| Phase 7. 프로젝트 구조 | Team, 채널, 관리자·Member 구성, 정책 공지 | 고객 권한과 기본 채널 구조 확인 |
| Phase 8. 내부 파일럿 | 기능·권한·검색·영속성·모바일·재부팅 시험 | 내부 파일럿 인수조건 통과 |
| Phase 9. 백업·복구 인수 | 비활성 등록, 수동 원격 백업, 폐기 VM 복구, 증거 승인 | RPO·RTO·5분 중단·queue 격리 검증 후 타이머 활성화 |
| Phase 10. 제한 고객 파일럿 | 고객 1~2명, 1~2주 권장 운영 | 고객 파일럿 Go 조건 충족 후 시작, 결과 기록 |
| Phase 11. 종료·재배포 | 보관 또는 폐기, 새 VM 재배포 시험 | 종료 기록과 재배포 시험 통과 |

## 18.2 내부 기술 파일럿

참여자:

- 시스템 관리자 1명
- 내부 프로젝트 담당자 1~2명

사용 데이터:

- 가상 고객과 시험 계정
- 실제 중요 고객자료 사용 금지

목적:

- 설치와 반복 배포 검증
- 가입 경로와 이메일 검증
- 공개·비공개 채널 새 글·스레드 notifier와 SMTP 장애 격리 검증
- System Scheme과 고객 Member 권한 검증
- 한글 검색 기능·성능 검증
- bind mount·컨테이너 재생성·VM 재부팅 검증
- 모바일 푸시 비활성화와 앱 동기화 검증
- 기록 유지·완전 폐기 절차 검증

내부 기술 파일럿은 구축 결과를 검증하는 단계이므로 시작 자체는 Go다. 필수 시험 실패가 남아 있으면 제한된 고객 파일럿으로 진행하지 않는다.

## 18.3 제한된 고객 파일럿

권장 구성:

- 시스템 관리자 1명
- 내부 담당자 1~2명
- 고객 사용자 1~2명
- 운영기간 1~2주

시작 조건:

- 19장의 고객 파일럿 Go 조건을 모두 충족한다.
- 고객 고지사항을 전달하고 내부 책임자가 잔여 위험을 수용한다.
- 긴급 연락 대안을 게시한다.
- 실제 고객 데이터는 16장의 허용 범위로 제한한다.

## 18.4 외부 의존성과 가정

| 의존성 또는 가정 | 영향 |
| --- | --- |
| OCI Compute와 예약 IP 사용 가능 | 인프라 생성과 고정 도메인 연결 |
| 프로젝트 도메인과 DNS 변경 권한 보유 | HTTPS와 모바일 앱 접속 |
| OCI Email Delivery 발송 승인·자격 증명 사용 가능 | 초대·확인·재설정 메일 |
| 고객 메일 서비스가 계정 메일을 수신 | 온보딩 |
| 공식 Mattermost 모바일 앱이 서버 버전과 호환 | 모바일 사용 |
| 지정 이미지 태그·Digest가 대상 아키텍처에서 pull 가능 | 재현 가능한 배포 |
| 프로젝트 참여자가 데이터 제한과 긴급 연락 규칙을 준수 | 잔여 위험 통제 |

의존성이 충족되지 않으면 그 의존성에 연결된 출시 단계만 중지하고, 무관한 내부 검증은 계속할 수 있다.

---

# 19. 인수조건과 Go/No-Go

## 19.1 판정 원칙

- 설정 파일의 존재가 아니라 실제 사용자 동작으로 판정한다.
- 정확한 Mattermost Team Edition 11.7.7 이미지와 기록된 Digest를 기준으로 시험한다.
- 고객 파일럿 필수 항목은 시험 결과와 근거를 남긴다.
- 기능 제한을 수용하는 경우 제한, 영향, 보완 통제와 승인자를 기록한다.
- 명시적 No-Go 조건이 하나라도 남아 있으면 고객 파일럿을 시작하지 않는다.

## 19.2 인프라 인수조건

| ID | 인수조건 |
| --- | --- |
| AC-INF-001 | OCI VM 한 대에서 NGINX, Mattermost와 PostgreSQL이 실행된다. |
| AC-INF-002 | VM은 AMD 기반 x86_64, 2 OCPU와 16GB RAM 기준으로 생성된다. |
| AC-INF-003 | 지정 도메인으로 유효한 HTTPS 접속이 가능하다. |
| AC-INF-004 | HTTP가 HTTPS로 전환된다. |
| AC-INF-005 | Mattermost WebSocket 연결이 정상 동작한다. |
| AC-INF-006 | 8065, 5432와 8443 포트가 외부에 노출되지 않는다. |
| AC-INF-007 | SSH는 관리자 IP와 공개키 인증으로만 접근할 수 있다. |
| AC-INF-008 | VM 재부팅 후 NGINX와 컨테이너가 자동 시작된다. |
| AC-INF-009 | Mattermost와 PostgreSQL health 상태가 정상이다. |
| AC-INF-010 | 이미지 태그와 실제 Digest가 기록된다. |

## 19.3 사용자·인증 인수조건

| ID | 인수조건 |
| --- | --- |
| AC-AUTH-001 | 유효한 이메일 초대 토큰으로 외부 사용자가 가입할 수 있다. |
| AC-AUTH-002 | 초대 토큰과 Team InviteId 없는 직접 가입은 실패한다. |
| AC-AUTH-003 | 이메일 확인 전 로그인은 실패하고 확인 후 로그인은 성공한다. |
| AC-AUTH-004 | 이메일과 사용자명 로그인이 모두 동작한다. |
| AC-AUTH-005 | 12자 미만 비밀번호가 거부된다. |
| AC-AUTH-006 | 로그인 실패 제한이 적용된다. |
| AC-AUTH-007 | 비밀번호 재설정이 동작하고 기존 웹·데스크톱·모바일 세션이 종료된다. |
| AC-AUTH-008 | 계정 비활성화 후 로그인은 실패하고 재활성화 후 성공한다. |
| AC-AUTH-009 | 사용 완료 또는 관리자가 무효화한 이메일 초대 토큰은 재사용할 수 없다. |
| AC-AUTH-010 | 유효한 Team 초대 URL 가입은 성공하며 코드 재생성 후 이전 URL은 실패한다. |
| AC-AUTH-011 | 모든 System Admin이 MFA 등록·정상 OTP·오류 OTP·복구 시험을 완료한다. |

## 19.4 권한 인수조건

| ID | 인수조건 |
| --- | --- |
| AC-PERM-001 | 고객은 일반 Member이며 System Admin 또는 Team Admin이 아니다. |
| AC-PERM-002 | 고객은 System Console에 접근할 수 없다. |
| AC-PERM-003 | 고객 Member는 사용자를 초대할 수 없다. |
| AC-PERM-004 | 고객 Member는 Team을 생성할 수 없다. |
| AC-PERM-005 | 고객 Member는 공개 채널을 생성할 수 없다. |
| AC-PERM-006 | 고객 Member는 비공개 채널을 생성할 수 없다. |
| AC-PERM-007 | 고객 Member는 Webhook 또는 불필요한 통합을 생성할 수 없다. |
| AC-PERM-008 | 실제 비공개 채널 멤버 변경, 사용자 검색과 DM 노출 범위를 기록한다. |
| AC-PERM-009 | 서로 신뢰하지 않는 고객 조직이 같은 인스턴스에 포함되지 않는다. |

## 19.5 협업 기능 인수조건

| ID | 인수조건 |
| --- | --- |
| AC-COL-001 | 공개·비공개 채널을 관리자가 생성할 수 있다. |
| AC-COL-002 | 채널 메시지, 스레드와 멘션이 정상 동작한다. |
| AC-COL-003 | 메시지와 스레드 링크를 복사하고 원문으로 이동할 수 있다. |
| AC-COL-004 | 1:1 DM과 최대 8명의 그룹 DM이 동작한다. |
| AC-COL-005 | 25MiB 이하 파일 업로드·다운로드가 동작하고 초과 파일은 거부된다. |
| AC-COL-006 | 공개 파일 링크를 만들 수 없다. |
| AC-COL-007 | 채널을 보관하고 복원할 수 있으며 기존 기록이 유지된다. |
| AC-COL-008 | 채널·Team Export 기능이 제공되지 않는다. |

## 19.6 검색 인수조건

| ID | 인수조건 |
| --- | --- |
| AC-SEARCH-001 | 한글 메시지 입력과 표시가 정상 동작한다. |
| AC-SEARCH-002 | `오류` 검색이 `로그인 오류`, `고객로그인오류`, `로그인오류를 확인했습니다`를 반환한다. |
| AC-SEARCH-003 | 한글·영문·숫자 혼합 검색이 동작한다. |
| AC-SEARCH-004 | 채널과 작성자 필터가 동작한다. |
| AC-SEARCH-005 | 스레드 답글과 수정된 메시지 검색이 동작한다. |
| AC-SEARCH-006 | 검색 결과에서 원문과 스레드로 이동할 수 있다. |
| AC-SEARCH-007 | 파일명 검색의 실제 지원 범위가 시험되고 기록된다. |
| AC-SEARCH-008 | 대표 누적 게시물 규모에서 검색 응답시간이 기록되고 업무상 수용 가능하다고 판정된다. |

## 19.7 데이터 영속성 인수조건

| ID | 인수조건 |
| --- | --- |
| AC-DATA-001 | PostgreSQL 18 호스트 경로가 `/var/lib/postgresql`에 bind mount된다. |
| AC-DATA-002 | Mattermost의 6개 중요 경로가 모두 명시적 bind mount다. |
| AC-DATA-003 | Mattermost 영구 경로가 고정 이미지의 실행 UID/GID와 일치하며 쓰기 가능하다. |
| AC-DATA-004 | 중요 경로에 anonymous volume이 없다. |
| AC-DATA-005 | Mattermost와 PostgreSQL 컨테이너 재시작 후 데이터가 유지된다. |
| AC-DATA-006 | `docker compose down` 후 재생성해도 계정·메시지·파일이 유지된다. |
| AC-DATA-007 | 각 컨테이너 재생성 후 계정·메시지·파일이 유지된다. |
| AC-DATA-008 | VM 재부팅 후 서비스 자동 시작과 데이터 유지를 확인한다. |
| AC-DATA-009 | 사용자 비활성화와 채널 보관 후 기존 기록이 유지된다. |
| AC-DATA-010 | 영구 경로 삭제와 완전 폐기 시 복구되지 않는다는 제약이 문서화된다. |

## 19.8 백업·복구 인수조건

| ID | 인수조건 |
| --- | --- |
| AC-BK-001 | 전용 OCI 버킷은 Public Access가 차단되고 `ap-singapore-1`에 있다. |
| AC-BK-002 | 정확한 프로젝트 VM의 Instance Principal만 대상 버킷 object create·inspect·read를 수행한다. |
| AC-BK-003 | 교차 버킷 접근, object delete와 bucket delete가 거부된다. |
| AC-BK-004 | backup set이 정확한 5개 객체로 업로드되고 크기와 SHA-256 원격 검증을 통과한다. |
| AC-BK-005 | Mattermost와 notifier 중단 단계가 절대 300초 deadline 안에 완료되고, timeout·초과 시 업로드가 차단되며 제한된 실패 복구가 시도된다. |
| AC-BK-006 | 폐기 가능한 신규 VM에서 PostgreSQL, 공개·비공개 채널, 스레드와 첨부파일이 복구된다. |
| AC-BK-007 | 복구 전후 소스 데이터 hash가 같고 운영 소스는 변경되지 않는다. |
| AC-BK-008 | 복구 notifier queue는 quarantine에 있고 새 live queue와 delivery는 비활성 상태다. |
| AC-BK-009 | 최초 수동 백업과 복구 증거 승인 전에는 timer가 disabled 상태이며, 활성화 직전 승인 ID의 정확한 5개 원격 객체가 다시 검증된다. |
| AC-BK-010 | 승인 후 24시간 이내 일일 실행과 실패 이메일의 개인정보 비포함을 확인한다. |
| AC-BK-011 | daily 7일·weekly 28일 lifecycle과 실제 객체 보존 결과를 확인한다. |

## 19.9 모바일·푸시 인수조건

| ID | 인수조건 |
| --- | --- |
| AC-MOB-001 | 공식 iOS 앱으로 로그인할 수 있다. |
| AC-MOB-002 | 공식 Android 앱으로 로그인할 수 있다. |
| AC-MOB-003 | 모바일에서 채널, 스레드, 멘션과 DM을 사용할 수 있다. |
| AC-MOB-004 | 모바일에서 파일을 업로드하고 다운로드할 수 있다. |
| AC-MOB-005 | 모바일에서 메시지를 검색할 수 있다. |
| AC-MOB-006 | 앱이 종료된 동안 새 메시지 푸시가 수신되지 않는다. |
| AC-MOB-007 | 앱을 다시 열면 최신 메시지가 동기화된다. |
| AC-MOB-008 | 계정 비활성화 후 모바일 재로그인이 실패한다. |

## 19.10 이메일 인수조건

| ID | 인수조건 |
| --- | --- |
| AC-MAIL-001 | OCI Email Delivery SMTP 587과 STARTTLS 연결이 성공한다. |
| AC-MAIL-002 | Approved Sender에서 초대 메일을 보낼 수 있다. |
| AC-MAIL-003 | 이메일 확인 메일의 링크가 동작한다. |
| AC-MAIL-004 | 비밀번호 재설정 메일의 링크가 동작한다. |
| AC-MAIL-005 | Gmail·네이버·다음에서 세 종류의 계정 메일을 수신할 수 있다. |
| AC-MAIL-006 | 시험 메일의 SPF와 DKIM 결과가 `pass`다. |
| AC-MAIL-007 | Mattermost 기본 일반 메시지 이메일 알림은 비활성화다. |
| AC-MAIL-008 | 수신 위치와 OCI suppression 상태를 시험 결과에 기록한다. |

## 19.11 즉시 채널 이메일 알림 인수조건

| ID | 인수조건 |
| --- | --- |
| AC-NOT-001 | 공개·비공개 채널의 새 글과 스레드 답글이 게시 시점의 적격 채널 멤버에게 발송된다. |
| AC-NOT-002 | 작성자·비활성 사용자·봇·이메일 미확인 사용자는 수신자에서 제외된다. |
| AC-NOT-003 | DM, 그룹 DM, 시스템 글, 수정·삭제와 Webhook·봇 작성 글은 발송되지 않는다. |
| AC-NOT-004 | 이메일·Mailer 요청·로그·상태 출력에 메시지 본문, 채널명, Team명과 작성자명이 없다. |
| AC-NOT-005 | 각 이메일은 수신자별 단일 SMTP envelope와 일반 안내문을 사용한다. |
| AC-NOT-006 | Mailer·SMTP 중단 중에도 Mattermost 글 작성이 성공하고 복구 후 영구 큐가 처리된다. |
| AC-NOT-007 | Mailer 컨테이너 재생성과 VM 재부팅 뒤에도 미처리 큐가 유지된다. |
| AC-NOT-008 | SMTP acceptance 전과 notifier disabled 상태에서는 신규 수집·발송이 일어나지 않는다. |
| AC-NOT-009 | allowlist 공개·비공개 루트 글·스레드 수동 시험 뒤에만 all-channels 활성화를 승인한다. |
| AC-NOT-010 | 플러그인 번들과 Mailer 이미지에 자체 라이선스와 전체 의존성 고지가 포함된다. |

## 19.12 라이선스·재배포 인수조건

| ID | 인수조건 |
| --- | --- |
| AC-LIC-001 | Mattermost Team Edition을 사용한다. |
| AC-LIC-002 | 유료 라이선스 키와 Enterprise Trial이 없다. |
| AC-LIC-003 | 유료 Guest, SSO, Calls와 유료 고급 기능을 사용하지 않는다. |
| AC-LIC-004 | 무료 TPNS가 구성되지 않고 모바일 푸시가 비활성화된다. |
| AC-LIC-005 | notifier가 공개 플러그인 API만 사용하고 Enterprise 코드·유료 기능 활성화·라이선스 우회를 포함하지 않는다. |
| AC-REP-001 | 비밀정보 없이 배포 구성을 Git에서 관리할 수 있다. |
| AC-REP-002 | 새 OCI VM에 배포 패키지로 ThreadHub를 재구성할 수 있다. |
| AC-REP-003 | 새 프로젝트마다 새 `.env`, 자격 증명, 도메인과 관리자 계정을 사용한다. |
| AC-REP-004 | 새 프로젝트는 이전 프로젝트 데이터 없이 시작한다. |
| AC-REP-005 | 기록 유지와 완전 폐기 절차가 문서화되어 있다. |

## 19.13 제한된 고객 파일럿 Go 조건

다음 조건을 모두 충족해야 한다.

1. 정보 공유 경계별 독립 인스턴스를 사용한다.
2. 이메일 초대 가입은 성공하고 초대 없는 직접 가입은 실패한다.
3. Team 초대 URL의 사용·코드 재생성·이전 URL 무효화 시험이 기대 결과와 일치한다.
4. System Scheme 적용 후 고객 Member의 초대·Team 생성·공개·비공개 채널 생성이 차단된다.
5. 실제 이미지에서 발견한 추가 권한 제한을 기록하고 잔여 위험을 승인한다.
6. System Admin 1~2명이 MFA 등록·로그인·복구 시험을 통과한다.
7. 한글 부분 문자열 검색과 대표 데이터 규모의 검색 시험이 수용 기준을 통과한다.
8. PostgreSQL과 Mattermost 컨테이너 재생성 후 데이터가 유지된다.
9. PostgreSQL과 Mattermost 중요 경로가 모두 예상한 bind mount다.
10. Mattermost 영구 경로의 소유권과 쓰기 시험을 통과한다.
11. 모바일 푸시가 비활성화되어 있고 앱 재실행 시 최신 메시지가 동기화된다.
12. Gmail·네이버·다음에서 초대·확인·재설정 메일이 동작하고 SPF·DKIM이 통과한다.
13. 8065, 5432와 8443이 외부에 노출되지 않는다.
14. HTTPS와 WebSocket이 정상 동작한다.
15. VM 재부팅 후 서비스가 자동 시작된다.
16. 디스크·컨테이너·인증서·SMTP 점검 절차가 준비된다.
17. 최초 원격 백업과 폐기 가능한 신규 VM 복구시험을 통과하고 증거 승인 후 타이머를 활성화한다.
18. 마지막 원격 검증 성공 세트가 backup ID 생성시각 기준 24시간 이내이고 daily 세트가 정확히 5개다.
19. 고객에게 모바일 푸시, RPO 24시간·수동 RTO 4시간 목표와 데이터 취급 제한을 안내한다.

## 19.14 고객 파일럿 No-Go 조건

다음 중 하나라도 해당하면 고객 파일럿을 시작하거나 계속하지 않는다.

- 초대 없이 누구나 계정을 만들 수 있다.
- 재생성한 Team 초대 코드의 이전 URL로 가입할 수 있다.
- 고객이 System Admin 또는 Team Admin 권한을 획득할 수 있다.
- 고객 Member가 사용자 초대, Team 생성 또는 공개·비공개 채널 생성을 할 수 있다.
- 서로 격리해야 하는 고객 조직이 같은 인스턴스에 포함되어 있다.
- 핵심 한글 검색이 합의된 완전어·부분 문자열 기준으로 동작하지 않는다.
- 대표 데이터 규모에서 검색이 업무를 수행하기 어려울 정도로 반복 지연된다.
- 컨테이너 재생성 후 DB, 설정 또는 첨부파일이 사라진다.
- Mattermost 중요 경로가 anonymous volume에 연결되거나 권한 오류로 쓰기 실패한다.
- System Admin MFA가 등록되지 않았거나 복구 절차가 확인되지 않았다.
- 8065, 5432 또는 8443이 인터넷에 노출되어 있다.
- 유효한 HTTPS 없이 서비스가 공개되어 있다.
- 모바일 푸시가 의도하지 않게 활성화되어 있다.
- 초대·확인·재설정 메일이 동작하지 않거나 SPF·DKIM 검증에 실패한다.
- 원격 backup set이 정확한 5개 객체가 아니거나 크기·SHA-256 검증에 실패한다.
- 폐기 가능한 신규 VM 복구시험이 실패하거나 과거 notifier 이메일이 재발송된다.
- 마지막 원격 검증 성공 세트가 backup ID 생성시각 기준 24시간을 초과한다.

---

# 20. 성공 지표

## 20.1 기술 품질 지표

| 지표 | 목표 | 측정 시점 |
| --- | ---: | --- |
| 파일럿 로그인 핵심 시나리오 성공률 | 100% | 내부 파일럿 |
| 채널·스레드·멘션·DM 기능 시험 | 100% 통과 | 내부 파일럿 |
| 합의된 한글 검색 필수 시나리오 | 100% 통과 | 내부 파일럿 |
| 컨테이너 재생성 후 데이터 유지 시험 | 100% 통과 | 내부 파일럿 |
| VM 재부팅 후 자동 실행 시험 | 100% 통과 | 내부 파일럿 |
| Mattermost 중요 경로 bind mount 검사 | 100% 통과 | 배포 직후·변경 후 |
| System Admin MFA 등록률 | 100% | 고객 파일럿 전 |
| 고객 Member 금지 권한 시험 | 100% 차단 | 고객 파일럿 전 |
| 비인가 직접 가입 성공 건수 | 0건 | 내부·고객 파일럿 |
| 외부 내부포트 노출 건수 | 0건 | 배포 직후·변경 후 |
| 의도하지 않은 모바일 푸시 수신 | 0건 | 내부·고객 파일럿 |
| 새 VM 재배포 시험 | 100% 통과 | MVP 완료 전 |

## 20.2 사용과 운영 지표

| 지표 | 목표 | 해석 |
| --- | ---: | --- |
| 계정 관련 시험 메일 수신 성공률 | 95% 이상 | 소규모 시험의 운영 지표이며 통계적 SLA가 아님 |
| 초대 사용자의 계정 생성률 | 90% 이상 | 사용자 미응답과 만료를 구분해 기록 |
| 주요 고객 요청의 ThreadHub 기록 비율 | 90% 이상 | 내부 담당자가 파일럿 종료 시 표본 검토 |
| 주요 결정사항의 `03-결정사항` 기록 비율 | 90% 이상 | DM·구두 결정의 채널 환류 여부 확인 |
| 주간 기본 운영점검 수행률 | 100% | 점검표 기록 기준 |
| 프로젝트 종료 방식 결정·기록률 | 100% | 유지 또는 완전 폐기 결과 기록 |

## 20.3 성공 판정 해석

- 기술 보안·영속성 출시 게이트는 표본 비율이 아니라 해당 필수 시험의 통과 여부로 판단한다.
- 메일 수신과 사용자 참여율은 외부 요인의 영향을 받으므로 실패 원인을 서비스, 메일 사업자와 사용자 미응답으로 분리한다.
- 메시지·결정사항 기록 비율은 제품 사용 정착 지표이며 시스템 결함과 구분한다.
- 파일럿 기간이 짧거나 표본이 작으면 수치를 과도하게 일반화하지 않고 관찰 결과로 기록한다.

---

# 21. 위험과 대응

| ID | 위험 | 영향 | 대응 또는 보완 통제 | 고객 파일럿 차단 |
| --- | --- | --- | --- | --- |
| R-01 | CJK 검색 기능 미동작 | 핵심 이력 검색 실패 | 정확한 11.7.7 이미지와 합의 말뭉치 시험 | 예 |
| R-02 | 선행 와일드카드 CJK 검색 성능 저하 | 게시물 누적 시 검색 지연 | 대표 데이터 규모 측정, 사용량 제한, 필요 시 후속 대안 검토 | 조건부 |
| R-03 | 초대 없는 가입 설정 오류 | 비인가 사용자 접근 | 가입 경로별 시험, 설정 변경 후 회귀시험 | 예 |
| R-04 | Team 초대 URL 유출·미회수 | 링크 소지자의 가입 | URL 비배포, 코드 재생성, 이전 URL 무효화 시험 | 예 |
| R-05 | System Scheme 설정 누락 | 고객의 임의 초대·공간 생성 | 정확한 이미지에서 적용, 고객 Member 시험 | 예 |
| R-06 | 고객 조직 오배치 | 고객 간 정보 노출 | 정보 공유 경계 확인과 독립 인스턴스 | 예 |
| R-07 | PostgreSQL 18 mount 경로 오류 | 신규 초기화 또는 데이터 손실 | `/var/lib/postgresql` 확인과 재생성 시험 | 예 |
| R-08 | Mattermost bind mount 누락 | 상태 손실·anonymous volume 생성 | 공식 6개 경로 명시, `docker inspect` 검사 | 예 |
| R-09 | Mattermost 호스트 경로 권한 오류 | 컨테이너 시작·파일 쓰기 실패 | 고정 이미지 UID/GID와 `2000:2000` 소유권·쓰기 시험 | 예 |
| R-10 | 백업 실패·복구 불가 | RPO 초과 또는 전체 데이터 손실 | 원격 SHA-256 검증, 일일 상태 점검, 신규 VM 복구시험, 타이머 인수 gate | 예 |
| R-11 | System Admin 계정 탈취 | 전체 인스턴스 장악 | 계정 1~2개, 강한 비밀번호, 사용자별 MFA와 복구시험 | 예 |
| R-12 | 모바일 푸시 부재 | 메시지 확인 지연 | 사전 안내, 앱 재실행 동기화 시험, 별도 긴급 연락 | 아니오 |
| R-13 | SMTP 발송·전달 실패 | 가입·확인·재설정 불가 | SPF·DKIM, 3개 메일 서비스 시험, suppression 확인 | 예 |
| R-14 | 디스크 고갈 | DB 손상 또는 서비스 중단 | 주간 사용량·로그 회전 점검, 수직 확장 | 조건부 |
| R-15 | 인증서 만료 | 전체 사용자 접속 실패 | Certbot 타이머와 갱신 dry-run 점검 | 조건부 |
| R-16 | 비밀정보 Git 유출 | DB·SMTP·서버 접근 위험 | `.gitignore`, `.env.example`, 파일 권한과 저장소 검사 | 예 |
| R-17 | 공개 내부포트 | DB·애플리케이션 직접 공격 | NSG, loopback, DB host port 미설정과 외부 시험 | 예 |
| R-18 | VM 사양 부족 | 응답 지연·OOM | 2 OCPU·16GB 기준, 파일럿 측정 후 수직 확장 | 아니오 |
| R-19 | 버전 또는 이미지 공급 변경 | 재배포 실패·동작 차이 | 태그·Digest 기록, pull·Compose 사전검증, 변경 통제 | 조건부 |
| R-20 | 고위험 데이터 업로드 | 규제·보안 영향 확대 | 금지 데이터 정책, 공지, 일반 프로젝트로 범위 제한 | 예 |

“차단: 아니오”는 위험이 없다는 뜻이 아니다. 해당 위험이 본 MVP의 명시적 제약으로 수용되었고, 고객 고지와 운영 통제를 전제로 파일럿을 진행할 수 있다는 뜻이다.

---

# 22. 산출물 요구사항

## 22.1 배포 저장소

배포 구성은 별도 Git 저장소 또는 본 프로젝트의 전용 디렉터리에서 다음 구조로 관리한다.

```text
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
│   ├── health-check.sh
│   └── destroy.sh
└── docs/
    ├── setup.md
    ├── admin-guide.md
    ├── operations-checklist.md
    ├── backup-restore.md
    ├── test-plan.md
    └── project-close.md
```

실제 구현 시 파일명은 조정할 수 있지만 각 역할의 산출물은 유지해야 한다.

## 22.2 저장소 포함 항목

- Docker Compose 구성
- 명시적 이미지 태그와 Digest 기록
- 환경변수 예제와 설명
- NGINX와 WebSocket 설정
- Docker 설치·배포·상태 점검 스크립트
- Team·채널 기본 구조
- notifier plugin·Mailer 소스, 빌드·설치·운영 구성과 라이선스 고지
- 사용자 초대·권한·MFA 절차
- 운영 점검 체크리스트
- 상세 시험 시나리오와 결과 양식
- 프로젝트 기록 유지·완전 폐기 절차

## 22.3 저장소 제외 항목

- 실제 `.env`
- PostgreSQL 비밀번호
- SMTP 사용자명과 비밀번호
- Mattermost 관리자 비밀번호와 MFA 복구정보
- SSH·TLS 개인키
- OCI 자격 증명
- 고객 메시지와 첨부파일
- PostgreSQL 데이터
- 프로젝트별 실제 도메인 비밀정보

## 22.4 필수 문서

| 문서 | 최소 포함 내용 |
| --- | --- |
| `setup.md` | 사전조건, 인프라, 배포, DNS, HTTPS, 이메일과 초기 설정 |
| `admin-guide.md` | 사용자 초대·비활성화, MFA, System Scheme, Team·채널 운영 |
| `notifier-architecture.md` | plugin·Mailer 역할, 이벤트 흐름, 데이터·장애·라이선스 경계 |
| `operations-checklist.md` | 디스크, 컨테이너, health, 인증서, SMTP와 로그 점검 |
| `backup-restore.md` | OCI 최소권한, 백업·원격 검증, 복구, 타이머 인수와 보존·폐기 |
| `test-plan.md` | 시험 ID, 절차, 기대 결과, 실제 결과, 증거와 판정 |
| `project-close.md` | 기록 유지와 완전 폐기, 대상 식별, 결과 기록 |
| 배포 기록 | 버전, 이미지 Digest, 도메인, 배포일, 변경 이력 |

---

# 23. Definition of Done

다음 조건이 모두 충족되면 ThreadHub MVP 구축을 완료한 것으로 판단한다.

1. 본 PRD와 구축·검증 계획서가 승인된 기준선으로 저장되어 있다.
2. 정보 공유 경계에 맞는 독립 OCI VM이 생성되어 있다.
3. VM은 AMD 기반 x86_64, 2 OCPU, 16GB RAM과 50GB 이상 Boot Volume 기준을 충족한다.
4. Ubuntu 24.04 LTS에 NGINX, Certbot, Docker Engine과 Compose Plugin이 설치되어 있다.
5. Mattermost Team Edition 11.7.7과 PostgreSQL 18.4가 같은 VM에서 실행된다.
6. 컨테이너 이미지 태그와 실제 Digest가 기록되어 있다.
7. 지정 도메인으로 유효한 HTTPS 접속이 가능하고 HTTP가 HTTPS로 전환된다.
8. NGINX의 Mattermost HTTP·WebSocket 프록시가 정상 동작한다.
9. 외부에는 TCP 80, 443과 승인된 관리자 IP의 TCP 22만 노출된다.
10. Mattermost 8065는 loopback에만 연결되고 PostgreSQL 5432에는 host port가 없다.
11. Calls 8443과 Docker API가 외부에 노출되지 않는다.
12. PostgreSQL 호스트 경로가 컨테이너 `/var/lib/postgresql`에 bind mount되어 있다.
13. Mattermost의 config, data, logs, plugins, client/plugins와 bleve-indexes가 모두 bind mount되어 있다.
14. Mattermost 영구 경로의 소유권이 고정 이미지 실행 UID/GID와 일치하고 쓰기 시험을 통과한다.
15. 중요 경로에 의도하지 않은 anonymous volume이 없다.
16. OCI Email Delivery, Approved Sender, SMTP 587·STARTTLS, SPF와 DKIM이 구성되어 있다.
17. Gmail·네이버·다음에서 초대·확인·비밀번호 재설정 메일과 링크가 동작한다.
18. 유효한 이메일 초대 사용자는 가입할 수 있고 초대 없는 직접 가입은 실패한다.
19. 사용 완료·무효화된 이메일 초대 토큰을 재사용할 수 없다.
20. 유효한 Team 초대 URL과 코드 재생성 후 이전 URL 무효화 동작이 검증되어 있다.
21. 비밀번호 최소 12자, 로그인 실패 제한과 비밀번호 변경 후 기존 세션 종료가 적용되어 있다.
22. System Admin 계정은 1~2개이며 모두 MFA 등록·로그인·복구 시험을 통과한다.
23. 고객은 일반 Member이며 System Admin·Team Admin 권한이 없다.
24. System Scheme으로 고객 Member의 사용자 초대, Team 생성, 공개·비공개 채널 생성과 통합 생성이 차단된다.
25. Internal과 Project Team 및 합의된 기본 채널이 생성되어 있다.
26. 채널, 스레드, 멘션, DM, 그룹 DM과 파일 공유가 정상 동작한다.
27. 25MiB 파일 제한과 공개 파일 링크 비활성화가 검증되어 있다.
28. 한글 입력과 합의된 부분 문자열·필터·스레드 검색 시험이 통과한다.
29. 대표 누적 게시물 규모의 CJK 검색 성능이 기록되고 수용 가능하다고 판정된다.
30. 웹, 데스크톱, 공식 iOS와 Android 앱에서 접속할 수 있다.
31. 모바일 푸시는 비활성화되어 있고 앱을 다시 열면 최신 메시지가 동기화된다.
32. 사용자 비활성화 후 로그인이 차단되고 기존 메시지가 유지된다.
33. 채널 보관·복원과 기존 메시지·파일 유지가 검증되어 있다.
34. 컨테이너 재시작, `docker compose down` 후 재생성과 각 컨테이너 재생성 뒤 데이터가 유지된다.
35. VM 재부팅 후 서비스가 자동 시작되고 데이터가 유지된다.
36. Mattermost Team Edition 무료 기능만 사용하고 유료 라이선스·Enterprise Trial이 없다.
37. Calls, SSO, 유료 Guest, 무료 TPNS, 진단 텔레메트리와 채널·Team Export가 사용되지 않는다.
38. 디스크, 컨테이너, health, 인증서, SMTP와 로그의 최소 운영점검 절차가 준비되어 있다.
39. 고객에게 모바일 푸시 부재, 긴급 연락, RPO 24시간·수동 RTO 4시간 목표와 데이터 제한이 안내되어 있다.
40. 사용자 초대, 계정 비활성화, System Scheme, MFA와 채널 보관 절차가 문서화되어 있다.
41. 프로젝트 기록 유지와 완전 폐기 절차가 문서화되어 있다.
42. 배포 패키지로 데이터가 없는 새 VM에 ThreadHub를 재구성할 수 있다.
43. 실제 `.env`, 비밀번호, 키와 고객 데이터가 Git 저장소에 포함되어 있지 않다.
44. notifier plugin은 대상 채널 이벤트와 멤버십을 판단하고 Mailer는 HMAC 입력, 영구 큐, 재시도와 SMTP 발송을 담당한다.
45. 공개·비공개 채널 루트 글·스레드, 제외 이벤트, 개인정보 비포함과 SMTP 장애 격리 시험이 통과한다.
46. notifier 산출물에 자체 라이선스와 전체 제3자 의존성 고지가 포함되고 라이선스 자동검증을 통과한다.
47. 백업 unit은 비활성으로 등록되고 최초 수동 backup set의 정확한 5개 원격 객체와 SHA-256이 검증되어 있다.
48. 폐기 가능한 신규 VM에서 PostgreSQL, 공개·비공개 채널, 스레드, 첨부파일과 notifier queue quarantine 복구시험을 통과한다.
49. 승인된 성공 백업 ID의 정확한 5개 원격 객체를 재검증한 뒤에만 타이머를 활성화하고, 해당 ID 생성시각이 24시간 이내다.
50. daily 7일·weekly 28일 lifecycle, 실패 이메일과 프로젝트 종료 시 보존·삭제 절차가 검증되어 있다.
51. 고객 파일럿 No-Go 조건이 남아 있지 않고 최종 시험 결과가 기록되어 있다.
52. 중앙 로깅, 통합 모니터링, 고가용성과 모바일 푸시는 후속 검토 대상으로 유지되어 있다.

---

# 24. 요구사항 추적성과 공식 근거

## 24.1 목표·요구사항·검증 추적표

| 제품 목표 | 주요 요구사항 | 인수조건 | 구축·검증 계획서 |
| --- | --- | --- | --- |
| G-01 채널 기반 협업 | FR-CH, FR-FILE | AC-COL | 12.5~12.6 |
| G-02 스레드 기반 논의 | FR-CH-003~009 | AC-COL-002~003 | 12.3, 12.5 |
| G-03 초대 기반 등록 | FR-AUTH, FR-INV | AC-AUTH | 12.1 |
| G-04 프로젝트 이력 유지 | FR-HIST, NFR-DATA | AC-SEARCH, AC-DATA | 12.3~12.4 |
| G-05 최대 50명 | NFR-PERF-001~002 | 운영대장·파일럿 기록 | 13.3, 14장 |
| G-06 사용자 교체 | FR-AUTH-009, FR-ADM-002~003 | AC-AUTH-008, AC-DATA-009 | 12.1, 12.4 |
| G-07 모바일 앱 | FR-MOB, FR-PUSH | AC-MOB | 12.5 |
| G-08 단일 VM | NFR-AVL, 13~15장 | AC-INF, AC-DATA | 11장 Phase 2~4, 12.7 |
| G-09 반복 배포 | NFR-MNT, FR-ADM | AC-REP | 11장 Phase 1, 16장 |
| G-10 무료 기능 | FR-PERM-012, FR-PUSH-003~005 | AC-LIC | 9.7, 15장 |
| G-11 명시적 보안 경계 | 8장, NFR-SEC-019 | AC-PERM-009 | 5장, 14.2 |
| G-12 검증 가능한 백업·복구 | NFR-DATA-007~016, 17.5 | AC-BK | 백업·복구 구현 계획과 `backup-restore.md` |

상세 시험 절차와 시험 ID는 [ThreadHub MVP 구축 및 검증 계획서](./threadhub-mvp-build-validation-plan.md)를 따른다.

## 24.2 근거 우선순위

기능 또는 에디션 동작이 불명확할 때 다음 순서로 판단한다.

1. 정확한 v11.7.7 태그의 Mattermost 공식 소스
2. Mattermost 공식 제품·관리·배포 문서
3. Mattermost 공식 Docker 저장소와 고정 이미지의 runtime metadata
4. PostgreSQL·Docker·OCI·Ubuntu의 공식 문서
5. 정확한 이미지와 실제 환경의 동작 시험

공식 문서의 에디션 배너와 정확한 버전 소스가 상충하면 단정하지 않고 실제 이미지 시험 결과를 출시 판정에 사용한다.

## 24.3 주요 공식 근거

### Mattermost 제품과 운영

- [Mattermost Editions and Offerings](https://docs.mattermost.com/product-overview/editions-and-offerings.html)
- [Mattermost v11.7.7 공식 소스 태그](https://github.com/mattermost/mattermost/tree/v11.7.7)
- [인증 설정](https://docs.mattermost.com/administration-guide/configure/authentication-configuration-settings.html)
- [사이트 설정](https://docs.mattermost.com/administration-guide/configure/site-configuration-settings.html)
- [사용자 관리 설정](https://docs.mattermost.com/administration-guide/configure/user-management-configuration-settings.html)
- [채널 보관과 복원](https://docs.mattermost.com/end-user-guide/collaborate/archive-unarchive-channels.html)
- [제품 한도](https://docs.mattermost.com/administration-guide/manage/product-limits.html)

### v11.7.7 구현 근거

- [사용자 생성과 초대 분기](https://github.com/mattermost/mattermost/blob/v11.7.7/server/channels/api4/user.go)
- [사용자별 MFA 등록 구현](https://github.com/mattermost/mattermost/blob/v11.7.7/server/channels/app/user.go#L870-L925)
- [전역 MFA 강제 검사](https://github.com/mattermost/mattermost/blob/v11.7.7/server/channels/app/authentication.go#L306-L370)
- [CJK Feature Flag](https://github.com/mattermost/mattermost/blob/v11.7.7/server/public/model/feature_flags.go#L90-L165)
- [PostgreSQL CJK 검색 구현](https://github.com/mattermost/mattermost/blob/v11.7.7/server/channels/store/sqlstore/post_store.go#L2097-L2218)
- [System Scheme 권한 목록 구현](https://github.com/mattermost/mattermost/blob/v11.7.7/webapp/channels/src/components/admin_console/permission_schemes_settings/permissions_tree/permissions_tree.tsx#L55-L115)
- [System Scheme의 Team Edition 제공 공지](https://forum.mattermost.com/t/granular-permissions-coming-soon-to-team-edition/11929)
- [Mattermost Team·Enterprise 플러그인 지원](https://developers.mattermost.com/integrate/plugins/using-and-managing-plugins/)
- [Mattermost plans와 통합 기능](https://docs.mattermost.com/product-overview/plans.html)
- [Mattermost server/public Apache 2.0 라이선스](https://github.com/mattermost/mattermost/blob/server/public/v0.3.0/server/public/LICENSE.txt)

### 배포·데이터·푸시

- [Mattermost 공식 컨테이너 배포](https://docs.mattermost.com/deployment-guide/server/deploy-containers.html)
- [Mattermost 공식 Docker 저장소](https://github.com/mattermost/docker)
- [Mattermost 푸시 설정](https://docs.mattermost.com/administration-guide/configure/push-notification-server-configuration-settings.html)
- [PostgreSQL 공식 Docker 이미지](https://hub.docker.com/_/postgres/)
- [Docker 영구 데이터](https://docs.docker.com/get-started/docker-concepts/running-containers/persisting-container-data/)
- [Docker Compose `down`](https://docs.docker.com/reference/cli/docker/compose/down/)
- [Ubuntu 24.04 LTS 릴리스 정보](https://documentation.ubuntu.com/release-notes/24.04/)
- [OCI Email Delivery 개요](https://docs.oracle.com/en-us/iaas/Content/Email/Concepts/overview.htm)

## 24.4 v4.2 대비 주요 변경

| 영역 | v4.3 변경 내용 |
| --- | --- |
| 알림 제품 범위 | 공개·비공개 채널 새 글과 스레드 답글의 즉시 일반 안내 이메일 요구 추가 |
| 책임 분리 | Mattermost plugin의 이벤트·멤버십·KV outbox와 Mailer의 SQLite 큐·재시도·SMTP 책임 명시 |
| 개인정보 | 메시지 본문, 채널·Team·작성자명을 요청·이메일·로그·상태에서 제외 |
| 장애 격리 | Mailer·SMTP 장애 중 Mattermost 글 작성 성공과 영구 큐 복구 요구 추가 |
| 활성화 gate | SMTP acceptance, allowlist 수동 인수와 명시적 all-channels 승인 요구 추가 |
| 라이선스 | 공개 플러그인 API 사용, 유료 기능 비우회, 자체·제3자 고지의 산출물 포함 요구 추가 |
| 문서 | plugin·Mailer 분리 이유와 데이터·장애·라이선스 경계 문서 추가 |

## 24.5 변경 통제

다음 변경은 PRD 기준선의 개정이 필요하다.

- Mattermost 또는 PostgreSQL 메이저 버전 변경
- Team Edition에서 유료 에디션으로 변경
- 백업·복구 또는 SLA 제공 범위 변경
- 모바일 푸시 활성화
- 단일 VM에서 다중 VM 또는 관리형 DB로 변경
- 정보 공유 경계 또는 고객 격리 모델 변경
- 고위험·규제 데이터 허용
- 활성 사용자 상한 50명 변경

패치 버전, 운영 스크립트와 세부 경로의 변경은 제품 범위를 바꾸지 않는 한 배포 설계서와 변경 기록으로 관리할 수 있다. 단, 인수조건에 영향을 주는 변경은 관련 시험을 다시 수행해야 한다.

---

# 25. 최종 제품 정의

> ThreadHub는 정보 공유 경계별 OCI Compute VM 한 대에 셀프호스팅되는 Mattermost Team Edition 기반 고객 협업 서비스다. 최대 50명의 내부 담당자와 외부 고객을 이메일로 초대하고, 채널과 스레드에서 일반 프로젝트 대화, 질문, 답변, 파일과 결정 이력을 관리한다.

## 25.1 확정 아키텍처

```text
정보 공유 경계당 OCI Compute VM 1대
├── Ubuntu Server 24.04 LTS
├── AMD x86_64 · 2 OCPU · 16GB RAM
├── NGINX
├── Certbot + Let’s Encrypt
└── Docker Compose
    ├── Mattermost Team Edition 11.7.7
    │   └── ThreadHub notifier plugin
    ├── PostgreSQL 18.4
    └── ThreadHub Mailer
```

## 25.2 확정 운영 원칙

```text
기본은 프로젝트당 독립 인스턴스 1개
실제 분리 기준은 정보 공유 경계
인스턴스당 활성 사용자 최대 50명
고객은 이메일로 초대되는 일반 Member
System Scheme으로 초대·Team·채널 생성 권한 제한
System Admin은 1~2명이며 사용자별 MFA 필수
채널·스레드 중심 프로젝트 이력 관리
웹·데스크톱·공식 iOS·Android 앱 지원
모바일 푸시는 MVP 기본 비활성화
Mattermost 기본 일반 메시지 이메일 알림은 비활성화
공개·비공개 채널 새 글·스레드 답글은 ThreadHub notifier로 즉시 일반 안내 이메일 발송
plugin은 이벤트·멤버십·KV outbox, Mailer는 HMAC·영구 큐·재시도·SMTP를 담당
이메일과 로그에 메시지 본문·채널·Team·작성자명 미포함
Mattermost 무료 기능만 사용
Mattermost Calls, SSO, 유료 Guest와 Export 미사용
PostgreSQL은 Mattermost와 동일 VM
PostgreSQL과 Mattermost 중요 데이터는 명시적 bind mount
정상 컨테이너 재생성·VM 재부팅 중 데이터 유지
일일 백업은 프로젝트 전용 Private OCI Object Storage에 저장·원격 검증
backup ID 생성시각 기준 RPO 24시간·수동 RTO 4시간·백업 중단 deadline 5분
복구는 동일 기준의 신규 VM과 비어 있는 데이터 경로에서만 수행
HA·PITR·리전 간 복제·무손실 복구·SLA는 미제공
중앙 로깅·통합 모니터링·고가용성은 초기 미구성
VM과 Boot Volume 삭제 시 프로젝트 데이터 완전 폐기
배포 구성은 다음 프로젝트에 재사용하되 데이터와 비밀정보는 재사용하지 않음
```

이 문서를 ThreadHub MVP의 최종 제품 요구사항 기준선으로 사용한다.
