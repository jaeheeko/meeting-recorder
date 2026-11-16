# MeetingRecorder

**English summary.** A personal macOS menu-bar app: toggle it on to record a meeting, toggle it off and it transcribes the audio on-device with Apple SpeechAnalyzer (Korean, `ko_KR`), then asks the Claude Code CLI (`claude -p`) to correct the transcript and write structured meeting notes (summary, topics, decisions, action items) as a Markdown file in a folder you choose. Your microphone and the system audio are recorded as two separate tracks, so the transcript says who spoke ("me" vs. "them"). Audio files are deleted after a successful transcription. Requires macOS 26+, Apple Silicon, and a logged-in Claude Code CLI. Save location, file naming and the prompts are all configurable (see below).

메뉴바 토글 하나로 회의를 녹음하고, 끄면 전사해서 주제별로 정리한 마크다운 노트를 원하는 폴더에 저장하는 macOS 앱입니다.

## 하는 일

1. 메뉴바 아이콘을 누르면 녹음이 시작됩니다(빨간 점). 다시 누르면 끝납니다.
2. **내 마이크**와 **시스템 오디오(상대 목소리)**를 별도 트랙으로 녹음하고, 각각 전사해 시간순으로 합칩니다. 전사에는 "나" / "상대"가 표시됩니다.
3. 전사는 Apple SpeechAnalyzer(ko_KR, macOS 내장)가 기기에서 합니다. 별도 STT API나 키는 필요 없습니다.
4. 전사본을 [Claude Code CLI](https://docs.claude.com/en/docs/claude-code)(`claude -p`)가 의미 기준으로 교정합니다(잘못 받아쓴 용어, 빠진 조사). 교정 전 원문은 `~/Library/Application Support/MeetingRecorder/transcripts/`에 남습니다.
5. 같은 시간대의 캘린더 일정(제목, 참석자)을 참조해 회의 제목·화자·고유명사를 맞춥니다(선택).
6. 요약, 주제별 정리, 결정, 할 일, 열린 질문과 교정된 전사를 한 파일(`.md`)로 설정한 폴더에 저장하고 알림으로 경로를 알려 줍니다.

## 요구 사항

- macOS 26 이상, Apple Silicon (SpeechAnalyzer 사용)
- Xcode 또는 Swift 6.2+ 툴체인 (소스에서 빌드할 때)
- [Claude Code CLI](https://docs.claude.com/en/docs/claude-code) 설치 및 로그인 (`claude -p`가 동작해야 함)

## 빌드와 실행

```bash
git clone https://github.com/jaeheeko/meeting-recorder.git
cd meeting-recorder
scripts/build.sh            # build/MeetingRecorder.app 생성 (ad-hoc 서명)
open build/MeetingRecorder.app
```

설치나 로그인 항목 등록은 하지 않습니다. 원하면 `.app`을 `/Applications`로 옮기세요.

### 첫 실행과 권한

첫 녹음에서 권한 창이 뜹니다. 모두 허용해야 합니다.

| 권한 | 용도 |
|---|---|
| 마이크 | 내 목소리 녹음 |
| 시스템 오디오 녹음 | 상대 목소리(Meet, Zoom, Slack 등 모든 앱의 출력) 녹음 |
| 캘린더 (전체 접근) | 회의 일정 참조. 설정에서 끌 수 있음 |

ad-hoc 서명이라 **다시 빌드하면 macOS가 앱을 새 앱으로 보고 권한을 다시 물을 수 있습니다.** 터미널이 아니라 `open`(또는 더블클릭)으로 실행해야 권한이 앱에 붙습니다.

### 메뉴

- 아이콘 왼쪽 클릭: 녹음 시작/종료. 오른쪽 클릭: 메뉴(경과 시간, 최근 결과, 설정…, 전사본 폴더 열기, 종료).
- 상태: 대기(마이크), 녹음 중(빨간 점), 처리 중(모래시계). 경과 시간은 툴팁과 메뉴에 있습니다.

## 설정

설정 창(메뉴의 "설정…")에서 저장 폴더, 작업 디렉터리, 내 이름, 교정·캘린더 켜기, 프롬프트·용어 사전 편집을 할 수 있습니다. 전체 항목은 `~/Library/Application Support/MeetingRecorder/config.json`입니다(없으면 기본값으로 만들어집니다).

| 항목 | 기본값 | 설명 |
|---|---|---|
| `userName` | `"나"` | 전사의 "나"가 누구인지. 프롬프트의 `{{USER_NAME}}` |
| `outputRoot` | `~/Documents/Meeting Notes` | 정리 노트를 저장할 루트 폴더 |
| `agentWorkingDir` | `""` (= outputRoot) | `claude`를 실행할 폴더. 규칙 파일(`CLAUDE.md` 등)이 있는 폴더를 지정하면 그 규칙이 적용됨 |
| `allowedPathPatterns` | `["*.md"]` | AI가 고를 수 있는 저장 경로 패턴(outputRoot 기준). `*`는 폴더·파일 이름 한 성분 안에서만 맞음 |
| `fallbackPath` | `""` | 확신하지 못하거나 패턴을 벗어날 때 저장할 폴더(루트 기준) |
| `requireExistingParent` | `true` | 패턴에서 `*`로 쓴 상위 폴더가 실제로 있어야 하는지 |
| `fileNameTemplate` | `{{date}} {{title}}.md` | 파일 이름 규칙(AI에게 알려 줌) |
| `organizePromptPath` | `""` | 정리 프롬프트 파일. 비우면 번들 기본본 |
| `correctPromptPath` | `""` | 교정 프롬프트 파일. 비우면 번들 기본본 |
| `termsPath` | `""` | 용어 사전(한 줄에 용어 하나). 비우면 `~/Library/Application Support/MeetingRecorder/terms.txt` |
| `correctionEnabled` | `true` | 전사 의미 교정 사용 |
| `calendarEnabled` | `true` | 캘린더 참조 사용 |
| `claudePath` | `""` | 비우면 `~/.local/bin`, Homebrew, PATH에서 자동 탐색 |
| `model` | `""` | `claude --model` 값. 비우면 기본 모델 |
| `correctModel` | `"sonnet"` | 전사 교정에 쓸 모델. 비우면 `model` |
| `organizeModel` | `"opus"` | 요약·정리에 쓸 모델. 비우면 `model` |
| `fallbackModels` | `["opus", "sonnet"]` | 모델이 사용 한도·과부하로 실패하면 차례로 시도할 모델 |
| `keepAudio` | `false` | `true`면 오디오를 지우지 않음. `false`여도 실패 징후가 있으면 남김 |
| `extraAllowedTools` | `[]` | `claude`에 추가로 허용할 도구. 기본은 Read/Glob/Grep(읽기 전용) |

앱은 AI가 고른 경로를 항상 검증합니다. 패턴에 맞지 않거나, `..`·`.`·빈 성분·절대 경로·숨김 폴더가 있거나, 필요한 상위 폴더가 없거나, AI가 확신하지 못했다고 답하면 `fallbackPath`에 저장합니다. 기존 파일은 덮어쓰지 않고 ` (2)`를 붙입니다. `claude`에는 쓰기 도구를 주지 않고, 파일은 앱이 씁니다.

### 프롬프트 커스텀

기본 프롬프트는 `Resources/organize-prompt.md`(정리)와 `Resources/correct-prompt.md`(교정)입니다. 설정 창의 "정리 프롬프트 편집"을 누르면 기본본이 `~/Library/Application Support/MeetingRecorder/prompts/`로 복사되고 config에 연결된 뒤 편집기로 열립니다. 쓸 수 있는 자리 표시자:

`{{USER_NAME}}` `{{ALLOWED_PATHS}}` `{{FALLBACK_PATH}}` `{{FILE_NAME_RULE}}` `{{CALENDAR}}` `{{TRACKS}}` `{{STARTED}}` `{{TRANSCRIPT}}` (정리), `{{USER_NAME}}` `{{TRACKS}}` `{{CALENDAR}}` `{{TERMS}}` `{{CHUNK}}` (교정).

정리 프롬프트의 답변 형식(`===PATH===`, `===CONFIDENCE===`, `===REASON===`, `===BODY===`)은 앱이 파싱하므로 유지하세요.

### Obsidian vault 예시

```json
{
  "userName": "Alex",
  "outputRoot": "/path/to/MyVault",
  "allowedPathPatterns": ["Inbox/*.md", "Projects/*/Meetings/*.md"],
  "fallbackPath": "Inbox",
  "requireExistingParent": true,
  "extraAllowedTools": []
}
```

`outputRoot`(= 작업 디렉터리)에 `CLAUDE.md`가 있으면 `claude`가 그 규칙(태그, frontmatter 등)을 읽고 따릅니다.

### CLI 모드 (디버그)

```bash
MeetingRecorder --transcribe me.wav [--other other.wav] [--out 파일]
MeetingRecorder --organize <transcript.md> --dry-run [--calendar-json 파일] [--no-correct] [--config 파일]
MeetingRecorder --process-session <세션 폴더>     # 전사 실패로 남은 오디오 복구
MeetingRecorder --selftest
```

`--dry-run`은 저장 경로와 본문만 출력하고 아무것도 쓰지 않습니다.

## 데이터 흐름과 개인정보

- **오디오는 기기 안에서만** 전사됩니다. 전사가 성공하면 임시 오디오는 삭제됩니다(`keepAudio` 설정 시 제외). 마이크 또는 상대 트랙이 비정상이거나 오류가 있으면 복구용으로 남기고 알림으로 알립니다.
- **전사 텍스트와 캘린더 일정 정보(제목, 참석자, 설명 일부)는 Claude Code CLI를 통해 Anthropic 서버로 전송됩니다.** 민감한 회의에는 쓰지 마세요. 교정(`correctionEnabled`)과 캘린더(`calendarEnabled`)를 꺼도 정리 단계에서 전사 텍스트는 전송됩니다.
- 교정 전 전사본은 `~/Library/Application Support/MeetingRecorder/transcripts/`에 남습니다.
- 녹음 전에 참석자의 동의가 필요한지 확인하는 것은 사용자의 책임입니다.

## 알려진 한계

- 이어폰이 아니면 상대 목소리가 마이크 트랙에도 들어갑니다(해결하지 않음).
- 상대가 여러 명이어도 모두 "상대"로 표시됩니다. 대면 회의(상대 트랙이 무음)는 AI가 맥락으로 화자를 나누며 `(화자 확인 필요)`가 남을 수 있습니다.
- 녹음 중 출력 장치가 바뀌면(블루투스 연결 등) 시스템 오디오가 끊길 수 있습니다.
- 한국어(`ko_KR`)만 다룹니다. 다른 언어는 코드의 로케일과 프롬프트를 바꿔야 합니다.
- 처리 중에는 새 녹음을 시작할 수 없습니다. 1시간 회의의 교정·정리에 몇 분이 걸립니다.
- 알림은 `osascript`로 띄우므로 아이콘이 스크립트 편집기로 보일 수 있습니다.

## 라이선스

MIT
