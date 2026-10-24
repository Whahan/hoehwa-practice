# 폰 단독 사용(PC 없이 폰만으로) 타당성 조사 + 설계

- 작성: designer (설계만, 코드·설정 수정 없음) / 조사일: 2026-10-17 / 대상 버전: 1.3 (가칭, 1.2 동기화 다음)
- 읽은 것(코드로 확인): `backend\server.py`(엔드포인트·STT·TTS·채점·chat·fix·feedback·lesson), `features.py`(음소·억양), `lesson_rules.py`, `reading.py`, `practice.py`, `missions.py`, `grammar.py`, `llm_opencode.py`·`llm_api.py` 머리글, `lan.py` 허용 목록, `config.json`, `requirements.txt`, `content\*.json`, `cache\`·`data\`·`models\` 크기, `godot\scripts\autoload\{api,backend,recorder,tts}.gd`, `core\{platform,mission_logic,text_sim,wav_util}.gd`, `practice\dictation_diff.gd`, `godot\export_presets.cfg`, `packaging\build_android.ps1`, `docs\android_remote_design.md`, `docs\sync_design.md`, `API.md`, 만들어진 APK 크기. 데이터 파일은 **개수·크기·스키마만** 봤고 사용자 폴더(`%APPDATA%\Godot\app_userdata\...`)와 비밀값(`secrets.json`, OpenCode 로그인)은 열지 않았다.
- 웹 조사(문서 읽기만, 내려받기 없음): Android 소스(SpeechRecognizer·RecognizerIntent·RecognitionPart), Godot 4.5 소스(`GodotTTS.java`, `export_plugin.cpp`)와 공식 문서(DisplayServer, Android 플러그인), whisper.cpp README·Hugging Face 모델 목록, Vosk 모델 표, sherpa-onnx 문서(Kokoro), OpenCode 문서(Zen·server)와 약관, LanguageTool 공개 API 문서·개인정보 방침, ML Kit GenAI 문서, 웹 검색 결과.
- 표기: **(추측)** = 코드·문서로 확인하지 못한 가정이나 기억. **(실측 필요)** = 실제 폰에서 재야 하는 값. 표기 없는 것은 코드·문서에서 확인한 사실. 모든 수치 중 "예상"은 추정치다.
- 경로 표기: 저장소 루트(앱 폴더)를 `<repo>`, 개인 폴더를 `%USERPROFILE%`로 쓴다.

---

## 0. 한눈에 보기

### 0.1 결론

**"PC 기능을 전부 같은 품질로 폰에서"는 불가능하다. 하지만 "연결 없이도 매일 공부하는 핵심 고리"는 가능하다.** 기능을 네 등급으로 나눈다.

| 등급 | 뜻 | 기능 |
|---|---|---|
| A 그대로 가능 | 규칙·데이터만 있으면 되고 AI·모델이 필요 없다 | 레슨(예문 기반), 복습(FSRS, 이미 폰 안에서 동작), 받아쓰기, 쉐도잉 문장, 약한 소리 연습 목록, 미션 규칙 판정·대본 모드, 로드맵·기록, 읽기(영어), 예문 검색(축소판) |
| B 낮은 품질로 가능 | 모델을 내려받아 폰에서 돌리면 되지만 PC보다 느리고 덜 정확하다 | 음성 인식·단어 단위 채점(whisper.cpp), 말하기, 시스템 음성(TTS) |
| C 조건부 | 사용자의 API 키(비용·개인정보 감수) 또는 PC 연결이 있어야 한다 | AI 대화·교정·피드백·AI 레슨·AI 미션 판정, 문맥 뜻풀이, 문법 교정 |
| D 폰 단독에서는 어렵다 | 모델이 너무 크거나 만들 도구가 없다 | 음소 단위 교정, 억양 그래프, 무료 DeepSeek(OpenCode), 일본어 형태소 분석을 쓰는 읽기, 오프라인 AI 대화(v1 제외) |

### 0.2 핵심 결정

| # | 결정 | 이유 |
|---|---|---|
| D1 | **"기능 공급자" 계층(`Route`)을 `Api` 앞에 둔다.** 경로마다 `phone`(폰 안 처리) / `pc`(기존 HTTP) / `none` 중 하나를 고른다. 폰 안 처리는 `LocalApi`가 **기존 `API.md` 계약과 같은 모양의 결과**를 돌려준다. | 화면(views/practice)은 거의 안 고쳐도 된다. 지금 화면은 `Api.post_json("/lesson", ...)`처럼 경로만 안다(코드 확인). |
| D2 | **세 모드: 자동(기본) / 폰만 / PC만(기존 동작).** 자동 = PC가 닿으면 PC 우선, 안 닿거나 요청이 끊기면 폰 처리가 있는 기능만 폰으로. | 요구: 연결 모드와 단독 모드를 같이. 이미 PC에 붙어 쓰는 사람의 동작은 바뀌지 않는다. |
| D3 | **무거운 일은 PC에서 미리(빌드 때) 해 두고 폰에는 결과표만 싣는다.** 레슨 은행, 단어 IPA 표, 단어 뜻 사전, 일본어 읽기 표, 단어 빈도표. | 폰에 spaCy·espeak-ng(GPL)·pyopenjtalk·WordNet을 올릴 수 없다. 미리 계산하면 코드 이식 범위가 줄고 라이선스 문제도 피한다. |
| D4 | **음성 인식은 whisper.cpp GDExtension(arm64)으로 폰 안에서.** 영어 `base-q5_1`(약 60 MB), 일본어는 `small-q5_1`(약 190 MB)을 선택 다운로드. 안드로이드 `SpeechRecognizer`는 쓰지 않는다. | 단어별 확률·시각을 PC와 같은 모양(`words[{w,p,start,end}]`)으로 얻어 `score_en/score_ja`를 그대로 옮길 수 있다. `SpeechRecognizer`는 단어 확률이 없고(문서: 신뢰도는 결과 후보 단위, 단어 단위는 5단계 거친 값이며 인식기가 채울 때만) 쓰려면 Gradle 플러그인이 필요하다. 아래 §3.1. |
| D5 | **TTS는 Godot `DisplayServer.tts_*`(시스템 음성)로.** 파일로 못 받으므로 억양 비교는 못 한다. 핵심 문장은 후속 단계에서 "음성 팩"(PC에서 Kokoro로 미리 만든 Ogg)을 선택 다운로드. | 설치 0 MB. 지연 0. 단 일본어 음성은 기기에 따라 설치가 필요하다. |
| D6 | **AI는 기본 "없음".** 쓰려면 ① 사용자 본인 API 키(OpenAI 호환 업체) ② PC 연결(자동 모드에서 PC의 AI). 온디바이스 소형 LLM은 v1에서 제외. 무료 DeepSeek(OpenCode)는 폰 단독에서 못 쓴다. | OpenCode는 CLI+로그인이 필요하고, 이 저장소의 실측 기록(`llm_opencode.py`)은 "무료 모델은 OpenCode 프로그램 안에서만"이다. 폰에서 CLI를 못 돌린다. |
| D7 | **문법 교정은 폰 단독에서 "AI 키가 있을 때 AI가" 한다.** LanguageTool 공개 서버는 v1에서 넣지 않는다(결정 Q5). | 공개 API는 "자동화 트래픽용이 아님"(분당 20회), 문장이 외부로 나간다, 링크 표기 의무. |
| D8 | **새 네이티브 코드는 whisper.cpp 하나뿐(GDExtension). Gradle 커스텀 빌드로 바꾸지 않는다.** | `export_plugin.cpp`(4.5 브랜치)의 비-Gradle APK 경로가 GDExtension `.so`를 `save_apk_so`로 APK에 넣는다. 지금 `build_android.ps1`·서명·검증 흐름을 유지한다. 4.6.3에서의 동작은 **(실측 필요, 작업 B0)**. |
| D9 | **큰 모델은 APK에 넣지 않고 첫 실행 뒤 내려받는다(GitHub 릴리스 자산, SHA-256 고정).** APK는 100 MB 이하(목표 50 MB 안팎). | 지금 APK 26.65 MB(1.1.1). 모델은 앱 비공개 저장소에 두고 삭제 가능. |
| D10 | **점수·결과에 `via`(처리 위치)와 `degraded`(빠진 부분) 필드를 붙인다.** 화면은 이를 보고 "폰 간이 채점" 같은 표시를 한다. | PC 점수와 폰 점수가 숫자만으로는 같은 뜻이 아니기 때문(§3.3). |

### 0.3 용량 예산

| 항목 | 위치 | 예상 크기 | 근거 |
|---|---|---|---|
| 현재 APK(Godot 기본 템플릿 + 앱) | APK | 26.65 MB | `packaging\out\android\hoehwa-practice-android-1.1.1.apk` 26,654,259 바이트 |
| 1단계 데이터 팩(레슨 은행·풀·어휘·사전 등) | APK(`res://data/pack`) | 원본 약 15~20 MB, APK 안에서 압축되어 +5~8 MB **(추측)** | 현재 풀 JSON: 영어 3.19 MB + 일본어 1.14 MB, 미션 77 KB. 레슨 은행 세부는 §6 |
| 2단계 `whisper_bridge` `.so` (arm64) | APK | +6~10 MB **(추측)** | whisper.cpp 정적 링크, 양자화 지원 포함 |
| **APK 합계 목표** | | **≤ 50 MB 예상, 한계 100 MB** | |
| 음성 인식 모델 영어 `ggml-base-q5_1.bin` | 다운로드 | 59.7 MB | Hugging Face 목록 |
| 음성 인식 모델 일본어 `ggml-small-q5_1.bin` | 다운로드(선택) | 190 MB | 같음 |
| (대안) tiny `q5_1` 32.2 MB / base `q8_0` 81.8 MB / small `q8_0` 264 MB | | | 같음 |
| 음소 모델 wav2vec2 int8 ONNX | 다운로드(후속, 선택) | 약 300~330 MB **(추측)** | PC 쪽 fp32가 1.2 GB(`models\hf\models--facebook--wav2vec2-lv-60-espeak-cv-ft`), int8이면 약 1/4 |
| 음성 팩(Kokoro 미리 만든 Ogg, 후속) | 다운로드(선택) | 3,000문장 기준 약 25~30 MB **(추측)** | 문장당 약 9 KB(24 kbps 모노 3초) |

---

## 1. 목표와 범위

### 1.1 목표
1. PC도 인터넷 연결도 없이 폰에서 매일의 학습 고리(레슨 → 복습 → 말하기 → 기록)가 돈다. 처음 내려받기(모델)와 AI 사용만 인터넷이 필요하다.
2. 연결 모드에서는 지금과 같이 PC를 우선 쓰고, PC가 끊기면 폰이 할 수 있는 것은 폰이 대신 한다.
3. 폰이 PC만큼 못 하는 것을 사용자에게 **숨기지 않고** 화면에서 보여 준다(§12).
4. 폰에서 쌓은 기록은 기존 1.2 동기화로 나중에 PC와 합쳐진다(코드 변경 없이).

### 1.2 하지 않을 것
- 음소 단위 교정·억양 그래프·일본어 음소 분석의 폰 이식(v1~v3 제외, 후속 단계 D에서 가부 판정).
- 온디바이스 LLM(Gemini Nano, llama.cpp 등)의 제품 탑재(v1~v3 제외, 후속에서 실험만).
- 안드로이드 `SpeechRecognizer`·Android 플러그인(AAR)·Gradle 커스텀 빌드로의 전환.
- 앱이 운영하는 서버나 클라우드 계정, 모든 사용자 공용 API 키 내장(키는 사용자 본인 것만).
- PC 없는 기기 간 동기화(허브가 PC에 있음). 대신 후속으로 "기록 내보내기/가져오기"(§10 R12).
- 일본어 미션(PC에도 아직 없음, `missions.py` `JA_MSG`), 일본어 받아쓰기(PC도 영어만).
- iOS, x86 에뮬레이터용 네이티브 라이브러리(필요하면 시험용으로만).
- `backend\` 서버 코드의 기능 변경(단, 데이터 팩 빌드 도구와 그 시험 추가는 허용).

---

## 2. PC 백엔드가 하는 일 (코드로 확인) 과 폰 이식 가능성

| # | 기능 | 엔드포인트 | PC 구현(근거) | 크기·무게 | 폰 이식 | 등급 |
|---|---|---|---|---|---|---|
| 1 | 음성 인식 | `POST /stt` | faster-whisper `small`, int8_float16, CUDA 우선·CPU 대체. `beam_size=5`, `word_timestamps=True`, `vad_filter=True`. 단어별 `{w,p,start,end}` (`server.py transcribe`) | 모델 `models\hf\whisper` 464 MB | whisper.cpp GDExtension. 모델 `base-q5_1` 60 MB / `small-q5_1` 190 MB | B |
| 2 | TTS | `POST /tts`, `GET /tts/voices` | **Kokoro-82M**(`kokoro==0.9.4`) 영어 `af_heart`·일본어 `jf_alpha`. 일본어 G2P는 pyopenjtalk-plus. 디스크 캐시 300 MB(LRU) | 모델 314 MB | 시스템 TTS(`DisplayServer.tts_*`). 같은 목소리는 후속 "음성 팩"으로 일부만 | B |
| 3 | 발음 채점(단어) | `POST /score` | whisper 단어 확률 `p ≥ OK_PROB(0.45)` + 정렬(`align_seq`, `word_sim`) + 유창성(말 속도·쉼). 최종 `0.6·정확도+0.25·또렷함+0.15·유창성` (`score_en`, `score_ja`, `fluency_score`, `_final_score`) | 순수 Python 로직 약 400줄 | GDScript로 이식. 일본어는 가나 변환(`ja_to_kata`, pyopenjtalk)이 걸림 → 근사 변환표(§3.3) | B |
| 4 | 발음 채점(음소) | `/score`의 `units[i].ph`, 팁 | wav2vec2-lv-60-espeak-cv-ft(torch, 1.2 GB) + espeak-ng(기대 음소) + CTC 정렬. **영어만**, 일본어는 코드는 있으나 꺼 둠(`add_phonemes`) | `features.py` 1,273줄 | 후속(D 등급) | D |
| 5 | 억양 | `POST /prosody` | librosa pyin 피치 + 원어민 윤곽(Kokoro 합성음에서 뽑음) DTW 비교, 일본어 악센트(OpenJTalk) | | 시스템 TTS는 음성 파일을 못 줘서 원어민 윤곽이 없음 → 후속(미리 계산한 윤곽) | D |
| 6 | 레슨(규칙) | `POST /lesson` (`source` 기본 `tatoeba`) | Tatoeba 한국어 번역이 있는 문장 풀(영어 7,956·일본어 1,848문장, `cache\lesson_pool_*.json`) + 3-gram 비트셋(17 MB) + WordNet + 단어 뜻 `gloss.json`. 10문제(고르기·빈칸·조립·듣기·말하기) (`lesson_rules.py` 1,407줄) | 풀 4.3 MB + 3-gram 17 MB | **미리 만든 레슨 은행**을 싣는다(D3). 런타임 이식은 후속 | A |
| 7 | 레슨(AI) | `POST /lesson` (`source:"ai"`) | LLM이 JSON 생성 후 검증(`run_lesson`, `verify_answers`) | LLM 필요 | AI 키 있을 때만 | C |
| 8 | 읽기 분석 | `POST /reading/analyze` | 영어 spaCy `en_core_web_sm`(품사·원형), 일본어 fugashi+unidic-lite, 단어 빈도 wordfreq(zipf) (`reading.py`) | 모델 수십 MB | 영어: 어형→원형 표 + 빈도표로 이식. 일본어: 형태소 분석기가 없음 → 제한(§3.5) | A(영)/D(일) |
| 9 | 읽기 뜻풀이 | `POST /reading/gloss` | **LLM 한 번에 30개**, 결과를 `cache\gloss.json`에 캐시, IPA는 espeak-ng (`reading.gloss`) | LLM 필요 | 미리 만든 대표 뜻 사전 + 미리 만든 IPA 표 + (키 있으면) 문맥 뜻은 AI | A/C |
| 10 | 예문 검색 | `GET /examples` | `data\tatoeba.sqlite`(영어 60.9만·일본어 18.0만 문장, 90 MB). 한국어 번역이 있는 것은 영어 8,672·일본어 2,132문장뿐 | 90 MB | 한국어 번역 있는 약 1.08만 문장만 싣는다(축소판) | A(축소) |
| 11 | 문법 교정 | `POST /fix` | LanguageTool 6.6(Java 자식 프로세스, 390 MB) → AI가 다듬기(`correct_learner`, `grammar.py`) | Java+390 MB | 폰에서 불가. AI 키로 대체(`_llm_correct`만) | C |
| 12 | AI 대화 | `POST /chat` | OpenCode `opencode serve` + 무료 DeepSeek V4.1 Flash(기본) / Ollama qwen3:8b / OpenAI 호환 API 키(`llm_opencode.py`, `llm_api.py`, `server.py ollama_json`). 일본어 읽기는 pyopenjtalk로 로컬 생성 | LLM 필요 | AI 키(OpenAI 호환 직접 호출) | C |
| 13 | 대화 피드백 | `POST /feedback` | LLM 1회 | | AI 키 | C |
| 14 | 미션 | `GET /missions`, `POST /missions/check`, `POST /missions/judge` | 8개 영어 미션(`content\missions.json` 76 KB). 판정은 정규식 규칙(`match.any/all`, 50 ms 이하), 놓친 목표만 AI(`judge`). **대본 모드는 이미 Godot 안에서 AI 없이 돈다**(`mission_screen.gd` 8행 주석) | 작음 | 규칙은 GDScript `RegEx`로 이식(데이터에 `pos`/`neg` 예문이 있어 자동 시험 가능). judge는 AI 키 | A/C |
| 15 | 연습 | `GET /practice/ping|sentences|phonemes|phoneme` | Tatoeba 문장 선택(`_pick`), 약한 소리 드릴(`content\phoneme_drills.json` 13 KB). AI 없음 | 작음 | 이식 | A |
| 16 | 커리큘럼 | `GET /curriculum` | `curriculum.json` | 111 KB | **이미 폰에 들어 있음**(`Store.CURRICULUM_BUNDLED = res://data/curriculum.json`) | A |
| 17 | 마이크 | `/mic/*` | PC 전용(PortAudio). 폰은 `Recorder`가 Godot 마이크로 직접 녹음(이미 구현) | | 해당 없음 | - |
| 18 | 복습·기록·로드맵 | (서버 없음) | FSRS(`fsrs.gd`), `Store`, `StudyLog` 모두 Godot 안 | | **이미 폰 단독** | A |

**읽고 알게 된 것(설계에 영향)**
- 화면이 쓰는 경로는 `api.gd`/`views`/`practice` 안 `Api.post_json/get_json` 호출 약 25곳이고, 폰 허용 목록(`lan.py ALLOW`)과 겹친다. 이 경로 집합이 곧 이식해야 할 **API 표면 전체**다(§4.3).
- 서버의 모든 한국어 문구·스키마는 `API.md`에 있다. 폰 처리도 같은 키 이름을 쓰면 화면은 모른 채 동작한다.
- PC의 `OK_PROB = 0.45`와 점수 가중치는 faster-whisper `small`의 단어 확률에 맞춰져 있다. 다른 모델(`base-q5_1`)의 확률 분포는 다르므로 **보정이 필요하다**(§3.3).
- `Api.cancel()`·`HTTPRequest.cancel_request()` 가 Godot 4.6.3에서 메인 스레드를 막는 문제가 코드 주석에 기록돼 있다(`api.gd`). 큰 파일 내려받기는 `HTTPRequest`로 하면 같은 문제에 걸리므로 `HTTPClient`+스레드로 한다(§5.6).

---

## 3. 기능별 조사와 추천

### 3.1 음성 인식

| 후보 | 온디바이스 | 단어별 신뢰도·시각 | 일본어 | 용량·속도(예상) | 빌드 영향 | 판정 |
|---|---|---|---|---|---|---|
| **A. whisper.cpp** (GDExtension, MIT) | 예(완전 오프라인) | 예: 토큰 확률·토큰 시각(`token_timestamps`, `-ml 1` 단어 시각은 README상 "실험적"). 단어 확률은 서브워드 토큰 확률을 묶어 계산 | 예(다국어 모델) | `tiny` 75 MiB/≈273 MB RAM, `base` 142 MiB/≈388 MB, `small` 466 MiB/≈852 MB(README). 양자화 `q5_1`: tiny 32 MB, base 60 MB, small 190 MB. 속도는 **(실측 필요)**: 5초 발화에서 `base-q5_1`이 중급 폰 CPU로 수 초 **(추측)**, `small`은 그보다 3~4배 느려 영어 쓰기엔 무거움 **(추측)** | NDK + CMake + godot-cpp 필요(§13 도구). Gradle 불필요(D8) | **추천** |
| B. Android `SpeechRecognizer` (+온디바이스 `createOnDeviceSpeechRecognizer`) | 기기·언어팩에 따라(Google 앱 모델 다운로드 필요). 지원 여부는 `checkRecognitionSupport`로 런타임 확인(API 33+ **(추측: 안드로이드 문서 기준 기억)**) | 단어별 확률 **없음**. `CONFIDENCE_SCORES`는 "결과 후보 목록과 같은 크기"(소스 주석). `RECOGNITION_PARTS`/`EXTRA_REQUEST_WORD_TIMING`·`WORD_CONFIDENCE`는 존재(`current.txt` 확인), 신뢰도는 **5단계 거친 값**, 시작 시각만(`RecognitionPart`: `rawText`, `timestampMillis`, `confidenceLevel`), 인식기가 채우는 경우에만 | 기기마다 다름 | 0 MB(내장) | **Godot가 이 API를 열어 주지 않아 v2 플러그인(AAR, Gradle 빌드) 필수**(공식 문서 확인). `build_android.ps1`·검증 스크립트 전체 변경 | 비추천(기본 경로). 후속에 "말해서 입력" 같은 가벼운 용도로만 고려 |
| C. Vosk (Kaldi, Apache-2.0) | 예 | 단어 시각·신뢰도는 라이브러리 기능이나 모델 표에는 언급 없음 | 소형 일본어 있음(`vosk-model-small-ja-0.22`, 48 MB, CER 9.5%/17.1%) | 영어 소형 `vosk-model-small-en-us-0.15` 40 MB, WER 9.85%(LibriSpeech clean) | AAR(JNI) 또는 C API로 또 GDExtension | 비추천(모국어 화자 중심 소형 모델, 학습자 발음에 약할 것 **(추측)**) |
| D. sherpa-onnx (Apache-2.0, ASR+TTS) | 예 | 모델에 따라 다름 | Whisper/SenseVoice/ReazonSpeech 등 **(미검증)** | 모델 100~300 MB급 **(추측)** | C API로 GDExtension을 직접 써야 함(Godot용 기성 플러그인은 검색에서 못 찾음) | 후보 보관. 일본어 정확도가 whisper-small에서도 부족할 때 대안 |
| E. godot-whisper (appsinacup, MIT) | whisper.cpp 래퍼 | whisper.cpp 기능 | | | 안드로이드 arm64 빌드 공개 여부 **확인 못 함**; 2024년 사용자 보고에 OpenCL 때문에 안드로이드에서 흑화면 | 그대로 쓰지 않는다. 직접 만든 얇은 래퍼(§5.7)가 안전 |

**추천: whisper.cpp 얇은 GDExtension(`whisper_bridge`).** 이유: ① 현재 녹음 경로(`Recorder` → `AudioStreamWAV`)가 그대로 PCM을 주므로 Java가 필요 없다. ② PC `transcribe`의 출력(`text`, `words[{w,p,start,end}]`)과 같은 모양을 만들 수 있어 `score_*` 이식이 쉽다. ③ 비-Gradle 빌드 유지.

**기본 모델 선택**: 영어 `ggml-base-q5_1`(60 MB), 일본어 `ggml-small-q5_1`(190 MB, 선택). `tiny`는 학습자 발음에 너무 약하다 **(추측)**. 정확한 선택은 작업 B0·B6의 측정(§8)으로 확정한다.
**불가능할 때의 대안**: 모델이 없거나 폰이 느려서 쓸 수 없으면 `/stt`·`/score`는 `none`이 되고, 말하기 문제는 "내 목소리 녹음 → 원어민 음성과 번갈아 듣기 → 스스로 평가"(A7)로 바뀐다.
**사용자에게 보일 문구**: "음성 인식 모델이 아직 없어요. 설정 > 음성 인식에서 내려받으면(약 60 MB) 폰에서 바로 채점할 수 있어요. 지금은 녹음해서 들어 보고 스스로 평가할 수 있어요."

### 3.2 TTS

Godot `DisplayServer.tts_*`는 안드로이드를 지원한다(문서의 `FEATURE_TEXT_TO_SPEECH` 목록에 Android). 4.5 소스(`GodotTTS.java`)로 확인한 동작:

| 항목 | 사실 | 설계 영향 |
|---|---|---|
| 호출 | `tts_speak(text, voice, volume=50, pitch=1.0, rate=1.0, utterance_id=0, interrupt=false)` | `rate`는 안드로이드 `setSpeechRate`에 그대로 전달 → 지금 `Tts.SLOW_SPEED = 0.75`·`normal_speed()`(0.6~1.3)를 그대로 사용 |
| 음성 선택 | `tts_get_voices()` → `{name, id, language}`(문서). 안드로이드에서 `voice` 값은 `Voice.getName()`과 일치해야 선택됨 | 언어 접두(`en`, `ja`)로 걸러 목록을 만든다. **성별 정보 없음** → `Tts.voice_label()`에서 성별을 빼야 함 |
| 파일 저장 | `synthesizeToFile` 없음 → **음성 데이터를 받을 수 없다** | 억양 비교(원어민 윤곽), 합성음 재생 속도 가공, 캐시 불가. PC 억양 기능은 폰 단독에서 꺼짐 |
| 큐 | `interrupt` 인자는 안드로이드에서 무시되고 큐에 쌓임 | 새 발화 전에 `tts_stop()` 먼저 호출 |
| 초기화 | 엔진 초기화가 비동기. 초기화 전 `speak`는 **조용히 버려진다**(`state != INIT_STATE_SUCCESS` → return) | 앱 시작 때 한 번 `tts_get_voices()`로 깨우고, 첫 발화 실패(`CANCEL` 이벤트 또는 무반응 1.5초)면 1회 재시도 |
| 진행 이벤트 | `START`/`END`/`CANCEL`/`BOUNDARY(문자 위치)` 콜백 (`tts_set_utterance_callback`) | `Tts.sequence_finished`, `chunk_started`를 이 콜백으로 구현. `BOUNDARY`로 읽는 단어 강조도 가능(후속) |
| 품질 | 기기·엔진마다 다름. 일본어는 시스템에 일본어 음성 데이터가 없으면 조용하거나 영어 발음으로 읽을 수 있음 **(추측)** | 일본어 음성이 없으면 안내 문구(아래) |
| 안드로이드 11+ | 기본 엔진은 보이나 다른 엔진 검색은 `<queries>`가 필요할 수 있음 **(추측, 실측 필요)** | 기본 엔진만 쓰고 엔진 선택은 시스템 설정으로 안내 |

**대안**: (1) sherpa-onnx의 Kokoro 영어 모델은 `model.onnx` 310 MB(문서)로 무겁고, 일본어는 지원 목록에 없다(문서: "English and Chinese 지원만 추가") → 제외. (2) PC에서 Kokoro로 미리 만든 **음성 팩**(Ogg Vorbis)을 선택 다운로드 → PC와 같은 목소리, 억양 윤곽 계산 가능. 레슨 은행·쉐도잉 문장 같은 **정해진 문장**에만 쓸 수 있고 AI 답변·읽기 본문에는 못 쓴다. 후속(작업 D1).
**추천**: v1은 시스템 TTS. 음성 팩은 후속.
**사용자에게 보일 문구**: "이 휴대폰에 일본어 음성이 없어요. 휴대폰 설정 > 일반 > 언어 > 텍스트 음성 변환에서 일본어 음성 데이터를 내려받아 주세요." / "폰 음성은 PC의 원어민 목소리와 달라요. 억양 비교는 PC에 연결했을 때만 돼요."

### 3.3 발음 채점·음소·억양

| 단계 | 폰에서 가능한가 | 방법 | 점수 호환 |
|---|---|---|---|
| 단어 단위 정확도·또렷함·유창성 | **가능**(B) | `server.py`의 `score_en`, `score_ja`, `align_seq`, `word_sim`, `mora_sim`, `fluency_score`, `en_tips`, `ja_tips`를 GDScript로 옮긴다. 입력은 `whisper_bridge`의 `words[{w,p,start,end}]` | **정렬·팁 로직은 같은 입력이면 같은 출력**이어야 한다(황금 파일로 검증, §8 B2). 그러나 `p` 분포가 모델마다 달라 `OK_PROB`·또렷함 값이 달라진다 → 보정 필요(B6) |
| 영어 `num2words`·축약형(`en_words`) | 가능 | `server.py en_words/_expand_contraction/_num_words`를 이식. 숫자→영어 단어는 0~9999 규칙으로 제한 **(PC는 `num2words` 전체 지원이라 일부 차이 가능)** | |
| 일본어 가나 변환 | **근사만 가능** | PC는 pyopenjtalk로 문맥을 보고 읽음. 폰은 빌드 도구가 만든 `ja_reading_map.json`(Tatoeba 일본어 어휘 3.08만 + 레슨 문장 단어 → 읽기)으로 **최장 일치 분할** + 가나는 그대로. 동음이의·특수 읽기는 틀릴 수 있음 | 결과에 `degraded:["ja_reading_approx"]` |
| 음소 단위(영어) | **후속, 무거움**(D) | wav2vec2 ONNX int8(약 300 MB **(추측)**) + ONNX Runtime(네이티브) + 기대 음소는 espeak-ng 대신 **미리 계산한 단어 IPA 표** + CTC 정렬 이식(`features.py` 약 600줄). 폰 5초 발화 추론 수 초~십수 초 **(실측 필요)**, RAM 1 GB 이상 **(추측)** | 후속 작업 D3. v1~v3에서는 화면에서 숨기고 "PC 연결 시"로 안내 |
| 억양 | **후속, 부분 가능**(D) | 시스템 TTS가 파일을 못 주므로 원어민 윤곽을 폰에서 만들 수 없다. **빌드 도구가 레슨 문장마다 Kokoro 합성음의 윤곽을 미리 계산**해 싣고(문장당 약 100점×1바이트, 1만 문장 약 1 MB), 학습자 피치는 폰에서 추출(YIN, C++) | 후속 D4. 임의 문장(대화·읽기)은 불가 |

**Whisper 신뢰도 보정 방법(작업 B6)**: ① PC 서버(별도 포트·`--stt-cpu`)에 같은 WAV 세트를 보내 PC 결과를 기록 ② 폰(또는 데스크톱 빌드의 같은 whisper.cpp 모델)이 낸 `p`로 `OK_PROB`을 바꿔 가며 PC와 단어별 `ok` 일치율을 최대화 ③ 영어/일본어 별 `OK_PROB_PHONE`을 데이터 파일(`res://data/pack/score_params.json`)에 둔다. 일치율 목표는 §8.
**추천**: v1 = 단어 단위만. 화면의 음소·억양 카드는 폰 단독에서 숨기고 한 줄 안내.
**사용자에게 보일 문구**: "폰 채점은 단어 단위로 간단히 봐요. 소리(음소) 교정과 억양 그래프는 PC에 연결했을 때만 볼 수 있어요." / 점수 옆 작은 글씨 "폰 간이 채점".

### 3.4 AI 대화·교정·피드백

| 후보 | 폰에서 되는가 | 정확도·비용·개인정보 | 판정 |
|---|---|---|---|
| **OpenCode 무료 DeepSeek (현재 PC 기본)** | **안 된다.** 이 앱은 PC에서 `opencode serve`(Node CLI)를 자식 프로세스로 띄우고 CLI 로그인(`opencode auth login`)을 쓴다. 폰에는 CLI도 로그인도 없다. `opencode serve`를 PC에서 열어 폰이 붙게 할 수는 있지만 그 서버는 파일 읽기·명령 실행 API를 가지므로(문서: "The API can read files, run shell commands, and set credentials") 폰에 노출하면 안 된다. 이미 있는 PC 백엔드의 `/chat`(허용 목록에 있음)이 같은 일을 안전하게 한다 | | 자동 모드에서 **PC 연결 시에만** |
| OpenCode Zen **API 키** 직접 호출 | **불확실.** 문서(`opencode.ai/docs/zen`, 2026-10-17 확인)는 무료 모델도 API 엔드포인트 표에 있고 `Authorization: Bearer $OPENCODE_API_KEY`로 호출할 수 있다고 적는다. 키는 콘솔 계정에서 만들고 "결제 정보와 크레딧 추가" 단계가 있다. 약관(`legal/terms-of-service`)에는 CLI 밖 사용을 금지하는 조항이 **없다**(내부 사용 한정, 다중 계정으로 한도 우회 금지, 대량 자동 추출 금지). 그러나 **이 저장소의 과거 실측**(`llm_opencode.py` 머리글, `llm_api.py` 프리셋 주석)은 "무료 모델은 OpenCode 프로그램 안에서만 거부됨"이다. 문서와 실측이 어긋난다 | 사용자 본인 키로 한 번 시험해 봐야 안다(내가 비밀값을 열 수 없어 시험 못 함) → **작업 C0** | 시험 결과가 O면 프리셋 `opencode_zen`의 무료 모델을 기본 안내, X면 유료 모델 키만 안내 |
| 사용자 API 키 직접 호출 (DeepSeek, Gemini, OpenRouter, OpenCode Zen 유료) | **된다.** `HTTPRequest`로 HTTPS POST `{base}/chat/completions`. PC `llm_api.py`가 이미 같은 프리셋(`opencode_zen`, `deepseek`, `gemini`, `openrouter`)과 오류 분류(`auth`/`limit`/`overload`)를 갖고 있어 그대로 옮긴다 | 품질은 PC와 같음(같은 모델). **비용은 사용자 부담**(요청당). **개인정보**: 대화·교정할 문장이 업체 서버로 나간다. 업체별 데이터 사용 정책이 다르다(예: 무료 등급은 개선에 쓰일 수 있음 **(추측, 업체별 확인 필요)**). 키 보관은 §5.9 | **추천(선택 기능)** |
| 온디바이스 Gemini Nano (ML Kit GenAI Prompt API) | 일부 기기만(Pixel 9, 갤럭시 Z폴드7 등 목록). 알파. Kotlin API → Gradle 플러그인 필요. 일본어·한국어 프롬프트 지원 확인 못 함 | | 제외 |
| 온디바이스 llama.cpp + 소형 모델(Qwen3-1.7B Q4 등) | 가능은 하다(모델 약 1~1.2 GB 내려받기, 8 Gen 3급에서 20~40 tok/s 예상 **(추측, 출처 간접)**, 중급 폰은 훨씬 느림). 그러나 한국어 설명·JSON 형식 준수·일본어 품질이 8B(PC `qwen3:8b`)보다 크게 낮다 **(추측)**, 배터리·발열, RAM 4 GB 이하 기기에서 실패 | | v1~v3 제외. 후속 실험 D5(대화 상대 역할만) |
| 규칙만 (AI 없음) | 된다 | | 기본값 |

**무 AI 모드에서 대화 기능 대체**
1. **미션 대본 모드**(이미 구현): 상대 대사는 데이터 `script` 줄, 내 답은 정규식 규칙+문장 유사도(`MissionLogic.script_passes`). 현재 영어 8개 미션.
2. 대화 탭이 "AI 필요" 화면 대신 **"대본 대화" 목록**을 보인다(미션 대본 모드 진입 + 후속 "대화 팩").
3. **대화 팩(후속, 선택 C5)**: PC에서 AI로 상황별 대화 대본(상대 대사, 학습자 모범 답 3개, 한국어 번역)을 미리 만들어 사람이 검수 후 싣는다. 미션 `script` 형식을 그대로 쓴다. 일본어 대본도 이 방식으로만 가능.
4. 교정(`fix`)·피드백(`feedback`)은 AI가 없으면 **숨긴다**(빈 결과를 보여 주지 않는다). 받아쓰기 비교(`dictation_diff.gd`)의 규칙 교정은 그대로.

**사용자에게 보일 문구**: "AI 대화는 AI 연결이 필요해요. 지금은 PC에 연결하거나 설정 > AI 연결에 본인 API 키를 넣으면 쓸 수 있어요. 키 없이도 '대본 대화'로 연습할 수 있어요." / 키 입력 화면: "키는 이 휴대폰 안에만 저장돼요. 대화한 문장은 선택한 업체(예: DeepSeek) 서버로 직접 전송되고, 사용 요금은 업체가 키 주인에게 청구해요."

### 3.5 레슨·사전·읽기·미션 규칙·커리큘럼·연습

**(1) 레슨 — 미리 만든 레슨 은행(추천) vs GDScript 이식**

| 방식 | 장점 | 단점 |
|---|---|---|
| **A. 레슨 은행**: 빌드 도구가 `lesson_rules.make_lesson(lang, month, week, stage, seed)`를 월·주별로 N번 돌려 결과를 JSON으로 저장. 폰은 골라서 보여 줌 | 이식 코드 거의 없음, 정답이 PC 검증을 통과한 것만 들어감(정답이 틀릴 일 없다는 현재 보장 유지), 3-gram 17 MB·WordNet 불필요, 일본어 읽기·`ko` 이미 포함 | 같은 문장이 반복될 수 있음(월·주당 N개 소진 뒤 순환), 사용자 단어 상태에 맞춘 선택 불가 |
| B. 런타임 이식: `Maker`·풀·3-gram 비트셋·WordNet | 매번 새 레슨 | 1,400줄 이식 + 17 MB 비트셋 + WordNet 데이터(11 MB) + 시험 비용 큼 |

**추천 A.** 월 12 × 주 4 × 언어 2 = 96칸 × 20개 = 1,920레슨, 레슨당 약 3.5 KB **(추측)** → 약 7 MB(압축 전). 반복이 거슬리면 후속에서 B를 검토.
데이터: 문제 JSON은 `API.md`의 `/lesson` 응답과 같은 키(`exercises[]`, `tatoeba_id`, `attribution`)를 쓴다.
**한계**: 요청의 `stage` 인자는 무시하고(월에서 정해짐), `source:"ai"`는 AI 키가 있을 때만.

**(2) 연습(쉐도잉·받아쓰기·약한 소리)** `practice.py`(358줄, 순수 규칙)를 GDScript로 이식. 입력 데이터는 레슨 풀 JSON(문장·한국어·단어 수·단계)과 `phoneme_drills.json`(13 KB). `GET /practice/sentences`의 `seed`·`exclude`·`n` 규칙은 같게. 받아쓰기 비교는 이미 Godot(`dictation_diff.gd`).

**(3) 미션** `missions.json`(76 KB)을 `res://data/pack/`에 복사. `normalize()`(NFKC 소문자화), `goal_matches()`(`match.any` 중 하나 + `match.all` 전부)를 이식. **주의**: GDScript에는 유니코드 NFKC가 없다 → 전각 영숫자·곡선 따옴표·공백 등 자주 나오는 경우만 직접 치환(§10 R6). 판정(`judge`)은 AI 키 때만.

**(4) 읽기** 
- 영어: 토큰화(정규식) + `en_forms`(어형→원형, 빌드 도구가 spaCy 규칙과 Tatoeba `en_forms` 18,858쌍·어휘 6.4만으로 생성) + 단어 빈도표(zipf, wordfreq 상위 약 12만 단어, 1.5 MB **(추측)**). 모르는 단어는 접미사(s/es/ed/ing/er/est/ly) 제거 후 표에서 찾는다. spaCy 품사 기반 원형화보다 부정확 **(품질 차이)**.
- 일본어: **형태소 분석기가 폰에 없다.** 선택지 ① 읽기 모드 일본어는 "PC 연결 시" ② 최장 일치 분할(어휘 3.08만, 활용형 약함) ③ 후속 D2에서 lindera 같은 Rust 분석기를 GDExtension으로(사전 포함 +15~50 MB **(추측)**). 추천 ①+(레슨 은행·예문 문장은 이미 토큰화된 상태로 싣기) — 일본어 직접 붙여 넣기는 PC 연결 안내.
- 뜻풀이(`gloss`): PC는 LLM이 문맥 뜻. 폰은 **미리 만든 대표 뜻 사전**(`gloss_en.json`, `gloss_ja.json`): 빌드 도구가 기존 PC 엔진(`/reading/gloss`)으로 상위 빈도 원형 약 1.5만(영어)+0.8만(일본어)을 생성하고 형식 검사(`ko_ok`)와 무작위 100개 사람 검수. 사전에 정의된 무료 한영 사전 데이터는 라이선스가 확인된 것을 찾지 못했다(JMdict에도 한국어 뜻이 없다고 EDRDG 메일링 기록; krdict는 API 약관 확인 필요). 그래서 **AI로 미리 만든 데이터**를 쓰고 출처 표기를 "AI가 만든 대표 뜻"으로 한다. 문맥 뜻은 AI 키 또는 PC.
- IPA: 영어 단어 IPA는 `espeak_ipa`(espeak-ng, **GPL-3.0**) 결과를 빌드 도구가 어휘 6.4만에 대해 미리 만들어 싣는다. 폰 앱에는 espeak-ng 코드를 넣지 않는다(앱 라이선스는 MIT, `LICENSE`).

**(5) 예문 검색(`/examples`)**: 한국어 번역이 있는 약 1.08만 문장과 단어→문장 색인을 JSON 샤드로(원본은 SQLite; Godot 기본에는 SQLite가 없다 → 샤드 파일 방식). PC의 79만 문장 검색은 PC 연결 시.

**(6) 커리큘럼**: 이미 폰 번들. 변경 없음.

### 3.6 문법 교정

| 방법 | 개인정보 | 속도·제한 | 약관 | 품질 | 판정 |
|---|---|---|---|---|---|
| LanguageTool **공개 API** (`api.languagetool.org/v2/check`) | 문장이 외부(Learneo)로 전송됨. 방침은 API 텍스트 보관 여부를 **명시하지 않음**(방침 문서 확인) | 무료: IP당 분당 20요청, 분당 75 KB, 요청당 20 KB, 첫 30개 오타까지만 제안 | "자동화 트래픽용이 아님, 대량은 자체 서버나 엔터프라이즈", 앱 안에 languagetool.org 링크 표시 의무. 일본어 지원 여부는 문서에 없음 | PC와 같은 규칙(일부 규칙 차이 가능) | **v1 제외**(Q5). 넣는다면 기본 꺼짐·사용자가 직접 누를 때만·고지·분당 6회 이하 |
| AI(사용자 키) | 문장이 업체로 전송 | 요청 1회 | 업체별 | 높음 | **추천**(C 등급) |
| 규칙만(앱 안) | 외부 전송 없음 | 즉시 | 없음 | 낮음: 대문자 시작, `a/an`, 문장 끝 부호, 반복 단어, `I is` 같은 소수 규칙 **(추측: 20~30개)** | v1은 넣지 않는다(오탐이 신뢰를 깎음). 받아쓰기 diff는 이미 있음 |
| PC LanguageTool(연결 시) | PC 안에서만 처리 | | | 현재 그대로 | 자동 모드에서 PC 연결 시 |

**추천**: 폰 단독 문법 교정 = AI 키가 있을 때 AI(`_llm_correct`의 `lt_fix=""` 경로). 없으면 교정 카드를 숨긴다.
**문구**: "문법 교정은 AI 연결이나 PC 연결이 있을 때 나와요."

---

## 4. 아키텍처

### 4.1 구조도

```
화면(views/practice/ui)  ──  Api.post_json("/lesson", body)  (호출 코드는 그대로)
          │
          ▼
      Api._start()  ── [새 훅] Route.decide(method, path) ──┬─ "pc"    → 기존 HTTPRequest 경로(변경 없음)
                                                           ├─ "phone" → LocalApi.dispatch(method, path, query, body)
                                                           │             └ 핸들러 스크립트(scripts/local/*.gd)  → 같은 결과 Dictionary
                                                           └─ "none"  → 즉시 실패(err_code, 한국어 이유)
Tts 자동로드 ── engine 선택(pc: /tts WAV, system: DisplayServer.tts_*)   ← Api를 거치지 않는다
Recorder     ── 폰에서는 이미 Godot 녹음. 변경 없음(필요 시 16 kHz 변환 헬퍼만 추가)
WhisperBridge(GDExtension, 2단계) ← LocalStt 핸들러가 호출(스레드)
ModelStore(모델 다운로드·검증·삭제)   AiClient(3단계, HTTPS)   PackLoader(팩 검증·지연 로딩)
```

### 4.2 `Route` 정책

입력: 메서드, 경로(쿼리 제외), 현재 `route_mode`, PC 상태(`Backend.status`, 마지막 `/health` 시각), 로컬 가용성(`LocalApi.available(path)`: 팩 로드 성공? 모델 있음? AI 키 있음?).

```
decide(method, path):
  entry = POLICY[(method, path)]           # §4.3 표. 없으면 "pc"(기존 동작과 같음)
  pc_ok     = entry.pc and Backend.is_ready() and not pc_flaky()
  phone_ok  = entry.phone != "" and LocalApi.available(path)
  mode == "pc"    → "pc" if entry.pc else "none"                      # 기존 동작 100% 유지
  mode == "phone" → "phone" if phone_ok else "none"                   # PC에 요청을 보내지 않음(배터리·개인정보)
  mode == "auto"  → entry.prefer == "pc":    pc_ok ? "pc" : (phone_ok ? "phone" : "none")
                    entry.prefer == "phone": phone_ok ? "phone" : (pc_ok ? "pc" : "none")
```

- `none`의 이유: `Route.why_none(path)` → `{err_code, text_ko}` (예: `model_missing`, `no_ai`, `needs_pc`).
- **PC가 요청 도중 끊기면(자동 모드)**: `Api._on_completed`에서 `err_code == "transport"` 또는 `not_connected`이고 `phone_ok`이면 같은 요청을 폰 핸들러로 한 번 넘긴다(요청이 PC에서 부작용이 없는 것은 `/tts`, `/stt`, `/score`, `/prosody`, `/reading/*`, 모든 GET, `/lesson`, `/missions*`, `/practice/*` — `IDEMPOTENT_POST` 개념 확장; `/chat`·`/fix`·`/feedback`은 폰 AI가 있을 때만 폴백). 한 번 폴백하면 `pc_flaky()`가 60초 true라 그 사이 요청은 PC에 시도하지 않고 바로 폰으로(90초 타임아웃을 매번 기다리지 않게). 60초 뒤 첫 요청이 PC를 다시 시험한다. 토스트: "PC에 닿지 않아 폰에서 처리했어요"(5분에 한 번).
- **PC 우선이 아닌 것(`prefer:"phone"`)**: 폰이 더 낫거나 같은 기능 — `GET /practice/*`, `GET /missions`, `/missions/check`(50 ms 규칙이라 왕복이 더 느림), `/reading/analyze`(영어). 그 외는 `prefer:"pc"`. (A1 결정, 2026-10-24: `GET /curriculum`은 `prefer:"pc"`로 바꿈. PC가 연결돼 있으면 PC 최신 커리큘럼을 받아 캐시하고, 연결이 없을 때만 폰 번들을 씀. 폰 답(`via`/`degraded` 키가 있는 응답)은 `Store.refresh_curriculum`이 캐시에 쓰지 않음.)
- **TTS**는 `Api`를 안 거치므로 별도 설정 `tts_engine`(`auto|system|pc`). 자동 = PC 연결 시 PC(Kokoro), 아니면 시스템. 연결 중이라도 지연이 싫은 사용자는 `system`을 고를 수 있다.

### 4.3 경로별 공급자 표 (정책 `POLICY`)

| 경로 | PC | 폰 처리(핸들러) | prefer | 폰 처리가 `none`이 되는 조건·이유 코드 |
|---|---|---|---|---|
| `GET /health` | 예 | `LocalApi`가 합성(§5.3) | pc | 항상 가능 |
| `GET /curriculum` | 예 | `LocalCurriculum`(= `Store`의 번들) | pc | 항상 |
| `POST /tts`, `GET /tts/voices` | 예 | **Api 미경유**, `Tts` 내부 | (tts_engine) | 시스템 음성 없음 → `no_voice` |
| `POST /stt` | 예 | `LocalStt`(whisper_bridge) | pc | 모델 없음 `model_missing`, 라이브러리 없음 `engine_missing` |
| `POST /score` | 예 | `LocalScore` | pc | 위와 같음 |
| `POST /prosody` | 예 | (1~3단계 없음) | pc | `not_on_phone` |
| `POST /lesson` (`source` 기본) | 예 | `LocalLessons`(은행) | phone | 팩 없음 `pack_missing` |
| `POST /lesson` (`source:"ai"`) | 예 | `LocalAi` | pc | `no_ai` |
| `POST /reading/analyze` | 예 | `LocalReading`(영어) | phone | 일본어 → `ja_reading_pc` |
| `POST /reading/gloss` | 예 | `LocalGloss`(사전 → 없으면 AI) | pc | 사전에 없고 AI 없음 → 부분 결과 + `degraded:["gloss_partial"]` |
| `GET /examples` | 예 | `LocalExamples`(축소판) | pc | 팩 없음 |
| `GET /practice/ping|sentences|phonemes|phoneme` | 예 | `LocalPractice` | phone | 팩 없음 |
| `GET /missions`, `POST /missions/check` | 예 | `LocalMissions` | phone | 팩 없음 |
| `POST /missions/judge` | 예 | `LocalAi` | pc | `no_ai` |
| `POST /chat` | 예 | `LocalAi` | pc | `no_ai` |
| `POST /fix` | 예 | `LocalAi` | pc | `no_ai` |
| `POST /feedback` | 예 | `LocalAi` | pc | `no_ai` |
| `/mic/*` | 예(PC 앱만) | 사용 안 함(폰 `Recorder`가 직접) | - | - |
| `GET/POST /llm*` | 예(로컬 전용) | 폰 `AI 연결` 설정 카드가 대신 | - | - |
| `/lan/*`, `/sync/*`(1.2) | 예 | 해당 없음(PC와 맺는 것) | - | PC 연결 전용 |

### 4.4 `ApiCall`과의 약속

- 폰 처리 결과는 `Api`의 결과 Dictionary와 **같은 키**를 가진다: `{ok, code, data, bytes, error, cancelled, err_code, err_body}` + `data.via = "phone"`.
- `ApiCall.cancel()`은 로컬 처리도 같게 동작한다: `_complete(cancelled)`로 끝내고 늦게 도착한 핸들러 결과는 버린다(스레드는 자기가 끝날 때까지 두되 결과를 쓰지 않는다). `active_count`·`sent_count` 계산: **로컬 처리는 `sent_count`를 올리지 않는다**(시험의 "네트워크 0건" 판정 근거).
- 오래 걸리는 로컬 일(전사)은 `WorkerThreadPool` 또는 `Thread`에서 하고, 완료는 `call_deferred`로 메인 스레드에서 `_complete`한다.

### 4.5 1.2 동기화와의 관계

- 동기화는 **학습 기록**(진행·복습 카드·공부 로그·음소 통계·화이트리스트 prefs 6개)만 다루고 기능 공급자와 무관하다. 폰 단독으로 쌓은 기록은 나중에 연결될 때 그대로 합쳐진다. 새 prefs(`route_mode`, `tts_engine`, 모델·AI 설정, `lesson_cursor`)는 **화이트리스트에 넣지 않는다**(기기별·비밀 포함 가능). 합격 조건으로 확인(§8 A8).
- 폰 단독 점수는 같은 학습 로그 필드에 들어간다(스키마 변경 없음). `via`는 저장하지 않는다 → PC 점수와 폰 간이 점수가 한 평균에 섞인다. 영향은 R5.
- 동기화 허브는 PC 쪽이므로 PC 없이 기기 간 동기화는 없다. 폰 교체·앱 삭제로 기록이 사라질 수 있다(`user_data_backup/allow=false`, `export_presets.cfg` 확인) → 후속 "기록 내보내기/가져오기" (R12). 이 위험은 화면 문구로 알린다(§12 #10).
- **선행 조건**: 1.2 동기화 작업(S3)과 이번 A1이 모두 `godot\scripts\autoload\api.gd`를 고친다(`IDEMPOTENT_POST` 한 줄 vs 훅). 두 작업을 같은 시기에 하면 병합 순서를 오케스트레이터가 정한다(§13 질문 외 소결정 S1).

### 4.6 화면과 모드

- 폰 `ConnectView`(PC 연결 화면)에 버튼 **"PC 없이 시작"**을 추가한다. 누르면 `Store.prefs.standalone_ok = true`, `route_mode = "auto"`로 두고 홈으로 간다. 이후 앱을 켜면 `Backend`가 PC를 찾아 보고(`NEEDS_PAIRING`이어도) 홈은 막지 않는다.
- 상단 배너(`main.gd`)는 PC 상태 대신 **"폰 단독 모드"** 작은 배지를 보인다. 연결되면 "PC 연결됨"으로 바뀐다.
- 설정 카드 **"처리 위치"**: 라디오 3개(자동 / 이 폰에서만 / PC에서만) + TTS 음성 위치. 아래 **"기능 현황"** 표(`CapabilityPanel`): 기능 이름 / 지금 쓰는 곳(폰·PC·없음) / 없을 때 이유와 해결 한 줄.
- 폰에서 못 하는 기능의 버튼은 **숨기지 않고 비활성 + 이유 한 줄**(예: 억양 카드: "억양 비교는 PC 연결 시"). 숨기면 "원래 없는 기능"으로 오해한다. 단 §3.4의 빈 교정 카드는 숨긴다.

---

## 5. 계약 (이름·형식 고정)

### 5.1 `LocalApi` 핸들러 (GDScript)

```gdscript
# godot/scripts/autoload/local_api.gd  (A1 소유)
func dispatch(method: String, path: String, query: Dictionary, body: Dictionary) -> Dictionary  # 코루틴 가능, 결과는 §4.4 모양
func available(path: String) -> bool          # 핸들러가 지금 일할 수 있나(팩·모델·키)
func why_none(path: String) -> Dictionary     # {err_code: String, text_ko: String}
static func ok(data: Variant, degraded: Array = []) -> Dictionary    # data.via="phone" 와 data.degraded 를 채움(data 가 Dictionary 일 때)
static func fail(code: int, text_ko: String, err_code: String) -> Dictionary
```

핸들러 스크립트(각 작업자 소유)는 이 정적 함수를 가진다. `LocalApi`는 문자열 경로로 `load()`해서 지연 로딩한다(없으면 `available=false`) → A1이 다른 작업자의 파일 없이도 완성·시험된다.

```gdscript
# 각 핸들러: godot/scripts/local/local_<이름>.gd, class_name Local<이름>
static func handle(method: String, path: String, query: Dictionary, body: Dictionary) -> Dictionary
static func is_available() -> bool
static func unavailable_reason() -> Dictionary   # {err_code, text_ko}
```

핸들러와 경로: `LocalLessons`(`POST /lesson`), `LocalPractice`(`/practice/*`), `LocalMissions`(`/missions*` 중 `GET /missions`, `POST /missions/check`), `LocalReading`(`/reading/analyze`, `/reading/gloss`, `GET /examples`), `LocalStt`(`/stt`, `/score`), `LocalAi`(`/chat`, `/fix`, `/feedback`, `/missions/judge`, `/lesson` 중 `source:"ai"`).

### 5.2 응답 확장 필드와 오류 코드

- 성공 응답의 최상위 객체에 (Dictionary일 때): `"via": "phone"`, `"degraded": []` (문자열 배열). `degraded` 값: `phoneme_off`, `prosody_off`, `ja_reading_approx`, `gloss_partial`, `examples_subset`, `bank_repeat`, `ai_off`.
- 실패 `err_code` (모두 `error`는 한국어): `not_on_phone`(폰에서 못 하는 기능), `needs_pc`, `pack_missing`, `pack_corrupt`, `model_missing`, `model_corrupt`, `engine_missing`(whisper 라이브러리 없음), `no_ai`, `ai_auth`(키 거부 401/403), `ai_limit`(429), `ai_overload`(5xx/타임아웃), `no_voice`, `no_permission`(마이크). HTTP `code`는 폰 처리에서는 `0`이 아니라 위 의미에 맞는 400/401/403/429/502/503을 쓴다(화면이 `code`를 보는 곳은 `Api` 401 처리뿐이며, **폰 처리의 401은 `auth_failed` 신호를 내지 않는다** — 그 신호는 PC 토큰 전용).

### 5.3 `Route.caps()` (설정 화면·시험이 읽음)

```json
{
  "mode": "auto",
  "pc": {"connected": true, "flaky": false},
  "items": {
    "lesson":  {"use": "phone", "phone": true,  "pc": true,  "why": ""},
    "stt":     {"use": "none",  "phone": false, "pc": false, "why": "model_missing"},
    "score":   {"use": "pc",    "phone": false, "pc": true,  "why": ""},
    "tts":     {"use": "phone", "phone": true,  "pc": true,  "why": ""},
    "prosody": {"use": "none",  "phone": false, "pc": false, "why": "not_on_phone"},
    "chat":    {"use": "none",  "phone": false, "pc": false, "why": "no_ai"}
  }
}
```
키 집합 고정: `lesson, lesson_ai, practice, missions, missions_judge, reading, gloss, examples, stt, score, phoneme, prosody, tts, chat, fix, feedback`. `use` ∈ `phone|pc|none`. 폰 단독의 합성 `/health`는 `{"ok": true, "via": "phone", "stt": bool, "score": bool, "tts": {"en": bool, "ja": bool}, "llm": bool, "llm_provider": "openai_api"|"none", "phoneme": false, "tatoeba": bool, "grammar": false, "llm_fallback": {"active": false, "until": null, "reason": ""}}` — `Backend.health`를 읽는 기존 코드(`phoneme_screen.gd` 321행: `health["phoneme"]`가 false면 안내)가 그대로 동작하도록 PC `/health`와 같은 키를 쓴다.

### 5.4 새 prefs 키 (`user://prefs.json`, 동기화 화이트리스트 밖)

| 키 | 값 | 기본 |
|---|---|---|
| `standalone_ok` | bool | false |
| `route_mode` | `"auto"`/`"phone"`/`"pc"` (그 밖의 값은 `auto`로 취급) | `"auto"` |
| `tts_engine` | `"auto"`/`"system"`/`"pc"` | `"auto"` |
| `tts_sys_voice_en`, `tts_sys_voice_ja` | 시스템 음성 `id` 문자열 | `""` (언어 일치 첫 음성) |
| `stt_model_en`, `stt_model_ja` | 모델 `id`(§5.6) | `"whisper-base-q5_1"` / `"whisper-small-q5_1"` |
| `ai_local` | `"none"`/`"openai_api"` | `"none"` |
| `ai_preset`, `ai_model` | 프리셋 id, 모델 이름 | `"deepseek"`, `""`(프리셋 기본) |
| `lesson_cursor` | `{"en-3-2": 7, ...}` | `{}` |

### 5.5 데이터 팩 (`godot/data/pack/`, 빌드 도구가 생성, 저장소에는 생성 결과 커밋)

| 파일 | 내용 | 스키마 |
|---|---|---|
| `manifest.json` | `{"v":1,"built":"ISO","files":[{"path","bytes","sha256","records"}],"sources":[{"id","license","url"}]}` | 모든 팩 파일의 SHA-256·크기. 앱 시작 때 검증하지 않고 **처음 읽을 때** 검증(시작 속도) |
| `lesson_bank_en.json`, `lesson_bank_ja.json` | `{"v":1,"lang","attribution","lessons":{"<month>-<week>":[<lesson>...]}}` | `<lesson>` = `/lesson` 응답과 같은 객체 + `"bank_id":"en-3-2-07"` |
| `practice_en.json`, `practice_ja.json` | `{"v":1,"sentences":[{"id","text","ko","reading","words","stage","lemmas":[...]}]}` | `practice._pick` 입력 |
| `missions.json`, `phoneme_drills.json` | `backend\content\`의 사본 | 변경 없음(바이트 동일, 해시 비교) |
| `examples_en.json`, `examples_ja.json` | `{"v":1,"sent":{"<id>":{"t","ko"}},"idx":{"<lemma or 형태>":[ids...]}}`, 샤드 `examples_en_<a-z>.json` | 한국어 번역 있는 문장만 |
| `reading_en.json` | `{"forms":{"형태":"원형"},"zipf":{"원형":<정수 zipf×10>}}` | |
| `gloss_en.json`, `gloss_ja.json` | `{"<lemma>":{"pos":"명사","ko":"대표 뜻 1~3개","ipa":""}}` | |
| `ipa_en.json` | `{"<소문자 단어>":"IPA"}` 어휘 약 6.4만 | espeak-ng 출력 사전 계산 |
| `ja_reading_map.json` | `{"<표기>":"<히라가나>"}` 최장 일치용 | |
| `score_params.json` | `{"en":{"ok_prob":0.45,...},"ja":{...},"model_ids":[...]}` | B6가 채움 |

### 5.6 모델 매니페스트 `res://data/pack/models.json` (APK 안에 고정 → 변조 방지)

```json
{"v":1,"models":[
  {"id":"whisper-base-q5_1","kind":"stt","langs":["en","ja"],"file":"ggml-base-q5_1.bin",
   "bytes":59700000,"sha256":"<빌드 도구가 채움>","min_free_mb":200,
   "urls":["https://github.com/Whahan/hoehwa-practice/releases/download/models-1/ggml-base-q5_1.bin"],
   "license":"MIT (OpenAI Whisper weights, whisper.cpp)"}
]}
```
- 저장: `user://models/<file>` (앱 비공개). 받는 중에는 `<file>.part`.
- 내려받기 방식: **`HTTPClient`를 스레드에서 폴링**(취소 플래그, Range 이어받기, 청크마다 파일 쓰기). `HTTPRequest`는 쓰지 않는다(4.6.3 취소 문제, `api.gd` 주석). 시작 전 `DirAccess.get_space_left()`(**(추측: 안드로이드에서 값이 올바른지 실측)**)가 `min_free_mb` 이상이어야 한다. 완료 후 `FileAccess.get_sha256()`이 매니페스트와 같아야 `.part` → 정식 이름으로 `rename`. 다르면 삭제하고 `model_corrupt`.
- 기본은 **Wi-Fi일 때만** 받기(`OS.get_connection_type`류 판별이 어려우면 첫 시작 확인 대화상자 "모바일 데이터로 약 60 MB를 받아요. 계속할까요?" — 안드로이드의 연결 종류 API 유무 **(추측)**, B3에서 확인).

### 5.7 `WhisperBridge` (GDExtension, C++ 얇은 래퍼)

```
class WhisperBridge : RefCounted
  static version() -> String
  load_model(path: String, threads: int = 0) -> int           # OK(0) 또는 Godot Error 코드. 0 은 자동(코어 수-1, 2~4)
  is_loaded() -> bool
  unload() -> void
  transcribe(pcm: PackedFloat32Array, lang: String, options: Dictionary = {}) -> Dictionary   # 블로킹. 스레드에서 호출
        # pcm: 16 kHz 모노 -1..1. lang: "en"|"ja". options: {beam: 1..5(기본 1), audio_ctx: int(0=기본), max_seconds: 30}
  abort() -> void                                              # 진행 중 전사를 가능한 빨리 중단(다음 콜백 시점)
  결과: {ok: bool, error: String, text: String, duration: float, ms: int, model: String,
         words: [{w: String, p: float(0..1), start: float(초), end: float(초)}]}
```
- 단어 만들기: 서브워드 토큰을 공백으로 시작하는 토큰 경계에서 묶고, `p` = 묶은 토큰 확률의 **평균** (faster-whisper의 단어 확률도 평균으로 기억함 **(추측: 구현 때 faster_whisper 소스로 확인)**). 시각은 whisper.cpp 토큰 시각(`token_timestamps`).
- 영어는 `language="en"` 고정, 일본어는 `"ja"`. 음성 구간 검출(VAD)은 래퍼에서 단순 에너지 기반으로 앞뒤 무음 제거(PC는 `vad_filter=True`) **(PC와 완전히 같지는 않음)**.
- 빌드 산출물: `godot/bin/android/libwhisper_bridge.android.template_release.arm64.so` 등, `whisper_bridge.gdextension`의 `[libraries]`에 `android.release.arm64`, 데스크톱 시험용 `windows.release.x86_64`. 의존 라이브러리는 정적 링크(`libc++_shared.so` 의존 시 같이 포함).
- Godot 쪽 래퍼 `LocalStt`가 이 객체를 `ClassDB.can_instantiate("WhisperBridge")`로 확인하고 없으면 `engine_missing`.

### 5.8 `AiClient` (GDScript, 3단계)

```gdscript
# godot/scripts/local/ai_client.gd
static func presets() -> Dictionary          # llm_api.py PRESETS 와 같은 id/label/base_url/model
func complete_json(messages: Array, schema: Dictionary, temperature: float, max_tokens: int, timeout: float) -> Dictionary
     # → {ok, data: Dictionary(파싱된 JSON), error, err_code: ai_auth|ai_limit|ai_overload|bad_format|"", kind: "auth"|"limit"|"overload"|""}
```
- `POST {base_url}/chat/completions`, 헤더 `Authorization: Bearer <키>`. `response_format` 거부 시 일반 모드로 재시도(PC `_no_json_mode`와 같은 동작). 응답이 JSON 형식이 아니면 1회 재시도(`bad_format`).
- 프롬프트·스키마·검증(`rules_text`, `CHAT_SCHEMA`, `FIX_SCHEMA`, `FEEDBACK_SCHEMA`, `ko_ok`, `scrub_ko`, `clean_hist`, `looks_like_question`, `_llm_correct`)은 `server.py`의 해당 함수를 **문장 단위로 옮긴다**. 일본어 `reading`(후리가나)은 PC는 pyopenjtalk로 만들었다 → 폰은 `ja_reading_map` 근사 변환으로(`degraded:["ja_reading_approx"]`).

### 5.9 비밀(API 키) 보관

- 위치: `user://secrets.cfg`(`ConfigFile`, 섹션 `ai_key`, 키 = 프리셋 id). 이 파일은 앱 비공개 저장소에 있고 `user_data_backup/allow=false`(`export_presets.cfg` 108행)라 안드로이드 자동 백업에 안 들어간다.
- **암호화는 하지 않는다**(안드로이드 Keystore는 플러그인(Gradle) 없이는 못 씀; 앱이 읽을 수 있는 키로 암호화하는 것은 눈속임). 루팅·USB 디버깅 접근에는 취약함을 설정 화면에 한 줄로 적는다.
- 화면 입력은 가려진 칸(보기 버튼), 저장 후에는 마지막 4자만 표시. 로그·토스트·`print`에 키를 쓰지 않는다. 동기화 화이트리스트(§4.5)·`SHARED_PREFS`와 겹치지 않는다. 시험 로그에서 키 문자열 검색 0건.

---

## 6. 데이터·용량·라이선스

| 데이터 | 원본 | 출처·라이선스 | 폰 크기(예상) | 표기 |
|---|---|---|---|---|
| 레슨 은행·연습 문장·예문 | Tatoeba(`tatoeba.sqlite`, `lesson_pool_*.json`) | CC BY 2.0 FR(일부 CC0). 문장 작성자 표기는 Tatoeba 방침상 사이트 표기로 충분하다고 PC가 이미 `ATTRIBUTION` 사용 | 레슨 은행 약 7 MB, 연습 약 1.5 MB, 예문 약 2 MB **(추측)** | 앱 "정보" 화면 + 레슨 결과에 `attribution`(이미 있음) |
| 단어 빈도 | wordfreq(영어) | 데이터 CC BY-SA 4.0으로 기억 **(추측, 확인 필요)** → 확인 후 표기·공유 조건 검토 | 약 1.5 MB | 정보 화면 |
| 어형→원형 | spaCy 규칙 + Tatoeba `en_forms` | MIT/CC BY | 약 0.5 MB | |
| IPA 표 | espeak-ng 출력 | espeak-ng는 GPL-3.0. 출력 데이터(단어→IPA)는 사전 계산 결과일 뿐이고 코드는 앱에 안 들어감. 법적 해석은 **(추측, 법률 자문 아님)** → 보수적으로 IPA 표 출처를 정보 화면에 적는다 | 약 1.5 MB | |
| 단어 뜻 사전 | 기존 PC AI(`/reading/gloss`)로 생성 | 제3자 사전 데이터 아님. 품질 검수(100개 표본) | 약 1 MB | "AI가 만든 대표 뜻" |
| 일본어 읽기 표 | pyopenjtalk-plus 출력 | | 약 1.2 MB | |
| whisper 모델 | OpenAI Whisper 가중치(MIT) via ggml 변환 | MIT | 다운로드 | 정보 화면 |
| whisper.cpp 코드 | MIT | | `.so` | 정보 화면 |

**릴리스 점검(공개 전 목록 확인)**: 모델 파일은 저장소에 커밋하지 않고 **GitHub 릴리스 자산**으로만 올린다(`models-1` 태그, 별도). 팩 JSON은 저장소에 들어가므로 비밀값·개인 학습 기록·로그가 섞이지 않았는지(`git`에 올라가는 목록 직접 확인) 확인한다. `packaging\check_zip.py`의 금지 패턴(`progress.json`, `studylog.json`, `backend/(data|...)/`)에 걸리지 않는 경로(`godot\data\pack\`)에 둔다.

---

## 7. 작업 분할

공통 규칙: 각 작업자는 **"수정 허용" 파일만** 고친다. 임시 파일은 `scratchpad\w_<ID>\`. 프로세스는 자기가 시작한 PID만 종료. 시험 서버는 포트 `18791~18799` 중 비어 있는 것을 확인 후 사용, 보고에 "남은 프로세스·열린 포트 없음". 보고 맨 앞에 합격 조건 표(항목 / O·X / 근거), 실행하지 않은 항목은 "미검증". 비밀값 출력 금지. 새 `class_name`을 만들면 `& $GODOT --headless --path <repo>\godot --import`로 캐시 갱신. 시험은 실제 사용자 폴더를 읽지도 쓰지도 않는다(임시 `user://` 경로로 `Store.progress_path` 등을 돌리는 기존 시험 방식, `mission_test.gd` 머리글 참고). `$GODOT = "$env:USERPROFILE\Desktop\Godot_v4.6.3-stable_win64.exe\Godot_v4.6.3-stable_win64_console.exe"`.

### 7.1 단계 개요

| 단계 | 이름 | 사용자가 얻는 것 | 대략 규모 | 선행 |
|---|---|---|---|---|
| 1 | 폰 단독 기본 | PC 없이: 레슨, 복습, 받아쓰기, 쉐도잉 문장(시스템 음성 듣기), 약한 소리 목록, 미션 규칙·대본, 읽기(영어), 예문, 기록. 말하기는 자가 평가 | GDScript 약 3,500~4,500줄, 파이썬 도구 약 800줄, 데이터 팩 | 없음(단, 1.2 동기화와 `api.gd` 병합 순서, §4.5) |
| 2 | 음성 인식·단어 채점 | 말하기 채점, 쉐도잉 채점 | C++ 약 600줄, GDScript 약 1,800줄, 모델 2개 | 1단계 A1, 실제 폰 |
| 3 | AI(키 방식) | 대화·교정·피드백·AI 레슨·미션 판정·문맥 뜻 | GDScript 약 1,500줄 | 1단계 A1, (C0 시험) |
| 4 | 후속(선택) | 음성 팩, 일본어 분석기, 억양, 음소, 온디바이스 LLM | 각각 별도 설계 | 각 단계 완료 + 측정 |

### 7.2 1단계 작업 (A)

| ID | 담당 | 내용 | 수정 허용(전부) | 의존 | 동시 |
|---|---|---|---|---|---|
| A0 | 오케스트레이터 | §5.1~5.4 계약 확정, `local_api.gd`·`route.gd` **빈 스텁**과 `Route.POLICY` 표 커밋 | `godot/scripts/autoload/route.gd`, `local_api.gd`(스텁) | - | - |
| A1 | worker-hard | `Route` 결정 로직(§4.2), `LocalApi` 디스패치·`ok/fail`·합성 `/health`·`caps()`, `Api._start/_on_completed` 훅(폴백·`pc_flaky`), `sent_count` 약속, `ApiCall.cancel` 로컬 처리 | 신규 `godot/scripts/autoload/route.gd`, `local_api.gd`(+`.uid`), `godot/scripts/autoload/api.gd`(훅 추가만), `godot/project.godot`(autoload 2줄 추가만), 신규 `godot/tests/route_test.gd/.tscn` | A0 | A2와 병행 |
| A2 | worker-hard | **팩 빌드 도구** `build_phone_pack.py`: 레슨 은행(`lesson_rules.make_lesson` 호출), 연습 문장, 예문 샤드, 영어 어형·빈도표, IPA 표, 일본어 읽기 표, 미션·드릴 사본, `manifest.json`. 읽기 전용으로 `backend\cache`·`data`·`content`를 읽음(원본 수정 금지) | 신규 `backend/tools/build_phone_pack.py`, 신규 `backend/test_phone_pack.py`, 신규 `godot/data/pack/*`(생성물) | 없음 | A1·A5와 병행 |
| A2g | worker | 단어 뜻 사전 생성 `build_gloss_pack.py`(`POST /reading/gloss`를 켜진 PC 백엔드에 30개씩 호출해 결과를 `gloss_en.json` 등으로 정리, 형식 검사, 표본 검수 목록 출력). 백엔드는 오케스트레이터가 켜 둠 | 신규 `backend/tools/build_gloss_pack.py`, 신규 `backend/test_gloss_pack.py`, `godot/data/pack/gloss_*.json` | A2 일부(어휘 목록) | A3 시작과 병행 |
| A3a | worker | `LocalLessons`(은행 선택·`lesson_cursor`), `LocalPractice`(`practice.py` 이식) | 신규 `godot/scripts/local/local_lessons.gd`, `local_practice.gd`, `godot/tests/local_lessons_test.*` | A1(계약), A2(데이터, 우선 고정 픽스처로 시작) | A3b·A4·A5와 병행 |
| A3b | worker | `LocalMissions`(`normalize`, `goal_matches`, `list`, `check`) | 신규 `godot/scripts/local/local_missions.gd`, `godot/tests/local_missions_test.*` | A1, A2 | 병행 |
| A4 | worker-hard | `LocalReading`: 분석(영어), 일본어 제한 처리, 사전/IPA 조회, 예문 | 신규 `godot/scripts/local/local_reading.gd`, `godot/tests/local_reading_test.*` | A1, A2, A2g | 병행 |
| A5 | worker-hard | `Tts` 엔진 전환: 시스템 음성 목록·발화·정지·진행 콜백, 기존 신호(`state_changed`, `chunk_started`, `sequence_finished`, `voices_loaded`) 유지, `voice_label` 성별 없는 경우, `tts_engine` 정책 | `godot/scripts/autoload/tts.gd`, 신규 `godot/scripts/local/system_tts.gd`, 신규 `godot/tests/system_tts_test.*` | A1(`tts_engine` pref 이름) | 병행 |
| A6 | worker | UI: `ConnectView` "PC 없이 시작", 배너 배지, 설정 "처리 위치"+`CapabilityPanel`(기능 현황), 정보 화면 출처 표기 | `godot/scripts/ui/connect_view.gd`, 신규 `godot/scripts/ui/capability_panel.gd`, `godot/scripts/main.gd`, `godot/scripts/views/today_view.gd`(설정 카드 영역만) | A1(`Route.caps()`) | 병행 |
| A7 | worker-hard | 말하기 대체(`Route`가 `score`를 `none`으로 줄 때): 녹음→"내 목소리 듣기/원어민 듣기" 번갈아→"잘했어요/다시" 자가 평가 위젯, 음소·억양 카드 비활성+안내 | 신규 `godot/scripts/ui/self_rate_panel.gd`, `godot/scripts/views/lesson_view.gd`, `godot/scripts/views/review_view.gd`, `godot/scripts/practice/shadow_screen.gd`, `godot/scripts/practice/speak_drill.gd`, `godot/scripts/ui/score_panel.gd`·`prosody_panel.gd`(숨김/안내만) | A1, A5 | A6와 파일 겹침 없음 |
| A8 | worker | 빌드·용량·권한: export 포함 필터에 `data/pack/*`, APK 크기·권한 검증 스크립트 갱신, 새 prefs가 동기화 화이트리스트 밖임을 검사하는 시험 | `godot/export_presets.cfg`(`include_filter`만), `packaging/build_android.ps1`(크기 검사 추가만), 신규 `packaging/check_phone_pack.ps1`, `docs/` 사용자 가이드 한 절(`INSTALL.md` 폰 단독 절) | A2~A7 대부분 | 마지막 |
| R1 | reviewer | 독립 재실행(§8 전부) | 없음(읽기만) | A8 | - |

### 7.3 2단계 작업 (B)

| ID | 담당 | 내용 | 수정 허용 | 의존 |
|---|---|---|---|---|
| B0 | worker-hard + **사용자 폰** | **스파이크(go/no-go)**: ① NDK·CMake 설치(오케스트레이터 승인 필요, §13 도구) ② godot-cpp로 빈 GDExtension을 만들어 비-Gradle APK에 넣고 폰에서 `ClassDB.can_instantiate` 확인 ③ whisper.cpp tiny/base-q5_1을 폰에서 돌려 5초 영어 발화 전사 시간·RAM 측정 | 신규 `native/whisper_bridge/` 전체(CMake, 소스), 신규 `godot/bin/`(산출물, 저장소에는 올리지 않고 릴리스에도 `.so`만), `godot/whisper_bridge.gdextension` | 폰, A1 |
| B1 | worker-hard | `WhisperBridge` 본 구현(§5.7), 데스크톱(Windows) 빌드 병행(시험용) | `native/whisper_bridge/**`, `godot/whisper_bridge.gdextension` | B0 통과 |
| B2 | worker-hard | `LocalScore`: `score_en/score_ja/fluency/align/tips/en_words` 이식 + **황금 파일 시험**(PC 서버 출력과 입력 `words` 동일 시 동일 결과) | 신규 `godot/scripts/local/local_score.gd`, `godot/scripts/core/score_core.gd`, 신규 `godot/tests/score_parity_test.*`, 신규 `godot/tests/fixtures/score_golden_*.json` | A1 |
| B3 | worker-hard | `ModelStore`(내려받기·검증·삭제·진행률, §5.6) + 설정 "음성 인식" 카드 | 신규 `godot/scripts/local/model_store.gd`, 신규 `godot/scripts/ui/model_panel.gd`, `godot/scripts/views/today_view.gd`(카드 추가 영역만), 신규 `godot/tests/model_store_test.*` | A1, A6 |
| B4 | worker | `LocalStt`(`/stt`, `/score` 핸들러): `b64` WAV 디코드 → 16 kHz 모노 변환 → `WhisperBridge` → `LocalScore` | 신규 `godot/scripts/local/local_stt.gd`, `godot/scripts/core/wav_util.gd`(`to_16k_float` 추가만), 신규 `godot/tests/local_stt_test.*` | B1, B2, B3 |
| B5 | worker | 일본어 근사 가나 변환(`JaKana`) + 일본어 점수 연결 | 신규 `godot/scripts/core/ja_kana.gd`, `godot/tests/ja_kana_test.*`, (도구) `build_phone_pack.py`의 읽기 표 부분 | A2, B2 |
| B6 | worker | **보정·정확도 측정**: PC 서버(별도 포트)에 같은 WAV 세트를 보내 `OK_PROB_PHONE` 결정, 정확도 표 작성 | `godot/data/pack/score_params.json`, 신규 `tools/` 측정 스크립트(`godot/tools/calibrate_*.gd`), 보고서는 보고 메시지로 | B4, B5 |
| B7 | worker-hard | 빌드 통합: APK에 `lib/arm64-v8a/libwhisper_bridge...so` 포함 확인, 크기·권한·서명 검증 갱신 | `packaging/build_android.ps1`, `packaging/check_phone_pack.ps1`, `godot/export_presets.cfg` | B1 |
| R2 | reviewer | 독립 재실행 | - | B7 |

### 7.4 3단계 작업 (C)

| ID | 담당 | 내용 | 수정 허용 | 의존 |
|---|---|---|---|---|
| C0 | **오케스트레이터 + 사용자** | **OpenCode Zen 무료 모델이 API 키로 CLI 밖에서 되는지 1회 시험**: 사용자 본인 키로 `POST https://opencode.ai/inference/v1/chat/completions`에 한 문장 요청(키를 채팅·로그에 붙여 넣지 않는다). 결과(성공/거부 메시지)만 기록 | 없음 | - |
| C1 | worker-hard | `AiClient`(§5.8), 키 저장(`user://secrets.cfg`), 오류 분류 | 신규 `godot/scripts/local/ai_client.gd`, `ai_secrets.gd`, 신규 `godot/tests/ai_client_test.*` (가짜 HTTP 서버 포트 18791~18799) | A1 |
| C2 | worker-hard | `LocalAi`: `/chat`, `/fix`, `/feedback`, `/missions/judge`, AI 레슨의 프롬프트·검증 이식 | 신규 `godot/scripts/local/local_ai.gd`, 신규 `godot/data/pack/prompts.json`, 신규 `godot/tests/local_ai_test.*` | C1 |
| C3 | worker | 설정 "AI 연결" 카드(프리셋 선택, 키 입력, 시험 호출, 안내 문구), 빈 AI 화면 대신 "대본 대화" 목록 | 신규 `godot/scripts/ui/ai_panel.gd`, `godot/scripts/views/talk_view.gd`(AI 없음 상태 영역만), `godot/scripts/views/today_view.gd`(카드 추가 영역만) | C1 |
| C5 | worker-hard (선택) | 대화 팩 생성 도구(PC AI로 대본 생성+형식 검사+검수 목록) | 신규 `backend/tools/build_dialog_pack.py`, `godot/data/pack/dialogs_*.json` | A2 |
| R3 | reviewer | 독립 재실행 | - | C3 |

### 7.5 후속(4단계) 후보와 시작 조건

| ID | 후보 | 시작 조건(측정으로 결정) | 비고 |
|---|---|---|---|
| D1 | 음성 팩(Kokoro 미리 만든 Ogg) | 시스템 음성에 대한 불만이 실제로 나오고, 3,000문장 팩 약 30 MB가 괜찮다고 승인 | 쉐도잉 품질 상승, 억양 윤곽 선계산과 같이 |
| D2 | 일본어 형태소 분석기(Rust lindera GDExtension) | 일본어 읽기 요구가 큼 | APK +15~50 MB **(추측)** |
| D3 | 영어 음소 교정(ONNX int8) | 폰 5초 발화 추론 ≤ 8초, RAM ≤ 1.2 GB가 B0 같은 스파이크로 확인 | 모델 약 300 MB |
| D4 | 억양(선계산 윤곽 + 폰 피치 추출) | D1 완료 | 레슨 문장에 한함 |
| D5 | 온디바이스 LLM(llama.cpp) | 실기에서 소형 모델의 한국어 설명·JSON 품질 시험 통과 | 대화 상대 역할만 |

---

## 8. 합격 조건 (O/X)

`$GODOT`은 §7 머리글의 값. 모든 Godot 시험은 `& $GODOT --headless --path <repo>\godot res://tests/<이름>.tscn`로 돌리고 **마지막 줄이 `== <이름> result: N passed, 0 failed ==`** 이며 종료코드 0이다(`sync_design.md`와 같은 형식). 아래 N은 최소값이다.

### A1 `Route`·`LocalApi`·`Api` 훅
| # | 조건 | 판정 방법 |
|---|---|---|
| A1-1 | `route_test` 통과, N ≥ 40 | 위 형식 |
| A1-2 | 정책 표 전수: §4.3의 모든 (메서드, 경로) × 모드 3 × (PC 있음/없음) × (폰 가능/불가) 조합의 `decide()` 결과가 기대표와 일치 | `route_test` 안의 표 비교, 실패 0 |
| A1-3 | 모드 `pc`에서 기존 동작 불변: 기존 시험 `remote_test`, `flow_test`, `persist_test`, `lifecycle_test`가 변경 전과 같은 통과 수 | 각 시험 실행 결과 비교(변경 전 수치를 보고에 기록) |
| A1-4 | 폰 처리 요청은 `Api.sent_count`를 올리지 않는다 | 시험에서 `sent_count` 전후 비교 0 |
| A1-5 | 취소: 폰 처리 중 `cancel()` → 결과 `cancelled:true`, 늦게 온 결과는 무시, `active_count` 0 복귀 | 시험 |
| A1-6 | 폴백: 가짜 PC가 `transport` 오류를 내면 자동 모드에서 같은 요청이 폰 핸들러로 가고 `data.via=="phone"`; 이후 60초 동안 PC로 요청이 가지 않음(`sent_count` 불변) | 시험(가짜 시계/타이머 주입) |
| A1-7 | 금지: `godot/scripts/views/`, `practice/`, `ui/` 파일 수정 0, `backend/` 수정 0 | 변경 파일 목록 비교 |

### A2 팩 빌드 도구
| # | 조건 | 판정 방법 |
|---|---|---|
| A2-1 | `.venv\Scripts\python.exe -I backend\test_phone_pack.py` 종료코드 0, 통과 N ≥ 25 | 실행 |
| A2-2 | 레슨 은행: 96칸(영 48 + 일 48)이 각 ≥ 10레슨, 레슨마다 `exercises` 길이 4~10, 모든 문제가 `API.md /lesson` 필수 키를 가짐 | 시험의 스키마 검사 |
| A2-3 | 정답 검증: 은행 모든 `choice/fill/listen`에서 `answer`가 `options` 범위 안, `build`에서 `answer` 토큰을 이어 붙인 문장이 `extra` 토큰을 포함하지 않음 | 시험 |
| A2-4 | `manifest.json`의 모든 파일 크기·SHA-256이 실제와 일치 | 시험 + `Get-FileHash` 1개 무작위 확인 |
| A2-5 | 팩 총 크기(압축 전) ≤ 30 MB, 단일 파일 ≤ 10 MB | `Get-ChildItem godot\data\pack -Recurse \| Measure-Object Length -Sum` |
| A2-6 | 의도적 오류: 입력 DB가 없으면 한국어/영어 메시지와 함께 종료코드 ≠ 0(빈 팩을 만들지 않음) | `--db 없는경로`로 실행 |
| A2-7 | 금지: `backend\cache`·`backend\data`·`backend\content` 원본 수정 0(해시 전후 동일), `backend\server.py` 등 기존 `.py` 수정 0, 사용자 폴더·`secrets.json` 접근 0 | 해시 비교 |
| A2-8 | 개인정보: 팩에 학습 기록·로그·경로 문자열(`Users`, `AppData`)이 없음 | `Select-String -Path godot\data\pack\* -Pattern "Users\\|AppData"` 0건 |

### A2g 뜻 사전
| # | 조건 | 판정 |
|---|---|---|
| A2g-1 | `gloss_en.json` 항목 ≥ 10,000, `gloss_ja.json` ≥ 5,000, 모든 `ko`가 한글 포함·길이 1~60자 | 시험 |
| A2g-2 | 무작위 100개(고정 시드) 목록이 보고에 있고 사람 검수 칸이 비어 있음(검수는 오케스트레이터) | 파일 존재 |
| A2g-3 | 백엔드가 꺼져 있으면 즉시 실패(0건 성공 처리 금지) | 서버 없이 실행 → 종료코드 ≠ 0 |

### A3a 레슨·연습, A3b 미션
| # | 조건 | 판정 |
|---|---|---|
| A3a-1 | `local_lessons_test` N ≥ 30 통과 | 실행 |
| A3a-2 | `POST /lesson {lang:"en",month:3,week:2}` → `exercises` ≥ 4, `source=="tatoeba"`, `attribution` 비어 있지 않음, `via=="phone"` | 시험 |
| A3a-3 | 같은 칸을 연속 N+1번 요청: 처음 N번은 서로 다른 `bank_id`, 소진 후 순환하며 `degraded`에 `bank_repeat` | 시험 |
| A3a-4 | 쉐도잉 `GET /practice/sentences?lang=en&mode=shadow&n=5&seed=1`을 두 번 호출하면 같은 결과(재현성), `exclude=<id>`를 주면 그 id 제외 | 시험 |
| A3b-1 | `local_missions_test` N ≥ 60 통과 | |
| A3b-2 | `missions.json`의 **모든 목표**에서 `pos` 예문 전부 매치, `neg` 예문 전부 비매치 (정규식 PCRE2 호환 검증) | 시험이 데이터에서 직접 읽어 전수 실행 |
| A3b-3 | 파이썬 `missions.check_text`와 일치: 고정 입력 30개에 대해 `reached` 집합이 같음(황금 파일은 파이썬이 생성) | 시험 |
| A3b-4 | 의도적 오류: 깨진 정규식 한 개를 넣은 가짜 미션 → 그 미션만 비활성, 나머지 정상, 앱 크래시 0 | 시험 |
| 공통 금지 | `scripts/local/` 안 자기 파일 외 수정 0, `Api`·`Route` 수정 0 | 변경 목록 |

### A4 읽기
| # | 조건 | 판정 |
|---|---|---|
| A4-1 | `local_reading_test` N ≥ 40 | |
| A4-2 | 영어 문단 5개를 `/reading/analyze`에 보냈을 때 PC 결과와 **단어 `lemma` 일치율 ≥ 90%**, `level`(easy/mid/hard) 일치율 ≥ 85% (황금: PC 서버 출력 파일) | 시험 |
| A4-3 | `lang:"ja"` → `err_code=="ja_reading_pc"` 또는 제한 안내(앱이 멈추지 않음) | 시험 |
| A4-4 | `/reading/gloss`: 사전에 있는 단어는 `ko` 반환, 없는 단어는 `degraded:["gloss_partial"]`와 부분 결과(전체 실패로 만들지 않음) | 시험 |
| A4-5 | 20,000자 초과 입력은 PC와 같은 한국어 오류 메시지 | 시험 |

### A5 시스템 TTS
| # | 조건 | 판정 |
|---|---|---|
| A5-1 | `system_tts_test` N ≥ 25 (가짜 `DisplayServer` 어댑터 주입) | |
| A5-2 | 신호 순서: `speak("A. B.","en")` → `state_changed`(말하는 중), `chunk_started(0)`, `chunk_started(1)`, `sequence_finished` 1회 | 시험 |
| A5-3 | 일본어 음성 없음 → `Toast`용 오류 문구가 §3.2의 것이고 크래시 0 | 시험 |
| A5-4 | 첫 발화가 `CANCEL`로 끝나면 정확히 1회 재시도 | 시험 |
| A5-5 | `tts_engine=pc`일 때 `/tts` 경로가 그대로(기존 `test_tts` 기반 시험 통과 수 불변) | 기존 시험 |
| A5-6 | **실기(사용자 폰)**: 영어 문장·일본어 문장을 각각 재생해 소리가 나고, 정지 버튼이 1초 안에 멈춤 | 실기 시험표 H1 |

### A6 UI, A7 말하기 대체
| # | 조건 | 판정 |
|---|---|---|
| A6-1 | 데스크톱 `-- --phone` 레이아웃 시험(`phone_layout_test`) 통과 수가 변경 전 이상, 새 버튼·카드로 인한 잘림 0 | 시험 |
| A6-2 | "PC 없이 시작" 누르면 `prefs.standalone_ok==true`, 홈 화면 도달, PC 요청 0건 | 시험 |
| A6-3 | `CapabilityPanel`이 `Route.caps()`의 키 16개를 모두 표시, `none`이면 이유 한 줄 | 시험 |
| A7-1 | `score`가 `none`일 때 레슨 말하기 문제·쉐도잉·복습 말하기가 자가 평가 위젯으로 바뀌고 `Api.post_json("/score")` 호출 0건 | 시험(`calls` 기록) |
| A7-2 | 자가 평가 "잘했어요"가 레슨 결과·`StudyLog`에 말하기 1회로 기록, "다시"는 기록 안 함 | 시험 |
| A7-3 | 금지: 위 작업 표 밖 파일 수정 0 | 변경 목록 |

### A8 빌드·통합 (1단계 종합, 오케스트레이터가 직접 재실행)
| # | 조건 | 판정 |
|---|---|---|
| A8-1 | `powershell -ExecutionPolicy Bypass -File packaging\build_android.ps1 -Version <v> -Debug` 성공, APK ≤ 100,000,000 바이트(예상 ≤ 50 MB) | `(Get-Item <apk>).Length` |
| A8-2 | APK 권한은 지금과 같은 3개(INTERNET, ACCESS_NETWORK_STATE, RECORD_AUDIO)만 | 스크립트의 권한 검증 통과 |
| A8-3 | APK 안에 `assets`/PCK에 `data/pack/manifest.json` 존재 | `unzip -l` 또는 Godot 로그 |
| A8-4 | 새 prefs 키(§5.4)가 동기화 화이트리스트 `SHARED_PREFS`에 없음 | 시험이 `SyncDoc.SHARED_PREFS`(또는 해당 상수)와 교집합 0 확인(1.2 코드가 아직 없으면 §4.5 문구로 "미검증") |
| A8-5 | **네트워크 없는 폰 단독 시험(데스크톱 `-- --phone --api=http://127.0.0.1:9`, 닫힌 포트)**: 레슨 1회, 복습 1회, 받아쓰기 1회, 쉐도잉 문장 듣기, 미션 대본 모드, 읽기(영어) 분석이 모두 성공하고 `Api.sent_count == 0` | `godot/tests/standalone_flow_test`(A8 소유, 신규) |
| A8-6 | **실기(사용자 폰, 비행기 모드)**: 위 흐름을 손으로 수행. 각 기능 O/X 기록 | 실기 시험표 H2 |
| 금지 | 서명 키·비밀번호를 출력/기록하지 않음, `packaging/android_cert.sha256` 불변, 서명 지문이 고정값과 같음(`build_android.ps1`가 이미 검사) | |

### B 단계
| # | 조건 | 판정 |
|---|---|---|
| B0-1 | 빈 GDExtension이 비-Gradle APK의 `lib/arm64-v8a/`에 들어가고 폰에서 `ClassDB.can_instantiate("WhisperBridge")==true` | `unzip -l`, 폰 로그 |
| B0-2 (go/no-go, **제안값**) | `base-q5_1`, 5초 영어 발화(Kokoro 합성음, 사람 목소리 아님) 전사 총 시간 ≤ 8초, 최대 RAM 증가 ≤ 700 MB, 5회 연속 안 죽음 | 앱 로그의 `ms`, `adb shell dumpsys meminfo` |
| B0-3 | 결과 단어 목록이 비어 있지 않고 `words[].p`가 모두 0~1, `start<end`, 단조 증가 | 시험 |
| B2-1 | `score_parity_test` N ≥ 60: PC 서버가 낸 황금 파일(영어 25문장·일본어 15문장)의 `words` → `LocalScore` 결과의 `score, accuracy, clarity, fluency, units[].ok/heard, tips_ko`가 **전부 동일** | 시험 |
| B2-2 | 일부러 틀린 입력: `words` 빈 배열 → PC와 같이 `score 0`·"소리를 못 들었어요" 계열 팁, `target` 빈 문자열 → 400 한국어 메시지 | 시험 |
| B3-1 | `model_store_test` N ≥ 30: 정상 내려받기(로컬 가짜 서버), 중간 끊김 후 이어받기, 해시 불일치 → 파일 삭제 + `model_corrupt`, 디스크 부족(가짜) → 시작 전 거절, 취소 → `.part` 정리 | 시험 |
| B3-2 | 내려받기 중 취소·앱 닫기에서 메인 스레드가 멈추지 않음(2초 이내 반응) | 시험(타이머) |
| B4-1 | 무음 WAV → `{text:"", words:[]}`와 PC와 같은 "소리를 못 들었어요", 0바이트·깨진 base64 → 400 한국어 메시지, 30초 초과 → 30초로 자름 | 시험 |
| B5-1 | 일본어 근사 가나: 레슨 은행 일본어 문장 전체(`text`→`reading`)에서 `ja_reading_map` 변환과 PC `reading` **모라 일치율 ≥ 95%** | 시험 |
| B6-1 (**제안값**) | 영어 20문장·일본어 20문장(Kokoro 합성음, 일부는 일부러 틀린 단어를 섞은 변형) 에서 PC와 단어별 `ok` 일치율 영어 ≥ 85%, 일본어 ≥ 75%; 못 미치면 모델 상향(small) 또는 해당 언어 폰 채점을 "베타" 표시 | 보정 보고서의 표 |
| B7-1 | APK 안 `lib/arm64-v8a/`에 `.so` 있음, APK ≤ 100 MB, 서명 지문 동일, 권한 3개 | 스크립트 |
| B 금지 | `.gdextension`/`native/` 밖 파일은 소유 작업만, 모델 파일(`*.bin`)을 저장소에 커밋하지 않음(`git status`/`.gitignore`), 릴리스 업로드는 오케스트레이터만 | 목록 확인 |

### C 단계
| # | 조건 | 판정 |
|---|---|---|
| C0-1 | 시험 결과(성공 또는 거부 메시지 요약)가 기록됨. 키는 어디에도 출력되지 않음 | 기록 확인 |
| C1-1 | `ai_client_test` N ≥ 40 (가짜 HTTP 서버): 200 정상, 401 → `ai_auth`, 429 → `ai_limit`, 503/타임아웃 → `ai_overload`, JSON 아님 → 재시도 1회 후 `bad_format` | 시험 |
| C1-2 | 키 비노출: 시험 전체 출력과 로그에서 시험용 가짜 키 문자열 0건 | `Select-String` |
| C1-3 | `secrets.cfg`가 `user://` 아래에만 생성, 동기화 화이트리스트에 없음 | 시험 |
| C2-1 | `local_ai_test` N ≥ 50: 가짜 AI 응답을 넣어 `/chat` 거부 규칙(영어 답에 한글 포함, 일본어 답에 한글만, 한국어 번역 `ko_ok` 실패)이 PC `run_chat`과 같은 결정을 내림 | 시험(황금 입력 10쌍) |
| C2-2 | AI 없음(`ai_local=none`) → `/chat`, `/fix`, `/feedback`가 `no_ai`로 즉시 실패(네트워크 0건) | 시험 |
| C3-1 | 화면: 키 입력 칸은 가려져 있고 저장 후 마지막 4자만 보임, "시험 호출" 결과 O/X 표시 | 시험 |
| C 금지 | 프롬프트·키를 로그/토스트에 쓰지 않음, 업체 base_url은 프리셋 목록 또는 사용자가 직접 입력한 `https://`만 허용(`http://`·`file://` 거부) | 시험 |

---

## 9. 시험 방법

### 9.1 폰 없이
- 모든 `LocalApi` 핸들러는 순수 GDScript라 데스크톱 `-- --phone` 모드와 `--headless`로 시험한다(`Platform.is_phone()`이 참).
- `WhisperBridge`는 Windows용 같은 소스 빌드로 데스크톱에서 같은 모델·같은 WAV를 돌려 정확도·황금 파일 시험을 한다(속도는 대표하지 않음).
- 가짜 서버: 기존 `backend\lan_stub_server.py`(PC 끊김·폴백 시험), 모델 서버·AI 서버는 시험용 작은 `http.server` 스크립트(작업자가 `scratchpad\w_<ID>\`에 둠).
- PC 황금 파일 만들기: 별도 포트(`--port 187xx --tag w_<ID> --stt-cpu`)로 `server.py`를 띄우고 `/score`·`/reading/analyze`·`missions.check_text`의 출력을 JSON으로 저장 → 시험 픽스처. 입력 WAV는 사람 목소리 대신 Kokoro 합성음을 사용(개인 음성 파일 금지).

### 9.2 실제 폰이 필요한 것 (사용자 폰 1대, adb)
| 표 | 내용 |
|---|---|
| H1 | 시스템 TTS 영어·일본어 재생·정지, 일본어 음성 없음 시 안내 |
| H2 | 비행기 모드에서 1단계 흐름 전체 |
| H3 | 비-Gradle APK의 GDExtension 로딩(B0), 전사 속도·RAM·발열(10분 연속 5회 전사 후 폰 온도 느낌, 앱 종료/재시작 후 모델 유지) |
| H4 | 모델 내려받기(Wi-Fi/모바일 데이터), 도중 앱 전환·화면 끔·네트워크 끊김 |
| H5 | PC 연결 ↔ 끊김 전환 시 자동 폴백(Tailscale 끄기) |
| H6 | 마이크 권한 거부 후 흐름 |

---

## 10. 위험 요소와 대안

| # | 위험 | 영향 | 대응·대안 |
|---|---|---|---|
| R1 | 비-Gradle APK에서 GDExtension `.so`가 4.6.3에서 로드되지 않음 | 2단계 불가 | B0에서 먼저 확인. 소스(4.5)상 `save_apk_so` 경로가 있다. 실패 시 Gradle 빌드 전환(빌드 스크립트·검증·서명 흐름 변경, 별도 설계) 또는 `SpeechRecognizer` 플러그인안 재검토 |
| R2 | 폰 전사가 너무 느림/정확도 낮음(특히 일본어) | 말하기 품질 불만 | 모델 상향(small), `audio_ctx` 축소 **(추측: 품질 저하 가능)**, 일본어 폰 채점은 "베타" 표시, 최악엔 `none`+자가 평가 유지(1단계로 이미 동작) |
| R3 | NDK/CMake/godot-cpp 환경 구축 부담(약 1~1.5 GB 다운로드, 도구 버전 호환) | 일정 | 오케스트레이터 승인 필요(§13). 현재 기록상 NDK·CMake·Gradle 미설치(`android_remote_design.md` §13) |
| R4 | 시스템 TTS 품질·일본어 음성 부재 | 듣기 품질 | 안내 문구, 후속 음성 팩(D1) |
| R5 | 폰 간이 점수와 PC 점수가 한 통계에 섞여 추이 그래프가 왜곡 | 지표 신뢰 | `OK_PROB` 보정(B6) + 점수 옆 "폰 간이 채점" 표시. 필요하면 후속에서 `via` 저장(동기화 스키마 변경 필요, 별도 결정) |
| R6 | GDScript에 NFKC가 없어 미션 정규화·텍스트 비교가 PC와 달라짐 | 판정 오차 | 전각/곡선따옴표/공백 치환표로 대부분 처리, 미션 `pos/neg` 전수 시험과 황금 입력으로 확인. 남는 차이는 알려진 한계로 기록 |
| R7 | 레슨 은행 반복 | 지루함 | 20개/칸 시작, 반복 시 안내. 후속 런타임 생성기 이식(방식 B) |
| R8 | 사용자 API 키 유출·과금 | 금전·개인정보 | 앱 비공개 저장(백업 끔), 화면에 마지막 4자, 사용량 한도는 업체 콘솔에서 설정하도록 안내, 로그에 키 금지(C1-2). 공용 키 내장 금지 |
| R9 | OpenCode 무료 모델이 키 직접 호출로는 거부 | 폰 단독의 "무료 AI" 소실 | C0에서 확인. 거부면 DeepSeek 등 유료 키를 안내하고 무료 경로는 "PC 연결 시"로 문구 고정 |
| R10 | 큰 모델 내려받기 실패·데이터 요금 | 사용자 불만 | Wi-Fi 기본, 이어받기, 해시 검증, 삭제 버튼, 남은 용량 표시 |
| R11 | 앱 배경 전환·화면 꺼짐 중 전사/다운로드 | 크래시·메모리 | `NOTIFICATION_APPLICATION_PAUSED`에서 전사 `abort()`, 다운로드는 일시정지(다음 실행에서 이어받기) |
| R12 | PC 없이 기록 이전 수단이 없음(폰 교체·삭제 시 소실) | 기록 손실 | 1단계 화면에 경고 문구, 후속 "기록 내보내기/가져오기" 설계(공유 인텐트 또는 네이티브 파일 대화상자 지원 여부는 **(추측, 확인 필요)**) |
| R13 | 라이선스 조건 누락(wordfreq CC BY-SA 가능성, GPL espeak 출력, Tatoeba) | 법적 | §6 표를 정보 화면에 반영, 불확실 항목은 릴리스 전 오케스트레이터가 확인 |
| R14 | `api.gd` 변경이 1.2 동기화 작업과 충돌 | 병합 비용 | §4.5의 순서 결정. A1 변경은 훅 한 군데+폴백 한 군데로 최소화 |
| R15 | 작은 팩 JSON 파싱이 느린 폰에서 홈 화면을 막음 | 시작 지연 | 지연 로딩(처음 쓸 때) + `Thread`에서 파싱, 시험으로 4 MB JSON 파싱 시간 기록(**(실측 필요)**) |

---

## 11. 일부러 틀린 입력으로 확인할 실패 시나리오

| # | 입력 | 기대 결과 |
|---|---|---|
| F1 | 팩 JSON 한 개의 한 글자를 바꿔 해시 불일치 | 그 기능만 `pack_corrupt`, 나머지 기능 정상, 앱 크래시 0, 한국어 안내 |
| F2 | `lesson_bank_en.json`을 깨진 JSON(중간 잘림)으로 교체 | 같은 방식으로 `pack_corrupt`(빈 레슨을 정상처럼 보여 주지 않음) |
| F3 | `prefs.route_mode = "아무거나"` | `auto`로 취급, 크래시 0 |
| F4 | 모델 매니페스트의 `sha256`을 틀리게 하고 내려받기 | 완료 후 파일 삭제 + `model_corrupt`, `.part` 잔여물 0 |
| F5 | 모델 파일을 절반으로 잘라 `load_model` | 오류 반환(`model_corrupt`), 앱 크래시 0 |
| F6 | 0바이트·무음·30초 초과·샘플레이트 8 kHz/스테레오 WAV를 `/stt`에 | 각각: 400 한국어 / 빈 결과 + "소리를 못 들었어요" / 30초로 자름 / 정상 변환 |
| F7 | 틀린 API 키 | `ai_auth` → "키가 맞지 않아요. 설정 > AI 연결에서 확인해 주세요." |
| F8 | AI가 JSON이 아닌 문장을 줌 | 재시도 1회 후 `bad_format` 한국어 오류, 무한 재시도 없음 |
| F9 | AI base_url에 `http://…`, `file://…` | 거부 |
| F10 | 폰이 PC 연결 중 PC를 끔(요청 도중) | 폴백 또는 `none`+안내, 90초 대기 반복 없음(§4.2) |
| F11 | 일본어 시스템 음성 없음 | 안내 문구, 영어 발음으로 읽지 않고 정지 |
| F12 | 저장 공간 부족(가짜 `get_space_left`) | 내려받기 시작 전 거절 |
| F13 | 전사 중 앱이 백그라운드로 | `abort()` 후 정상 복귀, 메모리 증가 없음 |
| F14 | `/reading/analyze`에 20,001자 | PC와 같은 한국어 400 |
| F15 | 미션 정규식 하나가 PCRE에서 컴파일 실패 | 해당 미션만 비활성(A3b-4) |
| F16 | 점수 입력 `words`가 `p` 범위 밖(−1, 2)·`start>end` | 값을 0~1·단조로 보정하고 크래시 0 |

---

## 12. 사용자에게 솔직히 알릴 "폰에서는 PC만큼 안 되는 것"

앱 안 "도움말 > 폰 단독 사용" 화면과 설정의 기능 현황 표에 그대로 싣는다.

| # | 항목 | 한 줄 안내(문구) |
|---|---|---|
| 1 | 목소리 | "폰 음성은 휴대폰에 설치된 음성이라 PC의 원어민 목소리와 달라요. 일본어는 음성 데이터를 따로 설치해야 할 수 있어요." |
| 2 | 음성 인식 | "처음 한 번 모델을 내려받아야 하고(영어 약 60 MB, 일본어 약 190 MB), PC보다 느리고 덜 정확해요. 시끄러운 곳에서는 더 그래요." |
| 3 | 발음 채점 | "폰은 단어 단위 간이 채점이에요. 점수 숫자가 PC와 같은 뜻이 아니에요." |
| 4 | 소리(음소)·억양 | "소리별 교정과 억양 그래프는 PC에 연결했을 때만 돼요." |
| 5 | AI 대화·교정·피드백 | "AI를 쓰려면 PC에 연결하거나 본인 API 키가 필요해요. 키를 쓰면 문장이 선택한 업체로 전송되고 사용료는 업체가 키 주인에게 청구해요. 무료 DeepSeek(OpenCode)는 PC에서만 돼요." |
| 6 | 문법 교정 | "AI 연결이 있을 때만 나와요." |
| 7 | 레슨 | "미리 만들어 둔 예문 레슨이라 같은 문제가 다시 나올 수 있어요. 새로 만드는 AI 레슨은 AI 연결이 필요해요." |
| 8 | 읽기 | "영어 글은 읽을 수 있어요. 일본어 글 분석은 아직 PC에서만 돼요. 뜻은 대표 뜻만 보여 주고, 문장 속 정확한 뜻은 AI 연결이 있을 때 나와요." |
| 9 | 예문 검색 | "폰에는 한국어 번역이 있는 예문 약 1만 개만 들어 있어요. PC에는 훨씬 많아요." |
| 10 | 기록 | "PC 없이 쓰면 기록이 이 폰에만 있어요. 앱을 지우거나 폰을 바꾸면 사라질 수 있어요." |
| 11 | 미션 | "AI 상대와의 미션은 AI 연결이 필요해요. 없으면 대본 모드로 연습해요." |
| 12 | 저장 공간·배터리 | "모델은 설정에서 지울 수 있어요. 음성 인식은 배터리를 더 쓰고 폰이 따뜻해질 수 있어요." |

---

## 13. 오케스트레이터가 정해야 할 사항

### 13.1 사용자에게 물어볼 것 (최대 5개, 각 추천 포함)
| Q | 질문 | 추천 |
|---|---|---|
| Q1 | 진행 순서와 범위: 1단계(폰 단독 기본, 네이티브 없음)를 먼저 끝내고 2단계(음성 인식)로 갈까요? | **예.** 1단계만으로도 레슨·복습·듣기·읽기·기록이 폰 단독으로 돈다. 2단계는 NDK 설치와 실제 폰 시험이 필요하므로 스파이크(B0) 통과 뒤 시작 |
| Q2 | 음성 인식 모델 내려받기 용량을 받아들이나요? (영어 약 60 MB 기본 + 일본어 약 190 MB 선택, Wi-Fi 기본) | **예.** 영어는 `base-q5_1`, 일본어는 `small-q5_1`. 폰 성능(B0 측정)에 따라 조정 |
| Q3 | 폰 단독에서 AI는 어떻게? (a) 본인 API 키 입력 허용 (b) AI 없음 + PC 연결 때만 (c) 온디바이스 소형 AI | **(a) 선택 기능으로 제공하되 기본은 AI 없음.** (c)는 v1~v3 제외. 먼저 C0(키로 OpenCode 무료 모델이 되는지) 확인 |
| Q4 | PC 연결 중 정책: 자동(PC 우선, 끊기면 폰 대체)을 기본으로, 설정에서 "폰만/PC만"을 고르게 할까요? TTS도 연결 중엔 PC 목소리 우선? | **예.** 자동 기본. TTS는 연결 중 PC(Kokoro) 우선, 설정에서 "항상 폰 음성" 선택 가능 |
| Q5 | 폰 단독 문법 교정에 LanguageTool 공개 서버(외부 전송, 약관상 대량 자동 호출 비권장)를 넣을까요? | **넣지 않는다.** AI 키가 있을 때 AI가 교정, 없으면 교정 카드 숨김 |

### 13.2 기본값으로 진행해도 되는 작은 결정 (반대할 때만 알려 주세요)
| # | 결정 | 기본 |
|---|---|---|
| S1 | `api.gd` 병합 순서(1.2 동기화 S3와 A1) | 동기화(S3)를 먼저 합치고 그 위에서 A1 시작 |
| S2 | 레슨 은행 크기 | 칸당 20레슨 |
| S3 | 모델·음성 팩 호스팅 | 이 저장소의 별도 GitHub 릴리스 태그(`models-1`), SHA-256은 APK 안에 고정 |
| S4 | 단어 뜻 사전 생성에 쓰는 엔진 | 지금 켜진 PC 백엔드(`/reading/gloss`), 호출 약 800회, 표본 100개 검수는 오케스트레이터 |
| S5 | 일본어 읽기(붙여 넣기)는 폰 단독 v1 제외 | 제외, 안내 문구로 대체 |
| S6 | 폰 점수 표시 | 점수 옆 "폰 간이 채점", `via`는 저장하지 않음(R5) |
| S7 | 실기 시험 기기 | 사용자의 현재 폰 1대(기종·안드로이드 버전·RAM은 B0 보고에 기록; 지금은 모름) |
| S8 | NDK/CMake 설치 | 2단계 시작 때 별도 승인 후 설치(약 1~1.5 GB) |

---

## 부록 A. 추측·미확인 목록 (착수 전에 검증)

1. 4.6.3의 비-Gradle APK가 GDExtension `.so`를 포함하는지(4.5 소스는 확인, 4.6.3은 B0에서).
2. `SpeechRecognizer` 관련 API 레벨(온디바이스 33+, 단어 정보 34+)은 문서·기억 기반.
3. 폰에서 whisper.cpp 속도·RAM·정확도 전부(tiny/base/small, 영어/일본어).
4. whisper.cpp 토큰 확률/시각으로 만든 단어 `p`가 PC(faster-whisper)와 같은 의미가 되는지(평균 방식 등).
5. wordfreq 데이터 라이선스(CC BY-SA 4.0으로 기억).
6. 안드로이드에서 `DirAccess.get_space_left()`와 연결 종류(Wi-Fi/모바일) 판별 가능 여부.
7. 안드로이드 11+에서 시스템 TTS 엔진 노출(`<queries>`).
8. OpenCode Zen 무료 모델의 API 키 직접 호출 가능 여부(문서는 가능해 보이나 이 저장소의 과거 실측은 거부).
9. 업체별 데이터 사용 정책(무료 등급 학습 사용 등).
10. 음소 모델 ONNX int8 크기·폰 추론 시간.
11. 네이티브 파일 대화상자의 안드로이드 지원(기록 내보내기).
12. 레슨 은행의 레슨당 크기·APK 압축률.

## 부록 B. 조사 출처 (읽기만 함)

- Android SDK 소스(aosp-mirror): `RecognitionPart.java`, `SpeechRecognizer.java`, `RecognizerIntent.java`, `current.txt`
- Godot: 4.5 브랜치 `platform/android/java/lib/src/org/godotengine/godot/tts/GodotTTS.java`, `platform/android/export/export_plugin.cpp`, 공식 문서 `class_displayserver`, `android_plugin`
- whisper.cpp README(github.com/ggml-org/whisper.cpp), 모델 목록(huggingface.co/ggerganov/whisper.cpp)
- Vosk 모델 표(alphacephei.com/vosk/models)
- sherpa-onnx Kokoro 문서(k2-fsa.github.io/sherpa/onnx/tts/pretrained_models/kokoro.html), Android 개요
- OpenCode 문서 `docs/zen`, `docs/server`, `legal/terms-of-service`
- LanguageTool 공개 API(dev.languagetool.org/public-http-api), 개인정보 방침(languagetool.org/privacy)
- ML Kit GenAI 문서·기사(2025~2026), 소형 LLM 속도 글(간접 근거)
- EDRDG JMdict 언어 목록 메일링 기록(한국어 뜻 없음)

## 결정 (2026-10-17, 사용자)
- 진행: 단계별(1단계 네이티브 없음 → B0 실기 스파이크 통과 뒤 2단계). 모델: 영어 base 기본, 일본어 small 선택 다운로드(Wi-Fi 기본).
- 폰 단독 AI: 기본 "AI 없음"(대본 대화), 선택 기능으로 사용자 본인 API 키. 온디바이스 LLM 제외. C0(본인 키로 OpenCode 무료 모델 직접 호출 시험)는 사용자가 키를 앱에 직접 입력하는 방식으로만.
- 연결 중 정책: 자동(PC 우선, 끊기면 폰) 기본 + 설정에서 폰만/PC만, TTS 는 연결 중 PC 목소리 우선 + "항상 폰 음성" 옵션. LanguageTool 공개 서버 미사용.
- NDK·CMake 설치: 2단계 시작 때 sdkmanager 로 설치 허용(사용자 승인).
- 순서: 동기화 구현 → UI 개편 W0~W3·W6~W11 과 병행 가능한 1단계 작업부터, 겹치는 파일(api.gd, main.gd, today_view.gd, connect_view.gd, talk_view.gd)은 동기화 S3/S7 병합 뒤.
