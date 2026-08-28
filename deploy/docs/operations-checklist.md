# ThreadHub 운영 점검표

## 배포·변경·재부팅 후

- [ ] `health-check.sh` 통과
- [ ] `readiness-check.sh` 통과
- [ ] Mattermost와 PostgreSQL이 healthy
- [ ] HTTPS 인증서 유효
- [ ] HTTP가 HTTPS로 전환
- [ ] WebSocket 정상
- [ ] 8065가 loopback에만 바인딩
- [ ] 5432와 8443 외부 미노출
- [ ] host iptables의 80·443 허용 규칙과 `netfilter-persistent` 활성 상태 확인
- [ ] 기존 계정·메시지·파일 유지
- [ ] `./deploy/scripts/notifier-status.sh`의 plugin=active, SMTP acceptance, pending/sending/sent/failed와 oldest_pending_seconds를 확인

## 주 1회

- [ ] Boot Volume 사용률 확인
- [ ] `/srv/threadhub` 전체 사용량 확인
- [ ] PostgreSQL과 첨부파일 증가량 확인
- [ ] 컨테이너 상태와 재시작 횟수 확인
- [ ] Mattermost·PostgreSQL health 확인
- [ ] NGINX 상태와 오류 로그 확인
- [ ] HTTPS 인증서 만료일 확인
- [ ] Certbot 갱신 타이머 확인
- [ ] SMTP 실패와 OCI suppression 확인
- [ ] Docker·Mattermost·NGINX 로그 크기와 회전 확인
- [ ] 활성 사용자 50명 이하 확인
- [ ] notifier pending/sending/failed counter와 oldest pending 기준을 확인하고, 상태 출력에 channel ID·수신자·비밀값이 없는지 확인

## 즉시 채널 이메일 알림 운영

```bash
./deploy/scripts/notifier-status.sh
./deploy/scripts/notifier-control.sh status
```

`notifier-status.sh`는 pending, sending, sent, failed counter와 `oldest_pending_seconds`,
마지막 성공·오류 분류를 출력합니다. allowlist는 ID가 아니라 개수만 표시합니다.

### 종료·credential 교체 전 queue 처리

1. `./deploy/scripts/notifier-control.sh drain`으로 새 수집만 중지합니다. 이 상태는 delivery-enabled drain mode이므로 기존 queue 발송은 계속됩니다.
2. delivery_enabled=true인 동안에만 다음 `threadhub-mailer retry-failed`로 `failed_exhausted`를 remediate/retry합니다. disable 뒤에는 retry-failed를 실행하지 않습니다.
3. `./deploy/scripts/notifier-status.sh`에서 `pending=0`과 `sending=0`을 모두 확인합니다. 최대 10분 뒤에도 0이 아니면 원인을 복구하거나 운영 책임자에게 escalate하며 close·SMTP·IAM·Approved Sender 변경을 진행하지 않습니다.
4. pending/sending이 0이면 다음 `threadhub-mailer cancel-failed`로 남은 `failed_permanent`와 `failed_exhausted`를 한 트랜잭션에서 취소하고 두 상태의 수신자 주소와 lease를 scrub합니다. pending/sending을 취소하거나 scrub하지 않습니다.
5. `./deploy/scripts/notifier-status.sh`에서 `failed=0`을 확인합니다. pending=0, sending=0, failed=0 중 하나라도 충족하지 못하면 closure와 SMTP/IAM 삭제는 blocked입니다.
6. `./deploy/scripts/notifier-control.sh disable`로 신규 수집과 SMTP delivery를 중지합니다.
7. `./deploy/scripts/notifier-status.sh`에서 `delivery_enabled=false`와 pending=0, sending=0, failed=0을 확인합니다. 이 뒤에는 notifier delivery를 다시 시도하지 않습니다.

```bash
docker compose --env-file deploy/.env --env-file deploy/versions.env \
  -f deploy/docker-compose.yml exec -T threadhub-mailer /threadhub-mailer retry-failed
docker compose --env-file deploy/.env --env-file deploy/versions.env \
  -f deploy/docker-compose.yml exec -T threadhub-mailer /threadhub-mailer cancel-failed
```

`disable`은 이미 OCI가 수락한 이메일을 회수하지 않으며 queue data를 삭제하지 않습니다.
백업 범위는 `/srv/threadhub/notifier/mailer/queue.db`와 그 SQLite sidecar뿐이며,
PostgreSQL·Mattermost 파일 또는 다른 프로젝트 큐를 함께 복사하지 않습니다.

queue backup은 `/srv/threadhub/notifier/mailer/queue.db`와 SQLite sidecar만 대상으로
하되 recipient addresses를 포함할 수 있습니다. backup은 비공개·보호된 저장소에만
두고 종료 결정에 따라 securely removed해야 합니다. 원시 backup이 남아 있으면 전체
email scrub을 주장하지 않습니다.

### SMTP Credential 교체

1. `./deploy/scripts/notifier-control.sh drain`을 실행합니다.
2. delivery-enabled drain mode에서 필요한 경우 `threadhub-mailer retry-failed`를 실행한 뒤 `pending=0`, `sending=0`을 확인합니다. 0이 아니면 중지하고 원인을 복구하거나 escalate합니다.
3. `threadhub-mailer cancel-failed`로 남은 `failed_permanent`와 `failed_exhausted`를 함께 취소·scrub하고 `failed=0`을 확인합니다. pending/sending은 그대로 유지되므로 앞 단계의 0 gate를 생략하지 않습니다.
4. `./deploy/scripts/notifier-control.sh disable`을 실행합니다.
5. 해당 프로젝트의 보호된 `deploy/.env`에서 SMTP credential을 교체합니다.
6. `./deploy/scripts/deploy.sh`로 변경된 환경을 사용하는 Compose 서비스를 재생성합니다. 이 명령은 Mattermost만 재생성한다고 가정하지 않습니다.
7. `./deploy/scripts/notifier-smtp-test.sh`로 one-time SMTP acceptance marker를 다시 만듭니다.
8. `./deploy/scripts/notifier-control.sh activate --from-env`로 gated control path를 통해 다시 활성화합니다.
9. `./deploy/scripts/notifier-status.sh`로 plugin, marker와 활성 delivery 상태를 확인합니다.

immediate disable and
24h/7d privacy retention: exhausted 수신자 이메일은 24시간 후 scrub하며 terminal
가명화 event metadata는 7일 후 삭제합니다. SMTP credential rotation 뒤에는
위 순서로 marker를 다시 시험합니다. HMAC rotation은 notifier disable과 queue
drain/cancel 뒤에만 수행하고, 새 marker와 activation cutoff를 다시 만들어야 합니다.

프로젝트 종료의 자원 회수 순서는 [프로젝트 종료 절차](./project-close.md)를 따릅니다.

## 기본 명령

```bash
./deploy/scripts/health-check.sh

docker compose \
  --env-file deploy/.env \
  --env-file deploy/versions.env \
  -f deploy/docker-compose.yml \
  ps

df -h / /srv/threadhub
sudo systemctl status nginx certbot.timer
sudo certbot certificates
sudo test -x /etc/letsencrypt/renewal-hooks/deploy/threadhub-reload-nginx
sudo certbot renew \
  --dry-run \
  --run-deploy-hooks \
  --no-random-sleep-on-renew
```

## 이상 징후

다음 현상이 반복되면 원인 확인과 수직 확장을 검토합니다.

- 컨테이너 OOM 또는 반복 재시작
- 메시지·채널 전환 지연
- CJK 검색 지연
- 파일 업로드 중 전체 응답 지연
- 디스크 여유 급감
- PostgreSQL health 실패

## 장애 대응 우선순위

1. 신규 초대와 변경 작업 중지
2. 외부 노출과 자격 증명 침해 여부 확인
3. 컨테이너·NGINX·디스크 상태 확인
4. 필요 시 자격 증명 폐기·교체
5. 고객에게 서비스 중단 또는 데이터 손실 가능성 안내

백업과 장애·오삭제 후 데이터 복구는 보장하지 않습니다.
