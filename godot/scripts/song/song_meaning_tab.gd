class_name SongMeaningTab
extends VBoxContainer
## 노래 학습 화면의 "해석" 탭 (설계 docs/song_study_design.md 5.1, 12.1b, 6, 8 U-13).
## 줄마다 원문 + (일본어) 히라가나 / 한글 발음(설정 show_reading · show_hangul_ja) + 한국어 해석(ko).
## ko 가 비었거나 고친 줄(stale)이 있으면 "해석이 아직 없어요" 와 [해석 만들기]: PC 의 POST /song/enrich 로 20줄씩 요청한다.
##   - 요청의 ai_ok = song_consent(설정) AND 곡별 해석 켬(song["translate"], 없으면 설정 song_translate, 기본 켬)  (12.1b).
##     ai_ok 가 false 면 요청을 아예 보내지 않고 이유만 알린다 (가사가 AI 서비스로 나가지 않는다).
##   - PC 에 연결돼 있지 않으면(폰 단독 · 엔진 꺼짐) 요청 없이 안내만 한다.
## 받은 해석은 곡에 넣고 SongStore.save_song 으로 저장한 뒤 song_changed 를 낸다.
##
## 탭 위젯 계약 (4개 탭 공통): setup(song, ctx{player, line}) / on_show() / on_hide() / set_line(i). SongWordsTab 머리말 참고.
## 이 탭만 곡을 고친다 -> signal song_changed (틀이 줄 목록 등을 다시 그린다).

signal song_changed

const BATCH := 20 ## 요청 하나에 보내는 줄 수 (서버 상한 20)
const TIMEOUT := 65.0 ## 서버 60초 제한보다 약간 길게
const ENRICH_PATH := "/song/enrich"
const PREF_CONSENT := "song_consent"
const PREF_TRANSLATE := "song_translate"
const MSG_NO_KO := "해석이 아직 없어요"
const MSG_NO_PC := "해석을 만들려면 PC에 연결해야 해요 (Tailscale). 저장된 해석은 그대로 볼 수 있어요."
const MSG_NO_CONSENT := "해석은 가사를 AI 서비스로 보내 만들어요. 노래 목록에서 안내에 동의하면 쓸 수 있어요."
const MSG_SWITCH_OFF := "이 곡의 AI 해석이 꺼져 있어요. 아래 스위치를 켜면 만들 수 있어요."
const MSG_FAIL := "해석을 만들지 못했어요. 잠시 뒤 다시 시도해 주세요."
const MSG_SAVE_FAIL := "해석을 만들었지만 저장하지 못했어요. 이 곡은 그대로 두었어요. 저장 공간을 확인한 뒤 다시 시도해 주세요."
const MSG_SWITCH_FAIL := "저장하지 못해서 스위치를 바꾸지 못했어요. 저장 공간을 확인한 뒤 다시 시도해 주세요."
const MSG_READONLY := "더 새로운 버전의 앱에서 만든 곡이라 여기서는 저장할 수 없어요. 그대로 두었어요."

var song: Dictionary = {}
var lang: String = "en"
var player: Object = null
var busy: bool = false
var progress_text: String = ""
var last_msg: String = ""
var last_warnings: Array = []
var request_count: int = 0 ## 이 탭이 보낸 /song/enrich 요청 수 (시험 확인용)

## 시험 전용: PC 연결 판정을 바꾼다 (Callable() -> bool).
static var pc_hook: Callable = Callable()

var _line: int = -1
var _serial: int = 0
var _call = null
var _panels: Dictionary = {} ## 줄 번호 -> 줄 상자
var _acc: Color = Pal.EN


func _init() -> void:
	add_theme_constant_override("separation", 12)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL


func _exit_tree() -> void:
	cancel_make(false)
	Tts.stop()


# ---------------------------------------------------------------- 계약

func setup(song_in: Dictionary, ctx: Dictionary = {}) -> void:
	cancel_make(false)
	song = song_in
	lang = str(song.get("lang", "en"))
	if lang != "ja":
		lang = "en"
	_acc = Pal.accent(lang)
	var pl: Variant = ctx.get("player", null)
	player = pl if (pl is Object) else null
	_line = int(ctx.get("line", -1))
	last_msg = ""
	last_warnings = []
	_render()


func on_show() -> void:
	_render()


func on_hide() -> void:
	cancel_make()
	Tts.stop()


func set_line(i: int) -> void:
	_line = i
	_paint_current()


# ---------------------------------------------------------------- 규칙 (정적: 다른 화면 · 시험에서도 쓴다)

## 곡별 "해석 켬": 곡에 song["translate"] 가 있으면 그 값, 없으면 설정 song_translate (기본 켬).
static func translate_on(song_d: Dictionary) -> bool:
	var v: Variant = song_d.get("translate", null)
	if v is bool:
		return v
	return bool(Store.prefs.get(PREF_TRANSLATE, true))


## ai_ok = song_consent AND 곡별 해석 켬 (설계 12.1b). 동의 전에는 항상 false.
static func ai_ok(song_d: Dictionary) -> bool:
	return Store.pref_bool(PREF_CONSENT) and translate_on(song_d)


## 해석을 만들 PC 가 있나: 경로가 PC 로 가고(폰 phone 모드면 아님) PC 가 준비돼 있어야 한다.
static func pc_available() -> bool:
	if pc_hook.is_valid():
		return bool(pc_hook.call())
	return Route.decide("POST", ENRICH_PATH, {}) == "pc" and Route.pc_ready() and (not Route.is_phone() or Api.base_url != "")


## 해석할 줄인가: 글자가 있고 [Chorus] 같은 구간 표시가 아니다.
static func is_translatable(line: Dictionary) -> bool:
	var t: String = str(line.get("text", "")).strip_edges()
	return t != "" and not (t.begins_with("[") and t.ends_with("]"))


## 해석이 필요한 줄 번호들: 글자가 있고 ko 가 비었거나 stale.
func missing_lines() -> Array:
	var out: Array = []
	var ls: Variant = song.get("lines", [])
	if not (ls is Array):
		return out
	for i in (ls as Array).size():
		var ln: Variant = (ls as Array)[i]
		if not (ln is Dictionary):
			continue
		var d: Dictionary = ln
		if not is_translatable(d):
			continue
		if str(d.get("ko", "")).strip_edges() == "" or bool(d.get("stale", false)):
			out.append(i)
	return out


## 요청 본문 (POST /song/enrich, 설계 5.1 + 12.1b). 줄 20개 이하.
func build_request(indices: Array) -> Dictionary:
	var lines: Array = []
	var any_stale := false
	for i in indices.slice(0, BATCH):
		var d: Dictionary = (song["lines"] as Array)[int(i)]
		lines.append({"i": int(i), "text": str(d.get("text", ""))})
		if bool(d.get("stale", false)):
			any_stale = true
	var tasks: Array = ["translate"]
	if lang == "ja":
		tasks.push_front("reading")
	if any_stale:
		tasks.append("tokens")
		tasks.append("gloss")
	return {"lang": lang, "lines": lines, "tasks": tasks, "known": [], "ai_ok": ai_ok(song)}


# ---------------------------------------------------------------- 만들기

## 비어 있는 해석을 PC 에서 받아 온다. 보낼 줄이 없거나 ai_ok 가 false 이거나 PC 가 없으면 요청 없이 false.
func make_missing() -> bool:
	if busy:
		return false
	var todo: Array = missing_lines()
	if todo.is_empty():
		return false
	if not Store.pref_bool(PREF_CONSENT):
		last_msg = MSG_NO_CONSENT
		_render()
		return false
	if not translate_on(song):
		last_msg = MSG_SWITCH_OFF
		_render()
		return false
	if not pc_available():
		last_msg = MSG_NO_PC
		_render()
		return false
	busy = true
	last_msg = ""
	last_warnings = []
	_serial += 1
	var serial: int = _serial
	var total: int = ceili(float(todo.size()) / float(BATCH))
	var snap: Dictionary = _snapshot() # 저장이 안 되면 받은 해석을 이 값으로 되돌린다 (다시 열면 사라지는 해석을 보이지 않는다)
	var filled := 0
	var failed_msg := ""
	for b in total:
		var batch: Array = todo.slice(b * BATCH, (b + 1) * BATCH)
		progress_text = "해석 만드는 중… %d / %d" % [b + 1, total]
		_render()
		var body: Dictionary = build_request(batch)
		request_count += 1
		var req: Object = SpeakDrill.request(ENRICH_PATH, body, TIMEOUT)
		_call = req
		var res: Dictionary = await req.wait()
		if serial != _serial:
			return false # 취소됨 (cancel_make 가 상태를 정리했다)
		_call = null
		if bool(res.get("cancelled", false)):
			break
		if not bool(res.get("ok", false)):
			failed_msg = SpeakDrill.error_message(res, MSG_FAIL)
			break
		filled += apply_response(res.get("data", null), batch)
	busy = false
	progress_text = ""
	var save_failed := false
	if filled > 0 and not _save():
		_restore(snap)
		save_failed = true
		filled = 0
	if save_failed:
		last_msg = MSG_READONLY if SongModel.is_read_only(song) else MSG_SAVE_FAIL
	elif failed_msg != "":
		last_msg = failed_msg if filled == 0 else "%s (%d줄은 만들었어요)" % [failed_msg, filled]
	elif filled == 0:
		last_msg = "해석을 받지 못했어요. 잠시 뒤 다시 시도해 주세요."
	else:
		var left: int = missing_lines().size()
		last_msg = "%d줄의 해석을 만들었어요." % filled + (" %d줄은 만들지 못했어요." % left if left > 0 else "")
	if filled > 0:
		song_changed.emit()
	_render()
	return filled > 0


## 서버 응답을 곡에 넣는다. 요청하지 않은 줄 번호나 모양이 틀린 항목은 무시한다. 해석(ko)이 채워진 줄 수.
func apply_response(data: Variant, batch: Array) -> int:
	if not (data is Dictionary):
		return 0
	var dd: Dictionary = data
	var w: Variant = dd.get("warnings", [])
	if w is Array:
		for x in (w as Array):
			if x is String and not last_warnings.has(x) and last_warnings.size() < 10:
				last_warnings.append(x)
	var arr: Variant = dd.get("lines", [])
	if not (arr is Array):
		return 0
	var ls: Array = song["lines"]
	var filled := 0
	var gloss_added := false
	for it in (arr as Array):
		if not (it is Dictionary):
			continue
		var item: Dictionary = it
		var iv: Variant = item.get("i", null)
		if not (iv is int or iv is float):
			continue
		var i: int = int(iv)
		if not batch.has(i) or i < 0 or i >= ls.size() or not (ls[i] is Dictionary):
			continue
		var ln: Dictionary = ls[i]
		var ko: String = SongModel.clean_str(item.get("ko", ""), SongModel.LEN_KO).strip_edges()
		if ko == "":
			continue
		ln["ko"] = ko
		filled += 1
		if lang == "ja":
			var rd: String = SongModel.clean_str(item.get("reading", ""), SongModel.LEN_READING).strip_edges()
			var pr: String = SongModel.clean_str(item.get("pron", ""), SongModel.LEN_READING).strip_edges()
			if rd != "":
				ln["reading"] = rd
			if pr != "":
				ln["pron"] = pr
		if bool(ln.get("stale", false)):
			var nw: Variant = item.get("words", null)
			if nw is Array and not (nw as Array).is_empty():
				var words: Array = []
				for x in (nw as Array):
					if x is Dictionary and str((x as Dictionary).get("w", "")) != "":
						var wd: Dictionary = (x as Dictionary).duplicate()
						wd["est"] = true
						words.append(wd)
				if not words.is_empty():
					ln["words"] = words
					gloss_added = true
			ln["stale"] = false
	if gloss_added and dd.get("glossary", null) is Dictionary:
		var g: Dictionary = song.get("glossary", {}) if song.get("glossary", null) is Dictionary else {}
		for k in (dd["glossary"] as Dictionary).keys():
			if (dd["glossary"] as Dictionary)[k] is Dictionary:
				g[str(k)] = (dd["glossary"] as Dictionary)[k]
		song["glossary"] = g
	return filled


func cancel_make(redraw: bool = true) -> void:
	if not busy and _call == null:
		return
	_serial += 1
	SpeakDrill.cancel_call(_call)
	_call = null
	busy = false
	progress_text = ""
	if redraw:
		_render()


## 곡별 "해석 켬" 스위치. 곡에 저장한다.
func set_translate(on: bool) -> void:
	var had: bool = song.has("translate")
	var old: Variant = song.get("translate", null)
	song["translate"] = on
	last_msg = ""
	if not _save():
		if had: # 저장이 안 됐으면 스위치도 예전 값으로 (다시 열면 사라질 값을 보이지 않는다)
			song["translate"] = old
		else:
			song.erase("translate")
		last_msg = MSG_READONLY if SongModel.is_read_only(song) else MSG_SWITCH_FAIL
	_render()


## 해석을 받기 전의 줄·용어집 (저장 실패 때 되돌리는 값).
func _snapshot() -> Dictionary:
	var ls: Variant = song.get("lines", [])
	return {"lines": (ls as Array).duplicate(true) if ls is Array else [], "has_glossary": song.has("glossary"),
		"glossary": (song["glossary"] as Dictionary).duplicate(true) if song.get("glossary", null) is Dictionary else null}


## _snapshot 의 값으로 되돌린다. 줄 Dictionary 는 같은 객체를 그대로 두고 안을 바꾼다 (다른 탭이 같은 곡을 본다).
func _restore(snap: Dictionary) -> void:
	var ls: Variant = song.get("lines", [])
	var old: Array = snap["lines"]
	if ls is Array:
		for i in mini((ls as Array).size(), old.size()):
			if (ls as Array)[i] is Dictionary and old[i] is Dictionary:
				((ls as Array)[i] as Dictionary).clear()
				((ls as Array)[i] as Dictionary).merge(old[i] as Dictionary, true)
	if bool(snap["has_glossary"]):
		song["glossary"] = snap["glossary"]
	else:
		song.erase("glossary")


func _save() -> bool:
	if SongModel.is_read_only(song):
		return false
	var ok: bool = SongStore.save_song(song)
	if not ok:
		Toast.error("해석을 저장하지 못했어요.")
	return ok


func play_line(i: int) -> bool:
	if player == null or not is_instance_valid(player) or not player.has_method("play_line"):
		return false
	player.call("play_line", i, 1)
	return true


## 줄 카드(복습)로 넣는다. 새로 들어간 수.
func add_line_card(i: int) -> int:
	var c: Dictionary = SongStudy.line_card(song, i)
	if c.is_empty():
		return 0
	var r: Dictionary = SongStudy.add_cards([c])
	var n: int = int(r.get("added", 0))
	if n > 0:
		Store.save_progress()
		Toast.ok("복습 카드에 넣었어요")
	else:
		Toast.info("이미 복습 카드에 있어요")
	return n


# ---------------------------------------------------------------- 그리기

func _render() -> void:
	UI.clear(self)
	_panels = {}
	var ls: Variant = song.get("lines", [])
	var lines: Array = ls if ls is Array else []
	var miss: Array = missing_lines()
	var head := UI.card("Card", 8)
	head.body.add_child(UI.label("한국어 해석", "H3"))
	var total_text := 0
	for d in lines:
		if d is Dictionary and is_translatable(d):
			total_text += 1
	head.body.add_child(UI.label("%d줄 중 %d줄에 해석이 있어요" % [total_text, total_text - miss.size()], "Muted"))
	if busy:
		head.body.add_child(UI.label(progress_text, "Strong"))
		head.body.add_child(UI.progress_indeterminate(_acc))
		var cb := SpeakDrill.touch_button("취소", "outline", _acc)
		cb.pressed.connect(cancel_make)
		head.body.add_child(cb)
	elif not miss.is_empty():
		head.body.add_child(UI.label("%s: %d줄" % [MSG_NO_KO, miss.size()], "Strong"))
		if not Store.pref_bool(PREF_CONSENT):
			head.body.add_child(SpeakDrill.notice(MSG_NO_CONSENT, false))
		else:
			head.body.add_child(UI.switch_row("이 곡의 해석을 AI로 만들기", translate_on(song), set_translate, "끄면 가사를 AI 서비스로 보내지 않아요"))
			if translate_on(song):
				if pc_available():
					var mb := SpeakDrill.touch_button("해석 만들기" if _any_ko() == false else "다시 만들기", "primary", _acc)
					mb.pressed.connect(func() -> void: make_missing())
					head.body.add_child(mb)
				else:
					head.body.add_child(SpeakDrill.notice(MSG_NO_PC, false))
	if last_msg != "":
		head.body.add_child(UI.colored(last_msg, Pal.INK, "Strong"))
	add_child(head)

	for i in lines.size():
		if not (lines[i] is Dictionary):
			continue
		var d: Dictionary = lines[i]
		if str(d.get("text", "")).strip_edges() == "":
			continue
		var p := _line_panel(i, d)
		_panels[i] = p
		add_child(p)
	_paint_current()
	UI.fix_cjk(self)


func _any_ko() -> bool:
	var ls: Variant = song.get("lines", [])
	if ls is Array:
		for d in (ls as Array):
			if d is Dictionary and str((d as Dictionary).get("ko", "")).strip_edges() != "":
				return true
	return false


func _line_panel(i: int, d: Dictionary) -> PanelContainer:
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", _panel_style(false))
	p.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var v := UI.vbox(4)
	p.add_child(v)
	v.add_child(UI.label(str(d.get("text", "")), "Strong"))
	ReadingLine.add(v, str(d.get("reading", "")), lang, Store.pref_bool("show_reading"), 0.0, str(d.get("pron", "")))
	var ko: String = str(d.get("ko", "")).strip_edges()
	if ko != "":
		v.add_child(UI.label(ko, ""))
	elif is_translatable(d):
		v.add_child(UI.label(MSG_NO_KO, "Muted"))
	if bool(d.get("stale", false)):
		v.add_child(UI.chip_kind("고친 줄 · 해석 다시 만들기 필요", "warn"))
	var row := UI.flow(4, 4)
	if player != null and is_instance_valid(player) and player.has_method("play_line"):
		var pb := UI.link_button("▶ 듣기")
		pb.pressed.connect(func() -> void: play_line(i))
		row.add_child(pb)
	var ab := UI.link_button("복습에 추가")
	ab.pressed.connect(func() -> void: add_line_card(i))
	row.add_child(ab)
	v.add_child(row)
	return p


func _panel_style(current: bool) -> StyleBoxFlat:
	if current:
		return UI.style(Pal.PRIMARY_SOFT, Pal.PRIMARY, 2, Ds.R_S, 14, 10)
	return UI.style(Pal.SURFACE, Pal.LINE, 1, Ds.R_S, 14, 10)


func _paint_current() -> void:
	for k in _panels.keys():
		var p: Variant = _panels[k]
		if p is PanelContainer and is_instance_valid(p):
			(p as PanelContainer).add_theme_stylebox_override("panel", _panel_style(int(k) == _line))
