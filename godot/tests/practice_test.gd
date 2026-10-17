extends Node
## 연습 허브 · 쉐도잉 · 받아쓰기 · 약한 소리 화면 시험 (서버 없이 가짜 응답으로).
##   godot --headless --path <project> res://tests/practice_test.tscn
##   라이브(선택): ... res://tests/practice_test.tscn -- --api=http://127.0.0.1:8813
## 종료 코드 0 = 전부 통과. 마지막 줄: "== practice result: N passed, 0 failed =="
## 진행 파일 · 학습 기록 · 설정은 시험 전용 경로로 바꿨다가 끝에 되돌린다. --api 가 없으면 서버 주소를 닫힌 포트로 돌려 8770 에 닿지 않게 한다.

const SENT_EN := "res://tests/sample_practice_sentences_en.json"
const SENT_JA := "res://tests/sample_practice_sentences_ja.json"
const PH_LIST := "res://tests/sample_phoneme_list.json"
const PH_TH := "res://tests/sample_phoneme_th.json"
const SCORE_PH := "res://tests/sample_score_en_ph.json"
const PROSODY := "res://tests/sample_prosody_en_before.json"
const FAKE_REC := {"b64": "AAAA", "duration": 1.2, "ok": true, "silent": false}
const TEST_PROGRESS := "user://t3_test_progress.json"
const TEST_LOG := "user://t3_test_studylog.json"

class Gate:
	extends RefCounted
	signal opened

var passed: int = 0
var failed: int = 0
var requests: Array = [] ## [{method, path, body}]
var routes: Dictionary = {} ## 경로 앞부분 -> 결과 Dictionary 또는 Callable(method, path, body)
var tts_calls: Array = []
var score_calls: Array = []
var live_api: String = ""

var _saved_prefs: Dictionary = {}
var _saved_progress: Dictionary = {}
var _saved_progress_path: String = ""
var _saved_log_path: String = ""
var _saved_base: String = ""


func ok(cond: bool, name: String) -> void:
	if cond:
		passed += 1
		print("  PASS  ", name)
	else:
		failed += 1
		print("  FAIL  ", name)


func _ready() -> void:
	print("== practice test start ==")
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--api="):
			live_api = a.substr(6)
	_setup()
	await _run()
	_teardown()
	print("== practice result: %d passed, %d failed ==" % [passed, failed])
	get_tree().quit(1 if failed > 0 else 0)


# ---------------------------------------------------------------- setup / helpers

func _setup() -> void:
	_saved_prefs = Store.prefs.duplicate(true)
	_saved_progress = Store.progress.duplicate(true)
	_saved_progress_path = Store.progress_path
	_saved_log_path = StudyLog.path
	_saved_base = Api.base_url
	Store.progress_path = TEST_PROGRESS
	Store.progress = Progress.blank()
	StudyLog.path = TEST_LOG
	StudyLog.load_from_disk()
	StudyLog.reset()
	Store.prefs["lang"] = "en"
	Store.prefs.erase("shadow_auto_rec")
	Store.prefs.erase("hide_prosody")
	if live_api == "":
		Api.base_url = "http://127.0.0.1:9" # 닫힌 포트: 실수로 8770 서버에 닿지 않게
	SpeakDrill.api_hook = Callable(self, "_hook")
	SpeakDrill.score_hook = Callable(self, "_on_score_hook")
	Tts.fetch_hook = Callable(self, "_tts_hook")


func _teardown() -> void:
	SpeakDrill.api_hook = Callable()
	SpeakDrill.score_hook = Callable()
	PhonemeScreen.weak_provider = Callable()
	Tts.fetch_hook = Callable()
	Tts.stop()
	StudyLog.reset()
	StudyLog.path = _saved_log_path
	Store.progress_path = _saved_progress_path
	Store.progress = _saved_progress
	Api.base_url = _saved_base
	for f in [TEST_PROGRESS, TEST_LOG, TEST_LOG + ".bad"]:
		if FileAccess.file_exists(f):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(f))
	Store.prefs = _saved_prefs
	Store.save_prefs()


func _hook(method: String, path: String, body: Variant) -> Variant:
	requests.append({"method": method, "path": path, "body": body})
	var keys: Array = routes.keys()
	keys.sort_custom(func(a: String, b: String) -> bool: return a.length() > b.length())
	for k in keys:
		if path.begins_with(str(k)):
			var r: Variant = routes[k]
			if r is Callable:
				return await (r as Callable).call(method, path, body)
			return r
	return ERR(404, "알 수 없는 경로예요.")


func _on_score_hook(l: String, res: Dictionary, src: String, _counted: bool) -> void:
	score_calls.append({"lang": l, "score": res.get("score", 0), "source": src})


func _tts_hook(text: String, l: String, speed: float, _voice: String) -> Variant:
	tts_calls.append({"text": text, "lang": l, "speed": speed})
	return null


func OK(data: Variant) -> Dictionary:
	return {"ok": true, "code": 200, "data": data, "error": ""}


func ERR(code: int, msg: String) -> Dictionary:
	return {"ok": false, "code": code, "data": null, "error": msg}


func load_json(path: String) -> Variant:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return null
	return JSON.parse_string(f.get_as_text())


func score_fixture(score: int, theta_ok: bool = false) -> Dictionary:
	var d: Dictionary = (load_json(SCORE_PH) as Dictionary).duplicate(true)
	d["score"] = score
	for u in d["units"]:
		for p in u["ph"]:
			if p["p"] == "θ":
				p["ok"] = theta_ok
				p["heard"] = null if theta_ok else "s"
	return d


func reqs(prefix: String) -> Array:
	var out: Array = []
	for r in requests:
		if str((r as Dictionary)["path"]).begins_with(prefix):
			out.append(r)
	return out


func wait_until(cond: Callable, max_frames: int = 180) -> bool:
	for i in max_frames:
		if cond.call():
			return true
		await get_tree().process_frame
	return bool(cond.call())


## 실제 서버를 기다릴 때: 프레임 수가 아니라 초 단위로.
func wait_secs(cond: Callable, secs: float) -> bool:
	var t0: int = Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < int(secs * 1000.0):
		if cond.call():
			return true
		await get_tree().process_frame
	return bool(cond.call())


func frames(n: int = 3) -> void:
	for i in n:
		await get_tree().process_frame


## 크기가 정해진 틀 안에 노드를 올린다.
func host(node: Control, sz: Vector2) -> Control:
	var h := Control.new()
	h.custom_minimum_size = sz
	h.size = sz
	add_child(h)
	h.add_child(node)
	node.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	return h


func free_host(h: Control) -> void:
	h.queue_free()
	await frames(2)


func find_buttons(node: Node, out: Array) -> void:
	for c in node.get_children():
		if c is Button:
			out.append(c)
		find_buttons(c, out)


func find_text(node: Node, needle: String) -> bool:
	for c in node.get_children():
		if (c is Label and needle in (c as Label).text) or (c is Button and needle in (c as Button).text) or (c is RichTextLabel and needle in (c as RichTextLabel).text):
			return true
		if find_text(c, needle):
			return true
	return false


func button_with(node: Node, needle: String) -> Button:
	var all: Array = []
	find_buttons(node, all)
	for b in all:
		if needle in (b as Button).text:
			return b
	return null


## L1(최소 폭) · L2(버튼 높이 44) 검사. 문제가 있으면 이름을 출력한다.
func layout_ok(root: Control, width: float, name: String) -> bool:
	await frames(3)
	var good := true
	var min_w: float = root.get_combined_minimum_size().x
	if width <= 412.0 and min_w > width + 0.5:
		print("    L1 minimum width ", min_w, " > ", width, " in ", name)
		good = false
	var all: Array = []
	find_buttons(root, all)
	var small := 0
	for b in all:
		var btn: Button = b
		if btn.is_visible_in_tree() and btn.size.y < 43.5 and not btn.has_meta("touch_exempt"):
			small += 1
			print("    L2 small button '", btn.text, "' h=", btn.size.y, " in ", name)
	if small > 0:
		good = false
	return good


# ---------------------------------------------------------------- run

func _run() -> void:
	await _test_hub()
	await _test_shadow_flow()
	await _test_span()
	await _test_phoneme()
	await _test_dictation()
	await _test_bad_inputs()
	await _test_on_hide()
	await _test_layout()
	await _test_live()


func _fresh() -> void:
	Store.progress = Progress.blank()
	StudyLog.reset()
	requests.clear()
	score_calls.clear()
	tts_calls.clear()
	routes.clear()
	for k in ShadowScreen.seen_ids.keys():
		ShadowScreen.seen_ids[k] = []
	DictationScreen.seen_ids = []


func _std_routes() -> void:
	routes = {
		"/practice/ping": OK({"ok": true, "practice": 1, "missions": 1, "tatoeba": true}),
		"/practice/sentences": func(_m: String, p: String, _b: Variant) -> Dictionary:
			return OK(load_json(SENT_JA if "lang=ja" in p else SENT_EN)),
		"/practice/phonemes": OK(load_json(PH_LIST)),
		"/practice/phoneme": OK(load_json(PH_TH)),
		"/score": OK(score_fixture(100)),
		"/prosody": OK(load_json(PROSODY)),
	}


# ---------------------------------------------------------------- T3-2 hub

func _test_hub() -> void:
	print("[hub]")
	_fresh()
	_std_routes()
	for sz in [Vector2(412, 915), Vector2(1280, 800)]:
		var v := PracticeView.new()
		var h := host(v, sz)
		v.refresh()
		await frames(3)
		ok(v.card_kinds().size() == 4 and v.card_kinds().has("mission") and v.card_kinds().has("shadow") and v.card_kinds().has("dictation") and v.card_kinds().has("phoneme"), "%s: 4 cards" % str(sz))
		ok(v._grid.columns == (1 if sz.x < 700 else 2), "%s: grid columns follow the width (%d)" % [str(sz), v._grid.columns])
		ok(await layout_ok(v, sz.x, "hub " + str(sz)), "%s: layout rules L1/L2" % str(sz))
		await free_host(h)

	var v2 := PracticeView.new()
	var h2 := host(v2, Vector2(412, 915))
	v2.refresh()
	await frames(2)
	var want := {"mission": "MissionScreen", "shadow": "ShadowScreen", "dictation": "DictationScreen", "phoneme": "PhonemeScreen"}
	for kind in want.keys():
		PracticeView.pending = {"kind": kind}
		v2.refresh()
		await frames(3)
		var s: Control = v2.current_screen()
		ok(s != null and s.get_script() != null and str(s.get_script().get_global_name()) == want[kind], "pending kind '%s' opens %s" % [kind, want[kind]])
		ok(PracticeView.pending.is_empty(), "pending is consumed (%s)" % kind)
		var went_back: bool = v2.go_back()
		await frames(2)
		ok(went_back and v2.current_screen() == null, "go_back() closes the sub screen (%s)" % kind)
	ok(v2.go_back() == false, "go_back() on the hub itself returns false")
	# 하위 화면이 열려 있는 동안 pending 이 생기면 refresh() 가 그것을 소비하고 해당 화면으로 바꾼다.
	v2.open_screen("shadow")
	await frames(2)
	var old_screen: Control = v2.current_screen()
	v2.refresh()
	await frames(2)
	ok(v2.current_screen() == old_screen and old_screen != null, "refresh() with an open sub screen and no pending leaves that screen alone")
	PracticeView.pending = {"kind": "dictation"}
	v2.refresh()
	await frames(3)
	var s2: Control = v2.current_screen()
	ok(PracticeView.pending.is_empty(), "pending is consumed even while a sub screen is open")
	ok(s2 != null and s2 != old_screen and str(s2.get_script().get_global_name()) == "DictationScreen", "open shadow screen is replaced by the pending dictation screen")
	ok(not is_instance_valid(old_screen) or old_screen.is_queued_for_deletion() or old_screen.get_parent() == null, "the replaced screen is closed (not left behind)")
	v2.refresh()
	await frames(2)
	ok(v2.current_screen() == s2, "a second refresh() does not reopen or change the screen")
	ok(v2.go_back() and v2.current_screen() == null, "after the replacement go_back() returns to the hub")
	v2.open_screen("mission")
	await frames(2)
	PracticeView.pending = {"kind": "no_such_screen"}
	v2.refresh()
	await frames(2)
	ok(PracticeView.pending.is_empty() and v2.current_screen() == null, "unknown pending kind closes the open screen and shows the hub")
	PracticeView.pending = {"kind": "phoneme", "p": "θ"}
	v2.refresh()
	await wait_until(func() -> bool: return v2.current_screen() != null and (v2.current_screen() as PhonemeScreen).stage == "detail")
	ok(v2.current_screen() != null and (v2.current_screen() as PhonemeScreen).cur_p == "θ" and (v2.current_screen() as PhonemeScreen).stage == "detail", "pending phoneme with p opens the explanation of that sound")
	while v2.go_back():
		await frames(2)
	ok(v2.current_screen() == null, "repeated go_back() steps out of the explanation, the list, then the hub")

	print("[hub: japanese, weak chips, old server]")
	Store.prefs["lang"] = "ja"
	v2.refresh()
	await frames(3)
	ok((v2._cards["dictation"] as Button).disabled and (v2._cards["phoneme"] as Button).disabled and not (v2._cards["shadow"] as Button).disabled, "ja: dictation and weak sounds are disabled, shadowing is not")
	Store.prefs["lang"] = "en"
	PhonemeScreen.weak_provider = func(_l: String, _n: int) -> Array: return [{"p": "θ", "n": 10, "bad": 6, "rate": 0.6, "heard": {"s": 5}}, {"p": "ɹ", "n": 8, "bad": 3, "rate": 0.375, "heard": {}}]
	v2.refresh()
	await frames(3)
	ok(v2._weak_buttons.size() == 2 and "60%" in (v2._weak_buttons[0] as Button).text and "38%" in (v2._weak_buttons[1] as Button).text, "weak sounds show as chips with the wrong-rate percentage")
	(v2._weak_buttons[0] as Button).pressed.emit()
	await wait_until(func() -> bool: return v2.current_screen() != null and (v2.current_screen() as PhonemeScreen).stage == "detail")
	ok(v2.current_screen() != null and (v2.current_screen() as PhonemeScreen).cur_p == "θ", "tapping a weak chip opens that sound")
	while v2.go_back():
		await frames(2)
	PhonemeScreen.weak_provider = func(_l: String, _n: int) -> Array: return []
	v2.refresh()
	await frames(2)
	ok(v2._weak_buttons.is_empty() and find_text(v2, "아직 약한 소리를 찾지 못했어요"), "no weak data -> guidance text, no chips")
	routes["/practice/ping"] = ERR(404, "")
	v2.old_server = false
	v2.refresh()
	await frames(4)
	ok(v2.old_server and find_text(v2, "최신 버전으로 업데이트"), "ping 404 -> 'update the PC program' notice")
	routes["/practice/ping"] = OK({"ok": true, "practice": 1})
	v2.refresh()
	await frames(4)
	ok(not v2.old_server, "ping ok clears the notice")
	await free_host(h2)
	PhonemeScreen.weak_provider = Callable()


# ---------------------------------------------------------------- T3-3 shadowing flow

func _test_shadow_flow() -> void:
	print("[shadowing session from fixtures]")
	_fresh()
	_std_routes()
	var sc := ShadowScreen.new()
	var h := host(sc, Vector2(412, 915))
	sc.open("en", {"source": "week"})
	var got: bool = await wait_until(func() -> bool: return sc.stage == "run")
	ok(got and sc.sentences.size() == 8, "8 sentences loaded and shown (%d)" % sc.sentences.size())
	var rq: Array = reqs("/practice/sentences")
	ok(rq.size() == 1 and "mode=shadow" in str(rq[0]["path"]) and "lang=en" in str(rq[0]["path"]) and "n=8" in str(rq[0]["path"]), "request carries lang, mode=shadow and n=8")
	ok(sc.attribution.begins_with("예문 출처: Tatoeba") and sc.drill != null, "attribution kept, drill created")
	var xp0: int = Store.xp("en")
	var passed_flags: Array = []
	for i in 8:
		var sc_val: int = 100 if i < 5 else 40
		routes["/score"] = OK(score_fixture(sc_val))
		sc.drill._on_recorded(FAKE_REC)
		var done: bool = await wait_until(func() -> bool: return sc.drill.status == "ok" and int((sc.results[i] as Dictionary)["tries"]) == 1)
		passed_flags.append(bool((sc.results[i] as Dictionary)["passed"]))
		if i == 0:
			ok(done and bool((sc.results[0] as Dictionary)["passed"]), "score 100 -> sentence passed")
			ok(Store.xp("en") == xp0 + 3, "first pass gives +3 XP (%d)" % (Store.xp("en") - xp0))
			ok(score_calls.size() == 1 and score_calls[0]["source"] == "shadow" and score_calls[0]["lang"] == "en", "StudyLog.add_score called once with source 'shadow'")
			ok(not sc.drill.prosody.is_empty(), "prosody response applied")
			var body: Dictionary = reqs("/score")[0]["body"]
			ok(body["target"] == str(sc.sentences[0]["text"]) and body["lang"] == "en" and body["audio_b64"] == "AAAA", "/score body = lang, whole sentence as target, audio")
		if i == 4:
			ok(Store.did_day(Plan.today_days(), "en"), "5th attempted sentence marks today as studied")
		if i < 7:
			sc.next_sentence()
			await frames(2)
	ok(passed_flags == [true, true, true, true, true, false, false, false], "pass flags %s" % str(passed_flags))
	ok(Store.xp("en") == xp0 + 15, "5 passes -> +15 XP (%d)" % (Store.xp("en") - xp0))
	sc.next_sentence() # 마지막 문장에서 -> 요약
	await frames(2)
	ok(sc.stage == "summary", "after the last sentence the summary is shown")
	var sm: Dictionary = ShadowScreen.summarize(sc.results)
	ok(int(sm["tried"]) == 8 and int(sm["passed"]) == 5 and int(sm["avg"]) == 78 and str(sm["worst"].get("p", "")) == "θ", "summary: 8 tried, 5 passed, avg 78, worst sound θ (%s)" % str(sm))
	var cards: Array = Store.review_for("en")
	var notes_ok := true
	for c in cards:
		if not str(c["note"]).begins_with("쉐도잉 40점"):
			notes_ok = false
	ok(cards.size() == 3 and notes_ok and sc.added_cards == 3, "3 sentences under 70 became review cards with a note (%d)" % cards.size())
	ok(find_text(sc, "평균 78점"), "summary text shows the average")
	await free_host(h)

	print("[shadowing: review cap 5, XP cap 24]")
	_fresh()
	_std_routes()
	var s2 := ShadowScreen.new()
	var h2 := host(s2, Vector2(412, 915))
	s2.open("en", {"source": "week"})
	await wait_until(func() -> bool: return s2.stage == "run")
	routes["/score"] = OK(score_fixture(40))
	for i in 8:
		s2.drill._on_recorded(FAKE_REC)
		await wait_until(func() -> bool: return int((s2.results[i] as Dictionary)["tries"]) == 1)
		s2.next_sentence()
		await frames(1)
	ok(s2.stage == "summary" and Store.review_for("en").size() == 5 and s2.added_cards == 5, "8 failed sentences -> at most 5 review cards (%d)" % Store.review_for("en").size())
	await free_host(h2)
	_fresh()
	_std_routes()
	var s3 := ShadowScreen.new()
	var h3 := host(s3, Vector2(412, 915))
	s3.open("en", {"source": "week"})
	await wait_until(func() -> bool: return s3.stage == "run")
	var x0: int = Store.xp("en")
	for i in 8:
		s3.drill._on_recorded(FAKE_REC)
		await wait_until(func() -> bool: return int((s3.results[i] as Dictionary)["tries"]) == 1)
		s3.next_sentence()
		await frames(1)
	ok(Store.xp("en") - x0 == 24, "8 passes -> +24 XP (session cap): %d" % (Store.xp("en") - x0))
	await free_host(h3)

	print("[shadowing: review cards as source, double tap on next]")
	_fresh()
	_std_routes()
	Store.add_review([{"lang": "en", "target": "Where is the station?", "ko": "역이 어디예요?", "reading": ""}, {"lang": "en", "target": "I am hungry.", "ko": "배고파요."}])
	var s4 := ShadowScreen.new()
	var h4 := host(s4, Vector2(412, 915))
	s4.open("en", {"source": "review"})
	await frames(3)
	ok(s4.stage == "run" and s4.sentences.size() == 2 and reqs("/practice/sentences").is_empty(), "review source needs no server request, 2 cards -> 2 sentences")
	var nb: Button = s4._next_btn
	nb.pressed.emit()
	nb.pressed.emit()
	await frames(2)
	ok(s4.idx == 1, "double tap on 'next' advances once (idx %d)" % s4.idx)
	await free_host(h4)

	print("[shadowing: japanese]")
	_fresh()
	_std_routes()
	var sj := ShadowScreen.new()
	var hj := host(sj, Vector2(412, 915))
	sj.open("ja", {"source": "week"})
	await wait_until(func() -> bool: return sj.stage == "run")
	ok(sj.sentences.size() == 3 and sj.drill.lang == "ja" and not sj.drill.show_prosody and "lang=ja" in str(reqs("/practice/sentences")[0]["path"]), "ja session: 3 sentences, no prosody")
	routes["/score"] = OK(score_fixture(90))
	sj.drill._on_recorded(FAKE_REC)
	await wait_until(func() -> bool: return sj.drill.status == "ok")
	var jb: Dictionary = reqs("/score")[0]["body"]
	ok(jb["reading"] == "まいあさはしります。" and jb["lang"] == "ja" and reqs("/prosody").is_empty(), "ja /score carries the reading and no /prosody call is made")
	await free_host(hj)


# ---------------------------------------------------------------- T3-4 span

func _test_span() -> void:
	print("[span repeat]")
	var t1: Dictionary = ShadowScreen.span_after_tap(-1, -1, false, 3)
	ok(t1 == {"a": 3, "b": 3, "picking": true}, "first tap selects that single word")
	var t2: Dictionary = ShadowScreen.span_after_tap(3, 3, true, 1)
	ok(t2 == {"a": 1, "b": 3, "picking": false}, "second tap before the first -> sorted (1..3)")
	ok(ShadowScreen.span_after_tap(3, 3, true, 3) == {"a": -1, "b": -1, "picking": false}, "tapping the single selected chip again clears it")
	ok(ShadowScreen.span_after_tap(1, 3, false, 2) == {"a": 2, "b": 2, "picking": true}, "tap after a finished span starts a new selection")
	ok(ShadowScreen.span_text(ShadowScreen.words_of("I run every morning."), 1, 3) == "run every morning", "span text joins the words and drops edge punctuation")
	_fresh()
	_std_routes()
	var sc := ShadowScreen.new()
	var h := host(sc, Vector2(412, 915))
	sc.open("en", {"source": "week"})
	await wait_until(func() -> bool: return sc.stage == "run")
	ok(str(sc.current()["text"]) == "I run every morning.", "first fixture sentence")
	sc.tap_word(3)
	sc.tap_word(1)
	ok(sc.span_a == 1 and sc.span_b == 3 and sc.current_span_text() == "run every morning", "tap 'morning' then 'run' -> span run..morning (auto-sorted)")
	sc.clear_span()
	ok(not sc.has_span(), "clear removes the span")
	sc.tap_word(2)
	ok(sc.span_a == 2 and sc.span_b == 2 and sc.current_span_text() == "every", "single chip -> only that word")
	sc.tap_word(2)
	ok(not sc.has_span(), "tapping the same chip again clears it")
	sc.tap_word(1)
	sc.tap_word(2)
	sc.set_speak_span(true)
	await frames(2)
	ok(sc.speak_span and sc.drill.score_target == "run every", "'speak span' sets the /score target to the span text")
	var xp0: int = Store.xp("en")
	sc.drill._on_recorded(FAKE_REC)
	await wait_until(func() -> bool: return sc.drill.status == "ok")
	var body: Dictionary = reqs("/score")[0]["body"]
	ok(body["target"] == "run every" and body["reading"] == "", "/score target is the span text")
	var r0: Dictionary = sc.results[0]
	ok(int(r0["tries"]) == 0 and int(r0["span_tries"]) == 1 and Store.xp("en") == xp0, "a span attempt does not count as a sentence pass")
	sc.set_speak_span(false)
	ok(sc.drill.score_target == str(sc.current()["text"]), "back to scoring the whole sentence")
	sc.tap_word(1)
	sc.tap_word(2)
	var listen_btn: Button = button_with(sc, "구간 듣기")
	ok(listen_btn != null, "span row shows the span listen button")
	if listen_btn != null:
		tts_calls.clear()
		listen_btn.pressed.emit()
		await frames(3)
		ok(tts_calls.size() == 1 and tts_calls[0]["text"] == "run every", "span listen speaks only the span")
	await free_host(h)


# ---------------------------------------------------------------- T3-5 weak sounds

func _test_phoneme() -> void:
	print("[phoneme judge]")
	requests.clear()
	var res: Dictionary = load_json(SCORE_PH)
	var j: Dictionary = PhonemeScreen.judge(res, "θ")
	ok(int(j["found"]) == 1 and int(j["good"]) == 0 and not bool(j["success"]) and not bool(j["unavailable"]) and str(j["words"][0]["heard"]) == "s", "θ in 'thank' was heard as s -> not a success")
	j = PhonemeScreen.judge(res, "ɹ")
	ok(bool(j["success"]) and int(j["good"]) == 1, "ɹ in 'very' fine -> success")
	j = PhonemeScreen.judge(res, "zzz")
	ok(int(j["found"]) == 0 and not bool(j["success"]) and not bool(j["unavailable"]), "sound not in the sentence -> not found, not success")
	j = PhonemeScreen.judge({"units": [{"t": "think", "ok": true}]}, "θ")
	ok(bool(j["unavailable"]) and not bool(j["success"]), "no ph in the response -> unavailable")
	j = PhonemeScreen.judge({}, "θ")
	ok(bool(j["unavailable"]), "empty response -> unavailable, no error")
	ok(PhonemeScreen.rate_pct({"rate": 0.58}) == 58 and PhonemeScreen.rate_pct({"rate": 58}) == 58 and PhonemeScreen.rate_pct({}) == 0, "rate_pct accepts 0..1 and 0..100")

	print("[phoneme screen with weak data]")
	_fresh()
	_std_routes()
	PhonemeScreen.weak_provider = func(_l: String, _n: int) -> Array: return [{"p": "θ", "n": 10, "bad": 6, "rate": 0.6, "heard": {}}, {"p": "qq", "n": 9, "bad": 5, "rate": 0.5, "heard": {}}]
	var ps := PhonemeScreen.new()
	var h := host(ps, Vector2(412, 915))
	ps.open("en", {})
	await wait_until(func() -> bool: return ps.stage == "list")
	ok(ps.stage == "list" and ps.phonemes.size() == 15, "sound list loaded (%d)" % ps.phonemes.size())
	ok(ps.weak.size() == 1 and str(ps.weak[0]["p"]) == "θ", "weak chips: only sounds that have a drill are kept")
	ok(find_text(ps, "틀림 60%"), "chip shows the wrong rate")
	PhonemeScreen.weak_provider = func(_l: String, _n: int) -> Array: return []
	ps.open("en", {})
	await wait_until(func() -> bool: return ps.stage == "list")
	ok(ps.weak.is_empty() and find_text(ps, "아직 약한 소리를 찾지 못했어요") and button_with(ps, "r (ɹ)") != null, "no weak data -> guidance and the full list to pick from")

	print("[phoneme drill]")
	ps.choose("θ")
	await wait_until(func() -> bool: return ps.stage == "detail")
	ok(ps.stage == "detail" and "p=%CE%B8" in str(reqs("/practice/phoneme?")[0]["path"]) and "sentences=3" in str(reqs("/practice/phoneme?")[0]["path"]), "detail request carries the encoded sound and sentences=3")
	ok(ps.items.size() == 5 and str(ps.items[0]["kind"]) == "phrase" and str(ps.items[4]["kind"]) == "sentence", "5 drill items: 2 phrases + 3 example sentences")
	ps.start_drill()
	await frames(2)
	ok(ps.stage == "drill" and ps.drill != null, "drill started")
	var xp0: int = Store.xp("en")
	ps.drill._on_recorded(FAKE_REC)
	await wait_until(func() -> bool: return ps.drill.status == "ok")
	ok(int((ps.results[0] as Dictionary)["tries"]) == 1 and not bool((ps.results[0] as Dictionary)["success"]) and ps.success_count() == 0, "θ heard as s -> item not successful")
	ok(find_text(ps, "s로 들림") and score_calls.size() == 1 and score_calls[0]["source"] == "drill", "verdict text shows what was heard; score recorded with source 'drill'")
	routes["/score"] = OK(score_fixture(95, true))
	ps.drill._on_recorded(FAKE_REC)
	await wait_until(func() -> bool: return bool((ps.results[0] as Dictionary)["success"]))
	ok(ps.success_count() == 1 and find_text(ps, "성공"), "second try with θ ok -> success counted")
	ps.next_item()
	await frames(2)
	var no_ph: Dictionary = score_fixture(80)
	for u in no_ph["units"]:
		u.erase("ph")
	routes["/score"] = OK(no_ph)
	ps.drill._on_recorded(FAKE_REC)
	await wait_until(func() -> bool: return ps.drill.status == "ok")
	ok(bool((ps.results[1] as Dictionary)["unavailable"]) and not bool((ps.results[1] as Dictionary)["success"]) and find_text(ps, "음소 분석을 쓸 수 없어요"), "response without ph -> 'phoneme analysis unavailable' and practice goes on")
	for i in 3:
		ps.next_item()
		await frames(1)
	ok(ps.idx == 4, "walked to the last item")
	ps.next_item()
	await frames(2)
	ok(ps.stage == "summary" and Store.xp("en") == xp0 + 10, "summary reached, +10 XP for finishing")
	ok(find_text(ps, "1/5 성공"), "summary shows '1/5 성공'")
	ok(Store.did_day(Plan.today_days(), "en") == false, "fewer than 5 attempts -> today is not marked")
	await free_host(h)

	print("[phoneme: errors]")
	_fresh()
	_std_routes()
	routes["/practice/phoneme"] = ERR(404, "아직 연습 자료가 없는 소리예요.")
	var p2 := PhonemeScreen.new()
	var h2 := host(p2, Vector2(412, 915))
	p2.open("en", {"p": "zzz"})
	await wait_until(func() -> bool: return p2.stage == "error")
	ok(p2.stage == "error" and find_text(p2, "연습 자료가 없는"), "unknown sound -> Korean error, no crash")
	await free_host(h2)
	requests.clear()
	var p3 := PhonemeScreen.new()
	var h3 := host(p3, Vector2(412, 915))
	p3.open("ja", {})
	await frames(2)
	ok(p3.stage == "unsupported" and reqs("/practice/phonemes").is_empty(), "ja -> 'English only' notice without any request")
	await free_host(h3)
	PhonemeScreen.weak_provider = Callable()


# ---------------------------------------------------------------- dictation screen

func _test_dictation() -> void:
	print("[dictation screen]")
	_fresh()
	_std_routes()
	var ds := DictationScreen.new()
	var h := host(ds, Vector2(412, 915))
	ds.open("en", {})
	await wait_until(func() -> bool: return ds.stage == "run")
	ok(ds.stage == "run" and ds.sentences.size() == 8 and "mode=dictation" in str(reqs("/practice/sentences")[0]["path"]), "8 sentences requested with mode=dictation")
	ok(not find_text(ds, "I run every morning"), "the sentence text is not shown before checking")
	tts_calls.clear()
	ds.listen(false)
	ds.listen(true)
	await frames(3)
	ok(tts_calls.size() == 2 and tts_calls[0]["text"] == "I run every morning." and absf(float(tts_calls[1]["speed"]) - Tts.SLOW_SPEED) < 0.01 and int((ds.results[0] as Dictionary)["listens"]) == 2, "normal and slow listening, listen counter = 2")
	ok(ds.check(false) == false and not ds.is_checked(), "empty answer is ignored")
	ok(ds._check_btn != null and ds._check_btn.disabled, "check button disabled while empty")
	ds.set_typed("i run every morning")
	ok(not ds._check_btn.disabled, "check button enabled once text is typed")
	var xp0: int = Store.xp("en")
	var first: bool = ds.check(false)
	var second: bool = ds.check(false)
	ok(first and not second and ds.is_checked(), "check works once; a second press is ignored")
	ok(int((ds.results[0] as Dictionary)["score"]) == 100 and bool((ds.results[0] as Dictionary)["passed"]) and Store.xp("en") == xp0 + 3, "correct answer -> 100, passed, +3 XP")
	await frames(2)
	ok(find_text(ds, "I run every morning.") and find_text(ds, "100점"), "after checking the answer and score are shown")
	ds.next_sentence()
	await frames(2)
	ds.set_typed("x".repeat(500))
	ok(ds._typed.length() == 300, "typed text is cut at 300 characters")
	ds.set_typed("She likes")
	ds.check(false)
	var r1: Dictionary = ds.results[1]
	ok(int(r1["score"]) > 0 and int(r1["score"]) < 85 and not bool(r1["passed"]), "partial answer fails (score %d)" % int(r1["score"]))
	ds.next_sentence()
	await frames(2)
	ok(ds.check(true) and bool((ds.results[2] as Dictionary)["gave_up"]) and int((ds.results[2] as Dictionary)["score"]) == 0, "'I don't know' shows the answer with 0 points")
	for i in range(3, 8):
		ds.next_sentence()
		await frames(1)
		ds.set_typed("😀 안녕")
		ds.check(false)
	ok(Store.did_day(Plan.today_days(), "en"), "5 attempted sentences mark today as studied")
	ds.next_sentence()
	await frames(2)
	ok(ds.stage == "summary" and ds.added_cards == 5 and Store.review_for("en").size() == 5, "summary: 7 failed sentences -> at most 5 review cards")
	var any_note := true
	for c in Store.review_for("en"):
		if c["note"] != "받아쓰기":
			any_note = false
	ok(any_note, "review cards carry the note '받아쓰기'")
	await free_host(h)

	var dj := DictationScreen.new()
	var hj := host(dj, Vector2(412, 915))
	requests.clear()
	dj.open("ja", {})
	await frames(2)
	ok(dj.stage == "unsupported" and reqs("/practice/sentences").is_empty(), "ja -> English-only notice, no request")
	await free_host(hj)


# ---------------------------------------------------------------- T3-6 bad inputs

func _test_bad_inputs() -> void:
	print("[bad input: server errors and empty data]")
	_fresh()
	_std_routes()
	routes["/practice/sentences"] = ERR(503, "예문 데이터가 아직 준비되지 않았어요.")
	var sc := ShadowScreen.new()
	var h := host(sc, Vector2(412, 915))
	sc.open("en", {"source": "week"})
	await wait_until(func() -> bool: return sc.stage == "error")
	ok(sc.stage == "error" and find_text(sc, "예문 데이터가 아직 준비되지 않았어요") and button_with(sc, "다시 시도") != null, "503 -> Korean message and a retry button")
	routes["/practice/sentences"] = ERR(0, "AI 엔진에 연결하지 못했어요.")
	button_with(sc, "다시 시도").pressed.emit()
	await wait_until(func() -> bool: return sc.stage == "error" and reqs("/practice/sentences").size() == 2)
	ok(sc.stage == "error", "network error -> same error screen, app keeps running")
	routes["/practice/sentences"] = ERR(404, "")
	button_with(sc, "다시 시도").pressed.emit()
	await wait_until(func() -> bool: return reqs("/practice/sentences").size() == 3)
	await frames(2)
	ok(find_text(sc, "최신 버전으로 업데이트"), "404 -> 'update the PC program'")
	routes["/practice/sentences"] = OK({"sentences": []})
	button_with(sc, "다시 시도").pressed.emit()
	await wait_until(func() -> bool: return sc.stage == "empty")
	ok(sc.stage == "empty" and find_text(sc, "문장이 없어요"), "0 sentences -> empty state")
	routes["/practice/sentences"] = OK({"sentences": [{"id": 1}, 5, {"text": "  "}]})
	sc.start_session("week")
	await wait_until(func() -> bool: return sc.stage == "empty")
	ok(sc.stage == "empty", "malformed sentence entries are dropped -> empty state")
	routes["/practice/sentences"] = ERR(503, "x")
	var dc := DictationScreen.new()
	var hd := host(dc, Vector2(412, 915))
	dc.open("en", {})
	await wait_until(func() -> bool: return dc.stage == "error")
	ok(dc.stage == "error" and button_with(dc, "다시 시도") != null, "dictation: 503 -> retry button")
	await free_host(hd)
	await free_host(h)

	print("[bad input: silent / broken /score responses]")
	_fresh()
	_std_routes()
	var s2 := ShadowScreen.new()
	var h2 := host(s2, Vector2(412, 915))
	s2.open("en", {"source": "week"})
	await wait_until(func() -> bool: return s2.stage == "run")
	var bad_responses: Array = [{}, {"score": 55, "transcript": "hello"}, {"score": 0, "transcript": "", "units": []}, {"score": 70, "transcript": "hi", "units": "x"}]
	var names: Array = ["{}", "no units", "score 0 + empty transcript", "units not an array"]
	for i in bad_responses.size():
		routes["/score"] = OK(bad_responses[i])
		var xp0: int = Store.xp("en")
		score_calls.clear()
		s2.drill._on_recorded(FAKE_REC)
		await wait_until(func() -> bool: return s2.drill.status == "silent")
		ok(s2.drill.status == "silent" and find_text(s2.drill, "소리가 들리지 않았어요") and score_calls.is_empty() and Store.xp("en") == xp0 and int((s2.results[0] as Dictionary)["tries"]) == 0, "/score %s -> 'no sound' message, nothing counted" % names[i])
		s2.drill.status = "idle"
	routes["/score"] = ERR(502, "채점 서버가 응답하지 않아요.")
	s2.drill._on_recorded(FAKE_REC)
	await wait_until(func() -> bool: return s2.drill.status == "error")
	ok(s2.drill.status == "error" and find_text(s2.drill, "채점 서버가 응답하지 않아요") and button_with(s2.drill, "다시 채점") != null, "/score 502 -> Korean error and a re-score button")
	routes["/score"] = OK(score_fixture(88))
	button_with(s2.drill, "다시 채점").pressed.emit()
	await wait_until(func() -> bool: return s2.drill.status == "ok")
	ok(s2.drill.status == "ok" and reqs("/score").size() >= 6, "re-score re-sends the same recording")
	routes["/score"] = OK(score_fixture(88))
	s2.drill._on_recorded({"b64": "", "duration": 0.0})
	ok(s2.drill.status == "silent", "empty audio -> 'no sound' without any request")
	await free_host(h2)

	print("[bad input: screen freed / language switched while a request is in flight]")
	_fresh()
	_std_routes()
	var gate := Gate.new()
	routes["/score"] = func(_m: String, _p: String, _b: Variant) -> Dictionary:
		await gate.opened
		return OK(score_fixture(90))
	var s3 := ShadowScreen.new()
	var h3 := host(s3, Vector2(412, 915))
	s3.open("en", {"source": "week"})
	await wait_until(func() -> bool: return s3.stage == "run")
	var drill_ref: SpeakDrill = s3.drill
	s3.drill._on_recorded(FAKE_REC)
	await frames(2)
	ok(drill_ref.status == "scoring", "request in flight")
	await free_host(h3)
	gate.opened.emit()
	await frames(3)
	ok(not is_instance_valid(drill_ref) and score_calls.is_empty(), "screen freed during the request: late answer ignored, nothing counted")

	var gate2 := Gate.new()
	routes["/practice/sentences"] = func(_m: String, _p: String, _b: Variant) -> Dictionary:
		await gate2.opened
		return OK(load_json(SENT_EN))
	var s4 := ShadowScreen.new()
	var h4 := host(s4, Vector2(412, 915))
	s4.open("en", {"source": "week"})
	await frames(2)
	ok(s4.stage == "loading", "sentences request in flight")
	s4.change_lang("ja")
	await frames(1)
	gate2.opened.emit()
	await frames(4)
	ok(s4.stage == "start" and s4.lang == "ja" and s4.sentences.is_empty() and s4.drill == null, "language switched while loading: the old answer is dropped")
	await free_host(h4)

	var gate3 := Gate.new()
	routes["/score"] = func(_m: String, _p: String, _b: Variant) -> Dictionary:
		await gate3.opened
		return OK(score_fixture(90))
	routes["/practice/sentences"] = OK(load_json(SENT_EN))
	var s5 := ShadowScreen.new()
	var h5 := host(s5, Vector2(412, 915))
	s5.open("en", {"source": "week"})
	await wait_until(func() -> bool: return s5.stage == "run")
	s5.drill._on_recorded(FAKE_REC)
	await frames(2)
	s5.next_sentence()
	await frames(1)
	gate3.opened.emit()
	await frames(3)
	ok(int((s5.results[0] as Dictionary)["tries"]) == 0 and s5.drill.status == "idle" and score_calls.is_empty(), "moving to the next sentence while scoring: the old result is ignored")
	await free_host(h5)

	print("[bad input: language switch in the hub closes the open screen]")
	_fresh()
	_std_routes()
	var v := PracticeView.new()
	var hv := host(v, Vector2(412, 915))
	v.refresh()
	await frames(2)
	v.open_screen("shadow")
	await frames(2)
	ok(v.current_screen() != null, "shadow screen open from the hub")
	Store.prefs["lang"] = "ja"
	Store.prefs_changed.emit()
	await frames(2)
	ok(v.current_screen() == null and v.lang == "ja", "hub language changed -> screen closed, hub rebuilt in ja")
	Store.prefs["lang"] = "en"
	await free_host(hv)


# ---------------------------------------------------------------- T3-7 on_hide

func _test_on_hide() -> void:
	print("[on_hide cancels recording]")
	_fresh()
	_std_routes()
	var sc := ShadowScreen.new()
	var h := host(sc, Vector2(412, 915))
	sc.open("en", {"source": "week"})
	await wait_until(func() -> bool: return sc.stage == "run")
	var rec: RecorderWidget = sc.drill.recorder
	# 마이크를 열지 않고 "내 위젯이 녹음 중" 상태만 만든다 (Recorder 공개 변수)
	Recorder.recording = true
	Recorder.owner_id = rec.get_instance_id()
	ok(rec.is_mine_recording(), "recorder reports it is recording (simulated)")
	sc.on_hide()
	ok(not Recorder.recording and not rec.is_mine_recording(), "on_hide() cancels the recording (shadowing)")
	await free_host(h)

	var ps := PhonemeScreen.new()
	var h2 := host(ps, Vector2(412, 915))
	ps.open("en", {"p": "θ"})
	await wait_until(func() -> bool: return ps.stage == "detail")
	ps.start_drill()
	await frames(2)
	Recorder.recording = true
	Recorder.owner_id = ps.drill.recorder.get_instance_id()
	ps.on_hide()
	ok(not Recorder.recording, "on_hide() cancels the recording (weak sounds)")
	Recorder.recording = true
	Recorder.owner_id = ps.drill.recorder.get_instance_id()
	await free_host(h2)
	ok(not Recorder.recording, "screen removed while recording -> recording cancelled")
	Recorder.recording = false


# ---------------------------------------------------------------- layout L1/L2

func _test_layout() -> void:
	print("[layout 412x915 and 1280x800]")
	_fresh()
	_std_routes()
	PhonemeScreen.weak_provider = func(_l: String, _n: int) -> Array: return [{"p": "θ", "n": 10, "bad": 6, "rate": 0.6, "heard": {}}]
	for sz in [Vector2(412, 915), Vector2(1280, 800)]:
		var tag: String = str(sz)
		var sc := ShadowScreen.new()
		var h := host(sc, sz)
		sc.open("en", {})
		ok(await layout_ok(sc, sz.x, "shadow start " + tag), "%s shadow start screen" % tag)
		sc.start_session("week")
		await wait_until(func() -> bool: return sc.stage == "run")
		sc.tap_word(1)
		sc.tap_word(2)
		sc.set_speak_span(true)
		routes["/score"] = OK(score_fixture(75))
		sc.drill._on_recorded(FAKE_REC)
		await wait_until(func() -> bool: return sc.drill.status == "ok")
		ok(await layout_ok(sc, sz.x, "shadow run " + tag), "%s shadow run with span and result" % tag)
		for i in 7:
			sc.next_sentence()
		sc.next_sentence()
		await frames(2)
		ok(sc.stage == "summary" and await layout_ok(sc, sz.x, "shadow summary " + tag), "%s shadow summary" % tag)
		await free_host(h)

		var ds := DictationScreen.new()
		var hd := host(ds, sz)
		ds.open("en", {})
		await wait_until(func() -> bool: return ds.stage == "run")
		ds.toggle_hint()
		ok(await layout_ok(ds, sz.x, "dictation run " + tag), "%s dictation before checking" % tag)
		ds.set_typed("i run every mornin")
		ds.check(false)
		await frames(2)
		ok(await layout_ok(ds, sz.x, "dictation checked " + tag), "%s dictation after checking" % tag)
		await free_host(hd)

		var ps := PhonemeScreen.new()
		var hp := host(ps, sz)
		ps.open("en", {})
		await wait_until(func() -> bool: return ps.stage == "list")
		ok(await layout_ok(ps, sz.x, "phoneme list " + tag), "%s phoneme list" % tag)
		ps.choose("θ")
		await wait_until(func() -> bool: return ps.stage == "detail")
		ok(await layout_ok(ps, sz.x, "phoneme detail " + tag), "%s phoneme detail" % tag)
		ps.start_drill()
		await frames(2)
		routes["/score"] = OK(score_fixture(75))
		ps.drill._on_recorded(FAKE_REC)
		await wait_until(func() -> bool: return ps.drill.status == "ok")
		ok(await layout_ok(ps, sz.x, "phoneme drill " + tag), "%s phoneme drill with result" % tag)
		await free_host(hp)
	PhonemeScreen.weak_provider = Callable()

	print("[layout: resize keeps working]")
	var v := PracticeView.new()
	var hv := host(v, Vector2(412, 915))
	v.refresh()
	await frames(2)
	hv.size = Vector2(1280, 800)
	await frames(3)
	ok(v._grid.columns == 2, "hub grows to 2 columns when widened")
	hv.size = Vector2(412, 915)
	await frames(3)
	ok(v._grid.columns == 1, "and back to 1 column when narrowed")
	await free_host(hv)


# ---------------------------------------------------------------- T3-8 live

func _test_live() -> void:
	if live_api == "":
		print("[live] 라이브 건너뜀 (--api 없음)")
		return
	print("[live %s]" % live_api)
	SpeakDrill.api_hook = Callable()
	Tts.fetch_hook = Callable()
	requests.clear()
	var sc := ShadowScreen.new()
	var h := host(sc, Vector2(412, 915))
	sc.open("en", {"source": "week"})
	var got: bool = await wait_secs(func() -> bool: return sc.stage == "run" or sc.stage == "error" or sc.stage == "empty", 120.0)
	ok(got and sc.stage == "run" and sc.sentences.size() == 8, "live: 8 sentences from the real server (stage %s, %d)" % [sc.stage, sc.sentences.size()])
	if sc.stage == "run":
		var first: String = str(sc.sentences[0]["text"])
		var call: Api.ApiCall = Api.post_json("/tts", {"text": first, "lang": "en", "speed": 1.0, "voice": Tts.voice_for("en")}, 60.0, false)
		var res: Dictionary = await call.wait()
		ok(bool(res["ok"]) and int(res["code"]) == 200 and (res["bytes"] as PackedByteArray).size() > 1000, "live: /tts for the first sentence -> 200 with WAV bytes")
	await free_host(h)
	var ps := PhonemeScreen.new()
	var hp := host(ps, Vector2(412, 915))
	ps.open("en", {"p": "θ"})
	await wait_secs(func() -> bool: return ps.stage == "detail" or ps.stage == "error", 60.0)
	ok(ps.stage == "detail" and ps.items.size() >= 4, "live: weak-sound detail for θ (%d items)" % ps.items.size())
	await free_host(hp)
	SpeakDrill.api_hook = Callable(self, "_hook")
	Tts.fetch_hook = Callable(self, "_tts_hook")
