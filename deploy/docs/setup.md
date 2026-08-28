# ThreadHub 설치 가이드

새 VM에서 가장 간단한 설치 방법은 [빠른 설치 가이드](./quick-install.md)의
`setup-wizard.sh`를 사용하는 것입니다. 이 문서는 각 단계를 수동으로 수행하거나
문제를 진단해야 할 때 사용합니다.

## 1. 사전조건

- OCI 계정과 Compute VM 생성 권한
- 프로젝트별 도메인과 DNS 변경 권한
- OCI Email Delivery SMTP 자격 증명
- Approved Sender, SPF와 DKIM 구성 권한
- Ubuntu 24.04 LTS AMD64 VM 관리자 SSH 접근
- GitHub 공개 저장소에 대한 read 접근

## 2. OCI VM 기준

| 항목 | 기준 |
| --- | --- |
| 운영체제 | Ubuntu Server 24.04 LTS |
| CPU | AMD 기반 x86_64 |
| OCPU | 2 |
| 메모리 | 16GB |
| Boot Volume | 50GB 이상 |
| 공인 IP | 예약 공인 IP 권장 |
| Subnet | Public Subnet |

NSG 또는 보안목록에는 다음 규칙만 허용합니다.

| 포트 | Source | 목적 |
| --- | --- | --- |
| TCP 80 | 인터넷 | ACME와 HTTPS 전환 |
| TCP 443 | 인터넷 | ThreadHub |
| TCP 22 | 승인된 관리자 IP | SSH |

8065, 5432, 8443과 Docker API는 외부에 공개하지 않습니다.

SSH 공개키 인증만 허용하고 root 직접 로그인을 차단합니다.

```bash
sudo install -m 0644 \
  deploy/ssh/99-threadhub-hardening.conf \
  /etc/ssh/sshd_config.d/99-threadhub-hardening.conf
sudo sshd -t
sudo systemctl reload ssh
sudo sshd -T | grep -E '^(passwordauthentication|pubkeyauthentication|permitrootlogin) '
```

마지막 출력은 `passwordauthentication no`, `pubkeyauthentication yes`, `permitrootlogin no`여야 합니다. 현재 관리자 SSH 세션을 유지한 상태에서 새 터미널의 `ubuntu` 키 접속을 확인한 후 기존 세션을 종료합니다.

## 3. 저장소 준비

VM에서 저장소를 복제합니다.

```bash
git clone https://github.com/nugaing119/ThreadHub.git
cd ThreadHub
```

배포 기준 버전과 현재 커밋을 기록합니다.

```bash
git rev-parse HEAD
sed -n '1,200p' deploy/versions.env
```

## 4. 실제 환경파일 생성

```bash
cp deploy/.env.example deploy/.env
chmod 600 deploy/.env
openssl rand -hex 32
```

마지막 명령의 64자리 결과를 `POSTGRES_PASSWORD`로 사용합니다. DSN 안전성을 위해 PostgreSQL 비밀번호는 64자리 16진수만 허용합니다.

다음 값을 모두 실제 프로젝트 값으로 교체합니다.

- `THREADHUB_DOMAIN`
- `LETSENCRYPT_EMAIL`
- `POSTGRES_PASSWORD`
- `SMTP_SERVER`
- `SMTP_USERNAME`
- `SMTP_PASSWORD`
- `SMTP_FROM_ADDRESS`
- `SMTP_REPLY_TO_ADDRESS`

실제 `.env`는 복사하거나 채팅에 붙여 넣지 않고 서버에서만 관리합니다.

## 5. OCI Email Delivery 준비

처음 구성하는 경우 [OCI Email Delivery 상세 설정](./oci-email-delivery.md)을 먼저
완료합니다.

배포 전에 다음 항목을 준비합니다.

1. SMTP Credentials 생성
2. 프로젝트 발신주소를 Approved Sender로 등록
3. OCI 리전 SMTP endpoint 확인
4. DNS SPF 레코드 구성
5. DKIM 레코드 구성과 검증

SMTP 587과 STARTTLS를 사용합니다. OCI 콘솔 비밀번호가 아니라 SMTP Credentials를 `.env`에 입력합니다.

## 6. Docker 설치

```bash
./deploy/scripts/install-docker.sh
```

스크립트는 다음 작업을 수행합니다.

- Ubuntu 24.04와 AMD64 확인
- Docker 공식 Ubuntu 저장소 구성
- `versions.env`에 기록한 Docker Engine, CLI, containerd와 Compose Plugin 설치
- 패키지 자동 변경 방지를 위한 hold 적용
- Docker 서비스 자동 시작
- 실제 설치 버전 검증

업데이트 시에는 hold를 무작정 해제하지 않고 버전 기준과 시험계획을 먼저 변경합니다.

## 7. Mattermost와 PostgreSQL 배포

정적 검증만 수행하려면 다음 명령을 사용합니다.

```bash
./deploy/scripts/deploy.sh --validate-only
```

실제 배포:

```bash
./deploy/scripts/deploy.sh
```

스크립트는 다음을 확인하거나 수행합니다.

- example·REPLACE 값 차단
- 64자리 PostgreSQL 비밀번호 확인
- `/srv/threadhub` 경로 생성
- Mattermost 6개 경로 생성과 UID/GID `2000:2000` 적용
- PostgreSQL 18 부모 경로 생성
- Compose 구성 검증
- Digest 고정 이미지 pull
- 컨테이너 시작과 health 대기
- mount, PGDATA와 loopback 포트 검사

## 8. DNS와 HTTPS

`THREADHUB_DOMAIN`의 A 레코드를 예약 공인 IP에 연결하고 DNS 전파를 확인합니다. DNS A record는 unrelated RRsets를 덮어쓰지 않고 추가하며, 한 hostname을 two independent VMs에 동시에 연결하지 않습니다. TCP 80과 443이 VM에 도달해야 합니다.

```bash
./deploy/scripts/configure-nginx.sh
```

스크립트는 HTTP ACME bootstrap, Let’s Encrypt 인증서, 최종 HTTPS·WebSocket 프록시와 Certbot 갱신 dry-run을 구성합니다.

OCI Ubuntu 이미지의 host iptables가 외부 연결을 거부할 수 있으므로, 스크립트는 TCP 80·443 허용 규칙을 중복 없이 추가하고 `netfilter-persistent`로 저장합니다. OCI Security List 또는 NSG 규칙도 별도로 허용되어 있어야 합니다.

## 9. 기계 검증

```bash
./deploy/scripts/health-check.sh
./deploy/scripts/readiness-check.sh
```

`health-check.sh`는 다음을 확인합니다.

- 두 컨테이너 health
- PostgreSQL host port 부재
- Mattermost `127.0.0.1:8065` 바인딩
- PostgreSQL `/var/lib/postgresql/18/docker` PGDATA
- PostgreSQL 1개와 Mattermost 6개 bind mount
- Mattermost ping endpoint

`readiness-check.sh`는 중요 보안 설정, 실제 HTTPS endpoint와 HTTP 전환을 추가 확인합니다. 이메일 전달, MFA, 권한, CJK 검색과 모바일 시험은 별도의 수동 인수시험입니다. notifier 관련 설치 순서와 activation cutoff는 [빠른 설치 가이드](./quick-install.md), 상태·drain 절차는 [운영 점검표](./operations-checklist.md)를 따릅니다.

## 10. 초기 관리자와 제품 설정

[관리자 가이드](./admin-guide.md)에 따라 다음 작업을 완료합니다.

1. 초기 System Admin 생성
2. System Admin MFA 등록과 복구시험
3. System Scheme 적용
4. Internal·Project Team 생성
5. 기본 채널 생성
6. Gmail·네이버·다음 계정 메일 시험
7. 고객 Member 권한 시험
8. 한글 검색 시험
9. 공식 모바일 앱 시험

## 11. 완료 기준

- [PRD의 고객 파일럿 Go 조건](../../docs/threadhub-prd-v4.1-final.md#1911-제한된-고객-파일럿-go-조건)을 충족해야 합니다.
- [상세 구축·검증 계획](../../docs/threadhub-mvp-build-validation-plan.md)을 시험 결과와 함께 완료해야 합니다.
- 실제 고객을 초대하기 전에 No-Go 조건이 남아 있지 않아야 합니다.
