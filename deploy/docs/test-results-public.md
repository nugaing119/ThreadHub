# ThreadHub 공개 검증 결과 요약

이 문서는 ThreadHub 배포 기준선의 검증 범위와 판정만 공개하기 위한 요약본입니다.
실제 서비스 도메인, 이메일, 사용자명, 사용자·초대·게시물 수, 인증서 시각,
OCI 식별자와 운영 로그는 비공개 운영 기록에서 관리합니다.

## 1. 검증 기준

| 항목 | 기준 |
| --- | --- |
| Mattermost | `mattermost/mattermost-team-edition:11.7.7` |
| PostgreSQL | `postgres:18.4` |
| 운영체제 | Ubuntu Server 24.04 LTS AMD64 |
| 배포 모델 | 프로젝트당 독립 VM과 신규 데이터 경로 |
| 라이선스 | Mattermost Team Edition 무료 기능 |

정확한 이미지 Digest는 [`deploy/versions.env`](../versions.env)를 기준으로 합니다.

## notifier 공개 자동 증거

| test date | source commit | pinned image identity | plugin SHA-256 | result |
| --- | --- | --- | --- | --- |
| 2026-08-28 | `40bf682583177ffcfbb1cb1fc3b8fae50f9546ab` | Mattermost Team Edition 11.7.7 `sha256:d23471992cb1e3b57807bdc0b45aa7a7982e290ac310a7dc4b85a7ccacdbdff1` | `a7643bbc2262418473aa1c79d418d562234cbf163d7b2b1d9faefee021cacf13` | pass |

로컬 real-image integration은 다음 fixed 15 NF scenario groups를 pass했습니다:
`NF-FN-01`~`NF-FN-08`, `NF-SEC-01`, `NF-SEC-02`, `NF-REL-01`, `NF-REL-03`,
`NF-REL-04`, `NF-REL-05`, `NF-SEC-04/05/06`. cleanup은 격리된 test container와
temporary data만 대상으로 했습니다. 이후 일반 registry pull은 고정 이미지 blob
missing으로 재실행하지 못했으며, cached image는 digest/platform을 확인했습니다.
GitHub CI, live OCI, inbox/link/SPF/DKIM/permissions/CJK/mobile 수동 인수시험은
실행하지 않았습니다. 이 문서는 `[READY]` 또는 운영 성공을 주장하지 않습니다.

## 2. 자동·반자동 검증

다음 항목은 저장소 검증 스크립트, GitHub Actions와 실제 시험 인스턴스에서
확인했습니다.

- Bash 구문과 ShellCheck
- Docker Compose 구성
- 고정 이미지 manifest
- NGINX 구문, HTTPS 전환과 WebSocket
- PostgreSQL·Mattermost 컨테이너 health
- PostgreSQL 외부 포트 미노출
- Mattermost `127.0.0.1:8065` 바인딩
- PostgreSQL 18 데이터 경로와 모든 명시적 bind mount
- 공개 가입, 모바일 푸시, 공개 파일 링크와 플러그인 비활성화

## 3. 기능·보안 시험 결과

| 시험군 | 공개 판정 |
| --- | --- |
| 이메일 초대와 초대 없는 직접 가입 차단 | 통과 |
| 비밀번호 길이와 재설정 후 기존 세션 종료 | 통과 |
| System Admin MFA 정상·오류 OTP와 서버 복구 | 통과 |
| 일반 Member의 System Console·Team·채널 생성 차단 | 통과 |
| 일반 Member의 공개·비공개 채널 삭제 차단 | 통과 |
| Team 간 비공개 채널 격리 | 통과 |
| 한글 부분 문자열·채널·작성자·스레드 검색 | 통과 |
| 한글 파일명과 수정 메시지 검색 | 통과 |
| 파일 크기 경계, 다운로드와 공개 링크 차단 | 통과 |
| 컨테이너 재생성·VM 재부팅 후 데이터 유지 | 통과 |
| 사용 완료된 초대 토큰 재사용 차단 | 통과 |
| HTTP·HTTPS·WebSocket과 내부 포트 차단 | 통과 |
| SSH 키 인증과 root·비밀번호 로그인 차단 | 통과 |
| Certbot 갱신 dry-run | 통과 |

시험 계정, 게시물, 파일과 채널은 종료 후 식별해 정리했습니다. 실제 토큰,
사용자 이메일, 게시물 내용과 운영 수량은 이 공개 문서에 기록하지 않습니다.

## 4. 한글 검색 성능

실제 프로젝트 데이터와 분리한 폐기 가능한 시험 채널에서 대표 누적 게시물을
생성해 CJK 부분 문자열 검색을 반복 측정했습니다. 설정한 3초 기준을 충족했으며,
시험 데이터는 측정 후 제거했습니다. 실제 게시물 수와 상세 측정 원본은 비공개
검증 기록에서 관리합니다.

## 5. 프로젝트 Team 구조

초대 전용 프로젝트 Team과 다음 네 Team 공개 채널의 자동 참여를 검증했습니다.

```text
00-공지
01-프로젝트-일반
02-진행-이슈
03-결정사항
```

Team 공개 채널은 인터넷 공개가 아니라 해당 Team 멤버에게만 공개됩니다.
`reconcile-team-channels.sh`는 대상 Team URL 이름을 명시적으로 받아 기존 멤버의
누락된 채널 참여를 보완합니다.

## 6. 공개 문서 경계

다음 증거는 공개 저장소에 커밋하지 않습니다.

- 실제 서비스·고객 도메인과 이메일
- System Admin과 고객 사용자명
- 초대·확인·비밀번호 재설정 토큰
- 활성 사용자·초대·게시물·파일 수
- OCI OCID, 공인 IP와 SSH 허용 IP
- 인증서 실제 만료시각
- 운영 로그와 명령 출력 원본
- 실제 메시지, 파일, PostgreSQL 데이터와 백업

사이트별 최종 Go/No-Go 판정은 비공개 시험 기록과
[`test-plan.md`](./test-plan.md)의 미완료 수동 시험을 기준으로 결정합니다.
