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

| 범위 | ID | 실행 경계 |
| --- | --- | --- |
| 채널 기능 | `NF-FN-01`~`NF-FN-08` | 자동 real-image integration |
| 내용·envelope·HMAC 보안 | `NF-SEC-01`, `NF-SEC-02`, `NF-SEC-04`~`NF-SEC-06` | 자동 unit/integration |
| 장애·중복·control | `NF-REL-01`, `NF-REL-03`~`NF-REL-05` | 자동 real-image integration |
| 설치와 activation | `NF-INS-01`, `NF-INS-02` | 자동/fixture installer 시험 |
| SMTP 접수·inbox 구분 | `NF-INS-03`~`NF-INS-05` | target scope와 명시적 라이브 승인 필요 |
| OCI IAM 격리 | `NF-IAM-01`~`NF-IAM-07` | target Compartment/region과 명시적 라이브 승인 필요 |

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
