폰 점수 보정 도구 (v2.0.1 PA5a)
==============================

무엇을 하는 도구인가
--------------------
폰(whisper.cpp)이 내는 단어 확률 p 는 PC 서버(faster-whisper)의 p 와 분포가 다르다. 그래서 같은 소리를 두 엔진에 돌려
폰 p -> PC p 로 가는 단조 매핑(p_map), 단어 통과선(ok_prob), 필요하면 beam, 마지막 대안으로 최종 점수 매핑(final_map)을 맞춘다.
결과는 godot\data\score_params.json 형식이다(docs\v201_design.md 2.3). 이 폴더의 도구는 값을 "만드는" 도구이고,
실제 보정 실행(PA5b)과 score_params.json 저장은 이 도구의 일이 아니다.

도구 (모두 phone_src\tools\, 파이썬은 backend\.venv)
  calib_make_set.py   합성 음성 세트 만들기 (서버 synth_wav = Kokoro, 이미 설치된 음성만)
  calib_record.py     사용자 녹음 (동의 문구 -> y -> 60클립)
  calib_pc_run.py     PC 쪽 결과 (서버 transcribe + score_en, 같은 프로세스 안, 서버·포트 없음)
  godot\tools\calib_phone.gd   폰 쪽 결과 (Windows 용 WhisperBridge DLL + 같은 모델 파일)
  calib_fit.py        맞추기 + 합격선 판정 + score_params.json / 보고서 쓰기
  test_calib_fit.py   시험 (python -I -X utf8 -m unittest discover -s phone_src\tools -p test_calib_fit.py)

PowerShell 에서 쓰는 이름 (docs\v201_design.md 5.0 과 같다)
  $W = 작업 폴더(저장소 또는 worktree)   $PY = D:\Ai\언어\app\backend\.venv\Scripts\python.exe
  $G = Godot 4.6.3 콘솔 실행 파일          $MODEL = ggml-base.en-q5_1.bin (모델 파일, 저장소 밖)
  $T = scratch 폴더(저장소 밖). 모든 산출물은 $T 아래에 둔다. 저장소 안에 오디오·인식 글자를 두지 않는다.

절차
----
0) (폰 쪽 실행에만 필요) 네이티브 준비 N0: PA1 산출물(DLL)을 godot\bin 으로 복사하고 godot\whisper_bridge.gdextension 을 만든 뒤
   godot --headless --path $W\godot --import 를 두 번 돌린다(docs\v201_design.md 5.0 의 Prep-Native). 브리지가 없으면 calib_phone.gd 는
   CALIB_PHONE_NO_ENGINE 을 찍고 종료 코드 2 로 끝난다.

1) 합성 세트
     & $PY -I -X utf8 $W\phone_src\tools\calib_make_set.py --out $T\set_synth [--n-sentences 200] [--voices 4] [--seed 7]
   문장: godot\data\pack\practice_en.json 의 3~10 낱말 문장(모자라면 코스 문장으로 보충). 문장·음성마다 8가지 변형:
   clean / wrong(낱말 1개를 바꿔 읽음, 타깃은 원문) / speed08 / speed125 / snr20 / snr10 / band8k / amp02.
   음성은 이 PC 에 이미 있는 것만 쓴다. 요청보다 적으면 "CALIB_SET_VOICES_LIMITED have=.. want=.." 를 찍고 계속한다
   (2026-11-19 이 PC: 영어 음성 1종 af_heart. PA5b-1 의 "음성 >= 4" 는 새 음성을 내려받지 않는 한 채울 수 없다).
   같은 시드면 문장·바꾼 낱말·잡음·오디오가 같다(합성 전에 torch 시드를 고정한다).
   결과: $T\set_synth\manifest.json 과 clips\*.wav (16 kHz 모노 16비트). manifest 의 각 클립: clip, file, sentence_id, target,
   variant, voice, wrong(null 또는 {index, said}; index 는 target.split() 의 몇 번째 낱말), spoken, seconds, sha256.

2) 사용자 녹음 (사용자가 직접, 마이크 앞)
     & $PY -I -X utf8 $W\phone_src\tools\calib_record.py --out $T\calib_user        (--dry-run 은 문구·문장만 보이고 아무것도 안 씀)
   먼저 동의 문구를 그대로 보이고 y 를 입력해야 시작한다:
     "영어 문장 30개를 한 번은 바르게, 한 번은 화면이 알려 주는 낱말 하나를 바꿔서 읽어요(약 8분). 녹음은 이 PC 의 임시 폴더에만
      저장되고 저장소·인터넷으로 나가지 않아요. 보정이 끝나면 지워요(원하면 보관). 시작할까요? (y/n)"
   문장 30개 x (바르게, 낱말 하나 바꿔) = 60클립. 클립마다 Enter 로 6초 녹음(카운트다운 표시), Enter = 다음, r = 다시, q = 여기서 그만.
   --out 은 필수(없으면 종료 코드 2)이고 비어 있거나 없는 폴더여야 한다. 끝나면 클립 수와 총 길이만 출력한다.
   manifest.json 에 동의 기록(consent.given, 문구 sha256, 날짜)이 들어간다.

3) PC 쪽과 폰 쪽 결과 (세트마다)
     & $PY -I -X utf8 $W\phone_src\tools\calib_pc_run.py --set $T\set_synth --out $T\pc_synth.json
     & $G --headless --path $W\godot -s res://tools/calib_phone.gd -- --model=$MODEL --set=$T\set_synth --out=$T\phone_synth.json [--beam=1]
   두 JSON 의 클립 id 집합은 같아야 한다. 이 JSON 에는 인식 글자가 들어 있으니
   scratch 에만 둔다. 사용자 세트도 같은 두 명령(--set $T\calib_user).
   calib_pc_run.py 는 먼저 클립 파일의 sha256 을 manifest 와 맞춰 보고(다르면 CALIB_PC_FAIL sha256) 모델을 불러온다.

4) 맞추기
     & $PY -I -X utf8 $W\phone_src\tools\calib_fit.py --pc $T\pc_synth.json $T\pc_user.json --phone $T\phone_synth.json $T\phone_user.json `
         --out-params $T\score_params.json --report $T\report.json [--holdout 0.3] [--seed 7] [--fit-final]
   - 클립은 id 로 짝짓는다(순서가 아니다). 한쪽에만 있는 클립, 빈 입력, 깨진 JSON 은 종료 코드 1.
   - 문장 단위로 70 % / 30 % 로 나눈다(같은 문장의 모든 음성·변형·사용자 클립이 한쪽에만). 70 % 로 맞추고 30 % 로 판정.
   - 짝 일치도(두 엔진이 들은 낱말 목록의 SequenceMatcher 비율 평균)가 0.6 미만이면 "CALIB_FAIL agreement", 종료 코드 1.
   - p_map: 서버 정렬로 두 엔진이 정확히 맞춘 낱말쌍에서 폰 p -> PC p 의 등위(isotonic) 회귀, 고정 10점(0, .05, .1, .2, .3, .45, .6, .75, .9, 1)에서 읽음.
   - ok_prob: 폰의 낱말별 ok 가 PC 의 ok 와 가장 많이 같아지는 값(0.21~0.79, 같으면 0.45 에 가까운 쪽).
   - 판정은 서버 score_en 을 같은 프로세스에서 불러 계산한다(복사 없음).
   합격선(보류 30 %): 낱말 ok 일치율 합성 >= 0.85·사용자 >= 0.80, 최종 점수 MAE <= 10·p90 <= 20, 유창성 MAE <= 15,
   틀린 클립이 같은 문장의 깨끗한 클립보다 낮은 쌍 >= 0.95, 틀린 클립 70+ <= 0.10, 깨끗한 클립 70 미만 <= 0.10.
   한 클립 세트(합성만 또는 사용자만)만 넣으면 없는 쪽의 일치율 줄은 SKIP 이다.
   미달이면 "CALIB_FAIL <지표들>" 과 종료 코드 1, --out-params 파일은 쓰지 않는다(--report 는 쓴다).
   통과하면 --out-params 에 score_params.json(v1, model_id, calibrated, date, ok_prob, beam, p_map, final_map, report)을 쓴다.
   model_id 는 폰 JSON 의 모델 파일 이름에서(ggml-base.en-q5_1.bin -> whisper-base.en-q5_1), beam 도 폰 JSON 에서 온다.
   date 는 pc JSON 의 날짜라서 같은 입력·같은 시드면 파일이 바이트 단위로 같다.
   보고서(--report)에는 숫자만 있다(클립 수, 지표, 95 % 구간, 합격선 결과). 문장·인식 글자는 없다.

폴백 순서 (docs\v201_design.md 2.4, 결정 7)
  1) beam 2 -> 3: calib_phone.gd --beam=2 (또는 3) 로 폰 쪽만 다시 돌려 calib_fit.py 를 다시 한다(beam 은 폰 JSON 에서 읽는다).
  2) 그래도 미달이면 멈추고 보고(q8_0 모델 비교는 사용자 재승인 뒤 별도 지시).
  3) calib_fit.py --fit-final: 최종 점수 매핑 final_map 을 찾는다. 틀린 클립 70+ <= 0.10 과 깨끗한 클립 70 미만 <= 0.10 을 같이
     만족하는 계단 하나(원점수 a -> 70, a-1 -> 69)를 학습 쪽에서 찾는다. 이때 폰 점수를 일부러 PC 점수에서 떼어 놓으므로
     최종 점수 MAE·p90(PC 와의 거리)은 숫자로 보고만 하고 판정하지 않는다("WAIVED"). 나머지 6개 합격선은 그대로 적용된다.
     report.fallback 은 "final_map"(beam 만 올렸으면 "beam", 아니면 "none").

개인정보와 삭제
---------------
- 사용자 녹음·인식 글자·전사는 저장소에 두지 않는다. 도구는 --out 으로 받은 폴더(scratch)에만 쓰고, 로그 파일을 만들지 않는다.
- calib_record.py 는 인식하지 않는다(녹음만 한다). 화면에는 읽을 문장이 보이고, 파일에는 manifest 의 target(문장)과 wav 만 남는다.
- 보정이 끝나면 지우는 것이 기본이다. 사용자가 보관을 원하면 그대로 두고, 어느 쪽인지 PA5b 보고에 적는다.
  삭제(PowerShell):   Remove-Item -Recurse -Force $T\calib_user
  합성 세트·pc/phone JSON 도 같은 방법으로 지운다(저장소 밖 scratch 폴더라 저장소에는 영향이 없다).

알려진 한계 (2026-11-19, 이 PC에서 직접 확인)
- 합성 영어 음성이 af_heart 1종뿐이다. 새로 내려받지 않았다.
- 폰 쪽 단어 시각(whisper.cpp token_timestamps)이 불안정하다: 짧은 클립에서도 마지막 낱말 끝이 30초 근처로 나오고
  낱말 하나가 몇 초씩 차지하는 경우가 있다. 서버 유창성 점수는 이 시각으로 계산하므로 calib_fit.py 는 폰 시각을 그대로 쓰면
  유창성 MAE 가 크게 나온다(작은 세트 5문장·40클립에서 약 74). PA4 의 "시각 정리"(docs\v201_design.md 2.3 6번)가 병합되면
  그 규칙으로 시각을 고친 phone JSON 을 쓰거나 calib_fit.py 앞에 같은 정리를 넣어야 한다. 이 도구는 시각을 고치지 않는다.
- calib_pc_run.py 는 CPU int8(서버 --stt-cpu 와 같은 설정)이라 클립이 많으면 오래 걸린다(작은 세트 40클립 약 85초).
