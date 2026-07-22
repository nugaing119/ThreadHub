# ThreadHub 검증 결과 — 2026-07-21

## 1. 기준 정보

| 항목 | 값 |
| --- | --- |
| 대상 | `https://threadhub.stillwhy.com` |
| 서버 검증 시각 | 2026-07-21 05:25 UTC |
| Mattermost | `mattermost/mattermost-team-edition:11.7.7` |
| Mattermost Digest | `sha256:d23471992cb1e3b57807bdc0b45aa7a7982e290ac310a7dc4b85a7ccacdbdff1` |
| PostgreSQL | `postgres:18.4` |
| PostgreSQL Digest | `sha256:d93de42662696f278fb34354b06fdaa90ad7ca3106d6f72fbd01d16da006d2cf` |
| 라이선스 | 설치된 유료 라이선스 없음 |

`readiness-check.sh`를 실행해 컨테이너 health, 중요 Mattermost 환경설정, HTTPS와 HTTP 영구 전환을 확인했고 통과했다.

## 2. 일반 Member 권한과 격리

실제 외부 초대 사용자(이메일 비공개)는 다음 상태임을 서버에서 확인했다.

- 사용자 역할: `system_user`
- Team: `project`만 소속
- Team Admin과 System Admin 아님
- 기본 채널 `00`~`05`, `town-square`, `off-topic` 소속
- 비공개 `test_project` 채널 미소속

System Scheme의 일반 채널 역할에서 다음 권한을 제거했다.

- `delete_public_channel`
- `delete_private_channel`

채널 멤버 관리, 채널 속성 변경, 북마크 관리와 본인 메시지 삭제 권한은 합의에 따라 유지했다.

실제 고객과 동일한 일반 역할의 임시 `threadhubqa` 계정으로 API 권한을 시험했다.

| 시험 | 결과 | 판정 |
| --- | ---: | --- |
| System 설정 조회 | HTTP 403 | 통과 |
| Team 생성 | HTTP 403 | 통과 |
| 공개 채널 생성 | HTTP 403 | 통과 |
| 비공개 채널 생성 | HTTP 403 | 통과 |
| 소속 Team 목록 | `project`만 반환 | 통과 |
| 기본 채널 목록 | `00`~`05`, `town-square`, `off-topic` | 통과 |
| 비공개 `test_project` 노출 | 미노출 | 통과 |
| 내부 전용 Team 직접 조회 | HTTP 403 | 통과 |

채널 삭제·보관은 실제 채널 손상을 피하기 위해 API 호출하지 않고 적용된 `channel_user` 역할에서 두 삭제 권한이 사라졌는지 확인했다. 실제 고객 계정 UI에서 메뉴가 노출되지 않는지는 후속 수동 시험으로 확인한다.

## 3. 한글 검색

임시 일반 Member가 `04-questions` 채널에 검색 말뭉치 9개와 스레드 답글 1개를 작성한 뒤 Mattermost 검색 API로 시험했다.

| 시험 | 실제 결과 | 응답시간 | 판정 |
| --- | ---: | ---: | --- |
| `오류` 부분 문자열 검색 | 기대 게시물 7개 모두 반환 | 28ms | 통과 |
| `오류 in:04-questions` 채널 필터 | 7개 반환 | 29ms | 통과 |
| `오류 from:threadhubqa` 작성자 필터 | 7개 반환 | 28ms | 통과 |
| `스레드 로그인오류` 답글 검색 | 스레드 답글 반환 | 28ms | 통과 |
| 수정 메시지 검색 | 수정 후 키워드 반환 | 별도 미측정 | 통과 |
| 한글 파일명 검색 | 파일 검색 API에서 반환 | 별도 미측정 | 통과 |

`오류` 검색은 `로그인 오류`, `고객로그인오류`, `로그인오류를 확인했습니다`와 스레드의 `로그인오류`를 모두 반환했다. 핵심 CJK 부분 문자열 검색은 고객 파일럿 기준을 통과했다.

시험 종료 후 검색 말뭉치와 가입 시스템 게시물을 모두 소프트 삭제했다. `threadhubqa` 계정은 비활성화했고 활성 게시물 수가 0임을 확인했다.

## 4. MFA

활성 System Admin은 `threadhub_admin` 1개이며 `mfaactive=true`임을 서버에서 확인했다. 사용자가 MFA 등록과 로그인을 완료했다고 확인했다. 잘못된 OTP와 복구 절차 시험 결과는 별도로 기록해야 한다.

## 5. 파일과 데이터 영속성

일반 QA 계정으로 작은 파일과 파일 크기 경계를 시험했다.

| 시험 | 결과 | 판정 |
| --- | ---: | --- |
| 작은 파일 업로드 | HTTP 201 | 통과 |
| 정확히 25MiB 업로드 | HTTP 201 | 통과 |
| 25MiB + 1바이트 업로드 | HTTP 413 | 통과 |
| 25MiB 파일 다운로드 | HTTP 200 | 통과 |
| 업로드·다운로드 SHA-256 | 일치 | 통과 |
| 공개 파일 링크 요청 | HTTP 403 | 통과 |

동일한 게시물 ID, 파일 ID와 SHA-256을 기준으로 다음 영속성 시험을 순서대로 수행했다.

| 시험 | 게시물 | 파일 다운로드 | SHA-256 | 판정 |
| --- | ---: | ---: | ---: | --- |
| `docker compose down` 후 재생성 | HTTP 200 | HTTP 200 | 일치 | 통과 |
| PostgreSQL 단독 강제 재생성 | HTTP 200 | HTTP 200 | 일치 | 통과 |
| Mattermost 단독 강제 재생성 | HTTP 200 | HTTP 200 | 일치 | 통과 |
| VM 재부팅 | HTTP 200 | HTTP 200 | 일치 | 통과 |

VM은 재부팅 후 자동 시작됐고 `readiness-check.sh`가 통과했다. 시험 게시물과 파일 메타데이터는 시험 종료 후 소프트 삭제 상태임을 확인했다.

## 6. 인증과 초대 코드

| 시험 | 결과 | 판정 |
| --- | ---: | --- |
| 초대 없는 직접 가입 | HTTP 403 | 통과 |
| 12자 미만 비밀번호로 변경 | HTTP 400 | 통과 |
| 관리자 비밀번호 재설정 메일 요청 | HTTP 200 | 서버 접수 통과 |
| 관리자 비밀번호 재설정 링크 사용 | 비밀번호 갱신 `2026-07-21 15:07:19 KST`, 완료 메일 발송 | 통과 |
| 비활성 계정 로그인 | HTTP 401 | 통과 |
| 계정 재활성화 후 로그인 | HTTP 200 | 통과 |
| Project Team 초대 코드 재생성 | HTTP 200 | 통과 |
| 재생성 전 초대 코드 사용 | HTTP 404 | 통과 |
| 재생성 후 새 초대 코드 사용 | HTTP 201 | 통과 |
| 새 초대 사용자의 Project 멤버십 | HTTP 200 | 통과 |

Team 초대 코드는 서버 내부 변수로만 처리했으며 출력하거나 저장소에 기록하지 않았다. 시험 종료 후 활성 System Admin은 1개, 활성 임시 사용자는 0개, 활성 임시 게시물은 0개임을 확인했다.

사용자가 Gmail에서 재설정 메일을 수신하고 링크로 비밀번호를 변경했으며, 서버의 `lastpasswordupdate`와 변경 완료 메일 발송 로그를 확인했다. 당시 기존 세션이 유지된 원인은 `ServiceSettings.TerminateSessionsOnPasswordChange=false`였으며, 이후 `MM_SERVICESETTINGS_TERMINATESESSIONSONPASSWORDCHANGE=true`를 배포 구성과 운영 컨테이너에 적용했다. 컨테이너 환경값과 Mattermost 실제 설정값이 모두 `true`이고 HTTPS ping이 HTTP 200임을 확인했다. 기존 세션 종료의 실제 동작 재시험은 다음 비밀번호 변경 시 기록한다.

## 7. 이메일 발신 도메인

- 발신 주소: `no-reply@stillwhy.com`
- OCI Email Domain `stillwhy.com`: `ACTIVE`
- OCI SPF 상태: 활성
- 공개 DNS SPF: `v=spf1 include:ap.rp.oracleemaildelivery.com ~all`
- OCI DKIM 키: 2048비트, `ACTIVE`
- DKIM CNAME과 대상 TXT 공개 DNS 조회: 성공
- 최근 30분 Mattermost SMTP 실제 전송 오류 패턴: 0건

Mattermost의 `Unable to convert html body to text` 경고는 6건 있었지만 SMTP 연결·인증·전송 실패가 아니라 메일 본문의 텍스트 변환 경고였다. OCI suppression 조회는 루트 compartment가 필요하므로 프로젝트 compartment 제한을 준수해 수행하지 않았다.

## 8. 네트워크·SSH·인증서·운영 상태

| 시험 | 결과 | 판정 |
| --- | ---: | --- |
| HTTP 80 | HTTP 301로 HTTPS 전환 | 통과 |
| HTTPS 443 | HTTP 200, TLS 검증 오류 0 | 통과 |
| 외부 8065 | 차단 | 통과 |
| 외부 5432 | 연결 거부 | 통과 |
| 외부 8443 | 연결 거부 | 통과 |
| WebSocket | HTTP 101 Switching Protocols | 통과 |
| SSH 비밀번호 인증 | `passwordauthentication no` | 통과 |
| SSH 공개키 인증 | `pubkeyauthentication yes` | 통과 |
| root 직접 로그인 | `permitrootlogin no`, 실제 접속 거부 | 통과 |
| Certbot timer | enabled·active | 통과 |
| Certbot 갱신 dry-run | 모든 simulated renewal 성공 | 통과 |

SSH 하드닝은 `/etc/ssh/sshd_config.d/99-threadhub-hardening.conf`에 적용했고 `sshd -t` 후 reload했다. 동일 구성을 배포 저장소의 `deploy/ssh/99-threadhub-hardening.conf`에도 추가했다.

운영 상태 확인 결과는 다음과 같다.

- Boot Volume 사용률 3%
- `/srv/threadhub` 사용량 94MiB
- Mattermost와 PostgreSQL 모두 healthy, 재시작 횟수 0
- Docker, NGINX, Certbot timer와 netfilter-persistent 모두 enabled·active
- 인증서 만료: 2026-10-18 23:55:28 UTC
- 활성 사용자: 3명

## 9. 모바일

- 관리자가 공식 모바일 앱에 `threadhub.stillwhy.com`을 연결하고 로그인했음을 사용자 확인으로 기록했다.
- 서버의 `MM_EMAILSETTINGS_SENDPUSHNOTIFICATIONS=false` 설정은 `readiness-check.sh`로 확인했다.
- 모바일 운영체제, 채널·스레드·DM·파일 시험과 앱 백그라운드 중 푸시 미수신·재실행 동기화는 추가 사용자 확인이 필요하다.

## 10. 2026-07-22 보완 검증

### 10.1 비밀번호 재설정과 세션 종료

운영 관리자 계정에 영향을 주지 않도록 임시 일반 사용자로 두 개의 독립 세션을 만든 뒤 실제 비밀번호 재설정 토큰 경로를 사용했다.

| 시험 | 결과 | 판정 |
| --- | ---: | --- |
| 재설정 전 세션 A | HTTP 200 | 통과 |
| 재설정 전 세션 B | HTTP 200 | 통과 |
| 비밀번호 재설정 메일 요청 | HTTP 200 | 통과 |
| 재설정 토큰 적용 | HTTP 200 | 통과 |
| 재설정 후 세션 A | HTTP 401 | 통과 |
| 재설정 후 세션 B | HTTP 401 | 통과 |
| 이전 비밀번호 로그인 | HTTP 401 | 통과 |
| 새 비밀번호 로그인 | HTTP 200 | 통과 |

`MM_SERVICESETTINGS_TERMINATESESSIONSONPASSWORDCHANGE=true`가 실제 reset 흐름에서 기존 세션을 모두 무효화함을 확인했다. 시험 사용자는 종료 시 비활성화했다.

### 10.2 MFA 실패와 복구

임시 System Admin으로 MFA를 등록해 다음 결과를 확인했다.

| 시험 | 결과 | 판정 |
| --- | ---: | --- |
| MFA secret 생성 | HTTP 200 | 통과 |
| MFA 활성화 | HTTP 200 | 통과 |
| 잘못된 OTP 로그인 | HTTP 401 | 통과 |
| 새 TOTP 구간의 정상 OTP 로그인 | HTTP 200 | 통과 |
| `mmctl user resetmfa` 복구 | `mfaactive=false` | 통과 |
| 복구 후 비밀번호 로그인 | HTTP 200 | 통과 |

시험 사용자를 비활성화한 뒤 활성 System Admin이 다시 1명임을 확인했다. 운영 복구 절차는 `admin-guide.md`에 기록했다.

### 10.3 이메일 초대 토큰 재사용

시험 시작 전 미수락 이메일 초대 토큰은 7개였다. 기존 초대에 영향을 주지 않는 새 시험 초대 1건으로 다음을 확인했다.

| 시험 | 결과 | 판정 |
| --- | ---: | --- |
| 최초 초대 토큰 가입 | HTTP 201 | 통과 |
| 가입 후 동일 토큰 DB 행 | 0건 | 통과 |
| 사용한 토큰 재사용 | HTTP 404 | 통과 |
| 재사용 오류 | `signup_link_invalid` | 통과 |
| 시험 후 미수락 초대 토큰 | 7개 | 기존 상태 유지 |

시험 사용자와 Team 가입 시스템 게시물을 정리한 뒤 전체·활성 게시물 수가 기존 80건·51건으로 돌아왔음을 확인했다. 미수락 초대 전체 무효화는 현재 7개의 실제 대기 초대에도 영향을 주므로 수행하지 않았다.

### 10.4 대표 누적 게시물 검색 성능

실제 프로젝트 데이터와 분리된 임시 비공개 채널에 API로 게시물 10,000건을 생성했다. 500건에는 `오류`를 포함했고, 5회 예열 후 `오류 in:<시험 채널>` 검색을 30회 측정했다.

| 항목 | 결과 |
| --- | ---: |
| 게시물 생성시간 | 12.137초 |
| 생성 처리량 | 초당 824.0건 |
| 검색 p50 | 6.609ms |
| 검색 p95 | 6.796ms |
| 검색 최대 | 6.864ms |
| API 반환 결과 수 | 매회 100건 |

`SEARCH-13`은 p95 3초 기준을 충분히 만족했다. 시험 채널과 10,000건의 게시물, 시험 사용자와 Team 가입 시스템 게시물을 정확히 식별해 제거했고 전체·활성 게시물 수가 80건·51건으로 복구됐음을 확인했다. 이후 `VACUUM (ANALYZE) posts`를 실행했다.

### 10.5 Twosome 구조

`Twosome`은 초대 전용 Team이며 `00-공지`, `01-프로젝트-일반`, `02-진행-이슈`, `03-결정사항`을 Team 공개 채널로 사용한다. `00-공지`는 이름을 변경한 기본 Town Square여서 Team 가입 시 자동 참여한다. 다른 세 채널은 관리자가 신규 사용자를 명시적으로 추가한다. 절차는 `twosome-runbook.md`에 기록했다.

### 10.6 일반 Member 채널 삭제 차단

임시 일반 Member와 고유한 공개·비공개 시험 채널을 만든 뒤 두 채널의 삭제 API를 호출했다.

| 시험 | 결과 | 판정 |
| --- | ---: | --- |
| 공개 채널 삭제 | HTTP 403 `permissions.app_error` | 통과 |
| 비공개 채널 삭제 | HTTP 403 `permissions.app_error` | 통과 |

시험 채널, 사용자와 Team 가입 시스템 게시물을 정리한 뒤 전체·활성 게시물 수가 80건·51건으로 유지됨을 확인했다. 기술적 삭제 차단은 검증됐으며 실제 외부 사용자 UI의 메뉴 미노출 여부만 수동 확인 대상으로 남긴다.

## 11. 판정과 남은 시험

- 서버·API 기준 일반 Member 권한 시험: 통과
- 핵심 한글 부분 문자열·필터·스레드 검색: 통과
- System Admin MFA 등록 상태: 통과
- 25MiB 파일 경계·다운로드·공개 링크 차단: 통과
- 컨테이너 재생성·VM 재부팅·데이터 영속성: 통과
- 네트워크·SSH·WebSocket·Certbot 갱신: 통과
- 수정 메시지·한글 파일명 검색: 통과
- 대표 누적 게시물 10,000건 CJK 검색 p95: 6.796ms, 통과
- 계정 비활성화 로그인 차단·재활성화: 통과
- 잘못된 System Admin OTP 거부와 MFA 복구: 통과
- 비밀번호 재설정 후 기존 세션 종료: 통과
- 사용 완료된 이메일 초대 토큰 재사용 차단: 통과
- 일반 Member의 공개·비공개 채널 삭제 API 차단: HTTP 403, 통과
- 실제 외부 시험 사용자 UI의 채널 삭제 메뉴 부재 확인: 표시 여부만 대기
- 모바일 운영체제 기록, 채널·스레드·DM·파일과 푸시 부재·재동기화: 일부 대기
- 비밀번호 재설정 메일 실제 수신·링크 동작: 통과
- 미수락 이메일 초대 전체 무효화: 기존 대기 초대 7개 정리 후 시험
- Gmail 외 네이버·다음 수신과 SPF·DKIM 원문 확인: 대기
- 비관리자 네트워크에서 SSH 차단: 대기
- 사용하지 않는 과거 SSH `/32` 규칙 정리: 대기

현재 판정은 내부 파일럿 **Go**, 제한된 고객 파일럿 **Conditional Go**다. 남은 수동·중단 시험을 완료한 뒤 최종 Go 여부를 판정한다.
