extends Node
## JaSounds 코어 시험: events 표(>= 25행), annotate, build_listen_session, 틀린 입력.
##   godot --headless --path <project> res://tests/ja_sounds_test.tscn
## 마지막 줄: "== ja_sounds: N passed, M failed ==" (실패가 있으면 종료 코드 1).
## 디스크를 쓰지 않는다(data/ja_sounds.json 읽기만). 네트워크 없음.

var passed: int = 0
var failed: int = 0


func ok(cond: bool, name: String) -> void:
	if cond:
		passed += 1
		print("  PASS  ", name)
	else:
		failed += 1
		print("  FAIL  ", name)


func _ready() -> void:
	print("== ja_sounds start ==")
	JaSounds.data_path = JaSounds.DATA_PATH
	JaSounds.clear_cache()
	_test_events_table()
	_test_events_shape()
	_test_events_bad_input()
	_test_annotate()
	_test_annotate_bad()
	_test_session()
	_test_selfchecks()
	JaSounds.clear_cache()
	print("== ja_sounds: %d passed, %d failed ==" % [passed, failed])
	get_tree().quit(1 if failed > 0 else 0)


# ---------------------------------------------------------------- helpers

## 읽기 reading 의 events 가 has 의 [cat, i] 를 전부 갖고, none 의 항목은 하나도 없는가.
## none 항목 [cat, -1] 은 "그 카테고리는 어디에도 없다", [cat, i] 는 "그 자리에는 없다".
func check_events(reading: String, has: Array, none: Array) -> bool:
	var evs: Array = JaSounds.events(reading)
	for h in has:
		var found := false
		for e in evs:
			if str(e["cat"]) == str(h[0]) and int(e["i"]) == int(h[1]):
				found = true
		if not found:
			return false
	for n in none:
		for e in evs:
			if str(e["cat"]) == str(n[0]) and (int(n[1]) < 0 or int(e["i"]) == int(n[1])):
				return false
	return true


# ---------------------------------------------------------------- events

func _test_events_table() -> void:
	print("[events table]")
	var L := "j_long"
	var S := "j_sokuon"
	var V := "j_voice"
	var T := "j_tsu"
	var Z := "j_za"
	var Y := "j_youon"
	var rows: Array = [
		["おばあさん", [[L, 2]], [[S, -1], [Y, -1]]],
		["おとうさん", [[L, 2]], [[S, -1]]],
		["せんせい", [[L, 3]], [[S, -1]]],
		["きって", [[S, 1]], [[L, -1]]],
		["がっこう", [[V, 0], [S, 1], [L, 3]], [[T, -1]]],
		["つき", [[T, 0]], [[L, -1], [S, -1]]],
		["ざっし", [[V, 0], [Z, 0], [S, 1]], [[L, -1]]],
		["じゃがいも", [[Z, 0], [V, 1], [Y, 0]], [[L, -1]]],
		["びょういん", [[Y, 0], [L, 1]], [[L, 2], [S, -1]]],
		["おばさん", [[V, 1]], [[L, -1]]],
		["かんこく", [[V, 0]], [[S, -1]]],
		["ありがとう", [[L, 4], [V, 2]], [[S, -1]]],
		["ええ", [[L, 1]], [[V, -1]]],
		["おおきい", [[L, 1], [L, 3]], [[S, -1]]],
		["こうこう", [[L, 1], [L, 3]], [[S, -1]]],
		["ゆうき", [[L, 1], [V, 2]], [[S, -1]]],
		["ゆき", [[V, 1]], [[L, -1]]],
		["すずしい", [[T, 0], [T, 1], [Z, 1], [L, 3]], [[S, -1]]],
		["ちず", [[Z, 1], [T, 1], [V, 0]], [[L, -1]]],
		["きゃく", [[Y, 0], [V, 0], [V, 1]], [[L, -1], [S, -1]]],
		["しゅみ", [[Y, 0]], [[L, -1], [S, -1]]],
		["きよう", [[L, 2]], [[Y, -1]]],
		["サッカー", [[S, 1], [L, 3], [V, 0]], [[Y, -1]]],
		["ぱん", [[V, 0]], [[S, -1], [L, -1]]],
		["ふうせん", [[L, 1], [V, 0]], [[S, -1]]],
		["とけい", [[L, 2]], [[S, -1]]],
		["たいへん", [[V, 0]], [[L, -1]]],
		["おいしい", [[L, 3]], [[L, 1]]],
		["ぜひ", [[Z, 0], [V, 0]], [[L, -1]]],
		["おばーさん", [[L, 2], [V, 1]], [[S, -1]]],
		["きょうしつ", [[Y, 0], [L, 1], [V, 2]], [[S, -1]]],
	]
	var n_ok := 0
	for r in rows:
		var good: bool = check_events(r[0], r[1], r[2])
		ok(good, "events(%s)" % r[0])
		if good:
			n_ok += 1
	print("events rows: %d (ok %d)" % [rows.size(), n_ok])
	ok(rows.size() >= 25, "events table has >= 25 rows (%d)" % rows.size())


func _test_events_shape() -> void:
	print("[events shape]")
	var evs: Array = JaSounds.events("おばあさん")
	var long_ev: Dictionary = {}
	for e in evs:
		if e["cat"] == "j_long":
			long_ev = e
	ok(not long_ev.is_empty() and long_ev["i"] == 2 and long_ev["mora"] == "あ", "long event is {cat, i, mora} = j_long / 2 / あ")
	# 모라 번호 순
	var sorted_ok := true
	var last := -1
	for e in JaSounds.events("がっこうじゃがいも"):
		if int(e["i"]) < last:
			sorted_ok = false
		last = int(e["i"])
	ok(sorted_ok, "events come in mora order")
	# 같은 모라가 여러 카테고리에 걸린다 (ざ: voice + za)
	var cats_at_0: Array = []
	for e in JaSounds.events("ざっし"):
		if int(e["i"]) == 0:
			cats_at_0.append(e["cat"])
	ok(cats_at_0.has("j_voice") and cats_at_0.has("j_za"), "one mora can carry several categories (ざ = voice + za)")
	# 작은 가나는 앞 글자에 붙어 한 모라: じゃ = 모라 0, が = 모라 1
	var ja_mora := ""
	for e in JaSounds.events("じゃがいも"):
		if e["cat"] == "j_youon":
			ja_mora = str(e["mora"])
	ok(ja_mora == "じゃ", "small kana joins the previous kana into one mora (じゃ)")
	# 가타카나·ー·쉼표
	ok(check_events("オバーサン", [["j_long", 2]], []), "katakana input is read as hiragana (ー = long)")
	ok(check_events("おばあさん、", [["j_long", 2]], []), "punctuation is not counted as a mora")
	ok(check_events("お ば あ さ ん", [["j_long", 2]], []), "spaces are not counted as moras")
	ok(JaSounds.is_category("j_long") and not JaSounds.is_category("en") and not JaSounds.is_category(""), "is_category")


func _test_events_bad_input() -> void:
	print("[events bad input]")
	var bad: Array = ["", "   ", "abc", "한국어", "漢字", "おばaさん", "あ1", "hello world", "。", "、、", "𠮷"]
	for b in bad:
		ok(JaSounds.events(b).is_empty(), "events(%s) = []" % [b])
	ok(JaSounds.events(null).is_empty(), "events(null) = []")
	ok(JaSounds.events(123).is_empty(), "events(123) = []")
	ok(JaSounds.events(["あ"]).is_empty(), "events(array) = []")
	ok(JaSounds.events("あ".repeat(500)).is_empty(), "events of a 500-mora string = [] (length limit)")
	print("selfcheck FAIL-as-expected events: bad inputs return [] (" + str(bad.size() + 4) + " cases)")


# ---------------------------------------------------------------- annotate

## /score 응답 모양(일본어): 읽기 "おばあさん" 의 발음형 오バーサン
func ja_res(ts: Array, oks: Array, heards: Array = []) -> Dictionary:
	var units: Array = []
	for i in ts.size():
		units.append({"t": ts[i], "ok": oks[i], "conf": 0.5 if oks[i] else 0.0, "heard": (heards[i] if i < heards.size() else null)})
	return {"transcript": "おばあさん", "score": 70, "accuracy": 70, "clarity": 70, "fluency": 70, "units": units, "tips_ko": []}


func ph_of(res: Dictionary, i: int) -> Array:
	var u: Dictionary = res["units"][i]
	return u.get("ph", [])


func has_ph(res: Dictionary, i: int, p: String, good: bool) -> bool:
	for e in ph_of(res, i):
		if e["p"] == p and e["ok"] == good:
			return true
	return false


func _test_annotate() -> void:
	print("[annotate]")
	var res: Dictionary = ja_res(["お", "ば", "ー", "さ", "ん"], [true, true, false, true, true], [null, null, "あ", null, null])
	var n: int = JaSounds.annotate(res)
	# ば(voice) ー(long) さ(voice) -> 3
	ok(n == 3, "annotate attaches 3 results to おばーさん (got %d)" % n)
	ok(has_ph(res, 2, "j_long", false), "the missed ー is a wrong j_long")
	var heard_ok := false
	for e in ph_of(res, 2):
		if e["p"] == "j_long" and e["heard"] == "あ":
			heard_ok = true
	ok(heard_ok, "heard of the unit is carried to the ph entry")
	ok(has_ph(res, 1, "j_voice", true) and has_ph(res, 3, "j_voice", true), "voice moras are marked ok")
	ok(ph_of(res, 0).is_empty() and ph_of(res, 4).is_empty(), "moras without a sound category get no ph")
	var n2: int = JaSounds.annotate(res)
	var total := 0
	for u in res["units"]:
		total += (u.get("ph", []) as Array).size()
	ok(n2 == n and total == n, "annotate twice: same count (%d) and no duplicates (%d entries)" % [n2, total])
	# 발음형이 아닌 읽기형(あ) 도 같은 자리를 잡는다
	var res2: Dictionary = ja_res(["お", "ば", "あ", "さ", "ん"], [true, true, true, true, true])
	ok(JaSounds.annotate(res2) == 3 and has_ph(res2, 2, "j_long", true), "reading-form あ is a long vowel too")
	# 가타카나 t
	var res3: Dictionary = ja_res(["オ", "バ", "ー", "サ", "ン"], [true, true, true, true, true])
	ok(JaSounds.annotate(res3) == 3 and has_ph(res3, 2, "j_long", true), "katakana t works")
	# 작은 가나 유닛: じゃ = za + voice + youon
	var res4: Dictionary = ja_res(["じゃ", "が"], [false, true])
	var n4: int = JaSounds.annotate(res4)
	ok(n4 == 4 and has_ph(res4, 0, "j_za", false) and has_ph(res4, 0, "j_youon", false) and has_ph(res4, 0, "j_voice", false), "じゃ unit: za + youon + voice (count %d)" % n4)
	# 이미 있는 다른 ph(엔진이 붙인 것)는 보존, 이 코어 항목만 다시 만든다
	var res5: Dictionary = ja_res(["つ", "き"], [true, true])
	(res5["units"][0] as Dictionary)["ph"] = [{"p": "x1", "ok": true}, {"p": "j_tsu", "ok": false}]
	var n5: int = JaSounds.annotate(res5)
	var u0: Array = ph_of(res5, 0)
	var n_x1 := 0
	var n_tsu := 0
	var tsu_ok := false
	for e in u0:
		if e["p"] == "x1":
			n_x1 += 1
		if e["p"] == "j_tsu":
			n_tsu += 1
			tsu_ok = bool(e["ok"])
	ok(n5 >= 1 and n_x1 == 1 and u0[0]["p"] == "x1" and n_tsu == 1 and tsu_ok, "foreign ph kept first, own old entry replaced (not duplicated): %s" % str(u0))
	# ok 가 bool 이 아닌 유닛은 건너뛴다
	var res6: Dictionary = ja_res(["つ", "ず"], [true, true])
	(res6["units"][0] as Dictionary)["ok"] = "yes"
	var n6: int = JaSounds.annotate(res6)
	ok(ph_of(res6, 0).is_empty() and not ph_of(res6, 1).is_empty() and n6 >= 1, "a unit whose ok is not a bool is skipped, the others are annotated")


func _test_annotate_bad() -> void:
	print("[annotate bad input]")
	var en: Dictionary = {"transcript": "hello", "score": 80, "units": [{"t": "h", "ok": true, "ph": [{"p": "h", "ok": true}]}, {"t": "ɛ", "ok": false}]}
	var en_before: Dictionary = en.duplicate(true)
	ok(JaSounds.annotate(en) == 0 and en == en_before, "English response (t is not kana): 0 and unchanged")
	var word: Dictionary = {"units": [{"t": "hello", "ok": true}]}
	var word_before: Dictionary = word.duplicate(true)
	ok(JaSounds.annotate(word) == 0 and word == word_before, "units with Latin words: 0 and unchanged")
	var mixed: Dictionary = ja_res(["お", "x", "あ"], [true, true, true])
	var mixed_before: Dictionary = mixed.duplicate(true)
	ok(JaSounds.annotate(mixed) == 0 and mixed == mixed_before, "one non-kana t makes the whole response untouched")
	var kanji: Dictionary = {"units": [{"t": "家", "ok": true}]}
	ok(JaSounds.annotate(kanji) == 0 and (kanji["units"][0] as Dictionary).size() == 2, "kanji t: 0, unchanged")
	var empty_t: Dictionary = {"units": [{"t": "", "ok": true}]}
	ok(JaSounds.annotate(empty_t) == 0, "empty t: 0")
	ok(JaSounds.annotate({}) == 0 and JaSounds.annotate({"units": []}) == 0 and JaSounds.annotate({"units": "x"}) == 0, "no units / empty units / units not an array: 0")
	ok(JaSounds.annotate(null) == 0 and JaSounds.annotate("あ") == 0 and JaSounds.annotate([1]) == 0 and JaSounds.annotate(5) == 0, "not a dictionary: 0")
	var notdict: Dictionary = {"units": [1, "あ", null]}
	var nd_before: Dictionary = notdict.duplicate(true)
	ok(JaSounds.annotate(notdict) == 0 and notdict == nd_before, "units that are not dictionaries: 0 and unchanged")
	var punct: Dictionary = {"units": [{"t": "あ、", "ok": true}]}
	ok(JaSounds.annotate(punct) == 0, "a t with punctuation: 0")
	print("selfcheck FAIL-as-expected annotate: 10 bad responses return 0 and are not changed")


# ---------------------------------------------------------------- 듣고 고르기

func _test_session() -> void:
	print("[listen session]")
	var d: Dictionary = JaSounds.load_data()
	ok(bool(d["ok"]), "data/ja_sounds.json loads")
	var cats_with_pairs := 0
	for p in JaSounds.CATEGORIES:
		var c: Dictionary = JaSounds.category(p)
		if c.is_empty():
			continue
		var pairs: Array = c["pairs"]
		if pairs.is_empty():
			continue
		cats_with_pairs += 1
		var rng := RandomNumberGenerator.new()
		rng.seed = 12345
		var s: Array = JaSounds.build_listen_session(p, rng, 10)
		var shape_ok: bool = s.size() == 10
		var answer_ok := true
		var distinct_first_lap := true
		var seen := {}
		for i in s.size():
			var it: Dictionary = s[i]
			var opts: Array = it["options"]
			if opts.size() != 2 or opts[0]["w"] == opts[1]["w"]:
				shape_ok = false
				continue
			var pair: Dictionary = it["pair"]
			var played: String = str(pair["a"]) if it["play"] == "a" else str(pair["b"])
			if str(opts[int(it["answer"])]["w"]) != played:
				answer_ok = false
			for k in ["w", "rd", "ko"]:
				if not (opts[0].has(k) and opts[1].has(k)):
					shape_ok = false
			if i < pairs.size():
				var key: String = str(pair["a"]) + "|" + str(pair["b"])
				if seen.has(key):
					distinct_first_lap = false
				seen[key] = true
		ok(shape_ok, "%s: 10 questions, 2 different options each" % p)
		ok(answer_ok, "%s: answer index points at the played word" % p)
		ok(distinct_first_lap, "%s: no pair repeats within one lap (%d pairs)" % [p, pairs.size()])
		# 같은 시드 = 같은 결과
		var rng2 := RandomNumberGenerator.new()
		rng2.seed = 12345
		ok(JaSounds.build_listen_session(p, rng2, 10) == s, "%s: same seed gives the same session" % p)
	ok(cats_with_pairs >= 5, "at least 5 categories have pairs (%d)" % cats_with_pairs)
	# 정답 자리와 재생 쪽이 치우치지 않는다 (200문항)
	var rngb := RandomNumberGenerator.new()
	rngb.seed = 7
	var s2: Array = JaSounds.build_listen_session("j_long", rngb, 200)
	var a0 := 0
	var pa := 0
	for it in s2:
		if int(it["answer"]) == 0:
			a0 += 1
		if it["play"] == "a":
			pa += 1
	ok(s2.size() == 200 and a0 > 60 and a0 < 140 and pa > 60 and pa < 140, "answer position and played side are mixed (answer 0: %d, play a: %d of 200)" % [a0, pa])
	# n 이 쌍 수보다 많아도 순환 (j_long 12쌍, n=30)
	var rngc := RandomNumberGenerator.new()
	rngc.seed = 3
	var s3: Array = JaSounds.build_listen_session("j_long", rngc, 30)
	ok(s3.size() == 30, "n larger than the number of pairs cycles (30 questions)")
	var no_rep_edge := true
	for i in range(1, s3.size()):
		if (s3[i]["pair"] as Dictionary)["a"] == (s3[i - 1]["pair"] as Dictionary)["a"]:
			no_rep_edge = false
	ok(no_rep_edge, "the same pair never comes twice in a row, also across laps")
	# rng null 도 동작
	ok(JaSounds.build_listen_session("j_tsu", null, 4).size() == 4, "rng = null is accepted")
	# 기본 n = 10
	var rngd := RandomNumberGenerator.new()
	rngd.seed = 1
	ok(JaSounds.build_listen_session("j_voice", rngd).size() == JaSounds.SESSION_N, "default n is SESSION_N (10)")


# ---------------------------------------------------------------- 틀린 입력

func _test_selfchecks() -> void:
	print("[selfchecks: wrong inputs must be judged wrong]")
	# 1) check_events 가 틀린 기대를 FAIL 로 판정한다
	var wrong_cases: Array = [
		["おばさん", [["j_long", 2]], []],            # おばさん 에는 장음이 없다
		["きって", [["j_sokuon", 0]], []],             # 촉음 자리는 1
		["かんこく", [["j_sokuon", 1]], []],           # 촉음이 없다
		["おばあさん", [["j_long", 3]], []],           # 장음 자리는 2
		["おばあさん", [], [["j_long", 2]]],           # 있는 것을 "없다" 로 단언
		["つき", [["j_za", 0]], []],                   # つ 는 za 가 아니다
	]
	for w in wrong_cases:
		var judged_wrong: bool = not check_events(w[0], w[1], w[2])
		ok(judged_wrong, "selfcheck FAIL-as-expected: wrong expectation for %s is rejected" % w[0])
		print("selfcheck FAIL-as-expected events(%s): %s" % [w[0], "rejected" if judged_wrong else "ACCEPTED (bad)"])
	# 2) 잘못된 입력들
	ok(JaSounds.build_listen_session("nope", null, 10).is_empty(), "build_listen_session('nope') = []")
	ok(JaSounds.build_listen_session("", null, 10).is_empty(), "build_listen_session('') = []")
	ok(JaSounds.build_listen_session("j_long", null, 0).is_empty() and JaSounds.build_listen_session("j_long", null, -3).is_empty(), "n <= 0 = []")
	ok(JaSounds.category("nope").is_empty() and JaSounds.label_of("nope") == "nope", "unknown category: {} / label falls back to p")
	ok(JaSounds.label_of("j_long") != "j_long" and JaSounds.label_of("j_long") != "", "label_of(j_long) is the Korean label")
	# 3) 깨진 데이터 파일이어도 죽지 않는다
	var bad_path := "user://test_a2_bad_sounds.json"
	var f := FileAccess.open(bad_path, FileAccess.WRITE)
	f.store_string("{ not json ]]")
	f.close()
	JaSounds.data_path = bad_path
	JaSounds.clear_cache()
	var d: Dictionary = JaSounds.load_data()
	ok(d["ok"] == false and d["err"] == "bad" and (d["categories"] as Array).is_empty(), "broken JSON: ok=false, err=bad")
	ok(JaSounds.build_listen_session("j_long", null, 5).is_empty() and JaSounds.category("j_long").is_empty() and JaSounds.label_of("j_long") == "j_long", "broken data: session [] / category {} / label p (no crash)")
	JaSounds.data_path = "user://test_a2_missing_sounds.json"
	JaSounds.clear_cache()
	var d2: Dictionary = JaSounds.load_data()
	ok(d2["ok"] == false and d2["err"] == "missing", "missing file: ok=false, err=missing")
	print("selfcheck FAIL-as-expected load_data: broken -> err=%s, missing -> err=%s" % [d["err"], d2["err"]])
	DirAccess.remove_absolute(ProjectSettings.globalize_path(bad_path))
	JaSounds.data_path = JaSounds.DATA_PATH
	JaSounds.clear_cache()
	ok(bool(JaSounds.load_data()["ok"]), "real data loads again after the hook is restored")
