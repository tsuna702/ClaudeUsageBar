# UsageBar

[English](README.md)

Claude와 Codex 사용량을 macOS 메뉴 막대에서 보여주는 앱이에요.

## 기능

- **메뉴 막대**: 세션(5시간)·주간 사용량, 남은 양, 초기화까지 남은 시간을 표시해요. 보일 요소는 설정에서 하나씩 켜고 끌 수 있어요.
- **대시보드** (아이콘 왼쪽 클릭)
  - 세션·주간 한도와 최근 45분 속도로 계산한 소진 예상 시각 ("이 속도면 2시간 후 소진")
  - 현재 세션·주간의 한도 사용 추이 그래프
  - 추가 사용량 · 크레딧 (Claude 추가 사용량, Codex 크레딧과 한도 리셋 횟수)
  - 오늘 비용(API 요금 환산)·토큰·작업 시간, 어제 대비 증감
  - 오늘 시간대별 그래프, 최근 30일 일별 그래프
  - 모델별·프로젝트별 사용 순위 (오늘 / 7일 / 30일)
- **알림**: 사용량이 경고 기준을 넘을 때, 한도에 가까웠던 창이 초기화될 때 알려줘요.
- **계정 연결**: 공식 CLI(`claude auth login`, `codex login`)로 로그인하고, 로그인이 끝나면 자동으로 사용량을 불러와요.
- **저장된 계정**: 로그인한 계정을 키체인에 보관해 두고 바로 전환할 수 있어요. 전환하면 Claude Code나 Codex가 쓰는 계정도 함께 바뀌어요.
- **CSV 내보내기**: 일별·모델별·프로젝트별 집계와 한도 기록을 파일로 저장해요.
- **업데이트 확인**: GitHub Releases에 새 버전이 올라오면 알려줘요.
- 한국어·영어 화면(기본은 시스템 언어), 라이트·다크 모드, 로그인 시 자동 실행을 지원해요.

## 데이터 출처

| 항목 | 출처 |
|---|---|
| Claude 한도 | Claude Code 로그인 정보(키체인)로 `api.anthropic.com/api/oauth/usage` 호출 |
| Codex 한도 | `~/.codex/auth.json`으로 `chatgpt.com/backend-api/wham/usage` 호출 |
| 토큰·비용·작업 시간 | `~/.claude/projects`, `~/.codex/sessions`의 로컬 기록 |

비용은 공식 API 가격으로 계산한 값이라 구독 요금제에서 실제로 내는 돈과는 달라요. Claude 토큰이 만료되면 Claude Code와 같은 방식으로 갱신해서 키체인에 다시 저장해요.

## 설치

[Releases](https://github.com/tsuna702/ClaudeUsageBar/releases)에서 최신 `ClaudeUsageBar-vX.Y.Z.zip`을 받아 압축을 풀고 응용 프로그램 폴더로 옮기세요. 공증(notarization)을 받지 않은 앱이라 처음에는 macOS가 막을 수 있어요. 앱을 우클릭해서 **열기**를 누르거나, 아래 명령을 실행하세요.

```bash
xattr -dr com.apple.quarantine /Applications/ClaudeUsageBar.app
```

## 릴리스

`v`로 시작하는 태그를 올리면 GitHub Actions가 앱을 빌드해서 새 릴리스에 zip으로 첨부해요.

```bash
git tag v1.0.0 && git push origin v1.0.0
```

## 빌드

Xcode Command Line Tools만 있으면 돼요 (macOS 14 이상).

```bash
./build.sh
open ClaudeUsageBar.app
```

앱 아이콘을 다시 만들려면:

```bash
swift tools/make_icon.swift Resources && iconutil -c icns Resources/AppIcon.iconset -o Resources/AppIcon.icns && rm -rf Resources/AppIcon.iconset
```

## 개발용 환경 변수

- `USAGE_DEBUG=1`: 불러온 값을 표준 출력에 찍어요.
- `USAGE_SNAPSHOT=<폴더>`: 대시보드 탭별 화면을 PNG로 저장해요 (라이트·다크).
- `USAGE_OPEN=1`: 실행하자마자 대시보드를 열어요.
