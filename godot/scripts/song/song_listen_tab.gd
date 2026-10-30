class_name SongListenTab
extends VBoxContainer
## 듣기 탭 (docs/song_study_design.md §4.3, U-9): 가사 줄 목록. 줄을 누르면 그 줄 구간을 반복 설정(1·3·계속)대로 재생하고,
## 재생을 따라 현재 줄이 강조되고(굵은 글씨 + 테두리 + 연한 바탕) 화면이 자동으로 따라 내려간다.
## 시간이 실측인 곡(타이밍 est 아님 · 줄 est 아님 · 단어 시간 있음)만 현재 줄 안에서 지금 부르는 단어를 굵게 보인다.
## 탭 위젯 계약은 song_study_screen.gd 머리말 참고 (setup / on_show / set_line / on_hide).

const WARN_EST := "이 곡은 줄 시간이 추정이라 위치가 어긋날 수 있어요. 가사 확인 화면에서 고칠 수 있어요."

var song: Dictionary = {}
var lang: String = "en"
var player: SongPlayer = null
var screen: Node = null
var rows: Array = [] ## 줄마다 {panel, label, rtl, i}
var hl: int = -1 ## 강조 중인 줄
var active_word: int = -1 ## 강조 중인 단어 번호 (words 배열 기준), 없으면 -1

var _style_normal: StyleBoxFlat = null
var _style_cur: StyleBoxFlat = null
var _bold: Font = null
var _scroll_serial: int = 0


func _init() -> void:
	name = "SongListenTab"
	add_theme_constant_override("separation", Ds.S2)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL


func setup(song_in: Dictionary, ctx: Dictionary = {}) -> void:
	song = song_in
	lang = str(ctx.get("lang", song.get("lang", "en")))
	player = ctx.get("player", null)
	screen = ctx.get("screen", null)
	_style_normal = UI.style(Pal.SURFACE, Pal.LINE, 1, Ds.R_S, 12, 8)
	_style_cur = UI.style(Pal.PRIMARY_SOFT, Pal.PRIMARY, 2, Ds.R_S, 12, 8)
	_bold = UI.bold_font()
	_build()
	if player != null:
		player.position_changed.connect(_on_position)
	if screen != null and screen.has_signal("highlight_changed"):
		screen.connect("highlight_changed", _on_highlight)
	var start: int = int(ctx.get("line", -1))
	if screen != null and screen.has_method("highlight_line"):
		start = int(screen.call("highlight_line"))
	_set_highlight(start, false)


func on_show() -> void:
	_scroll_to(hl)


## 곡이 바뀌었다(해석 등): 목록을 다시 그리고 강조를 되살린다.
func rebuild() -> void:
	hl = -1
	active_word = -1
	_build()
	var h: int = int(screen.call("highlight_line")) if screen != null and screen.has_method("highlight_line") else -1
	_set_highlight(h, false)


func on_hide() -> void:
	pass


func set_line(_i: int) -> void:
	pass # 강조는 화면의 highlight_changed 가 알려 준다


func line_count() -> int:
	return rows.size()


## 줄을 눌렀을 때와 같다: 그 줄을 골라 재생한다.
func tap_line(i: int) -> void:
	if i < 0 or i >= rows.size():
		return
	if screen != null and screen.has_method("select_line"):
		screen.call("select_line", i, true)
	elif player != null:
		player.play_line(i, 1)


## 그 줄에서 단어 강조를 쓸 수 있나 (타이밍 est 가 아니고, 줄 est 가 아니고, 단어에 시간이 있음).
func word_highlight_on(i: int = -2) -> bool:
	var idx: int = hl if i == -2 else i
	var ln: Dictionary = _line(idx)
	if ln.is_empty():
		return false
	var src: Variant = song.get("source", {})
	if src is Dictionary and str((src as Dictionary).get("timing", "line")) == "est":
		return false
	if bool(ln.get("est", false)):
		return false
	var ws: Variant = ln.get("words", [])
	if not (ws is Array):
		return false
	for w in (ws as Array):
		if w is Dictionary and not bool((w as Dictionary).get("est", false)) and float((w as Dictionary).get("e", 0.0)) > float((w as Dictionary).get("s", 0.0)):
			return true
	return false


func row_panel(i: int) -> Control:
	if i < 0 or i >= rows.size():
		return null
	return rows[i]["panel"]


# ---------------------------------------------------------------- drawing

func _line(i: int) -> Dictionary:
	var ls: Variant = song.get("lines", [])
	if ls is Array and i >= 0 and i < (ls as Array).size() and (ls as Array)[i] is Dictionary:
		return (ls as Array)[i]
	return {}


func _is_est_song() -> bool:
	var src: Variant = song.get("source", {})
	if src is Dictionary and str((src as Dictionary).get("timing", "line")) == "est":
		return true
	for ln in (song.get("lines", []) as Array):
		if ln is Dictionary and bool((ln as Dictionary).get("est", false)):
			return true
	return false


func _build() -> void:
	UI.clear(self)
	rows = []
	if _is_est_song():
		add_child(UI.colored(WARN_EST, Pal.WARN_ON, "Small"))
	var lines: Array = song.get("lines", []) if song.get("lines", []) is Array else []
	if lines.is_empty():
		add_child(UI.label("가사 줄이 없어요.", "Muted"))
		return
	var prev_p: int = -1
	var show_kana: bool = Store.pref_bool("show_reading")
	var show_ko: bool = Store.pref_bool("show_ko")
	for i in lines.size():
		var ln: Dictionary = lines[i]
		var p: int = int(ln.get("p", 0))
		if i > 0 and p != prev_p:
			add_child(UI.gap(Ds.S2)) # 연(스탠자)이 바뀌는 곳
		prev_p = p
		var panel := PanelContainer.new()
		panel.name = "Line%d" % i
		panel.add_theme_stylebox_override("panel", _style_normal)
		panel.mouse_filter = Control.MOUSE_FILTER_STOP
		panel.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		UI.touch(panel, Ds.touch_min())
		var box := VBoxContainer.new()
		box.add_theme_constant_override("separation", 2)
		panel.add_child(box)
		var txt: String = str(ln.get("text", ""))
		var lab := UI.label(txt if txt.strip_edges() != "" else "♪", "")
		lab.name = "Text"
		box.add_child(lab)
		if lang == "ja":
			ReadingLine.add(box, str(ln.get("reading", "")), lang, show_kana, 0.0, str(ln.get("pron", "")))
		var ko: String = str(ln.get("ko", ""))
		if show_ko and ko != "":
			box.add_child(UI.label(ko, "Muted"))
		_ignore_mouse(box)
		var idx: int = i
		UI.on_tap(panel, func() -> void: tap_line(idx))
		add_child(panel)
		rows.append({"panel": panel, "label": lab, "rtl": null, "i": i})
	UI.fix_cjk(self)


static func _ignore_mouse(n: Node) -> void:
	for c in n.get_children():
		if c is Control:
			(c as Control).mouse_filter = Control.MOUSE_FILTER_IGNORE
		_ignore_mouse(c)


# ---------------------------------------------------------------- highlight

func _on_highlight(i: int) -> void:
	_set_highlight(i, true)


func _set_highlight(i: int, scroll: bool) -> void:
	if i >= rows.size():
		i = -1
	if i == hl:
		return
	_drop_rtl(hl)
	if hl >= 0 and hl < rows.size():
		(rows[hl]["panel"] as PanelContainer).add_theme_stylebox_override("panel", _style_normal)
		(rows[hl]["label"] as Label).remove_theme_font_override("font")
	hl = i
	active_word = -1
	if hl >= 0:
		(rows[hl]["panel"] as PanelContainer).add_theme_stylebox_override("panel", _style_cur)
		(rows[hl]["label"] as Label).add_theme_font_override("font", _bold)
		_update_word(true)
		if scroll:
			_scroll_to(hl)


func _scroll_to(i: int) -> void:
	if i < 0 or i >= rows.size() or screen == null or not screen.has_method("scroll_to_control"):
		return
	_scroll_serial += 1
	var serial: int = _scroll_serial
	var panel: Control = rows[i]["panel"]
	# the layout settles one frame after the highlight changed
	await get_tree().process_frame
	if serial != _scroll_serial or not is_instance_valid(panel) or not is_instance_valid(screen):
		return
	screen.call("scroll_to_control", panel)


func _on_position(t: float) -> void:
	if hl < 0:
		return
	_update_word(false, t)


## 지금 부르는 단어 번호 (없거나 강조를 못 쓰면 -1).
func word_at(i: int, t: float) -> int:
	if not word_highlight_on(i):
		return -1
	var ws: Array = _line(i).get("words", [])
	for k in ws.size():
		var w: Dictionary = ws[k]
		if bool(w.get("est", false)):
			continue
		if t >= float(w.get("s", 0.0)) and t < float(w.get("e", 0.0)):
			return k
	return -1


func _update_word(force: bool, t: float = -1.0) -> void:
	if hl < 0 or hl >= rows.size():
		return
	if not word_highlight_on(hl):
		_drop_rtl(hl)
		active_word = -1
		return
	var tt: float = t if t >= 0.0 else (player.position() if player != null else 0.0)
	var k: int = word_at(hl, tt)
	if k == active_word and not force and rows[hl]["rtl"] != null:
		return
	active_word = k
	var row: Dictionary = rows[hl]
	var rtl: RichTextLabel = row["rtl"]
	if rtl == null:
		rtl = UI.rich("", 16)
		rtl.name = "WordText"
		rtl.add_theme_color_override("default_color", Pal.INK)
		rtl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var lab: Label = row["label"]
		var box: Node = lab.get_parent()
		box.add_child(rtl)
		box.move_child(rtl, lab.get_index() + 1)
		lab.visible = false
		row["rtl"] = rtl
	rtl.text = _word_bbcode(_line(hl), k)


func _drop_rtl(i: int) -> void:
	if i < 0 or i >= rows.size():
		return
	var row: Dictionary = rows[i]
	var rtl: RichTextLabel = row["rtl"]
	if rtl != null and is_instance_valid(rtl):
		if rtl.get_parent() != null:
			rtl.get_parent().remove_child(rtl)
		rtl.queue_free()
	row["rtl"] = null
	(row["label"] as Label).visible = true


## 줄 글자에서 k 번째 단어만 굵고 진하게.
func _word_bbcode(ln: Dictionary, k: int) -> String:
	var text: String = str(ln.get("text", ""))
	if k < 0:
		return UI.bb_escape(text)
	var out := ""
	var pos := 0
	for sp in SongStudy._spans(ln, lang):
		if int(sp["k"]) != k:
			continue
		var st: int = int(sp["start"])
		var ln_len: int = int(sp["len"])
		out += UI.bb_escape(text.substr(pos, st - pos))
		out += "[b][color=#%s]%s[/color][/b]" % [Pal.PRIMARY.to_html(false), UI.bb_escape(text.substr(st, ln_len))]
		pos = st + ln_len
		break
	out += UI.bb_escape(text.substr(pos))
	return out
