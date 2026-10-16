# 영어 회화 학습 v1.1 설계 (기능 묶음 5개)

- 작성: designer (설계만, 코드 수정 없음) / 대상 버전: 1.1.0 (부 버전: 기능 추가)
- 읽은 것: `README.md`, `API.md`, `ROADMAP.md`, `WORKLOG.md`, `godot/scripts/**`(main, autoload 6개, core, ui, views), `backend/server.py`(라우트·`run_chat`·`/score`), `lesson_rules.py`(Pool/`_eligible`/`target_vocab`), `reading.py`(`examples`), `features.py`(음소 팁), `packaging/build_dist.ps1`(백엔드 복사 규칙), 기존 테스트 머리글.
- 안드로이드 설계(`docs\android_remote_design.md`)는 이 문서를 쓰는 시점에 파일이 없었다. 아래의 안드로이드 관련 내용은 지시문에 적힌 범위(원격 모드, 페어링 라우터, 모든 뷰 세로 레이아웃 수정)를 근거로 한 **추측**이다.
- 표기: (추측) = 코드·문서로 확인하지 못한 가정.

---

## 1. 목표와 범위

### 1.1 목표
이미 있는 "대화·교정·발음 채점·레슨·복습"을 **습관 + 목표 + 약점 반복**의 고리로 묶어, 실제로 영어가 느는 앱으로 만든다.

### 1.2 v1.1에서 하는 것 (5개)

| ID | 기능 | 한 줄 | AI 호출 |
|---|---|---|---|
| F1 | 롤플레이 미션 | 상황 + 체크리스트 목표, 말하면 목표가 자동 체크, 끝나면 별점·피드백 | 턴당 1회(기존 `/chat`) + 종료 시 1회(기존 `/feedback`). 체크는 규칙(AI 0회) |
| F2 | 쉐도잉 | 원어민 목소리로 듣고 바로 따라 말하기, 억양·음소 채점, 느리게·구간 반복 | 0회 |
| F3 | 받아쓰기 | 듣고 타자로 쓰기, 단어별 정오 표시 | 0회 |
| F4 | 약한 소리 집중 연습 | 채점 결과에서 자주 틀린 음소를 모아 그 소리만 반복 연습 | 0회 |
| F5 | 일일 목표 · 연속 기록(보호권) · 학습 통계 | 오늘 목표(분), 보호권, 주간 공부 시간·정답률·발음 점수 추이 | 0회 |
| F6(소기능) | 교정 자동 카드 | 대화 중 나온 "더 자연스럽게" 문장을 자동으로 복습 카드에 추가 | 0회(이미 받은 결과 사용) |

### 1.3 하지 않는 것 (v1.1 제외)

| 제외 | 이유 |
|---|---|
| 단원 지도(커리큘럼 진행 경로 그림) | 학습 효과보다 동기부여용. 기존 `로드맵` 탭과 겹침. 통계 탭의 주간 진행으로 대체 |
| 일본어용 미션·받아쓰기 | 지시 범위가 "영어 회화". 일본어는 쉐도잉·목표·통계만 공통 지원 (일본어 받아쓰기는 한자·가나 표기 판정이 어려움) |
| AI가 미션을 새로 만들어 내기 | 느리고 품질이 흔들림. 미션은 사람이 쓴 데이터 파일 8개 |
| 리그·친구·알림 | 서버·계정 필요. 범위 밖 |
| 영상 쉐도잉, FSRS 개인 맞춤, 기록 내보내기 | ROADMAP v1.2+ |
| `Recorder`·`Tts`·`Api` 내부 수정 | 안드로이드 작업이 고치는 중. 공개 함수만 사용 |
| 기존 `/chat`·`/score`·`/prosody`·`/feedback` 계약 변경 | 호환 유지 |

---

## 2. 경쟁 앱 비교 (공개 정보만, 리뷰·소개 글 기준)

출처는 대부분 2차 자료(리뷰 사이트)라 정확한 기능 이름·가격은 공식 확인이 필요하다. 앱 내부 코드·콘텐츠는 보지도 복사하지도 않았다.

| 앱 | 학습 효과를 내는 핵심 | 이 앱 현재 | v1.1 |
|---|---|---|---|
| Speak | 상황별 AI 롤플레이로 많이 말하게 함, 말한 직후 교정, 맞춤 진행 | 롤플레이 대화·교정 있음. **목표/완료/점수 개념 없음** | F1 미션 |
| Duolingo | 하루 짧은 세션, 일일 목표·연속 기록·보호권(freeze)·복구, 단원 지도, (Max) 롤플레이·설명 | 연속 일수·XP만. **목표·보호권·통계 없음** | F5 |
| ELSA Speak | 음소 단위 색 피드백(초록/노랑/빨강), 초기 평가 뒤 약점 중심 경로, 강세·억양·리듬 | 음소·억양 채점 있음(영어). **약점이 쌓이지 않고 집중 연습 없음** | F4 |
| Cambly | 사람 원어민과 실시간 화상 대화 | AI 대화로 근사. 사람 튜터는 불가 | 해당 없음 |
| (일반 학습법) | 쉐도잉, 받아쓰기는 앱 밖에서도 검증된 말하기·듣기 훈련 | 따라 말하기 문제만 있음 | F2, F3 |

참고 링크: [Speak vs ELSA 비교](https://engvarta.com/speak-vs-elsa-speak-english-fluency-comparison/), [ELSA 리뷰 모음](https://makeheadway.com/blog/elsa-speak-review/), [Duolingo 연속 기록 분석](https://lennysnewsletter.com/p/behind-the-product-duolingo-streaks), [Cambly vs italki](https://www.talkdrill.com/blog/compare/cambly-vs-italki/).

**이 앱의 차이(유지할 강점)**: 전부 내 PC에서 돌아가 무료, 음소·억양 채점이 기본 제공, Tatoeba 실제 예문으로 AI 없이 연습 가능.

---

## 3. 공통 원칙

### 3.1 AI 호출 예산 (DeepSeek 무료는 한 턴 수 초, 한도가 걸릴 수 있음)

| 기능 | AI 있을 때 | AI 없을 때 (`/health`의 `llm` false 또는 오류) |
|---|---|---|
| F1 미션 | 말할 때마다 `/chat` 1회. 목표 체크는 규칙. 종료 `/feedback` 1회. 선택: "AI로 다시 판정" 1회 | **대본 모드**: 상대 대사는 데이터에 미리 쓴 줄, 내 답은 규칙+문장 유사도로 체크. 종료 피드백은 규칙 요약 |
| F2~F5, F6 | 0회 | 동일 |

- 미션의 첫 마디는 데이터의 `opening`을 쓴다(AI 첫 호출 생략, 시작 즉시).
- 미션에서는 턴마다 `/fix`를 부르지 않는다. 교정은 종료 `/feedback`의 `corrections`로 일괄 처리(기존 TalkView와 같은 방식으로 복습 카드에 추가).

### 3.2 새 화면 레이아웃 원칙 (폰 세로 412×915 / PC 1280×800 공용)

| # | 원칙 | 확인 방법 |
|---|---|---|
| L1 | 뿌리는 `PageScroll`(최대 폭 720) 또는 `VBoxContainer`. 고정 픽셀 폭 `custom_minimum_size.x`는 320 이하만 | 레이아웃 테스트: 412 폭에서 `get_combined_minimum_size().x <= 412` |
| L2 | 눌러서 쓰는 모든 `Button`은 높이 44px 이상 (`UI.button(.., min_h=48)`; `UI.link_button`도 주 동작이면 `custom_minimum_size.y = 44`) | 레이아웃 테스트: 보이는 Button 중 `size.y < 44` 가 0개 (예외는 `set_meta("touch_exempt", true)`, 화면당 3개 이하) |
| L3 | 열 개수는 `size.x` 기준(700 미만 1열). `NOTIFICATION_RESIZED`에서 다시 계산 (TodayView 방식) | 같은 화면을 412↔1280으로 바꿔도 오류 없음 |
| L4 | 긴 글은 항상 줄바꿈(`UI.label` 기본 wrap), 칩 줄은 `UI.flow()`(`HFlowContainer`) | 412 폭에서 가로 스크롤 없음 |
| L5 | 주 동작(녹음·확인)은 화면 아래 고정 바(LessonView의 `_footer_holder` 방식) | 코드 점검 |
| L6 | 호버·키보드만 되는 기능 금지(스페이스 녹음은 보조). 문자 입력창은 아래 고정 바에 둬서 소프트 키보드가 가려도 스크롤 가능 | 코드 점검 |
| L7 | 색·글꼴은 기존 `Pal`, `UI` 사용 (`UI.fix_cjk` 호출 포함) | 코드 점검 |

### 3.3 녹음·재생 사용 규칙
- 녹음: `RecorderWidget`(공개 클래스, `recorded(result)` 신호)만 쓴다. 자동 녹음 시작이 필요한 곳(F2 옵션)만 `Recorder.begin(owner)`/`Recorder.finished` 공개 함수를 쓴다. 내부 변수 직접 접근 금지.
- 재생: `Tts.speak(text, lang, slow)`, `Tts.stop()`, `Tts.speak_chunks()`, `Tts.sequence_finished`, `Tts.playing`만 사용. 속도는 보통(사용자 설정)과 느리게(0.75, `Tts.SLOW_SPEED`) 두 가지뿐(임의 속도는 `tts.gd`를 고쳐야 해서 v1.1 제외).
- 화면을 떠날 때(`on_hide`) 녹음 중이면 `stop_if_recording()` 호출(기존 뷰와 같은 패턴).

### 3.4 비동기 안전 패턴
모든 `await Api...wait()` 뒤에는 기존 뷰처럼 **일련번호(`_serial`) 비교 + `is_instance_valid`** 로 늦게 온 응답을 버린다. 요청 중 화면이 닫히거나 언어가 바뀌어도 오류가 나면 안 된다.

### 3.5 저장 호환
- 기존 `user://progress.json`, `user://prefs.json` 스키마는 **바꾸지 않는다**. `Progress.normalize()`는 모르는 키를 버리므로(확인함) 새 데이터는 거기에 넣지 않는다.
- 새 데이터는 별도 파일 `user://studylog.json` (클래스 `StudyLog`). 파일이 없으면 빈 상태로 시작, 깨졌으면 `studylog.json.bad`로 옮기고 빈 상태로 시작(앱은 멈추지 않음), `v`가 더 크면(다운그레이드) 아는 키만 쓰고 모르는 최상위 키는 그대로 보존해서 저장.
- 새 설정 키는 `Store.prefs`에 `Store.prefs.get(key, 기본값)`으로만 읽는다(`DEFAULT_PREFS` 수정 불필요): `daily_goal_min`(기본 10, 0=끔), `shadow_auto_rec`(기본 false), `auto_fix_cards`(기본 true).
- 서버는 새 데이터를 **저장하지 않는다**(무상태). 안드로이드 폰은 폰의 `user://`에 따로 쌓는다.

### 3.6 콘텐츠 파일 위치
`backend/data/`는 `.gitignore`와 `build_dist.ps1`(robocopy `/XD data`)이 모두 제외한다(Tatoeba DB용). 그래서 새 콘텐츠는 **`backend/content/`** (git 추적, 배포 포함)에 둔다.

---

## 4. 구조와 데이터 흐름

```
Godot (화면)                                      Python 서버 (같은 PC 또는 원격)
 main.gd ─ TABS + StudyClock(공부 시간)
 ├ PracticeView (연습 허브)  ──GET /practice/ping ──────────► practice.py (신규 라우터)
 │   ├ ShadowScreen    ──GET /practice/sentences ──────────►   └ lesson_rules.pool/_eligible 재사용
 │   ├ DictationScreen ──GET /practice/sentences            │
 │   ├ PhonemeScreen   ──GET /practice/phonemes, /phoneme ──►   └ content/phoneme_drills.json
 │   └ MissionScreen   ──GET /missions, POST /missions/check ► missions.py (신규 라우터)
 │                       POST /chat, /feedback, /stt (기존)      └ content/missions.json, (선택) ollama_json
 ├ SpeakDrill(듣기→녹음→/score→/prosody) ── 기존 /tts /score /prosody
 ├ StatsView (기록 탭) ◄── StudyLog (user://studylog.json)
 └ 기존 뷰 ──(한 줄 연결)──► StudyLog.add_score / add_lesson, FixCards.add
```

- 채점 결과 한 곳 모으기: 모든 `/score` 응답이 `StudyLog.add_score(lang, res, source)`로 들어가 발음 점수 추이와 음소별 성공/실패(F4의 재료)를 만든다.
- 공부 시간: `StudyClock`(노드 하나)이 "입력이 있었거나 녹음·재생·요청 중"일 때만 초를 센다. 기존 뷰를 고치지 않는다.

---

## 5. 기능별 설계

### F1. 롤플레이 미션

**사용자 흐름**
1. 연습 탭 → "미션" 카드 → 목록(영어, 단계에 맞는 것 먼저, 별점 표시).
2. 미션 선택 → 상황 설명 + 목표 3~5개 + "힌트 보기" → 시작. 상대의 첫 마디는 즉시 표시·재생.
3. 말하기(마이크 → `/stt`) 또는 타자 → 보내면 **즉시** `/missions/check`(규칙, 수십 ms)와 `/chat`(AI)을 동시에 호출. 체크 결과는 AI 답보다 먼저 목표 목록에 반영("목표 달성" 토스트).
4. 모든 목표 달성, 턴 한도(`max_turns`) 도달, 또는 "끝내기" → 종료 화면. 규칙으로 못 잡은 목표는 사용자가 직접 체크 가능(수동 표시), "AI로 다시 판정"(선택, 1회 호출) 가능.
5. 종료: `/feedback` 호출(스피너, 취소 가능) → 별점·점수·고쳐 말하기(복습 카드 자동 추가)·쓸 만한 표현. 실패해도 별점·목표 결과는 보인다.
6. AI 없음/오류: "대본 모드로 연습" 버튼.

**별점·XP (클라이언트 계산, `MissionLogic`)**
- 완료 비율 r = (규칙 달성 + 수동 체크) / 전체 목표. 별 3: r=1 이고 학습자 턴 ≤ `max_turns`. 별 2: r ≥ 0.6. 별 1: r > 0. 별 0: 그 외.
- XP = 20 + 10×달성 목표 수 + 10×별. `Store.add_xp`, `Store.mark_today`(달성 ≥1 또는 학습자 턴 ≥3), `StudyLog.add_mission`, `StudyLog.add_event(lang,"missions")`.

**화면 (PC 너비 ≥ 900 / 폰 세로)**

```
PC                                                  폰 세로 (412)
┌ ← 연습  카페에서 주문하기           [끝내기] ┐    ┌ ← 카페에서 주문하기   [끝내기] ┐
│ 대화                      │ 목표  2 / 4      │    │ 목표 2 / 4  ▾  (탭하면 펼침)   │
│  Emma  Hi! What can I...  │ [v] 인사하기     │    ├───────────────────────────────┤
│        (번역)(▶)          │ [v] 음료 주문    │    │  Emma  Hi! What can I...      │
│   나   I'd like a latte.  │ [ ] 사이즈 말하기│    │              I'd like a latte │
│                           │ [ ] 감사 인사    │    │  ...                          │
│                           │ 힌트 ▾           │    ├───────────────────────────────┤
├───────────────────────────┴──────────────────┤    │ [입력............] [●말하기][>]│
│ [입력......................][● 말하기][보내기] │    └───────────────────────────────┘
└──────────────────────────────────────────────┘
```
- 폭 < 700이면 목표 패널은 위쪽 한 줄 요약 + 펼침 목록으로 바뀐다(L3).
- 종료 화면: 별 3칸, 목표 목록(규칙 / 수동 / AI 판정 / 미달성 표시), 점수 3칸(유창성·정확성·어휘, `/feedback`), 고쳐 말하기 목록(복습에 추가됨), [다시 하기][연습으로].

**데이터 저장**: `studylog.json`의 `missions.<id> = {stars(최고), plays, last, done_goals(최근 달성 목록)}`. 진행 XP·오늘 표시는 기존 `Store`.

**콘텐츠 `backend/content/missions.json` (영어 8개, 스키마)**
```json
{"version": 1, "missions": [{
  "id": "cafe_order", "lang": "en", "min_stage": 1, "order": 10, "max_turns": 10,
  "title_ko": "카페에서 음료 주문하기",
  "situation_ko": "시애틀 카페 카운터. 음료를 고르고 사이즈를 말한 뒤 계산하세요.",
  "persona": "Emma, a friendly barista at a coffee shop in Seattle",
  "scene": "The learner is a customer at the counter. Offer natural chances to talk about size and for-here-or-to-go. Never tell the learner what to say.",
  "opening": "Hi there! What can I get started for you today?",
  "goals": [{
    "id": "order_drink", "label_ko": "음료를 주문한다", "goal_en": "order a drink",
    "hint_en": "I'd like a latte, please.",
    "match": {"any": ["\\b(i'?d like|i would like|i'?ll have|can i (get|have)|could i (get|have)|may i have)\\b"],
              "all": ["\\b(coffee|latte|americano|cappuccino|tea|mocha|espresso|juice|smoothie)\\b"]},
    "pos": ["I'd like a latte please", "Can I get an iced americano", "Could I have a coffee"],
    "neg": ["I like coffee", "Hello", "How much is it"]}],
  "script": [{"ai": "Hi there! What can I get started for you today?", "goal": "order_drink", "model": "I'd like a latte, please."}]
}]}
```
- 규칙 의미: 정규화한 문장(NFKC, 소문자, `’→'`, `[a-z0-9' ]` 외는 공백, 공백 합치기, 최대 300자)에 대해 `any` 중 하나 이상 + `all` 전부 맞으면 달성. `any`/`all` 중 하나는 비어 있지 않아야 한다.
- 목표마다 `pos` 3개 이상, `neg` 3개 이상(검사기가 실제로 돌려 본다). `script`는 목표 수 이상의 줄, `goal`은 존재하는 목표 id.
- 서버가 `scenario.scene`에 붙이는 것: 위 `scene` + `Your opening line was: "<opening>".` + `The learner's objectives (never reveal them; create natural openings for each): <goal_en; ...>.` (OpenCode 세션이 미리 쓴 첫 마디를 모를 수 있어 장면 설명에 넣는다.)
- 미션 목록(8개, 영어, 단계): cafe_order(1), self_intro(1), hotel_checkin(2), ask_directions(2), restaurant(2), pharmacy_doctor(3), return_item(3), job_interview(4).

**API 계약 (신규, `backend/missions.py`)**

`GET /missions?lang=en&stage=2` (`stage` 선택: `min_stage ≤ stage`만, 생략하면 전부)
```json
{"lang": "en", "unsupported": false,
 "missions": [{"id": "cafe_order", "title_ko": "...", "situation_ko": "...", "min_stage": 1, "max_turns": 10,
   "opening": "Hi there! ...",
   "goals": [{"id": "order_drink", "label_ko": "...", "hint_en": "I'd like a latte, please."}],
   "scenario": {"id": "mission:cafe_order", "title": "카페에서 음료 주문하기", "persona": "...", "scene": "..."},
   "script": [{"ai": "...", "goal": "order_drink", "model": "..."}]}]}
```
- `match`, `pos`, `neg`, `goal_en`은 응답에 **넣지 않는다**(검사 규칙은 서버에만).
- `lang=ja` → 200 `{"lang":"ja","unsupported":true,"missions":[],"message":"일본어 미션은 다음 버전에서 만들 예정이에요."}`. `lang` 그 외 → 400 `{"error":"lang은 'en' 또는 'ja'여야 해요."}`.

`POST /missions/check`
```json
요청 {"lang": "en", "mission_id": "cafe_order", "text": "I'd like a latte please", "done": ["greet"]}
응답 {"mission_id": "cafe_order", "goals": [{"id": "greet", "done": true, "new": false}, {"id": "order_drink", "done": true, "new": true}],
      "new": ["order_drink"], "all_done": false}
```
- 오류(한국어 `error`): 알 수 없는 `mission_id` 404 "알 수 없는 미션이에요."; `text` 비었거나 공백뿐 400 "확인할 문장이 비어 있어요."; `lang`≠en 400; 본문 형식 오류 422(기존 핸들러). `text`는 300자에서 자르고, `done`은 알려진 id만 20개까지 받는다. 한국어만 있는 문장은 어떤 목표도 달성시키지 않는다(200).
- AI를 쓰지 않는다. 응답 시간 목표 50ms 이하.

`POST /missions/judge` (선택 기능, AI 1회)
```json
요청 {"lang": "en", "mission_id": "cafe_order", "pending": ["ask_size"], "history": [{"role": "ai"|"me", "text": "..."}]}
응답 {"ai": true, "goals": [{"id": "ask_size", "done": true, "evidence": "Can I get a large?"}]}
```
- `evidence`가 `history`의 `me` 발화 안에 **그대로 들어 있어야** `done:true`로 인정(없으면 서버가 `false`로 고침 = AI 환각 방지). `pending` 비면 400, `history`는 마지막 24개만.
- AI 사용 불가/오류: 502·503 + 한국어 `error`(기존 `ApiError` 규칙). 화면은 규칙 결과를 그대로 두고 안내만 표시.
- 호출은 `server.py`의 `ollama_json`을 `missions.init(...)`으로 주입받는다(`reading.init` 패턴). 캐시 안 함.

`GET /practice/ping` (practice.py와 공용 상태 확인) → `{"ok": true, "practice": 1, "missions": 1, "tatoeba": true|false}`. 화면은 404면 "PC 프로그램을 최신 버전으로 업데이트해 주세요"를 보인다(폰 앱과 PC 서버 버전이 다를 수 있음, 추측).

**사용하는 기존 함수**: `Api.post_json("/chat")`(scenario에 위 객체, `skip_fix:true`, `conv_id`, `tts_speed`, `tts_voice`, `presynth`), `Api.post_json("/stt")`, `Api.post_json("/feedback")`, `Tts.speak/speak_chunks`, `RecorderWidget`, `UI.pref_toggle`, `Store.add_review/add_xp/mark_today/save_progress`, `TextSim.similarity`(대본 모드), TalkView의 말풍선 모양은 **복제**(TalkView 수정 금지).

**대본 모드(AI 없음)**: 줄마다 상대 대사 재생 → 내 답(말하기/타자) → 규칙 체크 또는 `TextSim.similarity(said, model) ≥ 60` 이면 통과·다음 줄. 3번 실패하면 모범 답을 보여 주고 목표 미달성으로 넘어감.

---

### F2. 쉐도잉

**사용자 흐름**: 연습 → 쉐도잉 → 문장 출처 선택("이번 주 예문" | "내 복습 카드") → 8문장 세션. 문장마다: 듣기(보통/천천히) → 따라 말하기(녹음) → 점수·음소·억양 그래프 → [다시] [다음]. 구간 반복: 단어 칩을 두 개 눌러 구간을 정하면 "구간 듣기"·"구간 따라 말하기". 옵션 "듣고 나면 자동으로 녹음 시작"(기본 끔, 스피커로 들으면 내 소리에 섞일 수 있어 이어폰 권장 문구).

**화면**
```
← 연습                    쉐도잉  3 / 8       (EN | JA)
─────────────────────────────────────────────
 I'd like a large coffee, please.
 나는 큰 커피 한 잔 주세요.            [번역 숨김 토글]
 [▶ 듣기] [천천히] [구간 반복 ▾]
 [I'd][like][a][large][coffee][please]   <- 탭: 구간 시작/끝
 ─ 구간: like ~ coffee   [구간 듣기] [구간 말하기] [해제]
 ──────────────────────────────────────────
 결과: 82   정확도 90 · 또렷함 75 · 유창성 80      (ScorePanel)
 억양 그래프(영어)                                   (ProsodyPanel)
─────────────────────────────────────────────
 [ ● 따라 말하기 ]  (고정 하단 바)    [다음 ▶]
```
- 통과 기준: 점수 ≥ 70. 80 이상 초록. 같은 문장 몇 번이든 다시 가능.
- 세션 끝 요약: 평균 점수, 통과 개수, 가장 많이 틀린 소리(영어). 70점 미만으로 끝난 문장 최대 5개를 복습 카드에 추가(`note: "쉐도잉 NN점"`).
- 구간 한계(추측 아님, 구조상): 구간 듣기는 그 부분 글자를 따로 합성하므로 문장 속에서의 억양과 조금 다르다. 화면에 한 줄 안내.
- 일본어: 같은 화면이 동작하되 음소·억양 그래프는 없음(서버가 영어만 제공). 문장은 `reading`을 `/score`에 같이 보냄.

**데이터**: 서버 무상태. 클라이언트가 `GET /practice/sentences`로 문장을 받는다. 기록은 `StudyLog.add_event(lang,"shadow")`, 점수는 `StudyLog.add_score(.., "shadow")`. XP 문장당 +3(통과 시, 세션 최대 +24). `mark_today`는 시도 ≥5문장.

**API (신규, `backend/practice.py`)**

`GET /practice/sentences?lang=en&mode=shadow&stage=2&month=1&week=1&n=8&seed=7&exclude=12,34`
```json
{"lang": "en", "mode": "shadow", "stage": 2,
 "sentences": [{"id": 1234, "text": "I run every morning.", "ko": "나는 매일 아침 달린다.", "reading": "", "words": 4,
                "url": "https://tatoeba.org/sentences/show/1234"}],
 "attribution": "예문 출처: Tatoeba (tatoeba.org) · CC BY 2.0 FR"}
```
- `mode`: `shadow`(영어·일본어) | `dictation`(영어만). 생략 시 400.
- 길이: 레슨과 같은 단계표(`lesson_rules.EN_LEN`/`JA_LEN`)의 `stage` 범위. `dictation`은 영어 3~10단어, 숫자 없음, 첫 단어와 `I` 외에 대문자 단어(이름) 없음.
- 정렬: 레슨과 같이 이달·이번 주 커리큘럼 단어 점수(`lesson_rules.target_vocab`) + 무작위(`seed`로 재현). `exclude`는 쉼표 구분 정수 id(숫자가 아닌 토큰은 무시).
- 범위 보정: `n`은 1~20으로, `stage`는 1~4로, `month`/`week`는 기존 `clamp_int`와 같이 보정. 일본어는 `reading`(히라가나, 서버의 `ja_reading`)을 채운다.
- 오류(한국어 `error`): `lang` 오류 400, `mode` 오류 400, 일본어 `dictation` 400 "받아쓰기는 영어만 지원해요.", Tatoeba DB 없음·깨짐 503 "예문 데이터가 아직 준비되지 않았어요. …"(`reading.tatoeba_ready()`가 false), DB 질의 중 `sqlite3.Error`는 `reading.invalidate_tatoeba_ready()` 후 503. 500은 내지 않는다.

**사용하는 기존 함수**: `/tts`(`Tts.speak`), `/score`, `/prosody`, `ScorePanel.build`, `ProsodyPanel`(+`tips_box`), `RecorderWidget`, `Store.review_for/due_for`, `Store.add_review`, `lesson_view`와 같은 호출 형식(`body = {lang, target, reading, audio_b64}`).

---

### F3. 받아쓰기 (영어만)

**사용자 흐름**: 연습 → 받아쓰기 → 8문장. 듣기(보통/천천히, 횟수 제한 없음) → 타자 입력 → [확인] → 단어별 초록/빨강/빠짐 표시 + 정답 문장 + 해석 + [▶] → [다음]. "모르겠어요"로 정답 보기 가능(점수 0). 힌트: 단어 수는 항상 표시, "첫 글자 보기" 탭.

**화면**
```
← 연습                  받아쓰기  2 / 8
 [▶ 듣기]  [천천히]            들은 횟수 2
 단어 5개   [첫 글자 힌트]
 ┌────────────────────────────────┐
 │ i would like a coffe           │  <- LineEdit(최대 300자)
 └────────────────────────────────┘
 [모르겠어요]                       [ 확인 ] (고정 하단)
 결과:  I'd(맞음) like(맞음) a(맞음) large(빠짐) coffee(철자 틀림)
 정답: I'd like a large coffee, please.   나는 큰 커피 한 잔 주세요.   [▶]
```
- 판정: 대소문자·문장부호·축약형(`I'd` = `I would`)을 무시하고 단어 단위 LCS로 비교(`TextSim` 재사용). 통과 ≥ 85점. 단어별 표시는 정답 원문 단어마다 맞음/틀림.
- 세션 끝: 85점 미만 문장 최대 5개를 복습 카드에 추가(`note: "받아쓰기"`). XP 통과 +3(세션 최대 +24), `mark_today`는 시도 ≥5문장.
- `DictationDiff.diff(said, target)` 순수 함수로 분리(테스트용): 반환 `{score:int, words:[{w:str, ok:bool}], extra:[str]}`.

**API**: `GET /practice/sentences?mode=dictation` (위와 동일). 그 외 새 API 없음.
**사용하는 기존 함수**: `Tts.speak`, `TextSim.tokens/lcs_match/similarity`, `Store.add_review`.

---

### F4. 약한 소리 집중 연습 (영어만)

**재료**: `/score` 응답의 `units[].ph[]`(`{p, ok, conf, heard}`). `StudyLog.add_score`가 소리(`p`)마다 최근 30번의 결과(`1`=틀림)와 "대신 들린 소리" 횟수를 쌓는다. 약점 = 표본 5개 이상 중 틀린 비율이 높은 순.

**사용자 흐름**: 연습 → "약한 소리" 카드에 상위 3개 소리가 틀린 비율과 함께 표시(예: `th /θ/ 틀림 58%`). 선택하면 → 설명(발음 방법 한국어 팁, 비슷한 소리 구분 쌍 예 think/sink, 단어 듣기) → 연습 5문항(짧은 구절 + 이 소리가 든 Tatoeba 예문 최대 3개) → 문항마다 듣기→녹음→채점 → 그 소리가 맞았는지(`ph[p].ok`) 표시 → 요약(`3/5 성공`). 표본이 없으면: "레슨이나 쉐도잉에서 따라 말하면 약한 소리를 찾아 줘요" + 소리 목록을 직접 골라 연습 가능.
- **한 단어만 말하는 문항은 쓰지 않는다**: API.md에 "짧은 단독 단어는 음소 인식이 틀릴 수 있다"고 적혀 있어 2~4단어 구절로 연습(`phrases`).
- `/health`의 `phoneme`이 false(음소 인식 불가)거나 응답에 `ph`가 없으면: 단어/문장 점수만 보여 주고 "음소 분석을 쓸 수 없어요" 안내(성공 판정 없이 연습만 기록).

**화면**
```
← 연습                       약한 소리
 지금 약한 소리 (최근 30회 기준)
 [th /θ/ 58%] [r /ɹ/ 44%] [f /f/ 31%]        <- 칩, 탭하면 선택, 폭 부족하면 줄바꿈
 ── th /θ/ ──────────────────────────────
 혀끝을 윗니 사이에 살짝 내밀고 바람만 내보내요.
 비슷한 소리: [▶ think] [▶ sink]   [▶ three] [▶ free]
 ── 연습 2 / 5 ──
 "I think three things."    [▶ 듣기][천천히]
 이번 소리 /θ/:  think  O   three  X(s로 들림)
 [ ● 말하기 ] (고정 하단)                      [다음 ▶]
```

**콘텐츠 `backend/content/phoneme_drills.json` (스키마)**
```json
{"version": 1, "phonemes": [{
  "p": "θ", "label": "th (θ)", "hint_ko": "혀끝을 윗니 사이에 ...",
  "words": ["think", "three", "thank", "mouth", "bath", "month"],
  "pairs": [{"a": "think", "b": "sink", "ko": "생각하다 / 가라앉다"}, {"a": "three", "b": "free", "ko": "셋 / 자유로운"}],
  "phrases": [{"text": "I think three things.", "ko": "나는 세 가지를 생각해요."}]
}]}
```
- 키 `p`는 `/score`가 쓰는 espeak IPA 토큰과 **같은 글자**여야 한다(예: r은 `ɹ`, g는 `ɡ`). 최소 15개: `θ ð f v ɹ l z ʃ æ ɪ iː ʊ uː ʌ ɛ`(= `features.EN_TIPS`가 이미 팁을 가진 소리들).
- 항목마다 `words` ≥ 6, `pairs` ≥ 2, `phrases` ≥ 4. 검사기가 espeak로 `words`의 기대 음소에 `p`가 있는지 확인한다.

**API (신규, `practice.py`)**
- `GET /practice/phonemes` → `{"phonemes": [{"p": "θ", "label": "th (θ)", "hint_ko": "..."}]}` (≥15개).
- `GET /practice/phoneme?p=θ&sentences=3`
```json
{"p": "θ", "label": "th (θ)", "hint_ko": "...", "words": ["think", "..."],
 "pairs": [{"a": "think", "b": "sink", "ko": "..."}],
 "phrases": [{"text": "I think three things.", "ko": "..."}],
 "sentences": [{"id": 77, "text": "I think so.", "ko": "...", "url": "https://tatoeba.org/sentences/show/77"}],
 "attribution": "예문 출처: Tatoeba (tatoeba.org) · CC BY 2.0 FR"}
```
- `sentences`는 `words`로 `reading.examples("en", word, 2)`를 찾아 3~10단어·번역 있는 것만 최대 `sentences`개(0~5, 기본 3). DB가 없으면 `sentences: []`로 200(구절 연습은 계속 가능).
- 오류: `p` 없음 400 "소리(p)를 보내 주세요."; 목록에 없는 `p` 404 "아직 연습 자료가 없는 소리예요."

**사용하는 기존 함수**: `/score`(응답의 `ph`), `ScorePanel.phonemes_of`, `Tts.speak`(단어 한 개 듣기는 TTS라 단독 단어도 문제 없음), `RecorderWidget`.

---

### F5. 일일 목표 · 연속 기록(보호권) · 학습 통계

**일일 목표**: 목표 시간(분) 5/10/15/20/30/끔(기본 10). 오늘 활동 시간(`StudyClock`)이 목표에 닿으면 토스트 + 오늘 공부로 기록(`Store.mark_today(lang)`). 레슨·대화 완료로 기록되던 기존 방식은 그대로(목표는 추가 경로).

**연속 기록 보호권**
- 처음 1개를 줌. 연속 7일을 새로 채울 때마다 +1(최대 2개, 언어별).
- 어제 공부를 못했고 그 전날까지 연속 기록이 있으면, 못한 날 수만큼 보호권을 자동 사용해 이어 줌(날 수 > 보호권이면 쓰지 않고 기록이 끊김). 사용하면 토스트 "연속 기록 보호권 N개를 써서 연속 기록을 지켰어요".
- 보호된 날은 연속 일수에 더해지지 않고 이어주기만 한다(Duolingo 방식은 공개 설명 기준).
- 계산은 순수 함수 `StreakCalc.settle(...)` — 같은 날 여러 번 불러도 결과 같음(멱등).

**통계 (`기록` 탭)**
```
기록                                        (EN | JA)
 ┌ 오늘 목표 ─────────────────────────────┐
 │ 12 / 15분  ████████░░░░                │
 │ 연속 5일 · 보호권 1개                   │
 │ 목표: (5)(10)(15)(20)(30)(끔)           │
 └────────────────────────────────────────┘
 이번 주 공부 시간(분)   월 화 수 목 금 토 일   <- 막대 7개
 레슨 정답률 (최근 14일) ……선        발음 점수 평균 (최근 30일) ……선
 약한 소리 TOP 3   th 58%  r 44%  f 31%   [집중 연습 >]
 미션  카페 ★★☆   호텔 ★☆☆  ...
```
- 폭 < 700이면 차트는 세로로 쌓는다. 데이터가 없으면 "아직 기록이 없어요" 빈 상태.
- 오늘 화면(TodayView)에는 `GoalCard.compact()` 한 줄(오늘 분/목표, 연속·보호권)만 추가.

**데이터: `user://studylog.json` (v1)**
```json
{"v": 1, "saved": 1760000000,
 "days": {"2026-10-16": {"en": {
    "sec": 840, "by": {"lesson": 300, "talk": 200, "practice": 340},
    "n": {"lessons": 1, "talks": 0, "missions": 1, "reviews": 12, "shadow": 5, "dictation": 3, "drill": 1},
    "lesson": [8, 10],   // [맞힌 수, 문제 수] 누적
    "score": [6, 480]}}}, // [채점 횟수, 점수 합] 누적 (평균 = 합/횟수)
 "phon": {"en": {"θ": {"h": "0110010", "heard": {"s": 5, "t": 1}}}},  // h = 최근 30개, 1 = 틀림
 "freeze": {"en": {"tokens": 1, "frozen": ["2026-10-14"], "awarded": 0}, "ja": {"tokens": 1, "frozen": [], "awarded": 0}},
 "missions": {"cafe_order": {"stars": 2, "plays": 3, "last": "2026-10-16", "done_goals": ["greet", "order_drink"]}}}
```
- `days`는 400일까지만 보관(그 전은 저장할 때 삭제). `phon`은 언어당 80개 소리까지. 숫자가 아닌 값·음수·NaN은 읽을 때 0으로 고친다.
- 점수 집계 규칙: `transcript`가 빈 문자열이거나 `units`가 배열이 아니면 **집계하지 않음**(무음 녹음이 점수 0으로 통계를 망치지 않게). `ph` 항목은 `p`가 비어 있지 않은 것만.
- 저장은 30초 간격 + 화면 전환 시. 앱이 강제 종료돼도 최대 30초 손실.

**공부 시간(`StudyClock`)**: 5초마다 점검. 창에 포커스가 있고, 최근 45초 안에 입력이 있었거나 `Recorder.recording`/`Tts.playing`/`Api.active_count > 0`이면 그 5초를 `StudyLog.add_seconds(Store.lang(), 현재 뷰, 5)`로 더함. 현재 뷰는 부모(`main.gd`)의 `current` 값. 자정을 넘기면 새 날짜로 기록.

**사용하는 기존 함수**: `Store.did_day/mark_today/streak/xp/lang`, `Plan.today_days/days_to_iso/iso_to_days/monday_of`, `Store.changed` 신호(레슨·대화 횟수 변화 감지), `Backend`.

**호환·초기 상태**: `studylog.json`이 없으면 과거 기록은 없는 상태(기존 `days`의 연속 일수는 `Store.progress.days`에서 계산하므로 그대로 보임). 보호권은 처음 1개.

---

### F6. 교정 자동 카드 (소기능)

- 대화에서 "더 자연스럽게" 상자(`fix`)가 붙을 때마다 그 문장을 복습 카드로 추가(`Store.add_review`, `note`=`fix_ko`). 이미 있는 문장은 중복 제외(기존 규칙).
- 한 대화당 최대 8개, 설정 `auto_fix_cards`(기본 켬)로 끌 수 있음. 로직은 새 파일 `FixCards.add(lang, msg)` 안에 두고 TalkView에는 한 줄 호출만 둔다.
- 주의: `Progress.MAX_REVIEW = 300`을 넘으면 가장 오래된 카드가 조용히 지워진다(확인함). 자동 카드가 늘면 이 한도가 빨리 찬다 → 연결 지점 표의 "300 → 1000" 권장.

---

## 6. 파일 구조 (신규 파일 전부)

| 영역 | 파일 | 클래스/역할 |
|---|---|---|
| Godot core | `godot/scripts/core/study_log.gd` | `StudyLog` 정적 API + 저장 |
| | `godot/scripts/core/streak_calc.gd` | `StreakCalc` 순수 계산 |
| | `godot/scripts/core/phoneme_stats.gd` | `PhonemeStats` 음소 집계 순수 함수 |
| | `godot/scripts/core/study_clock.gd` | `StudyClock` 노드(공부 시간) |
| | `godot/scripts/core/fix_cards.gd` | `FixCards` (F6) |
| | `godot/scripts/core/mission_logic.gd` | `MissionLogic` 별점·XP·대본 진행 순수 함수 |
| Godot ui | `godot/scripts/ui/goal_card.gd`, `mini_chart.gd` | `GoalCard`, `MiniChart` |
| Godot 뷰 | `godot/scripts/views/stats_view.gd` | `StatsView` ("기록" 탭) |
| | `godot/scripts/views/practice_view.gd` | `PracticeView` ("연습" 탭, 허브) |
| Godot 연습 | `godot/scripts/practice/speak_drill.gd` | `SpeakDrill` (듣기→녹음→/score→/prosody 공용 부품) |
| | `godot/scripts/practice/shadow_screen.gd`, `dictation_screen.gd`, `dictation_diff.gd`, `phoneme_screen.gd`, `mission_screen.gd` | 각 화면 |
| Godot 테스트 | `godot/tests/{streak,study_log,stats_view,practice,dictation,mission}_test.{gd,tscn}` + `sample_*.json` | 아래 합격 조건 참조 |
| 백엔드 | `backend/practice.py`, `backend/missions.py` | 라우터 2개 |
| | `backend/content/missions.json`, `backend/content/phoneme_drills.json` | 콘텐츠 |
| | `backend/test_practice.py`, `backend/test_missions.py` | 테스트 |

`.gd` 파일마다 `.gd.uid`가 같이 생긴다(저장소가 추적함). 커밋에 포함.

---

## 7. 연결 지점 (기존 파일 수정 목록) — 안드로이드 작업과 합칠 때 오케스트레이터가 처리

작업자는 이 표의 파일을 **고치지 않는다**. 오케스트레이터가 안드로이드 변경이 합쳐진 뒤 한 번에 적용한다(담당 T5).

| # | 파일 | 위치 | 바꿀 내용 | 겹칠 위험 |
|---|---|---|---|---|
| C1 | `godot/scripts/main.gd` | `TABS` 상수 | `["practice","연습"]`을 `talk` 다음에, `["stats","기록"]`을 `review` 다음에 추가 | 높음(안드로이드가 탭/하단 내비 변경) |
| C2 | 〃 | `views = {...}` 딕셔너리 | `"practice": PracticeView.new(), "stats": StatsView.new(),` 두 줄 | 높음 |
| C3 | 〃 | `_ready()`에서 `_build_toast()` 앞 | `add_child(StudyClock.new())` 한 줄 | 중간 |
| C4 | `backend/server.py` | `app = FastAPI(...)` 정의와 `/examples` 라우트 뒤 | `import practice, missions` + `practice.init(log=log, ApiError=ApiError, ja_reading=ja_reading, readmode=readmode, lesson_rules=lesson_rules, features=features)` + `missions.init(log=log, ApiError=ApiError, ollama_json=ollama_json)` + `app.include_router(practice.router); app.include_router(missions.router)` | 높음(페어링 라우터/인증 미들웨어 근처). 새 라우터는 안드로이드의 인증 미들웨어 아래에 있어야 하며(추측) 라우터 자체에 인증 코드를 넣지 않았다 |
| C5 | `godot/scripts/views/lesson_view.gd` | `_on_recorded`의 `speak_result = res["data"]` 바로 뒤(약 911행) | `StudyLog.add_score(lang, speak_result, "lesson")` | 중간(세로 레이아웃 수정) |
| C6 | 〃 | `finish_lesson()`의 `ok_count = ok` 뒤(약 330행) | `StudyLog.add_lesson(lang, ok, results.size())` | 중간 |
| C7 | `godot/scripts/views/review_view.gd` | `_on_recorded`의 `score_result = res["data"]` 뒤(약 419행) | `StudyLog.add_score(lang, score_result, "review")` | 중간 |
| C8 | `godot/scripts/views/talk_view.gd` | `_apply_reply`의 `(last as Dictionary)["fix_ko"] = ...` 뒤(약 432행)와 `_request_fix`의 `m["fix_ko"] = ...` 뒤(약 472행) | `FixCards.add(lang, <그 메시지 딕셔너리>)` 각 한 줄 | 중간 |
| C9 | `godot/scripts/autoload/store.gd` | `reset_progress()` 끝 | `StudyLog.reset()` | 낮음 |
| C10 | `godot/scripts/views/today_view.gd` | `_build()`의 `c.add_child(_hero(pos))` 뒤 | `c.add_child(GoalCard.compact(Store.lang()))` | 높음(Today 레이아웃) |
| C11 | 〃 | `_lang_card`의 `Store.streak(l)` | `StudyLog.streak(l)`로 교체 (보호된 연속 일수 표시) | 높음 |
| C12 | `godot/scripts/core/progress.gd` | `MAX_REVIEW := 300` | `1000`으로 (권장, 아래 열린 질문 Q3) | 낮음 |
| C13 | `API.md`, `README.md`, `ROADMAP.md` | 엔드포인트 절 / 표 / v1.1 후보 | 신규 엔드포인트 문서, 기능 표 4줄, 완료 항목 이동 | 중간(문서 충돌) |

**기존 테스트는 고치지 않는다**: `smoke.gd`의 `_test_views`는 뷰 목록을 하드코딩(`TodayView … ReadingView`, `get_child(2)`가 TalkView)하므로 `main.gd`가 아니라 이 목록을 건드리지 않는 한 영향 없음.

---

## 8. 작업 분할

### 8.1 단계와 동시성

```
T0 (stub, 15분) ─┬─► T1 (core+통계)   ─┐
                 ├─► T3 (연습 허브·쉐도잉·받아쓰기·약한 소리) ─┤
T2 (백엔드) ─────┘                     │   Phase 1: T1, T2, T3 동시 (3명)
        └─► T2b (콘텐츠 데이터)         │   Phase 2: T4, T2b 동시 (T1, T3 검토와 병행)
T0 ─► T4 (미션 화면) ───────────────────┤
                                       └─► R (독립 검토) ─► T5 (연결 지점, 오케스트레이터) ─► R5 (통합 검토)
```

| 작업 | 담당 | 시작 조건 | 동시 가능 |
|---|---|---|---|
| T0 | worker | 즉시 | 단독 먼저(15분). T1·T3·T4가 컴파일 오류 없이 시작하게 하는 뼈대 |
| T1 | worker-hard | T0 완료 | T2, T3와 동시 |
| T2 | worker-hard | 즉시(T0과 무관) | T0, T1, T3와 동시 |
| T3 | worker-hard | T0 완료 | T1, T2와 동시 |
| T2b | worker | T2의 검사기 통과(`test_missions.py --lint`, `test_practice.py --lint`가 있어야 함) | T4와 동시 |
| T4 | worker-hard | T0 완료, T2의 응답 계약은 이 문서 사용(고정 JSON으로 개발) | T2b와 동시. T1·T3와 파일 겹침 없음 |
| T5 | 오케스트레이터 | T1~T4 검토 합격 + 안드로이드 합치기 | 단독 |
| R1~R4 | reviewer | 각 작업 완료 후 새 컨텍스트 | 서로 동시 가능 |
| R5 | reviewer | T5 후 | 단독 |

### 8.2 파일 소유권 (겹침 없음)

| 작업 | 수정 허용 파일 (이것만) | 금지 |
|---|---|---|
| T0 | `godot/scripts/core/study_log.gd`(뼈대), `core/phoneme_stats.gd`(뼈대), `godot/scripts/practice/mission_screen.gd`(뼈대) | 그 외 전부 |
| T1 | `core/study_log.gd`, `core/phoneme_stats.gd`, `core/streak_calc.gd`, `core/study_clock.gd`, `core/fix_cards.gd`, `ui/goal_card.gd`, `ui/mini_chart.gd`, `views/stats_view.gd`, `godot/tests/{streak_test,study_log_test,stats_view_test}.{gd,tscn}`, `godot/tests/sample_studylog*.json` | 7절 표의 기존 파일, T2~T4 소유 파일 |
| T2 | `backend/practice.py`, `backend/missions.py`, `backend/test_practice.py`, `backend/test_missions.py`, `backend/content/missions.json`(뼈대 2개), `backend/content/phoneme_drills.json`(뼈대 3개) | `server.py` 포함 기존 파일 전부 (연결은 T5) |
| T2b | `backend/content/missions.json`, `backend/content/phoneme_drills.json` | 그 외 전부 (검사기도 수정 금지) |
| T3 | `views/practice_view.gd`, `practice/speak_drill.gd`, `practice/shadow_screen.gd`, `practice/dictation_screen.gd`, `practice/dictation_diff.gd`, `practice/phoneme_screen.gd`, `godot/tests/{practice_test,dictation_test}.{gd,tscn}`, `godot/tests/sample_practice_*.json`, `godot/tests/sample_phoneme_*.json` | `mission_screen.gd`, T1 소유 파일, 7절 기존 파일 |
| T4 | `practice/mission_screen.gd`, `core/mission_logic.gd`, `godot/tests/mission_test.{gd,tscn}`, `godot/tests/sample_mission_*.json` | T1·T3 소유 파일, 7절 기존 파일 |

- T0이 만든 뼈대의 소유권은 T0 완료 후 T1(`study_log`, `phoneme_stats`)과 T4(`mission_screen`)로 넘어간다.
- 모든 작업자 공통 금지: 프로세스는 이름으로 끄지 않고 자기가 시작한 PID만 종료, 포트 8770 사용 금지, 테스트 서버는 쓰기 전 포트가 비었는지 확인, 비밀값 출력 금지, 임시 파일은 `scratchpad\w_<작업명>\`에만, `Recorder`/`Tts`/`Api`/`Backend` 내부 수정 금지.

### 8.3 PracticeView ↔ 화면 계약 (T3와 T4가 서로 모르고 만들 수 있게)

- 허브 `PracticeView`(T3)는 하위 화면을 `add_child` 하고 `closed` 신호를 받으면 허브로 돌아온다.
- 모든 하위 화면은 `extends Control`, 신호 `closed`, 메서드 `open(lang: String, args: Dictionary = {})`, 선택 메서드 `on_hide()`를 가진다. `MissionScreen`(T4)도 같은 형태. T3는 `MissionScreen.new()`만 호출한다.
- 다른 화면에서 허브의 특정 항목으로 보내기: `PracticeView.pending = {"kind": "phoneme", "p": "θ"}`(정적 변수) 설정 후 `Store.navigate.emit("practice", lang)`. `kind` ∈ `mission|shadow|dictation|phoneme`.

### 8.4 StudyLog 공개 함수 (T0이 뼈대로 만들고 T1이 구현)

| 함수 | 반환 | 설명 |
|---|---|---|
| `reload()` / `flush()` / `reset()` | void / bool / void | 읽기 / 저장(바뀐 것이 있을 때) / 전부 삭제 |
| `static var path` | String | 기본 `user://studylog.json` (테스트가 바꿈) |
| `add_seconds(lang, view, sec)` | void | 공부 시간 |
| `add_event(lang, kind, n=1)` | void | `kind` ∈ lessons, talks, missions, reviews, shadow, dictation, drill |
| `add_lesson(lang, ok, total)` | void | 레슨 정답률 |
| `add_score(lang, res, source)` | bool | `/score` 응답 집계. 집계했으면 true |
| `add_mission(lang, id, stars, done_goals)` | void | |
| `mission_best(id)` | Dictionary | `{stars, plays, last, done_goals}`, 없으면 `{}` |
| `goal_minutes()` / `set_goal_minutes(m)` | int / void | 0=끔 |
| `today_seconds(lang)` | int | |
| `settle(lang)` | Dictionary | 보호권 적용 `{streak, tokens, used, gained}` |
| `streak(lang)` / `tokens(lang)` | int | |
| `range_summary(lang, days)` | Array | 오래된 날부터 `{iso, sec, lessons_ok, lessons_n, score_n, score_sum, n:{...}}` |
| `weak_phonemes(lang, limit, min_n=5)` | Array | `{p, n, bad, rate, heard:{}}` 틀린 비율 순 |

`PhonemeStats`: `blank()`, `observe(stats, res) -> int`(집계한 음소 수), `weakest(stats, limit, min_n) -> Array`.
`StreakCalc.settle(done:Dictionary, frozen:Dictionary, tokens:int, awarded:int, today:int) -> {frozen, tokens, used, streak, awarded, gained}` (`done`/`frozen`은 일수(`Plan` 일 번호) → true).

---

## 9. 작업별 합격 조건 (O/X)

### 9.0 공통 실행 방법

```powershell
# Godot 헤드리스 (종료 코드 0 = 전부 통과, 마지막 줄 "== <이름> result: N passed, 0 failed ==")
$GODOT = 'C:\Users\rtyu6\Desktop\Godot_v4.6.3-stable_win64.exe\Godot_v4.6.3-stable_win64_console.exe'
$G = 'D:\Ai\언어\app\godot'
& $GODOT --headless --path $G res://tests/streak_test.tscn ; $LASTEXITCODE
# 서버가 필요한 라이브 검사: 맨 뒤에 -- --api=http://127.0.0.1:<빈 포트>  (8770 금지)

# 백엔드 테스트 서버 (포트는 비어 있는지 먼저 확인, PID는 시작할 때 받은 값만 종료)
$PY = 'D:\Ai\언어\app\backend\.venv\Scripts\python.exe'
Get-NetTCPConnection -LocalPort 8811 -ErrorAction SilentlyContinue        # 출력 없어야 함
$srv = Start-Process -PassThru -WindowStyle Hidden $PY -ArgumentList '-X','utf8','D:\Ai\언어\app\backend\server.py','--port','8811','--tag','w_t2','--stt-cpu'
& $PY D:\Ai\언어\app\backend\test_practice.py --base http://127.0.0.1:8811
Stop-Process -Id $srv.Id
```
- 포트 배정(충돌 방지): T2=8811, T1/T3 라이브=8812/8813, T4=8814, 검토자=8821~8824. 모든 보고에 "남은 프로세스·열린 포트 없음" 확인(`Get-NetTCPConnection -LocalPort <포트>` 출력 없음)을 적는다.
- **현재 서버 코드는 `practice`/`missions` 라우터를 모른다(연결 전).** T2는 자기 테스트 서버에서만 연결을 임시로 하는 대신, 임시 진입 파일 `scratchpad\w_t2\serve.py`(저장소 밖; 실행은 `backend` 폴더를 `PYTHONPATH`에 넣어서)를 만들어 `server.app`에 라우터를 붙여 띄운다. 구체: `import server, practice, missions; practice.init(...); missions.init(...); server.app.include_router(...); uvicorn.run(server.app, port=8811)`. 이 방법으로 `server.py`를 건드리지 않는다. T5 이후 R5는 정식 `server.py`로 같은 테스트를 다시 돌린다.

### T0 (worker) 뼈대

| ID | 조건 | 확인 | 기대 |
|---|---|---|---|
| T0-1 | 8.4의 `StudyLog` 함수 17개가 정확한 이름·인자로 있음 | `Select-String -Path $G\scripts\core\study_log.gd -Pattern '^static func (reload\|flush\|reset\|add_seconds\|add_event\|add_lesson\|add_score\|add_mission\|mission_best\|goal_minutes\|set_goal_minutes\|today_seconds\|settle\|streak\|tokens\|range_summary\|weak_phonemes)\(' \| Measure-Object` | Count = 17 |
| T0-2 | 뼈대는 아무것도 하지 않고 오류 없이 값을 돌려줌 | 헤드리스 짧은 스크립트가 아니라 `smoke.tscn` 실행 | 종료 코드 0, 기존 smoke 통과 수가 T0 전과 같음 |
| T0-3 | `MissionScreen`이 신호 `closed`, 메서드 `open(lang, args)`을 가짐 | `Select-String -Path ...mission_screen.gd -Pattern 'signal closed','func open\('` | 2줄 일치 |
| T0-4 | 금지: 위 3개 외 파일 변경 없음 | `git -C D:\Ai\언어\app status --short` | 신규 파일(.gd와 .uid) 3쌍만 |

### T1 (worker-hard) Godot core + 통계

| ID | 조건 | 확인 | 기대 |
|---|---|---|---|
| T1-1 | 연속 기록 계산 표 15건 이상 통과: 안 놓침 / 1일 놓침+보호권1 → 이어짐 / 2일 놓침+보호권1 → 끊김 / 오늘 아직 안 함은 안 끊김 / 공부 이력 없음 → 보호권 안 씀 / 7일 달성 시 +1 / 최대 2개 / 연속이 끊긴 뒤 재달성 때 다시 지급 / 같은 날 두 번 `settle` → 결과 동일(멱등) / 시계가 과거로 되돌려짐 → 변화 없음 / 윤일 경계 / 4000일 연속 데이터도 즉시 | `& $GODOT --headless --path $G res://tests/streak_test.tscn` | `== streak result: N passed, 0 failed ==`, N ≥ 15, 종료 코드 0 |
| T1-2 | **일부러 틀린 저장 파일**: (a) 쓰레기 텍스트 (b) 빈 파일 (c) `v:99` + 알 수 없는 키 (d) `days`가 배열 (e) `sec`가 문자열/NaN/음수 (f) `phon.en.θ.h`가 숫자 → 앱이 멈추지 않고, (a)(b)(d)는 빈 상태로 시작, (a)는 `.bad` 파일이 생김, (c)는 저장 후에도 알 수 없는 키 보존, (e)(f)는 0/빈 값으로 고침 | `& $GODOT ... res://tests/study_log_test.tscn` | 6건 PASS, `SCRIPT ERROR` 로그 0건 |
| T1-3 | `add_score`: `godot/tests/sample_score_en_ph.json`(기존 픽스처)로 `θ` 항목이 생기고, `{}`, `null`, `units` 없음/배열 아님, `ph` 항목에 `p` 없음, `transcript:""` 응답은 집계 안 함(반환 false)·오류 없음 | 〃 | PASS |
| T1-4 | `weak_phonemes`: 표본 4개짜리는 제외(min_n=5), 틀린 비율 내림차순, 같으면 표본 많은 순; 400일 넘은 날 데이터는 저장 시 삭제; `reset()` 후 파일이 비어 있음 | 〃 | PASS |
| T1-5 | `StudyClock.tick(delta, active)`: 입력 없음·창 포커스 없음일 때 초가 안 늘고, 활성일 때 5초 단위로 늘며, 자정을 넘으면 새 날짜로 기록 | 〃 | PASS |
| T1-6 | `StatsView`가 412×915 와 1280×800 에서 (빈 기록 / 풍부한 기록 `sample_studylog.json`) 4가지 조합 모두 오류 없이 생성, L1·L2 레이아웃 검사 통과, 언어 전환·창 크기 변경 후 재생성 오류 없음 | `& $GODOT ... res://tests/stats_view_test.tscn` | `0 failed`, `SCRIPT ERROR` 0건 |
| T1-7 | `FixCards.add`: 같은 문장 두 번 → 카드 1개, 한 대화 8개 초과 안 늘어남, `auto_fix_cards=false`면 추가 안 함, `fix`가 원문과 같으면 추가 안 함 | `study_log_test.tscn` 안 | PASS |
| T1-8 | 금지: 7절의 기존 파일 변경 없음, 새 파일 외 변경 없음 | `git status --short` | 허용 파일 목록 안에만 변경 |
| T1-9 | 기존 테스트 회귀 없음 | `smoke`, `fsrs_test`, `review_walk_test` 각각 실행 | 종료 코드 0 |

### T2 (worker-hard) 백엔드

| ID | 조건 | 확인 | 기대 |
|---|---|---|---|
| T2-1 | `--base` 없이 실행하면 거부, 8770은 거부 | `& $PY backend\test_practice.py` / `... --base http://127.0.0.1:8770` | 둘 다 종료 코드 ≠ 0, 메시지에 `--base` / `refused` |
| T2-2 | `GET /practice/ping` → `{"ok":true,"practice":1,"missions":1,"tatoeba":bool}` | `test_practice.py` | PASS |
| T2-3 | 문장 API: `lang=en&mode=shadow&stage=1&n=8` → 8개, id 중복 없음, 각 문장 단어 수가 `EN_LEN[1]`(3~7) 안, `ko`에 한글, `url`이 `https://tatoeba.org/sentences/show/`로 시작, `attribution` 있음 | 〃 | PASS |
| T2-4 | `mode=dictation`: 숫자 없음, 첫 단어·`I` 외 대문자 단어 없음, 3~10단어. `lang=ja&mode=dictation` → 400 + 한글 `error` | 〃 | PASS |
| T2-5 | `exclude` 적용 시 이전 결과와 겹침 0, 같은 `seed`는 같은 id 목록, 일본어 shadow는 `reading`이 히라가나만이고 비어 있지 않음 | 〃 | PASS |
| T2-6 | **틀린 입력**: `lang=xx`, `mode=foo`, `mode` 없음, `stage=-3`/`9`, `n=0`/`999`, `exclude=a,,1,%00`, 매우 긴 `exclude`(5000자) → 400 또는 보정된 200만, **500 없음**, 오류 본문은 모두 `{"error": "<한글>"}` | 〃 | 12건 이상 PASS |
| T2-7 | DB 없음/깨짐: 프로세스 안에서 `reading.tatoeba_ready`를 거짓으로 바꿔 부르면 `ApiError 503`(한글), `sqlite3.Error`를 던지게 하면 503이고 `invalidate_tatoeba_ready` 호출됨 | `test_practice.py` 안의 프로세스 내 검사(`--no-extra`로 건너뛸 수 있음) | PASS, 건너뛰면 "SKIP n"이 출력에 나옴 |
| T2-8 | 음소 API: `/practice/phonemes` ≥ 15개(8절 F4의 15개 포함), `/practice/phoneme?p=θ&sentences=3` 구조 일치(`pairs`≥2, `phrases`≥4, `sentences`≤3·각 `ko` 있음), `p` 없음 → 400, `p=zzz` → 404 | 〃 | PASS |
| T2-9 | 콘텐츠 검사(프로세스 내): `phoneme_drills.json`의 각 항목 `words`의 espeak 기대 음소에 `p`(또는 그 대체형)가 들어 있음, 모든 `phrases[].text`에 `words` 중 하나가 포함됨, `words`≥6·`pairs`≥2·`phrases`≥4 (스키마 검사 `--lint` 지원) | `& $PY backend\test_practice.py --lint` | 뼈대 3개 PASS. espeak 불가 시 "미검증"으로 출력하고 종료 코드 ≠ 0 (통과로 치지 않음) |
| T2-10 | 미션 API: `/missions?lang=en` 응답에 `"match"`, `"pos"`, `"neg"`, `"goal_en"` 글자가 **없음**, `scenario.scene`에 `Your opening line was:`가 있음, `lang=ja` → `unsupported:true`, `lang=xx` → 400, `stage` 필터 동작 | `& $PY backend\test_missions.py --base ...` | PASS |
| T2-11 | `/missions/check`: 콘텐츠의 모든 목표에 대해 `pos` 예문은 달성, `neg` 예문은 미달성(실제 HTTP로 전부 돌림); `done` 누적 유지, `new`는 이번에 새로 달성한 것만, 전부 달성하면 `all_done:true` | 〃 | PASS (뼈대 2개 미션 기준 + T2b 후 8개 전부) |
| T2-12 | **틀린 입력**: 빈 `text`/공백 → 400, 알 수 없는 `mission_id` → 404, `done`에 모르는 id·1000개 → 무시(200), 한글만 있는 문장 → 달성 0, 5000자 → 200 + 1초 미만, 정규식 폭탄 입력(`"a"*300+"!"`, `"I'd like "*40`) → 0.5초 미만, 깨진 JSON 본문 → 422 한글, 필드 누락 → 422 | 〃 | 10건 이상 PASS |
| T2-13 | 정규식 정적 검사(`--lint`): 컴파일됨, 중첩 반복(`(.+)+`, `(.*)*`, `(a+)+` 형태) 거부, 목표마다 `pos`≥3·`neg`≥3, `script[].goal`이 존재하는 목표 id, `max_turns ≥ 목표 수 + 3`, `opening`에 한글 없음 | `& $PY backend\test_missions.py --lint` | PASS. 일부러 중첩 반복 패턴을 넣은 임시 JSON을 `--content <경로>`로 주면 FAIL이 나야 함(임시 경로는 scratchpad) |
| T2-14 | `/missions/judge`: AI를 가짜로 바꾼 프로세스 내 검사 — 증거가 `me` 발화에 없으면 `done:false`로 고쳐짐, AI가 `ApiError`를 던지면 라우트가 502/503 + 한글 `error`, `pending` 비면 400, 알 수 없는 미션 404. 실제 AI 호출은 `--ai`일 때만(기본 건너뜀, "SKIP"으로 표시) | 〃 | PASS |
| T2-15 | 금지: `server.py` 및 기존 파일 변경 없음, 새 모듈이 import 시점에 모델·네트워크를 쓰지 않음(`python -c "import practice, missions"`가 3초 안에 끝남) | `git status --short`, 위 명령 | 허용 파일만 변경, 종료 코드 0 |
| T2-16 | 기존 테스트 회귀 없음 | `test_backend.py`, `test_reading.py`, `test_lesson_rules.py --n 20` 를 같은 임시 서버로 | 기존과 같은 통과 수 |

### T2b (worker) 콘텐츠

| ID | 조건 | 확인 | 기대 |
|---|---|---|---|
| T2b-1 | `missions.json` 영어 미션 8개(8절 목록의 id), 미션당 목표 3~5개 | `& $PY backend\test_missions.py --lint` | PASS |
| T2b-2 | `/missions/check` 전체 `pos`/`neg` 통과(T2-11 재실행), 목표 `pos`·`neg` 각 3개 이상 | `test_missions.py --base ...` | PASS |
| T2b-3 | `phoneme_drills.json` ≥ 15개 소리(F4의 15개 포함), 항목 조건 충족 | `& $PY backend\test_practice.py --lint` (+ espeak 실제 사용 가능한 환경) | PASS, "미검증" 0건 |
| T2b-4 | 저작권: 문장·대본은 직접 쓴 것(다른 앱·사이트 문구 복사 금지), 보고에 "복사하지 않음" 확인 | 보고서 | 명시 |
| T2b-5 | 금지: 위 2개 파일 외 변경 없음, 검사기 수정 없음 | `git status --short` | 2개만 |

### T3 (worker-hard) 연습 허브 · 쉐도잉 · 받아쓰기 · 약한 소리

| ID | 조건 | 확인 | 기대 |
|---|---|---|---|
| T3-1 | `DictationDiff.diff` 표 테스트 12건 이상: 동일 문장 100점 / 대소문자·문장부호 무시 / `I would` = `I'd` / 단어 하나 빠짐(빠짐 표시) / 철자 틀림 / 추가 단어(`extra`) / 순서 바뀜 / 빈 문자열(0점·오류 없음) / 공백만 / 정답이 한 단어 / 300자 초과 입력 자름 / 이모지·한글 섞임 | `& $GODOT ... res://tests/dictation_test.tscn` | `0 failed` |
| T3-2 | 허브 `PracticeView`가 412×915, 1280×800 둘 다에서 4개 카드를 만들고 L1·L2 검사 통과; `PracticeView.pending`으로 각 하위 화면이 열림 | `res://tests/practice_test.tscn` | `0 failed` |
| T3-3 | 쉐도잉 픽스처 흐름(서버 없이): 문장 목록 적용 → 점수 응답(`sample_score_en_ph.json`) 적용 → 점수≥70 통과 처리·XP 증가·`StudyLog.add_score` 호출 → 8문장 끝 요약 → 70점 미만 문장이 복습 카드로 추가(최대 5) | 〃 | PASS |
| T3-4 | 구간 반복: 칩 두 개를 눌러 구간 선택/해제, 시작>끝이면 자동 정렬, 구간이 한 칩이면 그 단어만, `/score`의 `target`이 구간 글자 | 〃 | PASS |
| T3-5 | 약한 소리: 약점 데이터가 있으면 칩 표시, 없으면 안내+목록 선택, 응답에 `ph`가 없으면 "음소 분석을 쓸 수 없어요" 안내 후 연습 계속, `ph[p].ok` 개수로 성공 판정 | 〃 | PASS |
| T3-6 | **틀린 입력**: 문장 API가 503/네트워크 오류 → 화면에 한글 안내+[다시 시도], 앱 멈춤 없음; 문장 0개 → "문장이 없어요" 빈 상태; `/score`가 `{}`·`units` 없음·`score:0,transcript:""`(무음) → "소리가 들리지 않았어요", 통계 집계 안 됨; 요청 중 화면 `queue_free()` → 오류 없음; 요청 중 언어 전환 → 이전 응답 무시 | 〃 | 6건 PASS, `SCRIPT ERROR` 0건 |
| T3-7 | 녹음 중 `on_hide()` → 녹음 취소됨(`Recorder.recording == false`) | 〃 | PASS |
| T3-8 | 라이브(선택, `-- --api=http://127.0.0.1:8813`): 실제 서버(연결 지점 임시 적용 서버)에서 문장 8개를 받아 화면에 표시, `/tts`로 첫 문장 재생 요청이 200 | `res://tests/practice_test.tscn -- --api=...` | PASS. `--api` 없으면 "라이브 건너뜀" 출력 |
| T3-9 | 금지: 기존 파일·T1/T4 소유 파일 변경 없음; `Recorder`/`Tts` 내부 변수 접근 없음 | `Select-String -Path practice\*.gd,views\practice_view.gd -Pattern 'Recorder\._\|Tts\._'` | 0건 |
| T3-10 | 기존 테스트 회귀 없음 | `smoke`, `lesson_source_test`, `review_walk_test` | 종료 코드 0 |

### T4 (worker-hard) 미션 화면

| ID | 조건 | 확인 | 기대 |
|---|---|---|---|
| T4-1 | `MissionLogic` 표 테스트 12건: 별 계산(r=1·한도 이내 → 3, 한도 초과 → 2, r=0.6 → 2, r=0.5 → 1, r=0 → 0), XP 공식, 수동 체크 포함, 대본 모드 진행(통과/3번 실패 후 모범 답으로 넘어감), 목표 0개 미션(방어) | `& $GODOT ... res://tests/mission_test.tscn` | `0 failed` |
| T4-2 | 픽스처 흐름: 미션 목록 적용 → 시작(첫 마디 `opening` 즉시 표시, `/chat` 호출 없음) → 사용자 말 추가 시 `/missions/check`와 `/chat` 요청이 **둘 다** 나가고(요청 기록으로 확인), 체크 결과가 AI 답보다 먼저 목표 목록에 반영 | 〃 | PASS |
| T4-3 | 종료: 모든 목표 달성 → 종료 화면; `/feedback` 실패(502) → 별점·목표 결과는 보이고 "피드백을 불러오지 못했어요" + [다시 시도]; 성공 시 `corrections`가 `Store.add_review`로 들어가고(중복 제외) XP·`mark_today`·`StudyLog.add_mission` 호출 | 〃 | PASS |
| T4-4 | **AI 없음 경로**: `/chat` 503 또는 `Backend`가 LLM 없음 → [대본 모드] 버튼이 나타나고, 대본 모드로 처음부터 끝까지(`AI 호출 0회`, 요청 기록으로 `/chat`·`/feedback` 없음 확인) 완료 가능 | 〃 | PASS |
| T4-5 | **틀린 입력**: `/missions/check` 404/네트워크 오류 → 목표 체크는 무시하고 대화 계속(수동 체크 가능); 빈 입력 보내기 무시; 보내기 두 번 연타 → 한 번만; `/chat`이 `{}`나 `reply` 빈 값 → 한글 오류+[다시 보내기]; 미션 목록 `missions:[]`/`unsupported:true` → 안내 문구; `lang=ja` → 안내; 서버가 오래된 버전(404) → "PC 프로그램을 최신 버전으로 업데이트해 주세요" | 〃 | 7건 PASS |
| T4-6 | 레이아웃: 412×915 에서 목표 패널이 접힌 한 줄, 1280×800 에서 오른쪽 패널; L1·L2 검사 통과; 크기를 바꿔도 대화 내용 유지 | 〃 | PASS |
| T4-7 | `judge`: 버튼은 규칙으로 못 잡은 목표가 있을 때만, 응답의 `done` 목표가 "AI 판정"으로 표시, 오류 시 규칙 결과 유지+안내 | 〃 | PASS |
| T4-8 | 금지: 기존 파일·T1/T3 소유 파일 변경 없음; TalkView 코드 복사는 되지만 TalkView 수정 없음 | `git status --short` | 허용 파일만 |
| T4-9 | 라이브(선택, `-- --api=...8814`): 실제 `/missions`를 받아 목록 표시, `/missions/check` 한 번 호출 성공(연결 지점 임시 적용 서버) | 〃 | PASS 또는 "건너뜀" |

### T5 (오케스트레이터) 연결 지점 적용

| ID | 조건 | 확인 | 기대 |
|---|---|---|---|
| T5-1 | 7절 C1~C13을 안드로이드 변경이 합쳐진 상태에서 적용, 각 변경이 표에 적은 줄 수 이내 | `git diff --stat` | 기존 파일 변경 합계 약 20줄 이하(문서 C13 제외) |
| T5-2 | 정식 `server.py`로 `test_practice.py`, `test_missions.py`, `test_backend.py`, `test_reading.py`, `test_lesson_rules.py` 전부 통과 | 임시 서버(빈 포트) | 모두 종료 코드 0 |
| T5-3 | Godot 전체: `smoke`, `fsrs_test`, `review_walk_test`, `prosody_test`, `reading_test`, `lesson_source_test`, 신규 6개 | 각 `.tscn` | 모두 종료 코드 0 |
| T5-4 | 탭 8개가 최소 창 너비 900에서 잘리지 않음 | 헤드리스로 `main.tscn`을 900×600에 올려 상단 바 `get_combined_minimum_size().x` 측정 | ≤ 900 (안드로이드가 하단 내비로 바꿨으면 해당 방식으로 확인) |
| T5-5 | 배포 포함 확인: `backend/content/*.json`, `practice.py`, `missions.py`가 설치 zip에 들어감, `test_*.py`는 빠짐 | `build_dist.ps1` 드라이런 후 `packaging\check_zip.py` 및 zip 목록 확인 | 3개 포함, test 제외 |
| T5-6 | `studylog.json`이 없는 새 설치와 v1.0.1에서 업데이트한 설치(진행 파일만 있음) 둘 다 첫 실행 오류 없음 | 새 `user://` 폴더로 실행 | 오류 0, 보호권 1개로 시작 |
| T5-7 | 공개 전 점검: 올라갈 파일 목록에 비밀값·`studylog.json`·로그·캐시 없음 | 기존 공개 스크립트의 비밀값 검사 | 통과 |

### R1~R5 (reviewer)
각 검토는 새 컨텍스트에서 원래 합격 조건과 변경 파일만 보고 위 명령을 **직접 다시 실행**해 O/X를 판정한다. 검사기(`test_*.py`, `*_test.gd`)는 반드시 일부러 틀린 입력(망가진 JSON 저장 파일, 중첩 반복 정규식 JSON, 빈 오디오 응답, 뒤집은 기대값)을 하나 이상 넣어 **실제로 FAIL이 나는지** 확인한다(통과만 확인한 검사기는 믿지 않는다).

---

## 10. 위험 요소와 대안

| # | 위험 | 영향 | 대안 / 대응 |
|---|---|---|---|
| 1 | 규칙 체크의 오탐·미탐(학습자 표현이 다양함) | 미션 목표가 안 찍히거나 잘못 찍힘 | 수동 체크 + "AI로 다시 판정"(증거 문장 검증), 각 목표 `pos/neg` 3개 이상을 검사기가 강제. 목표는 "한 문장 표현" 단위로 작게 |
| 2 | OpenCode 세션이 미리 쓴 `opening`을 모를 수 있음 (`_chat_opencode`는 새 메시지만 보냄, 첫 호출이 전체 history를 보내는지는 **확인 못 함**) | 상대가 첫 마디와 다른 말을 함 | `scene`에 첫 마디를 명시. T4 라이브 검사에서 첫 응답이 상황에 맞는지 눈으로 확인(보고에 대화 3턴 첨부) |
| 3 | 단독 단어 음소 인식 불안정 (API.md에 명시) | F4 성공 판정 오류 | 구절(2~4단어) 중심 연습, 한 번 틀려도 "다시"로 표시만 하고 숙련도 판정에 쓰지 않음 |
| 4 | 구간 듣기는 부분 합성이라 억양이 문장 안과 다름 | 쉐도잉 정확도 | 화면 안내 한 줄. 구간 오디오 잘라 재생은 `tts.gd` 수정이 필요해 v1.2로 미룸 |
| 5 | 자동 녹음 시작이 스피커 소리를 같이 녹음 | 점수 하락 | 기본 끔 + 이어폰 안내 |
| 6 | 복습 카드 한도 300에서 오래된 카드 조용히 삭제 | 자동 카드로 학습 기록 손실 | C12 한도 1000 권장, 대화당 8개 제한 |
| 7 | `Progress.normalize()`가 모르는 키 삭제 | 통계를 progress.json에 넣으면 사라짐 | 별도 `studylog.json` (이미 반영) |
| 8 | 탭 8개로 상단 바가 좁은 창에서 넘침 | 900px에서 잘림 | T5-4 측정, 넘치면 "기록"을 `오늘` 안 카드로 이동하거나 "더보기" 사용(안드로이드 내비 방식과 맞춤) |
| 9 | 안드로이드 작업과 `main.gd`, `server.py`, `today_view.gd` 충돌 | 합치기 지연 | 7절 연결 지점만 수정, 신규 파일은 고유 이름. 안드로이드 설계 확인 후 C1~C4 위치 재조정 |
| 10 | 폰(앱 v1.1)이 PC 서버(v1.0.1)에 붙는 버전 불일치 (추측) | 신규 API 404 | `GET /practice/ping` 확인 후 안내 문구 |
| 11 | 시계 조작·자정 경계 | 보호권 부정 사용·날짜 오류 | 과거로 되돌림은 무시, 미래 날짜 기록은 오늘로 처리하지 않음, `StudyClock`이 매 점검에서 날짜 재계산, 순수 함수 테스트 |
| 12 | 공부 시간 오측정(방치) | 목표 달성 오판 | 최근 45초 입력/녹음/재생/요청 중일 때만 가산, 창 포커스 없으면 가산 안 함. 목표 달성은 기록 인정일 뿐 보상 없음 |
| 13 | 정규식 폭탄(ReDoS) | 서버 응답 지연 | 입력 300자 제한, 패턴 정적 검사, 시간 검사(0.5초) |
| 14 | `backend/data/`가 git·배포에서 제외됨 | 콘텐츠 누락 배포 | `backend/content/` 사용, T5-5에서 zip 포함 확인 |
| 15 | 작업량 과다 | 일정 지연 | 컷 순서: (1) `/missions/judge`와 화면 버튼 (2) 쉐도잉 자동 녹음 옵션 (3) 통계 꺾은선 차트(막대만) (4) 약한 소리의 Tatoeba 예문(구절만) — 각 컷은 다른 기능에 영향 없음 |
| 16 | Tatoeba 한국어 번역 품질 | 어색한 `ko` | 레슨 풀이 이미 `ko` 필터(`_ko_clean`)를 거침. 같은 풀 재사용 |

### 10.1 일부러 틀린 입력으로 확인할 실패 시나리오 모음

| 영역 | 입력 | 기대 |
|---|---|---|
| 서버 | `/practice/sentences?lang=xx`, `mode` 없음, `n=999`, `exclude=a,,1,%00`, 5000자 `exclude` | 400 또는 보정 200, 500 없음, 한글 `error` |
| 서버 | Tatoeba DB 없음/깨짐 | 503 한글, 레슨 등 다른 기능 영향 없음 |
| 서버 | `/missions/check` 빈 text, 모르는 미션, 5000자, 정규식 폭탄 문자열, 깨진 JSON | 400/404/200(자름)/0.5초 미만/422 |
| 서버 | `/missions/judge`에서 AI가 없는 증거 문장을 지어냄 | `done:false`로 정정 |
| 서버 | AI 엔진 없음(Ollama·OpenCode 모두 불가)에서 `/missions`, `/practice/*`, `/missions/check` | 모두 200 (AI 불필요) |
| 저장 | 깨진/빈/미래 버전/타입이 틀린 `studylog.json` | 앱 정상 시작, 빈 상태 또는 값 보정, `.bad` 파일 보존 |
| 저장 | 시계가 과거·미래로 점프 | 보호권 소모·지급 없음/중복 지급 없음 |
| 채점 | 빈 오디오 응답(`score:0`, `transcript:""`, `units:[]`), `ph` 없음, `ph.p` 없음 | 통계 불변, 안내 문구, 멈춤 없음 |
| 화면 | 요청 중 `queue_free`, 언어 전환, 화면 이탈 | 오류 로그 0, 녹음 취소 |
| 화면 | 받아쓰기에 이모지·한글·300자 초과·빈 입력 | 자르거나 무시, 0점 처리 |
| 화면 | 같은 버튼 연타(보내기·확인·다음) | 한 번만 처리 |

---

## 11. 작업량 추정 (추측)

| 작업 | 새 코드 | 에이전트 시간 | 비고 |
|---|---|---|---|
| T0 | GDScript 약 80줄 | 0.3h | |
| T1 | GDScript 약 1,100줄 + 테스트 500줄 | 5~6h | 순수 계산이라 검증이 쉬움 |
| T2 | Python 약 650줄 + 테스트 600줄 | 5~6h | 정규식 검사기와 폭탄 시험 포함 |
| T2b | JSON 약 600줄 (미션 8개, 소리 15개) | 2~3h | 문장 직접 작성, espeak 검증 반복 |
| T3 | GDScript 약 1,700줄 + 테스트 500줄 | 7~9h | 가장 큼 (SpeakDrill + 화면 3개 + 허브) |
| T4 | GDScript 약 900줄 + 테스트 400줄 | 5~6h | |
| T5 | 기존 파일 약 20줄 | 1h (오케스트레이터) | 안드로이드 합치기 후 |
| 검토 4~5회 | | 각 1~1.5h | 불합격 시 되돌림 1~2회 가정 |

합계 약 30~38 에이전트 시간. 3명 병렬이면 달력상 약 12~16시간(검토·되돌림 포함). 컷 순서(위험 #15)를 적용하면 약 20% 줄일 수 있다.

### 11.1 XP·기록 표 (참고)

| 활동 | XP | `mark_today` 조건 | `StudyLog.add_event` |
|---|---|---|---|
| 미션 | 20 + 10×목표 + 10×별 (최대 80) | 목표 ≥1 달성 또는 학습자 턴 ≥3 | `missions` |
| 쉐도잉 | 통과 문장당 +3 (세션 최대 24) | 시도 ≥5문장 | `shadow` |
| 받아쓰기 | 통과 문장당 +3 (세션 최대 24) | 시도 ≥5문장 | `dictation` |
| 약한 소리 | 세션 완료 +10 | 시도 ≥5회 | `drill` |
| 일일 목표 달성 | 0 | 즉시 | 없음 |

---

## 12.0 오케스트레이터 결정 (2026-10-16, 작업자는 이것을 따른다)

- Q1: 기본안 그대로 (PC 상단 탭 `연습`은 대화 다음, `기록`은 복습 다음). 폰 내비는 안드로이드 설계를 따름 — 탭 연결(C1~C3)은 T5에서.
- Q2: 폰과 PC 기록은 따로 쌓음(v1.1). 동기화는 v1.2 후보.
- Q3: 복습 카드 한도 1000으로(C12, T5에서).
- Q4: 보호권 처음 1개·7일마다 +1·최대 2개, 일일 목표 기본 10분.
- Q5·Q6: 기본안 그대로(일본어는 쉐도잉·목표·통계만, 미션 8개).
- Q7: `/missions/judge` 는 T4·T2 마지막 순서로 구현. 다른 합격 조건을 다 채운 뒤 남은 시간에만, 안 되면 빼고 보고.
- Q8: 라우터 연결(C4)은 안드로이드 인증 구조가 합쳐진 뒤 T5에서 결정. T2는 `init(...)` + `router` 만 제공하고 라우터 안에 인증 코드를 넣지 않는다.
- Q9: 1.1.0 과 문서 갱신은 모든 검토 합격 후 한 번에.
- Q10: `RecorderWidget`·`Recorder.begin()`·`Recorder.finished`·`Tts.*` 공개 함수 모양은 안드로이드 작업에서도 유지하도록 오케스트레이터가 지시한다. 이것만 써라.
- 테스트 포트는 9.0 의 배정을 따른다(T2=8811, T1/T3 라이브=8812/8813, T4=8814, 검토자=8821~8824). 안드로이드 작업은 다른 대역을 쓴다.
- 작업자는 `git commit` 하지 않는다. 오케스트레이터가 검토 후 커밋한다.

## 12. 오케스트레이터가 정해야 할 열린 질문

| # | 질문 | 이 설계의 기본안 |
|---|---|---|
| Q1 | 새 탭 2개("연습", "기록") 위치. 안드로이드 설계의 내비 방식(하단 내비/더보기)과 맞춰야 함 | PC 상단 탭에 둘 다 추가 (`연습`은 대화 다음, `기록`은 복습 다음). 폰은 안드로이드 설계를 따름 |
| Q2 | 연속 기록·통계를 폰과 PC가 따로 쌓는 것을 받아들일지 (폰 `user://`는 별개) | 따로 쌓음. 서버에 저장하는 방식은 계정/동기화 설계가 필요해 v1.2 |
| Q3 | 복습 카드 한도 300 → 1000 변경(C12) | 변경 권장 (자동 카드 때문) |
| Q4 | 보호권 규칙(처음 1개, 7일마다 +1, 최대 2개)과 일일 목표 기본값 10분 | 위 값. 사용자 선호로 조정 가능 |
| Q5 | 일본어 범위: 쉐도잉·목표·통계만 지원, 미션·받아쓰기·약한 소리는 영어만 | 그대로 |
| Q6 | 미션 8개 구성과 단계 배치(8절), 한국인 학습자에게 더 필요한 상황 추가 여부 | 8개 |
| Q7 | `/missions/judge`(AI 판정)를 v1.1에 포함할지 (컷 후보 1순위) | 포함하되 T4 마지막에 구현, 일정이 밀리면 컷 |
| Q8 | `server.py`의 라우터 연결(C4) 방식: 안드로이드 설계가 라우터 분리 구조를 도입했으면 그 구조에 맞춤 | 설계 확인 후 결정 |
| Q9 | 릴리스 번호 1.1.0과 문서(C13) 갱신 시점 | 모든 검토 합격 후 한 번에 |
| Q10 | 안드로이드 작업의 `Recorder` 원격 모드가 `RecorderWidget`/`Recorder.begin()` 공개 함수 모양을 바꾸는지 (바꾸면 T3 `SpeakDrill`의 자동 녹음 옵션 수정) | 바뀌지 않는다고 가정 |
