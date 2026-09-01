# ThreadHub 백업 및 복구 운영 가이드

이 문서는 ThreadHub의 일일 OCI Object Storage 백업, 검증, 신규 VM 복구와
예약 활성화 절차의 단일 운영 기준이다. 저장소 구현 작업만으로는 실제 OCI나
운영 VM 변경 권한이 부여되지 않는다.

## 1. 범위와 보장

ThreadHub 백업 기준은 다음과 같다.

- RPO 목표: 마지막 원격 검증 성공으로부터 최대 24시간
- 수동 복구 RTO 목표: 4시간
- 백업 중 Mattermost와 Mailer 쓰기 중단 목표: 최대 5분
- 백업 대상: PostgreSQL 논리 덤프, Mattermost 첨부파일, notifier SQLite 큐
- 백업 세트: `database.dump`, `mattermost-data.tar.zst`,
  `notifier-queue.tar.zst`, `manifest.json`, `manifest.sha256`
- 복구 방식: 동일 커밋·동일 고정 이미지의 새 VM에 수동 복구

이 구성은 HA, 무중단 백업, PITR, 리전 간 복제 또는 재해 자동 전환을 제공하지
않는다. 마지막 성공 백업 이후의 데이터와 백업 중 새로 유입된 데이터는 복구되지
않을 수 있다. 상태 파일만 성공이어서는 충분하지 않으며, 원격 Object Storage의
정확한 5개 객체가 크기와 SHA-256 검증을 통과해야 성공이다.

## 2. OCI 선행 조건

프로젝트별로 Public Access가 차단된 전용 버킷을 `ap-singapore-1`에 만든다.
OCI Object Storage 기본 서버 측 AES-256 암호화를 사용하며, 공개 URL이나
Pre-Authenticated Request를 만들지 않는다. VM은 Instance Principal로만
접근한다.

Dynamic Group은 정확한 프로젝트 VM 한 대만 일치해야 한다. 아래의 모든 값은
실제 값이 아닌 placeholder다.

```text
ALL {instance.id = '<project-threadhub-instance-ocid>'}

Allow dynamic-group '<identity-domain>'/'<project-backup-dynamic-group>' to inspect buckets in compartment <project-compartment> where target.bucket.name = '<project-backup-bucket>'
Allow dynamic-group '<identity-domain>'/'<project-backup-dynamic-group>' to manage objects in compartment <project-compartment> where all {target.bucket.name = '<project-backup-bucket>', any {request.permission = 'OBJECT_CREATE', request.permission = 'OBJECT_INSPECT', request.permission = 'OBJECT_READ'}}
```

VM 정책에는 `OBJECT_DELETE`, 버킷 생성·수정·삭제, 다른 버킷 접근 또는 다른
인스턴스 권한을 넣지 않는다. 라이브 시험에서 대상 버킷 create/inspect/read는
성공하고, 교차 버킷·객체 삭제·버킷 삭제는 거부되어야 한다.

## 3. 명시적 승인 경계

Dynamic Group, IAM policy와 같은 tenancy-wide 리소스의 생성·수정, 실제 버킷과
lifecycle policy 생성·수정, DNS, 공인 IP, Email Delivery, 운영 VM 변경에는
항상 explicit user authorization이 필요하다. 작업 전에 대상 compartment와
`ap-singapore-1` 리전을 사용자에게 명시하고 승인을 받아야 한다.

저장소의 문서·스크립트 작성, 시험 하네스 실행 또는 설치 요청은 실제 OCI 변경을
자동으로 허가하지 않는다. 다른 리전, 다른 compartment 또는 tenancy 전체 범위로
확대하지 않는다.

## 4. 보존과 lifecycle

객체 키와 보존 기준은 다음과 같다.

```text
daily/YYYY/MM/DD/BACKUP_ID/   7일
weekly/YYYY/MM/DD/BACKUP_ID/ 28일
```

일요일 백업은 `daily/`와 `weekly/`에 각각 완전한 세트를 쓴다. OCI lifecycle
rule은 해당 prefix와 기간에만 적용하며, 미완료 multipart upload도 정리한다.
Object Storage lifecycle 삭제는 best-effort이므로 운영자는 실제 객체 수와
가장 오래된 객체를 확인해야 한다.

Lifecycle service authorization은 VM의 no-delete 정책과 별개다. 실제 정책은
변경 시점의 Oracle 공식 문서를 기준으로 생성하고 검토한 뒤, 승인된 라이브
변경으로만 적용한다.

## 5. 설정 및 비활성 등록

먼저 저장소 검증을 실행한다.

```bash
./deploy/scripts/validate.sh
```

보호된 대화형 터미널에서 namespace, 정확한 프로젝트 버킷명, 장애 알림 수신
주소를 입력한다. 값은 명령행 인자로 넘기지 않는다.

```bash
sudo ./deploy/scripts/configure-backup.sh
sudo ./deploy/scripts/install-backup.sh --register
```

`configure-backup.sh`는 `/etc/threadhub/backup.env`를 root 전용 mode 0600으로
만들며 기존 파일을 덮어쓰지 않는다. `--register`는 SHA-256으로 고정한 OCI CLI,
`zstd`와 systemd unit을 설치한다. 이 시점에는 timer remains disabled 상태여야
하며, 백업이나 타이머를 자동 시작하지 않는다. 기본 설치 `[READY]`와 백업
준비 완료는 별도 gate다.

## 6. 최초 수동 백업과 검증

Instance Principal의 namespace·정확한 버킷 권한을 먼저 읽기 전용으로 확인한
뒤 최초 백업을 수동 실행한다.

```bash
sudo ./deploy/scripts/backup.sh
sudo ./deploy/scripts/backup-status.sh
sudo ./deploy/scripts/backup-status.sh --json
```

다음을 비공개 운영 증거에 기록한다.

- `status=success`, `phase=complete`, `verification_result=ok`
- `snapshot_result=ok`, `service_recovery_result=ok`, `upload_result=ok`
- `service_downtime_seconds <= 300`
- `uploaded_object_count`와 정확한 5개 daily 객체
- 일요일이면 정확한 5개 weekly 객체도 존재
- 원격 객체 크기와 `threadhub-sha256` metadata 일치
- 실패 알림에는 백업 ID·버킷·고객 데이터가 없고 일반 문구만 존재

상태 출력, 진단 파일, manifest 또는 백업 내용을 채팅·Issue·공개 CI 로그에
붙여 넣지 않는다.

## 7. 폐기 가능한 신규 VM 복구 시험

타이머 활성화 전에 운영 소스와 분리된 폐기 가능한 Ubuntu 24.04 AMD64 VM에서
복구한다. 대상은 new or empty `/srv/threadhub`여야 한다. 기존 또는 비어 있지
않은 경로에 복구하지 않으며 `--force` 우회는 없다.

1. 백업과 정확히 같은 Git commit을 checkout한다.
2. 같은 Mattermost·PostgreSQL 이미지 태그와 digest를 확인한다.
3. 새 PostgreSQL 비밀번호와 새 notifier HMAC으로 `deploy/.env`를 만든다.
4. 복구 VM 전용 Instance Principal이 같은 프로젝트 버킷을 읽을 수 있게 한다.
5. `/etc/threadhub/backup.env`를 mode 0600으로 구성한다.
6. 다음 명령으로 정확한 백업 ID를 복구한다.

```bash
sudo ./deploy/scripts/restore.sh <BACKUP_ID>
```

복구 명령은 manifest와 모든 artifact를 내려받아 검증한 뒤에만
`/srv/threadhub`를 만든다. PostgreSQL, 공개·비공개 채널, root 글, 스레드,
첨부파일을 확인한다. 소스 데이터 루트 hash는 복구 전후 동일해야 한다.

기존 notifier 큐는 live queue에 재주입하지 않고 보호된 restore state의
queue quarantine에 둔다. 새 live queue는 pending/sending/sent/failed가 모두 0이고,
`enabled=false`, `delivery_enabled=false`여야 한다. 이전 메시지의 메일이 새
SMTP 자격증명으로 발송되지 않았음을 확인한다.

## 8. 증거 검토 후 타이머 활성화

최초 원격 검증 성공과 폐기 가능한 VM 복구 증거를 사용자와 검토한 뒤에만 정확한
성공 백업 ID로 활성화한다.

```bash
sudo ./deploy/scripts/install-backup.sh --enable-after-acceptance <BACKUP_ID>
```

명령은 실제 TTY, 24시간 이내 최신 성공 상태, 동일 백업 ID의 원격 세트와
Instance Principal 접근을 다시 확인한다. 운영자가 정확히
`ENABLE BACKUP TIMER`를 입력해야 `threadhub-backup.timer`가 enable·start된다.
그 전에는 timer remains disabled다.

## 9. 정기 운영과 실패 대응

매일 다음 항목을 확인한다.

```bash
sudo ./deploy/scripts/backup-status.sh
sudo systemctl status threadhub-backup.timer --no-pager
sudo systemctl status threadhub-backup.service --no-pager
```

- 마지막 원격 검증 성공이 24시간 이내인지 확인한다.
- daily 세트가 정확히 5개인지, 일요일 weekly 세트도 5개인지 확인한다.
- `/var/lib/threadhub-backup/staging`에 실패 세트만 제한적으로 남는지 확인한다.
- 실패 이메일이 일반 문구로 도착했는지 확인한다.
- `preflight`, `snapshot`, `service_recovery`, `manifest`, `upload`,
  `remote_verify`의 안정된 failure class로 원인을 분류한다.

서비스가 정상이고 완전한 로컬 세트가 24시간 이내라면 서비스 중단 없이 업로드만
다시 시도할 수 있다.

```bash
sudo ./deploy/scripts/backup.sh --resume-upload <BACKUP_ID>
```

실패를 숨기기 위해 상태 파일을 수정하거나 타이머를 재시작하지 않는다. 최신 성공이
24시간을 넘으면 고객 파일럿을 중단하고 수동 백업·원격 검증·복구 가능성을 먼저
회복한다.

## 10. 프로젝트 종료와 삭제 승인

프로젝트 종료 전 notifier를 drain하고 pending/sending/failed를 0으로 만든 뒤
delivery를 disable한다. 그 다음 마지막 수동 백업과 원격 검증을 실행하고 다음 중
하나를 명시적으로 선택한다.

- 보존: 승인된 기간 동안 버킷과 최소 읽기 경로를 유지한다.
- 완전 삭제: 고객 보존 합의와 explicit user authorization을 받은 뒤 버킷 객체,
  lifecycle policy, Dynamic Group/IAM policy와 버킷을 정확한 순서로 제거한다.

VM의 Instance Principal 정책에는 삭제 권한이 없으므로 완전 삭제는 별도 승인된
관리자 작업이다. `destroy.sh`, VM 또는 Boot Volume 삭제가 Object Storage 백업을
암묵적으로 삭제하지 않는다. 삭제 대상 compartment, `ap-singapore-1`, 버킷명과
IAM 리소스를 다시 확인하고 다른 프로젝트 리소스는 변경하지 않는다.
