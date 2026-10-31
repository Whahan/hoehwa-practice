extends Node
## 가사 외우기 M2: MemoModel (memo.json 보정·줄 키·요약·오늘 큐). 서버·파일·마이크를 쓰지 않는다 (순수 함수 시험).
##   godot --headless --path <project> res://tests/memo_model_test.tscn
## Exit code 0 = all passed. Last line: "== memo_model_test result: N passed, 0 failed =="
## 가사는 tests/fixtures/song/lyrics_en.txt · lyrics_ja.txt (직접 쓴 문장, CC0) 와 이 파일의 직접 쓴 문장뿐이다.

const NOW := 1790000000
const DAY := 86400

var passed: int = 0
var failed: int = 0


func ok(cond: bool, name: String) -> void:
	if cond:
		passed += 1
		print("  PASS  ", name)
	else:
		failed += 1
		print("  FAIL  ", name)


func _fixture_lines(path: String) -> Array:
	var f := FileAccess.open(path, FileAccess.READ)
	var out: Array = []
	if f == null:
		return out
	var kept: PackedStringArray = []
	for ln in f.get_as_text().split("\n"):
		if not ln.strip_edges().begins_with("#"):
			kept.append(ln)
	f.close()
	for e in LrcParser.split_plain("\n".join(kept)):
		out.append(e["text"])
	return out


func _song(lang: String, texts: Array) -> Dictionary:
	var lines: Array = []
	for i in texts.size():
		lines.append({"i": i, "p": 0, "t0": 0.0, "t1": 0.0, "text": texts[i], "reading": "", "pron": "", "ko": ""})
	return {"v": 1, "kind": "lyrics", "lang": lang, "title": "T", "lines": lines}


func _card(due: int, state: int = 2) -> Dictionary:
	return {"due": due, "stability": 2.3, "difficulty": 5.1, "state": state, "step": 0, "last_review": NOW - DAY, "reps": 2, "lapses": 0}


func _memo_with(entries: Dictionary) -> Dictionary:
	var m := MemoModel.new_memo()
	for k in entries.keys():
		m["lines"][k] = entries[k]
	return m


func _hexkey(n: int) -> String:
	return "%012x" % n


func _ready() -> void:
	print("== memo_model_test start ==")
	_test_new_and_basic()
	_test_normalize_bad()
	_test_cards()
	_test_cap()
	_test_line_key()
	_test_is_memo_line()
	_test_keys_of()
	_test_summary()
	_test_queue()
	_test_prune()
	_test_purity()
	ok(true, "ran to the end of every section")
	print("== memo_model_test result: %d passed, %d failed ==" % [passed, failed])
	get_tree().quit(1 if failed > 0 else 0)


func _test_new_and_basic() -> void:
	print("[new memo and a valid memo]")
	var m := MemoModel.new_memo()
	ok(m["v"] == 1 and m["lines"] is Dictionary and m["lines"].is_empty() and m["stats"]["sessions"] == 0 and m["stats"]["last"] == 0, "new_memo: v 1, no lines, zero stats")
	ok(JSON.stringify(MemoModel.normalize(m, NOW)) == JSON.stringify(m), "normalize(new_memo) is unchanged")
	var raw := {"v": 1, "lines": {"a1b2c3d4e5f6": {"stage": 2, "seen": 1790000500, "tries": 7, "passes": 4,
		"card": {"due": 1790086400, "stability": 2.3, "difficulty": 5.1, "state": 2, "step": 0, "last_review": 1790000500, "reps": 2, "lapses": 0}}},
		"stats": {"sessions": 3, "last": 1790000500}, "app": "1.4.0"}
	var n: Dictionary = MemoModel.normalize(raw, NOW)
	ok(JSON.stringify(n) == JSON.stringify(raw), "a valid memo (the contract example) passes through unchanged")
	var again: Dictionary = MemoModel.normalize(JSON.parse_string(JSON.stringify(n)), NOW)
	ok(JSON.stringify(again) == JSON.stringify(n), "JSON round trip (numbers come back as floats): same result")
	ok(not MemoModel.is_read_only(n), "v 1 is not read-only")
	var before := JSON.stringify(raw)
	MemoModel.normalize(raw, NOW)
	ok(JSON.stringify(raw) == before, "normalize does not change its input")
	ok(MemoModel.normalize(null, NOW) == MemoModel.new_memo() and MemoModel.normalize([1, 2], NOW) == MemoModel.new_memo() and MemoModel.normalize("x", NOW) == MemoModel.new_memo(), "null / array / string -> a new memo")


func _test_normalize_bad() -> void:
	print("[normalize: bad keys, numbers, versions]")
	var good := _hexkey(0xabc123)
	var raw := {"v": 5, "lines": {
		good: {"stage": 3, "seen": 100, "tries": 1, "passes": 1},
		"short": {"stage": 1},
		"A1B2C3D4E5F6": {"stage": 1},
		"a1b2c3d4e5fg": {"stage": 1},
		"0123456789abc": {"stage": 1},
		"bbbbbbbbbbbb": "not a dict",
		"cccccccccccc": 7,
		5: {"stage": 1}},
		"stats": {"sessions": "x", "last": -4, "extra": 1}, "unknown": {"x": 1}, "app": "a\u0001b"}
	var n: Dictionary = MemoModel.normalize(raw, NOW)
	ok(n["v"] == 5 and MemoModel.is_read_only(n), "v:5 -> kept as 5 and marked read-only")
	ok(n["lines"].keys() == [good], "only 12-hex lower-case keys with a dictionary value are kept: %s" % [n["lines"].keys()])
	ok(not n.has("unknown") and n.keys().size() == 4, "unknown top-level keys dropped")
	ok(n["stats"]["sessions"] == 0 and n["stats"]["last"] == 0 and n["stats"].keys().size() == 2, "stats: non-number -> 0, negative -> 0, unknown key dropped")
	ok(n["app"] == "ab", "control characters removed from app")
	var e: Dictionary = MemoModel.normalize({"lines": {good: {"stage": 99, "seen": -5, "tries": 9.9e30, "passes": "7", "junk": 1}}}, NOW)["lines"][good]
	ok(e["stage"] == 8 and e["seen"] == 0 and e["tries"] == 1000000000 and e["passes"] == 0 and e.keys().size() == 4 and not e.has("card"), "entry: stage <= 8, negative seen 0, huge count capped, string -> 0, unknown key dropped")
	var e2: Dictionary = MemoModel.normalize({"lines": {good: {"stage": NAN, "seen": INF, "tries": -INF}}}, NOW)["lines"][good]
	ok(e2["stage"] == 0 and e2["seen"] == 0 and e2["tries"] == 0, "NaN / inf in numbers -> 0")
	ok(MemoModel.normalize({"v": "x"}, NOW)["v"] == 1 and MemoModel.normalize({"v": 0}, NOW)["v"] == 1 and MemoModel.normalize({"v": -3}, NOW)["v"] == 1, "v not a positive integer -> 1")
	ok(MemoModel.normalize({"lines": [1, 2, 3], "stats": 5}, NOW) == MemoModel.new_memo(), "lines / stats of the wrong type -> empty")


func _test_cards() -> void:
	print("[normalize: cards]")
	var k := _hexkey(0x1234567890ab)
	var base := {"due": NOW + DAY, "stability": 2.3, "difficulty": 5.1, "state": 2, "step": 0, "last_review": NOW, "reps": 2, "lapses": 0}
	var c: Dictionary = MemoModel.normalize({"lines": {k: {"card": base}}}, NOW)["lines"][k].get("card", {})
	ok(JSON.stringify(c) == JSON.stringify(base), "a valid card is kept as it is")
	var as_float := base.duplicate()
	as_float["state"] = 2.0
	as_float["due"] = float(NOW + DAY)
	as_float["reps"] = 2.0
	var c2: Dictionary = MemoModel.normalize({"lines": {k: {"card": as_float}}}, NOW)["lines"][k].get("card", {})
	ok(c2.get("state") is int and c2.get("due") is int and c2.get("reps") is int and c2["state"] == 2 and c2["due"] == NOW + DAY, "float state / due / reps (from JSON) become integers")
	var bad_cards := {
		"string stability": {"stability": "2.3"},
		"string due": {"due": "soon"},
		"NaN stability": {"stability": NAN},
		"inf difficulty": {"difficulty": INF},
		"negative stability": {"stability": -1.0},
		"negative difficulty": {"difficulty": -0.5},
		"state 9": {"state": 9},
		"state 0": {"state": 0},
		"state string": {"state": "2"},
		"string reps": {"reps": "many"},
		"NaN lapses": {"lapses": NAN},
		"review with stability 0": {"stability": 0.0},
		"review with difficulty 0": {"difficulty": 0.0},
		"state null": {"state": null},
	}
	for name in bad_cards.keys():
		var cc := base.duplicate()
		for kk in bad_cards[name].keys():
			cc[kk] = bad_cards[name][kk]
		var ent: Dictionary = MemoModel.normalize({"lines": {k: {"stage": 4, "card": cc}}}, NOW)["lines"][k]
		ok(not ent.has("card") and ent["stage"] == 4, "bad card dropped (new line), the entry stays: %s" % name)
	var no_due := base.duplicate()
	no_due.erase("due")
	ok(not MemoModel.normalize({"lines": {k: {"card": no_due}}}, NOW)["lines"][k].has("card"), "card without due -> dropped")
	ok(not MemoModel.normalize({"lines": {k: {"card": [1, 2]}}}, NOW)["lines"][k].has("card") and not MemoModel.normalize({"lines": {k: {"card": "x"}}}, NOW)["lines"][k].has("card"), "card that is not a dictionary -> dropped")
	var learning := {"due": NOW + 60, "stability": 0.0, "difficulty": 0.0, "state": 1, "step": 0, "last_review": 0, "reps": 0, "lapses": 0}
	ok(MemoModel.normalize({"lines": {k: {"card": learning}}}, NOW)["lines"][k].has("card"), "a fresh learning card (stability 0, state 1) is valid")
	var odd := base.duplicate()
	odd["step"] = -3
	odd["reps"] = -1
	odd["last_review"] = -9
	odd["lapses"] = 1.0e30
	odd["stability"] = 1.0e30
	var c3: Dictionary = MemoModel.normalize({"lines": {k: {"card": odd}}}, NOW)["lines"][k]["card"]
	ok(c3["step"] == 0 and c3["reps"] == 0 and c3["last_review"] == 0 and c3["lapses"] == 1000000000 and c3["stability"] <= MemoModel.MAX_STABILITY, "out-of-range card numbers are clamped (negative -> 0, huge -> limit)")
	var only_extra := base.duplicate()
	only_extra["sneaky"] = 1
	ok(not MemoModel.normalize({"lines": {k: {"card": only_extra}}}, NOW)["lines"][k]["card"].has("sneaky"), "unknown card keys dropped")


func _test_cap() -> void:
	print("[normalize: at most 400 lines]")
	var lines := {}
	for i in 401:
		lines[_hexkey(i + 1)] = {"stage": 1, "seen": 1000 + i}
	var n: Dictionary = MemoModel.normalize({"lines": lines}, NOW)
	ok(n["lines"].size() == 400, "401 entries -> 400")
	ok(not n["lines"].has(_hexkey(1)) and n["lines"].has(_hexkey(2)) and n["lines"].has(_hexkey(401)), "the entry with the oldest seen was removed")
	var same := {}
	for i in 405:
		same[_hexkey(i + 1)] = {"stage": 1, "seen": 50}
	var n2: Dictionary = MemoModel.normalize({"lines": same}, NOW)
	ok(n2["lines"].size() == 400 and n2["lines"].has(_hexkey(1)) and not n2["lines"].has(_hexkey(405)), "equal seen: the larger keys are dropped (deterministic)")
	ok(JSON.stringify(MemoModel.normalize({"lines": same}, NOW)) == JSON.stringify(n2), "same input, same result")
	var exact := {}
	for i in 400:
		exact[_hexkey(i + 1)] = {"stage": 0}
	ok(MemoModel.normalize({"lines": exact}, NOW)["lines"].size() == 400, "exactly 400 entries are all kept")


func _test_line_key() -> void:
	print("[line_key]")
	var a: String = MemoModel.line_key("The kettle hums.", "en")
	ok(a.length() == 12 and a == MemoModel.line_key("the KETTLE hums", "en"), "case and punctuation do not change the key")
	ok(a != MemoModel.line_key("The kettle sings", "en"), "a different line has a different key")
	ok(MemoModel.line_key("The kettle hums while the morning climbs the wall", "en") == "b31986e944f0", "pinned key (sha256 of the normalized text, first 12 hex)")
	ok(MemoModel.line_key("Nobody calls, so the quiet stays small", "en") == "4bccd3fcce44" and MemoModel.line_key("I count my steps to the old blue chair", "en") == "cbd555846420", "two more pinned keys")
	ok(MemoModel.line_key("  The   kettle \t hums!! ", "en") == a, "extra spaces and marks ignored")
	var ja: String = MemoModel.line_key("朝の窓辺で小さなやかんが鳴る", "ja")
	ok(ja == "cb1bf481ca91" and ja == MemoModel.line_key("朝の窓辺で、小さな やかんが鳴る。", "ja"), "ja: pinned key, punctuation and spaces ignored")
	ok(MemoModel.line_key("...", "en") == "" and MemoModel.line_key("   ", "en") == "" and MemoModel.line_key("", "ja") == "" and MemoModel.line_key("、。！", "ja") == "", "only marks / spaces -> empty key")
	ok(MemoModel.line_key(5, "en") == "" and MemoModel.line_key(null, "en") == "", "not a string -> empty key")
	ok(MemoModel.line_key("hello", "fr") == MemoModel.line_key("hello", "en"), "unknown language is treated like en")
	ok(MemoModel.is_valid_key(a) and not MemoModel.is_valid_key("") and not MemoModel.is_valid_key(a.to_upper()) and not MemoModel.is_valid_key(5), "keys it makes are valid keys")


func _test_is_memo_line() -> void:
	print("[is_memo_line]")
	ok(MemoModel.is_memo_line({"text": "The kettle hums"}, "en") and MemoModel.is_memo_line("The kettle hums", "en"), "an ordinary line (dictionary or string)")
	ok(not MemoModel.is_memo_line({"text": "[Chorus]"}, "en") and not MemoModel.is_memo_line({"text": "  [Verse 2] "}, "en"), "[Chorus] style section marks are not lines")
	ok(MemoModel.is_memo_line({"text": "[la] la la"}, "en"), "a line that only starts with a bracket is still a line")
	for t in ["", "   ", "...", "♪♪", "-", "'", "!!!"]:
		ok(not MemoModel.is_memo_line({"text": t}, "en"), "not a line (en): `%s`" % t)
	for t in ["♪♪", "、。", "・・・"]:
		ok(not MemoModel.is_memo_line({"text": t}, "ja"), "not a line (ja): `%s`" % t)
	ok(MemoModel.is_memo_line({"text": "あ"}, "ja") and MemoModel.is_memo_line({"text": "ララ♪"}, "ja"), "ja: a single kana / kana with a note is a line")
	ok(not MemoModel.is_memo_line({}, "en") and not MemoModel.is_memo_line({"text": 5}, "en") and not MemoModel.is_memo_line(null, "en") and not MemoModel.is_memo_line(7, "en"), "no text / not a string / null -> false (no error)")
	ok(MemoModel.is_memo_line({"text": "42"}, "en"), "digits count as letters")


func _test_keys_of() -> void:
	print("[keys_of]")
	var en: Array = _fixture_lines("res://tests/fixtures/song/lyrics_en.txt")
	ok(en.size() == 6, "lyrics_en.txt gives 6 lines")
	var song := _song("en", en)
	var ks: Array = MemoModel.keys_of(song)
	ok(ks.size() == 6 and ks[0]["i"] == 0 and ks[5]["i"] == 5 and ks[0]["key"] == "b31986e944f0", "6 keys in song order with their line numbers")
	var rep: Array = en.duplicate()
	rep.append(en[0])
	rep.insert(1, en[0].to_upper() + "!")
	rep.append("[Chorus]")
	rep.append("♪♪")
	rep.append("")
	var ks2: Array = MemoModel.keys_of(_song("en", rep))
	ok(ks2.size() == 6, "the same line three times (case / marks differ) counts once; [Chorus], ♪♪ and an empty line are left out (%d)" % ks2.size())
	ok(ks2[0]["i"] == 0 and ks2[1]["i"] == 2, "a repeated line keeps its first position (the next key is at 2)")
	ok(MemoModel.keys_of({}).is_empty() and MemoModel.keys_of({"lines": "x"}).is_empty() and MemoModel.keys_of({"lines": [1, "a", null]}).is_empty(), "no lines / junk lines -> empty")
	var ja: Array = _fixture_lines("res://tests/fixtures/song/lyrics_ja.txt")
	ok(ja.size() == 5 and MemoModel.keys_of(_song("ja", ja)).size() == 5 and MemoModel.keys_of(_song("ja", ja))[0]["key"] == "cb1bf481ca91", "lyrics_ja.txt: 5 keys")


func _summary_song() -> Dictionary:
	return _song("en", _fixture_lines("res://tests/fixtures/song/lyrics_en.txt"))


func _test_summary() -> void:
	print("[summary]")
	var song := _summary_song()
	var ks: Array = MemoModel.keys_of(song)
	var s0: Dictionary = MemoModel.summary(song, MemoModel.new_memo(), NOW)
	ok(s0 == {"total": 6, "memorized": 0, "learning": 0, "fresh": 6, "due": 0, "next_due": 0}, "no records: 6 fresh")
	var memo := _memo_with({
		ks[0]["key"]: {"stage": 8, "seen": NOW, "card": _card(NOW + 5 * DAY, 2)},
		ks[1]["key"]: {"stage": 8, "seen": NOW, "card": _card(NOW - 100, 2)},
		ks[2]["key"]: {"stage": 8, "seen": NOW, "card": _card(NOW - 5, 1)},
		ks[3]["key"]: {"stage": 8, "seen": NOW, "card": _card(NOW + 600, 3)},
		ks[4]["key"]: {"stage": 3, "seen": NOW},
	})
	var s: Dictionary = MemoModel.summary(song, memo, NOW)
	ok(s["total"] == 6 and s["memorized"] == 2 and s["learning"] == 2 and s["fresh"] == 2, "state 2 -> memorized (2), state 1 and 3 -> learning (2), no card (a saved stage only) -> fresh (2)")
	ok(s["due"] == 2, "due counts cards with due <= now of any state (2)")
	ok(s["next_due"] == NOW + 600, "next_due is the earliest due in the future (600 s)")
	ok(MemoModel.summary(song, memo, NOW + 10 * DAY)["due"] == 4 and MemoModel.summary(song, memo, NOW + 10 * DAY)["next_due"] == 0, "ten days later every card is due and none is upcoming")
	ok(MemoModel.summary(song, memo, NOW - 1)["due"] == 1 or MemoModel.summary(song, memo, NOW - 1)["due"] == 2, "a clock that went back does not throw")
	# the same line three times counts once
	var lines: Array = _fixture_lines("res://tests/fixtures/song/lyrics_en.txt")
	lines.append(lines[0])
	lines.append(lines[0].to_lower())
	lines.append("[Chorus]")
	var song2 := _song("en", lines)
	var s2: Dictionary = MemoModel.summary(song2, _memo_with({ks[0]["key"]: {"card": _card(NOW + DAY, 2)}}), NOW)
	ok(s2["total"] == 6 and s2["memorized"] == 1 and s2["fresh"] == 5, "a repeated chorus line counts once in total / memorized")
	ok(MemoModel.summary(song, {"v": 1, "lines": "junk"}, NOW)["fresh"] == 6, "a junk memo is handled like an empty one")
	ok(MemoModel.summary({}, memo, NOW) == {"total": 0, "memorized": 0, "learning": 0, "fresh": 0, "due": 0, "next_due": 0}, "no song: all zero")
	var bad_in: Dictionary = MemoModel.summary(song, _memo_with({ks[0]["key"]: {"card": {"due": "x", "state": 2, "stability": 1.0, "difficulty": 1.0}}}), NOW)
	ok(bad_in["fresh"] == 6 and bad_in["memorized"] == 0, "a broken card counts as a fresh line")


func _test_queue() -> void:
	print("[build_queue]")
	var song := _summary_song()
	var ks: Array = MemoModel.keys_of(song)
	var q0: Array = MemoModel.build_queue(song, MemoModel.new_memo(), NOW, {})
	ok(q0.size() == 5, "6 new lines -> 5 (new cap)")
	var order_ok := true
	for i in q0.size():
		if q0[i]["i"] != i or q0[i]["kind"] != "new" or q0[i]["key"] != ks[i]["key"]:
			order_ok = false
	ok(order_ok, "new lines come in song order with kind new")
	ok(MemoModel.build_queue(song, MemoModel.new_memo(), NOW, {"new_cap": 2}).size() == 2 and MemoModel.build_queue(song, MemoModel.new_memo(), NOW, {"new_cap": 99}).size() == 6, "new_cap is respected")
	var q_skip: Array = MemoModel.build_queue(song, MemoModel.new_memo(), NOW, {"skip_new": 2})
	ok(q_skip.size() == 4 and q_skip[0]["i"] == 2 and q_skip[3]["i"] == 5, "skip_new 2 skips the first two new lines (the next five would be 2..5)")
	ok(MemoModel.build_queue(song, MemoModel.new_memo(), NOW, {"skip_new": 99}).is_empty(), "skipping more than there are -> empty")
	# reviews first, oldest due first
	var memo := _memo_with({
		ks[3]["key"]: {"card": _card(NOW - 10, 2)},
		ks[1]["key"]: {"card": _card(NOW - 5000, 2)},
		ks[5]["key"]: {"card": _card(NOW - 300, 1)},
		ks[0]["key"]: {"card": _card(NOW + 100, 2)},
	})
	var q: Array = MemoModel.build_queue(song, memo, NOW, {})
	var rev: Array = []
	var news: Array = []
	for e in q:
		(rev if e["kind"] == "review" else news).append(e["i"])
	ok(rev == [1, 5, 3], "reviews: due <= now only, oldest due first: %s" % [rev])
	ok(news == [2, 4], "new lines: those with no card, in song order (the upcoming card at 0 is neither): %s" % [news])
	var kinds: Array = []
	for e in q:
		kinds.append(e["kind"])
	ok(kinds == ["review", "review", "review", "new", "new"], "order: reviews, then new")
	# caps with many reviews
	var many: Array = []
	for i in 30:
		many.append("Line number %d of the long test song goes here" % i)
	var big := _song("en", many)
	var bk: Array = MemoModel.keys_of(big)
	var entries := {}
	for i in 25:
		entries[bk[i]["key"]] = {"card": _card(NOW - 1000 + i, 2)}
	var qb: Array = MemoModel.build_queue(big, _memo_with(entries), NOW, {})
	var n_rev := 0
	var n_new := 0
	for e in qb:
		if e["kind"] == "review":
			n_rev += 1
		else:
			n_new += 1
	ok(qb.size() == 25 and n_rev == 20 and n_new == 5, "25 due + 5 new available -> 20 reviews + 5 new (%d + %d)" % [n_rev, n_new])
	ok(qb[0]["i"] == 0 and qb[19]["i"] == 19, "the 20 oldest reviews are kept")
	ok(MemoModel.build_queue(big, _memo_with(entries), NOW, {"review_cap": 3, "new_cap": 0}).size() == 3, "review_cap / new_cap override")
	# a repeated line is queued once
	var rep: Array = ["Alpha beta gamma", "alpha beta gamma!", "Delta epsilon", "ALPHA BETA GAMMA", "[Chorus]", "♪"]
	var qr: Array = MemoModel.build_queue(_song("en", rep), MemoModel.new_memo(), NOW, {})
	ok(qr.size() == 2 and qr[0]["i"] == 0 and qr[1]["i"] == 2, "same key twice -> once (first position); [Chorus] and ♪ never")
	# only_line
	var ol: Array = MemoModel.build_queue(song, memo, NOW, {"only_line": 4})
	ok(ol.size() == 1 and ol[0]["i"] == 4 and ol[0]["kind"] == "new", "only_line: just that line (new)")
	var ol2: Array = MemoModel.build_queue(song, memo, NOW, {"only_line": 0})
	ok(ol2.size() == 1 and ol2[0]["kind"] == "review", "only_line on a line with a card (not yet due) -> review")
	ok(MemoModel.build_queue(_song("en", rep), MemoModel.new_memo(), NOW, {"only_line": 4}).is_empty() and MemoModel.build_queue(song, memo, NOW, {"only_line": 99}).is_empty(), "only_line on [Chorus] / out of range -> empty")
	ok(MemoModel.build_queue({}, memo, NOW, {}).is_empty() and MemoModel.build_queue(song, MemoModel.new_memo(), NOW, {"review_cap": "x", "new_cap": null}).size() == 5, "no song -> empty; junk opts fall back to the defaults")


func _test_prune() -> void:
	print("[prune]")
	var song := _summary_song()
	var ks: Array = MemoModel.keys_of(song)
	var old_gone := _hexkey(0xdead01)
	var recent_gone := _hexkey(0xdead02)
	var memo := _memo_with({
		ks[0]["key"]: {"seen": 1},
		old_gone: {"seen": NOW - 31 * DAY},
		recent_gone: {"seen": NOW - 29 * DAY},
		_hexkey(0xdead03): {"seen": 0},
	})
	MemoModel.prune(memo, song, NOW)
	ok(memo["lines"].has(ks[0]["key"]), "a key of the song stays even when it is old")
	ok(not memo["lines"].has(old_gone) and not memo["lines"].has(_hexkey(0xdead03)), "keys not in the song and unseen for over 30 days (or never) are removed")
	ok(memo["lines"].has(recent_gone), "keys not in the song but seen within 30 days stay")
	var m2 := _memo_with({old_gone: {"seen": 5}})
	MemoModel.prune(m2, {}, NOW)
	MemoModel.prune(m2, {"lines": "x"}, NOW)
	ok(m2["lines"].has(old_gone), "no usable song: nothing is removed")
	var m3 := {"v": 1, "lines": 5}
	MemoModel.prune(m3, song, NOW)
	ok(m3["lines"] == 5, "a memo without a lines dictionary is left alone (no error)")


func _test_purity() -> void:
	print("[purity]")
	var src := FileAccess.get_file_as_string("res://scripts/core/memo_model.gd")
	var rx := RegEx.new()
	rx.compile("FileAccess|DirAccess|OS\\.|HTTPRequest|RandomNumberGenerator|randi|randf|Time\\.|StudyLog|SyncDoc|progress\\.json|prefs\\.json|Store\\.|Engine\\.")
	var code := PackedStringArray()
	for ln in src.split("\n"):
		if not ln.strip_edges().begins_with("#"):
			code.append(ln)
	var hits: Array = []
	for m in rx.search_all("\n".join(code)):
		hits.append(m.get_string())
	ok(src.length() > 3000 and hits.is_empty(), "memo_model.gd code: no file / network / clock / random / Store / StudyLog access %s" % [hits])
	# the detector itself: it must flag a source that does touch a file
	var bad_hits: Array = []
	for m in rx.search_all("var f = FileAccess.open(p, 1)\nvar t = Time.get_unix_time_from_system()"):
		bad_hits.append(m.get_string())
	ok(bad_hits.size() == 2, "control: the detector flags FileAccess / Time in a doctored source")
	var rx_ok := RegEx.new()
	rx_ok.compile("^[0-9a-f]{12}$")
	ok(rx_ok.search(MemoModel.line_key("The kettle hums", "en")) != null and rx_ok.search("A1B2C3D4E5F6") == null, "control: the key pattern accepts a real key and rejects upper case")
