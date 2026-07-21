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
