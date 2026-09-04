# ThreadHub 빠른 설치

이 절차는 새 Ubuntu 24.04 LTS AMD64 VM 한 대에 새 ThreadHub 인스턴스를
설치하는 fresh installation only 절차입니다. 기존 프로젝트 데이터를 이전하거나 OCI
리소스를 자동 생성하지 않습니다. 이미 운영 중인 Mattermost에 notifier만 추가하려면
이 문서나 설치 마법사를 사용하지 말고
[기존 Mattermost notifier 적용 가이드](./existing-mattermost-notifier.md)를 따릅니다.
플러그인과 Mailer를 함께 사용하는 이유와 데이터·장애·라이선스 경계는
[알림 아키텍처](./notifier-architecture.md)를 먼저 확인합니다.

## 1. 설치 순서와 준비해야 할 값

새 인스턴스의 순서는 다음과 같습니다. 기존 VM·`deploy/.env`·`/srv/threadhub`에
접속하거나 값을 덧붙이는 절차가 아닙니다.

1. fresh Ubuntu 24.04 AMD64 VM(2 OCPU, 16GB RAM, Boot Volume 50GB 이상) 기준을 확인합니다.
2. 저장소에서 `./deploy/scripts/validate.sh`를 실행합니다.
3. 프로젝트 DNS와 Email Delivery를 준비합니다.
4. 숨김 SMTP 입력과 generated HMAC으로 설정을 만듭니다.
5. build/install을 실행합니다.
6. 일회성 SMTP acceptance를 실행합니다.
7. activation cutoff 이후에만 notifier를 활성화합니다.
8. `./deploy/scripts/install-status.sh`의 `[READY]` 자동 항목을 확인합니다.
9. inbox/link/SPF/DKIM, permissions, CJK, mobile 수동 항목을 완료합니다.

설치 마법사를 실행하기 전에 다음 값을 준비합니다.

- VM으로 연결된 전체 도메인 이름
- Let’s Encrypt 연락 이메일
- OCI Email Delivery 리전
- OCI SMTP username과 password
- OCI Approved Sender 주소
- Reply-To 주소

SMTP 비밀번호는 채팅, 명령행 인수 또는 Git에 입력하지 않습니다. Oracle이
SMTP 자격 증명을 생성할 때 표시한 비밀번호를 설치 마법사의 숨김 입력창에
직접 붙여 넣습니다.

OCI 리소스가 아직 없다면 [OCI 인프라 준비](./oci-provisioning.md)와
[OCI Email Delivery 설정](./oci-email-delivery.md)을 먼저 완료합니다.

## 2. 저장소 복제와 검증

```bash
git clone https://github.com/nugaing119/ThreadHub.git
cd ThreadHub
./deploy/scripts/validate.sh
```

## 3. 대화형 설치와 notifier 활성화

```bash
./deploy/scripts/setup-wizard.sh
```

마법사는 다음을 자동 처리합니다.

- PostgreSQL 64자리 비밀번호 생성
- `deploy/.env` 생성과 mode `0600` 적용
- 고정 버전 Docker Engine과 Compose 설치
- Mattermost와 PostgreSQL 영구 경로 구성
- 컨테이너 시작과 health 검사
- DNS 준비 확인
- NGINX, Let’s Encrypt와 HTTPS 구성
- 최종 readiness 검사

마법사는 notifier HMAC을 생성하고 보호된 `deploy/.env`에만 기록합니다. SMTP
username/password는 hidden prompt로 입력하며 명령행 인수로 전달하지 않습니다.
`NOTIFIER_ENABLED=true`인 신규 설정은 `./deploy/scripts/notifier-smtp-test.sh`의
일회성 SMTP acceptance가 현재 자격 증명에 대해 성공하고, 빈 pre-activation queue와
정확한 Runtime=Running plugin을 확인한 뒤 activation cutoff를 기록할 때만 발송합니다.

마법사는 실제 `.env` 값을 출력하지 않습니다.

`deploy/.env`의 신규 생성과 notifier 설정 추가는 같은 파일시스템 안에서
no-clobber 이동과 hard link로 게시됩니다. Ubuntu 24.04 기본 GNU Coreutils의
`mv -T -n`과 exact-target `ln -T --`를 사용하며, `validate.sh`가 이 전제를
확인합니다. 설정 도중
중단되어 `.env.configure-displaced` recovery 파일이 남으면 설치기는 값을
출력하거나 임의로 덮지 않고 `[ACTION REQUIRED]`로 중단합니다. recovery 파일을
삭제하지 말고 로컬 관리자에게 원본/현재 파일 복구 판단을 요청합니다.

## 4. 외부 작업 후 재개

DNS 등의 외부 조건이 준비되지 않으면 설치된 컨테이너와 데이터는 유지되고
마법사는 `[ACTION REQUIRED]`와 후속 명령을 출력합니다.

```bash
./deploy/scripts/setup-wizard.sh --resume
```

이미 안전하게 작성된 `deploy/.env`가 있고 자동화 환경에서 질문을 허용하지
않으려면 다음 명령을 사용합니다.

```bash
./deploy/scripts/setup-wizard.sh --resume --non-interactive
```

`.env`가 없는 비대화형 실행은 안전하게 중단되며 exit code `20`을 반환합니다.

## 5. 설치 상태 확인

```bash
./deploy/scripts/install-status.sh
```

종료 코드는 다음과 같습니다.

| 코드 | 의미 |
| ---: | --- |
| `0` | 자동 설치 검증 통과 |
| `1` | 설정 또는 runtime 검증 실패 |
| `20` | 사용자 입력 또는 DNS 같은 외부 작업 필요 |

상태 명령은 자격 증명 값을 출력하지 않습니다.

## 6. 최초 관리자와 수동 인수시험

마법사가 `[READY]`를 출력하면 브라우저에서 안내된 HTTPS 주소를 열어 최초
System Admin을 생성합니다. 관리자 비밀번호는 채팅이나 셸 인수로 전달하지
않습니다.

이후 [관리자 가이드](./admin-guide.md)에 따라 다음 항목을 완료합니다.

1. System Admin MFA
2. 초대·이메일 확인·비밀번호 재설정 및 notifier SMTP 시험 메일의 inbox/link
3. SPF와 DKIM 결과
4. public/private 채널 Member 권한과 notifier 수신 경계
5. CJK 검색과 일반 안내문
6. iOS 또는 Android 앱

자동 점검 통과는 위 수동 인수시험을 대체하지 않습니다.
actual inbox/link/SPF/DKIM remains manual; `[READY]`는 자동 설치 검증의 결과일 뿐
실제 받은편지함, 링크, SPF/DKIM, 권한, CJK 또는 모바일 성공을 주장하지 않습니다.

## 7. 기본 readiness와 백업 readiness 분리

base readiness and backup readiness separation: 설치 마법사의 `[READY]`는 채팅
서비스의 자동 설치 gate만 뜻합니다. 백업 사용을 자동 승인하지 않습니다.

백업을 사용할 프로젝트는 [백업 및 복구 운영 가이드](./backup-restore.md)에 따라
`configure-backup.sh`, `install-backup.sh --register`, 최초 수동 백업, 원격 5개 객체
검증, 폐기 가능한 신규 VM 복구시험을 순서대로 수행합니다. unit 등록 뒤에도
timer remains disabled 상태여야 하며, 증거 검토와 명시적 인수 후에만 별도 명령으로
활성화합니다.
