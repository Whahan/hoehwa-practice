# 원터치 설치 + Ollama 제거 + 앱 안 AI 로그인 설계

- 작성일: 2026-11-01 / 작성: designer / 상태: **초안 (오케스트레이터 확정 전)**
- 대상: 회화 연습 앱 v1.4.1 (Godot 4.6.3 앱 + Python FastAPI 백엔드, 공개 저장소 Whahan/hoehwa-practice)
- 제안 버전: **1.5.0** (오케스트레이터가 정함)
- 이 문서는 설치·엔진·로그인만 다룬다. 화면 개편은 `docs/home_menu_design.md`(다른 설계자)가 맡는다. 겹치는 파일의 소유권은 4.3절.
- 표기: **(실측)** = 이번 조사에서 직접 실행해 확인 / **(코드)** = 파일·줄 번호 근거 / **(추측)** = 확인 못 함, 작업자가 검증.

---

## 1. 목표와 범위

### 1.1 목표 (사용자 확정 결정)

1. `setup.exe` 하나를 더블클릭하면 질문·입력 없이 진행 막대만 보이고, 끝나면 바탕화면·시작 메뉴 바로가기를 만들고 앱을 실행한다.
2. 설치 폴더는 관리자 권한이 필요 없는 기본값(`%LOCALAPPDATA%\Programs\회화연습`). 경로 95자 제한을 지킨다. 바꾸기는 선택.
3. Ollama(로컬 AI, qwen3:8b)를 완전히 뺀다. AI 엔진은 OpenCode의 무료 DeepSeek 하나.
4. OpenCode 로그인은 설치 중에 하지 않는다. 앱에서 AI 기능을 처음 쓸 때 [AI 연결하기]로 한 번 한다.
5. 로그인 전에도 AI 없는 기능(레슨, 받아쓰기, 발음 채점, 쉐도잉, 노래 외우기 등)은 그대로 동작한다.

### 1.2 하지 않을 것

- 화면 개편(홈·메뉴 구조). 다른 설계자 몫.
- 코드 서명 구입·신청. (안내 문구만. 8절 결정 D10)
- 안드로이드 앱 설치 방식 변경. APK는 지금처럼 따로 배포.
- 앱 안 자동 업데이트 버튼. 업데이트는 지금처럼 `업데이트.bat`(시작 메뉴 바로가기 추가).
- 사용자 PC의 Ollama 프로그램·모델(`~\.ollama`) 삭제. 안내만 한다.
- `openai_api` 엔진(숨은 개발용, API 키 방식) 제거. 그대로 둔다. (결정 D9)
- 모델 용량 줄이기(wav2vec2 1.26GB 지연 다운로드 등). 후속 제안으로만 적는다. (9절)

---

## 2. 조사 결과

### 2.1 지금 설치·업데이트·배포 (코드 근거)

| 항목 | 지금 | 근거 |
|---|---|---|
| 설치 진입 | `설치.bat` → `install.ps1` (PowerShell 콘솔, 11단계) | install.ps1:27, 설치.bat |
| 질문 | 엔진 번호 `Select-Engine` | install.ps1:143-155 |
| | Node.js 설치 `Ask-YN` | install.ps1:541 |
| | Java(Temurin 21 JRE) 설치 `Ask-YN` | install.ps1:369-370 |
| | 바탕화면 바로가기 `Ask-YN` | install.ps1:830 |
| | `opencode auth login` 터미널 대화형 + Enter 대기 | install.ps1:576-590 |
| Node.js | 공식 MSI(해시 확인) → 실패 시 winget. **관리자 권한 확인 창(-Verb RunAs)** | install.ps1:218-251 |
| OpenCode 설치 | `npm install -g opencode-ai@1.19.0` | install.ps1:135-137, 559 |
| Ollama | 공식 설치 파일 받기 + `ollama pull qwen3:8b` (약 5GB) | install.ps1:599-662 |
| 경로 제한 | 95자 초과 + LongPaths 꺼짐이면 실패 | install.ps1:408-414 |
| 디스크 | 20GB 미만이면 실패 | install.ps1:416-423 |
| GPU | NVIDIA 감지는 **안내만**. 그래도 nvidia-cublas/cudnn/nvrtc 설치(약 2GB) | install.ps1:433-436, locks/requirements.lock.txt |
| 설치 완료 기록 | `version.txt`, `runtime\.state\installer_version.txt` | install.ps1:866-877 |
| 업데이트 | GitHub `releases/latest` → asset 이름 정규식 `[-_]update[-_]v?<버전>\.zip$` + `SHA256SUMS.txt` | update.ps1:144-175, 244-246 |
| 새로 설치 필요 판정 | `manifest.min_installer_version` > 설치된 installer_version 이면 중단. 메시지가 "설치.bat" 을 말함 | update.ps1:279-284 |
| Ollama 처리 | `$localEngine`, 모델 태그 변경 시 pull, 옛 모델 rm, 실패 시 되돌리기 | update.ps1:118-140, 293-300, 408-438, 476-483, 525-526 |
| 보존 | `backend/config.json`은 병합(사용자 값 우선), `runtime/ backup/ backend/(models\|data\|cache\|logs\|tools)/ secrets.json version.txt` 업데이트가 못 건드림 | update.ps1:87-96, update_helper.py `mergecfg`·`PROTECTED_*` |
| 락 정보 | `lockinfo`가 `ollama` 다이제스트까지 계산 | update_helper.py:96 |
| 제거 | `제거.bat` → `uninstall.ps1`: runtime, models, logs, cache, tools 등 삭제. Ollama·학습 기록은 안 지움 | uninstall.ps1 |
| 빌드 | `build_dist.ps1`: Godot export → staging → `make_zip.py` → `check_zip.py`. `-Release x.y.z`면 update zip + `release_<v>\` (ASCII 이름, SHA256SUMS, latest.json) | build_dist.ps1:30-40, 190-197, 223-236 |
| 배포 | `publish_release.ps1`: 비밀값 검사 → 빌드 → `gh release create`. 자산 `hoehwa-practice-setup-<v>.zip`, `-update-<v>.zip`, SHA256SUMS.txt | publish_release.ps1:158, 209 |
| release.json | `installer_version: 1`, `min_installer_version: 1`, `asset_prefix: hoehwa-practice` | packaging/release.json |
| 크기 | 설치 zip 약 96MB(앱 exe 102MB + 파이썬 임베드 zip + get-pip). 나머지는 설치 중 pip·HF에서 받음 | out\release_1.4.1 |

### 2.2 OpenCode 실측 (로그인·키·모델)

모두 임시 폴더(`scratchpad\oc_probe`)로 `XDG_DATA_HOME`·`XDG_CONFIG_HOME`을 돌려서 실행했다. **실제 로그인 파일(`~\.local\share\opencode\auth.json`)은 읽지도 쓰지도 않았다.** 띄운 `opencode serve` 2개(PID 14540, 27884)는 PID로 종료했다.

| # | 실행 | 결과 |
|---|---|---|
| 1 | `opencode --version` | `1.19.0` |
| 2 | `opencode auth list` (실제 환경) | `OpenCode api` 1건. 이름만 나오고 키는 안 나옴. → 로그인 방식은 **API 키 붙여넣기(type api)** |
| 3 | `opencode auth login --help` | 옵션 `-p/--provider`, `-m/--method` 있음 (선택 화면 건너뛰기) |
| 4 | 로그인 없는 임시 환경에서 `opencode models opencode` | 무료 11개만. **`deepseek-v4.1-flash-free` 없음** (`big-pickle`, `exo-free` 등만) |
| 5 | 실제 환경에서 같은 명령 | 80줄. `opencode/deepseek-v4.1-flash-free` 있음 |
| 6 | 임시 `opencode serve` + 비밀번호(`OPENCODE_SERVER_PASSWORD`)로 `GET /doc` | `PUT /auth/{providerID}` (본문 `{"type":"api","key":"..."}`), `DELETE /auth/{providerID}`, `POST /instance/dispose`, `GET /provider` 있음 |
| 7 | 임시 서버에서 `GET /provider` | **로그인 없이도 `connected: ["opencode"]`**. → `connected`로 로그인 여부를 판단하면 안 된다 |
| 8 | 임시 서버에 가짜 키 `PUT /auth/opencode` → 200 `true`, 임시 `auth.json` 생성. `dispose` 전엔 모델 목록 그대로, `dispose` 후 84개로 바뀜 | 가짜 키도 **저장 시점엔 검증 안 함**. 반영하려면 `dispose` 필요. 가짜 키로는 `deepseek-v4.1-flash-free`가 안 보임 |
| 9 | `DELETE /auth/opencode` → 200 후 `opencode auth list` | 0건 |

결론:
- 무료 DeepSeek은 **로그인(키)이 있어야** 쓸 수 있다 (4·5). 사용자 결정(앱 안 로그인)이 맞다. 무료 모델 목록은 계정·시점에 따라 바뀐다. (추측: 계정별 무료 모델 배정. 확인 못 함)
- 키가 맞는지는 **실제 호출로만** 알 수 있다 (8). 목록에 모델이 보이는지로는 판정 불가.
- 로그인 여부는 `opencode auth list` 출력의 `OpenCode (api|oauth|wellknown)` 줄로 본다(이름만 보임. install.ps1:276-280과 같은 정규식). 앱은 `auth.json`을 **읽지 않는다** (기존 규칙 유지, llm_api.py 머리말).
- 앱이 키를 저장하는 방법은 오직 OpenCode 자신의 `PUT /auth/opencode`다. 키는 OpenCode가 `auth.json`에 적는다. 앱은 쓰기만 하고 읽지 않는다.
- 공식 문서: 키는 `https://opencode.ai/auth` 에서 로그인해 복사한다 (docs 확인).

### 2.3 npm 없이 OpenCode 받기 (Node.js 제거)

`opencode-ai` npm 패키지는 껍데기다. `postinstall.mjs`가 플랫폼별 패키지(`opencode-windows-x64` 또는 AVX2 없는 PC용 `-baseline`)의 `opencode.exe`를 `bin\`에 복사할 뿐이다 (실측: `postinstall.mjs` 읽음). 같은 파일이 GitHub 릴리스에 zip으로 있다 (실측, `gh api`).

| 자산 | 크기 | SHA256 |
|---|---|---|
| `opencode-windows-x64.zip` (v1.19.0) | 62,173,956 B | `17108e9448c4fdad48eb8714c4ed6f5dfc9cf86c2eb8f2ce5d02043fef806eb5` |
| `opencode-windows-x64-baseline.zip` (AVX2 없는 CPU) | 62,173,954 B | `2759ca3449fe946d82da3be43d2e85332127399686aafceaff153b90c3079c56` |

URL: `https://github.com/anomalyco/opencode/releases/download/v1.19.0/<자산 이름>` (저장소 이전 후 주소. `sst/opencode` 주소로도 접근됨). 풀면 약 180MB. 지금 npm 설치본은 345MB.
AVX2 판정은 `IsProcessorFeaturePresent(40)` (opencode의 postinstall과 같은 방법).
zip 안 구조는 확인 못 함. **(추측)** `opencode.exe`가 루트에 있다. 작업자가 풀어서 `opencode.exe`를 찾고, 없으면 실패 처리.

**결정(추천): Node.js·npm·winget을 전부 뺀다.** 장점: 관리자 확인 창 없음, 질문 없음, 다운로드 약 30MB(Node) + 설치 시간 절약, 의존 하나 감소. 단점: OpenCode 업데이트를 우리가 직접 고정 관리(어차피 버전 고정 중). 포터블 Node zip(공식 `node-v*-win-x64.zip` + SHASUMS256)도 가능하지만 의미가 없어 채택하지 않는다.

### 2.4 Java(LanguageTool)

- LanguageTool은 AI 없이 영어·일본어 문법을 고치는 기능이다. 로그인 전에도 문법 교정이 되려면 필요하다 (server.py `correct_learner`: LT 결과만으로 답함).
- 지금은 Java가 없으면 설치 중에 물어본다 (install.ps1:360-375). 질문을 없애려면 **물어보지 않고 항상 포터블 JRE를 앱 폴더에 푼다.**
- 고정값 (실측, Adoptium API 2026-11-01): Temurin `jdk-21.0.13+9` JRE x64 zip, 49,106,397 B, SHA256 `2332c0b4cff6bed722da3567c91d5e47568bcba863fa4945d0a8d6fc76158628`, URL `https://github.com/adoptium/temurin21-binaries/releases/download/jdk-21.0.13%2B9/OpenJDK21U-jre_x64_windows_hotspot_21.0.13_9.zip`.
- 풀면 `backend\tools\<최상위 폴더>\bin\java.exe`. `grammar.py`가 이미 `backend\tools\jre*|jdk*`를 찾는다 (install.ps1:301-306와 같은 규칙). 최상위 폴더 이름은 **(추측)** `jdk-21.0.13+9-jre`.
- 대안 비교:

| 안 | 용량 | 장점 | 단점 |
|---|---|---|---|
| A. 항상 JRE 포함 (추천) | +약 180MB 설치, +49MB 다운로드 | 로그인 전에도 문법 교정. 질문 없음 | 용량 |
| B. LanguageTool 빼기 | -약 600MB (LT 400MB + JRE) | 가장 작음 | 로그인 전 문법 교정이 없어지고, 로그인 후에도 AI 호출이 늘어남. 기능 후퇴 |
| C. 시스템 Java 있으면 쓰고 없으면 건너뜀 | 0 | 가장 간단 | PC마다 기능이 다름. 원터치 취지와 맞지 않음 |

### 2.5 Ollama 제거 범위 (코드 근거)

| 영역 | 파일·줄 | 처리 |
|---|---|---|
| 백엔드 기본 설정 | server.py:128-140 (`llm_model`, `ollama_url`, `keep_alive`, `num_ctx`) | 네 키 삭제 |
| 명령줄 | server.py:221-230 (`--ollama-url`, `--llm-model`) | 삭제 |
| 엔진 목록 | server.py:1571-1572 `ENGINES`, `ENGINE_LABEL` | `ollama` 삭제. 남는 값: `opencode`, `openai_api`(개발용) |
| 로컬 모델 도우미 | server.py:1549-1566 `llm_available` 의 ollama 분기, 1619-1690 `local_llm_*`, `remote_route_active`, `on_remote_error`의 로컬 재시도 | 삭제·단순화 |
| 호출 | server.py:1730-1796 `ollama_json`, `_ollama_json_once`, `_ollama_chat_json` | 로컬 분기 삭제. 이름 변경은 작업 G |
| 실행·예열 | server.py:2623-2651 `ensure_ollama`, 2654-2675 `_warmup`의 Ollama 예열, 2801-2802 | 삭제 |
| 엔진 API | server.py:2732-2820 `/llm` `/llm/test`, 2853-2854 `_ollama_installed`, 2857-2879 `/health`·`_fallback_status` | 새 계약(3.4절)으로 교체 |
| 한도 대체 | llm_fallback.py (머리말, 120줄 "로컬 AI(Ollama)") | 대체 로직 삭제. **한도 시각 계산·분류·상태 표시는 유지** |
| 캐시 | llm_cache.py:4 (주석) | 주석만. 캐시 키에 provider가 들어 있어 옛 `ollama` 항목은 자연히 안 쓰임 |
| 호출자 | missions.py:8,31,379 · reading.py:5,29,456 · song.py:24,195,1662,1731-1757 · song_enrich.py:14,19,25,282 | `ollama_json` 이름의 공용 도우미. **제공자와 무관**. 작업 G에서 `llm_json`으로 바꿈 (결정 D11) |
| 시험 | test_offline_ai.py(8곳), test_pron(8), test_song_identify(8), test_fixcore(7), test_missions(5), test_song(5), test_lesson_rules(4), test_song_enrich(3), test_backend(1), test_lan(1) | 같은 시점에 수정 |
| 개발 설치 | backend/setup.ps1:3,76,86-108 (Ollama pull) | 해당 단계 삭제 |
| 배포 설정 | packaging/defaults/config.default.json (`llm_model`, `ollama_url`, `keep_alive`, `num_ctx`) | 삭제 (check_zip이 이 파일과 byte 단위로 비교하므로 같이 바뀜) |
| 락 | packaging/make_locks.py:211-226,288-295 `ollama_info` → models.lock.json `ollama` | 삭제 |
| 설치·업데이트 | install.ps1 109-132,138-141,143-200,459-462,599-662,786,819,881 · update.ps1 118-140,199-201,293-300,408-438,476-483,525-526 · update_helper.py:96 | 삭제 |
| Godot | backend.gd:48-71 · settings_view.gd:739,759-848 · song_view.gd:245-250 · 시험(flow_test 41, live_test 44, song_view_test) | 4.3·작업 C |
| 문서 | README(42,58-59,72,77,143,155,186), INSTALL.md, 사용법.txt, API.md(3,32-46,507) | 작업 H |

**기존 사용자 이전 (engine=local)**: 업데이트하면 `config.json`에 `llm_provider: "ollama"`가 남는다(병합이 사용자 값을 지킴). 새 백엔드가 시작할 때 `llm_config.migrate()`가 고친다 (3.4.5절). 사용자 PC의 Ollama 프로그램과 모델은 **지우지 않는다**. 앱이 한 번 안내한다: "오프라인 로컬 AI는 더 이상 쓰지 않아요. 무료 DeepSeek으로 바꿨어요. 쓰려면 [AI 연결하기]. 디스크(약 5GB)를 비우려면 Windows 설정 > 앱에서 Ollama를 지우세요."

### 2.6 setup.exe 만드는 방법 비교

| 방식 | 새로 받을 것 | 진행 막대 | 질문 없이 | 제거 프로그램·앱 목록 등록 | 한국어 | 평가 |
|---|---|---|---|---|---|---|
| **Inno Setup 6.7.4** (추천) | 개발 PC에 1개 (아래) | 내장. `[Code]`로 우리 진행률 연결 | 쓰는 페이지를 `Disable*Page=yes`로 끔 | **자동** (unins000.exe + 앱 목록) | 공식 `Korean.isl` 있음 (실측: GitHub 6.7.4·7.1.1 둘 다 `Files/Languages/Korean.isl`) | 가장 적합 |
| Inno Setup 7.1.1 | 같음 | 같음 | 같음 | 같음 | 있음 | 최신(2026-10-28). 문법 변화 확인 안 함. 6.7.4가 안전 |
| IExpress (윈도우 내장) | 없음 | 없음(압축 해제 표시뿐). WinForms 창을 PowerShell로 따로 만들어야 함 | 가능 | **없음** (직접 구현) | 직접 | 폴더 구조 못 담아 zip을 또 넣어야 하고, 백신이 의심하는 편이라 비추천 |
| NSIS | 있음 | 가능 | 가능 | 스크립트 직접 | 있음 | 가능하지만 스크립트 언어가 불편. 이점 없음 |
| 직접 만든 C# 런처 (윈도우 내장 `csc.exe`) | 없음 | 직접 | 가능 | **직접 구현 전부** | 직접 | 위험·작업량 큼 |
| WiX/MSI | .NET SDK 등 | 있음 | 가능 | 있음 | 있음 | 사용자 단위(무관리자) 설치가 번거롭고 과함 |

**Inno Setup 6.7.4 고정**
- 개발 PC에는 없음 (실측: `Program Files (x86)\Inno Setup 6` 없음). `winget`·`csc.exe`·`iexpress.exe`는 있음.
- 파일 `innosetup-6.7.4.exe`, 10,604,576 B, SHA256 `a549929319f9120716677c685535ca4671e4b937b5fdc87e2585f32d8eb30e8c` (GitHub 릴리스 `is-6_7_4`, 2026-10-28, 실측 `gh api`).
- 출처: `https://github.com/jrsoftware/issrc/releases/download/is-6_7_4/innosetup-6.7.4.exe` (공식 jrsoftware.org/isdl.php 에도 같은 릴리스. 설치 파일 서명 있음).
- 설치 위치: `%LOCALAPPDATA%\hoehwa-practice\buildtools\innosetup-6.7.4\` (저장소 밖. 기존 `%LOCALAPPDATA%\hoehwa-practice\keys`와 같은 부모). 관리자 권한 없이 `/VERYSILENT /SUPPRESSMSGBOXES /CURRENTUSER /DIR=...`. (`/CURRENTUSER` 지원은 **추측**, 작업자 확인)
- 해시·URL은 저장소의 `packaging/tools.lock.json`에 적고, `packaging/get_build_tools.ps1`가 받아서 SHA256을 대조한다(다르면 설치 안 함).

**Inno가 하는 일 / 하지 않는 일**
- 하는 일: 파일 풀기(LZMA, 약 85~95MB 예상), 바로가기, 앱 목록 등록, 제거 프로그램, 진행 막대, 실행 중 프로세스 정리 호출, 마지막에 앱 실행.
- 하지 않는 일: pip·모델·LT 등 큰 다운로드. 이것은 `install.ps1`이 한다. Inno는 그 진행률 파일만 읽어 막대에 보여 준다.
- `[Setup]` 핵심: `PrivilegesRequired=lowest`, `DefaultDirName={autopf}\회화연습` (비관리자일 때 `{localappdata}\Programs` 아래, **추측**: 문서 확인 필요), `DisableWelcomePage/DirPage/ProgramGroupPage/ReadyPage/FinishedPage=yes`, `ShowLanguageDialog=no`, `SetupMutex`, `OutputBaseFilename=hoehwa-practice-setup`, `Compression=lzma2/max`, 한국어 메시지, `.iss`는 UTF-8 BOM.

### 2.7 서명 없는 exe와 SmartScreen

- 서명이 없으면 브라우저가 "흔히 다운로드되지 않는 파일"이라 하고, 실행하면 Windows가 "PC를 보호했습니다"를 띄울 수 있다. 막을 수 없다. 서명하면 줄지만 평판이 쌓일 때까지 경고가 남을 수 있다 (일반 지식, 확인 못 함).
- **지금은 안내 문구로 대응**한다 (README·INSTALL·릴리스 본문에 같은 글):
  > Windows가 "Windows의 PC 보호" 창을 띄우면 **[추가 정보]** 를 누른 뒤 **[실행]** 을 누르세요. 서명이 없는 새 프로그램이라 나오는 경고예요. 브라우저가 "흔히 다운로드되지 않는 파일"이라고 하면 **[유지]** 를 고르세요. 안심하려면 받은 파일의 해시를 릴리스의 `SHA256SUMS.txt` 와 비교하세요: `certutil -hashfile hoehwa-practice-setup.exe SHA256`
- 서명 후보(후속, 결정 D10): SignPath Foundation의 오픈소스 무료 서명(공개 저장소 + MIT 라이선스는 충족. 현재 조건·소요시간은 **미확인**), 유료 인증서. 지금은 하지 않는다.
- 백신 오탐이 나면 Microsoft Defender 오탐 신고 + 새 버전으로 고친다 (릴리스 삭제 금지).

### 2.8 용량·시간

| 항목 | 지금 | 새 설계 (추정, 측정은 작업 I) |
|---|---|---|
| 설치 후 디스크 | 약 6.8GB (사용자 측정) | NVIDIA PC 약 6.3GB, **NVIDIA 없는 PC 약 4.3GB** |
| 구성 | 파이썬 패키지 3.3GB(그중 nvidia-cudnn 1,096MB + cublas 737MB + nvrtc 179MB = 약 2.0GB, 실측 du), HF 모델 약 2.07GB (lock 합계), LT 약 0.4GB, 앱 exe 0.1GB, OpenCode(npm) 0.35GB, Node | OpenCode 0.18GB, JRE 0.18GB 추가. Node·npm 제거. nvidia 3개 CPU PC에서 생략 |
| 설치 시간 | 약 17분 (사용자 측정) | NVIDIA PC 12~14분, 비 NVIDIA 9~11분 **(추정. 100Mbps 가정)** |
| 필요 여유 공간 | 20GB | 설치 드라이브 14GB(NVIDIA) / 10GB(비NVIDIA) + 임시 폴더 드라이브 3GB |
| 질문·관리자 창 | 4~5번 | 0번 |

줄이는 방법 (이번 범위):
1. NVIDIA 그래픽카드가 없으면 `nvidia-cublas-cu12`, `nvidia-cudnn-cu12`, `nvidia-cuda-nvrtc-cu12`를 설치하지 않는다. Whisper는 이미 CUDA 실패 시 CPU로 내려간다 (server.py:300-325). 설치 때 `stt.device = "cpu"`, `compute_type = "int8"`로 적어 첫 실행 지연을 없앤다.
2. Node.js·npm 제거(약 0.2GB, 다운로드 30MB, 관리자 창 제거).
3. 디스크 요구량을 실제에 맞게 낮춤.

후속(이번 범위 밖): wav2vec2 음소 모델 1.26GB를 처음 쓸 때 받기, 모델 다운로드를 pip와 병렬화, fp16 변환.

### 2.9 업데이트가 새 형식을 찾는 방법, 기존 zip 설치본(1.4.x)에서 넘어오는 길

핵심 사실: **1.4.x 사용자의 PC에서 도는 것은 옛 `update.ps1`** 이다. 새 update zip을 받아 옛 스크립트가 적용한다. 적용 중 옛 스크립트가 부르는 `vendor\update_helper.py`는 새 파일로 바뀌어 있다 (update.ps1:282-286, 372, 382).

- **자산 이름 호환**: 옛 스크립트는 `…-update-<버전>.zip`과 `SHA256SUMS.txt`만 찾는다. 새 릴리스에도 그대로 둔다. setup 자산은 새 이름 `hoehwa-practice-setup.exe` (버전 없는 고정 이름 → `releases/latest/download/hoehwa-practice-setup.exe` 영구 링크가 됨. GitHub가 한글 자산 이름을 바꾸므로 ASCII). 옛 `…-setup-<v>.zip`은 더 올리지 않는다 (결정 D5).
- **`min_installer_version`은 올리지 않는다 (1 유지).** 올리면 옛 스크립트가 "설치.bat을 실행하라"고 안내하며 업데이트가 막힌다 (update.ps1:283). 새 레이아웃으로 못 옮기는 문제는 아래 "기존 설치 폴더에서도 동작" 설계로 푼다.
- `installer_version`은 **1 → 2** (새 스크립트 능력 표시용). 옛 스크립트는 업데이트 성공 시 이 값을 적는다 (update.ps1:445).
- **기존 설치 폴더에서도 동작** (zip 설치 폴더에 새 앱이 업데이트로 들어옴):
  - OpenCode: 찾는 순서 `backend\tools\opencode\opencode.exe` → `%APPDATA%\npm\node_modules\opencode-ai\bin\opencode.exe` (옛 방식) → PATH. 옛 설치본은 npm 것을 그대로 쓴다. 옛 로그인(`auth.json`)도 그대로 → **다시 로그인하지 않는다**.
  - engine=local이라 OpenCode가 없는 사용자: 앱에서 [AI 연결하기]를 누르면 먼저 구성 요소(opencode.exe 62MB)를 받는다 (`POST /llm/install`, 3.4.3절). `vendor\install_tools.py`와 `vendor\tools.lock.json`이 update zip에 들어 있어서 가능하다.
  - Java 없는 기존 사용자: 지금과 같음(문법 검사 꺼짐). 후속으로 점검/복구 메뉴.
  - 옛 스크립트가 새 `models.lock.json`(`ollama` 키 없음)을 읽어도 안전: `.ollama.model`이 null → 모델 교체 분기를 건너뜀 (update.ps1:410-411). 새 `lockinfo`에 `ollama` 키가 없으므로 `$chg.ollama` 분기도 건너뜀 (436).
  - `update_helper.py`의 명령줄(`verify`, `lockinfo`, `dirsize`, `mergecfg`, `setcfg`, `pipsync`, `prunehf`, `refsave`, `refrestore`, `languagetool`) 이름·인자는 **바꾸지 않는다.** (옛 스크립트가 부름)
- 학습 기록: `%APPDATA%\Godot\app_userdata\회화 연습\` (prefs.json, progress.json). 설치·업데이트·제거 어디서도 지우지 않는다. 기존 폴더에서 새 setup.exe를 실행해도 같은 경로를 쓰므로 그대로 이어진다. (새 setup.exe는 새 폴더에 따로 설치된다. 옛 폴더는 `제거.bat`로 지움. 8절 결정 D12)

---

## 3. 확정 설계

### 3.1 구조

```
hoehwa-practice-setup.exe  (Inno Setup 6.7.4, 비관리자, 약 90MB)
   │ 1) 파일 풀기 → {app} = %LOCALAPPDATA%\Programs\회화연습   (경로>80자면 C:\회화연습)
   │ 2) 앱 목록 등록, 시작 메뉴·바탕화면 바로가기, unins000.exe
   │ 3) install.ps1 -ProgressFile <임시>\hoehwa-setup-progress.json   (숨김 PowerShell)
   │      └ 1 점검 2 파이썬 3 pip 4 패키지 5 OpenCode 6 JRE 7 모델 8 prefetch 9 LanguageTool 10 설정 11 동작 확인
   │      └ 큰 다운로드는 vendor\install_tools.py (OpenCode, JRE) / pip / install_models.py
   │ 4) 진행 파일을 0.5초마다 읽어 Inno 진행 막대·문구 갱신
   └ 5) 성공이면 회화연습.exe 실행, 끝

{app}\
  회화연습.exe, version.txt, manifest.json, release.json, install.ps1, update.ps1, uninstall.ps1, *.bat, install.log
  backend\ (py, config.json, tools\opencode\opencode.exe, tools\jdk-*\, tools\languagetool\, models\hf\ …)
  runtime\python\, runtime\.state\ (단계 표시 파일, installer_version.txt=2, gpu.txt)
  vendor\ (python zip, get-pip.py, *.lock*, install_models.py, install_tools.py, tools.lock.json, update_helper.py, check_env.py)
  unins000.exe, unins000.dat   (Inno가 만듦)

%APPDATA%\Godot\app_userdata\회화 연습\   학습 기록 (그대로)
%USERPROFILE%\.local\share\opencode\auth.json   OpenCode 로그인 (OpenCode가 관리, 앱은 안 읽음)
%LOCALAPPDATA%\hoehwa-practice\opencode\work\   opencode serve 작업 폴더 (지금 그대로)
```

### 3.2 단계별 흐름

**① 설치 (setup.exe 더블클릭)**
1. (브라우저에서 받았다면) SmartScreen 안내(2.7)를 따라 실행.
2. 창이 하나 뜬다. 제목 "회화 연습 설치". 질문 없음. 진행 막대 + 한 줄 문구("파이썬 패키지 설치 중 (4/11)").
3. 이미 실행 중인 앱·서버가 있으면 `stop_app.ps1`이 **실행 파일 경로가 {app} 아래인 프로세스만 PID로** 끈다 (이름으로 끄지 않음).
4. 파일 풀기 → 바로가기(바탕화면 "회화 연습", 시작 메뉴 폴더 "회화 연습": 앱 / 업데이트 / 제거).
5. `install.ps1`이 11단계를 진행. 끊기면 다시 setup.exe를 실행하면 이어서 한다 (`runtime\.state\NN-*.ok`).
6. 성공: 막대 100% → 앱 실행 → setup 종료. 실패: 한국어 한 줄 원인 + `install.log` 위치 + "다시 실행하면 이어서 해요". 이미 풀린 파일은 지우지 않는다 (검증 필요, 5.F).
7. 폴더 바꾸기: `setup.exe /DIR="D:\회화연습"` (문서에만 적음. 화면에는 묻지 않음. 결정 D7).

**② 첫 실행 (로그인 전)**
1. 앱이 백엔드를 켠다 (지금과 같음, "AI 엔진 준비 중…" 15~60초).
2. `/health`: `llm_state = "not_connected"`. 위쪽에 조용한 안내줄: "AI 대화·AI 레슨은 연결이 필요해요. [AI 연결하기]". 팝업으로 막지 않는다.
3. AI 없는 기능은 정상. AI가 필요한 기능을 처음 누르면 백엔드가 503 `ai_not_connected`를 돌려주고, 앱이 [AI 연결하기] 시트를 **그 실행에서 한 번만** 자동으로 연다 ("나중에"를 누르면 다시 안 띄움. 안내줄·설정 버튼은 항상 열 수 있음).

AI 필요 여부:

| 기능 | AI 필요 | 로그인 전 동작 |
|---|---|---|
| 레슨 (Tatoeba 규칙 기반) | 아니오 | 정상 |
| AI 레슨(source ai) | 예 | 503 `ai_not_connected` → 시트 |
| 원어민 대화(/chat), 피드백(/feedback) | 예 | 503 → 시트 |
| 교정(/fix) | LT는 아니오, AI 다듬기만 예 | LT 결과만, HTTP 200 (server.py:1940-1960 이미 그렇게 동작) |
| 받아쓰기, 쉐도잉, 약한 소리, 발음 채점, 복습, 기록 | 아니오 | 정상 |
| 미션 규칙 확인 | 아니오 | 정상 |
| 미션 AI 판정(/missions/judge) | 예 | 503 → 시트 |
| 읽기 분석 | 아니오 | 정상 |
| 읽기 단어 뜻(gloss) | **(추측) 예**, 캐시·팩이 있으면 아니오. 작업자가 표로 확인 | 503 또는 부분 결과 |
| 노래 외우기·줄 반복·빈칸·받아쓰기 | 아니오 | 정상 |
| 노래 해석·가사 찾기 AI | 예 | 503 → 시트 |

**③ AI 연결하기 (PC에서만)**
1. 시트: 제목 "AI 연결하기". 본문: "대화·AI 레슨·교정에는 무료 AI(DeepSeek)가 필요해요. 한 번만 연결하면 돼요."
2. 순서 안내: "① [OpenCode 열기]를 눌러 로그인하고 API 키를 복사해요. ② 아래 칸에 붙여 넣고 [연결]을 눌러요."
3. [OpenCode 열기] → 앱이 `OS.shell_open("https://opencode.ai/auth")` (백엔드 호출 아님).
4. 키 칸은 가려진 입력(`LineEdit.secret = true`). [연결] → `POST /llm/connect {"key": "..."}`. 보낸 즉시 칸을 비운다. 성공하면 클립보드가 키와 같을 때 비운다.
5. 백엔드: 형식 검사 → `opencode serve`가 없으면 시작 → `PUT /auth/opencode` → `POST /instance/dispose` → 실제 시험 호출 1회 → 결과.
6. 결과 화면: 성공 "AI가 연결됐어요." / 키 거절 "키가 맞지 않아요. 다시 복사해서 붙여 넣어 주세요." / 한도·바쁨은 "연결은 됐어요(시험은 건너뜀)" / 구성 요소 없음이면 먼저 받기 진행 막대(`/llm/install`).
7. 안내문(시트 아래 작은 글): "키는 이 PC의 OpenCode에만 저장돼요. 이 앱은 키를 저장하거나 기록하지 않아요."
8. 설정 > "AI 연결" 카드: 상태 줄, [AI 연결하기/다시 연결], [연결 시험], [연결 해제]. 해제 확인 문구: "이 PC의 OpenCode 로그인이 지워져요. 터미널에서 쓰던 OpenCode도 로그아웃돼요."
9. 폰: [AI 연결하기]는 폰에서 열지 않는다 (`Platform.is_phone()`). PC에 연결된 폰이 `ai_not_connected`를 받으면 문구만 보인다: "PC의 회화 연습 설정에서 'AI 연결하기'를 눌러 주세요."

**④ 업데이트**: 시작 메뉴 "회화 연습 업데이트" 또는 `업데이트.bat`. 지금과 같다. 달라진 점: Ollama 처리 삭제, `tools` 락이 바뀌면 `install_tools.py` 호출(실패는 경고만), `nvidia-*` 필터. 기존 zip 설치 폴더도 같은 update zip으로 업데이트된다 (2.9).

**⑤ 제거**: Windows 설정 > 앱 > "회화 연습" 또는 시작 메뉴 "회화 연습 제거". Inno 제거 프로그램이 `stop_app.ps1`로 프로세스를 PID로 끄고 `{app}` 전체를 지운다. **학습 기록·OpenCode 로그인·Ollama는 지우지 않는다.** 끝에 "학습 기록은 `%APPDATA%\Godot\app_userdata\회화 연습`에 남아 있어요" 안내. `%LOCALAPPDATA%\hoehwa-practice\opencode\`(작업 폴더)는 지운다. `제거.bat`은 zip 설치 폴더용으로 남기되, `unins000.exe`가 있으면 "설정 > 앱에서 제거하세요"만 출력하고 끝낸다.

### 3.3 설치 스크립트 계약

#### 3.3.1 install.ps1 인자
```
install.ps1 [-ProgressFile <path>] [-Gpu auto|nvidia|cpu] [-DryRun] [-TestPort 8790]
            [-Yes] [-Engine <무시>] [-NoShortcut]   # 옛 인자: 받기만 하고 무시(로그에 "무시됨")
```
- 질문 코드(`Read-Host`, `Ask-YN`, `Select-Engine`) 없음. 입력을 닫아도(`< NUL`) 끝까지 간다.
- 단계 11개 (가중치 합 100):

| N | 키 | 제목 | 가중치 | 비고 |
|---|---|---|---|---|
| 1 | check | 점검 | 3 | OS, 경로 길이(95자), 디스크, 인터넷(pypi, github, huggingface), GPU 감지 → `runtime\.state\gpu.txt`(`nvidia`/`cpu`) |
| 2 | python | 파이썬 풀기 | 2 | 지금과 같음 |
| 3 | pip | pip 준비 | 2 | 지금과 같음 |
| 4 | packages | 파이썬 패키지 | 35 | `gpu.txt = cpu`면 nvidia 3개 줄 제외한 잠금으로 설치·검증 |
| 5 | opencode | OpenCode 받기 | 6 | `install_tools.py --only opencode` |
| 6 | jre | 자바 받기 | 3 | `install_tools.py --only jre` |
| 7 | models | 음성 모델 | 28 | 지금과 같음 (파일 단위로 진행률) |
| 8 | prefetch | 데이터 준비 | 5 | 지금과 같음 |
| 9 | languagetool | 문법 검사기 | 8 | 질문 없음 (Java는 6단계가 보장) |
| 10 | prefs | 설정 | 1 | config.json: `llm_provider=opencode`, 비 NVIDIA면 `stt.device=cpu, compute_type=int8`. 학습 기록 기본값 복사: `%APPDATA%\Godot\app_userdata\회화 연습`의 `prefs.json`·`progress.json`을 **없을 때만** `defaults\`에서 복사(있으면 그대로). 이 복사만이 설치 스크립트가 `%APPDATA%`에 쓰는 유일한 곳이다(D15). 시험은 `HOEHWA_USERDATA_DIR` |
| 11 | verify | 동작 확인 | 7 | 임시 서버 `/health`: ok, stt, tts en/ja, score. **AI(llm)는 요구하지 않음** (로그인 전이 정상) |

- 삭제: Node.js, npm, winget, `opencode auth login`, Ollama 전부, 바탕화면 질문, 엔진 선택, `engine.txt`·`engine-config.ok`·`engine-pending.ok` (있으면 지움).
- 옛 단계 표시 파일 이름(`05-node.ok`, `05-ollama.ok`, `06-llm.ok` 등)은 새 키와 달라 무시한다.
- 완료 시 `version.txt`, `runtime\.state\installer_version.txt`(= manifest의 `installer_version`, 2) 기록.

#### 3.3.2 진행 파일 (`-ProgressFile`)
UTF-8(BOM 없음) JSON 한 객체. 임시 파일에 쓰고 이름 바꾸기로 교체(읽는 쪽이 반쯤 쓴 파일을 보지 않게).
```json
{"v":1,"state":"running","pct":37,"step":4,"steps":11,
 "title":"파이썬 패키지 설치 중","detail":"torch 받는 중 (12/150)",
 "error":"","code":0,"log":"C:\\...\\install.log","warn":"","t":"2026-11-01T14:03:11+09:00"}
```
- `state`: `running` | `done` | `error`. `pct` 0~100 정수, **줄어들지 않는다.** 단계 시작·끝, 긴 단계 안에서는 2초마다 이내 갱신.
- `state=done`은 11단계가 통과하고 `version.txt`를 쓴 뒤에만. 그때 `pct=100`.
- `warn`: 설치를 막지 않는 경고(5·6단계의 OpenCode·JRE 받기 실패 등)를 한국어로 이어 붙인 문자열(300자까지, 넘으면 `…`). 없으면 `""`. 한 번 생기면 끝(`state=done`)까지 지워지지 않는다. 자세한 원인(해시·zip 등)은 `install.log`에만 있다. setup.exe는 `state=done`일 때 `warn`이 비어 있지 않으면 "설치는 끝났어요. 참고해 주세요" 안내를 한 번 보인다. 읽는 쪽이 이 키를 몰라도 된다(`v`는 1 그대로).
- `state=error`: `error`는 한국어 120자 이하 한 줄, `code`는 아래 종료 코드. 키·토큰·비밀 문자열은 넣지 않는다.

종료 코드: 0 성공 / 10 점검 실패(OS·경로·디스크) / 20 인터넷 / 30 받은 파일 해시 불일치 / 40 파이썬 패키지 / 50 모델 / 60 동작 확인 / 1 그 밖.

#### 3.3.3 시험 훅 (`HOEHWA_TEST_MODE=1`일 때만 읽음. 배포본은 무시)
| 환경변수 | 효과 |
|---|---|
| `HOEHWA_SETUP_SIMULATE=1` | 2·3·4·5·6·7·8·9·11단계의 실제 작업 대신 각 1초 대기와 진행 파일 갱신만 한다. 파일 풀기·1·10단계는 실제 수행 |
| `HOEHWA_SETUP_FAIL_STEP=<N>` | N단계에서 실패를 흉내 (그 단계의 종료 코드로 끝) |
| `HOEHWA_USERDATA_DIR=<폴더>` | 10단계의 학습 기록 기본값 복사 위치를 바꿈 (실제 `%APPDATA%` 보호) |
| `HOEHWA_FREEZE_FILE=<파일>` | `check_env.py`가 `pip freeze` 대신 이 파일을 읽음 |
| `HOEHWA_PIP_DRYRUN=1` | (기존) pip 실행 안 함 |
| `HOEHWA_TEST_LONGPATHS=0\|1` | 1단계가 윈도우 긴 경로 지원 값(레지스트리 `LongPathsEnabled`) 대신 이 값을 쓴다 (경로 95자 규칙 시험, D6) |
| `HOEHWA_TEST_FREE_GB=<숫자>` | 1단계가 설치·임시 드라이브의 여유 공간 대신 이 값(GB)을 쓴다 (디스크 부족 시험) |
| `HOEHWA_TEST_NET=skip` | 1단계의 인터넷 점검을 건너뛰고 모두 연결된 것으로 본다 |
| `HOEHWA_TEST_NET_FAIL=<호스트,호스트>` | 점검 대상 호스트(`pypi.org`, `github.com`, `huggingface.co`) 중 이름이 든 것을 안 되는 것으로 본다 (종료 20 시험) |

#### 3.3.4 vendor\tools.lock.json (스키마 1)
```json
{
 "schema": 1,
 "opencode": {
   "version": "1.19.0",
   "dest": "backend/tools/opencode",
   "exe": "opencode.exe",
   "variants": {
     "x64": {"url": "https://github.com/anomalyco/opencode/releases/download/v1.19.0/opencode-windows-x64.zip",
             "sha256": "17108e9448c4fdad48eb8714c4ed6f5dfc9cf86c2eb8f2ce5d02043fef806eb5", "size": 62173956},
     "x64-baseline": {"url": "https://github.com/anomalyco/opencode/releases/download/v1.19.0/opencode-windows-x64-baseline.zip",
             "sha256": "2759ca3449fe946d82da3be43d2e85332127399686aafceaff153b90c3079c56", "size": 62173954}
   }
 },
 "jre": {
   "version": "21.0.13+9",
   "dest": "backend/tools",
   "url": "https://github.com/adoptium/temurin21-binaries/releases/download/jdk-21.0.13%2B9/OpenJDK21U-jre_x64_windows_hotspot_21.0.13_9.zip",
   "sha256": "2332c0b4cff6bed722da3567c91d5e47568bcba863fa4945d0a8d6fc76158628", "size": 49106397
 }
}
```
원본은 `packaging/tools.lock.json`. `build_dist.ps1`이 `vendor\tools.lock.json`으로 복사한다. 이 파일의 해시가 `lockinfo.tools`가 된다.
OpenCode를 올릴 때는 새 URL·sha256으로 이 파일만 바꾼다. (`opencode.autoupdate`는 이미 false, llm_opencode.py `_write_config`.)

#### 3.3.5 vendor\install_tools.py (런타임 도구 설치기, 표준 라이브러리만)
```
python -X utf8 install_tools.py <tools.lock.json> <app_root> [--only opencode|jre|all]
        [--variant auto|x64|x64-baseline] [--progress-file F]
출력 줄: TOOL <이름> OK <버전> <설치 경로> | TOOL <이름> SKIP (이미 같은 버전) | TOOL <이름> FAIL <hash|net|zip|other> <한국어 이유>
마지막 줄: TOOL_RESULT OK | TOOL_RESULT FAIL
종료 코드: 0 OK / 20 인터넷 / 30 해시·크기 불일치 / 1 그 밖
```
동작: ① `https://`만 허용 (`HOEHWA_TEST_MODE=1`이면 `file:///`도). ② `<app_root>\runtime\dl\<이름>.part`로 받기(재시도 3회) ③ **크기와 SHA256 확인이 끝나기 전에는 풀지 않음** ④ 압축 항목 이름 검사(절대 경로, `..`, 드라이브 문자 거부) ⑤ `dest\<이름>.new`에 풀고 `opencode.exe`/`bin\java.exe` 존재 확인 ⑥ 기존 폴더를 치우고 이름 바꾸기 ⑦ `dest\...\tool.json`(`{version, sha256}`) 기록 ⑧ 받은 zip과 `.part`·`.new`는 성공·실패 모두 지움. 이미 같은 버전이면 SKIP. AVX2 없으면 `x64-baseline`. 다운로드 진행률(바이트)을 `--progress-file`에 `{"pct":..}`로 적을 수 있음. 비밀값 없음.

### 3.4 백엔드 계약

#### 3.4.1 새 모듈과 함수 (병렬 작업을 위해 이름을 고정)

`backend/llm_opencode.py` (수정):
```
exe() -> str | None
   # 찾는 순서: (HOEHWA_TEST_HOOKS=1 일 때만) 환경변수 HOEHWA_OPENCODE_EXE
   #  → BASE\tools\opencode\opencode.exe → %APPDATA%\npm\node_modules\opencode-ai\bin\opencode.exe → shutil.which("opencode.exe")
installed() -> bool                      # exe() is not None  (기존 available() 유지)
connected(force: bool = False) -> bool | None
   # `opencode auth list` 실행(최대 10초), ANSI 제거 후 정규식 (?im)\bOpenCode(\s+Zen)?\s+(api|oauth|wellknown)\b
   # 결과를 20초 캐시. 아직 모름 = None. 이 함수는 /health 에서 블로킹하지 않도록 캐시만 읽고,
   # 갱신은 백그라운드 스레드(refresh_async())가 한다.
refresh_async() -> None
state() -> "ready" | "not_connected" | "not_installed"
connect(key: str) -> dict                # {"tested": bool, "seconds": float}. 실패 시 llm_common.LlmError(kind=...)
disconnect() -> None
```
- `call_json`·`chat_json`은 호출 전에 `state()`를 보고 `not_installed`/`not_connected`면 `LlmError(msg, 503, kind="not_installed"|"not_connected")`를 올린다 (서버를 켜지 않고 바로).
- `connect(key)`: 서버가 없으면 `start()` → `PUT /auth/opencode` 본문 `{"type":"api","key":key}` (Basic 인증 헤더는 지금처럼) → `POST /instance/dispose` → 시험 호출 1회(`call_json`, 짧은 프롬프트). 시험이 `auth`로 실패하면 `LlmError(kind="auth")`. `limit`/`overload`로 실패하면 연결은 된 것으로 보고 `tested=False`로 성공.
- 키는 `_Secret`(repr이 값을 숨기는 str, llm_api.py:46-49와 같은 방식)으로만 다룬다.
- `disconnect()`: `DELETE /auth/opencode` + `connected` 캐시 무효화.

`backend/llm_config.py` (새, 무거운 import 없음):
```
migrate(cfg: dict) -> tuple[dict, str]    # (새 cfg, notice). notice = "" | "ollama_removed"
   # llm_provider 가 "ollama" 이거나 알 수 없는 값이면 "opencode" 로, notice="ollama_removed"
   # llm_model, ollama_url, keep_alive, num_ctx 키 삭제 (남아 있어도 서버는 무시)
   # 이미 "llm_migrated_from" 이 있으면 notice 유지
   # cfg["llm_migrated_from"] = "ollama" 를 적는다 (확인 전까지 유지)
```

`backend/llm_routes.py` (새, `missions.py`와 같은 `init()` + `router` 방식. `server.py`는 `include_router`만 함):
```
init(CFG, log, ApiError, local_only, fallback_status, save_config)
POST /llm/connect       POST /llm/disconnect       POST /llm/install      GET /llm/install      POST /llm/notice/ack
```
- 모든 POST는 `lan._local_only(request)`로 막는다 (LAN 청취기 통과 여부, 루프백 주소, Host·Origin, `Content-Type: application/json` 확인. lan.py:1065-1080). 통과 못 하면 403 `{"error": "...", "code": "local_only"|"bad_origin"}`.
- LAN 청취기 허용 목록(`lan.ALLOW`, lan.py:78-95)에 이 경로들을 **넣지 않는다** → 폰은 403 `lan_forbidden`.

#### 3.4.2 오류 형식 (모든 AI 오류 공통)
`ApiError(msg, status, format_error=False, code="")` — `code`가 있으면 응답 본문 `{"error": "<한국어>", "code": "<code>"}` (`server.py` `_api_error` 핸들러가 `code`를 덧붙임. `error` 키는 그대로).

| code | HTTP | 언제 | 한국어 `error` |
|---|---|---|---|
| `ai_not_connected` | 503 | OpenCode 있음, 로그인 없음 | "AI가 아직 연결되지 않았어요. 설정에서 [AI 연결하기]를 눌러 주세요. (폰이면 PC의 회화 연습에서)" |
| `ai_not_installed` | 503 | opencode.exe 없음 | "AI 구성 요소가 없어요. [AI 연결하기]에서 받을 수 있어요." |
| `ai_auth` | 503 | 호출이 키·권한 문제로 거절 | "OpenCode 로그인이 만료됐거나 키가 맞지 않아요. [AI 연결하기]로 다시 연결해 주세요." |
| `ai_limit` | 429 | 사용 한도 | "무료 AI의 사용 한도에 도달했어요. HH:MM 이후 다시 시도해 주세요." |
| `ai_overload` | 502 | 서버 바쁨 | "AI 서버가 바빠요. 잠시 뒤에 다시 시도해 주세요." |
| `bad_key_format` | 400 | `/llm/connect` 키 형식 | "키 형식이 올바르지 않아요. 복사한 키를 그대로 붙여 넣어 주세요." |
| `engine_removed` | 400 | `POST /llm {"provider":"ollama"}` | "오프라인 로컬 AI는 더 이상 지원하지 않아요." |

401은 쓰지 않는다 (Godot `Api.auth_failed`는 PC 토큰 인증용이라 오작동 위험).
기존 형식 오류(JSON 못 읽음 등)는 `ai_format` 없이 지금처럼 502 + `error`만.

#### 3.4.3 엔드포인트

`GET /health` (PC·폰 공용. 키 이름 유지, 값만 바뀜):
```json
{"ok":true,"stt":true,"tts":{"en":true,"ja":true},"tts_device":"cpu","llm":false,"llm_model":"deepseek-v4.1-flash-free",
 "llm_provider":"opencode","llm_state":"not_connected","score":true,"phoneme":true,"tatoeba":true,"grammar":true,
 "llm_fallback":{"active":false,"until":null,"reason":""},"song":true,"song_v":1,"song_identify":true}
```
- `llm`: `llm_state == "ready"` (한도로 막혀 있어도 true. 이유는 `llm_fallback`). **새 키 `llm_state`**: `ready | not_connected | not_installed | blocked`. (`blocked` = 한도·바쁨·키 거절을 최근에 겪어 `until`까지 안내 중. 호출은 막지 않음)
- `llm_fallback`: 이름 유지(옛 클라이언트용). 뜻이 바뀜: `active=true`는 한도·바쁨·거절 안내 중일 때만. `reason`에 "로컬 AI" 같은 말은 쓰지 않는다. 예: "무료 DeepSeek 사용 한도에 도달했어요. 23:21 이후 다시 시도해요."
- 한도에 걸려도 **호출을 막지 않는다** (이전엔 로컬로 돌렸지만 이제 대체가 없다). 호출마다 시도하고, 실패하면 `llm_fallback.mark`로 안내만 갱신. (결정 D14)

`GET /llm`:
```json
{"provider":"opencode","label":"DeepSeek V4.1 Flash (무료 · OpenCode)","state":"not_connected","installed":true,"connected":false,
 "model":"deepseek-v4.1-flash-free","login_url":"https://opencode.ai/auth",
 "options":[{"id":"opencode","label":"DeepSeek V4.1 Flash (무료 · OpenCode)","available":true}],
 "llm_fallback":{"active":false,"until":null,"reason":""},
 "notice":"", "openai_api":{ ...지금 그대로... }}
```
- `notice`: `"ollama_removed"` 또는 `""`. `options`는 호환용으로 항목 1개.

`POST /llm` `{"provider":"opencode"}` → `GET /llm`과 같은 응답. `"openai_api"`는 지금 그대로. `"ollama"`와 그 밖 값 → 400 `engine_removed`/지금의 "알 수 없는 AI 엔진이에요."

`POST /llm/connect` (로컬 전용):
- 요청 `{"key": "<문자열>"}`. 검사: 앞뒤 공백 제거 후 길이 16~256, 공백·제어문자·비ASCII 없음 (**접두어는 강제하지 않음**: 유효한 키 형식을 모름). 아니면 400 `bad_key_format`.
- 200 `{"ok":true,"state":"ready","tested":true,"seconds":2.4}` — 시험 호출 성공.
- 200 `{"ok":true,"state":"ready","tested":false,"note":"한도 또는 서버 사정으로 시험은 건너뛰었어요."}`.
- 503 `ai_auth` — 시험이 키 거절. (키는 OpenCode에 저장된 상태로 둠. 사용자가 다시 붙여 넣으면 덮어씀. [연결 해제]로 지울 수 있음)
- 503 `ai_not_installed` — opencode.exe 없음 (먼저 `/llm/install`).
- 응답·로그·예외 메시지 어디에도 키를 넣지 않는다. (3.5절)

`POST /llm/disconnect` (로컬 전용): 200 `{"ok":true,"state":"not_connected"}`.

`POST /llm/install` (로컬 전용): opencode.exe가 없을 때 백그라운드로 `vendor\install_tools.py --only opencode`를 실행 (`sys.executable`, 자식 프로세스 PID는 서버가 기억하고 끝나면 정리). 이미 실행 중이면 같은 상태를 돌려줌. 200 `{"ok":true,"state":"running"}`.
`GET /llm/install`: `{"state":"idle|running|done|error","pct":0-100,"error":""}`. 한 번에 하나만.
- `vendor\tools.lock.json`·`install_tools.py`가 없으면(개발 PC) `error`: "설치 구성 요소 정보가 없어요".

`POST /llm/notice/ack` (로컬 전용): `llm_migrated_from` 키를 지우고 저장. 200 `{"ok":true}`.

`POST /llm/test`: 그대로. 오류는 위 표 코드로.

#### 3.4.4 config.json 키

| 키 | 변화 |
|---|---|
| `port`, `stt`, `tts`, `lan` | 그대로 |
| `llm_provider` | 값은 `"opencode"`(기본) 또는 개발용 `"openai_api"`. 새 설치 기본 `"opencode"` |
| `opencode.model` | `"deepseek-v4.1-flash-free"` (그대로), `opencode.variant` `"low"` |
| `llm_model`, `ollama_url`, `keep_alive`, `num_ctx` | **삭제** (기본값에서도, 이전 시 사용자 파일에서도) |
| `llm_migrated_from` | 새. `"ollama"`일 때 앱이 한 번 안내. `/llm/notice/ack`가 지움 |
| `openai_api` | 그대로(개발용) |

참고: `mergecfg`는 사용자 값이 이긴다 → 나중에 기본 모델을 바꿔도 기존 설치엔 안 퍼진다 (7절 위험 R7).

#### 3.4.5 시작할 때 이전
`server.py`가 `load_config()` 직후 `llm_config.migrate(CFG)`를 호출한다. 바뀌었고 `--port`(시험 서버)가 아니면 `save_config`. 시험 서버(`--port`)는 메모리에서만 바꾼다 (server.py:215·2799의 기존 규칙).

#### 3.4.6 prefs (Godot, `prefs.json`)
새 키 **없음.** "나중에" 상태는 메모리에만 (실행당 1번 자동 시트).

#### 3.4.7 시험 훅 (백엔드)
`HOEHWA_TEST_HOOKS=1`일 때만: `HOEHWA_OPENCODE_EXE` = 가짜 `opencode` 실행 파일(`.cmd` 래퍼 허용). 기존 `/debug/engine_limit`, `/debug/config` 유지. 가짜 `opencode`(`backend/test_fake_opencode.py`)는 `serve --port --hostname`, `auth list`, Basic 인증, `GET/POST/DELETE /session…`, `POST /session/{id}/message`, `PUT/DELETE /auth/opencode`, `POST /instance/dispose`를 흉내 내고, 받은 키는 SHA256만 기억해 시험이 비교하게 한다 (키 원문은 출력·저장하지 않음).

### 3.5 비밀값 취급 규칙 (검토 기준)

1. 키가 지나가는 길은 **하나**: Godot 키 칸 → `POST /llm/connect` 본문(127.0.0.1) → 백엔드 메모리 → `PUT /auth/opencode`(127.0.0.1, Basic 인증) → OpenCode가 `auth.json`에 저장.
2. 아래 어디에도 키(또는 일부)가 남지 않는다: 서버 로그(`backend\logs\*`), `opencode.log`, 응답 본문(성공·실패 모두), 예외 메시지, `config.json`, `secrets.json`, 환경변수, **명령줄 인자**, Godot 출력·로그, `prefs.json`, 임시 파일.
3. 백엔드는 `auth.json`을 읽지 않는다. 로그인 여부는 `opencode auth list` 출력의 이름 줄만 본다.
4. 예외는 `type(e).__name__`만 로그에 남긴다 (`requests` 예외 문자열에 본문이 섞이지 않게).
5. LAN(폰·8775) 경로에서는 금지: 허용 목록에 없음 + `_local_only` 이중 방어. 폰은 키를 입력할 수 없다.
6. Godot: 키 칸 `secret = true`, [연결]을 누르면 즉시 칸을 비움, 변수에 오래 들고 있지 않음, `print`·`push_error`에 넣지 않음, 클립보드가 키와 같으면 성공 후 비움.
7. 시험은 **고유 표식 키**(`sk-SENTINEL-` + 무작위 24자)를 쓰고, 시험 후 모든 로그·응답·설정·임시 폴더를 훑어 0건임을 확인한다. 실제 OpenCode 로그인·실제 키는 어떤 자동 시험에도 쓰지 않는다.

---

## 4. 작업 분할

담당은 전부 `worker-hard` (Haiku `worker`는 쓰지 않음, CLAUDE.md). 작성 후 새 컨텍스트 `reviewer`. 높음 위험(A, B1, D, E, F, I)은 오케스트레이터가 핵심 명령을 다시 실행.

### 4.1 작업 목록

| ID | 이름 | 담당 | 수정 허용 파일 (소유) | 의존 | 동시 가능 | 위험 |
|---|---|---|---|---|---|---|
| **A** | 도구 잠금·설치기 | worker-hard | `packaging/tools.lock.json`(새), `packaging/get_build_tools.ps1`(새), `packaging/installer/install_tools.py`(새), `packaging/test_install_tools.py`(새) | 없음 | 예 | 높음 |
| **B1** | OpenCode 연결 핵심 | worker-hard | `backend/llm_opencode.py`, `backend/llm_config.py`(새), `backend/llm_routes.py`(새), `backend/test_fake_opencode.py`(새), `backend/test_llm_connect.py`(새) | 없음 (3.4.1 계약) | 예 | 높음(비밀값) |
| **B2** | 서버에서 Ollama 제거 | worker-hard | `backend/server.py`, `backend/llm_fallback.py`, `backend/llm_cache.py`(주석), `backend/llm_common.py`, `backend/test_offline_ai.py`, `backend/test_lan.py`(허용 목록 단언만), `backend/lan_stub_server.py`(필요 시), `backend/setup.ps1`, `packaging/defaults/config.default.json`, `API.md`(LLM·health 절만) | 계약만 (B1 완료 후 통합 확인) | 예(합치기는 B1 → B2) | 보통 |
| **C** | Godot AI 연결 화면 | worker-hard | `godot/scripts/ui/ai_connect_sheet.gd`(새), `godot/scripts/ui/ai_connect_card.gd`(새), `godot/scripts/autoload/backend.gd`(LLM 부분만), `godot/scripts/autoload/api.gd`(신호 1개), `godot/scripts/views/settings_view.gd`(AI 엔진 절만, 4.3), `godot/scripts/main.gd`(3곳, 4.3), `godot/scripts/views/song_view.gd`(245-250), `godot/tests/ai_connect_test.gd/.tscn`(새), 영향받는 기존 시험(`flow_test`, `live_test`, `song_view_test`, `remote_test`의 `llm_provider` 값 등) | B 계약 | 예(통합 시험은 B1+B2 뒤) | 보통 |
| **D** | install.ps1 원터치화 | worker-hard | `packaging/installer/install.ps1`, `packaging/installer/check_env.py`, `packaging/installer/설치.bat`, `packaging/installer/uninstall.ps1`, `packaging/installer/제거.bat`, `packaging/installer/사용법.txt`, `packaging/installer/test_progress_contract.ps1`(새) | A의 CLI 계약 | 예 | 높음 |
| **E** | update.ps1·helper 정리 | worker-hard | `packaging/installer/update.ps1`, `packaging/installer/update_helper.py`, `packaging/make_locks.py`, `packaging/installer/업데이트.bat`(필요 시) | A의 CLI 계약 | 예 | 높음 |
| **F** | setup.exe 만들기 | worker-hard | `packaging/setup/hoehwa.iss`(새), `packaging/setup/stop_app.ps1`(새), `packaging/setup/test_setup.ps1`(새), `packaging/build_dist.ps1`, `packaging/publish_release.ps1`, `packaging/check_zip.py`, `packaging/release.json` | A(Inno 설치), D(진행 파일·시뮬레이션 훅) | **D 병합 뒤** | 높음 |
| **G** | `ollama_json` → `llm_json` | worker-hard | `backend/server.py`, `backend/missions.py`, `backend/reading.py`, `backend/song.py`, `backend/song_enrich.py`, `backend/test_*.py` 중 해당 이름 쓰는 것 | B2 병합 뒤 | F와 동시 가능 | 보통 |
| **H** | 문서 | worker-hard | `README.md`, `INSTALL.md`, `API.md`(나머지), `ROADMAP.md`, `packaging/installer/사용법.txt`(D와 겹치면 H가 마지막) | A~G 뒤 | 아니오 | 낮음 |
| **I** | 통합·실설치 시험 | worker-hard | 코드 수정 금지. 시험 기록만 `scratchpad\w_integration\` | 전부 | 아니오 | 높음 |

### 4.2 실행 순서

```
1차 (동시 6개, 파일이 안 겹침):  A   B1   B2   C   D   E
      병합 순서: A → B1 → B2 → (C, D, E 순서 무관)
2차 (동시 2개):                   F (A·D 뒤)    G (B2 뒤)
3차:                              H
4차:                              I  (실설치 1회 + 전체 회귀)
```
- 동시에 6개가 부담이면 `A,B1,D,E` 먼저, 그다음 `B2,C`.
- 같은 파일을 둘이 고치는 경우: `server.py`(B2 → G 순서, 같은 때 금지), `API.md`(B2 → H 순서), `사용법.txt`(D → H 순서), `settings_view.gd`·`main.gd`·`backend.gd`·`song_view.gd`(화면 개편과 공유, 4.3).
- 병합은 git worktree별로 오케스트레이터가 순서대로 (CLAUDE.md).

### 4.3 화면 개편(`docs/home_menu_design.md`)과의 파일 경계

화면 개편 설계는 이 문서 작성 시점에 `docs/`에 **없다** (확인: 폴더에 파일 없음). 겹칠 수 있는 파일의 소유를 아래로 못 박는다. 화면 개편 쪽은 이 줄 번호 범위를 건드리지 않는다. 합의는 오케스트레이터가 한다 (결정 D13).

| 파일 | 이 작업(C)이 소유 | 화면 개편이 소유 |
|---|---|---|
| `settings_view.gd` | 머리말 변수 `_engine_ob`·`_engine_ids`·`_engine_note`(61-63), `_engine_section`~`_on_engine_test`(759-848)를 **삭제하고 `AiConnectCard` 한 줄로 교체**, `_update_status`의 `llm_name`(739)·힌트(743-746) | 나머지 전부 (섹션 순서·이름·배치) |
| `main.gd` | 연결 안내줄: 배너 버튼 문구/동작(약 430-441), `_on_backend_status`의 `llm_missing` 분기(452·477-479), `Api.ai_not_connected` 연결 1줄 | 나머지 전부 |
| `backend.gd` | 48-71 (`LLM_LABELS`, `llm_provider`, `llm_label`, `llm_missing_text`, `llm_state` 추가) | 나머지 |
| `song_view.gd` | 245-250 (Ollama일 때 "가사가 밖으로 나가지 않아요" 문구 삭제) | 나머지 |
| 새 파일 `ai_connect_sheet.gd`, `ai_connect_card.gd` | 전부 | 화면 개편은 `AiConnectCard.build()`를 **호출만** 한다 (위치는 마음대로) |

---

## 5. 작업별 합격 조건 (O/X)

표기: `$PY` = `D:\Ai\언어\app\backend\.venv\Scripts\python.exe`, `$GODOT` = `C:\Users\rtyu6\Desktop\Godot_v4.6.3-stable_win64.exe\Godot_v4.6.3-stable_win64_console.exe`, `$APP` = `D:\Ai\언어\app`, `$W` = 작업자 임시 폴더 `…\scratchpad\w_<작업명>\`. 모든 명령은 `$APP` 기준.

### 5.0 공통 금지 (모든 작업)

- 자기 소유가 아닌 파일 수정 금지 (4.1 표). 필요하면 보고에 적고 멈춘다.
- 포트 **8770, 8775, 8776**에 접속·바인드 금지. 시험 서버는 **18851~18859**에서 비어 있는지 확인 후 사용 (확인 실패 시 다음 포트). 보고에 "남은 프로세스·열린 포트 없음" 기재.
- 프로세스는 **이름으로 끄지 않는다.** 자기가 시작할 때 받은 PID만 `taskkill /PID <pid> /T /F`.
- 실제 사용자 폴더 쓰기 금지: `%APPDATA%\Godot\app_userdata\회화 연습`, `%USERPROFILE%\.local\share\opencode`, `%USERPROFILE%\.config\opencode`, 바탕화면·시작 메뉴, `HKCU\...\Run`·`Uninstall`(F·I의 **시험용 AppId**만 예외, 끝에 제거). 임시 파일은 `$W` 아래에만.
- 실제 OpenCode 로그인·실제 키·실제 DeepSeek 호출 금지. 시험은 가짜 opencode만 쓴다.
- 비밀값(키, 토큰, auth 파일 내용) 출력·기록 금지. 시험 표식 키 외에는 쓰지 않는다.
- 실제 앱(`회화연습.exe`)을 `%APPDATA%` 학습 기록을 쓰는 상태로 실행 금지 (시험은 `--api` 시험 서버나 `HOEHWA_USERDATA_DIR` 사용).
- 릴리스·태그·`git push` 금지 (오케스트레이터 몫).
- 보고 맨 앞에 합격 조건 표 (항목 / O·X·미검증 / 근거 명령과 출력 요약). 실행하지 않은 것은 "미검증".
- 검사기는 **일부러 틀린 입력**으로도 실패하는지 확인한다. 통과만 보인 검사기는 믿지 않는다.

### A. 도구 잠금·설치기

| # | 조건 | 명령 → 기대 출력 |
|---|---|---|
| A1 | 잠금 파일이 3.3.4와 같은 값 | `& $PY -X utf8 -c "import json;d=json.load(open(r'packaging/tools.lock.json',encoding='utf-8'));o=d['opencode'];assert o['version']=='1.19.0' and o['variants']['x64']['sha256']=='17108e9448c4fdad48eb8714c4ed6f5dfc9cf86c2eb8f2ce5d02043fef806eb5' and o['variants']['x64-baseline']['sha256']=='2759ca3449fe946d82da3be43d2e85332127399686aafceaff153b90c3079c56' and d['jre']['sha256']=='2332c0b4cff6bed722da3567c91d5e47568bcba863fa4945d0a8d6fc76158628';print('LOCK_OK')"` → `LOCK_OK` |
| A2 | 단위 시험 통과 | `& $PY -X utf8 packaging\test_install_tools.py` → 마지막 줄 `INSTALL_TOOLS_TEST PASS n/n`, 종료 0 |
| A3 | 해시가 다르면 풀지 않고 실패 | 시험이 로컬 가짜 zip(`file:///`, `HOEHWA_TEST_MODE=1`)의 잠금 sha256을 한 글자 바꿔 실행 → 종료 코드 30, 출력에 `TOOL opencode FAIL hash`, `dest`에 `opencode.exe` 없음, `runtime\dl`·`.part`·`.new` 남지 않음 |
| A4 | 크기가 다르면 실패 | 같은 방식, `size` 변경 → 종료 30 |
| A5 | 압축 안에 `..\evil.txt` 또는 절대 경로 항목 → 거부 | 종료 1, 출력 `TOOL opencode FAIL zip`, `$W` 밖에 파일 없음 |
| A6 | 깨진 JSON 잠금 → 한국어 한 줄 + 종료 1 (스택 트레이스 없음) | 명령 → 종료 1, 출력에 `Traceback` 없음 |
| A7 | `http://` 주소 → 거부 (`HOEHWA_TEST_MODE` 없이) | 종료 1, 출력 `https` 언급 |
| A8 | 같은 버전이 이미 있으면 SKIP, 두 번째 실행에서 네트워크 접근 없음 | 두 번 실행 → 둘째 출력 `TOOL opencode SKIP`, 종료 0 |
| A9 | 실제 받기: OpenCode | `& $PY -X utf8 packaging\installer\install_tools.py packaging\tools.lock.json $W\app --only opencode` 후 `& "$W\app\backend\tools\opencode\opencode.exe" --version` → `1.19.0` |
| A10 | 실제 받기: JRE | `--only jre` 후 `& (Get-ChildItem "$W\app\backend\tools\*\bin\java.exe").FullName -version 2>&1` → `21.0.13` 포함 |
| A11 | `get_build_tools.ps1 -DryRun` 이 아무것도 받지 않고 이름·버전·URL·SHA256을 출력 | `powershell -NoProfile -File packaging\get_build_tools.ps1 -DryRun` → 출력에 `innosetup-6.7.4.exe`, `a549929319f9120716677c685535ca4671e4b937b5fdc87e2585f32d8eb30e8c`, 종료 0, `buildtools` 폴더 안 만들어짐 |
| A12 | `get_build_tools.ps1` 실제 실행: 받은 파일 SHA256이 잠금과 같을 때만 설치. **다르면 설치 안 함** | 시험: 잠금 해시를 바꾼 복사본으로 실행 → 종료 ≠ 0, `%LOCALAPPDATA%\hoehwa-practice\buildtools\innosetup-6.7.4\ISCC.exe` 없음. 정상 실행 → `ISCC.exe /?` 가 실행됨 |
| A13 | 금지: `%APPDATA%\npm`·`~\.local\share\opencode` 읽기·쓰기 없음 | `Grep -n "APPDATA|\.local|auth\.json" packaging\installer\install_tools.py` → 0건 |
| A14 | 금지: 소유 밖 파일 변경 없음 | `git status --porcelain` 이 소유 파일 4개 외 변경 0 |

### B1. OpenCode 연결 핵심

| # | 조건 | 명령 → 기대 출력 |
|---|---|---|
| B1-1 | 전체 시험 통과 (자체 시험 서버 + 가짜 opencode를 18851~18859에서 띄움, PID로만 종료) | `& $PY -X utf8 backend\test_llm_connect.py` → 마지막 줄 `LLM_CONNECT_TEST PASS n/n`, 종료 0 |
| B1-2 | 연결 성공 흐름: 로그인 없음 → `state=not_connected` → `POST /llm/connect` 200 `ok:true` → `GET /llm` `state=ready`, `connected=true` | 시험 내 단언 |
| B1-3 | 키 거절(가짜 opencode가 시험 호출에 401) → 503 `code=ai_auth`. 한국어 `error` 포함 | 시험 내 단언 |
| B1-4 | 시험 호출이 429면 200 `tested:false` | 시험 내 단언 |
| B1-5 | **표식 키 누출 0**: 표식 `sk-SENTINEL-…`을 연결·거절·해제 흐름에 모두 쓴 뒤, 서버 로그, 가짜 opencode 로그, 모든 응답 본문, `config.json`, `secrets.json`(생기지 않음), 시험 작업 폴더 전체를 검색 | 시험이 `SENTINEL_LEAK 0` 출력. 가짜 opencode의 "받은 키 SHA256"이 표식의 SHA256과 같음(전달은 됐음) |
| B1-6 | 잘못된 입력 표 (각각 400 `bad_key_format` 또는 403, 그리고 **가짜 opencode가 `PUT /auth`를 받지 않음**): 빈 문자열 / 공백만 / 15자 / 257자 / 키 안에 공백·줄바꿈 / 비ASCII(한글) / `key`가 숫자 / `key` 없음 / 본문이 깨진 JSON / `Content-Type: text/plain` / `Origin: http://evil.example` / `Host: evil.example` | 시험 내 단언, 각 행 PASS |
| B1-7 | LAN 경로 차단: 페어링된 폰 토큰으로 `/llm/connect`, `/llm/disconnect`, `/llm/install` 호출 → 403 `lan_forbidden` (시험 서버의 LAN 청취기 또는 `lan_stub_server.py` 사용, `test_lan.py` 방식) | 시험 내 단언 |
| B1-8 | `opencode.exe` 없음(`HOEHWA_OPENCODE_EXE`가 없는 경로) → `state=not_installed`, `call_json` → `LlmError(kind="not_installed")`, 서버 시작 시도 없음 | 시험 내 단언 |
| B1-9 | `connected()`는 `/health` 경로에서 블로킹하지 않음: 가짜 `auth list`가 5초 걸려도 `GET /health`가 1초 안에 응답 | 시험이 응답 시간 단언 |
| B1-10 | `llm_config.migrate`: `{"llm_provider":"ollama","llm_model":"qwen3:8b","ollama_url":"http://127.0.0.1:11434","keep_alive":"30m","num_ctx":6144,"stt":{"device":"cpu"}}` → `llm_provider=="opencode"`, 네 키 삭제, `stt.device=="cpu"` 유지, notice `"ollama_removed"`, `llm_migrated_from=="ollama"`. `{"llm_provider":"opencode"}` → notice `""`. 알 수 없는 값 `"zzz"` → `opencode` | 시험 내 단언 (`import llm_config`만, server.py 임포트 없음) |
| B1-11 | `/llm/install`: 가짜 `install_tools.py`(시험용 환경변수로 교체)가 0→100%를 쓰면 `GET /llm/install`이 `running`→`done`, 두 번 연달아 `POST`해도 프로세스 1개 | 시험 내 단언 |
| B1-12 | 소유 밖 파일 변경 0, `11434`·`api/tags` 문자열이 B1 파일에 없음 (`llm_config.py` 이전 코드의 주석 제외) | `Grep -n "11434|api/tags" backend\llm_opencode.py backend\llm_routes.py` → 0건 |
| B1-13 | 시험 중 실제 opencode가 실행되지 않음: 시험이 서버 로그의 `opencode exe:` 줄이 가짜 경로이고 `Roaming\npm`을 포함하지 않음을 단언 | 시험 내 단언 |

### B2. 서버에서 Ollama 제거

| # | 조건 | 명령 → 기대 출력 |
|---|---|---|
| B2-1 | 서버에 Ollama 실행·접속 코드 없음 | `Grep -n -i "ollama_url\|11434\|api/tags\|ensure_ollama\|_ollama_installed\|_ollama_chat_json\|local_llm_\|--ollama-url\|--llm-model" backend\server.py` → 0건 (`ollama_json` 이름만 G 전까지 허용) |
| B2-2 | 새 시험 서버(가짜 opencode, **로그인 없음**)에서 `GET /health` | `llm_state=="not_connected"`, `llm==false`, `llm_provider=="opencode"`, `llm_model=="deepseek-v4.1-flash-free"`, 키 `llm_fallback.{active,until,reason}` 모두 있음, 나머지 기존 키(`stt`,`tts`,`score`,`phoneme`,`tatoeba`,`grammar`,`song`,`song_v`,`song_identify`) 있음 |
| B2-3 | 같은 서버: `POST /chat`(영어, 첫 턴) → HTTP 503, 본문 `code=="ai_not_connected"`, `error`는 한국어 | 명령 → 단언 |
| B2-4 | 같은 서버: `POST /lesson`(`source` 기본=tatoeba) 200, `POST /fix`(문법 틀린 영어 문장) 200 (`fix`가 LanguageTool 결과이거나 `""`), `POST /score` 정상 | 명령 → 단언 |
| B2-5 | 가짜 opencode에 로그인 있음 → `/chat` 200 (가짜 답) | 단언 |
| B2-6 | 한도 시뮬레이션(`/debug/engine_limit`, `HOEHWA_TEST_HOOKS=1`)에서 `/chat` → 429 `code=="ai_limit"`, `/health.llm_fallback.active==true`, `reason`에 "로컬" 글자 없음, `llm_state=="blocked"`. 해제하면 다음 호출은 막히지 않고 가짜 답 | 단언 |
| B2-7 | 옛 `config.json`(`llm_provider:"ollama"` + 네 키)로 시작한 시험 서버의 `GET /llm` → `provider=="opencode"`, `notice=="ollama_removed"`. `POST /llm/notice/ack` 후 `notice==""`. 시험 서버는 `config.json`을 **저장하지 않음** (파일 해시 불변) | 단언 |
| B2-8 | **Ollama 접속 0회**: 시험 서버의 `config.json`에 `ollama_url`을 시험 수신기(`127.0.0.1:18852`, 시험이 연결 수를 셈)로 적고 `/health`,`/chat`,`/fix`,`/lesson`,`/llm` 호출 후 | 수신기 연결 수 0 |
| B2-9 | `POST /llm {"provider":"ollama"}` → 400 `code=="engine_removed"`. `POST /llm {"provider":"opencode"}` 200 | 단언 |
| B2-10 | `GET /llm` 모양 = 3.4.3 (`options` 1개, `state`, `installed`, `connected`, `login_url`, `notice`, `openai_api` 있음) | 단언 |
| B2-11 | 설정 기본값: `packaging\defaults\config.default.json` 키에 `llm_model`, `ollama_url`, `keep_alive`, `num_ctx` 없음, `llm_provider=="opencode"` | `& $PY -c "import json;d=json.load(open(r'packaging/defaults/config.default.json'));assert not {'llm_model','ollama_url','keep_alive','num_ctx'}&set(d) and d['llm_provider']=='opencode';print('CFG_OK')"` → `CFG_OK` |
| B2-12 | `test_offline_ai.py`: 기본 실행은 가짜 opencode만 쓰고 실제 로그인을 쓰는 `test_opencode` 항목은 `--live-opencode`를 줘야만 실행 | `& $PY -X utf8 backend\test_offline_ai.py --base http://127.0.0.1:18851 --tag b2` (시험 서버 먼저 기동) → 실패 0, 출력에 `SKIP live opencode` |
| B2-13 | 회귀: 기존 시험 전부 변경 전 기준선과 같거나 좋음. 시작 전에 기준선을 `$W\baseline.txt`에 기록한 뒤, 각 파일 머리말의 방법으로 실행: `test_backend`, `test_lan`, `test_offline_ai`, `test_missions`, `test_reading`, `test_song`, `test_song_enrich`, `test_song_identify`, `test_fixcore`, `test_pron`, `test_lesson_rules` | 각 파일의 마지막 결과 줄에서 실패 0 |
| B2-14 | `test_lan.py`에 `/llm/connect` 등이 `lan.ALLOW`에 **없음** 단언 추가, 실행 통과 | `& $PY -X utf8 backend\test_lan.py --only unit` → 실패 0 |
| B2-15 | `API.md` LLM·health 절이 3.4와 일치 (키 이름·코드·상태 값) | 사람이 대조 (검토자) |
| B2-16 | 금지: `server.py` 로그에 키가 남을 수 있는 변경 없음 (`_timing` 미들웨어는 경로·상태·시간만) | 검토자가 `Grep -n "log\.\(info\|warning\|exception\)" backend\llm_routes.py` 의 모든 줄에 `key` 변수가 없음을 확인 |

### C. Godot AI 연결 화면

| # | 조건 | 명령 → 기대 출력 |
|---|---|---|
| C1 | 새 시험 통과, 스크립트 오류 0, **표식 키 출력 0** | `& $GODOT --headless --path godot res://tests/ai_connect_test.tscn *> $W\out.txt; Get-Content $W\out.txt -Tail 1` → `== ai_connect_test result: N passed, 0 failed ==`, `Select-String -Path $W\out.txt -Pattern '^SCRIPT ERROR'` → 0건, `Select-String -Path $W\out.txt -Pattern 'SENTINEL'` → 0건 |
| C2 | `ai_not_connected` 응답이 오면 시트가 **한 번** 열림 (같은 실행에서 두 번째 응답엔 안 열림, "나중에" 후에도 안 열림), 안내줄 [AI 연결하기] 버튼은 항상 열 수 있음 | 시험 내 단언 |
| C3 | 키 칸 `secret == true`. [연결] 누르는 순간 칸이 비어 있음. 보낸 요청 본문에 키가 정확히 1번(`POST /llm/connect`)만 | 시험 내 단언 (Api 호출 기록 후킹) |
| C4 | 결과별 문구: 성공 / `ai_auth` / `bad_key_format` / `ai_not_installed`(먼저 `/llm/install` 진행 막대) / 네트워크 실패 — 각각 한국어 문구가 시트에 보임 | 시험 내 단언 |
| C5 | 클립보드가 키와 같으면 성공 후 비워짐, 다르면 그대로 | 시험 내 단언 |
| C6 | 폰(`Platform.is_phone()` 가짜)에서는 시트가 안 열리고 문구만 보임 | 시험 내 단언 |
| C7 | 설정에 엔진 고르기(OptionButton)·`ollama` 문자열 없음. "AI 연결" 카드에 상태·[AI 연결하기]·[연결 시험]·[연결 해제] | 시험 내 단언 + `Grep -n -i "ollama" godot\scripts` → `backend.gd`/`settings_view.gd`/`song_view.gd`에 0건 |
| C8 | `llm_missing_text()`가 `llm_state`별 문구: `not_connected`, `not_installed`, `blocked`(`llm_fallback.reason`) | 시험 내 단언 |
| C9 | 이전 안내(`notice=="ollama_removed"`): 토스트 1번, 확인 후 `/llm/notice/ack` 호출 | 시험 내 단언 |
| C10 | 시험은 가짜 백엔드/스텁만 사용. 실제 백엔드·실제 OpenCode·실제 `%APPDATA%` 학습 기록 접근 없음 | 검토자가 시험 소스에서 `user://` 사용을 확인 (기존 시험과 같은 `--userdata` 규칙 따름) |
| C11 | 회귀: `route_test`, `remote_test`, `song_view_test`, `song_add_test`, `song_flow_test`, `song_search_test`, `a11y_sweep_test`, `screens_scan_test`, `flow_test`(가짜 백엔드 방식이면) 를 각 머리말대로 실행 → 실패 0, `^SCRIPT ERROR` 0 | 각 파일 마지막 줄 |
| C12 | 금지: 4.3의 "화면 개편 소유" 줄 번호 범위 밖 수정 없음 | 검토자가 `git diff -U0 godot\scripts\views\settings_view.gd godot\scripts\main.gd` 의 변경 구간이 4.3 표 범위 안 |

### D. install.ps1 원터치화

| # | 조건 | 명령 → 기대 출력 |
|---|---|---|
| D1 | 질문·Node·Ollama·winget·npm 코드 없음 | `Grep -n -i "Read-Host\|Ask-YN\|Select-Engine\|winget\|npm\|nodejs\|ollama\|auth login" packaging\installer\install.ps1` → 0건 (옛 인자 무시 주석은 `-Engine`만) |
| D2 | 입력이 닫혀도 끝까지 감 | `$env:HOEHWA_TEST_MODE='1'; $env:HOEHWA_SETUP_SIMULATE='1'; $env:HOEHWA_USERDATA_DIR="$W\ud"; powershell -NoProfile -ExecutionPolicy Bypass -File "$W\fake\install.ps1" -ProgressFile "$W\p.json" < NUL` (가짜 설치 폴더 `$W\fake`는 staging 구조 복사본) → 종료 0, 120초 이내 |
| D3 | 진행 파일 계약: 시험 스크립트가 0.2초마다 읽어 `state/pct/step/steps/title` 키 존재, `pct` 감소 없음, 마지막 `state=="done"`·`pct==100` | `powershell -NoProfile -ExecutionPolicy Bypass -File packaging\installer\test_progress_contract.ps1` → `PROGRESS_CONTRACT OK` |
| D4 | 실패 흉내: `HOEHWA_SETUP_FAIL_STEP=4` → 종료 40, 진행 파일 `state=="error"`, `code==40`, `error`가 비어 있지 않은 한국어, `install.log` 위치 포함 | 단언 |
| D5 | 이어하기: D4 직후 훅 없이 다시 실행 → 1~3단계는 "이미 끝난 단계" 표시, 종료 0 | 단언 |
| D6 | 경로 95자 초과 가짜 폴더(LongPaths 꺼짐 가정) → 종료 10, `error`에 "경로" | 단언 |
| D7 | GPU 규칙: `-Gpu cpu` → `runtime\.state\gpu.txt`=`cpu`, `config.json`의 `stt.device=="cpu"`, `compute_type=="int8"`. `-Gpu nvidia` → `gpu.txt`=`nvidia`, `stt.device` 안 바뀜 | 단언 |
| D8 | `check_env.py`: `gpu.txt=cpu`면 잠금에서 nvidia 3줄을 뺀 목록과 비교. `HOEHWA_FREEZE_FILE`에 (nvidia 없는 freeze) → `ENV_RESULT OK`, (nvidia 있는 freeze) → `EXTRA nvidia-…` + `MISMATCH`, 거꾸로 `gpu.txt=nvidia`에 nvidia 빠진 freeze → `MISSING` + `MISMATCH` | 4개 조합 단언 |
| D9 | 옛 인자 `-Yes -Engine local -NoShortcut`을 줘도 `-DryRun`이 종료 0, 로그에 `무시됨` | 명령 → 단언 |
| D10 | `-DryRun`은 아무것도 설치하지 않고 계획 출력: 단계 11개 이름과 `OpenCode`, `JRE` 줄 | 명령 → 출력에 `[DryRun]` 11줄 |
| D11 | 11단계(동작 확인)가 AI를 요구하지 않음: 시뮬레이션이 아닌 실행에서 `llm=false`여도 합격 (코드 읽기 + 시험 `/health` 가짜) | 검토자가 코드 확인 |
| D12 | 옛 상태 파일(`engine.txt`, `engine-config.ok`, `engine-pending.ok`)이 있는 폴더에서 실행해도 지우고 정상 진행 | 단언 |
| D13 | `uninstall.ps1`: `unins000.exe`가 있으면 "설정 > 앱에서 제거" 안내만 출력하고 아무것도 지우지 않음 (종료 0). 없으면 지금처럼 동작하되 Ollama 문구 삭제 | 가짜 폴더 2종으로 단언 |
| D14 | 금지: `auth.json` 문자열 없음, `opencode auth login` 안내 없음, 로그에 비밀값 없음 | `Grep -n "auth\.json" packaging\installer\install.ps1` → 0건 |
| D15 | 바탕화면·시작 메뉴·레지스트리에 쓰지 않음 (바로가기는 이 스크립트가 만들지 않음, F가 함). `%APPDATA%`는 **10단계의 학습 기록 기본값 복사(`prefs.json`·`progress.json`, 대상 파일이 이미 있으면 건드리지 않음)만** 허용하고, 시험·시뮬레이션은 `HOEHWA_USERDATA_DIR`로 임시 폴더에 돌려 실제 `%APPDATA%`를 쓰지 않는다 | `Grep -n "CreateShortcut\|Desktop" packaging\installer\install.ps1` → 0건, 코드에서 `APPDATA`를 쓰는 곳이 10단계 한 군데뿐이고 `Get-Hook "HOEHWA_USERDATA_DIR"`로 바뀜 |

### E. update.ps1·helper 정리

| # | 조건 | 명령 → 기대 출력 |
|---|---|---|
| E1 | `lockinfo`에 `ollama` 없음, `tools`(64자 hex) 있음 | `& $PY -X utf8 packaging\installer\update_helper.py lockinfo <vendor> <backend>` → JSON에서 `"ollama"` 키 없음, `tools` 길이 64 |
| E2 | `update.ps1`에 Ollama 코드 없음 | `Grep -n -i "ollama" packaging\installer\update.ps1` → 0건 |
| E3 | **옛 스크립트 × 새 update zip 호환**: 가짜 "1.4.1 설치 폴더"(옛 `update.ps1`은 `out\release_1.4.1\hoehwa-practice-setup-1.4.1.zip`에서 꺼냄, `config.json`에 `llm_provider:"ollama"`+네 키+`stt.device:"cpu"`, `version.txt=1.4.1`, 옛 manifest)에서 `HOEHWA_TEST_MODE=1 HOEHWA_PIP_DRYRUN=1 HOEHWA_UPDATE_SOURCE=<가짜 릴리스 폴더>`로 옛 `update.ps1 -Yes` 실행 | 종료 0, `version.txt`==새 버전, `config.json`의 `stt.device=="cpu"` 유지, `backup\1.4.1` 존재, 로그에 `ollama`·`ollama.exe` 호출 없음 |
| E4 | **새 스크립트 × 새 update zip**: 같은 가짜 폴더 | 종료 0, 같은 단언 + `runtime\.state\installer_version.txt`==`2` |
| E5 | `tools` 락이 바뀐 가짜 릴리스(opencode 버전·sha 변경, `file:///` zip) → 새 스크립트가 `install_tools.py`를 호출해 `backend\tools\opencode\opencode.exe`가 교체됨 (시험은 가짜 exe 문자열 확인). 도구 받기가 실패하면 경고만 하고 업데이트는 성공(종료 0, 파일 교체 완료) | 단언 |
| E6 | `pipsync` 필터: `gpu.txt=cpu` + `HOEHWA_PIP_DRYRUN=1`로 `update_helper.py pipsync` → 출력 계획에 `nvidia-` 줄 0개 (잠금엔 3개). `gpu.txt=nvidia` → 설치된 게 없을 때 3개 모두 계획에 포함. `gpu.txt` 없음(옛 설치) → 3개 포함(지금 동작) | 3조합 단언 |
| E7 | 틀린 입력: update zip 바이트 1개 변조 → "SHA256 불일치" 종료 1, 파일 교체 0건 / manifest의 파일 해시 변조 → `verify` 실패 종료 1 / `min_installer_version`을 3으로 한 manifest → 중단 메시지 | 각각 단언 |
| E8 | 되돌리기: `HOEHWA_UPDATE_FAIL=after_apply`로 실패시키면 옛 파일이 복원되고 `config.json`이 그대로 | 단언 |
| E9 | `make_locks.py`: `models.lock.json`에 `ollama` 키 없음, Ollama 접속 시도 없음 (`Grep -n -i "ollama" packaging\make_locks.py` 0건) | 명령 → 단언 |
| E10 | `update_helper.py` 명령줄 이름·인자 불변: `verify`, `lockinfo`, `dirsize`, `mergecfg`, `setcfg`, `pipsync`, `prunehf`, `refsave`, `refrestore`, `languagetool`, `manifest` 모두 `--help`/인자 오류가 아닌 정상 동작 (E3이 간접 증명) | E3 통과 + `Grep -c "add_parser\|== \"" ` 비교 (검토자) |
| E11 | 금지: 실제 `%APPDATA%`, 실제 설치 폴더 접근 없음 (모두 `$W` 아래 가짜 폴더) | 검토자 확인 |

### F. setup.exe 만들기

| # | 조건 | 명령 → 기대 출력 |
|---|---|---|
| F1 | 빌드: staging → 규칙 검사(check_zip) → Inno 컴파일 | `powershell -NoProfile -ExecutionPolicy Bypass -File packaging\build_dist.ps1 -SkipExport -Release 9.9.9 -OutDir "$W\out"` → 종료 0, `"$W\out\release_9.9.9\hoehwa-practice-setup.exe"` 존재, 크기 60~130MB |
| F2 | 릴리스 자산 목록: `hoehwa-practice-setup.exe`, `hoehwa-practice-update-9.9.9.zip`, `SHA256SUMS.txt`, `latest.json`. **`-setup-9.9.9.zip` 없음** | `Get-ChildItem "$W\out\release_9.9.9" -Name` |
| F3 | `SHA256SUMS.txt`의 줄이 실제 파일 해시와 일치, 두 파일(setup.exe, update zip) 포함 | `Get-FileHash` 대조 |
| F4 | 옛 업데이터 호환: `latest.json`의 자산 이름이 옛 정규식 `[-_]update[-_]v?9\.9\.9\.zip$`에 맞음 | `& $PY -c "import re,json;j=json.load(open(r'$W\out\release_9.9.9\latest.json',encoding='utf-8'));print(any(re.search(r'(?i)[-_]update[-_]v?9\.9\.9\.zip$',a['name']) for a in j['assets']))"` → `True` |
| F5 | payload 검사: staging과 같은 내용의 zip을 `check_zip.py`가 통과 (비밀·개인 정보·dev 파일 없음). 시험: staging에 `secrets.json`, `progress.json`, `test_x.py`를 넣고 다시 검사하면 `ZIPCHECK_RESULT FAIL` | 정상 `ZIPCHECK_RESULT OK`, 오염 시 FAIL (둘 다 확인) |
| F6 | **시험 빌드 + 조용한 시뮬레이션 설치** (`ISCC /DTestBuild=1` → 다른 AppId, 바로가기·자동 실행 없음) | `$env:HOEHWA_TEST_MODE='1'; $env:HOEHWA_SETUP_SIMULATE='1'; $env:HOEHWA_USERDATA_DIR="$W\ud"; Start-Process "$W\out\hoehwa-practice-setup-test.exe" -ArgumentList '/VERYSILENT','/SUPPRESSMSGBOXES',"/DIR=$W\inst","/LOG=$W\inno.log" -Wait -PassThru` → `ExitCode 0`, `$W\inst\회화연습.exe`·`unins000.exe`·`runtime\.state\installer_version.txt`(=2)·`version.txt` 존재, `$W\ud\prefs.json` 존재 |
| F7 | 진행 파일이 Inno 막대에 연결됨: 시험 스크립트가 시뮬레이션 설치 중 진행 파일의 `pct`가 0→100으로 증가함을 기록, Inno 로그에 `done` 확인 | `PROGRESS_CONTRACT OK` |
| F8 | **화면 확인**: 보이는 모드로 시뮬레이션 설치를 돌리며 시작·중간·완료 화면 캡처 3장 (`$W\shot_*.png`). 중간 화면에 진행 막대·문구가 보이고 질문·버튼이 없음 | 검토자가 이미지를 열어 확인 (실기 확인은 사용자 몫, 미검증으로 표기 가능) |
| F9 | 실패 시 롤백 없음: `HOEHWA_SETUP_FAIL_STEP=4`로 시뮬레이션 설치 → 종료 코드 ≠ 0, 한국어 오류 메시지(조용한 모드는 로그), **`$W\inst`의 파일이 남아 있음**. 다시 실행(훅 없이) → 이어서 성공 | 단언. (Inno에서 안 되면 7절 R1의 대안 B 사용) |
| F10 | 제거: `"$W\inst\unins000.exe" /VERYSILENT` → `$W\inst` 폴더 사라짐, 시험 AppId의 `HKCU\Software\Microsoft\Windows\CurrentVersion\Uninstall\<AppId>_is1` 없음, `$W\ud`(학습 기록 자리) 그대로 | `reg query` 대조 |
| F11 | 이미 실행 중인 프로세스 정리: `$W\inst` 아래 가짜 exe(`ping -t`을 부르는 복사본)가 떠 있을 때 재설치 → 그 PID만 종료되고 **같은 이름의 다른 폴더 프로세스는 살아 있음** | 단언 (PID 비교) |
| F12 | 경로 규칙: `/DIR`을 96자 이상으로 주면 `install.ps1` 종료 10 → 한국어 안내. 기본 경로가 80자를 넘는 환경(`LOCALAPPDATA` 가짜 값은 못 바꾸므로 `.iss` 함수 단위 확인)에서는 `C:\회화연습` 선택 | `.iss`의 경로 선택 함수를 작은 시험 스크립트로 검증 (Inno `ISPP` 또는 `[Code]` 분리) |
| F13 | 두 개 동시 실행 방지(`SetupMutex`): 두 번째 setup은 즉시 끝나고 첫 번째는 영향 없음 | 단언 |
| F14 | `publish_release.ps1 -Version 9.9.9 -DryRun -SkipExport` → 자산 목록에 위 3개, `DRY RUN OK`. 릴리스 본문에 SmartScreen 안내(2.7)와 "설치: hoehwa-practice-setup.exe 받아 더블클릭" 포함, `설치.bat`·압축 풀기 안내 없음 | 출력과 본문 확인 |
| F15 | 비밀·개인정보 검사가 그대로 작동: `publish_release.ps1 -ScanOnly` → `SCAN OK`. 시험: 임시로 추적 파일에 `sk-` + 24자 문자열을 넣으면 `ScanOnly`가 막음 (시험 후 되돌림) | 둘 다 확인 |
| F16 | `release.json`: `installer_version==2`, `min_installer_version==1`, `asset_prefix` 유지 | `& $PY -c "import json;d=json.load(open(r'packaging/release.json'));assert d['installer_version']==2 and d['min_installer_version']==1;print('REL_OK')"` → `REL_OK` |
| F17 | `.iss`에 개인 경로·키 없음 | `Grep -n "rtyu6\|sk-\|C:\\\\Users" packaging\setup\hoehwa.iss` → 0건 |
| F18 | 금지: 실제 바탕화면·시작 메뉴·실제 AppId 레지스트리에 쓰지 않음 (시험 빌드만 실행). 실제 빌드(`TestBuild=0`)는 컴파일만 하고 실행하지 않음 | 검토자가 `Get-ChildItem ([Environment]::GetFolderPath('Desktop')) -Filter '회화*'` 변화 없음 확인 |

### G. `ollama_json` → `llm_json`

| # | 조건 | 명령 → 기대 출력 |
|---|---|---|
| G1 | 이름 전부 교체 | `Grep -rn "ollama_json" backend godot` (`.venv` 제외) → 0건 |
| G2 | 남은 "ollama" 글자는 허용 목록뿐 | `Grep -rn -i "ollama" backend godot packaging --glob "!**/.venv/**" --glob "!packaging/out/**"` → 줄이 모두 8절 부록 허용 목록(마이그레이션 코드·그 시험·`ollama_removed`·안내 문구)에 있음 |
| G3 | 회귀: B2-13의 시험 전부 실패 0 (기준선과 같음) | 각 시험 결과 줄 |
| G4 | 주입 이름 변경이 시험용 도우미(song.py `_test_helpers`)에도 반영 | `test_song`, `test_song_enrich`, `test_missions`, `test_reading` 통과 |
| G5 | 동작 변경 없음: 이름만 바뀐 diff (검토자가 `git diff --stat`·`git diff -w` 샘플 확인, 로직 줄 변경 0) | 검토자 확인 |

### H. 문서

| # | 조건 | 명령 → 기대 출력 |
|---|---|---|
| H1 | README·INSTALL·사용법에 Ollama·Node.js 설치 안내가 없음 (이전 사용자 안내 한 줄 제외) | `Grep -n -i "ollama\|node\.js\|설치\.bat" README.md INSTALL.md packaging\installer\사용법.txt` → 허용된 줄만 |
| H2 | 설치 절이 "setup.exe 받기 → 더블클릭 → 기다리기 → 앱 실행"이고 SmartScreen 안내(2.7 문구)·해시 확인 명령·`/DIR` 폴더 바꾸기·"AI 연결하기 한 번"·제거 방법(설정 > 앱) 포함 | 검토자 대조 |
| H3 | INSTALL.md 4절 표에서 "opencode auth login" 안내 → "AI 연결하기"로 바뀜 | `Grep -n "auth login" INSTALL.md README.md` → 0건 |
| H4 | 용량·시간 숫자는 I의 실측값 사용 (추정 표기 제거) | 검토자 대조 |
| H5 | API.md가 3.4와 일치, 옛 "로컬 AI가 대신 답한다" 문구 없음 | `Grep -n "로컬 AI\|Ollama" API.md` → 허용된 줄만 |

### I. 통합·실설치 시험

코드 수정 금지. 실패는 원래 작업으로 되돌린다.

| # | 조건 | 명령 → 기대 출력 |
|---|---|---|
| I1 | 위 A~G의 모든 시험 재실행 → 실패 0 | 각 결과 줄 모음 |
| I2 | **실설치 1회 (시험 빌드, NVIDIA 없는 PC 흉내 `-Gpu cpu`)**: 인터넷 사용, 4~6GB 받기, 10~17분. `$W\inst`에 설치 | `Start-Process <시험 setup.exe> -ArgumentList '/VERYSILENT','/DIR=$W\inst','/GPU=cpu' -Wait` 후 종료 0, `$W\inst\install.log` 마지막에 완료, `version.txt` 존재 |
| I3 | 설치본에서 시험 서버만 켜 확인 (앱 exe 실행 금지): `"$W\inst\runtime\python\pythonw.exe" "$W\inst\backend\server.py" --port 18853 --tag setuptest` (PID 기억) → `GET /health` | `ok==true`, `stt`, `tts.en`, `tts.ja`, `score` 모두 true, `llm_state=="not_connected"` (opencode.exe는 설치돼 있고 로그인만 없음), `grammar==true` (JRE+LT 동작) |
| I4 | 설치본 구성: `backend\tools\opencode\opencode.exe --version`=`1.19.0`, `backend\tools\*\bin\java.exe` 있음, `backend\tools\languagetool\*\languagetool-server.jar` 있음, `runtime\python\Lib\site-packages\nvidia` **없음**(cpu 모드), `runtime\.state\gpu.txt`=`cpu` | 명령 → 단언 |
| I5 | 로그인 전 AI 없는 기능: `/lesson`(tatoeba) 200, `/fix` 200, `/score`에 무음 입력 → 정상 응답(오류 아님), `/chat` 503 `ai_not_connected` | 단언 |
| I6 | 용량·시간 기록: `Get-ChildItem $W\inst -Recurse \| Measure-Object Length -Sum`(GB), 단계별 시간(install.log 요약). 추정(2.8)과 비교해 보고 | 숫자 보고 |
| I7 | 제거 시험: `unins000.exe /VERYSILENT` → 폴더 삭제, 시험 AppId 레지스트리 없음 | 단언 |
| I8 | 되돌아가기 시험(옛 사용자): 1.4.1 설치 zip을 `$W\old`에 풀고(설치 없이 가짜 구조) 새 update zip을 옛 스크립트로 적용(E3과 같음) → 새 앱 코드가 `llm_provider:"ollama"` 설정으로 시작해 `GET /llm.notice=="ollama_removed"` | 단언 |
| I9 | **사용자 실기 필요 (미검증으로 표기)**: 실제 OpenCode 계정으로 키 붙여 넣기 → 대화 한 턴, 브라우저에서 받은 exe의 SmartScreen 실제 화면, 폰에서 `ai_not_connected` 문구 | 오케스트레이터가 사용자에게 요청 |
| I10 | 남은 프로세스·열린 포트 없음 (자기 PID만 종료) | `Get-NetTCPConnection -LocalPort 18851..18859 -ErrorAction SilentlyContinue` 비어 있음 |

---

## 6. 시험 방법 (장치 정리)

| 하고 싶은 것 | 쓰는 장치 |
|---|---|
| 설치를 빨리 흉내 | `HOEHWA_TEST_MODE=1` + `HOEHWA_SETUP_SIMULATE=1` (3.3.3). 1분 안에 끝남 |
| 단계 실패·이어하기 | `HOEHWA_SETUP_FAIL_STEP=N` |
| 실제 학습 기록 보호 | `HOEHWA_USERDATA_DIR=<임시>` |
| 점검 단계(1단계)의 환경 흉내 | `HOEHWA_TEST_LONGPATHS=0\|1`(긴 경로 지원), `HOEHWA_TEST_FREE_GB=<숫자>`(디스크 여유), `HOEHWA_TEST_NET=skip`(인터넷 점검 건너뜀), `HOEHWA_TEST_NET_FAIL=pypi.org,github.com`(안 되는 호스트). 모두 `HOEHWA_TEST_MODE=1`일 때만 읽음 (3.3.3) |
| 도구 받기 시험 | `install_tools.py`: `HOEHWA_TEST_MODE=1`에서만 `file:///` 주소 허용, `HOEHWA_TOOLS_AVX2=0\|1`(변형 고르기), `HOEHWA_TOOLS_MAXUNZIP=<바이트>`(압축 해제 상한) |
| 가짜 설치 폴더 | 빌드의 staging 폴더를 `$W\fake`로 복사해 쓰기 (`runtime\python` 없이도 시뮬레이션은 통과) |
| 가짜 opencode | `HOEHWA_TEST_HOOKS=1` + `HOEHWA_OPENCODE_EXE=<.cmd 래퍼>` + `backend/test_fake_opencode.py` |
| 업데이트 시험 | 기존 `-Source <폴더>` + `latest.json` (build_dist가 `release_<v>\`에 만듦) + `HOEHWA_PIP_DRYRUN=1`, `HOEHWA_UPDATE_FAIL=after_apply\|after_packages` |
| 옛 스크립트 호환 | `out\release_1.4.1\hoehwa-practice-setup-1.4.1.zip`에서 옛 `update.ps1`·`update_helper.py` 꺼내 사용 |
| 시험용 setup | `ISCC /DTestBuild=1`: 다른 AppId, 바로가기·자동 실행 없음, 끝나면 `unins000.exe`로 제거 |
| 시험 서버 포트 | 18851~18859 (비어 있는지 확인). 기존 시험이 쓰는 8787, 8790, 8862~8869와 겹치지 않음 |
| 비밀값 누출 시험 | 표식 키 `sk-SENTINEL-<무작위24자>` → 모든 로그·응답·설정·임시 폴더 검색 |

---

## 7. 위험 요소와 대안, 되돌리기

| ID | 위험 | 영향 | 대안·완화 | 확인할 실패 시나리오 |
|---|---|---|---|---|
| R1 | Inno `[Code]` 진행 연결과 "실패해도 롤백 안 함"이 기대대로 안 됨 (**추측**: 설치 단계 중 예외는 롤백을 부를 수 있음) | 실패 시 파일이 지워져 이어하기 불가 | 대안 B: Inno는 파일 풀기·바로가기만 하고, 마지막에 PowerShell WinForms 진행 창(`install.ps1 -Gui`, 같은 진행 파일을 읽음)을 띄움. 진행 파일 계약은 같아서 갈아타기 쉬움 | F9 (`FAIL_STEP=4` 후 파일 남음, 재실행 성공) |
| R2 | SmartScreen·백신 경고로 설치 포기 | 사용자 이탈 | 안내 문구(2.7), 해시 확인, 오탐 신고. 후속: 서명 (D10) | 사람 확인 (I9) |
| R3 | 무료 모델 `deepseek-v4.1-flash-free`가 사라지거나 계정마다 다름 (실측 4·5: 로그인 여부로 목록이 다름) | AI 전부 불가 | 오류 문구가 모델 사라짐을 알림(llm_opencode.py `_error`의 "model not found"). `opencode.model`로 교체 가능. 후속: 로그인 후 `/provider`에서 무료 모델 자동 선택 | 가짜 opencode가 "model not found" → `ai_auth` 문구 단언 (B1) |
| R4 | OpenCode가 `PUT /auth` API를 바꿈 | [AI 연결하기] 불가 | 버전 고정(1.19.0)·`tools.lock.json`으로만 올림. 올릴 때 B1 시험의 실제 확인 절차를 반복. 임시 대안: 터미널에서 `opencode auth login -p opencode` 안내 문구를 시트에 접어서 보임 | 시트의 "터미널로 연결" 접힌 안내가 있음 (C) |
| R5 | 키가 화면·클립보드·로그에 남음 | 계정 도용 | 3.5절 7개 규칙, 표식 시험 B1-5·C1 | B1-5, C1, C5 |
| R6 | 같은 PC의 다른 웹페이지가 `127.0.0.1:8770/llm/connect`로 키를 바꿔치기 (CSRF) | 남의 계정으로 연결됨 | `_local_only`의 Host·Origin·Content-Type 검사 | B1-6 (`Origin: evil`, `text/plain`) |
| R7 | `mergecfg`는 사용자 값이 이김 → 기본 모델·값을 나중에 바꿔도 기존 설치엔 안 퍼짐 | 업그레이드 지연 | `llm_config.migrate`에 버전별 이전을 추가하는 자리로 활용 | — |
| R8 | OpenCode 로그인이 `~\.local\share\opencode\auth.json` **전역** → [연결 해제]가 터미널의 OpenCode도 로그아웃 | 혼란 | 해제 확인 문구에 명시 (3.2-③-8). 반대로 이득: 옛 사용자는 다시 로그인 안 함 | C의 확인 문구 단언 |
| R9 | 신규 기본 경로가 80자 넘음(긴 한글 사용자명 등) | 파이썬 패키지 깨짐 | 80자 초과면 `C:\회화연습`로 자동 변경. `install.ps1`은 95자 초과 거절 | F12 |
| R10 | 회사 PC에서 GitHub·HuggingFace·PyPI 차단, 프록시 | 설치 실패 | 점검 단계에서 어느 주소가 안 되는지 한국어로 알림(종료 20). 프록시 환경은 범위 밖 | D에서 점검 실패 흉내 |
| R11 | PowerShell 실행 정책이 그룹 정책으로 강제 | install.ps1 실행 거부 | `-ExecutionPolicy Bypass`는 GPO가 이기면 무효. 오류 문구에 안내. 드문 경우 | — |
| R12 | `opencode.exe`(180MB) 첫 실행 때 Defender 검사로 느림 | "AI 엔진 준비 중" 길어짐 | 기존 prestart 유지. 설치 11단계에서 `opencode --version`을 한 번 실행해 첫 검사를 미리 끝냄 (선택) | — |
| R13 | 새 setup.exe를 기존 zip 설치 폴더 위에 실행하면 폴더가 둘로 갈라짐 (6.8GB 중복) | 디스크 낭비 | 문서에 "기존 설치는 업데이트.bat로". 후속: 옛 폴더 감지해 안내 (D12) | — |
| R14 | 업데이트 중 새 `update_helper.py` 명령줄이 옛 스크립트와 어긋남 | 업데이트 실패 | E3 (옛 스크립트 × 새 zip) 필수, E10 | E3 |
| R15 | GPU 감지 오류 (하이브리드 노트북, 구형 NVIDIA) | 필요한데 라이브러리 없음 → 앱이 CPU로 동작(느림). 반대로 불필요한데 설치(용량) | 서버가 CUDA 실패 시 CPU로 내려가는 기존 동작(server.py:300-325). `/GPU=nvidia\|cpu`로 강제, `gpu.txt` 수동 수정 안내 | D7, D8 |
| R16 | Ollama 사용자가 로컬로 돌아가고 싶어 함 | 불만 | 이번 결정은 "완전 제거". 릴리스 노트에 "1.4.x 유지 가능"만 적음 | — |

**되돌리기**: 코드는 git 브랜치 병합 단위로 되돌린다. 릴리스는 지우지 않고 새 버전으로 고친다 (CLAUDE.md). 설치 중 실패는 같은 setup.exe 재실행(단계 표시 파일), 업데이트 실패는 기존 `backup\<버전>` 복원. 개발 PC의 Inno Setup은 `%LOCALAPPDATA%\hoehwa-practice\buildtools\`를 지우면 끝.

---

## 8. 오케스트레이터가 정할 사항 (추천안 포함)

| ID | 질문 | 추천 |
|---|---|---|
| D1 | setup.exe 도구 | **Inno Setup 6.7.4** (고정 해시). 7.1.1은 최신이나 변화 미확인 |
| D2 | Node.js | **전부 제거**, opencode.exe를 GitHub 릴리스 zip에서 직접 받기 (sha256 고정) |
| D3 | LanguageTool·Java | **유지 + 포터블 JRE 항상 포함** (+약 180MB) |
| D4 | NVIDIA 없는 PC | **cuBLAS·cuDNN·nvrtc 생략** (약 2GB 절약) |
| D5 | 릴리스 자산 | `hoehwa-practice-setup.exe`(버전 없는 이름, 영구 링크) + `-update-<v>.zip` + `SHA256SUMS.txt`. 설치 zip 발행 중단 |
| D6 | 버전 | **1.5.0**, `installer_version` 2, `min_installer_version` 1 유지 |
| D7 | 폴더 바꾸기 | **`/DIR=` 인자만** (화면에는 안 물음). 화면이 필요하면 별도 결정 |
| D8 | 로그인 방식 | **앱 입력칸(A)** + 접힌 터미널 안내(B, 문구만). 터미널 직접 실행 버튼은 이번에 안 만듦 |
| D9 | `openai_api` 엔진 | **유지** (숨은 개발용, 이번 범위 밖) |
| D10 | 코드 서명 | 지금은 **무서명 + 안내 문구**. 이후 SignPath 오픈소스 신청 검토 |
| D11 | `ollama_json` 이름 | **`llm_json`으로 변경** (작업 G, 마지막) |
| D12 | 기존 zip 설치 사용자 | 업데이트로 계속 사용(권장). 새 setup.exe는 새 폴더에 설치됨을 문서에 명시. 옛 폴더 자동 감지는 후속 |
| D13 | 화면 개편 설계자와의 파일 경계 | 4.3 표대로 합의 필요 (home_menu_design.md가 아직 없음) |
| D14 | 한도 걸렸을 때 | **막지 않고 호출마다 시도**, 안내만 갱신 (로컬 대체가 없어졌기 때문) |
| D15 | 실설치 시험(I2) | **허용**: 4~6GB 다운로드, 10~17분, 시험 AppId·`$W\inst`만 사용 |
| D16 | 후속 용량 절감 | wav2vec2(1.26GB) 지연 다운로드, 모델·pip 병렬 다운로드는 이번 제외. 다음 릴리스 후보 |
| D17 | 사용자 몫 확인 | I9 (실제 계정 로그인, 실제 SmartScreen, 폰 문구)는 사용자 실기 |

부록: **허용되는 "ollama" 글자** (G2 기준)
- `backend/llm_config.py`의 이전 코드와 그 시험(`test_llm_connect.py`의 마이그레이션 시험).
- 값 `"ollama_removed"`, 설정 키 `llm_migrated_from`.
- 거절 코드 `"engine_removed"`(`POST /llm {"provider":"ollama"}`의 400)와 그 시험의 입력 문자열 `ollama`, 그리고 "ollama 없음"을 확인하는 시험이 검색하는 문자열(`test_offline_ai.py`의 Ollama 접속 0회·코드 없음 단언, `packaging/installer/test_progress_contract.ps1`의 설치 스크립트에 ollama 없음 단언 등).
- 앱·문서의 이전 사용자 안내 한 줄(Ollama를 지우면 5GB를 비울 수 있다는 문구).
- 릴리스 노트·WORKLOG·ROADMAP 같은 역사 기록.
- 이름 `ollama_json`은 이 문서의 작업 G 설명(옛 이름 → `llm_json`)에만 남긴다. 다른 `docs/*.md` 설계 문서는 `llm_json`으로 고쳤다(WORKLOG는 역사 기록이라 그대로).

---

## 9. 요약 (10줄)

1. 설치는 **Inno Setup 6.7.4**(해시 고정, 비관리자)로 `hoehwa-practice-setup.exe` 하나. 질문 페이지를 모두 끄고, `install.ps1`이 쓰는 **진행 파일(JSON)**을 읽어 Inno 진행 막대에 보여 준다.
2. 조사로 드러난 큰 단순화: `opencode-ai` npm은 껍데기라, **Node.js·npm·winget·관리자 창을 전부 없애고** GitHub 릴리스 zip(`opencode-windows-x64.zip`, sha256 고정)을 직접 받는다. JRE(Temurin 21.0.13+9, sha256 고정)도 질문 없이 항상 포함해 로그인 전에도 문법 교정이 된다.
3. NVIDIA 그래픽카드가 없으면 cuBLAS·cuDNN·nvrtc(약 2GB)를 설치하지 않는다. 설치 후 디스크 약 6.8GB → 약 4.3GB(비NVIDIA)/6.3GB(NVIDIA), 시간 약 17분 → 9~14분(추정).
4. 실측: 로그인 없이는 `deepseek-v4.1-flash-free`가 안 보인다 → 로그인은 필요하다. `GET /provider`의 `connected`는 로그인 없이도 `opencode`라 **판정에 못 쓴다**. 로그인 여부는 `opencode auth list`(이름만), 키가 맞는지는 실제 시험 호출로 판정한다.
5. [AI 연결하기]: 앱이 `opencode.ai/auth`를 열고, 사용자가 키를 가려진 칸에 붙여 넣으면 `POST /llm/connect` → 백엔드가 OpenCode의 `PUT /auth/opencode`로만 전달한다. 키는 로그·응답·설정·명령줄 어디에도 남지 않고, PC 로컬 전용(`_local_only` + LAN 허용 목록 제외). 표식 키 누출 시험으로 확인한다.
6. Ollama 완전 제거: server.py·llm_fallback·시험·설치·업데이트·Godot 엔진 선택 UI·설정 기본값·문서. 한도에 걸려도 로컬 대체는 없고 안내만 한다. 기존 `engine=local` 사용자는 시작 때 `opencode`로 이전되고 한 번 안내(PC의 Ollama는 지우지 않음).
7. 새 오류 코드 `ai_not_connected`/`ai_not_installed`/`ai_auth`/`ai_limit`가 응답 `code`로 오고, 앱은 PC에서만 시트를 연다. AI 없는 기능은 그대로 동작한다.
8. 기존 1.4.x 사용자는 **옛 update.ps1이 새 update zip을 적용**한다. 그래서 `min_installer_version`은 1 유지, 자산 이름·`update_helper.py` 명령줄 호환을 지키고, 옛 스크립트 × 새 zip 호환 시험(E3)을 필수로 둔다. 옛 npm OpenCode와 로그인도 그대로 쓴다.
9. 작업은 A(도구·잠금) B1/B2(백엔드) C(Godot) D(install) E(update) 6개를 먼저 병렬로, 이어 F(Inno·빌드·릴리스)와 G(이름 변경), 마지막 H(문서)·I(실설치 1회 포함 통합). 화면 개편과 겹치는 `settings_view.gd`·`main.gd`·`backend.gd`·`song_view.gd`는 4.3 표의 줄 범위로 소유를 나눈다.
10. 가장 큰 위험은 Inno 진행·롤백 동작(추측)과 SmartScreen이다. 대안(PowerShell 진행 창, 같은 진행 파일 계약)과 안내 문구를 준비했고, 서명·실제 계정 로그인·폰 문구는 사용자 실기 확인으로 남긴다.
