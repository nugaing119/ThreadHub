# ThreadHub 배포 시험계획

상세 시험 ID, 말뭉치와 기대 결과는 다음 기준문서를 사용합니다.

- [ThreadHub MVP 구축 및 검증 계획서](../../docs/threadhub-mvp-build-validation-plan.md)
- [ThreadHub PRD v4.1 Final](../../docs/threadhub-prd-v4.1-final.md)

## 자동·반자동 시험

| 범위 | 도구 또는 명령 |
| --- | --- |
| Compose·셸·Digest·NGINX 정적검증 | GitHub Actions와 `validate.sh` |
| 컨테이너 health | `health-check.sh` |
| mount 유형과 경로 | `health-check.sh` |
| PG18 PGDATA | `health-check.sh` |
| loopback 포트 | `health-check.sh` |
| 중요 환경설정 | `readiness-check.sh` |
| HTTPS와 HTTP 전환 | `readiness-check.sh` |
| notifier unit/race·installer security | `cd notifier && make test` 및 `validate.sh` |
| notifier real-image integration | `cd notifier && make integration` (로컬/CI Docker 환경) |

## notifier 시험 ID와 실행 경계

다음 표는 **계획된 실행 경계**이며 통과 실행을 뜻하지 않습니다.

| ID | 분류 | 계획된 증거 |
| --- | --- | --- |
| NF-FN-01 | 자동 | real-image integration 공개 루트 글 |
| NF-FN-02 | 자동 | real-image integration 비공개 루트 글 |
| NF-FN-03 | 자동 | real-image integration 공개 스레드 답글 |
| NF-FN-04 | 자동 | real-image integration 비공개 스레드 답글 |
| NF-FN-05 | 자동 | real-image integration 비멤버 제외 |
| NF-FN-06 | 자동 | real-image integration 비활성 사용자 제외 |
| NF-FN-07 | 자동 | real-image integration 봇 수신자 제외 |
| NF-FN-08 | 자동 | real-image integration DM·그룹 DM 제외 |
| NF-FN-09 | 자동 | plugin unit 수정·삭제·반응 제외 |
| NF-FN-10 | 자동 | plugin unit 시스템 글 제외 |
| NF-FN-11 | 자동 | plugin unit Webhook·봇 작성 일반 글 |
| NF-FN-12 | 수동 | 권한 있는 사용자의 이메일 링크 원문 이동 |
| NF-FN-13 | 수동 | 제거된 사용자의 이메일 링크 접근 거부 |
| NF-SEC-01 | 자동 | integration 일반 안내문만 확인 |
| NF-SEC-02 | 자동 | integration 수신자별 단일 envelope |
| NF-SEC-03 | 자동 | unit SQLite·로그 최소 데이터 검사 |
| NF-SEC-04 | 자동 | integration 잘못된 HMAC 거부 |
| NF-SEC-05 | 자동 | integration stale timestamp 거부 |
| NF-SEC-06 | 자동 | integration nonce replay 거부 |
| NF-SEC-07 | 자동 | Compose 정적 Mailer host port 부재 |
| NF-SEC-08 | 자동 | Compose 정적 plugin upload/Marketplace 비활성 |
| NF-SEC-09 | 자동 | `validate.sh` 비밀값·이미지 검증 |
| NF-REL-01 | 자동 | real-image Mailer 중지 후 재개 |
| NF-REL-02 | 자동 | integration SMTP 일시 장애 재시도 |
| NF-REL-03 | 자동 | integration 동일 이벤트 중복 차단 |
| NF-REL-04 | 자동 | integration Mailer recreate queue 유지 |
| NF-REL-05 | 자동 | integration Mattermost recreate KV 유지 |
| NF-REL-06 | 수동 | target VM 재부팅 후 worker 재개 |
| NF-REL-07 | 자동 | unit 영구 주소 오류 격리 |
| NF-REL-08 | 자동 | unit 성공 후 수신자 주소 제거 |
| NF-REL-09 | 수동 | target rollback 뒤 채팅 유지·추가 발송 중단 |
| NF-INS-01 | 자동 | fixture installer 목표 기본값 |
| NF-INS-02 | 자동 | fixture installer `[ACTION REQUIRED]` |
| NF-INS-03 | 라이브 승인 필요 | 실제 OCI STARTTLS·AUTH·접수 |
| NF-INS-04 | 라이브 승인 필요 | 실제 SMTP acceptance 뒤 activation cutoff |
| NF-INS-05 | 라이브 승인 필요 | 자동 접수와 수동 inbox/SPF/DKIM 비교 |
| NF-IAM-01 | 라이브 승인 필요 | Credential A + Sender A 성공 |
| NF-IAM-02 | 라이브 승인 필요 | Credential A + Sender B 거부 |
| NF-IAM-03 | 라이브 승인 필요 | Credential B + Sender B 성공 |
| NF-IAM-04 | 라이브 승인 필요 | Credential B + Sender A 거부 |
| NF-IAM-05 | 라이브 승인 필요 | Project A credential 삭제 뒤 B 발송 |
| NF-IAM-06 | 라이브 승인 필요 | Project A 종료 뒤 공유 DNS 유지 |
| NF-IAM-07 | 라이브 승인 필요 | additive IAM policy audit |

라이브 시험은 Task 15의 새 명시적 승인 전에는 실행하지 않습니다. `NF-IAM`은 A/A 성공,
A/B 거부, B/B 성공, B/A 거부와 additive policy audit을 비공개 change record에서
확인합니다. 실제 inbox, link, SPF/DKIM은 자동 SMTP acceptance와 별도의 수동 인수
항목입니다.

## 필수 수동 시험군

- `AUTH-01`~`AUTH-20`: 가입, 초대 URL, 비밀번호, 기존 세션 종료, MFA
- `PERM-01`~`PERM-10`: 고객 Member 권한
- `SEARCH-01`~`SEARCH-13`: 한글 검색 기능과 성능
- `DATA-01`~`DATA-15`: 재시작·재생성·mount·소유권
- `MOB-01`~`MOB-10`: 공식 모바일 앱과 푸시 부재
- `FILE-01`~`FILE-07`: 25MiB 경계와 파일 유지
- `NET-01`~`NET-10`: 공개 포트, SSH, HTTPS와 WebSocket

시험 결과에는 실행일, 이미지 Digest, 시험자, 실제 결과, 증거와 Go/No-Go 판정을 기록합니다. 실제 도메인, 이메일, 사용자명, 운영 수량과 로그 원본은 비공개 운영 기록에만 보관합니다.

## 시험 결과

- [공개 검증 결과 요약](./test-results-public.md)
