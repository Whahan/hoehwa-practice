extends Node
## HomeAi ("AI 연결" 자리) 시험. Backend.status 를 직접 바꿔 표(설계 §9.6)와 비교한다. 엔진은 시작하지 않는다.
##   godot --headless --path <project> res://tests/home_ai_test.tscn
## Exit code 0 = all passed. Last line: "== home_ai result: N passed, 0 failed =="
## prefs 는 user://test_home_prefs.json 에만 쓴다(Store.prefs_path 를 바꿔서). 시험이 끝나면 Backend, Route, Store 값을 되돌린다.

const PREFS := "user://test_home_prefs.json"

var passed: int = 0
var failed: int = 0
var _before: Array = []
var _saved := {}


func _ready() -> void:
	print("== home_ai start ==")
	_before = _user_listing()
	_save_state()
	_selfcheck()
	_default_table()
	_standalone()
	_wording()
	_provider()
	_sanitize()
	_dismiss()
	_restore_state()
	ok(JSON.stringify(_before) == JSON.stringify(_user_listing()), "user:// listing unchanged after the test")
	print("== home_ai result: %d passed, %d failed ==" % [passed, failed])
	get_tree().quit(1 if failed > 0 else 0)


func ok(cond: bool, name: String) -> void:
	if cond:
		passed += 1
		print("  PASS  ", name)
	else:
		failed += 1
		print("  FAIL  ", name)


func _save_state() -> void:
	_saved = {"status": Backend.status, "health": Backend.health.duplicate(true), "starting": Backend._starting,
		"route": Route.mode, "prefs_path": Store.prefs_path, "prefs": Store.prefs.duplicate(true),
		"override": StudyLog.today_override, "provider": HomeAi.provider, "force": HomeAi.force_phone}
	Backend._starting = true # nothing may start an engine
	Backend.set_process(false)
	Store.prefs_path = PREFS
	_rm(PREFS)


func _restore_state() -> void:
	Backend.status = _saved["status"]
	Backend.health = _saved["health"]
	Backend._starting = _saved["starting"]
	Backend.set_process(true)
	Route.mode = _saved["route"]
	Store.prefs = _saved["prefs"]
	Store.prefs_path = _saved["prefs_path"]
	StudyLog.today_override = _saved["override"]
	HomeAi.provider = _saved["provider"]
	HomeAi.force_phone = _saved["force"]
	_rm(PREFS)


func _rm(p: String) -> void:
	var g: String = ProjectSettings.globalize_path(p)
	for f in [g, g + ".tmp", g + ".bad"]:
		if FileAccess.file_exists(f):
			DirAccess.remove_absolute(f)


func _user_listing() -> Array:
	var out: Array = []
	var d := DirAccess.open("user://")
	if d == null:
		return out
	for n in d.get_files():
		out.append("%s:%d" % [n, FileAccess.get_file_as_bytes("user://" + n).size()])
	out.sort()
	return out


## show / state / title / action 네 값을 한 줄 글자로.
func key(s: Dictionary) -> String:
	return "%s|%s|%s|%s" % [s["show"], s["state"], s["title"], s["action"]]


func eq(got: String, want: String, name: String) -> void:
	ok(got == want, name if got == want else "%s  got=[%s] want=[%s]" % [name, got, want])


func slot_for(status: Backend.Status, llm: bool = true) -> Dictionary:
	Backend.status = status
	Backend.health = {"llm": llm}
	return HomeAi.slot()


func _selfcheck() -> void:
	print("[selfcheck]")
	var got: String = key(slot_for(Backend.Status.FAILED))
	var wrong: bool = got == "false|off||"
	print("selfcheck %s FAILED slot vs the hidden-card value" % ("FAIL-as-expected" if not wrong else "UNEXPECTED-PASS"))
	ok(not wrong, "key() comparison rejects a wrong expectation")
	var sloppy: bool = HomeAi.sanitize({"show": true, "title": "x"})["body"] == "something"
	print("selfcheck %s sanitize body vs invented text" % ("FAIL-as-expected" if not sloppy else "UNEXPECTED-PASS"))
	ok(not sloppy, "a made-up expectation on sanitize() fails")


func _default_table() -> void:
	print("[default table, PC]")
	HomeAi.force_phone = 0
	Store.prefs["standalone_ok"] = false
	Route.mode = "auto"
	HomeAi.provider = Callable()
	eq(key(slot_for(Backend.Status.READY, true)), "false|ready||", "READY + LLM -> hidden, state ready")
	eq(key(slot_for(Backend.Status.READY, false)), "true|llm_off|AI 답변이 꺼져 있어요|AI 연결하기", "READY + llm_missing -> llm_off card")
	eq(key(slot_for(Backend.Status.FAILED)), "true|off|AI 연결 안 됨|AI 연결하기", "FAILED -> off card")
	eq(key(slot_for(Backend.Status.NEEDS_PAIRING)), "true|needs_pairing|PC 연결이 필요해요|AI 연결하기", "NEEDS_PAIRING -> needs_pairing card")
	eq(key(slot_for(Backend.Status.IDLE)), "false|off||", "IDLE -> hidden")
	eq(key(slot_for(Backend.Status.CHECKING)), "false|off||", "CHECKING -> hidden")
	eq(key(slot_for(Backend.Status.STARTING)), "false|off||", "STARTING -> hidden")
	var s: Dictionary = slot_for(Backend.Status.FAILED)
	ok(s["prominent"] == false and s["dismissible"] == true, "default card: not prominent, dismissible")
	ok(s.keys().size() == 7, "slot() has exactly the 7 contract keys")
	var hidden: Dictionary = slot_for(Backend.Status.READY, true)
	ok(hidden.keys().size() == 7 and hidden["title"] == "" and hidden["action"] == "", "a hidden slot still has all keys (empty text)")


func _standalone() -> void:
	print("[standalone phone]")
	HomeAi.force_phone = 1
	Store.prefs["standalone_ok"] = true
	Route.mode = "auto"
	eq(key(slot_for(Backend.Status.FAILED)), "false|off||", "phone + standalone_ok + FAILED -> hidden")
	eq(key(slot_for(Backend.Status.NEEDS_PAIRING)), "false|off||", "phone + standalone_ok + NEEDS_PAIRING -> hidden")
	eq(key(slot_for(Backend.Status.READY, false)), "true|llm_off|AI 답변이 꺼져 있어요|AI 연결하기", "standalone does not hide a READY engine without LLM")
	Store.prefs["standalone_ok"] = false
	Route.mode = "phone"
	eq(key(slot_for(Backend.Status.FAILED)), "false|off||", "phone + processing place \"phone\" + FAILED -> hidden")
	Route.mode = "auto"
	eq(key(slot_for(Backend.Status.FAILED)), "true|off|AI 연결 안 됨|AI 연결하기", "phone, not standalone + FAILED -> card")
	eq(key(slot_for(Backend.Status.NEEDS_PAIRING)), "true|needs_pairing|PC 연결이 필요해요|AI 연결하기", "phone, not standalone + NEEDS_PAIRING -> card")
	HomeAi.force_phone = 0
	Store.prefs["standalone_ok"] = true
	Route.mode = "phone"
	eq(key(slot_for(Backend.Status.FAILED)), "true|off|AI 연결 안 됨|AI 연결하기", "PC never counts as standalone")
	HomeAi.force_phone = -1
	Store.prefs["standalone_ok"] = false
	Route.mode = "auto"


func _wording() -> void:
	print("[wording and lengths]")
	HomeAi.force_phone = 0
	var all_text := ""
	for st in [Backend.Status.READY, Backend.Status.FAILED, Backend.Status.NEEDS_PAIRING]:
		for llm in [true, false]:
			var s: Dictionary = slot_for(st, llm)
			ok(str(s["title"]).length() <= HomeAi.TITLE_MAX and str(s["body"]).length() <= HomeAi.BODY_MAX and str(s["action"]).length() <= HomeAi.ACTION_MAX,
				"lengths within 24 / 60 / 10 (status %d llm %s)" % [st, str(llm)])
			all_text += "%s %s %s " % [s["title"], s["body"], s["action"]]
	var low: String = all_text.to_lower()
	var banned: Array = []
	for w in ["ollama", "로컬 ai", "로컬ai", "오프라인", "opencode", "deepseek"]:
		if low.contains(w):
			banned.append(w)
	ok(banned.is_empty(), "default texts never name an engine (Ollama / 로컬 AI / OpenCode ...) %s" % str(banned))
	var fake_banned: bool = "Ollama를 실행해 주세요".to_lower().contains("ollama")
	print("selfcheck %s banned-word scan on a text that names Ollama" % ("FAIL-as-expected" if fake_banned else "UNEXPECTED-PASS"))
	ok(fake_banned, "the banned-word scan flags a text that names Ollama")


func _provider() -> void:
	print("[provider with strange values]")
	HomeAi.force_phone = 0
	Backend.status = Backend.Status.READY
	Backend.health = {"llm": true}
	HomeAi.provider = func() -> Variant: return null
	eq(key(HomeAi.slot()), "false|off||", "provider returns null -> hidden")
	HomeAi.provider = func() -> Variant: return "hello"
	eq(key(HomeAi.slot()), "false|off||", "provider returns a string -> hidden")
	HomeAi.provider = func() -> Variant: return 5
	eq(key(HomeAi.slot()), "false|off||", "provider returns an int -> hidden")
	HomeAi.provider = func() -> Variant: return [1, 2]
	eq(key(HomeAi.slot()), "false|off||", "provider returns an array -> hidden")
	HomeAi.provider = func() -> Variant: return {}
	eq(key(HomeAi.slot()), "false|off||", "provider returns {} -> hidden")
	HomeAi.provider = func() -> Variant: return {"title": "no show key"}
	eq(key(HomeAi.slot()), "false|off|no show key|", "provider without \"show\" -> hidden (text kept)")
	HomeAi.provider = func() -> Variant: return {"show": true}
	eq(key(HomeAi.slot()), "false|off||", "provider show=true without a title -> hidden")
	HomeAi.provider = func() -> Variant: return {"show": "yes", "title": "t"}
	eq(key(HomeAi.slot()), "false|off|t|", "provider show as a string -> hidden")
	var long_text: String = "가".repeat(500)
	HomeAi.provider = func() -> Variant: return {"show": true, "state": "hack", "title": long_text, "body": long_text, "action": long_text, "prominent": true, "dismissible": "x"}
	var s: Dictionary = HomeAi.slot()
	ok(s["show"] == true and str(s["title"]).length() == 24 and str(s["body"]).length() == 60 and str(s["action"]).length() == 10, "500-char texts cut to 24 / 60 / 10")
	ok(s["state"] == "off" and s["prominent"] == true and s["dismissible"] == false, "unknown state -> off, bad dismissible -> false, prominent kept")
	var good := {"show": true, "state": "not_installed", "title": "AI 설치하기", "body": "한 번만 설치하면 돼요", "action": "설치", "prominent": true, "dismissible": false}
	HomeAi.provider = func() -> Variant: return good.duplicate()
	ok(JSON.stringify(HomeAi.slot(), "", true) == JSON.stringify(good, "", true), "a valid provider result passes through unchanged")
	var n := Node.new()
	HomeAi.provider = Callable(n, "get_name")
	n.free()
	ok(not HomeAi.provider.is_valid(), "precondition: the provider's object is gone")
	eq(key(HomeAi.slot()), "false|ready||", "provider whose object was freed -> default implementation")
	HomeAi.provider = Callable()
	ok(not HomeAi.provider.is_valid(), "provider reset to an empty Callable")
	eq(key(HomeAi.slot()), "false|ready||", "after reset the default implementation answers")


func _sanitize() -> void:
	print("[sanitize]")
	var safe := "false|off||"
	eq(key(HomeAi.sanitize(null)), safe, "sanitize(null)")
	eq(key(HomeAi.sanitize(12)), safe, "sanitize(12)")
	eq(key(HomeAi.sanitize([])), safe, "sanitize([])")
	eq(key(HomeAi.sanitize("x")), safe, "sanitize(string)")
	var s: Dictionary = HomeAi.sanitize({"show": true, "title": "  spaced  ", "body": 5, "action": null, "state": 3})
	ok(s["title"] == "spaced" and s["body"] == "" and s["action"] == "" and s["state"] == "off" and s["show"] == true, "non-string texts -> empty, titles trimmed, non-string state -> off")
	for st in HomeAi.STATES:
		ok(HomeAi.sanitize({"show": true, "title": "t", "state": st})["state"] == st, "state %s accepted" % st)
	var src := {"show": true, "title": "t"}
	var copy: Dictionary = src.duplicate(true)
	HomeAi.sanitize(src)
	ok(JSON.stringify(src) == JSON.stringify(copy), "sanitize() does not modify its input")


func _dismiss() -> void:
	print("[dismiss today]")
	StudyLog.today_override = 20500
	Store.prefs.erase(HomeAi.DISMISS_PREF)
	ok(not HomeAi.dismissed_today(), "not dismissed at first")
	HomeAi.dismiss_today()
	ok(HomeAi.dismissed_today(), "dismissed after dismiss_today()")
	ok(int(Store.prefs.get(HomeAi.DISMISS_PREF, -1)) == 20500, "prefs.home_ai_dismiss_day == StudyLog.today()")
	ok(FileAccess.file_exists(ProjectSettings.globalize_path(PREFS)), "it was saved to the temp prefs file")
	var txt: String = FileAccess.get_file_as_string(PREFS)
	ok(txt.contains("home_ai_dismiss_day") and txt.contains("20500"), "the temp prefs file holds the day number")
	StudyLog.today_override = 20501
	ok(not HomeAi.dismissed_today(), "next day: shown again")
	StudyLog.today_override = 20500
	ok(HomeAi.dismissed_today(), "back on the same day: hidden again")
	Store.prefs[HomeAi.DISMISS_PREF] = "20500"
	ok(not HomeAi.dismissed_today(), "a string value in prefs does not count")
	Store.prefs[HomeAi.DISMISS_PREF] = null
	ok(not HomeAi.dismissed_today(), "null in prefs does not count")
	Store.prefs[HomeAi.DISMISS_PREF] = 20500.0
	ok(HomeAi.dismissed_today(), "a day number read back from JSON as a float works")
	var real_prefs: bool = Store.prefs_path == PREFS and Store.prefs_path != Store.PREFS_PATH
	ok(real_prefs, "prefs went to the temp path, not the real prefs.json")
	var wrong: bool = (Store.prefs_path == Store.PREFS_PATH)
	print("selfcheck %s temp-path check against the real prefs path" % ("FAIL-as-expected" if not wrong else "UNEXPECTED-PASS"))
	ok(not wrong, "the path check would fail if the real prefs path were in use")
