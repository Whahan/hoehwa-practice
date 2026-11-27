# v2.1.0 상세 설계: 영어 17~32주, 수준 맞춤 AI 대화(PC·폰), 이어지는 이야기 회화, 내 녹음 비교, 연습·미션·신고·따라잡기

- 작성: designer(Opus 5.5, 설계만. 코드·원고·설정 수정 없음) / 기준 커밋: `2d42a4a`(main, 2026-11-27)
- 상위 문서: `docs/v210_plan.md`(최상단 기획, 끝의 "사용자 결정" D1~D9 확정), `docs/v200_design.md`(72주 코스 원설계 §2·§3·§5·§6·§8·§9·§10·§14), `docs/v202_design.md`(형식·공통 명령·OWN·결합 기준 방법을 본뜸, PI1·PI2b API), `docs/v201_design.md`, `docs/v200_phone_design.md`. 이 문서는 그 문서들을 바꾸지 않고 **2.1.0 에서 정하는 것만** 적는다.
- 표기: **(추측)** = 코드·실행으로 확인하지 못한 가정·예상치. **(새)** = 이번에 새로 만드는 파일·함수·필드. **★** = 사용자 행동이 필요한 항목. **[SP 뒤 확정]** = 2파 AI 준수율 스파이크(SP) 결과로 바뀔 수 있는 상수(서버 `course_level.py` 와 폰 `ai_chat_rules.gd` 두 곳에 같은 값, 황금이 같음을 확인). 경로는 저장소 루트 `D:\Ai\언어\app` 기준.
- 담당: **모든 구현·원고·검수 작업자는 `worker-hard`(Sonnet 5.5)**. **코드 검토는 Sol 6.2**(Orca codex `gpt-6.2-sol`, effort high), Sol 이 이 PC 에서 시험을 못 돌리거나 한도에 걸린 경우에만 `reviewer`(Sonnet 5.5)가 대신하고 오케스트레이터가 그 사실을 WORKLOG·릴리스 노트에 적는다. **원고 표본 검수는 Gemini 4 Hydrogen**(Orca antigravity `gemini-4-hydrogen-high`). 사람 검수는 없다(D3 A) — README·릴리스 노트에 "AI 검수만(사람 검수 없음)"으로 적는다.
- **비밀값 규칙(모든 작업자·검토자·오케스트레이터)**: 실제 AI 키·토큰·`secrets.json`·auth 파일 내용·키스토어 암호는 이 문서·지시문·보고·WORKLOG·커밋·시험 픽스처·로그·채팅 어디에도 쓰지 않는다. 시험용 가짜 키는 2.0.2 규칙 그대로 `FAKEKEY_ZZ_` + 영숫자 20자 이상. 서버 `backend\secrets.json` 은 열지도 출력하지도 않는다. 실제 AI 를 부르는 일은 SP(무료 DeepSeek, 키 없음)와 6파 T-8 실측(오케스트레이터)뿐이다.

## 0. 근거·목표·범위

### 0.1 읽은 것 / 실행한 것 / 확인하지 못한 것
- **읽은 것**: `docs/v210_plan.md` 전체, `docs/v202_design.md` 전체(§2.1~2.3 API, §3 OWN, §5.0~5.1, §7~§11), `docs/v201_design.md` OWN, `docs/v200_design.md` §2~§14(특히 §2.3 72주 표, §3.3 3중 검사, §5 수준 맞춤 AI, §6.2 따라잡기, §8.1 미션 표, §9 검수, §10 데이터 계약, §13.3 OWN, §14 합격 조건), `docs/v200_phone_design.md` OWN, `WORKLOG.md`·`ROADMAP.md` 관련 줄. 원고·도구: `course_src/en/skeleton.json`(meta·id_ranges·17~33주 `weeks`·`patterns`·`canada_notes`·`situations`), `policy.json` 전체, `weeks/w001~w016.json`(통계), `course_src/tools/README.txt`, `check_course.py`(skeleton 검사 1090~1400행·`check_assignment`), `course_common.py`(`DEFAULT_LIMITS`·`tokenize`), `build_course.py` 전체, 시험 `test_check_course.py`·`test_k0_layout.py` 의 R1 한계 단언. 앱: `core/day_plan.gd` 전체, `course_feed.gd` 머리, `course_data.gd`(색인·주 레코드 검증), `course_store.gd` 함수 목록, `lexicon_guard.gd`(토큰화·색인), `course_model.gd` 일부, `practice/course_player.gd`(월말·힌트·기록 부분), `course_exercise_view.gd`(말하기 흐름), `shadow_screen.gd`(100~215행), `dictation_screen.gd`(요청), `mission_screen.gd`(코스 잠금·안내·`_chat_payload`), `views/talk_view.gd`(요청 본문), `autoload/recorder.gd`·`ui/recorder_widget.gd`(녹음 결과 모양), `core/wav_util.gd`, `core/progress.gd`(TEST_GUARD), `core/diary_store.gd`(기기 전용 저장소 본보기), `core/home_model.gd`·`ui/home_parts.gd`(DayPlan 스냅샷), `autoload/api.gd`(시간 제한), `sync/sync_doc.gd`(SCHEMA·SHARED_PREFS), `local/local_missions.gd`·`core/mission_logic.gd`(min_stage). 서버: `backend/server.py`(`LEVEL`·`rules_text`·`run_chat`·`ChatReq`·`/chat`), `missions.py`·`test_missions.py`(공개 모양 단언), `content/missions.json`, `tools/build_phone_pack.py` 머리, `phone_src/tools/make_ai_golden.py` 머리. 시험: `course_stage_wiring_test.gd`(E7-9 안내·주 5 미션 목록), `local_missions_test.gd`(16개·키 단언), `badge_engine_test.gd`(25개 단언).
- **실행한 것(읽기 전용)**: `git log`·`git status`, 17~32주 수량 합계 계산(아래 S1), R1 주별 문장 수·평균 길이 집계(S2), 세 설계 문서 + v200 폰 설계 OWN 의 기존 소유자 조회, **이 문서 OWN 블록의 소유권 검사**(§3.3: 정상 1회 + 일부러 틀린 복사본 5종).
- **확인하지 못한 것**: 2.0.2 구현 결과 전부(PI1·PI2b·RD 의 실제 코드 — 이 문서는 v202 설계의 계약을 근거로 함), 실제 AI(무료 DeepSeek·폰 업체)의 어휘 제한 준수율(SP·T-8 이 잼), 갤럭시 S24 마이크 샘플 레이트(추측: 48 kHz), Godot RichTextLabel `meta_clicked` 의 폰 터치 동작(추측: 된다), `CourseLevels` 런타임 파생의 폰 소요 시간(PC 에서만 측정), `build_phone_pack.py --only content` 가 다른 팩 파일을 바꾸지 않는지(추측: 도움말대로 그대로 둠).

### 0.2 목표와 범위
- **목표**: `docs/v210_plan.md` §8 완료 기준 1~6 을 만족하는 2.1.0 을 **2027-01-28(목표)·2027-02-11(상한)** 안에 공개한다.
- **넣을 것**: 17~32주 원고·출시 데이터(최소 유지선), 수준 맞춤 AI 대화(서버 S1 + 폰 PI-L, 최소 유지선), 이어지는 이야기 회화 시즌 1(16장면, D1 A·D7 A), 내 녹음 비교(D2 A), 쉐도잉·받아쓰기 코스 문장, 미션 `min_week`·새 미션 2개, 오류 신고, 따라잡기 정교화, (선택) 코스 배지(D5 A), (선택) 사소 잔여 1건.
- **하지 않을 것**
  - 33주 이후 원고, 시즌 2·3, 코스 진행 동기화(`ec-`), 카드 상한 변경, 자막 교재, 2.0.1 음성 재보정(D9 A), 새 설치 기본 모드 변경(D4 A).
  - 새 서버 라우트(`/chat` 선택 필드만), `lan.py`·`sync_hub.py`·`SyncDoc.SCHEMA`·`SHARED_PREFS` 변경, 안드로이드 권한 추가, `project.godot` 새 autoload, 원격 업로드(녹음·신고·이야기 기억은 어디로도 보내지 않음. 단 이야기 기억 몇 줄은 사용자가 고른 AI 업체로 대화 요청과 함께 간다 — §2.6).
  - 일본어 변경 전부(코드·데이터·시험 0줄).
  - 1~16주 원고(`w001~w016.json`) 변경(오류 수정도 이번엔 하지 않는다. 2.1.0 의 낱말 활용형은 §2.1 `forms_add` 로 17~32주 파일에 둔다).
  - 2.0.2 파일(`ai_client.gd`·`ai_secrets.gd`·`ai_presets.gd`·`ai_state.gd`·`local_ai.gd`·`phone_ai_*.gd`)의 이름·인자 변경. PI-L 은 `ai_chat_rules.gd` 에 **더하기만** 한다(v202 §11 약속).
  - 버전 올리기·릴리스·PI0·T-8 실측(오케스트레이터 몫).

### 0.3 지금 main 에서 확인한 사실(설계 근거)
| # | 사실 | 위치 |
|---|---|---|
| S1 | 17~32주 뼈대 수량: 능동 **400**(주 25·25·26·26, 21~31주 26, 32주 12), 수동 **224**(주 14), 문형 **64**(주 4, 20주 5, 32주 3), 월말 20·24·28·32주, 캐나다 노트 13개(21~29주). **낱말 배정표(`words`)는 1~16주만** 있고(`meta.itemized_weeks=[1,16]`), 17~32주 문형 64개는 `id·w·d·tpl` 만 있고 `title_ko·grammar_ko·needs` 가 없다 | `skeleton.json` |
| S2 | R1 실적: 문장 991(5~16주 평균 64.3/주, 평균 4.0~5.4 낱말), Tatoeba 0, 대화 줄 1~7주 4·8주~ 7~10. 문장 id 범위 R1 `s0001~s0999`(991개 사용), R2 예약 `s1000~s1999`·낱말 `w0700~w1399`(`id_ranges.future.R2`) | 원고 집계 |
| S3 | `policy.json` 에 `limits` 가 없으므로 수량 규칙은 `course_common.DEFAULT_LIMITS`: 주당 문장 ≥ 36, 문형당 ≥ 6, 능동 낱말당 ≥ 2, 수동 낱말당 ≥ 1, 능동 10~30(종합 주 16·32 는 10~16), 수동 8~16, 문형 3~5(종합 주 0~3), 대화 정확히 1편(8주~ 6~10줄), 월말 주 `speak_prompts` 3, Tatoeba ≤ 25% | `course_common.py` 30~56행 |
| S4 | 린터가 R1 에 묶여 있다: `R1_ID_LIMITS`(낱말 ≤ 699·문장 ≤ 999), 배정표 id ≤ 699, `w <= 16` 일 때만 `can_do`·문형 `title_ko`·`grammar_ko` 검사, 배정표 합계는 1~16주만. 기존 시험이 `..._outside_R1_limits` 문구를 단언 | `check_course.py` 1143·1218·1258·1323·1381·1393행, `test_check_course.py` 697행, `test_k0_layout.py` 131행 |
| S5 | `policy.json` 의 `Harbour Hostel`·`Blue Door Hotel` 은 `from_w: 34`. 기획 §3.1 은 17주부터 Harbour Hostel 을 쓴다 → 정책 변경이 필요 | `policy.json` `fake_businesses` |
| S6 | R1 에서 뒤 주 문형의 활용형(`cats` ← `p_plural_s` 6주)은 **앞 주 낱말 레코드의 `forms`** 에 적었다(93건). 2.1.0 의 과거형(`went` ← 19주)·비교급을 같은 방식으로 적으면 1~16주 파일을 고쳐야 한다 | `w001~w016.json` 집계 |
| S7 | `CourseData` 는 주 레코드의 모르는 키를 그대로 보존한다(정수 키만 검사) → `story`·`ai_fallback` 을 `en_weeks.json` 주 레코드에 넣어도 로더 변경이 없다. 주 수는 데이터로 정해진다(`available_weeks()`, 코스 홈 "준비 중") | `course_data.gd` 274~300행, `course_model.gd` 215~270행 |
| S8 | `LexiconGuard.tokens()` 는 K1 `course_common.tokenize` 와 같은 규칙(소문자, 글자·숫자 연속, 안쪽 `'` 유지, 하이픈 분리)이고 색인은 낱말·활용형(`forms[].o`)·`alt` 를 순서열로 가진다 | `lexicon_guard.gd` 20~30·186~290행 |
| S9 | 서버 `/chat`: `ChatReq`(pydantic, 모르는 필드는 무시) → `run_chat`: `rules_text(lang, scenario, stage, n, w)` 시스템 프롬프트, 형식·한국어 검사로 **최대 2회** 시도 후 실패면 502. OpenCode 엔진은 첫 시도만 세션(`_chat_opencode`). 응답 `{reply, reading, pron, ko, fix, fix_ko, suggest}` + 라우트가 `tts_chunks` 를 붙인다 | `server.py` 1551·1773·1993~2062·2541·2891행 |
| S10 | 앱 시간 제한 `Api.TIMEOUT_LLM = 180` 초, 서버 API 엔진 시간 제한 120초(v202 S16) → 재요청을 무제한 허용하면 앱이 먼저 끊는다 | `api.gd` 31행 |
| S11 | 대화·미션 요청 본문: `talk_view` `{lang, stage, month, week, scenario{id,title,persona,scene}, history}`, `mission_screen._chat_payload` 같은 모양. 코스 모드 영어는 `CourseModel.pos_for` 로 `stage`·`month`·`week` 를 채운다(cw·cd 도 가짐) | `talk_view.gd` 600~612행, `mission_screen.gd` 845행 |
| S12 | 2.0.0 임시 안내 `MissionScreen.COURSE_NOTICE = "코스에서 아직 배우지 않은 단어가 나올 수 있어요"` 를 쉐도잉·받아쓰기·대화·미션이 부른다. `course_stage_wiring_test` 는 부분 문자열 `"아직 배우지 않은"` 으로 네 화면을 단언, 주 5 미션 목록은 가짜 미션 4개(`min_week` 없음)로 "맞는 단계 2·더 나중에 2" 를 단언 | `mission_screen.gd` 21·105행, `course_stage_wiring_test.gd` 22·556~600·663~700행 |
| S13 | 쉐도잉·받아쓰기는 `GET /practice/sentences?...stage&month&week` 로 문장을 받는다(코스 문장 아님). 문장 id 는 정수 | `shadow_screen.gd` 162~200행, `dictation_screen.gd` 102~115행 |
| S14 | 미션 `min_stage` 만 있다. 서버 `public_mission` 키 집합을 `test_missions.py` 가 정확히 단언(585·1113·1138행), 폰 `local_missions_test` 가 "16개" 와 키 목록을 단언, 팩 `missions.json` 은 서버 사본과 바이트가 같아야 하고(`test_phone_pack.py` 128행) 2.0.2 PI2c 시험이 팩 sha256 을 상수로 단언(v202 PI2c-4) | `missions.py` 219·303·328행, `local_missions_test.gd` 99·222행 |
| S15 | 녹음 결과 = `{ok, silent, duration, b64, wav: PackedByteArray(mono 16-bit), ...}`. `WavUtil.mono16_with_peak` 는 **샘플 레이트를 바꾸지 않는다**(기기 레이트 그대로) → 48 kHz 면 5초 ≈ 480 KB(기획 §4.2 의 "5초 160 KB" 는 16 kHz 가정) | `recorder.gd` 15·276~285행, `wav_util.gd` |
| S16 | 시험 보호: `Progress.REAL_FILE_NAMES` 에 든 이름만 막는다. 기기 전용 저장소 본보기는 `DiaryStore.effective_path()`(가드가 켜지면 `user://test_guard/…` 로 돌림) | `progress.gd` 157~170행, `diary_store.gd` 74~82행 |
| S17 | "모든 기록 지우기" 확인 글은 `SyncPanel.reset_confirm_text()`(sync 폴더, 수정 금지)를 `settings_view.gd` 897행이 쓴다. 일기는 이 동작으로 지워지지 않는다 | `settings_view.gd` 886~897행, `diary_store.gd` 6행 |
| S18 | DayPlan 은 순수 함수, 늦음 = `expected_week(elapsed_days) - w`(7일 = 1주, 단계 끝 예비 주). 스냅샷은 `HomeParts.snapshot`(2.0.2 RD 가 고치는 파일)이 모은다. 쉬는 날(2.0.2, 주 2일)로 주 5칸만 하면 늦음이 매주 2/7주씩 쌓인다 | `day_plan.gd`, `home_parts.gd` 100행, v202 §2.8 |
| S19 | 코스 플레이어는 지금 문제의 항목 id 를 `_item_of(ex)` 로 안다(신고 대상). 월말은 `CourseStore.month_done` 으로 점수만 저장, 녹음은 `SpeakDrill._last_audio`(b64)에만 잠깐 있다 | `course_player.gd` 557·670행, `speak_drill.gd` 340~345행 |
| S20 | 배지 25개를 `badge_engine_test` 가 여러 곳에서 단언(2.0.2 RD 가 이 파일을 고친다) | `badge_engine_test.gd` 221·381·744행 |
| S21 | 황금 생성기 `make_ai_golden.py`(PI2a, main 에 있음)는 서버 함수를 같은 프로세스에서 부르고 엔진을 대본으로 바꿔 기록한다. `--check` 가 기존 462사례 드리프트를 잡는다 | `make_ai_golden.py` 머리 |

### 0.4 기획 대비 바뀐 점(요약)
| 항목 | 기획 | 이 설계 |
|---|---|---|
| 작업 이름 | K0-R2, A5~A8, X3-1/2, M2, S1, B1, C1, P1, KB-R2, PI-L, W1, BG, Z-R2 | **K1R**(새: 도구 R2 대응), **K0R**, A5~A8, **X3a/X3b**, **HS**(Hydrogen 표본), **SP**(스파이크), M2, S1, **ST**(새: 이야기 앱 쪽), B1, C1 → **RP**(신고)·**CU**(따라잡기) 둘로, P1, **KBR**, PI-L, W1, BG, **FXR**(선택 잔여), **ZR** |
| 활용형 | (언급 없음) | 1~16주 파일을 고치지 않도록 17~32주 파일에 `forms_add`(새, §2.1) |
| 이야기 기억 | 가상 사건 5~8줄·500자·패턴 필터 | **AI 가 쓴 글은 저장하지 않는다**: 장면마다 원고에 적은 기억 문장(템플릿)과 선택지가 있고, AI 는 대화 끝에 선택지 id 만 고른다(enum). 파일에는 템플릿 id 만, 프롬프트에는 그 영어 문장만. 패턴 필터는 이중 방어(§2.6) |
| `missions.json` 병렬 | 2.0.2 와 병렬 가능 | 2.0.2 PI2c 시험이 팩 sha256 을 단언하므로 **작성은 병렬, 병합은 2.0.2 뒤**(M2 가 그 상수 한 줄을 고침) |
| 녹음 용량 | 5초 160 KB(추측) | 기기 레이트 그대로면 3배. **저장 전에 16 kHz 모노로 줄인다**(B1) |
| 재요청 | 최대 2회 | 최대 2회 + **시간 조건**(첫 요청부터 60초가 지났으면 더 묻지 않고 안전 대사) — 앱 180초 제한 보호(S10) |
| 따라잡기 | "정교화" | 규칙 U8~U10 확정(쉬는 날 반영 늦음, 업데이트 대기 표시, 하루 1칸 더) |
| 폰 이야기 PI-L 지연 시 | (절단 7) | 응답에 `level` 이 없으면 앱이 대본 모드로 자동 전환(옛 서버·PI-L 없는 폰도 안전) |

---

## 1. 범위 확정표

| id | 내용 | 2.1.0 | 담당 | 파 | 절단 순서(기획 §2.2) | 비고 |
|---|---|---|---|---|---|---|
| K1R | 콘텐츠 도구 R2 대응(id 한계·17~32주 검사·`forms_add`·`story`·`ai_fallback`·`course_levels.json` 출력·검수 항목 수) | 넣음 | worker-hard | 2 | 유지선 | §2.1 |
| K0R | 17~32주 낱말 배정표 624개·문형 64개 `title_ko/grammar_ko/needs`·id 범위·이야기 시즌 1 개요 16장면·기준 문장 5개·정책 | 넣음 | worker-hard | 2 | 유지선 | §2.2 |
| A5 | 17~20주 원고(파일럿) | 넣음 | worker-hard | 2 | 유지선 | §2.3, 점검 P2 |
| SP | AI 어휘 준수율 스파이크(20대화, 무료 DeepSeek) | 넣음 | worker-hard(+오케스트레이터 승인) | 2 | - | §2.4, 저장소 변경 0 |
| X3a | 17~20주 독립 AI 검수 | 넣음 | worker-hard(작성자와 다른 세션) | 2 | 유지선 | §4 |
| A6·A7·A8 | 21~24·25~28·29~32주 원고 | 넣음 | worker-hard 3명 | 3 | 유지선 | §2.3 |
| X3b | 21~32주 독립 AI 검수 | 넣음 | worker-hard | 3 | 유지선 | §4 |
| HS | 한국어·뜻 표본 300 검수 | 넣음 | Gemini 4 Hydrogen(오케스트레이터가 시트·심은 오류 준비) | 3 | 유지선 | §4 |
| M2 | 미션 `min_week`, 새 미션 2개, 팩 갱신 | 넣음 | worker-hard | 3(작성)·4(병합) | 6 | §2.5 |
| S1 | 서버 `/chat` `course`·`help_ko`·`story`(수준 검사·재요청·안전 대사·기억) | 넣음 | worker-hard | 4 | 유지선(이야기 부분은 7) | §2.6, 위험 높음 |
| KBR | 1~32주 출시 데이터·`course_levels.json`·전수 가드 | 넣음 | worker-hard | 4 | 유지선 | §2.7, 위험 높음 |
| ST | 이야기 앱 쪽(저장소·대화 화면·도움 막대·요청 도우미) | 넣음 | worker-hard | 4 | 7 | §2.8 |
| B1 | 내 녹음 비교(저장소·화면·월말 연결) | 넣음 | worker-hard | 4 | 5 | §2.9, 위험 높음(녹음·개인정보) |
| RP | 오류 신고(저장소·시트·플레이어 버튼) | 넣음 | worker-hard | 4 | 3 | §2.10 |
| CU | 따라잡기 U8~U10 | 넣음 | worker-hard | 4 | 4 | §2.11 |
| P1 | 쉐도잉·받아쓰기 코스 문장 | 넣음 | worker-hard | 4 | 6 | §2.12 |
| PI-L | 폰 `AiChatRules` 수준 맞춤·도움·이야기 이식 + 황금 + `CourseLevels` | 넣음 | worker-hard | 5 | 7(2.0.2 장기 지연 시 2.1.1, D6) | §2.13, 위험 높음 |
| W1 | 대화·미션·설정·연습 허브 연결 | 넣음 | worker-hard | 5 | - | §2.14 |
| BG | 코스 배지 | 선택(D5 A) | worker-hard | 5 | 2 | §2.15 |
| FXR | 사소 잔여: 코스 홈 블록 머리글 폰 1.5배 줄바꿈(E5) | 선택 | worker-hard | 4 | 1 | §2.16 |
| ZR | README·ROADMAP·INSTALL 2.1.0 절 | 넣음 | worker-hard | 6 | - | §2.17 |

---

## 2. 작업별 상세

### 2.0 공통: worktree, 임시 폴더, 병합 관문
- worktree `D:\Ai\언어\app_wt\v210_<작업 소문자>`(PI-L 은 `v210_pil`), 브랜치 `v210/<작업 소문자>`. 이 문서는 분기 전에 main 에 커밋된다(오케스트레이터).
- 임시 파일: 작성자 `<scratch>\w_v210_<작업>\`, 검토자 `<scratch>\w_rev_v210_<작업>\`. `<scratch>` = `C:\Users\rtyu6\AppData\Local\Temp\claude\D--Ai----app\c5535f7a-0e1a-4bb6-bdc3-5597b7f84c22\scratchpad`.
- **병합 관문 G1**: `godot/`·`backend/`·`phone_src/` 를 바꾸는 작업은 **2.0.2 공개 완료 또는 `release/2.0.2` 가지 생성 뒤**에만 main 에 합친다(그 전에 합치면 2.0.2 APK 에 반쯤 된 기능이 실린다). `course_src/` 만 바꾸는 작업(K1R·K0R·A5~A8·X3a·X3b·HS)은 앱에 실리지 않으므로 아무 때나 합친다. 작업 자체(worktree 개발·검토)는 관문 전에 시작해도 된다.
- **병합 관문 G2(2.0.2 파일 의존)**: OWN 에서 `after=PI2b|PI2c|PSI|PWI|RD|PZ` 인 작업은 그 2.0.2 작업이 main 에 병합된 뒤에 분기·재기반한다(M2·PI-L·W1·CU·BG·ZR).
- 새 시험은 `.gd` + `.tscn` 짝, 머리 주석에 실행 명령(PC·`-- --phone`)과 마지막 줄 `== <이름>: N passed, M failed ==`. 새 `class_name` 뒤 `--import` 한 번, 생긴 `.uid` 는 그 작업 소유. 색은 `Pal`, 글자 `Ds.fs`/`UI.label`(최소 12), 눌리는 것은 `Button`, 도형은 `GlyphIcon`, 이모지 0, 보이는 숫자 5자리 이상 0, 진행 글은 `CourseModel.progress_label`.
- 새 기기 전용 파일 3개(`user://course_story.json`, `user://course_reports.json`, `user://voice_compare/`)는 `Progress.REAL_FILE_NAMES` 를 고치지 않고 **각 저장소가 `DiaryStore.effective_path()` 와 같은 방식으로 스스로 돌린다**: `Progress.test_guard` 가 켜져 있고 경로가 `user://test` 로 시작하지 않으면 `user://test_guard/<이름>` 을 쓴다(progress.gd 소유자를 늘리지 않기 위함).

### 2.1 K1R — 콘텐츠 도구 R2 대응 (2파)
- 파일: OWN K1R 줄. **기존 시험 파일(`test_*.py`) 수정 0**: R1 동작·문구는 그대로 두고 R2 동작은 `meta.itemized_weeks[1] >= 32` 일 때만 켠다.
- **릴리스 한계 표**(`check_course.py`):
```
RELEASE_ID_LIMITS = {16: {"words": (1, 699),  "sentences": (1, 999),  "dialogues": (1, 999)},    # 문구 "..._outside_R1_limits" 그대로
                     32: {"words": (1, 1399), "sentences": (1, 1999), "dialogues": (1, 999)}}    # 문구 "..._outside_R2_limits"
itemized_hi = skeleton.meta.itemized_weeks[1] (없으면 16) ; 16·32 밖의 값은 SCHEMA itemized_weeks_unsupported
```
  - `w <= 16` 로 묶인 `can_do`·문형 `title_ko`·`grammar_ko` 검사 → `w <= itemized_hi`. 배정표 id 상한 699 → 표의 `words` 상한. 배정표 합계: 1~16주 기존 범위 그대로 + `itemized_hi >= 32` 면 `DEFAULT_LIMITS` 에 더하는 `"assign_active_17_32": [380, 420]`, `"assign_passive_17_32": [213, 235]`(400·224 의 ±5%), 빠진 주는 `weeks_1_to_<hi>_not_all_assigned`. 캐나다 노트 "2주마다" 규칙은 8~16주 그대로(17~20주는 뼈대에 노트가 없다, S1).
  - skeleton 최상위 새 키 허용: `story_season1`, `voice_ref`(§2.2). `--strict` 의 모르는 키 경고 대상에서 뺀다.
- **주 파일 새 키**(`WEEK_KEYS` 에 더함, 17~32주만 의미가 있고 1~16주 파일에 있으면 SCHEMA):
```json
"forms_add": [{"word": "w0412", "f": "went", "pat": "p_went_to"}],
"ai_fallback": [{"id": "af1701", "en": "Oh, really?", "ko": "아, 정말요?", "say": ""}],
"story": { ... §2.6.2 ... }
```
  - `forms_add`: `word` 는 **이 주보다 앞 주**의 낱말 id(같은 주면 그 레코드의 `forms` 에 적는다 → SCHEMA `forms_add_same_week`), `pat` 은 **이 주의 문형**, `f` 는 `FORM_SUSPECT` 규칙(`forms_en.py`)을 통과, 같은 형태 중복 0. 형태 o = max(낱말 o, 문형 o). 빌드는 그 낱말의 `en_lexicon` 레코드 `forms` 뒤에 붙인다. `forms_en.py` 의 불규칙 표에 17~31주 테마의 과거형(was were went had ate saw met got took made came gave said told paid bought found left lost sent felt thought 등)·비교형(better best worse worst more most)을 더한다.
  - `ai_fallback`: 주당 6~10개, id `^af(\d{2})(\d{2})$`(앞 두 자리 = 주), `en` 은 1문장·8낱말 이하, 토큰 검사는 **앞 주 끝 o = (w-1)*10+7**(그 주 어느 날에 써도 안전), 수동 낱말 0, `ko` 해요체·`KO_*`, `NUM_SAY`, 같은 주 안 영어 중복 0.
  - `story`: §2.6.2 규칙 전부(SCHEMA·ORDER·UNKNOWN_TOKEN·PERSONAL·BLOCKED·KO_*·NUM_SAY). `DUP_EN` 은 `story`·`ai_fallback` 에 적용하지 않는다.
- **검수 항목 수**(`--count-items`, `--review`): 종류에 `story_line`(여는 말 + 대본 줄), `story_mem`, `story_text`(`title_ko`·`premise_ko`·`goal_ko`), `fallback` 을 더한다. 출력 `ITEMS weeks=.. word=.. pattern=.. sentence=.. dialogue_line=.. story_line=.. story_mem=.. story_text=.. fallback=.. total=N`(새 종류는 R2 주에서만 0 이 아님 → R1 출력 줄 형식이 바뀌면 안 되므로, 새 종류 4개는 **값이 0 이 아닐 때만** 줄 끝에 붙인다). `sample_sheet.py` 는 새 종류를 층 `dialogue_line` 으로 센다(층 비율 90/120/50/40 그대로).
- **빌드**(`build_course.py`): 주 레코드에 `story`(키 `_` 로 시작하는 것 제외)·`ai_fallback` 을 그대로 싣는다. 새 옵션 `--levels-out <path>` 가 있으면 `course_levels.json`(§2.7.1 형식)을 쓴다(없으면 안 씀). **R1 출력 바이트 불변**: `--weeks 1-16` 빌드 결과가 지금 커밋된 `godot/data/course/*` 와 sha256 같음(K1R-4).
- 픽스처: `make_fixtures.py` 가 `fixtures/r2/` 아래 `good_r2_mini`(17~18주 2주짜리, 배정표·story·fallback·forms_add 포함)와 `bad_r2_<이름>` 폴더를 만든다(기존 픽스처 바이트 불변, `--check` 통과).

### 2.2 K0R — 17~32주 뼈대·배정표·이야기 개요·정책 (2파, K1R 병합 뒤 `--skeleton` 확인)
- `skeleton.json`:
  - `meta.itemized_weeks = [1, 32]`, `meta.notes_ko` 에 2.1.0 줄 추가(참고 자료·"복사 안 함").
  - `words` 에 17~32주 항목 624개(`id lemma pos role w d`, id `w0700` 부터 연속), `weeks[17..32].words.new/passive`·`days[].words` 채움. 주별 개수는 `counts` 그대로(400/224), 일 분배 D1 7·D2 6~7·D3 6·D4 6(±1).
  - `patterns` 17~32주 64개에 `title_ko`·`grammar_ko`(2~4줄, 줄당 ≤ 90자)·`needs`(그 문형 o 이전 낱말만).
  - `id_ranges`: 기존 키 유지 + `words.assigned_r2 = ["w0700","w1323"]`, 작성자 키 **`R2A`(17~20)·`R2B`(21~24)·`R2C`(25~28)·`R2D`(29~32)**(기존 `A5` 키와 겹치지 않게): 고유명사 낱말 `R2A w1330~w1346, R2B w1347~w1363, R2C w1364~w1380, R2D w1381~w1399`, 문장 `R2A s1000~s1249, R2B s1250~s1499, R2C s1500~s1749, R2D s1750~s1999`, 대화 `R2A d0017~d0020 … R2D d0029~d0032`, `authors` 주 범위.
  - `story_season1`(새): `{"learner": {"name": "Min", "phone": "555-0142"}, "eps": [{"ep": 1, "w": 17, "id": "s1e01", "title_ko", "partner": "Sam", "places": ["Harbour Hostel"], "slots": ["stay"], "summary_ko": "..."} × 16]}` — 기획 §3.1 시즌 1 줄거리(17~20 도착 회상, 21~24 날씨·계획·약속·교통, 25~28 식당·쇼핑·전화·약국, 29~32 방·비교·조언·정리) 순서. 인물·장소는 `policy.json` 허용 목록 안.
  - `voice_ref`(새): 녹음 비교 기준 문장 5개 = **기존 R1 문장 id**(새 글 0, 이미 검수됨). 추천 `["s0266", "s0176", "s0443", "s0687", "s0522"]`(Nice to meet you. / I'm from Korea. / I'd like a large coffee, please. / Could you say that again? / I get up at seven every day.) — §8 D-5.
- `policy.json`: `Harbour Hostel` `from_w` 34 → **17**(S5). 이야기에 새 가상 장소가 필요하면 `fake_businesses` 에 더한다(실제 체인·실존 가게 이름 금지, 보고에 이름·주 목록). `context_allowed` 는 바꾸지 않는다.
- 하지 않음: 낱말 `ko`·예문(작성자 몫), 1~16주 항목 변경, 외부 단어표 복사.

### 2.3 A5~A8 — 17~32주 원고 (A5 2파 파일럿, A6~A8 3파)
- 형식은 `course_src/tools/README.txt` 의 주 파일 + §2.1 새 키. 작가는 **자기 4주 파일만**, id 는 자기 `R2x` 범위 안.
- **주당 분량 목표와 정책 규칙 대조**(규칙 = S3, 목표는 이 설계가 정함):

| 주 | 능동 | 수동 | 문형 | 문장 하한(규칙) | 문장 목표 | 대화 줄 | 월말 문항 | 이야기 | 안전 대사 |
|---|---|---|---|---|---|---|---|---|---|
| 17·18 | 25 | 14 | 4 | 36 | 48~60 | 6~10 | 0 | 2~3회 | 6~10 |
| 19 | 26 | 14 | 4 | 36 | 48~60 | 6~10 | 0 | 2~3회 | 6~10 |
| 20 | 26 | 14 | **5** | 36 | 50~60 | 6~10 | **3** | 2~3회 | 6~10 |
| 21~23, 25~27, 29~31 | 26 | 14 | 4 | 36 | 48~60 | 6~10 | 0 | 2~3회 | 6~10 |
| 24·28 | 26 | 14 | 4 | 36 | 48~60 | 6~10 | **3** | 2~3회 | 6~10 |
| 32(종합) | 12 | 14 | 3 | 36 | 40~56 | 6~10 | **3** | 2~3회 | 6~10 |

  - 근거: 능동 26 x 2 = 52 칸 + 수동 14 칸, 문장 하나가 새 낱말 평균 1.5개를 덮으면 약 44문장이 필요하고 문형 4 x 6 = 24 는 그 안에 겹친다 → **48~60** 이면 모든 하한을 넘는다. 상한은 **id 예산**에서 온다: R2 문장 id 1000개 / 16주 = 62.5 → 작가 범위 250 / 4주 = 주당 최대 62(R1 페이스 64.3 을 그대로 따르면 넘친다, S2·위험 R7).
  - 낱말 수(영어, 추측): 문장 54 x 6~7 ≈ 350, 대화 8줄 x 7 ≈ 56, 이야기(여는 말·대본 2.5회 x 5줄 x 7 + 기억 문장 6~10 x 8) ≈ 160, 안전 대사 8 x 3 ≈ 24, 월말 3 x 10 → **주당 약 600~700 낱말**, 16주 약 1만 낱말. 검수 항목 수(추측): 낱말 624 + 문형 64 + 문장 약 860 + 대화 줄 약 130 + 이야기 줄 약 200 + 기억 문장 약 130 + 이야기 글 약 100 + 안전 대사 약 130 ≈ **2,200**.
  - Tatoeba 는 쓰지 않아도 된다(R1 0). 쓰면 ≤ 25%.
- 활용형: 이 주 문형이 가르치는 형태가 **앞 주 낱말**의 것이면 `forms_add`, 이 주 낱말이면 그 레코드 `forms`(뒤 주 문형의 형태도 R1 방식대로 그 레코드에, 문형 o 가 뒤라서 문제없음).
- 이야기·안전 대사: §2.6.2 형식. 장면 인물·장소·`slots` 는 `skeleton.story_season1` 을 따른다(바꾸려면 오케스트레이터에게 보고). 대본 줄·여는 말은 그 주 D5 까지 배운 말만(o = w*10+5), 기억 문장은 그 주 끝(w*10+7)까지.
- 실제 정보 금지: 금액·세율·팁 비율·법·절차는 숫자로 박지 않는다(v200 §2.4). 전화번호 `555-01xx`, 이메일 `example.com`.

### 2.4 SP — AI 어휘 준수율 스파이크 (2파, 저장소 변경 0)
- 목적: S1 상수 **[SP 뒤 확정]**(낱말 수·문장 수·OOV 한도·재요청 문구·최근 목록 길이)을 실측으로 고른다.
- 방법: worker-hard 가 `<scratch>\w_v210_sp\` 에 파이썬 스크립트를 쓴다. `backend\.venv` 로 서버 모듈을 같은 프로세스에서 불러 **무료 DeepSeek(OpenCode, 키 없음)** 엔진만 쓴다(오케스트레이터가 실행 전 OpenCode 연결을 확인; 안 되면 SP 는 "미검증", 상수는 이 문서 기본값). 프롬프트·검사는 §2.6.3 규칙의 스크래치 사본. 대화 20개 = 주 17·21·25·29 x 5대화 x 학습자 6턴(학습자 줄은 A5 파일럿 문장과 짧은 대답으로 미리 만든 대본 — 개인정보 0).
- 출력 `<scratch>\w_v210_sp\sp_result.json` 과 요약 줄 `SP replies=N first_ok=P1% final_ok=P2% fallback=P3% avg_attempts=A avg_sec=T oov_per_reply=O`. 변형 2개 이상(예: 최근 목록 8주 vs 4주, OOV 한도 1 vs 0)을 같은 대화로 비교.
- 저장소 파일 0, 서버 설정·`secrets.json` 열람 0, 요청 수 상한 400(20대화 x 6턴 x 최대 3회 + 여유).

### 2.5 M2 — 미션 `min_week`·새 미션 2개 (3파 작성, 4파 병합: G1·G2(PI2c))
- `backend/content/missions.json`: 영어 미션에 선택 필드 `min_week`(정수 1~72)를 더한다: `self_intro 13`, `cafe_order 13`, `ask_directions 29`, `restaurant 29`, `return_item 31`, 새 `transit_help 29`, 새 `phone_call_basic 31`. 그 밖 미션(`hotel_checkin`·`pharmacy_doctor`·`job_interview`·일본어)은 **변경 0**(R3·R4 몫). 새 미션 두 개는 기존 형식 그대로(`id lang min_stage(2) order max_turns title_ko situation_ko persona scene opening goals[ {id,label_ko,goal_en,hint_en,match{any,all},pos≥6,neg≥6} ] script`), `hint_en`·`opening`·대본 줄은 `min_week` 까지 배운 코스 어휘만(검사 M2-4), 장소·이름은 `policy.json` 허용 목록.
- `backend/missions.py`: `build_mission` 이 `min_week`(정수 1~72, 아니면 없음)를 읽고, `public_mission` 은 **있을 때만** `min_stage` 바로 뒤에 `min_week` 를 넣는다(없는 미션의 응답 키 순서·모양 불변). 목록 필터는 지금처럼 `min_stage` 만.
- `backend/test_missions.py`: 공개 모양 단언을 "기존 9키, 또는 9키 + `min_week`" 로 넓힌다(그 단언 3곳만), 설계 표 `min_week` 대조 1개, 영어 미션 수 기대 8 → 10. 그 밖 단언 변경 0.
- 팩: `backend\.venv\Scripts\python.exe -I backend\tools\build_phone_pack.py --only content` → `godot/data/pack/missions.json`·`manifest.json` 만 바뀐다(다른 팩 파일 바이트 불변 확인).
- `local/local_missions.gd`: `min_week` 를 서버와 같은 규칙으로 통과. `core/mission_logic.gd`: `normalize_mission` 에 `min_week`(없으면 0), 새 `static func fits(m: Dictionary, stage: int, cw: int) -> bool`(cw > 0 이고 `min_week` > 0 이면 `min_week <= cw`, 아니면 `min_stage <= stage`)와 `static func sort_for(missions: Array, stage: int, cw: int) -> Array`(맞는 것 먼저, 안에서는 원래 순서). `sort_for_stage` 는 그대로 둔다(W1 이 새 함수로 바꿔 부른다).
- 시험: `local_missions_test.gd` 의 "16 missions" → 18, 키 목록은 그대로(포함 검사). `ai_feedback_parity_test.gd` 의 팩 sha256 상수 **한 줄만** 새 값으로(PI2c 소유 파일, G2).

### 2.6 S1 — 서버 `/chat` 수준 맞춤·한국어 도움·이야기 (4파, G1)
#### 2.6.1 요청·응답 계약 (`POST /chat`, 새 라우트 없음, 모든 새 필드는 선택)
```json
{"lang":"en","stage":2,"month":4,"week":1,"scenario":{...},"history":[...],
 "course":{"w":21,"d":5,"mode":"guided","simplify":false},
 "help_ko":"버스 정류장이 어디인지 묻고 싶어요",
 "story":{"id":"s1e05","part":1,"mode":"talk","memory":["You are staying at Harbour Hostel."]}}
```
- `course.w` 정수 1~72, `course.d` 정수 1~7(없으면 7), `course.mode` ∈ `guided | mission | story | free | open`(그 밖은 `guided`), `course.simplify` bool. `lang != "en"`, `w` 가 정수가 아님·범위 밖, `course_levels.json` 이 없거나 깨짐 → **`course`·`help_ko`·`story` 를 모두 무시하고 지금과 100% 같은 처리**(오류 아님).
- 응답(대화): 기존 키 + `"level": {"oov": ["word"], "source": "ai"|"fallback", "attempts": 1..3, "w": 21}`. `course` 가 무시되면 `level` 키 없음(앱은 이것으로 "수준 검사 안 됨"을 안다).
- `help_ko`(문자열, 앞뒤 공백 제거 1~120자, `course` 필수): 대화를 잇지 않고 `{"help": {"en": "...", "ko": "...", "oov": [...], "source": "ai"|"none", "attempts": n}}` 만. 1~120자가 아니면 400 `"도움 글은 1~120자로 써 주세요."`, `course` 가 무시되는 상황이면 400 `"한국어 도움은 코스 대화에서만 돼요."`.
- `story.mode == "summary"`: 대화를 잇지 않고 `{"story": {"slots": {"stay": "hostel", ...}, "source": "ai"}}`(값은 그 장면 선택지 id 또는 `""`). `story.id` 가 데이터에 없으면 `story` 무시.
- 라우트의 `tts_chunks` 래퍼는 `reply` 가 있을 때만 동작(지금 코드 그대로 → `help`·`summary` 응답엔 없음).

#### 2.6.2 이야기 데이터(원고 주 파일 `story`, 빌드 뒤 `en_weeks.json` 주 레코드와 `course_levels.json` 에 실림)
```json
"story": {
  "id": "s1e01", "title_ko": "밴쿠버 첫날 밤", "premise_ko": "(≤120자, 화면용)",
  "premise_en": "(≤400자, AI 전용 가상 설정. 화면에 안 나옴)",
  "partner": {"name": "Sam", "role_en": "the night staff at Harbour Hostel", "role_ko": "Harbour Hostel 야간 직원"},
  "parts": [
    {"n": 1, "goal_ko": "어제 어디에 있었는지 말하기", "goal_en": "The learner says where they were yesterday.",
     "opening": {"en": "Hi! Were you at the airport yesterday?", "ko": "안녕하세요! 어제 공항에 있었어요?", "say": ""},
     "script": [{"s": "A", "en": "...", "ko": "...", "say": ""},
                {"s": "B", "en": "...", "ko": "...", "say": "", "hint_ko": "...", "accept": ["..."]}],
     "mem_default": "m01_arrived"}],
  "slots": [{"id": "stay", "q_en": "Where does the learner say they are staying?",
             "choices": [{"id": "hostel", "mem": "m01_stay_hostel"}, {"id": "friend", "mem": "m01_stay_friend"}]}],
  "mem": [{"id": "m01_arrived", "en": "You arrived in Vancouver yesterday.", "ko": "어제 밴쿠버에 도착했어요."},
          {"id": "m01_stay_hostel", "en": "You are staying at Harbour Hostel.", "ko": "Harbour Hostel 에 묵고 있어요."}]}
```
- 규칙(K1R 린터가 강제): `id == "s1e%02d" % (w-16)`; `title_ko` ≤ 30자·`premise_ko` ≤ 120자·`goal_ko` ≤ 40자(한글 필수); `premise_en` ≤ 400자·`role_en` ≤ 80자·`goal_en` ≤ 120자(토큰 검사 제외, PERSONAL·BLOCKED 검사); `partner.name` 은 정책 허용 이름(from_w ≤ w); `parts` 2~3개(`n` = 1..), `opening` + `script` 4~6줄(A·B 번갈아, B 줄은 `hint_ko` 필수), 토큰 검사 o = w*10+5(A 줄은 수동 낱말 허용, B 줄·opening 은 불허); `slots` 1~3개(id `^[a-z][a-z0-9_]{0,15}$`, 장면 안 유일), 선택지 2~4개; `mem` 2~12개(id `^m(0[1-9]|1[0-6])_[a-z0-9_]{1,24}$` 앞 두 자리 = ep, 시즌 전체 유일), `en` ≤ 80자·1문장·토큰 검사 o = w*10+7, `ko` ≤ 60자; 모든 `mem` 은 선택지나 `mem_default` 가 가리킨다; 숫자는 `555-01xx` 꼴만.

#### 2.6.3 수준 검사·재요청·안전 대사(규범. 폰 PI-L 이 글자 그대로 같게 한다)
- 새 모듈 `backend/course_level.py`(표준 라이브러리만, 서버 밖에서도 import 가능, 네트워크·파일 쓰기 0):
```
LEVELS_PATH = <backend>/content/course_levels.json      # 시험·황금: set_levels(dict) 로 바꿈
WORDS_PER_SENTENCE = [(8, 6), (16, 8), (32, 12), (72, 16)]   # [SP 뒤 확정] (w 상한, 문장당 낱말)
MAX_SENTENCES = {"guided": 2, "mission": 2, "story": 2, "help": 1, "free": 3, "open": 4}   # [SP 뒤 확정]
OOV_MAX = [(16, 0), (40, 1), (72, 2)]                     # [SP 뒤 확정]
MAX_ATTEMPTS = 3            # 첫 요청 + 재요청 2
RETRY_IF_ELAPSED_UNDER = 60.0   # 초. 첫 요청을 보낸 뒤 이 시간이 지났으면 더 묻지 않는다
RECENT_WEEKS = 8            # [SP 뒤 확정] 프롬프트에 넣는 최근 능동 낱말 범위
MEM_MAX_LINES = 8 ; MEM_MAX_CHARS = 500 ; MEM_LINE_MAX = 80
def load() -> dict | None ; def set_levels(d: dict | None) -> None ; now = time.monotonic   # 시험 훅
def tokenize(text) -> list[str]                  # course_common.tokenize 와 같은 규칙(NFKC, 소문자, U+2019 -> ', [^\W_]+(?:'[^\W_]+)*)
def limits(w, mode, simplify) -> {"max_sentences", "max_words", "oov_max"}
def level_check(levels, text, w, d, mode, simplify) -> {"ok", "why": ""|"sentences"|"length"|"oov", "oov": [...], "sentences", "max_words"}
def course_prompt(levels, w, d, mode, simplify) -> str
def retry_note(check, lim) -> str
def pick_fallback(levels, w, n_hist) -> {"en", "ko"}
def clean_memory(levels, lines) -> list[str]
def story_prompt(levels, story_id, part, memory) -> str
def summary_messages(levels, story_id, part, hist) -> (messages, schema)
def help_messages(levels, w, d, help_ko, hist, scenario) -> (messages, schema)
```
- `limits`: `max_words` = 표에서 `w` 이상 첫 값, `max_sentences` = 모드 표, `oov_max` = 표. `simplify` 면 `max_words = max(5, max_words - 4)`, `max_sentences = 1`.
- `level_check` 알고리즘(이 순서): `cur_o = w*10 + d` → 글을 `(?<=[.!?])\s+` 로 나눠 토큰이 있는 조각만 문장으로 → 각 문장의 원래 대소문자 토큰을 차례로: 숫자가 든 토큰은 허용, `tokens[low] <= cur_o` 면 허용, **문장 첫 토큰이 아니고 대문자로 시작**하면 고유명사로 허용, 그 밖은 `oov`(처음 나온 순서, 중복 없이) → `why`: 문장 수 초과 `sentences` > 문장 낱말 수 초과 `length` > `len(oov) > oov_max` 면 `oov` > 아니면 `""`.
- `course_prompt`(영어, 시스템 프롬프트 끝에 붙임): `"LEVEL LIMITS: The learner is in week {w} of a 72-week course for Korean beginners. Use at most {S} sentence(s), each at most {N} words. Use mainly these words the learner knows (most recent first): {최근 목록}. Otherwise use only very common basic words. No idioms or phrasal verbs."` + 모드별 한 줄(guided: `"End with one easy question."`, mission·story: `"Stay in your role."`). 최근 목록 = `week[w..w-RECENT_WEEKS+1].recent` 중 o ≤ cur_o 인 영어 표제어, o 큰 순, 최대 320개.
- `retry_note`(직전 대화 끝에 user 메시지로 붙임): `why == "oov"` → `"(Too hard for the learner: {oov}. Say it again without those words, in at most {S} short sentence(s) of at most {N} words. JSON only.)"`, `sentences`/`length` → `"(Too long. Say it again in at most {S} short sentence(s) of at most {N} words. JSON only.)"`.
- **`run_chat` 의 코스 경로**(`course` 가 유효할 때만):
  1. 시스템 프롬프트 = 기존 `rules_text(...)` + `"\n\n" + course_prompt(...)` (+ `story.mode == "talk"` 이고 장면이 있으면 `"\n\n" + story_prompt(...)`).
  2. 시도 루프 `attempt in 0..MAX_ATTEMPTS-1`: 첫 시도는 기존과 같은 경로(OpenCode 세션 또는 `llm_json`, 온도 0.6), 그 뒤는 `llm_json`(온도 0.45). 응답이 기존 유효성 검사(빈 답·한글·`ko_ok`)에 걸리면 같은 메시지로 다시, 수준 검사에 걸리면 `retry_note` 를 붙여 다시. 실패한 OpenCode 세션 답은 지금처럼 `invalidate`. **`now() - t0 >= RETRY_IF_ELAPSED_UNDER` 이면 더 묻지 않는다.**
  3. 통과하면 `level.source = "ai"`. 끝까지 실패하면 `pick_fallback`: `week[w].fallback[len(hist) % n]` → `reply`·`ko`, `reading ""`, `level.source = "fallback"`(502 를 내지 않는다).
  4. `suggest` 는 각 줄을 같은 `level_check` 로 걸러(실패 줄 제거) 2개가 안 되면 안전 대사 다음 두 줄의 `en` 으로 채운다(재요청 없음).
  5. 엔진 오류(연결·한도·인증 등 형식 오류가 아닌 `LlmError`)는 지금처럼 바로 올린다(재요청·안전 대사 없음, 요금 보호).
  6. `fix`·`fix_ko`(학습자 문장 고치기)는 지금 그대로.
- **`help_ko` 경로**: `help_messages`(시스템: 같은 수준 규칙 + `"Write ONE short English sentence the learner can say for the Korean below. Give its natural Korean meaning in ko."`, user: 한국어 + 최근 6턴) + 스키마 `{"en": str, "ko": str}` → `level_check(mode="help")` 와 `ko_ok` 로 최대 3회(같은 시간 조건) → 실패면 `source "none"`, `en ""`. 캐시 끔, 로그에 글 0.
- **`story` 요약 경로**: `summary_messages` = 시스템 `"You classify a finished role-play. For each slot, pick the choice id that matches what happened, or \"\" if unclear. Never invent details."` + 슬롯마다 `q_en` 과 선택지(id: 그 기억 문장 `en`), user = 최근 12턴 대본 → 스키마 `{"slots": {<slot>: {"type": "string", "enum": [<choice ids>..., ""]}}}`(전 슬롯 필수) → 형식 오류 1회 재시도(기존 규칙) → 모르는 값은 `""`.
- **기억 정리 `clean_memory`**(서버·폰 같음, §2.13): 각 줄을 공백 정리 → `levels.story_mem` 값(시즌 전체 기억 문장 영어)과 **글자까지 같은 것만** 남김 → 개인정보 정규식(아래)에 걸리면 버림 → 중복 제거 → 마지막 8줄 → 앞에서부터 빼서 합계 500자 이하. 정규식(대소문자 무시): `@`, `https?://|www\.`, 연속 숫자 3자리 이상(단 `555-01\d\d` 전체 일치 부분은 제외), 낱말 `passport|password|birthday|birth date|date of birth|social insurance|credit card|account number|e-?mail|real name|address`.
- `story_prompt`: `"STORY (fiction, season 1, episode {ep}, part {n}): {premise_en} You are {partner.name}, {role_en}. The learner plays Min, a Korean working-holiday newcomer in Vancouver. Story so far:\n- {기억}\n...\nThis part's goal: {goal_en}. Never ask for the learner's real name, address, phone number, birthday, e-mail, or any ID or bank number. If the story needs them, use: name Min, phone 555-0142."`(기억이 없으면 그 줄 생략).
- 로그: 새 경로의 로그 줄은 숫자·코드만(`"course chat w=%d attempts=%d source=%s"`). `help_ko`·기억·학습자 글·AI 답 글은 로그 0.

### 2.7 KBR — 1~32주 출시 데이터·서버 수준표 (4파, G1, A5~A8·X3a/b C 0·HS C 0 뒤)
#### 2.7.1 `backend/content/course_levels.json`(새, `build_course.py --levels-out`)
```json
{"v":1,"lang":"en","weeks":[1,32],
 "tokens":{"hi":11,"hello":11,"went":191},
 "week":{"17":{"recent":[["was",171],["were",171]],
               "fallback":[{"en":"Oh, really?","ko":"아, 정말요?"}],
               "story":{"id":"s1e01","premise_en":"...","partner":{"name":"Sam","role_en":"..."},
                        "parts":[{"n":1,"goal_en":"..."}],
                        "slots":[{"id":"stay","q_en":"...","choices":[{"id":"hostel","mem":"m01_stay_hostel"}]}],
                        "mem":[{"id":"m01_stay_hostel","en":"You are staying at Harbour Hostel."}]}}},
 "story_mem":{"m01_stay_hostel":"You are staying at Harbour Hostel."}}
```
- `tokens` = 토큰 → 가장 이른 o: 능동·수동 표제어 토큰, 활용형(`forms[].o`, `forms_add` 포함), `alt`, 여러 낱말 표제어의 각 토큰(그 표제어 o), 두문자어는 소문자. `recent` = 그 주 능동 표제어 `[en, o]`(o 순). 한 줄 JSON(`separators=(",",":")`, 키 정렬), 결정적.
- 출시 데이터는 지금처럼 `build_course.py --in course_src/en --out godot/data/course`(1~32주) + `--levels-out backend/content/course_levels.json`.
- 시험 갱신: `course_data_real_test`(1~32주 개수·무결성, R1 레코드 불변), `course_guard_all_test`(1~32주 전수 + 이야기·안전 대사 줄 가드).

### 2.8 ST — 이야기 회화 앱 쪽 (4파, G1. 기존 파일 수정 0)
- **`StoryStore`**(새, `core/story_store.gd`, 정적): 파일 `user://course_story.json`(동기화 밖, 기기 전용).
```json
{"v":1,
 "eps":{"s1e01":{"parts":[1,2],"done":"2027-01-03","last":"2027-01-03","script":false}},
 "memory":[{"id":"m01_stay_hostel","ep":"s1e01","slot":"stay","t":"2027-01-03"}],
 "notice_seen":true}
```
  - **파일에 영어·한국어 글이 없다**(템플릿 id 만). 모르는 키 보존, 깨지면 `.bad` 로 옮기고 빈 상태, 쓰기는 `Progress.write_text_atomic`, 시험 가드 돌림(§2.0).
```
const PATH := "user://course_story.json" ; const MAX_MEM := 8 ; const MAX_MEM_CHARS := 500 ; const MAX_TURNS := 6
static var path := PATH
static func effective_path() -> String
static func scene(w: int) -> Dictionary                 # CourseData.week(w).story 또는 {}
static func scene_by_id(id: String) -> Dictionary
static func state(id: String) -> String                 # "done" | "partial" | "new"
static func open_for(id: String, cw: int) -> Dictionary # {open: bool, soft_week: int} — 장면 주 <= cw 면 열림, 아니면 "N주차부터"(부드러운 잠금)
static func memory_lines() -> Array                     # [{id, ep, en, ko}] — 데이터에 없는 id 는 빼고 돌려줌
static func memory_en() -> Array                        # 요청용 영어 줄(정리 규칙 §2.6.3 을 앱에서도 적용)
static func finish_part(id: String, part: int, slots: Dictionary, script: bool) -> Dictionary   # {ok, added:[ids]}
static func fill_previous_default(id: String) -> void   # 바로 앞 장면에 기억이 하나도 없으면 그 장면 마지막 회 mem_default 1줄
static func delete_memory(mem_id: String) -> bool ; static func clear_memory() -> bool ; static func reset_all() -> bool
static func mem_ok(line: String) -> bool                # §2.6.3 정규식 (이중 방어)
```
  - `finish_part`: 슬롯마다 값이 그 장면 선택지 id 면 그 `mem` 을 슬롯 키로 넣는다(같은 슬롯은 교체). 유효한 값이 하나도 없으면 그 회의 `mem_default`(키 `default:<id>:<n>`). 8줄 초과·500자 초과면 오래된 것(`t`, 같으면 장면 순)부터 뺀다.
- **`CourseChat`**(새, `core/course_chat.gd`, 정적, 순수):
```
const IDLE_SEC := 15.0
static func course_field(mode: String, simplify := false) -> Dictionary   # {"w": cw, "d": cd, "mode", "simplify"} (코스 모드 영어가 아니면 {})
static func story_field(id: String, part: int, mode: String) -> Dictionary # {"id","part","mode","memory": StoryStore.memory_en()}
static func help_body(base: Dictionary, ko: String) -> Dictionary
static func parse_level(resp: Dictionary) -> Dictionary  # {checked: bool(level 키 유무), oov: Array, source}
static func underline_bbcode(text: String, oov: Array) -> String   # "[" 를 "[lb]" 로 이스케이프한 뒤 oov 낱말(대소문자 무시, 낱말 경계)을 "[url=oov:<w>][u]..[/u][/url]"
class HelpSteps: step 0 대기 → 1 한국어 뜻 → 2 말할 문장(suggest) → 3 [한국어로 말해 보기]; idle(sec) 로 진행, reset()
```
- **`ChatHelpBar`**(새, `ui/chat_help_bar.gd`): 버튼 `HelpStep1`("뜻 보기")·`HelpStep2`("말할 문장")·`HelpStep3`("한국어로 말해 보기") + 한국어 입력칸(120자) + 결과 줄(영어 + 한국어 + [듣기] + [이 문장 쓰기]). 시그널 `use_text(en: String)`, `help_requested(ko: String)`. 15초 무입력이면 다음 단계 버튼이 강조되고, 버튼은 언제든 직접 눌러도 된다.
- **`StoryView`**(새, `views/story_view.gd`, `class_name StoryView`, `static func open(host: Node) -> Node`, `static func open_memory(host: Node) -> Node`):
  - 목록: 시즌 1 장면 16개(제목·상태·"N주차부터" 부드러운 잠금 + [그래도 해 보기]). 첫 진입 한 번 안내 `TXT_NOTICE := "이야기 기억(가상 사건 몇 줄)은 다음 대화 때 AI 업체로 함께 보내져요. 실제 이름·주소·번호 같은 개인 정보는 묻지도 저장하지도 않아요."` + [알겠어요](`notice_seen`).
  - 회 시작: 첫 요청(빈 기록, `course.mode "story"`, `story.mode "talk"`)이 **오류이거나 응답에 `level` 이 없으면**(수준 검사를 못 하는 연결 — 옛 서버, PI-L 없는 폰) 대본 모드로 바꾸고 `TXT_SCRIPT := "지금은 AI 와 이야기할 수 없어서 대본으로 이어 가요."` 를 보인다(자동 재시도 0).
  - AI 모드: 말풍선(AI 줄은 `RichTextLabel` + `underline_bbcode`, 밑줄 낱말을 누르면 뜻: `CourseData` 낱말이면 그 `ko`, 아니면 `POST /reading/gloss`), 입력칸 + [보내기], `ChatHelpBar`, 학습자 6턴 또는 [끝내기] → 요약 요청(`story.mode "summary"`) → `StoryStore.finish_part(id, n, slots, false)`(오류면 `{}` → 기본 기억). 화면에 "이번에 기억한 것" 줄 표시.
  - 대본 모드: `parts[n].script` 를 차례로(A 줄 소리·한국어, B 줄은 `hint_ko` + [듣기] + [다음]) → `finish_part(id, n, {}, true)`.
  - 기억 화면(`open_memory`): 줄마다 영어·한국어·[지우기](`StoryMemDel_<id>`), [기억 모두 지우기](확인 시트), [이야기 처음부터](기억 + 진행, 확인 시트).
  - 요청은 `Api.post_json("/chat", body, Api.TIMEOUT_LLM, true)` 한 길(폰이면 `Route` 가 `LocalAi` 로 보냄). 2.0.2 클래스(`AiState` 등)를 직접 부르지 않는다(병합 순서와 무관하게 파싱되게).
  - 요청 수 상한(한 회): 여는 말 1 + 학습자 턴 ≤ 6 + 요약 1 = 8.

### 2.9 B1 — 내 녹음 비교 (4파, G1, 위험 높음)
- **`VoiceCompareStore`**(새, `core/voice_compare_store.gd`, 정적):
```
const DIR := "user://voice_compare" ; const INDEX := "index.json"
const MAX_BYTES := 20971520          # 20 MiB (변이 대상). 표시는 "3.2MB / 20MB" 꼴(소수 한 자리)
const RATE := 16000 ; const MAX_CLIP_SEC := 15.0
const REF_IDS := ["s0266", "s0176", "s0443", "s0687", "s0522"]   # skeleton voice_ref 와 같음(D-5)
const CONSENT_TEXT := "녹음은 이 기기 안에만 저장되고 PC·다른 기기·인터넷으로 나가지 않아요. 언제든 지울 수 있어요."
static var root := DIR                # 시험: "user://test_vc_<이름>"
static var max_bytes_override := -1   # 시험 전용
static func effective_root() -> String
static func enabled() -> bool
static func enable() -> bool          # 이때 처음 폴더·index 를 만든다
static func disable() -> bool         # 새 저장만 멈춤(파일 유지)
static func save_clip(kind: String, item: String, wav: PackedByteArray, score: int = -1) -> Dictionary
    # kind "ref"|"month"; item "ref1".."ref5" | "m05_sp2001"(월 + 문항 id)
    # -> {ok, err: ""|"off"|"full"|"bad_audio"|"io", id, bytes, need_bytes}
static func clips(item: String = "") -> Array      # [{id, kind, item, date, sec, bytes, score}] 날짜 순
static func pair(item: String) -> Dictionary       # {first, latest} (하나뿐이면 latest = {})
static func middle_clips() -> Array                # 지워도 되는 것: 항목마다 처음·최근이 아닌 녹음
static func delete_clip(id: String) -> bool ; static func delete_all() -> int ; static func used_bytes() -> int
static func usage_text() -> String
static func to_16k_mono(wav: PackedByteArray) -> PackedByteArray   # 16 kHz 초과면 줄이고(평균), 이하면 그대로. MAX_CLIP_SEC 에서 자름
```
  - `index.json` = `{"v":1,"enabled":true,"consent_at":"2027-01-05","clips":[{"id":"vc_20270105_ref1_a1b2","kind":"ref","item":"ref1","date":"2027-01-05","sec":4.2,"bytes":134444,"score":-1,"file":"vc_20270105_ref1_a1b2.wav"}]}`. 파일 이름 `^vc_[0-9]{8}_[a-z0-9_]{1,16}_[0-9a-f]{4}\.wav$`. `used_bytes` 는 **실제 파일 크기 합 + index**.
  - **꺼져 있으면(기본) 폴더·파일을 만들지 않는다(0바이트)**. 저장 전 `used + 새 크기 > MAX_BYTES` 면 저장하지 않고 `full`(+`need_bytes`). 처음 녹음은 자동으로 지우지 않는다(자동 삭제 없음).
  - 동기화·`Store.prefs`·`progress.json`·`studylog.json`·로그에 녹음·경로 0. "모든 기록 지우기"는 이 폴더를 건드리지 않는다(D2 A).
- **`VoiceCompareView`**(새, `ui/voice_compare_view.gd`, `static func open(host: Node) -> Node`):
  - 꺼짐: `CONSENT_TEXT` + [켜기](`VcEnable`) / [닫기]. 켜기 → `enable()`.
  - 켜짐: 사용량 줄(`usage_text`), 기준 문장 5개 카드(영어·한국어 = `CourseData.sentence(id)`, [녹음](RecorderWidget, `VcRec_ref1`…), [처음 듣기](`VcFirst_<item>`)·[최근 듣기](`VcLatest_<item>`) + 날짜·점수(있으면)), 월말 녹음 카드(같은 문항끼리 처음·최근), 녹음마다 [지우기], [녹음 모두 지우기](`VcDeleteAll` → 확인 시트 `"내 녹음 N개를 모두 지울까요? 되돌릴 수 없어요."`), [끄기](`VcDisable` → `"새 녹음 저장을 멈출까요? 지금까지 녹음은 남아요."`).
  - `full` 이면 시트 `"공간이 부족해요(20MB). 중간 녹음 N개를 지우면 저장할 수 있어요."` [중간 녹음 정리](`middle_clips` 를 오래된 것부터 필요한 만큼 지우고 저장) / [저장 안 함].
  - 재생은 `AudioStreamPlayer` + `WavUtil.from_wav_bytes`. 파형·편집·공유·내보내기 없음.
- **월말 연결**(`practice/course_exercise_view.gd`): 단위 종류가 `month` 이고 `VoiceCompareStore.enabled()` 이면 말하기 채점이 끝난 순간(`_on_drill_scored`) `drill._last_audio`(b64)를 바이트로 바꿔 `save_clip("month", "m%02d_%s" % [월, 문항 id], wav, 점수)`. 꺼져 있으면 아무것도 안 함(점수·전사만, 지금 그대로). `full` 이면 토스트 `"녹음 공간이 부족해 이번 녹음은 저장하지 않았어요"`(시트 없음, 흐름을 막지 않음). `speak_drill.gd` 는 고치지 않는다(읽기만).

### 2.10 RP — 오류 신고 (4파, G1)
- **`CourseReports`**(새, `core/course_reports.gd`): 파일 `user://course_reports.json`.
```json
{"v":1,"reports":[{"id":"r20270105_ab12","t":"2027-01-05","kind":"sentence","item":"s1234","w":21,"d":2,"reason":"ko_wrong","note":""}]}
```
```
const MAX := 200 ; const NOTE_MAX := 100
const KINDS := ["word", "sentence", "pattern", "dialogue", "story", "ai_reply", "other"]
const REASONS := {"en_wrong": "영어가 틀려요", "ko_wrong": "뜻이 틀려요", "sound_wrong": "소리가 이상해요", "too_hard": "너무 어려워요", "other": "기타"}
static func add(kind, item, w, d, reason, note := "") -> Dictionary   # {ok, err: ""|"full"|"bad"|"io", id}
static func list() -> Array ; static func count() -> int ; static func clear() -> bool
static func copy_text() -> String   # 첫 줄 "hoehwa course reports v1", 그 뒤 "id\tt\tkind\titem\tw\td\treason\tnote"
```
  - `ai_reply` 는 **AI 글을 저장하지 않는다**(`item` = 시나리오 id 또는 장면 id). `note` 는 사용자가 쓴 선택 글(줄바꿈·탭 제거, 100자).
  - 가득 차면 저장 거절 + `"신고 기록이 가득 찼어요. 설정에서 복사한 뒤 지워 주세요."`.
- **`ReportSheet`**(새, `ui/report_sheet.gd`, `static func open(host, kind, item, w, d) -> Node`): 이유 라디오 5개(`ReportReason_<key>`), 메모 칸(`ReportNote`), [저장](`ReportSave`) → `"이 기기에 저장했어요. 설정 > 코스 기록에서 복사할 수 있어요."`, [취소].
- **플레이어**(`course_player.gd`): 머리 줄에 [신고](`CourseReportBtn`) → 지금 문제의 `_item_of(ex)` 와 종류(문제 type → kind 대응: `teach_word/recognize/recall` → word, `teach_pattern` → pattern, `build/listen/speak` → sentence, `dialogue_script` → dialogue). 문제 진행·채점·기록에 영향 0.

### 2.11 CU — 따라잡기 U8~U10 (4파, G1·G2(RD))
- `DayPlan.today(s)` 새 스냅샷 키(모두 선택, **없으면 지금과 완전히 같은 결과**):
  - `rest_days`(정수, 코스 시작일 이후 2.0.2 쉬는 날 수), `avail`(정수, 데이터가 있는 주 수), `avail_done`(bool, `avail` 주까지 다 끝냄), `cells_today`(정수, 오늘 끝낸 새 칸 수).
- 규칙(이 순서):
  - **U8 쉬는 날 반영 늦음**: `late_weeks = max(expected_week(max(elapsed_days - rest_days, 0)) - w, 0)`.
  - **U9 업데이트 대기**: `avail > 0` 이고 `w >= avail` 이고 `avail_done` → `late_weeks = 0`, 새 결과 키 `waiting_update = true`. 홈 안내 `"다음 단계는 업데이트에서 이어져요. 그동안 복습과 이야기 회화를 해요."`(늦음 안내 대신).
  - **U10 하루 1칸 더**: 블록이 모두 끝났고 `late_weeks >= 1` 이고 `cells_today < 2` 이고 다음 칸 종류가 `new` 또는 `speak` 면 새 결과 키 `extra = {"w","d","min":15,"title":"밀린 칸 하나 더"}`, 아니면 `{}`. 홈(`today_view`)이 그 버튼(`TodayExtraCell`)을 보이고 누르면 `CoursePlayer.open(host, {"kind": <칸 종류>, "w", "d", "block": "new"})`.
  - U3(7일 이상 쉬면 복귀 점검)은 쉬는 날과 무관하게 **그대로**(쉬는 날도 공부 안 한 날).
- `CourseStore`: 일 기록 키 `cells`(오늘 끝낸 칸 수, 0~7)를 `_complete_cell` 이 1 올린다(`DAY_KEYS` 에 더함, 옛 파일 호환). 새 `static func cells_today() -> int`.
- `HomeParts.snapshot`: 위 네 키를 채운다(`rest_days` = `StudyLog.rest_days("en")` 중 `CourseStore.started()` 이후 개수, `avail` = `CourseData.available_weeks()`, `avail_done` = `CourseModel.states(...).avail_done`). `HomeModel._norm` 은 새 키를 범위 검사해 통과(이상하면 없는 것으로).

### 2.12 P1 — 쉐도잉·받아쓰기 코스 문장 (4파, G1)
- **`CoursePractice`**(새, `core/course_practice.gd`, 정적, 순수):
```
const RECENT_SHARE := 0.6   # 이번 주·지난주 문장 비율
static func pick(mode: String, w: int, d: int, n: int, seed: int, exclude: Array, data: Dictionary = {}) -> Array
    # -> [{"id": "s1234", "text": en, "ko", "say", "tts": say 가 있으면 say 아니면 en}]
```
  - 후보: `CourseData` 문장 중 `o <= w*10+d`. `shadow` = scope `all|listen`, `dictation` = scope `all` + 토큰 3~8개 + `say` 빈 것만. `exclude` 의 id 제외(모자라면 제외 무시). 이번 주·지난주에서 `ceil(n*0.6)`, 나머지는 더 앞 주, 시드 고정 결정적. 후보 0 이면 `[]`.
- `shadow_screen.gd`·`dictation_screen.gd`: **코스 모드 영어에서만** `start_session("week")`/`_load()` 가 요청을 보내지 않고 `CoursePractice.pick` 결과로 바로 시작(`attribution ""`, Tatoeba 문장이면 기존 출처 문구). 코스 문장 id 는 문자열이라 별도 목록 `course_seen`(최근 100)에 둔다. 소리는 `tts` 글, 채점·받아쓰기 비교는 `text`. 후보 0 → `"아직 연습할 코스 문장이 없어요. 레슨을 조금 더 하고 와요."`. 이 두 화면에서 `MissionScreen.course_notice` 부르기를 뺀다. 코스 모드가 아닌 영어·일본어는 요청·쿼리·화면 **변화 0**.
- `course_stage_wiring_test.gd`: E7-9 의 쉐도잉·받아쓰기 단언(시작·진행·받아쓰기 페이지의 `expect`)만 "코스 모드에서 안내 없음" 으로 바꾸고, 코스 모드에서 `/practice/sentences` 요청 0건·코스 문장으로 시작 단언을 더한다. 대화·미션 안내 단언과 그 밖 줄 변경 0. (선택 항목: 이 파일이 `--font-scale`·`--dark` 인자를 무시하던 E7 사소 문제를 같은 작업에서 고친다 — 단언 삭제 없이.)

### 2.13 PI-L — 폰 수준 맞춤 대화 이식 (5파, G1·G2(PI2b), S1·KBR 병합 뒤)
- **`CourseLevels`**(새, `core/course_levels.gd`, 정적): `static func derive(data: Dictionary) -> Dictionary`(`CourseFeed.plain_data()` 의 낱말·주 레코드로 §2.7.1 과 **같은 모양** 생성, D8 A), `static func current() -> Dictionary`(처음 부를 때 한 번 만들어 보관, 코스 데이터가 없으면 `{}`), `static var override: Dictionary`(시험·황금), `static func reset()`.
- **`AiChatRules`**(`local/ai_chat_rules.gd`, PI2b 파일에 **더하기만**): §2.6.3 의 `limits`·`level_check`·`course_prompt`·`retry_note`·`pick_fallback`·`clean_memory`·`story_prompt`·`summary_messages`·`help_messages` 와 상수를 같은 이름(`snake_case`)의 정적 함수·상수로 옮기고, `run_chat(req, engine)` 이 `course`·`help_ko`·`story` 를 서버와 같은 순서로 처리한다. 시간 조건은 `static var now_hook: Callable`(기본 `Time.get_ticks_msec()/1000.0`). 토큰화는 `LexiconGuard.tokens`(S8)를 쓰고, 대소문자 원형이 필요한 고유명사 판정만 같은 경계로 원문에서 다시 자른다(황금으로 같음 확인).
- **2.0.2 약속**: `AiChatRules` 의 기존 공개 함수 `rules_text`·`context_text`·`clean_hist`·`ko_ok`·`scrub_ko`·`looks_like_question`·`norm_text`·`run_chat`·`fix` 의 이름·인자 그대로, `LocalAi`·`AiClient`·`AiState` 변경 0.
- **황금**: `make_ai_golden.py` 에 종류 `course_chat`(run_chat 의 코스·도움·이야기 대화·요약, 엔진 기록 포함, ≥ 60사례)·`course_level`(순수 `level_check`, ≥ 60)·`course_mem`(순수 `clean_memory`, ≥ 30)·`course_prompt`(순수, ≥ 16)를 더하고 출력 `course_chat.json`·`course_pure.json`. 수준표는 고정 픽스처 `phone_src/tools/course_levels_golden.json`(17~18주 가상 미니, 실제 원고와 무관 — 원고를 고쳐도 황금이 안 바뀜)을 서버 `course_level.set_levels` 와 폰 `CourseLevels.override` 에 같은 내용으로 넣는다. **기존 황금 11개 파일은 바이트 불변**(S1 이 옛 경로를 안 바꾼 증거).
- 사례에 반드시 포함: 수준 통과 1회, OOV 1회 재요청 뒤 통과, 길이 초과, 문장 수 초과, 같은 낱말을 고집해 안전 대사, 시간 조건으로 2번째에서 멈춤, 형식 오류 + 수준 실패 섞임, 엔진 한도 오류(재요청 0), `course` 범위 밖(무시 = 기존 결과), `simplify`, `suggest` 거르기·채우기, 도움 성공·실패·120자 초과·`course` 없음, 이야기 기억 0·8줄·500자 초과·화이트리스트 밖 줄·개인정보 정규식 줄, 요약 enum 밖 값, 모르는 장면 id.

### 2.14 W1 — 화면 연결 (5파, G1·G2(PSI·PWI), ST·B1·RP·M2·P1·S1 병합 뒤)
- **대화(`talk_view.gd`)**: 코스 모드 영어면 요청에 `course = CourseChat.course_field("guided" | 33주~ "free")`. 응답에 `level` 이 있으면 AI 줄을 `RichTextLabel` + `underline_bbcode`(밑줄 낱말 누르면 뜻), `ChatHelpBar` 를 입력칸 위에(15초 단계 + 직접 누르기, 3단계는 `help_ko` 요청 → [이 문장 쓰기] 가 입력칸에 넣음). AI 줄마다 작은 [이상해요](`TalkReport`) → `ReportSheet(kind "ai_reply", item = 시나리오 id)`. 안내 문구 `MissionScreen.COURSE_NOTICE` 는 W1 이 `"코스에서 아직 배우지 않은 단어는 밑줄로 보여 줘요. 눌러서 뜻을 볼 수 있어요."` 로 바꾼다(부분 문자열 `"아직 배우지 않은"` 유지 → `course_stage_wiring_test` 수정 0). `level` 이 없는 응답(옛 서버·PI-L 없는 폰)은 밑줄 없이 지금처럼.
- **미션(`mission_screen.gd`)**: 목록·안내는 `MissionLogic.sort_for`/`fits`(`min_week` 없는 미션은 지금 `min_stage` 규칙 그대로 → 주 5 가짜 4개 단언 불변), 카드 메타에 `min_week` 가 있으면 `"%d주차부터"`. AI 모드이고 코스 주 ≥ 25 면 `course = course_field("mission")`, 밑줄·도움 막대·[이상해요] 동일.
- **설정(`settings_view.gd`)**: 새 묶음 `CourseRecordSection`(제목 "코스 기록", 코스 데이터가 있을 때만): [내 녹음 비교](`VoiceCompareView.open`), [이야기 기억](`StoryView.open_memory`), "신고 기록 N개" + [복사](`ReportsCopy` → 클립보드 `CourseReports.copy_text()`) + [지우기](확인 시트). "모든 기록 지우기" 확인 글 = `SyncPanel.reset_confirm_text() + "\n\n" + RESET_KEEP_NOTE`, `RESET_KEEP_NOTE := "내 녹음 비교의 녹음, 이야기 기억, 신고 기록은 지워지지 않아요. 각 화면에서 따로 지울 수 있어요."`(sync 폴더 수정 0).
- **연습 허브(`practice_view.gd`)**: 코스 모드 영어에서 행 [이야기 회화](`StoryView.open`, 17주 전이면 "17주차부터" 부드러운 잠금)·[내 녹음 비교].
- 기존 시험: `mission_test`·`settings_view_test` 는 줄 **추가만**(새 행 때문에 깨지는 구조 단언이 있으면 고치지 말고 오케스트레이터에게 보고), 삭제 0.

### 2.15 BG — 코스 배지 (선택, 5파, G2(RD))
- 배지 4개(추천): `course_s1`(1~16주 완주), `course_s2`(17~32주 완주), `month_pass_4`(월말 평가 통과 4회), `story_s1`(시즌 1 16장면 완료). `badge_defs.gd` 에 정의, `badge_engine.gd` 에 계산(코스·이야기 저장소 읽기만).
- 기존 "25개" 단언을 **29 로 바꾸는 것만** 허용(`badge_engine_test` 3곳, 그 밖 파일에서 깨지면 보고). 시작 기준: 5파가 2027-01-14 까지 시작될 때만(§8 D-10).

### 2.16 FXR — 사소 잔여 (선택, 4파)
- 코스 홈 블록 머리글이 폰 1.5배 글자에서 낱말 중간에 줄이 바뀌는 문제(WORKLOG 2.0.0 사소): `course_home.gd` 의 머리글 `Label` 에 `autowrap_mode = AUTOWRAP_WORD_SMART`·최소 높이. 다른 줄 변경 0. 시험은 `course_home_test.gd` 에 단언을 **추가만**.

### 2.17 ZR — 문서 (6파)
- `README.md`: 17~32주(생활 말하기), 수준 맞춤 AI(밑줄·도움 3단계·안전 대사, PC·폰), 이야기 회화 시즌 1(기억은 가상 사건 몇 줄, 업체로 함께 전송, 보기·지우기), 내 녹음 비교(기본 꺼짐, 이 기기만, 20MB, 따로 지우기), 쉐도잉·받아쓰기 코스 문장, 미션 열림 주, 신고 기록, 따라잡기(쉬는 날 반영·하루 1칸 더), **"17~32주 원고는 AI 검수만(독립 AI 검수 + Gemini 4 Hydrogen 표본 300, 사람 검수 없음)"**, 실측 준수율 숫자(T-8).
- `ROADMAP.md`: 2.1.0 완료·알려진 한계(실기 미검증, 폰 파생 시간, 준수율), 2.1.1 로 미룬 것. `INSTALL.md`: 녹음 비교·이야기 기억·신고 기록 위치와 지우는 법.

---

## 3. 소유권 OWN 블록과 파 순서

### 3.1 파 순서와 병렬
```
0~1파(완료·오케스트레이터): 기획 확정 → 이 문서 확정·커밋 → §8 결정
2파(지금, 2.0.2 와 병렬):  K1R ∥ K0R(초안) → K0R 확정(K1R 병합 뒤) → A5 → X3a      ∥  SP
   ── 점검 P2: A5 린터 0·X3a 심은 오류 ≥ 9/10·잔여 C 0·작성 소요, SP 숫자 → 오케스트레이터가 [SP 뒤 확정] 상수와 A6~A8 지시 보완
3파:  A6 ∥ A7 ∥ A8 ∥ M2(작성·검토, 병합은 4파)  →  X3b  →  HS(표본 300 + 심은 오류 10)
── 관문 G1: 2.0.2 공개 또는 release/2.0.2 가지 생성
4파:  S1 ∥ ST ∥ B1 ∥ RP ∥ P1 ∥ FXR(선택)  ∥  CU(RD 병합 뒤)  ∥  M2 병합(PI2c 병합 뒤)  ∥  KBR(HS C 0 뒤)
── 절단 점검(2027-01-14 쯤 = 상한 4주 전): 늦으면 기획 §2.2 순서로 2.1.1 분리
5파:  PI-L(S1·KBR·PI2b 뒤) ∥ W1(ST·B1·RP·M2·P1·S1 뒤) ∥ BG(선택)
6파:  ZR → 버전 2.1.0(versionCode 20100) → 통합 시험 T(§6) → 시험 APK → ★실기 → 공개
```
| 작업 | 선행(병합) | 함께 해도 됨 | 위험도·검토 |
|---|---|---|---|
| K1R | - | K0R 초안, SP | 높음(검사기): Sol + 오케스트레이터 재실행(K1R-3·K1R-4·K1R-6) |
| K0R | K1R | SP | 보통: Sol 1회 |
| A5 / A6·A7·A8 | K0R / P2 | 서로, M2 작성 | 높음(콘텐츠): Sol(형식) + X3 + HS, 오케스트레이터 재실행(A-1·A-8) |
| SP | - | 2파 전부 | 낮음(저장소 0): 오케스트레이터 확인 |
| X3a / X3b | A5 / A6~A8 | - | 독립 판정(심은 오류) |
| HS | X3b C 0 | - | Hydrogen + 오케스트레이터 집계 |
| M2 | K0R(어휘), A6~A8(어휘 확인), PI2c | 4파 전부 | 보통: Sol 1회 + 독립 문장 시험 |
| S1 | K1R(형식) | 4파 전부 | 높음(AI·요금·개인정보): Sol + 재실행(S1-1·S1-2·S1-5) |
| KBR | A5~A8, X3a/b, HS, K1R | 4파 전부 | 높음(출시 데이터): Sol + 재실행(KBR-2·KBR-4·KBR-5) |
| ST | - | 4파 전부 | 높음(개인정보 전송): Sol + 재실행(ST-3·ST-4) |
| B1 | - | 4파 전부 | 높음(녹음): Sol + 재실행(B1-2·B1-3·B1-5) |
| RP | - | 4파 전부 | 보통: Sol 1회 |
| CU | RD | 4파 전부 | 보통: Sol 1회 |
| P1 | - | 4파 전부 | 보통: Sol 1회 |
| FXR | - | 4파 전부 | 낮음: Sol 1회 |
| PI-L | S1, KBR, PI2b | W1, BG | 높음: Sol + 재실행(PIL-2·PIL-3·PIL-5) |
| W1 | ST, B1, RP, M2, P1, S1, PSI, PWI | PI-L, BG | 높음(화면 통합·개인정보 문구): Sol + 재실행(W1-2·W1-4) |
| BG | RD | PI-L, W1 | 보통 |
| ZR | 5파 전부 | - | 낮음: 오케스트레이터 확인 |

### 3.2 OWN 블록 (기준: 이 블록. 줄 형식 `작업 종류 경로 [after=작업]`, v201·v202 와 같은 형식)
- **파일마다 이 문서 안의 소유자는 하나뿐이다**(같은 파일을 두 작업이 가지면 기존 검사기 규칙 ①·② 를 동시에 만족할 수 없다 — `course_stage_wiring_test.gd` 는 P1 만 갖고, W1 은 안내 부분 문자열을 지켜 그 파일을 고치지 않는다).
- `after=` 는 §3.3 결합 기준에서 그 파일의 마지막 소유자: `K1`·`K0`·`KB`·`E3`·`E4a`·`E6`·`E7` = v200, `PI2a`·`PWA` = v200 폰·v201, `F1`·`F3` = v201, `PI2b`·`PI2c`·`PSI`·`PWI`·`RD`·`PZ` = v202. `course_src/tools/` 와 `godot/data/course/` 는 v200 의 `newdir`(K1·KB)이라 그 안 파일은 `after=K1`/`after=KB`.
- 새 `.gd` 의 `.uid` 짝은 그 작업 소유(줄에 적지 않음). `K1R newdir course_src/tools/fixtures/r2/`, `ST newdir godot/tests/fixtures/story_mini/` 는 그 폴더 아래 새 파일 전부.
- 읽기만: `route.gd`·`api.gd`·`local_api.gd`·`store.gd`·`backend.gd`·`tts.gd`(autoload 전부), `local_ai.gd`·`ai_client.gd`·`ai_secrets.gd`·`ai_presets.gd`·`ai_state.gd`, `speak_drill.gd`, `recorder.gd`·`recorder_widget.gd`, `wav_util.gd`, `lexicon_guard.gd`·`lesson_builder.gd`·`course_feed.gd`·`course_data.gd`·`course_model.gd`, `study_log.gd`, `sync/*`, `progress.gd`, `diary_store.gd`, `backend/llm_*.py`, `phone_src/tools/fake_ai_server.py`.
- 수정 금지(어느 작업도 소유하지 않음): `godot/project.godot`, `godot/export_presets.cfg`(버전은 오케스트레이터), `godot/scripts/autoload/*`, `godot/scripts/sync/*`, `native/*`, `packaging/*`, `backend/lan.py`·`sync_hub.py`·`llm_*.py`·`secrets.json`·`config.json`, `godot/data/pack/*` 중 M2 줄 밖, `godot/data/curriculum.json`·`backend/curriculum.json`, `course_src/en/weeks/w001~w016.json`, `course_src/review/R1_*`, 일본어 파일 전부, 2.0.2 의 PI1·PI3 파일, 위 표에 없는 기존 시험.

<!-- OWN-BEGIN -->
K1R mod course_src/tools/check_course.py after=K1
K1R mod course_src/tools/course_common.py after=K1
K1R mod course_src/tools/forms_en.py after=K1
K1R mod course_src/tools/build_course.py after=K1
K1R mod course_src/tools/sample_sheet.py after=K1
K1R mod course_src/tools/make_fixtures.py after=K1
K1R mod course_src/tools/README.txt after=K1
K1R new course_src/tools/test_r2_tools.py after=K1
K1R newdir course_src/tools/fixtures/r2/
K0R mod course_src/en/skeleton.json after=K0
K0R mod course_src/en/policy.json after=K0
A5 new course_src/en/weeks/w017.json
A5 new course_src/en/weeks/w018.json
A5 new course_src/en/weeks/w019.json
A5 new course_src/en/weeks/w020.json
A6 new course_src/en/weeks/w021.json
A6 new course_src/en/weeks/w022.json
A6 new course_src/en/weeks/w023.json
A6 new course_src/en/weeks/w024.json
A7 new course_src/en/weeks/w025.json
A7 new course_src/en/weeks/w026.json
A7 new course_src/en/weeks/w027.json
A7 new course_src/en/weeks/w028.json
A8 new course_src/en/weeks/w029.json
A8 new course_src/en/weeks/w030.json
A8 new course_src/en/weeks/w031.json
A8 new course_src/en/weeks/w032.json
X3a new course_src/review/R2_X3a.tsv
X3b new course_src/review/R2_X3b.tsv
HS new course_src/review/R2_H300.tsv
S1 new backend/course_level.py
S1 mod backend/server.py
S1 new backend/test_course_chat.py
M2 mod backend/content/missions.json
M2 mod backend/missions.py
M2 mod backend/test_missions.py
M2 mod godot/data/pack/missions.json
M2 mod godot/data/pack/manifest.json
M2 mod godot/scripts/local/local_missions.gd
M2 mod godot/scripts/core/mission_logic.gd
M2 mod godot/tests/local_missions_test.gd
M2 mod godot/tests/ai_feedback_parity_test.gd after=PI2c
KBR mod godot/data/course/course_manifest.json after=KB
KBR mod godot/data/course/en_weeks.json after=KB
KBR mod godot/data/course/en_lexicon.json after=KB
KBR mod godot/data/course/en_patterns.json after=KB
KBR mod godot/data/course/en_sentences.json after=KB
KBR mod godot/data/course/en_dialogues.json after=KB
KBR mod godot/data/course/en_speak_prompts.json after=KB
KBR new backend/content/course_levels.json
KBR mod godot/tests/course_data_real_test.gd after=KB
KBR mod godot/tests/course_guard_all_test.gd after=KB
ST new godot/scripts/core/story_store.gd
ST new godot/scripts/core/course_chat.gd
ST new godot/scripts/ui/chat_help_bar.gd
ST new godot/scripts/views/story_view.gd
ST new godot/tests/story_store_test.gd
ST new godot/tests/story_store_test.tscn
ST new godot/tests/course_chat_test.gd
ST new godot/tests/course_chat_test.tscn
ST new godot/tests/story_view_test.gd
ST new godot/tests/story_view_test.tscn
ST newdir godot/tests/fixtures/story_mini/
B1 new godot/scripts/core/voice_compare_store.gd
B1 new godot/scripts/ui/voice_compare_view.gd
B1 mod godot/scripts/practice/course_exercise_view.gd after=E4a
B1 new godot/tests/voice_compare_test.gd
B1 new godot/tests/voice_compare_test.tscn
B1 new godot/tests/voice_compare_view_test.gd
B1 new godot/tests/voice_compare_view_test.tscn
RP new godot/scripts/core/course_reports.gd
RP new godot/scripts/ui/report_sheet.gd
RP mod godot/scripts/practice/course_player.gd after=F3
RP mod godot/tests/course_flow_test.gd after=F3
RP new godot/tests/course_reports_test.gd
RP new godot/tests/course_reports_test.tscn
P1 new godot/scripts/core/course_practice.gd
P1 mod godot/scripts/practice/shadow_screen.gd after=PWA
P1 mod godot/scripts/practice/dictation_screen.gd after=E7
P1 mod godot/tests/course_stage_wiring_test.gd after=E7
P1 new godot/tests/course_practice_test.gd
P1 new godot/tests/course_practice_test.tscn
CU mod godot/scripts/core/day_plan.gd after=E3
CU mod godot/scripts/core/course_store.gd after=E3
CU mod godot/scripts/core/home_model.gd after=E6
CU mod godot/scripts/ui/home_parts.gd after=RD
CU mod godot/scripts/views/today_view.gd after=E6
CU new godot/tests/catch_up_test.gd
CU new godot/tests/catch_up_test.tscn
PI-L new godot/scripts/core/course_levels.gd
PI-L mod godot/scripts/local/ai_chat_rules.gd after=PI2b
PI-L mod phone_src/tools/make_ai_golden.py after=PI2a
PI-L mod phone_src/tools/ai_golden_cases.json after=PI2a
PI-L mod phone_src/tools/test_make_ai_golden.py after=PI2a
PI-L new phone_src/tools/course_levels_golden.json
PI-L new godot/tests/fixtures/ai_golden/course_chat.json after=PI2a
PI-L new godot/tests/fixtures/ai_golden/course_pure.json after=PI2a
PI-L new godot/tests/ai_course_parity_test.gd
PI-L new godot/tests/ai_course_parity_test.tscn
PI-L new godot/tests/course_levels_test.gd
PI-L new godot/tests/course_levels_test.tscn
W1 mod godot/scripts/views/talk_view.gd after=E7
W1 mod godot/scripts/practice/mission_screen.gd after=PWI
W1 mod godot/scripts/views/settings_view.gd after=PSI
W1 mod godot/scripts/views/practice_view.gd
W1 mod godot/tests/mission_test.gd after=PWI
W1 mod godot/tests/settings_view_test.gd after=PSI
W1 new godot/tests/course_ai_wiring_test.gd
W1 new godot/tests/course_ai_wiring_test.tscn
BG mod godot/scripts/core/badge_defs.gd
BG mod godot/scripts/core/badge_engine.gd
BG mod godot/tests/badge_engine_test.gd after=RD
BG new godot/tests/course_badge_test.gd
BG new godot/tests/course_badge_test.tscn
FXR mod godot/scripts/views/course_home.gd after=F1
FXR mod godot/tests/course_home_test.gd after=E5
ZR mod README.md after=PZ
ZR mod ROADMAP.md after=PZ
ZR mod INSTALL.md after=PZ
<!-- OWN-END -->

### 3.3 소유권 검사 (합치기 전에 오케스트레이터·검토자가 돌린다. 검사기는 고치지 않는다)
- 검사기: `<scratch>\w_v201design\own_check_v201.py`(인자 `doc base [only]`, 규칙 ①~④, 마지막 줄 `files N dirs D tasks T ordered O OK|FAIL`) **그대로**. 기준 파일은 v202 §3.3 처럼 **네 문서의 OWN 줄을 순서대로 합친 임시 파일**: `v200_design` → `v200_phone_design`(v202 가 이어받은 `PI1 PI2b PI2c PI3 PSI PWI PZ` 줄 제외) → `v201_design`(**`F2` 의 `godot/data/course/` 줄 5개 제외**) → `v202_design`.
  - F2 줄을 빼는 이유: 그 파일들은 v200 KB 의 `newdir godot/data/course/` 안에 있어 검사기 규칙 ②가 `after=KB`(폴더 규칙)와 `after=F2`(파일 규칙)를 동시에 요구한다 → 어떤 줄로도 통과할 수 없다(설계자가 실제로 확인: 빼지 않은 기준에서 KBR 5줄 `FAIL overlaps base task F2`). F2 는 KB 폴더 안의 재빌드였으므로 폴더 주인 KB 를 기준으로 삼는다.
- 기준 파일 생성기(작성 때 설계자가 만든 것과 같은 내용, `<scratch>\w_v210design\own_base_v210.py` 에도 있음):
```powershell
# 저장소 루트(또는 검토 worktree 루트)에서. $T 는 자기 임시 폴더. 기준 파일은 커밋하지 않는다.
@'
import sys
def rows(doc, skip_tasks=(), skip_fn=None):
    blk = open(doc, encoding="utf-8").read().split("<!-- OWN-BEGIN -->")[1].split("<!-- OWN-END -->")[0]
    out = []
    for ln in blk.splitlines():
        ln = ln.strip()
        if not ln:
            continue
        p = ln.split()
        if p[0] in skip_tasks or (skip_fn and skip_fn(p)):
            continue
        out.append(ln)
    return out
r = rows("docs/v200_design.md")
r += rows("docs/v200_phone_design.md", ("PI1", "PI2b", "PI2c", "PI3", "PSI", "PWI", "PZ"))
r += rows("docs/v201_design.md", (), lambda p: p[0] == "F2" and p[2].startswith("godot/data/course/"))
r += rows("docs/v202_design.md")
open(sys.argv[1], "w", encoding="utf-8", newline="\n").write("<!-- OWN-BEGIN -->\n" + "\n".join(r) + "\n<!-- OWN-END -->\n")
print("OWN_BASE rows=%d" % len(r))
'@ | Set-Content -Encoding ascii "$T\own_base_v210.py"
& $PY -X utf8 "$T\own_base_v210.py" "$T\own_base_v210.md"
& $PY -X utf8 "$S\w_v201design\own_check_v201.py" docs/v210_design.md "$T\own_base_v210.md" <only>
```
- `<only>`(파일 존재 검사 대상): 그 파에서 아직 병합되지 않은 작업만. 이미 병합된 작업의 `new` 줄은 "이미 있음"으로 FAIL 하므로 넣지 않는다. 겹침·`after=` 규칙(①·②)은 `only` 와 무관하게 **전 줄**을 본다.
- **기대 출력(main `2d42a4a`, 2.0.2 미병합)**: `OWN_BASE rows=289`. `only` = `K1R,K0R,A5,A6,A7,A8,X3a,X3b,HS,S1,KBR,ST,B1,RP,P1,CU,W1,BG,FXR,ZR`(2.0.2 가 만들 파일을 고치는 M2·PI-L 제외) → 마지막 줄 **`files 117 dirs 2 tasks 22 ordered 48 OK`**, 종료 0. `only` 없이 돌리면 `FAIL missing existing file: godot/tests/ai_feedback_parity_test.gd`·`godot/scripts/local/ai_chat_rules.gd` 두 줄(2.0.2 가 만들 파일이라 정상, 2.0.2 병합 뒤 사라짐). 설계자가 작성 직후 직접 돌려 이 출력을 확인했고, 일부러 틀린 복사본 5종에서 각각 `FAIL` 과 종료 1 을 확인했다: ① CU `home_parts.gd` 의 `after=RD` 삭제 → `FAIL overlaps base task RD without matching after=` ② W1 이 CU 소유 `day_plan.gd` 를 `after=E3` 로 더 가짐 → `FAIL overlap without after=: ... ['CU'] -> W1` ③ 없는 `course_player_nope.gd` 를 `mod` → `FAIL missing existing file` ④ 이미 있는 `course_feed.gd` 를 `new` → `FAIL new file already exists`(+ 기준 E3 겹침) ⑤ F2 줄을 빼지 않은 기준 → KBR 5줄 `FAIL overlaps base task F2`.

---

## 4. 원고 검수 절차(D3 A)와 사용자 실기

### 4.1 원고 검수 절차 (사람 검수 없음)
1. **린터**(작성자·KBR): `check_course.py --in course_src/en --weeks <a>-<b> --strict` 위반 0, `--grammar` 결과 기록(LanguageTool 이 없으면 `GRAMMAR_SKIPPED` → "미검증").
2. **독립 AI 검수 X3a(17~20)·X3b(21~32)**: 작성자와 **다른** `worker-hard` 새 세션, 원고만 읽고(작성자 보고서 안 봄) `course_src/review/R2_X3?.tsv`(열 `id type verdict issue fix`)에 **전 항목**(낱말·문형 설명·문장·대화 줄·`story_line`·`story_mem`·`story_text`·`fallback`)을 `OK/M/C` 로. 판정 기준 v200 §9.4 등급(C = 영어·한국어 뜻·숫자 읽기·캐나다 표기·사실 틀림, M = 어색·수준 부적합, m = 오탈자).
   - **심은 오류 시험**: 오케스트레이터가 `<scratch>\w_orch_v210\x3_plant\` 의 원고 복사본에 4주당 10개(영어 문법 2·한국어 뜻 2·숫자 `say` 1·캐나다 철자 1·활용형 1·수준 밖 낱말 1·이야기 기억 문장의 개인정보형 숫자 1·안전 대사의 수동 낱말 1)를 심어 X3 에게 따로 검수시킨다 → **9개 이상** C/M 으로 잡아야 합격(X3a 1회, X3b 는 3묶음 각각). 복사본은 커밋하지 않는다.
   - C 가 있으면 작성자에게 되돌려 **같은 종류를 전체에서** 고치고 재검수 → 잔여 C 0.
3. **한국어·뜻 표본 HS(Gemini 4 Hydrogen)**: 오케스트레이터가 `sample_sheet.py --in course_src/en --weeks 17-32 --n 300 --seed 210 --out <scratch>\w_orch_v210\hs\sheet.csv`(층 낱말 90·문장 120·대화 줄 50(이야기·안전 대사 포함)·문법 설명 40) → 같은 시트 사본에 **심은 오류 10개**(한국어 뜻 4·어색한 한국어 2·영어 문법 2·숫자 읽기 1·캐나다 철자 1, 위치는 오케스트레이터만 앎)를 섞은 310행을 Hydrogen 에 준다(Orca, 지시: 행마다 `OK/M/C` + 이유, 원고 수정 금지).
   - 합격: 심은 오류 **≥ 9/10** 적발(아니면 Hydrogen 결과를 믿지 않고 지시를 고쳐 다시), 진짜 300행에서 **C 0, M ≤ 3**. C ≥ 1 이면 같은 종류 전수 수정 후 **새 시드(211)** 300개 재검수. 두 번째도 불합격이면 접근 재검토(오케스트레이터).
   - 결과 `course_src/review/R2_H300.tsv`(열 `id type verdict issue`, 300행, 심은 행 제외)를 오케스트레이터가 커밋. 릴리스 노트·README: "사람 검수 없음, AI 검수(Gemini 4 Hydrogen)로 대신함".
4. **출시 뒤**: 오류 신고(RP)로 모은다. 사용자가 원하면 표본 일부를 직접 확인할 수 있으나 필수 아님.

### 4.2 ★실기(갤럭시 S24, 6파 T 통과 뒤, 약 35~45분)
- 시험 APK 는 정식 키 서명(versionCode 20100), 2.0.2 APK 위 덮어쓰기. 실기를 통과한 같은 APK 를 공개.

| ID | 무엇을 | 사용자 행동 | O 기준 | 근거 |
|---|---|---|---|---|
| H14 | 덮어쓰기 보존 | 2.0.2 위 설치 → 홈·코스 홈·복습·설정 AI 연결 | 진도·카드·음성 모델·AI 키 유실 0, 17주 "준비 중" 이 사라짐 | 사진 |
| H15 | 17주 레슨 | 16주를 마친 상태(또는 [점검으로 건너뛰기])에서 17주 1일 새 내용 1단위 | 끝까지, 크래시 0 | 사진 |
| H16 | 폰 수준 맞춤 이야기 | 연습 > 이야기 회화 > 1장면 1회(6턴, 막혀서 도움 3단계 끝까지 한 번) → 다음 날(또는 시계 그대로) 2회 | AI 줄에 밑줄·뜻, 3단계 [한국어로 말해 보기] 영어 한 문장, 2회 첫 줄이 1회 기억과 이어짐, 기억 화면에 줄이 보이고 지울 수 있음 | 사진 |
| H17 | 내 녹음 비교 | 설정 > 코스 기록 > 내 녹음 비교 > 켜기 → 기준 문장 2개 녹음 → 하나 더 녹음 → 처음/최근 듣기 → 하나 지우기 → 모두 지우기 | 동의 전 저장 0(화면 사용량 0MB), 재생 됨, 지움 뒤 사용량 0MB | 사진 |
| H18 | 쉐도잉·받아쓰기 | 코스 모드에서 쉐도잉 1세트·받아쓰기 1세트 | 배운 문장만(사용자 느낌), 비행기 모드에서도 시작됨 | 보고 |
| H19 | 오류 신고 | 레슨 중 [신고] 1회 → 설정 > 신고 기록 [복사] → 메모장에 붙여 넣기 | 한 줄 보임, AI 글 없음 | 사진 |
| H20 | 비행기 모드 이야기 | 비행기 모드에서 이야기 회 시작 | 대본 모드 안내, 크래시 0 | 사진 |

---

## 5. 작업별 O/X 합격 조건

### 5.0 공통 명령 (작성자·검토자 모두 PowerShell 5.1 에서 이 블록을 먼저 실행)
```powershell
$R   = 'D:\Ai\언어\app'
$S   = 'C:\Users\rtyu6\AppData\Local\Temp\claude\D--Ai----app\c5535f7a-0e1a-4bb6-bdc3-5597b7f84c22\scratchpad'
$W   = 'D:\Ai\언어\app_wt\v210_<작업 소문자>'            # 검토 대상 worktree
$T   = "$S\w_rev_v210_<작업 소문자>"                     # 작성자는 "$S\w_v210_<작업 소문자>"
$BASE = '<분기 커밋>'                                    # 오케스트레이터가 지시에 적는다
$G   = 'C:\Users\rtyu6\Desktop\Godot_v4.6.3-stable_win64.exe\Godot_v4.6.3-stable_win64_console.exe'
$PY  = 'D:\Ai\언어\app\backend\.venv\Scripts\python.exe'
$API_ARG = '--api=http://127.0.0.1:9'
$R1W = 1..16 | ForEach-Object { 'course_src/en/weeks/w{0:d3}.json' -f $_ }
New-Item -ItemType Directory -Force "$T\appdata" | Out-Null
$env:APPDATA = "$T\appdata"
$env:PYTHONDONTWRITEBYTECODE = '1'

function Run-GT([string]$name, [string]$mode = 'pc', [switch]$Api, [string[]]$More = @()) {
  $a = @('--headless', '--path', "$W\godot")
  if ($mode -like 'phone*') { $a += @('--resolution', '412x915') }
  $a += "res://tests/$name.tscn"
  $u = @()
  if ($mode -like 'phone*') { $u += '--phone' }
  if ($mode -like '*font')  { $u += '--font-scale=1.5' }
  if ($mode -like '*dark')  { $u += '--dark' }
  if ($Api) { $u += $API_ARG }
  $u += $More
  if ($u.Count -gt 0) { $a += '--'; $a += $u }
  $out = Join-Path $T ("{0}_{1}.txt" -f $name, $mode)
  & $G @a *> $out
  $code = $LASTEXITCODE
  $last = Get-Content $out | Where-Object { $_ -match '\d+ passed, \d+ failed' } | Select-Object -Last 1
  $se = @(Select-String -Path $out -SimpleMatch 'SCRIPT ERROR:').Count
  $tg = @(Select-String -Path $out -SimpleMatch 'TEST_GUARD on').Count
  "{0} {1} exit={2} | {3} | SCRIPT_ERROR={4} TEST_GUARD={5}" -f $name, $mode, $code, $last, $se, $tg
}
function Run-PY([string]$tag, [string[]]$argv) {   # 파이썬 도구·시험. 출력은 $T\py_<tag>.txt
  $out = Join-Path $T ("py_{0}.txt" -f $tag)
  & $PY -X utf8 @argv *> $out
  "{0} exit={1} | {2}" -f $tag, $LASTEXITCODE, ((Get-Content $out | Select-Object -Last 1) -join '')
}
# 상수 변이: 정확히 한 곳(UTF-8, BOM 없음). 원복은 Restore.
function Mutate([string]$rel, [string]$from, [string]$to, [bool]$bom = $false) {
  $f = Join-Path $W $rel
  $txt = [IO.File]::ReadAllText($f)
  $n = ([regex]::Matches($txt, [regex]::Escape($from))).Count
  if ($n -ne 1) { throw "MUTATE_TARGET_COUNT=$n ($rel)" }
  [IO.File]::WriteAllText($f, $txt.Replace($from, $to), (New-Object Text.UTF8Encoding($bom)))
  "MUTATED $rel"
}
function Restore([string]$rel) { git -C $W checkout -- $rel; "RESTORED $rel" }
function Own-Diff([string]$task) {
  $doc = [IO.File]::ReadAllText("$W\docs\v210_design.md")
  $blk = (($doc -split [regex]::Escape('<!-- OWN-BEGIN -->'))[1] -split [regex]::Escape('<!-- OWN-END -->'))[0]
  $rows = $blk -split "`n" | Where-Object { $_ -match ("^" + [regex]::Escape($task) + "\s") } | ForEach-Object { $_.Trim() -split '\s+' }
  $files = @($rows | Where-Object { $_[1] -ne 'newdir' } | ForEach-Object { $_[2] })
  $dirs  = @($rows | Where-Object { $_[1] -eq 'newdir' } | ForEach-Object { $_[2] })
  $changed = @(git -C $W diff --name-only $BASE) + @(git -C $W ls-files --others --exclude-standard)
  $changed | Where-Object { $p = $_; $p -and ($files -notcontains $p) -and ($p -notmatch '\.uid$') -and -not ($dirs | Where-Object { $p.StartsWith($_) }) } | Sort-Object -Unique
}
# 출력 파일들에서 비밀·개인 표식 개수(0 이어야 O)
function Leak-Count { @(Select-String -Path "$T\*.txt" -Pattern 'FAKEKEY_ZZ_','ZZ_MARK_9731','golden-dummy-credential','ZZ_HELP_5523','ZZ_NOTE_6634','ZZ_MEMO_7781' -SimpleMatch).Count }
```
- 시험 표식: 한국어 도움 글 표식 `ZZ_HELP_5523`, 신고 메모 표식 `ZZ_NOTE_6634`, 이야기 대화 학습자 글 표식 `ZZ_MEMO_7781`. 시험 출력·`user://test_*` 파일(그 표식을 일부러 저장하는 신고 저장소 시험 파일 제외)에 0번이어야 한다. 양성 대조는 메모리 안에서만(`selfcheck FAIL-as-expected leak`).
- 화면 시험 기본 모드 "4모드" = `pc`, `phone`, `phonefont`, `phonedark`.

### 5.1 공통 조건 X (모든 작업에 붙는다. v200 §14.1 C-0~C-17 도 그대로 적용)
- **X-0 기준선**: 작업 전 자기가 건드리는 기존 시험(없으면 `smoke`·`route_test`, 파이썬 작업은 `course_src\tools` unittest)의 마지막 줄을 `$T\baseline.txt` 에 적고 보고 맨 앞 표에 붙인다.
- **X-1 시험 출력 통과**: 자기 시험의 모든 `Run-GT` 줄이 `exit=0`, `N passed, 0 failed`, `SCRIPT_ERROR=0`, `TEST_GUARD=1`. 파이썬은 `exit=0` 과 지정한 마지막 줄.
- **X-2 비밀값·개인 글 0**:
```powershell
Leak-Count
git -C $W grep -I -n -E "(^|[^A-Za-z0-9_])sk-(ant-|proj-)?[A-Za-z0-9_-]{20,}|AIza[0-9A-Za-z_-]{30,}|gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,}|AKIA[0-9A-Z]{16}|xox[baprs]-[A-Za-z0-9-]{10,}|-----BEGIN [A-Z ]*PRIVATE KEY-----" | Measure-Object | ForEach-Object Count
```
  기대 `0`, `0`.
- **X-3 추적 금지물**: `git -C $W ls-files | Select-String -Pattern '(^godot/bin/|\.gdextension$|^native/_deps/|\.bin$|\.gguf$|\.onnx$|\.so$|\.dll$|\.wav$|\.mp3$|\.ogg$|\.m4a$|ai_secrets|ai_salt|voice_compare|course_story\.json|course_reports\.json)'` → `godot/tests/fixtures/song/tone_8s.mp3` 한 줄뿐(B1 시험은 녹음을 `user://test_vc_*` 에만 만들고 저장소에 두지 않음).
- **X-4 공개 검사**: `powershell -ExecutionPolicy Bypass -File "$W\packaging\publish_release.ps1" -Version 2.1.0 -ScanOnly; "exit=$LASTEXITCODE"` → `exit=0`, `powershell -ExecutionPolicy Bypass -File "$W\packaging\check_no_media.ps1"; "exit=$LASTEXITCODE"` → `exit=0`.
- **X-5 금지 파일 무변경**: `git -C $W diff --name-only $BASE -- godot/project.godot godot/export_presets.cfg native godot/scripts/sync godot/scripts/autoload packaging backend/lan.py backend/sync_hub.py backend/llm_api.py backend/llm_common.py backend/llm_opencode.py backend/curriculum.json godot/data/curriculum.json godot/scripts/local/ai_client.gd godot/scripts/local/ai_secrets.gd godot/scripts/local/ai_presets.gd godot/scripts/core/ai_state.gd godot/scripts/local/local_ai.gd course_src/review/R1_X1.tsv course_src/review/R1_X2.tsv @R1W` → 출력 없음. `git -C $W diff --name-only $BASE -- backend` ⊆ 자기 OWN 줄(S1·M2·KBR 만 `backend` 를 가짐). 일본어: `git -C $W diff --name-only $BASE -- 'godot/tests/*ja*' 'backend/test_missions_ja.py' 'godot/data/pack/*_ja.json'` → 출력 없음. `SyncDoc.SCHEMA`: `Select-String "$W\godot\scripts\sync\sync_doc.gd" -Pattern 'const SCHEMA := 1' -SimpleMatch` 1줄.
- **X-6 네트워크 코드 위치**: `Get-ChildItem "$W\godot\scripts" -Recurse -Filter *.gd | Select-String -Pattern 'HTTPRequest','HTTPClient','shell_open','request_permission' -SimpleMatch | ForEach-Object { $_.Path.Substring($W.Length + 1) } | Sort-Object -Unique` → 기준 커밋의 같은 명령 결과와 같음(새 파일 0).
- **X-7 로그 정적 검사**: `Get-ChildItem "$W\godot\scripts\core\story_store.gd","$W\godot\scripts\core\course_chat.gd","$W\godot\scripts\views\story_view.gd","$W\godot\scripts\ui\chat_help_bar.gd","$W\godot\scripts\core\voice_compare_store.gd","$W\godot\scripts\ui\voice_compare_view.gd","$W\godot\scripts\core\course_reports.gd","$W\godot\scripts\ui\report_sheet.gd","$W\godot\scripts\core\course_levels.gd" -ErrorAction SilentlyContinue | Select-String -CaseSensitive -Pattern '(print|push_warning|push_error|printerr|Toast\.\w+)\(.*\b(help_ko|help|memory|mem|note|reply|text|wav|b64|body|messages|prompt|history)\b'` → 0줄. 서버: `Select-String "$W\backend\course_level.py" -Pattern '\b(log|print)\b.*\(' ` → 0줄, `Select-String "$W\backend\server.py" -Pattern 'log\.\w+\(.*(help_ko|memory|story|history)'` → 0줄. `ai_chat_rules.gd` 는 v202 X-7 그대로.
- **X-8 소유 밖 수정 0**: `Own-Diff <작업>` → 출력 없음.
- **X-9 소유권 검사**: §3.3 명령에 그 파에서 아직 병합되지 않은 작업을 `only` 로 넘겨 `OK`.
- **X-10 프로세스**: 시작한 프로세스는 받은 PID 로만 종료. 보고에 "남은 프로세스·열린 포트 없음"(`Get-NetTCPConnection -State Listen -LocalPort (18791..18799) -ErrorAction SilentlyContinue` 결과 없음).
- **X-11 실제 사용자 폴더 무변경**: 시험 전후 `Get-ChildItem "$env:USERPROFILE\AppData\Roaming\Godot\app_userdata" -Recurse -File | Select FullName,Length,LastWriteTime` 목록이 같다.
- **X-12 실제 네트워크 0**: 시험·도구가 `127.0.0.1` 밖에 접속하지 않는다. 파이썬 시험은 `socket.socket`·`socket.getaddrinfo`·`subprocess.Popen` 을 막은 상태로 돈다(`make_ai_golden.py` 방식). 예외: SP(무료 DeepSeek, 오케스트레이터 승인)와 T-8.
- **X-13 기기 전용 파일 시험 격리**: 새 저장소 시험은 경로를 `user://test_*` 로 바꾸고, 가드 자기 점검으로 "가드 켜짐 + 실제 경로 → `user://test_guard/…` 로 돌려짐"을 단언한다.
- **X-14 화면 규칙**: v200 C-11(이모지·`Color("#`) 0, C-14(화면 흐름 시험은 실제 버튼, `press:` 줄), C-15(5자리 숫자 0, 진행 글은 `progress_label`, `selfcheck` 포함).

### 5.2 K1R — 도구
- **K1R-1** `Run-PY k1r_all @('-m','unittest','discover','-s',"$W\course_src\tools",'-p','test_*.py')` → `exit=0`, 마지막 줄 `OK`, `Ran N tests` N ≥ 기준선 + 40.
- **K1R-2 기존 시험 무변경**: `git -C $W diff --name-only $BASE -- 'course_src/tools/test_*.py' course_src/tools/fixtures/good_mini 'course_src/tools/fixtures/bad_*'` → 출력 없음(새 `test_r2_tools.py` 는 untracked 로 별도).
- **K1R-3 R1 원고 회귀(핵심)**: `Run-PY r1lint @("$W\course_src\tools\check_course.py",'--in',"$W\course_src\en",'--weeks','1-16','--strict')` → `exit=0`, `CHECK_OK weeks=1-16 … violations=0`. `--skeleton --strict` 도 지금 skeleton(itemized 16)으로 `CHECK_OK`.
- **K1R-4 R1 빌드 바이트 불변(핵심)**: `& $PY -X utf8 "$W\course_src\tools\build_course.py" --in "$W\course_src\en" --weeks 1-16 --out "$T\r1out"` 뒤 `Get-FileHash "$T\r1out\*.json"` 와 `Get-FileHash "$W\godot\data\course\*.json"` 의 이름별 해시가 7개 모두 같음 → `R1_BUILD_SAME 7/7`(보고에 명령 출력).
- **K1R-5 R2 좋은 예시**: `check_course.py --in "$W\course_src\tools\fixtures\r2\good_r2_mini" --strict` → `CHECK_OK`, `build_course.py … --levels-out "$T\lv.json"` → `BUILD_OK`, `lv.json` 에 `tokens`·`week`·`story_mem` 키, 두 번 빌드 sha256 같음.
- **K1R-6 일부러 틀린 입력(핵심)**: `fixtures\r2\bad_r2_<이름>` 마다 종료 1·첫 줄 코드: `forms_add_same_week`(SCHEMA), `forms_add_bad_pat`(SCHEMA), `forms_add_bad_form`(FORM_SUSPECT), `fallback_passive`(ORDER), `fallback_future_word`(ORDER), `fallback_too_long`(COUNT 또는 SCHEMA), `story_bad_id`(SCHEMA), `story_line_future`(ORDER), `story_mem_unref`(SCHEMA), `story_phone`(PERSONAL), `story_name_not_allowed`(PERSONAL), `r2_id_outside`(SCHEMA `…_outside_R2_limits`), `r2_assign_total`(COUNT `assign_17_32`), `r2_grammar_ko_missing`(SCHEMA) — 14개, 시험이 표로 단언.
- **K1R-7 검수 항목**: `good_r2_mini` 의 `--count-items` 줄에 `story_line=`·`story_mem=`·`story_text=`·`fallback=`, R1 원고의 `--count-items` 줄은 기준 커밋과 글자까지 같음.
- **K1R-8 상수 변이**: `Mutate 'course_src\tools\check_course.py' '32: {"words": (1, 1399)' '32: {"words": (1, 699)'` → K1R-1 `exit=1`(R2 범위 시험 FAIL), `Restore` 뒤 `exit=0`.
- **금지**: 기존 시험·픽스처 수정, 네트워크(`requests|urllib|http.client|socket` 0줄), `backend\tools\` 새 파일, 출력에 원고 전문, X-8.

### 5.3 K0R — 뼈대·정책
- **K0R-1** K1R 병합 뒤 `check_course.py --in "$W\course_src\en" --skeleton --strict` → `CHECK_OK`(itemized 1~32).
- **K0R-2 수량**: 17~32주 배정 능동 400·수동 224(주별 `counts` 와 같음), 일 분배 위반 0, 문형 64개 모두 `title_ko`·`grammar_ko` 2~4줄·`needs`(순서 위반 0), lemma 중복 0(1~32주 전체).
- **K0R-3 id 범위**: `R2A~R2D` 겹침 0·R2 한계 안, 배정 id `w0700` 부터 연속 624개.
- **K0R-4 이야기 개요**: `story_season1.eps` 16개(ep 1~16, w 17~32, id `s1e01~s1e16`), 인물·장소가 `policy.json` 허용 목록(from_w ≤ w), `learner = {"name":"Min","phone":"555-0142"}`.
- **K0R-5 기준 문장**: `voice_ref` 5개가 모두 R1 문장 id 이고 scope `all`(시험 또는 파이썬 한 줄로 확인한 출력).
- **K0R-6 정책**: `Harbour Hostel` from_w 17, 새 이름은 보고 목록과 같음, 나머지 정책 줄 변경 0(`git diff` 확인).
- **K0R-7 일부러 틀린 입력**(C-17): 복사본에 같은 lemma 를 18·25주에 → `CHECK_FAIL SCHEMA`(또는 COUNT), 문형 `needs` 에 30주 낱말을 20주 문형에 → `ORDER`, 정책에서 Harbour Hostel 을 34 로 되돌린 복사본 + 17주 원고 조각 → `PERSONAL name_before_allowed_week`.
- **금지**: 1~16주 항목 변경, 낱말 뜻·예문, 외부 단어표 복사(보고에 참고 자료와 "복사 안 함"), X-8.

### 5.4 A5 / A6 / A7 / A8 — 주 원고
- **A-1 린터**: `check_course.py --in "$W\course_src\en" --weeks <a>-<b> --strict` → `CHECK_OK weeks=<a>-<b> … violations=0`(A6~A8 은 앞 주 파일이 main 에 있는 상태에서).
- **A-2 배정 준수**: 낱말 id 집합 = 배정표 그 주 집합(고유명사 추가만 허용, 자기 `R2x` 범위), 문장·대화 id 자기 범위.
- **A-3 수량**: §2.3 표 — 주당 문장 48~60(32주 40~56), 문장 id 사용 ≤ 250/작가, 대화 1편 6~10줄, 월말 주 `speak_prompts` 3, 이야기 `parts` 2~3·대본 4~6줄, 안전 대사 6~10. 보고에 주별 실제 숫자 표.
- **A-4 한국어**: `KO_HANGUL`·`KO_HANJA` 0, 해요체, 낱말 `ko` ≤ 12자.
- **A-5 숫자**: `NUM_SAY` 0(`numbers_en.py` 값).
- **A-6 이야기·기억**: 인물·장소·슬롯이 `story_season1` 과 같음, 모든 `mem` 이 참조됨, 기억 문장에 실제 정보형 숫자 0.
- **A-7 자연스러움 자가 점검 표**(보고): 고친 건수·고친 예 3개.
- **A-8 일부러 틀린 입력**(C-17): 복사본에서 (1) 18주 문장에 30주 낱말 (2) `ko` 한자 1자 (3) 가격 문장 `say` 삭제 (4) 안전 대사에 그 주 D3 낱말 (5) 기억 문장에 `555-1234` — 각각 `ORDER`, `KO_HANJA`, `NUM_SAY`, `ORDER`, `PERSONAL` 줄.
- **A-9 A5 파일럿 보고**(A5 만): 소요 시간·도구 호출 수·처음 린터 위반 수·고친 건수, 주당 실제 문장 수와 id 사용률.
- **금지**: 다른 작가·K0R 파일, 배정표 변경, 1~16주 파일, 외부 교재 문장 복사, 네트워크, X-8.

### 5.5 SP — 스파이크
- **SP-1** `<scratch>\w_v210_sp\sp_result.json` 과 요약 줄 2개 이상(변형별 `SP replies=…`), 대화 20개 x 변형 2개 이상.
- **SP-2** 저장소 변경 0(`git -C $R status --short` 출력 없음), 요청 수 ≤ 400(스크립트 카운터 줄), `secrets.json`·설정 열람 0(스크립트가 그 파일을 열지 않음을 코드로 확인).
- **SP-3 검사기 자기 점검**: 프로토타입 `level_check` 에 미래 낱말 3개 문장 → 실패, 허용 낱말만 → 통과 줄(`selfcheck FAIL-as-expected oov`).
- **금지**: 개인정보가 든 학습자 줄, 유료 엔진, 저장소 파일.

### 5.6 X3a / X3b — 독립 검수
- **X3-1 전수**: `check_course.py --in course_src\en --weeks <a>-<b> --review course_src\review\R2_X3?.tsv` → `REVIEW_OK rows=N`(N = `--count-items` total), verdict `OK/M/C` 만.
- **X3-2 심은 오류**: §4.1-2 복사본 검수에서 잡은 수/10 ≥ 9(묶음마다).
- **X3-3 잔여 C 0**: 작성자 수정 뒤 재검수 tsv 의 C 행 0.
- **X3-4 독립성**: 보고에 "작성자와 다른 세션, 원고만 보고 판정, 작성자 보고서 안 봄".
- **금지**: 원고 수정, tsv 밖 새 파일, 네트워크.

### 5.7 HS — 표본 300 (Hydrogen)
- **HS-1** 시트 310행(진짜 300 + 심은 10), 층별 개수 90/120/50/40 ±1(`sample_sheet.py` 출력).
- **HS-2** 심은 오류 적발 ≥ 9/10.
- **HS-3** 진짜 300행 C 0, M ≤ 3 → `R2_H300.tsv` 300행.
- **HS-4** Hydrogen 이 원고를 바꾸지 않음(입력·출력만), 결과에 "AI 검수(사람 아님)" 표기.

### 5.8 M2 — 미션
- **M2-1** `Run-PY m2lint @("$W\backend\test_missions.py",'--lint')` → `exit=0`, 실패 0 줄. `Run-PY m2pack @("$W\backend\test_phone_pack.py")` → `exit=0`.
- **M2-2 공개 모양**: `min_week` 없는 미션의 공개 키 순서 = 기존 9키(시험 단언), 있는 미션 = 9키 + `min_week`(min_stage 뒤). 영어 10개·일본어 8개.
- **M2-3 팩**: `build_phone_pack.py --only content` 뒤 `git -C $W diff --name-only $BASE -- godot/data/pack` = `missions.json`·`manifest.json` 둘뿐, 팩 `missions.json` = `backend/content/missions.json`(sha256 같음).
- **M2-4 어휘**: 새 미션 두 개와 `min_week` 를 받은 미션의 `hint_en`·`opening`·대본 줄 토큰이 모두 코스 어휘 o ≤ `min_week*10+7`(스크래치 스크립트가 `course_common` 낱말 목록으로 확인, `MISSION_VOCAB <id> bad=0` 줄 7개).
- **M2-5 폰**: `Run-GT local_missions_test pc`·`phone` → X-1(18개). `Run-GT ai_feedback_parity_test pc` → X-1(sha 상수만 바뀜: `git diff -U0` 의 `+`/`-` 줄이 그 상수 한 쌍). `make_ai_golden.py --check` → `exit=0`.
- **M2-6 `MissionLogic.fits`·`sort_for` 표**(새 단언 ≥ 12행, `local_missions_test` 안): min_week 있음/없음 x cw 0/5/29/31 x stage 1/2.
- **M2-7 독립 문장 시험**: 오케스트레이터가 다른 `worker-hard`(M2T, 규칙을 보지 않은 세션)에게 새 두 미션 목표마다 맞는 문장 15·아닌 문장 15를 쓰게 해 스크래치 러너로 → 맞는 문장 적중 ≥ 90%, 아닌 문장 오탐 ≤ 10%.
- **M2-8 상수 변이**: `Mutate 'godot\scripts\core\mission_logic.gd'` 의 `fits` 비교 `<=` 를 `<` 로(정확히 한 곳, 워커가 유일한 글을 정해 보고) → `local_missions_test pc` `exit=1`, 원복 뒤 0.
- **금지**: 다른 미션 내용·일본어 변경, `missions.py` 의 목록 필터 의미 변경, 팩의 다른 파일, X-8.

### 5.9 S1 — 서버
- **S1-1** `Run-PY s1 @("$W\backend\test_course_chat.py")` → `exit=0`, 마지막 줄 `COURSE_CHAT N passed, 0 failed`(N ≥ 150). 시험은 네트워크·프로세스를 막고, 엔진을 대본 가짜로 바꾸고, `course_level.set_levels(<미니 픽스처>)` 로 돈다.
- **S1-2 기존 호환(핵심)**: `Run-PY golden @('-I',"$W\phone_src\tools\make_ai_golden.py",'--check')` → `exit=0`(기존 462사례 드리프트 0). 시험 안에서 `course` 없는 요청·`course` 가 범위 밖·`lang:"ja"`·수준표 없음 → 응답에 `level` 키 없음·엔진 호출 인자 기존과 같음.
- **S1-3 수준 경로 표**(시험 단언): 통과 → 엔진 1회·`source "ai"`; OOV 2개(17주, 한도 1) → 2회째 메시지 끝에 `retry_note` 글 그대로·통과; 3회 모두 실패 → `source "fallback"`·`reply` 가 그 주 안전 대사·502 아님; 시간 훅으로 첫 요청 뒤 61초 → 재요청 0·안전 대사; 엔진 `limit` 오류 → 재요청 0·기존 오류 응답; 형식 오류 1회 + 수준 통과; `simplify` 로 한도 줄어듦; `suggest` 거르기·채우기.
- **S1-4 `level_check` 순수 표** ≥ 60행(대소문자·숫자·`'`·하이픈·유니코드·문장 첫 대문자·중간 대문자·빈 글·`?!.` 연속).
- **S1-5 개인정보·기억(핵심)**: 화이트리스트 밖 줄·이메일·URL·`555-1234`·`passport` 줄 → 프롬프트에 0; 9줄 → 8줄; 501자 → 500자 이하. 학습자 글 표식 `ZZ_MEMO_7781`·도움 표식 `ZZ_HELP_5523` 이 서버 로그 핸들러(시험이 메모리 핸들러로 받음)·캐시 호출에 0, 양성 대조 줄.
- **S1-6 도움·요약**: 도움 성공(1문장·수준 통과)·실패 `source "none"`·121자 400·`course` 없음 400·요약 enum 밖 값 → `""`·모르는 장면 → `story` 무시.
- **S1-7 상수 변이**: `Mutate 'backend\course_level.py' 'MAX_ATTEMPTS = 3' 'MAX_ATTEMPTS = 1'` → S1-1 `exit=1`, 원복 뒤 0. `Mutate 'backend\course_level.py' 'RETRY_IF_ELAPSED_UNDER = 60.0' 'RETRY_IF_ELAPSED_UNDER = 9999.0'` → `exit=1`(시간 조건 사례 FAIL), 원복 뒤 0.
- **금지**: 새 라우트, `lan.py`·`sync_hub.py`·`llm_*.py` 수정, 기존 응답 키 이름·모양 변경, 로그에 글(X-7), 실제 엔진 호출, X-8.

### 5.10 KBR — 출시 데이터
- **KBR-1** `check_course.py --in course_src\en --weeks 1-32 --strict` → `CHECK_OK weeks=1-32 … violations=0`. `--grammar` 결과 기록(없으면 "미검증").
- **KBR-2 결정성·해시(핵심)**: 두 번 빌드(데이터 + `--levels-out`) sha256 같음, 매니페스트 크기·sha256 = 실제 파일, 합계 ≤ 3 MB(추측치, 넘으면 이유 보고).
- **KBR-3 R1 불변(핵심)**: `course_data_real_test` 가 기준 커밋의 `godot/data/course/*` 사본(시험 픽스처가 아니라 `git show $BASE:<path>` 로 `$T` 에 꺼낸 것 — 시험은 경로 인자 `--r1-base=<dir>`)과 비교해 R1 의 문장·문형·대화·주 레코드 100% 같음, 낱말 레코드는 `forms` 에 o ≥ 171 항목이 더해진 것 말고 같음 → `R1_SAME weeks=16 sentences=991/991 …`.
- **KBR-4 전수 가드(핵심)**: `Run-GT course_guard_all_test pc`(1~32주 x 일 1~7 x 종류 6 x 시드 5 + 이야기 여는 말·대본 줄·기억 문장·안전 대사) → `checked N, violations 0, dropped R%`, R < 2.
- **KBR-5 수준표 일치(핵심)**: `course_levels.json` 의 `tokens` 가 빌드된 `en_lexicon.json` 에서 §2.7.1 규칙으로 다시 계산한 값과 같음(파이썬 한 줄 스크립트 출력 `LEVELS_EQ tokens=N same=N`), `story_mem` 수 = 원고 기억 문장 수.
- **KBR-6 개수**: 능동 776±(R1 실제 + 400), 수동 R1 실제 + 224, 문형 R1 + 64, 문장 ≥ 36 x 32, 대화 32편, 장면 16개, 월말 8세트, id 중복 0(`course_data_real_test` 가 실제 숫자 출력). PC·`phone` 둘 다, 1바이트 바꾼 복사본 → `course_corrupt`.
- **KBR-7 일부러 틀린 입력**(C-17): 복사본에서 (1) 20주 문장에 30주 낱말 → 린터 FAIL (2) 매니페스트 해시 틀림 → 시험 FAIL (3) `course_levels.json` 한 토큰 o 변경 → KBR-5 `same` 이 N-1.
- **KBR-8 공개 호환**: X-4.
- **금지**: 원고 수정(되돌림), 팩·커리큘럼 수정, X-8.

### 5.11 ST — 이야기 앱 쪽
- **ST-1** `Run-GT story_store_test pc`·`phone` → X-1, N ≥ 90. `Run-GT course_chat_test pc` → X-1, N ≥ 80. `Run-GT story_view_test` 4모드 + `pc -Api` → X-1, phone N ≥ 70.
- **ST-2 기억 규칙 표**: 슬롯 값 → 템플릿, 같은 슬롯 교체, 유효 값 0 → 기본 기억, 9개째 → 오래된 것 빠짐, 500자 초과 → 빠짐, 데이터에 없는 id → 목록에서 빠짐, 앞 장면 기본 채우기 1줄만, 깨진 파일 → `.bad`·빈 상태·크래시 0.
- **ST-3 파일에 글 0(핵심)**: 대화 흐름 전체(학습자 글에 `ZZ_MEMO_7781`) 뒤 `user://test_*` 의 이야기 파일 바이트에 영어·한국어 기억 문장·표식 0(id 만), 출력에 표식 0, `JSON.stringify(Store.prefs)`·`SyncDoc` 추출에 `course_story`·기억 문장 0.
- **ST-4 대본 전환(핵심, `press:` ≥ 18)**: 가짜 http 로 ① 첫 요청 오류 → 대본 모드·`TXT_SCRIPT`·요청 1건 ② 응답에 `level` 없음 → 대본 모드 ③ 정상 → 6턴(입력·[보내기] 버튼) → 요약 요청 본문 `story.mode == "summary"` → 기억 줄 표시 ④ 요약 오류 → 기본 기억. 회당 요청 ≤ 8, 자동 재시도 0.
- **ST-5 요청 본문**: `course.mode == "story"`, `story.memory` 가 `memory_en()` 과 같음(8줄·500자 이하), 비코스·일본어에서 `course_field` 가 `{}`.
- **ST-6 밑줄·도움**: `underline_bbcode` 표(대괄호 이스케이프, 낱말 경계, 대소문자) ≥ 15행, `HelpSteps` 15초 단계 진행(가짜 시계), 3단계 버튼 → 요청 본문 `help_ko`.
- **ST-7 기억 화면**: 줄 [지우기]·[기억 모두 지우기]·[이야기 처음부터] 각각 확인 시트 → 결과, 취소 → 변화 0.
- **ST-8 상수 변이**: `Mutate 'godot\scripts\core\story_store.gd' 'const MAX_MEM := 8' 'const MAX_MEM := 9'` → `story_store_test pc` `exit=1`, 원복 뒤 0.
- **금지**: 기존 파일 수정, 2.0.2 클래스 직접 참조(`AiState`·`AiClient`·`LocalAi` 0줄), 새 `HTTPRequest`, 로그에 글(X-7), X-8.

### 5.12 B1 — 내 녹음 비교
- **B1-1** `Run-GT voice_compare_test pc`·`phone` → X-1, N ≥ 90. `Run-GT voice_compare_view_test` 4모드 + `pc` → X-1, `press:` ≥ 16.
- **B1-2 동의 전 0바이트(핵심)**: 새 시험 루트에서 꺼짐 상태로 `save_clip` 10번(ref·month) → 모두 `err "off"`, 루트 폴더 없음(`DirAccess.dir_exists_absolute` false), 월말 연결 경로(가짜 drill 결과)도 0바이트. 양성 대조: 켠 뒤 1번 → 파일 1개.
- **B1-3 용량(핵심)**: `max_bytes_override` 로 작은 한도 → 넘는 저장 `full`·`need_bytes` 정확, 처음 녹음 자동 삭제 0, [중간 녹음 정리] 뒤 저장 성공, `usage_text` 에 5자리 숫자 0. 48 kHz 1초 사인 → `to_16k_mono` 결과 바이트 = 44 + 32000(±2), 16 kHz 입력 그대로, 20초 입력 → 15초로 자름.
- **B1-4 삭제(D2)**: 개별·모두 지우기 → 파일·index 일치, `Store.reset_progress()`(모든 기록 지우기) 뒤 녹음 파일·index 그대로.
- **B1-5 유출 0(핵심)**: `SyncDoc` 추출·`Store.prefs`·`progress.json`·`studylog.json`·시험 출력에 `voice_compare`·`.wav`·`vc_` 0, 가드 자기 점검(X-13).
- **B1-6 화면 흐름**: `VcEnable` → `VcRec_ref1`(가짜 녹음원 `Recorder.test_audio_source`) → `VcFirst_ref1`·`VcLatest_ref1` 재생 노드 → 녹음 2번째 → `VcDeleteAll` → 확인 → 사용량 0MB. `CONSENT_TEXT` 그대로 보임.
- **B1-7 월말**: 켜짐 + 월말 단위 말하기 채점 → `month` 녹음 1개(항목 `mNN_<문항 id>`), 꺼짐 → 0, `full` → 토스트·흐름 계속. `course_exercise_view_test`·`course_flow_test` 기준선 그대로.
- **B1-8 상수 변이**: `Mutate 'godot\scripts\core\voice_compare_store.gd' 'const RATE := 16000' 'const RATE := 48000'` → `voice_compare_test pc` `exit=1`, 원복 뒤 0.
- **금지**: 녹음을 저장소·동기화·서버·AI 로 보냄, 외부 공유·내보내기, `speak_drill.gd`·`wav_util.gd` 수정, X-8.

### 5.13 RP — 오류 신고
- **RP-1** `Run-GT course_reports_test pc`·`phone` → X-1, N ≥ 60. `Run-GT course_flow_test pc`·`phone` → passed ≥ 기준선, 0 failed(diff 는 `+` 줄만).
- **RP-2 저장소 표**: 종류·이유 검사, 메모 100자·줄바꿈 제거, 200개 가득 → `full`, `copy_text` 첫 줄·열 순서, `ai_reply` 레코드에 글 필드 0, 깨진 파일 `.bad`.
- **RP-3 버튼 흐름(`press:` ≥ 8)**: 플레이어 `CourseReportBtn` → 시트 → `ReportReason_ko_wrong` → `ReportNote`(표식 `ZZ_NOTE_6634`) → `ReportSave` → 저장 1개(항목 = 지금 문제 항목), 문제 상태·점수 변화 0. 표식은 신고 파일에만(출력 0).
- **RP-4 상수 변이**: `Mutate 'godot\scripts\core\course_reports.gd' 'const MAX := 200' 'const MAX := 201'` → `exit=1`, 원복 뒤 0.
- **금지**: 서버 전송, AI 글 저장, X-8.

### 5.14 CU — 따라잡기
- **CU-1** `Run-GT catch_up_test pc`·`phone` → X-1, N ≥ 90. `day_plan_test`·`course_today_test`·`home_view_test`(`pc -Api`·`phone -Api`) 기준선 그대로.
- **CU-2 동등(핵심)**: 시험 안 옛 `DayPlan.today` 사본과 새 함수를 새 키 없는 무작위 스냅샷 2,000개(시드 고정)로 비교 → `DAYPLAN_EQUIV cases=2000 same=2000`.
- **CU-3 규칙 표**: U8(쉬는 날 0/2/10, 경계 0), U9(avail 16·32, avail_done T/F), U10(cells_today 0/1/2, 다음 칸 new/speak/check/free, late 0/1) ≥ 24행.
- **CU-4 홈 흐름(`press:` ≥ 4)**: late ≥ 1 + 블록 완료 → `TodayExtraCell` 보임 → 누름 → 플레이어 spec 이 다음 칸, U9 상태 → 늦음 문구 없음 + 업데이트 문구.
- **CU-5 저장 호환**: `cells` 없는 옛 `course.json` 읽기·쓰기 → 다른 키 보존, `cells` 0~7 범위 밖 → 정규화.
- **CU-6 상수 변이**: `day_plan.gd` 의 U10 조건 `cells_today < 2` → `< 3`(정확히 한 곳) → `exit=1`, 원복 뒤 0.
- **금지**: 기존 DayPlan 결과 변경(새 키 없을 때), `study_log.gd` 수정, X-8.

### 5.15 P1 — 쉐도잉·받아쓰기
- **P1-1** `Run-GT course_practice_test pc` → X-1, N ≥ 70. `Run-GT course_stage_wiring_test` 4모드 + `pc`(`-Api`) → X-1. `practice_test`(`--api` 없이)·`dictation_test`·`dictation_ja_screen_test`·`phone_score_wiring_test` 기준선 그대로.
- **P1-2 고르기 표**: o ≤ 현재(미래 문장 0, 1~32주 x d 1·4·7 전수), 쉐도잉 scope, 받아쓰기 토큰 3~8·`say` 없음, 최근 60%, 시드 결정성, `exclude`, 1주 1일 후보 수, 0개 → `[]`.
- **P1-3 요청 0**: 코스 모드 영어 쉐도잉·받아쓰기 시작 → `/practice/sentences` 요청 0(가짜 http 카운터), 비코스 영어·일본어 → 요청 쿼리가 기준 커밋 함수와 같음(E7-3 표 그대로).
- **P1-4 단언 변경 범위**: `git -C $W diff -U0 $BASE -- godot/tests/course_stage_wiring_test.gd | Select-String '^-\s*(ok|eq)\('` 의 줄이 쉐도잉 2·받아쓰기 1 의 E7-9 단언뿐(검토자가 줄 확인).
- **P1-5 상수 변이**: `course_practice.gd` 의 o 비교 `<=` → `<`(정확히 한 곳) → `course_practice_test` `exit=1`, 원복 뒤 0.
- **금지**: 서버·`local_practice.gd` 수정, 대화·미션 안내 단언 변경, X-8.

### 5.16 PI-L — 폰 이식
- **PIL-1** `Run-GT ai_course_parity_test pc`·`phone` → X-1, N ≥ 400. `Run-GT course_levels_test pc`·`phone` → X-1, N ≥ 40. 2.0.2 시험 `ai_chat_parity_test`·`local_ai_test`·`ai_feedback_parity_test`(pc·phone) 기준선 그대로.
- **PIL-2 황금 일치(핵심)**: `make_ai_golden.py --check` → `exit=0`; 출력 줄 `AI_COURSE_GOLDEN chat=N/N level=M/M mem=K/K prompt=P/P`(N ≥ 60, M ≥ 60, K ≥ 30, P ≥ 16); 기존 11개 황금 파일 `git diff --name-only $BASE -- godot/tests/fixtures/ai_golden` 이 새 파일 2개 말고 0; `AI_CHAT_GOLDEN chat=68/68 fix=41/41` 그대로.
- **PIL-3 실제 데이터 일치(핵심)**: `course_levels_test` 가 `CourseLevels.derive(CourseFeed.plain_data())` 와 `backend/content/course_levels.json`(`ProjectSettings.globalize_path("res://").path_join("../backend/content/course_levels.json")`)을 `canon` 비교 → `COURSE_LEVELS_EQ tokens=N same=N week=32/32 story_mem=M/M`. 소요 출력 `COURSE_LEVELS_DERIVE_MS <n>`(PC ≤ 300, 폰은 실기 미검증).
- **PIL-4 2.0.2 약속**: `Select-String "$W\godot\scripts\local\ai_chat_rules.gd" -Pattern '^static func (rules_text|context_text|clean_hist|ko_ok|scrub_ko|looks_like_question|norm_text|run_chat|fix)\('` 의 줄이 기준 커밋과 글자까지 같음, `local_ai.gd`·`ai_client.gd`·`ai_state.gd` diff 0.
- **PIL-5 요금 보호(핵심)**: 가짜 엔진으로 OOV 고집 → 엔진 호출 정확히 3, 시간 훅 61초 → 1, `ai_limit` → 1·재요청 0, 도움 실패 → 3. 호출 수는 가짜 엔진의 기록 수로 센다.
- **PIL-6 상수 변이**: `Mutate 'godot\scripts\local\ai_chat_rules.gd' 'const MAX_ATTEMPTS := 3' 'const MAX_ATTEMPTS := 2'` → `ai_course_parity_test pc` `exit=1`, 원복 뒤 0.
- **금지**: 기존 황금 수정, 서버 코드 수정(차이가 나면 S1 을 다시 연다 — 오케스트레이터), 2.0.2 파일 수정, X-7, X-8.

### 5.17 W1 — 화면 연결
- **W1-1** `Run-GT course_ai_wiring_test` 4모드 + `pc`(`-Api`) → X-1, phone N ≥ 120, `press:` ≥ 24. `course_stage_wiring_test`(수정 0) 4모드 → X-1. `mission_test`·`settings_view_test`·`phone_ai_wiring_test`·`ai_connect_test`(`pc -Api`·`phone -Api`) → passed ≥ 기준선, 0 failed.
- **W1-2 대화 흐름(핵심)**: 코스 17주 대화 → 요청 본문 `course = {w:17, d, mode:"guided", simplify:false}` → 응답 `level.oov=["harbour"]` → AI 줄 `RichTextLabel` 에 `[u]` → 그 낱말 `meta_clicked` → 뜻 시트 → 15초(가짜 시계) 뒤 `HelpStep1` 강조 → `HelpStep3` → 한국어 입력(`ZZ_HELP_5523`) → 요청 본문 `help_ko` → [이 문장 쓰기] → 입력칸 = 도움 영어. `level` 없는 응답 → 밑줄 0. 표식이 출력에 0.
- **W1-3 미션**: 가짜 미션에 `min_week` 있음/없음 섞어 목록 순서·"N주차부터"·잠금 시트, 25주 AI 모드 요청 본문 `course.mode == "mission"`, 24주는 `course` 없음.
- **W1-4 설정(핵심)**: `CourseRecordSection` 의 세 행 버튼 → 각 화면 열림, `ReportsCopy` → 클립보드 훅에 `copy_text`, "모든 기록 지우기" 확인 시트 글에 `RESET_KEEP_NOTE` 포함 → [지우기] 뒤 녹음·이야기·신고 파일 그대로. 코스 데이터 없으면 묶음 없음.
- **W1-5 연습 허브**: 코스 16주 → [이야기 회화] 잠금 시트("17주차"), 17주 → `StoryView` 열림.
- **W1-6 기존 단언 삭제 0**: `git -C $W diff -U0 $BASE -- godot/tests | Select-String '^-\s*(ok|eq)\('` → 출력 없음.
- **W1-7 상수 변이**: `Mutate 'godot\scripts\practice\mission_screen.gd'` 의 AI 코스 시작 주 25 → 1(정확히 한 곳, 워커가 유일한 글을 정해 보고) → `course_ai_wiring_test phone -Api` `exit=1`, 원복 뒤 0.
- **금지**: `story_view.gd`·`chat_help_bar.gd`·`voice_compare_*`·`report_sheet.gd` 수정(각 작업 소유), `sync_panel.gd`, `course_stage_wiring_test.gd`, X-8.

### 5.18 BG — 배지(선택)
- **BG-1** `Run-GT course_badge_test pc` → X-1, N ≥ 30. `badge_engine_test`·`badge_view_test`·`badge_rules_test`·`stats_view_test` → 0 failed. 단언 변경은 `badge_engine_test` 의 25 → 29 세 곳뿐(`git diff -U0`).
- **BG-2 일부러 틀린 입력**: 코스 파일 없음·깨짐 → 배지 0·크래시 0. **변이**: `course_s2` 조건 주 32 → 31 → `exit=1`, 원복 뒤 0.

### 5.19 FXR — 사소 잔여(선택)
- **FXR-1** `Run-GT course_home_test` 4모드 → X-1, passed ≥ 기준선 + 2. 새 단언(이 파일에 **추가만**): `phonefont` 에서 블록 머리글 `Label` 의 `autowrap_mode == TextServer.AUTOWRAP_WORD_SMART`, 머리글 글자가 낱말 중간에서 잘리지 않음(줄마다 끝 글자가 공백·문장 끝 또는 낱말 끝). `git diff -U0 $BASE -- godot/scripts/views/course_home.gd` 는 머리글 줄 근처만, 시험 diff 는 `+` 줄만.
- **FXR-2 변이**: `course_home.gd` 의 그 `autowrap_mode` 줄을 지운 복사(정확히 한 곳) → `course_home_test phonefont` `exit=1`, 원복 뒤 0.

### 5.20 ZR — 문서
- **ZR-1** `git -C $W diff --stat $BASE` 가 `README.md`·`ROADMAP.md`·`INSTALL.md` 셋만.
- **ZR-2** `Select-String -Path "$W\README.md" -Pattern '17~32주','이야기','내 녹음','사람 검수 없음','Hydrogen','밑줄' -SimpleMatch` 각 ≥ 1, `ROADMAP.md` 에 `2.1.0`·"알려진" ≥ 1, `INSTALL.md` 에 "녹음 모두 지우기" ≥ 1.
- **ZR-3 사실 대조**(오케스트레이터): 20MB·주 2일·8줄·500자·15초 숫자가 코드 상수와 같음, 준수율 숫자 = T-8 기록.
- **ZR-4** 새 줄에 `C:\Users`·`secrets`·`FAKEKEY` 0, `WORKLOG.md`·버전 숫자 변경 0.

---

## 6. 통합 시험 T(2.1.0)·공개 (6파, 오케스트레이터가 main 에서 직접)
- **T-0 버전**: `config/version="2.1.0"`, `version/code=20100`(규칙 major*10000 + minor*100 + patch: 2.0.0=20000, 2.0.2=20002).
- **T-1 새 시험 전부**: §5 의 Godot 시험(4모드·pc·phone), `test_course_chat.py`, `make_ai_golden.py --check`, `test_make_ai_golden.py`, `course_src\tools` unittest, `check_course.py --weeks 1-32 --strict`, `test_missions.py --lint`, `test_phone_pack.py`.
- **T-2 회귀**: `$S\w_t9\run_godot.ps1 -Project 'D:\Ai\언어\app\godot' -Tag v210` 전체 → 0 failed·SCRIPT ERROR 0·TEST_GUARD 1. 2.0.2 시험 전부(`run_ai_tests.ps1`·`rest_days_test` 등), 일본어 시험 변경 0(`git diff v2.0.2 -- 'godot/tests/*ja*'` 비어 있음).
- **T-3 보안 정적**: X-2(전체), X-3, X-6, X-7 을 main 에서 다시.
- **T-4 개인정보 묶음**: B1-2·B1-5·ST-3·S1-5·RP-3 을 main 에서 다시 실행(높음 등급 핵심 명령).
- **T-5 빌드**: 정식 키 시험 APK → 권한 3개·`arm64-v8a`·16 KB(`check_phone_native.ps1 -Apk` `PHONE_NATIVE_OK`), APK 증가분 출력(코스 데이터 약 +0.5~1 MB 추측).
- **T-6 소유권**: 6파 시작 때 `only=ZR` 로 OK 기록.
- **T-7 콘텐츠 게이트**: 린터 0, X3a/b C 0·심은 오류 ≥ 9/10(모든 묶음), HS C 0·M ≤ 3·심은 오류 ≥ 9/10.
- **T-8 실제 AI 준수율 실측(오케스트레이터, 네트워크)**: PC 서버(무료 DeepSeek)로 20대화(주 17·21·25·29 x 5, 학습자 줄은 SP 대본 재사용) → 1차 통과율·최종 통과율·안전 대사 비율·평균 시도·밑줄 누락 0 확인(기획 §8-3 목표치는 추측: 70%/90%/≤10%). 미달이면 [SP 뒤 확정] 상수만 조정(S1·PI-L 함께, 황금 재생성) 후 재측정, 최종 숫자를 ZR 에 기록. 폰 업체 실측은 실기 H16 의 체감으로 대신(숫자는 미검증).
- **공개 전 확인**:
```powershell
git -C $R ls-files | Select-String -Pattern '(\.so|\.dll|\.bin|\.gguf|\.onnx|\.wav|\.mp3|\.ogg|\.m4a|\.apk|\.keystore|\.jks|release\.pass|secrets|auth\.json|\.gdextension|ai_secrets|ai_salt|voice_compare|course_story|course_reports)$'
```
  기대: `godot/tests/fixtures/song/tone_8s.mp3` 하나. 릴리스 노트: 무엇이 새로 생겼고 어디서 켜는지 1줄씩(이야기 = 연습 > 이야기 회화, 녹음 비교 = 설정 > 코스 기록), "17~32주 원고는 AI 검수만(사람 검수 없음)", 검토자 대체(Sol 한도) 여부. 공개 뒤 링크·SHA256SUMS·`releases/latest = v2.1.0`·APK 내려받기 확인. 문제가 생기면 지우지 않고 2.1.1 로.

---

## 7. 위험 요소와 대안, 일부러 틀린 입력

### 7.1 위험
| # | 위험 | 영향 | 대응·대안 |
|---|---|---|---|
| R1 | AI 어휘 준수율이 낮아 재요청·안전 대사가 잦음 | 느림, 폰 유료 요금 최대 3배(추측), 부자연스러운 대화 | SP 로 상수 먼저 조정, 최대 3회 + 60초 조건, `suggest` 는 거르기만, T-8 실측 공개. 그래도 낮으면 `OOV_MAX` 17~40주 2 로(D-6) |
| R2 | 2.0.2 지연 → G1·G2 막힘 | 4·5파 착수 지연, 상한 압박 | 2·3파(원고·검수·SP)와 4파 작업 개발은 관문 전 진행, 2.0.2 가 1월 중순을 넘기면 D6 B(PI-L 2.1.1) + 절단 순서 |
| R3 | 앱 180초 제한 안에 서버 재요청이 끝나지 않음(S10) | 앱은 오류, 서버는 계속 비용 | 60초 시간 조건, 엔진 오류는 재요청 0 |
| R4 | 이야기 기억으로 실제 개인정보가 업체에 감 | 개인정보 | 저장·전송은 원고 템플릿 문장뿐(화이트리스트), AI 는 enum 만, 프롬프트 금지 지시, 정규식 이중 방어, 안내 1회, 보기·지우기(ST-3·S1-5) |
| R5 | 녹음 opt-in 전 파일 생성·동기화·백업 유출 | 개인정보 | 켜기 전 폴더도 없음(B1-2), `allowBackup=false`(2.0.1 검사 유지), X-3, T-4 |
| R6 | 녹음 용량이 기기 레이트(48 kHz) 때문에 빨리 참(S15) | 20MB 금방 참 | 16 kHz 로 줄여 저장, 15초 자름, 가득 차면 거절 + 중간 정리 |
| R7 | 문장 id 예산(1000/16주)이 R1 페이스(64/주)보다 작음(S2) | 원고 막힘 | 주당 48~60 목표·작가 250 상한(A-3), 모자라면 R3 범위 당기기는 오케스트레이터 결정(D-13) |
| R8 | 1~16주 낱말의 과거형·비교형을 넣으려면 R1 파일 수정이 필요(S6) | "1~16주 변경 0" 위반 | `forms_add`(K1R), KBR-3 R1 불변 검사 |
| R9 | 서버 ↔ 폰 프롬프트·검사 드리프트 | PC·폰 결과 다름 | 고정 미니 픽스처 황금(PIL-2) + 실제 수준표 일치(PIL-3), 상수 두 곳은 황금이 같음을 강제 |
| R10 | `course_levels.json` 과 APK 데이터 불일치 | 폰과 PC 허용 어휘 다름 | KBR 가 같은 빌드에서 둘 다 만들고 PIL-3 이 비교 |
| R11 | 미션 데이터 변경이 2.0.2 시험(sha 상수)을 깸(S14) | 회귀 소음 | M2 병합은 PI2c 뒤, 그 상수 한 줄만 M2 가 고침 |
| R12 | 쉬는 날 때문에 "예정보다 늦음"이 매주 쌓임(S18) | 의욕 저하 | U8, 하루 1칸 더(U10), 업데이트 대기(U9) |
| R13 | AI-only 검수의 맹점 | 틀린 영어·뜻 출시 | 독립 검수 + Hydrogen 표본 각각 심은 오류 ≥ 9/10, 오류 신고, 정직한 표기 |
| R14 | 한 파일 두 소유자 규칙(검사기 한계) | 작업 순서 꼬임 | 파일당 소유자 1(§3.2), W1 은 안내 문구 부분 문자열을 지켜 P1 파일을 안 고침 |
| R15 | Sol 6.2 한도 | 병합 지연 | 높음 등급은 `reviewer` 대체 + 오케스트레이터 핵심 명령 재실행, 사실을 기록 |
| R16 | 옛 PC 서버(2.1.0 전)·PI-L 없는 폰에서 이야기 | 맥락 없는 AI | 응답에 `level` 없으면 대본 모드(ST-4) |
| R17 | 밑줄 낱말 누르기(RichTextLabel meta)가 폰에서 안 될 수 있음(추측) | 뜻을 못 봄 | 실기 H16, 안 되면 말풍선 아래 "모르는 낱말: …" 칩(2.1.1) |

### 7.2 일부러 틀린 입력으로 확인할 실패 시나리오
| # | 입력 | 기대 | 담당 조건 |
|---|---|---|---|
| F1 | `forms_add` 같은 주·틀린 문형·틀린 형태 | SCHEMA/FORM_SUSPECT | K1R-6 |
| F2 | 안전 대사에 수동·미래 낱말, 이야기 줄 미래 낱말 | ORDER | K1R-6, A-8 |
| F3 | 기억 문장에 `555-1234`·허용 밖 이름 | PERSONAL | K1R-6, A-8 |
| F4 | R2 id 범위 밖·배정 합계 틀림 | SCHEMA/COUNT | K1R-6 |
| F5 | R2 범위 상수를 699 로 변이 | 시험 FAIL | K1R-8 |
| F6 | 20주 문장에 30주 낱말, 매니페스트 해시, 수준표 토큰 o 변경 | 린터·시험 FAIL, `same=N-1` | KBR-7 |
| F7 | 심은 오류 10개(검수·표본) | ≥ 9 적발, 아니면 결과 불신 | X3-2, HS-2 |
| F8 | OOV 고집 엔진·61초·한도 오류 | 안전 대사·재요청 0 | S1-3, PIL-5 |
| F9 | `MAX_ATTEMPTS` 1·시간 조건 9999 변이 | FAIL | S1-7, PIL-6 |
| F10 | 기억에 화이트리스트 밖 줄·이메일·9줄·501자 | 버림·8줄·500자 | S1-5, ST-2 |
| F11 | 도움 121자·`course` 없음·요약 enum 밖 | 400·`""` | S1-6 |
| F12 | 첫 요청 오류·`level` 없는 응답 | 대본 모드, 요청 1 | ST-4 |
| F13 | 이야기 파일에 글이 섞였는지(표식) | 0 | ST-3 |
| F14 | 꺼진 상태 녹음 저장 10번 | 0바이트 | B1-2 |
| F15 | 작은 한도로 넘침 / `RATE` 48000 변이 | `full` / FAIL | B1-3, B1-8 |
| F16 | 모든 기록 지우기 뒤 녹음 | 그대로 | B1-4, W1-4 |
| F17 | 신고 201개째·`MAX` 변이 | `full` / FAIL | RP-2, RP-4 |
| F18 | 새 키 없는 DayPlan 무작위 2,000 / U10 조건 변이 | 같음 / FAIL | CU-2, CU-6 |
| F19 | 코스 모드 쉐도잉 요청 / o 비교 변이 | 요청 0 / FAIL | P1-3, P1-5 |
| F20 | 미션 `fits` 비교 변이 / 독립 문장 | FAIL / 적중 ≥ 90% | M2-8, M2-7 |
| F21 | AI 미션 시작 주 25 → 1 변이 | FAIL | W1-7 |
| F22 | 소유권: after 삭제·겹침·없는 mod·이미 있는 new·F2 미제외 기준 | `FAIL`, 종료 1 | X-9, §3.3 |
| F23 | 프로토타입 검사에 미래 낱말 3개 | 실패 줄 | SP-3 |

---

## 8. 오케스트레이터가 정할 것 (추천 포함)
| # | 항목 | 선택지 | 추천 |
|---|---|---|---|
| D-1 | 관문 G1 | A: 2.0.2 공개 뒤 / B: 2.0.2 8파 시작 때 `release/2.0.2` 가지를 만들고 main 에 2.1.0 병합 허용(v202 D-15 와 같은 방식) | **B**. 4파를 2.0.2 공개 날짜와 떼어 낼 수 있다 |
| D-2 | 1~16주 낱말의 새 활용형 | A: R1 파일 `forms` 에 추가 / B: 17~32주 파일 `forms_add`(새) | **B**. R1 원고 변경 0·작가별 소유권 깔끔 |
| D-3 | 이야기 기억 | A: 원고 템플릿 + AI 는 enum 선택만 / B: AI 자유 요약 + 필터 | **A**(D7 A 를 가장 엄격하게 구현, 저장 글 0) |
| D-4 | 이야기 대화 화면 | A: `StoryView` 자체 대화(ST, 기존 파일 0) / B: `TalkView` 이야기 모드(W1 이 크게 고침) | **A** |
| D-5 | 녹음 비교 기준 문장 5개 | 추천 `s0266 s0176 s0443 s0687 s0522` / 다른 R1 문장 | **추천안**(이미 검수된 문장, 새 검수 0) |
| D-6 | 수준 상수 | 기본: 17~32주 문장당 12낱말·2문장·OOV 1·최대 3회·60초·최근 8주 | **SP 뒤 확정**. SP 최종 통과율 < 80% 면 OOV 2 또는 낱말 14 를 먼저 시험 |
| D-7 | S1 병합 시점 | A: G1 과 같이 / B: 그 전(`--check` 0 이면) | **A**(2.0.2 시험에 영향 0 보장) |
| D-8 | 녹음 저장 | 16 kHz 줄임·15초·20 MiB·가득 차면 거절 + 중간 정리 / 원본 레이트 | **추천안** |
| D-9 | 따라잡기 | U8+U9+U10 / U8+U9 만 | **셋 다**(U10 은 하루 최대 1칸, 15분) |
| D-10 | BG 배지 | 5파가 2027-01-14 까지 시작되면 포함 / 2.1.1 | **조건부 포함**(D5 A) |
| D-11 | FXR | 포함 / 제외 | **포함**(파일 1개, 겹침 0) |
| D-12 | Harbour Hostel | from_w 34 → 17 / 새 이름 | **34 → 17**(기획 그대로, 가상 이름) |
| D-13 | 문장 id 예산 | 작가 250(주 48~60) / R3 범위 일부를 R2 로 | **250 유지**. A5 파일럿 사용률이 92% 를 넘으면 그때 재검토 |
| D-14 | 모든 기록 지우기와 이야기·신고 | 녹음처럼 따로 지우기 / 함께 지우기 | **따로**(일기·녹음과 같은 규칙, 확인 글에 명시) |
| D-15 | 이야기 열림 | 코스 주 기준 부드러운 잠금 / 앞 장면 완료 필수 | **부드러운 잠금**(건너뛰면 바로 앞 장면 기본 기억 1줄) |
| D-16 | 도움 시작 | 15초 + 언제든 직접 누르기 / 15초만 | **둘 다** |
| D-17 | 받아쓰기 문장 | `say` 있는 문장 제외 / 포함 | **제외**(숫자 입력 모호함) |
| D-18 | versionCode | 20100 | 20100 |
| D-19 | 검토자 대체 | Sol 한도 시 `reviewer` + 핵심 명령 재실행 | 기획 §5.2 그대로 |

---

## 9. 사용자에게 필요한 것
| 시점 | 무엇 | 시간 | 미루면 |
|---|---|---|---|
| 2파(SP) | PC 에서 OpenCode(무료 DeepSeek) 연결이 살아 있는지 — 오케스트레이터가 확인 요청할 때 앱 설정의 "AI 연결" 상태만 알려 줌(키 불필요) | 1분 | SP 미검증, 상수는 기본값 |
| 선택 | §8 중 체감이 큰 것(D-9 하루 1칸 더, D-14 지우기 범위, D-5 기준 문장)만 확인 | 2분 | 추천안으로 진행 |
| 선택 | Hydrogen 표본 중 일부(예: 30행)를 직접 훑어보기 — 필수 아님(D3 A) | 5~10분 | "사람 검수 없음" 그대로 |
| 6파(T 통과 뒤) | ★**실기 H14~H20**(§4.2): APK 덮어쓰기 → 17주 레슨 → 폰 이야기 2회(도움 3단계) → 녹음 비교 켜기·녹음·듣기·지우기 → 쉐도잉·받아쓰기 → 신고 → 비행기 모드 이야기 | 35~45분 | 2.1.0 공개 보류 |
| 6파 | 폰 AI 키는 2.0.2 에서 넣은 것을 그대로 씀(새 키 불필요). 키를 채팅에 붙이지 않음 | - | - |

---

## 10. 확인한 것 / 추측

### 10.1 확인한 것(코드 읽기·직접 실행)
- 17~32주 수량(능동 400·수동 224·문형 64·월말 4주·캐나다 노트 13)과 배정표·문형 설명이 아직 없다는 것(S1), 수량 규칙이 `DEFAULT_LIMITS` 이고 §2.3 표의 모든 주가 그 범위 안이라는 것(능동 25~26 ∈ 10~30, 32주 12 ∈ 10~16, 수동 14 ∈ 8~16, 문형 4~5 ∈ 3~5, 32주 3 ∈ 0~3)(S3).
- R1 실적(문장 991, 5~16주 평균 64.3, 평균 길이 4.0~5.4, Tatoeba 0)과 R2 문장 id 예산 1000(S2) → 작가 250 상한의 근거.
- 린터의 R1 고정 지점과 그것을 단언하는 기존 시험(S4), 정책의 Harbour Hostel 34주(S5), R1 의 뒤 주 활용형 93건(S6).
- `CourseData` 가 주 레코드 모르는 키를 보존(S7), `LexiconGuard` 토큰 규칙(S8), 서버 `/chat` 구조·2회 시도·502·pydantic 모르는 필드 무시(S9), 앱 180초 제한(S10), 요청 본문(S11), 임시 안내와 그 단언·주 5 가짜 미션 단언(S12), 쉐도잉·받아쓰기 요청(S13), 미션 공개 모양·팩 동일성 단언(S14), 녹음 결과가 기기 레이트 그대로(S15), 시험 가드·일기 저장소 본보기(S16), 모든 기록 지우기 확인 글 위치(S17), DayPlan 늦음 계산·스냅샷 위치(S18), 플레이어 항목 id·월말 저장(S19), 배지 25 단언(S20), 황금 생성기 방식(S21).
- OWN 블록 소유권 검사(§3.3): 결합 기준 289줄, `only` 20작업으로 `files 117 dirs 2 tasks 22 ordered 48 OK`(종료 0), `only` 없이 2.0.2 미생성 파일 2줄 FAIL(예상), 틀린 복사본 5종 모두 FAIL·종료 1.

### 10.2 추측(실행·실측으로 확인하지 못함)
- 2.0.2 의 실제 코드가 v202 설계 계약대로라는 것(`AiChatRules` 함수 이름, `StudyLog.rest_days`, PI2c sha 상수 위치) — G2 시점에 작업자가 기준선으로 확인.
- R2 문장 평균 길이 6~7낱말, 주당 600~700 영어 낱말, 검수 항목 약 2,200, 출시 데이터 1~32주 합계 1 MB 안팎·3 MB 이하.
- AI 준수율(기획 목표 70%/90%/≤10%), 재요청이 대부분 60초 안에 끝난다는 것.
- 갤럭시 S24 마이크 48 kHz, 16 kHz 줄임 뒤 5초 ≈ 160 KB → 20 MiB 에 약 130개.
- `CourseLevels.derive` 의 폰 소요 시간(PC ≤ 300 ms 목표), RichTextLabel 밑줄 누르기의 폰 터치 동작.
- `build_phone_pack.py --only content` 가 다른 팩 파일을 건드리지 않는다는 것(M2-3 이 확인).
- 일정: 2파 12월 초~중, 3파 12월 말, 4파 1월 초, 5파 1월 중, 공개 1월 하순(기획 §5.2 기준, 2.0.2 진행에 달림).

## 11. 오케스트레이터 확정 (2026-11-27)
- §8 의 D-1~D-19 는 모두 **추천안대로 확정**한다(D-1 은 2.0.2 8파 시작 때 `release/2.0.2` 브랜치를 만들고 그 뒤 main 에 2.1.0 병합 허용, D-6 수준 상수는 SP 결과로 확정, D-10 BG 는 2027-01-14 까지 5파 시작 시에만, D-12 Harbour Hostel 17주부터, D-13 문장 id 예산 작가당 250·주당 48~60, D-14 '모든 기록 지우기' 뒤에도 녹음·이야기 기억·신고 기록 유지 등).
- **SP(실제 AI 호출 스파이크)** 는 사용자의 PC AI 연결로 실제 외부 호출을 하므로, 시작 직전에 사용자에게 한 번 확인한다(키는 다루지 않음).