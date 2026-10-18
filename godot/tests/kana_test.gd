extends Node
## 히라가나 · 가타카나 익히기 시험 (서버 없이).
##   PC   : godot --headless --path godot res://tests/kana_test.tscn
##   폰   : godot --headless --path godot res://tests/kana_test.tscn -- --phone
## 글자표 · 문제 만들기(KanaData) / StudyLog kana 기록 / 복습 카드 / KanaScreen 화면(412 폭 표 칸 크기, 터치) 을 본다.
## 마지막 줄: "== kana result: N passed, M failed =="  (실패가 있으면 종료 코드 1)
## 시험 전용 파일 경로를 쓰고 끝에 되돌린다. 실제 사용자 파일은 건드리지 않는다.
## 일부러 망가뜨린 입력으로 검사기가 실제로 FAIL 하는지도 본다 (_validator_self_test).

const TEST_PROGRESS := "user://test_kana_progress.json"
const TEST_LOG := "user://test_kana_studylog.json"
const PHONE_SCREEN := Vector2(412, 915)
const PC_SCREEN := Vector2(1280, 800)
const DRAG_PX := 300.0
const DRAG_STEP := 10.0
const SEEDS := 200

var passed: int = 0
var failed: int = 0
var phone: bool = false
var tts_calls: Array = []
var _saved := {}
var _holder: Control = null
var _screen: KanaScreen = null
var _pressed_log: Array = []


func ok(cond: bool, name: String) -> void:
	if cond:
		passed += 1
		print("  PASS  ", name)
	else:
		failed += 1
		print("  FAIL  ", name)


func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


func _ready() -> void:
	phone = Platform.is_phone()
	print("== kana test start (%s) ==" % ("phone" if phone else "pc"))
	_setup()
	_test_table()
	_validator_self_test()
	_test_questions()
	_test_confusables()
	_test_ranges()
	_test_study_log()
	_test_sync_unaffected()
	_test_review_cards()
	await _test_screen_layout()
	await _test_screen_quiz_flow()
	await _test_no_connection()
	await _test_touch_or_click()
	_teardown()
	print("== kana result: %d passed, %d failed ==" % [passed, failed])
	get_tree().quit(1 if failed > 0 else 0)


# ---------------------------------------------------------------- setup

func _setup() -> void:
	_saved = {
		"prefs": Store.prefs.duplicate(true),
		"progress": Store.progress.duplicate(true),
		"progress_path": Store.progress_path,
		"log_path": StudyLog.path,
		"base": Api.base_url,
	}
	Store.progress_path = TEST_PROGRESS
	Store.progress = Progress.blank()
	StudyLog.path = TEST_LOG
	_rm(TEST_LOG)
	StudyLog.load_from_disk()
	StudyLog.reset()
	Store.prefs["lang"] = "ja"
	Api.base_url = "http://127.0.0.1:9" ## 닫힌 포트: 실수로 8770 서버에 닿지 않게 (소리는 fetch_hook 이 가로챈다)
	Tts.fetch_hook = Callable(self, "_tts_hook")
	if phone:
		get_window().min_size = Vector2i.ZERO
		get_window().size = Vector2i(PHONE_SCREEN)
	else:
		get_window().min_size = Vector2i.ZERO
		get_window().size = Vector2i(PC_SCREEN)


func _teardown() -> void:
	if _holder != null and is_instance_valid(_holder):
		_holder.queue_free()
	Tts.fetch_hook = Callable()
	Tts.stop()
	StudyLog.reset()
	for p in [TEST_LOG, TEST_LOG + ".tmp", TEST_LOG + ".bad", TEST_PROGRESS, TEST_PROGRESS + ".tmp"]:
		_rm(p)
	StudyLog.path = _saved["log_path"]
	Store.progress_path = _saved["progress_path"]
	Store.progress = _saved["progress"]
	Api.base_url = _saved["base"]
	Store.prefs = _saved["prefs"]
	if phone:
		Input.emulate_touch_from_mouse = false


func _tts_hook(text: String, l: String, speed: float, _voice: String) -> Variant:
	tts_calls.append({"text": text, "lang": l, "speed": speed})
	return null


func _rm(path: String) -> void:
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


func _write(path: String, text: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()


# ---------------------------------------------------------------- validators (also checked against broken input)

static func _is_hangul(s: String) -> bool:
	if s == "":
		return false
	for i in s.length():
		var c: int = s.unicode_at(i)
		if c < 0xAC00 or c > 0xD7A3:
			return false
	return true


static func _is_romaji(s: String) -> bool:
	if s == "":
		return false
	for i in s.length():
		var c: int = s.unicode_at(i)
		if c < 97 or c > 122:
			return false
	return true


## 글자 하나가 제대로 채워졌는지: 문제 있으면 이유 문자열, 없으면 "".
static func check_entry(e: Dictionary) -> String:
	for k in ["ch", "script", "hira", "ko", "ro", "sec", "grp"]:
		if not e.has(k) or str(e[k]).strip_edges() == "":
			return "empty field '%s' (%s)" % [k, str(e.get("ch", "?"))]
	if not _is_hangul(str(e["ko"])):
		return "ko is not hangul: '%s' (%s)" % [str(e["ko"]), str(e["ch"])]
	if not _is_romaji(str(e["ro"])):
		return "ro is not romaji: '%s' (%s)" % [str(e["ro"]), str(e["ch"])]
	return ""


## 문제 하나가 제대로 만들어졌는지: 보기 4개, 한글 소리 중복 없음, 글자 중복 없음, 정답 정확히 1개(소리가 같은 글자가 둘이면 안 됨).
static func check_question(q: Dictionary) -> String:
	var opts: Array = q.get("options", [])
	if opts.size() != 4:
		return "options != 4 (%d)" % opts.size()
	var kos := {}
	var chs := {}
	var right := 0
	for o in opts:
		kos[str((o as Dictionary).get("ko", ""))] = true
		chs[str((o as Dictionary).get("ch", ""))] = true
		if str((o as Dictionary).get("ko", "")) == str(q.get("ko", "-")):
			right += 1
	if kos.size() != 4:
		return "duplicate ko in options"
	if chs.size() != 4:
		return "duplicate ch in options"
	if right != 1:
		return "correct options = %d" % right
	var a: int = int(q.get("answer", -1))
	if a < 0 or a >= 4 or str((opts[a] as Dictionary).get("ch", "")) != str(q.get("ch", "-")):
		return "answer index does not point at the answer"
	return ""


func _validator_self_test() -> void:
	print("[validators reject broken input]")
	var good: Dictionary = KanaData.get_entry("か")
	ok(check_entry(good) == "", "check_entry accepts a real entry")
	var blank_ko := good.duplicate()
	blank_ko["ko"] = ""
	ok(check_entry(blank_ko) != "", "check_entry FAILS on an empty Korean sound")
	var blank_ro := good.duplicate()
	blank_ro["ro"] = "  "
	ok(check_entry(blank_ro) != "", "check_entry FAILS on an empty romaji")
	var ko_latin := good.duplicate()
	ko_latin["ko"] = "ka"
	ok(check_entry(ko_latin) != "", "check_entry FAILS on a non-hangul sound")
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var q: Dictionary = KanaData.make_question("read", KanaData.get_entry("ぬ"), KanaData.entries("hira"), rng)
	ok(check_question(q) == "", "check_question accepts a real question")
	var two := q.duplicate(true)
	var idx_other := 0
	for i in 4:
		if i != int(two["answer"]):
			idx_other = i
			break
	(two["options"] as Array)[idx_other] = KanaData.get_entry("ヌ") ## 같은 소리의 가타카나가 보기에 또 있다 -> 정답 2개
	ok(check_question(two) != "", "check_question FAILS when two options have the answer's sound (2 correct)")
	var dup_ch := q.duplicate(true)
	(dup_ch["options"] as Array)[idx_other] = (dup_ch["options"] as Array)[int(dup_ch["answer"])]
	ok(check_question(dup_ch) != "", "check_question FAILS when the answer is listed twice")
	var three := q.duplicate(true)
	(three["options"] as Array).pop_back()
	ok(check_question(three) != "", "check_question FAILS with 3 options")
	var none := q.duplicate(true)
	none["answer"] = (int(none["answer"]) + 1) % 4
	ok(check_question(none) != "", "check_question FAILS when the answer index points at a wrong option")


# ---------------------------------------------------------------- table

func _test_table() -> void:
	print("[table]")
	var hira: Array = KanaData.entries("hira")
	var kata: Array = KanaData.entries("kata")
	ok(KanaData.section_entries("hira", "seion").size() == 46, "hiragana seion = 46 (got %d)" % KanaData.section_entries("hira", "seion").size())
	var daku_total: int = KanaData.section_entries("hira", "daku").size() + KanaData.section_entries("hira", "handaku").size()
	ok(daku_total == 25, "hiragana daku + handaku = 25 (got %d)" % daku_total)
	ok(KanaData.section_entries("hira", "yoon").size() == 33, "hiragana yoon = 33 (got %d)" % KanaData.section_entries("hira", "yoon").size())
	ok(hira.size() == 104, "hiragana total 104 (got %d)" % hira.size())
	ok(KanaData.section_entries("kata", "seion").size() == 46, "katakana seion = 46")
	var kd: int = KanaData.section_entries("kata", "daku").size() + KanaData.section_entries("kata", "handaku").size()
	ok(kd == 25, "katakana daku + handaku = 25 (got %d)" % kd)
	ok(KanaData.section_entries("kata", "yoon").size() == 33, "katakana yoon = 33")
	ok(kata.size() == 104, "katakana total 104 (got %d)" % kata.size())
	var bad: Array = []
	var seen := {}
	var by_ko := {}
	var by_ro := {}
	for e in KanaData.entries("both"):
		var d: Dictionary = e
		var why := check_entry(d)
		if why != "":
			bad.append(why)
		if seen.has(d["ch"]):
			bad.append("duplicate glyph " + str(d["ch"]))
		seen[d["ch"]] = true
		by_ko[d["ko"]] = str(by_ko.get(d["ko"], "")) + "|" + str(d["ro"])
		by_ro[d["ro"]] = str(by_ro.get(d["ro"], "")) + "|" + str(d["ko"])
	ok(bad.is_empty(), "every glyph is unique and has a non-empty hangul sound and romaji %s" % str(bad.slice(0, 3)))
	var inconsistent: Array = []
	for k in by_ko.keys():
		var ros := {}
		for r in str(by_ko[k]).split("|", false):
			ros[r] = true
		if ros.size() != 1:
			inconsistent.append(k)
	for k in by_ro.keys():
		var kos := {}
		for r in str(by_ro[k]).split("|", false):
			kos[r] = true
		if kos.size() != 1:
			inconsistent.append(k)
	ok(inconsistent.is_empty(), "same hangul sound <=> same romaji %s" % str(inconsistent))
	var scripts_ok := true
	for e in hira:
		var c: int = str((e as Dictionary)["ch"]).unicode_at(0)
		if c < 0x3041 or c > 0x3096:
			scripts_ok = false
	for e in kata:
		var c2: int = str((e as Dictionary)["ch"]).unicode_at(0)
		if c2 < 0x30A1 or c2 > 0x30F6:
			scripts_ok = false
	ok(scripts_ok, "hiragana glyphs are in the hiragana block, katakana in the katakana block")
	var pairs_ok := true
	for e in hira:
		var d2: Dictionary = KanaData.get_entry(KanaData.to_katakana(str((e as Dictionary)["ch"])))
		if d2.is_empty() or d2["ko"] != (e as Dictionary)["ko"] or d2["hira"] != (e as Dictionary)["ch"]:
			pairs_ok = false
	ok(pairs_ok, "every katakana has the same sound as its hiragana and points back to it (hira field)")
	var spot := {"か": ["카", "ka"], "し": ["시", "shi"], "つ": ["츠", "tsu"], "ん": ["응", "n"], "ふ": ["후", "fu"], "を": ["오", "o"], "きゃ": ["캬", "kya"], "シ": ["시", "shi"], "ツ": ["츠", "tsu"], "ン": ["응", "n"]}
	var spot_ok := true
	for ch in spot.keys():
		var e3: Dictionary = KanaData.get_entry(ch)
		if e3.is_empty() or e3["ko"] != spot[ch][0] or e3["ro"] != spot[ch][1]:
			spot_ok = false
	ok(spot_ok, "spot checks: か카 し시 つ츠 ん응 ふ후 を오 きゃ캬 シ시 ツ츠 ン응")
	ok(KanaData.mastery(0, 0) == 0 and KanaData.mastery(0, 2) == 1 and KanaData.mastery(2, 1) == 2 and KanaData.mastery(4, 1) == 3 and KanaData.mastery(1, 1) == 1, "mastery levels 0/1/2/3")
	var rows_ok := true
	for sec in KanaData.SECTIONS:
		for r in KanaData.section_rows("hira", sec):
			if (r as Array).size() != int(KanaData.SECTION_COLS[sec]):
				rows_ok = false
	ok(rows_ok, "every table row has exactly the column count of its section (5/5/5/3)")


# ---------------------------------------------------------------- questions

func _test_questions() -> void:
	print("[questions: %d seeds]" % SEEDS)
	var errs: Array = []
	var n_q := 0
	var rng := RandomNumberGenerator.new()
	for s in SEEDS:
		for kind in KanaData.KINDS:
			for script in ["hira", "kata", "both"]:
				rng.seed = s
				var qs: Array = KanaData.build_session({"kind": kind, "script": script, "rows": [], "focus": false}, rng)
				if qs.size() != KanaData.QUIZ_N:
					errs.append("seed %d %s %s: %d questions" % [s, kind, script, qs.size()])
				for q in qs:
					n_q += 1
					var why := check_question(q)
					if why != "":
						errs.append("seed %d %s %s: %s" % [s, kind, script, why])
	ok(errs.is_empty(), "%d questions (200 seeds x read/listen x hira/kata/both): 4 options, 1 correct, no duplicates %s" % [n_q, str(errs.slice(0, 2))])
	rng.seed = 11
	var a: Array = KanaData.build_session({"kind": "read", "script": "hira"}, rng)
	rng.seed = 11
	var b: Array = KanaData.build_session({"kind": "read", "script": "hira"}, rng)
	var same := true
	for i in a.size():
		if (a[i] as Dictionary)["ch"] != (b[i] as Dictionary)["ch"]:
			same = false
	ok(same, "same seed -> same questions")
	var chs := {}
	rng.seed = 5
	for q in KanaData.build_session({"kind": "read", "script": "hira"}, rng):
		chs[(q as Dictionary)["ch"]] = true
	ok(chs.size() == KanaData.QUIZ_N, "10 questions of one session ask 10 different glyphs")
	var hits := {}
	for s in 60:
		rng.seed = s
		var qs2: Array = KanaData.build_session({"kind": "read", "script": "hira"}, rng)
		hits[(qs2[0] as Dictionary)["answer"]] = true
	ok(hits.size() >= 3, "the correct option is not always in the same place (%d different positions)" % hits.size())
	var qk: Array = KanaData.build_session({"kind": "listen", "script": "kata"}, rng)
	var all_kata := true
	for q in qk:
		for o in (q as Dictionary)["options"]:
			if (o as Dictionary)["script"] != "kata":
				all_kata = false
	ok(all_kata, "katakana scope -> options are all katakana")


func _test_confusables() -> void:
	print("[confusable groups]")
	var gs: Array = KanaData.groups("both")
	ok(gs.size() >= 12, "at least 12 groups (got %d)" % gs.size())
	var small: Array = []
	for g in gs:
		var kos := {}
		for e in KanaData.group_entries(g):
			kos[(e as Dictionary)["ko"]] = true
		if kos.size() < 4 or (g["chars"] as Array).size() != KanaData.group_entries(g).size():
			small.append(g["id"])
	ok(small.is_empty(), "every group has >= 4 glyphs with different sounds, all exist in the table %s" % str(small))
	var want := [["シ", "ツ"], ["ソ", "ン"], ["ぬ", "め"], ["わ", "ね", "れ"], ["る", "ろ"], ["さ", "ち"], ["は", "ほ"], ["ク", "ケ", "タ"]]
	var missing: Array = []
	for w in want:
		var found := false
		for g in gs:
			var all_in := true
			for ch in w:
				if not (g["chars"] as Array).has(ch):
					all_in = false
			if all_in:
				found = true
		if not found:
			missing.append("".join(PackedStringArray(w)))
	ok(missing.is_empty(), "the user's confusing sets are covered by a group %s" % str(missing))
	var errs: Array = []
	var rng := RandomNumberGenerator.new()
	var n_q := 0
	for g in gs:
		for kind in KanaData.KINDS:
			for s in 20:
				rng.seed = s
				var qs: Array = KanaData.build_session({"kind": kind, "script": g["script"], "focus": true, "group": g["id"]}, rng)
				if qs.size() != KanaData.QUIZ_N:
					errs.append("%s: %d questions" % [g["id"], qs.size()])
				for q in qs:
					n_q += 1
					var why := check_question(q)
					if why != "":
						errs.append("%s: %s" % [g["id"], why])
					if not (g["chars"] as Array).has((q as Dictionary)["ch"]):
						errs.append("%s: answer %s outside the group" % [g["id"], (q as Dictionary)["ch"]])
					for o in (q as Dictionary)["options"]:
						if not (g["chars"] as Array).has((o as Dictionary)["ch"]):
							errs.append("%s: option %s outside the group" % [g["id"], (o as Dictionary)["ch"]])
	ok(errs.is_empty(), "%d focus questions: all options come from the chosen group %s" % [n_q, str(errs.slice(0, 2))])
	errs = []
	n_q = 0
	for s in SEEDS:
		for script in ["hira", "kata", "both"]:
			rng.seed = s
			var qs2: Array = KanaData.build_session({"kind": "read", "script": script, "focus": true}, rng)
			if qs2.size() != KanaData.QUIZ_N:
				errs.append("seed %d %s: %d questions" % [s, script, qs2.size()])
			for q in qs2:
				n_q += 1
				var why2 := check_question(q)
				if why2 != "":
					errs.append(why2)
				var fit := false
				for g in KanaData.groups(script):
					var inside := (g["chars"] as Array).has((q as Dictionary)["ch"])
					for o in (q as Dictionary)["options"]:
						if not (g["chars"] as Array).has((o as Dictionary)["ch"]):
							inside = false
					if inside:
						fit = true
				if not fit:
					errs.append("seed %d %s: options of %s do not all come from one group" % [s, script, (q as Dictionary)["ch"]])
	ok(errs.is_empty(), "%d focus questions (any group): the 4 options + answer always sit in ONE confusable group %s" % [n_q, str(errs.slice(0, 2))])
	rng.seed = 1
	ok(KanaData.build_session({"kind": "read", "script": "hira", "focus": true, "group": "no_such"}, rng).is_empty(), "unknown group id -> no questions (not a crash)")
	ok(KanaData.build_session({"kind": "read", "script": "hira", "focus": true, "group": "k_shi_tsu"}, rng).is_empty(), "a katakana group id with the hiragana scope -> no questions (never katakana questions)")
	var mix_ok := true
	for q in KanaData.build_session({"kind": "read", "script": "both", "focus": true, "group": "k_shi_tsu"}, rng):
		if not ["シ", "ツ", "ソ", "ン"].has((q as Dictionary)["ch"]):
			mix_ok = false
	ok(mix_ok, "scope 'both' + a katakana group -> only that group")


func _test_ranges() -> void:
	print("[ranges]")
	var rng := RandomNumberGenerator.new()
	var errs: Array = []
	for rid in KanaData.range_ids():
		for script in ["hira", "kata", "both"]:
			var want: Array = KanaData.in_ranges(script, [rid])
			if want.is_empty():
				errs.append("range %s %s is empty" % [rid, script])
				continue
			var allowed := {}
			for e in want:
				allowed[(e as Dictionary)["ch"]] = true
			for s in 10:
				rng.seed = s
				for q in KanaData.build_session({"kind": "listen", "script": script, "rows": [rid]}, rng):
					var why := check_question(q)
					if why != "":
						errs.append("%s %s: %s" % [rid, script, why])
					if not allowed.has((q as Dictionary)["ch"]):
						errs.append("%s %s: answer %s outside the range" % [rid, script, (q as Dictionary)["ch"]])
	ok(errs.is_empty(), "every range (あ行~わ行, 탁음, 반탁음, 요음) x script: answers stay in range, options still 4 distinct %s" % str(errs.slice(0, 2)))
	var n_ya: int = KanaData.in_ranges("hira", ["ya"]).size()
	var n_wa: int = KanaData.in_ranges("hira", ["wa"]).size()
	ok(n_ya == 3 and n_wa == 3, "や行 = 3 glyphs, わ行 (わ を ん) = 3 glyphs (got %d, %d)" % [n_ya, n_wa])
	var total := 0
	for rid2 in KanaData.range_ids():
		total += KanaData.in_ranges("hira", [rid2]).size()
	ok(total == 104, "the ranges together cover all 104 hiragana exactly once (got %d)" % total)
	rng.seed = 3
	var only: Array = KanaData.build_session({"kind": "read", "script": "hira", "only": ["ぬ", "め"]}, rng)
	var only_ok := only.size() == 10
	for q in only:
		if not ["ぬ", "め"].has((q as Dictionary)["ch"]) or check_question(q) != "":
			only_ok = false
	ok(only_ok, "'only' list (retry wrong glyphs): answers come from the list, options still 4 distinct")


# ---------------------------------------------------------------- study log

func _test_study_log() -> void:
	print("[study log kana stats]")
	StudyLog.reset()
	ok(not StudyLog.snapshot().has("kana"), "a log without kana answers has no 'kana' key (old shape unchanged)")
	ok(StudyLog.kana_stat("あ") == {"ok": 0, "bad": 0}, "unknown kana -> zeros")
	ok(StudyLog.add_kana("あ", true) and StudyLog.add_kana("あ", true) and StudyLog.add_kana("あ", false) and StudyLog.add_kana("ア", false) and StudyLog.add_kana("きゃ", true), "add_kana accepts あ ア きゃ")
	var rej := [StudyLog.add_kana("", true), StudyLog.add_kana("a", true), StudyLog.add_kana("가", true), StudyLog.add_kana("あいう", true), StudyLog.add_kana("漢", true)]
	ok(not rej.has(true), "add_kana rejects empty / latin / hangul / 3 chars / kanji")
	StudyLog.add_kana_run(7, 10)
	StudyLog.add_kana_run(99, 10) ## 맞힌 수는 문제 수까지만
	StudyLog.add_kana_run(1, 0) ## 문제 0개는 무시
	ok(StudyLog.is_dirty(), "recording marks the log dirty")
	ok(StudyLog.flush(), "flush writes the file")
	ok(FileAccess.file_exists(TEST_LOG) and not FileAccess.file_exists(TEST_LOG + ".tmp"), "file written atomically (no .tmp left)")
	StudyLog.load_from_disk()
	var st: Dictionary = StudyLog.kana_stat("あ")
	ok(int(st["ok"]) == 2 and int(st["bad"]) == 1, "round trip: あ 2 right 1 wrong (got %s)" % str(st))
	ok(StudyLog.kana_stat("ア") == {"ok": 0, "bad": 1} and StudyLog.kana_stat("きゃ") == {"ok": 1, "bad": 0}, "round trip: ア 0/1, きゃ 1/0")
	var sm: Dictionary = StudyLog.kana_summary()
	ok(int(sm["runs"]) == 2 and int(sm["total"]) == 20 and int(sm["ok"]) == 17 and str(sm["last"]) != "", "round trip: summary runs 2, ok 17 / total 20, last date set (got %s)" % str(sm))
	ok(StudyLog.kana_stats().size() == 3, "kana_stats lists 3 glyphs")
	# 깨진 kana 항목은 다듬어서 읽고, 다른 칸(days 등)은 그대로
	_write(TEST_LOG, JSON.stringify({"v": 1, "saved": 5, "days": {}, "kana": {"c": {"あ": [3, 1], "x": [5, 5], "い": [-4, "z"], "う": "bad", "か": [1e30, 2]}, "runs": "many", "ok": 50, "total": 3, "last": "2026-13-45"}}))
	StudyLog.load_from_disk()
	ok(StudyLog.last_load_status == "ok", "file with a damaged kana block still loads (status %s)" % StudyLog.last_load_status)
	ok(StudyLog.kana_stat("あ") == {"ok": 3, "bad": 1} and StudyLog.kana_stat("x") == {"ok": 0, "bad": 0} and StudyLog.kana_stat("い") == {"ok": 0, "bad": 0} and StudyLog.kana_stat("う") == {"ok": 0, "bad": 0}, "damaged entries dropped, good one kept")
	var sm2: Dictionary = StudyLog.kana_summary()
	ok(int(sm2["runs"]) == 0 and int(sm2["ok"]) <= int(sm2["total"]) and str(sm2["last"]) == "", "damaged summary: runs 0, ok <= total, bad date emptied (got %s)" % str(sm2))
	ok(int(StudyLog.kana_stat("か")["ok"]) <= StudyLog.MAX_COUNT, "huge counts are clamped")
	# 가짜 키 400개로 상한(MAX_KANA)을 채운 파일: 가짜는 버려지고 진짜 글자 기록은 막히지 않는다
	var fake := {}
	for a in range(0x3041, 0x3061):
		for b in range(0x3041, 0x3061):
			var k: String = char(a) + char(b)
			if fake.size() < StudyLog.MAX_KANA and not KanaData.has(k):
				fake[k] = [1, 1]
	ok(fake.size() == StudyLog.MAX_KANA, "fixture: %d fake kana-block keys" % fake.size())
	_write(TEST_LOG, JSON.stringify({"v": 1, "saved": 5, "days": {}, "kana": {"c": fake}}))
	StudyLog.load_from_disk()
	ok(StudyLog.kana_stats().is_empty(), "fake keys (400 odd two-character kana strings) are all dropped on load")
	ok(StudyLog.add_kana("あ", true) and StudyLog.add_kana("ア", false) and StudyLog.add_kana("きゃ", true) and StudyLog.add_kana("ン", true), "with a file full of fake keys, real glyphs are still recorded")
	ok(not StudyLog.add_kana("ぁぃ", true) and not StudyLog.add_kana("ゔ", true), "kana-range strings that are not in the table are rejected")
	ok(StudyLog.flush(), "...and saved")
	StudyLog.load_from_disk()
	ok(StudyLog.kana_stats().size() == 4 and int(StudyLog.kana_stat("あ")["ok"]) == 1, "...and read back (4 real glyphs, no fake ones)")
	_write(TEST_LOG, JSON.stringify({"v": 1, "saved": 5, "days": {}, "kana": "oops"}))
	StudyLog.load_from_disk()
	ok(StudyLog.kana_stats().is_empty() and int(StudyLog.kana_summary()["runs"]) == 0, "kana block of the wrong type -> empty, no crash")
	_write(TEST_LOG, JSON.stringify({"v": 1, "saved": 5, "days": {}}))
	StudyLog.load_from_disk()
	ok(StudyLog.kana_stats().is_empty(), "file without kana -> empty")
	StudyLog.add_kana("さ", true)
	ok(StudyLog.flush(), "first answer on an old file saves")
	StudyLog.load_from_disk()
	ok(int(StudyLog.kana_stat("さ")["ok"]) == 1, "...and reads back")
	StudyLog.reset()
	ok(StudyLog.kana_stats().is_empty() and not StudyLog.snapshot().has("kana"), "reset clears kana too")


func _test_sync_unaffected() -> void:
	print("[sync extraction ignores kana]")
	StudyLog.reset()
	StudyLog.add_event("ja", "lessons", 1)
	var snap0: Dictionary = StudyLog.snapshot()
	StudyLog.add_kana("あ", true)
	StudyLog.add_kana_run(1, 1)
	var snap1: Dictionary = StudyLog.snapshot()
	ok(snap1.has("kana") and not snap0.has("kana"), "snapshot gains a kana block after an answer")
	var prog := Progress.blank()
	var d0: String = SyncMerge.canonical(SyncDoc.extract(prog, snap0, {}, 0))
	var d1: String = SyncMerge.canonical(SyncDoc.extract(prog, snap1, {}, 0))
	ok(d0 == d1, "SyncDoc.extract gives the same document with and without kana (kana is not synchronised)")
	var v: Dictionary = SyncDoc.extract(prog, snap1, {}, 0)
	ok(not JSON.stringify(v).contains("kana"), "the extracted document does not mention kana")
	ok(StudyLog.apply_sync({"days": snap1["days"], "phon": snap1["phon"], "missions": snap1["missions"]}), "apply_sync works on a log that has kana")
	ok(int(StudyLog.kana_stat("あ")["ok"]) == 1, "apply_sync keeps the local kana block")
	StudyLog.reset()


# ---------------------------------------------------------------- review cards

func _test_review_cards() -> void:
	print("[review cards from wrong glyphs]")
	Store.progress = Progress.blank()
	StudyLog.reset()
	var s := KanaScreen.new()
	add_child(s)
	s.open("ja")
	s.rng.seed = 21
	ok(s.start_quiz({"kind": "read", "script": "both", "rows": [], "focus": false}, 21), "quiz starts")
	ok(s.questions.size() == 10, "10 questions")
	for i in 10:
		var q: Dictionary = s.current()
		var right: int = int(q["answer"])
		var pick: int = right if i % 2 == 0 else (right + 1) % 4
		s.answer(pick)
		if i < 9:
			s.next_question()
	var wrong: Array = s.wrong_entries()
	ok(s.correct_count() == 5 and wrong.size() == 5, "5 right, 5 wrong (got %d, %d)" % [s.correct_count(), wrong.size()])
	s.finish()
	ok(s.stage == "result" and s.rate_pct() == 50, "result stage, 50%% (got %s %d)" % [s.stage, s.rate_pct()])
	var n1: int = s.add_wrong_to_review()
	ok(n1 == 5, "5 cards added (got %d)" % n1)
	var cards: Array = Store.review_for("ja")
	var shape_ok := cards.size() == 5
	for c in cards:
		var e: Dictionary = KanaData.get_entry(str((c as Dictionary)["target"]))
		if e.is_empty() or (c as Dictionary)["lang"] != "ja" or (c as Dictionary)["reading"] != e["hira"] or (c as Dictionary)["ko"] != e["ko"]:
			shape_ok = false
	ok(shape_ok, "cards: lang ja, target = glyph, reading = hiragana, ko = hangul sound")
	var n2: int = s.add_wrong_to_review()
	ok(n2 == 0 and Store.review_for("ja").size() == 5, "adding again -> 0 new cards, still 5 (no duplicates)")
	var s2 := KanaScreen.new()
	add_child(s2)
	s2.open("ja")
	s2.start_quiz({"kind": "listen", "script": "both"}, 22)
	for i in 10:
		s2.answer((int(s2.current()["answer"]) + 1) % 4)
		if i < 9:
			s2.next_question()
	var dup_before: int = Store.review_for("ja").size()
	var n3: int = s2.add_wrong_to_review()
	var targets := {}
	for c in Store.review_for("ja"):
		targets[(c as Dictionary)["target"]] = true
	ok(Store.review_for("ja").size() == dup_before + n3 and targets.size() == Store.review_for("ja").size(), "a second quiz's wrong glyphs add only the new ones; no target appears twice")
	ok(StudyLog.kana_summary()["runs"] == 1, "finish() logged exactly one run (the second quiz is not finished yet)")
	s2.finish()
	s2.finish()
	ok(StudyLog.kana_summary()["runs"] == 2 and StudyLog.kana_summary()["total"] == 20, "finish() twice still logs one run (runs 2, total 20)")
	var rs := StudyLog.kana_stats()
	var counted := 0
	for k in rs.keys():
		counted += int((rs[k] as Array)[0]) + int((rs[k] as Array)[1])
	ok(counted == 20, "per-glyph answers add up to the 20 answered questions (got %d)" % counted)
	var empty_s := KanaScreen.new()
	add_child(empty_s)
	empty_s.open("ja")
	empty_s.start_quiz({"kind": "read", "script": "hira"}, 3)
	for i in 10:
		empty_s.answer(int(empty_s.current()["answer"]))
		if i < 9:
			empty_s.next_question()
	ok(empty_s.wrong_entries().is_empty() and empty_s.add_wrong_to_review() == 0, "no wrong glyphs -> no cards")
	ok(not empty_s.retry_wrong(), "retry_wrong with nothing wrong does nothing")
	var rw := KanaScreen.new()
	add_child(rw)
	rw.open("ja")
	rw.start_quiz({"kind": "read", "script": "hira", "focus": true}, 4)
	rw.answer((int(rw.current()["answer"]) + 1) % 4)
	rw.next_question()
	rw.answer((int(rw.current()["answer"]) + 1) % 4)
	var ws: Array = rw.wrong_entries()
	ok(rw.retry_wrong() and rw.stage == "quiz", "retry_wrong starts a quiz")
	var only_wrong := true
	for q in rw.questions:
		if not ws.any(func(e: Dictionary) -> bool: return e["ch"] == q["ch"]):
			only_wrong = false
	ok(only_wrong and bool(rw.cfg["focus"]) and not rw.cfg.has("only"), "retry quiz asks only the wrong glyphs; the screen's own settings are restored")
	for x in [s, s2, empty_s, rw]:
		x.queue_free()


# ---------------------------------------------------------------- screen

func _make_screen() -> KanaScreen:
	if _holder != null and is_instance_valid(_holder):
		_holder.queue_free()
	_holder = Control.new()
	_holder.size = PHONE_SCREEN if phone else PC_SCREEN
	_holder.clip_contents = true
	add_child(_holder)
	_screen = KanaScreen.new()
	_holder.add_child(_screen)
	_screen.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	return _screen


func _test_screen_layout() -> void:
	print("[screen layout: %s]" % ("412x915 phone" if phone else "1280x800 pc"))
	if phone:
		PhoneLayout.install_touch_scroll(get_tree())
	Api.base_url = "http://127.0.0.1:9"
	var s := _make_screen()
	s.open("ja")
	await _frames(4)
	var page: PageScroll = s._shell["page"]
	ok(s.stage == "table", "opens on the table")
	ok(s.cells.size() == 104, "hiragana table has 104 cells (got %d)" % s.cells.size())
	var min_w := 1e9
	var min_h := 1e9
	var max_right := 0.0
	var page_rect: Rect2 = page.get_global_rect()
	for ch in s.cells.keys():
		var c: Control = s.cells[ch]
		min_w = minf(min_w, c.size.x)
		min_h = minf(min_h, c.size.y)
		max_right = maxf(max_right, c.get_global_rect().end.x)
	ok(min_w >= 48.0 and min_h >= 48.0, "every cell is at least 48x48 (smallest %.1f x %.1f)" % [min_w, min_h])
	var hbar := page.get_h_scroll_bar()
	ok(max_right <= page_rect.end.x + 0.5, "no cell sticks out to the right (right edge %.1f, page %.1f)" % [max_right, page_rect.end.x])
	ok(not hbar.visible or hbar.max_value - hbar.page < 1.0, "no horizontal scrolling")
	var g0: GridContainer = s.grids[0]
	ok(g0.columns == 5, "seion grid has 5 columns")
	var a_row: Array = []
	for ch in ["あ", "い", "う", "え", "お"]:
		a_row.append(s.cells[ch])
	var same_row := true
	for i in 5:
		if absf((a_row[i] as Control).global_position.y - (a_row[0] as Control).global_position.y) > 0.5:
			same_row = false
		if i > 0 and (a_row[i] as Control).global_position.x <= (a_row[i - 1] as Control).global_position.x:
			same_row = false
	ok(same_row, "あ い う え お sit in one row, left to right")
	ok(absf((s.cells["か"] as Control).global_position.y - (s.cells["あ"] as Control).global_position.y) > 40.0, "か行 is on the next row")
	if phone:
		ok(max_right <= PHONE_SCREEN.x, "phone: table fits in 412 px (right edge %.1f)" % max_right)
		ok(absf((s.cells["あ"] as Control).size.x - 71.0) < 4.0, "phone: cell is about 71 px wide (got %.1f)" % (s.cells["あ"] as Control).size.x)
	# 소리 · 로마자 글자가 칸 안에 보이는지 (라벨 내용)
	var texts: Array = []
	_collect_label_text(s.cells["し"], texts)
	ok(texts.has("し") and texts.has("시") and texts.has("shi"), "cell し shows glyph, hangul sound and romaji (%s)" % str(texts))
	# 익힘 점
	StudyLog.reset()
	for i in 5:
		StudyLog.add_kana("か", true)
	StudyLog.add_kana("き", false)
	s.open("ja")
	await _frames(3)
	ok((s.cells["か"] as Object).get("level") == 3 and (s.cells["き"] as Object).get("level") == 1 and (s.cells["く"] as Object).get("level") == 0, "dots follow the log: か level 3, き level 1, く level 0")
	# 가타카나 전환
	s._on_table_script("kata")
	await _frames(3)
	ok(s.cells.size() == 104 and s.cells.has("シ") and not s.cells.has("し"), "katakana view has 104 katakana cells")
	var kmin := 1e9
	for ch in s.cells.keys():
		kmin = minf(kmin, minf((s.cells[ch] as Control).size.x, (s.cells[ch] as Control).size.y))
	ok(kmin >= 48.0, "katakana cells also >= 48 (smallest %.1f)" % kmin)
	var yoon_cols: GridContainer = s.grids[3]
	ok(yoon_cols.columns == 3, "yoon grid has 3 columns")
	s._on_table_script("hira")
	# 일본어가 아닌 탭
	s.open("en")
	await _frames(2)
	ok(s.stage == "unsupported" and s.cells.is_empty(), "English tab: unsupported screen, no table")
	ok(KanaScreen.available("ja") and not KanaScreen.available("en"), "available(): ja yes, en no")
	var closed_n := [0]
	s.closed.connect(func() -> void: closed_n[0] += 1)
	ok(s.go_back() and closed_n[0] == 1, "back from the table emits closed once")
	# 설정 화면
	s.open("ja")
	s.open_setup()
	await _frames(2)
	ok(s.stage == "setup" and s.pool_size() == 104, "setup screen: 104 glyphs by default (got %d)" % s.pool_size())
	s.toggle_row("ya")
	ok(s.pool_size() == 3, "range や行 -> 3 glyphs")
	s.set_cfg("focus", true)
	ok(s.pool_size() > 0 and (s.cfg["rows"] as Array).is_empty(), "focus mode lists confusable glyphs and clears the row range")
	s.set_cfg("script", "both")
	s.set_cfg("focus", false)
	ok(s.pool_size() == 208, "both scripts, all rows -> 208 glyphs (got %d)" % s.pool_size())
	ok(s.go_back() and s.stage == "table" and closed_n[0] == 1, "back from setup returns to the table, not the hub")


func _collect_label_text(n: Node, out: Array) -> void:
	for c in n.get_children():
		if c is Label:
			out.append((c as Label).text)
		_collect_label_text(c, out)


func _test_screen_quiz_flow() -> void:
	print("[screen quiz flow]")
	Api.base_url = "http://127.0.0.1:9"
	StudyLog.reset()
	Store.progress = Progress.blank()
	var s := _make_screen()
	s.open("ja")
	ok(s.start_quiz({"kind": "read", "script": "kata", "rows": ["ya"], "focus": false}, 9), "start quiz (katakana, ヤ行)")
	await _frames(3)
	ok(s.option_buttons.size() == 4, "4 option buttons")
	var q: Dictionary = s.current()
	ok(q["script"] == "kata" and ["ヤ", "ユ", "ヨ"].has(q["ch"]), "question glyph is a ヤ行 katakana (%s)" % q["ch"])
	var texts_ok := true
	for i in 4:
		if (s.option_buttons[i] as Button).text != str(q["options"][i]["ko"]):
			texts_ok = false
	ok(texts_ok, "read quiz: buttons show the hangul sounds")
	var before: int = s.answered_count()
	(s.option_buttons[(int(q["answer"]) + 1) % 4] as Button).pressed.emit()
	ok(s.answered_count() == before + 1 and not s.answers[0]["ok"], "pressing a wrong option answers once, marked wrong")
	(s.option_buttons[int(q["answer"])] as Button).pressed.emit()
	ok(s.answered_count() == before + 1 and not s.answers[0]["ok"], "a second press on the same question is ignored")
	ok(StudyLog.kana_stat(q["ch"]) == {"ok": 0, "bad": 1}, "StudyLog got the wrong answer for %s" % q["ch"])
	ok(not s.answer(9) and not s.answer(-1), "answer() outside 0..3 is ignored")
	s.next_question()
	ok(s.idx == 1, "next goes to question 2")
	s.next_question() ## 풀지 않고 넘어가기는 안 된다
	ok(s.idx == 1, "next without answering does nothing")
	for i in range(1, 10):
		s.answer(int(s.current()["answer"]))
		if i < 9:
			s.next_question()
	ok(s.correct_count() == 9 and s.answered_count() == 10, "9 of 10 right")
	s.next_question()
	ok(s.stage == "result" and s.finished, "after the last answer, next shows the result")
	ok(StudyLog.kana_summary()["runs"] == 1 and StudyLog.kana_summary()["ok"] == 9, "run logged: 9 / 10")
	ok(FileAccess.file_exists(TEST_LOG), "study log flushed to disk at the result")
	StudyLog.load_from_disk()
	ok(StudyLog.kana_summary()["total"] == 10, "read back after reload: total 10")
	await _frames(2)
	var found_review: bool = _has_text(s._shell["page"], "틀린 글자 복습 카드로 추가")
	var found_rate: bool = _has_text(s._shell["page"], "정답률 90%")
	ok(found_review and found_rate, "result page shows 정답률 90% and the add-to-review button")
	# 소리 -> 글자
	s.start_quiz({"kind": "listen", "script": "hira", "rows": [], "focus": false}, 10)
	await _frames(4)
	var cq: Dictionary = s.current()
	var glyph_ok := true
	for i in 4:
		if (s.option_buttons[i] as Button).text != str(cq["options"][i]["ch"]):
			glyph_ok = false
	ok(glyph_ok, "listen quiz: buttons show the glyphs")
	ok(tts_calls.size() > 0 and tts_calls.back()["text"] == cq["ch"] and tts_calls.back()["lang"] == "ja", "listen quiz plays the question glyph in Japanese (%s)" % str(tts_calls.back() if not tts_calls.is_empty() else {}))
	# 헷갈림 모드 화면
	s.start_quiz({"kind": "read", "script": "kata", "focus": true, "group": "k_shi_tsu"}, 12)
	var in_group := true
	for qq in s.questions:
		for o in qq["options"]:
			if not ["シ", "ツ", "ソ", "ン"].has(o["ch"]):
				in_group = false
	ok(in_group, "screen: focus group シ ツ ソ ン -> every option is one of those four")
	# 뒤로
	s.go_back()
	ok(s.stage == "table", "back from a quiz returns to the table")


func _has_text(n: Node, needle: String) -> bool:
	for c in n.get_children():
		if (c is Label or c is Button) and str(c.text).contains(needle):
			return true
		if _has_text(c, needle):
			return true
	return false


func _test_no_connection() -> void:
	print("[no connection: silent]")
	Api.base_url = ""
	tts_calls.clear()
	StudyLog.reset()
	var s := _make_screen()
	s.open("ja")
	await _frames(3)
	var before_sent: int = Api.sent_count
	ok(not KanaScreen.sound_available(), "sound_available() is false without an address")
	s.tap_cell("か")
	await _frames(3)
	ok(tts_calls.is_empty() and s.silent_requests == 1 and s.sound_requests == 0, "tapping a cell with no connection plays nothing (tts %d, silent %d)" % [tts_calls.size(), s.silent_requests])
	ok(s.last_ch == "か", "...but the cell is still selected / explained")
	ok(_has_text(s._shell["footer_col"], KanaScreen.NO_SOUND_TEXT), "a one-line notice says why there is no sound")
	ok(Api.sent_count == before_sent, "no request left through Api")
	s.start_quiz({"kind": "listen", "script": "hira"}, 5)
	await _frames(3)
	ok(tts_calls.is_empty(), "listen quiz does not try to play without a connection")
	ok(_has_text(s._shell["page"], "로마자 힌트"), "listen quiz shows a romaji hint instead of sound")
	for i in 10:
		s.answer(int(s.current()["answer"]))
		if i < 9:
			s.next_question()
	s.next_question()
	ok(s.stage == "result" and s.correct_count() == 10, "the quiz runs to the result without sound")
	ok(tts_calls.is_empty() and Api.sent_count == before_sent, "...with no sound request and no network call at all")
	Api.base_url = "http://127.0.0.1:9"


# ---------------------------------------------------------------- touch / click

func _touch(pos: Vector2, pressed: bool) -> void:
	var e := InputEventScreenTouch.new()
	e.index = 0
	e.position = pos
	e.pressed = pressed
	Input.parse_input_event(e)


func _drag_ev(pos: Vector2, rel: Vector2) -> void:
	var e := InputEventScreenDrag.new()
	e.index = 0
	e.position = pos
	e.relative = rel
	e.velocity = rel * 60.0
	Input.parse_input_event(e)


func _mouse(pos: Vector2, pressed: bool) -> void:
	var e := InputEventMouseButton.new()
	e.button_index = MOUSE_BUTTON_LEFT
	e.position = pos
	e.global_position = pos
	e.pressed = pressed
	e.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed else 0
	Input.parse_input_event(e)


func _mouse_move(pos: Vector2, held: bool = false) -> void:
	var e := InputEventMouseMotion.new()
	e.position = pos
	e.global_position = pos
	e.relative = Vector2(0, -DRAG_STEP) if held else Vector2.ZERO
	e.button_mask = MOUSE_BUTTON_MASK_LEFT if held else 0
	Input.parse_input_event(e)


func _watch(n: Node) -> void:
	if n is BaseButton and not (n as BaseButton).pressed.is_connected(_on_btn_pressed.bind(n)):
		(n as BaseButton).pressed.connect(_on_btn_pressed.bind(n))
	for c in n.get_children():
		_watch(c)


func _on_btn_pressed(b: BaseButton) -> void:
	_pressed_log.append(str(b.name))


func _test_touch_or_click() -> void:
	print("[%s]" % ("touch: drag scrolls, tap plays once" if phone else "click: one click plays once"))
	Api.base_url = "http://127.0.0.1:9"
	tts_calls.clear()
	StudyLog.reset()
	var s := _make_screen()
	s.open("ja")
	await _frames(4)
	var page: PageScroll = s._shell["page"]
	if phone:
		Input.emulate_touch_from_mouse = true
		Input.use_accumulated_input = false
		ok(DisplayServer.is_touchscreen_available(), "touchscreen available (emulated)")
	_watch(s)
	# --- 칸 위에서 300px 끌기
	var starts: Array = ["か", "ま", "し", "は"]
	for ch in starts:
		page.scroll_vertical = 0
		await _frames(3)
		var cell: Control = s.cell_for(ch)
		if cell == null:
			ok(false, "cell %s exists" % ch)
			continue
		var pos: Vector2 = cell.get_global_rect().get_center()
		var plays0: int = tts_calls.size()
		var req0: int = s.sound_requests
		_pressed_log.clear()
		var last0: String = s.last_ch
		var v0: int = page.scroll_vertical
		if phone:
			_touch(pos, true)
			await get_tree().process_frame
			for i in int(DRAG_PX / DRAG_STEP):
				pos.y -= DRAG_STEP
				_drag_ev(pos, Vector2(0, -DRAG_STEP))
				await get_tree().process_frame
			_touch(pos, false)
		else:
			# PC: 마우스로 끌어도 칸이 눌리지는 않는다 (눌렀다가 칸 밖에서 뗌)
			_mouse_move(pos)
			await get_tree().process_frame
			_mouse(pos, true)
			await get_tree().process_frame
			for i in int(DRAG_PX / DRAG_STEP):
				pos.y -= DRAG_STEP
				_mouse_move(pos, true)
				await get_tree().process_frame
			_mouse(pos, false)
		await _frames(30)
		var moved: int = page.scroll_vertical - v0
		if phone:
			ok(moved >= 200, "drag 300 px up from cell %s scrolls the page >= 200 (moved %d)" % [ch, moved])
		ok(tts_calls.size() == plays0 and s.sound_requests == req0 and s.last_ch == last0 and _pressed_log.is_empty(), "drag from cell %s: 0 plays, 0 selections, 0 presses (plays %d, pressed %s)" % [ch, tts_calls.size() - plays0, str(_pressed_log)])
	# --- 탭 1번 = 재생 1번
	page.scroll_vertical = 0
	await _frames(5)
	var tcell: Control = s.cell_for("さ")
	var tpos: Vector2 = tcell.get_global_rect().get_center()
	tts_calls.clear()
	var req1: int = s.sound_requests
	_pressed_log.clear()
	if phone:
		_touch(tpos, true)
		await _frames(3)
		_touch(tpos, false)
	else:
		_mouse_move(tpos)
		await _frames(2)
		_mouse(tpos, true)
		await _frames(2)
		_mouse(tpos, false)
	await _frames(8)
	ok(s.sound_requests == req1 + 1 and tts_calls.size() == 1 and tts_calls[0]["text"] == "さ" and tts_calls[0]["lang"] == "ja", "one tap on さ -> exactly 1 sound request for さ in Japanese (requests %d, tts %d)" % [s.sound_requests - req1, tts_calls.size()])
	ok(s.last_ch == "さ" and _pressed_log.count("pressed") + _pressed_log.size() >= 1, "...and the cell is selected")
	# 칸 안 라벨 위를 눌러도 한 번
	tts_calls.clear()
	var lab_pos: Vector2 = (s.cell_for("ち") as Control).get_global_rect().position + Vector2(10, 8)
	if phone:
		_touch(lab_pos, true)
		await _frames(3)
		_touch(lab_pos, false)
	else:
		_mouse_move(lab_pos)
		await _frames(2)
		_mouse(lab_pos, true)
		await _frames(2)
		_mouse(lab_pos, false)
	await _frames(8)
	ok(tts_calls.size() == 1 and tts_calls[0]["text"] == "ち", "a tap on the glyph label of ち also plays once")
	# --- 퀴즈 보기 위에서 끌기 / 탭
	if phone:
		page.scroll_vertical = 0
		s.start_quiz({"kind": "read", "script": "hira"}, 1)
		await _frames(5)
		_watch(s)
		var ob: Button = s.option_buttons[0]
		var opos: Vector2 = ob.get_global_rect().get_center()
		_pressed_log.clear()
		var answered0: int = s.answered_count()
		_touch(opos, true)
		await get_tree().process_frame
		for i in 12:
			opos.y -= DRAG_STEP
			_drag_ev(opos, Vector2(0, -DRAG_STEP))
			await get_tree().process_frame
		_touch(opos, false)
		await _frames(5)
		ok(s.answered_count() == answered0, "a drag that starts on a quiz option answers nothing")
		page.scroll_vertical = 0
		await _frames(3)
		var tp: Vector2 = (s.option_buttons[1] as Button).get_global_rect().get_center()
		_touch(tp, true)
		await _frames(3)
		_touch(tp, false)
		await _frames(5)
		ok(s.answered_count() == answered0 + 1, "a tap on a quiz option answers once")
	Input.emulate_touch_from_mouse = false
