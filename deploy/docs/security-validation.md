# ThreadHub 보안 검증 기준

이 문서는 신규 `canonical fresh` ThreadHub가 OWASP 위험을 줄이기 위해 적용해야 할
배포 통제와 시험 증거를 정의한다. OWASP Top 10은 인식·위험 분류 문서이고, 그 자체가
제품 인증이나 완전한 준수 증명은 아니다. ThreadHub는
[OWASP Top 10:2025](https://owasp.org/Top10/2025/)을 위험 분류에 사용하고,
[OWASP ASVS 5.0.0](https://owasp.org/www-project-application-security-verification-standard/)
Level 1의 적용 가능한 항목을 구체적인 검증 기준으로 사용한다.

`OWASP compliant`, `OWASP certified` 또는 `취약점 없음`이라고 표현하지 않는다.
자동 시험, 수동 시험, 예외와 미검증 항목을 함께 기록한 뒤 제한된 운영 가능 여부를
판정한다.

## 1. Mattermost 라이선스 gate

보안 기능을 추가한다는 이유로 유료 Mattermost 기능을 활성화하지 않는다.

- 공식 `mattermost/mattermost-team-edition` 이미지만 사용한다.
- Mattermost 라이선스 키와 Enterprise Trial을 설치하거나 시작하지 않는다.
- SSO, Guest, Enterprise Search, 고급 감사·보존·접근제어처럼 유료 플랜으로 표시된
  기능을 무료 기능으로 전제하지 않는다.
- ThreadHub notifier는 Team Edition의 공개 plugin API만 사용하며 Mattermost의
  라이선스 검사나 기능 gate를 우회하지 않는다.
- ZAP, 이미지 취약점 스캐너, OCI Logging·Monitoring·Notifications와 Object Storage는
  Mattermost 유료 기능을 해제하는 수단이 아니라 배포 외부의 보안·운영 통제다.
- 기능의 플랜 표기가 불명확하면 적용 전에 현재 Mattermost 공식 문서와 정확한 서버
  tag의 공개 소스를 확인한다. 확인되지 않은 기능은 비활성 상태로 유지한다.
- notifier 의존성을 바꾸면 `notifier/THIRD_PARTY_NOTICES.md`와 라이선스 자동 시험을
  같은 변경에서 갱신한다.

## 2. 출시 gate

다음 네 종류의 증거가 모두 있어야 고객 데이터를 넣을 수 있다.

1. 저장소 gate: `validate.sh`, ShellCheck, Gitleaks 전체 이력, `govulncheck`, notifier
   unit/race와 real-image integration이 통과한다.
2. 공급망 gate: Mattermost·PostgreSQL·Go builder는 정확한 AMD64 digest로 고정하고,
   배포 시점에 지원되는 Mattermost 보안 패치와 PostgreSQL minor를 사용한다. 안정성을
   위해 ESR을 우선하되, 최신 ESR에 외부에서 도달 가능한 Critical/High 취약점이 남고
   지원 중인 Team Edition 기능 릴리스에서 수정된 경우에는 격리된 복제 DB 시험 후 해당
   기능 릴리스를 사용할 수 있다. 실행 이미지의 알려진 Critical/High 취약점은 이미지
   스캔 결과와 vendor 상태를 검토한다.
3. 런타임 gate: `install-status.sh`, `health-check.sh`, `readiness-check.sh`, 공개 포트,
   SSH, TLS, 보안 헤더, 컨테이너 격리, 로그 수집과 경보를 확인한다.
4. 애플리케이션 gate: 폐기 가능한 무데이터 시험 인스턴스에서 수동 인증·권한 시험과
   ZAP baseline을 수행한다. 능동 공격형 스캔은 운영 인스턴스에 실행하지 않는다.

Critical 또는 High 결과가 있으면 다음 중 하나가 문서화되기 전까지 고객 사용은
No-Go다.

- 패치 또는 설정 수정 후 재시험 통과
- upstream 오탐 또는 도달 불가능 경로임을 재현 가능한 증거로 확인
- 보완 통제, 소유자, 만료일과 재검토일이 있는 명시적 위험 수용

ESR에서 기능 릴리스로 이동하는 것은 Enterprise 기능 활성화나 라이선스 변경을 뜻하지
않는다. 이동 대상도 반드시 공식 `mattermost/mattermost-team-edition` 이미지여야 하며,
라이선스 키와 Enterprise Trial이 없는 상태를 다시 확인한다. 기능 릴리스는 ESR보다
업데이트 주기가 짧으므로 지원 종료 전에 다음 지원 릴리스 또는 보안 수정 ESR로 이동할
운영 일정을 함께 기록한다.

버전별 판정 증거와 현재 예외는
[`security-image-review-2026-09-07.md`](security-image-review-2026-09-07.md)에 기록한다.

## 3. OWASP Top 10:2025 대응표

| 위험 | ThreadHub 기본 통제 | 필수 검증 |
| --- | --- | --- |
| A01 Broken Access Control | 프로젝트 경계별 VM, 초대 전용 가입, System Scheme, 공개 파일 링크·Webhook·토큰 비활성 | 비회원·타 Team·비공개 채널 접근과 일반 Member 권한 거부 |
| A02 Security Misconfiguration | 고정 Compose, 8065 loopback, DB host port 없음, no-new-privileges, 최소 NSG·호스트 방화벽 | `validate.sh`, `health-check.sh`, 외부 포트 스캔 |
| A03 Software Supply Chain Failures | tag+AMD64 digest, 고정 GitHub Action, Gitleaks, ShellCheck, `govulncheck`, 제3자 고지 | manifest 확인, 전체 이미지 취약점 검토, CI 통과 |
| A04 Cryptographic Failures | TLS 1.2/1.3, HSTS, STARTTLS 인증서 검증, 64 hex DB/HMAC 비밀값, OCI 서버측 백업 암호화 | TLS·인증서 갱신·SPF/DKIM·비밀 파일 mode 시험 |
| A05 Injection | Mattermost upstream 구현, 입력 크기 제한, Webhook·명령·OAuth provider 비활성 | ZAP baseline, 파일명·검색·게시물 특수문자 회귀시험 |
| A06 Insecure Design | 작성 경로와 Mailer 큐 분리, fail-closed control, 백업 복구 gate | SMTP 장애·재시도·복구 queue quarantine 시험 |
| A07 Authentication Failures | 비밀번호 12자, 최대 로그인 시도, API rate limit, 이메일 확인, 관리자 MFA 절차, 비밀번호 변경 시 세션 종료 | 직접 가입·초대 URL·재설정 token·MFA·rate limit 시험 |
| A08 Software or Data Integrity Failures | 고정 digest, plugin bundle SHA, HMAC+timestamp+nonce, 백업 manifest SHA | 변조 bundle·서명·replay·백업 artifact 거부 시험 |
| A09 Security Logging and Alerting Failures | query string 없는 NGINX 로그, JSON Mattermost 로그, OCI Logging, Monitoring alarm과 Notification | 실제 로그 수집 시각과 시험 경보 수신 확인 |
| A10 Mishandling of Exceptional Conditions | shell strict mode, 원자적 no-clobber, 건강검사, bounded backup downtime, SMTP 영구 실패 격리 | fault injection·중단·재실행·불완전 설정 시험 |

## 4. OCI와 호스트 검증

- VM: Ubuntu 24.04 AMD64, 2 OCPU, 16GB RAM, 200GB 이상 Boot Volume
- 네트워크: TCP 22는 승인된 관리자 CIDR, 80·443은 인터넷, 8065·5432·8443과
  Docker API는 외부 비노출
- SSH: 공개키만 허용, root 직접 로그인과 비밀번호 로그인 금지
- TLS: HTTP 영구 전환, TLS 1.2/1.3, 유효 인증서, 자동 갱신 dry-run 성공
- 런타임: PostgreSQL host port 없음, Mattermost 8065 loopback, Mailer host port 없음,
  명시적 bind mount와 안전한 UID/GID·mode
- Object Storage: 프로젝트 전용 private bucket, exact-instance Dynamic Group,
  VM에 object delete 권한 없음, lifecycle service만 만료 객체 삭제 가능
- 관측성: 프로젝트 전용 log group·custom log, CPU·메모리·인프라 상태·접근성 alarm,
  확인된 Notification 구독

공용 subnet의 Security List와 전용 NSG는 허용 규칙이 합산된다. 전용 NSG가 기존
Security List를 더 좁게 덮어쓴다고 가정하지 않는다. 두 계층을 함께 검토하고,
호스트 방화벽으로 예상하지 않은 ingress를 다시 차단한다.

## 5. DAST와 수동 시험 경계

ZAP baseline은 로그인하지 않은 공개 표면의 수동(passive) 결과를 확인한다. 능동
스캔은 실제 사용자·대화·첨부파일이 전혀 없는 폐기 가능한 시험 VM에만 허용한다.
관리자, Member, 비회원 역할별 접근제어는 브라우저와 공식 API의 기대 결과로 별도
시험한다. SMTP 비밀번호, session token, reset token, 이메일 주소와 채널 ID를 ZAP
파일이나 공개 CI artifact에 넣지 않는다.

시험 결과에는 다음만 공개할 수 있다.

- 실행일과 대상 소프트웨어 tag/digest
- 시험 ID별 pass/fail/accepted-risk
- 개인정보를 제거한 finding 종류와 수정 상태

원본 ZAP 보고서, OCI 식별자, 실제 hostname·이메일·로그·백업 식별자는 비공개 운영
증거에 보관한다.

## 6. 완료 판정

`[READY]`는 설치 자동 점검 완료만 뜻한다. 다음 항목까지 끝나야 보안 검증을
완료했다고 기록할 수 있다.

- Notification 이메일 구독 확인과 시험 경보 수신
- OCI Logging에서 auth, NGINX와 Mattermost 로그의 최근 수집 확인
- 이미지 취약점 검토와 ZAP baseline 결과 판정
- 관리자 MFA, 초대, 비밀번호 재설정, Member 권한과 비공개 채널 경계
- CJK, 모바일, SMTP inbox/link/SPF/DKIM
- 최초 원격 백업과 별도 폐기 VM 복구시험
