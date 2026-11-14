# v1.7.0 설계: 일본어 받아쓰기·약한 소리 · 일본어 미션 8개 · 한 줄 일기

- 작성: designer (설계만. 코드·설정 수정 없음) / 대상: Godot 4.6.3 앱 `godot\` (PC 1280x800, 안드로이드 412x915)와 파이썬 백엔드 `backend\`
- 기준 커밋: `682e72d` (main. v1.6.0 공개 뒤 v1.6.1 작업 `app_wt\v161_u1`, `v161_u2` 일부가 이미 병합됨). 작업 시작 때 main 최신으로 다시 확인한다(§6.2 O-1).
- 상태: 오케스트레이터 확정 전 초안. 사용자에게 물을 것은 §6.1.
- 표기: **(추측)** = 코드·실행으로 확인하지 못한 가정. 표기 없는 것은 코드를 읽어서 확인한 사실이다. **(새)** = 이번에 새로 만드는 파일·함수·경로. 경로는 저장소 루트 `D:\Ai\언어\app` 기준.
- 요청한 필수 항목과 이 문서의 절: ① 화면 흐름·진입 위치 = §1 ② 데이터·API 계약·호환·동기화 = §2 ③ 파일별 작업 분할·소유권·병렬 순서 = §3 ④ 작업별 O/X 합격 조건·금지 조건 = §4 ⑤ 위험·실패 시나리오 = §5 ⑥ 사용자 질문·오케스트레이터 결정 = §6. 목표·범위·읽은 것·핵심 결정은 §0.

## 0. 목표·범위·사실·핵심 결정

### 0.1 읽은 것 / 확인하지 못한 것
- 읽은 것: `README.md`, `ROADMAP.md`, `WORKLOG.md` 끝부분, `REVIEW.md`, `docs\v160_fun_design.md`(형식·§6 작업 분할·합격 조건), `docs\phone_standalone_design.md`(§0, §3.3~3.4, §12), `docs\english_v11_design.md`(일본어 범위 줄), `API.md`(/fix, /practice/*, /missions*), 앱 코드 `practice\dictation_screen.gd`·`dictation_diff.gd`·`phoneme_screen.gd`·`mission_screen.gd`(일본어·영어 분기 줄)·`speak_drill.gd`(요청·훅), `local\local_practice.gd`·`local_missions.gd`, `core\mission_logic.gd`·`text_sim.gd`·`song_study.gd`(`dictation_score`)·`phoneme_stats.gd`·`study_log.gd`(phon·missions·add_score·add_mission)·`fix_cards.gd`·`badge_defs.gd`·`badge_engine.gd`·`kana_voice.gd`·`progress.gd`(`write_text_atomic`, `REAL_FILE_NAMES`), `autoload\route.gd`·`local_api.gd`·`store.gd`(`add_review`, `apply_test_guard`), `views\practice_view.gd`·`today_view.gd`·`stats_view.gd`, `ui\fun_parts.gd`·`reading_line.gd`·`sheet.gd`, 백엔드 `practice.py`·`missions.py`·`server.py`(`score_ja`, `ja_tips`, `correct_learner`, `_llm_correct`, `llm_json`, `/score`, `/fix`)·`grammar.py`·`lan.py`(`ALLOW`)·`llm_cache.py`·`llm_opencode.py`, 콘텐츠 `backend\content\missions.json`·`phoneme_drills.json`, 팩 `godot\data\pack\manifest.json`·`practice_ja.json`, 빌더 `backend\tools\build_phone_pack.py`·`make_mission_golden.py`, 기존 시험의 일본어 관련 줄.
- 실행한 것: 읽기 전용 파이썬으로 `godot\data\pack\practice_ja.json`(문장 1,848개)에서 받아쓰기 후보를 세었다(글자 6~24자, 아라비아 숫자·영문 없음, 읽기가 히라가나만: **1,693개**. 길이 때문에 빠진 것 154, 읽기 문제 1). Godot·파이썬 시험은 하나도 실행하지 않았다. 그래서 기준선(현재 통과 개수)은 모른다: 각 작업자가 작업 전에 잰다(§4.1 C-0).
- 확인하지 못한 것(전부 사용자 실기·작업자 실측 몫): 폰 시스템 음성이 일본어 문장의 한자를 `reading` 과 같게 읽는지, 폰 키보드로 가나·한자 입력이 되는지, 일본어 TTS가 장음·촉음 짝을 실제로 구별해 읽는지, Whisper(일본어)가 장음·촉음 오류를 얼마나 잡는지, AI 교정 한 문장의 지연, LanguageTool 서버(JVM)가 입력 문장을 자기 로그에 남기는지.

### 0.2 목표와 범위
- **A. 일본어 받아쓰기·약한 소리**: ① 받아쓰기에서 일본어를 지원(기존 화면 확장, 가나·한자 표기 차이를 읽기 기준으로 채점) ② 약한 소리에 한국인이 자주 틀리는 일본어 소리 6개(장음, 촉음, 청탁, つ/す, ざ/じゃ, 요음) 연습 + 기록. 폰 단독에서도 문장·채점·듣고 고르기가 된다.
- **B. 일본어 미션 8개**: 편의점·라멘집·길 묻기·호텔 체크인·역 매표소·병원 접수·쇼핑 계산·자기소개. 영어 8개와 같은 구조·같은 라우트. 목표는 규칙으로 바로 체크, 놓친 것만 AI(학습자 문장의 증거 인용이 있을 때만 인정). 별 3 배지가 언어를 어떻게 세는지 정한다.
- **C. 한 줄 일기**: 1~3문장을 쓰거나 말하면 AI가 고쳐 주고(원문·고친 문장·짧은 이유), 고친 문장은 복습 카드로 자동 추가. 원문은 서버 로그·캐시에 남기지 않는다.
- **하지 않을 것**
  - 일본어 음소 모델·고저 악센트·모음/촉음 길이 실측·억양 그래프(`features.JA_ENABLED` 가 꺼져 있고 이번에도 켜지 않는다), 폰 단독 음성 인식(`local_stt` 없음, 2단계 미구현).
  - 새 하단 탭(폰 5개 그대로), 새 autoload(`project.godot` 변경 0), 안드로이드 권한 추가(`export_presets.cfg` 변경 0), 새 백엔드 라우트·`lan.py` `ALLOW` 변경, 동기화 스키마(`SyncDoc` 등) 변경.
  - 일본어 받아쓰기의 가나 조각 입력(키보드 없는 폰용), 일기의 한국어→외국어 번역 기능(교정만), 일기 질문 추천, 일기 내용의 동기화·내보내기, 일기 기반 주간 리포트.
  - 버전 올리기·릴리스(오케스트레이터), 기존 영어 동작 변경.

### 0.3 지금 구조에서 알게 된 사실 (설계의 근거)
| # | 사실 | 위치 |
|---|---|---|
| F1 | 받아쓰기는 영어 전용: 화면은 `lang != "en"` 이면 "받아쓰기는 영어만 지원해요" 화면, 서버는 일본어+dictation 을 400, 폰은 `DICT_JA_MSG` 로 400. 채점 `DictationDiff.diff` 는 영어 단어 LCS | `practice\dictation_screen.gd` `open`, `backend\practice.py` `get_sentences`, `local\local_practice.gd` `_sentences` |
| F2 | 일본어 문장은 이미 받아쓰기에 쓸 재료가 다 있다: 쉐도잉용 응답이 `text`(한자 섞임)·`reading`(히라가나, 조사 は는 は)·`pron`(가타카나)·`ko` 를 준다. 폰 팩 `practice_ja.json` 은 1,848문장(받아쓰기 후보 1,693) | `practice.py` `_pick`, `godot\data\pack\practice_ja.json` |
| F3 | 일본어 글자 비교 선례: 노래 받아쓰기 `SongStudy.dictation_score("ja", …)` 는 `TextSim.similarity(said, text, reading, "ja")`(표기와 읽기 중 높은 쪽, 글자 단위 LCS). 가타카나/히라가나 접기·혼합 표기는 못 한다. 노래 화면과 `MemoGrade` 가 쓰므로 바꾸지 않는다 | `core\song_study.gd`, `core\text_sim.gd` |
| F4 | 일본어 발음 채점은 Whisper 단어 → 모라 정렬(`score_ja`)까지다. 팁은 장음·촉음·청탁·つ 를 문장으로 알려 준다(`ja_tips`, `ja_tip_for_pair`). 음소·악센트는 꺼져 있다(`add_phonemes` 가 일본어면 바로 return, `JA_ENABLED=False`). 인식기가 문맥으로 고쳐 들으면 "맞음"으로 나오므로 과소 검출이 있다 **(추측: 정도는 실측 필요)**. 폰 단독은 채점 엔진이 없다(`local_stt` 없음 → `needs_pc`, 자가 평가) | `backend\server.py`, `features.py`, `autoload\route.gd`, `ui\self_rate_panel.gd` |
| F5 | 약한 소리 통계 `studylog.phon` 은 `{"en":{}, "ja":{}}` 로 이미 두 언어 자리가 있고 동기화된다. 그런데 기록은 `/score` 의 `units[].ph[]`(영어 음소)만 읽어서 일본어 통계는 항상 비어 있다. 모든 채점 결과는 `StudyLog.add_score` 한 길로 들어온다(쉐도잉·레슨·복습·드릴) | `core\phoneme_stats.gd`, `core\study_log.gd` `add_score_any` |
| F6 | 미션 데이터는 `backend\content\missions.json`(영어 8개, 항목마다 `lang`) 하나이고 폰 팩 `godot\data\pack\missions.json` 은 바이트 복사본(`manifest.json` 해시 검증, `build_phone_pack.py --only content`). 서버·폰·앱 세 곳이 영어 전용이다: `missions.list_missions`(일본어면 `unsupported`), `_need_mission`(일본어 400), `normalize`(`[a-z0-9' ]` 외는 공백이라 일본어가 통째로 사라짐), 판정 프롬프트 "English learner"; `LocalMissions` 도 같은 제약; `MissionScreen._load_list` 는 일본어면 `JA_NOTE`; `MissionLogic.apply_judge`·`script_passes` 는 `"en"` 고정 | `backend\missions.py`, `local\local_missions.gd`, `practice\mission_screen.gd`, `core\mission_logic.gd` |
| F7 | 미션 기록 `studylog.missions` 의 키는 미션 id 하나(언어 없음)이고 동기화된다. 별 3 배지: `mission_star3` 는 모든 id 에서 세고, `mission_all_star3` 는 `BadgeRules.MISSION_IDS`(영어 8개)만 센다. 시험 `badge_rules_test` 가 `MISSION_IDS == StatsView.MISSION_ORDER` 를 확인한다 | `core\badge_engine.gd` `snapshot`, `core\badge_rules.gd`, `views\stats_view.gd` |
| F8 | 대화 교정 `POST /fix` 는 일본어도 받는다(`correct_learner`: LanguageTool → AI 다듬기; 일본어는 LT 규칙이 적어 대부분 AI). 그런데 `llm_json(..., cache_key_kind="fix")` 가 결과를 `backend\cache\llm_cache.sqlite` 에 저장하고, `log.info("AI polished LanguageTool fix %r -> %r")` 와 `grammar.correct` 의 `_info("… fixed sentence %r …")` 가 문장을 서버 로그에 쓴다 → 일기 원문이 디스크에 남는다. `/fix` 는 이미 `lan.py` `ALLOW` 에 있어 폰이 PC를 통해 쓸 수 있다(폰 단독은 `needs_pc`) | `backend\server.py`, `llm_cache.py`, `grammar.py`, `lan.py`, `autoload\route.gd` |
| F9 | 대화 후 복습 카드 `FixCards.add` 는 설정 `auto_fix_cards`·대화당 8개·`Store.add_review` 중복 제거를 쓰지만, 카드 `note` 에 원문을 넣을 수 있다(`"내가 말한 문장: " + text`) → 일기에는 그대로 못 쓴다 | `core\fix_cards.gd` |
| F10 | 연습 허브 카드는 6개이고 시험 4곳이 개수·순서를 단언한다(`practice_test` 289, `ui_practice_widgets_test` 456·503, `fun_wiring_test` 374). 일본어 허브에서 받아쓰기·약한 소리 카드는 꺼져 있고(`en_only`) 시험이 그 글을 확인한다 | `views\practice_view.gd` `_hub_items` |
| F11 | 사용자 파일은 `Progress.write_text_atomic`(임시 파일 → 이름 바꾸기)로 쓰고, 시험 보호(`Progress.REAL_FILE_NAMES`)가 실제 이름의 파일에 쓰는 시험을 막는다. 안드로이드 자동 백업은 꺼져 있다(`user_data_backup/allow=false`) | `core\progress.gd`, `autoload\store.gd`, `export_presets.cfg` |
| F12 | 연습 화면 시험의 서버 없이 가로채기: `SpeakDrill.api_hook`(요청), `SpeakDrill.score_hook`, 소리 `Tts.fetch_hook`. 실제 버튼 누름은 `button.pressed.emit()` 패턴(`kana_course_screen_test`) | `practice\speak_drill.gd`, `tests\kana_course_screen_test.gd` |

### 0.4 핵심 결정 요약
| # | 결정 | 이유 |
|---|---|---|
| D1 | **일본어 받아쓰기 = 기존 `DictationScreen` 에 언어 분기**(새 화면 아님). 문장은 기존 `GET /practice/sentences?lang=ja&mode=dictation`(서버·폰 둘 다 허용으로 바꿈), 새 경로 없음 | 허브 계약·XP·복습 카드 흐름 재사용, `lan.py` 변경 0 |
| D2 | **채점 = 새 순수 클래스 `DictationDiffJa`**: 비교 단위는 **읽기(히라가나) 글자**. 가나만 써도(한자를 안 써도) 소리가 맞으면 정답, 한자까지 맞으면 "표기까지 맞음" 표시. 가타카나는 히라가나로 접어 비교, 공백·문장부호 무시, 혼합 표기(일부만 한자)는 정답 문장의 한자 덩어리별 읽기로 풀어 비교. 기존 `TextSim`·`DictationDiff` 는 수정하지 않고, 가나만·표기만 입력에서 기존 `TextSim.similarity` 점수보다 낮지 않다는 시험으로 묶는다 | F3, 한자 입력 부담을 없애고 철자(조사 は/を/へ, ー, っ)를 정확히 시험 |
| D3 | **일본어 약한 소리 = 새 화면 `JaSoundScreen` + 새 데이터 `godot\data\ja_sounds.json`**(팩 밖, 서버 불필요: `speed_words.json` 선례). 영어 `PhonemeScreen`·`/practice/phoneme*` 는 그대로. 허브가 언어로 화면을 고른다 | 팩·매니페스트·서버 라우트 변경을 피한다 |
| D4 | **채점 근거**: 듣고 고르기 = 어느 쪽 낱말을 재생했는가(결정적), 따라 말하기 = PC `/score` 의 모라 정렬 결과(**추정**: 인식된 글자와의 비교일 뿐 소리 분석이 아님), 통계 = `phon.ja` 에 카테고리 `j_long`, `j_sokuon`, `j_voice`, `j_tsu`, `j_za`, `j_youon` 기록. 기록은 `StudyLog.add_score_any` 에서 일본어 결과에 `ph` 를 붙여(`JaSounds.annotate`) 기존 `PhonemeStats` 를 그대로 쓴다. 폰 단독은 듣고 고르기와 자가 평가만(통계는 듣고 고르기 결과) | F4, F5 |
| D5 | **일본어 미션 8개 = 같은 `missions.json`·같은 라우트**, id 접두어 `ja_`(기록이 id 만 키라서 충돌 방지). 서버·폰이 `lang` 으로 목록·체크·판정을 일본어에도 허용. 일본어 정규화 `norm_ja`(NFKC → 소문자 → 가타카나를 히라가나로 → 한자·가나·ー·영숫자만 남기고 공백·부호 삭제)를 파이썬과 GDScript가 똑같이 구현하고 황금 파일로 맞춘다. 읽기 필드(`*_rd`, `*_pr`)를 콘텐츠에 싣는다 | F6, 폰은 OpenJTalk 이 없다 |
| D6 | **별 3 배지**: `mission_star3` 는 그대로(모든 미션). `mission_all_star3` 는 "한 언어의 미션 8개 모두"(영어 8 / 일본어 8 중 큰 쪽). BadgeDefs 23개의 id·이름·측정 이름·목표는 그대로이고 설명 글만 바꾼다 → B1 시험 표 불변. `BadgeRules.MISSION_IDS` 는 영어 그대로, 일본어용 `MISSION_IDS_JA`(새)를 더하고 `StatsView.MISSION_ORDER_JA`(새)와 같음을 시험으로 대조 | 사용자 요구 "언어를 어떻게 셀지", 23개를 건드리지 않는 최소 변경 |
| D7 | **일기 진입 = 연습 허브 7번째 카드 `diary` + 홈 "이번 주" 카드의 4번째 버튼 [일기]**. 하단 탭·새 탭 없음 | `pending` 계약 재사용 |
| D8 | **일기 교정 = 기존 `POST /fix` 에 선택 필드 `private`(새)**: `true` 이면 서버가 결과를 캐시에 저장하지 않고 문장을 로그에 쓰지 않으며, 일본어면 응답에 `reading`·`pron` 을 더한다. 새 라우트 없음. 앱은 문장별로 최대 3번 호출 | F8, 기존 교정(LT+AI) 재사용 |
| D9 | **일기 저장 = 새 파일 `user://diary.json`, 이 기기 전용, 동기화 안 함**. 폰 단독·AI 없음이면 "저장만"(상태 `saved`) 해 두고 나중에 [고치기] | 개인 정보, 동기화 스키마 변경 회피 |
| D10 | **복습 카드 = 고친 문장만**(원문은 카드에 넣지 않음). `Store.add_review` 중복 제거 + 일기당 3개 + 하루 5개 상한 + 기존 설정 `auto_fix_cards` 존중. `FixCards.add` 는 note 에 원문이 들어갈 수 있어 쓰지 않는다 | F9 |
| D11 | **배지**: 일기 배지 2개(`diary_first`, `diary_7`)는 선택 사항(사용자 질문 Q6). 승인되면 작업 S 가 23→25 로 바꾸고 시험 표를 명시 숫자로 고친다(파생값으로 느슨하게 만들지 않음) | 사용자 요청 |
| D12 | **공유 파일은 한 작업에만**: `study_log.gd`=A2, `progress.gd`=C1, `server.py`·`grammar.py`=C2, `practice_view.gd`·`today_view.gd`·`fun_parts.gd`·허브·홈 시험=W, `missions.py`=B1 (§3.3) | 병렬 충돌 방지 |

---

## 1. 화면 흐름과 진입 위치

### 1.1 진입 지도 (폰 하단 탭 5개 그대로)
```
연습 허브(언어 스위치 영어/일본어) ── 카드 7개 (순서 고정)
 ├ 롤플레이 미션   → 일본어 탭이면 일본어 미션 8개 목록(새)
 ├ 쉐도잉
 ├ 받아쓰기        → 일본어 탭에서도 켜짐(새), 소리가 없으면 안내
 ├ 약한 소리       → 영어: PhonemeScreen / 일본어: JaSoundScreen(새)
 ├ 가나 기초 코스(일본어 탭만)
 ├ 60초 스피드 퀴즈
 └ 한 줄 일기(새, 영어·일본어 둘 다)
홈 "이번 주" 카드 ── [60초 퀴즈] [가나 코스(일본어)] [일기(새)] [배지 n/23]
기록 화면 ── 일본어 탭: 미션 별점(일본어 8개), 약한 소리(일본어 카테고리) 카드(새)
```
- 홈 [일기] → `PracticeView.pending = {"kind": "diary"}` + `Store.navigate.emit("practice", lang)`(기존 계약).
- 기록 화면의 약한 소리 [집중 연습] → `pending = {"kind": "phoneme", "p": "j_long"}` → 허브가 일본어면 `JaSoundScreen` 으로 연다.
- 안드로이드 뒤로 가기: 각 새 화면은 `go_back() -> bool` 로 한 단계씩(입력 중 → 목록 → 허브).

### 1.2 일본어 받아쓰기 (`DictationScreen`, 일본어 분기)
```
┌─────────────────────────────────────┐
│ ← 연습         받아쓰기        1 / 6 │ 일본어는 한 번에 6문장(영어는 8)
│ ┌─ 들리는 대로 일본어로 써 보세요 ──┐ │
│ │ [▶ 듣기] [천천히]   들은 횟수 1     │ │
│ │ 글자 수 14자 (가나 기준)           │ │
│ │ [첫 글자 힌트] [모르겠어요]         │ │ 힌트 = 읽기의 앞 2글자
│ │ 일본어 키보드로 써요. 가나만 써도    │ │
│ │ 소리가 맞으면 정답이에요.           │ │
│ └────────────────────────────────┘ │
│ [ 들은 문장을 써 보세요      ][확인] │ 아래 고정 입력 줄(영어와 같은 구조)
└─────────────────────────────────────┘
채점 뒤(같은 화면 위쪽에 결과 카드):
 92점  ✓ 통과!   (표기까지 맞음 / 읽기가 맞아요(한자를 가나로 씀) / 일부만 한자)
 내가 쓴 것: 彼らはぱいろっとです
 [✓ 彼らは] [✕ パイロット · 철자 틀림 (ぱいろと)] [✓ です]   ← 칩: 맞음 ✓ / 틀림 ✕ + 이유 글
 정답: 彼らはパイロットです。   ▶   읽기: かれらはぱいろっとです。 (한글 소리 줄은 ReadingLine)
 ko 번역 · 출처(Tatoeba)
[다음 ▶]
```
- 칩의 기호는 글자(✓ ✕)가 아니라 이유 글을 함께 쓴다(영어 화면과 같은 규칙: 색만으로 구분하지 않음). 이유 종류: `빠짐`, `철자 틀림`, `한자가 달라요(같은 소리의 다른 한자일 수 있어요)`, `정답에 없는 글자`.
- 소리가 낼 수 없으면(폰에 일본어 음성이 없음 / PC 연결 없음: `KanaVoice.available()` 가 false) 문장을 불러오기 전에 안내 화면 `stage = "no_voice"`: "받아쓰기는 소리가 있어야 해요. 폰 설정에서 일본어 음성 데이터를 내려받거나 PC에 연결해 주세요." + [연습으로].
- 끝나면 85점 미만 문장(최대 5개)을 복습 카드로(영어와 같음): `{"lang":"ja","target":<text>,"reading":<reading>,"ko":<ko>,"note":"받아쓰기"}`.

### 1.3 일본어 약한 소리 (`JaSoundScreen`, 새)
```
목록                                   소리 하나(설명)                         듣고 고르기(10문항)
┌──────────────────────────┐   ┌───────────────────────────┐   ┌─────────────────────────┐
│ 약한 소리 연습 (일본어)   │   │ 장음 (ー)                  │   │ 3 / 10   [▶ 다시 듣기]  │
│ 지금 약한 소리(최근 30회) │   │ 길게 늘이는 소리예요. …    │   │ 어느 쪽이 들렸을까요?   │
│  [장음 틀림 40%] [촉음 …] │   │ 비슷한 낱말                │   │ ┌─────────┬─────────┐   │
│ 소리 직접 고르기          │   │  おばさん ▶ 이모·고모       │   │ │おばさん │おばあさん│   │ 보기 2개, 높이 ≥ 64
│  [장음][촉음][청탁][つ/す] │   │  おばあさん ▶ 할머니        │   │ │ 이모    │ 할머니   │   │
│  [ざ/じゃ][요음]          │   │ [듣고 고르기 시작]          │   │ └─────────┴─────────┘   │
│ 안내: 인식된 글자와 비교한 │   │ [따라 말하기 5문항]         │   │ (고른 뒤) ✓ 정답 / ✕ 오답 │
│ 추정이에요.               │   └───────────────────────────┘   │  둘의 읽기·뜻, [다음 ▶]    │
└──────────────────────────┘                                     └─────────────────────────┘
```
- 따라 말하기 5문항: 낱말·구절을 `SpeakDrill`(영어 `PhonemeScreen` 과 같은 부품)로 녹음·채점. PC 연결이 있으면 `/score`(모라 단위 결과를 `JaSounds` 가 이 소리 칸으로 판정), 없으면 자가 평가(녹음 듣고 "잘했어요"). 자가 평가는 통계에 넣지 않는다.
- 소리를 낼 수 없으면(`KanaVoice.available()` false) 듣고 고르기·소리 재생 버튼을 끄고 "일본어 음성이 있어야 해요" 한 줄 + 설명·낱말 쌍 읽기만 보인다.
- 끝: 정답률, 틀린 쌍(두 낱말과 뜻), [틀린 낱말 복습 카드로 추가](낱말 `target`, `reading`, `ko`), [같은 소리 다시]/[소리 목록으로]. 10문항 끝나면 XP 10(영어 드릴과 같음), `StudyLog.add_event("ja", "drill", 1)`.

### 1.4 일본어 미션 (`MissionScreen`, 같은 화면)
- 목록: 일본어 탭이면 `GET /missions?lang=ja` 결과 8개(기존 영어 카드와 같은 모양: 제목, 상황, 목표 수, 별). 단계(`min_stage`)에 맞는 것을 앞에.
- 대화: 상대 말풍선 아래에 **히라가나 읽기 + 한글 소리 줄**(`ReadingLine`, 설정 `show_reading`·`show_hangul_ja` 존중). AI 모드는 `/chat` 응답의 `reading`·`pron`, 대본 모드는 콘텐츠의 `ai_rd`·`ai_pr`. 내 힌트(`hint_en`=일본어 예시 문장)도 `hint_rd` 를 아래에 보인다. 소리·음성 입력은 `lang` 그대로(`Tts.speak(text, "ja")`, `/stt` `lang:"ja"` — PC 연결 때만).
- 목표 체크: 한 문장마다 `/missions/check`(폰은 폰 안에서) → 규칙으로 닿은 목표를 체크. 대화가 끝나면 놓친 목표만 `/missions/judge`(AI): **증거 인용이 학습자 문장에 있을 때만 인정**(앱도 한 번 더 확인).
- AI가 없으면 대본 모드(`script`)로 진행: 상대 대사는 데이터, 내 답은 규칙 + 글자 유사도(일본어는 `TextSim` `"ja"`).
- 결과·별·XP·기록은 영어와 같다(`StudyLog.add_mission(lang, id, …)`).

### 1.5 한 줄 일기 (`DiaryScreen`, 새, 허브 카드 `diary`)
```
쓰기 화면(stage "home")                         고치는 중 → 결과(stage "result")
┌──────────────────────────────────┐     ┌──────────────────────────────────┐
│ ← 연습          한 줄 일기         │     │ 1 / 3 문장 고치는 중…   [취소]     │
│ 오늘 있었던 일을 1~3문장으로 써 보세요│     │ ───────────────────────────      │
│ ┌──────────────────────────────┐ │     │ 결과                              │
│ │ (여러 줄 입력)                 │ │     │ 쓴 것   きのう ともだちと えいがをみた。│
│ └──────────────────────────────┘ │     │ 고침    昨日、友達と映画を見ました。 ▶ │
│ 문장 2/3 · 87/300자   [말해서 쓰기] │     │ 이유    과거형과 정중체로 맞췄어요.    │
│ [고쳐 보기]   [저장만 하기]         │     │ ✓ 복습 카드에 넣었어요 (2개)        │
│ 안내: AI 연결·PC 연결이 필요해요    │     │ 읽기    きのう、ともだちと…(ReadingLine)│
│ ─ 최근 일기 ─                      │     │ [다시 쓰기] [일기 목록]             │
│ 11월 14일 (금) 고침 완료            │     └──────────────────────────────────┘
│ 11월 13일 (목) 고치기 대기  [고치기]│
└──────────────────────────────────┘
```
- **[고쳐 보기]**: 처음에는 동의 시트(`Sheet.confirm`, 설정 `diary_consent`): "쓴 문장이 AI 서비스로 보내져 고쳐져요. 이 PC의 로그·캐시에는 남기지 않고 일기는 이 기기에만 저장돼요." [동의하고 고치기] [나중에]. 동의 뒤 `/fix`(`private:true`)를 문장마다 순서대로 부른다. 문장 하나가 실패하면(한도·연결) 그 일기는 `saved` 로 두고 이유를 보여 준다(부분 저장 없음).
- **[저장만 하기]**: AI·PC가 없을 때 기본 버튼(그때는 [고쳐 보기]가 꺼지고 이유 한 줄). 저장된 `saved` 일기는 목록에서 [고치기]로 나중에 고친다(대기 N개 표시).
- **[말해서 쓰기]**: PC 연결이 있을 때만(`RecorderWidget` → `/stt`, 미션 화면과 같은 방식). 폰 단독이면 숨기고 "음성 입력은 PC에 연결했을 때만 돼요" 한 줄.
- 입력 검사(`DiaryLogic.check_input`): 비어 있음, 300자 초과, 4문장 이상, 한 문장 120자 초과, 목표 언어 글자가 하나도 없음(일본어: 가나·한자가 없음, 영어: 알파벳이 없음)은 각각 한국어 안내로 거절한다.
- 결과 카드(문장마다): 원문 / 고친 문장(▶ 듣기) / 이유(한 줄) / 일본어면 읽기. 고칠 것이 없으면 "잘 썼어요. 고칠 곳이 없어요" 한 줄(카드 없음).
- 목록: 현재 허브 언어의 최근 일기(날짜는 "11월 14일 (금)" 꼴). 항목 [보기]·[지우기](확인), 맨 아래 [일기 모두 지우기](확인 시트). 개수·날짜는 읽을 수 있는 단위로만 보인다(unix·ms 값을 화면에 내지 않는다).

### 1.6 폰 단독(PC 없이)에서 어디까지 되는가
| 기능 | 폰 단독 | PC 연결 | 조건·비고 |
|---|---|---|---|
| 일본어 받아쓰기 | **됨**(문장: 팩 1,693개 중에서, 채점: 폰 안 규칙) | 됨(PC의 더 많은 Tatoeba 문장) | 폰에 일본어 음성 필수, 일본어 키보드 필요 **(실기 미검증)** |
| 약한 소리: 설명·낱말 쌍 | 됨(정적 데이터) | 됨 | |
| 약한 소리: 듣고 고르기 | **됨** | 됨 | 소리 필수. 통계 기록됨 |
| 약한 소리: 따라 말하기 | 자가 평가만(통계 제외) | `/score` 모라 정렬로 판정(추정) | 음소·악센트·길이는 안 함 |
| 일본어 미션 목록·목표 체크·대본 모드 | **됨**(팩 + 폰 안 규칙) | 됨 | 팩이 있어야 함(`pack_missing`이면 안내) |
| 일본어 미션 AI 대화·AI 판정 | 안 됨(`needs_pc`) → 대본 모드 | 됨 | 기존 영어 미션과 같은 제약 |
| 일기 쓰기·저장·목록·지우기 | **됨** | 됨 | |
| 일기 고치기(AI) | 안 됨 → "저장만", 나중에 고치기 | 됨 | PC + AI 연결(`Route.caps()["items"]["fix"]["use"] == "pc"` 이고 `Backend.health["llm"]`) |
| 일기 음성 입력 | 안 됨 | 됨 | `/stt` |

---

## 2. 데이터·API 계약

### 2.1 일본어 받아쓰기

**`GET /practice/sentences?lang=ja&mode=dictation&stage&month&week&n&seed&exclude`** (기존 경로, 서버 `practice.py`·폰 `LocalPractice` 둘 다)
- 응답 모양은 기존과 같다(`sentences[]` = `{id, text, ko, reading, pron, words, url}`, `attribution`). 새 필드 없음. `words` 는 일본어에서 글자 수(기존).
- 일본어 받아쓰기 후보 규칙 `ja_dictation_ok(text)`(**새**, 서버와 폰이 같은 규칙. 폰은 `LocalPractice.ja_dictation_ok`): 문장부호를 뺀 글자 수 6~24, 아라비아 숫자(전각 포함)·알파벳 없음, 읽기가 비어 있지 않고 히라가나뿐(기존 `ja_reading_ok`). 이 규칙에 더해 기존 `_eligible` 의 단계별 길이 한도가 그대로 적용된다.
- 서버: `get_sentences` 가 일본어+dictation 을 허용(400 "받아쓰기는 영어만 지원해요" 제거). 폰: `DICT_JA_MSG` 분기 제거.
- 한 번에 가져오는 개수 `SESSION_N_JA = 6`(**새** 상수, 영어 `SESSION_N = 8` 유지).

**`DictationDiffJa`** (**새**, `godot\scripts\practice\dictation_diff_ja.gd`, 순수 함수. 노드·저장소·네트워크 없음)
```gdscript
class_name DictationDiffJa
const MAX_LEN := 300            # 입력이 이보다 길면 자른다
const PASS_SCORE := 85          # 영어 DictationScreen.PASS_SCORE 와 같은 통과선
const HARD_ERRORS := 3          # 틀린 글자 수가 이 이상이면 점수를 HARD_CAP 이하로 (초기값 — 시험으로 조정, 조정하면 근거 보고)
const HARD_CAP := 84
static func fold(s: String) -> String          # §아래 정규화(읽기 비교용): 가타카나→히라가나, 전각/반각, 공백·문장부호 삭제, ー 는 유지
static func segments(text: String, reading: String) -> Array
    # [{"s": 표기 조각, "r": 읽기 조각, "k": bool(한자 포함)}] — 가나 글자는 한 글자씩, 한자 덩어리는 한 조각.
    # 표기의 가나를 닻(anchor)으로 읽기에서 찾아 그 사이를 한자 덩어리의 읽기로 정한다. 닻을 못 찾으면 전체를 한 조각으로(대체 경로).
    # 불변식: 조각의 s 를 이으면 fold(text), r 을 이으면 fold(reading)
static func diff(said: String, text: String, reading: String) -> Dictionary
    # {"score": 0..100, "passed": bool, "mode": "exact"|"reading"|"mixed"|"wrong"|"empty",
    #  "units": [{"w": 정답 표기 조각, "rd": 읽기 조각, "ok": bool, "kind": "ok"|"kana"|"kanji_diff"|"missing"|"typo", "said": 쓴 조각("" 가능)}],
    #  "extra": [정답에 없는 글자 덩어리 문자열...], "len": 읽기 글자 수}
static func first_hint(reading: String) -> String   # 읽기 앞 2글자 + "…"
```
- 정규화 `fold`: 앞 `MAX_LEN` 글자만 → 전각 영숫자 → 반각, 반각 가타카나 → 전각(탁점 결합) → 가타카나(U+30A1~30F6, ヽヾ) → 히라가나 → 공백·`、。，．！？!?「」『』（）()…・〜~"'：:；;` 삭제. `ー`(U+30FC)는 **유지**(철자 시험이라 `こうひい` 와 `コーヒー` 는 다르다).
- 점수: 정답 읽기 R 과 쓴 글자 T(쓴 글에서 정답 문장에 있는 한자 덩어리 표기를 그 읽기로 바꾼 것) 사이 `TextSim.lcs_match` 로 맞은 글자를 센다. `score = round(200 * lcs / (len(R) + len(T)))`(기존 `TextSim.similarity` 와 같은 Dice 식). 틀린 글자 수(`len(R)+len(T)-2*lcs`)가 `HARD_ERRORS` 이상이면 `min(score, HARD_CAP)`. `passed = score >= PASS_SCORE`.
- 표기 정책(사용자 결정 Q2 의 추천안): 읽기가 맞으면 정답이다. 한자 덩어리를 한자로 정확히 쓰면 `mode "exact"`(전부 정답 표기와 같음, 가타카나·히라가나 접기 후), 전부 가나로 쓰면 `"reading"`, 일부만 한자면 `"mixed"`, 점수가 100 미만이면 `"wrong"`. 한자 덩어리 자리에 다른 한자를 썼으면 그 조각은 `kind "kanji_diff"`, `ok false`(같은 소리의 다른 한자일 수 있어 이유 글에 그렇게 적는다. 폰은 쓴 한자를 읽을 수 없어서 판정 불가 — 정직하게 틀림 처리).
- 허용하는 표기 차이: 가타카나/히라가나(`パイロット`=`ぱいろっと`), 전각/반각, 공백·문장부호 유무, 송가나 표기 차이는 읽기로 풀면 같아진다(`行なう`=`行う`=`おこなう`), 한자 대신 가나. 허용하지 않는 것(철자로 본다): `ー` 와 모음 연장(`ラーメン` ≠ `ラアメン`), 조사 は/を/へ 의 소리 표기(`わ`로 쓴 は), `ぢ/づ` vs `じ/ず`, 작은 가나 `ゃ` vs `や`, `ん` 의 누락.

**일본어 받아쓰기 기록·보상**(영어와 같은 규칙, `lang="ja"`): `StudyLog.add_event("ja", "dictation", 1)`, 통과 문장마다 XP 3(상한 24), 5문장 이상 시도하면 `Store.mark_today("ja")`.

### 2.2 일본어 약한 소리

**`godot\data\ja_sounds.json`** (**새**, 팩 밖. `include_filter="data/*"` 라 PC·폰 빌드에 둘 다 들어간다)
```json
{"v": 1,
 "categories": [
  {"p": "j_long", "label": "장음 (ー)", "hint_ko": "길게 늘이는 소리예요. 한 박(모라)을 더 끌어요. …", "tip_ko": "…",
   "pairs": [{"a": "おばさん", "a_rd": "おばさん", "a_pr": "オバサン", "a_ko": "이모·고모",
              "b": "おばあさん", "b_rd": "おばあさん", "b_pr": "オバーサン", "b_ko": "할머니"}],
   "words": [{"w": "おばあさん", "rd": "おばあさん", "pr": "オバーサン", "ko": "할머니"}],
   "phrases": [{"text": "おばあさんは元気です。", "rd": "おばあさんはげんきです。", "pr": "オバーサンワゲンキデス。", "ko": "할머니는 건강하세요."}]}
 ]}
```
- 카테고리 id: `j_long`(장음), `j_sokuon`(촉음 っ), `j_voice`(청탁 구분: か/が, さ/ざ, た/だ, は/ば/ぱ), `j_tsu`(つ/す/ず), `j_za`(ざ/じゃ), `j_youon`(요음: きゃ/きや, びょういん/びよういん). 필수 5개(`j_long`, `j_sokuon`, `j_voice`, `j_tsu`, `j_za`), `j_youon` 은 검증된 쌍이 3개 이상일 때만 넣는다. `p` 는 `^j_[a-z]{2,8}$`(`PhonemeStats.MAX_P_LEN` 12 이하).
- 최소 개수: 쌍 `j_long`·`j_sokuon`·`j_voice` 8개 이상, `j_tsu` 6개 이상, `j_za`·`j_youon` 은 쌍이 있으면 그만큼(쌍이 부족한 소리는 `pairs` 를 비우고 `words` 4개 이상 + `phrases` 4개 이상으로 따라 말하기 중심). 모든 카테고리 `phrases` 4개 이상.
- 모든 낱말은 **실제 낱말**이어야 한다(가짜 낱말 금지). 객관 검사: 쌍의 `a`·`b` 가 `godot\data\pack\gloss_ja.json` 의 표제어에 있을 것, `a_rd != b_rd`, `rd`·`a_rd`·`b_rd` 는 히라가나만(`ー` 허용), `pr` 은 가타카나만, 한국어 글자 포함. `rd`·`pr` 은 작업자가 `backend\server.py` 의 `ja_reading`·`ja_pron`(OpenJTalk)으로 만들어 넣는다(손으로 쓰지 않음). 한국어 `hint_ko`·`tip_ko` 문구는 작업자 초안 → 사용자 검수(Q4).

**`JaSounds`** (**새**, `godot\scripts\core\ja_sounds.gd`, 순수 함수)
```gdscript
class_name JaSounds
const CATEGORIES := ["j_long", "j_sokuon", "j_voice", "j_tsu", "j_za", "j_youon"]
static func is_category(p: String) -> bool
static func load_data() -> Dictionary                       # ja_sounds.json 을 한 번 읽어 캐시: {"ok": bool, "categories": Array, "err": "" | "missing" | "bad"}. 깨졌거나 없으면 ok=false(앱은 죽지 않음)
static func category(p: String) -> Dictionary               # 없으면 {}
static func label_of(p: String) -> String                   # 데이터의 label, 없으면 p
static func events(reading: String) -> Array                # [{"cat": "j_long", "i": 모라 번호, "mora": "あ"}] — 한 모라가 여러 카테고리에 걸릴 수 있다
static func annotate(res: Variant) -> int                   # 일본어 /score 응답(units[].t = 히라가나 모라)에 units[i].ph = [{"p": cat, "ok": units[i].ok, "heard": units[i].heard 또는 null}] 를 붙인다. 붙인 항목 수. 두 번 불러도 중복 없음, 이상한 입력은 0 (바꾸지 않음)
static func build_listen_session(p: String, rng: RandomNumberGenerator, n: int = 10) -> Array
    # [{"play": "a"|"b", "pair": {...}, "options": [{w, rd, ko}, {w, rd, ko}] (섞음), "answer": 0|1}] — 한 바퀴 안에 같은 쌍 반복 금지(쌍이 n보다 적으면 순환)
```
- `events` 규칙(모라는 `server.split_mora` 와 같이 작은 가나를 앞 글자에 붙인 단위, 입력은 히라가나 읽기): `j_long` = 앞 모라의 모음과 이어지는 `あ/い/う/え/お` 또는 `ー`(예: おば**あ**さん, せんせ**い**, とう**きょう**의 う), `j_sokuon` = `っ`, `j_voice` = か·が, さ·ざ, た·だ, は·ば·ぱ 행의 모든 모라, `j_tsu` = `つ づ す ず`, `j_za` = `ざ ず ぜ ぞ じ` 와 `じゃ じゅ じょ`, `j_youon` = 작은 `ゃゅょ` 가 붙은 모라. 정확한 모음 대응표와 ≥ 25행의 기대 표는 작업 A2 가 시험에 싣는다.
- 한계(화면 안내 문구로도 보여 준다): "인식된 글자와 비교한 추정이에요. 소리 길이나 성대 울림을 직접 재지는 않아요."

**`StudyLog` 추가** (작업 A2, `core\study_log.gd`)
```gdscript
static func add_phon_obs(lang: String, p: String, ok: bool, heard: String = "") -> bool
    # 듣고 고르기 한 문항을 phon[lang][p] 에 넣는다(PhonemeStats.observe 와 같은 규칙: p 비었음·12자 초과·잘못된 언어는 false 이고 아무것도 안 바꿈)
# add_score_any 안: lang == "ja" 이면 JaSounds.annotate(d 의 복사본) 후 PhonemeStats.observe — 영어 경로는 그대로
```
- 새 저장 키 없음. `phon.ja` 의 새 키 6개는 길이 ≤ 12 라 `SyncDoc` 검사(`PhonemeStats.MAX_P_LEN`)에 맞는다. 옛 파일은 `phon.ja` 가 `{}` 여서 그대로 읽힌다. 1.6.x 앱이 새 키를 가진 파일을 읽어도 `_norm_phon` 이 그대로 보존한다(키 이름 제한만 지키면 됨).

### 2.3 일본어 미션

**콘텐츠** (`backend\content\missions.json` 에 일본어 8개 추가, 같은 형식. 기존 영어 8개는 바이트 그대로)
- 항목 키는 영어 미션과 같다: `id, lang:"ja", min_stage, order, max_turns, title_ko, situation_ko, persona, scene, opening, goals[], script[]`. 일본어에서 값의 의미는 다음과 같다.
  - `persona`·`scene`: 영어 지시문(AI 엔진용). 예: `Tanaka-san, a polite clerk at a convenience store in Tokyo`, scene 에 "정중한 일본어(です·ます)로 짧게, 학습자가 할 말을 알려 주지 말 것, JLPT 수준은 단계에 맞춤" 포함. 병원 미션은 **진단·약 용량을 말하지 말 것**을 scene 에 넣는다(영어 약국 미션과 같은 안전 규칙).
  - `opening`: 일본어 첫 대사. 새 선택 필드 `opening_rd`(히라가나 읽기), `opening_pr`(가타카나 발음형). 영어 미션에는 없다.
  - `goals[].goal_en`: AI 판정·상대 AI 프롬프트용 영어 설명(기존 이름 유지). `goals[].hint_en`: **일본어 예시 문장**(이름은 호환 때문에 유지), 새 선택 필드 `hint_rd`.
  - `script[]`: `{ai, goal, model}` + 새 선택 필드 `ai_rd`, `ai_pr`, `model_rd`, `model_pr`. 일본어 `ai`·`model` 에는 한글이 없다(기존 린트가 `ai` 의 한글을 거부).
  - `match`: 정규식 목록. **일본어 정규화 결과 문자열**(아래 `norm_ja`)에 적용된다. 규칙 §2.3.2.
  - `pos`/`neg`: 목표를 달성하는/못 하는 예시 문장(일본어).
- 미션 8개(id·단계·순서·목표). 순서 `order` 는 영어 10~80 과 겹치지 않게 110~180.

| id | 제목(`title_ko`) | min_stage | order | 목표 id : 한국어 라벨 |
|---|---|---|---|---|
| `ja_konbini` | 편의점에서 계산하기 | 1 | 110 | `find_item`: 찾는 물건이 어디 있는지 묻기 / `buy_item`: 살 물건 말하기 / `heat_bag`: 데우기·봉투 요청 또는 답하기 / `pay`: 결제 방법 말하기 / `thank`: 감사 인사 |
| `ja_ramen` | 라멘집에서 주문하기 | 1 | 120 | `seat_party`: 인원·자리 말하기 / `order_ramen`: 라멘 주문 / `customize`: 양·맵기·면 굳기 요청 / `ask_bill`: 계산 요청 / `thank`: ごちそうさま·감사 |
| `ja_ask_way` | 길 묻기 | 2 | 130 | `call_out`: 말 걸기 / `ask_place`: 장소·가는 법 묻기 / `ask_distance`: 거리·시간 묻기 / `confirm_route`: 되묻기·확인 / `thank_bye`: 감사·작별 |
| `ja_hotel_checkin` | 호텔 체크인 | 2 | 140 | `reservation`: 예약 확인 / `room_request`: 방 요청 / `breakfast_wifi`: 조식·와이파이 문의 / `checkout_luggage`: 체크아웃·짐 맡기기 |
| `ja_station_ticket` | 역 매표소에서 표 사기 | 2 | 150 | `dest_ticket`: 목적지·표 말하기 / `ticket_kind`: 종류·매수 / `platform_time`: 승강장·시각 묻기 / `pay_thank`: 결제·감사 |
| `ja_clinic` | 병원 접수 | 3 | 160 | `first_visit`: 처음 방문·접수 의사 / `symptom`: 증상 말하기 / `duration`: 언제부터인지 / `allergy_insurance`: 알레르기·보험증 |
| `ja_shopping` | 쇼핑 계산 | 2 | 170 | `ask_price`: 가격 묻기 / `size_color`: 사이즈·색 요청 / `tax_free`: 면세·할인 문의 / `pay_bag`: 결제 방법·봉투·포장 |
| `ja_self_intro` | 자기소개 | 1 | 180 | `say_name`: 이름 말하기 / `nice_meet`: はじめまして·よろしく / `origin`: 출신 / `hobby`: 취미 / `ask_back`: 되묻기(あなたは?) |

- `max_turns` 10, `script` 줄은 목표마다 1줄 이상(모든 목표가 대본 모드에서 달성 가능해야 함. 영어 린트와 같은 규칙).
- 폰 팩: `godot\data\pack\missions.json` 은 `backend\content\missions.json` 의 바이트 복사본으로 유지하고 `manifest.json` 의 해시·`records`(8→16)를 갱신한다: `backend\.venv\Scripts\python.exe -I backend\tools\build_phone_pack.py --only content`(기존 도구, 수정 없음). 작업 B2 만 한다.

**2.3.1 서버 `backend\missions.py` 변경**(작업 B1)
- `normalize(text, lang="en")`: 영어는 지금과 바이트 단위로 같다. 일본어는 `normalize_ja`(**새**):
  1. 앞 300자만. 2. NFKC. 3. 영문 소문자. 4. 가타카나(U+30A1~30F6)를 히라가나로(`-0x60`), `ヽ`→`ゝ`, `ヾ`→`ゞ`. 5. 남기는 글자: 히라가나(U+3041~3096, 309D, 309E), `ー`(U+30FC), 한자(U+4E00~9FFF, U+3400~4DBF), `々`(U+3005), `〇`(U+3007), `a-z`, `0-9`. 나머지(공백·부호·기호)는 **지운다**(영어처럼 공백으로 바꾸지 않음. 일본어에는 띄어쓰기가 없다).
- `list_missions(lang, stage)`: 일본어도 `lang` 이 맞는 미션만 `public_mission` 으로(더 이상 `unsupported`가 아님). `JA_MSG` 는 `unsupported` 응답에서 제거(일본어 `unsupported:true` 응답이 사라지므로 API.md도 고친다). 영어 응답은 바이트 그대로.
- `public_mission`: 영어 미션의 출력은 지금과 같고, 일본어 미션이면 위 선택 필드(`opening_rd`, `opening_pr`, `goals[].hint_rd`, `script[].ai_rd/ai_pr/model_rd/model_pr`)를 **있을 때만** 더한다. 정답 규칙(`match`/`pos`/`neg`/`goal_en`)은 어떤 응답에도 나가지 않는다(기존 보안 규칙).
- `_need_mission(lang, id)`: 일본어 400 제거. 요청 `lang` 과 미션의 `lang` 이 다르면 404 "알 수 없는 미션이에요."
- `check_text`: `norm = normalize(text, lang)`. `judge_goals`: 시스템 프롬프트를 언어별로(`Japanese learner`), 증거 인용 확인 `_quoted_in` 은 일본어에서 `normalize_ja` 한 증거가 `normalize_ja` 한 학습자 문장 안에 들어 있고 길이가 2~80자일 때만 인정. 대화는 마지막 24줄·줄당 500자까지(기존).
- 정규식 안전 검사 `unsafe_regex` 는 그대로(300자 한도, 중첩 반복·넓은 반복 제한). 일본어 패턴은 `\b`·`\s` 를 쓰지 않는다.

**2.3.2 일본어 규칙 작성 규약**(어미·경어 변형 체크)
- 패턴은 `norm_ja` 결과의 글자(히라가나·`ー`·한자·영숫자)로만 쓴다. 가타카나 낱말은 **히라가나로** 쓴다(`らーめん`, `こーひー`). 한자가 있는 낱말은 한자·가나 표기를 둘 다 넣는다: `(?:お願い|おねがい)`, `(?:下さい|ください)`.
- 조사 생략을 허용한다(말할 때 흔함): `これをください` 와 `これください`, `駅はどこですか` 와 `駅どこですか` → 조사는 `(?:を)?`·`(?:は|が)?` 로.
- 어미 변형 묶음(작업자가 목표마다 필요한 것만 골라 쓴다. 전부 정규식 안에 풀어서 쓴다 — 매크로는 최종 JSON에 남기지 않는다):

| 묶음 | 풀어 써야 하는 형태 |
|---|---|
| 정중 | `ます` `ません` `ました` `ませんでした` `ましょう` `たいです` `たいんですが` `ていますか` |
| 부탁 | `てください` `てくれませんか` `てもらえますか` `ていただけますか` `てもいいですか` `てほしいです` `をお願いします` `おねがいします` `をください` |
| 보통체 | `る` `ない` `た` `なかった` `たい` `ている` |
| 단정 | `です` `だ` `でした` `じゃない` `ではありません` `なんですが` |
| 말끝 | `んですが` `んですけど` `ですよね` `ですか` `かな` `ね` |

- 같은 의미의 정중·보통체를 모두 받는다(학습자 수준이 다르다). 목표 라벨에 "정중하게"가 있는 목표만 `です/ます/お願い` 형을 요구한다.
- 린트(작업 B1의 `test_missions.py`): 일본어 목표마다 `pos` 6개 이상 중 히라가나만인 문장 1개 이상 + 한자 섞인 문장 1개 이상, `neg` 5개 이상, `pos` 전부 달성·`neg` 전부 미달성, `hint_en` 이 목표를 달성, 대본 `model` 이 자기 목표를 달성, 모든 일본어 필드의 읽기 필드가 히라가나(+부호)만, `ai`·`model`·`opening` 에 한글 없음, 일본어 id 는 `^ja_[a-z0-9_]{2,36}$`.

**2.3.3 폰·앱 변경**
- 폰 `LocalMissions`(작업 B3): `normalize(text, lang="en")` 가 일본어면 `MissionText.norm_ja`(**새** `godot\scripts\core\mission_text.gd`, 순수 함수)를 쓴다. NFKC 는 GDScript에 없으므로 **부분집합**으로 구현한다: 전각 ASCII(U+FF01~FF5E) → ASCII, U+3000 → 공백, 반각 가타카나(U+FF66~FF9F, 탁점·반탁점 결합) → 전각. 그 밖의 호환 문자(`㌔` 같은 것)는 파이썬과 다를 수 있다 → 황금 입력에 넣지 않고 문서에 "알려진 차이"로 적는다. `_list`/`_check` 가 일본어를 허용하고(`JA_MSG` 분기 제거), `_public` 이 선택 필드를 통과시킨다.
- 황금 파일 `godot\tests\fixtures\mission_golden.json`: 일본어 입력 24개 이상(미션 8개 × 3, 전각·반각 가나·가타카나 접기·긴 입력 포함)과 정규화 사례를 `backend\tools\make_mission_golden.py`(기존 도구 수정)로 다시 만든다. 영어 30개는 그대로.
- 앱 `MissionLogic`(작업 B4): `normalize_mission` 이 선택 필드(`opening_rd`, `opening_pr`, `goals[].hint_rd`, `script[].ai_rd` 등)를 보존한다(없으면 `""`). `apply_judge(done, pending, resp, me_texts, lang := "en")`·`script_passes(said, line, reached, lang := "en")` 에 `lang` 인자(기본 `"en"`, 기존 호출은 그대로 동작)를 더하고 일본어는 `MissionText.norm_ja` 로 증거를 비교한다. `MissionScreen` 은 일본어에서 목록 요청 `?lang=ja`, 말풍선 아래 `ReadingLine`, 힌트의 읽기, 대본 모드의 읽기를 보인다.

**2.3.4 별 3 배지·기록 화면**(작업 S)
- `BadgeRules.MISSION_IDS` 는 영어 8개 그대로. `BadgeRules.MISSION_IDS_JA = ["ja_konbini","ja_ramen","ja_ask_way","ja_hotel_checkin","ja_station_ticket","ja_clinic","ja_shopping","ja_self_intro"]`(**새**). `StatsView.MISSION_ORDER_JA`(**새**)는 같은 목록, `MISSION_NAME_JA`(**새**)는 `{ja_konbini: 편의점, ja_ramen: 라멘집, ja_ask_way: 길 묻기, ja_hotel_checkin: 호텔, ja_station_ticket: 역 매표소, ja_clinic: 병원 접수, ja_shopping: 쇼핑 계산, ja_self_intro: 자기소개}`.
- `BadgeEngine.snapshot`: `mission_star3` 는 지금대로(모든 id), `mission_all_star3 = max(영어 8개 중 별3 수, 일본어 8개 중 별3 수)`. 측정 이름·목표(8)·이름("미션 8개 모두 별 3개")·id 는 그대로. 설명만 "한 언어의 미션 8개 모두에서 별 3개를 받았어요."
- 시험: 기존 `MISSION_IDS == MISSION_ORDER` 단언은 그대로 두고 `MISSION_IDS_JA == MISSION_ORDER_JA` 단언을 더한다(순서를 바꾼 목록은 거부하는 일부러 틀린 입력 포함). 영어 8개 별3 → 배지 받음, 영어 7 + 일본어 7 → 못 받음, 일본어 8 → 받음.
- `StatsView` 미션 카드: 선택된 언어의 미션만 칩으로(영어는 `MISSION_ORDER`, 일본어는 `MISSION_ORDER_JA`; 목록에 없는 id 는 같은 언어 접두어일 때만 뒤에 붙임). 약한 소리 카드: 일본어 탭에서 `JaSounds.label_of` 로 일본어 카테고리 칩을 보이고 [집중 연습] 은 `pending = {"kind":"phoneme","p":<id>}`.

### 2.4 한 줄 일기

**저장 `user://diary.json`** (**새** 파일, 이 기기 전용. `DiaryStore`, `godot\scripts\core\diary_store.gd`)
```json
{"v": 1,
 "entries": [
  {"id": "d1731571200123", "date": "2026-11-14", "lang": "ja", "created": 1731571200,
   "text": "きのう ともだちと えいがをみた。",
   "state": "fixed",
   "items": [{"orig": "きのう ともだちと えいがをみた。", "fix": "昨日、友達と映画を見ました。",
              "why": "과거형과 정중체로 맞췄어요.", "reading": "きのう、ともだちとえいがをみました。", "pron": "キノー、トモダチトエーガヲミマシタ。",
              "same": false, "card": true}],
   "fixed_at": 1731571300}
 ],
 "cards_by_day": {"2026-11-14": 2}}
```
- 규칙(읽을 때 `_normalize` 가 강제, 쓰레기 값은 에러 없이 정리·버림): `entries` 최대 `MAX_ENTRIES = 1000`(가득 차면 새 일기를 거절하고 "일기가 1,000개예요. 오래된 것을 지워 주세요"), `id` `^d[0-9]{6,20}$` 중복 없음, `date` 실제 달력의 `YYYY-MM-DD`, `lang` `en` 또는 `ja`, `text` 1~300자, `state` `saved` 또는 `fixed`, `items` 0~3개(`saved` 는 `[]`), 각 `orig` ≤ 120자·`fix` ≤ 300자·`why` ≤ 200자·`reading`·`pron` ≤ 300자·`same`/`card` 불리언, `created`·`fixed_at` 0 이상 정수, `cards_by_day` 최근 14일만(날짜 키 검사, 값 0~100). 모르는 최상위 키는 보존. 파일이 깨졌으면 기존 방식대로 `.bad` 로 옮기고 빈 상태(`Progress.read_json_file`), 못 읽으면 읽기 전용(저장 안 함).
- 같은 (`lang`, `date`, `text`)를 다시 저장하면 새 일기를 만들지 않고 기존 것을 갱신한다.
- 쓰기는 `Progress.write_text_atomic`. 시험 보호: `Progress.REAL_FILE_NAMES` 에 `"diary.json"` 추가(작업 C1), 시험은 `DiaryStore.path = "user://test_diary_*.json"` 으로 바꿔 쓴다. 시험 실행 중 경로 기본값이 실제 파일이면(`Progress.test_guard`) `user://test_guard/diary.json` 으로 돌린다.
- 동기화 안 함: `SyncDoc`·`SyncMerge` 는 이 파일을 읽지 않는다(시험으로 확인). 안드로이드 자동 백업 꺼짐(F11). 원문은 `diary.json` 한 곳에만 있다.

```gdscript
class_name DiaryStore          # core\diary_store.gd (새)
const MAX_ENTRIES := 1000
static var path := "user://diary.json"
static func entries(lang: String = "") -> Array            # 최신순 복사본
static func get_entry(id: String) -> Dictionary
static func add(lang: String, text: String) -> Dictionary  # {"ok": bool, "id": String, "reason": "" | "full" | "read_only" | "invalid"}
static func set_fixed(id: String, items: Array) -> bool    # state = "fixed", fixed_at = 지금
static func remove(id: String) -> bool
static func clear() -> int                                 # 지운 개수
static func pending(lang: String = "") -> Array            # state == "saved"
static func counts() -> Dictionary                         # {"entries": n, "days": 서로 다른 날짜 수, "fixed": n}  (배지용, 원문 없음)
static func cards_today() -> int
static func note_cards(n: int) -> void
static func is_read_only() -> bool
```
```gdscript
class_name DiaryLogic          # core\diary_logic.gd (새, 순수 함수)
const MAX_CHARS := 300
const MAX_SENTENCES := 3
const MAX_SENTENCE_CHARS := 120
const CARDS_PER_ENTRY := 3
const CARDS_PER_DAY := 5
static func split(text: String, lang: String) -> Array     # 일본어: 。！？!? 와 줄바꿈 뒤에서 나눔, 영어: .!? 와 줄바꿈. 끝 부호는 문장에 붙임, 빈 문장 제거
static func check_input(text: String, lang: String) -> Dictionary   # {"ok": bool, "reason": "" | "empty" | "too_long" | "too_many" | "sentence_long" | "wrong_lang", "sentences": Array}
static func clean_fix(orig: String, resp: Variant, lang: String) -> Dictionary
    # {"orig", "fix", "why", "reading", "pron", "same": bool, "bad": bool}. AI 출력 검증 §5(R-C4): 사전이 아님·fix 가 문자열이 아님 → bad
static func cards_for(entry: Dictionary, today_cards: int) -> Array   # 카드로 넣을 [{lang, target, reading, ko, note}] (고친 것만, 원문 제외, 상한 적용)
static func date_label(iso: String) -> String               # "11월 14일 (금)"
```
- `clean_fix` 검증: `fix` 는 한 줄(줄바꿈·제어 문자 제거), ≤ 300자. 영어면 한글 없음, 일본어면 가나·한자가 있고 한글 없음. `fix` 가 비었거나 원문과 `TextSim.norm_text` 로 같으면 `same`. 길이 비 `len(fix) <= 3 * len(orig) + 20`(AI가 내용을 지어내는 것 차단) 위반 → `bad`. `why` ≤ 200자, 비었으면 "더 자연스럽게 고쳤어요." `bad` 인 문장은 고치지 못했다고 보이고 카드에 넣지 않는다.

**`POST /fix` 확장** (작업 C2, 백엔드 `server.py`·`grammar.py`. 새 라우트 없음, `lan.py` 변경 없음)
```json
요청  {"lang": "ja", "stage": 1, "text": "きのう ともだちと えいがをみた。", "prev_ai": "", "private": true}
응답  {"fix": "昨日、友達と映画を見ました。", "fix_ko": "과거형과 정중체로 맞췄어요.", "reading": "きのう、ともだちとえいがをみました。", "pron": "キノー、…"}
```
- `private` 는 선택(생략·`false` 는 지금과 똑같이 동작하고 응답 키도 `fix`, `fix_ko` 둘뿐). `private:true` 일 때만: ① `llm_json` 을 `cache_key_kind=None` 으로 불러 `backend\cache\llm_cache.sqlite` 에 저장하지 않는다 ② 문장(원문·고친 문장)을 로그에 쓰지 않는다: `correct_learner`·`_llm_correct`·`grammar.correct(…, quiet=True)` 의 문장 `%r` 로그를 끄고, 실패 로그도 길이·규칙 id 만 ③ 응답에 `reading`·`pron` 을 더한다(일본어: `fix_ja_reading(ja_reading(fix), fix)`, `ja_pron(fix)`; 영어·고칠 것 없음: `""`). `text` 는 500자까지(기존) — 일기 앱은 문장당 120자만 보낸다.
- 서버 코드 안에서 `private` 는 `correct_learner(lang, stage, text, prev_ai, private=False)` 인자로 전달한다(기본값이 있어 기존 호출 모두 그대로).

**앱 쪽 호출·상태**: `DiaryScreen` 은 `SpeakDrill.request("/fix", body, Api.TIMEOUT_LLM)` 한 길(시험은 `SpeakDrill.api_hook` 으로 가로챔). AI 사용 가능 판정 `DiaryScreen.ai_state() -> "ready" | "no_pc" | "ai_off"`(**새**): `Route.caps()["items"]["fix"]["use"] != "pc"` 이면 `no_pc`, PC인데 `Backend.health["llm"]` 가 false 면 `ai_off`(시험은 `DiaryScreen.ai_hook`(**새** 정적 `Callable`)으로 바꿔 끼움). 설정 키 `diary_consent`(불리언, 기본 없음 = false; 이름이 `_consent` 로 끝나 공개 빌드의 기본 설정에서 자동 제거됨). 음성 입력은 `/stt`(`SpeakDrill.request`).

### 2.5 기존 데이터와의 호환·동기화
| 항목 | 결정 |
|---|---|
| `studylog.json` | 새 최상위 키 없음. `phon.ja` 에 키 6개가 생길 수 있다(동기화됨: 영어 `phon.en` 과 같은 병합). `missions` 에 `ja_*` id 가 생긴다(기존 동기화 규칙·`MAX_MISSIONS` 200 이내, 키 형식은 `[a-z0-9_]`) |
| 옛 앱(1.6.x)이 새 파일을 읽을 때 | `phon.ja` 새 키·`missions.ja_*` 는 모르는 키가 아니라 같은 구조의 값이라 그대로 보존·표시(미션 칩은 id 로 보임). `diary.json` 은 옛 앱이 열지 않는다 |
| 동기화(1.2 허브) | 변경 없음. `diary.json`·`ja_sounds.json` 은 동기화 대상이 아님. 복습 카드(`progress.review`)에 들어간 **고친 문장은** 기존 규칙대로 동기화된다 → 일기의 고친 문장이 PC 허브로 간다(원문은 가지 않음). 사용자에게 알린다(Q8) |
| 두 기기의 일본어 미션 별 | `missions` 가 이미 동기화되고 최대값 병합이라 두 기기가 같은 결과로 수렴. `mission_all_star3` 배지는 기록에서 계산하므로 수렴 |
| 서버 구버전 | `private` 를 모르는 서버(1.6.x PC)는 필드를 무시하고 원래대로 캐시·로그를 남긴다. 앱은 응답에 `reading` 키가 없으면(구버전 신호) `OLD_SERVER_PRIVACY`(**새** 상수) 안내 한 줄("PC 프로그램을 최신 버전으로 업데이트하면 일기 내용이 PC에 남지 않아요")을 일기 화면에 보인다 |
| 폰 팩 | `missions.json` 해시·records 만 바뀜(`manifest.json`). `ja_sounds.json` 은 팩 밖이라 매니페스트 영향 없음. APK 증가: 미션 약 +80 KB, `ja_sounds.json` ≤ 120 KB |
| 기록 초기화 | `Store.reset_progress()` 는 일기를 지우지 않는다(일기는 별도 지우기, Q8). 일본어 미션·`phon.ja` 는 지금처럼 `StudyLog.reset()` 이 지운다 |
| 공개 빌드 | 기본 설정에서 `diary_consent` 는 자동 제거됨(`packaging\sanitize_prefs.py`, `*_consent` 규칙). `diary.json` 은 `user://` 에만 있어 올라가지 않는다 |

### 2.6 바뀌는 기존 시험 단언 (근거 있는 것만. 이 밖의 기존 단언을 지우거나 느슨하게 하면 X)
| 파일 | 줄(대략) | 지금 | 바뀐 뒤 | 이유 | 담당 |
|---|---|---|---|---|---|
| `backend\test_practice.py` | 367~368, 405 | 일본어 dictation → 400 + 한글 error | 200, 문장이 `ja_dictation_ok` 를 통과, `reading` 히라가나만 | D1 | A4 |
| `godot\tests\local_lessons_test.gd` | 323~324 | 폰 `lang=ja&mode=dictation` → 400 | 200, n 개, 규칙 통과 | D1 | A4 |
| `backend\test_missions.py` | 388~391, 463, 507, 700, FULL_SET | 일본어 목록 `unsupported`, check·judge 400 | 일본어 목록 8개, 체크·판정 정상, `--full` 은 언어별 8개 | D5 | B1 |
| `godot\tests\local_missions_test.gd` | 69, 74, 222, 328~344, 115 | 미션 8개, 일본어 `unsupported`, 황금 30개 | 영어 8·일본어 8(언어로 거름), 일본어 목록, 황금 54개 이상 | D5 | B3 |
| `godot\tests\mission_test.gd` | 322~325, 619~625 | 일본어 응답 `unsupported` 안내 | 일본어 목록·대화 흐름(새 시험은 `mission_ja_flow_test`), `parse_list` 의 `unsupported` 분기는 옛 서버 호환으로 유지 | D5 | B4 |
| `godot\tests\stats_view_test.gd` | 248 | 일본어 페이지에 약한 소리·미션 카드 없음 + 영어 전용 안내 | 일본어 페이지에 일본어 미션 칩·일본어 약한 소리 카드 | D6, D4 | S |
| `godot\tests\practice_test.gd` | 289, 346, 690 | 카드 6개, 일본어에서 받아쓰기·약한 소리 꺼짐, 일본어 받아쓰기 `unsupported` | 카드 7개(`diary` 포함), 일본어에서 둘 다 켜짐, 일본어 받아쓰기는 `/practice/sentences?lang=ja&mode=dictation` 요청 | D1, D3, D7 | W |
| `godot\tests\ui_practice_widgets_test.gd` | 456, 482, 503 | 카드 6개 목록, 일본어 "영어만" 글 | 카드 7개 목록, "영어만" 글 없음(일본어 설명으로 대체) | 〃 | W |
| `godot\tests\fun_wiring_test.gd`, `fun_parts_test.gd` | 374, 홈 버튼 목록 | 허브 6카드, 홈 카드 버튼 3~4개 | 허브 7카드, 홈 카드에 [일기] | D7 | W |
| 배지 시험 4개(조건부) | `badge_rules_test` 116·118·169·197, `badge_engine_test` 366·367·509·511·528·629, `badge_view_test` 213·226~228·253·256·374·595, `fun_*_test` 의 `23` | 23개 | **일기 배지를 승인했을 때만** 25(명시 숫자, 표에 2행 추가) | D11 | S(배지 시험), W(`fun_*_test`) |
- 시험이 일부러 틀린 값을 넣는 줄(selfcheck)은 새 상수에 맞게 같이 고친다.
- `practice_test.gd` 625의 `PhonemeScreen.open("ja")` → `unsupported` 는 **그대로 맞다**(영어 화면은 영어 전용 유지, 일본어는 `JaSoundScreen`).

---

## 3. 작업 분할과 병렬 순서

### 3.1 규칙 (모든 작업 공통)
- 담당은 전부 `worker-hard`(구현·시험). 검토는 `reviewer`(§3.4). 문서 작업 Z 도 `worker-hard`.
- 작업마다 **별도 worktree** `D:\Ai\언어\app_wt\ja_<작업>`, 브랜치 `ja170/<작업>`(`v161_u1`, `v161_u2` 는 건드리지 않는다). 오케스트레이터가 §3.2 순서로 합친다. 다른 작업의 파일은 읽기만, 고칠 일이 생기면 오케스트레이터에게 보고한다.
- 임시 파일·로그·가짜 APPDATA 는 `<scratchpad>\w_<작업>\` 안에만. 시험이 쓰는 사용자 파일은 `user://test_*` 만(시험 보호). 콘텐츠를 만드는 일회용 스크립트(읽기·발음형 생성, 변환)도 scratchpad 에 둔다 — `backend\tools\` 에 새 추적 파일을 만들지 않는다(공개 검사 `-ScanOnly` 가 막는다).
- 새 `class_name` 스크립트를 더한 뒤 `godot --headless --path <worktree>\godot --import` 를 한 번 돌리고 생성된 `.uid` 도 같이 둔다(자기 새 파일의 짝만). 새 시험은 `.gd` + `.tscn` 짝, 머리 주석에 실행 명령(PC·`-- --phone`)과 마지막 줄 형식을 적는다. 마지막 줄: `== <이름>: N passed, M failed ==`(실패 있으면 종료 코드 1).
- 색은 `Pal` 토큰만(`Color("#…")` 금지), 글자 크기 `Ds.fs(n)`/`UI.label` 변형(최소 12), 눌리는 것은 `Button`/`BaseButton`, 도형은 `GlyphIcon`(이모지·도형 글자 금지).
- 요청은 기존 경로만: 화면은 `SpeakDrill.request`(또는 기존 `Api`). 새 `HTTPRequest`·`OS.shell_open` 금지.

### 3.2 의존 순서와 병렬
```
1파 (동시에 5명):  A1 일본어 받아쓰기 채점  ∥  A2 일본어 소리 코어·기록  ∥  B1 미션 서버 엔진  ∥  C1 일기 저장·로직  ∥  C2 /fix private 백엔드
2파 (1파가 합쳐진 뒤 동시에 6명):  A4 받아쓰기 화면·문장(A1)  ∥  A5 약한 소리 화면(A2)  ∥  B2 일본어 미션 콘텐츠(B1)  ∥  B4 미션 화면(B1 계약)  ∥  C3 일기 화면(C1, C2)  ∥  S 기록 화면·배지(A2, C1)
3파:  B3 폰 미션 엔진·황금(B2)  ∥  B2t 독립 문장 시험(B2)  ∥  W 연결(A4, A5, B4, C3, S)
4파:  Z 문서(W)  →  reviewer 독립 검토(작업마다, 합치기 전)  →  오케스트레이터 통합 시험(T8)
```
| 작업 | 선행 | 동시에 해도 되는 것 | 비고 |
|---|---|---|---|
| A1 | 없음 | A2, B1, C1, C2 | 순수 계산 |
| A2 | 없음 | A1, B1, C1, C2 | `study_log.gd` 소유 |
| B1 | 없음 | A1, A2, C1, C2 | `missions.py` 소유, 린트 틀 확정 |
| C1 | 없음 | A1, A2, B1, C2 | `progress.gd` 소유(1줄) |
| C2 | 없음 | A1, A2, B1, C1 | `server.py`·`grammar.py` 소유 |
| A4 | A1 | A5, B2, B4, C3, S | `practice.py`·`local_practice.gd` 소유 |
| A5 | A2 | A4, B2, B4, C3, S | |
| B2 | B1 | A4, A5, B4, C3, S | 콘텐츠 + 팩 동기화 |
| B4 | B1(계약: §2.3), 시험 데이터는 자기 `sample_*_ja.json` | B2 등 | 콘텐츠를 기다리지 않는다 |
| C3 | C1, C2 | 2파 전부 | |
| S | A2(`JaSounds`), C1(일기 배지를 승인했을 때만 `DiaryStore.counts`) | 2파 전부 | |
| B3 | B2(최종 콘텐츠로 시험), B1(황금은 PC 엔진에서 만듦) | B2t, W | 코드는 B1 뒤에 시작해도 되지만 최종 시험은 B2 뒤 |
| B2t | B2 | B3, W | **작성자와 다른 작업자**가 독립 문장을 쓴다 |
| W | A4, A5, B4, C3, S | B3, B2t | 공유 파일 소유 |
| Z | W | — | |

### 3.3 소유권 표 (수정 허용 파일. 이 밖은 수정 금지)
| 작업 | 수정(기존 파일) | 새 파일 |
|---|---|---|
| A1 | (없음) | `godot\scripts\practice\dictation_diff_ja.gd`, `godot\tests\dictation_diff_ja_test.gd`(+tscn) |
| A2 | `godot\scripts\core\study_log.gd` | `godot\scripts\core\ja_sounds.gd`, `godot\data\ja_sounds.json`, `godot\tests\ja_sounds_test.gd`(+tscn), `godot\tests\ja_sounds_data_test.gd`(+tscn), `godot\tests\study_log_ja_test.gd`(+tscn) |
| A4 | `godot\scripts\practice\dictation_screen.gd`, `godot\scripts\local\local_practice.gd`, `backend\practice.py`, `backend\test_practice.py`, `godot\tests\local_lessons_test.gd` | `godot\tests\dictation_ja_screen_test.gd`(+tscn), `godot\tests\sample_practice_dictation_ja.json` |
| A5 | (없음) | `godot\scripts\practice\ja_sound_screen.gd`, `godot\tests\ja_sound_screen_test.gd`(+tscn) |
| B1 | `backend\missions.py`, `backend\test_missions.py` | (없음) |
| B2 | `backend\content\missions.json`, `godot\data\pack\missions.json`, `godot\data\pack\manifest.json` | (없음) |
| B2t | (없음) | `backend\test_missions_ja.py` |
| B3 | `godot\scripts\local\local_missions.gd`, `backend\tools\make_mission_golden.py`, `godot\tests\fixtures\mission_golden.json`, `godot\tests\local_missions_test.gd` | `godot\scripts\core\mission_text.gd`, `godot\tests\mission_text_test.gd`(+tscn) |
| B4 | `godot\scripts\practice\mission_screen.gd`, `godot\scripts\core\mission_logic.gd`, `godot\tests\mission_test.gd` | `godot\tests\mission_ja_flow_test.gd`(+tscn), `godot\tests\sample_mission_list_ja.json`, `godot\tests\sample_mission_chat_ja.json` |
| C1 | `godot\scripts\core\progress.gd` | `godot\scripts\core\diary_store.gd`, `godot\scripts\core\diary_logic.gd`, `godot\tests\diary_store_test.gd`(+tscn), `godot\tests\diary_logic_test.gd`(+tscn) |
| C2 | `backend\server.py`, `backend\grammar.py` | `backend\test_fix_private.py` |
| C3 | (없음) | `godot\scripts\practice\diary_screen.gd`, `godot\tests\diary_screen_test.gd`(+tscn), `godot\tests\diary_flow_test.gd`(+tscn) |
| S | `godot\scripts\core\badge_rules.gd`, `godot\scripts\core\badge_engine.gd`, `godot\scripts\core\badge_defs.gd`, `godot\scripts\views\stats_view.gd`, `godot\tests\badge_rules_test.gd`, `godot\tests\badge_engine_test.gd`, `godot\tests\badge_view_test.gd`, `godot\tests\stats_view_test.gd` | (없음) |
| W | `godot\scripts\views\practice_view.gd`, `godot\scripts\views\today_view.gd`, `godot\scripts\ui\fun_parts.gd`, `godot\tests\practice_test.gd`, `godot\tests\ui_practice_widgets_test.gd`, `godot\tests\fun_parts_test.gd`, `godot\tests\fun_wiring_test.gd`, `godot\tests\t5_wiring_test.gd`, `godot\tests\home_view_test.gd`, `godot\tests\screens_scan_test.gd` | `godot\tests\v170_wiring_test.gd`(+tscn) |
| Z | `README.md`, `ROADMAP.md`, `API.md` | (없음) |

- 소유 밖이지만 **읽기만** 하는 파일: `kana_voice.gd`, `text_sim.gd`, `song_study.gd`, `dictation_diff.gd`, `phoneme_stats.gd`, `speak_drill.gd`, `fix_cards.gd`, `route.gd`, `store.gd`, `reading_line.gd`, `sheet.gd`, `sync\*`, `lan.py`, `llm_*.py`, `build_phone_pack.py`(실행만).
- 수정 금지(어느 작업도 소유하지 않음): `godot\project.godot`, `godot\export_presets.cfg`, `godot\scripts\autoload\*`(특히 `store.gd`, `route.gd`, `local_api.gd`), `godot\scripts\sync\*`, `backend\lan.py`, `backend\llm_*.py`, `backend\tools\build_phone_pack.py`, `packaging\*`, `godot\data\pack\practice_*.json`, `godot\scripts\main.gd`.
- 소유권을 **스크립트로 검사**한다(§3.5). 아래 블록이 그 입력이다(`.tscn` 짝은 줄로 적고 `.uid` 는 새 `.gd` 와 같은 이름의 짝이라 적지 않는다).

<!-- OWN-BEGIN -->
A1 new godot\scripts\practice\dictation_diff_ja.gd
A1 new godot\tests\dictation_diff_ja_test.gd
A1 new godot\tests\dictation_diff_ja_test.tscn
A2 mod godot\scripts\core\study_log.gd
A2 new godot\scripts\core\ja_sounds.gd
A2 new godot\data\ja_sounds.json
A2 new godot\tests\ja_sounds_test.gd
A2 new godot\tests\ja_sounds_test.tscn
A2 new godot\tests\ja_sounds_data_test.gd
A2 new godot\tests\ja_sounds_data_test.tscn
A2 new godot\tests\study_log_ja_test.gd
A2 new godot\tests\study_log_ja_test.tscn
A4 mod godot\scripts\practice\dictation_screen.gd
A4 mod godot\scripts\local\local_practice.gd
A4 mod backend\practice.py
A4 mod backend\test_practice.py
A4 mod godot\tests\local_lessons_test.gd
A4 new godot\tests\dictation_ja_screen_test.gd
A4 new godot\tests\dictation_ja_screen_test.tscn
A4 new godot\tests\sample_practice_dictation_ja.json
A5 new godot\scripts\practice\ja_sound_screen.gd
A5 new godot\tests\ja_sound_screen_test.gd
A5 new godot\tests\ja_sound_screen_test.tscn
B1 mod backend\missions.py
B1 mod backend\test_missions.py
B2 mod backend\content\missions.json
B2 mod godot\data\pack\missions.json
B2 mod godot\data\pack\manifest.json
B2t new backend\test_missions_ja.py
B3 mod godot\scripts\local\local_missions.gd
B3 mod backend\tools\make_mission_golden.py
B3 mod godot\tests\fixtures\mission_golden.json
B3 mod godot\tests\local_missions_test.gd
B3 new godot\scripts\core\mission_text.gd
B3 new godot\tests\mission_text_test.gd
B3 new godot\tests\mission_text_test.tscn
B4 mod godot\scripts\practice\mission_screen.gd
B4 mod godot\scripts\core\mission_logic.gd
B4 mod godot\tests\mission_test.gd
B4 new godot\tests\mission_ja_flow_test.gd
B4 new godot\tests\mission_ja_flow_test.tscn
B4 new godot\tests\sample_mission_list_ja.json
B4 new godot\tests\sample_mission_chat_ja.json
C1 mod godot\scripts\core\progress.gd
C1 new godot\scripts\core\diary_store.gd
C1 new godot\scripts\core\diary_logic.gd
C1 new godot\tests\diary_store_test.gd
C1 new godot\tests\diary_store_test.tscn
C1 new godot\tests\diary_logic_test.gd
C1 new godot\tests\diary_logic_test.tscn
C2 mod backend\server.py
C2 mod backend\grammar.py
C2 new backend\test_fix_private.py
C3 new godot\scripts\practice\diary_screen.gd
C3 new godot\tests\diary_screen_test.gd
C3 new godot\tests\diary_screen_test.tscn
C3 new godot\tests\diary_flow_test.gd
C3 new godot\tests\diary_flow_test.tscn
S mod godot\scripts\core\badge_rules.gd
S mod godot\scripts\core\badge_engine.gd
S mod godot\scripts\core\badge_defs.gd
S mod godot\scripts\views\stats_view.gd
S mod godot\tests\badge_rules_test.gd
S mod godot\tests\badge_engine_test.gd
S mod godot\tests\badge_view_test.gd
S mod godot\tests\stats_view_test.gd
W mod godot\scripts\views\practice_view.gd
W mod godot\scripts\views\today_view.gd
W mod godot\scripts\ui\fun_parts.gd
W mod godot\tests\practice_test.gd
W mod godot\tests\ui_practice_widgets_test.gd
W mod godot\tests\fun_parts_test.gd
W mod godot\tests\fun_wiring_test.gd
W mod godot\tests\t5_wiring_test.gd
W mod godot\tests\home_view_test.gd
W mod godot\tests\screens_scan_test.gd
W new godot\tests\v170_wiring_test.gd
W new godot\tests\v170_wiring_test.tscn
Z mod README.md
Z mod ROADMAP.md
Z mod API.md
<!-- OWN-END -->

### 3.4 검토 강도 (변경 내용 기준)
| 작업 | 위험도 | 검토 |
|---|---|---|
| C2(개인 정보·서버 로그·캐시), C1(사용자 글 저장), A2(영구 기록 `study_log.gd`), B2·B3(규칙 파이썬↔GDScript 일치, 팩 해시) | 높음 | `reviewer` 판정 + 오케스트레이터가 핵심 명령(C2-3~C2-5, C1-4, A2-6, B3-3, B2-5)을 직접 다시 실행 |
| A1, A4, A5, B1, B2t, B4, C3, S, W | 보통 | `reviewer` 1회(W·S 는 기존 시험 변경이 있어 diff 를 §2.6 과 대조) |
| Z | 낮음 | 오케스트레이터 확인 |
- 불합격 사유는 **중요**(합격 조건 X·버그·보안)만. 왕복 최대 3라운드, 그 뒤엔 오케스트레이터가 접근을 다시 정한다. `REVIEW.md` 의 실패 항목(화면 시험이 실제 버튼을 안 누름, 보이는 숫자가 내부 단위, 실제 사용자 폴더에 씀 등)을 검토자가 먼저 본다.

### 3.5 소유권 검사 스크립트 (오케스트레이터·검토자가 합치기 전에 돌린다)
저장소 루트에서 실행. 두 작업이 같은 파일을 소유하면, 기존 파일 목록에 없으면, 새 파일이 이미 있으면 `FAIL` 을 찍고 종료 코드 1.
```powershell
@'
import re, sys, os
doc = open("docs/v170_design.md", encoding="utf-8").read()
blk = doc.split("<!-- OWN-BEGIN -->")[1].split("<!-- OWN-END -->")[0]
owner, bad = {}, 0
for line in blk.strip().splitlines():
    task, kind, path = line.split(None, 2)
    p = path.strip().replace("\\", "/").lower()
    if p in owner and owner[p] != task:
        print("FAIL overlap:", p, owner[p], task); bad += 1
    owner[p] = task
    exists = os.path.exists(path.strip().replace("\\", "/"))
    if kind == "mod" and not exists:
        print("FAIL missing existing file:", path); bad += 1
    if kind == "new" and exists:
        print("FAIL new file already exists:", path); bad += 1
print("files", len(owner), "tasks", len(set(owner.values())), "FAIL" if bad else "OK")
sys.exit(1 if bad else 0)
'@ | python -X utf8 -
```
기대 출력: 마지막 줄 `files 81 tasks 15 OK`(파일 수는 이 표 기준. 문서를 고치면 같이 고친다).

---

## 4. 작업별 합격 조건 (O/X)

### 4.1 공통 합격 조건 (모든 작업에 붙는다)
시험 명령 형식: `$G = 'C:\Users\rtyu6\Desktop\Godot_v4.6.3-stable_win64.exe\Godot_v4.6.3-stable_win64_console.exe'`, `$env:APPDATA = '<scratchpad>\w_<작업>\appdata'`(실제 사용자 폴더를 읽고 쓰지 않게), 실행 `& $G --headless --path <worktree>\godot [--resolution 412x915] res://tests/<이름>.tscn [-- --phone] [--font-scale=1.5] [--dark] [--api=http://127.0.0.1:9]`. 파이썬: `backend\.venv\Scripts\python.exe`. 라이브 서버 시험은 비어 있는 포트(18801~18899, `Get-NetTCPConnection` 으로 확인)에 `python backend\server.py --port <p> --tag <작업> --stt-cpu` 로 띄우고 자기가 시작한 PID 만 종료한다.

| ID | 조건 | 판정 |
|---|---|---|
| C-0 | **작업 전** 자기가 건드리는 기존 시험의 기준선(마지막 줄 `N passed, M failed`, 종료 코드)을 `<scratchpad>\w_<작업>\baseline.txt` 에 적고 보고서 맨 앞 표에 붙인다 | 파일·표 있음 = O |
| C-1 | 자기 시험 전부 마지막 줄이 `N passed, 0 failed` 이고 종료 코드 0. 화면 시험은 PC 와 `-- --phone`(412x915) 둘 다, 더해서 `--font-scale=1.5` 와 `--dark` | O/X |
| C-2 | 출력에 `SCRIPT ERROR:` 0줄 | 0건 = O |
| C-3 | Godot 시험 출력에 `TEST_GUARD on` 정확히 1줄 | 1건 = O |
| C-4 | 접속 금지: 시험·코드·명령에 `8770`, `8775`, `8776` 이 0번. 화면 시험은 `-- --api=http://127.0.0.1:9`(`practice_test`·`touch_scroll_test` 는 `--api` 없이). 새 파일에 `HTTPRequest`, `OS.shell_open`, `OS.request_permission` 0줄 | `rg -n "HTTPRequest\|shell_open\|request_permission" <새 파일>` 0줄 |
| C-5 | 기존 시험 기대값을 근거 없이 완화하지 않는다: 시험 diff 에서 지워지거나 느슨해진 단언은 §2.6 에 적힌 것만. 기준선 passed 보다 줄면 이유가 §2.6 에 있어야 한다 | diff 검토 + 표 대조 |
| C-6 | 소유 밖 파일 수정 0: `git -C <worktree> diff --name-only <기준 커밋>` ⊆ §3.3 의 그 작업 목록(+ 자기 새 파일의 `.uid`) | 부분집합 = O |
| C-7 | `git -C <worktree> diff --stat -- godot\project.godot godot\export_presets.cfg` 가 비어 있다 | 비어 있음 = O |
| C-8 | 프로세스는 자기가 시작한 PID 만 종료. 보고에 "남은 프로세스·열린 포트 없음" | 보고 문구 |
| C-9 | 실제 사용자 폴더(`%APPDATA%\Godot\app_userdata\…`) 쓰기 0: 시험 전후 파일 이름·크기·수정 시각 목록이 같다. 새 시험은 `DiaryStore.path`·`StudyLog.path`·`Store.prefs_path`·`Store.progress_path` 를 `user://test_*` 로 바꿔 쓴다 | 전후 같음 |
| C-10 | 비밀값(키·토큰·auth) 출력·기록 0. **일기·받아쓰기 입력 원문 마커**(시험이 쓰는 `ZZ_MARK_9731` 류 문자열)가 시험 출력에 0번 | `Select-String ZZ_MARK <출력 파일>` 0건 |
| C-11 | 새 파일에 이모지·도형 글자(✦♥★ 등) 0, `Color("#` 0: `rg -n "Color\(\"#" <새·바뀐 .gd>` 0줄 | 0줄 |
| C-12 | **검사기도 실패할 수 있어야 한다**: 새 시험마다 일부러 틀린 입력을 같은 검사 함수에 넣어 "실패로 판정되는지"를 찍는 줄(`selfcheck FAIL-as-expected …`)이 있다. 더해서 작업마다 §4.2 에 지정한 상수/조건 하나를 일부러 틀리게 바꾸면 시험이 **FAIL 하는 출력 줄**을 보고서에 붙이고 `git checkout` 으로 원복(원복 뒤 시험 통과 줄도 붙임) | 출력 줄 존재 |
| C-13 | 읽지 못한 결과·실행하지 않은 항목은 O 가 아니라 "미검증" | 보고 형식 |
| C-14 | **(REVIEW.md) 화면 흐름 시험은 실제 버튼을 누른다**: 흐름 시험은 `answer()`·`next_*()`·`check()`·`send_*()` 같은 함수를 직접 불러 단계를 넘기지 않고, 보기·확인·다음·시작 `Button` 의 `pressed.emit()` 으로만 끝까지 간다. 누를 때마다 `print("press: <버튼 이름>")` 을 찍고, 매 단계 뒤 피드백·다음 버튼이 `visible` 이고 `disabled` 가 아닌지 단언한다. §4.2 에 `press:` 줄 최소 개수가 적혀 있다 | 출력의 `press:` 줄 수 ≥ 지정값 |
| C-15 | **(REVIEW.md) 보이는 숫자는 읽을 수 있는 단위**: 화면의 어떤 `Label`/`Button` 글에도 연속 5자리 이상 숫자가 없고(unix 시각·ms·바이트 직접 표시 금지), 날짜는 "11월 14일 (금)" 꼴, 시간은 분·시간, 진행 표시(`value/target`)를 만드는 곳은 한 함수로 모은다. 시험이 화면 전체 글을 훑어 `\d{5,}` 를 찾는 검사를 한다(일부러 `12345` 를 넣은 가짜 화면에서 그 검사가 실패하는 `selfcheck` 포함) | 검사 PASS + selfcheck 줄 |
| C-16 | 공개 스크립트 호환: `git -C <worktree> diff --name-only <기준> -- backend/tools` 가 기존 허용 파일(`make_mission_golden.py`)만, 새 파일 0 | 0건 = O |

보고 맨 앞: 합격 조건 표(항목 / O·X·미검증 / 근거 = 실행한 명령과 출력 요약).

### 4.2 작업별 상세

#### A1 — 일본어 받아쓰기 채점 (`worker-hard`, 1파)
- 하는 일: §2.1 의 `DictationDiffJa`(fold·segments·diff·first_hint), 시험(말뭉치는 `res://data/pack/practice_ja.json`, 시험 경로는 `res://`).
| ID | 조건 | 명령 → 기대 |
|---|---|---|
| A1-1 | 시험 통과 | `dictation_diff_ja_test` → `== dictation_diff_ja: N passed, 0 failed ==` |
| A1-2 | 정답 말뭉치: `ja_dictation_ok` 규칙(글자 6~24·숫자/영문 없음)을 통과하는 `practice_ja.json` 문장 전부(내가 센 값 1,693개, 시험이 실제 개수를 찍는다)에서 ① 표기 그대로 ② 읽기(히라가나) 그대로 ③ 표기를 가타카나로 바꾼 것 세 방식 모두 점수 100, `mode` 가 ①②③ 각각 `exact`/`reading`/(가타카나로 바꾼 한자 없는 문장은 `exact`) | 시험 줄 PASS, 100% |
| A1-3 | 혼합 표기: 한자 덩어리 하나만 읽기로 바꾼 입력 → 100점, `mode "mixed"`, 정렬(`segments`) 성공 문장에서 ≥ 98%. 정렬을 못 해 대체 경로로 간 문장 수와 id 를 보고(**임계 98%는 초기 추측값. 측정 후 오케스트레이터가 조정**) | 시험이 비율·실패 id 를 찍음 |
| A1-4 | 변이 1,000건(고정 시드): 읽기 한 글자 삭제 / 다른 글자로 교체 / 한 글자 추가 → 점수 100 아님 **100%**, 틀린 칸이 `units` 에서 `ok false` 로 표시된 비율 ≥ 95%(변이 위치를 포함하는 유닛) | 시험 PASS |
| A1-5 | 통과선: 읽기 12자 이상 문장 + 한 글자 틀림 → `passed true`, 읽기 6자 문장 + 한 글자 틀림 → `passed false`, 틀린 글자 3개 이상 → 점수 ≤ 84 | 시험 PASS |
| A1-6 | 기존 점수보다 낮지 않음: 표기만·읽기만 입력 전체에서 `diff().score >= TextSim.similarity(said, text, reading, "ja")["score"]` | 위반 0건 |
| A1-7 | 허용하는 표기 차이와 허용하지 않는 것(§2.1 목록)을 사례 표로 단언: `パイロット`=`ぱいろっと`, 전각 `ｐ` 등, 공백·`、。` 유무, `行なう`=`行う`(읽기 풀이), `ラーメン`≠`ラアメン`, `は`를 `わ`로 쓴 것은 틀림, 작은 가나 `ゃ`→`や` 틀림 | 시험 PASS(≥ 20행) |
| A1-8 | 한자 덩어리 자리에 다른 한자를 쓰면 그 유닛 `kind "kanji_diff"`, `ok false`, 나머지 유닛은 정상 | 시험 PASS |
| A1-9 | **일부러 틀린 입력**: `""`, `"   "`, `"abc"`, 영어 문장, 한글 문장, 10,000자(300자에서 잘림, 100 ms 안에 끝남), `reading == ""`(표기만 비교), `text == ""`, `null` 비슷한 값(`Variant`로 문자열 아님) → 점수 0 또는 안전한 값, 에러 0, 반환 키 전부 존재 | `selfcheck FAIL-as-expected` 줄 + PASS |
| A1-10 | `segments` 불변식: 모든 말뭉치 문장에서 조각 `s` 를 이으면 `fold(text)`, `r` 을 이으면 `fold(reading)`. 대체 경로(한 조각)는 ≤ 3%(**추측 임계. 측정값 보고**) | 시험 PASS + 비율 줄 |
| A1-11 | 기존 시험 회귀 없음(수정 안 함): `dictation_test`, `song_study_test`, `memo_grade_test` 0 failed, passed ≥ 기준선 | C-0 표 |
| A1-12 | 상수를 일부러 틀리게 | `PASS_SCORE` 85 → 60 으로 바꾸면 A1-5 가 FAIL 하는 줄을 붙이고 원복 |
- 금지: `text_sim.gd`·`dictation_diff.gd`·`song_study.gd` 수정, 네트워크, 소유 밖 파일.

#### A2 — 일본어 소리 코어·기록 (`worker-hard`, 1파, 위험도 높음: 영구 기록)
- 하는 일: §2.2 의 `JaSounds`, `ja_sounds.json`(작업자가 scratchpad 스크립트로 OpenJTalk 읽기·발음형을 만들어 채움), `StudyLog.add_phon_obs` 와 `add_score_any` 의 일본어 `annotate`.
| ID | 조건 | 명령 → 기대 |
|---|---|---|
| A2-1 | 시험 3종 통과 | `ja_sounds_test`, `ja_sounds_data_test`, `study_log_ja_test` → 각 `N passed, 0 failed` |
| A2-2 | `events` 표(≥ 25행)가 맞다. 각 행의 기대는 "이 카테고리 이벤트가 이 모라 번호에 있다"(규칙상 다른 이벤트가 더 있어도 됨)와 "이 카테고리는 없다". 최소 행: `おばあさん` long@2(あ), `おとうさん` long@2(う), `せんせい` long@3(い), `きって` sokuon@1, `がっこう` voice@0(が)+sokuon@1+long@3(う), `つき` tsu@0, `ざっし` voice@0+za@0+sokuon@1, `じゃがいも` za@0(じゃ)+voice@1(が)이고 long 은 없음(が 뒤의 い 는 장음이 아님), `びょういん` youon@0+long@1(う), `おばさん` long 없음, `かんこく` sokuon 없음 | 시험 PASS |
| A2-3 | `annotate`: 샘플 일본어 `/score` 응답에 `ph` 가 붙고(`units[i].ph[].p` 가 카테고리), 두 번 불러도 항목 수 불변, 영어 응답·`units` 없음·`t` 가 가나 아님·사전이 아님은 0 이고 입력을 바꾸지 않음 | 시험 PASS |
| A2-4 | 데이터 린트: 필수 카테고리 5개 존재, 쌍 개수(§2.2), 모든 `a`·`b` 가 `gloss_ja.json` 표제어에 있음, `a_rd != b_rd`, `rd`/`a_rd`/`b_rd` 히라가나만(+`ー`), `pr` 가타카나만, 한국어 글자 포함, 중복 낱말 쌍 0, 파일 ≤ 120,000 바이트 | `ja_sounds_data_test` PASS |
| A2-5 | 읽기 정확성: scratchpad 스크립트가 `backend\server.py` 의 `ja_reading`·`ja_pron` 으로 **모든** `rd`/`pr` 를 다시 만들어 데이터와 같음을 확인(불일치 0). 보고에 스크립트 이름과 출력 요약, 검토자가 20개를 다시 만든다 | 보고 + 재실행 |
| A2-6 | 기록: `add_score_any("ja", res)` 뒤 `weak_phonemes("ja", 6, 1)` 에 해당 카테고리가 오고, `add_phon_obs` 5번(틀림 4·맞음 1)이면 `rate == 0.8`, `heard` 집계. 잘못된 입력(`p=""`, 13자 `p`, 언어 `"fr"`)은 false 이고 파일 상태 불변. 영어 경로는 바뀌지 않음(`study_log_test`·`study_log_fun_test` 0 failed, passed ≥ 기준선) | 시험 PASS |
| A2-7 | 동기화·호환: 새 키 6개가 든 파일이 `SyncDoc` 정리를 통과하고 `run_sync_tests.ps1` 0 failed; `phon.ja` 가 `{}` 인 옛 파일이 그대로 읽힘 | `run_sync_tests.ps1` → 0 failed |
| A2-8 | **일부러 틀린 입력**: `events("")`, `events("abc")`, 한글, `null` 비슷한 값 → `[]`; `build_listen_session("nope", …)` → `[]`; 데이터가 깨졌을 때(`load_data` 가 `ok=false`) 앱이 죽지 않음 | `selfcheck FAIL-as-expected` 줄 |
| A2-9 | 상수를 일부러 틀리게 | `events` 의 장음 모음 대응에서 `う` 를 빼면 A2-2 가 FAIL 하는 줄을 붙이고 원복 |
- 금지: `phoneme_stats.gd`·`phoneme_screen.gd` 수정, 영어 기록 의미 변경, `StudyLog` 새 최상위 키, `SyncDoc` 수정, 네트워크.

#### A4 — 일본어 받아쓰기 화면·문장 (`worker-hard`, 2파)
- 하는 일: §2.1 의 서버·폰 문장 규칙(`ja_dictation_ok`, `SESSION_N_JA`), `DictationScreen` 의 일본어 분기(문장 요청 `lang=ja`, `DictationDiffJa` 채점, 칩, 힌트, 읽기·한글 소리 줄, `no_voice` 안내, 복습 카드 `reading`, 로그·XP `"ja"`).
| ID | 조건 | 명령 → 기대 |
|---|---|---|
| A4-1 | 새 화면 시험 통과(`sample_practice_dictation_ja.json` 로 서버 없이) | `dictation_ja_screen_test` PC·`-- --phone` → `== dictation_ja_screen: N passed, 0 failed ==` |
| A4-2 | **실제 버튼 흐름**: 일본어로 6문장을 끝까지 — [▶ 듣기] 누름 → 입력 → [확인] 누름 → 결과 카드(점수·칩·정답·읽기) 보임 → [다음 ▶] 누름 → … → [결과 보기] → 요약 → [다시 하기] 누름 → 새 문장. 매 단계 피드백·다음 버튼 `visible`·`disabled` 아님 단언. [모르겠어요]·[첫 글자 힌트] 도 눌러 봄 | `press:` 줄 ≥ 30, FAIL 0 |
| A4-3 | 채점 연결: 표기 그대로 입력 → "표기까지 맞음", 가나만 입력 → "읽기가 맞아요(한자를 가나로 씀)", 한 글자 틀림 → 해당 칩이 `✕` 와 이유 글을 가짐, 영어 화면은 지금과 같은 글(단어 칩)을 그대로 보임 | 시험 PASS |
| A4-4 | 소리 없음: `KanaVoice.available()` 가 false 면 문장 요청 없이 `stage "no_voice"` 안내와 [연습으로] 버튼, 요청 0건 | 시험 PASS(요청 카운터 0) |
| A4-5 | 복습 카드: 85점 미만 문장 최대 5개가 `{lang:"ja", target:<표기>, reading, ko, note:"받아쓰기"}` 로 들어가고 같은 문장은 중복으로 안 들어감. `StudyLog.add_event("ja","dictation")` 가 시도마다, XP·오늘 공부 표시는 영어와 같은 규칙 | 시험 PASS |
| A4-6 | 서버: `test_practice.py` 가 일본어 dictation 200, 문장이 `ja_dictation_ok`(글자 6~24, 숫자·영문 없음, 읽기 히라가나만), 영어 dictation·shadow 는 그대로, 잘못된 `lang`/`mode` 는 한글 400 | `backend\.venv\Scripts\python.exe backend\test_practice.py --base http://127.0.0.1:<p>` → 0 FAIL, 미검증 0(라이브 서버에 Tatoeba DB 가 없으면 "미검증" 으로 적고 그 사유) |
| A4-7 | 폰: `local_lessons_test` 가 폰 일본어 dictation 200·규칙 통과(§2.6), 영어 단언은 그대로, 폰 후보 개수가 1,000개 이상(내가 센 1,693 근거) | `local_lessons_test` → 0 failed |
| A4-8 | 일부러 틀린 입력: 빈 입력으로 [확인] → 아무 일 없음(버튼 꺼짐), 공백만, 영어 문장, 1만 자(300자에서 잘림), 이상한 서버 응답(`sentences` 가 문자열)·빈 응답 → 오류 안내 화면(`error`/`empty`), 에러 0 | `selfcheck FAIL-as-expected` |
| A4-9 | 보이는 숫자(C-15): 결과 점수는 "92점", 글자 수는 "14자", 들은 횟수 | C-15 검사 PASS |
| A4-10 | 기존 시험: `dictation_test`(영어 화면·`DictationDiff`) 0 failed passed ≥ 기준선(수정 안 함). `practice_test` 는 **알려진 예상 실패만**: §2.6 의 `practice_test.gd` 줄(일본어 받아쓰기 `unsupported`, 카드 6개 확인은 이 작업에서 안 바뀜) — 예상 실패 줄 번호·메시지를 보고에 적고, 그 밖의 실패는 0 | 보고 표 |
| A4-11 | 상수를 일부러 틀리게 | `SESSION_N_JA` 를 6 → 3 으로 바꾸면 A4-2 의 "6문장 끝까지" 가 FAIL 하는 줄을 붙이고 원복 |
- 금지: `phoneme_screen.gd`·`practice_view.gd` 수정, `DictationDiff`·`TextSim` 수정, 영어 받아쓰기 동작 변경, 서버 새 라우트.

#### A5 — 일본어 약한 소리 화면 (`worker-hard`, 2파)
- 하는 일: `JaSoundScreen`(목록·설명·듣고 고르기·따라 말하기·요약), `JaSounds`·`StudyLog.add_phon_obs`·`SpeakDrill` 를 읽어서 쓴다.
| ID | 조건 | 명령 → 기대 |
|---|---|---|
| A5-1 | 시험 통과 | `ja_sound_screen_test` PC·`-- --phone` → `N passed, 0 failed` |
| A5-2 | **실제 버튼 흐름(듣고 고르기)**: 목록에서 [장음] 칩 누름 → 설명 화면(쌍 목록) → [듣고 고르기 시작] 누름 → 10문항을 보기 버튼(`pressed.emit()`)으로 끝까지, 매 문항 정답/오답 표시와 [다음 ▶] 가 보임 → 요약(정답률, 틀린 쌍) → [소리 목록으로] 누름. 소리는 `Tts.fetch_hook` 으로 가로채 재생된 낱말(`a`/`b`)이 문항의 `play` 와 같음을 단언 | `press:` 줄 ≥ 24, FAIL 0 |
| A5-3 | 채점 근거: 재생한 쪽과 같은 보기를 누르면 정답, 다른 쪽이면 오답이고 `phon.ja.<p>` 에 맞음/틀림 한 건씩(틀림이면 `heard` 에 고른 쪽 낱말) 기록 | 시험 PASS(`StudyLog.weak_phonemes`) |
| A5-4 | 따라 말하기: `SpeakDrill.score_hook`/`api_hook` 로 가짜 `/score` 응답(모라 `ok`/`heard`)을 넣으면 `JaSounds` 판정이 이 소리 칸에 반영, PC 연결 없음(`needs_pc`)이면 자가 평가 버튼이 보이고 통계에는 안 들어감 | 시험 PASS |
| A5-5 | 소리 없음(`KanaVoice.available()` false): 듣고 고르기·▶ 버튼 꺼짐, 안내 한 줄, 설명·쌍 읽기는 보임 | 시험 PASS |
| A5-6 | 데이터 이상(`JaSounds.load_data` `ok=false`, 쌍 없는 카테고리 `j_za`): 화면이 죽지 않고 안내/낱말·구절 중심으로 동작 | 시험 PASS |
| A5-7 | 끝나면 XP 10 한 번, `StudyLog.add_event("ja","drill",1)` 한 번(10문항 끝낼 때). 틀린 낱말 복습 카드: `{lang:"ja", target, reading, ko, note}`, 중복 안 들어감 | 시험 PASS |
| A5-8 | 안내 문구: "인식된 글자와 비교한 추정이에요" 가 따라 말하기 결과 화면에 보임. 보이는 숫자 C-15 | 시험 PASS |
| A5-9 | 상수를 일부러 틀리게 | `build_listen_session` 의 `answer` 를 항상 0 으로 바꾸면 A5-2 가 FAIL 하는 줄을 붙이고 원복 |
- 금지: `phoneme_screen.gd`·`speak_drill.gd`·`practice_view.gd` 수정, 영어 `/practice/phoneme*` 변경.

#### B1 — 미션 서버 엔진 (`worker-hard`, 1파)
- 하는 일: §2.3.1 의 `missions.py` 변경, `test_missions.py` 를 일본어까지 확장(린트 규약 §2.3.2, 일부러 틀린 콘텐츠 변형, 정규화 단위 시험, 판정 프롬프트·증거 인용). 일본어 콘텐츠가 아직 없어도 시험용 임시 콘텐츠(`HOEHWA_CONTENT_DIR` 의 scratchpad 사본)로 돌린다.
| ID | 조건 | 명령 → 기대 |
|---|---|---|
| B1-1 | 린트·단위 시험 | `backend\.venv\Scripts\python.exe backend\test_missions.py --lint` → `== test_missions result: N passed, 0 failed, 0 미검증 …` 종료 코드 0 |
| B1-2 | 영어 회귀: 영어 `GET /missions?lang=en`·`/missions/check` 응답이 변경 전과 **바이트 단위로 같다**(변경 전 응답을 scratchpad 에 저장해 비교), `normalize("Hello, I'd like a latte!")` 같은 영어 정규화 결과 동일 | 시험 PASS |
| B1-3 | `normalize_ja` 사례(≥ 20행): `ラーメン` → `らーめん`, 전각 `ＡＢＣ１２３` → `abc123`, 반각 `ｺﾞｼﾞｮｳ`/`ﾊﾟｲﾛｯﾄ` → 히라가나(`ごじょう`·`ぱいろっと`), `。、！? 「」` 삭제, 공백 삭제, 300자 자름, 한자 유지, 이모지·기호 삭제, 빈 문자열 | 시험 PASS |
| B1-4 | 일본어 목록·체크: 임시 일본어 미션으로 `GET /missions?lang=ja` 가 `unsupported:false` 와 목록, `/missions/check` 가 어미 변형(`ください`/`くださいませんか`/`ほしいです`)·가타카나·전각 입력으로 목표를 달성/미달성 판정, 영어 미션 id 로 `lang=ja` 요청은 404, 일본어 id 로 `lang=en` 은 404 | 시험 PASS |
| B1-5 | 판정(`/missions/judge`): 가짜 `llm_json` 으로 ① 증거가 학습자 문장에 있음 → 인정 ② 증거가 상대(PARTNER) 문장에만 있음 → 불인정 ③ 증거 1글자·81자 이상 → 불인정 ④ 전각/가타카나만 다른 증거 → 인정(`normalize_ja` 비교) ⑤ 학습자 문장 없음 → AI 호출 0회 ⑥ 프롬프트에 `Japanese learner`, 영어 프롬프트는 바이트 그대로 | 시험 PASS |
| B1-6 | **일부러 틀린 콘텐츠**(린트가 실패해야 함): 일본어 id 접두어 없음, `pos` 5개, 히라가나만인 `pos` 없음, 한자 `pos` 없음, `neg` 가 달성되는 규칙, `ai` 에 한글, `*_rd` 에 한자, 대본이 목표를 못 채움, 안전하지 않은 정규식(`(.+)+`), `\b` 사용 | 변형마다 `FAIL-as-expected` 줄 |
| B1-7 | 정규식 폭탄: 300자 일본어 입력(`あ`×300, `ください`×60 등)에서 체크가 50 ms 안에 끝남 | 시험 PASS |
| B1-8 | `public_mission` 가 정답 규칙(`match`·`pos`·`neg`·`goal_en`)을 어떤 응답에도 내지 않음(재귀 검사) | 시험 PASS |
| B1-9 | 상수를 일부러 틀리게 | `normalize_ja` 의 가타카나→히라가나 변환 오프셋을 `0x60` → `0x50` 으로 바꾸면 B1-3 이 FAIL 하는 줄을 붙이고 원복 |
- 금지: 일본어 콘텐츠 파일(`content\missions.json`) 수정(B2 소유), 새 라우트, `lan.py` 수정, 영어 응답 변경.

#### B2 — 일본어 미션 콘텐츠 (`worker-hard`, 2파, 위험도 높음: 규칙 품질·팩 해시)
- 하는 일: §2.3 표의 8개 미션을 `backend\content\missions.json` 에 추가(`match`/`pos`/`neg`/`script`/읽기 필드). 읽기·발음형은 scratchpad 스크립트로 `ja_reading`·`ja_pron` 에서 만든다. 끝나면 `build_phone_pack.py --only content` 로 팩 복사본·매니페스트 갱신.
| ID | 조건 | 명령 → 기대 |
|---|---|---|
| B2-1 | 린트(일본어 8개·최종 세트) | `python backend\test_missions.py --lint --full` → `0 failed, 0 미검증`, 일본어 목표 수 합 ≥ 34(영어 34와 비슷한 규모), 목표마다 `pos` ≥ 6 / `neg` ≥ 5 |
| B2-2 | 영어 8개는 바이트 그대로: 변경 전 `missions.json` 에서 `lang=="en"` 항목만 뽑은 JSON 해시 = 변경 후 같음 | 해시 일치 |
| B2-3 | 어미·경어 변형 폭: 목표마다 `pos` 에 ① 히라가나만 ② 한자 섞임 ③ 보통체 ④ 조사 생략 형태가 하나씩 이상(작업자가 표로 보고) | 보고 표 |
| B2-4 | 자체 새 문장 점검(작성자 본인이 쓴 새 문장 ≥ 목표당 8개 positive·6개 negative)의 과소 판정 ≤ 15%, 과대 판정 ≤ 10% (독립 문장 시험 B2t 가 따로 다시 잰다) | 측정값 보고 |
| B2-5 | 팩 동기화: 팩 `missions.json` 이 `backend\content\missions.json` 과 **바이트 같고**, `manifest.json` 의 해시·records(16)가 맞음 | `backend\.venv\Scripts\python.exe backend\test_phone_pack.py` → 0 FAIL; `packaging\check_phone_pack.ps1` → OK(출력 보고) |
| B2-6 | 안전: 병원 미션 `scene` 에 "진단·약 용량을 말하지 않는다" 규칙, 대사에 구체적 약·용량 없음. 모든 미션 `scene` 에 "학습자가 할 말을 알려 주지 않는다" | 린트 또는 `Select-String` 확인 |
| B2-7 | 정규식 안전: 모든 일본어 패턴이 `unsafe_regex` 통과(린트에 포함), `\b`·`\s` 0개 | 린트 PASS |
| B2-8 | 일부러 틀린 입력: 각 목표의 `neg` 문장을 영어로 바꾼 것·빈 문장·같은 문장 반복(`はい`×300)이 어떤 목표도 달성하지 못함 | 시험 PASS(스크립트 출력 보고) |
- 금지: `missions.py` 수정, 영어 미션 변경, `build_phone_pack.py` 수정(실행만), `backend\tools\` 새 파일, 기존 8개의 id·순서 변경.

#### B2t — 독립 문장 시험 (`worker-hard`, 3파, **B2 작성자와 다른 작업자**)
- 하는 일: B2 의 콘텐츠를 보지 않고(목표 라벨 `label_ko` 와 §2.3 표만 보고) 목표마다 새 일본어 문장(positive ≥ 8, negative ≥ 6, 다양한 어미·경어·조사 생략·가타카나)을 써서 `backend\test_missions_ja.py` 에 넣고 `missions.check_text` 로 잰다.
| ID | 조건 | 명령 → 기대 |
|---|---|---|
| B2t-1 | 독립 문장 점검 | `python backend\test_missions_ja.py` → 과소 판정 ≤ 15%(목표별 ≤ 30%), 과대 판정 ≤ 10%, 실패 문장 전부를 목표·문장과 함께 출력 |
| B2t-2 | 이 시험 자체: 일부러 규칙을 망가뜨린 콘텐츠 사본(모든 목표의 `any` 를 빈 문자열 한 개로)에서 과소 판정 100%로 FAIL | `FAIL-as-expected` 줄 |
| B2t-3 | 기준 초과 시 실패 문장을 B2 작성자에게 되돌려 고친다(같은 종류의 누락을 목표 전체에서 한 번에) | 보고 |
- 금지: `missions.json` 수정(실패는 보고만).

#### B3 — 폰 미션 엔진·황금 파일 (`worker-hard`, 3파, 위험도 높음: 파이썬↔GDScript 일치)
| ID | 조건 | 명령 → 기대 |
|---|---|---|
| B3-1 | 시험 통과 | `local_missions_test`, `mission_text_test` → 각 `N passed, 0 failed` (PC·`-- --phone`) |
| B3-2 | 황금 파일 재생성: `backend\.venv\Scripts\python.exe -I backend\tools\make_mission_golden.py` 로 영어 30개(기존 값 불변)+일본어 ≥ 24개, `local_missions_test` 가 일본어 입력의 `reached` 집합·정규화 문자열이 PC 엔진과 **전부 같음** | 시험 줄 `golden ja` PASS |
| B3-3 | 폰 팩의 일본어 목표 전부: `pos` 전부 달성·`neg` 전부 미달성(`LocalMissions.normalize(s, "ja")` 로) — 파이썬 린트와 같은 결과. 정규식이 GDScript(PCRE2)에서 컴파일 실패하는 일본어 미션 0개 | `disabled_missions()` 가 빈 배열 |
| B3-4 | 목록·체크: `GET /missions?lang=ja` 8개(`unsupported:false`), 영어 8개, 선택 필드가 통과, 다른 언어 id 는 404, 영어 응답은 변경 전과 같음 | 시험 PASS |
| B3-5 | NFKC 부분집합: 전각 영숫자, 반각 가타카나(탁점·반탁점 결합), U+3000 → 파이썬과 같음. 알려진 차이(호환 기호 `㌔` 등)는 시험이 "표에 있는 차이"로 명시(황금 입력에는 없음) | 시험 PASS |
| B3-6 | 깨진 정규식 한 미션만 빠지고 나머지는 동작(기존 F15 시험을 일본어에도). 팩이 없음/깨짐이면 기존 `pack_missing`/`pack_corrupt` | 시험 PASS |
| B3-7 | **일부러 틀린 입력**: 빈 문장, 공백만, 1만 자, 영어 문장, 이모지, 제어 문자, `text` 가 문자열이 아님 → 400 또는 미달성, 에러 0 | `selfcheck FAIL-as-expected` |
| B3-8 | 상수를 일부러 틀리게 | `MissionText` 의 가타카나 오프셋을 틀리게 하면 B3-2 가 FAIL 하는 줄을 붙이고 원복 |
- 금지: `missions.py`·콘텐츠 수정, 영어 정규화 변경, 앱 화면 파일 수정.

#### B4 — 일본어 미션 화면 (`worker-hard`, 2파)
| ID | 조건 | 명령 → 기대 |
|---|---|---|
| B4-1 | 시험 통과 | `mission_test`, `mission_ja_flow_test` PC·`-- --phone` → `N passed, 0 failed` (`practice_test`·`touch_scroll_test` 는 `--api` 없이) |
| B4-2 | **실제 버튼 흐름(대본 모드)**: 일본어 탭 목록에서 미션 카드 누름 → 상황 설명 → [대본으로 연습] 누름 → 상대 말풍선(일본어 + 히라가나 읽기 + 한글 소리 줄 보임) → 입력칸에 일본어 입력 → [보내기] 누름 → 목표 체크 표시가 바뀜 → … 목표 전부 → 결과 화면의 별·XP → [목록으로] 누름. 매 단계 목표 패널의 `n / m` 이 바뀌는지 단언 | `press:` 줄 ≥ 20 |
| B4-3 | AI 모드: 가짜 `/chat`(`sample_mission_chat_ja.json`)·`/missions/check`·`/missions/judge` 응답으로 [보내기] 누름 → 상대 답이 읽기와 함께 보임 → 놓친 목표는 `/missions/judge` 로 **증거가 내 문장에 있을 때만** 체크, 증거가 없거나 상대 문장에서 따온 것이면 체크 안 됨 | 시험 PASS |
| B4-4 | `MissionLogic.apply_judge(..., "ja")`: 가타카나/전각만 다른 증거 인정, 상대 문장 증거 불인정, 빈 증거 불인정. 영어 호출(`lang` 생략)은 기존 동작 그대로 | 시험 PASS |
| B4-5 | 목록: 일본어 탭에서 8개 카드(영어와 같은 구조), 별 표시는 `StudyLog.mission_best(id)`, 영어 탭은 영어 8개만. 옛 서버가 주는 `unsupported:true` 일본어 응답은 기존 안내로 처리(호환) | 시험 PASS |
| B4-6 | 읽기·한글 소리 줄: 설정 `show_reading` 끔 → 히라가나 줄 숨김, `show_hangul_ja` 끔 → 한글 줄 숨김(`ReadingLine` 규칙) | 시험 PASS |
| B4-7 | 일부러 틀린 입력: 빈 입력 [보내기] 무반응, 1만 자(300자에서 자름), 서버 오류·옛 서버 404 안내, `*_rd` 가 없는 미션(읽기 줄 없이 동작), 목표가 12개 초과 | `selfcheck FAIL-as-expected` |
| B4-8 | 보이는 숫자(C-15): 별·목표·턴 수 | C-15 검사 PASS |
| B4-9 | 상수를 일부러 틀리게 | `MissionLogic.PASS_SIM` 60 → 100 으로 바꾸면 대본 모드 통과 단언이 FAIL 하는 줄을 붙이고 원복 |
- 금지: `local_missions.gd`·`missions.py`·콘텐츠 수정, 영어 미션 동작 변경, 새 요청 경로.

#### C1 — 일기 저장·로직 (`worker-hard`, 1파, 위험도 높음: 사용자 글 저장)
| ID | 조건 | 명령 → 기대 |
|---|---|---|
| C1-1 | 시험 통과 | `diary_store_test`, `diary_logic_test` → 각 `N passed, 0 failed` |
| C1-2 | 저장 계약(§2.4): 추가·갱신(같은 lang/date/text 는 한 개)·`set_fixed`·삭제·`clear`·`pending`·`counts`·`cards_today`, 저장 뒤 다시 읽어 같음, 파일이 `Progress.write_text_atomic` 로 쓰임(쓰기 훅으로 중간 실패를 흉내 내면 옛 파일 유지) | 시험 PASS |
| C1-3 | **일부러 틀린 파일**: 깨진 JSON → `.bad` 로 옮기고 빈 상태, 읽을 수 없음(`open_hook`) → 읽기 전용(저장 안 함), `entries` 가 배열이 아님, `text` 가 숫자·401자, `date` `2026-13-40`, `state` 가 모르는 값, `items` 4개, 중복 id, 1,001번째 일기, `cards_by_day` 가 쓰레기 | 에러 0, 정리/버림 줄 PASS |
| C1-4 | 시험 보호: `Progress.REAL_FILE_NAMES` 에 `diary.json` 이 있고, 시험 보호가 켜진 상태에서 `DiaryStore.path` 가 기본값이면 쓰기가 `user://test_guard/` 로 가거나 거절됨. 시험 전후 실제 `app_userdata` 목록이 같음 | 시험 PASS + 목록 비교 |
| C1-5 | `DiaryLogic.split`: 일본어 `。！？` 와 줄바꿈, 영어 `.!?`, 끝 부호 유지, 빈 문장 제거, 3문장 한도(`too_many`), `「…。」` 같은 따옴표 안 부호, 부호 없는 한 문장 | 시험 PASS(≥ 15행) |
| C1-6 | `check_input` 거절 사유: 빈 입력·공백, 301자, 4문장, 121자 한 문장, 일본어인데 알파벳뿐/한글뿐, 영어인데 한글뿐 → 각 `reason`, 정상 입력은 `ok` | 시험 PASS |
| C1-7 | `clean_fix` 검증(AI 출력): 정상, `fix` 빈 문자열(`same`), 원문과 같음(`same`), 한글이 든 영어 fix(`bad`), 가나·한자가 없는 일본어 fix(`bad`), 길이 비 초과(`bad`), 줄바꿈·제어 문자(제거), 사전이 아님·`fix` 가 숫자·`null`(`bad`), `why` 비었음(기본 문구), 300자 초과(자름) | 시험 PASS(≥ 14행) |
| C1-8 | `cards_for`: 고친 문장만, 원문이 어떤 필드에도 안 들어감(`orig` 문자열이 `target`/`note`/`ko` 어디에도 없음을 단언), 일기당 3개·하루 5개 상한(`today_cards` 인자), `same`/`bad` 제외, 설정 `auto_fix_cards` 꺼지면 호출측이 부르지 않음(함수는 순수) | 시험 PASS |
| C1-9 | `date_label("2026-11-14")` = `"11월 14일 (금)"`, 잘못된 날짜는 `""`. 화면용 숫자 단위 C-15 | 시험 PASS |
| C1-10 | 동기화 무관: `SyncDoc.extract` 결과·`StudyLog` 어디에도 일기 글이 없음(시험이 마커 문장을 저장한 뒤 `Store.progress`·`StudyLog.snapshot()`·`SyncDoc` 직렬화 문자열에서 마커를 찾아 0건) | 시험 PASS |
| C1-11 | 상수를 일부러 틀리게 | `MAX_SENTENCES` 3 → 5 로 바꾸면 C1-5/C1-6 이 FAIL 하는 줄을 붙이고 원복 |
- 금지: `store.gd`·`study_log.gd`·`sync\*` 수정, 일기 글을 로그(`print`/`push_warning`)에 출력, 새 최상위 `progress`/`studylog` 키.

#### C2 — `/fix` 개인 정보 모드 (`worker-hard`, 1파, 위험도 높음: 개인 정보)
- 하는 일: §2.4 의 `private` 필드. `test_fixcore.py` 처럼 `server.py` 함수를 **프로세스 안에서** 가짜 엔진(`server._remote_json`, `grammar.correct`/`check`)으로 시험한다(포트·네트워크 없음).
| ID | 조건 | 명령 → 기대 |
|---|---|---|
| C2-1 | 시험 통과 | `backend\.venv\Scripts\python.exe backend\test_fix_private.py` → 0 FAIL, 0 미검증, 종료 코드 0 |
| C2-2 | 응답 호환: `private` 생략·`false` 일 때 `/fix` 응답 키는 `fix`, `fix_ko` 뿐이고 결과·캐시 저장·로그가 변경 전과 같다(`test_fixcore.py` 0 FAIL, passed ≥ 기준선) | 비교 PASS |
| C2-3 | **캐시에 원문 없음**: 임시 `llm_cache.DB_PATH` 에서 마커 문장(`ZZ_MARK_9731きのう…`)으로 `private:true` 호출(LT 결과 있음 / 없음 / AI 다듬기 / AI 단독 네 경로) 뒤 DB 행 수 불변·마커 0건. `private:false` 는 지금처럼 저장(양성 대조 — 시험이 저장되는지도 확인해야 검사기를 믿는다) | 시험 PASS |
| C2-4 | **로그에 원문 없음**: `logging` 핸들러를 붙여 모든 로그 레코드(레벨 DEBUG 이상, 예외 트레이스백 포함)를 모아 `private:true` 호출 네 경로 + 실패 경로(AI 형식 오류·`ApiError`·LT 예외)에서 마커 0건. `private:false` 의 `AI polished … %r` 로그는 있음(양성 대조) | 시험 PASS |
| C2-5 | 파일 검사: 시험이 쓰는 임시 폴더 전체와(가능하면) 실제 `backend\logs\*.log`·`backend\cache\*` 를 마커로 훑어 0건. 라이브 LanguageTool 이 설치된 PC 에서는 `private:true` 호출 뒤 `backend\logs\languagetool.log` 도 훑는다(설치 안 됐으면 "미검증" + 사유) | 보고 |
| C2-6 | 응답 `reading`·`pron`: 일본어 `private:true` → `reading` 히라가나만·`pron` 가타카나만, 영어·고칠 것 없음 → `""`. 한글이 든 fix 는 기존 검증으로 거부되어 `fix == ""` | 시험 PASS |
| C2-7 | **일부러 틀린 입력**: `private` 가 문자열 `"yes"`/숫자/`null`(→ `false` 로 안전하게 취급, 422 아님), `text` 가 500자 초과(자름), 공백만(400 한글), `lang` 이 `"fr"`(400 한글), 제어 문자 | 시험 PASS |
| C2-8 | `lan.py` `ALLOW` 변경 0(`git diff --name-only` 에 없음), `/fix` 가 허용 목록에 이미 있음 확인 | O/X |
| C2-9 | 상수를 일부러 틀리게 | `correct_learner` 에서 `private` 를 무시하게(`cache_key_kind="fix"` 고정) 바꾸면 C2-3 이 FAIL 하는 줄을 붙이고 원복. 로그 억제 한 줄을 지우면 C2-4 FAIL 줄 |
- 금지: 새 라우트, `lan.py`·`llm_*.py` 수정, 원문을 파일·로그에 쓰는 새 코드, `private` 가 아닌 호출의 동작 변경, 마커 값 이외의 실제 사용자 글 사용.

#### C3 — 일기 화면 (`worker-hard`, 2파)
| ID | 조건 | 명령 → 기대 |
|---|---|---|
| C3-1 | 시험 통과 | `diary_screen_test`, `diary_flow_test` PC·`-- --phone`(+`--font-scale=1.5`, `--dark`) → `N passed, 0 failed` |
| C3-2 | **실제 버튼 흐름(AI 있음)**: 일본어로 3문장 입력 → [고쳐 보기] 누름 → 동의 시트 [동의하고 고치기] 누름 → "1 / 3 문장 고치는 중" → 결과 카드(원문·고침·이유·읽기) → "✓ 복습 카드에 넣었어요" → [일기 목록] 누름 → 목록에 "고침 완료" → 항목 [보기]·[지우기]→확인 시트 [지우기] 누름. `/fix` 는 `SpeakDrill.api_hook` 가짜 응답 | `press:` 줄 ≥ 12, FAIL 0 |
| C3-3 | **AI 없음 흐름**: `DiaryScreen.ai_hook` 이 `no_pc` → [고쳐 보기] 가 꺼지고 이유 한 줄, [저장만 하기] 누름 → 목록에 "고치기 대기" → AI 가 `ready` 로 바뀐 뒤 목록의 [고치기] 누름 → 고침 완료. 폰 모드(`-- --phone`)에서 [말해서 쓰기] 숨김 | `press:` 줄 ≥ 8 |
| C3-4 | 동의: `diary_consent` 가 false 면 [고쳐 보기]가 `/fix` 를 부르기 전에 시트를 띄우고, [나중에] 누르면 요청 0건·글 보존. 동의 뒤에는 시트가 다시 안 뜸 | 시험 PASS(요청 카운터) |
| C3-5 | `/fix` 요청 본문에 `"private": true` 가 항상 들어가고 문장당 1회·최대 3회, `text` 는 문장 하나(≤ 120자), `prev_ai` `""` | 시험 PASS(가로챈 요청 검사) |
| C3-6 | AI 출력 방어: 한글이 든 영어 fix, 가나 없는 일본어 fix, 길이 비 초과, 사전이 아닌 응답이 문장 2에서 오면 그 일기는 `saved` 로 남고 안내(부분 저장 없음), 카드 0개. 한도·연결 오류(`ai_limit`, `needs_pc`)는 한국어 안내 + 글 보존 | 시험 PASS |
| C3-7 | 복습 카드: 고친 문장만 `Store.add_review`(원문이 `target`/`note` 어디에도 없음), 일기당 3개·하루 5개, 설정 `auto_fix_cards` 꺼지면 자동 추가 안 함, 같은 고친 문장 중복 안 들어감, `newcards` 사건이 `StudyLog` 에 한 번씩 | 시험 PASS |
| C3-8 | 개인 정보: 시험이 마커 일기를 쓰고 끝까지 흐름을 돌린 뒤 ① 시험 출력에 마커 0건(C-10) ② `DiaryStore.path` 외 `user://` 어떤 파일에도 마커 없음(`Store.progress`·`prefs`·`studylog` 포함) | 시험 PASS |
| C3-9 | 옛 서버 신호(응답에 `reading` 키 없음): "PC 프로그램을 최신 버전으로 업데이트하면 일기 내용이 PC에 남지 않아요" 한 줄 | 시험 PASS |
| C3-10 | 보이는 숫자(C-15): "문장 2/3 · 87/300자", 날짜 "11월 14일 (금)", 대기 개수; 화면 전체 `\d{5,}` 없음. 터치 대상 높이 ≥ 폰 기준(`Ds.touch_min()`) | C-15 PASS |
| C3-11 | **일부러 틀린 입력**: 빈 입력·공백, 301자, 4문장, 목표 언어 글자 없음 → 거절 안내(버튼 꺼짐 또는 안내), `DiaryStore` 가득 참(1,000개) → "지워 주세요" 안내, 파일 읽기 전용 → 저장 안 한다는 안내 | `selfcheck FAIL-as-expected` |
| C3-12 | 상수를 일부러 틀리게 | `DiaryLogic.CARDS_PER_ENTRY` 3 → 9 로 바꾸면 C3-7 이 FAIL 하는 줄을 붙이고 원복 |
- 금지: 일기 글을 `print`·`push_warning`·토스트에 출력, `diary.json` 외 저장, `Api`/`Route` 수정, 하단 탭 변경, `practice_view.gd` 수정(연결은 W).

#### S — 기록 화면·배지 (`worker-hard`, 2파)
| ID | 조건 | 명령 → 기대 |
|---|---|---|
| S-1 | 시험 통과 | `badge_rules_test`, `badge_engine_test`, `badge_view_test`, `stats_view_test` → 각 `N passed, 0 failed` (PC·폰·`--font-scale=1.5`·`--dark`) |
| S-2 | 기존 단언 유지: `MISSION_IDS == MISSION_ORDER`(영어)와 8개, 배지 표 23행(일기 배지 승인 전). 새 단언 `MISSION_IDS_JA == MISSION_ORDER_JA`, 8개, 영어와 겹침 0, 순서 바꾼 목록은 거부하는 `selfcheck` | 시험 PASS |
| S-3 | `mission_all_star3`: 영어 8개 별3 → 받음, 일본어 8개 별3 → 받음, 영어 7 + 일본어 7 → 못 받음, 영어 8 중 하나가 별2 + 일본어 8 별3 → 받음, `mission_star3` 는 어느 언어든 1개면 받음. 소급(첫 평가)도 같음 | `badge_engine_test` PASS |
| S-4 | 설명 글만 바뀌고 id·이름·측정 이름·목표는 그대로(표 행 비교 `table_matches` 가 같은 표로 통과) | 시험 PASS |
| S-5 | 기록 화면: 일본어 탭에서 일본어 미션 칩(`★★☆` 형식 + 한국어 이름), 영어 탭에서는 영어 칩만, 이름 없는 id 는 id 로 보임. 일본어 약한 소리 카드: `phon.ja` 가 있으면 `JaSounds.label_of` 칩과 "틀림 n%", [집중 연습] 누르면 `PracticeView.pending == {"kind":"phoneme","p":<id>}` 와 `Store.navigate` 신호; 없으면 빈 상태 글 | 시험 PASS(버튼은 `pressed.emit()`) |
| S-6 | (일기 배지 승인 시) `diary_first`(첫 일기: `DiaryStore.counts().fixed >= 1`), `diary_7`(`days >= 7`) 2개를 표 끝에 추가, 시험의 `23` 을 모두 명시 숫자 `25` 로(파생값 금지), 카테고리 수 단언(`badge_view_test` 213)·표 행·소급·경계(목표-1/목표) 단언을 새 2개까지, `DiaryStore.counts()` 는 **원문 없이** 개수만 읽음. 승인 안 하면 이 줄은 "해당 없음" | 시험 PASS 또는 해당 없음 |
| S-7 | 일부러 틀린 입력: 미션 기록이 없음·모르는 id·`stars` 가 문자열/음수/4 → 에러 없이 0 취급, `DiaryStore` 가 없거나 깨져도(`counts` 가 `{}`) 배지 평가가 죽지 않음 | `selfcheck FAIL-as-expected` |
| S-8 | 보이는 숫자(C-15): 미션 칩의 "n번 도전", 약한 소리 "틀림 n%" | C-15 검사 PASS |
| S-9 | 상수를 일부러 틀리게 | `MISSION_IDS_JA` 의 항목 하나를 바꾸면 S-2 가 FAIL 하는 줄, `mission_all_star3` 집계를 `min` 으로 바꾸면 S-3 FAIL 줄을 붙이고 원복 |
- 금지: 배지 id·이름·측정 이름·목표 변경(기존 23개), `study_log.gd`·`practice_view.gd` 수정, 일기 원문 읽기.

#### W — 연결: 허브·홈 (`worker-hard`, 3파, 공유 파일)
- 하는 일: 허브 카드 7개(`diary` 추가), 일본어 허브에서 받아쓰기·약한 소리 켜기(설명 글을 일본어용으로), `_make_screen` 이 언어로 `JaSoundScreen` 선택, 일본어 약한 소리 칩(`_weak_box`), `diary` 카드, 홈 "이번 주" 카드의 [일기] 버튼과 `_on_fun_open("diary")`, 기존 시험 갱신(§2.6), 새 연결 시험.
| ID | 조건 | 명령 → 기대 |
|---|---|---|
| W-1 | 새 시험 통과 | `v170_wiring_test` PC·`-- --phone`(+`--font-scale=1.5`, `--dark`) → `N passed, 0 failed` |
| W-2 | **실제 버튼 흐름**: 홈에서 [일기] 누름 → 연습 탭의 일기 화면이 열림(`PracticeView.current_screen()` 이 `DiaryScreen`); 연습 허브 일본어 탭에서 [받아쓰기] 카드 버튼 → 일본어 받아쓰기 화면; [약한 소리] 카드 → `JaSoundScreen`; 영어 탭 [약한 소리] → `PhonemeScreen`; [롤플레이 미션] → 일본어 미션 목록. 각 화면의 ← 버튼으로 허브 복귀 | `press:` 줄 ≥ 12 |
| W-3 | 허브 카드 순서 `["mission","shadow","dictation","phoneme","kana","speed","diary"]`, `PracticeView.KINDS` 와 일치, 모든 카드가 `KINDS` 에 있음 | 시험 PASS |
| W-4 | 일본어 허브: 받아쓰기·약한 소리 버튼 `disabled == false`, 영어 탭에서도 켜짐, `en_only` 글("…영어만 지원해요")이 허브 어디에도 없음. 가나 카드는 일본어 탭에서만 켜짐(기존) | 시험 PASS |
| W-5 | 약한 소리 칩: 일본어 `phon.ja` 에 기록이 있으면 허브 카드에 일본어 카테고리 칩(`JaSounds.label_of`), 누르면 `JaSoundScreen` 이 그 소리 설명으로 열림 | 시험 PASS |
| W-6 | `pending` 소비: `PracticeView.pending = {"kind":"diary"}` → 일기 화면, `{"kind":"phoneme","p":"j_long"}` 일본어 → `JaSoundScreen`, 모르는 kind·모르는 `p` → 허브(에러 0) | 시험 PASS |
| W-7 | 홈 카드 버튼: [60초 퀴즈], [가나 코스](일본어만), [일기], [배지 n/N]. 첫 화면 규칙(시작 버튼 y ≤ 480, 이어하기 카드 y < 859)이 깨지지 않음(`home_view_test` 통과) | 시험 PASS |
| W-8 | 기존 시험 갱신은 §2.6 의 줄만. 갱신 후 `practice_test`, `ui_practice_widgets_test`, `fun_parts_test`, `fun_wiring_test`, `t5_wiring_test`, `home_view_test`, `screens_scan_test`, `phone_layout_test`(`--resolution 412x915 -- --phone`) 전부 0 failed, passed ≥ 기준선(줄어든 만큼은 §2.6 근거) | C-0 표 대조 |
| W-9 | 일부러 틀린 입력: 알 수 없는 `kind`, `p` 가 빈 문자열·영어 음소(`θ`)를 일본어에 줌, 언어를 바꾸는 중에 열린 화면 닫힘 | 시험 PASS |
| W-10 | 상수를 일부러 틀리게 | `KINDS` 에서 `"diary"` 를 빼면 W-3 이 FAIL 하는 줄을 붙이고 원복 |
- 금지: `main.gd`·`project.godot`·`export_presets.cfg`·`autoload\*` 수정, 하단 탭 변경, 새 화면 클래스 수정(각 작업 소유).

#### Z — 문서 (`worker-hard`, 4파, 위험도 낮음)
| ID | 조건 | 명령 → 기대 |
|---|---|---|
| Z-1 | `API.md` 에 ① `/practice/sentences` 일본어 dictation ② `/missions*` 일본어(응답 필드, `unsupported` 분기 제거, 선택 필드) ③ `/fix` 의 `private` 와 `reading`·`pron` 을 정확히 반영. 다른 절은 바뀌지 않음 | `git diff --stat` 로 해당 절만, 사실 확인은 코드와 대조 |
| Z-2 | `README.md`·`ROADMAP.md` 에 v1.7.0 기능(일본어 받아쓰기·약한 소리, 일본어 미션, 일기)과 한계(폰 단독 범위 표 §1.6, 일본어 약한 소리는 "추정", 일기 내용은 PC 로그·캐시에 안 남음, 일기는 기기 전용·동기화 안 됨, 일기 고친 문장 카드는 동기화됨)를 적음. "알려진 문제·실기 미검증" 에 §0.1 의 확인 못 한 것을 옮김 | `Select-String` 으로 키워드 확인 |
| Z-3 | 비밀값·개인 경로 0 | `rg -n "C:\\\\Users\\\\\|secrets\|token" README.md ROADMAP.md API.md` 에 새 줄 없음 |
- 금지: 코드 수정, 버전 숫자 올리기(오케스트레이터), `WORKLOG.md` 수정.

### 4.3 통합 시험 T8 (오케스트레이터가 직접 재실행)
- 소유권 검사 §3.5 스크립트 → `files 81 tasks 15 OK`.
- 새 시험 전부(PC·`-- --phone`): `dictation_diff_ja_test`, `dictation_ja_screen_test`, `ja_sounds_test`, `ja_sounds_data_test`, `study_log_ja_test`, `ja_sound_screen_test`, `mission_text_test`, `mission_ja_flow_test`, `diary_store_test`, `diary_logic_test`, `diary_screen_test`, `diary_flow_test`, `v170_wiring_test`. 백엔드: `test_missions.py --lint --full`, `test_missions_ja.py`, `test_fix_private.py`, `test_fixcore.py`, `test_phone_pack.py`, `test_practice.py`(라이브).
- 회귀: `local_missions_test`, `local_lessons_test`, `mission_test`, `practice_test`(`--api` 없이), `dictation_test`, `song_study_test`, `memo_grade_test`, `study_log_test`, `study_log_fun_test`, `badge_*_test`, `stats_view_test`, `home_view_test`, `fun_*_test`, `t5_wiring_test`, `ui_practice_widgets_test`, `phone_layout_test`, `run_sync_tests.ps1`, `smoke`, `test_guard_test`, `persist_test`, `contrast_test`, `a11y_sweep_test`(`--dark` 포함), `ui_perf_test`(단독 재실행), `screens_scan_test`. 모두 마지막 줄 `0 failed`, `SCRIPT ERROR:` 0, `TEST_GUARD on` 1.
- 개인 정보 직접 확인: 마커 일기로 라이브 서버(가능하면 실제 LanguageTool 포함)에 `private:true` `/fix` 를 보낸 뒤 `backend\logs\*`·`backend\cache\llm_cache.sqlite`·`languagetool.log` 를 마커로 훑어 0건(AI 연결이 없으면 가짜 엔진 시험 결과로 대체하고 "실제 AI 미검증" 으로 보고).
- 권한·버전: `git diff --stat godot\project.godot godot\export_presets.cfg` 비어 있음(버전 올리기는 릴리스 단계). 공개 점검 `packaging\publish_release.ps1 -ScanOnly` 통과, `check_no_media.ps1` OK, 올라갈 파일에 `diary.json`·사용자 글·마커 없음.
- 실기기 확인(**미검증으로 남김, 사용자 몫**): §0.1 의 "확인하지 못한 것" 전부.

---

## 5. 위험 요소와 실패 시나리오

### 5.1 위험 요소와 대안
| # | 위험 | 영향 | 대안·완화 |
|---|---|---|---|
| R-A1 | **일본어 받아쓰기 채점 정확도**: 한자 읽기 모호성(同音異字), 한자 덩어리 정렬 실패, 송가나 변형, 조사 표기, `ー`·촉음 표기, 코퍼스(Tatoeba) 번역·읽기 오류 | 맞게 들었는데 틀림/틀리게 썼는데 통과 | 읽기 기준 채점으로 한자 부담 제거, 정렬 실패는 한 조각 대체 경로, 변이 시험 1,000건(A1-4), 말뭉치 전수(A1-2), 한자 불일치는 "같은 소리의 다른 한자일 수 있어요" 로 정직하게 표시. 임계값은 **초기 추측값**이라 측정 후 조정(A1-3/A1-10). 독립 검토자가 사람이 쓸 법한 답 30개를 따로 넣어 본다 |
| R-A2 | **TTS가 문장의 한자를 `reading` 과 다르게 읽을 수 있음(추측)**(폰 시스템 음성은 기기마다 다름, PC Kokoro 는 자체 G2P) | 맞게 들은 학습자가 틀림 처리 | 결과 카드에 정답 읽기를 항상 보이고, 사용자 실기로 몇 문장 확인(§6.1 Q1 후속). 대안: 소리를 `reading`(가나)으로 재생하는 옵션 — 이번 범위에서는 만들지 않고 실기에서 문제가 크면 1.7.1 |
| R-A3 | 폰에 일본어 키보드가 없음 | 입력 불가 | 입력칸 아래 안내, 후속(가나 조각 입력, Q1). 한글 키보드는 못 씀을 명시 |
| R-A4 | **일본어 약한 소리 감지가 약함**: Whisper 가 문맥으로 고쳐 들어 장음·촉음 오류를 "맞음"으로 냄(과소), 반대로 인식 오류(과대) | 통계가 부정확 | 화면에 "추정" 문구, 표본 5회 이상일 때만 약한 소리로 표시(`weak_phonemes` min_n), 핵심 연습은 결정적인 듣고 고르기. 음소 모델·길이 실측은 범위 밖(§0.2) |
| R-A5 | `ja_sounds.json` 의 낱말 쌍·한국어 설명 오류(실제로 구별되지 않는 쌍, 어색한 설명) | 틀린 것을 배움 | `gloss_ja.json` 표제어·OpenJTalk 읽기 교차 검사(A2-4/A2-5), 가짜 낱말 금지, 사용자 검수(Q4), 확신 없는 쌍은 넣지 않음(쌍 개수는 하한이 아니라 검증 통과분) |
| R-A6 | 일본어 TTS 가 장음·촉음 쌍을 구별해 읽지 못함(추측) | 듣고 고르기가 무의미 | 쌍마다 시험할 수 없음 → 사용자 실기 확인 항목. 문제가 되는 쌍은 데이터에서 뺄 수 있게 `pairs` 는 개별 항목 |
| R-B1 | 일본어 규칙 과소/과대 판정(어미·경어 변형, 조사 생략, 한자/가나 표기) | 달성했는데 체크 안 됨 / 못 했는데 체크됨 | §2.3.2 규약, 린트(pos/neg), 독립 문장 시험 B2t(작성자≠시험자), 놓친 목표는 AI 판정으로 구제(증거 인용 필수), 과소 15%·과대 10% 임계 |
| R-B2 | **파이썬 `re` ↔ Godot PCRE2 차이, NFKC 부분집합 차이** | 폰에서 판정이 PC와 다름 | 황금 파일(일본어 24개+, B3-2), 일본어 패턴에서 `\b`·`\s`·`\p{…}` 금지(린트), 컴파일 실패 미션만 빠짐(기존 F15) |
| R-B3 | AI 판정이 학습자가 안 한 말을 인정(환각) | 별을 잘못 줌 | 증거 인용이 **학습자 문장에 있을 때만** 인정(서버 `_quoted_in` + 앱 `apply_judge`), 일본어는 `normalize_ja` 로 비교·길이 2~80자, 대화는 `<conversation>` 데이터로 취급하고 지시를 무시하라는 프롬프트(기존) |
| R-B4 | 일본어 AI 상대가 수준에 안 맞거나 한자·중국어 글자가 섞임 | 대화 품질 | 기존 대화 검증(`ja_text_foreign`, 한글 거부)·단계별 프롬프트 재사용, `scene` 에 정중체·짧은 문장 지시, 실기 확인 |
| R-B5 | 병원 미션의 의료 안전 | 부정확한 의료 정보 | 상대 AI 는 진단·약 용량을 말하지 않음(`scene`), 대사에 구체적 약·용량 없음(B2-6) |
| R-B6 | 미션 id 충돌·`MAX_MISSIONS`·동기화 키 형식 | 기록 손상 | `ja_` 접두어, 영문 소문자·숫자·밑줄만, 총 16개 ≪ 200 |
| R-C1 | **일기 원문이 서버 로그·LLM 캐시·시험 출력에 남음** | 개인 정보 | `private` 모드(C2), 원문 마커 시험 3중(캐시·로그·파일, C2-3~5), 앱 쪽 마커 시험(C3-8). 남는 곳: ① OpenCode(공급자) 쪽은 우리가 통제 못 함 → 동의 시트에 "AI 서비스로 전송" 명시 ② LanguageTool JVM 로그는 **실측 필요(추측)** — 라이브 확인, 문제면 LT 건너뛰기 옵션을 1.7.1 |
| R-C2 | 구 서버(PC 1.6.x)는 `private` 를 몰라 원문을 남김 | 개인 정보(구버전 조합) | 응답에 `reading` 키가 없으면 앱이 안내 한 줄(§2.5). 오케스트레이터는 릴리스 노트에 "PC 프로그램도 같이 업데이트" 를 적는다 |
| R-C3 | 고친 문장 복습 카드가 동기화로 PC 허브에 감 | 일기 문장이 두 기기에 남음 | 원문은 카드에 넣지 않음(고친 문장만), 설정 `auto_fix_cards` 존중, 사용자에게 알림(Q8) |
| R-C4 | **AI 교정 출력 검증**: 프롬프트 주입(일기에 "앞의 지시를 무시하고…"), 엉뚱한 언어·길이, 내용 지어내기, 코드·링크 | 이상한 문장이 카드가 됨 | 서버 `fix_valid`(한글/가나 검사, `fix_ko` 검사) + 앱 `DiaryLogic.clean_fix`(한 줄, ≤ 300자, 길이 비 `3×원문+20`, 언어 검사, 이유 ≤ 200자). `bad` 는 카드 금지·"고치지 못했어요". 결과는 화면 글자일 뿐 도구·명령 실행 경로가 없음 |
| R-C5 | 일기 파일 손상·가득 참·읽기 전용 | 글 손실 | 원자적 쓰기, `.bad` 격리, 읽기 전용이면 저장 안 함 + 안내, 1,000개 한도에서 새 글 거절(조용히 지우지 않음) |
| R-C6 | AI 교정 지연(3문장 순차 호출 **(추측: 문장당 수 초~십수 초)**) | 기다림 | 진행 표시 "1 / 3", [취소], 실패 시 글 보존. 느리면 1.7.1 에 병렬 호출 또는 한 번에 보내는 방식 |
| R-C7 | 시험이 실제 사용자 폴더·`diary.json` 을 건드림 | 사용자 일기 손실 | `REAL_FILE_NAMES` 에 `diary.json`, 시험은 `user://test_*` 만(C-9, C1-4) |
| R-W1 | 허브·홈 시험이 카드 수·버튼 수에 기대고 있음 | 연결 때 시험 파손 | W 소유로 모아 의도한 변경만(§2.6), 줄어든 단언 0(C-5) |
| R-W2 | `study_log.gd` 가 1.6.1 작업(`v161_u1`/`u2`)과 겹침 | 병합 충돌 | 작업 시작 전 main 최신 확인(O-1), A2 의 변경은 `add_score_any` 안 한 줄 + 새 함수 1개로 작게 |

### 5.2 일부러 틀린 입력으로 확인하는 실패 시나리오 (작업 표의 항목을 한눈에)
| 시나리오 | 기대 | 담당 |
|---|---|---|
| 받아쓰기: 빈 입력·공백·영어·한글·1만 자·읽기 없는 문장·글자 하나 바꾼 정답 | 0점/안전한 값/틀린 칸 표시, 에러 0 | A1-4, A1-9, A4-8 |
| 받아쓰기: 일본어 음성 없음, 서버 응답이 이상함 | 안내 화면, 요청 0건/오류 화면 | A4-4, A4-8 |
| 약한 소리: 깨진 `ja_sounds.json`, 모르는 카테고리, 이상한 `/score` 응답, 잘못된 `p`·언어 | 죽지 않음, 기록 불변 | A2-3, A2-6, A2-8, A5-6 |
| 미션: 일본어 id 를 영어로 요청(404), 전각/가타카나/제어 문자/이모지/300자 폭탄, 규칙 망가뜨린 콘텐츠 | 400/404/미달성, 50 ms 안, 린트 실패 | B1-4~B1-7, B2t-2, B3-7 |
| 미션 AI 판정: 증거가 상대 문장에서 따옴·1글자·81자·없음 | 인정 안 함 | B1-5, B4-3, B4-4 |
| 미션: 폰 정규식 컴파일 실패 한 개 | 그 미션만 빠짐 | B3-6 |
| 별 3 배지: 영어 7+일본어 7, 모르는 id, 깨진 기록 | 못 받음, 에러 0 | S-3, S-7 |
| 일기: 깨진 파일·읽기 전용·가득 참·401자·4문장·언어 불일치 | `.bad` 격리·안내·거절 | C1-3, C3-11 |
| 일기 AI 출력: 한글 영어 fix·가나 없는 일본어 fix·길이 폭주·사전이 아님 | `bad`, 카드 0, 글 보존 | C1-7, C3-6 |
| `/fix`: `private` 가 이상한 값·500자 초과·공백·`fr` | 안전하게 처리, 한글 400 | C2-7 |
| 일기 원문 마커 | 서버 캐시·로그·파일·시험 출력·`user://` 에 0건 | C2-3~5, C3-8, C1-10 |
| 허브: 모르는 kind·영어 음소를 일본어에 줌 | 허브로, 에러 0 | W-6, W-9 |
| 상수 하나를 일부러 틀리게(각 작업 C-12) | 그 작업 시험이 FAIL 하는 줄 | 각 작업 |

---

## 6. 사용자에게 물을 것과 오케스트레이터 결정

### 6.1 사용자에게 물을 것 (추천안 포함)

> **확정(2026-11-14, 사용자 "추천대로")**: Q1~Q11 모두 추천안. O-1 기준 커밋은 v1.6.1 공개 뒤 main. O-3 가짜 엔진 시험 필수, 실제 AI 는 선택(미검증 표기). O-5 LT 로그에 원문이 남으면 private 일 때 LT 건너뛰기. worktree 는 `app_wt\ja_<작업>`, 브랜치 `ja170/<작업>`.
| # | 질문 | 추천 |
|---|---|---|
| **Q1** | 일본어 받아쓰기는 **폰에서 일본어 키보드(가나·한자)로 쓰는 것**을 전제로 해도 되나요? 키보드가 없으면 못 씁니다(가나 조각 고르기 입력은 이번에 안 만듦). 폰에 일본어 키보드가 있나요? 또 TTS 가 한자를 이상하게 읽는 문장은 실기에서 몇 개 들어 봐 주실 수 있나요? | 예(키보드 입력만). 실기에서 막히면 1.7.1 에 가나 조각 입력 |
| **Q2** | 받아쓰기 **한자 정책**: 한자를 안 쓰고 가나로만 써도 소리가 맞으면 정답(한자까지 맞으면 "표기까지 맞음" 표시)으로 할까요, 아니면 한자까지 맞아야 정답으로 할까요? | 가나만 써도 정답 + 표기까지 맞으면 표시 |
| **Q3** | 일본어 **약한 소리 범위**: "듣고 고르기(정확, 폰 단독 가능) + 따라 말하기(PC 채점은 인식된 글자와 비교한 추정, 폰 단독은 자가 평가)"로 갈까요, 듣고 고르기만 할까요? 소리 분석·악센트·길이 측정은 이번에 안 합니다. | 둘 다(따라 말하기에 "추정" 안내) |
| **Q4** | `ja_sounds.json` 의 **낱말 쌍과 한국어 설명**(장음·촉음·청탁·つ/す·ざ/じゃ·요음)을 작업자가 초안 → 사용자(또는 일본어 아는 분)가 읽고 고치는 방식으로 해도 되나요? 확신 없는 쌍은 넣지 않습니다. | 예 |
| **Q5** | 미션 **별 3 배지**: 기존 "미션 8개 모두 별 3개" 를 "한 언어의 8개 모두"로 세도 되나요? (대안: 영어 8개만 유지하고 일본어 전용 배지를 24번째로 추가 — 배지 표·시험이 늘어남 / 영어+일본어 16개 모두) | 한 언어의 8개 모두(배지 23개 유지, 이름·id 그대로, 설명만 변경) |
| **Q6** | **일기 배지 2개**(`diary_first` 첫 일기를 고침, `diary_7` 서로 다른 날 7일 일기)를 추가할까요? 추가하면 배지 25개가 되고 배지 시험 표·숫자 23 을 여러 시험 파일에서 25 로 바꿔야 합니다(작업 S 에 모아 둠). | 예(작업 S 안에서만. 싫으면 S-6 이 빠질 뿐 다른 작업에 영향 없음) |
| **Q7** | 일기 **진입 위치**: 연습 허브 7번째 카드 + 홈 "이번 주" 카드의 [일기] 버튼 둘 다로 할까요, 허브 카드만 할까요? (하단 탭은 늘리지 않음) | 둘 다 |
| **Q8** | 일기 **저장·지우기·동기화**: 일기는 이 기기에만 저장하고 동기화하지 않습니다. 고친 문장은 복습 카드가 되어 기존 규칙대로 PC·폰에 동기화됩니다(원문은 가지 않음). "모든 기록 지우기" 는 일기를 지우지 않고, 일기 화면의 [일기 모두 지우기] 로 따로 지웁니다(전체 초기화 확인 문구에 일기·배지를 적는 것은 1.7.1). 괜찮은가요? | 예 |
| **Q9** | 일기를 AI 로 고칠 때 **처음 한 번 동의 시트**("쓴 문장이 AI 서비스로 전송됨, PC 로그·캐시엔 안 남음")를 띄워도 되나요? 노래 공부의 동의와 같은 방식입니다. | 예 |
| **Q10** | 일기는 **목표 언어로만 쓰게**(한국어로 쓰면 거절) 할까요? 한국어로 쓰고 번역받는 기능은 이번에 안 만듭니다. | 예(교정만) |
| **Q11** | 버전: 기능이 늘어나므로 **1.7.0**, 그리고 v1.6.1 작업(`app_wt\v161_u1`, `v161_u2`)이 main 에 다 합쳐지고 공개된 뒤에 시작하는 것이 맞나요? | 예 |

### 6.2 오케스트레이터가 정할 것
| # | 항목 | 이 문서의 기본 |
|---|---|---|
| O-1 | 시작 기준 커밋: 문서 기준은 `682e72d`. v1.6.1 병합이 끝난 main 으로 정하고, `study_log.gd`·`practice_view.gd`·`today_view.gd` 가 그동안 바뀌었는지 확인 | 시작 직전 main |
| O-2 | A1 임계(혼합 98%, 대체 경로 3%, 점수 `HARD_ERRORS`·`HARD_CAP`)와 B2t 임계(과소 15%·과대 10%)는 초기 추측값. 측정 뒤 조정 여부 | 측정 보고를 보고 결정 |
| O-3 | 라이브 시험 포트 배분(작업별 18801~18899 한 개씩)과 라이브 AI(실제 OpenCode) 시험을 할지 | 가짜 엔진 시험 필수, 실제 AI 는 선택(미검증 표기) |
| O-4 | 합치는 순서와 `.uid`·`--import` 처리, 1파→2파→3파 사이마다 §3.5 스크립트와 새 시험 실행 | 문서 §3.2 |
| O-5 | LanguageTool JVM 로그에 원문이 남는 것으로 확인되면(C2-5) 일기에서 LT 를 건너뛸지(`private` 일 때 AI 만) | 확인되면 건너뛰기 |
| O-6 | `/fix` 응답에 일본어 `reading` 이 없는 구서버 안내 문구 | §2.5 문구 |
| O-7 | 실기(폰) 확인 항목을 사용자에게 어떻게 부탁할지(§0.1 마지막 줄 목록) | 릴리스 노트에 "미검증" 으로 |

---

## 요약 (10줄)
1. 일본어 받아쓰기는 기존 화면을 확장한다. 문장은 기존 `/practice/sentences`(서버·폰 팩 1,693개 후보), 채점은 읽기(히라가나) 글자 기준의 새 순수 클래스 — 가나만 써도 소리가 맞으면 정답, 한자까지 맞으면 표시.
2. 일본어 발음 채점은 Whisper→모라 정렬까지(음소·악센트 꺼짐, 폰 단독 STT 없음). 그래서 약한 소리는 "듣고 고르기(결정적, 폰 단독 가능)" 중심 + "따라 말하기(PC, 추정)" + 통계(`phon.ja`)로 한정한다.
3. 약한 소리 일본어는 새 화면과 새 데이터 파일 `ja_sounds.json`(팩·서버 불필요), 장음·촉음·청탁·つ/す·ざ/じゃ(+요음) 6개 카테고리, 낱말은 `gloss_ja`·OpenJTalk 로 교차 검사.
4. 일본어 미션 8개는 같은 `missions.json`·같은 라우트·같은 화면. 서버·폰이 `lang` 으로 일본어를 허용하고, 일본어 정규화(가타카나→히라가나, 부호·공백 삭제)를 파이썬·GDScript가 황금 파일로 맞춘다. 규칙은 어미·경어·조사 생략 변형을 정규식에 풀어 쓰고, 작성자와 다른 작업자가 독립 문장으로 과소/과대 판정을 잰다.
5. 별 3 배지는 23개를 그대로 두고 `mission_all_star3` 를 "한 언어의 8개 모두"로 센다(id·이름·목표 불변, B1 시험 표 불변). 일기 배지 2개는 선택(작업 S 한 곳).
6. 일기는 허브 7번째 카드 + 홈 [일기] 버튼. 고치기는 기존 `/fix` 에 `private:true` 를 더해 캐시·로그에 원문을 안 남기고 일본어 읽기를 돌려받는다(새 라우트 없음, `lan.py` 변경 없음). 문장별 최대 3회 호출, AI 출력은 앱이 한 번 더 검증한다.
7. 일기는 `user://diary.json`(기기 전용, 동기화·백업 없음), AI·PC 가 없으면 "저장만" 해 두고 나중에 고친다. 복습 카드는 고친 문장만(원문 제외), 일기당 3개·하루 5개·중복 제거.
8. 작업 15개: 1파 A1·A2·B1·C1·C2 → 2파 A4·A5·B2·B4·C3·S → 3파 B3·B2t·W → Z. 공유 파일은 한 작업에만(`study_log.gd`=A2, `server.py`=C2, 허브·홈=W 등), 소유권은 스크립트로 검사한다.
9. 모든 작업에 O/X 합격 조건, 일부러 틀린 입력, 상수 변이 확인이 있다. 흐름 시험은 실제 버튼 `pressed.emit()` 과 `press:` 줄 개수로, 보이는 숫자는 읽을 수 있는 단위(5자리 이상 숫자 금지)로 판정한다(`REVIEW.md`).
10. 사용자에게: 일본어 키보드 전제(Q1), 한자 정책(Q2), 약한 소리 범위(Q3), 낱말 쌍 검수(Q4), 별 3 집계(Q5), 일기 배지(Q6), 진입 위치(Q7), 일기 저장·동기화(Q8), AI 동의(Q9), 한국어 입력 불가(Q10), 버전·시작 시점(Q11).
