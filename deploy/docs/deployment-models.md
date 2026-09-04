# ThreadHub 배포 모델과 신규 프로젝트 표준

이 문서는 새 프로젝트를 만들 때 사용할 기준 배포 모델과 이미 운영 중인
Mattermost를 안전하게 채택하는 예외 경로를 구분한다. 두 경로는 기능 목표는 같지만
설치·데이터 경로와 운영 복잡도가 다르다.

## 1. 결정 기준

| 조건 | 선택할 모델 | 진입 문서 |
| --- | --- | --- |
| 새 VM이고 `/srv/threadhub`가 없거나 비어 있음 | **canonical fresh** | [빠른 설치](./quick-install.md) |
| 지원 조건을 만족하는 Mattermost가 이미 운영 중이며 데이터를 유지해야 함 | **existing adoption** | [기존 Mattermost notifier 적용](./existing-mattermost-notifier.md) |
| 기존 배포를 새 VM으로 교체하거나 백업에서 복구함 | canonical fresh 레이아웃으로 복구 | [백업 및 복구](./backup-restore.md) |

신규 프로젝트에는 항상 canonical fresh를 사용한다. 기존 배포를 단순히 경로 통일
목적으로 in-place layout migration하지 않는다. 기존 Team·사용자·게시물·파일을
보존해야 하는 환경은 existing adoption 상태로 운영하고, 향후 검증된 백업을 새 VM에
복구할 때 canonical fresh 레이아웃으로 수렴한다.

## 2. 두 모델의 운영 차이

| 항목 | canonical fresh | existing adoption |
| --- | --- | --- |
| 대상 | 신규 프로젝트 VM | 이미 운영 중인 지원 대상 Mattermost |
| Compose | 저장소의 단일 `deploy/docker-compose.yml` | 기존 base Compose + 검토된 override |
| 보호 설정 | 프로젝트별 `deploy/.env` | 기존 환경파일 + `deploy/existing-notifier.env` |
| 데이터 루트 | `/srv/threadhub` 아래 통합 | 기존 데이터 경로와 `/srv/threadhub-notifier` 유지 |
| notifier | 초기 배포에 포함하고 SMTP acceptance 전 disabled | preflight 후 disabled 상태로 후설치 |
| 백업 | 기본 canonical 경로 | `/etc/threadhub/backup-source.env` 어댑터 사용 |
| 복구 결과 | new or empty `/srv/threadhub` | 새 VM의 canonical fresh 레이아웃으로만 복구 |
| 운영 복잡도 | 낮음 | 별도 경로·override·rollback 증거 때문에 높음 |

existing adoption은 열등하거나 임시로 방치된 구성이라는 뜻이 아니다. 운영 데이터를
보존하면서 기능을 추가하기 위한 지원 경로다. 다만 신규 프로젝트에 동일한 복잡성을
복제하지 않는다.

## 3. canonical fresh 프로젝트 기준

새 프로젝트는 다음 기준을 하나의 배포 단위로 사용한다.

- Ubuntu 24.04 AMD64, 2 OCPU, 16GB RAM, Boot Volume 50GB 이상인 새 VM
- 정보 공유 경계당 독립 VM과 프로젝트별 hostname A 레코드
- 저장소의 고정 이미지 태그·Digest와 단일 Compose
- 프로젝트별 `deploy/.env`, PostgreSQL 비밀번호와 notifier HMAC
- 프로젝트별 SMTP IAM 사용자·그룹·Credential과 exact Approved Sender
- 프로젝트별 Public Access 차단 Object Storage 버킷, lifecycle와 최소 권한 policy
- SMTP acceptance와 allowlist 수동시험 후 전체 채널 알림 활성화
- 최초 원격 백업과 폐기 가능한 VM 복구시험 후에만 백업 timer 활성화

설치 마법사의 `[READY]`는 기본 서비스의 자동 검증 완료만 뜻한다. 받은편지함 링크,
SPF/DKIM, 권한, CJK, 모바일, notifier 수신 경계와 백업 복구는 각각의 수동 인수 gate를
완료해야 한다.

## 4. OCI 리소스 분리 기준

| 리소스 | 기준 |
| --- | --- |
| Compute VM·Boot Volume | 프로젝트별 |
| Reserved Public IP·hostname A 레코드 | 프로젝트별 |
| `deploy/.env`·DB 비밀번호·HMAC | 프로젝트별 |
| SMTP IAM 사용자·그룹·Credential | 프로젝트별 |
| Approved Sender | 프로젝트별 exact 주소 |
| 백업 버킷·lifecycle·접근 policy | 프로젝트별 |
| Email Domain·DKIM·SPF | 같은 발신 도메인과 같은 리전일 때만 공동 사용 가능 |
| DNS zone | 공동 사용 가능, 프로젝트 hostname은 별도 레코드로 추가 |
| VCN·subnet | 공동 사용 가능, 각 VM의 실제 노출 포트와 SSH source를 별도 검증 |
| Dynamic Group | 전용 사용이 기본이며, quota 제약 시 아래의 승인된 공유 예외 허용 |

공유 자원은 한 프로젝트 종료 시 다른 프로젝트가 사용 중이면 변경하거나 삭제하지
않는다. 프로젝트별 비밀값과 고객 데이터는 공유하지 않는다.

## 5. shared Dynamic Group exception

OCI quota 때문에 프로젝트별 Dynamic Group을 만들 수 없을 때만 하나의 검토된
Dynamic Group을 여러 ThreadHub 백업 VM이 공동 사용할 수 있다. 이 예외는 다음 조건을
모두 만족해야 한다.

1. matching rule은 승인된 활성 VM의 정확한 OCID만 `ANY {instance.id = ...}` 형태로
   열거한다. compartment 전체, broad tag 또는 모든 인스턴스를 포함하지 않는다.
2. 프로젝트별 IAM policy는 exact `target.bucket.name`과 exact
   `request.principal.id`를 함께 제한한다. Dynamic Group membership만으로 다른
   프로젝트 버킷에 접근할 수 없어야 한다.
3. VM에는 자기 버킷의 get/create/inspect/read만 허용하고 object delete, bucket
   변경·삭제와 다른 프로젝트 버킷 권한을 주지 않는다.
4. 신규 VM 추가나 policy 변경 때 cross-project deny matrix를 실행한다. 자기 버킷
   접근은 성공하고 다른 모든 프로젝트 버킷 접근은 거부되어야 한다.
5. 프로젝트 VM을 폐기하면 해당 instance OCID를 matching rule과 프로젝트 policy에서
   제거하고 교차 거부 시험을 다시 실행한다.

placeholder 정책 형태는 다음과 같다. 실제 이름과 OCID는 승인된 비공개 change
record에서만 대입한다.

```text
ANY {instance.id = '<project-a-instance-ocid>', instance.id = '<project-b-instance-ocid>'}

Allow dynamic-group '<identity-domain>'/'<shared-backup-dynamic-group>' to read buckets in compartment <project-compartment> where all {target.bucket.name = '<project-a-backup-bucket>', request.principal.id = '<project-a-instance-ocid>'}
Allow dynamic-group '<identity-domain>'/'<shared-backup-dynamic-group>' to manage objects in compartment <project-compartment> where all {target.bucket.name = '<project-a-backup-bucket>', request.principal.id = '<project-a-instance-ocid>', any {request.permission = 'OBJECT_CREATE', request.permission = 'OBJECT_INSPECT', request.permission = 'OBJECT_READ'}}
```

matching rule의 `ANY`·`ALL`과 `instance.id` 문법은 Oracle의
[Writing Matching Rules to Define Dynamic Groups](https://docs.oracle.com/en-us/iaas/Content/Identity/dynamicgroups/Writing_Matching_Rules_to_Define_Dynamic_Groups.htm)를,
`target.bucket.name`과 Object Storage permission은
[Details for Object Storage and Archive Storage](https://docs.oracle.com/en-us/iaas/Content/Identity/Reference/objectstoragepolicyreference.htm)를 기준으로 한다.

Dynamic Group, IAM policy와 SMTP IAM 리소스는 리전에 종속되지 않는 tenancy-wide
리소스다. 생성·수정·삭제 전에 대상 compartment와 운영 리전을 명시하고 사용자의
명시적 승인을 받는다. 실제 OCID, 버킷명과 정책 전문은 공개 저장소에 기록하지 않는다.

## 6. 신규 프로젝트 실행 순서

1. 대상 compartment, `ap-singapore-1`, 정보 공유 경계와 프로젝트 이름을 확정한다.
2. [OCI 인프라 준비](./oci-provisioning.md)에 따라 VM·네트워크·DNS를 준비한다.
3. [OCI Email Delivery 설정](./oci-email-delivery.md)에 따라 프로젝트별 발신 리소스를
   준비한다.
4. [빠른 설치](./quick-install.md)의 canonical fresh 절차를 실행한다.
5. [관리자 가이드](./admin-guide.md)의 수동 인수시험을 완료한다.
6. 백업이 필요하면 [백업 및 복구](./backup-restore.md)의 별도 승인 gate를 진행한다.

어느 단계에서도 다른 프로젝트의 `.env`, SMTP Credential, HMAC, PostgreSQL 데이터,
Mattermost data 또는 notifier queue를 복사해 사용하지 않는다.
