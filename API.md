# 회화 앱 구조와 API 계약

데스크톱 학습 앱. 화면은 Godot 4.6.3, 음성·AI 처리는 같은 PC의 파이썬 로컬 서버가 맡는다. 음성 인식·목소리·채점·문법 검사는 인터넷 없이 동작한다(모델 다운로드 후). 대화·레슨 AI는 기본으로 무료 DeepSeek V4.1 Flash(OpenCode, 인터넷 필요)를 쓰고, 쓸 수 없으면 오프라인 로컬 모델(Ollama qwen3:8b)이 자동으로 대신한다(아래 "AI 엔진").

```
app/
├── API.md                 ← 이 문서 (백엔드와 Godot가 모두 따르는 계약)
├── backend/               ← 파이썬 로컬 서버
│   ├── curriculum.json    ← 커리큘럼 데이터 (영어/일본어 12개월, 이미 있음)
│   ├── build_curriculum.py← 커리큘럼 md → json 변환기 (이미 있음)
│   ├── server.py          ← FastAPI 앱, 엔드포인트
│   ├── config.json        ← 포트·모델 이름 설정
│   ├── requirements.txt
│   ├── setup.ps1          ← venv 생성, 패키지·모델 설치 (재실행 안전)
│   ├── run_backend.bat    ← 서버 단독 실행
│   └── .venv/, models/    ← 설치물 (git 대상 아님)
└── godot/                 ← Godot 4.6 프로젝트 (화면)
```

## 공통

- 주소: `http://127.0.0.1:8770` (config.json의 `port`)
- 모든 요청·응답 본문은 JSON(UTF-8). 예외: `/tts`의 응답은 WAV 바이너리.
- 오디오 업로드는 JSON 안에 `audio_b64`(WAV 파일 전체를 base64)로 보낸다. WAV는 어떤 샘플레이트·채널이어도 된다(서버가 16kHz 모노로 변환).
- `lang`은 `"en"` 또는 `"ja"`.
- 실패 시 HTTP 4xx/5xx와 `{"error": "한국어로 된 사용자용 설명"}`.
- 한국어 문자열 필드(`ko`, `why`, `summary`, `tips_ko` 등)는 화면에 그대로 보여줄 수 있는 한국어.

## 엔드포인트

### GET /health
`{"ok": true, "stt": bool, "tts": {"en": bool, "ja": bool}, "llm": bool, "llm_model": "qwen3:8b", "llm_provider": "opencode"|"ollama", "score": bool, "phoneme": bool, "tatoeba": bool, "grammar": bool, "llm_fallback": {"active": bool, "until": "ISO 8601"|null, "reason": "한국어 안내"}}`
각 기능이 준비됐는지. Godot는 시작할 때 이것으로 서버 기동을 확인한다.
- `grammar`: LanguageTool(오프라인 문법 검사기)과 Java 17+가 있어 쓸 수 있는지.
- `llm_fallback.active`: 선택한 엔진(무료 DeepSeek)이 한도·권한 문제로 막혀서 `until`까지 로컬 AI가 대신 답하는 중인지. `reason`은 화면에 그대로 보여 줄 한국어 (예: "DeepSeek V4.1 Flash (무료 · OpenCode) 사용 한도에 도달해서 23:21까지 로컬 AI로 답해요."). 로컬 AI(Ollama)도 연결되지 않으면 `active`는 true이지만 `reason`은 "AI 엔진을 쓸 수 없어요: …"로 시작한다.

### AI 엔진 (GET/POST /llm, POST /llm/test)
엔진은 두 가지다. `opencode`(기본): 무료 DeepSeek V4.1 Flash를 OpenCode의 로컬 서버(`opencode serve`, 서버가 필요할 때 자식 프로세스로 띄움)로 쓴다. 로그인은 `opencode auth login`. `ollama`: 오프라인 로컬 qwen3:8b.
- `GET /llm` → `{"provider", "options": [{"id": "opencode"|"ollama", "label", "available"}], "llm_fallback": {...}, "openai_api": {...}}`
- `POST /llm` `{"provider": "opencode"|"ollama"}` → GET /llm과 같은 응답 (config.json에 저장)
- `POST /llm/test` → `{"ok", "provider", "seconds", "reply"}` (선택한 엔진 자체를 시험, 로컬 대체 없이)
- 자동 대체: 무료 모델이 한도(429 등)·권한(무료 모델 거절)·서버 혼잡으로 실패하면 그 요청을 로컬 모델로 다시 처리하고, 오류 문구의 재시도 시각(없으면 30분, 혼잡은 5분)까지 이후 요청도 바로 로컬로 보낸다. 응답 형식은 같다.
- 대화(`/chat`)는 `conv_id`마다 OpenCode 세션 하나를 유지해 새 메시지만 보낸다(한 턴 약 3~4초).
- (고급) `"openai_api"`: OpenAI 호환 HTTP API(DeepSeek 공식, OpenRouter, Gemini 등) + API 키. 화면 선택지에는 없고 `POST /llm {"provider": "openai_api", "preset", "model", "api_key"}`로만 고른다. 키는 사용자가 앱에 직접 입력한 것만 `backend/secrets.json`에 저장하고(`key_source`는 항상 `"secret"`), 응답·로그에 나오지 않는다. `GET /llm`의 `openai_api.has_key`도 `secrets.json`만 보고 정한다. **OpenCode 로그인 키(`auth.json`)는 이 앱이 절대 읽지 않는다** (`key_source: "opencode"`는 400). `GET /llm/models?preset=` → `{"models": [{"id", "free"}]}`.
- OpenCode 작업 폴더: `%LOCALAPPDATA%\hoehwa-practice\opencode\work` (앱 폴더·git 저장소 밖; 에이전트 설정 `opencode.json`만 있다). OpenCode 프로젝트 범위에 앱 파일이 들어가지 않는다.
- AI가 하나도 없을 때(OpenCode 없음·실패 **그리고** Ollama 꺼짐): `/fix`와 대화 교정은 오류 없이 HTTP 200으로 LanguageTool 결과만 돌려준다 — LanguageTool이 못 찾으면 `{"fix": "", "fix_ko": ""}`. 이때 `/health`·`GET /llm`의 `llm_fallback.reason`은 "AI 엔진을 쓸 수 없어요: …"로 시작하고 로컬 AI가 답한다고 말하지 않는다.
- 문법 검사(LanguageTool) 신뢰 규칙: 학습자 문장에 자주 틀리는 규칙(대명사 격 바꾸기 `CONFUSION_OF_ME_I` 등)과 고유명사(대문자 단어)를 바꾸는 제안은 쓰지 않고, 고친 문장을 LanguageTool이 다시 검사해 여전히 문제가 있으면 고침을 내놓지 않는다(AI가 있으면 AI가 원문을 직접 본다). `fix_ko`는 규칙 종류(문법/철자/헷갈리는 단어)에 맞게 쓴다.
- 같은 요청 재사용: 교정(`/fix`), 번역, 레슨 정답 검사 같은 결정적 작업의 AI 결과는 `backend/cache/llm_cache.sqlite`에 (작업, 엔진, 모델, 스키마, 메시지)로 캐시한다. 대화·피드백은 캐시하지 않는다.

### GET /curriculum
`curriculum.json` 내용 그대로. 구조: `{"en": Lang, "ja": Lang}`,
`Lang.months[]` = `{n, ym, title, goal, content:[{k,v}], weeks:[{w,topic,act}], missions:[str], checks:[str]}`,
`Lang.roadmap` = `{header:[...], rows:[[단계, 기간, 핵심 목표, 도달 수준], ...]}`.
텍스트에 마크다운 `**굵게**`가 섞여 있을 수 있다.

### POST /tts → audio/wav
요청 `{"text": str, "lang": "en"|"ja", "speed": 1.0, "voice": "af_heart"}` (speed 0.6~1.3, voice는 선택)
응답: 16-bit PCM 모노 WAV(24kHz) 바이너리. 같은 (text, lang, speed, voice)는 서버가 디스크에 캐시한다(`backend/cache/tts`, 300 MB 상한, 가장 오래 안 쓴 것부터 삭제 · `config.json`의 `tts.cache_max_mb`).
같은 키로 동시에 들어온 요청은 합성을 한 번만 하고 결과를 나눠 쓴다. `voice`가 없거나 이 PC에 없는 목소리면 기본 목소리(`af_heart` / `jf_alpha`)로 읽는다.

### GET /tts/voices
`{"voices": {"en": [{"id": "af_heart", "name": "Heart", "gender": "female"|"male", "default": true}], "ja": [...]}, "default": {"en": "af_heart", "ja": "jf_alpha"}}`
이 PC의 `models/hf`(Kokoro 스냅샷 `voices/*.pt`)에 이미 있는 목소리만 나온다(영어 `a*`, 일본어 `j*`). 새로 내려받지 않는다.

`/health`에 `"tts_device": "cpu"|"cuda"|""`(Kokoro를 올린 장치, 아직 안 올렸으면 빈 문자열)가 붙는다. `config.json`의 `tts.device`가 `auto`면 torch에 CUDA가 있고 남는 VRAM이 1.5 GB 이상일 때만 GPU를 쓴다.

### POST /stt
요청 `{"lang": "en"|"ja", "audio_b64": str}`
응답 `{"text": str, "words": [{"w": str, "p": 0~1, "start": 초, "end": 초}], "duration": 초}`

### POST /score  (발음 채점)
요청 `{"lang", "target": str, "reading": str(일본어 히라가나 읽기, 없으면 ""), "audio_b64": str}`
응답:
```json
{
  "transcript": "들린 문장",
  "score": 0-100,            // 종합
  "accuracy": 0-100,         // 목표 단어(일본어는 가나 음절)를 얼마나 맞게 말했나
  "clarity": 0-100,          // 맞게 들린 부분의 음성 인식 확신도 평균 (또렷함)
  "fluency": 0-100,          // 말 속도와 긴 멈춤
  "units": [{"t": "목표 단위(영어 단어 / 일본어 가나)", "ok": bool, "conf": 0-1, "heard": "대신 들린 것 또는 null"}],
  "tips_ko": ["'rice'가 'lice'로 들렸어요. r은 혀끝을 입천장에 대지 않아요.", "..."]
}
```

#### /score: 음소 단위 결과 (영어만, 일본어는 아직 없음)
`lang == "en"`이고 음소 인식기(`/health`의 `phoneme`)가 준비됐으면 각 `units[i]`에 `ph`가 붙는다. 기존 필드는 그대로이고, `ph`가 없으면 화면은 예전처럼 동작한다.
```json
{"t": "think", "ok": false, "conf": 0.3, "heard": "sink",
 "ph": [{"p": "θ", "ok": false, "conf": 0.01, "heard": "s"},   // p = 기대한 IPA, heard = 대신 들린 IPA(없으면 null)
        {"p": "ɪ", "ok": true, "conf": 0.99, "heard": null}, {"p": "ŋ", ...}, {"p": "k", ...}]}
```
- `p`는 espeak IPA(단어별). `conf` 0~1은 정렬된 구간에서 기대 음소의 최대 사후확률 대비 경쟁 음소 비율. `heard`는 `ok:false`이고 경쟁 음소 확률이 0.2 이상일 때만.
- 끝에 모음이 붙으면(milk→밀크) `heard`는 `"k" + 모음`(예 `"kə"`), 끝 자음이 빠지면 `heard: null`.
- `tips_ko`에는 음소 기반 팁이 최대 2개 앞쪽에 섞인다(전체 3개 이하): 예 `'think'의 th(θ)가 s로 들렸어요. 혀끝을 윗니 사이에 살짝 내밀고 …`.
- 음소 인식기는 wav2vec2-lv-60-espeak-cv-ft(CPU)를 Whisper와 병렬로 돌린다. 한계: 짧은 단독 단어와 학습 데이터가 적은 소리는 틀릴 수 있고, 문맥에 끌려 같은 소리로 들리기도 한다.

### POST /prosody  (억양 그래프, 영어만)
요청 `{"lang": "en", "text": "목표 문장", "reading": "", "audio_b64": "(선택) /score에 보낸 것과 같은 WAV"}`
```json
{"native": {"t": [0..1], "f0": [반음 또는 null], "dur": 초},   // Kokoro 원어민. 화자 중앙값 기준 반음, 무성음 null, 초당 약 50점
 "mine": {"t": [native와 같은 t], "f0": [...], "dur": 초} | null, // 학습자(오디오가 있을 때). 억양 비교용으로 DTW로 원어민 시간축에 맞춘 값
 "similarity": 0-100 | null,   // 정렬 후 윤곽 상관 x 목표 문장을 실제로 말했는지(음소 일치율)
 "accent": null, "mine_accent": null,   // 일본어 악센트용 자리(지금은 항상 null; features.JA_ENABLED=False)
 "match": 0-1,                 // (선택) 목표 음소 중 들린 비율. 0.45 미만이면 다른 문장을 말한 것으로 보고 비교하지 않는다
 "tips_ko": ["문장 끝을 올려 말했어요. 평서문은 끝을 내려요."]}
```
- 피치는 `librosa.pyin`, 정렬은 MFCC+에너지 DTW. 원어민 윤곽은 (text, lang)별로 캐시한다.
- 팁: 문장 끝 올림/내림(`?`로 끝나면 올려야 함), 억양이 너무 평평하거나 과한 경우. 한계: Kokoro는 의문문 끝을 올리지 않아서 끝 억양은 문장 부호를 기준으로 판단하고, 마이크 잡음이 큰 끝부분의 피치 오류로 가끔 "끝을 올렸다"고 잘못 나올 수 있다.

### POST /chat  (원어민 역할 대화, 한 턴)
요청
```json
{"lang": "en", "stage": 1-4, "month": 1-12, "week": 1-4,
 "scenario": {"id": "cafe", "title": "카페에서 주문", "persona": "Emma, a friendly barista in Seattle", "scene": "The learner orders at the counter."},
 "history": [{"role": "ai"|"me", "text": str}]}
```
요청에 선택 필드 `tts_speed`(기본 1.0), `tts_voice`, `presynth`(기본 true; 앱의 자동 읽기가 꺼져 있으면 false)를 붙이면, 서버가 답을 만드는 즉시 백그라운드에서 답의 문장들을 그 속도·목소리로 합성해 TTS 캐시에 넣는다(첫 문장 먼저). 앱이 곧이어 보내는 `/tts`는 캐시 적중이거나 진행 중인 합성에 합류한다. 응답에 `"tts_chunks": [str, ...]`가 붙는다(읽을 조각 순서; 문장 단위, 첫 문장이 길면 첫 쉼표에서 한 번 더 자른다). 앱은 이 조각을 순서대로 `/tts`로 받아 첫 조각이 오는 대로 재생한다.
`history`가 비어 있으면 AI가 먼저 첫 마디를 한다. 마지막이 `me`면 그에 대한 답.
응답 `{"reply": str, "reading": str, "ko": str, "fix": str, "fix_ko": str, "suggest": [str, str]}`
- `reply`: 목표 언어로 1~3문장. `reading`: 일본어면 히라가나 읽기, 영어면 "".
- `fix`/`fix_ko`: 학습자의 마지막 말이 틀렸거나 어색하면 자연스럽게 고친 문장과 한국어 한 줄 설명, 아니면 "".
- `suggest`: 학습자가 다음에 할 만한 말 2개(목표 언어).

### POST /feedback  (대화 종료 후 평가)
요청 `{"lang", "stage", "history": [...]}`
응답
```json
{"scores": {"fluency": 1-5, "accuracy": 1-5, "vocabulary": 1-5},
 "summary": "한국어 2~3문장",
 "corrections": [{"you": str, "better": str, "reading": str, "ko": str, "why": str}],
 "phrases": [{"phrase": str, "reading": str, "ko": str}]}
```

### POST /lesson  (듀오링고식 레슨 생성)
요청 `{"lang", "month": 1-12, "week": 1-4, "stage": 1-4}`
응답 `{"title": "한국어 제목", "exercises": [Exercise, ...]}` (8~10개, 유형 섞임)
Exercise 유형:
- `{"type":"choice","question":str,"options":[4],"answer":idx,"explain":str}`
- `{"type":"fill","sentence":"___ 포함 문장","reading":str,"ko":str,"options":[4],"answer":idx,"explain":str}`
- `{"type":"build","ko":str,"answer":[토큰...],"extra":[오답 토큰 2개],"reading":str,"explain":str}` (일본어 토큰은 의미 덩어리: 毎朝 / 七時に / 起きます)
- `{"type":"listen","audio":"읽어줄 문장","reading":str,"options":[한국어 뜻 4개],"answer":idx,"explain":str}`
- `{"type":"speak","text":"따라 말할 문장","reading":str,"ko":str}` → 앱이 녹음해 `/score`로 채점
서버는 형식이 틀린 문제를 걸러내고, 4개 미만이면 한 번 다시 생성한 뒤에도 부족하면 에러를 돌려준다.

요청에 `"source"`를 붙일 수 있다(생략하면 `"tatoeba"`).
- `"tatoeba"`: AI 없이 규칙으로 만든다. 한국어 번역이 있는 Tatoeba 실제 문장(`backend/data/tatoeba.sqlite`)에서 이달·이번 주 커리큘럼 단어가 든 문장을 단계별 길이(영어 stage1 3~7단어 … stage4 ~14단어, 일본어는 글자 수)로 골라 10문제(choice 2, build 3, listen 2, fill 2, speak 1)를 만든다. 정답이 원문 그대로라서 항상 맞다. 응답에 `"source": "tatoeba"`, `"attribution"`(CC BY 문구, 화면에 표시)이 붙고 각 문제에 `"tatoeba_id"`가 붙는다. 영어 build 토큰에는 문장부호가 없다. `explain`은 `/reading/gloss`로 캐시된 뜻이 있을 때만 채워지고 없으면 `""`. 0.5초 이내. DB가 없으면 `"ai"`로 대신 만든다.
- `"ai"`: 현재 AI 엔진이 만든다(합격 조건 (a)~(f)를 프롬프트에 넣고, 두 번째 호출이 문제마다 조건별 O/X와 정답을 매겨 X가 하나라도 있거나 정답이 다른 문제를 뺀다). 검증을 통과하면 응답에 `"source": "ai"`. 검증 호출이 실패(`answer_check_failed`)하거나 문제를 빠뜨리거나(`answer_check_incomplete`) 통과한 문제가 너무 적으면(`too_few_verified_items`) AI 레슨을 버리고 같은 요청으로 Tatoeba 레슨을 만들어 `"source": "tatoeba"`, `"fallback_reason": "<위 값>"`을 붙인다. Tatoeba도 안 되면 503(한국어 메시지).
- Tatoeba DB가 비었거나 깨졌으면(SQLite로 열리지 않음, 필요한 테이블·행 없음) `/health`의 `tatoeba`가 false, `/examples`는 503, `/lesson`은 AI로 만든다. 500은 내지 않는다.
- 영어 fill 오답 보기는 정답과 바꿔 넣어도 말이 되는 단어(WordNet 동의어·상하위어, 직접 만든 유의어 묶음, Tatoeba 코퍼스의 앞뒤 단어 조합)를 뺀다. 일본어는 한자를 공유하거나 유의어 표에 있는 단어를 뺀다. 본문·보기·오답·추가 타일 모두 차단 단어 목록을 거친다.

### 마이크 녹음 (/mic/*)
Godot는 마이크를 직접 열지 않는다(`audio/driver/enable_input=false`). Godot의 WASAPI 입력이 ZOOM H/F 시리즈 같은 USB 오디오 장치에서 녹음할 때마다 장치를 열고 닫다가 앱 전체를 튕기게 했기 때문이다. 녹음은 서버가 PortAudio(sounddevice, MME 장치)로 한다.
- `GET /mic/devices` → `{"devices": [장치 이름...], "default": 기본 장치 이름}`
- `POST /mic/start` `{"device": 이름 또는 ""(기본)}` → `{"ok": true}` (실패 시 500 + 한국어 error)
- `GET /mic/level` → `{"recording": bool, "level": 0~1, "elapsed": 초}` (녹음 중 약 0.12초마다 호출)
- `POST /mic/stop` → `{"ok": bool, "b64": 16kHz 모노 WAV base64, "duration": 초, "silent": bool}` → 이 b64를 그대로 `/stt`·`/score`에 보낸다
- `POST /mic/cancel` → `{"ok": true}`

### POST /fix  (대화 중 교정, /chat과 따로)
요청 `{"lang", "stage", "text": 학습자 문장, "prev_ai": 직전 AI 말}` → `{"fix": str, "fix_ko": str}`
`/chat`에 `"skip_fix": true`를 보내면 교정을 빼고 답만 빨리 돌려준다. 앱은 답을 먼저 보여 주고 `/fix` 결과를 나중에 붙인다.
- 교정 순서: 먼저 LanguageTool(오프라인, `backend/tools/languagetool`, Java 17+)로 문법·철자를 검사한다(약 0.05초). 고칠 것이 있으면 각 오류의 첫 제안을 겹치지 않게 적용하고(지난 시간 표현이 있으면 과거형 제안을 고름), `fix_ko`는 규칙 종류별 한국어 설명(`'go' → 'went': 어제·지난주처럼 지난 일을 말할 때는 과거형을 써요.`)이다. AI 엔진이 있으면 그 결과를 AI가 한 번 더 자연스럽게 다듬을 수 있다(config `grammar_llm_polish`, 기본 켬). LanguageTool이 아무것도 못 찾으면 예전처럼 AI가 "문법은 맞지만 어색한" 문장을 고친다. AI가 없어도 LanguageTool 결과만으로 답한다.
- 일본어는 LanguageTool 규칙이 적어(예: これわ→これは) 대부분 AI가 고친다.

### 읽기 모드 (/reading/*)
LingQ/Lute 방식: 글을 붙여 넣으면 단어를 눌러 뜻·예문을 보고 복습 목록에 넣는다. 영어 우선, 일본어는 기본 동작.

`POST /reading/analyze` `{"lang", "text"}` (최대 20,000자) →
```json
{"tokens": [{"t": "Running", "w": true, "lemma": "run", "zipf": 4.9, "level": "easy|mid|hard", "s": 0}, {"t": " ", "w": false, "s": 0}, ...],
 "sentences": [{"i": 0, "text": "Running is fun."}],
 "words": [{"lemma": "run", "count": 3, "zipf": 4.9, "level": "easy"}]}
```
- `tokens`를 순서대로 이어 붙이면 원문과 정확히 같다(공백·줄바꿈·문장부호도 `w:false` 토큰). `s`는 그 토큰이 속한 문장 번호.
- `lemma`: 영어는 spaCy 원형(소문자, 고유명사는 원형 그대로), 일본어는 사전형(fugashi/unidic-lite의 lemma, 없으면 표층형).
- `zipf`: 단어 빈도(wordfreq, 0~8, 높을수록 흔함). `level`: zipf ≥ 4.5 easy, 3.5~4.5 mid, < 3.5 hard. 숫자·고유명사·기호는 `w:false`로 둔다.

`POST /reading/gloss` `{"lang", "items": [{"lemma", "sentence"}]}` (최대 30개) →
`{"glosses": [{"lemma", "pos": "동사|명사|…", "ko": "문맥에 맞는 한국어 뜻(짧게)", "ipa": "영어 IPA, 일본어는 히라가나 읽기", "note": "용법 한 줄 또는 \"\""}]}`
현재 AI 엔진(무료 DeepSeek 또는 오프라인 로컬)으로 한 번에 생성한다. 같은 (lang, lemma, sentence)는 서버가 캐시한다.

`GET /examples?lang=en&q=<lemma>&limit=5` →
```json
{"examples": [{"id": 1234, "text": "I run every morning.", "ko": "나는 매일 아침 달린다." | "", "en": "" , "ja": "" ,
               "url": "https://tatoeba.org/sentences/show/1234"}],
 "attribution": "예문 출처: Tatoeba (tatoeba.org) · CC BY 2.0 FR"}
```
- Tatoeba 공개 데이터(문장 텍스트, CC BY 2.0 FR)를 로컬 SQLite(`backend/data/tatoeba.sqlite`)에 넣어 오프라인 검색한다. 음성은 녹음자마다 라이선스가 달라 쓰지 않고 우리 TTS로 읽는다.
- 원형과 활용형 모두로 찾는다(run → runs, ran, running). 짧고(영어 3~14단어) 번역이 있는 문장을 먼저 준다. 번역은 한국어 우선, 없으면 영어↔일본어.
- 화면은 예문 아래에 `attribution`을 항상 표시한다(CC BY 조건).

`/health`에 `"tatoeba": bool` 추가.

## 학습 단계 기준 (stage)
| stage | 영어 | 일본어 |
|---|---|---|
| 1 | CEFR A2, 아주 쉬운 단어·짧은 문장 | JLPT N5, です/ます만, 아주 쉬운 한자 |
| 2 | B1, 일상 표현 | N5~N4, 정중체 기본 |
| 3 | B1+, 흔한 구동사 | N4, 친구 사이면 반말 |
| 4 | B2, 원어민 속도·관용 표현 | N3, 자연스러운 구어 |
월(month) → stage = ceil(month / 3). 시작일 2026-11-01 기준으로 현재 월·주차를 계산한다(웹앱과 같음: 시작일부터 달력 월 단위, 주차 = 그 달 경과일 / 7 + 1, 최대 4).
