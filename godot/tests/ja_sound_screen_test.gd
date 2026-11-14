extends Node
## 일본어 약한 소리 화면 시험 (서버 없이): JaSoundScreen 의 목록 · 설명 · 듣고 고르기 10문항(실제 버튼) · 요약 · 복습 카드 · XP,
## 따라 말하기(가짜 /score, 자가 평가), 소리 없음, 데이터 이상, 뒤로 가기, 레이아웃, 소스 검사.
##   PC   : godot --headless --path godot res://tests/ja_sound_screen_test.tscn -- --api=http://127.0.0.1:9
##   폰   : godot --headless --path godot --resolution 412x915 res://tests/ja_sound_screen_test.tscn -- --phone --api=http://127.0.0.1:9
##   옵션 : -- [--phone] [--font-scale=1.5] [--dark] [--shots=<폴더>]   (--shots 는 창이 있는 실행에서만 PNG 가 저장된다: 헤드리스는 그림이 없다)
## 마지막 줄: "== ja_sound_screen: N passed, M failed =="  (실패가 있으면 종료 코드 1)
## 흐름은 보기·시작·다음 버튼의 pressed 신호로만 간다(press: 줄). 정답 여부는 화면 내부값이 아니라 "실제로 재생된 낱말"로 따로 계산해서 대조한다.
## 마이크는 헤드리스에서 쓸 수 없으므로 녹음 끝남(recorded) 신호만 직접 낸다. /score 는 SpeakDrill.api_hook 으로 가로챈다.
## 시험 전용 파일 경로(user://test_a5_*)만 쓰고 끝에 되돌린다. 소리는 Tts.fetch_hook 으로 가로채고 주소는 닫힌 포트(9)다.
## 검사기(big_numbers / rect_inside / phon_clean)는 일부러 틀린 입력을 넣어 실제로 실패하는지도 본다 ("selfcheck FAIL-as-expected ..." 줄).

const TEST_PROGRESS := "user://test_a5_progress.json"
const TEST_PREFS := "user://test_a5_prefs.json"
const TEST_LOG := "user://test_a5_studylog.json"
const TEST_DATA := "user://test_a5_sounds.json"
const PHONE_SCREEN := Vector2(412, 915)
const PC_SCREEN := Vector2(1280, 800)
const FAKE_REC := {"b64": "AAAA"}

var passed: int = 0
var failed: int = 0
var phone: bool = false
var press_n: int = 0
var tts_calls: Array = []
var _saved := {}
var _holder: Control = null
var _screen: JaSoundScreen = null
var _scheme: String = "light"
var _font_scale: float = 1.0
var _shots_dir: String = ""
var _closed_n: int = 0
var _api: Node = null ## 자동 로드 Api (접속 금지 규칙 때문에 이름으로 직접 부르지 않고 노드로 잡는다)
var _fake_mode: String = "all_ok" ## 가짜 /score: all_ok | bad_sokuon | english | silent
var _score_bodies: Array = []


func ok(cond: bool, name: String) -> void:
	if cond:
		passed += 1
		print("  PASS  ", name)
	else:
		failed += 1
		print("  FAIL  ", name)


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
	_api = get_node("/root/Api")
	for a in OS.get_cmdline_user_args():
		if a == "--dark":
			_scheme = "dark"
		elif a.begins_with("--font-scale="):
			var raw: String = a.substr(13)
			_font_scale = raw.to_float() if raw.is_valid_float() else 1.0
		elif a.begins_with("--shots="):
			_shots_dir = a.substr(8)
	UiBoot.apply(get_tree().root, _scheme, _font_scale)
	print("== ja_sound_screen start (%s, scheme=%s, font_scale=%s) ==" % ["phone" if phone else "pc", _scheme, Ds.font_scale])
	_setup()
	_selfcheck()
	await _test_open_and_list()
	await _test_listen_flow()
	await _test_speak_flow()
	await _test_speak_variants()
	await _test_no_sound()
	await _test_bad_data()
	await _test_back_navigation()
	await _test_layout()
	_test_static_scan()
	_teardown()
	print("== ja_sound_screen: %d passed, %d failed ==" % [passed, failed])
	get_tree().quit(1 if failed > 0 else 0)


# ---------------------------------------------------------------- setup

func _setup() -> void:
	_saved = {
		"prefs": Store.prefs.duplicate(true),
		"progress": Store.progress.duplicate(true),
		"progress_path": Store.progress_path,
		"prefs_path": Store.prefs_path,
		"log_path": StudyLog.path,
		"base": _api.base_url,
		"route_mode": Route.mode,
		"phone_hook": Route.phone_hook,
		"data_path": JaSounds.data_path,
	}
	Store.progress_path = TEST_PROGRESS
	Store.prefs_path = TEST_PREFS
	Store.progress = Progress.blank()
	StudyLog.path = TEST_LOG
	_rm(TEST_LOG)
	StudyLog.load_from_disk()
	StudyLog.reset()
	Store.prefs["lang"] = "ja"
	_api.base_url = "http://127.0.0.1:9" ## 닫힌 포트: 실제 PC 서버에 닿지 않게 (소리는 fetch_hook 이 가로챈다)
	Tts.fetch_hook = Callable(self, "_tts_hook")
	SpeakDrill.api_hook = Callable(self, "_api_hook")
	get_window().min_size = Vector2i.ZERO
	get_window().size = Vector2i(PHONE_SCREEN if phone else PC_SCREEN)


func _teardown() -> void:
	if _holder != null and is_instance_valid(_holder):
		_holder.queue_free()
	Tts.fetch_hook = Callable()
	Tts.stop()
	SpeakDrill.api_hook = Callable()
	Route.mode = _saved["route_mode"]
	Route.phone_hook = _saved["phone_hook"]
	JaSounds.data_path = _saved["data_path"]
	JaSounds.clear_cache()
	StudyLog.reset()
	for p in [TEST_LOG, TEST_LOG + ".tmp", TEST_LOG + ".bad", TEST_PROGRESS, TEST_PROGRESS + ".tmp", TEST_PREFS, TEST_PREFS + ".tmp", TEST_DATA]:
		_rm(p)
	StudyLog.path = _saved["log_path"]
	Store.progress_path = _saved["progress_path"]
	Store.prefs_path = _saved["prefs_path"]
	Store.progress = _saved["progress"]
	_api.base_url = _saved["base"]
	Store.prefs = _saved["prefs"]


func _tts_hook(text: String, l: String, speed: float, _voice: String) -> Variant:
	tts_calls.append({"text": text, "lang": l, "speed": speed})
	return null


## 가짜 /score: 목표 글자의 모라마다 한 단위. bad_sokuon 이면 っ 만 틀림(들린 글자 つ).
func _api_hook(method: String, path: String, body: Variant) -> Variant:
	await get_tree().process_frame
	if method == "POST" and path == "/score" and body is Dictionary:
		_score_bodies.append(body)
		match _fake_mode:
			"silent":
				return {}
			"english":
				return {"transcript": "hello world", "score": 80.0, "units": [{"t": "hello", "ok": true}, {"t": "world", "ok": false, "heard": "word"}]}
		var rd: String = str((body as Dictionary).get("reading", ""))
		if rd == "":
			rd = str((body as Dictionary).get("target", ""))
		var units: Array = []
		for m in _split_moras(rd):
			var good := true
			var u := {"t": str(m), "ok": true}
			if _fake_mode == "bad_sokuon" and str(m) == "っ":
				good = false
				u["ok"] = false
				u["heard"] = "つ"
			units.append(u)
		return {"transcript": rd, "score": 80.0, "units": units}
	return {"ok": false, "code": 404, "data": null, "error": "no fake for " + path}


## 읽기 -> 모라 목록 (작은 가나는 앞 글자에 붙이고 쉼표·마침표는 건너뜀). 가짜 /score 응답을 만들 때만 쓴다.
func _split_moras(rd: String) -> Array:
	var out: Array = []
	for k in rd.length():
		var ch: String = rd.substr(k, 1)
		if "、。 ,.".contains(ch):
			continue
		if not out.is_empty() and "ゃゅょぁぃぅぇぉゎ".contains(ch):
			out[out.size() - 1] = str(out[out.size() - 1]) + ch
		else:
			out.append(ch)
	return out


func _rm(path: String) -> void:
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


func _reset_state() -> void:
	StudyLog.reset()
	Store.progress = Progress.blank()
	tts_calls.clear()
	_score_bodies.clear()
	_fake_mode = "all_ok"
	_api.base_url = "http://127.0.0.1:9"
	Route.mode = "auto"
	Route.phone_hook = Callable()
	JaSounds.data_path = JaSounds.DATA_PATH
	JaSounds.clear_cache()


func _make_screen() -> JaSoundScreen:
	if _holder != null and is_instance_valid(_holder):
		_holder.queue_free()
	_holder = Control.new()
	_holder.size = PHONE_SCREEN if phone else PC_SCREEN
	_holder.clip_contents = true
	add_child(_holder)
	_screen = JaSoundScreen.new()
	_holder.add_child(_screen)
	_screen.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_closed_n = 0
	_screen.closed.connect(func() -> void: _closed_n += 1)
	return _screen


func _find(n: Node, node_name: String) -> Node:
	if n.name == node_name:
		return n
	for c in n.get_children():
		var f: Node = _find(c, node_name)
		if f != null:
			return f
	return null


func _has_text(n: Node, needle: String) -> bool:
	for c in n.get_children():
		if (c is Label or c is Button) and str(c.text).contains(needle):
			return true
		if _has_text(c, needle):
			return true
	return false


func _btn(node_name: String) -> Button:
	var n: Node = _find(_holder, node_name)
	return n as Button if n is Button else null


## 실제 버튼 누르기: 보이고 눌 수 있는 버튼만. 눌렀다고 한 줄 찍는다 ("press: <이름>").
func _press(node_name: String) -> bool:
	var b: Button = _btn(node_name)
	var usable: bool = b != null and is_instance_valid(b) and b.is_visible_in_tree() and not b.disabled
	ok(usable, "press target %s is visible and enabled" % node_name)
	if not usable:
		return false
	press_n += 1
	print("press: ", node_name)
	b.pressed.emit()
	return true


func _phon(p: String) -> Dictionary:
	var d: Dictionary = (StudyLog._data["phon"] as Dictionary)["ja"]
	return (d.get(p, {"h": "", "heard": {}}) as Dictionary)


func _phon_h(p: String) -> String:
	return str(_phon(p).get("h", ""))


func _drill_events() -> int:
	return int(((StudyLog._rec("ja", false) as Dictionary)["n"] as Dictionary).get("drill", 0))


func _shot(name: String) -> void:
	if _shots_dir == "":
		return
	await _frames(3)
	var img: Image = get_viewport().get_texture().get_image() if get_viewport().get_texture() != null else null
	if img == null or img.is_empty():
		print("  (no image for shot %s: headless?)" % name)
		return
	DirAccess.make_dir_recursive_absolute(_shots_dir)
	var path := "%s/%s_%s_f%d.png" % [_shots_dir, name, _scheme, roundi(Ds.font_scale * 100.0)]
	print("  shot ", path, " err=", img.save_png(path))


# ---------------------------------------------------------------- validators (also checked against broken input)

## 화면의 모든 Label/Button 글에서 연속 5자리 이상 숫자(unix 시각 · ms · 바이트 직접 표시)를 찾는다. 찾은 글 목록.
func big_numbers(n: Node) -> Array:
	var out: Array = []
	var re := RegEx.new()
	re.compile("\\d{5,}")
	_scan_numbers(n, re, out)
	return out


func _scan_numbers(n: Node, re: RegEx, out: Array) -> void:
	for c in n.get_children():
		if c is Label or c is Button:
			var t: String = str(c.text)
			if re.search(t) != null:
				out.append(t)
		_scan_numbers(c, re, out)


## r 이 bounds 안(가로)에 들어 있고 높이가 min_h 이상인가.
func rect_inside(r: Rect2, bounds: Rect2, min_h: float) -> bool:
	return r.position.x >= bounds.position.x - 0.5 and r.end.x <= bounds.end.x + 0.5 and r.size.y >= min_h - 0.5


## phon.<lang> 이 비어 있는가 (한 언어에만 기록했는지).
func phon_clean(lang: String) -> bool:
	return ((StudyLog._data["phon"] as Dictionary)[lang] as Dictionary).is_empty()


func _selfcheck() -> void:
	var fake := Control.new()
	var l1 := Label.new()
	l1.text = "정답 7 / 10 (70%)"
	fake.add_child(l1)
	ok(big_numbers(fake).is_empty(), "selfcheck: big_numbers accepts a screen without 5-digit numbers")
	var l2 := Label.new()
	l2.text = "시간 12345"
	fake.add_child(l2)
	fails(not big_numbers(fake).is_empty(), "a label showing 12345")
	var l3 := Button.new()
	l3.text = "1731561234567 ms"
	var fake2 := Control.new()
	fake2.add_child(l3)
	fails(not big_numbers(fake2).is_empty(), "a button showing a unix time in ms")
	fake.free()
	fake2.free()
	var bounds := Rect2(0, 0, 412, 915)
	ok(rect_inside(Rect2(12, 100, 388, 64), bounds, 64.0), "selfcheck: rect_inside accepts a 64 high row inside the screen")
	fails(not rect_inside(Rect2(12, 100, 420, 64), bounds, 64.0), "row sticks out to the right")
	fails(not rect_inside(Rect2(12, 100, 388, 40), bounds, 64.0), "row shorter than 64")
	# 기록 언어 검사기: 영어 칸에 한 건이라도 있으면 더럽다고 판정해야 한다
	StudyLog.reset()
	ok(phon_clean("en") and phon_clean("ja"), "selfcheck: phon_clean accepts empty stats")
	StudyLog.add_phon_obs("en", "j_long", false, "x")
	fails(not phon_clean("en"), "a record in phon.en")
	StudyLog.reset()
	# 판정기: 영어 응답(가나가 아님)은 소리별 판정 불가여야 한다
	var j: Dictionary = JaSoundScreen.judge({"transcript": "hi", "score": 80, "units": [{"t": "hello", "ok": true}]}, "j_long")
	ok(bool(j["unavailable"]) and not bool(j["success"]), "selfcheck: judge() of an English response is unavailable")
	var j2: Dictionary = JaSoundScreen.judge({"transcript": "おばあさん", "score": 80, "units": [{"t": "お", "ok": true}, {"t": "ば", "ok": true}, {"t": "あ", "ok": false, "heard": "は"}, {"t": "さ", "ok": true}, {"t": "ん", "ok": true}]}, "j_long")
	ok(int(j2["found"]) == 1 and int(j2["good"]) == 0 and not bool(j2["success"]) and not bool(j2["unavailable"]), "selfcheck: judge() sees the missed long vowel (found 1, good 0)")
	var j3: Dictionary = JaSoundScreen.judge({"transcript": "おばあさん", "score": 80, "units": [{"t": "お", "ok": true}, {"t": "ば", "ok": true}, {"t": "あ", "ok": true}, {"t": "さ", "ok": true}, {"t": "ん", "ok": true}]}, "j_long")
	ok(bool(j3["success"]) and int(j3["found"]) == 1, "selfcheck: judge() succeeds when the long vowel is fine")
	# 순수 함수
	ok(JaSoundScreen.word_text("家", "いえ") == "家 (いえ)" and JaSoundScreen.word_text("いいえ", "いいえ") == "いいえ", "word_text shows the headword with its reading only when they differ")
	ok(JaSoundScreen.progress_text(3, 10) == "3 / 10" and JaSoundScreen.percent(7, 10) == 70 and JaSoundScreen.percent(0, 0) == 0, "progress_text / percent")
	ok(JaSoundScreen.rate_pct({"rate": 0.4}) == 40 and JaSoundScreen.rate_pct({"rate": 40}) == 40 and JaSoundScreen.rate_pct({}) == 0, "rate_pct accepts 0..1 and 0..100")
	ok(JaSoundScreen.heard_text({"w": "家", "rd": "いえ"}) == "いえ" and JaSoundScreen.heard_text({"w": "家", "rd": "あいうえおかきくけこさしすせそ"}) == "家", "heard_text prefers the kana reading, falls back to the headword when it is too long")
	var items: Array = JaSoundScreen.build_speak_items({"words": [{"w": "家", "rd": "いえ", "ko": "집"}, {"w": "雨", "rd": "あめ", "ko": "비"}, {"w": "木", "rd": "き", "ko": "나무"}], "phrases": [{"text": "家です。", "rd": "いえです。", "ko": "집이에요."}]})
	ok(items.size() == 4 and str(items[0]["target"]) == "いえ" and str(items[0]["text"]) == "家", "build_speak_items: 3 words + 1 phrase -> 4 items, a word's target is its reading")
	ok(JaSoundScreen.build_speak_items({}).is_empty() and JaSoundScreen.build_speak_items({"words": [5, "x"], "phrases": [null]}).is_empty(), "build_speak_items: empty and junk entries -> []")


# ---------------------------------------------------------------- open + list

func _test_open_and_list() -> void:
	print("[open + list]")
	_reset_state()
	var s := _make_screen()
	s.open("ja")
	await _frames(3)
	ok(s.stage == "list", "open(ja): the sound list")
	var cats: Array = JaSounds.load_data()["categories"]
	var all_chips := true
	for c in cats:
		if _btn("Chip_" + str((c as Dictionary)["p"])) == null:
			all_chips = false
	ok(all_chips and cats.size() >= 5, "every sound of the data has a chip (%d sounds)" % cats.size())
	ok(_has_text(s, "아직 약한 소리를 찾지 못했어요"), "no weak sound yet: the empty-state sentence")
	ok(_has_text(s, "인식된 글자와 비교한 추정이에요"), "the list shows the estimate note")
	ok(big_numbers(s).is_empty(), "list: no 5-digit number on screen")
	await _shot("list_empty")
	# 약한 소리 칩: 기록을 넣고 다시 연다 (장음 5번 중 2번 틀림 = 40%)
	for r in [true, false, true, false, true]:
		StudyLog.add_phon_obs("ja", "j_long", r, "" if r else "おばさん")
	s.open("ja")
	await _frames(3)
	var wb: Button = _btn("Weak_j_long")
	ok(wb != null and wb.text.contains("틀림 40%"), "weak chip: '%s'" % (wb.text if wb != null else "missing"))
	ok(wb != null and wb.size.y >= 44.0 - 0.5, "weak chip is at least 44 high")
	await _shot("list_weak")
	if wb != null:
		press_n += 1
		print("press: Weak_j_long")
		wb.pressed.emit()
	await _frames(2)
	ok(s.stage == "detail" and s.cur_p == "j_long", "pressing the weak chip opens that sound")
	# 다른 언어: 안내만
	s.open("en")
	await _frames(2)
	ok(s.stage == "unsupported" and _btn("CloseBtn") != null and _btn("Chip_j_long") == null, "open(en): only the notice and a close button, no chips")
	_press("CloseBtn")
	ok(_closed_n == 1, "the close button emits closed")
	# args.p
	s.open("ja", {"p": "j_sokuon"})
	await _frames(2)
	ok(s.stage == "detail" and s.cur_p == "j_sokuon", "open(ja, {p}) goes straight to that sound")
	s.open("ja", {"p": "zz_unknown"})
	await _frames(2)
	ok(s.stage == "list", "open(ja, {p: unknown}): the list, no error")
	ok(phon_clean("en"), "the list never wrote to phon.en")


# ---------------------------------------------------------------- listen flow (real buttons)

func _test_listen_flow() -> void:
	print("[listen flow: chip -> detail -> start -> 10 questions -> result -> list]")
	_reset_state()
	press_n = 0
	var s := _make_screen()
	s.rng.seed = 12345
	s.open("ja")
	await _frames(3)
	_press("Chip_j_long")
	await _frames(3)
	ok(s.stage == "detail" and s.cur_p == "j_long", "chip j_long opens the explanation")
	var cat: Dictionary = JaSounds.category("j_long")
	var pairs: Array = cat["pairs"]
	var pair_rows := 0
	for i in pairs.size():
		if _btn("PairA_%d" % i) != null and _btn("PairB_%d" % i) != null:
			pair_rows += 1
	ok(pair_rows == pairs.size() and pairs.size() >= 8, "detail lists every pair as two sound buttons (%d pairs)" % pair_rows)
	ok(_has_text(s, str(cat["hint_ko"]).substr(0, 12)), "detail shows the explanation text")
	# 한자 표제어는 보기에 읽기와 함께 보이고, 소리는 읽기(가나)로 난다
	var kanji_i := -1
	for i in pairs.size():
		if str(pairs[i]["a"]) != str(pairs[i]["a_rd"]):
			kanji_i = i
			break
	ok(kanji_i >= 0, "the data has a pair whose headword differs from its reading")
	if kanji_i >= 0:
		var pa: Button = _btn("PairA_%d" % kanji_i)
		ok(pa.text.contains(str(pairs[kanji_i]["a"])) and pa.text.contains(str(pairs[kanji_i]["a_rd"])) and pa.text.contains(str(pairs[kanji_i]["a_ko"])), "pair button shows headword, reading and meaning: '%s'" % pa.text.replace("\n", " | "))
		tts_calls.clear()
		_press("PairA_%d" % kanji_i)
		await _frames(8)
		ok(tts_calls.size() >= 1 and str(tts_calls[tts_calls.size() - 1]["text"]) == str(pairs[kanji_i]["a_rd"]) and str(tts_calls[tts_calls.size() - 1]["lang"]) == "ja", "pair button plays the kana reading '%s', not the kanji (got %s)" % [pairs[kanji_i]["a_rd"], str(tts_calls)])
	ok(_btn("StartListenBtn") != null and not _btn("StartListenBtn").disabled, "the start button is on")
	var h_before: String = _phon_h("j_long")
	_press("StartListenBtn")
	await _frames(6)
	ok(s.stage == "listen" and s.session.size() == 10, "10 questions start")
	var xp0: int = Store.xp("ja")
	var drill0: int = _drill_events()
	var expected_wrong: Array = []
	var wrong_words := {}
	var h_expect: String = h_before
	for k in 10:
		var tag := "q%d" % (k + 1)
		ok(s.stage == "listen" and s.idx == k, "%s: on question %d" % [tag, k + 1])
		ok(str((s._shell["count"] as Label).text) == "%d / 10" % (k + 1), "%s: the progress shows '%s'" % [tag, (s._shell["count"] as Label).text])
		var o0: Button = _btn("Opt0")
		var o1: Button = _btn("Opt1")
		ok(o0 != null and o1 != null and o0.size.y >= 64.0 - 0.5 and o1.size.y >= 64.0 - 0.5, "%s: two options, each at least 64 high" % tag)
		ok(_btn("NextBtn") == null or not _btn("NextBtn").is_visible_in_tree(), "%s: no next button before an answer" % tag)
		# 실제로 재생된 낱말 (자동 재생)
		await _frames(8)
		ok(tts_calls.size() >= 1, "%s: the sound played by itself" % tag)
		var played: String = str(tts_calls[tts_calls.size() - 1]["text"]) if not tts_calls.is_empty() else ""
		var q: Dictionary = s.current()
		var pair: Dictionary = q["pair"]
		ok(played == str(pair["a_rd"] if str(q["play"]) == "a" else pair["b_rd"]), "%s: the played word '%s' is the question's play side (%s)" % [tag, played, q["play"]])
		ok(played in [str(pair["a_rd"]), str(pair["b_rd"])] and str(tts_calls[tts_calls.size() - 1]["lang"]) == "ja", "%s: the played word is one of the pair's readings, in ja" % tag)
		# 다시 듣기 버튼
		if k == 0:
			tts_calls.clear()
			_press("ReplayBtn")
			await _frames(8)
			ok(tts_calls.size() >= 1 and str(tts_calls[tts_calls.size() - 1]["text"]) == played, "q1: the replay button plays the same word again")
		# 보기 2개의 읽기 중 재생된 쪽과 같은 것이 정답이다 (화면의 answer 값이 아니라 소리로 정한다)
		var opts: Array = q["options"]
		var right_i := -1
		for i in 2:
			if str((opts[i] as Dictionary)["rd"]) == played:
				right_i = i
		ok(right_i >= 0, "%s: one option matches the played word" % tag)
		var want_ok: bool = k % 3 != 2 ## 3번째마다 일부러 틀린 쪽을 누른다
		var pick: int = right_i if want_ok else 1 - right_i
		ok(str(o0.text).contains(str((opts[0] as Dictionary)["rd"])) and str(o0.text).contains(str((opts[0] as Dictionary)["ko"])), "%s: option text shows the reading and the meaning" % tag)
		if k == 0:
			await _shot("listen_question")
		_press("Opt%d" % pick)
		await _frames(2)
		h_expect += "0" if want_ok else "1"
		ok(_phon_h("j_long") == h_expect, "%s: phon.ja.j_long history is '%s' (the %s) (got '%s')" % [tag, h_expect, "right pick" if want_ok else "wrong pick", _phon_h("j_long")])
		var head: Label = _find(_holder, "FeedbackHead") as Label
		ok(head != null and head.text == ("정답이에요" if want_ok else "아쉬워요"), "%s: feedback says '%s'" % [tag, head.text if head != null else "none"])
		ok(bool((s.answers[k] as Dictionary)["ok"]) == want_ok, "%s: the screen graded the pick %s" % [tag, "right" if want_ok else "wrong"])
		var nb: Button = _btn("NextBtn")
		ok(nb != null and nb.is_visible_in_tree() and not nb.disabled, "%s: the next button is visible and enabled" % tag)
		ok(o0.disabled and o1.disabled, "%s: both options are locked after the answer" % tag)
		if not want_ok:
			var picked_rd: String = str((opts[pick] as Dictionary)["rd"])
			ok(int(((_phon("j_long")["heard"]) as Dictionary).get(picked_rd, 0)) >= 1, "%s: the wrong pick '%s' is noted as heard" % [tag, picked_rd])
			expected_wrong.append(k)
			for o in opts:
				wrong_words[str((o as Dictionary)["w"])] = o
		if k == 0:
			await _shot("listen_correct")
		if k == 2:
			await _shot("listen_wrong")
		ok(big_numbers(s).is_empty(), "%s: no 5-digit number on screen" % tag)
		tts_calls.clear()
		_press("NextBtn")
		await _frames(4)
	# 요약
	ok(s.stage == "result", "after the 10th next press the result shows")
	var good: int = 10 - expected_wrong.size()
	var rh: Label = _find(_holder, "ResultHead") as Label
	ok(rh != null and rh.text.contains("%d / 10" % good) and rh.text.contains("%d%%" % (good * 10)), "result head shows the score: '%s'" % (rh.text if rh != null else "none"))
	ok(_find(_holder, "WrongPairs") != null and expected_wrong.size() == 3, "the wrong pairs are listed (3 wrong picks were made)")
	ok(_has_text(s, "+10 XP") and Store.xp("ja") == xp0 + 10, "XP +10 exactly once (xp %d -> %d)" % [xp0, Store.xp("ja")])
	ok(_drill_events() == drill0 + 1, "one drill event recorded (%d -> %d)" % [drill0, _drill_events()])
	ok(_phon_h("j_long").length() >= 10 and _phon_h("j_long") == h_expect, "the 10 answers are all in the history")
	ok(phon_clean("en"), "nothing was written to phon.en")
	ok(big_numbers(s).is_empty(), "result: no 5-digit number on screen")
	await _shot("listen_result")
	# 복습 카드
	var before_cards: int = (Store.progress["review"] as Array).size()
	_press("AddCardsBtn")
	await _frames(3)
	var cards: Array = Store.review_for("ja")
	var targets := {}
	var shape_ok := true
	for cd in cards:
		var d: Dictionary = cd
		targets[str(d["target"])] = d
		if str(d["lang"]) != "ja" or str(d["reading"]) == "" or str(d["ko"]) == "" or not str(d["note"]).contains("장음"):
			shape_ok = false
	ok(cards.size() == before_cards + wrong_words.size() and cards.size() == wrong_words.size(), "review cards = the wrong pairs' distinct words (%d, expected %d)" % [cards.size(), wrong_words.size()])
	var words_ok := true
	for w in wrong_words.keys():
		if not targets.has(w) or str((targets[w] as Dictionary)["reading"]) != str((wrong_words[w] as Dictionary)["rd"]) or str((targets[w] as Dictionary)["ko"]) != str((wrong_words[w] as Dictionary)["ko"]):
			words_ok = false
	ok(words_ok and shape_ok, "each card has lang ja, target (headword), reading, ko and a note")
	ok(_btn("AddCardsBtn") != null and _btn("AddCardsBtn").disabled and _btn("AddCardsBtn").text.contains("넣었어요"), "the add button is off and says it is done")
	ok(Store.add_review(s.wrong_cards()) == 0, "the same words are not added twice")
	ok(Store.xp("ja") == xp0 + 10 and _drill_events() == drill0 + 1, "adding cards does not give XP or a drill event again")
	# 같은 소리 다시 -> 다시 10문항, 이번엔 XP 가 또 한 번(새 세션)
	_press("AgainBtn")
	await _frames(4)
	ok(s.stage == "listen" and s.idx == 0 and s.session.size() == 10 and s.answered_count() == 0, "[같은 소리 다시] starts a fresh round")
	s.go_back() # 이 판은 여기서 접는다 (뒤로 가기 시험은 따로)
	await _frames(2)
	ok(s.stage == "detail", "going back from a round leaves the explanation")
	# 목록으로
	_reset_state()
	s.session = []
	s.open("ja", {"p": "j_sokuon"})
	await _frames(2)
	_press("StartListenBtn")
	await _frames(6)
	for k in 10:
		await _frames(6)
		var played2: String = str(tts_calls[tts_calls.size() - 1]["text"]) if not tts_calls.is_empty() else ""
		var q2: Dictionary = s.current()
		var opts2: Array = q2["options"]
		var ri := 0 if str((opts2[0] as Dictionary)["rd"]) == played2 else 1
		_press("Opt%d" % ri)
		await _frames(2)
		tts_calls.clear()
		_press("NextBtn")
		await _frames(3)
	ok(s.stage == "result" and _has_text(s, "100%") and _find(_holder, "WrongPairs") == null and _btn("AddCardsBtn") == null, "all right: 100%, no wrong pairs, no add-cards button")
	_press("ListBtn")
	await _frames(3)
	ok(s.stage == "list" and _btn("Chip_j_long") != null, "[소리 목록으로] returns to the list")
	ok(press_n >= 24, "enough real button presses were made (%d)" % press_n)
	print("press total (listen flow): ", press_n)


# ---------------------------------------------------------------- speak flow

func _expected_found(item: Dictionary, p: String) -> int:
	var rd: String = str(item["rd"]) if str(item["rd"]) != "" else str(item["target"])
	var n := 0
	for e in JaSounds.events(rd):
		if str((e as Dictionary)["cat"]) == p:
			n += 1
	return n


func _test_speak_flow() -> void:
	print("[speak flow: fake /score -> sound verdict -> summary]")
	_reset_state()
	press_n = 0
	var s := _make_screen()
	s.open("ja", {"p": "j_sokuon"})
	await _frames(3)
	ok(s.stage == "detail" and not _btn("StartSpeakBtn").disabled, "the sokuon explanation has an enabled speak button")
	_press("StartSpeakBtn")
	await _frames(4)
	ok(s.stage == "speak" and s.speak_items.size() == 5 and s.drill != null, "speak starts with 5 items and a SpeakDrill")
	ok(str((s._shell["count"] as Label).text) == "1 / 5", "the speak progress shows '1 / 5'")
	ok(_has_text(s, "인식된 글자와 비교한 추정이에요"), "the estimate note is on the speak screen")
	await _shot("speak_start")
	var h0: String = _phon_h("j_sokuon")
	var xp0: int = Store.xp("ja")
	var drill0: int = _drill_events()
	for k in 5:
		var item: Dictionary = s.speak_current()
		var found: int = _expected_found(item, "j_sokuon")
		_fake_mode = "bad_sokuon" if k == 0 else "all_ok"
		ok(_btn("NextBtn") != null and _btn("NextBtn").is_visible_in_tree(), "speak %d: the next button is on" % (k + 1))
		if k == 0:
			ok(found > 0, "speak 1: the first item has a sokuon (found %d)" % found)
		var before: String = _phon_h("j_sokuon")
		s.drill.recorder.recorded.emit(FAKE_REC) ## 마이크 대신: 녹음이 끝났다는 신호만 낸다
		await _frames(6)
		var last: Dictionary = (s.speak_results[k] as Dictionary).get("last", {})
		ok(not last.is_empty() and int(last["found"]) == found, "speak %d: the verdict found %d sokuon (got %s)" % [k + 1, found, str(last.get("found", "none"))])
		var want_bad: bool = k == 0 and found > 0
		var after: String = _phon_h("j_sokuon")
		var added: String = after.substr(before.length()) if after.begins_with(before) else "?"
		var expect_add: String = ("1" if want_bad else "0").repeat(found)
		ok(added == expect_add, "speak %d: phon.ja.j_sokuon gained '%s' (expected '%s')" % [k + 1, added, expect_add])
		ok(_find(_holder, "Verdict") != null, "speak %d: a verdict box is shown" % (k + 1))
		if want_bad:
			ok(_has_text(_find(_holder, "Verdict"), "틀림") and _has_text(_find(_holder, "Verdict"), "つ로 들림") and not bool(last["success"]), "speak 1: the verdict shows the missed sokuon (틀림, つ로 들림)")
			await _shot("speak_verdict_bad")
		elif found > 0:
			ok(_has_text(_find(_holder, "Verdict"), "맞음") and bool(last["success"]), "speak %d: the verdict shows the sokuon right" % (k + 1))
			if k == 1:
				await _shot("speak_verdict_ok")
		ok(_has_text(_find(_holder, "Verdict"), "인식된 글자와 비교한 추정이에요") or found == 0, "speak %d: the verdict repeats the estimate note" % (k + 1))
		ok(big_numbers(s).is_empty(), "speak %d: no 5-digit number" % (k + 1))
		_press("NextBtn")
		await _frames(4)
	ok(s.stage == "speak_result", "after the 5th next press the speak summary shows")
	ok(Store.xp("ja") == xp0 + 10 and _drill_events() == drill0 + 1, "speak summary: XP +10 once and one drill event")
	ok(_has_text(s, "인식된 글자와 비교한 추정이에요"), "the speak summary shows the estimate note")
	ok(_find(_holder, "SpeakResultHead") != null, "the speak summary has a result line")
	ok(_phon_h("j_sokuon").length() > h0.length(), "the speak answers changed the sokuon history")
	ok(phon_clean("en"), "nothing was written to phon.en")
	ok(_score_bodies.size() == 5 and str((_score_bodies[0] as Dictionary).get("lang", "")) == "ja", "5 /score requests were sent, all lang ja")
	await _shot("speak_result")
	_press("AgainBtn")
	await _frames(4)
	ok(s.stage == "speak" and s.speak_idx == 0, "[다시 하기] starts the speak round again")
	s.go_back()
	await _frames(2)
	_press_back_to_list(s)


func _press_back_to_list(s: JaSoundScreen) -> void:
	s.go_back()


func _test_speak_variants() -> void:
	print("[speak variants: self rating, silent, English response]")
	# 1) PC 연결 없음(needs_pc) -> 자가 평가, 통계에는 안 들어감
	_reset_state()
	var s := _make_screen()
	Route.mode = "phone"
	Route.phone_hook = func() -> bool: return true
	ok(SelfRatePanel.needed(), "setup: /score has nowhere to go (self rating is needed)")
	s.open("ja", {"p": "j_voice"})
	await _frames(3)
	_press("StartSpeakBtn")
	await _frames(4)
	var xp0: int = Store.xp("ja")
	s.drill.recorder.recorded.emit(FAKE_REC)
	await _frames(5)
	var panel: Node = _find(_holder, "SelfRatePanel")
	ok(panel != null and _score_bodies.is_empty(), "no PC: the self rating panel shows and no /score was sent")
	var good_btn: Button = null
	if panel != null:
		for c in _all_buttons(panel):
			if (c as Button).text == "잘했어요":
				good_btn = c
	ok(good_btn != null and good_btn.is_visible_in_tree() and not good_btn.disabled, "the self rating button '잘했어요' is visible and enabled")
	await _shot("speak_self_rate")
	if good_btn != null:
		press_n += 1
		print("press: SelfRate good")
		good_btn.pressed.emit()
	await _frames(4)
	ok(_find(_holder, "Verdict") != null and _has_text(_find(_holder, "Verdict"), "통계에는 넣지 않아요"), "self rated: the verdict says it is not counted")
	ok(_phon("j_voice").get("h", "") == "" and phon_clean("ja") and phon_clean("en"), "self rated: nothing entered the sound stats")
	ok((s.speak_results[0] as Dictionary)["success"] == true and (s.speak_results[0] as Dictionary)["self"] == true, "self rated counts as a success of the item, marked 'self'")
	Route.mode = "auto"
	Route.phone_hook = Callable()
	# 2) 무음(빈 응답): 기록 없음, 죽지 않음
	_reset_state()
	s = _make_screen()
	s.open("ja", {"p": "j_voice"})
	await _frames(3)
	_press("StartSpeakBtn")
	await _frames(4)
	_fake_mode = "silent"
	s.drill.recorder.recorded.emit(FAKE_REC)
	await _frames(6)
	ok(s.stage == "speak" and phon_clean("ja") and s.attempts == 0, "silent response: nothing recorded, still on the speak screen")
	ok(s.drill != null and s.drill.status == "silent", "silent response: the drill says it heard nothing")
	# 3) 영어(가나가 아닌) 응답: 점수는 남아도 소리별 판정 없음
	_fake_mode = "english"
	s.drill.recorder.recorded.emit(FAKE_REC)
	await _frames(6)
	ok(phon_clean("ja") and phon_clean("en"), "non-kana response: no sound stats written")
	ok(_find(_holder, "Verdict") != null and _has_text(_find(_holder, "Verdict"), "소리별 판정을 할 수 없어요"), "non-kana response: the verdict says the sound check is not possible")
	# 끝까지 안 해도 끝낼 수 있다: 다음 5번 -> 요약에 점수만 남겼다는 안내
	for k in 5:
		_press("NextBtn")
		await _frames(3)
	ok(s.stage == "speak_result" and Store.xp("ja") == 10, "finishing a round with only unusable verdicts still ends with XP once")
	ok(_has_text(s, "인식된 글자와 비교한 추정이에요"), "the summary keeps the estimate note")


func _all_buttons(n: Node) -> Array:
	var out: Array = []
	for c in n.get_children():
		if c is Button:
			out.append(c)
		out.append_array(_all_buttons(c))
	return out


# ---------------------------------------------------------------- no sound

func _test_no_sound() -> void:
	print("[no sound]")
	_reset_state()
	_api.base_url = "" ## fetch_hook 이 있어서 엔진은 pc: 주소가 없으면 소리를 낼 수 없다
	ok(not KanaVoice.available(), "setup: no sound is available")
	var s := _make_screen()
	s.open("ja", {"p": "j_long"})
	await _frames(3)
	var note: Node = _find(_holder, "NoSoundNote")
	ok(note != null and (note as Label).text.contains("일본어 음성이 있어야 해요"), "one line says Japanese voice is needed")
	ok(_btn("StartListenBtn") != null and _btn("StartListenBtn").disabled, "the listen button is off")
	ok(_btn("StartSpeakBtn") != null and _btn("StartSpeakBtn").disabled, "the speak button is off")
	ok(_btn("PairA_0") != null and _btn("PairA_0").disabled and _btn("PairB_0").disabled, "the pair sound buttons are off")
	ok(_find(_holder, "PairsCard") != null and _has_text(_find(_holder, "PairsCard"), str(JaSounds.category("j_long")["pairs"][0]["a_ko"])), "the pairs and their meanings are still readable")
	ok(_has_text(s, str(JaSounds.category("j_long")["hint_ko"]).substr(0, 12)), "the explanation is still shown")
	ok(not s.start_listen() and not s.start_speak() and s.stage == "detail", "starting is refused without sound")
	await _frames(6)
	ok(tts_calls.is_empty(), "nothing was played")
	await _shot("no_sound")
	_reset_state()


# ---------------------------------------------------------------- bad data

func _write_data(text: String) -> void:
	var f := FileAccess.open(TEST_DATA, FileAccess.WRITE)
	f.store_string(text)
	f.close()
	JaSounds.data_path = TEST_DATA
	JaSounds.clear_cache()


func _test_bad_data() -> void:
	print("[bad data]")
	_reset_state()
	# 깨진 JSON
	_write_data("{ this is not json")
	var s := _make_screen()
	s.open("ja")
	await _frames(3)
	ok(s.stage == "error" and _has_text(s, "소리 데이터를 불러오지 못했어요") and _btn("CloseBtn") != null, "broken JSON: an error notice and a close button, no crash")
	_press("CloseBtn")
	ok(_closed_n == 1, "the error screen can be closed")
	# 파일 없음
	JaSounds.data_path = "user://test_a5_missing_sounds.json"
	JaSounds.clear_cache()
	s.open("ja", {"p": "j_long"})
	await _frames(2)
	ok(s.stage == "error", "missing file: the error screen")
	# 쌍 없는 소리(j_za) + 쌍 있는 소리(j_long)
	var za_words: Array = []
	var za_phr: Array = []
	for i in 4:
		za_words.append({"w": "語%d" % i, "rd": "ご%d" % i, "pr": "ゴ", "ko": "낱말%d" % i})
		za_phr.append({"text": "文%d。" % i, "rd": "ぶん%d。" % i, "pr": "ブン", "ko": "문장%d" % i})
	var data := {"v": 1, "categories": [
		{"p": "j_za", "label": "ざ / じゃ", "hint_ko": "시험용 설명", "tip_ko": "", "pairs": [], "words": za_words, "phrases": za_phr},
		{"p": "j_long", "label": "장음 (ー)", "hint_ko": "장음 설명", "tip_ko": "요령", "pairs": [
			{"a": "家", "a_rd": "いえ", "a_pr": "イエ", "a_ko": "집", "b": "いいえ", "b_rd": "いいえ", "b_pr": "イーエ", "b_ko": "아니요"},
			{"a": "好き", "a_rd": "すき", "a_pr": "スキ", "a_ko": "좋아함", "b": "スキー", "b_rd": "すきー", "b_pr": "スキー", "b_ko": "스키"}], "words": za_words, "phrases": za_phr}]}
	_write_data(JSON.stringify(data))
	s.open("ja")
	await _frames(3)
	ok(s.stage == "list" and _btn("Chip_j_za") != null and _btn("Chip_j_long") != null and _btn("Chip_j_sokuon") == null, "partial data: only the sounds in the file are offered")
	_press("Chip_j_za")
	await _frames(3)
	ok(s.stage == "detail" and _find(_holder, "NoPairsNote") != null and _find(_holder, "PairsCard") == null, "a sound without pairs: a note and no pair card")
	ok(_btn("StartListenBtn").disabled and not _btn("StartSpeakBtn").disabled, "a sound without pairs: listen is off, speak is on")
	ok(_find(_holder, "WordsCard") != null and _find(_holder, "PhrasesCard") != null, "a sound without pairs: its words and phrases are shown")
	_press("StartSpeakBtn")
	await _frames(4)
	ok(s.stage == "speak" and s.speak_items.size() == 5, "a sound without pairs: the speak round works (5 items)")
	ok(not s.drill == null and _has_text(s, "語") or _has_text(s, "文"), "the speak item text is shown")
	s.go_back()
	await _frames(2)
	# 쌍이 2개뿐: 10문항을 순환해서 채운다
	s.go_back()
	await _frames(2)
	_press("Chip_j_long")
	await _frames(3)
	_press("StartListenBtn")
	await _frames(4)
	ok(s.stage == "listen" and s.session.size() == 10, "two pairs only: the round is still 10 questions")
	# 시작 전에 데이터가 바뀌어도(없어져도) 죽지 않는다
	JaSounds.data_path = "user://test_a5_missing_sounds.json"
	JaSounds.clear_cache()
	s.go_back()
	s.go_back()
	await _frames(2)
	ok(s.stage == "list", "data vanished mid-way: still a list screen")
	_reset_state()


# ---------------------------------------------------------------- back navigation

func _test_back_navigation() -> void:
	print("[back navigation]")
	_reset_state()
	var s := _make_screen()
	s.open("ja")
	await _frames(2)
	_press("Chip_j_tsu")
	await _frames(2)
	_press("StartListenBtn")
	await _frames(4)
	ok(s.stage == "listen", "in a round")
	var back: Button = s._shell["back"]
	press_n += 1
	print("press: header back button")
	back.pressed.emit()
	await _frames(2)
	ok(s.stage == "detail" and _closed_n == 0, "back from a round: the explanation")
	back.pressed.emit()
	await _frames(2)
	ok(s.stage == "list" and _closed_n == 0, "back from the explanation: the list")
	back.pressed.emit()
	await _frames(2)
	ok(_closed_n == 1, "back from the list: closed")
	ok(s.go_back() and _closed_n == 2, "go_back() reports handled and closes again")
	s.on_hide()
	ok(true, "on_hide() does not crash")


# ---------------------------------------------------------------- layout

func _test_layout() -> void:
	print("[layout: width, touch size, text]")
	_reset_state()
	var s := _make_screen()
	var screen: Vector2 = PHONE_SCREEN if phone else PC_SCREEN
	var bounds := Rect2(Vector2.ZERO, screen)
	var stages: Array = []
	s.open("ja")
	await _frames(3)
	stages.append("list")
	_check_buttons(s, bounds, "list")
	s.open("ja", {"p": "j_voice"})
	await _frames(3)
	_check_buttons(s, bounds, "detail")
	await _shot("detail")
	s.start_listen()
	await _frames(6)
	_check_buttons(s, bounds, "question")
	ok(_btn("Opt0").size.y >= 64.0 - 0.5, "question: options are at least 64 high at this text size")
	ok(_btn("ReplayBtn").size.y >= 56.0 - 0.5, "question: the replay button is at least 56 high")
	var played: String = str(tts_calls[tts_calls.size() - 1]["text"]) if not tts_calls.is_empty() else ""
	var q: Dictionary = s.current()
	var ri := 0 if str((q["options"][0] as Dictionary)["rd"]) == played else 1
	_press("Opt%d" % (1 - ri)) # 일부러 오답: 오답 화면도 폭을 본다
	await _frames(3)
	_check_buttons(s, bounds, "wrong feedback")
	if _scheme == "dark" or _font_scale > 1.2:
		await _shot("layout_wrong")
	s.go_back()
	await _frames(2)
	s.start_speak()
	await _frames(4)
	_check_buttons(s, bounds, "speak")
	ok(_find(_holder, "SpeakText") != null and (_find(_holder, "SpeakText") as Label).get_theme_font_size("font_size") >= 12, "speak text is at least size 12")
	var smallest := 99
	for l in _all_labels(s):
		var sz: int = (l as Label).get_theme_font_size("font_size")
		if (l as Label).visible and str((l as Label).text) != "" and sz < smallest:
			smallest = sz
	ok(smallest >= 12, "no visible text is smaller than size 12 (smallest %d)" % smallest)
	s.go_back()
	_reset_state()


func _all_labels(n: Node) -> Array:
	var out: Array = []
	for c in n.get_children():
		if c is Label:
			out.append(c)
		out.append_array(_all_labels(c))
	return out


## 보이는 Button 은 화면 가로 안에 들고, 눌러서 쓰기 좋은 높이(44 이상)다.
func _check_buttons(s: Node, bounds: Rect2, tag: String) -> void:
	var bad_w := 0
	var small_h := 0
	var n := 0
	for b in _all_buttons(s):
		if not (b as Button).is_visible_in_tree() or (b as Button).get_parent() is RecorderWidget:
			continue
		n += 1
		var r: Rect2 = (b as Button).get_global_rect()
		if not rect_inside(r, bounds, 0.0):
			bad_w += 1
			print("    out of bounds: ", (b as Button).name, " ", r)
		if r.size.y < 44.0 - 0.5:
			small_h += 1
			print("    too short: ", (b as Button).name, " ", r.size.y)
	ok(n > 0 and bad_w == 0, "%s: %d buttons all inside the screen width" % [tag, n])
	ok(small_h == 0, "%s: every visible button is at least 44 high" % tag)
	ok(big_numbers(s).is_empty(), "%s: no 5-digit number on screen" % tag)


# ---------------------------------------------------------------- source scan

func _test_static_scan() -> void:
	print("[source scan: no network, no emoji, no hard-coded colors]")
	var forbid: Array = ["HTTP" + "Request", "OS.shell" + "_open", "OS.request" + "_permission", "Color(\"" + "#", "87" + "70", "87" + "75", "87" + "76", "Api" + ".", "Route" + "."]
	var files: Array = ["res://scripts/practice/ja_sound_screen.gd"]
	var hits: Array = []
	var emoji_hits := 0
	for f in files:
		var text: String = FileAccess.get_file_as_string(str(f))
		ok(text != "", "%s can be read" % f)
		for w in forbid:
			if text.contains(str(w)):
				hits.append("%s contains %s" % [f, w])
		for i in text.length():
			var c: int = text.unicode_at(i)
			if (c >= 0x2190 and c <= 0x2BFF) or c >= 0x1F000 or (c >= 0xFE00 and c <= 0xFE0F):
				emoji_hits += 1
	ok(hits.is_empty(), "the screen source has no http class, shell open, permission request, fixed port, hex colour, Api or Route call (%s)" % str(hits))
	ok(emoji_hits == 0, "no emoji or symbol characters in the screen source (%d)" % emoji_hits)
	var src: String = FileAccess.get_file_as_string("res://scripts/practice/ja_sound_screen.gd")
	ok(src.contains("StudyLog.add_phon_obs(LANG,") and not src.contains("add_phon_obs(lang"), "the screen records with the constant ja, never with the screen's lang variable")
	# 검사기 점검: 금지어가 실제로 들어 있는 글에서는 잡아내는지
	var probe := "var r = HTTP" + "Request.new()"
	fails(probe.contains("HTTP" + "Request"), "scan helper on text that contains the forbidden word")
	var bad_src := "StudyLog.add_phon_obs(lang, p, ok)"
	fails(not (bad_src.contains("StudyLog.add_phon_obs(LANG,") and not bad_src.contains("add_phon_obs(lang")), "the ja-constant check on a call that uses the variable")
