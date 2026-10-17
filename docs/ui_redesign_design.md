# 폰·PC UI 전면 개편 설계 (1.3 후보)

- 작성: designer (설계만, 코드·설정 수정 없음) / 대상: Godot 4.6.3 앱 `godot\` (폰 = `Platform.is_phone()`, PC = 그 반대)
- 읽은 것(코드로 확인): `godot\scripts\ui\ui.gd`, `core\pal.gd`, `core\platform.gd`, `ui\phone_layout.gd`, `ui\bottom_tabs.gd`, `ui\card_box.gd`, `ui\column_box.gd`, `ui\page_scroll.gd`, `ui\score_panel.gd`, `ui\recorder_widget.gd`, `ui\mini_chart.gd`(색 사용부), `ui\goal_card.gd`(머리), `ui\connect_view.gd`(머리), `main.gd`(전체), `views\app_view.gd`, `views\today_view.gd`(구조·설정 패널 구간), `views\lesson_view.gd`·`talk_view.gd`·`reading_view.gd`·`review_view.gd`·`roadmap_view.gd`·`stats_view.gd`·`practice_view.gd`(함수 목록과 홈 화면 구간), `practice\speak_drill.gd`(공용 틀), `theme\app_theme.tres`, `tools\make_theme.gd`, `project.godot`, `tests\phone_layout_test.gd`·`touch_scroll_test.gd`·`shots_phone.gd`(머리와 단언 목록), `docs\sync_design.md`(§2·§6.3·S7), `screenshots\*.png` 2장.
- 확인하지 못한 것: 폰 화면의 실제 모습(저장소 `screenshots\`에는 PC 화면 2장(2026-10-15)뿐이고, 폰 스크린샷은 창이 있는 렌더러와 앱 사용자 폴더 쓰기가 필요해서 이번 설계 작업에서 만들지 않았다. 폰 모습은 코드로 추정). 실기기 동작(Android dp 환산, 시스템 다크 모드 감지, TalkBack).
- 표기: **(추측)** = 코드·문서·실행으로 확인하지 못한 가정. 표기 없는 것은 코드를 읽거나 실행해서 확인한 사실이다.
- 실행으로 확인한 것(헤드리스 Godot 4.6.3, 임시 빈 프로젝트): `Control.accessibility_name` 있음, `Image.load_svg_from_string` 동작(오류 0, 2배 스케일 크기 정상), `CheckButton`·`Label.max_lines_visible`·`Window.theme`·`StyleBoxFlat.shadow_size`·Label `line_spacing` 테마 상수 있음. `DisplayServer.is_dark_mode_supported()` 는 헤드리스에서 false(더미 디스플레이라 의미 없음 → 데스크톱·Android 값은 **미검증**).
- 용어: **토큰** = 색·크기·간격 같은 디자인 값의 이름 붙은 상수, **부품** = 앱 바·리스트 그룹 같은 재사용 UI 조각, **셸** = `main.gd` 가 만드는 바깥 틀(내비게이션·토스트·스플래시).

---

## 1. 목표와 범위

### 1.1 목표
1. 폰과 PC 모두 같은 디자인 언어(삼성 One UI 의 원칙을 참고한 "보는 영역 위 / 조작 영역 아래, 둥근 카드 묶음, 큰 제목이 접히는 앱 바, 글자 많이 보여주기보다 한 번에 한 일")로 바꾼다.
2. 색·크기·글자·간격을 **토큰 한 곳**에서 정하고, 라이트/다크 두 벌을 같은 구조로 만든다.
3. 접근성 기준을 숫자로 못 박는다: 글자 대비 4.5:1(큰 글자 3:1), 터치 영역 48dp 이상, 글자 크기 선택(100~150%), 색만으로 구분하지 않기.
4. 기능은 그대로다. 학습 기록, 채점, 녹음, 복습 일정, 동기화, 연결 방식은 건드리지 않는다. 화면 전환 이름(`Store.navigate` 의 `"today"|"lesson"|"talk"|"practice"|"reading"|"review"|"stats"|"roadmap"`)과 `AppView` 계약(`refresh`, `on_hide`, `go_back`)도 유지한다.
5. 지금 있는 시험(특히 `touch_scroll_test`, `phone_layout_test`)을 깨지 않고, 개편이 의도적으로 바꾸는 단언만 **작업 지시에 줄 단위로 명시**해서 바꾼다.

### 1.2 이번에 하지 않는 것
- 기능 추가·삭제, 문구(한국어 안내문) 바꾸기. 화면에 보이는 한국어 문장은 구조상 필요할 때만(예: 새 부품의 라벨) 바꾼다.
- 삼성 로고·상표·글꼴 파일·아이콘 이미지·스크린샷 복제. 앱 안·README·릴리스 글 어디에도 "One UI" 또는 삼성 이름을 붙이지 않는다(§2.3).
- 아이콘 세트 도입(외부 아이콘 폰트·SVG 모음). 글꼴 파일 번들(시스템 글꼴 유지).
- Android 태블릿·폴더블 전용 레이아웃(600dp 이상에서 두 칸 배치). 폰 레이아웃을 가운데 정렬 컬럼으로 쓰는 현재 방식 유지.
- 화면 전환 애니메이션 대공사, 제스처(스와이프로 탭 전환 — One UI 도 탭 사이 스와이프를 막는다), 위젯, 알림.
- 실행 중 즉시 다크 모드 전환(v1 은 시작 시 적용, §5.1.4). 키보드 포커스 링 전면 도입(지금 버튼이 전부 `FOCUS_NONE`), TalkBack 지원 보장(Godot Android 의 접근성 연동 여부 **미검증**).
- 백엔드(Python), 동기화 로직, 폰 단독 모드 로직. 그 둘과 겹치는 UI 파일은 §9 순서로 피한다.
- `reading_view` 의 마스터-디테일 2분할(PC) 같은 구조 대공사는 **선택 과제**(W9 의 마지막 단계, 시간이 있을 때만).

---

## 2. One UI 참고 요약과 라이선스

### 2.1 읽은 문서 (2026-10-17 에 WebFetch 로 읽음)
`developer.samsung.com/one-ui` 의 다음 쪽: 개요(`/one-ui/index.html`), 구조(`structure/basic`, `structure/visual-depth`), 레이아웃(`layout/basic`, `layout/grid`), 부품(`comp/app-bar`, `comp/bottom-navigation`, `comp/bottom-bar`, `comp/button`, `comp/dialog`, `comp/list`, `comp/toast`, `comp/search`), 색(`color/system`, `color/theme`), 아이콘(`iconography/symbol`), 모션(`motion/basic`), 접근성(`accessibility/layout-and-typo`, `color-contrast`, `interaction-and-control`), 큰 화면(`largescreen-and-foldable/large_screen_layout`). 읽지 않은 쪽: 글쓰기(writing), 소리·햅틱, 화면 낭독기·포커스 순서·콘텐츠 접근성, 접는 폰. **타이포그래피 전용 쪽은 없다**(글자 크기는 접근성 쪽의 "최대 200% 확대"뿐, 숫자 값 없음).
쪽에 숫자가 거의 없다. 아래 "숫자"로 적은 것이 문서에서 확인된 전부이고, 나머지 수치(반경 24, 높이 56 등)는 **이 앱이 정한 값**이다.

### 2.2 원칙 요약 (우리 말로 다시 씀)
| One UI 쪽 | 핵심 | 확인된 숫자 |
|---|---|---|
| 개요 | ① 지금 할 일에 집중(짧은 길) ② 자연스럽게 조작: 화면을 **보는 영역(위)** 과 **조작 영역(아래)** 으로 나눠 손이 닿는 곳에 조작을 둔다 ③ 눈이 편안하게: 다크 모드, 글자 크기·굵기 조절 ④ 반응형: 화면 크기에 맞춰 배치 | - |
| 레이아웃 | 보는 영역 위쪽은 여백을 넓게, 터치 요소 넣지 않기. 조작 영역은 묶음(카드·리스트·이미지)별 여백. 좌우 여백에서 터치는 막힘 | 좌우 여백 **24dp 이상** |
| 깊이 | 블러·딤·그림자는 아껴서. 관련 없는 화면이 위에 뜨면 아래를 딤/블러, 관련 있으면 그림자만. 그림자는 약하고 부드럽게, **그림자와 딤을 동시에 쓰지 않는다** | - |
| 앱 바 | 큰(확장) 바는 스크롤하면 표준 높이로 줄고, 올리면 다시 커짐. 제목은 길면 줄이고, 그래도 안 맞으면 말줄임. 오른쪽에 동작 단추(선택), 맨 끝에 "더보기" | 제목 아래 동작 최대 2개, **한 화면 단추 3개 이하** |
| 하단 탭 | 글자만(아이콘 없음). 탭 사이 스와이프 이동 없음. 탭이 있으면 위 제목 생략 가능 | **4개 미만 권장, 최대 5개** |
| 하단 바 | 선택 후 쓰는 동작(편집·삭제) 용. 아이콘+글자, 한 개만 두지 않기 | 최대 5개 |
| 버튼 | 두 종류: flat(배경 없음, 낮은 강조) / contained(회색=중간, 색=높음). **한 화면에는 한 종류 스타일만** | 모서리 반경 **18dp** |
| 대화상자 | 선택·확인 = **화면 아래**, 정보·진행 = **가운데**. 확인 전까지 유지, 바깥 터치·뒤로가기로 닫힘 | - |
| 리스트 | 설정·메뉴를 묶음으로 쪼개 훑기 쉽게. 주 글은 명사/짧은 동사구, 한 줄. 부연은 꼭 필요할 때만. 켜짐/꺼짐은 **오른쪽 스위치** | 주 글 **31자 이내** |
| 토스트 | 한 줄 정도, 어떤 언어로도 3줄 초과 금지. 선택·경고는 토스트가 아니라 팝업. 스낵바는 오른쪽에 동작 단추 | 최대 **3줄** |
| 색 | 단색 위주의 안정된 배경, 밝은 색은 작은 포인트. 기능색(알림·수락·거절)은 라이트/다크에서 같은 색 계열 | (Samsung 의 기본 파랑 hex 는 문서에 있으나 **채택하지 않는다**, §2.3) |
| 테마 | 라이트·다크 모두 대비 충분. 다크에서는 배경·메뉴를 검정/짙은 회색으로, 이미지·내용이 번쩍이지 않는지 확인. 출시 전 두 모드 모두 시험 | - |
| 접근성 | 글자 최대 200% 확대에도 기능 유지, 터치 영역은 충분히 크게·간격 두기, 색만으로 구분 금지(회색조로 봐도 정보가 보여야 함) | 작은 글자 **4.5:1**, 큰 글자 **3:1**(18dp 초과 보통/14dp 초과 굵게) |
| 모션 | 기본 곡선: 빨리 시작해 천천히 멈춤. 100ms 미만은 지각 어려움, 500ms 초과는 작업을 지연 | **100~500ms** |
| 큰 화면 | 폭 600dp 이상이면 큰 화면 레이아웃. 메뉴를 옆에 계속 보여 주고, 짧은 작업은 전체 화면 대신 작은 팝업 | 폭 구분: <600 / 600~840 / ≥840dp |

### 2.3 라이선스 확인 (이 설계가 허용하는 범위)
- 쪽 하단: "Copyright © 2026 SAMSUNG. All rights reserved." 가이드라인 글에 대한 별도 이용 허락 문구는 **없다**.
- 약관(`developer.samsung.com/terms`): 삼성 이름·상표·로고·고유한 브랜드 특징 사용 권리를 주지 않는다. 사이트 내용을 사전 서면 허락 없이 복사·배포·전송하는 것과 사이트를 개작·파생물로 만드는 것을 금지한다. 사이트 이용은 개인·비영리 목적으로 제한. (소스 코드·프로젝트 예시는 개작 금지에서 제외.) 글꼴(SamsungOne)에 대한 언급은 약관에 없다 → **번들·복제 불가로 간주**한다(추측이 아니라 권리 부여가 없다는 뜻).
- 따라서 이 프로젝트의 방침:
  1. **원칙과 패턴만 참고**한다. 문서의 문장을 옮기지 않고 위 표처럼 우리 말로 요약한다. 숫자 사실(18dp, 24dp, 최대 5개, 4.5:1)만 적는다(4.5:1·3:1 은 WCAG 와도 같다).
  2. 색은 **우리가 고른 값**이다. Samsung 문서의 hex 값(`#0381fe` 등)을 쓰지 않는다. 글꼴은 현재 앱이 쓰는 시스템 글꼴(§5.3)이다. 아이콘은 코드로 그리는 단순 도형(§5.8)이다.
  3. 앱·README·릴리스 노트·저장소 설명에 삼성/One UI 표기와 로고를 쓰지 않는다. 이 문서(공개 저장소 `docs\`)는 참고 출처 URL 과 위 숫자만 담는다.
  4. 법률 자문이 아니다. 배포 전 의심되면 오케스트레이터가 사용자에게 확인한다.

---

## 3. 지금 구조 (코드로 확인한 사실)

### 3.1 화면 뼈대
- **폰** (`main.gd` `_build_phone_top_bar`, `BottomTabs`): 위 40px 띠(제목 "회화 연습" + 연결 상태 점·글자, 누르면 오늘의 설정 열림) → (배너) → 페이지 → 아래 탭줄. 탭줄은 `MAX_DIRECT = 6`: 8개 탭이면 5개 + "더보기"(탭 위에 뜨는 시트). 탭은 글자만, 선택은 위쪽 3px 검정 선.
- **PC** (`_build_top_bar`): 위 탭 줄(제목 + 탭 8개, 안 들어가면 "더보기 ▾" `PopupMenu`) + 오른쪽에 "폰 연결 켜짐"·엔진 상태 점. 선택은 아래 3px 검정 선. 페이지는 `PageScroll`(`ColumnBox` 가운데 정렬, 최대 폭 960).
- 탭 8개(`add_tab` 순서): 오늘, 레슨, 원어민 대화(폰 "대화"), 연습, 읽기, 복습, 기록, 로드맵. 설정은 탭이 아니라 **오늘 화면 아래 접히는 패널**(`today_view.gd` `_settings_panel`, `open_settings()`).
- 토스트(`main.gd` `_build_toast`, `Toast` 자동 로드의 `info/ok/error`), 스플래시(`_build_splash`, CanvasLayer 20), 연결 화면(`ConnectView`, CanvasLayer 25), 배너(`_build_banner`), 더보기 시트(`BottomTabs.open_more`, CanvasLayer 16)가 전부 코드로 만든 오버레이다.
- 화면 안 하위 화면: 연습 4종(`practice\*_screen.gd`)은 `SpeakDrill.build_shell`(← 뒤로 · 제목 · 쪽수 + 스크롤 본문 + 고정 하단 바) 공용 틀을 쓴다. 레슨은 `_render_footer` 로 하단 고정 바.

### 3.2 색·테마·글꼴·아이콘
- `core\pal.gd`: **`const Color`** 16개(BG #F4F5F7, SURFACE, SUNK, INK #1A202C, MUTED #5A6373, LINE #DDE1E8, EN #2C56C9/EN_SOFT, JA #C4412A/JA_SOFT, OK #23855A/OK_SOFT, BAD #B83A3A/BAD_SOFT, WARN #9A6A00/WARN_SOFT) + `accent(lang)`, `soft(lang)`. `const` 안에서 `Pal.*` 를 참조하는 곳은 **없다**(grep 확인) → `static var` 로 바꿔도 `Pal.INK` 사용 문법은 그대로 컴파일된다.
- `Pal.*` 사용 약 300곳(파일별: reading_view 38, mission_screen 38, main 29, talk_view 26, prosody_panel 22, lesson_view 20, today_view 19 …). `Color("#…")` 직접 쓴 곳 10곳(main 토스트·배너 4, prosody_panel 4, ui.gd 포커스 1, reading_view 학습 강조 2).
- 테마: `theme\app_theme.tres`(= `tools\make_theme.gd` 로 생성, `project.godot` `gui/theme/custom`). 변형(`theme_type_variation`): Big, BigCard, Card, Eyebrow, FlatButton, H1, H2, H3, Muted, OptionRow, Score, Seg, Small, Strong, Sunk, Tile, Toast, TopBar. 글자 크기: 기본 16, Big 34, H1 28, H2 21, H3 17, Strong 16, Muted 15, Small 13, Eyebrow 12, Score 40. 폰은 `PhoneLayout.font_bump` 로 기본 17, Small 14, Eyebrow 13, Muted 16, Strong 17.
- 카드: 흰 바탕 + 1px 테두리 + 반경 16(Card 12·BigCard 16 은 theme 의 StyleBox, `UI.card`). 버튼: `UI.style_button` 의 primary/soft/outline/flat, 반경 10, 가로 패딩 18.
- 글꼴: 파일 번들 없음. `SystemFont` 이름 순서 `Malgun Gothic, Yu Gothic UI, Meiryo, Segoe UI` + (Android) `Roboto, Noto Sans CJK KR, Noto Sans KR, Noto Sans CJK JP, Noto Sans JP, sans-serif`. 일본어 글자가 있으면 `UI.fix_cjk` 가 `ja_font` 를 줌. 굵게는 `font_weight=700`.
- 아이콘: **이미지 아이콘은 SVG 4개뿐**(`theme\check_on/off.svg`, `slider_grabber.svg`, `arrow_down.svg`, 직접 그린 단순 도형). 나머지는 글자 도형(`▶ ● ▾ ▴ ← ✓ ★ ☆`)을 라벨에 섞어 쓴다(약 20곳).
- 현재 팔레트의 대비(WCAG, 계산 스크립트로 확인): 거의 통과(INK/BG 14.96, MUTED/BG 5.55, EN/흰 6.40, BAD/흰 5.67). **실패 3건**: `JA` on `JA_SOFT` 4.27, `OK` on `OK_SOFT` 4.00, `WARN` on `WARN_SOFT` 4.29 (칩·알림 글자). `OK` on `BG` 4.21, `WARN` on `BG` 4.34 도 실패(카드 밖 글자로 쓸 때). 선 색 `LINE` 은 흰 바탕과 1.31:1(장식선이므로 허용, 입력칸 테두리는 3:1 필요 → §5.1).

### 3.3 터치 스크롤·시험 결합 (깨면 안 되는 것)
- `PhoneLayout.install_touch_scroll`: `main.gd` 가 폰에서 한 번 호출. `node_added` 신호로 **ScrollContainer 안의 `MOUSE_FILTER_STOP` 컨트롤을 `PASS` 로 바꾸고**, 모든 ScrollContainer 의 `scroll_deadzone` 을 12 로 둔다. OptionButton 은 손 뗄 때 열리게 한다. 입력칸은 세로 드래그를 직접 스크롤로 넘긴다(`_assist_field_drag`). 슬라이더·스크롤바·ItemList·Tree·SpinBox 와 `set_meta("own_drag", true)` 컨트롤은 제외.
- `UI.on_tap(c, cb)`: 폰에서는 **손 뗄 때** + 움직임 ≤ `TAP_SLOP`(12) 일 때만 호출. `UI.on_meta_click`: 드래그로 끝난 클릭 무시.
- **이번 개편의 규칙**: 새 부품의 누를 수 있는 모든 것은 `UI.on_tap` 또는 `BaseButton`(손 뗄 때 동작하는 Godot 기본)만 쓰고, 부품 안에 `gui_input` 으로 누름 즉시 동작하는 코드를 새로 만들지 않는다. 새 부품은 ScrollContainer 안에서 `MOUSE_FILTER_STOP` 이어도 훅이 PASS 로 바꾸므로 그대로 둔다. 시트·앱 바처럼 **ScrollContainer 밖 오버레이**는 STOP 이 맞다(아래로 이벤트가 새면 안 됨).
- 시험이 건드리는 구조(개편이 바꾸면 이 줄을 같이 고쳐야 함, **고치는 작업을 W 번호로 지정**):
  - `phone_layout_test.gd` 폰: 탭 셀 6개(`cells.size()==6`, 각 ≥48×56), `main.tab_buttons` 가 폰에서 안 보임, `main._status_text` 가 y 0~41 안(상단 띠 40px), 설정의 `RemoteLinkPanel` 이 설정 카드의 첫 항목, 오늘 `_grid.columns==1`, 대화 마이크 폭 >300, 레슨 녹음 버튼 폭 >300 높이 ≥56, 키보드 300px 일 때 탭줄 숨김·입력줄 616 이내. → **W4(셸)·W5(설정)** 가 고친다.
  - 같은 파일 PC: 상단 탭 6개 모두 보임, `_top_more` 숨김, `_link_text` 숨김, 오늘 `_grid.columns==2`, `main._bottom_tabs==null`, 녹음 버튼 `(96,44)`·`(190,58)`, 설정 안 `PhoneLinkPanel` 이 `_engine_ob`(엔진 섹션) 아래. → **W4·W5**. (녹음 버튼 PC 크기는 W6 에서 **바꾸지 않는다**: 토큰 `Ds.REC_BIG_PC=Vector2(190,58)`, `Ds.REC_SMALL_PC=Vector2(96,44)` 로 못 박아 단언이 그대로 통과.)
  - `phone_layout_test.gd` 터치 크기 임계: `BaseButton/LineEdit` 높이·폭 ≥ **43.5**(슬라이더 높이 ≥40). 새 목표는 47.5(= 48dp). → 임계는 **W13** 에서 올리고, 그 전에는 `--touch-min=47.5 --only=<상태접두>` 인자(W4 가 추가)로 작업별 확인.
  - `touch_scroll_test.gd`: 모든 스크롤 화면에서 300px 드래그가 최소 200px 움직임. `CheckBox or CheckButton` 모두 처리. 시작 위치로 빈 곳·카드·버튼·라벨·RichText·LineEdit·체크 등. → **모든 작업의 공통 합격 조건**.
  - `shots_phone.gd`(`phone_layout_test` 가 같은 순회를 씀): `main_node._toast_box`, `main_node._bottom_tabs.open_more()/close_more()`, `tdv._settings_open`, `tdv._settings_btn`, `tdv._scroll`, `lv.*`(status, picked, built, `_record_widget`, `_autoplayed`, `_render`, …), `tv.*`, `rv.*` 등 **화면 내부 멤버를 직접 만진다**. → 화면 작업자는 `grep -n "lv\.\|tv\.\|rv\.\|tdv\." godot\tests\*.gd` 로 나오는 멤버의 이름·의미를 **유지**한다. 이름을 바꿔야 하면 오케스트레이터에게 보고(시험을 약하게 고치지 않는다).
  - `Toast.message(text, kind)` 신호 계약은 여러 시험이 구독 → 유지(`kind` 는 `"info"|"ok"|"error"`).

---

## 4. 원칙을 이 앱에 적용하는 방식

### 4.1 폰
| 원칙 | 적용 |
|---|---|
| 보는 영역 / 조작 영역 | **위**: 큰 제목 + 한 줄 요약(보는 영역, 터치 요소 없음). **아래**: 하단 탭(항상), 화면별 고정 **조작 바**(레슨의 "확인/다음", 연습의 "다시/다음", 대화의 입력줄·마이크). 손가락이 닿는 아래 1/3 에 주 행동을 둔다. 목록 화면은 위쪽 앱 바 동작을 최소(연결 칩, 설정). |
| 큰 제목이 접히는 앱 바 | 페이지 첫 항목으로 **큰 제목 블록**(`PageHeader`, 제목 32 굵게 + 한 줄 부제)을 두고, 화면 위에 **고정 앱 바**(높이 56 + 상태바 inset: 뒤로, 작은 제목, 동작, 연결 칩)를 둔다. 스크롤하면 큰 제목이 밀려 올라가며 앱 바의 작은 제목이 서서히 나타난다(알파 0→1). One UI 는 바 높이 자체가 줄지만, 이 구현은 **스크롤 내용의 높이가 줄어드는 되먹임을 피하려고** 높이는 고정하고 제목만 교차 표시한다(의도적 근사). 앱 바가 상태를 기억한다는 원칙은 `ScrollContainer.scroll_vertical` 이 보존되므로 자동 충족. |
| 한 손 조작 | 위쪽 동작 단추는 **최대 2개 + 연결 칩**(= 3개 이하). 선택·확인·옵션은 **아래서 올라오는 시트**(`Sheet`). 위쪽의 "← 뒤로"는 유지하되 안드로이드 뒤로가기와 동일하게 `go_back()` 호출. |
| 둥근 카드 묶음 | 화면 = 회색 바탕(BG) 위에 흰 카드(SURFACE, 반경 24)가 세로로 쌓임. 설정·목록은 **리스트 그룹**(카드 하나 안에 행 여러 개, 행 사이 안쪽 구분선). 카드 사이 12, 섹션 사이 24. |
| 여백·반경·그림자 | 좌우: 카드는 화면 끝에서 16, **글자·단추는 화면 끝에서 24 이상**(카드 안쪽 여백 16 + 바깥 16 = 32, 제목·섹션 머리글은 바깥 16 + 안쪽 8 = 24) — 문서의 "24dp 이상" 해석(추측: 문서가 카드 틀과 글 중 무엇을 가리키는지는 그림에만 있음). 반경: 단추 18, 입력칸 14, 카드 24, 시트 윗모서리 28. 그림자: 카드 없음, 시트·대화상자는 **딤만**(그림자 없음), 토스트·떠 있는 단추만 약한 그림자(§5.6). |
| 다크 모드 | 토큰 두 벌(§5.1). 시작 시 `scheme` 설정(`system`/`light`/`dark`)을 읽어 적용. 다크에서는 검정 대신 아주 짙은 남회색 바탕(#101216)과 단계별 짙은 면. 이미지 없는 앱이라 번쩍임 위험은 하얀 `Color.WHITE` 직접 쓴 곳뿐(mini_chart 막대 흐림, 토스트) → 토큰으로 교체. |
| 글자 크기 | 설정에서 `글자 크기` 5단계(90/100/115/130/150%). 200% 는 **하지 않는다**(레슨·읽기의 고정 폭 부품이 깨질 위험, 150% 에서 겹침 0 을 먼저 보장). |

### 4.2 PC
같은 언어를 넓은 화면(1280×800 기본, 최소 900×600)에 맞춘다. One UI 의 큰 화면 원칙("메뉴를 옆에 계속 보여 주기", "한 번에 더 많은 정보")을 따른다.

| 항목 | 제안 |
|---|---|
| 내비게이션 | 위 탭 줄 폐지 → **왼쪽 사이드 내비**(폭 224, `SideNav`). 위에 "회화 연습" 글자, 섹션 "학습"(오늘·레슨·원어민 대화·연습·읽기·복습), 섹션 "기록"(기록·로드맵), 맨 아래 연결 칩(엔진 상태·"폰 연결 켜짐")과 "설정". 선택은 **옅은 강조색 알약**(글자 굵게). 8개+설정이어도 세로로 들어가므로 "더보기" 메뉴가 사라진다. |
| 콘텐츠 | 사이드 내비 오른쪽에 `PageHeader`(제목 28 굵게, 부제, 오른쪽에 동작) + 가운데 정렬 컬럼(최대 폭 880; 레슨·대화·연습 하위는 720). 창이 좁으면(<980) 오늘의 2열이 1열로. |
| 입력 | 마우스 우선: 행에 hover 색, 버튼 높이 40, 스위치·체크는 클릭 영역 ≥ 40×40. 키보드: 지금처럼 `FOCUS_NONE` 유지(범위 밖). |
| 오버레이 | 선택·확인 대화상자는 폰에서는 아래 시트, PC 에서는 **가운데 대화상자**(폭 440). 진행·정보는 양쪽 가운데. |
| 확장(선택) | 읽기: 왼쪽 문서 목록 + 오른쪽 읽기 화면 2분할, 복습: 목록 + 상세. 이번 범위는 단일 컬럼 유지(§1.2). |

### 4.3 "한 종류 스타일" 규칙 (버튼)
한 화면 안의 버튼은 **채움(primary) 1개 이하 + 나머지는 tonal(soft) 또는 flat**. 지금 `outline`(2px 테두리)은 "done" 같은 토글 상태에 쓰이므로 호출 이름은 유지하되 모양은 tonal+얇은 테두리로 바꾼다(§6.4).

---

## 5. 디자인 토큰

토큰은 두 파일이 소유한다: **색 = `core\pal.gd`**(이름 유지, 값은 `static var`), **크기·글자·간격·반경 = 새 `ui\ds.gd`**(`class_name Ds`). 둘 다 `tools\make_theme.gd` 가 읽어 테마(.tres)를 만든다.

### 5.1 색

#### 5.1.1 기존 `Pal` 대응표 (이름 유지, 라이트 값은 **그대로**)
| 기존 이름 | 라이트 | 다크 | 용도 / 변경 |
|---|---|---|---|
| `BG` | #F4F5F7 | #101216 | 화면 바탕 |
| `SURFACE` | #FFFFFF | #1B1E24 | 카드·입력칸·탭줄 |
| `SUNK` | #ECEEF2 | #252932 | 눌림·팁 상자·진행 바 트랙·세그먼트 바탕 |
| `INK` | #1A202C | #E8EAEE | 본문 글자 |
| `MUTED` | #5A6373 | #A3AAB8 | 보조 글자(작은 글자 포함, 모든 면 위에서 4.5:1 이상) |
| `LINE` | #DDE1E8 | #343944 | **장식** 구분선(대비 요구 없음) |
| `EN` | #2C56C9 | #8FA8F0 | 영어 강조(글자·채움) |
| `EN_SOFT` | #E7ECFA | #1F2842 | 영어 연한 면 |
| `JA` | #C4412A | #F08C78 | 일본어 강조 |
| `JA_SOFT` | #F8E8E3 | #3A2420 | 일본어 연한 면 |
| `OK` | #23855A | #5FCB96 | **채움·점·테두리**(글자로 쓰면 BG 위 4.21 로 실패) |
| `OK_SOFT` | #E3F3EA | #1C3328 | 정답·성공 면 |
| `BAD` | #B83A3A | #F28B8B | 오류 채움·테두리(글자도 4.69~5.67 로 통과) |
| `BAD_SOFT` | #F9E5E5 | #3A2224 | 오답 면 |
| `WARN` | #9A6A00 | #E3B34A | **채움·점·테두리** |
| `WARN_SOFT` | #FFF3D6 | #382E14 | 경고 면 |

#### 5.1.2 새 토큰
| 새 이름 | 라이트 | 다크 | 용도 |
|---|---|---|---|
| `SURFACE_HI` | #FFFFFF | #23272F | 시트·대화상자·사이드 내비(바탕 위로 한 단계 뜬 면) |
| `LINE_STRONG` | #7C8596 | #6F7888 | **입력칸·선택 칩·스위치 트랙** 같은 상호작용 경계(비텍스트 3:1) |
| `PRIMARY` | (선택 A) #2C56C9 / (B) #0A6BD6 | (A) #8FA8F0 / (B) #7DB4FF | 언어와 무관한 강조(링크·선택·스위치 켜짐·주요 버튼). **A 이면 `EN` 과 같은 값** |
| `PRIMARY_SOFT` | (A) #E7ECFA / (B) #E8F1FC | (A) #1F2842 / (B) #12263F | 선택된 항목 배경(사이드 내비 알약, 선택 칩) |
| `ON_ACCENT` | #FFFFFF | #101216 | **채운 버튼 위 글자**(다크에서는 어두운 글자가 대비 7~9:1) |
| `EN_ON` | = `EN` | = `EN` | 연한 면 위 글자(영어) |
| `JA_ON` | #A8351F | #F08C78 | 연한 면·BG 위 글자(일본어). `JA` 는 SOFT 위 4.27 로 실패 |
| `OK_ON` | #1B6B49 | #5FCB96 | **정답·성공 글자 전부** (OK_SOFT 5.63, BG 5.93, 흰 6.47) |
| `WARN_ON` | #7F5700 | #E3B34A | **경고 글자 전부** (WARN_SOFT 5.83, BG 5.89) |
| `BAD_ON` | = `BAD` | = `BAD` | 오류 글자 |
| `DIM` | Color(0,0,0,0.32) | Color(0,0,0,0.55) | 시트·대화상자 뒤 딤 |
| `TOAST_BG` / `TOAST_FG` | #222A38 / #FFFFFF | #2E333C / #F2F3F5 | 토스트 (ok = #1D6B49, error = #8F2D2D 로 바탕만 바꾸고 글자는 `TOAST_FG`; 세 바탕 모두 흰 글자 6.46~14.42:1) |

규칙: **글자에는 `*_ON` 과 `INK/MUTED/PRIMARY` 만, 채움·점·진행 바·테두리에는 `OK/WARN/BAD/EN/JA`.** 채운 면 위 글자는 `ON_ACCENT`. 직접 `Color("#…")` 쓰기 금지(예외 없음).

#### 5.1.3 점수 색 (`ScorePanel.score_color`)
`>=80 → OK`, `>=60 → WARN`, 그 외 `BAD`(임계값 유지). 큰 숫자(40px)는 색 채움이라 3:1 로 충분하지만 **작은 라벨은 `*_ON`**. 색만으로 구분하지 않는다: 점수 옆에 판정 문장(`verdict`: "원어민이 바로 알아들어요/대체로 알아들어요/잘 전달되지 않았어요")이 이미 있고, 단어 칩에서 **놓친 단어는 굵은 테두리 2px(BAD) + 굵은 글자**, 잘한 단어는 테두리 없음으로 모양도 다르게 한다. 미션 별점 `★☆` 은 그대로.

#### 5.1.4 다크 모드 적용 방식
- 설정 키(기기별, **동기화하지 않는다** — `docs\sync_design.md` 의 공유 설정 6개에 넣지 않음): `scheme` ∈ `"system"|"light"|"dark"`(기본 `"system"`), `font_scale` ∈ `0.9|1.0|1.15|1.3|1.5`(기본 `1.0`). 잘못된 값은 읽을 때 기본값으로 되돌린다(`"purple"` → `"system"`, `9.0` → `1.5` 로 가장 가까운 허용값, 숫자가 아님 → `1.0`).
- `Pal.use(scheme: String) -> void`("light"|"dark"), `Pal.scheme() -> String`, `Pal.is_dark() -> bool`, `Pal.resolve(pref: String) -> String`(`"system"` 이면 `DisplayServer.is_dark_mode_supported() and DisplayServer.is_dark_mode()` 로 정함; 지원 안 하면 `"light"`. Android 에서 지원 여부는 **(추측) 4.6 에서 지원 → 실기기 확인 필요**, 확인 전 기본값 `system` 은 사실상 라이트).
- `UiBoot.apply(root: Window, scheme_pref: String, font_scale: float) -> String`(새 `ui\ui_boot.gd`): ① `Pal.use(resolve)` ② `theme\app_theme.tres` 또는 `theme\app_theme_dark.tres` 로드(없거나 깨지면 라이트로 대체하고 `push_error`, 앱은 계속) ③ `PhoneLayout.apply_theme`(폰 보정, 테마마다 한 번) ④ 글자 크기 배율 적용(`Ds.set_font_scale`, 테마의 글자 크기를 `Ds` 표 × 배율로 **재계산**, 멱등) ⑤ `ThemeIcons.apply(theme)`(§5.8) ⑥ `root.theme = theme`(`Window.theme` 존재 확인됨). 돌려주는 값 = 적용된 `"light"|"dark"`.
- **v1 은 시작할 때 한 번 적용**한다. 코드로 만든 UI(`UI.style(Pal.X, …)`)가 만들 때 색을 붙잡기 때문에 즉시 전환하면 모든 화면을 다시 만들어야 한다. 설정에서 바꾸면 토스트 "다시 열면 적용돼요"(폰) / "앱을 다시 시작하면 적용돼요"(PC). 즉시 전환(`reload_current_scene` 또는 모든 뷰 재생성)은 상태 손실·`Backend.start()` 재호출 위험이 있어 **후속 과제**.

#### 5.1.5 강조색 후보 (사용자가 고른다)
`PRIMARY` 는 한 줄로 바뀐다(`Pal` 두 값). 둘 다 흰 글자(채움)·본문(링크) 4.5:1 통과.
| 후보 | 라이트 | 대비 | 다크 | 대비 | 비고 |
|---|---|---|---|---|---|
| **A. 지금 파랑 유지**(영어 파랑과 같은 값) | #2C56C9 | 흰 6.40, BG 5.87, EN_SOFT 5.42 | #8FA8F0 | 면 7.18 | 변경 최소, 영어 화면 색 변화 없음 |
| **B. 더 밝은 파랑** | #0A6BD6 | 흰 5.14, BG 4.71, 연한 면 4.51(경계) | #7DB4FF | 면 7.83 | One UI 풍(밝은 파랑). `EN` 도 같이 바꾸면 영어 화면 전체가 밝아짐 |
| C. 청록 | #0F766E | 흰 5.47, 연한 면 4.81 | (다크 값은 W1 에서 계산) | - | 영어(파랑)·일본어(빨강)와 겹치지 않음 |
- 추천: **B 를 W1 에서 둘 다 만들어 스크린샷으로 비교한 뒤 확정**(코드 변경은 값 두 줄). 비교 없이 정해야 하면 A(영어 색이 곧 앱 색이 되어 학습 언어 색 규칙이 흐려지지 않음 — 일본어=빨강/영어=파랑을 해치지 않는 쪽).

#### 5.1.6 대비 계산식과 합격 표 (시험이 쓴다)
상대 휘도 `L = 0.2126 R + 0.7152 G + 0.0722 B`(각 채널 sRGB 선형화: `c/12.92` 또는 `((c+0.055)/1.055)^2.4`), 대비 `= (L밝 + 0.05) / (L어두 + 0.05)`.
`tests\contrast_test.gd` 가 **라이트·다크 각각** `Pal.use(…)` 후 아래 쌍을 검사한다(최소 대비): 
- 글자 4.5: `INK/BG, INK/SURFACE, INK/SURFACE_HI, INK/SUNK, MUTED/BG, MUTED/SURFACE, MUTED/SUNK, MUTED/SURFACE_HI, MUTED/PRIMARY_SOFT, PRIMARY/SURFACE, PRIMARY/BG, PRIMARY/PRIMARY_SOFT, EN/SURFACE, EN_ON/EN_SOFT, JA/SURFACE, JA_ON/JA_SOFT, JA_ON/BG, OK_ON/OK_SOFT, OK_ON/BG, OK_ON/SURFACE, WARN_ON/WARN_SOFT, WARN_ON/BG, WARN_ON/SURFACE, BAD_ON/BAD_SOFT, BAD_ON/SURFACE, BAD_ON/BG, ON_ACCENT/PRIMARY, ON_ACCENT/EN, ON_ACCENT/JA, ON_ACCENT/OK, ON_ACCENT/BAD, TOAST_FG/TOAST_BG(+ok·error 바탕)`.
- 비텍스트 3.0: `LINE_STRONG/SURFACE, LINE_STRONG/BG, LINE_STRONG/SUNK, OK/SURFACE, BAD/SURFACE, WARN/SURFACE, PRIMARY/SURFACE`(점·진행 바·테두리).
- 자체 점검(틀린 입력): 검사기에 `#777777/#FFFFFF`(4.48 → **FAIL 로 보고돼야 함**)와 `#767676/#FFFFFF`(4.54 → PASS)를 넣어 판정이 갈리는지 확인. 현재(기존) 팔레트의 `JA/JA_SOFT 4.27` 이 같은 코드에서 FAIL 로 잡히는지도 한 줄 확인(기존 값 표를 `LEGACY` 로 테스트에 둠).
- 이 문서가 §5.1 에서 쓴 대비 수치는 Python 으로 직접 계산한 값이다(예: `#A8351F on #F8E8E3 = 5.52`, `#7C8596 on #FFFFFF = 3.72`). 다크 SOFT 면 값(예 `#3A2420`)은 **제안값**이라 W1 이 바꿀 수 있으나 위 합격 표는 통과해야 한다.

### 5.2 글자 크기 (`Ds.type`)
테마 변형 이름은 **전부 유지**(화면 코드 변경 없음). 크기는 `Ds` 표에서 읽고 `font_scale` 배율을 곱한다(`Ds.fs(n) = max(12, round(n * font_scale))`).
| 변형 | PC | 폰 | 용도 / 비고 |
|---|---|---|---|
| `Big` | 34 굵게 | 34 | "D-30", "38일째" 같은 큰 숫자(Display) |
| `Score` | 40 굵게 | 40 | 점수 |
| `LargeTitle`(**새**) | - | 32 굵게 | 폰 `PageHeader` 제목(접히는 큰 제목) |
| `H1` | 28 | 30 | PC `PageHeader` 제목 |
| `AppBarTitle`(**새**) | - | 20 굵게 | 접힌 앱 바 제목 |
| `H2` | 21 | 22 | 카드 제목 |
| `H3` | 17 | 18 | 카드 안 소제목 |
| 기본 / `Strong`(굵게) | 16 | 17 | 본문 |
| `Muted` | 15 | 16 | 보조 설명 |
| `Small` | 13 | 14 | 캡션, 입력칸 라벨 |
| `Eyebrow` | 12 굵게 | 13 굵게 | 카드 위 작은 머리글 |
| `SectionHeader`(**새**) | 14 굵게 `PRIMARY` | 15 굵게 | 리스트 그룹 머리글(One UI 소제목) |
| `ListMain` / `ListSub`(**새**) | 16 / 13 | 17 / 14 | 리스트 행 주 글 / 부연(`Strong`·`Small` 과 같은 값이라 별칭) |
- 줄 간격: `Label` 상수 `line_spacing` +2(폰 +3), `RichTextLabel` `line_separation` 동일. 한국어 여러 줄 본문의 숨통(시각 조정은 W1 스크린샷으로 확인, 값은 바뀔 수 있음).
- 글꼴: **지금 방식 유지** — `SystemFont`(Malgun Gothic → Yu Gothic UI → Meiryo → Segoe UI, Android 는 Roboto → Noto Sans CJK KR → … → sans-serif). 새 글꼴 파일을 넣지 않는다. 일본어는 `UI.fix_cjk` 유지. Samsung 기기에서 한글이 어떤 글꼴로 보이는지는 시스템 대체(**실기기 미확인**).
- 고정 글자 크기 41곳(`add_theme_font_size_override`, reading 8, ui 5, score_panel 4 …)과 `draw_string` 18곳(mini_chart, prosody_panel)은 `Ds.fs(n)` 으로 감싸야 글자 크기 설정에 반응한다 → 파일 소유 작업자가 각자 처리(W2 `ui.gd`, W6 `score_panel/mini_chart/prosody_panel`, W7~W11 각 화면).

### 5.3 간격·반경·높이 (`Ds`) — 단위는 **논리 px**
1 논리 px ≈ 1dp 로 쓴다(폰 기준 폭 412, `project.godot` Android: `canvas_items` + `expand`). **(추측)** 폭이 412dp 보다 좁은 기기(예 360dp)에서는 1 논리 px 가 0.87dp 라 48px 이 42dp 가 된다. 그래서 `PhoneLayout.dp_scale()`(논리 px per dp = `(DisplayServer.screen_get_dpi()/160) / PhoneLayout._px_per_logical()`, 데스크톱 시험에서는 1.0)을 두고 **`Ds.touch_min() = clamp(48 / dp_scale, 48, 60)`** 으로 쓴다. W1 에서 실기기 진단 한 줄(`print(screen_get_size, get_visible_rect, screen_get_dpi)`)을 `UiBoot` 디버그 출력으로 남겨 확인한다.

| 토큰 | 값 | 비고 |
|---|---|---|
| 간격 `S1..S10` | 4, 8, 12, 16, 20, 24, 32, 40 | 카드 사이 폰 12 / PC 16, 섹션 사이 24, 카드 안쪽 폰 16 / PC 20 |
| 페이지 좌우 | 폰 16(`PhoneLayout.PAD`), PC 컬럼 가운데 | 글자는 화면 끝에서 ≥24(카드 16+8 또는 카드 안쪽 16) |
| 반경 | `R_XS` 6, `R_S` 12(옵션 행), `R_INPUT` 14, `R_BTN` 18, `R_CARD` 24, `R_SHEET` 28(윗모서리만), `R_PILL` 99 | 단추 18 = 문서 숫자. 나머지는 이 앱 값 |
| 터치 최소 | `touch_min()` = 48(좁은 폰은 최대 60) | 누를 수 있는 모든 컨트롤의 **히트 영역**(`get_global_rect`) 가로·세로 ≥ 이 값. 한 줄 글 링크(`link_button`)는 가로가 글자 폭이어도 세로 48 |
| 버튼 높이 | 폰 48 / PC 40, 큰 CTA(`primary` 시작 버튼, 녹음) 56 | `UI.button` 의 `min_h` 가 이보다 작으면 올림 |
| 입력칸 높이 | 폰 48 / PC 40 | 테두리 `LINE_STRONG` 1.5px, 포커스 `PRIMARY` 2px, 플레이스홀더 `MUTED`(불투명, 지금 알파 0.7 은 대비 부족) |
| 리스트 행 | 한 줄 56 / 두 줄 72(폰·PC 동일, PC 는 48/64 허용) | 안쪽 구분선 왼쪽 16 들여쓰기 |
| 칩 | 표시용 높이 28(글자 13 굵게), 누르는 칩 폰 40(+위아래 투명 여백으로 히트 48) / PC 32 | `UI.chip` 는 표시용 |
| 하단 탭 | 56 + 아래 inset | 칸 최소 48×56, 글자 14(큰 글자에서 16) |
| 앱 바 | 접힌 56 + 위 inset, 큰 제목 블록 최소 112 | 높이 고정(§4.1) |
| 사이드 내비 | 폭 224, 항목 44, 섹션 머리글 28 | PC |
| 시트 | 윗모서리 28, 손잡이 36×4(선택), 최대 높이 화면의 70%, 버튼 줄 56 | 키보드 높이만큼 위로 |
| 스위치 | 트랙 52×32, 행 56 → 히트 ≥48×48 | `CheckButton` + `ThemeIcons` |
| 녹음 버튼 | 폰 가득 폭 56 / PC 큰 `Vector2(190,58)`·작은 `Vector2(96,44)`(**변경 금지**, §3.3) | |

### 5.4 그림자·딤·깊이
- 카드는 **그림자 없음**, 윤곽: 폰 없음(회색 바탕 대비로 구분), PC 1px `LINE` 헤어라인(흰 면이 넓어서) — 최종은 W2 스크린샷 후 오케스트레이터가 확정.
- **시트·대화상자 = 딤만**(`DIM`, 그림자 없음). **토스트·스낵바·떠 있는 단추 = 약한 그림자만**(`shadow_size 8, offset (0,2), color 알파 0.14`; 다크에서는 그림자 없이 `SURFACE_HI` 로 구분). 한 요소에 둘을 같이 쓰지 않는다. 블러는 쓰지 않는다(Godot 에서 비용 큼).
- 오버레이 순서(CanvasLayer): 더보기/시트 16, 스플래시 20, 연결 화면 25, 토스트 30 — **유지**(새 `Sheet` 는 16, 확인 대화상자도 16).

### 5.5 모션
- 기본 곡선: `Tween.TRANS_QUINT` + `EASE_OUT`(One UI 기본 곡선과 같은 "빨리 시작해 천천히 멈춤" 계열의 근사). 길이: 스위치 160ms, 탭 선택 120ms, 시트 열림 280ms·닫힘 200ms, 토스트 150/400ms(지금 값 유지). **100ms 미만·500ms 초과 금지**. 큰 제목↔앱 바 제목은 스크롤 값에 직접 연결(트윈 없음). 폰 단말의 "애니메이션 끄기" 설정은 읽지 않는다(후속).

### 5.6 아이콘 방침
- 지금: 이미지 아이콘은 SVG 4개(직접 그린 도형), 나머지는 글자 도형. **외부 아이콘 세트·폰트·삼성 아이콘을 쓰지 않는다**(§2.3).
- 새 규칙: ① 하단 탭·사이드 내비는 **글자만**(문서 하단 탭 규칙과 같다). ② 새 부품에 필요한 단순 도형(뒤로 `<`, 쉐브론 `v ^ >`, 체크, 닫기 `x`, 재생 `▶`, 녹음 `●`, 더보기 `⋯`)은 `GlyphIcon`(새 `ui\glyph.gd`, `Control._draw` 로 `draw_polyline`/`draw_polygon`/`draw_circle`)으로 직접 그린다. 글자 도형은 글꼴마다 크기·모양이 달라(Android 에서 이모지로 바뀔 위험) 새 곳에는 쓰지 않는다. ③ **기존 라벨의 글자 도형(`▶ 듣기`, `다음 ▶`, `← 연습`, `▾`)은 문자열을 바꾸지 않는다**(시험이 `_has_button(main, "붙여넣기")` 처럼 텍스트로 찾음) — 별도 승인 전까지 유지. ④ 아이콘만 있는 컨트롤에는 `accessibility_name` 을 단다(속성 존재 확인됨; 실제 낭독 여부 **미검증**). ⑤ 스위치·체크 이미지는 `ThemeIcons`(새 `ui\theme_icons.gd`)가 **SVG 문자열 + 현재 `Pal` 색**으로 만들어 `Image.load_svg_from_string(svg, 2.0)` → `ImageTexture` 로 테마에 넣는다(임포트 단계 없음, 다크 대응, 동작 확인됨). 기존 `theme\*.svg` 4개는 W2 이후 미사용이 되면 삭제하지 말고 오케스트레이터에게 보고.

---

## 6. 컴포넌트 사양

공통: 모든 부품은 **테마 변형 + `UI` 헬퍼**로 만든다(색·크기를 부품 안에 하드코딩하지 않음 → 동기화 `SyncPanel`, 폰 단독 모드 패널이 같은 헬퍼를 쓰면 자동으로 새 모습). 폰/PC 분기는 `Platform.is_phone()` 만(플랫폼 판정은 `platform.gd` 한 곳, 기존 규칙).

### 6.1 한눈에 보기
| # | 부품 | 파일(새/변경) | 폰 | PC | 담당 |
|---|---|---|---|---|---|
| 1 | 앱 바 `AppBar` | 새 `ui\app_bar.gd` | 접힌 바 56 + 연결 칩 | 쓰지 않음 | W3 |
| 2 | 큰 제목 헤더 `PageHeader` | 새 `ui\page_header.gd` | 제목 블록(접힘 대상) | 제목 줄 + 동작 | W3 |
| 3 | 카드/리스트 그룹 `ListGroup`, `SectionHeader` | 새 `ui\list_group.gd`, 변경 `ui\card_box.gd`, `ui.gd` | 반경 24 | 반경 24 + 헤어라인 | W2 |
| 4 | 버튼 | 변경 `ui.gd` `button/style_button/link_button/tile/option_row` | 48 | 40 | W2 |
| 5 | 칩 | 변경 `ui.gd` `chip` + 새 `UI.filter_chip` | 표시 28 / 선택 40(히트 48) | 28 / 32 | W2 |
| 6 | 입력칸 | 테마(`LineEdit/TextEdit`), `ui.gd` `field` | 48 | 40 | W1·W2 |
| 7 | 스위치·체크 | 새 `ui\theme_icons.gd`, 변경 `ui.gd` `pref_toggle/check_row` + 새 `UI.switch_row` | 행 56 | 행 52 | W1·W2 |
| 8 | 대화상자·바텀시트 `Sheet` | 새 `ui\sheet.gd` | 아래 시트 | 가운데 대화상자 | W3 |
| 9 | 토스트·스낵바 `ToastHost` | 새 `ui\toast_host.gd`, 변경 `autoload\toast.gd`(`snack` 신호 추가) | 탭 위, 폭 화면-32 | 아래 가운데 폭 ≤ 420 | W3 |
| 10 | 진행 표시 | 변경 `ui.gd` `progress_bar` + 테마 | 높이 10 | 높이 10 | W2 |
| 11 | 하단 탭 `BottomTabs` | 변경 `ui\bottom_tabs.gd` | 5칸 | 쓰지 않음 | W3 |
| 12 | 사이드 내비 `SideNav` | 새 `ui\side_nav.gd` | 쓰지 않음 | 폭 224 | W3 |
| 13 | 연결 칩 `ConnChip` | 새 `ui\conn_chip.gd` | 앱 바 오른쪽 | 사이드 내비 아래 | W3 |
| 14 | 녹음 버튼 | 변경 `ui\recorder_widget.gd` | 가득 폭 56 | 190×58 / 96×44 | W6 |
| 15 | 점수 패널 | 변경 `ui\score_panel.gd`, `prosody_panel.gd`, `mini_chart.gd` | | | W6 |

### 6.2 `Ds`·`Pal`·`UiBoot`·`ThemeIcons`·`GlyphIcon` (W1) — 계약
```gdscript
# core/pal.gd  (class_name Pal)  — 이름 유지, const -> static var
static var BG: Color      # ... 기존 16개 + 새 토큰 (SURFACE_HI, LINE_STRONG, PRIMARY, PRIMARY_SOFT, ON_ACCENT,
                          #     EN_ON, JA_ON, OK_ON, WARN_ON, BAD_ON, DIM, TOAST_BG, TOAST_FG)
static func use(scheme: String) -> void      # "light"|"dark"; 그 밖의 값은 "light" 로 + push_warning
static func scheme() -> String
static func is_dark() -> bool
static func resolve(pref: String) -> String  # "system"|"light"|"dark" -> "light"|"dark"
static func accent(lang: String) -> Color    # 기존 유지
static func soft(lang: String) -> Color      # 기존 유지
static func on(lang: String) -> Color        # 새: 연한 면 위 글자 (JA_ON | EN_ON)

# ui/ds.gd  (class_name Ds)
static var font_scale: float = 1.0
static func set_font_scale(f: float) -> void           # 허용 {0.9,1.0,1.15,1.3,1.5} 중 가장 가까운 값, NaN·비숫자 -> 1.0
static func fs(n: int) -> int                           # max(12, round(n * font_scale))
static func touch_min() -> float                        # 폰 48..60(dp 환산), PC 40
static func btn_h() -> float                            # 폰 touch_min, PC 40
static func field_h() -> float
const R_XS := 6; const R_S := 12; const R_INPUT := 14; const R_BTN := 18; const R_CARD := 24; const R_SHEET := 28; const R_PILL := 99
const S1 := 4; const S2 := 8; const S3 := 12; const S4 := 16; const S5 := 20; const S6 := 24; const S8 := 32; const S10 := 40
const REC_BIG_PC := Vector2(190, 58); const REC_SMALL_PC := Vector2(96, 44)
static func type_size(variation: String) -> int         # §5.2 표(폰/PC 분기 포함, font_scale 적용 전 기본값)

# ui/ui_boot.gd (class_name UiBoot)
static func apply(root: Window, scheme_pref: String, font_scale: float) -> String   # §5.1.4

# ui/theme_icons.gd
static func apply(theme: Theme) -> void   # CheckButton checked/unchecked(+_disabled), CheckBox checked/unchecked, HSlider grabber, OptionButton arrow

# ui/glyph.gd
class_name GlyphIcon extends Control
func _init(kind: String = "chevron_right", size: float = 20.0, color: Color = Pal.INK)
# kind ∈ "back"|"chevron_down"|"chevron_up"|"chevron_right"|"check"|"close"|"play"|"record"|"more"; 모르는 kind -> 빈 칸(오류 없음)
# custom_minimum_size == Vector2(size, size); mouse_filter = IGNORE
```
`PhoneLayout`(W1 변경 범위): 상수 `BTN_H`, `LINK_H`, `TAB_H`, `PAD`, `TOP_H` 는 이름 유지(다른 곳이 참조), `BTN_H`·`LINK_H` 는 **`Ds.touch_min()` 과 같은 값 48**(링크 44 → 48). `font_bump`/`apply_theme` 는 **테마마다 한 번**(지금 전역 bool `_theme_done` 은 두 테마를 못 다룸 → 테마 `set_meta("phone_done", true)` 로 바꾼다). 글자 크기는 `Ds.type_size` 표로 대체(`font_bump` 의 하드코딩 제거).

### 6.3 앱 바 `AppBar`, 큰 제목 `PageHeader` (W3)
```gdscript
# ui/app_bar.gd — 폰 전용, main 이 PanelContainer 로 한 개 둔다
class_name AppBar extends PanelContainer
signal back_pressed
signal action_pressed(id: String)
signal chip_pressed
func set_top_inset(px: float) -> void
func set_page(title: String, back: bool = false, actions: Array = []) -> void
    # actions = [{"id": String, "text": String}] 최대 2개(3개 이상은 앞의 2개만 쓰고 push_warning)
func bind_scroll(sc: ScrollContainer, header: Control) -> void   # sc.get_v_scroll_bar().value_changed 를 듣고 제목 알파 갱신, 헤어라인 알파 = scroll>0
func set_chip(c: Control) -> void                                # ConnChip 을 오른쪽에 둔다
static func collapse_t(scroll_y: float, header_h: float) -> float
    # t = clamp((scroll_y - 0.5*header_h) / (0.5*header_h), 0, 1); header_h <= 0 또는 NaN 이면 1.0, scroll_y NaN·음수(오버스크롤)이면 0.0
# ui/page_header.gd
class_name PageHeader
static func build(title: String, subtitle: String = "", actions: Array = []) -> Control
    # 폰: VBox(min 높이 112): LargeTitle(최대 2줄, 넘으면 말줄임) + Muted 부제. 위쪽 inset 은 앱 바가 책임. 터치 요소 없음(mouse_filter PASS).
    # PC: HBox: [VBox(H1 제목, Muted 부제)] [spacer] [동작 버튼들]
static func height() -> float                                    # 폰 112, PC 72
```
- 앱 바 구조: `[뒤로 48×48 GlyphIcon("back")]` `[제목(AppBarTitle, 알파=collapse_t, 한 줄 말줄임)]` `[spacer]` `[동작 ≤2]` `[ConnChip]`. 높이 `56 + top_inset`. 바 배경 `BG`, 아래 헤어인(`LINE`)은 스크롤>0 일 때만 보임. 동작 단추는 flat 버튼(글자 "설정" 등; 아이콘 안 씀 — One UI 도 "아이콘으로 표현하기 어려운 기능은 글자 버튼").
- 터치 스크롤과의 관계: 앱 바는 ScrollContainer **밖**이고(높이 고정이라 페이지 크기 되먹임 없음), `PageHeader` 는 스크롤 **안**의 첫 항목이라 손가락이 제목 위에서 시작해도 `PASS` 라 스크롤된다.
- 하위 화면(연습 4종 등): `AppView` 가 `page_title()` 에 하위 화면 제목을 돌려주면 앱 바에 뒤로 버튼이 켜진다(`go_back()` 와 연결). `SpeakDrill.build_shell` 의 자체 헤더(← · 제목 · 쪽수)는 **폰에서는 앱 바로 흡수**하고 쪽수만 부제에 둔다(W6·W11).
- `AppView` 계약 추가(W3, `views\app_view.gd` 소유; 기본 구현은 아무것도 안 함 → 기존 화면은 그대로 동작):
```gdscript
signal bar_changed                         # 제목·뒤로·동작이 바뀌었을 때 화면이 보냄
func page_title() -> String: return ""     # "" 이면 main 이 탭 이름을 씀
func page_subtitle() -> String: return ""
func page_actions() -> Array: return []    # [{"id","text"}]
func on_action(id: String) -> void: pass
func scroll_host() -> ScrollContainer: return null   # 앱 바가 bind_scroll 할 대상(없으면 제목은 항상 보임)
func header_block() -> Control: return null          # 큰 제목 블록(없으면 위와 같음)
```

### 6.4 리스트 그룹·카드·버튼·칩·입력칸·스위치 (W2)
**카드** (`UI.card(variation, sep)` 시그니처 유지): `Card`(반경 24, 안쪽 폰 16 / PC 20), `BigCard`(안쪽 폰 16 / PC 24, 큰 안내 카드), `Sunk`(SUNK 면, 반경 18, 팁 상자), 새 `Group`(리스트 그룹, 안쪽 여백 0). 테두리: 폰 없음, PC `LINE` 1px(§5.4). **지금 그림자 없음 유지**.
**리스트 그룹**:
```gdscript
class_name ListGroup extends CardBox        # theme_type_variation = "Group"
func add_row(main: String, sub: String = "", trailing: Control = null, on_tap: Callable = Callable(), danger: bool = false) -> Control
    # 행: min 높이 56(부연 있으면 72), 왼쪽 안쪽 16, 주 글 ListMain(한 줄, 넘으면 말줄임), 부연 ListSub(Muted), 오른쪽 trailing.
    # on_tap 이 유효하면 UI.on_tap 으로 연결(폰은 손 뗄 때 + 12px 이내), hover/눌림 면 = SUNK. danger 이면 주 글 BAD_ON.
func add_value_row(main: String, value: String, on_tap: Callable) -> Control   # 오른쪽 value(Muted) + GlyphIcon("chevron_right")
func add_switch_row(main: String, sub: String, pref_key: String) -> CheckButton # Store.pref_bool/set_pref 연결(기존 pref_toggle 와 같은 키)
func add_check_row / add_custom(c: Control) -> void    # custom 도 같은 들여쓰기 구분선 규칙
static func header(text: String) -> Label   # SectionHeader 변형, 위 24 아래 8 간격, 왼쪽 8(바깥 16 + 8 = 24)
```
행 사이 구분선은 행 위에 `ColorRect` 1px `LINE`(왼쪽 16 들여쓰기), **마지막 행 아래에는 없음**. 비어 있는 `main`(빈 문자열)은 행을 만들지 않고 `push_warning`(깨지지 않음).
**버튼**(`UI.button(text, kind, accent, min_h)` 시그니처 유지): `kind` = `"primary"`(채움 `accent`, 글자 `ON_ACCENT`, 반경 18, 굵게), `"soft"`(tonal: `accent` 연한 면 → 다크는 SOFT 토큰, 글자 `*_ON`/`accent`), `"outline"`(**호출 이름 유지**, 모양 = soft + 1.5px `accent` 테두리; 한 화면 한 종류 규칙은 호출자 몫), `"flat"`(배경 없음, 글자 `accent`), 새 `"danger"`(채움 `BAD`, 글자 `ON_ACCENT`). 상태: normal / hover(한 단계 밝게·어둡게) / pressed(한 단계 더) / disabled(알파 0.4, 글자 대비 요구 면제 — 사용 불가 상태는 WCAG 면제). 높이는 `max(min_h, Ds.btn_h())`, 폰 큰 CTA 56. `link_button` 은 세로 `Ds.touch_min()`(폰), 글자 15→`Ds.fs`.
**칩**: `UI.chip(text, fg, bg, tip)` 유지(표시용, 반경 pill, 높이 28) — 호출부가 `fg` 에 `Pal.OK` 등을 넘기면 대비 실패가 생기므로 **W2 가 `UI.chip_kind(text, "ok"|"bad"|"warn"|"info"|"lang_en"|"lang_ja"|"neutral")` 를 추가**하고 화면 작업자가 옮긴다. 선택 칩 `UI.filter_chip(text, selected, on_tap)`: 표시 높이 폰 40, 켜짐 = `PRIMARY_SOFT` 면 + `PRIMARY` 2px 테두리 + 굵게(색 + 테두리 두께 + 굵기로 구분).
**입력칸**: 테마 `LineEdit/TextEdit` — 바탕 `SURFACE`, 테두리 `LINE_STRONG` 1.5px, 포커스 `PRIMARY` 2px, 반경 14, 안쪽 가로 14, 플레이스홀더 `MUTED`.
**스위치·체크**: `CheckButton`(스위치, 켜짐 `PRIMARY` 트랙 + 흰 손잡이, 꺼짐 `LINE_STRONG` 트랙, 트랙 52×32, 이미지는 `ThemeIcons`), `CheckBox`(체크리스트·다중 선택 — 이미 쓰는 체크 이미지의 색만 토큰화). 규칙: **켜짐/꺼짐 설정 = 스위치 행, 다중 선택·체크리스트(로드맵 체크, "이번 주 활동 끝냄") = 체크박스**(One UI 도 같음). `UI.pref_toggle`(CheckBox 반환)은 유지하고 새 `UI.pref_switch(text, key)`(CheckButton 반환)를 추가; 화면 작업자가 설정·대화 옵션 등을 옮긴다. 둘 다 `BaseButton` 이라 `touch_scroll_test` 의 `CheckBox or CheckButton` 처리에 해당.
**진행 표시**: `UI.progress_bar(value, color, height)` 유지 — 트랙 `SUNK`, 채움 `color`, 반경 pill, 기본 높이 10(폰·PC). 불확정 진행(스플래시): 같은 스타일 + `indeterminate`. 값 표시는 옆 글자(`3/5`)와 함께(색만으로 상태를 말하지 않음).
**스타일 캐시**: 지금 `UI.button` 한 개가 `StyleBoxFlat` 6개를 만든다. 복습 목록 수백 행에서 부담이므로 `UI._cache`(키 = `kind|accent|scheme|scale`)로 **버튼 스타일 세트를 공유**한다. 단 `UI.style()` 가 돌려준 객체를 호출부가 고쳐 쓰는 곳(`segmented` 의 그림자, `paint_option` 의 `border_width_bottom`)이 있어 **캐시는 `UI.button`/`style_button` 전용**, `UI.style()` 자체는 새 객체를 계속 만든다.

### 6.5 대화상자·바텀시트 `Sheet` (W3)
```gdscript
class_name Sheet extends Control            # CanvasLayer(16) 안의 전체 화면 루트(STOP)
signal closed(result: Variant)              # 버튼 id 문자열, 선택 값, 닫힘이면 "dismiss"
static func open(host: Node, title: String, body: Control, buttons: Array = [], opts: Dictionary = {}) -> Sheet
    # buttons = [{"id": "ok", "text": "지우기", "kind": "danger"|"primary"|"soft"|"flat"}]
    # opts = {"mode": "auto"|"bottom"|"center", "dismissable": true, "max_h_frac": 0.7}
    # auto: 폰 -> "bottom", PC -> "center". 진행·정보 대화상자는 호출자가 "center" 를 준다.
static func confirm(host: Node, title: String, message: String, ok_text: String = "확인", danger: bool = false, cancel_text: String = "취소") -> Sheet
static func choice(host: Node, title: String, items: Array, current: String = "") -> Sheet     # items = [[value, label], ...], closed(value)
static func is_open() -> bool
static func close_top(result: Variant = "dismiss") -> bool       # 열려 있으면 닫고 true. main.handle_back 이 가장 먼저 호출
```
- 모양: 딤(`DIM`, 탭하면 `dismissable` 일 때 닫힘) + 패널(`SURFACE_HI`, 폰: 아래 붙음·윗모서리 `R_SHEET`·폭 화면 전체, PC: 가운데·폭 440·반경 `R_CARD`). 내용: 손잡이(폰), 제목(`H2`), 본문(스크롤 가능, 최대 높이 `max_h_frac`), 버튼 줄(폰: 버튼들을 세로로 가득 폭, 확인이 맨 위·flat 취소가 아래 / PC: 오른쪽 정렬 가로). 키보드 높이 > 0 이면 패널 아래 여백 = 키보드 높이(`PhoneLayout.keyboard_height()`).
- 동시에 여러 개: 위에 쌓이되(스택) `close_top()` 은 맨 위만 닫는다. 같은 `host` 에서 빠르게 두 번 `open` 해도 오류 없이 스택 2개.
- 터치 스크롤: 시트 본문 `ScrollContainer` 는 `node_added` 훅 대상이라 그대로 동작. 딤은 `STOP`(아래 페이지 스크롤·탭 차단).
- 기존 대체: `BottomTabs` 의 "더보기" 시트(`open_more`)를 `Sheet.choice` 모양으로 맞추되 **`open_more/close_more/is_more_open` 이름·동작 유지**(shots·`handle_back` 사용). 설정의 "모든 기록 지우기"(확인 줄)는 `Sheet.confirm(danger=true)` 로 바꾼다(W5).

### 6.6 토스트·스낵바 `ToastHost` (W3)
```gdscript
# ui/toast_host.gd
class_name ToastHost extends CanvasLayer     # layer 30
var box: PanelContainer                       # 기존 main._toast_box 와 같은 역할(시험이 .visible 을 끔)
func set_bottom_gap(px: float) -> void        # 폰: 12 + (키보드 | 탭줄 높이+inset)
func show_message(text: String, kind: String, action_text: String = "", action: Callable = Callable()) -> void
# autoload/toast.gd (W3 소유): 기존 info/ok/error 유지 + signal snack(text, action_text, action: Callable); func snack(text, action_text, cb)
```
- 규칙: 본문 최대 **3줄**(`Label.max_lines_visible = 3` + 말줄임), 폭 폰 `화면-32`(최대 420) / PC 420. 종류별 바탕: info `TOAST_BG`, ok `#1D6B49`, error `#8F2D2D`(글자 `TOAST_FG`), **오류는 글자 앞에 "! "(굵게)** 를 붙여 색만으로 구분하지 않음(시험이 `Toast.message` 텍스트를 보므로 **신호로 나가는 텍스트는 그대로**, 표시할 때만 접두어를 붙인다). 표시 시간: info·ok 3.5초, error·동작이 있는 스낵바 6초(이미 6초). 동작 단추는 오른쪽 flat 버튼(`ON_ACCENT` 반대색), 눌러도 스크롤 방해 없음(토스트는 `mouse_filter=IGNORE`, 동작 단추만 STOP).
- 위치: 폰 = 하단 탭줄 위 12(키보드가 떠 있으면 키보드 위 12), PC = 아래 가운데 28. 선택을 요구하거나 경고할 때는 토스트가 아니라 `Sheet`(원칙: "선택·심각한 경고는 팝업").

### 6.7 하단 탭 `BottomTabs`, 사이드 내비 `SideNav`, 연결 칩 `ConnChip` (W3)
**BottomTabs** — API 이름 전부 유지(`set_tabs, set_current, tab_selected, more_toggled, overflow_keys, direct_keys, cell_buttons, is_more_open, toggle_more, open_more, close_more, set_bottom_inset, set_side_inset`) + `var max_direct: int = 6`(W3 는 6 유지로 시험 무변경; **W4 가 5 로 바꿈**). 모양: 위 3px 선택선 폐지 → 배경 `SURFACE`, 위 헤어라인, 선택 칸 = 글자 `PRIMARY` 굵게 + 글자 아래 20×3 알약 표시(색 + 굵기 + 표시 세 가지 단서), 비선택 `MUTED`. 칸 최소 48×56, 글자 `Ds.fs(14)`. 더보기 칸은 선택 탭이 더보기 안에 있으면 선택 모양. **글자만**(아이콘 없음). 점 배지: `set_badge(key, on: bool)` — 복습 기한 알림용(선택, W4 에서 `Store.due_count` 연결 여부 결정, 기본 끔).
**SideNav**(PC):
```gdscript
class_name SideNav extends PanelContainer
signal item_selected(key: String)
func set_items(sections: Array) -> void   # [{"title": "학습", "items": [[key, label], ...]}, ...]  title "" 이면 머리글 없음
func set_current(key: String) -> void
func set_footer(c: Control) -> void       # ConnChip·폰 연결 칩이 들어가는 아래 영역
func set_settings_visible(v: bool) -> void
```
폭 224 고정(`custom_minimum_size.x`), 바탕 `SURFACE_HI`, 오른쪽 헤어라인. 항목 높이 44, 반경 14, 왼쪽 안쪽 16; hover = `SUNK`, 선택 = `PRIMARY_SOFT` 면 + 글자 `PRIMARY` 굵게. 앱 이름 "회화 연습"은 `H3`(로고 없음).
**ConnChip**:
```gdscript
class_name ConnChip extends PanelContainer
signal tapped
func set_state(kind: String, text: String) -> void   # kind ∈ "ok"|"warn"|"bad"|"idle"; 점(색) + 글자(항상 보임, 색만으로 말하지 않음)
```
칩은 상태 판단을 하지 않는다(문구·kind 는 `main._on_backend_status` 가 정함 → **폰 단독 모드 작업이 문구만 바꾸면 이 칩은 그대로**). 누르면 `tapped`(폰: 설정의 연결 항목 열기, PC: 설정). 높이 28, 글자 `Small`, 점 8px(`OK/WARN/BAD/MUTED` 채움).

### 6.8 녹음 버튼·점수 패널 (W6)
- **녹음 버튼**(`RecorderWidget`): 상태 3가지를 **글자·모양·색**으로 모두 구분 — 대기: 채움 `accent` + `●` + "녹음 시작"(지금 `idle_text`), 녹음 중: `BAD` 채움 + "녹음 중 · 눌러서 끝내기"(폰) / "● 녹음 중" 등 글자가 바뀜 + 타이머·레벨 바(`OK` 채움, 트랙 `SUNK`), 처리 중(`_enabled=false`): disabled 모양 + 글자 "채점 중…". 누름 방식은 **그대로**(눌러서 시작, 0.45초 이상 누르면 떼서 끝/짧게 누르면 토글, 스페이스바는 PC 만). 크기: 폰 가득 폭 56, PC 큰 190×58 / 작은 96×44(§3.3 시험 때문에 고정).
- **점수 패널**(`ScorePanel`): 큰 숫자 `Score`(점수 색), 판정 문장 `*_ON`, 3개 점수 타일(정확도·또렷함·유창성)은 `PRIMARY_SOFT` 가 아니라 `SUNK` 면 + 숫자 `INK`·라벨 `MUTED`(색 의존 줄임). 단어 칩: 잘함 = `OK_SOFT` 면 + `OK_ON` 글자, 놓침 = `BAD_SOFT` 면 + `BAD_ON` 굵은 글자 + **2px `BAD` 테두리**. `MiniChart`: 막대의 흐림 색을 `color.lerp(Color.WHITE, 0.45)` → `color.lerp(Pal.SURFACE, 0.55)` 로(다크에서 흰색으로 번쩍이지 않게), 격자·글자색 토큰화, `FONT_SIZE` 에 `Ds.fs`. `ProsodyPanel`: 하드코딩 4색(`#7D8DA8`, `#C9D0DC`, `#E8ECF2`, `#EEF1F5`)을 `MUTED`/`LINE`/`LINE_STRONG` 계열 토큰으로.

---

## 7. 화면별 개편안

공통: 폰 와이어프레임은 폭 412 기준 약식(박스 문자는 한글 폭이 달라 칸이 어긋날 수 있음 — 구조만 본다). `[ ]` = 버튼, `( )` = 칩, `=====` = 고정 하단 조작 바, `▓` = 진행.
모든 화면의 **정보 우선순위**는 "지금 할 일 → 현재 상태 → 설명 → 설정 순".

### 7.1 오늘 (`today_view.gd`, W5)
정보 우선순위: ① 오늘의 목표 진행(`GoalCard.compact`) ② 이어서 할 일(레슨/대화/복습 시작 버튼) ③ 연속 일수·주간 점 ④ 이번 주 활동 체크 ⑤ (설정은 이 화면에서 **분리**).
```
폰                                   |  PC (사이드 내비 오른쪽 컬럼, 폭 ≤ 880)
┌──────────────────────────────┐    |  오늘                     [● AI 엔진 준비됨]
│                    (● PC 연결됨)│ ← 앱 바 |  2단계 · 5개월차 2주차
│ 오늘                          │ ← 큰 제목 |  ┌─ 히어로 카드 ───────────────────────────┐
│ 2단계 · 5개월차 2주차           │    |  │ 38일째 / 365일   ▓▓▓▓░░░░░░░             │
│ ┌─ 히어로 ────────────────┐   │    |  │ 오늘 목표 12/15분 ▓▓▓▓▓▓▓░░              │
│ │ 38일째 / 365일           │   │    |  └──────────────────────────────────────────┘
│ │ ▓▓▓▓░░░░░░               │   │    |  ┌─ 영어 카드 ─────────┐ ┌─ 일본어 카드 ───────┐
│ │ 오늘 목표 12/15분 ▓▓▓▓░  │   │    |  │ English  (연속 3일·120XP)│ │ 日本語 ...            │
│ └──────────────────────────┘   │    |  │ 5개월차 · 이번 주 주제   │ │                       │
│ ┌─ English ───────────────┐   │    |  │ [오늘의 레슨] [원어민 대화]│ │                       │
│ │ (연속 3일 · 120 XP)       │   │    |  │ [복습 12개] ☑ 이번 주 활동│ │                       │
│ │ 이번 주: 주제…            │   │    |  └──────────────────────┘ └───────────────────────┘
│ │ [   오늘의 레슨 (primary) ]│   │
│ │ [원어민과 대화] [복습 12]  │   │
│ │ ☐ 이번 주 활동 끝냄       │   │
│ │ ● ● ○ ○ ○ ○ ○ (주간 점)   │   │
│ └──────────────────────────┘   │
│ ┌─ 日本語 ... ───────────────┐   │
└──────────────────────────────┘
 [오늘] [레슨] [대화] [복습] [더보기]
```
- 바뀌는 상호작용: 상단 40px 띠를 누르면 설정이 열리던 것 → **연결 칩 + 앱 바 "설정" 동작**으로 분리(칩=연결 상태·연결 변경, "설정"=설정 화면). `GoalCard`·`UI.lang_segmented` 는 그대로. 언어별 카드에서 `primary` 버튼은 **카드당 1개**(레슨), 나머지는 tonal. "오늘 영어 공부 완료" 토글은 `outline` 유지(상태 토글).
- 폰: 카드 세로, `_grid.columns==1`(시험 단언 유지) / PC `size.x >= 980` 이면 2열(사이드 내비 폭을 뺀 콘텐츠 폭 기준 — 1280 창에서 1056 → 2열 유지).

### 7.2 설정 (새 `views\settings_view.gd`, W5; 내비는 W4 가 연결)
지금은 오늘 화면 아래 접히는 패널(`_settings_panel`, 시작일·읽는 속도·목소리·마이크·엔진 상태·기록 지우기·연결 패널). **리스트 그룹 섹션**으로 재구성한다.
```
폰                                   |  PC
│ 설정                          │    |  설정
│ 연결                           │ ← SectionHeader
│ ┌──────────────────────────┐   │    |  좌: 섹션 목록 없이 한 컬럼 리스트 그룹(폭 720)
│ │ PC 연결 상태    ● 연결됨 > │   │    |
│ │ 연결 변경               > │   │    |
│ └──────────────────────────┘   │
│ 학습                           │
│ ┌──────────────────────────┐   │
│ │ 시작일      2026.09.01  > │   │
│ │ 하루 목표   15분        > │   │ → Sheet.choice
│ │ 읽는 속도   ──●── 1.00배   │   │
│ │ 목소리(영어)  Aria      > │   │
│ │ 자동 읽기           [스위치]│   │
│ └──────────────────────────┘   │
│ 화면                           │
│ ┌──────────────────────────┐   │
│ │ 화면 모드  시스템      > │   │ → Sheet.choice(시스템/라이트/다크), 바꾸면 "다시 열면 적용돼요"
│ │ 글자 크기  보통        > │   │ → Sheet.choice(90~150%), 미리보기 한 줄
│ └──────────────────────────┘   │
│ 기록 동기화 (SyncPanel 마운트) │ ← 1.2
│ 마이크 테스트 / 위험           │
│ ┌ 모든 기록 지우기 (danger) ┐   │ → Sheet.confirm(danger)
```
- 섹션 순서와 **마운트 지점**: `SettingsView.mount(section: String, c: Control) -> void` — `section` ∈ `"connection"|"learning"|"voice"|"display"|"sync"|"danger"`. `RemoteLinkPanel`(폰) / `PhoneLinkPanel`(PC) 는 `"connection"`, 새 `SyncPanel`(동기화 설계 S7)은 `"sync"` 에 한 줄로 마운트. 지금 `today_view.gd` 의 `_mount_link_panel(card, panel)` 규칙(비어 있으면 패널·구분선 숨김)을 그대로 이어받는다.
- 시험이 보는 계약 유지(W5): `TodayView.open_settings()`, `_settings_open`, `_settings_btn`, `_scroll`, `_engine_ob`(PC만), `go_back()` 가 설정을 닫음. `TodayView` 는 W5 단계에서 `SettingsView` 를 **오늘 화면 안에 끼워 넣는 방식으로 유지**(탭 분리는 W4 가 `views["settings"]` 로 올리면서 시험 이름 갱신).
- 새 설정 두 개의 저장: `Store.set_pref("scheme", v)`, `Store.set_pref("font_scale", f)` — 허용값만(§5.1.4), 잘못된 값은 저장하지 않고 토스트 "지원하지 않는 값이에요".

### 7.3 레슨 (`lesson_view.gd`, W7)
정보 우선순위(홈): ① "레슨 시작" ② 범위·주차·종류 선택 ③ 복습 안내. 풀이 중: ① 지금 문제 ② 선택지 ③ 확인/다음(아래 고정).
```
홈(폰)                                |  풀이(폰)
│ 레슨                          │    |  │ ← 닫기       3/10   ▓▓▓░░░░ │
│ (영어)(일본어) 세그먼트        │    |  │ 문장 고르기                    │
│ ┌ 오늘의 레슨 ────────────────┐   │    |  │ "Can I have a menu?"          │
│ │ 카페에서 주문하기             │   │    |  │ ┌ 메뉴판 좀 주실래요? ───────┐ │
│ │ 범위 [3개월차 ▾] 주차 [2 ▾]  │   │    |  │ │ ○ ...                      │ │
│ │ 레슨 종류 (실제 예문|AI)     │   │    |  │ │ ● ...  (선택)              │ │
│ │ [      레슨 시작 (56)      ]│   │    |  │ └────────────────────────────┘ │
│ └──────────────────────────┘   │    |  ================================
│ ┌ 복습 ─────────────────────┐   │    |  │ 정답이에요!  [   확인   ]      │ ← 고정 하단 조작 바
│ │ 모인 문장 12개 [복습하러]    │   │    |  ================================
```
- 바뀌는 상호작용: **범위·주차 선택(OptionButton) → 폰에서는 행을 누르면 `Sheet.choice`** (OptionButton 팝업 대신 큰 터치 항목). 하단 고정 바(`_render_footer`)가 폰·PC 모두 같은 모양(위 헤어라인 + 배경 + 결과 색: 정답 `OK_SOFT`/오답 `BAD_SOFT` 면 + 글자 `*_ON` + 결과 문장 맨 앞에 **"✓ "/"✕ " 같은 글자 표지**(색만으로 구분 금지; 기존 `✓` 글자는 이미 한 곳 사용)). 선택지(`option_row`) 선택·정답·오답 표시는 색 + 테두리 두께(2px→선택 3px)로.
- PC: 컬럼 폭 720, 푸터는 컬럼 폭에 맞춰 가운데.

### 7.4 원어민 대화 (`talk_view.gd`, W8)
정보 우선순위: 설정(상황 선택) → 대화(말풍선) → 입력(아래 고정) → 피드백.
```
설정(폰)                              |  대화(폰)
│ 원어민 대화                    │    |  │ ← 편의점에서      (さくら·1단계) │
│ (영어)(일본어)                  │    |  │            ┌──────────────┐ │
│ 어떤 상황에서 말해 볼까요?      │    |  │ ┌──────────┐│私はおにぎり… │ │
│ ┌ 카드 ┐┌ 카드 ┐ (2열)          │    |  │ │いらっしゃいませ│└──────────────┘ │
│ ┌ 카드 ┐┌ 카드 ┐               │    |  │ └──────────┘ 듣기 천천히 번역 │
│ 말하기 수준 [ ▾]  주제 [ ▾ ]    │    |  │ (はい、お願いします) (…)  ← 제안 칩 │
│ 자동 읽기      [스위치]         │    |  =================================
│ 고친 문장 바로 보기 [스위치]    │    |  │ [ 글자 입력 …………………… ] [보내기] │
│ [      대화 시작 (56)       ]  │    |  │ [      ● 말하기 (56, 가득)    ] │ ← 아래 고정
```
- 바뀌는 상호작용: 상황 카드 선택은 `filter_chip` 식 선택 표시(색+테두리+굵기), 옵션 4개는 **스위치 행(리스트 그룹)**. 말풍선 색: AI = `SURFACE` + `INK`, 나 = `accent` 채움 + `ON_ACCENT`(다크에서 어두운 글자), 교정 = `OK_SOFT` + `OK_ON`(제목 "더 자연스럽게"는 굵게). 입력줄·마이크는 지금처럼 아래 고정(키보드가 뜨면 탭줄 숨김, `phone_layout_test` L-04 유지). 대화 중 뒤로가기 2회 확인은 `Sheet.confirm` 로 바꿀 수 있으나 **시험(`lifecycle_test`: "first back only asks (toast)")이 토스트를 기대하므로 이번에는 토스트 유지**.

### 7.5 연습 허브·하위 4종 (`practice_view.gd`, `practice\*`, W6·W11)
```
허브(폰)                              |  하위 화면 공통 틀(폰)
│ 연습                          │    |  │ ← 연습     받아쓰기      3/8  │ ← 폰은 앱 바로 흡수(뒤로+제목+부제 3/8)
│ ┌ 미션 ──────────────────────┐   │    |  │ (본문 스크롤)                   │
│ │ 상황 대화로 말하기 미션     [시작]│   │    |  ==================================
│ ┌ 쉐도잉 …                    │   │    |  │ [ 다시 ]   [   다음 ▶ (primary) ]│
│ ┌ 받아쓰기 …                  │   │
│ ┌ 약한 소리 …                 │   │
```
- 4종 카드는 **리스트 그룹이 아니라 카드 4장**(각각 큰 시작 버튼). 하위 화면은 `SpeakDrill.build_shell` 이 돌려주는 딕셔너리 키(`root, back, title, count, head, page, footer_holder, footer_col`)를 **유지**(4개 화면이 키로 접근) — 폰에서 `head` 를 숨기고 앱 바가 대신 보이게 하되 `back`·`title`·`count` 노드는 존재하며 값을 계속 갱신(앱 바로 전달).
- 미션(1467줄): 대화·점수·재도전 UI — 점수 패널·녹음 버튼 공용 부품을 따르는 것 외 구조 변경 없음(리스크 §10).

### 7.6 읽기 (`reading_view.gd`, W9)
```
라이브러리(폰)                        |  읽기(폰)
│ 읽기                          │    |  │ ← 목록   City foxes   [글자 크기]│
│ (영어)(일본어)                  │    |  │ 본문(단어 탭 → 단어 시트)        │
│ ┌ 새 글 ────────────────────┐   │    |  │  Urban (foxes) have adapted …   │
│ │ 제목 [………]                │   │    |  =================================
│ │ [붙여넣기]  텍스트 [………]   │   │    |  ┌ 단어: reckless ─────────── ✕ ┐ ← 아래 시트(비모달, 높이 45%)
│ │ [      분석하기 (56)      ]│   │    |  │ 뜻 · 예문 · [복습에 추가][아는 단어]│
│ └──────────────────────────┘   │    |  └──────────────────────────────┘
│ 내 글 (리스트 그룹)              │
│  City foxes · 12단어       >    │
```
- 바뀌는 상호작용(위험도 높음, 선택 단계): 폰의 **단어 패널을 아래 시트로**(본문이 위에 보이고 단어를 계속 누를 수 있도록 비모달, 닫기 ✕). 기존 `_panel_scroll`·`select_token`·`close_panel` 계약을 유지하고 컨테이너만 바꾼다. 시트화가 터치 스크롤·`on_meta_click` 과 부딪히면 **기존 레이아웃을 새 토큰으로만 입히는 안**으로 후퇴(W9 판단 → 보고).
- 단어 상태 색(새 단어/모르는 단어/아는 단어 하이라이트 `LEARN_BG/LEARN_FG` 등)은 **색 + 밑줄/굵기**(이미 `_legend(... underline ...)` 있음)를 유지하고 값을 토큰으로 옮겨 다크 대비 확보(`#FFE6A6/#6B4A00` 는 다크에서 번쩍이므로 `WARN_SOFT/WARN_ON`).
- PC: 컬럼 폭 유지. 2분할은 선택 과제.

### 7.7 복습 (`review_view.gd`, W10)
```
홈(폰)                                |  진행(폰)
│ 복습                          │    |  │ ← 그만    3/12   ▓▓▓░░░░░░      │
│ (영어)(일본어)                  │    |  │ 한국어 뜻                          │
│ ┌ 틀린 문장 다시 말하기 ──────┐   │    |  │ "메뉴판 좀 주실래요?"              │
│ │ 오늘 복습 12개 · 새 문장 3   │   │    |  │ [ ● 말하기 ]  또는 직접 입력        │
│ │ [       복습 시작 (56)      ]│   │    |  ====================================
│ └──────────────────────────┘   │    |  │ 얼마나 기억했나요?                  │
│ 모인 문장 (리스트 그룹, 최근순)  │    |  │ [다시] [어려움] [좋음] [쉬움]        │ ← 등급 4칸, 아래 고정
```
- 우선순위: 오늘 분량 → 시작 → 모인 문장. 등급 버튼(FSRS, 4칸)은 **글자 + 색**(색만으로 구분하지 않음; 글자가 이미 있음). 아래 고정 영역은 폰에서 하단 탭 위에 붙는 조작 바.

### 7.8 기록 (`stats_view.gd`, W10)
`GoalCard.full`(목표 시간 선택은 `Sheet.choice`), 주간 막대(`MiniChart.bars`), 정답률·발음 점수 선(`MiniChart.line`) 카드들을 **카드 + 큰 숫자 + 차트** 순으로. 빈 상태 문구(`"아직 기록이 없어요…"`) 유지. 차트 색은 토큰, 차트 아래에 **숫자 요약 한 줄**(색 없이 읽히도록: "이번 주 합계 45분", "기간 평균 82%").

### 7.9 로드맵 (`roadmap_view.gd`, W10)
월 카드 아코디언(`▾/▴` 글자 유지 — 시험이 열림 상태를 `open_months` 로 봄)을 **리스트 그룹 머리글처럼** 보이게: 월 제목 행(56) 아래 주차 행들, 체크박스(다중 선택이라 체크) 유지, 진행률 글자 `Muted`.

### 7.10 연결 화면·스플래시·배너 (`connect_view.gd` 등)
- 스플래시·배너는 `main.gd`(W4): 카드 `BigCard`(폭 520 / 폰 화면-32), 진행 `indeterminate`, 버튼은 primary 1 + tonal. 배너 = `WARN_SOFT` 면 + `WARN_ON` 글자 + 왼쪽 굵은 표지 "! "(색만 X).
- `ConnectView`(폰 페어링): **재스킨만**(테마 변형이 자동 적용). 구조 변경은 폰 단독 모드 설계가 이 화면을 건드릴 가능성이 높아 **그 작업이 병합된 뒤 W12 로 미룬다**(§9).

---

## 8. 구현 전략과 작업 분할

### 8.1 전략
1. **토큰·테마·부품을 먼저**(공용 파일, 화면 구조는 건드리지 않음) → 이 단계는 "모습만 바뀌고 구조는 같아서" 기존 시험이 그대로 통과해야 한다.
2. 화면은 **파일 소유로 쪼개 병렬**로 옮긴다(`UI.*` 헬퍼와 새 부품으로). 각 화면 작업자는 자기 파일만 고친다.
3. 셸(`main.gd`)과 오늘/설정(`today_view.gd`)은 **동기화 S7·폰 단독 모드와 같은 파일**이라 그 둘이 병합된 뒤에 한다(§9).
4. 시각 회귀 = (a) 기존 `shots_phone.gd` 순회를 PC·폰 × 라이트·다크 × 글자 100/150% 로 확장해 PNG 생성 (b) `tools\shot_check.gd` 로 크기·빈 이미지·밝기 방향 검사 (c) 같은 순회로 돌리는 `phone_layout_test`(겹침·터치 크기) (d) 사람(오케스트레이터)이 대표 화면을 열어 본다. 픽셀 완전 일치 비교는 **하지 않는다**(의도적 변경이라). 기준(전) 스크린샷은 W0 가 찍어 `scratchpad` 에 둔다(저장소에 올리지 않음 — 공개 점검: 대용량 데이터 금지).
5. 접근성은 숫자 시험으로: 대비(`contrast_test`), 터치 48(`phone_layout_test --touch-min=47.5`), 글자 150% 겹침 0(`--font-scale=1.5` 로 같은 순회), 색만 구분 금지(칩·정답·오류·점수에 글자/모양 단서 — 수동 목록 점검 + 회색조 스크린샷 변환은 선택).

### 8.2 공통 명령 표기
```
$GODOT = "$env:USERPROFILE\Desktop\Godot_v4.6.3-stable_win64.exe\Godot_v4.6.3-stable_win64_console.exe"   # WORKLOG 에 적힌 경로
$P     = "D:\Ai\언어\app\godot"
헤드리스 시험:  & $GODOT --headless --path $P res://tests/<이름>.tscn [-- --phone]
스크린샷(창이 잠깐 뜸):  & $GODOT --path $P --resolution 412x915 --audio-driver Dummy res://tests/shots_phone.tscn -- <출력폴더> --phone
                        & $GODOT --path $P --resolution 1280x800 --audio-driver Dummy res://tests/shots_phone.tscn -- <출력폴더>
```
시험 끝 줄 형식: `== <이름> ...: N passed, M failed ==`(기존 시험 공통). "0 failed" 확인은 마지막 줄의 `, 0 failed` 문자열로 한다.

### 8.3 공통 합격 조건 (모든 작업에 붙음, `C-1..C-8`)
| # | 조건 | 판정 방법 |
|---|---|---|
| C-1 | **UI 시험 묶음** 전부 `0 failed`: W0 가 기록한 목록(예상: smoke, flow, review_walk, reading, stats_view, practice, dictation, mission, lifecycle, t5_wiring, prosody, lesson_source, study_log, streak, fsrs, persist 중 엔진이 필요 없는 것) 각각 마지막 줄 `, 0 failed ==`, **passed 수 ≥ W0 기록**(시험을 지우거나 약하게 고치지 않음) | 각 `.tscn` 헤드리스 실행 |
| C-2 | `phone_layout_test`(`-- --phone` 와 PC 둘 다)와 `touch_scroll_test`(`-- --phone` 와 PC 둘 다) `, 0 failed ==` | 위 4회 실행 |
| C-3 | 수정 파일이 **소유 파일 목록 안에만** 있다 | `git diff --name-only` 결과가 소유 목록의 부분집합 |
| C-4 | 시험 전후로 **실제 사용자 파일**(앱의 `user://` 아래 `progress.json`, `prefs.json`, `studylog.json`, `remote.json`)의 MD5 불변 | 실행 전후 `Get-FileHash` 비교(값은 출력하지 않고 일치 여부만 보고) |
| C-5 | 포트 8770·8775 에 접속하지 않음. 테스트 서버가 필요하면 18700대의 빈 포트를 확인한 뒤 자기 PID 만 종료. 보고에 "남은 프로세스·열린 포트 없음" | `Get-NetTCPConnection` 확인 |
| C-6 | 비밀값(토큰·API 키·`remote.json` 내용) 출력·기록 없음 | 보고·로그 검색 |
| C-7 | 임시 파일은 `scratchpad\w_<작업명>\` 아래만 | 경로 확인 |
| C-8 | 시험이 건드리는 화면 멤버(§3.3 grep)의 이름·의미 유지. 시험을 고쳐야 하면 그 작업 지시에 **줄 단위로 허용된 것만** | `git diff -- godot/tests` 가 허용 목록과 일치 |
금지(공통): 프로세스는 이름으로 끄지 않고 시작한 PID 로만 종료, `git commit/push` 금지(커밋은 오케스트레이터), 소유 아닌 파일 수정 금지, 한국어 문구 임의 변경 금지(필요하면 보고), 외부 이미지·글꼴·아이콘 파일 추가 금지(§2.3), 시험 단언 삭제·완화 금지.

### 8.4 작업 목록 (W0 ~ W13)
표기: 담당 = worker(Haiku) / worker-hard(Sonnet). "병렬" = 같은 단계에서 동시에 해도 파일이 겹치지 않음. 같은 파일을 둘이 고치는 경우는 **worktree 로 분리**(CLAUDE.md 규칙)하고 오케스트레이터가 순서대로 합친다.

#### W0 — 기준선 (worker)
- 수정 허용: **새 파일** `godot\tests\ui_perf_test.gd`, `godot\tests\ui_perf_test.tscn` 만. 나머지 읽기 전용.
- 내용: ① 모든 Godot 시험 장면을 하나씩 헤드리스로 실행해 `scratchpad\w_baseline\tests.tsv`(이름, 종료코드, passed, failed, 비고) 작성. 엔진·네트워크가 필요한 것(`live_test`, `phone_live_test`, `tts_test`, `mic_test`, `remote_test` 등)은 실행하지 말고 `SKIP(엔진 필요)`. `practice_test` 는 실제 `prefs.json` 을 쓴다는 기존 알려진 문제가 있으므로 실행 전 MD5 기록·후 비교(변하면 복원 보고, **복원은 사용자 파일을 쓰는 일이라 하지 말고 보고만**). ② 현재 화면 스크린샷 PC·폰 각각 `scratchpad\w_baseline\before_pc\`, `before_phone\`. ③ `ui_perf_test`: 화면 6개(오늘·레슨·대화·읽기·복습·로드맵)와 복습 카드 200개 픽스처 상태를 5번씩 만들어 `PERF view=<k> nodes=<n> res=<r> build_ms=<t>` 출력(`Performance.OBJECT_NODE_COUNT`, `RESOURCE_COUNT`, `Time.get_ticks_usec`), `-- --baseline=<파일> --max-ratio=1.3` 이면 비교해 `== ui_perf: N passed, M failed ==`.
- 합격 조건:
  - W0-1 `tests.tsv` 행이 시험 장면 수(`godot\tests\*.tscn`, 현재 29개 중 실제 시험 아닌 `shots*`·`crash_repro` 제외)와 같고, 각 행이 숫자 또는 `SKIP(사유)` — 판정 불가·읽지 못한 행은 `미검증`.
  - W0-2 `before_phone\` 와 `before_pc\` 각각 PNG ≥ 30장, 각 폭×높이가 412×915 / 1280×800(`tools\shot_check.gd` 가 아직 없으므로 `Image` 크기를 읽는 한 줄 스크립트로 확인).
  - W0-3 `ui_perf_test` 가 기준값 파일을 만들고, 같은 빌드에서 `--baseline=<그 파일> --max-ratio=1.3` 으로 다시 돌리면 0 failed. **틀린 입력 확인**: 기준값 파일의 한 줄 `build_ms` 를 1/10 로 고쳐서 돌리면 FAIL 이 보고돼야 한다.
  - C-3(새 파일 2개 외 변경 0), C-4~C-7.
- 의존: 없음. 병렬: W1 과 병렬 불가(W1 이 시작되기 전 기준선이어야 함) — **W0 → W1 순서**.

#### W1 — 토큰·테마·아이콘 (worker-hard)
- 수정 허용: `godot\scripts\core\pal.gd`, 새 `godot\scripts\ui\ds.gd`, 새 `ui\ui_boot.gd`, 새 `ui\theme_icons.gd`, 새 `ui\glyph.gd`, `godot\scripts\ui\phone_layout.gd`(상수·`apply_theme` 만), `godot\tools\make_theme.gd`, `godot\theme\app_theme.tres`(재생성), 새 `godot\theme\app_theme_dark.tres`, 새 `godot\tests\contrast_test.gd/.tscn`. 읽기 전용: 나머지 전부(특히 `main.gd`, `ui.gd`).
- 내용: §5.1~5.3, §6.2 전부. `const` → `static var`(기존 이름·라이트 값 그대로), 새 토큰, `Pal.use/resolve`, `Ds`, `UiBoot.apply`, `ThemeIcons`, `GlyphIcon`. `make_theme.gd` 가 라이트·다크 두 테마를 생성(변형 이름 유지 + 새 변형 `LargeTitle, AppBarTitle, SectionHeader, ListMain, ListSub, Group, FilterChip` 추가, 반경·입력칸 테두리·플레이스홀더·줄 간격 반영). 강조색 A·B 두 벌을 만들어 스크린샷 비교용으로 남긴다(선택값은 `Pal.PRIMARY` 한 줄).
- 이 단계는 `main.gd` 를 **건드리지 않으므로** 앱은 계속 라이트 + 기존 구조로 뜬다(`UiBoot.apply` 는 시험·스크린샷이 부르고, 실제 앱 시작에 연결하는 것은 W4).
- 합격 조건:
  - W1-1 `& $GODOT --headless --path $P res://tests/contrast_test.tscn` 마지막 줄 `== contrast: N passed, 0 failed ==`, N ≥ 70(§5.1.6 표를 라이트·다크 둘 다).
  - W1-2 **틀린 입력**: `contrast_test` 안 자체 점검이 `#777777/#FFFFFF` 를 FAIL 로, `#767676/#FFFFFF` 를 PASS 로, 기존 값 `JA/JA_SOFT`(4.27)를 FAIL 로 보고(출력에 `selfcheck FAIL-as-expected` 3줄).
  - W1-3 기존 라이트 값 불변: 테스트의 `LEGACY` 표(§5.1.1 라이트 16색)가 `Pal.use("light")` 후 모두 같음.
  - W1-4 `Pal.use("purple")` 가 라이트로 대체되고 경고만 남김(예외·크래시 없음); `Ds.set_font_scale(9.0)` → 1.5, `set_font_scale(0.0)`/NaN → 1.0.
  - W1-5 두 테마 파일이 존재하고 로드되며(`load("res://theme/app_theme.tres") is Theme`, 다크도), `theme.get_stylebox("panel","Card").corner_radius_top_left == Ds.R_CARD`, `theme.get_font_size("font_size","Small") == 13`(PC) 등 §5.2 표 3개 값 일치. 깨진 입력: `UiBoot.apply(root, "dark", 1.0)` 호출 전 `theme\app_theme_dark.tres` 를 임시 이름으로 바꿔 둔 사본 경로 테스트(`UiBoot` 의 경로를 인자로 받는 내부 함수로)에서 **라이트로 대체 + 0 크래시**.
  - W1-6 `ThemeIcons.apply(theme)` 후 `theme.get_icon("checked","CheckButton").get_size().x >= 52`, 모든 아이콘이 비어 있지 않음(`Image.is_empty()==false`). `GlyphIcon.new("nope")` 가 오류 없이 빈 칸.
  - W1-7 C-1, C-2(전부 라이트·구조 불변이라 변화 없어야 함), C-3~C-8. 추가: `phone_layout_test --phone` 의 `TOUCH_SMALL_COUNT 0`(링크 44→48 이 되어도 통과).
- 의존: W0. 병렬: W1b(§아래)는 W1 이 끝난 뒤.

#### W1b — 스크린샷 도구 (worker)
- 수정 허용: `godot\tests\shots_phone.gd`(인자 처리·출력 이름만), 새 `godot\tools\shot_check.gd`. 읽기 전용: 나머지.
- 내용: `shots_phone.gd` 에 사용자 인자 `--dark`, `--font-scale=<f>`, `--only=<접두>` 추가(앱 시작 전에 `UiBoot.apply` 호출, 파일 이름 접두 `phone_dark_`, `pc_light_f150_` 처럼). `phone_layout_test` 가 같은 순회를 쓰므로 인자를 그대로 전달 가능해야 함. `shot_check.gd`: `godot --headless --path $P --script res://tools/shot_check.gd -- <폴더> --expect=412x915 --scheme=light|dark` → 각 PNG 의 크기, **빈 이미지(휘도 표준편차 < 0.02)**, 밝기 방향(라이트 평균 휘도 > 0.70, 다크 < 0.35)을 검사하고 마지막 줄 `SHOT_CHECK ok=<n> bad=<m>`, `bad>0` 이면 종료 코드 1.
- 합격 조건:
  - W1b-1 `shots_phone` 이 `--dark` 로 PNG ≥ 30장 생성, `shot_check --scheme=dark` → `bad=0`. 라이트 폴더에 `--scheme=dark` 로 돌리면 `bad` ≥ 1 (**틀린 입력 확인**).
  - W1b-2 단색 PNG 1장(검사기 시험용으로 `Image.create` 로 만든 412×915 흰색)을 폴더에 넣으면 `bad` ≥ 1, 크기가 다른 PNG(100×100)도 `bad` ≥ 1.
  - W1b-3 `--font-scale=1.5` 로 PNG ≥ 30장 생성, 인자 없는 기본 실행은 이전과 같은 파일 이름 접두(`phone_NN_…`, `pc_NN_…`)로 동작(기존 도구 호환).
  - C-1~C-8.
- 의존: W1. 병렬: W2, W3 와 병렬 가능(파일 겹침 없음).

#### W2 — 기본 부품 (worker-hard)
- 수정 허용: `godot\scripts\ui\ui.gd`, `ui\card_box.gd`, `ui\column_box.gd`, `ui\page_scroll.gd`, 새 `ui\list_group.gd`, 새 `godot\tests\ui_prims_test.gd/.tscn`, 새 `godot\tests\ui_gallery.gd/.tscn`(부품 모음 장면, `-- --dark --phone` 인자 지원), `godot\scripts\ui\phone_layout.gd`(터치 헬퍼만 — W1 과 겹치지 않게 W1 이 끝난 뒤). 읽기 전용: 그 밖에 전부.
- 내용: §6.4. **기존 `UI.*` 시그니처는 하나도 바꾸지 않는다**(호출 100곳 이상). 추가 함수: `UI.chip_kind`, `UI.filter_chip`, `UI.pref_switch`, `UI.switch_row`, `UI.fs`(= `Ds.fs`). 버튼 4종+danger, 스타일 캐시, 카드 변형, `ListGroup`.
- 합격 조건:
  - W2-1 `ui_prims_test` `, 0 failed`: 폰 모드(`-- --phone`)에서 `UI.button/option_row/tile/link_button/segmented 버튼/check_row/pref_switch/option_button/field` 의 `get_combined_minimum_size().y` 또는 설정 높이 ≥ 47.5; `ListGroup.add_row` 행 ≥ 56(부연 있으면 ≥ 72); 스위치 행의 `CheckButton` 히트 영역 ≥ 48×48. PC 모드 버튼 높이 ≥ 40.
  - W2-2 **스타일 캐시**: `UI.button("x","primary",Pal.EN)` 를 200번 만들어도 `Performance.get_monitor(Performance.OBJECT_RESOURCE_COUNT)` 증가가 ≤ 40(캐시 없을 때 ≈ 1200).
  - W2-3 **틀린 입력**: `UI.button("", "nope")`(모르는 kind)는 크래시 없이 기본 모양; `ListGroup.add_row("")` 는 행을 만들지 않고 경고만; `UI.chip_kind("x","nope")` 는 neutral.
  - W2-4 `ui_gallery` 가 폰·PC × 라이트·다크 4가지로 뜨고 PNG 4장 생성(`shot_check` `bad=0`); 갤러리에 §6.1 의 #3~#7, #10 부품이 모두 한 번씩 보임(오케스트레이터 눈 확인용 장면 이름 목록을 보고서에 적음).
  - W2-5 `touch_scroll_test`(폰·PC) 0 failed — 새 `ListGroup` 행·스위치는 스크롤 안에서 손가락 시작 위치에 상관없이 스크롤(이 시험이 갤러리를 포함하지 않으므로 `ui_prims_test` 에 **같은 방식의 300px 드래그 검사**를 복사해 `ListGroup` 행 위에서 시작하는 경우와 스위치 위에서 시작하는 경우 `on_tap`/`toggled` 가 **불리지 않고** 페이지가 ≥ 200px 움직임을 확인).
  - W2-6 C-1~C-8. 색: `ui.gd` 에 `Color("#7C9BE8")` 같은 직접 색 0건(`grep -n 'Color("#' godot/scripts/ui/ui.gd` 결과 없음), 고정 글자 크기 `add_theme_font_size_override` 가 `UI.fs` 를 거침.
- 의존: W1. 병렬: W3, W1b 와 병렬.

#### W3 — 겹침·내비 부품 (worker-hard)
- 수정 허용: 새 `ui\sheet.gd`, `ui\toast_host.gd`, `ui\app_bar.gd`, `ui\page_header.gd`, `ui\side_nav.gd`, `ui\conn_chip.gd`, `godot\scripts\ui\bottom_tabs.gd`, `godot\scripts\autoload\toast.gd`(`snack` 신호 추가만), `godot\scripts\views\app_view.gd`(§6.3 계약 추가만), 새 `godot\tests\ui_nav_test.gd/.tscn`, 새 `godot\tests\ui_gallery_nav.gd/.tscn`. 읽기 전용: `main.gd` 포함 나머지.
- 내용: §6.3, §6.5~6.7. **`main.gd` 에 연결하지 않는다**(연결은 W4). `BottomTabs` 는 `max_direct=6` 유지(시험 무변경), 모양만 새것.
- 합격 조건:
  - W3-1 `ui_nav_test` `, 0 failed`: `AppBar.collapse_t(0,96)==0`, `(48,96)==0`, `(72,96)==0.5`, `(96,96)==1`, `(500,96)==1`; **틀린 입력**: `collapse_t(-50,96)==0`, `collapse_t(NAN,96)==0`, `collapse_t(10,0)==1`, `collapse_t(10,NAN)==1`.
  - W3-2 `Sheet`: `Sheet.confirm(...)` 열면 `Sheet.is_open()`; `close_top()` 가 true 한 번, 그 뒤 false; 확인 버튼 → `closed("ok")`, 취소 → `"cancel"`, 딤 탭 → `"dismiss"`; `dismissable=false` 면 딤 탭이 닫지 않음; 폰 `bottom` 패널의 `get_global_rect().end.y` 가 화면 높이(915) 이하이고 키보드 300px 일 때 ≤ 615; 같은 호스트에서 두 번 연속 `open` → 스택 2, `close_top` 두 번에 모두 닫힘; 버튼 0개·본문 `null` 입력에도 크래시 없음.
  - W3-3 `ToastHost`: 500자 문자열의 `show_message` 후 라벨 줄 수 ≤ 3(`get_visible_line_count() <= 3`); `Toast.error("x")` 로 `Toast.message("x","error")` 신호 텍스트 불변(구독 시험 유지); 동작 단추가 있는 스낵바에서 단추 `pressed` 시 콜백 1회; `Toast.snack` 신호 추가가 기존 구독자에게 영향 없음(`lifecycle_test`·`persist_test` 통과).
  - W3-4 `SideNav`: 항목 높이 ≥ 44, `set_current` 가 선택 모양 하나만 켬, 클릭 시 `item_selected(key)` 1회, 폭 223~225. `ConnChip.set_state("ok","PC 연결됨")` 글자가 항상 보임(`label.visible and label.text != ""`), 모르는 kind 는 idle.
  - W3-5 `BottomTabs`: `shots_phone` 이 쓰는 API 이름 전부 존재(`has_method` 목록 검사), 8개 탭에서 직접 5개+더보기 시트(기존 동작), 셀 ≥ 48×56, 새 모양에서도 `phone_layout_test --phone` 의 기존 탭 단언 통과.
  - W3-6 `AppView` 계약 추가가 기존 8개 화면에 영향 없음(C-1·C-2). 갤러리 `ui_gallery_nav` 폰·PC × 라이트·다크 PNG 4장 `shot_check` `bad=0`.
  - W3-7 C-1~C-8.
- 의존: W1. 병렬: W2, W1b 와 병렬.

#### W6 — 연습 공용 부품 (worker-hard)
- 수정 허용: `godot\scripts\ui\recorder_widget.gd`, `ui\score_panel.gd`, `ui\prosody_panel.gd`, `ui\mini_chart.gd`, `godot\scripts\practice\speak_drill.gd`, `godot\scripts\views\practice_view.gd`, 새 `godot\tests\ui_practice_widgets_test.gd/.tscn`. 읽기 전용: 나머지(특히 `practice\*_screen.gd`).
- 내용: §6.8, §7.5 의 공용 틀(`build_shell` 반환 키 유지, 폰 앱 바 흡수는 W4 가 연결하기 전까지 기존 헤더 모양을 새 토큰으로 유지).
- 합격 조건:
  - W6-1 `ui_practice_widgets_test` `, 0 failed`: 녹음 버튼 3상태(대기/녹음 중/처리 중)의 `_btn.text` 가 서로 다름, 폰 큰 버튼 높이 ≥ 56 폭 > 300, PC `custom_minimum_size == Ds.REC_BIG_PC / Ds.REC_SMALL_PC`.
  - W6-2 `ScorePanel`: 점수 85/65/40 에서 숫자 색이 OK/WARN/BAD, **놓친 단어 칩이 테두리 폭 ≥ 2 이고 잘한 칩은 0**(색 말고 모양 단서), 라벨 글자색이 `*_ON` 계열(테스트가 `Pal.OK_ON` 과 같은지).
  - W6-3 `MiniChart` 다크: `Pal.use("dark")` 후 흐린 막대 색의 휘도 < 0.5(흰색 쪽으로 번쩍이지 않음). 라이트에서는 기존과 같은 방향(휘도 > 막대색).
  - W6-4 `add_theme_font_size_override`·`draw_string` 크기가 `Ds.fs` 를 거침 — `Ds.set_font_scale(1.5)` 후 `MiniChart` 글자 크기 값이 기본의 1.5배(±1).
  - W6-5 `practice_test`, `dictation_test`, `mission_test`(C-1)와 `touch_scroll_test` 의 연습 화면 시나리오 통과. `SpeakDrill.build_shell` 반환 딕셔너리의 키 8개(`root, back, title, count, head, page, footer_holder, footer_col`) 모두 존재(테스트가 `keys()` 비교).
  - W6-6 C-1~C-8.
- 의존: W2, W3. 병렬: W7~W11 과 (W6 가 끝난 뒤) 병렬. W6 끝나기 전에 W11 시작 금지(공용 틀 변경 영향).

#### W7 — 레슨 (worker-hard) / W8 — 원어민 대화 (worker-hard) / W9 — 읽기 (worker-hard) / W10 — 복습·기록·로드맵 (worker-hard) / W11 — 연습 4종 (worker-hard)
공통(각 작업의 수정 허용 파일은 **아래 하나뿐**, 나머지 전부 읽기 전용): 
- W7: `godot\scripts\views\lesson_view.gd`
- W8: `godot\scripts\views\talk_view.gd`
- W9: `godot\scripts\views\reading_view.gd`
- W10: `godot\scripts\views\review_view.gd`, `roadmap_view.gd`, `stats_view.gd`, `godot\scripts\ui\goal_card.gd`
- W11: `godot\scripts\practice\mission_screen.gd`, `shadow_screen.gd`, `dictation_screen.gd`, `phoneme_screen.gd`(`dictation_diff.gd`·`speak_drill.gd` 는 W6)
- 의존: W2, W3, W6(W7·W8·W9·W10 은 W6 의 공용 부품 변경과 무관하나 녹음·점수를 쓰므로 W6 뒤). 병렬: **서로 파일이 달라 W7~W11 모두 병렬**.
- 공통 내용: §7 의 해당 절. 하드코딩 색 → 토큰, `Pal.OK/WARN` 글자 → `*_ON`, `add_theme_font_size_override` → `Ds.fs`, 기본 `OptionButton` 은 폰에서 `Sheet.choice` 행으로(선택), `pref_toggle` → `pref_switch`(설정·옵션), 칩 → `chip_kind`, 상태 표시에 글자/모양 단서 추가. **시험이 만지는 멤버(§3.3 grep)와 한국어 문구는 유지.**
- 공통 합격 조건(작업마다 접두 `W7-` 처럼):
  - Wn-1 C-1, C-2.
  - Wn-2 **자기 화면 상태**의 터치 크기: `& $GODOT --headless --path $P res://tests/phone_layout_test.tscn -- --phone --touch-min=47.5 --only=<자기 상태 접두>` 마지막 줄 `, 0 failed ==`(레슨 `lesson_`, 대화 `talk_`, 읽기 `reading_`, 복습 `review_`, 로드맵 `roadmap`, 기록 `stats`, 연습 `practice`·`mission`·`shadow`·`dictation`·`phoneme`). `--touch-min`·`--only` 는 W4 가 추가한다 → **W4 가 먼저 끝나지 않았으면** 이 항목은 "W4 이후 W13 에서 일괄 확인"으로 미룸(보고서에 `미검증(W4 대기)` 로 적는다).
  - Wn-3 `--font-scale=1.5` 순회(W1b)에서 `LAYOUT_OVERFLOW_COUNT 0`(자기 상태 한정).
  - Wn-4 `shots_phone` 스크린샷: 폰 라이트·폰 다크·PC 라이트·PC 다크 각각 자기 상태 PNG 생성, `shot_check` `bad=0`.
  - Wn-5 `grep -n 'Color("#' <자기 파일>` 결과 없음, `grep -n 'Pal\.\(OK\|WARN\)\b' <자기 파일>` 중 **글자색으로 쓰는 곳 0건**(채움·테두리는 허용; 작업자가 목록과 판정을 보고서에 표로).
  - Wn-6 색만으로 구분하던 상태(정답/오답/상태 칩/점수)마다 글자·모양 단서가 있음(작업자가 상태 목록 표를 보고서에 적고 오케스트레이터가 2개를 직접 확인).
  - Wn-7 C-3~C-8.
- 화면별 추가 합격 조건:
  - W7: 레슨 풀이 중 하단 고정 바가 폰·PC 모두 `footer` 로 존재, 정답/오답 결과 문장 앞에 글자 표지(`✓`/`✕`)가 붙음(테스트가 `lv._render_footer` 후 라벨 텍스트 확인), `lv._record_widget`·`lv._autoplayed` 유지. 범위·주차 선택은 폰에서 `Sheet.choice` (선택 과제, 하지 않으면 OptionButton 유지 — 둘 다 허용).
  - W8: 대화 말풍선 `_bubble`(시그니처 유지), 입력줄·마이크 위치 단언(L-04) 통과, 키보드 300px 시나리오 통과. `tv._input`, `tv._mic` 유지.
  - W9: `ReadingView.SAMPLES`, `rv._te`, `rv._panel_scroll`, `select_token`, `close_panel` 유지. 학습 단어 하이라이트의 다크 대비: `LEARN_BG`/`LEARN_FG` 가 토큰으로 바뀌고 `contrast_test` 쌍에 추가(4.5). 폰 단어 시트화는 선택 과제 — 하면 단어를 누를 때 `touch_scroll_test` 읽기 시나리오(드래그가 단어 선택을 일으키지 않음)가 0 failed 여야 하고, 아니면 후퇴.
  - W10: 로드맵 `open_months` 동작 유지, 체크박스 유지, 기록 화면 빈 상태 문구 유지, `stats_view_test` 0 failed.
  - W11: 4개 화면의 `build_shell` 키 접근 유지, `mission_test`/`dictation_test`/`practice_test` 0 failed.

#### W4 — 셸 (worker-hard) — **선행 조건: 동기화 S7 병합 + 폰 단독 모드 UI 병합(§9)**
- 수정 허용: `godot\scripts\main.gd`, `godot\scenes\main.tscn`(필요 시), `godot\scripts\views\app_view.gd`(W3 이후 변경이 필요할 때만), `godot\tests\phone_layout_test.gd`(**§3.3 에 적힌 셸 관련 줄만**), `godot\tests\shots_phone.gd`(이름 맞춤만), `godot\tests\touch_scroll_test.gd`(연결 화면 시나리오가 셸 변경 때문에 깨질 때만, 줄 단위 보고), `godot\project.godot` **수정 금지**. 읽기 전용: 나머지.
- 내용: §4, §6.3~6.7 연결. (1) 시작 시 `UiBoot.apply(get_window(), Store.pref_string("scheme","system"), Store.pref_float("font_scale",1.0))` — `Store` 에 `pref_string`/`pref_float` 이 없으면 `Store.prefs.get(key, default)` 로 직접 읽는다(`store.gd` 는 W4 소유가 아니므로 수정 금지). (2) 폰: 위 40px 띠 → `AppBar`(+`ConnChip`), 아래 `BottomTabs`(`max_direct=5`, 탭 순서 `today, lesson, talk, review` 직접 + 더보기(`practice, reading, stats, roadmap, settings`)); 큰 제목은 각 화면이 `AppView.header_block()` 로 제공하면 연결. (3) PC: 위 탭 줄 + "더보기 ▾"(`PopupMenu`) 제거 → `SideNav`(+ 아래 `ConnChip` 두 개: 엔진 상태, "폰 연결 켜짐") + 콘텐츠. (4) 토스트 → `ToastHost`(`_toast_box` 별칭 유지). (5) `handle_back` 첫 줄에 `if Sheet.close_top(): return`. (6) 설정을 별도 도착지로: `views["settings"]` = `SettingsView`(W5), `_open_settings()` 가 `show_view("settings")`. (7) 스플래시·배너·연결 레이어 재스킨(구조 유지). (8) **`_on_backend_status` 의 문구 결정 블록(`match st:` … `_splash_title` 등)은 글자 그대로 둔다**(폰 단독 모드가 이 문구를 바꿀 가능성이 높음); 점·글자를 직접 스타일하던 두 줄만 `ConnChip.set_state(kind, text)` 호출로 바꾼다. (9) `phone_layout_test` 에 인자 `--touch-min=<f>`(기본 43.5), `--only=<접두>`(상태 이름 접두 필터), `--font-scale=<f>`, `--dark` 추가.
- 합격 조건:
  - W4-1 폰: `phone_layout_test -- --phone` 0 failed 이며 갱신된 단언이 **측정 가능한 값**: 탭 셀 5개(각 ≥ 48×56), 직접 탭 키 = `["today","lesson","talk","review"]`, 더보기 시트의 `overflow_keys()` = `["practice","reading","stats","roadmap","settings"]`(설정이 탭 목록에 있을 때), 앱 바 높이 ≤ 56 + inset, 상태 칩 글자가 앱 바 안, `main._bottom_tabs.max_direct == 5`.
  - W4-2 PC: `phone_layout_test`(PC) 0 failed: `main._side_nav.size.x` ∈ [223, 225], `main._bottom_tabs == null`, 위 탭 버튼 없음, 콘텐츠 컬럼 폭 ≤ 880, 오늘 `_grid.columns == 2`(1280 창, 사이드 내비 포함). 창 폭 900 으로 줄여도 겹침 0(헤드리스는 창 크기 지정 가능 — 시험이 `get_window().size` 를 900×600 으로 바꿔 한 번 더 `_scan`).
  - W4-3 다크: `--dark` 로 `Pal.is_dark()==true`, `get_window().theme` 이 다크 테마, 스크린샷 `shot_check --scheme=dark` `bad=0`. `scheme="purple"`(잘못된 pref)로 시작 → 라이트·크래시 없음(**틀린 입력**), `font_scale="abc"` → 1.0.
  - W4-4 `handle_back`: `Sheet` 가 열려 있으면 앱이 종료·화면 이동하지 않고 시트만 닫힘(시험: `Sheet.confirm` 열고 `main.handle_back()` → `Sheet.is_open()==false` 이고 `main.current` 불변); 열려 있지 않으면 기존 동작.
  - W4-5 `Toast.message` 계약: `lifecycle_test`·`persist_test`·`study_log_test` 0 failed(토스트 텍스트 불변). `main._toast_box` 별칭 존재(`shots_phone` 이 `.visible=false` 대입 가능).
  - W4-6 `touch_scroll_test`(폰·PC) 0 failed — 앱 바·하단 탭·시트가 **ScrollContainer 밖**이라 드래그를 가로채지 않음. 추가 시나리오 1개: 앱 바 영역 위에서 시작한 300px 드래그는 페이지를 움직이지 않음(앱 바는 스크롤 영역 밖이므로 정상, `delta == 0` 확인) — 기대 동작을 시험으로 못 박음.
  - W4-7 `_on_backend_status` 문구 블록 diff 없음(`git diff -U0 main.gd` 에서 `text = "PC 연결됨"` 등 문구 줄이 `-`/`+` 로 나타나지 않음).
  - W4-8 C-1~C-8.
- 의존: W2, W3, (W5 와 함께 또는 W5 뒤 — `views["settings"]` 를 쓰므로 **W5 선행**), S7·단독 모드 병합. 병렬: W7~W11 과 병렬(파일 겹침 없음), W5 와는 순서(W5 → W4).

#### W5 — 오늘·설정 (worker-hard) — **선행 조건: S7 병합, 폰 단독 모드 A6·B3·C3 병합(§9)**
- 수정 허용: `godot\scripts\views\today_view.gd`, 새 `godot\scripts\views\settings_view.gd`, `godot\scripts\ui\remote_link_panel.gd`, `ui\phone_link_panel.gd`(재스킨만, 로직 불변), `godot\tests\phone_layout_test.gd`(**§3.3 의 설정 관련 줄만**: `RemoteLinkPanel` 첫 항목, `PhoneLinkPanel` 위치, `_engine_ob`, mount 시험 3개), `godot\tests\t5_wiring_test.gd`(설정 구조에 의존하는 줄이 있을 때만). 읽기 전용: 나머지.
- 내용: §7.1, §7.2. `SettingsView` 는 `TodayView` 안에 끼워 쓰는 방식으로 먼저(탭 분리는 W4). `SyncPanel` 은 S7 이 이미 마운트했으면 `SettingsView.mount("sync", panel)` 한 줄로 옮긴다.
- 합격 조건:
  - W5-1 `SettingsView.mount(section, c)` 7개 섹션 id(`connection, learning, voice, display, sync, danger` + 단독 모드용 `engine`) 모두에 마운트되고, 모르는 section id 는 경고 + 마지막 섹션에 붙음(크래시 없음). 빈 패널은 숨김(기존 mount 시험 3개 유지).
  - W5-2 설정 값 저장: `scheme`·`font_scale` 을 허용값으로 저장하면 `Store.prefs` 에 들어가고, **틀린 입력**(`"neon"`, `2.0`, `"abc"`)은 저장되지 않고 토스트 1개(`Toast.message` 구독으로 확인).
  - W5-3 "모든 기록 지우기": 누르면 `Sheet.is_open()` 이고 제목·`danger` 버튼이 있음, 취소 시 `Store.progress` 불변(해시 비교), 확인 시에만 지워짐(시험용 임시 `Store.progress_path` 사용 — **실제 사용자 파일 금지**, C-4).
  - W5-4 기존 계약: `TodayView.open_settings()`, `_settings_open`, `_settings_btn`, `_scroll`, `_grid`, `_engine_ob`(PC), `go_back()` 가 설정을 닫음 — `phone_layout_test`·`shots_phone` 순회 통과. 폰 오늘의 `_grid.columns == 1`, PC 2.
  - W5-5 오늘 화면 `primary` 버튼이 언어 카드당 1개(테스트가 카드 안 `Button` 중 primary 스타일 수를 셈 — `get_theme_stylebox("normal")` 가 `accent` 채움인 것).
  - W5-6 동기화 `SyncPanel` 이 들어갈 자리가 `SettingsView` 에 있고, 임시 더미 패널로 `mount("sync", dummy)` 시 설정 화면이 겹침 0(폰 412, PC 1280/900).
  - W5-7 C-1~C-8.
- 의존: W2, W3, S7 병합(또는 S7 이 `SettingsView.mount` 를 쓰도록 §9). 병렬: W7~W11 과 병렬. **W4 보다 먼저.**

#### W12 — 연결 화면·링크 패널 (worker-hard) — **선행 조건: 폰 단독 모드 병합**
- 수정 허용: `godot\scripts\ui\connect_view.gd`(재스킨; `Flow`·신호 불변). 그 밖에는 단독 모드 작업이 정함.
- 합격: `connect_view` 시험(`remote_test`, 연결 관련 `touch_scroll_test` 시나리오) 0 failed, 터치 크기 ≥ 47.5, 다크 스크린샷 `bad=0`, `grep 'Color("#' connect_view.gd` 없음.

#### W13 — 접근성·마감 (worker-hard)
- 수정 허용: `godot\tests\phone_layout_test.gd`(터치 임계 43.5 → 47.5 상향, `--touch-min` 기본값만), 새 `godot\tests\a11y_sweep_test.gd/.tscn`(선택), 마감 중 발견한 **작은** 수정은 해당 파일 소유 작업의 파일이라 오케스트레이터에게 보고(직접 고치지 않음). 읽기 전용: 나머지.
- 내용: 전체 순회를 PC·폰 × 라이트·다크 × 글자 100/130/150% 로 돌려 겹침·터치·밝기·빈 이미지 검사, `contrast_test` 최종, `ui_perf_test --baseline`(W0 기준 대비 ≤ 1.3배 노드·리소스 수·빌드 시간), 색만 구분 목록 최종 점검, 오케스트레이터용 스크린샷 모음(대표 12장).
- 합격 조건:
  - W13-1 `phone_layout_test -- --phone` 기본 임계 47.5 로 0 failed(`TOUCH_SMALL_COUNT 0`, `LAYOUT_OVERFLOW_COUNT 0`), PC 0 failed.
  - W13-2 글자 150%: `phone_layout_test -- --phone --font-scale=1.5` `LAYOUT_OVERFLOW_COUNT 0`, PC 도 0. 130% 도 0.
  - W13-3 `contrast_test` 0 failed, `shot_check` 폰·PC × 라이트·다크 `bad=0`(총 4 폴더).
  - W13-4 `ui_perf_test --baseline=<W0> --max-ratio=1.3` 0 failed.
  - W13-5 `touch_scroll_test`(폰·PC) 0 failed, `grep -rn 'Color("#' godot/scripts` 결과가 **허용 목록**(토스트 ok/error 바탕 2곳, 테마 생성기)만.
  - W13-6 **틀린 입력**: `scheme` 와 `font_scale` 에 잘못된 값을 `prefs` 에 넣고(임시 경로) 앱을 시작해도 크래시 없이 기본값으로 뜸; `theme` 다크 파일이 없는 환경 시뮬레이션에서 라이트로 뜸.
  - W13-7 대표 스크린샷 12장 경로 목록(폰 라이트 6·폰 다크 3·PC 3)과 "확인한 것/못 한 것"(실기기 dp·다크 감지·TalkBack 은 `미검증`) 표.
  - W13-8 C-1~C-8.
- 의존: W4, W5, W7~W12 전부.

### 8.5 의존 그래프와 병렬성
```
W0 ─► W1 ─┬─► W1b ──────────────────────────────────────────────┐
          ├─► W2 ─┐                                              │
          └─► W3 ─┴─► W6 ─┬─► W7  레슨        ─┐                  │
                          ├─► W8  대화        ─┤                  │
                          ├─► W9  읽기        ─┤  (서로 병렬)      │
                          ├─► W10 복습·기록·로드맵 ─┤               │
                          └─► W11 연습 4종    ─┘                  │
   [동기화 S7 병합] ─► W5 ─► W4 ─────────────────────────────────┤
   [폰 단독 모드 병합] ─► W12 ───────────────────────────────────┤
                                                                 └─► W13
```
- 동시에 해도 되는 묶음: {W1b, W2, W3}, {W7, W8, W9, W10, W11}(+ W5, 조건 충족 시). 동시에 하면 안 되는 쌍: W4↔W5(순서), W6↔W11(순서), W13 은 맨 마지막.
- 예상 규모(추측): W1 0.5일, W2·W3 각 1일, W6 0.5일, W7~W11 각 0.5~1.5일(W9·W11 이 큼), W5 1일, W4 1.5일, W13 0.5일.

### 8.6 검토 흐름
각 작업이 끝나면 **새 컨텍스트의 `reviewer`** 가 원래 지시(이 문서의 해당 절 + 공통 조건)와 변경 파일만 보고 합격 조건을 직접 다시 실행해 O/X 를 판정한다(작성자 보고는 참고). 오케스트레이터는 검증 명령 일부와 대표 스크린샷을 직접 열어 확인한다. 메모리 방침(`review-severity-gate`): **데이터·보안·기능 파손만 릴리스를 막고**, 외관·저위험 항목은 다음 패치 목록으로 보낸다(재검토 없음).

---

## 9. 동기화(1.2)·폰 단독 모드와 겹침을 줄이는 순서

### 9.1 파일 소유 충돌 지도
| 파일 | 이 개편 | 동기화(`docs\sync_design.md`) | 폰 단독 모드(`docs\phone_standalone_design.md` 작업표 A6·B3·C3 에서 확인) |
|---|---|---|---|
| `main.gd` | W4(대폭) | S7: `add_sync()` 한 곳 추가 | A6: 배너의 "폰 단독 모드" 배지 등 |
| `views\today_view.gd` | W5(대폭: 설정 분리) | S7: `SyncPanel` 마운트 1줄 + 초기화 확인 문구 | 설정의 엔진/연결 섹션 수정 가능성 |
| `ui\connect_view.gd` | W12(연결 화면) | 없음 | A6: "PC 없이 시작" 추가 |
| `ui
emote_link_panel.gd`, `phone_link_panel.gd` | W5(재스킨만) | 없음 | (표에 없음) |
| `views	alk_view.gd` | W8 | 없음 | C3: AI 없음 상태 영역만 |
| 새 패널 `capability_panel.gd`, `model_panel.gd`, `ai_panel.gd` | (파일 겹침 없음, 재스킨은 자동) | 없음 | A6·B3·C3 가 새로 만듦 |
| `autoload\store.gd`, `study_log.gd`, `progress.gd`, `api.gd` | **읽기 전용** | S3 | (백엔드 쪽) |
| `core\pal.gd`, `ui\ui.gd`, `theme\*`, `phone_layout.gd`, `ui\*` 부품 | W1·W2·W3·W6 | 없음 | 없음 |
| `views\{lesson,talk,reading,review,roadmap,stats,practice}_view.gd`, `practice\*` | W6~W11 | 없음 | 없음 |

### 9.2 권장 순서
1. **지금 바로 병렬**: 개편 W0 → W1 → {W1b, W2, W3} → W6 → {W7~W11} 는 동기화 S1~S6(백엔드·`store.gd`·`study_log.gd`·`api.gd`·새 `scripts/sync/*`)와 폰 단독 모드 **설계**와 파일이 겹치지 않는다.
2. **S7(동기화 UI)** 는 W5 보다 먼저 병합한다. 그때 S7 작업자에게 전달할 조건(이 문서가 오케스트레이터에게 요구): ① `SyncPanel` 은 `UI.*` 헬퍼와 테마 변형만 쓰고 `Color(`·`Pal.` 직접 색·고정 픽셀 글자 크기를 쓰지 않는다(그러면 개편 후 자동으로 새 모습) ② 마운트는 `today_view.gd` 의 `_mount_link_panel` 규칙으로 **한 줄** ③ `main.gd` 는 `add_sync()` 한 곳만 ④ 토스트 문구는 `Toast.info/ok/error` 만. S7 이 W5 **뒤**가 되면 `SettingsView.mount("sync", SyncPanel.new())` 한 줄로.
3. **폰 단독 모드 UI 작업 A6(`connect_view.gd`·`main.gd`·`today_view.gd` 설정 영역)·B3·C3 가 병합된 뒤** W4(셸)·W5(오늘·설정)·W12(연결 화면)를 한다. `talk_view.gd` 는 C3 가 "AI 없음 상태 영역"만 고치므로 W8 은 C3 병합 뒤에 하거나, 겹치면 worktree 로 분리해 오케스트레이터가 합친다. 새 패널 3개(`CapabilityPanel`·`ModelPanel`·`AiPanel`)는 `UI.*` 헬퍼·테마 변형만 쓰고 직접 색·고정 글자 크기를 쓰지 않게 해 주면 개편 후 자동으로 새 모습이 되고, 마운트는 `today_view.gd` 의 `_mount_link_panel` 규칙(W5 이후 `SettingsView.mount(section, panel)`)을 쓴다. 설정 섹션 id 에 `"engine"`(처리 위치·모델·AI 연결)을 **추가**하는 것을 W5 가 허용한다(§7.2 의 6개 + `engine`). 그 전에 W4 를 먼저 해야 한다면, 단독 모드 작업자에게 `ConnChip.set_state(kind, text)` 와 `_on_backend_status` 문구 블록 규칙(§8.4 W4-7)을 알려 문구만 바꾸게 한다.
4. 새 설정 키 `scheme`, `font_scale` 은 **기기별**이므로 동기화의 공유 설정 목록(Q3 의 6개)에 **넣지 않는다**(오케스트레이터가 S3/S7 작업자에게 한 줄 전달).
5. 단독 모드가 `Platform` 에 새 판정(`is_standalone` 등)을 추가해도 이 개편은 `Platform.is_phone()` 만 쓰므로 영향 없음. 단독 모드가 폰 화면에 새 탭·카드를 더하면 `AppView` 계약과 `ListGroup`/`SectionHeader` 를 쓰도록 안내.

---

## 10. 위험 요소와 대안, 실패 시나리오

| # | 위험 | 영향 | 대안·완화 |
|---|---|---|---|
| R1 | **기능 회귀**: 화면 코드를 대량으로 만지면서 시험이 만지는 멤버를 바꿈 | 시험 대량 실패 | §3.3 grep 규칙 + C-8, W0 의 passed 수 기준선, 작업마다 reviewer |
| R2 | **터치 스크롤 깨짐**: 새 부품이 `gui_input` 으로 누름 즉시 동작하거나, 스크롤 영역 안 컨트롤이 `STOP` 을 유지 | 폰에서 카드·행 위에서 스크롤 불가(1.1.1 에서 고친 문제 재발) | 새 부품은 `UI.on_tap`/`BaseButton` 만(§3.3 규칙), `touch_scroll_test` 가 모든 작업의 C-2, `ui_prims_test` 에 행·스위치 위 드래그 시험(W2-5), 앱 바는 스크롤 **밖** 고정 높이 |
| R3 | **큰 제목 접힘 되먹임**: 높이를 줄이면 `scroll_vertical` 이 튐 | 깜빡임·점프 | 높이 고정 + 제목 교차 표시(§4.1). 실제 높이 접힘은 후속 |
| R4 | **dp 환산 오류**: 좁은 폰(360dp)에서 48px 이 42dp (**추측**) | 접근성 기준 미달 | `Ds.touch_min()`(좁을수록 키움, 최대 60), W1 진단 출력, 실기기 확인은 **미검증으로 보고**(사용자 폰) |
| R5 | **성능**: `StyleBoxFlat` 수·그림자·`SystemFont` 변형 증가, 복습 목록 수백 행 | 느린 폰에서 끊김 | 버튼 스타일 캐시(W2-2), 그림자는 토스트·떠 있는 단추만, 블러 금지, `ui_perf_test` 기준 1.3배 이내(W13-4), 헤드리스는 **그리기 비용을 못 잼**(미검증 → 실기기 확인 요청) |
| R6 | **한국어 글꼴**: Android 에 Malgun Gothic 없음 → Roboto/Noto 대체, 굵게 합성, 줄 간격·글자 폭 차이 | 줄바꿈·잘림 | 글꼴 파일 번들 안 함(§5.2), `font_scale` 130/150% 겹침 0 시험(W13-2), 글자 줄 수 제한(토스트 3줄), 실기기 확인 요청 |
| R7 | **다크 모드 즉시 전환 불가**(코드로 만든 UI 가 색을 붙잡음) | 설정 변경 후 재시작 필요 | v1 은 재시작 안내(토스트), 후속으로 뷰 재생성 방식 검토(상태 손실·`Backend.start()` 재호출 위험을 먼저 확인) |
| R8 | **시스템 다크 감지 불확실**(`is_dark_mode_supported` Android 지원 **추측**, 헤드리스 false) | 기본 `system` 이 라이트로만 동작 | 설정에서 수동 선택 제공(W5), 결과는 `UiBoot.apply` 반환값으로 로그 한 줄 |
| R9 | **동기화·단독 모드와 `main.gd`·`today_view.gd` 충돌** | 병합 지옥 | §9 순서(S7 → W5 → W4, 단독 모드 → W4·W12), 문구 블록 불변 규칙(W4-7), worktree 분리 |
| R10 | **읽기 단어 시트화**가 터치 스크롤·`on_meta_click` 과 충돌 | 단어 오선택 | 선택 과제로 두고, 시험 0 failed 아니면 후퇴(W9) |
| R11 | **미션 화면(1467줄)·읽기(1432줄)** 수정 범위가 커서 작업자가 실수 | 회귀 | 색·크기·헬퍼 교체 위주로 제한(구조 변경 금지 목록), reviewer 별도, 단위로 쪼개 보고 |
| R12 | **PC 레이아웃 단언 대량 교체**(L-06) | 시험 신뢰 하락 | W4 가 "무엇이 바뀌었나" 표를 보고서에 줄 단위로 적고 reviewer 가 새 단언이 측정 가능한지(`ok(true)` 같은 빈 단언 없음) 확인 |
| R13 | `StyleBoxFlat` 캐시를 공유하다 한 곳이 수정해 전체가 변함 | 이상한 색 | 캐시는 `UI.button/style_button` 전용, 반환 스타일을 호출부가 수정하는 곳은 복제(`duplicate()`) |
| R14 | 삼성 상표·문구 오용 | 법적 | §2.3 방침, 앱 문자열·README 에 삼성/One UI 문자열 금지(W13 에서 `grep -rniE 'samsung|one ui|삼성' godot README.md` 가 **docs 외 0건**) |

### 10.1 일부러 틀린 입력으로 확인할 실패 시나리오 (검사기 자체의 신뢰 확인)
통과만 확인한 검사기는 믿지 않는다. 각 항목은 **의도한 FAIL/폴백이 실제로 나오는지** 본다.
| # | 대상 | 틀린 입력 | 기대 |
|---|---|---|---|
| F1 | `contrast_test` | `#777777/#FFFFFF`, 기존 `JA/JA_SOFT`(4.27) | FAIL 로 보고(`selfcheck FAIL-as-expected`) |
| F2 | `contrast_test` | 다크 토큰에서 `MUTED` 를 `#5A6578` 로 바꾼 사본 | 해당 쌍 FAIL(임시 사본으로만, 파일은 되돌림) |
| F3 | `shot_check` | 단색 PNG, 100×100 PNG, 라이트 폴더를 `--scheme=dark` 로 | 각각 `bad ≥ 1`, 종료 코드 1 |
| F4 | `ui_perf_test` | 기준값을 1/10 로 줄인 파일 | FAIL |
| F5 | `phone_layout_test` 자체 점검 | 20px 버튼·30px 입력칸·600px 폭 컨트롤(기존 `_selfcheck`) + **새**: 47px 높이 버튼 | 47px 가 `--touch-min=47.5` 에서 `TOUCH_SMALL` 로 잡힘 |
| F6 | `UiBoot.apply` | `scheme="purple"`, `font_scale="abc"`/`9.0`, 다크 테마 파일 없음 | 라이트·1.0/1.5·라이트, 크래시 0, 경고 로그 1줄 |
| F7 | `AppBar.collapse_t` | `NAN`, 음수, `header_h=0` | §6.3 규칙대로 0/1, 예외 없음 |
| F8 | `Sheet` | 빠른 두 번 `open`, 버튼 0개, 본문 `null`, 열린 채 `handle_back` | 스택 2·크래시 0·시트만 닫힘 |
| F9 | `ToastHost` | 500자·줄바꿈 20개 | 3줄 이하 + 말줄임 |
| F10 | `ListGroup` | 빈 `main`, `trailing=null`, `on_tap` 비어 있음 | 행 미생성/탭 없음/경고, 크래시 0 |
| F11 | 터치 | `ListGroup` 행·스위치 위에서 시작한 300px 드래그 | `on_tap`·`toggled` 불리지 않고 페이지 ≥ 200px 이동(탭은 불림) |
| F12 | 설정 저장 | `scheme="neon"`, `font_scale=2.0` | 저장 안 됨 + 토스트 1개 |

---

## 11. 오케스트레이터가 정할 사항

| # | 질문 | 선택지 | 추천 |
|---|---|---|---|
| Q1 | **강조색(`PRIMARY`)** | A 지금 파랑 #2C56C9 유지 / B 밝은 파랑 #0A6BD6 / C 청록 #0F766E | W1 에서 A·B 스크린샷을 둘 다 만들어 보고 확정. 미리 정한다면 **B**(One UI 풍 밝은 파랑이고 흰 글자 5.14:1 통과, 값 두 줄이라 되돌리기 쉬움). 영어=파랑/일본어=빨강 언어색을 흐리고 싶지 않으면 A |
| Q2 | **폰 하단 탭 구성** | A) 오늘·레슨·대화·복습 + 더보기(연습·읽기·기록·로드맵·설정), 5칸 / B) 지금처럼 5칸+더보기=6칸 | **A** — One UI 는 5개 이하(4개 미만 권장), 일상 반복(오늘→레슨→대화→복습)을 아래에, 나머지는 더보기 시트. 오늘 화면에 "연습·읽기" 바로가기 카드 1줄 추가는 W5 판단 |
| Q3 | **PC 내비** | A) 왼쪽 사이드 내비(폭 224) / B) 지금처럼 위 탭(스타일만 변경) | **A** — 탭 8개+설정이 "더보기"로 숨는 문제 해결, 큰 화면 원칙(메뉴 상시 표시)에 맞음. 단 PC 시험 단언 교체(L-06)가 따라옴(W4) |
| Q4 | **다크 모드 적용 시점** | A) v1 은 앱을 다시 열면 적용(안정) / B) 즉시 전환(모든 뷰 재생성, 상태 손실·`Backend.start()` 위험) | **A**, 즉시 전환은 1.3 이후 |

그 밖에 확인이 필요한 것(사용자 선택 아님): S7 조건 전달(§9.2-2), `scheme`·`font_scale` 을 동기화 공유 설정에서 제외(§9.2-4), 카드 PC 헤어라인 유지 여부(W2 스크린샷 후), 폰 실기기에서 dp·다크 감지·글꼴·TalkBack 확인(**미검증**, W13 보고서에 표로).
