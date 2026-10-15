extends Node
## Headless walkthrough of FSRS-based review: due ordering, ratings, fake clock, session UI.
##   godot --headless --path <project> res://tests/review_walk_test.tscn
## Exit code 0 = all checks passed.

var passed: int = 0
var failed: int = 0


func _ready() -> void:
	print("== review walkthrough start ==")
	Store.progress_path = "user://test_review_walk.json"
	Store.progress = Progress.blank()
	Store.time_offset = 0
	_test_store_scheduling()
	await _test_view()
	DirAccess.remove_absolute(ProjectSettings.globalize_path("user://test_review_walk.json"))
	Store.time_offset = 0
	print("== review walkthrough result: %d passed, %d failed ==" % [passed, failed])
	get_tree().quit(1 if failed > 0 else 0)


func ok(cond: bool, name: String) -> void:
	if cond:
		passed += 1
		print("  PASS  ", name)
	else:
		failed += 1
		print("  FAIL  ", name)


func _item(target: String) -> Dictionary:
	for r in Store.progress["review"]:
		if r["target"] == target:
			return r
	return {}


func _targets(arr: Array) -> Array:
	var out: Array = []
	for r in arr:
		out.append(r["target"])
	return out


func _test_store_scheduling() -> void:
	print("[store scheduling]")
	var t0: int = Store.now()
	ok(Store.add_review([
		{"lang": "en", "target": "A", "ko": "에이"},
		{"lang": "en", "target": "B", "ko": "비"},
		{"lang": "en", "target": "C", "ko": "씨"},
		{"lang": "ja", "target": "D", "ko": "디"},
	]) == 4, "add 3 en + 1 ja items")
	var a: Dictionary = _item("A")
	ok(FSRS.is_new(a) and int(a["state"]) == 1 and int(a["due"]) <= Store.now() and int(a["reps"]) == 0, "new items are new cards due now")
	ok(Store.due_count("en") == 3 and Store.due_count("ja") == 1, "3 en + 1 ja due")
	# make the due order different from the insertion order: A newest, B oldest, C in the middle
	_item("A")["due"] = t0 - 100
	_item("B")["due"] = t0 - 300
	_item("C")["due"] = t0 - 200
	ok(_targets(Store.due_for("en")) == ["B", "C", "A"], "oldest due first: %s" % str(_targets(Store.due_for("en"))))
	ok(Store.due_for("en", 2).size() == 2, "limit respected")

	# rate: A Good, B Again, C Easy
	Store.rate_review(str(_item("A")["id"]), 3)
	Store.rate_review(str(_item("B")["id"]), 1)
	Store.rate_review(str(_item("C")["id"]), 4)
	var now: int = Store.now()
	ok(int(_item("A")["state"]) == 1 and int(_item("A")["step"]) == 1 and int(_item("A")["due"]) - now == 600, "A Good: still learning, next step in 10 minutes")
	ok(int(_item("B")["state"]) == 1 and int(_item("B")["step"]) == 0 and int(_item("B")["due"]) - now == 60, "B Again: back to step 0, due in 1 minute")
	ok(int(_item("C")["state"]) == 2 and int(_item("C")["due"]) - now >= FSRS.DAY, "C Easy: graduates to Review, due in >= 1 day (%s)" % FSRS.format_interval(int(_item("C")["due"]) - now))
	ok(Store.due_count("en") == 0 and Store.due_count("ja") == 1, "nothing due in en right after rating")
	ok(int(_item("A")["reps"]) == 1 and not FSRS.is_new(_item("A")), "reps counted")
	ok(Store.next_due("en") == int(_item("B")["due"]), "next_due = soonest (B)")
	ok(_targets(Store.upcoming_for("en")) == ["B", "A", "C"], "upcoming order B, A, C")

	# fake clock: +2 minutes -> only B is due
	Store.time_offset += 120
	ok(_targets(Store.due_for("en")) == ["B"], "after +2 min only B is due")
	# +11 more minutes -> B and A, B first (earlier due)
	Store.time_offset += 660
	ok(_targets(Store.due_for("en")) == ["B", "A"], "after +13 min B then A are due: %s" % str(_targets(Store.due_for("en"))))
	# A Good at last step -> Review; B Good -> next step
	Store.rate_review(str(_item("A")["id"]), 3)
	Store.rate_review(str(_item("B")["id"]), 3)
	ok(int(_item("A")["state"]) == 2 and int(_item("B")["state"]) == 1 and int(_item("B")["step"]) == 1, "A graduated, B on step 2")
	# just past C's due (its Easy interval is ~9 days, fuzzed to 7~11) -> C is due; lapse it
	Store.time_offset += int(_item("C")["due"]) - Store.now() + 60
	ok(_targets(Store.due_for("en")).has("C"), "just after C's due date, C is due")
	Store.rate_review(str(_item("C")["id"]), 1)
	ok(int(_item("C")["state"]) == 3 and int(_item("C")["lapses"]) == 1, "C lapse -> Relearning, lapses=1")
	# persistence
	Store.save_progress()
	var due_before: int = int(_item("C")["due"])
	Store.load_progress()
	ok(int(_item("C")["due"]) == due_before and int(_item("C")["state"]) == 3 and is_equal_approx(float(_item("C")["stability"]), float(_item("C")["stability"])) and float(_item("C")["stability"]) > 0.0, "FSRS fields survive save/load")
	Store.remove_review(str(_item("D")["id"]))
	ok(_item("D").is_empty(), "removing an item still works")


func _texts(node: Node, out: Array = []) -> Array:
	if node is Label:
		out.append((node as Label).text)
	elif node is Button:
		out.append((node as Button).text)
	for ch in node.get_children():
		_texts(ch, out)
	return out


func _buttons(node: Node, out: Array = []) -> Array:
	if node is Button:
		out.append(node)
	for ch in node.get_children():
		_buttons(ch, out)
	return out


func _has_text(node: Node, part: String) -> bool:
	for t in _texts(node):
		if str(t).contains(part):
			return true
	return false


func _test_view() -> void:
	print("[review view]")
	ok(ReviewView.rating_for_score(0) == 1 and ReviewView.rating_for_score(59.9) == 1 and ReviewView.rating_for_score(60) == 2 \
		and ReviewView.rating_for_score(79) == 2 and ReviewView.rating_for_score(80) == 3 and ReviewView.rating_for_score(94) == 3 \
		and ReviewView.rating_for_score(95) == 4 and ReviewView.rating_for_score(100) == 4, "score -> rating mapping")
	var now: int = Store.now()
	var day_start: int = now - (now + int(Time.get_time_zone_from_system().get("bias", 0)) * 60) % FSRS.DAY # local midnight
	ok(ReviewView.due_text(day_start + FSRS.DAY + 15 * 3600, day_start + 9 * 3600) == "내일 오후 3시", "due_text tomorrow 3 pm: " + ReviewView.due_text(day_start + FSRS.DAY + 15 * 3600, day_start + 9 * 3600))
	ok(ReviewView.due_text(day_start + 15 * 3600 + 20 * 60, day_start + 9 * 3600) == "오늘 오후 3시 20분", "due_text today 3:20 pm")
	ok(ReviewView.due_text(day_start + 2 * FSRS.DAY + 9 * 3600, day_start + 8 * 3600) == "모레 오전 9시", "due_text day after tomorrow")
	ok(ReviewView.due_text(day_start + 12 * 3600, day_start + 12 * 3600 - 600) == "10분 뒤", "due_text within the hour")

	# fresh en list: 25 new items + legacy items -> a session holds at most 20, oldest due first
	Store.progress = Progress.blank()
	Store.time_offset = 0
	var many: Array = []
	for i in 25:
		many.append({"lang": "en", "target": "Sentence %d" % i, "ko": "문장 %d" % i})
	Store.add_review(many)
	var t0: int = Store.now()
	for i in 25:
		_item("Sentence %d" % i)["due"] = t0 - 1000 + i # Sentence 0 is the oldest
	var rv := ReviewView.new()
	add_child(rv)
	await get_tree().process_frame
	rv.lang = "en"
	rv.status = "idle"
	rv._render()
	ok(_has_text(rv, "오늘 복습 20개 · 새 문장 20개") or _has_text(rv, "오늘 복습 25개 · 새 문장 20개"), "home shows '오늘 복습 N개 · 새 문장 M개'")
	rv._start()
	ok(rv.status == "run" and rv.items.size() == 20 and rv.items[0]["target"] == "Sentence 0" and rv.items[19]["target"] == "Sentence 19", "session: 20 oldest due items first")
	ok(_has_text(rv, "오늘 복습 20개 · 새 문장 20개"), "run view header")

	# answer by typing -> four rating buttons with intervals, 좋음/쉬움 preselected by score
	var it: Dictionary = rv.items[0]
	rv.typed_sim = TextSim.similarity("Sentence 0", str(it["target"]), "", "en")
	rv.checked = true
	rv._render()
	var rating_btns: Array = []
	for b in _buttons(rv):
		if (b as Button).text.contains("\n"):
			rating_btns.append(b)
	ok(rating_btns.size() == 4, "four rating buttons (found %d)" % rating_btns.size())
	if rating_btns.size() == 4:
		var labels: Array = []
		for b in rating_btns:
			labels.append((b as Button).text.replace("\n", " "))
		print("    ", labels)
		ok(labels[0] == "다시 1분" and labels[1] == "어려움 6분" and labels[2] == "좋음 10분" and labels[3].begins_with("쉬움 ") and labels[3].ends_with("일"), "labels carry the previewed intervals")
		# exact match -> score 100 -> 쉬움 highlighted (primary style = bold font override, white font)
		ok((rating_btns[3] as Button).get_theme_color("font_color") == Color.WHITE and (rating_btns[0] as Button).get_theme_color("font_color") != Color.WHITE, "score 100 pre-selects 쉬움")
		(rating_btns[2] as Button).pressed.emit() # user picks 좋음 instead
		ok(rv.idx == 1 and rv.done_count == 1 and not rv.checked, "advanced to next item after choosing a rating")
		ok(int(_item("Sentence 0")["state"]) == 1 and int(_item("Sentence 0")["step"]) == 1 and int(_item("Sentence 0")["due"]) - Store.now() > 500, "chosen rating (좋음) applied, not the suggestion")
	ok(Store.due_count("en") == 24, "rated item left the due list (24 due)")

	# remove from list
	var rm_target: String = str(rv.items[1]["target"])
	rv.checked = true
	rv.shown_only = true
	rv._render()
	var removed := false
	for b in _buttons(rv):
		if (b as Button).text == "목록에서 빼기":
			(b as Button).pressed.emit()
			removed = true
	ok(removed and _item(rm_target).is_empty() and rv.idx == 2, "'목록에서 빼기' removes the item and moves on")

	# finish: nothing due -> done message + practice mode keeps schedules untouched
	Store.time_offset = 0
	for r in Store.progress["review"]:
		r["due"] = Store.now() + 5 * FSRS.DAY # push everything into the future
	rv.status = "idle"
	rv._render()
	ok(_has_text(rv, "오늘 복습할 문장을 다 끝냈어요") and _has_text(rv, "다음 복습: "), "no due items -> finished message with next due time")
	ok(_has_text(rv, "미리 연습하기"), "practice button offered")
	var snapshot: String = JSON.stringify(Store.progress["review"])
	rv._start_practice()
	ok(rv.status == "run" and rv.practice and rv.items.size() == 20, "practice session started (20 items)")
	rv.typed_sim = TextSim.similarity("wrong", str(rv.items[0]["target"]), "", "en")
	rv.checked = true
	rv._render()
	var any_rating := false
	var next_btn: Button = null
	for b in _buttons(rv):
		if (b as Button).text.contains("\n"):
			any_rating = true
		if (b as Button).text == "다음 문장":
			next_btn = b
	ok(not any_rating and next_btn != null, "practice mode shows no rating buttons")
	if next_btn != null:
		next_btn.pressed.emit()
	ok(rv.idx == 1 and JSON.stringify(Store.progress["review"]) == snapshot, "practice leaves the schedule unchanged")
	rv.status = "idle"
	rv._render()

	# 5 days later everything is due again
	Store.time_offset += 5 * FSRS.DAY + 1
	ok(Store.due_count("en") == Store.review_for("en").size(), "after +5 days all items are due again")

	# today view button
	var tv := TodayView.new()
	add_child(tv)
	await get_tree().process_frame
	var found := ""
	for b in _buttons(tv):
		if (b as Button).text.begins_with("복습 "):
			found += (b as Button).text + "|"
	ok(found.contains("복습 %d개" % Store.due_count("en")), "today view shows due count: " + found)
	Store.progress["review"] = []
	tv.refresh()
	await get_tree().process_frame
	found = ""
	for b in _buttons(tv):
		if (b as Button).text.begins_with("복습 "):
			found += (b as Button).text
	ok(found == "", "today view hides the review button with 0 items")
