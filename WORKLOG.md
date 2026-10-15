# 작업 인수인계 (WORKLOG)

이 문서는 세션이 한도에 걸려 끊겼을 때 다른 세션(예약 작업)이 이어받기 위한 것입니다. 작업하는 세션은 단계를 끝낼 때마다 이 문서와 `.orchestrator_heartbeat`를 갱신합니다.

- 작업 규칙: `C:\Users\rtyu6\.claude\CLAUDE.md` (역할별 에이전트 designer / worker / worker-hard / reviewer, 모두 effort high, O/X 합격 조건, 독립 검토, 프로세스는 PID로만 종료, 비밀값 출력 금지)
- 구조와 API 규칙: `D:\Ai\언어\app\API.md`, 개발 계획: `D:\Ai\언어\app\ROADMAP.md`, 사용 설명: `D:\Ai\언어\app\README.md`
- 앱 서버는 포트 8770(사용자 앱이 씀, 건드리지 말 것). 테스트는 `backend\.venv\Scripts\python.exe backend\server.py --port <빈 포트> --tag <이름> --stt-cpu`로 따로 띄우고 PID로 끈다.
- Godot 콘솔: `C:\Users\rtyu6\Desktop\Godot_v4.6.3-stable_win64.exe\Godot_v4.6.3-stable_win64_console.exe` (폴더 경로)

## 남은 작업 (위에서부터 순서대로)

1. [진행 중] 배포·업데이터: 검토 불합격(공개 스크립트 비밀검사 오판, -Notes 빈값). worker-hard가 6번(설치 2선택지·찌꺼기 정리·중립 config·.gitattributes)과 함께 수정 중. 끝나면 reviewer 재검토.
2. [진행 중] 규칙 기반 레슨 독립 검토(reviewer) 결과 확인. 같은 방식.
3. [진행 중] 레슨 화면: 실제 예문 / AI 레슨 선택, 예문 출처 표시 (worker). 끝나면 reviewer.
4. [진행 중] AI 엔진 정리: Claude/Codex/Gemini CLI 엔진 완전 제거, DeepSeek V4.1 Flash 무료(`opencode serve`, 모델 `opencode/deepseek-v4.1-flash-free`) 기본, 로컬 qwen3:8b 자동 전환, LanguageTool 교정, AI 결과 캐시. 끝나면 reviewer.
5. [진행 중] 대화 음성: 미리 만들기, 문장 단위 재생, GPU 사용, Kokoro 목소리 고르기, 음성 캐시 300MB 제한 (worker-hard). 끝나면 reviewer. 음성 모델 자체는 Kokoro 유지(사용자 결정).
6. 설치 프로그램 단순화(worker-hard): 엔진 선택지를 "DeepSeek 무료(기본, opencode 설치 + `opencode auth login`)"와 "오프라인 로컬(qwen3:8b)" 두 개로. 업데이터 정리 정책: 백업은 직전 1개만, 내려받은 zip·임시 폴더 즉시 삭제, pip 캐시 남기지 않기, 새 잠금 목록에 없는 모델 파일·옛 Ollama 모델 삭제, 업데이트 전후 앱 폴더 용량 표시. 배포판 기본 config.json은 `llm_provider: opencode`(개발 PC 값이 들어가지 않게). 1번 검토 지적 사항도 함께. 끝나면 reviewer.
7. DeepSeek(무료) vs 로컬 qwen3:8b 비교표: `C:\Users\rtyu6\AppData\Local\Temp\claude\D--Ai---\9cb41c31-c114-4117-abfc-6c62dfb3d0b7\scratchpad\bench_models.py`로 같은 문장 비교(대화 질문 응답, 번역, 교정, AI 레슨, 속도). 결과를 ROADMAP과 사용자 보고에 반영.
8. 통합 테스트: backend `test_backend.py`, `test_reading.py`, `test_lesson_rules.py`, `test_offline_ai.py`, `test_features.py` + Godot `smoke`, `fsrs_test`, `review_walk_test`, `prosody_test`, `reading_test`, `live_test`. 최종 exe(`godot` export → `dist\회화연습.exe`), `packaging\build_dist.ps1 -Release 1.0.0`.
9. **공개 (사용자 승인됨, 조건부)**: 8번 통합 테스트 통과 + 만든 설치 zip으로 새 폴더(한글·공백 경로)에 실제 설치가 성공하고 `/health` 전부 true일 때만 진행. 공개 전 파일 점검(CLAUDE.md 공개 체크리스트) → `gh repo create Whahan/hoehwa-practice --public --source D:\Ai\언어\app --push` → `packaging\publish_release.ps1 -Version 1.0.0` → 릴리스 링크와 `업데이트.bat -CheckOnly`로 실제 확인. 조건을 못 맞추면 진행하지 말고 이유를 적는다.

### 공개 이후 규칙 (사용자 승인)

- reviewer 검토를 통과한 변경마다 커밋하고 `git push` 한다(git 작성자: Whahan / 90018039+Whahan@users.noreply.github.com, 저장소 로컬 설정에 이미 있음).
- 사용자에게 가는 업데이트(앱 동작이 바뀌는 묶음)는 전체 테스트 통과 + 공개 스크립트의 비밀값 검사 통과 후 `publish_release.ps1 -Version <다음 버전>`으로 릴리스한다. 버전은 기능 추가면 부 버전, 버그 수정이면 수 버전을 올린다.
- 릴리스나 저장소를 지우고 다시 만들지 않는다. 문제가 있으면 새 버전으로 고친다.
10. 공개 후 개발 PC 정리: `app\backups\`, `packaging\out\`의 예전 zip, scratchpad 테스트 파일, 테스트 로그.

## 완료 기록

- (작업 세션이 단계를 끝낼 때마다 여기에 날짜와 한 줄을 적습니다)
- 2026-10-15 23:20 로컬 git 저장소 생성, 첫 커밋 da95917 (작성자 Whahan, noreply 이메일). 아직 푸시 안 함.
- 2026-10-15 23:20 레슨 화면 실제 예문/AI 선택·출처 표시 완료(64+29 테스트 통과), 시작 화면 문구 수정.
- 2026-10-15 23:20 큰 로컬 모델(gemma4:26b, qwen3.6) 너무 느려 삭제. qwen3:8b만 유지.
