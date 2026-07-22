# Twosome 운영 절차

## 1. 접근 경계

`Twosome`은 초대 전용 Mattermost Team입니다. Team에 초대된 사용자만 Team과 아래 채널에 접근할 수 있습니다.

| 채널 | 유형 | 용도 | 신규 Team 멤버 |
| --- | --- | --- | --- |
| `00-공지` | Team 공개 | 공지와 운영 안내 | 자동 참여 |
| `01-프로젝트-일반` | Team 공개 | 일반 프로젝트 대화 | 관리자 추가 |
| `02-진행-이슈` | Team 공개 | 진행상황, 이슈와 차단사항 | 관리자 추가 |
| `03-결정사항` | Team 공개 | 최종 결정과 근거 | 관리자 추가 |

여기서 Team 공개는 인터넷 공개가 아니라 `Twosome` Team 멤버에게 공개된다는 뜻입니다. 다른 Team의 사용자는 `Twosome` 멤버십 없이는 채널을 볼 수 없습니다.

`00-공지`는 Mattermost 기본 `Town Square`의 표시 이름을 변경한 채널입니다. 새 Team 멤버가 자동 참여하므로 별도의 두 번째 공지 채널을 만들지 않습니다.

## 2. 사용자 초대

1. 관리자가 이메일 초대를 발송합니다.
2. 사용자가 이메일 확인과 계정 생성을 완료합니다.
3. 사용자의 `Twosome` Team 멤버십을 확인합니다.
4. 사용자를 `01-프로젝트-일반`, `02-진행-이슈`, `03-결정사항`에 추가합니다.
5. 사용자가 네 채널을 모두 열 수 있는지 확인합니다.
6. 사용자 역할이 일반 `Member`이고 Team Admin·System Admin이 아닌지 확인합니다.

서버에서 확인하거나 보완할 때는 다음 형식을 사용합니다.

```bash
sudo docker exec threadhub-mattermost-1 \
  mmctl team users add twosome USERNAME --local

sudo docker exec threadhub-mattermost-1 \
  mmctl channel users add twosome:01-project-general USERNAME --local

sudo docker exec threadhub-mattermost-1 \
  mmctl channel users add twosome:02-progress-issues USERNAME --local

sudo docker exec threadhub-mattermost-1 \
  mmctl channel users add twosome:03-decisions USERNAME --local
```

Team 초대 URL은 고객에게 배포하지 않습니다. 기본 초대 수단은 관리자가 보내는 이메일 초대입니다.

## 3. 운영 규칙

- 새 주제는 새 메시지로 시작하고 후속 논의는 스레드로 이어갑니다.
- 진행상황과 차단사항은 `02-진행-이슈`에 기록합니다.
- 최종 결정과 근거는 `03-결정사항`에 다시 정리합니다.
- 중요한 결정을 DM에만 남기지 않습니다.
- 비밀번호, API 키, 개인키와 고객 비밀정보를 채널에 올리지 않습니다.
- 모바일 푸시는 제공하지 않으므로 긴급 연락은 별도 이메일이나 전화로 수행합니다.

## 4. 사용자 제거

1. 진행 중 업무와 인계 내용을 확인합니다.
2. 사용자를 `Twosome` 채널과 Team에서 제거합니다.
3. 사용자가 이 인스턴스의 다른 프로젝트에도 참여하지 않으면 계정을 비활성화합니다.
4. 기존 메시지와 스레드가 유지되는지 확인합니다.
5. 재참여 시 새 계정을 만들지 않고 기존 계정을 재활성화합니다.

Team 또는 채널에서 제거하는 것과 계정 비활성화는 다릅니다. 다른 Team에 계속 참여해야 하는 사용자는 계정을 비활성화하지 않습니다.

## 5. 프로젝트 종료

1. 종료 일정과 기록 유지 범위를 공지합니다.
2. 미완료 작업과 최종 결정사항을 확인합니다.
3. 외부 사용자를 Team에서 제거하고 필요 시 계정을 비활성화합니다.
4. 채널은 삭제보다 보관을 기본으로 합니다.
5. VM과 Boot Volume 유지 여부를 결정합니다.

VM과 Boot Volume을 모두 삭제하면 메시지, 파일과 계정 데이터를 복구할 수 없습니다. ThreadHub MVP는 장애·오삭제 복구를 보장하지 않습니다.

## 6. 온보딩 완료 확인

- [ ] 이메일 초대와 이메일 확인 성공
- [ ] `Twosome` Team 멤버십 확인
- [ ] 네 채널 접근 확인
- [ ] Team Admin·System Admin 아님
- [ ] 채널 삭제·보관 권한 없음
- [ ] 모바일 푸시 미제공 안내
- [ ] 장애 복구 미보장 안내
