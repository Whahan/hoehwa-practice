# v1.6.0 재미 기능 설계: 가나 기초 코스 · 60초 스피드 퀴즈 · 업적 배지 + 주간 리포트

- 작성: designer (설계만. 코드·설정 수정 없음) / 대상: Godot 4.6.3 앱 `godot\` (PC 1280x800, 안드로이드 412x915), 현재 v1.5.1
- 상태: 오케스트레이터 확정 전 초안. §10 의 결정이 필요하다(사용자에게 물을 것은 §10.1).
- 표기: **(추측)** = 코드·실행으로 확인하지 못한 가정. 표기 없는 것은 코드를 읽어서 확인한 사실이다. **(새)** = 이번에 새로 만드는 파일·함수. 경로는 저장소 루트 `D:\Ai\언어\app` 기준.

- 요청한 필수 항목과 이 문서의 절: ① 화면 흐름·진입 위치 = §4 ② 데이터 계약(새 저장 키·JSON·동기화·호환) = §5.1~5.3 ③ 배지 목록·소급 결정 = §5.5 ④ 파일별 작업 분할·소유권·의존 순서 = §6.2~6.3 ⑤ 작업별 O/X 합격 조건·금지 조건 = §6.4~6.5 ⑥ 위험 요소·사용자 결정 질문 = §7, §10.

## 0. 읽은 것 / 확인하지 못한 것

- 읽은 것(전체 또는 해당 구간): `README.md`, `ROADMAP.md`, `docs\home_menu_design.md`(1-390, 751-830, 제목 목록: 형식·작업 분할 표기 참고), `docs\sync_design.md`(§4.1-4.3, 제목 목록), `docs\phone_standalone_design.md`(가나·읽기 관련 줄만 검색), `godot\scripts\core\kana_data.gd`(전체), `core\kana_hangul.gd`(머리 60줄), `practice\kana_screen.gd`(전체), `autoload\tts.gd`(전체), `local\system_tts.gd`(머리 80줄), `core\study_log.gd`(전체), `autoload\store.gd`(1-200, 320-530), `core\progress.gd`(1-140), `core\fsrs.gd`(머리), `core\streak_calc.gd`(머리), `core\study_clock.gd`(전체), `core\home_model.gd`·`ui\home_parts.gd`(해당 구간), `core\song_due.gd`(머리·집계부), `core\memo_model.gd`(`summary`), `local\local_lessons.gd`·`local\pack_loader.gd`(머리), `main.gd`(1-130, 180-340, 445-600), `views\menu_view.gd`·`app_view.gd`(전체), `views\practice_view.gd`(전체), `views\stats_view.gd`(1-140), `views\today_view.gd`(180-290, 370-387), `sync\sync_doc.gd`(머리·`clean_rec`·`_check_rec`), `sync\sync_merge.gd`(`_rec_add`), `ui\sheet.gd`·`ui\glyph.gd`(함수 목록), `practice\speak_drill.gd`(`build_shell`), 테스트 머리(`kana_test.gd`, `home_view_test.gd`, `run_memo_tests.ps1`), `packaging\check_no_media.ps1`, `godot\export_presets.cfg`(필터·권한 줄), 데이터 `godot\data\pack\gloss_*.json`·`lesson_bank_*.json`·`manifest.json`(구조·개수).
- 실행한 것: 읽기 전용 파이썬 스크립트로 `gloss_*.json`·`lesson_bank_*.json` 의 단어 수를 셌다(§2.5). **Godot 시험은 하나도 실행하지 않았다.** 그래서 현재 시험 통과 개수(기준선)는 모른다 — 각 작업자가 작업 전에 잰다(§6.4 C-0).
- 확인하지 못한 것: 실제 폰에서 일본어 시스템 음성이 있는지, 단독 가나 한 글자를 Kokoro·시스템 음성이 어떻게 읽는지(は·へ·を 등), 폰에서 JSON 파싱 속도, 실제 화면 모습(스크린샷 없음, 코드로 추정).

---

## 1. 목표와 범위

### 1.1 목표
- **A. 가나 기초 코스(일본어):** 이미 있는 가나 익히기(표 + 퀴즈)를 "코스"로 키운다: 단계(행 단위) 22개 + 헷갈리는 짝 2개, 단계 시험(듣고 고르기 → 글자 보고 읽기 고르기 → 입력), 글자별 숙련도, 헷갈리는 짝(シ/ツ, ソ/ン, ぬ/め …) 집중 연습. AI·PC 없이 폰 단독.
- **D. 60초 스피드 퀴즈:** 내 복습 카드 + 레슨 단어로 4지선다를 60초 안에 빠르게, 콤보 점수, 언어별 최고 기록. AI·PC 없이 폰 단독.
- **E. 업적 배지 23개 + 주간 리포트:** 기존 기록에서 계산하는 배지(소급 지급), 획득 알림, 배지 화면. 지난 7일 공부 시간·새 카드·정답률·발음 점수 변화를 한 장 카드로 기록 화면(전체)과 홈(요약)에서.

### 1.2 하지 않을 것
- AI·서버·네트워크 호출 전부(새 코드는 `Api`·`HTTPRequest`·`Route`·`OS.shell_open` 을 쓰지 않는다). 안드로이드 권한 추가(`export_presets.cfg` 변경 0).
- 폰 하단 탭 5개 변경(홈·레슨·복습·노래·메뉴 그대로). 새 autoload 등록(`project.godot` 변경 0).
- 동기화 스키마(`SyncDoc`·`SyncMerge`·`SyncEngine`) 변경. 배지·스피드 기록·가나 코스 기록의 기기 간 동기화(§5.2: 이번에는 기기별).
- 복습 카드(FSRS) 일정 변경: 스피드 퀴즈·가나 코스에서 맞히고 틀려도 `Store.rate_review` 를 부르지 않는다.
- 마스코트·폭죽·소리 효과·푸시 알림. 새 글꼴·이미지·이모지(도형은 `GlyphIcon` 으로 그린다. 이모지·도형 글자 문자열 금지, `docs\home_menu_design.md` §6 과 같은 규칙).
- 가나 쓰기(획순) 연습, 가나 손글씨 인식, 일본어 가타카나 단어 코스.
- 가나 소리 파일(번들 클립)은 **이번 필수 범위가 아니다**(§2.2, 사용자 결정 §10.1 Q1 에서 고른다).
- 버전 올리기(`godot\project.godot`·`export_presets.cfg` 의 1.6.0)·릴리스: 오케스트레이터의 릴리스 단계.

---

## 2. 지금 구조에서 알게 된 사실 (설계의 근거)

### 2.1 가나 기능은 이미 절반 있다 (가장 중요한 발견)
요청의 A 는 "새로 만들기"가 아니라 **기존 `KanaScreen` 을 코스로 확장**하는 일이다.

| 이미 있는 것 | 위치 |
|---|---|
| 글자표(청음 46 + 탁음 20 + 반탁음 5 + 요음 33 = 히라가나 104, 가타카나 104, 합 208), 한글 소리 `ko`, 로마자 `ro` | `core\kana_data.gd` `_ROWS`, `entries()`, `get_entry()`, `section_rows()` |
| 표 칸을 누르면 소리, 칸마다 익힘 점 3개 | `practice\kana_screen.gd` `tap_cell`, `Cell`, `Dots` |
| 퀴즈 2종: 글자→소리(`read`), 소리→글자(`listen`). 10문제, 보기 4개(한글 소리가 모두 달라 정답이 하나) | `KanaData.KINDS`, `make_question()`, `build_session()` |
| 헷갈리는 글자 묶음 15개(シ ツ ソ ン, ぬ め ね れ わ …)와 집중 연습 | `KanaData._GROUPS`, `groups()`, `build_session(cfg.focus)` |
| 글자별 맞힘/틀림 횟수와 숙련도 0~3 | `StudyLog.add_kana()`, `kana_stat()`, `kana_stats()`, `KanaData.mastery(ok, bad)` (3 = 맞힘 ≥ 4 이고 틀림×3 ≤ 맞힘) |
| 한 판 기록, 틀린 글자 복습 카드 추가, 5문제 이상 풀면 "오늘 공부" 표시 | `StudyLog.add_kana_run()`, `KanaScreen.add_wrong_to_review()`, `MARK_TODAY_AT := 5` |
| 연습 허브 카드 "히라가나·가타카나 익히기"(일본어 탭만) | `views\practice_view.gd` `_hub_items()`, `KINDS` 의 `"kana"` |
| 가나 기록 저장은 이 기기 전용(`studylog.json` 의 `"kana"` 키, 동기화 안 됨) | `study_log.gd` 머리 주석, `_norm_kana` |

**없는 것(이번에 만든다):** 단계(코스) 구조와 단계 시험, **입력 퀴즈**(보기가 없는 문제), 명시적인 **글자 짝**(2글자)과 구별 요령 문구, 코스 진행 기록, 가나 숙련 배지.

### 2.2 가나 소리는 폰 단독에서 "조건부로만" 난다
- 소리는 `Tts.speak(ch, "ja")` 한 길이다(`KanaScreen.play_kana`). 폰 단독이면 `Tts.engine_now() == "system"`(폰 시스템 음성, `DisplayServer.tts_*`)이고, **폰에 일본어 음성 데이터가 있을 때만** 난다(`Tts.system_voices_ok().get("ja")`, `KanaScreen.sound_available()`). 앱에는 가나 소리 파일이 없다.
- 일본어 음성이 없으면 지금도 "소리 없이 글자만 익힐 수 있어요" 한 줄 안내 + 로마자 힌트로 퀴즈가 진행된다(`KanaScreen.no_sound_text()`, 퀴즈 `listen` 에서 로마자 힌트). 이 대체 동작은 **유지한다**.
- PC 엔진이면 PC 서버(Kokoro `jf_alpha`)로 낸다. PC 연결이 없으면 소리 없음(`Api.base_url == ""`).
- 결론: "오프라인 소리"는 폰의 일본어 음성에 달려 있어 **보장되지 않는다.** 대안 = 번들 클립(§6.5 K0). 번들 클립에는 걸림돌이 둘 있다: ① `packaging\check_no_media.ps1` 이 추적되는 `.wav/.ogg/.mp3…` 를 금지한다(`godot/tests/fixtures/song/` 만 예외) → 클립을 JSON(base64)로 넣거나 이 검사의 예외 폴더를 하나 추가해야 한다. ② 한 글자 합성 음질·읽기(は/へ/を)를 **들어 보고 정해야 한다(추측: 단독 한 글자는 합성기가 어색하게 읽을 수 있음)**.

### 2.3 PC 빌드에는 폰 데이터 묶음이 없다
`godot\export_presets.cfg` 첫 번째 프리셋(PC)은 `exclude_filter="tests/*, tools/*, data/pack/*"`, 안드로이드는 `tools/*` 제외만이다. 그래서 `godot\data\pack\*`(레슨 은행·단어 뜻 사전)은 **PC 앱에 없고**, PC에서 `PackLoader` 는 `pack_missing` 을 준다. 스피드 퀴즈가 PC·폰 둘 다 되려면 `data\pack\` 밖에 **작은 새 데이터 파일**이 필요하다(`godot\data\speed_words.json`, §5.4. `include_filter="data/*"` 라 두 빌드에 다 들어간다).

### 2.4 학습 기록 구조(배지·리포트의 재료)
- `studylog.json` v1(`StudyLog`): `days[iso][lang] = {sec, by, n{lessons, talks, missions, reviews, shadow, dictation, drill}, lesson[ok,total], score[count,sum]}`, `missions[id] = {stars, plays, last, done_goals}`, `kana`, `path`, `freeze`, `phon`. 최상위 모르는 키는 보존된다(`_normalize`). 이 기기 전용 키의 선례: `"kana"`, `"path"`(`SyncDoc` 는 `days`/`phon`/`missions` 만 주고받는다. `StudyLog.apply_sync` 도 그 셋만 바꾼다).
- 동기화되는 것: `progress.json`(`start, checks, days, xp, stats, review, known_words`)과 `studylog.days.*`(**모든 숫자 잎을 합산**, `n` 의 키는 임의 문자열 ≤ 24자·≤ 32개, `SyncMerge._rec_add`·`SyncDoc.clean_rec`)와 `missions`. → **`days.*.n` 에 새 키를 더하면 동기화로 두 기기에 저절로 합산된다**(스키마 변경 없음).
- `Store.stat(lang, "lessons"|"talks")`(레슨 끝낸 횟수, 대화 횟수)는 동기화됨. 복습 카드 `progress.review[]` 에는 **만든 시각이 없다** → "새 카드 수"는 지금 셀 수 없다(§5.6 에서 `n.newcards` 를 새로 센다).
- 연속 일수: `StudyLog.settle(lang)` 은 **현재** 연속만 준다(최장 기록 없음). 배지용으로 `StudyLog.longest_streak(lang)` 를 새로 만든다(§5.3).
- 공부 시간 측정: `StudyClock` 이 창 포커스 + 최근 45초 입력을 5초 단위로 세고 `current_view()` 이름으로 `by` 에 쌓는다. 스피드 퀴즈·가나 코스는 `practice` 화면 안이라 자동으로 센다.
- 곡 기억: `SongStore.memo_summary()` = `{total, memorized(FSRS 복습 상태 줄 수), learning, fresh, due, next_due}`. 홈이 스레드로 돌리는 `SongDue.compute()` 가 곡 집계를 이미 한다(`SongDue.cache`) → 거기에 "다 외운 곡 수"만 더한다(§5.5).

### 2.5 스피드 퀴즈의 "레슨 단어" 재료와 한계 (파이썬으로 센 값)
| 자료 | 사실 |
|---|---|
| `data\pack\gloss_en.json` 10,265 단어, `gloss_ja.json` 5,074 단어 | 단어 → `{pos, ko, ipa}`. 일본어의 `ipa` 는 가나 읽기. 뜻은 **로컬 AI(Qwen3 8B)가 만든 자료라 일부가 틀릴 수 있다**(README 라이선스 표 마지막 줄 근처에 이미 적힘) |
| `lesson_bank_*.json` | 월 12 x 주 4 = 48칸, 칸마다 레슨 ≈ 20, 문제 종류 `build/choice/listen/fill/speak`. `fill` 정답(빈칸 단어)만 모으면 영어 211·일본어 281 단어뿐이라 **부족**하다 |
| 레슨 문장 전체에서 gloss 단어를 찾으면(명사·동사·형용사·부사, 뜻 ≤ 12자) | **영어 약 718, 일본어 약 918 단어**(월 1~12 모두에 걸침. 이 값은 내가 단순 규칙으로 센 근사치이고 작업자가 다시 잰다). 그중 한국어 뜻의 어간이 같은 칸 한국어 번역에 나오는 "교차 확인" 통과 단어는 영어 약 355, 일본어 약 530 |
| `Store.review_for(lang)` 카드 | `target`(단어·문장), `reading`, `ko`. 카드가 8장 미만이면 카드 문제만으로는 부족 |

---

## 3. 핵심 결정 요약

| # | 결정 | 이유 |
|---|---|---|
| D1 | 가나 코스는 **기존 `KanaScreen` 확장**(새 화면 클래스 만들지 않음). 연습 허브 카드(일본어 탭)는 그대로 쓰고 글을 "가나 기초 코스"로 바꾼다. 홈에서도 바로 간다 | 기존 시험(`kana_test` 1085줄)·허브 계약을 그대로 이어 간다 |
| D2 | 스피드 퀴즈는 **연습 허브의 새 카드**(`kind "speed"`, 새 화면 `SpeedScreen`). 허브가 `closed` 신호로 돌아오는 기존 계약 그대로 | `PracticeView` 머리 주석의 "세 군데에 한 줄씩" 규칙 |
| D3 | 배지·리포트: 새 화면 하나 `BadgeView`(탭 키 `"badges"`, 이름 "배지")를 **`add_v16_tabs()`(새)로 등록**. 폰은 메뉴 화면 "기록" 묶음 맨 끝에 저절로 놓이고(`main.gd _update_menu` 가 "어느 묶음에도 없는 탭은 기록 끝"으로 처리), PC는 왼쪽 메뉴 "기록" 묶음 끝에 놓인다. **하단 탭은 늘리지 않는다.** | 폰 5탭 유지, 메뉴→배지 2번 눌러 닿음 |
| D4 | 주간 리포트: 전체 카드는 **기록 화면 맨 위**, 요약 카드는 **홈 연속 카드 아래**(홈 "이번 주" 카드: 숫자 3개 + 바로가기 버튼 2~3개) | 사용자 요청 "홈 또는 기록" 둘 다 가볍게 만족 |
| D5 | 새 저장 파일 **없음**. `studylog.json` 최상위 키 3개 추가: `"speed"`, `"badges"`, `"kana_course"`. 셋 다 **이 기기 전용**(동기화 안 함) | `kana`·`path` 선례. 읽기·쓰기·깨짐 격리(`.bad`)·시험 보호·초기화가 이미 있다 |
| D6 | 배지는 **"기존 기록에서 계산 → 한 번 받으면 영구"**: 규칙은 순수 함수(`BadgeRules`), 받은 것만 `studylog.badges.got` 에 저장. 계산이 가능한 배지는 **소급 지급**(§5.5) | 동기화되는 기록(레슨·연속·시간·카드·미션)에서 계산하므로 두 기기가 같은 배지에 수렴 |
| D7 | 배지 평가 시점: `BadgeWatcher`(새 Node, `main.gd` 가 `add_child`)가 ① `Store.activity` 신호(새: 퀴즈 한 판·가나 시험·레슨 끝 같은 "한 단위 끝") ② `Store.changed` ③ 30초 타이머(기록이 바뀐 경우만)에서 평가. 한 번 평가에 알림은 **최대 1개** | 토스트 폭주 방지, 새 autoload 불필요 |
| D8 | 새 `n` 키 하나: `newcards`(복습 카드가 새로 들어간 수). `Store.add_review` 가 언어별로 센다. `StudyLog.KINDS` 에 추가 | 동기화에 저절로 합산됨. 옛 기록은 0(소급 없음) |
| D9 | 스피드 퀴즈 단어는 새 데이터 파일 `godot\data\speed_words.json`(`godot\tools\build_speed_words.gd` 가 gloss + 레슨 은행에서 만듦, 커밋) | PC 빌드에 pack 이 없다(§2.3). 런타임에 3.5MB JSON 파싱을 피한다 |
| D10 | 가나 소리는 새 `KanaVoice`(`core\kana_voice.gd`) 한 곳으로 모은다. 지금은 `Tts` 로 보내는 얇은 껍데기. 나중에 번들 클립(K0)을 이 파일 하나만 바꿔 끼운다 | 화면 코드를 다시 안 건드림 |
| D11 | 가나 입력 퀴즈의 정답은 **로마자(헵번 + 훈령식 변형)와 한글 소리 둘 다 인정**(폰 키보드가 영어든 한국어든 됨) | 일본어 키보드 없이 폰 단독 |
| D12 | 단계 잠금 없음. 다음 단계에 "추천" 표시만 한다 | 이미 가나를 아는 사람을 막지 않음(홈·길 설계의 "부드러운 잠금" 정신) |

---

## 4. 화면 흐름과 진입 위치

### 4.1 진입 지도 (폰 하단 탭 5개 그대로)
```
홈 ── "이번 주" 카드(새) ── [60초 퀴즈] ─────→ 연습 > 스피드 퀴즈(새 화면)
 │                      ├─ [가나 코스](일본어일 때만) → 연습 > 가나 익히기, 코스 화면
 │                      ├─ [배지 n/23 ●] ────→ 배지 화면(새 탭 "badges")
 │                      └─ 카드 본문 ────────→ 기록 화면(맨 위 전체 리포트)
메뉴(폰) ── 기록 묶음: 기록 · 로드맵 · 배지(새)
PC 왼쪽 메뉴 ── 기록 묶음: 기록 · 로드맵 · 배지(새)
연습 허브 ── [히라가나·가타카나 익히기→"가나 기초 코스"] · [60초 스피드 퀴즈](새 카드, 맨 끝)
기록 화면 ── 맨 위 "이번 주 리포트" 전체 카드(새)
```
- 폰 뒤로 가기: 홈 → 연습(스피드) 으로 가면 기존 `_origin` 규칙대로 홈으로 돌아온다(`main.gd _track_origin`). 연습 안 하위 화면에서는 기존대로 하위 화면 `go_back()` 이 먼저.
- 홈에서 스피드·가나로 가기: `PracticeView.pending = {"kind": "speed"}`(또는 `{"kind":"kana","view":"course"}`) 설정 후 `Store.navigate.emit("practice", lang)`(`PracticeView.refresh` 가 `_consume_pending` 으로 연다. 기존 계약).
- 새 배지 알림: 토스트(`Toast.ok`) 한 줄 + 홈 카드·배지 화면의 "새" 점. 푸시 알림 없음.

### 4.2 가나 코스 화면 (폰 412x915, `KanaScreen` 새 단계 `course`·`stage_intro`)
```
┌─────────────────────────────────────┐
│ ← 연습           히라가나 · 가타카나   │ SpeakDrill.build_shell 머리
│ [ 표 | 코스 ]                         │ 위쪽 segmented(새). 표 = 지금 화면
│ 히라가나  4 / 11 단계 완료  ▓▓▓░░░░░  │ 진행 바(청록) + 글자 숙련 38/104
│ ┌────────────────────────────────┐  │ 단계 행: 높이 ≥ 64, 전체가 눌림
│ │ ✓ 1  あ행   あ い う え お  5/5  │  │ ✓ = 완료(최고 93%), 숙련 5/5
│ │ ✓ 2  か행   か き く け こ  5/5  │  │
│ │ ▶ 3  さ행   さ し す せ そ  2/5  │  │ ▶ = 추천(다음)
│ │   4  た행 …                  0/5  │  │
│ │ …  탁음 · 반탁음 · 요음 …          │  │
│ │ ◇ 헷갈리는 짝 (히라가나) 10쌍 3/10 │  │ 짝 단계
│ └────────────────────────────────┘  │
│ 가타카나  0 / 11 단계 완료 …           │
└─────────────────────────────────────┘
```
- 단계를 누르면 `stage_intro`: 그 단계 글자 칸(표와 같은 `Cell`, 누르면 소리), 아래 큰 버튼 [단계 시험 시작 (15문제)] 한 개, 보조 [표로].
- 단계 시험: 15문제 = 듣고 고르기 5 + 글자 보고 읽기 고르기 5 + 입력 5(소리가 안 나는 기기면 듣기 5개를 읽기 고르기로 바꾸고 안내 한 줄). 위쪽 "7 / 15". 통과 = 12개 이상(80%).
- 입력 문제(보기 없음):
```
│  이 글자는 어떻게 읽을까요?            │
│           し                          │ 글자 크기 72
│  ┌───────────────────────────────┐   │ LineEdit, 높이 ≥ 56
│  │ shi 또는 시                    │   │ 안내(placeholder): "로마자 또는 한글로"
│  └───────────────────────────────┘   │
│  [ 확인 ]                             │ primary 56. 입력창에서 Enter 도 확인
│  (틀리면) 정답: shi / si / 시          │ 인정되는 답을 모두 보여 줌
```
- 결과: 정답률, 통과/미통과, 틀린 글자 목록(소리 ▶), [틀린 글자 복습 카드로 추가](기존), [다음 단계](통과 시, primary), [같은 단계 다시], [코스로].
- **헷갈리는 짝 단계**: 짝 목록(シ/ツ 등)을 칩으로 고르거나 "전체 섞기". 문제는 4지선다 — 정답과 **그 짝 글자가 반드시 보기에 들어가고** 나머지 둘은 같은 묶음 글자(§5.7). 문제 아래에 구별 요령 한 줄(예: "シ 는 …").
- 기존 "퀴즈 설정"(범위·헷갈리는 묶음 집중)은 [표] 쪽 "퀴즈 풀기"로 그대로 남고, 문제 종류에 **"입력"**(`type`)이 하나 더 생긴다.

### 4.3 스피드 퀴즈 (`SpeedScreen`, 연습 허브 카드)
```
시작 화면                         진행 중                            결과
┌──────────────────────┐   ┌──────────────────────────┐   ┌──────────────────────┐
│ ← 연습  60초 스피드 퀴즈│   │ 남은 시간 42초   점수 230 │   │ 결과                   │
│ [영어]  (칩)            │   │ ▓▓▓▓▓▓▓▓▓░░░  (시간 바)   │   │ 점수 540  ★ 새 기록!   │
│ 내 카드 + 레슨 단어에서  │   │ 콤보 x7  (보라 알약)      │   │ 정답 24 / 27 (89%)     │
│ 뜻을 빨리 고르세요.      │   │                          │   │ 최고 콤보 12           │
│ 최고 기록 540점         │   │        work             │   │ 이전 최고 480점        │
│ 단어 1,030개 준비됨      │   │      (読み: かな)        │   │ 틀린 단어 3개:          │
│ [ ▶ 시작 ]              │   │ ┌─────────┬─────────┐   │   learn  배우다   ▶    │
└──────────────────────┘   │ │ 일하다 ✓│ 공부하다 │   │ [오답 3개 복습 카드로]   │
                            │ ├─────────┼─────────┤   │ [다시 도전] [나가기]     │
                            │ │ 사다    │ 걷다    │   └──────────────────────┘
                            │ └─────────┴─────────┘ │
                            └──────────────────────────┘
```
- 단어(큰 글자 44)와 보기 4개(2x2, 각 높이 ≥ 72, 글자 18~20). 단어가 일본어면 읽기(가나)를 아래에 작게(`rd`).
- 정답: 보기에 ✓ 도형 + 초록, 다음 문제로 0.35초 뒤 자동. 오답: 고른 보기에 × + 빨강, 정답 보기에 ✓, 0.9초 보여 주고 다음(그 동안 시간은 흐른다). 색만으로 구분하지 않는다(`GlyphIcon("check"|"close")`).
- 뒤로 가기(안드로이드 뒤로·← 연습)를 누르면 시간을 멈추고 "그만할까요?" 시트(`Sheet.confirm`). 그만두면 기록하지 않는다. 폰이 백그라운드로 가면(`NOTIFICATION_APPLICATION_PAUSED`)·PC 창 포커스를 잃으면 시간이 멈추고 돌아오면 이어진다.
- 언어는 연습 허브의 언어 스위치를 따른다(영어/일본어). 단어 수가 `SpeedPool.MIN_POOL`(12) 미만이면 시작 버튼을 끄고 "복습 카드를 더 모으거나 레슨을 해 보세요" 안내.

### 4.4 배지 화면 (`BadgeView`, 탭 키 `badges`)
```
┌─────────────────────────────────────┐
│ 배지                                  │ 큰 제목(폰은 앱 바 제목)
│ 23개 중 9개 받았어요  ▓▓▓▓░░░░░       │ 보라 진행 바
│ [전체][습관][레슨·복습][말하기][노래][가나][스피드] │ filter_chip, 가로 줄바꿈(flow)
│ ┌───────┐ ┌───────┐ ┌───────┐        │ 타일 3열(폰) / 5열(PC 넓음)
│ │ 별    │ │ 별    │ │ 자물쇠 │        │ 받은 것: REWARD 도형 + 이름 + 날짜
│ │첫 레슨│ │7일 연속│ │30일연속│        │ 못 받은 것: 흐린 자물쇠 + 이름 + 진행 "3/30"
│ │11-02  │ │11-09●새│ │ 3/30  │        │ ● = 아직 안 본 새 배지(화면에 들어오면 본 것으로 표시)
│ └───────┘ └───────┘ └───────┘        │
└─────────────────────────────────────┘
```
- 타일을 누르면 시트(`Sheet.open`): 큰 도형, 이름, 설명(조건), 받은 날짜 또는 진행(`value / target`), "예전 기록으로 받음"(소급이면).
- 타일은 `Button`(`UI.on_tap` 규칙, `PhoneLayout.install_touch_scroll` 이 터치 스크롤을 처리하므로 일반 `BaseButton` 만 쓴다).

### 4.5 주간 리포트 카드 (한 장, `FunParts.report_card`)
```
┌ 이번 주 리포트 · 11.08 ~ 11.14 (영어) ┐
│ 공부한 날 5 / 7        공부 시간 128분 (지난주 +34) │
│ 레슨 6개 · 정답률 84% (지난주 79%)                  │
│ 새 카드 18 · 복습 52번                              │
│ 발음 점수 평균 78점 (지난주 72점, +6)               │  표본이 적으면 "발음 점수: 기록이 적어요"
│ 한 줄: 지난주보다 34분 더 공부했어요. 이대로 쭉!    │  규칙 문구(AI 아님)
└─────────────────────────────────────────────────────┘
```
- "지난 7일" = 오늘 포함 7일(오늘−6 ~ 오늘), 비교 대상 = 그 앞 7일. 홈 요약 카드는 같은 데이터에서 숫자 3개(공부 분·레슨 수·새 카드 수)만.
- 언어는 선택 언어 하나(홈·기록 화면의 언어 스위치를 따름).

### 4.6 홈 "이번 주" 카드 (`FunParts.home_card`, 카드 id `"fun"`)
```
┌ 이번 주 ───────────────────────────┐
│ 공부 128분 · 레슨 6개 · 새 카드 18   │ 눌러서 기록으로
│ [ 60초 퀴즈 ] [ 가나 코스 ] [ 배지 9/23 ● ] │ soft 버튼 48, 폰은 줄바꿈 가능(flow)
└──────────────────────────────────┘
```
- 위치: 연속 카드 바로 아래(AI 카드 non-prominent·폰 바로가기 줄 위). PC는 오른쪽 열(연속 카드 아래). 이 카드가 첫 화면의 "시작 버튼 y ≤ 480, 이어하기 카드 y < 859" 규칙에 영향을 주지 않는다(연속 카드 아래라서).
- [가나 코스]는 일본어일 때만. 기록이 하나도 없으면(`StudyLog.has_data(lang)` 거짓) 숫자 줄 대신 "공부를 시작하면 이번 주 기록이 여기에 쌓여요" 한 줄.

---

## 5. 데이터 계약

### 5.1 `studylog.json` 새 최상위 키 3개 (v 는 1 그대로, 이 기기 전용)
```json
{
  "v": 1,
  "speed": {
    "en": {"plays": 12, "ok": 160, "total": 190, "last": "2026-11-20",
           "best": {"score": 540, "correct": 24, "total": 27, "combo": 12, "date": "2026-11-20"}},
    "ja": {"plays": 0, "ok": 0, "total": 0, "last": "", "best": {}}
  },
  "badges": {
    "got":  {"first_lesson": {"at": "2026-11-02", "retro": true},
             "streak_7":    {"at": "2026-11-09", "retro": false}},
    "seen": ["first_lesson"]
  },
  "kana_course": {
    "done":  {"h1": "2026-11-12", "h2": "2026-11-13"},
    "best":  {"h1": 93, "h2": 87, "h3": 60},
    "tries": {"h1": 2, "h2": 1, "h3": 1}
  }
}
```
| 키 | 규칙(정규화 `_normalize` 가 읽을 때 강제) |
|---|---|
| `speed.<lang>` | `lang` ∈ `en, ja`(그 밖은 버림). `plays, ok, total` 정수 0~1,000,000, `ok ≤ total`. `last` = 실제 달력의 `YYYY-MM-DD` 또는 `""`(`_iso_days` 재사용). `best` = `{}` 또는 `{score 0~100000, correct 0~1000, total 0~1000(correct ≤ total), combo 0~1000, date}`. 모르는 하위 키는 버린다 |
| `badges.got` | 키 = 정규식 `^[a-z0-9_]{1,32}$`, 최대 `MAX_BADGES`(100)개. 값 = `{at: 유효한 날짜, retro: bool}`(날짜가 틀리면 그 항목 버림). **`BadgeDefs` 에 없는 id 도 보존한다**(다른 버전이 만든 배지를 지우지 않음. 화면만 무시) |
| `badges.seen` | 문자열 배열, `got` 에 있는 id 만, 중복 제거 |
| `kana_course.done` | 키 = 단계 id(정규식 `^(h|k)([1-9]|1[01])$` 또는 `^p_(h|k)$`), 값 = 유효한 날짜 |
| `kana_course.best` | 같은 키 규칙, 값 정수 0~100 |
| `kana_course.tries` | 같은 키 규칙, 값 정수 0~1,000,000 |
- 세 키 모두 **파일에 없으면 `snapshot()` 에도 없다**(`kana`·`path` 와 같은 방식: 첫 쓰기 때 생긴다. `_blank()` 에 넣지 않는다).
- 단계 id 검증을 `KanaCourse` 클래스에 기대지 않고 정규식으로 한다(코어 순환 의존 방지, `_is_kana_key` 와 같은 이유).

### 5.2 기존 `studylog`/`progress`/`prefs` 와의 관계, 동기화, 호환
| 항목 | 결정 |
|---|---|
| `days.*.n.newcards`(새) | `StudyLog.KINDS` 에 `"newcards"` 추가. **동기화 대상**(`n` 잎 합산, 스키마 변경 없음). `Store.add_review` 가 새로 들어간 카드마다 센다. 동기화로 들어오는 카드(`apply_sync_progress`)는 세지 않는다. 옛 기록·1.5.x 기기는 0 |
| `speed`, `badges`, `kana_course` | **동기화하지 않는다**(기기별). `SyncDoc.extract` 는 이 키를 읽지 않고 `StudyLog.apply_sync` 는 `days/phon/missions` 만 바꾸므로 **지워지지도 않는다**(D1 시험이 확인) |
| 두 기기의 배지 | 레슨·연속·시간·카드·미션처럼 **동기화되는 기록에서 계산하는 배지는 두 기기가 같은 결과로 수렴**한다(각 기기가 평가할 때 받음). 가나·스피드·노래 배지는 그 기기의 기록으로만 받는다. 받은 날짜는 기기마다 다를 수 있다. 1.6.1 후보: `badges.got` 합집합(더 이른 날짜), `speed.best` 최대값 병합 |
| 옛 파일(1.5.x) | 새 키가 없으면 빈 상태로 읽고, 첫 기록 때 만든다. `v` 는 1 유지 |
| 새 파일을 옛 앱(1.5.1)이 읽을 때 | 새 키 3개가 최상위 **모르는 키**라 보존된다(`_normalize` 의 deep copy). 단 1.5.1 의 `kana` 정규화가 모르는 하위 키를 버리므로, **코스 기록을 `kana` 안이 아니라 별도 최상위 `kana_course` 에 둔다**(그래서 이 이름) |
| `prefs.json` | 새 설정 없음 |
| 기록 초기화 | `Store.reset_progress()` → `StudyLog.reset()` 은 지금처럼 모든 기록(새 키 포함)을 지운다. 지운 뒤 배지는 다시 평가되며 기록이 없으면 받을 게 없다 |
| 시계 | 날짜는 `StudyLog.today()`(시험은 `today_override`). 시계를 되돌려도 받은 배지·`at` 은 바뀌지 않는다(영구, 되돌리지 않음) |

### 5.3 새·바뀌는 함수 시그니처 (작업 간 계약 — 바꾸려면 오케스트레이터 승인)

**D1: `core\study_log.gd`, `autoload\store.gd`**
```gdscript
# study_log.gd
const KINDS := ["lessons", "talks", "missions", "reviews", "shadow", "dictation", "drill", "newcards"]
const KNOWN_KEYS := ["v", "saved", "days", "phon", "freeze", "missions", "kana", "path", "speed", "badges", "kana_course"]
const MAX_BADGES := 100
const SPEED_MIN_ANSWERED := 5                     # 이보다 적게 푼 판은 기록하지 않는다
static func add_speed_run(lang: String, score: int, correct: int, total: int, combo: int) -> Dictionary
    # {"recorded": bool, "new_best": bool, "prev_best": int}. total < SPEED_MIN_ANSWERED, 잘못된 언어, correct > total → recorded=false(아무것도 안 바꿈)
    # recorded: plays+1, ok+=correct, total+=total, last=오늘. new_best = score > 기존 best.score(없으면 true). 최고 기록은 낮아지지 않는다
static func speed_best(lang: String) -> Dictionary     # {} 또는 best 복사본
static func speed_summary(lang: String) -> Dictionary  # {plays, ok, total, last}
static func badges_got() -> Dictionary                 # id -> {at, retro} 복사본
static func has_badge_record() -> bool                 # "badges" 키가 이미 있나(첫 평가 = 소급 판정용)
static func init_badge_record() -> void                # 빈 {"got":{}, "seen":[]} 를 만든다(이미 있으면 아무것도 안 함). 받을 배지가 0개인 첫 평가도 "첫 평가를 했다"고 남기려는 것
static func grant_badge(id: String, retro: bool = false) -> bool   # 새로 받으면 true. 이미 있음/형식 틀림/가득 참 → false
static func badges_seen() -> Array
static func mark_badges_seen(ids: Array) -> void
static func add_kana_course_try(stage: String, correct: int, total: int, passed: bool) -> bool
    # 단계 id 형식이 틀리면 false. tries+1, best = max(기존, round(100*correct/total)), passed 면 done[stage] = 오늘(이미 있으면 그대로)
static func kana_course_done() -> Dictionary           # stage -> iso
static func kana_course_best() -> Dictionary           # stage -> 0..100
static func longest_streak(lang: String) -> int        # progress.days 표시가 있는 날의 가장 긴 연속 일수. 보호권으로 이은 날(frozen_days)은 **연속을 잇기만 하고 일수에 더하지 않는다**(StreakCalc 규칙과 같음). 미래 날은 무시
# store.gd
signal activity(kind: String)                          # "한 단위가 끝났다" 알림. kind ∈ lesson|review|talk|mission|kana|speed|song|other
func note_activity(kind: String) -> void               # activity.emit(kind) 한 줄
# Store.add_review 안: 새로 들어간 카드가 있으면 언어별로 StudyLog.add_event(lang, "newcards", 개수)
```

**K1: 새 `core\kana_course.gd`, `core\kana_typing.gd`, `core\kana_voice.gd`** (순수 계산 + 소리 껍데기)
```gdscript
class_name KanaCourse
const STAGE_QUESTIONS := 15
const STAGE_PASS := 12                                   # 15문제 중 12개 이상 = 80%
static func stages(script: String = "both") -> Array     # [{id, script, title, kind: "rows"|"pairs", groups: [KanaData 행 id...], chars: [글자...]}] 표 순서
static func stage_by_id(id: String) -> Dictionary        # 없으면 {}
static func stage_ids() -> Array
static func next_stage(script: String, done: Dictionary) -> String   # done(= StudyLog.kana_course_done())에 없는 첫 단계 id, 다 했으면 ""
static func is_passed(correct: int, total: int) -> bool  # total == STAGE_QUESTIONS 일 때 correct >= STAGE_PASS (그 밖의 total 은 80% 이상 + total >= 5)
static func pairs(script: String = "both") -> Array      # [{id, script, a, b, group, tip}]
static func pair_by_id(id: String) -> Dictionary
static func build_stage_test(stage_id: String, rng: RandomNumberGenerator, sound: bool = true, stats: Dictionary = {}) -> Array
    # 15개 질문: listen 5(sound=false 면 read 로 바꿈) + read 5 + type 5. 같은 글자는 한 바퀴 안 반복 금지, 약한 글자(stats 의 숙련 ≤ 1) 우선. 글자가 15개 미만인 단계는 글자 수까지 순환
static func build_session(cfg: Dictionary, rng: RandomNumberGenerator, n: int = KanaData.QUIZ_N) -> Array
    # KanaData.build_session 과 같은 cfg 에 kind "type" 을 더한 버전(read/listen 은 KanaData 로 위임)
static func build_pair_session(pair_ids: Array, script: String, rng: RandomNumberGenerator, n: int = 10) -> Array
    # pair_ids 가 비면 script 의 모든 짝. 문제마다 정답 글자 + 그 짝 글자 + 같은 묶음의 다른 글자 2개(한글 소리가 모두 다름)
static func make_type_question(answer: Dictionary) -> Dictionary
    # {"kind":"type","ch","ko","ro","hira","script","options":[],"answer":-1,"accept":[...KanaTyping.accepted(answer)]}
static func weak_letters(stats: Dictionary, script: String, limit: int) -> Array   # 숙련 ≤ 1 이고 푼 적 있는 글자, 틀림 많은 순
class_name KanaTyping
static func accepted(entry: Dictionary) -> Array[String]  # 소문자·공백 없는 정답 모두: 헵번 ro + 훈령식 변형 + 한글 ko (표는 §5.7)
static func normalize(s: String) -> String                # 앞뒤 공백 제거, 전각 영문 → 반각, 소문자, 안쪽 공백·'·- 제거 아님(공백은 제거)
static func check(entry: Dictionary, input: String) -> bool
class_name KanaVoice
static func available() -> bool                           # = KanaScreen.sound_available() 와 같은 판정(시스템 음성: 일본어 음성 있음 / PC: 연결 있음)
static func speak(ch: String) -> bool                     # 소리를 부탁했으면 true, 낼 수 없으면 false(소리 없이 지나감). 지금은 Tts.speak(ch,"ja",false)
static func no_text() -> String                           # 낼 수 없을 때 안내 한 줄(= KanaScreen.no_sound_text() 와 같은 글)
```
- 질문 사전의 공통 필드(`kind, ch, ko, ro, hira, script`)는 `KanaData.make_question` 과 같다. `listen/read` 는 `options`(글자 4개 사전)와 `answer`(0~3), `type` 은 `options: []`, `answer: -1`, `accept`.
- `KanaCourse` 는 `StudyLog`·`Store` 를 읽지 않는다(통계는 인자로 받는다). `KanaVoice` 만 `Tts`·`Api` 를 쓴다.

**Q1: 새 `core\speed_pool.gd`, `core\speed_logic.gd`, 데이터 `data\speed_words.json`, 도구 `tools\build_speed_words.gd`**
```gdscript
class_name SpeedPool
const MIN_POOL := 12
const OPTIONS_N := 4
static func load_words(lang: String) -> Dictionary
    # data\speed_words.json 을 한 번 읽어 캐시. {"ok": bool, "words": [{w, rd, ko, pos, m, v}], "err": "" | "missing" | "bad"}. 깨졌거나 없으면 ok=false(앱은 죽지 않음)
static func card_items(cards: Array) -> Array            # Store.review_for(lang) 결과 → 퀴즈 항목(ko 비었음/너무 김(>40자)/target 너무 김 제외)
static func build(lang: String, cards: Array, month: int, words: Array) -> Dictionary
    # {"ok": bool, "items": Array, "reason": "" | "pool_small", "n_cards": int, "n_words": int}
    # items = 카드 항목 + (words 중 m <= month+1) 레슨 항목. 합이 MIN_POOL 미만이면 ok=false
static func make_question(item: Dictionary, pool: Array, rng: RandomNumberGenerator) -> Dictionary
    # {"id","src":"card"|"lesson","w","rd","ko","options":[한국어 뜻 4개],"answer":0..3}. 보기 뜻은 서로 다르고 정답과 뜻 조각(ko_tokens)이 겹치지 않는다. 같은 품사 우선
static func ko_tokens(ko: String) -> Array               # "일하다, 근무하다" → ["일하다","근무하다"] ( , · / ; ~ 로 쪼갬, 공백 제거, 빈 조각 버림)
class_name SpeedLogic
const LIMIT_MS := 60000
const BASE_POINTS := 10
const COMBO_STEP := 2           # 정답 점수 = BASE_POINTS + COMBO_STEP * min(이전 콤보, COMBO_CAP)
const COMBO_CAP := 10
const WRONG_LOCK_MS := 900      # 오답 뒤 이만큼은 다음 답을 받지 않는다
func _init(items: Array, rng: RandomNumberGenerator, limit_ms: int = LIMIT_MS)
func start(now_ms: int) -> void
func current() -> Dictionary                              # 지금 문제(make_question 결과), 끝났으면 {}
func answer(i: int, now_ms: int) -> Dictionary            # {"accepted": bool, "ok": bool, "points": int, "combo": int, "correct_index": int}
    # 시간이 끝난 뒤·잠금 중·보기 번호 범위 밖·이미 답한 문제 → accepted=false(아무것도 안 바뀜)
func next_question() -> void                              # 정답/오답 표시 뒤 화면이 부른다
func tick(now_ms: int) -> bool                            # 시간이 끝났으면 true(한 번 끝나면 계속 true)
func remaining_ms(now_ms: int) -> int
func pause(now_ms: int) -> void
func resume(now_ms: int) -> void
func result() -> Dictionary                               # {"score","correct","total","combo"(최고),"wrong":[{w,rd,ko,id,src}...],"finished": bool}
```
- 시계 값은 호출자가 넣는다(`Time.get_ticks_msec()`). `SpeedLogic` 은 노드·파일·시계를 직접 쓰지 않는다. NaN·음수·시간이 거꾸로 가는 값은 무시한다(거꾸로 간 값은 직전 값으로 취급).
- 점수 예: 연속 정답이면 10, 12, 14 … 30(콤보 10 이상은 30 고정). 오답: 점수 변화 0, 콤보 0.

**R1: 새 `core\week_report.gd`**
```gdscript
class_name WeekReport
static func build(cur: Array, prev: Array, lang: String = "en", to_iso: String = "") -> Dictionary
    # cur / prev = StudyLog.range_summary(...) 항목 7개씩(오래된 순). 항목이 모자라거나 모양이 틀려도 에러 없이 0으로 센다
static func for_lang(lang: String) -> Dictionary    # StudyLog.range_summary(lang, 14) 를 7개씩 나눠 build 에 넘긴다(StudyLog 를 읽는 유일한 함수)
```
결과 사전(모든 값은 정수. "없음" = -1):
```
{"lang","from","to"(iso),"empty": bool,                     # empty = 이번 주 sec·레슨·카드·복습·연습이 모두 0
 "days_studied": 0..7,                                       # sec>0 또는 n 합>0 인 날 수
 "minutes","minutes_prev","minutes_delta",                   # round(sec 합/60)
 "lessons","lessons_prev",
 "lesson_acc","lesson_acc_prev",                             # round(100*ok/total), total 0 이면 -1
 "new_cards","new_cards_prev","reviews","reviews_prev",      # n.newcards, n.reviews 합
 "practice",                                                  # n.shadow + n.dictation + n.drill 합
 "score_avg","score_n","score_prev","score_prev_n",         # round(sum/count), count 0 이면 -1
 "score_delta": int | null,                                   # 두 주의 score_n 이 모두 >= 3 일 때만 숫자, 아니면 null
 "lines": [String...]}                                        # 규칙 문구 최대 2줄(§5.6)
```

**B1: 새 `core\badge_defs.gd`, `core\badge_rules.gd`, `core\badge_engine.gd`, `core\badge_watcher.gd`**
```gdscript
class_name BadgeDefs
static func all() -> Array          # 23개: [{id, name, desc, cat, measure, target, glyph}] 표 순서(§5.5). cat ∈ habit|learn|speak|song|kana|speed
static func by_id(id: String) -> Dictionary
static func categories() -> Array   # [["habit","습관"],["learn","레슨·복습"],["speak","말하기"],["song","노래"],["kana","가나"],["speed","스피드"]]
class_name BadgeRules               # 순수 계산: 스냅샷 사전 하나만 읽는다
static func measure(name: String, snap: Dictionary) -> int     # 스냅샷 키(§5.5 표) 값을 0..MAX 정수로 청소해서 돌려줌. 숫자가 아니면 0
static func progress(def: Dictionary, snap: Dictionary) -> Dictionary   # {"value": int, "target": int, "earned": bool}
static func earned_ids(snap: Dictionary) -> Array              # 조건을 채운 모든 id
class_name BadgeEngine
static var provider: Callable = Callable()                     # 시험이 스냅샷을 바꿔 끼움: () -> Dictionary
static func snapshot() -> Dictionary                           # 실제 값으로 스냅샷(Store/StudyLog/KanaData/KanaCourse/SongDue 읽기. 이 파일이 읽는 유일한 곳)
static func evaluate(source: String = "") -> Array             # 새로 받은 id 목록. 저장·알림(토스트 최대 1개)까지 한다. 평가 도중 오류가 나도 앱은 죽지 않음
static func ui_list(lang: String = "") -> Array                # 배지 화면용: [{id,name,desc,cat,glyph,got,at,retro,value,target,is_new}] 표 순서
static func counts() -> Dictionary                             # {"got": n, "total": 23, "unseen": n}
static func mark_all_seen() -> void
class_name BadgeWatcher extends Node                           # main.gd 가 add_child. Store.activity/changed 와 30초 타이머로 평가(평가 간 최소 2초)
```
스냅샷 사전(`BadgeEngine.snapshot()` 이 만들고 `BadgeRules.measure` 가 읽는다. 키 = measure 이름):
`lessons_total, talks_total, streak_best, study_sec_total, reviews_total, cards_count, mission_star3, mission_all_star3, pron_day_best, song_lyrics, song_done, kana_hira_seion, kana_kata_seion, kana_all, kana_pairs, speed_plays, speed_combo, speed_score`(전부 정수).

**B2: 새 `ui\fun_parts.gd`, `views\badge_view.gd`** (그리고 기존 `views\stats_view.gd` 에 카드 한 장)
```gdscript
class_name FunParts
static func report_card(report: Dictionary, compact: bool = false) -> CardBox     # meta "report" = report. compact=true 는 숫자 3개 줄만
static func home_card(lang: String, report: Dictionary, badge_counts: Dictionary, on_open: Callable) -> CardBox
    # on_open(kind: String): "report" | "speed" | "kana" | "badges". meta "buttons" = {"speed": Button, "kana": Button | null, "badges": Button}
static func badge_tile(info: Dictionary, on_tap: Callable) -> Button               # info = BadgeEngine.ui_list 항목
class_name BadgeView extends AppView
static var provider: Callable = Callable()   # () -> Array(BadgeEngine.ui_list 모양). 비면 빈 목록. main.gd 가 BadgeEngine.ui_list 를 꽂는다
static var on_seen: Callable = Callable()    # () -> void. 화면이 보일 때 "새 배지를 봤다"고 알림. main.gd 가 BadgeEngine.mark_all_seen 을 꽂는다
func tile(id: String) -> Control             # 시험·셸용
func visible_ids() -> Array                  # 지금 필터로 보이는 id 순서
func set_filter(cat: String) -> void         # "" = 전체
```

### 5.4 `godot\data\speed_words.json` (새 파일 형식)
```json
{"v": 1, "built": "2026-11-xx", "src": "gloss_<lang>.json + lesson_bank_<lang>.json (godot/tools/build_speed_words.gd)",
 "en": [{"w": "work", "ko": "일하다", "pos": "동사", "m": 1, "v": true}],
 "ja": [{"w": "学校", "rd": "がっこう", "ko": "학교", "pos": "명사", "m": 1, "v": true}]}
```
- `w` 단어(표제어), `rd` 일본어 읽기(영어는 키 없음), `ko` 한국어 뜻(≤ 12자), `pos` 품사(명사·동사·형용사·부사만), `m` 그 단어가 레슨 문장에 **처음 나오는 달**(1~12), `v` 교차 확인 통과 여부(아래).
- 만드는 규칙(`build_speed_words.gd`, 읽기만 하는 도구 스크립트, `godot --headless --path godot --script res://tools/build_speed_words.gd`): ① 영어: 레슨 은행 문장(build 정답 이어 붙임·listen `audio`·fill 빈칸 채운 문장·speak `text`)을 소문자 단어로 쪼개 gloss 에 있는 단어(`pos` 가 위 4종, `ko` ≤ 12자)의 첫 달 `m`. ② 일본어: gloss 표제어(2글자 이상 또는 한자 포함)가 그 달 문장 전체 문자열에 부분 문자열로 나오는 첫 달. ③ `v` = 한국어 뜻 첫 조각의 어간(끝 "다" 제거, "~" 제거)이 그 달 한국어 번역(`ko`/`options[answer]`) 어딘가에 들어 있으면 true. ④ 같은 `w` 중복 제거, 정렬은 `m`, 그다음 gloss 순서(빈도순).
- 목표값(작업자가 실제로 재서 보고): 영어 ≥ 500, 일본어 ≥ 600 단어, 파일 전체 ≤ 400KB, 월 1~12 각각 ≥ 15(없으면 보고).
- 한계(문서·UI 안내): 뜻은 자동 생성 자료라 틀릴 수 있다 → 시작 화면 아래에 "단어 뜻은 자동으로 만든 자료라 가끔 틀려요" 한 줄, `v == true` 단어를 먼저 쓴다(`SpeedPool.build` 는 `v` 단어를 가중해서 먼저 뽑고, 부족할 때만 `v == false` 를 쓴다).

### 5.5 배지 23개 (id · 이름 · 조건 · 판정 재료)
판정 = `measure(스냅샷 키) >= target`. "소급" = 이미 지난 기록으로 첫 평가 때 한꺼번에 받는지.

| # | id | 이름 | cat | 조건(스냅샷 키 ≥ 목표) | 판정에 쓰는 기존 데이터 | 소급 |
|---|---|---|---|---|---|---|
| 1 | `first_lesson` | 첫 레슨 | learn | `lessons_total ≥ 1` | `Store.stat("en","lessons") + Store.stat("ja","lessons")`(동기화됨) | 예 |
| 2 | `lessons_10` | 레슨 10번 | learn | `lessons_total ≥ 10` | 같음 | 예 |
| 3 | `lessons_50` | 레슨 50번 | learn | `lessons_total ≥ 50` | 같음 | 예 |
| 4 | `first_talk` | 첫 원어민 대화 | speak | `talks_total ≥ 1` | `Store.stat(l,"talks")` 합 | 예 |
| 5 | `cards_20` | 복습 카드 20장 | learn | `cards_count ≥ 20` | `Store.progress["review"].size()`(현재 보유 수) | 예 |
| 6 | `reviews_100` | 복습 100번 | learn | `reviews_total ≥ 100` | `days.*.*.n.reviews` 합(400일 보존 범위) | 예 |
| 7 | `streak_3` | 3일 연속 | habit | `streak_best ≥ 3` | `StudyLog.longest_streak` 두 언어 중 큰 값(`progress.days` 표시 + 보호권 날) | 예 |
| 8 | `streak_7` | 7일 연속 | habit | `streak_best ≥ 7` | 같음 | 예 |
| 9 | `streak_30` | 30일 연속 | habit | `streak_best ≥ 30` | 같음 | 예 |
| 10 | `time_1h` | 공부 1시간 | habit | `study_sec_total ≥ 3600` | `days.*.*.sec` 합(두 언어, 400일) | 예 |
| 11 | `time_10h` | 공부 10시간 | habit | `study_sec_total ≥ 36000` | 같음 | 예 |
| 12 | `mission_star3` | 미션 별 3개 | speak | `mission_star3 ≥ 1` | `StudyLog.mission_best(id)["stars"] == 3` 인 미션 수(`StudyLog.mission_ids()`) | 예 |
| 13 | `mission_all_star3` | 미션 8개 모두 별 3개 | speak | `mission_all_star3 ≥ 8` | `BadgeRules.MISSION_IDS`(8개: `cafe_order, self_intro, hotel_checkin, ask_directions, restaurant, pharmacy_doctor, return_item, job_interview` — `StatsView.MISSION_ORDER` 와 같은지 시험이 대조) 중 별 3개인 수 | 예 |
| 14 | `pron_80` | 발음 80점 | speak | `pron_day_best ≥ 80` | 하루 단위로 `score[1]/score[0]`(= 평균), 그날 `score[0] ≥ 3` 인 날 중 가장 높은 평균(두 언어 따로 계산해 큰 값). 자기 평가(`self_rated`)는 점수에 안 들어감 | 예 |
| 15 | `song_first` | 첫 가사 등록 | song | `song_lyrics ≥ 1` | `SongDue.cache["lyrics"]` | 아니오(곡 파일은 이 기기 것) → 홈이 곡을 읽은 뒤 평가 |
| 16 | `song_done` | 가사 한 곡 다 외움 | song | `song_done ≥ 1` | `SongDue.cache["done"]`(새: `memo_summary.total ≥ 4` 이고 `memorized == total` 인 곡 수) | 같음 |
| 17 | `kana_hira` | 히라가나 청음 마스터 | kana | `kana_hira_seion ≥ 46` | `KanaData.entries("hira")` 중 `sec == "seion"` 글자의 `KanaData.mastery(ok,bad) ≥ 3` 개수(`StudyLog.kana_stats()`) | 예(퀴즈 기록이 있으면) |
| 18 | `kana_kata` | 가타카나 청음 마스터 | kana | `kana_kata_seion ≥ 46` | 같음(`script == "kata"`) | 예 |
| 19 | `kana_all` | 가나 전부 숙련 | kana | `kana_all ≥ 208` | 208글자 전부 숙련 3(`KanaData.entries("both")`) | 예 |
| 20 | `kana_pairs` | 헷갈리는 글자 극복 | kana | `kana_pairs ≥ N`(N = `KanaCourse.pairs()` 에 나오는 서로 다른 글자 수) | 짝에 나오는 글자의 숙련 3 개수 | 예 |
| 21 | `speed_first` | 첫 스피드 퀴즈 | speed | `speed_plays ≥ 1` | `StudyLog.speed_summary(l).plays` 두 언어 합 | 예(옛 기록엔 없음 = 사실상 아니오) |
| 22 | `speed_combo_10` | 콤보 10 | speed | `speed_combo ≥ 10` | `StudyLog.speed_best(l).combo` 두 언어 중 큰 값 | 같음 |
| 23 | `speed_score_500` | 스피드 500점 | speed | `speed_score ≥ 500` | `StudyLog.speed_best(l).score` 두 언어 중 큰 값 | 같음 |

- 총 23개(요청 15~25개). 상수(목표값)는 `BadgeDefs` 한 곳에 있고 시험이 "표와 코드가 같다"를 확인한다.
- **소급 지급 결정(추천): 한다.** 첫 평가(`StudyLog.has_badge_record()` 가 거짓일 때)에 조건을 채운 배지를 모두 `retro = true` 로 한꺼번에 받고, 알림은 **한 줄만**("이미 달성한 배지 N개를 모았어요", `Toast.info`). 그 뒤 평가에서 새로 받으면 `retro = false` + 배지 이름이 든 토스트 한 줄(여러 개면 "배지 N개를 받았어요: A 외 N-1"). 사용자 결정은 §10.1 Q2.
- 배지는 **빼앗지 않는다**(기록이 지워지거나 값이 내려가도 유지).
- 스냅샷 값 계산이 틀리면(숫자 아님·음수·NaN) 0 으로 본다 → 배지를 잘못 주지 않는다.
- `speed_score_500` 목표는 점수식(§5.8)에서 "한 판 약 20개 이상 정답 + 오답 거의 없음"일 때 닿는 값으로 잡은 **조정 가능한 상수**(추측: 실제 사용자는 더 낮게/높게 느낄 수 있음 → 시험 사용 뒤 조정).

### 5.6 주간 리포트 계산·문구 규칙
- 입력: `StudyLog.range_summary(lang, 14)`(오래된 순 14항목: `iso, sec, lessons_ok, lessons_n, score_n, score_sum, n{...}`). 앞 7개 = 지난 주(`prev`), 뒤 7개 = 이번 주(`cur`, 끝 = 오늘). 이 기록은 `days` 합산이라 **동기화된 두 기기에서 거의 같은 값**이 나온다.
- `score_avg = round(score_sum 합 / score_n 합)`(합이 0 이면 -1). `score_delta` 는 두 주 `score_n` 이 모두 ≥ 3 일 때만(아니면 `null`, 카드는 "발음 점수: 비교하기엔 기록이 적어요").
- 문구(`lines`, 최대 2줄, 위에서부터 첫 규칙 하나 + 보조 한 줄):
  1. `empty` → "이번 주에는 아직 기록이 없어요. 오늘 10분만 해 볼까요?"
  2. `minutes > minutes_prev` 이고 `minutes_prev > 0` → "지난주보다 N분 더 공부했어요."
  3. `minutes == 0 이 아닌데 minutes < minutes_prev` → "지난주보다 N분 적어요. 하루 10분만 더 해 볼까요?"
  4. 그 밖 → "이번 주 N일 공부했어요."
  보조: `score_delta != null and score_delta > 0` → "발음 점수가 N점 올랐어요."
- 새 카드 수는 1.6.0 이후부터만 센다(소급 없음): 업데이트한 첫 주에는 "새 카드 0"이 나올 수 있다 → 카드에 작은 글씨로 "새 카드는 1.6.0부터 세요" 안내(첫 주만이 아니라 항상 보여도 됨, 한 줄).

### 5.7 가나 코스 정의
**단계 24개** (`KanaCourse.stages()`; 표 순서. `groups` 는 `KanaData` 행 id = `entries()[i]["grp"]`):

| id | 이름 | 글자(히라가나 기준) | 글자 수 |
|---|---|---|---|
| `h1`~`h11` | あ행, か행, さ행, た행, な행, は행, ま행, や·ら·わ·ん행(`ya`+`ra`+`wa`), 탁음(`daku`), 반탁음(`handaku`), 요음(`yoon`) | 5,5,5,5,5,5,5,11,20,5,33 | 합 104 |
| `k1`~`k11` | 같은 구성, 가타카나 | 합 104 | |
| `p_h`, `p_k` | 헷갈리는 짝(히라가나 / 가타카나) | 짝 글자들의 합집합 | |
- 일본어 학습 첫 사람의 추천 순서 = `h1 … h11, p_h, k1 … k11, p_k`. `next_stage("hira", done)` 가 `h*` 와 `p_h` 를 순서대로 본다. 잠금 없음(§3 D12).
- 한 단계 시험 = 15문제(듣기 5, 읽기 5, 입력 5). 글자가 15개 미만인 단계는 순환. 통과 = 12개 이상. 통과하면 `kana_course.done[stage] = 오늘`.
- 글자 숙련도는 **기존 방식 그대로**: 모든 정답/오답(코스·퀴즈·짝·입력 모두)을 `StudyLog.add_kana(ch, ok)` 로 센다. 단계 시험 결과는 `add_kana_run` 으로도 한 판 센다(기존 `kana.runs/ok/total`).

**헷갈리는 짝 21쌍**(`KanaCourse.pairs()`; `group` = 기존 `KanaData._GROUPS` 묶음 id, 보기 나머지 2개는 그 묶음에서; 두 글자의 한글 소리가 달라야 한다):

| 히라가나(10) | group | 가타카나(11) | group |
|---|---|---|---|
| ぬ/め, ね/れ, れ/わ | `h_nu_me` | シ/ツ, ソ/ン | `k_shi_tsu` |
| る/ろ | `h_ru_ro` | ク/ケ, ク/タ | `k_ku_ke_ta` |
| さ/ち, き/さ | `h_sa_chi` | ウ/ワ, ワ/フ | `k_u_wa_fu` |
| は/ほ, ほ/ま | `h_ha_ho` | コ/ユ | `k_ko_yu` |
| あ/お | `h_a_o` | ヌ/ス, ナ/メ | `k_nu_su` |
| い/り | `h_i_ri` | ア/マ | `k_a_ma` |
| | | ル/レ | `k_ru_re` |
- `tip` = 구별 요령 한 줄 한국어. 예: シ/ツ "シ는 점 두 개가 옆으로 누워 있고, ツ는 점 두 개가 위에서 아래로 서 있어요."(작업자가 초안을 쓰고 **사용자가 검수**한다: §10.1 Q6. 틀린 요령을 넣지 않도록 모르는 것은 `tip` 을 빈 문자열로 두고 화면에서 줄을 숨긴다.)

**입력 정답 규칙** (`KanaTyping.accepted(entry)`: 항상 `ro` 와 `ko` 를 포함, 아래는 추가):

| 글자 | 추가로 인정하는 로마자 |
|---|---|
| し ち つ ふ | si, ti, tu, hu |
| じ ぢ づ | zi / (ぢ: di, ji, zi) / (づ: du, zu) |
| を | wo, o |
| ん | n, nn, n' |
| しゃ しゅ しょ | sya, syu, syo |
| ちゃ ちゅ ちょ | tya, tyu, tyo, cha 등 헵번 |
| じゃ じゅ じょ | zya, zyu, zyo, jya, jyu, jyo |
- 가타카나는 대응하는 히라가나와 같은 정답. 비교 전 `normalize`(앞뒤·안쪽 공백 제거, 소문자, 전각→반각). 빈 문자열·공백만은 항상 틀림. 한글은 완성된 음절만(조합 중인 자모 ㅅ 같은 입력은 틀림).
- `ko` 가 같은 글자(じ/ぢ = "지", ず/づ = "즈", お/を = "오")는 같은 한글 정답을 인정한다(기존 표 규칙, `kana_data.gd` 머리 주석).
- 한글 소리는 `KanaData` 의 `ko` 를 그대로 쓴다. `core\kana_hangul.gd`(문장용 변환기)는 **이번에 수정하지 않는다**(`kana_hangul_test` 가 이미 `KanaData` 와의 일치를 검사한다).

### 5.8 스피드 퀴즈 규칙
- 한 판 = 60초(`LIMIT_MS`), 문제는 시간이 끝날 때까지 이어서 나온다(개수 제한 없음, 한 판 안에서 같은 항목은 풀 전체를 한 바퀴 돌기 전에 다시 나오지 않음).
- 정답 점수 = `10 + 2 × min(이전 콤보, 10)`, 콤보는 연속 정답 수(오답이면 0). 오답은 0점이고 0.9초 동안 다음 답을 받지 않음(마구 누르기 방지). 시간 벌점 없음.
- 단어 방향: 단어(+읽기) → 한국어 뜻 4개 중 고르기. 한 방향만(양방향·듣기는 이번에 안 함).
- 문제 재료 = `SpeedPool.build`: **내 복습 카드(`Store.review_for(lang)`)** + **레슨 단어(`speed_words.json` 중 `m ≤ 현재 달 + 1`)**. 현재 달 = `Store.position()["n"]`(시작 전이면 1, 끝났으면 12). 카드가 8장 이상이면 문제의 약 절반을 카드에서(마감이 빠른 카드 우선), 그보다 적으면 레슨 단어 위주. 카드는 target 이 짧은 것(영어 ≤ 4단어 / 일본어 ≤ 12자)과 `ko` 가 있는 것만.
- 푼 결과는 복습 일정에 영향을 주지 않는다(`rate_review` 없음). 오답은 결과 화면에서 [복습 카드로 추가](`Store.add_review`, `note` = "스피드 퀴즈")를 눌러야만 들어간다(이미 있는 카드는 `add_review` 가 건너뜀).
- 판이 끝나면: `StudyLog.add_speed_run(...)`, 5문제 이상 풀었으면 `StudyLog.add_event(lang, "drill", 1)` + `Store.mark_today(lang)` + `Store.save_progress()`(공부한 날 표시, 가나와 같은 규칙), `Store.note_activity("speed")`.
- 새 기록이면 결과에 "새 기록!"(도형 + 글자), 이전 최고 점수를 같이 보여 준다.

---

## 6. 작업 분할

### 6.1 규칙 (모든 작업 공통)
- 담당은 전부 `worker-hard`(구현·시험). 검토는 `reviewer`(§6.6 강도). 문서(Z)만 `worker`로도 가능(Haiku 아님).
- 각 작업은 **별도 worktree**: `D:\Ai\언어\app_wt\fun_<작업>`, 브랜치 `fun/<작업>`. 오케스트레이터가 §6.2 순서로 합친다. 소유 파일은 겹치지 않는다(§6.3). 다른 작업의 파일은 읽기만 하고, 고칠 필요가 생기면 오케스트레이터에게 보고한다.
- 임시 파일·로그·가짜 APPDATA 는 `<scratchpad>\w_<작업>\` 안에만 둔다. 시험이 쓰는 사용자 파일은 `user://test_fun_*` 만(시험 보호가 켜져 있다: `Store.apply_test_guard`).
- 새 `class_name` 스크립트를 더한 뒤 `godot --headless --path <worktree>\godot --import` 를 한 번 돌리고, 생성된 `.uid` 파일도 같이 둔다(저장소가 `.uid` 를 추적한다).
- 새 시험마다 `.tscn` 짝을 둔다(예: `kana_course_test.gd` + `kana_course_test.tscn`, `kana_test.tscn` 형식). 시험 머리 주석에 실행 명령(PC·`-- --phone`)과 마지막 줄 형식을 적는다. 새 시험의 마지막 줄 = `== <이름>: N passed, M failed ==`(실패가 있으면 종료 코드 1).
- 새 화면·카드의 색은 전부 `Pal` 토큰(`Color("#…")` 직접 쓰기 금지), 글자 크기는 `Ds.fs(n)`/`UI.label` 변형, 최소 12. 눌리는 것은 `Button`/`BaseButton`.

### 6.2 의존 순서와 병렬
```
1파 (동시에 4명):  D1 기록 계약  ∥  K1 가나 코스 로직  ∥  Q1 스피드 데이터·로직  ∥  R1 주간 리포트 모델
2파 (1파가 합쳐진 뒤 동시에 4명):  B1 배지 엔진  ∥  B2 배지·리포트 화면  ∥  K2 가나 화면  ∥  Q2 스피드 화면
3파:  W 연결(셸·홈·연습 허브)         — 2파가 합쳐진 뒤, 단독
4파:  Z 문서(README·ROADMAP)  → reviewer 독립 검토(작업마다, 합치기 전) → 오케스트레이터 통합 시험(T7)
선택:  K0 오프라인 가나 소리 묶음 — 사용자 결정(Q1)이 "예"일 때만, K2 가 합쳐진 뒤 (kana_voice.gd 한 파일 교체)
```
| 작업 | 선행 | 동시에 해도 되는 것 |
|---|---|---|
| D1 | 없음 | K1, Q1, R1 |
| K1 | 없음 | D1, Q1, R1 |
| Q1 | 없음 | D1, K1, R1 |
| R1 | 없음 | D1, K1, Q1 |
| B1 | D1, K1 (스냅샷이 `StudyLog` 새 함수·`KanaCourse.pairs()` 를 읽음) | B2, K2, Q2 |
| B2 | R1 (`WeekReport`) | B1, K2, Q2 (배지 데이터는 `provider` 로 받아서 `BadgeEngine` 클래스를 참조하지 않음) |
| K2 | D1, K1 | B1, B2, Q2 |
| Q2 | D1, Q1 | B1, B2, K2 |
| W | B1, B2, K2, Q2, (R1) | 없음(공유 파일 소유) |
| Z | W | — |
| K0(선택) | K2 | — |

공유 파일(메뉴·홈·연습 허브·셸)은 **W 한 작업**에만 있다. `study_log.gd`·`store.gd` 는 D1 한 작업에만 있다(다른 작업은 D1 이 합쳐진 뒤 그 함수를 쓴다).

### 6.3 소유권 표 (수정 허용 파일. 이 밖은 수정 금지)
**기존 파일 수정**은 "수정" 열, **새 파일**은 "새" 열. 새 시험은 `.gd` + `.tscn`(+ 생성된 `.uid`) 한 벌.

| 작업 | 수정(기존 파일) | 새(파일) |
|---|---|---|
| D1 | `godot\scripts\core\study_log.gd`, `godot\scripts\autoload\store.gd`, `godot\tests\study_log_test.gd` | `godot\tests\study_log_fun_test.gd`(+tscn), `godot\tests\sample_studylog_fun.json` |
| K1 | (없음) | `godot\scripts\core\kana_course.gd`, `godot\scripts\core\kana_typing.gd`, `godot\scripts\core\kana_voice.gd`, `godot\tests\kana_course_test.gd`(+tscn) |
| Q1 | (없음) | `godot\scripts\core\speed_pool.gd`, `godot\scripts\core\speed_logic.gd`, `godot\data\speed_words.json`, `godot\tools\build_speed_words.gd`, `godot\tests\speed_logic_test.gd`(+tscn), `godot\tests\speed_words_test.gd`(+tscn) |
| R1 | (없음) | `godot\scripts\core\week_report.gd`, `godot\tests\week_report_test.gd`(+tscn) |
| B1 | `godot\scripts\core\song_due.gd`, `godot\tests\song_due_test.gd` | `godot\scripts\core\badge_defs.gd`, `godot\scripts\core\badge_rules.gd`, `godot\scripts\core\badge_engine.gd`, `godot\scripts\core\badge_watcher.gd`, `godot\tests\badge_rules_test.gd`(+tscn), `godot\tests\badge_engine_test.gd`(+tscn) |
| B2 | `godot\scripts\views\stats_view.gd`, `godot\tests\stats_view_test.gd` | `godot\scripts\ui\fun_parts.gd`, `godot\scripts\views\badge_view.gd`, `godot\tests\fun_parts_test.gd`(+tscn), `godot\tests\badge_view_test.gd`(+tscn) |
| K2 | `godot\scripts\practice\kana_screen.gd`, `godot\tests\kana_test.gd` | `godot\scripts\practice\kana_course_view.gd`, `godot\scripts\practice\kana_type_box.gd`, `godot\tests\kana_course_screen_test.gd`(+tscn) |
| Q2 | (없음) | `godot\scripts\practice\speed_screen.gd`, `godot\tests\speed_screen_test.gd`(+tscn) |
| W | `godot\scripts\main.gd`, `godot\scripts\views\today_view.gd`, `godot\scripts\views\practice_view.gd`, `godot\tests\home_view_test.gd`, `godot\tests\practice_test.gd`, `godot\tests\ui_practice_widgets_test.gd`, `godot\tests\t5_wiring_test.gd` | `godot\tests\fun_wiring_test.gd`(+tscn) |
| Z | `README.md`, `ROADMAP.md` | (없음) |
| K0(선택) | (없음. 단 `core\kana_voice.gd` 는 아래 "소유 이전" 참고) | `godot\tools\build_kana_audio.gd`, `godot\data\kana_audio.json`, `godot\tests\kana_voice_test.gd`(+tscn) |

- 같은 파일을 두 작업이 소유하는 줄은 없다. **소유 이전(선택 작업 K0 만):** 사용자가 Q1 에 "예"라고 하면, 2파가 모두 합쳐지고 K1 이 끝난 뒤 오케스트레이터가 `core\kana_voice.gd` 의 소유를 K0 에게 넘긴다(K1 은 그때 끝나 있어 동시 편집이 없다. K0 의 합격 조건 C-6 은 이 파일을 허용 목록에 더해서 판정).
- 오케스트레이터는 합치기 전에 이 검사를 돌린다: `git -C <worktree> diff --name-only <기준 커밋>` 가 그 작업의 "수정+새" 목록의 부분집합.
- 소유 밖이지만 **읽기만** 하는 파일: `kana_data.gd`, `kana_hangul.gd`, `sync\*`, `fsrs.gd`, `streak_calc.gd`, `plan.gd`, `home_model.gd`, `home_parts.gd`, `menu_view.gd`, `app_view.gd`, `tts.gd`, `system_tts.gd`, `speak_drill.gd`, `ui.gd`, `pal.gd`, `ds.gd`, `glyph.gd`.
- 수정 금지(어느 작업도 소유하지 않음): `godot\project.godot`, `godot\export_presets.cfg`(권한·버전), `godot\scripts\sync\*`, `godot\scripts\core\kana_data.gd`, `core\kana_hangul.gd`, `core\home_model.gd`, `ui\home_parts.gd`, `ui\ui.gd`, `core\pal.gd`, `ui\ds.gd`, `ui\glyph.gd`(새 도형이 필요하면 기존 `sparkle/star/lock/check/close/play` 로 해결), `packaging\*`, `backend\*`, `godot\data\pack\*`.

### 6.4 공통 합격 조건 (모든 작업에 붙는다)
시험 명령 형식: `$G = 'C:\Users\rtyu6\Desktop\Godot_v4.6.3-stable_win64.exe\Godot_v4.6.3-stable_win64_console.exe'`, `$env:APPDATA = '<scratchpad>\w_<작업>\appdata'`(실제 사용자 폴더를 읽고 쓰지 않게), 실행 `& $G --headless --path <worktree>\godot [--resolution 412x915] res://tests/<이름>.tscn [-- --phone] [--font-scale=1.5] [--dark]`.

| ID | 조건 | 판정 |
|---|---|---|
| C-0 | **작업 전** 자기가 건드리는 기존 시험의 기준선을 잰다: 각 시험의 마지막 줄 `N passed, M failed` 와 종료 코드를 `<scratchpad>\w_<작업>\baseline.txt` 에 적고 보고서 맨 앞 표에 붙인다 | 파일이 있고 표에 있음 = O |
| C-1 | 자기 시험 전부: 마지막 줄이 `N passed, 0 failed ==` 이고 종료 코드 0. PC 실행과 `-- --phone` 실행 둘 다(화면이 없는 순수 계산 시험은 PC 한 번) | O/X |
| C-2 | 출력에 `SCRIPT ERROR:` 0줄 | 0건 = O |
| C-3 | 출력에 `TEST_GUARD on` 이 정확히 1줄 | 1건 = O |
| C-4 | 접속 금지: 출력·코드·명령에 `8770`, `8775`, `8776` 이 0번. 새 파일에 `HTTPRequest`, `Api.`, `Route.`, `OS.shell_open`, `OS.request_permission` 0줄(단 `kana_voice.gd` 는 `Tts`·`Api.base_url` 읽기 1곳 허용). 화면 시험은 `--api=http://127.0.0.1:9`(닫힌 포트)만 | `rg -n "HTTPRequest\|Api\.\|Route\.\|OS\.shell_open\|OS\.request_permission" <새 파일>` 0줄(예외 명시) |
| C-5 | **기존 시험 기대값을 근거 없이 완화하지 않는다.** 시험 파일 diff 에서 지워지거나 느슨해진 단언은 §6.5 에 적힌 것만. 기준선 passed 보다 줄면 줄어든 이유가 §6.5 에 있어야 한다 | diff 검토 + 표 대조 |
| C-6 | 소유 밖 파일 수정 0: `git -C <worktree> diff --name-only <기준 커밋>` ⊆ §6.3 의 그 작업 목록 | 부분집합 = O |
| C-7 | 안드로이드 권한·버전·autoload 변경 0: `git -C <worktree> diff --stat -- godot\project.godot godot\export_presets.cfg` 가 비어 있다 | 비어 있음 = O |
| C-8 | 프로세스는 자기가 시작한 PID 만 종료. 이 설계의 시험은 서버가 필요 없다. 보고에 "남은 프로세스·열린 포트 없음" | 보고 문구 |
| C-9 | 실제 사용자 폴더(`%APPDATA%\Godot\app_userdata\…`) 쓰기 0: 시험 전후 이름·크기·수정 시각 목록 비교가 같다(파일 내용은 열지 않음). 새 시험은 `Store.prefs_path`, `Store.progress_path`, `StudyLog.path`, `SongStore.root` 를 `user://test_fun_*` 로 바꿔 쓴다 | 전후 같음 |
| C-10 | 비밀값(키·토큰·auth) 출력·기록 0 | 보고에 없음 |
| C-11 | 새 파일에 이모지·도형 글자(★✦🔥♥ 등) 0, `Color("#` 0, 다른 앱 이름·상표 0: `rg -n -i "duolingo\|듀오\|올빼미\|flame\|불꽃\|#58CC02\|#1CB0F6\|#FF9600\|Color\(\"#" <새·바뀐 파일>` 0줄 | 0줄 |
| C-12 | **검사기도 실패할 수 있어야 한다**: 새 시험마다 일부러 틀린 입력을 같은 검사 함수에 넣어 "실패로 판정되는지"를 찍는 줄이 있다(`selfcheck FAIL-as-expected …`). 더해서 작업자는 코드 상수 하나를 일부러 틀리게 바꾼 뒤(작업마다 §6.5 에 지정) 시험이 **실패하는** 출력 줄을 보고서에 붙이고 원래대로 되돌린다 | 출력 줄 존재 |
| C-13 | 읽지 못한 결과·실행하지 않은 항목은 O 가 아니라 "미검증" | 보고 형식 |

보고 맨 앞: 합격 조건 표(항목 / O·X·미검증 / 근거 = 실행한 명령과 출력 요약).

### 6.5 작업별 상세

#### D1 — 기록 계약 (`worker-hard`, 1파)
- 소유: §6.3 표의 D1 줄.
- 하는 일: §5.1 정규화(`_norm_speed`, `_norm_badges`, `_norm_kana_course`, `_normalize` 에서 `src.has(키)` 일 때만 넣음, `_blank()` 는 건드리지 않음), §5.3 함수들, `KINDS` 에 `"newcards"`, `KNOWN_KEYS` 갱신, `Store.activity` 신호·`note_activity`, `Store.add_review` 의 `newcards` 집계, `longest_streak`. 기존 함수 동작은 바꾸지 않는다.
- 합격 조건:

| ID | 조건 | 명령 → 기대 |
|---|---|---|
| D1-1 | 새 시험 통과 | `study_log_fun_test` PC·`-- --phone` → `== study_log_fun: N passed, 0 failed ==` |
| D1-2 | 옛 파일 호환: 새 키가 없는 파일(`sample_studylog_path.json` 형식)을 읽고 `flush()` 한 뒤 `snapshot()` 에 `speed`·`badges`·`kana_course` 키가 **없다** | 시험 줄 "old file: no new keys" PASS |
| D1-3 | 모르는 최상위 키 보존: `sample_studylog_v99.json` 로드→저장→다시 로드해도 모르는 키가 그대로 | 기존 `study_log_test` 의 해당 줄 PASS(수정 없이) |
| D1-4 | 정규화가 깨진 입력을 막는다(일부러 틀린 입력): `speed.en.plays = "x"`, `-5`, `NaN` 같은 값, `ok > total`, `best.score = 1e12`, 잘못된 날짜 `"2026-13-40"`, `badges.got` 의 `"Bad ID!"`·길이 33 id·값이 문자열, 101개째 배지, `seen` 에 `got` 에 없는 id·중복, `kana_course.done` 의 `"zz"`·`"h12"`·`"p_x"`, `best` 가 150 | 각각 시험 줄 PASS(값이 0 또는 범위 안으로 정리되고 나쁜 항목은 버려짐) + 에러 로그 0 |
| D1-5 | `add_speed_run`: 4문제(< 5)는 `recorded == false` 이고 파일 상태 불변, 5문제·점수 300 → `new_best == true`, 이어서 점수 200 → `new_best == false` 이고 `speed_best.score == 300` 유지, `correct > total`·잘못된 언어는 `recorded == false` | 시험 PASS |
| D1-6 | `grant_badge`: 새로 받으면 true, 같은 id 다시 false, 형식 틀린 id false, 100개 뒤 false. `has_badge_record()` 는 첫 `grant_badge`·`init_badge_record()` 전 false → 후 true, `init_badge_record()` 를 두 번 불러도 `got` 불변. `mark_badges_seen` 은 `got` 에 없는 id 를 무시 | 시험 PASS |
| D1-7 | `add_kana_course_try("h1", 12, 15, true)` → `done.h1` = 오늘, `best.h1 == 80`, `tries.h1 == 1`; 다시 `(9, 15, false)` → `best` 80 유지·`tries == 2`·`done` 유지; `("x9", 1, 1, true)` 는 false | 시험 PASS |
| D1-8 | `newcards`: 빈 복습 목록에 영어 2 + 일본어 1 + 중복 1 을 `Store.add_review` → 오늘 `range_summary("en",1)[0]["n"]["newcards"] == 2`, `"ja"` 는 1. `apply_sync_progress` 로 카드가 들어와도 `newcards` 불변 | 시험 PASS |
| D1-9 | 동기화가 새 키를 지우지 않는다: 새 키 3개가 있는 상태에서 `StudyLog.apply_sync({"days": {...}})` 한 뒤에도 `speed`·`badges`·`kana_course` 가 그대로, `SyncDoc.extract` 결과(보기)에 이 키들이 없다 | 시험 PASS |
| D1-10 | `longest_streak`: `progress.days` 에 7일 연속 + 하루 빠짐 + 3일 연속, 빠진 하루가 보호권 날이면 10(7 + 3, 보호된 날은 잇기만), 아니면 7. 미래 날(오늘보다 뒤)은 무시. 기록 없으면 0 | 시험 PASS |
| D1-11 | 동기화·기록 회귀 없음 | `run_sync_tests.ps1`(기준선 대비 passed 수 이상, 0 failed), `study_log_test`, `streak_test`, `persist_test`, `test_guard_test`, `kana_test`, `home_model_test`, `stats_view_test` 모두 `0 failed`, passed ≥ 기준선 |
| D1-12 | 상수를 일부러 틀리게 | `SPEED_MIN_ANSWERED` 를 5 → 1 로 바꾸면 D1-5 가 FAIL 하는 줄을 보고에 붙이고 원복 |
- 금지: `SyncDoc`/`SyncMerge`/`SyncEngine` 수정, `VERSION` 변경, `_blank()` 에 새 키 추가, `KINDS` 에 `newcards` 외 추가, 기존 `add_*` 함수의 의미 변경, 소유 밖 파일.

#### K1 — 가나 코스 로직 (`worker-hard`, 1파)
- 소유: §6.3 표의 K1 줄. **기존 파일을 고치지 않는다**(`kana_data.gd` 는 읽기만).
- 하는 일: §5.3 의 `KanaCourse`, `KanaTyping`, `KanaVoice`, §5.7 의 단계 24개·짝 21쌍(`tip` 문구 초안)·입력 정답 표.
- 합격 조건:

| ID | 조건 | 명령 → 기대 |
|---|---|---|
| K1-1 | 시험 통과 | `kana_course_test` → `== kana_course: N passed, 0 failed ==` |
| K1-2 | 단계 구성: `stages("hira")` 가 11개 + `p_h`, `stages("kata")` 가 11개 + `p_k`(합 24). `h1..h11` 의 글자 합집합 = `KanaData.entries("hira")` 의 104글자 전부(겹침 0), `k1..k11` 도 104 | 시험 줄 PASS |
| K1-3 | 짝 21쌍(히라가나 10·가타카나 11): 두 글자 모두 `KanaData.has`, 한글 소리 `ko` 가 서로 다름, 두 글자가 `group` 묶음의 `chars` 안에 있음, 짝 id 중복 없음, `シ/ツ`·`ソ/ン`·`ぬ/め` 가 포함 | 시험 줄 PASS |
| K1-4 | `build_stage_test` 15문제: 종류 개수가 듣기 5·읽기 5·입력 5(`sound=false` 면 읽기 10·입력 5), 모든 글자가 그 단계 글자 안, 연속 같은 글자 없음, 200개 난수 시드에서 모두 유효(`check_question` 검사기: 보기 4개의 한글 소리가 서로 다르고 정답 번호의 글자가 `ch`) | 시험 PASS |
| K1-5 | 짝 문제: 200개 시드에서 모든 문제의 보기에 **정답과 그 짝 글자가 모두 포함**, 보기 4개 한글 소리 모두 다름 | 시험 PASS |
| K1-6 | 입력 채점: 208글자 전부에서 `check(e, e.ro)`·`check(e, e.ko)` 가 true. 대문자 `SHI`, 앞뒤 공백 ` shi `, 전각 `ｓｈｉ` 도 true. §5.7 표의 추가 정답(si, tu, wo, nn …)이 true | 시험 PASS |
| K1-7 | **일부러 틀린 입력**: `check(し, "")`, `"  "`, `"ka"`(き 에 대해), `"ㅅ"`, `"시시"`, `"shi?"`, `check({}, "a")` 는 모두 false 이고 에러 없음. `KanaCourse.stage_by_id("zz")` = `{}`, `build_stage_test("zz", …)` = `[]` | 시험 줄 `selfcheck FAIL-as-expected …` 와 PASS |
| K1-8 | 질문 검사기 자체 점검: 보기에 같은 한글 소리가 2개 든 가짜 문제, 정답 번호가 틀린 문제, 짝 글자가 빠진 짝 문제를 검사기에 넣으면 각각 실패로 판정 | `selfcheck FAIL-as-expected` 3줄 |
| K1-9 | `is_passed(12,15)` true, `(11,15)` false, `(0,0)` false. `next_stage("hira", {"h1":…,"h2":…})` = `"h3"`, 전부 했으면 `""` | 시험 PASS |
| K1-10 | `KanaVoice.speak("あ")`: 시험이 `Tts.fetch_hook` 으로 합성 소리를 바꿔 끼우면 호출 1번, 소리를 낼 수 없는 상태(시스템 음성에 일본어 없음 / PC 연결 없음)면 false 이고 `Tts` 를 부르지 않음 | 시험 PASS(`kana_test` 의 `VoiceFake` 방식) |
| K1-11 | 기존 시험 회귀 없음 | `kana_test`, `kana_hangul_test` 0 failed, passed ≥ 기준선(둘 다 수정하지 않음) |
| K1-12 | 상수를 일부러 틀리게 | `STAGE_PASS` 12 → 8 로 바꾸면 K1-9 가 FAIL 하는 줄을 붙이고 원복 |
- 금지: `kana_data.gd`·`kana_hangul.gd`·`study_log.gd` 수정, `StudyLog`·`Store` 직접 읽기(통계는 인자로), 네트워크 호출, 소유 밖 파일.

#### Q1 — 스피드 데이터·로직 (`worker-hard`, 1파)
- 소유: §6.3 표의 Q1 줄.
- 하는 일: §5.4 도구와 데이터 파일 생성(실행해서 `speed_words.json` 커밋), §5.3 `SpeedPool`·`SpeedLogic`, §5.8 규칙.
- 합격 조건:

| ID | 조건 | 명령 → 기대 |
|---|---|---|
| Q1-1 | 도구 실행 | `& $G --headless --path <wt>\godot --script res://tools/build_speed_words.gd` → 마지막 줄에 `speed_words: en=<N> ja=<M> bytes=<B>` 형식, 종료 코드 0. 같은 명령을 두 번 돌려 `speed_words.json` 이 바이트 단위로 같다(결정적) |
| Q1-2 | 데이터 시험 | `speed_words_test` → `0 failed`: 영어 ≥ 500, 일본어 ≥ 600, 파일 ≤ 400,000바이트, 모든 항목에 `w`(비지 않음)·`ko`(1~12자)·`pos`(4종)·`m`(1~12 정수)·`v`(bool), 일본어는 `rd` 가 가나뿐, 같은 `w` 중복 없음, 월 1~12 중 단어가 15개 미만인 달이 있으면 시험이 그 달 번호를 출력(통과 여부와 별개로 보고) |
| Q1-3 | 뜻 품질 표본 점검 | 작업자는 무작위(시드 고정) 영어 30개·일본어 30개의 `w → ko` 를 출력해 보고서에 붙이고, **명백히 틀린 뜻을 표시**한다(3개 이하면 O, 넘으면 `v == true` 만 쓰도록 도구 규칙을 조이고 다시). 검토자가 다른 시드 30+30개로 한 번 더 본다 |
| Q1-4 | 풀 구성: 카드 20장 + 레슨 단어로 `SpeedPool.build` → `ok`, `n_cards ≥ 1`, `n_words ≥ 1`. 카드 0장 + 레슨 단어만 → `ok`. 카드 3장 + 단어 0개 → `ok == false`, `reason == "pool_small"` | 시험 PASS |
| Q1-5 | 문제 생성 300개 시드: 보기 4개의 뜻이 모두 다르고, 어떤 보기도 정답과 `ko_tokens` 가 겹치지 않으며(예: 정답 "좋다" 에 "좋다" 가 든 오답 없음), `answer` 번호의 뜻 = 정답 뜻, 일본어 항목은 `rd` 보존 | 시험 PASS(검사기 함수 `check_question`) |
| Q1-6 | `SpeedLogic` 점수: 정답 5연속 점수 = 10+12+14+16+18 = 70, 오답 뒤 콤보 0, 다시 정답은 10. 콤보 12 연속에서 점수 증가분이 30 에서 멈춤 | 시험 PASS |
| Q1-7 | 시간: `start(0)`, `answer(i, 59_999)` 는 반영, `answer(i, 60_001)` 는 `accepted == false`·점수 불변. 오답 직후 899ms 에 답하면 `accepted == false`, 900ms 에 받음. `pause(10_000)` 후 `resume(20_000)` 이면 남은 시간이 정지 전과 같다. `tick` 은 끝난 뒤 계속 true | 시험 PASS |
| Q1-8 | **일부러 틀린 입력**: `answer(-1, …)`, `answer(4, …)`, `answer(0, NAN)`, 음수 `now_ms`, 시간이 거꾸로 가는 `now_ms`(직전보다 작음), 같은 문제에 두 번 답하기, 시작 전 `answer`, 빈 항목 목록으로 `SpeedLogic.new([])` → 모두 에러 없이 `accepted == false` 또는 빈 결과 | 시험 `selfcheck FAIL-as-expected` 줄 PASS |
| Q1-9 | 깨진 데이터: `speed_words.json` 대신 깨진 JSON·`en` 키 없는 파일·`ko` 가 숫자인 항목을 가리키는 시험용 경로(`SpeedPool.words_path` 같은 시험 훅)로 `load_words` → `ok == false`(또는 나쁜 항목만 버림)이고 에러 없이 앱이 계속 동작 | 시험 PASS |
| Q1-10 | 카드 항목 거르기: `ko` 빈 카드·`target` 너무 긴 카드·`lang` 다른 카드는 항목에 들어가지 않는다 | 시험 PASS |
| Q1-11 | 상수를 일부러 틀리게 | `COMBO_CAP` 10 → 3 으로 바꾸면 Q1-6 이 FAIL 하는 줄을 붙이고 원복 |
- 금지: `data\pack\*`·`manifest.json` 수정(읽기만), `StudyLog`·`Store` 쓰기(`Store.review_for` 같은 읽기는 인자로 받은 카드로 대체: `SpeedPool` 은 카드 배열을 **인자로** 받는다), 소유 밖 파일. 도구는 `data\pack\*` 를 읽기만 하고 다른 파일을 쓰지 않는다.

#### R1 — 주간 리포트 모델 (`worker-hard`, 1파)
- 소유: §6.3 표의 R1 줄. 하는 일: §5.3 `WeekReport`, §5.6 규칙.
- 합격 조건:

| ID | 조건 | 명령 → 기대 |
|---|---|---|
| R1-1 | 시험 통과 | `week_report_test` → `== week_report: N passed, 0 failed ==` |
| R1-2 | 계산: 손으로 만든 14일 입력(공부 시간·레슨 6개 중 5개 정답·점수 합·복습·`newcards`)에서 `minutes`, `minutes_delta`, `lesson_acc`(= 정수 반올림), `score_avg`, `days_studied` 가 손계산과 같다 | 시험 PASS(기대값은 시험 안에 계산 근거 주석) |
| R1-3 | 경계: 이번 주만 있고 지난 주 0 → `minutes_prev == 0`, 문구 규칙 4번(또는 규칙 2 가 안 걸림). 두 주 다 0 → `empty == true`, 문구 1번. 레슨 0 → `lesson_acc == -1`. 점수 `score_n` 2 와 5 → `score_delta == null`, 3 과 3 → 숫자 | 시험 PASS |
| R1-4 | **일부러 틀린 입력**: 항목이 5개뿐인 배열, 빈 배열, `null`, 항목이 숫자·문자열, `sec` 가 음수·`NaN`·문자열, `n` 이 배열, `score_sum > score_n*100`, 날짜가 거꾸로 | 모두 에러 없이 0/-1 로 정리되고 `empty` 판정이 맞다 |
| R1-5 | `for_lang` 실제 연결: 시험용 `StudyLog.path`·`today_override` 로 14일치 기록을 직접 넣은 뒤 `for_lang("en")` 결과가 R1-2 와 같은 규칙으로 맞다. `from`/`to` 날짜 = 오늘−6 / 오늘 | 시험 PASS |
| R1-6 | 같은 입력 두 번 호출 결과가 같고 입력 배열이 바뀌지 않는다 | 시험 PASS |
| R1-7 | 상수를 일부러 틀리게 | "비교 최소 표본 3" 을 1 로 바꾸면 R1-3 이 FAIL 하는 줄을 붙이고 원복 |
- 금지: `StudyLog`·`Store` 쓰기, `for_lang` 밖에서 `StudyLog` 읽기, 소유 밖 파일.

#### B1 — 배지 엔진 (`worker-hard`, 2파, 위험도 높음: 영구 기록·소급)
- 소유: §6.3 표의 B1 줄. 하는 일: §5.3 `BadgeDefs`·`BadgeRules`·`BadgeEngine`·`BadgeWatcher`, §5.5 표 23개, `SongDue` 에 `done`(다 외운 곡 수) 집계 추가(`compute`/`_tally`/`cache` 기본값·`_blank` 에 키 `"done"` 한 개, 기존 키 의미 불변).
- 평가 흐름: `retro = not StudyLog.has_badge_record()` 를 먼저 정하고 `StudyLog.init_badge_record()` → `snapshot()` → `BadgeRules.earned_ids` → 이미 받은 것 제외 → `StudyLog.grant_badge(id, retro)` → `StudyLog.flush()` → 알림. 평가 동작 규칙: `retro = not StudyLog.has_badge_record()` 이던 첫 평가. 알림은 평가 한 번에 최대 1개(§5.5). `BadgeWatcher`: `Store.activity`·`Store.changed` 를 받으면 0.3초 뒤(여러 신호는 한 번으로) 평가, 30초 타이머는 `StudyLog.is_dirty()` 가 참이거나 마지막 평가 뒤 `Store.changed` 가 있었을 때만 평가, 평가 사이 최소 2초.
- 합격 조건:

| ID | 조건 | 명령 → 기대 |
|---|---|---|
| B1-1 | 규칙 시험 | `badge_rules_test` → `0 failed`: 23개 배지마다 "목표 − 1 → 못 받음, 목표 → 받음" 경계 2줄 |
| B1-2 | 표 = 코드: `BadgeDefs.all()` 의 id·`measure`·`target`·`cat` 이 §5.5 표와 같다(시험 안에 표를 복사해 대조). id 중복 0, 모든 `name`·`desc` 비지 않음, `cat` 이 `categories()` 에 있음, 개수 23 | 시험 PASS |
| B1-3 | `MISSION_IDS` 8개가 `StatsView.MISSION_ORDER` 와 같다 | 시험 PASS |
| B1-4 | **일부러 틀린 스냅샷**: 값이 문자열·`null`·음수·`NaN`·`INF`·`true`·배열인 키, 빈 사전, 키 일부 없음 → 아무 배지도 못 받고 에러 0. 한 키만 좋은 값이면 그 배지만 받음 | 시험 `selfcheck FAIL-as-expected` PASS |
| B1-5 | 엔진 시험 | `badge_engine_test` → `0 failed`(PC·`-- --phone`) |
| B1-6 | 소급: 기록이 풍부한 가짜 상태(레슨 12번, 연속 8일, 시간 2시간, 카드 25장, 미션 별 3개 1개)에서 첫 `evaluate()` → `first_lesson, lessons_10, cards_20, streak_3, streak_7, time_1h, mission_star3` 가 `retro == true` 로 들어가고 토스트가 **정확히 1개**("이미 달성한 배지 7개를 모았어요" 형식) | 시험 PASS(`Toast.message` 신호 수 세기) |
| B1-7 | 두 번째 평가: 같은 상태로 `evaluate()` 다시 → 새로 받은 것 0, 토스트 0, `got` 불변. 값이 올라서 `lessons_50` 조건이 되면 → 그 배지만 `retro == false` 로 받고 이름이 든 토스트 1개 | 시험 PASS |
| B1-8 | 빈 기록에서 첫 평가: 받는 배지 0, 토스트 0, `StudyLog.init_badge_record()` 가 불려 **`has_badge_record()` 는 참이 되고**, 그 뒤에 받는 배지는 `retro == false`(소급 판정이 한 번만) | 시험 PASS |
| B1-9 | 시계를 되돌려도(`StudyLog.today_override` 를 과거로) 받은 배지·`at` 불변, 연속 배지는 `longest_streak` 가 과거로 가도 다시 빼앗지 않음 | 시험 PASS |
| B1-10 | 가나 스냅샷: 청음 히라가나 46글자 전부 `ok 4, bad 0` 기록 → `kana_hira` 받음, 45개만 → 못 받음. `kana_all` 은 208개 모두일 때만. `kana_pairs` 는 짝 글자 전부 숙련 3일 때만 | 시험 PASS |
| B1-11 | 노래: `SongDue` 가짜 `lister`(기존 시험 방식)로 곡 1개 `total 6, memorized 6` → `done == 1` → `song_done` 받음. `total 3, memorized 3`(< 4줄)·`memorized 5 of 6` 는 못 받음. 기존 `song_due_test` 0 failed, passed ≥ 기준선 | 시험 PASS |
| B1-12 | `ui_list()`: 23개, 표 순서, `got`·`at`·`value`·`target`·`is_new`(받았지만 `seen` 에 없음)가 맞다. `mark_all_seen()` 뒤 `is_new` 전부 거짓, `counts().unseen == 0` | 시험 PASS |
| B1-13 | `BadgeWatcher`: `Store.activity.emit("speed")` 를 3번 연달아 보내도 평가는 1번(디바운스), 2초 안에 다시 와도 한 번 더 돌지 않음(가짜 시계/카운터로 확인). `Store` 신호 없이 `StudyLog` 가 깨끗하면 30초 타이머가 평가를 건너뜀 | 시험 PASS |
| B1-14 | 안전: `StudyLog.is_read_only()`(파일을 못 열어 읽기 전용)일 때 평가가 에러 없이 끝나고 받은 것이 디스크에 안 써진다는 알림 없이 조용히 건너뜀(메모리만) — 토스트 0 | 시험 PASS |
| B1-15 | 성능: `snapshot()` + `evaluate()` 를 기록 400일 × 2언어 가득 + 글자 208개 상태에서 100회 돌려 1회 평균 < 20ms(PC 헤드리스 기준, 시험이 평균을 출력. 폰 값은 **미검증**으로 표시) | 시험 PASS |
| B1-16 | 회귀 없음 | `song_due_test`, `home_model_test`, `home_view_test`, `study_log_test`, `study_log_fun_test` 0 failed, passed ≥ 기준선 |
| B1-17 | 상수를 일부러 틀리게 | `streak_7` 의 target 7 → 6 으로 바꾸면 B1-1 이 FAIL 하는 줄을 붙이고 원복 |
- 금지: 배지 회수(삭제)·`got` 덮어쓰기, 알림 2개 이상, `StudyLog`/`Store` 소유 파일 수정(D1 의 함수만 사용), `SongDue` 의 기존 키 의미 변경, 파일 시스템을 직접 읽는 곡 스캔 추가(`SongDue` 의 기존 읽기 경로만), 소유 밖 파일.

#### B2 — 배지·리포트 화면 (`worker-hard`, 2파)
- 소유: §6.3 표의 B2 줄. 하는 일: §5.3 `FunParts`·`BadgeView`, §4.4·4.5·4.6 화면, `StatsView` 의 `GoalCard.full` 바로 아래에 `FunParts.report_card(WeekReport.for_lang(lang))` 한 장 추가(그 밖의 `StatsView` 동작 불변).
- 합격 조건:

| ID | 조건 | 명령 → 기대 |
|---|---|---|
| B2-1 | 시험 통과 | `fun_parts_test`, `badge_view_test`, `stats_view_test` 각각 PC 와 `-- --phone`(412x915) → `0 failed` |
| B2-2 | 배지 화면: 가짜 `provider` 로 23개를 넣으면 타일 23개, 받은 것·못 받은 것 구분(받은 것: 이름+날짜, 못 받은 것: 자물쇠 도형 + `value/target` 글자). 필터 `speed` 를 누르면 `visible_ids()` 가 3개(speed 카테고리)만. 필터 "전체" 복귀 | 시험 PASS |
| B2-3 | 타일을 누르면 시트가 열리고 그 배지의 이름·설명·진행이 있다(`Sheet.is_open()` 참, 안의 글자 확인). 시트를 닫으면 `Sheet.depth() == 0` | 시험 PASS |
| B2-4 | 새 배지 점: `provider` 가 준 항목의 `is_new` 가 참이면 타일에 점 도형이 있다. 화면이 보일 때(`refresh`) `BadgeView` 는 **콜백 `on_seen: Callable`**(W 가 `BadgeEngine.mark_all_seen` 을 꽂는다)만 부르고 `StudyLog`·`BadgeEngine` 은 직접 부르지 않는다. 같은 화면을 다시 열면(`provider` 가 `is_new` 를 거짓으로 줌) 점이 없다 | 시험 PASS |
| B2-5 | 리포트 카드: 가짜 `report`(기록 많음 / 지난주 없음 / 전부 0 / 점수 표본 적음)로 4가지 모양이 그려지고 각 필수 글자("공부 시간", "레슨", "새 카드", "발음 점수")가 있다. 전부 0 이면 "아직 기록이 없어요" 계열 한 줄 | 시험 PASS |
| B2-6 | 홈 카드: `home_card("ja", …)` 는 버튼 3개(60초 퀴즈·가나 코스·배지), `home_card("en", …)` 는 2개(가나 코스 없음). 버튼을 누르면 `on_open` 이 `"speed"`/`"kana"`/`"badges"` 로 불림. 카드 본문을 누르면 `"report"` | 시험 PASS |
| B2-7 | 레이아웃(폰 412x915, 글자 150%, 다크): 배지 타일·버튼이 가로로 삐져나오지 않는다(`size.x ≤ 부모`), 눌리는 것 높이 ≥ 44(홈 카드 버튼 ≥ 48), 글자 최소 12. PC 1280x800 에서 타일 5열 | 시험 PASS(`--font-scale=1.5`, `--dark` 각각 한 번) |
| B2-8 | **일부러 틀린 입력**: `provider` 가 빈 배열·`null`·항목이 문자열·`value > target`·`target == 0`(0 나눔)·이름 없음 → 에러 0, 나쁜 항목은 건너뜀. `report` 가 `{}`·`null` → 카드가 "기록 없음"으로 그려짐 | 시험 PASS |
| B2-9 | 대비·접근성: `contrast_test`, `a11y_sweep_test`(PC·`--dark`) 0 failed, passed ≥ 기준선(새 색을 만들지 않고 `Pal` 토큰만 쓴다) | 기준선 비교 |
| B2-10 | 기록 화면 회귀: `stats_view_test` 기존 단언 전부 유지(지운 단언 0), 리포트 카드가 `GoalCard` 아래·주간 막대 카드 위에 있다 | diff + PASS |
| B2-11 | 상수를 일부러 틀리게 | 타일 열 수(폰 3) 를 6 으로 바꾸면 B2-7 이 FAIL 하는 줄을 붙이고 원복 |
- 금지: `BadgeEngine`·`StudyLog`·`Store` 의 배지 함수를 `badge_view.gd`/`fun_parts.gd` 에서 직접 부르기(데이터는 `provider`/인자/콜백으로 받는다. `WeekReport.for_lang` 은 `StatsView` 에서만 직접 호출), 새 색·새 글꼴·이모지, `GlyphIcon` 새 도형 추가, 소유 밖 파일.

#### K2 — 가나 화면 (`worker-hard`, 2파)
- 소유: §6.3 표의 K2 줄. 하는 일: §4.2 화면: `KanaScreen` 에 단계 `course`·`stage_intro`·`stage_test`·`stage_result`·`pairs`, 표/코스 segmented, 입력 문제(`kana_type_box.gd`: `LineEdit` + 확인 버튼 + 정답 표시), 퀴즈 설정에 "입력" 종류, `open(l, args)` 에 `args.view == "course"`, 소리는 `KanaVoice` 로(기존 `KanaScreen.sound_available()`·`no_sound_text()`·`play_kana()` 는 **같은 이름·같은 동작으로 남겨** 얇게 위임). 시험 끝에 `StudyLog.add_kana_course_try`, `add_kana_run`, `Store.note_activity("kana")`, 통과하면 토스트 한 줄.
- 합격 조건:

| ID | 조건 | 명령 → 기대 |
|---|---|---|
| K2-1 | 기존 가나 시험 유지 | `kana_test` PC·`-- --phone` → `0 failed`, passed ≥ 기준선, 지운·완화한 단언 0(`git diff -U0 godot\tests\kana_test.gd` 의 `-` 줄은 새 상태 이름을 반영하느라 불가피한 것만 §6.5 에 줄 번호로 적는다) |
| K2-2 | 새 시험 | `kana_course_screen_test` PC·`-- --phone` → `0 failed` |
| K2-3 | 코스 화면: `open("ja", {"view":"course"})` 가 코스 목록을 그림: 히라가나 11 + 짝 1, 가타카나 11 + 짝 1 단계 행 24개, 추천 표시(▶)가 첫 미완료 단계에만. 단계 행 높이 ≥ 64(폰). `StudyLog.kana_course_done` 에 `h1`·`h2` 가 있으면 둘은 ✓ 이고 `h3` 이 추천 | 시험 PASS |
| K2-4 | 단계 시험 한 판 끝까지(코드로 정답을 골라 12개 맞힘): 통과 화면, `kana_course.done.h1` 기록, `tries.h1 == 1`, 글자별 `add_kana` 가 15번 올라감, 틀린 글자 [복습 카드로 추가] 가 동작(`Store.add_review` 카드 들어감) | 시험 PASS |
| K2-5 | 미통과: 11개 맞힘 → "아쉬워요/통과 못 했어요", `done` **안 생김**, `best` 는 73, [같은 단계 다시] 가 새 15문제 | 시험 PASS |
| K2-6 | 입력 문제: `answer_text("shi")` 가 し 에 맞음, 빈 입력·`"ka"` 는 틀림(틀린 것도 `add_kana(ch, false)` 로 셈), 같은 문제에 두 번 제출해도 한 번만 셈, 정답 공개에 인정되는 답이 보임. 소리 없는 기기(음성 없음)에서는 듣기 문제가 읽기로 바뀌고 안내 한 줄 | 시험 PASS |
| K2-7 | 짝 단계: 짝 칩으로 고르거나 전체 섞기, 문제에 구별 요령(`tip`)이 있으면 한 줄 보이고 없으면 줄이 없음. 10문제 한 판 → 결과 | 시험 PASS |
| K2-8 | 폰 레이아웃(412x915, 글자 150%, 다크): 코스 행·입력창·확인 버튼이 화면 밖으로 나가지 않음, 입력창 높이 ≥ 56, 확인 버튼 ≥ 56, 키보드가 올라와도(가상 키보드 높이 300 가정) 확인 버튼이 보이는 영역 안(`main.gd` 의 키보드 처리를 쓰는 기존 화면과 같은 방식) | 시험 PASS / 키보드는 실기기 **미검증** |
| K2-9 | 뒤로 가기: 단계 시험 중 `go_back()` → 코스 목록(기록 안 남김: 중간에 나간 판은 `tries` 로 세지 않음), 코스 목록 → 표, 표 → `closed` 신호 | 시험 PASS |
| K2-10 | 네트워크·AI 없음: 새로 추가한 줄에 `Api.`·`HTTPRequest`·`Route.` 0(`git diff -U0 … | rg "^\+.*(HTTPRequest\|Api\.\|Route\.)"` 0줄). `--api=http://127.0.0.1:9` 로 모든 시험 통과 | 0줄 + PASS |
| K2-11 | 한 단계 시험 중 소리 요청 횟수 = 듣기 문제 수(5)와 같고, 소리를 낼 수 없는 기기에서는 0(기존 `sound_requests`/`silent_requests` 방식) | 시험 PASS |
| K2-12 | **일부러 틀린 입력**: `open("en")`(영어)는 "일본어에서만"(기존 `unsupported`), 존재하지 않는 단계 id, `args.view = "zz"`, `start_stage("zz")`, 글자가 모자란 상태의 가짜 단계 → 에러 없이 안전한 화면 | 시험 PASS |
| K2-13 | 회귀 | `practice_test`(PC)·`ui_practice_widgets_test` 는 W 가 고치므로 K2 는 `kana_hangul_test`, `phone_layout_test --resolution 412x915 -- --phone`, `a11y_sweep_test`, `ui_perf_test` 를 기준선 비교(0 failed, passed ≥ 기준선, 성능 `--max-ratio=1.3`) |
| K2-14 | 상수를 일부러 틀리게 | `KanaCourse.STAGE_PASS` 를 임시로 8 로 바꾸면 K2-5 가 FAIL(11 맞힘이 통과해 버림)하는 줄을 붙이고 원복(이 상수는 K1 소유라 **시험 실행 중 임시로만** 바꾸고 커밋하지 않는다) |
- 금지: `kana_data.gd`·`kana_hangul.gd`·`study_log.gd`·`practice_view.gd` 수정, 새 색·이모지, 새 네트워크 호출, `KanaScreen` 의 공개 이름(`available`, `sound_available`, `no_sound_text`, `open`, `go_back`, `closed`, `tap_cell`, `start_quiz`, `answer`, `add_wrong_to_review`, `retry_wrong`, `current`, `rate_pct`, `Cell`, `Dots` …) 삭제·이름 변경, 소유 밖 파일.

#### Q2 — 스피드 화면 (`worker-hard`, 2파)
- 소유: §6.3 표의 Q2 줄. 하는 일: §4.3 화면 `SpeedScreen`(연습 하위 화면 계약: `signal closed`, `open(l, args)`, `go_back() -> bool`, `on_hide()`, 머리 `SpeakDrill.build_shell`), 시작→진행→결과, 타이머(`_process` + `Time.get_ticks_msec()`), 일시정지, 결과 처리(§5.8).
- 합격 조건:

| ID | 조건 | 명령 → 기대 |
|---|---|---|
| Q2-1 | 시험 통과 | `speed_screen_test` PC·`-- --phone` → `0 failed` |
| Q2-2 | 시작 화면: 카드 12장 미만 + 레슨 단어 0(가짜 단어 목록)이면 시작 버튼이 꺼지고 안내 글. 풀이 충분하면 시작 버튼이 켜짐·최고 기록·단어 수 표시 | 시험 PASS |
| Q2-3 | 한 판 끝까지(가짜 시계 주입: 화면이 `clock: Callable` 훅을 쓴다): 정답 8번 → 점수가 §5.8 식과 같고, 시간 끝 → 결과 화면, `StudyLog.speed_best` 에 기록, `add_event(lang,"drill")` 1, 오늘 공부 표시(5문제 이상일 때), `Store.activity` 신호 `"speed"` 1번 | 시험 PASS |
| Q2-4 | 새 기록: 이전 최고보다 높으면 "새 기록" 표시와 이전 점수, 낮거나 같으면 표시 없음. 4문제만 풀고 끝나면(< 5) 기록하지 않고 "기록은 5문제부터 남아요" | 시험 PASS |
| Q2-5 | 오답 처리: 오답 → 정답 보기에 ✓·고른 보기에 ×(도형 존재), 콤보 0, 0.9초 안 연타는 무시, 결과의 틀린 단어 목록, [복습 카드로 추가] 가 `Store.add_review`(`note` "스피드 퀴즈")로 카드를 넣고 두 번 눌러도 중복 없음. `Store.rate_review` 를 부르지 않는다(복습 카드의 `reps`·`due` 불변) | 시험 PASS |
| Q2-6 | 일시정지: 진행 중 `NOTIFICATION_APPLICATION_PAUSED`(또는 창 포커스 잃음) → 남은 시간이 멈춤, 돌아오면 이어짐. 뒤로 가기 → "그만할까요?" 시트, [계속] 이면 시간 이어짐, [그만두기] 이면 기록 0·허브로 | 시험 PASS |
| Q2-7 | 단어가 일본어면 `rd`(읽기)가 보이고 영어면 안 보임. 보기 4개의 글자 길이가 긴 뜻(12자)도 줄바꿈되어 버튼 밖으로 안 나감(폰 150%) | 시험 PASS |
| Q2-8 | 레이아웃(412x915, 글자 150%, 다크, PC 1280x800): 보기 버튼 높이 ≥ 72(폰), 시간 바·점수·콤보 줄이 한 화면 안, 결과 화면 [다시 도전] 버튼 ≥ 48 | 시험 PASS |
| Q2-9 | 네트워크·AI 없음(C-4)·`--api=http://127.0.0.1:9` 로 통과. 단어 파일을 못 읽는 상태(`SpeedPool.load_words` 가 `ok=false`)에서도 카드만으로 시작 가능하거나(카드 충분) 안내가 나오고 에러가 없다 | 시험 PASS |
| Q2-10 | **일부러 틀린 입력**: 시간이 끝난 뒤 보기 누르기, 결과 화면에서 보기 누르기, `open("fr")`(알 수 없는 언어 → 안전한 화면), 같은 결과를 두 번 `finish()`(기록 1번만) | 시험 PASS |
| Q2-11 | 상수를 일부러 틀리게 | `SpeedLogic.LIMIT_MS` 를 임시로 6_000 으로 바꾸면 Q2-3 이 FAIL 하는 줄을 붙이고 원복(Q1 소유 상수, 실행 중 임시로만) |
- 금지: `practice_view.gd` 수정(허브 연결은 W), `SpeedLogic`/`SpeedPool` 수정, 새 색·이모지, 소리·진동 추가, 소유 밖 파일.

#### W — 연결: 셸·홈·연습 허브 (`worker-hard`, 3파)
- 소유: §6.3 표의 W 줄. 하는 일:
  1. `main.gd`: `add_v16_tabs()`(새): `add_tab("badges", "배지", BadgeView.new(), "배지", "stats")`, `BadgeView.provider = BadgeEngine.ui_list`, `BadgeView` 가 본 것으로 표시하는 콜백 → `BadgeEngine.mark_all_seen`, `add_child(BadgeWatcher.new())`. `_ready()` 에서 `add_v11_tabs()`·`add_sync()` 와 같은 조건(`get_tree().current_scene == self`)일 때만 호출(그래서 `main.tscn` 을 자식으로 불러오는 기존 레이아웃 시험의 탭 목록은 그대로). `MENU_SUB` 에 `"badges": "받은 배지와 진행"` 한 줄.
  2. `today_view.gd`: `_build()` 에서 연속 카드 바로 뒤(PC 오른쪽 열, 폰 본문)에 `FunParts.home_card(lang, WeekReport.for_lang(lang), BadgeEngine.counts(), on_open)` 를 카드 id `"fun"` 으로 추가. `on_open`: `"speed"` → `PracticeView.pending = {"kind":"speed"}` + `Store.navigate.emit("practice", lang)`, `"kana"` → `{"kind":"kana","view":"course"}`, `"badges"` → `Store.navigate.emit("badges", lang)`, `"report"` → `Store.navigate.emit("stats", lang)`.
  3. `practice_view.gd`: `KINDS` 에 `"speed"` 를 `"kana"` 뒤에, `_make_screen` 에 `"speed": return SpeedScreen.new()`, `_hub_items()` 에 `_item("speed", "60초 스피드 퀴즈", "내 복습 카드와 레슨 단어의 뜻을 60초 안에 빠르게 고르고 콤보를 쌓아요.", "퀴즈 시작")`, `"kana"` 카드 글을 "가나 기초 코스" / "단계별로 글자를 익히고, 듣고 고르기·읽기·입력 시험으로 확인해요. 헷갈리는 글자 짝도 집중 연습해요." / "코스 시작" 으로. 허브 카드 순서 = mission, shadow, dictation, phoneme, kana, speed.
  4. 시험: `practice_test.gd`·`ui_practice_widgets_test.gd` 의 "카드 5개" 단언 → 6개(`["mission","shadow","dictation","phoneme","kana","speed"]`)로, `home_view_test.gd` 에 카드 `"fun"` 단언 추가(기존 단언은 유지), `t5_wiring_test.gd` 는 필요하면 한 줄(탭 목록 단언이 있다면 `add_v16_tabs()` 를 부르지 않으므로 불변), 새 `fun_wiring_test.gd`.
- 합격 조건:

| ID | 조건 | 명령 → 기대 |
|---|---|---|
| W-1 | 새 연결 시험 | `fun_wiring_test` PC·`-- --phone` → `0 failed`: `main.add_v16_tabs()` 후 `tab_keys()` 에 `"badges"` 가 `"stats"` 바로 뒤, `bar_keys()` 는 그대로(5개 이하, `"badges"` 없음), 폰 메뉴 "기록" 묶음 `entry_keys()` 에 `"badges"` 포함, PC `side_nav` 의 기록 묶음에 포함 |
| W-2 | 하단 탭은 늘지 않는다: 폰에서 `bar_keys()` == 기존 5개(`today, lesson, review, song, menu`), `BottomTabs` 의 더보기 칸이 안 생김 | 시험 PASS |
| W-3 | 홈 카드: 연속 카드 뒤·폰 바로가기 줄 앞(폰), 연속 카드 아래 같은 열(PC). 일본어 홈에는 [가나 코스] 가 있고 영어에는 없다. 새 카드 때문에 기존 위치 단언(시작 버튼 y ≤ 480, 이어하기 카드 y < 859)이 깨지지 않는다 | `home_view_test` PC·폰 `0 failed`, passed ≥ 기준선 + 새 단언 |
| W-4 | 이동: 홈 [60초 퀴즈] → `main.current == "practice"` 이고 `PracticeView.current_screen()` 이 `SpeedScreen`; [가나 코스] → `KanaScreen` 이 코스 화면; [배지] → `main.current == "badges"`; 카드 본문 → `"stats"`. 뒤로 가기(`handle_back`)는 홈으로(`_origin` 규칙) | 시험 PASS |
| W-5 | 연습 허브: 카드 6개, 순서가 위와 같고, 일본어가 아니면 가나 카드 버튼 꺼짐(기존), 스피드 카드는 두 언어 다 켜짐 | `practice_test`·`ui_practice_widgets_test` PC `0 failed` |
| W-6 | 배지 알림 실제 연결: `main` 을 실행 씬처럼 띄운 시험에서 `Store.note_activity("speed")` 후 0.5초 안에 `BadgeWatcher` 가 평가(가짜 `BadgeEngine.provider` 스냅샷으로 `speed_first` 가 되게 함) → 토스트 1개 | 시험 PASS |
| W-7 | 전체 회귀(PC와 `-- --phone`): `phone_layout_test`(412x915), `menu_view_test`, `t5_wiring_test`, `song_view_test`, `standalone_ui_test`, `ui_regress_test`, `ui_nav_test`, `touch_scroll_test`, `screens_scan_test`, `settings_view_test`, `review_walk_test` | 전부 `0 failed`, passed ≥ 기준선(§6.5 W-5·W-3 의 의도한 변경 외 줄어든 단언 0) |
| W-8 | 성능 | `ui_perf_test -- --baseline=<작업 전 측정 json> --max-ratio=1.3` → `0 failed` |
| W-9 | 안드로이드 권한·autoload 변경 0(C-7). `git diff` 에 `project.godot`·`export_presets.cfg` 없음 | 비어 있음 |
| W-10 | **일부러 틀린 입력**: `PracticeView.pending = {"kind":"zz"}`(모르는 kind) → 기존대로 허브로, `Store.navigate_args.emit("badges", {})` → 화면 열림 에러 0, `BadgeView.provider` 가 빈 Callable 인 채 `badges` 를 열어도 빈 화면(에러 0), `BadgeEngine.counts()` 가 비정상 값을 줘도 홈 카드가 그려짐 | 시험 PASS |
| W-11 | 상수를 일부러 틀리게 | `add_tab` 의 `after_key` 를 `"stats"` → `"roadmap"` 으로 바꾸면 W-1 이 FAIL 하는 줄을 붙이고 원복 |
- 금지: 하단 탭 키 목록(`BAR_PHONE`) 변경, `core\home_model.gd`·`ui\home_parts.gd`·`views\menu_view.gd` 수정(홈 카드는 `FunParts` 가 그림), 기존 시험 단언 삭제·완화(§6.5 에 적힌 5→6 교체와 새 단언 추가만), 소유 밖 파일.
- 허용 변경 표(C-5 의 "§6.5 에 적힌 것만"): `practice_test.gd` 와 `ui_practice_widgets_test.gd` 에서 **"5"를 "6"으로, 카드 목록 리터럴에 `"speed"` 추가**한 줄만 허용(줄 번호는 작업자가 보고서에 적는다). 그 밖에 지워진 단언 0.

#### Z — 문서 (`worker`, 4파, 위험도 낮음)
- 소유: `README.md`, `ROADMAP.md`.
- 하는 일: README "할 수 있는 것" 표에 한 줄씩(가나 기초 코스·스피드 퀴즈·배지/주간 리포트), "화면 안내"에 홈 "이번 주" 카드·연습 허브 카드·메뉴/PC 메뉴의 "배지", 라이선스 표에 "스피드 퀴즈 단어 자료(gloss·레슨 문장 기반, 자동 생성 뜻은 일부 틀릴 수 있음)" 줄, "폰 단독" 문단에 스피드 퀴즈·가나 코스 추가, 동기화 문단에 "배지·스피드 기록·가나 코스는 기기별" 한 줄. ROADMAP 에 v1.6.0 절.
- 합격 조건:

| ID | 조건 | 명령 → 기대 |
|---|---|---|
| Z-1 | 새 기능 이름이 README 에 있다 | `rg -c "가나 기초 코스\|60초 스피드 퀴즈\|배지\|주간 리포트" README.md` ≥ 4 |
| Z-2 | README·ROADMAP 외 수정 0 | `git diff --name-only` ⊆ {README.md, ROADMAP.md} |
| Z-3 | 기존 문장을 지우지 않고(추가·정정만) 깨진 표 없음 | `git diff --stat` 의 삭제 줄이 정정에 필요한 것뿐(작업자가 목록으로 보고) |
| Z-4 | 문서에 "AI 필요" 라고 잘못 쓰지 않음: 새 세 기능 설명에 "AI" 가 나오면 "AI 없이" 문맥뿐 | 검토 확인 |
- 금지: 코드 수정, 약속하지 않은 기능 서술(번들 가나 소리는 K0 가 합쳐지기 전에는 "폰의 일본어 음성이 있을 때 소리가 나요"로만).

#### K0 — 오프라인 가나 소리 묶음 (선택, `worker-hard`, 사용자 결정 Q1 이 "예"일 때만)
- 전제: 사용자가 PC 개발 서버(Kokoro `jf_alpha`)로 만든 **샘플 10개(あ い う え お し つ は へ を)를 들어 보고 승인**한 뒤에만 시작(§10.1 Q1). 승인 전에는 만들지 않는다.
- 소유: §6.3 표의 K0 줄. 하는 일: 합성에는 PC 개발 서버(Kokoro `jf_alpha`)가 필요하므로 `godot\tools\build_kana_audio.gd` 는 **개발 PC 에서 한 번만 돌리는 도구**다(`tools\` 는 앱에 들어가지 않음). 이 작업에서만 localhost 개발 서버 접속을 허용하고, 포트가 비어 있는지 확인한 뒤 자기가 켠 PID 로만 켜고 끈다. 고유 읽기 약 101개를 짧은 ogg 로 합성해 base64 로 `godot\data\kana_audio.json` 에 담는다(`{"v":1,"sr":24000,"clips":{"あ":"<base64>"}}`, 파일 ≤ 1.5MB 목표). `KanaVoice.speak` 는 번들 클립을 먼저 쓰고(`AudioStreamOggVorbis.load_from_buffer`, **추측: 이 함수가 4.6.3 에서 그대로 쓰이는지는 작업자가 확인**) 없으면 `Tts` 로 되돌아간다(`available()` 는 번들이 있으면 항상 참). `.ogg` 파일은 저장소에 추적하지 않는다(`packaging\check_no_media.ps1` 이 오디오 확장자를 금지한다. JSON 안의 base64 는 이 검사의 글자 규칙에는 걸리지 않지만, 검사의 취지는 노래·가사 금지이고 이 소리는 합성한 한 글자 소리라 충돌하지 않는다. 이 사실을 README 에 밝힌다).
- 합격 조건:

| ID | 조건 | 명령 → 기대 |
|---|---|---|
| K0-1 | 시험 통과 | `kana_voice_test` PC·`-- --phone` → `0 failed` |
| K0-2 | 클립 수·연결: 클립 ≥ 100개, `KanaData.entries("both")` 208글자 전부가 클립 있는 읽기로 연결됨 | 시험 PASS |
| K0-3 | 파일 크기 | `(Get-Item godot\data\kana_audio.json).Length` ≤ 1,500,000 |
| K0-4 | 일부러 틀린 입력: 깨진 base64, 빈 클립, 키가 없는 JSON, 파일 없음 → `KanaVoice` 가 에러 없이 `Tts` 경로로 되돌아간다 | 시험 PASS |
| K0-5 | 미디어 점검 | `powershell -File packaging\check_no_media.ps1` → 마지막 줄 `NO_MEDIA_RESULT OK` (`.ogg`·`.wav` 추적 0) |
| K0-6 | README 라이선스 표에 Kokoro(Apache 2.0) 합성 소리 줄 | `rg -n "합성" README.md` 로 확인 |
| K0-7 | 실제 폰 스피커 재생·음질 | **미검증**(사용자 실기) |
- 금지: 계속 켜 두는 서버, `data\pack` 변경, `.ogg`/`.wav` 추적, 소유 밖 파일.

---

### 6.6 검토 강도 (CLAUDE.md 기준: 변경 내용 기준)
| 작업 | 위험도 | 검토 |
|---|---|---|
| D1(영구 기록 형식·동기화 인접), B1(영구 배지·소급·평가 루프) | 높음 | `reviewer` 판정 + 오케스트레이터가 핵심 시험(D1-2·D1-9, B1-6~B1-9)을 직접 다시 실행 |
| K1, K2, Q1, Q2, R1, B2, W | 보통 | `reviewer` 1회(W 는 기존 시험 변경이 있어 diff 를 §6.5 와 대조) |
| Z | 낮음 | 오케스트레이터 확인 |
| K0 | 보통(합성 데이터·릴리스 점검 인접) | `reviewer` + 릴리스 전 `check_no_media.ps1` |
- 합격 불가 사유는 **중요**(합격 조건 X·버그·보안)만. 검토·수정 왕복 최대 3라운드, 그 뒤엔 오케스트레이터가 접근을 다시 정한다.

---

## 7. 위험 요소와 대안

| # | 위험 | 영향 | 대안·완화 |
|---|---|---|---|
| R-1 | **폰에 일본어 음성이 없으면 가나 소리가 안 난다**(§2.2) | 듣고 고르기가 약해짐 | 지금처럼 로마자 힌트·글자만 모드 유지(기본). 단계 시험은 소리가 안 나면 듣기 5문제를 읽기로 바꿈. 대안 = K0 번들 소리(사용자 결정 Q1) |
| R-2 | **한 글자 합성 소리가 어색할 수 있음(추측)**: は·へ 단독을 wa·e 로 읽거나 を 를 wo 로 읽거나, 일본어 음성이 한 글자를 "글자 이름"으로 읽을 수 있음 | 정답 소리와 한글 표기 불일치 | K1 `KanaVoice` 에 "소리 낼 글" 매핑 한 곳(`SAY_AS`: 기본은 글자 그대로, 문제가 되는 글자만 단어형으로 바꿈)을 두되 **실기기에서 사용자가 들어 보고 정한다**. 이번 구현은 글자 그대로 + 이 위험을 문서·README 에 명시 |
| R-3 | **단어 뜻이 틀릴 수 있다**(gloss 가 로컬 AI 생성 자료) | 퀴즈로 틀린 뜻을 배울 수 있음 | `v`(교차 확인) 단어 우선, 시작 화면 한 줄 안내, Q1-3 표본 점검(틀린 뜻 ≤ 3/30), 내 복습 카드는 사용자가 만든 뜻이라 안전. 심하면 `v == true` 만 사용(영어 약 355·일본어 약 530 단어: 판은 충분) |
| R-4 | 레슨 단어 수가 적다(영어 ~718, 일본어 ~918, 초반 달에 편중) | 반복되어 지루함 | 카드와 섞음, 한 판 안 반복 금지, 달 +1까지 열기. 후속(1.6.1): gloss 빈도순으로 단어 추가 |
| R-5 | 배지가 한꺼번에 쏟아지는 토스트 | 거슬림 | 평가당 토스트 1개, 첫 평가는 요약 1줄(B1-6) |
| R-6 | 평가 루프가 느려서 폰이 버벅임 | 프레임 끊김 | 변경이 있을 때만 평가(디바운스 + dirty 조건), 평균 < 20ms 시험(B1-15), 폰 실측은 미검증 → 사용자 실기. 필요하면 평가를 홈이 보일 때와 활동 신호 때로만 줄임 |
| R-7 | 두 기기 배지가 다름(가나·스피드·노래는 기기별) | "폰에선 있는데 PC엔 없다" | README·배지 화면 하단에 "일부 배지는 이 기기의 기록으로 받아요" 한 줄(B2). 1.6.1 에서 합집합 동기화 검토(§5.2) |
| R-8 | 시계를 앞당겨 연속·시간 배지를 쉽게 받음 | 배지 신뢰도 | 보상용 기록일 뿐 서버·순위 없음 → 수용. 이미 시계 되돌림 가드가 보호권에 있다(`freeze.last`). 배지는 되돌리지 않음 |
| R-9 | `n.newcards` 가 `add_review` 의 모든 경로(레슨 오답, 대화 교정, 읽기 단어, 가나 오답, 스피드 오답)를 센다 | "새 단어" 의미가 넓음 | 리포트 문구를 "새 카드"로 통일. 옛 기록은 0 이라 첫 주 안내 한 줄(§5.6) |
| R-10 | `PracticeView`·홈 시험이 카드 수·위치에 기대고 있음 | 연결 때 시험이 깨짐 | W 소유로 모아 의도한 변경만(5→6, `"fun"` 카드 추가), 기준선 대비 줄어든 단언 0(C-5, W-7) |
| R-11 | 폰 키보드(한글 IME) 입력 중 조합 글자 | 입력 채점 오판 | 확인 버튼을 눌렀을 때의 최종 텍스트만 채점, 조합 자모(ㅅ)만 있으면 틀림 처리. 실기기 키보드 동작은 **미검증**(K2-8) |
| R-12 | 새 `n` 키가 `MAX_KEYS`(32)·키 길이 24 제한에 걸림 | 동기화 검사 실패 | `newcards` 는 8자·키 총 8개로 여유(D1-8 이 `SyncDoc.clean_rec`·`check` 통과도 확인: `sync_roundtrip_test` 회귀) |
| R-13 | `StudyLog.reset()`(기록 초기화)이 배지·스피드 기록도 지움 | 사용자 놀람 | 기존 "초기화" 확인 문구가 모든 학습 기록을 지운다고 말하는지 W 가 확인(설정 화면은 소유 밖 → 문구가 부족하면 오케스트레이터에게 보고만, §10.2 O-3) |
| R-14 | 신규 데이터 파일이 PC·폰 빌드에 들어가는지 | 스피드가 PC 에서 빈 풀 | `data/*` 포함 규칙(§2.3)을 시험이 `FileAccess.file_exists("res://data/speed_words.json")` 로 확인(Q1-2). 실제 내보내기 파일 확인은 릴리스 단계(오케스트레이터) |
| R-15 | 하루 날짜 경계(자정) 중 스피드·가나 한 판 | 기록 날짜 | 기록 날짜는 판이 끝난 시각 기준(`StudyLog.today()`), 다른 기능과 같다 |

### 7.1 일부러 틀린 입력으로 확인하는 실패 시나리오 (시험이 직접 한다. 작업 표의 "일부러 틀린 입력" 항목을 한눈에)
| 시나리오 | 기대 | 담당 시험 |
|---|---|---|
| `studylog.json` 의 `speed`/`badges`/`kana_course` 에 문자열·음수·NaN·너무 큰 값·나쁜 id | 에러 없이 정리되거나 버려짐 | D1-4 |
| 깨진 JSON 파일 | 기존대로 `.bad` 로 옮기고 빈 상태(배지·기록 초기화), 앱 계속 | 기존 `study_log_test` + D1 |
| 읽기 전용 기록 파일 | 평가·기록이 조용히 건너뜀, 파일을 덮어쓰지 않음 | B1-14 |
| 가나 입력에 빈 문자열·공백·엉뚱한 로마자·한글 자모·`shi?` | 틀림, 에러 없음 | K1-7, K2-6 |
| 질문 검사기에 보기 중복·정답 번호 틀림 | 검사기가 FAIL 판정 | K1-8 |
| 스피드 점수 시계가 거꾸로·NaN·시간 종료 뒤 입력 | 받지 않음, 점수 불변 | Q1-7, Q1-8, Q2-10 |
| `speed_words.json` 깨짐/없음 | `ok=false`, 앱 계속 | Q1-9, Q2-9 |
| 풀이 12개 미만 | 시작 불가 + 안내 | Q1-4, Q2-2 |
| 리포트 입력이 5일뿐·`null`·음수·NaN | 0/-1 로 정리, 에러 0 | R1-4 |
| 배지 스냅샷이 쓰레기 | 아무것도 안 받음 | B1-4 |
| 배지 화면 데이터가 빈 배열·`null`·0 나눔 | 빈 화면/건너뜀, 에러 0 | B2-8 |
| 알 수 없는 연습 kind·화면 이름 | 허브/무시 | W-10 |
| 상수 하나를 일부러 틀리게(각 작업 C-12) | 그 작업 시험이 FAIL 하는 줄 | 각 작업 |

---

## 8. 확인 방법 요약 (오케스트레이터용)

- 파일 소유 충돌 검사: 각 worktree 에서 `git diff --name-only <기준 커밋>` ⊆ §6.3.
- 핵심 직접 재실행(보고를 믿지 않고): `study_log_fun_test`, `badge_engine_test`, `kana_course_test`, `speed_logic_test`, `week_report_test`, `fun_wiring_test` 를 PC·`-- --phone` 으로 각각, 그리고 `run_sync_tests.ps1`(동기화 회귀), `kana_test`, `practice_test`, `home_view_test`, `phone_layout_test --resolution 412x915 -- --phone`.
- 최종 통합 시험(T7): 위 전부 + `contrast_test`, `a11y_sweep_test`(`--dark` 포함), `ui_perf_test`, `screens_scan_test`, `persist_test`, `test_guard_test`, `smoke`. 모두 `0 failed`, `SCRIPT ERROR:` 0, `TEST_GUARD on` 1.
- 권한·버전: `git diff --stat godot\project.godot godot\export_presets.cfg` 는 릴리스 단계의 버전 올리기 전까지 비어 있다. 릴리스 단계에서 `config/version` 과 export preset 의 1.6.0 만 올린다(권한 줄 불변: `INTERNET, ACCESS_NETWORK_STATE, RECORD_AUDIO`).
- 실기기 확인(**미검증으로 남김, 사용자 몫**): 폰의 일본어 음성으로 가나 소리가 나는지·は/へ/を 읽기, 한글 키보드로 입력 퀴즈, 스피드 퀴즈 터치 반응·시간 정지(앱 전환), 홈 카드 첫 화면 모습.
- 릴리스 전 공개 점검(CLAUDE.md): 올라갈 파일 목록에 새 `.json`(speed_words)·`.gd` 만 있고 비밀값·기록·로그 없음, `check_no_media.ps1` OK.

---

## 9. 새 파일 / 기존 파일 한눈에 (이 문서가 말하는 경로 목록)
- **기존(존재 확인함):** `godot\scripts\core\kana_data.gd`, `core\kana_hangul.gd`, `core\study_log.gd`, `core\song_due.gd`, `core\memo_model.gd`, `core\home_model.gd`, `core\streak_calc.gd`, `core\plan.gd`, `core\fsrs.gd`, `autoload\store.gd`, `autoload\tts.gd`, `autoload\toast.gd`, `local\system_tts.gd`, `local\pack_loader.gd`, `local\local_lessons.gd`, `practice\kana_screen.gd`, `practice\speak_drill.gd`, `views\practice_view.gd`, `views\stats_view.gd`, `views\today_view.gd`, `views\menu_view.gd`, `views\app_view.gd`, `ui\home_parts.gd`, `ui\sheet.gd`, `ui\glyph.gd`, `ui\ui.gd`, `main.gd`, `godot\tests\{kana_test, kana_hangul_test, study_log_test, stats_view_test, song_due_test, practice_test, ui_practice_widgets_test, home_view_test, t5_wiring_test, phone_layout_test, run_sync_tests.ps1}`, `godot\data\pack\{gloss_en, gloss_ja, lesson_bank_en, lesson_bank_ja, manifest}.json`, `godot\export_presets.cfg`, `godot\project.godot`, `packaging\check_no_media.ps1`, `README.md`, `ROADMAP.md`.
- **새(§6.3 소유 표의 "새" 열):** `core\kana_course.gd`, `core\kana_typing.gd`, `core\kana_voice.gd`, `core\speed_pool.gd`, `core\speed_logic.gd`, `core\week_report.gd`, `core\badge_defs.gd`, `core\badge_rules.gd`, `core\badge_engine.gd`, `core\badge_watcher.gd`, `ui\fun_parts.gd`, `views\badge_view.gd`, `practice\kana_course_view.gd`, `practice\kana_type_box.gd`, `practice\speed_screen.gd`, `godot\data\speed_words.json`, `godot\tools\build_speed_words.gd`, 시험 파일들, `godot\tests\sample_studylog_fun.json`, (선택) `godot\tools\build_kana_audio.gd`, `godot\data\kana_audio.json`.

---

## 10. 결정이 필요한 것

> **확정(2026-11-14, 사용자 "추천대로")**: Q1~Q8 모두 추천안. K0(가나 소리 번들)는 1.6.0에서 하지 않음. O-1~O-5는 문서 기본값. Z 작업도 `worker-hard`가 맡는다.

### 10.1 사용자에게 물을 것 (추천안 포함)
| # | 질문 | 추천 |
|---|---|---|
| **Q1** | **가나 소리를 폰 단독에서도 확실히 내고 싶은가?** 지금은 폰의 일본어 음성이 있어야만 난다. 없을 때를 대비해 합성 소리 약 100개(한 글자씩, 약 1MB)를 앱에 넣을 수 있다. 넣기 전에 샘플 10개를 사용자가 들어 보고 정한다 | 1.6.0 은 지금 방식(시스템/PC 음성 + 소리 없는 대체)으로 내고, 샘플을 들어 본 뒤 괜찮으면 K0 를 같은 릴리스 또는 1.6.1 에 넣는다 |
| **Q2** | 이미 쌓인 기록으로 **배지를 한꺼번에(소급) 줘도 되는가?** (알림은 "이미 N개 달성" 한 줄만) | 예 |
| **Q3** | 스피드 퀴즈 뜻이 자동 생성 자료라 **가끔 틀릴 수 있다.** 교차 확인을 통과한 단어(영어 약 355·일본어 약 530)만 쓸까, 전체(약 718·918)를 안내문과 함께 쓸까? | 통과 단어를 먼저, 부족할 때만 나머지 + 시작 화면 안내 한 줄 |
| **Q4** | 배지·스피드 기록·가나 코스 진행을 **PC와 폰이 서로 동기화**하게 할까? 하면 동기화 문서 구조 변경과 시험이 크게 늘어난다 | 1.6.0 은 기기별(연속·레슨·시간 등 동기화되는 기록에서 계산하는 배지는 두 기기에서 자연히 같아짐), 필요하면 1.6.1 |
| **Q5** | 헷갈리는 글자 짝의 **구별 요령 문구**(예: シ 와 ツ)를 작업자가 초안 → 사용자가 읽고 고치는 것으로 해도 되는가? 확신이 없는 짝은 문구 없이 둔다 | 예 |
| **Q6** | 배지 화면을 **새 항목 "배지"**(폰 메뉴 기록 묶음·PC 왼쪽 메뉴 기록 묶음)로 두는 것에 동의하는가? (대안: 기록 화면 안으로 합침 — 하단 탭은 어느 쪽이든 안 늘어남) | 새 항목 |
| **Q7** | 홈의 "이번 주" 카드를 **항상** 보일까, 월요일에만 보일까? | 항상(작게). 방해되면 설정에서 끄는 것은 1.6.1 |
| **Q8** | 버전: 기능이 늘어나는 변경이라 **1.6.0** 으로 하는 것이 맞는가? | 예 |

### 10.2 오케스트레이터가 정할 것
| # | 항목 | 이 문서의 기본 |
|---|---|---|
| O-1 | `PracticeView.pending` 에 `view:"course"` 같은 추가 인자를 `KanaScreen.open(l, args)` 가 읽는 계약을 확정 | §5.3·K2: `args.view` ∈ `table`(기본)/`course` |
| O-2 | `speed_score_500`·`streak_30`·`time_10h` 같은 배지 목표 숫자 | 표의 값. 출시 뒤 조정 가능한 상수 |
| O-3 | 설정의 "기록 초기화" 문구가 새 기록(배지·스피드)도 지운다고 말하는지: `settings_view.gd` 는 이 설계의 소유 밖 → 문구가 부족하면 1.6.1 후보 | 보고만 |
| O-4 | `Store.activity` 신호의 `kind` 값 목록과 누가 보내는지: 이번에는 K2(`kana`)·Q2(`speed`)만 보냄. 레슨·복습·미션·노래 쪽에서 보내게 하려면 해당 화면 파일(이번 소유 밖)을 건드려야 해서, 그 경우는 `Store.changed`(레슨 끝·복습 평가 때 이미 나옴)와 30초 타이머로 충분하다고 판단 | 기본 그대로 |
| O-5 | 합치는 순서와 `.uid` 충돌 처리, `--import` 를 합친 뒤 한 번 더 돌릴지 | 1파→2파→3파 합칠 때마다 `--import` |
| O-6 | K0 진행 여부(Q1 결과) | 사용자 답에 따름 |

---

## 요약 (10줄)
1. 가나 기능은 이미 표·소리·퀴즈·숙련도가 있다 → 새로 만들지 않고 `KanaScreen` 을 단계 코스(24단계)·입력 퀴즈·짝 연습으로 확장한다.
2. 가나 소리는 폰의 일본어 음성이 있을 때만 난다(보장 안 됨) → 현재 대체 동작 유지, 번들 소리(K0)는 사용자가 샘플을 듣고 결정.
3. 스피드 퀴즈는 연습 허브의 새 카드, 재료는 내 복습 카드 + 새 `speed_words.json`(PC 빌드엔 `data\pack` 이 없어서 별도 파일).
4. 배지 23개는 기존 기록에서 계산하는 순수 규칙 + 한 번 받으면 영구 + 첫 평가에서 소급(알림 1줄). 동기화되는 기록 기반 배지는 두 기기에서 수렴.
5. 새 저장 파일 없음: `studylog.json` 에 `speed`·`badges`·`kana_course` 세 키(기기 전용, 옛 앱이 읽어도 보존). 동기화 스키마 변경 없음. 새 `n.newcards` 는 동기화에 자동 합산.
6. 주간 리포트는 기록 화면 맨 위 전체 카드 + 홈 "이번 주" 요약 카드, 계산은 `StudyLog.range_summary(lang,14)`.
7. 하단 탭 5개 그대로. 배지는 새 화면 `badges`(메뉴·PC 메뉴의 기록 묶음), 홈 카드에서 [60초 퀴즈][가나 코스][배지].
8. 작업: 1파 D1·K1·Q1·R1 → 2파 B1·B2·K2·Q2 → 3파 W(공유 파일 전부) → Z 문서. 소유 파일 겹침 없음.
9. 모든 작업에 O/X 합격 조건·일부러 틀린 입력·상수 변이 확인·금지 조건. 권한·autoload·`project.godot` 변경 금지.
10. 사용자 질문: 번들 가나 소리(Q1), 소급 지급(Q2), 뜻 품질 정책(Q3), 동기화 여부(Q4), 구별 요령 문구(Q5), 배지 항목 위치(Q6), 홈 카드 노출(Q7), 버전(Q8).
