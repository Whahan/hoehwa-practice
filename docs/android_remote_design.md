# 안드로이드 "PC 연결형" 클라이언트 설계

작성: designer, 2026-10-16. 대상: `D:\Ai\언어\app` (v1.0.1 기준). 이 문서는 설계만 담고 코드는 아직 고치지 않았다.
표기: **(추측)** = 코드나 문서로 확인하지 못한 가정이라 작업자가 먼저 확인한다. **(확인)** = 실제 파일을 읽어 확인한 사실.

---

## 0. 한눈에 보기

### 0.1 핵심 결정

| # | 결정 | 이유 |
|---|---|---|
| D1 | 폰 앱 = 지금 Godot 화면 + "원격 모드". 백엔드는 PC 것을 그대로 쓴다 | Whisper·Kokoro 등은 PC 전용 (확인: README) |
| D2 | LAN 접속은 **별도 포트의 추가 리스너**(`0.0.0.0:8775`)로 연다. 기존 `127.0.0.1:8770`은 그대로, 서버 재시작 없음 | 같은 포트 `8770`에 `0.0.0.0`을 또 바인딩하면 Windows에서 충돌한다. 재시작은 모델 로딩 15~60초 (확인: README) |
| D3 | 인증은 **리스너 기준**: LAN 리스너로 들어온 요청은 전부 토큰 필요(소스 IP가 127.0.0.1이어도). 루프백 리스너는 지금처럼 토큰 없음 | IP 판별은 우회·오판 위험이 크다. 리스너 기준이 단순하고 시험하기 쉽다 |
| D4 | 페어링 = PC에 6자리 코드 표시 → 폰이 `/pair`로 토큰 발급. 코드 5번 틀리면 잠금, 5분 만료, 1회용 | 요청 사항 |
| D5 | LAN 리스너에는 **허용 목록**(allowlist)만 열린다. `/mic/*`, `/llm`(POST), `/lan` 관리, `/docs`는 LAN에서 403 | 폰이 PC 마이크를 켜거나 PC 설정을 바꾸면 안 된다 |
| D6 | 찾기 = 직접 입력 + UDP 브로드캐스트(포트 8776). 폰 연결이 켜져 있고 자동 찾기가 켜져 있을 때만 응답, 응답은 이름·포트만 | 요청 사항 |
| D7 | 폰 녹음 = Godot `AudioEffectRecord` → 모노 16bit WAV → `audio_b64`. 서버가 16kHz로 변환하므로 폰은 리샘플링하지 않는다 | GDScript 리샘플링은 느리다. API.md "WAV는 어떤 샘플레이트·채널이어도 된다" (확인) |
| D8 | 폰 화면 = 논리 412×915 세로 고정, 하단 탭바, 키보드 높이 반영 | 요청 사항 |
| D9 | 서명 APK = `hoehwa-practice-android-<버전>.apk`, 새 스크립트 `packaging\build_android.ps1` (기존 `build_dist.ps1`은 건드리지 않음) | 파이썬 venv가 필요 없는 빌드라 분리 |
| D10 | 파일 소유권으로 W1~W4 4명 병렬 + 오케스트레이터가 먼저 만드는 Phase 0 스텁 | §8 |

### 0.2 환경 확인 결과 (문서 작성 시점, 읽기 전용 조회)

사용자 설명과 달리 **빌드 도구 일부가 이미 설치돼 있다** (WORKLOG의 `w_androidtools` 작업 결과로 추정). §13에서 재확인한다.

| 항목 | 상태 |
|---|---|
| Godot export 템플릿 | `%APPDATA%\Godot\export_templates\4.6.3.stable\`에 `android_release.apk`(103 MB), `android_debug.apk`(125 MB), `android_source.zip`, 윈도우 템플릿, `version.txt`=`4.6.3.stable` |
| platform-tools | `%LOCALAPPDATA%\Android\Sdk\platform-tools\adb.exe` 있음 (`source.properties` Revision 37.0.1) |
| JDK 17 | `%LOCALAPPDATA%\Android\jdk-17\bin\java.exe` 있음. Godot 에디터 설정 `export/android/java_sdk_path`가 이 경로를 가리킴 |
| SDK | `build-tools\34.0.0`, `platforms\android-34`, `cmdline-tools\latest`. `android_sdk_path`는 에디터 설정에 있음 |
| 시스템 Java | 22 (`C:\Program Files\Java\jdk-22`) |
| `docs\` | 이 문서가 처음 만든 파일 (`english_v11_design.md`는 아직 없음) |
| 저장소 | `main`, 작업 트리 깨끗 (읽은 시점), `.gitignore`에 `*.pem`, `*.key`, `secrets.json*`만 있고 키스토어 패턴 없음 |

---

## 1. 목표와 범위

### 1.1 목표
1. 안드로이드 폰에서 지금의 레슨·대화·읽기·복습·로드맵 화면을 쓴다. 처리(STT·TTS·채점·AI)는 같은 와이파이의 PC 백엔드가 한다.
2. 안전하게: 기본 꺼짐, 켜면 페어링한 기기만, 언제든 해제.
3. PC 앱 동작은 폰 연결을 안 쓰는 사람에게 바뀌지 않는다.
4. 서명된 APK를 GitHub 릴리스에 올릴 수 있다.

### 1.2 하지 않을 것
- 폰에서 백엔드/모델 실행, 인터넷 건너 접속(포트포워딩·터널), Google Play 등록, iOS.
- HTTPS(자체 서명 인증서 고정). 대신 공용 와이파이 경고 (§16 대안).
- 학습 기록 동기화 (1차는 폰이 자기 `user://` 기록을 따로 가짐. §15 로드맵 후보).
- Windows 방화벽 규칙을 앱이 만들거나 바꾸는 일. 사용자가 Windows 허용 창을 누르고, 앱은 안내 문구만 보여 준다.
- 폰에서 PC 마이크·PC 설정(AI 엔진 변경 등) 조작.
- 가로 화면·태블릿 최적화 (세로 고정, 넓은 화면은 가운데 열 + 여백).
- 기존 PC 화면 리디자인 (영어 v1.1 트랙과는 §11 위험 R17 참고).

---

## 2. 구조와 데이터 흐름

### 2.1 구조도

```
┌──────────────── 폰 (APK, Godot 4.6.3 gl_compatibility) ────────────────┐
│ main.gd 하단 탭바 ── views/* ── RecorderWidget ── Recorder(autoload)   │
│        │                              │  AudioStreamMicrophone→Record 버스
│  ConnectView / RemoteLinkPanel        └ 모노 WAV → audio_b64            │
│        │                                                               │
│  RemoteLink(core) ── Api(autoload, Bearer 토큰) ── Backend(원격 모드)   │
│  user://remote.json (token)    user://progress.json (폰 자체 기록)      │
└───────────┬───────────────────────────────┬────────────────────────────┘
            │ HTTP  :8775 (+ UDP 8776)      │
            ▼  같은 와이파이 (사설 IPv4)     │
┌──────────────────────────── PC ───────────┴────────────────────────────┐
│ 회화연습.exe (Godot, PC 모드)                                           │
│   PhoneLinkPanel ──HTTP 127.0.0.1:8770──┐   (/lan, /lan/code, ...)      │
│                                          ▼                              │
│ backend\server.py  (한 프로세스)                                         │
│   ├ 리스너 A: 127.0.0.1:8770  uvicorn(메인 스레드) → FastAPI app         │
│   │            토큰 없음. /lan/* 관리 가능. 지금과 동일                    │
│   ├ 리스너 B: 0.0.0.0:8775   uvicorn(보조 스레드, 켜면 시작·끄면 종료)     │
│   │            LanGate(ASGI) → 토큰 확인 → 허용 목록 → 같은 FastAPI app   │
│   ├ UDP 디스커버리: 0.0.0.0:8776 (보조 스레드, 켜짐+자동 찾기 켜짐일 때만) │
│   └ backend\lan_devices.json (토큰 SHA-256만, git 미추적)               │
└─────────────────────────────────────────────────────────────────────────┘
```

### 2.2 흐름 ① 페어링
```
PC 사용자: 설정 > 휴대폰 연결 켜기 ─▶ POST 127.0.0.1:8770/lan {"enabled":true}
   서버: 리스너 B·디스커버리 시작, 코드 생성 ─▶ GET /lan 에 code "482913", expires_in 300
   PC 화면: 주소 192.168.0.12:8775 · 코드 482 913 · 방화벽·공용 와이파이 안내
폰 ConnectView:
   (a) [PC 자동 찾기] UDP 브로드캐스트 {"hoehwa":1,"op":"discover"} → 응답 {"hoehwa":1,"op":"here","name":"MYPC","port":8775}
       또는 (b) 주소 직접 입력 "192.168.0.12" / "192.168.0.12:8775"
   GET http://ip:8775/hello → {"hoehwa":1,"name":"MYPC","pairing_open":true}   (토큰 없이 허용)
   POST /pair {"code":"482913","device_name":"Pixel 8"} → 200 {"token":"hp1_…","device_id":"a1b2c3d4","server_name":"MYPC","port":8775}
   폰: user://remote.json 저장 → Backend 원격 모드 READY → 메인 화면
```
### 2.3 흐름 ② 일반 요청
```
폰 view ─ Api.post_json("/chat", …) ─ 헤더 Authorization: Bearer hp1_… ─▶ :8775
   LanGate: ①토큰 SHA-256 → 등록 기기? 아니면 401 ②허용 목록 경로? 아니면 403 ③본문 16MB 초과? 413 ④FastAPI app 호출
   응답은 PC 앱과 동일 JSON. 401(token_invalid)이면 Api가 auth_failed 신호 → Backend NEEDS_PAIRING → ConnectView
```
### 2.4 흐름 ③ 녹음 (폰)
```
RecorderWidget 누름 → Recorder.begin()
   (처음) OS.request_permission("RECORD_AUDIO") → 거부 시 한국어 안내, finished(ok=false, reported=true)
   AudioStreamMicrophone 재생(버스 "Record": AudioEffectRecord → AudioEffectCapture(레벨) → Amplify -80 dB)
RecorderWidget 다시 누름 → Recorder.end() → record.get_recording() (mix rate 44.1/48 kHz, 스테레오일 수 있음)
   → 스레드에서 모노 16bit 변환 + 최대값(peak) 계산 → WAV 바이트 → base64
   → finished({ok, silent, duration, b64, wav, owner})   ← PC 모드와 같은 모양
뷰: Api.post_json("/stt" | "/score" | "/prosody", {"audio_b64": b64, …})  ← 기존 코드 그대로
```
### 2.5 흐름 ④ TTS 재생 (폰)
```
Tts.speak → Api.post_json("/tts") → WAV(24kHz 모노, 응답 본문) → WavUtil.from_wav_bytes → AudioStreamPlayer
```
변경 없음. 캐시·청크 분할 로직은 그대로(확인: tts.gd). 백그라운드로 가면 `Tts.stop()`만 추가.

---

## 3. 백엔드 계약 (W1)

### 3.1 바인딩 방식 (D2)

| 방식 | 장점 | 단점 | 결정 |
|---|---|---|---|
| A. 켜면 서버를 `0.0.0.0:8770`로 재시작 | 코드 단순, 포트 하나 | 재시작 15~60초, 진행 중 요청 끊김, 꺼도 되돌리려면 또 재시작 | 기각 |
| **B. 추가 리스너 `0.0.0.0:<lan.port>`** | 재시작 없음, 끄면 포트가 실제로 닫힘, 루프백 경로 불변 | 두 번째 uvicorn 서버를 스레드에서 돌려야 함 | **채택** |
| C. 특정 LAN IP에 같은 포트 8770 바인딩 | 포트 번호 하나 | IP가 바뀌면 깨짐, 어댑터 여러 개면 복잡 | 기각 |

구현 규칙 (W1):
- `lan.py`가 `socket`으로 미리 `bind`·`listen` 한 소켓을 만들고(포트 사용 중이면 그 자리에서 `OSError` → 409 `lan_port_busy`), `uvicorn.Server(Config(LanGate(app), lifespan="off", log_config=None, access_log=False, timeout_graceful_shutdown=2))`를 **새 스레드의 자기 이벤트 루프**에서 `asyncio.run(server.serve(sockets=[sock]))`로 돌린다.
- 끄기: `server.should_exit = True` → 스레드 `join(5)` → 소켓 닫기 → 포트가 닫힘.
- uvicorn 0.54.0(requirements 고정, 확인)에서 비주 스레드 실행이 되는지 W1이 먼저 시험한다 **(추측: `capture_signals`가 비주 스레드를 건너뜀)**. 안 되면 `Server.install_signal_handlers = lambda: None` 로 우회.
- 메인 리스너(`uvicorn.run(app, host="127.0.0.1", port=CFG["port"])`)와 `lifespan`(워밍업)은 건드리지 않는다. `lifespan` 시작에서 `lan.start_if_enabled()`, 끝에서 `lan.shutdown()`만 추가.
- `server.py`에는 약 15줄 연결만 넣는다: `import lan`, `DEFAULT_CONFIG["lan"]`, `app.include_router(lan.router)`, lifespan 두 줄, CLI 인자 `--lan-bind`(시험용, 기본 `0.0.0.0`). 나머지 로직은 모두 새 파일 `backend\lan.py`.
- 루프백 리스너에서도 `/lan/*` 관리 엔드포인트는 `request.scope.get("hoehwa_lan")`가 참이거나 `request.client.host`가 루프백이 아니면 403 `local_only` (이중 방어). `LanGate`는 `scope["hoehwa_lan"]=True`를 직접 넣고, 클라이언트가 보낸 같은 이름의 헤더는 무시한다.

### 3.2 `config.json`

```json
"lan": {"enabled": false, "port": 8775, "discovery": true, "discovery_port": 8776, "name": ""}
```
- 저장 대상: 켬 여부, 포트 둘, 자동 찾기 여부, 표시 이름(빈 문자열 = Windows 컴퓨터 이름). **토큰·코드·기기 목록은 넣지 않는다** (`publish_release.ps1`이 `config.json`의 `token` 필드를 막는 규칙과도 일관, 확인).
- `DEFAULT_CONFIG`(server.py)에 기본값을 넣고 `packaging\defaults\config.default.json`은 **고치지 않는다** (없어도 기본값 적용, `check_zip.py`의 바이트 동일 검사와 `mergecfg` 영향 없음).
- 시험 서버(`--port` 인자)는 지금처럼 `config.json`을 저장하지 않는다 (확인: `if not ARG_PORT: save_config`).
- **켠 상태는 재시작 후에도 유지**(앱 상단에 "폰 연결 켜짐" 표시). 오케스트레이터 확인 필요 (§17 Q1).

### 3.3 토큰·저장

| 항목 | 규칙 |
|---|---|
| 토큰 형식 | `hp1_` + base64url(32바이트 난수, 패딩 없음) = 47자. 정규식 `^hp1_[A-Za-z0-9_-]{43}$`. `secrets.token_bytes(32)` |
| 서버 저장 | `backend\lan_devices.json` (시험 서버에 `--tag t`가 있으면 `lan_devices-t.json`). **SHA-256 해시만** 저장하고 토큰 원문은 저장·로그 금지 |
| 파일 형식 | `{"version":1,"devices":[{"id":"a1b2c3d4","name":"Pixel 8","token_sha256":"<64 hex>","created":"2026-10-17T10:00:00+09:00","last_seen":"…","last_ip":"192.168.0.23"}]}` |
| 쓰기 | 임시 파일 `*.tmp` 작성 후 `os.replace` (config 저장과 같은 방식). `last_seen`은 메모리에 두고 60초에 한 번만 디스크에 반영 |
| 읽기 실패 | JSON이 깨졌으면 `*.bad`로 옮기고 빈 목록으로 시작, 경고 로그. 이전 토큰은 전부 무효 (fail-closed) |
| 비교 | `hmac.compare_digest`로 해시 비교 |
| 기기 수 | 최대 8대 (초과 시 409 `device_limit`) |
| git | `.gitignore`에 `backend/lan_devices*.json*` 추가 (W1) |
| 배포 제외 | `build_dist.ps1` robocopy `/XF`에 `lan_devices*.json*` 추가 + 패키지 안전망 검사에 추가, `check_zip.py` `BAD_NAME`에 추가, `uninstall.ps1` 삭제 대상에 추가 (W1 소유) |

### 3.4 엔드포인트

공통: 모든 오류 본문 = `{"error": "한국어 문장", "code": "<기계가 읽는 코드>"}`. `code`는 **이번에 새로 붙는 선택 필드**이고 기존 엔드포인트의 오류 본문은 그대로다 (Godot `Api`는 `error`만 읽음, 확인).

| 메서드·경로 | 어느 리스너 | 토큰 | 요청 | 성공 응답 |
|---|---|---|---|---|
| `GET /hello` | 둘 다 | 불필요 | – | `{"hoehwa":1,"name":"MYPC","pairing_open":true}` |
| `POST /pair` | LAN | 불필요 | `{"code":"482913","device_name":"Pixel 8"}` (`code`는 정확히 숫자 6자리 문자열, `device_name` 1~40자) | `{"token":"hp1_…","device_id":"a1b2c3d4","server_name":"MYPC","port":8775}` |
| `POST /lan/proof` | LAN | 불필요 | `{"device_id":"a1b2c3d4","nonce":"<hex 8~64자>"}` | `{"proof":"<hex>"}` = HMAC-SHA256(키=토큰의 SHA-256 바이트, 메시지=nonce UTF-8). 폰이 IP가 바뀐 PC를 다시 찾았을 때 토큰을 보내기 **전에** 진짜 그 PC인지 확인하는 용도 |
| `GET /lan/me` | LAN | 필요 | – | `{"device_id","name","server_name"}` |
| `POST /lan/unpair` | LAN | 필요 | – | `{"ok":true}` (자기 기기만 삭제) |
| `GET /lan` | 루프백만 | – | – | 아래 3.4.1 |
| `POST /lan` | 루프백만 | – | `{"enabled":bool?, "discovery":bool?, "port":int?, "discovery_port":int?, "name":str?}` (모두 선택, 포트 1024~65535) | `GET /lan`과 같은 모양 |
| `POST /lan/code` | 루프백만 | – | `{}` 또는 `{"cancel":true}` | `{"code":"482913","expires_in":300}` / `{"ok":true}` |
| `POST /lan/devices/revoke` | 루프백만 | – | `{"id":"a1b2c3d4"}` 또는 `{"all":true}` | `{"ok":true,"revoked":1}` |

(해제는 DELETE 대신 POST를 쓴다: `Api`에 `post_json`만 있어 W2 변경이 작다.)

#### 3.4.1 `GET /lan` 응답
```json
{"enabled": true, "listening": true, "port": 8775, "bind": "0.0.0.0",
 "discovery": true, "discovery_listening": true, "discovery_port": 8776,
 "name": "MYPC", "addresses": ["192.168.0.12"],
 "pairing": {"active": true, "code": "482913", "expires_in": 274, "locked": false, "attempts_left": 5},
 "devices": [{"id": "a1b2c3d4", "name": "Pixel 8", "created": "…", "last_seen": "…", "last_ip": "192.168.0.23"}],
 "error": ""}
```
- `pairing.code`는 `active`일 때만 문자열, 아니면 `null`. 토큰·해시는 어떤 응답에도 없다.
- `addresses`: 사설 IPv4(10.x, 172.16~31.x, 192.168.x)만 최대 3개, 링크로컬(169.254)·루프백 제외. 기본 경로 IP는 UDP 소켓을 `connect(("10.255.255.255",1))`만 하고 얻는다 (패킷 전송 없음).
- `error`: 비치명 문제의 한국어 설명 (예: 자동 찾기 포트 사용 중 → LAN은 켜지고 `discovery_listening:false`).

#### 3.4.2 켜고 끄기 규칙
- `enabled:true` → 소켓 bind 성공이 먼저. 실패면 `enabled`는 false로 남고 409 `lan_port_busy`. 성공하면 코드를 자동 생성.
- `enabled:false` → 리스너 B·디스커버리 종료, 코드 폐기. **등록 기기는 유지**(다시 켜면 그대로 쓸 수 있음).
- `port`·`discovery_port` 변경은 켜져 있으면 해당 리스너를 재시작한다.

#### 3.4.3 페어링 코드 규칙

| 항목 | 값 |
|---|---|
| 형식 | `secrets.randbelow(10**6)` 6자리, 앞 0 유지 |
| 유효 시간 | 300초 (시험용 환경변수 `HOEHWA_LAN_CODE_TTL`은 `HOEHWA_TEST_HOOKS=1`일 때만 읽음) |
| 사용 | 1회용. 성공하면 즉시 폐기 |
| 틀림 | 5번까지 `401 code_invalid` (`attempts_left` 4,3,2,1,0). **5번째 실패에서 코드를 폐기하고 잠금**. 6번째부터 `429 pair_locked` (맞는 코드를 보내도). PC에서 `POST /lan/code`를 누르거나 껐다 켜야 풀림 |
| 코드 없음/만료 | `410 no_active_code` (실패 횟수에 세지 않음) |
| 형식 오류 | `400 code_format` (세지 않음) |
| 비교 | `hmac.compare_digest` |

### 3.5 LAN 허용 목록과 오류 코드

LAN 리스너(`LanGate`) 순서: ① 스코프 종류가 http가 아니면 거부 ② 토큰 불필요 경로(`GET /hello`, `POST /pair`, `POST /lan/proof`) 통과 ③ 토큰 확인 ④ 허용 목록 확인 ⑤ 본문 크기 확인 ⑥ 앱 호출. 허용 목록(메서드·경로):

`GET /health` · `GET /curriculum` · `POST /tts` · `GET /tts/voices` · `POST /stt` · `POST /score` · `POST /prosody` · `POST /chat` · `POST /feedback` · `POST /fix` · `POST /lesson` · `POST /reading/analyze` · `POST /reading/gloss` · `GET /examples` · `GET /lan/me` · `POST /lan/unpair`

그 밖 전부(`/mic/*`, `/llm*`, `/lan`, `/lan/code`, `/lan/devices/*`, `/debug/*`, `/docs`, `/openapi.json`)는 403.

| HTTP | code | 언제 | 한국어 `error` (예) |
|---|---|---|---|
| 400 | `code_format` | 코드가 숫자 6자리가 아님 | 연결 코드는 숫자 6자리예요. |
| 401 | `token_missing` | LAN 요청에 `Authorization` 없음 | 이 PC에 연결되지 않았어요. 연결 코드를 입력해 주세요. |
| 401 | `token_invalid` | 틀린·해제된 토큰, `Bearer` 형식 아님 | 이 휴대폰의 연결이 해제됐어요. 다시 연결해 주세요. |
| 401 | `code_invalid` | 틀린 코드. 본문에 `attempts_left` | 코드가 맞지 않아요. 남은 기회 N번. |
| 403 | `lan_forbidden` | 허용 목록 밖 경로 | 휴대폰에서는 쓸 수 없는 기능이에요. |
| 403 | `local_only` | LAN 리스너로 온 관리 요청 | 이 PC에서만 할 수 있어요. |
| 404 | `device_not_found` | 해제/증명할 기기 없음 | 연결된 기기를 찾지 못했어요. |
| 409 | `lan_port_busy` | 포트 bind 실패 | 포트 N을 다른 프로그램이 쓰고 있어요. |
| 409 | `lan_off` | 꺼진 상태에서 `/lan/code` | 휴대폰 연결이 꺼져 있어요. |
| 409 | `device_limit` | 기기 8대 초과 | 연결할 수 있는 휴대폰이 가득 찼어요(최대 8대). |
| 410 | `no_active_code` | 코드 없음·만료·사용됨 | 연결 코드가 없거나 시간이 지났어요. PC에서 새 코드를 만들어 주세요. |
| 413 | `too_large` | 본문 16 MB 초과 (헤더·누적 바이트 둘 다 검사) | 보낸 데이터가 너무 커요. |
| 429 | `pair_locked` | 코드 5번 실패 후 | 코드를 너무 많이 틀려서 잠겼어요. PC에서 새 코드를 만들어 주세요. |
| 429 | `rate_limited` | 같은 IP에서 토큰 실패 30회/10분 | 잠시 뒤에 다시 시도해 주세요. |

`Authorization` 파싱: 스킴은 대소문자 무시(`Bearer`/`bearer`), 토큰은 정규식으로 먼저 형식 검사 후 해시 비교. 토큰·`Authorization` 헤더는 로그에 남기지 않는다 (기존 `_timing` 미들웨어는 경로만 기록, 확인).

### 3.6 디스커버리 UDP

| 항목 | 규칙 |
|---|---|
| 소켓 | UDP `0.0.0.0:<discovery_port>`, `SO_REUSEADDR` 쓰지 않음, 켜짐+`discovery:true`일 때만 열림. 끄면 닫혀서 다른 프로그램이 같은 포트를 bind 할 수 있어야 함 |
| 요청 | UTF-8 JSON, 128바이트 이하: `{"hoehwa":1,"op":"discover"}` (키가 정확히 이 값일 때만) |
| 응답 | 보낸 곳으로 **유니캐스트**: `{"hoehwa":1,"op":"here","name":"MYPC","port":8775}` — 키는 정확히 이 4개 (IP·버전·기기 목록 없음) |
| 그 밖 | 모르는 형식·너무 큰 패킷·JSON 아님은 **무응답**. 초당 응답 10개 상한 |
| 폰 쪽 | `255.255.255.255:8776`와 각 사설 IP의 `/24` 브로드캐스트(`a.b.c.255`) 둘 다 보냄, 2.5초 대기, 응답 패킷의 **송신 IP**를 PC 주소로 사용 |

### 3.7 기존 엔드포인트 영향

| 항목 | 영향 |
|---|---|
| `GET /health`, `/stt`, `/score` 등 | 요청·응답 모양 변화 없음. 루프백 리스너는 토큰 불필요 그대로 |
| 오류 본문 | 새 엔드포인트와 LAN 게이트에서만 `code` 추가 |
| `/mic/*` | LAN에서 403, 루프백 동작 그대로 |
| `/llm` POST | LAN에서 403 (폰 설정 화면은 AI 엔진 영역을 숨김) |
| `API.md` | "휴대폰 연결" 절 추가 (W1) |
| 성능 | LAN 리스너가 꺼져 있으면 추가 비용 없음 |

---

## 4. Godot 계약 (W2 주담당, 일부 Phase 0)

### 4.1 분기 규칙
`scripts/core/platform.gd`(Phase 0, 오케스트레이터가 작성, 아래 코드 그대로)만 플랫폼을 판정한다. 다른 파일은 `OS.has_feature("android")`를 직접 쓰지 않고 `Platform.*`을 쓴다. 단 마이크·권한 호출은 `Platform.is_android()`일 때만.

```gdscript
class_name Platform
extends RefCounted
## android = 실제 안드로이드 기기. phone = 안드로이드 또는 데스크톱 시험용 `-- --phone`.
static func is_android() -> bool:
	return OS.has_feature("android")
static func is_phone() -> bool:
	return OS.has_feature("android") or OS.get_cmdline_user_args().has("--phone")
static func is_pc() -> bool:
	return not is_phone()
```

| 시험 인자 (`godot ... -- <인자>`) | 뜻 |
|---|---|
| `--phone` | 데스크톱에서 폰 모드(원격 모드 + 폰 레이아웃)로 실행. **데스크톱에서는 Godot 마이크를 절대 열지 않는다** (WASAPI 크래시, 확인: README) |
| `--api=http://ip:port` | 기존. 폰 모드에서는 이 주소를 원격 주소로 사용 |
| `--token=hp1_…` | 시험 전용: 토큰 주입. `--api=`가 같이 있을 때만 유효 |
| `--remote-file=user://x.json` | 시험 전용: 연결 정보 파일 경로 (실제 `remote.json`을 건드리지 않기 위함) |

### 4.2 Phase 0 스텁 (오케스트레이터가 만들고 커밋 후 worktree 분기)
빈 껍데기라도 `class_name`이 있어야 다른 작업자가 컴파일할 수 있다. 공개 시그니처는 이 문서가 계약이다.

| 파일 | 스텁 내용 (계약) |
|---|---|
| `godot/scripts/core/platform.gd` | 위 코드 전체 (완성품) |
| `godot/scripts/autoload/backend.gd` | **두 줄만** 추가: enum 끝에 `NEEDS_PAIRING`, `var remote_mode: bool = false`. 이후 소유자는 W2 |
| `godot/scripts/core/remote_link.gd` | `class_name RemoteLink extends RefCounted` + §4.5 시그니처 (본문은 `return {}` 등) |
| `godot/scripts/ui/connect_view.gd` | `class_name ConnectView extends Control` + `signal connected` + `signal cancelled` |
| `godot/scripts/ui/phone_link_panel.gd` | `class_name PhoneLinkPanel extends VBoxContainer` (PC 설정 카드, 인자 없는 `new()`) |
| `godot/scripts/ui/remote_link_panel.gd` | `class_name RemoteLinkPanel extends VBoxContainer` (폰 설정 카드) + `signal change_requested` |
| 확인 명령 | `& $GODOT --headless --path D:\Ai\언어\app\godot --import` 후 `& $GODOT --headless --path D:\Ai\언어\app\godot --quit` 종료코드 0, 출력에 `SCRIPT ERROR`·`Parse Error` 0건 (새 `class_name`은 import로 캐시에 등록해야 함) |

### 4.3 `Api` (W2)

| 변경 | 내용 |
|---|---|
| 상태 | `var token: String = ""`, `func set_remote(base_url, token)`, `func clear_remote()`, `signal auth_failed(code: String)` |
| 헤더 | `token != ""`이면 모든 요청에 `Authorization: Bearer <token>`. `RemoteLink.hello/pair/proof` 호출에는 **붙이지 않는 별도 경로**(`get_json_to(base, path)` 등) |
| 오류 결과 | 결과 딕셔너리에 `err_code: String`(서버 `code`, 없으면 `""`) 추가. 기존 키는 그대로 |
| 401 | `err_code`가 `token_missing`/`token_invalid`이고 `token != ""`이면 `auth_failed` 방출 (한 번에 한 번만) |
| 폰 모드 시작값 | `base_url = ""`. 연결 전 요청은 네트워크를 쓰지 않고 즉시 실패(`"PC에 연결되지 않았어요."`). 폰에서 `127.0.0.1:8770`으로 가는 요청은 없어야 함 |
| 전송 오류 문구 | 폰이면 "AI 엔진에 연결하지 못했어요" 대신 "PC에 닿지 않아요. PC가 켜져 있고 같은 와이파이인지, PC 앱의 '휴대폰 연결'이 켜져 있는지 확인해 주세요." |
| 재시도 | 연결 끊김(`RESULT_CANT_CONNECT`/`CONNECTION_ERROR`)이나 앱이 막 복귀했을 때의 실패에 한해 **멱등 경로만 1회 자동 재시도**: 모든 GET, `/tts`, `/stt`, `/score`, `/prosody`, `/reading/*`. `/chat`·`/feedback`·`/lesson`·`/fix`는 재시도하지 않음(화면의 "다시 보내기" 사용) |
| 시험 인자 | `--api=`(기존), `--token=`, `--remote-file=` 처리 |
| 타임아웃 | 폰 모드에서 `TIMEOUT_SHORT` 60→90초 (큰 업로드·느린 와이파이) |

### 4.4 `Backend` (W2)

| 변경 | 내용 |
|---|---|
| `remote_mode` | `Platform.is_phone()`이면 `_ready`에서 true |
| `start()` | 원격이면 `_start_remote()`로 분기. **원격 모드에서는 `find_backend_dir`·`python_path`·`OS.create_process`가 호출되면 안 됨** (`pid==-1`, `launched_by_us==false` 유지) |
| `_start_remote()` | ① `RemoteLink.load_saved()`가 비어 있으면 `NEEDS_PAIRING` (네트워크 요청 0건). ② 있으면 `Api.set_remote(...)` 후 `/health`(3초). 성공 → `READY`. ③ 실패 → 같은 PC를 `RemoteLink.discover()`로 다시 찾고 이름이 같고 `/lan/proof`가 맞으면 주소 갱신 후 재시도, 아니면 `FAILED`(문구: "PC에 닿지 않아요 …") |
| `auth_failed` | `NEEDS_PAIRING`으로 전환, 파일에서 토큰만 지움(주소·PC 이름은 남겨 ConnectView에 미리 채움), 메시지 "PC에서 이 휴대폰의 연결이 해제됐어요. 다시 연결해 주세요." |
| 주기 확인 | 기존 15초 `/health` 폴링 유지. 폰이 `NOTIFICATION_APPLICATION_PAUSED` 동안은 중지, `RESUMED`에 즉시 1회 |
| `shutdown()` | 원격 모드에서는 아무 것도 죽이지 않음 |
| PC 모드 | 지금과 한 줄도 다르지 않게 (`_adopt_config_port` 등 그대로) |

### 4.5 `RemoteLink` (core, W2) 공개 계약
```gdscript
const PATH := "user://remote.json"          # {"v":1,"base_url","token","device_id","server_name","paired_at"}
const DEFAULT_PORT := 8775
const DISCOVERY_PORT := 8776
static func parse_address(text: String) -> Dictionary   # {ok, host, port, base_url, error}   IPv4(+선택 :포트)만. "http://", 끝 "/" 허용
static func discover(tree: SceneTree, timeout_sec: float = 2.5) -> Array   # await 가능. [{name, host, port, base_url}], 없으면 []
static func hello(base_url: String) -> Dictionary       # await. {ok, name, pairing_open, err_code, error}
static func pair(base_url: String, code: String, device_name: String) -> Dictionary  # await. {ok, token, device_id, server_name, err_code, error, attempts_left}
static func proof_ok(base_url: String, conn: Dictionary) -> bool   # await. /lan/proof 를 nonce 로 호출해 HMAC 검증
static func save(conn: Dictionary, path: String = PATH) -> bool
static func load_saved(path: String = PATH) -> Dictionary          # 없음·깨짐 → {}
static func clear_token(path: String = PATH) -> void
```
HMAC 계산: `Crypto.new().hmac_digest(HashingContext.HASH_SHA256, token.sha256_buffer(), nonce.to_utf8_buffer())` (메서드 이름은 4.6.3 클래스 레퍼런스로 확인 **(추측)**).

### 4.6 `Recorder` (W2) — 안드로이드 분기

공개 인터페이스(`begin/end/cancel/finished/started/recording/stopping/elapsed/level/owner_id/MAX_SECONDS/input_devices/refresh_devices/apply_device`)는 **그대로**다. `RecorderWidget`·뷰는 안 고친다.

| 상황 | 동작 |
|---|---|
| PC (`not Platform.is_phone()`) | 지금 코드 그대로 (`/mic/*`) |
| 안드로이드 (`Platform.is_android()`) | Godot 녹음. 버스 `"Record"`를 코드로 만든다: `AudioEffectRecord`(16bit) → `AudioEffectCapture`(레벨 계산) → `AudioEffectAmplify`(−80 dB, 되울림 방지). `AudioStreamPlayer`+`AudioStreamMicrophone`을 이 버스로 재생 |
| 데스크톱 `--phone` | Godot 마이크를 열지 않는다. `Recorder.test_audio_source: Callable`(→ `AudioStreamWAV`)이 설정돼 있으면 그것으로, 없으면 `finished({ok:false, reported:true})`+Toast "이 환경에서는 마이크를 쓸 수 없어요(시험 모드)". `/mic/*` 호출 0건 |
| 권한 | 처음 `begin()`: `OS.get_granted_permissions()`에 RECORD_AUDIO 없으면 Toast "마이크 권한이 필요해요. 다음 창에서 '허용'을 눌러 주세요" → `OS.request_permission("RECORD_AUDIO")` → `get_tree().on_request_permissions_result` 로 결과 대기(최대 60초). 거부면 `finished({ok:false, reported:true})` + Toast "마이크 권한이 꺼져 있어요. 휴대폰 설정 > 앱 > 회화 연습 > 권한 > 마이크를 허용해 주세요." (한 번 더 안 묻는 '다시 묻지 않음' 상태 포함). API 이름은 4.6.3 클래스 레퍼런스로 확인 **(추측)** |
| 변환 | `end()`에서 `AudioEffectRecord.get_recording()`(mix rate 44.1/48 kHz, 스테레오일 수 있음) → `WavUtil.to_mono16(stream) -> AudioStreamWAV`(스테레오면 평균, 샘플레이트 유지, 16bit) → 별도 스레드(`WorkerThreadPool`)에서 실행해 화면이 멈추지 않게. peak 계산해 `silent = peak < 0.003`(서버와 같은 기준, 확인: server.py `mic_stop`) |
| 결과 | `{ok, silent, duration, b64, wav, owner}` — PC 모드와 같은 키 (+`stream`은 옵션) |
| 길이 | `MAX_SECONDS = 30` 유지. 30초 모노 48 kHz 16bit ≈ 2.9 MB, base64 ≈ 3.8 MB |
| 레벨 | `AudioEffectCapture.get_buffer()`로 RMS→0..1, 프레임마다 |
| 생명주기 | `NOTIFICATION_APPLICATION_PAUSED`: 녹음 중이면 `cancel()` + `Tts.stop()`. 마이크를 백그라운드에서 열어 두지 않는다 |
| 장치 | `input_devices()`는 `["Default"]`만, `refresh_devices()`는 아무 일도 안 함 |

`WavUtil.to_mono16`은 W2 소유 `wav_util.gd`에 추가하고 단위 시험한다 (스테레오 입력 → 샘플 수 동일·최대값 보존).

### 4.7 `Tts` (W2)
`NOTIFICATION_APPLICATION_PAUSED`에서 `stop()` 한 줄. 나머지 변경 없음.

### 4.8 새 화면

#### (가) 폰 `ConnectView` (W2, `ui/connect_view.gd`)
전체 화면 `Control`. `main.gd`가 `Backend.status == NEEDS_PAIRING`일 때, 또는 설정에서 "연결 변경"을 눌렀을 때 `CanvasLayer(layer=25)`에 올린다 (스플래시 20, 토스트 30 사이). 성공하면 `connected` 방출 후 스스로 닫는다.

```
┌ 내 PC에 연결 ────────────────┐
│ 같은 와이파이의 PC에서 회화 연습을 켜고 │
│ 설정 > 휴대폰 연결을 켜 주세요.        │
│ [ PC 자동 찾기 ]  (찾는 중… 2.5초)    │
│  ○ MYPC  192.168.0.12                │   ← 찾은 목록, 누르면 아래 칸에 채움
│ 또는 주소 직접 입력                    │
│ [ 192.168.0.12:8775        ]          │   ← 포트 생략 가능(8775)
│ 연결 코드 (PC 화면의 6자리)            │
│ [ 482913 ]   ← 숫자 키패드             │
│ 이 휴대폰 이름 [ Pixel 8 ]             │   ← OS.get_model_name()
│ [ 연결 ]                              │
│ (오류 안내 영역)                       │
└───────────────────────────────────┘
```
- 단계: `parse_address` → `hello`(PC 닿는지, `pairing_open` 확인) → `pair` → `save` → `Api.set_remote` → `Backend.start()` 재호출.
- 코드 입력은 공백·하이픈 제거 후 숫자 6자리 검사. `LineEdit.virtual_keyboard_type = KEYBOARD_TYPE_NUMBER`, `max_length`.
- 오류 문구 표:

| 상황 | 문구 |
|---|---|
| 접속 실패/시간 초과 | PC에 닿지 않아요. ① PC 앱에서 '휴대폰 연결'이 켜져 있나요? ② 폰과 PC가 같은 와이파이인가요? ③ PC에 뜬 Windows 방화벽 허용 창을 눌렀나요? ④ 공공·게스트 와이파이는 기기끼리 통신을 막는 경우가 많아요. |
| `/hello`가 404 | 이 PC의 회화 연습이 옛 버전이에요. PC 앱을 1.1.0 이상으로 업데이트해 주세요. |
| `pairing_open:false` | PC에서 '새 코드 만들기'를 눌러 주세요. |
| `code_invalid` | 코드가 맞지 않아요. 남은 기회 N번. |
| `pair_locked` | 코드를 너무 많이 틀려서 잠겼어요. PC에서 새 코드를 만들어 주세요. |
| `no_active_code` | 코드 시간이 지났거나 이미 썼어요. PC에서 새 코드를 만들어 주세요. |
| `device_limit` | 연결할 수 있는 휴대폰이 가득 찼어요(최대 8대). PC에서 안 쓰는 기기를 해제해 주세요. |
| 주소 형식 | 주소를 확인해 주세요. 예: 192.168.0.12 또는 192.168.0.12:8775 (이름 대신 숫자 주소만 쓸 수 있어요) |

#### (나) 폰 설정 카드 `RemoteLinkPanel` (W2, `ui/remote_link_panel.gd`)
`TodayView` 설정 맨 위에 들어간다 (W3가 마운트). 내용: 상태 점(연결됨/안 됨), PC 이름·주소, [연결 변경] (`change_requested`), [연결 끊기] (`POST /lan/unpair` 시도 후 로컬 토큰 삭제), 마이크 권한 상태 줄("마이크: 허용됨/꺼짐" + 안내).

#### (다) PC 설정 카드 `PhoneLinkPanel` (W2, `ui/phone_link_panel.gd`)
`TodayView` 설정에서 "AI 엔진" 아래에 들어간다 (W3가 마운트, **PC 모드에서만**). 패널이 보이는 동안 `GET /lan`을 2초마다 폴링(꺼짐일 때는 보일 때 한 번).

```
휴대폰 연결                               [ 꺼짐 ◯── ]   ← 기본 꺼짐
 켜면 같은 와이파이의 내 휴대폰이 이 PC의 AI 엔진을 쓸 수 있어요.
 켜기 전에 읽어 주세요 (접는 상자, 켜는 순간 펼쳐서 한 번 보여 줌)
 [켜짐일 때]
  주소  192.168.0.12:8775        연결 코드  482 913   (4:32 안에 입력)
  [ 새 코드 만들기 ]
  연결된 휴대폰 (1)
   Pixel 8 · 3분 전 · 192.168.0.23                [ 연결 해제 ]
  [ 모두 해제 ]
  ⚠ 공용 와이파이 경고 / 방화벽 안내 (아래 문구)
```
- 문구(그대로 사용):
  - 설명(꺼짐): "켜면 같은 와이파이에 있는 내 휴대폰의 회화 연습 앱이 이 PC의 AI 엔진을 쓸 수 있어요. 끄면 외부 연결 포트가 바로 닫혀요. 연결 코드를 입력한 휴대폰만 쓸 수 있어요."
  - 경고(켜는 순간·켜진 동안 표시): "카페·학교·호텔 같은 공용 와이파이에서는 켜지 마세요. 휴대폰과 PC 사이의 통신은 암호화되지 않아서 같은 와이파이의 다른 사람이 볼 수 있어요. 집이나 내가 관리하는 와이파이에서만 쓰세요. 안 쓸 때는 꺼 두세요."
  - 방화벽: "처음 켜면 Windows가 '이 앱이 네트워크에서 통신하도록 허용하시겠습니까?' 창을 띄워요. '개인 네트워크'를 체크하고 '액세스 허용'을 눌러 주세요. 창이 안 보이면 작업 표시줄을 확인해 보세요. 이 프로그램은 방화벽 설정을 직접 바꾸지 않아요. 그래도 폰에서 안 잡히면: 설정 > 네트워크 및 인터넷 > 와이파이 > 이 네트워크의 '네트워크 프로필'이 '개인'인지 확인하세요. 회사·학교 와이파이는 기기끼리 통신을 막는 경우가 많아요."
  - 잠김: "코드를 5번 틀려서 잠겼어요. '새 코드 만들기'를 눌러 주세요."
  - 포트 사용 중: "포트 8775를 다른 프로그램이 쓰고 있어요. 다른 프로그램을 끄거나 아래 '고급'에서 포트를 바꿔 주세요."
  - 자동 찾기 포트 실패: "자동 찾기를 켜지 못했어요(포트 8776 사용 중). 휴대폰에서 주소를 직접 입력하면 연결할 수 있어요."
- "고급" 접이식: 자동 찾기 on/off, LAN 포트, 표시 이름.
- 켜져 있는 동안 `main.gd`(W3) 상단 상태 줄에 "폰 연결 켜짐" 점이 보인다. 이를 위해 `PhoneLinkPanel`과 별개로 `Backend`가 15초 `/health` 갱신 때 `GET /lan`을 한 번 더 부르지 않는다 — 대신 `PhoneLinkPanel`이 마지막 상태를 `Store`가 아닌 자기 정적 변수 `PhoneLinkPanel.last_enabled`에 두고 `main.gd`가 읽는다 (W3는 읽기만).

---

## 5. 폰 화면 설계 (W3)

### 5.1 공통

| 항목 | 규칙 |
|---|---|
| 논리 해상도 | 412×915 (프로젝트 설정은 W4: `display/window/size/viewport_width.android=412`, `viewport_height.android=915`, `stretch/mode.android="canvas_items"`, `stretch/aspect.android="expand"`). 물리 1080×2400 폰이면 배율 약 2.62, 논리 높이는 기기에 따라 늘어남 |
| 데스크톱 시험 | `godot ... --resolution 412x915 -- --phone` (데스크톱은 스트레치 없음 → 창 크기 = 논리 크기) |
| `main._setup_window()` | `Platform.is_phone()`이면 **전부 건너뜀** (지금 코드는 안드로이드에서 `screen_get_scale()`>1이면 창 크기를 1280×800 기준으로 바꿔 버림, 확인: main.gd 36~48행) |
| 안전 영역 | `PhoneLayout.safe_insets()` = `DisplayServer.get_display_safe_area()`·창 크기로 계산한 상/하/좌/우 논리 px. 상단 상태 줄과 하단 탭바에 더한다. 엣지-투-엣지 여부는 기기마다 달라 **실기 확인**(S5) |
| 상단 | 40px 얇은 줄: "회화 연습" + 상태 점·텍스트("PC 연결됨"/"PC 연결 안 됨"/"연결 필요"). 누르면 설정(오늘 탭의 설정 펼침)으로 |
| 탭 | 데스크톱 상단 탭 6개는 폭 900+가 필요 → 폰은 **하단 탭바** 6칸(오늘·레슨·대화·읽기·복습·로드맵), 높이 56 + 하단 안전 영역, 칸마다 터치 영역 ≥ 48×56. 키보드가 올라오면 탭바를 숨김 |
| 여백 | `ColumnBox.min_pad` 20→16, `max_width`는 무시(폭이 이미 좁음). `PageScroll(max_w)`의 인자는 폰에서 `1e6`로 취급 |
| 글자 | 기본 16→17, "Small" 13→14, 부제 12→13. 일본어 글꼴·IPA 글꼴 확인 항목은 §11 R12 |
| 터치 대상 | 모든 버튼·옵션·체크 행 **높이 ≥ 48**, 링크 버튼(`UI.link_button`) ≥ 44, 타일 ≥ 48. 폰에서 `UI.button` 기본 `min_h`=48 (호출부가 더 크게 주면 그 값) |
| 스크롤 | `ScrollContainer.scroll_deadzone`≈12, 버튼 위에서 시작한 드래그도 스크롤로 인정되는지 실기 확인(S7) |
| 키보드 | `PhoneLayout.keyboard_height()` = `DisplayServer.virtual_keyboard_get_height()` ÷ (창 픽셀 폭 ÷ 논리 폭). `main.gd`가 `_process`에서 읽고 `_content` 아래쪽 여백으로 반영, 탭바 숨김. 입력창이 있는 뷰(대화·복습·읽기)는 포커스 시 `ensure_control_visible`. 안드로이드가 창을 직접 올려 주는 기기(`adjustPan` 추정)에서는 높이가 0일 수 있음 **(추측, 실기 S6)** |
| 뒤로 가기 | `NOTIFICATION_WM_GO_BACK_REQUEST`: 하위 화면(읽기 리더·대화 중·ConnectView)이면 한 단계 뒤로, 다른 탭이면 "오늘"로, 오늘 탭이면 2초 안에 두 번째 누름일 때 종료(첫 번째에 토스트 "한 번 더 누르면 종료돼요"). `application/config/quit_on_go_back=false`(W4) |
| 데스크톱 전용 문구 | "Ctrl+V", "Ctrl+Enter", "스페이스바", 툴팁은 폰에서 숨기거나 바꾼다 (`use_space=false`) |
| 토스트 | 최소 폭 420→`min(420, 폭−32)`, 위치는 탭바·키보드 위 |
| 스플래시 | 폭 520→`폭−32`. 폰은 "PC 연결 중…" 문구와 [다시 시도] [PC 다시 찾기] |

### 5.2 뷰별 변경 (W3)

| 파일 | 지금 (확인) | 폰에서 바꿀 것 |
|---|---|---|
| `main.gd` | 상단 `TABS` 6개 버튼+상태 점, `_banner`, 스플래시 520px, 토스트 420px, `_setup_window` | 하단 탭바 추가(`ui/bottom_tabs.gd` 신규), 상단 줄 축소, 배너 문구 줄바꿈+버튼 아래로, `NEEDS_PAIRING`이면 `ConnectView` 표시, 뒤로 가기, 키보드 여백, `_setup_window` 건너뜀, PC 모드 코드 경로는 그대로 |
| `today_view.gd` | `PageScroll(1040)`, `_grid` 열 수 `size.x>=980 ? 2 : 1`(이미 폰=1열), 언어 카드 머리 `hbox`(이름+한글명+spacer+칩), 버튼 2개 `hbox`, 설정: `_voice_row`(라벨 60+옵션 260+미리듣기), 속도(슬라이더 최소 240+라벨 60+버튼 2개), 마이크(옵션 320), AI 엔진(옵션 320), 시작일 입력 | 칩은 이름 아래 줄로(HFlow). 음성·속도·마이크·엔진 행은 **세로로 쌓기**(`UI.adaptive(sep)` = PC는 HBox, 폰은 VBox). 설정 맨 위에 `RemoteLinkPanel`, PC 모드에서만 `PhoneLinkPanel`. 폰에서는 **AI 엔진 구역 숨김**(PC 설정이라 403), 마이크 장치 선택 숨기고 "마이크 테스트"와 권한 상태만, "모든 기록 지우기"는 "이 휴대폰의 기록만 지워져요" 문구. 슬라이더 높이 ≥ 40 |
| `lesson_view.gd` | `PageScroll(720)`+푸터 `ColumnBox(720)`, 선택 화면: 월/주 옵션 `fields` `hbox`(L437), 출처 분할 버튼 라벨이 김("실제 예문 레슨 (빠름)"/"AI 레슨 (느림)", L446), 통계/버튼 `hbox`(L505~531), 문제: `option_row`·타일 flow(OK)·듣기 버튼 88×72, 말하기: `RecorderWidget(big)` 190×58+안내 열 130, 결과 `ScorePanel`+`ProsodyPanel` | `fields`는 세로 쌓기, 출처 라벨 단축("실제 예문 (빠름)"/"AI (느림)")하거나 두 줄, 통계는 flow, 푸터 버튼 행(L830)은 전체 폭 버튼 쌓기, 푸터 아래 안전 영역, 말하기 영역은 `RecorderWidget` 폰 변형, 힌트 텍스트 줄바꿈 |
| `talk_view.gd` | 설정: 시나리오 격자 `3 if size.x>=900 else 2`(폰=2열 OK), 수준·월 옵션 `fields` `hbox`; 채팅 머리(아바타 42+제목+"대화 끝내고 피드백" 버튼), 말풍선 `max_w = clamp(w*0.72-40, 260, 620)`, 말풍선 액션 `hbox`(듣기·천천히·번역…), **하단: 입력창+마이크(작은 위젯 96)+보내기 한 줄**, 옵션 체크 4개 flow | 시나리오 카드 높이 ≥ 64, `fields` 세로, 머리 버튼은 "끝내기"(44px), 말풍선 최대 폭 `폭×0.86`, 액션은 flow+각 44px, **하단 패널 2줄**: 1줄 입력창(확장)+보내기(56×48), 2줄 큰 마이크 버튼(전체 폭 56px, 길게/짧게 누름 둘 다 지원) → 폰에선 마이크가 주 입력. 옵션 체크 4개는 "옵션 ▾" 접힘. 키보드 높이만큼 하단 패널 위로, 변경 시 `scroll_to_bottom`. 피드백 화면은 그대로 쌓임 확인 |
| `reading_view.gd` | `PageScroll(860)`, 초안 `TextEdit` 260, 버튼 행(예시·글자 수·spacer·분석 180px), 리더는 `NARROW_W=1000` 미만이면 이미 위/아래 분할(`_narrow`), 단어 패널 `size.y*0.46`, 머리 `row1`(뒤로+칩+제목?+글자 크기 분할), 문구 "Ctrl+V" | 버튼 행 줄바꿈(분석 버튼 전체 폭), **[붙여넣기] 버튼 추가**(`DisplayServer.clipboard_get()` → `insert_text_at_caret`; 폰에는 Ctrl+V가 없음), "Ctrl+V/Ctrl+Enter" 문구 제거, 리더 기본 글자 크기를 "크게", 줄 간격 +6, 단어 패널에 닫기(×) 48px, 머리는 2줄, 단어 탭 대상은 줄 간격으로 확보 |
| `review_view.gd` | `PageScroll(720)`, 말하기 `RecorderWidget(big)`(L266), 입력 `LineEdit`(L274), 버튼 행 여러 개(L193, 224, 342, 371) | 버튼 행은 세로 쌓기·전체 폭, `RecorderWidget` 폰 변형, `LineEdit` 포커스 시 보이게, 하단 안전 영역 |
| `roadmap_view.gd` | 단계 카드 격자 `4 if size.x>=1000 else 2`, 월 머리 `num 60 + mid + right 72`, 내용 행 `k 96 + v` | 격자 1열, 월 머리 세로 터치 높이 ≥ 64, 내용 행은 `k`를 `v` 위로(세로) |
| `ui/recorder_widget.gd` | 버튼 190×58(큰) / 96×44(작은), 옆 열에 시간 라벨(긴 안내문, 줄바꿈 없음)+레벨 130 | 폰 변형: 세로 배치(버튼 전체 폭 56, 아래에 레벨 막대 전체 폭, 안내문 줄바꿈). 작은 위젯도 폰에서는 56×48. `use_space` 무시 |
| `ui/ui.gd` | 버튼·링크·옵션·체크 크기 고정 | 폰에서 최소 높이 상향(위 터치 표), `UI.adaptive()` 추가, `UI.label` 기본 줄바꿈 유지 |
| `ui/score_panel.gd` | 점수 `top hbox(16)`, 단어/음소 칩(flow), 칩 최소 44 폭 | `top` 줄바꿈 가능하게, 칩 높이 ≥ 44. 폭 372에서 넘침 검사 |
| `ui/prosody_panel.gd` | 최소 폭 260, 폭에 맞춰 높이 계산(확인) | 폭 372에서 글자·그래프가 읽히는지 스크린샷 확인, `CELL_W` 조정 필요하면 폰 값 |
| `ui/page_scroll.gd`, `column_box.gd`, `card_box.gd` | `max_w`, `min_pad=20` | 폰 값 분기(§5.1), `scroll_deadzone` |
| `ui/phone_layout.gd` (신규) | – | `safe_insets()`, `keyboard_height()`, `font_bump(theme)`, `is_narrow()`; 시험용 `test_keyboard_height`/`test_insets` 덮어쓰기 변수 |
| 테마 | `app_theme.tres`(`make_theme.gd`로 생성) | 파일은 고치지 않고 시작 시 `PhoneLayout.apply_theme(ThemeDB.get_project_theme())`로 글자 크기만 올림 |

---

## 6. 안드로이드 프로젝트·export 설정 (W4)

### 6.1 `project.godot` (W4 소유, 데스크톱 값은 그대로)
```
[application]  config/version="1.1.0"   config/quit_on_go_back=false
[audio]        driver/enable_input.android=true            ; 기본 false(PC 크래시 방지)는 유지
[display]      window/size/viewport_width.android=412
               window/size/viewport_height.android=915
               window/stretch/mode.android="canvas_items"
               window/stretch/aspect.android="expand"
               window/handheld/orientation=1               ; 세로 (값 의미는 4.6 레퍼런스로 확인)
[rendering]    textures/vram_compression/import_etc2_astc=true   ; 안드로이드 export 필수 검사 회피 **(추측)**
```
형식은 `키.android=값`(기능 태그 덮어쓰기). 데스크톱 `viewport 1280×800`·`audio/driver/enable_input=false`는 그대로 둔다.

### 6.2 export preset (`godot/export_presets.cfg`에 `[preset.1]` 추가, 기존 윈도우 preset.0은 불변)

| 키(Godot 4.6 이름, 틀리면 export 로그에 경고) | 값 |
|---|---|
| `name` / `platform` | `"Android"` / `"Android"` |
| `export_filter`, `include_filter`, `exclude_filter` | `all_resources`, `data/*`, `tests/*, tools/*` (윈도우와 같음) |
| `gradle_build/use_gradle_build` | `false` (기성 템플릿 APK 사용, §13) |
| `package/unique_name` | `io.github.whahan.hoehwa` |
| `package/name` | `회화 연습` |
| `version/code` | 정수 `10100` (= major×10000+minor×100+patch; 1.1.0 → 10100). 릴리스마다 올림 |
| `version/name` | 비움 → 프로젝트 `config/version` 사용 **(추측: 비우면 프로젝트 값)**. 안 되면 `1.1.0`을 직접 적고 `build_android.ps1`이 일치 검사 |
| `architectures/arm64-v8a` | `true` (나머지 false. x86_64는 에뮬레이터 시험용 `-Emulator` 옵션에서만) |
| `keystore/*` (debug/release/user/password) | **전부 빈 값**. 서명 정보는 환경변수로만 (§7) |
| `permissions/internet` | `true` |
| `permissions/record_audio` | `true` |
| `permissions/access_network_state` | `true` (연결 상태 확인용; 안 쓰면 false로 줄여도 됨) |
| 그 밖 모든 권한 | `false` (특히 위치·저장소·카메라·`change_wifi_multicast_state`: 유니캐스트 응답만 받으므로 불필요) |
| `user_data_backup/allow` | `false` (토큰이 클라우드 백업으로 새지 않게) |
| `screen/immersive_mode` | `false` (실기 후 결정) |
| `launcher_icons/*` | 비움 → 프로젝트 `icon.svg` 사용. 어댑티브 아이콘(432×432)은 후속 |
| 최소 SDK | 템플릿 고정 **24** (Godot 4.6 기본 `DEFAULT_MIN_SDK_VERSION=24`, 대상 `36`, 확인: export_plugin.cpp 상단), 결과는 `aapt2 dump badging`으로 검증 |
| 예상 APK 크기 | arm64만 25~35 MB **(추정, 4개 ABI 템플릿 103 MB에서 계산)** — 15~60 MB를 합격 범위로 둔다 |

---

## 7. 배포: 서명·빌드·릴리스 (W4)

### 7.1 키스토어 (저장소 밖)
- 위치: `%LOCALAPPDATA%\hoehwa-practice\keys\release.keystore` (확인: 이 폴더는 이미 `%LOCALAPPDATA%\hoehwa-practice\opencode`가 있는 상위). 비밀번호 파일: 같은 폴더 `release.pass` (사용자 프로필 ACL로 보호; 내용 출력 금지).
- 새 스크립트 `packaging\make_release_key.ps1`: 키가 이미 있으면 **거부**(덮어쓰기 없음). JDK 17 `keytool -genkeypair -keystore … -alias hoehwa -keyalg RSA -keysize 4096 -validity 10000 -storetype PKCS12`, 비밀번호는 무작위 24자(`-storepass:file`로 전달, 화면 출력 없음). Godot는 **키스토어 비번 = 키 비번**을 요구하므로 PKCS12 하나의 비번 사용 (확인: 공식 문서). 끝에 **인증서 SHA-256 지문과 경로만** 출력하고 지문을 `packaging\android_cert.sha256`(공개 정보, 커밋 대상)에 기록.
- 빌드 시 비밀번호는 환경변수로만 Godot 자식 프로세스에 전달 (확인: 공식 문서의 `GODOT_ANDROID_KEYSTORE_RELEASE_PATH/USER/PASSWORD`). `export_presets.cfg`에는 쓰지 않는다.
- **경고 문구(README·스크립트 출력·릴리스 노트 개발자 절에 그대로)**: "이 키스토어를 잃어버리거나 비밀번호를 잊으면 같은 앱을 덮어 설치할 수 없습니다. 사용자는 앱을 지우고 다시 설치해야 하고, 그러면 폰에 있던 학습 기록이 사라집니다. `keys` 폴더 전체를 서로 다른 두 곳(예: USB와 암호 관리자)에 백업하세요. 저장소에 올리지 마세요."
- 키스토어를 새로 만들면 지문이 달라지므로 `publish_release.ps1`이 막는다 (`-AcceptNewKey` 없이는 중단).

### 7.2 빌드 스크립트 `packaging\build_android.ps1` (신규, `build_dist.ps1`은 변경 없음)
```
powershell -ExecutionPolicy Bypass -File packaging\build_android.ps1 -Version 1.1.0 [-GodotExe <경로>] [-OutDir <폴더>] [-Debug] [-Emulator]
```
1. 입력 검사: `-Version`이 `^\d+\.\d+\.\d+$`, `godot\project.godot`의 `config/version`과 일치, preset `version/code`가 계산값과 일치, 키스토어·`release.pass` 존재(릴리스 빌드), **키 폴더가 저장소 안이 아님**, `export_presets.cfg`의 비밀번호 칸이 비어 있음.
2. 환경변수(자식 프로세스 범위): `GODOT_ANDROID_KEYSTORE_RELEASE_PATH/USER/PASSWORD`. 비밀번호는 출력하지 않음.
3. `Godot --headless --path godot --export-release "Android" <OutDir>\hoehwa-practice-android-<Version>.apk` (타임아웃 15분). 실패하면 부분 산출물 삭제.
4. 검증: `apksigner verify --print-certs` 성공 및 SHA-256이 `android_cert.sha256`과 같음, `aapt2 dump badging`(패키지·versionCode·versionName·`sdkVersion`), `aapt2 dump permissions`(INTERNET·ACCESS_NETWORK_STATE·RECORD_AUDIO 외 없음), native-code가 `arm64-v8a`만.
5. 마지막 줄에 APK 경로·크기·SHA-256 출력. 기본 출력 폴더 `packaging\out\android\` (이미 `/packaging/out/`는 git 제외, 확인).
- `-Debug`: 디버그 키스토어로 서명한 `-debug.apk`(설치 시험용, 릴리스 이름 아님, 업로드 대상 아님).

### 7.3 `publish_release.ps1` 변경 (W4)
- 새 스위치 `-WithApk`: 기존 빌드 뒤에 `build_android.ps1`을 호출해 APK를 `release_<ver>\`에 두고 **`SHA256SUMS.txt`에 APK 줄을 추가**, 기존 체크섬 재검증 루프가 APK도 확인, `$assets`에 포함. 기존 사용(스위치 없음)은 동작 변화 없음.
- 비밀값 검사(`$tracked` 스캔) 추가 패턴:
  - `$badExt`에 `keystore|jks|p12|pfx|apk|aab|idsig`
  - `$badName`에 `release\.pass|keystore\.properties|lan_devices[^/]*\.json[^/]*`
  - 내용 검사 추가: `GODOT_ANDROID_KEYSTORE_\w*PASSWORD\s*[=:]\s*["'][^"'$]+["']` (따옴표 친 리터럴만; 스크립트가 변수에서 대입하는 줄은 걸리지 않게), `keystore/(release|debug)_password="[^"]+"`
  - 이 새 패턴이 **스크립트 자신과 `build_android.ps1`에 걸리지 않는지** `-ScanOnly`로 확인한다.
- `-WithApk` 시 `android_cert.sha256` 지문 불일치면 중단 (§7.1).
- 업데이터 영향 없음: `update.ps1`의 업데이트 zip 선택 정규식은 `[-_]update[-_]v?<버전>\.zip$`이므로 `hoehwa-practice-android-<버전>.apk`는 선택되지 않는다 (확인: update.ps1 243행).
- 릴리스 노트(`-NotesFile`)에 한국어 설치 안내: "출처를 알 수 없는 앱 설치 허용", Play Protect 경고, 덮어 설치(같은 키 서명) 안내.

### 7.4 앱 안 새 버전 알림 (선택, §14 "O1")
`core/app_update.gd`: 시작 후 1회, 인터넷이 될 때만 `https://api.github.com/repos/Whahan/hoehwa-practice/releases/latest`에서 `tag_name`과 APK 자산(`hoehwa-practice-android-*.apk`)을 찾아 현재 `application/config/version`보다 높으면 설정 카드에 "새 버전 1.2.0 · [내려받기]"(`OS.shell_open(url)`) 표시. 실패하면 조용히 무시. PC와 폰 버전이 같이 가므로 PC가 더 높은 버전이면 `GET /hello`에서 확인하는 대안도 가능 (PC 버전을 노출하면 "이름·포트만" 원칙을 깨므로 쓰지 않음).

---

## 8. 작업 분할

### 8.1 개요

| 순서 | 작업 | 담당 | 병렬 | 의존 |
|---|---|---|---|---|
| P0 | 스텁·`platform.gd`·백엔드 enum 두 줄, import 확인, 커밋 | 오케스트레이터(직접) | – | 이 문서 확정 |
| W1 | 백엔드 LAN (`lan.py` 등) | worker-hard | W2·W3·W4와 동시 | P0 |
| W2 | Godot 네트워크·녹음·연결 화면·PC 설정 카드 | worker-hard | W1·W3·W4와 동시 | P0 (실제 서버 시험은 W1 M1 이후) |
| W3 | Godot 폰 레이아웃 | worker-hard | W1·W2·W4와 동시 | P0 |
| W4 | 프로젝트 설정·export·서명·빌드·릴리스 스크립트·README | worker-hard | W1·W2·W3와 동시. 단 **APK 실빌드 O/X(§9.4 X-04~)는 W2·W3 병합 뒤** | P0 |
| O1 | 앱 새 버전 알림(선택) | worker | W2·W3 병합 뒤 | W2, W3 |
| R1~R3 | 독립 검토 | reviewer | 작업별 | 해당 작업 |
| I | 통합 시험(§10.3) | reviewer | – | W1~W4 병합 |
| H | 실제 폰 시험(§10.4) | 사용자+오케스트레이터 | – | I 통과, 서명 키 |

- **worktree**: Godot를 여러 프로세스가 동시에 돌리면 `godot\.godot\` 캐시(전역 클래스 캐시·임포트)가 충돌할 수 있다 **(추측)**. 그래서 작업자마다 `git worktree add -b android/w<N> D:\Ai\언어\app_wt\w<N>`(저장소 밖)에서 일한다. 파일 소유권은 겹치지 않으므로 오케스트레이터가 4개 브랜치를 순서 상관없이 병합한다. W1이 worktree에서 실제 `server.py`를 돌리려면 모델이 없으므로(`backend\models`는 git 제외) **스텁 서버**로 시험하고, 실제 서버 시험은 병합 뒤 I 단계에서 한다.
- 영어 v1.1 트랙이 같은 뷰를 고치면 W3와 충돌한다 → §17 Q3.
- 작업자 공통 금지(모든 작업의 합격 조건에 포함): ① 포트 8770 요청 금지 ② 프로세스는 자기가 시작한 PID로만 종료 ③ 시험 서버 시작 전 포트가 비었는지 확인, 보고에 "남은 프로세스·열린 포트 없음" ④ 비밀값(토큰 전체, 코드, 키스토어 비번) 출력·기록 금지 ⑤ 소유 파일 밖 수정 금지 ⑥ 임시 파일은 `scratchpad\w_<작업명>\` ⑦ Windows 방화벽 창이 뜨면 누르지 말고 보고에 적기.

### 8.2 W1 — 백엔드 LAN (worker-hard)

| 항목 | 내용 |
|---|---|
| 수정 허용 파일 | `backend\lan.py`(신규), `backend\lan_stub_server.py`(신규), `backend\test_lan.py`(신규), `backend\server.py`(연결 약 15줄만), `API.md`, `.gitignore`, `packaging\build_dist.ps1`(robocopy `/XF`·안전망 한 줄씩), `packaging\check_zip.py`(`BAD_NAME` 한 줄), `packaging\installer\uninstall.ps1`(삭제 대상 한 항목) |
| 입력 | 이 문서 §3, `server.py`(미들웨어·lifespan·CFG·save_config), `API.md` |
| 출력 | ① §3.4 엔드포인트와 §3.5 게이트 ② §3.6 UDP ③ §3.3 파일 ④ `lan_stub_server.py`(모델 없이 뜨는 가짜 서버: `/health` `/stt` `/tts`(0.3초 WAV) `/score` `/prosody` `/chat` `/mic/start` `/llm`(POST) + `lan.router`; 인자 `--port --lan-bind --tag --devices-file`) ⑤ `test_lan.py` ⑥ `API.md` "휴대폰 연결" 절 |
| 마일스톤 | **M1** = `lan.py`+스텁이 §9.1 B-01~B-10을 통과 → 오케스트레이터가 W2에 "스텁 서버 사용 가능" 전달. M2 = 나머지 |
| 담당 근거 | 두 번째 uvicorn 스레드·소켓 수명·ASGI 게이트는 실패 비용이 크다 → worker-hard |

### 8.3 W2 — Godot 네트워크·녹음·연결 화면·PC 설정 (worker-hard)

| 항목 | 내용 |
|---|---|
| 수정 허용 파일 | `scripts/autoload/api.gd`, `backend.gd`, `recorder.gd`, `tts.gd`(일시정지 한 줄), `scripts/core/remote_link.gd`, `scripts/core/wav_util.gd`, `scripts/ui/connect_view.gd`, `phone_link_panel.gd`, `remote_link_panel.gd`, `tests/remote_test.gd/.tscn`, `tests/recorder_android_test.gd/.tscn`, `tests/phone_live_test.gd/.tscn`, 대응 `.uid` |
| 입력 | §3(서버 계약), §4(Godot 계약), P0 스텁 |
| 출력 | §4.3~4.8 전부 + 시험 3종 |
| 의존 | 코딩은 즉시. 처음엔 파이썬 `http.server`로 만든 임시 가짜 서버(scratchpad)로 시험하고, M1 이후 W1 스텁으로 최종 시험 |
| 금지 | `views/*`·`main.gd`·`ui/ui.gd`·`recorder_widget.gd` 수정 금지(W3 소유). 필요한 변경은 보고서에 요청으로 적기 |

### 8.4 W3 — Godot 폰 레이아웃 (worker-hard)

| 항목 | 내용 |
|---|---|
| 수정 허용 파일 | `scripts/main.gd`, `scripts/views/*.gd`(6개), `scripts/ui/ui.gd`, `page_scroll.gd`, `column_box.gd`, `card_box.gd`, `recorder_widget.gd`, `score_panel.gd`, `prosody_panel.gd`, `ipa.gd`, `scripts/ui/phone_layout.gd`(신규), `scripts/ui/bottom_tabs.gd`(신규), `tests/phone_layout_test.gd/.tscn`(신규), `tests/shots_phone.gd/.tscn`(신규), 대응 `.uid` |
| 입력 | §5, P0 스텁(`ConnectView`·`PhoneLinkPanel`·`RemoteLinkPanel`·`Platform`·`Backend.Status.NEEDS_PAIRING`) |
| 출력 | §5.1 공통·§5.2 뷰별 변경, 시험 2종, 스크린샷 |
| 중요 | PC 모드(`not Platform.is_phone()`) 화면은 한 픽셀도 달라지지 않게. 폰 분기는 `Platform.is_phone()`으로만 |
| 금지 | `autoload/*`·`remote_link.gd`·`connect_view.gd` 등 W2 소유 파일 수정 금지, `project.godot` 수정 금지(W4) |

### 8.5 W4 — 프로젝트 설정·export·서명·릴리스·문서 (worker-hard)

| 항목 | 내용 |
|---|---|
| 수정 허용 파일 | `godot/project.godot`, `godot/export_presets.cfg`, `packaging\build_android.ps1`(신규), `packaging\make_release_key.ps1`(신규), `packaging\publish_release.ps1`, `packaging\android_cert.sha256`(신규), `README.md` |
| 입력 | §6, §7, §13 |
| 출력 | 설정·preset·스크립트 3종, README "휴대폰에서 쓰기"와 개발자 절(키스토어 경고), 시험용 디버그 APK 빌드 증거 |
| 의존 | 설정·스크립트는 즉시. 서명 시험은 **scratch 키스토어**(`-KeysDir` 인자로 scratchpad 폴더 지정)로만 한다. **진짜 릴리스 키는 만들지 않는다**(오케스트레이터 결정 Q5) |
| 금지 | `.gitignore` 수정 금지(W1이 아래 목록을 넣음. 9.4 X-09·X-10에서 확인만) |

`.gitignore`에 W1이 넣을 줄(전체 목록, W1이 한 번에 반영):
```
# ---- phone link / Android signing ----
backend/lan_devices*.json
backend/lan_devices*.json.*
*.keystore
*.jks
*.p12
*.pfx
release.pass
keystore.properties
*.apk
*.aab
*.idsig
godot/android/
packaging/out/android/
```

---

## 9. 합격 조건 (O/X)

표기: PY=`D:\Ai\언어\app\backend\.venv\Scripts\python.exe`, GODOT=`C:\Users\rtyu6\Desktop\Godot_v4.6.3-stable_win64.exe\Godot_v4.6.3-stable_win64_console.exe`. 시험 포트는 `18771~18790`에서 비어 있는 것을 쓰고 `8770·8775·8776`은 쓰지 않는다. 보고 맨 앞에 합격 조건 표(항목/O·X/근거), 실행 못 한 항목은 "미검증".

### 9.1 W1

| ID | 실행 | O 조건 |
|---|---|---|
| B-00 | 작업 전 기준선: 기존 시험(`test_lesson_rules.py`, `test_reading.py`, `test_features.py`, `test_offline_ai.py`)을 WORKLOG 7번 방식으로 실행 | 결과를 기록해 두고 작업 후 같은 결과 |
| B-01 | `& $PY -I -m py_compile backend\lan.py backend\server.py backend\lan_stub_server.py backend\test_lan.py` | 종료코드 0 |
| B-02 | `& $PY backend\test_lan.py` | 마지막 줄 `LAN_TEST_RESULT PASS n/n` (n≥27), 종료코드 0, `SKIP`·`미검증`이 하나라도 있으면 X |
| B-03 | 기본값: 스텁을 `lan.enabled=false`로 시작 후 `socket.connect_ex(("127.0.0.1", lan_port))`와 사설 IP:lan_port | 둘 다 0이 아님(거부), `GET /lan`(루프백) → `enabled:false, listening:false` |
| B-04 | 켜기: `POST /lan {"enabled":true,"port":P,"discovery_port":D}` | `listening:true`, `connect_ex==0`, `pairing.code`가 `^\d{6}$`, `netstat -ano | findstr :P`에 LISTENING + 자기 PID |
| B-05 | LAN 포트로 토큰 없이 `GET /health` | 401 `code:"token_missing"` |
| B-06 | 틀린 토큰 `Bearer hp1_xxx…`, 스킴 없는 토큰, 빈 값 | 모두 401 (`token_invalid` 또는 `token_missing`) |
| B-07 | 루프백 8770 대신 **스텁의 메인 포트**로 토큰 없이 `GET /health`, LAN 켜짐·꺼짐 두 상태에서 | 둘 다 200 (루프백은 영향 없음) |
| B-08 | **틀린 코드 6번**: `/pair`에 `000000`을 연달아 6번 | 상태 `[401,401,401,401,401,429]`, `attempts_left` 4,3,2,1,0, 6번째 `code:"pair_locked"` |
| B-09 | 잠금 뒤 맞는 코드로 `/pair` | 429. 루프백 `POST /lan/code` 후 새 코드로 → 200, 토큰이 `^hp1_[A-Za-z0-9_-]{43}$` |
| B-10 | 같은 코드 재사용 / `HOEHWA_TEST_HOOKS=1 HOEHWA_LAN_CODE_TTL=2`로 시작해 3초 뒤 사용 | 둘 다 410 `no_active_code` |
| B-11 | 유효 토큰으로 `GET /health`, `POST /stt`(작은 본문), `GET /lan/me` — 127.0.0.1 **그리고 사설 IP** 두 주소로 | 전부 200 (사설 IP가 없으면 `미검증`) |
| B-12 | 유효 토큰으로 `POST /mic/start`, `POST /llm`, `GET /docs`, `GET /openapi.json` | 403 `lan_forbidden` |
| B-13 | 유효 토큰으로 `GET /lan`, `POST /lan/code`, `POST /lan/devices/revoke` (LAN 포트로) | 403 `local_only` |
| B-14 | 해제: 루프백 `revoke {id}` 후 그 토큰으로 요청 / 없는 id 해제 | 401 `token_invalid` / 404 `device_not_found` |
| B-15 | 응답·파일 위생: `GET /lan` 본문과 `lan_devices*.json` | 본문에 `token_sha256`·`hp1_` 없음, 파일에 토큰 원문 문자열 없음(부분 문자열 검사), 파일에는 64 hex |
| B-16 | 재시작 지속: 스텁 종료·재시작 후 같은 토큰 / 파일을 `{broken`으로 덮고 재시작 | 앞은 200, 뒤는 서버 정상 기동·옛 토큰 401·`*.bad` 파일 생김 |
| B-17 | 끄기: `POST /lan {"enabled":false}` | 3초 안에 LAN 포트 `connect_ex!=0`, 디스커버리 포트에 테스트가 직접 bind 성공, 다시 켜면 예전 토큰 200 |
| B-18 | 디스커버리 켜짐: UDP `{"hoehwa":1,"op":"discover"}` → 127.0.0.1:D | 1초 안에 응답, 키가 정확히 `hoehwa,op,name,port`, `port==P` |
| B-19 | **디스커버리 응답 없어야 함**: 자동 찾기 꺼짐+LAN 켜짐 / LAN 꺼짐 / 깨진 바이트·`{"op":"discover"}`·2KB 패킷 | 각각 3회 보내도 1.5초 무응답 |
| B-20 | 본문 17 MB를 토큰과 함께 `POST /stt` (LAN) | 413 `too_large`, 이후 `GET /health` 200 (서버 생존) |
| B-21 | 기기 9번째 `/pair` | 409 `device_limit` |
| B-22 | `/lan/proof`: 시험이 계산한 올바른 HMAC / 다른 nonce / 모르는 `device_id` | 일치 / 불일치 / 404 |
| B-23 | 포트 점유: 시험이 P를 먼저 bind 후 `POST /lan {"enabled":true}` | 409 `lan_port_busy`, 이어서 `GET /lan`의 `enabled:false`, 루프백 `/health` 계속 200 |
| B-24 | 통합(실제 서버): `& $PY backend\server.py --port 18771 --tag w1int --stt-cpu`(PID 기록) → LAN 켜고 페어링 → 사설 IP로 `/health`, `/tts`(응답이 `RIFF`로 시작), `/stt`(받은 WAV를 base64로) | `/health` 200 `"ok":true`, `/tts` WAV, `/stt` 200 JSON에 `text` 키. 마지막에 **그 PID만** 종료, `netstat`에 해당 포트 없음. 모델 부족으로 불가하면 `미검증`(병합 뒤 I 단계에서) |
| B-25 | 로그 위생: `backend\logs\server-*.log`와 시험 출력에서 `hp1_[A-Za-z0-9_-]{20,}` 및 `Authorization` | 0건 |
| B-26 | `git check-ignore -v backend/lan_devices.json` | 규칙 출력됨. 시험 후 `git status --short`에 `lan_devices*`·`*.bad` 없음 |
| B-27 | 문서: `Select-String` 로 `API.md`에 `/pair` `/hello` `/lan` `/lan/code` `/lan/devices/revoke` `/lan/proof` `/lan/me` `/lan/unpair` `token_invalid` `pair_locked` 각각 | 전부 1건 이상 |
| B-28 | 패키지 제외: `check_zip.py`를 `backend/lan_devices.json`이 든 가짜 zip(scratchpad)에 / 정상 zip에 | 앞은 `VIOLATION` + 종료코드 1, 뒤는 `ZIPCHECK_RESULT OK` (정상 zip이 없으면 `미검증`). `build_dist.ps1`에 `lan_devices` 문자열 1건 이상, `uninstall.ps1`에도 |
| B-29 | 소유권: `git diff --name-only` | §8.2 수정 허용 파일만 |
| B-30 | 금지: `Select-String -Pattern '8770' backend\lan.py backend\lan_stub_server.py backend\test_lan.py` | 0건 (기본 설정 값 언급 제외 필요하면 주석에 사유) |

### 9.2 W2

| ID | 실행 | O 조건 |
|---|---|---|
| R-00 | `& $GODOT --headless --path <worktree>\godot --quit` | 종료코드 0, 출력에 `SCRIPT ERROR`·`Parse Error` 0건 |
| R-01 | `& $GODOT --headless --path <wt>\godot res://tests/remote_test.tscn -- --phone` | 마지막 줄 `== remote test: N passed, 0 failed ==` (N≥14), 종료코드 0 |
| R-02 | 주소 파싱: `192.168.0.12`→포트 8775, `192.168.0.12:9000`, `http://192.168.0.12:8775/` 정규화 | ok=true. 그리고 틀린 입력 `""`, `abc`, `999.1.1.1`, `192.168.0.12:99999`, `:80`, `mypc.local`, `192.168.0.12:abc` → ok=false + 한국어 error |
| R-03 | 헤더: 시험 안의 `TCPServer`(가짜 서버)가 받은 원문 요청에서 `Authorization:` 검사 | 원격 모드 일반 요청엔 `Bearer hp1_…` 있음, **PC 모드엔 없음**, `hello`·`pair`·`proof` 요청엔 **없음** |
| R-04 | 페어링 성공(스텁): 시험 전용 `--remote-file=user://test_remote.json` | 파일에 `base_url,token,device_id,server_name` 있음, 테스트 끝에 파일 삭제, 시험 출력에 `hp1_` 전체 없음 |
| R-05 | 틀린 코드 6번(스텁) | 5번째까지 `err_code=code_invalid`+남은 횟수 한국어, 6번째 `pair_locked` 문구 |
| R-06 | 세션 중 서버에서 기기 해제 후 요청 | `Api.auth_failed` 정확히 1회, `Backend.status==NEEDS_PAIRING`, 파일에서 토큰만 지워지고 `base_url` 유지 |
| R-07 | `Backend.start()` 3경로: 저장 연결 정상 / 닫힌 포트 / 파일 없음 | READY ≤5초 / FAILED ≤10초+"PC에 닿지 않아요" 포함 / NEEDS_PAIRING+가짜 서버가 받은 요청 0건. 세 경로 모두 `Backend.pid==-1`, `launched_by_us==false` |
| R-08 | 연결 전 요청: 폰 모드 `Api.base_url==""` 상태에서 `get_json("/health")` | 네트워크 요청 없이 즉시 실패(가짜 서버 요청 0건), 어떤 경로로도 `127.0.0.1:8770` 접속 없음 |
| R-09 | 디스커버리(스텁 UDP): 켜짐 / 꺼짐 | 켜짐: 이름·포트 1건, 꺼짐: `[]`이고 호출이 3.5초 안에 돌아옴(멈추지 않음) |
| R-10 | 자동 재시도: 가짜 서버가 첫 `/stt`에서 연결 끊기 / 첫 `/chat`에서 연결 끊기 | `/stt` 총 2회 요청, `/chat` 총 1회 요청 |
| R-11 | `recorder_android_test`: 스테레오 48000Hz 합성음 → `WavUtil.to_mono16` | 샘플 수 동일, `mix_rate` 유지, 최대값이 원본 ±1 LSB, 무음 입력은 `silent==true`, 30초 상한, `to_wav_bytes` 헤더 `RIFF`·채널 1·16bit |
| R-12 | 데스크톱 `--phone`에서 `Recorder.begin()` (후크 없음) | `finished`가 `ok:false, reported:true`로 한 번, 크래시 없음, `/mic/*` 요청 0건. 후크(`test_audio_source`)가 있으면 `ok:true`+b64 비어있지 않음 |
| R-13 | PC 모드(인자 없이)에서 `Recorder.begin()` | 가짜 서버가 `POST /mic/start`를 받음 (기존 동작 유지) |
| R-14 | `PhoneLinkPanel` ↔ 스텁: 켜기 → 코드 6자리 라벨+남은 시간, 페어링 후 기기 행, [연결 해제] | 행이 사라지고 다음 `GET /lan`에서 devices 0. 패널 텍스트에 `개인 네트워크`, `공용 와이파이` 포함 |
| R-15 | 일시정지: 녹음 중 `NOTIFICATION_APPLICATION_PAUSED` 전달 / 복귀 시 | 녹음 취소됨, `Tts.stop()` 호출됨, 복귀 시 `/health` 즉시 1회 |
| R-16 | 회귀: `smoke.tscn`, `fsrs_test.tscn`, `review_walk_test.tscn`, `reading_test.tscn`, `prosody_test.tscn`(`--headless`) | 작업 전 기준선과 같은 통과 수, 0 failed |
| R-17 | 실전 흐름(`phone_live_test`, 스텁 또는 실제 서버 + 사설 IP): `/health` `/tts` `/stt`(받은 WAV 재사용) `/score` `/prosody` | 모두 ok. 실제 서버가 없으면 `미검증` |
| R-18 | 코드 점검: `Select-String "AudioStreamMicrophone|request_permission|create_process" scripts -Recurse` | 각 줄이 `Platform.is_android()` 분기 안(또는 그 분기에서만 부르는 함수)이라고 보고서에 근거 명시 — reviewer가 열어 확인 |
| R-19 | 소유권·금지 | `git diff --name-only`가 §8.3 파일만. 시험 출력에 토큰 전체·코드 없음 |
| R-20 | 권한 창·실제 녹음 | **실기 전용 → "미검증"으로 표기** (O 불가) |

### 9.3 W3

| ID | 실행 | O 조건 |
|---|---|---|
| L-00 | `& $GODOT --headless --path <wt>\godot --quit` | 종료코드 0, `SCRIPT ERROR`·`Parse Error` 0건 |
| L-01 | `& $GODOT --headless --path <wt>\godot --resolution 412x915 res://tests/phone_layout_test.tscn -- --phone` | 마지막 줄 `== phone layout: N passed, 0 failed ==`, 종료코드 0 |
| L-02 | 넘침 검사(시험 내부): 6개 뷰 × 상태(오늘·레슨 선택/문제 각 유형/결과·대화 설정/채팅(긴 한국어·일본어 말풍선)/피드백·읽기 라이브러리/리더+단어 패널·복습·로드맵 펼침)에서 보이는 모든 `Control`의 `get_global_rect().end.x` | 출력 `LAYOUT_OVERFLOW_COUNT 0` (폭 412.5 초과 0건; 예외 목록은 시험 파일에 사유와 함께 3개 이하) |
| L-03 | 터치 크기 검사: 보이는 `BaseButton`·`OptionButton`·`LineEdit`·체크 행 높이 | `TOUCH_SMALL_COUNT 0` (높이 <44 인 것 0건, 링크 버튼 포함) |
| L-04 | 키보드: `PhoneLayout.test_keyboard_height=300` 설정 후 대화 화면 | 입력 행 `get_global_rect().end.y <= 915-300+1`, 탭바 숨김, 해제 후 원위치 |
| L-05 | 안전 영역: `test_insets=Rect(top 48, bottom 34)` | 상단 줄 내용 y ≥ 48, 탭바 아래 여백 ≥ 34 |
| L-06 | 데스크톱 불변: 같은 시험을 인자 없이 1280×800으로 | 상단 탭 6개 있음, 하단 탭바 없음, 오늘 화면 격자 2열, 대화 하단이 한 줄, `RecorderWidget` 190×58 |
| L-07 | 스크린샷(창 있는 실행): `& $GODOT --path <wt>\godot --resolution 412x915 res://tests/shots_phone.tscn -- --phone` | `scratchpad\w_layout\phone_*.png` 14장 이상, 각 412×915 (또는 배율 정수배). reviewer가 임의 3장을 열어 텍스트 잘림·겹침이 없다고 확인 |
| L-08 | 화면 문구 | 폰 화면 텍스트에 `Ctrl`·`스페이스바` 0건 (시험이 `Label/Button/RichTextLabel` 텍스트 검색) |
| L-09 | 뒤로 가기 | 읽기 리더/대화 중/ConnectView에서 `NOTIFICATION_WM_GO_BACK_REQUEST` → 한 단계 뒤로; 오늘 탭에서 1회→토스트, 2초 안 2회→종료 요청 |
| L-10 | 회귀: `smoke`, `review_walk_test`, `reading_test`, `flow_test`, `lesson_source_test`(`--headless`) | 기준선과 같음, 0 failed |
| L-11 | 소유권·금지 | `git diff --name-only`가 §8.4 파일만. `OS.has_feature("android")` 직접 사용 0건 (`Select-String`) |

### 9.4 W4

| ID | 실행 | O 조건 |
|---|---|---|
| X-01 | `git diff godot/project.godot` | §6.1의 키만 추가, 기존 줄 변경 없음(`window/size/viewport_width=1280` 등 그대로) |
| X-02 | 준비: scratch 키스토어 생성 `make_release_key.ps1 -KeysDir <scratchpad>\w_keys` | 종료코드 0, 출력에 비밀번호 없음(`Select-String` 로 `release.pass` 내용이 출력 로그에 없음), 지문 출력, 같은 명령 재실행은 거부(종료코드≠0) |
| X-03 | 부정 시험(키 없음): 존재하지 않는 키 폴더로 `build_android.ps1 -Version 1.1.0 -KeysDir <없음>` | 종료코드≠0, 한국어 메시지, APK 파일 없음 |
| X-04 | 부정 시험(버전 불일치): `-Version 1.1.1` (project.godot는 1.1.0) | 종료코드≠0, APK 없음 |
| X-05 | 부정 시험(틀린 비밀번호): scratch 키의 `release.pass`를 틀린 값으로 바꾼 사본으로 | 종료코드≠0, 서명 안 된 APK가 출력 폴더에 남지 않음 |
| X-06 | 정상 빌드(scratch 키, W2·W3 병합 뒤): `build_android.ps1 -Version 1.1.0 -KeysDir <scratch> -OutDir <scratch>` | 종료코드 0, `hoehwa-practice-android-1.1.0.apk` 존재, 크기 15~60 MB |
| X-07 | `apksigner verify --print-certs <apk>` | 종료코드 0, 인증서 SHA-256이 scratch 키의 지문과 같음 (실제 `android_cert.sha256`과는 다름 — 릴리스 키가 아니므로) |
| X-08 | `aapt2 dump badging <apk>` / `aapt2 dump permissions <apk>` | `package: name='io.github.whahan.hoehwa'`, `versionCode='10100'`, `versionName='1.1.0'`, `sdkVersion:'24'`(다르면 보고), `native-code: 'arm64-v8a'`만, 권한 = INTERNET·ACCESS_NETWORK_STATE·RECORD_AUDIO뿐 |
| X-09 | 비밀값: `Select-String 'keystore/(release\|debug)_password="[^"]' godot\export_presets.cfg` 및 `git ls-files | Select-String '\.(keystore|jks|p12|pfx)$'` | 둘 다 0건. 키 폴더가 저장소 밖(`D:\Ai\언어\app` 하위 아님) |
| X-10 | 공개 스크립트: `publish_release.ps1 -ScanOnly -Version 1.1.0` | `SCAN OK` (새 패턴이 스크립트 자신에 안 걸림). **부정 시험**: 저장소 복제본(scratchpad)에 가짜 `x.keystore`와 `GODOT_ANDROID_KEYSTORE_RELEASE_PASSWORD = "abc"` 한 줄을 `git add` 한 뒤 복제본의 스크립트로 `-ScanOnly` → 종료코드≠0, 출력에 값은 없고 파일 이름만 |
| X-11 | `publish_release.ps1 -DryRun -WithApk -SkipBuild -Version 1.1.0` (scratch 산출물 사용) | `release_1.1.0\`에 APK와 `SHA256SUMS.txt`가 있고 그 안에 `hoehwa-practice-android-1.1.0.apk` 줄 존재, 체크섬 재검증 통과. 지문 불일치(scratch 키 ≠ `android_cert.sha256`)면 중단되는 것도 확인 (-AcceptNewKey 없이) |
| X-12 | 업데이터 영향: PowerShell로 `update.ps1`의 정규식 `(?i)[-_]update[-_]v?1\.1\.0\.zip$`를 `hoehwa-practice-android-1.1.0.apk`에 적용 | `False` |
| X-13 | `-WithApk` 없이 `-DryRun`(기존 동작) | 이전과 같은 자산 목록 (APK 없음) |
| X-14 | README: `Select-String` 로 `키스토어`, `덮어`, `출처를 알 수 없는`, `Play Protect`, `휴대폰 연결` | 전부 1건 이상, 키스토어 분실 경고 문구 포함 |
| X-15 | 소유권·금지 | `git diff --name-only`가 §8.5 파일만. 진짜 릴리스 키 생성·업로드·`gh` 호출 0건 |

### 9.5 검토자(reviewer) 공통
작성자 보고를 믿지 않고 위 명령을 새 컨텍스트에서 다시 실행한다. 일부러 틀린 입력 항목(B-06·08·10·19·20, R-02·05, X-03~05·10)은 **반드시 실제로 실패하는지** 직접 확인한다(통과만 확인한 검사기는 믿지 않음). 원본 8770 서버를 건드리지 않았는지(`Get-NetTCPConnection -LocalPort 8770`의 소유 PID가 시험 시작 전과 같은지) 확인한다.

---

## 10. 시험 방법

### 10.1 폰 없이 할 수 있는 것

| 무엇 | 방법 |
|---|---|
| 토큰·페어링·잠금·허용 목록·포트 열림/닫힘·디스커버리 | `test_lan.py` (스텁 서버, 모델 불필요) |
| "LAN 요청" 흉내 | 같은 PC의 **사설 IPv4**(예: 192.168.x.x)로 접속하면 소스 IP가 루프백이 아니다. LAN 리스너는 리스너 기준이라 `127.0.0.1:8775`로 접속해도 토큰이 필요하다. 자기 IP로의 접속은 방화벽 허용 없이도 되는 것으로 알려져 있음 **(추측, 확인)** |
| Godot 원격 모드 | `-- --phone --api=http://<사설IP>:<lan포트> --remote-file=user://test_remote.json` (+ 필요 시 `--token=`) 로 헤드리스 시험 |
| 폰 레이아웃 | `--resolution 412x915 -- --phone`로 데스크톱 창에서 실행, 넘침·터치 크기 자동 검사, 스크린샷 |
| 녹음 변환·업로드 | `WavUtil.to_mono16` 단위 시험 + `Recorder.test_audio_source` 후크로 전체 경로 |
| APK 빌드·서명·권한·패키지 | `build_android.ps1`+`apksigner`+`aapt2` (설치는 안 함) |
| 안드로이드 UI·권한 창 (선택) | 에뮬레이터(§13 선택 항목)에서 APK 설치, 주소 `10.0.2.2:8775`(에뮬레이터에서 본 PC)로 직접 입력 — 디스커버리(UDP)는 안 됨 |

### 10.2 실제 폰이 필요한 것

| ID | 항목 | O 조건 |
|---|---|---|
| S1 | APK 설치 | `adb install` 또는 파일로 설치 성공, 앱 아이콘·이름 "회화 연습" |
| S2 | 연결 | PC '폰 연결' 켬 → 폰에서 자동 찾기로 PC가 목록에 보임 → 코드 입력 → 메인 화면 |
| S3 | 글꼴 | 한글·일본어·IPA 기호(θ ɪ ŋ ʔ)가 □(두부)로 안 나옴. 나오면 §11 R12 대안 |
| S4 | 마이크 권한 | 처음 녹음에서 시스템 권한 창이 뜨고, 허용 후 녹음됨, 거부 후 안내 문구가 보임 |
| S5 | 화면 | 상태 표시줄·제스처 바·노치에 가려지는 것 없음, 하단 탭바 터치 쉬움 |
| S6 | 키보드 | 대화·복습·읽기 입력창이 키보드에 가려지지 않음 (한글·일본어 입력 포함) |
| S7 | 스크롤 | 버튼 위에서 시작한 손가락 드래그가 스크롤됨 |
| S8 | 발음 채점 | 말하기 → 점수 표시(PC와 같은 형식) 지연 5초 이내 (로컬 와이파이) |
| S9 | 백그라운드 | 홈으로 나갔다 30초 뒤 복귀: 연결 유지 또는 한국어 안내 후 자동 복구, 녹음은 취소되어 있음 |
| S10 | 해제 | PC에서 기기 해제 → 폰 다음 요청에서 "연결이 해제됐어요" → 연결 화면 |
| S11 | 업데이트 설치 | 같은 키로 서명한 다음 버전 APK를 **덮어 설치**, 연결과 학습 기록 유지 |
| S12 | 공유기 | AP 격리 켠 와이파이(또는 게스트)에서 연결 실패 안내 문구가 보임 |

### 10.3 통합 시험 I (병합 뒤, reviewer, 병합된 `main` 작업 트리)
1. B-02·B-24, R-01·R-16·R-17, L-01·L-10, X-06~X-08을 병합본에서 재실행.
2. 실제 서버 + 사설 IP + `--phone` 데스크톱: 연결 화면 흐름(코드 입력은 시험 후크) → `/lesson`(tatoeba) → `/tts` → 후크 오디오로 `/score` → `/chat` 한 턴(AI 엔진이 없으면 `미검증`).
3. 영향 확인: PC 앱(인자 없는 Godot)이 기존처럼 8770에 붙어 같은 응답을 받는지(기준선과 비교).

### 10.4 실기 시험 H
사용자 폰 + `adb`(platform-tools 있음). 순서: 디버그 APK로 S1~S10 → 문제 수정 → 릴리스 서명 APK로 S11. 결과는 위 표에 O/X와 사진으로.

---

## 11. 위험 요소와 대응

| ID | 위험 | 영향 | 대응 | 확인 |
|---|---|---|---|---|
| R1 | Windows 방화벽이 8775/8776 차단, 네트워크 프로필이 "공용" | 폰이 PC를 못 찾음 | 안내 문구(§4.8 다), 폰 오류 문구에 ①~④ 점검 목록. 앱은 방화벽을 건드리지 않음 | S2 |
| R2 | 와이파이 AP 격리(게스트·공용·일부 메시) | 같은 와이파이인데 못 닿음 | 같은 문구에 안내, 핫스팟(폰 테더링)이나 다른 공유기 제안 | S12 |
| R3 | UDP 브로드캐스트 차단·일부 기기 미지원 | 자동 찾기 실패 | 직접 입력이 항상 됨. 자동 찾기는 편의 기능 | S2 |
| R4 | 녹음 형식: `AudioEffectRecord`는 믹스 레이트(44.1/48k)·스테레오, 기기에 따라 한쪽 채널 무음 가능 | 채점 오류 | 모노 평균 변환, peak로 `silent` 판정, 서버가 16kHz 변환. 한쪽 채널만 소리나는 기기는 실기에서 채널 선택 로직 추가 | R-11, S8 |
| R5 | 큰 업로드: 30초 ≈ 3.8 MB(base64), `/score`+`/prosody`가 같은 오디오를 두 번 보냄 | 느린 와이파이에서 수 초~십수 초 | 폰 타임아웃 90초, 진행 문구, 필요하면 `/prosody`가 직전 `/score` 오디오를 재사용하는 서버 캐시(후속) | S8 |
| R6 | 배터리: 화면 켜짐·15초 폴링·마이크 | 소모 | 백그라운드 폴링 중지, 일시정지 시 녹음 취소, 폴링 15→30초(폰), `screen_set_keep_on`은 요청·녹음 중에만(선택) | S9 |
| R7 | 안드로이드가 백그라운드 앱의 소켓을 끊음 | 진행 중 요청 실패 | 멱등 요청만 1회 자동 재시도, `/chat` 등은 "다시 보내기", 복귀 즉시 `/health` | R-10, S9 |
| R8 | **키스토어 분실** | 덮어 설치 불가, 폰 기록 사라짐 | §7.1 경고·두 곳 백업·지문 고정·`publish`가 지문 불일치 시 중단 | X-11 |
| R9 | 토큰이 평문 HTTP로 오감 | 같은 와이파이의 공격자가 토큰을 가로채면 PC의 AI 엔진·TTS 사용 가능(파일 접근은 불가) | 공용 와이파이 경고, 허용 목록, 즉시 해제, 서버는 해시만 저장. HTTPS는 §16 | – |
| R10 | PC IP가 DHCP로 바뀜 | 연결 실패 | 재탐색+이름 일치+`/lan/proof` 검증 후 자동 갱신 (같은 이름의 다른 PC에 토큰이 새는 일 방지) | R-07 |
| R11 | 같은 와이파이에 같은 PC 이름 둘 | 잘못된 PC 선택 | 목록에서 사용자가 고름, 자동 갱신은 proof 통과만 | – |
| R12 | 폰 글꼴: 테마·IPA가 윈도우 글꼴 이름만 지정(확인: app_theme.tres, ipa.gd) → 안드로이드 시스템 글꼴 대체가 한글·일본어·IPA를 다 그리는지 불확실 **(추측)** | 두부 글자 | 먼저 시스템 글꼴 대체로 시험. 실패하면 Noto Sans KR/JP(OFL)를 번들(APK +10~20 MB)해 `SystemFont.fallbacks` 앞에 추가. §17 Q4 | S3 |
| R13 | Godot 4.6 안드로이드 마이크 API 세부(권한 후 재초기화, `enable_input` 시작 순서) | 첫 녹음 무음 | 권한 허용 직후 마이크 플레이어를 새로 생성, 첫 1초 무음이면 1회 재시도 | S4 |
| R14 | Play Protect/출처 불명 앱 경고 | 설치 거부감 | README·릴리스 노트에 설치 안내 | S1 |
| R15 | 대상 SDK가 37 이상이 되면 안드로이드 17의 로컬 네트워크 권한(`ACCESS_LOCAL_NETWORK`)이 필수 | LAN 접속 차단 | 현재 대상 36(Godot 4.6 기본)은 암묵 허용. 대상 SDK를 올릴 때 권한 선언+런타임 요청 추가 | 출처: developer.android.com/privacy-and-security/local-network-permission |
| R16 | 엣지-투-엣지·컷아웃 | 가림 | 안전 영역 계산 | S5 |
| R17 | 영어 v1.1 트랙이 같은 뷰를 동시에 수정 | 병합 충돌 | §17 Q3: 병합 순서 합의, 폰 분기는 `Platform.is_phone()` 한 줄 단위로 최소화 | – |
| R18 | 두 번째 uvicorn 서버 스레드 불안정(이벤트 루프·종료) | 포트가 안 닫히거나 서버 정지 | `socket` 선 bind, `should_exit`+`join`, 단위 시험(B-17·B-23), 실패 시 대안 A(재시작)를 최후 수단으로 | B-17 |
| R19 | 동시 Godot 프로세스의 `.godot` 캐시 충돌 | 시험 오류 | worktree 분리(§8.1) | – |
| R20 | PC 절전·잠자기 | 폰 요청 무응답 | 폰 오류 문구에 "PC가 켜져 있는지"; 설정 문구에 "PC가 잠들면 연결이 끊겨요" | S2 |
| R21 | Godot `HTTPClient`가 안드로이드의 평문 HTTP(cleartext) 제한을 받는지 | 모든 요청 실패 | Godot는 자체 소켓을 쓰므로 제한 대상이 아니라고 보지만 **(추측)**, S2에서 첫 확인. 막히면 preset의 `usesCleartextTraffic` 설정(가능하면) 또는 HTTPS 전환 | S2 |
| R22 | 에디터 설정/빌드 도구 버전: 문서는 build-tools 35.0.1을 요구, 설치는 34.0.0 | export 거부 | W4가 첫 export 결과로 확인, 거부되면 `sdkmanager "build-tools;35.0.1" "platforms;android-35"` (오케스트레이터 승인 후) | X-06 |

---

## 12. 일부러 틀린 입력 시험 요약

| 대상 | 틀린 입력 | 기대 | ID |
|---|---|---|---|
| `/pair` | 틀린 코드 6회 | 401×5 → 429 `pair_locked`, 이후 맞는 코드도 429 | B-08·09 |
| `/pair` | 숫자 아닌 코드·5자리·`device_name` 없음 | 400/422 | B-02 내부 |
| `/pair` | 만료·재사용 | 410 | B-10 |
| LAN 요청 | 토큰 없음·틀림·해제됨·스킴 없음 | 401 | B-05·06·14 |
| LAN 요청 | `/mic/start` `/llm` `/docs` | 403 | B-12 |
| LAN 요청 | 관리 엔드포인트 | 403 `local_only` | B-13 |
| LAN 요청 | 17 MB 본문 | 413, 서버 생존 | B-20 |
| 루프백 | 토큰 없이 | 200 (영향 없음) | B-07 |
| 폰 연결 꺼짐 | 포트 접속 | 거부 | B-03·17 |
| 디스커버리 | 꺼짐·LAN 꺼짐·깨진·큰 패킷 | 무응답 | B-19 |
| 파일 | 깨진 `lan_devices.json` | 기동 정상, 옛 토큰 401, `.bad` 생성 | B-16 |
| 포트 | 이미 사용 중 | 409 `lan_port_busy`, 켜지지 않음 | B-23 |
| 기기 수 | 9번째 | 409 | B-21 |
| 증명 | 틀린 nonce·모르는 기기 | 불일치·404 | B-22 |
| 주소 입력(폰) | `""` `abc` `999.1.1.1` `:80` `mypc.local` | ok=false 한국어 | R-02 |
| 녹음 변환 | 무음·스테레오 한쪽만 소리 | `silent` 판정/평균 | R-11 |
| 폰 모드 | 데스크톱에서 마이크 | 열지 않음 | R-12 |
| 빌드 | 키 없음·버전 불일치·틀린 비밀번호 | 비정상 종료, APK 없음 | X-03~05 |
| 비밀값 검사 | 가짜 `.keystore`·비밀번호 줄 추적 | `-ScanOnly` 실패 | X-10 |
| 패키지 검사 | `lan_devices.json` 든 zip | `VIOLATION` | B-28 |

---

## 13. 필요한 다운로드·도구

현재 상태는 §0.2. "상태" 칸은 재확인 명령 결과로 오케스트레이터가 확정한다 (읽기 전용: `Get-ChildItem`, `adb version`, `& "$env:LOCALAPPDATA\Android\jdk-17\bin\java.exe" -version`).

| 이름 | 공식 출처 | 대략 크기 | 왜 필요한가 | 상태 |
|---|---|---|---|---|
| Godot 4.6.3 export templates (`…_export_templates.tpz`) | https://godotengine.org/download/archive/ 의 4.6.3-stable 또는 godot-builds 저장소 릴리스 `4.6.3-stable` **(태그 이름 추측)** | tpz 약 1 GB (설치된 것은 윈도우+안드로이드 ≈ 630 MB) | 안드로이드 export는 **기성 템플릿 APK**(`android_release.apk`, 모든 ABI 포함)에 리소스 팩을 넣고 서명하는 방식 | 설치돼 있음 (`version.txt` = `4.6.3.stable`) |
| Android platform-tools (adb) | https://developer.android.com/tools/releases/platform-tools (직접: `dl.google.com/android/repository/platform-tools-latest-windows.zip`) | zip 약 8 MB | 에디터가 SDK 경로 유효성으로 `platform-tools\adb` 확인(공식 문서: "must contain platform-tools/adb"), 폰에 `adb install`, 로그 | 설치돼 있음 (37.0.1) |
| JDK 17 (Temurin) | https://adoptium.net/temurin/releases/?version=17 | zip 약 180 MB, 풀면 약 300 MB | 공식 문서: OpenJDK 17 권장, 상위 버전도 지원. Godot가 `keytool`(디버그 키 생성)·`apksigner`(서명) 실행에 사용. 시스템 Java 22로도 될 수 있으나 에디터 설정이 이미 jdk-17을 가리키므로 17 고정이 예측 가능 | 설치돼 있음 (`%LOCALAPPDATA%\Android\jdk-17`) |
| Android SDK build-tools 34.0.0, platforms android-34, cmdline-tools | `sdkmanager`(cmdline-tools) | 이미 설치 | `apksigner`·`zipalign`·`aapt2`(검증) | 설치돼 있음 |
| build-tools **35.0.1** + platform **android-35** | `sdkmanager "build-tools;35.0.1" "platforms;android-35"` | 약 60 MB + 65 MB | 공식 문서(gradle 기준)가 요구하는 버전. 설치된 34.0.0으로 gradle 없는 export가 통과하는지는 **(추측: 통과)**, 거부되면 추가 | **조건부**(W4 첫 export 결과로 결정) |
| Android 에뮬레이터 + x86_64 시스템 이미지 | `sdkmanager "emulator" "system-images;android-34;google_apis;x86_64"` | 약 350 MB + 1.5 GB | UI·권한 창·글꼴을 실제 폰 없이 시험 (선택). Windows 하이퍼바이저 기능 필요 | **선택**(승인 필요, Q6) |

**Godot 4.6 gradle 미사용 export에 필요한 것 vs 불필요한 것** (근거: 공식 문서 `exporting_for_android` — gradle은 AAB와 플러그인 때 필요하다고 서술, APK는 기성 템플릿 사용):

| 필요 | 불필요 |
|---|---|
| 안드로이드 export 템플릿(기성 APK), JDK(17 권장), Android SDK 경로(platform-tools·build-tools·cmdline-tools), 서명 키스토어 | Gradle, Android Studio, NDK r28b, CMake (맞춤 빌드·AAB·네이티브 플러그인일 때만), Google Play 서비스 |

APK에 들어가는 최소 SDK는 템플릿에 고정이라 preset의 min/target SDK 칸은 gradle 빌드에서만 효력이 있다 **(추측)** → `aapt2`로 실제 값을 확인한다.

---

## 14. 작업량 추정

에이전트 작업 시간 기준의 거친 값(검토·재작업 포함하지 않음). 사람 기준 일수는 괄호.

| 작업 | 규모 | 시간 | 비고 |
|---|---|---|---|
| P0 스텁 | 파일 6개, 약 60줄 | 0.5시간 | 오케스트레이터 |
| W1 | `lan.py` ~500줄, 스텁 서버 ~120줄, 시험 ~600줄, 문서·패키징 한두 줄씩 | 5~7시간 (1.5일) | M1은 약 3시간 시점 |
| W2 | `remote_link` ~250줄, `api/backend/recorder` 변경 ~300줄, `connect_view` ~250줄, 패널 2개 ~350줄, 시험 3종 ~600줄 | 7~9시간 (2일) | 실제 녹음은 실기 의존 |
| W3 | 뷰 6개+위젯 6개 변경, `phone_layout` ~150줄, 하단 탭 ~120줄, 시험 ~400줄, 스크린샷 반복 | 8~12시간 (2.5일) | 가장 큼. 시각 확인 반복 |
| W4 | 설정·preset ~60줄, 스크립트 3개 ~400줄, README | 4~5시간 (1일) | 실빌드는 W2·W3 병합 뒤 |
| 검토 R1~R3 + 통합 I | – | 4~6시간 | 부정 시험 포함 |
| 실기 H | – | 2~3시간 | 사용자 참여 |
| **합계(병렬 4명)** | – | 벽시계 약 1.5~2.5일 + 실기 | |
| O1 새 버전 알림(선택) | ~120줄 | 1~2시간 | |
| 로드맵: 학습 기록 동기화 | 서버 `GET/PUT /sync/progress`, 항목별 최신 우선 병합(`updatedAt`), 충돌 UI, 시험 | 3~4일 | `progress.json` 구조는 `core/progress.gd` 참고, 이번엔 안 함 |
| 로드맵: HTTPS+인증서 고정 | 자체 서명 인증서, 페어링 때 지문 전달, Godot `TLSOptions` | 2~3일 | |
| 로드맵: 어댑티브 아이콘·가로 화면 | – | 0.5~1일 | |

---

## 15. 로드맵 후보 (이번 범위 밖)
1. 학습 기록 동기화 (위 추정). 1차는 폰과 PC가 각자 기록.
2. HTTPS(자체 서명+지문 고정), 3. 공용 와이파이 자동 감지 경고, 4. VPN(Tailscale)으로 밖에서 사용 (토큰은 그대로 쓸 수 있고 `100.x` 주소를 `addresses`에 넣으면 됨), 5. 업로드 압축(Godot에 Opus 인코더가 없어 지금은 PCM), 6. 어댑티브 아이콘, 7. 앱 안 새 버전 알림(O1).

---

## 16. 대안 (오케스트레이터 방향과 다른 선택지, 근거와 함께)

| 대안 | 내용 | 채택하지 않은 이유 |
|---|---|---|
| 단일 포트 재시작 (3.1 A) | 켤 때 서버를 `0.0.0.0:8770`로 재시작 | 모델 재로딩 15~60초, 되돌릴 때도 재시작. 단 B가 구현 중 실패하면 최후 수단 |
| 소스 IP로 LAN 판별 | `request.client.host` 비루프백이면 토큰 | 같은 PC의 사설 IP 접속·프록시·IPv6 매핑에서 오판 소지. 리스너 기준이 더 단순·견고 |
| mDNS(`_hoehwa._tcp`) | 이름으로 자동 찾기 | Godot에 mDNS 클라이언트가 없고 안드로이드 `NsdManager`는 플러그인 필요. UDP 브로드캐스트가 순수 Godot로 가능 |
| 웹앱(브라우저) | APK 없이 PC가 웹 화면 제공 | 브라우저 마이크는 보안 컨텍스트(HTTPS)가 필요해 `http://IP`에서 막힘 |
| 허용 목록 대신 전체 허용 | LAN 토큰이면 모든 경로 | 폰이 PC 마이크를 켜거나 AI 엔진·API 키를 바꿀 수 있어 위험 |
| 기기 해제 DELETE | RESTful | 지금 `Api`에 POST/GET만 있어 변경이 커짐 |
| 폰에서 16kHz 리샘플링 | 업로드 3배 절약 | GDScript 반복문이 느려 UI가 멈춤. 서버가 이미 변환 가능. 실측 후 스레드+리샘플로 바꿀 수 있음 |

---

## 17.0 오케스트레이터 결정 (2026-10-16, 작업자는 이것을 따른다)

- Q1 유지(재시작 후에도 켜짐 유지 + 상단 '폰 연결 켜짐' 표시). Q2 그대로(8775/8776, 최대 8대). Q4 시스템 글꼴 먼저. Q8 arm64만. Q9 새 버전 알림 제외. Q10 동기화는 실사용 후. Q11 SDK 36 유지.
- Q3 병합 순서: 안드로이드 W3(폰 레이아웃) 먼저, 영어 v1.1 은 새 파일 위주라 그 뒤 연결 지점(T5)에서 `Platform.is_phone()` 분기만 추가.
- Q5 진짜 릴리스 키스토어는 W4가 만들지 않음(scratch 키로만 시험). 실제 키는 사용자 확인 후 오케스트레이터가 생성.
- Q6 에뮬레이터 받지 않음(사용자 실제 폰으로 실기 시험). Q7 폰 1.1.0 은 PC 1.1.0 과 같은 태그. Q12 실기 때 기종 확인.
- 영어 v1.1 트랙(docs/english_v11_design.md)이 main 작업 트리에서 새 파일(`core/study_log.gd` 등, `practice/*`, `backend/practice.py`·`missions.py`)을 만드는 중. 안드로이드 작업자는 worktree 에서 일하므로 충돌하지 않지만, 그 파일들은 건드리지 않는다. `RecorderWidget`·`Recorder.begin/finished`·`Tts.*` 공개 함수 모양은 영어 트랙이 쓰므로 바꾸지 않는다(설계 §4.6 과 같음).
- 안드로이드 SDK: build-tools 36.1.0·platforms android-36 설치 승인됨(설치 작업 진행 중). 템플릿·adb·JDK 17 은 설치 완료(§0.2).
- 포트: W1 스텁 서버 8830~8839 (LAN 리스너는 시험용으로 8840~8849), W2 가짜 서버 8850~8859. 영어 트랙은 8811~8824 사용.

## 17. 오케스트레이터가 정해야 할 사항

| Q | 질문 | 추천 |
|---|---|---|
| Q1 | '폰 연결' 켠 상태를 PC 앱 재시작 후에도 유지? | 유지 + 상단에 "폰 연결 켜짐" 표시. 더 안전하게 하려면 "앱을 켤 때마다 꺼짐"(번거로움) |
| Q2 | 기본 포트 8775(HTTP)·8776(UDP)와 기기 최대 8대 | 그대로 |
| Q3 | 영어 v1.1 트랙과 병합 순서. 같은 뷰 파일을 둘 다 고치므로 W3를 먼저 병합할지 | 폰 레이아웃(W3)을 먼저 병합하고 v1.1은 그 위에서 `Platform.is_phone()` 분기만 추가 |
| Q4 | 폰 글꼴: 시스템 글꼴 대체로 먼저 시험(추천) vs 처음부터 Noto Sans KR/JP 번들(APK +10~20 MB) | 먼저 시스템 글꼴, 실기 S3 실패 시 번들 |
| Q5 | 진짜 릴리스 키스토어를 언제·누가 만드나, 백업 위치 두 곳 | W4는 scratch 키로만 시험. 실제 키는 사용자 확인 후 `make_release_key.ps1`로 생성, 백업 두 곳 확인 뒤 지문을 커밋 |
| Q6 | 에뮬레이터(약 1.9 GB) 다운로드 승인 | 실제 폰이 있으면 생략 |
| Q7 | 폰 앱 버전 1.1.0을 PC 1.1.0 릴리스와 같은 태그에 올리나 (PC 쪽 백엔드가 1.1.0 이상이어야 폰이 붙음) | 같은 태그, 노트에 "PC 앱도 1.1.0으로 업데이트" |
| Q8 | arm64만 지원(구형 32비트 폰 제외)해도 되나 | 예 (APK 용량 절약) |
| Q9 | 앱 안 새 버전 알림(O1) 포함 여부 | 이번엔 제외, 1.1.1에서 |
| Q10 | 학습 기록 동기화 착수 시점 | 폰 실사용 피드백 후 |
| Q11 | 대상 SDK는 Godot 기본(36) 유지, 37로 올리는 시점에 로컬 네트워크 권한 작업 | 유지 |
| Q12 | 실기 시험 때 사용자 폰 기종·안드로이드 버전 | 알려 주면 S1~S12 기준 조정 |
