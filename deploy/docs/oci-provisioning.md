# OCI 인프라 준비

이 문서는 ThreadHub 설치 마법사를 실행하기 전에 준비해야 할 OCI 리소스를
정리합니다. 설치 마법사는 OCI 리소스를 생성·삭제·변경하지 않습니다.

## 1. 작업 경계 확정

먼저 다음 값을 기록합니다.

- 대상 tenancy와 compartment
- 대상 OCI region
- 프로젝트 도메인과 DNS zone 관리자
- 승인된 SSH source CIDR
- 기존 VCN·subnet·NSG 재사용 여부

리전에 종속되지 않는 IAM 사용자·그룹·정책·SMTP Credentials는 tenancy에
영향을 줄 수 있으므로 자동 생성하지 말고 명시적 승인을 받은 뒤 작업합니다.

## 2. 네트워크

기존 VCN을 재사용하거나 다음 조건의 VCN을 준비합니다.

- Internet Gateway가 연결됨
- Internet Gateway로 향하는 route가 있는 public subnet
- VM VNIC에 public IPv4를 연결할 수 있음
- NSG 또는 Security List에 필요한 포트만 허용

| 포트 | Source | 목적 |
| --- | --- | --- |
| TCP 22 | 승인된 관리자 CIDR | SSH |
| TCP 80 | 인터넷 | ACME와 HTTPS 전환 |
| TCP 443 | 인터넷 | ThreadHub |

8065, 5432, 8443과 Docker API는 인터넷에 공개하지 않습니다.

OCI의 public subnet 요구조건은 [Public IP Addresses](https://docs.oracle.com/en-us/iaas/Content/Network/Tasks/managingpublicIPs.htm)를 참고합니다.

## 3. Compute VM

다음 기준으로 새 VM을 생성합니다.

| 항목 | 기준 |
| --- | --- |
| 이미지 | Ubuntu Server 24.04 LTS |
| 아키텍처 | AMD x86_64 |
| OCPU | 2 |
| 메모리 | 16GB |
| Boot Volume | 50GB 이상 |
| Subnet | Public Subnet |
| SSH | 공개키 인증 |

ThreadHub는 프로젝트 또는 정보 공유 경계마다 독립 VM을 사용합니다. 새 VM에는
기존 `/srv/threadhub` 데이터가 없으므로 clone한 저장소는 새 PostgreSQL과
Mattermost 데이터를 생성합니다.

## 4. Reserved Public IP

서비스 주소가 VM 재생성이나 IP 변경으로 흔들리지 않도록 Reserved Public IP를
권장합니다.

1. Networking의 Reserved public IPs에서 새 주소를 생성합니다.
2. VM primary VNIC의 private IP에 연결합니다.
3. 연결된 public IPv4를 기록합니다.

공식 절차:

- [Creating a Reserved Public IP](https://docs.oracle.com/en-us/iaas/Content/Network/Tasks/reserved-public-ip-create.htm)
- [Assigning a Reserved Public IP](https://docs.oracle.com/en-us/iaas/Content/Network/Tasks/reserved-public-ip-assign.htm)

## 5. DNS A 레코드

프로젝트별 hostname을 새로 추가합니다.

```text
project-a.example.net  A  <reserved-public-ip>
```

기존 프로젝트 hostname이나 unrelated RRset을 덮어쓰지 않습니다. 같은 hostname을
공유 스토리지 없는 두 독립 VM에 동시에 연결하지 않습니다.

OCI DNS를 사용한다면 zone의 Records에서 A 레코드를 추가하고 변경사항을
publish합니다. 자세한 절차는 [Adding a Record to a DNS Zone](https://docs.oracle.com/en-us/iaas/Content/DNS/Tasks/record-add.htm)을 참고합니다.

DNS 확인 예시:

```bash
getent ahostsv4 project-a.example.net
```

DNS가 아직 전파되지 않아도 설치 마법사는 컨테이너까지 구성한 뒤 안전하게
중단합니다. 전파 후 다음 명령으로 이어서 실행합니다.

```bash
./deploy/scripts/setup-wizard.sh --resume
```

## 6. 설치 시작 전 체크리스트

- [ ] 정확한 compartment와 region을 확인함
- [ ] Ubuntu 24.04 AMD64, 2 OCPU, 16GB VM을 생성함
- [ ] Reserved Public IP를 VM에 연결함
- [ ] TCP 22·80·443만 필요한 범위로 허용함
- [ ] 프로젝트 hostname A 레코드를 추가함
- [ ] SSH 공개키로 접속함
- [ ] OCI Email Delivery 준비를 완료함

## 7. 선택적 Object Storage 백업

백업을 사용할 때만 [백업 및 복구 운영 가이드](./backup-restore.md)의 전용 Private
버킷, exact-instance Dynamic Group과 create/inspect/read-only object policy를
구성합니다. 실제 버킷·lifecycle·Dynamic Group·IAM policy는 설치 요청만으로 만들지
않습니다. 대상 compartment와 `ap-singapore-1`을 명시하고 별도 승인을 받아야 하며,
VM에는 object 또는 bucket delete 권한을 주지 않습니다.
