# Security Policy

## Supported baseline

보안 수정은 기본 브랜치의 최신 검증 커밋을 기준으로 제공합니다. 운영 배포는
저장소의 최신 커밋을 무조건 실행하지 말고, 배포 전에 변경사항과 검증 결과를
확인해야 합니다.

## Reporting a vulnerability

비밀번호, 토큰, 개인키, 고객정보 또는 실제 운영 인프라 정보가 포함된 내용을
공개 Issue에 작성하지 마십시오. GitHub 저장소의 **Security** 탭에서 private
vulnerability report를 제출해 주십시오.

보고서에는 다음 내용을 포함해 주십시오.

- 영향을 받는 파일과 버전 또는 commit SHA
- 재현 절차와 예상 영향
- 민감값을 제거한 로그 또는 증거
- 이미 악용됐다고 판단할 근거가 있는지 여부

실제 자격 증명이 노출된 경우 보고서에 값을 다시 붙여 넣지 말고 자격 증명의
종류와 노출 위치만 기재해 주십시오.

## Public repository boundary

다음 항목은 이 저장소에 커밋하지 않습니다.

- 실제 `.env`와 데이터베이스·SMTP 자격 증명
- API 토큰, 초대·확인·비밀번호 재설정 토큰
- SSH·TLS 개인키와 OCI CLI 설정
- OCI OCID, 실제 공인 IP와 SSH 허용 IP
- 고객 도메인, 이메일, 사용자명과 프로젝트 식별정보
- 운영 로그, 메시지, 첨부파일, PostgreSQL 데이터와 백업
- notifier 큐의 수신자 주소·제어 파일·SMTP acceptance marker와 실제 알림 수신 결과
- 백업 artifact·manifest, backup status·diagnostic, 버킷명과 백업 ID

즉시 채널 이메일 알림의 `project_team_channel` 모드는 프로젝트 도메인과 공개·비공개
Team·채널 표시명을 OCI Email Delivery와 수신자 메일함에 전달합니다. 메시지 본문,
작성자명, 첨부파일명과 다른 수신자 주소는 전달하지 않습니다. 채널명 자체가 기밀이면
`generic` 모드를 사용합니다. Team·채널명과 수신자 주소는 일반 공개 문서·로그·상태
출력에 넣지 않습니다. 공개 시험 증거는
[공개 검증 결과 요약](./deploy/docs/test-results-public.md)의 고정 ID·SHA·통과/실패
범위로 제한하고, 운영 식별자가 필요한 기록은 비공개 운영 기록에서만 보관합니다.

## Backup privacy boundary

백업은 Private OCI Object Storage 버킷과 root 전용 로컬 상태에만 저장합니다.
backup manifest, backup status, diagnostic 파일에는 운영 구조와 식별정보가 포함될
수 있으므로 공개 저장소, Issue, 채팅 또는 공개 CI artifact로 내보내지 않습니다.
백업 객체와 복구 증거에는 public URL 또는 Pre-Authenticated Request를 만들지
않으며, 실패 메일은 고객 데이터 없이 일반 문구만 전송합니다. 자세한 통제는
[백업 및 복구 운영 가이드](./deploy/docs/backup-restore.md)를 따릅니다.
