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
│   ├── install-docker.sh
│   ├── deploy.sh
│   ├── configure-nginx.sh
│   ├── health-check.sh
│   ├── readiness-check.sh
│   ├── destroy.sh
│   └── validate.sh
└── docs/
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
- 모바일 푸시, 플러그인, Webhook, 공개 파일 링크와 진단 텔레메트리를 비활성화합니다.
- `destroy.sh`는 컨테이너만 내리며 bind mount 데이터를 삭제하지 않습니다.

## 로컬 정적 검증

```bash
./deploy/scripts/validate.sh
```

Docker Compose가 설치되어 있으면 실제 `docker compose config`를 실행합니다. Docker가 없는 환경에서는 일반 YAML 구문까지만 검사하며, GitHub Actions가 Compose, ShellCheck, 이미지 manifest와 NGINX 구성을 다시 검증합니다.

## VM 배포 순서

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
