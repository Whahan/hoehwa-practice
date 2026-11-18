# v2.0 추가 설계: 폰이 주인공 — 폰 안 음성 인식(P-ASR)과 폰 직접 AI 연결(P-AI)

- 작성: designer (설계만. 코드·설정 수정 없음) / 기준 커밋: `b32cd84` (main, 2026-11-17)
- 상태: 초안. 오케스트레이터 확정 대기(§9).
- 전제(사용자 결정, 2026-11-17 "추천대로"): ① 폰 앱이 주인공, PC 앱은 지금 기능 그대로(선택). 새 기능은 폰 기준으로 먼저. ② 폰 안 음성 인식·발음 채점은 whisper.cpp GDExtension(arm64), 영어 모델 약 60 MB는 첫 실행 뒤 내려받기, 오프라인·녹음은 폰 밖으로 안 나감. 일본어 모델은 범위 밖. ③ 사용자가 AI 키를 폰에 한 번 넣으면 폰이 AI 서비스에 직접 요청(대화·대화 중 교정·일기 교정·2.1의 수준 맞춤 대화). ④ 배포는 GitHub 릴리스 APK, 구글 플레이는 나중.
- 상위 문서(바꾸지 않고 덧붙인다): `docs\v200_design.md`(코스, 확정, 지금 1파 K1·K0·E1·E2 진행 중), `docs\phone_standalone_design.md`(폰 단독 1~3단계: D1~D10, §7 단계 개요).
- 표기: **(추측)** = 코드·문서·실행으로 확인하지 못한 가정. 표기 없는 것은 읽거나 실행해서 확인한 사실. **(새)** = 이번에 새로 만드는 파일·함수·필드·설정. **★** = 실행 전에 사용자 확인이 필요한 항목. 경로는 저장소 루트 `D:\Ai\언어\app` 기준.
- 요청 항목 ↔ 절: ① P-ASR = §1 ② P-AI = §2 ③ 폰 우선 화면 점검 = §3 ④ 출시 계획 통합 = §4 ⑤ 작업 분할·소유권·O/X = §5, §6, §7 ⑥ 위험·사용자 질문 = §8, §9. 목표·범위·사실·핵심 결정은 §0.

## 0. 목표·범위·사실·핵심 결정

### 0.1 읽은 것 / 실행한 것 / 확인하지 못한 것
- **읽은 것(코드)**: `docs\phone_standalone_design.md` 전체, `docs\v200_design.md` §0·§3~§7·§10~§15, `docs\v170_design.md`의 일기·`/fix` private 부분, `backend\server.py`(`transcribe`·`decode_audio_b64`·`score_en`·`fluency_score`·`en_words`·`align_seq`·`rules_text`·`run_chat`·`_llm_correct`·`run_feedback`·`/fix`·`fix_private`·`/stt`·`/score`·`/chat`·`/health`), `backend\llm_api.py`·`llm_opencode.py`·`llm_common.py`, `backend\missions.py`(`judge_goals`), `godot\scripts\autoload\{route,local_api,api,backend,recorder}.gd`, `godot\scripts\ui\{ai_connect_sheet,capability_panel,self_rate_panel}.gd`, `godot\scripts\practice\{speak_drill,diary_screen,mission_screen,shadow_screen}.gd`, `godot\scripts\views\{talk_view,settings_view}.gd`, `godot\scripts\core\{home_ai,text_sim,wav_util}.gd`, `godot\scripts\main.gd`, `godot\scripts\sync\sync_doc.gd`(`SHARED_PREFS`), `godot\export_presets.cfg`, `packaging\build_android.ps1`·`publish_release.ps1`, `.gitignore`, `README.md`, `REVIEW.md`, `WORKLOG.md`.
- **실행한 것(읽기 전용)**: 이 PC 도구 현황 조회(§1.2 표), `backend\.venv` 의 `faster_whisper\transcribe.py` 에서 단어 확률 계산 확인(1748행: 토큰 확률의 `np.mean`), 두 `curriculum.json` 해시 비교(같음), `git worktree list`·`git status`(깨끗). 아무것도 내려받거나 설치하지 않았다. 비밀 파일(`backend\secrets.json`, 키스토어, 사용자 폴더)은 열지 않았다.
- **웹에서 확인한 것**(출처는 §10): OpenCode Zen·Go 문서, Gemini API 문서(OpenAI 호환·가격·지역), DeepSeek 가격·개인정보 방침, OpenRouter 한도, whisper.cpp README·`whisper.h`·Hugging Face 모델 목록, godot-cpp README·`tools\android.py`, Godot 4.6 브랜치 `export_plugin.cpp`, Android 16 KB 페이지 문서, Godot 클래스 문서(`DirAccess`·`OS`·`JavaClassWrapper`), GitHub 릴리스 한도.
- **확인하지 못한 것(실측·사용자 몫)**: 사용자 폰의 기종·안드로이드 버전·RAM·남은 공간·16 KB 페이지 여부, whisper.cpp 가 그 폰에서 내는 속도·메모리·발열, 4.6.3 에서 비-Gradle APK 안 `.so` 로딩(소스는 확인, 실행은 G1), NDK r28b 와 godot-cpp 의 CMake 길이 실제로 되는지, OpenCode Zen 키가 `https://opencode.ai/inference/v1` 로 직접 유료 모델을 부르는지(C0), Gemini 무료 등급의 분·일 한도 숫자(이번 문서 읽기에서 못 읽음), DeepSeek·OpenRouter API 의 데이터 정책, GitHub 릴리스 자산 리다이렉트 호스트 이름, `OS.get_memory_info()`·`OS.get_unique_id()` 의 안드로이드 동작, JavaClassWrapper 로 Android Keystore 호출이 되는지.

### 0.2 목표와 범위
- **목표**: 사용자가 캐나다에서 **폰만** 들고 18개월 코스(하루 45분)를 계속한다. 말하기 채점은 폰 안에서 오프라인으로, AI 대화·교정·일기는 폰이 AI 서비스에 직접 요청(인터넷 필요)한다. PC 앱은 변하지 않는다.
- **하지 않을 것**
  - 일본어 음성 인식 모델·일본어 채점·일본어 AI 대화(폰). 일본어는 지금처럼 PC 연결 시에만.
  - 음소 단위 교정·억양 그래프의 폰 이식(PC 전용 유지). 온디바이스 LLM.
  - AI 레슨(`POST /lesson` `source:"ai"`)·읽기 문맥 뜻풀이(`/reading/gloss` 의 AI 부분)·노래 해석(`/song/*`)·`/missions/judge` 외 AI 기능의 폰 이식(범위 밖, PC 연결 시).
  - Gradle 커스텀 빌드, Android 플러그인(AAR), Android Keystore 플러그인, 새 autoload, 새 안드로이드 권한(`export_presets.cfg` 의 권한 3개 그대로), `project.godot` 변경.
  - 서버(`backend\`) 코드 변경 0, `lan.py`·동기화 스키마(`SyncDoc.SCHEMA`) 변경 0. 서버는 읽기만 하고 시험 도구가 그 함수를 호출만 한다.
  - 앱이 운영하는 서버·계정, 앱 안에 공용 AI 키 내장, PC 앱에 폰 AI 키 저장.
  - 구글 플레이 등록(나중). 단 16 KB 페이지 호환은 빌드 점검으로 확인만 한다(§1.2).
  - 버전 올리기·릴리스·GitHub 모델 릴리스 업로드(오케스트레이터).

### 0.3 지금 구조에서 알게 된 사실 (설계의 근거)
| # | 사실 | 위치 |
|---|---|---|
| F-P1 | 폰 단독 1단계(1.3)는 이미 들어 있다. `Route`·`LocalApi`·핸들러 `lessons/practice/missions/reading`·`SystemTts`. 핸들러 표 `LocalApi.HANDLERS` 에 `"stt"`·`"ai"` 경로는 이미 적혀 있으나 파일(`local_stt.gd`·`local_ai.gd`)이 없어 지금은 `needs_pc` 로 떨어진다 | `godot\scripts\autoload\local_api.gd` 20~28행, `godot\scripts\local\` |
| F-P2 | 1.5.0 "AI 연결하기"는 **PC 전용**이다. 사용자가 opencode.ai 에서 키를 복사해 PC 앱에 붙여 넣으면 PC 백엔드가 OpenCode 에 건네고 OpenCode 가 자기 `auth.json` 에 저장한다. 폰은 시트를 열지 않고 문장만 보인다 | `godot\scripts\ui\ai_connect_sheet.gd` 1~14행·80~90행, `backend\llm_opencode.py` 머리글 |
| F-P3 | `Route.ERR_TEXT["no_ai"]` 는 "설정 > AI 연결에 본인 API 키를 넣으면 쓸 수 있어요" 라고 적지만 **폰에 그 설정이 아직 없다**(안내가 사실과 다르다) | `godot\scripts\autoload\route.gd` 76행, `godot\scripts\ui\capability_panel.gd` 43행 |
| F-P4 | 서버의 "API 키 엔진"은 `llm_api.py`(OpenAI 호환 `POST {base}/chat/completions`, 프리셋 4개, 오류 분류 `auth/limit/overload`, JSON 모드 거부 시 재시도). 키는 `backend\secrets.json` | `backend\llm_api.py` |
| F-P5 | 무료 DeepSeek(OpenCode)는 OpenCode 프로그램 밖에서 거부된다는 **이 저장소의 과거 실측**(`llm_api.py` 프리셋 주석·`llm_opencode.py` 머리글)이 있고, Zen 문서(2026-11-17 확인)도 "Free-tier chat models require OpenCode; use paid models or Go from other clients" 라고 적는다 | `backend\llm_api.py` 31~32행, §2.1 |
| F-P6 | PC 채점은 faster-whisper `small`(`beam_size=5`, `word_timestamps=True`, `vad_filter=True`)의 단어 `{w,p,start,end}` 를 `score_en` 이 `OK_PROB=0.45` 로 판정하고 `0.6·정확도+0.25·또렷함+0.15·유창성` 으로 합친다. faster-whisper 의 단어 확률은 **토큰 확률의 평균**이다(소스 1748행) | `backend\server.py` 345~368행·1231행·1261행, `...\faster_whisper\transcribe.py` |
| F-P7 | 폰은 이미 `Recorder`(Godot 마이크)로 녹음하고 `SpeakDrill` 이 base64 WAV 를 `/score` 로 보낸다. 최대 30초, 무음 기준 `SILENT_PEAK=0.003` 이 서버(`np.max(np.abs(audio)) < 0.003`)와 같다. 서버는 60초까지 받는다 | `godot\scripts\autoload\recorder.gd` 21~23행, `godot\scripts\practice\speak_drill.gd` 389행, `backend\server.py` 260행·349행 |
| F-P8 | 일기 화면은 AI 가능 여부를 `Route.caps()["items"]["fix"]["use"] == "pc"` 와 PC `Backend.health["fix_private"]` 로만 판정한다. 폰 직접 AI 가 생겨도 지금 코드는 "저장만"으로 막는다 | `godot\scripts\practice\diary_screen.gd` 154~168행·215~221행 |
| F-P9 | 미션 화면의 `_llm_down()` 등 여러 곳이 `Backend.llm_missing()`(PC `/health` 기반, `status==READY` 일 때만 참) 을 본다. 폰 AI 가 있어도 "AI 없음"으로 보이거나 반대로 판정이 빠질 수 있다 | `godot\scripts\autoload\backend.gd` 50~57행, `godot\scripts\practice\mission_screen.gd` 312~315행, 그 밖 §3 표 |
| F-P10 | Godot 4.6.3 에서 `HTTPRequest.cancel_request()`(와 노드 제거)가 메인 스레드를 막는다는 기록과 그 우회(고아로 두고 결과 버림)가 `api.gd` 에 있다. AI 호출·모델 내려받기도 같은 규칙을 따라야 한다 | `godot\scripts\autoload\api.gd` 137~145행 |
| F-P11 | 공개 점검(`publish_release.ps1`)은 키 모양 문자열(`sk-…`·`AIza…` 등)이 든 추적 파일을 막고, `backend\tools\` 의 새 추적 파일도 막는다. 그래서 시험용 가짜 키는 이 모양을 피하고 새 도구는 `backend\tools\` 밖(`phone_src\tools\`, 새)에 둔다 | `packaging\publish_release.ps1` 105~115행 |
| F-P12 | `export_presets.cfg`: Android 는 Gradle 끔(`gradle_build/use_gradle_build=false`), arm64 만, 자동 백업 끔(`user_data_backup/allow=false`), 권한 INTERNET·ACCESS_NETWORK_STATE·RECORD_AUDIO. Windows 프리셋 `exclude_filter` 는 `tests/*, tools/*, data/pack/*`. 폰 음성 인식·AI 직접 연결에 **새 권한이 필요 없다** | `godot\export_presets.cfg` 13·40~110행 |
| F-P13 | 이 PC: Android SDK(`...\Packages\Claude_pzs8sxrjxfjjc\LocalCache\Local\Android\Sdk`)에 build-tools 34.0.0·36.1.0, platforms android-34·36, cmdline-tools, platform-tools(adb), JDK 17 이 있다. **NDK·SDK CMake 폴더는 없다.** 시스템 CMake 4.3.1, Ninja 1.11.1, Python 3.10.11, Git, GitHub CLI, Visual Studio 2022 Community(C++ 도구 있음)가 있다. **SCons·godot-cpp·whisper.cpp 는 없다**(`D:\Ai` 3~4단계 검색). 디스크 여유 C: 173.6 GB, D: 363.7 GB. Godot 에디터 설정은 일반 `%LOCALAPPDATA%\Android\...` 경로를 가리켜서 Claude 앱 밖에서는 SDK 를 못 찾는다(오케스트레이터 메모 `release-key-location`: 내보내기·공개는 scratch APPDATA 방식) | §1.2 표 |
| F-P14 | Godot **4.6 브랜치** `export_plugin.cpp` 의 `save_apk_so()`: Gradle 없는 템플릿 APK 경로에서 `.gdextension` 의 `.so` 를 `lib/<abi>/<파일>` 로, 압축 없이(`Z_NO_COMPRESSION`) 넣는다. 파일 이름은 `lib` 로 시작해야 하고 태그가 ABI 와 안 맞으면 내보내기가 실패한다. (4.6.3 실기 확인은 G1) | §1.2(d) |
| F-P15 | godot-cpp master: v10 부터 Godot 와 따로 버전 관리, `scons api_version=4.3` 으로 4.3 이상을 겨냥, "이전 Godot 로 만든 확장은 이후 마이너에서 대체로 동작". `tools\android.py`: `ANDROID_HOME`(없으면 `ANDROID_SDK_ROOT`)의 `ndk\<ndk_version>`, 기본 `ndk_version="28.1.13356709"`, `android_api_level` 기본 24(그 미만은 24로 올림), arch `arm64`. CMake 지원 상태는 README 에 없다 | §1.2 |
| F-P16 | NDK r28 이상은 16 KB 정렬이 기본이다. 압축 안 한 `.so` 는 APK 안에서 16 KB 로 zip 정렬돼야 한다(확인: `zipalign -c -P 16 -v 4`, build-tools 35.0.0 이상 — 36.1.0 있음). 4 KB 정렬 라이브러리는 16 KB 기기에서 "호환 모드"로 돌 수 있다 | Android 문서 |
| F-P17 | `DirAccess.get_space_left()` 는 플랫폼 질의가 실패하면 **0** 을 돌려줘서 "가득 참"과 구별되지 않는다. `OS.get_user_data_dir()` 문서는 안드로이드에서 "내부 또는 외부 저장소의 샌드박스 폴더"라고 적는다(어느 쪽인지 확인 필요). Wi-Fi/모바일 데이터를 알려 주는 `OS` 함수는 없다 | Godot 문서 |
| F-P18 | whisper.cpp C API: `whisper_token_data{id, p, plog, t0, t1}`, `whisper_full_get_token_data`, `whisper_full_params{token_timestamps, max_len, split_on_word, n_threads, no_context, single_segment, audio_ctx, abort_callback, language, temperature, suppress_blank}`, 샘플링 `GREEDY`/`BEAM_SEARCH`. README: 단어 시각은 "experimental", MIT 라이선스, 안드로이드 예제는 `examples/whisper.android`(빌드 옵션 설명 없음) | `whisper.h`, README |
| F-P19 | 모델(Hugging Face): `ggml-base.en-q5_1.bin` 59.7 MB, `ggml-base.en-q8_0.bin` 81.8 MB, `ggml-tiny.en-q5_1.bin` 32.2 MB, `ggml-small.en-q5_1.bin` 190 MB. 다국어 `ggml-base-q5_1.bin` 도 59.7 MB. README 메모리 표(양자화 전): base ≈ 388 MB | HF 목록, README |
| F-P20 | GitHub 릴리스: 파일마다 2 GiB 미만, 총량·대역폭 제한 없음 | GitHub 문서 |
| F-P21 | `backend\curriculum.json` 과 `godot\data\curriculum.json` 은 해시가 같다(SHA-256 앞 20자 `549e5a9869f8d4ced83e`). 폰 프롬프트의 커리큘럼 문맥이 PC 와 같다 | 실행 |
| F-P22 | 이 저장소에는 `difflib.SequenceMatcher` 의 GDScript 이식이 없다(`text_sim.gd` 는 LCS 만). 채점 정렬(`align_seq`)이 이것을 쓴다 | `backend\server.py` 1175~1196행, `godot\scripts\core\text_sim.gd` |

### 0.4 핵심 결정 요약
| # | 결정 | 이유 |
|---|---|---|
| PD1 | **폰 우선 = 새 기능을 폰 기준으로 먼저 만들고, PC 앱 동작은 한 줄도 바꾸지 않는다.** 폰 처리는 기존 `Route`/`LocalApi` 의 `stt`·`ai` 핸들러 빈자리를 채우는 방식 | F-P1. 화면 코드는 거의 안 고친다 |
| PD2 | **whisper.cpp GDExtension `WhisperBridge`(arm64) + Gradle 없음.** 소스는 빌드 때 고정 커밋을 받고, 산출물(`.so`/`.dll`)과 `.gdextension` 파일은 **추적하지 않고 빌드가 만든다**. `BUILD_INFO.json`(커밋·NDK·sha256)만 추적 | F-P14. 추적되는 `.gdextension` 이 있고 라이브러리가 없으면 모든 워크트리의 모든 Godot 실행이 로딩 오류를 낸다(§8 R-P7) |
| PD3 | **영어 전용 모델 `ggml-base.en-q5_1.bin`(59.7 MB)** 기본, 저사양 `ggml-tiny.en-q5_1.bin`(32.2 MB). 속도가 목표에 못 미치면 `base.en-q8_0`(81.8 MB, 사용자 승인 필요)을 비교. 다국어 모델·일본어는 쓰지 않음 | 같은 크기에서 영어 전용이 영어에 유리(추측, §1.6 측정으로 확인) |
| PD4 | 모델은 **GitHub 릴리스 자산(`models-1`) + Hugging Face 미러**, SHA-256 은 APK 안 `res://data/models.json` 에 고정, 이어받기, 저장 공간 확인 | F-P19·F-P20, 서명된 APK 가 지문의 신뢰 근거 |
| PD5 | **점수 보정은 브리지 출력 `p` 에 단조 매핑(`p_map`)과 `ok_prob` 를 적용**하고 `ScoreCore.score_en` 은 PC 와 같은 입력이면 같은 출력(황금 파일). 보정값은 데이터 파일 `godot\data\score_params.json`(새) | F-P6, 서버 코드 변경 0 |
| PD6 | **자동 모드에서 `/stt`·`/score` 는 폰 우선**(새 설정 `score_where`, 기본 `"phone"`), 음소 분석 화면만 PC(`need_ph`). **AI(`/chat`·`/fix`·`/feedback`·`/missions/judge`)는 PC 우선 유지**(무료·학습 안 함·키 비용 없음). 폰 채점이 엔진 오류면 PC 로 한 번 재시도 | §1.8 |
| PD7 | **속도 목표**: 3~6초 발화 한 문장 채점 p50 ≤ 3.0초, p95 ≤ 6.0초, 12초에서 중단. 저사양 폰은 `tiny.en` 또는 폰 채점 끄기(자가 평가) | §1.7(전부 제안값) |
| PD8 | **AI 공급자는 프리셋 4종(OpenCode Zen 유료 모델·DeepSeek·Gemini·OpenRouter), 기본값 없음**(사용자가 고르고 동의해야 키가 나감). 1.5.0 OpenCode 무료 모델은 폰에서 못 쓴다 | §2.1 |
| PD9 | **키 저장 = 기기 결합 암호화 파일(`FileAccess.open_encrypted_with_pass`) + 자동 백업 끔 + 내부 저장소 확인.** 눈속임에 가깝다는 한계를 화면과 문서에 적는다. Android Keystore(JavaClassWrapper 로 시도)는 선택 스파이크 | §2.3 |
| PD10 | **프롬프트·검증은 GDScript 로 문장 단위 복사 + 서버 함수를 부르는 파이썬 황금 파일 생성기(`--check` 로 드리프트 감지).** 서버 변경 0 | §2.5 |
| PD11 | **폰 AI 범위는 영어의 `/chat`·`/fix`(private 포함)·`/feedback`·`/missions/judge`.** 일본어는 `ja_ai_pc` 로 PC 안내 | §0.2 |
| PD12 | **개인정보: 업체별 고지와 동의(키 저장 때 + 일기 첫 사용 때). 무료 등급이 보낸 글을 학습에 쓰는 업체(Gemini 무료)는 일기 AI 교정이 기본 꺼짐.** 동의 문구를 폰용으로 바꾼다(PC 용 "이 PC의 로그" 문구는 폰에 맞지 않음) | §2.6 |
| PD13 | **출시 추천: 2.0.0 = R1 그대로(폰 추가 0), 2.0.1 = P-ASR, 2.0.2 = P-AI, 2.1.0 = R2 + 수준 맞춤 대화 이식(PI-L).** P-ASR 이 2.0.0 동결 1주 전까지 모든 합격 조건·실기를 통과하면 2.0.0 에 넣을 수 있다(오케스트레이터 판단) | §4 |
| PD14 | 새 폴더 `native\`(C++), `phone_src\`(파이썬 도구·보정 안내). v200 이 소유한 파일을 고쳐야 하면 **그 작업이 병합된 뒤**(`after=`)에만 고친다 | §5 |

---

## 1. 폰 음성 인식 (P-ASR)

### 1.1 구조와 데이터 흐름
```
화면(SpeakDrill / 코스 플레이어 / 쉐도잉 / 약한 소리 …) ── Api.post_json("/score", {lang,target,reading,audio_b64[,need_ph]})
                                   │  (호출 코드는 그대로)
                                   ▼  Api._start → Route.decide("POST","/score",body)
                  prefer = score_where("phone" 기본) ── need_ph 가 true 면 PC
                                   ▼ "phone"
                         LocalApi.dispatch → LocalStt.handle   (새, scripts\local\local_stt.gd)
                                   │ 1) base64 → WAV 바이트 (Marshalls)            [메인]
                                   │ 2) [Thread] WhisperBridge.transcribe(wav,"en",opts)   [GDExtension, 블로킹]
                                   │       → {ok,text,duration,ms,words:[{w,p,start,end}]}
                                   │ 3) p' = ScoreCore.map_p(p, score_params)       [메인, 순수 GDScript]
                                   │ 4) ScoreCore.score_en(target, words', text)    ← PC score_en 과 같은 입력=같은 출력
                                   ▼
        {transcript,score,accuracy,clarity,fluency,units[{t,ok,conf,heard}],tips_ko} + via:"phone" + degraded[…]
   엔진 오류·12초 초과 ─(자동 모드 & PC 준비됨)─▶ 같은 요청을 PC 로 1회 재시도 (P0 가 api.gd 에 추가)
   모델 없음·엔진 없음 ─▶ Route 가 "none"(PC 도 없을 때) → 자가 평가 위젯(기존 SelfRatePanel) + [모델 받기] 버튼(PWA)
```
- 동일 요청 모양: 입력 `{lang, target, reading, audio_b64}`(+ 새 선택 필드 `need_ph`)와 출력은 `API.md` 의 `/score`·`/stt` 와 같은 키. 서버는 `need_ph` 를 모른 채 무시한다: 설치된 pydantic 2.14.1 이고 `server.py` 에 `extra`·`model_config` 설정이 없어 기본값(무시)이다(코드로 확인, P0-7 이 실제 `ScoreReq` 로 한 번 더 확인).
- 영어만. `lang:"ja"` 는 `LocalStt.is_available_for` 가 false → Route 가 PC 로 보낸다(PC 없으면 기존 `not_on_phone` 안내).

### 1.2 빌드 경로 (whisper.cpp → GDExtension → 비-Gradle APK)

**(a) 이 PC 도구 현황 (직접 확인)**
| 도구 | 상태 | 근거 |
|---|---|---|
| Android NDK | **없음** | SDK 폴더에 `ndk\` 없음(§0.3 F-P13) |
| SDK 설치 CMake(`cmake;3.22.1` 등) | 없음 | 시스템 CMake 4.3.1(`C:\Program Files\CMake\bin`)·pip CMake 4.1.0 이 대신 있음 |
| CMake / Ninja | **있음** (4.3.1 / 1.11.1) | `cmake --version`, `ninja --version` |
| SCons | **없음** | Python 3.10.11 에 `scons` 모듈 없음 |
| godot-cpp, whisper.cpp 소스 | **없음** | `D:\Ai` 검색 결과 없음 |
| Visual Studio 2022 Community(C++ 도구) | 있음 | `vswhere -requires ...VC.Tools` → 경로 반환. Windows 데스크톱용 브리지 시험 빌드에 쓴다 |
| JDK 17, build-tools 34.0.0·36.1.0(zipalign·apksigner·aapt2), platform-tools(adb) | 있음 | SDK 폴더 |
| Godot 4.6.3 + 안드로이드 내보내기 템플릿 | 있음 | `%APPDATA%\Godot\export_templates\4.6.3.stable\android_release.apk` |
| Git, GitHub CLI | 있음 | PATH |

**(b) 받아야 할 것 (★ = 받기·설치 전에 사용자 확인)**
| 항목 | 어디서 | 크기(추측) | 놓을 곳 | 확인 |
|---|---|---|---|---|
| ★ Android NDK `28.1.13356709`(r28b) | `sdkmanager "ndk;28.1.13356709"`(cmdline-tools `latest\bin`), godot-cpp 기본값과 같은 버전 | 설치 후 약 1.5 GB | SDK 폴더의 `ndk\28.1.13356709`(Claude 앱 가상 LocalAppData 아래, F-P13) | ★ 설치 승인 |
| ★ godot-cpp (GitHub `godotengine/godot-cpp`, 고정 커밋) | `git clone` + `git checkout <sha>` | 수십 MB | `native\_deps\godot-cpp`(추적 안 함) | ★ 다운로드 승인 |
| ★ whisper.cpp (GitHub `ggml-org/whisper.cpp`, 고정 커밋) | 같음 | 수십~100 MB | `native\_deps\whisper.cpp`(추적 안 함) | ★ 다운로드 승인 |
| ★ SCons | `pip install scons` 를 **임시 가상환경**(`<scratch>\venv_scons`)에 | 수 MB | 시스템 Python·`backend\.venv` 는 건드리지 않음 | ★ 설치 승인 |
| ★ 시험용 모델 2개(`ggml-base.en-q5_1.bin` 59.7 MB, `ggml-tiny.en-q5_1.bin` 32.2 MB) | Hugging Face `ggerganov/whisper.cpp` | 92 MB | `<scratch>`(저장소 밖) | ★ 다운로드 승인 |
| ★ 사용자 폰 준비 | USB 디버깅 켜기, 디버그 APK 설치 | - | 사용자 폰 | ★ 사용자 작업 |
| (선택) `ggml-base.en-q8_0.bin` 81.8 MB, `ggml-small.en-q5_1.bin` 190 MB | 같음 | 속도·정확도 비교용 | `<scratch>` | 필요할 때 |
- 디스크: 합계 약 3 GB 이내(추측). C: 173.6 GB·D: 363.7 GB 여유로 충분.
- 모델 파일은 저장소에 절대 넣지 않는다(`.gitignore` 에 `*.bin` 계열이 없으면 PA1 이 `godot/bin/`·`native/_deps/`·`native/**/build*/` 와 함께 추가).

**(c) 빌드 절차** — `native\whisper_bridge\build.ps1`(새, PA1)가 한 줄로 재현. 두 길을 모두 적고 PA1 스파이크가 먼저 되는 쪽을 고른다.
- **길 A(권장 시작점, CMake 하나로)**: `CMakeLists.txt` 가 godot-cpp(`add_subdirectory`)와 whisper.cpp·ggml(정적, `BUILD_SHARED_LIBS=OFF`)를 같이 빌드해 공유 라이브러리 `libwhisper_bridge.android.arm64.so` 를 만든다. 툴체인 `-DCMAKE_TOOLCHAIN_FILE=<ndk>\build\cmake\android.toolchain.cmake -DANDROID_ABI=arm64-v8a -DANDROID_PLATFORM=android-24 -DANDROID_STL=c++_static -G Ninja`. whisper.cpp 옵션은 `GGML_OPENMP=OFF`·예제·시험 끄기·`GGML_NATIVE=OFF`(옵션 이름은 고정 커밋의 CMakeLists 로 확인, **추측**). godot-cpp 가 이 NDK·CMake 조합에서 정상 빌드되는지는 README 에 상태가 없어 **(추측)**.
- **길 B(길 A 가 막히면)**: godot-cpp 만 SCons(`scons platform=android arch=arm64 target=template_release api_version=4.3 android_api_level=24 ANDROID_HOME=<sdk> ndk_version=28.1.13356709`)로 정적 라이브러리를 만들고, whisper.cpp 는 CMake(NDK 툴체인)로 정적 라이브러리를 만든 뒤 브리지 `.so` 를 링크.
- 두 길 모두 `libc++` 는 **정적**으로(`c++_static`) 링크해 `libc++_shared.so` 동봉을 피한다. 아니면 `.gdextension` 의 `[dependencies]` 에 올리고 APK 안 존재를 확인한다.
- CPU 최적화: 기본은 armv8-a(NEON) **범용**. `dotprod`/`i8mm` 전용 빌드는 안 만든다(구형 SoC 에서 "illegal instruction" 위험 — 추측). 속도가 부족할 때만 PA1 스파이크가 `/proc/cpuinfo` 의 `asimddp` 확인 뒤 전용 `.so` 를 비교 측정한다.
- Windows 데스크톱용(시험·보정): 같은 `CMakeLists.txt` 로 `-Target windows-x64`(VS 2022) → `godot\bin\whisper_bridge.windows.x86_64.dll`. **PC 앱에는 넣지 않는다**(아래 (d)).
- 재현성: `BUILD_INFO.json` 에 `whisper_cpp_commit`·`godot_cpp_commit`·`ndk_version`·`bridge_version` 과 산출물별 sha256 을 기록한다. `build.ps1` 은 고정 커밋이 아니면 실패한다.

**(d) Gradle 커스텀 빌드 없이 GDExtension 을 APK 에 넣는 방법**
1. `build.ps1` 이 `native\whisper_bridge\whisper_bridge.gdextension.in` 을 `godot\whisper_bridge.gdextension` 으로 복사(생성, 추적 안 함, `.gitignore`)한다:
```
[configuration]
entry_symbol = "whisper_bridge_init"
compatibility_minimum = "4.3"
reloadable = false

[libraries]
android.debug.arm64   = "res://bin/libwhisper_bridge.android.arm64.so"
android.release.arm64 = "res://bin/libwhisper_bridge.android.arm64.so"
windows.debug.x86_64   = "res://bin/whisper_bridge.windows.x86_64.dll"
windows.release.x86_64 = "res://bin/whisper_bridge.windows.x86_64.dll"
```
(항목 이름·`compatibility_minimum` 형식은 Godot GDExtension 문서 기억 기반 **(추측)** — PA1 이 4.6.3 에서 확인.)
2. 내보내기는 지금과 같은 `build_android.ps1`(템플릿 APK, `gradle_build/use_gradle_build=false`). 4.6 브랜치 `save_apk_so()` 가 `.so` 를 `lib/arm64-v8a/libwhisper_bridge.android.arm64.so` 로 압축 없이 넣는다(F-P14, 파일 이름이 `lib` 로 시작해야 하고 태그에 `arm64` 가 있어야 ABI 매칭). 디버그·릴리스 두 태그가 같은 `.so` 를 가리킨다(지금도 릴리스 템플릿 + 디버그 키 조합이 있으므로).
3. **PC(Windows) 내보내기에는 넣지 않는다**: `export_presets.cfg` preset.0 `exclude_filter` 에 `bin/*, whisper_bridge.gdextension` 추가(PA7, 한 줄). PC 앱은 faster-whisper 를 쓴다.
4. `.gdextension` 이 없는 곳(새 워크트리·리뷰어 환경)에서는 `WhisperBridge` 클래스가 없고 `ClassDB.can_instantiate("WhisperBridge")` 가 false → `LocalStt` 가 `engine_missing` 을 돌려준다. 오류 로그 없음.
5. 새 권한 없음. 새 ABI 없음(arm64 만). 확인: `build_android.ps1` 의 기존 검증(권한 3개·ABI 목록)과 PA7 의 `check_phone_native.ps1`(§6).
6. 16 KB 페이지: NDK r28b 는 기본 16 KB 정렬. 확인 명령 — `llvm-objdump -p <so> | Select-String LOAD` 의 모든 `align` 이 `2**14`, `zipalign -c -P 16 -v 4 <apk>` 가 "Verification successful"(F-P16).

### 1.3 모델 받기
- **매니페스트** `godot\data\models.json`(새, APK 안 → 서명으로 보호. 팩 `manifest.json` 과 별개 파일, `build_phone_pack.py` 변경 0):
```json
{"v":1,"models":[
 {"id":"whisper-base.en-q5_1","kind":"stt","langs":["en"],"file":"ggml-base.en-q5_1.bin",
  "bytes":0,"sha256":"<PA3 가 실제 파일로 채움, 64자리 소문자 16진수>","min_free_mb":250,"default":true,
  "urls":["https://github.com/Whahan/hoehwa-practice/releases/download/models-1/ggml-base.en-q5_1.bin",
          "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en-q5_1.bin"],
  "license":"MIT (OpenAI Whisper 가중치, ggml 변환: whisper.cpp)","ram_hint_mb":400},
 {"id":"whisper-tiny.en-q5_1","kind":"stt","langs":["en"],"file":"ggml-tiny.en-q5_1.bin","bytes":0,"sha256":"…","min_free_mb":150,"default":false,"urls":["…"],"license":"MIT","ram_hint_mb":250}
]}
```
  `bytes`·`sha256` 는 오케스트레이터가 실제 파일을 내려받아 계산해 PA3 에 건넨다(★ 다운로드 승인). 미러 URL 도 같은 sha256 이어야 한다(미러가 바뀐 파일을 줘도 거부됨).
- **저장**: `user://models/<file>`, 받는 중 `<file>.part` + `<file>.part.meta`(받은 바이트·사용한 URL). 앱 비공개 저장소.
- **내려받기**(`ModelStore`, 새): `HTTPClient` 를 `Thread` 에서 폴링(F-P10: `HTTPRequest` 는 쓰지 않는다). 청크마다 `.part` 에 쓰고 진행(바이트)을 메인 스레드로 `call_deferred`. 이어받기: `.part` 크기 N>0 이면 `Range: bytes=N-`; `206` 이면 이어쓰기, `200`(서버가 Range 무시)이면 처음부터 다시, `416` 이면 `.part` 폐기 후 처음부터. 리다이렉트 `301/302/303/307/308` 은 수동으로 최대 3번 따라가되 **https 만**, 호스트 허용 목록(`github.com`, `objects.githubusercontent.com`, `release-assets.githubusercontent.com`(추측), `huggingface.co`, `cdn-lfs.huggingface.co`, `cas-bridge.xethub.hf.co`(추측), 시험 때만 루프백)에서만. 서명된 리다이렉트 URL 은 만료되므로 이어받기 때는 항상 원래 URL 부터 다시 시작한다. 첫 URL 이 실패(연결·4xx·5xx)하면 다음 URL(미러).
- **검증**: 다 받으면 크기 == `bytes`, `FileAccess.get_sha256()` == `sha256`(스레드에서) → 맞으면 `.part` 를 정식 이름으로 `rename`(원자적). 틀리면 파일 삭제 + `model_corrupt`(다음 URL 로 한 번 더 시도하지 않고 사용자에게 보임: 두 미러가 같은 오류를 내면 매니페스트 오류).
- **저장 공간**: 시작 전 `DirAccess.get_space_left()` 가 `0` 이 아니면 `남은 ≥ (bytes − 이미 받은 .part) × 1.1 + 100 MB` 여야 하고, 미달이면 요청을 한 번도 보내지 않고 거절(`no_space`, 문구는 MB 단위). 값이 `0` 이면 "알 수 없음"(F-P17)이므로 "남은 공간을 확인하지 못했어요. 약 100 MB 이상 비어 있는지 확인하고 계속할까요?" 확인을 받고 진행하되 쓰기 오류(`FileAccess.get_error()`)가 나면 `.part` 를 지우고 `no_space`.
- **네트워크 종류**: Godot 에 Wi-Fi/데이터 구분 함수가 없다(F-P17). 시작 전 확인창 "약 60 MB를 받아요. 와이파이에 연결돼 있나요?" [받기] [나중에]. 설정에서 자동 시작은 없다.
- **중단·취소·삭제**: 앱이 백그라운드로 가면(`NOTIFICATION_APPLICATION_PAUSED`) 일시정지(`.part` 유지, 다음에 [이어받기]), [취소]는 `.part` 를 남기고 멈춤, [모델 지우기]는 모델·`.part`·`.meta` 전부 삭제(확인 시트). 메인 스레드는 2초 이상 막히지 않는다.
- **상태** `ModelStore.state(id)`: `missing | partial | downloading | verifying | ready | corrupt`. `ready` 는 파일 크기 == `bytes` 이고 `.ok` 표식(검증 때 sha256 을 적은 작은 파일)이 있을 때. 앱 시작 때는 크기만 본다(60 MB sha256 을 매번 읽지 않는다). 로드가 실패하면 `model_corrupt` 로 바꾼다.
- 화면 문구(MB 단위만, 5자리 이상 숫자 없음): "음성 인식 모델(약 60 MB)을 받는 중 35 / 60 MB" 같은 진행 글은 `ModelStore.progress_label(done, total)` **한 함수**에서 만든다.

### 1.4 `WhisperBridge` 계약 (GDExtension, C++ 얇은 래퍼 — 새)
```
class WhisperBridge : RefCounted
  static version() -> String                       # 예 "bridge 1 / whisper.cpp <sha7>"
  load_model(path: String, threads: int = 0) -> int  # Godot Error (OK = 0). threads 0 = 자동(코어 수 − 2, 2~4)
  is_loaded() -> bool
  model_file() -> String                           # 불러온 파일 이름
  unload() -> void
  transcribe(wav: PackedByteArray, lang: String, options: Dictionary = {}) -> Dictionary   # 블로킹(스레드에서 부른다)
        wav    : RIFF WAV(PCM16, 모노/스테레오, 8~48 kHz). C++ 가 모노·16 kHz·float 로 바꾼다(GDScript 샘플 루프 금지, F-P7 메모)
        lang   : "en" 만 허용(그 밖은 ok:false, error:"bad_lang")
        options: {beam:int 1..5 (기본 1), max_seconds:float (기본 30), trim:bool (기본 true), token_timestamps:bool (기본 true)}
  abort() -> void                                  # 다른 스레드에서 불러도 안전. 다음 abort_callback 시점에 중단
  결과: {ok:bool, error:"" | "bad_wav" | "bad_lang" | "no_model" | "aborted" | "engine",
         text:String, duration:float(초), ms:int(걸린 시간), model:String,
         words:[{w:String, p:float(0..1), start:float(초), end:float(초)}]}
```
- **단어 만들기**: 모든 세그먼트의 토큰을 순서대로 보며 특수 토큰(`id ≥ eot`)은 건너뛰고, **공백으로 시작하는 토큰이 새 단어를 연다**. 구두점만인 토큰은 앞 단어에 붙이되 `p` 계산에서 제외. 단어 `p` = 단어를 이루는 토큰 `p` 의 **평균**(F-P6: faster-whisper 와 같은 방식). `start`/`end` = 첫 토큰 `t0`·마지막 토큰 `t1`(10 ms 단위 → 초). `t1 ≤ t0` 이면 그 세그먼트 길이를 글자 수로 나눠 보간. (`token_timestamps` 는 README 상 experimental → §8 R-P4.)
- **무음·짧은 소리**: 샘플 1,600 미만이거나 최대 진폭 < 0.003(서버와 같은 기준)이면 `{ok:true, text:"", words:[]}`.
- **앞뒤 무음 제거(`trim`)**: 20 ms 프레임 에너지 기준 간이 방식(서버의 Silero VAD 와 같지 않음 — 차이는 보정 데이터에 포함).
- **디코딩 기본값**: 그리디(`beam=1`), `language="en"`, `no_context=true`, `single_segment=true`(30초 이하), `suppress_blank=true`, `temperature=0`(서버와 달리 beam 5 가 아님 → 속도 때문, 측정 뒤 `beam` 2~3 허용 여부 결정). `audio_ctx` 축소는 정확도 손실 위험(추측)이라 기본 끔.
- **동시성**: 모델 하나·전사 하나. 두 번째 호출은 뮤텍스에서 기다린다. 앱 일시정지 때 `abort()` + `unload()`.
- **크기 한도**: `.so` 한 개 ≤ 20 MB(추측: 정적 링크 whisper.cpp 가 3~8 MB). 넘으면 PA1 이 보고.

### 1.5 `LocalStt` 핸들러 계약 (새, `godot\scripts\local\local_stt.gd`)
- 정적 함수(`LocalApi` 규약): `handle(method, path, query, body)`, `is_available()`, `unavailable_reason()`, **`is_available_for(path, query, body)`**(요청 언어가 `en` 이고 모델 `ready` 이고 `ClassDB.can_instantiate("WhisperBridge")`), `unavailable_reason_for(...)` → `engine_missing | model_missing | model_corrupt | not_on_phone(ja)`.
- `POST /stt` → `{text, words:[{w,p,start,end}], duration}` + `via:"phone"`, `degraded`. `p` 는 **보정 후** 값(`/stt` 의 소비자들도 같은 척도를 본다).
- `POST /score` → `ScoreCore.score_en(target, words', text)` 결과(키: `transcript, score, accuracy, clarity, fluency, units[{t,ok,conf,heard}], tips_ko`) + `via`, `degraded`. 영어만.
- `degraded` 값(`Route.DEGRADED` 에 P0 가 추가): `phoneme_off`(항상), `score_uncalibrated`(`score_params.json` 이 없거나 `calibrated:false` 또는 모델 id 불일치), `stt_tiny_model`(tiny 모델 사용 중).
- 입력 검사(서버와 같은 한국어 문구): `audio_b64` 빈 값 → 400 "녹음된 소리가 없어요. 다시 녹음해 주세요."; base64 깨짐 → 400 "오디오 데이터를 읽을 수 없어요."; WAV 가 아님(`bad_wav`) → 400 "오디오 형식을 읽을 수 없어요. WAV 파일을 보내 주세요."; `target` 빈 값 → 400 "연습할 문장이 비어 있어요."; 무음 → 점수 0 + `NO_VOICE_TIP`(`empty_score`); 30초 초과는 30초로 자름.
- 스레드: `WorkerThreadPool` 또는 `Thread` 에서 `transcribe`, 완료는 `call_deferred` 로 메인에서 결과 조립. 12초(`STT_TIMEOUT_SEC`)가 지나면 `abort()` + `stt_timeout`(P0 의 재시도 규칙이 PC 로 넘김). `ApiCall.cancel()` 이면 `abort()` 하고 결과를 버린다.
- 수명: 모델은 처음 쓸 때 불러오고(`warm()` 은 말하기 화면이 열릴 때 비동기), 마지막 사용 90초 뒤 `unload()`, `NOTIFICATION_APPLICATION_PAUSED` 에서 `abort()` + `unload()`. 모델 불러오기 실패 → `model_corrupt`(상태를 `corrupt` 로).
- 로그: `print`·`push_warning` 에 인식 글자·타깃 문장을 쓰지 않는다(개발 로그는 `stt_ms=… audio_ms=… model=…` 숫자만).

### 1.6 점수 보정 (PC `/score` ↔ 폰)
- **왜 필요한가**: PC 의 단어 `p` 는 faster-whisper 가 **강제 정렬 단계**(teacher forcing)에서 낸 토큰 확률의 평균이고 `beam 5` 다. whisper.cpp 는 디코딩 중 **뽑힌 토큰의 확률**이고 모델도 `base.en`(양자화)이다. 분포가 달라 `OK_PROB=0.45` 를 그대로 쓰면 판정이 흔들린다(F-P6).
- **방식**: `ScoreCore.score_en` 은 한 글자도 바꾸지 않고(PD5), `LocalStt` 가 브리지의 `p` 에 **단조 증가 구간 선형 매핑** `p' = map(p)` 를 적용하고 필요하면 `ok_prob`(기본 0.45)를 조정한다. 값은 `godot\data\score_params.json`(새, PA5 가 채움):
```json
{"v":1,"model_id":"whisper-base.en-q5_1","calibrated":true,"date":"YYYY-MM-DD",
 "ok_prob":0.45,
 "p_map":[[0.0,0.0],[0.05,0.02],[0.1,0.05],[0.2,0.12],[0.3,0.25],[0.45,0.45],[0.6,0.62],[0.75,0.78],[0.9,0.92],[1.0,1.0]],
 "report":{"synth_clips":0,"user_clips":0,"ok_agree":0.0,"score_mae":0.0,"score_p90":0.0}}
```
  파일이 없거나 형식 불량(비단조·범위 밖·모델 id 불일치)이면 **항등 매핑 + `degraded:["score_uncalibrated"]`**(앱은 죽지 않음).
- **보정 데이터**(`phone_src\tools\calib_*.py`, 새, 산출물은 모두 `<scratch>` — 저장소에 오디오 0):
  1. **합성 음성**(`calib_make_set.py`): `practice_en.json` 의 3~10단어 문장 ≥ 200개를 Kokoro(`backend\server.py synth_wav`, 음성 4종 이상)로 합성. 변형: 깨끗함 / **틀린 단어 1개를 바꿔 읽음(타깃은 원문)** ≥ 250클립 / 속도 0.8·1.25배 / 소음(SNR 20·10 dB) / 8 kHz 대역 제한 / 진폭 0.2배. 합계 ≥ 1,000클립.
  2. **사용자 녹음**(`calib_record.py`, ★ 사용자 동의): 사용자가 PC 마이크로 영어 문장 30개를 **정상 1번 + 일부러 틀리게 1번** 읽는다(약 60클립, 8분 안팎). 파일은 `<scratch>\calib_user\` 에만 두고 저장소·네트워크·로그에 나가지 않으며, 보정이 끝나면 지울지 사용자가 정한다(기본 삭제). 보고에는 개수·총 길이만 적는다. 동의 문구(§9 Q5 에 그대로 사용).
  3. **PC 기준 결과**(`calib_pc_run.py`): 서버 함수 `transcribe`(`--stt-cpu` 와 같은 설정, 포트·서버 프로세스 없이 프로세스 안에서)와 `score_en` 으로 단어별 `{t, ok, conf}`·최종 점수를 저장.
  4. **폰 쪽 결과**(`godot\tools\calib_phone.gd`, 새): 데스크톱 Windows 브리지 DLL + 같은 모델 파일로 같은 WAV 를 돌려 `words` 를 저장(속도는 대표하지 않지만 확률 분포는 같은 모델이면 같다).
  5. **맞추기**(`calib_fit.py`): 정확히 일치한 단어쌍에서 폰 `p` → PC `p` 의 등위(isotonic) 회귀로 `p_map`(위 10개 지점), 단어별 `ok` 일치율이 최대가 되는 `ok_prob`. 데이터의 70%로 맞추고 30%로 평가(클립 단위로 나눠 같은 문장이 양쪽에 안 걸리게).
- **합격선(제안값)**: 보류 30% 에서 단어별 `ok` 일치율 합성 ≥ 85%·사용자 ≥ 80%(클립 수와 95% 신뢰구간을 같이 보고), 최종 점수 차 평균절대오차 ≤ 10점·90번째 백분위 ≤ 20점, 유창성 점수 평균절대오차 ≤ 15점, **틀린 단어 클립의 폰 점수가 같은 문장의 깨끗한 클립보다 낮은 쌍 ≥ 95%**, 틀린 클립이 통과선 70 이상인 비율 ≤ 10%, 깨끗한 클립이 70 미만인 비율 ≤ 10%. 미달이면 모델 상향(`q8_0`)·`beam` 2~3 을 다시 측정하고, 그래도 안 되면 "폰 간이 채점" 표시를 유지한 채 통과선(70)을 폰에서만 조정할지 오케스트레이터가 정한다.
- **점수가 섞이는 문제(phone_standalone R5)**: `StudyLog.add_score` 는 출처(PC/폰)를 저장하지 않는다. 폰 우선(PD6)이면 앞으로의 점수는 한 엔진으로 일관되고, 옛 PC 점수와의 차이는 이 보정으로 줄인다. `via` 저장은 동기화 스키마 변경이라 하지 않는다.

### 1.7 속도·배터리 목표와 저사양 처리 (제안값 — 기준 폰은 사용자 폰, 측정 전까지 모두 추측)
| 지표 | 목표 | 측정 |
|---|---|---|
| 문장 하나 채점 시간(녹음 끝 → 결과 표시), 3~6초 발화, `base.en-q5_1` | **p50 ≤ 3.0초, p95 ≤ 6.0초, 12초에서 중단**(그 뒤 PC 재시도 또는 자가 평가) | 앱이 숫자만 로그(`stt_ms`, `audio_ms`), 20회 이상 |
| 처음 모델 불러오기 | ≤ 3초 | 같음 |
| 최대 RAM 증가 | ≤ 600 MB | `adb shell dumpsys meminfo <pkg>` 전후 |
| 배터리 | 100% 충전·화면 켬·와이파이로 **60회 채점(하루 말하기 12분 + 재시도 몫)** 연속 후 감소 ≤ 4%p (같은 시간 채점 없이 화면만 켠 대조와 비교) | `adb shell dumpsys battery` |
| 발열 | 60회 연속 중 배터리 온도 상승 ≤ 6.0 °C | `dumpsys battery` 의 `temperature`(0.1 °C 단위) |
- **G1 통과선(스파이크, 더 느슨)**: `base.en-q5_1` p50 ≤ 8초·RAM 증가 ≤ 700 MB·5회 연속 비정상 종료 0. 이 선을 못 넘으면 `base.en-q8_0`·`tiny.en` 도 재 보고, 모두 못 넘으면 **no-go**(P-ASR 중단, 자가 평가 유지, P-AI 는 계속).
- **저사양 처리**: ① 스레드 수 = clamp(코어 수 − 2, 2, 4). ② 처음 모델을 고를 때 `OS.get_memory_info()` 로 RAM 이 3 GB 미만이면(알 수 없으면 `-1`: 측정으로 대체, **추측: 안드로이드 지원 확인 필요**) 기본을 `tiny.en` 으로 제안. ③ 실행 중 최근 5회 처리시간/음성길이(RTF) 중앙값이 > 1.6 이면 "이 폰에서는 채점이 느려요" 안내와 [작은 모델로 바꾸기]·[PC로 채점]·[자가 평가만]. ④ 2회 연속 12초 초과나 메모리 부족이면 자동으로 폰 채점을 끄고(`stt_phone_off=true`, 설정에서 다시 켬) 자가 평가로 돌아간다. ⑤ 전사는 녹음이 끝난 뒤에만(스트리밍 없음), 우선순위 낮은 스레드, 앱이 백그라운드면 중단.

### 1.8 Route 통합: 폰 우선으로 바꾼다 (결정 + 대안)
- **결정(추천)**: 자동 모드의 `/stt`·`/score` 는 **폰 모델이 준비됐으면 폰**, 아니면 PC 가 닿을 때 PC, 둘 다 없으면 `none`(자가 평가). 새 설정 `score_where`(`"phone"` 기본 / `"pc"`)로 사용자가 "PC 우선(음소 분석 포함)"을 고를 수 있다. 음소 분석 화면(`phoneme_screen.gd` 294행 `SpeakDrill.new(lang, "drill")`, 쉐도잉은 `"shadow"`)은 요청에 `need_ph:true` 를 실어 항상 PC 를 우선한다(PC 가 없으면 폰 점수 + `phoneme_off` 안내).
- **이유**: ① 사용자 결정 ②(녹음이 폰 밖으로 안 나감)를 PC 연결 중에도 지킨다. ② 앞으로 18개월 점수가 한 엔진으로 일관돼 추이가 의미가 있다(R5). ③ 캐나다에서는 PC 가 없다 — 평소 쓰던 경로가 그대로다. ④ PC 가 닿을 때의 지연(Tailscale 왕복 + GPU)이 폰 추론(약 3초 목표)보다 꼭 짧지는 않다(추측).
- **잃는 것**: PC 에 연결해 쉐도잉하던 사용자가 음소 팁(`units[i].ph`)을 못 본다 → `score_where="pc"` 로 되돌릴 수 있고(설정 한 줄) 릴리스 노트에 적는다(R-P14). 폰이 PC 보다 배터리를 더 쓸 수 있다(추측) → 같은 설정.
- **대안(기각)**: "PC 우선 유지"는 PC 앱 사용자 경험은 그대로지만 점수 척도가 연결 상태에 따라 뒤섞이고 사용자 결정 ②와 어긋난다.
- **AI 는 PC 우선 유지**(`/chat`·`/fix`·`/feedback`·`/missions/judge`): PC 경로는 무료·키 없음·무보관(Zen 문서의 DeepSeek 무료 모델 정책)이고 폰 직접 호출은 사용자의 돈·개인정보를 쓴다. PC 의 AI 가 한도·미연결로 막혀도 **폰 키로 자동 전환하지 않는다**(요금 보호). 폰만 쓰기·PC 연결 끊김 때만 폰 AI.
- **P0 가 바꾸는 것(새)**: `Route.POLICY` 에 `"POST /score#ph"`(`need_ph:true` 일 때 선택, prefer `"pc"`), `"POST /stt"`·`"POST /score"` 의 prefer 를 `score_where` 에 따라 계산(없으면 `"phone"`), 새 오류 코드·문구, `Route.DEGRADED` 추가, `api.gd` 에 "폰 처리가 `engine_error`/`stt_timeout` 으로 실패하면(자동 모드·PC 준비됨·`/stt`/`/score` 만) PC 로 **한 번만** 재시도".

---

## 2. 폰 AI 직접 연결 (P-AI)

### 2.1 공급자: 어떤 서비스·엔드포인트·무료 조건
**1.5.0 OpenCode 키를 폰에서도 쓸 수 있나?** — 부분적으로. 1.5.0 키는 opencode.ai 콘솔의 API 키이고 PC 앱은 그것을 OpenCode(`opencode serve`)에 건넨다(F-P2). 같은 종류의 키를 폰에 다시 붙여 넣으면 **유료 모델**은 직접 호출할 수 있을 것으로 문서가 말한다. **무료 모델(`deepseek-v4.1-flash-free`)은 폰에서 못 쓴다**: Zen 문서 "Free-tier chat models require OpenCode; use paid models or Go from other clients", 이 저장소의 과거 실측(F-P5)도 같다. 키가 `https://opencode.ai/inference/v1` 로 유료 모델을 실제로 부르는지는 아직 **미검증**(C0, 사용자 키로 1회 시험).

| 프리셋 id | 서비스 | 호출 방식·기본 모델 | 무료 여부·한도 | 가격(문서) | 데이터 정책(문서) | 비고 |
|---|---|---|---|---|---|---|
| `opencode_zen` | OpenCode Zen(유료 모델) | `https://opencode.ai/inference/v1`(현재 프리셋; 문서의 채팅 엔드포인트는 `https://opencode.ai/inference/openai/v1/chat/completions` 로 적혀 있어 **어느 쪽이 맞는지 C0 에서 확인**), `deepseek-v4.1-flash`(채팅 완성). 문서가 채팅 엔드포인트의 인증 헤더를 명시하지 않음 → `Authorization: Bearer`(프리셋 현재값, **추측**) | 무료 모델은 폰 불가. 유료는 크레딧 충전(충전마다 수수료 4.6% + $0.31, 최소 충전액은 문서에 없음) | 입력 $0.30 / 출력 $1.20 (100만 토큰당) | 무료 DeepSeek 은 무보관·무학습이라고 문서가 적음. **유료 모델의 정책은 문서에서 못 찾음(추측)** | 1.5.0 키 재사용. OpenCode Go($10/월 구독, `https://opencode.ai/inference/go`)는 가벼운 사용에는 과함 |
| `deepseek` | DeepSeek API | `https://api.deepseek.com`, `deepseek-flash`(JSON 출력 지원) | 문서에 무료 한도·최소 충전액 없음(충전 잔액·부여 잔액) | 캐시 미스 입력 $0.15(비피크)~$0.30(피크), 출력 $0.6~$1.2 | **API 의 데이터 정책은 못 찾음(추측)**. 소비자 앱 개인정보 방침: 서버가 중국, 입력을 기술 학습·개선에 쓸 수 있음(거부 옵션 있음), API 는 이 방침 범위 밖이라고 적음 | 이미 쓰는 모델과 같은 계열 |
| `gemini` | Google Gemini API | `https://generativelanguage.googleapis.com/v1beta/openai`, 현재 프리셋 `gemini-2.5-flash`(무료 등급 모델 목록에 있음. 문서 예시는 더 새 모델명을 씀 → 프리셋 모델은 낡았을 수 있음(R-P10)). `response_format` 의 `json_object` 지원은 문서에서 확인 못 함 → 거부 시 일반 모드 재시도로 대비 | **무료 등급 있음**(Flash·Flash-Lite 계열). 분·일 한도 숫자는 못 읽음(추측: AI Studio 에서 확인). 한국·캐나다가 지원 국가 목록에 있음. 프로젝트 단위 한도 | 무료 | **무료 등급: "Content used to improve our products" = 예**, 유료: 아니오 | 일기 같은 개인 글이면 주의 |
| `openrouter` | OpenRouter | `https://openrouter.ai/api/v1`, `:free` 모델 | `:free` 모델 분당 20회, 하루 50회(구입 크레딧 10 미만) / 1,000회(그 이상) | 무료 모델 | 문서에 정보 없음(모델 제공자별) | 모델이 자주 바뀜 |
- **추천 순서(오케스트레이터·사용자 확정 §9 Q3)**: ① 이미 계정이 있는 **OpenCode Zen 유료 크레딧**(키 재사용, 이미 쓰던 모델 계열) — C0 통과가 조건 ② **Gemini 무료**(비용 0, 대신 개인정보 고지 강화·일기 기본 꺼짐) ③ DeepSeek 직접. 앱은 4종을 모두 싣고 **기본 선택을 두지 않는다**(`ai_preset` 기본 `""`): 사용자가 고르고 동의하기 전에는 아무것도 보내지 않는다.
- **비용 감 잡기(추정, 가정 표시)**: 한 번 주고받기 ≈ 입력 2,000 + 출력 250 토큰(+교정 호출 별도)으로 가정하면 Zen `deepseek-v4.1-flash` 기준 약 $0.0009. 하루 20번 × 30일 = 600번 ≈ **$0.5/월**, $5 충전(수수료 포함)이 약 9개월분. 실제 수치는 모델·대화 길이에 따라 다르다(추측). 앱은 "오늘 N번 요청" 횟수만 보여 주고 요금을 계산해 주지 않으며, 업체 콘솔에서 지출 한도를 걸라고 안내한다.
- **목록 점검**: 설정 카드의 [모델 목록 확인]이 `GET {base}/models`(Zen 문서에 `.../inference/v1/models` 있음)로 모델 id 를 보여 주고 직접 입력도 허용한다(프리셋 기본 모델이 낡아도 사용자가 바꿀 수 있게).

### 2.2 구조와 데이터 흐름
```
화면(talk_view / mission_screen / diary_screen …) ── Api.post_json("/chat"|"/fix"|"/feedback"|"/missions/judge", body)   (호출 코드는 그대로)
        ▼ Route.decide → 자동 모드: PC 우선(prefer pc), PC 가 없거나 끊기거나 mode="phone" 이면 "phone"
        ▼ LocalApi.dispatch → LocalAi.handle   (새)
              AiState.use(lang) ── 키 없음 → fail("no_ai") (네트워크 0)   영어가 아님 → fail("ja_ai_pc")
              AiChatRules.*  : 서버 rules_text / clean_hist / ko_ok / scrub_ko / run_chat 검증 / _llm_correct 의 GDScript 복사
              AiClient.complete_json(...) ── HTTPS ──▶ 업체 /chat/completions   [키는 이 한 곳에서만 헤더로, 로그·오류에 안 남음]
        ▼ 결과 = 서버와 같은 키: {reply, reading:"", pron:"", ko, fix, fix_ko, suggest[]} + via:"phone", degraded[]   (tts_chunks 없음 → 화면은 기본 Tts 로 읽음)
```
- 요청 취소·재시도는 `Api` 와 같은 약속(F-P10): HTTPRequest 를 끊지 않고 고아로 두고 결과를 버린다. 폰 AI 요청은 `sent_count` 를 올리지 않는다(기존 규약).

### 2.3 키 저장: 세 가지 비교와 결정
| 방법 | 지키는 것 | 못 지키는 것 | Gradle/플러그인 | 구현 난이도 | 평가 |
|---|---|---|---|---|---|
| **A. `user://` 파일에 평문(ConfigFile)** | 다른 앱의 읽기(샌드박스, Godot 문서: 모바일에서 프로젝트 전용·다른 앱 접근 불가) | 루팅·ADB(디버그 가능 빌드의 `run-as`)·파일을 통째로 공유한 경우·백업 파일 열람(백업을 끈 상태면 해당 없음). 파일에서 키가 그대로 보임 | 없음 | 매우 낮음 | 1.3 설계가 택했던 방식 |
| **B. 기기 결합 값으로 암호화한 파일** | A 의 이점 + 파일만 유출됐을 때(공유·잘못된 백업·디스크 덤프) 키가 평문으로 안 보임 | **APK 안에 복호화 코드가 있고 키 재료(`OS.get_unique_id()`·설치별 솔트 파일)도 같은 기기에 있다 — 마음먹은 공격자(루팅+APK 분석)는 풀 수 있다.** 눈속임(obfuscation)이지 보안이 아니다 | 없음 | 낮음(Godot `FileAccess.open_encrypted_with_pass`) | **선택** |
| **C. Android Keystore** | 하드웨어 보호·키 추출 불가(앱 프로세스가 복호화 호출은 할 수 있음) | 루팅된 기기에서 앱이 시키는 대로 복호화는 가능 | **일반적으로 Android 플러그인(AAR, Gradle 빌드) 필요 → D8 위반.** 예외 가능성: `JavaClassWrapper`(안드로이드 전용)로 `java.security.KeyStore` 를 리플렉션 호출 — 문서상 존재하나 `byte[]` 처리·빌더 패턴·4.6.3 동작은 **미검증(추측)** | 높음·위험 | **선택 스파이크(K-스파이크, 2.0.2 뒤)**. 성공하면 B 의 암호화 키를 Keystore 에 두는 강화 |
- **결정**: **B 로 시작**한다 — `user://ai_secrets.bin`(`FileAccess.open_encrypted_with_pass`, 암호 = SHA-256(`user://ai_salt.bin` 의 무작위 32바이트 + `OS.get_unique_id()` + 고정 문자열 `"hoehwa-ai-v1"`), 내용 `{"v":1,"keys":{"<preset>":"<키>"}}`). `OS.get_unique_id()` 가 비거나 기기 초기화로 바뀌어 복호화가 실패하면 **"키 없음"으로 취급**하고 다시 입력하게 한다(앱은 죽지 않음, 손상 파일은 `.bad` 로 격리).
- **정직한 한계 문구(설정 카드에 한 줄)**: "키는 이 휴대폰 안에만 저장되고 암호화돼요. 다만 루팅된 폰이나 폰 전체를 분석하는 경우에는 완전히 지킬 수 없어요. 업체 사이트에서 지출 한도를 걸어 두세요."
- **저장 위치 확인(F-P17)**: `user://` 가 앱 **내부** 저장소인지(외부 공유 저장소가 아닌지) 실기에서 확인한다(H8). 외부라면 키 파일을 쓰지 않고 중단한다.
- **백업**: `user_data_backup/allow=false` 를 PA7 점검이 매 빌드마다 확인(APK 매니페스트 `allowBackup=false`, aapt2 로). 새 폰으로 옮길 때 키는 따라가지 않는다 — 다시 입력(의도).
- **PC 앱에서는 키를 저장하지 않는다**: `AiSecrets.set_key` 는 `Platform.is_phone()` 이 아니면(시험 훅 제외) 거부 — PC 의 `user://` 와 PC 앱 설정이 키를 갖게 되는 경로를 막는다.

### 2.4 키 노출 규칙 (로그·동기화·백업·스크린샷)
| # | 규칙 | 시험·확인 |
|---|---|---|
| K1 | 키는 `Store.prefs`·`progress`·`studylog`·`diary.json`·`user://*.json` 어디에도 없다. 오직 `AiSecrets` 파일. 설정에는 프리셋 id·모델·`"키 있음"` 불리언 정도만 | `SyncDoc.extract` 결과·`Store.prefs` JSON·모든 `user://test_*` 파일에서 가짜 키 마커 0건(`AiSecrets` 파일 제외, 그 파일도 마커 평문 0건) |
| K2 | **동기화에 섞이지 않는다**: 새 prefs(`ai_*`, `phone_ai_consent`, `phone_diary_trains_ok`, `score_where`, `stt_*`)는 `SyncDoc.SHARED_PREFS`(`daily_goal_min, lesson_source, auto_fix_cards, tts_voice_en, tts_voice_ja, tts_speed`)에 없다. 시험이 교집합 0 을 단언하고, prefs 에 일부러 `ai_key` 를 넣어도 `SyncDoc` 직렬화에 안 나옴을 단언 | PI1·PSI 시험 |
| K3 | 로그: `print`·`push_warning`·`push_error`·`printerr`·`Toast` 에 키·요청 본문·메시지·프롬프트·사용자 글을 쓰지 않는다. 개발 로그는 `err_code`·HTTP 상태·`ms` 같은 숫자·코드만 | 정적 검사(`rg`)와 시험 stdout 캡처에서 마커 0건, 실기 `adb logcat -d` 에서 마커·키 조각 0건(H8) |
| K4 | **리다이렉트에 키를 따라 보내지 않는다**: `HTTPRequest.max_redirects = 0`(기본 8은 같은 헤더로 따라갈 수 있음 — **추측: 동작 확인 필요, 어쨌든 0 으로**). 3xx 응답은 `ai_overload` 류 오류로 처리 | 가짜 서버가 302 를 주고 대상 호스트가 받은 요청 0건·Authorization 0건 |
| K5 | 업체 오류 본문을 그대로 화면·로그에 내보내지 않는다(키 일부가 에코될 수 있음 — OpenAI 형식 401 은 키 앞뒤 조각을 말해 준다). 상태 코드·분류 코드만 한국어 문구로 바꿔 보이고, 내부 문자열에서는 키 전체와 8자 이상 부분 문자열을 `<key>` 로 치환(서버 `llm_api._fail` 과 같은 방침) | 가짜 서버가 키를 에코하는 오류를 줘도 화면·`err_body` 에 0건 |
| K6 | 화면: 입력칸 `LineEdit.secret = true`, 저장 즉시 칸을 비우고 이후에는 마지막 4자(`••••abcd`)만 보인다. 한 번 저장한 키를 전체 다시 보여 주는 기능 없음(바꾸려면 새로 입력). 클립보드: 붙여 넣은 직후 클립보드가 키와 같으면 비운다(해시 비교, `AiConnectSheet` 의 `_key_hash` 방식) | 시트 시험이 모든 `Label`/`Button`/`LineEdit` 글을 훑어 키 0건 |
| K7 | 스크린샷·최근 앱 미리보기: Godot 는 플러그인 없이 `FLAG_SECURE` 를 못 켠다 **(추측: 4.6 에 프로젝트 설정 없음 확인 필요)**. 완화: 키 입력 시트는 저장 즉시 닫고 칸을 비운다. **한계를 문서·카드에 적는다**("키를 입력하는 동안에는 화면 캡처를 하지 마세요") | 문구 존재 확인 |
| K8 | 키는 `AiClient` 가 요청을 보내는 **마지막 순간**에만 `AiSecrets.get_key` 로 꺼내 헤더에 넣는다. 다른 객체의 멤버·시그널·`Dictionary` 에 담지 않는다. 오류 결과 객체에도 헤더를 넣지 않는다 | 정적 검사 + 시험 |
| K9 | `https://` 만 허용(프리셋 기본). 사용자 지정 base URL 은 `https://` + 호스트에 사용자 정보(`user:pass@`) 없음 + 저장 전에 "이 주소로 키를 보냅니다: <호스트>" 확인. TLS 검증은 끄지 않는다. TLS 실패 시 "폰의 날짜·시간이 맞는지 확인" 안내 | 시험 |
| K10 | 공개 스크립트의 키 모양 검사를 통과: 시험 픽스처의 가짜 키는 `FAKEKEY_ZZ_<무작위 영숫자>` 꼴(`sk-`·`AIza` 로 시작하지 않음) | `git grep -I -n -E "<publish 키 정규식>"` 0줄 |
| K11 | "모든 기록 지우기"는 키를 지우지 않는다(별도 [키 지우기]). 지우기 확인 문구에 "AI 키는 그대로예요"를 적는다 | 시험 |
| K12 | PC 앱·PC↔폰 동기화·업데이터·`build_dist` 가 키 파일을 만지지 않는다. `sanitize_prefs.py`(공개 빌드 기본 설정 정리)가 `*_consent` 를 지우는 규칙은 새 이름 `phone_ai_consent` 에도 적용된다 | 시험 + 이름 규칙 |

### 2.5 프롬프트·검증 공유: GDScript 로 복사하고 황금 파일로 맞춘다
- **원칙**: 서버(`server.py`)는 한 줄도 바꾸지 않는다(v200 R1 서버 변경 0, R2 가 `/chat` 을 고칠 예정). 폰은 **같은 동작을 문장 단위로 옮기고**, 서버 함수를 직접 호출해 만든 **황금 파일**과 비교한다. 서버가 바뀌면 `--check` 가 깨져 알려 준다(드리프트 감지).
- **옮길 목록(출처 행)**: `LEVEL`(1551), `context_text`(1564, `curriculum.json` 은 PC·폰이 같음 F-P21), `rules_text`(1773~1804), `clean_hist`(1807), `ko_ok`·`scrub_ko`·`FOREIGN_SCRIPT`(1821~1857), `looks_like_question`(1885), `CHAT_SCHEMA`·`FIX_SCHEMA`·`FEEDBACK_SCHEMA`(1749~1757), `run_chat` 의 **`openai_api` 경로**(1993~2062: 메시지 조립, 재시도 2번, `bad` 판정 규칙), `_llm_correct`(1928~1970: 프롬프트·`fix_valid`·재시도), `run_feedback`(2065~2114), `missions.judge_goals`·`_judge_messages`·`_quoted_in`(`missions.py` 405~472), `llm_api.call_json` 의 시스템 지시 덧붙이기·`response_format` 재시도(152~188), `llm_common.extract_json`(코드펜스·`<think>`·말미 쉼표·곡선따옴표 복구). 텍스트 정규화(`norm_text`)는 기존 `TextSim.norm_text` 를 쓰고 차이는 황금 파일이 드러낸다.
- **일부러 다른 점(문서에 고정, 시험이 확인)**: ① LanguageTool 없음 → `correct_learner` 는 항상 `_llm_correct(lt_fix="")` 경로(서버가 LT 없을 때 하는 일과 같음) ② OpenCode 세션 경로(`_chat_opencode`)·캐시(`llm_cache`)·`presynth`/`tts_chunks` 없음 ③ 일본어 없음(`reading`/`pron` 은 영어에서 항상 `""`) ④ 폰은 호출마다 `AiClient` 오류 분류를 `Route` 오류 코드로 바꿔 돌려줌.
- **황금 파일 생성기** `phone_src\tools\make_ai_golden.py`(새): `backend\server.py` 를 **프로세스 안에서** 불러(네트워크·포트 없음, `socket` 생성 시 예외로 막음) ① `CFG["llm_provider"]="openai_api"` ② `server._remote_json` 을 가짜 엔진으로 바꿔 **엔진에 간 `messages`·`schema`·`temperature` 를 기록**하고 사례별로 준비한 **가짜 모델 답**(정상·한글 섞임·`ko` 누락·JSON 아님 등)을 돌려줌 ③ `grammar.correct` 를 `None` 으로 ④ 결과 사전과 **시도 횟수**를 기록. 사례 입력은 `ai_golden_cases.json`(생성기와 같이 추적). 출력은 `godot\tests\fixtures\ai_golden\` 아래 JSON(추적). 형식(예):
```json
{"case":"chat_en_stage2_q","kind":"chat","req":{"lang":"en","stage":2,"month":4,"week":2,"scenario":{"id":"cafe_order"},"history":[{"role":"me","text":"Can you tell me what a latte is?"}]},
 "engine":[{"messages":[{"role":"system","content":"..."}],"schema":{...},"temperature":0.6,"reply":{"reply":"...","ko":"...","suggest":["a","b"]}}],
 "expect":{"result":{"reply":"...","reading":"","pron":"","ko":"...","fix":"","fix_ko":"","suggest":["a","b"]},"attempts":1}}
```
  `--check` 는 메모리에서 다시 만든 결과가 저장된 파일과 같은지 비교(다르면 종료 1, 어느 사례인지 코드만 출력). 새 서버 변경(예: v200 R2 `course` 필드)이 들어가면 `--check` 가 실패하고 PI-L 작업이 갱신한다.
- **GDScript 쪽 시험**(`ai_chat_parity_test` 등): 같은 사례 파일을 읽어 `AiClient` 자리에 **기록용 가짜 전송**을 꽂고, ① 엔진에 보낸 `messages` 가 **문자열까지 같은지** ② 결과 사전이 같은지 ③ 시도 횟수가 같은지를 단언한다.
- **R2 연결(수준 맞춤 대화 이식, PI-L)**: v200 §5 의 `course` 필드·`level_check`·`help_ko`·안전 대사는 서버에 R2 가 들어간 **뒤**에 같은 방식(황금 파일 `--check` → GDScript 이식 → 시험)으로 폰에 옮긴다(2.1.0). `course_levels.json`(서버 쪽 빌드 사본)은 폰이 `res://data/course\` 의 낱말 목록에서 직접 만든다(PI-L 이 결정). 그때까지 폰 `/chat` 의 `course` 필드는 무시하고 `legacy_stage` 로 기존 `LEVEL` 을 쓴다.

### 2.6 개인정보: 흐름과 동의 문구
- **흐름**: 대화·교정·일기 글은 **폰 → 선택한 업체**로만 간다. 폰의 로그·캐시·`user://` 어디에도 남기지 않는다(대화 기록은 기존대로 화면 메모리뿐, 일기 원문은 기존 `user://diary.json` 한 곳). 앱이 운영하는 서버는 없다.
- **동의 문구를 바꿔야 하나? — 예.** 현재 일기 동의는 "쓴 문장이 AI 서비스로 전송돼요. (이 PC의 로그·캐시에는 남지 않아요.)"(`diary_screen.gd` 24행)로 **PC 경로 전제**다. 폰 직접 경로는 업체가 다르고 보관·학습 정책이 업체마다 다르므로 **새 폰용 문구**가 필요하다(PWI 가 `CONSENT_PARAS_PHONE` 추가). PC 경로 문구는 그대로.
- **새 동의 두 개**(설정 `phone_ai_consent`: `{ "<preset>": true }`, 이름이 `_consent` 로 끝남):
  1. **키를 저장할 때(프리셋별)**: "대화·교정·피드백·일기에 쓴 문장이 이 휴대폰에서 **{업체}** 서버로 직접 전송돼요. 이 앱은 문장을 폰에 기록하지 않지만, {업체}의 보관·학습 정책은 그 업체를 따라요. 요금은 키 주인에게 청구돼요. 업체 사이트에서 지출 한도를 걸어 두세요." + 프리셋별 한 줄(아래). [동의하고 저장] [취소].
  2. **일기를 처음 고칠 때(기존 `diary_consent` 와 별개)**: "일기 내용이 {업체}로 전송돼요. 이 폰의 로그·캐시에는 남지 않고 일기 원문은 이 기기에만 저장돼요. 고친 문장은 복습 카드가 되어 PC·폰에 동기화돼요(원문은 아니에요)."
- **프리셋별 한 줄**: `gemini`(무료 등급) — "구글 무료 등급은 보낸 내용을 서비스 개선에 쓸 수 있다고 문서에 적혀 있어요. 개인적인 글은 유료 등급 키나 다른 업체를 쓰세요."(문서 근거, §10) / `deepseek` — "DeepSeek 서버는 중국에 있고, API 의 데이터 정책은 문서에서 확인하지 못했어요." / `opencode_zen` — "유료 모델의 데이터 정책은 확인하지 못했어요. 업체 문서를 확인하세요." / `openrouter` — "모델 제공자에 따라 달라요."
- **무료 등급이 학습에 쓰는 업체는 일기 교정이 기본 꺼짐**: `AiPresets` 에 `trains_free:true`(Gemini) 표시, 이 프리셋일 때 일기의 [고쳐 보기]는 꺼지고 "이 업체는 보낸 글을 학습에 쓸 수 있어요. 일기는 저장만 해요" 한 줄 + 사용자가 별도 스위치(`phone_diary_trains_ok`)를 켜고 확인 시트에서 동의해야 켜진다. 대화·피드백은 §1번 동의로 충분.
- 폰에서 일기 `/fix` 는 항상 `private:true` 의 의미(캐시·로그 없음)를 코드로 지킨다: 응답 키 `fix, fix_ko, reading, pron`(영어는 `""`)을 서버와 같이 돌려주고, 폰은 애초에 캐시·로그가 없다.
- 영어 일기·대화만. 일본어 요청은 `ja_ai_pc`.

### 2.7 실패 처리: 안내 문구와 동작
| 상황(`err_code`) | 판별 | 안내 문구(한국어, `Route.ERR_TEXT`) | 동작 |
|---|---|---|---|
| 키 없음(`no_ai`) | `AiState` 가 `none` | "AI를 쓰려면 설정 > AI 연결에서 본인 AI 키를 한 번 넣어 주세요. PC에 연결해도 돼요. 키 없이도 '대본 대화'로 연습할 수 있어요." | **네트워크 0건**. 일기는 "저장만"(기존). 미션은 대본 모드(기존) |
| 오프라인(`ai_offline`) | `HTTPRequest` 연결·이름 확인 실패 | "인터넷에 연결돼 있지 않아요. 와이파이나 데이터를 켠 뒤 다시 시도해 주세요. 지금은 '대본 대화'로 연습할 수 있어요." | 재시도 자동 없음. 일기 `saved` 유지 |
| 보안 연결 실패(`ai_tls`) | TLS 핸드셰이크 오류 | "보안 연결에 실패했어요. 폰의 날짜와 시간이 맞는지 확인해 주세요." | 키 안 보냄(핸드셰이크 전) |
| 키 오류(`ai_auth`) | HTTP 401·403 | "키가 맞지 않아요. 설정 > AI 연결에서 키를 다시 넣어 주세요." | 카드에 빨간 상태. 키는 그대로(사용자가 바꿈) |
| 한도·잔액(`ai_limit`) | 402·429·"quota/insufficient/balance/rate limit" | "{업체} 사용 한도(또는 잔액)에 도달했어요. 잠시 뒤 다시 시도하거나 업체 사이트에서 잔액을 확인해 주세요."(`Retry-After` 가 있으면 "N분 뒤") | 자동 재시도 없음(요금 보호) |
| 서버 바쁨·시간 초과(`ai_overload`) | 5xx·타임아웃(90초)·3xx | "AI 서버가 바빠요. 잠시 뒤 다시 시도해 주세요." | 자동 재시도 없음 |
| 모델 없음(`ai_model`) | 404·"model not found" | "AI 모델 '{모델}'을(를) 찾을 수 없어요. 설정 > AI 연결에서 모델을 다시 골라 주세요." | 카드로 안내 |
| 답 형식 오류(`bad_format`) | JSON 추출 실패 | "AI 답변 형식이 맞지 않아요. 다시 시도해 주세요." | 서버처럼 **엄격 지시를 붙여 1회만** 재요청, 그 뒤 오류. 무한 재시도 없음 |
| 일본어(`ja_ai_pc`) | `lang != "en"` | "일본어 AI 대화는 아직 PC에서만 돼요." | 네트워크 0건 |
| 키 형식 불량(`ai_key_format`) | 저장 때 검사(공백·줄바꿈·`Bearer `·따옴표·길이) | "키 형식이 올바르지 않아요. 복사한 키를 그대로 붙여 넣어 주세요." | 저장 안 함 |
| 주소 불량(`ai_url`) | `http://`·`file://`·사용자 정보 포함 | "주소가 안전하지 않아요. https:// 로 시작하는 주소만 쓸 수 있어요." | 저장 안 함, 요청 0건 |
- 어느 경우도 키·본문을 로그·토스트에 쓰지 않는다. 오류 화면의 글은 위 표의 고정 문구다.

### 2.8 계약 (이름·형식 고정, 모두 새)
```
AiPresets (scripts\local\ai_presets.gd, static)   presets() -> Dictionary  # llm_api.py PRESETS 와 같은 id/label/base_url/model + {"trains_free":bool,"single_system":bool,"note_ko":String}
AiSecrets (scripts\local\ai_secrets.gd, static)   path="user://ai_secrets.bin"(시험 user://test_ai_secrets_*.bin)
    has_key(preset) -> bool ; set_key(preset, key) -> {ok, err_code:"ai_key_format"|"io"|"not_phone"} ; get_key(preset) -> String  # AiClient 전용
    clear_key(preset) -> bool ; last4(preset) -> String
AiJson (scripts\local\ai_json.gd, static)         extract(text) -> {ok, data:Dictionary}   # llm_common.extract_json 이식
AiClient (scripts\local\ai_client.gd, RefCounted) static var test_allow_http := false
    complete_json(preset, model, base_url, messages, schema, temperature, max_tokens, timeout) -> Dictionary   # 코루틴
        → {ok, data:Dictionary, err_code:""|ai_auth|ai_limit|ai_overload|ai_offline|ai_tls|ai_model|ai_url|bad_format|ai_cancelled, error:String(한국어), status:int, retry_after:int}
    cancel() -> void
AiState (scripts\core\ai_state.gd, static)        use(lang:String) -> {"use":"pc"|"phone"|"none", "why":String, "preset":String}   # Route.caps + AiSecrets + prefs 로 한 곳에서 판정
LocalAi (scripts\local\local_ai.gd, LocalApi 핸들러)   handle / is_available / unavailable_reason / is_available_for(path, query, body)
    /chat, /fix(private 포함), /feedback, /missions/judge 만. POST /lesson(source ai) 는 is_available_for=false
AiChatRules (scripts\local\ai_chat_rules.gd, static)   rules_text, clean_hist, ko_ok, scrub_ko, looks_like_question, run_chat(req, client), correct(...), …
AiFeedbackRules (scripts\local\ai_feedback_rules.gd, static)   run_feedback(req, client), judge_goals(req, client)
```
- 새 prefs(모두 동기화 화이트리스트 밖):
| 키 | 값 | 기본 |
|---|---|---|
| `score_where` | `"phone"` / `"pc"` | `"phone"` |
| `stt_model` | 모델 id | `"whisper-base.en-q5_1"` |
| `stt_phone_off` | bool(자동으로 끔) | false |
| `ai_local` | `"none"` / `"openai_api"` | `"none"` |
| `ai_preset`, `ai_model`, `ai_base_url` | 프리셋 id / 모델 이름 / 사용자 지정 `https://` 주소 | `""`, `""`, `""` |
| `phone_ai_consent` | `{"<preset>": true}` | `{}` |
| `phone_diary_trains_ok` | bool | false |
- 새 파일(앱 비공개 저장소): `user://ai_secrets.bin`, `user://ai_salt.bin`, `user://models/*`.

---

## 3. 폰 우선 화면 점검: "PC에 연결하면…" 안내가 나오는 곳

폰 단독(또는 PC 없음)일 때 PC 연결을 안내하거나 AI 상태를 PC `/health` 로만 보는 곳(코드 검색으로 찾음, 줄 번호는 `b32cd84`)과 P-ASR·P-AI 가 들어올 때의 변화. 담당 작업은 §5.

| # | 위치 | 지금 | P-ASR 가 들어오면 | P-AI 가 들어오면 | 담당 |
|---|---|---|---|---|---|
| 1 | `autoload\route.gd` 69~85행 `ERR_TEXT` 의 `not_on_phone`·`needs_pc`·`model_missing`·`engine_missing`·`no_ai`·`ja_reading_pc`(+ `ERR_HTTP`, `DEGRADED`) | "PC에 연결했을 때만 돼요", `no_ai` 는 **없는 설정을 안내(F-P3)** | `model_missing`("설정 > 음성 인식에서 …")는 사실이 되므로 유지, `engine_error`·`stt_timeout`·`no_space` 추가 | `no_ai` 문구 교체, `ai_offline`·`ai_tls`·`ai_model`·`ai_key_format`·`ai_url`·`ja_ai_pc` 추가 | **P0** |
| 2 | `ui\capability_panel.gd` 35~47행 `REASONS` | "PC에 연결하면…", `no_ai`: "PC에 연결하거나 AI 키를 넣어 주세요" | `model_missing`·`model_corrupt`·`engine_missing` 문구를 폰 기준으로, "처리 위치" 카드에 `score_where` 라디오 | `no_ai` 를 "설정 > AI 연결에서 키를 넣어 주세요"로, 항목 `chat/fix/feedback` 이 `phone` 으로 보이게 | **PSA / PSI** |
| 3 | `ui\self_rate_panel.gd` 18~20행(`PROSODY_REASON`·`PHONEME_REASON`·`INTRO_TEXT`) | "점수는 PC에 연결하면 볼 수 있어요" | 모델 없음 이유면 **[음성 인식 모델 받기(약 60 MB)]** 버튼 + "받으면 폰에서 점수를 볼 수 있어요". 음소·억양 줄("PC 연결 시")은 그대로(범위 밖) | - | **PWA** |
| 4 | `practice\shadow_screen.gd` 562행 | "지금은 점수를 낼 수 없어요(점수는 PC 연결 시)…" | 이유별 문구(모델 없음/엔진 없음) | - | **PWA**(`after=E7`) |
| 5 | `song\song_sing_tab.gd` 12행 `SELF_NOTE` | "점수는 PC 연결 시" | 영어 노래는 폰 채점이 되므로 문구 갱신. **일본어 노래는 계속 PC 전용**(`is_available_for` 가 false) | - | **PWA** |
| 6 | `views\lesson_view.gd` 850·1192행, `views\review_view.gd`, `practice\speak_drill.gd` 327행(채점할 곳이 없으면 `_begin_self_rate`) | `Route.caps()["items"]["score"]["use"]=="none"` 일 때 자가 평가 | **코드 변경 없음**: 폰 모델이 `ready` 면 `score` 가 `phone` 이라 자동으로 채점 경로. 말하기 문제가 점수 화면으로 바뀌는 것을 시험(PWA)이 확인. `lesson_view.gd` 는 v200 E5 소유라 **건드리지 않는다** | - | (시험만 PWA) |
| 7 | `ui\score_panel.gd` | 점수 표시 | 결과 `via=="phone"` 이면 점수 옆 작은 글씨 **"폰 간이 채점"**(phone_standalone §3.3 에서 약속했으나 아직 없음) | - | **PWA** |
| 8 | `practice\speak_drill.gd` `request("/score")` 본문 | 항상 같은 본문 | `source=="drill"` 이고 `lang=="en"`(영어 약한 소리 화면, `phoneme_screen.gd` 294행)일 때만 `need_ph:true` 추가. 일본어 `ja_sound_screen.gd` 438행도 `"drill"` 이지만 폰 채점이 영어뿐이라 영향 없음 | - | **PWA** |
| 9 | `practice\diary_screen.gd` 24~33행 상수·154~168행 `ai_state`/`fix_private_ok`·171~178행 `stt_ok` | 폰 단독은 "저장만", `NOTE_NO_PC`("AI로 고치려면 PC에 연결해야 해요"), `NOTE_NO_MIC`("음성 입력은 PC에 연결했을 때만") | `stt_ok()` 가 폰 `stt` 경로도 허용(음성으로 쓰기) — 영어만 | `ai_state()`/`fix_private_ok()` 가 폰 경로(`AiState`)를 인정, 동의 문구 폰용 추가(§2.6), 무료 학습 업체는 기본 꺼짐, `NOTE_NO_PC` 문구에 "설정 > AI 연결" 선택지 추가 | **PWI**(`after=E7`) |
| 10 | `practice\mission_screen.gd` 17~18행·312~315행 `_llm_down()` | `Backend.llm_missing()`(PC 상태만) | - | `AiState.use("en")` 를 함께 봐서 폰 AI 가 있으면 AI 모드 허용 | **PWI**(`after=E7`) |
| 11 | `views\talk_view.gd` 600·660·913행(`/chat`·`/fix`·`/feedback`) | AI 가 없으면 오류 문구만 보임 | - | **코드 변경 없음**(Route 가 폰으로 보냄, 오류 문구는 P0 의 새 `no_ai` 등). `talk_view.gd` 는 v200 E7 소유라 건드리지 않는다. "대본 대화" 목록(phone_standalone C3)은 **범위 밖**(미구현 상태 유지) | - |
| 12 | `core\home_ai.gd` 66~85행·`ui\ai_connect_sheet.gd` 108~119행 `home_slot` | 폰이면 "PC의 회화 연습 설정에서 AI 연결하기를 눌러 주세요" | - | 폰에 키가 없으면 "AI 연결이 필요해요 / 설정에서 AI 키를 넣어요"(+ 액션이 설정 카드로), 있으면 숨김 | **PWI** |
| 13 | `main.gd` 548~560행 `_on_ai_connect()`(폰이면 PC 시트 또는 연결 화면), 660~690행 배너, 979행 시작 화면 안내("레슨·대화·음성은 PC에 연결된 뒤에 써요" — 1.3 이후 사실과 다름) | 폰은 항상 PC 안내 | - | `_on_ai_connect()` 가 폰이면 설정의 AI 카드를 연다. 979행 문구는 폰 단독 가능을 반영 | **PWI**(`after=E6`) |
| 14 | `autoload\backend.gd` 50~57행 `llm_missing()`, 61행 `NOT_CONNECTED_PHONE_TEXT`, 81~93행 `llm_missing_text()` | PC `/health` 전용, 폰이면 "PC의 회화 연습 설정에서 'AI 연결하기'" | - | 폰 AI 가 있으면 `llm_missing()` 이 false 가 되게(또는 호출부가 `AiState` 를 함께), 폰 문구 교체 | **PWI** |
| 15 | `views\settings_view.gd` 486~496행(처리 위치 설명)·739~741행(AI 힌트)·엔진 섹션의 `ai_connect_card.gd`(PC 전용 카드) | PC 연결·AI 상태만 | 새 카드 **"음성 인식(채점 모델)"**(`stt_model_card.gd`), `score_where` 라디오 | 새 카드 **"AI 연결(이 폰)"**(`phone_ai_card.gd`); PC 용 카드는 PC 에서만 | **PSA / PSI** |
| 16 | `practice\phoneme_screen.gd` 646행·`practice\ja_sound_screen.gd` 937행("소리별 분석/판정은 PC에 연결하면") | PC 연결 안내 | **그대로**(음소·억양·일본어는 범위 밖, `need_ph` 로 PC 우선) | - | 변경 없음 |
| 17 | `song\song_meaning_tab.gd`·`song_memo_screen.gd`·`song_search_screen.gd`·`views\song_view.gd`("PC에 연결하면 해석/AI로 더 찾을 수 있어요", "곡 추가는 PC 연결 시") | PC 안내 | 변경 없음 | **변경 없음**(노래 AI·곡 추가는 범위 밖) | - |
| 18 | `practice\dictation_screen.gd` 20행·`ja_sound_screen.gd` 25행 `NO_VOICE_TEXT`("…PC에 연결해 주세요") | TTS 음성 데이터 안내 | 변경 없음(TTS 는 별개) | 변경 없음 | - |
| 19 | `README.md` 폰 단독 절(47·155행 부근), `INSTALL.md` 폰 단독 절 | 1.3 기준 | 2.0.1 설명(모델 내려받기·채점 위치·한계) | 2.0.2 설명(AI 키 넣기·개인정보·요금·한계) | **PZ**(`README.md`·`ROADMAP.md` 는 `after=Z`) |
- 다른 곳(Api 의 `UNREACHABLE_TEXT`, 연결 화면, 동기화·Tailscale 안내)은 PC 와 실제로 연결하는 흐름이라 그대로다.

---

## 4. 출시 계획 통합 (v200 §12 R1~R4 와 묶기)

### 4.1 추천안
| 릴리스 | v200 | 폰 추가(이 문서) | 이유 |
|---|---|---|---|
| **2.0.0** | R1(0단계+1~3개월, 1~16주) | **없음**(코스 화면은 v200 이 이미 412x915·폰 시험을 포함) | 2.0.0 범위를 키우지 않는다. 폰 네이티브·키 작업의 위험이 R1 콘텐츠 일정을 끌지 않게 분리 |
| **2.0.1** | (패치) | **P-ASR**: P0, PA1~PA5, PA7, PSA, PWA, PZ(ASR 절) | 말하기 사다리 L1(따라 말하기)이 **1주차부터**이고 하루 45분 중 12분이 말하기다. 문장 채점이 의미 있어지는 때는 5주차(문장 단계) — 제때 공부하는 사용자는 2.0.0 공개 후 약 4주에 닿으므로 **2.0.0 공개 후 4주 안**이 목표 |
| **2.0.2** | (패치) | **P-AI**: PI1~PI3, PSI, PWI, PZ(AI 절) | 안내형 AI 대화(L5)는 17주차부터, 일기는 지금도 있다. R2(2.1.0)까지 **12주 안** 목표(= 간격 규칙). 네이티브 없이 GDScript 만이라 PA 와 독립 |
| **2.1.0** | R2(17~32주 + 수준 맞춤 AI 대화) | R2 + **PI-L**(수준 맞춤 대화 폰 이식: 황금 파일 재생성 → `course`·`level_check`·`help_ko` GDScript 이식) | v200 §5 가 서버에 들어간 뒤여야 하므로 R2 와 같이 |
| **2.2.0 / 2.3.0** | R3 / R4 | 폰 추가 없음(모델·프리셋이 낡으면 `models-2`·프리셋 갱신) | |
- **번들 B(릴리스 수를 줄이고 싶을 때)**: 2.0.1 = P-ASR, 2.1.0 = P-AI + R2 + PI-L. 2.0.2 를 건너뛴다. 단점: 폰만 쓰는 사용자의 일기 AI 교정·대화가 12주 더 늦다.
- **2.0.0 에 P-ASR 을 넣는 조건(오케스트레이터 판단)**: 2.0.0 동결 1주 전까지 PA 합격 조건 전부 O + 사용자 실기 H1~H6 통과 + 검토 통과. 그렇지 않으면 2.0.1. **G1 이 no-go 이면 P-ASR 은 보류**(자가 평가 유지)하고 P-AI 만 진행한다.
- 각 릴리스는 v200 §12 의 간격 규칙(첫 주 도달 4주 전 공개)을 지킨다. 18개월 매일 폰 사용을 전제로, **업데이트는 APK 직접 설치**(GitHub 릴리스)이므로 사용자가 직접 받아 설치해야 한다 — 릴리스 노트에 "2.0.1 에서 폰 채점이 생겼어요. 설정 > 음성 인식에서 모델을 받으세요" 같은 한 줄을 넣는다(모델은 업데이트로 사라지지 않음: `user://models/` 유지, 같은 서명 키라 덮어쓰기 설치).
- 공개 점검(CLAUDE.md 체크리스트): 올라갈 파일 목록에 `godot\bin\*`, `*.gdextension`, `native\_deps`, 모델 `*.bin`, `phone_src\calib` 의 오디오, 키·`ai_secrets.bin` 이 없어야 한다(`git ls-files` 직접 확인 + `publish_release.ps1 -ScanOnly` + `check_no_media.ps1`). 릴리스 후 APK 링크를 열어 내려받기, `models-1` 자산 링크 열기(상대 미러 포함), 업데이트 확인.

---

## 5. 작업 분할

### 5.1 규칙 (모든 작업 공통)
- 담당: **`worker-hard`**(네이티브·오디오·동시성·네트워크·비밀값·인증/개인정보·빌드/설치: P0, PA1~PA5, PA7, PI1, PI2a~c, PI3, PWI) / **`worker`**(화면 문구·연결·문서: PSA, PSI, PWA, PZ). 검토는 `reviewer`(§5.4).
- 작업마다 별도 worktree `D:\Ai\언어\app_wt\v200p_<작업>`, 브랜치 `v200p/<작업>`(**`v200_*` 와 겹치지 않게 `p` 를 붙인다.** 기존 `v200_e1`·`v200_e2`·`v200_k0`·`v200_k1`·`ja_*`·`ss_*`·`inst_*`·`rev_base` 는 건드리지 않는다). 오케스트레이터가 §5.2 순서로 합친다. 다른 작업의 파일은 읽기만, 고칠 일이 생기면 오케스트레이터에게 보고한다.
- 임시 파일·로그·가짜 APPDATA·모델·오디오는 `<scratchpad>\w_<작업>\` 안에만. 시험이 쓰는 사용자 파일은 `user://test_*` 만. **원고·모델·오디오·키는 저장소에 올리지 않는다.**
- 공통 합격 조건·시험 명령 형식은 `docs\v200_design.md` §14.1 의 **C-0~C-17 을 그대로** 적용한다(기준선, 마지막 줄 `N passed, 0 failed`, `SCRIPT ERROR:` 0, `TEST_GUARD on` 1줄, 소유 밖 수정 0, `project.godot` 변경 0, 실제 사용자 폴더 쓰기 0, 상수 변이 확인 C-12, 실제 버튼 시험 C-14, 읽을 수 있는 단위 C-15 …). **예외**: C-4 의 "새 파일에 `HTTPRequest` 0줄"은 `ai_client.gd`(HTTPRequest)와 `model_store.gd`(HTTPClient)만 허용한다. 추가 공통 조건은 §6.1.
- 새 `class_name` 스크립트를 더한 뒤 `godot --headless --path <worktree>\godot --import` 한 번(자기 새 파일의 `.uid` 짝만 같이 둠). 새 시험은 `.gd` + `.tscn` 짝.
- 이 PC 의 안드로이드 SDK·JDK 는 Claude 앱 가상 LocalAppData 아래이므로(F-P13) APK 내보내기는 오케스트레이터가 준비한 scratch APPDATA 방식으로 한다. 워커는 그 환경을 지시에 받는다.

### 5.2 의존 순서와 병렬
```
0파 (오케스트레이터, 코드 없음): ★승인 요청(§9) · C0 공급자 시험(사용자 키, §6 PI0) · 모델 파일 sha256 확정(★다운로드 승인)
1파 (v200 1파 K1·K0·E1·E2 와 동시, 파일 겹침 0):  P0 ∥ PA1(스파이크→G1) ∥ PA2 ∥ PI1 ∥ PI2a
   ── 게이트 G1: PA1 스파이크 + 사용자 실기 H1. no-go 면 PA2~PA7·PSA·PWA 중단, PI 는 계속
2파 (P0·PI1·PI2a 병합 뒤 / G1 통과 뒤):  PA3 ∥ PA4(PA1·PA2·PA3 계약 필요) ∥ PI2b ∥ PI2c ∥ PI3
3파:  PA5(보정, PA1 전체·PA4·모델 파일·사용자 녹음 필요) ∥ PA7(PA1 필요) ∥ PSA(PA3) ∥ PSI(PI3)
4파 (v200 E6·E7 이 main 에 병합된 뒤):  PWA ∥ PWI
5파:  PZ(v200 Z 병합 뒤) → reviewer 독립 검토 → 사용자 실기 H 목록 → 통합 시험 T → 릴리스(오케스트레이터)
```
| 작업 | 선행 | 동시에 해도 되는 것 | 비고 |
|---|---|---|---|
| P0 | 없음 | PA1, PA2, PI1, PI2a, v200 1파 | `route.gd`·`api.gd` 의 유일한 소유자 |
| PA1 | ★승인(NDK·소스·scratch SCons) | P0, PA2, PI1, PI2a | 스파이크(G1)까지가 1단계, 전체 구현이 2단계 |
| PA2 | 없음 | 전부 | 순수 GDScript + 파이썬 황금 생성기 |
| PA3 | P0(오류 코드 이름) | PA4 와 계약만 맞춰 병행 | `models.json` 의 sha256 은 오케스트레이터가 채워 줌(★) |
| PA4 | P0, PA2, PA3(`ModelStore` 계약), PA1(브리지 계약 §1.4; 시험은 가짜 브리지) | PI2b, PI2c, PI3 | |
| PA5 | PA1(전체), PA4, 모델 파일, ★사용자 녹음 | PA7, PSA | |
| PA7 | PA1 | PA5, PSA | `export_presets.cfg`·`build_android.ps1` 의 유일한 소유자 |
| PI1 | 없음 | 전부 | |
| PI2a | 없음 | 전부 | 서버를 읽기만 하는 생성기 |
| PI2b | PI1, PI2a(픽스처 형식) | PI2c, PI3, PA* | |
| PI2c | PI1, PI2a | PI2b, PI3 | `local_ai.gd` 는 PI2b 소유 — PI2c 는 별도 파일을 `load()` 경로로 연결 |
| PI3 | PI1 | PI2b, PI2c | 화면 부품만(설정 연결은 PSI) |
| PSA | PA3 | PA5, PA7 | `settings_view.gd`·`capability_panel.gd` 의 첫 소유자 |
| PSI | PI3, PSA | PWI | `after=PSA` |
| PWA | PSA, PA4, **v200 E7 병합** | PWI | `shadow_screen.gd` 는 `after=E7` |
| PWI | PSI, PI2b, PI2c, **v200 E6·E7 병합** | PWA | `diary_screen.gd`·`mission_screen.gd`=`after=E7`, `main.gd`=`after=E6` |
| PZ | 해당 릴리스 작업 전부, **v200 Z 병합** | - | README·ROADMAP 은 `after=Z` |
- v200 1파(K1, K0, E1, E2)와 **파일이 하나도 겹치지 않는다**(소유권 스크립트가 확인). v200 E4a·E4b·E5(`lesson_view.gd`)·E6·E7 은 `route.gd`·`local_api.gd`·`speak_drill.gd` 를 읽기만 한다: P0·PWA 가 이 파일을 바꾸면 그 v200 작업들이 쓰는 **공개 시그니처는 그대로**여야 한다(P0-9, PWA-6). v200 작업이 병합되기 전에 P0 가 먼저 병합돼도 충돌이 없다(서로 다른 줄).

### 5.3 소유권 표 (수정 허용 파일. 이 밖은 수정 금지)
| 작업 | 수정(기존) | 새 파일 |
|---|---|---|
| P0 | `autoload\route.gd`, `autoload\api.gd`(재시도 함수 범위만), `tests\route_test.gd`(단언 추가만) | - |
| PA1 | `.gitignore`(추가만) | `native\whisper_bridge\` 의 CMake·`build.ps1`·`.gdextension.in`·`BUILD_INFO.json`·`README.txt`·`THIRD_PARTY.txt`·`src\*`, `tests\native_bridge_test.*` |
| PA2 | - | `core\score_core.gd`, `tests\score_parity_test.*`, `tests\fixtures\score_golden_en.json`, `phone_src\tools\make_score_golden.py`·`test_make_score_golden.py` |
| PA3 | - | `local\model_store.gd`, `ui\stt_model_card.gd`, `data\models.json`, `tests\model_store_test.*`·`stt_model_card_test.*`·`run_model_tests.ps1`, `phone_src\tools\fake_model_server.py` |
| PA4 | - | `local\local_stt.gd`, `tests\local_stt_test.*`, `tests\fixtures\score_params_test.json` |
| PA5 | - | `data\score_params.json`, `tools\calib_phone.gd`, `phone_src\tools\calib_make_set.py`·`calib_record.py`·`calib_pc_run.py`·`calib_fit.py`·`test_calib_fit.py`, `phone_src\calib\README.txt` |
| PA7 | `packaging\build_android.ps1`, `godot\export_presets.cfg`(preset.0 `exclude_filter` 한 줄만) | `packaging\check_phone_native.ps1` |
| PI1 | - | `local\ai_secrets.gd`·`ai_presets.gd`·`ai_client.gd`·`ai_json.gd`, `core\ai_state.gd`, 시험 4종(`ai_secrets_test`·`ai_client_test`·`ai_json_test`·`ai_state_test`), `tests\fixtures\ai_json_golden.json`, `tests\run_ai_tests.ps1`, `phone_src\tools\fake_ai_server.py`·`make_ai_json_golden.py` |
| PI2a | - | `phone_src\tools\make_ai_golden.py`·`ai_golden_cases.json`·`test_make_ai_golden.py`, `tests\fixtures\ai_golden\`(폴더) |
| PI2b | - | `local\local_ai.gd`, `local\ai_chat_rules.gd`, `tests\local_ai_test.*`, `tests\ai_chat_parity_test.*` |
| PI2c | - | `local\ai_feedback_rules.gd`, `tests\ai_feedback_parity_test.*` |
| PI3 | - | `ui\phone_ai_card.gd`, `ui\phone_ai_sheet.gd`, `tests\phone_ai_sheet_test.*` |
| PSA | `views\settings_view.gd`, `ui\capability_panel.gd`, `tests\settings_view_test.gd` | `tests\phone_settings_asr_test.*` |
| PSI | 위 세 파일(`after=PSA`) | `tests\phone_settings_ai_test.*` |
| PWA | `ui\self_rate_panel.gd`, `ui\score_panel.gd`, `practice\speak_drill.gd`, `practice\shadow_screen.gd`(`after=E7`), `song\song_sing_tab.gd`, `tests\self_rate_test.gd` | `tests\phone_score_wiring_test.*` |
| PWI | `practice\diary_screen.gd`·`practice\mission_screen.gd`(`after=E7`), `main.gd`(`after=E6`, `_on_ai_connect`·시작 화면 안내 함수만), `core\home_ai.gd`, `ui\ai_connect_sheet.gd`, `autoload\backend.gd`, `tests\diary_screen_test.gd`·`diary_flow_test.gd`·`ai_connect_test.gd`(단언 추가만) | `tests\phone_ai_wiring_test.*` |
| PZ | `README.md`·`ROADMAP.md`(`after=Z`), `INSTALL.md` | - |
- 경로 접두어: `godot\scripts\` 는 위 표에서 `autoload\`·`core\`·`local\`·`ui\`·`practice\`·`song\`·`views\` 로 줄여 썼다(`tests\`·`data\`·`tools\` 는 `godot\` 아래). 정확한 목록은 아래 OWN 블록이 기준이다.
- **읽기만 하는 파일**: `local_api.gd`, `store.gd`, `study_log.gd`, `sync\*`, `text_sim.gd`, `wav_util.gd`, `tts.gd`, `recorder.gd`, `backend\*`(전부), `lan.py`, v200 소유 파일 전부(`after=` 로 선언한 것 제외).
- **수정 금지(어느 작업도 소유하지 않음)**: `godot\project.godot`, `godot\scripts\sync\*`, `backend\*`(전부), `lan.py`, `godot\data\pack\*`, `godot\data\curriculum.json`, `backend\curriculum.json`, `packaging\publish_release.ps1`·`check_no_media.ps1`·`build_dist.ps1`, 일본어 관련 파일, v200 이 소유한 파일(위 `after=` 항목 제외), 기존 시험(위 허용 목록 밖).

<!-- OWN-BEGIN -->
P0 mod godot/scripts/autoload/route.gd
P0 mod godot/scripts/autoload/api.gd
P0 mod godot/tests/route_test.gd
PA1 mod .gitignore
PA1 new native/whisper_bridge/CMakeLists.txt
PA1 new native/whisper_bridge/build.ps1
PA1 new native/whisper_bridge/whisper_bridge.gdextension.in
PA1 new native/whisper_bridge/BUILD_INFO.json
PA1 new native/whisper_bridge/README.txt
PA1 new native/whisper_bridge/THIRD_PARTY.txt
PA1 new native/whisper_bridge/src/register_types.h
PA1 new native/whisper_bridge/src/register_types.cpp
PA1 new native/whisper_bridge/src/whisper_bridge.h
PA1 new native/whisper_bridge/src/whisper_bridge.cpp
PA1 new godot/tests/native_bridge_test.gd
PA1 new godot/tests/native_bridge_test.tscn
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
PA4 new godot/scripts/local/local_stt.gd
PA4 new godot/tests/local_stt_test.gd
PA4 new godot/tests/local_stt_test.tscn
PA4 new godot/tests/fixtures/score_params_test.json
PA5 new godot/data/score_params.json
PA5 new godot/tools/calib_phone.gd
PA5 new phone_src/tools/calib_make_set.py
PA5 new phone_src/tools/calib_record.py
PA5 new phone_src/tools/calib_pc_run.py
PA5 new phone_src/tools/calib_fit.py
PA5 new phone_src/tools/test_calib_fit.py
PA5 new phone_src/calib/README.txt
PA7 mod packaging/build_android.ps1
PA7 mod godot/export_presets.cfg
PA7 new packaging/check_phone_native.ps1
PI1 new godot/scripts/local/ai_secrets.gd
PI1 new godot/scripts/local/ai_presets.gd
PI1 new godot/scripts/local/ai_client.gd
PI1 new godot/scripts/local/ai_json.gd
PI1 new godot/scripts/core/ai_state.gd
PI1 new godot/tests/ai_secrets_test.gd
PI1 new godot/tests/ai_secrets_test.tscn
PI1 new godot/tests/ai_client_test.gd
PI1 new godot/tests/ai_client_test.tscn
PI1 new godot/tests/ai_json_test.gd
PI1 new godot/tests/ai_json_test.tscn
PI1 new godot/tests/ai_state_test.gd
PI1 new godot/tests/ai_state_test.tscn
PI1 new godot/tests/fixtures/ai_json_golden.json
PI1 new godot/tests/run_ai_tests.ps1
PI1 new phone_src/tools/fake_ai_server.py
PI1 new phone_src/tools/make_ai_json_golden.py
PI2a new phone_src/tools/make_ai_golden.py
PI2a new phone_src/tools/ai_golden_cases.json
PI2a new phone_src/tools/test_make_ai_golden.py
PI2a newdir godot/tests/fixtures/ai_golden/
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
PSA mod godot/scripts/views/settings_view.gd
PSA mod godot/scripts/ui/capability_panel.gd
PSA mod godot/tests/settings_view_test.gd
PSA new godot/tests/phone_settings_asr_test.gd
PSA new godot/tests/phone_settings_asr_test.tscn
PSI mod godot/scripts/views/settings_view.gd after=PSA
PSI mod godot/scripts/ui/capability_panel.gd after=PSA
PSI mod godot/tests/settings_view_test.gd after=PSA
PSI new godot/tests/phone_settings_ai_test.gd
PSI new godot/tests/phone_settings_ai_test.tscn
PWA mod godot/scripts/ui/self_rate_panel.gd
PWA mod godot/scripts/ui/score_panel.gd
PWA mod godot/scripts/practice/speak_drill.gd
PWA mod godot/scripts/practice/shadow_screen.gd after=E7
PWA mod godot/scripts/song/song_sing_tab.gd
PWA mod godot/tests/self_rate_test.gd
PWA new godot/tests/phone_score_wiring_test.gd
PWA new godot/tests/phone_score_wiring_test.tscn
PWI mod godot/scripts/practice/diary_screen.gd after=E7
PWI mod godot/scripts/practice/mission_screen.gd after=E7
PWI mod godot/scripts/main.gd after=E6
PWI mod godot/scripts/core/home_ai.gd
PWI mod godot/scripts/ui/ai_connect_sheet.gd
PWI mod godot/scripts/autoload/backend.gd
PWI mod godot/tests/diary_screen_test.gd
PWI mod godot/tests/diary_flow_test.gd
PWI mod godot/tests/ai_connect_test.gd
PWI new godot/tests/phone_ai_wiring_test.gd
PWI new godot/tests/phone_ai_wiring_test.tscn
PZ mod README.md after=Z
PZ mod ROADMAP.md after=Z
PZ mod INSTALL.md
<!-- OWN-END -->

### 5.4 검토 강도 (변경 내용 기준)
| 작업 | 위험도 | 검토 |
|---|---|---|
| PA1(네이티브·로딩·오디오), PA3(다운로드·삭제·저장 공간), PA4(오디오·동시성·스레드), PA5(사용자 녹음 개인정보), PA7(빌드·서명·권한), P0(`api.gd`·재시도), PI1(비밀값·네트워크), PI2b·PI2c(개인정보 전송), PI3(키 입력 화면), PWI(일기 개인정보 동의) | 높음 | `reviewer` 판정 + 오케스트레이터가 핵심 명령(PA1-1·PA1-2·PA7-1·PI1-1·PI1-3·PI2b-2·K1~K5 검사·PA5-4)을 직접 재실행 + 사용자 실기 |
| PA2(점수 이식), PI2a(황금 생성기), PSA, PSI, PWA | 보통 | `reviewer` 1회 |
| PZ | 낮음 | 오케스트레이터 확인 |
- `REVIEW.md` 를 검토자가 먼저 읽는다. 불합격 사유는 **중요**만, 왕복 최대 3라운드, 3라운드 뒤엔 접근 재검토. 특히 이 문서에서 추가로 보는 **중요** 항목: 키·사용자 글·인식 글자가 로그·화면·파일·동기화에 나감, `HTTPRequest` 가 `ai_client.gd` 밖에 있음, 리다이렉트로 키가 따라감, 모델 파일·`.so`·`.dll`·오디오가 추적됨, v200 소유 파일 무단 수정.

### 5.5 소유권 검사 스크립트 (합치기 전에 오케스트레이터·검토자가 돌린다)
저장소 **루트**(`D:\Ai\언어\app`)에서 실행. 이 문서의 OWN 블록(폰 작업)과 `docs\v200_design.md` 의 OWN 블록(v200)을 함께 읽는다. 규칙: ① 폰 작업끼리 같은 파일을 소유하면 **뒤에 적힌 작업이 `after=<앞 작업>` 을 달아야** 한다 ② v200 이 소유한 파일(또는 v200 `newdir` 안)을 폰 작업이 소유하면 **`after=<그 v200 작업>` 이 같아야** 한다 ③ `mod` 인데 파일이 없으면, `new` 인데 이미 있으면, `newdir` 이 비어 있지 않으면 FAIL ④ 폴더 중첩·폴더 안 남의 파일 FAIL. 종료 코드 0 = OK.
```powershell
@'
import sys, os
phone = sys.argv[1] if len(sys.argv) > 1 else "docs/v200_phone_design.md"
base = sys.argv[2] if len(sys.argv) > 2 else "docs/v200_design.md"
def rows(path):
    blk = open(path, encoding="utf-8").read().split("<!-- OWN-BEGIN -->")[1].split("<!-- OWN-END -->")[0]
    out = []
    for line in blk.strip().splitlines():
        p = line.split()
        if len(p) < 3:
            continue
        after = ""
        for x in p[3:]:
            if x.startswith("after="):
                after = x[6:]
        out.append((p[0], p[1], p[2].replace("\\", "/"), after))
    return out
P, B, bad = rows(phone), rows(base), 0
bown, bdirs = {}, {}
for t, k, p, _ in B:
    (bdirs if k == "newdir" else bown)[p.lower()] = t
owner, dirs, ordered, seen_tasks = {}, {}, 0, []
for t, k, p, a in P:
    key = p.lower()
    if t not in seen_tasks:
        seen_tasks.append(t)
    if a:
        ordered += 1
    if k == "newdir":
        if not key.endswith("/"):
            print("FAIL newdir must end with /:", p); bad += 1
        dirs[key] = t
        if os.path.exists(p) and os.listdir(p):
            print("FAIL new dir already has files:", p); bad += 1
        continue
    prev = owner.get(key, [])
    if prev and t not in prev and a not in prev:
        print("FAIL overlap without after=:", p, prev, "->", t); bad += 1
    if t not in prev:
        prev.append(t)
    owner[key] = prev
    exists = os.path.exists(p)
    if k == "mod" and not exists:
        print("FAIL missing existing file:", p); bad += 1
    if k == "new" and exists:
        print("FAIL new file already exists:", p); bad += 1
    if key in bown and a != bown[key]:
        print("FAIL overlaps v200 task %s without matching after=:" % bown[key], p, t); bad += 1
    for d, dt in bdirs.items():
        if key.startswith(d) and a != dt:
            print("FAIL inside v200 dir %s (%s) without after=:" % (d, dt), p, t); bad += 1
for f, ts in owner.items():
    for d, dt in dirs.items():
        if f.startswith(d) and dt not in ts:
            print("FAIL file inside another task's dir:", f, ts, dt); bad += 1
for d1 in dirs:
    for d2 in dirs:
        if d1 != d2 and d2.startswith(d1):
            print("FAIL nested dirs:", d1, d2); bad += 1
print("files", len(owner), "dirs", len(dirs), "tasks", len(seen_tasks), "ordered", ordered, "FAIL" if bad else "OK")
sys.exit(1 if bad else 0)
'@ | python -X utf8 -
```
기대 출력: 마지막 줄 `files 108 dirs 1 tasks 17 ordered 9 OK`(숫자는 OWN 블록 줄 수에서 나온다. 문서를 고치면 같이 고친다. 설계자가 작성 직후 직접 돌려 이 출력을 확인했고, 겹침(`after=` 없음)·v200 파일 겹침·없는 파일·이미 있는 새 파일을 일부러 넣은 복사본에서 각각 `FAIL` 이 나오는 것도 확인했다).

---

## 6. 작업별 합격 조건 (O/X)

### 6.1 공통 조건 (v200 §14.1 C-0~C-17 에 더한다)
`$G`, `$PY`, 시험 실행·`$env:APPDATA` 임시화는 v200 §14.1 과 같다. 워크트리 `$W = D:\Ai\언어\app_wt\v200p_<작업>`. 모든 보고 맨 앞에 합격 조건 표(항목 / O·X·미검증 / 근거), 실행하지 않은 것은 "미검증". 아래 표 안의 `\|` 는 마크다운 표 때문에 이스케이프한 것이고 실제 명령·정규식에서는 `|` 이다.

| ID | 조건 | 판정 |
|---|---|---|
| X-1 | **비밀·개인 글 0**: 시험 출력·로그·보고에 가짜 키 마커 `FAKEKEY_ZZ_`·사용자 글 마커 `ZZ_MARK_9731`·인식 글자 마커가 0번(키 파일을 일부러 읽는 시험의 복호 결과 제외, 그 파일에도 평문 0) | `Select-String -Path <출력> -Pattern "FAKEKEY_ZZ_\|ZZ_MARK_9731"` 0건 |
| X-2 | 공개 스크립트의 키 정규식 통과: `git -C $W grep -I -n -E "(^\|[^A-Za-z0-9_])sk-(ant-\|proj-)?[A-Za-z0-9_-]{20,}\|AIza[0-9A-Za-z_-]{30,}\|gh[pousr]_[A-Za-z0-9]{30,}\|github_pat_[A-Za-z0-9_]{30,}\|AKIA[0-9A-Z]{16}\|xox[baprs]-[A-Za-z0-9-]{10,}\|-----BEGIN [A-Z ]*PRIVATE KEY-----"` | 0줄 |
| X-3 | 추적 금지물 0: `git -C $W ls-files` 에서 `godot/bin/`, `*.gdextension`(`.in` 제외), `native/_deps/`, `*.bin`·`*.gguf`·`*.onnx`, `*.so`·`*.dll`(원본 저장소 기존 파일 제외), `*.wav`·`*.mp3`·`*.ogg`·`*.m4a`, `phone_src/calib/` 의 오디오, `ai_secrets` | 0건 |
| X-4 | `$W` 에서 `packaging\publish_release.ps1 -ScanOnly` 통과, `packaging\check_no_media.ps1` OK(작업이 `packaging\` 를 안 건드려도 확인) | 종료 0 |
| X-5 | `backend\` 변경 0(`git -C $W diff --name-only <기준> -- backend` 비어 있음). 파이썬 도구는 `backend\*.py` 를 **읽기만**(전후 sha256 동일) | 비어 있음·해시 동일 |
| X-6 | 새 파일의 `HTTPRequest`/`HTTPClient`: `rg -n "HTTPRequest\|HTTPClient" <새 .gd>` 가 `ai_client.gd`(HTTPRequest)·`model_store.gd`(HTTPClient) 밖에서 0줄. `OS.shell_open`·`OS.request_permission` 0줄 | 0줄 |
| X-7 | **로그 정적 검사**: `rg -n "(print\|push_warning\|push_error\|printerr)\(.*(key\|body\|messages\|prompt\|text\|target\|transcript)" <새·바뀐 local\ai_*.gd, local_stt.gd, local_ai.gd, model_store.gd>` 0줄(필요하면 줄별 허용 주석 없이 코드를 고친다) | 0줄 |
| X-8 | 소유 밖 파일 수정 0: `git -C $W diff --name-only <기준>` ⊆ §5.3 OWN 블록의 그 작업 파일(+ 새 `.gd` 의 `.uid`). v200 소유 파일은 `after=` 가 선언된 것만이고 그 v200 작업이 main 에 병합돼 있어야 한다 | 부분집합 |
| X-9 | 소유권 검사 스크립트(§5.5)가 `OK` 이고 기대 숫자와 같다 | 출력 |

### 6.2 P0 — 계약 확정: Route 정책·오류 코드·`api.gd` 재시도 (`worker-hard`, 1파, 위험도 높음)
- 하는 일: §1.8 의 P0 항목. `Route.POLICY`(`#ph`)·`score_where`·새 오류 코드·문구·HTTP·`DEGRADED`, `Api` 의 폰 처리 실패 시 PC 1회 재시도.

| ID | 조건 | 명령 → 기대 |
|---|---|---|
| P0-1 | 시험 통과 | `route_test` PC·`-- --phone` → 마지막 줄 `N passed, 0 failed`, N ≥ 기준선 + 24 |
| P0-2 | 정책: `Route.policy_for("POST","/score",{})` prefer `"phone"`(`score_where` 없음·`"phone"`), `{"need_ph":true}` 이면 키 `POST /score#ph` prefer `"pc"`, `score_where="pc"` 이면 `/stt`·`/score` prefer `"pc"`. **그 밖의 모든 POLICY 항목은 기준선 SPEC 과 동일**(시험의 SPEC 표 변경은 `/stt`·`/score` 두 줄과 `#ph` 한 줄뿐) | 시험 + `git diff` 로 SPEC 변경 줄 수 확인 |
| P0-3 | `decide` 전수: (`/stt`, `/score`, `/score`+`need_ph`) × 모드(auto·phone·pc) × PC 준비(T/F) × 폰 처리 가능(T/F) × `score_where`(phone·pc) = 72행이 기대표와 일치 | 시험(행 수 출력 72) |
| P0-4 | 재시도: 가짜 폰 핸들러가 `engine_error`(또는 `stt_timeout`)로 실패 + 가짜 PC 정상 + auto → 최종 `ok:true`·PC 응답, 핸들러 `served_count` 1·PC 요청 1회. mode `phone` → 재시도 없음. `/chat`·`/fix`·`/feedback` 의 폰 실패는 PC 로 안 넘김. 폰 실패 + PC 실패 → 루프 없이 오류 반환(PC 요청 정확히 1회) | 시험 |
| P0-5 | 새 오류 코드 `engine_error, stt_timeout, ai_offline, ai_tls, ai_model, ai_url, ai_key_format, ja_ai_pc, no_space` 전부 `Route.ERR_TEXT`(한국어, 한글 포함)·`ERR_HTTP`(400/401/403/429/5xx 중 의미에 맞는 값, 0 아님) 가 있고, 폰 쪽 401 이 `Api.auth_failed` 신호를 내지 않는다(기존 규칙 유지). `no_ai` 문구가 "설정 > AI 연결에서 본인 AI 키…"로 바뀌고 `model_missing`/`engine_missing` 문구는 §3 #1 과 같다 | 시험 |
| P0-6 | `Route.DEGRADED` 에 `score_uncalibrated`·`stt_tiny_model` 포함, `LocalApi.ok(data, ["score_uncalibrated"])` 가 통과 | 시험 |
| P0-7 | `ScoreReq` 가 `need_ph` 를 무시한다(설계 §1.1 의 추측 확인): 서버를 **프로세스 안에서만** 불러 모델·포트 없이 확인. `test_fix_private.py` 와 같은 격리(`HOEHWA_ESPEAK_DIR` 임시 폴더, `--tag`)를 쓴다. `backend\logs\` 에 태그 로그가 생기는 것은 허용(추적 안 됨) | `$env:HOEHWA_ESPEAK_DIR='<scratch>\espeak'; & $PY -I -c "import sys; sys.path.insert(0,'backend'); sys.argv=['x','--tag','unit_p0']; import server; server.ScoreReq(lang='en',target='a',audio_b64='x',need_ph=True); print('OK')"` → `OK` |
| P0-8 | 기존 시험 기준선 대비 같은 passed·0 failed: `remote_test`, `flow_test`, `persist_test`, `lifecycle_test`, `smoke`, `local_lessons_test`, `local_missions_test`, `local_reading_test`, `practice_test`(`--api` 없이) | C-0 표 대조 |
| P0-9 | 금지: `api.gd` 의 PC 요청 생성부·인증 헤더·401 처리·`IDEMPOTENT_POST`·`FALLBACK_POST` 정의 변경 0(`git diff -U0 godot\scripts\autoload\api.gd` 의 바뀐 줄이 재시도 함수 범위뿐), `Route` 의 기존 공개 함수 시그니처 변경 0, `local_api.gd`·`project.godot` 변경 0 | diff |
| P0-10 | 상수 변이: `score_where` 기본값 `"phone"` → `"pc"` 로 바꾸면 P0-2·P0-3 이 **FAIL** 하는 줄을 붙이고 원복 | 줄 존재 |

### 6.3 PA1 — 네이티브 브리지 (`worker-hard`, 1파 스파이크 → G1 → 2파 전체, 위험도 높음)
- 1단계(스파이크, G1): ★승인 뒤 NDK·소스를 받고 빈 확장 + whisper.cpp tiny/base 가 폰에서 도는지. 2단계: §1.4 전체.

| ID | 조건 | 명령 → 기대 |
|---|---|---|
| PA1-1 | ★승인된 도구: `Get-Content "<SDK>\ndk\28.1.13356709\source.properties"` 에 `Pkg.Revision = 28.1.13356709`. 승인 전에는 이 항목과 이후 빌드 항목이 **"미검증(승인 대기)"** | 출력 |
| PA1-2 | 안드로이드 빌드: `powershell -ExecutionPolicy Bypass -File native\whisper_bridge\build.ps1 -Target android-arm64 -Out <scratch>` 종료 0, `godot\bin\libwhisper_bridge.android.arm64.so` 있음, 크기 ≤ 20 MB, `BUILD_INFO.json` 의 sha256 이 `(Get-FileHash <so>).Hash` 와 같음 | 출력 |
| PA1-3 | ELF: `llvm-readelf -h` Machine = AArch64; `llvm-readelf -d` 의 NEEDED ⊆ {`libc.so`, `libm.so`, `libdl.so`, `liblog.so`, `libandroid.so`}(**`libc++_shared.so` 없음** — 있으면 `.gdextension` `[dependencies]` + APK 안 존재 확인); `llvm-objdump -p <so>` 의 모든 LOAD `align` = `2**14`; `llvm-nm -D --defined-only` 에 `whisper_bridge_init` | 출력(NDK 의 `toolchains\llvm\prebuilt\windows-x86_64\bin\`) |
| PA1-4 | Windows 데스크톱 빌드: `build.ps1 -Target windows-x64` 종료 0 → `godot\bin\whisper_bridge.windows.x86_64.dll`. `build.ps1` 이 `godot\whisper_bridge.gdextension` 을 **생성**(추적 안 됨) | 출력 + `git status` 에 안 보임 |
| PA1-5 | `native_bridge_test`(`-- --model=<scratch>\ggml-base.en-q5_1.bin --wav-dir=<scratch>\wav`) N ≥ 40: `version()` 비어 있지 않음, `load_model` OK, **Kokoro 합성 WAV**("I would like a cup of coffee, please.")의 전사에 정답 단어 8개 중 ≥ 5개, 모든 `words[].p` ∈ [0,1], `start < end`·시작 시각 단조 증가, `ms > 0`, 무음 WAV → `ok:true, words:[]`, 0바이트·깨진 WAV → `ok:false, error:"bad_wav"`, `lang:"ja"` → `bad_lang`, 모델 없이 → `no_model`, **반 토막 모델 파일**: `load_model` ≠ OK·`is_loaded()` false·앱 크래시 0, **중단**: 25초 오디오 전사를 스레드로 시작하고 300 ms 뒤 `abort()` → 2초 안에 `error:"aborted"`, 이어서 정상 전사가 다시 됨, 두 스레드가 동시에 `transcribe` 해도 결과가 섞이지 않음(순서 대기) | 시험. 모델·WAV 가 없으면 "미검증(승인 대기)" |
| PA1-6 | **APK 포함(비-Gradle)**: scratch 복사본(또는 `--export-debug`)으로 만든 디버그 APK 에서 `Expand-Archive`/`unzip -l` 로 `lib/arm64-v8a/libwhisper_bridge.android.arm64.so` 가 있고 **다른 ABI 폴더가 없음**, `zipalign -c -P 16 -v 4 <apk>` 의 마지막 줄 `Verification successful`, 권한이 3개 그대로(`aapt2 dump permissions`), `git diff --stat godot\export_presets.cfg` 비어 있음 | 출력 |
| PA1-7 | **G1(사용자 실기 H1)**: 프로브 APK(`--export-debug`, 디버그 템플릿, 앱 코드 변경 없이 scratch 프로젝트 복사본의 메인 씬만 프로브로 교체)를 사용자 폰에 설치 → 화면·logcat 에 `ClassDB.can_instantiate("WhisperBridge") == true`, `version()`, `tiny.en-q5_1` 로드·5초 영어 발화 전사 성공, `base.en-q5_1` 5회 전사 `ms` 의 중앙값(보고), 비정상 종료 0. **통과선**: base p50 ≤ 8초 이고 RAM 증가 ≤ 700 MB(§1.7). 못 넘으면 `q8_0`·`tiny` 재측정 후 no-go 판단 | 사용자 실기 표 H1 |
| PA1-8 | 일부러 틀린 입력: `build.ps1` 에 고정되지 않은 커밋(`-WhisperCommit deadbeef`)을 주면 한국어/영어 오류와 종료 ≠ 0(빌드 안 함), NDK 경로가 없으면 같은 식 | 출력 |
| PA1-9 | 상수 변이: 브리지의 무음 임계값 `0.003` 을 `0.3` 으로 바꾸면 PA1-5 의 정상 전사 항목이 **FAIL** 하는 줄(원복 뒤 통과 줄) | 줄 존재 |
| PA1-10 | 금지: 모델·`.so`·`.dll`·`native\_deps` 추적(X-3), `godot\project.godot`·`export_presets.cfg` 변경, 새 권한, 네트워크 접근은 ★승인된 `git clone`·모델 다운로드뿐, 서버 프로세스·열린 포트 없음 | X-3, C-7 |

### 6.4 PA2 — 점수 이식 `ScoreCore` + 황금 파일 (`worker-hard`, 1파)
- 하는 일: `server.py` 의 `en_words`(`_expand_contraction`·`_num_words`), `norm`, `align_seq`·`nw_align`·`word_sim`(**`difflib.SequenceMatcher` 의 `get_opcodes`·`ratio` 를 CPython 알고리즘 그대로**), `fluency_score`, `_final_score`, `en_tips`·`en_tip_for_pair`·`_EN_RULES`, `empty_score`, `mismatch_tip`, `score_en` 을 `ScoreCore`(정적)로 이식. 영어만.

| ID | 조건 | 명령 → 기대 |
|---|---|---|
| PA2-1 | 생성기 시험: `& $PY -I phone_src\tools\test_make_score_golden.py` | 종료 0, 통과 ≥ 15 |
| PA2-2 | 드리프트 점검: `& $PY -I phone_src\tools\make_score_golden.py --check` | 종료 0(저장된 황금 == 서버 `score_en` 재계산) |
| PA2-3 | `score_parity_test` PC·`-- --phone` | `N passed, 0 failed`, N ≥ 300 |
| PA2-4 | **전체 결과 동일**: 서버 `score_en(target, words, text)` 로 만든 황금 ≥ 120사례(정확·누락·추가·대체·축약 `don't`·`I'm`·`it's`·숫자 0~99·`100`·`1,234`·하이픈·대문자·곡선따옴표·한 단어·20단어 초과·`p` 0/1·빈 `words`·구두점뿐인 토큰)에서 GDScript 결과 사전이 **키 집합·값·순서까지 같다**(`conf` 는 소수 3자리) | 시험 |
| PA2-5 | **정렬 동일**: 무작위 토큰열 쌍 ≥ 300(고정 시드)에서 `align_seq` 의 `pairs`·`inserts` 가 파이썬과 같고 `word_sim` 이 같은 값(부동소수 완전 일치 또는 1e-9 이내) | 시험(황금이 쌍을 담음) |
| PA2-6 | `en_words` 동일: `practice_en.json` 문장 ≥ 300 + 일부러 어려운 입력 ≥ 80(전각 영숫자·곡선따옴표·`—`·`\u00a0`·숫자 사이 쉼표·큰 수 `1234567890`) — 같지 않은 것은 `KNOWN_GAPS` 목록에 이유와 함께 적고 시험이 "여전히 다름"을 단언(`mission_golden` 방식). 숫자는 `num2words` 와 다른 영역(10자리 이상)만 허용 | 시험 |
| PA2-7 | 방어: `words` 가 배열이 아님·`p` 가 −1/2/NaN·`start > end`·`target` 빈 문자열 → 에러 0, 값은 0~1·단조로 보정, 빈 `target` 은 서버와 같은 400 한국어 문구 "연습할 문장이 비어 있어요." | 시험 |
| PA2-8 | 성능: 40단어 타깃·60단어 `words` 채점이 데스크톱에서 ≤ 50 ms(시험이 측정 출력, 폰 한도는 보고) | 시험 |
| PA2-9 | **일부러 틀린 입력**: 황금 파일의 값 1개를 바꾼 복사본으로 시험하면 **FAIL**, `OK_PROB` 0.45 → 0.40 변이는 PA2-4 가 FAIL(줄을 붙이고 원복) | 줄 존재 |
| PA2-10 | 금지: `backend\` 수정(X-5), 네트워크, 서버 프로세스·포트, 소유 밖 파일 | X-5, X-8 |

### 6.5 PA3 — 모델 받기 `ModelStore` + 카드 (`worker-hard`, 2파, 위험도 높음)
- 하는 일: §1.3 전체. 가짜 서버(`phone_src\tools\fake_model_server.py`, Range·302·지연·연결 끊기 흉내)와 `run_model_tests.ps1` 로 시험. `models.json` 의 sha256 은 시험용 값으로 채우고 실제 값은 ★오케스트레이터가 실제 파일로 계산해 건네 준다.

| ID | 조건 | 명령 → 기대 |
|---|---|---|
| PA3-1 | `powershell -File godot\tests\run_model_tests.ps1`(포트 18791~18799 중 빈 포트 확인 후 서버 기동·PID 로만 종료) → `model_store_test` N ≥ 80, `stt_model_card_test` N ≥ 40, 둘 다 0 failed. 끝에 "남은 프로세스·열린 포트 없음" | 출력 |
| PA3-2 | 정상 받기(3 MB 가짜 모델): 최종 파일 sha256 == 매니페스트, `.part`·`.meta` 0개, 상태 `ready` | 시험 |
| PA3-3 | **이어받기**: 서버가 40%에서 연결을 끊음 → `.part` 유지 → [이어받기]가 `Range: bytes=N-` 을 보내고 두 번째 요청이 보낸 바이트 ≤ 남은 양 + 1 KB → 최종 sha256 일치. 서버가 Range 를 무시(200)하면 처음부터 받고 역시 성공. `416` 이면 `.part` 폐기 후 재시작 | 시험(서버가 요청 헤더·바이트 수를 기록) |
| PA3-4 | **해시 불일치** → 파일 삭제 + `model_corrupt`, `.part` 0개, 상태 `corrupt`(일부러 틀린 매니페스트). 같은 오류를 미러에서도 받으면 매니페스트 오류로 보임 | 시험 |
| PA3-5 | **저장 공간**: `free_space_hook` 이 10 MB 를 돌려주면 **요청이 0건**(서버 기록)이고 `no_space`; 훅이 `0`(알 수 없음)이면 확인 시트 후 진행, 쓰기 오류(훅이 `FileAccess` 오류 모사)면 `.part` 삭제 + `no_space` | 시험 |
| PA3-6 | 리다이렉트: 302 → 허용 호스트(시험 루프백)로 따라감, 3번 넘으면 오류, 허용 목록 밖 호스트·`http://`(시험 훅 off)는 거절, 이어받기는 항상 원래 URL 부터 | 시험 |
| PA3-7 | **메인 스레드가 멈추지 않음**: 받는 동안 매 프레임 증가하는 카운터가 초당 ≥ 50회(PC), 취소·앱 닫기·일시정지 요청에 2초 안에 반응(`NOTIFICATION_APPLICATION_PAUSED` 흉내) | 시험 |
| PA3-8 | 삭제·취소: [취소]는 `.part` 유지, [모델 지우기](확인 시트)는 파일·`.part`·`.meta` 전부 삭제 후 `missing` | 시험 |
| PA3-9 | `models.json` 검사: 모델마다 `sha256` 이 64자리 소문자 16진수, `urls` 가 모두 `https://`, 호스트가 허용 목록 안, `bytes` > 0, `id` 중복 0, 기본 모델 정확히 1개. (**★ 실제 파일 sha256 반영은 오케스트레이터 몫 — 반영 전에는 "미검증"**) | 시험 + 보고 |
| PA3-10 | 카드(`stt_model_card_test`): 실제 버튼 `pressed`(C-14, `press:` 줄 ≥ 12) — [받기] → 와이파이 확인 시트 → [받기] → 진행 → 완료 → [모델 지우기] 확인 → `missing`; 글에 연속 5자리 이상 숫자 0(MB 단위), 진행 글은 `ModelStore.progress_label` 한 함수(`rg -n '%d/%d'` 로 카드에 자체 진행 글 0), PC·폰 412x915·`--font-scale=1.5`·`--dark` | 시험 + selfcheck |
| PA3-11 | 일부러 틀린 입력: 0바이트 응답·`Content-Length` 가 매니페스트와 다름·서버 5xx 연속·URL 목록이 전부 실패 → 앱 크래시 0, 한국어 안내, `.part` 정리 규칙 준수 | 시험 |
| PA3-12 | 상수 변이: `SPACE_MARGIN_MB`(100)를 0 으로 바꾸면 PA3-5 가 **FAIL** | 줄 존재 |
| PA3-13 | 금지: `HTTPRequest` 사용(F-P10), 모델을 저장소에 둠, 동기화 대상 파일·`prefs` 에 경로 저장 외의 모델 정보 저장, 소유 밖 파일 | X-6, X-3 |

### 6.6 PA4 — `LocalStt` 핸들러 (`worker-hard`, 2파, 위험도 높음)
- 하는 일: §1.5 전체. 브리지는 `LocalStt.bridge_factory`(시험 훅)로 **가짜 브리지**를 꽂는다(실제 브리지는 PA1 시험·실기).

| ID | 조건 | 명령 → 기대 |
|---|---|---|
| PA4-1 | `local_stt_test` PC·`-- --phone` | `N passed, 0 failed`, N ≥ 90 |
| PA4-2 | 가용성 표: (모델 `ready`/`missing`/`corrupt`) × (브리지 클래스 있음/없음) × (`lang` en/ja) × (`/stt`·`/score`) 전수 → `is_available_for`·`unavailable_reason_for` 가 `engine_missing`/`model_missing`/`model_corrupt`/`not_on_phone`/가능 중 기대값 | 시험 |
| PA4-3 | `/score` 결과가 같은 `words` 로 `ScoreCore.score_en` 을 직접 부른 결과와 **같다**(`p_map` 이 항등일 때). `p_map` 이 있으면 `words[].p` 가 매핑된 값으로 `score_en` 에 들어간다(수식 단언). 파일 없음·비단조·범위 밖·모델 id 불일치 → 항등 + `degraded` 에 `score_uncalibrated`, 앱 크래시 0 | 시험(`fixtures\score_params_test.json` 변형 6종) |
| PA4-4 | `/stt` 응답 `{text, words, duration}` + `via:"phone"`; `/score` 키 `transcript, score, accuracy, clarity, fluency, units, tips_ko`; `degraded` 에 `phoneme_off` 항상, tiny 면 `stt_tiny_model` | 시험 |
| PA4-5 | 입력 방어(서버와 같은 한국어 문구): `audio_b64` 빈 값·깨진 base64·비 WAV(`bad_wav`)·빈 `target` → 400, 무음 → 점수 0 + `NO_VOICE_TIP`, 30초 초과 → 30초로 자름(가짜 브리지가 받은 길이로 확인) | 시험 |
| PA4-6 | **시간 초과·취소**: 가짜 브리지가 13초(가짜 시계) 걸리면 `abort()` 가 불리고 `stt_timeout`; `ApiCall.cancel()` 이면 `abort()` 호출·결과 폐기·`active_count` 0; 동시에 두 요청은 순서대로 처리(두 번째가 첫 번째를 깨지 않음) | 시험 |
| PA4-7 | **수명**: 첫 사용에 모델 로드 1회, 연속 요청은 재사용, 마지막 사용 90초 뒤 `unload()`(가짜 시계), `NOTIFICATION_APPLICATION_PAUSED` → `abort()`+`unload()`, 로드 실패 → 상태 `corrupt`·`model_corrupt` | 시험 |
| PA4-8 | **메인 스레드 비차단**: 가짜 브리지가 1초 블로킹하는 동안 메인의 프레임 카운터가 ≥ 50 증가 | 시험 |
| PA4-9 | 네트워크 0: 폰 처리 요청 전후 `Api.sent_count` 불변 | 시험 |
| PA4-10 | **일부러 틀린 입력**: 가짜 브리지가 `{ok:false, error:"engine"}`·단어 `p` 가 음수·`start>end`·`words` 누락·예외를 던짐 → 크래시 0, `engine_error`(P0 재시도 대상) 또는 보정된 값 | 시험 |
| PA4-11 | 상수 변이: `STT_TIMEOUT_SEC`(12)를 120 으로 바꾸면 PA4-6 이 **FAIL** | 줄 존재 |
| PA4-12 | 금지: 인식 글자·타깃 문장 로그(X-7), `HTTPRequest`, `Route`·`Api` 수정, 소유 밖 파일 | X-7, X-6 |

### 6.7 PA5 — 점수 보정 (`worker-hard`, 3파, ★사용자 녹음 동의 필요)
- 하는 일: §1.6 전체. 데이터는 전부 `<scratch>`(저장소 밖).

| ID | 조건 | 명령 → 기대 |
|---|---|---|
| PA5-1 | 도구 시험: `& $PY -I phone_src\tools\test_calib_fit.py` | 종료 0, 통과 ≥ 20(등위 회귀 단조성, 임계값 탐색, 일치율 정의, 클립 단위 분할 누수 0) |
| PA5-2 | 합성 세트: `calib_make_set.py` 가 클립 ≥ 1,000, 서로 다른 문장 ≥ 200, 음성 ≥ 4종, "틀린 단어" 클립 ≥ 250, 변형(속도·소음·대역제한·진폭) 포함, 해시 목록 저장. 저장소에 오디오 0(X-3) | 출력 + `git ls-files` |
| PA5-3 | ★사용자 녹음: ≥ 40클립(정상·일부러 틀림 쌍), 동의 문구 그대로 보여 주고 사용자 확인을 받았다고 보고(**동의 없으면 이 항목과 PA5-4 의 "사용자" 열은 "미검증"**). 파일은 `<scratch>\calib_user\` 에만, 보고에는 개수·총 길이만 | 보고 |
| PA5-4 | **지표(§1.6 합격선, 보류 30%)**: 합성 단어별 `ok` 일치율 ≥ 85%, 사용자 ≥ 80%(클립 수·95% 신뢰구간 표기), 최종 점수 평균절대오차 ≤ 10·P90 ≤ 20, 유창성 평균절대오차 ≤ 15, 틀린 단어 클립이 깨끗한 클립보다 낮은 쌍 ≥ 95%, 틀린 클립 중 70점 이상 ≤ 10%, 깨끗한 클립 중 70점 미만 ≤ 10%. 미달이면 모델 상향·`beam` 재측정 결과를 보고하고 오케스트레이터가 정한다 | 보고서 표 |
| PA5-5 | `godot\data\score_params.json` 형식: `v`·`model_id`(== `models.json` 기본 모델 id)·`calibrated:true`·`ok_prob` ∈ (0.2, 0.8)·`p_map` 지점이 단조 비감소·x 범위 0~1·양 끝 포함. `LocalStt`(PA4)가 이 파일을 `degraded:["score_uncalibrated"]` 없이 읽음(`local_stt_test` 재실행 또는 PA5 가 추가한 한 줄 확인 스크립트) | 시험 |
| PA5-6 | **일부러 틀린 입력**: PC·폰 결과의 클립 짝을 무작위로 섞어 `calib_fit.py` 를 돌리면 일치율 < 0.6 → `CALIB_FAIL agreement` 와 종료 1(`score_params.json` 을 쓰지 않음); 빈 데이터·한쪽만 있는 클립도 종료 1 | 출력 |
| PA5-7 | 개인정보: 사용자 WAV·전사 글이 저장소·로그·보고에 없음(`Select-String` 0건), 끝나면 `<scratch>\calib_user\` 를 지울지 사용자 선택을 기록(기본 삭제) | 보고 |
| PA5-8 | 금지: 서버 프로세스·포트(보정 PC 결과는 프로세스 안 함수 호출), 사용자 폴더·`secrets.json` 접근, 네트워크(모델은 ★승인된 경로) | X-5 |

### 6.8 PA7 — 빌드 통합 (`worker-hard`, 3파, 위험도 높음: 빌드·서명)
| ID | 조건 | 명령 → 기대 |
|---|---|---|
| PA7-1 | `powershell -ExecutionPolicy Bypass -File packaging\build_android.ps1 -Version <v> -Debug`(scratch APPDATA·scratch OutDir) 성공, 기존 검증(서명 지문 == `android_cert.sha256`, 패키지·버전·권한 3개) 통과, APK 안 `lib/arm64-v8a/libwhisper_bridge.android.arm64.so` 있음, **ABI 폴더는 `arm64-v8a` 하나** | 스크립트 출력 + `unzip -l` |
| PA7-2 | `.so` 가 없거나 `BUILD_INFO.json` 의 sha256 과 다르면(일부러 1바이트 변경한 복사본) 스크립트가 한국어 오류와 종료 ≠ 0 으로 **APK 를 만들지 않음** | 출력 |
| PA7-3 | `check_phone_native.ps1 -Apk <apk>`: (a) `.so` 있음 (b) 모든 LOAD `2**14` (c) `zipalign -c -P 16 -v 4` 통과 (d) `aapt2 dump xmltree --file AndroidManifest.xml` 에 `allowBackup` = false (e) NEEDED 허용 목록 (f) APK 크기와 기준 APK(직전 릴리스) 대비 증가분 출력, **증가분 ≤ 15 MB**, 전체 ≤ 100,000,000바이트 | 출력 |
| PA7-4 | **`check_phone_native.ps1 -SelfTest`** 가 일부러 틀린 입력(정렬 안 된 `.so` 를 넣은 가짜 zip, `allowBackup=true` 매니페스트 조각)에서 **실제로 실패**하고 정상 입력에서 통과 | 출력(실패 줄 + 통과 줄) |
| PA7-5 | PC 내보내기에 폰 확장이 안 들어감: `& $G --headless --path $W\godot --export-pack "Windows Desktop" <scratch>\pc.pck` 후 `Select-String -Path <scratch>\pc.pck -Pattern "whisper_bridge" -SimpleMatch` 0건. `export_presets.cfg` diff 는 preset.0 `exclude_filter` 한 줄뿐(`version/code`·권한·키스토어·`package/unique_name` 변경 0) | 출력 + `git diff` |
| PA7-6 | 일부러 틀린 입력: `.gdextension` 가 없는 상태에서도 `build_android.ps1` 이 **모델/브리지 없는 일반 APK 빌드를 막지 않는다**(`-RequireNative` 가 아니면 경고만, `-RequireNative` 이면 실패) — 2.0.0 처럼 폰 네이티브 없는 릴리스를 계속 만들 수 있어야 함 | 출력 |
| PA7-7 | `publish_release.ps1 -ScanOnly`·`check_no_media.ps1` 통과, 서명 키·비밀번호 출력·기록 0, `android_cert.sha256` 불변 | X-4 |
| PA7-8 | 상수 변이: 크기 증가 한도 15 MB → 1 MB 로 바꾸면 PA7-3 이 **FAIL** | 줄 존재 |

### 6.9 PI0 — C0 공급자 시험 (오케스트레이터 + 사용자, 1파 전, 코드 없음)
- 사용자의 **자기 키**로 1회: 개발 스크립트(저장소 밖 `<scratch>`)가 환경변수(`HOEHWA_TEST_KEY`)에서 키를 읽어 `POST {base}/chat/completions` 에 한 줄 요청을 보낸다. 키는 채팅·로그·보고에 쓰지 않고 상태 코드·오류 분류만 기록.

| ID | 조건 | 판정 |
|---|---|---|
| PI0-1 | 후보: Zen 유료 모델 `deepseek-v4.1-flash` 를 `https://opencode.ai/inference/v1` 와 `https://opencode.ai/inference/openai/v1` 두 주소로 각각 호출 → 어느 쪽이 되는지 상태 코드(200/401/404…) | 기록 |
| PI0-2 | Zen 무료 `deepseek-v4.1-flash-free` 를 폰과 같은 방식(직접 호출)으로 호출 → 거부 메시지 확인(문서·과거 실측과 일치 확인) | 기록 |
| PI0-3 | `response_format {"type":"json_object"}` 지원 여부와 `system` 메시지가 대화 중간·마지막에 와도 되는지(프리셋의 `single_system` 필요성) | 기록 |
| PI0-4 | 사용자가 고른 다른 업체(Gemini 등)로 같은 시험 | 기록 |
| PI0-5 | 키가 출력·로그·셸 기록에 없음 | 확인 |

### 6.10 PI1 — 키 저장·프리셋·클라이언트·JSON 추출 (`worker-hard`, 1파, 위험도 높음: 비밀값·네트워크)
| ID | 조건 | 명령 → 기대 |
|---|---|---|
| PI1-1 | `powershell -File godot\tests\run_ai_tests.ps1`(가짜 서버 `phone_src\tools\fake_ai_server.py` 를 포트 18791~18799 중 빈 곳에서 기동·PID 로만 종료) → `ai_secrets_test` N ≥ 50, `ai_client_test` N ≥ 100, `ai_json_test` N ≥ 80, `ai_state_test` N ≥ 30, 전부 0 failed, "남은 프로세스·열린 포트 없음" | 출력 |
| PI1-2 | **키 파일**: 저장 후 파일 바이트 어디에도 가짜 키 평문·마지막 4자가 없음(`Select-String`/바이트 검색 0), 솔트 파일은 별도, 잘못된 기기 값(훅)이면 복호화 실패 → `has_key` false·크래시 0, 잘리거나 쓰레기인 파일 → `.bad` 로 격리 후 "키 없음", 읽기 전용 폴더 → `io` 오류 | 시험 |
| PI1-3 | **키 형식 검사**: 공백·줄바꿈·`Bearer ` 접두·따옴표·15자 미만·257자 이상·비 ASCII → `ai_key_format`, 정상 형식 통과. PC(`Platform.is_phone()` false, 훅 없음)에서는 `set_key` 가 `not_phone` 으로 거부 | 시험(≥ 12행) |
| PI1-4 | **전송 계약**(가짜 서버가 요청을 기록): 메서드 POST, 경로 `…/chat/completions`, 헤더 `Authorization: Bearer <키>`(서버는 **해시로만** 비교·기록), 본문 `model`·`messages`(마지막이 시스템 지시)·`temperature`·`stream:false`·`max_tokens`·`response_format`. `response_format` 을 거부(400 + 해당 문구)하면 **빼고 정확히 1회** 재요청하고 그 업체는 이후 JSON 모드를 끔 | 시험 |
| PI1-5 | **오류 분류**: 401/403 → `ai_auth`, 402·429·본문에 quota/insufficient/balance/rate limit → `ai_limit`(+`Retry-After` 숫자), 404·model not found → `ai_model`, 500/502/503/504/529 → `ai_overload`, 서버 지연 > 타임아웃 → 타임아웃+1초 안에 `ai_overload`, 연결 거부 → `ai_offline`, TLS 오류(시험 훅) → `ai_tls`, JSON 아님 → 엄격 지시를 붙여 **1회 재요청** 후 `bad_format`(무한 재시도 0) | 시험 |
| PI1-6 | **K4 리다이렉트**: 가짜 서버가 302 로 두 번째 호스트를 가리켜도 따라가지 않음(두 번째 호스트가 받은 요청 0건·Authorization 0건), 결과는 오류. `max_redirects` 가 0 | 시험 |
| PI1-7 | **K5 오류 본문 에코**: 가짜 서버가 키 전체를 에코하는 오류 본문을 줘도 `error`·`err_body`·시험 stdout 에 키 0건(`<key>` 로 치환) | 시험 |
| PI1-8 | **K9 주소 검사**: `http://`·`file://`·`https://user:pass@host`·빈 주소 → `ai_url`, 요청 0건. `AiClient.test_allow_http` 는 기본 false(시험이 켰다 끔을 단언) | 시험 |
| PI1-9 | **취소·비차단**: 응답이 느린 동안 `cancel()` → `ai_cancelled`, 늦게 온 응답 무시, HTTPRequest 를 끊지 않고 고아 처리(F-P10), 메인 프레임 카운터 ≥ 50/초, 활성 요청 0 복귀 | 시험 |
| PI1-10 | `AiJson.extract` 가 `llm_common.extract_json` 과 같다: 황금 ≥ 50사례(코드펜스 여러 개·닫히지 않은 펜스·`<think>` 블록·열린 `<think>`·말미 쉼표·곡선따옴표·설명 앞뒤·중첩 객체·잘린 객체·배열 최상위·빈 문자열)에서 결과 동일/둘 다 실패. `phone_src\tools\make_ai_json_golden.py --check` 종료 0 | 시험 |
| PI1-11 | `AiState.use(lang)` 표: (키 있음/없음) × (`ai_local`) × (`lang` en/ja) × (PC 준비 + `Route.mode`) 전수 → `pc`/`phone`/`none` + 이유가 기대표와 같다 | 시험 |
| PI1-12 | **동기화·저장 누출 0(K1·K2)**: 키를 저장한 뒤 `Store.prefs`·`Store.progress`·`StudyLog.snapshot()`·`SyncDoc.extract(...)` 직렬화 문자열·`user://test_*` 모든 파일에서 가짜 키·마지막 4자 0건. prefs 에 일부러 `ai_key` 를 넣어도 `SyncDoc` 에 안 나옴. 새 prefs 키가 `SyncDoc.SHARED_PREFS` 와 교집합 0 | 시험 |
| PI1-13 | 일부러 틀린 입력: 응답 본문이 빈 문자열·거대한 본문(2 MB)·`choices` 없음·`content` 가 배열(부분 텍스트)·`null` → 에러 0, `bad_format`/정상 추출 | 시험 |
| PI1-14 | 상수 변이: `AiClient` 의 `max_redirects = 0` 을 8 로 바꾸면 PI1-6 이 **FAIL**, 오류 본문 키 치환을 끄면 PI1-7 이 **FAIL** | 줄 존재 |
| PI1-15 | 금지: X-1·X-2·X-6·X-7, 키 값을 어떤 `Dictionary`/시그널/멤버/메시지에도 담지 않음(`rg -n "get_key"` 호출 위치가 `ai_client.gd` 의 헤더 조립 1곳뿐), 소유 밖 파일 | 검사 |

### 6.11 PI2a — 프롬프트·검증 황금 파일 생성기 (`worker-hard`, 1파)
| ID | 조건 | 명령 → 기대 |
|---|---|---|
| PI2a-1 | `& $PY -I phone_src\tools\test_make_ai_golden.py` | 종료 0, 통과 ≥ 25 |
| PI2a-2 | `& $PY -I phone_src\tools\make_ai_golden.py --check` | 종료 0 |
| PI2a-3 | 사례 규모(파일 내용 검사): chat ≥ 40(단계 1~4·시나리오 변형·마지막 말이 질문/비질문·history 비어 있음/`ai` 로 시작/24개 초과), fix ≥ 30(고칠 것 없음·고침·한글 섞인 fix·`ko_ok` 실패 → "더 자연스럽게 고친 문장이에요."·재시도 2번), feedback ≥ 20, judge ≥ 20(인용 검증), `ko_ok`·`scrub_ko` ≥ 60문자열(중국어·키릴 섞임), `clean_hist` ≥ 15, `looks_like_question` ≥ 30 | 시험 |
| PI2a-4 | **네트워크·서버 프로세스 0**: 생성기가 `socket` 생성을 막은 상태에서 돌고(시험이 막은 사실 확인), `backend\*.py`·`backend\cache`·`backend\data`·`backend\content` 의 전후 sha256 동일 | 시험 + 해시 |
| PI2a-5 | **드리프트 감지(일부러 틀린 입력)**: 시험이 서버의 `rules_text` 를 메모리에서 한 글자 바꾼 복사본으로 `--check` 를 돌리면 **종료 1** 과 `GOLDEN_DRIFT <case>` 출력 | 시험 줄 |
| PI2a-6 | 두 `curriculum.json`(`backend\`·`godot\data\`)이 같음을 단언(다르면 `GOLDEN_CURRICULUM_DIFF`) | 시험 |
| PI2a-7 | 금지: 서버 코드 수정, `backend\tools\` 새 파일(F-P11), 실제 사용자 글(사례 문장은 직접 만든 것), 키 모양 문자열 | X-2, X-5 |

### 6.12 PI2b — `LocalAi`: `/chat`·`/fix` (`worker-hard`, 2파, 위험도 높음: 개인정보 전송)
| ID | 조건 | 명령 → 기대 |
|---|---|---|
| PI2b-1 | `ai_chat_parity_test`·`local_ai_test` PC·`-- --phone` | 각 0 failed, N ≥ 400 / ≥ 100 |
| PI2b-2 | **황금 일치**: `godot\tests\fixtures\ai_golden\` 의 chat·fix 사례 전부에서 ① 엔진에 보낸 `messages`(시스템 프롬프트 포함)가 **문자열까지 같다** ② 결과 사전이 같다 ③ 시도 횟수가 같다 | 시험 |
| PI2b-3 | 가용성·네트워크 0: 키 없음 → `/chat`·`/fix` 가 `no_ai`, `lang:"ja"` → `ja_ai_pc`, 둘 다 `AiClient` 호출 0·`Api.sent_count` 불변. `POST /lesson`(`source:"ai"`)은 `LocalApi.available` false | 시험 |
| PI2b-4 | `/fix` `private:true`: 응답 키 `fix, fix_ko, reading, pron`(영어는 `""`)·`private` 생략 시 `fix, fix_ko` 뿐(서버와 같음), 시험 stdout·`user://test_*`·메모리 캐시 어디에도 마커 문장 0건(양성 대조: 시험이 마커를 일부러 `print` 하는 가짜 화면으로 검사기가 잡는지도 확인) | 시험 |
| PI2b-5 | 응답 계약: `via:"phone"`, `degraded:[]`, `tts_chunks` 키 없음, `suggest` ≤ 2개, `reading:""`, 한글이 든 영어 `reply`·`ko` 누락은 서버처럼 거부 후 재시도·최종 `bad`/오류 | 시험 |
| PI2b-6 | 입력 방어: history 24개로 자름, `text` 500자·`prev_ai` 300자 자름, 제어 문자 치환, 빈 `text` → 서버와 같은 한국어 400, `stage`·`month`·`week` 범위 밖 → `clamp_int` 와 같은 값 | 시험 |
| PI2b-7 | 가짜 서버 통합: `AiClient` → 가짜 서버로 `/chat`·`/fix` 가 끝까지 되고, 오류 분류(401/429/503/오프라인)가 `Route` 오류 코드·한국어 문구로 나온다 | 시험 |
| PI2b-8 | **일부러 틀린 입력**: 가짜 모델 답이 JSON 아님·한글 `reply`·빈 `reply`·`fix` 가 원문과 같음·`suggest` 가 문자열 하나·거대 → 크래시 0, 서버와 같은 결정(황금과 동일) | 시험 |
| PI2b-9 | 상수 변이: `rules_text` 의 문장 한 줄을 지우면 PI2b-2 가 **FAIL** | 줄 존재 |
| PI2b-10 | 금지: 사용자 글·프롬프트 로그(X-7), `Api`·`Route` 수정, `course` 필드 처리(PI-L 몫: 무시하고 기존 `stage`), 소유 밖 파일 | X-7 |

### 6.13 PI2c — `LocalAi`: `/feedback`·`/missions/judge` (`worker-hard`, 2파)
| ID | 조건 | 명령 → 기대 |
|---|---|---|
| PI2c-1 | `ai_feedback_parity_test` PC·`-- --phone` | 0 failed, N ≥ 200 |
| PI2c-2 | 황금 일치: feedback ≥ 20·judge ≥ 20 사례에서 `messages` 문자열·결과 사전·시도 횟수 동일(점수 1~5 `clamp`, 중복 교정 제거, 한국어 `scrub_ko`, `summary` 가 한글이 아니면 재시도) | 시험 |
| PI2c-3 | **judge 증거 검증**: AI 가 `done:true` 라고 해도 `evidence` 가 학습자 발화에 실제로 들어 있지 않으면 `done:false`(`_quoted_in`), 목표 id 중복·모르는 id 무시, `pending` 비면 서버와 같은 400 | 시험 |
| PI2c-4 | 연결: PI2b 의 `local_ai.gd` 가 이 파일을 `load()` 경로로 찾아 `/feedback`·`/missions/judge` 를 처리하고, 이 파일이 없으면 `not_on_phone`(PI2c 병합 전에도 PI2b 가 깨지지 않음) | 시험(파일 유무 두 경우) |
| PI2c-5 | 금지: PI2b 소유 파일 수정, 로그(X-7), 소유 밖 파일 | X-7, X-8 |

### 6.14 PI3 — 설정 "AI 연결(이 폰)" 카드·시트 (`worker-hard`, 2파, 위험도 높음: 키 입력 화면)
| ID | 조건 | 명령 → 기대 |
|---|---|---|
| PI3-1 | `phone_ai_sheet_test` PC·`-- --phone`(+`--font-scale=1.5`·`--dark`) | 0 failed, N ≥ 80 |
| PI3-2 | **실제 버튼 흐름(C-14, `press:` ≥ 16)**: 카드 [AI 연결] → 프리셋 고르기 → 키 붙여 넣기(`LineEdit.secret == true`) → [저장] → 동의 시트(프리셋별 문구, §2.6) [동의하고 저장] → 칸이 비고 마지막 4자(`••••`+4자)만 보임 → [시험 호출](가짜 서버 200) "연결됐어요" → [키 지우기] 확인 시트 → 카드가 "키 없음". 각 단계 뒤 다음 버튼이 `visible`·`disabled` 아님 | 시험 |
| PI3-3 | **화면에 키 0**: 시트·카드의 모든 `Label`/`Button`/`LineEdit`/툴팁 글에서 가짜 키 전체·마지막 4자 외 부분 문자열 0건(저장 전 입력칸은 제외, 입력칸은 `secret`). 연속 5자리 이상 숫자 0(C-15) | 시험 + 일부러 키를 라벨에 넣은 가짜 화면이 실패하는 selfcheck |
| PI3-4 | 클립보드: 붙여 넣은 직후 클립보드가 키와 같으면 비워짐(해시 비교), 다르면 그대로 | 시험 |
| PI3-5 | 오류 표시: `ai_auth`·`ai_offline`·`ai_limit`·`ai_model` 이 §2.7 의 한국어 문구로, 카드 상태 점이 빨강/주황, 키는 유지. `ai_key_format`·`ai_url` 은 저장 단계에서 막힘(저장 안 됨) | 시험 |
| PI3-6 | 프리셋 `gemini`(무료 학습) 선택 시 개인정보 경고 한 줄이 보이고 `trains_free` 가 `phone_diary_trains_ok` 기본 false 를 유지. 사용자 지정 주소 입력 시 호스트 확인 문구 | 시험 |
| PI3-7 | 한계 문구(§2.3)와 "키를 입력하는 동안 화면 캡처 금지"(K7) 문구가 카드에 있음, 지출 한도 안내 문구 있음 | 시험 |
| PI3-8 | PC 앱(`Platform.is_phone()` false)에서는 이 카드가 나타나지 않거나 "키는 폰에서만 넣어요" 안내뿐이고 `AiSecrets.set_key` 가 호출되지 않음 | 시험 |
| PI3-9 | 레이아웃: 412x915·글자 1.5배·다크에서 겹침·잘림 0, 눌리는 곳 ≥ 44 | 시험 |
| PI3-10 | 상수 변이: 시트의 `secret = true` 를 `false` 로 바꾸면 PI3-2 가 **FAIL** | 줄 존재 |
| PI3-11 | 금지: `HTTPRequest` 직접 사용(시험 호출은 `AiClient` 로), 키를 변수에 보관, 로그(X-7), 소유 밖 파일(`settings_view.gd` 연결은 PSI) | X-6, X-7 |

### 6.15 PSA / PSI — 설정 연결 (`worker`, 3파)
| ID | 조건 | 명령 → 기대 |
|---|---|---|
| PS-1 | PSA: `phone_settings_asr_test`(+`settings_view_test` 기준선 이상) 0 failed, 폰에서 "음성 인식(채점 모델)" 카드와 `score_where` 라디오 2개(폰 우선 / PC 우선) 보임, 라디오가 `Store.prefs.score_where` 와 `Route` 결정을 바꿈(`Route.decide` 확인), PC 앱에서는 카드가 없음 | 시험 |
| PS-2 | PSI: `phone_settings_ai_test` 0 failed, 폰에서 "AI 연결(이 폰)" 카드(`phone_ai_card.gd`) 보임, PC 에서는 기존 `ai_connect_card.gd` 만 | 시험 |
| PS-3 | `CapabilityPanel` 키 16개 그대로, `REASONS` 문구 갱신(§3 #2), 항목 `chat/fix/feedback/stt/score` 가 `phone` 으로 보일 수 있음 | 시험 |
| PS-4 | 기존 `settings_view_test`·`ai_connect_test`(PSI 는 읽기만)·`phone_layout_test`·`screens_scan_test` 기준선 이상(단언 추가만, C-5) | C-0 표 |
| PS-5 | 실제 버튼 흐름(`press:` ≥ 8): 처리 위치 라디오 누르기 → 저장·반영, 카드의 [받기]/[AI 연결] 버튼이 해당 시트를 엶 | 시험 |
| PS-6 | 일부러 틀린 입력: `score_where` 에 `"아무거나"`·숫자·null → `"phone"` 으로 취급, 크래시 0 | 시험 |
| PS-7 | 금지: 카드 부품 파일(PA3·PI3 소유) 수정, `project.godot`, 소유 밖 파일 | X-8 |

### 6.16 PWA — P-ASR 화면 연결 (`worker`, 4파, v200 E7 병합 뒤)
| ID | 조건 | 명령 → 기대 |
|---|---|---|
| PWA-1 | `phone_score_wiring_test` PC·`-- --phone`(+폰트·다크) 0 failed, N ≥ 70 | 시험 |
| PWA-2 | **실제 버튼 흐름(`press:` ≥ 10)**: 모델이 없는 폰에서 말하기 → 자가 평가 위젯 위에 [음성 인식 모델 받기(약 60 MB)] → 모델 카드/시트가 열림; 모델 `ready`(가짜 상태) 뒤 같은 화면에서 `/score` 가 폰 경로로 가고 점수 화면 + "폰 간이 채점" | 시험(`SpeakDrill.api_hook` 가로채기) |
| PWA-3 | `ScorePanel`: 결과 `via=="phone"` 일 때만 "폰 간이 채점", PC 결과·`via` 없음엔 없음 | 시험 |
| PWA-4 | `SpeakDrill`: `source=="drill"` 이고 `lang=="en"` 일 때만 요청 본문에 `need_ph:true`(`"shadow"`·레슨·복습·코스는 없음), 일본어 `"drill"` 은 변화 0 | 시험 |
| PWA-5 | 문구: `SelfRatePanel`·`shadow_screen`·`song_sing_tab` 이 이유(`model_missing`/`engine_missing`/`model_corrupt`)별로 §3 의 문구. 일본어 노래·일본어 화면은 **변경 0**(`lang=="ja"` 는 기존 문구) | 시험 |
| PWA-6 | **v200 호환**: `course_flow_test`·`course_exercise_view_test`(E4a·E4b 병합 뒤 존재)·`practice_test`(`--api` 없이)·`self_rate_test`·`shadow`/`dictation` 관련·`lesson_source_test` 가 기준선 이상, `SpeakDrill` 의 공개 시그니처(`request`, `api_hook`, `scored`, `silent_result`) 변경 0 | C-0 표 + diff |
| PWA-7 | 일부러 틀린 입력: `via` 가 문자열이 아님·`degraded` 가 배열이 아님 → 에러 0 | 시험 |
| PWA-8 | 금지: 일본어 시험·화면 변경, `lesson_view.gd`(E5)·`talk_view.gd`(E7) 수정, 소유 밖 파일 | X-8 |

### 6.17 PWI — P-AI 화면 연결 (`worker-hard`, 4파, v200 E6·E7 병합 뒤, 위험도 높음: 일기 개인정보)
| ID | 조건 | 명령 → 기대 |
|---|---|---|
| PWI-1 | `phone_ai_wiring_test` PC·`-- --phone`(+폰트·다크) 0 failed, N ≥ 90 | 시험 |
| PWI-2 | **일기(PC 경로 불변)**: `diary_screen_test`·`diary_flow_test` 기준선 이상(단언 추가만), PC 경로의 동의 문구·`fix_private_ok()`(PC `health`) 동작 변경 0 | C-0 표 |
| PWI-3 | **일기(폰 경로)**: 폰 AI 키 + 영어 → `ai_state()` == `"ready"`, `fix_private_ok()` true, [고쳐 보기]가 `SpeakDrill.request("/fix", {… "private": true})` 한 길로 가고 결과가 저장됨(가짜 AI). 처음에는 **폰용 동의 시트**(업체 이름·§2.6 문구)가 나오고 동의 뒤에만 요청이 나감(요청 0건 → 동의 → 1건). 동의 전 [나중에]는 요청 0건 | 시험(`press:` ≥ 10) |
| PWI-4 | **무료 학습 업체**: `gemini` 프리셋이면 [고쳐 보기]가 꺼지고 "이 업체는 보낸 글을 학습에 쓸 수 있어요. 일기는 저장만 해요" 한 줄, `phone_diary_trains_ok` 를 켜고 확인 시트에서 동의한 뒤에만 켜짐 | 시험 |
| PWI-5 | 일기 원문이 로그·`print`·`Toast`·`user://test_*`(일기 파일 제외)·동기화 직렬화에 0건(마커 `ZZ_MARK_9731`) — 양성 대조 포함 | 시험(X-1) |
| PWI-6 | 미션: 폰 AI 가 있으면 `_llm_down()` false(AI 모드 가능), 없으면 기존처럼 true. `mission_test`·`mission_ja_flow_test` 기준선 | 시험 + C-0 표 |
| PWI-7 | 홈·메뉴 슬롯: 폰에 키가 없으면 "AI 연결이 필요해요"(설정으로 가는 액션), 있으면 숨김, PC 경로 문구 불변. `main._on_ai_connect()` 가 폰이면 설정의 AI 카드를 연다(훅으로 확인) | 시험 |
| PWI-8 | `Backend.llm_missing_text()` 폰 문구 교체, PC 문구·`llm_missing()` 의 PC 의미 불변(`ai_connect_test`·`settings_view_test` 기준선) | C-0 표 |
| PWI-9 | `main.gd` 변경은 `_on_ai_connect`·시작 화면 안내 함수 범위뿐(`git diff -U0 godot\scripts\main.gd`), E6 의 `_menu_summary` 변경과 겹치지 않음 | diff |
| PWI-10 | 일부러 틀린 입력: 키는 있는데 `Route` 가 `none`·키 파일 손상·프리셋 `""`·`phone_ai_consent` 가 숫자 → 에러 0, "저장만"으로 안전하게 | 시험 |
| PWI-11 | 상수 변이: 폰 동의 시트를 건너뛰게(동의 없이 요청) 바꾸면 PWI-3 이 **FAIL** | 줄 존재 |
| PWI-12 | 금지: `talk_view.gd` 수정, 서버 요청 모양 변경, v200 소유 파일 중 `after=` 선언 밖 수정, 소유 밖 파일 | X-8 |

### 6.18 PZ — 문서 (`worker`, 5파, 위험도 낮음)
| ID | 조건 | 명령 → 기대 |
|---|---|---|
| PZ-1 | `README.md` 의 폰 단독 절에 2.0.1(모델 내려받기 약 60 MB·와이파이 확인·오프라인 채점·`score_where`·"폰 간이 채점"·음소/억양/일본어는 PC), 2.0.2(AI 키 넣는 법·업체별 요금·개인정보 고지·일기는 업체 정책에 따름·한계: 암호화는 눈속임 수준·화면 캡처)를 정확히 적음. 다른 절 변경 0 | `git diff --stat` + 사실을 코드와 대조 |
| PZ-2 | `ROADMAP.md` 에 2.0.1·2.0.2·2.1.0(PI-L)와 "알려진 문제·실기 미검증"(§0.1 의 확인 못 한 것) | `Select-String` 키워드 |
| PZ-3 | `INSTALL.md` 폰 절에 업데이트 방법(직접 설치, 모델은 유지), 모델 지우기, 키 지우기 | 확인 |
| PZ-4 | 비밀값·개인 경로 0(`rg -n "C:\\\\Users\\\\\|secrets\|token\|FAKEKEY" README.md ROADMAP.md INSTALL.md` 새 줄 없음), 버전 숫자 올리기·`WORKLOG.md` 수정 0 | C-6 |

### 6.19 통합 시험 T (오케스트레이터가 직접 재실행, 릴리스마다)
- 소유권 검사 §5.5 → `files 108 dirs 1 tasks 17 ordered 9 OK`. v200 §13.5 검사도 그대로 OK.
- **2.0.1(P-ASR)**: 새 시험 전부(PC·`-- --phone`, 화면은 `--font-scale=1.5`·`--dark`): `route_test`, `score_parity_test`, `model_store_test`, `stt_model_card_test`, `local_stt_test`, `native_bridge_test`(DLL·모델 있을 때), `phone_settings_asr_test`, `phone_score_wiring_test`, 도구 `test_make_score_golden.py`·`test_calib_fit.py`·`--check`. `check_phone_native.ps1 -SelfTest`와 실제 APK 검사. 회귀: v200 §14.3 회귀 목록 전체 + 일본어 시험 **한 줄도 바뀌지 않고** 통과. **사용자 실기 H1~H6.**
- **2.0.2(P-AI)**: `ai_secrets_test`, `ai_client_test`, `ai_json_test`, `ai_state_test`, `ai_chat_parity_test`, `ai_feedback_parity_test`, `local_ai_test`, `phone_ai_sheet_test`, `phone_settings_ai_test`, `phone_ai_wiring_test`, `diary_screen_test`, `diary_flow_test`, `ai_connect_test`, `mission_test`, 도구 `make_ai_golden.py --check`·`test_make_ai_golden.py`·`make_ai_json_golden.py --check`. 정적 검사 X-7. **사용자 실기 H7~H11.**
- 공개 점검: X-2, X-3, `publish_release.ps1 -ScanOnly`, `check_no_media.ps1`, `git ls-files` 직접 확인, 올라가는 APK 에 키·모델 없음, 서명 지문 고정값. 릴리스 후 APK 링크·`models-1` 자산 링크(HF 미러 포함) 열기, 업데이트 확인.

---

## 7. 사용자 실기 확인 목록 (폰 1대, adb) — "사용자 실기"로 표시한 시험

사용자 폰 정보(기종·안드로이드 버전·RAM·남은 공간·16 KB 페이지 여부)는 **지금은 모른다**(§9 Q1). 모든 항목은 사용자 실기이며 결과는 O/X 로 기록한다.

| ID | 무엇을 | 어떻게(명령 예) | O 기준 | 관련 |
|---|---|---|---|---|
| H1 | **G1: 비-Gradle APK 의 확장 로딩 + 전사 속도** | 프로브 APK 설치(`adb install -r`), 앱 실행, `adb logcat -s godot` 로 프로브 출력 확인, `tiny.en`·`base.en` 모델은 `adb shell run-as <pkg>`(디버그 템플릿이라 가능, **추측**)로 앱 폴더에 넣음 | `WhisperBridge` 사용 가능, 5초 발화 전사 성공, base p50 ≤ 8초, RAM 증가 ≤ 700 MB, 비정상 종료 0 | PA1-7 |
| H2 | 모델 내려받기(와이파이): 처음부터, 중간에 비행기 모드→해제로 끊고 [이어받기], 앱 전환·화면 끄기, 용량 부족 시도(남은 공간이 적은 상태 또는 큰 파일로 채움) | 앱 UI + `adb shell df /data` | 이어받기로 완료·sha 검증 통과, 용량 부족이면 시작 전 거절, 취소·삭제 동작 | PA3 |
| H3 | **속도·배터리·발열**: 같은 문장 20회 채점 `stt_ms`(logcat 의 숫자 줄), 60회 연속 전후 배터리 %·온도 | `adb shell dumpsys battery`, `adb shell dumpsys meminfo <pkg>` | §1.7 표(p50 ≤ 3.0초, p95 ≤ 6.0초, 60회 ≤ 4%p, ≤ 6.0 °C, RAM ≤ 600 MB). 미달이면 tiny/q8 비교 보고 | PA4, PA5 |
| H4 | **채점 체감**: 정상으로 읽기 10문장 vs 일부러 틀리게 10문장 | 앱의 말하기 | 정상은 대체로 70+, 틀린 단어는 ✗ 표시. 이상한 점수가 3개 이상이면 X | PA5 |
| H5 | **비행기 모드 전체 흐름**: 모델 설치 후 비행기 모드에서 레슨·쉐도잉·코스 말하기 채점 | 앱 | 채점이 동작하고 네트워크 요청 0(앱 표시 "폰 간이 채점") | PA4, PWA |
| H6 | **저사양 시나리오**(가능하면): RAM 적은 다른 폰 또는 백그라운드 앱 많이 켠 상태 | 앱 | 느려도 크래시 0, 안내 문구가 §1.7 대로 | PA4 |
| H7 | **AI 키 실제 사용**: 실제 키로 대화·교정·피드백·일기 1회씩(와이파이), 요청 횟수 표시 | 앱 | 응답 정상, 키가 화면에 전체로 안 보임, 마지막 4자만 | PI1~PI3, PWI |
| H8 | **키 비노출·저장 위치**: 대화·일기를 한 뒤 `adb logcat -d` 를 검색해 키·사용자 글 조각이 없음, 디버그 빌드에서 `adb shell run-as <pkg> ls files` 로 `ai_secrets.bin` 이 앱 **내부** 폴더에 있고 평문 키 조각이 없음(`run-as <pkg> cat … \| strings`), `adb shell dumpsys package <pkg> \| findstr allowBackup` 에 백업 꺼짐 | adb | 0건, 내부 폴더, 백업 꺼짐 | PI1, PA7 |
| H9 | **오프라인·한도·키 오류 문구**: 비행기 모드에서 대화, 일부러 틀린 키, (가능하면) 한도 초과 | 앱 | §2.7 문구가 나오고 크래시 0, 일기는 `saved` 유지 | PI2b, PWI |
| H10 | **PC↔폰 동기화에 키 없음**: 키를 넣은 폰을 PC 와 동기화한 뒤 PC `progress.json`·허브 파일에서 키 조각 검색(검색어는 키 마지막 4자만 사용, 출력 금지) | PC `Select-String` | 0건 | K2 |
| H11 | **16 KB 페이지 기기**(해당될 때): `adb shell getconf PAGE_SIZE` 가 16384 면 앱이 실행되고 호환 모드 경고가 없는지 | adb | 정상 실행 | PA1, PA7 |
| H12 | (선택 스파이크) JavaClassWrapper 로 Keystore 시험 | 프로브 | 성공하면 보고(강화안 근거), 실패해도 무관 | K-스파이크 |

---

## 8. 위험 요소와 대안, 일부러 틀린 입력

### 8.1 위험 요소
| # | 위험 | 영향 | 대응·대안 |
|---|---|---|---|
| R-P1 | **G1 실패**: 4.6.3 에서 비-Gradle APK 의 `.so` 가 안 올라가거나 NDK/godot-cpp 조합이 안 됨, 16 KB 문제 | P-ASR 불가 | 스파이크 첫 작업으로 확인(소스상 경로는 4.6 에서 확인됨). 대안: 길 B(SCons), Gradle 전환(별도 설계, `build_android.ps1`·서명·검증 전체 변경), 자가 평가 유지. P-AI 는 독립 |
| R-P2 | 폰 전사가 느리거나 정확도가 낮음(학습자 발음에 특히) | 말하기 불만 | tiny/`q8_0`(승인), `beam` 2~3, 12초 중단 후 PC·자가 평가, 보정 합격선 미달 시 "폰 간이 채점" 유지 |
| R-P3 | `p` 분포가 달라 보정 실패 → 점수가 들쭉날쭉 | 신뢰 하락 | 합성 + 사용자 녹음, 보류 데이터 평가, 합격선, 항등 매핑 + `score_uncalibrated` 표시 |
| R-P4 | 토큰 시각이 부정확(experimental) → 유창성(쉼 벌점) 오차 | 점수 왜곡 | 보정 지표에 유창성 포함(MAE ≤ 15), 세그먼트 시각·평활, 필요하면 유창성 비중을 폰에서만 낮춤(오케스트레이터 결정) |
| R-P5 | 모델 호스팅·다운로드 실패(GitHub 리다이렉트 호스트 변경, 속도, 데이터 요금) | 설치 불가 | HF 미러, 이어받기, sha256, 와이파이 확인, `models-2` 로 새 태그(지우고 다시 하지 않음) |
| R-P6 | NDK·godot-cpp·whisper.cpp 버전 호환·빌드 시간·디스크 | 일정 | 커밋·NDK 고정(`BUILD_INFO.json`), ★승인, 소스는 추적 안 함 |
| R-P7 | **추적되는 `.gdextension` 이 라이브러리 없는 환경(새 워크트리·리뷰어)에서 모든 Godot 실행에 오류** | 기존 시험 소음·실패 | `.gdextension` 은 **빌드가 생성**(추적 안 함), `.in` 템플릿만 추적. `engine_missing` 으로 안전 처리. PA7-6 이 "네이티브 없는 빌드도 가능"을 확인 |
| R-P8 | **AI 키 유출**(로그·리다이렉트·오류 본문·백업·화면·동기화·클립보드) | 금전·개인정보 | §2.4 K1~K12, 공개 스크립트 키 정규식, 실기 H8·H10, 지출 한도 안내 |
| R-P9 | 무료 등급 업체가 보낸 글을 학습에 씀 / 업체 정책 불명 | 일기 등 개인 글 | 업체별 동의·경고, 무료 학습 업체는 일기 기본 꺼짐, 문구에 "확인하지 못함"을 정직하게 |
| R-P10 | 업체 문서·모델명·엔드포인트가 자주 바뀜(프리셋 모델 `gemini-2.5-flash` 등이 낡음) | 호출 실패 | [모델 목록 확인]·직접 입력, C0, 오류 `ai_model` 안내, 릴리스마다 프리셋 점검 |
| R-P11 | 서버 프롬프트가 바뀌어(특히 v200 R2) 폰과 어긋남 | 결과 차이 | `make_ai_golden.py --check` 를 통합 시험 T 에 포함, 실패하면 PI-L/갱신 작업 |
| R-P12 | 요금 폭주(긴 대화·오타·반복) | 금전 | history 24개·`max_tokens` 제한, 자동 재시도 없음(`bad_format` 1회 제외), "오늘 N번" 표시, 업체 지출 한도 안내 |
| R-P13 | v200 파일과의 병합 충돌(`main.gd`·`diary_screen.gd`·`mission_screen.gd`·`shadow_screen.gd`·README·ROADMAP) | 병합 지연 | `after=` 순서(소유권 스크립트가 강제), `main.gd` 는 함수 범위만, v200 E6·E7·Z 병합 뒤 4·5파 |
| R-P14 | 폰 우선 채점으로 PC+폰 사용자가 음소 팁을 잃음 | 기능 후퇴 체감 | `score_where="pc"` 한 줄 복귀, 릴리스 노트, 음소 화면은 PC 우선(`need_ph`) |
| R-P15 | 메모리 부족·발열로 전사 중 종료(저사양) | 크래시 | RAM 기준·tiny 제안, 12초 중단, 2회 연속 실패 시 자동 끔, 앱 일시정지에서 `abort()`+`unload()` |
| R-P16 | JavaClassWrapper Keystore 가 안 됨/불안정 | 강화안 무산 | 선택 스파이크일 뿐, B 안 유지 |
| R-P17 | 사용자 녹음 개인정보 | 프라이버시 | ★동의, scratch 한정, 보고에 숫자만, 기본 삭제 |
| R-P18 | Whisper 가 틀린 발음을 문맥으로 "고쳐서" 전사해 채점이 관대함(PC 도 같은 한계) / 무음·소음에서 환각 문장 | 채점 신뢰 | 틀린 단어 합성 시험(PA5)으로 측정, 앞뒤 무음 제거·무음 임계값, 보정 합격선(틀린 클립 통과 ≤ 10%) |
| R-P19 | 16 KB 페이지·구글 플레이 요건(2027-02-01) | 나중 | NDK r28b 기본 16 KB 정렬, PA7 이 매 빌드 확인. 플레이 등록은 이 문서 범위 밖 |
| R-P20 | GDScript 로 `difflib` 이식 시 동점 처리 차이 | 점수 차이 | PA2 황금(정렬 쌍 300) 완전 일치 요구 |
| R-P21 | `HTTPRequest` 가 리다이렉트에 헤더를 따라 보내는지 불확실 | 키 유출 | `max_redirects=0` + 시험(PI1-6) |
| R-P22 | 업데이트로 사용자가 폰 채점 존재를 모름 | 미사용 | 릴리스 노트·홈 안내(PWA 의 자가 평가 위젯 위 [모델 받기]) |

### 8.2 일부러 틀린 입력으로 확인하는 실패 시나리오
| # | 입력 | 기대 | 담당 |
|---|---|---|---|
| F1 | 매니페스트 sha256 을 틀리게 / 모델 파일을 절반으로 자름 | `model_corrupt`, 파일·`.part` 정리, 크래시 0 | PA3-4, PA1-5 |
| F2 | 서버가 Range 무시(200) / 40%에서 끊김 / 416 | 처음부터 또는 이어받아 성공 | PA3-3 |
| F3 | 남은 공간이 모자람(가짜) / 공간 값 0 | 요청 0건으로 거절 / 확인 후 쓰기 오류 시 정리 | PA3-5 |
| F4 | 허용 밖 호스트·`http://` 로 리다이렉트 | 거절 | PA3-6 |
| F5 | 0바이트·깨진 base64·비 WAV·무음·60초 초과 오디오 | 400 한국어 / 점수 0 + 안내 / 30초로 자름 | PA4-5 |
| F6 | 전사가 12초 넘게 걸림 / 전사 중 앱이 백그라운드로 | `abort()`·`stt_timeout`→PC 재시도 또는 자가 평가 / 정상 복귀 | PA4-6, PA4-7 |
| F7 | 브리지가 `engine` 오류·음수 `p`·`start>end` | `engine_error` 재시도 또는 값 보정, 크래시 0 | PA4-10 |
| F8 | `score_params.json` 이 없음·비단조·모델 id 불일치 | 항등 + `score_uncalibrated`, 앱은 계속 | PA4-3 |
| F9 | PC·폰 결과를 섞어 보정 | `CALIB_FAIL`, 파일 안 씀 | PA5-6 |
| F10 | `.so` 1바이트 변경 / `.so` 없음 / 정렬 안 된 `.so` / `allowBackup=true` | 빌드 거절·검사 실패 | PA7-2, PA7-4 |
| F11 | 키 형식 위반(공백·`Bearer `·따옴표·길이) / 키 파일 손상 / 기기 값 변경 | 저장 거절 / `.bad` 격리 후 "키 없음", 크래시 0 | PI1-2, PI1-3 |
| F12 | `http://`·`file://`·사용자 정보 포함 주소 | `ai_url`, 요청 0건 | PI1-8 |
| F13 | 업체가 302 로 다른 호스트 지정 / 오류 본문에 키 에코 | 따라가지 않음 / 화면·로그에 키 0 | PI1-6, PI1-7 |
| F14 | 401·429·404·503·타임아웃·연결 거부·TLS 오류·JSON 아님 | 각 `ai_*` 코드와 §2.7 문구, 무한 재시도 없음 | PI1-5 |
| F15 | 키 없음에서 `/chat`·`/fix` / 일본어 요청 | `no_ai`·`ja_ai_pc`, 네트워크 0 | PI2b-3 |
| F16 | 가짜 모델 답이 한글 영어 `reply`·빈 값·JSON 아님 | 서버와 같은 결정(황금) | PI2b-8 |
| F17 | 서버 프롬프트를 메모리에서 한 글자 변경 | `--check` 종료 1 `GOLDEN_DRIFT` | PI2a-5 |
| F18 | 일기 원문 마커를 `print`·`Toast` 로 일부러 출력하는 가짜 화면 | 검사기가 **잡아냄**(검사기 자체 확인) | PI2b-4, PWI-5 |
| F19 | 무료 학습 업체 + 일기 | 기본 꺼짐, 동의 전 요청 0건 | PWI-4 |
| F20 | `score_where`·`ai_preset` 에 이상한 값 | 기본값으로 취급, 크래시 0 | PS-6, PWI-10 |
| F21 | `.gdextension` 이 없는 새 워크트리에서 기존 시험 | `SCRIPT ERROR:` 0, `engine_missing` | PA1-4, PA7-6 |
| F22 | 상수 변이(각 작업 C-12) | 그 작업 시험이 FAIL 하는 줄 | 각 작업 |

---

## 9. 오케스트레이터가 정할 것과 사용자에게 물을 것 (추천안 포함)

### 9.1 사용자에게 물을 것

> **확정 (2026-11-18, 사용자 "갤럭시 s24 다 동의 추천대로")**: Q1 폰 = 삼성 갤럭시 S24(안드로이드 버전·RAM·남은 공간·16 KB 페이지는 adb 연결 때 확인). Q2~Q10 모두 승인·추천안: NDK·godot-cpp·whisper.cpp·임시 SCons·시험 모델 2개 설치/다운로드 승인, AI 키는 OpenCode Zen 유료 크레딧(채팅에 붙이지 않고 PI0 때 환경변수), 모델 `base.en-q5_1`, 보정 녹음 동의, 폰 우선 채점, 2.0.1·2.0.2 분리, 무료 학습 업체 일기 기본 꺼짐, 영어만, `models-1` + HF 미러. 오케스트레이터 O-1 결정: 폰 1파는 **P0 ∥ PA1(스파이크) ∥ PI2a** 먼저, PA2·PI1 은 그 뒤.
| # | 질문 | 추천 |
|---|---|---|
| **Q1** | **폰 기종·안드로이드 버전·RAM·남은 저장 공간·USB 디버깅 가능 여부**(설정 > 휴대전화 정보). 실기 시험(H1~H12)과 모델 선택·16 KB 여부가 여기에 달렸습니다 | 알려 주세요. 모르면 설정 화면 캡처(비밀 정보 가리고) 또는 `adb shell getprop ro.product.model`·`ro.build.version.release`·`getconf PAGE_SIZE` 결과 |
| **Q2** | ★**도구 설치·다운로드 승인**: Android NDK `28.1.13356709`(설치 후 약 1.5 GB, SDK 폴더), godot-cpp·whisper.cpp 소스(`git clone` 2개), 임시 가상환경의 SCons, 시험용 모델 2개(92 MB). 모두 저장소 밖·`native\_deps`(추적 안 함) | **승인**(디스크 여유 충분). 설치 뒤 `PA1` 스파이크 시작 |
| **Q3** | **AI 키 종류**: ① OpenCode Zen **유료 크레딧**(1.5.0 키 재사용, 소액 충전) ② Gemini **무료 등급**(비용 0, 개인정보 학습 사용 고지) ③ DeepSeek 직접 ④ OpenRouter 무료 모델. 지금 가진 키가 있나요? | ①을 1순위(C0 로 먼저 확인), 비용을 안 쓰려면 ②(일기는 기본 꺼짐). 지금 키를 채팅에 붙여 넣지 말고 C0 때 환경변수로 |
| **Q4** | **모델 선택**: 영어 전용 `base.en-q5_1`(약 60 MB, 기본) / 느리면 `q8_0`(약 82 MB) / 저사양 `tiny.en-q5_1`(약 32 MB). 다국어·일본어 모델은 안 받음 | 기본 `base.en-q5_1`, 스파이크 결과로 조정(q8_0 은 다시 승인 요청) |
| **Q5** | ★**보정용 목소리 녹음 동의**: 영어 문장 30개를 정상으로 1번, 일부러 틀리게 1번(약 8분, PC 마이크). 파일은 이 PC 임시 폴더에만 있고 저장소·인터넷으로 나가지 않으며 보정이 끝나면 삭제(원하면 보관)합니다 | **동의**. 안 하면 합성 음성만으로 보정하고 "사용자 목소리 미검증"으로 표시 |
| **Q6** | **채점 위치 기본값**: 폰이 주인공이므로 자동 모드에서 **폰 우선**(PC 연결 중에도 폰 채점, 음소 분석 화면만 PC). PC 로 쉐도잉하던 분은 음소 팁이 줄고 설정에서 "PC 우선"으로 되돌릴 수 있습니다 | **폰 우선** |
| **Q7** | **릴리스 묶음**: 2.0.0 = R1 만, 2.0.1 = 폰 음성 인식, 2.0.2 = 폰 AI, 2.1.0 = R2 + 수준 맞춤 이식(번들 B: 2.0.2 생략하고 AI 를 2.1.0 에) | 추천안(2.0.1·2.0.2 분리). P-ASR 이 2.0.0 동결 1주 전까지 준비되면 2.0.0 에 합치기 |
| **Q8** | **개인정보 정책**: 무료 등급이 보낸 글을 학습에 쓰는 업체(Gemini 무료)는 **일기 교정을 기본 꺼짐**(별도 동의로만), 대화·피드백은 키 저장 때 동의 한 번 | 예 |
| **Q9** | **범위 확인**: 폰 음성 인식·AI 는 **영어만**(일본어는 계속 PC), AI 레슨·노래 AI·문맥 뜻풀이는 폰에서 안 함 | 예 |
| **Q10** | `models-1` GitHub 릴리스(모델 파일 업로드)는 공개 쪽 변경이라 오케스트레이터가 직접 합니다. Hugging Face 를 미러로 같이 써도 되나요 | 예(같은 sha256 으로만 허용) |

### 9.2 오케스트레이터가 정할 것
| # | 항목 | 이 문서의 기본 |
|---|---|---|
| O-1 | 1파를 v200 1파와 **동시에** 돌릴지(워커 5명 추가: P0·PA1·PA2·PI1·PI2a) 또는 PA1(+P0) 만 먼저 | 파일 겹침은 0 이므로 가능. 비용이 걱정이면 **PA1 스파이크 + P0 + PI2a** 만 먼저 |
| O-2 | G1 판정(통과선 p50 ≤ 8초·RAM ≤ 700 MB, 제안값)과 no-go 때 방향(Gradle 전환 별도 설계 vs P-ASR 보류) | 보류 + P-AI 진행 |
| O-3 | 보정 합격선(§1.6)·속도 목표(§1.7)·통과선 70 의 폰 조정 여부(모두 제안값) | 측정 뒤 결정 |
| O-4 | PI0(C0) 시험 일정과 프리셋 기본 모델 id 확정(낡은 모델명 갱신) | PA/PI1 시작 전 |
| O-5 | 새 최상위 폴더 `phone_src\`·`native\` 가 PC 설치 파일에 섞이지 않는지 | 확인함: `packaginguild_dist.ps1` 은 `backend\`(robocopy)·exe·`packaging\` 의 정해진 파일만 복사하므로 새 폴더는 배포 안 됨, `publish_release.ps1` 의 금지 폴더 목록에도 없음. 남은 확인은 `check_zip.py` 가 새 폴더를 이상하게 보지 않는지(PA7·T 에서 `-ScanOnly` 로 확인) |
| O-6 | worktree `app_wt\v200p_<작업>`·브랜치 `v200p/<작업>`, 합치는 순서(§5.2), `.uid`·`--import` 처리 | 문서 기본 |
| O-7 | v200 E6·E7·Z 가 main 에 병합된 시점에 4·5파 시작(소유권 스크립트로 `after=` 재확인, `main.gd`·`diary_screen.gd`·`mission_screen.gd`·`shadow_screen.gd` 가 바뀌었는지 보고 §5.3 줄을 다시 맞춤) | 병합 직후 |
| O-8 | `models.json` 의 `bytes`·`sha256` 확정(★실제 파일 다운로드 승인 뒤 오케스트레이터가 계산, HF LFS 표시값과 대조) | PA3 시작 전 |
| O-9 | 버전 올리기·`version/code`·릴리스·모델 릴리스 업로드·공개 후 링크 확인은 오케스트레이터가 직접 | `ROADMAP.md` 절차 + CLAUDE.md 체크리스트 |
| O-10 | 선택 스파이크 K(JavaClassWrapper Keystore)를 2.0.2 뒤에 할지 | 하지 않아도 무방 |

---

## 10. 조사 출처 (읽기만 함, 2026-11-17)
- OpenCode Zen 문서(무료 모델·엔드포인트·가격·데이터 정책): https://opencode.ai/docs/zen/ , OpenCode Go: https://opencode.ai/docs/go/
- Gemini API OpenAI 호환(기본 URL·인증, `ai.google.dev` 는 `aistudio.google.com` 으로 이전): https://aistudio.google.com/docs/openai , 가격·무료 등급·데이터 사용: https://aistudio.google.com/docs/pricing , 한도 문서(무료 한도 숫자는 이 페이지에서 확인 못 함): https://aistudio.google.com/docs/rate-limits , 지원 국가: https://aistudio.google.com/docs/available-regions
- DeepSeek 가격·모델·기본 URL: https://api-docs.deepseek.com/quick_start/pricing , 개인정보 방침(소비자 서비스): https://cdn.deepseek.com/policies/en-US/deepseek-privacy-policy.html
- OpenRouter 한도: https://openrouter.ai/docs/api-reference/limits
- whisper.cpp README: https://raw.githubusercontent.com/ggml-org/whisper.cpp/master/README.md , C API: https://raw.githubusercontent.com/ggml-org/whisper.cpp/master/include/whisper.h , 모델 목록: https://huggingface.co/ggerganov/whisper.cpp/tree/main , 모바일 벤치(간접, 같은 장치·길이 불명): https://voiceping-landingpage-prod.pages.dev/en/blog/research-offline-speech-transcription-benchmark/
- godot-cpp README: https://raw.githubusercontent.com/godotengine/godot-cpp/master/README.md , Android 도구: https://raw.githubusercontent.com/godotengine/godot-cpp/master/tools/android.py
- Godot 4.6 `export_plugin.cpp`(`save_apk_so`): https://raw.githubusercontent.com/godotengine/godot/4.6/platform/android/export/export_plugin.cpp
- Android 16 KB 페이지: https://developer.android.com/guide/practices/page-sizes
- Godot 클래스 문서: https://docs.godotengine.org/en/stable/classes/class_diraccess.html , https://docs.godotengine.org/en/stable/classes/class_os.html , https://docs.godotengine.org/en/stable/classes/class_javaclasswrapper.html (이 페이지는 4.7 문서로 보임 — 4.6.3 에서의 존재는 추측), https://docs.godotengine.org/en/stable/tutorials/io/data_paths.html
- GitHub 릴리스 한도: https://docs.github.com/en/repositories/releasing-projects-on-github/about-releases
- 로컬: `backend\.venv\Lib\site-packages\faster_whisper\transcribe.py` 1748행(단어 확률 평균), `backend\server.py`·`llm_api.py`·`llm_common.py`·`missions.py`, 오케스트레이터 메모(Android SDK·키 위치).

---

## 요약 (12줄)
1. 폰이 주인공: PC 앱은 그대로, 폰은 기존 `Route`/`LocalApi` 의 `stt`·`ai` 빈자리(`local_stt.gd`·`local_ai.gd`)를 채운다. 화면 코드는 거의 안 고친다.
2. P-ASR: whisper.cpp 얇은 GDExtension(`WhisperBridge`), arm64, **Gradle 없음**(Godot 4.6 `save_apk_so` 가 `.so` 를 `lib/arm64-v8a/` 에 넣음). 이 PC 에는 NDK·SCons·godot-cpp·whisper.cpp 가 없고 CMake 4.3.1·Ninja·VS2022 는 있다. ★NDK `28.1.13356709`·소스·모델 받기는 사용자 승인 필요. `.gdextension`·`.so` 는 추적하지 않고 빌드가 생성(새 워크트리 오류 방지).
3. 모델: 영어 전용 `ggml-base.en-q5_1.bin` 59.7 MB(저사양 `tiny.en` 32.2 MB), GitHub 릴리스 `models-1` + HF 미러, sha256 은 APK 안에 고정, `HTTPClient` 스레드 이어받기, 저장 공간·와이파이 확인.
4. 점수: `ScoreCore` 는 PC `score_en` 과 같은 입력=같은 출력(황금), 폰 `p` 는 단조 `p_map`+`ok_prob` 로 보정(합성 음성 ≥ 1,000클립 + ★사용자 녹음 약 60클립, 합격선: 단어 `ok` 일치율 85%/80%). 속도 목표 p50 ≤ 3초·p95 ≤ 6초·12초 중단, 저사양은 tiny 또는 자가 평가.
5. Route: `/stt`·`/score` 는 **폰 우선**(설정 `score_where`), 음소 분석만 PC(`need_ph`), 폰 엔진 오류는 PC 1회 재시도. AI 는 PC 우선 유지(폰 키 자동 전환 없음 — 요금 보호).
6. P-AI: 1.5.0 키는 같은 종류지만 **무료 DeepSeek 는 폰에서 못 쓴다**(문서·과거 실측). 프리셋 4종(Zen 유료·DeepSeek·Gemini·OpenRouter), 기본 선택 없음, 비용 감은 월 $0.5 안팎(추정). C0 로 사용자 키 1회 시험.
7. 키 저장: 평문 / 기기 결합 암호화 / Android Keystore 비교 → **기기 결합 암호화 파일 + 백업 끔 + 내부 저장소 확인**, "눈속임 수준" 한계를 화면에 적음. 노출 규칙 K1~K12(리다이렉트 `max_redirects=0`, 오류 본문 키 치환, 동기화 화이트리스트 밖, 공개 스크립트 키 정규식 회피).
8. 프롬프트·검증은 GDScript 로 문장 단위 복사 + 서버 함수를 부르는 파이썬 황금 생성기(`--check` 로 드리프트 감지), 서버 변경 0. 폰 AI 는 영어의 `/chat`·`/fix`(private)·`/feedback`·`/missions/judge`.
9. 개인정보: 폰용 동의 문구 신설(업체별), 무료 학습 업체는 일기 교정 기본 꺼짐. 실패 문구 표(키 없음·오프라인·TLS·키 오류·한도·바쁨·모델 없음·형식 오류·일본어).
10. 폰 우선 화면 점검 19곳(route.gd·capability_panel·self_rate_panel·shadow_screen·song_sing_tab·diary_screen·mission_screen·home_ai·main·backend·settings_view 등)과 각각의 변화, 코드 변경 없이 되는 곳(lesson_view·talk_view)도 표시.
11. 출시: 2.0.0 = R1 그대로, **2.0.1 = P-ASR, 2.0.2 = P-AI, 2.1.0 = R2 + 수준 맞춤 이식**(번들 B 대안). 작업 17개(P0, PA1~PA5·PA7, PI1·PI2a~c·PI3, PSA·PSI, PWA·PWI, PZ), v200 1파(K1·K0·E1·E2)와 파일 겹침 0, v200 E6·E7·Z 파일은 `after=` 순서로만 수정(소유권 스크립트가 강제).
12. 사용자에게: 폰 기종·RAM·공간(Q1), 도구 설치·다운로드 승인(Q2), AI 키 종류(Q3), 모델(Q4), 보정 녹음 동의(Q5), 폰 우선 채점(Q6), 릴리스 묶음(Q7), 일기 개인정보 정책(Q8), 영어만(Q9), 모델 릴리스·HF 미러(Q10).
