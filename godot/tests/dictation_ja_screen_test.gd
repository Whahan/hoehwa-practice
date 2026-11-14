extends Node
## 일본어 받아쓰기 화면 시험 (서버 없이 가짜 응답으로): DictationScreen 의 일본어 분기.
## 실제 버튼(▶ 듣기 · 천천히 · 첫 글자 힌트 · 모르겠어요 · 확인 · 다음 · 결과 보기 · 다시 하기)의 pressed 로 6문장을 끝까지 간다.
##   PC   : godot --headless --path godot res://tests/dictation_ja_screen_test.tscn -- --api=http://127.0.0.1:9
##   폰   : godot --headless --path godot --resolution 412x915 res://tests/dictation_ja_screen_test.tscn -- --phone --api=http://127.0.0.1:9
##   옵션 : -- [--phone] [--font-scale=1.5] [--dark] [--shots=<폴더>]   (--shots 는 창이 있는 실행에서만 PNG 가 저장된다: 헤드리스는 그림이 없다)
## 마지막 줄: "== dictation_ja_screen: N passed, M failed =="  (실패가 있으면 종료 코드 1)
## 시험 전용 파일 경로(user://test_a4_*)만 쓰고 끝에 되돌린다. 소리는 Tts.fetch_hook, 요청은 SpeakDrill.api_hook 으로 가로채고 주소는 닫힌 포트(9)다.
## 검사기(wrong_cell_visible / no_big_numbers / rect_inside)는 일부러 틀린 입력을 넣어 실제로 실패하는지도 본다 ("selfcheck FAIL-as-expected ..." 줄).
## 누를 때마다 "press: <버튼 글>" 을 찍는다(화면 흐름은 함수 호출이 아니라 버튼으로만 넘긴다).

const SENT_JA := "res://tests/sample_practice_dictation_ja.json"
const SENT_EN := "res://tests/sample_practice_sentences_en.json"
const TEST_PROGRESS := "user://test_a4_progress.json"
const TEST_LOG := "user://test_a4_studylog.json"
const PHONE_SCREEN := Vector2(412, 915)
const PC_SCREEN := Vector2(1280, 800)
const NEXT_WAIT_MSEC := 320 ## DictationScreen.NEXT_LOCK_MSEC(250) 보다 길게

var passed: int = 0
var failed: int = 0
var phone: bool = false
var presses: int = 0
var requests: Array = []
var routes: Dictionary = {}
var tts_calls: Array = []
var _saved := {}
var _holder: Control = null
var _scheme: String = "light"
var _font_scale: float = 1.0
var _shots_dir: String = ""
var _closed_n: int = 0
var _api: Node = null ## 자동 로드 Api (접속 금지 규칙 때문에 이름으로 직접 부르지 않고 노드로 잡는다)


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


func _wait_ms(ms: int) -> void:
	var t0: int = Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < ms:
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
	print("== dictation_ja_screen start (%s, scheme=%s, font_scale=%s) ==" % ["phone" if phone else "pc", _scheme, Ds.font_scale])
	_setup()
	_selfcheck()
	await _test_session_flow()
	await _test_no_voice()
	await _test_bad_inputs()
	await _test_extra_letter_only()
	await _test_english_unchanged()
	await _test_layout()
	_teardown()
	print("== dictation_ja_screen: %d passed, %d failed ==" % [passed, failed])
	get_tree().quit(1 if failed > 0 else 0)


# ---------------------------------------------------------------- setup

func _setup() -> void:
	_saved = {
		"prefs": Store.prefs.duplicate(true),
		"progress": Store.progress.duplicate(true),
		"progress_path": Store.progress_path,
		"log_path": StudyLog.path,
		"base": _api.base_url,
	}
	Store.progress_path = TEST_PROGRESS
	Store.progress = Progress.blank()
	StudyLog.path = TEST_LOG
	_rm(TEST_LOG)
	StudyLog.load_from_disk()
	StudyLog.reset()
	Store.prefs["lang"] = "ja"
	_api.base_url = "http://127.0.0.1:9" ## 닫힌 포트: 실제 PC 서버에 닿지 않게 (소리·요청은 훅이 가로챈다)
	Tts.fetch_hook = Callable(self, "_tts_hook")
	SpeakDrill.api_hook = Callable(self, "_hook")
	get_window().min_size = Vector2i.ZERO
	get_window().size = Vector2i(PHONE_SCREEN if phone else PC_SCREEN)


func _teardown() -> void:
	if _holder != null and is_instance_valid(_holder):
		_holder.queue_free()
	Tts.fetch_hook = Callable()
	SpeakDrill.api_hook = Callable()
	Tts.stop()
	StudyLog.reset()
	for p in [TEST_LOG, TEST_LOG + ".tmp", TEST_LOG + ".bad", TEST_PROGRESS, TEST_PROGRESS + ".tmp"]:
		_rm(p)
	StudyLog.path = _saved["log_path"]
	Store.progress_path = _saved["progress_path"]
	Store.progress = _saved["progress"]
	_api.base_url = _saved["base"]
	Store.prefs = _saved["prefs"]


func _rm(path: String) -> void:
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


func _tts_hook(text: String, l: String, speed: float, _voice: String) -> Variant:
	tts_calls.append({"text": text, "lang": l, "speed": speed})
	return null


func _hook(method: String, path: String, body: Variant) -> Variant:
	requests.append({"method": method, "path": path, "body": body})
	for k in routes.keys():
		if path.begins_with(str(k)):
			var r: Variant = routes[k]
			if r is Callable:
				return await (r as Callable).call(method, path, body)
			return r
	return ERR(404, "알 수 없는 경로예요.")


func OK(data: Variant) -> Dictionary:
	return {"ok": true, "code": 200, "data": data, "error": ""}


func ERR(code: int, msg: String) -> Dictionary:
	return {"ok": false, "code": code, "data": null, "error": msg}


func load_json(path: String) -> Variant:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return null
	return JSON.parse_string(f.get_as_text())


func _reset_state() -> void:
	StudyLog.reset()
	Store.progress = Progress.blank()
	requests.clear()
	tts_calls.clear()
	routes = {"/practice/sentences": Callable(self, "_sentences_route")}
	_api.base_url = "http://127.0.0.1:9"
	DictationScreen.seen_ids = []
	DictationScreen.seen_ids_ja = []


## 가짜 서버: 요청의 n 만큼(최대 견본 개수) 문장을 돌려준다(진짜 서버처럼 n 을 따른다).
func _sentences_route(_m: String, p: String, _b: Variant) -> Dictionary:
	var data: Dictionary = (load_json(SENT_JA if "lang=ja" in p else SENT_EN) as Dictionary).duplicate(true)
	var rx := RegEx.create_from_string("[?&]n=([0-9]+)")
	var m := rx.search(p)
	if m != null:
		data["sentences"] = (data["sentences"] as Array).slice(0, int(m.get_string(1)))
	return OK(data)


func _make_screen() -> DictationScreen:
	if _holder != null and is_instance_valid(_holder):
		_holder.queue_free()
	_holder = Control.new()
	_holder.size = PHONE_SCREEN if phone else PC_SCREEN
	_holder.clip_contents = true
	add_child(_holder)
	var s := DictationScreen.new()
	_holder.add_child(s)
	s.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_closed_n = 0
	s.closed.connect(func() -> void: _closed_n += 1)
	return s


# ---------------------------------------------------------------- tree helpers

func _buttons(n: Node, out: Array = []) -> Array:
	for c in n.get_children():
		if c is Button:
			out.append(c)
		_buttons(c, out)
	return out


func _labels(n: Node, out: Array = []) -> Array:
	for c in n.get_children():
		if c is Label:
			out.append(c)
		_labels(c, out)
	return out


func _has_text(n: Node, needle: String) -> bool:
	for c in n.get_children():
		if (c is Label or c is Button) and str(c.text).contains(needle):
			return true
		if _has_text(c, needle):
			return true
	return false


## 보이는 버튼 중 글에 needle 이 든 것 (없으면 null).
func _button_with(n: Node, needle: String) -> Button:
	for b in _buttons(n):
		var btn: Button = b
		if btn.is_visible_in_tree() and btn.text.contains(needle):
			return btn
	return null


## 실제로 누른다: 보이고 꺼져 있지 않은 버튼의 pressed 를 낸다. 눌렀으면 true.
func _press(s: DictationScreen, needle: String) -> bool:
	var b: Button = _button_with(s, needle)
	if b == null or b.disabled:
		print("  (cannot press: %s)" % needle)
		return false
	presses += 1
	print("press: ", b.text)
	b.pressed.emit()
	return true


## 입력칸에 쓴다(키보드로 치는 것과 같게 text_changed 를 낸다).
func _type(s: DictationScreen, text: String) -> void:
	s._edit.text = text
	s._edit.text_changed.emit(text)


## 이 언어의 받아쓰기 기록 수(모든 날의 합: 시험이 자정을 넘겨도 흔들리지 않게).
func _dictation_count(l: String) -> int:
	var total := 0
	var days: Dictionary = StudyLog.snapshot().get("days", {})
	for iso in days.keys():
		var rec: Dictionary = (days[iso] as Dictionary).get(l, {})
		total += int((rec.get("n", {}) as Dictionary).get("dictation", 0))
	return total


## 이 언어로 공부했다고 표시된 날이 있는가(오늘 표시는 자정을 넘기면 어제일 수 있어 모든 날을 본다).
func _did_any_day(l: String) -> bool:
	for k in (Store.progress["days"] as Dictionary).keys():
		if bool(((Store.progress["days"] as Dictionary)[k] as Dictionary).get(l, false)):
			return true
	return false


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

## 보이는 글 어디에도 연속 5자리 이상 숫자가 없는가(unix 시각·ms·바이트를 그대로 내보이지 않는다, C-15).
func no_big_numbers(root: Node) -> bool:
	var rx := RegEx.create_from_string("[0-9]{5,}")
	for l in _labels(root):
		if rx.search((l as Label).text) != null:
			return false
	for b in _buttons(root):
		if rx.search((b as Button).text) != null:
			return false
	return true


## 통과했어도 철자가 틀렸으면 그 칸이 보이는가: "철자가 조금 틀렸어요" 한 줄과, ✕ 와 이유 글(빠짐/철자 틀림)이 든 칩.
func wrong_cell_visible(root: Node) -> bool:
	if not _has_text(root, "철자가 조금 틀렸어요"):
		return false
	for l in _labels(root):
		var t: String = (l as Label).text
		if t.begins_with("✕") and (t.contains("빠짐") or t.contains("철자 틀림")):
			return true
	return false


func rect_inside(r: Rect2, bounds: Rect2, min_h: float) -> bool:
	return r.position.x >= bounds.position.x - 0.5 and r.end.x <= bounds.end.x + 0.5 and r.size.y >= min_h - 0.5


func _selfcheck() -> void:
	var fake := Control.new()
	var l1 := Label.new()
	l1.text = "다음 시각 12345"
	fake.add_child(l1)
	add_child(fake)
	fails(not no_big_numbers(fake), "a screen showing 12345 is caught by no_big_numbers")
	l1.text = "92점 / 14자 / 들은 횟수 1"
	ok(no_big_numbers(fake), "selfcheck: readable numbers pass no_big_numbers")
	var plain := Label.new()
	plain.text = "정답을 확인했어요."
	fake.add_child(plain)
	fails(not wrong_cell_visible(fake), "a card without the wrong-cell note is caught by wrong_cell_visible")
	var note := Label.new()
	note.text = "철자가 조금 틀렸어요. 아래 ✕ 칸을 확인해 보세요."
	fake.add_child(note)
	fails(not wrong_cell_visible(fake), "the note without any ✕ chip is caught by wrong_cell_visible")
	var chip := Label.new()
	chip.text = "✕ っ  · 빠짐"
	fake.add_child(chip)
	ok(wrong_cell_visible(fake), "selfcheck: note + ✕ chip with a reason is accepted")
	fake.queue_free()
	var bounds := Rect2(0, 0, 412, 915)
	ok(rect_inside(Rect2(12, 100, 388, 48), bounds, 44.0), "selfcheck: rect_inside accepts a row inside the screen")
	fails(not rect_inside(Rect2(12, 100, 420, 48), bounds, 44.0), "row sticks out to the right")
	fails(not rect_inside(Rect2(12, 100, 388, 30), bounds, 44.0), "button shorter than 44")
	# 칩 만들기 검사기도 틀린 입력을 본다
	ok(DictationScreen.ja_chips({}).is_empty() and DictationScreen.ja_chips({"units": "x"}).is_empty(), "ja_chips: no units (or a wrong type) -> no chips, no error")
	ok(DictationScreen.ja_mode_text({}, true) == "" and DictationScreen.ja_mode_text({"mode": "zzz"}, false) == "", "ja_mode_text: unknown mode -> empty text")


# ---------------------------------------------------------------- 6문장을 버튼으로 끝까지

func _test_session_flow() -> void:
	print("[ja dictation: 6 sentences with real buttons]")
	_reset_state()
	var s := _make_screen()
	var xp0: int = Store.xp("ja")
	var n0: int = _dictation_count("ja")
	s.open("ja", {})
	await _frames(2)
	ok(s.stage == "loading" or s.stage == "run", "open('ja') starts loading, no 'English only' screen")
	for i in 120:
		if s.stage == "run":
			break
		await _frames(1)
	ok(s.stage == "run" and s.sentences.size() == 6, "6 Japanese sentences loaded (SESSION_N_JA)")
	var req: String = str(requests[0]["path"]) if requests.size() > 0 else ""
	ok("lang=ja" in req and "mode=dictation" in req and "n=6" in req, "request: " + req)
	var raws: Array = (load_json(SENT_JA) as Dictionary)["sentences"]
	ok(str(s.sentences[0].get("pron", "")) != "" and str(s.sentences[0].get("reading", "")) != "", "parse keeps reading and pron for Japanese")
	await _shot("a4_question")

	# per sentence: said, expected passed, expected mode, expected visible text(s), gave up
	var plan: Array = [
		{"said": "来てくださってありがとうございます。", "passed": true, "mode": "exact", "see": "표기까지 맞음"},
		{"said": "めがさめたらゆきがふっていた", "passed": true, "mode": "reading", "see": "읽기가 맞아요(한자를 가나로 씀)"},
		{"said": "おっとはまもなく帰ってきます", "passed": true, "mode": "mixed", "see": "일부만 한자로 씀"},
		{"said": "かれはれしゃにまにあうでしょうか", "passed": true, "mode": "wrong", "see": "철자가 조금 틀렸어요"},
		{"said": "", "passed": false, "mode": "empty", "see": "정답을 확인했어요", "give_up": true},
		{"said": "彼は学校にバスで生きます", "passed": false, "mode": "wrong", "see": "통과 기준은 85점이에요"},
	]
	var passes := 0
	for i in 6:
		var p: Dictionary = plan[i]
		var text: String = str(raws[i]["text"])
		ok(s.idx == i and s.stage == "run", "sentence %d: on screen" % (i + 1))
		ok(not _has_text(s, text), "sentence %d: the answer text is not shown before checking" % (i + 1))
		ok(_has_text(s, "글자 수 ") and _has_text(s, "자 (가나 기준)") and _has_text(s, "들은 횟수 0"), "sentence %d: letter count and listen counter are readable" % (i + 1))
		ok(str((s._shell["count"] as Label).text) == "%d / 6" % (i + 1), "sentence %d: header shows 'i / 6'" % (i + 1))
		tts_calls.clear()
		ok(_press(s, "듣기"), "sentence %d: press listen" % (i + 1))
		ok(_press(s, "천천히"), "sentence %d: press slow" % (i + 1))
		await _frames(2)
		ok(tts_calls.size() == 2 and str(tts_calls[0]["text"]) == text and str(tts_calls[0]["lang"]) == "ja" and absf(float(tts_calls[1]["speed"]) - Tts.SLOW_SPEED) < 0.01, "sentence %d: spoke the sentence in ja, normal and slow" % (i + 1))
		ok(_has_text(s, "들은 횟수 2"), "sentence %d: listen counter = 2" % (i + 1))
		var chk: Button = s._check_btn
		ok(chk != null and chk.disabled, "sentence %d: [확인] disabled while the input is empty" % (i + 1))
		ok(not _press(s, "확인"), "sentence %d: pressing a disabled [확인] does nothing" % (i + 1))
		if i == 0:
			var hint_before: bool = s._hint_label != null and s._hint_label.visible
			ok(_press(s, "첫 글자 힌트"), "sentence 1: press hint")
			ok(not hint_before and s._hint_label.visible and s._hint_label.text == DictationDiffJa.first_hint(str(raws[0]["reading"])) and s._hint_label.text.ends_with("…"), "sentence 1: hint shows the first 2 kana (%s)" % s._hint_label.text)
		if bool(p.get("give_up", false)):
			ok(_press(s, "모르겠어요"), "sentence %d: press give up" % (i + 1))
		else:
			_type(s, str(p["said"]))
			await _frames(1)
			ok(not s._check_btn.disabled, "sentence %d: [확인] enabled after typing" % (i + 1))
			ok(_press(s, "확인"), "sentence %d: press check" % (i + 1))
		await _frames(3)
		var r: Dictionary = s.results[i]
		ok(s.is_checked() and bool(r["passed"]) == bool(p["passed"]), "sentence %d: passed=%s (score %d)" % [i + 1, str(p["passed"]), int(r["score"])])
		if not bool(p.get("give_up", false)):
			ok(str((r["diff"] as Dictionary)["mode"]) == str(p["mode"]), "sentence %d: mode %s" % [i + 1, str(p["mode"])])
		ok(_has_text(s, "%d점" % int(r["score"])), "sentence %d: score is shown as '%d점'" % [i + 1, int(r["score"])])
		ok(_has_text(s, str(p["see"])), "sentence %d: shows '%s'" % [i + 1, str(p["see"])])
		ok(_has_text(s, text) and _has_text(s, str(raws[i]["ko"])), "sentence %d: answer text and Korean translation are shown after checking" % (i + 1))
		ok(_has_text(s, str(raws[i]["reading"])), "sentence %d: the answer reading is shown" % (i + 1))
		ok(no_big_numbers(s), "sentence %d: no 5+ digit number on screen (C-15)" % (i + 1))
		var nb: Button = _button_with(s, "결과 보기" if i == 5 else "다음")
		ok(nb != null and not nb.disabled, "sentence %d: the next button is visible and enabled" % (i + 1))
		if bool(r["passed"]):
			passes += 1
		if i == 0:
			await _shot("a4_correct_exact")
		if i == 3:
			ok(wrong_cell_visible(s), "sentence 4: PASSED with a missing っ, and the wrong cell is still shown (note + ✕ chip with its reason)")
			ok(_has_text(s, "✓ 통과!") and bool(r["passed"]) and str((r["diff"] as Dictionary)["mode"]) == "wrong", "sentence 4: it says passed AND that the spelling was slightly wrong")
			ok(_has_text(s, "✕ 列車(れっしゃ)  · 빠짐"), "sentence 4: the wrong chip names the kanji chunk, its right reading and the reason")
			await _shot("a4_passed_but_wrong")
		if i == 5:
			ok(_has_text(s, "한자가 달라요") and wrong_cell_visible_chip(s), "sentence 6: the wrong kanji chip says the kanji differs")
			await _shot("a4_wrong")
		if i < 3 or i == 4:
			ok(not _has_text(s, "철자가 조금 틀렸어요"), "sentence %d: no 'slightly wrong' note on a clean or given-up answer" % (i + 1))
		ok(_press(s, "결과 보기" if i == 5 else "다음"), "sentence %d: press next" % (i + 1))
		await _wait_ms(NEXT_WAIT_MSEC)
		await _frames(2)
	ok(s.stage == "summary", "after the last [결과 보기] the summary is shown")
	ok(_has_text(s, "오늘의 받아쓰기") and _has_text(s, "평균 ") and _has_text(s, "통과 %d개 / 시도 6개" % passes), "summary: average and 'passed n / tried 6'")
	ok(Store.xp("ja") - xp0 == 3 * passes, "XP: +3 per passed sentence for 'ja' (%d)" % (Store.xp("ja") - xp0))
	ok(Store.xp("en") == 0, "XP of English is untouched")
	ok(_dictation_count("ja") - n0 == 6, "StudyLog: 6 'dictation' events for ja")
	ok(_dictation_count("en") == 0, "StudyLog: none for en")
	ok(_did_any_day("ja") and not _did_any_day("en"), "6 attempts mark the day as studied for ja only")
	var cards: Array = Store.review_for("ja")
	ok(s.added_cards == 2 and cards.size() == 2, "review: the 2 sentences below 85 became cards (%d)" % cards.size())
	var card_ok := true
	for c in cards:
		var cd: Dictionary = c
		if str(cd["note"]) != "받아쓰기" or str(cd["lang"]) != "ja" or str(cd["reading"]) == "" or str(cd["ko"]) == "":
			card_ok = false
	ok(card_ok and str(cards[0]["target"]) == str(raws[4]["text"]) and str(cards[1]["target"]) == str(raws[5]["text"]), "review cards: {lang ja, target text, reading, ko, note 받아쓰기}")
	ok(Store.review_for("en").is_empty(), "no English card")
	ok(no_big_numbers(s), "summary: no 5+ digit number")
	await _shot("a4_summary")

	# 다시 하기: 새 6문장(같은 가짜 응답), 같은 문장은 복습 카드로 두 번 들어가지 않는다
	var reqs_before: int = requests.size()
	ok(_press(s, "다시 하기"), "press again")
	for i in 120:
		if s.stage == "run":
			break
		await _frames(1)
	ok(s.stage == "run" and s.idx == 0 and requests.size() == reqs_before + 1 and s.results.size() == 6, "again: a new request, a new run of 6")
	ok("exclude=" in str(requests[requests.size() - 1]["path"]), "again: the sentences already seen are sent as exclude")
	for i in 6:
		ok(_press(s, "듣기"), "again %d: press listen" % (i + 1))
		if i >= 4:
			ok(_press(s, "모르겠어요"), "again %d: press give up" % (i + 1))
		else:
			_type(s, str(raws[i]["text"]))
			ok(_press(s, "확인"), "again %d: press check" % (i + 1))
		await _frames(2)
		ok(s.is_checked() and (i >= 4 or bool(s.results[i]["passed"])), "again %d: checked" % (i + 1))
		ok(_press(s, "결과 보기" if i == 5 else "다음"), "again %d: press next" % (i + 1))
		await _wait_ms(NEXT_WAIT_MSEC)
		await _frames(2)
	ok(s.stage == "summary" and s.added_cards == 0 and Store.review_for("ja").size() == 2, "again: the same failed sentences are not added twice (still 2 cards)")
	ok(_press(s, "연습으로") and _closed_n == 1, "press [연습으로] -> closed")
	print("presses in this test so far: %d" % presses)
	ok(presses >= 30, "at least 30 real button presses (%d)" % presses)


## 화면에 ✕ 로 시작하는 칩이 하나라도 있는가.
func wrong_cell_visible_chip(root: Node) -> bool:
	for l in _labels(root):
		if (l as Label).text.begins_with("✕"):
			return true
	return false


# ---------------------------------------------------------------- 소리 없음

func _test_no_voice() -> void:
	print("[ja dictation: no voice]")
	_reset_state()
	_api.base_url = "" ## fetch_hook 이 있어서 engine 은 pc: 주소가 없으면 소리를 낼 수 없다
	ok(not KanaVoice.available(), "setup: no sound available")
	var s := _make_screen()
	s.open("ja", {})
	await _frames(3)
	ok(s.stage == "no_voice" and requests.is_empty(), "no voice -> stage 'no_voice' and 0 requests (%d)" % requests.size())
	ok(_has_text(s, "소리가 있어야 해요") and _has_text(s, "일본어 음성 데이터") and _has_text(s, "PC에 연결"), "the notice says what to do")
	ok(_button_with(s, "듣기") == null and s._edit == null, "no listen button and no input box")
	await _shot("a4_no_voice")
	ok(_press(s, "연습으로") and _closed_n == 1, "press [연습으로] -> closed")
	# 소리가 생기면 같은 화면이 다시 열려 문장을 부른다
	_api.base_url = "http://127.0.0.1:9"
	s.open("ja", {})
	for i in 120:
		if s.stage == "run":
			break
		await _frames(1)
	ok(s.stage == "run" and requests.size() == 1, "with sound again the same screen runs (1 request)")


# ---------------------------------------------------------------- 일부러 틀린 입력

func _test_bad_inputs() -> void:
	print("[ja dictation: bad input]")
	_reset_state()
	var s := _make_screen()
	s.open("ja", {})
	for i in 120:
		if s.stage == "run":
			break
		await _frames(1)
	ok(s.stage == "run", "setup: running")
	ok(not s.check(false) and not s.is_checked(), "empty input: check() does nothing")
	_type(s, "")
	ok(s._check_btn.disabled and not _press(s, "확인"), "empty input: [확인] is disabled and pressing does nothing")
	_type(s, "   \t ")
	ok(s._check_btn.disabled and not _press(s, "확인") and not s.is_checked(), "spaces only: [확인] stays disabled")
	_type(s, "I like tea")
	ok(not s._check_btn.disabled and _press(s, "확인"), "an English sentence can be checked")
	await _frames(2)
	ok(s.is_checked() and int(s.results[0]["score"]) == 0 and not bool(s.results[0]["passed"]), "English text for a Japanese sentence -> 0 points, not passed, no error")
	ok(_has_text(s, "0점") and wrong_cell_visible_chip(s), "0 points shows the ✕ chips")
	ok(_press(s, "다음"), "press next")
	await _wait_ms(NEXT_WAIT_MSEC)
	await _frames(2)
	_type(s, "あ".repeat(10000))
	ok(s._typed.length() == 300, "10,000 characters are cut at 300 (%d)" % s._typed.length())
	var t0: int = Time.get_ticks_msec()
	ok(_press(s, "확인"), "press check with a very long answer")
	ok(Time.get_ticks_msec() - t0 < 1500, "the long answer is scored fast (%d ms)" % (Time.get_ticks_msec() - t0))
	await _frames(2)
	ok(s.is_checked() and not bool(s.results[1]["passed"]) and no_big_numbers(s), "long answer: scored, not passed, readable numbers")
	ok(_press(s, "다음"), "press next (to the 3rd)")
	await _wait_ms(NEXT_WAIT_MSEC)
	# 이상한 서버 응답
	for bad in [OK({"sentences": "oops"}), OK({}), OK({"sentences": []}), OK({"sentences": [{"id": 1}, 5, {"text": "  "}]}), OK("x")]:
		_reset_state()
		routes["/practice/sentences"] = bad
		var s2 := _make_screen()
		s2.open("ja", {})
		for i in 120:
			if s2.stage != "loading":
				break
			await _frames(1)
		ok(s2.stage == "empty" and _has_text(s2, "문장이 없어요"), "odd response %s -> 'empty' screen, no crash" % str(bad["data"]).left(40))
	_reset_state()
	routes["/practice/sentences"] = ERR(503, "예문 데이터가 아직 준비되지 않았어요.")
	var s3 := _make_screen()
	s3.open("ja", {})
	for i in 120:
		if s3.stage != "loading":
			break
		await _frames(1)
	ok(s3.stage == "error" and _has_text(s3, "예문 데이터가 아직 준비되지 않았어요") and _button_with(s3, "다시 시도") != null, "503 -> error screen with a retry button")
	routes["/practice/sentences"] = func(_m: String, _p: String, _b: Variant) -> Dictionary: return OK(load_json(SENT_JA))
	ok(_press(s3, "다시 시도"), "press retry")
	for i in 120:
		if s3.stage == "run":
			break
		await _frames(1)
	ok(s3.stage == "run" and s3.sentences.size() == 6, "retry works")
	# 1.6.x PC 프로그램은 일본어 받아쓰기를 400 으로 거절한다: 업데이트 안내
	_reset_state()
	routes["/practice/sentences"] = ERR(400, "받아쓰기는 영어만 지원해요.")
	var s5 := _make_screen()
	s5.open("ja", {})
	for i in 120:
		if s5.stage != "loading":
			break
		await _frames(1)
	ok(s5.stage == "error" and _has_text(s5, "최신 버전으로 업데이트") and _button_with(s5, "다시 시도") != null, "an old PC program (400) -> 'update the PC program' + retry button")
	# 영어·일본어 밖의 언어는 그대로 안내
	var s4 := _make_screen()
	s4.open("fr", {})
	await _frames(2)
	ok(s4.stage == "unsupported", "an unknown language still shows the 'unsupported' screen")


# ---------------------------------------------------------------- 통과했지만 더 쓴 글자만 있는 경우

func _test_extra_letter_only() -> void:
	print("[ja dictation: passed with an extra letter only]")
	_reset_state()
	var raws: Array = (load_json(SENT_JA) as Dictionary)["sentences"]
	var d0: Dictionary = DictationDiffJa.diff(str(raws[0]["text"]) + "あ", str(raws[0]["text"]), str(raws[0]["reading"]))
	ok(bool(d0["passed"]) and str(d0["mode"]) == "wrong" and not (d0["extra"] as Array).is_empty(), "setup: a long sentence plus one extra letter passes with mode 'wrong' (%d)" % int(d0["score"]))
	var s := _make_screen()
	s.open("ja", {})
	for i in 120:
		if s.stage == "run":
			break
		await _frames(1)
	_type(s, str(raws[0]["text"]) + "あ")
	ok(_press(s, "확인"), "press check")
	await _frames(3)
	ok(bool(s.results[0]["passed"]) and _has_text(s, "철자가 조금 틀렸어요") and _has_text(s, "정답에 없는 글자"), "passed + 'slightly wrong' note + the extra letter is listed")
	ok(not _has_text(s, "아래 ✕ 칸") , "the note does not point at a ✕ cell that does not exist")


# ---------------------------------------------------------------- 영어는 그대로

func _test_english_unchanged() -> void:
	print("[english dictation unchanged]")
	_reset_state()
	Store.prefs["lang"] = "en"
	var s := _make_screen()
	s.open("en", {})
	for i in 120:
		if s.stage == "run":
			break
		await _frames(1)
	ok(s.stage == "run" and s.sentences.size() == 8 and "lang=en" in str(requests[0]["path"]) and "n=8" in str(requests[0]["path"]), "English: 8 sentences, lang=en")
	ok(_has_text(s, "들리는 대로 영어로 써 보세요") and _has_text(s, "단어 ") and not _has_text(s, "글자 수 "), "English: 'words' counter, no Japanese letter counter")
	var tx: String = str(s.sentences[0]["text"])
	_type(s, tx)
	ok(_press(s, "확인"), "English: press check")
	await _frames(2)
	ok(bool(s.results[0]["passed"]) and _has_text(s, "100점") and _has_text(s, "✓ "), "English: 100 points with ✓ word chips")
	ok(_press(s, "다음"), "English: press next")
	await _wait_ms(NEXT_WAIT_MSEC)
	await _frames(2)
	_type(s, "x")
	ok(_press(s, "확인"), "English: press check with a wrong word")
	await _frames(2)
	ok(_has_text(s, "빠짐") or _has_text(s, "철자 틀림"), "English: wrong word chip keeps its reason text")
	ok(Store.xp("en") == 3 and Store.xp("ja") == 0, "English XP goes to en only")
	Store.prefs["lang"] = "ja"


# ---------------------------------------------------------------- 레이아웃

func _test_layout() -> void:
	print("[layout: %s, scale %s, %s]" % ["phone 412x915" if phone else "pc 1280x800", Ds.font_scale, _scheme])
	_reset_state()
	var s := _make_screen()
	var screen: Vector2 = PHONE_SCREEN if phone else PC_SCREEN
	var bounds := Rect2(Vector2.ZERO, screen)
	s.open("ja", {})
	for i in 120:
		if s.stage == "run":
			break
		await _frames(1)
	await _frames(3)
	var page: PageScroll = s._shell["page"]
	var hbar := page.get_h_scroll_bar()
	ok(not hbar.visible or hbar.max_value - hbar.page < 1.0, "question: no horizontal scrolling")
	var all_in := true
	for b in _buttons(s):
		var btn: Button = b
		if btn.is_visible_in_tree() and not rect_inside(btn.get_global_rect(), bounds, 44.0):
			all_in = false
			print("    button out of bounds: '%s' %s" % [btn.text, str(btn.get_global_rect())])
	ok(all_in, "question: every button is inside the screen width and >= 44 high")
	ok(s._edit != null and s._edit.size.y >= 48.0 - 0.5 and rect_inside(s._edit.get_global_rect(), bounds, 48.0), "the input box is inside the screen and >= 48 high (%.1f)" % s._edit.size.y)
	# 긴 칩이 있는 결과(한자 틀림 + 가나 틀림)
	_type(s, "来てくださてありがとうございまし")
	_press(s, "확인")
	await _frames(4)
	ok(s.is_checked(), "layout: checked")
	hbar = page.get_h_scroll_bar()
	ok(not hbar.visible or hbar.max_value - hbar.page < 1.0, "result: no horizontal scrolling")
	var chips_in := true
	for l in _labels(page.content):
		var lbl: Label = l
		if lbl.is_visible_in_tree() and lbl.get_global_rect().end.x > screen.x + 0.5:
			chips_in = false
			print("    label out of the screen: '%s'" % lbl.text.left(30))
	ok(chips_in, "result: no label sticks out to the right")
	var btn_in := true
	for b in _buttons(s):
		var bb: Button = b
		if bb.is_visible_in_tree() and not rect_inside(bb.get_global_rect(), bounds, 44.0):
			btn_in = false
	ok(btn_in, "result: every button is inside the screen and >= 44 high")
	ok(no_big_numbers(s), "result: no 5+ digit number")
