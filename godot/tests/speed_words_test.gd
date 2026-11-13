extends Node
## 스피드 퀴즈 단어 데이터(data/speed_words.json) + SpeedPool.load_words 시험 (서버 없이).
##   PC : godot --headless --path godot res://tests/speed_words_test.tscn
##   폰 : (화면이 없는 순수 데이터 시험이라 PC 한 번이면 된다. 같은 명령에 `-- --phone` 을 붙여도 결과는 같다)
## 마지막 줄: "== speed_words: N passed, M failed ==" (실패가 있으면 종료 코드 1)
## 일부러 틀린 입력으로 검사 함수(check_words)가 실제로 FAIL 하는지도 본다(selfcheck FAIL-as-expected).
## 시험용 파일은 user://test_fun_speed/ 에만 쓰고 끝에 지운다. 실제 사용자 파일은 건드리지 않는다.

const DATA := "res://data/speed_words.json"
const TMP_DIR := "user://test_fun_speed"
const POS_OK := ["명사", "동사", "형용사", "부사"]
const MIN_EN := 500
const MIN_JA := 600
const MAX_BYTES := 400000
const MONTH_MIN := 15
const TOOL := "res://tools/build_speed_words.gd"

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
	print("== speed_words test start ==")
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(TMP_DIR))
	_test_data_file()
	_selfcheck()
	_test_load_words()
	_test_broken_files()
	_cleanup()
	SpeedPool.words_path = SpeedPool.DATA_PATH
	SpeedPool.clear_cache()
	print("== speed_words: %d passed, %d failed ==" % [passed, failed])
	get_tree().quit(1 if failed > 0 else 0)


## 한 언어의 단어 배열이 형식에 맞는지: 틀린 곳의 설명 목록(빈 배열 = 통과).
func check_words(arr: Variant, lang: String) -> Array:
	var errs: Array = []
	if not (arr is Array):
		return ["not an array"]
	var seen := {}
	for i in (arr as Array).size():
		var e: Variant = (arr as Array)[i]
		if not (e is Dictionary):
			errs.append("#%d not a dict" % i)
			continue
		var d: Dictionary = e
		var w: Variant = d.get("w", null)
		if not (w is String) or (w as String).strip_edges() == "":
			errs.append("#%d w empty" % i)
		elif seen.has(w):
			errs.append("#%d duplicate w %s" % [i, w])
		else:
			seen[w] = true
		var ko: Variant = d.get("ko", null)
		if not (ko is String) or (ko as String).length() < 1 or (ko as String).length() > 12:
			errs.append("#%d ko length" % i)
		if not (d.get("pos", null) is String) or not ((d["pos"] as String) in POS_OK):
			errs.append("#%d pos" % i)
		var m: Variant = d.get("m", null)
		if not (m is float or m is int) or float(m) != floorf(float(m)) or float(m) < 1.0 or float(m) > 12.0:
			errs.append("#%d m" % i)
		if not (d.get("v", null) is bool):
			errs.append("#%d v not bool" % i)
		if lang == "ja":
			if not (d.get("rd", null) is String) or not _all_kana(d["rd"]):
				errs.append("#%d rd not kana" % i)
		elif d.has("rd"):
			errs.append("#%d en has rd" % i)
	return errs


func _all_kana(s: String) -> bool:
	if s == "":
		return false
	for i in s.length():
		var c := s.unicode_at(i)
		if not ((c >= 0x3041 and c <= 0x3096) or (c >= 0x30A1 and c <= 0x30FC)):
			return false
	return true


func _test_data_file() -> void:
	ok(FileAccess.file_exists(DATA), "speed_words.json exists")
	var bytes := FileAccess.get_file_as_bytes(DATA).size()
	ok(bytes > 0 and bytes <= MAX_BYTES, "file size <= %d bytes (%d)" % [MAX_BYTES, bytes])
	var j := JSON.new()
	ok(j.parse(FileAccess.get_file_as_string(DATA)) == OK and j.data is Dictionary, "file parses as a JSON object")
	var root: Dictionary = j.data if j.data is Dictionary else {}
	ok(int(root.get("v", 0)) == 1, "v == 1")
	for lang in ["en", "ja"]:
		var arr: Variant = root.get(lang, null)
		var n := (arr as Array).size() if arr is Array else 0
		ok(n >= (MIN_EN if lang == "en" else MIN_JA), "%s words >= %d (%d)" % [lang, MIN_EN if lang == "en" else MIN_JA, n])
		var errs := check_words(arr, lang)
		ok(errs.is_empty(), "%s: every entry well-formed %s" % [lang, str(errs.slice(0, 3))])
		# 달별 개수와 통과/나머지(v) 개수는 통과 여부와 별개로 보고한다.
		var per := {}
		var vtrue := 0
		var small_months: Array = []
		for e in (arr as Array if arr is Array else []):
			per[int(e["m"])] = int(per.get(int(e["m"]), 0)) + 1
			if e["v"] == true:
				vtrue += 1
		for m in range(1, 13):
			if int(per.get(m, 0)) < MONTH_MIN:
				small_months.append(m)
				print("  NOTE  %s: month %d has only %d words (< %d)" % [lang, m, int(per.get(m, 0)), MONTH_MIN])
		print("  INFO  %s: total=%d verified(v=true)=%d rest=%d per-month=%s small-months=%s" % [lang, n, vtrue, n - vtrue, str(per), str(small_months)])
		ok(vtrue > 0 and vtrue < n, "%s: some verified, some not (v is meaningful)" % lang)
		# 어느 달이든(누적 m <= 달+1) 통과 단어만으로 PREFER_POOL 이상이라 비통과 단어가 섞이지 않는다.
		var min_cum := 99999
		var min_month := 0
		for month in range(1, 13):
			var cum := 0
			for e in (arr as Array if arr is Array else []):
				if e["v"] == true and int(e["m"]) <= month + 1:
					cum += 1
			if cum < min_cum:
				min_cum = cum
				min_month = month
		print("  INFO  %s: min verified pool over months = %d (month %d)" % [lang, min_cum, min_month])
		ok(min_cum >= SpeedPool.PREFER_POOL, "%s: every month has >= %d verified words (min %d)" % [lang, SpeedPool.PREFER_POOL, min_cum])
		var ex_errs := check_excluded(arr, lang)
		ok(ex_errs.is_empty(), "%s: no excluded (wrong-meaning) word is in the file as v=true %s" % [lang, str(ex_errs.slice(0, 3))])


## 도구의 제외·교정 목록(DROP_WORDS / FIX_KO)을 읽는다(스크립트 상수만 읽고 인스턴스는 만들지 않는다).
func _tool_const(name: String) -> Dictionary:
	var sc: Variant = load(TOOL)
	if sc == null:
		return {}
	var c: Dictionary = (sc as Script).get_script_constant_map()
	return c.get(name, {}) if c.get(name, {}) is Dictionary else {}


## 제외 목록 단어가 v=true 로 남아 있거나(또는 파일에 있거나), 교정 목록 단어가 옛 뜻이 아니라 고친 뜻이 아닌 채 v=true 인 곳.
func check_excluded(arr: Variant, lang: String, drop_all: Dictionary = {}, fix_all: Dictionary = {}) -> Array:
	var errs: Array = []
	var drop_d: Dictionary = drop_all if not drop_all.is_empty() else _tool_const("DROP_WORDS")
	var fix_d: Dictionary = fix_all if not fix_all.is_empty() else _tool_const("FIX_KO")
	var drop: Array = drop_d.get(lang, [])
	var fix: Dictionary = fix_d.get(lang, {})
	if drop.is_empty() or fix.is_empty():
		return ["exclusion list is empty or unreadable"]
	if not (arr is Array):
		return ["not an array"]
	for e in arr:
		if not (e is Dictionary):
			continue
		var w := str(e.get("w", ""))
		if w in drop and e.get("v", false) == true:
			errs.append("%s is excluded but v=true" % w)
		elif w in drop:
			errs.append("%s is excluded but still in the file" % w)
		if fix.has(w) and str(e.get("ko", "")) != str(fix[w]):
			errs.append("%s has ko %s, expected %s" % [w, str(e.get("ko", "")), str(fix[w])])
	return errs


## 검사 함수가 일부러 틀린 입력을 실제로 거르는지.
func _selfcheck() -> void:
	var good := [{"w": "work", "ko": "일하다", "pos": "동사", "m": 1, "v": true}]
	ok(check_words(good, "en").is_empty(), "selfcheck: good entry passes")
	var bad_cases := {
		"empty w": [{"w": "", "ko": "일하다", "pos": "동사", "m": 1, "v": true}],
		"long ko": [{"w": "x", "ko": "가나다라마바사아자차카타파하가", "pos": "동사", "m": 1, "v": true}],
		"bad pos": [{"w": "x", "ko": "뜻", "pos": "조사", "m": 1, "v": true}],
		"m = 13": [{"w": "x", "ko": "뜻", "pos": "명사", "m": 13, "v": true}],
		"m = 1.5": [{"w": "x", "ko": "뜻", "pos": "명사", "m": 1.5, "v": true}],
		"v string": [{"w": "x", "ko": "뜻", "pos": "명사", "m": 1, "v": "yes"}],
		"duplicate w": [good[0], good[0]],
		"not a dict": [3],
		"ko number": [{"w": "x", "ko": 5, "pos": "명사", "m": 1, "v": true}],
	}
	for name in bad_cases:
		ok(not check_words(bad_cases[name], "en").is_empty(), "selfcheck FAIL-as-expected: %s" % name)
	ok(not check_words([{"w": "学校", "rd": "gakkou", "ko": "학교", "pos": "명사", "m": 1, "v": true}], "ja").is_empty(),
		"selfcheck FAIL-as-expected: ja rd not kana")
	ok(not check_words("nope", "en").is_empty(), "selfcheck FAIL-as-expected: not an array")
	var drop_en: Array = _tool_const("DROP_WORDS").get("en", [])
	var revived := [{"w": str(drop_en[0]) if not drop_en.is_empty() else "kobe", "ko": "이름", "pos": "명사", "m": 7, "v": true}]
	ok(not check_excluded(revived, "en").is_empty(), "selfcheck FAIL-as-expected: excluded word revived as v=true")
	var drop_ja: Array = _tool_const("DROP_WORDS").get("ja", [])
	ok(not check_excluded([{"w": str(drop_ja[0]) if not drop_ja.is_empty() else "寝", "rd": "ね", "ko": "들어", "pos": "동사", "m": 2, "v": true}], "ja").is_empty(),
		"selfcheck FAIL-as-expected: excluded ja word revived as v=true")
	ok(not check_excluded([{"w": "spoke", "ko": "말하다", "pos": "동사", "m": 2, "v": true}], "en").is_empty(),
		"selfcheck FAIL-as-expected: corrected word back to the old meaning")


func _test_load_words() -> void:
	SpeedPool.words_path = SpeedPool.DATA_PATH
	SpeedPool.clear_cache()
	for lang in ["en", "ja"]:
		var r := SpeedPool.load_words(lang)
		ok(bool(r["ok"]) and str(r["err"]) == "" and (r["words"] as Array).size() > 0, "load_words(%s) ok" % lang)
		var raw: Array = (r["words"] as Array).duplicate(true)
		for e in raw:
			if lang == "en" and e.get("rd", "x") == "":
				e.erase("rd")  # load_words 는 영어에도 rd "" 를 채워 준다(파일 형식에는 영어 rd 가 없다)
		ok(check_words(raw, lang).is_empty(), "load_words(%s) words well-formed" % lang)
	var bad_lang := SpeedPool.load_words("fr")
	ok(not bad_lang["ok"] and (bad_lang["words"] as Array).is_empty(), "load_words('fr') -> ok=false")
	var a := SpeedPool.load_words("en")
	(a["words"] as Array).clear()
	ok((SpeedPool.load_words("en")["words"] as Array).size() > 0, "caller clearing the returned array does not damage the cache")


func _write(name: String, text: String) -> String:
	var p := TMP_DIR.path_join(name)
	var f := FileAccess.open(p, FileAccess.WRITE)
	f.store_string(text)
	f.close()
	return p


func _load_from(path: String, lang: String) -> Dictionary:
	SpeedPool.words_path = path
	SpeedPool.clear_cache()
	return SpeedPool.load_words(lang)


## 깨진 데이터 파일: 앱이 죽지 않고 ok=false (또는 나쁜 항목만 버림).
func _test_broken_files() -> void:
	var r := _load_from(TMP_DIR.path_join("nope.json"), "en")
	ok(not r["ok"] and r["err"] == "missing", "missing file -> ok=false err=missing")
	r = _load_from(_write("broken.json", "{\"v\": 1, \"en\": [ {\"w\": "), "en")
	ok(not r["ok"] and r["err"] == "bad", "broken JSON -> ok=false err=bad")
	r = _load_from(_write("empty.json", ""), "en")
	ok(not r["ok"] and r["err"] == "bad", "empty file -> ok=false err=bad")
	r = _load_from(_write("array_root.json", "[1,2,3]"), "en")
	ok(not r["ok"] and r["err"] == "bad", "root is an array -> ok=false")
	r = _load_from(_write("no_en.json", "{\"v\":1,\"ja\":[{\"w\":\"学校\",\"rd\":\"がっこう\",\"ko\":\"학교\",\"pos\":\"명사\",\"m\":1,\"v\":true}]}"), "en")
	ok(not r["ok"] and r["err"] == "bad", "file without the en key -> load_words(en) ok=false")
	r = _load_from(TMP_DIR.path_join("no_en.json"), "ja")
	ok(r["ok"] and (r["words"] as Array).size() == 1, "the same file still serves ja")
	var mixed := "{\"v\":1,\"en\":[{\"w\":\"work\",\"ko\":\"일하다\",\"pos\":\"동사\",\"m\":1,\"v\":true},{\"w\":\"bad\",\"ko\":5,\"pos\":\"동사\",\"m\":1,\"v\":true},{\"w\":\"x\",\"ko\":\"뜻\",\"pos\":\"명사\",\"m\":99,\"v\":true},7,{\"ko\":\"뜻\"}]}"
	r = _load_from(_write("mixed.json", mixed), "en")
	ok(r["ok"] and (r["words"] as Array).size() == 1 and r["words"][0]["w"] == "work", "numeric ko / m out of range / non-dict / no w entries dropped, good one kept")
	var all_bad := "{\"v\":1,\"en\":[{\"w\":\"bad\",\"ko\":5,\"pos\":\"동사\",\"m\":1,\"v\":true}],\"ja\":[]}"
	r = _load_from(_write("all_bad.json", all_bad), "en")
	ok(not r["ok"], "only bad entries -> ok=false")
	# 깨진 데이터로도 build 가 에러 없이 끝난다.
	var b := SpeedPool.build("en", [], 1, r["words"])
	ok(not b["ok"] and b["reason"] == "pool_small", "build with no usable words -> pool_small")
	SpeedPool.words_path = SpeedPool.DATA_PATH
	SpeedPool.clear_cache()


func _cleanup() -> void:
	var d := DirAccess.open(TMP_DIR)
	if d != null:
		for f in d.get_files():
			d.remove(f)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(TMP_DIR))
