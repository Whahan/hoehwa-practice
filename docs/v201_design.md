# v2.0.1 상세 설계: 폰 발음 채점(P-ASR) 마무리와 2.0.0 후속 패치

- 작성: designer(Opus 5.5, 설계만. 코드·설정 수정 없음) / 기준 커밋: `40df5df`(main, 2026-11-19)
- 상위 문서: `docs/v201_plan.md`(최상단 기획, §6 결정 9건 모두 추천안 A로 확정), `docs/v200_phone_design.md`(폰 설계. 이 문서는 그 문서를 바꾸지 않고, **바뀐 점과 확정값만** 적는다).
- 표기: **(추측)** = 코드·실행으로 확인하지 못한 가정. **(새)** = 이번에 새로 만드는 파일·함수·필드. **★** = 사용자 확인·행동이 필요한 항목. 경로는 저장소 루트 `D:\Ai\언어\app` 기준. "§1.5(폰)"은 `docs/v200_phone_design.md` 의 절을 뜻한다.
- 검토자: Sol 6.2(Codex). 검토자는 `REVIEW.md` 를 먼저 읽고, §5의 PowerShell 명령을 그대로 따라 실행한다.

## 0. 근거·목표·범위

### 0.1 읽은 것 / 실행한 것 / 확인하지 못한 것
- **읽은 것**: `docs/v201_plan.md` 전체, `docs/v200_phone_design.md` 전체, `docs/v200_design.md` §13.5·§14.1·§14.3, `REVIEW.md`, `WORKLOG.md` 뒷부분, `native/whisper_bridge/src/whisper_bridge.h`·`whisper_bridge.cpp`(바인딩·`load_model`·`unload`·`transcribe`)·`README.txt`·`BUILD_INFO.json`·`build.ps1`·`whisper_bridge.gdextension.in`, `godot/scripts/autoload/route.gd`·`api.gd`·`local_api.gd`·`tts.gd`(일부), `godot/scripts/ui/self_rate_panel.gd`·`capability_panel.gd`, `godot/scripts/views/settings_view.gd`(일부)·`course_home.gd`(주 상세 시트), `godot/scripts/practice/course_player.gd`(`_show_error`·`_finish_unit`)·`shadow_screen.gd`(일부)·`speak_drill.gd`(일부), `godot/scripts/song/song_sing_tab.gd`(일부), `godot/scripts/core/course_feed.gd`·`home_model.gd`(일부), `course_src/tools/README.txt`·`check_course.py`(키 목록)·`build_course.py`(노트 출력), `course_src/en/weeks/w001.json`·`w005.json`·`w006.json`·`w011.json`(해당 항목), `godot/data/course/course_manifest.json`·`en_weeks.json`(노트), `packaging/build_android.ps1`(머리)·`publish_release.ps1`(APK 부분)·`packaging/installer/update.ps1`(릴리스 선택), `packaging/release.json`, `godot/export_presets.cfg`(해당 줄), `.gitignore`, scratchpad 의 `w_v200pa1\G1_steps.txt`·`폰_시험_안내.txt`·`probe_src\probe_logic.gd`(URL), `w_t9\run_godot.ps1`, 바탕화면 `발음샘플\목록.txt`.
- **실행한 것(읽기 전용)**: `git status`·`git log`·`git ls-files`, 위 파일 검색, w001 노트에서 [듣기] 대상 추출 규칙 시험(정확히 31개, 전부 1주), scratchpad 의 PA1 산출물·모델 sha256 계산(아래 0.3), Godot 4.6.3 에 API 존재 여부 질의(`OS.get_power_*` 없음, `OS.get_memory_info`·`DisplayServer.clipboard_set`·`JavaClassWrapper`·`WorkerThreadPool` 있음), 소유권 검사 스크립트(§3.3), 코스 린터(`CHECK_OK …`)와 scratch 로의 재빌드(7개 파일 해시가 커밋된 데이터와 같음), F2-3 항목 비교 스크립트(정상·변형 두 경우), 이 문서의 백틱 경로·`클래스.멤버` 이름 전수 검사(`<scratch>\w_v201design\check_paths.py`·`<scratch>\w_v201design\check_symbols.py`: 없는 기존 경로·이름 0, 일부러 넣은 가짜 경로·이름은 FAIL). 내려받기·설치·네트워크 접근은 하지 않았다.
- **확인하지 못한 것**: Gemini 표본2 의 M3 3건 원문 지적(저장소·scratchpad 에서 찾지 못함 → F2 는 오케스트레이터가 원문을 넘긴다), GitHub·Hugging Face 리다이렉트 호스트의 현재 이름(추측: `release-assets.githubusercontent.com`, `cas-bridge.xethub.hf.co`), 폰 시스템 TTS 가 글자 이름(`ay`, `ess` 등)을 읽는 품질, Godot 가 Windows 내보내기에서 `.godot/extension_list.cfg` 를 걸러내는지(PA7-5 가 확인), 같은 versionCode 로 덮어쓰기 설치가 되는지(추측: 된다).

### 0.2 목표와 범위
- **목표**: `docs/v201_plan.md` §1.1 의 완료 기준 1~5 를 만족하는 2.0.1 을 공개한다. 폰만으로 오프라인 영어 발음 채점, 1주차 알파벳 소리 듣기, 원고 M3 3건 손질, 코스 플레이어 저장 실패 제목 수정.
- **하지 않을 것**
  - 2.0.2 범위 전부(폰 AI 직접 연결, PI0~PI3, PSI, PWI). `Route.ERR_TEXT["no_ai"]` 문구와 `CapabilityPanel.REASONS["no_ai"]` 는 그대로 둔다(결정 1).
  - `godot/scripts/autoload/route.gd`·`api.gd`·`local_api.gd`·`godot/project.godot`·`backend/` 수정. 새 autoload, 새 권한.
  - 2주차 이후의 소리 노트 [듣기](2~4주 36건, 13~16주 4건), 노트 전체를 보여 주는 새 화면(1주차 소리 노트 시트 하나만 만든다).
  - E5 머리글 줄바꿈, E7 시험 `font`/`dark` 옵션, `q8_0`/`f16` 실물 검증(PA5 미달 시에만, 결정 7).
  - "이 폰에서는 채점이 느려요" RTF 안내 팝업(§1.7④(폰)의 ③). S24 실측 1.9초라 2.0.1 에서는 빼고, 2회 연속 시간 초과 자동 끔(④)만 넣는다.
  - `ApiCall.cancel()` 이 폰 엔진을 중단시키는 연결(`api.gd` 변경이 필요해서 뺀다. 취소는 결과 폐기만, §2.3).
  - 버전 올리기·릴리스·`models-1` 업로드(오케스트레이터 몫, §6).

### 0.3 지금 main 에서 확인한 사실(설계 근거)
| # | 사실 | 위치 |
|---|---|---|
| S1 | P0 병합됨: `Route.POLICY` 의 `POST /stt`·`/score`(prefer phone, `score_where`), `POST /score#ph`, 오류 코드 `engine_error`·`stt_timeout`·`no_space` 등, `Route.DEGRADED` 의 `score_uncalibrated`·`stt_tiny_model`, `Api._phone_retry_wanted`(`engine_error`·`stt_timeout` 이면 PC 1회 재시도). `engine_error`·`stt_timeout` 문구는 "설정 > 음성 인식에서 'PC에서 채점'", `model_missing` 은 "설정 > 음성 인식에서 내려받으면(약 60 MB)" 을 가리킨다 | `godot/scripts/autoload/route.gd`, `godot/scripts/autoload/api.gd` |
| S2 | PA1 병합됨. `WhisperBridge` 공개 함수: `version()`(정적, 패치 빌드면 `+abort-sched`), `check_model(path)`·`cpu_features()`·`memory_info()`(정적, `{peak_kb, rss_kb}`), `load_model(path, threads=0)`, `is_loaded()`, `model_file()`, `unload()`, `transcribe(wav, lang, options={})`, `abort()`. `load_model`·`unload`·`transcribe` 는 같은 뮤텍스를 잡는다: **전사 중이면 `load_model`·`unload` 가 전사가 끝날 때까지 막힌다**(`unload` 는 abort 표시를 먼저 올리지만 잠금은 기다린다). `transcribe` 옵션: `beam`(1..5), `max_seconds`, `trim`, `token_timestamps` | `native/whisper_bridge/src/whisper_bridge.h`, `whisper_bridge.cpp` 316~520행 |
| S3 | `.so`·`.dll`·`godot/whisper_bridge.gdextension` 은 추적하지 않는다(`.gitignore`). PA1 빌드 산출물은 scratchpad `w_v200pa1\copy_tree\godot\bin\` 에 있고 sha256 이 `BUILD_INFO.json` 과 같다(`ac22dc63…`(so 1,916,928 B), `53c17b96…`(dll 2,355,712 B)). 소스 `native\_deps` 는 main 체크아웃에 없고 `w_v200pa1\copy_tree\native\_deps\` 에 있다. `build.ps1` 은 실행하면 추적 파일 `BUILD_INFO.json` 을 다시 쓴다 | `.gitignore`, `native/whisper_bridge/build.ps1` 180행 |
| S4 | 시험 모델: `w_v200pa1\models\ggml-base.en-q5_1.bin`(59,721,011 B, sha256 `4baf70dd0d7c4247ba2b81fafd9c01005ac77c2f9ef064e00dcf195d0e2fdd2f`), `ggml-tiny.en-q5_1.bin`(32,166,155 B, `c77c5766f1cef09b6b7d47f21b546cbddd4157886b3b5d6d4f709e91e66c7c2b`). 직접 계산해 지시값과 같음을 확인 | scratchpad |
| S5 | **주(week) 노트는 지금 앱 어디에도 보이지 않는다.** `en_weeks.json` 의 `notes`(1주: sound 32, culture 1)를 읽는 GDScript 가 없다(`HomeModel.course_notes` 는 다른 기능). 1주 소리 노트는 `en` 이 `"A (ay)"`, 짧은 모음은 `en` 이 `"a"` 이고 예시 낱말이 `text_ko` 끝 괄호 `(cat, bag, hat)` 에 있다. 빌드는 `_` 로 시작하는 키(`_sound`)를 지운다 | `godot/data/course/en_weeks.json`, `course_src/tools/build_course.py` 77행 |
| S6 | 노트에 `say` 키를 넣으면 린터가 막는다(`NOTE_KEYS` 에 `say` 없음) | `course_src/tools/check_course.py` 53행 |
| S7 | 코스 플레이어의 저장 실패(`TEXT_SAVE`)도 `_show_error()` 를 거쳐 제목이 "문제를 열 수 없어요" 로 나온다(E4b 사소) | `godot/scripts/practice/course_player.gd` 56·673·916~930행 |
| S8 | 11주 `p_price_say` 의 `grammar_ko` 2번째 줄이 이미 "5달러 99센트는 It's five ninety-nine. 처럼 dollars 를 빼고 숫자를 두 번에 나눠 읽기도 해요." 이다(3줄) | `course_src/en/weeks/w011.json` |
| S9 | Godot 4.6.3 에 배터리·온도 API 가 없다(`OS.get_power_percent_left` 등 false). `OS.get_memory_info()`·`DisplayServer.clipboard_set` 은 있다 | 직접 질의 |
| S10 | `publish_release.ps1 -WithApk` 는 `build_android.ps1 -Version <v> -OutDir …` 를 **`-Debug` 없이** 부른다. 그래서 "릴리스 빌드에서는 네이티브 필수"를 `build_android.ps1` 안에서 정하면 공개 스크립트를 고치지 않아도 된다 | `packaging/publish_release.ps1` 161~180행 |
| S11 | 업데이터는 `channel:"stable"` 이면 `releases/latest`, 아니면 최신 생성 릴리스 하나를 고른다. `models-1` 이 "latest" 가 되면 PC 업데이터가 깨진다 | `packaging/installer/update.ps1` 150·174행, `packaging/release.json` |
| S12 | 주 상세 시트는 `scene.canada` 의 id(`cn_app_voice`, `cn_zed`)를 그대로 줄로 보인다(**기존 문제**, 코드 읽기로 확인, 화면 실행은 안 함) | `godot/scripts/views/course_home.gd` 368~375행 |
| S13 | 2.0.0 공개 APK 기준선: `packaging\out\release_2.0.0\hoehwa-practice-android-2.0.0.apk`(31,695,862 B) | 파일 |

### 0.4 v200_phone_design 대비 바뀐 점(요약)
| 항목 | v200 폰 설계 | 2.0.1 확정 |
|---|---|---|
| 담당 | PSA·PWA·PZ 는 `worker` | 전부 `worker-hard`(사용자 CLAUDE.md 표: 구현은 worker-hard 만) |
| 모델 매니페스트 | `bytes`·`sha256` 미정, 리다이렉트 최대 3, 정확한 호스트 목록 | 값 확정(§2.2), 리다이렉트 최대 5·상대 `Location` 허용, 호스트는 **접미사** 목록 |
| `LocalStt` 스레드 | 전사만 스레드 | **엔진 스레드 1개(`SttEngine`, 새)가 `load_model`·`unload`·`transcribe` 를 모두 맡는다.** 메인은 `abort()` 만 직접 부르고 기다리지 않는다(결정 5) |
| 취소 | `ApiCall.cancel()` → `abort()` | 결과 폐기만(`api.gd` 무변경) |
| `score_params.json` | `ok_prob`·`p_map` | + `beam`(1..3), `final_map`(폰 최종 점수 단조 매핑). 결정 7 의 폴백을 데이터로 표현 |
| `ScoreCore.score_en` | 3인자 | `ok_prob` 4번째 인자(기본 0.45) + `map_p`·`valid_p_map`·`map_final` |
| PA5 | 한 작업 | **PA5a**(도구, 2파) / **PA5b**(보정 실행·`score_params.json`, 3파). 사용자 녹음을 2파에 받기 위해 |
| 녹음 도구 | 미정 | `calib_record.py` 가 `backend\.venv` 의 `sounddevice`(이미 설치됨)를 쓴다. 새 설치 없음 |
| 실기 측정 | adb | 앱 안 **진단 시트**(`SttDiagSheet`, 새) + [결과 복사]. 배터리 %는 사용자가 시트에 입력, 온도는 미측정(S9) |
| `build_android.ps1` | `-RequireNative` 일 때만 필수 | **릴리스(비 `-Debug`) 빌드는 네이티브 필수**, `-Debug` 는 경고만(S10) |
| 소유권 검사 | 폰 문서 OWN | 이 문서 OWN + `docs/v200_design.md` OWN(§3.3), 같은 규칙 |

---

## 1. 범위 확정표

| id | 내용 | 2.0.1 | 담당 | 파 | 비고 |
|---|---|---|---|---|---|
| P0 | Route 폰 우선·오류 코드·PC 1회 재시도 | 완료(병합 `fba1b62`) | - | 0 | 수정 없음 |
| PA1 | WhisperBridge GDExtension | 완료(병합 `40df5df`) | - | 0 | 수정 없음. 산출물은 N0 로 복사 |
| N0 | 네이티브 준비(산출물 복사·`.gdextension` 생성) | 넣음 | 오케스트레이터 | 매 worktree | 코드 아님, §2.0 |
| PA2 | `ScoreCore` + 파이썬 황금 | 넣음 | worker-hard | 1 | §2.1 |
| PA3 | `ModelStore` + `models.json` + 모델 카드 | 넣음 | worker-hard | 1 | §2.2 |
| PA7 | 빌드 통합·16KB·`allowBackup`·PC 제외 | 넣음 | worker-hard | 1 | §2.7 |
| F1 | 1주 알파벳·짧은 모음 소리 노트 [듣기] | 넣음 | worker-hard | 1 | §2.9 |
| F2 | 원고 M3 3건 + 11주 가격 설명 1줄 + 재빌드 | 넣음 | worker-hard | 1 | §2.10. 11주 설명은 재빌드 파일이 겹치므로 F3 이 아니라 F2 가 한다 |
| F3 | 코스 플레이어 저장 실패 오류 제목 | 넣음 | worker-hard | 1 | §2.11 |
| PA4 | `LocalStt` + `SttEngine`(비동기 로드·언로드) | 넣음 | worker-hard | 2 | §2.3 |
| PSA | 설정 "음성 인식" 카드·`score_where` 라디오·`CapabilityPanel`·진단 시트 | 넣음 | worker-hard | 2 | §2.5 |
| PA5a | 보정 도구(파이썬 5개 + Godot 1개) + README | 넣음 | worker-hard | 2 | §2.4 |
| PA5b | 보정 실행·`score_params.json`·폴백 | 넣음 | worker-hard | 3 | §2.4, ★사용자 녹음 뒤 |
| PWA | 말하기 화면 연결(자가 평가 [모델 받기], "폰 간이 채점", `need_ph`, 쉐도잉·노래 문구) | 넣음 | worker-hard | 3 | §2.6 |
| PZ | README·ROADMAP·INSTALL 의 2.0.1 절 | 넣음 | worker-hard | 4 | §2.8 |
| PA6 | (v200 폰 설계에도 없음) | - | - | - | 번호 비어 있음 |
| PI0~PI3, PSI, PWI | 폰 AI | **뺌**(2.0.2) | - | - | PI0 키 시험은 오케스트레이터가 따로 |
| E5 줄바꿈, E7 시험 옵션, q8/f16 | 사소 | **뺌** | - | - | 결정 4 |
| 2~4주 소리 노트 [듣기] | - | **뺌** | - | - | 규칙만 넓히면 되므로 2.0.2 후보(§8 O-5) |

---

## 2. 작업별 상세 (바뀐 점과 확정값만)

### 2.0 공통: N0 네이티브 준비, worktree, 임시 폴더
- worktree `D:\Ai\언어\app_wt\v201_<작업 소문자>`, 브랜치 `v201/<작업 소문자>`(예: `v201/pa4`). 이 문서는 분기 전에 main 에 커밋된다(오케스트레이터).
- 임시 파일: 작성자 `<scratch>\w_v201_<작업>\`, 검토자 `<scratch>\w_rev_v201_<작업>\`. 다른 워커와 이름을 공유하지 않는다. `<scratch>` = `C:\Users\rtyu6\AppData\Local\Temp\claude\D--Ai----app\c5535f7a-0e1a-4bb6-bdc3-5597b7f84c22\scratchpad`.
- **N0(네이티브가 필요한 작업만: PA4 실물 확인, PA5a·PA5b, PA7, T)**: 빌드하지 않고 PA1 산출물을 복사한다(`BUILD_INFO.json` 을 바꾸지 않기 위해, S3). 명령은 §5.0 의 `Prep-Native`. 새 `class_name` 이 생기거나 `.gdextension` 을 처음 둔 뒤에는 `--import` 를 **두 번** 돌린다(첫 번째는 Godot 4.6.3 알려진 접근 위반으로 끝날 수 있음, `native/whisper_bridge/README.txt`).
- **`native_bridge_test` 는 빌드 산출물(DLL)·모델·WAV 가 있어야만 통과한다.** main 이나 N0 를 안 한 worktree 에서 돌리면 실패하는 것이 정상이다. 이 시험이 필요한 판정(T-3)은 N0 뒤에만 한다.
- `build.ps1` 은 PA7 의 일부 확인(§5.7 PA7-9)에서만, 그리고 끝에 `git checkout -- native/whisper_bridge/BUILD_INFO.json` 으로 되돌린다.

### 2.1 PA2 — `ScoreCore` (1파)
- 하는 일·합격선은 §6.4(폰)와 같다. 바뀐 점: `ok_prob` 인자와 매핑 함수 3개를 더하고, 빈 타깃은 예외 대신 빈 사전.
- 파일: §3 OWN 의 PA2 줄.
- 공개 계약(새, `godot/scripts/core/score_core.gd`, `class_name ScoreCore extends RefCounted`, 전부 정적):
```
const OK_PROB := 0.45
const TARGET_EMPTY_TEXT := "연습할 문장이 비어 있어요."
static func score_en(target: String, words: Array, text: String, ok_prob: float = OK_PROB) -> Dictionary
    # 서버 score_en 과 같은 결과 사전(키: transcript, score, accuracy, clarity, fluency, units[{t,ok,conf,heard}], tips_ko).
    # en_words(target) 가 비면 {} 를 돌려준다(호출자가 TARGET_EMPTY_TEXT 로 400 을 만든다).
static func en_words(text: String) -> Array          # 서버 en_words
static func align_seq(target: Array, heard: Array) -> Dictionary   # {"pairs": [[j 또는 null, exact:bool], ...], "inserts": [...]}
static func word_sim(a: String, b: String) -> float
static func fluency_score(n_units: int, words: Array) -> int
static func map_p(p: float, p_map: Array) -> float   # 구간 선형, p 는 [0,1] 로 자르고 NaN 은 0
static func valid_p_map(p_map: Variant) -> bool       # 2~32점, [x,y] 쌍, x 엄격 증가·y 비감소, x 0 과 1 포함, y ∈ [0,1]
static func map_final(score: int, final_map: Array) -> int   # 같은 규칙, 축은 0..100, 결과 반올림·clamp
static func valid_final_map(m: Variant) -> bool       # x 0 과 100 포함, y ∈ [0,100], 비감소
```
- 황금 파일 `godot/tests/fixtures/score_golden_en.json`(새): `{"v":1,"ok_prob":0.45,"cases":[{"id","target","words":[{w,p,start,end}],"text","ok_prob"(선택),"expect":{…}}],"align":[{"a":[…],"b":[…],"pairs":…,"inserts":…,"sim":[…]}],"en_words":[{"in","out"}],"known_gaps":[{"in","why"}]}`. `ok_prob` 가 0.45 가 아닌 사례 ≥ 10(생성기가 `server.OK_PROB` 를 그 값으로 잠시 바꿔 계산).
- 시험 인자: `score_parity_test -- --golden=<경로>`(기본 `res://tests/fixtures/score_golden_en.json`). 일부러 틀린 황금으로 FAIL 을 보이는 데 쓴다.
- 다른 작업과의 계약: PA4 는 `score_en`·`map_p`·`map_final`·`valid_*` 만 부른다. PA5a/b 는 파이썬 쪽에서 서버 `score_en` 을 직접 쓰고(황금으로 같음이 보장됨) `map_p` 와 같은 규칙을 파이썬으로 구현한다(PA5a 시험이 같은 사례로 GDScript 결과와 대조하지 않아도 되게 **규칙 문장**을 이 절에 고정: 구간 선형, 양 끝 밖은 끝 값, 같은 x 없음).

### 2.2 PA3 — `ModelStore`·`models.json`·모델 카드 (1파)
- 하는 일은 §1.3(폰). 바뀐 점과 확정값만 적는다.
- **`godot/data/models.json`(새) 확정 내용**:
```json
{"v":1,
 "hosts":["github.com","githubusercontent.com","huggingface.co","hf.co"],
 "models":[
  {"id":"whisper-base.en-q5_1","kind":"stt","langs":["en"],"file":"ggml-base.en-q5_1.bin",
   "bytes":59721011,"sha256":"4baf70dd0d7c4247ba2b81fafd9c01005ac77c2f9ef064e00dcf195d0e2fdd2f",
   "min_free_mb":250,"default":true,"ram_hint_mb":400,"label_ko":"기본 모델",
   "urls":["https://github.com/Whahan/hoehwa-practice/releases/download/models-1/ggml-base.en-q5_1.bin",
           "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en-q5_1.bin"],
   "license":"MIT (OpenAI Whisper weights, ggml conversion by whisper.cpp)"},
  {"id":"whisper-tiny.en-q5_1","kind":"stt","langs":["en"],"file":"ggml-tiny.en-q5_1.bin",
   "bytes":32166155,"sha256":"c77c5766f1cef09b6b7d47f21b546cbddd4157886b3b5d6d4f709e91e66c7c2b",
   "min_free_mb":150,"default":false,"ram_hint_mb":250,"label_ko":"작은 모델(느린 폰용)",
   "urls":["https://github.com/Whahan/hoehwa-practice/releases/download/models-1/ggml-tiny.en-q5_1.bin",
           "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-tiny.en-q5_1.bin"],
   "license":"MIT (OpenAI Whisper weights, ggml conversion by whisper.cpp)"}]}
```
  `hosts` 는 **접미사** 규칙이다: 호스트 `h` 가 허용되려면 `h == s` 이거나 `h` 가 `"." + s` 로 끝나야 한다(`release-assets.githubusercontent.com` 허용, `evilgithub.com` 거절). 시험 때만 `ModelStore.allow_http_loopback = true` 로 `http://127.0.0.1:<port>` 허용.
- **저장 파일**(앱 비공개 `user://models/`): `<file>`, `<file>.part`, `<file>.part.json`(`{"v":1,"id","bytes_done","url_index"}` — 서명된 리다이렉트 URL·쿼리는 저장하지 않는다), `<file>.ok`(`{"v":1,"sha256","bytes"}`).
- **리다이렉트**: `301/302/303/307/308` 을 최대 `MAX_REDIRECTS = 5` 번 따라간다. `Location` 이 상대 경로면 현재 URL 기준으로 푼다(추측: HF 가 상대 경로를 쓸 수 있음). 매 단계 https·허용 호스트 검사. 이어받기는 항상 `urls[url_index]` 원래 주소부터.
- **공개 계약**(새, `godot/scripts/local/model_store.gd`, `class_name ModelStore extends RefCounted`, 정적 + 안쪽 실행 노드):
```
const SPACE_MARGIN_MB := 100
const MAX_REDIRECTS := 5
const MB := 1000000                       # 화면 MB 는 10^6 바이트, 반올림 정수
const ERR_TEXT := {"dl_net": "...", "dl_http": "...", "dl_redirect": "...", "dl_host": "...", "no_space": "...", "model_corrupt": "...", "io": "...", "bad_manifest": "..."}   # 한국어, 카드 전용
static var manifest_path := "res://data/models.json"
static var base_dir := "user://models/"            # 시험: "user://test_models_<이름>/"
static var free_space_hook: Callable                # () -> int 바이트, -1 = 알 수 없음. 기본 DirAccess.get_space_left()(0 이면 -1 로 본다)
static var allow_http_loopback := false
static func manifest() -> Dictionary               # {ok:bool, models:Array, hosts:Array, err:String}
static func model(id: String) -> Dictionary         # {} = 없음
static func default_id() -> String
static func active_id() -> String                  # pref stt_model 이 목록에 있으면 그것, 아니면 default_id()
static func set_active(id: String) -> bool          # pref stt_model 저장
static func state(id: String) -> String            # missing | partial | downloading | verifying | ready | corrupt
static func path_of(id: String) -> String          # base_dir + file
static func info(id: String) -> Dictionary         # {id, file, bytes, state, part_bytes, label_ko}
static func start(id: String, space_confirmed: bool = false) -> Dictionary   # {ok, err_code: ""|"no_space"|"space_unknown"|"busy"|"bad_manifest"}
static func cancel(id: String) -> void             # .part 유지
static func remove(id: String) -> bool             # 모델·.part·.part.json·.ok 삭제
static func mark_corrupt(id: String) -> void        # LocalStt 가 load 실패 때 부른다
static func progress_label(done: int, total: int) -> String   # "35 / 60 MB" (진행 글은 이 한 함수)
static func mb_label(bytes: int) -> String          # "약 60 MB"
static func events() -> Node                        # 신호: progress(id, done, total), state_changed(id, state), finished(id, ok, err_code)
static func stats() -> Dictionary                   # {requests, resumed, resume_bytes, last_host, last_err} — 진단용, 숫자·호스트 이름·코드만
```
- **모델 카드**(새, `godot/scripts/ui/stt_model_card.gd`, `class_name SttModelCard`): `static func build(host: Node) -> Control`(설정에 붙는 카드, 노드 이름 `SttModelCard`), `static func open_sheet(host: Node) -> Node`(같은 내용을 시트로 연다 — PWA 가 자가 평가 위젯에서 부른다). 버튼 노드 이름: `ModelGetBtn`·`ModelResumeBtn`·`ModelCancelBtn`·`ModelDeleteBtn`·`ModelPick_<id>`. 와이파이 확인 시트 문구: "음성 인식 모델(약 60 MB)을 받아요. 와이파이에 연결돼 있나요?" [받기]·[나중에]. RAM 이 3 GB 미만이면(`OS.get_memory_info()["physical"]`, 0 이면 판단 안 함) "이 폰은 메모리가 적어서 작은 모델을 추천해요" 한 줄.
- 다른 작업과의 계약: PA4 는 `active_id`·`state`·`path_of`·`model`·`mark_corrupt`·`stats` 만, PSA 는 `SttModelCard.build`·`ModelStore.stats`, PWA 는 `SttModelCard.open_sheet` 만 부른다. 새 prefs `stt_model` 은 `SyncDoc.SHARED_PREFS` 에 넣지 않는다.

### 2.3 PA4 — `LocalStt` + `SttEngine` (2파)
- 하는 일은 §1.5(폰). 바뀐 점: 엔진 스레드 구조(결정 5), 취소, 자동 끔, 진단·벤치 함수, `score_params` 새 필드.
- **구조**:
```
LocalApi.dispatch → LocalStt.handle (정적, 메인)
   1) 입력 검사·base64→WAV(메인)   2) engine := SttEngine.get_or_create()
   3) 필요하면 engine.request_load(ModelStore.path_of(active)) — 비동기
   4) res := await engine.transcribe(wav, {"beam": params.beam, "max_seconds": 30.0})  — 메인은 프레임마다 돈다
   5) 12초 넘으면 engine.abort() 후 fail("stt_timeout") (늦게 온 결과는 버림)
   6) words' = map_p 적용·시각 정리 → /stt 또는 ScoreCore.score_en(…, ok_prob) → map_final
SttEngine (Node, 루트 아래 "SttEngine" 하나, 새 파일)
   Thread 1개 + Mutex + Semaphore + 작업 큐(FIFO): load | unload | transcribe | quit
   bridge 의 load_model / unload / transcribe 는 이 스레드에서만 부른다. 메인은 bridge.abort() 만 직접 부른다.
   결과는 call_deferred 로 메인에 돌려준다.
```
- **결정 5 반영(비동기 로드·언로드, abort 를 기다리지 않음)**:
  - `request_unload()`: `bridge.abort()` 를 바로 부르고(원자 변수만 바꿈) 큐에 unload 를 넣고 **곧바로 돌아온다**. 엔진 스레드는 진행 중 전사가 `aborted` 로 끝난 뒤 unload 한다. 메인은 기다리지 않는다.
  - `request_load(path)`: 큐에 넣고 돌아온다. 이미 같은 파일이 올라가 있으면 아무것도 안 한다.
  - `NOTIFICATION_APPLICATION_PAUSED`: `abort()` + `request_unload()`. 그 전사를 기다리던 요청은 `fail("engine_error", TEXT_PAUSED)`(TEXT_PAUSED = "앱이 잠시 멈춰서 채점을 끝내지 못했어요. 다시 말해 보세요."). `RESUMED` 는 아무것도 안 한다(다음 요청이나 `warm()` 때 로드).
  - 마지막 사용 90초(`IDLE_UNLOAD_SEC`) 뒤 `request_unload()`.
  - 종료(`NOTIFICATION_PREDELETE`/`tree_exiting`)에서만 `abort()` → quit 작업 → `wait_to_finish()`. abort 패치(`+abort-sched`) 덕분에 전사 중이어도 수 ms 안에 끝난다(PA1 측정). 패치 표식이 없는 브리지면 진단에 `abort_patch=0`.
- **취소**: `api.gd` 를 바꾸지 않으므로 `ApiCall.cancel()` 은 결과만 버린다(기존 `_run_phone` 규칙). 엔진은 그 전사를 끝까지(또는 12초 타임아웃까지) 돈다. 큐는 순서대로 처리하고, 앞 요청이 다음 요청을 깨뜨리지 않는다.
- **자동 끔(§1.7④(폰))**: 시간 초과가 연속 2번이면 pref `stt_phone_off = true`. 그 뒤 `is_available_for` 는 false, `unavailable_reason_for` 는 `{"err_code":"engine_error","text_ko":TEXT_PHONE_OFF}`(TEXT_PHONE_OFF = "이 폰에서 채점이 두 번 연속 너무 오래 걸려서 폰 채점을 껐어요. 설정 > 음성 인식에서 다시 켤 수 있어요."). 사이에 성공이 한 번 있으면 횟수는 0. pref 를 false 로 되돌리면 다시 가능.
- **`score_params.json` v1(확정, §1.6(폰)에 필드 추가)**:
```json
{"v":1,"model_id":"whisper-base.en-q5_1","calibrated":true,"date":"YYYY-MM-DD",
 "ok_prob":0.45,"beam":1,
 "p_map":[[0.0,0.0],[0.45,0.45],[1.0,1.0]],
 "final_map":[[0,0],[100,100]],
 "report":{"synth_clips":0,"user_clips":0,"ok_agree_synth":0.0,"ok_agree_user":0.0,"score_mae":0.0,"score_p90":0.0,
           "fluency_mae":0.0,"wrong_lower_pairs":0.0,"wrong_pass_rate":0.0,"clean_fail_rate":0.0,"fallback":"none"}}
```
  읽기 규칙: 파일 없음·JSON 아님·`v != 1`·`model_id` 가 지금 모델과 다름·`calibrated != true`·`ok_prob ∉ (0.2, 0.8)`·`beam ∉ {1,2,3}`·`valid_p_map` 거짓·`final_map` 이 있는데 `valid_final_map` 거짓 → **항등 매핑, ok_prob 0.45, beam 1, final_map 항등** + `degraded` 에 `score_uncalibrated`. tiny 모델은 항상 `score_uncalibrated` + `stt_tiny_model`. `final_map` 이 없으면 항등. `report.fallback` ∈ `none|beam|q8|final_map`.
- **공개 계약**(새, `godot/scripts/local/local_stt.gd`, `class_name` 없음 — `LocalApi` 가 경로로 불러 쓴다):
```
const STT_TIMEOUT_SEC := 12.0
const IDLE_UNLOAD_SEC := 90.0
const MAX_AUDIO_SEC := 30.0
const PARAMS_PATH := "res://data/score_params.json"
static var bridge_factory: Callable        # 시험: () -> WhisperBridge 와 같은 함수를 가진 가짜. 기본은 ClassDB.instantiate("WhisperBridge")
static var params_path_override := ""      # 시험
static var clock: Callable                 # 시험: () -> 초(float)
static func handle(method: String, path: String, query: Dictionary, body: Dictionary) -> Dictionary   # 코루틴
static func is_available() -> bool
static func unavailable_reason() -> Dictionary
static func is_available_for(path: String, query: Dictionary, body: Dictionary) -> bool
static func unavailable_reason_for(path: String, query: Dictionary, body: Dictionary) -> Dictionary
static func warm() -> void                  # 폰이고 모델 ready 면 request_load 만(비동기). PWA 가 SpeakDrill 에서 부른다
static func params() -> Dictionary         # 읽은 score_params(검증 후 값) + "degraded": bool
static func stats() -> Dictionary          # 진단용 숫자만(아래 키)
static func bench(wav: PackedByteArray, target: String, n: int, on_step: Callable = Callable()) -> Dictionary  # 코루틴, 진단 전용
static func reset_for_tests() -> void
```
  `stats()` 키(전부 숫자·코드·버전 문자열): `runs, ok, timeouts, engine_err, aborted, load_count, unload_count, load_ms_first, stt_ms_p50, stt_ms_p95, stt_ms_max, audio_ms_p50, rtf_p50, rss_mb_before_load, rss_mb_after_load, rss_mb_peak, abort_patch(0/1), bridge_version, model_id, params_state("calibrated"|"uncalibrated"), beam, phone_off(0/1), recent:[{score, n, ok}](최근 20개, 글자 없음)`. `rss_*` 는 `WhisperBridge.memory_info()`(kB → MB 반올림), 알 수 없으면 0.
  `bench()`: 같은 WAV·타깃으로 `n` 번 전사+채점, `StudyLog`·`Store` 기록 0, 결과 `{n, ok, fail, ms_p50, ms_p95, ms_max, rss_mb_peak, seconds}`.
- `SttEngine`(새, `godot/scripts/local/stt_engine.gd`, `class_name SttEngine extends Node`): `static func get_or_create() -> SttEngine`, `func request_load(path: String, threads: int = 0) -> void`, `func request_unload() -> void`, `func transcribe(wav: PackedByteArray, opts: Dictionary) -> Dictionary`(코루틴), `func abort() -> void`, `func loaded_path() -> String`, `func busy() -> bool`, `func shutdown() -> void`(종료 경로, 시험이 부름). 시험용 `static var main_thread_calls: int`(가짜 브리지가 메인 스레드에서 불리면 올라감).
- 로그: `print`·`push_warning` 에 인식 글자·타깃 금지(X-7). 숫자만.
- 다른 작업과의 계약: P0 의 `engine_error`·`stt_timeout` 재시도 규칙을 그대로 쓴다. PSA 진단 시트는 `stats()`·`bench()`·`params()` 만, PWA 는 `warm()` 만 부른다(둘 다 `load("res://scripts/local/local_stt.gd")` 로, 파일이 없으면 아무것도 안 함).

### 2.4 PA5a / PA5b — 점수 보정 (2파 / 3파)
- 하는 일·합격선은 §1.6(폰)·`docs/v201_plan.md` §1.1-3. 바뀐 점: 두 작업으로 나눈다, 녹음 도구 확정, 폴백 순서(결정 7)를 데이터로 표현.
- **PA5a(도구, 2파)**: 새 파일 7개(§3). 모든 산출물은 `--out <scratch 폴더>`, 저장소에 오디오·전사 0.
  - `calib_make_set.py --out <dir> [--n-sentences 200] [--voices 4] [--seed 7]`: `godot/data/pack/practice_en.json`(설계자가 위치 확인) 의 3~10 낱말 문장(모자라면 코스 `godot/data/course/en_sentences.json` 에서 보충) → 서버 `synth_wav`(프로세스 안)로 Kokoro 합성. 변형·개수는 §1.6(폰). `manifest.json`(`clip, sentence_id, target, variant, wrong:{index, said}` + sha256).
  - `calib_record.py --out <dir> [--dry-run]`: `sounddevice`(backend\.venv 에 있음)로 16 kHz 모노 녹음. 시작 때 동의 문구(§4.1)를 그대로 보이고 `y` 를 입력해야 시작. 문장 30개 × (정상, 지정 단어를 바꿔 읽기) = 60클립, 문장당 6초 카운트다운 녹음, Enter 로 다음, `r` 로 다시. `--dry-run` 은 마이크를 열지 않고 문장 목록·동의 문구만 출력하고 아무것도 쓰지 않는다. 출력에 인식 글자·문장 원문을 로그 파일로 남기지 않는다(화면 표시는 허용).
  - `calib_pc_run.py --set <dir> --out <json>`: 서버 `transcribe`(CPU, `--stt-cpu` 와 같은 설정)·`score_en` 을 프로세스 안에서. 포트·서버 프로세스 0.
  - `godot/tools/calib_phone.gd`: `& $G --headless --path <W>\godot -s res://tools/calib_phone.gd -- --model=<bin> --set=<dir> --out=<json> [--beam=1]`. Windows DLL(N0) + 같은 모델로 `words` 를 저장. 브리지가 없으면 `CALIB_PHONE_NO_ENGINE` 과 종료 2.
  - `calib_fit.py --pc <json> --phone <json> --out-params <json> --report <json> [--holdout 0.3] [--seed 7]`: §1.6(폰) 5 의 등위 회귀 + `ok_prob` 탐색 + 보류 30% 평가. 합격선(아래) 미달이면 `CALIB_FAIL <지표>` 와 종료 1, `--out-params` 를 쓰지 않는다. 짝이 맞지 않는 데이터(일치율 < 0.6)·빈 입력·한쪽만 있는 클립도 종료 1.
  - `test_calib_fit.py`(≥ 20 시험), `phone_src/calib/README.txt`(절차·동의 문구·삭제 방법).
- **PA5b(실행, 3파)**: ★사용자 녹음(§4.1) 뒤. PA5a 도구로 합성 세트·사용자 세트를 돌려 `godot/data/score_params.json` 과 `phone_src/calib/report_v201.json`(숫자만: 클립 수·지표·신뢰구간·폴백 단계)을 만든다. 도구 결함은 PA5b 가 고치지 않고 오케스트레이터에게 보고해 PA5a 를 다시 연다(소유권).
- **합격선**(`docs/v201_plan.md` §1.1-3, 보류 30%): 단어 `ok` 일치율 합성 ≥ 0.85·사용자 ≥ 0.80, 최종 점수 MAE ≤ 10·p90 ≤ 20, 유창성 MAE ≤ 15, 틀린 클립 < 깨끗한 클립 쌍 ≥ 0.95, ~~틀린 클립 70+ 비율 ≤ 0.10~~ → **폰의 틀린 클립 70+ 비율이 PC 기준 비율과 ±0.10 이내**(D-4, 2026-11-22), 깨끗한 클립 70 미만 ≤ 0.10.
- **폴백 순서(결정 7)**: ① `beam` 2 → 3 으로 `calib_phone.gd --beam=` 재측정(속도 영향은 H3 에서 확인), 통과하면 `score_params.beam` 에 기록 ② 그래도 미달이면 **멈추고 오케스트레이터에게 보고** → ★사용자 재승인 뒤 `base.en-q8_0`(약 82 MB) 비교(모델 추가는 `models.json`·`models-1` 변경이 따르므로 별도 지시) ③ 마지막으로 "폰 간이 채점" 표시를 유지한 채 `final_map` 으로 폰 최종 점수만 조정(틀린 클립 70+ ≤ 0.10 과 깨끗한 클립 70 미만 ≤ 0.10 을 동시에 만족하는 단조 매핑을 `calib_fit.py --fit-final` 이 찾는다). `report.fallback` 에 단계를 적는다. 어느 단계도 2.0.1 공개를 자동으로 막지 않는다(결정 7 A): 합격선 미달 항목은 릴리스 노트·ROADMAP 의 알려진 한계에 숫자로 적는다.

### 2.5 PSA — 설정 "음성 인식" 카드·라디오·기능 현황·진단 시트 (2파)
- 하는 일은 §3 #2·#15(폰)와 PS-1~7(§6.15(폰)). 확정 문구·구조:
  - 설정(폰, `standalone_panels`)의 `engine` 구역에 **제목 "음성 인식"** 묶음(노드 이름 `SttSection`)을 `_build_processing()` 앞에 넣는다: `SttModelCard.build(self)` → 라디오(`UI.segmented`, 노드 이름 `ScoreWhereSeg`) **"폰에서 채점" / "PC에서 채점"**(P0 문구 'PC에서 채점' 과 같은 글자) → 설명 한 줄 → (pref `stt_phone_off` 가 참이면) 스위치 "폰 채점 다시 켜기"(`SttPhoneOnBtn`) → 행 "진단 보기"(`SttDiagBtn`) → `SttDiagSheet.open(self)`.
  - 설명: phone = "말하기 점수를 이 폰에서 계산해요. 녹음은 폰 밖으로 나가지 않아요. 소리별 분석 화면만 PC를 써요." / pc = "PC에 연결돼 있으면 PC에서 채점해요(소리별 팁 포함). PC가 없으면 이 폰에서 채점해요."
  - 라디오는 `Store.set_pref("score_where", v)` 만 하고 `Route.policy_for` 가 그 값을 읽는다(P0). PC 앱에는 이 묶음이 없다.
  - 라디오 항목은 상수 한 줄로 둔다(변이 시험 대상): `const SCORE_WHERE_CHOICES := [["phone", "폰에서 채점"], ["pc", "PC에서 채점"]]`.
  - `CapabilityPanel.REASONS`: `model_missing` = "설정 > 음성 인식에서 모델을 받으면 폰에서 쓸 수 있어요.", `model_corrupt` = "음성 인식 모델이 손상됐어요. 설정 > 음성 인식에서 다시 받아 주세요.", `engine_missing` 은 그대로, `engine_error` 새 줄 = "폰 채점이 꺼져 있어요. 설정 > 음성 인식에서 다시 켤 수 있어요." `no_ai` 는 그대로(결정 1). 키 16개 그대로.
- **진단 시트**(새, `godot/scripts/ui/stt_diag_sheet.gd`, `class_name SttDiagSheet`):
```
static var stt_script_override: GDScript = null    # 시험: 가짜 LocalStt
static var clipboard_hook: Callable                # 시험: (text) -> void. 기본 DisplayServer.clipboard_set
static var record_hook: Callable                   # 시험: () -> {ok, wav: PackedByteArray}. 기본 Recorder
static func open(host: Node) -> Node               # Sheet
static func report_text(extra: Dictionary = {}) -> String   # 복사할 글(§4.3 형식). extra: {bench20, bench60, battery_start, battery_end}
```
  화면: [한 문장 녹음](`DiagRecBtn`, 3~6초 영어 한 문장, 녹음은 메모리에만), [20회 속도 시험](`DiagBench20Btn`), [60회 연속 시험](`DiagBench60Btn`), "시작 배터리 %"·"끝 배터리 %" `SpinBox`(`DiagBatStart`·`DiagBatEnd`, 0~100), [결과 복사](`DiagCopyBtn`), 결과 요약 줄(읽을 수 있는 단위: "중앙값 1.8초", "메모리 +230 MB"). **화면에 원시 복사 글을 보이지 않는다**(5자리 숫자 금지 C-15). 시험 타깃 문장은 고정 "I would like a cup of coffee, please."(화면에 보여 사용자가 읽는다).
- 다른 작업과의 계약: `LocalStt` 는 `load()` 경로로 쓴다(PA4 병합 전에도 컴파일·시험 가능, 없으면 `stt=missing`). 카드 부품(PA3) 파일은 고치지 않는다.

### 2.6 PWA — 말하기 화면 연결 (3파)
- 하는 일은 §3 #3~#8(폰)·§6.16(폰). 확정·추가:
  - `SelfRatePanel`: 폰이고 `Route.why_none("POST","/score",{})` 의 `err_code` 가 `model_missing` 또는 `model_corrupt` 이면 카드 안에 버튼 **"음성 인식 모델 받기 (약 60 MB)"**(`SelfRateModelBtn`; corrupt 면 "음성 인식 모델 다시 받기") → `SttModelCard.open_sheet(<화면 루트>)`. 숫자는 `ModelStore.mb_label(model.bytes)` 로 만든다. 일본어(`lang=="ja"`)는 버튼 없음.
  - `ScorePanel.build(res, lang)`: `res.via == "phone"`(문자열 비교, 다른 타입은 무시)일 때만 점수 옆 작은 글 **"폰 간이 채점"**(노드 이름 `PhoneScoreBadge`, 상수 `const PHONE_BADGE := "폰 간이 채점"`). `degraded` 에 `score_uncalibrated` 가 있으면 같은 줄 끝에 " · 보정 전"(PA5b 가 병합되기 전 빌드와 tiny 모델에서 보인다).
  - `SpeakDrill`: `_ready()` 에서 폰이고 `lang=="en"` 이면 `LocalStt.warm()`(경로 로드, 없으면 무시). `/score` 본문에 `need_ph:true` 는 `source=="drill"` 이고 `lang=="en"` 일 때만(§6.16 PWA-4(폰)). 공개 시그니처(`request`, `api_hook`, `scored`, `silent_result`, `new_footer_row`, `touch_button`, `fit_touch`) 변경 0.
  - `shadow_screen.gd`(564행 부근)·`song_sing_tab.gd` `SELF_NOTE`: 이유별 문구. `model_missing` → "점수를 보려면 설정 > 음성 인식에서 모델을 받아 주세요(약 60 MB). 지금은 스스로 평가해요.", `engine_missing` → 기존 PC 문구, 그 밖(PC 없음 등) → 기존 문구. 일본어 노래는 변경 0.
  - 코스 말하기(`CourseExerciseView` 의 `SpeakDrill.new(LANG, "course")`)·코스 플레이어 말하기 단계·쉐도잉이 **코드 변경 없이** 폰 경로로 채점되는지를 PWA 시험이 확인한다(`course_exercise_view.gd`·`course_player.gd` 는 PWA 소유가 아니다).
- 다른 작업과의 계약: PA3 `open_sheet`·`mb_label`, PA4 `warm()`. `lesson_view.gd`·`talk_view.gd`·`course_*` 파일은 건드리지 않는다.

### 2.7 PA7 — 빌드 통합 (1파)
- 하는 일은 §1.2(d)(폰)·§6.8(폰). 바뀐 점:
  - `build_android.ps1`: **릴리스(비 `-Debug`) 빌드는 `godot\bin\libwhisper_bridge.android.arm64.so` 와 `godot\whisper_bridge.gdextension` 이 있어야 하고**, `.so` 의 sha256 이 `BUILD_INFO.json` `artifacts.android-arm64.sha256` 과 같아야 한다. 아니면 한국어 오류("폰 음성 인식 라이브러리가 없어요(또는 기록과 달라요). native\whisper_bridge\README.txt 의 순서로 준비한 뒤 다시 하세요.")와 종료 1, APK 를 만들지 않는다. `-Debug` 는 같은 상황에서 경고만 하고 계속한다(네이티브 없는 시험 APK 허용). 새 스위치 `-NoNative`(디버그 전용: 있어도 넣지 않음) — 선택, 워커가 필요하면.
  - `-VerifyApk` 경로(공개 스크립트가 올릴 파일을 검사하는 단계)에서도 릴리스면 `check_phone_native.ps1 -Apk` 를 부른다.
  - `export_presets.cfg`: preset.0(Windows) `exclude_filter` 를 `"tests/*, tools/*, data/pack/*, bin/*, whisper_bridge.gdextension"` 로 바꾸는 한 줄만.
  - `check_phone_native.ps1`(새): `-Apk <apk> [-BaselineApk <apk>] [-SelfTest]`. 검사 (a) `.so` 있음·ABI 폴더 `arm64-v8a` 하나 (b) `.so` 의 모든 LOAD align `2**14`(NDK `llvm-objdump`) (c) `zipalign -c -P 16 -v 4` 마지막 줄 `Verification successful` (d) `aapt2 dump xmltree --file AndroidManifest.xml` 의 `allowBackup` 이 false (e) NEEDED ⊆ {`libc.so`,`libm.so`,`libdl.so`,`liblog.so`,`libandroid.so`} (f) APK 안 `.dll`·`ggml-*.bin` 0개 (g) 크기 ≤ 100,000,000 B, 기준 APK 대비 증가 ≤ 15,000,000 B(스크립트 안 한 줄 `$MaxGrowBytes = 15000000`, `-BaselineApk` 기본 `packaging\out\release_2.0.0\hoehwa-practice-android-2.0.0.apk`, 없으면 이 항목 "미검증" 줄). 마지막 줄 `PHONE_NATIVE_OK` 또는 `PHONE_NATIVE_FAIL <항목들>`, 종료 0/1.
- 도구 경로: Android SDK·NDK 는 Claude 앱 가상 LocalAppData 아래(메모리 `release-key-location`). 서명 키·비밀번호를 출력·기록하지 않는다.

### 2.8 PZ — 문서 (4파)
- `README.md` 폰 절(after=Z): 2.0.1 의 모델 받기(약 60 MB, 와이파이 확인, 이어받기), 오프라인 채점, "음성 인식" 설정의 '폰에서 채점/PC에서 채점', "폰 간이 채점" 표시와 한계(보정 지표 숫자는 `report_v201.json` 값), 음소·억양·일본어는 PC, 녹음은 폰 밖으로 안 나감, 진단 복사, **폰 AI 키 설정은 2.0.2 예정**(결정 1). 1주 소리 노트 [듣기]. `ROADMAP.md`(after=Z): 2.0.1 완료 항목·알려진 한계(PA5 미달 지표, 온도 미측정, 실기 미검증 항목). `INSTALL.md`: APK 덮어쓰기 업데이트(학습 기록·모델 유지), 모델 지우기.
- 버전 숫자·`WORKLOG.md` 는 건드리지 않는다.

### 2.9 F1 — 1주 소리 노트 [듣기] (1파, 결정 2)
- 사실(S5): 노트가 앱에 안 보인다. 그래서 F1 은 **보여 주는 곳 + [듣기]** 를 같이 만든다. 가장 작은 변경으로 코스 홈의 **주 상세 시트**에 버튼 하나를 더한다.
- **데이터 규칙(원고·빌드 무변경, S6 때문에 `say` 필드를 새로 넣지 않는다)**: `CourseSoundNotes.speak_text(note)`:
  1. `note.kind == "sound"` 이고 `note.en` 이 정규식 `^[A-Z] \(([a-z][a-z\- ]*)\)$` 에 맞으면 괄호 안 글자 이름(`"A (ay)"` → `"ay"`, `"W (double-you)"` → `"double-you"`, `"Z (zed)"` → `"zed"`). 발음샘플 01~05(사용자 확인)와 같은 읽기 글이다.
  2. `note.kind == "sound"` 이고 `note.en` 이 `^[aeiou]$` 이면 `text_ko` 끝의 `\(([a-z]+(?:, [a-z]+)*)\)\s*$` 괄호 안 예시 낱말(`"cat, bag, hat"`). 고립 모음은 읽지 않는다.
  3. 그 밖은 `""`(버튼 없음). 이 규칙으로 1~16주 전체에서 정확히 31개(전부 1주)가 나온다(설계자가 실제 데이터로 확인).
  4. `const SPEAK_OVERRIDE := {}`(id → 읽을 글). H4b 결과 이상한 글자가 있으면 데이터 대신 여기에 한 줄 넣는다(빈 상태로 출시).
  5. 정규식은 상수로 둔다(상수 변이 시험이 이 글자를 찾는다): `const RE_VOWEL := "^[aeiou]$"`, `const RE_LETTER := "^[A-Z] \\(([a-z][a-z\\- ]*)\\)$"`, `const RE_EXAMPLES := "\\(([a-z]+(?:, [a-z]+)*)\\)\\s*$"`.
- **공개 계약**(새):
```
CourseSoundNotes (godot/scripts/core/course_sound_notes.gd, class_name, 정적)
  static func notes_for_week(w: int) -> Array      # CourseData.week(w).notes 중 kind=="sound", 원래 순서, 각 {id, en, text_ko, speak}
  static func speak_text(note: Dictionary) -> String
  static func count_speakable(w: int) -> int
SoundNotesSheet (godot/scripts/ui/sound_notes_sheet.gd, class_name)
  static var speak_hook: Callable                  # 시험: (text, lang) -> void. 기본 Tts.speak(text, "en")
  static func open(host: Node, w: int) -> Node     # Sheet. 제목 "알파벳·모음 소리"
```
  시트 내용: 노트마다 한 행(영어 `en` 굵게 + `text_ko` 작은 글), `speak != ""` 이면 행 오른쪽 [듣기] 버튼(노드 이름 `SoundPlay_<id>`, 높이 ≥ 44). 맨 위 한 줄 "앱 소리는 합성음이에요. 짧은 모음은 예시 낱말로 들려줘요."
- `CourseHome.week_body(w, state)`: `CourseSoundNotes.count_speakable(w) > 0` 이면 "이번 주 공부량" 아래에 버튼 **"알파벳·모음 소리 듣기"**(노드 이름 `SoundNotesBtn`) → `SoundNotesSheet.open(_host(), w)`. 그 밖 주는 변화 없음.
- **(권장 포함, §8 O-4)** 같은 함수의 기존 문제 S12: `scene.canada` 줄 중 `^cn_[a-z0-9_]+$` 모양(id 그대로)은 보이지 않게 한다(한 줄 조건). 오케스트레이터가 빼라고 하면 뺀다.
- 안전장치(결정 2): 구현이 2일 넘게 늘거나 H4b 에서 이상한 소리가 5개 이상이면 2.0.2 로 넘긴다(그때 F1 브랜치는 병합하지 않는다).

### 2.10 F2 — 원고 M3 3건 + 11주 설명 1줄 + 재빌드 (1파, 결정 3·4)
- 대상과 **추천 수정안(추측: Gemini 원문 지적을 찾지 못함 — 오케스트레이터가 원문을 지시에 붙이고, 원문과 다르면 원문을 따른다)**:

| id | 지금 | 추천 수정 | 이유(추측) |
|---|---|---|---|
| `w0164`(6주, `not`) | `ko` "~이 아니에요", `ko2` "~않아요" | `ko` "아니다(부정)", `ko2` "~지 않아요" | "not ko" 지적: 낱말 뜻이 문장 꼴로 적힘 |
| `s0011`(1주) | "Bye, bye." / "바이바이." | "Bye-bye." / "잘 가요, 안녕." | 쉼표 표기와 음차 번역 |
| `s0295`(5주) | "Our family is very big." / "우리 가족은 아주 커요." | 영어 그대로 / "우리 가족은 식구가 아주 많아요." | "가족이 커요" 가 어색함 |
- 11주 `p_price_say` `grammar_ko`(S8): 2번째 줄을 "가게에서는 5달러 99센트를 five dollars and ninety-nine cents 라고 길게 말하기보다 보통 It's five ninety-nine. 처럼 dollars 와 cents 를 빼고 숫자를 두 번에 나눠 말해요." 로 바꾼다(줄 수 3 유지, 2~4줄 규칙). `$5.99`·`five ninety-nine` 규칙과 `numbers_en.py` 는 그대로(결정 3).
- 재빌드: `build_course.py --in course_src\en --out godot\data\course --weeks 1-16`(엄격 린트 통과 때만 씀). 바뀌는 생성 파일은 `en_lexicon.json`·`en_sentences.json`·`en_patterns.json`·`course_manifest.json`(해시), `en_weeks.json` 은 안 바뀔 것으로 예상(추측, 바뀌어도 소유 범위 안).
- 바뀐 항목 4개를 Gemini Hydrogen 에게 재검수 받는다(오케스트레이터, CLAUDE.md 표의 콘텐츠 검수). C 0·M 0 이 병합 조건.

### 2.11 F3 — 저장 실패 오류 제목 (1파, 결정 4)
- `course_player.gd`: `const TITLE_OPEN := "문제를 열 수 없어요"`, `const TITLE_SAVE := "기록을 저장하지 못했어요"`(새 상수). `_show_error(text: String, title: String = TITLE_OPEN)`. 코스 진도 저장 실패(673행 `_show_error(TEXT_SAVE)`)만 `TITLE_SAVE` 를 넘긴다. 다른 호출은 그대로.
- `course_flow_test.gd`: 기존 "save fail" 흐름(1166~1189행)에 `ErrorTitle` 글 == `TITLE_SAVE` 단언, 기존 build 오류 흐름에 `ErrorTitle` == `TITLE_OPEN` 단언을 **더한다**(기존 단언 삭제·완화 0).

---

## 3. 소유권 OWN 블록과 파 순서

### 3.1 파 순서와 병렬
```
0파(오케스트레이터): 이 문서 확정·커밋 → (선택) PI0 키 시험은 2.0.2 일정으로 따로
1파: PA2 ∥ PA3 ∥ PA7 ∥ F1 ∥ F2 ∥ F3            (파일 겹침 0)
2파: PA4(PA2·PA3 병합 뒤) ∥ PSA(PA3 병합 뒤) ∥ PA5a(언제든, 2파에 둠)
     ★ PA5a 병합 직후 사용자 녹음 8분(§4.1)
3파: PA5b(PA4·PA5a 병합 + 녹음 뒤) ∥ PWA(PA4·PSA 병합 뒤)
4파: PZ → 버전 올리기(오케스트레이터) → 통합 시험 T(§6) → 시험 APK(정식 키) → models-1 업로드(§6.3) → ★실기 H2~H5(§4.2) → 2.0.1 공개
```
| 작업 | 선행(병합) | 함께 해도 됨 | 위험도·검토 |
|---|---|---|---|
| PA2 | - | 1파 전부 | 보통: reviewer 1회 |
| PA3 | - | 1파 전부 | 높음(다운로드·삭제): reviewer + 오케스트레이터 재실행(PA3-1·PA3-4·PA3-6) |
| PA7 | - | 1파 전부 | 높음(빌드·서명): reviewer + 재실행(PA7-1·PA7-3·PA7-5) |
| F1 | - | 1파 전부 | 보통 |
| F2 | - | 1파 전부 | 보통 + 콘텐츠 재검수(Gemini) |
| F3 | - | 1파 전부 | 낮음~보통: reviewer 1회(시험 변경 포함) |
| PA4 | PA2, PA3 | PSA, PA5a | 높음(동시성·오디오): reviewer + 재실행(PA4-1·PA4-6·PA4-13) |
| PSA | PA3 | PA4, PA5a | 보통 |
| PA5a | - | PA4, PSA | 높음(녹음 개인정보): reviewer + 재실행(PA5a-4·PA5a-6) |
| PA5b | PA4, PA5a, ★녹음 | PWA | 높음: 재실행(PA5b-2·PA5b-4) |
| PWA | PA4, PSA | PA5b | 보통 |
| PZ | 3파 전부 | - | 낮음: 오케스트레이터 확인 |
- 1파 6개는 파일이 하나도 겹치지 않는다. F1·F2 는 같은 코스 데이터를 읽지만 F1 은 `en_weeks.json` 의 **노트만** 읽고 F2 는 노트를 바꾸지 않는다.

### 3.2 OWN 블록 (기준: 이 블록. 줄 형식 `작업 종류 경로 [after=작업]`)
- `after=E5`·`E4b`·`E7`·`A1`·`A2`·`A3`·`KB`·`Z` 는 `docs/v200_design.md` 의 작업(모두 main 에 병합됨)을 뜻한다. 이 문서 안에서 같은 파일을 두 작업이 소유하는 경우는 없다.
- 새 `.gd` 의 `.uid` 짝은 그 작업 소유로 본다(줄에는 적지 않는다).
- 읽기만: `route.gd`, `api.gd`, `local_api.gd`, `store.gd`, `recorder.gd`, `tts.gd`, `course_data.gd`, `course_exercise_view.gd`, `native/*`(전부), `backend/*`(전부), `course_src/tools/*`.
- 수정 금지(어느 작업도 소유하지 않음): `godot/project.godot`, `godot/scripts/sync/*`, `backend/*`, `native/whisper_bridge/*`(BUILD_INFO 포함), `packaging/publish_release.ps1`·`check_no_media.ps1`·`build_dist.ps1`·`installer/*`, 일본어 파일, 위 표에 없는 기존 시험.

<!-- OWN-BEGIN -->
PA2 new godot/scripts/core/score_core.gd
PA2 new godot/tests/score_parity_test.gd
PA2 new godot/tests/score_parity_test.tscn
PA2 new godot/tests/fixtures/score_golden_en.json
PA2 new phone_src/tools/make_score_golden.py
PA2 new phone_src/tools/test_make_score_golden.py
PA3 new godot/scripts/local/model_store.gd
PA3 new godot/scripts/ui/stt_model_card.gd
PA3 new godot/data/models.json
PA3 new godot/tests/model_store_test.gd
PA3 new godot/tests/model_store_test.tscn
PA3 new godot/tests/stt_model_card_test.gd
PA3 new godot/tests/stt_model_card_test.tscn
PA3 new godot/tests/run_model_tests.ps1
PA3 new phone_src/tools/fake_model_server.py
PA7 mod packaging/build_android.ps1
PA7 mod godot/export_presets.cfg
PA7 new packaging/check_phone_native.ps1
F1 new godot/scripts/core/course_sound_notes.gd
F1 new godot/scripts/ui/sound_notes_sheet.gd
F1 mod godot/scripts/views/course_home.gd after=E5
F1 new godot/tests/sound_notes_test.gd
F1 new godot/tests/sound_notes_test.tscn
F2 mod course_src/en/weeks/w001.json after=A1
F2 mod course_src/en/weeks/w005.json after=A2
F2 mod course_src/en/weeks/w006.json after=A2
F2 mod course_src/en/weeks/w011.json after=A3
F2 mod godot/data/course/course_manifest.json after=KB
F2 mod godot/data/course/en_lexicon.json after=KB
F2 mod godot/data/course/en_patterns.json after=KB
F2 mod godot/data/course/en_sentences.json after=KB
F2 mod godot/data/course/en_weeks.json after=KB
F3 mod godot/scripts/practice/course_player.gd after=E4b
F3 mod godot/tests/course_flow_test.gd after=E4b
PA4 new godot/scripts/local/local_stt.gd
PA4 new godot/scripts/local/stt_engine.gd
PA4 new godot/tests/local_stt_test.gd
PA4 new godot/tests/local_stt_test.tscn
PA4 new godot/tests/fixtures/score_params_test.json
PSA mod godot/scripts/views/settings_view.gd
PSA mod godot/scripts/ui/capability_panel.gd
PSA mod godot/tests/settings_view_test.gd
PSA new godot/scripts/ui/stt_diag_sheet.gd
PSA new godot/tests/phone_settings_asr_test.gd
PSA new godot/tests/phone_settings_asr_test.tscn
PSA new godot/tests/stt_diag_test.gd
PSA new godot/tests/stt_diag_test.tscn
PA5a new phone_src/tools/calib_make_set.py
PA5a new phone_src/tools/calib_record.py
PA5a new phone_src/tools/calib_pc_run.py
PA5a new phone_src/tools/calib_fit.py
PA5a new phone_src/tools/test_calib_fit.py
PA5a new godot/tools/calib_phone.gd
PA5a new phone_src/calib/README.txt
PA5b new godot/data/score_params.json
PA5b new phone_src/calib/report_v201.json
PWA mod godot/scripts/ui/self_rate_panel.gd
PWA mod godot/scripts/ui/score_panel.gd
PWA mod godot/scripts/practice/speak_drill.gd
PWA mod godot/scripts/practice/shadow_screen.gd after=E7
PWA mod godot/scripts/song/song_sing_tab.gd
PWA mod godot/tests/self_rate_test.gd
PWA new godot/tests/phone_score_wiring_test.gd
PWA new godot/tests/phone_score_wiring_test.tscn
PZ mod README.md after=Z
PZ mod ROADMAP.md after=Z
PZ mod INSTALL.md
<!-- OWN-END -->

### 3.3 소유권 검사 (합치기 전에 오케스트레이터·검토자가 돌린다)
- 규칙은 §5.5(폰)와 같다: ① 이 문서 안에서 같은 파일을 두 작업이 가지면 뒤 줄에 `after=<앞 작업>` ② `docs/v200_design.md` OWN 의 파일(또는 그 `newdir` 안)을 가지면 `after=<그 v200 작업>` 이 같아야 함 ③ `mod` 인데 없음·`new` 인데 이미 있음·`newdir` 이 비어 있지 않음 → FAIL ④ 폴더 중첩·남의 폴더 안 파일 FAIL. 종료 0 = OK.
- 스크립트: `<scratch>\w_v201design\own_check_v201.py`(§5.5(폰) 스크립트와 같은 규칙·같은 마지막 줄 형식에 **세 번째 인자 `only=작업,작업`** 만 더함: ③ 의 파일 존재 검사를 그 작업들에만 적용. 병합이 진행되면 이미 병합된 작업의 `new` 줄이 "이미 있음"으로 FAIL 하므로, 파마다 그 파의 작업만 넘긴다).
```powershell
Set-Location 'D:\Ai\언어\app'
& 'D:\Ai\언어\app\backend\.venv\Scripts\python.exe' -X utf8 "$S\w_v201design\own_check_v201.py" docs/v201_design.md docs/v200_design.md
# 파별:  ... docs/v201_design.md docs/v200_design.md PA4,PSA,PA5a      (2파 시작 때)
```
- **기대 출력(main `40df5df`, 전 작업)**: 마지막 줄 `files 67 dirs 0 tasks 12 ordered 15 OK`, 종료 0. 설계자가 작성 직후 직접 돌렸고, 일부러 틀린 복사본 4종(①겹침 `after=` 없음 ②v200 파일 `after=` 불일치 ③없는 `mod` 파일 ④이미 있는 `new` 파일)에서 각각 `FAIL` 줄과 종료 1 을 확인했다(보고에 출력 첨부).

---

## 4. 사용자 요청 시점과 실기·진단

### 4.1 ★보정 녹음 (약 8분, 2파: PA5a 병합 직후)
- 오케스트레이터가 사용자에게 **PowerShell 한 줄**을 준다(사용자가 자기 PC 터미널에서 실행, 마이크 앞):
```powershell
& 'D:\Ai\언어\app\backend\.venv\Scripts\python.exe' -X utf8 'D:\Ai\언어\app\phone_src\tools\calib_record.py' --out 'C:\Users\rtyu6\AppData\Local\Temp\claude\D--Ai----app\c5535f7a-0e1a-4bb6-bdc3-5597b7f84c22\scratchpad\w_v201_pa5b\calib_user'
```
- 도구가 먼저 보이는 동의 문구(그대로): "영어 문장 30개를 한 번은 바르게, 한 번은 화면이 알려 주는 낱말 하나를 바꿔서 읽어요(약 8분). 녹음은 이 PC 의 임시 폴더에만 저장되고 저장소·인터넷으로 나가지 않아요. 보정이 끝나면 지워요(원하면 보관). 시작할까요? (y/n)".
- 끝나면 도구가 개수·총 길이만 출력한다. 보정 뒤 삭제 여부를 사용자에게 묻고 기록(기본 삭제).

### 4.2 ★실기 H2~H5 (약 25~35분, 4파: T 통과·models-1 업로드 뒤)
- **시험 APK 는 정식 키로 서명**(versionCode 20001, `build_android.ps1` 비 `-Debug`). 디버그 키 APK 는 2.0.0 위에 덮어 설치되지 않아 학습 기록을 지워야 하므로 쓰지 않는다. 실기를 통과한 **같은 APK 파일**을 그대로 공개한다(추측: 같은 versionCode 재설치도 된다 — 안 되면 공개 APK 를 20002 로 다시 만들지 않고 실기 APK 를 그대로 올린다).
- 전달: 카카오톡 "나와의 채팅" 또는 USB 파일 전송(`w_v200pa1\폰_시험_안내.txt` 와 같은 방식).

| ID | 무엇을 | 사용자 행동 | O 기준 | 근거 줄(진단 복사) |
|---|---|---|---|---|
| H2 | 덮어쓰기 설치·모델 받기 | ① 설치 **전** 코스 홈의 "N주 N일"과 복습 카드 수를 메모 ② APK 설치(덮어쓰기) ③ 설정 > 음성 인식 > [받기] → 와이파이 확인 → 받는 중 30 MB 쯤에서 비행기 모드 켰다 끄기 → [이어받기] ④ 완료 뒤 [진단 보기] > [결과 복사] → 채팅에 붙임 ⑤ (선택) [모델 지우기] 뒤 다시 받기 | 진도·카드 수가 설치 전과 같음, 이어받기로 완료, `verified=1`, 크래시 0 | `course_pos`, `review_cards`, `stt_model … state=ready verified=1`, `dl_resumed≥1`, `dl_last_host` |
| H3 | 속도·메모리·배터리 | 화면 켬·와이파이 켬·배터리 80% 이상. 진단 시트에서 시작 배터리 % 입력 → [한 문장 녹음]("I would like a cup of coffee, please.") → [20회 속도 시험] → [60회 연속 시험] → 끝 배터리 % 입력 → [결과 복사] | `bench20 p50_ms ≤ 3000`, `p95_ms ≤ 6000`, `load_ms_first ≤ 3000`, `rss_mb_after_load − rss_mb_before_load ≤ 600`, 60회 `fail=0`, 배터리 감소 ≤ 4%p(대조 없음: 같은 시간 화면만 켠 감소를 사용자가 한 번 따로 재면 그만큼 뺀다, 안 재면 그대로 판정), 온도는 **미검증**(S9, 사용자가 "손에 뜨겁다" 여부만 적음) | `bench20`, `bench60`, `battery_*` |
| H4 | 채점 체감 20문장 | 코스 말하기 또는 쉐도잉에서 문장 10개를 바르게, 같은 10개를 낱말 하나 바꿔 말하기 → [결과 복사] | 바른 문장 대체로 70+, 바꾼 낱말 ✗ 표시, 납득 안 되는 점수 ≤ 2개(사용자 판단) | `recent=` 20개(점수/낱말 수/맞은 수) |
| H4b | F1 [듣기] 31개 | 코스 홈 > 1주 > [알파벳·모음 소리 듣기] → 31개 차례로 듣기 | 이상하게 들리는 것 ≤ 4개(번호로 알려 줌) | 사용자 보고 |
| H5 | 비행기 모드 | 비행기 모드 켬 → 레슨 말하기·쉐도잉·코스 말하기 각 2번 → [결과 복사] | 모두 점수 화면 + "폰 간이 채점", 크래시 0 | `api_sent_since_start=0`, `phone_served` 증가 |
- 선택 H6(저사양 흉내: 백그라운드 앱 많이)·H11(16 KB 페이지, S24 는 해당 없음으로 추측)은 하지 않아도 공개를 막지 않는다.

### 4.3 진단 복사 글 형식 (`SttDiagSheet.report_text`)
- 첫 줄 `hoehwa-diag 1`. 한 줄에 `키=값` 여러 개, 공백 구분. **인식 글자·타깃 문장·파일 경로·키·사용자 이름 0**(경로는 `user_dir_internal` 0/1 로만).
```
hoehwa-diag 1
app=<config/version> platform=<OS.get_name()> os=<OS.get_version()> device=<OS.get_model_name()> cores=<n> ram_mb=<physical/10^6>
bridge=<WhisperBridge.version()> abort_patch=<0|1> cpu=<cpu_features 공백→+>
user_dir_internal=<0|1>            # OS.get_user_data_dir() 가 /data/user/ 또는 /data/data/ 로 시작하면 1
stt_model=<id> state=<state> file_mb=<n> verified=<0|1> params=<calibrated|uncalibrated> beam=<n> phone_off=<0|1> score_where=<phone|pc>
dl_requests=<n> dl_resumed=<n> dl_resume_mb=<n> dl_last_host=<호스트 이름만> dl_last_err=<코드>
stt_runs=<n> stt_ok=<n> timeouts=<n> engine_err=<n> aborted=<n> load_count=<n> unload_count=<n> load_ms_first=<ms>
stt_ms_p50=<ms> stt_ms_p95=<ms> stt_ms_max=<ms> audio_ms_p50=<ms> rtf_p50=<x.xx>
rss_mb_before_load=<n> rss_mb_after_load=<n> rss_mb_peak=<n>
bench20 n=<n> ok=<n> p50_ms=<ms> p95_ms=<ms> max_ms=<ms>
bench60 n=<n> ok=<n> fail=<n> minutes=<x.x> rss_mb_peak=<n> battery_start=<%> battery_end=<%>
recent=<점수/낱말수/맞은수>,<…>                 # 최근 20개
api_sent_since_start=<Api.sent_count> phone_served=<LocalApi.served_count>
course_pos=w<n>d<n> review_cards=<n>      # CourseStore.pos() 의 w·d, Store.progress["review"] 의 개수
```
- 값이 없으면 `-`(예: 벤치를 안 했으면 `bench20 -`). 숫자는 정수 또는 소수 둘째 자리.

---

## 5. 작업별 O/X 합격 조건

### 5.0 공통 명령 (작성자·검토자 모두 PowerShell 5.1 에서 이 블록을 먼저 실행)
```powershell
$R   = 'D:\Ai\언어\app'
$S   = 'C:\Users\rtyu6\AppData\Local\Temp\claude\D--Ai----app\c5535f7a-0e1a-4bb6-bdc3-5597b7f84c22\scratchpad'
$W   = 'D:\Ai\언어\app_wt\v201_<작업 소문자>'            # 검토 대상 worktree
$T   = "$S\w_rev_v201_<작업 소문자>"                     # 작성자는 "$S\w_v201_<작업 소문자>"
$BASE = '<분기 커밋>'                                    # 오케스트레이터가 지시에 적는다(1파는 이 문서를 커밋한 main 커밋)
$G   = 'C:\Users\rtyu6\Desktop\Godot_v4.6.3-stable_win64.exe\Godot_v4.6.3-stable_win64_console.exe'
$PY  = 'D:\Ai\언어\app\backend\.venv\Scripts\python.exe'
$API_ARG = '--api=http://127.0.0.1:9'                  # 이름이 Run-GT 의 -Api 스위치와 겹치면 안 된다(PowerShell 변수는 대소문자 무시, 2026-11-19 보정)
New-Item -ItemType Directory -Force "$T\appdata" | Out-Null
$env:APPDATA = "$T\appdata"                              # 실제 사용자 폴더를 쓰지 않게

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
# 상수 변이: 정확히 한 곳을 바꾼다(UTF-8, BOM 없음). 원복은 Restore.
function Mutate([string]$rel, [string]$from, [string]$to) {
  $f = Join-Path $W $rel
  $txt = [IO.File]::ReadAllText($f)
  $n = ([regex]::Matches($txt, [regex]::Escape($from))).Count
  if ($n -ne 1) { throw "MUTATE_TARGET_COUNT=$n ($rel)" }
  [IO.File]::WriteAllText($f, $txt.Replace($from, $to), (New-Object Text.UTF8Encoding($false)))
  "MUTATED $rel"
}
function Restore([string]$rel) { git -C $W checkout -- $rel; "RESTORED $rel" }
# 소유 밖 변경: 출력이 없어야 O
function Own-Diff([string]$task) {
  $doc = [IO.File]::ReadAllText("$W\docs\v201_design.md")
  $blk = (($doc -split [regex]::Escape('<!-- OWN-BEGIN -->'))[1] -split [regex]::Escape('<!-- OWN-END -->'))[0]
  $own = $blk -split "`n" | Where-Object { $_ -match "^$task\s" } | ForEach-Object { ($_.Trim() -split '\s+')[2] }
  $changed = @(git -C $W diff --name-only $BASE) + @(git -C $W ls-files --others --exclude-standard)
  $changed | Where-Object { $_ -and ($own -notcontains $_) -and ($_ -notmatch '\.uid$') } | Sort-Object -Unique
}
# N0: PA1 산출물 복사 + .gdextension 생성 + import 두 번 (빌드하지 않는다)
function Prep-Native {
  $src = "$S\w_v200pa1\copy_tree\godot\bin"
  New-Item -ItemType Directory -Force "$W\godot\bin" | Out-Null
  Copy-Item "$src\libwhisper_bridge.android.arm64.so", "$src\whisper_bridge.windows.x86_64.dll" "$W\godot\bin\" -Force
  $info = Get-Content "$W\native\whisper_bridge\BUILD_INFO.json" -Raw | ConvertFrom-Json
  foreach ($k in 'android-arm64', 'windows-x64') {
    $a = $info.artifacts.$k
    $h = (Get-FileHash ("$W\" + $a.file.Replace('/', '\')) -Algorithm SHA256).Hash.ToLower()
    if ($h -ne $a.sha256) { throw "NATIVE_SHA_MISMATCH $k" }
  }
  $tmpl = [IO.File]::ReadAllText("$W\native\whisper_bridge\whisper_bridge.gdextension.in").Replace("`r`n", "`n")
  [IO.File]::WriteAllText("$W\godot\whisper_bridge.gdextension", $tmpl, (New-Object Text.UTF8Encoding($false)))
  & $G --headless --path "$W\godot" --import *> "$T\import1.txt"
  & $G --headless --path "$W\godot" --import *> "$T\import2.txt"
  "NATIVE_READY import2_exit=$LASTEXITCODE"
}
$MODEL_BASE = "$S\w_v200pa1\models\ggml-base.en-q5_1.bin"
$MODEL_TINY = "$S\w_v200pa1\models\ggml-tiny.en-q5_1.bin"
$WAVS       = "$S\w_v200pa1\wav"
```
- 새 `class_name` 이 생긴 worktree 는 시험 전에 `& $G --headless --path "$W\godot" --import *> "$T\import.txt"` 한 번(네이티브가 있으면 두 번).
- 화면 시험 기본 모드: `pc`, `phone`, `phonefont`(폰 + 1.5배), `phonedark`. 아래 "4모드" 는 이 넷이다.

### 5.1 공통 조건 X (모든 작업에 붙는다. v200 §14.1 C-0~C-17 도 그대로 적용)
- **X-0 기준선**: 작업 전 자기가 건드리는 기존 시험(없으면 `smoke`·`route_test`)의 마지막 줄을 `$T\baseline.txt` 에 적는다. 보고 맨 앞 표에 붙인다.
- **X-1 시험 출력 통과**: 자기 시험의 모든 `Run-GT` 줄이 `exit=0`, `N passed, 0 failed`, `SCRIPT_ERROR=0`, `TEST_GUARD=1`.
- **X-2 비밀값·개인 글 0**:
```powershell
Select-String -Path "$T\*.txt" -Pattern 'ZZ_MARK_9731','ZZ_TGT_4417' -SimpleMatch | Measure-Object | ForEach-Object Count
git -C $W grep -I -n -E "(^|[^A-Za-z0-9_])sk-(ant-|proj-)?[A-Za-z0-9_-]{20,}|AIza[0-9A-Za-z_-]{30,}|gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,}|AKIA[0-9A-Z]{16}|-----BEGIN [A-Z ]*PRIVATE KEY-----" | Measure-Object | ForEach-Object Count
```
  기대: `0`, `0`. (`ZZ_TGT_4417` = 시험이 가짜 브리지 인식 글·타깃에 넣는 표식. 누출 검사기의 양성 대조는 **메모리 안 문자열**로 한다: 표식이 든 글을 검사 함수에 넣어 `selfcheck FAIL-as-expected leak` 줄만 출력하고 표식 자체는 stdout 에 내지 않는다. 그래서 출력 파일 전체에서 0건이어야 한다.)
- **X-3 추적 금지물**:
```powershell
git -C $W ls-files | Select-String -Pattern '(^godot/bin/|\.gdextension$|^native/_deps/|\.bin$|\.gguf$|\.onnx$|\.so$|\.dll$|\.wav$|\.mp3$|\.ogg$|\.m4a$)'
```
  기대: `godot/tests/fixtures/song/tone_8s.mp3` 한 줄뿐(기존 허용 파일).
- **X-4 공개 검사**: `powershell -ExecutionPolicy Bypass -File "$W\packaging\publish_release.ps1" -Version 2.0.1 -ScanOnly; "exit=$LASTEXITCODE"` → `exit=0`, `powershell -ExecutionPolicy Bypass -File "$W\packaging\check_no_media.ps1"; "exit=$LASTEXITCODE"` → `exit=0`.
- **X-5 서버·금지 파일 무변경**: `git -C $W diff --name-only $BASE -- backend godot/project.godot godot/scripts/autoload native godot/scripts/sync` → 출력 없음. 파이썬 도구가 서버를 불러 쓰는 작업은 전후 `Get-FileHash "$W\backend\*.py"` 가 같다.
- **X-6 네트워크 코드 위치**: `Select-String -Path (git -C $W diff --name-only $BASE | Where-Object { $_ -like '*.gd' } | ForEach-Object { "$W\$_" }) -Pattern 'HTTPRequest','HTTPClient','shell_open','request_permission' -SimpleMatch` → `model_store.gd` 의 `HTTPClient` 줄 밖에서 0줄.
- **X-7 로그 정적 검사**: `Select-String -Path "$W\godot\scripts\local\local_stt.gd","$W\godot\scripts\local\stt_engine.gd","$W\godot\scripts\local\model_store.gd","$W\godot\scripts\ui\stt_diag_sheet.gd" -Pattern '(print|push_warning|push_error|printerr)\(.*(text|target|transcript|words|url|path)'` → 0줄(파일이 아직 없으면 그 파일은 건너뜀).
- **X-8 소유 밖 수정 0**: `Own-Diff <작업>` → 출력 없음.
- **X-9 소유권 검사**: §3.3 명령에 그 파의 작업을 `only` 로 넘겨 `OK`.
- **X-10 프로세스**: 시작한 프로세스는 받은 PID 로만 종료. 보고에 "남은 프로세스·열린 포트 없음"(`Get-NetTCPConnection -State Listen -LocalPort (18791..18799) -ErrorAction SilentlyContinue` 결과 없음).
- **X-11 실제 사용자 폴더 무변경**: 시험 전후 `Get-ChildItem "$env:USERPROFILE\AppData\Roaming\Godot\app_userdata" -Recurse -File | Select FullName,Length,LastWriteTime` 목록이 같다(`$env:APPDATA` 를 바꿨으므로 시험은 거기에 쓰지 않는다).

### 5.2 PA2 — `ScoreCore`
- **PA2-1** 생성기 단위 시험:
```powershell
& $PY -I -X utf8 -m unittest discover -s "$W\phone_src\tools" -p "test_make_score_golden.py" *> "$T\pa2_1.txt"; "exit=$LASTEXITCODE"
Select-String -Path "$T\pa2_1.txt" -Pattern '^Ran \d+ tests','^OK'
```
  기대 `exit=0`, `Ran N tests`(N ≥ 15), `OK`.
- **PA2-2** 드리프트 점검: `& $PY -I -X utf8 "$W\phone_src\tools\make_score_golden.py" --check; "exit=$LASTEXITCODE"` → 마지막 줄 `SCORE_GOLDEN_OK cases=<n>`(n ≥ 120), `exit=0`.
- **PA2-3** 동등성 시험: `Run-GT score_parity_test pc`, `Run-GT score_parity_test phone` → X-1, N ≥ 300.
- **PA2-4~8**: §6.4(폰) PA2-4(결과 사전 완전 일치 ≥ 120사례)·PA2-5(정렬 ≥ 300쌍)·PA2-6(`en_words` ≥ 380 입력, `known_gaps`)·PA2-7(방어 입력)·PA2-8(40×60 채점 ≤ 50 ms 출력 줄)을 시험 출력 줄로 확인. 추가: `ok_prob ≠ 0.45` 사례 ≥ 10 일치.
- **PA2-9 매핑 함수**: 시험 줄로 `map_p` 항등·구간 선형·양 끝 clamp·NaN→0, `valid_p_map` 이 비단조·x 범위 밖·x 중복·점 1개·33개·`[[0,0],[1,1.2]]` 를 거부, `map_final` 같은 규칙(정수 반올림) — 각 ≥ 1 단언, 합계 ≥ 20.
- **PA2-10 일부러 틀린 황금**:
```powershell
$src = "$W\godot\tests\fixtures\score_golden_en.json"
& $PY -I -X utf8 -c "import json,sys; d=json.load(open(sys.argv[1],encoding='utf-8')); json.dump(d,open(sys.argv[2],'w',encoding='utf-8'),ensure_ascii=False)" $src "$T\golden_same.json"
& $PY -I -X utf8 -c "import json,sys; d=json.load(open(sys.argv[1],encoding='utf-8')); d['cases'][0]['expect']['score']+=1; json.dump(d,open(sys.argv[2],'w',encoding='utf-8'),ensure_ascii=False)" $src "$T\golden_bad.json"
Run-GT score_parity_test pc -More @("--golden=$T\golden_same.json"); Move-Item -Force "$T\score_parity_test_pc.txt" "$T\golden_same_out.txt"
Run-GT score_parity_test pc -More @("--golden=$T\golden_bad.json")
```
  기대: 같은 내용 복사본은 `exit=0`(인자 경로가 실제로 읽힘), 값 1개를 바꾼 복사본은 `exit=1`·`failed` ≥ 1.
- **PA2-11 상수 변이**: `Mutate 'godot\scripts\core\score_core.gd' 'const OK_PROB := 0.45' 'const OK_PROB := 0.40'; Run-GT score_parity_test pc; Restore 'godot\scripts\core\score_core.gd'; Run-GT score_parity_test pc` → 첫 실행 `exit=1`, 원복 뒤 `exit=0`.
- **금지**: X-5(서버 `.py` 해시 전후 같음), 네트워크·서버 프로세스·포트, X-8.

### 5.3 PA3 — `ModelStore`·카드
- **PA3-1** `powershell -ExecutionPolicy Bypass -File "$W\godot\tests\run_model_tests.ps1" *> "$T\pa3_1.txt"; "exit=$LASTEXITCODE"` → `exit=0`. 출력에 `model_store_test` N ≥ 90·`stt_model_card_test` 4모드 각 N ≥ 40·전부 `0 failed`, 마지막 줄 `남은 프로세스·열린 포트 없음`. 스크립트는 18791~18799 중 비어 있는 포트를 고르고 자기가 띄운 PID 만 끈다.
- **PA3-2** 매니페스트 확정값(오프라인):
```powershell
$m = Get-Content "$W\godot\data\models.json" -Raw -Encoding UTF8 | ConvertFrom-Json
foreach ($x in $m.models) { "{0} {1} {2} default={3}" -f $x.id, $x.bytes, $x.sha256, $x.default }
(Get-FileHash $MODEL_BASE -Algorithm SHA256).Hash.ToLower(); (Get-Item $MODEL_BASE).Length
(Get-FileHash $MODEL_TINY -Algorithm SHA256).Hash.ToLower(); (Get-Item $MODEL_TINY).Length
```
  기대: 두 모델 줄의 바이트·sha256 이 §2.2 값과 같고, 그 값이 scratch 실제 파일의 해시·크기와 같다. `default=True` 정확히 1개, 모든 `urls` 가 `https://`, 호스트가 `hosts` 접미사 규칙 안.
- **PA3-3~8**: §6.5(폰) PA3-2(정상 받기)·PA3-3(이어받기: `Range: bytes=N-`, 200 무시, 416)·PA3-4(해시 불일치 → `corrupt`, `.part` 0)·PA3-5(공간 10 MB → 요청 0건 `no_space`, 알 수 없음(-1) → `space_unknown` 후 확인 시 진행, 쓰기 오류 → `.part` 삭제)·PA3-7(받는 동안 프레임 카운터 ≥ 50/초, 취소·일시정지 2초 안 반응)·PA3-8(취소는 `.part` 유지, 지우기는 4종 파일 전부 삭제)을 `model_store_test` 출력 줄로 확인.
- **PA3-9 리다이렉트(바뀐 값)**: 가짜 서버 시나리오 — 302 5번 → 성공, 6번 → `dl_redirect`, 상대 `Location: /x/file` → 같은 호스트로 성공, 허용 밖 호스트(`evilgithub.com` 흉내: 시험 훅의 호스트 이름 치환) → `dl_host` 요청 0건, `http://`(훅 off) → 거절. 이어받기 두 번째 요청이 원래 URL 로 시작. `.part.json` 에 `?` 문자 0.
- **PA3-10 카드 버튼 흐름(C-14)**: `stt_model_card_test` 출력의 `press:` 줄 ≥ 12, [받기] → 와이파이 시트 [받기] → 진행 → 완료 → [모델 지우기] 확인 → `missing`. `Select-String -Path "$W\godot\scripts\ui\stt_model_card.gd" -Pattern '%d/%d','%d / %d'` → 0줄(진행 글은 `progress_label` 만). 화면 글에 연속 5자리 숫자 0(시험 단언 + selfcheck 줄).
- **PA3-11 일부러 틀린 입력**: 0바이트 응답·`Content-Length` 불일치·5xx 연속·URL 전부 실패·`models.json` 깨진 JSON(`manifest_path` 훅) → 크래시 0, 한국어 안내, `bad_manifest`. 출력에 `selfcheck FAIL-as-expected` 줄 ≥ 2.
- **PA3-12 상수 변이**: `Mutate 'godot\scripts\local\model_store.gd' 'const SPACE_MARGIN_MB := 100' 'const SPACE_MARGIN_MB := 0'` → `run_model_tests.ps1` `exit=1`, `Restore` 뒤 `exit=0`. 같은 방식으로 `const MAX_REDIRECTS := 5` → `:= 50` 이면 PA3-9 의 6번 리다이렉트 단언이 FAIL.
- **PA3-13 동기화 격리**: 시험이 `SyncDoc.SHARED_PREFS.keys()` 와 `["stt_model"]` 교집합 0 을 단언.
- **금지**: `HTTPRequest`(X-6), 모델 파일 추적(X-3), 실제 네트워크(가짜 서버 루프백만), X-8.

### 5.4 PA4 — `LocalStt`·`SttEngine`
- **PA4-1** `Run-GT local_stt_test pc`, `Run-GT local_stt_test phone` → X-1, N ≥ 120.
- **PA4-2~12**: §6.6(폰) PA4-2(가용성 전수표)·PA4-3(`p_map` 항등이면 `ScoreCore` 직접 결과와 같음, `godot/tests/fixtures/score_params_test.json` 변형 ≥ 9종: 없음·JSON 아님·`v:2`·모델 불일치·`calibrated:false`·ok_prob 0.9·비단조 p_map·beam 7·잘못된 final_map → 전부 항등 + `score_uncalibrated`)·PA4-4(응답 키)·PA4-5(입력 방어 한국어 문구)·PA4-7(수명: 첫 사용 로드 1회·90초 뒤 언로드(가짜 시계)·로드 실패 → `ModelStore.mark_corrupt` 호출·`model_corrupt`)·PA4-8(메인 비차단)·PA4-9(`Api.sent_count` 불변)·PA4-10(가짜 브리지 오류·음수 p·`start>end`·예외 → `engine_error` 또는 보정값)를 출력 줄로 확인.
- **PA4-6 시간 초과·취소(바뀐 점)**: 가짜 브리지 13초(가짜 시계) → `abort()` 호출 1회·결과 `stt_timeout`·늦은 결과 폐기. 요청 두 개 연속 → 순서대로 처리, 두 번째 결과 정상. 첫 요청을 `ApiCall.cancel()` 해도 두 번째가 막히지 않음.
- **PA4-13 비동기 로드·언로드(결정 5)**: 시험 줄로 ① 가짜 브리지의 `load_model`·`unload`·`transcribe` 호출 스레드가 전부 메인이 아님(`SttEngine.main_thread_calls == 0`) ② 가짜 `load_model` 이 1.5초, `transcribe` 가 2초 막히는 동안 메인 프레임 카운터 ≥ 50/초 ③ 전사 중 `request_unload()` 가 1프레임 안에 돌아오고 `abort()` 가 즉시 1회 불림, unload 는 전사 반환 뒤 실행 ④ 전사 중 `NOTIFICATION_APPLICATION_PAUSED` → 그 요청 `engine_error`(문구 TEXT_PAUSED), 언로드 1회 ⑤ `shutdown()` 이 전사 중에도 끝남. **검사기 자체 확인**: 시험이 가짜 브리지를 메인에서 일부러 한 번 직접 불러 `main_thread_calls` 검사가 FAIL 을 내는 `selfcheck FAIL-as-expected main_thread` 줄.
- **PA4-14 패치 표식**: 가짜 `version()` 에 `+abort-sched` 가 있으면 `stats().abort_patch == 1`, 없으면 0 이고 채점은 정상.
- **PA4-15 자동 끔**: 시간 초과 2연속 → pref `stt_phone_off == true`·`is_available_for` false·`unavailable_reason_for` 의 `err_code == "engine_error"`·문구 TEXT_PHONE_OFF. 시간 초과 → 성공 → 시간 초과 이면 꺼지지 않음. pref false 로 되돌리면 가능.
- **PA4-16 params 새 필드**: `beam:2` 파일이면 가짜 브리지가 받은 `options.beam == 2`, `final_map [[0,0],[50,70],[100,100]]` 이면 최종 점수 50 → 70. tiny 모델이면 `degraded` 에 `score_uncalibrated`·`stt_tiny_model`.
- **PA4-17 벤치**: `bench(wav, target, 5)` → `n=5`, `StudyLog`·`Store.progress` 직렬화 전후 같음, `Api.sent_count` 불변, `stats().runs` 5 증가.
- **PA4-18 실물 확인(선택, N0 필요)**: `Prep-Native; Run-GT local_stt_test pc -More @("--real-model=$MODEL_BASE", "--real-wav=$WAVS\coffee.wav")` → 추가 단언 `real: /score via phone, score ≥ 60, words ≥ 5` 통과. N0 를 안 했으면 이 항목은 "미검증"(합격 판정에 쓰지 않음).
- **PA4-19 상수 변이**: `Mutate 'godot\scripts\local\local_stt.gd' 'const STT_TIMEOUT_SEC := 12.0' 'const STT_TIMEOUT_SEC := 120.0'; Run-GT local_stt_test pc; Restore 'godot\scripts\local\local_stt.gd'` → `exit=1`(PA4-6 FAIL), 원복 뒤 `exit=0`.
- **금지**: `route.gd`·`api.gd`·`local_api.gd` 수정(X-5), 인식 글자·타깃 로그(X-7, `ZZ_TGT_4417` 0건), `HTTPRequest`, X-8.

### 5.5 PA5a / PA5b — 보정
- **PA5a-1** `& $PY -I -X utf8 -m unittest discover -s "$W\phone_src\tools" -p "test_calib_fit.py" *> "$T\pa5a_1.txt"; "exit=$LASTEXITCODE"` → `exit=0`, `Ran N tests`(N ≥ 20: 등위 회귀 단조성, `ok_prob` 탐색, 일치율 정의, 클립 단위 분할 누수 0, 합격선 판정, `final_map` 탐색 단조성, `map_p` 규칙 = §2.1 문장).
- **PA5a-2 작은 합성 세트**: `& $PY -I -X utf8 "$W\phone_src\tools\calib_make_set.py" --out "$T\set_small" --n-sentences 5 --voices 2 --seed 7; "exit=$LASTEXITCODE"` → `exit=0`, `$T\set_small\manifest.json` 의 클립 수 ≥ 5 × 변형 수, 각 sha256 이 파일과 같음. 같은 시드로 다시 돌리면 `manifest.json` 바이트 동일(추측: Kokoro 결정성 — 다르면 해시 목록만 같은지로 판정하고 보고).
- **PA5a-3 녹음 도구 건조 실행**: `& $PY -I -X utf8 "$W\phone_src\tools\calib_record.py" --out "$T\rec_dry" --dry-run *> "$T\pa5a_3.txt"; "exit=$LASTEXITCODE"` → `exit=0`, 출력에 §4.1 동의 문구 전체, 문장 30개, `$T\rec_dry` 에 파일 0개(폴더 없음 또는 비어 있음).
- **PA5a-4 PC·폰 쪽 실행(N0 필요)**: `Prep-Native`, 그다음 `calib_pc_run.py --set "$T\set_small" --out "$T\pc.json"`, `& $G --headless --path "$W\godot" -s res://tools/calib_phone.gd -- --model=$MODEL_BASE --set="$T\set_small" --out="$T\phone.json"` → 둘 다 종료 0, 두 JSON 의 클립 id 집합이 같다. 브리지 없이(`godot\whisper_bridge.gdextension` 이름을 잠시 바꿈) → `CALIB_PHONE_NO_ENGINE`, 종료 2, 그 뒤 이름 원복.
- **PA5a-5 일부러 틀린 입력**: `calib_fit.py --pc "$T\pc.json" --phone "$T\phone_shuffled.json" …`(시험 도우미가 클립 짝을 섞은 파일) → `CALIB_FAIL agreement` 종료 1, `--out-params` 파일 없음. 빈 JSON·한쪽만 있는 클립 → 종료 1.
- **PA5a-6 개인정보**: `calib_record.py` 소스에 로그 파일 쓰기 0(`Select-String -Path "$W\phone_src\tools\calib_record.py" -Pattern 'logging','\.log'` 0줄), 기본 출력 폴더 인자 필수(없으면 종료 2), X-3.
- **PA5b-1 데이터 규모(보고)**: 합성 클립 ≥ 1,000(문장 ≥ 200, 음성 ≥ 4, 틀린 단어 ≥ 250), 사용자 클립 ≥ 40(동의 기록 있음, 없으면 사용자 열 "미검증").
- **PA5b-2 지표**: `Get-Content "$W\phone_src\calib\report_v201.json" -Raw | ConvertFrom-Json` 의 값이 §2.4 합격선을 모두 만족하면 `fallback:"none"|"beam"`. 미달 항목이 있으면 그 이름·값과 폴백 단계(§2.4)를 보고하고 **오케스트레이터 판정**(자동 X 아님, 결정 7).
- **PA5b-3 형식**: `score_params.json` 이 §2.3 읽기 규칙을 모두 통과(`model_id == "whisper-base.en-q5_1"`, `calibrated:true`, `beam ∈ {1,2,3}`, `p_map` 단조·0과 1 포함). 확인: `Run-GT local_stt_test pc -More @("--params=$W\godot\data\score_params.json")` 의 `params: calibrated` 줄과 `score_uncalibrated` 없음.
- **PA5b-4 재현**: `calib_fit.py` 를 같은 입력·시드로 다시 돌린 `score_params.json` 이 저장된 파일과 바이트 동일.
- **PA5b-5 개인정보**: 저장소·보고에 사용자 WAV·전사 글 0(`git -C $W ls-files phone_src` 에 `.wav` 0, `report_v201.json` 에 영어 문장 0 — `Select-String -Pattern '[A-Za-z]{3,} [A-Za-z]{3,} [A-Za-z]{3,}'` 0줄), 녹음 폴더 삭제 여부를 사용자 선택대로 기록.
- **금지**: 서버 프로세스·포트(프로세스 안 호출만), `secrets.json` 접근, 네트워크, X-8. q8 모델 내려받기는 ★재승인 뒤 별도 지시.

### 5.6 PSA — 설정 연결·진단
- **PSA-1** `Run-GT phone_settings_asr_test` 4모드 + `pc`(PC 앱에서 묶음 없음 확인) → X-1, phone N ≥ 50. `Run-GT stt_diag_test phone`·`phonefont`·`phonedark` → X-1, N ≥ 40. `Run-GT settings_view_test pc -Api`·`phone -Api` 가 기준선 passed 이상.
- **PSA-2 문구 고정**: 시험이 노드 `SttSection` 의 제목 "음성 인식", `ScoreWhereSeg` 의 두 버튼 글 "폰에서 채점"·"PC에서 채점" 을 단언하고, `Route.text_for("engine_error")` 안에 "PC에서 채점" 이 들어 있음을 단언(P0 문구와 같은 글자).
- **PSA-3 버튼 흐름(C-14, `press:` ≥ 10)**: [PC에서 채점] → `Store.prefs.score_where == "pc"` 그리고 `Route.policy_for("POST","/score",{}).prefer == "pc"` → [폰에서 채점] → `"phone"`; `stt_phone_off=true` 상태에서 `SttPhoneOnBtn` → false; `SttDiagBtn` → 시트 열림 → `DiagRecBtn`(가짜 녹음) → `DiagBench20Btn`(가짜 LocalStt 의 `bench` 가 n=20 으로 불림) → `DiagCopyBtn` → `clipboard_hook` 이 받은 글의 첫 줄 `hoehwa-diag 1`.
- **PSA-4 진단 글 계약**: `report_text()` 가 §4.3 의 키를 전부 포함(시험이 키 목록 ≥ 40개를 하나씩 단언), 가짜 `stats()` 에 표식 `ZZ_TGT_4417` 을 넣은 필드가 있어도 복사 글·화면에 0건, `user_dir_internal` 이 0/1, 경로 문자 `/data/`·`C:\`·`user://` 0건. 화면 글 연속 5자리 숫자 0 + selfcheck 줄.
- **PSA-5 일부러 틀린 입력**: `score_where` 에 `"아무거나"`·`7`·`null` → 라디오 "폰에서 채점" 선택·크래시 0. `stt_script_override` 에 `has_method` 가 없는 스크립트·`null` → `stt=missing` 줄, 크래시 0. 배터리 `SpinBox` 범위 밖 입력 → 0~100 으로 잘림.
- **PSA-6 기능 현황**: `CapabilityPanel` 키 16개 그대로, `REASONS` 의 `model_missing`·`model_corrupt`·`engine_error` 가 §2.5 문구, `no_ai` 줄 변경 0(`git -C $W diff -U0 $BASE -- godot/scripts/ui/capability_panel.gd | Select-String 'no_ai'` 0줄 — 문맥 줄을 빼려고 `-U0`, 2026-11-19 보정).
- **PSA-7 상수 변이**: `Mutate 'godot\scripts\views\settings_view.gd' '["pc", "PC에서 채점"]' '["pc", "PC 채점"]'` → `phone_settings_asr_test phone` `exit=1`, 원복 뒤 0.
- **금지**: `stt_model_card.gd`·`model_store.gd`(PA3) 수정, `project.godot`, X-8.

### 5.7 PA7 — 빌드 통합
- **PA7-1 디버그 APK(네이티브 있음)**: `Prep-Native` 뒤
```powershell
$env:LOCALAPPDATA = '<오케스트레이터가 주는 Claude 가상 LocalAppData>'   # SDK·JDK 위치, 값 출력 금지
powershell -ExecutionPolicy Bypass -File "$W\packaging\build_android.ps1" -Version 2.0.1 -Debug -OutDir "$T\apk" *> "$T\pa7_1.txt"; "exit=$LASTEXITCODE"
Add-Type -A System.IO.Compression.FileSystem; ([IO.Compression.ZipFile]::OpenRead((Get-ChildItem "$T\apk\*.apk")[0].FullName)).Entries | Where-Object { $_.FullName -like 'lib/*' } | ForEach-Object FullName
```
  기대: `exit=0`, `lib/arm64-v8a/libwhisper_bridge.android.arm64.so` 와 Godot 기본 `lib/arm64-v8a/*.so` 만, 다른 ABI 폴더 0.
- **PA7-2 릴리스 빌드는 네이티브 필수**: `godot\bin\libwhisper_bridge.android.arm64.so` 를 `$T` 로 옮긴 상태에서 `build_android.ps1 -Version 2.0.1 -OutDir "$T\apk_rel"`(키가 없는 환경이면 서명 전 단계에서 네이티브 검사가 먼저 실패해야 함) → `exit=1`, 출력에 "폰 음성 인식 라이브러리가 없어요", APK 0개. `.so` 를 1바이트 바꾼 복사본 → 같은 실패. 같은 상태에서 `-Debug` → `exit=0` + 경고 줄. 검사 뒤 원래 `.so` 를 되돌린다.
- **PA7-3 APK 검사**: `powershell -ExecutionPolicy Bypass -File "$W\packaging\check_phone_native.ps1" -Apk (Get-ChildItem "$T\apk\*.apk")[0].FullName; "exit=$LASTEXITCODE"` → 마지막 줄 `PHONE_NATIVE_OK`, `exit=0`, 출력에 (a)~(g) 각 `OK` 줄, 크기 증가 값 출력.
- **PA7-4 검사기 자체 확인**: `check_phone_native.ps1 -SelfTest` → 정렬 안 된 `.so` 가짜 zip·`allowBackup=true` 조각·`.dll` 이 든 zip·NEEDED 에 `libc++_shared.so` → 각각 `SELFTEST FAIL-as-expected <항목>`, 정상 입력 `SELFTEST PASS`, 마지막 줄 `SELFTEST_OK`, `exit=0`.
- **PA7-5 PC 내보내기 제외**:
```powershell
& $G --headless --path "$W\godot" --export-pack "Windows Desktop" "$T\pc.pck" *> "$T\pa7_5.txt"
@(Select-String -Path "$T\pc.pck" -Pattern 'whisper_bridge' -SimpleMatch).Count
git -C $W diff $BASE -- godot/export_presets.cfg | Select-String '^[+-][^+-]'
```
  기대: `0`, 바뀐 줄은 preset.0 `exclude_filter` 의 `-`/`+` 한 쌍뿐. (`.godot/extension_list.cfg` 에 이름이 남으면 여기서 잡힌다 — 그때 워커는 해결책과 함께 보고.)
- **PA7-6 기준 크기**: PA7-3 출력의 증가분 ≤ 15,000,000 B, 전체 ≤ 100,000,000 B.
- **PA7-7 공개 검사·지문**: X-4, `git -C $W diff --name-only $BASE -- packaging/android_cert.sha256` 비어 있음, 출력·로그에 키스토어 비밀번호·`release.pass` 내용 0.
- **PA7-8 상수 변이**: `Mutate 'packaging\check_phone_native.ps1' '$MaxGrowBytes = 15000000' '$MaxGrowBytes = 1000000'` → PA7-3 `exit=1` + `PHONE_NATIVE_FAIL size`, 원복 뒤 `exit=0`.
- **PA7-9 (선택) 재빌드 일치**: `build.ps1 -Target android-arm64 -Out "$T\nb" -AndroidSdk <SDK>`(소스는 `copy_tree\native\_deps` 를 `$W\native\_deps` 로 복사) → sha256 비교 결과를 보고만 하고, 끝에 `git -C $W checkout -- native/whisper_bridge/BUILD_INFO.json`. 합격 판정에 쓰지 않는다.
- **금지**: 새 권한·`version/code`·키스토어 설정 변경(PA7-5 diff), 서명 비밀값 출력, X-8.

### 5.8 PWA — 말하기 화면 연결
- **PWA-1** `Run-GT phone_score_wiring_test` 4모드 + `pc`, `-Api` → X-1, N ≥ 80. `Run-GT self_rate_test pc -Api`·`phone -Api` 기준선 이상.
- **PWA-2 버튼 흐름(`press:` ≥ 12)**: 모델 없는 폰(가짜 `ModelStore` 상태 `missing`)에서 코스 말하기 단계(`CourseExerciseView`, 실제 데이터 또는 `course_mini`) 녹음 → 자가 평가 위젯 + `SelfRateModelBtn`("음성 인식 모델 받기 (약 60 MB)") → 누르면 `SttModelCard.open_sheet` 시트가 열림; 상태를 `ready` 로 바꾼 뒤(가짜 LocalStt 핸들러를 `LocalApi.handler_override["stt"]` 로) 같은 화면에서 다시 녹음 → `/score` 가 폰으로 가고(`LocalApi.served_count` +1, `Api.sent_count` 불변) 점수 화면 + `PhoneScoreBadge`. 쉐도잉·코스 플레이어 말하기 단계에서도 같은 확인 각 1회.
- **PWA-3** `ScorePanel`: `via=="phone"` 일 때만 배지, `via` 가 `"pc"`·없음·숫자·배열이면 배지 0, `degraded` 에 `score_uncalibrated` 면 " · 보정 전".
- **PWA-4** `need_ph`: `SpeakDrill.api_hook` 로 받은 본문에서 `source=="drill"`·`lang=="en"` 만 `need_ph:true`, `"shadow"`·`"course"`·레슨·일본어 `"drill"` 은 키 없음.
- **PWA-5** 문구: `model_missing`·`engine_missing`·그 밖 이유별로 `shadow_screen`·`song_sing_tab` 의 글이 §2.6 문구. 일본어 노래·일본어 화면 변경 0(`git -C $W diff $BASE -- godot/scripts/song/song_sing_tab.gd` 에서 일본어 분기 줄 변경 0, 시험 단언).
- **PWA-6 v200 호환**: `course_exercise_view_test`·`course_flow_test`·`course_stage_wiring_test` 4모드 `-Api`, `practice_test pc`(`--api` 없이), `phoneme_screen`/`shadow` 관련 기존 시험이 기준선 이상. `SpeakDrill` 공개 시그니처 diff 0:
```powershell
git -C $W diff $BASE -- godot/scripts/practice/speak_drill.gd | Select-String '^[-+](static )?func |^[-+]signal '
```
  기대: 출력 없음(새 비공개 함수 `_warm_stt` 같은 `_` 로 시작하는 것만 허용 — 있으면 `+func _` 로만 보임).
- **PWA-7 일부러 틀린 입력**: `via` 숫자·`degraded` 문자열·`ModelStore` 스크립트 없음(경로 훅) → 크래시 0, 버튼 없음.
- **PWA-8 상수 변이**: `Mutate 'godot\scripts\ui\score_panel.gd' 'const PHONE_BADGE := "폰 간이 채점"' 'const PHONE_BADGE := "폰 채점"'` → `phone_score_wiring_test phone` `exit=1`, 원복 뒤 0.
- **금지**: `course_*`·`lesson_view.gd`·`talk_view.gd`·일본어 파일 수정, X-8.

### 5.9 PZ — 문서
- **PZ-1** `git -C $W diff --stat $BASE` 가 `README.md`·`ROADMAP.md`·`INSTALL.md` 셋만.
- **PZ-2** `Select-String -Path "$W\README.md" -Pattern '약 60 MB','폰에서 채점','PC에서 채점','폰 간이 채점','2.0.2' -SimpleMatch` 각 ≥ 1, `ROADMAP.md` 에 `2.0.1` 과 "알려진" ≥ 1, `INSTALL.md` 에 "모델" ≥ 1.
- **PZ-3** 사실 대조: README 의 숫자(모델 크기·속도·보정 지표)가 `models.json`·`report_v201.json`·H3 결과와 같다(오케스트레이터가 직접 대조).
- **PZ-4** `Select-String -Path "$W\README.md","$W\ROADMAP.md","$W\INSTALL.md" -Pattern 'C:\\Users','secrets','token','FAKEKEY'` 새 줄 0, `WORKLOG.md`·버전 숫자 변경 0.

### 5.10 F1 — 소리 노트 [듣기]
- **F1-1** `Run-GT sound_notes_test` 4모드 + `pc`, `-Api` → X-1, phone N ≥ 70. `Run-GT course_home_test` 4모드 `-Api` 기준선 이상.
- **F1-2 규칙 = 실제 데이터**: 시험이 `CourseData`(릴리스 데이터)로 1~16주를 훑어 `speak_text != ""` 인 노트가 **정확히 31개, 전부 1주**, id `n0103`~`n0133` 이고 읽을 글이 다음 표와 같음을 단언: `ay bee see dee ee eff gee aitch eye jay kay el em en oh pee cue ar ess tee you vee double-you ex why zed` / `cat, bag, hat` / `bed, red, pen` / `big, sit` / `hot, dog` / `bus, cup`. 2주 `n0202`(`en:"b"`)는 `""`.
- **F1-3 버튼 흐름(`press:` ≥ 34)**: 코스 홈 1주 노드 → 주 시트에 `SoundNotesBtn` 보임(2주 시트에는 없음) → 누르면 시트 → `SoundPlay_n0103`~`SoundPlay_n0133` 31개를 차례로 눌러 `speak_hook` 이 `(<표의 글>, "en")` 으로 31번 불림. 각 버튼 높이 ≥ 44. 행 수 32(`n0102` 는 버튼 없는 행).
- **F1-4 일부러 틀린 입력**: 노트 `en` 이 `"A(ay)"`(공백 없음)·`"AB (ay)"`·`""`·숫자·`text_ko` 괄호 없음 → `""`, 크래시 0. `CourseData` 를 빈 폴더로 돌린 상태(`course_mini` 또는 `--course-dir` 훅) → 버튼 없음·크래시 0. selfcheck 줄 ≥ 1(일부러 32개를 기대하게 한 검사기가 FAIL).
- **F1-5 S12(권장 포함 시)**: 1주 시트 글에 `cn_` 으로 시작하는 줄 0, 장면 제목은 그대로.
- **F1-6 상수 변이**: `Mutate 'godot\scripts\core\course_sound_notes.gd' 'const RE_VOWEL := "^[aeiou]$"' 'const RE_VOWEL := "^[aeio]$"'` → `sound_notes_test pc` `exit=1`(31 → 30), 원복 뒤 0.
- **금지**: 원고·`godot/data/course/*` 수정(F2 소유), `Tts` 수정, X-8.

### 5.11 F2 — 원고 + 재빌드
- **F2-1 린터**: `& $PY -I -X utf8 "$W\course_src\tools\check_course.py" --in "$W\course_src\en" --weeks 1-16 --strict *> "$T\f2_1.txt"; "exit=$LASTEXITCODE"; Get-Content "$T\f2_1.txt" -Tail 1` → `exit=0`, 마지막 줄 `CHECK_OK weeks=1-16 words=517 sentences=991 dialogue_lines=104 violations=0`(지금 main 에서 설계자가 실행해 얻은 줄. 개수는 F2 뒤에도 같아야 한다).
- **F2-2 재빌드 = 커밋된 데이터**:
```powershell
& $PY -I -X utf8 "$W\course_src\tools\build_course.py" --in "$W\course_src\en" --out "$T\build" --weeks 1-16; "exit=$LASTEXITCODE"
Get-ChildItem "$T\build" -File | ForEach-Object { "{0} {1}" -f $_.Name, ((Get-FileHash $_.FullName).Hash -eq (Get-FileHash "$W\godot\data\course\$($_.Name)").Hash) }
```
  기대: `exit=0`, 7개 파일 모든 줄 `True`(main `40df5df` 에서 같은 방법으로 7개 모두 `True` 를 설계자가 확인했다).
- **F2-3 바뀐 항목만**: 시험 도우미(scratch 의 파이썬 한 줄 스크립트)가 `git show ${BASE}:godot/data/course/<파일>` 과 지금 파일을 id 단위로 비교 → 바뀐 id 집합 == {`w0164`, `s0011`, `s0295`, `p_price_say`}(오케스트레이터가 원문 지적으로 다른 항목을 지시했으면 그 집합).
```powershell
@'
import json, subprocess, sys
base, w = sys.argv[1], sys.argv[2]
def load(txt, key):
    d = json.loads(txt); return {str(x.get("id", x.get("w"))): x for x in d[key]}
out = set()
for f, key in [("en_lexicon.json","words"),("en_sentences.json","sentences"),("en_patterns.json","patterns"),("en_weeks.json","weeks"),("en_dialogues.json","dialogues")]:
    old = subprocess.run(["git","-C",w,"show",base+":godot/data/course/"+f],capture_output=True).stdout.decode("utf-8")
    new = open(w+"/godot/data/course/"+f,encoding="utf-8").read()
    try: a, b = load(old, key), load(new, key)
    except Exception as e: print("SKIP", f, type(e).__name__); continue
    out |= {k for k in set(a)|set(b) if a.get(k) != b.get(k)}
print("CHANGED", " ".join(sorted(out)))
'@ | Set-Content -Encoding UTF8 "$T\f2_diff.py"
& $PY -I -X utf8 "$T\f2_diff.py" $BASE $W
```
  기대: `CHANGED p_price_say s0011 s0295 w0164`, `SKIP` 줄 0. (주 기록은 `id` 대신 `w` 를 키로 쓴다. 설계자가 같은 스크립트를 main 에서 `HEAD` 와 비교해 빈 `CHANGED` 를, `s0011` 의 `ko` 만 바꾼 복사본에서 `s0011` 이 나오는 것을 확인했다.)
- **F2-4 개수 불변**: `course_manifest.json` 의 `records`(16, 517, 52, 991, 4, 16)가 기준과 같다.
- **F2-5 앱 시험**: `Run-GT course_data_real_test pc`·`phone`, `Run-GT course_guard_all_test pc`·`phone` → X-1. `& $PY -X utf8 -m unittest discover -s "$W\course_src\tools" -p "test_*.py"` → `OK`.
- **F2-6 일부러 틀린 입력(C-17)**: `$W\course_src\en` 을 `$T\bad_src` 로 복사하고 `s0011` 의 `en` 을 `"Bye-bye 2."` 로 바꿔 린터 → `CHECK_FAIL NUM_SAY` 줄·`exit=1`. `$T\build` 의 `en_sentences.json` 1바이트를 바꾼 복사 폴더로 `Run-GT course_data_real_test pc -More @("--course-dir=$T\build_bad")` → `exit=1`.
- **F2-7** `p_price_say.grammar_ko` 줄 수 3(2~4), `numbers_en.py`·`lexicon_guard_test` 변경 0.
- **F2-8 콘텐츠 재검수(오케스트레이터)**: 바뀐 4항목 Gemini Hydrogen 판정 C 0·M 0.
- **금지**: `course_src/tools/*`·노트·다른 항목 수정, X-8.

### 5.12 F3 — 저장 실패 제목
- **F3-1** `Run-GT course_flow_test` 4모드 `-Api` → X-1, passed ≥ 기준선 + 2.
- **F3-2** 출력에 `save fail` 흐름의 `ErrorTitle` 단언 줄(`기록을 저장하지 못했어요`)과 build 오류 흐름의 `문제를 열 수 없어요` 단언 줄이 PASS.
- **F3-3** `git -C $W diff $BASE -- godot/tests/course_flow_test.gd | Select-String '^-\s*ok\('` → 0줄(기존 단언 삭제 0).
- **F3-4 상수 변이**: `Mutate 'godot\scripts\practice\course_player.gd' 'const TITLE_SAVE := "기록을 저장하지 못했어요"' 'const TITLE_SAVE := "문제를 열 수 없어요"'` → `course_flow_test pc` `exit=1`, 원복 뒤 0.
- **금지**: `_show_error` 의 다른 호출 동작 변경, X-8.

---

## 6. 통합 시험 T(2.0.1)와 공개 체크리스트

### 6.1 통합 시험 T (4파, 오케스트레이터가 main 에서 직접 실행)
- **T-0** 버전: `godot/project.godot` `config/version="2.0.1"`, `export_presets.cfg` `version/code=20001`(오케스트레이터 커밋).
- **T-1 새 시험 전부**(PC·`phone`, 화면은 `phonefont`·`phonedark` 도): `score_parity_test`, `model_store_test`·`stt_model_card_test`(`run_model_tests.ps1`), `local_stt_test`, `phone_settings_asr_test`, `stt_diag_test`, `phone_score_wiring_test`, `sound_notes_test`, `course_flow_test`, `route_test`. 전부 X-1.
- **T-2 도구**: `test_make_score_golden.py`·`make_score_golden.py --check`·`test_calib_fit.py`·`course_src\tools` unittest·`check_course.py --strict`(CHECK_OK)·F2-2 재빌드 일치.
- **T-3 네이티브(N0 뒤)**: `Run-GT native_bridge_test pc -More @("--model=$MODEL_BASE", "--wav-dir=$WAVS")` → `== native_bridge: N passed, 0 failed ==`, N ≥ 106. PA4-18 실물 확인 통과.
- **T-4 회귀**: `$S\w_t9\run_godot.ps1 -Project 'D:\Ai\언어\app\godot' -Tag v201` 전체(2.0.0 T9 의 130회) → `results_v201.tsv` 전부 0 failed·SCRIPT ERROR 0·TEST_GUARD 1. 일본어 시험은 **변경 0**(`git diff v2.0.0 -- godot/tests/*ja*` 비어 있음). `flow_test` 는 8770 필요로 기존과 같이 미검증.
- **T-5 빌드**: 정식 키 시험 APK(`build_android.ps1 -Version 2.0.1`, 비 `-Debug`, scratch APPDATA·가상 LocalAppData, 메모리 `release-key-location`) → 기존 검증(지문 = `android_cert.sha256`, 권한 3개, versionCode 20001) + `check_phone_native.ps1 -Apk` `PHONE_NATIVE_OK` + `-SelfTest` `SELFTEST_OK` + PA7-5(PC pck `whisper_bridge` 0).
- **T-6 공개 검사**: X-2, X-3, X-4, `git ls-files` 직접 훑기(아래 6.2).
- **T-7 소유권**: 마지막 파 시작 때 `only=PZ` 로 OK 를 기록(병합 뒤에는 `new` 줄이 FAIL 하는 것이 정상이므로 병합 뒤 재실행은 하지 않는다).

### 6.2 공개 전 파일 목록 확인 (CLAUDE.md 체크리스트)
```powershell
git -C $R ls-files | Select-String -Pattern '(\.so|\.dll|\.bin|\.gguf|\.onnx|\.wav|\.mp3|\.ogg|\.m4a|\.apk|\.keystore|\.jks|release\.pass|secrets|auth\.json|\.gdextension)$'
git -C $R ls-files phone_src godot/data | Select-String -Pattern 'calib_user|report_v201'
```
- 기대: 첫 줄은 `godot/tests/fixtures/song/tone_8s.mp3` 하나, 둘째는 `phone_src/calib/report_v201.json` 하나(숫자만인지 PA5b-5 로 확인됨).
- APK 안: `ggml-*.bin` 0, `.dll` 0, `lib/arm64-v8a/libwhisper_bridge.android.arm64.so` 1(PA7-3 (f)).
- 업데이트 zip(PC): `whisper_bridge` 0(`Select-String` 로 zip 안 `.pck` 검사는 `build_dist.ps1` 산출물에 대해 오케스트레이터가 PA7-5 와 같은 방법으로).

### 6.3 `models-1` 릴리스·미러·링크 (오케스트레이터, ★네트워크는 이 단계에서만)
- **순서**: T 통과 → `models-1` 생성 → 실기 H2(GitHub 첫 주소로 받는지 확인) → 2.0.1 공개. (`docs/v201_plan.md` §2.1 은 "실기 → models-1" 순서지만, 실기에서 첫 주소를 시험하려면 먼저 올려야 한다. 모델은 MIT 공개 파일이라 먼저 올려도 위험이 작다. §8 O-1.)
- **생성(업데이터 보호)**: `gh release create models-1 "$MODEL_BASE" "$MODEL_TINY" --repo Whahan/hoehwa-practice --title "models-1 (음성 인식 모델)" --notes-file "$S\w_orch_v201\notes_models1.md" --prerelease --latest=false`. 노트에 출처(whisper.cpp ggml 변환, MIT)와 두 sha256.
- **확인 명령**:
```powershell
gh api repos/Whahan/hoehwa-practice/releases/latest --jq .tag_name          # 기대: v2.0.0 (models-1 이 아님)
gh release view models-1 --repo Whahan/hoehwa-practice --json assets --jq '.assets[] | .name + " " + (.size|tostring)'
foreach ($f in 'ggml-base.en-q5_1.bin','ggml-tiny.en-q5_1.bin') {
  foreach ($u in "https://github.com/Whahan/hoehwa-practice/releases/download/models-1/$f", "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/$f") {
    $dst = "$S\w_orch_v201\dl\$([guid]::NewGuid().ToString('N'))_$f"
    curl.exe -sSL -o $dst $u; "{0} {1}" -f $u, (Get-FileHash $dst -Algorithm SHA256).Hash.ToLower()
    curl.exe -sSIL $u | Select-String -Pattern '^location:' | ForEach-Object { ([uri](($_ -split ' ',2)[1].Trim())).Host }
  }
}
```
  기대: 자산 크기 59721011·32166155, 네 주소 모두 §2.2 sha256, 리다이렉트 호스트가 전부 `models.json` `hosts` 접미사 안. **HF sha 가 다르면** 공개 전에 `models.json` 에서 HF 주소를 빼는 수정(PA3 소유 파일, 오케스트레이터가 별도 커밋·reviewer 확인)을 한다. 내려받은 파일은 확인 뒤 지운다.
- **공개 뒤**: 릴리스 페이지 열기, APK·update zip·setup 내려받아 `SHA256SUMS` 일치, `releases/latest` = `v2.0.1`, `latest/download` 200, H2 에서 받은 APK 와 공개 APK sha256 이 같음. 문제가 생겨도 릴리스·태그를 지우지 않고 2.0.2(또는 `models-2`)로 고친다.
- 릴리스 노트(오케스트레이터, `$S\w_orch_v201\notes_2.0.1.md`): "설정 > 음성 인식에서 모델(약 60 MB)을 받으면 폰에서 바로 채점", "폰 간이 채점" 한계, 보정 지표, "폰 AI 키 설정은 2.0.2 예정"(결정 1), 1주 소리 듣기, 원고 손질.

---

## 7. 위험 요소와 대안, 일부러 틀린 입력

### 7.1 위험 (2.0.1 에서 새로 생기거나 바뀐 것. 나머지는 §8.1(폰) R-P1~R-P22 그대로)
| # | 위험 | 영향 | 대응·대안 |
|---|---|---|---|
| V1 | PA5 보정 미달(특히 틀린 발음 통과) | 채점 신뢰 | 결정 7 폴백(§2.4). 미달 지표를 숫자로 공개, "폰 간이 채점" 유지 |
| V2 | 배터리·온도 API 없음(S9) | H3 일부 미측정 | 배터리 %는 사용자 입력, 온도는 미검증으로 정직하게 표기. 대안: JavaClassWrapper 로 배터리 인텐트 읽기(추측, 2.0.2 이후 선택 스파이크) |
| V3 | GitHub/HF 리다이렉트 호스트·형식 변경 | 받기 실패 | 접미사 허용, 상대 `Location`, 리다이렉트 5회, 두 주소, §6.3 에서 실제 호스트 확인. 바뀌면 `models.json` 갱신 패치 |
| V4 | `models-1` 이 `latest` 가 됨 / 비안정 채널 업데이터가 고름(S11) | PC 업데이트 실패 | `--prerelease --latest=false` + 확인 명령. 비안정 채널은 기존 코드 한계(**기존 문제**): `update.ps1` 이 태그 `^v\d` 만 고르게 하는 수정을 2.0.2 후보로 |
| V5 | 시험 APK 서명이 디버그 키 | 덮어쓰기 불가 → 기록 삭제 | 정식 키 서명(§4.2), 같은 APK 를 공개 |
| V6 | PC 내보내기에 `extension_list.cfg` 가 남음(추측) | PC 앱 시작 오류 | PA7-5 가 잡는다. 잡히면 대안: Windows 내보내기 전에 `.gdextension` 을 잠시 옮기는 단계를 `build_dist.ps1` 대신 오케스트레이터 절차로(공개 스크립트 무변경) |
| V7 | 릴리스 빌드에 `.so` 가 빠짐 | 폰 채점 없음 | 릴리스 빌드 네이티브 필수(§2.7), `-VerifyApk` 에서도 검사 |
| V8 | 워커가 `build.ps1` 을 돌려 `BUILD_INFO.json` 이 바뀜 | 소유 위반·sha 불일치 | N0 는 복사만, PA7-9 는 원복 필수, X-5 에 `native` 포함 |
| V9 | 폰 시스템 TTS 의 글자 이름 읽기가 Kokoro 샘플과 다름 | 1주 소리 학습 혼란 | H4b, `SPEAK_OVERRIDE`, 5개 이상 이상하면 F1 이월(결정 2) |
| V10 | 재빌드가 의도보다 많은 항목을 바꿈 | 진도·카드 변화 | F2-3 id 단위 비교, F2-4 개수 불변 |
| V11 | 엔진 스레드 큐 설계 오류(교착·메인 차단) | 앱 멈춤 | PA4-13 의 메인 스레드 호출 0·프레임 카운터·`shutdown()`, H3 60회 연속 |
| V12 | 첫 `--import` 접근 위반(4.6.3 알려진 현상) | 시험 오판 | import 두 번(N0), 시험 판정은 두 번째 뒤 |
| V13 | M3 원문 지적이 없음 | 엉뚱한 수정 | F2 는 오케스트레이터가 원문을 붙인 지시로만 시작, Gemini 재검수 |
| V14 | 같은 versionCode 재설치 거부(추측) | 실기 APK ≠ 공개 APK | 실기 APK 를 그대로 공개(재빌드하지 않음) |
| V15 | 녹음 개인정보 | 프라이버시 | 동의 문구, scratch 한정, 숫자만 보고, 기본 삭제(PA5a-6, PA5b-5) |
| V16 | 정적 핸들러 `LocalStt.handle` 안의 `await`(추측: Godot 4.6 정적 함수 코루틴 동작) | 컴파일·실행 오류 | PA4-1 이 바로 드러낸다. 막히면 `handle` 은 `SttEngine.get_or_create().serve(...)`(인스턴스 코루틴)를 `await` 해 돌려주는 한 줄로 줄인다(`LocalApi.dispatch` 는 이미 `await script.call("handle", …)`) |

### 7.2 일부러 틀린 입력으로 확인할 실패 시나리오 (2.0.1 추가분)
| # | 입력 | 기대 | 담당 조건 |
|---|---|---|---|
| G1 | 황금 값 1개 변경 / `OK_PROB` 0.40 | 시험 FAIL | PA2-10, PA2-11 |
| G2 | `p_map` 비단조·x 중복·점 1개 | `valid_p_map` false → 항등 + `score_uncalibrated` | PA2-9, PA4-3 |
| G3 | 리다이렉트 6번 / 상대 Location / 허용 밖 호스트 / `http://` | `dl_redirect` / 성공 / `dl_host` 요청 0 / 거절 | PA3-9 |
| G4 | 매니페스트 깨진 JSON·sha 불일치 | `bad_manifest` / `corrupt` | PA3-11, PA3-4 |
| G5 | 공간 10 MB / 알 수 없음 | 요청 0건 `no_space` / 확인 시트 | PA3-5 |
| G6 | 전사 중 언로드·일시정지·종료 | 메인 비차단, abort 즉시, 언로드는 뒤에 | PA4-13 |
| G7 | 시간 초과 2연속 | 폰 채점 자동 끔, 다시 켜기 | PA4-15, PSA-3 |
| G8 | `score_params` 9종 불량 | 항등 + `score_uncalibrated` | PA4-3 |
| G9 | 브리지 버전에 `+abort-sched` 없음 | `abort_patch=0`, 채점 정상 | PA4-14 |
| G10 | 보정 데이터 짝 섞기·빈 입력 | `CALIB_FAIL`, 파일 안 씀 | PA5a-5 |
| G11 | 진단 stats 에 인식 글 표식 | 복사 글·화면 0건 | PSA-4 |
| G12 | `score_where` 이상값 | "폰에서 채점" 으로 취급 | PSA-5 |
| G13 | 릴리스 빌드에 `.so` 없음·1바이트 변경 | 종료 1, APK 없음 | PA7-2 |
| G14 | 정렬 안 된 `.so`·`allowBackup=true`·`.dll` 포함·`libc++_shared` | 검사 FAIL | PA7-4 |
| G15 | 노트 `en` 모양이 다름·데이터 없음 | 버튼 없음, 크래시 0 | F1-4 |
| G16 | 원고에 숫자 넣기 / 데이터 1바이트 변경 | `CHECK_FAIL NUM_SAY` / 해시 실패 | F2-6 |
| G17 | 저장 실패 제목 상수를 되돌림 | 시험 FAIL | F3-4 |
| G18 | 소유권: 겹침·v200 after 불일치·없는 mod·이미 있는 new | `FAIL` 줄, 종료 1 | X-9, §3.3 |

---

## 8. 오케스트레이터가 정할 것
| # | 항목 | 이 문서의 기본(추천) |
|---|---|---|
| O-1 | `models-1` 을 실기 H2 **전**에 올릴지(기획은 실기 뒤) | 전에 올린다(§6.3). 아니면 H2 는 HF 미러만 시험되고 GitHub 주소는 공개 뒤 첫 사용자 때 처음 쓰인다 |
| O-2 | M3 3건 원문 지적 전달과 최종 문구 | 원문을 F2 지시에 붙인다. 원문이 없으면 §2.10 추천안 + Gemini 재검수 |
| O-3 | 11주 설명을 F3 대신 F2 에서 처리(재빌드 파일 겹침 0) | F2 |
| O-4 | F1 에 기존 문제 S12(`cn_` id 줄 숨기기) 포함 | 포함(한 줄) |
| O-5 | 소리 노트 [듣기] 를 2~4주(자음·강세, 36건)로 넓힐지 | 2.0.1 은 1주만(결정 2 범위). 2.0.2 후보 |
| O-6 | PA5b 폴백 ② `base.en-q8_0` 시도 시 ★사용자 재승인(82 MB 내려받기)·`models.json`·`models-1` 변경 | 필요해지면 그때 결정 |
| O-7 | 시험 APK 를 정식 키로 서명해 사용자 폰에 덮어 설치(versionCode 20001) | 예(§4.2) |
| O-8 | 진단 시트를 공개 APK 에도 남길지 | 남긴다(숫자만 복사, 설정 깊은 곳). 빼려면 PSA 에 플래그 |
| O-9 | `update.ps1` 비안정 채널 태그 필터(V4, 기존 문제) | 2.0.2 |
| O-10 | 1파 6개 동시 실행 여부(검토 부하) | 동시. 부담이면 PA2·PA3·PA7 먼저, F1~F3 뒤 |

### 8.1 확정한 결정 (2026-11-19, 오케스트레이터)
- **D-1 단어 시각 정리 규칙**(§2.3 6) 의 "시각 정리"; PA4 의 GDScript 와 PA5a/PA5b 의 파이썬이 **같은 규칙**을 쓴다. 입력 `words`(전사 순서), `clip_sec`(WAV 길이, 초):
  1) 각 단어 `start`·`end` 가 유한수가 아니면 0. 2) `start`·`end` 를 [0, clip_sec] 로 자른다. 3) 앞 단어부터 차례로 `start = max(start, 앞 단어 start)` (단조). 4) `end = max(end, start)`. 5) 다음 단어가 있으면 `end = min(end, 다음 단어의 정리된 start)`, 단 `end < start` 가 되면 `end = start`. 6) 순서·개수·`w`·`p` 는 바꾸지 않는다. 결과 시각은 소수 3자리 반올림 없이 그대로 쓴다.
  - 같은 입력에 대한 기대값 사례를 PA5a 시험(`test_calib_fit.py`)에 두고, PA4 는 같은 사례를 GDScript 시험에 복사해 일치를 확인한다.
- **D-2** PA5a `--fit-final` 의 점수 MAE·p90 자동 면제(`WAIVED`)는 하지 않는다. 미달은 `CALIB_FAIL` 과 숫자로 보고하고, 공개 여부는 §2.4 대로 오케스트레이터가 정한다.
- **D-3** PA5b 합성 음성 4종 조건: 지금 PC 에는 `af_heart` 1종뿐. PA5b 시작 전에 추가 음성 내려받기를 사용자에게 승인받거나, 승인이 없으면 1종 + 사용자 녹음으로 진행하고 보고서에 적는다. → 2026-11-21 사용자 승인으로 4종(af_heart·af_bella·am_adam·am_michael).
- **D-4 합격선 "틀린 70+" 변경(2026-11-22, 사용자 결정)**: PC `score_en` 자체가 낱말 하나 틀린 클립의 대부분에 70 이상을 준다(합성 0.97, 사용자 0.67). 그래서 "틀린 70+ ≤ 0.10" 은 폰 보정으로 닿을 수 없는 조건이다. 보정의 목표는 "폰 점수가 PC 점수를 따라간다" 이므로 이 항목을 **|폰 틀린 70+ 비율 − PC 틀린 70+ 비율| ≤ 0.10**(보류 30%, 합성·사용자 합산)으로 바꾼다. `final_map`(폴백 ③)은 사용자 정상 발음의 약 62% 를 69점으로 누르므로 쓰지 않는다. 채택 구성은 beam 1 + `p_map`·`ok_prob`(일반 모드). 사용자 표본이 작다(42클립, 보류 12)는 점은 report·릴리스 노트에 숫자로 적는다.
- **D-5 사용자 세트 id 충돌**: 두 번 나눠 녹음하면 클립 id 가 겹친다(`u01_clean`). 2.0.1 은 둘째 세트의 PC·폰 JSON 사본에만 `s8_` 접두사를 붙여 맞춘다. 녹음 도구가 세트마다 접두사를 달도록 고치는 일은 2.0.2 후보.
