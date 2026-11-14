extends Node
## B3: MissionText.norm_ja (godot/scripts/core/mission_text.gd) against the PC rule engine's normalize_ja.
##   godot --headless --path <project> res://tests/mission_text_test.tscn
##   godot --headless --path <project> --resolution 412x915 res://tests/mission_text_test.tscn -- --phone
## Exit code 0 = all checks passed. Last line: "== mission_text_test: N passed, M failed =="
## Data: res://tests/fixtures/mission_golden.json "ja_*" keys (written by backend/tools/make_mission_golden.py from missions.normalize_ja).
## No network, no user files.

const GOLDEN := "res://tests/fixtures/mission_golden.json"

var passed: int = 0
var failed: int = 0


func _ready() -> void:
	print("== mission_text_test start ==")
	var g: Dictionary = _load_golden()
	ok(not g.is_empty(), "golden file parses")
	_test_rules()
	_test_golden(g)
	_test_properties(g)
	_test_selfchecks()
	print("== mission_text_test: %d passed, %d failed ==" % [passed, failed])
	get_tree().quit(1 if failed > 0 else 0)


func ok(cond: bool, name: String) -> void:
	if cond:
		passed += 1
	else:
		failed += 1
		print("  FAIL  ", name)


func _load_golden() -> Dictionary:
	var f: FileAccess = FileAccess.open(GOLDEN, FileAccess.READ)
	if f == null:
		return {}
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	return parsed if parsed is Dictionary else {}


## The rules, with the expected strings written out here (not read from the golden file).
func _test_rules() -> void:
	print("[rules written out]")
	ok(MissionText.norm_ja("") == "", "empty -> empty")
	ok(MissionText.norm_ja("すみません") == "すみません", "hiragana stays")
	ok(MissionText.norm_ja("ラーメン") == "らーめん", "katakana -> hiragana, ー stays")
	ok(MissionText.norm_ja("ヽヾ") == "ゝゞ", "ヽ ヾ -> ゝ ゞ")
	ok(MissionText.norm_ja("駅は どこ ですか？") == "駅はどこですか", "kanji stay, spaces and punctuation are deleted (not turned into spaces)")
	ok(MissionText.norm_ja("ＡＢＣ１２３") == "abc123", "full-width Latin letters and digits -> ASCII, lower case")
	ok(MissionText.norm_ja("Hello World 123") == "helloworld123", "ASCII letters lower case, space deleted")
	ok(MissionText.norm_ja("　ー〇々　") == "ー〇々", "U+3000 deleted; ー 〇 々 kept")
	ok(MissionText.norm_ja("ｶﾞｷﾞｸﾞｹﾞｺﾞ") == "がぎぐげご", "half-width kana + ﾞ compose")
	ok(MissionText.norm_ja("ﾊﾟﾋﾟﾌﾟﾍﾟﾎﾟ") == "ぱぴぷぺぽ", "half-width kana + ﾟ compose")
	ok(MissionText.norm_ja("ｳﾞ") == "ゔ", "ｳﾞ -> ヴ -> ゔ")
	ok(MissionText.norm_ja("か\u3099は\u309a") == "がぱ", "combining marks compose")
	ok(MissionText.norm_ja("ヷヸヹヺ") == "", "rule 2: U+30F7..30FA are not kept")
	ok(MissionText.norm_ja("ﾜﾞ") == "" and MissionText.norm_ja("ワ\u3099") == "", "rule 2: ワ + voicing mark makes ヷ, which is deleted")
	ok(MissionText.norm_ja("あ".repeat(300) + "い") == "あ".repeat(300), "first cut: only 300 characters are read")
	ok(MissionText.norm_ja("⑩".repeat(200)).length() == 300, "rule 1: cut to 300 again at the end (⑩ gives 2 digits)")
	ok(MissionText.norm_ja("😀 안녕 🇯🇵") == "", "emoji and Hangul are deleted")
	ok(MissionText.norm_ja("𠮷") == "", "a kanji outside the BMP ranges is deleted (as the PC)")


func _test_golden(g: Dictionary) -> void:
	print("[golden: PC normalize_ja results]")
	var diff := 0
	var n := 0
	for key in ["ja_norm_cases", "ja_random", "ja_known_gaps"]:
		var arr: Array = g.get(key, []) as Array
		ok(not arr.is_empty(), "%s is not empty" % key)
		for i in arr.size():
			var c: Dictionary = arr[i]
			var got: String = MissionText.norm_ja(str(c["text"]))
			if key != "ja_known_gaps":
				n += 1
				if got != str(c["norm"]):
					diff += 1
				ok(got == str(c["norm"]), "%s #%d: want '%s' got '%s'" % [key, i, str(c["norm"]).substr(0, 30), got.substr(0, 30)])
			else:
				ok(got != str(c["norm"]), "known gap #%d still differs from the PC result" % i)
	var table: Array = g.get("ja_table_cases", []) as Array
	ok(table.size() >= 500, "ja_table_cases has at least 500 code points (%d)" % table.size())
	for t in table:
		n += 1
		var got_c: String = MissionText.norm_ja(String.chr(int(t[0])))
		if got_c != str(t[1]):
			diff += 1
		ok(got_c == str(t[1]), "table U+%04X: want '%s' got '%s'" % [int(t[0]), str(t[1]), got_c])
	var entries: Array = g.get("ja_entries", []) as Array
	for i in entries.size():
		n += 1
		var e: Dictionary = entries[i]
		var got_e: String = MissionText.norm_ja(str(e["text"]))
		if got_e != str(e["norm"]):
			diff += 1
		ok(got_e == str(e["norm"]), "ja_entries #%d normalised text" % i)
	print("golden: %d comparisons, %d differences" % [n, diff])
	ok(diff == 0 and n >= 1000, "0 differences in %d comparisons" % n)


## Properties that hold for every input, checked over the golden texts and a few more.
func _test_properties(g: Dictionary) -> void:
	print("[properties]")
	var texts: Array = []
	for key in ["ja_norm_cases", "ja_random", "ja_known_gaps", "ja_entries"]:
		for c in (g.get(key, []) as Array):
			texts.append(str(c["text"]))
	var bad_len := 0
	var bad_chars := 0
	var bad_idem := 0
	for t in texts:
		var out: String = MissionText.norm_ja(t)
		if out.length() > 300:
			bad_len += 1
		for i in out.length():
			var c: int = out.unicode_at(i)
			var keep: bool = ((c >= 0x3041 and c <= 0x3096) or c == 0x309D or c == 0x309E or c == 0x30FC
				or (c >= 0x4E00 and c <= 0x9FFF) or (c >= 0x3400 and c <= 0x4DBF) or c == 0x3005 or c == 0x3007
				or (c >= 0x61 and c <= 0x7A) or (c >= 0x30 and c <= 0x39))
			if not keep:
				bad_chars += 1
		if MissionText.norm_ja(out) != out:
			bad_idem += 1
	print("  %d texts: too long %d, characters outside the kept set %d, not idempotent %d" % [texts.size(), bad_len, bad_chars, bad_idem])
	ok(texts.size() > 400, "properties checked on %d texts" % texts.size())
	ok(bad_len == 0, "output is never longer than 300 characters")
	ok(bad_chars == 0, "output has only hiragana, ー, kanji, 々, 〇, a-z, 0-9")
	ok(bad_idem == 0, "norm_ja(norm_ja(x)) == norm_ja(x)")


## The comparisons above are only worth something if they can fail: wrong expectations must be rejected.
func _test_selfchecks() -> void:
	print("[selfcheck: wrong expectations are rejected]")
	var wrong: Array = [
		["ヷ", "ゔ"], ["ヷ", "ヷ"], ["ヷ", "わ"], ["カ", "カ"], ["ｶﾞ", "か"], ["ｶﾞ", "ガ"], ["あ ", "あ "],
		["ＡＢＣ", "ＡＢＣ"], ["A", "A"], ["、", "、"], ["あ".repeat(301), "あ".repeat(301)],
	]
	for w in wrong:
		var same: bool = MissionText.norm_ja(str(w[0])) == str(w[1])
		print("  selfcheck FAIL-as-expected: norm_ja('%s') != '%s'" % [str(w[0]).substr(0, 10), str(w[1]).substr(0, 10)])
		ok(not same, "selfcheck FAIL-as-expected: norm_ja('%s') is not '%s'" % [str(w[0]).substr(0, 10), str(w[1]).substr(0, 10)])
	# the golden comparison itself: a tampered golden value is detected
	var g: Dictionary = _load_golden()
	var arr: Array = g.get("ja_norm_cases", []) as Array
	var c: Dictionary = arr[0]
	ok(MissionText.norm_ja(str(c["text"])) != str(c["norm"]) + "x", "selfcheck FAIL-as-expected: a tampered golden norm does not compare equal")
