extends Node
## 한 줄 일기 "끝까지 진행" 시험 (REVIEW.md: 실제 버튼의 pressed 신호만 눌러 흐름을 끝까지 간다. answer()/next_*() 같은 함수 직접 호출 금지).
##   PC   : godot --headless --path godot res://tests/diary_flow_test.tscn -- --api=http://127.0.0.1:9
##   폰   : godot --headless --path godot --resolution 412x915 res://tests/diary_flow_test.tscn -- --phone --api=http://127.0.0.1:9 [--font-scale=1.5] [--dark]
##   그림 : (헤드리스 아님) ... -- --phone --shots=<폴더>   -> 01_write, 02_consent, 03_result, 04_list_saved 의 PNG 를 남긴다.
## (APPDATA 는 임시 폴더로 바꿔 실행한다. 시험 전용 파일 user://test_diary_c3f_* 만 쓴다.)
## 흐름 A (AI 있음): 3문장 쓰기 -> [고쳐 보기] -> 동의 시트 [동의하고 고치기] -> "1 / 3 문장 고치는 중…" -> 결과 카드 -> "✓ 복습 카드에 넣었어요"
##                  -> [일기 목록] -> "고침 완료" -> [보기] -> [지우기] -> 확인 시트 [지우기] -> [다시 쓰기] ... -> [일기 모두 지우기]
## 흐름 B (AI 없음): [고쳐 보기] 꺼짐 + 이유 -> [저장만 하기] -> "고치기 대기" -> AI 가 켜진 뒤 [고치기] -> 고침 완료 (폰: [말해서 쓰기] 숨김)
## 흐름 C (마커)   : 고유 마커(ZZ_MARK_9731)를 일기에 쓰고 끝까지 진행한 뒤 progress / studylog / prefs / user:// 파일 / 시험 출력에 마커가 없다
##                  (일기 파일 자체와, 고친 문장 칸(target)에 AI 가 마커를 되돌려 주는 경우는 예외).
## 누를 때마다 `press: <버튼>` 줄을 찍고, 단계마다 다음 버튼이 보이고 켜져 있는지 단언한다.
## 마지막 줄: "== diary_flow: N passed, M failed ==" (실패가 있으면 종료 코드 1)

const MARK := "ZZ_MARK_9731"
const P_DIARY := "user://test_diary_c3f_diary.json"
const P_PROG := "user://test_diary_c3f_progress.json"
const P_PREFS := "user://test_diary_c3f_prefs.json"
const P_LOG := "user://test_diary_c3f_studylog.json"
const PHONE_SCREEN := Vector2(412, 915)
const PC_SCREEN := Vector2(1280, 800)

const FIX_JA := ["昨日、友達と映画を見ました。", "今日は雨が降っています。", "明日は学校に行きます。", "私は本を読みました。", "夕飯にカレーを食べました。",
	"朝は七時に起きます。", "週末に海へ行きました。", "彼女は先生になりたいです。", "駅まで歩いて行きます。", "犬と公園を散歩しました。"]
const RD_JA := ["きのう、ともだちとえいがをみました。", "きょうはあめがふっています。", "あしたはがっこうにいきます。", "わたしはほんをよみました。", "ゆうはんにカレーをたべました。",
	"あさはしちじにおきます。", "しゅうまつにうみへいきました。", "かのじょはせんせいになりたいです。", "えきまであるいていきます。", "いぬとこうえんをさんぽしました。"]

signal _go

var passed: int = 0
var failed: int = 0
var phone: bool = false
var _scale: float = 1.0
var _dark: bool = false
var _shots_dir: String = ""
var _holder: Control = null
var _saved := {}
var _reqs: Array = []
var _all_reqs: Array = []
var _queue: Array = []
var _hold: bool = false
var _n: int = 0
var _presses: int = 0
var _tts_events: int = 0
var _toasts: Array = []


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
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--font-scale=") and a.substr(13).is_valid_float():
			_scale = a.substr(13).to_float()
		elif a == "--dark":
			_dark = true
		elif a.begins_with("--shots="):
			_shots_dir = a.substr(8)
	print("== diary_flow test start (%s, scale %s%s) ==" % ["phone" if phone else "pc", str(_scale), ", dark" if _dark else ""])
	_setup()
	await _frames(2)
	_selfchecks()
	await _flow_a()
	await _flow_b()
	await _flow_c()
	await _flow_d()
	await _flow_e()
	await _flow_f()
	_final_checks()
	_teardown()
	print("== diary_flow: %d passed, %d failed ==" % [passed, failed])
	get_tree().quit(1 if failed > 0 else 0)


# ---------------------------------------------------------------- setup

func _setup() -> void:
	_saved = {
		"diary_path": DiaryStore.path, "prefs_path": Store.prefs_path, "progress_path": Store.progress_path, "log_path": StudyLog.path,
		"progress": Store.progress.duplicate(true), "prefs": Store.prefs.duplicate(true), "animate": Sheet.animate, "health": Backend.health.duplicate(true),
	}
	Store.prefs_path = P_PREFS
	Store.progress_path = P_PROG
	StudyLog.path = P_LOG
	DiaryStore.path = P_DIARY
	DiaryStore.today_override = Plan.days_from_civil(2026, 11, 14)
	DiaryStore.unix_override = 1731571200
	Sheet.animate = false
	SpeakDrill.api_hook = Callable(self, "_api")
	Tts.chunk_started.connect(func(_i: int, _t: String) -> void: _tts_events += 1)
	Tts.state_changed.connect(func() -> void: _tts_events += 1)
	Toast.message.connect(func(t: String, _k: String) -> void: _toasts.append(t))
	var size := Vector2i(PHONE_SCREEN) if phone else Vector2i(PC_SCREEN)
	get_window().min_size = Vector2i.ZERO
	get_window().size = size
	UiBoot.apply(get_window(), "dark" if _dark else "light", _scale)
	if phone:
		PhoneLayout.install_touch_scroll(get_tree())
	if _shots_dir != "":
		DirAccess.make_dir_recursive_absolute(_shots_dir)
	_fresh()


func _teardown() -> void:
	if _holder != null and is_instance_valid(_holder):
		_holder.queue_free()
	while Sheet.close_top():
		pass
	SpeakDrill.api_hook = Callable()
	DiaryScreen.ai_hook = Callable()
	DiaryScreen.stt_hook = Callable()
	DiaryScreen.old_server_seen = false
	StudyLog.reset()
	for p in [P_DIARY, P_DIARY + ".tmp", P_DIARY + ".bad", P_PROG, P_PROG + ".tmp", P_PREFS, P_PREFS + ".tmp", P_LOG, P_LOG + ".tmp"]:
		_rm(p)
	DiaryStore.today_override = -1
	DiaryStore.unix_override = -1
	DiaryStore.path = _saved["diary_path"]
	DiaryStore.forget()
	StudyLog.path = _saved["log_path"]
	Store.prefs_path = _saved["prefs_path"]
	Store.progress_path = _saved["progress_path"]
	Store.progress = _saved["progress"]
	Store.prefs = _saved["prefs"]
	Sheet.animate = _saved["animate"]
	Backend.health = _saved["health"]


func _rm(path: String) -> void:
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


func _fresh() -> void:
	while Sheet.close_top():
		pass
	_rm(P_DIARY)
	_rm(P_DIARY + ".bad")
	DiaryStore.forget()
	Store.progress = Progress.blank()
	Store.prefs["diary_consent"] = false
	Store.prefs["auto_fix_cards"] = true
	Store.prefs["show_reading"] = true
	_rm(P_LOG)
	StudyLog.load_from_disk()
	StudyLog.reset()
	DiaryScreen.ai_hook = func() -> String: return "ready"
	DiaryScreen.stt_hook = func() -> bool: return false
	DiaryScreen.old_server_seen = false
	Backend.health = {"llm": true, "fix_private": true} ## a PC program that knows "private"
	_reqs = []
	_queue = []
	_hold = false
	_n = 0
	_presses = 0


# ---------------------------------------------------------------- fake server

func _api(method: String, path: String, body: Variant) -> Variant:
	var rec := {"method": method, "path": path, "body": (body as Dictionary).duplicate(true) if body is Dictionary else body}
	_reqs.append(rec)
	_all_reqs.append(rec)
	if _hold:
		await _go
	if not _queue.is_empty():
		return _queue.pop_front()
	if path == "/fix":
		var i: int = _n
		_n += 1
		return {"fix": FIX_JA[i % FIX_JA.size()], "fix_ko": "과거형과 정중체로 맞췄어요.", "reading": RD_JA[i % RD_JA.size()], "pron": "キノー、トモダチ"}
	return {"ok": false, "code": 404, "data": null, "error": "no route", "err_code": ""}


func _fix_reqs() -> Array:
	return _reqs.filter(func(r: Dictionary) -> bool: return r["path"] == "/fix")


## 가짜 서버가 대기 중인 요청 하나를 풀어 준다.
func _release() -> void:
	_go.emit()
	await _frames(3)


# ---------------------------------------------------------------- helpers

func _make(lang: String) -> DiaryScreen:
	if _holder != null and is_instance_valid(_holder):
		_holder.queue_free()
	_holder = Control.new()
	_holder.size = PHONE_SCREEN if phone else PC_SCREEN
	_holder.clip_contents = true
	add_child(_holder)
	var s := DiaryScreen.new()
	_holder.add_child(s)
	s.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	s.open(lang)
	return s


func _type(s: DiaryScreen, text: String) -> void:
	s._edit.text = text
	s._edit.text_changed.emit()


func _find(s: Node, node_name: String) -> Node:
	return s.find_child(node_name, true, false)


func _btn(s: Node, node_name: String) -> Button:
	return _find(s, node_name) as Button


## 단계마다: 이 버튼이 보이고 켜져 있어야 한다. 그 뒤 pressed 신호를 낸다.
func _press(b: Button, label: String) -> bool:
	var good: bool = b != null and is_instance_valid(b) and b.is_visible_in_tree() and not b.disabled
	ok(good, "visible and enabled before the press: " + label)
	if not good:
		return false
	_presses += 1
	print("press: ", label)
	b.pressed.emit()
	return true


func _collect(node: Node, out: Array) -> void:
	for c in node.get_children():
		if c is Control and not (c as Control).visible:
			continue
		if c is Label:
			out.append((c as Label).text)
		elif c is Button:
			out.append((c as Button).text)
		_collect(c, out)


func _joined(node: Node) -> String:
	var out: Array = []
	_collect(node, out)
	return "\n".join(PackedStringArray(out))


func _count(s: Node, prefix: String) -> int:
	var n := 0
	var stack: Array = [s]
	while not stack.is_empty():
		var x: Node = stack.pop_back()
		for c in x.get_children():
			stack.append(c)
		if str(x.name).contains(prefix) and x.is_visible_in_tree():
			n += 1
	return n


func _shot(file: String) -> void:
	if _shots_dir == "":
		return
	await _frames(3)
	await get_tree().create_timer(0.35).timeout ## (frame_post_draw does not always come when the window is not in front)
	var img: Image = get_viewport().get_texture().get_image()
	if img != null:
		img.save_png(_shots_dir.path_join(file))


func _min_button_h(s: Node) -> float:
	var m := 1e9
	var stack: Array = [s]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		for c in n.get_children():
			stack.append(c)
		if n is Button and (n as Button).is_visible_in_tree():
			m = minf(m, (n as Button).size.y)
	return m


# ---------------------------------------------------------------- marker scan

func _file_has_mark(path: String) -> bool:
	var f := FileAccess.open(path, FileAccess.READ)
	return f != null and f.get_as_text().contains(MARK)


## user:// 아래 모든 파일 중 마커가 든 것 (allowed 에 있는 경로는 제외).
func _files_with_mark(dir: String, allowed: Array) -> Array:
	var out: Array = []
	var d := DirAccess.open(dir)
	if d == null:
		return out
	for sub in d.get_directories():
		out.append_array(_files_with_mark(dir.path_join(sub), allowed))
	for fn in d.get_files():
		var p: String = dir.path_join(fn)
		if not allowed.has(p) and _file_has_mark(p):
			out.append(p)
	return out


func _selfchecks() -> void:
	print("[selfcheck: the checkers fail on purpose-wrong input]")
	var tmp := "user://test_diary_c3f_selfcheck.txt"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	f.store_string("hello " + MARK + " world")
	f.close()
	var hits: Array = _files_with_mark("user://", [])
	ok(hits.has(tmp), "selfcheck FAIL-as-expected: the scan finds a file that carries the marker (%d file)" % hits.size())
	ok(not _files_with_mark("user://", [tmp]).has(tmp), "the allowed list really skips a file")
	_rm(tmp)
	ok(not _files_with_mark("user://", []).has(tmp), "...and a clean folder has no hit")
	var fake := Button.new()
	fake.disabled = true
	add_child(fake)
	var before: int = _presses
	var pressed_ok := _press_would_pass(fake)
	ok(not pressed_ok and _presses == before, "selfcheck FAIL-as-expected: a disabled button is not pressed")
	fake.queue_free()


func _press_would_pass(b: Button) -> bool:
	return b != null and is_instance_valid(b) and b.is_visible_in_tree() and not b.disabled


# ---------------------------------------------------------------- flow A

func _flow_a() -> void:
	print("[flow A: AI ready, three sentences, real buttons]")
	_fresh()
	_hold = true
	var s := _make("ja")
	await _frames(3)
	var text := "きのう ともだちと えいがをみた。きょうは あめだった。あした がっこうへ いく。"
	_type(s, text)
	await _frames(2)
	ok((_find(s, "Counter") as Label).text == "문장 3/3 · %d/300자" % text.length(), "counter: " + (_find(s, "Counter") as Label).text)
	await _shot("01_write.png")
	# [고쳐 보기] -> consent sheet
	_press(_btn(s, "FixBtn"), "고쳐 보기")
	await _frames(3)
	ok(Sheet.is_open() and s.last_sheet != null and not s.last_sheet.is_closed(), "the consent sheet is shown")
	ok(_fix_reqs().is_empty(), "no request while the sheet is open")
	await _shot("02_consent.png")
	_press(s.last_sheet.buttons["agree"], "동의하고 고치기")
	await _frames(3)
	# working: 1/3, 2/3, 3/3
	ok(s.stage == "working", "working screen after agreeing")
	var wl: Label = _find(s, "WorkLabel") as Label
	ok(wl != null and wl.text == "1 / 3 문장 고치는 중…", "label: 1 / 3 문장 고치는 중…")
	ok(_btn(s, "CancelBtn") != null and _btn(s, "CancelBtn").is_visible_in_tree() and not _btn(s, "CancelBtn").disabled, "[취소] is visible and enabled")
	ok(_fix_reqs().size() == 1, "one request so far")
	await _release()
	wl = _find(s, "WorkLabel") as Label
	ok(wl != null and wl.text == "2 / 3 문장 고치는 중…" and _fix_reqs().size() == 2, "label: 2 / 3 문장 고치는 중…")
	await _release()
	wl = _find(s, "WorkLabel") as Label
	ok(wl != null and wl.text == "3 / 3 문장 고치는 중…" and _fix_reqs().size() == 3, "label: 3 / 3 문장 고치는 중…")
	await _release()
	_hold = false
	# result
	ok(s.stage == "result", "result screen")
	ok(_count(s, "ResultCard") == 3, "three result cards (%d)" % _count(s, "ResultCard"))
	var rt: String = _joined(s)
	ok(rt.contains("쓴 것") and rt.contains("고침") and rt.contains("이유"), "cards have 쓴 것 / 고침 / 이유")
	ok(rt.contains(FIX_JA[0]) and rt.contains("과거형과 정중체로 맞췄어요."), "the fixed sentence and the reason are shown")
	ok(rt.contains(RD_JA[0]), "the reading is shown (ReadingLine)")
	ok(rt.contains("きのう ともだちと えいがをみた。"), "the original sentence is shown")
	var cm: Label = _find(s, "CardsMsg") as Label
	ok(cm != null and cm.text == "✓ 복습 카드에 넣었어요 (3개)", "✓ 복습 카드에 넣었어요 (3개)")
	ok(Store.progress["review"].size() == 3, "3 review cards were added")
	ok(_btn(s, "AgainBtn") != null and _btn(s, "ListBtn") != null, "[다시 쓰기] and [일기 목록] are shown")
	await _shot("03_result.png")
	# [일기 목록]
	_press(_btn(s, "ListBtn"), "일기 목록")
	await _frames(3)
	ok(s.stage == "home", "back on the home screen with the list")
	ok(_joined(s).contains("고침 완료"), "the list shows 고침 완료")
	ok(_find(s, "PendingChip") == null, "no pending chip: nothing waits")
	# [보기]
	_press(_btn(s, "ViewBtn"), "보기")
	await _frames(3)
	ok(s.stage == "view" and _count(s, "ResultCard") == 3, "[보기] shows the three result cards again")
	ok(_find(s, "CardsMsg") == null, "the card message is only for the fresh result")
	_press(_btn(s, "ListBtn"), "일기 목록 (from view)")
	await _frames(3)
	# [지우기] -> sheet -> [지우기]
	_press(_btn(s, "DeleteBtn"), "지우기")
	await _frames(3)
	ok(Sheet.is_open() and s.last_sheet != null, "the confirm sheet is shown")
	ok(DiaryStore.entries().size() == 1, "nothing is deleted yet")
	_press(s.last_sheet.buttons["ok"], "지우기 (sheet)")
	await _frames(3)
	ok(DiaryStore.entries().is_empty() and _find(s, "EmptyList") != null, "the entry is deleted")
	ok(Store.progress["review"].size() == 3, "the review cards stay (the sheet said so)")
	# second round: no sheet, [다시 쓰기], single sentence, then [일기 모두 지우기]
	_hold = true
	_type(s, "あした やすみ。")
	await _frames(2)
	_press(_btn(s, "FixBtn"), "고쳐 보기 (2nd, no sheet)")
	await _frames(3)
	ok(not Sheet.is_open() and s.stage == "working" and s.consent_asks == 1, "the consent sheet does not come again")
	ok((_find(s, "WorkLabel") as Label).text == "1 / 1 문장 고치는 중…", "label: 1 / 1")
	await _release()
	_hold = false
	ok(s.stage == "result", "second result")
	_press(_btn(s, "AgainBtn"), "다시 쓰기")
	await _frames(3)
	ok(s.stage == "home" and s._edit.text == "" and _btn(s, "FixBtn").disabled, "[다시 쓰기]: an empty box and the buttons off again")
	_type(s, "ともだちと あそんだ。")
	await _frames(2)
	_press(_btn(s, "SaveBtn"), "저장만 하기 (flow A)")
	await _frames(3)
	ok(DiaryStore.entries("ja").size() == 2 and DiaryStore.pending("ja").size() == 1, "one fixed and one saved-only entry in the list")
	_press(_btn(s, "ViewBtn"), "보기 (flow A, 2nd)")
	await _frames(3)
	ok(s.stage == "view", "[보기] of the newest entry")
	_press(_btn(s, "ListBtn"), "일기 목록 (flow A, 2nd)")
	await _frames(3)
	_press(_btn(s, "ClearAllBtn"), "일기 모두 지우기")
	await _frames(3)
	ok(Sheet.is_open(), "the clear-all confirm sheet is shown")
	_press(s.last_sheet.buttons["ok"], "모두 지우기 (sheet)")
	await _frames(3)
	ok(DiaryStore.entries().is_empty() and _find(s, "ClearAllBtn") == null, "[일기 모두 지우기] clears the diary")
	print("flow A presses: ", _presses)
	ok(_presses >= 12, "flow A pressed at least 12 buttons (%d)" % _presses)
	ok(_fix_reqs().size() == 4, "flow A sent 4 /fix requests in all (3 + 1): %d" % _fix_reqs().size())


# ---------------------------------------------------------------- flow B

func _flow_b() -> void:
	print("[flow B: no AI, save only, fix later]")
	_fresh()
	DiaryScreen.ai_hook = func() -> String: return "no_pc"
	DiaryScreen.stt_hook = Callable() # the real rule: no PC connected -> no voice input
	var s := _make("ja")
	await _frames(3)
	ok(not DiaryScreen.stt_ok(), "no PC: voice input is not available")
	ok(_find(s, "MicBtn") == null and _find(s, "NoMicNote") != null, "[말해서 쓰기] is hidden and a one-line note is shown")
	var text := "きのう ともだちと えいがをみた。きょうは あめだった。"
	_type(s, text)
	await _frames(2)
	ok(_btn(s, "FixBtn").disabled, "[고쳐 보기] is off")
	var note: Label = _find(s, "AiNote") as Label
	ok(note != null and note.text == DiaryScreen.NOTE_NO_PC, "one reason line: " + (note.text if note != null else "none"))
	ok(_btn(s, "SaveBtn").text == "저장만 하기" and not _btn(s, "SaveBtn").disabled, "[저장만 하기] is on")
	_press(_btn(s, "SaveBtn"), "저장만 하기")
	await _frames(3)
	ok(DiaryStore.entries("ja").size() == 1 and DiaryStore.entries("ja")[0]["state"] == "saved", "saved, waiting for the AI")
	ok(s._edit.text == "", "the box is empty after saving")
	var pc: Node = _find(s, "PendingChip")
	ok(pc != null and _joined(pc) == "고치기 대기 1개", "the list shows 고치기 대기 1개")
	ok(_joined(s).contains("고치기 대기"), "the entry says 고치기 대기")
	ok(_btn(s, "FixEntryBtn") != null and _btn(s, "FixEntryBtn").disabled, "the list [고치기] is off while there is no AI")
	ok(_fix_reqs().is_empty(), "nothing was sent")
	await _shot("04_list_saved.png")
	# another entry is saved only, viewed, and deleted
	_type(s, "あした やすみ。")
	await _frames(2)
	_press(_btn(s, "SaveBtn"), "저장만 하기 (2nd)")
	await _frames(3)
	ok(DiaryStore.pending("ja").size() == 2 and _joined(_find(s, "PendingChip")) == "고치기 대기 2개", "two waiting")
	# the AI comes back
	DiaryScreen.ai_hook = func() -> String: return "ready"
	s.refresh()
	await _frames(3)
	ok(_btn(s, "FixBtn").disabled and _btn(s, "FixEntryBtn") != null and not _btn(s, "FixEntryBtn").disabled, "AI ready: the list [고치기] turns on")
	_press(_btn(s, "ViewBtn"), "보기 (a waiting entry)")
	await _frames(3)
	ok(s.stage == "view" and _joined(s).contains("아직 고치지 않은 일기예요"), "a waiting entry is shown as not fixed yet")
	_press(_btn(s, "ListBtn"), "일기 목록")
	await _frames(3)
	_press(_btn(s, "FixEntryBtn"), "고치기")
	await _frames(3)
	ok(Sheet.is_open() and s.consent_asks == 1 and _fix_reqs().is_empty(), "the consent sheet comes first (consent was never given)")
	_press(s.last_sheet.buttons["agree"], "동의하고 고치기")
	await _frames(5)
	ok(s.stage == "result" and _count(s, "ResultCard") == 1, "fixed: the result is shown")
	ok(_fix_reqs().size() == 1 and _body_private(_fix_reqs()[0]["body"]), "one request, with private:true")
	_press(_btn(s, "ListBtn"), "일기 목록 (after fix)")
	await _frames(3)
	var states: Array = []
	for st in ["고침 완료", "고치기 대기"]:
		states.append(_joined(s).contains(st))
	ok(states == [true, true], "the list has one 고침 완료 and one 고치기 대기")
	ok(_joined(_find(s, "PendingChip")) == "고치기 대기 1개", "the pending chip counts 1")
	# delete the waiting one
	var rows: Array = DiaryStore.pending("ja")
	ok(rows.size() == 1, "one is still waiting")
	var del: Button = _find(s, "Entry_" + str(rows[0]["id"])).find_child("DeleteBtn", true, false) as Button
	_press(del, "지우기 (the waiting one)")
	await _frames(3)
	_press(s.last_sheet.buttons["ok"], "지우기 (sheet)")
	await _frames(3)
	ok(DiaryStore.pending("ja").is_empty() and DiaryStore.entries("ja").size() == 1, "the waiting entry is gone, the fixed one stays")
	print("flow B presses: ", _presses)
	ok(_presses >= 8, "flow B pressed at least 8 buttons (%d)" % _presses)
	ok(_min_button_h(s) >= Ds.touch_min() - 0.5, "every button is at least %.1f high" % Ds.touch_min())


func _body_private(b: Variant) -> bool:
	return b is Dictionary and (b as Dictionary).get("private", null) == true and typeof((b as Dictionary).get("private", null)) == TYPE_BOOL


# ---------------------------------------------------------------- flow C (marker)

func _flow_c() -> void:
	print("[flow C: a unique marker in the diary, nothing but the diary file keeps it]")
	_fresh()
	_hold = true
	var s := _make("ja")
	await _frames(3)
	var text := MARK + "きのう えいがを みた。きょう " + MARK + " あめ。"
	_type(s, text)
	await _frames(2)
	_press(_btn(s, "FixBtn"), "고쳐 보기 (marker)")
	await _frames(3)
	_press(s.last_sheet.buttons["agree"], "동의하고 고치기 (marker)")
	await _frames(3)
	ok(s.stage == "working", "working")
	await _release()
	await _release()
	_hold = false
	ok(s.stage == "result", "result")
	_press(_btn(s, "ListBtn"), "일기 목록 (marker)")
	await _frames(3)
	_press(_btn(s, "ViewBtn"), "보기 (marker)")
	await _frames(3)
	_press(_btn(s, "ListBtn"), "일기 목록 (marker, 2)")
	await _frames(3)
	# a second marker diary only saved
	_type(s, MARK + "ほぞんだけ。")
	await _frames(2)
	_press(_btn(s, "SaveBtn"), "저장만 하기 (marker)")
	await _frames(3)
	ok(DiaryStore.entries("ja").size() == 2, "two marker entries are stored")
	StudyLog.flush()
	await _frames(2)
	ok(_file_has_mark(P_DIARY), "the diary file does hold the text (so the scan can find it)")
	ok(not JSON.stringify(Store.progress).contains(MARK), "Store.progress (memory) has no marker")
	ok(not _file_has_mark(P_PROG), "the progress file has no marker")
	ok(not JSON.stringify(Store.prefs).contains(MARK) and not _file_has_mark(P_PREFS), "prefs (memory and file) have no marker")
	ok(not JSON.stringify(StudyLog.snapshot()).contains(MARK) and not _file_has_mark(P_LOG), "studylog (memory and file) has no marker")
	var hits: Array = _files_with_mark("user://", [P_DIARY, P_DIARY + ".tmp"])
	ok(hits.is_empty(), "no other file under user:// has the marker (%d)" % hits.size())
	var dump := ""
	for r in Store.progress["review"]:
		dump += JSON.stringify(r)
	ok(Store.progress["review"].size() == 2 and not dump.contains(MARK), "the 2 review cards have no marker (the fixed sentences only)")
	var toast_hits := 0
	for t in _toasts:
		if str(t).contains(MARK):
			toast_hits += 1
	ok(toast_hits == 0, "no toast carried the marker")
	var bodies_ok := _fix_reqs().size() == 2 and _fix_reqs().all(func(r: Dictionary) -> bool: return _body_private(r["body"]))
	ok(bodies_ok, "the two /fix requests carried private:true")
	ok(not _reqs.any(func(r: Dictionary) -> bool: return str(r["path"]).begins_with("/tts")), "no /tts request: the diary is never read aloud")
	print("flow C presses: ", _presses)


# ---------------------------------------------------------------- flow D (old server)

func _flow_d() -> void:
	print("[flow D: an old PC program answers without reading]")
	_fresh()
	_queue = [{"fix": "昨日、友達と映画を見ました。", "fix_ko": "고쳤어요."}]
	var s := _make("ja")
	await _frames(3)
	_type(s, "きのう ともだちと えいがをみた。きょうは あめだった。")
	await _frames(2)
	_press(_btn(s, "FixBtn"), "고쳐 보기 (old server)")
	await _frames(3)
	_press(s.last_sheet.buttons["agree"], "동의하고 고치기 (old server)")
	await _frames(4)
	ok(s.stage == "home" and _find(s, "OldServerNote") != null, "the notice about the old PC program is shown")
	ok(_joined(_find(s, "OldServerNote")) == DiaryScreen.OLD_SERVER_PRIVACY, "text: " + DiaryScreen.OLD_SERVER_PRIVACY)
	ok(_fix_reqs().size() == 1, "only one sentence was sent")
	ok(_btn(s, "FixBtn").disabled and _btn(s, "FixEntryBtn").disabled, "no more fixing until the PC program is updated")
	_press(_btn(s, "SaveBtn"), "저장만 하기 (old server)")
	await _frames(3)
	ok(_fix_reqs().size() == 1 and DiaryStore.pending("ja").size() == 1, "saving still works and sends nothing")


# ---------------------------------------------------------------- flow E (cancel)

func _flow_e() -> void:
	print("[flow E: cancel while fixing]")
	_fresh()
	Store.prefs["diary_consent"] = true
	_hold = true
	var s := _make("ja")
	await _frames(3)
	_type(s, "きのう えいがをみた。きょう あめだった。")
	await _frames(2)
	_press(_btn(s, "FixBtn"), "고쳐 보기 (to cancel)")
	await _frames(3)
	ok(s.stage == "working", "working")
	_press(_btn(s, "CancelBtn"), "취소")
	await _frames(2)
	_hold = false
	_go.emit()
	await _frames(3)
	ok(s.stage == "home" and _joined(s).contains("취소했어요"), "[취소]: back on the home screen with a note")
	ok(DiaryStore.pending("ja").size() == 1 and _fix_reqs().size() == 1, "[취소]: the entry waits, no second request")
	ok(s._edit.text.length() > 0, "[취소]: the text is kept")
	ok(Store.progress["review"].is_empty(), "[취소]: no review cards")
	# fix it from the list
	_press(_btn(s, "FixEntryBtn"), "고치기 (after cancel)")
	await _frames(5)
	ok(s.stage == "result" and DiaryStore.pending("ja").is_empty(), "fixed from the list after the cancel")


# ---------------------------------------------------------------- flow F (a 1.6.x PC program: /health has no fix_private)

func _flow_f() -> void:
	print("[flow F: the PC program is old (no fix_private): nothing is sent, saving works, the update makes fixing work]")
	_fresh()
	Backend.health = {"llm": true}
	var s := _make("ja")
	await _frames(3)
	var text := MARK + "きのう ともだちと えいがをみた。きょうは あめだった。"
	_type(s, text)
	await _frames(2)
	ok(_btn(s, "FixBtn").disabled, "[고쳐 보기] is off")
	var note: Label = _find(s, "OldPcNote") as Label
	ok(note != null and note.text.contains(DiaryScreen.OLD_SERVER_PRIVACY), "the old PC program notice is shown: " + (note.text if note != null else "none"))
	var before: int = _reqs.size()
	_press(_btn(s, "SaveBtn"), "저장만 하기 (old PC)")
	await _frames(3)
	ok(DiaryStore.pending("ja").size() == 1 and _reqs.size() == before, "saved, 0 requests")
	ok(_btn(s, "FixEntryBtn") != null and _btn(s, "FixEntryBtn").disabled, "the list [고치기] is off")
	ok(not Sheet.is_open() and s.consent_asks == 0, "no consent sheet: nothing could be sent")
	ok(_fix_reqs().is_empty() and _reqs.is_empty(), "0 requests of any kind on the whole screen")
	# the user updates the PC program: the health now has the flag
	Backend.health = {"llm": true, "fix_private": true}
	s.refresh()
	await _frames(3)
	ok(_find(s, "OldPcNote") == null and not _btn(s, "FixEntryBtn").disabled, "after the update the list [고치기] turns on")
	_press(_btn(s, "FixEntryBtn"), "고치기 (updated PC)")
	await _frames(3)
	if s.last_sheet != null and is_instance_valid(s.last_sheet) and s.last_sheet.buttons.has("agree"):
		_press(s.last_sheet.buttons["agree"], "동의하고 고치기 (updated PC)")
	await _frames(5)
	ok(s.stage == "result" and _fix_reqs().size() == 2, "fixed with 2 requests (one per sentence)")
	ok(_fix_reqs().all(func(r: Dictionary) -> bool: return _body_private(r["body"])), "both with private:true")


# ---------------------------------------------------------------- final

func _final_checks() -> void:
	print("[whole run]")
	var fixes: Array = _all_reqs.filter(func(r: Dictionary) -> bool: return r["path"] == "/fix")
	var bad := 0
	for r in fixes:
		var b: Dictionary = r["body"]
		var t: String = str(b.get("text", ""))
		if not _body_private(b) or t == "" or t.length() > DiaryLogic.MAX_SENTENCE_CHARS or str(b.get("prev_ai", "x")) != "":
			bad += 1
	ok(fixes.size() >= 10 and bad == 0, "all %d /fix requests of the run carried private:true, one short sentence and an empty prev_ai (%d bad)" % [fixes.size(), bad])
	ok(not _all_reqs.any(func(r: Dictionary) -> bool: return str(r["path"]).begins_with("/tts")), "no /tts request in the whole run")
	ok(_tts_events == 0, "Tts never started in the whole run (%d events)" % _tts_events)
	ok(not _all_reqs.any(func(r: Dictionary) -> bool: return r["path"] != "/fix"), "only /fix was requested")
