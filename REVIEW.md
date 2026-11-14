# 검토 규칙 (reviewer 가 먼저 읽는다)

이 프로젝트에서 무엇을 실패로 보는지, 꼭 확인할 것을 적는다. 같은 종류의 실수가 반복되면 여기에 한 줄씩 더한다.

## 실패로 본다 (중요)

- **화면 시험이 실제 버튼을 누르지 않는다.** 퀴즈·시험·흐름 화면의 "끝까지 진행" 시험은 `answer()`·`next_question()` 같은 함수를 직접 부르지 말고, 보기·확인·다음 버튼의 `pressed` 를 내서 끝까지 가야 한다. 매 단계 뒤 피드백·다음 버튼이 보이는지 단언한다. (1.6.0 K2: 단계 시험이 첫 답 뒤에 멈췄는데 코드로 넘어가는 시험이 통과시켰다.)
- **사용자에게 보이는 숫자가 내부 단위 그대로다.** 초·바이트·밀리초 같은 값은 분·시간·MB 처럼 읽을 수 있는 단위로 바꿔 보여야 한다. 진행 표시(`value/target`)를 만드는 곳은 한 함수로 모은다. (1.6.0 B2: 배지 진행이 `3/3600` 으로 보였다.)
- 합격 조건 표의 항목이 X 이거나, 실행하지 않은 항목을 O 로 적었다.
- 소유 밖 파일 수정, `project.godot`·`export_presets.cfg`(권한·버전·autoload) 무단 변경.
- 시험이 실제 사용자 폴더(`%APPDATA%\Godot\app_userdata`)에 쓴다. 시험은 `APPDATA` 를 임시 폴더로 바꾸고, 앱 안에서는 `user://test_*` 만 쓴다.
- 비밀값(키·토큰·auth·keystore·release.pass) 출력·기록·복사.
- 공개 스크립트(`packaging\publish_release.ps1 -ScanOnly`)를 깨뜨리는 새 추적 파일(특히 `backend/tools/` 아래).

## 꼭 확인할 것

- 기존 시험 기대값을 근거 없이 완화하지 않았는지(지워지거나 느슨해진 단언).
- 시험이 잘못된 구현을 실제로 잡는지: 상수나 조건 하나를 임시로 틀리게 바꿔 FAIL 이 나는지 보고 `git checkout` 으로 원복.
- PC 와 폰(`--resolution 412x915 ... -- --phone`) 둘 다, 화면이면 `--font-scale=1.5`·`--dark` 도.
- 화면 시험은 `-- --api=http://127.0.0.1:9`(닫힌 포트). 단 `practice_test`·`touch_scroll_test` 는 `--api` 없이 돌린다(있으면 라이브 항목이 기존부터 실패).
- 마지막 줄 `N passed, 0 failed`, `SCRIPT ERROR:` 0줄, `TEST_GUARD on` 1줄.

## 건너뛸 것

- `backend\.venv\`, `godot\.godot\`, `packaging\out\` 아래.
- Godot 종료 때 나오는 `RID ... leaked`, `ObjectDB instances leaked` 경고(기존 현상).
- `ui_perf_test` 가 다른 Godot 프로세스와 겹쳐 한도를 조금 넘는 것은 단독 재실행으로 판정.

## 지적 형식

- 심각도: **중요**(위 실패 항목·버그·보안), **사소**(고치면 좋음), **기존 문제**(이번 변경 전부터). 불합격 사유는 중요만. 스타일 취향은 쓰지 않는다.
- 지적은 많아야 10개. 중요부터.
