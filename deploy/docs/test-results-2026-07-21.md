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

## 10. 판정과 남은 시험

- 서버·API 기준 일반 Member 권한 시험: 통과
- 핵심 한글 부분 문자열·필터·스레드 검색: 통과
- System Admin MFA 등록 상태: 통과
- 25MiB 파일 경계·다운로드·공개 링크 차단: 통과
- 컨테이너 재생성·VM 재부팅·데이터 영속성: 통과
- 네트워크·SSH·WebSocket·Certbot 갱신: 통과
- 수정 메시지·한글 파일명 검색: 통과
- 계정 비활성화 로그인 차단·재활성화: 통과
- 실제 외부 시험 사용자 UI의 채널 삭제 메뉴 부재 확인: 대기
- 모바일 운영체제 기록, 채널·스레드·DM·파일과 푸시 부재·재동기화: 일부 대기
- 비밀번호 재설정 메일 실제 수신·링크 동작: 통과
- 비밀번호 재설정 후 기존 세션 종료와 이메일 초대 토큰 재사용: 대기
- Gmail 외 네이버·다음 수신과 SPF·DKIM 원문 확인: 대기
- 비관리자 네트워크에서 SSH 차단: 대기

현재 판정은 내부 파일럿 **Go**, 제한된 고객 파일럿 **Conditional Go**다. 남은 수동·중단 시험을 완료한 뒤 최종 Go 여부를 판정한다.
