extends Node
## data/ja_sounds.json 린트 (docs/v170_design.md §2.2, A2-4): 필수 카테고리, 쌍 개수, 낱말이 gloss_ja 표제어에 있는지,
## 읽기·발음형 글자 종류, 한국어 글자, 중복 쌍 없음, 파일 크기, 카테고리와 쌍이 실제로 맞는지(events 로 확인).
##   godot --headless --path <project> res://tests/ja_sounds_data_test.tscn
## 마지막 줄: "== ja_sounds_data: N passed, M failed ==". 린트 함수도 일부러 틀린 데이터를 넣어 실패하는지 확인한다(selfcheck).
## 디스크를 쓰지 않는다(깨진 파일 시험만 user://test_a2_* 에 쓰고 지운다). 네트워크 없음.

const MAX_BYTES := 120000
const REQUIRED := ["j_long", "j_sokuon", "j_voice", "j_tsu", "j_za"]

var passed: int = 0
var failed: int = 0
var gloss: Dictionary = {}


func ok(cond: bool, name: String) -> void:
	if cond:
		passed += 1
		print("  PASS  ", name)
	else:
		failed += 1
		print("  FAIL  ", name)


func _ready() -> void:
	print("== ja_sounds_data start ==")
	JaSounds.data_path = JaSounds.DATA_PATH
	JaSounds.clear_cache()
	var g: Variant = JSON.parse_string(FileAccess.get_file_as_string("res://data/pack/gloss_ja.json"))
	if g is Dictionary:
		gloss = g
	ok(gloss.size() > 1000, "gloss_ja.json loaded (%d headwords)" % gloss.size())
	_test_real_data()
	_test_cleaning()
	_test_selfchecks()
	JaSounds.clear_cache()
	print("== ja_sounds_data: %d passed, %d failed ==" % [passed, failed])
	get_tree().quit(1 if failed > 0 else 0)


# ---------------------------------------------------------------- 린트 함수 (순수)

func has_hangul(s: String) -> bool:
	for i in s.length():
		var c: int = s.unicode_at(i)
		if c >= 0xAC00 and c <= 0xD7A3:
			return true
	return false


## only: 히라가나(+ー) / 가타카나(+ー). extra: 추가로 허용하는 글자(문장부호)
func only_hira(s: String, extra: String = "") -> bool:
	if s == "":
		return false
	for i in s.length():
		var c: int = s.unicode_at(i)
		var ch: String = s.substr(i, 1)
		if not ((c >= 0x3041 and c <= 0x3096) or ch == "ー" or extra.contains(ch)):
			return false
	return true


func only_kata(s: String, extra: String = "") -> bool:
	if s == "":
		return false
	for i in s.length():
		var c: int = s.unicode_at(i)
		var ch: String = s.substr(i, 1)
		if not ((c >= 0x30A1 and c <= 0x30F6) or ch == "ー" or extra.contains(ch)):
			return false
	return true


func count_cat(reading: String, cat: String) -> int:
	var n := 0
	for e in JaSounds.events(reading):
		if e["cat"] == cat:
			n += 1
	return n


## 쌍 하나의 문제 목록 (비어 있으면 통과). 카테고리 p 에 대해 본다.
func lint_pair(p: String, e: Dictionary, gl: Dictionary) -> Array:
	var out: Array = []
	for k in ["a", "b"]:
		var w: String = str(e.get(k, ""))
		var rd: String = str(e.get(k + "_rd", ""))
		var pr: String = str(e.get(k + "_pr", ""))
		var ko: String = str(e.get(k + "_ko", ""))
		if w == "" or not gl.has(w):
			out.append("%s not in gloss_ja: '%s'" % [k, w])
		if not only_hira(rd):
			out.append("%s_rd is not hiragana: '%s'" % [k, rd])
		if not only_kata(pr):
			out.append("%s_pr is not katakana: '%s'" % [k, pr])
		if not has_hangul(ko):
			out.append("%s_ko has no Korean: '%s'" % [k, ko])
	if str(e.get("a_rd", "x")) == str(e.get("b_rd", "x")):
		out.append("a_rd == b_rd")
	if str(e.get("a", "x")) == str(e.get("b", "y")):
		out.append("a == b")
	# 카테고리와 쌍이 실제로 맞는다 (events 로 확인)
	var ca: int = count_cat(str(e.get("a_rd", "")), p)
	var cb: int = count_cat(str(e.get("b_rd", "")), p)
	if p == "j_long" or p == "j_sokuon" or p == "j_youon":
		if ca == cb:
			out.append("pair does not differ in %s (%d vs %d)" % [p, ca, cb])
	else:
		if ca == 0 or cb == 0:
			out.append("both words must contain a %s sound (%d, %d)" % [p, ca, cb])
	return out


func lint_word(e: Dictionary) -> Array:
	var out: Array = []
	if str(e.get("w", "")) == "":
		out.append("empty w")
	if not only_hira(str(e.get("rd", ""))):
		out.append("rd is not hiragana: '%s'" % str(e.get("rd", "")))
	if not only_kata(str(e.get("pr", ""))):
		out.append("pr is not katakana: '%s'" % str(e.get("pr", "")))
	if not has_hangul(str(e.get("ko", ""))):
		out.append("ko has no Korean")
	return out


func lint_phrase(e: Dictionary) -> Array:
	var out: Array = []
	if str(e.get("text", "")) == "":
		out.append("empty text")
	if not only_hira(str(e.get("rd", "")), "、。！？"):
		out.append("rd is not hiragana: '%s'" % str(e.get("rd", "")))
	if not only_kata(str(e.get("pr", "")), "、。！？"):
		out.append("pr is not katakana: '%s'" % str(e.get("pr", "")))
	if not has_hangul(str(e.get("ko", ""))):
		out.append("ko has no Korean")
	return out


# ---------------------------------------------------------------- 실제 데이터

func _test_real_data() -> void:
	print("[real data]")
	var size_bytes: int = FileAccess.get_file_as_bytes("res://data/ja_sounds.json").size()
	ok(size_bytes > 0 and size_bytes <= MAX_BYTES, "file size %d bytes <= %d" % [size_bytes, MAX_BYTES])
	var d: Dictionary = JaSounds.load_data()
	ok(bool(d["ok"]), "load_data ok")
	var raw: Variant = JSON.parse_string(FileAccess.get_file_as_string("res://data/ja_sounds.json"))
	ok(raw is Dictionary and int((raw as Dictionary).get("v", 0)) == 1, "version v = 1")
	var cats: Array = d["categories"]
	var ids: Array = []
	for c in cats:
		ids.append(c["p"])
	for r in REQUIRED:
		ok(ids.has(r), "required category %s exists" % r)
	var raw_cats: Array = (raw as Dictionary).get("categories", []) if raw is Dictionary else []
	ok(cats.size() == raw_cats.size(), "every category survives the loader's cleaning (%d of %d)" % [cats.size(), raw_cats.size()])
	var all_pairs := {}
	var total_lint := 0
	var rx := RegEx.new()
	rx.compile("^j_[a-z]{2,8}$")
	for c in cats:
		var p: String = c["p"]
		ok(rx.search(p) != null and p.length() <= PhonemeStats.MAX_P_LEN and JaSounds.is_category(p), "%s: id format and known category" % p)
		ok(str(c["label"]) != "" and has_hangul(str(c["hint_ko"])) and has_hangul(str(c["tip_ko"])), "%s: label is set, hint_ko / tip_ko are Korean" % p)
		var pairs: Array = c["pairs"]
		var words: Array = c["words"]
		var phrases: Array = c["phrases"]
		var need_pairs := 8 if (p == "j_long" or p == "j_sokuon" or p == "j_voice") else (6 if p == "j_tsu" else (3 if p == "j_youon" else 1))
		ok(pairs.size() >= need_pairs, "%s: %d pairs (>= %d)" % [p, pairs.size(), need_pairs])
		ok(words.size() >= 4, "%s: %d words (>= 4)" % [p, words.size()])
		ok(phrases.size() >= 4, "%s: %d phrases (>= 4)" % [p, phrases.size()])
		var pair_problems: Array = []
		for e in pairs:
			for why in lint_pair(p, e, gloss):
				pair_problems.append("%s %s/%s: %s" % [p, e["a"], e["b"], why])
			var ka: String = str(e["a"])
			var kb: String = str(e["b"])
			var key: String = (ka + "|" + kb) if ka < kb else (kb + "|" + ka)
			if all_pairs.has(p + "|" + key):
				pair_problems.append("duplicate pair %s" % key)
			all_pairs[p + "|" + key] = true
		for line in pair_problems:
			print("    LINT  ", line)
		total_lint += pair_problems.size()
		ok(pair_problems.is_empty(), "%s: all %d pairs pass the lint" % [p, pairs.size()])
		var word_problems := 0
		for e in words:
			var wp: Array = lint_word(e)
			if not wp.is_empty():
				print("    LINT   word %s: %s" % [e["w"], str(wp)])
				word_problems += 1
		ok(word_problems == 0, "%s: all %d words pass the lint" % [p, words.size()])
		var phrase_problems := 0
		for e in phrases:
			var pp: Array = lint_phrase(e)
			if not pp.is_empty():
				print("    LINT   phrase %s: %s" % [e["text"], str(pp)])
				phrase_problems += 1
		ok(phrase_problems == 0, "%s: all %d phrases pass the lint" % [p, phrases.size()])
	var n_pairs := 0
	var n_words := 0
	var n_phr := 0
	for c in cats:
		n_pairs += (c["pairs"] as Array).size()
		n_words += (c["words"] as Array).size()
		n_phr += (c["phrases"] as Array).size()
	print("data: %d categories, %d pairs, %d words, %d phrases, %d bytes" % [cats.size(), n_pairs, n_words, n_phr, size_bytes])
	ok(total_lint == 0, "no lint problems in the whole file")


func _test_cleaning() -> void:
	print("[loader cleaning]")
	var path := "user://test_a2_partial_sounds.json"
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(JSON.stringify({"v": 1, "categories": [
		{"p": "j_long", "label": "x", "hint_ko": "y", "tip_ko": "z",
		 "pairs": [{"a": "家", "a_rd": "いえ", "a_ko": "집", "b": "いいえ", "b_rd": "いいえ", "b_ko": "아니"}, {"a": "x"}, 5, {"a": "", "a_rd": "", "a_ko": "", "b": "b", "b_rd": "b", "b_ko": "b"}],
		 "words": [{"w": "あ", "rd": "あ", "ko": "아"}, {"w": "", "rd": "あ", "ko": "아"}, "x"],
		 "phrases": [{"text": "あ", "rd": "あ", "ko": "아"}, {"text": "あ"}]},
		{"p": "bad id"}, {"p": "j_x"}, {"p": "toolong_category_name"}, 7, "x"]}))
	f.close()
	JaSounds.data_path = path
	JaSounds.clear_cache()
	var d: Dictionary = JaSounds.load_data()
	ok(bool(d["ok"]) and (d["categories"] as Array).size() == 1, "only the well-formed category is kept (%d)" % (d["categories"] as Array).size())
	var c: Dictionary = JaSounds.category("j_long")
	ok((c["pairs"] as Array).size() == 1 and (c["words"] as Array).size() == 1 and (c["phrases"] as Array).size() == 1, "bad pairs / words / phrases are dropped, good ones kept")
	# 카테고리가 빈 배열이면 ok=false
	var f2 := FileAccess.open(path, FileAccess.WRITE)
	f2.store_string(JSON.stringify({"v": 1, "categories": []}))
	f2.close()
	JaSounds.clear_cache()
	var d2: Dictionary = JaSounds.load_data()
	ok(d2["ok"] == false and d2["err"] == "bad", "no category at all: ok=false, err=bad")
	var f3 := FileAccess.open(path, FileAccess.WRITE)
	f3.store_string("[]")
	f3.close()
	JaSounds.clear_cache()
	ok(JaSounds.load_data()["ok"] == false, "top-level array: ok=false")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	JaSounds.data_path = JaSounds.DATA_PATH
	JaSounds.clear_cache()
	ok(bool(JaSounds.load_data()["ok"]), "hook restored: real data loads")


# ---------------------------------------------------------------- 린트도 실패할 수 있다

func _test_selfchecks() -> void:
	print("[selfchecks: broken data must fail the lint]")
	var good: Dictionary = {"a": "家", "a_rd": "いえ", "a_pr": "イエ", "a_ko": "집", "b": "いいえ", "b_rd": "いいえ", "b_pr": "イーエ", "b_ko": "아니요"}
	ok(lint_pair("j_long", good, gloss).is_empty(), "control: the good pair passes")
	var cases: Array = []
	var x1: Dictionary = good.duplicate()
	x1["a"] = "ZZ偽単語"
	cases.append(["fake word (not in gloss)", "j_long", x1])
	var x2: Dictionary = good.duplicate()
	x2["b_rd"] = "いえ"
	cases.append(["a_rd == b_rd", "j_long", x2])
	var x3: Dictionary = good.duplicate()
	x3["a_rd"] = "家"
	cases.append(["reading with kanji", "j_long", x3])
	var x4: Dictionary = good.duplicate()
	x4["b_pr"] = "いーえ"
	cases.append(["pr with hiragana", "j_long", x4])
	var x5: Dictionary = good.duplicate()
	x5["a_ko"] = "house"
	cases.append(["ko without Korean", "j_long", x5])
	cases.append(["pair does not belong to the category (long pair listed as sokuon)", "j_sokuon", good])
	var x6: Dictionary = good.duplicate()
	x6["b_rd"] = "いえ"
	x6["b"] = "家"
	cases.append(["a == b", "j_long", x6])
	for cs in cases:
		var problems: Array = lint_pair(cs[1], cs[2], gloss)
		var judged: bool = not problems.is_empty()
		ok(judged, "selfcheck FAIL-as-expected: %s" % cs[0])
		print("selfcheck FAIL-as-expected lint(%s): %s" % [cs[0], str(problems.slice(0, 2))])
	ok(not lint_word({"w": "あ", "rd": "亜", "pr": "ア", "ko": "아"}).is_empty(), "selfcheck FAIL-as-expected: word with kanji rd")
	ok(not lint_phrase({"text": "あ。", "rd": "あ。", "pr": "ア。", "ko": "x"}).is_empty(), "selfcheck FAIL-as-expected: phrase without Korean")
	ok(not only_hira("") and not only_hira("あa") and not only_kata("ア〜") and not has_hangul("abc"), "selfcheck FAIL-as-expected: char-class helpers reject wrong strings")
	# 파일 크기 검사가 너무 큰 값에서 실패한다
	ok(not (130000 > 0 and 130000 <= MAX_BYTES), "selfcheck FAIL-as-expected: a 130000-byte file would be rejected")
