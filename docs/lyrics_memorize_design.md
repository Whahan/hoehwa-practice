# 노래 공부 "가사 외우기" 모드 설계 (음악 파일 없이 가사만으로 곡 전체 외우기)

- 작성: designer (설계만, 코드·설정 수정 없음) / 조사일: 2026-10-31 / 전제: `docs\song_study_design.md`(노래 공부 v1)가 main에 병합돼 있고, **ss/u5(화면 연결: `song_view.gd`, `godot\scripts\song\*.gd`)가 진행 중**. 이 문서는 그 위에 얹는다.
- 읽은 것(코드로 확인): `core\{song_model,song_study,lrc_parser,fsrs,text_sim,study_log}.gd`, `local\{song_store,lrclib_client}.gd`, `views\song_view.gd`, `song\{song_study_screen,song_add_screen,song_meaning_tab,song_dictation_tab,song_sing_tab}.gd`, `practice\{speak_drill,dictation_diff}.gd`, `ui\{self_rate_panel,sheet}.gd`, `autoload\{route,tts,store}.gd`, `backend\server.py`의 `/stt`, `godot\tests\fixtures\song\lyrics_{en,ja}.txt`, `docs\song_study_design.md` 전체, `WORKLOG.md` 끝부분, **ss/u5 worktree의 `git diff main`**(`D:\Ai\언어\app_wt\ss_u5`, 읽기만), 초안 후속 메모 `scratchpad\song_followups.md`. LRCLIB 문서(`lrclib.net/docs.md`) 다시 읽음.
- 표기: **(추측)** = 코드·문서로 확인하지 못한 가정. **(실측 필요)** = 실제로 재야 하는 값. **(제안값)** = 합격선을 내가 정한 것. 표기 없는 것은 확인한 사실.
- 경로: 저장소 `D:\Ai\언어\app` = `<repo>`, `$GODOT = "$env:USERPROFILE\Desktop\Godot_v4.6.3-stable_win64.exe\Godot_v4.6.3-stable_win64_console.exe"`. Godot 시험 한 줄: `& $GODOT --headless --path <repo>\godot res://tests/<이름>.tscn` (마지막 줄 `== <이름> result: N passed, 0 failed ==`, 종료 0). 새 `class_name`을 만들면 먼저 `& $GODOT --headless --path <repo>\godot --import`.

---

## 0. 한눈에 보기

### 0.1 결론
**가능하고, 기존 부품을 거의 그대로 쓴다.** 새로 만드는 핵심은 (1) 음원 없는 곡 종류(`kind:"lyrics"`), (2) 줄마다의 외우기 기록(`memo.json`), (3) "점점 가리기" 규칙과 채점 연결 로직(순수 함수), (4) 외우기 화면과 가사만 추가 화면 두 개다. 곡 저장·LRCLIB·받아쓰기 비교·자가 평가·TTS·FSRS는 이미 있는 코드를 호출한다. 서버(`backend`)는 **한 줄도 바꾸지 않는다**(`/stt`, `/song/enrich`를 있는 그대로 부른다).

### 0.2 핵심 결정
| # | 결정 | 이유 |
|---|---|---|
| M-D1 | 외우기는 학습 화면의 새 탭이 아니라 **별도 화면 `SongMemoScreen`**(허브 `SongView.open_screen("memo")`). 음원 있는 곡도 학습 화면 ⋯ 메뉴에서 같은 화면을 연다. | §4.4 비교표. 음원 없는 곡을 학습 화면은 못 연다(`SongPlayer.load_song` 실패, 재생 막대 쓸모없음). u5가 `song_study_screen.gd`를 고치는 중이라 충돌 회피. |
| M-D2 | **음원 없는 곡 = `song.json`에 `"kind":"lyrics"`**, `audio` 필드는 빈 값, `duration 0`, 모든 줄 `t0=t1=0`, `source.timing="none"`. `kind`가 없으면 기존 곡(`"audio"`). 버전 `v`는 1 그대로(키 추가만). | `SongStore`·`SongModel`의 틀(저장·목록·한도·삭제·원자적 쓰기)을 그대로 쓴다. 기존 곡 JSON은 한 바이트도 달라지지 않는다(§5.1). |
| M-D3 | **줄별 외우기 기록은 곡 폴더의 별도 파일 `memo.json`**(song.json 안에 넣지 않음). 키는 줄 번호가 아니라 **줄 글자의 해시 12자리**. 곡 폴더째 지워지고, 동기화·백업 대상이 아니다. | song.json은 확인 화면·해석 탭이 통째로 다시 쓴다(잃어버린 갱신 위험), 답할 때마다 50~100 KB를 다시 쓰는 것은 낭비, 줄을 합치고 나눠도(번호가 바뀌어도) 기록이 따라간다, 가사 글자가 들어 있지 않다. |
| M-D4 | **점점 가리기**: 단계 `0%(읽기) → 25 → 50 → 75 → 100%(빈 화면)`, 줄의 단어를 **줄 글자에서 정한 시드로 섞은 고정 순서**로 가린다(앞 단계에서 가린 단어는 다음 단계에서도 가려짐). "빠르게" 선택 시 `0 → 50 → 100%`. 단어 수가 적어 같아지는 단계는 건너뜀. | 같은 줄은 언제나 같은 가림(재시도·다음 날 동일), 순수 함수라 시험이 쉽다. |
| M-D5 | **영어 단위 = 기존 `DictationDiff.split_words` 단어, 일본어 단위 = 문자 종류 덩어리(한자/히라가나/가타카나/영숫자)를 2~5자로 맞춘 것**. 형태소 분석(PC)은 쓰지 않는다. | 띄어쓰기 없는 일본어를 폰 단독에서도 같은 규칙으로 가려야 한다. `DictationDiff`·`TextSim`의 결과와 단위를 1:1로 맞추려면 단위 규칙이 같은 토큰화여야 한다(§3.3). |
| M-D6 | **채점**: 입력은 기존 `SongStudy.dictation_score`(영어 `DictationDiff.diff`, 일본어 `TextSim.similarity`) 그대로, **통과선 85**(받아쓰기와 같음). 말하기는 `/stt` 글자 → 같은 비교, **통과선 75**(제안값, 음성 인식 오차 감안). 폰 단독이면 `SelfRatePanel`(잘했어요/다시). | 새 채점기를 만들지 않는다. |
| M-D7 | **복습 일정 = 기존 `FSRS`(core\fsrs.gd)를 줄 카드에 그대로 사용**, 카드는 `memo.json`에 둔다. 기존 복습 탭(`Store.progress["review"]`)과는 **섞지 않는다**(카드를 거기에 넣지 않음). 첫 학습은 5단계를 통과하면 FSRS 학습 단계를 거친 것으로 보고 `GOOD`을 두 번 적용한다(§3.6). | `FSRS.review`는 사전 하나를 받아 새 사전을 돌려주는 순수 정적 함수라 어디 저장하든 쓸 수 있다. |
| M-D8 | **줄 읽어 주기**는 `Tts.speak(text, lang, slow)`(PC Kokoro / 폰 시스템 음성은 `Tts`가 알아서). 빈 화면 단계에서는 답을 낸 뒤(또는 "정답 보기" 뒤)에만 켠다. | 정답이 들리는 것을 막는다. |
| M-D9 | **폰 단독**: 가사만 추가(붙여넣기·LRCLIB), 외우기, 입력 채점, 자가 평가, 복습은 모두 PC 없이 된다. PC가 필요한 것은 말하기 **채점**과 해석·단어 뜻 만들기뿐. | §6.1. |
| M-D10 | 서버·`route.gd`·`api.gd`·`store.gd`·`study_log.gd`·`speak_drill.gd`·`fsrs.gd`·`dictation_diff.gd`·`text_sim.gd`·`self_rate_panel.gd`·`tts.gd` **수정 0**. 기존 파일 수정은 `song_model.gd`·`song_store.gd`(음원 없는 곡 + memo 입출력)와 u5 이후 `song_view.gd`·`song_study_screen.gd`(진입점)뿐. | 병합 충돌과 회귀 최소화. |

### 0.3 용량·한도
| 항목 | 값 |
|---|---|
| 음원 없는 곡 | 곡 수 한도 40을 **음원 곡과 같이 쓴다**(`SongStore.MAX_SONGS`), 바이트는 `song.json`+`memo.json` 합 수십 KB |
| `memo.json` | 줄 400개 × 줄당 약 150 B ≈ 60 KB **(추측)**, 읽기 상한 2 MiB(넘으면 `.bad`로 격리) |
| 한 번에 하는 줄 | 복습 줄 최대 20(`REVIEW_CAP`) + 새 줄 최대 5(`NEW_CAP`), "더 하기"로 5줄씩 추가 |
| 가사 한도 | 기존 그대로: 400줄·한 줄 200자·합계 20000자(`SongAddScreen.prepare_lyrics`) |

---

## 1. 목표와 범위

### 1.1 목표
1. 음악 파일 없이 **가사만으로 곡을 만든다**(붙여넣기 / 사용자가 버튼을 눌러 LRCLIB 검색). PC 불필요.
2. 곡의 줄을 **점점 가리며** 마지막에는 빈 화면에서 떠올려 **입력 또는 말하기**로 답한다. 틀린 단어를 보여 준다.
3. 줄마다 기억 상태를 기록하고 **잊을 때쯤 다시 묻는다**. 곡별 "외운 줄 N/M"과 "오늘 복습할 줄"을 보인다.
4. 원어민 목소리(`Tts`, 폰은 시스템 음성)로 줄을 읽어 준다.
5. 음원 있는 곡(기존)도 같은 외우기 화면을 쓸 수 있다.

### 1.2 하지 않을 것
- 따라 부르기·노래 듣기·줄 시간 맞추기(음원 없는 곡은 시간 자체가 없다).
- 벅스·나무위키 등 **자동 수집**, AI가 가사를 **생성·보충**하는 것. 가사는 사용자가 붙여넣거나 버튼으로 LRCLIB에서 받은 것만.
- 가사·외우기 기록의 동기화·내보내기·백업(`SyncDoc`·`SHARED_PREFS`에 안 넣음).
- 기존 복습 탭 카드와 섞기, `Store.add_review` 사용(사용자가 "기존 복습 카드로"를 고르지 않음).
- 서버 변경, 새 API, `StudyLog.KINDS`·`VIEWS` 변경(통계는 기존 `drill` 이벤트에 합산).
- **후속 후보로만 적는 것**(이번 범위 아님): 첫 글자 힌트 단계, 줄 누적(1줄→1~2줄→…) 연습, 곡 전체를 처음부터 끝까지 이어 말하는 전체 시험, 엄격 채점(한 단어도 틀리면 불통과), 일본어 형태소 단위 가리기(PC `reading.analyze`), 쉬움(EASY) 평가 버튼.

---

## 2. 저작권·약관 (기존 규칙을 이어받음)

| # | 항목 | 결정 | 검사 |
|---|---|---|---|
| C1 | 가사 출처 | 사용자 붙여넣기 또는 **버튼을 누를 때만** LRCLIB. 곡(폼) 하나당 `GET /api/get` 1번 + `GET /api/search` 1번(기존 `LrclibClient`·U2 규칙 그대로). 입력 중 자동 호출 없음 | M6 합격 조건(호출 수) |
| C2 | 저장 | 사용자 기기 `user://songs/<id>/`만. 동기화·백업·릴리스 zip에 안 들어감(`export_presets.cfg`의 `user_data_backup/allow=false` 그대로). `memo.json`에는 가사 글자가 없고 해시 키와 FSRS 숫자만 있다 | M2 `song_sync_guard` 확장 시험, P1(`check_zip.py`)에 `memo\.json$` 거절 패턴 포함 요청 |
| C3 | 출처 표시 | LRCLIB에서 받은 곡은 외우기 화면 하단에 기존 문구 `SongStudyScreen.DEFAULT_ATTRIBUTION`("가사: LRCLIB (lrclib.net) · 개인 학습용으로만 쓰세요")을 항상 표시 | M5 |
| C4 | 외부 전송 | 가사 찾기는 lrclib.net에 곡 제목·가수(선택으로 길이)만 보낸다. 해석·단어 뜻은 PC `/song/enrich`(기존 동의 시트 `song_consent`와 곡별 `translate` 스위치, `ai_ok = song_consent AND translate`, `SongMeaningTab.ai_ok`)로만, **사용자가 버튼을 눌렀을 때만** | M5·M6 |
| C5 | AI 가사 생성 금지 | 앱 코드에 가사를 만들어 달라는 호출이 없다. `/song/enrich`는 이미 있는 줄의 번역·읽기만 한다 | 소스 검사 |
| C6 | 시험 픽스처 | 직접 쓴 `lyrics_en.txt`(6줄)·`lyrics_ja.txt`(5줄)만(파일 머리 "직접 작성, CC0"). 실존 곡 가사 금지 | reviewer가 눈으로 확인 |

---

## 3. 외우기 규칙

### 3.1 용어
- **줄(line)**: `song.lines[i]` 중 외울 수 있는 것 = 글자가 있고, 단위가 1개 이상이며, `[Chorus]`처럼 `[ ... ]`만 있는 줄이 아님(`SongMeaningTab.is_translatable`과 같은 기준 + 단위 ≥ 1). 이런 줄만 **외울 줄**.
- **키(key)**: `MemoModel.line_key(text, lang)` = `TextSim.norm_text(text, lang).sha256_text().left(12)`. 대소문자·구두점이 달라도 같은 키. **같은 키는 한 줄로 센다**(후렴 반복은 한 번만 외움). 키가 빈 문자열이면 외울 줄이 아님.
- **M** = 곡의 서로 다른 키 수, **N** = 카드 `state == REVIEW(2)`인 키 수("외운 줄 N/M"). 줄 상태: `새 줄`(카드 없음) · `학습 중`(state 1·3) · `외움`(state 2) · `복습 시간`(카드 있고 `due ≤ now`).
- **단위(unit)**: 가릴 수 있는 조각. 영어는 단어, 일본어는 §3.3 규칙의 덩어리.

### 3.2 단계(점점 가리기)
| 설정 | 가리는 비율 | 단계 번호 |
|---|---|---|
| 보통(기본) | 0%, 25%, 50%, 75%, 100% | 0, 1, 2, 3, 4 |
| 빠르게(`memo_fast`) | 0%, 50%, 100% | 0, 1, 2 |

- 가리는 개수 = `ceil(비율 × 단위 수)`, 비율 > 0이면 최소 1. **앞 단계와 개수가 같은 단계는 건너뜀**(단위가 적을 때): 단위 9개 보통 → 가림 개수 `[0, 3, 5, 7, 9]`, 8개 → `[0,2,4,6,8]`, 3개 → `[0,1,2,3]`, 2개 → `[0,1,2]`, 1개 → `[0,1]`. 맨 끝 단계(전부 가림)는 항상 마지막.
- **가리는 순서**: `MemoMask.hide_order(n, seed)` = 각 위치 `i`의 `mix(seed, i)` 값 오름차순 정렬(동률은 `i`). `seed = 줄 키 앞 8자리를 정수로`. 엔진 난수(`RandomNumberGenerator`)를 쓰지 않는다 — 플랫폼·버전이 달라도 같은 결과여야 하므로 32비트 정수 연산만(`mix` = splitmix32 계열, 공식은 M1이 정하고 시험에 고정). 가림 집합은 순서의 앞 `count`개 → **단계가 올라가도 앞 단계에서 가린 것은 계속 가려진다**.
- 단계 0 = **읽기**(전부 보임, 원어민 읽어 주기 가능, 답하지 않고 [다음 단계]만). 새 줄은 단계 0에서 시작, **복습 줄은 맨 끝 단계(빈 화면)에서 시작**.
- **빈 화면**(맨 끝 단계): 줄 글자는 화면 어디에도(라벨·버튼·툴팁·접근성 이름 포함) 없다. 줄 번호 "3/12"와 (설정 켬이면) **이전 줄**, 입력칸 또는 녹음 버튼만 보인다.

단계별로 무엇이 보이는가:
| 요소 | 단계 0(읽기) | 중간 단계(가림 있음) | 빈 화면 | 정답 공개(결과 뒤) |
|---|---|---|---|---|
| 줄 글자 | 전부 | 가린 단위는 `____`(고정 4칸, 길이 힌트 없음), 구두점·띄어쓰기 유지 | 없음 | 전부, 틀린 단위 표시 |
| 일본어 읽기(`reading`)·한글 발음 | 있으면 표시 | 숨김 | 숨김 | 표시 |
| 한국어 해석(`ko`) | 있으면 표시 | 있으면 표시 | 숨김 | 표시 |
| 이전 줄 힌트(`memo_prev_cue`, 기본 켬) | 표시 | 표시 | 표시 | 표시 |
| 원어민 읽어 주기 | 켬 | 꺼짐(전체 읽기는 정답 노출) | 꺼짐 | 켬 |

### 3.3 단위 나누기
**영어**: `MemoMask.units(text, "en")` = `DictationDiff.split_words`와 **같은 규칙**(정규식 `[^A-Za-z0-9'À-ÖØ-öø-ÿ]+`로 나누고 앞뒤 `'` 제거)으로 단어와 **원문 위치**(`s`,`e`)를 구한다. 개수가 `DictationDiff.word_count(text)`와 다르면(`o.k.` 같은 특수 처리 줄) `aligned:false` → 그 줄은 공백으로 이은 단어 목록으로만 보이고(구두점 생략), 채점 표시는 단어 목록 기준.
**일본어**(`ja_split`, 순수 함수, 형태소 분석 안 씀):
1. 글자를 종류로 나눠 덩어리(run)로 만든다. 종류: **한자**(4E00–9FFF, 3400–4DBF, F900–FAFF, 々〆) / **히라가나**(3041–309F) / **가타카나**(30A0–30FF, ー, 31F0–31FF, FF66–FF9F) / **영숫자**(ASCII·전각). 공백·구두점(`TextSim.JA_SKIP`)과 그 밖 문자는 덩어리를 끊는 구분자(화면에는 그대로 남음).
2. 히라가나 덩어리가 5자 이상이면 앞에서부터 3자씩 자른다(남는 1자는 앞 조각에 붙이고, 남는 2자는 별도 조각).
3. 구분자 없이 이어진 조각들 안에서, 1자 조각은 **한자면 뒤 조각과**, 그 밖이면 앞 조각과 합친다(앞/뒤가 없으면 있는 쪽). 1자 조각이 없어질 때까지 반복. 줄 전체가 1자면 그대로.
- 성질(시험): 단위를 이으면 `JA_SKIP` 글자를 뺀 줄 글자와 같다 / 줄에 2자 이상이 있으면 1자 단위가 없다 / 같은 입력은 항상 같은 결과.
- 한계(추측, 실측 필요): 언어학적 경계가 아니라 **2~5자 덩어리**다. 가리는 데는 지장이 없다고 보지만(가림 위치는 시드로 흩어짐) 어색하면 후속으로 PC 형태소(`words[]`)를 우선 쓰는 방식을 검토.

### 3.4 채점(`MemoGrade.grade`)
```
grade(lang, said, line: Dictionary{text, reading}, via: "type"|"speak"|"self") -> {
  score: int(0-100), passed: bool, via, threshold: int, good: bool,
  marks: Array[bool]   # 줄의 단위마다 맞음/틀림 (units와 같은 길이, aligned:false면 단어 목록 기준)
  extra: Array[String] # 더한 단어(영어만)
  said: String, silent: bool }
```
- 영어: `SongStudy.dictation_score(lang, said, line)` = `DictationDiff.diff`. `marks[i] = diff.words[i].ok`. 틀린 단어의 `kind`(`missing`/`typo`)와 `said`도 `detail`에 둔다.
- 일본어: 통과 판정 점수 = `TextSim.similarity(said, text, reading, "ja").score`(읽기가 있으면 둘 중 높은 쪽). 단위 표시는 **줄 글자만**(`TextSim.similarity(said, text, "", "ja").hit`)에서 단위 글자 범위(`JA_SKIP` 글자는 건너뜀)별로 전부 맞아야 `true`. 읽기 쪽이 이겨서 통과하면 `marks`는 모두 `true`.
- 통과선: `PASS_TYPE = 85`(`SongDictationTab.PASS_SCORE`와 같음), `PASS_SPEAK = 75`(제안값). "좋음"(FSRS Good 후보) 선: `GOOD_TYPE = 95`, `GOOD_SPEAK = 85`. `via:"self"`는 "잘했어요" = `passed:true, good:true, score:100`, "다시" = `passed:false`.
- `said`가 빈 문자열/공백이면 `silent:true, score:0` — **시도로 세지 않는다**(입력은 [확인] 단추를 막고, 말하기는 무음 안내).
- 영어에서 한 단어 빠짐은 통과할 수 있다(9단어 줄에서 94점). 이때 `good:false`라 평가가 Hard가 되고 틀린 단어는 표시된다(엄격 채점은 후속).

### 3.5 한 줄의 진행(상태기계, `MemoSession`)
- 단계 통과(`passed`) → 다음 단계. 맨 끝 단계 통과 → **줄 끝**.
- 같은 단계에서 **두 번 틀리면** 정답을 보여 주고(정답 공개) 단계를 **하나 내린다**(최소 1), 틀린 횟수를 0으로. [정답 보기] 단추도 같은 효과(그 단계 틀린 것으로 침).
- 평가(FSRS)는 **맨 끝 단계의 결과만** 본다: 맨 끝에서 정답 공개가 있었으면 `Again(1)`, 맨 끝에서 틀린 적이 있거나 첫 시도가 `good:false`면 `Hard(2)`, 아니면 `Good(3)`. 중간 단계의 실패는 평가에 영향이 없다(학습 과정이므로).
- [이 줄 나중에]: 기록 변경 없음(새 줄이면 도달한 단계만 `memo.json`의 `stage`에 저장해 다음에 이어서).
- "연습만"(줄 목록에서 외운 줄을 눌러 연습): 평가·통계 기록 없음.

### 3.6 복습 일정(FSRS) 연결
- 줄(키)마다 카드 1개: `FSRS.new_card(now)`와 같은 필드(`due stability difficulty state step last_review reps lapses`).
- **새 줄이 줄 끝에 도달**했을 때 카드가 없으면 `new_card` 후: `Good` → `FSRS.review`를 `GOOD`으로 **두 번**(같은 `now`; 5단계 통과를 학습 단계 1분·10분을 마친 것으로 봄) → state 2(복습), 첫 간격 약 1~4일 **(추측, 시험으로 확인: `FSRS.fuzz_override` 고정 후 `due − now`가 86400~345600)**. `Hard` → `GOOD` 한 번만(state 1, 10분 뒤). `Again` → `AGAIN` 한 번(1분 뒤).
- **카드가 있는 줄**(복습 줄)은 평가 하나를 `FSRS.review(card, rating, now)`로 한 번 적용.
- **오늘 복습할 줄** = `due ≤ now`인 카드(오래된 순, 최대 `REVIEW_CAP=20`). 학습 중 카드의 10분·1분 간격도 같은 규칙이라, 세션이 끝난 뒤 시간이 되면 다시 나온다.
- 시계가 거꾸로 가도(`now < last_review`) 예외 없이 유한한 정수 `due`를 낸다(시험).

### 3.7 말하기·입력·폰 단독
| 상황 | 입력으로 답하기 | 말하기 |
|---|---|---|
| PC 앱 | 가능 | `RecorderWidget` → `SpeakDrill.request("/stt", {lang, audio_b64})` → `text` → `MemoGrade(via:"speak")`. `/stt` 오류·`Backend` 미준비면 오류 안내 + **자가 평가로 전환**(시도로 세지 않음) |
| 폰 + PC 연결 | 가능 | 위와 같음(`Route.decide("POST","/stt") == "pc"`) |
| 폰 단독 | 가능 | `Route.decide("POST","/stt") == "none"`이면 **`/stt`를 부르지 않고** `SelfRatePanel`: 녹음 → 내 목소리/원어민 듣기(`Tts`) → 잘했어요/다시. 이 코드베이스에는 폰 음성 인식 핸들러 파일(`local\local_stt.gd`)이 아직 **없어** 지금 폰 단독의 말하기는 항상 자가 평가(있으면 자동으로 `/stt`) |
| 말하기에서 인식이 틀렸다고 느낄 때 | - | 결과 카드에 [내가 맞게 말했어요] — `via:"self"`로 통과 처리(평가는 Hard 이하로 제한하지 않음. 사용자 결정 Q3) |
- 일본어 말하기/입력은 한자·가나 표기 차이 때문에 **읽기(`reading`)가 있는 곡이 훨씬 정확**하다(PC 해석을 만든 곡). 읽기가 없는 곡에서는 가사 글자 그대로(한자 포함) 입력해야 통과(§10 R4).

---

## 4. 구조와 데이터 흐름

### 4.1 구조도
```
SongView (허브, ss/u5)
 ├ [+ 곡 추가] ─▶ SongAddScreen (음원 + 가사, PC 필요)              ← 기존, 수정 0
 ├ [가사만 추가] ─▶ SongLyricsAddScreen (신규)                      ← PC 불필요
 │     ├ 붙여넣기 / LrclibClient.find·search (사용자가 누를 때만, SongAddScreen.prepare_lyrics 재사용)
 │     └ SongStore.install_lyrics(song) ─▶ user://songs/<id>/song.json  (kind:"lyrics")
 └ 곡 탭 ─ kind=="lyrics" ─▶ SongMemoScreen (신규) ◀─ 학습 화면 ⋯ "가사 외우기" (음원 곡)
        ├ 집 화면: 외운 줄 N/M · 오늘 복습 K줄 · 줄 목록 · 설정 칩 · [해석 만들기](PC, SongMeaningTab 재사용)
        ├ SongMemoDrill (줄 하나의 단계 화면: 가린 줄 · 입력/말하기 · 결과)
        │      ├ 입력  : MemoGrade ─ SongStudy.dictation_score ─ DictationDiff / TextSim
        │      ├ 말하기: RecorderWidget ─ SpeakDrill.request("/stt") ─ MemoGrade   (폰 단독: SelfRatePanel)
        │      └ 읽어 주기: Tts.speak
        ├ MemoSession (순수: 큐·단계·평가) ─ MemoMask (가리기) ─ MemoGrade (채점)
        └ MemoModel (memo.json 보정·요약·큐 만들기) ─ FSRS.review  ─▶ SongStore.save_memo(id)
저장: user://songs/<id>/{song.json, memo.json}   (음원 곡은 audio.mp3도)
```

### 4.2 가사만 추가 흐름
1. 곡 목록 `[가사만 추가]` (PC 연결 불필요). 첫 사용이면 기존 동의 시트(`SongView.show_consent`) → 곡이 40개/400 MiB면 안내.
2. `SongLyricsAddScreen`: 언어(영/일) · 제목(필수) · 가수 · (선택) 곡 길이 `m:ss` → 출처 선택: **붙여넣기**(TextEdit, 입력하는 동안 "N줄 · M단위" 미리보기와 잘림 안내) 또는 **LRCLIB**([가사 찾기] get 1번 → 없으면 [비슷한 곡 찾기] search 1번 → 후보 선택). 길이를 적으면 `find`에 `duration`을 넘기고 안 적으면 보내지 않는다(문서상 선택 항목이지만 없을 때 결과는 **(추측)** 덜 정확 → 후보 검색이 보완).
3. `[저장하고 외우기]` → `SongAddScreen.prepare_lyrics(src, text, record)`로 줄을 만들고(시간 `t`는 버림) → `kind:"lyrics"` 곡 사전 → `SongStore.install_lyrics`. 실패 코드는 `quota_songs` `quota_bytes` `bad_song`(줄 0개) `disk_write`, 한국어 안내.
4. 허브가 `SongMemoScreen`을 연다. PC가 있고 동의했으면 집 화면에 "해석·단어 뜻을 만들 수 있어요 [만들기]" 카드(눌러야만 `/song/enrich`, `SongMeaningTab.make_missing` 재사용).

### 4.3 외우기 한 판
`[오늘 외우기]` → `MemoSession.begin`이 큐를 만든다(복습 줄 ≤20 오래된 순 → 새 줄 ≤5 곡 순서) → 줄마다 `SongMemoDrill`이 현재 단계를 그린다 → 답(입력/말하기/자가 평가) → `MemoGrade` → `MemoSession.submit` → 단계 통과/실패/정답 공개/줄 끝 → 줄 끝이면 FSRS 적용 + `SongStore.save_memo` + `StudyLog.add_event(lang, "drill", 1)`(줄 끝마다 1번, 연습만은 제외) → 다음 줄 → 큐가 비면 요약("오늘 N줄 완료, 다음 복습 ○시간 뒤", [5줄 더]).

### 4.4 외우기를 새 탭으로 넣을까, 별도 화면으로 둘까 (결정과 근거)
| 기준 | 학습 화면의 새 탭 | **별도 화면(채택)** |
|---|---|---|
| 음원 없는 곡 | `SongStudyScreen.open`이 곧바로 `player.load_song`을 부르고 재생 막대(▶ 이전/다음 줄·속도·반복)가 쓸모없이 남는다. 탭 6개 중 4개(듣기·부르기·…)가 줄 시간에 의존 | 막대 없는 자기 틀 |
| 탭 계약 `setup(song, opts{player,line,screen,save,lang})` · `on_show` · `on_hide` · `set_line(i)` | "고른 줄 하나" 모델. 외우기는 **큐·단계·세션** 모델이라 `set_line`이 의미 없음 | 허브 계약 `closed` 신호 · `open(lang, args)` · `on_hide()` · `go_back()` · `_shell`(앱 바 제목) — `SongStudyScreen`·`SongAddScreen`과 같음 |
| 화면 크기 | 탭 본문은 스크롤 한 칸, 위에 재생 막대가 자리를 차지 | 전체 화면(폰 세로) |
| ss/u5 충돌 | `song_study_screen.gd`(+121줄 수정 중)를 고쳐야 함 | 신규 파일, 진입점 한 줄(⋯ 메뉴)만 u5 뒤에 |
| 재사용 손실 | - | 탭 위젯은 그대로 임베드 가능: 해석 만들기는 `SongMeaningTab`(탭 계약대로 `add_child → setup → on_show`)을 집 화면에 넣어 쓴다 |

---

## 5. 계약 (이름·형식 고정)

### 5.1 `song.json` 변경 (음원 없는 곡)
```json
{"v": 1, "kind": "lyrics", "id": "s_3fa9c1d20b7e", "lang": "en",
 "title": "…", "artist": "…", "created": 1790000000, "duration": 0.0,
 "audio": {"file": "", "bytes": 0, "sha256": "", "orig_name": ""},
 "source": {"lyrics": "pasted|lrclib", "lrclib_id": null, "timing": "none", "attribution": ""},
 "offset": 0.0,
 "lines": [{"i": 0, "p": 0, "t0": 0.0, "t1": 0.0, "text": "…", "reading": "", "pron": "", "ko": "",
            "conf": null, "est": true, "stale": false, "words": []}],
 "glossary": {}, "marks": {"lines": [], "words": []}, "stats": {"plays": 0, "last": 0, "best": {}},
 "warnings": [], "app": "1.4.0"}
```
`SongModel` 변경(`core\song_model.gd`만):
- 상수 `KINDS := ["audio", "lyrics"]`, `TIMINGS`에 `"none"` 추가, `_KNOWN_TOP`에 `"kind"` 추가, `static func is_lyrics(song) -> bool`.
- `normalize`: `kind == "lyrics"`이면 `out["kind"]="lyrics"`, `duration = 0.0`, 모든 줄 `t0 = t1 = 0.0`(`_fix_times` 건너뜀, 줄 순서는 입력 순서 유지 — 동률 안정 정렬), `audio = {file:"", bytes:0, sha256:"", orig_name:""}`, `source.timing = "none"`, `offset = 0`. **`kind`가 없거나 `"audio"`면 출력에 `kind` 키를 넣지 않는다**(기존 곡의 정규화 결과는 변경 전과 완전히 같다). 알 수 없는 `kind` 값 → `"audio"`로 보정.
- 불변식(`0 ≤ t0 < t1 ≤ duration`)은 **음원 곡에만** 적용된다는 것을 주석과 시험에 명시.

### 5.2 `SongStore` 추가 (`local\song_store.gd`만, 기존 함수 동작 불변)
```gdscript
const MEMO_FILE := "memo.json"
const MAX_MEMO_BYTES := 2 * 1024 * 1024
static func install_lyrics(song: Dictionary) -> Dictionary   # {ok, id, err_code}; err: bad_song(kind!=lyrics·줄 0개·v>1) quota_songs quota_bytes disk_write
static func load_memo(id: String, song: Dictionary = {}) -> Dictionary   # 정규화된 memo. 없으면 MemoModel.new_memo(). 깨짐·2MiB 초과는 memo.json.bad로 격리하고 새 memo, last_error="bad_memo"
static func save_memo(id: String, memo: Dictionary) -> bool  # 임시 파일 → 이름 바꾸기(원자적). 곡 폴더 없음 "not_found", v>1 "read_only", 쓰기 실패 "disk_write"(기존 memo.json 유지)
static func memo_summary(id: String, now: int) -> Dictionary # 읽기 전용(격리·쓰기 없음, 목록 스레드에서 호출): {total, memorized, learning, fresh, due, next_due} 또는 {}
static func delete_memo(id: String) -> bool                  # 외우기 기록만 지움(진도 초기화)
```
- `install_lyrics`: `install`과 같은 방식(`_tmp_<id>` 폴더에 `song.json`만 쓰고 이름 바꾸기, 실패 시 부분 폴더 0), 곡 수 한도는 `usage()["songs"]`로 `install`과 **같은 한도**를 쓴다.
- `list()` 항목에 `kind: "audio"|"lyrics"` 추가. `kind=="lyrics"`면 `ready:true`(`_audio_ok`가 곡 사전을 받으므로 거기서 분기). `verify_audio`도 lyrics면 true. 나머지 키 불변.
- `memo.json`은 곡 폴더 안이라 `usage()`(폴더 안 모든 파일 합산)·`delete(id)`(폴더째 삭제)에 자동 포함된다.

### 5.3 `memo.json` (v1)
```json
{"v": 1,
 "lines": {"a1b2c3d4e5f6": {"stage": 2, "seen": 1790000500, "tries": 7, "passes": 4,
            "card": {"due": 1790086400, "stability": 2.3, "difficulty": 5.1, "state": 2, "step": 0,
                     "last_review": 1790000500, "reps": 2, "lapses": 0}}},
 "stats": {"sessions": 3, "last": 1790000500}, "app": "1.4.0"}
```
- `stage`: 새 줄이 도달한 단계(0~8, 카드가 생기면 의미 없음). `card`: `FSRS` 사전(없으면 새 줄). `tries/passes`: 시도·통과 합계(표시용, 0~1e9).
- `MemoModel.normalize(raw, now)`가 읽을 때마다 보정: `v` 정수(>1이면 읽기 전용, 저장 금지), 키는 `^[0-9a-f]{12}$`만, 항목 ≤ 400(넘으면 `seen`이 오래된 것 삭제), 숫자 아닌 값·NaN·inf·음수 → 0(또는 한도 안으로), `card`는 `FSRS.ensure_fields` 검사 후 **복구 불가능하면 카드 버림**(새 줄 취급), 알 수 없는 키 버림.
- **쓰는 때**: 줄이 끝날 때마다, [이 줄 나중에]·화면을 떠날 때. 답을 낼 때마다는 쓰지 않는다.
- `MemoModel.prune(memo, song)`: 곡에 없는 키 중 `seen`이 30일 지난 것 삭제(가사 고치기 뒤에 호출).

### 5.4 Godot 클래스 계약
| 클래스(파일) | 핵심 시그니처 |
|---|---|
| `MemoMask` (`core\memo_mask.gd`, 순수) | `const BLANK := "____"`; `static func units(text, lang) -> Dictionary` `{units: [{w, s, e}], aligned: bool}`; `static func ja_split(text) -> Array`; `static func stage_plan(n_units: int, fast: bool = false) -> Array` (단계별 가림 개수, 중복 제거, 첫 값 0·끝 값 n); `static func seed_of(key: String) -> int`; `static func hide_order(n: int, seed: int) -> Array`; `static func hidden_flags(n: int, count: int, seed: int) -> Array`; `static func render(text, lang, hidden: Array) -> String` |
| `MemoGrade` (`core\memo_grade.gd`, 순수) | `const PASS_TYPE := 85, PASS_SPEAK := 75, GOOD_TYPE := 95, GOOD_SPEAK := 85`; `static func grade(lang, said, line, via: String = "type") -> Dictionary`(§3.4); `static func self_result(good: bool) -> Dictionary` |
| `MemoModel` (`core\memo_model.gd`, 순수) | `static func new_memo() -> Dictionary`; `static func normalize(raw, now: int) -> Dictionary`; `static func line_key(text, lang) -> String`; `static func is_memo_line(line, lang) -> bool`; `static func keys_of(song) -> Array`(곡 순서, 중복 제거, `{key, i}`); `static func summary(song, memo, now) -> Dictionary`; `static func build_queue(song, memo, now, opts: Dictionary) -> Array`(`opts`: `review_cap`=20, `new_cap`=5, `only_line`=-1, `skip_new`=0); `static func prune(memo, song, now) -> void` |
| `MemoSession` (`core\memo_session.gd`, `RefCounted`) | `func begin(song, memo, now, opts) -> void`(`opts`: `fast`, `review_cap`, `new_cap`, `only_line`, `practice_only`, `prev_cue`); `func current() -> Dictionary`(§5.5); `func skip_read() -> void`; `func submit(grade: Dictionary) -> Dictionary`(이벤트 `stage_pass` `stage_fail` `revealed` `line_done` `ignored`); `func reveal() -> Dictionary`(정답 보기); `func leave_line() -> void`; `func next_line() -> bool`; `func summary() -> Dictionary`; `var memo: Dictionary`(고쳐진 기록, 호출한 쪽이 `SongStore.save_memo`) ; `var now: int` |
| `SongMemoDrill` (`song\song_memo_drill.gd`, `VBoxContainer`) | `signal event(kind: String, data: Dictionary)`; `func setup(session: MemoSession, lang: String) -> void`; `func render() -> void`; `func on_hide() -> void`(녹음·TTS·요청 정리); 노드 이름 고정(시험용): `LineBox` `CueBox` `AnswerEdit` `SubmitBtn` `RecordBox` `RevealBtn` `LaterBtn` `ListenBtn` `ResultBox` |
| `SongMemoScreen` (`song\song_memo_screen.gd`, `Control`) | 허브 계약: `signal closed`; `func open(lang, args: Dictionary)`(`args.id`, 시험용 `args.song`); `func on_hide()`; `func go_back() -> bool`(진행 중이면 집 화면으로, 집이면 `closed`); `_shell`; `var result: String`(`"back"`·`"deleted"`) |
| `SongLyricsAddScreen` (`song\song_lyrics_add_screen.gd`, `Control`) | `signal closed`, `signal song_added(song_id: String)`; `func open(lang, args)`; `go_back()`; `on_hide()`; 시험용 `lrclib_base_url`, `lrclib_factory`(U2와 같은 이름) |

### 5.5 `MemoSession.current()` 반환
```
{ok: bool, line_i: int, key: String, text: String, reading: String, ko: String, lang: String,
 kind: "new"|"review", practice_only: bool, pos: int(1부터), total: int,
 stage: int, stage_count: int, hidden: Array[bool], hidden_count: int, units: Array, aligned: bool,
 final: bool, read_only_stage: bool(단계 0), fails_stage: int, revealed: bool(정답 공개 상태),
 prev_text: String(이전 줄, prev_cue 켬일 때만), answered: bool}
```

### 5.6 새 prefs 키 (`user://prefs.json`, 동기화 화이트리스트 밖, `Store.DEFAULT_PREFS`는 건드리지 않고 `Store.prefs.get(key, 기본)`으로 읽음)
| 키 | 값 | 기본 |
|---|---|---|
| `memo_fast` | bool(빠르게: 0→50→100%) | false |
| `memo_prev_cue` | bool(이전 줄 힌트) | true |
| `memo_answer` | `"type"` \| `"speak"` | `"type"` |

### 5.7 StudyLog
줄 끝(연습만 제외)마다 `StudyLog.add_event(lang, "drill", 1)` 한 번. 시도마다·단계마다는 세지 않는다. 시간은 기존처럼 `StudyClock`이 `other`로 센다(`song` 탭이 `StudyLog.VIEWS`에 없음). `StudyLog.add_score`는 부르지 않는다(외우기는 점수 통계가 아님).

---

## 6. 기존 기능 재사용 지점

| 필요 | 재사용(파일·함수) | 방법 |
|---|---|---|
| 곡 모델·저장 | `SongModel.normalize`, `SongStore`(`list` `load_song` `save_song` `delete` `usage` `_write_atomic` `_quarantine_file` 패턴) | §5.1·5.2에서 확장 |
| 가사 줄 나누기 | `LrcParser.split_plain(text)`(연 `p` 포함), `LrcParser.parse` | **`SongAddScreen.prepare_lyrics(src, text, record)`**(정적)로 한 번에: 줄·`[Chorus]` 제거·400줄/200자/20000자 자르기·안내 문구까지 이미 있음. `t`는 쓰지 않음 |
| LRCLIB | `LrclibClient.find(track, artist, album, duration)` · `search(q, track, artist, duration)` · `abandon()`, `SongAddScreen.candidate_text/usable_record/lyric_kind/guess_from_name`(정적), 헤더·간격·429 처리 | 화면이 `add_child`하고, 사용자 탭에서만 호출. 곡 하나당 get ≤1, search ≤1(U2와 같은 카운터 `lr_get_calls` `lr_search_calls`) |
| 허브·화면 틀 | `SongView.open_screen(kind, args)`(u5), `SpeakDrill.build_shell/new_footer_row/hide_footer/fit_touch/notice`, `PageScroll`, `ColumnBox`, `UI.*`, `Sheet.open/confirm/choice`, `Toast` | `SongStudyScreen`과 같은 모양 |
| 입력 채점 | `SongStudy.dictation_score`, `DictationDiff.diff/split_words/word_count`, `TextSim.similarity/tokens/norm_text` | `MemoGrade` 안에서 호출 |
| 말하기 | `RecorderWidget(is_big, accent, space)` + `recorded(rec)`(`rec.b64`), `SpeakDrill.request(path, body, timeout)`(시험은 `SpeakDrill.api_hook`), `Api.TIMEOUT_SHORT`, `SpeakDrill.SILENT_TEXT/ERROR_TEXT/error_message` | `POST /stt` → `{text, words, duration}`(`server.py` 2899행, `talk_view.gd`·`mission_screen.gd`가 이미 같은 방식) |
| 자가 평가 | `SelfRatePanel.needed()`는 `/score` 기준이라 쓰지 않고 `Route.decide("POST","/stt",{})`로 직접 판단, 패널 자체(`SelfRatePanel.new(lang, text, rec, accent)`, `rated(good)`)는 그대로 | 외우기에서는 점수 기록(`good_result`/`StudyLog.add_score`)을 하지 않고 `rated`만 받음 |
| 읽어 주기 | `Tts.speak(text, lang, slow)`, `Tts.stop()`, `Tts.engine_now()`, `Tts.system_voices_ok()`(폰에 음성 없을 때 `KanaScreen`처럼 단추를 끄고 `Route.text_for("no_voice")`) | |
| 복습 일정 | `FSRS.new_card/review/preview/format_interval`, `FSRS.fuzz_override`(시험) | `MemoSession`이 호출, 카드 저장은 `memo.json` |
| 해석·단어 뜻 | `SongMeaningTab`(탭 계약, `make_missing`, `ai_ok`, `pc_available`, `translate_on`, `song_changed`) | 집 화면 접이식 칸에 임베드. 플레이어는 `null` 허용(코드 확인: `play_line`이 `player == null` 처리) |
| 통계 | `StudyLog.add_event(lang, "drill", 1)` | §5.7 |
| 동의 | `SongView.show_consent`·`Store.pref_bool("song_consent")` | 가사만 추가에도 첫 1회 |
| 한글 폰트·터치 | `UI.fix_cjk`, `Ds.touch_min()` | 새 색·크기 직접 지정 금지(`Pal`/`Ds` 토큰) |

### 6.1 `Route` 정책 — 폰 단독일 때
`route.gd`는 수정하지 않는다. `/song/*`은 정책 항목이 없어 폰 `phone`(폰만) 모드에서 "none"이지만, **가사만 추가·외우기는 `/song/*`를 부르지 않는다**(해석 만들기만 `/song/enrich`).
| 기능 | PC 연결 | 폰 단독(PC 없음 / 폰만 모드) |
|---|---|---|
| 가사만 추가(붙여넣기) | O | **O** (요청 0건) |
| LRCLIB 가사 찾기 | O | **O** (인터넷만 있으면; `lrclib.net` 직접) |
| 외우기(단계·입력 채점·읽어 주기·복습) | O | **O** (`Api.sent_count` 불변) |
| 읽어 주기(`Tts`) | PC Kokoro | 시스템 음성(없으면 단추 비활성 + 안내) |
| 말하기 채점 | `/stt` | **X** → 자가 평가(`SelfRatePanel`) |
| 해석·단어 뜻 만들기 | O(`SongMeaningTab`) | X (안내 문구 `SongMeaningTab.MSG_NO_PC`) |
| 곡 추가(음원) | O | X (기존) |

---

## 7. 작업 분할

공통 규칙(모든 작업): "수정 허용" 파일만 고친다. 담당은 전부 `worker-hard`(Haiku 작업자 폐지, 설계 §12.1a). 작업마다 별도 worktree(예: `D:\Ai\언어\app_wt\mm_<ID>`, 브랜치 `mm/<id>`), 임시 파일은 `scratchpad\w_<ID>\`. 프로세스는 자기가 시작한 PID만 종료, 시험용 가짜 LRCLIB는 포트 18791~18799 중 빈 곳(M6 18797, M8 18798)만, **8770·8775·8776 접속 금지**, 보고에 "남은 프로세스·열린 포트 없음". 보고 맨 앞에 합격 조건 표(항목 / O·X / 근거), 실행 안 한 항목은 "미검증". 비밀값 출력 금지. 사용자 폴더(`%APPDATA%\Godot\app_userdata\…`)를 읽지도 쓰지도 않는다 — Godot 시험은 `user://test_*`만(`SongStore.root = "user://test_songs_<태그>"`, `Store.apply_test_guard`가 prefs·progress를 `user://test_guard`로 돌림). 새 `class_name`을 만들면 `--import`. 실존 곡 가사 금지(§9).

### 7.1 작업 표
| ID | 담당 | 내용 | 수정 허용 파일(전부, 신규 포함) | 의존 | 동시 |
|---|---|---|---|---|---|
| **M0** | 오케스트레이터 | 이 문서 확정, §12.1 질문 3개 결정, ss/u5 병합 시점 정함 | 이 문서 | - | - |
| **M1** | worker-hard | `MemoMask`(단위·단계 계획·시드 순서·가리기 그리기) + `MemoGrade`(채점 래퍼) | 신규 `godot/scripts/core/memo_mask.gd`, `memo_grade.gd`, `godot/tests/memo_mask_test.gd/.tscn`, `memo_grade_test.gd/.tscn` | M0 | M2, M6와 병행 |
| **M2** | worker-hard | 자료 층: `SongModel`(kind) + `SongStore`(`install_lyrics` `load_memo` `save_memo` `memo_summary` `delete_memo`, `list` kind) + `MemoModel` | 수정 `godot/scripts/core/song_model.gd`, `godot/scripts/local/song_store.gd`; 신규 `godot/scripts/core/memo_model.gd`, `godot/tests/song_lyrics_store_test.gd/.tscn`, `memo_model_test.gd/.tscn` | M0 | M1, M6와 병행 |
| **M3** | worker-hard | `MemoSession`(큐·단계 상태기계·FSRS 적용·평가 규칙) | 신규 `godot/scripts/core/memo_session.gd`, `godot/tests/memo_session_test.gd/.tscn` | M1, M2 (이름만 알면 작성은 병행, **시험 실행은 둘 병합 뒤**) | M6와 병행 |
| **M4** | worker-hard | `SongMemoDrill`(단계 그림·입력·말하기·자가 평가·읽어 주기·결과) | 신규 `godot/scripts/song/song_memo_drill.gd`, `godot/tests/song_memo_drill_test.gd/.tscn` | M1, M3 | M6와 병행 |
| **M5** | worker-hard | `SongMemoScreen`(집 화면·세션 진행·요약·설정 칩·줄 목록·가사 고치기·진도 초기화·해석 칸) | 신규 `godot/scripts/song/song_memo_screen.gd`, `godot/tests/song_memo_screen_test.gd/.tscn` | M2, M3, M4 (해석 칸은 **ss/u5 병합 뒤 최종 확인**) | M6과 병행 |
| **M6** | worker-hard | `SongLyricsAddScreen`(붙여넣기·LRCLIB·미리보기·저장) | 신규 `godot/scripts/song/song_lyrics_add_screen.gd`, `godot/tests/song_lyrics_add_test.gd/.tscn` | M2(`install_lyrics`) | M1, M3~M5와 병행 |
| **M7** | worker-hard | 허브 연결: `SongView`에 `[가사만 추가]` 버튼·`open_screen("lyrics_add"/"memo")`·곡 탭 `kind` 분기·목록 행 "외운 줄 N/M"·삭제 문구; `SongStudyScreen` ⋯ 메뉴 "가사 외우기" + `memo_requested` 신호 | 수정 `godot/scripts/views/song_view.gd`, `godot/scripts/song/song_study_screen.gd`, `godot/tests/song_view_test.gd`, `godot/tests/song_study_screen_test.gd` | M5, M6, **ss/u5 병합 뒤 main에서 시작** | 단독 |
| **M8** | worker-hard | 종단 시험: 가사 붙여넣기→외우기→복습, LRCLIB(가짜 서버)→외우기, 폰 단독, 틀린 입력 | 신규 `godot/tests/memo_flow_test.gd/.tscn`, `godot/tests/run_memo_tests.ps1` | M7 | 단독 |
| **R1~R3** | reviewer | R1: M1~M3 순수 로직, R2: M4~M6 화면, R3: M7·M8 통합과 u5 겹침 확인. 각 단계 독립 재실행 | 없음(읽기만) | 각 단계 | - |
| **(P1 보강)** | 오케스트레이터 | 공개 검사(`packaging/check_zip.py`)에 `memo\.json$` 거절 패턴 포함 지시(P1 작업자에게) | P1 소유 | P1 | - |

### 7.2 의존 순서
```
M0 ─┬─ M1 ──────────────┬─ M3 ─ M4 ─ M5 ─┐
    ├─ M2 ──────────────┘                 ├─ M7 (ss/u5 병합 뒤) ─ M8 ─ R3
    └─ M6 (M2 뒤 시작해도 됨) ────────────┘
R1 = M1~M3 뒤, R2 = M4~M6 뒤
```
M1·M2·M6은 서로 파일이 겹치지 않아 **동시에** 진행. M3은 M1·M2의 함수 이름(§5.4)만 알면 코드는 쓸 수 있으나 시험 실행은 두 작업이 main에 병합된 뒤. M4·M5도 같은 방식. M7은 ss/u5가 main에 병합된 **뒤** main에서 새 worktree로 시작한다.

### 7.3 ss/u5와 파일 겹침 (u5 worktree `git diff main` 기준: 수정 6개 + 신규 3개)
| 파일 | u5 | 이 설계 | 충돌 대응 |
|---|---|---|---|
| `godot/scripts/views/song_view.gd` | **수정**(허브: `open_screen` `_make_screen` `_close_screen` 등 +192줄) | M7 수정 | **M7은 u5 병합 뒤**. 그 전에는 건드리지 않음 |
| `godot/tests/song_view_test.gd` | **수정**(+2) | M7 수정 | 같은 방식 |
| `godot/scripts/song/song_study_screen.gd` | **수정**(⋯ 메뉴 `open_menu` `request_check` `deleted` 등 +121줄) | M7 수정(메뉴 항목 1개 + 신호 1개) | u5 병합 뒤 |
| `godot/tests/song_study_screen_test.gd` | (u5는 안 고침, 신규 `song_flow_test`) | M7 수정 | u5 뒤 |
| `godot/scripts/song/song_add_screen.gd` | **수정**(12줄) | **읽기만**(정적 함수 `prepare_lyrics` `candidate_text` `usable_record` `lyric_kind` `guess_from_name` 호출) | M6이 호출하는 정적 함수 이름이 u5에서 바뀌면 컴파일 오류 → **u5 병합 뒤 M6 시험 재실행**(합격 조건 M6-8) |
| `godot/scripts/song/song_meaning_tab.gd` | **수정**(+45, 저장 실패 처리) | **읽기만**(`setup` `make_missing` `ai_ok` `pc_available` `translate_on` `song_changed` 사용) | M5 해석 칸은 u5 병합 뒤 재확인 |
| `godot/scripts/song/song_check_screen.gd` | **수정**(6줄) | 사용 안 함 | 없음 |
| `godot/tests/run_song_tests.ps1`, `song_flow_test.gd/.tscn` | **신규** | M8은 **별도 이름**(`run_memo_tests.ps1`, `memo_flow_test`) | 겹침 0 |
| `godot/scripts/main.gd` | 수정 없음(탭 등록은 이미 main) | **수정 0** | 없음 |
| `godot/scripts/core/song_model.gd`, `local/song_store.gd` | u5 수정 없음 | M2 수정 | 겹침 없음. 단 main이 움직이면 M2 병합 전 rebase |
| 나머지 신규 파일(`memo_*.gd`, `song_memo_*.gd`, `song_lyrics_add_screen.gd`, 새 시험) | - | M1·M3~M6 | 겹침 0 |
- 결론: **M1~M6은 u5와 완전히 독립**이라 지금 바로 시작할 수 있다. 겹치는 것은 M7뿐이고 u5 병합 뒤 순서로 해결한다.

---

## 8. 합격 조건 (O/X)

판정은 작업자 보고가 아니라 reviewer가 아래 명령을 새로 실행해 한다. "N ≥ 값"은 최소 통과 개수. **금지 조건**은 각 표의 마지막 행. 기존 시험(`song_model_test` `song_store_test` `song_sync_guard_test` `song_view_test` `song_study_screen_test` `fsrs_test` `dictation_test` `self_rate_test` `phone_layout_test` `screens_scan_test` `contrast_test` `a11y_sweep_test`)은 **변경 전 통과 수 이상, 0 failed**(작업자는 변경 전 수치를 보고에 적는다).

### M1 `MemoMask` · `MemoGrade`
| # | 조건 | 판정 |
|---|---|---|
| M1-1 | `memo_mask_test` N ≥ 40, `memo_grade_test` N ≥ 25, 둘 다 `0 failed` | 실행 2회 |
| M1-2 | 영어 단위: `lyrics_en.txt`의 6줄(`#` 주석 줄은 시험이 먼저 제거)에서 `units(...).units.size()`가 `[9,9,7,9,8,8]`이고 모두 `DictationDiff.word_count(줄)`와 같고 `aligned == true`. `units[k]`의 `[s,e)`로 원문을 잘라 `w`와 같음 | 시험 |
| M1-3 | `stage_plan`: 9 → `[0,3,5,7,9]`, 8 → `[0,2,4,6,8]`, 4 → `[0,1,2,3,4]`, 3 → `[0,1,2,3]`, 2 → `[0,1,2]`, 1 → `[0,1]`, 0 → `[0]`; 빠르게 9 → `[0,5,9]`, 1 → `[0,1]`. 모든 결과가 오름차순·중복 없음·끝값 n | 시험 |
| M1-4 | 가림: 같은 `seed`·`n`은 항상 같은 순열(`hide_order`가 0..n-1의 순열), 서로 다른 시드 5개 중 최소 2개는 서로 다른 순열(n=9), `hidden_flags(n, c1) ⊆ hidden_flags(n, c2)` (c1<c2) 모든 단계 쌍에서 성립, `true` 개수 == count | 시험 |
| M1-5 | `render("The kettle hums while the morning climbs the wall", "en", 가림 {1,5})` == `"The ____ hums while the ____ climbs the wall"` (구두점·띄어쓰기 보존: `"Nobody calls, so the quiet stays small"`에서 `calls` 가림 → `"Nobody ____, so the quiet stays small"`). 전부 가림이면 단위 글자가 하나도 남지 않음 | 시험 |
| M1-6 | 일본어 `ja_split`: `lyrics_ja.txt` 5줄 모두 (a) 단위를 이으면 `TextSim.JA_SKIP` 글자를 뺀 원문과 같음, (b) 2자 이상 줄에는 1자 단위 없음, (c) 두 번 호출한 결과 같음, (d) 한자·히라가나·가타카나·영숫자가 섞인 직접 만든 입력 6개 이상에서 (a)(b)(c) 성립. 골든 2줄은 작업자가 §3.3 규칙대로 손으로 계산해 시험에 고정하고 reviewer가 규칙대로 검산 | 시험·검산 |
| M1-7 | `MemoGrade` 영어: 정답 줄 입력 → score 100·`passed`·`good`·`marks` 전부 true; "I count my steps to the old chair"(blue 빠짐) → `marks`에서 `blue` 위치만 false, 점수가 `DictationDiff.diff` 점수와 같고(94) `passed:true, good:false`; 전혀 다른 문장 → `passed:false`; 부정어 not 추가 → `DictationDiff` 규칙대로 불통과 | 시험 |
| M1-8 | 통과선 경계: 같은 점수를 `via:"type"`은 84 불통과·85 통과, `"speak"`는 74 불통과·75 통과(점수를 직접 주입하는 시험 훅 또는 점수가 정확히 나오는 입력 사용), `good`은 type 95·speak 85 경계 | 시험 |
| M1-9 | 일본어 `MemoGrade`: 정답 → 100·marks 전부 true; 한 단위 틀림 → 그 단위만 false; 읽기(`reading`)를 주고 히라가나로 입력 → 통과, 읽기 없이 히라가나 입력 → 불통과; `JA_SKIP` 글자(구두점) 위치가 있는 줄에서도 `marks.size() == units.size()` | 시험 |
| M1-10 | **틀린 입력**: 빈 문자열·공백만 → `silent:true, score:0, passed:false`(예외 0); 2000자 입력·널 문자·이모지·`said`가 String 아닌 값(int/null) → 예외 0·점수 0~100; `line`이 빈 사전·`text` 없음 → 예외 0; `units`가 0개인 줄 | 시험 |
| M1-금지 | 수정 파일이 허용 목록 밖 0(`dictation_diff.gd` `text_sim.gd` `song_study.gd` 포함 해시 불변), `RandomNumberGenerator` 소스에 0건(`Select-String -Path godot\scripts\core\memo_mask.gd -Pattern 'RandomNumberGenerator\|randi\|randf'` 0건), 전역 상태·파일·네트워크 접근 0 | 해시·검색 |

### M2 `SongModel`·`SongStore`·`MemoModel`
| # | 조건 | 판정 |
|---|---|---|
| M2-1 | `song_lyrics_store_test` N ≥ 35, `memo_model_test` N ≥ 40 `0 failed`; 기존 `song_model_test` `song_store_test` `song_sync_guard_test` 통과 수가 변경 전 이상, 0 failed | 실행 5회 |
| M2-2 | 기존 곡 호환: 음원 곡(`kind` 없음) `normalize` 결과에 `"kind"` 키 0, 변경 전 코드로 만든 정규화 결과(작업자가 변경 전 `git stash`/`main` 커밋으로 JSON 문자열을 만들어 시험 상수로 박음)와 `JSON.stringify` 결과가 완전히 같음 | 시험 |
| M2-3 | `kind:"lyrics"` 정규화: `duration == 0`, 모든 줄 `t0 == t1 == 0`, `audio.file == ""`, `source.timing == "none"`, 줄 순서는 입력 순서, `kind:"banana"` → `"audio"` 처리, `v:2`이면 `is_read_only` | 시험 |
| M2-4 | 설치: `lyrics_en.txt` 6줄(+연 `p`)로 `install_lyrics` → `ok`, 폴더 안 파일이 `song.json` **한 개뿐**(오디오 파일·`.tmp` 0), `list()` 항목 `kind=="lyrics"` `ready==true` `duration==0` `lines==6`, `usage().bytes` < 20000, `load_song(id)`가 같은 줄 | 시험 |
| M2-5 | 실패: 줄 0개·`kind` 아님·`v:2` → `bad_song`, 폴더 0개; 41번째 곡(음원 곡 40개 + 가사 곡 1개 포함 합계) → `quota_songs`; `fake_used_bytes`로 용량 초과 → `quota_bytes`; `write_hook`이 실패 → `disk_write`·부분 폴더 0·이전 곡 정상 | 시험 |
| M2-6 | memo 입출력: 저장→읽기 왕복 동일, 파일은 `memo.json`, 곡 폴더 밖에 파일 0, **원자적**(`write_hook` 실패 후 기존 내용 그대로), 곡 폴더 없는 id에 저장 → false·`not_found`, `v:2` memo → 저장 `read_only`, `delete(id)`가 `memo.json`까지 지움, `delete_memo`는 `song.json`을 남김 | 시험 |
| M2-7 | **깨진 입력**: 잘린 JSON·배열 JSON·널 바이트·2 MiB 초과 → `load_memo`가 `memo.json.bad`로 옮기고 새 memo 반환, `last_error == "bad_memo"`, 곡(`song.json`)은 정상; `memo_summary`는 같은 깨진 파일에서 `{}`를 돌려주되 **파일을 옮기지 않음**(이름 그대로) | 시험 |
| M2-8 | `MemoModel.normalize`: 키가 12자리 hex가 아닌 항목 버림, `card`의 문자열·NaN·inf·음수 안정도·`state:9` → 카드 버림(새 줄), 숫자 한도 보정, 항목 401개 → 400개(오래된 `seen` 삭제), 알 수 없는 키 버림, `v:5` → 읽기 전용 표시 | 시험 |
| M2-9 | `line_key`: `"The kettle hums."`와 `"the KETTLE hums"` 같은 키, 다른 줄은 다른 키, 일본어 구두점 차이 무시, 구두점·공백뿐인 줄은 빈 키 → `is_memo_line` false, `[Chorus]` 줄 false; `keys_of`는 곡 순서·중복 제거(같은 줄 3번 → 1개, 처음 위치) | 시험 |
| M2-10 | `summary`: 카드 없음 → `fresh`, state 1·3 → `learning`, state 2 → `memorized`, `due ≤ now` 개수, `total`은 서로 다른 키 수(후렴 반복 제외). `build_queue`: 복습 줄이 `due` 오래된 순·상한 20, 새 줄이 곡 순서·상한 5, `only_line`은 그 줄 하나, 같은 키 두 번 안 나옴, `skip_new`로 새 줄 건너뛰기 | 시험 |
| M2-11 | 동기화 비대상: `SyncDoc.SHARED_PREFS`에 `memo_*` 0개, `SyncDoc.extract` 결과에 가사 표식 `ZZSONGLINEZZ`·`"memo"` 0건, 외우기를 한 뒤에도 `Store.progress["review"]` 길이 불변 | 시험 |
| M2-금지 | 기본 `user://songs`·`prefs.json`·`progress.json` 접근 0(시험이 `root`를 `user://test_songs_*`로 바꾸고 전후 목록 비교), `store.gd` `progress.gd` `sync_doc.gd` `fsrs.gd` 수정 0, `song_store.gd`의 기존 함수 시그니처 불변 | 목록·해시 |

### M3 `MemoSession`
| # | 조건 | 판정 |
|---|---|---|
| M3-1 | `memo_session_test` N ≥ 50 `0 failed` (모든 시험은 `FSRS.fuzz_override = 0.5`로 고정, 시계는 주입한 `now`) | 실행 |
| M3-2 | 새 줄(영어 9단위) 정상 진행: 단계 개수 5(`[0,3,5,7,9]`), 단계 0은 `skip_read`로 넘김, 매 단계 정답을 넣으면 `stage_pass` 4번 뒤 `line_done`, 평가 `Good` → 카드 `state==2`, `reps==2`, `last_review==now`, `due − now`가 86400~345600 | 시험 |
| M3-3 | 같은 단계 연속 2번 오답 → 이벤트 `revealed`, 단계가 하나 내려가고(최소 1) `fails_stage==0`; 중간 단계 실패는 최종 평가에 영향 없음(맨 끝 첫 시도 만점이면 Good) | 시험 |
| M3-4 | 맨 끝 단계에서 1번 틀리고 통과 → `Hard`: 카드 `state==1`, `step==1`, `due − now == 600`; 맨 끝 첫 시도가 `good:false`(통과는 했음) → Hard; 맨 끝에서 정답 공개 → `Again`: `state==1`, `step==0`, `due − now == 60` | 시험 |
| M3-5 | 복습 줄(카드 `state==2`, `due ≤ now`)은 **맨 끝 단계에서 시작**(`stage == stage_count-1`, `final == true`); `Good`이면 `stability`가 이전보다 크고 `due`가 이전보다 뒤; `Again`이면 `lapses`가 1 늘고 `state==3` | 시험 |
| M3-6 | `practice_only`: 줄 끝까지 가도 `memo` 사전이 `begin` 때와 완전히 같고(`==`), `line_done` 이벤트에 `counted:false`; 일반 줄 끝은 `counted:true` | 시험 |
| M3-7 | 큐: 복습 줄 25개·새 줄 10개 입력 → 큐 크기 25(복습 20 + 새 5), 순서 복습→새, 새 줄은 곡 순서; `[Chorus]` 줄·기호만 있는 줄·중복 키 제외; `only_line` 큐 크기 1 | 시험 |
| M3-8 | 나가기: 새 줄 단계 2에서 `leave_line` → `memo.lines[key].stage == 2`이고 `card` 없음, 다시 `begin`하면 단계 2에서 이어서; 복습 줄에서 `leave_line` → 카드 불변 | 시험 |
| M3-9 | `via:"self"`: 잘했어요 → 통과(`good:true`), 다시 → 실패(2번 → 정답 공개); `silent:true` 결과는 이벤트 `ignored`이고 시도·틀린 횟수·`tries` 불변 | 시험 |
| M3-10 | **틀린 입력**: `submit({})`·키 없는 사전·`passed`가 문자열 → 예외 0이고 `ignored`; 큐가 빈 상태에서 `current()`가 `ok:false`; 이미 끝난 줄에 `submit` 반복 → 평가가 두 번 적용되지 않음(`reps` 불변); `now`가 `last_review`보다 과거 → 예외 0, `due`가 유한한 정수 | 시험 |
| M3-11 | 단위 1개 줄·2개 줄(단계가 `[0,1]`, `[0,1,2]`)이 막히지 않고 끝까지 진행; 일본어 줄도 같은 시험 | 시험 |
| M3-금지 | `fsrs.gd` 수정 0, `Store`·`StudyLog` 접근 0(순수; `StudyLog` 호출은 화면 몫), 파일·네트워크 접근 0 | 해시·검색(`Select-String -Pattern 'Store\.\|StudyLog\|FileAccess'` 0건) |

### M4 `SongMemoDrill`
| # | 조건 | 판정 |
|---|---|---|
| M4-1 | `song_memo_drill_test` N ≥ 45 `0 failed`; PC `res://tests/…tscn` 와 폰 `… -- --phone` 둘 다 | 실행 2회 |
| M4-2 | 중간 단계 그림: 영어 9단위·단계 2(가림 5)에서 `LineBox` 글자 안의 `____` 개수 == 5, 보이는 단어는 가림 집합에 없는 단어, 구두점 유지; 단계 0은 전부 보임 | 시험 |
| M4-3 | **빈 화면 누출 검사**: 맨 끝 단계(답하기 전) 노드 트리 전체(`Label.text` `RichTextLabel.text` `Button.text` `LineEdit/TextEdit.text·placeholder_text` `tooltip_text` `accessibility_name`)에서 정답 줄의 3글자 이상 단어가 하나도 나오지 않음(영어 6줄·일본어 5줄 모두). 이전 줄 힌트는 켬일 때만 이전 줄 글자가 나옴 | 시험 |
| M4-4 | 일본어 읽기·한글 발음은 단계 0과 정답 공개 때만, 한국어 해석은 맨 끝 단계에서 숨김 | 시험 |
| M4-5 | 입력: 빈 입력이면 `SubmitBtn` 비활성; 정답 입력 → `event("submit", …)`로 `ResultBox`에 통과 표시("✓ 통과"), 틀리면 정답 줄과 틀린 단위에 **글자 표식**(굵게·밑줄·`✕`, 색만으로 구분 금지)이 있고 `RevealBtn`/재시도가 나옴; 영어는 더한 단어 목록 표시 | 시험 |
| M4-6 | 말하기(PC): `SpeakDrill.api_hook`으로 `/stt` 응답 `{text: …}`을 주입 → `MemoGrade(via:"speak")`; 빈 `text`(무음) → "소리가 들리지 않았어요" + 시도로 세지 않음; `/stt`가 `{ok:false}` → 오류 문구 + 자가 평가 패널(`SelfRatePanel`)로 전환; 결과가 실패일 때 [내가 맞게 말했어요]가 있고 누르면 통과 | 시험 |
| M4-7 | 폰 단독(`Route.phone_hook`으로 폰, 모드 `phone`): 말하기를 눌러도 `/stt` 호출 0·`Api.sent_count` 불변, `SelfRatePanel`이 뜨고 잘했어요 → 통과 이벤트·다시 → 실패 이벤트(점수 기록 `StudyLog.add_score` 호출 0) | 시험 |
| M4-8 | 읽어 주기: `Tts.fetch_hook`(또는 폰은 엔진 `system` 흉내)으로 호출 수를 센다 — 중간·맨 끝 단계(답 전)에서 `ListenBtn` 비활성이고 호출 0, 단계 0과 결과 뒤에는 1번 호출; 시스템 음성이 없는 폰이면 비활성 + 안내 문구 | 시험 |
| M4-9 | `on_hide()`: 녹음 중이면 취소(`Recorder.recording == false`), `Tts.stop()` 호출, 늦게 오는 `/stt` 응답은 버림(화면이 닫힌 뒤 이벤트 0) | 시험 |
| M4-10 | 레이아웃: 폰 412×915(`-- --phone`)와 `--font-scale=1.5`에서 가로 스크롤 0·잘린 글자 0(기존 시험 방식), 터치 대상 ≥ `Ds.touch_min()` | 시험 |
| M4-금지 | `speak_drill.gd` `self_rate_panel.gd` `recorder_widget.gd` `tts.gd` 수정 0, 새 색·폰트 크기 직접 지정 0(`Pal`/`Ds` 토큰만), 사용자 폴더 접근 0 | 해시·검색 |

### M5 `SongMemoScreen`
| # | 조건 | 판정 |
|---|---|---|
| M5-1 | `song_memo_screen_test` N ≥ 40 `0 failed`(PC·폰 둘 다) | 실행 2회 |
| M5-2 | 집 화면: `lyrics_en.txt` 곡(6줄)에서 "외운 줄 0/6", 오늘 새 줄 5줄 표시, 복습 0줄; 카드가 `due ≤ now`인 줄이 3개면 "오늘 복습 3줄" | 시험 |
| M5-3 | 세션 진행: [오늘 외우기] → 새 줄 하나를 단계 0→끝까지(정답 주입) 진행 → 줄 끝에서 `memo.json`이 저장되고(`SongStore.load_memo`로 카드 확인), `StudyLog` `drill` 이벤트 +1, 다음 줄로 이동; 큐가 비면 요약 화면("오늘 N줄", 다음 복습 시각) | 시험 |
| M5-4 | 진도 숫자: 줄을 외운 뒤(두 번 `Good`, state 2) "외운 줄 1/6"; 같은 줄 두 번(후렴)인 곡에서 M == 서로 다른 줄 수; `[Chorus]` 줄은 목록에서 빠짐 | 시험 |
| M5-5 | 설정 칩: "빠르게"(`memo_fast`)·"이전 줄 힌트"(`memo_prev_cue`)·답하기(`memo_answer`)가 `Store.prefs`에 저장되고 다음 세션에 반영(단계 수 5→3, 이전 줄 표시 여부) | 시험 |
| M5-6 | 뒤로 가기: 세션 중 `go_back()` → 집 화면(true, `closed` 안 나감) + 도달 단계 저장; 집에서 `go_back()` → `closed` | 시험 |
| M5-7 | 줄 목록: 줄을 누르면 "연습만" 세션(기록 변경 0); 목록 행의 상태 표시(새/학습 중/외움/복습 시간)는 글자로(색만으로 구분 금지) | 시험 |
| M5-8 | 진도 초기화: 확인 시트 후 `memo.json`만 지워지고 `song.json` 그대로, 숫자 0/M으로 | 시험 |
| M5-9 | 가사 고치기(음원 없는 곡만): 줄 하나의 글자를 고치고 저장 → 고친 줄만 새 줄(키 변경), 나머지 줄의 카드 유지, `song.json`의 줄 수·`kind` 보존; 400줄 초과·빈 가사는 저장 안 되고 안내 | 시험 |
| M5-10 | 해석 칸(PC 연결 + 동의 + `translate` 켬일 때만 `[만들기]`): 누르기 전 `/song/enrich` 호출 0, 폰 단독·미동의면 `SongMeaningTab.MSG_NO_PC`/`MSG_NO_CONSENT` 안내, 해석이 만들어진 줄은 `ko`가 단계 0~중간 단계에 보임 | 시험(`SongMeaningTab.pc_hook`·`SpeakDrill.api_hook`) |
| M5-11 | LRCLIB 출처 곡은 하단에 `DEFAULT_ATTRIBUTION` 문구, 붙여넣기 곡은 없음 | 시험 |
| M5-12 | 폰 단독(PC 없음) 전체 흐름: 집 → 세션 → 입력 채점 → 줄 끝 → 저장 동안 `Api.sent_count` 불변 | 시험 |
| M5-13 | **깨진 입력**: `memo.json`이 잘려 있으면 열 때 토스트("외우기 기록이 깨져 새로 시작했어요") + `.bad`로 격리 + 새 기록으로 정상 진행; `v:2` memo면 "이 기록은 더 새 버전이에요" 안내 + 연습은 되지만 저장 안 함; 곡 열기 실패(`id` 없음) → `MSG_OPEN_FAIL`류 안내(예외 0) | 시험 |
| M5-금지 | `Store.add_review`·`Store.progress["review"]` 접근 0(소스 검색 `Select-String -Pattern 'add_review\|progress\["review"\]'` 0건), `song_study_screen.gd` `song_view.gd` 수정 0(M7 몫), 새 색·폰트 크기 직접 지정 0 | 검색·해시 |

### M6 `SongLyricsAddScreen`
| # | 조건 | 판정 |
|---|---|---|
| M6-1 | `song_lyrics_add_test` N ≥ 40 `0 failed`(PC·폰) | 실행 2회 |
| M6-2 | 붙여넣기: `lyrics_en.txt` 내용(주석 줄 제거)을 넣고 제목 입력 → [저장하고 외우기] → `SongStore.list()`에 `kind=="lyrics"` 곡 1개, 줄 6, `source.lyrics=="pasted"`, `song_added(id)` 신호 1번; 미리보기에 "6줄" | 시험 |
| M6-3 | 제한: 401줄 붙여넣기·201자 줄·20001자 → `prepare_lyrics` 규칙대로 잘리고 안내 문구; 가사 비어 있음·제목 비어 있음 → 저장 단추 비활성 또는 안내(저장 0); `[Chorus]` 줄 제거 안내 | 시험 |
| M6-4 | LRCLIB(가짜 서버 `fake_lrclib.py`, 포트 18797): 버튼을 누르기 전 `LrclibClient` 호출 0 → [가사 찾기] 1번 눌러 get 1건 → [비슷한 곡 찾기] search 1건 → 같은 단추를 다시 눌러도 호출 수 불변(안내 토스트) → 후보 선택 → 저장하면 `source.lyrics=="lrclib"`, `lrclib_id` 기록, `attribution` 문구 저장 | 시험(서버 수신 횟수) |
| M6-5 | 길이 입력(선택): 비우면 `find` 요청에 `duration` 없음, `3:42` → 222로 전송, 잘못된 값(`abc`·`99:99`·음수)은 무시하고 안내; 제목·가수 2글자 미만이면 호출 0 | 시험(서버가 받은 쿼리) |
| M6-6 | LRCLIB 실패(가짜 서버: 429+`Retry-After`·500·연결 거부·깨진 JSON·404·연주곡): 각각 한국어 안내 + 붙여넣기로 대체 안내, 크래시 0, 요청이 `LrclibClient` 규칙(≥400 ms 간격, 429 자동 재시도 ≤1) 안 | 시험 |
| M6-7 | **폰 단독**(PC 없음·`phone` 모드): 붙여넣기 저장이 되고 `Api.sent_count` 불변; PC 안내 문구 없이 동작 | 시험 |
| M6-8 | 호출하는 정적 함수(`SongAddScreen.prepare_lyrics/candidate_text/usable_record/lyric_kind`)가 u5 병합 뒤 main에서도 존재(작업 시작 전·병합 뒤 둘 다 시험 재실행 O) | 시험 재실행 |
| M6-9 | 저장 실패(`SongStore.write_hook` 실패·41번째 곡 `quota_songs`·`fake_used_bytes` 초과) → 한국어 안내, 곡 0개·부분 폴더 0, 입력한 가사는 화면에 남음 | 시험 |
| M6-10 | 화면을 나가면(`on_hide`/`_exit_tree`) 날아가는 LRCLIB 요청 결과를 버리고(`abandon`) 늦은 신호로 화면이 오류 내지 않음; `cancel_request` 호출 소스 0건 | 시험·검색 |
| M6-금지 | `song_add_screen.gd` `song_view.gd` 수정 0, 실제 `lrclib.net` 접속 0(기본 주소가 시험에서 `127.0.0.1`로 바뀌어 있음), `publish`·`flag`·`challenge` 호출 소스 0건, 가사 생성·자동 수집 코드 0 | 해시·검색 |

### M7 허브 연결 (ss/u5 병합 뒤)
| # | 조건 | 판정 |
|---|---|---|
| M7-1 | `song_view_test` 통과 수가 변경 전(u5 병합 후 수치) + 10 이상, `song_study_screen_test`·`song_flow_test`(u5) 변경 전 이상 0 failed | 실행 |
| M7-2 | 목록: `kind=="lyrics"` 곡 행의 보조 글자에 "가사만"·"외운 줄 N/M"이 있고 "오디오 없음"은 없음; 음원 곡 행은 변경 전과 같음; `[가사만 추가]` 단추(PC: 머리줄 동작, 폰: 둘째 전폭 단추) | 시험 |
| M7-3 | 곡 탭: 가사 곡 → `SongMemoScreen`(`screen_kind == "memo"`), 음원 곡 → `SongStudyScreen`(변경 전과 같음) | 시험 |
| M7-4 | `[가사만 추가]` → (첫 사용이면 동의 시트 → "동의하고 시작") → `SongLyricsAddScreen`; **PC 없음에서도 열림**(`Api.sent_count` 불변), 기존 `[+ 곡 추가]`는 PC 없음에서 변경 전처럼 안내만 | 시험 |
| M7-5 | `song_added` → 외우기 화면으로 자동 이동, 뒤로 가기(`go_back`)가 외우기 → 목록으로 한 단계씩; 안드로이드 뒤로 가기에서 시트가 먼저 | 시험 |
| M7-6 | 학습 화면 ⋯ 메뉴에 "가사 외우기"가 있고, 누르면 `memo_requested(id)` → 외우기 화면 → 닫으면 학습 화면이 아니라 목록(결정: 단순화)으로 | 시험 |
| M7-7 | 삭제 문구: 가사 곡은 "가사와 외우기 기록이 이 기기에서 지워져요…", 음원 곡은 변경 전 문구 그대로 | 시험 |
| M7-8 | 겹침 확인: `git diff <u5 병합 직전>..HEAD --stat`이 §7.3의 M7 허용 파일 4개만 | 명령 |
| M7-금지 | `main.gd` `song_add_screen.gd` `song_check_screen.gd` `song_meaning_tab.gd` 수정 0, u5 시험 삭제·약화 0 | diff |

### M8 종단
| # | 조건 | 판정 |
|---|---|---|
| M8-1 | `powershell -NoProfile -ExecutionPolicy Bypass -File godot\tests\run_memo_tests.ps1` 마지막 줄 `MEMO_E2E_RESULT PASS`, 종료 0. 러너는 가짜 LRCLIB를 빈 포트에서 띄우고(자기 PID만 종료), `APPDATA`를 작업 폴더로 돌려 사용자 폴더 불변(전후 목록·md5), 끝나면 포트 해제 확인 | 실행 |
| M8-2 | `memo_flow_test` 영어: 붙여넣기(`lyrics_en.txt`) → 추가 → 외우기 시작 → 새 줄 5개를 단계 끝까지 정답으로 진행 → 진도 "외운 줄" 숫자·`memo.json` 카드 5개·`StudyLog` `drill` +5 → 시계를 3일 뒤로 → "오늘 복습 5줄" → 복습 줄이 빈 화면에서 시작 → 정답 → 카드 `due`가 뒤로 밀림 | 시험 |
| M8-3 | 일본어: `lyrics_ja.txt` 5줄 → 단위 가림·입력 채점(정답 통과, 한 단위 오답 표시) | 시험 |
| M8-4 | LRCLIB(가짜) → 후보 선택 → 저장 → 외우기, 하단 출처 문구, 호출 수 get 1 + search ≤1 | 시험 |
| M8-5 | 폰 단독(`-- --phone`, PC 없음): 추가·외우기·입력 채점·자가 평가(말하기)·복습이 이어서 되고 전 구간 `Api.sent_count` 불변, `/stt`·`/song/*` 요청 0 | 시험 |
| M8-6 | 실패 입력: 틀린 답 2번 → 정답 공개 → 단계 내려감 → 다시 통과 → 평가 규칙대로(Hard/Again); 깨진 `memo.json` 중간에 만들기 → 격리·새 시작; 곡 삭제 → 목록에서 사라지고 폴더 0 | 시험 |
| M8-7 | 종료 후 `user://test_*` 외 파일 변화 0, 남은 프로세스·열린 포트 0 | 목록 |
| M8-금지 | 포트 8770·8775·8776 접속 0, 실제 `lrclib.net` 접속 0, 실존 곡 가사 0 | 러너 로그 |

---

## 9. 시험 방법
- **실제 노래·서버 없이**: 가사는 `godot\tests\fixtures\song\lyrics_en.txt`(6줄, 2연)·`lyrics_ja.txt`(5줄)만. 두 파일 머리의 `#` 주석 줄은 **시험이 먼저 제거**(`LrcParser.split_plain`은 `#` 줄을 거르지 않음 — 코드 확인). 필요한 변형(같은 줄 반복, 기호 줄, 401줄, 201자 줄)은 시험 안에서 이 줄들을 조합해 만든다. 실존 곡 가사·알려진 구절 금지.
- 영어 줄 단위 수: `The kettle hums while the morning climbs the wall` 9, `I count my steps to the old blue chair` 9, `Nobody calls, so the quiet stays small` 7, `A paper boat rides the puddle by the gate` 9, `I whistle one note and watch it drift` 8, `Tomorrow can wait while the tea is warm` 8.
- 순수 로직(M1~M3)은 Godot 헤드리스, 서버·마이크·화면 없음. 시계는 주입한 `now`, 난수는 없음(시드 해시), `FSRS.fuzz_override = 0.5`.
- 화면(M4~M7): 가짜 장치 — `SpeakDrill.api_hook`(`/stt`·`/song/enrich`), `Tts.fetch_hook`, `Route.phone_hook`·`Route.pc_ready_hook`·모드, `SongMeaningTab.pc_hook`, `SelfRatePanel.play_hook`, `Recorder.test_audio_source`. 폰 확인은 기존처럼 `-- --phone`, 글자는 `--font-scale=1.5`.
- 저장: `SongStore.root = "user://test_songs_<태그>"`(태그 예: `memo_store` `memo_screen` `memo_add` `memo_flow`), 설정·진행·학습 기록은 `Store.apply_test_guard`가 `user://test_guard`로 돌림. 기본 `user://songs`는 시험이 건드리면 `TEST_GUARD` 오류가 나는 기존 장치를 그대로 믿되, 전후 파일 목록 비교를 각 시험에 넣는다.
- 가짜 LRCLIB: 기존 `godot\tests\fixtures\song\fake_lrclib.py`(사용법은 `lrclib_client_test.gd`·`song_add_test.gd` 참고), M6 18797, M8 18798.
- 일부러 틀린 입력: §8 각 표의 **틀린 입력** 행과 §11. 검사기(채점·보정·격리)는 통과 입력뿐 아니라 실패 입력도 넣어 실제로 실패하는지 확인한다.

### 9.1 실기(사용자 폰·PC) 확인표
| 표 | 내용 |
|---|---|
| H1 | 사용자 곡 1~2개(영어·일본어)를 붙여넣어 한 곡을 하루 동안 외워 보기: 단계 느낌, 일본어 가림 단위 체감, 입력 편의(폰 키보드·IME), 통과선 85/75 체감 |
| H2 | 폰 단독(비행기 모드): 추가·외우기·자가 평가·복습, 원어민 읽어 주기(시스템 음성 유무) |
| H3 | PC 연결 폰: 말하기 `/stt` 인식 정확도(영어·일본어), [내가 맞게 말했어요]가 얼마나 쓰이는지 |
| H4 | LRCLIB로 실제 곡 1개(`get` 1번), 하루 뒤 복습 줄이 나오는 시각이 기대와 맞는지(첫 간격 1~4일 추측 확인) |

---

## 10. 위험 요소와 대안
| # | 위험 | 영향 | 대응·대안 |
|---|---|---|---|
| R1 | 일본어 단위(2~5자 덩어리)가 어색하거나 한 단위가 너무 커서 가림이 거칠다 | 학습 경험 | 시험은 성질(이으면 원문, 1자 없음, 결정적)만 고정. H1에서 체감 확인, 후속으로 PC `words[]`(형태소) 우선 사용 |
| R2 | 입력에서 한 단어 빠짐이 통과(9단어 줄 94점) | 외움을 과대평가 | `good:false`면 평가 Hard로 내리고 틀린 단어를 보여 줌. 엄격 채점은 후속 |
| R3 | 말하기 `/stt` 오인식으로 억울한 실패(특히 일본어 한자/가나, 영어 축약) | 좌절 | 통과선 75, 일본어는 읽기 후보, [내가 맞게 말했어요], 입력으로 답하기 대안 |
| R4 | 읽기(`reading`)가 없는 일본어 곡(폰 단독으로 만든 곡)은 히라가나 입력이 불통과 | 불편 | 안내 문구("가사 글자 그대로 입력"), PC 연결 시 해석 만들기로 읽기 생성(`SongMeaningTab`) |
| R5 | 폰 `memo.json` 저장 빈도·플래시 | 폰 수명·지연 | 줄 끝·나가기에서만 저장(§5.3), 60 KB 이하라 영향 작음 **(추측)**, 쓰기는 원자적 |
| R6 | 같은 키 병합으로 후렴을 한 번만 외움 → 곡 순서·반복 위치는 연습되지 않음 | 곡 전체 암기 한계 | 이전 줄 힌트(순서 단서), 후속 "이어 말하기·전체 시험" |
| R7 | 곡 한도 40개를 음원 곡과 공유 | 가사 곡이 한도 소진 | 가사 곡은 용량이 작아 바이트 한도는 무관. 곡 수 한도 분리는 §12.1a S4(필요 시) |
| R8 | FSRS 초기 두 번 `Good` 규칙이 의도(1~4일 첫 간격)와 다르게 나옴 | 복습 시점 어긋남 | M3-2가 구간을 시험으로 고정(실측), 어긋나면 규칙을 `Good` 한 번 + 즉시 `Hard`로 교체하는 대안을 오케스트레이터가 판단 |
| R9 | u5와 겹침(`song_view.gd` 등) 병합 충돌, 정적 함수 이름 변경 | 컴파일 오류 | §7.3 표, M7은 u5 병합 뒤, M6-8로 병합 뒤 시험 재실행 |
| R10 | `StudyLog` `drill`에 합산되어 "연습 횟수" 통계가 부풀음 | 통계 오해 | 줄 끝에서만 1번, 별도 통계는 `study_log.gd` 변경이 필요하므로 후속 |
| R11 | 폰 시스템 음성이 없으면 읽어 주기 불가 | 기능 일부 불가 | 단추 비활성 + `Route.text_for("no_voice")` 안내, 외우기 자체는 그대로 |
| R12 | 목록 스레드(`SongStore.list`+`memo_summary`)와 화면이 같은 파일을 동시에 씀 | 읽기 중 파일 변경 | u5의 규칙을 따름(하위 화면이 열려 있는 동안 목록 로드 안 함), `memo_summary`는 읽기 전용 |
| R13 | 사용자가 가사를 그대로 복사해 두는 곡이 늘면서 저작물 관련 오해 | 법적 인식 | 동의 시트(첫 1회), 개인 학습용·이 기기에만 문구(`SongView.MSG_SAVED_HERE`), 동기화·릴리스에서 제외 시험 |
| R14 | LRCLIB `get`을 길이 없이 부르면 결과가 덜 정확 **(추측: 문서에 동작 명시 없음)** | 헛걸음 | 선택 길이 입력 + `search` 보완, 사용 횟수 규칙은 그대로 |

---

## 11. 일부러 틀린 입력으로 확인할 실패 시나리오
| # | 입력 | 기대 결과 |
|---|---|---|
| F1 | `memo.json` 중간 잘림 / 배열 JSON / 널 바이트 / 3 MiB | 열 때 `memo.json.bad`로 격리, 토스트, 새 기록으로 정상 진행, `song.json` 무사 |
| F2 | `memo.json`의 `v:2` | 읽기 전용: 연습은 되고 저장 안 함, 안내 |
| F3 | 카드 필드에 문자열·NaN·음수 안정도·`state:9` | 그 카드만 버려 새 줄 취급, 다른 줄 정상, 예외 0 |
| F4 | 빈 가사·제목 없음으로 [저장] | 저장 0, 안내 |
| F5 | 401줄·201자 줄·20001자·`[Chorus]` 줄 붙여넣기 | `prepare_lyrics` 규칙대로 자르고 안내, 저장은 잘린 가사로 |
| F6 | 기호뿐인 줄(`♪♪`, `...`) | 외울 줄에서 제외, N/M에서 빠짐 |
| F7 | 같은 줄이 후렴으로 3번 | 키 하나, M에 한 번만 셈, 큐에 한 번만 나옴 |
| F8 | 입력칸 비움 → [확인] | 단추 비활성(시도로 세지 않음) |
| F9 | 정답 줄 + 군더더기 단어 100개 / 이모지 / 2000자 | 예외 0, 점수 0~100, 더한 단어 표시 |
| F10 | 일본어 줄(한자)에 히라가나만 입력 — 읽기 없음 / 읽기 있음 | 불통과 / 통과 |
| F11 | 말하기 무음·`/stt`가 `text:""` | "소리가 들리지 않았어요", 시도·틀린 횟수 불변 |
| F12 | `/stt` 오류(PC 끊김·503·`Backend` 미준비) | 오류 문구 + 자가 평가로 전환, 시도로 세지 않음 |
| F13 | 폰 단독에서 말하기 선택 | `/stt` 호출 0, `Api.sent_count` 불변, `SelfRatePanel` |
| F14 | LRCLIB 429+`Retry-After` / 500 / 연결 거부 / 깨진 JSON / 404 / 연주곡 | 각각 한국어 안내 + 붙여넣기 대체 안내, 자동 재시도 ≤1, 크래시 0 |
| F15 | LRCLIB 단추를 다시 누름(이미 get 1·search 1 사용) | 호출 0, 안내 토스트 |
| F16 | 41번째 곡 / 디스크 쓰기 실패(`write_hook`) | `quota_songs`/`disk_write` 안내, 부분 폴더 0, 입력한 가사 화면에 남음 |
| F17 | 외우는 도중 화면을 나가거나 앱을 닫음 | 새 줄 도달 단계만 저장, 카드·통계 변경 0(줄 끝 전) |
| F18 | 시계가 `last_review`보다 과거 | 예외 0, `due`는 유한한 정수 |
| F19 | 이미 끝난 줄에 `submit` 반복 | 평가 두 번 적용되지 않음(`reps` 불변) |
| F20 | 가사 고치기로 한 줄 수정 | 고친 줄만 새 줄, 나머지 카드 유지, 오래된 키는 `prune`(30일 뒤) |
| F21 | 곡 삭제 | 폴더째 사라져 `memo.json`도 0, 목록에서 제거, 복습 탭 카드는 영향 0 |
| F22 | `song.json`이 `kind:"lyrics"`인데 줄 0개 / `kind:"banana"` | 설치 거절(`bad_song`) / `"audio"`로 보정 |
| F23 | 빈 화면 단계에서 접근성·툴팁을 읽는 보조기능 | 정답 줄 글자가 어디에도 없음(M4-3) |
| F24 | 시스템 음성이 없는 폰에서 읽어 주기 | 단추 비활성 + 안내, 다른 기능 정상 |

---

## 12. 오케스트레이터가 정할 것

### 12.1 사용자에게 물을 결정 (3개, 추천 포함)
| Q | 질문 | 추천 |
|---|---|---|
| Q1 | **빈 화면 단계에서 "이전 줄"을 힌트로 보여 줄까요?** (곡 순서를 떠올리는 단서. 끄면 정말 아무것도 없는 화면에서 줄 번호만 보고 떠올림) | **기본 켬, 설정 칩으로 끌 수 있게.** "빈 화면" 요구에 가장 가깝게 하려면 끔이 기본이지만, 줄 단독 문제라 순서 단서가 없으면 후렴 앞뒤를 구분하기 어렵다 |
| Q2 | **같은 가사 줄이 여러 번 나오면(후렴) 한 줄로 묶어 한 번만 외우게 할까요?** (묶으면 진도 숫자 M에도 한 번만 셈. 안 묶으면 줄 번호별 기록이라 가사를 고치면 기록이 끊김) | **묶는다**(글자 해시 키). 외우는 양이 줄고, 가사 수정에도 기록이 유지됨. 곡 순서 전체 시험은 후속 |
| Q3 | **말하기 채점이 틀렸을 때 [내가 맞게 말했어요]로 스스로 통과시키는 것을 허용할까요? 통과선은 입력 85·말하기 75로 시작해도 될까요?** (음성 인식 오차가 크고, 정직하게 눌러야 복습 일정이 맞음) | **허용 + 85/75로 시작**, 실기 H1·H3 결과를 보고 조정 |

### 12.1b 사용자 결정 (2026-10-31)
- Q1 빈 화면 단계의 앞 줄 힌트: **기본 켬, 설정으로 끌 수 있게**.
- Q2 같은 가사 줄(후렴) 묶기: **묶기**(곡 순서 전체 시험은 후속).
- Q3 말하기 오채점 시 [내가 맞게 말했어요] 스스로 통과: **허용**. 통과선 입력 85·말하기 75로 시작, 실기 H1·H3 뒤 조정.
- 작업자: 모든 작업 worker-hard(Haiku 작업자 폐지).

### 12.1a 기본값으로 진행해도 되는 작은 결정 (반대할 때만 알려 주세요)
| # | 결정 | 기본 |
|---|---|---|
| S1 | 단계 | 보통 0·25·50·75·100%, "빠르게" 0·50·100%(설정 칩) |
| S2 | 가림 순서 | 줄 글자에서 정한 시드로 섞은 고정 순서(쉬운/어려운 단어 구분 없음). 어려운 단어 먼저·나중 가림은 후속 |
| S3 | 한 번에 하는 양 | 복습 최대 20 + 새 줄 5, [5줄 더] |
| S4 | 곡 한도 | 음원 곡과 합쳐 40곡(가사 곡만 따로 늘리는 것은 필요해질 때 `SongStore.MAX_SONGS` 변경으로) |
| S5 | 평가 | `Again/Hard/Good`만(EASY 없음), 평가는 맨 끝 단계 결과만 반영 |
| S6 | 음원 곡의 외우기 진입 | 학습 화면 ⋯ 메뉴 "가사 외우기"(목록 행에는 단추 안 둠) |
| S7 | 통계 | 줄 끝마다 기존 `drill` 이벤트 1번(별도 "외우기" 통계는 후속) |
| S8 | 복습 카드 | 기존 복습 탭과 분리(요청에 따라 섞지 않음). 줄을 기존 복습 카드로 보내는 단추는 후속 |

### 12.2 선행 확인 (착수 전)
- ss/u5 병합 시점(M7의 시작 조건). M1·M2·M6은 지금 시작 가능.
- P1(공개 검사) 작업자에게 `check_zip.py` 거절 패턴에 `memo\.json$` 포함 지시.

---

## 부록 A. 추측·미확인 목록 (착수 전에 검증)
1. FSRS 두 번 `Good`(같은 시각)의 첫 간격이 1~4일(M3-2에서 시험으로 확인, 계산상 약 2일).
2. 일본어 단위 규칙의 체감 품질(H1).
3. 폰 `memo.json` 쓰기 지연(60 KB 추측).
4. LRCLIB `/api/get`을 `duration` 없이 부를 때의 동작(문서에 없음).
5. 폰 음성 인식 핸들러(`local\local_stt.gd`)는 현재 저장소에 없음 — 생기면 폰 단독 말하기가 `/stt` 경로로 자동 전환됨(`Route.decide`).
6. `SongMeaningTab`을 `player = null`로 임베드해도 모든 경로가 안전한지(코드로 `play_line`은 확인, 나머지는 M5 시험).
7. 영어 `o.k.` 같은 특수 처리 줄의 단어 수 불일치(`aligned:false` 대체 표시로 처리, 빈도 낮음).
8. ss/u5가 `SongAddScreen`의 정적 함수 이름을 바꾸지 않는다는 가정(M6-8로 확인).
