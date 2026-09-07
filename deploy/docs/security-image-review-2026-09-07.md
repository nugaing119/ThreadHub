# ThreadHub 런타임 이미지 보안 검토 — 2026-09-07

이 문서는 무데이터 격리 시험 인스턴스에서 수행한 런타임 이미지 검토 결과다. OWASP
인증이나 취약점 부재 선언이 아니며, 자동 스캔 결과와 실제 도달 가능성을 구분해 신규
고객 배포의 버전 선택 근거를 남긴다. 원본 JSON·ZAP 보고서·호스트명·OCI 식별자와
계정 정보는 공개 저장소에 넣지 않고 시험 VM의 root 전용 증거 경로에 보관한다.

## 1. 사용 도구와 라이선스

| 도구 | 용도 | 라이선스 |
| --- | --- | --- |
| Trivy 0.74.0 | 컨테이너 OS·언어 패키지 스캔 | Apache-2.0 |
| govulncheck 1.7.0 | Go 바이너리·소스 심볼 도달 가능성 분석 | BSD-3-Clause |
| ZAP stable baseline | 로그인 전 공개 표면의 passive DAST | Apache-2.0 |

이 도구들은 Mattermost 기능 gate를 해제하지 않는다. Mattermost는 모든 시험에서 공식
Team Edition 이미지와 무라이선스 상태만 사용했다.

## 2. Mattermost 11.7.10 ESR 판정

대상은 공식 `mattermost/mattermost-team-edition:11.7.10` AMD64 이미지다.

- Trivy: Critical 2, High 10. Mattermost와 `mmctl`에 중복 포함된 결과를 합치면 6개
  고유 모듈 취약점이다.
- `golang.org/x/crypto/ssh`와 `golang.org/x/mod/sumdb/tlog` 취약 함수는 실제 서버
  바이너리에서 호출되지 않았다.
- gRPC는 HashiCorp `go-plugin`의 선택적 구현 때문에 링크되지만 Mattermost plugin
  구현은 `net/rpc`를 사용하고 gRPC를 지원하지 않는다. 기본 허용 프로토콜도
  `ProtocolNetRPC`이며, 실행 컨테이너와 호스트에 gRPC 수신 포트가 없었다. 따라서
  gRPC HTTP/2 서버 취약점은 현재 배포 경로에서 외부 도달 불가능으로 판정한다.
- `golang.org/x/image/webp`는 파일 업로드 전처리·미리보기 생성 경로에서 실제로
  `vp8l.Decode`를 호출한다. 채널 파일 업로드 권한이 있는 인증된 Member가 조작된 WebP
  파일로 메모리 고갈을 유발할 수 있다. 25 MiB 파일 제한, 33 MP 해상도 제한과 디코더
  동시성 제한은 위험을 낮추지만 이 취약점의 입력 구조 자체를 제거하지 않는다.

결론: `11.7.10 ESR`은 내부 무데이터 시험에는 사용할 수 있지만, WebP 취약점이 수정되기
전에는 신규 고객 데이터 투입 기준으로 No-Go다.

관련 1차 자료:

- [GO-2026-6222](https://pkg.go.dev/vuln/GO-2026-6222)
- [gRPC GHSA-hrxh-6v49-42gf](https://github.com/advisories/GHSA-hrxh-6v49-42gf)
- [gRPC GHSA-vp52-pcj8-j9qc](https://github.com/advisories/GHSA-vp52-pcj8-j9qc)

## 3. Mattermost 11.10.1 Team Edition 대안

대상은 공식 `mattermost/mattermost-team-edition:11.10.1` AMD64 이미지다.

```text
index digest:   sha256:8285b96eb412d89dd308e4c1ad9cc7f1a9dc9edcd798167b55bc35f1c7ee69d1
runtime digest: sha256:12f18e9f6ad2a9c29a95393f337aa2ab0700517a55470cd943a759f5392a017f
```

- `golang.org/x/image`은 0.45.0, gRPC는 1.83.1로 올라가 위 두 취약 버전을 벗어난다.
- Trivy Critical/High 결과는 0건이었다.
- `govulncheck`는 `golang.org/x/crypto/openpgp` 사용을 별도 잔여 위험으로 보고한다.
  이 경로는 Mattermost plugin 서명 검증에 사용된다. ThreadHub는 plugin 업로드,
  Marketplace와 자동 prepackaged plugin 설치를 끄고, 저장소에서 빌드해 SHA-256을
  검증한 정확한 notifier bundle만 설치한다. 외부 Member가 OpenPGP 입력이나 plugin
  실행 파일을 공급할 경로는 없다.
- 원본 `11.7.10` DB의 논리 덤프를 외부 포트 없는 임시 Docker 네트워크에 복원한 뒤
  `11.10.1`을 기동했으며 API readiness와 DB migration이 성공했다. 원본 서비스는
  시험 전후 모두 정상이고 임시 컨테이너·네트워크·볼륨은 제거됐다.

결론: 공급망 Critical/High gate는 통과한다. OpenPGP 경로는 위 보완 통제와 함께 운영
예외로 기록하고, Mattermost가 다른 서명 구현을 제공하거나 관련 보안 공지를 내면 다시
검토한다. 고객 투입 전에는 나머지 수동 인증·권한·SMTP·CJK·모바일·복구 시험도 통과해야
한다.

관련 1차 자료:

- [Mattermost v11 changelog](https://docs.mattermost.com/product-overview/mattermost-v11-changelog)
- [Mattermost version archive](https://docs.mattermost.com/product-overview/version-archive)
- [Mattermost release policy](https://docs.mattermost.com/product-overview/release-policy)
- [GO-2026-5932](https://pkg.go.dev/vuln/GO-2026-5932)
- [govulncheck](https://pkg.go.dev/golang.org/x/vuln/cmd/govulncheck)

## 4. PostgreSQL 18.6 이미지 판정

기존 Debian 13 기반 `postgres:18.6` 이미지는 Trivy에서 Critical 14, High 97을
보고했다. 대부분은 장기 실행 PostgreSQL 요청 경로가 아닌 Perl, util-linux, `gosu`와
이미지 내 보조 도구에서 발생하지만 공개 보안 기준선으로는 잡음과 예외가 지나치게 많다.

공식 `postgres:18.6-alpine` AMD64 이미지는 다음 digest로 검증했다.

```text
index digest:   sha256:d3e1620b530c944afa6e887d22eb899824da68e19c52024bf98f5220c88a65b2
runtime digest: sha256:63bdc97d67b5133bf0e5ebd500bec6d046fa851dc81340d838f0347e616107e8
```

- Trivy: Critical 1, High 30.
- 이 중 22건은 시작 시 권한을 PostgreSQL 사용자로 내리는 `gosu`의 오래된 Go 표준
  라이브러리 버전 때문에 보고됐다. 정확한 `gosu` 바이너리를 `govulncheck`로 분석한
  결과 실제 호출되는 취약 심볼은 0건이었다. `gosu`는 초기화 후 장기 실행 네트워크
  서비스로 남지 않는다.
- OS 패키지 9건 중 OpenSSL 2건은 QUIC server 경로지만 PostgreSQL은 QUIC listener를
  제공하지 않는다. util-linux 계열 7건은 `libuuid` 소스 패키지에 귀속된 mount·nsenter
  로컬 권한 문제이며 PostgreSQL 요청 처리 경로가 아니다. 컨테이너에는 Docker socket과
  `CAP_SYS_ADMIN`을 주지 않는다.
- 같은 고정 base digest에 현재 Alpine 보안 업데이트를 적용한 평가 이미지는 OS
  Critical/High 0건, `gosu` 모듈 결과 22건만 남았다. 외부 포트 없는 임시 컨테이너에서
  초기화, readiness, SQL 쓰기·읽기 시험도 통과했다.

결론: 신규 설치는 Debian 변형보다 공식 Alpine 변형을 우선 검토한다. 다만 Debian과
Alpine은 libc·locale과 컨테이너 UID가 다르므로 기존 데이터 디렉터리에 이미지만 바꾸지
않는다. 기존 인스턴스 전환은 `pg_dump` → 새 빈 Alpine 데이터 디렉터리 → `pg_restore`
복구 시험을 거친 별도 작업으로만 수행한다.

## 5. 표준 변경 결과

검토 결과를 반영해 신규 `canonical fresh` 기준을 다음과 같이 변경했다.

1. Mattermost는 공식 Team Edition `11.10.1`의 정확한 AMD64 digest를 사용한다.
2. PostgreSQL은 공식 `18.6-alpine`의 정확한 AMD64 digest를 사용하고 위 도달 불가능
   판정을 VEX/위험대장에 유지한다.
3. `11.10.1`은 ESR이 아니므로 지원되는 후속 Team Edition 패치를 정기적으로 확인하고,
   WebP 수정이 포함된 `11.7.x` 후속 ESR이 나오면 격리 시험 후 ESR 복귀를 검토한다.
4. 기존 운영 인스턴스에는 이 문서만으로 자동 업그레이드나 PostgreSQL 이미지 계열
   전환을 수행하지 않는다.

이 표준 변경만으로 고객 파일럿을 Go로 전환하지 않는다. 해당 프로젝트의 수동 수락
시험과 복구 VM 시험까지 통과해야 전체 Go를 판정한다.
