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
