# 작업 인수인계 (WORKLOG)

이 문서는 세션이 한도에 걸려 끊겼을 때 다른 세션(예약 작업)이 이어받기 위한 것입니다. 작업하는 세션은 단계를 끝낼 때마다 이 문서와 `.orchestrator_heartbeat`를 갱신합니다.

- 작업 규칙: `C:\Users\rtyu6\.claude\CLAUDE.md` (역할별 에이전트 designer / worker / worker-hard / reviewer, 모두 effort high, O/X 합격 조건, 독립 검토, 프로세스는 PID로만 종료, 비밀값 출력 금지)
- 구조와 API 규칙: `D:\Ai\언어\app\API.md`, 개발 계획: `D:\Ai\언어\app\ROADMAP.md`, 사용 설명: `D:\Ai\언어\app\README.md`
- 앱 서버는 포트 8770(사용자 앱이 씀, 건드리지 말 것). 테스트는 `backend\.venv\Scripts\python.exe backend\server.py --port <빈 포트> --tag <이름> --stt-cpu`로 따로 띄우고 PID로 끈다.
- Godot 콘솔: `C:\Users\rtyu6\Desktop\Godot_v4.6.3-stable_win64.exe\Godot_v4.6.3-stable_win64_console.exe` (폴더 경로)

## 남은 작업 (위에서부터 순서대로)

**[진행 중 2026-10-16 21:10] 안드로이드 A안(PC 연결형)** — 사용자 요청. 폰 앱은 Godot 화면만, 같은 와이파이의 PC 백엔드에 페어링 코드+토큰으로 연결. designer 설계 중 → `docsndroid_remote_design.md`. 그다음: 설계 확정 → 다운로드 승인(Godot 안드로이드 export 템플릿, platform-tools, 필요 시 JDK 17) → W1 백엔드 / W2 Godot 네트워크·녹음·PC 설정 / W3 폰 레이아웃·export 병렬 → reviewer → 실제 폰 시험 → 커밋·푸시 → (사용자 확인 후) 릴리스에 APK.
  - 2026-10-16 22:30 안드로이드 설계 완료(`docsndroid_remote_design.md`, §17.0 결정). Phase 0 스텁 커밋 bb5049e(푸시). worktree `D:\Ai\언어pp_wt\w1~w4`(브랜치 android/w1~w4)에서 W1 백엔드 LAN·W2 네트워크/녹음/연결 화면·W3 폰 레이아웃·W4 설정/export/서명 스크립트 동시 진행(커밋은 각 브랜치, push 금지). 진짜 릴리스 키스토어는 사용자 확인 후. 병합 순서: W1·W2·W4 → W3 → 영어 v1.1 T5 연결.

**[진행 중 2026-10-16 21:20] 영어 학습 기능 강화 v1.1** — 사용자 요청("더 좋은 영어공부앱으로", 안드로이드와 동시에). designer 설계 중 → `docs\english_v11_design.md`(새 기능은 새 파일 위주, 기존 파일은 연결 지점만, 폰 세로 레이아웃 원칙). 빌드 도구(Godot 안드로이드 템플릿·platform-tools·필요시 JDK 17)는 사용자 승인 후 worker-hard `w_androidtools` 설치 중. 빌드 도구 결과: Godot 안드로이드 템플릿(SHA512 일치)·platform-tools r37.0.1(adb)·Temurin JDK 17.0.20.1(`%LOCALAPPDATA%\Android\jdk-17`, 에디터 설정 java_sdk_path) 설치 완료. 시험 APK 는 실패: 4.6.3 템플릿이 SDK 36(build-tools 36.1.0) 기준인데 SDK 에 34 만 있음 → `build-tools;36.1.0`·`platforms;android-36` 추가 설치에 사용자 승인 필요(대기). 시험 프로젝트 scratchpad `w_androidtools\proj`. 영어 v1.1 설계 완료(`docs\english_v11_design.md`: 롤플레이 미션·쉐도잉·받아쓰기·약한 소리·일일 목표/보호권/통계·교정 자동 카드, 12.0 에 오케스트레이터 결정). 구현 시작: T0 뼈대(worker `w_t0`)·T2 백엔드(worker-hard `w_t2`, 포트 8811) 동시 → T0 끝나면 T1·T3·T4. 기존 파일 연결(C1~C13)은 안드로이드와 합친 뒤 T5. 두 설계가 나오면 파일 소유권을 나누고, 겹치는 파일은 git worktree 브랜치로 분리해 순서대로 합친다.

1. [완료] 배포·업데이터: 재검토 합격(2026-10-16, 합격 조건 1~8 전부 O). 경미한 후속(v1.0.x): 롤백 시 HF `refs/main` 미복구, 실패 시 OllamaSetup.exe·LT `_download.zip`·`packaging\out\staging` 잔재, publish 정리 실패가 조용함, 테스트용 환경변수(HOEHWA_*) 배포본 잔존, prunehf가 사용자 추가 음성 팩 삭제 가능, npm 없음 시 null 오류, 재설치 시 engine.txt가 앱에서 바꾼 엔진을 덮어씀, README에 "-Yes는 deepseek 기본·로그인은 나중" 한 줄.
**2026-10-16 02:20 공개 완료.** 저장소 https://github.com/Whahan/hoehwa-practice (public, main 푸시), 릴리스 v1.0.0 https://github.com/Whahan/hoehwa-practice/releases/tag/v1.0.0 (setup 94.7MB·update 84.3MB·SHA256SUMS). 확인: 공개 링크로 setup zip 내려받아 SHA256 일치, 설치본 `update.ps1 -CheckOnly` → "최신 버전입니다 (v1.0.0)". 통합 테스트: 백엔드 6개 전부 통과, Godot 8개 통과(review_walk 퍼즈 간헐 실패는 eba78dc에서 수정, 10/10), 새 한글·공백 경로 실제 설치 603초·/health 전부 true·tts/lesson/chat/fix 정상, 설치 폴더 6.65GB. 정리: 시험 바로가기·옛 zip·export 임시물·app\backups 삭제. 시험 설치본 `D:\Ai\설치 시험\`은 사용자 승인으로 삭제함. 다음 할 일은 ROADMAP v1.0.x(아래 각 항목의 "후속"·"v1.0.x").
0. 2026-10-16 커밋 f78f5b8: 레슨 차단어·보기 품질(A, 검토 합격 + 오케스트레이터 보강), 일본어 표기·JSON 파서·피드백 재시도·config 보호(B, 3차 검토에서 남은 2건(최상위 배열·닫히지 않은 <think>)·곡선 따옴표는 오케스트레이터가 직접 고치고 검토자 시험 45건+작업자 74+28건 재실행 통과). 지금: 8번 통합 테스트·빌드·실제 설치를 worker-hard `w_integ`에 맡김(설치 시험 폴더 `D:\Ai\설치 시험\회화 연습 1.0.0\`). 이전 기록: 검토 통과분(배포·AI 엔진·레슨·음성) 로컬 커밋 0ae7f50. 진행 중: (A) worker-hard `w_lessonblock` — lesson_rules.py 차단어 확장(heroin/cocaine/abortion/kidnap…)·일본어 과잉 차단(ばかり/神戸…) 수정·접두어 오답 보기(mid/anti) 제거; (B) worker-hard `w_jpfeed` — server.py 일본어 reading 로컬 가나 교정·/feedback 형식 재시도·test_features 억양 2건 실패·prefetch WordNet 표시. 둘 다 끝나면 reviewer → 커밋 → 8번 통합 테스트. (A 검토 합격 → 오케스트레이터가 차단어 소폭 추가(bullshit, abduct*, hanged, pistol/rifle, alcoholic, 殺し屋, 人殺し)와 `ensure_wordnet_data()`가 디스크 기준으로 True/False 반환하도록 수정, test_lesson_rules 0 problem(s) 확인. B는 검토 불합격(잘린 JSON이 안쪽 객체로 복구돼 가짜 200, 髙橋·﨑山 같은 정상 일본어가 중국어로 오판돼 글자 삭제) → 작성 worker-hard에 되돌림(+ ja_reading 확장 한자, scrub_ko 빈 괄호, `--prefetch --stt-cpu`가 config.json을 덮어쓰는 문제). 검토 중 덮어써진 config.json은 git으로 원복함.) 남은 영어 과잉 차단 'shoot photos'는 v1.0.x. 일본어 AI 레슨 문장에 중국어 글자 정리(`finish_ex`에 `ja_fix_foreign`)는 v1.0.x 후보. 한국어 번역 차단 BLOCK_KO 가 '총','죽' 부분 문자열로 과잉 차단 → v1.0.x.
2. [완료 — 재검토 합격, WordNet prefetch 줄 출력 반영됨] 규칙 기반 레슨: 지적 사항(동의어 오답·차단어·깨진 DB 500·AI 검증 fail-open·--base 필수) worker-hard 수정 완료(2026-10-16), API.md 반영, reviewer 재검토 중(임시 폴더 w_review_lesson2). 새 의존성 nltk==3.9.2 → 잠금 파일 반영 완료(잠금은 build_dist가 venv에서 매번 다시 만들고 git 미추적이 정상). 후속: prefetch가 WordNet을 Tatoeba 준비 시에만·실패해도 조용히 받음 → `[prefetch] WordNet OK/FAIL` 줄 출력하게(레슨 재검토 끝난 뒤 4번 (a)와 함께).
3. [완료 — v1.0.0 포함] 레슨 화면: 실제 예문 / AI 레슨 선택, 예문 출처 표시 (worker). 끝나면 reviewer.
4. [완료 — 재검토 합격 2026-10-16] 후속(v1.0.x): (a) 일본어 채팅 reading에 한자/중국어가 섞이는 경우(예: 买) 검사·재시도, /feedback 형식 오류 502 가끔 → test_backend가 라이브 AI 때문에 3번 중 1번만 통과; (b) [완료] `llm_opencode._write_config`가 사용자 전역 MCP url/command를 복사하던 것 → 자리표시 값으로만 끄도록 수정, `opencode debug config`로 병합 결과 확인; (c) `--ollama-url`을 닫힌 포트로 주면 실제 Ollama 앱을 띄우는 부작용(테스트 전용 인자). 원래 범위: AI 엔진 정리: Claude/Codex/Gemini CLI 엔진 완전 제거, DeepSeek V4.1 Flash 무료(`opencode serve`, 모델 `opencode/deepseek-v4.1-flash-free`) 기본, 로컬 qwen3:8b 자동 전환, LanguageTool 교정, AI 결과 캐시. 끝나면 reviewer.
5. [완료 — v1.0.0 포함] 대화 음성: 미리 만들기, 문장 단위 재생, GPU 사용, Kokoro 목소리 고르기, 음성 캐시 300MB 제한 (worker-hard). 끝나면 reviewer. 음성 모델 자체는 Kokoro 유지(사용자 결정).
6. [완료 — v1.0.0 포함, 경미한 후속은 11번] 설치 프로그램 단순화(worker-hard): 엔진 선택지를 "DeepSeek 무료(기본, opencode 설치 + `opencode auth login`)"와 "오프라인 로컬(qwen3:8b)" 두 개로. 업데이터 정리 정책: 백업은 직전 1개만, 내려받은 zip·임시 폴더 즉시 삭제, pip 캐시 남기지 않기, 새 잠금 목록에 없는 모델 파일·옛 Ollama 모델 삭제, 업데이트 전후 앱 폴더 용량 표시. 배포판 기본 config.json은 `llm_provider: opencode`(개발 PC 값이 들어가지 않게). 1번 검토 지적 사항도 함께. 끝나면 reviewer.
7. DeepSeek(무료) vs 로컬 qwen3:8b 비교표: `C:\Users\rtyu6\AppData\Local\Temp\claude\D--Ai---\9cb41c31-c114-4117-abfc-6c62dfb3d0b7\scratchpad\bench_models.py`로 같은 문장 비교(대화 질문 응답, 번역, 교정, AI 레슨, 속도). 결과를 ROADMAP과 사용자 보고에 반영.
8. 통합 테스트: backend `test_backend.py`, `test_reading.py`, `test_lesson_rules.py`, `test_offline_ai.py`, `test_features.py` + Godot `smoke`, `fsrs_test`, `review_walk_test`, `prosody_test`, `reading_test`, `live_test`. 최종 exe(`godot` export → `dist\회화연습.exe`), `packaging\build_dist.ps1 -Release 1.0.0`.
9. **공개 (사용자 승인됨, 조건부)**: 8번 통합 테스트 통과 + 만든 설치 zip으로 새 폴더(한글·공백 경로)에 실제 설치가 성공하고 `/health` 전부 true일 때만 진행. 공개 전 파일 점검(CLAUDE.md 공개 체크리스트) → `gh repo create Whahan/hoehwa-practice --public --source D:\Ai\언어\app --push` → `packaging\publish_release.ps1 -Version 1.0.0` → 릴리스 링크와 `업데이트.bat -CheckOnly`로 실제 확인. 조건을 못 맞추면 진행하지 말고 이유를 적는다.

### 공개 이후 규칙 (사용자 승인)

- reviewer 검토를 통과한 변경마다 커밋하고 `git push` 한다(git 작성자: Whahan / 90018039+Whahan@users.noreply.github.com, 저장소 로컬 설정에 이미 있음).
- 사용자에게 가는 업데이트(앱 동작이 바뀌는 묶음)는 전체 테스트 통과 + 공개 스크립트의 비밀값 검사 통과 후 `publish_release.ps1 -Version <다음 버전>`으로 릴리스한다. 버전은 기능 추가면 부 버전, 버그 수정이면 수 버전을 올린다.
- 릴리스나 저장소를 지우고 다시 만들지 않는다. 문제가 있으면 새 버전으로 고친다.
11. [진행 중 2026-10-16 18:30 — (A) 검토 합격·커밋 8e0bf21 푸시 완료(성능 항목 1회 흔들림, 재실행 통과); (B) 검토 2회(지적 3건 수정 + 기존 설치 표시는 오케스트레이터가 update.ps1에 추가) 합격 → 커밋 f20d35f 푸시. 전체 테스트(백엔드 5·Godot 6) 통과, 1.0.1 빌드, 새 v1.0.0 시험 설치(`D:\Ai\설치 시험 101\`) → 업데이트 1.0.1 성공·/health 전부 true. 지적: v1.0.0→1.0.1 첫 업데이트는 옛 update.ps1이 돌아 표시가 안 생김 → install.ps1이 version.txt도 완료로 보고 engine-pending.ok로 끊긴 새 선택을 구분하도록 수정, reviewer `w_rev_eng3` 합격 → 커밋 03f8378 푸시. publish DryRun OK(자산·체크섬·비밀값 검사 통과, `packaging\outelease_1.0.1` 준비됨). **실제 릴리스는 자동 실행 권한 분류기가 막음 → 사용자가 직접 실행하거나 권한 허용 필요**: `publish_release.ps1 -Version 1.0.1 -NotesFile <노트> -SkipBuild` (노트 초안은 이번 세션 scratchpad `notes_1.0.1.md`). 릴리스 후 링크 내려받기·`업데이트.bat -CheckOnly` 확인. 시험 설치본 `D:\Ai\설치 시험 101\`(6.65GB)은 삭제 여부 사용자 결정] v1.0.1 수정 묶음: (A) worker-hard `w_lessonfix` — BLOCK_KO '총·죽' 과잉 차단, 영어 'shoot photos' 과잉 차단, 일본어 AI 레슨 finish_ex에 ja_fix_foreign, `--ollama-url` 닫힌 포트 시 Ollama 실행 부작용. (B) worker-hard `w_updfix` — 1번의 경미한 후속(a~h: HF refs/main 롤백, 실패 잔재, publish 정리 경고, prunehf 사용자 파일, npm null, engine.txt 덮어쓰기, HOEHWA_* 훅, README 한 줄). 각각 reviewer → 커밋·푸시 → 전체 테스트 → v1.0.1 릴리스.
10. 공개 후 개발 PC 정리: `app\backups\`, `packaging\out\`의 예전 zip, scratchpad 테스트 파일, 테스트 로그.

## 완료 기록

- (작업 세션이 단계를 끝낼 때마다 여기에 날짜와 한 줄을 적습니다)
- 2026-10-15 23:20 로컬 git 저장소 생성, 첫 커밋 da95917 (작성자 Whahan, noreply 이메일). 아직 푸시 안 함.
- 2026-10-15 23:20 레슨 화면 실제 예문/AI 선택·출처 표시 완료(64+29 테스트 통과), 시작 화면 문구 수정.
- 2026-10-15 23:20 큰 로컬 모델(gemma4:26b, qwen3.6) 너무 느려 삭제. qwen3:8b만 유지.
- 2026-10-16 대화 음성(사전 합성·문장 단위 재생·목소리 선택·캐시 300MB) 검토: 깨진 캐시 파일 재합성 문제만 불합격 → 오케스트레이터가 `_wav_ok` 검사로 수정·확인(빈/엉뚱한/잘린 파일 3건 모두 재합성). GPU TTS는 torch가 CPU 전용이라 불가(로드맵).
- 2026-10-16 AI 엔진: 1차 검토 불합격(앱이 OpenCode 키를 읽음 등) → 수정 완료, 재검토 중. 배포 수정본 재검토 중. 레슨 지적 수정 진행 중.
- 2026-10-16 **사용자 결정**: 사용자가 OpenCode 약관을 확인했고 "써도될듯" → 배포판 기본 엔진은 무료 DeepSeek(OpenCode, 각 사용자 본인 계정 로그인) 유지. 오프라인 로컬은 설치 2번 선택지. 9번 공개 진행 가능(다른 조건은 그대로).
- 2026-10-16 18:50 v1.0.1 (A) 레슨 과잉 차단(총·죽·shoot)·AI 일본어 레슨 중국어 글자 정리·--ollama-url 시 Ollama 미실행: reviewer 합격(1~8 O) → 커밋 8e0bf21 푸시.
- 2026-10-16 19:40 v1.0.1 (B) 설치·업데이터 후속 a~h: reviewer 합격(재검토 포함) → 커밋 f20d35f 푸시. 오케스트레이터 보강: 업데이트 성공 시 engine-config.ok 생성(v1.0.0 설치도 재설치 때 앱 엔진 유지). 남은 예외: 재설치가 10단계 전에 끊긴 뒤 설치 대신 업데이트를 돌리면 새로 고른 엔진이 다음 재설치에서 유지 처리됨(드묾).
- 2026-10-16 20:20 v1.0.1 후보: 전체 테스트(백엔드 5, Godot 6) 통과, v1.0.0 새 설치→1.0.1 업데이트 성공, install.ps1 엔진 유지 보강(03f8378, 검토 합격). 릴리스는 권한 차단으로 미실행.
- 2026-10-16 21:00 **v1.0.1 공개** (사용자 승인, 메인 세션에서 실행): https://github.com/Whahan/hoehwa-practice/releases/tag/v1.0.1 . 공개 링크로 setup·update zip 내려받아 SHA256 일치, releases/latest = v1.0.1, 1.0.0 설치의 `update.ps1 -CheckOnly` → "새 버전이 있습니다: v1.0.0 -> v1.0.1". 시험 설치본 `D:\Ai\설치 시험 101\` 삭제(바로가기 없음). 참고: publish_release.ps1 은 여러 줄 노트를 -Notes 로 넘기면 깨짐 → -NotesFile 사용.
