# ThreadHub 프로젝트 종료 절차

## 1. 종료 방식 결정

프로젝트 책임자는 다음 중 하나를 선택하고 기록합니다.

- 기록 유지: VM 또는 Boot Volume 유지
- 완전 폐기: VM과 Boot Volume 삭제

어느 방식도 별도 백업이나 복구 보장을 의미하지 않습니다.

## 2. 공통 절차

1. 종료 대상 프로젝트명과 정보 공유 경계를 확인합니다.
2. 고객에게 종료 일정과 접속 종료 시점을 안내합니다.
3. 최종 논의와 필요한 자료를 확인합니다.
4. 고객 사용자를 Team에서 제거하고 계정을 비활성화합니다.
5. SMTP·DNS·공인 IP와 인스턴스 식별정보를 기록합니다.

알림을 먼저 중지하고 `./deploy/scripts/notifier-control.sh drain`으로 새 수집만 막은
뒤 최대 10분간 큐를 처리합니다. 잔여 실패·재시도 항목은
[운영 점검표](./operations-checklist.md)의 retry/cancel 순서로 처리합니다.

## 3. 기록 유지

1. 프로젝트 채널을 보관합니다.
2. 기존 메시지와 파일을 열람할 수 있는지 확인합니다.
3. 고객 계정의 로그인이 차단되는지 확인합니다.
4. 유지할 VM 또는 Boot Volume과 비용 책임자를 기록합니다.
5. 유지 중에도 장애 복구가 보장되지 않음을 기록합니다.

## 4. 컨테이너만 중지

```bash
./deploy/scripts/destroy.sh --confirm-stop
```

이 명령은 `docker compose down --remove-orphans`만 실행합니다. `/srv/threadhub`의 bind mount 데이터는 삭제하지 않으며 `down -v`를 사용하지 않습니다.

## 5. 완전 폐기

완전 폐기는 OCI에서 수행하는 별도의 파괴적 작업입니다.

1. notifier queue를 cancel하여 email scrub을 확인합니다.
2. 프로젝트 SMTP Credential을 삭제합니다.
3. exact project Approved Sender를 삭제합니다.
4. IAM membership/user/policy/group을 순서대로 제거합니다.
5. project A record만 제거합니다.
6. 정확한 OCI 인스턴스 OCID와 Boot Volume OCID를 재확인합니다.
7. OCI Compute VM을 삭제합니다.
8. Boot Volume 삭제 옵션과 실제 결과를 확인합니다.
9. 예약 공인 IP를 해제하거나 다음 프로젝트용으로 재지정합니다.

공유 Email Domain/DKIM/SPF/DNS zone은 별도 영향분석과 명시적 승인 없이는 삭제하지
않습니다. IAM user/group/policy 또는 SMTP Credential은 tenancy-wide 영향을 줄 수
있으므로 생성·교체·삭제마다 명시적 승인이 필요하며, Approved Sender와 DNS 변경에는
target Compartment와 region을 기록합니다. 상세 격리 정책은
[OCI Email Delivery 설정](./oci-email-delivery.md)을 따릅니다.

완전 폐기 후 PostgreSQL, 메시지와 첨부파일은 복구되지 않습니다.

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

실제 값이 입력된 종료 기록은 공개 GitHub 저장소에 커밋하지 않습니다.
