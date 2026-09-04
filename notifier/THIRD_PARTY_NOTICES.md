# ThreadHub notifier 라이선스 및 제3자 고지

기준일: 2026-09-04

ThreadHub Channel Email Notifier 플러그인과 Mailer는 ThreadHub의 MIT
라이선스 코드입니다. 자체 라이선스 전문은 [LICENSE](./LICENSE)에 있으며, 빌드에
포함되는 Go 모듈의 버전·SPDX 식별자·고지 원문은
[third_party/modules.tsv](./third_party/modules.tsv)와
[third_party/licenses](./third_party/licenses)에 있습니다.

## Mattermost Team Edition 사용 기준

Mattermost 공식 플러그인 문서는 다음과 같이 명시합니다.

> Plugins are fully supported in both Team Edition and Enterprise Edition

ThreadHub notifier는
`github.com/mattermost/mattermost/server/public`의 공개 플러그인 API와
`MessageHasBeenPosted` 훅을 사용합니다.

- Mattermost 서버나 Enterprise 코드를 수정하지 않습니다.
- Enterprise 전용 패키지 또는 Mattermost Source Available License 구성요소를
  포함하지 않습니다.
- 유료 기능을 활성화하거나 라이선스 검사를 우회하지 않습니다.
- 공개·비공개 채널의 새 글 및 스레드 답글을 감지하여 일반 이메일을 발송하는
  독립적인 통합 기능입니다. Persistent Notification, 확인 강제, Reminder 또는
  Scheduled Message를 구현하지 않습니다.

공식 근거:

- [Use plugins with Mattermost](https://developers.mattermost.com/integrate/plugins/using-and-managing-plugins/)
- [Mattermost plans](https://docs.mattermost.com/product-overview/plans.html)
- [Mattermost source available plugin license](https://developers.mattermost.com/integrate/plugins/source-available-license/)
- [Mattermost server/public Apache 2.0 license](https://github.com/mattermost/mattermost/blob/server/public/v0.3.0/server/public/LICENSE.txt)

Mattermost 서버 이미지와 상표에는 Mattermost가 정한 별도 라이선스와 상표 정책이
적용됩니다. ThreadHub는 Mattermost, Inc.의 공식 제품이 아니며 제휴 또는 보증을
의미하지 않습니다.

## MPL 2.0 구성요소의 소스 제공

다음 MPL 2.0 모듈은 수정하지 않은 상태로 바이너리에 연결됩니다. 해당 버전의 Source
Form은 아래 공개 저장소에서 받을 수 있습니다. 이 안내와 각 모듈의 MPL 2.0 전문은
실행 파일 형태 배포에 함께 포함됩니다.

- [hashicorp/errwrap v1.1.0](https://github.com/hashicorp/errwrap/tree/v1.1.0)
- [hashicorp/go-multierror v1.1.1](https://github.com/hashicorp/go-multierror/tree/v1.1.1)
- [hashicorp/go-plugin v1.7.0](https://github.com/hashicorp/go-plugin/tree/v1.7.0)
- [hashicorp/yamux v0.1.2](https://github.com/hashicorp/yamux/tree/v0.1.2)

## 변경 통제

`notifier/go.mod`의 의존성을 추가하거나 버전을 변경할 때는 다음 작업을 같은 변경에
포함해야 합니다.

1. 새 모듈의 라이선스와 재배포 조건을 검토합니다.
2. `third_party/modules.tsv`와 해당 라이선스·NOTICE 원문을 갱신합니다.
3. MPL·GPL·AGPL·SSPL·BSL·Source Available 또는 판별 불가 라이선스가 새로 나타나면
   배포를 중단하고 별도 검토합니다.
4. `deploy/tests/notifier-license-compliance-test.sh`와 전체 검증을 통과시킵니다.
5. 플러그인 번들과 Mailer 이미지에 고지가 실제 포함됐는지 확인합니다.

이 문서는 프로젝트의 기술적 라이선스 준수 기준이며 법률 자문을 대신하지 않습니다.
상업적 배포 조건이나 고객 계약과 충돌할 가능성이 있으면 출시 전에 법률 검토를
받아야 합니다.
