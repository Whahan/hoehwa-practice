# 1.2 폰 ↔ PC 학습 기록 동기화 설계

- 작성: designer (설계만, 코드 수정 없음) / 대상 버전: 1.2.0
- 읽은 것(코드로 확인): `godot/scripts/core/progress.gd`, `autoload/store.gd`, `core/study_log.gd`, `core/streak_calc.gd`, `core/phoneme_stats.gd`, `core/fsrs.gd`, `core/study_clock.gd`, `core/remote_link.gd`, `core/platform.gd`, `autoload/api.gd`, `autoload/backend.gd`, `main.gd`, `views/today_view.gd`(설정 카드, 초기화 버튼), `views/review_view.gd`, `backend/lan.py`(전체), `backend/server.py`(lifespan, attach, 미들웨어), `backend/lan_stub_server.py`·`test_lan.py` 머리글, `docs/android_remote_design.md`(§1.2·§14·§15·§17), `API.md`(휴대폰 연결 절), `ROADMAP.md`, `packaging/build_dist.ps1`·`check_zip.py`·`installer/update_helper.py`(보호 경로), 실제 사용자 폴더는 **키 이름과 항목 개수만** 봤다(값은 안 읽음).
- 표기: **(추측)** = 코드·문서로 확인하지 못한 가정. 표기 없는 것은 코드에서 확인한 사실이다.
- 용어: **PC 앱** = PC 의 Godot 화면, **백엔드** = PC 의 Python FastAPI(127.0.0.1:8770, 폰용 Tailscale 리스너 :8775), **허브** = 이번에 백엔드에 새로 만드는 "기기별 기록 보관함", **복제본(replica)** = 한 기기가 허브에 올려 둔 자기 기록 문서.

---

## 1. 목표와 범위

### 1.1 목표
1. 폰에서 공부한 것이 PC 에도, PC 에서 한 것이 폰에도 반영된다(복습 카드, 로드맵 체크, 공부한 날, 날짜별 공부 시간·정답률·발음 점수, 연속 일수(합친 '공부한 날'로 계산), 미션 최고 기록, 음소 통계, 아는 단어, 일부 설정).
2. **학습 기록이 사라지지 않는다.** 첫 동기화는 양쪽을 "합친다"(덮어쓰기 없음). 어느 한쪽 결과가 줄어드는 병합은 저장 전에 검사로 막는다.
3. 폰이 PC 에 닿지 않아도(Tailscale 꺼짐, PC 꺼짐) 공부는 폰에 그대로 쌓이고, 다음 연결 때 반영된다. 별도의 "보낼 목록"(outbox)이 필요 없다(§3.3).
4. 시험이 실제 사용자 폴더를 쓰지 않는다. 동기화 전 백업이 있고 되돌릴 수 있다.

### 1.2 이번에 하지 않는 것 (§11.3 에 이유)
- 기록 **초기화(전체 삭제)를 다른 기기로 전파**하는 것. 초기화는 이 기기 연결을 끊고 이 기기만 지운다(§4.8).
- 실시간 푸시(서버가 폰을 깨워 알림), 압축 전송, 여러 PC 사이 동기화(허브는 PC 한 대에 하나).
- 인터넷 건너 동기화(Tailscale 이 아닌 경로), 계정/클라우드, 암호화 저장(허브 파일은 PC 사용자 폴더 권한에 맡김).
- `curriculum.json` 캐시, `remote.json`(연결 정보·토큰), 오디오/TTS 캐시, 읽기 모드 `user://reading/*`, 음성 설정의 기기별 항목 동기화.
- 학습 이벤트를 하나하나 기록하는 로그 방식(event sourcing)과 복습 로그 재생(FSRS replay).
- 충돌을 사람에게 고르게 하는 UI(자동 병합만 한다. 결과 요약 문구만 보여 준다).
- `PUT /sync/progress` 한 덩어리 API(§5.1 에서 이유).

---

## 2. 핵심 결정 요약

| # | 결정 | 이유 |
|---|---|---|
| D1 | **허브 = 백엔드의 "기기별 복제본 보관함"**(`backend/data/sync/`). 허브는 병합하지 않고 각 기기가 올린 자기 기록 문서를 **그대로** 보관·전달한다. 병합은 **각 기기(Godot)가 같은 순수 함수**로 한다. PC 앱도 폰과 똑같이 루프백으로 허브에 동기화한다. | 병합 코드가 GDScript 한 벌뿐이다(Python 중복 없음). 허브는 입력 원본을 지우지 않으므로 병합 버그가 나도 고쳐서 다시 합치면 복구된다. 허브가 PC 앱의 `user://` 파일을 쓰지 않아 파일 경합이 없다. 폰이 동기화하는 동안 PC 앱이 꺼져 있어도(백엔드만 떠 있어도) 된다. |
| D2 | **각 기기는 허브에 자기 기록만 쓴다(기기당 파일 1개).** 남의 파일은 읽기만 한다. | 쓰기 충돌이 구조적으로 없다. 동시 동기화 안전. |
| D3 | 합산해야 하는 값(공부 시간, 횟수, xp, 점수 합 등)은 **기기별 자기 몫(own slot)** 으로 올리고, 병합값은 **기기별 몫의 합**이다. 자기 몫 = 이전 몫 + `max(0, 지금 값 − 마지막 동기화 때 값)`. | 같은 시간이 두 번 세어지지 않는다. 같은 요청을 다시 보내도 결과가 같다(멱등). 한쪽 파일이 지워져도 허브에서 되살아난다. |
| D4 | 집합류(체크, 공부한 날 표시, 복습 카드 목록, 아는 단어)는 **LWW-element-set**: 항목별 `add` 시각 / `del` 시각, 같으면 **추가가 이긴다**. 삭제 흔적(tombstone)은 400일 보관. | 첫 동기화는 합집합. 지운 것은 지운 대로 전파된다. "의심스러우면 남긴다." |
| D5 | 복습 카드 한 장의 상태는 **(reps 큰 쪽) → (last_review 늦은 쪽) → (stability 큰 쪽) → (정규화 JSON 사전순)** 으로 한쪽을 통째로 채택. | FSRS 상태는 필드 단위로 섞으면 일관성이 깨진다. reps 먼저 보는 이유는 시계가 틀린 기기에 영향을 안 받기 때문. |
| D6 | **시계**: 모든 시각은 **허브 시각**으로 저장한다(기기는 `skew = 허브시각 − 내시각` 을 매 동기화 때 구해 더한다). 병합할 때 복제본 안의 모든 시각은 `min(t, 그 복제본이 허브에 도착한 시각 + 5초)` 로 자른다. | 미래 시각을 올린 기기가 영원히 이기지 못한다. 폰 시계가 몇 시간 틀려도 카드 due/last_review 가 맞는 시각으로 합쳐진다. |
| D7 | **순서: 받기 → 병합·적용(동기, await 없음) → 올리기.** 올리기가 실패해도 로컬은 이미 일관된 상태이고 다음 라운드가 같은 내용을 다시 올린다. | 병합 계산과 적용 사이에 사용자 조작이 끼어들 틈이 없다. 끊겨도 잃는 것이 없다. |
| D8 | 적용 전 **백업**(최대 10개 + 첫 동기화 백업 영구) → **병합 결과 검사**(줄어듦 금지 등) → **저널(pending)** 을 먼저 쓰고 파일 3개를 쓴 뒤 저널 삭제. | 파일 여러 개를 쓰는 도중 꺼져도 다음 시작에 이어서 끝낸다. |
| D9 | API 는 `GET /sync/pull`, `POST /sync/push` 두 개. 인증은 폰=Bearer 토큰(기존 `lan.py` 문), PC=루프백 + Host/Origin/Content-Type 검사(`/lan*` 와 같은 수준). | `Api`(api.gd)가 GET/POST 만 지원, `lan.py` 허용 목록이 (메서드, 경로) 정확 일치라 PUT 을 쓰려면 둘 다 고쳐야 한다. 기존 로드맵의 `GET/PUT /sync/progress` 는 이 구조에 맞춰 바꿨다. |
| D10 | **첫 연결 때 한 번 묻는다**: "PC와 학습 기록을 합칠까요? / 따로 쓸까요?"(PC 앱은 "폰과 …"). 합치기를 고르면 동기화가 켜지고, 따로 쓰기를 고르면 꺼지며 **다시 묻지 않는다**. 선택 전에는 폰은 네트워크 요청을 **0번** 보낸다. 설정에 '학습 기록 동기화' 켜기/끄기 스위치가 있어 언제든 바꾼다(PC·폰 같은 스위치). **끄면 받기·올리기를 모두 하지 않는다**(요청 0). 허브의 내 복제본은 남고, 다시 켜면 합집합으로 재합류한다(§4.8.1). | 사용자 결정(Q1). 합집합·백업이 있어 합치기는 손실이 없지만, 처음 한 번은 사용자가 고르게 한다. |
| D11 | **보호권은 동기화하지 않는다(기기별).** 연속 일수는 합쳐진 '공부한 날'(`progress.days` 집합)로 각 기기에서 `StudyLog.settle()` 이 다시 계산한다. | 사용자 결정(Q9). 보호권 병합 휴리스틱(±1 오차)을 없애 규칙을 단순하게 한다. |

---

## 3. 구조와 데이터 흐름

### 3.1 구조도

```
┌─────────── 폰 (Godot, Platform.is_phone()) ───────────┐        ┌────────────────────── PC ───────────────────────────┐
│ progress.json studylog.json prefs.json  (user://)     │        │ PC 앱(Godot)                                         │
│ sync_state.json  sync_backup/                         │        │  progress.json studylog.json prefs.json (user://)    │
│  SyncManager(타이머·생명주기) → SyncEngine            │        │  sync_state.json  sync_backup/                       │
│       │ extract/apply        │ SyncMerge(순수 함수)   │        │   SyncManager → SyncEngine ── Api ─┐                │
│       └─ Api(Bearer 토큰) ───┼────────────────────────┼─ Tailscale ─► :8775 (LanGate: 토큰·허용 목록)               │
└──────────────────────────────┘                         │   (백엔드 프로세스, 같은 FastAPI 앱)  ▲  ▼ 127.0.0.1:8770 │
                                                         │      sync_hub.py (GET /sync/pull, POST /sync/push)           │
                                                         │      backend/data/sync/hub.json, replicas/<device_id>.json   │
                                                         └──────────────────────────────────────────────────────────────┘
```

- 허브 파일은 `backend/data/sync/`. 이 경로는 이미 **업데이트 보호 경로**(`update_helper.py` `PROTECTED_PREFIXES` 의 `backend/data/`), **배포 제외**(`build_dist.ps1` robocopy `/XD data`, `check_zip.py` 금지 패턴 `^backend/(data|...)/`), **git 제외**(`.gitignore` `backend/data/`)다 → 패키징/ignore 파일 수정 불필요.
- `user://sync_state.json`, `user://sync_backup/` 은 패키지에 들어갈 일이 없다(사용자 폴더). `check_zip.py` 는 `progress.json`/`studylog.json` 을 이미 금지한다.

### 3.2 PC 앱이 켜져 있는 동안 폰이 동기화할 때(경합 처리)

1. 폰은 허브의 **폰 복제본 파일 하나**만 쓴다. PC 앱의 `user://progress.json` 등은 백엔드 프로세스가 **절대 열지 않는다**.
2. PC 앱은 자기 프로세스 안에서 허브를 읽고(루프백 GET) 자기 파일을 자기가 쓴다. 폰이 올린 내용은 PC 앱의 **다음 라운드**(최대 60초 폴링, §6.1)에 들어온다.
3. 허브는 프로세스 전체에서 하나의 `threading.Lock` 으로 읽기·쓰기를 감싸고(루프백 서버와 :8775 리스너가 같은 프로세스·다른 스레드), 복제본은 `임시파일 → os.replace` 로 바꾼다. 읽는 쪽은 옛 문서 또는 새 문서 전체만 본다(반쯤 쓴 문서는 없다).
4. PC 앱이 병합·적용하는 구간은 await 가 없는 동기 구간이라 StudyClock·화면 조작과 섞이지 않는다(GDScript 단일 스레드). 녹음 중(`Recorder.recording`)이면 적용을 5초 미룬다.
5. 같은 기기 id 로 두 프로세스가 동시에 올리면(PC 앱을 두 번 띄움) `seq` 검사(409 `stale_seq`)가 막고, 진 쪽이 `stored_seq+1` 로 한 번 다시 시도한다(§5.2). 두 번째 앱은 원래 `progress.json` 도 망가뜨리는 기존 문제라 별도 해결은 하지 않는다(§11.1 R14).

### 3.3 한 라운드(SyncEngine.sync_now)

```
0. 점검: `choice=="undecided"` 이거나 스위치가 꺼짐(`enabled==false`)이면 **네트워크 요청 없이** 즉시 `disabled` 로 끝(§4.8.1). 읽기 전용(Store.progress_read_only / StudyLog.is_read_only / prefs_read_only)이면 중단(local_read_only).
         사이드카에 pending(저널)이 있으면 먼저 그것을 적용해 끝낸다.
1. GET /sync/pull?device_id=<내 id>&rev=<마지막 rev>      (await)
     - 404 → old_pc.  hub_id 가 저장된 것과 다르면 §4.9(hub_changed).
     - unchanged:true 이고 로컬 지문(fingerprint)도 마지막과 같으면 → 끝(할 일 없음, 올리기도 안 함).
     - skew = hub_time − 지금 로컬 시각(응답 도착 시점)
────────────── 여기부터 8번까지 await 없음(동기) ──────────────
2. local  = SyncDoc.extract(Store.progress, StudyLog.snapshot(), Store.prefs, skew)
3. r = SyncMerge.sync_round({own, local, base, peers, stamp=hub_now_estimate, hub_now, today, rebase})
     - r.ok=false(검사 실패)면 로컬을 건드리지 않고 merge_check_failed 로 끝.
4. changed = canonical(r.view) != canonical(local)
5. changed 면: 백업(5분 throttle, 첫 동기화는 반드시) → 사이드카에 pending={view, own} 기록
6. changed 면: Store.apply_sync_progress / StudyLog.apply_sync / Store.apply_sync_prefs (각각 원자적 저장)
7. state.own = r.own; state.base = SyncDoc.extract(적용 후 실제 로컬); state.seq += 1; pending = null; 사이드카 저장
8. 지문 갱신
────────────────────────────────────────────────────────────
9. POST /sync/push {device_id, name, kind, seq, skew, client_time, doc: state.own}   (await)
     - 409 stale_seq → seq = stored_seq+1 로 한 번 더. 그 밖의 실패 → 로컬은 정상, push_pending=true 로 두고 다음 라운드에서 다시 올린다.
10. 성공이면 last_ok, hub_rev 갱신, peers 목록 갱신. 결과 Dictionary 를 signal finished 로 낸다.
```

**끊김 처리가 자동인 이유**: 올려야 할 것은 "로컬 − 마지막으로 합의된 값(base)" 의 차이로 매번 새로 계산한다. 폰이 며칠 오프라인이었어도 base 는 그대로이므로 연결되는 첫 라운드에 며칠 치 차이가 전부 자기 몫에 더해진다. 올리기 요청이 서버에 닿았는지 모르는 채 끊겨도, 자기 몫은 **누적값**이라 다시 올려도 두 번 세이지 않는다.

---

## 4. 데이터 모델

### 4.1 파일별 현재 구조(코드 확인)와 동기화 여부

**`user://progress.json`** (`Progress.blank()/normalize()`; 쓰기 `Store.save_progress()`)

| 필드 | 형식 | 동기화 | 병합 규칙 |
|---|---|---|---|
| `start` | `"YYYY-MM-DD"` (기본 `Plan.DEFAULT_START`=`2026-11-01`) | O | 레지스터(LWW): `{value, t}`. 기본값이면 `t=0`, 사용자가 바꾸면 그 동기화 시각. `t` 큰 쪽, 같으면 ISO 문자열이 큰 쪽 |
| `checks` | `{"en-3-w0": true, ...}` (로드맵 체크) | O | 집합(D4). 키 정규식 `^[a-z]{2}-\d{1,3}-[wmc]\d{1,3}$` |
| `days` | `{"2026-10-15": {"en": true, "ja": true}}` (공부한 날 표시; 연속 기록 계산 입력) | O | 집합, 항목 키 `"<iso>\|<lang>"`. 적용할 때 `days[iso][lang]` 만 만지고 다른 키는 보존, 빈 날은 삭제 |
| `xp` | `{"en":int,"ja":int}` | O | 자기 몫 합산(D3) |
| `stats` | `{"en":{"lessons","talks"},"ja":{...}}` | O | 자기 몫 합산 |
| `review` | 카드 배열: `id,lang,target,reading,ko,note` + FSRS(`due,stability,difficulty,state,step,last_review,reps,lapses`), 상한 `MAX_REVIEW` | O | 집합(키 `"<lang>\|<target>"`, `Store.add_review` 의 중복 기준과 같다) + 카드 상태 승자(D5). `id` 는 기기별 임의값이라 **비교에 안 쓰고**, 이 기기에 같은 키가 있으면 그 `id` 를 유지한다(복습 중 `rate_review(id)` 가 깨지지 않게). 새로 들어오는 카드의 `id` 가 다른 키와 겹치면 `Progress.new_id()` 로 바꾼다 |
| `known_words` | `{"en":[lemma...],"ja":[...]}` 상한 `MAX_KNOWN`=30000/언어 | O | 언어별 집합. 적용 순서: `add` 시각 오름차순, 같으면 사전순(상한을 넘으면 오래된 것부터 잘리고 **보고**한다) |
| `updatedAt` | unix | 적용 시 `now` | 동기화 대상 아님 |

**`user://studylog.json`** (`StudyLog`, v1; 쓰기 `flush()` 30초마다·화면 전환)

| 필드 | 형식 | 병합 규칙 |
|---|---|---|
| `v`, `saved` | 정수 | 동기화 안 함(로컬 값 유지) |
| `days.<iso>.<lang>` | `{sec, by:{view:sec}, n:{kind:count}, lesson:[ok,total], score:[count,sum]}` | **모든 숫자 잎(leaf)** 을 자기 몫 합산. 합친 뒤 `sec`·`by.*` ≤ 86400, 나머지 ≤ 1,000,000(`StudyLog` 상한)로 자른다. 400일(`KEEP_DAYS`)보다 오래된 날은 저장 때 `StudyLog` 가 알아서 자른다 |
| `phon.<lang>.<p>` | `{h:"0110…"(최대 30자, 1=틀림), heard:{소리:횟수}}` | `h`: 기기별 **자기 관찰**만 올리고(§4.5) 병합 때 복제본을 `(t, device_id)` 오름차순으로 이어 붙여 **뒤 30자**. `heard`: 자기 몫 합산 후 `PhonemeStats` 규칙(상위 8개, 음소 80개)으로 자름 |
| `freeze.<lang>` | `{tokens(0~2), frozen:[iso], awarded, last(일 번호)}` | **동기화 안 함(기기별)**. 허브에 올리지도, 적용 때 건드리지도 않는다(§4.6) |
| `missions.<id>` | `{stars(0~3), plays, last(iso), done_goals}` | `stars`·`done_goals` = max, `last` = 늦은 날, `plays` = 자기 몫 합산 |
| 모르는 최상위 키 | 보존 대상 | **보내지 않고**, 적용할 때 건드리지 않는다(로컬에 그대로 남음) |

**`user://prefs.json`**: 아래 **화이트리스트 6개만** 공유한다. 나머지는 기기별이라 허브에 올리지도 않는다(마이크 장치 이름 등 기기 정보 유출 방지).

| 키 | 기본값 | 공유 | 이유 |
|---|---|---|---|
| `daily_goal_min` | 10 | O | 목표는 하나 |
| `lesson_source` | `"tatoeba"` | O | 학습 방식 |
| `auto_fix_cards` | true | O | 학습 방식 |
| `tts_voice_en` / `tts_voice_ja` / `tts_speed` | `af_heart`/`jf_alpha`/1.0 | O | 같은 PC 백엔드의 TTS 를 쓴다 |
| `lang`, `mic_device`, `open_months`, `show_fix`, `show_reading`, `show_ko`, `auto_send`, `auto_speak`, `hide_prosody`, `reading_font`, `shadow_auto_rec` | – | **X(기기별)** | 화면 상태·기기 장치·폰/PC 사용 방식이 다르다 |

공유 설정은 키별 레지스터 `{value, t}`: 기본값과 같으면 `t=0`, 바꾸면 그 동기화 시각. 값이 기대 형식이 아니면(예: `daily_goal_min` 이 숫자가 아님, `lesson_source` 가 `ai|tatoeba` 가 아님) 그 복제본의 그 키를 무시한다.

동기화 **하지 않는** 파일: `curriculum.json`, `remote.json`, `reading/*`, `sync_state.json`, `*.bad`, `*.tmp`.

### 4.2 지역 뷰(local view, 병합 입력·출력) — 키 이름·형식 고정

`SyncDoc.extract()` 가 로컬 파일 3개를 이 하나의 Dictionary 로 만든다. `SyncMerge` 의 입력(`local`)이자 출력(`view`)이다. 카드 시각(`due`, `last_review`)은 **허브 시각**으로 바꿔 담는다(`+skew`).

```json
{
  "start": "2026-11-01",
  "checks": ["en-1-w0"],                       // 정렬된 키 배열
  "marks": ["2026-10-15|en"],                  // progress.days 의 (iso|lang)
  "xp": {"en": 120, "ja": 0},
  "stats": {"en": {"lessons": 3, "talks": 1}, "ja": {"lessons": 0, "talks": 0}},
  "cards": [{"key": "en|I went home", "id": "1a2b3c", "lang": "en", "target": "I went home", "reading": "", "ko": "", "note": "",
             "due": 1760000000, "stability": 2.3, "difficulty": 5.1, "state": 2, "step": 0, "last_review": 1759900000, "reps": 4, "lapses": 0}],
  "known": {"en": ["go"], "ja": []},
  "days": {"2026-10-17": {"en": {"sec": 600, "by": {"lesson": 300}, "n": {"lessons": 1}, "lesson": [3, 5], "score": [2, 160]}}},
  "phon": {"en": {"θ": {"h": "0110", "heard": {"s": 5}}}, "ja": {}},
  "missions": {"cafe_order": {"stars": 2, "plays": 3, "last": "2026-10-16", "done_goals": 2}},
  "prefs": {"daily_goal_min": 10, "lesson_source": "tatoeba", "auto_fix_cards": true, "tts_voice_en": "af_heart", "tts_voice_ja": "jf_alpha", "tts_speed": 1.0}
}
```

`SyncDoc.to_local(view, skew, progress, studylog, prefs)` 는 반대 방향: 현재 로컬 Dictionary 에 병합 결과를 **덮어 쓸 필드만** 반영해 `{progress, studylog, prefs_changes}` 를 돌려준다(모르는 키·`v`·`saved`·기기별 설정은 그대로). 카드 시각은 `−skew`.

### 4.3 복제본 문서(replica doc) — 허브에 올라가는 것, 스키마 v1

```json
{
  "v": 1,
  "progress": {
    "start":  {"value": "2026-11-01", "t": 0},
    "checks": {"add": {"en-1-w0": 1760000000}, "del": {}},
    "marks":  {"add": {"2026-10-15|en": 1760000000}, "del": {}},
    "xp":     {"en": 120, "ja": 0},
    "stats":  {"en": {"lessons": 3, "talks": 1}, "ja": {"lessons": 0, "talks": 0}},
    "cards":  {"add": {"en|I went home": 1760000000}, "del": {}, "data": {"en|I went home": { "id": "1a2b3c", "lang": "en", "target": "…", "reading": "", "ko": "", "note": "", "due": 0, "stability": 0.0, "difficulty": 0.0, "state": 1, "step": 0, "last_review": 0, "reps": 0, "lapses": 0 }}},
    "known":  {"en": {"add": {"go": 1760000000}, "del": {}}, "ja": {"add": {}, "del": {}}}
  },
  "studylog": {
    "days":     {"2026-10-17": {"en": {"sec": 600, "by": {}, "n": {}, "lesson": [0, 0], "score": [0, 0]}}},
    "phon":     {"en": {"θ": {"h": "0110", "t": 1760000000, "heard": {"s": 5}}}, "ja": {}},
    "missions": {"cafe_order": {"stars": 2, "done_goals": 2, "last": "2026-10-16", "plays": 3}}
  },
  "prefs": {"daily_goal_min": {"value": 10, "t": 0}, "lesson_source": {"value": "tatoeba", "t": 0}, "auto_fix_cards": {"value": true, "t": 0},
            "tts_voice_en": {"value": "af_heart", "t": 0}, "tts_voice_ja": {"value": "jf_alpha", "t": 0}, "tts_speed": {"value": 1.0, "t": 0}}
}
```

- `add[key] = t`: 이 기기가 그 항목을 "있다"고 말하는 시각. **복제본은 로컬에 있는 모든 항목을 `add` 에 가진다**(완전한 스냅샷). 다른 기기에서 받은 항목은 그 `add` 시각을 그대로 베껴 온다(채택, adopt) — 허브에서 어떤 복제본이 사라져도 이 기기의 항목이 병합에서 빠지지 않게 하려는 것이다. `del[key] = t`: 이 기기가 지운 시각(삭제 흔적, 400일 뒤 자기 것은 정리).
- 카드 `data` 는 지금 살아 있는 카드의 현재 상태(허브 시각).
- `days` 는 **자기 몫**(이 기기가 직접 공부한 양)이다. 로컬 파일의 `days` 는 합쳐진 값이다.
- 숫자 잎은 정수. `n`/`by` 의 키는 `StudyLog` 규칙(길이 ≤ 24, 최대 32개)을 따른다.

### 4.4 병합 알고리즘(순수 함수 `SyncMerge.sync_round`)

입력 `args`:

| 키 | 형식 | 설명 |
|---|---|---|
| `own` | replica doc 또는 `{}` | 이 기기의 지난번 복제본(사이드카) |
| `local` | 지역 뷰 | 지금 로컬(`extract`) |
| `base` | 지역 뷰에서 `cards.data`·`prefs` 를 뺀 것(카드는 키 배열) 또는 `{}` | 마지막 적용 직후 로컬. `{}` = 처음 동기화 |
| `peers` | `[{device_id, saved_hub, doc}]` | 허브에서 받은 **남의** 복제본 |
| `stamp` | int | 이 라운드의 허브 시각 추정값(새 이벤트의 `t`) |
| `hub_now` | int | 허브 응답의 시각 |
| `today` | int | 일 번호(`Plan.days_from_civil`), 삭제 흔적 보관 기간 계산 |
| `rebase` | `{"sets_at": int}` 또는 null | §4.8 되돌리기 직후 1회 |

반환: `{ok: bool, own: replica doc, view: 지역 뷰, report: {...}, problems: [String]}`. 입력은 바꾸지 않는다. 시계·파일·네트워크·난수에 접근하지 않는다(같은 입력 → 같은 출력).

**단계**

1. **정리**: `peers` 에서 dict 가 아니거나 `doc.v` 가 정수가 아닌 것 → `report.peers_skipped[{device_id, reason:"invalid"}]`. `doc.v > SCHEMA(1)` → `reason:"newer"`(UI 가 "다른 기기 앱이 더 새 버전이에요" 표시). 섹션이 빠지거나 타입이 틀린 부분은 그 부분만 빈 값으로 취급(예외 없음). 모든 시각 `t` 를 `min(t, saved_hub + TIME_SLACK(5))` 로 자르고 음수는 0 으로 → `report.clamped_times` 에 센다.
2. **내 새 이벤트(`update_own`)**: `own` 이 비었거나 깨졌으면 `{}` 로 시작.
   - 카운터 잎(xp, stats, days 의 모든 숫자, missions.plays): `own' = own + max(0, local − base)` (base 없으면 0). 음수·NaN·비숫자는 0.
   - 집합(checks, marks, cards, known): `local ∖ base` 의 키 → `add[k] = stamp`(이미 있으면 덮어씀). `base ∖ local` 의 키 → `del[k] = stamp`. `rebase` 가 있으면 base 집합을 비어 있다고 보고 `stamp` 대신 `rebase.sets_at` 을 쓴다(삭제 이벤트는 만들지 않는다).
   - `start`·prefs 레지스터: base 가 `{}` 이면 `value == 기본값` 일 때 `t=0`, 아니면 `stamp`. base 가 있으면 `local != base` 일 때만 `{local, stamp}`, 같으면 이전 `own` 값을 유지(없으면 `{local, 0}`).
   - phon: `new = new_outcomes(base.h, local.h)`; `own.h' = (own.h + new)` 뒤 30자; `new != ""` 이면 `t = stamp`; `heard` 는 카운터 잎 규칙.
   - missions: `stars/done_goals = max(own, local)`, `last = max`.
3. **병합(`merge`)** — 대상 복제본 = `own'` + 유효한 `peers`:
   - 카운터: 복제본별 몫의 **잎 단위 합**. 그 뒤 §4.1 의 상한으로 자름.
   - 집합: `add_max[k] = max add`, `del_max[k] = max del`; **있음 ⇔ `add_max[k] ≥ del_max[k]`**(del 이 없으면 add 만 있으면 있음). 결과 키는 `(add_max 오름차순, 키)` 순.
   - 카드: 있음으로 판정된 키마다 `data` 를 가진 복제본들 중 D5 순서의 승자. 로컬에 같은 키가 있으면 `id` 는 로컬 것 유지.
   - `start`/prefs: 키별 `t` 최대(자른 뒤), 같으면 `canonical(value)` 가 큰 쪽, 모두 `t=0` 이면 기본값.
   - 미션: `stars`/`done_goals` max, `last` 늦은 날, `plays` 합.
   - phon: §4.5. (보호권/freeze 는 병합 대상이 아니다, §4.6)
4. **채택(adopt)**: `own''` = `own'` 에서 집합의 `add` 를 병합 결과의 `add_max` 로 올리고(있는 항목 전부), 카드 `data` 를 병합 승자로, `start`·prefs 를 병합 레지스터로, 미션 `stars/done_goals/last` 를 병합값으로 바꾼다. 카운터 몫과 phon 은 **자기 것 그대로**. 자기 `del` 중 400일 지난 것(`stamp − t > 400일`)은 버린다.
5. **검사(`check`)**: §7.2 의 불변식이 하나라도 깨지면 `ok=false`, `problems` 에 사유(키 이름만, 값 없음), `own`·`view` 는 입력 그대로(`local`).
6. `view` 를 정렬·정규화해 돌려준다.

**성질(시험 대상)**: ① 멱등: 같은 입력으로 두 번 → 같은 `own`·`view`. ② 교환: `peers` 순서를 바꿔도 같은 `view`. ③ 단조: 카운터는 `view ≥ local`(상한 제외), 집합은 `local` 의 키가 남아 있거나 더 늦은 `del` 이 있다. ④ 수렴: 두 기기가 서로의 복제본으로 한 번씩 더 돌리면 `view` 가 같다.

### 4.5 음소 통계 `new_outcomes`

`PhonemeStats` 의 `h` 는 최근 30번을 담는 링이다. 자기 관찰만 뽑으려고 `base.h` 와 `local.h` 를 비교한다.

`new_outcomes(base_h, local_h)`: `d = 0..len(base_h)` 중 **가장 작은** d 로 `local_h.begins_with(base_h.substr(d))` 가 되는 것을 찾아 `local_h.substr(len(base_h) - d)` 를 돌려준다(못 찾으면 `local_h` 전체; `base_h` 가 빈 문자열이면 `local_h` 전체). 가장 작은 d 를 고르므로 모호할 때 **적게** 센다(두 번 세지 않는 쪽).

| base_h | local_h | 결과 |
|---|---|---|
| `""` | `"0101"` | `"0101"` |
| `"0101"` | `"0101"` | `""` |
| `"0101"` | `"010111"` | `"11"` |
| 30자 `"0"*30` | `"0"*29+"1"` | `"1"` (링이 밀림: d=1) |
| `"0101"` | `"1111"` | `"1111"` (관계 없음 → 전부 새것) |

### 4.6 연속 기록·보호권 (단순안: 보호권은 기기별)

- **보호권(`freeze.<lang>`: tokens, frozen, awarded, last)은 동기화하지 않는다.** 복제본·지역 뷰에 없고, `SyncDoc.to_local` / `StudyLog.apply_sync` 는 `freeze` 를 읽지도 쓰지도 않는다. 각 기기는 자기 보호권을 계속 따로 쓰고 받는다.
- **연속 일수는 합쳐진 '공부한 날'로 계산한다.** 입력은 `progress.days` 표시(집합, 두 기기 합집합)이고 `StudyLog.settle()` 이 로컬에서 평소처럼 돌린다. 그래서 폰에서 공부한 날도 PC 의 연속 일수에 들어간다.
- 결과: 한 기기에서 보호권으로 이은 날은 그 기기에서만 "보호된 날"이다. 다른 기기가 그 날 공부했다면(표시가 합쳐져 들어오면) 보호권을 쓸 필요가 없어져 연속이 이어진다. 두 기기가 같은 빠진 날에 각각 보호권을 쓰면 두 개가 소모될 수 있다(드문 경우, §11.1 R17).
- 시험: 합쳐진 표시로 연속 일수가 늘어나는 것(U18), 동기화 전후 로컬 `freeze` 가 바이트 단위로 같은 것(U17).

### 4.7 시계가 틀린 기기

1. **기기 시각을 그대로 믿지 않는다.** 응답의 `hub_time` 으로 `skew = hub_time − 로컬 지금(응답 도착 시각)` 을 라운드마다 구해 `extract`(카드 시각 +skew), 이벤트 `stamp`(= 라운드 시작의 로컬 시각 + skew), `to_local`(−skew)에 쓴다. 허브 응답 지연은 오차로 두되 `TIME_SLACK=5초`로 흡수.
2. `|skew| > 120초` 이면 결과에 `clock_off_sec = skew` 를 담고 설정 화면에 "이 기기의 시계가 PC와 N분 차이 나요. 시계를 자동으로 맞춰 주세요." 를 보인다(동기화는 계속한다).
3. 병합은 복제본 안의 모든 시각을 `min(t, saved_hub + 5)` 로 자른다(D6). 허브가 `saved_hub` 를 붙이므로 기기가 거짓말할 수 없다.
4. 카드 승자는 **reps 먼저** 비교해 시각 오차의 영향을 줄인다(D5).
5. 한계: 날짜 키(`YYYY-MM-DD`)는 각 기기의 로컬 날짜라 폰 시계/시간대가 몇 시간 어긋나면 날짜별 기록이 하루 옮겨질 수 있다(경고만, §11.1 R4).

### 4.8 삭제·초기화·되돌리기

- **개별 삭제**(체크 해제, 오늘 표시 해제, 카드 "목록에서 빼기", 아는 단어 해제): 집합의 `del` 이벤트로 전파된다. 나중에 같은 항목을 다시 추가하면 새 `add` 시각이 `del` 보다 커서 되살아난다.
- **"모든 기록 지우기"(설정)**: 전파하지 않는다. 동기화가 켜져 있으면 확인 문구가 바뀐다 — "동기화가 켜져 있어요. 지우면 이 기기의 동기화 연결이 끊기고, PC 보관함에 올라간 기록은 그대로 남아요. (PC 보관함까지 지우려면 PC의 backend\data\sync 폴더를 지우세요.)" 확인하면 `SyncManager.unlink_for_reset()`(백업 `unlink` → `enabled=false` → 사이드카의 `own`/`base`/`hub_id` 비움)을 먼저 하고 평소대로 지운다. 다시 켜면 새 기기 id 로 가입해 보관함 기록이 돌아온다(복원처럼 보인다).
- **동기화에서 되돌리기(`restore_backup`)**: 백업 폴더의 `progress/studylog/prefs` 를 되돌리기 직전 상태를 먼저 백업(`restore`)한 뒤 복사하고, `enabled=false` 로 끄며, 사이드카에 `rebase={"sets_at": 백업 시각(허브 시각 추정)}` 를 남기고 `own`은 **그대로 둔다**(사이드카는 복원하지 않는다: 과거 몫으로 허브의 몫을 되돌리면 상대 기기의 "줄어듦 검사"가 깨지기 때문). 다시 켜면 첫 라운드에서 집합은 처음 동기화처럼 `sets_at` 시각으로 추가되고(그 뒤의 남의 삭제가 이긴다), 카운터는 `max(0, local−base)=0` 이라 중복 없이, 허브의 최신 합이 다시 들어온다. 안내 문구: "되돌렸어요. 자동 동기화를 껐어요. 다시 켜면 PC와 다시 합쳐져요."

### 4.8.1 첫 연결 선택, 켜기/끄기 스위치, 재합류 (사용자 결정 Q1)

상태 두 개: `choice` ∈ {`undecided`, `merge`, `separate`}, `enabled`(설정의 '학습 기록 동기화' 스위치). 동기화는 `choice != "undecided"` 이고 `enabled == true` 일 때만 한다.

| 상황 | 동작 |
|---|---|
| **폰: 첫 연결**(`Backend.status` 가 처음 `READY`, 사이드카 없음) | 대화상자 "PC와 학습 기록을 합칠까요?"(§6.3). 선택 전에는 `/sync/*` 요청을 **0번** 보낸다. |
| **PC 앱: 첫 연결** | 사이드카가 없고 `choice=="undecided"` 인 동안에만, 60초마다 **읽기 전용 확인용 `GET /sync/pull`(probe)** 을 보낸다(적용·올리기 없음, 사이드카 안 만듦). 응답에 **다른 기기 복제본이 하나라도** 있으면 대화상자 "폰과 학습 기록을 합칠까요?"를 띄운다. 폰이 없는 PC 는 아무것도 묻지 않는다. 선택하면 probe 는 멈춘다. |
| **합치기** 선택 | `choice="merge"`, `enabled=true`, 기기 id 생성, 첫 동기화(백업 `first` 후 합집합 적용 + 토스트 "PC와 폰의 학습 기록을 합쳤어요…") |
| **따로 쓰기** 선택 | `choice="separate"`, `enabled=false`. **다시 묻지 않는다.** 요청 0. 허브에는 이 기기의 복제본이 생기지 않는다. 나중에 설정 스위치를 켜면 평범한 첫 동기화(합집합)가 된다. |
| **스위치 끔**(언제든) | `enabled=false`, `disabled_at=지금(허브 시각 추정)`. 이후 받기·올리기·폴링·probe **전부 0 요청**(수동 '지금 동기화' 버튼은 비활성). 허브에 있는 내 복제본은 지우지 않는다. 로컬 기록은 평소처럼 쌓인다. |
| **스위치 다시 켬**(합치기를 이미 고른 기기) | **합집합으로 재합류**: 사이드카의 `rebase={"sets_at": disabled_at}` 를 설정하고 첫 라운드를 돌린다. 카운터는 `max(0, 로컬−base)` 라 꺼져 있던 동안 공부한 양이 정확히 한 번 자기 몫에 더해진다. 집합(체크·카드·단어·공부한 날 표시)은 `sets_at` 시각의 추가로 취급하므로 꺼진 동안 이 기기에서 지운 항목은 **삭제로 전파되지 않고** 허브의 항목이 다시 들어온다(합집합). 꺼진 동안 다른 기기가 지운 것(더 늦은 삭제)은 그대로 이긴다. 재합류 첫 라운드 전에 백업(`auto`)을 만든다. |
| **스위치 켬**(따로 쓰기를 고른 기기) | 사이드카에 `own`/`base` 가 없으므로 첫 가입과 같다(합집합, 백업 `first`). |

원칙: 어느 경우에도 로컬 기록을 지우지 않는다. 재합류 때 새 기기 id 를 만들지 않는다(같은 id 를 계속 써야 이중 계산이 안 생긴다). '따로 쓰기' 이후에도 사용자가 명시적으로 켜기 전에는 요청 0.

### 4.9 스키마 버전·허브 신원

- 복제본 `v`=1, 사이드카 `v`=1, 허브 `hub.json` `v`=1. 더 큰 `v` 를 만난 읽는 쪽은 **그 복제본을 병합에서 빼고** 알린다(자기 복제본은 계속 올린다). 허브는 `doc.v != 1` 을 `400 bad_doc` 으로 거절한다(새 앱이 옛 PC 에 올리면 "PC 앱을 업데이트해 주세요").
- 로컬 `studylog.json` 의 `v`>1 이어도 동기화는 읽기·덮어쓰기 필드만 만진다(모르는 키 보존 규칙은 `StudyLog` 가 이미 지킨다).
- **허브 신원(`hub_id`)**: 허브 폴더가 처음 만들어질 때 난수 16자리(hex)로 생성. 클라이언트가 저장한 `hub_id` 와 다르면: 허브에 복제본이 하나도 없으면(허브 폴더가 지워진 경우) 새 `hub_id` 를 채택하고 자기 몫을 다시 올려 복구한다. 허브에 다른 복제본이 있으면(다른 PC 에 페어링했거나 PC 를 새로 깔았고 폰이 새 PC 에 붙음) **동기화를 멈추고** `hub_changed` 안내: "다른 PC에 연결돼 있어요. 설정 → 기록 동기화 → '이 PC와 새로 합치기'를 눌러 주세요." 버튼을 누르면 백업(`first`) 후 새 기기 id, `own={}`, `base={}` 로 가입한다(옛 PC 에서 이미 합쳐진 기록이 이 폰의 몫으로 다시 세어질 수 있음을 문구에 적는다, §11.1 R6).

### 4.10 사이드카 `user://sync_state.json` (기기별, 동기화 안 함)

```json
{
  "v": 1,
  "device_id": "a3f91c07d2e84b56",
  "enabled": true,
  "choice": "merge",
  "disabled_at": 0,
  "hub_id": "9c1e5a7b3d204f68",
  "seq": 17,
  "hub_rev": 42,
  "skew": 0,
  "own": { "…replica doc…": 1 },
  "base": { "…지역 뷰에서 cards.data/prefs 를 뺀 것…": 1 },
  "pushed_hash": "<sha256 hex of canonical(own) 마지막으로 허브가 받은 것>",
  "push_pending": false,
  "last_ok": 1760000000,
  "last_error": {"code": "unreachable", "at": 1760000000},
  "peers": [{"device_id": "…", "name": "Pixel 8", "kind": "phone", "saved_hub": 1760000000}],
  "rebase": null,
  "pending": null,
  "first_done": true
}
```
- `choice`: `"undecided"`(처음, 아직 안 물음) | `"merge"`(합치기) | `"separate"`(따로 쓰기, 다시 묻지 않음). `enabled` 는 설정 스위치. `disabled_at`: 스위치를 끈 시각(허브 시각 추정, §4.8.1 재합류에 쓴다). 사이드카는 첫 선택을 하는 순간 만들어진다.
- `device_id`: `Crypto.new().generate_random_bytes(8).hex_encode()`(16자 hex), 처음 켤 때 만든다. 토큰(`remote.json`)과 **따로**라 다시 페어링해도 같은 id 가 유지된다(이중 계산 방지).
- `pending` = `{"view": …, "own": …, "seq": n}` — 저널(§7.3).
- 저장은 `Progress.write_text_atomic` 로, 읽기는 `Progress.read_json_file`(깨졌으면 `.bad` 격리) 규칙을 따른다. 쓰기 전에 이전 파일을 `sync_state.json.prev` 로 한 세대 남긴다.
- **사이드카가 없거나 깨졌는데 로컬 기록은 있는 경우**: 새 기기로 가입(= 몫을 로컬 전체로 시작)하면 이미 합쳐진 값이 이중 계산될 수 있다. 그래서 `.bad`/`.prev` 가 있으면 자동 가입하지 않고 `state_lost` 로 멈춘 뒤 "동기화 상태 파일이 손상됐어요. '이전 상태로 되돌리기'로 복원하거나 '새로 합치기'를 눌러 주세요(기록이 겹쳐 셀 수 있어요)" 를 보인다. 단 `.bad`/`.prev` 가 아무것도 없으면(처음 켜는 경우) 평범한 첫 가입이다.

---

## 5. API 계약

### 5.1 개요와 결정 이유

| 경로 | 메서드 | 인증 | 용도 |
|---|---|---|---|
| `/sync/pull` | GET | 폰: Bearer / PC: 루프백 + Host·Origin 검사 | 남의 복제본 받기 |
| `/sync/push` | POST | 같음 | 내 복제본 올리기 |

- 기존 로드맵의 `GET/PUT /sync/progress`(한 문서를 통째로 덮어쓰기)는 **쓰지 않는다**: 덮어쓰기는 곧 손실이고, `Api` 는 PUT 을 못 하며, `lan.py` 의 `ALLOW` 가 (메서드, 경로) 정확 일치다.
- `lan.py` 의 `ALLOW` 에 `("GET","/sync/pull")`, `("POST","/sync/push")` 두 줄을 추가한다(23 → 25개). 그러면 `test_lan.py` 의 `len(lan.ALLOW) == 23` 단언을 25 로 고쳐야 한다.
- `Api.IDEMPOTENT_POST` 에 `"/sync/push"` 를 넣어 연결이 끊겼을 때 한 번 자동 재시도하게 한다(같은 `seq`·같은 본문은 멱등이다).
- 쿼리 문자열은 `LanGate` 가 보지 않는다(`scope["path"]` 만 비교) → `GET /sync/pull?device_id=…` 가 허용 목록을 통과한다.

### 5.2 `GET /sync/pull?device_id=<16 hex>[&rev=<int>]`

응답 200 (복제본이 바뀌었거나 `rev` 를 안 보냈을 때):

```json
{
  "v": 1,
  "hub_id": "9c1e5a7b3d204f68",
  "hub_time": 1760000123,
  "rev": 43,
  "self": {"seq": 17},
  "replicas": [
    {"device_id": "b2c4…16hex", "name": "Pixel 8", "kind": "phone", "seq": 9, "saved_hub": 1760000100, "doc": { "…replica doc…": 1 }}
  ],
  "warnings": [{"device_id": "d9…", "code": "replica_unreadable"}]
}
```
- `replicas` 는 **요청한 `device_id` 를 뺀** 나머지 전부(최대 15개). `self.seq` 는 허브가 가진 내 복제본의 `seq`(없으면 0).
- `rev` 가 허브의 현재 `rev` 와 같으면 `{"v":1,"unchanged":true,"hub_id":…,"hub_time":…,"rev":43,"self":{"seq":17}}` 만 돌려준다(폴링용, 수백 바이트).
- 복제본 파일이 깨졌으면 `.prev` 를 대신 읽고, 둘 다 못 쓰면 그 항목을 빼고 `warnings` 에 넣는다(요청 자체는 200). 깨진 파일은 `*.bad` 로 옮긴다.

### 5.3 `POST /sync/push`

요청(`Content-Type: application/json`, 본문 ≤ **3 MiB**):

```json
{"v": 1, "device_id": "a3f91c07d2e84b56", "name": "내 폰", "kind": "phone", "seq": 18, "client_time": 1760000120, "skew": 0, "doc": { "…replica doc…": 1 }}
```
- `device_id`: `^[0-9a-f]{16}$`. `name`: 1~40자(제어문자 제거). `kind`: `"pc"|"phone"`. `seq`: 정수 ≥ 1. `skew`: 정수 |skew| ≤ 604800. `client_time`: 정수(정보용, 신뢰 안 함).
- `doc`: §4.3 스키마. 허브는 **구조·타입·크기만** 검증한다(의미는 검증 안 함):
  - 최상위 키 `v, progress, studylog, prefs` 만; `v == 1`.
  - 시각 `t` 는 0 이상 정수 ≤ 4102444800. 숫자 잎은 0 이상 정수 ≤ 2^53, `stability/difficulty` 는 유한 실수.
  - 항목 수: cards.add/del/data ≤ 3500, known 언어당 add+del ≤ 70000, checks ≤ 5000, marks ≤ 5000, days ≤ 800일, missions ≤ 200, phon 언어당 ≤ 80, 중첩 깊이 ≤ 8. 문자열 ≤ 400자(카드 `target/reading/ko/note` ≤ 300자).
  - 키 형식: `cards` 키 `^(en|ja)\|.{1,300}$`, `marks` 키 `^\d{4}-\d{2}-\d{2}\|(en|ja)$`, `checks` 키 `^[a-z]{2}-\d{1,3}-[wmc]\d{1,3}$`, 날짜 키 `^\d{4}-\d{2}-\d{2}$`.
- 처리: 락 안에서 ① 저장된 `seq` 와 비교 — `seq < stored` → **409 `stale_seq`**(`stored_seq` 포함); `seq == stored` 이고 정규화 JSON 해시가 같으면 **200 `dup:true`**(저장 안 함); `seq == stored` 인데 내용이 다르면 **409 `seq_reuse`** ② 새 기기 id 이고 이미 복제본이 16개면 **409 `too_many_devices`** ③ 기존 파일을 `<id>.json.prev` 로 한 세대 남기고 `임시파일 → os.replace` 로 저장 ④ `hub.json.rev += 1`(원자적 저장). 허브는 저장 시각 `saved_hub` 를 **허브 시계로** 붙인다.
- 응답 200:
```json
{"ok": true, "dup": false, "rev": 44, "hub_time": 1760000124, "stored_seq": 18, "hub_id": "9c1e5a7b3d204f68"}
```

### 5.4 오류 코드

본문은 항상 `{"error": "<한국어>", "code": "<코드>"}`(+ 필요 시 `stored_seq`, `detail`). `detail` 은 `"doc.progress.xp.en"` 처럼 **어느 경로가 틀렸는지**만 담고 값은 담지 않는다.

| HTTP | code | 언제 | 문구(error) |
|---|---|---|---|
| 400 | `bad_request` | JSON 아님/객체 아님/필수 필드 없음/쿼리 형식 틀림 | 요청 형식이 올바르지 않아요. |
| 400 | `bad_device_id` | `device_id` 형식 위반 | 기기 번호 형식이 올바르지 않아요. |
| 400 | `bad_doc` | 스키마·크기·버전 위반 | 보낸 기록의 형식이 올바르지 않아요. |
| 401 | `token_missing` / `token_invalid` | 폰: 토큰 없음/잘못됨(`LanGate`, 기존) | 기존 문구 |
| 403 | `bad_origin` | 루프백에서 Host/Origin/Content-Type 검사 실패 | 허용되지 않은 요청이에요. 이 PC의 앱에서만 쓸 수 있어요. |
| 403 | `lan_forbidden` | 허용 목록에 없는 경로/메서드(기존) | 기존 문구 |
| 408/413/429 | `request_timeout` / `too_large` / `rate_limited` | `LanGate`(폰, 기존) 또는 허브(루프백 413) | 기존 문구 / 보낸 기록이 너무 커요. |
| 409 | `stale_seq` | `seq` 가 저장된 것보다 작음 | 더 오래된 기록이라 저장하지 않았어요. |
| 409 | `seq_reuse` | 같은 `seq` 로 다른 내용 | 같은 번호로 다른 기록을 보냈어요. |
| 409 | `too_many_devices` | 복제본 16개 초과 | 동기화할 수 있는 기기가 가득 찼어요. |
| 500 | `store_failed` | 디스크 쓰기 실패(아무것도 바꾸지 않음) | PC에 기록을 저장하지 못했어요. |
| 503 | `sync_off` | 허브 폴더를 쓸 수 없음 / 시험 서버에 `--sync-dir` 없음 | 이 PC에서는 기록 동기화를 쓸 수 없어요. |
| 404 | (경로 없음) | 옛 PC(1.1.x) | 클라이언트가 `old_pc` 로 해석 |

### 5.5 인증·Host/Origin 검사와의 관계

- **폰(:8775)**: `LanGate` 가 먼저 토큰을 확인하고 허용 목록(+2줄)과 본문 한도(16 MiB)를 적용한다. 허브는 `request.scope["hoehwa_lan"]` 이 참이고 `hoehwa_device` 가 있을 때만 통과시키며, 없으면 401 로 거절한다(게이트가 우회된 경우의 이중 방어). 허브는 `via=<lan device id>` 를 복제본 메타에 기록만 한다(기기 id 와 묶지 않음: 재페어링 때 같은 동기화 id 를 계속 써야 하므로).
- **PC 앱(127.0.0.1:8770, 토큰 없음)**: `/lan*` 관리 엔드포인트와 같은 검사를 한다 — 접속 주소가 루프백, `Host` ∈ `127.0.0.1|localhost|[::1]`(+포트), `Origin` 헤더가 있으면 `http://<Host>` 와 같을 것, POST 는 `Content-Type: application/json`. 위반은 403 `bad_origin`. **이유**: 허브는 학습 기록을 읽고 쓰는 API 이고 루프백 서버는 인증이 없어 웹 페이지(CSRF, DNS 리바인딩)가 건드릴 수 있다. Godot `HTTPRequest` 는 Origin 을 안 보내고 `Api` 가 `Content-Type: application/json` 을 항상 붙이므로 정상 사용에는 영향이 없다.
- 구현 위치: `lan.py` 는 건드리지 않고(`ALLOW` 두 줄만 예외) `sync_hub.py` 안에서 `lan.HOST_RE`, `lan._is_loopback`, `lan._err` 를 가져다 쓴다.
- 허브는 토큰·`Authorization` 헤더·기록 값(단어, 문장)을 **로그에 남기지 않는다**(기기 id, 크기, seq, 결과 코드만).

### 5.6 허브 저장소

```
backend/data/sync/
  hub.json                 {"v":1,"hub_id":"…16hex","rev":43,"created":"2026-…"}
  replicas/<device_id>.json     {"v":1,"device_id","name","kind","seq","saved_hub","via","doc":{…}}
  replicas/<device_id>.json.prev   (직전 세대 1개)
  replicas/*.bad                (깨진 파일 격리)
```
- 기본 경로 `BASE/data/sync`. 시험 서버(`--port` 가 있는 실행)는 **`--sync-dir` 이 없으면 허브를 끈다**(전부 503 `sync_off`) → 시험이 실제 허브를 쓸 수 없다.
- 폴더 전체 ≤ 64 MiB. 시작 시 `*.tmp` 찌꺼기를 지운다.

---

## 6. 동기화 시점·재시도·UI

### 6.1 언제 동기화하나(`SyncManager`, `main.gd` 가 `add_child`; 레이아웃 시험이 읽는 `main.tscn` 자식 장면에는 붙이지 않는다 — `StudyClock` 과 같은 방식)

| 계기 | 동작 | 제한 |
|---|---|---|
| 앱 시작 | `Backend.status` 가 처음 `READY` 가 되고 3초 뒤 1회 | |
| 연결 회복 | `FAILED`/`CHECKING` → `READY` 로 바뀌면 1초 뒤 1회, 백오프 초기화 | |
| 변경 감지 | 20초마다 로컬 지문(`extract` 결과 `sha256_text(canonical)`)이 마지막 동기화 때와 다르면 예약 | 마지막 변경 후 20초 묵힘(debounce), 자동 동기화 사이 최소 30초 |
| 폴링(받기) | PC 60초, 폰 90초(앞에 보일 때만): `GET /sync/pull?rev=` 로 `unchanged` 면 끝 | 폰이 백그라운드(`NOTIFICATION_APPLICATION_PAUSED`)면 멈춤 |
| 폰이 백그라운드로 감 | 지문이 다를 때만 즉시 1회(HTTP 타임아웃 5초). 안 끝나면 다음 실행에 반영 | |
| 폰이 앞으로 옴 | `NOTIFICATION_APPLICATION_RESUMED` 1초 뒤 1회 | |
| 지금 동기화 버튼 | 즉시, 최소 간격 무시 | 진행 중이면 무시 |
| PC 창 닫기 | **하지 않음**(종료를 지연시키지 않는다. 다음 시작 때 반영) | |

**전제**: 위 모든 계기는 `choice != "undecided"` 이고 `enabled == true` 일 때만 동작한다. 그렇지 않으면 타이머·신호·폴링·백그라운드/복귀 훅 어디서도 `/sync/*` 요청을 만들지 않는다(요청 0). 예외는 PC 앱의 `undecided` 상태 probe 하나(§4.8.1)뿐이다.

한 번에 하나만 실행(`_busy`). 실행 중 새 요청은 "한 번 더" 플래그 하나로 합친다.

### 6.2 실패와 재시도

- 자동 시도 실패 시 다음 자동 시도까지 `min(300, 30 × 2^(연속실패−1))`초(30, 60, 120, 240, 300…). 성공하거나 `READY` 복귀 때 0 으로.
- HTTP 타임아웃: pull 20초(폰 45초), push 30초(폰 60초). 연결 끊김은 `Api` 가 `/sync/push`(멱등)에 한해 1회 자동 재시도.
- 폰이 PC 에 닿지 않을 때: 조용히 백오프(토스트 없음). 설정 화면의 상태 줄에만 표시.
- 401 `token_*` 는 기존 `Backend._on_auth_failed` 흐름(연결 필요)을 따르고 동기화는 멈춘다.
- 서버 오류 `store_failed`(500) 는 다음 라운드에서 같은 내용을 다시 올린다. `stale_seq` 는 §3.3 의 자동 해결. `bad_doc` 은 재시도하지 않고 오류 상태로 둔다(앱 버전 불일치 가능성).

### 6.3 UI (설정 카드, 한국어; 새 파일 `scripts/sync/sync_panel.gd`)

설정 카드(`views/today_view.gd` `_build_settings`)의 "휴대폰 연결" 패널 근처에 `SyncPanel` 을 한 줄로 붙인다(`card.body.add_child(SyncPanel.new())`). 폰·PC 둘 다 보인다.

| 요소 | 문구 |
|---|---|
| 제목 | 학습 기록 동기화 |
| 첫 연결 대화상자(폰) | 제목 `PC와 학습 기록을 합칠까요?` · 본문 `이 폰과 PC에 따로 쌓인 학습 기록을 하나로 합쳐요. 어느 쪽 기록도 지워지지 않고, 합치기 전에 백업해 둬요. 설정에서 언제든 끌 수 있어요.` · 버튼 `합치기` / `따로 쓰기` |
| 첫 연결 대화상자(PC) | 제목 `폰과 학습 기록을 합칠까요?` · 본문·버튼은 위와 같고 `PC` 대신 `폰` |
| 따로 쓰기 확인(토스트) | `따로 쓰기로 했어요. 설정의 '학습 기록 동기화'를 켜면 언제든 합칠 수 있어요.` |
| 설명(PC) | 휴대폰 연결을 켜고 폰 앱에서 이 PC에 연결하면, 폰과 PC의 학습 기록이 자동으로 합쳐져요. |
| 설명(폰) | PC에 연결돼 있으면 공부한 기록이 PC와 자동으로 합쳐져요. 연결이 안 될 때 공부한 것도 다음 연결 때 반영돼요. |
| 마지막 동기화 줄 | `마지막 동기화: 방금 전` (<60초) · `3분 전` (<1시간) · `오늘 14:32` · `10월 16일 21:05` · `아직 동기화하지 않았어요` |
| 기기 줄 | `함께 쓰는 기기: 내 폰, PC` (peers 이름) / 없으면 `아직 다른 기기가 없어요` |
| 상태 줄 | `동기화 중…` / `동기화됐어요` / 오류 문구(`Pal.BAD` 색, 아래 표) |
| 버튼 | `지금 동기화` (진행 중엔 비활성 + `동기화 중…`) |
| 스위치 | `학습 기록 동기화` (켜기/끄기. 끄면 받기·올리기를 모두 멈춰요) |
| 스위치 설명(끌 때 한 줄) | 끄면 이 기기의 기록은 PC와 주고받지 않아요. 다시 켜면 PC에 남아 있는 기록과 합쳐져요. |
| 링크 | `이전 상태로 되돌리기` → 백업 목록(날짜·이유 `첫 동기화 전/동기화 전/되돌리기 전/초기화 전`) → `이 시점으로 되돌릴까요? 자동 동기화가 꺼져요.` [되돌리기] [취소] |
| 첫 병합 안내(토스트 1회) | `PC와 폰의 학습 기록을 합쳤어요. 합치기 전 기록은 백업해 뒀어요.` |
| 수동 성공 토스트 | `동기화했어요.` (+ 새로 들어온 카드가 있으면 ` 복습 카드 N장이 새로 들어왔어요.`) |
| 시계 경고 | `이 기기의 시계가 PC와 N분 차이 나요. 시계를 자동으로 맞춰 주세요.` |

오류 코드 → 문구(`SyncEngine` 이 `error` 로 채움):

| code | 문구 |
|---|---|
| `unreachable` | PC에 닿지 않아요. 연결되면 자동으로 동기화해요. (폰: `Api.UNREACHABLE_TEXT` 재사용 가능) |
| `not_connected` | PC에 연결되지 않았어요. |
| `old_pc` | 이 PC의 회화 연습이 기록 동기화를 지원하지 않아요. PC 앱을 1.2 이상으로 업데이트해 주세요. |
| `hub_changed` | 다른 PC에 연결돼 있어요. 아래 '이 PC와 새로 합치기'를 눌러 주세요. |
| `state_lost` | 동기화 상태 파일이 손상됐어요. '이전 상태로 되돌리기'로 복원하거나 '새로 합치기'를 눌러 주세요. (기록이 겹쳐 셀 수 있어요) |
| `merge_check_failed` | 합친 결과를 확인하지 못해서 이 기기의 기록은 그대로 뒀어요. 다시 시도하거나 앱을 업데이트해 주세요. |
| `local_read_only` | 이 기기의 기록 파일을 읽지 못해서 동기화를 쉬어요. |
| `disk` | 기록을 저장하지 못했어요. 저장 공간을 확인해 주세요. |
| `server_rejected` | PC가 기록 형식을 받아들이지 않았어요. 두 기기의 앱 버전을 확인해 주세요. |
| `too_large` | 기록이 너무 커서 보내지 못했어요. |
| `peer_newer` (경고, ok) | 다른 기기의 앱이 더 새 버전이에요. 그 기기 기록은 앱을 업데이트한 뒤에 합쳐져요. |
| `bad_reply` | PC가 보낸 답을 이해하지 못했어요. |

### 6.4 `SyncEngine.sync_now()` 결과 Dictionary(계약)

`choice=="undecided"` 또는 스위치 꺼짐이면 요청 없이 `{ok:false, code:"disabled", error:"", ...}` 를 돌려준다(UI 는 오류로 표시하지 않음).

`{"ok": bool, "code": String("ok"|위 코드|"disabled"), "error": String(한국어, ok 면 ""), "applied": bool, "pushed": bool, "reason": "start|reconnect|change|poll|pause|resume|manual", "peers": int, "changes": {"cards_added": int, "cards_removed": int, "checks_changed": int, "marks_changed": int, "known_added": int, "known_removed": int}, "trimmed": {"cards": int, "known": int}, "clock_off_sec": int, "warnings": [String], "duration_ms": int}`

---

## 7. 안전장치

### 7.1 백업 (`SyncBackup`, `user://sync_backup/`)
- 적용으로 로컬이 바뀌기 **직전**마다(마지막 백업이 5분 안이면 건너뜀. 단 `first`/`restore`/`unlink` 는 항상) 폴더 `YYYYMMDD-HHMMSS-<reason>/` 를 만들어 `progress.json`, `studylog.json`, `prefs.json`, `sync_state.json`(있는 것만)을 복사하고 `meta.json {reason, at, md5{파일:md5}}` 를 쓴다. `reason` ∈ `first|auto|restore|unlink`.
- 보관: `first` 는 **영구 1개**, 나머지는 최신 **10개**(오래된 것부터 삭제). 백업 한 벌 크기는 보통 수백 KB.
- 복사 실패(디스크 가득 등) 시 **적용하지 않는다**(`disk`).
- 5분 throttle 로 건너뛴 구간의 로컬 변경도 허브 복제본(`pushed`)에는 이미 들어 있어 원본이 보존된다(허브는 기기당 직전 한 세대 `.prev` 도 둔다).

### 7.2 병합 결과 검사 (`SyncMerge.check`, `sync_round` 안에서 항상 실행)
하나라도 깨지면 로컬을 건드리지 않고 `merge_check_failed`(문제 목록은 `user://sync_last_problem.json` 에 키 이름·개수만 저장, 값 없음).
1. 카운터: 모든 잎에서 `view ≥ local`(적용 대상 기간 안, 상한으로 잘린 값은 상한과 비교).
2. 집합: `local` 에만 있고 `view` 에 없는 키는, **다른 복제본의 `del` 이 그 키의 모든 `add` 보다 큰 경우에만** 허용(독립적으로 다시 계산).
3. 카드: 같은 키의 `view.reps ≥ local.reps`; `view` 카드 수 ≥ 복제본 카드 키의 합집합 − 삭제된 키 − `trimmed`.
4. 미션: `stars`, `done_goals` 가 줄지 않음.
5. 형식: `start` 유효 ISO, prefs 값 타입·범위(`daily_goal_min` 0~240 정수, `lesson_source` ∈ {ai, tatoeba}), `to_local` 결과가 `Progress.normalize` / `StudyLog._normalize` 를 거쳐도 카드·단어 수가 같다(다르면 `trimmed` 로 보고하되 상한 때문인 경우만 허용).
6. JSON 왕복(`stringify → parse`)이 같다.
- 시험용 훅 `SyncMerge.test_corrupt: Callable`(비어 있음)이 있으면 `check` 직전에 `view` 를 변조해 적용한다 → "검사기가 실제로 막는지" 를 시험한다(기존 `Progress.write_hook` 방식).

### 7.3 적용 순서와 저널(꺼져도 안전)
1. 사이드카에 `pending = {view, own, seq}` 와 새 `own` 을 저장(원자적).
2. `Store.apply_sync_progress` → `StudyLog.apply_sync` → `Store.apply_sync_prefs` 순서로 각각 원자적 저장(`.tmp → rename`, 기존 1.1.1 방식).
3. 사이드카에 `base = extract(적용 후 로컬)`, `pending = null`, `seq+1` 저장.
- 시작 시(`SyncEngine` 첫 호출) `pending != null` 이면 `pending.view` 를 다시 적용하고 3번을 한다(적용은 멱등: 같은 view 를 두 번 써도 결과 같음). 적용 도중 어떤 쓰기가 실패하면 `disk` 로 끝내고 `pending` 은 그대로 둔다(다음 라운드 첫 일).
- `base` 를 병합 결과가 아니라 **적용 후 실제 로컬에서 다시 뽑는** 이유: 로컬 정규화(상한 자름, 0 항목 제거)가 병합 결과와 달라도 다음 차이가 0 이 되게 하려는 것이다.

### 7.4 시험이 실제 사용자 폴더를 쓰지 않게 하는 격리(4중)
1. **실행 래퍼** `godot/tests/run_sync_tests.ps1` 가 `APPDATA` 를 시험 전용 임시 폴더(`scratchpad\w_sync_<작업>\appdata`)로 바꿔 Godot 을 실행한다 → `user://` 가 그 안으로 간다(ROADMAP "테스트 격리" 항목의 방법).
2. **시험 코드 가드**: 모든 Godot 동기화 시험은 시작 즉시 `OS.get_user_data_dir()` 가 환경변수 `HOEHWA_SYNC_TEST_ROOT` 로 시작하지 않으면 아무것도 쓰지 않고 종료코드 2 로 끝낸다. 그리고 `Store.progress_path`, `Store.prefs_path`, `StudyLog.path`, `SyncState.path`, `SyncBackup.root` 를 `user://sync_test_<이름>/…` 로 돌리고 끝에 원복·삭제한다.
3. **백엔드**: 시험 허브는 항상 `--sync-dir <임시>` 를 줘서 띄운다. `--port` 만 주고 `--sync-dir` 가 없으면 허브가 꺼진다(503) → 실수로도 `backend/data/sync/` 를 안 쓴다. 시험 포트는 `18791~18799` 중 비어 있는 것(8770·8775·8776·8862~8869 금지).
4. **감시**: 래퍼가 시작 전/후에 실제 `%APPDATA%\Godot\app_userdata\회화 연습\` 의 `progress.json`, `prefs.json`, `studylog.json` 의 MD5 와 **폴더 파일 목록(이름·크기)**, 그리고 `backend\data\sync\` 존재 여부/목록을 기록해 하나라도 다르면 FAIL. (`sync_state.json`, `sync_backup\` 이 새로 생겨도 FAIL.)
- 실제 사용자 폴더는 읽기만(MD5, 목록). 값은 출력하지 않는다.

### 7.5 되돌리기 방법(운영)
앱: 설정 → 기록 동기화 → "이전 상태로 되돌리기"(§4.8). 수동: `user://sync_backup/<폴더>/` 의 세 파일을 앱을 끈 채로 `progress.json` 등 위에 복사. 허브 쪽: 허브는 원본을 지우지 않으므로 `backend\data\sync\replicas\*.json` 을 그대로 두면 모든 기록이 남아 있다.

---

## 8. 작업 분할

공통 규칙: 각 작업자는 **표의 "수정 허용"** 만 고친다. 임시 파일은 `scratchpad\w_<ID>\`. 프로세스는 자기가 시작한 PID 만 종료. 포트는 `18791~18799` 중 비어 있는 것. 보고 맨 앞에 합격 조건 표(항목/O·X/근거), 실행 안 한 항목은 "미검증". 새 `class_name` 이 생기면 `GODOT --headless --path D:\Ai\언어\app\godot --import` 로 캐시를 갱신한다. `godot/scripts/ui/*`, `godot/tests/touch_scroll_test.*` 는 다른 작업자가 고치는 중이므로 **읽기만**.

표기: PY = `D:\Ai\언어\app\backend\.venv\Scripts\python.exe`, GODOT = `%USERPROFILE%\Desktop\Godot_v4.6.3-stable_win64.exe\Godot_v4.6.3-stable_win64_console.exe`.

| ID | 담당 | 내용 | 수정 허용(소유) | 의존 | 동시 가능 |
|---|---|---|---|---|---|
| S1 | **worker-hard** | 허브 백엔드(`sync_hub.py`), `lan.py` ALLOW 2줄, `server.py` 연결, 스텁 서버 연결 | 신규 `backend/sync_hub.py`; `backend/server.py`(import 1줄 + `sync_hub.attach(...)` 호출 3줄 이내, 다른 줄 금지); `backend/lan.py`(`ALLOW` 에 2항목만); `backend/lan_stub_server.py`(라우터 연결 + `--sync-dir` 인자만); `backend/test_lan.py`(`len(lan.ALLOW) == 23` → `25` 한 곳만) | 이 문서 | S2·S5·S6a 와 동시 |
| S2 | **worker-hard** | 순수 함수 `SyncDoc`, `SyncMerge` | 신규 `godot/scripts/sync/sync_doc.gd`, `sync_merge.gd`(+ `.uid`) | 이 문서 | S1·S5·S6a 와 동시 |
| S5 | worker | 허브 시험 + 허브 변이 시험 | 신규 `backend/test_sync_hub.py`, `backend/sync_hub_mutations.json`, `backend/run_sync_hub_mutations.ps1` | 문서만 보고 작성(구현 코드를 읽지 않는다). 실행·변이는 S1 뒤 | S1·S2 와 동시(작성) |
| S6a | worker | 병합 단위 시험 | 신규 `godot/tests/sync_merge_test.gd`, `.tscn`(+ `.uid`) | 문서만 보고 작성. 실행은 S2 뒤 | 동시(작성) |
| S6b | worker | 병합 변이 시험 | 신규 `godot/tests/sync_mutations.json`, `godot/tests/run_sync_mutations.ps1` | S2 완료 + S6a | S6a 뒤 |
| S3 | **worker-hard** | 엔진: 사이드카·백업·저널·포트·라운드 + 저장소 적용 함수 | 신규 `godot/scripts/sync/sync_engine.gd`, `sync_state.gd`, `sync_backup.gd`, `sync_ports.gd`(+ `.uid`; 선택·스위치·재합류·probe 포함, §4.8.1); 기존 `godot/scripts/autoload/store.gd`(`apply_sync_progress`, `apply_sync_prefs` 추가만), `godot/scripts/core/study_log.gd`(`apply_sync` 추가만), `godot/scripts/core/progress.gd`(`MAX_REVIEW` 1000→3000 한 줄), `godot/tests/t5_wiring_test.gd`(307행 `MAX_REVIEW == 1000` → `3000` 한 줄), `godot/scripts/autoload/api.gd`(`IDEMPOTENT_POST` 에 `"/sync/push"` 한 항목) | S2 의 함수 시그니처(문서 §9.1)는 지금 확정이므로 병행 착수 가능. 시험 실행은 S1·S2 뒤 | S4·S7 과 병행(S4·S7 은 S3 의 공개 함수가 생긴 뒤 실행) |
| S4 | worker | 엔진 시험·왕복·끊김·동시·스위치·선택·격리 러너 | 신규 `godot/tests/sync_engine_test.gd/.tscn`, `godot/tests/sync_roundtrip_test.gd/.tscn`, `godot/tests/sync_fixtures/*.json`, `godot/tests/run_sync_tests.ps1`, `godot/tests/sync_engine_mutations.json` | S1·S2·S3 | S7 과 병행 |
| S7 | worker | 매니저(타이머·생명주기)·설정 패널·연결 | 신규 `godot/scripts/sync/sync_manager.gd`, `sync_panel.gd`(스위치·상태), `sync_choice_dialog.gd`(첫 연결 선택 대화상자), 시험 `godot/tests/sync_manager_test.*`, `godot/tests/sync_panel_test.*`(+ `.uid`); 기존 `godot/scripts/main.gd`(`add_sync()` 추가와 `add_v11_tabs()` 옆 호출 1곳), `godot/scripts/views/today_view.gd`(`SyncPanel` 마운트 1줄 + 초기화 확인 문구 §4.8) | S3 | S4 와 병행. 지금 `today_view.gd` 를 고치는 다른 작업자는 없다(Q6). 이후 UI 전면 개편 예정이므로 화면 변경은 독립 `SyncPanel`(+ 별도 대화상자 파일)과 마운트 1줄로 한정해 나중에 옮기기 쉽게 한다 |
| S8 | worker | 문서 | `API.md`("기록 동기화" 절 추가, 휴대폰 허용 목록 23개 → 25개 문구), `ROADMAP.md` 는 **오케스트레이터가** | S1 | |
| R1~R4 | reviewer | 새 컨텍스트 독립 검토: R1=S1+S5(허브), R2=S2+S6(병합), R3=S3+S4(엔진·왕복), R4=S7+S8(UI·문서)+통합 | 코드 수정 없음 | 각 묶음 완료 후 | R1·R2 동시 |

겹침 점검: `sync_*.gd` 는 파일마다 소유자가 하나. 기존 파일은 S1(`server.py`, `lan.py`, `lan_stub_server.py`, `test_lan.py`)·S3(`store.gd`, `study_log.gd`, `progress.gd`, `t5_wiring_test.gd`, `api.gd`)·S7(`main.gd`, `today_view.gd`)가 서로 다른 파일만 고친다. S3 가 건드리는 `store.gd`/`study_log.gd` 는 다른 진행 중인 작업이 없다고 가정한다(Q6/Q7 결정: 지금 다른 작업자 없음. 단 이후 UI 전면 개편이 예정되어 있으므로 S7 의 화면 변경은 `SyncPanel` 독립 패널 + 설정 카드에 마운트 1줄로 한정한다).

실행 순서: **1단계(병렬)** S1, S2, S5(작성), S6a(작성), S8 준비 → **2단계** S3(+S5·S6a 실행), S6b → **3단계(병렬)** S4, S7 → **4단계** R1·R2(1·2단계 직후 가능), R3, R4 → 오케스트레이터 통합·실제 폰 확인.

---

## 9. 공개 시그니처(작업 간 계약 — 바꾸려면 오케스트레이터 승인)

### 9.1 순수 함수 (S2 구현, S3·S6 사용)

```gdscript
class_name SyncDoc extends RefCounted
const SCHEMA := 1
const SHARED_PREFS := {"daily_goal_min": 10, "lesson_source": "tatoeba", "auto_fix_cards": true,
                       "tts_voice_en": "af_heart", "tts_voice_ja": "jf_alpha", "tts_speed": 1.0}   # 키 → 기본값
static func blank_view() -> Dictionary
static func blank_replica() -> Dictionary
## progress=Store.progress, studylog=StudyLog.snapshot(), prefs=Store.prefs. 카드 시각에 skew 를 더한다.
static func extract(progress: Dictionary, studylog: Dictionary, prefs: Dictionary, skew: int) -> Dictionary
## 병합 결과(view)를 로컬 모양으로: {"progress": Dictionary, "studylog": Dictionary, "prefs_changes": Dictionary}. 카드 시각에서 skew 를 뺀다.
static func to_local(view: Dictionary, skew: int, progress: Dictionary, studylog: Dictionary, prefs: Dictionary) -> Dictionary
## 복제본 구조 검사. 문제 없으면 [], 있으면 ["doc.progress.xp.en: not int", ...] (값은 담지 않음)
static func validate_replica(doc: Variant) -> Array
## base 로 저장할 축약본(cards.data·prefs 제거)
static func to_base(view: Dictionary) -> Dictionary

class_name SyncMerge extends RefCounted
const TIME_SLACK := 5
const DEL_KEEP_SEC := 400 * 86400
static var test_corrupt: Callable = Callable()   # 시험 전용: (view) -> view
static func sync_round(args: Dictionary) -> Dictionary   # §4.4
static func new_outcomes(base_h: String, local_h: String) -> String   # §4.5
static func card_wins(a: Dictionary, b: Dictionary) -> bool   # a 가 b 를 이기나(D5). 같으면 false
static func canonical(v: Variant) -> String   # 키 정렬 JSON (비교·지문용)
```

### 9.2 엔진·포트 (S3 구현, S4·S7 사용)

```gdscript
class_name SyncPorts extends RefCounted
## 시험에서 바꿔 끼우는 모든 바깥 접근. 기본값 live() 는 Store/StudyLog/Api/실제 시계를 쓴다.
var state_path: String = "user://sync_state.json"
var backup_root: String = "user://sync_backup"
var device_name: String
var device_kind: String          # "pc" | "phone"
var now_unix: Callable           # () -> int
var today_days: Callable         # () -> int
var load_local: Callable         # () -> {"progress","studylog","prefs"}  (딥카피)
var apply_local: Callable        # (progress, studylog, prefs_changes) -> bool
var local_paths: Callable        # () -> {"progress": String, "studylog": String, "prefs": String}  (백업 복사 대상)
var is_read_only: Callable       # () -> bool
var http_get: Callable           # (path: String, timeout: float) -> Api 결과 Dictionary(await 가능)
var http_post: Callable          # (path: String, body: Dictionary, timeout: float) -> 〃
var is_busy_ui: Callable         # () -> bool  (녹음 중이면 true → 적용 연기)
static func live() -> SyncPorts

class_name SyncEngine extends RefCounted
signal finished(result: Dictionary)
func _init(ports: SyncPorts) -> void
func sync_now(reason: String) -> Dictionary        # await 가능. §6.4 결과
func status() -> Dictionary    # {enabled, choice, linked, busy, last_ok, last_error{code,error,at}, peers[], backups:int, clock_off_sec, first_done}
func set_enabled(on: bool) -> void                # 스위치. 끄면 disabled_at 기록, 켜면(합치기 선택자) rebase 설정
func needs_choice() -> bool                        # choice=="undecided" (사이드카 없음 포함)
func set_choice(choice: String) -> Dictionary      # "merge" | "separate". merge → 첫 동기화까지 수행해 결과 반환, separate → enabled=false
func probe_peers() -> int                          # PC undecided 전용: 읽기 전용 pull 1번, 다른 기기 복제본 수(-1=실패). 사이드카·로컬을 바꾸지 않는다
func list_backups() -> Array   # [{name, reason, at, md5}]
func restore_backup(name: String) -> Dictionary   # {ok, error}
func unlink_for_reset() -> void
func relink_fresh() -> Dictionary                  # '이 PC와 새로 합치기' / state_lost 의 '새로 합치기'
func local_fingerprint() -> String

class_name SyncManager extends Node     # S7: 타이머·생명주기·Store/Backend 신호 연결
func request_sync(reason: String) -> void       # disabled/undecided 이면 아무 요청도 만들지 않음
signal choice_needed(kind: String)                # "phone"|"pc" — SyncPanel/대화상자가 받는다
```

### 9.3 저장소 적용 함수 (S3 가 추가, 이름 고정)

```gdscript
# store.gd
func apply_sync_progress(p: Dictionary) -> bool   # progress_read_only 면 false. Progress.normalize 후 교체, 원자적 저장, 실패 시 메모리 원복, 성공 시 changed.emit()
func apply_sync_prefs(changes: Dictionary) -> bool   # SHARED_PREFS 키만 반영, 원자적 저장, prefs_changed.emit()
# study_log.gd
static func apply_sync(parts: Dictionary) -> bool    # parts={days,phon,missions} (freeze 는 건드리지 않음); _read_only 면 false; _normalize 후 즉시 쓰기(_write_text), 실패 시 원복
```

---

## 10. 합격 조건 (O/X) 와 금지 조건

각 항목은 명령을 실행해 출력으로 판정한다. 실행하지 않은 항목은 O 가 아니라 "미검증".

### 10.1 S1 허브 (worker-hard)
| ID | 명령 / 확인 | 기대 | 판정 |
|---|---|---|---|
| H-01 | `& $PY D:\Ai\언어\app\backend\test_sync_hub.py` | 마지막 줄 `SYNC_HUB_TEST_RESULT PASS n/n`, n ≥ 45, 종료코드 0 | O/X |
| H-02 | `& $PY D:\Ai\언어\app\backend\test_lan.py` | 마지막 줄 `LAN_TEST_RESULT PASS k/k`, k 는 작업 전 기준선과 같음(WORKLOG 기준 160; 작업 전에 직접 측정해 보고), `len(lan.ALLOW)==25` | O/X |
| H-03 | `server.py` 변경 확인: 작업 전 복사본(`scratchpad\w_S1\server.py.orig`)과 `fc` 비교 | 추가된 줄만 있고 `import sync_hub` 1줄 + `sync_hub.attach` 호출 3줄 이내, 삭제·수정된 기존 줄 0 | O/X |
| H-04 | 시험 서버를 `--port 1879x`(`--sync-dir` 없음)로 띄워 `GET /sync/pull?device_id=0123456789abcdef` | 503 `code":"sync_off"`, `backend\data\sync` 폴더가 생기지 않음(`Test-Path` False) | O/X |
| H-05 | 시험 서버 `--sync-dir <임시>` 로 정상 push→pull 왕복 | push 200 `rev` 증가, pull 에 상대 복제본 `doc` 가 바이트 단위로 같은 JSON(키 정렬 비교) | O/X |
| H-06 | 로그 점검: 시험 서버 로그에서 `Select-String -Pattern 'hp1_|Authorization|bearer'` | 0건. 기록 값(시험용 단어 `ZZSENTINEL`)이 로그에 0건 | O/X |
| H-07 | 시험 후: `Get-Process`/포트 확인(`netstat -ano`)에서 자기가 띄운 PID·포트 | 남은 프로세스·열린 포트 없음(보고에 적음) | O/X |
| H-08 | 금지: 실제 `%APPDATA%\Godot\app_userdata\회화 연습\` 의 `progress/prefs/studylog.json` MD5, 실제 `backend\data\sync` 존재 여부 시작 전/후 | 동일(§7.4-4) | O/X |

금지 조건(S1): 기존 `lan.py` 로직 수정 금지(ALLOW 두 항목 추가만), `lan_devices*.json` 읽기/쓰기 금지, 포트 8770/8775/8776/8862~8869 사용 금지, 토큰·기록 값 출력 금지, `backend\data\sync` 에 시험 데이터 쓰기 금지.

### 10.2 S5 허브 시험 (worker) — `test_sync_hub.py` 가 반드시 포함할 시나리오
| ID | 시나리오 | 기대 |
|---|---|---|
| T-H1 | push 정상 → pull 에 상대로 보임, 자기 자신은 `replicas` 에 없음 | 200, 일치 |
| T-H2 | 같은 `seq`·같은 본문 재전송 | 200 `dup:true`, `rev` 안 변함 |
| T-H3 | 낮은 `seq` | 409 `stale_seq` + `stored_seq` |
| T-H4 | 같은 `seq` 다른 본문 | 409 `seq_reuse` |
| T-H5 | 깨진 JSON / JSON 배열 / 빈 본문 | 400 `bad_request`, 저장 상태 불변(replicas 폴더 MD5 동일) |
| T-H6 | 일부러 틀린 doc: `v:2`, `xp.en:"7"`, `xp.en:-1`, `t:-5`, 키 형식 위반, 카드 `target` 301자, cards 3501개, 깊이 9, 알 수 없는 최상위 키 | 각각 400 `bad_doc` + `detail` 경로, 불변 |
| T-H7 | `device_id` 형식 위반(대문자, 15자, `../x`, 빈 값) pull/push | 400 `bad_device_id`, 폴더 밖 파일 생성 없음 |
| T-H8 | 본문 3 MiB 초과(루프백) | 413 `too_large`, 불변 |
| T-H9 | 복제본 17번째 새 id | 409 `too_many_devices` |
| T-H10 | `rev` 같으면 `unchanged:true`, 다르면 전체 | 응답 형식 §5.2 |
| T-H11 | 복제본 파일을 외부에서 깨뜨림 → pull | `.prev` 로 대체되거나 `warnings:[replica_unreadable]`, 200, 깨진 파일은 `.bad` 로 격리 |
| T-H12 | 루프백 보안: `Host: evil.example`, `Origin: http://evil.example`, `Content-Type: text/plain` POST | 모두 403 `bad_origin`. 정상 헤더는 200 |
| T-H13 | :8775 리스너(`--lan-enabled`, 훅 `HOEHWA_TEST_HOOKS=1 HOEHWA_LAN_ASSUME_TAILSCALE=127.0.0.1`): 토큰 없음/틀린 토큰/정상 토큰 | 401 `token_missing`, 401 `token_invalid`, 200 |
| T-H14 | 동시 push 24개(서로 다른 id 8개 × 3번씩, 스레드) 와 동시 pull | 모든 응답이 200 또는 설계된 409, 끝난 뒤 모든 복제본 파일이 유효한 JSON, `*.tmp` 0개, `rev` = 성공한 비-dup push 수 |
| T-H15 | 새 서버 프로세스로 재시작(같은 `--sync-dir`) | `hub_id`·`rev`·복제본 유지 |
| T-H16 | 쓰기 실패 주입(대상 폴더를 읽기 전용으로 바꾸거나 `replicas` 를 파일로 교체) | 500 `store_failed` 또는 503, 기존 복제본 불변 |
| T-H17 | `--sync-dir` 없이 `--port` 시험 서버 | 모든 `/sync/*` 가 503 `sync_off` |
| T-H18 | 허용 목록: `("PUT","/sync/pull")`, `("GET","/sync/push")`, `("POST","/sync/pull")` | :8775 에서 403 `lan_forbidden`(토큰 있음), 루프백에서 405/404 |

변이 시험(S1 완료 후, 사본에서): `sync_hub_mutations.json` 의 각 변이를 **사본** `scratchpad\w_S5\mut\backend\` 에 적용해 `test_sync_hub.py` 가 FAIL(종료코드 ≠ 0)해야 한다 — M-H1 스키마 검증 생략, M-H2 `seq` 검사 제거, M-H3 `bad_origin` 검사 제거, M-H4 크기 제한 제거, M-H5 임시파일 없이 직접 쓰기(T-H14/T-H16 에서 걸려야 함), M-H6 `device_id` 정규식 제거, M-H7 `sync_off` 기본 경로 허용(시험 서버가 실제 경로 사용). 합격: 변이 7개 모두 FAIL 확인, 원본 파일 MD5 불변.

### 10.3 S2 순수 함수 (worker-hard)
| ID | 명령 | 기대 | 판정 |
|---|---|---|---|
| M-01 | `& $GODOT --headless --path D:\Ai\언어\app\godot --import` 후 `& $GODOT --headless --path D:\Ai\언어\app\godot --quit` | 종료코드 0, 출력에 `SCRIPT ERROR`·`Parse Error` 0건 | O/X |
| M-02 | `& $GODOT --headless --path D:\Ai\언어\app\godot res://tests/sync_merge_test.tscn` (S6a 가 만든 시험) | 마지막 줄 `== sync_merge result: N passed, 0 failed ==`, N ≥ 90, 종료코드 0 | O/X |
| M-03 | 순수성: `sync_doc.gd`·`sync_merge.gd` 에서 `FileAccess`, `DirAccess`, `OS.`, `Time.`, `randi`, `randf`, `Engine.`, `Api`, `Store`, `StudyLog` 문자열 검색 | 0건(`StudyLog` 상수 복사 필요 시 값을 상수로 적는다) | O/X |
| M-04 | 입력 불변: 시험이 `sync_round` 호출 전후 `args` 를 `canonical` 비교 | 동일 | O/X |
| M-05 | 성능: 카드 3000 + 아는 단어 30000×2 + 날짜 400일 복제본 3개 병합 시간(시험이 `Time.get_ticks_msec` 로 측정) | ≤ 5000 ms | O/X |

금지(S2): `Store`/`StudyLog`/`Api` 의존, 시계·난수·파일 접근, 위 시그니처 변경, 다른 작업자 소유 파일 수정.

### 10.4 S6a 병합 단위 시험 (worker) — `sync_merge_test.gd` 필수 사례
각 사례는 입력을 고정값으로 만들어 `sync_round` 를 호출하고 기대값을 단언한다. 아래 번호가 시험 이름 앞에 붙는다.

| ID | 사례 | 기대 |
|---|---|---|
| U01 | 첫 동기화 합집합: PC checks {a,b}, 폰 checks {b,c} (둘 다 base 없음) | 결과 {a,b,c}, b 한 번 |
| U02 | 합집합 카드: PC 카드 {X,Y}, 폰 {Y,Z} | {X,Y,Z}, Y 는 한 장 |
| U03 | 이중 계산 없음(§ 아래 예 A): 라운드를 §예 A 순서대로 | 최종 양쪽 `days.sec` = 960, 1860 이 아님 |
| U04 | 멱등: 같은 입력 `sync_round` 2번, 그리고 결과 `own`/`view` 를 다시 입력으로 넣어 3번째 | `own`·`view` canonical 동일 |
| U05 | 교환: peers 3개를 모든 순열(6가지)로 | `view` canonical 모두 동일 |
| U06 | 수렴: PC·폰·PC·폰 순으로 서로의 `own` 을 peers 로 두 번씩 | 두 기기 `view` 동일 |
| U07 | 삭제 전파: PC 가 체크 a 해제(base 에 a, local 에 없음) | 폰 병합 결과에서 a 없음 |
| U08 | 삭제 후 재추가: U07 뒤 폰이 a 를 다시 체크(더 늦은 stamp) | a 있음 |
| U09 | 동시 삭제/추가 같은 시각(tie) | 있음(추가 우선) |
| U10 | 카드 승자: reps 5(last 1000) vs reps 6(last 900) | reps 6 채택 |
| U11 | 같은 reps, last_review 다름 / 같으면 stability / 모두 같으면 canonical 사전순 | 순서대로 결정, `card_wins(a,b)` 와 `card_wins(b,a)` 가 동시에 true 인 경우 0 |
| U12 | 카드 id 보존: 로컬에 키 X(id L1), 폰에서 온 X(id P9) | 결과 X 의 id = L1. 폰에서만 온 키의 id 가 로컬의 다른 카드 id 와 같으면 id 가 바뀜 |
| U13 | 카드 삭제 vs 상대 복습: PC 가 X 삭제(del 100), 폰 X add 50 → 삭제됨; 폰 add 150 → 있음 | 위 |
| U14 | 날짜별 시간: 같은 날 폰 300 + PC 600 / 서로 다른 날 / 합이 86400 초과 | 900 / 두 날 모두 / 86400 로 잘림 |
| U15 | 이중 계산 방지 잎 전부: `by`, `n`, `lesson`, `score` 도 같은 규칙 | 각 잎이 합, 두 번째 라운드에도 같음 |
| U16 | 미션: 별 폰 2·PC 3, done_goals 1·2, last, plays | stars 3, done_goals 2, last 늦은 날, plays 합(자기 몫 합) |
| U17 | 보호권 비동기화: 서로 다른 `freeze` 를 가진 폰·PC 로 `sync_round`+`to_local` | `extract` 결과·복제본에 `freeze` 키 없음, `to_local` 결과 `studylog` 에 `freeze` 가 입력과 바이트 단위로 같음 |
| U18 | 연속 기록: PC 가 월·화, 폰이 수·목 공부 | 합친 marks 로 `StreakCalc.settle` 계산 시 연속 4(시험은 marks 합집합 4일을 단언) |
| U19 | 음소: `new_outcomes` 표(§4.5) 5행 + 두 기기 `h` 가 `t` 순으로 이어짐, 30자 초과 시 뒤 30자, `heard` 합 | 표대로 |
| U20 | 시계: ① 미래 `t`(saved_hub+10일)로 올린 삭제 이벤트가 이후 정직한 추가(saved_hub+1)를 이기지 못함 ② `extract(…, skew=−7200)` → `to_local(…, −7200)` 왕복이 카드 due/last_review 를 보존 ③ skew=+7200 에서 같은 카드의 hub 시각 | 단언대로 |
| U21 | 스키마: peer `doc.v=2` → 병합에서 빠지고 `report.peers_skipped[0].reason=="newer"`; `doc.v` 누락/문자열 → `invalid`; peer 가 `null`/배열/섹션 타입 틀림 → 예외 없이 무시 | |
| U22 | 깨진 own: `own={"progress":5}`, `own=null`, `own="x"` | `{}` 취급, 예외 없음 |
| U23 | 깨진 숫자: 음수, NaN, `inf`, 문자열, 1e30 | 0 또는 상한, 예외 없음, `view` 의 모든 숫자가 정수·상한 안 |
| U24 | 검사기 막음: `test_corrupt` 로 `view.xp.en` 을 `local` 보다 작게, 카드 수 줄임, 별 3→1 로 변조 | 각각 `ok==false`, `problems` 비어 있지 않음, 반환 `view` == `local`(변조 아님) |
| U25 | 검사기 통과: 정상 병합 100개 무작위 시나리오(시드 고정) | 모두 `ok==true` |
| U26 | prefs: 기본값 vs 사용자가 바꾼 값(t=0 vs t>0), 둘 다 바꾼 경우 늦은 쪽, 값 타입 틀림(`daily_goal_min:"x"`, `lesson_source:"zzz"`) 무시, `mic_device` 는 `extract` 결과에 없음 | |
| U27 | known_words: 합집합, 해제 전파, 상한 초과 시 `trimmed.known` 보고, 오래된 것부터 잘림 | |
| U28 | `start`: 기본(t=0) vs 사용자 설정 → 설정값 승, 둘 다 설정이면 늦은 쪽, 같은 t 면 ISO 큰 쪽 | |
| U29 | `rebase`: §4.8 시나리오(base 비어 있고 local 이 옛 상태 + rebase.sets_at=500, 남의 del 600) | 600 의 삭제가 이김, 400 의 삭제는 짐 |
| U30 | 처음 동기화 + 상대 비어 있음 | `view == local`(canonical), 백업/적용 불필요 판정(`changed==false`) |

**예 A (U03 의 정확한 순서)** — 날짜 `2026-10-17`, `en.sec`: PC 600, 폰 300(둘 다 처음, base 없음).
1. PC 라운드(peers 없음): PC.own.sec=600, view=600, base=600.
2. 폰 라운드(peers=[PC 의 own]): 폰.own.sec=300, view=900, 폰 local=900, base=900.
3. PC 라운드(peers=[폰.own]): PC delta=0 → own 600, view=900, PC local=900.
4. PC 가 60초 더 공부(local 960): PC delta=60 → own 660, view=660+300=960.
5. 폰 라운드(peers=[PC.own 660]): view=960. → 양쪽 960.

**예 B (카드 삭제 흔적)** — PC 가 카드 `en|I went home` 을 지움: PC.base 키 배열에 있고 local 에 없음 → `del[키]=stamp(=1000)`. 폰.own.add[키]=500 → 병합 결과에 없음(500 < 1000). 이후 폰이 같은 문장을 다시 추가(stamp 1200) → `add 1200 ≥ del 1000` → 있음.

### 10.5 S6b 변이 시험 (worker) — `sync_mutations.json` + `run_sync_mutations.ps1`
형식: `[{"id","file","find","replace","expect_fail":["U03",…]}]`. 러너는 `godot/scripts/sync/`, `godot/tests/sync_merge_test.*`, `project.godot`, 필요한 `core/`·`autoload/`를 `scratchpad\w_S6b\proj\` 로 복사한 **사본**에서 변이를 적용하고 시험을 실행해, 지정한 시험이 실패하는지 확인한다.
| 변이 | 내용 | 반드시 FAIL 해야 하는 시험 |
|---|---|---|
| MG1 | 카운터를 합이 아닌 `max` 로 병합 | U01(xp/days 합 사례)·U03 |
| MG2 | 카운터 병합 때 `own` 대신 `local` 전체를 몫으로 삼음(이중 계산) | U03·U15 |
| MG3 | `max(0, local−base)` 에서 `max(0, …)` 제거(음수 허용) | U23·U03 |
| MG4 | 삭제 흔적 무시(항상 합집합) | U07·U13 |
| MG5 | 동률에서 삭제 우선 | U09 |
| MG6 | 카드 승자 비교를 `last_review` 만으로 | U10 |
| MG7 | 카드 승자 비교 방향 반전 | U10·U11 |
| MG8 | 미션 `stars` 를 min | U16 |
| MG9 | 시각 자르기(`TIME_SLACK`) 제거 | U20 |
| MG10 | 첫 동기화에서 늦은 복제본이 통째로 이김(덮어쓰기) | U01·U02 |
| MG11 | `check()` 가 항상 `[]` | U24 |
| MG12 | `to_local` 이 합쳐진 값으로 `freeze` 를 덮어씀(또는 `extract` 가 `freeze` 를 복제본에 넣음) | U17 |
| MG13 | `new_outcomes` 가 항상 `local_h` 전체 | U19 |
| MG14 | 카드 `id` 를 승자의 것으로 교체 | U12 |
| MG15 | `peers` 순서에 의존(첫 승자 우선) | U05 |
합격: 15개 모두 지정 시험 FAIL(= 변이 탐지), 변이 없는 원본 사본은 0 failed, **원본 소스 파일 MD5 시험 전후 동일**.

### 10.6 S3 엔진 (worker-hard)
| ID | 명령 | 기대 | 판정 |
|---|---|---|---|
| E-01 | `--import` 후 `GODOT --headless --path D:\Ai\언어\app\godot --quit` | 종료코드 0, `SCRIPT ERROR`·`Parse Error` 0건 | O/X |
| E-02 | `& $GODOT --headless --path ...\godot res://tests/sync_engine_test.tscn` (S4 작성) | 마지막 줄 `== sync_engine result: N passed, 0 failed ==`, N ≥ 40 | O/X |
| E-03 | 회귀: `persist_test`, `study_log_test`, `fsrs_test`, `review_walk_test`, `streak_test`, `t5_wiring_test`, `smoke` 각각 `GODOT --headless --path ...\godot res://tests/<이름>.tscn` | 작업 전 기준선과 같은 통과 수, 0 failed(`t5_wiring_test` 의 MAX_REVIEW 항목은 3000 기준) | O/X |
| E-04 | `progress.gd` 변경 확인 | `MAX_REVIEW` 한 줄 외 차이 0 | O/X |
| E-05 | `store.gd`/`study_log.gd` 변경은 함수 추가만 | 기존 줄 삭제·수정 0(`fc` 비교) | O/X |
| E-06 | 사이드카/저널: S4 시험 E-J1~E-J3 | §10.7 | O/X |

금지(S3): `ui/*` 수정, 허브/백엔드 파일 수정, 병합 로직(`SyncMerge`)을 엔진 안에 복제, 실제 `user://` 파일 쓰기(시험은 §7.4 격리), 토큰 로그 출력.

### 10.7 S4 엔진·왕복 시험 (worker) — 필수 시나리오
러너 `run_sync_tests.ps1` 가 ① 실제 사용자 폴더 MD5·목록 기록 ② 임시 APPDATA·`HOEHWA_SYNC_TEST_ROOT` 설정 ③ 비어 있는 포트(18791~18799) 확인 ④ 스텁 서버 `lan_stub_server.py --port <p> --sync-dir <임시>` 시작(PID 저장 변수 보관) ⑤ Godot 시험 실행(`-- --api=http://127.0.0.1:<p>`) ⑥ 자기 PID 만 종료 ⑦ MD5·목록 재확인 ⑧ `SYNC_E2E_RESULT PASS n/n` 출력. 시험 서버는 `lan_stub_server.py`(S1 이 `sync_hub` 연결)를 쓴다.

**엔진 단위(가짜 포트, 네트워크 없음) `sync_engine_test`**
| ID | 사례 | 기대 |
|---|---|---|
| E-U1 | 백업: 적용 전 `first` 백업 생성, `meta.json` 의 md5 가 실제 파일과 일치 | |
| E-U2 | 보관: 적용을 12번 반복(5분 throttle 해제 훅) | `first` 1개 + 최신 10개, 총 11개 |
| E-U3 | 백업 복사 실패 주입 | 로컬 불변, 결과 `code=="disk"` |
| E-J1 | 저널: pending 기록 직후 "프로세스가 죽음"(적용 훅이 중간에 예외/중단) → 새 엔진 인스턴스로 `sync_now` | 로컬 == pending.view 적용 결과, pending 비어 있음, 중복 적용해도 값 동일 |
| E-J2 | progress 쓰기 성공·studylog 쓰기 실패 주입 | 결과 `disk`, pending 남음, 다음 라운드에서 완료 |
| E-J3 | 사이드카 깨짐(`{`), `.prev` 없음, 로컬에 기록 있음 → 첫 라운드 | 처음 켜는 경우처럼 가입(or `state_lost` 규칙: `.bad`가 생겼으면 중단). `.bad` 격리 확인 |
| E-R1 | 읽기 전용(`is_read_only` true) | `local_read_only`, 아무것도 안 씀 |
| E-R2 | 녹음 중(`is_busy_ui` true) | 적용 연기(`applied==false`, `code=="busy"`) |
| E-C1 | 시계: 가짜 포트의 `now_unix` 가 허브보다 +7200 | `clock_off_sec==-7200`, 경고, 카드 시각이 허브 시각으로 올라감 |
| E-C2 | 검사기 막음(`SyncMerge.test_corrupt` 설정) | 로컬 불변, `merge_check_failed`, 백업 없음, 사이드카 불변 |
| E-H1 | `hub_id` 가 바뀜 + 허브에 복제본 있음 | 결과 `hub_changed`, 로컬 불변 |
| E-H2 | `hub_id` 가 바뀜 + 허브 비어 있음 | 새 id 채택, 자기 몫 재업로드 |
| E-B1 | 되돌리기: `restore_backup(first)` | 세 파일 MD5 == 백업 MD5, `enabled==false`, `rebase` 설정, `restore` 백업 생김, 사이드카 `own` 불변 |
| E-B2 | 되돌리기 후 다시 켬 → 라운드 | 지운 적 없는 항목이 되살아나고, 카운터 이중 계산 없음 |
| E-S1 | **스위치 끔 → 요청 0**: `choice=merge` 로 동기화한 뒤 `set_enabled(false)`; 가짜 포트의 `http_get/http_post` 호출 횟수 카운터를 0 으로 놓고 `sync_now("manual"/"poll"/"change"/"pause"/"resume")` 와 `SyncManager` 타이머를 가상 시간으로 1시간 진행 | 카운터 0, 결과 `code=="disabled"`, 로컬·사이드카 불변 |
| E-S2 | **첫 연결 선택 두 경로(폰)**: 사이드카 없음 → `needs_choice()==true`, 선택 전 `sync_now` 와 매니저 타이머 1시간 → 요청 0. (a) `set_choice("merge")` → 첫 동기화(백업 `first` 생성, 합집합) (b) `set_choice("separate")` → `enabled==false`, 요청 0 | (a)(b) 각각 새 엔진 인스턴스(재시작 흉내)에서 `needs_choice()==false` — **다시 묻지 않음** |
| E-S3 | **따로 쓰기 후 켜기 = 무손실 재합류**: 따로 쓰기 선택 뒤 폰 로컬에 공부·카드·체크 누적, PC/허브에도 별개 기록 → 스위치 켬 | 결과는 합집합: 양쪽 모든 카드·체크 존재, 카운터 = 폰 몫 + PC 몫(정확히 한 번씩), 백업 `first` 존재 |
| E-S4 | **합치기 후 껐다 켜기 재합류**: 동기화 → 스위치 끔 → 폰에서 공부 +120초·카드 삭제 1개·체크 추가 1개, PC 에서 공부 +60초·카드 추가 1개 → 스위치 켬 | 폰 몫에 +120초가 **정확히 한 번** 더해짐(이중 계산 0), 꺼진 동안 폰이 지운 카드는 되살아남(삭제 전파 안 됨), PC 의 새 카드 도착, 폰의 새 체크 도착, 어떤 항목도 사라지지 않음(켜기 전 로컬 키 ⊆ 켠 후 키, 단 PC 의 더 늦은 삭제는 예외) |
| E-S5 | PC `undecided` probe: 허브가 비어 있음 → `probe_peers()==0`, 대화상자 요청 없음; 허브에 폰 복제본 있음 → `probe_peers()==1`; probe 후 사이드카 파일이 생기지 않음 | |
| E-S6 | 선택 대화상자: `choice_needed` 신호가 폰은 첫 `READY` 에, PC 는 probe>0 일 때만 1번 발생 | |
| E-F1 | 초기화 연동: `unlink_for_reset()` | `enabled==false`, `own`·`base`·`hub_id` 비워짐, `unlink` 백업 생김, 허브의 내 복제본은 그대로 |

**왕복 `sync_roundtrip_test`** — 한 Godot 프로세스 안에서 가짜 기기 두 개("pc"=루프백, "phone"=같은 허브)를 서로 다른 `SyncPorts`(별도 사이드카·별도 로컬 데이터 홀더)로 돌리고 실제 스텁 허브와 HTTP 로 통신. 픽스처 `sync_fixtures/pc_local.json`, `phone_local.json`(아래 값 고정).
| ID | 시나리오 | 기대 |
|---|---|---|
| E-RT1 | 첫 동기화 합침: PC(카드 A,B, checks {a}, xp.en 120, day 10-17 en sec 600) / 폰(카드 B',C, checks {b}, xp.en 30, 같은 날 sec 300). 순서 PC→폰→PC | 양쪽: 카드 {A,B,C}(B 는 reps 큰 쪽), checks {a,b}, xp.en 150, sec 900. 합치기 전 파일 값은 백업에 있음 |
| E-RT2 | 연이은 공부: PC +60초, 폰 +20초 후 PC→폰→PC | 양쪽 sec 980 |
| E-RT3 | 끊김: 폰이 허브에 닿지 않을 때(`http_*` 가 `transport` 오류, 또는 허브 PID 종료) 폰이 공부 +120초, 카드 1장 추가, 체크 1개 → `sync_now` 3번 | 결과 `unreachable`, 폰 로컬 값 그대로(손실 0), 사이드카 `own` 불변 or 갱신 없음. 허브 재시작(같은 `--sync-dir`) 후 폰→PC | PC 에 +120초·카드·체크 반영 |
| E-RT4 | 동시 동기화: PC·폰 라운드를 `await` 없이 동시에 시작(코루틴 2개)해 20번 반복, 사이사이 임의의 공부/삭제(시드 고정) | 끝에 두 번 더 돌린 뒤 양쪽 `view` 동일, 어떤 카운터도 단일 기기 합보다 작지 않음, 허브 파일 전부 유효 JSON, `*.tmp` 0 |
| E-RT5 | 삭제 전파: 폰이 카드 B 를 목록에서 뺌 → 동기화 → PC 동기화 | PC 에서 B 사라짐. PC 가 B 를 다시 추가 → 폰에 돌아옴 |
| E-RT6 | 옛 PC: 서버가 `/sync/pull` 에 404 | `old_pc`, 로컬 불변 |
| E-RT7 | 서버가 망가진 응답(`{"replicas": 7}`, 비 JSON)을 줌(스텁 훅) | `bad_reply`, 로컬 불변 |
| E-RT8 | 서버가 `push` 에 409 `stale_seq` | 한 번 재시도 후 성공 |
| E-RT9 | 폰 모드 + 토큰: `-- --phone --api=… --token=…` 로 :8775 리스너에 붙는 경로(스텁 `--lan-enabled`, 훅) | 토큰 없으면 `token_missing` 계열 실패, 있으면 성공 |
| E-RT10 | 사용자 폴더 불변 | 래퍼의 MD5·목록 비교 PASS |
| E-RT11 | 실제 허브 상대: 폰 `separate` → 스텁 서버 요청 로그(스텁이 세는 `/sync/*` 호출 수)가 0 → 켬 → 합집합 재합류, 이후 PC 가 폰 기록을 받음 | 호출 수 0 확인 후 양쪽 `view` 동일 |
| E-RT12 | 스위치 끄고 켜기 왕복: E-S4 를 실제 허브·두 기기로, 끈 동안 서버 요청 로그 0 | 양쪽 카운터 합 정확, 손실 0 |

엔진 변이(`sync_engine_mutations.json`, 사본에서): ME1 백업 생략, ME2 검사 생략, ME3 저널 생략(pending 안 씀), ME4 base 를 병합 결과로 저장(적용 후 재추출 안 함 — 상한 사례에서 어긋남), ME5 `seq` 갱신 안 함, ME6 pull 전에 push, ME7 허브 시각 대신 로컬 시각 사용(E-C1), ME8 `rebase` 무시, ME9 스위치가 꺼져도 pull 수행(E-S1), ME10 `undecided` 에서 요청 전송(E-S2), ME11 재합류 때 새 기기 id 생성(E-S3/E-S4 이중 계산), ME12 `separate` 선택을 저장하지 않아 다시 물음(E-S2). 합격: 각 변이에서 지정 시험(E-U1/E-C2/E-J1/E-U2 or E-RT1/E-RT8/E-RT3/E-C1/E-B2/E-S1/E-S2/E-S4/E-S2) FAIL.

### 10.8 S7 매니저·UI (worker)
| ID | 명령 | 기대 | 판정 |
|---|---|---|---|
| UI-01 | `GODOT --headless --path ...\godot --quit` | 0 오류 | O/X |
| UI-02 | `sync_manager_test`(S7 가 작성: `godot/tests/sync_manager_test.gd/.tscn`, 가짜 엔진·가짜 시계로 타이머 규칙 검증) | `== sync_manager result: N passed, 0 failed ==`, N ≥ 20: 20초 debounce, 최소 30초 간격, 백오프 30/60/120/240/300, `READY` 복귀 시 즉시, PAUSED 시 지문 다를 때만, 진행 중 중복 요청 합침, **스위치 꺼짐/undecided 에서 모든 계기가 요청 0**, PC undecided probe 60초 주기와 선택 후 중단 | O/X |
| UI-02b | `sync_panel_test`(S7: `godot/tests/sync_panel_test.gd/.tscn`): 스위치 끔/켬이 엔진 `set_enabled` 를 부르고 끈 상태에서 '지금 동기화' 버튼이 비활성; 첫 연결 대화상자 두 버튼이 `set_choice("merge"/"separate")` 를 부르고 문구가 §6.3 과 글자 단위로 같음; 따로 쓰기 후 패널 재생성 시 대화상자 안 뜸 | `== sync_panel result: N passed, 0 failed ==`, N ≥ 10 | O/X |
| UI-03 | 회귀 `phone_layout_test`, `smoke`, `t5_wiring_test` (`--headless`) | 기준선과 같은 통과 수 | O/X |
| UI-04 | 문구 점검: `sync_panel.gd` 의 한국어 문구가 §6.3 표와 글자 단위로 같음(`grep`) | 표의 모든 문구 존재 | O/X |
| UI-05 | `today_view.gd`/`main.gd` 변경 줄 수 | `today_view.gd`: 마운트 1줄 + 초기화 문구 블록만, `main.gd`: `add_sync` 함수 + 호출 1곳. 그 밖 차이 0(`fc`) | O/X |
| UI-06 | 레이아웃 시험이 읽는 `main.tscn` 자식 장면에 `SyncManager` 가 붙지 않는다(`get_tree().current_scene == self` 조건) | `phone_layout_test` 통과로 확인 | O/X |

금지(S7): `godot/scripts/ui/*`, `godot/tests/touch_scroll_test.*` 수정 금지, `SyncEngine`/`SyncMerge` 로직 수정 금지, 폰 모드에서 PC 전용 UI 노출 금지.

### 10.9 S8 문서 (worker)
- `API.md` 에 §5 내용(두 경로, 요청/응답, 오류 코드 표, 크기 한도, Host/Origin 설명)이 있고 "휴대폰 허용 목록 23개" 문구가 25개(+ `/sync/pull`, `/sync/push`)로 갱신됐다: `Select-String -Path API.md -Pattern '/sync/pull','/sync/push','25'` 로 확인. O/X
- 금지: API.md 외 파일 수정.

### 10.10 통합(R4/오케스트레이터)
| ID | 확인 | 기대 |
|---|---|---|
| I-01 | `run_sync_tests.ps1` 전체 | `SYNC_E2E_RESULT PASS n/n`, 종료코드 0 |
| I-02 | 병합·엔진·허브 변이 시험 3종 | 변이 전부 탐지(지정 시험 FAIL), 원본 MD5 불변 |
| I-03 | 회귀 일괄: 백엔드 `test_lan.py`, `test_backend.py`; Godot `persist_test`, `study_log_test`, `fsrs_test`, `review_walk_test`, `streak_test`, `stats_view_test`, `remote_test -- --phone`, `smoke` | 기준선과 같은 통과 수 |
| I-04 | 실제 사용자 폴더 3개 파일 MD5 + `backend\data\sync` 목록, 작업 시작 전/후 | 동일 |
| I-05 | 사람 확인(오케스트레이터/사용자): 실제 폰 + PC 로 시나리오 3개(폰에서 카드 복습→PC 에서 보임, PC 에서 체크→폰에서 보임, 폰 Tailscale 끈 채 공부→켠 뒤 PC 에 보임) | 육안 확인 |

---

## 11. 위험, 대안, 하지 않는 것

### 11.1 위험과 완화
| # | 위험 | 영향 | 완화 |
|---|---|---|---|
| R1 | 오프라인 중 편집의 시각이 "연결 시각"으로 찍힘 | 같은 항목을 양쪽에서 엇갈려 바꾸면 나중에 연결한 쪽이 이김(예: 폰이 10시에 해제, PC 가 11시에 체크, 폰이 12시에 연결 → 해제가 이김) | 추가 우선(동률), 삭제는 사용자가 의도한 것. 개선안(변경 시각 기록)은 1.3 |
| R2 | 사이드카(`sync_state.json`) 분실·손상 | 몫 계산 기준이 사라져 이중 계산 가능 | 원자적 저장 + `.prev` + 백업에 사본 + 자동 가입 대신 `state_lost` 멈춤 |
| R3 | 같은 카드를 두 기기가 따로 복습 | 한쪽 FSRS 이력 일부 손실(reps 큰 쪽 채택) | 복습 횟수 통계(`n.reviews`)는 카운터라 보존. 허브 원본에도 남음 |
| R4 | 기기 시계/시간대 차이로 날짜 키가 어긋남 | 날짜별 기록이 하루 옮겨짐 | 경고 문구. 시간대 보정은 안 함 |
| R5 | 카드/아는 단어 상한 초과 | 합친 결과 일부가 이 기기에서 잘림 | `MAX_REVIEW` 3000 으로 상향, 잘리면 `trimmed` 로 보고하고 토스트. 허브 원본은 보존 |
| R6 | 같은 기록을 수동 복사해 두 기기에 넣고 첫 동기화 / 새 PC 에 새로 합치기 | 합산이라 이중 계산 | 첫 동기화 문구·백업. 되돌리기 가능. 실사용에선 드묾 |
| R7 | 허브 폴더 삭제 | 허브 복제본 소실 | 기기들이 자기 몫(누적)을 다시 올려 복구. 그 전에 기기 한 대가 사라졌다면 그 기기가 올린 몫은 복구 불가(다른 기기 로컬에는 합쳐진 값이 남아 있어 "줄어듦 검사"가 막아 줌 → 사용자 안내 필요) |
| R8 | GDScript 성능(3000 카드, 6만 단어) | 병합이 느려 UI 끊김 | 병합은 클릭 시/타이머로 1회 수백 ms 목표, M-05 로 5초 상한 측정. 느리면 단어 병합을 청크로 나눔(1.3) |
| R9 | Android 가 백그라운드에서 네트워크를 끊음 | PAUSED 시 즉시 동기화가 안 끝남 | 다음 실행에 반영(상태 기반이라 손실 없음) |
| R10 | 복제본 크기 / 8대 × 3 MiB | 응답이 큼 | `rev` 폴링으로 평소 수백 바이트, 일반 사용량은 수십~수백 KB |
| R11 | 루프백 API 를 웹 페이지가 건드림 | 기록 오염·유출 | §5.5 Host/Origin/Content-Type 검사 + 시험 T-H12 |
| R12 | 폰이 새 앱, PC 가 옛 앱 | 동기화 안 됨 | 404 → `old_pc` 안내, 로컬 영향 없음 |
| R13 | 사용자가 초기화 후 동기화를 다시 켬 | 보관함 기록이 되돌아옴(원하지 않을 수 있음) | 초기화 확인 문구에 설명, PC 보관함 폴더 삭제 방법 안내 |
| R14 | PC 앱 두 개 동시 실행 | 같은 사이드카/로컬 파일 경합 | 기존 문제. `seq` 가 허브 쪽 덮어쓰기를 막음. 해결은 이번 범위 밖 |
| R15 | `StudyLog.settle()` 이 적용 직후 토스트("보호권을 써서…")를 띄움 | 놀라움 | 정상 동작(합쳐진 공부한 날 기준 재계산). 문서화만 |
| R16 | 병합 중 `Store.changed` 로 화면이 다시 그려짐(복습 중) | 진행 중 카드 화면 깜빡임 | 복습 화면은 `status=="idle"` 일 때만 다시 그림(기존). 녹음 중 적용 연기 |
| R17 | 보호권이 기기별이라 같은 빠진 날에 두 기기가 각각 보호권을 쓸 수 있음 | 보호권이 한 개 더 줄어듦 | 사용자 결정(Q9)으로 감수. 연속 일수 자체는 합친 공부한 날로 계산되어 일치 |
| R18 | 추측: `Time.get_unix_time_from_system()` 이 폰에서 정수 초로 충분 | 영향 없음 | – |
| R19 | 추측: `OS.get_model_name()` 이 Android 에서 기기 이름을 돌려줌 | 이름이 비면 `휴대폰` | 빈 값이면 `"휴대폰"` 사용 |

### 11.2 대안과 채택하지 않은 이유
| 대안 | 내용 | 이유 |
|---|---|---|
| A. 파일 통째로 최신 우선(로드맵 원안 `updatedAt`) | 최근에 저장한 기기 파일이 이김 | 한쪽의 학습이 통째로 사라진다 → 요구 2 위반 |
| B. 서버(Python)가 병합 | 허브가 정본 하나를 갖고 병합, 기기는 변경분만 보냄 | 병합 규칙을 Python/GDScript 두 곳에서 유지하거나 Godot 쪽을 포기해야 함. 허브 버그가 정본을 오염시킴. (장점: 기기는 더 단순) |
| C. PC 의 Godot 앱이 정본 | 폰이 PC 앱에 직접 | PC 앱에 HTTP 서버가 없고, 앱이 꺼져 있으면 폰이 동기화를 못 함 |
| D. 이벤트 로그(복습 로그 재생) | 모든 공부 이벤트를 쌓고 재생 | 가장 정확하지만 기록 코드 전체를 이벤트화해야 하고 FSRS 재생에 퍼지(난수)가 있어 비결정적. 이번엔 과함 |
| E. 외부 동기화 도구(Syncthing 등) | 파일 단위 복제 | 형식 병합을 못 해 충돌 파일이 생김 |
| F. 기기별 몫을 로컬 파일 안에 저장(`StudyLog` 가 기록 때 자기 몫도 갱신) | 이중 계산을 구조적으로 제거 | `study_log.gd` 기록 함수 전부를 바꿔야 해 기존 시험(169개)과 충돌 위험. 이번엔 사이드카 차이(diff) 방식으로 기록 코드를 안 건드림 |
| G. 변경 시각을 편집 시점에 기록 | 오프라인 편집 순서를 정확히 | 모든 편집 지점(체크, 삭제 등)에 훅 필요. R1 로 감수 |

### 11.3 이번에 하지 않는 것 (이유)
- 전파되는 전체 초기화: 어느 기기에서 실수로 눌러도 모든 기기 기록이 사라지는 위험. 1.3 에서 PC 전용 + 이중 확인으로.
- 허브 쪽 병합/조회 화면: 보관함을 PC 에서 들여다보는 UI 없음.
- 허브 복제본 삭제 API(옛 폰의 몫 제거): 몫이 사라지면 합계가 줄어 "사라짐"이 되므로 의도적으로 안 만든다. 필요하면 폴더에서 수동 삭제.
- 압축/증분 전송, 푸시 알림, 인터넷 건너 동기화.
- 날짜 키의 시간대 보정, FSRS 로그 재생, 카드 리뷰 이력 병합.
- 사이드카 분실 시 자동 복구(허브 복제본으로 `own` 되살리기): 설계가 복잡해 `state_lost` 안내 + 백업 복원으로 대체.

---

## 12. 결정 완료 (사용자·오케스트레이터)

| Q | 질문 | 결정 | 문서 반영 |
|---|---|---|---|
| Q1 | 첫 동기화 방식 | **사용자 결정**: 첫 연결 때 "PC와 학습 기록을 합칠까요? / 따로 쓸까요?" 를 한 번 묻는다. 설정에 '학습 기록 동기화' 켜기/끄기 스위치(PC·폰 공통). 끄면 받기·올리기 모두 안 함(허브의 내 복제본은 남고 다시 켜면 합집합 재합류). 따로 쓰기를 고르면 다시 묻지 않음. 첫 실행 확인 단계는 S7 | D10, §4.8.1, §4.10 `choice`, §6.1·6.3·6.4, §9.2, S3·S7, E-S1~S6, E-RT11·12, ME9~ME12 |
| Q2 | `MAX_REVIEW` 상향 | 3000 으로 상향, `t5_wiring_test` 307행 수정 포함 | §4.1, S3 |
| Q3 | 공유할 설정 | 6개 그대로 | §4.1 |
| Q4 | 초기화 정책 | 이 기기만 초기화 + 연결 해제. 전 기기 초기화는 1.3 | §4.8, §11.3 |
| Q5 | 시험 포트 | `18791~18799` 사용 | §7.4, §8 |
| Q6/Q7 | 다른 작업자와 파일 겹침 | 지금 다른 작업자 없음. 이후 UI 전면 개편 예정 → S7 화면 변경은 설정 화면에 **독립 패널 `SyncPanel`**(+ 별도 대화상자 파일)과 마운트 1줄로 한정 | S7, §8 겹침 점검 |
| Q8 | 폰·PC 릴리스 태그 | 같은 태그 | – |
| Q9 | 보호권 | **사용자 결정**: 동기화하지 않고 기기별. 연속 일수는 합친 '공부한 날'로 계산 | D11, §4.6, U17·U18, MG12, R17 |
| Q10 | 실제 폰 확인 | 통합 뒤 사용자 폰으로 3개 시나리오(§10.10 I-05) + 첫 연결 선택 두 경로·스위치 끄고 켜기 | §10.10 |

---

## 부록 A. 합격 조건 요약(작업별 한 줄)

| 작업 | 통과 기준 |
|---|---|
| S1 | `SYNC_HUB_TEST_RESULT PASS ≥45`, `LAN_TEST_RESULT PASS`(기준선 동일), 허용 목록 25, 실제 폴더 불변 |
| S2 | `sync_merge` 시험 ≥90 통과 0 실패, 순수성 grep 0건, 성능 ≤5초 |
| S3 | `sync_engine` ≥40 통과, 회귀 기준선 동일, 기존 파일 변경은 지정 줄만 |
| S4 | `SYNC_E2E_RESULT PASS`, 엔진 변이 12개 탐지, 사용자 폴더 MD5·목록 불변 |
| S5 | 허브 변이 7개 탐지, 원본 MD5 불변 |
| S6 | 병합 변이 15개 탐지, 원본 MD5 불변 |
| S7 | `sync_manager` ≥20 + `sync_panel` ≥10 통과, 회귀 동일, 문구 일치 |
| S8 | API.md 에 두 경로·오류 코드·25개 반영 |
