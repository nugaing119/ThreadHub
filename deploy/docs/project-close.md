# ThreadHub 프로젝트 종료 절차

## 1. 종료 방식 결정

프로젝트 책임자는 다음 중 하나를 선택하고 기록합니다.

- 기록 유지: VM 또는 Boot Volume과 승인된 Object Storage 백업 유지
- 완전 폐기: VM, Boot Volume과 승인된 백업 리소스 삭제

백업을 활성화한 경우에도 RPO 24시간·수동 RTO 4시간 목표이며 HA·PITR·복구시간
SLA를 의미하지 않습니다.

## 2. 공통 절차

1. 종료 대상 프로젝트명과 정보 공유 경계를 확인합니다.
2. 고객에게 종료 일정과 접속 종료 시점을 안내합니다.
3. 최종 논의와 필요한 자료를 확인합니다.
4. 고객 사용자를 Team에서 제거하고 계정을 비활성화합니다.
5. SMTP·DNS·공인 IP와 인스턴스 식별정보를 기록합니다.

### notifier 종료 gate

1. `./deploy/scripts/notifier-control.sh drain`으로 새 수집을 중지하고 delivery-enabled drain mode를 유지합니다.
2. delivery_enabled=true인 동안 필요한 `threadhub-mailer retry-failed` remediation을 마친 뒤 `pending=0`과 `sending=0`을 확인합니다.
3. `threadhub-mailer cancel-failed`는 남은 `failed_permanent`와 `failed_exhausted`를 한 트랜잭션에서 취소하고 두 상태의 수신자 주소와 lease를 scrub합니다. 그 뒤 `failed=0`을 확인합니다.
4. pending=0, sending=0, failed=0이면 `./deploy/scripts/notifier-control.sh disable`을 실행하고 `delivery_enabled=false`를 확인합니다.
5. pending, sending, failed 중 **하나라도 0이 아니면** (ANY of pending, sending, or failed is nonzero) close를 중지합니다. project close is blocked이며, 원인을 복구하거나 운영 책임자에게 escalate합니다. 이 상태에서는 SMTP Credential, IAM, Approved Sender, DNS 또는 VM 삭제를 진행하지 않습니다.

`cancel-failed`는 pending/sending을 취소하거나 scrub하지 않습니다. 따라서 0 queue gate를
통과하기 전에는 전체 email scrub을 주장할 수 없습니다.

queue backup 범위는 `queue.db`와 SQLite sidecar뿐이지만 recipient addresses를 포함할 수
있습니다. backup은 비공개·보호된 저장소에 보관하고 종료 결정에 따라 securely removed
합니다. 원시 backup이 남아 있으면 email scrub 완료라고 기록하지 않습니다. 정확한
retry/cancel 명령은 [운영 점검표](./operations-checklist.md)를 따릅니다.

### 백업 보존·삭제 gate

1. 위 notifier 종료 gate를 먼저 통과합니다.
2. 마지막 수동 백업을 실행하고 원격 검증 성공을 확인합니다.
3. [백업 및 복구 운영 가이드](./backup-restore.md)의 보존 또는 완전 삭제 중 하나를 선택합니다.
4. 보존 기간, 책임자, 버킷과 복구 접근 경로를 비공개 종료 기록에 남깁니다.
5. 삭제는 대상 compartment와 `ap-singapore-1`을 다시 확인하고 explicit user authorization을 받은 뒤 진행합니다.
6. Object Storage 객체·lifecycle·IAM·Dynamic Group·버킷은 다른 프로젝트와 공유 여부를 확인한 뒤 별도 관리자 절차로 제거합니다.

## 3. 기록 유지

1. 프로젝트 채널을 보관합니다.
2. 기존 메시지와 파일을 열람할 수 있는지 확인합니다.
3. 고객 계정의 로그인이 차단되는지 확인합니다.
4. 유지할 VM 또는 Boot Volume과 비용 책임자를 기록합니다.
5. 마지막 검증 성공 시각, RPO·RTO 목표와 복구 제한을 기록합니다.

## 4. 컨테이너만 중지

```bash
./deploy/scripts/destroy.sh --confirm-stop
```

이 명령은 `docker compose down --remove-orphans`만 실행합니다. `/srv/threadhub`의 bind mount 데이터는 삭제하지 않으며 `down -v`를 사용하지 않습니다.

## 5. 완전 폐기

완전 폐기는 OCI에서 수행하는 별도의 파괴적 작업입니다.

1. `pending=0`, `sending=0`, `failed=0`, `delivery_enabled=false` close gate와 `failed_permanent` 및 `failed_exhausted` cancel/scrub 결과를 확인합니다.
2. 보호된 queue backup의 보존 또는 securely removed 결정을 기록합니다.
3. 마지막 수동 백업과 원격 5개 객체 검증이 성공했는지 확인합니다.
4. 공유 Dynamic Group exception을 사용했다면 종료 프로젝트의 정확한 VM·복구 VM
   OCID clause만 제거하고, 다른 프로젝트 clause가 변경되지 않았는지 비교합니다.
   전용 Dynamic Group이면 관련 project policy 제거 뒤 그룹을 삭제합니다.
5. 프로젝트 SMTP Credential을 삭제합니다.
6. exact project Approved Sender를 삭제합니다.
7. 전용 IAM membership과 user를 제거한 뒤 SMTP policy와 전용 group을 삭제합니다.
8. project A record의 현재 값이 종료 VM의 공인 IP와 일치하는지 확인하고 해당
   `A` RRset만 제거합니다.
9. 정확한 OCI 인스턴스 OCID와 Boot Volume OCID를 재확인합니다.
10. OCI Compute VM을 Boot Volume 보존 없이 삭제하고 두 lifecycle state가 모두
    `TERMINATED`인지 확인합니다.
11. 예약 공인 IP가 VM에서 분리됐는지 확인한 뒤 해제하거나, 명시적으로 승인된 다음
    프로젝트용으로만 재지정합니다.
12. 프로젝트 전용 NSG가 다른 VNIC에 연결되지 않았는지 확인한 뒤 삭제합니다. 공유
    VCN, subnet, Security List 또는 NSG는 삭제하지 않습니다.
13. 완전 삭제를 선택한 백업 버킷의 object lifecycle policy를 먼저 삭제해 새 lifecycle
    작업을 중지합니다.
14. daily·weekly 객체, object version과 미완료 multipart upload를 제거하고
    버킷이 비었는지 확인한 뒤 exact project bucket을 삭제합니다.
15. 프로젝트 전용 backup Instance Principal policy와 lifecycle service policy를
    삭제합니다. 공유 Dynamic Group 자체와 다른 프로젝트 policy는 삭제하지 않습니다.
16. exact 이름·OCID 조회로 프로젝트 IAM user/group/policy, SMTP Credential,
    Approved Sender, DNS RRset, bucket, 공인 IP와 NSG가 0건인지 확인합니다.
17. 공유 Dynamic Group의 기존 clause, 기존 운영 VM의 `RUNNING` 상태와 운영 HTTPS
    응답을 다시 확인합니다.

공유 Email Domain/DKIM/SPF/DNS zone은 별도 영향분석과 명시적 승인 없이는 삭제하지
않습니다. IAM user/group/policy 또는 SMTP Credential은 tenancy-wide 영향을 줄 수
있으므로 생성·교체·삭제마다 명시적 승인이 필요하며, Approved Sender와 DNS 변경에는
target Compartment와 region을 기록합니다. 상세 격리 정책은
[OCI Email Delivery 설정](./oci-email-delivery.md)을 따릅니다.

완전 폐기 후 PostgreSQL, 메시지, 첨부파일과 Object Storage 백업은 복구되지 않습니다.

## 6. 종료 기록

| 항목 | 기록값 |
| --- | --- |
| 프로젝트명 |  |
| 도메인 |  |
| OCI 인스턴스 OCID |  |
| Boot Volume OCID |  |
| 종료 방식 | 기록 유지 / 완전 폐기 |
| 실행자 |  |
| 실행 일시 |  |
| DNS 결과 |  |
| SMTP Credentials 결과 |  |
| VM 결과 |  |
| Boot Volume 결과 |  |
| 공인 IP 결과 |  |
| 마지막 원격 검증 성공 |  |
| 백업 보존 또는 삭제 |  |
| Object Storage 결과 |  |
| Dynamic Group·IAM 결과 |  |

실제 값이 입력된 종료 기록은 공개 GitHub 저장소에 커밋하지 않습니다.
