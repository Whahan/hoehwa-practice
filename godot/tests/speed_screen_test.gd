extends Node
## 60초 스피드 퀴즈 화면(SpeedScreen) 시험 (서버 없이, 가짜 시계).
##   PC   : godot --headless --path godot res://tests/speed_screen_test.tscn -- --api=http://127.0.0.1:9
##   폰   : godot --headless --path godot --resolution 412x915 res://tests/speed_screen_test.tscn -- --phone --api=http://127.0.0.1:9 [--font-scale=1.5] [--dark]
## 시작 화면(풀 모자람 / 충분 / 안내 한 줄) · 한 판 끝까지 · 새 기록 · 오답 처리 · 일시정지 · 그만두기 · 일본어 읽기 · 긴 뜻 · 레이아웃 ·
## 단어 파일이 없을 때 · 일부러 틀린 입력을 본다. 시험 전용 파일(user://test_fun_q2_*)만 쓴다.
## 마지막 줄: "== speed_screen: N passed, M failed =="  (실패가 있으면 종료 코드 1)
## 검사기도 일부러 틀린 입력에서 실제로 실패하는지 본다 (selfcheck FAIL-as-expected ...).

const TEST_PROGRESS := "user://test_fun_q2_progress.json"
const TEST_LOG := "user://test_fun_q2_studylog.json"
const TEST_BAD_WORDS := "user://test_fun_q2_bad_words.json"
const PHONE_SCREEN := Vector2(412, 915)
const PC_SCREEN := Vector2(1280, 800)

var passed: int = 0
var failed: int = 0
var phone: bool = false
var _scale: float = 1.0
var _dark: bool = false
var _t: int = 0                 ## 가짜 시계 (ms)
var _holder: Control = null
var _saved := {}
var _speed_events: int = 0
var _all_events: Array = []


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


func _clock() -> int:
	return _t


func _ready() -> void:
	phone = Platform.is_phone()
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--font-scale=") and a.substr(13).is_valid_float():
			_scale = a.substr(13).to_float()
		elif a == "--dark":
			_dark = true
	print("== speed_screen test start (%s, scale %s%s) ==" % ["phone" if phone else "pc", str(_scale), ", dark" if _dark else ""])
	_setup()
	await _frames(2)
	_selfchecks()
	await _test_start_screen()
	await _test_full_run()
	await _test_records()
	await _test_wrong()
	await _test_review_cards()
	await _test_pause()
	await _test_quit_sheet()
	await _test_japanese()
	await _test_long_text_layout()
	await _test_layout_sizes()
	await _test_words_file_missing()
	await _test_bad_input()
	_test_file_rules()
	_teardown()
	print("== speed_screen: %d passed, %d failed ==" % [passed, failed])
	get_tree().quit(1 if failed > 0 else 0)


# ---------------------------------------------------------------- setup

func _setup() -> void:
	_saved = {
		"progress_path": Store.progress_path,
		"progress": Store.progress.duplicate(true),
		"log_path": StudyLog.path,
		"prefs": Store.prefs.duplicate(true),
		"words_path": SpeedPool.words_path,
		"animate": Sheet.animate,
	}
	Store.progress_path = TEST_PROGRESS
	StudyLog.path = TEST_LOG
	Sheet.animate = false
	Store.activity.connect(_on_activity)
	var size := Vector2i(PHONE_SCREEN) if phone else Vector2i(PC_SCREEN)
	get_window().min_size = Vector2i.ZERO
	get_window().size = size
	UiBoot.apply(get_window(), "dark" if _dark else "light", _scale)
	if phone:
		PhoneLayout.install_touch_scroll(get_tree())
	_fresh()


func _teardown() -> void:
	Store.activity.disconnect(_on_activity)
	if _holder != null and is_instance_valid(_holder):
		_holder.queue_free()
	while Sheet.close_top():
		pass
	StudyLog.reset()
	for p in [TEST_LOG, TEST_LOG + ".tmp", TEST_LOG + ".bad", TEST_PROGRESS, TEST_PROGRESS + ".tmp", TEST_BAD_WORDS]:
		_rm(p)
	SpeedPool.words_path = _saved["words_path"]
	SpeedPool.clear_cache()
	StudyLog.path = _saved["log_path"]
	Store.progress_path = _saved["progress_path"]
	Store.progress = _saved["progress"]
	Store.prefs = _saved["prefs"]
	Sheet.animate = _saved["animate"]


func _on_activity(kind: String) -> void:
	_all_events.append(kind)
	if kind == "speed":
		_speed_events += 1


func _rm(path: String) -> void:
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


## 빈 복습 목록 · 빈 기록으로 되돌린다.
func _fresh() -> void:
	Store.progress = Progress.blank()
	_rm(TEST_LOG)
	StudyLog.load_from_disk()
	StudyLog.reset()
	_speed_events = 0
	_all_events = []
	_t = 0
	while Sheet.close_top():
		pass


# ---------------------------------------------------------------- fake data

## n 개의 가짜 단어. 뜻은 모두 서로 달라 보기가 겹치지 않는다. long_ko = 12자 뜻.
func _words(lang: String, n: int, verified: bool = true, long_ko: bool = false, first: int = 0) -> Array:
	var out: Array = []
	for k in n:
		var i: int = first + k
		var ko := ""
		if long_ko:
			for j in 12:
				ko += char(0xAC00 + i * 13 + j)
		else:
			ko = char(0xAC00 + i * 7) + char(0xB200 + i * 5)
		var w := ""
		var rd := ""
		if lang == "ja":
			w = char(0x4E00 + i * 3) + char(0x4E01 + i * 3)
			rd = char(0x3042 + i) + char(0x3043 + i)
		else:
			w = "alpha%02d" % i
		out.append({"w": w, "rd": rd, "ko": ko, "pos": "noun", "m": 1, "v": verified})
	return out


func _hook_for(words: Array) -> Callable:
	return func(_l: String) -> Dictionary: return {"ok": not words.is_empty(), "words": words, "err": "" if not words.is_empty() else "missing"}


## 복습 카드 n 장 (lang). 뜻은 단어와 겹치지 않게 별도 범위를 쓴다.
func _add_cards(lang: String, n: int) -> void:
	var items: Array = []
	for i in n:
		items.append({"lang": lang, "target": "card%02d" % i, "reading": "", "ko": char(0xC000 + i * 9) + char(0xC400 + i * 3), "note": "x"})
	Store.add_review(items)


func _make(lang: String, words: Array, with_hook: bool = true) -> SpeedScreen:
	if _holder != null and is_instance_valid(_holder):
		_holder.queue_free()
	_holder = Control.new()
	_holder.size = PHONE_SCREEN if phone else PC_SCREEN
	_holder.clip_contents = true
	add_child(_holder)
	var s := SpeedScreen.new()
	s.clock = Callable(self, "_clock")
	if with_hook:
		s.words_hook = _hook_for(words)
	_holder.add_child(s)
	s.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_t = 0
	s.open(lang)
	return s


func _page_labels(s: SpeedScreen) -> Array:
	var out: Array = []
	_collect_text(s, out)
	return out


func _collect_text(n: Node, out: Array) -> void:
	for c in n.get_children():
		if c is Label:
			out.append((c as Label).text)
		elif c is Button:
			out.append((c as Button).text)
		_collect_text(c, out)


func _has_text(s: SpeedScreen, needle: String) -> bool:
	for t in _page_labels(s):
		if str(t).contains(needle):
			return true
	return false


func _find_button(n: Node, text: String) -> Button:
	for c in n.get_children():
		if c is Button and (c as Button).text.contains(text):
			return c
		var r := _find_button(c, text)
		if r != null:
			return r
	return null


## 정답 점수를 시험이 따로 계산한다 (SpeedLogic 을 쓰지 않는 독립 식).
static func expected_score(flags: String) -> int:
	var combo := 0
	var score := 0
	for ch in flags:
		if ch == "c":
			score += 10 + 2 * mini(combo, 10)
			combo += 1
		else:
			combo = 0
	return score


## s 에서 문제 하나를 풀고(정답 c / 오답 w) 보여 주기 시간만큼 시계를 흘린 뒤 step. 받아들여졌으면 true.
func _play_one(s: SpeedScreen, good: bool) -> bool:
	var q: Dictionary = s.current()
	if q.is_empty():
		return false
	var a: int = int(q["answer"])
	var pick: int = a if good else (a + 1) % 4
	var acc: bool = s.answer(pick)
	_t += 400 if good else 1000
	s.step()
	return acc


func _play(s: SpeedScreen, flags: String) -> void:
	for ch in flags:
		_play_one(s, ch == "c")


func _time_up(s: SpeedScreen) -> void:
	_t += SpeedLogic.LIMIT_MS
	s.step()


# ---------------------------------------------------------------- validators (also checked against broken input)

## 진행 화면 상태가 말이 되나: 보기 4개, 글자가 문제의 보기와 같음, 서로 다름, 정답 번호 범위. 문제 있으면 이유, 없으면 "".
static func check_play(q: Dictionary, texts: Array) -> String:
	var opts: Array = q.get("options", [])
	if opts.size() != 4 or texts.size() != 4:
		return "options/buttons != 4 (%d/%d)" % [opts.size(), texts.size()]
	var seen := {}
	for i in 4:
		if str(texts[i]) != str(opts[i]):
			return "button %d text differs from option" % i
		seen[str(texts[i])] = true
	if seen.size() != 4:
		return "duplicate option text"
	var a: int = int(q.get("answer", -1))
	if a < 0 or a > 3 or str(opts[a]) != str(q.get("ko", "-")):
		return "answer index does not point at the meaning"
	return ""


static func check_play_ui(s: SpeedScreen) -> String:
	var texts: Array = []
	for b in s.option_buttons:
		texts.append((b as Button).text)
	return check_play(s.current(), texts)


func _expect_reject(name: String, reason: String) -> void:
	if reason != "":
		print("  selfcheck FAIL-as-expected: ", name, " -> ", reason)
		ok(true, "selfcheck: %s is rejected" % name)
	else:
		ok(false, "selfcheck: %s should have been rejected" % name)


func _selfchecks() -> void:
	print("[validators reject broken input]")
	var good := {"options": ["a1", "b2", "c3", "d4"], "answer": 2, "ko": "c3"}
	ok(check_play(good, ["a1", "b2", "c3", "d4"]) == "", "check_play accepts a good question")
	_expect_reject("3 buttons", check_play(good, ["a1", "b2", "c3"]))
	_expect_reject("button text differs", check_play(good, ["a1", "b2", "zz", "d4"]))
	_expect_reject("duplicate options", check_play({"options": ["a", "a", "c", "d"], "answer": 2, "ko": "c"}, ["a", "a", "c", "d"]))
	_expect_reject("answer points at the wrong option", check_play({"options": ["a", "b", "c", "d"], "answer": 1, "ko": "c"}, ["a", "b", "c", "d"]))
	_expect_reject("answer out of range", check_play({"options": ["a", "b", "c", "d"], "answer": 7, "ko": "c"}, ["a", "b", "c", "d"]))
	ok(expected_score("ccccc") == 70, "expected_score: 5 right in a row = 70")
	ok(expected_score("ccwc") == 10 + 12 + 10, "expected_score: a wrong answer resets the combo")
	ok(expected_score("cccccccccccc") == 10 + 12 + 14 + 16 + 18 + 20 + 22 + 24 + 26 + 28 + 30 + 30, "expected_score: bonus stops at combo 10")
	_expect_reject("expected_score mismatch", "" if expected_score("ccc") == 37 else "expected_score(ccc) is %d, not 37" % expected_score("ccc"))
	_expect_reject("emoji / shape scan", _scan_text("start " + char(0x25B6)))
	_expect_reject("hex colour scan", _scan_text("var c := " + "Color(\"" + "#FFFFFF\")"))
	ok(_scan_text("정상 문장 Pal.INK") == "", "scan accepts plain text")


# ---------------------------------------------------------------- start screen

func _test_start_screen() -> void:
	print("[start screen]")
	_fresh()
	# 카드 5장 + 단어 0개 -> 시작 꺼짐 + 안내
	_add_cards("en", 5)
	var s := _make("en", [])
	await _frames(2)
	ok(s.stage == "start", "opens on the start screen")
	ok(not s.pool_ok(), "5 cards + 0 words: pool too small")
	ok(s.start_button != null and s.start_button.disabled, "start button is off when the pool is too small")
	ok(_has_text(s, "복습 카드를 더 모으거나 레슨을 해 보세요"), "too-small notice is shown")
	ok(not s.start_run(), "start_run refuses a too-small pool")
	ok(s.stage == "start", "still on the start screen after a refused start")
	# 풀이 충분하면
	_fresh()
	_add_cards("en", 4)
	StudyLog.add_speed_run("en", 300, 20, 25, 8)
	s = _make("en", _words("en", 60, true))
	await _frames(2)
	ok(s.pool_ok() and s.start_button != null and not s.start_button.disabled, "enough words: start button is on")
	ok(_has_text(s, "최고 기록 300점"), "best record is shown")
	ok(_has_text(s, "단어 64개 준비됨"), "ready word count is shown (4 cards + 60 words = 64)")
	ok(s.unverified_note == null and not _has_text(s, "틀릴 수 있어요"), "no accuracy note when every word is cross-checked")
	# 교차 확인 통과 단어가 모자라 통과 못한 단어가 섞이면 안내 한 줄
	s = _make("en", _words("en", 20, true) + _words("en", 30, false, false, 100))
	await _frames(2)
	ok(bool(s.pool.get("mixed_unverified", false)), "fixture: pool mixes unverified words")
	ok(s.unverified_note != null and s.unverified_note.text.contains("틀릴 수 있어요"), "accuracy note is shown when unverified words are mixed in")
	# 첫 기록 전
	_fresh()
	s = _make("en", _words("en", 30, true))
	await _frames(2)
	ok(_has_text(s, "아직 기록이 없어요"), "no record yet: says so")
	s.start_run(7)
	ok(s.stage == "play", "start button path: play stage")
	ok(s.logic != null and s.logic.is_started(), "the logic clock started")


# ---------------------------------------------------------------- a whole run

func _test_full_run() -> void:
	print("[full run with a fake clock]")
	_fresh()
	var s := _make("en", _words("en", 40, true))
	await _frames(2)
	ok(s.start_run(11), "run starts")
	await _frames(2)
	ok(check_play_ui(s) == "", "play screen: 4 options match the question (%s)" % check_play_ui(s))
	ok(s.remaining_ms() == 60000, "60 seconds at the start")
	var scores: Array = []
	for i in 8:
		ok(check_play_ui(s) == "", "question %d options valid" % (i + 1))
		ok(_play_one(s, true), "answer %d accepted" % (i + 1))
		scores.append(int(s.logic.result()["score"]))
	ok(int(s.logic.result()["score"]) == expected_score("cccccccc"), "8 right in a row = %d points (got %d)" % [expected_score("cccccccc"), int(s.logic.result()["score"])])
	ok(s.stage == "play", "still playing before the time is up")
	_t = 59000
	s.step()
	ok(s.stage == "play" and s.remaining_ms() == 1000, "1 second left at 59 s")
	_time_up(s)
	ok(s.stage == "result", "time up -> result screen")
	ok(int(s.run_result["score"]) == expected_score("cccccccc") and int(s.run_result["correct"]) == 8 and int(s.run_result["total"]) == 8, "result numbers: score / 8 of 8")
	var best: Dictionary = StudyLog.speed_best("en")
	ok(int(best.get("score", -1)) == expected_score("cccccccc"), "StudyLog.speed_best holds the score")
	ok(int(StudyLog.speed_summary("en")["plays"]) == 1, "one play recorded")
	var n: Dictionary = (StudyLog.range_summary("en", 1)[0] as Dictionary)["n"]
	ok(int(n.get("drill", 0)) == 1, "drill event counted once")
	ok(Store.did_day(Plan.today_days(), "en"), "today is marked as studied (8 answers >= 5)")
	ok(_speed_events == 1 and _all_events == ["speed"], "Store.activity 'speed' fired once (events %s)" % str(_all_events))
	ok(s.finish_count == 1, "one finish")
	ok(_has_text(s, "점수 %s" % str(expected_score("cccccccc"))), "result shows the score")
	ok(_has_text(s, "정답 8 / 8 (100%)"), "result shows 8 / 8 (100%)")
	ok(_has_text(s, "최고 콤보 8"), "result shows best combo 8")
	var cb: Button = _find_button(s, "다시 도전")
	ok(cb != null, "retry button exists")
	ok(s.retry() and s.stage == "play", "retry starts a new run")
	ok(s.remaining_ms() == 60000 or s.remaining_ms() == 60000 - 0, "the new run has a full minute")


# ---------------------------------------------------------------- new record

func _test_records() -> void:
	print("[new record / not recorded]")
	_fresh()
	var s := _make("en", _words("en", 40, true))
	s.start_run(3)
	_play(s, "cccccc")
	_time_up(s)
	ok(s.stage == "result" and s.new_record_shown(), "first run: new record shown")
	ok(not _has_text(s, "이전 최고"), "first run: no previous-best line")
	var first: int = expected_score("cccccc")
	# 더 낮은 판
	s.retry()
	_play(s, "ccccw")
	_time_up(s)
	ok(not s.new_record_shown(), "lower score: no new-record mark")
	ok(int(StudyLog.speed_best("en")["score"]) == first, "best stays at the higher score")
	ok(_has_text(s, "최고 기록 %d점" % first), "lower score: shows the best record")
	# 같은 점수: 표시 없음
	s.retry()
	_play(s, "cccccc")
	_time_up(s)
	ok(not s.new_record_shown(), "equal score is not a new record")
	# 더 높은 판
	s.retry()
	_play(s, "cccccccc")
	_time_up(s)
	ok(s.new_record_shown(), "higher score: new record shown")
	ok(_has_text(s, "이전 최고 %d점" % first), "higher score: shows the previous best (%d)" % first)
	ok(int(StudyLog.speed_best("en")["score"]) == expected_score("cccccccc"), "best moved up")
	# 4문제 -> 기록 안 함
	var plays_before: int = int(StudyLog.speed_summary("en")["plays"])
	var drill_before: int = int(((StudyLog.range_summary("en", 1)[0] as Dictionary)["n"] as Dictionary).get("drill", 0))
	s.retry()
	_play(s, "cccc")
	_time_up(s)
	ok(s.stage == "result" and not bool(s.run_record.get("recorded", true)), "4 answers: not recorded")
	ok(int(StudyLog.speed_summary("en")["plays"]) == plays_before, "4 answers: plays unchanged")
	ok(int(((StudyLog.range_summary("en", 1)[0] as Dictionary)["n"] as Dictionary).get("drill", 0)) == drill_before, "4 answers: no drill event")
	ok(_has_text(s, "기록은 5문제부터 남아요"), "4 answers: says records start at 5 answers")
	ok(not s.new_record_shown(), "4 answers: no new-record mark")


# ---------------------------------------------------------------- wrong answers

func _test_wrong() -> void:
	print("[wrong answers]")
	_fresh()
	var s := _make("en", _words("en", 40, true))
	s.start_run(5)
	await _frames(2)
	var q: Dictionary = s.current()
	var a: int = int(q["answer"])
	var pick: int = (a + 1) % 4
	ok(s.answer(pick), "a wrong answer is accepted once")
	ok(s.option_mark(a) == "check", "the right option gets a check mark")
	ok(s.option_mark(pick) == "close", "the picked wrong option gets a cross mark")
	var others := 0
	for i in 4:
		if i != a and i != pick and s.option_mark(i) != "":
			others += 1
	ok(others == 0, "the other options have no mark")
	ok(_has_text(s, "콤보 x0"), "combo is 0 after a wrong answer")
	_t += 500
	ok(not s.answer(a), "tapping again 0.5 s later is ignored (lock)")
	ok(int(s.logic.result()["total"]) == 1, "the ignored tap did not count")
	_t += 300 # 0.8 s: still showing the wrong answer
	s.step()
	ok(s.current().get("id", "") == q["id"], "the wrong answer is still on screen at 0.8 s")
	_t += 150 # 0.95 s
	s.step()
	ok(s.current().get("id", "") != q["id"], "next question appears after 0.9 s")
	ok(check_play_ui(s) == "", "next question is valid")
	# 맞히면 0.35 초 뒤 다음 문제
	var q2: Dictionary = s.current()
	ok(s.answer(int(q2["answer"])), "right answer accepted")
	ok(s.option_mark(int(q2["answer"])) == "check", "right answer: check mark")
	ok(_has_text(s, "콤보 x1"), "combo is 1 after a right answer")
	_t += 300
	s.step()
	ok(s.current().get("id", "") == q2["id"], "right answer: still shown at 0.3 s")
	_t += 100
	s.step()
	ok(s.current().get("id", "") != q2["id"], "right answer: next question after 0.35 s")
	# 틀린 단어 목록
	_time_up(s)
	ok(s.stage == "result", "result after the time is up")
	var wrong: Array = s.run_result.get("wrong", [])
	ok(wrong.size() == 1 and str((wrong[0] as Dictionary)["w"]) == str(q["w"]), "result lists the one wrong word")
	ok(_has_text(s, "틀린 단어 1개"), "result shows the wrong-word header")
	ok(_has_text(s, str(q["w"])) and _has_text(s, str(q["ko"])), "result shows the wrong word and its meaning")


func _test_review_cards() -> void:
	print("[add wrong words to review cards]")
	_fresh()
	_add_cards("en", 2) # 카드 2장 (복습 일정을 바꾸지 않는지 본다)
	var before: Array = Store.review_for("en").duplicate(true)
	var s := _make("en", _words("en", 40, true))
	s.start_run(9)
	_play(s, "wwwcc")
	_time_up(s)
	ok(s.stage == "result", "result reached")
	var n_wrong: int = (s.run_result["wrong"] as Array).size()
	ok(n_wrong == 3, "3 wrong words listed (got %d)" % n_wrong)
	var cards_before: int = Store.review_for("en").size()
	var added: int = s.add_wrong_to_review()
	ok(added == 3, "add_wrong_to_review adds 3 new cards (got %d)" % added)
	ok(Store.review_for("en").size() == cards_before + 3, "review list grew by 3")
	var again: int = s.add_wrong_to_review()
	ok(again == 0 and Store.review_for("en").size() == cards_before + 3, "pressing twice adds nothing more")
	var noted := 0
	for c in Store.review_for("en"):
		if str((c as Dictionary).get("note", "")) == "스피드 퀴즈":
			noted += 1
	ok(noted == 3, "new cards carry the note '스피드 퀴즈' (got %d)" % noted)
	var same := true
	for old in before:
		for cur in Store.review_for("en"):
			if (cur as Dictionary)["id"] == (old as Dictionary)["id"]:
				for k in ["reps", "due", "stability", "difficulty", "state", "lapses"]:
					if (old as Dictionary).has(k) and (cur as Dictionary).get(k) != (old as Dictionary)[k]:
						same = false
	ok(same, "existing cards' schedule (reps / due / stability ...) is unchanged: rate_review is not used")
	ok(not before.is_empty(), "fixture: there were existing cards to compare")
	await _frames(2)
	var rb: Button = _find_button(s, "복습 카드에 넣었어요")
	ok(rb == null or rb.disabled, "button is spent after adding")


# ---------------------------------------------------------------- pause

func _test_pause() -> void:
	print("[pause]")
	_fresh()
	var s := _make("en", _words("en", 40, true))
	s.start_run(2)
	_t = 10000
	s.step()
	ok(s.remaining_ms() == 50000, "50 s left at 10 s")
	s.notification(Node.NOTIFICATION_APPLICATION_PAUSED)
	ok(s.is_paused(), "app paused -> paused")
	_t = 40000
	s.step()
	ok(s.remaining_ms() == 50000, "the clock stands still while paused (50 s left)")
	ok(s.stage == "play", "no result while paused")
	ok(not s.answer(0), "no answer while paused")
	s.notification(Node.NOTIFICATION_APPLICATION_RESUMED)
	ok(not s.is_paused(), "app resumed -> running")
	ok(s.remaining_ms() == 50000, "right after resume the time is as before the pause")
	_t = 45000
	s.step()
	ok(s.remaining_ms() == 45000, "the clock runs again after resume (45 s left)")
	# 창 포커스
	s.notification(Node.NOTIFICATION_WM_WINDOW_FOCUS_OUT)
	_t = 100000
	s.step()
	ok(s.stage == "play" and s.remaining_ms() == 45000, "focus lost: time is held, no result")
	s.notification(Node.NOTIFICATION_WM_WINDOW_FOCUS_IN)
	_t = 101000
	s.step()
	ok(s.remaining_ms() == 44000, "focus back: running again")
	# 두 이유가 겹치면 둘 다 풀려야 이어진다
	s.notification(Node.NOTIFICATION_APPLICATION_PAUSED)
	s.notification(Node.NOTIFICATION_WM_WINDOW_FOCUS_OUT)
	s.notification(Node.NOTIFICATION_APPLICATION_RESUMED)
	ok(s.is_paused(), "still paused while the window has no focus")
	s.notification(Node.NOTIFICATION_WM_WINDOW_FOCUS_IN)
	ok(not s.is_paused(), "both reasons gone -> running")
	# 가려지면(on_hide) 멈춘다
	var rem: int = s.remaining_ms()
	s.on_hide()
	ok(s.is_paused(), "on_hide pauses the run")
	_t += 20000
	s.step()
	ok(s.remaining_ms() == rem and s.stage == "play", "hidden: time held")
	s.notification(CanvasItem.NOTIFICATION_VISIBILITY_CHANGED)
	ok(not s.is_paused(), "shown again -> running")
	# 오답을 보여 주는 동안 멈추면 보여 주기도 같이 멈춘다
	var q: Dictionary = s.current()
	s.answer((int(q["answer"]) + 1) % 4)
	_t += 300
	s.notification(Node.NOTIFICATION_APPLICATION_PAUSED)
	_t += 5000
	s.step()
	ok(s.current().get("id", "") == q["id"], "the wrong-answer display is held while paused")
	s.notification(Node.NOTIFICATION_APPLICATION_RESUMED)
	_t += 400
	s.step()
	ok(s.current().get("id", "") == q["id"], "after resume the rest of the display time is still owed")
	_t += 300
	s.step()
	ok(s.current().get("id", "") != q["id"], "then the next question comes")


# ---------------------------------------------------------------- quit sheet

func _test_quit_sheet() -> void:
	print("[back button / quit sheet]")
	_fresh()
	var s := _make("en", _words("en", 40, true))
	var closed_n := [0]
	s.closed.connect(func() -> void: closed_n[0] += 1)
	ok(s.go_back() and closed_n[0] == 1, "back on the start screen leaves to the hub")
	s.start_run(4)
	_t = 5000
	s.step()
	_play_one(s, true)
	ok(s.go_back(), "back during a run is handled")
	ok(Sheet.is_open() and s.quit_sheet != null, "a confirm sheet opens")
	ok(s.is_paused(), "the clock is held while the sheet is open")
	var rem: int = s.remaining_ms()
	s.go_back()
	ok(Sheet.depth() == 1, "a second back does not open a second sheet")
	_t += 30000
	s.step()
	ok(s.remaining_ms() == rem and s.stage == "play", "no time passes while the sheet is open")
	(s.quit_sheet.buttons["cancel"] as Button).pressed.emit()
	ok(not Sheet.is_open() and not s.is_paused(), "[계속] closes the sheet and the clock runs on")
	_t += 1000
	s.step()
	ok(s.remaining_ms() == rem - 1000, "time continues after [계속]")
	var plays: int = int(StudyLog.speed_summary("en")["plays"])
	s.go_back()
	(s.quit_sheet.buttons["ok"] as Button).pressed.emit()
	ok(closed_n[0] == 2, "[그만두기] leaves to the hub (closed emitted)")
	ok(int(StudyLog.speed_summary("en")["plays"]) == plays and plays == 0, "quitting records nothing")
	ok(_speed_events == 0, "quitting sends no activity event")
	ok(not Sheet.is_open(), "no sheet is left open")


# ---------------------------------------------------------------- japanese

func _test_japanese() -> void:
	print("[japanese reading]")
	_fresh()
	var words: Array = _words("ja", 40, true)
	var s := _make("ja", words)
	s.start_run(6)
	await _frames(2)
	var q: Dictionary = s.current()
	var rd: String = str(q["rd"])
	ok(rd != "", "fixture: the question has a reading")
	ok(_has_text(s, rd), "ja: the reading is shown")
	ok(_has_text(s, str(q["w"])), "ja: the word is shown")
	# 영어는 읽기 줄이 없다 (카드에 reading 이 있어도)
	_fresh()
	Store.add_review([{"lang": "en", "target": "cardx", "reading": "kaadoekkusu", "ko": "카드엑스", "note": "x"}])
	var ew: Array = _words("en", 40, true)
	for w in ew:
		(w as Dictionary)["rd"] = "zzreadzz"
	var es := _make("en", ew)
	es.start_run(6)
	await _frames(2)
	ok(not _has_text(es, "zzreadzz") and not _has_text(es, "kaadoekkusu"), "en: no reading line even when the data has one")


# ---------------------------------------------------------------- layout

func _check_inside(s: SpeedScreen, name: String) -> void:
	var page: PageScroll = s._shell["page"]
	var pr: Rect2 = Rect2(_holder.global_position, _holder.size) ## the screen itself (the page may have grown wider than the screen)
	ok(page.size.x <= _holder.size.x + 0.5, "%s: the page is not wider than the screen (%.1f of %.1f)" % [name, page.size.x, _holder.size.x])
	var bad := 0
	for b in s.option_buttons:
		var r: Rect2 = (b as Button).get_global_rect()
		if r.end.x > pr.end.x + 0.5 or r.position.x < pr.position.x - 0.5:
			bad += 1
		if (b as Button).size.y + 0.5 < (b as Button).get_combined_minimum_size().y:
			bad += 1
	ok(bad == 0, "%s: option buttons stay inside the page and tall enough for their text" % name)
	var hbar := page.get_h_scroll_bar()
	ok(not hbar.visible or hbar.max_value - hbar.page < 1.0, "%s: no horizontal scrolling" % name)
	var wide: Array = _outside(page.content, pr)
	ok(wide.is_empty(), "%s: every control stays inside the page width (outside: %s)" % [name, str(wide.slice(0, 3))])


## page 영역 오른쪽 밖으로 나간 보이는 컨트롤의 이름 목록.
func _outside(n: Node, pr: Rect2) -> Array:
	var out: Array = []
	for c in n.get_children():
		if c is Control and (c as Control).is_visible_in_tree():
			var r: Rect2 = (c as Control).get_global_rect()
			if r.end.x > pr.end.x + 0.5 or r.position.x < pr.position.x - 0.5:
				out.append("%s(%s)" % [c.get_class(), str(c.get("text")) if c is Label or c is Button else ""])
		out.append_array(_outside(c, pr))
	return out


func _test_long_text_layout() -> void:
	print("[12-character meanings wrap inside the buttons]")
	_fresh()
	var s := _make("en", _words("en", 40, true, true))
	s.start_run(8)
	await _frames(5)
	ok(check_play_ui(s) == "", "long meanings: options valid")
	var longest := 0
	for b in s.option_buttons:
		longest = maxi(longest, (b as Button).text.length())
	ok(longest == 12, "fixture: meanings are 12 characters (got %d)" % longest)
	_check_inside(s, "12-char meanings")
	# 정답 표시(도형 · 오른쪽 여백)가 붙은 뒤에도
	s.answer((int(s.current()["answer"]) + 1) % 4)
	await _frames(3)
	_check_inside(s, "12-char meanings after answering")
	# 긴 영어 카드 단어(40자)도 화면 안
	_fresh()
	Store.add_review([{"lang": "en", "target": "abcdefghijklmnopqrstuvwxyzabcdefghijklmn", "reading": "", "ko": "긴 카드", "note": "x"}])
	var s2 := _make("en", _words("en", 40, true))
	s2.start_run(1)
	await _frames(2)
	for i in 80: # 긴 카드 문제가 나올 때까지 (한 바퀴 안에 반드시 나온다)
		if str(s2.current().get("w", "")).length() > 30 or s2.stage != "play":
			break
		_play_one(s2, true)
	await _frames(4)
	if str(s2.current().get("w", "")).length() > 30:
		var pr: Rect2 = Rect2(_holder.global_position, _holder.size)
		var wide := false
		for l in _label_nodes(s2):
			if (l as Label).text.length() > 30 and (l as Label).get_global_rect().end.x > pr.end.x + 0.5:
				wide = true
		ok(not wide, "a 40-character word wraps inside the screen")
	else:
		ok(false, "the long card question never came up")


func _label_nodes(n: Node) -> Array:
	var out: Array = []
	for c in n.get_children():
		if c is Label:
			out.append(c)
		out.append_array(_label_nodes(c))
	return out


func _test_layout_sizes() -> void:
	print("[layout: %s, scale %s%s]" % ["412x915 phone" if phone else "1280x800 pc", str(_scale), ", dark" if _dark else ""])
	_fresh()
	var s := _make("en", _words("en", 40, true))
	s.start_run(10)
	await _frames(5)
	var page: PageScroll = s._shell["page"]
	var pr: Rect2 = Rect2(_holder.global_position, _holder.size)
	var min_h := 1e9
	for b in s.option_buttons:
		min_h = minf(min_h, (b as Button).size.y)
	if phone:
		ok(min_h >= 72.0, "phone: option buttons are at least 72 high (smallest %.1f)" % min_h)
	else:
		ok(min_h >= 60.0, "pc: option buttons are at least 60 high (smallest %.1f)" % min_h)
	ok(s.option_buttons.size() == 4, "four option buttons")
	var g: GridContainer = (s.option_buttons[0] as Button).get_parent()
	ok(g.columns == 2, "options sit in a 2x2 grid")
	var hud_ok := true
	for node in [s._time_label, s._score_label, s._bar, s._combo_label]:
		var r: Rect2 = (node as Control).get_global_rect()
		if r.position.y < pr.position.y - 0.5 or r.end.y > pr.end.y + 0.5 or r.end.x > pr.end.x + 0.5:
			hud_ok = false
	ok(hud_ok, "time label, score, time bar and combo are all inside the visible page")
	var holder_rect := Rect2(Vector2.ZERO, _holder.size)
	var all_in := true
	for b in s.option_buttons:
		var r2: Rect2 = (b as Button).get_global_rect()
		if r2.end.y > holder_rect.end.y + 0.5:
			all_in = false
	if _scale <= 1.0:
		ok(all_in, "at normal text size the whole question fits on one screen")
	_check_inside(s, "normal")
	var bar_before: float = s._bar.value
	_t += 30000
	s.step()
	ok(s._bar.value < bar_before and absf(s._bar.value - 0.5) < 0.01, "the time bar shrinks with the time (half at 30 s)")
	ok(s._time_label.text == "남은 시간 30초", "time label: 30 s left (%s)" % s._time_label.text)
	# 결과 화면
	_time_up(s)
	await _frames(4)
	ok(s.stage == "result", "result screen")
	var again: Button = _find_button(s, "다시 도전")
	ok(again != null and again.size.y >= 48.0, "[다시 도전] is at least 48 high (%.1f)" % (again.size.y if again != null else -1.0))
	var out: Button = _find_button(s, "나가기")
	ok(out != null and out.size.y >= 48.0, "[나가기] is at least 48 high")
	var rpr: Rect2 = Rect2(_holder.global_position, _holder.size)
	ok(again != null and again.get_global_rect().end.x <= rpr.end.x + 0.5, "[다시 도전] stays inside the page")
	# 12자 뜻의 오답이 있는 결과 화면도 폭 안에
	_fresh()
	var sl := _make("en", _words("en", 40, true, true))
	sl.start_run(8)
	_play(sl, "wwcw")
	_time_up(sl)
	await _frames(4)
	_check_inside(sl, "result with long wrong meanings")


# ---------------------------------------------------------------- the data file is unreadable

func _test_words_file_missing() -> void:
	print("[word file cannot be read]")
	_fresh()
	# 카드가 충분하면 단어 없이도 시작할 수 있다
	_add_cards("en", 14)
	var s := _make("en", [], true)
	await _frames(2)
	ok(not s.words_ok, "fixture: words not ok")
	ok(s.pool_ok() and s.start_button != null and not s.start_button.disabled, "14 cards are enough to start without the word file")
	ok(s.start_run(3) and s.stage == "play", "a run starts from cards only")
	ok(check_play_ui(s) == "", "cards-only question is valid")
	# 카드가 모자라면 안내
	_fresh()
	_add_cards("en", 3)
	s = _make("en", [], true)
	await _frames(2)
	ok(not s.pool_ok() and s.start_button != null and s.start_button.disabled, "3 cards and no words: start is off")
	ok(_has_text(s, "복습 카드를 더 모으거나 레슨을 해 보세요"), "3 cards and no words: guidance shown")
	ok(_has_text(s, "읽지 못했어요"), "tells that the word list could not be read")
	# 진짜 SpeedPool.load_words 경로: 깨진 JSON 파일
	_fresh()
	var f := FileAccess.open(TEST_BAD_WORDS, FileAccess.WRITE)
	f.store_string("{ this is not json")
	f.close()
	SpeedPool.words_path = TEST_BAD_WORDS
	SpeedPool.clear_cache()
	_add_cards("en", 13)
	s = _make("en", [], false) # 훅 없이: 실제 load_words 가 깨진 파일을 본다
	await _frames(2)
	ok(not s.words_ok and s.words_err == "bad", "broken file: load_words reports bad (err '%s')" % s.words_err)
	ok(s.pool_ok(), "broken file but 13 cards: still startable")
	_fresh()
	SpeedPool.words_path = "user://test_fun_q2_does_not_exist.json"
	SpeedPool.clear_cache()
	s = _make("ja", [], false)
	await _frames(2)
	ok(not s.words_ok and s.words_err == "missing" and not s.pool_ok(), "missing file: guidance, no error")
	ok(s.stage == "start" and s.start_button.disabled, "missing file: start is off")
	SpeedPool.words_path = _saved["words_path"]
	SpeedPool.clear_cache()
	# 진짜 데이터 파일
	_fresh()
	s = _make("en", [], false)
	await _frames(2)
	ok(s.words_ok and s.pool_ok(), "the real data/speed_words.json gives a playable pool")
	ok(s.start_run(12) and check_play_ui(s) == "", "a real-data run starts with valid options")
	_play(s, "cccwc")
	_time_up(s)
	ok(s.stage == "result" and int(StudyLog.speed_summary("en")["plays"]) == 1, "a real-data run finishes and is recorded")
	var sj := _make("ja", [], false)
	await _frames(2)
	ok(sj.words_ok and sj.pool_ok() and sj.start_run(12) and check_play_ui(sj) == "", "ja: real data also plays")


# ---------------------------------------------------------------- bad input on purpose

func _test_bad_input() -> void:
	print("[bad input on purpose]")
	_fresh()
	var s := _make("fr", [])
	ok(s.stage == "unsupported", "open('fr') shows the safe unsupported screen")
	ok(not s.start_run() and not s.answer(0), "unsupported: start_run / answer do nothing")
	ok(s.go_back(), "unsupported: back leaves")
	var s2 := _make("", [])
	ok(s2.stage == "unsupported", "open('') is also the safe screen")
	# 시간이 끝난 뒤 보기 누르기
	_fresh()
	var s3 := _make("en", _words("en", 40, true))
	s3.start_run(1)
	_play(s3, "ccccc")
	_t += SpeedLogic.LIMIT_MS # 시간이 끝났지만 step 은 아직
	var late: bool = s3.answer(0)
	ok(not late, "answer after the time is over is refused")
	ok(s3.stage == "result", "...and the screen moves to the result")
	ok(int(s3.run_result["total"]) == 5, "the late tap did not count (5 answers)")
	# 결과 화면에서 보기 누르기
	ok(not s3.answer(0) and not s3.answer(3) and int(StudyLog.speed_summary("en")["total"]) == 5, "answer on the result screen does nothing")
	# 같은 결과를 두 번 finish()
	var plays: int = int(StudyLog.speed_summary("en")["plays"])
	s3.finish()
	s3.finish()
	ok(int(StudyLog.speed_summary("en")["plays"]) == plays and s3.finish_count == 1 and _speed_events == 1, "finish() twice records once (plays %d, finish_count %d, events %d)" % [int(StudyLog.speed_summary("en")["plays"]), s3.finish_count, _speed_events])
	var drills: int = int(((StudyLog.range_summary("en", 1)[0] as Dictionary)["n"] as Dictionary).get("drill", 0))
	ok(drills == 1, "drill event counted once after two finish() calls")
	# 범위 밖 번호
	_fresh()
	var s4 := _make("en", _words("en", 40, true))
	s4.start_run(2)
	ok(not s4.answer(-1) and not s4.answer(4) and not s4.answer(99), "option numbers outside 0..3 are refused")
	ok(int(s4.logic.result()["total"]) == 0, "refused taps did not count")
	# 시작 전(start 화면)에서 answer / step
	var s5 := _make("en", _words("en", 40, true))
	ok(not s5.answer(0), "answer before the run starts is refused")
	s5.step()
	ok(s5.stage == "start", "step on the start screen changes nothing")
	# 풀이 모자란 상태로 다시 도전
	ok(not s5.retry(), "retry outside the result screen does nothing")
	# 시계가 거꾸로 가도 죽지 않는다
	var s6 := _make("en", _words("en", 40, true))
	s6.start_run(2)
	_t = 5000
	s6.step()
	_t = 1000
	s6.step()
	ok(s6.stage == "play", "a clock that goes backwards does not end the run or crash")
	# 읽기 못 하는 단어 항목(ko 가 숫자인 항목)은 건너뛴다
	_fresh()
	var junk: Array = _words("en", 30, true)
	junk.append({"w": "bad", "rd": "", "ko": 5, "pos": "noun", "m": 1, "v": true})
	junk.append("not a dict")
	var s7 := _make("en", junk, false)
	s7.words_hook = Callable(self, "_junk_hook").bind(junk)
	s7.open("en")
	ok(s7.pool_ok() or not s7.pool_ok(), "junk word entries do not crash the start screen")
	if s7.pool_ok():
		ok(s7.start_run(2) and check_play_ui(s7) == "", "junk entries are skipped, the run is valid")


func _junk_hook(_l: String, junk: Array) -> Dictionary:
	return {"ok": true, "words": junk, "err": ""}


# ---------------------------------------------------------------- file rules

## 금지 글자 · 패턴을 찾으면 이유, 없으면 "".
static func _scan_text(src: String) -> String:
	var bad_words := ["HTTP" + "Request", "Api" + ".", "Route" + ".", "OS" + ".shell_open", "OS" + ".request_permission",
		"Color(\"" + "#", "Color" + ".html(", "duo" + "lingo", "fla" + "me"]
	for w in bad_words:
		if src.contains(w):
			return "contains '%s'" % w
	for i in src.length():
		var c: int = src.unicode_at(i)
		if (c >= 0x2190 and c <= 0x2BFF) or c >= 0x1F000 or (c >= 0xFE00 and c <= 0xFE0F):
			return "contains a symbol / emoji character U+%04X" % c
	return ""


func _test_file_rules() -> void:
	print("[file rules]")
	for p in ["res://scripts/practice/speed_screen.gd", "res://tests/speed_screen_test.gd"]:
		var txt := FileAccess.get_file_as_string(p)
		ok(txt != "", "%s can be read" % p)
		var why := _scan_text(txt)
		ok(why == "", "%s: no network call / hex colour / emoji (%s)" % [p, why])
	var src := FileAccess.get_file_as_string("res://scripts/practice/speed_screen.gd")
	ok(not src.contains("rate_review"), "speed_screen.gd never calls rate_review")
	ok(not src.contains("AudioStreamPlayer") and not src.contains("Input.vibrate") and not src.contains("Tts."), "no sound / vibration in speed_screen.gd")
