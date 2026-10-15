# 작업 인수인계 (WORKLOG)

이 문서는 세션이 한도에 걸려 끊겼을 때 다른 세션(예약 작업)이 이어받기 위한 것입니다. 작업하는 세션은 단계를 끝낼 때마다 이 문서와 `.orchestrator_heartbeat`를 갱신합니다.

- 작업 규칙: `C:\Users\rtyu6\.claude\CLAUDE.md` (역할별 에이전트 designer / worker / worker-hard / reviewer, 모두 effort high, O/X 합격 조건, 독립 검토, 프로세스는 PID로만 종료, 비밀값 출력 금지)
- 구조와 API 규칙: `D:\Ai\언어\app\API.md`, 개발 계획: `D:\Ai\언어\app\ROADMAP.md`, 사용 설명: `D:\Ai\언어\app\README.md`
- 앱 서버는 포트 8770(사용자 앱이 씀, 건드리지 말 것). 테스트는 `backend\.venv\Scripts\python.exe backend\server.py --port <빈 포트> --tag <이름> --stt-cpu`로 따로 띄우고 PID로 끈다.
- Godot 콘솔: `C:\Users\rtyu6\Desktop\Godot_v4.6.3-stable_win64.exe\Godot_v4.6.3-stable_win64_console.exe` (폴더 경로)

## 남은 작업 (위에서부터 순서대로)

1. [진행 중] 배포·업데이터 독립 검토(reviewer) 결과 확인. 불합격 항목은 worker-hard로 고치고 다시 검토.
2. [진행 중] 규칙 기반 레슨 독립 검토(reviewer) 결과 확인. 같은 방식.
3. [진행 중] 레슨 화면: 실제 예문 / AI 레슨 선택, 예문 출처 표시 (worker). 끝나면 reviewer.
4. [진행 중] AI 엔진 정리: Claude/Codex/Gemini CLI 엔진 완전 제거, DeepSeek V4.1 Flash 무료(`opencode serve`, 모델 `opencode/deepseek-v4.1-flash-free`) 기본, 로컬 qwen3:8b 자동 전환, LanguageTool 교정, AI 결과 캐시. 끝나면 reviewer.
5. [진행 중] 대화 음성: 미리 만들기, 문장 단위 재생, GPU 사용, Kokoro 목소리 고르기, 음성 캐시 300MB 제한 (worker-hard). 끝나면 reviewer. 음성 모델 자체는 Kokoro 유지(사용자 결정).
6. 설치 프로그램 단순화(worker-hard): 엔진 선택지를 "DeepSeek 무료(기본, opencode 설치 + `opencode auth login`)"와 "오프라인 로컬(qwen3:8b)" 두 개로. 업데이터 정리 정책: 백업은 직전 1개만, 내려받은 zip·임시 폴더 즉시 삭제, pip 캐시 남기지 않기, 새 잠금 목록에 없는 모델 파일·옛 Ollama 모델 삭제, 업데이트 전후 앱 폴더 용량 표시. 배포판 기본 config.json은 `llm_provider: opencode`(개발 PC 값이 들어가지 않게). 1번 검토 지적 사항도 함께. 끝나면 reviewer.
7. DeepSeek(무료) vs 로컬 qwen3:8b 비교표: `C:\Users\rtyu6\AppData\Local\Temp\claude\D--Ai---\9cb41c31-c114-4117-abfc-6c62dfb3d0b7\scratchpad\bench_models.py`로 같은 문장 비교(대화 질문 응답, 번역, 교정, AI 레슨, 속도). 결과를 ROADMAP과 사용자 보고에 반영.
8. 통합 테스트: backend `test_backend.py`, `test_reading.py`, `test_lesson_rules.py`, `test_offline_ai.py`, `test_features.py` + Godot `smoke`, `fsrs_test`, `review_walk_test`, `prosody_test`, `reading_test`, `live_test`. 최종 exe(`godot` export → `dist\회화연습.exe`), `packaging\build_dist.ps1 -Release 1.0.0`.
9. **[사용자 확인 필요 — 자동으로 하지 말 것]** 공개 전 파일 점검 → `git init`(D:\Ai\언어\app) → 커밋 → 공개 저장소 `Whahan/hoehwa-practice` 생성·푸시 → `packaging\publish_release.ps1 -Version 1.0.0` → 릴리스 링크를 실제로 열어 확인.
10. 공개 후 개발 PC 정리: `app\backups\`, `packaging\out\`의 예전 zip, scratchpad 테스트 파일, 테스트 로그.

## 완료 기록

- (작업 세션이 단계를 끝낼 때마다 여기에 날짜와 한 줄을 적습니다)
