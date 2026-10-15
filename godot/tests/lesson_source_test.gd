extends Node
## Headless test: lesson source selector, attribution line and Tatoeba links.
##   godot --headless --path <project> res://tests/lesson_source_test.tscn
## Exit code 0 = all checks passed. Uses tests/lesson_tatoeba_fixture.json; no backend needed.
## Restores the user's prefs at the end.

const FIXTURE := "res://tests/lesson_tatoeba_fixture.json"
const ATTRIBUTION := "예문 출처: Tatoeba (tatoeba.org) · CC BY 2.0 FR"

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
	print("== lesson source test start ==")
	var saved_prefs: Dictionary = Store.prefs.duplicate(true)
	await _run()
	Store.prefs = saved_prefs
	Store.save_prefs()
	print("== lesson source result: %d passed, %d failed ==" % [passed, failed])
	get_tree().quit(1 if failed > 0 else 0)


func _run() -> void:
	print("[fixture]")
	var f := FileAccess.open(FIXTURE, FileAccess.READ)
	ok(f != null, "fixture file opens")
	var data: Variant = JSON.parse_string(f.get_as_text()) if f != null else null
	ok(data is Dictionary and str((data as Dictionary).get("source", "")) == "tatoeba", "fixture has source = tatoeba")

	print("[selector and request body]")
	Store.prefs.erase("lesson_source")
	var lv := LessonView.new()
	add_child(lv)
	lv.size = Vector2(1100, 760)
	await get_tree().process_frame
	ok(lv.lesson_source() == "tatoeba", "selector defaults to tatoeba when the pref is missing")
	var body_default: Dictionary = LessonView.lesson_request_body("en", 1, 1, 1, lv.lesson_source())
	ok(body_default.get("source") == "tatoeba" and JSON.stringify(body_default).contains("\"source\":\"tatoeba\""), "request body carries source tatoeba by default")
	ok(_find_button(lv._page.content, "실제 예문 레슨 (빠름)") != null, "start screen shows the tatoeba option")
	var ai_btn: Button = _find_button(lv._page.content, "AI 레슨 (느림)")
	ok(ai_btn != null, "start screen shows the AI option")
	if ai_btn != null:
		ai_btn.pressed.emit()
	await get_tree().process_frame
	ok(lv.lesson_source() == "ai", "pressing the AI option switches the source")
	Store.load_prefs()
	ok(str(Store.prefs.get("lesson_source", "")) == "ai", "switch persists to prefs (reloaded from disk)")
	var body_ai: Dictionary = LessonView.lesson_request_body("en", 1, 1, 1, lv.lesson_source())
	ok(body_ai.get("source") == "ai" and JSON.stringify(body_ai).contains("\"source\":\"ai\""), "request body carries source ai after switching")
	ok(JSON.stringify(body_ai) != JSON.stringify(body_default), "switching to ai changes the request body")

	print("[response parsing]")
	ok(lv._apply_lesson_data(data), "fixture response is accepted (invalid exercise dropped, unknown fields ignored)")
	ok(lv.exercises.size() == 4, "4 valid exercises parsed (got %d)" % lv.exercises.size())
	ok(lv.attribution == ATTRIBUTION, "attribution stored from the response")
	ok(lv.title == "카페에서 주문하기", "title stored from the response")
	ok(LessonView.tatoeba_url(lv.exercises[0]) == "https://tatoeba.org/sentences/show/1234", "tatoeba_id 1234 -> sentence URL")
	ok(LessonView.tatoeba_url({"tatoeba_id": "5678"}) == "https://tatoeba.org/sentences/show/5678", "string tatoeba_id accepted")
	ok(LessonView.tatoeba_url({}) == "" and LessonView.tatoeba_url({"tatoeba_id": "abc"}) == "", "missing or non-numeric tatoeba_id gives no URL")
	var no_attr: Dictionary = (data as Dictionary).duplicate(true)
	no_attr.erase("attribution")
	ok(lv._apply_lesson_data(no_attr) and lv.attribution == "", "response without attribution clears it")
	lv._apply_lesson_data(data)

	print("[exercise panel]")
	for i in lv.exercises.size():
		lv.idx = i
		lv._reset_answer()
		lv._render()
		await get_tree().process_frame
		var lbl: Label = _find_label(lv._page.content, ATTRIBUTION)
		ok(lbl != null, "attribution label shown on exercise %d" % (i + 1))
		if lbl == null:
			continue
		var url: String = LessonView.tatoeba_url(lv.exercises[i])
		if url != "":
			ok(lbl.mouse_filter == Control.MOUSE_FILTER_STOP and lbl.mouse_default_cursor_shape == Control.CURSOR_POINTING_HAND and lbl.tooltip_text == url, "exercise %d: attribution links to %s" % [i + 1, url])
		else:
			ok(lbl.mouse_filter != Control.MOUSE_FILTER_STOP, "exercise %d without tatoeba_id: attribution is plain text" % (i + 1))

	print("[end screen]")
	lv.idx = 0
	lv.status = "done"
	lv._render()
	await get_tree().process_frame
	ok(_find_label(lv._page.content, ATTRIBUTION) != null, "attribution shown on the lesson end screen")

	print("[loading text]")
	lv.status = "loading"
	lv._req_source = "tatoeba"
	lv._render()
	await get_tree().process_frame
	ok(lv._loading_label != null and lv._loading_label.text == "레슨을 만드는 중…", "tatoeba loading text")
	lv._req_source = "ai"
	lv._render()
	await get_tree().process_frame
	ok(lv._loading_label != null and lv._loading_label.text.begins_with("문제 10개"), "ai loading keeps the longer text")

	lv.queue_free()
	await get_tree().process_frame


func _find_label(node: Node, text: String) -> Label:
	for c in node.get_children():
		if c is Label and (c as Label).text == text:
			return c as Label
		var found: Label = _find_label(c, text)
		if found != null:
			return found
	return null


func _find_button(node: Node, text: String) -> Button:
	for c in node.get_children():
		if c is Button and (c as Button).text == text:
			return c as Button
		var found: Button = _find_button(c, text)
		if found != null:
			return found
	return null
