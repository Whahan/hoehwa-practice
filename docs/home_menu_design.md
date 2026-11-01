# 보기 편한 새 홈 + 메뉴 설계 (1.5 후보)

- 작성: designer (설계만. 코드·설정 수정 없음) / 대상: Godot 4.6.3 앱 `godot\` (PC 1280x800 창, 안드로이드 412x915)
- 상태: 오케스트레이터 확정 전 초안. 맨 끝 §16 의 결정이 필요하다.
- 표기: **(추측)** = 코드·실행으로 확인하지 못한 가정. 표기 없는 것은 코드를 읽어서(줄 번호 표기) 확인한 사실이다.

## 0. 읽은 것 / 확인하지 못한 것

- 읽은 것(전체 또는 해당 구간): `main.gd`(전체), `views\today_view.gd`(전체), `views\app_view.gd`, `views\lesson_view.gd`(1-180, 320-580), `views\practice_view.gd`(1-140), `views\song_view.gd`(함수 목록·345-440), `views\review_view.gd`·`roadmap_view.gd`(머리), `views\settings_view.gd`(머리), `autoload\store.gd`(전체), `autoload\route.gd`(머리·POLICY), `core\pal.gd`, `ui\ds.gd`, `core\progress.gd`, `core\plan.gd`, `core\streak_calc.gd`, `core\study_log.gd`(머리·650-792), `core\study_clock.gd`, `local\local_lessons.gd`, `ui\ui.gd`(버튼·칩·함수 목록), `ui\bottom_tabs.gd`, `ui\side_nav.gd`, `ui\sheet.gd`, `ui\goal_card.gd`, `ui\glyph.gd`, `ui\list_group.gd`·`page_header.gd`·`app_bar.gd`(함수 목록), `core\platform.gd`, `ui\card_box.gd`, `tools\make_theme.gd`(머리), `project.godot`, `data\curriculum.json`, `data\pack\lesson_bank_*.json`(구조), 시험 17개의 머리·해당 단언, `docs\ui_redesign_design.md`(1-330).
- 실행한 것: Python 으로 WCAG 대비 계산(§5.3 의 수치 전부). 그 밖에 Godot·시험은 **실행하지 않았다**.
- 확인하지 못한 것: 폰 실제 화면 모습(스크린샷 없음, 코드로 추정), 실기기 dp 환산·시스템 다크 모드 감지·TalkBack, 시험의 현재 통과 개수(기준선은 작업자가 작업 전에 잰다, §11 공통 규칙 C-0), `docs\onetouch_install_design.md`(아직 없음. §9.6 의 계약만 우리 쪽에서 정했다).
- 용어: **토큰** = 이름 붙은 색·크기 상수. **셸** = `main.gd` 가 만드는 바깥 틀. **길** = 레슨 진도 화면. **노드** = 길 위의 한 칸(= 한 주).

---

## 1. 목표와 범위

### 1.1 목표
1. 앱을 열면 맨 앞에 **오늘 할 일**과 **이어하기**가 크게 보인다. 한 번 눌러 바로 시작한다.
2. 하단 탭 5개(폰) / 왼쪽 메뉴(PC)로 기능을 정리한다. 모든 기능은 2번 눌러 안에 닿는다.
3. 레슨 탭은 **길**처럼 이어진 진도 화면이다. 지금 어디인지, 다음이 무엇인지 한눈에 보인다.
4. 큰 버튼, 밝은 색, 연속 학습일, 오늘 목표 링, 별 모으기로 매일 오게 한다.
5. 기존 학습 화면(레슨 풀이·복습·받아쓰기·쉐도잉·미션·읽기·노래·대화·연습 안쪽)은 새로 그리지 않는다. 색 토큰과 버튼 높이·모양만 새 스타일을 따른다.
6. 독창적인 디자인이다(§6).
7. 폰과 PC 모두 같은 구조·같은 데이터. 라이트 테마 기준으로 만들고, 다크 테마도 같은 토큰 구조로 함께 만든다.

### 1.2 하지 않을 것
- 설치·AI 엔진·로그인 화면과 로직(다른 설계자: `docs\onetouch_install_design.md`). `settings_view.gd` 의 AI 엔진 부분은 건드리지 않는다. 홈에 **자리 하나**만 두고 계약만 정한다(§9.6).
- 학습 기능 추가·삭제, 채점·녹음·FSRS·동기화 로직 변경. 레슨 풀이 화면(`_render_run`, `_render_done`, `_render_loading`) 변경.
- 마스코트·캐릭터·일러스트·애니메이션 대공사. 소리·햅틱·알림(푸시).
- 연속 일수 계산식(`StreakCalc`) 변경. `progress.json`·`SyncDoc`(동기화 문서) 변경. 길 기록은 이 기기에만 저장한다(§9.1).
- 새 외부 글꼴·아이콘 세트. 글꼴은 지금의 `SystemFont` 그대로. 아이콘은 코드로 그린 도형(`GlyphIcon`)만.
- 즉시 테마 전환(색 구성은 시작할 때 한 번 적용, 기존 규칙 그대로: `main.gd` 14행 주석).
- 태블릿·폴더블 전용 배치.

---

## 2. 지금 구조 (코드 근거)

### 2.1 셸·이동 (`main.gd`)
| 사실 | 근거 |
|---|---|
| 탭 목록 `TABS` = 오늘, 레슨, 원어민 대화, 복습, 읽기, 로드맵, 설정. 폰 짧은 이름 `TAB_SHORT` 는 대화만 | 18-28행 |
| 폰 하단 바는 직접 5칸(4탭 + 더보기 시트) | `PHONE_MAX_DIRECT := 5` 32행, 171-176행 |
| PC 왼쪽 메뉴 순서 `NAV_LEARN`, `NAV_RECORD` | 34-35행, `_rebuild_nav` 309-324행 |
| 화면 6개를 만들고 `views` 에 등록. 설정은 나중에 | 178-204행 |
| `add_v11_tabs()` 가 연습·기록·노래 탭을 더함. 앱이 실행 씬일 때만 | 257-264행, 197-199행 |
| `show_view(name)` 이 유일한 화면 전환 함수 | 387-400행 |
| `Store.navigate(view, lang)` 신호 → `_on_navigate` → 언어 바꾸고 `show_view` | 206행, 410-413행 |
| 안드로이드 뒤로 가기 `handle_back`: 첫 연결 질문 → 시트 → 연결 화면 → 더보기 → 하위 화면 `go_back()` → 오늘 → 2초 안 두 번이면 종료 | 669-695행 |
| 앱 바 뒤로 버튼 `_on_bar_back`: `go_back()` → 오늘 | 367-371행 |
| 앱 바 제목·동작·스크롤 연동 | `_refresh_bar` 339-359행. 오늘만 "설정" 동작 |
| 폰/PC 분기는 `Platform.is_phone()` 한 곳. 데스크톱 시험은 `-- --phone` | `platform.gd` 7-13행 |
| `Route.mode`("auto/phone/pc")는 **처리 위치**이지 화면 모드가 아니다 | `route.gd` 1-12행 |
| 폰 단독 배지: `standalone_ok()` / `standalone_badge()` | 529-538행 |

### 2.2 공용 UI
- 색: `Pal` 의 `static var`(라이트·다크 표 `LIGHT`/`DARK`) 12-31행, `Pal.use()` 71-111행. 원래 16색의 라이트 값은 시험이 못 박는다(`contrast_test.gd` `LEGACY` 10행, 단언 181-196행).
- 크기: `Ds` 반경 `R_BTN 18, R_CARD 24, R_SHEET 28`(6-12행), 간격 `S1..S10`(14-21행), `touch_min()` 폰 48(92-95행). 글자 크기 표 `TYPE_TABLE` 34-38행, 배율 `fs()` 66행.
- 버튼: `UI.button(text, kind, accent, min_h)` 286-298행. 폰은 높이 `max(min_h, Ds.btn_h())`. 모양은 `_btn_style` = 반경 18, 가로 18, 세로 11(419-421행). 종류 primary/soft/outline/flat/danger.
- `SpeakDrill.touch_button(text, kind, accent, min_h)` 는 `UI.button` 에 최소 높이 44를 더한 얇은 껍데기(`speak_drill.gd` 219-220행). 연습 화면 안에서만 쓴다.
- `CardBox`(카드 + 안쪽 VBox `body`) `card_box.gd`. `UI.card("Card"|"BigCard", sep)`.
- 칩 `UI.chip_kind`(ok/bad/warn/info/lang_en/lang_ja), 눌리는 칩 `UI.filter_chip`, 진행 바 `UI.progress_bar`.
- 글자 배율은 시작할 때 `UiBoot.apply`(설정 `font_scale` ∈ 0.9/1.0/1.15/1.3/1.5, `scheme` ∈ system/light/dark). `main.gd` 113-120행.
- 큰 제목·앱 바: `PageHeader.build`, `AppBar`, 스크롤하면 제목이 앱 바로 올라감(`bind_scroll`). 오버레이 `Sheet.open/confirm/choice`(폰 아래 시트, PC 가운데 440px).
- 터치: `PhoneLayout.install_touch_scroll` 가 ScrollContainer 안의 버튼을 PASS 로 바꿔 세로 드래그가 스크롤이 되게 한다(`main.gd` 126행, `phone_layout.gd` 161행). 새 부품은 `BaseButton` 이나 `UI.on_tap` 만 쓴다.

### 2.3 화면별
| 화면 | 클래스·키 | 지금 모습 | 근거 |
|---|---|---|---|
| 오늘 | `TodayView` "today" | 큰 제목, 진행 카드(몇 일째), **언어 카드 2장**(영어·일본어 각각: 레슨 버튼, 대화·복습 버튼, 주간 체크, 오늘 공부 완료 버튼, 주간 점) | `today_view.gd` 50-75행, 133-219행 |
| 레슨 | `LessonView` "lesson" | 홈 = 언어 스위치, 카드(범위·주차 고르기, 레슨 종류, [레슨 시작]), 복습 카드 | `lesson_view.gd` 476-563행 |
| 복습 | `ReviewView` "review" | FSRS 복습. 한 세션 최대 20개 | `review_view.gd` 6행 |
| 연습 | `PracticeView` "practice" | 허브: 미션·쉐도잉·받아쓰기·약한 소리·가나 | `practice_view.gd` 12행 |
| 노래 | `SongView` "song" | 곡 목록, 곡 추가, 가사 외우기 | `song_view.gd` |
| 대화·읽기·기록·로드맵 | "talk" "reading" "stats" "roadmap" | 각자 허브 | `main.gd` 178-185행, 262-263행 |
| 설정 | `SettingsView` "settings" | 목록 그룹 섹션들 | `settings_view.gd` 22-30행 |

### 2.4 진도·기록 데이터
| 데이터 | 위치·모양 | 근거 |
|---|---|---|
| 시작일, 체크, 날짜별 공부 표시, XP, 통계, 복습 카드, 아는 단어 | `user://progress.json` = `{start, checks, days, xp, stats, review, known_words, updatedAt}`. `Progress.normalize` 는 **모르는 키를 버린다** | `progress.gd` 10-20행, 35-85행 |
| 공부한 날 | `progress.days["2026-11-01"]["en"] = true`. 쓰는 곳: 레슨 끝(`finish_lesson` 346행), 하루 목표 시간 달성(`study_clock.gd` 137행), "오늘 공부 완료" 직접 누름(`Store.toggle_today` 333행) | `store.gd` 320-346행 |
| 주 체크 | `checks["en-3-w1"]` (월 n, 주 인덱스 0부터). 로드맵·오늘 카드에서 사용자가 직접 켠다. 동기화됨 | `store.gd` 272-286행, `today_view.gd` 196-208행 |
| 달력 위치 | `Plan.position(start, today)` = `{phase: before/on/after, n 1-12, w 1-4, day_no}`. 날짜는 일 번호, **현지 날짜**(`Time.get_date_dict_from_system`) | `plan.gd` 62-65행, 90-101행 |
| 학습 기록 | `user://studylog.json` v1: `days[iso][lang] = {sec, by, n{lessons, talks, missions, reviews, shadow, dictation, drill}, lesson[ok,total], score}`, `phon`, `freeze`, `missions`, `kana`. 모르는 최상위 키는 보존해서 다시 쓴다. 이 기기 전용 키는 `kana` 가 선례("동기화되지 않는다") | `study_log.gd` 10-31행 |
| 연속 학습일·보호권 | `StudyLog.settle(lang)` → `{streak, tokens, used, gained}`. 규칙은 `StreakCalc`(7일마다 보호권 +1, 최대 2, 시계 되돌림 가드 `freeze.<lang>.last`). 언어별로 따로 | `study_log.gd` 698-733행, `streak_calc.gd` 4-15행 |
| 하루 목표(분) | `prefs.daily_goal_min`(기본 10, 동기화 공유 설정) | `study_log.gd` 657행, `sync_doc.gd` 11행 |
| 오늘 공부 시간 | `StudyLog.today_seconds(lang)` | 668행 |
| 레슨 커서 | `prefs.lesson_cursor = {"en-3-2": 7}` 칸별 다음 레슨 번호. **폰 은행(LocalLessons) 전용**이고 PC 엔진 레슨에는 없다. 칸 하나에 레슨 약 20개, 12개월 x 4주 = 48칸 | `local_lessons.gd` 8-16행, 77-85행 |
| 어느 칸을 몇 번 풀었나 | **기록 없음.** `finish_lesson` 은 XP·횟수·오늘 표시만 올린다 | `lesson_view.gd` 332-350행 |
| 복습 카드(FSRS) | `progress.review[]`, `Store.due_count(lang)`, `Store.due_for(lang, limit)` | `store.gd` 449행 |
| 노래 외우기 | 곡 폴더 `memo.json`. 곡 목록 읽기는 **스레드**로(`SongView._default_load`), 요약 `SongStore.memo_summary(id, now)` = `{total, memorized, learning, fresh, due, next_due}`. 시험 보호 중에는 `SongStore.blocked()` | `song_view.gd` 348-362행, `song_store.gd` 621행 |
| 마지막 활동(이어하기) | **기록 없음.** `by` 는 보기별 초 합계라 "마지막"을 모른다 | `study_log.gd` 12행 |

### 2.5 화면 구조에 기대는 시험 (전체 80개 중)
`phone_layout_test`, `t5_wiring_test`, `song_view_test`, `settings_view_test`, `review_walk_test`, `touch_scroll_test`, `sync_panel_test`(711-712행), `standalone_ui_test`, `ui_regress_test`, `ui_nav_test`, `a11y_sweep_test`, `screens_scan_test`, `contrast_test`, `ui_perf_test`, `smoke`, `tts_test`. 어떻게 바뀌는지는 §13.

---

## 3. 핵심 결정 요약

| # | 결정 | 이유 |
|---|---|---|
| D1 | 내부 키 `"today"` 와 클래스 이름 `TodayView` 는 **그대로**, 화면 이름만 "홈" | 시험 22개 파일이 키를 쓴다. 이름 바꾸기는 이득 없이 위험만 크다 |
| D2 | 폰 하단 탭 5개: **홈 · 레슨 · 복습 · 노래 · 메뉴**. 더보기 시트 폐지. "메뉴"는 시트가 아니라 **화면**이다(대화·연습·읽기·기록·로드맵·설정) | 사용자 예시(홈·레슨·복습·노래·설정)를 실제 기능 10개에 맞춤. 대화·연습·읽기는 홈 바로가기 줄로 항상 보인다 |
| D3 | PC 왼쪽 메뉴는 같은 순서로 3묶음: 공부(홈·레슨·복습·노래), 말하기·읽기(대화·연습·읽기), 기록(기록·로드맵). 설정은 맨 아래(지금처럼) | 폰과 PC 가 같은 머릿속 지도 |
| D4 | 홈은 **선택한 언어 하나**만 보여 준다. 위쪽에 영어/일본어 스위치. 기존 "언어 카드 2장" 폐지 | 한 번에 한 일. 연속 학습일·보호권이 원래 언어별이다 |
| D5 | 홈 = **오늘 할 일 카드**(링 + 큰 시작 버튼 + 할 일 줄) → **이어하기 카드** → 연속 카드 → (AI 자리) → 바로가기 | 사용자 결정: 맨 앞에 크게 |
| D6 | 레슨 탭 = **길**. 한 노드 = 한 주(12개월 x 4주 = 48칸). 노드 완료 = 그 주 레슨 5번 끝냄(상수) **또는** 그 주 체크를 사용자가 켬 | 기존 체크(동기화됨)와 자연스럽게 겹침. 새 저장은 이 기기 전용 길 기록 하나 |
| D7 | 잠금은 **부드러운 잠금**: 지금 칸 + 앞 2칸까지 열림, 그보다 먼 칸은 확인 시트("미리 해 볼래요?") 뒤에 열림. 완전히 막지 않는다 | 지금 앱은 어느 달·주든 고를 수 있다. 완전 잠금은 기존 사용자를 막는다 |
| D8 | 새 저장 파일 **없음**. `studylog.json` 에 최상위 키 `"path"` 하나를 더한다(`kana` 선례) | 읽기·쓰기·깨짐 격리·시험 보호·초기화가 이미 있다 |
| D9 | 팔레트: 대표색 **청록**(`PRIMARY`), 보상색 **보라**(`REWARD`, 연속·XP·별). 영어 파랑·일본어 빨강·정답 초록은 그대로. 원래 중립색 16개의 라이트 값은 **바꾸지 않는다** | 시험 기대값 변경을 `PRIMARY` 계열 3줄로 한정 |
| D10 | 큰 버튼: 폰에서 `primary` 는 높이 ≥ 56(`Ds.CTA_H`), soft·outline 48. 모양(반경 18)은 그대로 | 반경 상수를 시험이 못 박는다 |
| D11 | "AI 연결" 자리는 `HomeAi.slot()`(읽기) + `Store.ai_connect_requested`(신호) 둘만. 구현은 설치 설계자가 바꿔 끼운다 | §9.6 |
| D12 | 연속 학습일 계산은 **그대로**. 홈은 `StudyLog.settle(lang)` 결과를 보여 줄 뿐 | 계산 시험이 이미 많다 |

---

## 4. 이동 구조·뒤로 가기

### 4.1 화면 키와 소속
| 키 | 이름 | 폰 하단 탭 | PC 왼쪽 메뉴 묶음 |
|---|---|---|---|
| today | 홈 | 1 | 공부 |
| lesson | 레슨 | 2 | 공부 |
| review | 복습 | 3 (할 일이 있으면 점 배지) | 공부 |
| song | 노래 | 4 | 공부 |
| menu | 메뉴 | 5 (**폰 전용 화면**) | (없음) |
| talk | 원어민 대화 | 메뉴 안 / 홈 바로가기 | 말하기·읽기 |
| practice | 연습 | 메뉴 안 / 홈 바로가기 | 말하기·읽기 |
| reading | 읽기 | 메뉴 안 / 홈 바로가기 | 말하기·읽기 |
| stats | 기록 | 메뉴 안 | 기록 |
| roadmap | 로드맵 | 메뉴 안 | 기록 |
| settings | 설정 | 메뉴 안 | 아래 고정 |

### 4.2 `main.gd` 계약
```gdscript
const BAR_PHONE := ["today", "lesson", "review", "song", "menu"]      # 하단 바에 보이는 순서
const TAB_PARENT := {"talk": "menu", "practice": "menu", "reading": "menu",
                     "stats": "menu", "roadmap": "menu", "settings": "menu"}   # 바에서 불 켤 탭
const NAV_GROUPS := [                                                  # PC 왼쪽 메뉴
  {"title": "공부", "keys": ["today", "lesson", "review", "song"]},
  {"title": "말하기·읽기", "keys": ["talk", "practice", "reading"]},
  {"title": "기록", "keys": ["stats", "roadmap"]}]
const TABS := [["today","홈"],["lesson","레슨"],["review","복습"],["talk","원어민 대화"],
               ["reading","읽기"],["roadmap","로드맵"],["settings","설정"]]
var _origin: String = ""            # 바 밖 화면을 연 탭(뒤로 가기가 돌아갈 곳)
func bar_keys() -> Array            # BAR_PHONE 중 지금 등록된 것(순서 유지). 예: 시험처럼 자식 씬이면 노래가 없어 4개
func back_target() -> String        # 뒤로 갈 키. 홈이면 ""
```
- `add_v11_tabs()` 의 `after_key`: 연습 = "talk" 뒤, 노래 = "review" 뒤, 기록 = "reading" 뒤.
- 기대하는 `tab_keys()`:
  - PC 시험처럼 자식 씬: `["today","lesson","review","talk","reading","roadmap","settings"]`
  - PC 실행 씬: `["today","lesson","review","song","talk","practice","reading","stats","roadmap","settings"]` (10개, 지금과 같은 개수)
  - 폰 실행 씬: 위 + `"menu"` 가 `"song"` 바로 뒤. 폰 자식 씬: `["today","lesson","review","menu","talk","reading","roadmap","settings"]`
- 폰의 "menu" 화면은 `TABS` 에 넣지 않고 `_ready()` 에서 `add_tab("menu", "메뉴", MenuView.new(), "메뉴", "review")` 로 등록한다(PC 에는 없음). `_ready()` 와 `add_tab()` 안의 `_bottom_tabs.set_tabs(...)` 호출은 둘 다 `bar_keys()` 에 해당하는 항목만 넘기도록 바꾼다.
- 하단 바에는 `bar_keys()` 만 `BottomTabs.set_tabs` 로 준다. `BottomTabs` 코드는 바꾸지 않는다(`max_direct = 5`, 탭이 5개 이하면 더보기 칸이 안 생김: `bottom_tabs.gd` `_direct_count` 116행). 라벨: 홈·레슨·복습·노래·메뉴. `TAB_SHORT` 의 "talk" 는 메뉴 안 행 이름용으로 유지.
- `_style_tabs`: 폰 바에는 `TAB_PARENT.get(current, current)` 를 `set_current` 로 준다(메뉴 안 화면에 있으면 "메뉴" 탭이 켜짐). PC 메뉴에는 `current` 그대로.
- 복습 탭 배지: `BottomTabs.set_badge("review", Store.due_count(Store.lang()) > 0)` 를 `show_view`, `Store.changed`, `Store.prefs_changed` 때 갱신.
- `OWN_HEADER`, 연결 칩, 배너, 스플래시, 연결 화면, 키보드·안전 영역 처리(626-650행)는 **그대로**.
- `NAV_LEARN`/`NAV_RECORD` 를 `NAV_GROUPS` 로 바꾼다. 어느 그룹에도 없는 키(시험이 더한 "log")는 "기록" 묶음 끝에(지금 규칙 320-322행과 같다).

### 4.3 뒤로 가기(안드로이드 버튼과 앱 바 ← 가 같은 함수를 쓴다)
순서(위가 먼저):
1. 첫 연결 질문 → 2. 열린 `Sheet` → 3. 연결 화면 → 4. 열린 하위 화면 `go_back()`(레슨 풀이, 연습 하위 화면, 노래 하위 화면 등, 기존 그대로) → 5. **`back_target()` 이 가리키는 화면으로 이동** → 6. 홈이면 "한 번 더 누르면 종료돼요" 토스트, 2초 안에 한 번 더 누르면 종료.

`back_target()`:
- 현재가 `today` 이면 `""`.
- 현재가 바 밖 화면(`BAR_PHONE` 에 없음)이면 `_origin` 이 유효하고 지금과 다르면 `_origin`, 아니면 `"menu"`(등록돼 있을 때), 아니면 `"today"`.
- 현재가 바 안 다른 탭이면 `"today"`.

`_origin` 규칙(`show_view` 안): 폰에서 바 안 화면 → 바 밖 화면으로 갈 때 `_origin = 떠나는 화면`. 바 안 화면으로 가면 `_origin = ""`. 바 밖 → 바 밖이면 그대로 둔다.

예: 홈 → [바로가기 대화] → 대화. 뒤로 → 홈. 메뉴 → 읽기. 뒤로 → 메뉴. 메뉴 → 뒤로 → 홈. 홈 → 뒤로 → 토스트.

PC 는 앱 바가 없어 위 5번이 쓰이지 않는다(왼쪽 메뉴로 직접 이동).

### 4.4 화면 사이 이동 계약
```gdscript
# store.gd (Store 신호 버스에 추가)
signal navigate_args(view: String, args: Dictionary)   # 깊은 이동. 기존 navigate(view, lang) 은 그대로
signal ai_connect_requested                            # 홈·메뉴의 [AI 연결하기]
func request_ai_connect() -> void                      # ai_connect_requested.emit()

# app_view.gd (기본은 아무것도 안 함)
func open_target(args: Dictionary) -> bool             # 이 화면이 args 를 받아 처리했으면 true
```
- `main._on_navigate_args(view, args)`: `args.lang` 이 "en"/"ja" 면 언어를 바꾸고, `show_view(view)`, 그 다음 `views[view].open_target(args)`.
- 처음 쓰는 곳: 홈의 [이어하기] → `Store.navigate_args.emit("lesson", {"lang":"en","n":3,"w":2,"start":true})`.
- `LessonView.open_target`: `lang`, `n`, `w` 를 고르고, `start == true` 이고 `lesson_source() == "tatoeba"` 일 때만 바로 `start_lesson()`. AI 레슨은 10~60초가 걸려서 시작 화면에서 사람이 누른다.
- 다른 화면(노래·연습·읽기·대화·복습)은 이번에 `open_target` 을 만들지 않는다. 화면만 연다(`navigate`).

---

## 5. 디자인 토큰

### 5.1 원칙
- 기존 구조 유지: 색은 `core\pal.gd`, 크기·간격은 `ui\ds.gd`, 테마 파일은 `tools\make_theme.gd` 로 다시 만든다(`godot --headless --path godot --script res://tools/make_theme.gd`).
- 글자에는 `*_ON` 과 `INK/MUTED/PRIMARY` 만, 채움·점·테두리에는 `OK/WARN/BAD/EN/JA/REWARD`(`pal.gd` 9-10행 규칙). 새 코드에 `Color("#...")` 직접 쓰기 금지.
- **바꾸는 것**: `PRIMARY`, `PRIMARY_SOFT`(라이트·다크). **더하는 것**: `REWARD`, `REWARD_SOFT`, `REWARD_ON`(라이트·다크). 나머지 `Pal` 값은 바꾸지 않는다.

### 5.2 색 (라이트 / 다크)
| 토큰 | 라이트 | 다크 | 용도 |
|---|---|---|---|
| `PRIMARY` (바뀜) | #0A726D | #4FD1C5 | 대표색: 시작 버튼, 길 노드, 선택된 탭, 링, 스위치 켜짐 |
| `PRIMARY_SOFT` (바뀜) | #E4F5F3 | #10302E | 선택·옅은 면 |
| `REWARD` (새) | #6C47D9 | #B7A1FF | 연속·XP·별·현재 노드 테두리(채움·선) |
| `REWARD_SOFT` (새) | #EEE9FC | #241D4A | 보상 칩·보호된 날 면 |
| `REWARD_ON` (새) | #5333B8 | #B7A1FF | 보상 글자 |
| 그대로 | `BG #F4F5F7`, `SURFACE #FFFFFF`, `SUNK #ECEEF2`, `INK #1A202C`, `MUTED #5A6373`, `LINE #DDE1E8`, `LINE_STRONG #7C8596`, `EN #2C56C9`, `JA #C4412A`, `OK #23855A`, `BAD #B83A3A`, `WARN #9A6A00` 과 각 SOFT·ON | 다크 표(`pal.gd` 22-31행) | |

역할 규칙(색만으로 구분하지 않는다):
- 청록 = "하는 일"(시작, 진도, 선택). 초록(`OK`) = "정답·성공 피드백"에만. 둘이 비슷해 보이므로 정답 표시는 항상 ✓ 도형과 글자를 함께 쓴다(기존 규칙).
- 보라 = "모은 것"(연속, XP, 별, 보호권).
- 영어 파랑·일본어 빨강 = 언어 구분. 언어 안의 큰 버튼은 지금처럼 언어색(`Pal.accent(lang)`), 언어와 무관한 큰 버튼(홈 시작, 길 시작, AI 연결)은 `PRIMARY`.

### 5.3 대비 (Python 으로 계산한 값. WCAG 상대 휘도식)
글자·채움 위 글자 4.5 이상, 선·도형 3.0 이상이어야 한다.

| 쌍 | 라이트 | 다크 | 기준 |
|---|---|---|---|
| `PRIMARY` / `SURFACE` | 5.77 | 8.95 | 4.5 |
| `PRIMARY` / `BG` | 5.29 | 10.05 | 4.5 |
| `PRIMARY` / `PRIMARY_SOFT` | 5.12 | 7.59 | 4.5 |
| `PRIMARY` / `SUNK` | 4.97 | 7.81 | 4.5 |
| `ON_ACCENT` / `PRIMARY` | 5.77 | 10.05 | 4.5 |
| `MUTED` / `PRIMARY_SOFT` | 5.38 | 6.06 | 4.5 |
| `INK` / `PRIMARY_SOFT` | 14.50 | 11.75 | 4.5 |
| `REWARD_ON` / `REWARD_SOFT` | 6.99 | 7.08 | 4.5 |
| `REWARD_ON` / `SURFACE` | 8.29 | 7.60 | 4.5 |
| `REWARD_ON` / `BG` | 7.60 | 8.53 | 4.5 |
| `REWARD_ON` / `SUNK` | 7.14 | 6.63 | 4.5 |
| `MUTED` / `REWARD_SOFT` | 5.10 | 6.67 | 4.5 |
| `ON_ACCENT` / `REWARD` | 5.93 | 8.53 | 4.5 |
| `MUTED` / `SUNK` (잠긴 노드 글자) | 5.21 | (기존 시험이 이미 검사) | 4.5 |
| `REWARD` / `SURFACE` (선·점) | 5.93 | 7.60 | 3.0 |
| `LINE_STRONG` / `PRIMARY_SOFT` | 3.30 | 3.18 | 3.0 |
| `LINE_STRONG` / `REWARD_SOFT` | 3.13 | 3.50 | 3.0 |

다크 `ON_ACCENT` 는 기존 값 #101216(어두운 글자)이다. 위 값 가운데 다크 `PRIMARY_SOFT` #10302E, `REWARD_SOFT` #241D4A 는 **제안값**이다. 위 표의 모든 쌍이 통과하면 값을 조금 바꿔도 된다.

### 5.4 글꼴·크기 (기존 `TYPE_TABLE` 변형 이름 재사용, 새 변형 없음)
| 쓰임 | 변형 | PC / 폰 크기 | 비고 |
|---|---|---|---|
| 홈 인사 한 줄 | `Strong` | 16 / 17 | 한 줄, 길면 2줄 |
| 링 가운데 숫자 | `Big` | 34 | 링 안에서 `Ds.fs` 로 배율 적용, 링 지름 안에 들어가게 폰트 크기 상한 `RING_D * 0.34` |
| 카드 제목 | `H2` | 21 | |
| 할 일 줄 제목 | `Strong` | 16 / 17 | |
| 할 일 줄 부연 | `Small` | 13 / 14 | |
| 시작 버튼 글자 | 굵게 17~18 | | `UI.button` 이 굵은 글꼴을 이미 씀 |
| 노드 숫자 | 굵게 `Ds.fs(18)` | | 150% 에서 27px, 지름 56 안에 들어감 |
| 노드 이름표 | `Small` | 13 / 14 | 2줄까지, 넘으면 말줄임 |
| 월 머리글 | `H3` | 17 / 18 | |
- 글자 크기 최저 12(`Ds.MIN_FONT`). 직접 크기를 줄 때는 반드시 `Ds.fs(n)`.
- 글꼴 파일은 넣지 않는다.

### 5.5 크기·간격 (논리 px, 폰 412 기준 1px ≈ 1dp)
`Ds` 에 **더하는** 상수(기존 상수 값은 그대로, `contrast_test.gd` 244행 단언 유지):
```gdscript
const CTA_H := 56.0              # 폰의 primary 버튼 최소 높이. PC 는 강제하지 않음(기존 L-06 규칙)
const HOME_CTA_H_PHONE := 60.0   # 홈·길의 시작 버튼
const HOME_CTA_H_PC := 52.0
const RING_D_PHONE := 96.0       # 오늘 목표 링 지름
const RING_D_PC := 120.0
const RING_STROKE := 10.0
const NODE_D := 56.0             # 길 노드 지름(터치 영역)
const NODE_D_CUR := 72.0         # 지금 노드
const NODE_STRIDE_PHONE := 112.0 # 노드 중심 사이 세로 거리
const NODE_STRIDE_PC := 120.0
const NODE_AMP_MAX := 72.0       # 좌우 흔들림 최대
const PATH_TRACK_W := 10.0       # 길 선 굵기
const TASK_ROW_H := 56.0         # 할 일 줄 최소 높이(두 줄이면 늘어남)
const STONE_D := 28.0            # 주간 점 지름(표시만, 터치 아님)
const HOME_RIGHT_W := 340.0      # PC 홈 오른쪽 열 폭
const PATH_COL_W_PC := 520.0     # PC 길 폭
```
간격: 카드 사이 폰 12 / PC 16(`ColumnBox` 기본), 카드 안쪽 폰 16 / PC 20, 섹션 사이 24. 반경: 카드 24(`R_CARD`), 버튼 18(`R_BTN`), 칩 알약(`R_PILL`). 노드는 원(반지름 = 지름/2).

### 5.6 버튼 모양
| 종류 | 폰 높이 | PC | 모양 |
|---|---|---|---|
| 시작(primary, 홈·길 등) | 56~60, 가로 가득 | 52 이상 | 채움, 글자 `ON_ACCENT`, 굵게 17~18, 앞에 `GlyphIcon("play")` 선택 |
| 보조(soft) | 48 | 40 | 옅은 면 + 진한 글자 |
| 외곽선(outline) | 48 | 40 | 옅은 면 + 2px 선(오늘 완료 토글 등) |
| 평면(flat) | 48 | 40 | 배경 없음 |
- 한 화면의 채움 버튼은 한 개 이하(기존 규칙 `ui_redesign_design.md` §4.3).
- **누르면 아래로 들어가는 두꺼운 아래 선(입체 버튼)을 쓰지 않는다**(§6).
- 구현: `UI.button` 이 폰에서 `kind == "primary"` 이면 높이를 `max(min_h, Ds.CTA_H)` 로 올린다. 다른 종류는 그대로.

### 5.7 모션
기존 규칙 유지: 100~500ms, `TRANS_QUINT`+`EASE_OUT`. 새 모션은 둘뿐: 링이 채워질 때 호 길이 트윈 400ms(목표를 막 채운 순간 한 번), 길이 열릴 때 지금 노드로 스크롤 이동 0ms(점프, 애니메이션 없음). 폭죽·반짝임 애니메이션 없음.

### 5.8 다크 테마를 고려하는가
예. 새 토큰은 `LIGHT`/`DARK` 표에 같이 넣는다(`Pal.LIGHT.keys() == Pal.DARK.keys()` 시험이 이미 있음: `contrast_test.gd` `_test_fresh_state`). 새 화면은 색을 전부 토큰으로 칠하므로 따로 만들 것이 없다. 시각 확인은 `shots_phone.gd --dark`(창 필요)로 사용자 몫. 합격 조건은 대비 시험(양쪽 스킴)과 `phone_layout_test --dark` 이다.

---

## 6. 독창성 규칙 (베끼지 않는다)

일반 패턴만 쓴다: 오늘의 목표, 진도 길, 하단 탭, 연속 학습일, 별 모으기.

금지(작업자가 새 파일에서 지켜야 하고, T6 이 검사한다):
1. 마스코트·캐릭터·동물 그림. 올빼미, 새, 깃털 모양 도형.
2. 특정 회사 앱의 색 조합. 밝은 연두 + 주황 + 하늘색 조합을 쓰지 않는다. 우리 조합은 청록 + 보라 + 영어 파랑/일본어 빨강.
3. 연속 학습일 상징으로 **불꽃**을 쓰지 않는다. 우리 상징은 네 갈래 반짝임(`GlyphIcon("sparkle")`)과 숫자 알약이다.
4. 누르면 눌리는 두꺼운 아래 선이 있는 입체 버튼.
5. 길을 "산·성·왕관" 같은 특정 앱의 상징 아이템으로 꾸미지 않는다. 우리 길은 단색 원 노드 + 굵은 선.
6. 특정 앱의 화면 배치 복제: 상단 가로 통계 줄(깃발·불꽃·보석·하트), 좌우 흔들리는 노드 위 왕관, 하트(목숨) 시스템. 우리는 목숨이 없다.
7. 문구에 다른 앱 이름·"듀오" 등 상표를 쓰지 않는다.
8. 새 파일에 이모지·도형 문자(★✦🔥♥ 등) 문자열을 쓰지 않는다. 도형은 `GlyphIcon` 으로 그린다.

우리 고유 요소: ① 길(단색 원 노드, 굵은 선, 완료 구간은 청록으로 칠해짐) ② 오늘 목표 링 + 보호된 날은 보라 면 ③ 주간 7개 점(돌) ④ 보라 숫자 알약 ⑤ 따뜻한 한국어 짧은 문구 표(§8.4).

검사(O/X): `rg -n -i "duolingo|듀오|올빼미|\bowl\b|flame|불꽃|#58CC02|#1CB0F6|#FF9600|#FFC800|#CE82FF" godot\scripts godot\tools godot\tests` 결과 0줄(이 문서·시험의 이 검사 줄 자체는 `docs\` 에 있어 대상이 아니다. 시험 코드에는 이 패턴 문자열을 넣지 않는다).

---

## 7. 화면 와이어프레임

표기: `┌┐└┘` = 카드, `[ ]` = 버튼(괄호 안은 높이), `(●)` 완료 노드, `((▶))` 지금 노드, `(○)` 열린 노드, `(자물쇠)` 잠긴 노드, `◯ 7/10` = 링.

### 7.1 홈 — 폰 (412x915, 글자 100%)

```
┌──────────────────────────────────────┐ y=0
│ 홈                    ● 연결됨  [설정]│ 앱 바 56 (+위 안전 영역)
├──────────────────────────────────────┤
│ 오늘 할 일을 시작해요.                │ 인사 한 줄(Strong, 규칙 §8.4)
│ [ 영어 English | 일본어 日本語 ]  48 │ 언어 스위치
│ ┌──────────────────────────────────┐ │
│ │ 오늘 할 일                ◯ 7/10분│ │ 카드 반경 24, 안쪽 16
│ │ 레슨 1, 복습 12, 노래 4줄         │ │  링 96
│ │ ┌──────────────────────────────┐ │ │
│ │ │ ▶  오늘의 레슨 시작           │ │ │ 시작 버튼 60, 가득 폭, PRIMARY
│ │ └──────────────────────────────┘ │ │
│ │ ✓ 오늘의 레슨 완료         ›    │ │ 할 일 줄 56 (끝낸 것은 아래로, 흐리게)
│ │ ○ 복습 12개                ›    │ │
│ │ ○ 노래 외우기 4줄          ›    │ │
│ │ ○ 원어민과 말해 보기 (선택) ›   │ │
│ └──────────────────────────────────┘ │
│ ┌ 이어하기 ────────────────────────┐ │ 마지막 활동이 7일 안일 때만
│ │ 복습 이어하기  · 남은 12개  [시작]│ │ 버튼 48
│ └──────────────────────────────────┘ │
│ ┌ 연속 ✦ 5일   보호권 1 ───────────┐ │ 보라 알약 + 반짝임
│ │ 월 화 수 목 금 토 일               │ │ 돌 7개(28)
│ │ ●  ●  ●  ●  ◎  ○  ○               │ │
│ │ XP 240 · 별 6/48                   │ │
│ │ [ 오늘 공부한 걸로 표시 ] (평면 48) │ │ 지금 있는 직접 표시 기능을 옮김
│ └──────────────────────────────────┘ │
│ ┌ AI 연결 안 됨 ───────────────────┐ │ 연결이 안 될 때만(§9.6)
│ │ 대화와 AI 레슨은 연결 뒤에…[AI 연결하기]│
│ └──────────────────────────────────┘ │
│  [ 대화 ]    [ 연습 ]    [ 읽기 ]     │ 바로가기 3칸(각 높이 ≥ 64)
├──────────────────────────────────────┤
│  홈  │ 레슨 │ 복습● │ 노래 │ 메뉴    │ 하단 탭 56 (+아래 안전 영역)
└──────────────────────────────────────┘ y=915
```
- 앱 바 제목이 항상 "홈"이므로 큰 제목 블록(`PageHeader`)을 쓰지 않는다. `header_block()` 은 폰에서 `null`.
- 첫 화면에서 보이는 것(설계 추정치, §12 T4 가 측정): 시작 버튼 아래 끝 y ≤ 480, 이어하기 카드 윗끝 y < 859(하단 탭 위).
- 이어하기 카드가 없으면(최근 활동 없음 또는 시작 버튼과 같은 곳) 그 칸은 없다.
- 오늘 할 일 줄은 전부 `Button`(왼쪽 정렬 평면 버튼, 안에 글자). 글자는 `"복습 %d개"` 형식을 지킨다(§13 `review_walk_test`).

### 7.2 홈 — PC (1280x800, 왼쪽 메뉴 224 + 본문)

```
┌ 왼쪽 메뉴 224 ┬────────────────────────────────────────────────────────────┐
│ 회화 연습     │ 홈                       [ 영어 English | 일본어 日本語 ]    │ PageHeader 72
│ 공부          │ 2단계 · 1개월차 1주차                                       │
│  홈 (선택)    │ ┌ 오늘 할 일 ─────────────────────┐ ┌ 연속 ✦ 5일  보호권 1 ┐│
│  레슨         │ │ (링 120) 7/10분                    │ │ 월 화 수 목 금 토 일  ││ 왼쪽 열 가변
│  복습         │ │ [ ▶ 오늘의 레슨 시작  (52) ]       │ │ ●  ●  ●  ●  ◎  ○  ○  ││ 오른쪽 열 340
│  노래         │ │ ✓ 오늘의 레슨 완료                 │ │ XP 240 · 별 6/48       ││
│ 말하기·읽기   │ │ ○ 복습 12개   ○ 노래 4줄           │ └────────────────────────┘│
│  원어민 대화  │ │ ○ 원어민과 말해 보기 (선택)        │ ┌ AI 연결 안 됨 ─────────┐│
│  연습         │ └──────────────────────────────────┘ │ [AI 연결하기]  [나중에]  ││
│  읽기         │ ┌ 이어하기 ─────────────────────────┐ └────────────────────────┘│
│ 기록          │ │ 복습 이어하기 · 남은 12개  [시작]  │                            │
│  기록 로드맵  │ └──────────────────────────────────┘                            │
│ [연결 칩]설정 │                                                              │
└───────────────┴────────────────────────────────────────────────────────────┘
```
- 본문 폭 960 이하 가운데 정렬(`PageScroll(960)`). 본문 폭이 980 미만(창을 줄임)이면 한 열로(폰 순서와 같음). 지금도 같은 기준 980(`today_view.gd` 47행).
- 왼쪽 열: 오늘 할 일, 이어하기. 오른쪽 열: 연속, AI 자리. 바로가기 줄은 PC 에 없다(왼쪽 메뉴가 같은 일을 한다).
- 첫 화면: 시작 버튼 아래 끝 y ≤ 420.

### 7.3 레슨(길) — 폰

```
┌──────────────────────────────────────┐
│ 레슨                       ● 연결됨   │ 앱 바 (큰 제목 블록 없음: 위 카드가 첫 화면)
├──────────────────────────────────────┤
│ [ 영어 English | 일본어 日本語 ]  48 │
│ ┌ 지금 위치 ───────────────────────┐ │
│ │ 3개월차 · 2주   ●●●○○ 3/5         │ │ 노드 완료 점 5개
│ │ 이번 주: (주제 한 줄)              │ │
│ │ 레슨 종류 [ 실제 예문 (빠름) | AI (느림) ] │ ← 기존 분할 버튼 그대로
│ │ [ ▶ 레슨 시작 (60) ]               │ │
│ └──────────────────────────────────┘ │
│ 3개월차 · (제목)          ★ 2/4주     │ 월 머리글
│            (●) 1주 · 주제             │
│     (●) 2주 · 주제                    │ 좌우로 흔들리는 길
│            ((▶)) 3주 · 주제  [지금]   │ 72, 보라 테두리
│                  (○) 4주 · 주제       │ 열림
│ 4개월차 · (제목)                      │
│            (자물쇠) 1주 · 주제        │ 잠김
│ ...                                  │
├──────────────────────────────────────┤
│  홈  │ 레슨 │ 복습 │ 노래 │ 메뉴      │
└──────────────────────────────────────┘
```
- 길 선: 노드 중심을 잇는 굵은 선(10px). 완료 → 완료/지금 구간은 `PRIMARY`, 나머지는 `LINE`.
- 노드 모양(색만으로 구분하지 않는다):
  | 상태 | 모양 | 안 | 이름표 |
  |---|---|---|---|
  | done | 지름 56, `PRIMARY` 채움 | 체크 `ON_ACCENT` | "2주 · 주제" |
  | current | 지름 72, `PRIMARY` 채움 + 4px `REWARD` 테두리 | 재생 `ON_ACCENT` | "지금" 칩(보라) + 이름 |
  | open | 지름 56, `SURFACE` + 3px `PRIMARY` 테두리 | 주차 숫자 `PRIMARY` | 이름 |
  | past(건너뜀) | 지름 56, `SUNK` + 2px `LINE_STRONG` | 주차 숫자 `MUTED` | 이름(흐림) |
  | locked | 지름 56, `SUNK` + 2px `LINE_STRONG` | 자물쇠 `MUTED` | 이름(흐림) + "잠김" 접근성 이름 |
- 노드를 누르면 시트(§7.5). 지금 위치 카드의 [레슨 시작]은 지금 노드를 바로 시작한다.
- 길이 열리면 지금 노드가 화면 위에서 35% 근처에 오도록 스크롤한다(`scroll_vertical` 지정, 애니메이션 없음).

### 7.4 레슨(길) — PC

```
┌ 왼쪽 메뉴 ┬───────────────────────────────────────────────────────────┐
│           │ 레슨                         [ 영어 English | 일본어 日本語 ] │ PageHeader 72
│           │ ┌ 지금 위치 (폭 520, 가운데) ───────────────────────────┐ │
│           │ │ 3개월차 · 2주  ●●●○○ 3/5      이번 주: (주제)          │ │
│           │ │ 레슨 종류 [ 실제 예문 레슨 (빠름) | AI 레슨 (느림) ]    │ │
│           │ │ [ ▶ 레슨 시작 (52) ]                                    │ │
│           │ └────────────────────────────────────────────────────────┘ │
│           │ 3개월차 · (제목)                      ★ 2/4주               │
│           │                  (●) 1주                                   │ 길 폭 520, 흔들림 최대 120
│           │            (●) 2주                                         │
│           │                  ((▶)) 3주  [지금]                         │
│           │                          (○) 4주                           │
└───────────┴───────────────────────────────────────────────────────────┘
```
- PC 는 이름표를 노드 오른쪽 옆에 놓는다(가로 공간이 넉넉). 폰은 노드 아래.

### 7.5 노드 시트 (폰 아래 시트 / PC 가운데 440)
```
┌ 3개월차 · 2주 ───────────────────────┐
│ 주제: (주 주제 한 줄)                  │
│ 레슨 3/5  ●●●○○                        │
│ [ ✓ 이번 주 활동 끝냄 ]  (기존 체크 줄)│ ← Store.set_checked(check_key(l,n,"w",w-1))
│ [ ▶ 레슨 시작 (56) ]                   │
│ [ 닫기 ]                               │
└──────────────────────────────────────┘
```
- 잠긴 노드: 본문 "앞 단계를 먼저 하면 길이 순서대로 열려요. 그래도 미리 해 볼까요?" 버튼 [미리 해 보기] [닫기]. [닫기]나 시트 밖/뒤로 가기는 아무것도 시작하지 않는다.
- 시작하면 `LessonView` 가 `sel_n, sel_w` 를 그 노드로 놓고 `start_lesson()` 한다.

### 7.6 메뉴 — 폰 전용 화면
```
┌──────────────────────────────────────┐
│ 메뉴                       ● 연결됨   │ 앱 바
├──────────────────────────────────────┤
│ ┌ 내 기록 ─────────────────────────┐ │ 누르면 기록 화면
│ │ 연속 ✦ 5일 · XP 240 · 별 6/48   ›│ │
│ └──────────────────────────────────┘ │
│ 말하기·읽기                           │
│ ┌──────────────────────────────────┐ │ ListGroup(행 56, 부연 있으면 72)
│ │ 원어민 대화                      ›│ │
│ │ 연습   미션·쉐도잉·받아쓰기…     ›│ │
│ │ 읽기                             ›│ │
│ └──────────────────────────────────┘ │
│ 기록                                  │
│ │ 기록                             ›│ │
│ │ 로드맵                           ›│ │
│ 앱                                    │
│ │ AI 연결           연결 안 됨     ›│ │ HomeAi.slot() 상태 글자
│ │ 설정                             ›│ │
└──────────────────────────────────────┘
```
- 행은 등록된 화면만 보인다(시험처럼 자식 씬이면 연습·기록이 없을 수 있다).
- "AI 연결" 행은 `HomeAi.slot().show` 가 참일 때만. 누르면 `Store.request_ai_connect()`.

### 7.7 AI 연결 자리 (홈 카드 한 장)
```
┌──────────────────────────────────────┐
│ ●(주황 점) AI 연결 안 됨              │ 제목 24자 이하
│ 대화와 AI 레슨은 연결 뒤에 쓸 수 있어요│ 본문 60자 이하(없을 수 있음)
│ [ AI 연결하기 (48) ]   [ 나중에 (48) ]│ 나중에 = 오늘 하루 숨김
└──────────────────────────────────────┘
```
`prominent == true` 이면 홈 맨 위(오늘 할 일 위)에 놓고 [나중에]를 보이지 않는다(설치 첫 실행용).

---

## 8. 규칙

### 8.1 홈 카드 우선순위 (무엇을 언제 보여 주나)
위에서 아래 순서. 조건이 안 맞으면 카드가 없다.

| 순서 | 카드 | 보이는 조건 |
|---|---|---|
| 0 | AI 자리 | `HomeAi.slot().show` 가 참이고 `prominent` 가 참일 때만 맨 위 |
| 1 | 오늘 할 일 | 항상 |
| 2 | 이어하기 | `HomeModel.resume()` 가 비어 있지 않을 때(§8.2) |
| 3 | 연속 | 항상 |
| 4 | AI 자리 | `show` 참, `prominent` 거짓, 오늘 숨기지 않았을 때 |
| 5 | 바로가기(대화·연습·읽기) | 폰만 |

**할 일 줄과 시작 버튼 규칙**(`HomeModel.tasks()`, `HomeModel.hero()`; 입력은 §9.4 스냅샷):
1. 줄은 최대 4개. 기본 순서: 레슨, 복습, 노래, 말하기(선택).
2. 레슨 줄: 항상 있음. 오늘 레슨을 1번 이상 끝냈으면 `done`("오늘의 레슨 완료"), 아니면 `todo`("오늘의 레슨").
3. 복습 줄: 복습할 카드 수 `due > 0` 이면 `todo`("복습 N개"). `due == 0` 이고 오늘 복습을 1번 이상 했으면 `done`("복습 끝!"). 둘 다 아니면 줄이 **없다**(글자 "복습 …" 이 어디에도 없다).
4. 노래 줄: 외울 줄 수 `song_due > 0` 일 때만 `todo`("노래 외우기 N줄"). 없으면 줄이 없다.
5. 말하기 줄: 항상, 상태 `optional`("원어민과 말해 보기", 부연 "선택 · 5분이면 충분해요"). 완료 계산에 넣지 않는다.
6. 복습이 밀렸으면(`due >= 20`, 상수 `REVIEW_FIRST_DUE`) 그리고 레슨이 `todo` 이면 복습 줄이 레슨 줄 앞에 온다.
7. 끝낸 줄(`done`)은 `todo` 줄 뒤로 간다(순서는 유지). `optional` 은 맨 끝.
8. 시작 버튼 = 첫 `todo` 줄의 행동:
   - 레슨 → 글자 "오늘의 레슨 시작". 단, 7일 안 마지막 활동이 레슨이면 "레슨 이어하기"(이 경우 이어하기 카드는 숨긴다).
   - 복습 → "복습 N개 시작"(대상 화면 `review`).
   - 노래 → "노래 외우기 시작"(`song`).
   - `todo` 가 하나도 없으면 "더 연습하기"(`practice`), `all_done = true`.
   - 길을 48칸 다 끝냈으면 레슨 줄 부연이 "1년 과정을 마쳤어요 · 복습 삼아 해 봐요" 로 바뀐다(줄은 그대로).
9. 링은 **하루 목표 시간**(`StudyLog.goal_minutes()`, 분)을 보여 준다: 가운데 "7/10분", 목표가 꺼져 있으면(0) 링 대신 "오늘 7분"만. 목표를 채우면 링이 `OK` 색으로 바뀌고 가운데에 체크 도형.
   할 일 줄 개수 완료율이 아니라 시간을 쓰는 이유: 줄은 하루 중 늘고 줄어서(복습이 새로 쌓임) 비율이 흔들린다.

### 8.2 이어하기 규칙
- 기록: `StudyClock.tick` 이 5초 단위로 공부 시간을 더할 때 현재 화면이 `lesson/review/talk/practice/reading/song` 이면 `StudyLog.note_resume(view, lang)` 를 한 번 부른다(§9.1). 시계 한 칸 = 실제 입력이 있었던 순간이다.
- 보이는 조건: `resume.view` 가 위 6개 중 하나, `resume.at` 가 지금부터 7일(604800초) 이내이고 미래 1일 초과가 아닐 것, 그리고 `resume.view` 와 시작 버튼의 대상 화면이 **다를** 것(같으면 시작 버튼이 "이어하기" 글자를 대신 가진다).
- 글자(`HomeModel.resume()` 출력): 레슨 "레슨 이어하기 · 3개월차 2주 · 3/5", 복습 "복습 이어하기 · 남은 12개"(남은 것이 0이면 카드 없음), 노래 "노래 이어하기", 연습 "연습 이어하기", 읽기 "읽기 이어하기", 대화 "대화 이어하기".
- 버튼 대상: 레슨은 `navigate_args("lesson", {lang,n,w,start:true})`, 나머지는 `navigate(view, lang)`.
- 기록이 아예 없는 새 사용자는 이어하기 카드가 없고, 시작 버튼이 "오늘의 레슨 시작"(길의 지금 노드)이다.

### 8.3 진도 길 규칙
- **칸(노드)**: 언어별 48칸. 칸 번호 `i = (n-1)*4 + (w-1)`, `n` 1~12(개월차), `w` 1~4(주). 키 문자열 `"3-2"`. (커리큘럼과 레슨 은행이 둘 다 12 x 4 구조: `curriculum.json` 월 12개·주 4개, `lesson_bank_*.json` 칸 48개 x 20.)
- **완료(done)**: `StudyLog.path_done(lang, n, w) >= PathModel.NODE_GOAL`(상수 5) **또는** `Store.is_checked(Store.check_key(lang, n, "w", w-1))`.
  - 레슨은 `finish_lesson` 에서 그 칸에 1회로 센다. 점수와 무관(끝까지 풀면 1회). 한 칸의 점은 5개까지만 그린다.
  - 사용자가 주 체크를 직접 켜도 완료다(동기화되는 기존 값이라 다른 기기 진도와 이어진다).
- **지금(current)** = `PathModel.states()` 의 `current`:
  1. `StudyLog.path_last(lang)` 가 있으면: 그 칸이 아직 완료가 아니면 그 칸. 완료면 그 뒤 첫 미완료 칸. 뒤에 없으면 처음부터 첫 미완료 칸.
  2. 기록이 없으면(새 사용자·기존 사용자의 첫 실행): 달력 위치(`Store.position()` → `i`) 이상의 첫 미완료 칸. 시작일 전(`phase == "before"`)이면 0번 칸. 끝난 뒤(`after`)면 47번 칸에서 시작해 첫 미완료.
  3. 48칸이 다 완료면 `finished = true`, `current = 47`.
- **상태**: 완료 칸은 `done`. `current` 는 `current`. 그 앞 미완료는 `past`(건너뜀, 진행률에 안 센다). 그 뒤 `LOOKAHEAD`(상수 2) 칸까지 미완료는 `open`. 더 먼 미완료는 `locked`.
- **잠금은 부드럽다**: `locked` 노드를 누르면 확인 시트 뒤에 연다. `past` 와 `open` 은 바로 시트(§7.5)가 열린다.
- **월 머리글**: "n개월차 · 제목", 오른쪽 "완료 k/4주". 4칸 모두 완료면 별 도형(`GlyphIcon("star")`)을 `REWARD` 로 채운다. 아니면 속이 빈 별 선.
- **별 합계**: 언어별 완료 칸 수 "별 6/48"(홈 연속 카드·메뉴 내 기록 줄).
- 길은 **이 기기에서** 센 레슨 횟수 + **동기화되는** 주 체크로 계산한다. 두 기기의 레슨 횟수는 합쳐지지 않는다(알려진 한계, §14 R7).

### 8.4 격려 문구 한 줄 (홈 인사, `HomeModel.message()`)
임의 선택 없이 위에서부터 첫 일치:
| 순서 | 조건 | 글자 | 종류 |
|---|---|---|---|
| 1 | 시작일 전(`phase == "before"`) | "시작까지 D-%d · 지금 맛보기 레슨을 해 볼 수 있어요" | info |
| 2 | 처음(`first_run`: 기록 없음 & XP 0) | "처음이에요! 레슨 하나부터 가볍게 시작해요." | info |
| 3 | 목표 시간을 채움 | 연속 ≥ 2: "오늘 목표 달성! 연속 %d일째예요." / 아니면 "오늘 목표 달성! 잘했어요." | ok |
| 4 | 연속 > 0, 오늘 아직 안 함, 현지 시각 18시 이후 | "오늘 아직이에요. 지금 하면 연속 %d일!" (%d = 연속+1) | warn |
| 5 | 연속 == 0 이고 기록은 있음 | "다시 시작해요. 오늘 한 번이면 연속 1일이에요." | info |
| 6 | 남은 `todo` 가 N > 0 | "오늘 할 일 %d개 남았어요." | info |
| 7 | 그 밖 | "오늘 할 일을 다 했어요." | ok |
`warn` 글자는 `WARN_ON`, `ok` 는 `OK_ON`, `info` 는 `INK`. 종류는 글자 앞 도형(느낌표·체크)으로도 구분한다(`GlyphIcon`).

### 8.5 연속 학습일 규칙 (계산은 지금 그대로, 여기서는 규칙을 못 박는다)
1. **공부한 날** = `progress.days[날짜][언어] == true`. 켜지는 때: 레슨 끝, 하루 목표 시간 달성, 사람이 직접 "오늘 공부 완료"(`Store.toggle_today`, 지금은 오늘 화면의 언어 카드에만 있다: `today_view.gd` 212-216행. 기능을 없애지 않고 홈 연속 카드의 평면 버튼 "오늘 공부한 걸로 표시"/"표시 취소"로 옮긴다. 다른 곳에는 이 기능이 없다).
2. **언어별로 따로**. 홈은 지금 선택한 언어의 숫자를 보여 준다.
3. **날짜 경계 = 기기의 현지 날짜 00:00.** UTC 변환 없음. `Plan.today_days()` 는 `Time.get_date_dict_from_system()` 을 쓴다(`plan.gd` 62-65행). 23:58 에 한 공부는 그날, 00:01 에 한 공부는 다음 날이다. `StudyClock.tick` 은 5초마다 그 순간의 날짜에 더한다(`study_log.gd` `add_seconds`).
4. 오늘 아직 안 했어도 어제까지 이어져 있으면 연속은 유지된다(오늘 안 한 것은 "빠진 날"이 아니다).
5. 빠진 날이 있으면 보호권 개수만큼 이어 준다. 7일 연속마다 보호권 +1(최대 2). 보호된 날은 연속 일수에 더하지 않고 잇기만 한다. 부족하면 연속이 끊긴다(`streak_calc.gd`).
6. **시계 되돌림 가드**: 오늘이 `freeze.<언어>.last` 보다 이르면 아무것도 바꾸지 않고 표시용 계산만 한다(`study_log.gd` 709-710행).
7. **시간대 이동**: 현지 날짜가 바뀌므로 같은 날이 두 번 오거나 하루가 건너뛸 수 있다. 건너뛴 날은 보호권이 대신 이어 준다. 두 번 온 날은 같은 날로 센다. 알려진 한계이고 고치지 않는다.
8. **자정에 홈이 열려 있을 때**: 홈은 30초마다 `StudyLog.today()` 를 보고 날짜가 바뀌면 다시 그린다. 앱이 백그라운드에서 돌아올 때(`NOTIFICATION_APPLICATION_RESUMED`)도 다시 그린다.
9. 홈은 `StudyLog.today()`(시험이 `today_override` 로 바꿀 수 있음)를 쓴다. 주간 점의 요일 계산은 `Plan.monday_of`(월요일 시작, 지금과 같음).
10. 보여 주는 것: 연속 N일(보라 알약), 보호권 개수, 이번 주 7개 점. 점 모양: 한 날 = 채운 원 + 체크, 오늘 아직 = 보라 테두리 원("오늘"), 지난 못 한 날 = 속 빈 원, 보호된 날 = `REWARD_SOFT` 면 + `REWARD` 테두리, 앞으로 올 날 = 작은 회색 점. 점 아래 요일 글자(오늘만 굵게).

---

## 9. 데이터·API 계약

### 9.1 `studylog.json` 최상위 키 `"path"` (새, 이 기기 전용, v 는 1 그대로)
```json
"path": {
  "cells": {"en": {"3-2": {"done": 3, "ok": 22, "total": 30, "last": "2026-11-01"}}, "ja": {}},
  "last":  {"en": "3-2", "ja": ""},
  "resume": {"view": "lesson", "lang": "en", "at": 1793500000}
}
```
- 키가 없어도 된다(처음 쓸 때 생긴다. `kana` 와 같은 방식). 키가 없는 파일을 읽어도 `snapshot()` 이 달라지지 않는다.
- 정리 규칙(`_normalize`): `"path"` 가 사전이 아니면 빈 것으로. `cells.<lang>` 의 키는 `^([1-9]|1[0-2])-[1-4]$` 만, 값의 `done` 0..9999, `ok`·`total` 0..1000000(정수 아닌 값은 0), `last` 는 진짜 날짜(`_iso_days` >= 0) 아니면 `""`. `last.<lang>` 은 위 키 모양이거나 `""`. `resume.view` ∈ `["lesson","review","talk","practice","reading","song"]`, `lang` ∈ en/ja, `at` 정수 >= 0 — 하나라도 틀리면 `resume` 은 빈 사전. 모르는 하위 키는 버린다.
- `KNOWN_KEYS`(28행)에 `"path"` 를 더한다. `reset()`(98행)이 `path` 도 지운다(전체 초기화에 따라간다).
- 동기화: `SyncDoc` 은 `days / phon / missions` 만 보낸다. `path` 는 보내지 않는다(`apply_sync` 는 다른 키를 건드리지 않는다: `study_log.gd` 129-132행 주석).
- 마이그레이션: **없다**. 예전 사용자는 길 기록이 비어 있다 → §8.3 의 2번 규칙(달력 위치에서 시작)과 주 체크로 첫 화면이 자연스럽다. 이전 버전 앱이 이 파일을 다시 쓰면 `path` 키는 "모르는 키 보존" 규칙으로 살아남는다(`v` 가 같으니 보존 대상: `study_log.gd` 7-8행).

`StudyLog` 에 더하는 함수(정적, 메모리만 바꾸고 저장은 기존 `flush()`):
```gdscript
static func add_path_lesson(lang: String, n: int, w: int, ok: int, total: int) -> bool
    # 잘못된 lang/n(1-12)/w(1-4)면 false. done+1(상한 9999), ok/total 누적, last 날짜=오늘, last[lang]="n-w", dirty
static func path_done(lang: String, n: int, w: int) -> int          # 기록 없으면 0
static func path_last(lang: String) -> Array                         # [n, w] 또는 []
static func path_cells(lang: String) -> Dictionary                   # 복사본 {"3-2": {done, ok, total, last}}
static func frozen_days(lang: String) -> Dictionary                  # {일 번호: true}  (freeze.<lang>.frozen)
static func note_resume(view: String, lang: String) -> bool          # 잘못된 값 false. 같은 view+lang 이고 60초 안이면 바꾸지 않음(dirty 아님)
static func resume() -> Dictionary                                   # {"view","lang","at"} 또는 {}
```
`StudyClock.tick`(study_clock.gd 95-115행)에서 `StudyLog.add_seconds(...)` 바로 뒤에 한 줄: 현재 화면이 위 6개이면 `StudyLog.note_resume(view, lang)`.

### 9.2 `PathModel` (새 `core\path_model.gd`, 순수 계산, 파일·UI 없음)
```gdscript
class_name PathModel
const MONTHS := 12
const WEEKS := 4
const CELLS := 48
const NODE_GOAL := 5
const LOOKAHEAD := 2
static func index_of(n: int, w: int) -> int        # (n-1)*4+(w-1); 범위 밖이면 -1
static func cell_of(i: int) -> Array               # [n, w]; 범위 밖이면 []
static func key_of(n: int, w: int) -> String       # "3-2"
static func states(done: Array, cal_idx: int, last_idx: int, lookahead: int = LOOKAHEAD) -> Dictionary
    # done: bool 배열(길이가 48이 아니면 모자란 곳은 false, 남는 곳은 무시). cal_idx 는 [0,47] 로 자름. last_idx 가 -1 이거나 범위 밖이면 "기록 없음".
    # 돌려주는 값: {"states": Array[String](48, "done|current|open|past|locked"), "current": int, "finished": bool, "done_count": int}
static func done_flags(lang: String) -> Array      # StudyLog.path_done / Store.is_checked 로 48칸 계산(Store·StudyLog 읽기만)
static func current_cell(lang: String) -> Dictionary   # {"n","w","i","done":int,"goal":int,"finished":bool}
```

### 9.3 `HomeModel` (새 `core\home_model.gd`, 순수 계산)
입력 스냅샷 `s`(모든 키가 없어도 에러 없이 기본값으로):
```
{"lang": "en", "phase": "before|on|after", "before_days": int,
 "lesson_today": int, "due": int, "reviews_today": int, "song_due": int, "song_count": int,
 "path": {"n": int, "w": int, "done": int, "goal": int, "finished": bool},
 "goal_min": int, "sec_today": int, "streak": int, "tokens": int, "studied_today": bool,
 "has_data": bool, "first_run": bool, "hour": int, "now": int,
 "resume": {"view": String, "lang": String, "at": int} 또는 {}}
```
함수:
```gdscript
static func tasks(s: Dictionary) -> Array
    # [{"id":"lesson|review|song|talk","title":String,"sub":String,"state":"todo|done|optional",
    #   "target":{"view":String,"args":Dictionary}}]   순서·글자는 §8.1
static func hero(s: Dictionary) -> Dictionary
    # {"text":String,"target":{"view","args"},"all_done":bool,"kind":"lesson|review|song|practice"}
static func resume(s: Dictionary) -> Dictionary
    # {} 이면 카드 없음. 아니면 {"title":String,"sub":String,"button":String,"target":{"view","args"}}  (§8.2)
static func message(s: Dictionary) -> Dictionary
    # {"text":String,"kind":"info|warn|ok"}  (§8.4)
static func snapshot(lang: String) -> Dictionary
    # 실제 값으로 스냅샷을 만든다: StudyLog.range_summary(lang,1)[0], Store.due_count, StudyLog.settle, PathModel.current_cell,
    # Store.position, StudyLog.resume, Time(현지 시각 hour), SongDue 캐시(song_due, song_count)
```
상수: `REVIEW_FIRST_DUE := 20`, `RESUME_DAYS := 7`, `EVENING_HOUR := 18`.
`snapshot()` 에서 `now` 는 `Time.get_unix_time_from_system()`(시간대 무관), `hour` 는 `Time.get_datetime_dict_from_system()["hour"]`(현지).

### 9.4 `SongDue` (새 `core\song_due.gd`)
```gdscript
class_name SongDue
static var cache: Dictionary = {"songs": 0, "lyrics": 0, "due": 0, "fresh": 0, "at": 0}   # at 0 = 아직 안 읽음
static func scan(lister: Callable = Callable()) -> Dictionary
    # 스레드에서 불러도 된다(읽기만, 파일을 옮기거나 쓰지 않음). SongStore.blocked() 이면 0 으로 채운 사전.
    # lister 가 비어 있으면 SongStore.list() 와 memo_summary 를 쓴다(song_view.gd 348-362행과 같은 방식). 시험은 lister 를 넣는다.
static func due_lines() -> int        # cache.due
```
- 홈은 보일 때마다 `Thread` 로 `scan()` 을 돌리고, 끝나면 `cache` 를 채워 노래 줄만 다시 그린다. 홈이 보이는 동안은 60초마다 다시 돈다. 마지막 읽기에서 30초가 안 지났으면 건너뛴다.
- **`song_view.gd` 는 건드리지 않는다**(`SongView` 가 목록을 읽을 때 `cache` 를 갱신하게 하는 방식은 쓰지 않는다. 그러면 노래 화면 소유 파일이 늘어난다).

### 9.5 `TodayView` 공개 구성 (시험이 쓰는 이름)
```gdscript
class_name TodayView extends AppView          # 이름 유지
var _scroll: PageScroll                       # 유지 (scroll_deadzone·touch_scroll_test 가 씀)
var _body: BoxContainer                       # 좁으면 VBox, 넓으면(PC, 본문 폭 >= 980) HBox(왼쪽 VBox, 오른쪽 VBox)
func is_wide() -> bool
func card(id: String) -> Control              # "tasks"|"resume"|"streak"|"ai"|"shortcuts", 없으면 null (카드마다 set_meta("card_id", id))
func hero_button() -> Button                  # "tasks" 카드의 시작 버튼
func task_buttons() -> Array                  # 할 일 줄 Button 들(순서대로)
func lang_switch() -> Control                 # UI.lang_segmented 결과
func refresh() -> void                        # 기존과 같음 (스크롤 유지하며 다시 그림)
func header_block() -> Control                # 폰은 null, PC 는 PageHeader
func page_title() -> String                   # "" (앱 바는 탭 이름 "홈")
func _voice_row(l: String) -> Control         # 유지 (tts_test)
```
- 홈 화면 안에 `GoalRing` 노드가 **정확히 1개**, `SyncPanel`·`open_settings` 글자는 `today_view.gd` 에 없다(`sync_panel_test.gd` 711-712행이 검사).
- 새 부품 파일: `ui\goal_ring.gd`(`class_name GoalRing extends Control`, `draw_arc` 로 링), `ui\home_parts.gd`(`class_name HomeParts`: 정적 `task_row`, `streak_card`, `stones`, `ai_card`, `shortcut_tiles`).

### 9.6 AI 연결 자리 계약 (설치 설계자와 맞출 것)
```gdscript
# core/home_ai.gd
class_name HomeAi
static var provider: Callable = Callable()        # 설치 설계자가 넣는다. () -> Dictionary. 비어 있으면 기본 구현
static func slot() -> Dictionary
    # {"show": bool, "state": "ready|off|llm_off|needs_pairing|not_installed",
    #  "title": String(24자까지), "body": String(60자까지), "action": String(10자까지, ""이면 버튼 없음),
    #  "prominent": bool, "dismissible": bool}
static func sanitize(raw: Variant) -> Dictionary  # provider 결과가 사전이 아니거나 키가 빠졌거나 문자열이 길면 안전한 값으로 (show=false 또는 글자 자르기)
static func dismissed_today() -> bool             # prefs.home_ai_dismiss_day == StudyLog.today()
static func dismiss_today() -> void               # prefs.home_ai_dismiss_day = StudyLog.today() 저장

# store.gd: signal ai_connect_requested ; func request_ai_connect() -> void
```
기본 구현(`Backend.status`, `Backend.llm_missing()`, 폰 단독 판정 사용. 단독 판정은 `main.gd` 529-538행과 같은 식: `Platform.is_phone() and (prefs.standalone_ok or Route.normalize_mode(Route.mode) == "phone")`):
| 상태 | show | state | title | action |
|---|---|---|---|---|
| READY, LLM 있음 | false | ready | | |
| READY, `llm_missing()` | true | llm_off | "AI 답변이 꺼져 있어요" | "AI 연결하기" |
| IDLE/CHECKING/STARTING | false | off | | (스플래시가 덮고 있다) |
| FAILED | true | off | "AI 연결 안 됨" | "AI 연결하기" |
| NEEDS_PAIRING(폰) | true | needs_pairing | "PC 연결이 필요해요" | "AI 연결하기" |
| 폰 단독 모드 | false | off | | |
- 누르면 `Store.request_ai_connect()` 만 부른다. `main.gd` 의 `_on_ai_connect()` 가 이 신호를 받는다. 기본 동작: 폰 → `_open_connect_view()`, PC → `show_view("settings")`. **설치 설계자는 `_on_ai_connect()` 본문과 `HomeAi.provider` 만 바꾼다.** 신호 이름·`slot()` 키는 바꾸지 않는다.
- `docs\onetouch_install_design.md` 가 생기면 오케스트레이터가 이 계약과 대조한다(§16 결정 아님, 확인 사항).

### 9.7 `MenuView` (새 `views\menu_view.gd`, 폰 전용 화면)
```gdscript
class_name MenuView extends AppView
signal entry_chosen(key: String)
func set_entries(groups: Array) -> void
    # [{"title": String, "items": [{"key": String, "title": String, "sub": String}]}]. 이름이 비어 있으면 그 묶음은 안 보임.
func set_summary(text: String) -> void       # "내 기록" 카드 글자 (비면 카드 없음)
func refresh() -> void                       # main 이 show_view 때 부름
func page_title() -> String                  # "" (앱 바는 탭 이름 "메뉴")
```
- `main.gd` 가 `tab_keys()` 에서 바 밖 키를 모아 `set_entries` 를 부른다(묶음 이름: "말하기·읽기" = talk, practice, reading; "기록" = stats, roadmap; "앱" = settings). 등록되지 않은 키는 행을 만들지 않는다. 알 수 없는 키를 누르는 일은 무시.
- "AI 연결" 행은 `HomeAi.slot()` 으로 `main.gd` 가 만들어 "앱" 묶음 맨 위에 넣는다(`key = "__ai"`, 누르면 `Store.request_ai_connect()`).
- 요약 글자는 `HomeModel.snapshot` 으로: "연속 ✦ …" 대신 글자만 "연속 5일 · XP 240 · 별 6/48"(아이콘은 카드 앞 `GlyphIcon("sparkle")`).

### 9.8 `LessonView` 변경 범위 (홈 부분만)
- `_set_default_selection()`(102-106행): 고를 칸을 `PathModel.current_cell(lang)` 의 `n, w` 로(달력 위치 대신).
- `_render_home()`(476-563행)를 §7.3~7.4 로 바꾼다: 언어 스위치(그대로), 지금 위치 카드(레슨 종류 분할 버튼은 **같은 글자**로 유지), `PathBoard` 월 구간들. 기존 "범위·주차" 고르기와 복습 카드는 없앤다(복습은 탭이 있다). `_pick_field()` 는 안 쓰면 지운다.
- `start_lesson()`(110행): 시작할 때 `_run_n`, `_run_w` 에 `sel_n`, `sel_w` 를 적어 둔다.
- `finish_lesson()`(332-350행): `Store.mark_today(lang)`(346행) 근처에 `StudyLog.add_path_lesson(lang, _run_n, _run_w, ok, results.size())` 한 줄.
- `open_target(args)` 추가(§4.4). `_render_run`, `_render_done`, `_render_loading`, 채점·녹음·운율 코드는 **손대지 않는다**.
- 새 부품 파일: `ui\path_board.gd`(`class_name PathBoard extends Container`: 노드 자리 계산, 선 그리기), `ui\path_node.gd`(`class_name PathNode extends Button`: 상태별 모양), 시트 본문 만들기는 `PathBoard` 의 정적 함수 `detail_body(lang, n, w, state) -> Control`.
- `PathBoard` 계약:
```gdscript
func build(lang: String, month_n: int, states: Array, names: Array, current_global_idx: int) -> void   # 한 달(4칸) 구간
signal node_pressed(n: int, w: int, state: String)
func node_rects() -> Array                  # [Rect2] 노드 전역 사각형(시험)
func node_button(w: int) -> Button          # w = 1..4
```
- 노드마다 `accessibility_name = "%d개월차 %d주, %s"`(상태 말: 완료/지금/열림/건너뜀/잠김).

---

## 10. 접근성

| 항목 | 기준 | 어디서 |
|---|---|---|
| 터치 크기 | 누를 수 있는 모든 것의 가로·세로 ≥ 48(`Ds.touch_min()`, 폰). 노드 56/72, 탭 칸 ≥ 48x56, 할 일 줄 ≥ 56, 바로가기 ≥ 64. 표시만 하는 것(돌, 칩, 링)은 터치 대상이 아니다 | `phone_layout_test --phone` 의 `TOUCH_SMALL_COUNT` 0 |
| 글자 배율 | 90~150% 에서 겹침·잘림 0. 줄바꿈 허용(`autowrap`), 노드 이름표는 2줄 + 말줄임. 링 안 숫자는 지름 안에 들어가게 상한 | `--font-scale=1.5` 로 `LAYOUT_OVERFLOW_COUNT` 0 |
| 대비 | §5.3. 글자 4.5, 도형 3.0 | `contrast_test` |
| 색만으로 구분 금지 | 노드는 모양(체크·재생·숫자·자물쇠)과 크기, 이름표 글자. 돌은 채움/테두리/점. 경고는 도형 + 글자. 정답은 ✓ | 구조 시험(§12 T4, T5) |
| 이름 붙이기 | 아이콘만 있는 컨트롤과 노드·링에 `accessibility_name`. 실제 낭독은 **미검증**(TalkBack 은 확인 못 함) | 시험은 속성 값이 비어 있지 않은지만 |
| 모션 | 100~500ms, 끌 수 있는 큰 움직임 없음 | §5.7 |
| 한 손 조작 | 시작 버튼·탭·바로가기는 화면 아래 절반 가까이. 폰 하단 탭은 항상 | 와이어프레임 |

---

## 11. 작업 분할

### 11.1 규칙 (모든 작업 공통)
- 담당은 전부 `worker-hard`(구현·시험 모두). 검토는 §11.3 의 `reviewer`.
- 각 작업은 **별도 worktree**에서 한다: `D:\Ai\언어\app_wt\home_<작업>`, 브랜치 `home/<작업>`. 오케스트레이터가 §11.2 순서대로 합친다. 소유 파일이 겹치지 않게 나눠서 합칠 때 충돌이 없어야 한다.
- 임시 파일·로그·가짜 APPDATA 는 `…\scratchpad\w_<작업>\` 안에만 둔다.
- 새 `class_name` 스크립트를 더한 뒤 `godot --headless --path <worktree>\godot --import` 를 한 번 돌리고, 생성된 `.uid` 파일도 같이 둔다(기존 저장소가 `.uid` 를 가지고 있다).
- 시험은 시험 머리 주석의 명령을 따른다. `--api` 가 필요한 시험은 **닫힌 포트** `--api=http://127.0.0.1:9` 만 쓴다.

### 11.2 의존 순서와 병렬
```
1파 (동시에 3명):  T0 토큰·스타일  ∥  T1a 기록·길 모델  ∥  T1b 홈 모델·AI 자리·노래 집계
2파 (1파가 끝나고 동시에 3명):  T3 셸·메뉴  ∥  T4 홈  ∥  T5 레슨 길
3파:  T6 전 화면 훑기(2파가 합쳐진 뒤)
4파:  reviewer 독립 검토(각 작업마다, 2파·3파는 합치기 전) → 오케스트레이터 통합 시험(T7)
```
| 작업 | 선행 | 병렬 가능 | 소유(수정 허용) 파일 |
|---|---|---|---|
| T0 | 없음 | T1a, T1b 와 동시 | §11.4 |
| T1a | 없음 | T0, T1b 와 동시 | §11.5 |
| T1b | 없음 | T0, T1a 와 동시 | §11.6 |
| T3 | T0, T1a, T1b 합친 뒤 | T4, T5 와 동시 | §11.7 |
| T4 | T0, T1a, T1b | T3, T5 와 동시 | §11.8 |
| T5 | T0, T1a | T3, T4 와 동시 | §11.9 |
| T6 | T3, T4, T5 | 단독 | §11.10 |

소유 파일은 **한 작업에만** 있다. 예외 하나: `core\home_model.gd` 는 T1b 가 만들고(1파), T4 는 T1b 가 합쳐진 뒤 `snapshot()` 본문만 채운다(순서가 달라 충돌 없음). 다른 작업의 파일은 읽기만 한다. 고칠 필요가 생기면 오케스트레이터에게 보고하고 직접 고치지 않는다.

### 11.3 공통 합격 조건 (모든 작업에 붙는다)
| ID | 조건 | 판정 |
|---|---|---|
| C-0 | **작업 전** 자기가 건드리는 시험의 기준선을 잰다: 각 시험 `== … N passed, M failed ==` 줄과 종료 코드를 `scratchpad\w_<작업>\baseline.txt` 에 적는다. 이 기준선은 보고서 맨 앞 표에 붙인다 | 파일이 있고 표에 있음 = O |
| C-1 | 시험 명령 형식: `$G = 'C:\Users\rtyu6\Desktop\Godot_v4.6.3-stable_win64.exe\Godot_v4.6.3-stable_win64_console.exe'`, `$env:APPDATA = '<scratchpad>\w_<작업>\appdata'`(실제 사용자 폴더를 읽고 쓰지 않게), `& $G --headless --path <worktree>\godot [--resolution 412x915] res://tests/<이름>.tscn [-- --phone] [--font-scale=1.5] [--dark]` | 마지막 줄 `== … N passed, 0 failed ==`, 종료 코드 0 |
| C-2 | 출력에 `SCRIPT ERROR:` 가 0줄 | `Select-String 'SCRIPT ERROR:'` 0건 |
| C-3 | 출력에 `TEST_GUARD on` 이 정확히 1줄(시험 보호 켜짐) | 1건 |
| C-4 | 출력·코드·명령에 `8770`, `8775`, `8776` 이 0번 나온다(접속 금지) | 0건 |
| C-5 | **기존 시험 기대값을 근거 없이 완화하지 않는다.** 시험 파일의 diff 에서 지워지거나 느슨해진 단언은 §13 표에 줄 번호로 적힌 것만 허용. 기준선 N passed 보다 줄었다면 줄어든 이유가 §13 에 있어야 한다 | diff 검토 + 표 대조 |
| C-6 | 소유 밖 파일 수정 0: `git -C <worktree> diff --name-only <기준 커밋>` 가 소유 목록의 부분집합 | 부분집합 = O |
| C-7 | 프로세스는 자기가 시작한 PID 만 종료. 이름으로 끄지 않는다. 시험 서버가 필요하면 포트가 비었는지 먼저 확인하고(8770/8775/8776 제외), 보고에 "남은 프로세스·열린 포트 없음"을 적는다. 이 설계의 시험은 서버가 필요 없다(닫힌 포트 9 사용) | 보고 문구 + `Get-NetTCPConnection` 확인 |
| C-8 | 실제 사용자 폴더(`%APPDATA%\Godot\app_userdata\…`) 쓰기 0. 시험이 만드는 파일은 `user://test_*` 또는 시험 보호가 옮긴 `user://test_guard\` 만. 새 시험은 `Store.prefs_path`, `Store.progress_path`, `StudyLog.path`, `SongStore.root` 를 `user://test_home_*` 로 바꿔 쓴다 | 시험 전후 실제 폴더 목록 비교 같음 |
| C-9 | 비밀값(키·토큰·auth 파일 내용) 출력·기록 0 | 보고에 없음 |
| C-10 | 새 파일이 §6 의 독창성 검사를 통과: `rg -n -i "duolingo|듀오|올빼미|\bowl\b|flame|불꽃|#58CC02|#1CB0F6|#FF9600|#FFC800|#CE82FF" <새·바꾼 파일>` 0줄. 새 코드에 `Color("#` 리터럴 0(`core\pal.gd` 만 예외), 이모지·도형 글자 문자열 0 | 0줄 |
| C-11 | **검사기도 실패할 수 있어야 한다**: 새 시험마다 일부러 틀린 입력을 같은 검사 함수에 넣어 "실패로 판정되는지"를 찍는 줄이 있다(`selfcheck FAIL-as-expected …`). 더해서 작업자는 코드 상수 하나를 일부러 틀리게 바꾼 뒤(예: `LOOKAHEAD := 5`) 시험이 **실패하는** 출력 줄을 보고서에 붙이고 원래대로 되돌린다 | 출력 줄 존재 |
| C-12 | 읽지 못한 결과·실행하지 않은 항목은 "O" 가 아니라 "미검증"으로 적는다 | 보고 형식 |

보고 맨 앞: 합격 조건 표(항목 / O·X·미검증 / 근거 = 실행한 명령과 출력 요약).

### 11.4 T0 — 토큰·스타일 (`worker-hard`)
- 소유: `godot\scripts\core\pal.gd`, `godot\scripts\ui\ds.gd`, `godot\scripts\ui\ui.gd`, `godot\scripts\ui\glyph.gd`, `godot\tools\make_theme.gd`, `godot\theme\app_theme.tres`, `godot\theme\app_theme_dark.tres`, `godot\tests\contrast_test.gd`, `godot\tests\ui_prims_test.gd`
- 하는 일:
  0. **작업 전** `ui_perf_test` 기준선 파일을 만든다: `… res://tests/ui_perf_test.tscn -- --out=<scratchpad>\baseline\perf_old.json`(2파가 이 파일로 비교한다).
  1. `pal.gd`: §5.2 값으로 `PRIMARY`, `PRIMARY_SOFT` 변경, `REWARD`, `REWARD_SOFT`, `REWARD_ON` 추가(`LIGHT`, `DARK` 표, `static var`, `use()`).
  2. `ds.gd`: §5.5 상수 추가. 기존 상수 값 변경 금지.
  3. `ui.gd`: 폰에서 `kind == "primary"` 이면 높이 `max(min_h, Ds.CTA_H)`. 캐시 키(`_button_styles`)에 영향이 없는지 확인. `soft_pair()` 에 `REWARD` → `[REWARD_SOFT, REWARD_ON]` 추가.
  4. `glyph.gd`: `KINDS` 에 `"sparkle"`(네 갈래 별 다각형), `"star"`(오각 별, 채움), `"lock"`(자물쇠: 몸체 둥근 사각형 + 고리 호), 기존 `_draw` 의 `match` 에 그리는 코드 추가. 이모지·글자 사용 금지.
  5. `make_theme.gd` 로 두 테마 파일을 다시 만든다.
  6. `contrast_test.gd`: `TEXT_PAIRS` 에 `REWARD_ON/REWARD_SOFT, REWARD_ON/SURFACE, REWARD_ON/BG, REWARD_ON/SUNK, MUTED/REWARD_SOFT, ON_ACCENT/REWARD, PRIMARY/SUNK` 추가, `NONTEXT_PAIRS` 에 `REWARD/SURFACE, LINE_STRONG/PRIMARY_SOFT, LINE_STRONG/REWARD_SOFT` 추가, `tok()` 에 새 이름 추가, 181·182·184행의 의도적 변경 단언을 새 값으로(§13).
  7. `ui_prims_test.gd`: 폰 primary ≥ 56, soft·outline 48, PC primary 높이 강제 없음 단언 추가.
- 합격 조건:
  | ID | 조건 | 명령 → 기대 |
  |---|---|---|
  | T0-1 | 테마 두 개가 다시 만들어진다 | `& $G --headless --path <wt>\godot --script res://tools/make_theme.gd` → 출력에 `theme saved: res://theme/app_theme.tres err=0` 와 `…app_theme_dark.tres err=0`, 종료 코드 0 |
  | T0-2 | 대비 시험 통과, 새 쌍이 라이트·다크 둘 다 검사됨 | `contrast_test` → `== contrast: N passed, 0 failed ==`, 출력에 `REWARD_ON/REWARD_SOFT` 가 `light` 와 `dark` 구간에 각각 있음 |
  | T0-3 | 검사기 자체 점검 3줄 유지 | 출력에 `selfcheck FAIL-as-expected #777777/#FFFFFF`, `selfcheck PASS-as-expected #767676/#FFFFFF`, `selfcheck FAIL-as-expected legacy JA/JA_SOFT` |
  | T0-4 | 의도한 변경만 바뀜 | `git diff -U0 godot\tests\contrast_test.gd` 에서 지워진 줄이 181, 182, 184행의 `PRIMARY` 값 단언 3개뿐. 나머지는 추가 줄 |
  | T0-5 | `Pal` 원래 16색 라이트 값 변화 없음 | `contrast_test` 의 `LEGACY …` 16줄이 모두 PASS |
  | T0-6 | 새 글리프가 그려진다 | `contrast_test` 의 `GlyphIcon('sparkle'|'star'|'lock')` 줄이 PASS 이고 "all glyphs survived two frames of drawing" PASS |
  | T0-7 | 폰 시작 버튼 높이 | `ui_prims_test -- --phone` → 새 단언 "primary >= 56" PASS. PC 실행에서는 primary 에 높이 강제 없음 단언 PASS |
  | T0-8 | 공유 UI 시험 회귀 없음 | `ui_nav_test`, `ui_regress_test`, `a11y_sweep_test`, `ui_prims_test` 를 PC 와 `-- --phone` 으로 각각: 모두 `0 failed`, passed 수가 기준선 이상 |
  | T0-9 | 전체 화면 훑기가 깨지지 않음 | `phone_layout_test --resolution 412x915 -- --phone` 와 PC(1280x800) 모두 `0 failed`(이 시험은 2파에서 바뀌므로, T0 단계에서는 기준선과 **같은 단언 수·같은 결과**여야 한다) |
  | T0-10 | 다크 | `contrast_test` 의 다크 구간 전부 PASS. `a11y_sweep_test -- --dark` PASS |
  | T0-11 | 성능 기준 | `ui_perf_test -- --baseline=<perf_old.json> --max-ratio=1.3` → `0 failed` |
  | T0-12 | 일부러 틀린 값 | `PRIMARY` 라이트를 #7C8596 같은 낮은 대비 값으로 잠깐 바꾸고 `contrast_test` 가 **실패**하는 줄을 보고에 붙인다(원복 후 통과 다시 확인) |
- 금지: 원래 16색 라이트 값 변경, `R_BTN/R_CARD/R_SHEET/S6/REC_*` 변경, 소유 밖 파일 수정, `Color("#…")` 를 `pal.gd` 밖에 추가.

### 11.5 T1a — 기록·길 모델 (`worker-hard`)
- 소유: `godot\scripts\core\study_log.gd`, `godot\scripts\core\study_clock.gd`, `godot\scripts\autoload\store.gd`, `godot\scripts\core\path_model.gd`(새), `godot\scripts\views\app_view.gd`, `godot\tests\study_log_test.gd`, `godot\tests\path_model_test.gd`(새) + `.tscn`, `godot\tests\sample_studylog_path.json`(새 보조 파일)
- 하는 일: §9.1(함수·정리 규칙·`KNOWN_KEYS`·`StudyClock` 한 줄), §9.2(`PathModel`), §4.4(`Store.navigate_args`, `ai_connect_requested`, `request_ai_connect()`, `AppView.open_target`).
- 합격 조건:
  | ID | 조건 | 명령 → 기대 |
  |---|---|---|
  | T1a-1 | 길 기록 읽기·쓰기·다시 읽기 | `study_log_test` → `0 failed`, 새 줄: `add_path_lesson` 두 번 → `path_done == 2`; `flush()` 후 `load_from_disk()` → 같은 값; `path_last == [n, w]` |
  | T1a-2 | 틀린 입력 정리 | `sample_studylog_path.json`(깨진 `path`: 셀 키 "13-9"·"abc"·"0-1", done -5·"x"·1e99, `last` 가짜 날짜 "2026-02-30", `resume.view` "hack", `at` "soon", `path` 자체가 배열인 변형) → 읽으면 에러 없이 정리된 값, 파일은 `.bad` 로 격리되지 **않음**(JSON 이 유효하므로). `study_log_test` 가 항목마다 PASS |
  | T1a-3 | 깨진 JSON 은 기존대로 격리 | 같은 시험에 잘린 JSON 입력 → `last_load_status == "bad"`, `.bad` 파일 생김, 빈 상태로 시작 |
  | T1a-4 | 모르는 키 보존 + `path` 키 없는 파일 | v99 샘플(`sample_studylog_v99.json`)을 읽고 쓰면 `future_feature` 보존, `path` 키가 **생기지 않음** |
  | T1a-5 | `note_resume` 규칙 | 같은 view+lang 이 60초 안에 다시 오면 `is_dirty()` 가 그대로, 다른 view 면 갱신. 잘못된 view("hack")·lang("fr") → false. `resume()` 의 `at` 이 미래 1일 초과(시계 이상)여도 에러 없이 반환(표시 여부는 HomeModel 몫) |
  | T1a-6 | `reset()` 이 `path` 도 지움 | 시험 줄 PASS |
  | T1a-7 | 보호된 날 | `frozen_days("en")` 가 `freeze.en.frozen` 의 날짜를 일 번호 사전으로 돌려줌. 빈 경우 `{}` |
  | T1a-8 | `PathModel` 표 시험 | `path_model_test` → `0 failed`, 줄 12개 이상: 아무것도 안 함(cal 0 → current 0, 1·2번 `open`, 3번부터 `locked`), 기록 있음·그 칸 미완료(current = 그 칸), 그 칸 완료(current = 다음 미완료), 중간 건너뜀(앞 미완료는 `past`), 48칸 전부 완료(`finished == true`, 전부 `done`), 달력 위치 20·기록 없음, `done` 배열 길이 10·60, `cal_idx` -5·999, `last_idx` -1·48·-99, `lookahead` 0·5, `index_of(13,1) == -1`, `cell_of(48) == []` |
  | T1a-9 | 검사기가 실패할 수 있음 | `path_model_test` 에 일부러 틀린 기대값을 같은 비교 함수에 넣어 `selfcheck FAIL-as-expected` 가 찍힌다. 그리고 `LOOKAHEAD := 5` 변이 → 시험 실패 줄을 보고에 붙임(원복) |
  | T1a-10 | `done_flags` 가 주 체크를 반영 | 시험: `Store.set_checked(Store.check_key("en",3,"w",1), true)` → `done_flags("en")[index_of(3,2)] == true` |
  | T1a-11 | Store 신호 | 시험(`path_model_test` 안): `Store.request_ai_connect()` 를 부르면 `ai_connect_requested` 가 정확히 1번, `navigate_args.emit("lesson", {})` 가 받아짐 |
  | T1a-12 | 기존 계산 시험 회귀 없음 | `streak_test`, `persist_test`, `test_guard_test`, `sync_merge_test` PASS, passed 수가 기준선 이상. `StreakCalc`·`settle` 코드 diff 0줄 |
  | T1a-13 | 변경이 더하기뿐 | `git diff --stat` 에서 `study_log.gd`·`study_clock.gd`·`store.gd`·`app_view.gd` 의 삭제 줄이 `KNOWN_KEYS` 한 줄(수정)과 `reset()` 안 한 줄 이내 |
- 금지: `StreakCalc`, `Progress.normalize`, `SyncDoc`, `apply_sync` 변경, `progress.json` 모양 변경, 새 저장 파일 만들기.

### 11.6 T1b — 홈 모델·AI 자리·노래 집계 (`worker-hard`)
- 소유: `godot\scripts\core\home_model.gd`(새), `godot\scripts\core\home_ai.gd`(새), `godot\scripts\core\song_due.gd`(새), `godot\tests\home_model_test.gd`(새) + `.tscn`, `godot\tests\home_ai_test.gd`(새) + `.tscn`, `godot\tests\song_due_test.gd`(새) + `.tscn`
- 하는 일: §9.3(`snapshot()` 제외), §9.4, §9.6. `snapshot()` 은 `StudyLog`·`Store`·`PathModel`(T1a 가 만드는 클래스)을 부르므로 T1b 는 만들지 않는다: 함수 틀과 `# TODO(T4)` 만 두고 `return {}`. **`snapshot()` 본문의 소유는 T4**(§11.8, 1파가 합쳐진 뒤). T1b 시험은 스냅샷을 **직접 만든 사전**으로만 시험한다.
- 합격 조건:
  | ID | 조건 | 명령 → 기대 |
  |---|---|---|
  | T1b-1 | 할 일 표 시험 | `home_model_test` → `0 failed`, 줄 30개 이상. 최소 사례: 새 사용자(레슨 todo + 말하기 optional, 복습·노래 줄 없음), 복습 12개(레슨 앞/뒤: due 12는 뒤, due 20은 앞), 레슨 끝(done, 시작 버튼이 복습), 전부 끝(`all_done == true`, "더 연습하기"), `due == 0 && reviews_today > 0`(복습 끝!), `song_due == 3`, 길 완료(`finished`) 부연 글자, 음수 `due -5`, `due 10**9`, 키가 빠진 빈 사전 `{}` |
  | T1b-2 | 문구 표 | 같은 시험: §8.4 의 7행 각각 입력 → 정확한 글자·종류. 순서(시작일 전이 맨 앞)를 겹치는 입력으로 확인(예: before + first_run → 1번이 이김) |
  | T1b-3 | 이어하기 | `resume`: 레슨(7일 안, 시작 버튼이 레슨이면 `{}`), 복습(남은 0 → `{}`), `at` 8일 전 → `{}`, `at` 미래 2일 → `{}`, `view` "hack" → `{}`, `at` 가 문자열 → `{}`, 시작 버튼 대상과 같은 화면이면 `{}` |
  | T1b-4 | 시작 버튼 글자 | 레슨 + 최근 레슨 활동이면 "레슨 이어하기", 아니면 "오늘의 레슨 시작", 복습 "복습 12개 시작", 노래 "노래 외우기 시작", 끝 "더 연습하기" |
  | T1b-5 | AI 자리 기본 구현 | `home_ai_test` → `0 failed`. `Backend.status` 를 READY/FAILED/NEEDS_PAIRING/IDLE 로 바꿔(엔진은 시작하지 않는다: `Backend._starting = true`, `set_process(false)`) 표(§9.6)와 같은 `show/state/title/action` |
  | T1b-6 | provider 가 낯선 값 | `HomeAi.provider` 가 `null` 반환, 문자열 반환, 키 빠진 사전, 제목 500자 → `slot()` 이 에러 없이 안전한 값(`show` false 또는 24자·60자·10자로 잘림). 설정 후 `provider = Callable()` 로 되돌림 |
  | T1b-7 | 오늘 숨기기 | `dismiss_today()` 후 `dismissed_today() == true`, `StudyLog.today_override` 를 +1 하면 false. `prefs` 는 `Store.prefs_path = user://test_home_prefs.json` 에만 저장 |
  | T1b-8 | 노래 집계 | `song_due_test` → `0 failed`. `lister` 에 가짜 곡 3개(가사만 2, 음원 1)·`due` 합 5 → `{"songs":3,"lyrics":2,"due":5,…}`. `lister` 가 `null`·깨진 요약({}·문자열) → 0. `SongStore.blocked()` 가 참인 시험 보호 안에서 `scan()` 은 실제 `user://songs` 를 열지 않고 0 |
  | T1b-9 | 검사기 실패 점검 | 세 시험 모두 `selfcheck FAIL-as-expected` 줄. 변이: `REVIEW_FIRST_DUE := 99` → `home_model_test` 실패 줄 보고(원복) |
  | T1b-10 | 순수 계산 | 위 시험이 파일을 쓰지 않는다: 시험 전후 `user://test_home_*` 외 변화 0 |
- 금지: `home_model.gd` 가 `Control`·노드를 만드는 것, 시험이 실제 `user://songs`·`prefs.json` 접근, `snapshot()` 본문 작성.

### 11.7 T3 — 셸·메뉴 (`worker-hard`)
- 소유: `godot\scripts\main.gd`, `godot\scripts\views\menu_view.gd`(새), `godot\tests\menu_view_test.gd`(새) + `.tscn`, `godot\tests\phone_layout_test.gd`, `godot\tests\t5_wiring_test.gd`, `godot\tests\song_view_test.gd`, `godot\tests\touch_scroll_test.gd`, `godot\tests\shots_phone.gd`, `godot\tests\ui_regress_test.gd`, `godot\tests\standalone_ui_test.gd`
- 하는 일: §4(탭 목록·`BAR_PHONE`·`TAB_PARENT`·`NAV_GROUPS`·`back_target`·`_origin`·배지·`_on_navigate_args`·`_on_ai_connect`), §9.7(`MenuView` + `main` 연결), PC 메뉴 라벨 "홈", §13 의 시험 수정(셸 관련 줄).
- 합격 조건:
  | ID | 조건 | 명령 → 기대 |
  |---|---|---|
  | T3-1 | 폰 하단 바 | 폰 실행 씬(`t5_wiring_test -- --phone --api=http://127.0.0.1:9`): `bar_keys() == ["today","lesson","review","song","menu"]`, 칸 5개, 더보기 칸 없음, 각 칸 ≥ 48x56, 라벨 순서 홈·레슨·복습·노래·메뉴 |
  | T3-2 | 폰 자식 씬 | `phone_layout_test -- --phone`: `bar_keys() == ["today","lesson","review","menu"]`, 칸 4개 |
  | T3-3 | `tab_keys()` | §4.2 의 네 가지 기대 배열과 정확히 같음(PC·폰, 자식·실행 씬) |
  | T3-4 | 메뉴 화면 | `menu_view_test` → `0 failed`: 묶음·행 수, 행 높이 ≥ 56, 행을 누르면 `entry_chosen(key)`, 알 수 없는 key 클릭은 무시, 빈 묶음은 안 보임, `set_summary("")` 이면 카드 없음, 글자 배율 1.5 에서 가로 넘침 0 |
  | T3-5 | 메뉴 안 화면의 탭 불 | 폰: `show_view("talk")` → 하단 바에서 "menu" 가 선택됨(`BottomTabs` 의 현재 키가 `"menu"`). `show_view("today")` → "today" |
  | T3-6 | 뒤로 가기 | 폰 시험(`phone_layout_test::_test_back` 에 줄 추가): ① 메뉴 → 읽기 → `handle_back()` → 현재 `"menu"` ② 홈 → `Store.navigate("talk","en")` → `handle_back()` → 현재 `"today"` ③ 레슨 탭 → `handle_back()` → `"today"` ④ 홈에서 `handle_back()` 한 번 → 토스트 "한 번 더 누르면 종료돼요", `exit_requested` 0번, 2초 안에 한 번 더 → `exit_requested` 1번 ⑤ 시트가 열려 있으면 `handle_back()` 이 시트만 닫고 화면은 그대로 |
  | T3-7 | 앱 바 ← 와 같은 동작 | `ui_regress_test` 의 두 뒤로 가기 경로 단언 PASS(바 ← 와 `handle_back` 이 같은 결과) |
  | T3-8 | PC 메뉴 | PC: `item_buttons().size() == 10`(실행 씬), 세로 순서가 홈<레슨<복습<노래<대화<연습<읽기<기록<로드맵<설정, 묶음 머리글 "공부/말하기·읽기/기록", 폭 224, "메뉴" 항목 없음 |
  | T3-9 | 복습 배지 | 시험: 복습 카드 due 1개 → `BottomTabs` 의 review 배지 켜짐, 0개 → 꺼짐(`BottomTabs._badges["review"]`) |
  | T3-10 | AI 연결 신호 | `Backend.status = FAILED` 상태에서 메뉴의 "AI 연결" 행을 누르면 `Store.ai_connect_requested` 가 정확히 1번 나가고, 폰은 연결 화면(`is_connect_open()`), PC 는 `current == "settings"` |
  | T3-11 | 깊은 이동 | `Store.navigate_args.emit("lesson", {"lang":"ja","n":2,"w":3,"start":false})` → `current == "lesson"`, `Store.lang() == "ja"`, `LessonView.sel_n == 2`, `sel_w == 3`(T5 합친 뒤 통합 시험에서 확인. T3 단독 시점에는 `open_target` 기본 구현이 false 를 돌려주고 화면만 바뀌는 것까지 확인) |
  | T3-12 | 터치 스크롤 | `touch_scroll_test -- --phone` → `0 failed`, "menu" 시나리오가 새로 들어 있고, 앱 바·하단 탭에서 시작한 드래그는 페이지를 움직이지 않음(기존 shell drag 단언 PASS). 하단 탭 인덱스 `cell_buttons()[1]` 은 레슨 칸 |
  | T3-13 | 전 화면 훑기 | `phone_layout_test --resolution 412x915 -- --phone` 와 PC 1280x800: `0 failed`, `LAYOUT_OVERFLOW_COUNT 0`, `TOUCH_SMALL_COUNT 0`. `--font-scale=1.5`, `--dark` 도 각각 0 failed |
  | T3-14 | 유지해야 하는 것 | `main.gd` 에 `func add_sync()` 와 `\t\tadd_sync()` 가 그대로(`sync_panel_test` 714행), `OWN_HEADER`·연결 칩·배너·스플래시 코드 diff 0줄 |
  | T3-15 | 노래 탭 시험 | `song_view_test`(PC·폰·`--font-scale=1.5`) 0 failed. 1098행 "add_v11_tabs() 전에는 노래 탭 없음" 단언은 그대로 PASS |
  | T3-16 | 폰 단독 흐름 | `standalone_ui_test -- --phone --api=http://127.0.0.1:9` 와 `standalone_flow_test -- --phone --api=http://127.0.0.1:9` 0 failed, `sent_count 0` |
- 금지: `BottomTabs`·`SideNav`·`AppBar` 코드 변경(소유 아님), 설정 화면(`settings_view.gd`) 수정, `Sheet`·`ToastHost` 수정, 연결 화면 흐름 변경, 시험 기대값을 §13 에 없는 줄에서 완화.

### 11.8 T4 — 홈 화면 (`worker-hard`)
- 소유: `godot\scripts\views\today_view.gd`, `godot\scripts\ui\goal_ring.gd`(새), `godot\scripts\ui\home_parts.gd`(새), `godot\scripts\core\home_model.gd`(**`snapshot()` 본문만**, T1b 가 합쳐진 뒤), `godot\tests\home_view_test.gd`(새) + `.tscn`, `godot\tests\settings_view_test.gd`, `godot\tests\review_walk_test.gd`
- 하는 일: §7.1, §7.2, §8.1~8.5, §9.5. 홈은 `HomeModel`·`HomeAi`·`SongDue`(스레드)·`StudyLog` 를 써서 그린다. 30초 타이머로 날짜 바뀜 감지. 언어 스위치는 `UI.lang_segmented` + `Store.set_lang`.
- 합격 조건:
  | ID | 조건 | 명령 → 기대 |
  |---|---|---|
  | T4-1 | 홈 구조 | `home_view_test` → `0 failed`(PC 와 `-- --phone`): `card("tasks")` 있음, `hero_button()` 글자가 `HomeModel.hero().text` 와 같음, `GoalRing` 노드 정확히 1개, `_voice_row("en")` 가 컨트롤을 돌려줌 |
  | T4-2 | 카드 순서·조건 | 시험: 이어하기 조건이 없으면 `card("resume") == null`; AI 상태 `FAILED`(+`prominent` false)이면 `card("ai")` 가 `card("streak")` **뒤**; `prominent` true 이면 `tasks` **앞**; `HomeAi.dismiss_today()` 후 `card("ai") == null`; 폰만 `card("shortcuts")` 있음 |
  | T4-3 | 폰 첫 화면(412x915, 100%) | 시험: `hero_button().get_global_rect().end.y <= 480`. 이어하기 카드가 있으면 `card("resume").get_global_rect().position.y < 859`. 가로 넘침 0 |
  | T4-4 | 폰 150% 글자 | `--font-scale=1.5`: `hero_button()` 아래 끝 y <= 700, 할 일 줄 글자 잘림 0(`LAYOUT_OVERFLOW_COUNT 0`) |
  | T4-5 | PC 배치 | 1280x800: `is_wide() == true`, `card("tasks")` 와 `card("streak")` 가 서로 다른 열(x 가 다름), 겹침 0, `hero_button()` 아래 끝 y <= 420. 창을 폭 900(본문 < 980)으로 줄이면 `is_wide() == false` 이고 모든 카드 겹침 0, 다시 1280 이면 `true` |
  | T4-6 | 터치 크기 | 폰: 홈의 모든 `BaseButton` 높이 ≥ 47.5, 시작 버튼 ≥ 56(`Ds.HOME_CTA_H_PHONE` 60), 바로가기 ≥ 64, 할 일 줄 ≥ 56 |
  | T4-7 | 복습 글자 규칙 | `review_walk_test` → `0 failed`: 복습 카드 N개일 때 "복습 N개" 가 포함된 Button 글자가 있고, 카드 0개일 때 "복습 " 으로 시작하는 Button 이 **하나도 없다**(시작 버튼 포함) |
  | T4-8 | 설정 시험의 오늘 부분 | `settings_view_test` → `0 failed`: `_test_today_cards` 가 새 홈 구조(§13)로 바뀌고, `_test_today_settings` 의 첫 부분(설정 토글·`SettingsView` 없음, `go_back()` false)은 그대로 PASS |
  | T4-9 | 연속 카드 값 | 시험: `StudyLog` 에 연속 3일·보호권 1·오늘 안 함을 만들고(`today_override`, `Store.progress["days"]`) → 알약 글자 "연속 3일", "보호권 1", 돌 7개 중 지난 3개 채움·오늘 보라 테두리·앞날 점. 보호된 날이 있으면 `frozen_days` 로 `REWARD_SOFT` 면 |
  | T4-10 | 날짜가 바뀜 | 시험: 홈이 보이는 상태에서 `StudyLog.today_override += 1` → 타이머(또는 시험이 `_check_day()` 호출) 뒤 다시 그려져 "오늘" 돌 위치가 한 칸 이동, 오늘 안 한 상태면 연속 글자가 새 규칙 |
  | T4-11 | 시작 버튼이 일한다 | 시험: 시작 버튼을 누르면(`pressed.emit()`) 대상 화면이 열림(`Store.navigate`/`navigate_args` 신호를 시험이 구독해서 인자 확인: 레슨 → `navigate_args("lesson", {lang, n, w, start:true})`) |
  | T4-12 | AI 자리 버튼 | `Backend.status = FAILED` → "AI 연결하기" 버튼을 누르면 `Store.ai_connect_requested` 정확히 1번, [나중에] 를 누르면 카드가 사라지고 `prefs.home_ai_dismiss_day` 저장(시험 prefs 경로) |
  | T4-13 | 노래 줄 | `SongDue.cache` 에 `due 4` 를 넣고 홈을 그리면 "노래 외우기 4줄" 줄이 있고, `due 0` 이면 노래 줄이 없다. 시험에서 실제 `SongStore` 를 열지 않는다(`SongDue.cache` 를 직접 채우고 스레드 스캔은 `SongStore.blocked()` 로 건너뜀) |
  | T4-14 | 스크롤 | `touch_scroll_test -- --phone` 의 "today" 시나리오 PASS(빈 곳·카드·버튼·라벨에서 시작한 300px 드래그가 200px 이상 움직임. 단 시작 위치 종류 수가 기준선보다 **줄지 않음**) |
  | T4-15 | 전 화면 훑기 | `phone_layout_test` 의 today 상태(폰·PC), `a11y_sweep_test`, `screens_scan_test` 를 `--font-scale=1.5`, `--dark` 포함 0 failed (phone_layout_test 의 today 단언은 T3 가 §13 대로 고친 상태를 쓴다 → T3 와 합친 뒤 오케스트레이터가 실행) |
  | T4-16 | 성능 | `ui_perf_test -- --baseline=<perf_old.json> --max-ratio=2.0` 에서 today 의 `build_ms`·`nodes` 중앙값이 기준선의 2.0배 이하(추정 한도: 첫 측정 뒤 오케스트레이터가 조정할 수 있음). 다른 5개 화면은 1.3배 이하 |
  | T4-17 | 파일 규칙 | `today_view.gd` 에 `SyncPanel`·`open_settings` 글자 0(`rg -c`), `Color("#` 0, 새·바꾼 파일 독창성 검사(C-10) 0줄 |
  | T4-19 | 직접 표시 | 연속 카드의 "오늘 공부한 걸로 표시" 를 누르면 `Store.did_day(StudyLog.today(), lang)` 가 참이 되고 버튼 글자가 "표시 취소" 로 바뀐다. 다시 누르면 거짓. 목표 시간·레슨으로 이미 켜진 날도 같은 값을 보여 준다 |
  | T4-18 | 일부러 틀린 입력 | 시험이 ① 스냅샷이 빈 사전 ② `HomeAi.provider` 가 쓰레기 ③ `SongDue.cache` 가 음수 ④ 곡 목록이 깨짐 으로 홈을 그려도 에러 없이 기본 모양(할 일 줄 레슨 + 말하기)을 보인다 |
- 금지: `lesson_view.gd`·`main.gd` 수정, 언어 카드 2장·"이번 주 활동 끝냄" 줄을 홈에 남기기(옮겼다: 노드 시트), `GoalCard`(기록 탭이 쓴다) 수정, 기존 `StudyLog` 규칙 변경, 포트 8770/8775/8776 접속.

### 11.9 T5 — 레슨 길 (`worker-hard`)
- 소유: `godot\scripts\views\lesson_view.gd`, `godot\scripts\ui\path_board.gd`(새), `godot\scripts\ui\path_node.gd`(새), `godot\tests\lesson_path_test.gd`(새) + `.tscn`
- 하는 일: §7.3~7.5, §8.3, §9.8. 풀이·채점 코드는 건드리지 않는다.
- 합격 조건:
  | ID | 조건 | 명령 → 기대 |
  |---|---|---|
  | T5-1 | 길 구조 | `lesson_path_test`(PC·폰) → `0 failed`: 월 구간 12개, 노드 48개(`PathBoard.node_button` 합계), 각 노드가 `PathModel.states` 의 상태와 같은 모양 표식(`PathNode.state`) |
  | T5-2 | 상태 고정 입력 | 시험이 기록을 만든다: 3개월차 1주 5회 완료, 2주 3회 → 지금 = 3-2(칸 번호 9), 노드 상태(칸 번호 `i = (n-1)*4+(w-1)`): 0~7 중 완료 아닌 것은 `past`, 8(3-1) `done`, 9(3-2) `current`, 10(3-3)·11(3-4) `open`, 12(4-1) 이상 `locked`. 주 체크만 켠 칸도 `done` |
  | T5-3 | 레슨 기록 | `finish_lesson()` 호출(시험이 `results` 를 채우고 부름) → `StudyLog.path_done(lang, _run_n, _run_w)` 가 1 늘고, `path_last` 가 그 칸. 레슨 시작 후 선택 칸을 바꿔도(시험이 `sel_n` 을 바꿈) 기록은 **시작한 칸**에 쌓인다 |
  | T5-4 | 노드 터치 크기 | 폰: 모든 노드 `get_global_rect` ≥ 56x56(current 72), 노드끼리 겹침 0, 화면 가로 넘침 0 |
  | T5-5 | 지금 노드가 보인다 | 길을 열고 3프레임 뒤 `node_button(w)` 중 current 의 전역 사각형이 `_page` 의 보이는 영역 안(위에서부터 25~50% 구간) |
  | T5-6 | 노드 시트 | 열린 노드를 누르면 시트가 열리고 [레슨 시작] 이 있다. 누르면 `sel_n/sel_w` 가 그 칸이고 `status == "loading"`(시험은 `Api` 를 닫힌 포트로: `Api.sent_count` 를 확인하고, 폰 은행 경로로 가는 시험은 `LocalApi.handler_override` 로 가짜 응답) |
  | T5-7 | 잠긴 노드 | 잠긴 노드를 누르면 확인 시트가 열린다. [닫기] 또는 `Sheet.handle_back()` → 시트만 닫히고 `status == "idle"`, `Api.sent_count` 변화 0. [미리 해 보기] → 레슨이 시작됨 |
  | T5-8 | 주 체크 | 시트의 "이번 주 활동 끝냄" 을 켜면 `Store.is_checked(check_key(lang,n,"w",w-1)) == true` 이고 길을 다시 그리면 그 노드가 `done`. 끄면 도로 돌아옴 |
  | T5-9 | 기존 시험 | `lesson_source_test`(PC·폰) 0 failed 그대로(분할 버튼 글자 "실제 예문 레슨 (빠름)"/"AI 레슨 (느림)", 폰은 "실제 예문 (빠름)"/"AI (느림)" 가 `lv._page.content` 안에 있음). `local_lessons_test`, `standalone_flow_test -- --phone --api=http://127.0.0.1:9` 0 failed |
  | T5-10 | 깊은 이동 | `LessonView.open_target({"lang":"ja","n":2,"w":3,"start":false})` → 언어 "ja", `sel_n == 2`, `sel_w == 3`, `status == "idle"`, true 반환. `start: true` 이고 `lesson_source() == "ai"` 이면 시작하지 않음. 범위 밖 `n=13` → false 반환, 선택 변화 없음, 에러 없음 |
  | T5-11 | 스크롤·터치 | `touch_scroll_test -- --phone` 의 "lesson_home" 시나리오 PASS(노드 위에서 시작한 드래그도 200px 이상 움직임) |
  | T5-12 | 풀이 화면 불변 | `lesson_view.gd` diff 에서 `_render_run`, `_render_done`, `_render_loading`, `check_answer`, `_on_recorded` 등 풀이 구간의 줄 변경 0 |
  | T5-13 | 글자 배율·다크 | `lesson_path_test` 를 `--font-scale=1.5`, `--dark` 로도 0 failed. 150% 에서 노드 이름표가 노드와 겹치지 않음(이름표 사각형 ∩ 노드 사각형 = 빈) |
  | T5-14 | 성능 | `ui_perf_test` lesson 의 중앙값이 기준선의 2.0배 이하(추정 한도, 오케스트레이터 조정 가능), 노드 개수는 월 구간을 한꺼번에 만들어도 `nodes` 가 600 이하(추정) |
  | T5-15 | 일부러 틀린 입력 | 시험이 ① `StudyLog` 에 깨진 `path` ② 커리큘럼이 비어 있음(`Store.curriculum = {}`) ③ 주 개수가 3 인 달 ④ `start_lesson` 도중 `quit_lesson` 으로 길을 그려도 에러 없이 48칸(커리큘럼이 비면 이름표 없이 숫자만) |
  | T5-16 | 파일 규칙 | `Color("#` 0, 이모지·도형 글자 0, C-10 통과 |
- 금지: `today_view.gd`·`main.gd` 수정, 레슨 풀이·채점·녹음·운율 코드 변경, `LocalLessons` 커서 로직 변경, 에러 없이 조용히 삼키기(시험에서 확인되지 않는 `if x == null: return` 으로 상태를 숨기지 않는다).

### 11.10 T6 — 전 화면 훑기 (`worker-hard`)
- 소유: 기본은 없음(검증 작업). 훑기에서 **실패한 줄이 가리키는 파일만**, **숫자·색 토큰 한 줄 수정에 한해** 고칠 수 있다. 허용 후보: `godot\scripts\views\review_view.gd`, `roadmap_view.gd`, `stats_view.gd`, `practice_view.gd`, `talk_view.gd`, `reading_view.gd`, `godot\scripts\practice\speak_drill.gd`. 각 파일 수정은 보고에 줄 번호와 이유를 적는다. 이 밖의 수정은 오케스트레이터에게 보고.
- 하는 일: 2파가 합쳐진 상태에서 폰·PC, 글자 배율 100/130/150, 라이트·다크로 전 화면을 훑어 새 토큰과 큰 버튼(`primary` 56)이 만든 줄바꿈·넘침·잘림을 찾아 고친다. 결과를 표로(화면 x 조건 x 판정).
- 합격 조건:
  | ID | 조건 | 명령 → 기대 |
  |---|---|---|
  | T6-1 | 폰 훑기 3종 | `phone_layout_test --resolution 412x915 -- --phone` 을 기본, `--font-scale=1.15`, `--font-scale=1.3`, `--font-scale=1.5`, 각각 `--dark` 와 짝지어 8회: 모두 `0 failed`, `LAYOUT_OVERFLOW_COUNT 0`, `TOUCH_SMALL_COUNT 0` |
  | T6-2 | PC 훑기 | `phone_layout_test --resolution 1280x800` 기본·`--font-scale=1.5`·`--dark`: 0 failed |
  | T6-3 | 나머지 화면 | `screens_scan_test`(폰: 기본·1.5·`--dark`, PC), `a11y_sweep_test`(같은 조합), `touch_scroll_test -- --phone`, `ui_nav_test`, `ui_regress_test`, `stats_view_test` PC·폰: 0 failed |
  | T6-4 | 기존 학습 화면이 새로 그려지지 않았음 | `git diff --stat <1파 이전 커밋>..HEAD -- godot\scripts\practice godot\scripts\song godot\scripts\views\talk_view.gd godot\scripts\views\reading_view.gd godot\scripts\views\review_view.gd` 의 변경 줄이 숫자·색 토큰 줄뿐(보고에 목록) |
  | T6-5 | 독창성 검사 | `rg -n -i "duolingo|듀오|올빼미|\bowl\b|flame|불꽃|#58CC02|#1CB0F6|#FF9600|#FFC800|#CE82FF" godot\scripts godot\tools godot\tests` 0줄(작업 전에 설계자가 같은 명령을 돌려 0줄임을 확인함) |
  | T6-6 | 색 직접 쓰기 없음 | `rg -n 'Color\("#' godot\scripts` 의 결과가 `core\pal.gd` 한 파일뿐(작업 전에 설계자가 확인: pal.gd 31줄, 그 밖 0줄) |
- 금지: 시험 기대값 완화, 소유 밖 대규모 수정, 화면 구조 재작성.

---

## 12. 합격 조건과 금지 조건 요약 (한눈에)

모든 작업에 C-0~C-12(§11.3)가 붙는다. 작업별 O/X 는 §11.4~§11.10 의 표가 정본이다.

공통 금지(문서 어디서나):
1. 포트 8770 / 8775 / 8776 접속 금지.
2. 실제 사용자 폴더 쓰기 금지. 시험은 `user://test_*` 만.
3. 이름으로 프로세스 종료 금지(자기가 시작한 PID 만).
4. 기존 시험 기대값을 §13 에 없는 이유로 완화 금지.
5. 비밀값 출력·기록 금지.
6. 다른 작업 소유 파일 수정 금지.
7. 시험이 실제 `user://songs`, 실제 `progress.json`, `studylog.json`, `prefs.json` 을 열거나 쓰는 것 금지.

---

## 13. 기존 시험은 어떻게 바뀌나 (의도한 변경만. 이 표에 없는 단언 완화는 불합격)

| 시험 | 줄(지금 기준) | 지금 단언 | 바뀌는 모습 | 담당 |
|---|---|---|---|---|
| `contrast_test.gd` | 181-182 | `PRIMARY == #0A6BD6`, `PRIMARY_SOFT == #E8F1FC` ("INTENTIONAL CHANGE") | `#0A726D`, `#E4F5F3`. 문구에 "INTENTIONAL CHANGE (home_menu_design D9)" | T0 |
| `contrast_test.gd` | 184 | 다크 `PRIMARY == #7DB4FF`, `PRIMARY_SOFT == #12263F` | `#4FD1C5`, `#10302E` | T0 |
| `contrast_test.gd` | 17-30 | 글자·도형 쌍 목록 | §11.4 6번의 쌍 추가(삭제 없음) | T0 |
| `contrast_test.gd` | 244 | `Ds` 상수 단언 | 유지 + 새 상수 값 단언 추가 | T0 |
| `phone_layout_test.gd` | 226-228 | 폰 today: `tv._grid.columns == 1` | `not tv.is_wide()` | T3 |
| `phone_layout_test.gd` | 229-241 | 바 5칸, `direct_keys == [today,lesson,talk,review]`, `overflow_keys` 에 settings | 자식 씬은 4칸 `bar_keys == [today,lesson,review,menu]`, 더보기 칸 없음, `max_direct == 5` 유지 | T3 |
| `phone_layout_test.gd` | 246-247 | 앱 바 제목 "오늘", 동작 1개 "설정" | 제목 "홈", 동작 1개 "설정" | T3 |
| `phone_layout_test.gd` | 250 | 설정 화면은 더보기 항목 | 설정은 "메뉴" 탭이 켜진 상태에서 열림 (`TAB_PARENT`) | T3 |
| `phone_layout_test.gd` | 343-345 | PC today: `_grid.columns == 2`, 설정 항목 보임 | `tv.is_wide()`, 왼쪽 메뉴에서 "홈" 선택됨 | T3 |
| `phone_layout_test.gd` | 589-632 | `tab_keys` 9개, `direct/overflow` 목록, 더보기 시트 5행, 설정 선택 | §4.2 의 새 배열, 더보기 시트 시험은 **삭제**(시트가 없어짐. 같은 자리에 "메뉴 화면이 바 밖 키 전부를 행으로 가짐" 단언 추가), `add_tab("log")` 은 설정 앞 | T3 |
| `phone_layout_test.gd` | 636-665 | PC 메뉴 순서·10개·섹션 | 순서 홈<레슨<복습<노래<대화<연습<읽기<기록<로드맵<log<설정, 10개 유지 | T3 |
| `phone_layout_test.gd` | 718-740 | 폭 900 에서 `_grid.columns == 1`, 언어 카드 2장 겹침 없음 | `not tv.is_wide()`, `card("tasks")` 등 모든 카드 겹침 0, 1280 에서 `is_wide()` | T3 |
| `t5_wiring_test.gd` | 107-135 | 폰 `direct/overflow` 목록, PC 10항목 | `bar_keys == [today,lesson,review,song,menu]`, PC 10항목 유지 | T3 |
| `t5_wiring_test.gd` | 153 | 오늘에 compact `GoalCard` 1개 | `GoalRing` 1개 | T3 |
| `t5_wiring_test.gd` | 159-185 | 탭 클릭·폭별 동작 | 키 목록이 새 목록. 같은 동작 단언 유지 | T3 |
| `song_view_test.gd` | 1098-1113 | 노래 탭이 폰 더보기 안 | 노래는 폰 바 4번째 칸, `NAV_GROUPS` 의 "공부" 에 있고 `OWN_HEADER` 유지 | T3 |
| `touch_scroll_test.gd` | 시나리오 목록(223-) | today, settings, lesson_home … | "menu" 시나리오 추가(폰). 기존 시나리오 삭제 없음 | T3 |
| `shots_phone.gd` | 166-167, 390-403 | today 상태, `_bottom_tabs.open_more()` | 더보기 열기 구간 삭제(없어짐). "menu" 상태 추가(폰) | T3 |
| `ui_regress_test.gd` | 뒤로 가기 경로 단언 | 바 ← 와 `handle_back` | 같은 단언 유지(결과가 같아야 함) | T3 |
| `settings_view_test.gd` | 405-440 `_test_today_cards` | 언어 카드 2장, 카드마다 언어색 채움 버튼 1개, "오늘의 레슨" 버튼, 열 수 | 새 홈: 채움 버튼은 홈 전체에서 **정확히 1개**(시작 버튼, `PRIMARY` 채움), 그 글자가 "오늘의 레슨…" 으로 시작, `is_wide() == (not _phone)` | T4 |
| `review_walk_test.gd` | 228-245 | "복습 N개" 버튼, 0개면 "복습 " 버튼 없음 | **변경 없음**(홈이 이 규칙을 지켜야 함) | T4(통과 확인만) |
| `ui_perf_test.gd` | 비교 | 기준선 1.3배 | 코드 변경 없음. 실행 때 today·lesson 만 2.0배 허용(§11.8 T4-16, T5-14) | T4, T5 |
| `sync_panel_test.gd` | 711-714 | `today_view.gd` 에 `SyncPanel`·`open_settings` 없음, `main.gd` 에 `add_sync()` | 변경 없음(지켜야 함) | T3, T4 |
| `lesson_source_test.gd` | 41-61 | 분할 버튼 글자·선택 저장 | 변경 없음(지켜야 함) | T5 |
| `stats_view_test.gd` | 262 | `GoalCard.compact` 한 줄 | 변경 없음(`GoalCard` 는 기록 탭이 계속 씀) | - |
| `tts_test.gd`, `smoke.gd`, `ui_nav_test.gd` | `TodayView.new()`, `_voice_row`, `BottomTabs`/`SideNav` API | 변경 없음 | - |

---

## 14. 위험 요소와 대안

| # | 위험 | 가능성·영향 | 대안·대응 |
|---|---|---|---|
| R1 | 화면 구조에 기대는 시험이 많아 한꺼번에 깨짐 | 높음 / 중간 | §9.5·§4.2 의 이름을 계약으로 못 박고, 시험 수정은 §13 줄 단위로 소유자를 정함. 통합 시험(T7)은 오케스트레이터가 직접 실행 |
| R2 | 청록(대표색)과 초록(정답)이 비슷해 헷갈림 | 중간 / 낮음 | 정답에는 항상 체크 도형 + 글자. 역할 규칙 §5.2. 거슬리면 §16 Q1 의 대안(현재 파랑 유지, 밝기만 조정)으로 바꾼다. 값은 `pal.gd` 두 줄 |
| R3 | 길 노드 위에서 시작한 세로 드래그가 스크롤이 안 됨(터치 훅) | 중간 / 높음 | 노드는 `Button`(`BaseButton`)이라 `install_touch_scroll` 훅이 PASS 로 바꾼다. `touch_scroll_test` 의 lesson_home 시나리오로 확인(T5-11). 안 되면 노드를 `UI.on_tap` 으로 바꾼다 |
| R4 | `PathBoard` 직접 배치가 글자 150% 에서 겹침 | 중간 / 중간 | 노드 지름은 고정, 이름표만 줄바꿈·말줄임. T5-13 으로 확인 |
| R5 | "이어하기" 기록이 `StudyClock` 에서만 남아 시험 환경에서는 비어 있음 | 낮음 / 낮음 | `StudyClock` 은 앱이 실행 씬일 때만 있다(`main.gd` 197-199행). 시험은 `StudyLog.note_resume` 을 직접 부른다 |
| R6 | `StudyLog.settle()` 이 홈을 그릴 때마다 토스트를 낼 수 있음(보호권 사용·획득) | 낮음 / 낮음 | 지금 `GoalCard` 도 같다. 같은 날 두 번째 호출은 `used/gained == 0`(멱등, `streak_calc.gd` 규칙) |
| R7 | 길이 이 기기 전용이라 폰·PC 진도가 다르게 보임 | 중간 / 낮음 | 주 체크(동기화됨)로 이어 붙임. 후속: `path` 를 동기화 문서에 넣는 별도 설계(이번 범위 밖) |
| R8 | 새 사용자 첫 실행에서 "달력 위치"가 시작일 전/후로 어긋남 | 낮음 / 낮음 | `Plan.DEFAULT_START` 는 "2026-11-01"(`plan.gd` 8행). before/after 규칙을 §8.3 에 명시, 시험 입력으로 확인(T1a-8) |
| R9 | `SongDue` 가 곡이 많을 때 느림 | 낮음 / 낮음 | 스레드, 30초 안 다시 읽지 않음, 시험 보호 중 건너뜀 |
| R10 | 폰에서 `primary` 56 이 좁은 하단 바(레슨 풀이 등)를 넘침 | 중간 / 낮음 | 풀이 화면 하단 바는 이미 56. T6 훑기에서 넘침 0 확인. 넘치면 해당 파일만 숫자 조정 |
| R11 | 설치 설계자가 `main.gd` 를 동시에 고쳐 충돌 | 중간 / 중간 | `_on_ai_connect()` 본문과 `HomeAi.provider` 만 그쪽, 나머지 `main.gd` 는 T3. 오케스트레이터가 합칠 순서를 정한다 |
| R12 | 실기기에서 폰 첫 화면이 설계 추정치(시작 버튼 y ≤ 480)보다 길어짐 | 중간 / 중간 | 헤드리스 시험은 고정 크기 기준. 실기기 dp 환산은 **미검증**(`Ds.touch_min()` 이 좁은 폰에서 최대 60 으로 키움). 사용자가 실기기에서 확인 |
| R13 | 독창성 판단은 사람이 한다 | 낮음 / 중간 | 검사는 기계적 문자열뿐이다. 최종 시각 판단은 오케스트레이터가 스크린샷(`shots_phone.gd`)으로 한다 |
| R14 | 이전 버전 앱이 `studylog.json` 을 다시 쓰면 `path` 가 사라질까 | 낮음 / 낮음 | "모르는 최상위 키는 보존" 규칙(`study_log.gd` 7-8행)과 `sample_studylog_v99` 시험이 이미 있다. T1a-4 가 `path` 가 없는 파일도 확인 |
| R15 | 길 노드 자리 계산이 창 크기 변화(`NOTIFICATION_RESIZED`)마다 다시 돌아 느림 | 낮음 / 낮음 | `ColumnBox` 처럼 같은 폭이면 건너뜀 + 한 프레임에 한 번(`ui_regress_test` 의 재귀 점검 방식 참고) |

### 일부러 틀린 입력으로 확인할 실패 시나리오 (시험이 직접 한다)
1. `studylog.json` 의 `path` 가 배열·문자열·숫자, 셀 키 "0-0"·"13-1"·"abc", `done` 가 -1·"7"·NaN·1e99, `resume.at` 가 "soon"·-5·미래 → 에러 0, 정리된 값(T1a-2).
2. `studylog.json` 이 잘린 JSON → `.bad` 격리, 빈 상태(T1a-3).
3. `PathModel.states` 에 길이 10·60·0 인 `done`, `cal_idx` -5·999, `last_idx` -99·48 → 에러 0, 48칸 결과(T1a-8).
4. `HomeModel` 스냅샷이 `{}`, `due` -5·1e9, `hour` 99, `resume.view` "hack" → 에러 0, 기본 할 일(T1b-1).
5. `HomeAi.provider` 가 null·문자열·키 빠진 사전·500자 제목 → 안전한 값(T1b-6).
6. 시계 되돌림: `StudyLog.today_override` 를 `freeze.last` 보다 과거로 → 홈이 연속을 표시만 하고 보호권·기록을 바꾸지 않음(기존 가드. T4 시험에 한 줄).
7. 날짜가 바뀐 채 홈 열림: `today_override += 1` → 다시 그림(T4-10).
8. 잠긴 노드 → [닫기]·뒤로 가기 → 레슨이 시작되지 않고 `Api.sent_count` 0(T5-7).
9. 레슨 중간에 선택 칸을 바꿈 → 기록은 시작한 칸(T5-3).
10. 커리큘럼이 비어 있음·주가 3개인 달 → 에러 0(T5-15).
11. `Backend.status` 가 READY 인데 `llm_missing` → "AI 답변이 꺼져 있어요" 카드(T1b-5).
12. 메뉴에서 알 수 없는 key 클릭, 빈 묶음, 항목 0개 → 에러 0(T3-4).
13. 글자 배율 `9.0`·NaN·"abc" 로 시작 → 1.5·1.0(기존 `Ds.sanitize_scale`, 화면 에러 0).
14. 검사기 자체: 새 시험마다 틀린 기대값이 "실패"로 판정되는 줄(`selfcheck FAIL-as-expected`)과 상수 변이 1회(C-11).

---

## 15. 확인 방법 요약 (오케스트레이터용)

- 2파·3파가 끝날 때마다 reviewer 가 **새 컨텍스트**로 §11 의 해당 표를 처음부터 다시 실행해 O/X 판정(코드 수정 없음). 위험도: 시험·구조 변경이 크므로 "보통"(reviewer 1회), 단 T1a(저장 파일 모양)는 "높음"(오케스트레이터가 T1a-1~T1a-6, T1a-12 를 직접 다시 실행).
- 오케스트레이터가 직접 재실행할 핵심 명령: T0-1, T0-2, T1a-1, T1a-8, T3-3, T3-6, T4-3, T5-2, T6-1 한 조합.
- 통합(T7, 오케스트레이터): 합친 뒤 `phone_layout_test`(폰·PC·150%·다크), `t5_wiring_test`, `touch_scroll_test`, `standalone_flow_test`, `route_test`, `smoke`, `run_memo_tests.ps1`(포트 18797/18798 만 사용, 시작 전·후 비었는지 확인)과 `run_sync_tests.ps1` 을 실행. 이 문서의 시험 목록에 없는 시험이 깨지면 원인 작업에 되돌린다(최대 3라운드).
- 스크린샷(창이 있는 실행)은 사용자 확인용: `shots_phone.gd` 를 폰(412x915)·PC(1280x800), 라이트·다크로 `scratchpad\shots_home_menu\` 에. 합격 조건은 아니고 **미검증 항목**으로 사용자에게 알린다.

---

## 16. 사용자에게 물어야 할 결정 (추천안 포함)

| # | 질문 | 선택지 | 추천 |
|---|---|---|---|
| Q1 | 대표색 | (A) 청록 + 보라(이 문서) (B) 지금 파랑 유지, 밝기·모양만 새로 | **A**. 영어 파랑과 겹치지 않고 독창적이다. 마음에 안 들면 `pal.gd` 두 줄로 B 로 바꾼다 |
| Q2 | 폰 하단 탭 5개 | (A) 홈·레슨·복습·노래·메뉴 (B) 홈·레슨·대화·복습·메뉴(노래는 메뉴 안) | **A**. 대화·연습·읽기는 홈 바로가기 줄에 항상 보인다 |
| Q3 | 길 잠금 | (A) 부드러운 잠금(앞 2칸 열림, 먼 칸은 확인 뒤 열림) (B) 완전 열림(잠금 없음) (C) 완전 잠금 | **A** |
| Q4 | 한 칸(주)을 끝낸 것으로 치는 레슨 횟수 | 1 / 3 / **5** / 10 | **5**(월~금 하루 1개). 상수 `PathModel.NODE_GOAL` 한 줄 |
| Q5 | 복습이나 연습만 해도 "공부한 날"로 칠까(지금은 레슨 끝·목표 시간 달성·직접 표시만) | (A) 지금처럼 (B) 복습 5장 이상도 인정 | **B**를 별도 후속 작업으로(연속 계산 시험이 늘어남). 이번 범위에서는 **A**. 직접 표시 버튼은 연속 카드로 옮겨 남긴다 |
| Q6 | 연속 학습일 | (A) 언어별(지금) (B) 두 언어 합산 | **A** |
| Q7 | 홈에 언어 | (A) 선택한 언어 하나 + 스위치 (B) 두 언어 카드 | **A** |
| Q8 | PC 왼쪽 메뉴 순서 변경(홈·레슨·복습·노래 / 대화·연습·읽기 / 기록·로드맵) | 동의 / 지금 순서 유지 | **동의**(폰과 같은 지도) |
| Q9 | 하루가 바뀌는 시각 | (A) 현지 00:00(지금) (B) 새벽 4시 | **A**(`StreakCalc` 시험이 날짜 기준) |
| Q10 | AI 연결 자리 위치 | 연결이 안 될 때만 연속 카드 아래 / 항상 맨 위 | 연결이 안 될 때만 아래. 설치 첫 실행은 설치 설계자가 `prominent` 로 맨 위 |
| Q11 | 마스코트 | 없음(코드로 그린 도형만) | **없음** |
| Q12 | 홈의 인사 문구(§8.4) 말투 | 이 문서의 해요체 / 반말·존댓말 변경 | 해요체 유지 |

오케스트레이터가 정해야 할 일: ① Q1~Q9 확정 ② 설치 설계 문서가 생기면 §9.6 과 대조 ③ 1파·2파 합치는 순서와 `main.gd` 충돌 방지(R11) ④ 성능 한도(T4-16, T5-14) 첫 측정 뒤 확정 ⑤ 실기기·스크린샷 확인을 누가 하는지.

---

## 요약 (10줄)

1. 홈(`TodayView`, 키 "today" 유지)은 선택한 언어 하나로 오늘 할 일(링 + 큰 시작 버튼 + 할 일 줄)과 이어하기를 맨 앞에 크게 보여 준다.
2. 폰 하단 탭 5개는 홈·레슨·복습·노래·메뉴. 더보기 시트는 없어지고 "메뉴"가 화면이 된다. PC 왼쪽 메뉴는 같은 순서의 3묶음.
3. 레슨 탭은 12개월 x 4주 = 48칸 길. 칸 완료 = 그 주 레슨 5번 또는 주 체크. 부드러운 잠금(앞 2칸까지 열림, 더 먼 칸은 확인 뒤 열림).
4. 새 저장 파일은 없다. `studylog.json` 에 이 기기 전용 키 `path`(칸별 횟수, 마지막 칸, 마지막 활동) 하나만 더하고, 정리·격리·초기화는 기존 코드를 쓴다.
5. 연속 학습일 계산(`StreakCalc`)은 그대로. 날짜 경계는 현지 00:00. 홈은 날짜 바뀜을 30초마다 감지한다.
6. 색은 `PRIMARY`(청록)·`REWARD`(보라) 두 계열만 새로 정하고 나머지 팔레트와 반경 상수는 그대로라 시험 변경이 적다. 대비 수치는 모두 계산했다.
7. 독창성: 마스코트·불꽃·입체 버튼·특정 앱 색 조합을 쓰지 않고, 기계 검사(rg)와 사람의 스크린샷 확인으로 막는다.
8. "AI 연결" 자리는 `HomeAi.slot()` + `Store.ai_connect_requested` 계약만 두고, 구현 교체는 설치 설계자가 한다. `settings_view.gd` 는 건드리지 않는다.
9. 작업: 1파 T0(토큰)·T1a(기록·길 모델)·T1b(홈 모델·AI 자리) 병렬 → 2파 T3(셸·메뉴)·T4(홈)·T5(길) 병렬 → T6(전 화면 훑기) → reviewer. 소유 파일은 겹치지 않는다.
10. 기존 시험 중 구조에 기대는 줄은 §13 에 줄 번호로 적었고, 그 밖의 완화는 불합격이다. 결정할 것은 §16 Q1~Q9(대표색, 탭 구성, 길 잠금, 완료 레슨 수가 핵심).
