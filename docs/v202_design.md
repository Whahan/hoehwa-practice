# v2.0.2 상세 설계: 폰 AI 직접 연결(P-AI), 연속 기록 '쉬는 날', 2.0.1 뒤 정리

- 작성: designer(Opus 5.5, 설계만. 코드·설정 수정 없음) / 기준 커밋: `3407a82`(main, 2026-11-27)
- 상위 문서: `docs/v201_plan.md` §1.2·§2.1(5~8파)·§3·§6(최상단 기획, 사용자 승인), `docs/v200_phone_design.md` §2(폰 AI 원설계. 이 문서는 그 문서를 바꾸지 않고 **바뀐 점과 확정값만** 적는다), `docs/v201_design.md`(형식·공통 명령·OWN 형식을 그대로 본뜸), `ROADMAP.md` "외부 제안에서 받은 것"·"v2.0.1 알려진 한계", `WORKLOG.md` 끝(2.0.2 후보 4건), `REVIEW.md`, `docs/v200_design.md` §14.1(C-0~C-17).
- 표기: **(추측)** = 코드·실행으로 확인하지 못한 가정. **(새)** = 이번에 새로 만드는 파일·함수·필드. **★** = 사용자 확인·행동이 필요한 항목. **[PI0 뒤 확정]** = PI0(실제 키 1회 시험) 결과로 바뀔 수 있는 값(전부 `AiPresets` 한 곳에 모은다). 경로는 저장소 루트 `D:\Ai\언어\app` 기준. "§2.4(폰)" 은 `docs/v200_phone_design.md` 의 절, "§5.0(201)" 은 `docs/v201_design.md` 의 절.
- 담당: **모든 구현 작업은 `worker-hard`(Sonnet 5.5)**, **코드 검토는 Sol 6.2(Orca codex `gpt-6.2-sol`, effort high)**. Sol 이 이 PC 에서 시험을 못 돌리는 경우에만 `reviewer`(Sonnet 5.5)가 대신하고 오케스트레이터가 그 사실을 WORKLOG·릴리스 노트에 적는다. 검토자는 `REVIEW.md` 를 먼저 읽고 §5 의 PowerShell 명령을 그대로 실행한다.

## 0. 근거·목표·범위

### 0.1 읽은 것 / 실행한 것 / 확인하지 못한 것
- **읽은 것**: `docs/v201_plan.md` 전체, `docs/v200_phone_design.md` §0·§2·§3·§5·§6.9~6.19·§7~§9, `docs/v201_design.md` 전체, `docs/v200_design.md` §14.1, `REVIEW.md`, `ROADMAP.md` 60~231행, `WORKLOG.md` 끝 9 KB. 코드: `godot/scripts/core/streak_calc.gd`(전체), `study_log.gd`(머리·`apply_sync`·`_prune_for_save`·`_norm_freeze`·`settle`·`longest_streak`·`frozen_days`), `ui/goal_card.gd`(`_build`), `ui/home_parts.gd`(`snapshot`·`Stone`·`stone_states`·`stones`·`streak_card`), `core/plan.gd`(`weekday`·`monday_of`), `core/badge_engine.gd`(40행), `core/badge_defs.gd`(83~85행), `sync/sync_doc.gd`(머리·`SHARED_PREFS`·`pref_valid`), `autoload/route.gd`(1~130행·`decide`·`why_none`), `autoload/local_api.gd`(1~200행), `autoload/api.gd`(`FALLBACK_POST`·`_can_fall_back`·`_fall_back`·`_run_phone`·`cancel`), `autoload/backend.gd`(40~100행), `autoload/tts.gd`(95~135행), `local/system_tts.gd`(speed 부분), `views/settings_view.gd`(40~80·250~300·320~362·500~560·884~906행), `ui/capability_panel.gd`(1~80행), `practice/diary_screen.gd`(1~77·150~240·320~480행), `practice/mission_screen.gd`(385~400·715~730행), `core/home_ai.gd`(전체), `ui/ai_connect_sheet.gd`(`home_slot`·`is_phone`), `main.gd`(225·231·233·553~562·636~650·970~984행), `core/platform.gd`, `packaging/installer/update.ps1`(1~40·80~90·144~260행), `packaging/release.json`, `packaging/build_dist.ps1`(173행), `packaging/sanitize_prefs.py`, `godot/tests/model_store_test.gd`(39·163~240·463·647·708·713·924행), `godot/tests/stt_model_card_test.gd`(295~345행), `godot/tests/run_model_tests.ps1`(1~40·100~230행), `godot/tests/lifecycle_test.gd`(1~60·230~300행), `views/reading_view.gd`(46·263행), `godot/tests/course_today_test.gd`(1544행), `phone_src/tools/calib_record.py`(463~572행), `calib_pc_run.py`(30~70행), `godot/tools/calib_phone.gd`(머리·87~145행), `phone_src/tools/make_ai_golden.py`(머리·140~260·333~370행), `backend/llm_api.py`(1~230행), `backend/server.py`(242~253·1619~1660행·699행), 시험 파일들의 관련 단언(`home_view_test` 561~612, `stats_view_test` 201·484·522, `ai_connect_test` 283·300~315·660~745, `diary_screen_test` 412·1061, `diary_flow_test` 456, `streak_test` 머리).
- **실행한 것(읽기 전용)**: `git log`·`git status`, 위 파일 검색, PI2a 황금 파일 통계(`make_ai_golden.py --list`: 462사례, 아래 S15), 황금 오류 결과 집계(아래 S15), `backend/content/missions.json` ↔ `godot/data/pack/missions.json`·두 `curriculum.json` sha256 비교(같음), 세 설계 문서 OWN 블록의 기존 소유자 조회, **이 문서 OWN 블록의 소유권 검사**(§3.3, 정상 1회 + 일부러 틀린 복사본 4종). 내려받기·설치·네트워크 접근·키 파일 열람은 하지 않았다.
- **확인하지 못한 것**: PI0 결과 전부(OpenCode Zen 유료 엔드포인트, `json_object` 지원, `single_system` 필요성, Gemini 최신 모델 id, OpenRouter 기본 모델), Godot 4.6.3 `HTTPRequest.max_redirects = 0` 일 때 3xx 응답이 `RESULT_REDIRECT_LIMIT_REACHED` 로 오는지 응답 코드 3xx 로 오는지(시험이 둘 다 오류로 다룬다), 안드로이드에서 `OS.get_unique_id()` 가 앱 재설치·업데이트 뒤에도 같은지(추측: 같은 서명 키면 같다), 안드로이드에서 `DisplayServer.clipboard_get()` 동작(추측: 된다), Godot 가 안드로이드에서 TLS 인증서를 무엇으로 검증하는지(추측: 엔진 내장 CA 묶음), 2.0.1 실기 H2~H5 결과(아직 안 함).

### 0.2 목표와 범위
- **목표**: `docs/v201_plan.md` §1.2 의 완료 기준 1~4 를 만족하는 2.0.2 를 공개한다. 더해서 (1) 연속 기록 '쉬는 날'(ROADMAP 외부 제안, 사용자 승인), (2) 2.0.1 뒤 작은 정리 5건(녹음 세트 접두사, 업데이터 태그 필터, 모델 시험 부재 단언 정착, `lifecycle_test` 격리, 듣기 속도 범위).
- **넣을 것**: PI1, PI2b, PI2c, PI3, PSI(+ 속도 범위 (e)), PWI, PZ, RD(쉬는 날), FXA·FXB·FXC·FXD(정리 (a)~(d)).
- **하지 않을 것**
  - 2.1.0 범위: 수준 맞춤 AI 대화(`course` 필드·`level_check`·`help_ko`, PI-L), 이어지는 이야기 회화, 내 녹음 비교, 서버 `/chat` 변경. 폰 `/chat` 은 받은 `course` 필드를 무시하고 기존 `stage` 를 쓴다.
  - 일본어 AI(`ja_ai_pc` 안내 유지), AI 레슨·노래 AI·읽기 문맥 뜻풀이 AI.
  - Android Keystore 연동(K-스파이크), 중계 서버·공용 키, PC 앱에 폰 키 저장, **사용자 지정 base URL 입력**(§8 D-7), `max_tokens` 상한(§8 D-8).
  - 서버(`backend/`)·동기화(`godot/scripts/sync/*`, `SyncDoc.SCHEMA`·`SHARED_PREFS`)·`godot/project.godot`·`route.gd`·`api.gd`·`local_api.gd`·`store.gd` 변경, 새 autoload·새 권한.
  - 네이티브 `abort` 기대 세대 인자(D-7(201) 근본 수정): 네이티브 재빌드가 필요해 **기본은 빼고** 오케스트레이터 결정 항목으로만 둔다(§8 D-4).
  - "모든 기록 지우기" 확인 문구 변경(`sync_panel.gd` 소유 금지). 대신 AI 카드에 "모든 기록 지우기는 AI 키를 지우지 않아요" 한 줄.
  - 쉬는 날의 **소급 적용**(과거 끊긴 연속을 다시 계산)과 쉬는 날 개수 설정 화면(§8 D-1·D-2).
  - 버전 올리기·릴리스·PI0 실행(오케스트레이터 몫, §6).

### 0.3 지금 main 에서 확인한 사실(설계 근거)
| # | 사실 | 위치 |
|---|---|---|
| S1 | `StreakCalc.settle(done, frozen, tokens, awarded, today)` 는 순수 계산. 마지막 공부일 `prev` 와 오늘 사이 빈 날 `gap` 을 `tokens + 그 틈에 이미 있던 frozen 수` 로 메울 수 있으면 전부 frozen 으로 잇고, 못 메우면 그 틈의 frozen 을 지우고 쓴 보호권을 돌려준다. 보호된 날은 연속 일수에 안 센다. `MAX_TOKENS := 2`, `MILESTONE := 7`. 시계가 과거로 가면 아무것도 안 바꾼다 | `godot/scripts/core/streak_calc.gd` 17~101행 |
| S2 | 보호권 상태는 `studylog.json` 의 `freeze.<lang> = {tokens, frozen:[iso], awarded, last}`(처음 tokens 1). `_norm_freeze` 는 **이 네 키 밖의 키를 버린다**. `frozen` 은 400일보다 오래되면 저장 때 지운다. `StudyLog.settle` 은 `last` 로 시계 되돌림을 막고, 보호권을 쓰면/받으면 토스트 1번 | `study_log.gd` 14·214~233·384~403·1218~1245행 |
| S3 | 보호권은 **동기화하지 않는다**: `SyncDoc` 머리 주석, `StudyLog.apply_sync` 는 `days/phon/missions` 만 바꾸고 `freeze` 는 그대로 둔다. 공부한 날(`progress.days`)은 동기화로 합쳐진다 | `sync/sync_doc.gd` 8행, `study_log.gd` 151~168행·1200행 |
| S4 | 배지 `streak_best` = `StudyLog.longest_streak` 최댓값. `longest_streak` 는 frozen 날을 다리로만 쓰고 세지 않는다 | `badge_engine.gd` 40행, `study_log.gd` 1259~1290행, `badge_defs.gd` 83~85행 |
| S5 | 화면: 목표 카드 설명 글(1개 문장 묶음)과 칩 "연속 N일"·"보호권 N개", 홈 연속 카드의 알약·보호권 칩·이번 주 돌 7개(`done/today/frozen/missed/future`). 시험 단언: `stats_view_test` 522행이 설명에 "보호권 개수보다 많은 날을 놓치면"·"보호권은 그대로 남아요" 를 요구, `home_view_test` 612행이 "토요일에 금요일이 missed" 를 요구 | `ui/goal_card.gd` 48~85행, `ui/home_parts.gd` 255~281·425~505행 |
| S6 | 주 계산 함수가 이미 있다: `Plan.weekday(d)`(1970-01-01 목요일 기준), `Plan.monday_of(d)` | `core/plan.gd` 81·115행 |
| S7 | 듣기 속도: `Tts.normal_speed()` 가 `[0.6, 1.3]` 으로 자르고 `SLOW_SPEED := 0.75`. 설정 슬라이더도 `0.6~1.3`. **서버 합성(`synth_wav`)이 `[0.6, 1.3]` 으로 자른다**(서버 변경 금지). 폰 시스템 음성은 `DisplayServer.tts_speak(..., rate, ...)` 로 그대로 넘긴다. `tts_speed` 는 동기화되는 설정이고 `SyncDoc.pref_valid` 는 `0.1~5.0` 을 받는다 | `autoload/tts.gd` 14·114~115행, `views/settings_view.gd` 331~356행, `backend/server.py` 699행, `local/system_tts.gd` 38~40행, `sync_doc.gd` 11~12·191행 |
| S8 | 업데이터: `channel:"stable"` 이면 `releases/latest`, 아니면 `releases?per_page=10` 에서 **draft 가 아닌 첫 릴리스**를 고른다(태그 모양 검사 없음). `Parse-Ver("models-1")` 은 `0.0` → "최신 버전입니다" 로 조용히 넘어간다. 파일은 UTF-8 BOM, 업데이트 zip 에 BOM 으로 복사된다 | `packaging/installer/update.ps1` 80~85·144~174행, `packaging/build_dist.ps1` 173행 |
| S9 | `model_store_test` 의 부재 단언 5곳(463·647·708·713·924행)은 `_frames(n)` 뒤 즉시 `_log(tok).size()` 를 본다. 카드 시험에는 이미 `_inflight()`(서버가 원자적으로 쓰는 `inflight.txt`)·`_settled_count()` 가 있다. 러너는 `MODEL_SRV_LOGDELAY` 를 **카드 시험 서버에만** 건다 | `godot/tests/model_store_test.gd`, `stt_model_card_test.gd` 302~345행, `run_model_tests.ps1` 14~16·118·196행 |
| S10 | `lifecycle_test` 의 `_test_reading_scroll` 은 `ReadingView.new()` 를 `storage_dir` 를 바꾸지 않고 붙인다. `ReadingView.storage_dir` 기본값은 `user://reading`(읽을 때 폴더를 만든다). `course_today_test` 1544행은 `user://reading` 이 없어야 한다고 단언 → 같은 APPDATA 에서 이어 돌리면 실패(2.0.1 T-4 의 4회 실패 원인) | `godot/tests/lifecycle_test.gd` 238~252행, `views/reading_view.gd` 46·263행 |
| S11 | 녹음 도구 클립 id 는 `"u%02d_%s" % (k, kind)` 고정. 뒤 도구(`calib_pc_run.py`, `calib_phone.gd`, `calib_fit.py`)는 id 를 자유 문자열로만 쓴다(중복만 거절) | `phone_src/tools/calib_record.py` 516행, `calib_pc_run.py` 47~51행, `calib_phone.gd` 98~109행 |
| S12 | P0 덕분에 `Route` 에 폰 AI 오류 코드·문구가 이미 있다(`no_ai` "설정 > AI 연결에서…", `ai_offline/ai_tls/ai_model/ai_url/ai_key_format/ja_ai_pc/ai_auth/ai_limit/ai_overload/bad_format`). AI 경로 정책은 `prefer:"pc"`, `phone:"ai"` | `autoload/route.gd` 42~121행 |
| S13 | `LocalApi.HANDLERS["ai"] = "res://scripts/local/local_ai.gd"`(파일 없음 → 지금은 `needs_pc`). 핸들러는 경로로 `load()` 하고 `is_available_for` 가 있으면 그것을 쓴다 | `autoload/local_api.gd` 20~27·103~118행 |
| S14 | **자동 모드에서 PC 가 전송 실패하면 `/chat`·`/fix`·`/feedback`·`/missions/judge` 도 폰으로 한 번 넘긴다**(`FALLBACK_POST`, `_can_fall_back` 은 `LocalApi.available` 만 본다). 폰 AI 가 생기면 일기 `/fix` private 가 PC 동의만 받은 채 폰 업체로 갈 수 있다 → `LocalAi.is_available_for` 가 일기 폰 동의를 반드시 확인해야 한다(§2.3) | `autoload/api.gd` 45·344~368행 |
| S15 | PI2a 황금 파일 11개(`godot/tests/fixtures/ai_golden/`), 462사례: api 40, chat 68, clean_hist 20, context 16, extract_json 32, feedback 28, fix 41, judge 35, ko 80, norm_text 38, question 46, rules 18. 엔진 사례 기록 = `{messages, schema, temperature, num_predict, reply|error{kind,msg,status}}`, 결과 = `{result}` 또는 `{error:{status,msg,code,format_error}}` + `attempts`. 오류 결과의 `code` 는 `ai_limit/ai_auth/ai_overload/ai_not_connected/""`. **api 사례의 HTTP 응답 대본은 `phone_src/tools/ai_golden_cases.json` 에만 있다**(출력 파일에는 요청 기록·결과만) | 직접 집계 |
| S16 | 서버의 API 키 엔진 경로는 `llm_api.call_json(CFG, messages, schema, temperature, timeout=120)` — `num_predict` 는 버리고 `max_tokens` 를 보내지 않는다. 스키마 지시를 **마지막 system 메시지**로 붙이고 `response_format:{"type":"json_object"}`, 400 응답에 `response_format/json/not support` 가 있으면 빼고 1번 다시, 그 (base,model) 은 이후 JSON 모드 끔. 오류 분류 순서: free tier 문구 → 401/403 → 402/429/quota·insufficient·balance·rate limit → 404/모델 문구 → 500/502/503/504/529 → 그 밖 | `backend/llm_api.py` 28~41·103~180행, `server.py` 1619~1638행 |
| S17 | `backend/content/missions.json` = `godot/data/pack/missions.json`, `backend/curriculum.json` = `godot/data/curriculum.json`(sha256 같음) → 폰 프롬프트·판정 데이터가 서버와 같다 | 직접 계산 |
| S18 | 일기: AI 가능 판정이 PC 만 본다(`ai_state()` 가 `caps.fix.use == "pc"`·PC `llm`), `fix_private_ok()` 는 PC `/health` 의 `fix_private`. 동의 pref `diary_consent`(PC 문구 "이 PC의 로그·캐시"). 요청은 언제나 `SpeakDrill.request("/fix", {…, "private": true})` | `practice/diary_screen.gd` 21~33·154~178·386~440행 |
| S19 | 미션: `_llm_down()` = `Backend.llm_missing()`(PC `/health` 가 READY 일 때만 참). 시험 훅 `llm_override` | `mission_screen.gd` 391~394행, `backend.gd` 50~57행 |
| S20 | 홈 AI 자리(폰): READY + PC AI 없음이면 "PC의 회화 연습 설정에서…", 버튼 없음. `ai_connect_test` 670행이 "폰 홈 자리는 버튼 없음 + 'PC' 포함" 을, 710~716행이 "폰에서 [AI 연결하기]는 시트를 열지 않고 문장 토스트" 를 단언 | `ui/ai_connect_sheet.gd` 109~119행, `godot/tests/ai_connect_test.gd` |
| S21 | 폰 앱은 언제나 `settings.standalone_panels = _phone` → 설정 "엔진" 구역에 `SttSection`·처리 위치·기능 현황이 있고 AI 카드는 없다(PC 는 `AiConnectCard`) | `main.gd` 225행, `settings_view.gd` 259~267행 |
| S22 | `CapabilityPanel.REASONS["no_ai"]` = "AI 연결이 필요해요. PC에 연결하거나 AI 키를 넣어 주세요."(2.0.1 결정 1 로 유지) | `ui/capability_panel.gd` 45행 |
| S23 | `Platform.is_phone()` 은 안드로이드 **또는** 데스크톱 시험 인자 `--phone` | `core/platform.gd` 9~10행 |
| S24 | `sanitize_prefs.py` 는 이름이 `_consent` 로 끝나는 설정을 공개 기본값에서 지운다 | `packaging/sanitize_prefs.py` 18행 |
| S25 | 2.0.1 은 구현·병합 끝, 실기 H2~H5·`models-1` 업로드·공개는 남음(main = 2.0.1, versionCode 20001) | `ROADMAP.md` 93행, `WORKLOG.md` 끝 |

### 0.4 v200_phone_design §2 대비 바뀐 점(요약)
| 항목 | v200 폰 설계 | 2.0.2 확정 |
|---|---|---|
| 담당 | PSI 는 `worker` | **전부 `worker-hard`**, 검토 Sol 6.2 |
| JSON 황금 | PI1 이 `make_ai_json_golden.py`·`ai_json_golden.json` 을 새로 | **PI2a 의 `extract_json.json`(32)·`api_call.json`(40) 을 그대로 쓴다**(새 생성기 없음, §8 D-6). 기획 완료 기준 4 의 `make_ai_json_golden.py --check` 는 `make_ai_golden.py --check` 로 대신 |
| 엔진 계약 | `AiClient.complete_json` 을 규칙 코드가 직접 | 규칙 코드는 **엔진 Callable**(`(messages, schema, temperature, num_predict) -> 결과`)만 받는다. 시험은 황금의 엔진 대본을 그대로 재생하는 가짜 엔진을 꽂는다(§2.2) |
| 결과 대응 | 미정 | 서버 결과 ↔ 폰 결과 **대응표 R-MAP**(§2.2) 고정. 시험 도우미 `ai_golden_util.gd`(PI1 소유) 한 곳에 구현 |
| `max_tokens` | 상한으로 보냄 | **보내지 않는다**(서버와 같음, 황금 일치. §8 D-8) |
| 타임아웃 | 90초 | **120초**(서버와 같음) |
| 사용자 지정 주소 | 확인 문구와 함께 허용 | **2.0.2 에서는 없음**(프리셋 4개 + 모델 이름만 바꿈, §8 D-7) |
| prefs | `ai_local`·`ai_preset`·`ai_model`·`ai_base_url`·`phone_ai_consent`·`phone_diary_trains_ok` | `ai_preset`·`ai_model`·`phone_ai_consent`·`phone_diary_consent`(새)·`phone_diary_trains_ok`·`ai_req_day`(새). `ai_local`·`ai_base_url` 없음 |
| 홈 AI 자리 | 폰에 키가 없으면 [AI 연결하기] 버튼 | 버튼은 그대로 없음(`ai_connect_test` 670행 유지), 문구만 "설정 > AI 연결…"(§2.7). 메뉴·배너·`Store.request_ai_connect` 는 폰에서 `PhoneAiSheet` 를 연다 |
| `home_ai.gd` | PWI 가 수정 | **수정 없음**(`AiConnectSheet.home_slot` 만 바꿈) |
| 실기 | adb 전제 | 앱 안 확인 우선(H8 은 `SttDiagSheet` 의 `user_dir_internal`, logcat·run-as 는 USB 가 될 때만, 아니면 "미검증", 기획 결정 6) |
| 소유권 검사 | v200 OWN 한 개가 기준 | **세 문서 OWN 을 합친 기준 파일**(§3.3)로 기존 검사기를 그대로 돌린다 |

---

## 1. 범위 확정표

| id | 내용 | 2.0.2 | 담당 | 파 | 비고 |
|---|---|---|---|---|---|
| PI0 | 실제 키 1회 시험(엔드포인트·JSON 모드·system 위치·모델 id) | 넣음(공개 전 게이트) | 오케스트레이터 + ★사용자 키 파일 | 0 또는 5파 중 | §6.1. PI1 은 PI0 없이 시작·병합 가능, **공개는 PI0 뒤** |
| PI1 | `AiSecrets`·`AiPresets`·`AiClient`·`AiJson`·`AiState` + 시험·가짜 서버·황금 도우미 | 넣음 | worker-hard | 5 | §2.1, 위험 높음 |
| RD | 연속 기록 '쉬는 날'(주 최대 2일, 보호권 없이) | 넣음 | worker-hard | 5 | §2.8 |
| FXA | 녹음 도구 세트 접두사(D-5(201)) | 넣음 | worker-hard | 5 | §2.9 |
| FXB | `update.ps1` 비안정 채널 태그 필터 `^v\d`(O-9(201)) | 넣음 | worker-hard | 5 | §2.10, 위험 높음(업데이터) |
| FXC | `model_store_test` 부재 단언 로그 정착 대기 | 넣음 | worker-hard | 5 | §2.11 |
| FXD | `lifecycle_test` 의 `user://reading` 격리 | 넣음 | worker-hard | 5 | §2.12 |
| PI2b | `LocalAi`(핸들러) + `AiChatRules`(`/chat`·`/fix`) | 넣음 | worker-hard | 6 | §2.3, 위험 높음 |
| PI2c | `AiFeedbackRules`(`/feedback`·`/missions/judge`) | 넣음 | worker-hard | 6 | §2.4 |
| PI3 | 설정 "AI 연결(이 폰)" 카드·키 입력 시트·업체 동의 시트 | 넣음 | worker-hard | 6 | §2.5, 위험 높음 |
| PSI | 설정 연결·기능 현황 문구 + **듣기 속도 범위 (e)** | 넣음 | worker-hard | 7 | §2.6. `settings_view.gd` 의 유일한 소유자라 (e) 를 여기에 묶는다 |
| PWI | 일기 폰 경로·폰 동의·무료 학습 업체 기본 꺼짐, 미션 AI 모드, 홈 자리·메뉴·배너·시작 화면 문구 | 넣음 | worker-hard | 7 | §2.7, 위험 높음 |
| PZ | README·ROADMAP·INSTALL 의 2.0.2 절 | 넣음 | worker-hard | 8 | §2.13 |
| D7N | 네이티브 abort 기대 세대 인자 | **기본 뺌**(§8 D-4) | - | - | 넣기로 하면 별도 설계 보충 |
| K-스파이크 | Android Keystore | 뺌 | - | - | |

---

## 2. 작업별 상세

### 2.0 공통: worktree, 임시 폴더, 비밀값 규칙
- worktree `D:\Ai\언어\app_wt\v202_<작업 소문자>`, 브랜치 `v202/<작업 소문자>`(예: `v202/pi1`). 이 문서는 분기 전에 main 에 커밋된다(오케스트레이터).
- 임시 파일: 작성자 `<scratch>\w_v202_<작업>\`, 검토자 `<scratch>\w_rev_v202_<작업>\`. `<scratch>` = `C:\Users\rtyu6\AppData\Local\Temp\claude\D--Ai----app\c5535f7a-0e1a-4bb6-bdc3-5597b7f84c22\scratchpad`.
- 네이티브(N0)는 이번 작업 어디에도 필요 없다. 통합 시험 T-3 만 §5.0(201) `Prep-Native` 를 쓴다.
- **비밀값 규칙(모든 작업자·검토자·오케스트레이터)**
  1. 실제 AI 키는 **이 문서·지시문·보고·WORKLOG·커밋·시험 픽스처·로그·채팅 어디에도 쓰지 않는다.** 실제 키를 쓰는 것은 PI0(오케스트레이터)와 실기 H7~H10(사용자 폰)뿐이다.
  2. 키 파일(★사용자가 만든다)은 저장소 밖 경로에 두고, 내용을 `Get-Content`·`type`·`cat` 으로 화면에 내지 않는다. PI0 스크립트는 파일을 **프로세스 안에서** 읽고, 출력 직전 모든 글에서 키 전체와 8자 이상 부분을 `<key>` 로 바꾼다. 키를 명령줄 인자·환경 변수 값으로 넘기지 않는다(파일 경로만 넘긴다).
  3. 시험용 가짜 키는 `FAKEKEY_ZZ_` + 영숫자 20자 이상(공개 스크립트의 `sk-…`·`AIza…` 정규식을 피한다). 일기 원문 표식은 `ZZ_MARK_9731`. 둘 다 시험 출력 파일에 **0번**이어야 하고(양성 대조는 메모리 안에서만, §5.1 X-2), 황금 api 사례가 쓰는 가짜 값 `golden-dummy-credential` 도 같은 취급(출력 0번).
  4. 가짜 서버 로그는 `Authorization` 값을 **sha256 으로만** 남긴다.

### 2.1 PI1 — 키 저장·프리셋·클라이언트·JSON·상태 (5파)
- 하는 일은 §2.3·§2.4·§2.8(폰). 바뀐 점과 확정 계약만 적는다. 파일: §3 OWN 의 PI1 줄.
- **`AiPresets`**(새, `godot/scripts/local/ai_presets.gd`, `class_name AiPresets extends RefCounted`, 정적). **[PI0 뒤 확정] 값은 이 파일 한 곳에만 있다.**
```
const PRESETS := {   # backend/llm_api.py PRESETS 의 복사(황금 api 사례와 바이트 단위로 맞춘다)
  "opencode_zen": {"label": "OpenCode Zen", "base_url": "https://opencode.ai/inference/v1", "model": "deepseek-v4.1-flash",
                   "trains_free": false, "single_system": false, "note_ko": NOTE_ZEN},
  "deepseek":     {"label": "DeepSeek", "base_url": "https://api.deepseek.com", "model": "deepseek-flash",
                   "trains_free": false, "single_system": false, "note_ko": NOTE_DEEPSEEK},
  "gemini":       {"label": "Google Gemini", "base_url": "https://generativelanguage.googleapis.com/v1beta/openai", "model": "gemini-2.5-flash",
                   "trains_free": true,  "single_system": false, "note_ko": NOTE_GEMINI},
  "openrouter":   {"label": "OpenRouter", "base_url": "https://openrouter.ai/api/v1", "model": "openrouter/auto",
                   "trains_free": false, "single_system": false, "note_ko": NOTE_OPENROUTER},
}
const ORDER := ["opencode_zen", "gemini", "deepseek", "openrouter"]   # 화면 순서. 기본 선택 없음(PD8)
const SERVER_DEFAULT := "opencode_zen"   # 모르는 프리셋 id 가 AiClient 에 오면 서버처럼 이 값(황금 api_unknown_preset). 앱 상태(AiState)는 모르는 id 를 "" 로 본다
static var PI0_OVERRIDES := {}           # [PI0 뒤 확정] {"<id>": {"base_url"?, "model"?, "single_system"?, "json_mode"?: false}}. 지금은 비어 있다
const PI0_CONFIRMED := false             # [PI0 뒤 확정] PI0 를 마치면 오케스트레이터가 true 로 바꾸는 한 줄(공개 게이트 T-0 이 확인)
static var apply_overrides := true       # 시험: false 면 서버 복사값 그대로(황금 일치 시험용)
static func ids() -> Array               # ORDER
static func preset(id: String) -> Dictionary   # 덮어쓰기 적용 뒤 값, 모르면 {}
static func label(id: String) -> String
static func is_valid(id: String) -> bool
```
  `NOTE_*` 문구(그대로): ZEN = "무료 모델은 OpenCode 프로그램 안에서만 돼요. 이 앱에서는 유료 크레딧이 필요해요. 유료 모델의 데이터 정책은 확인하지 못했어요.", DEEPSEEK = "DeepSeek 서버는 중국에 있고, API 의 데이터 정책은 문서에서 확인하지 못했어요.", GEMINI = "구글 무료 등급은 보낸 내용을 서비스 개선에 쓸 수 있다고 문서에 적혀 있어요. 개인적인 글은 유료 등급 키나 다른 업체를 쓰세요.", OPENROUTER = "모델 제공자에 따라 데이터 정책이 달라요."
- **`AiSecrets`**(새, `godot/scripts/local/ai_secrets.gd`, `class_name AiSecrets extends RefCounted`, 정적):
```
const PASS_TAG := "hoehwa-ai-v1"
const KEY_MIN := 16
const KEY_MAX := 256
static var path := "user://ai_secrets.bin"        # 시험: "user://test_ai_secrets_<이름>.bin"
static var salt_path := "user://ai_salt.bin"      # 시험: "user://test_ai_salt_<이름>.bin"
static var device_id_hook: Callable               # 시험: () -> String. 기본 OS.get_unique_id()
static func check_format(key: String) -> String   # "" = 통과 | "ai_key_format"
static func set_key(preset: String, key: String) -> Dictionary   # {ok, err_code: ""|"ai_key_format"|"bad_preset"|"not_phone"|"io"}
static func has_key(preset: String) -> bool
static func last4(preset: String) -> String       # 없으면 ""
static func clear_key(preset: String) -> bool
static func status() -> String                    # "none" | "ok" | "bad"(손상 파일을 .bad 로 옮긴 뒤)
static func get_key(preset: String) -> String     # ai_client.gd 의 헤더 조립 1곳만 부른다(PI1-16)
```
  - 파일: `FileAccess.open_encrypted_with_pass(path, …, pass)`, `pass = SHA-256(salt 32바이트 + device_id + PASS_TAG)` 의 16진 문자열. 내용 `{"v":1,"keys":{"<preset>":"<key>"}}`. 쓰기는 `path + ".tmp"` → 이름 바꾸기. 솔트가 없으면 새로 만들고, **솔트는 있는데 복호화가 안 되면** 손상으로 보고 `path + ".bad"` 로 옮긴 뒤(1개만 보관) "키 없음". 앱은 죽지 않는다.
  - `check_format` 거절: 길이 < 16 또는 > 256, 공백·탭·줄바꿈, `Bearer `(대소문자 무시) 접두, 따옴표 `"` `'`, 출력 가능 ASCII(33~126) 밖 글자.
  - `set_key` 는 `Platform.is_phone()` 이 거짓이면 `not_phone`(PC 앱은 키를 저장하지 않는다. 데스크톱 시험은 `--phone` 으로 연다, S23).
- **`AiJson`**(새, `godot/scripts/local/ai_json.gd`, 정적): `static func extract(text: Variant) -> Dictionary  # {ok:bool, data:Dictionary}` — `llm_common.extract_json` 이식. 황금 `extract_json.json` 32사례 전부 같음 + 방어 사례 ≥ 20(시험 안).
- **`AiClient`**(새, `godot/scripts/local/ai_client.gd`, `class_name AiClient extends RefCounted`, 정적 + 루트 아래 요청 노드):
```
const TIMEOUT_SEC := 120.0
const MAX_BODY_BYTES := 2000000
const MASK := "<key>"
static var test_allow_http := false     # 시험만: http://127.0.0.1:<port> 허용(다른 호스트는 여전히 거절)
static var transport_hook: Callable     # 시험: (req: {url, method, headers: PackedStringArray, body: String, timeout: float}) -> {result:int, code:int, headers:PackedStringArray, body:PackedByteArray}
static func settings_for(preset: String, model: String = "", base_url: String = "") -> Dictionary
    # llm_api.settings 와 같은 규칙: 모르는 preset -> SERVER_DEFAULT, base_url 끝 "/" 제거, model "" -> 프리셋 기본.
    # base_url 인자는 시험(황금 api_custom_model_and_base) 전용. 앱 코드(LocalAi·PI3)는 넘기지 않는다.
    # -> {preset, label, base_url, model, trains_free, single_system}
static func complete_json(messages: Array, schema: Dictionary, temperature: float, opts: Dictionary = {}) -> Dictionary   # 코루틴
    # opts: {preset, model, base_url(시험), max_tokens(시험: 황금 api_ok_max_tokens), timeout}
    # -> {ok, data:Dictionary, model:String, err_code:""|ai_auth|ai_limit|ai_model|ai_overload|ai_offline|ai_tls|ai_url|bad_format|bad_request|ai_cancelled|no_ai,
    #     error:String(Route.text_for(err_code), 고정 한국어), status:int, retry_after:int(초, 없으면 0), free_tier:bool, attempts:int, detail:String("HTTP <n>" 꼴, 본문 없음)}
static func engine_call(messages: Array, schema: Dictionary, temperature: float, num_predict: int) -> Dictionary   # 코루틴. 규칙 코드용 엔진(§2.2). 지금 AiState 의 프리셋·모델로 complete_json
static func list_models(preset: String) -> Dictionary   # {ok, ids:Array, err_code} — GET {base}/models, Gemini "models/" 접두 제거, 정렬
static func test_call(preset: String) -> Dictionary     # 짧은 요청 1번(스키마 {"ok": bool}). 횟수에 센다
static func abandon_all() -> void                        # 진행 중 요청 결과를 버린다(HTTPRequest 는 끊지 않고 고아로 두었다가 끝나면 지운다, api.gd cancel 과 같은 규칙)
static func json_mode_off() -> Array                      # [[base, model], …] 정렬(황금 json_mode_off 와 비교용)
static func reset_for_tests() -> void
```
  - **요청 본문(서버와 바이트 단위로 같게)**: `{"model", "messages": messages + [{"role":"system","content": INSTR}], "temperature", "stream": false}`, `max_tokens` 는 `opts.max_tokens` 가 참값일 때만(앱은 안 넘긴다), `(base, model)` 이 JSON 모드 끔 목록에 없으면 `"response_format": {"type": "json_object"}`. `INSTR = "Reply with ONLY one JSON object (no code fences, no extra text) that matches this JSON schema:\n" + JSON(schema, 서버 json.dumps(ensure_ascii=False) 와 같은 글자)`. 본문 비교는 §2.2 의 `canon()` 으로 한다.
  - 프리셋 `single_system == true`([PI0 뒤 확정], 지금은 모두 false)면 모든 system 메시지를 순서대로 `"\n\n"` 로 이어 맨 앞 하나로 합친다.
  - 헤더: `Content-Type: application/json`, `Authorization: Bearer <키>`(키는 `AiSecrets.get_key` 를 **이 한 줄에서만** 부른다), `User-Agent: hoehwa-practice/2`. `HTTPRequest.max_redirects = 0`, `use_threads = true`, `timeout = opts.timeout 또는 TIMEOUT_SEC`, TLS 검증은 기본값(끄지 않음).
  - 주소 검사(요청 전, 실패면 요청 0건 `ai_url`): `https://` 로 시작, 호스트에 `@`·사용자 정보 없음. `test_allow_http` 일 때만 `http://127.0.0.1:` 허용.
  - **오류 분류(규범, 서버 `_fail` 순서와 같다)**: 전송 실패 `CANT_CONNECT`/`CANT_RESOLVE`/`CONNECTION_ERROR` → `ai_offline`, `TLS_HANDSHAKE_ERROR` → `ai_tls`, `TIMEOUT` → `ai_overload`, `REDIRECT_LIMIT_REACHED` 또는 응답 3xx → `ai_overload`(따라가지 않음), 본문 > `MAX_BODY_BYTES`·`BODY_SIZE_LIMIT_EXCEEDED` → `bad_format`. HTTP 응답은 서버 `_err_text` 와 같은 방식으로 오류 글을 뽑아 소문자로: ① `freetier`/`free tier` → `ai_auth` + `free_tier:true` ② 401·403 → `ai_auth` ③ 402·429 또는 `quota/insufficient/balance/rate limit` → `ai_limit`(+ `Retry-After` 가 숫자면 `retry_after`) ④ 404 또는 `model` 과 `not found/not exist/invalid/unknown` → `ai_model` ⑤ 500·502·503·504·529 → `ai_overload` ⑥ 그 밖 400~499 → `bad_request`, 그 밖 → `ai_overload`. 200 인데 `choices[0].message.content` 가 없거나(`content` 가 배열이면 `text` 이어 붙임) JSON 추출 실패 → `bad_format`. 400 + `response_format/json/not support` 는 서버처럼 `response_format` 을 빼고 **정확히 1번** 다시(2번째도 실패면 그 결과로 분류).
  - **키 숨김**: 오류 처리 중 만드는 모든 내부 문자열에서 키 전체를 `MASK` 로 바꾼다. 결과 사전에는 업체 본문을 넣지 않는다(`detail` 은 `"HTTP <n>"` 만).
  - 횟수: HTTP 요청을 실제로 보낼 때마다 `AiState.note_request()`. 로그는 `push_warning("ai call failed: %s %d" % [err_code, status])` 꼴(코드·숫자)만.
  - 엔진 결과(§2.2 계약): `engine_call` 은 `complete_json` 결과를 `{ok:true, data}` 또는 `{ok:false, err_code, format: err_code == "bad_format"}` 로 줄여 돌려준다.
- **`AiState`**(새, `godot/scripts/core/ai_state.gd`, `class_name AiState extends RefCounted`, 정적):
```
const PREF_PRESET := "ai_preset"                 # "" = 끔(기본)
const PREF_MODEL := "ai_model"                   # "" = 프리셋 기본
const PREF_CONSENT := "phone_ai_consent"         # {"<preset>": true} — 키 저장 때 동의(PI3)
const PREF_DIARY_CONSENT := "phone_diary_consent"   # {"<preset>": true} — 일기 첫 고치기 때 동의(PWI)
const PREF_DIARY_TRAINS := "phone_diary_trains_ok"  # bool — 무료 학습 업체로 일기 보내기 허락(PWI)
const PREF_REQ := "ai_req_day"                   # {"day": <일 번호>, "n": <횟수>}
const NEW_PREFS := [PREF_PRESET, PREF_MODEL, PREF_CONSENT, PREF_DIARY_CONSENT, PREF_DIARY_TRAINS, PREF_REQ]
static var force_phone: int = -1                 # 시험: 1 폰 / 0 PC / -1 Platform.is_phone()
static func preset() -> String                   # 설정의 프리셋이 AiPresets 에 있으면 그 id, 아니면 ""
static func model() -> String
static func phone_ready() -> bool                # 폰 && preset != "" && AiSecrets.has_key(preset) && phone_ai_consent[preset] == true
static func diary_consented() -> bool            # phone_diary_consent[preset] == true
static func set_diary_consent(v: bool) -> void
static func diary_allowed() -> bool              # 프리셋이 trains_free 가 아니거나 phone_diary_trains_ok == true
static func use(lang: String, path: String = "/fix") -> Dictionary
    # {"use": "pc"|"phone"|"none", "why": err_code 또는 "", "preset": String}
    # d := Route.decide("POST", path, {"lang": lang}).  d == "pc": PC 준비 && not Backend.llm_missing() 이면 "pc", 아니면 "none"(why "not_connected"/"no_ai")
    # d == "phone": "phone".  d == "none": why = Route.why_none(...).err_code
static func note_request() -> void ; static func requests_today() -> int   # 날짜가 바뀌면 0 부터
```
  새 prefs 는 전부 `SyncDoc.SHARED_PREFS` 밖이다(동기화 안 됨, S3). `phone_ai_consent`·`phone_diary_consent` 는 `_consent` 로 끝나 공개 기본값에서 지워진다(S24).
- **가짜 AI 서버**(새, `phone_src/tools/fake_ai_server.py`, 표준 라이브러리만, `127.0.0.1` 만 bind): `--port --root --peer-port`(302 대상). 경로 `/s/<scenario>/v1/chat/completions`(POST), `/s/<scenario>/v1/models`(GET). 시나리오: `ok`, `ok_fenced`, `json_mode_reject`, `auth_echo_key`(본문에 받은 키를 그대로 되돌림), `limit_retry_after`, `quota_400`, `model_404`, `overload_503`, `slow`(타임아웃보다 오래), `redirect_302`(→ peer), `not_json`, `content_parts`, `huge_2mb`, `no_choices`, `free_tier`. 기록 `<root>/requests.jsonl` 한 줄 = `{"t","port","path","scenario","auth_sha256"|null,"body_sha256","has_response_format":bool}` — 키·본문 원문은 쓰지 않는다. 시작하면 `<root>/ready.txt`. 단위 시험 `phone_src/tools/test_fake_ai_server.py`(≥ 10, 기록에 원문 키 0 포함).
- **시험 러너**(새, `godot/tests/run_ai_tests.ps1`): `run_model_tests.ps1` 와 같은 규칙(18791~18799 중 빈 포트 2개, 시험마다 새 폴더, 자기 PID 트리만 종료, `APPDATA` 임시화, `--api=http://127.0.0.1:9`, 엔진 `ERROR:` 줄 실패 판정). 돌리는 것: `ai_secrets_test`·`ai_json_test`·`ai_state_test`·`ai_client_test` 를 `pc`·`phone` 두 모드. 마지막 줄 `남은 프로세스·열린 포트 없음`.
- **황금 도우미**(새, `godot/tests/ai_golden_util.gd`, `class_name AiGoldenUtil`, 시험 전용 — PI2b·PI2c 시험도 쓴다): `canon(v) -> String`(§2.2), `load_kind(file: String) -> Array`(`res://tests/fixtures/ai_golden/<file>`), `load_api_scripts() -> Dictionary`(`ProjectSettings.globalize_path("res://").path_join("../phone_src/tools/ai_golden_cases.json")` 의 api 사례 `script` 를 사례 id 로), `class FakeEngine`(엔진 대본 재생·기록), `to_phone(expect: Dictionary, engine_steps: Array) -> Dictionary`(R-MAP), `compare_engine_calls(got: Array, want: Array) -> String`(""=같음, 아니면 첫 차이의 위치 이름만).
- 다른 작업과의 계약: PI2b·PI2c 는 `AiClient.engine_call`·`AiState`·`AiGoldenUtil` 만, PI3 는 `AiSecrets`(get_key 제외)·`AiPresets`·`AiClient.list_models/test_call`·`AiState`, PWI 는 `AiState` 만 쓴다.

### 2.2 엔진 계약과 결과 대응표 R-MAP (PI1 이 고정, PI2b·PI2c·PWI 가 따른다)
- **엔진 Callable**: `func(messages: Array, schema: Dictionary, temperature: float, num_predict: int) -> Dictionary`(코루틴 허용). 결과 `{ok:true, data:Dictionary}` 또는 `{ok:false, err_code:String, format:bool}`. 앱에서는 `AiClient.engine_call`, 시험에서는 `AiGoldenUtil.FakeEngine.call`.
- **가짜 엔진의 대본 해석**(황금 엔진 기록 한 줄 = 한 번의 호출): `reply` 가 있으면 `{ok:true, data:reply}`, `error.kind` 면 `auth→ai_auth`, `limit→ai_limit`, `overload→ai_overload`, `not_connected→no_ai`, `format→bad_format(format:true)`, `plain→ai_overload`. 받은 인자 `{messages, schema, temperature, num_predict}` 를 기록한다.
- **규칙 코드의 결과(서버 모양)**: `{"result": {...}}` 또는 `{"error": {"status": int, "msg": String, "code": String, "format_error": bool}}`. 엔진 오류로 끝나면 `code` = 엔진 `err_code`, `msg` = `Route.text_for(code)`, `status` = `Route.http_for(code)`. 입력 검사·내용 거절(서버가 `code:""` 로 내는 것)은 서버와 **같은 한국어 글과 status**.
- **R-MAP(황금 기대값 → 폰 기대값)** — `AiGoldenUtil.to_phone`:

| 황금 `expect` | 폰 기대 |
|---|---|
| `result: R` | `result` == R(같은 `canon`) |
| `error.code ∈ {ai_auth, ai_limit, ai_overload}` | `code` 같음, `msg == Route.text_for(code)`, `format_error` false(status 는 비교 안 함) |
| `error.code == "ai_not_connected"` | `code == "no_ai"`, `msg == Route.text_for("no_ai")` |
| `error.code == ""`, `format_error: true` | `code == "bad_format"`, `msg == Route.text_for("bad_format")`, `format_error: true` |
| `error.code == ""`, `format_error: false`, 마지막 엔진 기록이 `error.kind == "plain"` | `code == "ai_overload"`, `msg == Route.text_for("ai_overload")` |
| `error.code == ""`, `format_error: false`, 그 밖(입력 400·미션 404·내용 거절 502) | `code == ""`, `msg`·`status` 가 황금과 같음 |
| `attempts: n` | 엔진 호출 수 == n, 호출마다 `messages`(문자열까지)·`schema`·`temperature`·`num_predict` 가 같음 |

- **`LocalApi` 결과로 바꾸기**(`LocalAi`): `result` → `LocalApi.ok(result)`(키 `via:"phone"`, `degraded:[]`, `tts_chunks` 없음). `error` → `code != ""` 면 `LocalApi.fail(code, msg)`, `code == ""` 면 status 400 → `fail("bad_request", msg)`, 404 → `fail("not_found", msg)`, 502 → `fail("bad_format", msg)`.
- **`canon(v)`**: 사전 키를 정렬하고, 정수값인 float 는 int 로 바꾼 뒤(`JSON.parse` 가 정수를 float 로 읽기 때문) `JSON.stringify(v, "", true)`. 문자열은 그대로(유니코드 비교).

### 2.3 PI2b — `LocalAi` + `AiChatRules` (6파)
- 하는 일은 §2.5(폰)·§6.12(폰). 확정 계약:
- **`LocalAi`**(새, `godot/scripts/local/local_ai.gd`, **class_name 없음**: `LocalApi` 가 경로로 부른다):
```
const PATHS := ["/chat", "/fix", "/feedback", "/missions/judge"]
const FEEDBACK_RULES_PATH := "res://scripts/local/ai_feedback_rules.gd"   # PI2c. 없으면 /feedback·/missions/judge 는 not_on_phone
const TEXT_DIARY_CONSENT := "일기를 이 폰에서 AI 업체로 보내려면 일기 화면에서 한 번 동의해 주세요."
const TEXT_DIARY_TRAINS := "이 업체는 보낸 글을 학습에 쓸 수 있어서 일기 고치기는 꺼져 있어요. 일기 화면에서 직접 켤 수 있어요."
static var engine_override: Callable   # 시험: 엔진 Callable. 기본 AiClient.engine_call
static var engine_calls: int = 0       # 시험용 누적
static func handle(method: String, path: String, query: Dictionary, body: Dictionary) -> Dictionary   # 코루틴
static func is_available() -> bool
static func unavailable_reason() -> Dictionary
static func is_available_for(path: String, query: Dictionary, body: Dictionary) -> bool
static func unavailable_reason_for(path: String, query: Dictionary, body: Dictionary) -> Dictionary
```
  - 가용성 판정 순서(`is_available_for` 와 `handle` 이 **같은 함수**를 쓴다): ① 폰이 아님 → `not_on_phone` ② `path ∉ PATHS`(예: `/lesson` + `source:"ai"`) → `not_on_phone` ③ `str(body.get("lang","en")) != "en"` → `ja_ai_pc` ④ `not AiState.phone_ready()` → `no_ai` ⑤ `path == "/fix"` 이고 `private` 가 참값(`true`, 0 이 아닌 수, 문자열 `true/1/yes/on` 대소문자 무시 — 서버 pydantic 과 같음)이면: `not AiState.diary_consented()` → `no_ai` + `TEXT_DIARY_CONSENT`, `not AiState.diary_allowed()` → `no_ai` + `TEXT_DIARY_TRAINS` ⑥ `/feedback`·`/missions/judge` 인데 `FEEDBACK_RULES_PATH` 가 없음 → `not_on_phone`. 하나라도 걸리면 **엔진 호출 0, `AiClient` 요청 0**. ⑤ 는 `Api._fall_back`(S14)을 막는 핵심 방어선이다.
  - 처리: `/chat` → `AiChatRules.run_chat(body, engine)`, `/fix` → `AiChatRules.fix(body, engine)`, `/feedback` → `AiFeedbackRules.run_feedback`, `/missions/judge` → `AiFeedbackRules.judge(body, engine)`(경로로 `load`). 결과는 §2.2 로 `LocalApi` 결과로 바꾼다.
- **`AiChatRules`**(새, `godot/scripts/local/ai_chat_rules.gd`, `class_name AiChatRules`, 정적): 서버 `LEVEL`·`context_text`·`rules_text`·`clean_hist`·`ko_ok`·`scrub_ko`·`FOREIGN_SCRIPT`·`looks_like_question`·`CHAT_SCHEMA`·`FIX_SCHEMA`·`run_chat`(openai_api 경로)·`correct_learner`(LanguageTool 없음 = 항상 `_llm_correct(lt_fix="")`)·`fix`(`/fix` 의 입력 검사·자르기·`private` 응답 키)·`norm_text` 를 문장 단위로 옮긴다. 공개 함수: `rules_text(lang, scenario, stage, n, w) -> String`, `context_text(lang, n, w) -> String`, `clean_hist(history) -> Array`, `ko_ok(s) -> bool`, `scrub_ko(s) -> String`, `looks_like_question(s) -> bool`, `norm_text(s) -> String`, `run_chat(req: Dictionary, engine: Callable) -> Dictionary`, `fix(req: Dictionary, engine: Callable) -> Dictionary`(뒤 둘은 코루틴, 결과는 §2.2 서버 모양). 커리큘럼은 `res://data/curriculum.json`(S17).
- **일부러 다른 점(시험이 확인)**: LanguageTool·OpenCode 세션·캐시·`presynth`/`tts_chunks` 없음, 일본어 없음, 엔진 오류 문구는 `Route` 고정 문구(R-MAP), `course` 필드 무시.
- 로그 금지: `print`·`push_*`·`Toast` 에 메시지·프롬프트·사용자 글·결과 글 0(X-7).

### 2.4 PI2c — `AiFeedbackRules` (6파)
- **`AiFeedbackRules`**(새, `godot/scripts/local/ai_feedback_rules.gd`, `class_name AiFeedbackRules`, 정적): 서버 `run_feedback`(FEEDBACK_SCHEMA, 점수 1~5 clamp, 교정 6개·표현 5개 상한, `summary` 한국어 아니면 재시도, transcript 12000자·history 40개 자름)와 `missions.missions_judge`·`judge_goals`·`_judge_messages`·`_quoted_in`(증거가 학습자 한 줄에 글자 그대로 있어야 `done:true`, 모르는 id·중복 무시, `pending` 비면 400, 모르는 미션·언어 불일치 404, history 24개·한 줄 500자)를 옮긴다. 미션 데이터는 `res://data/pack/missions.json`(서버와 같음, S17)을 `PackLoader` 로 읽는다(구현 선택은 워커, 검증은 황금).
- 공개: `run_feedback(req: Dictionary, engine: Callable) -> Dictionary`, `judge(req: Dictionary, engine: Callable) -> Dictionary`(코루틴, §2.2 서버 모양), `const JUDGE_MAX_TURNS := 24`(변이 대상), `const FB_MAX_TURNS := 40`.
- `local_ai.gd`(PI2b 소유)는 고치지 않는다. PI2b 병합 전에도 이 작업의 시험은 규칙 함수를 직접 부르므로 독립적이다. `LocalAi` 를 거치는 확인은 통합 시험 T-1 에서 한다.

### 2.5 PI3 — 설정 "AI 연결(이 폰)" 카드·시트 (6파)
- **`PhoneAiCard`**(새, `godot/scripts/ui/phone_ai_card.gd`, `class_name PhoneAiCard`): `static func build(host: Node) -> Control`(노드 이름 `PhoneAiCard`). 폰이 아니면 `TXT_PC` 한 줄만 있는 `Label` 을 돌려주고 키 관련 함수를 부르지 않는다.
  - 키 없음: 제목 `TITLE`, `TXT_NONE`, 버튼 [AI 키 넣기](`PhoneAiOpenBtn`) → `PhoneAiSheet.open(host)`.
  - 키 있음: `TXT_READY % [라벨, "••••" + last4, 모델]`, `TXT_COUNT % AiState.requests_today()`, 버튼 [키 바꾸기](`PhoneAiOpenBtn`), [연결 시험](`PhoneAiTestBtn`) → `AiClient.test_call` → 결과 줄(`PhoneAiResult`: 성공 `TXT_TEST_OK`, 실패 `Route.text_for(err_code)`, `free_tier` 면 `NOTE_ZEN`), [모델 목록](`PhoneAiModelsBtn`) → 목록 시트에서 고르면 `ai_model` 저장, [키 지우기](`PhoneAiClearBtn`) → 확인 시트 → `AiSecrets.clear_key` + `phone_ai_consent[preset]` 제거.
  - 늘 보이는 작은 글: `LIMIT_TEXT`, `SPEND_TEXT`, `CAPTURE_TEXT`, `RESET_NOTE`. 상태 점: 성공 초록, `ai_auth` 빨강, `ai_offline/ai_limit/ai_overload` 주황.
  - 문구(그대로): `TITLE := "AI 연결(이 폰)"`, `TXT_NONE := "AI 키가 없어요. 내 AI 키를 한 번 넣으면 PC 없이도 대화·교정·피드백·일기 고치기를 쓸 수 있어요."`, `TXT_READY := "%s · 키 %s · 모델 %s"`, `TXT_COUNT := "오늘 %d번 요청했어요"`, `TXT_TEST_OK := "연결됐어요."`, `LIMIT_TEXT := "키는 이 휴대폰 안에만 암호화해서 저장해요. 다만 루팅된 폰이나 폰 전체를 분석하는 경우에는 완전히 지킬 수 없어요."`, `SPEND_TEXT := "요금은 키 주인에게 청구돼요. 업체 사이트에서 지출 한도를 걸어 두세요."`, `CAPTURE_TEXT := "키를 입력하는 동안에는 화면 캡처를 하지 마세요."`, `RESET_NOTE := "'모든 기록 지우기'는 AI 키를 지우지 않아요. 키는 [키 지우기]로 지워요."`, `TXT_PC := "AI 키는 폰 앱에서만 넣어요. PC는 [AI 연결하기]를 써요."`
- **`PhoneAiSheet`**(새, `godot/scripts/ui/phone_ai_sheet.gd`, `class_name PhoneAiSheet`):
```
static var clipboard_get_hook: Callable   # 시험: () -> String. 기본 DisplayServer.clipboard_get
static var clipboard_set_hook: Callable   # 시험: (String) -> void. 기본 DisplayServer.clipboard_set
static func open(host: Node, preset: String = "") -> Node   # Sheet
static func is_open() -> bool
```
  - 1단계: 안내 `TXT_PICK := "쓸 AI 업체를 골라 주세요. 고르기 전에는 아무것도 보내지 않아요."`, 프리셋 버튼 `AiPreset_<id>`(라벨 + `note_ko` 작은 글; gemini 는 경고색).
  - 2단계: 모델 칸 `AiModelEdit`(빈칸 = 기본, 안내 "모델(비워 두면 기본값: %s)"), 키 칸 `AiKeyEdit`(**`_key_edit.secret = true`**, 이 한 줄이 변이 대상), [저장](`AiSaveBtn`). 저장 누르면 `AiSecrets.check_format` → 실패면 `Route.text_for("ai_key_format")`, 저장 안 함.
  - 3단계(동의 시트, 노드 `AiConsentSheet`, 제목 `"AI 업체로 보내기 전에"`): 문단 `"대화·교정·피드백에 쓴 문장이 이 휴대폰에서 %s 서버로 직접 전송돼요."`, `"이 앱은 문장을 폰에 기록하지 않지만, %s의 보관·학습 정책은 그 업체를 따라요."`, `SPEND_TEXT`, 프리셋 `note_ko`, `"일기는 일기 화면에서 따로 한 번 더 물어봐요."`. 버튼 [동의하고 저장](`AiConsentAgree`) / [취소](`AiConsentCancel`). 동의하면 `AiSecrets.set_key` → `ai_preset`·`ai_model`·`phone_ai_consent[preset]=true` 저장 → 키 칸 비움 → 클립보드가 키와 같으면(sha256 비교) 비움 → 시트 닫음. 취소면 아무것도 저장 안 함.
  - 시트는 키를 멤버 변수·시그널·사전에 담지 않는다(칸의 글을 저장 함수에 바로 넘기고 칸을 비운다).
- 설정 화면 연결(`settings_view.gd`)은 PSI 몫이다. PI3 는 부품만.

### 2.6 PSI — 설정 연결·기능 현황 + 듣기 속도 범위 (e) (7파)
- **AI 연결 묶음**: 폰(`standalone_panels`) "엔진" 구역에서 `SttSection` 다음, `_build_processing()` 앞에 노드 `PhoneAiSection`(제목 H3 `"AI 연결"` — `Route.ERR_TEXT["no_ai"]` 의 "설정 > AI 연결" 과 같은 글자) → `PhoneAiCard.build(self)`. PC 앱은 변화 없음(`AiConnectCard` 그대로). `Store.prefs_changed` 로 `ai_*`·`phone_ai_consent` 가 바뀌면 카드를 다시 그린다.
- **`CapabilityPanel.REASONS["no_ai"]`** = `"설정 > AI 연결에서 내 AI 키를 넣으면 폰에서 쓸 수 있어요. PC에 연결해도 돼요."`(이 한 줄만 바꾼다. 키 16개 그대로).
- **(e) 듣기 속도**(사용자: "듣기가 너무 느리다"). `tts.gd`:
```
const SPEED_MIN := 0.6
const SPEED_MAX_PHONE := 1.6   # 폰 시스템 음성(DisplayServer.tts_speak rate)
const SPEED_MAX_PC := 1.3      # PC 목소리(서버 synth_wav 가 1.3 에서 자른다, 서버 변경 금지)
const SLOW_SPEED := 0.75       # 그대로
func max_speed() -> float      # engine_now() == "system" 이면 SPEED_MAX_PHONE, 아니면 SPEED_MAX_PC
func normal_speed() -> float   # clampf(pref tts_speed, SPEED_MIN, max_speed())
```
  설정 슬라이더: 최소 0.6, 최대 = 폰 앱이면 1.6, PC 앱이면 1.3(지금과 같음), 간격 0.05, 기본 1.0 그대로. 폰에서 값이 1.3 보다 크고 지금 엔진이 PC 목소리면 슬라이더 아래 `TXT_SPEED_PC_CAP := "PC 목소리는 1.3배까지만 빨라져요."` 한 줄. `SLOW_SPEED` 와 코스 연습의 "천천히" 동작은 바꾸지 않는다. `tts_speed` 는 동기화 설정이라 폰의 1.5 가 PC 로 가도 PC 는 `normal_speed()` 에서 1.3 으로 자른다.
- 다른 작업과의 계약: `phone_ai_card.gd`·`phone_ai_sheet.gd`(PI3) 수정 금지.

### 2.7 PWI — 일기·미션·홈·메뉴·시작 화면 연결 (7파)
- **일기(`diary_screen.gd`)**
  - 새 정적 함수 `ai_route() -> String`: `ai_hook` 이 있으면 그 값의 길, 아니면 `AiState.use(lang, "/fix")["use"]`.
  - `ai_state()`: 길이 `"phone"` 이면 `"ready"`, 그 밖은 지금 코드 그대로(PC 경로 불변).
  - `fix_private_ok()`: 길이 `"phone"` 이면 `true`(폰은 로그·캐시가 없다), 아니면 지금 그대로.
  - 동의: 길이 `"phone"` 이면 `AiState.diary_consented()` 를 보고, 아니면 **폰용 동의 시트**(`DiaryPhoneConsent`, 제목 `CONSENT_TITLE_PHONE := "일기를 고치기 전에(이 폰)"`, 문단 `CONSENT_PARAS_PHONE`, 버튼 "동의하고 고치기"/"나중에") → 동의면 `AiState.set_diary_consent(true)`. PC 경로의 `diary_consent`·`CONSENT_PARAS` 는 그대로. 상수 `const PHONE_CONSENT_PREF := AiState.PREF_DIARY_CONSENT`(변이 대상).
  - `CONSENT_PARAS_PHONE`(그대로, `%s` = 업체 라벨): `"쓴 문장이 이 휴대폰에서 %s 서버로 직접 전송돼요. 이 폰의 로그·캐시에는 남지 않아요."`, `"일기 원문은 이 기기에만 저장돼요. 다른 기기로 동기화되지 않아요."`, `"고친 문장은 복습 카드가 되어 PC·폰에 동기화돼요. 원문은 카드에 넣지 않아요."`, `"%s의 보관·학습 정책은 그 업체를 따라요."`
  - 무료 학습 업체(`trains_free`): 길이 `"phone"` 이고 `not AiState.diary_allowed()` 면 [고쳐 보기] 꺼짐 + `NOTE_TRAINS := "이 업체는 보낸 글을 학습에 쓸 수 있어요. 일기는 저장만 해요. 아래 스위치로 직접 켤 수 있어요."` + 스위치 `DiaryTrainsSwitch`("이 업체로 일기 고치기 켜기") → 확인 시트(`DiaryTrainsSheet`, `"일기 내용이 %s로 전송되고, 무료 등급은 그 내용을 서비스 개선에 쓸 수 있어요. 그래도 켤까요?"`, [켜기]/[취소]) → 켜기면 `phone_diary_trains_ok = true`.
  - 음성 입력 `stt_ok()`: `caps.stt.use == "phone"`(폰 안 음성 인식, 녹음이 밖으로 안 나감)이면 참, 아니면 지금 규칙.
  - 문구 교체: `NOTE_NO_PC := "AI로 고치려면 설정 > AI 연결에서 내 AI 키를 넣거나 PC에 연결해야 해요. 지금은 [저장만 하기]로 저장해 두고, 나중에 목록의 [고치기]로 고칠 수 있어요."`, `NOTE_NO_MIC := "음성 입력은 설정 > 음성 인식에서 모델을 받거나 PC에 연결했을 때 돼요."`
  - 요청 모양 불변: 여전히 `SpeakDrill.request("/fix", {lang, stage, text, prev_ai:"", private:true})` 한 길(폰이면 `Route` 가 `LocalAi` 로 보낸다).
- **미션(`mission_screen.gd`)** `_llm_down()`: `llm_override` 우선(그대로). 폰이면 `u := AiState.use(lang, "/chat")` → `u.use == "none"` 이거나 (`u.use == "pc"` 이고 `Backend.llm_missing()`)면 참, 아니면 거짓. PC 앱은 지금 그대로 `Backend.llm_missing()`.
- **홈 AI 자리(`ai_connect_sheet.gd` `home_slot`)**: 폰 + READY + `Backend.llm_missing()` 일 때만 바뀐다. `AiState.phone_ready()` 면 `{"show":true, "state":"llm_off", "title":"PC의 AI가 꺼져 있어요", "body":"폰 키를 쓰려면 설정 > 처리 위치를 '이 폰에서만'으로", "action":"", ...}`, 아니면 body 만 `"설정 > AI 연결에서 내 AI 키를 넣거나 PC에서 연결해요"`(action `""` 유지 → `ai_connect_test` 670행 그대로 통과). 그 밖 상태·PC 앱은 변화 없음(`HomeAi._default_slot`, 폰 단독은 숨김 유지 — §8 D-11).
- **`main.gd`**: `_on_ai_connect()` 의 폰 분기를 `PhoneAiSheet.open(self)` 한 줄로(요청 0건). PC 분기 불변(`AiConnectSheet.open(self)` 문자열 유지, `ai_connect_test` 314행). 시작 화면 폰 안내(981행) = `"PC 없이도 코스·복습·말하기 채점을 쓸 수 있어요. AI 대화는 설정 > AI 연결에서 내 키를 넣거나 PC에 연결하면 돼요."`. 다른 줄 변경 0(PWI-9).
- **`backend.gd`**: `NOT_CONNECTED_PHONE_TEXT := "AI가 아직 연결되지 않았어요. 설정 > AI 연결에서 내 AI 키를 넣거나, PC의 회화 연습 설정에서 'AI 연결하기'를 눌러 주세요."`(여전히 "PC" 포함). `llm_missing()` 의미 불변.
- **기존 시험에서 허용되는 단언 변경(이것만)**: `ai_connect_test.gd` 의 폰 `_main_wiring` 블록 두 단언 — "C6: [AI 연결하기] from the home screen on a paired phone opens no sheet" 와 "C6: ... it shows the sentence" — 을 "폰 [AI 연결하기]는 `PhoneAiSheet` 를 연다(`PhoneAiSheet.is_open()`, 요청 0건)" 로 바꾼다. "and sends no request" 단언은 그대로 둔다. 그 밖 기존 단언 삭제·완화 0(PWI-2).
- `talk_view.gd`·`home_ai.gd`·`route.gd` 는 고치지 않는다(대화는 `Route` 가 폰으로 보낸다).

### 2.8 RD — 연속 기록 '쉬는 날' (5파)
- **규칙(규범)**: 달력 주(월~일)마다 최대 `R` 일(기본 **2**, §8 D-1)은 보호권 없이 빈 날을 이어 준다. 빈 날을 이을 때 **쉬는 날을 먼저** 쓰고 모자라면 보호권을 쓴다. 다 못 이으면 지금처럼 그 틈 전체를 잇지 않고(전부 아니면 없음), 그 틈에서 쓴 보호권은 돌려준다. 쉬는 날·보호권으로 이은 날은 연속 일수에 **세지 않는다**(지금 보호권과 같음). 7일마다 보호권 받기·최대 2개는 그대로. **소급 없음**: 지금처럼 "마지막 공부일 ~ 오늘" 틈만 계산하므로 과거 끊긴 기록은 바뀌지 않는다(§8 D-2).
- **`StreakCalc`(`streak_calc.gd`)**:
```
const REST_PER_WEEK := 2            # 변이 대상
static func settle(done: Dictionary, frozen: Dictionary, tokens: int, awarded: int, today: int,
                   rest: Dictionary = {}, rest_per_week: int = 0) -> Dictionary
    # 결과: 기존 {frozen, tokens, used, streak, awarded, gained} + {"rest": Dictionary, "rest_used": int}
    # rest_per_week 기본 0 = 지금과 완전히 같은 결과(기존 호출·streak_test 불변)
static func week_of(d: int) -> int  # Plan.monday_of(d)
static func rest_left(rest: Dictionary, today: int, rest_per_week: int) -> int   # R - (오늘이 속한 주의 rest 수), 0 이상
```
  알고리즘(이 순서 그대로): `R = clampi(rest_per_week, 0, 7)`, `rs = _clean(rest)` 중 `fz` 에 있는 날만. 시계 되돌림이면 `_reversed`(rest 그대로, rest_used 0). `prev` 가 있고 `gap > 0` 이면 `prev+1 .. today-1` 을 차례로: 이미 `fz` 에 있으면 `rs` 에 없을 때만 `in_gap_tok += 1` 하고 넘어감, 아니면 `count[week_of(d)]`(그 주의 `rs` 수 + 이번에 새로 고른 수) `< R` 이면 새 쉬는 날, 아니면 `need_tok += 1`. `need_tok <= tokens` 면 틈 전체를 `fz` 에, 새 쉬는 날을 `rs` 에 넣고 `tokens -= need_tok`, `used = need_tok`, `rest_used = 새 쉬는 날 수`. 아니면 틈의 날을 `fz`·`rs` 에서 지우고 `tokens = mini(MAX_TOKENS, tokens + in_gap_tok)`. 그 뒤 연속·보상 계산은 지금 그대로. (R = 0 이면 기존 식과 같다: `need_tok = gap − in_gap`, 조건 `gap ≤ tokens + in_gap`.)
- **`StudyLog`(`study_log.gd`)**: `freeze.<lang>` 에 키 `"rest": [iso…]`(정렬)를 더한다. `_blank_freeze` 에 `"rest": []`, `_norm_freeze` 가 `rest` 를 받아(문자열·유효 날짜·중복 제거·**`frozen` 에 있는 날만**) 보존, `_prune_for_save` 가 400일보다 오래된 `rest` 도 지움, `settle()` 이 `StreakCalc.settle(…, rest, rest_per_week())` 를 부르고 `rest` 가 바뀌면 저장 대상(dirty). 쉬는 날을 새로 쓰면 토스트 `TXT_REST_USED := "이번 주 쉬는 날 %d일을 써서 연속 기록이 이어졌어요"`(보호권 토스트는 그대로, 둘 다 쓰였으면 둘 다). 새 공개:
```
static var rest_per_week_override: int = -1   # 시험 전용(-1 = StreakCalc.REST_PER_WEEK)
static func rest_per_week() -> int
static func rest_days(lang: String) -> Dictionary   # 일 번호 -> true
static func rest_left(lang: String) -> int          # 이번 주 남은 쉬는 날(오늘 기준)
# settle(lang) 결과에 "rest_used", "rest_left" 키 추가(기존 키 그대로)
```
  `KNOWN_KEYS`·`VERSION` 그대로(마이그레이션 없음). 옛 앱이 이 파일을 읽으면 `rest` 만 버리고 `frozen` 은 남으므로 연속은 그대로이고, 다시 새 앱으로 오면 그 날들이 "보호권으로 지킴" 으로 보일 뿐이다. 동기화 영향 없음(`freeze` 전체가 동기화 밖, S3). 배지 규칙 변경 없음(`longest_streak` 가 `frozen` 을 다리로 쓰므로 쉬는 날도 자동으로 다리가 된다, S4. 결과적으로 `streak_7`·`streak_30` 이 조금 쉬워진다 — 위험 V9).
- **화면**
  - `home_parts.gd`: `stone_states` 에 상태 `"rest"`(공부 안 함 + `rest_days` 에 있음; 우선순위 done > rest > frozen > missed), `Stone._draw` 의 `"rest"` = 채움 없는 점선 고리(짧은 호 8개, `Pal.REWARD`, 굵기 2), 접근성 이름 `"쉬는 날"`. 연속 카드 머리에 칩 `TXT_REST_CHIP := "쉬는 날 %d일 남음"`(`StudyLog.rest_left`, 0 이어도 보임). 다른 줄 변경 0.
  - `goal_card.gd`: 칩 줄에 같은 `TXT_REST_CHIP`, 한 줄형(compact) 끝에 `" · 쉬는 날 %d일 남음"`. 설명 글을 상수 `const EXPLAIN := "주마다(월~일) 2일까지는 보호권 없이 쉬어도 연속 기록이 이어져요. 그보다 더 쉬면 보호권을 써요. 7일 연속할 때마다 보호권 1개를 받고, 최대 2개까지 모아요. 쉬는 날과 보호권 개수보다 많은 날을 놓치면 연속 기록이 이어지지 않고 보호권은 그대로 남아요."` 로 바꾼다(기존 단언의 두 부분 문자열 "보호권 개수보다 많은 날을 놓치면"·"보호권은 그대로 남아요" 를 그대로 포함). 숫자 2 는 `StreakCalc.REST_PER_WEEK` 로 채운다(문자열 포맷).
- **기존 시험 처리(규범)**: 새 규칙 때문에 깨지는 기존 시험은 **기존 단언을 고치지 않고** 그 구간 앞에 `StudyLog.rest_per_week_override = 0` 을, 끝에 `StudyLog.rest_per_week_override = -1` 을 더하는 것만 허용한다(옛 규칙 회귀 보호 유지). 허용 파일은 OWN 의 RD 줄에 있는 기존 시험 7개뿐이고, 그 diff 의 `+`/`-` 줄은 전부 `rest_per_week_override` 를 담은 `+` 줄 또는 주석 `+` 줄이어야 한다(RD-6). 새 규칙은 새 시험 `rest_days_test` 가 덮는다.

### 2.9 FXA — 녹음 도구 세트 접두사 (5파, D-5(201))
- `calib_record.py`: 새 인자 `--set-tag TAG`. 규칙 `SET_TAG_RE = re.compile(r"^[a-z][a-z0-9]{0,11}$")`(변이 대상). 안 주면 자동 `"s" + 오늘 시각 "%m%d%H%M"`(예 `s11271930`). 틀린 값이면 `CALIB_REC_FAIL set_tag` 와 종료 2(마이크·폴더를 건드리기 전, `--dry-run` 에서도).
- 클립 id = `"<tag>_u%02d_<kind>"`, 파일 `clips/<id>.wav`, `manifest.json` 최상위에 `"set": "<tag>"`. `--dry-run` 마지막 줄에 ` set=<tag>` 를 덧붙인다(그 밖 출력·동의 문구 불변, 아무것도 안 씀).
- `phone_src/calib/README.txt`: 두 번 나눠 녹음할 때 `--set-tag` 를 다르게 주는 한 단락. `docs/v201_design.md` §4.1 명령은 바꾸지 않는다(자동 접두사로 그대로 동작).
- 뒤 도구(`calib_pc_run.py`·`calib_fit.py`·`calib_phone.gd`) 변경 0(id 자유 문자열, S11).

### 2.10 FXB — 업데이터 태그 필터 (5파, O-9(201))
- `update.ps1` 에 새 함수 두 개(파일 안, 별도 파일 없음 — `build_dist.ps1` 이 이 한 파일만 복사하므로):
```
function Test-AppTag([string]$tag) { return ("" + $tag) -match '^v\d' }          # 대소문자 무시(-match 기본)
function Select-UpdateRelease([object[]]$list) {                                  # 비안정 채널: draft 아님 + 앱 태그인 첫 릴리스, 없으면 $null
    foreach ($r in @($list)) { if ($null -ne $r -and -not $r.draft -and (Test-AppTag $r.tag_name)) { return $r } }
    return $null
}
```
  `Get-LatestRelease` 의 비안정 분기 `Select-Object -First 1` 을 `Select-UpdateRelease` 로 바꾼다. 안정 분기는 받은 릴리스가 `Test-AppTag` 거짓이면 `throw "GitHub 의 최신 릴리스가 앱 버전이 아니에요 ($tag). 잠시 뒤 다시 시도해 주세요. 설치된 프로그램은 그대로 쓸 수 있어요."`(지금은 `0.0` 으로 조용히 넘어감). `-Source` 경로는 변경 0. 파일은 **UTF-8 BOM 유지**.
- 이 고침은 사용자가 2.0.2 업데이트를 받은 **뒤의** 업데이트부터 효과가 있다(지금 설치본의 `update.ps1` 은 옛 코드, 위험 V11).

### 2.11 FXC — `model_store_test` 부재 단언 로그 정착 대기 (5파)
- `model_store_test.gd`: 카드 시험과 같은 `_inflight()`(마지막 줄 문자열 그대로 `return maxi(int(t), -1) # a negative number is a server bug: -1 keeps it "not settled"`)·`_settled_log(tok) -> Array`(inflight 0 이고 개수가 `SETTLE_MS := 400` 동안 그대로일 때 반환, `SETTLE_LIMIT_MS := 8000` 넘으면 `_settle_timeouts += 1`)를 더하고, 부재 단언 5곳(463·647·708·713·924행; 924행은 반복문이라 실행 수는 그 이상)의 `await _frames(n)` + `_log(tok)` 를 `await _settled_log(tok)` 로 바꾼다. 각 자리에서 `print("absence: settled %s" % <짧은 이름>)`. 끝에 `ok(_settle_timeouts == 0, …)`. 단언 글·기대 숫자는 그대로.
- **검사기 자체 확인**: 새 자기 점검 — 새 모델 id 로 `ModelStore.start` 를 한 번 부르고 `await _frames(5)` 뒤 옛 방식 개수 `n_old = _log(tok_sc).size()`, 새 방식 `n_new = (await _settled_log(tok_sc)).size()` → `ok(n_new == 1, …)`, 그리고 `n_old == 0` 이면 `print("selfcheck FAIL-as-expected late_line")`(로그 지연이 있을 때 옛 방식이 놓친다는 증거).
- `run_model_tests.ps1`: 새 환경 변수 `MODEL_SRV_LOGDELAY_STORE`(ms, 기본 0) — `model_store_test` 서버에만. 기존 `MODEL_SRV_LOGDELAY`(카드 시험 전용) 의미 불변. 머리 주석에 한 줄.

### 2.12 FXD — `lifecycle_test` 격리 (5파)
- `_test_reading_scroll`: `add_child(rv)` **전에** `rv.storage_dir = READING_DIR`(`const READING_DIR := "user://test_lifecycle_reading"`), 끝에 그 폴더를 지운다(`DirAccess` 재귀 삭제, 시험 폴더만). 시험 시작 때 `user://reading` 존재 여부를 기록하고, 없었으면 끝에 `ok(not DirAccess.dir_exists_absolute(ProjectSettings.globalize_path("user://reading")), "user://reading was not made")`. 이미 있었으면 그 단언 대신 `print("precondition: user://reading existed before the test")`(PASS 로 세지 않음).

### 2.13 PZ — 문서 (8파)
- `README.md` 폰 절: "폰 AI 직접 연결 (2.0.2)" — 설정 > AI 연결에서 업체 고르기·키 넣기·동의, 업체 4곳과 요금·개인정보(Gemini 무료는 학습 사용 → 일기 기본 꺼짐), 키 보관 한계(눈속임 수준·화면 캡처 금지·지출 한도), "오늘 N번 요청", 오류 문구 예, PC 가 연결돼 있으면 PC AI 가 먼저(폰 키를 쓰려면 처리 위치 '이 폰에서만'), 일본어는 PC. 연속 기록 '쉬는 날'(주 2일). 듣기 속도 폰 1.6배·PC 1.3배.
- `ROADMAP.md`: 2.0.2 완료 항목·알려진 한계(PI0 결과 숫자, 실기 미검증 항목, USB 없으면 logcat 미검증), "외부 제안" 표의 쉬는 날 줄 완료 표시, 남은 2.0.2 후보(D7N 등).
- `INSTALL.md`: 폰 업데이트 뒤 AI 키 넣는 곳, 키 지우기, "모든 기록 지우기는 키를 지우지 않음".
- 버전 숫자·`WORKLOG.md` 변경 0.

---

## 3. 소유권 OWN 블록과 파 순서

### 3.1 파 순서와 병렬
```
0파(오케스트레이터): 이 문서 확정·커밋 → §8 결정 → (2.0.1 공개 경로 확정, D-15) → ★키 파일이 생기면 PI0(§6.1)
5파: PI1 ∥ RD ∥ FXA ∥ FXB ∥ FXC ∥ FXD                  (파일 겹침 0)
6파: PI2b ∥ PI2c ∥ PI3                                 (PI1 병합 뒤)
7파: PSI ∥ PWI                                          (PSI: PI3 병합 뒤 / PWI: PI2b·PI2c·PI3 병합 뒤. 파일 겹침 0 → 동시 가능, D-9)
8파: PZ → 버전 2.0.2(오케스트레이터) → 통합 시험 T(§6.2) → PI0 게이트 확인 → 시험 APK(정식 키) → ★실기 H7~H10·H13 → 2.0.2 공개
```
| 작업 | 선행(병합) | 함께 해도 됨 | 위험도·검토 |
|---|---|---|---|
| PI1 | - | 5파 전부 | 높음(비밀값·네트워크): Sol + 오케스트레이터 재실행(PI1-1·PI1-5·PI1-7·PI1-8·PI1-16) |
| RD | - | 5파 전부 | 보통: Sol 1회 |
| FXA | - | 5파 전부 | 보통(녹음 개인정보 도구): Sol 1회 |
| FXB | - | 5파 전부 | 높음(업데이터): Sol + 재실행(FXB-1·FXB-2) |
| FXC | - | 5파 전부 | 보통(시험만): Sol 1회 |
| FXD | - | 5파 전부 | 낮음~보통(시험만): Sol 1회 |
| PI2b | PI1 | PI2c, PI3 | 높음(개인정보 전송): Sol + 재실행(PI2b-2·PI2b-3·PI2b-4) |
| PI2c | PI1 | PI2b, PI3 | 보통: Sol 1회 |
| PI3 | PI1 | PI2b, PI2c | 높음(키 입력 화면): Sol + 재실행(PI3-2·PI3-3) |
| PSI | PI3 | PWI | 보통: Sol 1회 |
| PWI | PI2b, PI2c, PI3 | PSI | 높음(일기 개인정보): Sol + 재실행(PWI-3·PWI-4·PWI-5) |
| PZ | 7파 전부 | - | 낮음: 오케스트레이터 확인 |

### 3.2 OWN 블록 (기준: 이 블록. 줄 형식 `작업 종류 경로 [after=작업]`, `docs/v201_design.md` §3.2 와 같은 형식)
- **파일마다 이 문서 안의 소유자는 하나뿐이다**(검사기 규칙 ① 은 걸리지 않는다). `after=` 는 §3.3 기준 파일(세 문서 OWN 합본)에서 그 파일의 마지막 소유자를 뜻한다: `E6`·`E7` = `docs/v200_design.md`, `PSA`·`PA3`·`PA5a`·`PZ` = `docs/v201_design.md`(모두 main 에 병합됨). 이 문서의 작업 id `PI1`·`PI2b`·`PI2c`·`PI3`·`PSI`·`PWI`·`PZ` 는 `docs/v200_phone_design.md` 의 같은 이름 작업(실행되지 않음)을 이어받는다 — 그래서 합본에서는 그 문서의 그 일곱 작업 줄을 뺀다(§3.3).
- 새 `.gd` 의 `.uid` 짝은 그 작업 소유로 본다(줄에는 적지 않는다).
- 읽기만: `route.gd`, `api.gd`, `local_api.gd`, `store.gd`, `home_ai.gd`, `talk_view.gd`, `plan.gd`, `badge_*.gd`, `sync/*`, `backend/*`, `phone_src/tools/make_ai_golden.py`·`ai_golden_cases.json`, `godot/tests/fixtures/ai_golden/*`, `stt_model_card_test.gd`, `fake_model_server.py`, `reading_view.gd`, `course_today_test.gd`.
- 수정 금지(어느 작업도 소유하지 않음): `godot/project.godot`, `godot/export_presets.cfg`, `godot/scripts/sync/*`, `backend/*`, `native/*`, `packaging/publish_release.ps1`·`check_no_media.ps1`·`build_dist.ps1`·`build_android.ps1`·`check_phone_native.ps1`, `packaging/installer/*` 중 `update.ps1` 밖, 일본어 파일, 황금 파일과 생성기(PI2a), 위 표에 없는 기존 시험.

<!-- OWN-BEGIN -->
PI1 new godot/scripts/local/ai_secrets.gd
PI1 new godot/scripts/local/ai_presets.gd
PI1 new godot/scripts/local/ai_client.gd
PI1 new godot/scripts/local/ai_json.gd
PI1 new godot/scripts/core/ai_state.gd
PI1 new godot/tests/ai_golden_util.gd
PI1 new godot/tests/ai_secrets_test.gd
PI1 new godot/tests/ai_secrets_test.tscn
PI1 new godot/tests/ai_client_test.gd
PI1 new godot/tests/ai_client_test.tscn
PI1 new godot/tests/ai_json_test.gd
PI1 new godot/tests/ai_json_test.tscn
PI1 new godot/tests/ai_state_test.gd
PI1 new godot/tests/ai_state_test.tscn
PI1 new godot/tests/run_ai_tests.ps1
PI1 new phone_src/tools/fake_ai_server.py
PI1 new phone_src/tools/test_fake_ai_server.py
RD mod godot/scripts/core/streak_calc.gd
RD mod godot/scripts/core/study_log.gd
RD mod godot/scripts/ui/goal_card.gd
RD mod godot/scripts/ui/home_parts.gd after=E6
RD mod godot/tests/streak_test.gd
RD mod godot/tests/study_log_test.gd
RD mod godot/tests/study_log_fun_test.gd
RD mod godot/tests/home_view_test.gd after=E6
RD mod godot/tests/stats_view_test.gd
RD mod godot/tests/badge_engine_test.gd
RD mod godot/tests/t5_wiring_test.gd after=E6
RD new godot/tests/rest_days_test.gd
RD new godot/tests/rest_days_test.tscn
FXA mod phone_src/tools/calib_record.py after=PA5a
FXA mod phone_src/tools/test_calib_fit.py after=PA5a
FXA mod phone_src/calib/README.txt after=PA5a
FXB mod packaging/installer/update.ps1
FXB new packaging/test_update_channel.ps1
FXC mod godot/tests/model_store_test.gd after=PA3
FXC mod godot/tests/run_model_tests.ps1 after=PA3
FXD mod godot/tests/lifecycle_test.gd
PI2b new godot/scripts/local/local_ai.gd
PI2b new godot/scripts/local/ai_chat_rules.gd
PI2b new godot/tests/local_ai_test.gd
PI2b new godot/tests/local_ai_test.tscn
PI2b new godot/tests/ai_chat_parity_test.gd
PI2b new godot/tests/ai_chat_parity_test.tscn
PI2c new godot/scripts/local/ai_feedback_rules.gd
PI2c new godot/tests/ai_feedback_parity_test.gd
PI2c new godot/tests/ai_feedback_parity_test.tscn
PI3 new godot/scripts/ui/phone_ai_card.gd
PI3 new godot/scripts/ui/phone_ai_sheet.gd
PI3 new godot/tests/phone_ai_sheet_test.gd
PI3 new godot/tests/phone_ai_sheet_test.tscn
PSI mod godot/scripts/views/settings_view.gd after=PSA
PSI mod godot/scripts/ui/capability_panel.gd after=PSA
PSI mod godot/scripts/autoload/tts.gd
PSI mod godot/tests/settings_view_test.gd after=PSA
PSI new godot/tests/phone_settings_ai_test.gd
PSI new godot/tests/phone_settings_ai_test.tscn
PWI mod godot/scripts/practice/diary_screen.gd after=E7
PWI mod godot/scripts/practice/mission_screen.gd after=E7
PWI mod godot/scripts/main.gd after=E6
PWI mod godot/scripts/ui/ai_connect_sheet.gd
PWI mod godot/scripts/autoload/backend.gd
PWI mod godot/tests/diary_screen_test.gd
PWI mod godot/tests/diary_flow_test.gd
PWI mod godot/tests/ai_connect_test.gd
PWI mod godot/tests/mission_test.gd
PWI new godot/tests/phone_ai_wiring_test.gd
PWI new godot/tests/phone_ai_wiring_test.tscn
PZ mod README.md after=PZ
PZ mod ROADMAP.md after=PZ
PZ mod INSTALL.md after=PZ
<!-- OWN-END -->

### 3.3 소유권 검사 (합치기 전에 오케스트레이터·검토자가 돌린다. 검사기는 고치지 않는다)
- 검사기: `<scratch>\w_v201design\own_check_v201.py`(인자 `doc base [only]`, 규칙 ①~④, 마지막 줄 `files N dirs D tasks T ordered O OK|FAIL`) **그대로**. 다만 `base` 에 v201 문서 하나만 넘기면 v200 작업(E6·E7)이 소유한 파일을 못 보고, v200 문서를 넘기면 `README.md` 처럼 두 문서가 다 가진 파일에서 `after=` 가 하나뿐이라 충돌한다. 그래서 **세 문서의 OWN 줄을 순서대로 합친 기준 파일**(나중 문서가 같은 파일의 소유자를 덮는다: `v200_design` → `v200_phone_design`(이 문서가 이어받는 `PI1 PI2b PI2c PI3 PSI PWI PZ` 줄 제외) → `v201_design`)을 임시로 만들어 `base` 로 넘긴다.
```powershell
# 저장소 루트(또는 검토 worktree 루트)에서. $T 는 자기 임시 폴더. 기준 파일은 커밋하지 않는다.
function New-OwnBase([string]$root, [string]$out) {
  function Rows([string]$doc, [string[]]$skip) {
    $txt = [IO.File]::ReadAllText((Join-Path $root $doc))
    $blk = (($txt -split [regex]::Escape('<!-- OWN-BEGIN -->'))[1] -split [regex]::Escape('<!-- OWN-END -->'))[0]
    $blk -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -and ($skip -notcontains ($_ -split '\s+')[0]) }
  }
  $rows = @(Rows 'docs/v200_design.md' @()) + @(Rows 'docs/v200_phone_design.md' @('PI1','PI2b','PI2c','PI3','PSI','PWI','PZ')) + @(Rows 'docs/v201_design.md' @())
  [IO.File]::WriteAllText($out, "<!-- OWN-BEGIN -->`n" + ($rows -join "`n") + "`n<!-- OWN-END -->`n", (New-Object Text.UTF8Encoding($false)))
  "OWN_BASE rows=$($rows.Count)"
}
Set-Location 'D:\Ai\언어\app'
New-OwnBase 'D:\Ai\언어\app' "$T\own_base_v202.md"
& 'D:\Ai\언어\app\backend\.venv\Scripts\python.exe' -X utf8 "$S\w_v201design\own_check_v201.py" docs/v202_design.md "$T\own_base_v202.md"
# 파별:  ... docs/v202_design.md "$T\own_base_v202.md" PI2b,PI2c,PI3     (6파 시작 때. 이미 병합된 작업의 new 줄은 "이미 있음" 으로 FAIL 하므로 그 파의 작업만 넘긴다)
```
- **기대 출력(main `3407a82`, 전 작업)**: `OWN_BASE rows=223`, 검사기 마지막 줄 `files 71 dirs 0 tasks 12 ordered 17 OK`, 종료 0. 설계자가 작성 직후 직접 돌려 이 출력을 확인했고, 일부러 틀린 복사본 4종에서 각각 `FAIL` 줄과 종료 1 을 확인했다: ① `PZ` 가 `lifecycle_test.gd` 를 `after=` 없이 → `FAIL overlap without after=` ② `home_parts.gd` 의 `after=E6` 삭제 → `FAIL overlaps base task E6 without matching after=` ③ 없는 `lifecycle_test_nope.gd` 를 `mod` → `FAIL missing existing file` ④ 이미 있는 `local_stt.gd` 를 `new` → `FAIL new file already exists`(+ 기준 PA4 겹침 FAIL).
- 주의: 위 블록을 `.ps1` 파일로 저장해 돌릴 때는 **UTF-8 BOM** 으로 저장한다(BOM 이 없으면 PowerShell 5.1 이 `D:\Ai\언어` 경로를 깨뜨려 `OWN_BASE rows=0` 이 된다 — 설계자가 실제로 겪음). 콘솔에 붙여 넣어 돌리면 상관없다.

---

## 4. 사용자 요청 시점과 실기

### 4.1 ★키 파일(PI0, 약 5분, 0파 또는 5파 중 아무 때나)
- 사용자가 할 일: 쓰려는 업체(추천: 이미 계정이 있는 OpenCode Zen 유료 크레딧, 비용을 안 쓰려면 Gemini 무료) 사이트에서 키를 만들고 **지출 한도를 건 뒤**, 키 한 줄만 든 텍스트 파일을 저장소 **밖** `C:\Users\rtyu6\hoehwa_keys\<업체>.txt` 에 저장한다(예: `opencode_zen.txt`). 채팅에 키를 붙이지 않는다. 오케스트레이터에게 "키 파일 만들었다" 와 파일 이름만 알린다.
- PI0 가 끝나면 오케스트레이터가 결과(상태 코드·분류만)를 보고하고, 사용자는 원하면 그 파일을 지운다(실기 H7 은 폰에 직접 붙여 넣으므로 파일이 필요 없다).

### 4.2 ★실기 H7~H10·H13 (약 20~25분, 8파: T 통과 뒤)
- 시험 APK 는 정식 키로 서명(versionCode 20002, `build_android.ps1` 비 `-Debug`), 실기를 통과한 같은 APK 를 공개한다. 전달은 2.0.1 과 같은 방식.

| ID | 무엇을 | 사용자 행동 | O 기준 | 근거 |
|---|---|---|---|---|
| H7 | AI 실제 사용 | 덮어쓰기 설치 → 설정 > AI 연결 > [AI 키 넣기] → 업체 고르기 → 키 붙여 넣기 → [저장] → 동의 → [연결 시험] → 대화 1회·대화 중 교정 1회·대화 피드백 1회·미션 AI 1회·한 줄 일기 [고쳐 보기] 1회(폰 동의 시트 확인) | 각 1회 정상, 카드에 `••••xxxx` 만, "오늘 N번 요청" 이 늘어남, 크래시 0 | 화면 사진(키 가림 필요 없음: 4자만 보임) |
| H8 | 키 비노출·저장 위치 | 설정 > 음성 인식 > 진단 보기 > [결과 복사] → 채팅에 붙임(숫자만) | `user_dir_internal=1`, 화면 어디에도 키 전체 0. logcat·run-as 확인은 USB 가 될 때만, 아니면 **미검증**으로 기록 | `user_dir_internal` 줄 |
| H9 | 오류·요금 보호 | 비행기 모드에서 대화 1번 → 키를 일부러 한 글자 틀리게 다시 넣고 [연결 시험] → 일기 [고쳐 보기] | "인터넷에 연결돼 있지 않아요…", "키가 맞지 않아요…" 고정 문구, 크래시 0, 일기는 저장만(목록에 "고치기 대기"), 같은 요청이 자동으로 다시 나가지 않음("오늘 N번" 이 1씩만 늚) | 화면 사진 |
| H10 | 동기화에 키 없음 | (PC 를 쓰는 경우만) 폰↔PC 동기화 1번 → 오케스트레이터가 PC 의 `progress.json`·`prefs.json`·허브 파일에서 **키 마지막 4자만**으로 검색, 개수만 출력 | 0건 | 개수 줄 |
| H13 | 듣기 속도·쉬는 날 | 설정 > 읽어주는 속도를 1.5 쯤으로 → [영어 들어보기]. 홈 연속 카드에서 "쉬는 날 N일 남음" 칩 확인 | 1.3 보다 빠르게 들림, 칩 보임 | 사용자 보고 |

---

## 5. 작업별 O/X 합격 조건

### 5.0 공통 명령 (작성자·검토자 모두 PowerShell 5.1 에서 이 블록을 먼저 실행)
```powershell
$R   = 'D:\Ai\언어\app'
$S   = 'C:\Users\rtyu6\AppData\Local\Temp\claude\D--Ai----app\c5535f7a-0e1a-4bb6-bdc3-5597b7f84c22\scratchpad'
$W   = 'D:\Ai\언어\app_wt\v202_<작업 소문자>'            # 검토 대상 worktree
$T   = "$S\w_rev_v202_<작업 소문자>"                     # 작성자는 "$S\w_v202_<작업 소문자>"
$BASE = '<분기 커밋>'                                    # 오케스트레이터가 지시에 적는다(5파는 이 문서를 커밋한 main 커밋)
$G   = 'C:\Users\rtyu6\Desktop\Godot_v4.6.3-stable_win64.exe\Godot_v4.6.3-stable_win64_console.exe'
$PY  = 'D:\Ai\언어\app\backend\.venv\Scripts\python.exe'
$API_ARG = '--api=http://127.0.0.1:9'
New-Item -ItemType Directory -Force "$T\appdata" | Out-Null
$env:APPDATA = "$T\appdata"

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
# 상수 변이: 정확히 한 곳(UTF-8, BOM 없음). .ps1 처럼 BOM 이 있는 파일은 Mutate-Bom. 원복은 Restore.
function Mutate([string]$rel, [string]$from, [string]$to, [bool]$bom = $false) {
  $f = Join-Path $W $rel
  $txt = [IO.File]::ReadAllText($f)
  $n = ([regex]::Matches($txt, [regex]::Escape($from))).Count
  if ($n -ne 1) { throw "MUTATE_TARGET_COUNT=$n ($rel)" }
  [IO.File]::WriteAllText($f, $txt.Replace($from, $to), (New-Object Text.UTF8Encoding($bom)))
  "MUTATED $rel"
}
function Mutate-Bom([string]$rel, [string]$from, [string]$to) { Mutate $rel $from $to $true }
function Restore([string]$rel) { git -C $W checkout -- $rel; "RESTORED $rel" }
function Own-Diff([string]$task) {
  $doc = [IO.File]::ReadAllText("$W\docs\v202_design.md")
  $blk = (($doc -split [regex]::Escape('<!-- OWN-BEGIN -->'))[1] -split [regex]::Escape('<!-- OWN-END -->'))[0]
  $own = $blk -split "`n" | Where-Object { $_ -match "^$task\s" } | ForEach-Object { ($_.Trim() -split '\s+')[2] }
  $changed = @(git -C $W diff --name-only $BASE) + @(git -C $W ls-files --others --exclude-standard)
  $changed | Where-Object { $_ -and ($own -notcontains $_) -and ($_ -notmatch '\.uid$') } | Sort-Object -Unique
}
# 출력 파일들에서 비밀·개인 표식 개수(0 이어야 O)
function Leak-Count { @(Select-String -Path "$T\*.txt" -Pattern 'FAKEKEY_ZZ_','ZZ_MARK_9731','golden-dummy-credential' -SimpleMatch).Count }
```
- 새 `class_name` 이 생긴 worktree 는 시험 전에 `& $G --headless --path "$W\godot" --import *> "$T\import.txt"` 한 번.
- 화면 시험 기본 모드: `pc`, `phone`, `phonefont`, `phonedark`. 아래 "4모드" 는 이 넷이다.

### 5.1 공통 조건 X (모든 작업에 붙는다. v200 §14.1 C-0~C-17 도 그대로 적용)
- **X-0 기준선**: 작업 전 자기가 건드리는 기존 시험(없으면 `smoke`·`route_test`)의 마지막 줄을 `$T\baseline.txt` 에 적는다. 보고 맨 앞 표에 붙인다.
- **X-1 시험 출력 통과**: 자기 시험의 모든 `Run-GT` 줄이 `exit=0`, `N passed, 0 failed`, `SCRIPT_ERROR=0`, `TEST_GUARD=1`.
- **X-2 비밀값·개인 글 0**:
```powershell
Leak-Count
git -C $W grep -I -n -E "(^|[^A-Za-z0-9_])sk-(ant-|proj-)?[A-Za-z0-9_-]{20,}|AIza[0-9A-Za-z_-]{30,}|gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,}|AKIA[0-9A-Z]{16}|xox[baprs]-[A-Za-z0-9-]{10,}|-----BEGIN [A-Z ]*PRIVATE KEY-----" | Measure-Object | ForEach-Object Count
```
  기대: `0`, `0`. 누출 검사기의 양성 대조는 **메모리 안 문자열**로만 하고 `selfcheck FAIL-as-expected leak` 줄만 출력한다(표식 자체를 stdout 에 내지 않는다).
- **X-3 추적 금지물**: `git -C $W ls-files | Select-String -Pattern '(^godot/bin/|\.gdextension$|^native/_deps/|\.bin$|\.gguf$|\.onnx$|\.so$|\.dll$|\.wav$|\.mp3$|\.ogg$|\.m4a$|ai_secrets|ai_salt)'` → `godot/tests/fixtures/song/tone_8s.mp3` 한 줄뿐.
- **X-4 공개 검사**: `powershell -ExecutionPolicy Bypass -File "$W\packaging\publish_release.ps1" -Version 2.0.2 -ScanOnly; "exit=$LASTEXITCODE"` → `exit=0`, `powershell -ExecutionPolicy Bypass -File "$W\packaging\check_no_media.ps1"; "exit=$LASTEXITCODE"` → `exit=0`.
- **X-5 서버·금지 파일 무변경**: `git -C $W diff --name-only $BASE -- backend godot/project.godot godot/export_presets.cfg native godot/scripts/sync godot/scripts/autoload/route.gd godot/scripts/autoload/api.gd godot/scripts/autoload/local_api.gd godot/scripts/autoload/store.gd godot/tests/fixtures/ai_golden phone_src/tools/make_ai_golden.py phone_src/tools/ai_golden_cases.json` → 출력 없음. 파이썬 도구가 서버를 불러 쓰면 전후 `Get-FileHash "$W\backend\*.py"` 같음.
- **X-6 네트워크 코드 위치**: `Get-ChildItem "$W\godot\scripts" -Recurse -Filter *.gd | Select-String -Pattern 'HTTPRequest','HTTPClient','shell_open','request_permission' -SimpleMatch | ForEach-Object { $_.Path.Substring($W.Length + 1) } | Sort-Object -Unique` → 기준 커밋의 같은 명령 결과에 `godot\scripts\local\ai_client.gd` 하나만 더해진 목록(그 밖 새 파일 0).
- **X-7 로그 정적 검사**: `Get-ChildItem "$W\godot\scripts\local\ai_*.gd","$W\godot\scripts\local\local_ai.gd","$W\godot\scripts\core\ai_state.gd","$W\godot\scripts\ui\phone_ai_*.gd","$W\godot\scripts\practice\diary_screen.gd" -ErrorAction SilentlyContinue | Select-String -CaseSensitive -Pattern '(print|push_warning|push_error|printerr|Toast\.\w+)\(.*\b(key|body|messages|prompt|content|text|reply|_text|entry)\b'` → 0줄(파일이 아직 없으면 건너뜀. `diary_screen.gd` 는 기존 줄이 있으면 기준 커밋과 같은 수여야 한다).
- **X-8 소유 밖 수정 0**: `Own-Diff <작업>` → 출력 없음.
- **X-9 소유권 검사**: §3.3 명령에 그 파의 작업을 `only` 로 넘겨 `OK`.
- **X-10 프로세스**: 시작한 프로세스는 받은 PID 로만 종료. 보고에 "남은 프로세스·열린 포트 없음"(`Get-NetTCPConnection -State Listen -LocalPort (18791..18799) -ErrorAction SilentlyContinue` 결과 없음).
- **X-11 실제 사용자 폴더 무변경**: 시험 전후 `Get-ChildItem "$env:USERPROFILE\AppData\Roaming\Godot\app_userdata" -Recurse -File | Select FullName,Length,LastWriteTime` 목록이 같다.
- **X-12 실제 네트워크 0**: 시험·도구가 `127.0.0.1` 밖에 접속하지 않는다(가짜 서버·`transport_hook` 만). 워커는 실제 키·실제 업체 주소로 요청하지 않는다(PI0 는 오케스트레이터 몫).

### 5.2 PI1 — 키·프리셋·클라이언트·JSON·상태
- **PI1-1** `powershell -NoProfile -ExecutionPolicy Bypass -File "$W\godot\tests\run_ai_tests.ps1" *> "$T\pi1_1.txt"; "exit=$LASTEXITCODE"` → `exit=0`. 출력에 두 모드(`pc`·`phone`) 각각 `ai_secrets_test` N ≥ 50, `ai_json_test` N ≥ 60, `ai_state_test` N ≥ 40, `ai_client_test` N ≥ 150, 전부 `0 failed`, 마지막 줄 `남은 프로세스·열린 포트 없음`.
- **PI1-2** `& $PY -I -X utf8 -m unittest discover -s "$W\phone_src\tools" -p "test_fake_ai_server.py" *> "$T\pi1_2.txt"; "exit=$LASTEXITCODE"` → `exit=0`, `Ran N tests`(N ≥ 10), `OK`. 시험 중 하나는 기록 파일 전체에 가짜 키 원문 0건을 단언.
- **PI1-3 키 파일**(`ai_secrets_test` 출력 줄): 저장 뒤 파일 바이트에 가짜 키 원문·마지막 4자 0, 솔트 파일 별도, `device_id_hook` 을 다른 값으로 → `has_key` false·크래시 0·`status()=="bad"`·`.bad` 파일 생김, 잘린 파일·쓰레기 파일 → 같은 처리, 쓰기 불가 경로 → `io`, PC(시험 인자 `--phone` 없음) → `not_phone`.
- **PI1-4 키 형식 표**: 공백·탭·줄바꿈·`Bearer `·`bearer `·`"`·`'`·15자·257자·한글·제어 문자 → `ai_key_format`, 16자·256자·`_`·`-`·`.` 포함 → 통과. 행 ≥ 14.
- **PI1-5 황금 api 일치**: `ai_client_test` 가 `api_call.json` 40사례를 `transport_hook`(대본은 `AiGoldenUtil.load_api_scripts()`)으로 돌려 사례마다 ① HTTP 요청 순서·`url`·본문 `canon`·`timeout`·`key_sent`(헤더가 `Bearer <golden-dummy-credential>` 인지 sha256 으로 비교) ② `json_mode_off()` ③ 결과: 황금 `result.data`·`model` 이 같거나, 오류면 §2.1 분류표의 코드가 다음과 같음 — `api_content_null/no_choices/content_not_json/body_not_json` → `bad_format`, `api_401/403/error_echoes_key` → `ai_auth`, `api_free_tier_word` → `ai_auth`+`free_tier`, `api_402/429_*/400_quota_word` → `ai_limit`(`api_429_retry_after` 는 `retry_after == 120`), `api_404/model_not_exist_word` → `ai_model`, `api_500/503/529/error_body_list_text/400_retry_fails` → `ai_overload`, `api_418` → `ai_overload`, `api_gemini_list_error/400_unrelated_no_retry` → `bad_request`. 출력에 `AI_API_GOLDEN cases=40 match=40` 한 줄(`AiPresets.apply_overrides = false` 로 돌린다).
- **PI1-6 가짜 서버 통합**(`run_ai_tests.ps1` 의 실제 HTTP): `ok`·`ok_fenced`·`content_parts` 성공, `json_mode_reject` → 요청 2번(두 번째 `has_response_format:false`)·성공, `auth_echo_key` → `ai_auth`, `limit_retry_after` → `ai_limit`+`retry_after`, `model_404` → `ai_model`, `overload_503` → `ai_overload`, `slow`(타임아웃 2초로) → 3초 안에 `ai_overload`, 닫힌 포트 → `ai_offline`, `not_json`·`no_choices` → `bad_format`, `huge_2mb` → `bad_format`·크래시 0. `transport_hook` 으로 `TLS_HANDSHAKE_ERROR` → `ai_tls`.
- **PI1-7 리다이렉트**: `redirect_302` → 결과 오류(`ai_overload`), **peer 서버 기록 0줄**, 시험이 만든 요청 노드의 `max_redirects == 0` 단언.
- **PI1-8 키 에코**: `auth_echo_key` 결과의 `error`·`detail`·`str(결과 사전 전체)`·시험 stdout 에 가짜 키 0건(`Leak-Count` 0), 메모리 양성 대조 `selfcheck FAIL-as-expected leak` 1줄.
- **PI1-9 주소**: `http://example.com`·`file:///x`·`https://user:pw@host/v1`·`""` → `ai_url`, 가짜 서버 기록 0줄. `AiClient.test_allow_http` 기본값 false 를 단언하고 시험 끝에 false 로 되돌림. `test_allow_http` 일 때도 `http://192.168.0.1:1` → `ai_url`.
- **PI1-10 비차단·버리기**: `slow` 진행 중 메인 프레임 카운터 ≥ 50/초, `abandon_all()` → 그 호출 `ai_cancelled` 즉시, 늦게 온 응답 무시, 요청 노드는 끝난 뒤 사라짐(고아 0 복귀).
- **PI1-11 JSON**: `ai_json_test` 가 `extract_json.json` 32사례 전부 같음 → `AI_JSON_GOLDEN cases=32 match=32`, 방어 사례 ≥ 20(빈 글·`null`·숫자·2 MB·닫히지 않은 펜스·열린 `<think>`·배열 최상위) 크래시 0.
- **PI1-12 상태 표**: `AiState.use` 를 (키 있음/없음) × (동의 있음/없음) × (`lang` en/ja) × (`Route.mode` auto/phone/pc) × (PC 준비 T/F) × (PC AI 없음 T/F) 로 ≥ 30행, 기대표와 같음. `requests_today` 날짜 넘김(`StudyLog.today_override`) → 0.
- **PI1-13 누출·동기화**: 키 저장 뒤 `JSON.stringify(Store.prefs)`·`Store.progress`·`StudyLog.snapshot()`·`SyncDoc.extract(…)` 결과·`user://test_*` 모든 파일(키 파일 제외; 키 파일은 평문 0)에서 가짜 키·마지막 4자 0. prefs 에 일부러 `ai_key` 를 넣어도 `SyncDoc` 결과에 0. `AiState.NEW_PREFS ∩ SyncDoc.SHARED_PREFS.keys() == []`.
- **PI1-14 일부러 틀린 응답**: 빈 본문·`choices` 없음·`content` 배열·`null`·HTML → 크래시 0, `bad_format`.
- **PI1-15 상수 변이**: ① `Mutate 'godot\scripts\local\ai_client.gd' 'max_redirects = 0' 'max_redirects = 8'` → `run_ai_tests.ps1` `exit=1`(PI1-7 FAIL), `Restore` 뒤 `exit=0`. ② 키 치환 줄: `Mutate 'godot\scripts\local\ai_client.gd' '.replace(key, MASK)' '.replace("", MASK)'`(이 문자열이 파일에 정확히 1번 있게 워커가 쓴다) → `run_ai_tests.ps1` `exit=1`(PI1-8 FAIL), 원복 뒤 `exit=0`.
- **PI1-16 정적**: `Get-ChildItem "$W\godot\scripts" -Recurse -Filter *.gd | Select-String 'get_key\(' | ForEach-Object { "{0}:{1}" -f $_.Filename, $_.LineNumber }` → `ai_secrets.gd` 의 정의 1줄 + `ai_client.gd` 1줄뿐. `ai_client.gd` 밖 `HTTPRequest` 0(X-6). 키를 담는 멤버 변수·시그널 0(코드 읽기 + 시험이 `AiClient` 의 스크립트 변수 목록 `get_script_property_list()` 에 문자열 값으로 키가 없음을 단언).
- **금지**: X-5·X-6·X-7·X-12, `route.gd`·`api.gd`·`local_api.gd` 수정, 황금·생성기 수정, 실제 키·실제 업체 접속, X-8.

### 5.3 RD — 쉬는 날
- **RD-1** `Run-GT rest_days_test pc`, `Run-GT rest_days_test phone` → X-1, N ≥ 80. `Run-GT streak_test pc` → passed ≥ 기준선 + 20, 0 failed.
- **RD-2 R=0 동등**: `rest_days_test` 가 시험 안에 옮겨 둔 **옛 알고리즘 사본**과 `StreakCalc.settle(…, {}, 0)` 을 시드 고정 무작위 2,000사례(done·frozen·tokens·awarded·today 무작위, 미래 날 포함)로 비교 → 출력 `RD_EQUIV_R0 cases=2000 same=2000`.
- **RD-3 규범 표**(T = 2026-10-16 금요일 = 0, -1 목, -2 수, -3 화, -4 월, -5 지난주 일, -6 지난주 토; R = 2; awarded 0; 오늘 공부 안 함). 시험이 아래 행을 그대로 단언(결과 `frozen`·`rest` 는 날 오프셋 집합):

| # | 입력 done / frozen / rest / tokens | 기대 frozen | rest | tokens | used | rest_used | streak |
|---|---|---|---|---|---|---|---|
| 1 | {-3,-2} / {} / {} / 1 | {-1} | {-1} | 1 | 0 | 1 | 2 |
| 2 | {-4} / {} / {} / 1 | {-3,-2,-1} | {-3,-2} | 0 | 1 | 2 | 1 |
| 3 | {-4} / {} / {} / 0 | {} | {} | 0 | 0 | 0 | 0 |
| 4 | {-6} / {} / {} / 2 | {-5,-4,-3,-2,-1} | {-5,-4,-3} | 0 | 2 | 3 | 1 |
| 5 | {-6} / {} / {} / 1 | {} | {} | 1 | 0 | 0 | 0 |
| 6 | 2번 결과를 그대로 다시 | 같음 | 같음 | 0 | 0 | 0 | 1 |
| 7 | {-6,-3} / {-5,-4} / {-5,-4} / 1 | {-5,-4,-2,-1} | {-5,-4,-2} | 0 | 1 | 1 | 2 |
| 8 | 2번 입력, R = 1 | {} | {} | 1 | 0 | 0 | 0 |
| 9 | {-4,+1} / {} / {} / 1 (시계 되돌림) | {}(입력 그대로) | {} | 1 | 0 | 0 | 0 |
| 10 | {-3} / {-2} / {} / 0 (옛 보호권 날) | {-2,-1} | {-1} | 0 | 0 | 1 | 1 |
| 11 | {-4} / {-3} / {} / 0, R = 0 (환불) | {} | {} | 1 | 0 | 0 | 0 |
| 12 | {-4} / {-3} / {} / 0, R = 2 | {-3,-2,-1} | {-2,-1} | 0 | 0 | 2 | 1 |
| 13 | {-3} / {} / {-2} / 1 (rest ⊄ frozen 입력) | {-2,-1} | {-2,-1} | 1 | 0 | 2 | 1 |
  (13번: 입력 rest {-2} 는 frozen 에 없어 버려진 뒤, 틈 -2·-1 이 새 쉬는 날로 이어진다.)
- **RD-4 저장·호환**: `freeze.en.rest` 저장·다시 읽기 같음, `rest` 키 없는 옛 파일 → `[]`·연속 그대로, `frozen` 에 없는 `rest` 날·틀린 날짜·숫자·중복 → 버림, 400일 지난 `rest` 저장 때 지움, `apply_sync` 뒤 `freeze.*.rest` 그대로, `SyncDoc.extract` 결과 문자열에 `"rest"` 키 0(시험이 `freeze` 부분이 없음을 확인), `StudyLog.settle` 두 번 연속 → 두 번째 dirty 아님.
- **RD-5 화면**: 홈 연속 카드 `Stones` 의 `states` 에 `"rest"`(쉬는 날)·`"frozen"`(보호권 날) 구분, 접근성 이름 `"쉬는 날"`, 칩 `"쉬는 날 2일 남음"`→쉬는 날 하나 쓴 뒤 `"쉬는 날 1일 남음"`, 목표 카드 설명 == `GoalCard.EXPLAIN` 이고 "보호권 개수보다 많은 날을 놓치면"·"보호권은 그대로 남아요"·"2일까지는 보호권 없이" 포함, 한 줄형 끝 `"쉬는 날 %d일 남음"`, 토스트 `TXT_REST_USED` 가 쉬는 날을 새로 쓴 settle 에서 정확히 1번(같은 날 두 번째 settle 에서 0번). 화면 글 연속 5자리 숫자 0(C-15) + selfcheck.
- **RD-6 기존 시험 변경 범위**:
```powershell
git -C $W diff -U0 $BASE -- godot/tests/study_log_test.gd godot/tests/study_log_fun_test.gd godot/tests/home_view_test.gd godot/tests/stats_view_test.gd godot/tests/badge_engine_test.gd godot/tests/t5_wiring_test.gd |
  Select-String '^[-+]' | Where-Object { $_.Line -notmatch '^(\+\+\+|---) ' -and $_.Line -notmatch '^\+.*rest_per_week_override' -and $_.Line -notmatch '^\+\s*#' }
```
  기대: 출력 없음(바꾼 파일이 없으면 그대로 O). 그 시험들(`study_log_test`·`study_log_fun_test`·`badge_engine_test`·`t5_wiring_test` pc, `home_view_test`·`stats_view_test` 4모드 `-Api`) passed ≥ 기준선, 0 failed. `streak_test.gd` 는 행 추가만(`git diff -U0 … streak_test.gd | Select-String '^-\s*ok\('` 0줄).
- **RD-7 배지**: 쉬는 날로 이어진 7일 공부(달력 9일) → `StudyLog.longest_streak == 7`, `BadgeEngine` 의 `streak_best` ≥ 7 → `streak_7` 받음(시험 줄).
- **RD-8 일부러 틀린 입력**: `rest` 키에 float·문자열·NaN, `rest_per_week` -3·99(→ 0·7), `freeze.rest` 가 배열이 아님 → 크래시 0, 정규화.
- **RD-9 상수 변이**: `Mutate 'godot\scripts\core\streak_calc.gd' 'const REST_PER_WEEK := 2' 'const REST_PER_WEEK := 0'; Run-GT rest_days_test pc; Restore 'godot\scripts\core\streak_calc.gd'; Run-GT rest_days_test pc` → 첫 실행 `exit=1`, 원복 뒤 `exit=0`.
- **금지**: `sync/*`·`store.gd`·`home_model.gd`·`today_view.gd`·`badge_*.gd` 수정, `KNOWN_KEYS`·`VERSION` 변경, 기존 시험 단언 수정(RD-6), X-8.

### 5.4 FXA — 녹음 세트 접두사
- **FXA-1** `& $PY -I -X utf8 -m unittest discover -s "$W\phone_src\tools" -p "test_calib_fit.py" *> "$T\fxa_1.txt"; "exit=$LASTEXITCODE"` → `exit=0`, `Ran N tests`(N ≥ 기준선 + 6), `OK`. 새 시험: 가짜 녹음기로 `--set-tag s8` → 모든 클립 id 가 `s8_u` 로 시작·`manifest.set == "s8"`, 다른 태그 두 번 → id 겹침 0, 태그 생략 → 자동 태그가 `SET_TAG_RE` 에 맞음, 틀린 태그 표(`""`, `A1`, `1a`, `a b`, `a`×13, `../x`, `s-8`) → `CALIB_REC_FAIL set_tag`·종료 2·폴더 안 만듦.
- **FXA-2 건조 실행**: `& $PY -I -X utf8 "$W\phone_src\tools\calib_record.py" --out "$T\rec_dry" --dry-run --set-tag s8 *> "$T\fxa_2.txt"; "exit=$LASTEXITCODE"` → `exit=0`, 마지막 줄이 `CALIB_REC_DRY_RUN sentences=30 clips=60 (no microphone opened, nothing written) set=s8`, `$T\rec_dry` 없음 또는 비어 있음, 동의 문구 줄 변경 0(`git diff $BASE -- phone_src/tools/calib_record.py | Select-String 'CONSENT_TEXT'` 의 `-` 줄 0).
- **FXA-3 틀린 태그**: `… --dry-run --set-tag "A1"; "exit=$LASTEXITCODE"` → 출력 `CALIB_REC_FAIL set_tag`, `exit=2`.
- **FXA-4 개인정보 불변**: `Select-String -Path "$W\phone_src\tools\calib_record.py" -Pattern 'logging','\.log\b'` → 0줄, X-3.
- **FXA-5 상수 변이**: `Mutate 'phone_src\tools\calib_record.py' 'r"^[a-z][a-z0-9]{0,11}$"' 'r"^.*$"'` → FXA-1 `exit=1`, 원복 뒤 `exit=0`.
- **금지**: `calib_fit.py`·`calib_pc_run.py`·`calib_phone.gd`·`docs/v201_design.md` 수정, 마이크 열기(시험은 가짜 녹음기만), X-8.

### 5.5 FXB — 업데이터 태그 필터
- **FXB-1** `powershell -NoProfile -ExecutionPolicy Bypass -File "$W\packaging\test_update_channel.ps1" *> "$T\fxb_1.txt"; "exit=$LASTEXITCODE"` → `exit=0`, 마지막 줄 `UPDATE_CHANNEL_TEST_OK cases=N`(N ≥ 10). 시험 방법: `[System.Management.Automation.Language.Parser]::ParseFile` 로 `update.ps1` 를 읽어 `FunctionDefinitionAst` 중 `Test-AppTag`·`Select-UpdateRelease` 만 꺼내 `[scriptblock]::Create($ast.Extent.Text)` 로 정의(본문은 실행하지 않음). 사례: `[models-1, v2.0.2]` → v2.0.2, `[draft v2.0.3, models-1, v2.0.2]` → v2.0.2, `[models-1]` → `$null`, `[]` → `$null`, `[$null, v2.0.1]` → v2.0.1, `V2.0.1` → 앱 태그(대소문자 무시), `v` 만 → 아님, `release-2` → 아님, `Test-AppTag $null` → false, 안정 분기 throw 문구에 "앱 버전이 아니에요" 포함(AST 의 `Get-LatestRelease` 본문 문자열 검사).
- **FXB-2 파싱·BOM**: `$e=$null; [void][System.Management.Automation.Language.Parser]::ParseFile("$W\packaging\installer\update.ps1",[ref]$null,[ref]$e); $e.Count` → `0`. `[IO.File]::ReadAllBytes("$W\packaging\installer\update.ps1")[0..2] -join ','` → `239,187,191`.
- **FXB-3 변경 범위**: `git -C $W diff -U0 $BASE -- packaging/installer/update.ps1` 의 바뀐 덩어리가 `Get-LatestRelease` 안과 새 함수 두 개뿐(검토자가 덩어리 머리 줄 번호로 확인), `-Source` 줄 변경 0.
- **FXB-4 상수 변이**: `Mutate-Bom 'packaging\installer\update.ps1' "-match '^v\d'" "-match '^.'"` → FXB-1 `exit=1`, `Restore` 뒤 `exit=0`.
- **금지**: `build_dist.ps1`·`install.ps1`·`release.json`·다른 `installer/*` 수정, 실제 GitHub 접속(시험은 AST 만), BOM 제거, X-8.

### 5.6 FXC — 모델 시험 부재 단언
- **FXC-1** `powershell -NoProfile -ExecutionPolicy Bypass -File "$W\godot\tests\run_model_tests.ps1" *> "$T\fxc_1.txt"; "exit=$LASTEXITCODE"` → `exit=0`, `model_store_test` passed ≥ 기준선 + 2·`0 failed`, 카드 시험 4모드 각 ≥ 40·`0 failed`, 마지막 줄 `남은 프로세스·열린 포트 없음`.
- **FXC-2 지연 정착**: `$env:MODEL_SRV_LOGDELAY_STORE='600'; $env:MODEL_ONLY='model_store_test'; powershell -NoProfile -ExecutionPolicy Bypass -File "$W\godot\tests\run_model_tests.ps1" *> "$T\fxc_2.txt"; "exit=$LASTEXITCODE"; Remove-Item Env:MODEL_SRV_LOGDELAY_STORE, Env:MODEL_ONLY` → `exit=0`, 그 시험 로그(러너가 출력한 로그 경로)에 `selfcheck FAIL-as-expected late_line` 1줄 이상, `absence: settled` 줄 ≥ 7, settle 시간 초과 0 단언 PASS.
- **FXC-3 기본은 지연 없음**: FXC-1 출력에서 `model_store_test` 서버 줄에 `(log delay` 문구 0.
- **FXC-4 상수 변이**: `Mutate 'godot\tests\model_store_test.gd' 'return maxi(int(t), -1) # a negative number' 'return 0 * maxi(int(t), -1) # a negative number'` 뒤 FXC-2 명령 → `exit=1`(정착 대기가 늦은 줄을 놓쳐 단언 FAIL), `Restore` 뒤 FXC-2 → `exit=0`.
- **금지**: 기존 단언의 기대 숫자·글 변경(`git diff -U0 … model_store_test.gd | Select-String '^-\s*ok\('` 의 줄은 바뀐 5자리 단언의 같은 글이 `+` 쪽에 그대로 있어야 함), `fake_model_server.py`·`stt_model_card_test.gd` 수정, 서버에 지연을 기본으로 켜기, X-8.

### 5.7 FXD — `lifecycle_test` 격리
- **FXD-1** 새 APPDATA 로 `Run-GT lifecycle_test pc` → X-1, passed = 기준선 + 1, 출력에 `PASS  user://reading was not made`.
- **FXD-2 이어 돌리기**: 같은 APPDATA 로 `Run-GT lifecycle_test pc` 직후 `Run-GT course_today_test pc -Api` → 둘 다 X-1(2.0.1 T-4 의 실패 재현이 사라짐).
- **FXD-3 남는 폴더 0**: `@(Get-ChildItem "$T\appdata" -Recurse -Directory -Filter 'test_lifecycle_reading' -ErrorAction SilentlyContinue).Count` → `0`, `@(Get-ChildItem "$T\appdata" -Recurse -Directory -Filter 'reading' -ErrorAction SilentlyContinue).Count` → `0`.
- **FXD-4 상수 변이**: `Mutate 'godot\tests\lifecycle_test.gd' 'rv.storage_dir = READING_DIR' 'pass # rv.storage_dir = READING_DIR'` 뒤 새 APPDATA 로 FXD-1 → `exit=1`, 원복 뒤 `exit=0`.
- **금지**: `reading_view.gd`·`course_today_test.gd` 수정, 기존 단언 변경, X-8.

### 5.8 PI2b — `LocalAi`·`AiChatRules`
- **PI2b-1** `Run-GT ai_chat_parity_test pc`·`phone` → X-1, N ≥ 500. `Run-GT local_ai_test pc`·`phone` → X-1, N ≥ 120.
- **PI2b-2 황금 일치**: chat 68·fix 41 사례마다 `AiGoldenUtil` 의 가짜 엔진·R-MAP 으로 ① 엔진 호출 인자(문자열까지) ② 결과 ③ 시도 횟수 같음 → `AI_CHAT_GOLDEN chat=68/68 fix=41/41`. 순수 함수 사례 `ko_text` 80·`clean_hist` 20·`question` 46·`prompts` 34(rules 18 + context 16)·`norm_text` 38 전부 같음 → `AI_PURE_GOLDEN ko=80/80 clean_hist=20/20 question=46/46 prompts=34/34 norm_text=38/38`.
- **PI2b-3 가용성·네트워크 0**(`local_ai_test`): 키 없음 → `/chat`·`/fix` `no_ai`, 동의 없음 → `no_ai`, `lang:"ja"` → `ja_ai_pc`, PC(`--phone` 없음) → `not_on_phone`, `POST /lesson`+`source:"ai"` → `LocalApi.available == false` — 모두 `LocalAi.engine_calls` 불변·`Api.sent_count` 불변.
- **PI2b-4 일기 방어선(S14)**: 키·업체 동의는 있고 `phone_diary_consent` 없음 → `/fix` `private:true`(그리고 `"true"`·`1`) `is_available_for == false`·`handle` 이 `no_ai`+`TEXT_DIARY_CONSENT`·엔진 호출 0. `private:false` 는 통과. gemini + `phone_diary_trains_ok` false → `TEXT_DIARY_TRAINS`. **`Api` 전송 실패 대체 경로**: 시험이 닫힌 PC 주소(`Api.base_url = "http://127.0.0.1:9"`, 자동 모드, PC 준비로 흉내)로 `/fix` private 를 보내면 `_can_fall_back` 이 거짓이 되어 엔진 호출 0(가짜 엔진 기록 0).
- **PI2b-5 응답 계약**: `via == "phone"`, `degraded == []`, `tts_chunks` 키 없음, `/fix` private 응답 키 == `fix, fix_ko, reading, pron`(서버와 같음), 일기 표식 `ZZ_MARK_9731` 이 출력·`user://test_*` 에 0(메모리 양성 대조 `selfcheck FAIL-as-expected leak`).
- **PI2b-6 상수 변이**: `Mutate 'godot\scripts\local\ai_chat_rules.gd' 'Speak simply and clearly.' 'Speak simply.'`(그 글이 파일에 정확히 1번; 아니면 워커가 `LEVEL` 안의 유일한 다른 문장을 골라 보고) → `ai_chat_parity_test pc` `exit=1`, 원복 뒤 0.
- **금지**: `route.gd`·`api.gd`·`local_api.gd`·황금 수정, 로그(X-7), `course` 필드 처리, `ai_feedback_rules.gd` 만들기(PI2c), X-8.

### 5.9 PI2c — `AiFeedbackRules`
- **PI2c-1** `Run-GT ai_feedback_parity_test pc`·`phone` → X-1, N ≥ 180.
- **PI2c-2 황금 일치**: feedback 28·judge 35 사례 R-MAP 일치 → `AI_FEEDBACK_GOLDEN feedback=28/28 judge=35/35`.
- **PI2c-3 판정 증거**: `judge_evidence_not_in_learner_text`·`judge_evidence_from_partner_line`·`judge_prompt_injection_line` 사례가 `done:false` 인 것을 이름으로 따로 단언(황금과 같음의 중복 확인).
- **PI2c-4 미션 데이터**: 시험이 `res://data/pack/missions.json` 의 sha256 이 `3c89d619e110637021cfc863d13a8da1ac84565407fc3d3936c7f020b675ec1d` 인지 단언(다르면 서버와 어긋남 — `GOLDEN_MISSIONS_DIFF` 줄로 FAIL).
- **PI2c-5 상수 변이**: `Mutate 'godot\scripts\local\ai_feedback_rules.gd' 'const JUDGE_MAX_TURNS := 24' 'const JUDGE_MAX_TURNS := 23'` → `exit=1`(`judge_history_cut_24` FAIL), 원복 뒤 0.
- **금지**: `local_ai.gd`(PI2b) 수정, 로그(X-7), X-8.

### 5.10 PI3 — AI 카드·시트
- **PI3-1** `Run-GT phone_ai_sheet_test` 4모드 + `pc`, `-Api` → X-1, phone N ≥ 90.
- **PI3-2 버튼 흐름(C-14, `press:` ≥ 16)**: 카드 `PhoneAiOpenBtn` → `AiPreset_opencode_zen` → `AiKeyEdit` 에 가짜 키(`secret == true` 단언) → `AiSaveBtn` → `AiConsentSheet` 문단에 "OpenCode Zen" → `AiConsentAgree` → 키 칸 빈 글·카드에 `"••••" + 마지막 4자` → `PhoneAiTestBtn`(가짜 `transport_hook` 200) → `PhoneAiResult == "연결됐어요."`·`TXT_COUNT` 의 N 이 1 늘어남 → `PhoneAiModelsBtn`(가짜 목록 2개) → 하나 고르면 `ai_model` 저장 → `PhoneAiClearBtn` → 확인 → 카드 `TXT_NONE`·`has_key false`·`phone_ai_consent` 에서 그 프리셋 없음. 매 단계 뒤 다음 버튼 `visible`·`disabled` 아님.
- **PI3-3 화면에 키 0**: 저장 뒤 시트·카드의 모든 `Label`/`Button`/`LineEdit`/툴팁 글에서 가짜 키 전체·앞 8자 0, 마지막 4자는 `••••` 뒤에만. 연속 5자리 숫자 0(C-15). 일부러 키를 라벨에 넣은 가짜 화면으로 검사기가 잡는 `selfcheck FAIL-as-expected key_on_screen`.
- **PI3-4 취소·형식**: `AiConsentCancel` → `has_key false`·prefs 변화 0·요청 0. 형식 틀린 키 → `Route.text_for("ai_key_format")` 표시·저장 0·동의 시트 안 열림.
- **PI3-5 클립보드**: 붙여 넣은 키와 같은 클립보드 → 저장 뒤 `clipboard_set_hook("")` 1번, 다른 글이면 0번.
- **PI3-6 무료 학습 업체**: `AiPreset_gemini` 의 안내 글 == `AiPresets.NOTE_GEMINI`, 저장 뒤 `phone_diary_trains_ok` 는 false 그대로.
- **PI3-7 문구**: 카드에 `LIMIT_TEXT`·`SPEND_TEXT`·`CAPTURE_TEXT`·`RESET_NOTE` 가 그대로 있음. PC 모드에서 `PhoneAiCard.build` → `TXT_PC` 한 줄, `AiSecrets` 호출 0(시험 훅 카운터).
- **PI3-8 오류 표시**: `test_call` 결과 `ai_auth`·`ai_offline`·`ai_limit`·`ai_model` → `Route.text_for(code)` 글, 상태 점 색, 키 유지.
- **PI3-9 레이아웃**: 412x915·1.5배·다크에서 가로 스크롤 0, 눌리는 곳 높이 ≥ 44.
- **PI3-10 상수 변이**: `Mutate 'godot\scripts\ui\phone_ai_sheet.gd' '_key_edit.secret = true' '_key_edit.secret = false'` → `phone_ai_sheet_test phone` `exit=1`, 원복 뒤 0.
- **금지**: `HTTPRequest` 직접 사용, `AiSecrets.get_key` 호출, 키를 변수·시그널에 보관, `settings_view.gd` 수정(PSI), X-8.

### 5.11 PSI — 설정 연결·속도
- **PSI-1** `Run-GT phone_settings_ai_test` 4모드 + `pc` → X-1, phone N ≥ 50. `Run-GT settings_view_test pc -Api`·`phone -Api` → passed ≥ 기준선 + 8, 0 failed. `Run-GT phone_settings_asr_test phone -Api` 기준선 이상.
- **PSI-2 위치·문구**: 폰 설정 "엔진" 구역 순서 `SttSection` → `PhoneAiSection`(제목 "AI 연결") → 처리 위치 → 기능 현황, `PhoneAiSection` 안에 `PhoneAiCard`. PC 앱에는 `PhoneAiSection` 0·`AiConnectCard` 그대로. `Route.text_for("no_ai")` 안에 "설정 > AI 연결" 포함 단언.
- **PSI-3 버튼 흐름(`press:` ≥ 8)**: 설정에서 `PhoneAiOpenBtn` → 시트 열림 → (가짜 저장) → 카드 다시 그려짐(키 있음 글), 기능 현황의 `chat`·`fix`·`feedback` 줄이 "폰"(가짜 `LocalAi` 를 `LocalApi.handler_override["ai"]` 로).
- **PSI-4 기능 현황**: `CapabilityPanel` 키 16개 그대로, `REASONS["no_ai"]` 가 §2.6 문구, 다른 줄 변경 0(`git -C $W diff -U0 $BASE -- godot/scripts/ui/capability_panel.gd | Select-String '^[-+]\s*"' ` 의 줄이 `no_ai` 한 쌍뿐).
- **PSI-5 속도**: 폰 앱 슬라이더 `max_value == 1.6`, PC 앱 `1.3`, `min_value == 0.6`, `step == 0.05`. `Tts.normal_speed()` 표: pref 1.5 + 엔진 system → 1.5, 엔진 pc → 1.3, pref 2.0 → 1.6(system), pref 0.3 → 0.6, pref `"x"` → 기본(1.0)으로 처리·크래시 0. `Tts.SLOW_SPEED == 0.75`. 폰 + 엔진 pc + 값 1.5 → `TXT_SPEED_PC_CAP` 보임, 1.2 → 안 보임.
- **PSI-6 상수 변이**: ① `Mutate 'godot\scripts\autoload\tts.gd' 'const SPEED_MAX_PHONE := 1.6' 'const SPEED_MAX_PHONE := 1.3'` → `settings_view_test phone -Api` `exit=1`, 원복 뒤 0. ② `Mutate 'godot\scripts\ui\capability_panel.gd' '"no_ai": "설정 > AI 연결에서' '"no_ai": "AI 연결에서'` → `phone_settings_ai_test phone` `exit=1`, 원복 뒤 0.
- **금지**: `phone_ai_card.gd`·`phone_ai_sheet.gd`(PI3)·`stt_model_card.gd`·`model_store.gd` 수정, 서버 속도 변경, `SLOW_SPEED` 변경, X-8.

### 5.12 PWI — 일기·미션·홈·메뉴
- **PWI-1** `Run-GT phone_ai_wiring_test` 4모드 + `pc`, `-Api` → X-1, phone N ≥ 100.
- **PWI-2 기존 시험**: `diary_screen_test`·`diary_flow_test`·`ai_connect_test`·`mission_test` 를 `pc -Api`·`phone -Api` 로 → passed ≥ 기준선, 0 failed. 단언 삭제는 §2.7 의 두 개뿐:
```powershell
git -C $W diff -U0 $BASE -- godot/tests/diary_screen_test.gd godot/tests/diary_flow_test.gd godot/tests/mission_test.gd | Select-String '^-\s*ok\('
git -C $W diff -U0 $BASE -- godot/tests/ai_connect_test.gd | Select-String '^-\s*ok\('
```
  기대: 첫 명령 출력 없음, 두 번째는 정확히 2줄("opens no sheet" 이 든 홈 [AI 연결하기] 단언, "it shows the sentence").
- **PWI-3 일기 폰 경로(`press:` ≥ 10)**: 폰 키·업체 동의 있음(가짜 `LocalAi` 엔진), 일기 쓰기 → [고쳐 보기] → `DiaryPhoneConsent` 시트(문단에 업체 라벨) → [나중에] → 가짜 엔진 호출 0·글은 입력칸 그대로 → 다시 [고쳐 보기] → [동의하고 고치기] → 엔진 호출 = 문장 수, 결과 화면·복습 카드 안내, `phone_diary_consent[preset] == true`. PC 경로(`ai_hook` 으로 PC 흉내)는 기존 `diary_consent` 시트·문구 그대로.
- **PWI-4 무료 학습 업체**: gemini → [고쳐 보기] `disabled`, `NOTE_TRAINS` 보임, `DiaryTrainsSwitch` → `DiaryTrainsSheet` [취소] → 그대로 꺼짐·요청 0 → 다시 [켜기] → 켜짐 → 폰 동의 시트 → 요청.
- **PWI-5 일기 원문 0**: 일기 글에 `ZZ_MARK_9731` 을 넣고 흐름 전체를 돈 뒤 출력·`user://test_*`(일기 파일 제외)·`Store.prefs`·`SyncDoc.extract` 에 0, 메모리 양성 대조 줄.
- **PWI-6 미션**: 폰 + `phone_ready` → `_llm_down() == false`(AI 모드 버튼 기본), 폰 + 키 없음 + PC 없음 → `true`(대본 모드 권장), PC 앱은 `Backend.llm_missing()` 과 같음(표 ≥ 6행).
- **PWI-7 홈·메뉴·배너**: 폰 + READY + PC AI 없음 + 키 없음 → `home_slot` body 에 "AI 연결"·"PC" 포함, action `""`; 키 있음 → title "PC의 AI가 꺼져 있어요". 폰에서 `Store.request_ai_connect()` → `PhoneAiSheet.is_open()`, `Api.sent_count` 불변. 폰 시작 화면 안내 글 == §2.7 문구. `Backend.llm_missing_text()` 폰 == 새 `NOT_CONNECTED_PHONE_TEXT`(“PC” 포함).
- **PWI-8 일부러 틀린 입력**: 키는 있는데 `Route` 가 none·키 파일 손상(`AiSecrets.device_id_hook` 변경)·프리셋 `""`·`phone_ai_consent` 가 숫자·`phone_diary_consent` 가 문자열 → 크래시 0, 일기는 "저장만".
- **PWI-9 `main.gd` 범위**: `git -C $W diff -U0 $BASE -- godot/scripts/main.gd | Select-String '^[-+][^-+]'` 의 줄이 `_on_ai_connect` 폰 분기와 시작 화면 안내 줄뿐(검토자가 줄 번호로 확인), `"AiConnectSheet.open(self)"` 문자열 남음.
- **PWI-10 상수 변이**: `Mutate 'godot\scripts\practice\diary_screen.gd' 'const PHONE_CONSENT_PREF := AiState.PREF_DIARY_CONSENT' 'const PHONE_CONSENT_PREF := CONSENT_PREF'` → `phone_ai_wiring_test phone -Api` `exit=1`(PC 동의만으로 폰 요청이 나감을 잡음), 원복 뒤 0.
- **금지**: `talk_view.gd`·`home_ai.gd`·`route.gd`·`api.gd` 수정, 일기 요청 모양 변경, 허용된 두 단언 밖 기존 단언 변경, X-8.

### 5.13 PZ — 문서
- **PZ-1** `git -C $W diff --stat $BASE` 가 `README.md`·`ROADMAP.md`·`INSTALL.md` 셋만.
- **PZ-2** `Select-String -Path "$W\README.md" -Pattern 'AI 연결','지출 한도','Gemini','쉬는 날','1.6' -SimpleMatch` 각 ≥ 1, `ROADMAP.md` 에 `2.0.2`·"알려진" ≥ 1, `INSTALL.md` 에 "키 지우기" ≥ 1.
- **PZ-3** 사실 대조(오케스트레이터): README 의 업체·모델 이름·주소가 `AiPresets`(PI0 반영 뒤)와 같다, 쉬는 날 수가 `StreakCalc.REST_PER_WEEK` 와 같다.
- **PZ-4** `Select-String -Path "$W\README.md","$W\ROADMAP.md","$W\INSTALL.md" -Pattern 'C:\\Users','hoehwa_keys','FAKEKEY','secrets'` 새 줄 0, `WORKLOG.md`·버전 숫자 변경 0.

---

## 6. PI0·통합 시험 T(2.0.2)·공개

### 6.1 PI0 — 실제 키 1회 시험 (오케스트레이터, ★키 파일 뒤)
- 오케스트레이터가 `$S\w_orch_v202\pi0_probe.py` 를 쓴다(저장소 밖, 커밋 안 함). 규칙: `backend\.venv` 의 `requests` 로, 키는 `--key-file <경로>` 의 첫 줄을 프로세스 안에서 읽고, 출력 전 모든 글에서 키 전체·8자 이상 부분을 `<key>` 로 바꾼다. 요청은 업체마다 **최대 6번**(아래), 각 요청 본문은 `"Say ok"` 한 줄 수준(요금 1센트 미만, 추측).
- 기록(`$S\w_orch_v202\pi0_result.json`, 키 0): 업체·주소·모델·HTTP 상태·분류(§2.1 규칙)·`response_format` 수용 여부·system 메시지가 마지막에 와도 되는지·`/models` 목록 개수·지연 ms.

| ID | 시험 | 결정되는 값 |
|---|---|---|
| PI0-1 | Zen 유료 `deepseek-v4.1-flash` 를 `https://opencode.ai/inference/v1` 과 `https://opencode.ai/inference/openai/v1` 로 | `opencode_zen.base_url` |
| PI0-2 | Zen 무료 `deepseek-v4.1-flash-free` 직접 호출 → 거부 문구에 free tier 류가 있는지 | `free_tier` 분류 확인 |
| PI0-3 | `response_format:{"type":"json_object"}` 수용, system 메시지가 끝에 와도 되는지 | `json_mode`·`single_system` |
| PI0-4 | (키가 있으면) Gemini 로 같은 시험 + `/models` 에서 Flash 계열 최신 id | `gemini.model`·`single_system` |
| PI0-5 | 출력·로그·셸 기록에 키 0(`Select-String` 로 키 **마지막 4자만**으로 검색, 개수만 출력) | 0 |
- 결과 반영: `AiPresets.PI0_OVERRIDES` 와 `PI0_CONFIRMED := true` 를 바꾸는 **오케스트레이터 커밋 1개**(PI1 소유 파일이므로 PI1 병합 뒤, Sol 검토 1회: `run_ai_tests.ps1` 재실행 + `AI_API_GOLDEN … match=40`(덮어쓰기 끄고) 유지). PI0 결과에 따라 오류 분류가 서버와 달라야 하면(예: 새 오류 모양) 그때만 PI1 을 다시 연다.

### 6.2 통합 시험 T (8파, 오케스트레이터가 main 에서 직접)
- **T-0 버전·게이트**: `godot/project.godot` `config/version="2.0.2"`, `export_presets.cfg` `version/code=20002`(오케스트레이터 커밋), `Select-String "$R\godot\scripts\local\ai_presets.gd" -Pattern 'const PI0_CONFIRMED := true' -SimpleMatch` 1줄(**없으면 공개 중단**).
- **T-1 새 시험 전부**: `run_ai_tests.ps1`, `ai_chat_parity_test`·`ai_feedback_parity_test`·`local_ai_test`(pc·phone), `phone_ai_sheet_test`·`phone_settings_ai_test`·`phone_ai_wiring_test`(4모드 + pc), `rest_days_test`(pc·phone), `streak_test`, `run_model_tests.ps1`, `lifecycle_test`, 그리고 PI2c 병합 뒤 `local_ai_test` 에 `/feedback`·`/missions/judge` 가 `LocalAi` 를 거쳐 처리되는지(가짜 엔진) 확인 줄. 전부 X-1.
- **T-2 도구**: `make_ai_golden.py --check`(종료 0), `test_make_ai_golden.py`, `test_fake_ai_server.py`, `test_calib_fit.py`, `test_update_channel.ps1`, `make_score_golden.py --check`, `course_src\tools` unittest, `check_course.py --strict`.
- **T-3 네이티브 회귀(N0 뒤)**: §5.0(201) `Prep-Native` → `native_bridge_test` N ≥ 106, 0 failed.
- **T-4 회귀**: `$S\w_t9\run_godot.ps1 -Project 'D:\Ai\언어\app\godot' -Tag v202` 전체 → 전부 0 failed·SCRIPT ERROR 0·TEST_GUARD 1(FXD 로 `course_today` 4회 실패가 사라져야 함). 일본어 시험 변경 0(`git diff v2.0.1 -- godot/tests/*ja*` 비어 있음; v2.0.1 태그가 아직 없으면 `$BASE` 기준).
- **T-5 보안 정적 검사**: X-2(전체 저장소), X-6, X-7, PI1-16 을 main 에서 다시.
- **T-6 빌드**: 정식 키 시험 APK(2.0.1 T-5 와 같은 절차) → 권한 3개, versionCode 20002, `check_phone_native.ps1 -Apk` `PHONE_NATIVE_OK`, APK 안 `ai_secrets`·`FAKEKEY` 0(`Select-String` 로 zip 안 `.pck` 검사).
- **T-7 소유권**: 8파 시작 때 `only=PZ` 로 OK 기록.

### 6.3 공개 전 확인 (CLAUDE.md 체크리스트)
```powershell
git -C $R ls-files | Select-String -Pattern '(\.so|\.dll|\.bin|\.gguf|\.onnx|\.wav|\.mp3|\.ogg|\.m4a|\.apk|\.keystore|\.jks|release\.pass|secrets|auth\.json|\.gdextension|ai_secrets|ai_salt|hoehwa_keys)$'
git -C $R grep -I -l 'FAKEKEY_ZZ_' -- ':!godot/tests' ':!phone_src/tools/test_*'
```
- 기대: 첫 명령 `godot/tests/fixtures/song/tone_8s.mp3` 하나, 둘째 출력 없음(가짜 키 글자는 시험 파일 밖에 0).
- 릴리스 노트(오케스트레이터): "설정 > AI 연결에서 내 AI 키를 넣으면 PC 없이 대화·교정·피드백·일기 고치기", 업체별 요금·개인정보 한 줄씩, "모든 기록 지우기는 키를 지우지 않음", 쉬는 날, 속도 1.6. AI 검수·사람 검수 구분 기록.
- 공개 뒤: 링크 열기·SHA256SUMS·`releases/latest = v2.0.2`·APK 내려받기. 문제가 생기면 지우지 않고 2.0.3 으로.

---

## 7. 위험 요소와 대안, 일부러 틀린 입력

### 7.1 위험
| # | 위험 | 영향 | 대응·대안 |
|---|---|---|---|
| V1 | PI0 결과로 엔드포인트·모델 id·JSON 모드가 문서와 다름 | 폰 AI 실패 | 값은 `AiPresets` 한 곳 + `PI0_OVERRIDES`, 공개 게이트 `PI0_CONFIRMED`(T-0). 황금 일치는 덮어쓰기 끄고 유지 |
| V2 | 키 유출(로그·오류 본문·리다이렉트·화면·클립보드·동기화) | 금전·개인정보 | §2.0 비밀값 규칙, PI1-7·8·13·16, PI3-3·5, X-2·X-7, T-5, 실기 H8·H10 |
| V3 | **PC 전송 실패 → 폰 대체(S14)로 일기 원문이 폰 동의 없이 업체로** | 개인정보 | `LocalAi` 가용성 ⑤(일기 폰 동의·무료 학습 업체), PI2b-4 가 `Api` 대체 경로까지 시험, PWI-10 변이 |
| V4 | 서버 프롬프트가 바뀜(2.1.0 `/chat`) → 황금 드리프트 | 폰·PC 결과 차이 | T-2 `make_ai_golden.py --check`, 2.1.0 의 PI-L 에서 같이 갱신 |
| V5 | Godot `JSON.parse` 가 정수를 float 로 → 비교 오판 | 시험 거짓 실패·통과 | `canon()`(§2.2) 한 곳, PI1 이 도우미 자체 시험 |
| V6 | `max_redirects = 0` 의 3xx 처리 방식 불명(추측) | 리다이렉트 오판 | 두 결과 모양 모두 `ai_overload`, peer 서버 기록 0 을 직접 확인(PI1-7), 변이 8 로 FAIL 확인 |
| V7 | `OS.get_unique_id()` 가 바뀌어 복호화 실패 | 키를 다시 입력 | `.bad` 격리 후 "키 없음", 카드 문구, 크래시 0(PI1-3) |
| V8 | 요금 폭주(긴 대화·재시도) | 금전 | 자동 재시도는 서버 규칙(형식 오류 재요청)만, history 24개, "오늘 N번", 지출 한도 안내, 실기 H9 |
| V9 | 쉬는 날로 연속 기록·배지가 쉬워짐(달력 주 경계로 최대 4일 연속 쉼, 10일 빈 틈도 보호권 2개로 이어질 수 있음, RD-3 4번·주 경계) | 동기 부여 의미 약화 | 규칙 문구로 명확히, D-1(주 1일로 줄이기)·D-3(연속 쉬는 날 상한) 선택지 |
| V10 | 옛 앱으로 되돌리면 `rest` 목록 사라짐 | 표시만 "보호권" 으로 바뀜 | `frozen` 은 남아 연속 유지(설계상 허용) |
| V11 | 업데이터 고침은 2.0.2 를 받은 **뒤**부터 효과 | 지금 비안정 채널 사용자는 여전히 위험 | 지금 사용자는 안정 채널(기본), `models-1` 은 `--latest=false`(2.0.1 §6.3), 릴리스 노트 |
| V12 | `update.ps1` BOM 을 잃음 | 한국어 깨짐·업데이트 실패 | FXB-2 바이트 확인, `Mutate-Bom` |
| V13 | 기존 시험이 새 연속 규칙으로 깨짐 | 회귀 소음 | `rest_per_week_override = 0` 추가만 허용(RD-6 명령으로 판정) |
| V14 | PC 연결 + PC AI 없음 + 폰 키 → PC 로 가서 실패 | 사용자 혼란 | 홈 자리·README 에 "처리 위치 '이 폰에서만'", D-10 B(Route 변경)는 2.0.3 후보 |
| V15 | 속도 1.3 초과 시 PC 목소리는 1.3 | 기대와 다름 | `max_speed()` 로 클라이언트에서 같은 값으로 자르고 안내 한 줄(PSI-5) |
| V16 | 미션 `_llm_down` 폰 판정 변화로 기존 폰 모드 시험 기대가 달라짐 | 시험 실패 | 워커가 기준선에서 깨지는 단언을 찾으면 고치지 말고 오케스트레이터에게 보고(PWI-2 는 삭제 0) |
| V17 | 안드로이드 TLS 인증서·클립보드 동작 불명(추측) | 연결 실패·클립보드 안 비워짐 | `ai_tls` 문구, 실기 H7, 클립보드는 최선 노력 + 문구 |
| V18 | 2.0.1 이 아직 공개 전인데 v202 병합이 main 에 쌓임 | 2.0.1 핫픽스 어려움 | D-15: 2.0.1 은 지금 main 커밋으로 태그·공개하거나 `release/2.0.1` 가지를 먼저 만든다 |
| V19 | 실기 USB 없음 → logcat·내부 파일 확인 공백 | 보안 검증 일부 미검증 | 자동 시험 + `user_dir_internal`, 미검증을 문서에 정직하게(기획 결정 6) |

### 7.2 일부러 틀린 입력으로 확인할 실패 시나리오
| # | 입력 | 기대 | 담당 조건 |
|---|---|---|---|
| G1 | 키 형식 위반 14종 | `ai_key_format`, 저장 0 | PI1-4, PI3-4 |
| G2 | 키 파일 손상·기기 값 변경 | `.bad` 격리, "키 없음", 크래시 0 | PI1-3, PWI-8 |
| G3 | 302 → 다른 호스트 / `max_redirects` 8 로 변이 | peer 기록 0 / 시험 FAIL | PI1-7, PI1-15 |
| G4 | 오류 본문이 키를 되돌림 / 치환 끄기 변이 | 출력 0건 / FAIL | PI1-8, PI1-15 |
| G5 | `http://`·`file://`·사용자 정보 주소 | `ai_url`, 요청 0 | PI1-9 |
| G6 | 빈 본문·HTML·2 MB·`choices` 없음 | `bad_format`, 크래시 0 | PI1-14, PI1-6 |
| G7 | 황금 메시지 한 문장 변이 / JUDGE 상수 변이 | 일치 시험 FAIL | PI2b-6, PI2c-5 |
| G8 | 키 없음·동의 없음·일본어·PC 앱 | `no_ai`/`ja_ai_pc`/`not_on_phone`, 엔진 0 | PI2b-3 |
| G9 | 일기 폰 동의 없이 PC 전송 실패 대체 | 엔진 호출 0 | PI2b-4 |
| G10 | 일기 표식이 출력·파일·동기화에 섞임(양성 대조) | 검사기가 잡음 | PI2b-5, PWI-5 |
| G11 | 동의 시트 [취소]·[나중에] | 저장·요청 0 | PI3-4, PWI-3 |
| G12 | 키를 라벨에 넣은 가짜 화면 | `selfcheck FAIL-as-expected key_on_screen` | PI3-3 |
| G13 | `secret = false` 변이 / 폰 동의 pref 를 PC 것으로 변이 | 시험 FAIL | PI3-10, PWI-10 |
| G14 | `REST_PER_WEEK` 0 변이 / R=0 무작위 2,000 | FAIL / 옛 결과와 같음 | RD-9, RD-2 |
| G15 | `rest` 에 쓰레기 값·frozen 밖 날 | 정규화, 크래시 0 | RD-3 13번, RD-8 |
| G16 | 기존 시험 단언을 고친 diff | RD-6 명령이 줄을 출력 → X | RD-6 |
| G17 | 녹음 태그 `A1`·`../x` / 정규식 변이 | 종료 2 / FAIL | FXA-1, FXA-3, FXA-5 |
| G18 | 릴리스 목록 맨 앞이 `models-1` / 필터 변이 | v2.0.x 선택 / FAIL | FXB-1, FXB-4 |
| G19 | 로그 줄 600 ms 지연 / `_inflight` 0 변이 | 통과 + `late_line` 자기 점검 / FAIL | FXC-2, FXC-4 |
| G20 | `storage_dir` 줄 제거 변이 | FAIL | FXD-4 |
| G21 | 속도 pref `"x"`·2.0·0.3 / `SPEED_MAX_PHONE` 변이 | 기본·1.6·0.6 / FAIL | PSI-5, PSI-6 |
| G22 | 소유권: 겹침·기준 after 불일치·없는 mod·이미 있는 new | `FAIL` 줄, 종료 1 | X-9, §3.3 |

---

## 8. 오케스트레이터가 정할 것 (추천 포함)
| # | 항목 | 선택지 | 추천 |
|---|---|---|---|
| D-1 | 주당 쉬는 날 수 | A: 2일 / B: 1일 / C: 사용자 설정(0~2, 기기별 pref) | **A(2일)**. ROADMAP 문구 "주 1~2일" 의 너그러운 쪽, 18개월 매일 45분 목표에서 끊김이 동기 부여를 가장 크게 깎음. 바꾸려면 `REST_PER_WEEK` 한 줄 |
| D-2 | 소급 적용 | A: 없음(앞으로만) / B: 과거 끊김 재계산 | **A**. 저장 데이터·배지 갑작스런 변화 없음, 마이그레이션 없음 |
| D-3 | 주 경계를 넘는 연속 쉼(최대 4일) | A: 달력 주 규칙 그대로 / B: 연속 쉬는 날 상한 R 추가 | **A**(규칙이 단순하고 사용자 문구와 같음). B 는 2.1.x 에서 사용 데이터 보고 |
| D-4 | 네이티브 abort 기대 세대 인자(D-7(201)) 를 2.0.2 에 | A: 넣지 않음 / B: 넣음(`whisper_bridge` 재빌드 → `BUILD_INFO.json`·PA7 해시·`check_phone_native`·실기 H3 재측정, 새 `.so` 배포) | **A**. 현재 결과 폐기로 정확성은 지켜지고(알려진 한계는 계산 시간뿐), 2.0.1 실기 H3 전이라 영향 크기를 모름. H3 결과가 나쁘면 2.0.3 단독 작업 |
| D-5 | PI0 시점 | A: 키 파일이 생기는 대로(5파 중), 공개 전 필수 / B: 5파 시작 전 필수 | **A**. PI1 은 서버 복사값으로 진행·병합 가능, 공개 게이트(T-0)로 막음 |
| D-6 | JSON 황금 | A: PI2a 의 `extract_json.json`·`api_call.json` 사용(새 생성기 없음) / B: 기획대로 `make_ai_json_golden.py` 신설 | **A**. 같은 서버 함수를 이미 덮음. 기획 완료 기준 4 문구는 "`make_ai_golden.py --check` 종료 0 + 황금 전 사례 일치" 로 읽는다 |
| D-7 | 사용자 지정 base URL | A: 2.0.2 에서 없음 / B: 확인 문구와 함께 허용 | **A**(키가 엉뚱한 호스트로 갈 경로 차단). 필요하면 2.0.3 |
| D-8 | `max_tokens` | A: 보내지 않음(서버와 같음) / B: `num_predict` 를 상한으로 | **A**. 생각하는 모델에서 잘린 답(형식 오류)이 늘 위험(추측), 황금 일치 유지 |
| D-9 | 7파 PSI·PWI | A: 동시(파일 겹침 0) / B: 기획대로 PSI → PWI | **A**. 검토 부하가 걱정이면 B |
| D-10 | PC 연결 + PC AI 없음 + 폰 키 | A: 지금 Route 그대로(PC 우선, 안내) / B: Route 가 PC `llm_missing` 이면 폰(route.gd·route_test 변경) | **A**. B 는 2.0.3 후보 |
| D-11 | 폰 단독 + 키 없음일 때 홈 AI 자리 | A: 숨김 유지 / B: "AI 연결이 필요해요" 보임(하루 숨김 가능) | **A**(매일 뜨는 권유 없음, 진입은 메뉴·설정·오류 문구) |
| D-12 | 듣기 속도 | A: 폰 0.6~1.6, PC 0.6~1.3(서버 한계), 기본 1.0 / B: 기본값도 올림 | **A** |
| D-13 | 일기 음성 입력에 폰 음성 인식 허용 | A: 허용(녹음이 폰 밖으로 안 나감) / B: 지금처럼 PC 만 | **A** |
| D-14 | 정리 작업 묶기 | A: FXA·FXB·FXC·FXD 각각 워커 / B: FXC+FXD 한 워커(시험 격리), FXA·FXB 각각 | **B**(같은 영역·같은 검토자, 파일 겹침 0이라 소유권 그대로) |
| D-15 | 2.0.1 공개와 v202 병합 순서 | A: 2.0.1 을 v202 첫 병합 전 main 커밋에서 태그·공개 / B: `release/2.0.1` 가지를 먼저 만들고 v202 병합 진행 | **B**(실기 H2~H5 일정과 무관하게 5파 시작 가능, 2.0.1 핫픽스는 그 가지에서) |
| D-16 | versionCode | 20002 | 20002 |
| D-17 | K-스파이크(Keystore) | 하지 않음 | 하지 않음 |

---

## 9. 사용자에게 필요한 것
| 시점 | 무엇 | 시간 | 미루면 |
|---|---|---|---|
| 아무 때나(공개 전까지) | ★**AI 키 파일**(§4.1): 업체 1곳(추천 OpenCode Zen 유료, 무료로 하려면 Gemini) 키를 만들고 **지출 한도를 건 뒤** `C:\Users\rtyu6\hoehwa_keys\<업체>.txt` 에 키 한 줄 저장, 채팅에는 "만들었다" 만 | 5분 | PI0 미완 → 2.0.2 공개 보류(T-0) |
| §8 결정 직후 | D-1(쉬는 날 2일)·D-11(홈 자리) 처럼 사용자 체감이 큰 항목만 확인(오케스트레이터 판단) | 1분 | 추천안으로 진행 |
| 8파(T 통과 뒤) | ★**실기 H7~H10·H13**(§4.2): APK 덮어쓰기 → 키 넣기 → 대화·교정·피드백·미션·일기 각 1회 → 비행기 모드·틀린 키 → 진단 복사 → 속도·쉬는 날 확인 | 20~25분 | 2.0.2 공개 보류 |
| 선택 | USB 디버깅 1회(H8 의 logcat·내부 파일 확인) | 10분 | 그 항목 "미검증" 으로 공개 |

---

## 10. 확인한 것 / 추측

### 10.1 확인한 것(코드 읽기·직접 실행)
- 쉬는 날 설계의 근거: `StreakCalc`·`StudyLog` 의 보호권 구조, `_norm_freeze` 가 모르는 키를 버림, `freeze` 비동기화, `longest_streak`·배지 연결, 돌 7개·목표 카드 문구와 그것을 단언하는 시험 줄(S1~S6). R=0 일 때 새 식이 기존 식과 같다는 것은 식 대입으로 확인(§2.8 괄호), RD-3 표 13행은 손으로 계산(시험이 다시 확인).
- 속도: 클라이언트·설정·서버 세 곳의 1.3 상한과 동기화 허용 범위(S7).
- 업데이터: 비안정 채널이 태그 모양을 안 봄, `Parse-Ver` 동작, BOM 복사(S8).
- 모델 시험 부재 단언 5곳의 줄 번호가 지금 main 에서도 그대로이고(FLAKY 병합 뒤 확인), 카드 시험에 정착 대기 도우미가 있음(S9).
- `lifecycle_test` 가 `user://reading` 을 만드는 경로와 `course_today_test` 의 반대 단언(S10).
- 녹음 도구 id 형식과 뒤 도구가 id 를 자유 문자열로 씀(S11).
- 폰 AI: Route 오류 코드·정책, LocalApi 핸들러 자리, **Api 의 PC 전송 실패 대체가 AI 경로에도 적용됨**(S12~S14), PI2a 황금 462사례와 오류 결과 집계, api 대본 위치(S15), 서버 API 엔진의 본문·분류·재시도·타임아웃(S16), 미션·커리큘럼 데이터 동일(S17), 일기·미션·홈·메인·설정·기능 현황의 현재 코드와 그것을 단언하는 시험(S18~S22).
- OWN 블록 소유권 검사(§3.3): 정상 1회 + 틀린 복사본 4종 FAIL.

### 10.2 추측(실행·실측으로 확인하지 못함)
- PI0 의 모든 값(엔드포인트·JSON 모드·system 위치·모델 id·free tier 문구 모양), 업체 요금·데이터 정책의 최신 내용.
- Godot 4.6.3 `HTTPRequest` 의 `max_redirects = 0` 일 때 3xx 결과 모양, 리다이렉트 때 사용자 헤더를 따라 보내는지.
- 안드로이드에서 `OS.get_unique_id()` 의 안정성, `DisplayServer.clipboard_get/set`, TLS 인증서 검증 방식, 폰 시스템 음성이 rate 1.6 을 그대로 내는지.
- 무작위 2,000사례 동등 시험이 옛 알고리즘의 모든 분기를 덮는다는 것(시험 설계로 확인 예정).
- `mission_test` 의 폰 모드 단언이 `_llm_down` 변경에 영향받지 않는다는 것(V16, 워커가 기준선으로 확인).
- 2.0.2 일정: 5~8파가 2026-12 말 안에 끝난다는 것(기획 §5.1 기준선, 2.0.1 실기·공개 시점에 달림).

## 9. 오케스트레이터 확정 (2026-11-27)
- §8 의 D-1~D-17 은 모두 **추천안대로 확정**: D-1 주당 쉬는 날 2, D-2 과거 연속에 소급 없음, D-3 달력 주 규칙 그대로(경계에서 최대 4일 연속 가능), D-4 네이티브 abort 수정은 2.0.2 에 넣지 않음(H3 뒤 재검토), D-5 PI0 는 키 파일이 생기면 바로·공개 전 필수, D-6 기존 황금 재사용, D-7 사용자 지정 주소 없음, D-8 `max_tokens` 안 보냄, D-9 PSI·PWI 동시, D-10 현재 Route 유지, D-11 키·PC 없으면 홈 칸 숨김, D-12 속도 폰 1.6·PC 1.3, D-13 일기 음성 입력 허용, D-14 FXC+FXD 한 작업자, D-15 2.0.2 코드를 합치기 전에 `release/2.0.1` 브랜치를 만든다, D-16 versionCode 20002, D-17 Keystore 스파이크 없음.
- 2.1.0 기획(`docs/v210_plan.md`)의 D6(PI-L 을 2.1.0 에 포함)에 따라 2.0.2 의 PI1·PI2b 공개 API 는 2.1.0 이 확장할 수 있게 둔다(이름·인자를 2.0.2 안에서 바꾸지 않음).