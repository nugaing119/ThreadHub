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
