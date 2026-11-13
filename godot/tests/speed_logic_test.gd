extends Node
## 스피드 퀴즈 로직 시험: SpeedPool(풀·문제) + SpeedLogic(점수·시간) (서버 없이, 화면 없음).
##   PC : godot --headless --path godot res://tests/speed_logic_test.tscn
##   폰 : (순수 계산 시험이라 PC 한 번이면 된다. `-- --phone` 을 붙여도 결과는 같다)
## 마지막 줄: "== speed_logic: N passed, M failed ==" (실패가 있으면 종료 코드 1)
## 일부러 틀린 입력으로 검사 함수(check_question)와 SpeedLogic 이 실제로 FAIL/거절하는지도 본다(selfcheck FAIL-as-expected).
## 파일을 쓰지 않는다. Store/StudyLog 에 닿지 않는다.

const SEEDS := 300

var passed: int = 0
var failed: int = 0
var _words := {}  ## lang -> SpeedPool.load_words 의 words


func ok(cond: bool, name: String) -> void:
	if cond:
		passed += 1
		print("  PASS  ", name)
	else:
		failed += 1
		print("  FAIL  ", name)


func _ready() -> void:
	print("== speed_logic test start ==")
	SpeedPool.words_path = SpeedPool.DATA_PATH
	SpeedPool.clear_cache()
	for l in ["en", "ja"]:
		_words[l] = SpeedPool.load_words(l)["words"]
	_test_ko_tokens()
	_test_card_items()
	_test_build()
	_selfcheck_question()
	_test_questions()
	_test_scoring()
	_test_time()
	_test_bad_inputs()
	_test_order()
	_test_result()
	print("== speed_logic: %d passed, %d failed ==" % [passed, failed])
	get_tree().quit(1 if failed > 0 else 0)


# ---------------------------------------------------------------- 도우미

const FRUITS := ["사과", "바나나", "포도", "수박", "딸기", "귤", "감", "배", "자두", "복숭아", "살구", "앵두", "체리", "망고", "키위", "레몬", "오이", "당근", "무", "파"]


func _cards(n: int, lang: String = "en") -> Array:
	var out: Array = []
	for i in n:
		out.append({"id": "id%d" % i, "lang": lang, "target": "word%s" % char(97 + i) if lang == "en" else "語%d" % i,
			"reading": "", "ko": FRUITS[i % FRUITS.size()] + ("" if i < FRUITS.size() else "씨"), "note": "", "due": 1000 + (n - i) * 10})
	return out


func _rng(seed_: int) -> RandomNumberGenerator:
	var r := RandomNumberGenerator.new()
	r.seed = seed_
	return r


## 질문 하나가 규칙에 맞는지: 틀린 곳의 설명 목록(빈 배열 = 통과).
func check_question(q: Dictionary, item: Dictionary) -> Array:
	var errs: Array = []
	var opts: Variant = q.get("options", null)
	if not (opts is Array) or (opts as Array).size() != SpeedPool.OPTIONS_N:
		return ["options is not %d long" % SpeedPool.OPTIONS_N]
	var seen := {}
	for o in opts:
		if seen.has(o):
			errs.append("duplicate option '%s'" % o)
		seen[o] = true
	var a: int = int(q.get("answer", -1))
	if a < 0 or a >= (opts as Array).size():
		errs.append("answer index out of range")
		return errs
	if str(opts[a]) != str(item.get("ko", "")):
		errs.append("options[answer] is not the item's meaning")
	if str(q.get("ko", "")) != str(item.get("ko", "")):
		errs.append("q.ko differs from the item's ko")
	var ans_tok: Array = SpeedPool.ko_tokens(str(opts[a]))
	for i in (opts as Array).size():
		if i == a:
			continue
		for t in SpeedPool.ko_tokens(str(opts[i])):
			if t in ans_tok:
				errs.append("option '%s' shares token '%s' with the answer" % [opts[i], t])
	if str(q.get("w", "")) != str(item.get("w", "")):
		errs.append("w changed")
	if str(q.get("rd", "")) != str(item.get("rd", "")):
		errs.append("rd not preserved")
	if str(q.get("src", "")) != str(item.get("src", "")):
		errs.append("src not preserved")
	return errs


func _lesson_items(lang: String, month: int = 12, cards: Array = []) -> Array:
	var b := SpeedPool.build(lang, cards, month, _words[lang])
	return b["items"]


# ---------------------------------------------------------------- 시험

func _test_ko_tokens() -> void:
	ok(SpeedPool.ko_tokens("일하다, 근무하다") == ["일하다", "근무하다"], "ko_tokens: comma split + space removed")
	ok(SpeedPool.ko_tokens("~의") == ["의"], "ko_tokens: leading ~ dropped")
	ok(SpeedPool.ko_tokens("가다/오다;오르다·내리다") == ["가다", "오다", "오르다", "내리다"], "ko_tokens: / ; · split")
	ok(SpeedPool.ko_tokens(" , ,; ").is_empty() and SpeedPool.ko_tokens("").is_empty(), "ko_tokens: empty pieces dropped")
	ok(SpeedPool.ko_tokens("하고 있는 상태") == ["하고있는상태"], "ko_tokens: inner spaces removed")


func _test_card_items() -> void:
	var cards: Array = _cards(3)
	cards.append({"id": "e1", "lang": "en", "target": "x", "reading": "", "ko": "", "note": ""})            # ko 비었음
	cards.append({"id": "e2", "lang": "en", "target": "x", "reading": "", "ko": "   ", "note": ""})         # ko 공백뿐
	cards.append({"id": "e3", "lang": "en", "target": "one two three four five", "ko": "다섯 단어", "note": ""})  # 영어 5단어
	cards.append({"id": "e4", "lang": "en", "target": "ok", "ko": "가".repeat(41), "note": ""})              # ko 41자
	cards.append({"id": "e5", "lang": "ja", "target": "あ".repeat(13), "ko": "열세 글자", "note": ""})        # 일본어 13자
	cards.append({"id": "e6", "lang": "fr", "target": "bonjour", "ko": "안녕", "note": ""})                  # 다른 언어
	cards.append({"id": "e7", "lang": "en", "target": "", "ko": "빈 target", "note": ""})
	cards.append({"id": "e8", "lang": "en", "target": 5, "ko": "숫자 target", "note": ""})
	cards.append("not a card")
	cards.append({"id": "ok1", "lang": "en", "target": "see you later", "ko": "나중에 봐", "note": ""})       # 3단어 통과
	cards.append({"id": "ok2", "lang": "ja", "target": "あ".repeat(12), "ko": "열두 글자", "note": ""})       # 12자 통과
	var all := SpeedPool.card_items(cards)
	var ids: Array = []
	for it in all:
		ids.append(it["id"])
	ok("c:e1" not in ids and "c:e2" not in ids, "card_items: empty / blank ko dropped")
	ok("c:e3" not in ids, "card_items: en target > 4 words dropped")
	ok("c:e4" not in ids, "card_items: ko > 40 chars dropped")
	ok("c:e5" not in ids, "card_items: ja target > 12 chars dropped")
	ok("c:e6" not in ids and "c:e7" not in ids and "c:e8" not in ids, "card_items: foreign lang / empty target / non-string target dropped")
	ok("c:ok1" in ids and "c:ok2" in ids and all.size() == 5, "card_items: good cards kept (%d items)" % all.size())
	var en_only := SpeedPool.card_items(cards, "en")
	var has_ja := false
	for it in en_only:
		if it["id"] == "c:ok2":
			has_ja = true
	ok(not has_ja and en_only.size() == 4, "card_items(lang=en) drops ja cards (%d items)" % en_only.size())
	ok(all[0]["src"] == "card" and all[0]["v"] == true and int(all[0]["due"]) > 0, "card item shape: src=card, v=true, due kept")


func _test_build() -> void:
	for l in ["en", "ja"]:
		var b20 := SpeedPool.build(l, _cards(20, l), 1, _words[l])
		ok(b20["ok"] and int(b20["n_cards"]) >= 1 and int(b20["n_words"]) >= 1, "build %s: 20 cards + lesson words ok (cards=%d words=%d)" % [l, b20["n_cards"], b20["n_words"]])
		ok(int(b20["n_cards"]) == 20, "build %s: all 20 cards used" % l)
		var b0 := SpeedPool.build(l, [], 1, _words[l])
		ok(b0["ok"] and int(b0["n_cards"]) == 0 and int(b0["n_words"]) >= 1, "build %s: no cards, lesson words only ok (%d)" % [l, b0["n_words"]])
		var b3 := SpeedPool.build(l, _cards(3, l), 1, [])
		ok(not b3["ok"] and b3["reason"] == "pool_small" and (b3["items"] as Array).is_empty(), "build %s: 3 cards + 0 words -> pool_small" % l)
		var b_all := SpeedPool.build(l, [], 12, _words[l])
		ok(int(b_all["n_words"]) > int(b0["n_words"]), "build %s: later month has more words (%d > %d)" % [l, b_all["n_words"], b0["n_words"]])
		# 레슨 단어는 m <= month+1
		var over := false
		for it in b0["items"]:
			if int(it["m"]) > 2:
				over = true
		ok(not over, "build %s: month 1 uses only words with m <= 2" % l)
	# 합성 단어: 월 필터 · 중복 제거 · 통과 우선
	var fw: Array = []
	for i in 30:
		fw.append({"w": "w%d" % i, "ko": FRUITS[i % FRUITS.size()] + ("" if i < FRUITS.size() else "x"), "pos": "명사", "m": 1 + (i % 6), "v": true})
	var bm := SpeedPool.build("en", [], 3, fw)
	var max_m := 0
	for it in bm["items"]:
		max_m = maxi(max_m, int(it["m"]))
	ok(max_m == 4, "build: month 3 -> highest m used is 4 (month+1) (%d)" % max_m)
	var dup_cards: Array = _cards(2)
	dup_cards[0]["target"] = "w0"
	var bd := SpeedPool.build("en", dup_cards, 6, fw)
	var count_w0 := 0
	for it in bd["items"]:
		if str(it["w"]).to_lower() == "w0":
			count_w0 += 1
	ok(count_w0 == 1, "build: a lesson word equal to a card target is not added twice")
	# 통과(v) 우선: 풀이 충분하면 통과 못한 단어는 안 섞는다
	var vw: Array = []
	for i in 60:
		vw.append({"w": "v%d" % i, "ko": FRUITS[i % FRUITS.size()] + "_" + str(i), "pos": "명사", "m": 1, "v": i < 50})
	var bv := SpeedPool.build("en", [], 1, vw)
	var unv := 0
	for it in bv["items"]:
		if not it["v"]:
			unv += 1
	ok(bv["ok"] and unv == 0 and not bv["mixed_unverified"] and bv["n_unverified"] == 0, "build: 50 verified >= PREFER_POOL -> unverified words not mixed in")
	# 통과 단어가 모자라면 모자란 만큼만 섞고 표시한다
	var few: Array = []
	for i in 60:
		few.append({"w": "f%d" % i, "ko": FRUITS[i % FRUITS.size()] + "_" + str(i), "pos": "명사", "m": 1, "v": i < 10})
	var bf := SpeedPool.build("en", [], 1, few)
	var verified := 0
	var rest := 0
	for it in bf["items"]:
		if it["v"]:
			verified += 1
		else:
			rest += 1
	ok(bf["ok"] and verified == 10 and rest == SpeedPool.PREFER_POOL - 10 and bf["mixed_unverified"] and bf["n_unverified"] == rest,
		"build: 10 verified + only the missing %d unverified mixed in, flagged (v=%d rest=%d)" % [SpeedPool.PREFER_POOL - 10, verified, rest])
	# 같은 뜻만 있는 풀은 보기를 못 만들어서 ok=false
	var same: Array = []
	for i in 30:
		same.append({"w": "s%d" % i, "ko": "똑같다", "pos": "명사", "m": 1, "v": true})
	ok(not SpeedPool.build("en", [], 1, same)["ok"], "build: 30 words all with the same meaning -> not ok")
	# 시험 입력: 깨진 항목이 섞여도 에러 없이
	var junk: Array = [1, "x", null, {"w": 5}, {"w": "a", "ko": 3, "m": 1}]
	ok(not SpeedPool.build("en", [], 1, junk)["ok"], "build: junk entries only -> not ok, no error")


func _selfcheck_question() -> void:
	var item := {"id": "w:work", "src": "lesson", "w": "work", "rd": "", "ko": "일하다"}
	var good := {"id": "w:work", "src": "lesson", "w": "work", "rd": "", "ko": "일하다", "options": ["가다", "일하다", "먹다", "자다"], "answer": 1}
	ok(check_question(good, item).is_empty(), "selfcheck: check_question passes a good question")
	var dup := good.duplicate(true)
	dup["options"] = ["가다", "일하다", "가다", "자다"]
	ok(not check_question(dup, item).is_empty(), "selfcheck FAIL-as-expected: duplicate option")
	var wrong_ans := good.duplicate(true)
	wrong_ans["answer"] = 0
	ok(not check_question(wrong_ans, item).is_empty(), "selfcheck FAIL-as-expected: wrong answer index")
	var overlap := good.duplicate(true)
	overlap["options"] = ["일하다, 근무하다", "일하다", "먹다", "자다"]
	ok(not check_question(overlap, item).is_empty(), "selfcheck FAIL-as-expected: option shares a token with the answer")
	var short := good.duplicate(true)
	short["options"] = ["일하다", "먹다", "자다"]
	short["answer"] = 0
	ok(not check_question(short, item).is_empty(), "selfcheck FAIL-as-expected: only 3 options")
	var lost_rd := good.duplicate(true)
	var ja_item := item.duplicate()
	ja_item["rd"] = "はたらく"
	ok(not check_question(lost_rd, ja_item).is_empty(), "selfcheck FAIL-as-expected: rd lost")
	var oob := good.duplicate(true)
	oob["answer"] = 7
	ok(not check_question(oob, item).is_empty(), "selfcheck FAIL-as-expected: answer index out of range")


func _test_questions() -> void:
	for l in ["en", "ja"]:
		var items := _lesson_items(l, 12, _cards(20, l))
		ok(items.size() > 100, "questions %s: pool of %d items" % [l, items.size()])
		var bad := 0
		var made := 0
		var first_err := ""
		var rd_ok := true
		for s in SEEDS:
			var r := _rng(1000 + s)
			var it: Dictionary = items[s % items.size()]
			var q := SpeedPool.make_question(it, items, r)
			if q.is_empty():
				bad += 1
				first_err = "empty question for %s" % it["w"]
				continue
			made += 1
			var errs := check_question(q, it)
			if not errs.is_empty():
				bad += 1
				if first_err == "":
					first_err = "%s: %s" % [it["w"], str(errs)]
			if l == "ja" and it["src"] == "lesson" and (q["rd"] as String) == "":
				rd_ok = false
		ok(bad == 0 and made == SEEDS, "questions %s: %d seeds all valid %s" % [l, SEEDS, first_err])
		ok(rd_ok, "questions %s: ja reading kept on lesson items" % l)
	# 같은 시드면 같은 문제
	var items_en := _lesson_items("en", 12)
	var q1 := SpeedPool.make_question(items_en[5], items_en, _rng(7))
	var q2 := SpeedPool.make_question(items_en[5], items_en, _rng(7))
	ok(q1 == q2 and not q1.is_empty(), "questions: same seed -> same question")
	# 정답 "좋다" 에 "좋다" 가 든 오답이 안 나온다
	var pool: Array = [{"id": "a", "w": "good", "ko": "좋다", "pos": "형용사", "src": "lesson"}]
	for k in ["좋다, 훌륭하다", "좋다", "나쁘다", "크다", "작다", "빠르다", "느리다", "높다", "낮다", "나쁘다, 안 좋다"]:
		pool.append({"id": "x" + k, "w": "w" + k, "ko": k, "pos": "형용사", "src": "lesson"})
	var leaked := 0
	for s in 100:
		var q := SpeedPool.make_question(pool[0], pool, _rng(s))
		if q.is_empty():
			leaked += 1
			continue
		for o in q["options"]:
			if o != "좋다" and "좋다" in SpeedPool.ko_tokens(str(o)):
				leaked += 1
	ok(leaked == 0, "questions: no wrong option contains the answer's meaning '좋다' (100 seeds)")
	# 같은 품사 우선
	var pool2: Array = [{"id": "t", "w": "run", "ko": "달리다", "pos": "동사", "src": "lesson"}]
	for i in 6:
		pool2.append({"id": "v%d" % i, "w": "verb%d" % i, "ko": FRUITS[i] + "하다", "pos": "동사", "src": "lesson"})
	for i in 10:
		pool2.append({"id": "n%d" % i, "w": "noun%d" % i, "ko": FRUITS[10 + i], "pos": "명사", "src": "lesson"})
	var verbs := true
	for s in 50:
		var q := SpeedPool.make_question(pool2[0], pool2, _rng(s))
		for o in q["options"]:
			if o != "달리다" and not str(o).ends_with("하다"):
				verbs = false
	ok(verbs, "questions: distractors prefer the same part of speech when enough exist")
	# 만들 수 없는 경우는 빈 사전
	ok(SpeedPool.make_question({"id": "a", "w": "x", "ko": "뜻"}, [{"id": "b", "w": "y", "ko": "다른"}], _rng(1)).is_empty(), "questions: pool with < 3 distractors -> {}")
	ok(SpeedPool.make_question({}, items_en, _rng(1)).is_empty(), "questions: empty item -> {}")
	ok(SpeedPool.make_question({"id": "a", "w": "x", "ko": ""}, items_en, _rng(1)).is_empty(), "questions: empty ko -> {}")


## 한 판을 돌리는 도우미: 정답/오답을 시간 t 에 한 번 낸다. 결과 사전.
func _hit(sl: SpeedLogic, good: bool, t: int) -> Dictionary:
	var q := sl.current()
	var idx: int = q["answer"] if good else (int(q["answer"]) + 1) % 4
	var r := sl.answer(idx, t)
	sl.next_question()
	return r


func _logic(seed_: int = 1, limit: int = SpeedLogic.LIMIT_MS) -> SpeedLogic:
	return SpeedLogic.new(_lesson_items("en", 12), _rng(seed_), limit)


func _test_scoring() -> void:
	var sl := _logic()
	sl.start(0)
	var pts: Array = []
	for i in 5:
		pts.append(_hit(sl, true, 100 * (i + 1))["points"])
	ok(pts == [10, 12, 14, 16, 18], "scoring: 5 correct in a row -> 10,12,14,16,18 (%s)" % str(pts))
	ok(sl.result()["score"] == 70 and sl.result()["correct"] == 5 and sl.result()["combo"] == 5, "scoring: total 70, combo 5")
	var w := _hit(sl, false, 700)
	ok(w["accepted"] and not w["ok"] and w["points"] == 0 and w["combo"] == 0, "scoring: a wrong answer scores 0 and resets the combo")
	var after := _hit(sl, true, 1700)
	ok(after["accepted"] and after["points"] == 10 and after["combo"] == 1, "scoring: next correct answer is 10 again")
	ok(sl.result()["score"] == 80 and sl.result()["combo"] == 5, "scoring: score 80, best combo stays 5")
	# 콤보 12 연속: 증가분이 30 에서 멈춘다
	var sl2 := _logic(2)
	sl2.start(0)
	var p2: Array = []
	for i in 14:
		p2.append(_hit(sl2, true, 100 * (i + 1))["points"])
	ok(p2 == [10, 12, 14, 16, 18, 20, 22, 24, 26, 28, 30, 30, 30, 30], "scoring: points rise by 2 and stop at 30 (%s)" % str(p2))
	ok(p2[11] == 30 and p2[12] == 30, "scoring: combo 12 and 13 still give 30")
	ok(sl2.result()["combo"] == 14, "scoring: best combo counts every correct answer in the chain (14)")
	ok(SpeedLogic.BASE_POINTS + SpeedLogic.COMBO_STEP * SpeedLogic.COMBO_CAP == 30, "scoring: constants give a 30 cap")
	# 답한 뒤 next_question 전에는 다시 못 답한다 / 문제가 바뀐다
	var sl3 := _logic(3)
	sl3.start(0)
	var q0 := sl3.current()
	var r0 := sl3.answer(int(q0["answer"]), 100)
	ok(r0["accepted"] and r0["correct_index"] == q0["answer"], "scoring: answer returns the correct index")
	ok(sl3.current()["id"] == q0["id"], "scoring: the question stays until next_question()")
	sl3.next_question()
	ok(sl3.current()["id"] != q0["id"], "scoring: next_question() moves to a different question")


func _test_time() -> void:
	var sl := _logic()
	ok(sl.remaining_ms(0) == SpeedLogic.LIMIT_MS and not sl.tick(0), "time: before start nothing runs out")
	sl.start(0)
	ok(sl.remaining_ms(10_000) == 50_000, "time: remaining 50000 at 10s")
	var r := sl.answer(int(sl.current()["answer"]), 59_999)
	ok(r["accepted"] and r["points"] == 10, "time: answer at 59,999 ms is counted")
	sl.next_question()
	var late := sl.answer(int(sl.current()["answer"]), 60_001)
	ok(not late["accepted"] and late["points"] == 0 and sl.result()["score"] == 10, "time: answer at 60,001 ms is refused, score unchanged")
	ok(sl.tick(60_001) and sl.tick(61_000) and sl.tick(70_000), "time: tick stays true after the end")
	ok(sl.remaining_ms(99_000) == 0 and sl.current().is_empty() and sl.result()["finished"], "time: remaining 0, no current question, result finished")
	# 정확히 60,000 에서 끝
	var sl_edge := _logic(5)
	sl_edge.start(0)
	ok(not sl_edge.tick(59_999) and sl_edge.tick(60_000), "time: tick false at 59,999 and true at 60,000")
	# 오답 잠금 900ms
	var sl2 := _logic(6)
	sl2.start(0)
	_hit(sl2, false, 5000)
	var early := sl2.answer(int(sl2.current()["answer"]), 5899)
	ok(not early["accepted"], "time: 899 ms after a wrong answer -> refused")
	var on_time := sl2.answer(int(sl2.current()["answer"]), 5900)
	ok(on_time["accepted"] and on_time["ok"], "time: 900 ms after a wrong answer -> accepted")
	ok(sl2.result()["total"] == 2, "time: a refused answer is not counted in total")
	# pause / resume
	var sl3 := _logic(7)
	sl3.start(0)
	var before := sl3.remaining_ms(10_000)
	sl3.pause(10_000)
	ok(sl3.is_paused() and sl3.remaining_ms(15_000) == before, "time: paused clock stands still")
	var paused_ans := sl3.answer(int(sl3.current()["answer"]), 15_000)
	ok(not paused_ans["accepted"], "time: answers are refused while paused")
	ok(not sl3.tick(16_000), "time: a paused game does not run out")
	sl3.resume(20_000)
	ok(sl3.remaining_ms(20_000) == before, "time: pause(10s) resume(20s) -> same remaining as before (%d)" % before)
	ok(sl3.answer(int(sl3.current()["answer"]), 25_000)["accepted"], "time: answers accepted again after resume")
	ok(sl3.remaining_ms(30_000) == before - 10_000, "time: clock runs again after resume")
	# 정지 때문에 오답 잠금이 줄어들지 않는다
	var sl4 := _logic(8)
	sl4.start(0)
	_hit(sl4, false, 1000)       # 잠금 ~1900
	sl4.pause(1100)
	sl4.resume(9100)             # 8 초 정지
	ok(not sl4.answer(int(sl4.current()["answer"]), 9500)["accepted"], "time: the wrong-answer lock is not eaten by a pause")
	ok(sl4.answer(int(sl4.current()["answer"]), 9900)["accepted"], "time: ... and ends 900 ms of play after the wrong answer")
	# 한도가 다른 판
	var sl5 := SpeedLogic.new(_lesson_items("en", 12), _rng(9), 5000)
	sl5.start(0)
	ok(sl5.remaining_ms(1000) == 4000 and sl5.tick(5000), "time: custom limit 5000 ms respected")


func _test_bad_inputs() -> void:
	var sl := _logic()
	var q := sl.current()
	var none := sl.answer(int(q["answer"]), 0)
	ok(not none["accepted"], "selfcheck FAIL-as-expected: answer before start() refused")
	sl.start(1000)
	for bad_i in [-1, 4, 99, -99]:
		ok(not sl.answer(bad_i, 2000)["accepted"], "selfcheck FAIL-as-expected: answer(%d) out of range refused" % bad_i)
	ok(not sl.answer(0, NAN)["accepted"], "selfcheck FAIL-as-expected: answer(0, NAN) refused")
	ok(not sl.answer(int(q["answer"]), -5)["accepted"], "selfcheck FAIL-as-expected: negative now_ms refused")
	ok(sl.result()["total"] == 0 and sl.result()["score"] == 0, "bad inputs changed nothing so far")
	var good := sl.answer(int(q["answer"]), 3000)
	ok(good["accepted"], "a good answer after all that bad input is still accepted")
	ok(not sl.answer(int(q["answer"]), 3100)["accepted"], "selfcheck FAIL-as-expected: answering the same question twice refused")
	sl.next_question()
	ok(not sl.answer(int(sl.current()["answer"]), 2500)["accepted"], "selfcheck FAIL-as-expected: now_ms going backwards refused")
	ok(sl.answer(int(sl.current()["answer"]), 3200)["accepted"], "forward time works again")
	ok(sl.result()["total"] == 2, "total counts only the 2 accepted answers")
	# tick/remaining 은 나쁜 값을 직전 값으로 본다
	ok(sl.remaining_ms(-1) == sl.remaining_ms(3200), "bad now_ms in remaining_ms is read as the last good one")
	ok(not sl.tick(-1000) and not sl.tick(100), "bad now_ms in tick does not end the game")
	# 빈 목록
	var empty := SpeedLogic.new([], _rng(1))
	empty.start(0)
	ok(empty.current().is_empty() and not empty.answer(0, 100)["accepted"], "selfcheck FAIL-as-expected: SpeedLogic.new([]) has no question and refuses answers")
	var er := empty.result()
	ok(er["score"] == 0 and er["total"] == 0 and (er["wrong"] as Array).is_empty() and not er["finished"], "empty list: zero result, not finished")
	ok(empty.tick(60_000) and empty.result()["finished"], "empty list: time still runs out")
	empty.next_question()
	# 쓸 수 없는 항목만 있는 목록
	var junk := SpeedLogic.new([1, "a", {"w": "x"}, {"w": "y", "ko": ""}, null], _rng(1))
	junk.start(0)
	ok(junk.current().is_empty() and not junk.answer(0, 10)["accepted"], "junk items: ignored, no question, no error")
	# 문제를 못 만드는 풀(뜻이 3개 미만)
	var tiny := SpeedLogic.new([{"id": "a", "w": "a", "ko": "하나"}, {"id": "b", "w": "b", "ko": "둘"}], _rng(1))
	tiny.start(0)
	ok(tiny.current().is_empty(), "tiny pool: no question can be made -> empty, no endless loop")


func _test_order() -> void:
	# 카드 없이 레슨 단어만: 한 바퀴 안에 같은 항목이 다시 나오지 않는다.
	var items := _lesson_items("en", 4)
	var sl := SpeedLogic.new(items, _rng(11))
	sl.start(0)
	var seen := {}
	var dup := false
	var asked := 0
	for i in items.size():
		var q := sl.current()
		if q.is_empty():
			break
		if seen.has(q["id"]):
			dup = true
		seen[q["id"]] = true
		asked += 1
		_hit(sl, true, 10 + i)
	ok(not dup and asked >= items.size() - 3, "order: no repeat inside one pass over the pool (%d asked of %d)" % [asked, items.size()])
	# 한 바퀴를 넘겨도 바로 같은 문제가 이어지지 않는다
	var last := ""
	var consecutive := false
	for i in items.size() + 20:
		var q := sl.current()
		if q.is_empty():
			break
		if q["id"] == last:
			consecutive = true
		last = q["id"]
		_hit(sl, true, 5000 + i)
	ok(not consecutive, "order: the same question never comes twice in a row, also across passes")
	# 카드 20장: 문제의 약 절반이 카드, 마감이 빠른 카드부터
	var cards := _cards(20)
	var mixed := _lesson_items("en", 12, cards)
	var s2 := SpeedLogic.new(mixed, _rng(12))
	s2.start(0)
	var card_n := 0
	var due_seq: Array = []
	var ids: Array = []
	for i in 20:
		var q := s2.current()
		ids.append(q["id"])
		if q["src"] == "card":
			card_n += 1
			for c in cards:
				if "c:" + str(c["id"]) == q["id"]:
					due_seq.append(c["due"])
		_hit(s2, true, 10 + i)
	ok(card_n == 10, "order: with 20 cards, 10 of the first 20 questions are cards (%d)" % card_n)
	var sorted := due_seq.duplicate()
	sorted.sort()
	ok(due_seq == sorted and due_seq.size() == 10, "order: cards come earliest-due first %s" % str(due_seq.slice(0, 4)))
	ok(_unique(ids), "order: first 20 questions are all different")
	# 카드가 8장 미만이면 레슨 단어 위주
	var s3 := SpeedLogic.new(_lesson_items("en", 12, _cards(5)), _rng(13))
	s3.start(0)
	var c3 := 0
	for i in 30:
		if s3.current()["src"] == "card":
			c3 += 1
		_hit(s3, true, 10 + i)
	ok(c3 <= 5, "order: with 5 cards, cards are a small part (%d of 30)" % c3)


func _unique(a: Array) -> bool:
	var s := {}
	for x in a:
		if s.has(x):
			return false
		s[x] = true
	return true


func _test_result() -> void:
	var sl := _logic(21)
	sl.start(0)
	var wrong_ids: Array = []
	for i in 4:
		wrong_ids.append(sl.current()["id"])
		_hit(sl, false, 1000 * (i + 1))
	_hit(sl, true, 6000)
	var res := sl.result()
	ok(res["total"] == 5 and res["correct"] == 1 and res["score"] == 10 and res["combo"] == 1 and not res["finished"], "result: totals after 4 wrong + 1 correct")
	ok((res["wrong"] as Array).size() == 4, "result: 4 wrong words listed")
	var first: Dictionary = res["wrong"][0]
	ok(first.has("w") and first.has("rd") and first.has("ko") and first.has("id") and first.has("src") and first["id"] == wrong_ids[0], "result: wrong entry has w/rd/ko/id/src in order")
	(res["wrong"] as Array).clear()
	ok((sl.result()["wrong"] as Array).size() == 4, "result: changing the returned copy does not change the game")
	sl.tick(60_000)
	ok(sl.result()["finished"], "result: finished after the time ran out")
	# 일본어: rd 가 오답 목록에 보존
	var ja := SpeedLogic.new(_lesson_items("ja", 12), _rng(22))
	ja.start(0)
	_hit(ja, false, 100)
	var jw: Dictionary = ja.result()["wrong"][0]
	ok(str(jw["rd"]) != "", "result: ja wrong word keeps its reading (%s)" % str(jw["rd"]))
