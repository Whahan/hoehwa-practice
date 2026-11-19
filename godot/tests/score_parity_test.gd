extends Node
## PA2: ScoreCore (godot/scripts/core/score_core.gd) against backend/server.py score_en and its helpers.
##   godot --headless --path <project> res://tests/score_parity_test.tscn
##   godot --headless --path <project> --resolution 412x915 res://tests/score_parity_test.tscn -- --phone
##   ... -- --golden=<path>      read another golden file (the default is res://tests/fixtures/score_golden_en.json)
## Exit code 0 = all checks passed. Last line: "== score_parity_test: N passed, M failed =="
## Data: score_golden_en.json (written by phone_src/tools/make_score_golden.py from the server functions): "cases" (full score_en
## results, keys + values + key order), "align" (align_seq pairs / inserts, word_sim), "en_words", "known_gaps".
## No network, no user files.

const GOLDEN_DEFAULT := "res://tests/fixtures/score_golden_en.json"

var passed: int = 0
var failed: int = 0
var _fail_names: Array = []


func _ready() -> void:
	print("== score_parity_test start ==")
	var path: String = GOLDEN_DEFAULT
	for a in OS.get_cmdline_user_args():
		if String(a).begins_with("--golden="):
			path = String(a).substr(9)
	print("golden file: ", path.get_file())
	var g: Dictionary = _load_golden(path)
	ok(not g.is_empty(), "golden file parses")
	ok(float(g.get("v", 0)) == 1.0, "golden format version 1")
	ok(float(g.get("ok_prob", 0)) == ScoreCore.OK_PROB, "golden ok_prob == ScoreCore.OK_PROB (%s)" % [str(g.get("ok_prob"))])
	_test_rules()
	_test_cases(g)
	_test_align(g)
	_test_en_words(g)
	_test_maps()
	_test_defensive()
	_test_perf()
	_test_selfchecks(g)
	print("== score_parity_test: %d passed, %d failed ==" % [passed, failed])
	get_tree().quit(1 if failed > 0 else 0)


func ok(cond: bool, name: String) -> void:
	if cond:
		passed += 1
	else:
		failed += 1
		print("  FAIL  ", name)


func _load_golden(path: String) -> Dictionary:
	var f: FileAccess = FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	return parsed if parsed is Dictionary else {}


## Deep equality for the golden comparison: numbers compare by value (JSON has no int/float), a Dictionary must have the same
## keys IN THE SAME ORDER, bool is not a number. eps > 0 allows that much difference between two numbers.
static func same(a: Variant, b: Variant, eps: float = 0.0) -> bool:
	var ta: int = typeof(a)
	var tb: int = typeof(b)
	var a_num: bool = ta == TYPE_INT or ta == TYPE_FLOAT
	var b_num: bool = tb == TYPE_INT or tb == TYPE_FLOAT
	if a_num or b_num:
		if not (a_num and b_num):
			return false
		return absf(float(a) - float(b)) <= eps
	if ta != tb:
		return false
	if ta == TYPE_DICTIONARY:
		var da: Dictionary = a
		var db: Dictionary = b
		if da.size() != db.size():
			return false
		var ka: Array = da.keys()
		var kb: Array = db.keys()
		for i in ka.size():
			if ka[i] != kb[i]:
				return false
			if not same(da[ka[i]], db[kb[i]], eps):
				return false
		return true
	if ta == TYPE_ARRAY:
		var aa: Array = a
		var ab: Array = b
		if aa.size() != ab.size():
			return false
		for i in aa.size():
			if not same(aa[i], ab[i], eps):
				return false
		return true
	return a == b


## The rules with the expected values written out here (not read from the golden file).
func _test_rules() -> void:
	print("[rules written out]")
	ok(ScoreCore.en_words("") == [], "en_words('') is empty")
	ok(ScoreCore.en_words("Hello, World!") == ["hello", "world"], "lower case, punctuation dropped")
	ok(ScoreCore.en_words("I don't know") == ["i", "do", "not", "know"], "n't -> not")
	ok(ScoreCore.en_words("I'm it's let's can't") == ["i", "am", "it", "is", "let", "us", "can", "not"], "'m, 's after it, let's, can't")
	ok(ScoreCore.en_words("John's") == ["john"], "possessive 's is dropped")
	ok(ScoreCore.en_words("21") == ["twenty", "one"], "21 -> twenty one")
	ok(ScoreCore.en_words("100") == ["one", "hundred"], "100 -> one hundred")
	ok(ScoreCore.en_words("101") == ["one", "hundred", "and", "one"], "101 -> one hundred and one")
	ok(ScoreCore.en_words("1,234") == ["one", "thousand", "two", "hundred", "and", "thirty", "four"], "1,234: the comma goes, one thousand two hundred and thirty four")
	ok(ScoreCore.en_words("1,23") == ["one", "twenty", "three"], "1,23: the comma is not a thousands comma (it splits)")
	ok(ScoreCore.en_words("1234567890") == ["1234567890"], "10 digits stay digits")
	ok(ScoreCore.en_words("well-known") == ["well", "known"], "hyphen splits")
	ok(ScoreCore.en_words("\uFF28\uFF49") == ["hi"], "full-width letters")
	ok(ScoreCore.en_words("a\u00A0b") == ["a", "b"], "no-break space splits")
	ok(ScoreCore.en_words("Let\u2019s") == ["let", "us"], "curly apostrophe")
	# Unicode (review of round 1): written out, from the server
	var thousand: Array = ["one", "thousand", "two", "hundred", "and", "thirty", "four"]
	ok(ScoreCore.en_words("CAFE\u0315\u0301") == ["caf"], "E + U+0315 + U+0301: NFC sorts the marks (230 before 232), E composes with U+0301, the letter is gone")
	ok(ScoreCore.en_words("a\u0310\u0301b") == ["a", "b"], "a + U+0310 + U+0301: both marks have class 230, the second is blocked, the a stays")
	ok(ScoreCore.en_words("e\u0344x") == ["x"], "U+0344 is U+0308 U+0301: e composes")
	ok(ScoreCore.en_words("I\u0307x") == ["i", "x"] and ScoreCore.en_words("\u0130x") == ["i", "x"], "I + dot above and \u0130 give i")
	ok(ScoreCore.en_words("1,2\u06634") == ["twelve", "four"], "Arabic-Indic digit inside the group counts as a digit (Python digit class)")
	ok(ScoreCore.en_words("1,234\u0589") == thousand and ScoreCore.en_words("1,234\u037E") == thousand, "Armenian full stop and Greek question mark are non-word characters")
	ok(ScoreCore.en_words("1,234\u00E9") == ["one", "two", "hundred", "and", "thirty", "four"] and ScoreCore.en_words("1,234e\u0301") == ["one", "two", "hundred", "and", "thirty", "four"],
		"a letter (also one made by composing) after the group keeps the comma from being a thousands comma")
	var ca: Dictionary = ScoreCore.score_en("CAFE\u0315\u0301", [{"w": "cafe", "p": 0.9, "start": 0.0, "end": 0.5}], "cafe")
	ok(ca["units"][0]["t"] == "caf" and ca["units"][0]["ok"] == false and int(ca["score"]) < 50, "the reviewer's case: target CAFE + U+0315 + U+0301 against 'cafe' is a wrong answer")
	# 3rd round: U+0130 is I + U+0307 for NFKC; marks after it are sorted (U+0323 and U+0328 before U+0307) and composed with the I
	ok(ScoreCore.en_words("AN \u0130\u0328 AND") == ["an", "and"] and ScoreCore.en_words("AN I\u0307\u0328 AND") == ["an", "and"], "\u0130 + U+0328 and I + U+0307 + U+0328 are the same text: no i")
	ok(ScoreCore.en_words("YOU DRANK \u0130\u0323 COFFEE") == ["you", "drank", "coffee"] and ScoreCore.en_words("YOU DRANK I\u0307\u0323 COFFEE") == ["you", "drank", "coffee"],
		"\u0130 + U+0323 and I + U+0307 + U+0323 are the same text: no i")
	ok(ScoreCore.en_words("\u0130") == ["i"] and ScoreCore.en_words("I\u0307") == ["i"] and ScoreCore.en_words("I\u0323\u0307") == [] and ScoreCore.en_words("\u0130x") == ["i", "x"],
		"\u0130 alone and I + U+0307 give i; with U+0323 first the I is composed and gone")
	var di: Dictionary = ScoreCore.score_en("YOU DRANK \u0130\u0323 COFFEE", [{"w": "you", "p": 0.9, "start": 0.0, "end": 0.3}, {"w": "drank", "p": 0.9, "start": 0.4, "end": 0.7}, {"w": "coffee", "p": 0.9, "start": 0.8, "end": 1.1}], "you drank coffee")
	ok((di["units"] as Array).size() == 3 and int(di["score"]) == 98, "the reviewer's case 2: three words, all heard, 98 points")
	ok(ScoreCore.word_sim("abc", "abc") == 1.0, "word_sim equal = 1")
	ok(ScoreCore.word_sim("", "") == 1.0, "word_sim of two empty strings = 1")
	ok(ScoreCore.word_sim("abc", "xyz") == 0.0, "word_sim without common letters = 0")
	ok(absf(ScoreCore.word_sim("kitten", "sitting") - 0.6153846153846154) < 1e-12, "word_sim kitten/sitting = 8/13")
	ok(ScoreCore.align_seq(["a", "b", "c"], ["a", "x", "c", "d"]) == {"pairs": [[0, true], [null, false], [2, true]], "inserts": [[1, 1], [3, 3]]},
		"align_seq a b c / a x c d (x and d are inserts: x is too different from b)")
	ok(ScoreCore.align_seq([], []) == {"pairs": [], "inserts": []}, "align_seq of nothing")
	# Python round() is half to even
	ok(ScoreCore._round_int(0.5) == 0 and ScoreCore._round_int(1.5) == 2 and ScoreCore._round_int(2.5) == 2 and ScoreCore._round_int(12.5) == 12
		and ScoreCore._round_int(97.5) == 98 and ScoreCore._round_int(92.5) == 92 and ScoreCore._round_int(2.4999) == 2 and ScoreCore._round_int(2.5001) == 3,
		"_round_int is half-to-even")
	ok(ScoreCore._round3(0.0625) == 0.062 and ScoreCore._round3(0.1875) == 0.188 and ScoreCore._round3(0.3125) == 0.312
		and ScoreCore._round3(0.4375) == 0.438 and ScoreCore._round3(0.1235) == 0.123 and ScoreCore._round3(0.0005) == 0.001
		and ScoreCore._round3(0.9995) == 1.0 and ScoreCore._round3(0.9) == 0.9 and ScoreCore._round3(0.0) == 0.0 and ScoreCore._round3(1.0) == 1.0,
		"_round3 follows Python round(p, 3) (exact binary value, ties to even)")
	var w1: Array = [{"w": "Hello", "p": 0.9, "start": 0.0, "end": 0.5}]
	var r1: Dictionary = ScoreCore.score_en("Hello", w1, "Hello")
	ok(r1["score"] == 98 and r1["accuracy"] == 100 and r1["clarity"] == 90 and r1["fluency"] == 100, "one good word: 0.6*100 + 0.25*90 + 0.15*100 = 97.5 -> 98 (half to even)")
	ok(r1.keys() == ["transcript", "score", "accuracy", "clarity", "fluency", "units", "tips_ko"], "result key order")
	ok(r1["units"] == [{"t": "hello", "ok": true, "conf": 0.9, "heard": null}], "unit keys t, ok, conf, heard")
	var r2: Dictionary = ScoreCore.score_en("Hello", [{"w": "Hello", "p": 0.7, "start": 0.0, "end": 0.5}], "Hello")
	ok(r2["score"] == 92, "92.5 -> 92 (half to even)")
	ok(ScoreCore.score_en("Hello", [], "")["tips_ko"] == [ScoreCore.NO_VOICE_TIP] and ScoreCore.score_en("Hello", [], "")["transcript"] == "", "no words: NO_VOICE_TIP, empty transcript")
	ok(ScoreCore.score_en("", w1, "x").is_empty() and ScoreCore.score_en("?!", w1, "x").is_empty(), "target without words -> {}")
	ok(ScoreCore.TARGET_EMPTY_TEXT == "연습할 문장이 비어 있어요.", "TARGET_EMPTY_TEXT")
	ok(ScoreCore.OK_PROB == 0.45, "OK_PROB is 0.45")
	var r3: Dictionary = ScoreCore.score_en("Hello", [{"w": "Hello", "p": 0.4, "start": 0.0, "end": 0.5}], "Hello")
	var r4: Dictionary = ScoreCore.score_en("Hello", [{"w": "Hello", "p": 0.4, "start": 0.0, "end": 0.5}], "Hello", 0.35)
	ok(r3["units"][0]["ok"] == false and r4["units"][0]["ok"] == true, "the ok_prob argument moves the threshold")


func _test_cases(g: Dictionary) -> void:
	print("[golden: score_en full results]")
	var cases: Array = g.get("cases", []) as Array
	ok(cases.size() >= 120, "at least 120 cases (%d)" % cases.size())
	var diff: int = 0
	var n_prob: int = 0
	var n_prob_same: int = 0
	var n_err: int = 0
	var n_units: int = 0
	for c in cases:
		var cd: Dictionary = c
		var got: Dictionary
		if cd.has("ok_prob"):
			n_prob += 1
			got = ScoreCore.score_en(str(cd["target"]), cd["words"], str(cd["text"]), float(cd["ok_prob"]))
		else:
			got = ScoreCore.score_en(str(cd["target"]), cd["words"], str(cd["text"]))
		var same_all: bool = same(got, cd["expect"])
		if not same_all:
			diff += 1
		if cd.has("ok_prob") and same_all:
			n_prob_same += 1
		if cd.has("error"):
			n_err += 1
			ok(str(cd["error"]) == ScoreCore.TARGET_EMPTY_TEXT, "case %s: the server error is TARGET_EMPTY_TEXT" % [str(cd["id"])])
		if got.has("units"):
			n_units += (got["units"] as Array).size()
		ok(same_all, "case %s: result identical to the server (%s)" % [str(cd["id"]), JSON.stringify(got).substr(0, 160)])
	print("PA2-4 cases=%d identical=%d different=%d units=%d" % [cases.size(), cases.size() - diff, diff, n_units])
	print("PA2-4 ok_prob cases=%d identical=%d error cases=%d" % [n_prob, n_prob_same, n_err])
	ok(n_prob >= 10, "at least 10 cases with an ok_prob other than 0.45 (%d)" % n_prob)
	ok(n_prob_same == n_prob, "all ok_prob cases identical (%d of %d)" % [n_prob_same, n_prob])
	ok(n_err >= 2, "cases with an empty target exist (%d)" % n_err)
	# the cases cover the tips: every rule category and the generic tips are asserted through the expected texts
	var cats: Dictionary = {"r은": false, "f는": false, "v는": false, "th는": false, "z는": false, "짧은 i": false, "a와 e": false, "복수형 s": false,
		"-ed(d/t)": false, "받침처럼": false, "놓치거나": false, "그 단어만": false, "속도나 멈춤": false, "목표 문장과": false, "목소리가": false}
	for c in cases:
		for tip in ((c as Dictionary)["expect"] as Dictionary).get("tips_ko", []):
			for k in cats:
				if String(tip).contains(k):
					cats[k] = true
	var missing: Array = []
	for k in cats:
		if not cats[k]:
			missing.append(k)
	ok(missing.is_empty(), "the golden cases produce every kind of tip (missing: %s)" % [str(missing)])


func _test_align(g: Dictionary) -> void:
	print("[golden: align_seq / word_sim]")
	var al: Array = g.get("align", []) as Array
	ok(al.size() >= 300, "at least 300 aligned pairs (%d)" % al.size())
	var n_sim: int = 0
	var bad_sim: int = 0
	var bad_pairs: int = 0
	var worst: float = 0.0
	for i in al.size():
		var e: Dictionary = al[i]
		var a: Array = e["a"]
		var b: Array = e["b"]
		var got: Dictionary = ScoreCore.align_seq(a, b)
		var pairs_ok: bool = same(got["pairs"], e["pairs"]) and same(got["inserts"], e["inserts"])
		if not pairs_ok:
			bad_pairs += 1
		var sims: Array = e["sim"]
		var sim_ok: bool = sims.size() == mini(a.size(), b.size())
		for k in sims.size():
			n_sim += 1
			var d: float = absf(ScoreCore.word_sim(str(a[k]), str(b[k])) - float(sims[k]))
			worst = maxf(worst, d)
			if d > 1e-9:
				sim_ok = false
		if not sim_ok:
			bad_sim += 1
		ok(pairs_ok and sim_ok, "align #%d: pairs, inserts and word_sim as the server (a=%s b=%s)" % [i, JSON.stringify(a).substr(0, 60), JSON.stringify(b).substr(0, 60)])
	print("PA2-5 aligned pairs=%d bad pairs=%d word_sim values=%d bad=%d worst difference=%s" % [al.size(), bad_pairs, n_sim, bad_sim, str(worst)])
	ok(n_sim >= 400, "at least 400 word_sim values compared (%d)" % n_sim)


func _test_en_words(g: Dictionary) -> void:
	print("[golden: en_words]")
	var arr: Array = g.get("en_words", []) as Array
	ok(arr.size() >= 380, "at least 380 en_words inputs (%d)" % arr.size())
	var diff: int = 0
	for i in arr.size():
		var e: Dictionary = arr[i]
		var got: Array = ScoreCore.en_words(str(e["in"]))
		var same_out: bool = same(got, e["out"])
		if not same_out:
			diff += 1
		ok(same_out, "en_words #%d '%s': want %s got %s" % [i, str(e["in"]).substr(0, 40), JSON.stringify(e["out"]).substr(0, 80), JSON.stringify(got).substr(0, 80)])
	var gaps: Array = g.get("known_gaps", []) as Array
	ok(g.has("known_gaps"), "the golden file has a known_gaps list (%d entries)" % gaps.size())
	var still: int = 0
	for i in gaps.size():
		var e2: Dictionary = gaps[i]
		ok(str(e2.get("why", "")).length() > 10, "known gap #%d has a reason" % i)
		var got2: Array = ScoreCore.en_words(str(e2["in"]))
		var differs: bool = not same(got2, e2["out"])
		if differs:
			still += 1
		ok(differs, "known gap #%d still differs from the server (so the list cannot go stale)" % i)
	print("PA2-6 en_words inputs=%d different=%d known gaps=%d still different=%d" % [arr.size(), diff, gaps.size(), still])


func _test_maps() -> void:
	print("[maps: map_p, valid_p_map, map_final, valid_final_map]")
	var ident: Array = [[0, 0], [1, 1]]
	ok(ScoreCore.map_p(0.0, ident) == 0.0 and ScoreCore.map_p(0.25, ident) == 0.25 and ScoreCore.map_p(0.4499, ident) == 0.4499 and ScoreCore.map_p(1.0, ident) == 1.0,
		"map_p identity map: unchanged (exactly)")
	var m: Array = [[0, 0], [0.5, 0.2], [1, 1]]
	ok(absf(ScoreCore.map_p(0.25, m) - 0.1) < 1e-12, "map_p linear in the first segment")
	ok(absf(ScoreCore.map_p(0.75, m) - 0.6) < 1e-12, "map_p linear in the second segment")
	ok(ScoreCore.map_p(0.5, m) == 0.2, "map_p at a point gives that point's y")
	ok(ScoreCore.map_p(-0.5, m) == 0.0 and ScoreCore.map_p(1.5, m) == 1.0, "map_p cuts p to [0, 1]: the end values")
	ok(ScoreCore.map_p(NAN, m) == 0.0, "map_p NaN -> the value at 0")
	ok(ScoreCore.map_p(0.3, [[0, 0.1], [1, 0.1]]) == 0.1, "map_p flat map")
	ok(ScoreCore.map_p(0.3, [[0, 0], [0.5, 0.8], [1, 0.5]]) == 0.3, "map_p with an invalid (non-monotone) map: p unchanged")
	ok(ScoreCore.map_p(NAN, [[0, 0], [0.5, 0.8], [1, 0.5]]) == 0.0 and ScoreCore.map_p(2.0, []) == 1.0, "map_p invalid map: p cut to [0, 1], NaN -> 0")
	ok(ScoreCore.valid_p_map(ident) and ScoreCore.valid_p_map(m) and ScoreCore.valid_p_map([[0.0, 0.0], [1.0, 1.0]]), "valid_p_map accepts good maps (ints and floats)")
	ok(ScoreCore.valid_p_map([[0, 0.3], [1, 0.3]]), "valid_p_map accepts a flat map")
	var pts32: Array = []
	for i in 32:
		pts32.append([float(i) / 31.0, float(i) / 31.0])
	var pts33: Array = []
	for i in 33:
		pts33.append([float(i) / 32.0, float(i) / 32.0])
	ok(ScoreCore.valid_p_map(pts32), "valid_p_map accepts 32 points")
	ok(not ScoreCore.valid_p_map(pts33), "valid_p_map rejects 33 points")
	ok(not ScoreCore.valid_p_map([[0, 0]]), "valid_p_map rejects one point")
	ok(not ScoreCore.valid_p_map([]) and not ScoreCore.valid_p_map(null) and not ScoreCore.valid_p_map("x") and not ScoreCore.valid_p_map(5), "valid_p_map rejects empty / null / string / number")
	ok(not ScoreCore.valid_p_map([[0, 0], [0.5, 0.8], [1, 0.5]]), "valid_p_map rejects a y that goes down")
	ok(not ScoreCore.valid_p_map([[0, 0], [1.2, 1]]), "valid_p_map rejects x out of range (1.2)")
	ok(not ScoreCore.valid_p_map([[0, 0], [0.5, 0.2], [0.5, 0.3], [1, 1]]), "valid_p_map rejects a repeated x")
	ok(not ScoreCore.valid_p_map([[0, 0], [0.6, 0.2], [0.5, 0.3], [1, 1]]), "valid_p_map rejects x going back")
	ok(not ScoreCore.valid_p_map([[0, 0], [1, 1.2]]), "valid_p_map rejects y > 1")
	ok(not ScoreCore.valid_p_map([[0, -0.1], [1, 1]]), "valid_p_map rejects y < 0")
	ok(not ScoreCore.valid_p_map([[0.1, 0], [1, 1]]) and not ScoreCore.valid_p_map([[0, 0], [0.9, 1]]), "valid_p_map needs x = 0 first and x = 1 last")
	ok(not ScoreCore.valid_p_map([[0], [1, 1]]) and not ScoreCore.valid_p_map([[0, 0, 0], [1, 1]]) and not ScoreCore.valid_p_map([0, 1]), "valid_p_map rejects points that are not [x, y]")
	ok(not ScoreCore.valid_p_map([[0, "a"], [1, 1]]) and not ScoreCore.valid_p_map([[0, true], [1, 1]]), "valid_p_map rejects non-numbers")
	ok(not ScoreCore.valid_p_map([[0, NAN], [1, 1]]) and not ScoreCore.valid_p_map([[0, 0], [1, INF]]), "valid_p_map rejects NaN and infinity")
	# final map
	var fm: Array = [[0, 0], [50, 40], [100, 100]]
	ok(ScoreCore.map_final(25, fm) == 20 and ScoreCore.map_final(75, fm) == 70, "map_final linear")
	ok(ScoreCore.map_final(50, fm) == 40 and ScoreCore.map_final(0, fm) == 0 and ScoreCore.map_final(100, fm) == 100, "map_final at points")
	ok(ScoreCore.map_final(1, [[0, 0], [100, 50]]) == 1 and ScoreCore.map_final(3, [[0, 0], [100, 50]]) == 2, "map_final rounds half up (0.5 -> 1, 1.5 -> 2)")
	ok(ScoreCore.map_final(150, fm) == 100 and ScoreCore.map_final(-5, fm) == 0, "map_final cuts the score to 0..100")
	ok(ScoreCore.map_final(77, [[0, 0], [100, 100]]) == 77, "map_final identity")
	ok(ScoreCore.map_final(77, [[0, 0], [60, 90], [100, 50]]) == 77, "map_final invalid map: score unchanged")
	ok(ScoreCore.valid_final_map(fm) and ScoreCore.valid_final_map([[0, 0], [100, 100]]) and ScoreCore.valid_final_map([[0, 10.5], [100, 90.5]]), "valid_final_map accepts good maps")
	ok(not ScoreCore.valid_final_map([[0, 0], [1, 1]]) and not ScoreCore.valid_final_map([[0, 0], [100, 120]]) and not ScoreCore.valid_final_map([[0, 0], [50, 60], [100, 50]]),
		"valid_final_map rejects x not reaching 100, y > 100, y going down")
	ok(not ScoreCore.valid_final_map([[0, 0], [50, 40], [50, 45], [100, 100]]) and not ScoreCore.valid_final_map([[5, 0], [100, 100]]) and not ScoreCore.valid_final_map(null),
		"valid_final_map rejects a repeated x, x not starting at 0, null")
	ok(ScoreCore.valid_final_map(pts32.map(func(p: Array) -> Array: return [p[0] * 100.0, p[1] * 100.0])) and not ScoreCore.valid_final_map(pts33.map(func(p: Array) -> Array: return [p[0] * 100.0, p[1] * 100.0])),
		"valid_final_map: 32 points yes, 33 no")


func _test_defensive() -> void:
	print("[defensive input]")
	var good: Array = [{"w": "hello", "p": 0.9, "start": 0.0, "end": 0.5}, {"w": "there", "p": 0.8, "start": 0.6, "end": 1.0}]
	for bad in [null, "text", 5, {"w": "hello"}, true, [], [1, "a", null], [{"p": 0.5}], [[1, 2]]]:
		var r: Dictionary = ScoreCore.score_en("hello there", bad, "x")
		ok(r.has("score") and int(r["score"]) == 0 and (r["units"] as Array).size() == 2 and r["tips_ko"] == [ScoreCore.NO_VOICE_TIP], "words = %s: no error, score 0" % [str(bad)])
	for pv in [-1.0, 2.0, NAN, INF, -INF, -0.0001, 1.0001]:
		var r2: Dictionary = ScoreCore.score_en("hello", [{"w": "hello", "p": pv, "start": 0.0, "end": 0.4}], "hello")
		var conf: float = float(r2["units"][0]["conf"])
		ok(conf >= 0.0 and conf <= 1.0 and int(r2["score"]) >= 0 and int(r2["score"]) <= 100, "p = %s is cut to [0, 1] (conf %s)" % [str(pv), str(conf)])
	var r3: Dictionary = ScoreCore.score_en("hello", [{"w": "hello", "p": "high", "start": "a", "end": null}], "hello")
	ok(r3.has("score") and float(r3["units"][0]["conf"]) == 0.0, "p of the wrong type -> 0, times of the wrong type -> no error")
	var r4: Dictionary = ScoreCore.score_en("hello there", [{"w": "hello", "p": 0.9, "start": 2.0, "end": 1.0}, {"w": "there", "p": 0.9, "start": 0.5, "end": 0.2}], "x")
	ok(r4.has("fluency") and int(r4["fluency"]) >= 0 and int(r4["fluency"]) <= 100, "start > end and time going back: fluency stays 0..100")
	ok(ScoreCore.score_en("hello there", good, "x") == ScoreCore.score_en("hello there", good.duplicate(true), "x"), "same input, same result")
	var bad_missing: Array = [{"w": "hello"}, {"w": "there", "p": 0.9}]
	var r5: Dictionary = ScoreCore.score_en("hello there", bad_missing, "x")
	ok(r5.has("score"), "words without p / start / end: no error")
	ok(ScoreCore.score_en("", good, "x").is_empty() and ScoreCore.score_en("   ", good, "x").is_empty() and ScoreCore.score_en("-- ,, ..", good, "x").is_empty(), "empty target -> {}")
	ok(ScoreCore.score_en("hello", [{"w": 123, "p": 0.9, "start": 0.0, "end": 0.4}], "x").has("units"), "w that is a number: no error")
	# for valid input the corrections change nothing: a sentence with overlapping times and a long pause
	var ov: Array = [{"w": "a", "p": 0.9, "start": 0.0, "end": 0.5}, {"w": "b", "p": 0.9, "start": 0.4, "end": 0.9}, {"w": "c", "p": 0.9, "start": 2.5, "end": 3.0}]
	ok(ScoreCore.fluency_score(3, ov) == ScoreCore.fluency_score(3, ScoreCore._clean_words(ov)), "valid words are not changed by the cleaning")
	# fuzz: 300 random inputs never fail and always give values in range
	var rng := RandomNumberGenerator.new()
	rng.seed = 20261119
	var vocab: Array = ["the", "right", "light", "think", "sink", "I", "don't", "21", "ship", "sheep", "coffee,", "!!", "...", "cats", "cat", "100", "1,234"]
	var bad_range: int = 0
	var bad_units: int = 0
	for it in 300:
		var tgt: Array = []
		for k in rng.randi_range(0, 8):
			tgt.append(vocab[rng.randi() % vocab.size()])
		var ws: Array = []
		var t: float = 0.0
		for k in rng.randi_range(0, 10):
			var st: float = t + rng.randf_range(-0.3, 1.5)
			ws.append({"w": vocab[rng.randi() % vocab.size()], "p": rng.randf_range(-0.5, 1.5), "start": st, "end": st + rng.randf_range(-0.2, 0.8)})
			t = st
		var target: String = " ".join(PackedStringArray(tgt))
		var res: Dictionary = ScoreCore.score_en(target, ws, "x")
		if ScoreCore.en_words(target).is_empty():
			if not res.is_empty():
				bad_units += 1
			continue
		for key in ["score", "accuracy", "clarity", "fluency"]:
			if int(res[key]) < 0 or int(res[key]) > 100:
				bad_range += 1
		if (res["units"] as Array).size() != ScoreCore.en_words(target).size():
			bad_units += 1
	print("fuzz 300 inputs: out of range %d, wrong unit count %d" % [bad_range, bad_units])
	ok(bad_range == 0 and bad_units == 0, "fuzz: values within 0..100, one unit per target word")


func _test_perf() -> void:
	print("[performance]")
	var vocab: Array = ["time", "people", "year", "way", "day", "thing", "world", "life", "hand", "part", "child", "eye", "woman", "place", "work",
		"week", "case", "point", "government", "company", "number", "group", "problem", "fact", "morning", "evening", "kitchen", "window",
		"summer", "winter", "garden", "river", "mountain", "bridge", "market", "school", "music", "story", "letter", "dinner"]
	var tgt: Array = []
	for i in 40:
		tgt.append(vocab[i % vocab.size()])
	var words: Array = []
	var t: float = 0.0
	for i in 60:
		var w: String = tgt[i % 40] if (i % 3 != 2) else vocab[(i * 7) % vocab.size()]
		if i % 7 == 3:
			w = w.substr(0, w.length() - 1) + "x"   # a wrong letter now and then
		words.append({"w": w, "p": 0.5 + float(i % 5) * 0.1, "start": t, "end": t + 0.3})
		t += 0.4
	var target: String = " ".join(PackedStringArray(tgt))
	var best: int = 1 << 30
	for rep in 5:
		var t0: int = Time.get_ticks_usec()
		var res: Dictionary = ScoreCore.score_en(target, words, "x")
		var dt: int = Time.get_ticks_usec() - t0
		best = mini(best, dt)
		if rep == 0:
			ok(res.has("score"), "40-word target against 60 words gives a result")
	print("PA2-8 perf: score_en 40-word target x 60 words = %.1f ms (best of 5)" % [float(best) / 1000.0])
	ok(best <= 50000, "40 x 60 scoring takes at most 50 ms on the desktop (%.1f ms)" % [float(best) / 1000.0])
	# everything different: one big replace block, the alignment table is 40 x 60
	var other: Array = []
	for i in 60:
		other.append({"w": vocab[(i * 11 + 5) % vocab.size()] + "q", "p": 0.6, "start": float(i) * 0.4, "end": float(i) * 0.4 + 0.3})
	var runs: Array = []
	var res2: Dictionary = {}
	for rep in 6:
		var t1: int = Time.get_ticks_usec()
		res2 = ScoreCore.score_en(target, other, "x")
		runs.append(float(Time.get_ticks_usec() - t1) / 1000.0)
	var worst_ms: float = 0.0
	var runs_txt: String = ""
	for r in runs:
		worst_ms = maxf(worst_ms, float(r))
		runs_txt += "%.1f " % [float(r)]
	print("PA2-8 perf (worst case, one replace block 40 x 60), 6 runs in ms: %s| max %.1f" % [runs_txt, worst_ms])
	ok(res2.has("score"), "worst case gives a result")
	ok(worst_ms <= 50.0, "the worst case (everything different, one 40 x 60 block) takes at most 50 ms in each of 6 runs (max %.1f ms; design aim 30 ms)" % [worst_ms])


## The comparisons above are only worth something if they can fail: wrong expectations must be rejected.
func _test_selfchecks(g: Dictionary) -> void:
	print("[selfcheck: wrong expectations are rejected]")
	var cases: Array = g.get("cases", []) as Array
	if cases.is_empty():
		ok(false, "selfcheck needs the golden cases")
		return
	var c0: Dictionary = (cases[0] as Dictionary).duplicate(true)
	var got: Dictionary = ScoreCore.score_en(str(c0["target"]), c0["words"], str(c0["text"]))
	var exp: Dictionary = c0["expect"]
	ok(same(got, exp), "selfcheck baseline: the first case is identical")
	var t1: Dictionary = exp.duplicate(true)
	t1["score"] = float(t1["score"]) + 1.0
	print("  selfcheck FAIL-as-expected: score + 1")
	ok(not same(got, t1), "selfcheck FAIL-as-expected: score + 1 is detected")
	var t2: Dictionary = exp.duplicate(true)
	(t2["units"] as Array)[0]["conf"] = float(t2["units"][0]["conf"]) + 0.001
	print("  selfcheck FAIL-as-expected: conf + 0.001")
	ok(not same(got, t2), "selfcheck FAIL-as-expected: conf + 0.001 is detected")
	var t3: Dictionary = {}
	for k in ["score", "transcript", "accuracy", "clarity", "fluency", "units", "tips_ko"]:
		t3[k] = exp[k]
	print("  selfcheck FAIL-as-expected: key order changed")
	ok(not same(got, t3), "selfcheck FAIL-as-expected: another key order is detected")
	var t4: Dictionary = exp.duplicate(true)
	t4["extra"] = 1
	print("  selfcheck FAIL-as-expected: extra key")
	ok(not same(got, t4), "selfcheck FAIL-as-expected: an extra key is detected")
	var t5: Dictionary = exp.duplicate(true)
	(t5["units"] as Array)[0]["ok"] = 1
	print("  selfcheck FAIL-as-expected: bool vs number")
	ok(not same(got, t5), "selfcheck FAIL-as-expected: true vs 1 is detected")
	var t6: Dictionary = exp.duplicate(true)
	(t6["tips_ko"] as Array).append("x")
	print("  selfcheck FAIL-as-expected: extra tip")
	ok(not same(got, t6), "selfcheck FAIL-as-expected: an extra tip is detected")
	ok(not same(ScoreCore.en_words("don't"), ["don't"]) and not same(ScoreCore.en_words("21"), ["twenty-one"]) and not same(ScoreCore.en_words("a b"), ["a"]),
		"selfcheck FAIL-as-expected: wrong en_words expectations are detected")
	ok(not same(ScoreCore.align_seq(["a"], ["b"]), {"pairs": [[0, true]], "inserts": []}), "selfcheck FAIL-as-expected: a wrong alignment is detected")
	ok(same(1.0, 1.0000000001, 1e-9) and not same(1.0, 1.0000000001), "selfcheck: eps makes the comparison looser, and only then")
	# a result with a wrong threshold is not the golden result: p between 0.40 and 0.45 exists in the cases
	var diff_prob: int = 0
	for c in cases:
		var cd: Dictionary = c
		if cd.has("ok_prob"):
			continue
		var alt: Dictionary = ScoreCore.score_en(str(cd["target"]), cd["words"], str(cd["text"]), 0.40)
		if not same(alt, cd["expect"]):
			diff_prob += 1
	print("selfcheck: OK_PROB 0.40 instead of 0.45 changes %d golden cases" % diff_prob)
	ok(diff_prob >= 3, "selfcheck FAIL-as-expected: with OK_PROB 0.40 at least 3 golden cases differ (%d)" % diff_prob)
