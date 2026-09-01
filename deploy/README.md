# ThreadHub deployment package

이 디렉터리는 ThreadHub MVP를 Ubuntu 24.04 LTS 기반 AMD64 OCI VM 한 대에 재현 가능하게 배포하기 위한 기준 구성입니다.

현재 구성은 정적 검증과 CI 검증 대상이며, 실제 OCI VM에서의 컨테이너·네트워크·메일·모바일 시험이 완료되기 전에는 고객 운영 완료본으로 간주하지 않습니다.

## 구성

```text
deploy/
├── docker-compose.yml
├── .env.example
├── versions.env
├── logrotate/
│   └── threadhub
├── nginx/
│   ├── threadhub-bootstrap.conf.template
│   └── threadhub.conf.template
├── scripts/
│   ├── common.sh
│   ├── setup-wizard.sh
│   ├── install-status.sh
│   ├── install-docker.sh
│   ├── deploy.sh
│   ├── configure-nginx.sh
│   ├── reload-nginx.sh
│   ├── health-check.sh
│   ├── readiness-check.sh
│   ├── destroy.sh
│   ├── build-notifier.sh
│   ├── configure-notifier.sh
│   ├── install-notifier-plugin.sh
│   ├── notifier-control.sh
│   ├── notifier-smtp-test.sh
│   ├── notifier-status.sh
│   ├── configure-backup.sh
│   ├── install-backup.sh
│   ├── backup.sh
│   ├── backup-status.sh
│   ├── restore.sh
│   └── validate.sh
└── docs/
    ├── quick-install.md
    ├── backup-restore.md
    ├── existing-mattermost-notifier.md
    ├── oci-provisioning.md
    ├── oci-email-delivery.md
    ├── setup.md
    ├── admin-guide.md
    ├── operations-checklist.md
    ├── test-plan.md
    ├── project-team-runbook.md
    └── project-close.md
```

## 설계 기준

- Mattermost와 PostgreSQL 이미지는 `linux/amd64` runtime manifest Digest로 고정합니다.
- PostgreSQL 18은 호스트 `/srv/threadhub/postgres`를 컨테이너 `/var/lib/postgresql`에 연결합니다.
- Mattermost config, data, logs, plugins, client/plugins와 bleve-indexes를 모두 명시적 bind mount로 연결합니다.
- Mattermost 호스트 디렉터리는 공식 이미지의 UID/GID `2000:2000`으로 설정합니다.
- Mattermost 8065는 `127.0.0.1`에만 연결합니다.
- PostgreSQL은 host port를 갖지 않습니다.
- Docker json-file 로그와 Mattermost 파일 로그의 크기 증가를 제한합니다.
- NGINX 접근 로그는 query string을 기록하지 않으며 access/error 로그를 `0640 www-data:adm`으로 제한합니다.
- 모바일 푸시, 플러그인, Webhook, 공개 파일 링크와 진단 텔레메트리를 비활성화합니다.
- 채널 이메일 notifier만 Mattermost Team Edition의 일반 plugin API로 실행하며,
  제어 파일이 없거나 안전하지 않으면 수집과 SMTP 발송을 fail-closed로 중지합니다.
- `destroy.sh`는 컨테이너만 내리며 bind mount 데이터를 삭제하지 않습니다.

## 로컬 정적 검증

```bash
./deploy/scripts/validate.sh
```

Docker Compose가 설치되어 있으면 실제 `docker compose config`를 실행합니다. Docker가 없는 환경에서는 일반 YAML 구문까지만 검사하며, GitHub Actions가 Compose, ShellCheck, 이미지 manifest와 NGINX 구성을 다시 검증합니다.

## VM 배포 순서

새 VM의 권장 진입점은 대화형 설치 마법사입니다.

```bash
./deploy/scripts/setup-wizard.sh
```

마법사는 실제 `.env` 값을 출력하지 않고 PostgreSQL 비밀번호를 자동 생성하며,
도메인·OCI SMTP처럼 프로젝트마다 다른 값만 입력받습니다. DNS 같은 외부 작업이
남으면 작업 내용을 출력하고 exit code `20`으로 중단하며, 완료 후 `--resume`으로
이어갈 수 있습니다. 전체 절차는 [빠른 설치 가이드](./docs/quick-install.md)를
따릅니다.

수동으로 각 단계를 실행하려면 다음 순서를 사용합니다.

```bash
cp deploy/.env.example deploy/.env
chmod 600 deploy/.env
# deploy/.env의 모든 example/REPLACE 값을 실제 프로젝트 값으로 변경

./deploy/scripts/install-docker.sh
./deploy/scripts/deploy.sh
./deploy/scripts/configure-nginx.sh
./deploy/scripts/readiness-check.sh
```

상세 절차는 [setup.md](./docs/setup.md)를 따릅니다.

설치 상태는 비밀값을 출력하지 않는 다음 명령으로 확인합니다.

```bash
./deploy/scripts/install-status.sh
```

notifier artifact build, 설정, plugin 설치, SMTP 접수시험, 제어와 상태 확인은 각각
`./deploy/scripts/build-notifier.sh`, `./deploy/scripts/configure-notifier.sh`,
`./deploy/scripts/install-notifier-plugin.sh`, `./deploy/scripts/notifier-smtp-test.sh`,
`./deploy/scripts/notifier-control.sh`, `./deploy/scripts/notifier-status.sh`를 사용합니다.
순서와 수동 인수 항목은 [빠른 설치 가이드](./docs/quick-install.md), 일상 운영은
[운영 점검표](./docs/operations-checklist.md), 종료는 [프로젝트 종료 절차](./docs/project-close.md)를 따릅니다.

일일 백업은 기본 설치 `[READY]`와 분리하여 등록합니다. 타이머는 최초 원격 백업
검증과 폐기 가능한 새 VM 복구시험의 증거를 검토할 때까지 비활성 상태로 유지합니다.
설정·인수·활성화·복구·보존 절차는 [백업 및 복구 운영 가이드](./docs/backup-restore.md)를
따릅니다.

위 절차는 새 ThreadHub 인스턴스용입니다. 이미 운영 중인 지원 대상 Mattermost에
notifier만 추가할 때는 base Compose와 기존 환경파일을 변경하지 않고
[기존 Mattermost notifier 적용 가이드](./docs/existing-mattermost-notifier.md)의
preflight·disabled 설치·수동 인수·rollback gate를 따릅니다.

기존 운영 VM에 저장소의 NGINX 템플릿 변경만 반영할 때는 다음 명령을
사용합니다. 기존 설정을 임시 백업하고 `nginx -t`를 통과한 경우에만
무중단 reload하며, 실패하면 이전 설정을 복원합니다. 이 과정은 NGINX
접근·오류 로그의 소유권과 권한도 안전한 기준으로 다시 맞춥니다.

```bash
./deploy/scripts/reload-nginx.sh
```

프로젝트 Team의 사용자 온보딩과 종료 절차는 [프로젝트 Team 운영 절차](./docs/project-team-runbook.md)를 따릅니다.

## Compose 직접 실행

스크립트 외부에서 Compose를 실행해야 할 때는 실제 환경파일을 먼저, 버전 기준파일을 마지막에 로드합니다. 버전파일을 마지막에 적용해 `.env`가 고정 이미지 정보를 덮어쓰지 못하게 합니다.

```bash
docker compose \
  --env-file deploy/.env \
  --env-file deploy/versions.env \
  -f deploy/docker-compose.yml \
  config --quiet
```

`config`를 `--quiet` 없이 실행하면 보간된 데이터베이스·SMTP 비밀번호가
터미널과 세션 로그에 표시될 수 있으므로 실제 환경파일에는 사용하지 않습니다.

정상 운영에서 `docker compose down -v`를 사용하지 않습니다.

## 비밀정보

`deploy/.env`는 Git에서 제외됩니다. 실제 DB·SMTP 자격 증명, 도메인, 고객 이메일, OCI 식별자, 인증서와 운영 데이터는 공개 저장소에 추가하지 않습니다.
