# ThreadHub 빠른 설치

이 절차는 새 Ubuntu 24.04 LTS AMD64 VM 한 대에 새 ThreadHub 인스턴스를
설치합니다. 기존 프로젝트 데이터를 이전하거나 OCI 리소스를 자동 생성하지 않습니다.

## 1. 준비해야 할 값

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

## 3. 대화형 설치

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
2. 초대·이메일 확인·비밀번호 재설정 메일
3. Member 권한
4. CJK 검색
5. iOS 또는 Android 앱

자동 점검 통과는 위 수동 인수시험을 대체하지 않습니다.
