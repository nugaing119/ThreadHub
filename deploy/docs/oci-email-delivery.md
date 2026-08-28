# OCI Email Delivery 설정

ThreadHub는 계정 초대, 이메일 확인과 비밀번호 재설정에 OCI Email Delivery의
SMTP submission을 사용합니다. 이 작업은 Mattermost VM 설치와 별개이며 OCI
Console과 발신 도메인의 DNS 관리 권한이 필요합니다.

Oracle 공식 시작 순서는 [Email Delivery Getting Started](https://docs.oracle.com/en-us/iaas/Content/Email/Reference/gettingstarted.htm)를 기준으로 합니다.

## 1. 작업 범위와 리전

다음 값을 먼저 확정합니다.

- ThreadHub VM과 동일한 OCI region
- Email Domain과 Approved Sender를 둘 compartment
- 발신 도메인 DNS 관리자
- ThreadHub 전용 SMTP credential을 소유할 IAM 사용자

Approved Sender는 생성한 리전에만 존재하므로 Mattermost의 SMTP endpoint와
같은 리전을 사용합니다. root compartment 대신 프로젝트 compartment 사용을
권장합니다.

IAM 사용자·그룹·정책과 SMTP Credentials는 tenancy 범위에 영향을 줄 수
있습니다. 자동화 도구는 명시적 승인 없이 이를 생성하거나 변경하면 안 됩니다.

## 2. 전용 IAM 사용자와 권한

개인 Console 관리자의 SMTP credential을 재사용하지 않고 ThreadHub 발송 전용
IAM 사용자를 권장합니다. 필요한 Email Delivery 권한은 조직의 identity domain과
compartment 구조에 맞춰 최소 범위로 부여합니다.

정책 문법과 resource type은 다음 공식 문서를 사용합니다.

- [Required IAM Policy](https://docs.oracle.com/en-us/iaas/Content/Email/Tasks/managingapprovedsenders_topic-policies.htm)
- [Email Delivery Policy Reference](https://docs.oracle.com/en-us/iaas/Content/Identity/Reference/emailpolicyreference.htm)

저장소는 tenancy별 identity domain 이름과 IAM 구조를 추측해 정책을 자동 생성하지
않습니다.

project-specific IAM user/group/SMTP Credential/exact Approved Sender를 프로젝트마다
사용합니다. 다음 정책은 **그대로** 사용하되 angle-bracket 값은 사용자가 승인한
비공개 change record에서만 해석합니다. 실제 identity domain, group, Compartment,
Approved Sender OCID를 공개 저장소에 기록하지 않습니다.

```text
Allow group '<identity-domain>'/'<project-smtp-group>'
to use approved-senders
in compartment <project-compartment>
where target.approved-sender.id = '<project-approved-sender-ocid>'
```

domain-wide sender와 broad `email-family` policy는 사용하지 않습니다. 이 exact
Approved Sender IAM condition은 additive least privilege입니다. IAM 허용은 다른
group·상위 scope 정책과 누적될 수 있으므로 additive IAM policy audit에서 해당 사용자
group membership과 적용되는 모든 정책을 확인합니다. 단, 이 condition 자체가 Email
Delivery tenant-wide resources를 region-scoped로 만드는 것은 아닙니다. project
compartment와 region을 명시해야 하며 tenancy-wide IAM mutation에는 별도 명시적 사용자
승인이 필요합니다.

no unauthorized OCI automation: 설치기와 저장소 스크립트는 OCI IAM user/group/policy,
SMTP Credential, Approved Sender, DNS, public IP 또는 Email Delivery 자원을 생성·변경·삭제하지 않습니다.

## 3. SMTP Credentials 생성

1. 전용 IAM 사용자의 상세 화면을 엽니다.
2. **SMTP credentials**를 선택합니다.
3. **Generate credentials**를 실행합니다.
4. 표시된 username과 password를 안전한 암호 저장소에 즉시 보관합니다.

SMTP password는 생성 직후에만 확인할 수 있고, 사용자가 원하는 문자열로 지정할
수 없습니다. 자격 증명은 자동 만료되지 않으며 사용자당 최대 2개이므로 교체 시
기존 credential 정리까지 계획합니다.

공식 절차:

- [Creating SMTP Credentials](https://docs.oracle.com/en-us/iaas/Content/Email/Reference/gettingstarted_topic-create-smtp-credentials.htm)
- [Working with SMTP Credentials](https://docs.oracle.com/en-us/iaas/Content/Identity/access/working-with-smtp-credentials.htm)

SMTP password를 Git, 채팅, 이슈, 셸 history 또는 명령행 인수에 기록하지 않습니다.

## 4. Email Domain과 DKIM

1. 대상 region에서 **Developer Services → Email Delivery → Email Domains**로 이동합니다.
2. 실제 발신주소에 사용할 소유 도메인을 생성합니다.
3. Email Domain 상세 화면의 DKIM에서 새 selector를 생성합니다.
4. OCI가 생성한 CNAME 이름과 값을 도메인의 실제 DNS 공급자에 추가합니다.
5. DNS 전파 후 DKIM 상태가 active인지 확인합니다.

공개 메일 서비스 도메인은 Email Domain으로 사용할 수 없습니다. Email Domain과
DKIM이 적용되는 정확한 도메인 또는 subdomain이 From 주소와 일치해야 합니다.

Email Domain/DKIM/SPF는 same sending domain and region일 때만 공유할 수 있습니다.
공유는 도메인 인증 운영의 공유일 뿐, project-specific exact Approved Sender 권한을
대체하지 않습니다. 다른 프로젝트가 남아 있으면 이 공유 자원을 변경하거나 삭제하지
않습니다.

공식 절차:

- [Creating an Email Domain](https://docs.oracle.com/en-us/iaas/Content/Email/Reference/gettingstarted_topic-create-email-domain.htm)
- [Setting up an Email Domain with DKIM](https://docs.oracle.com/en-us/iaas/Content/Email/Tasks/managing_dkim-setup_email_domain_with_dkim.htm)
- [Creating a DKIM Record](https://docs.oracle.com/en-us/iaas/Content/Email/Tasks/managing_dkim-create_dkim_record.htm)

## 5. SPF

Asia/Pacific commercial region의 OCI Email Delivery를 발신 도메인에 허용하는
기준 SPF 값은 다음과 같습니다.

```text
v=spf1 include:ap.rp.oracleemaildelivery.com ~all
```

기존 SPF 레코드가 있다면 두 번째 `v=spf1` TXT 레코드를 추가하지 말고 기존
레코드에 OCI include를 병합합니다. 다른 대륙 또는 realm은 Oracle의
[Configuring SPF](https://docs.oracle.com/en-us/iaas/Content/Email/Tasks/configurespf.htm) 표에서 정확한 값을 확인합니다.

## 6. Approved Sender

DKIM이 active가 된 뒤 대상 region과 project compartment에서 Approved Sender를
생성합니다. 최소 구성에서는 ThreadHub의 실제 From 주소 하나를 등록합니다.

```text
no-reply@your-sending-domain.example
```

이 주소는 `deploy/.env`의 `SMTP_FROM_ADDRESS`와 정확히 일치해야 합니다. 승인되지
않은 From 주소는 OCI Email Delivery에서 거부됩니다.

공식 절차는 [Creating an Approved Sender](https://docs.oracle.com/en-us/iaas/Content/Email/Reference/gettingstarted_topic-Create_an_approved_sender.htm)를 참고합니다.

## 7. ThreadHub 환경값 대응

설치 마법사가 다음 값을 질문합니다.

| ThreadHub 값 | OCI 또는 DNS 값 |
| --- | --- |
| `OCI Email Delivery region` | Approved Sender를 생성한 region |
| `SMTP_SERVER` | `smtp.email.<region>.oci.oraclecloud.com` |
| `SMTP_PORT` | `587` |
| `SMTP_USERNAME` | OCI가 생성한 SMTP username |
| `SMTP_PASSWORD` | 생성 직후 표시된 SMTP password |
| `SMTP_FROM_ADDRESS` | Approved Sender 주소 |
| `SMTP_REPLY_TO_ADDRESS` | 실제 회신을 받을 주소 |

ThreadHub 기준 연결 방식은 SMTP 587과 STARTTLS입니다. 대상 region의 현재 endpoint와
지원 port는 Email Delivery **Configuration** 화면과 [Configuring SMTP Connection](https://docs.oracle.com/en-us/iaas/Content/Email/Reference/gettingstarted_topic-Configure_the_SMTP_connection.htm)에서 다시 확인합니다.

## 8. 시험과 suppression

설치 후 Gmail, 네이버와 다음 주소에서 다음 메일을 각각 시험합니다.

1. 사용자 초대
2. 이메일 확인
3. 비밀번호 재설정

메일 원문에서 SPF와 DKIM이 `pass`인지 확인하고 링크 동작을 검증합니다. 받은편지함
수신은 보장할 수 없으므로 스팸함도 확인합니다.

정상 주소에 발송되지 않으면 Email Delivery의 Suppression List에서 hard bounce나
complaint 여부를 확인합니다. 원인을 해결하기 전에는 suppression을 삭제하지 않습니다.

- [Managing Suppression List](https://docs.oracle.com/en-us/iaas/Content/Email/Tasks/managingsuppressionlist.htm)
- [Listing Suppressed Addresses](https://docs.oracle.com/en-us/iaas/Content/Email/Reference/managingsuppressionlist_topic-list-suppressed-addresses.htm)

프로젝트 격리 수동 시험은 cross-send matrix `A/A success, A/B deny, B/B success, B/A deny`를
비공개 change record에서 확인합니다. 실제 SMTP credential, sender, recipient, Compartment,
region 또는 응답 전문은 공개 저장소에 기록하지 않습니다.

## 9. 비용과 승인 경계

OCI Email Delivery cost는 tenancy and region total sending volume을 기준으로 before deployment
재확인합니다. 프로젝트별 credential 또는 Approved Sender가 별도 무료 quota를 만들지
않습니다. 현재 price, quota, rate limit은 OCI Console에서 읽기 전용으로 확인하고,
target Compartment와 region을 기록합니다.

## 10. SMTP Credential 교체

1. `./deploy/scripts/notifier-control.sh drain`으로 새 수집을 중지하고 delivery-enabled drain mode를 유지합니다.
2. delivery_enabled=true인 동안 필요한 `threadhub-mailer retry-failed` remediation을 실행한 뒤 `pending=0`과 `sending=0`을 확인합니다. 0이 아니면 중지하고 복구하거나 escalate합니다.
3. `threadhub-mailer cancel-failed`로 남은 `failed_permanent`와 `failed_exhausted`를 한 트랜잭션에서 취소·scrub하고 `failed=0`을 확인합니다. pending/sending은 변경되지 않으므로 앞 단계의 0 gate를 생략하지 않습니다.
4. `./deploy/scripts/notifier-control.sh disable`로 delivery를 중지합니다.
5. 그 뒤에만 서버의 보호된 `deploy/.env`에서 username과 password를 교체합니다.
6. `./deploy/scripts/deploy.sh`로 변경된 환경을 사용하는 Compose 서비스를 재생성합니다. Mattermost만 영향을 받는다고 가정하지 않습니다.
7. `./deploy/scripts/notifier-smtp-test.sh`로 one-time SMTP acceptance marker를 다시 시험합니다.
8. `./deploy/scripts/notifier-control.sh activate --from-env`의 gated path로 다시 활성화하고 `./deploy/scripts/notifier-status.sh`에서 상태를 확인합니다.
9. 새 credential의 acceptance와 notifier send 상태가 성공으로 확인된 뒤에만 OCI에서 이전 credential을 삭제합니다.

이 절차는 PostgreSQL과 첨부파일 bind mount를 삭제하지 않습니다. 실제 secret은
교체 전후 모두 Git에 커밋하지 않습니다.
