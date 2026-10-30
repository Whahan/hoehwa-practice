# 노래로 공부하기(팝송·J-pop 가사 학습) 설계

- 작성: designer (설계만, 코드·설정 수정 없음) / 조사일: 2026-10-30 / 대상 버전: 1.4 (가칭)
- 읽은 것(코드로 확인): `backend\server.py`(`/stt` `/score` `transcribe` `decode_audio_b64` `ollama_json` `ko_ok` `ja_reading` `ja_pron` `_final_score` `/health`), `lan.py`(허용 목록·본문 한도·`LanGate`), `reading.py`(`analyze` `gloss`), `practice.py`(라우터 패턴), `features.py`(`ctc_align`), `lan_stub_server.py`, `requirements.txt`, `config.json`, `.gitignore`, `packaging\check_zip.py`, `godot\scripts\autoload\{api,route,local_api,store,recorder,tts}.gd`, `core\{study_log,kana_hangul,text_sim,progress}.gd`, `sync\sync_doc.gd`(`clean_card` `SHARED_PREFS`), `practice\{speak_drill,shadow_screen,dictation_diff}.gd`, `ui\{reading_line,list_group,sheet,ui}.gd`, `views\{practice_view,reading_view}.gd`, `main.gd`, `export_presets.cfg`, `docs\phone_standalone_design.md`(형식), `docs\android_remote_design.md`.
- 직접 확인한 환경(읽기 전용 실행): `backend\.venv`에 PyAV 17.1(인코더 `libmp3lame` `libopus` `vorbis`(내장) `aac` `flac` 있음, `libvorbis` 없음), faster-whisper 1.2.1(`WhisperModel.find_alignment` 있음), torch 2.14.1+cpu, librosa, onnxruntime 있음 / `demucs` `torchaudio` `python-multipart` `ctc_forced_aligner` 없음. 이 PC GPU: RTX 3060 Ti 8 GB. Whisper 기본 `small`(cuda, int8_float16).
- 웹 조사(문서 읽기만): LRCLIB 공식 문서(`lrclib.net/docs.md`), Godot 클래스 문서(`AudioStreamMP3`, `AudioEffectPitchShift`), Godot 4.6 안드로이드 파일 대화상자(SAF) 관련 포럼 글.
- 표기: **(추측)** = 코드·문서로 확인하지 못한 가정. **(실측 필요)** = 실제로 재야 하는 값. **(제안값)** = 합격선을 내가 정한 것(측정 후 오케스트레이터가 조정). 표기 없는 것은 확인한 사실.
- 경로: 저장소 루트 `D:\Ai\언어\app` = `<repo>`. `$PY = <repo>\backend\.venv\Scripts\python.exe`(항상 `-I`), `$GODOT = "$env:USERPROFILE\Desktop\Godot_v4.6.3-stable_win64.exe\Godot_v4.6.3-stable_win64_console.exe"`.

---

## 0. 한눈에 보기

### 0.1 결론
**가능하다. 단, "아무 노래나 정확히 받아 적는다"가 아니라 "가사가 있으면 시간을 맞추고, 없으면 초안을 만들어 사람이 고친다"로 설계한다.** 음악 위 가사 인식은 반주·멜리스마 때문에 말하기보다 훨씬 틀리므로, 자동 결과를 믿게 하지 않고 **가사 확인·시간 고치기 화면을 필수 단계**로 둔다. 합성 음성으로 얻은 정확도는 실제 노래의 상한에 가깝다(§3.4).

### 0.2 핵심 결정
| # | 결정 | 이유 |
|---|---|---|
| D1 | **무거운 처리(받아 적기·시간 맞춤·해석)는 PC 백엔드, 곡은 클라이언트(`user://songs/`)에 저장.** 서버는 곡을 보관하지 않는다(작업 폴더는 완료 확인 즉시, 늦어도 24시간 뒤 삭제). | 저작물을 서버에 쌓지 않음. 폰이 PC 없이도 복습(요구). 서버는 상태 없음 → 기존 `practice.py`처럼 라우터 모듈 하나(`backend\song.py`). |
| D2 | **가사 출처 3개는 하나의 요청 모양으로 합친다**: `lyrics.source = none \| pasted \| lrclib`. 서버는 LRC를 읽지 않는다. 클라이언트가 줄 배열(`text`, 선택 `t`)로 바꿔 보낸다. | 서버 코드 단순화, 형식 파서는 Godot 한 곳(`LrcParser`). |
| D3 | **기본 경로 = Whisper(`small`, 이미 올라온 모델) 창 단위 전사 + (가사가 있으면) 단어 서열 정렬로 앵커를 잡고 나머지는 보간.** 보컬 분리(Demucs)는 **기본 끔, v1에 설치하지 않음**. 실측(S0)이 이득을 보이면 옵션으로. 포스 얼라인먼트(`find_alignment`)는 2단계 후보. | 의존성 0 추가, 이미 로드된 모델 재사용, 취소·진행 표시가 쉬움. 근거와 실측 계획은 §3. |
| D4 | **LRCLIB는 클라이언트(PC 앱·폰)가 직접 호출**(백엔드 경유 안 함). 사용자가 "가사 찾기"를 누를 때만, 곡 1개당 요청 1~2번, `User-Agent`에 앱 이름·버전·저장소 주소. | 가사 문자열이 서버를 지나지 않음, 폰에서도 동작, 대량 수집 구조 자체가 없음(§2). |
| D5 | **업로드는 3 MiB 조각 JSON(base64)** 으로 기존 `Api.post_json` 위에서. `lan.py`·`api.gd` 한도·코드를 바꾸지 않는다(본문 16 MB 한도 안). 진행률·재개·취소 가능. | `python-multipart` 미설치, `Api`는 JSON 전용, 큰 단일 요청은 폰 회선에서 취소·재시도가 어렵다. |
| D6 | **서버가 오디오를 하나의 형식으로 정규화**: MP3 128 kbps, 44.1 kHz, 최대 스테레오(PyAV `libmp3lame`). 클라이언트에는 이 MP3만 저장. | Godot 런타임은 mp3·ogg(Vorbis)·wav만 읽는다. m4a/flac/opus 등은 못 읽음. `libvorbis`가 없고 Godot은 Opus-in-Ogg를 못 읽으므로 MP3가 유일하게 안전. 4분 ≈ 3.8 MB. |
| D7 | **재생은 `AudioStreamPlayer` + 구간 감시, 느리게는 `pitch_scale`로 속도 + `AudioEffectPitchShift`(1/속도)로 음높이 보정.** 보정 끄기 선택 제공. 서버에서 느린 버전을 미리 만들지 않는다(v1). | 파일·서버 추가 없이 가능. 보컬 위상 보코더 잡음은 **(실측 필요)**. |
| D8 | **따라 부르기는 기존 `SpeakDrill`(녹음 → `/score`)을 그대로 쓴다.** 노래는 박자가 달라 유창성(`fluency`)이 점수를 깎으므로, 서브클래스 `SongSingDrill`이 응답에서 `score = round((0.6·accuracy + 0.25·clarity) / 0.85)`로 다시 계산해 넘긴다. 음소·억양(`/prosody`)은 끈다. | `speak_drill.gd`·`server.py` 수정 0. `/score` 응답에 `accuracy` `clarity`가 있음(코드 확인). 점수는 "참고용"이라고 표시. |
| D9 | **복습 카드는 `Store.add_review`로.** 카드 필드는 기존 그대로(`target` `reading` `ko` `note`). 곡 정보는 `note`에 글로(`♪ 제목 – 가수`). 카드 스키마·동기화 문서는 바꾸지 않는다. | `SyncDoc.clean_card`는 정해진 키만 통과시킨다(코드 확인). 새 필드를 넣으면 동기화에서 버려진다. |
| D10 | **가사·음원·`song.json`은 동기화·내보내기 대상이 아니다.** 카드에 들어간 한 줄/단어 텍스트만 기존 동기화를 탄다(사용자 본인 기기 사이). | 저작물 보호. 카드는 사용자 개인 학습 기록으로 이미 동기화 중(공개 릴리스 체크리스트에서 `progress.json`은 이미 금지 목록). |
| D11 | **기존 파일 수정은 최소**: 서버는 `server.py` 4곳(import·`init`·`include_router`·`/health` 필드), `lan.py`는 `ALLOW`에 9줄. Godot은 `main.gd`(탭 등록)만. `route.gd` `api.gd` `store.gd` `study_log.gd` `speak_drill.gd`는 **수정하지 않는다.** | 병합 충돌과 회귀 최소화. `Route`는 정책 항목이 없는 경로를 PC 전용으로 다룬다(코드 확인 `decide`). |
| D12 | **폰 단독(PC 없음)에서는 곡 추가(처리)가 안 되고, 저장된 곡의 학습은 전부 된다.** 채점만 폰 STT(2단계)가 있으면 간이 채점, 없으면 `SelfRatePanel` 자가 평가(`SpeakDrill`이 이미 처리). | 사용자 확정 결정과 일치. 폰만으로 곡 추가(LRCLIB + mp3/ogg, 영어)는 후속 "폰 단독 곡 추가"(§1.2). |

### 0.3 용량·한도 한눈에
| 항목 | 값 |
|---|---|
| 업로드 파일 | ≤ 64 MiB(`MAX_SONG_BYTES`), 길이 ≤ 600 초(`MAX_SONG_SEC`) |
| 업로드 조각 | 원본 3 MiB(base64 4 MiB 남짓) — `lan.py` 본문 한도 16 MiB 안 |
| 저장 오디오(MP3 128k) | 4분 ≈ 3.8 MB, 6분 ≈ 5.8 MB |
| `song.json` | 60줄 곡 ≈ 50~100 KB **(추측)** |
| 클라이언트 한도 | 곡 40개, 오디오 합계 400 MiB (`SongStore.MAX_SONGS` `MAX_BYTES`) |
| 서버 작업 폴더 | `backend\cache\song_jobs\` (이미 `.gitignore`·`check_zip.py`가 `backend/cache/` 제외), 합계 ≤ 1 GiB, 미완료 업로드 2시간·완료 작업 24시간 뒤 삭제 |

---

## 1. 목표와 범위

### 1.1 목표
1. 사용자 음악 파일 + (가사 붙여넣기 | LRCLIB | 가사 없음) 로 **줄 시간이 맞는 곡**을 만든다(영어·일본어).
2. 학습: 줄 듣기·반복·느리게, 따라 부르기(녹음 + 발음 채점), 단어 뜻·발음기호, 줄별 한국어 해석, 일본어는 히라가나 + 한글 발음, 빈칸 채우기, 한 줄 받아쓰기, 모르는 줄·단어를 복습 카드로.
3. 처리된 곡은 폰에 저장돼 PC 없이 학습·복습.
4. 처리는 오래 걸리므로 진행 표시·취소·이어받기를 제공한다.

### 1.2 하지 않을 것
- 가사·음원을 앱·저장소·설치 파일·서버에 넣거나 올리는 것. 샘플 곡 번들 없음.
- 유튜브·스트리밍 서비스 다운로드, 링크로 음원 가져오기, DRM 해제(보호된 `.m4p` 등은 `bad_audio` 오류로 거절).
- LRCLIB **게시**(`/api/publish`), 대량 수집·미러링·검색어 자동 완성·미리 받기. 앱 코드에 `publish` 호출이 없어야 한다.
- 곡·가사의 동기화, 기기 사이 곡 전달, 공유·내보내기.
- 보컬 분리의 v1 설치, 서버가 만드는 느린 재생 파일, 가사 노래방 효과 영상, 악보·음정 채점, 억양 그래프(`/prosody`).
- 폰에서 곡 처리(전사·정렬) — 폰 단독 곡 추가는 **후속 작업**: 영어 + mp3/ogg + LRCLIB(줄 시간 있음)만으로 `song.json`을 폰이 직접 만드는 가벼운 추가. 이 설계의 `song.json`은 번역·읽기·단어 시간이 비어 있어도 열리게 만들어 두었다.
- `route.gd` `api.gd` `store.gd` `study_log.gd` `speak_drill.gd` `server.py`의 기존 동작 변경.
- 학습 통계에 "노래" 항목 신설(`StudyLog.KINDS`·`VIEWS` 변경). v1은 기존 항목에 합산(§6).

---

## 2. 저작권·약관 (필수 사항)

| # | 항목 | 결정 | 구현·검사 |
|---|---|---|---|
| L1 | 가사·음원 번들 | **없다.** 곡은 사용자가 넣은 것만 `user://songs/`에 | 저장소·APK·설치 zip에 오디오(`mp3 ogg wav m4a flac opus`)·`.lrc`·`song.json` 없음. `packaging\check_zip.py`에 `(^|/)songs/`, `song\.json$`, `\.lrc$`, `song_jobs/` 거절 패턴 추가(작업 P1). 시험용 오디오는 §9의 합성물뿐, 생성물은 `.gitignore` |
| L2 | 서버 보관 | 서버는 작업 중에만 보관. 클라이언트가 `release`하면 즉시 삭제, 아니면 24시간 | K5 합격 조건(폴더 삭제 확인). 로그에 가사 줄 원문·오디오 바이트를 쓰지 않음(표식 문자열 검색 0건) |
| L3 | 동기화·백업 | 대상 아님. `user://songs/`는 `SyncManager`가 안 읽고, `user_data_backup/allow=false`(`export_presets.cfg` 108행)라 폰 자동 백업에도 안 들어감. `song_*` prefs는 `SHARED_PREFS`에 넣지 않음 | G2 시험(`song_sync_guard_test`) |
| L4 | LRCLIB 호출 방식 | 사용자가 "가사 찾기"를 누를 때만. 곡 1개당 `GET /api/get` 1번, 없으면 `GET /api/search` 1번(최대 20건 표시). 호출 사이 ≥ 400 ms, 입력 2글자 미만이면 호출 안 함, 검색어 입력 중 자동 호출 없음. 429면 `Retry-After`(+지터 최대 30%)를 지키고 자동 재시도는 1번까지, 그 뒤에는 사용자 안내 | G3 합격 조건 + 가짜 서버 시험 |
| L5 | LRCLIB `User-Agent` | 문서: "클라이언트를 식별해야 한다"(앱 이름·버전·링크/이메일), 헤더를 못 바꾸면 `X-User-Agent` 또는 `Lrclib-Client`. 식별된 클라이언트 한도 약 90회/분, 일반 약 45회/분, 429 시 `Retry-After`. 우리 값: `HoehwaPractice/<config/version> (https://github.com/Whahan/hoehwa-practice)` 를 `User-Agent`와 `Lrclib-Client` **둘 다** 보냄. 저장소 주소는 `packaging\release.json`의 `repo` 값 | G3: 가짜 서버가 받은 두 헤더를 시험이 검사. (Godot `HTTPRequest`가 사용자 지정 `User-Agent`를 기본값 대신 쓰는지는 **실측 필요**, 안 쓰면 `Lrclib-Client`가 대신 식별) |
| L6 | LRCLIB 약관 | 문서에 이용약관·데이터 라이선스·대량 내려받기 정책 문구가 **없다**(2026-10-30 확인). 가사 저작권은 각 권리자에게 있다고 가정한다. 우리는 사용자 기기 안 개인 학습용 저장만, 재배포·게시 없음 | 화면 문구(아래) + 위 L4 |
| L7 | 출처 표시 | LRCLIB에서 받은 곡은 `song.source.attribution = "가사: LRCLIB (lrclib.net) · 개인 학습용으로만 쓰세요"` 를 학습 화면 하단과 곡 정보에 항상 표시 | UI 시험(문구 존재) |
| L8 | 외부 전송 고지 | ① LRCLIB: 검색어(제목·가수)와 곡 길이가 lrclib.net으로 나감. ② 해석·단어 뜻: 가사가 현재 AI 엔진(무료 DeepSeek via OpenCode, 또는 로컬 Ollama)으로 나감. 첫 사용 때 동의 시트를 보이고 곡마다 "해석 만들기" 끄기 제공. 로컬 Ollama를 쓰면 외부 전송 없음 | U2 합격 조건. 서버는 가사 번역 결과를 영구 캐시에 넣지 않는다(`cache_key_kind=None`). 단어 뜻은 기존 `gloss.json` 캐시를 쓰므로 가사 줄이 `backend\cache\gloss.json`(로컬·git/배포 제외)에 남을 수 있음 → 위험 R9에 기록 |
| L9 | 동의 시트 문구(첫 사용 1회, `song_consent` pref) | "내가 가진 음악과 가사를 이 기기에서 공부하는 데만 써요. 가사와 음악은 앱에 들어 있지 않고, 다른 곳에 올리거나 공유할 수 없어요. 가사 찾기는 lrclib.net에 곡 제목·가수·길이를 보내요. 해석을 만들 때 가사가 AI 서비스(현재: ○○)로 전송돼요." | U1 |
| L10 | 테스트 픽스처 | 직접 쓴 짧은 가사(영어 6줄·일본어 5줄, 파일 머리에 "직접 작성, CC0") + Kokoro 합성음 + 수식으로 만든 반주. 실존 곡 가사·녹음 금지 | K6 합격 조건: 가사 파일에 알려진 곡 문구 없음(오케스트레이터가 읽어 확인), 생성 오디오는 커밋 안 함 |
| L11 | 공개 릴리스 체크리스트 추가 | 릴리스 전 `git ls-files` 결과에서 확장자 `mp3 m4a ogg wav flac opus lrc`는 `godot\tests\fixtures\song\`의 합성 파일 외 0건, `song_jobs`·`songs` 폴더 0건. 릴리스 zip에 `check_zip.py` 통과 | P1 스크립트 `packaging\check_no_media.ps1` |

---

## 3. 음악 위 가사 인식: 정확도 위험과 기본 경로

### 3.1 방법 비교
| 후보 | 용량·의존성 | 속도(이 PC) | 라이선스 | 장점 | 약점 | 판정 |
|---|---|---|---|---|---|---|
| **A. Whisper(`small`) 단독, 창 단위** | 추가 0 | GPU 곡 길이의 약 1/10~1/20 **(추측, S0에서 실측)**, CPU 약 0.5~1× **(추측)** | MIT(기존) | 가사 없이도 됨, 단어 시각 | 반주에 약함, 노래 구간 환각(같은 구절 반복), 일본어 한자 선택이 가사와 다름 | 가사 없음 경로의 **기본** |
| B. A + 붙여넣은/LRCLIB 가사로 **서열 정렬** | 추가 0 | A와 같음 + 정렬 수 초 | - | 인식 오류가 있어도 가사 단어와 짝지을 수 있어 앵커만 맞으면 됨. 사용자가 보는 글자는 가사 그대로 | 앵커가 적으면 보간이 부정확 | 가사 있음 경로의 **기본** |
| C. 포스 얼라인먼트: `WhisperModel.find_alignment`(교차 주의 DTW)로 가사 토큰을 구간에 강제 정렬 | 추가 0(메서드는 설치돼 있음) | 창당 1회 인코딩 | - | 인식 텍스트와 무관하게 가사 시간을 얻음 | 어느 창에 어느 줄이 있는지 먼저 알아야 함(B의 앵커로 해결), 공식 API 아님(내부 메서드) | B의 보정 단계로 **2단계 후보**(S0에서 이득 입증 시) |
| D. 보컬 분리(Demucs `htdemucs` 등) 후 A/B | `demucs`+`torchaudio` 설치(수백 MB), 모델 약 80 MB **(추측)**. 이 PC torch는 **CPU 빌드**라 CPU에서 돌아감 | 4분 곡 수 분 **(추측: 곡 길이의 1~2배)** | Demucs 코드·모델 MIT로 기억함 **(확인 필요)**, 저장소 유지보수 상태 **(확인 필요)** | 반주를 줄여 인식·정렬 개선 가능 | 설치·시간·디스크, GPU 쓰려면 CUDA torch 별도(수 GB) | v1 **제외**, 옵션 후보. 대안 후보: UVR/MDX-Net ONNX(`onnxruntime` 설치돼 있음, 모델 라이선스 모델마다 다름 **(확인 필요)**) |
| E. CTC 음소 정렬(`features.ctc_align` + wav2vec2 음소 모델) | 이미 설치(1.2 GB) | 20초 창 제한(`phoneme_probs`는 20초까지) | - | 영어는 코드 재사용 | 일본어 꺼짐(`JA_ENABLED`), 20초 창 | 제외 |

### 3.2 추천: 기본 경로
```
[가사 없음]  Whisper 창 단위 전사 → 줄 만들기 → "초안" 표시 + 확인 화면 필수
[가사 있음]  Whisper 창 단위 전사(+가사 힌트) → 가사 단어와 서열 정렬 → 앵커 사이 보간 → 확인 화면
[LRCLIB 줄 시간] 가사 시간 그대로 사용 + "표본 검사"(곡의 20·50·80% 지점 30초 3곳만 전사해 전체 오프셋·불일치 판정) → 확인 화면
모든 경우: 전체 오프셋 슬라이더(±5 s), 줄 시작 지금 위치로, ±0.1 s 미세 조정을 사용자에게 준다.
```
근거: ① 추가 설치 0, ② 단어 일부만 맞아도 정렬은 된다, ③ 줄 단위 시간이면 줄 반복·빈칸·받아쓰기에 충분(단어 단위 강조는 "있으면 좋은" 기능, 추정 시간은 `est:true`로 표시해 UI가 단어 강조를 끈다), ④ 실패했을 때 사용자가 고칠 수 있다.

### 3.3 전사 설정 (K3, 시작값 — S0에서 확정)
- 창: 30초(GPU) / 20초(CPU), 경계는 목표 지점 앞 3초 안에서 에너지가 가장 낮은 50 ms 프레임. 창마다 `_stt_run_lock`을 따로 잡아 **창 사이에 `/score`가 끼어들 수 있다**(최대 한 창 대기).
- `word_timestamps=True`, `condition_on_previous_text=False`, `temperature=(0.0, 0.2, 0.4)`, `no_speech_threshold=0.5`, `compression_ratio_threshold=2.0`, `hallucination_silence_threshold=1.5`, `beam_size=5`. VAD(`vad_filter`)는 **S0에서 켬/끔 비교** 후 결정(노래 구간을 잘라낼 위험, 시작값 끔).
- 가사 힌트(`initial_prompt`): 끔 / 가사 앞 150단어 / 창별로 아직 안 맞은 다음 가사 30단어 — S0에서 비교(시작값: 창별 30단어, 추측).
- 환각 제거: 같은 줄 텍스트가 3번 이상 연속이면 첫 번째만 남기고 `warnings += hallucination_cut`; 평균 단어 확률 < 0.35이고 2단어 미만인 줄은 버림.
- 모델: 기본 설정의 `stt.model`(small)을 그대로 쓴다. `config.json`의 선택 키 `song.model`(예 `medium`)을 읽을 수 있게만 한다(없으면 기본). `config.json`에 키를 **써 넣지 않는다**(`check_zip.py`가 기본 설정과 바이트 동일을 요구).

### 3.4 정확도 한계 (솔직히)
- 합성 음성(Kokoro) + 합성 반주 시험은 **노래 특유의 음 늘림·비브라토·코러스·강한 믹싱**을 재현하지 못한다. 합격선은 "기본 경로가 최소한 이 정도는 한다"는 하한이고, 실제 곡 품질은 사용자 곡으로 하는 실곡 확인표 H1에서 숫자로 남긴다(곡은 저장소에 넣지 않음).
- 일본어는 한자·가나 표기 선택이 가사와 달라 글자 단위 정렬이 서툴다 → 정렬은 **가타카나 읽기(`ja_to_kata`) 문자열**에서 한다. 앵커 일치율이 낮으면 줄 시간만 믿고 단어 시간은 추정으로 표시.
- 힌트와 정렬이 있어도 앵커 일치율 < 0.4면 결과에 `low_match` 경고를 붙이고 UI가 "시간이 많이 틀릴 수 있어요. 줄 시간을 직접 맞춰 주세요"를 띄운다.

### 3.5 실측 계획 S0 (구현 전 스파이크, 판정은 §8 S0)
측정 스크립트 `backend\tools\song_bench.py`(K3 소유)가 K6 합성 곡으로 아래 표를 채운다. 시험 서버는 포트 18791~18799만, `--stt-cpu` 변형 포함.

| 축 | 값 |
|---|---|
| 모델 | small(기본), medium(있으면) |
| 장치 | cuda, cpu |
| SNR(음성 대 반주) | ∞, +10, +5, 0 dB |
| 가사 힌트 | 끔, 앞 150단어, 창별 30단어 |
| VAD | 끔, 켬 |
| 보컬 분리 | 끔(v1), 켬(Demucs를 임시 환경에 설치해 1회 비교, 저장소·`requirements.txt` 변경 없음) |
| 측정 | 처리 시간(곡 길이 대비 배수), 단어 오류율, 앵커 일치율, 줄 시작 오차 중앙값·p90, 단어 시작 오차 중앙값, 환각 줄 수, 반주만 입력에서의 줄 수 |

**결정 규칙**: (1) SNR +5 dB, 가사 있음에서 §8 S0-2 합격선을 만족하는 가장 단순한 설정을 기본으로 한다. (2) 보컬 분리는 SNR 0 dB 앵커 일치율을 +0.15 이상 올리고 4분 곡이 이 PC에서 곡 길이의 2배 안에 끝날 때만 "정밀 모드" 옵션 후보로 오케스트레이터에게 올린다. (3) 포스 얼라인먼트(C)는 줄 시작 오차 중앙값을 +30% 이상 개선할 때만 K2에 후속 작업으로 추가한다.

### 3.6 처리 시간·진행·취소
- 단계와 진행률 구간: `decode 0-5` → `separate 5-30`(옵션, v1은 건너뜀) → `asr 5-70` → `align 70-75` → `enrich 75-95`(읽기·해석·단어 뜻) → `package 95-100`. 전사 중에는 창 개수로, 해석 중에는 줄 묶음 개수로 `pct`와 `eta_sec`(지금까지 속도로 추정, 처음 2창 동안은 `null`)를 갱신.
- 목표(제안값, 실측 필요): 4분 곡, 이 PC GPU에서 전사·정렬 ≤ 90초, 해석·단어 뜻 포함 전체 ≤ 4분. CPU만 있는 PC는 "오래 걸려요(약 ○분)" 표시, 상한은 두지 않되 ETA 오차를 측정(±30% 이내가 목표).
- 한 번에 한 작업만 실행, 대기열 최대 3(넘으면 429 `queue_full`). 작업은 서버 스레드 `song-job`.
- 취소: `POST /song/jobs/cancel` → 상태 `cancelled`를 곧바로 응답, 스레드는 창 사이(GPU 1~3초, CPU 최대 한 창)나 해석 묶음 사이에 멈추고 작업 폴더를 지운다. 이미 시작한 LLM 호출 1건은 끝날 때까지 기다리되 결과는 버린다.
- 폰이 화면을 끄거나 앱이 내려가도 작업은 계속된다. 클라이언트는 `user://songs/_pending.json`에 `job` id를 적어 두고, 다음 실행·화면 진입 때 상태를 다시 물어 끝난 곡을 받는다. 서버 재시작으로 끊긴 작업은 `failed` + `server_restart`, 업로드는 24시간 남아 있어 같은 `upload_id`로 `POST /song/jobs`를 다시 호출하면 된다(재업로드 불필요).

---

## 4. 구조와 데이터 흐름

### 4.1 구조도
```
[Godot: PC 앱 또는 폰]                                         [PC 백엔드 (127.0.0.1:8770 / Tailscale)]
 SongView(탭) ─ SongAddScreen ─┬ SongImport.pick() 파일 선택(PC: FileDialog, 폰: DisplayServer.file_dialog_show)
                               ├ LrclibClient ───────────────HTTPS──────────────▶ lrclib.net (직접, 백엔드 안 거침)
                               └ SongTransfer ── Api.post_json /song/upload ×N ──▶ song.py (라우터)
                                       │       ── POST /song/jobs, GET /song/jobs/status(폴링)
                                       │                                         ├ song_asr.py   (창 단위 Whisper)
                                       │                                         ├ song_align.py (가사↔인식 서열 정렬, 순수 함수)
                                       │                                         └ song_enrich.py(읽기·발음·해석·단어 뜻)
                                       └ GET /song/result, GET /song/audio?part=N, POST /song/jobs/release
 SongStore ─ user://songs/<id>/{song.json, audio.mp3}   (SongModel이 읽을 때마다 정규화)
 SongCheckScreen (가사 확인·시간 고치기) → SongStudyScreen (듣기 | 따라 부르기 | 단어 | 빈칸 | 받아쓰기 | 해석)
      ├ SongPlayer(AudioStreamPlayer + Song 버스)   ├ SongSingDrill(extends SpeakDrill → /score)
      └ SongStudy(순수 로직) → Store.add_review / Store.set_known / StudyLog.add_*
```

### 4.2 곡 추가 흐름 (데이터 흐름)
1. 곡 목록 `[+ 곡 추가]` → 첫 사용이면 동의 시트(L9) → 추가 화면.
2. 파일 선택(`mp3 ogg wav m4a flac aac opus`). 클라이언트는 이름·크기만 먼저 검사(64 MiB 초과면 올리기 전에 거절).
3. 언어(영어/일본어)와 가사 출처 선택: ① "가사 없음(받아 적기)" ② "가사 붙여넣기" ③ "LRCLIB에서 찾기"(제목·가수 입력 → `LrclibClient.find`, 파일 길이로 ±2초 후보 표시). ③에서 `syncedLyrics`가 없으면 `plainLyrics`를 ②처럼 쓴다.
4. 옵션: "한국어 해석 만들기"(기본 켬), "단어 뜻 만들기"(기본 켬). `[만들기]`.
5. `SongTransfer`: 조각 업로드(진행 막대 "올리는 중 n/N") → 작업 시작 → 1.5초마다 상태 → 단계 이름·퍼센트·남은 시간·`[취소]`. `pending`에 기록.
6. 완료: 결과 JSON + 오디오 조각 내려받기 → sha256 확인 → `SongStore.install` → 서버에 `release` → **가사 확인 화면**으로 자동 이동.
7. 확인 화면에서 줄을 고치고(텍스트·시작 시간·합치기·나누기·삭제, 전체 오프셋) `[저장하고 공부하기]` → 학습 화면. 고친 줄은 `stale:true`(읽기·해석이 옛 글자 기준) 표시, PC 연결 시 "해석 다시 만들기"(`POST /song/enrich`).

### 4.3 화면 흐름
```
(PC) SideNav [노래] / (폰) 더보기 > 노래
  곡 목록 ── 곡 탭 ──▶ 학습 화면 ── 상단 ⋯ ▶ 가사 확인·수정 / 곡 삭제 / 곡 정보
     │  [+ 곡 추가] ▶ 추가 화면 ▶ 진행 화면 ▶ 가사 확인 화면 ▶ 학습 화면
     └ 사용량 "곡 3개 · 12 MB / 400 MB", 저장 위치 안내 "이 기기에만 저장돼요"
학습 화면 탭(UI.segmented): 듣기 | 따라 부르기 | 단어 | 빈칸 | 받아쓰기 | 해석
  폰은 상단 고정 재생 막대(▶ ⏮ ⏭ 반복 속도) + 아래 탭 내용, PC는 좌측 가사 목록 + 우측 탭 내용.
```
탭 등록은 `main.gd`의 `add_tab("song", "노래", SongView.new(), "노래", "reading")`. PC `NAV_LEARN`에 `song`을 `reading` 뒤에 넣고, `OWN_HEADER`에도 추가. 폰은 하단 직접 칸(4개)을 바꾸지 않고 "더보기"에 들어간다.

---

## 5. 계약 (이름·형식 고정)

### 5.1 백엔드 API (`backend\song.py`, `APIRouter`)
공통: 오류 본문 `{"error": "한국어 문장", "code": "기계가 읽는 코드"}`(`lan.py`와 같은 모양). `job`/`upload_id`는 정규식 검사 후에만 경로에 쓴다. 인증: 폰은 기존 `Authorization: Bearer hp1_…`(리스너 단위, `lan.py`), PC 앱은 루프백이라 토큰 없음. `lan.py` `ALLOW`에 아래 9개를 더한다:
`("POST","/song/upload")`, `("GET","/song/upload")`, `("POST","/song/jobs")`, `("GET","/song/jobs/status")`, `("POST","/song/jobs/cancel")`, `("GET","/song/result")`, `("GET","/song/audio")`, `("POST","/song/jobs/release")`, `("POST","/song/enrich")` — **9개**(경로에 id를 넣지 않고 쿼리로 받는 이유: `LanGate`가 `(메서드, 정확한 경로)`로만 허용을 판정). `/health`에 `"song": bool`, `"song_v": 1` 추가(옛 서버는 키 없음 → 클라이언트가 "PC 프로그램을 최신으로 업데이트해 주세요").

| 엔드포인트 | 요청 | 응답 |
|---|---|---|
| `POST /song/upload` | `{"upload_id": "<소문자 hex 32자, 클라이언트 생성>", "index": 0, "total": 5, "name": "x.m4a", "data_b64": "…"}` 조각 원본 ≤ 3 MiB | 중간: `{"upload_id", "received": 1, "bytes": 3145728}` / 마지막(`index == total-1`): `{"upload_id", "done": true, "bytes", "duration": 231.42, "format": "mp3", "sha256": "…"}` |
| `GET /song/upload?upload_id=…` | - | `{"upload_id", "next": 2, "bytes": 6291456, "done": false}` (이어 올리기용) |
| `POST /song/jobs` | `{"upload_id", "lang": "en"\|"ja", "title": "", "artist": "", "lyrics": {"source": "none"\|"pasted"\|"lrclib", "lines": [{"text": "…", "t": 12.3\|null, "p": 0}], "lrclib_id": 123\|null}, "options": {"translate": true, "gloss": true, "verify": true, "precise": false}}` | 202 `{"job": "j_8hex", "state": "queued", "queue_pos": 0}` |
| `GET /song/jobs/status?job=…` | - | `{"job", "state": "queued"\|"running"\|"done"\|"failed"\|"cancelled", "stage": "decode"\|"separate"\|"asr"\|"align"\|"enrich"\|"package"\|"", "pct": 0-100, "eta_sec": 85\|null, "message_ko": "받아 적는 중 (3/9)", "warnings": ["low_match"], "error": null\|{"code","message"}}` |
| `POST /song/jobs/cancel` | `{"job"}` | `{"ok": true, "state": "cancelled"}` (이미 끝났으면 `state` 그대로, `ok: true`) |
| `GET /song/result?job=…` | - | 완료 작업의 곡 JSON(§5.2, `id` 제외, `audio`에 `parts`·`sha256` 포함). 미완료는 409 `not_done` |
| `GET /song/audio?job=…&part=0` | - | `{"part": 0, "parts": 2, "bytes": 3145728, "data_b64": "…", "sha256": "<전체 MP3>"}` 조각 원본 ≤ 3 MiB |
| `POST /song/jobs/release` | `{"job"}` | `{"ok": true, "removed": true}` 작업·업로드 폴더 즉시 삭제 |
| `POST /song/enrich` | `{"lang", "lines": [{"i": 3, "text": "…"}] (≤ 20), "tasks": ["reading","translate","tokens","gloss"], "known": []}` | `{"lines": [{"i", "reading", "pron", "ko", "words": [{"w","lemma","level","zipf","content"}]}], "glossary": {"lemma": {"pos","ko","ipa","pron"}}, "warnings": []}`. 동기, 20줄 60초 타임아웃 |

오류 코드: 400 `bad_request`(필드·정규식·줄 수 400 초과·글자 수 20000 초과) · 400 `bad_index` · 404 `no_upload` `no_job` · 409 `upload_gap`(`expected` 포함) `job_running` `not_done` · 413 `too_large`(64 MiB) `too_long`(600초) · 415 `bad_audio`(못 읽음·오디오 없음·DRM) · 429 `queue_full` · 503 `song_unavailable`(PyAV·모델 없음) `storage_full`(작업 폴더 1 GiB 또는 디스크 여유 1 GiB 미만) · 작업 오류(`status.error.code`): `asr_failed` `no_speech` `model_missing` `server_restart` `internal`. 해석이 실패해도 작업은 `done`이고 `warnings`에 `ko_missing` `gloss_missing`.

`warnings` 값: `low_match` `no_vocals` `ko_missing` `gloss_missing` `est_times` `offset_guess` `duration_mismatch` `hallucination_cut` `lyrics_truncated`.

서버 한도 상수(`song.py` 상단): `MAX_SONG_BYTES = 64 MiB`, `MAX_SONG_SEC = 600`, `CHUNK_BYTES = 3 MiB`, `MAX_LINES = 400`, `MAX_LINE_CHARS = 200`, `MAX_LYRIC_CHARS = 20000`, `QUEUE_MAX = 3`, `UPLOAD_TTL = 2 h`, `JOB_TTL = 24 h`, `FOLDER_MAX = 1 GiB`. 시험용 환경 변수(`HOEHWA_TEST_HOOKS=1`일 때만 읽음): `HOEHWA_SONG_DIR`(작업 폴더), `HOEHWA_SONG_TTL_SEC`, `HOEHWA_SONG_FAKE_ASR=1`(가짜 전사: 시험 서버·스텁용).

### 5.2 곡 JSON (`song.json`, v1)
```json
{
 "v": 1, "id": "s_3fa9c1d20b7e", "lang": "en",
 "title": "…", "artist": "…", "created": 1790000000, "duration": 231.42,
 "audio": {"file": "audio.mp3", "bytes": 3702144, "sha256": "<64hex>", "orig_name": "x.m4a"},
 "source": {"lyrics": "asr|pasted|lrclib", "lrclib_id": null, "timing": "line|word|est",
            "attribution": "가사: LRCLIB (lrclib.net) · 개인 학습용으로만 쓰세요"},
 "offset": 0.0,
 "lines": [
  {"i": 0, "p": 0, "t0": 17.12, "t1": 20.48, "text": "I feel your breath upon my neck",
   "reading": "", "pron": "", "ko": "당신의 숨결이 내 목에 닿는 게 느껴져요",
   "conf": 0.82, "est": false, "stale": false,
   "words": [{"w": "feel", "lemma": "feel", "level": "easy", "zipf": 5.1, "s": 17.5, "e": 17.8, "est": false, "content": true}]}
 ],
 "glossary": {"breath": {"pos": "명사", "ko": "숨, 호흡", "ipa": "brɛθ", "pron": ""}},
 "marks": {"lines": [3, 7], "words": ["breath"]},
 "stats": {"plays": 3, "last": 1790000500, "best": {"3": 88}},
 "warnings": ["low_match"], "app": "1.4.0"
}
```
- `p`: 연(스탠자) 번호. `conf`: 평균 단어 확률 또는 `null`(붙여넣기/LRCLIB). `est`: 시간이 추정이면 true. `words[].s/e`는 `est:true`면 신뢰하지 않음(UI 단어 강조 끔). `offset`은 재생할 때 모든 시간에 더하는 사용자 값(−5~+5, 0.05 단위), 파일의 `t0/t1`은 서버가 준 원래 값에 사용자 미세 조정을 더한 값.
- 일본어: `reading`(히라가나), `pron`(가타카나 발음형)이 줄마다 있고 `words[]`에 `lemma`와 단어 읽기(`reading`)도 둔다. 한글 발음은 저장하지 않고 화면에서 `KanaHangul.from_pron(pron)`(없으면 `to_hangul(reading)`)으로 만든다.
- `SongModel.normalize(raw) -> Dictionary`가 읽을 때마다 보정한다: `v`가 1보다 크면 읽기 전용으로 열고 저장 금지(알 수 없는 키는 보존), 시간은 `[0, duration]`로 자르고 `t1 > t0`·줄 `t0` 오름차순 보장, 줄 ≤ 400·단어 ≤ 80·문자열 ≤ 길이 상한, 제어문자 제거, 모르는 `level`은 `mid`.

### 5.3 저장 위치·파일·용량 (`SongStore`, 정적 클래스)
```
user://songs/<id>/song.json , audio.mp3        ← id = "s_" + 12 hex (랜덤)
user://songs/_pending.json                      ← [{"job","upload_id","lang","title","t"}] (최대 5)
```
시험은 `SongStore.root = "user://test_songs_<태그>"`로 바꿔 쓴다(기본 경로 접근 금지).
```gdscript
const ROOT := "user://songs"; const MAX_SONGS := 40; const MAX_BYTES := 400 * 1024 * 1024
static var root: String = ROOT
static var last_error: String = ""        # err_code 마지막 값
static func new_id() -> String
static func list() -> Array               # [{id,title,artist,lang,duration,lines,bytes,created,last,warnings}] last 내림차순, 깨진 곡은 건너뛰고 last_error 기록
static func load_song(id: String) -> Dictionary      # 정규화된 곡, 실패 시 {}
static func save_song(song: Dictionary) -> bool      # 임시 파일 → 이름 바꾸기(원자적). v>1 곡이나 읽기 전용이면 false
static func audio_path(id: String) -> String
static func install(song: Dictionary, audio: PackedByteArray) -> Dictionary   # {ok, id, err_code}  err: quota_songs quota_bytes sha_mismatch disk_write bad_song
static func delete(id: String) -> bool
static func usage() -> Dictionary         # {songs, bytes, max_songs, max_bytes}
static func pending_list() -> Array ; pending_put(rec: Dictionary) ; pending_remove(job: String)
static func find_line_by_text(lang: String, text: String) -> Dictionary   # 후속(S6)용: {song_id, line_index} 또는 {}
```
`song.json`이 깨졌으면 `<경로>.bad`로 옮기고(최대 3개 보존, `StudyLog`와 같은 방식) 목록에서 빼며 토스트로 알린다. 오디오가 없거나 `sha256` 불일치인 곡은 `ready:false`로 목록에 보이되 학습 진입 시 "오디오 파일이 없어요 — 삭제 후 다시 추가해 주세요".

### 5.4 Godot 클래스 계약
| 클래스(파일) | 핵심 시그니처 |
|---|---|
| `LrcParser` (`core/lrc_parser.gd`, 순수) | `static func parse(text: String) -> Dictionary` → `{lines: [{t: float\|-1.0, text: String}], offset_ms: int, meta: {ar,ti,al,length}, timed: bool, words_in_line: bool}`. 지원: `[mm:ss.xx]` `[mm:ss.xxx]` `[mm:ss]`, 한 줄 여러 시간표, `[offset:±ms]`(적용해서 `t`에 반영), 메타 태그, 빈 줄(`text==""`은 간주 표시로 유지하되 `lines`에서는 `gap:true`), CRLF·BOM, `<mm:ss.xx>` 단어 태그(글자만 남기고 `words_in_line=true`). 깨진 줄은 건너뜀. `static func split_plain(text: String) -> Array` — 시간 없는 가사를 줄 배열로(연 구분 `p` 포함) |
| `LrclibClient` (`local/lrclib_client.gd`, `Node`) | `signal found(result)`; `func find(track: String, artist: String, album: String, duration: float) -> Dictionary`(코루틴: `GET /api/get`) → `{ok, kind: "exact"\|"none"\|"instrumental"\|"error", record: {id,name,trackName,artistName,albumName,duration,syncedLyrics,plainLyrics,instrumental}, err_code: "rate_limited"\|"network"\|"bad_response"\|"", retry_after: float}`; `func search(q: String, track: String, artist: String) -> Dictionary` → `{ok, items: Array(≤20, duration_diff 포함 정렬), err_code}`. 내부: 최소 호출 간격 400 ms, `HTTPRequest`를 쓰되 **`cancel_request()`를 부르지 않는다**(4.6.3에서 메인 스레드를 막는 문제, `api.gd` 주석) — 포기할 때는 결과를 버리고 완료 후 `queue_free`. 헤더 `User-Agent`·`Lrclib-Client`. 기본 주소 `https://lrclib.net`(시험은 `base_url` 변수로 `http://127.0.0.1:1879x`) |
| `SongTransfer` (`local/song_transfer.gd`, `Node`) | `signal progress(stage: String, pct: float, text: String)`, `signal finished(result: Dictionary)`; `func start(src_path: String, params: Dictionary) -> void`(조각 업로드 → 작업 → 폴링 → 결과 → 오디오 → 설치 → release), `func cancel() -> void`, `func resume(rec: Dictionary) -> void`(pending 기록으로 이어받기). 조각 재시도 3회(0.5·1·2초), 폴링 1.5초(연속 실패 5회면 `transport` 종료·pending 유지). 결과 `{ok, song_id, err_code, warnings}`. 파일은 `FileAccess`로 조각씩 읽는다(`content://` 주소도 같은 방식, 스파이크 J0) |
| `SongPlayer` (`local/song_player.gd`, `Node`) | `signal position_changed(t: float)`, `signal line_changed(i: int)`, `signal finished_loop(count: int)`; `func load_song(song: Dictionary) -> bool`; `play_from(t)`, `pause()`, `stop()`; `play_line(i, repeat: int = 1)`(`repeat==0`이면 무한); `set_speed(s)`(0.5~1.25, 프리셋 0.5·0.65·0.75·0.9·1.0); `set_keep_pitch(b)`; `position() -> float`(곡 시간, 오프셋 반영). 줄 구간 = `[t0 − 0.15, t1 + 0.25]`(곡 경계로 자름). 어댑터 `var backend: Object`로 실제 `AudioStreamPlayer`/가짜를 바꿀 수 있게 해 시험한다 |
| `SongStudy` (`core/song_study.gd`, 순수) | `static func cloze(song, line_i, level: int, seed: int) -> Dictionary` → `{prompt: String(빈칸은 "____"), blanks: [{idx, answer, alts: [], options: []}], ok: bool}`; `static func pick_unknown(song, known: Dictionary, limit: int) -> Array`(모르는 단어 후보); `static func word_card(song, lemma) -> Dictionary`와 `line_card(song, i) -> Dictionary`(`Store.add_review` 항목: `{lang, target, reading, ko, note}`); `static func dictation_score(lang, said, line) -> Dictionary`(영어 `DictationDiff.diff`, 일본어 `TextSim.similarity(said, target, reading, "ja")`) ; `static func song_score(res: Dictionary) -> int` |
| `SongSingDrill` (`song/song_sing_drill.gd`, `extends SpeakDrill`) | `apply_score(data)`를 덮어써 `data.score = SongStudy.song_score(data)`로 바꾼 뒤 `super.apply_score`. `show_prosody = false`. `listen()`은 쓰지 않는다(곡 구간은 `SongPlayer`가 재생) |
| 화면(`godot/scripts/song/`) | `SongView`(`views/song_view.gd`, `AppView`), `SongAddScreen`, `SongCheckScreen`, `SongStudyScreen` + 탭 위젯 `SongListenTab`, `SongSingTab`, `SongWordsTab`, `SongClozeTab`, `SongDictationTab`, `SongMeaningTab`. 하위 화면은 `PracticeView`처럼 `closed` 신호와 `open(lang, args)` 계약 |

카드 항목(`Store.add_review` 입력):
- 줄 카드: `{lang, target: 줄 원문(≤300), reading: 일본어 히라가나, ko: 해석, note: "♪ 제목 – 가수"}`
- 단어 카드: `{lang, target: lemma 또는 표면형, reading: 영어 IPA / 일본어 히라가나, ko: 뜻, note: "♪ 제목 · "줄 앞 40자…""}` (≤300자)

### 5.5 오디오 재생 상세
- 로드: `AudioStreamMP3.load_from_file("user://songs/<id>/audio.mp3")`(Godot 문서에 `load_from_file`·`load_from_buffer` 있음). 4.6.3 안드로이드에서 `user://` 읽기는 **실측 필요**(G5가 데스크톱 시험, 폰은 H1).
- 버스: 실행 중에 `Song` 버스를 만든다(`Recorder.ensure_record_bus`와 같은 방식) — `AudioEffectPitchShift`(`fft_size = FFT_SIZE_2048`(지연 약 46 ms), `oversampling = 4`) 하나. 속도 s: `player.pitch_scale = s`, `fx.pitch_scale = 1.0 / s`. `keep_pitch=false`면 `fx.pitch_scale = 1.0`(속도와 음높이가 같이 변함). `s == 1.0`이면 효과를 우회(`set_bus_effect_enabled(false)`).
- 구간 반복: `_process`에서 `get_playback_position() + AudioServer.get_time_since_last_mix()`가 `끝`을 넘으면 `play(시작)`으로 되돌림(한 프레임 + 믹스 버퍼 ≈ 20~50 ms 초과 허용, 합격선 ≤ 80 ms). 반복 횟수 1·3·∞.
- 단어/줄 TTS(`Tts`)를 쓰기 전에 `SongPlayer.pause()`, 녹음 시작 전에 `pause()`(마이크가 음악을 받지 않게 — 녹음 중 노래는 멈춘다). 앱이 백그라운드로 가면(`NOTIFICATION_APPLICATION_PAUSED`) 재생·녹음을 멈춘다. 이어폰 사용 여부는 감지하지 않는다.
- 음높이 보정 품질·CPU 사용은 **실측 필요**(H1), 거슬리면 사용자가 `음높이 같이 낮추기`로 바꿀 수 있고 기본값은 설정 `song_keep_pitch`(기본 true).

### 5.6 새 prefs 키 (`user://prefs.json`, 동기화 화이트리스트 밖, `Store.DEFAULT_PREFS`는 건드리지 않고 `prefs.get(key, 기본)`으로 읽음)
| 키 | 값 | 기본 |
|---|---|---|
| `song_consent` | bool(동의 시트를 봤음) | false |
| `song_speed` | 0.5~1.25 | 1.0 |
| `song_keep_pitch` | bool | true |
| `song_repeat` | 1 / 3 / 0(무한) | 1 |
| `song_translate` | bool(추가 화면 기본값) | true |
| `song_gloss` | bool | true |
| `song_last_tab` | `listen\|sing\|words\|cloze\|dictation\|meaning` | `listen` |

---

## 6. 기존 기능 재사용 지점

| 필요 | 재사용(파일·함수) | 방법 |
|---|---|---|
| 발음 채점 | `practice\speak_drill.gd` `SpeakDrill` (`make_recorder` `set_target(text, reading, ko)` `apply_score` `scored`/`silent_result`), `Api.post_json("/score")`, `ScorePanel` | `SongSingDrill`이 상속. `source = "song"`(`StudyLog.add_score`는 source를 무시) |
| 점수 기록 | `StudyLog.add_score`(SpeakDrill 안에서 자동), 줄을 통과하면(점수 ≥ 70) `StudyLog.add_event(lang, "shadow", 1)`, 빈칸 한 줄 끝내면 `"drill"`, 받아쓰기 한 줄 끝내면 `"dictation"`. 시간은 `StudyClock`이 `by.other`로 센다(`VIEWS`에 없는 화면은 `other`) | `study_log.gd` 수정 없음. 통계에 "노래"가 따로 안 나오는 것은 알려진 한계 |
| 읽기 분석·뜻 | `/reading/analyze`(`reading.analyze`)·`/reading/gloss`(`reading.gloss`) | 서버 `song_enrich.py`가 같은 모듈 함수를 호출(`readmode` 주입 객체). 클라이언트는 저장된 `words`·`glossary`를 쓰고, 고친 줄만 `POST /song/enrich` |
| 일본어 읽기·발음 | 서버 `ja_reading(text)`(히라가나), `ja_pron(text)`(가타카나 발음형) → 줄의 `reading` `pron`; 클라이언트 `ReadingLine.add(parent, reading, "ja", show_kana, 0, pron)`, `KanaHangul.from_pron/to_hangul`; 표시 설정 `show_reading` `show_hangul_ja` `show_ko` | 새 화면은 `ReadingLine`을 그대로 쓴다 |
| 영어 발음기호 | `glossary[lemma].ipa`(`reading.gloss`가 이미 줌) | 단어 시트에 표시, `Tts.speak(word, lang)` 단어 듣기 |
| 복습 카드 | `Store.add_review(items)`(중복 `lang\|target`은 건너뜀, 최대 3000), 이후 `rate_review` 등 기존 `ReviewView` | §5.4 카드 항목 |
| 아는 단어 | `Store.known_set(lang)` `Store.set_known(lang, lemmas, on)` + `save_progress()` | 단어 탭에서 "아는 단어" 표시, 빈칸에서 제외 |
| 받아쓰기 비교 | `DictationDiff.diff(said, target)`(영어), `TextSim.similarity`(일본어) | `SongStudy.dictation_score` |
| 녹음 | `Recorder`(`RecorderWidget`), 폰은 Godot 마이크, PC는 백엔드 마이크 | `SpeakDrill.make_recorder()` 그대로 |
| 폰 접속·인증 | `Api`(토큰·`base_url`), `Backend.is_ready()`/`health` | `SongTransfer`는 `Api.post_json/get_json`만 쓰고 직접 HTTP 안 함. `Backend.health.get("song", false)` |
| UI | `ListGroup`(곡 목록·설정 행), `Sheet.open/confirm/choice`(동의·삭제 확인·LRCLIB 후보 선택), `Toast`, `UI.segmented`(학습 탭), `UI.lang_segmented`, `PageHeader`, `CardBox`, `Pal`/`Ds` 토큰, `UI.touch/fit_touch`, 폰 `PhoneLayout` | 새 색·크기를 만들지 않는다 |

### 6.1 `Route.POLICY` — 폰 단독일 때
`route.gd`는 수정하지 않는다. `/song/*`은 정책 항목이 없는 경로로, `decide()`는 **PC 앱은 항상 "pc", 폰 `auto`/`pc` 모드는 "pc", 폰 `phone`(폰만) 모드는 "none"**(코드 확인). 폰 단독 결과:

| 기능 | PC 연결 | 폰 단독(PC 없음 / 폰만 모드) |
|---|---|---|
| 곡 목록·삭제·가사 확인(저장된 곡) | O | O |
| 듣기·반복·느리게·단어·빈칸·받아쓰기·해석·카드 추가 | O | O (저장된 곡 전부) |
| 따라 부르기 채점 | `/score` PC | 폰 STT(2단계 `LocalStt`)가 있으면 간이 채점, 없으면 `SelfRatePanel` 자가 평가(`SpeakDrill`이 `SelfRatePanel.needed()`로 자동 전환) |
| 단어·줄 음성(`Tts`) | PC Kokoro | 시스템 음성 |
| 곡 추가(전사·정렬·해석) | O | **X** — 추가 화면 진입 시 "곡을 만들려면 PC에 연결해야 해요(Tailscale)". 저장된 곡 학습은 막지 않음 |
| LRCLIB 가사 찾기 | O (직접 인터넷) | O (인터넷만 있으면; 곡 추가 자체는 X이므로 폰 단독 곡 추가가 생기기 전까지 쓸 곳이 없음) |
| 가사 고친 줄의 읽기·해석 다시 만들기 | O | X(줄에 "다시 만들기 필요" 표시만) |
| 진행 중 작업 이어받기 | O | PC 연결 시 |

---

## 7. 작업 분할

공통 규칙(모든 작업): "수정 허용" 파일만 고친다. 임시 파일은 `scratchpad\w_<ID>\`. 프로세스는 자기가 시작한 PID만 종료, 시험 서버는 포트 18791~18799 중 빈 곳을 확인하고 쓴다(8770·8775·8776·8862~8869 접속·사용 금지), 보고에 "남은 프로세스·열린 포트 없음". 보고 맨 앞에 합격 조건 표(항목 / O·X / 근거), 실행 안 한 항목은 "미검증". 비밀값(토큰·키·auth) 출력 금지. 사용자 폴더(`%APPDATA%\Godot\app_userdata\…`, `backend\data`, `secrets.json`)를 읽지도 쓰지도 않는다 — Godot 시험은 `user://test_*` 경로만, 파이썬 시험은 `HOEHWA_SONG_DIR`로 임시 폴더. 새 `class_name`을 만들면 `& $GODOT --headless --path <repo>\godot --import`. Godot 시험 형식: 마지막 줄 `== <이름> result: N passed, 0 failed ==`, 종료 코드 0. 파이썬 시험 형식: `== test_song: N passed, 0 failed ==`. 포트 배정: K5 18791, K3·S0 18792, K6 18793, G4 18794, G3 18797(가짜 LRCLIB), E1 18795·18796.

### 7.1 작업 표
| ID | 담당 | 내용 | 수정 허용 파일(전부, 신규 포함) | 의존 | 동시 |
|---|---|---|---|---|---|
| **K0** | 오케스트레이터 | §5 계약 확정, 결정 Q1~Q3 | 이 문서 | - | - |
| **K2** | worker-hard | `song_align.py`: 토큰 정규화·서열 정렬·앵커·보간·LRC 오프셋 추정·줄/단어 시간 만들기·ASR 단독 줄 만들기(순수 함수, 무거운 import 없음) + 황금 시험 | 신규 `backend/song_align.py`, `backend/test_song_align.py` | K0 | K3·K4·K6·G* 와 병행 |
| **K3** | worker-hard | `song_asr.py`(창 나누기·창별 Whisper·환각 제거·진행 콜백·취소 확인) + 벤치 스크립트(S0) | 신규 `backend/song_asr.py`, `backend/tools/song_bench.py`, `backend/test_song_asr.py` | K0, K2(함수 이름), K6(S0만) | K2·K4와 병행 |
| **K4** | worker | `song_enrich.py`: 줄 토큰화(`readmode.analyze` 호출), 일본어 읽기·발음, 줄 해석(묶음 12줄 + 앞뒤 문맥 2줄, `ko_ok` 검사, 실패 줄 개별 재시도 1회, 캐시 안 씀), 단어 뜻(`readmode.gloss`, 곡당 ≤ 120개) + 가짜 LLM 시험 | 신규 `backend/song_enrich.py`, `backend/test_song_enrich.py` | K0 | K2·K3와 병행 |
| **K5** | worker-hard | `song.py` 라우터·작업 관리자(업로드 조각·검사·MP3 정규화·대기열·상태·취소·삭제·TTL)·`/song/enrich`, `server.py` 연결(import·`init`·`include_router`·`/health` 필드), `lan.py` `ALLOW` 9줄, `lan_stub_server.py`에 `--song` 추가(가짜 전사), `API.md` 절 추가 | 신규 `backend/song.py`, `backend/test_song.py`; 수정 `backend/server.py`(위 4곳만), `backend/lan.py`(`ALLOW`만), `backend/lan_stub_server.py`, `API.md` | K0, K2~K4의 함수 이름(가짜로 시작 가능) | K2~K4와 병행, 합치기는 마지막 |
| **K6** | worker | 합성 곡 생성기: 직접 쓴 가사, Kokoro 합성(`/tts`), 반주 수식 합성, SNR 혼합, 형식별 인코딩, 정답 시간 `*.truth.json`, 작은 시험 mp3 | 신규 `backend/tools/make_song_fixtures.py`, 신규 `godot/tests/fixtures/song/*`(가사 텍스트·truth·아주 작은 mp3 한 개·가짜 LRCLIB 서버 `fake_lrclib.py`), `.gitignore`(`!backend/tools/make_song_fixtures.py`, `godot/tests/fixtures/song/_gen/` 두 줄만) | 시험 서버(Kokoro) 1개 | 모두와 병행(S0 전에 끝나야 함) |
| **G1** | worker | `LrcParser` + 시험 | 신규 `godot/scripts/core/lrc_parser.gd`, `godot/tests/lrc_parser_test.gd/.tscn` | K0 | 병행 |
| **G2** | worker-hard | `SongModel.normalize` + `SongStore` + 동기화 비대상 시험 | 신규 `godot/scripts/core/song_model.gd`, `godot/scripts/local/song_store.gd`, `godot/tests/song_model_test.*`, `song_store_test.*`, `song_sync_guard_test.*` | K0 | 병행 |
| **G3** | worker-hard | `LrclibClient` + 가짜 LRCLIB 서버 시험 | 신규 `godot/scripts/local/lrclib_client.gd`, `godot/tests/lrclib_client_test.*` | K0, K6(`fake_lrclib.py`) | 병행 |
| **G4** | worker-hard | `SongTransfer`(조각 업로드·폴링·내려받기·설치·release·재개·취소) | 신규 `godot/scripts/local/song_transfer.gd`, `godot/tests/song_transfer_test.*` | K5(스텁에 `--song`), G2 | K5 뒤 |
| **G5** | worker-hard | `SongPlayer`(MP3 로드, 버스, 속도·음높이 보정, 구간 반복, 가짜 어댑터) | 신규 `godot/scripts/local/song_player.gd`, `godot/tests/song_player_test.*` | K0, K6(시험 mp3) | 병행 |
| **G6** | worker | `SongStudy`(빈칸·모르는 단어·카드 항목·받아쓰기 점수·노래 점수) + `SongSingDrill` | 신규 `godot/scripts/core/song_study.gd`, `godot/scripts/song/song_sing_drill.gd`, `godot/tests/song_study_test.*` | K0 | 병행 |
| **U1** | worker-hard | `SongView`(곡 목록·빈 상태·사용량·삭제·동의 시트·PC 미연결 안내) + `main.gd` 탭 등록 | 신규 `godot/scripts/views/song_view.gd`, `godot/tests/song_view_test.*`; 수정 `godot/scripts/main.gd`(`add_tab` 한 줄, `NAV_LEARN`·`OWN_HEADER`에 `song`) | G2 | G1~G6와 병행 가능(가짜 `SongStore` 데이터로) |
| **U2** | worker-hard | `SongAddScreen`(파일 선택, 출처 3개, LRCLIB 검색·후보 선택, 옵션, 진행·취소·이어받기 UI) + `SongImport.pick()` | 신규 `godot/scripts/song/song_add_screen.gd`, `song_import.gd`, `godot/tests/song_add_test.*` | G1, G3, G4 | U3·U4와 병행 |
| **U3** | worker-hard | `SongCheckScreen`(줄 목록, 텍스트 수정, 시작 시간 지금 위치로, ±0.1 s, 합치기·나누기·삭제, 전체 오프셋, 줄 미리 듣기, 변경 취소/저장) | 신규 `godot/scripts/song/song_check_screen.gd`, `godot/tests/song_check_test.*` | G2, G5 | U2·U4와 병행 |
| **U4a** | worker-hard | `SongStudyScreen` 틀(재생 막대, 줄 목록 + 현재 줄 강조, 탭 전환) + `SongListenTab` + `SongSingTab`(`SongSingDrill`) | 신규 `godot/scripts/song/song_study_screen.gd`, `song_listen_tab.gd`, `song_sing_tab.gd`, `godot/tests/song_study_screen_test.*` | G2, G5, G6 | U4b와 병행(탭 위젯 인터페이스 고정) |
| **U4b** | worker | `SongWordsTab`, `SongClozeTab`, `SongDictationTab`, `SongMeaningTab` | 신규 `godot/scripts/song/song_words_tab.gd`, `song_cloze_tab.gd`, `song_dictation_tab.gd`, `song_meaning_tab.gd`, `godot/tests/song_tabs_test.*` | G2, G6 | U4a와 병행 |
| **E1** | worker-hard | 종단 시험: 스텁 서버(가짜 전사) + Godot `song_flow_test`(추가 → 확인 → 학습 → 카드), 실 서버 1회(합성 곡) | 신규 `godot/tests/song_flow_test.*`, `godot/tests/run_song_tests.ps1`; 실 서버 시험은 읽기·실행만 | 모든 U, K5, G4 | 마지막 |
| **P1** | worker | 릴리스 검사·문서: `check_zip.py` 패턴, `check_no_media.ps1`, `INSTALL.md`·`README.md`에 노래 기능 절과 저작권 안내 | `packaging/check_zip.py`, 신규 `packaging/check_no_media.ps1`, `INSTALL.md`, `README.md` | U* 대부분 | 마지막 |
| **J0** | worker-hard + **사용자 폰** | 스파이크: 폰에서 `DisplayServer.file_dialog_show`가 돌려준 `content://` 주소를 `FileAccess.open`·`get_length`·조각 읽기로 4 MB 파일을 끝까지 읽을 수 있는지, `AudioStreamMP3.load_from_file("user://…")` 재생, 피치 보정 소리 | 신규 `godot/tests/j0_song_probe.gd/.tscn`(저장소에는 임시 커밋 없이 보고만) | 폰 | U2 시작 전 |
| **S0** | worker-hard | §3.5 실측(합격 조건 S0) | `backend/tools/song_bench.py`(K3 소유)의 실행만, 보고서는 보고 메시지 | K3, K6 | K3 뒤 |
| **R1~R4** | reviewer | R1: 백엔드(K2~K6), R2: Godot 로직(G1~G6), R3: 화면(U1~U4b, E1), R4: 릴리스·저작권(P1) 독립 재실행 | 없음(읽기만) | 각 단계 | - |

### 7.2 의존 순서
```
K0 ─┬─ K2 ┐
    ├─ K3 ┼─ K5 ─┬─ G4 ─┐
    ├─ K4 ┘      │      ├─ U2 ┐
    ├─ K6 ───────┘ (S0)  │     │
    ├─ G1 ───────────────┤     │
    ├─ G2 ─────┬─ U1     ├─ U3 ┼─ E1 ─ P1 ─ R1~R4
    ├─ G3 ─────┘         │     │
    ├─ G5 ───────────────┴─ U4a┤
    └─ G6 ───────────────── U4b┘
J0(폰)은 U2 전에. S0은 K3+K6 뒤, 결과로 K3의 기본 설정을 확정(결과가 합격선 미달이면 접근을 오케스트레이터가 재검토).
```
파일 겹침: `server.py`·`lan.py`·`lan_stub_server.py`·`API.md`는 K5만, `main.gd`는 U1만, `.gitignore`는 K6만, `check_zip.py`는 P1만. 나머지는 모두 신규 파일이라 충돌 없음.

---

## 8. 합격 조건 (O/X)

판정은 작업자 보고가 아니라 reviewer가 아래 명령을 새로 실행해 한다. "N ≥ 값"은 최소 통과 개수. **금지 조건**은 각 표의 마지막 행.

### K2 정렬 (`test_song_align.py`)
| # | 조건 | 판정 |
|---|---|---|
| K2-1 | `& $PY -I backend\test_song_align.py` 마지막 줄 `== test_song_align: N passed, 0 failed ==`, N ≥ 40, 종료 0 | 실행 |
| K2-2 | 황금 1(영어): 정답 단어 12개 중 인식 결과에 3개 오인식·2개 누락을 섞어도 가사 단어 **앵커 일치율 ≥ 0.75**, 모든 단어 시간이 단조 증가, 매칭된 단어의 시간은 입력 인식 시간과 같음 | 시험 |
| K2-3 | 황금 2(일본어, 가타카나 정렬): 한자/가나 표기 차이(`君`↔`きみ`)가 있어도 읽기가 같으면 매칭 | 시험 |
| K2-4 | 보간: 앵커 사이의 단어는 `est:true`, 앞뒤 구간은 평균 속도로 외삽하되 `[0, duration]` 안 | 시험 |
| K2-5 | LRC 오프셋: 모든 줄이 +1.2 s 어긋난 입력 → 추정 오프셋 1.2 ±0.1, 지지 줄 5개 미만이면 0 | 시험 |
| K2-6 | **틀린 입력**: 인식 결과 빈 배열 → 예외 없이 줄 시간을 전체 길이에 비례 배분, `low_match` 경고; 가사 빈 배열 → 빈 줄 목록; 가사와 전혀 다른 인식 → 앵커 일치율 < 0.15 이고 `low_match` | 시험 |
| K2-7 | 출력 불변식(모든 시험 케이스에 자동 적용): `0 ≤ t0 < t1 ≤ duration`, 줄 `t0` 오름차순, 줄 안 단어 시간이 `[t0, t1]` 안 | 시험의 공통 검사 |
| K2-금지 | `backend` 안 다른 파일 수정 0(`git`이 없으니 전후 SHA-256 비교), `torch` `faster_whisper` `numpy` 등 무거운 모듈 import 0(표준 라이브러리만; 소스 `Select-String 'import (torch|faster_whisper|numpy)'` 0건) | 해시·검색 |

### K3 전사·벤치 (`test_song_asr.py`, S0)
| # | 조건 | 판정 |
|---|---|---|
| K3-1 | `& $PY -I backend\test_song_asr.py` N ≥ 25 통과(가짜 모델 주입: 창 나누기, 경계 선택, 시간 오프셋 더하기, 환각 제거, 취소) | 실행 |
| K3-2 | 창 경계: 90초 가짜 신호(무음 구간 포함)를 30초 창으로 나누면 마지막 창 포함 모든 샘플이 정확히 한 번 덮이고, 경계는 요청 지점 앞 3초 안 | 시험 |
| K3-3 | 취소: 취소 플래그를 켠 뒤 다음 창에 들어가기 전에 `Cancelled`가 올라오고 락이 풀려 있음(다른 스레드가 `_stt_run_lock`을 즉시 얻음) | 시험 |
| K3-4 | 환각 제거: 같은 줄 5회 연속 → 1줄 + `hallucination_cut`; 낮은 확률 1단어 줄은 버림 | 시험 |
| K3-5 | 실제 모델 1회: 시험 서버(포트 18792)에서 K6 영어 곡(SNR ∞)을 전사해 단어 오류율 ≤ 0.2 | `song_bench.py` 출력 표 |
| K3-금지 | `server.py`의 `transcribe()`·`/stt`·`/score` 동작 변경 0(수정 파일 목록에 `server.py` 없음), 창 처리에서 `_stt_run_lock`을 한 번에 한 창보다 오래 잡지 않음(시험 K3-3과 소스 검토) | 목록·시험 |

### K4 보강 (`test_song_enrich.py`)
| # | 조건 | 판정 |
|---|---|---|
| K4-1 | `& $PY -I backend\test_song_enrich.py` N ≥ 30 통과(가짜 LLM·가짜 `readmode`) | 실행 |
| K4-2 | 해석 묶음: 40줄 → LLM 호출 4번(12줄씩 + 문맥 2줄), 결과 40개가 줄 번호에 맞게 들어감 | 시험 |
| K4-3 | **틀린 입력**: LLM이 한글 없는 문장·중국어 섞인 문장·개수가 다른 배열을 주면 해당 줄만 개별 재시도 1회 후 `ko:""` + `ko_missing`, 전체 실패로 만들지 않음 | 시험 |
| K4-4 | LLM 호출 인자의 `cache_key_kind`가 `None`(가사를 영구 캐시에 안 넣음) | 시험(호출 인자 검사) |
| K4-5 | 일본어 줄: `reading`은 히라가나만, `pron`은 가타카나, 둘 다 가짜 `ja_reading`/`ja_pron` 호출 결과와 같음 | 시험 |
| K4-6 | 단어 뜻은 곡당 ≤ 120개, `level`이 `easy`인 단어와 `content:false`는 제외 | 시험 |
| K4-7 | 로그에 가사 줄 원문이 없음: 표식 문자열 `ZZSONGLINEZZ`를 가사에 넣고 로그 캡처에서 검색 0건 | 시험 |
| K4-금지 | `reading.py` `server.py` 수정 0 | 해시 |

### K5 라우터·작업 (`test_song.py`)
| # | 조건 | 판정 |
|---|---|---|
| K5-1 | `& $PY -I backend\test_song.py` N ≥ 60 통과, 종료 0 | 실행 |
| K5-2 | 조각 업로드: 7 MiB 가짜 MP3(합성 톤)를 3 MiB + 3 MiB + 1 MiB로 → 마지막 응답 `done:true`, `duration`이 실제와 ±0.05 s, `sha256`이 `Get-FileHash`와 같음 | 시험 |
| K5-3 | 순서 틀림: `index 2`를 `index 1`보다 먼저 → 409 `upload_gap` + `expected:1`. 같은 조각 재전송은 200(멱등) | 시험 |
| K5-4 | 한도: 누적 64 MiB 초과 → 413 `too_large`, 업로드 폴더 삭제. 11분 오디오 → 413 `too_long` | 시험 |
| K5-5 | **틀린 입력**: 난수 바이트를 `x.mp3`로 올림 → 415 `bad_audio`(한국어 문구), 폴더 삭제 | 시험 |
| K5-6 | 경로 위험: `upload_id`/`job`에 `../x`, 대문자, 31자 → 400, `song_jobs` 밖에 파일 생성 0 | 시험(폴더 전후 비교) |
| K5-7 | 작업 수명: 가짜 전사(`HOEHWA_SONG_FAKE_ASR=1`)로 `queued→running→done`, `pct`가 단조 증가하며 100 도달, `GET /song/result`의 `lines ≥ 1`, `GET /song/audio` 조각을 이어 붙인 MP3의 sha256이 `audio.sha256`과 같음 | 시험 |
| K5-8 | 취소: 가짜 전사가 창마다 0.5초 걸릴 때 `cancel` 후 3초 안에 `state:"cancelled"`, 작업 폴더 없음, 스레드 `song-job` 없음. 취소 뒤 `result`는 409 또는 404 | 시험 |
| K5-9 | `release` 후 폴더 없음, `status`는 404 `no_job`. TTL: `HOEHWA_SONG_TTL_SEC=1`로 시작한 서버가 다음 요청에서 오래된 폴더를 지움 | 시험 |
| K5-10 | 대기열: 작업 4개째 → 429 `queue_full`; 같은 업로드로 실행 중 작업이 있는데 또 시작 → 409 `job_running` | 시험 |
| K5-11 | LAN 게이트(스텁 `--song` + `--lan-enabled`, 포트 18791과 빈 LAN 포트): 토큰 없이 `/song/jobs/status` → 401 `token_missing`; 토큰으로 9개 경로 → 404/200 계열(403 아님); 목록에 없는 `/song/purge` → 403 `lan_forbidden` | 시험 |
| K5-12 | `/health`에 `song:true`, `song_v:1`; 기존 시험 통과 수 불변: `test_lan.py`, `test_phone_pack.py`, `test_gloss_pack.py`(변경 전 수치를 보고에 기록) | 실행 |
| K5-13 | 로그·응답에 가사 원문 없음: 표식 `ZZSONGLINEZZ` 검색 0건(서버 로그 캡처 + 상태 응답) | 시험 |
| K5-14 | 한도 상수가 §5.1 값과 같음(소스에서 `grep`) | `Select-String` |
| K5-금지 | `server.py` 수정은 import·`init`·`include_router`·`/health` 필드 외 0(전후 diff 확인), `lan.py`는 `ALLOW` 줄 외 0, `config.json`에 키를 쓰지 않음(해시 불변), 사용자 폴더·`secrets.json` 접근 0 | diff·해시 |

### K6 합성 곡 (`make_song_fixtures.py`)
| # | 조건 | 판정 |
|---|---|---|
| K6-1 | `& $PY -I backend\tools\make_song_fixtures.py --server http://127.0.0.1:18793 --out <scratch>` 종료 0, 영어·일본어 각 곡의 `*.wav` `*.mp3` `*.m4a` `*.flac`와 SNR ∞/+10/+5/0 dB 변형, `*.truth.json` 생성 | 실행·목록 |
| K6-2 | 정답 시간 검사: `truth.json`의 줄 시작/끝이 실제 합성 구간과 ±0.05 s(합성기가 구간 길이를 알고 이어 붙이므로 정확) — 파일을 `av`로 열어 길이가 `truth.duration`과 ±0.1 s | 스크립트 자체 검사 출력 |
| K6-3 | SNR 검사: 혼합 후 음성/반주 RMS 비가 요청 SNR ±0.5 dB | 출력 |
| K6-4 | 서버가 없으면 한국어/영어 메시지와 종료 ≠ 0(빈 파일을 만들지 않음) | 닫힌 포트로 실행 |
| K6-5 | 가사 파일 머리에 "직접 작성, CC0" 표기, 줄 수 영어 6·일본어 5, 알려진 노래 문구 없음(오케스트레이터가 눈으로 확인) | 파일 |
| K6-6 | 커밋 대상은 가사 텍스트·truth JSON·작은 mp3 1개(≤ 50 KB, 순음)·`fake_lrclib.py`뿐. 생성 오디오는 `_gen/`에 두고 `.gitignore` | `Get-ChildItem` 크기 합 |
| K6-금지 | 실존 곡 가사·녹음 사용 0, 사용자 폴더 접근 0, `.gitignore`는 지정한 두 줄 외 변경 0 | diff |

### G1 `LrcParser`
| # | 조건 | 판정 |
|---|---|---|
| G1-1 | `& $GODOT --headless --path D:\Ai\언어\app\godot res://tests/lrc_parser_test.tscn` 마지막 줄 `== lrc_parser_test result: N passed, 0 failed ==`, N ≥ 30 | 실행 |
| G1-2 | `[00:17.12]`·`[00:17.123]`·`[00:17]`·`[0:17.1]`(분 한 자리) 처리, 한 줄 여러 시간표 `[00:10.00][01:20.00]후렴`이 두 줄로 확장되고 시간 순서 정렬 | 시험 |
| G1-3 | `[offset:+500]`은 모든 `t`에서 0.5 s를 뺀다(일반적 관례: 양수는 가사가 더 일찍 나옴. 구현마다 부호 해석이 달라 **관례를 시험에 명시**하고, 화면의 전체 오프셋 슬라이더가 어긋남을 사용자가 고칠 수 있게 한다) | 시험 |
| G1-4 | **틀린 입력**: 빈 문자열, 시간표 없는 텍스트, `[99:99.99]`, `[ab:cd]`, 1 MB 한 줄, 널 문자 → 예외 0, `timed:false`이거나 해당 줄만 건너뜀 | 시험 |
| G1-5 | CRLF·BOM·`<00:12.30>` 단어 태그 제거 후 글자만 남음 | 시험 |
| G1-금지 | 이 파일과 자기 시험 외 수정 0 | 목록 |

### G2 `SongModel`·`SongStore`
| # | 조건 | 판정 |
|---|---|---|
| G2-1 | `song_model_test` N ≥ 30, `song_store_test` N ≥ 40, `song_sync_guard_test` N ≥ 6 모두 `0 failed` | 실행 3회 |
| G2-2 | 정규화: 시간 음수·`t1 ≤ t0`·`duration` 초과·줄 순서 뒤섞임·줄 401개·단어 81개·문자열 500자 → 규칙대로 보정, 알 수 없는 키 보존, `v:2` 곡은 읽기 전용(`save_song` false) | 시험 |
| G2-3 | 설치: 정상 곡 설치 후 `list()`에 보이고 `audio_path` 파일 크기 = `audio.bytes`; `sha256` 불일치 → `sha_mismatch`, 폴더 생성 0 | 시험 |
| G2-4 | 한도: 41번째 곡 → `quota_songs`, 합계 400 MiB 초과 → `quota_bytes`(가짜 크기 주입), 실패 시 부분 폴더 남지 않음 | 시험 |
| G2-5 | **깨진 입력**: `song.json`에 잘린 JSON → `.bad`로 이동, 목록에서 제외, 다른 곡 정상, `list()` 예외 0; 오디오 파일 없는 곡 → `ready:false` | 시험 |
| G2-6 | 원자적 저장: 저장 도중(임시 파일만 있는 상태) 읽어도 이전 `song.json` 그대로 | 시험 |
| G2-7 | 동기화 비대상: `SyncDoc`(또는 `SHARED_PREFS`·문서 키 목록)에 `songs`·`song_*`가 없음, `SyncDoc.from_progress` 결과에 가사 텍스트 표식(`ZZSONGLINEZZ`) 0건 | 시험 |
| G2-8 | pending: 6번째 기록 시 가장 오래된 것 삭제, 깨진 `_pending.json` 무시 | 시험 |
| G2-금지 | 기본 `user://songs`·`user://prefs.json`·`progress.json` 접근 0(시험이 `root`를 `user://test_songs_*`로 바꿈, 전후 파일 목록 비교), `store.gd` `progress.gd` `sync_doc.gd` 수정 0 | 목록 |

### G3 `LrclibClient`
| # | 조건 | 판정 |
|---|---|---|
| G3-1 | `lrclib_client_test` N ≥ 35 (가짜 서버 `fake_lrclib.py` 포트 18797) | 실행 |
| G3-2 | 가짜 서버가 받은 요청에 `User-Agent`(또는 `Lrclib-Client`)가 `HoehwaPractice/1.` 로 시작하고 괄호 안에 `https://github.com/Whahan/hoehwa-practice`가 있음 | 시험 |
| G3-3 | 응답 처리: 200(`syncedLyrics` 있음) → `exact`; 404 → `none`; `instrumental:true` → `instrumental`; 429 + `Retry-After: 2` → `rate_limited`, `retry_after==2`, **자동 재시도 최대 1회**; 500·연결 거부·타임아웃(10초, 시험은 1초로 단축) → `error`; 깨진 JSON → `bad_response` | 시험 |
| G3-4 | 간격: 연속 2번 호출 사이 ≥ 400 ms(가짜 서버 수신 시각 비교), 검색어 1글자 → 호출 0건 | 시험 |
| G3-5 | `duration` 차이: 파일 길이와 ±2 s 안은 `ok`, 밖은 `duration_diff` 표시용 값이 채워짐(결과를 버리지 않음) | 시험 |
| G3-6 | 소스에 `publish`·`/api/flag`·`request-challenge` 호출 없음 | `Select-String -Path godot\scripts\local\lrclib_client.gd -Pattern 'publish\|flag\|challenge'` 0건 |
| G3-7 | `cancel_request`를 호출하지 않음 | `Select-String … 'cancel_request'` 0건 |
| G3-금지 | 시험 중 실제 `lrclib.net` 접속 0(기본 주소가 시험에서 `127.0.0.1`로 바뀌어 있고, 시험이 `base_url`이 `https://lrclib.net`인 채 호출하려 하면 실패하도록 검사), 포트 8770·8775·8776 사용 0 | 시험·목록 |

### G4 `SongTransfer`
| # | 조건 | 판정 |
|---|---|---|
| G4-1 | `song_transfer_test` N ≥ 40 (스텁 서버 `lan_stub_server.py --song`, 포트 18794) | 실행 |
| G4-2 | 정상 흐름: 가짜 전사 서버로 업로드 → 완료 → 설치, `progress` 신호의 `pct`가 단조 증가, 마지막에 `finished.ok == true`, `SongStore.list()`에 1곡, 서버 쪽 작업 폴더 없음(`release` 호출됨) | 시험 |
| G4-3 | 재개: 조각 2에서 서버 연결을 끊었다 되살림 → 같은 `upload_id`로 `GET /song/upload`의 `next`부터 이어 올림(앞 조각 재전송 0) | 시험 |
| G4-4 | 취소: 업로드 중 `cancel()` → 2초 안에 `finished.ok == false, err_code=="cancelled"`, 서버 `cancel` 호출, 설치된 곡 0, 메인 스레드가 멈추지 않음(프레임 간격 < 500 ms) | 시험 |
| G4-5 | **틀린 입력**: 서버가 마지막 조각 `sha256`과 다른 MP3를 줌 → `sha_mismatch`, 설치 0; `status`가 `failed`(`no_speech`) → 한국어 안내 + 곡 설치 0; 폴링 5회 연속 `transport` → `transport` 종료 + `pending` 유지 | 시험 |
| G4-6 | 폰 단독(`Route`가 `none`): 업로드를 시작하지 않고 `err_code == "not_on_phone"`(또는 `needs_pc`), `Api.sent_count` 불변 | 시험 |
| G4-금지 | `api.gd` `route.gd` 수정 0, `Api` 직접 `HTTPRequest` 생성 0(소스 검색), 로그·토스트에 토큰 문자열 0 | 해시·검색 |

### G5 `SongPlayer`
| # | 조건 | 판정 |
|---|---|---|
| G5-1 | `song_player_test` N ≥ 35 | 실행 |
| G5-2 | 로드: 커밋된 작은 mp3를 `AudioStreamMP3.load_from_file`로 읽어 길이가 `truth` 길이와 ±0.15 s | 시험 |
| G5-3 | 속도 수식: `set_speed(0.75)` → 플레이어 `pitch_scale == 0.75`, 효과 `pitch_scale ≈ 1/0.75`(±0.001); `set_keep_pitch(false)` → 효과 1.0; 속도 1.0 → 효과 우회 | 시험 |
| G5-4 | 구간 반복(가짜 시계·어댑터): `play_line(i, 3)`이 정확히 3번 돌고 `finished_loop(3)` 1회; `repeat==0`은 `stop()`까지 계속; 시작은 `t0−0.15`(곡 시작 밖이면 0), 끝은 `t1+0.25`(곡 끝 밖이면 `duration`) | 시험 |
| G5-5 | 실제 오디오(헤드리스 더미 드라이버 가능 여부 **실측 필요**): 2초 재생 후 `position()`이 1.7~2.3 s, 속도 0.5에서 2초 뒤 0.8~1.2 s — 더미 드라이버가 시간을 안 흘리면 이 항목은 "미검증"으로 적고 H1로 넘김 | 시험 또는 미검증 |
| G5-6 | 오프셋: `song.offset = 0.5`일 때 `play_line`의 실제 시작이 `t0+0.5−0.15` | 시험 |
| G5-7 | **틀린 입력**: 오디오 없음·길이 0·깨진 mp3 → `load_song` false + 오류 문구(예외 0); 범위 밖 줄 번호 → 무시 | 시험 |
| G5-금지 | `recorder.gd` `tts.gd` 수정 0, 전역 `Master` 버스 효과 변경 0(`Song` 버스만 생성, 종료 시 정리) | 목록·시험 |

### G6 `SongStudy`·`SongSingDrill`
| # | 조건 | 판정 |
|---|---|---|
| G6-1 | `song_study_test` N ≥ 45 | 실행 |
| G6-2 | 빈칸: 같은 `seed`는 같은 결과, 난이도 1/2/3은 빈칸 1/2/3개(단어가 모자라면 가능한 만큼), 불용어·`content:false`·아는 단어는 제외, 정답에 대문자·`'` 변형 허용(`alts`) | 시험 |
| G6-3 | 일본어 빈칸: 정답 비교는 `TextSim.similarity` 기준으로 표기(한자) 또는 `reading`(히라가나) 둘 중 하나가 맞으면 정답 | 시험 |
| G6-4 | 카드 항목: `line_card`/`word_card`가 `Store.add_review`에 넣을 수 있는 모양이고, 같은 항목을 두 번 넣으면 두 번째 추가 수 0, `note`가 `♪ `로 시작·300자 이하, 카드 수 한도 처리 | 시험(`Store.progress_path`를 임시로) |
| G6-5 | `song_score`: `{accuracy:90, clarity:80, fluency:40}` → 87, `{accuracy:0, clarity:0}` → 0, 키 누락·음수·문자열 → 0~100 안으로 보정, 예외 0 | 시험 |
| G6-6 | `SongSingDrill`: `apply_score`에 위 응답을 주면 `result.score == 87`, `scored` 신호 1회, `StudyLog`에 점수 1건; 무음 응답(`transcript:""`)은 `silent_result`; `show_prosody == false`일 때 `/prosody` 호출 0 | 시험(`SpeakDrill.api_hook` 사용) |
| G6-7 | 받아쓰기: 영어 `DictationDiff.diff` 점수와 같음, 일본어 빈 문자열 → 0점 | 시험 |
| G6-금지 | `speak_drill.gd` `study_log.gd` `store.gd` 수정 0 | 해시 |

### U1~U4 화면
| # | 조건 | 판정 |
|---|---|---|
| U-1 | 시험 실행 `song_view_test`(N ≥ 25), `song_add_test`(N ≥ 35), `song_check_test`(N ≥ 35), `song_study_screen_test`(N ≥ 40), `song_tabs_test`(N ≥ 40) 모두 `0 failed` | 실행 5회 |
| U-2 | 레이아웃: `phone_layout_test`·`screens_scan_test`(기존)가 변경 전 통과 수 이상, 새 화면 PC 1280×800 / 폰 `-- --phone` 412×915에서 잘린 글자·가로 스크롤 0(기존 시험 방식으로 검사), 터치 대상 폰 ≥ `Ds.touch_min()` | 시험 |
| U-3 | `main.gd`: PC `SideNav`에 "노래"가 읽기 뒤에 있고, 폰 하단 직접 칸은 기존 4칸 그대로이며 "더보기"에 "노래"가 있음 | `song_view_test` |
| U-4 | 첫 진입 동의 시트: `song_consent=false`면 시트가 뜨고 문구에 "lrclib.net"과 "AI 서비스"가 포함, "동의" 전에는 추가 화면 진입 불가, 동의하면 `song_consent==true` 저장 | 시험 |
| U-5 | PC 미연결(폰 `phone` 모드 또는 `Backend`가 준비 안 됨)에서 `[+ 곡 추가]` → 안내 문구, `Api.sent_count` 불변; 저장된 곡 열기는 가능 | 시험 |
| U-6 | 추가 화면: 파일 64 MiB 초과 → 올리기 전 거절(`Api.sent_count` 불변); 길이 > 600초 안내; 가사 붙여넣기 401줄 → "400줄까지" 안내; LRCLIB 검색은 버튼을 눌러야만 호출(`LrclibClient` 호출 수 0 → 버튼 → 1) | 시험 |
| U-7 | 진행 화면: 단계 이름·퍼센트·남은 시간 표시, `[취소]`가 눌리면 `SongTransfer.cancel()` 호출, 화면을 나갔다 오면 `pending`에서 이어받기 | 시험 |
| U-8 | 확인 화면: 줄 텍스트 수정·합치기·나누기·삭제·"지금 위치로 시작"·±0.1 s·전체 오프셋 후 저장 → `song.json`이 규칙대로 바뀌고(`t0` 오름차순 유지, 합친 줄의 `est:true`), `[변경 취소]`는 저장 전 상태로 되돌림; 고친 줄은 `stale:true` | 시험 |
| U-9 | 학습 화면 듣기: 줄 탭 → `SongPlayer.play_line`, 현재 줄 강조가 재생 위치를 따라 바뀜, 속도 칩·반복(1·3·∞)이 `SongPlayer`에 전달, `est:true`인 곡은 단어 강조가 꺼져 있음 | 시험(가짜 플레이어) |
| U-10 | 따라 부르기: 줄 선택 → 녹음 → (`api_hook`) 채점 결과 표시, 녹음 시작 직전 `SongPlayer.pause()` 호출, 통과(≥ 70) 시 `StudyLog` `shadow` 이벤트 +1; PC 없음/`SelfRatePanel` 상태에서 `/score` 호출 0 | 시험 |
| U-11 | 단어 탭: 모르는 단어(아는 단어 제외) 목록, 단어 탭하면 뜻·IPA(영어)/히라가나+한글(일본어)·단어 듣기, `[복습에 추가]` → `Store.add_review` 1건, 같은 단어 재추가는 0건, `[아는 단어]` → `Store.is_known` true | 시험 |
| U-12 | 빈칸·받아쓰기: 한 줄 끝낼 때 정답/오답 표시, 모두 끝내면 요약, 틀린 줄/단어 `[복습에 추가]`, 받아쓰기는 줄 듣기 → 입력 → 비교; 일본어 받아쓰기는 `TextSim` 기준 | 시험 |
| U-13 | 해석 탭: `ko`가 비어 있으면 "해석이 아직 없어요"와 (PC 연결 시) `[다시 만들기]`, 일본어는 히라가나 + 한글 발음 표시(설정 `show_reading` `show_hangul_ja` 반영) | 시험 |
| U-14 | LRCLIB 출처 곡은 학습 화면 하단에 `attribution` 문구가 항상 보임 | 시험 |
| U-금지 | 이 표 밖 기존 파일 수정 0(`main.gd` 외), 새 색·폰트 크기 직접 지정 0(`Pal`/`Ds` 토큰만 — `contrast_test`·`a11y_sweep_test` 통과 수 불변), 사용자 폴더 접근 0 | 목록·시험 |

### J0 폰 스파이크 (go/no-go, 사용자 폰)
| # | 조건 | 판정 |
|---|---|---|
| J0-1 | 파일 선택 → 돌려받은 주소로 `FileAccess.open(…, READ)`가 성공하고 `get_length()`가 실제 크기와 같으며 3 MiB씩 끝까지 읽은 합이 같음(4 MB mp3 하나) | 폰 로그 |
| J0-2 | `AudioStreamMP3.load_from_file("user://j0.mp3")` 재생 소리 남, 속도 0.75 + 보정에서 소리가 끊기거나 갈라지지 않음(사용자 청취 O/X) | 폰 |
| J0-3 | 실패 시 보고: 오류 코드와 대안(읽기 권한 `READ_MEDIA_AUDIO` 추가, 음악 폴더 목록) — 결정은 오케스트레이터(Q2) | 보고 |

### S0 실측 (벤치)
| # | 조건 | 판정 |
|---|---|---|
| S0-1 | §3.5 표가 모두 채워진 보고(조합마다 처리 시간·오류율·앵커 일치율·줄 시작 오차) | 보고 |
| S0-2 (**제안값**) | 영어·일본어 각각 SNR +5 dB, 가사 있음, 기본 설정(small, GPU): 앵커 일치율 ≥ 0.85, 줄 시작 오차 중앙값 ≤ 0.35 s, p90 ≤ 1.0 s | 표 |
| S0-3 (**제안값**) | 가사 없음 SNR +5 dB: 단어 오류율 ≤ 0.25(영어), 글자 오류율 ≤ 0.30(일본어) | 표 |
| S0-4 | 반주만(보컬 없음) 입력: 만들어진 줄 ≤ 1, 경고 `no_vocals` | 표 |
| S0-5 (**제안값**) | 4분 곡 GPU 전사·정렬 ≤ 90 s, CPU(`--stt-cpu`)는 측정만 | 표 |
| S0-6 | 미달 시 접근을 오케스트레이터가 재검토(합격선 조정이 아니라 방법 변경 후보: `find_alignment` 추가, 모델 상향, 보컬 분리 옵션) | 보고 |

### E1 종단
| # | 조건 | 판정 |
|---|---|---|
| E1-1 | `powershell -NoProfile -ExecutionPolicy Bypass -File godot\tests\run_song_tests.ps1` 마지막 줄 `SONG_E2E_RESULT PASS`, 종료 0. 러너는 스텁 서버를 빈 포트에서 띄우고, `APPDATA`를 작업 폴더로 돌려 사용자 폴더 불변(전후 파일 목록·`md5` 비교), 끝나면 자기 PID만 종료·포트 해제 확인 | 실행 |
| E1-2 | `song_flow_test`: 영어 곡(가사 붙여넣기) 추가 → 확인 화면에서 한 줄 고침 → 학습 화면에서 줄 반복·단어 카드 추가·빈칸 1문제 → 복습 목록에 카드 ≥ 1 | 시험 |
| E1-3 | 일본어 곡(가사 없음 경로, 가짜 전사)에서 `reading`·`pron`·한글 발음 표시 | 시험 |
| E1-4 | **실 서버 1회**(오케스트레이터가 포트 18792에 띄운 시험 서버, 실제 Whisper): K6 영어 곡 SNR +5 dB를 가사 붙여넣기로 처리 → 앵커 일치율·줄 오차가 S0-2 이내, 폰 모드(`-- --phone`)에서도 같은 흐름이 PC 연결 상태로 성공 | 실행·보고 |
| E1-5 | 종료 후 `user://test_*` 외 파일 변화 0, 서버 작업 폴더 비어 있음 | 목록 |
| E1-금지 | 포트 8770·8775·8776 접속 0, 실제 `lrclib.net` 접속 0 | 러너 로그 |

### P1 릴리스 검사
| # | 조건 | 판정 |
|---|---|---|
| P1-1 | `check_zip.py`에 새 패턴 추가 후, 일부러 `songs/x/song.json`·`a.lrc`·`backend/cache/song_jobs/x` 를 넣은 가짜 zip은 종료 1, 정상 zip(기존 시험 zip)은 종료 0 | 가짜 zip 3개 + 기존 zip |
| P1-2 | `packaging\check_no_media.ps1`: 저장소에서 허용 목록(`godot/tests/fixtures/song/` 안 합성 파일) 외 `mp3 m4a ogg wav flac opus lrc`와 `song.json`이 있으면 종료 1. 일부러 하나를 만들어 1이 나오는지 확인(그 파일은 즉시 삭제) | 실행 |
| P1-3 | `INSTALL.md` `README.md`에 "가사·음원은 앱에 없음 / 내 파일만 / 이 기기에만 저장 / LRCLIB 출처" 문구 | `Select-String` |
| P1-금지 | `check_zip.py`의 기존 패턴 삭제·완화 0 | diff |

---

## 9. 시험 방법

### 9.1 실제 노래 없이
- **합성 곡**(K6): 직접 쓴 짧은 가사 → Kokoro(`/tts`, 영어 `af_heart`, 일본어 `jf_alpha`)로 줄마다 합성 → 줄 사이 0.4~1.5초 간격으로 이어 붙임(구간 길이를 알므로 정답 시간이 정확) → 반주를 수식으로 합성(4코드 진행의 화음 패드 + 노이즈 타악, 템포 90) → SNR ∞/+10/+5/0 dB로 섞음 → `av`로 `wav` `mp3` `m4a` `flac` `ogg(vorbis 내장)` 인코딩. 4분짜리가 필요하면 같은 줄을 반복해 늘리고 정답 시간도 같이 늘림(S0 시간 측정용).
- 한계(§3.4)를 문서와 보고에 적는다. 실제 노래 확인은 사용자 곡으로 H1 한 번(곡 이름·가사는 어디에도 적지 않고 숫자·O/X만).
- 단위 시험은 서버 없이: 가짜 모델/가짜 LLM/`HOEHWA_SONG_FAKE_ASR=1`. Godot는 가짜 `SongPlayer` 어댑터·가짜 `Api` 훅(`SpeakDrill.api_hook`).
- 가짜 LRCLIB: `godot\tests\fixtures\song\fake_lrclib.py`(포트 18797, `User-Agent` 에코·429·지연 시나리오 포함).

### 9.2 포트·폴더
- 시험 서버 포트 18791~18799만(§7 배정). 8770·8775·8776과 안드로이드 연결용 포트에는 접속하지 않는다.
- 파이썬: `HOEHWA_TEST_HOOKS=1 HOEHWA_SONG_DIR=<scratch>`. Godot: `SongStore.root = "user://test_songs_<태그>"`, `Store.apply_test_guard`가 이미 prefs·progress를 `user://test_guard`로 돌림.

### 9.3 실기(사용자 폰·PC) 확인표
| 표 | 내용 |
|---|---|
| H1 | 사용자 곡 1~2개(영어·일본어)로 실제 처리: 앵커 일치율·경고·처리 시간(PC GPU)·줄 오차 체감, 피치 보정 소리 품질(0.75×), 줄 반복 경계 끊김 |
| H2 | 폰: 파일 선택(J0), 업로드 중 화면 끄기 → 돌아와 이어받기, Tailscale 끊김/복구, 비행기 모드에서 저장된 곡 학습 |
| H3 | 폰 마이크: 노래 구간 멈춘 뒤 녹음 → 채점, 이어폰 유무 차이 |
| H4 | LRCLIB 검색: 실제 곡 1개로 `get` 1번(제목·가수·길이), 결과 확인(과도한 반복 호출 안 함) |

---

## 10. 위험 요소와 대안

| # | 위험 | 영향 | 대응·대안 |
|---|---|---|---|
| R1 | 노래 위 전사가 부정확(환각·누락·일본어 표기 차이) | 가사/시간 오류 | 확인·수정 화면 필수, `low_match`·`conf` 표시, 가사 붙여넣기/LRCLIB 권장, S0 결정 규칙, 보컬 분리·`find_alignment`는 실측 근거로 단계 추가 |
| R2 | LRCLIB 곡 버전(리마스터·라이브)이 내 파일과 달라 시간이 어긋남 | 줄 시간 틀림 | 길이 ±2초 후보 표시, 표본 검사 `verify`(20·50·80% 지점), 전체 오프셋 슬라이더, 줄별 "지금 위치로" |
| R3 | 긴 곡 처리 시간·GPU/CPU 경쟁(`/score`가 전사에 막힘) | 대기 | 창 단위 락, CPU는 20초 창·ETA·취소, 한 번에 한 작업, 대기열 3 |
| R4 | 폰 파일 선택이 `content://`로 막힘(Godot 4.6 SAF) | 폰에서 곡 추가 불가 | J0 스파이크(`FileAccess`로 읽힌다는 포럼 보고 있음, 확인 안 됨). 대안: `READ_MEDIA_AUDIO` 권한 추가(APK 권한 3개 → 4개, 승인 필요 Q2), PC 앱에서만 추가 |
| R5 | 피치 보정(`AudioEffectPitchShift`) 음질·CPU | 느리게 듣기 품질 | `fft_size` 2048/4096 비교(H1), 끄기 옵션, 후속: 서버가 느린 파일 생성 |
| R6 | MP3 구간 이음매(Godot 디코더 지연 ≈ 25~50 ms **(추측)**) | 줄 시작이 약간 어긋남 | 줄 구간에 −0.15/+0.25초 여유, 전체 오프셋 |
| R7 | 동기화·백업으로 저작물이 샘 | 법적 | L3 시험, `song_*` prefs 비화이트리스트, 카드는 한 줄/단어 텍스트뿐 |
| R8 | 서버 작업 폴더에 남은 음원 | 법적·용량 | `release` 즉시 삭제, TTL 24시간, 폴더 1 GiB 상한, 시작 시 청소, `.gitignore`·`check_zip.py` 이미 제외 |
| R9 | 가사 줄이 AI 서비스·`gloss.json` 캐시로 흘러감 | 개인정보·저작권 | 동의 시트(L9), 번역은 영구 캐시 끔, 곡별 해석 끄기, 로컬 Ollama면 외부 전송 0. `gloss.json`에 줄이 남는 것은 로컬(git·배포 제외)임을 INSTALL에 적음 |
| R10 | `lan.py` 본문 한도·타임아웃(120초)에 걸리는 업로드 | 업로드 실패 | 3 MiB 조각(조각당 수 초), 조각 재시도, 이어 올리기 |
| R11 | PyAV가 일부 코덱을 못 읽음(m4p DRM, 특이 opus) | 추가 실패 | `bad_audio` 한국어 안내 "다른 형식(mp3)으로 바꿔서 다시 시도", 시험 형식 목록으로 확인 |
| R12 | `Api` 폴링·업로드가 `FALLBACK`/재시도 로직과 얽힘 | 중복 요청 | `/song/*`은 `IDEMPOTENT_POST`에 없음 → `Api` 자동 재시도 없음, 재시도는 `SongTransfer`가 조각 단위(멱등)로만 |
| R13 | 마이크가 스피커 음악을 받아 채점 오염 | 점수 왜곡 | 녹음 중 재생 정지(설계), 카운트인 없음, H3 확인 |
| R14 | 노래 채점의 신뢰도(박자·음 늘림) | 오해 | "노래 점수는 참고용" 상시 표시, 유창성 제외 점수(D8), 통과선 70 유지 |
| R15 | Demucs 등 후속 의존성의 크기·라이선스 | 설치 부담 | v1 제외, 설치 시 `setup.ps1` 선택 단계와 별도 설계 |
| R16 | 폰 저장 공간 | 용량 | 곡 40개/400 MiB 상한, 사용량 표시, 삭제 쉬움. `DirAccess.get_space_left()`는 안드로이드에서 신뢰하지 않음 **(추측)** |

---

## 11. 일부러 틀린 입력으로 확인할 실패 시나리오

| # | 입력 | 기대 결과 |
|---|---|---|
| F1 | 난수 바이트를 `x.mp3`로 업로드 | 415 `bad_audio`, 한국어 문구, 서버 폴더 삭제, 클라이언트는 곡 0개 설치 |
| F2 | 70 MiB 파일 / 11분 파일 | 클라이언트가 올리기 전에 거절; 서버 직접 호출 시 413 `too_large`/`too_long` |
| F3 | 조각 순서 바꿔 전송, 같은 조각 두 번 | 409 `upload_gap`+`expected` / 두 번째는 200(멱등) |
| F4 | `job=../../x`, 대문자 id | 400, 폴더 밖 쓰기 0 |
| F5 | 반주만 있는 파일(보컬 없음) + 가사 없음 | `no_vocals` 경고, 줄 ≤ 1, 환각 줄 없음 |
| F6 | 가사와 전혀 다른 노래를 붙여넣기 | 앵커 일치율 < 0.15, `low_match`, 모든 시간 `est:true`, 확인 화면 배너 |
| F7 | 모든 줄이 1.2초 어긋난 LRCLIB 가사 | `offset_guess` ≈ 1.2 적용 또는(지지 줄 부족 시) 0 + 경고; 사용자가 슬라이더로 고침 |
| F8 | LRC에 `[99:99.99]`, 시간표 없는 텍스트, 1 MB 한 줄 | 파서 예외 0, 해당 줄만 건너뜀/`timed:false` |
| F9 | LRCLIB 429 + `Retry-After`, 500, 연결 거부, 깨진 JSON | 각각 `rate_limited`(재시도 ≤ 1) / `error` / `network` / `bad_response`, 앱 크래시 0 |
| F10 | LRCLIB 검색어 1글자·빈 문자열 | 호출 0건 |
| F11 | AI가 한글 없는 번역·개수 다른 배열을 줌 | 해당 줄만 재시도 1회 후 `ko:""`, `ko_missing` 경고, 곡은 `done` |
| F12 | 업로드 중 연결 끊김 | 같은 `upload_id`로 이어 올림, 앞 조각 재전송 0 |
| F13 | 작업 중 서버 재시작 | 상태 `failed`+`server_restart`, 같은 `upload_id`로 재시작 가능 |
| F14 | 작업 중 취소 | 3초 안 `cancelled`, 작업 폴더·스레드 정리 |
| F15 | 내려받은 MP3 한 바이트 변조 | `sha_mismatch`, 설치 0, 서버 `release` 안 함(재시도 가능) |
| F16 | `song.json` 중간 잘림 / 오디오 파일 삭제 | `.bad`로 이동·목록 제외 / `ready:false` 안내, 다른 곡 정상 |
| F17 | `song.json`의 `v:2`, 시간 음수, 줄 순서 뒤섞임 | 읽기 전용으로 열기 / 보정 후 열기 |
| F18 | 41번째 곡, 합계 400 MiB 초과 | `quota_songs`/`quota_bytes`, 부분 폴더 0 |
| F19 | 폰 `phone` 모드에서 곡 추가 | 안내 문구, 요청 0건, 저장된 곡 학습은 정상 |
| F20 | 같은 단어/줄 카드를 두 번 추가 | 두 번째 0건 |
| F21 | 녹음이 무음 | `SpeakDrill` 기존 "소리가 들리지 않았어요" |
| F22 | 앱 백그라운드 전환 중 재생/녹음 | 재생·녹음 정지, 돌아오면 정상, 소리 겹침 0 |

---

## 12. 오케스트레이터가 정할 것

### 12.1 사용자에게 물을 결정 (3개, 추천 포함)
| Q | 질문 | 추천 |
|---|---|---|
| Q1 | **보컬 분리(Demucs 등)를 v1에 넣을까요?** 넣으면 반주가 큰 곡의 인식·정렬이 좋아질 수 있지만 설치(수백 MB~수 GB, 현재 torch는 CPU 빌드), 처리 시간(곡 길이의 1~2배 **추측**), 라이선스 확인이 늘어납니다. | **넣지 않는다.** S0 측정에서 SNR 0 dB 앵커 일치율이 +0.15 이상 오르고 시간이 허용될 때 "정밀 모드" 옵션으로 별도 승인 |
| Q2 | **폰에서 파일 선택이 안 되면(J0 실패) 읽기 권한(`READ_MEDIA_AUDIO`)을 추가해 음악 폴더 목록에서 고르게 할까요?** 지금 APK 권한은 3개(인터넷·네트워크 상태·녹음)이고 권한을 추가하면 설치 때 보이는 목록이 늘어납니다. | **J0에서 파일 대화상자가 되면 추가하지 않는다.** 안 될 때만 권한 추가 승인, 그동안 폰 곡 추가는 보류하고 PC 앱에서만 추가 |
| Q3 | **한국어 해석·단어 뜻을 만들 때 가사가 현재 AI 서비스(무료 DeepSeek via OpenCode)로 전송되는 것을 허용할까요?** 첫 사용 때 동의 시트로 알리고 곡마다 끌 수 있습니다. 로컬 Ollama를 쓰면 외부 전송이 없습니다. | **허용 + 동의 시트 + 곡별 끄기.** 외부 전송이 싫은 사용자는 해석을 끄거나 로컬 AI를 쓰게 안내 |

### 12.1a 사용자 결정 (2026-10-30)
- Q1 보컬 분리: **v1에 넣지 않음**(추천대로). S0 결과가 기준을 넘으면 "정밀 모드"로 따로 물음.
- Q2 폰 읽기 권한: **추가하지 않음**. J0에서 권한 없이 파일 대화상자로 4 MB를 읽을 수 있으면 그대로 진행. 안 되면 폰은 곡 추가를 하지 않고, **PC에서 추가한 곡을 PC 연결로 폰에 내려받는 경로**(후속 작업 K7/G7, 오케스트레이터가 J0 결과 뒤 설계)로 대신함.
- Q3 AI 전송: **허용, 첫 사용 때 동의 시트로 알리고 곡마다 끌 수 있게**(추천대로). 로컬 Ollama 사용 시 외부 전송 없음을 시트에 표시.
- 작업자: Haiku 작업자(`worker`)는 폐지됨 — §7 표의 `worker` 담당은 모두 `worker-hard`가 맡음.

### 12.2 기본값으로 진행해도 되는 작은 결정 (반대할 때만 알려 주세요)
| # | 결정 | 기본 |
|---|---|---|
| S1 | 곡 한도 | 40곡 / 400 MiB |
| S2 | 서버 작업 보관 | 완료 후 24시간, `release`하면 즉시 삭제 |
| S3 | 노래 탭 위치 | PC 사이드바 "읽기" 다음, 폰은 "더보기" 안 |
| S4 | 전사 모델 | 설정의 `stt.model`(현재 small) 재사용, `medium`은 설정 키로만 |
| S5 | 노래 학습 시간·횟수의 통계 | v1은 기존 항목에 합산(연습: `shadow`/`drill`/`dictation`, 시간은 `other`). "노래" 별도 통계는 `study_log.gd`·`stats_view.gd` 변경이 필요해 후속 |
| S6 | 카드 → 곡 연결 | v1은 `note` 텍스트만. 후속: `SongStore.find_line_by_text`로 복습 화면에서 "♪ 노래에서 듣기" |
| S7 | 느린 재생 | 실시간 피치 보정. 서버가 만든 느린 파일은 후속 |
| S8 | 폰 단독 곡 추가 | 후속(영어 + mp3/ogg + LRCLIB 줄 시간) |
| S9 | `/score`에 `sung` 옵션 추가(서버에서 유창성 제외) | 하지 않음, 클라이언트 재계산(D8) |

---

## 부록 A. 추측·미확인 목록 (착수 전에 검증)
1. Whisper `small`의 GPU/CPU 처리 속도와 노래 구간 정확도(S0).
2. Godot `HTTPRequest`가 사용자 지정 `User-Agent`를 기본값 대신 보내는지(G3 시험으로 확인, 아니면 `Lrclib-Client`가 식별).
3. 폰에서 `DisplayServer.file_dialog_show`가 준 `content://` 주소를 `FileAccess`로 읽을 수 있는지(J0). 포럼 글은 "파일을 열어 크기는 확인했다"고만 함.
4. 헤드리스 더미 오디오 드라이버가 재생 시간을 실제로 흘리는지(G5-5).
5. `AudioEffectPitchShift` 보컬 음질·폰 CPU 사용량(H1).
6. Godot MP3 디코더의 시작 지연(약 25~50 ms 추측)과 시크 정확도.
7. Demucs 라이선스·유지보수 상태·CPU 속도(후속 결정 시 확인).
8. `song.json` 크기(60줄 50~100 KB 추측).
9. LRCLIB 데이터 이용 조건: 문서에 약관이 없음(2026-10-30). 변경될 수 있으니 릴리스 전 `lrclib.net/docs`를 다시 확인.
10. 폰의 `DirAccess.get_space_left()` 신뢰성.

## 부록 B. 조사 출처 (읽기만 함)
- LRCLIB API 문서: `https://lrclib.net/docs.md` (엔드포인트 `GET /api/get`·`/api/search`, `User-Agent`/`X-User-Agent`/`Lrclib-Client` 식별 요구, 식별된 클라이언트 약 90회/분, 429 `Retry-After`, 요청 사이 200~500 ms 권장, `duration` ±2초 규칙, `hasWordSync`·`lyricsfile` 필드)
- Godot 클래스 문서: `AudioStreamMP3`(`load_from_file` `load_from_buffer` `data`), `AudioEffectPitchShift`(`pitch_scale` `fft_size` `oversampling`)
- Godot 4.6 안드로이드 SAF 파일 대화상자: `https://forum.godotengine.org/t/problem-with-new-saf-storage-implementation/132088` (대화상자가 `content://` 주소를 돌려줌)
- 이 저장소 코드·문서(위 "읽은 것")
