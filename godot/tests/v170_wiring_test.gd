extends Node
## 1.7.0 W: 허브·홈 연결 시험 (docs/v170_design.md §4.2 W-1 .. W-10, 공통 C-14·C-15). scenes/main.tscn 이 진짜 현재 장면이다(fun_wiring_test 와 같은 방식).
##   PC:   godot --headless --path godot res://tests/v170_wiring_test.tscn -- --api=http://127.0.0.1:9
##   폰:   godot --headless --path godot --resolution 412x915 res://tests/v170_wiring_test.tscn -- --phone --api=http://127.0.0.1:9 [--font-scale=1.5] [--dark]
## (APPDATA 는 임시 폴더로 바꿔 실행한다. 시험 전용 파일 user://test_v170_w_* 만 쓴다.)
## 하는 일: 허브 카드 7개와 순서·KINDS, 일본어 허브(약한 소리 켜짐), 홈 [일기] 버튼, 약한 소리 칩, pending 소비, 잘못된 입력, 일기 저장·고침 직후 배지 평가
##   (diary_first 토스트 1회), 구서버에서 일기 요청 0건([말해서 쓰기]도 꺼짐), 읽기 줄 중복(ReadingLine).
## 흐름은 실제 버튼의 pressed 신호만 누른다. 누를 때마다 `press: <버튼>` 줄을 찍고, 누르기 전에 보이고 켜져 있는지 단언한다.
## 일본어 받아쓰기 카드는 켜져 있고 누르면 DictationScreen 이 ja 로 열린다(A4 합침 뒤).
## 마지막 줄: "== v170_wiring: N passed, M failed ==" (실패가 있으면 종료 코드 1)

const MARK := "ZZ_MARK_9731"
const P_PROG := "user://test_v170_w_progress.json"
const P_PREFS := "user://test_v170_w_prefs.json"
const P_LOG := "user://test_v170_w_studylog.json"
const P_DIARY := "user://test_v170_w_diary.json"
const HUB_ORDER := ["mission", "shadow", "dictation", "phoneme", "kana", "speed", "diary"]
const FIX_JA := "昨日、友達と映画を見ました。"
const RD_JA := "きのう、ともだちとえいがをみました。"
const FIRST_TOAST := "배지를 받았어요: 첫 일기 고침"

var passed: int = 0
var failed: int = 0
var _phone: bool = false
var _scale: float = 1.0
var _dark: bool = false
var _main: Control
var _toasts: Array = []
var _activity_kinds: Array = []
var _presses: int = 0
var _reqs: Array = []
var _fake_ms: int = 0
var _saved_paths: Dictionary = {}


func ok(cond: bool, name: String) -> void:
	if cond:
		passed += 1
		print("  PASS  ", name)
	else:
		failed += 1
		print("  FAIL  ", name)


## 검사기가 틀린 입력을 실제로 거절하는지: judged 가 true 면(= 잘못된 입력이 통과했다면) 실패다.
func selfcheck(judged: bool, name: String) -> void:
	if judged:
		failed += 1
		print("  FAIL  selfcheck: the wrong input passed: ", name)
	else:
		passed += 1
		print("  PASS  selfcheck FAIL-as-expected: ", name)


func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


func _wait(sec: float) -> void:
	await get_tree().create_timer(sec).timeout


func _has_arg(prefix: String) -> bool:
	for a in OS.get_cmdline_user_args():
		if a.begins_with(prefix):
			return true
	return false


func _on_toast(text: String, _kind: String) -> void:
	_toasts.append(text)


func _count_toast(text: String) -> int:
	return _toasts.filter(func(t: Variant) -> bool: return str(t) == text).size()


func _rm(path: String) -> void:
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


# ---------------------------------------------------------------- start

func _ready() -> void:
	_phone = Platform.is_phone()
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--font-scale=") and a.substr(13).is_valid_float():
			_scale = a.substr(13).to_float()
		elif a == "--dark":
			_dark = true
	if not _has_arg("--api="):
		print("refusing to run: pass --api=http://127.0.0.1:9 after the --")
		get_tree().quit(1)
		return
	print("== v170_wiring start (%s, scale %s%s) ==" % ["phone" if _phone else "pc", str(_scale), ", dark" if _dark else ""])
	var want := Vector2i(412, 915) if _phone else Vector2i(1280, 800)
	get_window().min_size = Vector2i.ZERO
	get_window().size = want
	UiBoot.apply(get_window(), "dark" if _dark else "light", _scale) # main leaves a scheme that was applied first alone
	await _frames(2)
	_saved_paths = {"diary": DiaryStore.path}
	Store.progress_path = P_PROG
	Store.prefs_path = P_PREFS
	StudyLog.path = P_LOG
	DiaryStore.path = P_DIARY
	for p in [P_PROG, P_PREFS, P_LOG, P_DIARY]:
		_rm(p)
		_rm(p + ".tmp")
	DiaryStore.forget()
	StudyLog.load_from_disk()
	StudyLog.reset()
	Store.load_prefs()
	Store.progress = Progress.blank()
	Store.prefs["lang"] = "en"
	Store.prefs["auto_speak"] = false
	Store.prefs["show_reading"] = true
	Store.prefs["show_hangul_ja"] = true
	Store.prefs["diary_consent"] = false
	Store.prefs["auto_fix_cards"] = false # no review card: nothing but the activity signal can start the badge evaluation after a fix
	Backend._starting = true # never launch or poll the real engine
	Backend.set_process(false)
	Backend.health = {"llm": true, "fix_private": true}
	DiaryScreen.ai_hook = func() -> String: return "ready"
	DiaryScreen.stt_hook = func() -> bool: return true
	DiaryScreen.old_server_seen = false
	DiaryStore.today_override = Plan.days_from_civil(2026, 11, 14)
	DiaryStore.unix_override = 1731571200
	Sheet.animate = false
	SpeakDrill.api_hook = Callable(self, "_api")
	PracticeView.pending = {}
	Toast.message.connect(_on_toast)
	Store.activity.connect(func(k: String) -> void: _activity_kinds.append(k))

	get_tree().current_scene = null
	get_tree().change_scene_to_file("res://scenes/main.tscn")
	for i in 30:
		await get_tree().process_frame
		if get_tree().current_scene != null:
			break
	_main = get_tree().current_scene
	ok(_main != null and _main.has_method("tab_keys"), "main.tscn is the running scene")
	if _main == null:
		_finish()
		return
	_main.quit_on_exit = false
	await _frames(4)
	var w: BadgeWatcher = _watcher()
	w.clock = func() -> int: return _fake_ms
	_fake_ms = 100000

	await _test_hub_cards()
	await _test_home_button()
	await _test_hub_flow()
	await _test_chips()
	await _test_pending()
	await _test_wrong_inputs()
	await _test_diary_badge()
	await _test_diary_old_server()
	await _test_reading_line()
	await _test_talk_reading()
	await _test_numbers_visible()
	_test_dictation_chips()
	_selfchecks()
	_finish()


func _finish() -> void:
	print("press count: ", _presses)
	Toast.message.disconnect(_on_toast)
	SpeakDrill.api_hook = Callable()
	DiaryScreen.ai_hook = Callable()
	DiaryScreen.stt_hook = Callable()
	DiaryScreen.old_server_seen = false
	DiaryStore.today_override = -1
	DiaryStore.unix_override = -1
	DiaryStore.path = str(_saved_paths.get("diary", "user://diary.json"))
	DiaryStore.forget()
	StudyLog.reset()
	for p in [P_PROG, P_PREFS, P_LOG, P_DIARY]:
		_rm(p)
		_rm(p + ".tmp")
	print("== v170_wiring: %d passed, %d failed ==" % [passed, failed])
	get_tree().quit(1 if failed > 0 else 0)


func _watcher() -> BadgeWatcher:
	for c in _main.get_children():
		if c is BadgeWatcher:
			return c
	return null


# ---------------------------------------------------------------- fake server (일기 /fix 만)

func _api(method: String, path: String, body: Variant) -> Variant:
	_reqs.append({"method": method, "path": path, "body": (body as Dictionary).duplicate(true) if body is Dictionary else body})
	if path == "/fix":
		return {"fix": FIX_JA, "fix_ko": "과거형과 정중체로 맞췄어요.", "reading": RD_JA, "pron": "キノー、トモダチ"}
	if path == "/practice/ping":
		return {"ok": true, "practice": 1, "missions": 1, "tatoeba": true}
	return {"ok": false, "code": 404, "data": null, "error": "no route", "err_code": ""}


func _reqs_for(prefix: String) -> int:
	return _reqs.filter(func(r: Dictionary) -> bool: return str(r["path"]).begins_with(prefix)).size()


# ---------------------------------------------------------------- helpers

func _pv() -> PracticeView:
	return _main.views["practice"]


func _tv() -> TodayView:
	return _main.views["today"]


func _set_lang(l: String) -> void:
	Store.set_lang(l)


## 단계마다: 이 버튼이 보이고 켜져 있어야 한다. 그 뒤 pressed 신호를 낸다 (REVIEW.md: 실제 버튼만 누른다).
func _press(b: Button, label: String) -> bool:
	var good: bool = _pressable(b)
	ok(good, "visible and enabled before the press: " + label)
	if not good:
		return false
	_presses += 1
	print("press: ", label)
	b.pressed.emit()
	return true


func _pressable(b: Button) -> bool:
	return b != null and is_instance_valid(b) and b.is_visible_in_tree() and not b.disabled


## 하위 화면의 ← 버튼.
func _back_button(screen: Control) -> Button:
	if screen == null:
		return null
	var sh: Variant = screen.get("_shell")
	if sh is Dictionary and (sh as Dictionary).get("back", null) is Button:
		return (sh as Dictionary)["back"] as Button
	for b in screen.find_children("*", "Button", true, false):
		if (b as Button).text.begins_with("←") and (b as Button).is_visible_in_tree():
			return b as Button
	return null


## ← 버튼을 눌러 허브로 돌아온다(여러 단계면 반복). 눌러 본 횟수를 돌려준다.
func _back_to_hub(label: String) -> int:
	var n := 0
	var pv := _pv()
	while pv.current_screen() != null and n < 6:
		var bb: Button = _back_button(pv.current_screen())
		if not _press(bb, "%s: ← (%d)" % [label, n + 1]):
			break
		n += 1
		await _frames(3)
	return n


func _open_hub(l: String) -> void:
	_set_lang(l)
	_main.show_view("practice")
	_pv().refresh()
	await _frames(4)


func _fun_button(kind: String) -> Button:
	var fun: Control = _tv().card("fun")
	if fun == null:
		return null
	return (fun.get_meta("buttons") as Dictionary).get(kind, null)


func _labels_text(root: Node) -> String:
	var out: Array = []
	_collect(root, out)
	return "\n".join(PackedStringArray(out))


func _collect(node: Node, out: Array) -> void:
	for c in node.get_children():
		if c is Control and not (c as Control).visible:
			continue
		if c is Label:
			out.append((c as Label).text)
		elif c is Button:
			out.append((c as Button).text)
		_collect(c, out)


func _count_label(root: Node, text: String) -> int:
	var n := 0
	for l in root.find_children("*", "Label", true, false):
		if (l as Label).text == text and (l as Label).is_visible_in_tree():
			n += 1
	return n


## W-3 의 검사 함수: 카드 순서가 정해진 일곱 개이고 KINDS 와 서로 같은 것을 담는다.
func _hub_order_ok(kinds: Array, kinds_const: Array) -> bool:
	if kinds != HUB_ORDER:
		return false
	for k in kinds:
		if not kinds_const.has(k):
			return false
	for k in kinds_const:
		if not kinds.has(k):
			return false
	return true


# ---------------------------------------------------------------- W-3, W-4

func _test_hub_cards() -> void:
	print("[W-3 W-4: hub cards]")
	await _open_hub("en")
	var pv := _pv()
	ok(_hub_order_ok(pv.card_kinds(), PracticeView.KINDS), "W-3: hub cards %s are in order and match PracticeView.KINDS" % str(pv.card_kinds()))
	ok(PracticeView.KINDS == HUB_ORDER, "W-3: KINDS is %s" % str(PracticeView.KINDS))
	for k in pv.card_kinds():
		ok(PracticeView.KINDS.has(k) and pv._make_screen(k) != null, "W-3: card %s is in KINDS and builds a screen" % k)
	ok(pv._make_screen("nope") == null, "W-3: an unknown kind builds no screen")
	# 영어 탭
	var en_text: String = _labels_text(pv)
	ok(not (pv._cards["phoneme"] as Button).disabled and not (pv._cards["dictation"] as Button).disabled and not (pv._cards["diary"] as Button).disabled, "W-4: english: weak sounds, dictation and diary are on")
	ok((pv._cards["kana"] as Button).disabled, "W-4: english: the kana card is off")
	ok(not en_text.contains("영어만 지원해요"), "W-4: english: no 'english only' text")
	# 일본어 탭
	await _open_hub("ja")
	var ja_text: String = _labels_text(pv)
	ok(not (pv._cards["phoneme"] as Button).disabled, "W-4: japanese: weak sounds are on")
	ok(not (pv._cards["kana"] as Button).disabled and not (pv._cards["mission"] as Button).disabled and not (pv._cards["shadow"] as Button).disabled and not (pv._cards["diary"] as Button).disabled, "W-4: japanese: kana, mission, shadow, diary are on")
	ok(not (pv._cards["dictation"] as Button).disabled, "W-4: japanese: dictation is on")
	ok(not ja_text.contains("약한 소리 연습은 영어만"), "W-4: japanese: weak sounds have no 'english only' text")
	ok(not ja_text.contains("영어만 지원해요"), "W-4: japanese: no 'english only' text anywhere on the hub")
	ok(ja_text.contains("길게 끄는 소리") and not ja_text.contains("자주 틀리는 소리만"), "W-4: japanese: the weak sounds card has the Japanese description")


# ---------------------------------------------------------------- W-7, W-2 (홈 → 일기)

func _test_home_button() -> void:
	print("[W-7 W-2: home [일기] button]")
	_set_lang("en")
	_main.show_view("today")
	_tv().refresh()
	await _frames(4)
	var tv := _tv()
	var fun: Control = tv.card("fun")
	ok(fun != null, "W-7: the home has the fun card")
	if fun == null:
		return
	var bs: Dictionary = fun.get_meta("buttons")
	ok(bs["speed"] != null and bs["diary"] != null and bs["badges"] != null and bs["kana"] == null, "W-7: english: 60초 퀴즈, 일기, 배지, no 가나 코스")
	ok((bs["diary"] as Button).text == "일기", "W-7: the diary button reads 일기")
	if is_equal_approx(_scale, 1.0):
		ok(tv.hero_button() != null and tv.hero_button().get_global_rect().position.y <= 480.0, "W-7: the start button is still at y <= 480")
		var rc: Control = tv.card("resume")
		if rc != null:
			ok(rc.get_global_rect().position.y < 859.0, "W-7: the resume card is still above y 859")
	# 일본어: 4개
	_set_lang("ja")
	tv.refresh()
	await _frames(4)
	fun = tv.card("fun")
	bs = fun.get_meta("buttons")
	ok(bs["kana"] != null and bs["diary"] != null, "W-7: japanese: 60초 퀴즈, 가나 코스, 일기, 배지")
	# [일기] -> 연습 탭의 일기 화면
	_press(_fun_button("diary"), "home: [일기]")
	await _frames(5)
	var pv := _pv()
	ok(_main.current == "practice" and pv.current_screen() is DiaryScreen, "W-2: [일기] opens the diary screen in the practice tab (%s, %s)" % [_main.current, str(pv.current_screen())])
	ok(PracticeView.pending.is_empty(), "W-2: the pending request was used up")
	if pv.current_screen() is DiaryScreen:
		ok((pv.current_screen() as DiaryScreen).lang == "ja", "W-2: the diary opens in the home's language (ja)")
	await _back_to_hub("diary (from home)")
	ok(pv.current_screen() == null and _main.current == "practice", "W-2: the diary's ← button returns to the hub")
	_main.show_view("today")
	await _frames(2)


# ---------------------------------------------------------------- W-2: 허브 카드 흐름 (실제 버튼)

func _test_hub_flow() -> void:
	print("[W-2: hub card buttons]")
	var pv := _pv()
	# 영어: [약한 소리] -> PhonemeScreen
	await _open_hub("en")
	_press(pv._cards["phoneme"] as Button, "hub en: [약한 소리 연습]")
	await _frames(4)
	ok(pv.current_screen() is PhonemeScreen, "W-2: english [약한 소리] opens PhonemeScreen (%s)" % str(pv.current_screen()))
	await _back_to_hub("phoneme en")
	ok(pv.current_screen() == null, "W-2: ← returns to the hub (phoneme en)")
	# 일본어: [약한 소리] -> JaSoundScreen (소리 목록)
	await _open_hub("ja")
	_press(pv._cards["phoneme"] as Button, "hub ja: [약한 소리 연습]")
	await _frames(4)
	var js: Control = pv.current_screen()
	ok(js is JaSoundScreen and (js as JaSoundScreen).stage == "list", "W-2: japanese [약한 소리] opens JaSoundScreen at the list (%s)" % [str((js as JaSoundScreen).stage) if js is JaSoundScreen else "-"])
	await _back_to_hub("phoneme ja")
	ok(pv.current_screen() == null, "W-2: ← returns to the hub (phoneme ja)")
	# 일본어: [롤플레이 미션] -> 일본어 미션 화면
	_press(pv._cards["mission"] as Button, "hub ja: [미션 고르기]")
	await _frames(6)
	var ms: Control = pv.current_screen()
	ok(ms is MissionScreen and (ms as MissionScreen).lang == "ja", "W-2: japanese [미션 고르기] opens MissionScreen in ja (%s)" % [str((ms as MissionScreen).lang) if ms is MissionScreen else "-"])
	if ms is MissionScreen and (ms as MissionScreen).status == "list":
		var all_ja := not (ms as MissionScreen).missions.is_empty()
		for m in (ms as MissionScreen).missions:
			all_ja = all_ja and str((m as Dictionary).get("id", "")).begins_with("ja_")
		ok(all_ja, "W-2: the mission list of the japanese tab holds only japanese missions")
	await _back_to_hub("mission ja")
	ok(pv.current_screen() == null, "W-2: ← returns to the hub (mission ja)")
	# 일본어: [받아쓰기] -> DictationScreen 이 ja 로 열린다 (일본어 소리가 있어야 하므로 Tts.fetch_hook 을 켠다)
	var db: Button = pv._cards["dictation"] as Button
	Tts.fetch_hook = func(_t: String, _l: String, _sp: float, _v: String) -> Variant: return null
	var dreq0: int = _reqs_for("/practice/sentences")
	_press(db, "hub ja: [받아쓰기 시작]")
	await _frames(6)
	var ds: Control = pv.current_screen()
	ok(ds is DictationScreen and (ds as DictationScreen).lang == "ja", "W-2: japanese [받아쓰기] opens DictationScreen in ja (%s)" % [str((ds as DictationScreen).lang) if ds is DictationScreen else "-"])
	var dreqs: Array = _reqs.filter(func(r: Dictionary) -> bool: return str(r["path"]).begins_with("/practice/sentences"))
	ok(dreqs.size() == dreq0 + 1 and "lang=ja" in str(dreqs[dreqs.size() - 1]["path"]) and "mode=dictation" in str(dreqs[dreqs.size() - 1]["path"]), "W-2: ...and asks for lang=ja&mode=dictation sentences")
	await _back_to_hub("dictation ja")
	ok(pv.current_screen() == null, "W-2: ← returns to the hub (dictation ja)")
	Tts.fetch_hook = Callable()
	# 일기 카드 (일본어·영어 둘 다)
	_press(pv._cards["diary"] as Button, "hub ja: [일기 쓰기]")
	await _frames(4)
	ok(pv.current_screen() is DiaryScreen and (pv.current_screen() as DiaryScreen).lang == "ja", "W-2: the diary card opens DiaryScreen in ja")
	await _back_to_hub("diary ja")
	ok(pv.current_screen() == null, "W-2: ← returns to the hub (diary)")
	await _open_hub("en")
	_press(pv._cards["diary"] as Button, "hub en: [일기 쓰기]")
	await _frames(4)
	ok(pv.current_screen() is DiaryScreen and (pv.current_screen() as DiaryScreen).lang == "en", "W-2: the diary card opens DiaryScreen in en")
	await _back_to_hub("diary en")


# ---------------------------------------------------------------- W-5: 약한 소리 칩

func _test_chips() -> void:
	print("[W-5: japanese weak sound chips]")
	var pv := _pv()
	await _open_hub("ja")
	ok(pv._weak_buttons.is_empty() and _labels_text(pv).contains("아직 약한 소리를 찾지 못했어요"), "W-5: no data -> guidance text, no chips")
	for i in 6:
		StudyLog.add_phon_obs("ja", "j_long", i >= 4, "" if i >= 4 else "おばさん") # 4 wrong of 6 = 67%
	for i in 5:
		StudyLog.add_phon_obs("ja", "j_sokuon", i >= 2, "" if i >= 2 else "きて") # 2 wrong of 5 = 40%
	await _open_hub("ja")
	ok(pv._weak_buttons.size() == 2, "W-5: two chips from the Japanese record (%d)" % pv._weak_buttons.size())
	if pv._weak_buttons.size() == 2:
		var t0: String = (pv._weak_buttons[0] as Button).text
		var t1: String = (pv._weak_buttons[1] as Button).text
		ok(t0.contains(JaSounds.label_of("j_long")) and t0.contains("67%") and t1.contains(JaSounds.label_of("j_sokuon")) and t1.contains("40%"), "W-5: chips show JaSounds labels and the wrong rate (%s | %s)" % [t0, t1])
		_press(pv._weak_buttons[0] as Button, "hub ja: chip " + t0)
		await _frames(4)
		var js: Control = pv.current_screen()
		ok(js is JaSoundScreen and (js as JaSoundScreen).cur_p == "j_long" and (js as JaSoundScreen).stage == "detail", "W-5: the chip opens JaSoundScreen at that sound's explanation (%s)" % [str((js as JaSoundScreen).cur_p) if js is JaSoundScreen else "-"])
		await _back_to_hub("chip detail")
		ok(pv.current_screen() == null, "W-5: ← steps out of the explanation, the list, then the hub")
	# 영어 허브에는 일본어 칩이 없다 (영어 기록은 따로)
	await _open_hub("en")
	for b in pv._weak_buttons:
		ok(not (b as Button).text.contains(JaSounds.label_of("j_long")), "W-5: an english chip never shows a Japanese sound label")


# ---------------------------------------------------------------- W-6: pending 소비

func _test_pending() -> void:
	print("[W-6: pending]")
	var pv := _pv()
	await _open_hub("en")
	PracticeView.pending = {"kind": "diary"}
	pv.refresh()
	await _frames(4)
	ok(pv.current_screen() is DiaryScreen and PracticeView.pending.is_empty(), "W-6: pending diary opens the diary screen")
	# 이미 열린 화면이 있을 때도 소비한다
	await _open_hub("ja")
	PracticeView.pending = {"kind": "phoneme", "p": "j_long"}
	pv.refresh()
	await _frames(4)
	var js: Control = pv.current_screen()
	ok(js is JaSoundScreen and (js as JaSoundScreen).cur_p == "j_long" and (js as JaSoundScreen).stage == "detail" and PracticeView.pending.is_empty(), "W-6: ja pending phoneme j_long opens JaSoundScreen at that sound (replacing the open diary)")
	await _back_to_hub("pending detail")
	PracticeView.pending = {"kind": "phoneme"}
	pv.refresh()
	await _frames(4)
	js = pv.current_screen()
	ok(js is JaSoundScreen and (js as JaSoundScreen).stage == "list", "W-6: ja pending phoneme without p opens the sound list")
	await _back_to_hub("pending list")
	# 모르는 kind·모르는 p -> 허브
	for bad in [{"kind": "no_such_screen"}, {"kind": ""}, {"kind": "phoneme", "p": "θ"}, {"kind": "phoneme", "p": "zz_nope"}, {}]:
		PracticeView.pending = (bad as Dictionary).duplicate()
		pv.refresh()
		await _frames(4)
		ok(PracticeView.pending.is_empty() and pv.current_screen() == null, "W-6: ja pending %s shows the hub without an error (%s)" % [str(bad), str(pv.current_screen())])
	# 빈 p 는 소리 목록
	PracticeView.pending = {"kind": "phoneme", "p": ""}
	pv.refresh()
	await _frames(4)
	ok(pv.current_screen() is JaSoundScreen and (pv.current_screen() as JaSoundScreen).stage == "list", "W-6: ja pending phoneme with an empty p opens the sound list")
	await _back_to_hub("pending empty p")
	# 영어: 영어 화면(약한 소리) 그대로
	await _open_hub("en")
	PracticeView.pending = {"kind": "phoneme", "p": "θ"}
	pv.refresh()
	await _frames(4)
	ok(pv.current_screen() is PhonemeScreen, "W-6: en pending phoneme θ still opens PhonemeScreen")
	await _back_to_hub("pending en phoneme")


# ---------------------------------------------------------------- W-9: 잘못된 입력

func _test_wrong_inputs() -> void:
	print("[W-9: wrong inputs]")
	var pv := _pv()
	# 영어 음소를 일본어 칩 열기에 준다
	await _open_hub("ja")
	pv.open_screen("phoneme", {"p": "θ"})
	await _frames(3)
	var js: Control = pv.current_screen()
	ok(js is JaSoundScreen and (js as JaSoundScreen).stage == "list" and (js as JaSoundScreen).cur_p == "", "W-9: JaSoundScreen given an English phoneme (θ) falls back to the list")
	# 언어를 바꾸는 중에 열린 화면이 닫힌다
	_set_lang("en")
	await _frames(4)
	ok(pv.current_screen() == null and pv.card_kinds() == HUB_ORDER, "W-9: switching the language while a screen is open closes it and redraws the hub")
	await _open_hub("en")
	pv.open_screen("diary")
	await _frames(3)
	ok(pv.current_screen() is DiaryScreen, "W-9: (setup) the diary is open")
	_set_lang("ja")
	await _frames(4)
	ok(pv.current_screen() == null, "W-9: switching the language closes the diary too")
	# 열린 일기 화면이 허브로 돌아올 때 refresh 를 받는다 (쓰던 글은 그대로)
	pv.open_screen("diary")
	await _frames(3)
	var ds := pv.current_screen() as DiaryScreen
	ds._edit.text = "きのう ともだちと えいがをみた。"
	ds._edit.text_changed.emit()
	pv.refresh()
	await _frames(3)
	ok(pv.current_screen() == ds and ds._edit.text.begins_with("きのう"), "W-9: refresh() with the diary open keeps the screen and the text")
	await _back_to_hub("wrong inputs diary")
	# 허브가 안 보이는 사이 일본어 칩 데이터가 사라져도(빈 기록) 허브는 그려진다
	StudyLog.reset()
	await _open_hub("ja")
	ok(pv.card_kinds() == HUB_ORDER and pv._weak_buttons.is_empty(), "W-9: an empty record draws the hub without chips")


# ---------------------------------------------------------------- 일기 저장·고침 직후 배지 평가

func _type_into(s: DiaryScreen, text: String) -> void:
	s._edit.text = text
	s._edit.text_changed.emit()


func _test_diary_badge() -> void:
	print("[diary: badge evaluation right after save / fix]")
	StudyLog.reset()
	DiaryStore.forget()
	_rm(P_DIARY)
	Store.prefs["diary_consent"] = false
	Backend.health = {"llm": true, "fix_private": true}
	var w: BadgeWatcher = _watcher()
	var pv := _pv()
	await _open_hub("ja")
	_press(pv._cards["diary"] as Button, "badge: hub [일기 쓰기]")
	await _frames(4)
	var s := pv.current_screen() as DiaryScreen
	ok(s != null, "the diary screen is open")
	if s == null:
		return
	# 저장만 하기 -> activity "diary"
	var a0: int = _activity_kinds.size()
	var e0: int = w.eval_count
	_fake_ms += 10000
	_type_into(s, "きのう ともだちと えいがをみた。%s" % MARK)
	await _frames(2)
	_press(s.find_child("SaveBtn", true, false) as Button, "badge: [저장만 하기]")
	await _frames(3)
	ok(_activity_kinds.size() == a0 + 1 and _activity_kinds[_activity_kinds.size() - 1] == "diary", "saving a diary announces the activity \"diary\" once (%s)" % str(_activity_kinds.slice(a0)))
	await _wait(0.6)
	ok(w.eval_count == e0 + 1, "the badge watcher evaluated once because of it (%d -> %d)" % [e0, w.eval_count])
	ok(_count_toast(FIRST_TOAST) == 0, "a saved (not fixed) diary gives no diary_first toast")
	# 저장된 일기를 목록의 [고치기]로 고친다 -> diary_first 토스트 1회
	var a1: int = _activity_kinds.size()
	_fake_ms += 10000
	var fx := s.find_child("FixEntryBtn", true, false) as Button
	_press(fx, "badge: list [고치기]")
	await _frames(3)
	if s.last_sheet != null and Sheet.is_open():
		_press(s.last_sheet.buttons["agree"] as Button, "badge: consent [동의하고 고치기]")
	for i in 20:
		await _frames(3)
		if s.stage == "result":
			break
	ok(s.stage == "result", "the fix finished (stage %s)" % s.stage)
	ok(_activity_kinds.size() >= a1 + 1 and _activity_kinds[_activity_kinds.size() - 1] == "diary", "fixing a diary announces the activity \"diary\" (%s)" % str(_activity_kinds.slice(a1)))
	for i in 15:
		if _count_toast(FIRST_TOAST) > 0:
			break
		await _wait(0.2)
	ok(_count_toast(FIRST_TOAST) == 1, "the toast \"%s\" came once right after the fix (%d)" % [FIRST_TOAST, _count_toast(FIRST_TOAST)])
	ok(StudyLog.badges_got().has("diary_first") and not bool((StudyLog.badges_got()["diary_first"] as Dictionary).get("retro", true)), "diary_first is saved as a new (not retro) badge")
	# 같은 상태로 또 고쳐도 두 번째 토스트는 없다
	await _wait(0.4)
	_fake_ms += 10000
	var n_t: int = _count_toast(FIRST_TOAST)
	_press(s.find_child("AgainBtn", true, false) as Button, "badge: [다시 쓰기]")
	await _frames(3)
	_type_into(s, "あした がっこうへ いく。")
	await _frames(2)
	_press(s.find_child("FixBtn", true, false) as Button, "badge: [고쳐 보기]")
	for i in 20:
		await _frames(3)
		if s.stage == "result":
			break
	await _wait(0.6)
	ok(s.stage == "result" and _count_toast(FIRST_TOAST) == n_t, "a second fixed diary gives no second diary_first toast (%d)" % _count_toast(FIRST_TOAST))
	# 일기 원문 마커가 설정·진행·기록 파일에 없다 (일기 파일만 예외)
	var leaked: Array = []
	for p in [P_PROG, P_PREFS, P_LOG]:
		if FileAccess.file_exists(p) and FileAccess.get_file_as_string(p).contains(MARK):
			leaked.append(p)
	ok(leaked.is_empty(), "the diary text marker is in no progress / prefs / study log file (%s)" % str(leaked))
	await _back_to_hub("badge diary")


# ---------------------------------------------------------------- 구서버: 일기 요청 0건 (/fix, /stt)

func _test_diary_old_server() -> void:
	print("[old PC program: no diary request at all]")
	var pv := _pv()
	StudyLog.reset()
	DiaryStore.forget()
	_rm(P_DIARY)
	Backend.health = {"llm": true} # a 1.6.x PC program: no fix_private key
	DiaryScreen.stt_hook = func() -> bool: return true # the route says "PC with microphone support"
	DiaryScreen.ai_hook = func() -> String: return "ready"
	ok(not DiaryScreen.fix_private_ok(), "the old PC program does not know fix_private")
	ok(not DiaryScreen.stt_ok(), "stt_ok() is false for the old PC program even when the route allows /stt")
	var before_fix: int = _reqs_for("/fix")
	var before_stt: int = _reqs_for("/stt")
	await _open_hub("ja")
	_press(pv._cards["diary"] as Button, "old: hub [일기 쓰기]")
	await _frames(4)
	var s := pv.current_screen() as DiaryScreen
	ok(s != null, "the diary screen is open")
	if s != null:
		ok(s.find_child("MicBtn", true, false) == null, "[말해서 쓰기] is not offered")
		_type_into(s, "きのう ともだちと えいがをみた。")
		await _frames(2)
		var fb := s.find_child("FixBtn", true, false) as Button
		ok(fb != null and fb.disabled, "[고쳐 보기] is off")
		_press(s.find_child("SaveBtn", true, false) as Button, "old: [저장만 하기]")
		await _frames(3)
		ok(DiaryStore.entries().size() == 1, "the diary is saved only")
		await _back_to_hub("old server diary")
	ok(_reqs_for("/fix") == before_fix and _reqs_for("/stt") == before_stt, "0 /fix and 0 /stt requests while the PC program is old (%d, %d)" % [_reqs_for("/fix") - before_fix, _reqs_for("/stt") - before_stt])
	# 새 PC 프로그램이면 둘 다 켜진다
	Backend.health = {"llm": true, "fix_private": true}
	ok(DiaryScreen.stt_ok(), "stt_ok() is true for a PC program that knows fix_private")
	selfcheck(_stt_would_pass({"llm": true}), "an old PC program's health is judged 'no voice input'")
	selfcheck(_stt_would_pass({"llm": true, "fix_private": "yes"}), "a non-boolean fix_private is judged 'no voice input'")
	Backend.health = {"llm": true, "fix_private": true}


## stt_ok() 를 일부러 틀린 health 로 돌려 본다 (통과하면 true).
func _stt_would_pass(health: Dictionary) -> bool:
	var saved: Dictionary = Backend.health.duplicate(true)
	Backend.health = health.duplicate(true)
	var r: bool = DiaryScreen.stt_ok()
	Backend.health = saved
	return r


# ---------------------------------------------------------------- ReadingLine: 읽기가 원문과 같으면 히라가나 줄을 숨긴다

func _line_count(box: Control) -> int:
	return box.get_child_count() if box != null else 0


func _test_reading_line() -> void:
	print("[ReadingLine: the hiragana line that only repeats the sentence]")
	Store.prefs["show_hangul_ja"] = true
	# source 를 알려 줄 때
	var same: Control = ReadingLine.make("ありがとう", "ja", true, 0.0, "アリガトウ", "ありがとう")
	ok(same != null and _line_count(same) == 1 and ((same.get_child(0) as Label).text == ReadingLine.hangul_of("ありがとう", "アリガトウ")), "source == reading (kana only): the hiragana line is left out, the Hangul line stays")
	var diff: Control = ReadingLine.make("ありがとう", "ja", true, 0.0, "アリガトウ", "有難う")
	ok(diff != null and _line_count(diff) == 2 and (diff.get_child(0) as Label).text == "ありがとう", "source with kanji: both lines")
	var kata: Control = ReadingLine.make("こーひーをください。", "ja", true, 0.0, "コーヒーヲクダサイ。", "コーヒーをください。")
	ok(kata != null and _line_count(kata) == 2 and (kata.get_child(0) as Label).text == "こーひーをください。", "katakana sentence: the reading differs, so both lines stay")
	var spaced: Control = ReadingLine.make("きのう ともだちと", "ja", true, 0.0, "キノートモダチト", "きのうともだちと")
	ok(spaced != null and _line_count(spaced) == 1, "spaces do not make a reading different from its sentence")
	ok(ReadingLine.make("ありがとう", "ja", true, 0.0, "", "ありがとう") != null and _line_count(ReadingLine.make("ありがとう", "ja", true, 0.0, "", "ありがとう")) == 1, "the Hangul line is built from the reading when there is no pron")
	Store.prefs["show_hangul_ja"] = false
	ok(ReadingLine.make("ありがとう", "ja", true, 0.0, "アリガトウ", "ありがとう") == null, "same text + Hangul line off -> nothing at all")
	ok(_line_count(ReadingLine.make("ありがとう", "ja", true, 0.0, "アリガトウ", "有難う")) == 1, "different text + Hangul line off -> the hiragana line stays")
	Store.prefs["show_hangul_ja"] = true
	# source 를 모를 때: 위쪽 형제 라벨을 본다 (대화 말풍선 꼴)
	var host := VBoxContainer.new()
	add_child(host)
	var bub := VBoxContainer.new()
	host.add_child(bub)
	bub.add_child(_label("ありがとうございます。"))
	var rl1: Control = ReadingLine.add(bub, "ありがとうございます。", "ja", true, 0.0, "アリガトウゴザイマス。")
	var bub2 := VBoxContainer.new()
	host.add_child(bub2)
	bub2.add_child(_label("私は学生です。"))
	var rl2: Control = ReadingLine.add(bub2, "わたしはがくせいです。", "ja", true, 0.0, "ワタシワガクセイデス。")
	var bub3 := VBoxContainer.new()
	host.add_child(bub3)
	var wrap := PanelContainer.new()
	bub3.add_child(wrap)
	wrap.add_child(_label("こんにちは。"))
	var rl3: Control = ReadingLine.add(bub3, "こんにちは。", "ja", true, 0.0, "コンニチワ。")
	await _frames(3)
	ok(rl1 != null and is_instance_valid(rl1) and _line_count(rl1) == 1 and _count_label(bub, "ありがとうございます。") == 1, "in the tree: a sentence of kana shown right above hides its own hiragana reading")
	ok(rl2 != null and _line_count(rl2) == 2 and _count_label(bub2, "わたしはがくせいです。") == 1, "in the tree: a sentence with kanji keeps its hiragana reading")
	ok(rl3 != null and is_instance_valid(rl3) and _line_count(rl3) == 1, "in the tree: the sentence inside a wrapper right above is found too")
	# 위쪽이 아니라 아래쪽/다른 줄의 같은 글은 건드리지 않는다
	var bub4 := VBoxContainer.new()
	host.add_child(bub4)
	var rl4: Control = ReadingLine.add(bub4, "ありがとう", "ja", true, 0.0, "アリガトウ")
	bub4.add_child(_label("ありがとう"))
	await _frames(2)
	ok(rl4 != null and _line_count(rl4) == 2, "a label BELOW the reading does not hide it")
	# 한글 줄까지 꺼져 있고 같은 글이면 상자가 사라진다
	Store.prefs["show_hangul_ja"] = false
	var bub5 := VBoxContainer.new()
	host.add_child(bub5)
	bub5.add_child(_label("ありがとう"))
	var rl5: Control = ReadingLine.add(bub5, "ありがとう", "ja", true)
	await _frames(3)
	ok(rl5 == null or not is_instance_valid(rl5) or rl5.is_queued_for_deletion() or not rl5.visible, "same text + Hangul off: nothing is left to show")
	Store.prefs["show_hangul_ja"] = true
	host.queue_free()
	await _frames(2)
	# 검사 함수도 틀린 입력을 거절한다
	selfcheck(ReadingLine.same_text("ありがとう", "ありがとー"), "same_text: a different reading is not the same")
	selfcheck(ReadingLine.same_text("", ""), "same_text: two empty texts are not 'the same'")
	selfcheck(ReadingLine.same_text("コーヒー", "こーひー"), "same_text: katakana vs hiragana is not the same")
	selfcheck(ReadingLine.same_text("ありがとう", ""), "same_text: nothing to compare with")


func _label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	return l


# ---------------------------------------------------------------- 대화 말풍선: 가나뿐인 말의 읽기 줄이 숨겨진다

func _test_talk_reading() -> void:
	print("[talk: reading lines under bubbles]")
	_set_lang("ja")
	Store.prefs["show_reading"] = true
	Store.prefs["show_hangul_ja"] = true
	_main.show_view("talk")
	await _frames(4)
	var tv: TalkView = _main.views["talk"]
	tv.lang = "ja"
	tv.status = "talk"
	tv.msgs = [
		{"role": "ai", "reply": "ありがとうございます。", "reading": "ありがとうございます。", "pron": "アリガトウゴザイマス。", "ko": "", "suggest": []},
		{"role": "ai", "reply": "私は学生です。", "reading": "わたしはがくせいです。", "pron": "ワタシワガクセイデス。", "ko": "", "suggest": []},
		{"role": "ai", "reply": "コーヒーをください。", "reading": "こーひーをください。", "pron": "コーヒーヲクダサイ。", "ko": "", "suggest": []},
	]
	tv._update_visibility()
	tv._render_msgs()
	await _frames(4)
	ok(_count_label(tv, "ありがとうございます。") == 1, "talk: a kana-only reply shows its sentence once (no repeated hiragana line)")
	ok(_count_label(tv, ReadingLine.hangul_of("ありがとうございます。", "アリガトウゴザイマス。")) == 1, "talk: ...and keeps its Hangul sound line")
	ok(_count_label(tv, "わたしはがくせいです。") == 1, "talk: a reply with kanji keeps its hiragana reading")
	ok(_count_label(tv, "こーひーをください。") == 1, "talk: a katakana reply keeps its hiragana reading (it differs from the sentence)")
	tv.msgs = []
	tv.status = "setup"
	tv._update_visibility()
	tv._render_setup()
	_main.show_view("today")
	await _frames(2)
	_set_lang("en")


# ---------------------------------------------------------------- C-15: 화면에 연속 다섯 자리 이상 숫자가 없다

func _digits_in(text: String) -> bool:
	var re := RegEx.new()
	re.compile("\\d{5,}")
	return re.search(text) != null


func _test_numbers_visible() -> void:
	print("[C-15: no raw 5+ digit numbers on the hub / home / diary]")
	var pv := _pv()
	await _open_hub("ja")
	ok(not _digits_in(_labels_text(pv)), "the japanese hub shows no 5+ digit number")
	_main.show_view("today")
	_tv().refresh()
	await _frames(3)
	ok(not _digits_in(_labels_text(_tv())), "the home shows no 5+ digit number")
	await _open_hub("ja")
	pv.open_screen("diary")
	await _frames(3)
	ok(not _digits_in(_labels_text(pv)), "the diary screen (with its list) shows no 5+ digit number")
	await _back_to_hub("numbers")
	var fake := VBoxContainer.new()
	fake.add_child(_label("마지막 일기 1731571200"))
	add_child(fake)
	selfcheck(not _digits_in(_labels_text(fake)), "a fake screen with a unix time (1731571200) is caught by the digit scan")
	fake.queue_free()
	_set_lang("en")


# ---------------------------------------------------------------- 일본어 받아쓰기 칩: 쓴 글자가 비면 "철자 틀림 ()" 이 나오지 않는다

func _empty_paren(text: String) -> bool:
	return text.contains("()")


func _test_dictation_chips() -> void:
	print("[dictation ja chips: empty written text]")
	var d := {"units": [
		{"w": "学校", "k": true, "rd": "がっこう", "kind": "typo", "ok": false, "said": ""},
		{"w": "へ", "k": false, "kind": "ok", "ok": true, "said": "へ"},
		{"w": "い", "k": false, "kind": "typo", "ok": false, "said": ""},
		{"w": "く", "k": false, "kind": "typo", "ok": false, "said": ""},
		{"w": "が", "k": true, "rd": "が", "kind": "typo", "ok": false, "said": "gaku"},
	]}
	var chips: Array = DictationScreen.ja_chips(d)
	var texts: Array = chips.map(func(c: Variant) -> String: return str((c as Dictionary)["text"]))
	ok(texts.size() == 4, "the chips are drawn (%d)" % texts.size())
	var any_empty := false
	for t in texts:
		any_empty = any_empty or _empty_paren(str(t))
	ok(not any_empty, "no chip reads '철자 틀림 ()' (%s)" % str(texts))
	ok(str(texts[0]).contains("学校") and str(texts[0]).ends_with("철자 틀림"), "kanji chunk with nothing written: the reason stays, the parentheses go (%s)" % str(texts[0]))
	ok(str(texts[2]).contains("いく") and str(texts[2]).ends_with("철자 틀림"), "kana run with nothing written: the reason stays, the parentheses go")
	ok(str(texts[3]).contains("철자 틀림 (gaku)"), "something written is still shown in parentheses (%s)" % str(texts[3]))
	selfcheck(not _empty_paren("✕ 学校(がっこう)  · 철자 틀림 ()"), "the empty-parentheses scan catches the old chip text")


# ---------------------------------------------------------------- 검사기도 틀린 입력을 거절한다 (C-12)

func _selfchecks() -> void:
	print("[selfchecks]")
	selfcheck(_hub_order_ok(["mission", "shadow", "dictation", "phoneme", "kana", "speed"], PracticeView.KINDS), "a hub without the diary card fails W-3")
	selfcheck(_hub_order_ok(HUB_ORDER, ["mission", "shadow", "dictation", "phoneme", "kana", "speed"]), "a KINDS without diary fails W-3")
	selfcheck(_hub_order_ok(["diary", "mission", "shadow", "dictation", "phoneme", "kana", "speed"], PracticeView.KINDS), "a wrong card order fails W-3")
	selfcheck(_count_toast("이 문장은 나온 적이 없어요") > 0, "a toast text that never came is not found")
	var fake_btn := Button.new()
	fake_btn.disabled = true
	add_child(fake_btn)
	var before: int = _presses
	selfcheck(_press_would_pass(fake_btn), "a disabled button is not pressed")
	ok(_presses == before, "the disabled button was not counted as a press")
	fake_btn.queue_free()


func _press_would_pass(b: Button) -> bool:
	return _pressable(b)
