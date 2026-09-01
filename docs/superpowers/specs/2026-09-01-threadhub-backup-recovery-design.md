# ThreadHub Backup and Recovery Design

## 1. 문서 정보

| 항목 | 내용 |
| --- | --- |
| 문서 유형 | 백업·복구 구조 설계 기준선 |
| 기준일 | 2026-09-01 |
| 대상 | 프로젝트별 단일 노드 ThreadHub 신규 설치와 지원되는 기존 설치 |
| 운영 환경 | Ubuntu 24.04 LTS AMD64, 2 OCPU, 16GB RAM, 50GB 이상 Boot Volume |
| 데이터 저장 | `/srv/threadhub` 명시적 bind mount |
| 원격 백업 위치 | `ap-singapore-1`의 프로젝트별 전용 비공개 OCI Object Storage 버킷 |
| 목표 RPO | 최대 24시간 |
| 목표 RTO | 수동 복구 4시간 이내 |
| 허용 중단 | 매일 백업 시 5분 이내 |

## 2. 목적

ThreadHub의 PostgreSQL 데이터, Mattermost 첨부파일과 notifier queue를 프로젝트 VM과
분리된 Object Storage에 보관하고, 폐기 가능한 새 VM에서 반복 가능하게 복구한다.
현재의 단일 VM 배포 모델과 무료 Mattermost Team Edition 범위는 유지한다.

이 설계가 보장하는 것은 최근 성공 백업까지의 수동 복구 경로다. 무중단 백업,
고가용성, 자동 장애조치, 시점 복구, 다른 리전 복제와 법적 보존은 보장하지 않는다.

여기서 "지원되는 기존 설치"는 이 저장소의 기본 Compose와 표준
`THREADHUB_DATA_ROOT=/srv/threadhub` 계약으로 배포된 인스턴스를 뜻한다. 임의의 외부
Mattermost나 `existing-notifier` 채택 경로는 데이터 위치와 운영 책임이 다르므로 MVP
백업 자동화 대상이 아니다.

## 3. 확정 요구사항

- 매일 새벽 애플리케이션 정합성 백업을 실행한다.
- Mattermost와 notifier의 중단은 5분 이내를 목표로 한다.
- 최근 일일 백업은 7일, 매주 일요일 백업은 4주 보관한다.
- 백업은 `ap-singapore-1`의 프로젝트별 전용 Object Storage 버킷에 저장한다.
- VM은 사용자 API 키가 아니라 Instance Principal로 Object Storage에 접근한다.
- Object Storage 기본 AES-256 서버 암호화와 HTTPS/TLS를 사용한다.
- Object Storage 버킷은 Public Access를 차단한다.
- VM에는 정확한 프로젝트 버킷의 객체 생성·조회 권한만 부여하고 삭제 권한을 주지
  않는다.
- Dynamic Group, IAM Policy와 Object Storage Lifecycle 서비스 권한은 리전에
  종속되지 않는 IAM 변경이므로 실행 직전 별도 명시적 승인을 받는다.
- 실제 OCI 작업은 지정 compartment에서만 수행하며 다른 리전은 사용하지 않는다.
- 복구는 새 VM의 비어 있는 데이터 경로에서만 허용한다.
- 운영 중인 `/srv/threadhub`에 덮어쓰는 복구 기능과 `--force` 우회 옵션은 제공하지
  않는다.

RPO는 마지막으로 Object Storage 원격 검증까지 성공한 backup set의 생성시각을
기준으로 계산한다. RTO는 복구 결정을 내리고 필요한 OCI 권한과 백업 ID가 준비된
시점부터 새 도메인의 HTTPS 인수시험 완료까지로 측정하며, 사용자 승인 대기시간은
제외한다. 백업 중단시간은 Mattermost 정지 시작부터 재시작 후 health 성공까지다.

## 4. 범위

### 4.1 백업 포함 범위

- Mattermost 애플리케이션 데이터가 저장된 PostgreSQL 데이터베이스의 custom-format
  논리 dump
- `/srv/threadhub/mattermost/data` 첨부파일 트리
- `/srv/threadhub/notifier/mailer/queue.db`와 존재하는 SQLite sidecar
- 백업 ID, 생성시각, source Git commit, 고정 이미지 버전·Digest, artifact 크기와
  SHA-256을 기록한 manifest
- notifier 버전과 검증된 Mailer image ID를 기록한 복구 호환성 메타데이터
- 도메인이나 OCI 식별자를 사용하지 않는 비밀정보 없는 복구 메타데이터

PostgreSQL role과 비밀번호는 새 `deploy/.env`에서 다시 생성한다. 논리 dump는 소유권과
ACL을 새 환경에 강제하지 않도록 생성한다.

### 4.2 제외 범위

- `deploy/.env`, SMTP 비밀번호와 notifier HMAC secret
- OCI 사용자 API key와 `~/.oci/config`
- TLS 개인키와 인증서 원본
- PostgreSQL 원시 데이터 디렉터리
- Mattermost와 NGINX 로그
- Docker 이미지, 실행 컨테이너와 Docker build cache
- Git에서 재생성하는 플러그인 bundle과 client plugin 파일
- 재생성 가능한 Bleve 검색 인덱스
- OS, NGINX, Certbot, DNS, 공인 IP, NSG와 SSH 설정의 이미지 백업

복구 시 새 `.env`, SMTP Credential과 HMAC secret을 생성한다. TLS 인증서는 새 도메인
검증 후 다시 발급한다.

## 5. 검토한 접근법

### 5.1 애플리케이션 정합성 백업

Mattermost와 notifier를 잠시 중지하고 PostgreSQL 논리 dump, 첨부파일과 queue snapshot을
같은 백업 ID로 생성한다. PostgreSQL은 실행 상태로 유지하되 애플리케이션 작성자를
제거한다. 이식성과 데이터 경계가 명확하고 실제 복구시험이 가능하므로 채택한다.

### 5.2 무중단 온라인 백업

서비스를 운영한 채 `pg_dump`와 파일 복사를 병렬로 수행하면 중단은 없지만 백업 도중
생성·삭제된 파일과 데이터베이스 행의 시점이 어긋날 수 있다. 50명 이하 단일 노드
MVP에서는 복잡성 대비 이점이 작아 채택하지 않는다.

### 5.3 Boot Volume 백업 중심

VM 전체 복원에는 편리하지만 인스턴스 구조에 종속되고 개별 데이터 검증과 새 환경
이식성이 떨어진다. 향후 보조 수단으로 검토하되 주 백업으로 사용하지 않는다.

## 6. 아키텍처

```text
systemd timer
      |
      v
threadhub-backup.sh
      |
      +-- 중복 실행 잠금과 사전점검
      +-- Mattermost/notifier 정지
      +-- PostgreSQL dump와 파일 snapshot
      +-- Mattermost/notifier 재시작·health 확인
      +-- manifest·SHA-256 생성
      +-- Instance Principal 업로드·원격 검증
      |
      v
OCI Object Storage private project bucket
      +-- daily/YYYY/MM/DD/BACKUP_ID/
      +-- weekly/YYYY/MM/DD/BACKUP_ID/
```

Object Storage 업로드는 서비스 재시작 뒤 수행하여 네트워크 속도가 중단시간을 늘리지
않게 한다. 일요일 KST 실행의 검증된 동일 backup set은 `daily/`와 `weekly/`에 각각
저장한다.
Object key는 UTC timestamp와 random backup ID만 사용하며 도메인, 프로젝트명, 이메일,
Team, 채널과 파일명을 포함하지 않는다.

## 7. 구성요소와 책임

### 7.1 `backup-common.sh`

- `deploy/.env`, `backup.env`와 `versions.env`를 출력 없이 검증
- 안전한 경로, 일반 파일, owner, mode와 symlink 경계 검증
- Compose 호출, OCI CLI 호출, 상태 원자 갱신과 공통 오류 분류
- 로그 redaction과 stable exit code 제공

### 7.2 `backup.sh`

- `flock` 기반 단일 실행 보장
- 사전점검, 정지, snapshot, 재시작, 업로드와 검증의 전체 orchestration
- 모든 종료 경로에서 서비스 복구를 시도하는 trap
- `--resume-upload BACKUP_ID`를 통한 완성된 로컬 backup set 재업로드
- 성공한 원격 검증 뒤에만 `latest-success.json` 갱신

### 7.3 `backup-status.sh`

다음 개인정보 비포함 상태만 표시한다.

```text
status
phase
backup_id
started_at
completed_at
service_downtime_seconds
local_bundle_bytes
uploaded_object_count
verification_result
failure_class
```

버킷명, Object key, 도메인, 이메일, 사용자, 채널, 메시지, 파일명, 비밀값과 OCI OCID는
표시하지 않는다. 마지막 성공이 24시간을 초과하면 비정상 exit code를 반환한다.

### 7.4 `restore.sh`

- manifest와 모든 artifact checksum 검증
- source Git commit과 Mattermost·PostgreSQL 이미지 기준 일치 확인
- 비어 있는 `THREADHUB_DATA_ROOT`만 허용
- PostgreSQL 논리 restore와 Mattermost data 권한 정상화
- notifier delivery가 disabled인 control state로 서비스 시작
- queue는 기본 격리하고 별도 명시적 승인 없이는 live path에 연결하지 않음

### 7.5 systemd 단위

- `threadhub-backup.service`: root로 실행하되 restrictive umask와 명시적 writable path를
  사용하고 동시 실행을 거부
- `threadhub-backup.timer`: Asia/Seoul 새벽 03:00, `Persistent=true`
- 설치기는 unit을 등록하지만 실제 운영 timer 활성화는 전체 인수시험 뒤 수행

### 7.6 구성과 문서

- `deploy/backup.env.example`: region, namespace, bucket, schedule, alert recipient와
  비밀정보가 아닌 정책값
- 실제 `/etc/threadhub/backup.env`: root-owned mode `0600`, Git 제외
- `deploy/docs/backup-restore.md`: OCI 준비, 수동 실행, timer, 상태, 복구와 실패 대응
- 운영 점검표, 빠른 설치 가이드, 프로젝트 종료 문서와 agent 설치 계약 갱신

## 8. Backup Set 형식

로컬 staging root는 `/var/lib/threadhub-backup/staging`이며 root-owned mode `0700`으로
관리한다. 하위 디렉터리는 mode `0700`, 모든 artifact와 상태파일은 mode `0600`으로
생성한다. 각 backup set은 다음 artifact를 가진다.

```text
BACKUP_ID/
├── database.dump
├── mattermost-data.tar.zst
├── notifier-queue.tar.zst
├── manifest.json
└── manifest.sha256
```

`manifest.json`은 artifact별 상대경로, byte size와 SHA-256, source commit,
Mattermost/PostgreSQL image repository·tag·Digest, notifier version·Mailer image ID,
schema version과 생성시각만 기록한다.
원본 도메인, bucket, compartment, instance, 사용자와 파일 목록은 기록하지 않는다.

`manifest.sha256`은 manifest 자체를 검증한다. 복구는 manifest hash를 먼저 확인한 뒤
각 artifact의 SHA-256과 archive entry를 확인한다. 절대경로, `..`, device entry 또는
허용되지 않은 symlink가 있는 archive는 압축 해제 전에 거부한다.

## 9. 백업 실행 흐름

1. restrictive `umask 077`과 non-blocking lock을 설정한다.
2. 실제 env를 출력하지 않고 구성, 파일 권한과 고정 버전을 검증한다.
3. health, 예상 staging 용량, OCI namespace·bucket 조회와 Instance Principal 인증을
   확인한다.
4. 사전점검 실패 시 서비스를 중지하지 않고 실패 상태와 일반 이메일을 기록한다.
5. Compose service `mattermost`와 `threadhub-mailer`를 정상 종료한다. PostgreSQL은 계속
   실행한다.
6. `pg_dump` custom format을 owner·ACL 비종속 옵션으로 생성한다.
7. Mattermost data와 notifier queue를 별도 `tar.zst`로 생성한다.
8. snapshot이 완성되면 `threadhub-mailer`와 `mattermost`를 즉시 재시작한다.
9. `health-check.sh`로 Mattermost, PostgreSQL과 Mailer 상태를 확인한다.
10. artifact SHA-256, manifest와 manifest hash를 생성한다.
11. 고유 Object key와 conditional create(`If-None-Match: *`)로 daily prefix에
    업로드하고 일요일 KST에는 weekly prefix에도 업로드한다. 같은 key가 이미 있으면
    덮어쓰지 않고 실패한다.
12. OCI upload integrity 결과, remote object 존재, byte size와 checksum metadata를
    확인한다. 전체 SHA-256은 복구 다운로드 시 다시 검증한다.
13. 모든 원격 검증이 성공한 뒤 `latest-success.json`을 원자적으로 갱신한다.
14. 성공한 staging set을 제거한다. 실패 set은 mode `0700` 아래 최대 24시간 보존한다.

## 10. 실패 처리와 가용성

### 10.1 사전점검 실패

서비스를 변경하지 않는다. stable failure class를 기록하고 일반 실패 메일을 한 번
시도한다.

### 10.2 snapshot 실패

불완전한 backup set은 업로드하지 않는다. trap이 Mattermost와 Mailer를 재시작하고
health를 확인한다. 재시작 실패는 snapshot 실패보다 높은 우선순위의 service recovery
오류로 기록한다.

### 10.3 서비스 재시작 실패

제한된 횟수로 재시작과 health를 재시도한다. 완성된 local set은 보존할 수 있지만
`latest-success`를 갱신하지 않는다. 서비스 장애와 백업 artifact 상태를 별도 field로
기록한다.

### 10.4 업로드 또는 원격 검증 실패

서비스는 이미 재개된 상태를 유지한다. 완성된 local set을 24시간 보존하고
`--resume-upload`만 허용한다. resume은 artifact를 다시 만들거나 서비스 중단을
유발하지 않는다.

### 10.5 다음 예약 실행

이전 실패가 있어도 새 backup ID로 독립 실행한다. 24시간이 지난 실패 staging은
성공 set과 경로·상태를 확인한 뒤 정리한다. 원격 객체는 VM이 삭제하지 않는다.

## 11. 실패 알림과 관측성

기존 OCI Email Delivery SMTP를 사용해 `BACKUP_ALERT_EMAIL`에 다음과 같은 일반 실패
메일을 한 번 발송한다.

> ThreadHub 자동 백업이 실패했습니다. 서버에서 backup-status를 확인해 주세요.

제목에는 failure class만 포함할 수 있으며 프로젝트명, 도메인과 데이터 내용은 넣지
않는다. SMTP 비밀번호는 기존 `deploy/.env`에서 안전하게 읽고 명령행, process list,
stdout, stderr와 상태파일에 노출하지 않는다. SMTP 실패는 원래 실패를 덮어쓰지 않고
`alert_delivery=failed`만 기록한다.

운영자는 첫 7일 동안 매일, 안정화 후 매주 다음을 확인한다.

- timer와 마지막 service 실행 결과
- `backup-status.sh`의 마지막 성공시각이 24시간 이내인지
- local staging 실패 set과 사용량
- Object Storage의 daily·weekly 개수와 lifecycle 결과
- 실패 이메일 발송 결과

## 12. OCI 보안 모델

### 12.1 버킷

- `ap-singapore-1`의 대상 compartment에 프로젝트별 전용 Standard bucket 생성
- Public Access 금지
- Oracle-managed key를 사용하는 기본 AES-256 server-side encryption
- versioning 비활성
- unique object name을 사용해 overwrite 금지
- daily object는 7일, weekly object는 28일 뒤 lifecycle 삭제
- uncommitted multipart upload 정리 규칙 추가

Object Lifecycle Management는 best-effort로 실행되므로 정확한 삭제 시각을 가용성
조건으로 사용하지 않는다. 보관 개수는 운영 상태에서 별도로 점검한다.

### 12.2 Instance Principal

Dynamic Group은 정확한 백업 대상 Compute instance OCID만 일치시킨다. compartment의
모든 instance를 포괄하는 matching rule은 사용하지 않는다. 정책은 exact bucket에 대해
다음 권한만 제공한다.

- bucket inspect/read
- object create
- object inspect/list
- object read

VM에는 object delete, object version delete, bucket update와 bucket delete를 허용하지
않는다. 다른 프로젝트 버킷 접근이 실제로 거부되는지 cross-bucket 시험으로 확인한다.

Lifecycle delete는 Object Storage regional service principal에만 별도 허용한다.
Dynamic Group과 IAM Policy는 tenancy-level 또는 리전에 종속되지 않는 변경이므로 실제
생성·수정·삭제마다 사용자 명시적 승인을 요구한다.

## 13. 복구 흐름

1. 요구 사양을 충족하는 새 Ubuntu 24.04 AMD64 VM을 준비한다.
2. 저장소를 clone하고 backup manifest의 source commit을 checkout한다.
3. `validate.sh`를 실행한다.
4. `setup-wizard.sh --configure-only`로 새 도메인, DB 비밀번호, SMTP Credential과 HMAC
   secret을 안전하게 입력한다.
5. `restore.sh BACKUP_ID`가 Object Storage에서 backup set을 내려받는다.
6. manifest hash, artifact SHA-256, size, schema와 고정 이미지 버전을 검증한다.
7. `THREADHUB_DATA_ROOT`가 존재하지 않거나 비어 있는 일반 디렉터리인지 확인한다.
8. PostgreSQL만 시작하고 빈 database가 healthy인지 확인한다.
9. logical dump를 restore한다.
10. Mattermost data archive를 풀고 UID/GID와 mode를 현재 고정 이미지 기준으로
    정상화한다.
11. notifier queue archive는 격리된 restore staging에 유지한다.
12. disabled notifier control state를 만든 뒤 전체 Compose를 시작한다.
13. health와 readiness를 확인하고 수동 데이터 인수시험을 수행한다.
14. queue 재사용이 별도로 승인된 경우에만 queue 내용을 검토하고 live path 연결과
    delivery 재활성화를 독립 작업으로 수행한다.
15. 모든 인수시험이 끝난 뒤에만 DNS를 새 VM으로 전환한다.

복구 스크립트는 DNS, 예약 공인 IP, NSG, SMTP, IAM, Approved Sender와 인증서를 생성,
변경 또는 삭제하지 않는다. 이 작업들은 대상 compartment와 `ap-singapore-1`을 명시한
별도 승인 단계다.

## 14. 복구 안전장치

- 기존 데이터가 하나라도 있는 target root는 즉시 거부
- `--force`, 자동 삭제와 자동 in-place restore 미제공
- version 또는 schema 불일치 시 자동 migration 미수행
- checksum 또는 archive path 검증 실패 시 추출 전 종료
- 원격 원본 backup set의 수정·삭제 금지
- notifier delivery 기본 비활성
- 복구 성공과 DNS 전환 분리
- 실패 시 새 target의 부분 데이터를 자동 삭제하지 않고 exact path와 안전한 수동 정리
  절차만 출력

## 15. 시험 전략

### 15.1 정적·계약 시험

- Bash syntax와 ShellCheck
- `backup.env` 필수값, duplicate key, symlink, owner와 mode 거부
- Compose와 env 비밀값이 명령행과 출력에 나타나지 않음
- systemd service와 timer 정적 검증
- status와 manifest 개인정보 금지 field 검사
- exact-bucket, no-delete IAM 문서 계약 검사
- lifecycle daily·weekly prefix와 보관일 계약 검사

### 15.2 fault-injection 시험

- lock 중복 실행 거부
- preflight 실패 시 service stop 미호출
- dump, archive와 manifest 실패 뒤 서비스 재시작
- restart 실패의 우선순위와 반복 제한
- upload 실패 뒤 local set 보존
- resume upload가 새 snapshot과 서비스 중단을 수행하지 않음
- remote size·metadata mismatch 거부
- 실패 이메일의 본문·제목과 로그가 privacy-safe임
- SMTP 실패가 원래 backup failure를 덮어쓰지 않음

### 15.3 실제 이미지 통합시험

Mattermost Team Edition 11.7.7과 PostgreSQL 18.4 격리 Compose fixture에서 다음을
검증한다.

1. 사용자, Team, 공개·비공개 채널, 메시지, 스레드와 첨부파일 생성
2. notifier queue 생성
3. application-consistent backup 실행
4. 별도 empty data root에 restore
5. 계정, Team, 채널, 메시지, 스레드와 파일 비교
6. source data hash 불변 확인
7. notifier delivery disabled와 오래된 이메일 미발송 확인
8. 손상 artifact, 잘못된 manifest와 version mismatch 거부

OCI는 deterministic stub을 사용해 명령, auth mode, region, bucket scope와 privacy를
검증한다. 실제 OCI 자격 증명과 운영 데이터는 CI에 제공하지 않는다.

### 15.4 OCI 라이브 인수시험

별도 승인 후 다음을 비공개 운영 기록으로 남긴다.

- exact instance Instance Principal 성공
- exact project bucket upload, list, head와 download 성공
- 다른 bucket 접근 거부
- object와 bucket 삭제 거부
- Public Access 차단
- upload integrity, byte size와 metadata 검증
- 폐기 가능한 객체의 daily·weekly lifecycle 검증
- 실패 이메일 수신
- 새 폐기 가능 VM의 실제 복구
- 서비스 중단 5분 이내
- 수동 RTO 4시간 이내

## 16. 운영 적용 조건

다음 조건을 모두 충족하기 전에는 운영 timer를 활성화하지 않는다.

1. 저장소 정적·fault-injection·실제 이미지 CI 통과
2. OCI 최소권한과 cross-bucket 거부 시험 통과
3. 첫 수동 backup set의 원격 검증 통과
4. 폐기 가능한 새 VM 복구시험 통과
5. notifier queue 기본 격리와 오래된 알림 미발송 확인
6. 관리자 실패 이메일 수신 확인
7. 문서, 운영 점검표와 프로젝트 종료 절차 검토 완료

운영 적용 뒤 첫 7일은 매일 확인하고 그 뒤 주간 점검으로 전환한다. 마지막 성공이
24시간을 넘으면 백업 보호가 비정상인 것으로 판정한다.

## 17. 프로젝트 종료

프로젝트 종료 시 보존 또는 완전 삭제를 명시적으로 선택한다.

- 기록 유지: VM 종료와 무관하게 승인된 기간 동안 backup set을 보존한다.
- 완전 삭제: notifier queue close gate를 먼저 통과하고, 백업 보존 책임자의 승인을
  받은 뒤 project bucket과 IAM 자원을 별도 절차로 삭제한다.
- Lifecycle만으로 즉시 삭제 완료를 주장하지 않는다.
- 공유 DNS zone, Email Domain, DKIM과 SPF는 프로젝트 버킷 삭제 범위가 아니다.

## 18. 완료 조건

1. 새 설치와 지원되는 기존 설치 모두 동일한 backup contract를 사용한다.
2. 자동 백업은 서비스 중단 5분 이내와 RPO 24시간을 충족한다.
3. backup set은 PostgreSQL, Mattermost data와 notifier queue를 같은 backup ID로
   보존한다.
4. 성공 상태는 원격 업로드와 검증 뒤에만 기록된다.
5. VM은 프로젝트 버킷의 생성·조회만 가능하고 삭제할 수 없다.
6. backup과 restore 출력에 비밀값과 고객 식별정보가 없다.
7. 복구는 empty target에서만 가능하고 운영 데이터를 덮어쓰지 않는다.
8. 복구된 notifier는 기본 disabled이며 과거 알림을 자동 발송하지 않는다.
9. 새 VM 복구시험이 계정, 채널, 메시지, 스레드와 첨부파일을 확인한다.
10. 실제 OCI·IAM·DNS·운영 timer 변경은 각각 필요한 명시적 승인 뒤 수행한다.

## 19. 공식 근거

- [Oracle Cloud Infrastructure: Calling Services from an Instance](https://docs.oracle.com/en-us/iaas/Content/Identity/Tasks/callingservicesfrominstances.htm)
- [Oracle Cloud Infrastructure: Details for Object Storage and Archive Storage](https://docs.oracle.com/en-us/iaas/Content/Identity/Reference/objectstoragepolicyreference.htm)
- [Oracle Cloud Infrastructure: Object Storage Data Encryption](https://docs.oracle.com/en-us/iaas/Content/Object/Tasks/encryption.htm)
- [Oracle Cloud Infrastructure: Object Storage Lifecycle Management](https://docs.oracle.com/en-us/iaas/Content/Object/Tasks/usinglifecyclepolicies.htm)
