class_name UI
extends RefCounted
## Small static helpers for building the interface in code.

static var _bold: SystemFont = null
static var _ja: SystemFont = null
static var _ja_bold: SystemFont = null
static var _cjk_rx: RegEx = null

## Fonts that exist on Android, appended behind the Windows names (same look on the PC).
const _ANDROID_FONTS := ["Roboto", "Noto Sans CJK KR", "Noto Sans KR", "Noto Sans CJK JP", "Noto Sans JP"]


static func bold_font() -> SystemFont:
	if _bold == null:
		_bold = SystemFont.new()
		_bold.font_names = PackedStringArray(["Malgun Gothic", "Yu Gothic UI", "Meiryo", "Segoe UI"] + _ANDROID_FONTS)
		_bold.font_weight = 700
	return _bold


## Font that renders Japanese kana/kanji with proper proportions (Yu Gothic UI first,
## Malgun Gothic as fallback for Hangul).
static func ja_font(bold: bool = false) -> SystemFont:
	if bold and _ja_bold != null:
		return _ja_bold
	if not bold and _ja != null:
		return _ja
	var f := SystemFont.new()
	f.font_names = PackedStringArray(["Yu Gothic UI", "Meiryo", "Malgun Gothic", "Segoe UI"] + _ANDROID_FONTS)
	f.font_weight = 700 if bold else 400
	var fb := SystemFont.new()
	fb.font_names = PackedStringArray(["Malgun Gothic", "Noto Sans CJK KR", "Noto Sans KR"])
	fb.font_weight = 700 if bold else 400
	var arr: Array[Font] = [fb]
	f.fallbacks = arr
	if bold:
		_ja_bold = f
	else:
		_ja = f
	return f


static func has_cjk(s: String) -> bool:
	if _cjk_rx == null:
		_cjk_rx = RegEx.new()
		_cjk_rx.compile("[\u3040-\u30ff\u31f0-\u31ff\u4e00-\u9fff]")
	return _cjk_rx.search(s) != null


const _BOLD_VARIATIONS := ["H1", "H2", "H3", "Strong", "Big", "Score", "Eyebrow"]


## Walks `root` and gives every label/button that contains Japanese text the Japanese font
## (the global theme font is Malgun Gothic, whose kana look too widely spaced).
static func fix_cjk(root: Node) -> void:
	for n in root.get_children():
		if n is Label or n is Button:
			var t: String = n.text
			if t != "" and has_cjk(t):
				var bold: bool = str(n.theme_type_variation) in _BOLD_VARIATIONS
				if not bold and n.has_theme_font_override("font"):
					bold = n.get_theme_font("font") == bold_font()
				n.add_theme_font_override("font", ja_font(bold))
		elif n is RichTextLabel:
			var rt: String = n.text
			if rt != "" and has_cjk(rt):
				n.add_theme_font_override("normal_font", ja_font(false))
				n.add_theme_font_override("bold_font", ja_font(true))
		fix_cjk(n)


## Removes and frees all children immediately (so layout does not see stale nodes).
static func clear(node: Node) -> void:
	for c in node.get_children():
		node.remove_child(c)
		c.queue_free()


## Strips the markdown that appears in the curriculum text.
static func plain(s: Variant) -> String:
	return str(s).replace("**", "").replace("`", "")


# ---------------------------------------------------------------- containers

static func vbox(sep: int = 10) -> VBoxContainer:
	var b := VBoxContainer.new()
	b.add_theme_constant_override("separation", sep)
	return b


static func hbox(sep: int = 8) -> HBoxContainer:
	var b := HBoxContainer.new()
	b.add_theme_constant_override("separation", sep)
	return b


static func flow(h_sep: int = 8, v_sep: int = 8) -> HFlowContainer:
	var f := HFlowContainer.new()
	f.add_theme_constant_override("h_separation", h_sep)
	f.add_theme_constant_override("v_separation", v_sep)
	return f


## Row on the PC (HBox), column on the phone (VBox). Children of a phone column fill its width.
static func adaptive(sep: int = 8) -> BoxContainer:
	return vbox(sep) if Platform.is_phone() else hbox(sep)


## Raises a control's minimum height (and width) to the phone touch size. No-op on the PC.
static func touch(c: Control, h: float = 48.0, w: float = 0.0) -> void:
	if Platform.is_phone():
		PhoneLayout.touch(c, h, w)


static func spacer() -> Control:
	var c := Control.new()
	c.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return c


static func gap(h: float) -> Control:
	var c := Control.new()
	c.custom_minimum_size = Vector2(0, h)
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return c


static func margin(child: Control, l: int, t: int, r: int, b: int) -> MarginContainer:
	var m := MarginContainer.new()
	m.add_theme_constant_override("margin_left", l)
	m.add_theme_constant_override("margin_top", t)
	m.add_theme_constant_override("margin_right", r)
	m.add_theme_constant_override("margin_bottom", b)
	m.add_child(child)
	return m


static func hline() -> HSeparator:
	return HSeparator.new()


## A panel with a style variation ("Card", "BigCard", "Sunk", ...) and an inner VBox.
static func card(variation: String = "Card", sep: int = 12) -> CardBox:
	var c := CardBox.new()
	c.theme_type_variation = variation
	c.body.add_theme_constant_override("separation", sep)
	return c


## Flat colored panel (e.g. the green/red feedback bar, chips).
static func tinted_panel(bg: Color, border: Color = Color(0, 0, 0, 0), bw: int = 0, radius: int = 10, ph: int = 14, pv: int = 10) -> PanelContainer:
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", style(bg, border, bw, radius, ph, pv))
	return p


static func style(bg: Color, border: Color = Color(0, 0, 0, 0), bw: int = 0, radius: int = 10, ph: int = 14, pv: int = 10) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.border_color = border
	s.set_border_width_all(bw)
	s.set_corner_radius_all(radius)
	s.content_margin_left = ph
	s.content_margin_right = ph
	s.content_margin_top = pv
	s.content_margin_bottom = pv
	return s


# ---------------------------------------------------------------- text

static func label(text: String, variation: String = "", wrap: bool = true) -> Label:
	var l := Label.new()
	l.text = text
	if variation != "":
		l.theme_type_variation = variation
	if wrap:
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return l


static func colored(text: String, color: Color, variation: String = "", wrap: bool = true) -> Label:
	var l := label(text, variation, wrap)
	l.add_theme_color_override("font_color", color)
	return l


## Pixel width of the widest line of `s` in the theme font.
static func text_width(s: String, font_size: int, bold: bool = false) -> float:
	var f: Font = bold_font() if bold else null
	if f == null:
		var th: Theme = ThemeDB.get_project_theme()
		f = th.default_font if th != null and th.default_font != null else ThemeDB.fallback_font
	var w := 0.0
	for line in s.split("
"):
		w = maxf(w, f.get_string_size(line, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x)
	return w


static func bb_escape(s: String) -> String:
	return s.replace("[", "[lb]")


## RichTextLabel that sizes itself to its content (BBCode on).
static func rich(bbcode: String, font_size: int = 16) -> RichTextLabel:
	var r := RichTextLabel.new()
	r.bbcode_enabled = true
	r.fit_content = true
	r.scroll_active = false
	r.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	r.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	r.add_theme_font_size_override("normal_font_size", font_size)
	r.text = bbcode
	return r


# ---------------------------------------------------------------- buttons

## kind: "default" (theme), "primary", "soft", "outline", "flat"
static func button(text: String, kind: String = "default", accent: Color = Pal.INK, min_h: float = 0.0) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	if min_h > 0.0:
		b.custom_minimum_size.y = min_h
	if Platform.is_phone():
		PhoneLayout.touch(b, PhoneLayout.BTN_H)
	style_button(b, kind, accent)
	return b


static func style_button(b: Button, kind: String, accent: Color) -> void:
	match kind:
		"primary":
			_apply(b, accent, accent.lightened(0.12), accent.darkened(0.15), Color.WHITE, Color(0, 0, 0, 0), 0)
			b.add_theme_font_override("font", bold_font())
		"soft":
			var bg := accent.lerp(Color.WHITE, 0.86)
			_apply(b, bg, accent.lerp(Color.WHITE, 0.78), accent.lerp(Color.WHITE, 0.68), accent, Color(0, 0, 0, 0), 0)
			b.add_theme_font_override("font", bold_font())
		"outline":
			_apply(b, Color(0, 0, 0, 0), accent.lerp(Color.WHITE, 0.9), accent.lerp(Color.WHITE, 0.8), accent, accent, 2)
			b.add_theme_font_override("font", bold_font())
		"flat":
			b.theme_type_variation = &"FlatButton"
		_:
			pass


static func _apply(b: Button, bg: Color, hover: Color, pressed: Color, fg: Color, border: Color, bw: int) -> void:
	b.add_theme_stylebox_override("normal", style(bg, border, bw, 10, 18, 11))
	b.add_theme_stylebox_override("hover", style(hover, border, bw, 10, 18, 11))
	b.add_theme_stylebox_override("pressed", style(pressed, border, bw, 10, 18, 11))
	b.add_theme_stylebox_override("hover_pressed", style(pressed, border, bw, 10, 18, 11))
	var dis_bg := Color(bg, bg.a * 0.4)
	b.add_theme_stylebox_override("disabled", style(dis_bg if bg.a > 0.0 else Color(0, 0, 0, 0), Color(border, border.a * 0.4), bw, 10, 18, 11))
	b.add_theme_stylebox_override("focus", style(Color(0, 0, 0, 0), Color("#7C9BE8"), 2, 10, 18, 11))
	b.add_theme_color_override("font_color", fg)
	b.add_theme_color_override("font_hover_color", fg)
	b.add_theme_color_override("font_pressed_color", fg)
	b.add_theme_color_override("font_hover_pressed_color", fg)
	b.add_theme_color_override("font_focus_color", fg)
	b.add_theme_color_override("font_disabled_color", Color(fg, 0.55))


## Left-aligned, wrapping answer button (choice / fill / listen).
static func option_row(text: String) -> Button:
	var b := Button.new()
	b.theme_type_variation = &"OptionRow"
	b.text = text
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	b.focus_mode = Control.FOCUS_NONE
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	b.add_theme_font_size_override("font_size", 17)
	if Platform.is_phone():
		PhoneLayout.touch(b, 52.0)
	return b


static func paint_option(b: Button, state: String, accent: Color) -> void:
	# state: "idle" | "picked" | "right" | "wrong"
	var bg := Pal.SURFACE
	var border := Pal.LINE
	match state:
		"picked":
			bg = accent.lerp(Color.WHITE, 0.9)
			border = accent
		"right":
			bg = Pal.OK_SOFT
			border = Pal.OK
		"wrong":
			bg = Pal.BAD_SOFT
			border = Pal.BAD
		_:
			b.remove_theme_stylebox_override("normal")
			b.remove_theme_stylebox_override("hover")
			b.remove_theme_stylebox_override("pressed")
			b.remove_theme_stylebox_override("disabled")
			return
	var s := style(bg, border, 2, 12, 16, 12)
	s.border_width_bottom = 4
	for n in ["normal", "hover", "pressed", "hover_pressed", "disabled"]:
		b.add_theme_stylebox_override(n, s)


static func tile(text: String) -> Button:
	var b := Button.new()
	b.theme_type_variation = &"Tile"
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	if Platform.is_phone():
		PhoneLayout.touch(b, PhoneLayout.BTN_H, 48.0)
	return b


## Small text-only action (듣기 / 천천히 / 번역 ...).
static func link_button(text: String, tip: String = "") -> Button:
	var b := Button.new()
	b.theme_type_variation = &"FlatButton"
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	b.add_theme_font_size_override("font_size", 14)
	if tip != "" and not Platform.is_phone():
		b.tooltip_text = tip
	if Platform.is_phone():
		b.add_theme_font_size_override("font_size", 15)
		PhoneLayout.touch(b, PhoneLayout.LINK_H, PhoneLayout.LINK_H)
	return b


## 듣기 / 천천히 pair that speaks `text` via the backend TTS.
static func speak_buttons(text: String, lang: String) -> HBoxContainer:
	var h := hbox(2)
	var b1 := link_button("▶ 듣기")
	b1.pressed.connect(func() -> void: Tts.speak(text, lang, false))
	var b2 := link_button("천천히")
	b2.pressed.connect(func() -> void: Tts.speak(text, lang, true))
	h.add_child(b1)
	h.add_child(b2)
	return h


# ---------------------------------------------------------------- widgets

## Segmented control. items = [[value, label], ...]. Calls on_change(value).
static func segmented(items: Array, current: String, on_change: Callable, accent_for: Callable = Callable()) -> PanelContainer:
	var p := PanelContainer.new()
	p.theme_type_variation = &"Seg"
	var h := hbox(2)
	p.add_child(h)
	var phone: bool = Platform.is_phone()
	if phone:
		p.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for it in items:
		var value: String = str(it[0])
		var b := Button.new()
		b.text = str(it[1])
		b.focus_mode = Control.FOCUS_NONE
		b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		if phone:
			b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			PhoneLayout.touch(b, PhoneLayout.LINK_H)
		var sel: bool = value == current
		var fg: Color = Pal.MUTED
		if sel:
			fg = accent_for.call(value) if accent_for.is_valid() else Pal.INK
			var s := style(Pal.SURFACE, Color(0, 0, 0, 0), 0, 8, 18, 7)
			s.shadow_color = Color(0, 0, 0, 0.12)
			s.shadow_size = 2
			s.shadow_offset = Vector2(0, 1)
			for n in ["normal", "hover", "pressed", "hover_pressed", "disabled"]:
				b.add_theme_stylebox_override(n, s)
			b.add_theme_font_override("font", bold_font())
		else:
			var f := style(Color(0, 0, 0, 0), Color(0, 0, 0, 0), 0, 8, 18, 7)
			var hv := style(Color(1, 1, 1, 0.55), Color(0, 0, 0, 0), 0, 8, 18, 7)
			b.add_theme_stylebox_override("normal", f)
			b.add_theme_stylebox_override("hover", hv)
			b.add_theme_stylebox_override("pressed", hv)
			b.add_theme_stylebox_override("hover_pressed", hv)
		b.add_theme_color_override("font_color", fg)
		b.add_theme_color_override("font_hover_color", fg)
		b.add_theme_color_override("font_pressed_color", fg)
		b.add_theme_color_override("font_hover_pressed_color", fg)
		b.pressed.connect(func() -> void: on_change.call(value))
		h.add_child(b)
	return p


static func lang_segmented(current: String, on_change: Callable) -> PanelContainer:
	return segmented([["en", "영어 English"], ["ja", "일본어 日本語"]], current, on_change, Pal.accent)


static func chip(text: String, fg: Color, bg: Color, tip: String = "") -> PanelContainer:
	var p := tinted_panel(bg, Color(0, 0, 0, 0), 0, 99, 10, 2)
	var l := Label.new()
	l.text = text
	l.add_theme_color_override("font_color", fg)
	l.add_theme_font_size_override("font_size", 13)
	l.add_theme_font_override("font", bold_font())
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	p.add_child(l)
	if tip != "":
		p.tooltip_text = tip
	else:
		p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return p


static func progress_bar(value: float, color: Color, height: float = 10.0) -> ProgressBar:
	var b := ProgressBar.new()
	b.min_value = 0.0
	b.max_value = 1.0
	b.value = clampf(value, 0.0, 1.0)
	b.show_percentage = false
	b.custom_minimum_size = Vector2(0, height)
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	b.add_theme_stylebox_override("fill", style(color, Color(0, 0, 0, 0), 0, 99, 0, 0))
	return b


## Checkbox row with a wrapping label. on_toggle(bool).
static func check_row(text: String, checked: bool, on_toggle: Callable, sub: String = "") -> HBoxContainer:
	var row := hbox(8)
	var cb := CheckBox.new()
	cb.button_pressed = checked
	cb.focus_mode = Control.FOCUS_NONE
	cb.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	cb.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	if Platform.is_phone():
		PhoneLayout.touch(cb, PhoneLayout.BTN_H, PhoneLayout.BTN_H)
	cb.toggled.connect(func(on: bool) -> void: on_toggle.call(on))
	row.add_child(cb)
	var col := vbox(1)
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if Platform.is_phone():
		col.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		row.custom_minimum_size.y = PhoneLayout.BTN_H
	var l := label(text, "Strong" if sub != "" else "")
	if checked:
		l.add_theme_color_override("font_color", Pal.MUTED)
	l.mouse_filter = Control.MOUSE_FILTER_STOP
	l.gui_input.connect(func(ev: InputEvent) -> void:
		if ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_LEFT:
			cb.button_pressed = not cb.button_pressed)
	col.add_child(l)
	if sub != "":
		col.add_child(label(sub, "Small"))
	row.add_child(col)
	return row


## Labeled toggle (checkbox with plain text) bound to a pref key.
static func pref_toggle(text: String, pref_key: String) -> CheckBox:
	var cb := CheckBox.new()
	cb.text = text
	cb.focus_mode = Control.FOCUS_NONE
	cb.button_pressed = Store.pref_bool(pref_key)
	cb.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	cb.toggled.connect(func(on: bool) -> void: Store.set_pref(pref_key, on))
	if Platform.is_phone():
		cb.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		PhoneLayout.touch(cb, PhoneLayout.BTN_H)
	return cb


static func option_button(items: Array, selected: int) -> OptionButton:
	var o := OptionButton.new()
	o.focus_mode = Control.FOCUS_NONE
	o.fit_to_longest_item = false
	o.clip_text = true
	o.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	if Platform.is_phone():
		PhoneLayout.touch(o, PhoneLayout.BTN_H)
	for it in items:
		o.add_item(str(it))
	if selected >= 0 and selected < items.size():
		o.select(selected)
	return o


static func field(caption: String, control: Control) -> VBoxContainer:
	var v := vbox(4)
	v.add_child(label(caption, "Small"))
	v.add_child(control)
	return v


## Scrolls a ScrollContainer to the bottom after layout settles.
static func scroll_to_bottom(sc: ScrollContainer) -> void:
	if not sc.is_inside_tree():
		return
	await sc.get_tree().process_frame
	await sc.get_tree().process_frame
	if is_instance_valid(sc):
		var bar := sc.get_v_scroll_bar()
		sc.scroll_vertical = int(bar.max_value)
