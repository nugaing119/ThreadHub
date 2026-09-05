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

`backup-restore-integration` 표는 실제로 통과한 커밋만 기록합니다. 허용된 필드 외에
버킷, namespace, OCID, 도메인, 이메일, backup ID, object key, 데이터 크기,
사용자 수와 파일명을 공개하지 않습니다.

## notifier 공개 자동 증거

| test date | source commit | Mattermost image digest | PostgreSQL image digest | notifier version | plugin bundle SHA-256 | NF scenario count | result |
| --- | --- | --- | --- | --- | --- | ---: | --- |
| 2026-08-28 | `0cbb3c35927a7cc5b3cd0f07d8cdfbfbc98e072e` | `sha256:d23471992cb1e3b57807bdc0b45aa7a7982e290ac310a7dc4b85a7ccacdbdff1` | `sha256:d93de42662696f278fb34354b06fdaa90ad7ca3106d6f72fbd01d16da006d2cf` | `0.1.0` | `a7643bbc2262418473aa1c79d418d562234cbf163d7b2b1d9faefee021cacf13` | 15 | pass |

## backup·restore 공개 자동 증거

| test date | source commit | Mattermost image digest | PostgreSQL image digest | notifier version | backup scenario count | result |
| --- | --- | --- | --- | --- | ---: | --- |
| 2026-09-01 | `f867f91eb46c2b68643cdf011c336307a8f68548` | `sha256:d23471992cb1e3b57807bdc0b45aa7a7982e290ac310a7dc4b85a7ccacdbdff1` | `sha256:d93de42662696f278fb34354b06fdaa90ad7ca3106d6f72fbd01d16da006d2cf` | `0.1.0` | 4 | pass |

## existing-adoption 자동 증거 계약

`notifier-existing-adoption` CI job은 신규설치 real-image integration 성공 뒤 실행되며,
기존 Mattermost 채택 시나리오 `NF-ADOPT-01`~`NF-ADOPT-10`을 검증합니다. 성공
artifact에는 다음 비밀정보 없는 필드만 기록됩니다. 이 설명은 아직 실행되지 않은
커밋을 통과로 표시하지 않으며, 실제 판정은 해당 커밋의 CI artifact를 기준으로 합니다.

| 필드 | 공개 값 |
| --- | --- |
| test date | UTC 실행일 |
| source commit | 검증한 Git commit |
| Mattermost/PostgreSQL image digest | `deploy/versions.env`의 고정 Digest |
| notifier version | 고정 release version |
| plugin bundle SHA-256 | 실행 중 검증된 bundle hash |
| existing-adoption scenario count | 10 |
| result | `pass` 또는 실패 시 안전한 `NF-ADOPT-*` ID |

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
- 공개 가입, 모바일 푸시, 공개 파일 링크와 ThreadHub notifier 외 플러그인 비활성화
- notifier plugin·Mailer의 공개 API, 개인정보 최소화, 영구 큐와 장애 격리

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
| notifier 공개·비공개 채널 루트 글·스레드와 제외 이벤트 | 통과 |
| Mailer·SMTP 장애 중 게시 성공과 영구 큐 복구 | 통과 |
| notifier 산출물 비밀정보·라이선스 고지 검사 | 통과 |

시험 계정, 게시물, 파일과 채널은 종료 후 식별해 정리했습니다. 실제 토큰,
사용자 이메일, 게시물 내용과 운영 수량은 이 공개 문서에 기록하지 않습니다.

## 4. 신규 프로젝트 생성·폐기 라이브 검증

2026-09-05에 `4909de77252f0dea01a4c992cf23a15f4283ccea` 기준으로 기존 운영
인스턴스와 분리된 폐기 가능한 프로젝트를 생성해 다음 한 사이클을 확인했습니다.

- Ubuntu 24.04 AMD64, 2 OCPU, 16GB와 신규 Boot Volume에서 저장소 검증 후
  설치 마법사 `[READY]` 통과
- 프로젝트 전용 DNS, NSG, 예약 공인 IP, SMTP IAM user/group/policy/credential,
  Approved Sender와 비공개 Object Storage bucket 구성
- 공유 Dynamic Group exception에 exact 시험 VM OCID만 임시 추가하고,
  `request.principal.id`와 exact bucket 조건으로 다른 프로젝트 접근 차단
- public/private 채널의 root 글, 스레드, 첨부파일, 한글 검색과 notifier 메일 링크를
  운영자 수동 확인
- 두 번의 수동 백업에서 매번 정확한 원격 5개 객체, SHA-256, 서비스 복구와 5분 이내
  쓰기 중단 gate 통과
- notifier drain 뒤 pending/sending/failed 0과 delivery 비활성 상태에서 완전 폐기
- lifecycle rule, 모든 backup object, bucket, 프로젝트 IAM·Email Delivery·DNS·VM,
  Boot Volume, 예약 공인 IP와 NSG의 잔여 없음 확인
- 공유 Dynamic Group의 기존 운영 VM clause와 두 운영 HTTPS 응답 정상 확인

이 사이클은 폐기 경로 검증이 목적이므로 신규 VM restore acceptance는 수행하지 않았고
backup timer도 활성화하지 않았습니다. System Admin MFA도 해당 시험 프로젝트의 명시적
위험 수용에 따라 생략했습니다. 따라서 이 결과만으로 정기 백업 readiness나 MFA 인수를
주장하지 않습니다. 실제 도메인, 이메일, OCID, IP, bucket 이름, backup ID와 운영 수량은
비공개 기록에만 보관했습니다.

## 5. 한글 검색 성능

실제 프로젝트 데이터와 분리한 폐기 가능한 시험 채널에서 대표 누적 게시물을
생성해 CJK 부분 문자열 검색을 반복 측정했습니다. 설정한 3초 기준을 충족했으며,
시험 데이터는 측정 후 제거했습니다. 실제 게시물 수와 상세 측정 원본은 비공개
검증 기록에서 관리합니다.

## 6. 프로젝트 Team 구조

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

## 7. 공개 문서 경계

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
