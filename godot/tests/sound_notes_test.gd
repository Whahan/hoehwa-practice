extends Node
## v2.0.1 F1 (docs/v201_design.md §5.10 F1-1..F1-6): 1주 알파벳·짧은 모음 소리 노트 [듣기]. 서버 없이.
##   PC   : godot --headless --path godot res://tests/sound_notes_test.tscn -- --api=http://127.0.0.1:9
##   폰   : godot --headless --path godot --resolution 412x915 res://tests/sound_notes_test.tscn -- --phone --api=http://127.0.0.1:9
##   옵션 : -- [--phone] [--font-scale=1.5] [--dark]
## 마지막 줄: "== sound_notes: N passed, M failed (presses: P) ==" (실패가 있으면 종료 코드 1)
## 흐름은 실제 버튼의 pressed.emit() 으로 간다(출력의 "press: ..." 줄): 코스 홈 1주 노드 -> 주 시트의 [알파벳·모음 소리 듣기] -> 소리 시트 ->
## [듣기] 31개. 읽는 글은 Tts.fetch_hook 이 받은 글로 단언한다(실제 Tts.speak 경로). SoundNotesSheet.speak_hook 은 두 번째 길로 따로 본다.
## 데이터는 실제 출시 데이터(res://data/course, 1~16주). 검사기는 일부러 틀린 입력도 넣어 실제로 실패하는지 본다("selfcheck FAIL-as-expected ...").
## 시험 전용 파일(user://test_f1_*)만 쓰고 끝에 되돌린다. 주소는 닫힌 포트(9)다.

const PROG := "user://test_f1_progress.json"
const PREFS := "user://test_f1_prefs.json"
const LOG := "user://test_f1_studylog.json"
const CS := "user://test_f1_course.json"
const GONE_DIR := "res://tests/fixtures/__not_here__"
const SRC_ALL := ["res://scripts/core/course_sound_notes.gd", "res://scripts/ui/sound_notes_sheet.gd", "res://scripts/views/course_home.gd", "res://tests/sound_notes_test.gd"]
const PHONE_SCREEN := Vector2(412, 820)
const PC_SCREEN := Vector2(1100, 760)
const NOW_ISO := "2026-11-14"
## 설계 §5.10 F1-2 의 표: n0103 .. n0133 (31개).
const WANT := ["ay", "bee", "see", "dee", "ee", "eff", "gee", "aitch", "eye", "jay", "kay", "el", "em", "en", "oh", "pee", "cue", "ar", "ess", "tee",
	"you", "vee", "double-you", "ex", "why", "zed", "cat, bag, hat", "bed, red, pen", "big, sit", "hot, dog", "bus, cup"]

var passed: int = 0
var failed: int = 0
var presses: int = 0
var phone: bool = false
var _scheme: String = "light"
var _font_scale: float = 1.0
var _screen: Vector2 = PC_SCREEN
var lv: LessonView = null
var _saved: Dictionary = {}
var _before: Array = []
var _reached: Array = []
var _heard: Array = [] ## Tts.fetch_hook 이 받은 [text, lang]
var _hooked: Array = [] ## SoundNotesSheet.speak_hook 이 받은 [text, lang]
var _avail: int = 0


func ok(cond: bool, name: String) -> void:
	if cond:
		passed += 1
		print("  PASS  ", name)
	else:
		failed += 1
		print("  FAIL  ", name)


func eq(got: Variant, want: Variant, name: String) -> void:
	var good: bool = typeof(got) == typeof(want) and got == want
	ok(good, name if good else "%s  got=%s want=%s" % [name, str(got), str(want)])


## 검사기가 "실패로 판정"해야 하는 입력: 실패로 판정하면 통과로 센다.
func fails(verdict_is_bad: bool, name: String) -> void:
	if verdict_is_bad:
		passed += 1
		print("  PASS  selfcheck FAIL-as-expected: ", name)
	else:
		failed += 1
		print("  FAIL  selfcheck did NOT fail: ", name)


func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


func _ready() -> void:
	phone = Platform.is_phone()
	_screen = PHONE_SCREEN if phone else PC_SCREEN
	for a in OS.get_cmdline_user_args():
		if a == "--dark":
			_scheme = "dark"
		elif a.begins_with("--font-scale="):
			var raw: String = a.substr(13)
			_font_scale = raw.to_float() if raw.is_valid_float() else 1.0
	UiBoot.apply(get_tree().root, _scheme, _font_scale)
	print("== sound_notes start (%s, scheme=%s, font_scale=%s) ==" % ["phone" if phone else "pc", _scheme, Ds.font_scale])
	ok(is_equal_approx(Ds.font_scale, Ds.sanitize_scale(_font_scale)) and Pal.is_dark() == (_scheme == "dark"), "the run uses the asked text scale and colour scheme")
	_before = _user_listing()
	_setup()
	_selfcheck()
	_sec_rule_real_data()
	_sec_wrong_input()
	await _sec_buttons()
	await _sec_no_data()
	_sec_source()
	_teardown()
	for s in ["selfcheck", "rule", "wrong_input", "buttons", "no_data", "source"]:
		ok(_reached.has(s), "section '%s' ran to its end" % s)
	ok(_before == _user_listing(), "user:// listing unchanged by this test")
	print("== sound_notes: %d passed, %d failed (presses: %d) ==" % [passed, failed, presses])
	get_tree().quit(1 if failed > 0 else 0)


# ---------------------------------------------------------------- setup

func _user_listing() -> Array:
	var out: Array = []
	var d := DirAccess.open("user://")
	if d == null:
		return out
	for n in d.get_files():
		out.append("f:%s:%d" % [n, FileAccess.get_file_as_bytes("user://" + n).size()])
	for n in d.get_directories():
		out.append("d:" + n)
	out.sort()
	return out


func _setup() -> void:
	_saved = {"prefs": Store.prefs.duplicate(true), "progress": Store.progress.duplicate(true), "progress_path": Store.progress_path,
		"prefs_path": Store.prefs_path, "log_path": StudyLog.path, "cs": CourseStore.path, "base": CourseData.base_dir,
		"api": Api.base_url, "route": Route.mode, "anim": Sheet.animate, "phone_hook": Route.phone_hook, "speak_hook": SoundNotesSheet.speak_hook}
	Store.progress_path = PROG
	Store.prefs_path = PREFS
	StudyLog.path = LOG
	CourseStore.path = CS
	Api.base_url = "http://127.0.0.1:9" ## 닫힌 포트: 실제 PC 서버에 닿지 않게
	Tts.fetch_hook = Callable(self, "_tts_hook")
	SoundNotesSheet.speak_hook = Callable()
	Route.phone_hook = Callable(self, "_yes")
	Route.mode = "phone"
	Sheet.animate = false
	get_window().min_size = Vector2i.ZERO
	get_window().size = Vector2i(_screen)


func _teardown() -> void:
	if lv != null and is_instance_valid(lv):
		lv.queue_free()
	Tts.fetch_hook = Callable()
	Tts.stop()
	_close_sheets()
	StudyLog.reset()
	_rm_all()
	CourseData.base_dir = _saved["base"]
	CourseData.reset()
	Store.progress_path = _saved["progress_path"]
	Store.prefs_path = _saved["prefs_path"]
	StudyLog.path = _saved["log_path"]
	CourseStore.path = _saved["cs"]
	Store.progress = _saved["progress"]
	Store.prefs = _saved["prefs"]
	Api.base_url = _saved["api"]
	Route.mode = _saved["route"]
	Route.phone_hook = _saved["phone_hook"]
	Sheet.animate = _saved["anim"]
	SoundNotesSheet.speak_hook = _saved["speak_hook"]


func _rm_all() -> void:
	for base in [PROG, PREFS, LOG, CS]:
		for suffix in ["", ".tmp", ".bad", ".bad.1", ".bad.2"]:
			if FileAccess.file_exists(base + suffix):
				DirAccess.remove_absolute(ProjectSettings.globalize_path(base + suffix))


func _world() -> void:
	_close_sheets()
	_rm_all()
	Store.progress = Progress.blank()
	Store.prefs = Store.DEFAULT_PREFS.duplicate(true)
	Store.prefs["lang"] = "en"
	StudyLog.reset()
	CourseStore.reset_memory()
	CourseStore.today_override = Plan.iso_to_days(NOW_ISO)
	CourseData.base_dir = _saved["base"]
	CourseData.reset()
	CourseFeed.reset()
	_avail = CourseData.available_weeks()


func _yes() -> bool:
	return true


func _tts_hook(text: String, lang: String, _speed: float, _voice: String) -> Variant:
	_heard.append([text, lang])
	return null


func _on_speak(text: String, lang: String) -> void:
	_hooked.append([text, lang])


func _close_sheets() -> void:
	var guard: int = 0
	while Sheet.is_open() and guard < 12:
		Sheet.close_top()
		guard += 1


# ---------------------------------------------------------------- 도우미

func _new_view() -> void:
	if lv != null and is_instance_valid(lv):
		lv.queue_free()
		await _frames(2)
	lv = LessonView.new()
	add_child(lv)
	lv.size = _screen
	await _frames(4)


## 제목이 title 인 열린 시트(가장 위에 있는 것).
func _sheet_titled(title: String) -> Sheet:
	var found: Array = []
	_collect_sheets(get_tree().root, found)
	var res: Sheet = null
	for s in found:
		if (s as Sheet).title_label != null and (s as Sheet).title_label.text == title:
			res = s
	return res


func _collect_sheets(n: Node, out: Array) -> void:
	if n is Sheet and not (n as Sheet).is_closed():
		out.append(n)
	for c in n.get_children():
		_collect_sheets(c, out)


func _collect_named(n: Node, prefix: String, out: Array) -> void:
	if String(n.name).begins_with(prefix):
		out.append(n)
	for c in n.get_children():
		_collect_named(c, prefix, out)


func _named(root: Node, nm: String) -> Node:
	return root.find_child(nm, true, false) if root != null else null


func _ready_btn(b: Variant) -> bool:
	return b is Button and is_instance_valid(b) and (b as Button).is_visible_in_tree() and not (b as Button).disabled


## 실제 버튼을 누른다: 보이고 눌릴 수 있는지 먼저 확인하고, pressed 를 낸다.
func press(b: Variant, label: String) -> void:
	var good: bool = _ready_btn(b)
	ok(good, "button ready: %s" % label)
	if not good:
		return
	presses += 1
	print("press: ", label)
	(b as Button).pressed.emit()


func _texts(n: Node, out: Array) -> void:
	if n is Label or n is Button or n is RichTextLabel:
		out.append(str(n.text))
	for c in n.get_children():
		_texts(c, out)


func _has_text(root: Node, needle: String) -> bool:
	var all: Array = []
	_texts(root, all)
	for t in all:
		if str(t).contains(needle):
			return true
	return false


## 화면 글 중 "cn_" 으로 시작하는 줄의 개수(노트 id 가 그대로 보이는 줄).
func _cn_lines(root: Node) -> int:
	var all: Array = []
	_texts(root, all)
	var n: int = 0
	for t in all:
		var s: String = str(t).lstrip("· ").strip_edges()
		if s.begins_with("cn_"):
			n += 1
	return n


## 읽을 글 목록이 설계 표와 같은가(다르면 사유 글, 같으면 "").
func _table_diff(ids: Array, texts: Array) -> String:
	if ids.size() != WANT.size() or texts.size() != WANT.size():
		return "size %d/%d != %d" % [ids.size(), texts.size(), WANT.size()]
	for i in WANT.size():
		if str(ids[i]) != "n%04d" % (103 + i):
			return "id %d is %s" % [i, str(ids[i])]
		if str(texts[i]) != str(WANT[i]):
			return "text %d is '%s'" % [i, str(texts[i])]
	return ""


func _overlaps(rects: Array) -> int:
	var n: int = 0
	for i in rects.size():
		for j in range(i + 1, rects.size()):
			if (rects[i] as Rect2).intersects(rects[j] as Rect2):
				n += 1
	return n


## 소스 글에서 금지 패턴을 찾는다(이름 목록).
func _scan_source_text(txt: String) -> Array:
	var hits: Array = []
	if txt.contains("Color(\"" + "#"):
		hits.append("hex colour")
	for needle in ["877" + "0", "877" + "5", "877" + "6"]:
		if txt.contains(needle):
			hits.append(needle)
	for needle in ["HTTPRe" + "quest", "HTTPCl" + "ient", "shell" + "_open", "request" + "_permission"]:
		if txt.contains(needle):
			hits.append(needle)
	if _symbol_count(txt) > 0:
		hits.append("symbol glyph")
	return hits


func _symbol_count(txt: String) -> int:
	var n: int = 0
	for i in txt.length():
		var cp: int = txt.unicode_at(i)
		if (cp >= 0x2600 and cp <= 0x27BF) or (cp >= 0x1F300 and cp <= 0x1FAFF) or cp == 0x2B50 or cp == 0x2713:
			n += 1
	return n


# ---------------------------------------------------------------- 검사기 자체 시험

func _selfcheck() -> void:
	print("[selfcheck: the checkers fail on wrong input]")
	var ids: Array = []
	for i in WANT.size():
		ids.append("n%04d" % (103 + i))
	eq(_table_diff(ids, WANT), "", "the table diff accepts the real table")
	var big_ids: Array = ids.duplicate()
	var big_txt: Array = WANT.duplicate()
	big_ids.append("n0134")
	big_txt.append("x")
	fails(_table_diff(big_ids, big_txt) != "", "a checker that expects 32 items fails on the 31 of the table")
	var short_txt: Array = WANT.duplicate()
	short_txt.remove_at(30)
	var short_ids: Array = ids.duplicate()
	short_ids.remove_at(30)
	fails(_table_diff(short_ids, short_txt) != "", "30 items fail the table diff")
	var bad_txt: Array = WANT.duplicate()
	bad_txt[25] = "zee"
	fails(_table_diff(ids, bad_txt) != "", "one wrong text (zee for zed) fails the table diff")
	var bad_ids: Array = ids.duplicate()
	bad_ids[3] = "n0999"
	fails(_table_diff(bad_ids, WANT) != "", "one wrong id fails the table diff")
	var fake := VBoxContainer.new()
	var l1 := Label.new()
	l1.text = "· cn_zed"
	fake.add_child(l1)
	fails(_cn_lines(fake) == 1, "a label that shows a note id is counted")
	var l2 := Label.new()
	l2.text = "· 캐나다 노트"
	fake.add_child(l2)
	eq(_cn_lines(fake), 1, "a normal line is not counted")
	fake.free()
	fails(_overlaps([Rect2(0, 0, 10, 10), Rect2(5, 5, 10, 10)]) == 1, "overlapping rectangles are counted")
	eq(_overlaps([Rect2(0, 0, 10, 10), Rect2(20, 0, 10, 10)]), 0, "separate rectangles are not counted")
	fails(_scan_source_text("var c = Color(\"" + "#ff0000\")").size() > 0, "a source with a hex Color is flagged")
	fails(_scan_source_text("var h = HTTPRe" + "quest.new()").size() > 0, "a source with an HTTP request node is flagged")
	fails(_scan_source_text("var u = \"http://127.0.0.1:877" + "0\"").size() > 0, "a source with a forbidden port is flagged")
	fails(_scan_source_text("var s = \"" + char(0x2605) + " star\"").size() > 0, "a source with a star glyph is flagged")
	eq(_scan_source_text("var s = \"ok text\"").size(), 0, "a clean source is not flagged")
	ok(CourseHome.is_note_id("cn_zed") and not CourseHome.is_note_id("Canada notes"), "is_note_id sees cn_zed but not a normal line")
	ok(not CourseHome.is_note_id("cn_Zed") and not CourseHome.is_note_id("") and not CourseHome.is_note_id(5) and not CourseHome.is_note_id("a cn_zed"), "is_note_id refuses odd shapes (upper case, empty, number, prefix text)")
	_reached.append("selfcheck")


# ---------------------------------------------------------------- 1. 규칙 = 실제 데이터 (F1-2)

func _sec_rule_real_data() -> void:
	print("[rule on the real data: exactly 31 notes, all in week 1]")
	_world()
	ok(_avail >= 16, "the real course data has 16 weeks (%d)" % _avail)
	var ids: Array = []
	var texts: Array = []
	var other_weeks: int = 0
	var total: int = 0
	for w in range(1, _avail + 1):
		var cnt: int = 0
		for n in CourseSoundNotes.notes_for_week(w):
			var d: Dictionary = n
			if str(d["speak"]) != "":
				cnt += 1
				total += 1
				if w == 1:
					ids.append(str(d["id"]))
					texts.append(str(d["speak"]))
				else:
					other_weeks += 1
		eq(CourseSoundNotes.count_speakable(w), cnt, "count_speakable(%d) = notes with a text (%d)" % [w, cnt])
	eq(total, 31, "exactly 31 speakable notes in weeks 1..%d" % _avail)
	eq(other_weeks, 0, "none of them is outside week 1")
	var diff: String = _table_diff(ids, texts)
	ok(diff == "", "ids n0103..n0133 and the texts are the design table (%s)" % diff)
	var w1: Array = CourseSoundNotes.notes_for_week(1)
	eq(w1.size(), 32, "week 1 has 32 sound notes (n0102 has no button)")
	var n102: Dictionary = {}
	for n in w1:
		if str((n as Dictionary)["id"]) == "n0102":
			n102 = n
	ok(not n102.is_empty() and str(n102["speak"]) == "" and str(n102["text_ko"]).contains("zed"), "n0102 (the Z = zed explanation) is listed with an empty text")
	var n202: Dictionary = {}
	for n in CourseSoundNotes.notes_for_week(2):
		if str((n as Dictionary)["id"]) == "n0202":
			n202 = n
	ok(not n202.is_empty() and str(n202["en"]) == "b" and str(n202["speak"]) == "", "week 2 n0202 (en 'b') has an empty text")
	var culture: int = 0
	for n in w1:
		if str((n as Dictionary)["id"]) == "n0101":
			culture += 1
	eq(culture, 0, "the culture note n0101 is not a sound note")
	eq(CourseSoundNotes.count_speakable(0), 0, "week 0 has nothing")
	eq(CourseSoundNotes.count_speakable(99), 0, "week 99 has nothing")
	ok(CourseSoundNotes.SPEAK_OVERRIDE.is_empty(), "SPEAK_OVERRIDE ships empty")
	_reached.append("rule")


# ---------------------------------------------------------------- 2. 일부러 틀린 입력 (F1-4)

func _sec_wrong_input() -> void:
	print("[wrong input: odd notes give an empty text, no crash]")
	var good: Dictionary = {"id": "x1", "kind": "sound", "en": "A (ay)", "text_ko": "알파벳 A"}
	eq(CourseSoundNotes.speak_text(good), "ay", "a good letter note gives its letter name")
	eq(CourseSoundNotes.speak_text({"id": "x2", "kind": "sound", "en": "W (double-you)", "text_ko": ""}), "double-you", "a name with a hyphen is read whole")
	eq(CourseSoundNotes.speak_text({"id": "x3", "kind": "sound", "en": "a", "text_ko": "짧은 a 소리예요. (cat, bag, hat)"}), "cat, bag, hat", "a short vowel gives its example words")
	eq(CourseSoundNotes.speak_text({"id": "x4", "kind": "sound", "en": "u", "text_ko": "짧은 u 소리예요. (bus, cup) "}), "bus, cup", "trailing spaces after the brackets are fine")
	var bad_cases: Array = [
		{"kind": "sound", "en": "A(ay)", "text_ko": ""},
		{"kind": "sound", "en": "AB (ay)", "text_ko": ""},
		{"kind": "sound", "en": "a (ay)", "text_ko": ""},
		{"kind": "sound", "en": "A (AY)", "text_ko": ""},
		{"kind": "sound", "en": "A ()", "text_ko": ""},
		{"kind": "sound", "en": "A (ay) ", "text_ko": ""},
		{"kind": "sound", "en": "A (ay)\nB (bee)", "text_ko": ""},
		{"kind": "sound", "en": "", "text_ko": "알파벳 Z 는 zed 라고 읽어요."},
		{"kind": "sound", "text_ko": "(cat, bag, hat)"},
		{"kind": "sound", "en": 5, "text_ko": "(cat)"},
		{"kind": "sound", "en": null, "text_ko": null},
		{"kind": "sound", "en": ["A (ay)"], "text_ko": {}},
		{"kind": "sound", "en": "a", "text_ko": "짧은 a 소리"},
		{"kind": "sound", "en": "a", "text_ko": "짧은 a 소리 (cat, bag, hat) 이에요"},
		{"kind": "sound", "en": "a", "text_ko": "짧은 a 소리 (Cat)"},
		{"kind": "sound", "en": "a", "text_ko": ""},
		{"kind": "sound", "en": "a", "text_ko": 7},
		{"kind": "sound", "en": "ab", "text_ko": "(cat)"},
		{"kind": "sound", "en": "b", "text_ko": "(bed)"},
		{"kind": "culture", "en": "A (ay)", "text_ko": ""},
		{"kind": 5, "en": "A (ay)"},
		{"en": "A (ay)"},
		{},
	]
	var wrong: int = 0
	for c in bad_cases:
		if CourseSoundNotes.speak_text(c) != "":
			wrong += 1
			print("  odd note read: ", str(c))
	eq(wrong, 0, "%d odd notes (no space, two letters, empty, number, no brackets, wrong kind ...) all give an empty text" % bad_cases.size())
	fails(CourseSoundNotes.speak_text({"kind": "sound", "en": "A(ay)"}) != "ay", "a checker that wants 'ay' from 'A(ay)' fails")
	_reached.append("wrong_input")


# ---------------------------------------------------------------- 3. 버튼 흐름 (F1-3, F1-5)

func _sec_buttons() -> void:
	print("[button flow: week sheet -> sound sheet -> 31 [듣기] with real presses]")
	_world()
	CourseStore.set_mode("course")
	CourseData.reset()
	CourseFeed.reset()
	await _new_view()
	ok(lv._course != null, "the course road is shown")
	# 1주 시트
	press(lv._course.current_node(), "현재 노드(1주)")
	await _frames(2)
	var wk: Sheet = lv._course.week_sheet
	ok(wk != null and not wk.is_closed() and wk.title_label != null and wk.title_label.text.begins_with("1주"), "the node opens the week-1 sheet")
	var snb: Node = _named(wk, "SoundNotesBtn") if wk != null else null
	ok(snb is Button and _ready_btn(snb), "week 1: [알파벳·모음 소리 듣기] is shown")
	ok(snb is Button and (snb as Button).text == "알파벳·모음 소리 듣기", "the button says '알파벳·모음 소리 듣기'")
	ok(snb is Button and (snb as Button).get_global_rect().size.y >= 44.0, "the button is at least 44 high")
	ok(wk != null and _has_text(wk, "이번 주 공부량") and _has_text(wk, "요일 칸") and _has_text(wk, "알파벳과 첫 인사"), "the rest of the week sheet is unchanged (amount, day slots, scene title)")
	eq(_cn_lines(wk), 0, "week 1 sheet: no line starts with cn_ (note ids are hidden)")
	ok(wk != null and not _has_text(wk, "cn_app_voice") and not _has_text(wk, "cn_zed"), "week 1 sheet: cn_app_voice and cn_zed are not on the screen")
	ok(wk != null and wk.buttons.has("start") and wk.buttons.has("skip") and wk.buttons.has("close"), "week sheet: [이 주 시작] [점검으로 건너뛰기] [닫기] unchanged")
	if wk != null:
		press(wk.buttons["close"], "주 시트 닫기")
	await _frames(2)
	ok(not Sheet.is_open(), "the week sheet is closed")
	# 2주 시트에는 버튼이 없다
	press(lv._course.node_of(2), "2주 노드")
	await _frames(2)
	var wk2: Sheet = lv._course.week_sheet
	ok(wk2 != null and not wk2.is_closed() and wk2.title_label != null and wk2.title_label.text.begins_with("2주"), "the node of week 2 opens the week-2 sheet")
	ok(wk2 != null and _named(wk2, "SoundNotesBtn") == null, "week 2: no [알파벳·모음 소리 듣기]")
	eq(_cn_lines(wk2), 0, "week 2 sheet: no line starts with cn_")
	if wk2 != null:
		press(wk2.buttons["close"], "2주 시트 닫기")
	await _frames(2)
	# 1주 시트 -> 소리 시트
	press(lv._course.current_node(), "현재 노드(1주) 다시")
	await _frames(2)
	wk = lv._course.week_sheet
	snb = _named(wk, "SoundNotesBtn") if wk != null else null
	press(snb, "알파벳·모음 소리 듣기")
	await _frames(4)
	var ss: Sheet = _sheet_titled("알파벳·모음 소리")
	ok(ss != null, "the sound sheet opens with the title '알파벳·모음 소리'")
	if ss == null:
		_reached.append("buttons")
		return
	eq(Sheet.depth(), 2, "the sound sheet is above the week sheet (depth 2)")
	ok(_has_text(ss, "앱 소리는 합성음이에요. 짧은 모음은 예시 낱말로 들려줘요."), "the sheet starts with the one-line note about synthetic sound")
	var rows: Array = []
	var play: Array = []
	_collect_named(ss, "SoundRow_", rows)
	_collect_named(ss, "SoundPlay_", play)
	eq(rows.size(), 32, "32 rows (n0102 is a row without a button)")
	eq(play.size(), 31, "31 [듣기] buttons")
	ok(_named(ss, "SoundRow_n0102") != null and _named(ss, "SoundPlay_n0102") == null, "n0102 has a row and no button")
	eq(_cn_lines(ss), 0, "the sound sheet shows no cn_ line")
	var ids_seen: Array = []
	for b in play:
		ids_seen.append(String((b as Node).name).trim_prefix("SoundPlay_"))
	var want_ids: Array = []
	for i in WANT.size():
		want_ids.append("n%04d" % (103 + i))
	eq(ids_seen, want_ids, "the buttons are SoundPlay_n0103 .. SoundPlay_n0133 in order")
	# 모양: 높이 >= 44, 가로로 넘치지 않음, 글과 버튼이 겹치지 않음
	var small: int = 0
	var out_x: int = 0
	var clash: int = 0
	var pr: Rect2 = ss.panel_rect()
	for b in play:
		var br: Rect2 = (b as Control).get_global_rect()
		if br.size.y < 43.5:
			small += 1
		if br.position.x < pr.position.x - 0.5 or br.end.x > pr.end.x + 0.5:
			out_x += 1
		var row: Node = (b as Node).get_parent()
		for c in row.get_children():
			if c != b and c is Control and (c as Control).get_global_rect().intersects(br):
				clash += 1
	eq(small, 0, "every [듣기] is >= 44 high")
	eq(out_x, 0, "no [듣기] sticks out of the sheet sideways")
	eq(clash, 0, "no [듣기] overlaps the text next to it")
	var body_w: float = ss.body.get_combined_minimum_size().x
	ok(body_w <= ss._scroll.size.x + 0.5, "no sideways scrolling in the sound sheet (%.0f <= %.0f)" % [body_w, ss._scroll.size.x])
	# [듣기] 31번: Tts.fetch_hook 이 받은 글
	_heard.clear()
	var bad_text: int = 0
	var bad_lang: int = 0
	var bad_count: int = 0
	var first_bad: String = ""
	for i in play.size():
		var before: int = _heard.size()
		press(play[i], "듣기 %s" % str(want_ids[i]))
		if _heard.size() != before + 1:
			bad_count += 1
			continue
		var h: Array = _heard[_heard.size() - 1]
		if str(h[0]) != str(WANT[i]):
			bad_text += 1
			if first_bad == "":
				first_bad = "%d: '%s' != '%s'" % [i, str(h[0]), str(WANT[i])]
		if str(h[1]) != "en":
			bad_lang += 1
	eq(bad_count, 0, "each press reaches Tts.fetch_hook exactly once (31 presses)")
	eq(bad_text, 0, "the text Tts reads is the table text each time (%s)" % first_bad)
	eq(bad_lang, 0, "every text is read as English ('en')")
	eq(_heard.size(), 31, "31 texts were read in all")
	# 두 번째 길: speak_hook (계약)
	_heard.clear()
	_hooked.clear()
	SoundNotesSheet.speak_hook = Callable(self, "_on_speak")
	var hook_bad: int = 0
	for i in play.size():
		press(play[i], "듣기(hook) %s" % str(want_ids[i]))
		if _hooked.size() != i + 1 or str((_hooked[i] as Array)[0]) != str(WANT[i]) or str((_hooked[i] as Array)[1]) != "en":
			hook_bad += 1
	eq(hook_bad, 0, "speak_hook is called with (table text, 'en') for each of the 31 buttons")
	eq(_hooked.size(), 31, "speak_hook was called 31 times")
	eq(_heard.size(), 0, "with a speak_hook set, Tts is not used")
	fails(_hooked.size() != 32, "a checker that wants 32 hook calls fails")
	SoundNotesSheet.speak_hook = Callable()
	# 닫기: 소리 시트만 닫힌다
	press(ss.buttons["close"], "소리 시트 닫기")
	await _frames(2)
	ok((not is_instance_valid(ss) or ss.is_closed()) and lv._course.week_sheet != null and not lv._course.week_sheet.is_closed(), "[닫기] closes only the sound sheet; the week sheet stays")
	_close_sheets()
	await _frames(2)
	_reached.append("buttons")


# ---------------------------------------------------------------- 4. 데이터가 없을 때 (F1-4)

func _sec_no_data() -> void:
	print("[no course data: no button, no crash]")
	_world()
	CourseData.base_dir = GONE_DIR
	CourseData.reset()
	eq(CourseSoundNotes.notes_for_week(1).size(), 0, "no data: no notes")
	eq(CourseSoundNotes.count_speakable(1), 0, "no data: nothing speakable")
	var ch := CourseHome.new()
	add_child(ch)
	var body: Control = ch.week_body(1, "current")
	add_child(body)
	await _frames(2)
	ok(_named(body, "SoundNotesBtn") == null, "no data: week_body has no [알파벳·모음 소리 듣기]")
	body.queue_free()
	ch.queue_free()
	var ss: Node = SoundNotesSheet.open(self, 1)
	await _frames(3)
	ok(ss is Sheet and not (ss as Sheet).is_closed(), "no data: the sound sheet still opens")
	var rows: Array = []
	_collect_named(ss, "SoundRow_", rows)
	eq(rows.size(), 0, "no data: the sound sheet has no rows")
	_close_sheets()
	await _frames(2)
	CourseData.base_dir = _saved["base"]
	CourseData.reset()
	_reached.append("no_data")


# ---------------------------------------------------------------- 5. 소스 검사

func _sec_source() -> void:
	print("[source scan]")
	for p in SRC_ALL:
		var f := FileAccess.open(p, FileAccess.READ)
		var txt: String = f.get_as_text() if f != null else ""
		ok(txt != "", "source readable: %s" % p)
		var hits: Array = _scan_source_text(txt)
		ok(hits.is_empty(), "no forbidden pattern in %s (%s)" % [p, str(hits)])
	_reached.append("source")
