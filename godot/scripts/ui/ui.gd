class_name UI
extends RefCounted
## Small static helpers for building the interface in code.

static var _bold: SystemFont = null
static var _ja: SystemFont = null
static var _ja_bold: SystemFont = null
static var _cjk_rx: RegEx = null

## Button / chip style sets are shared between buttons of the same look (key = kind|accent|scheme|scale|platform):
## 200 buttons cost a handful of StyleBoxes instead of 1200. Only UI.button / style_button / filter_chip use it;
## UI.style() still returns a fresh object because callers edit what they get. Tests switch it off to measure.
static var cache_enabled: bool = true
static var _cache: Dictionary = {}

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


const _BOLD_VARIATIONS := ["H1", "H2", "H3", "Strong", "Big", "Score", "Eyebrow", "LargeTitle", "AppBarTitle", "SectionHeader"]


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


## A fixed text size n times the user's font size setting (Ds.fs). Every add_theme_font_size_override goes through it.
static func fs(n: int) -> int:
	return Ds.fs(n)


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


## Calls `cb` when the control is clicked with the left button. PC: on press, as always. Phone: on release, and only
## when the finger stayed within PhoneLayout.TAP_SLOP, so a drag that starts on the control scrolls the page
## instead of triggering it.
static func on_tap(c: Control, cb: Callable) -> void:
	if not Platform.is_phone():
		c.gui_input.connect(func(ev: InputEvent) -> void:
			if ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_LEFT:
				cb.call())
		return
	var st := {"down": false, "pos": Vector2.ZERO}
	c.gui_input.connect(func(ev: InputEvent) -> void:
		if not (ev is InputEventMouseButton) or (ev as InputEventMouseButton).button_index != MOUSE_BUTTON_LEFT:
			return
		var mb := ev as InputEventMouseButton
		if mb.pressed:
			st["down"] = true
			st["pos"] = mb.global_position
		elif st["down"]:
			st["down"] = false
			if (mb.global_position - (st["pos"] as Vector2)).length() <= PhoneLayout.TAP_SLOP:
				cb.call())


## Connects RichTextLabel.meta_clicked to `cb(meta)`. Phone: a click that ends a drag (the finger moved more than
## PhoneLayout.TAP_SLOP since the press, i.e. the page was scrolled) is ignored, so scrolling over a word or a link
## does not select it on lift-off. PC: plain connect.
static func on_meta_click(rtl: RichTextLabel, cb: Callable) -> void:
	if not Platform.is_phone():
		rtl.meta_clicked.connect(cb)
		return
	var st := {"start": Vector2.ZERO, "moved": false}
	rtl.gui_input.connect(func(ev: InputEvent) -> void: # the signal runs before the label emits meta_clicked
		if ev is InputEventMouseButton and (ev as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
			var mb := ev as InputEventMouseButton
			if mb.pressed:
				st["start"] = mb.global_position
				st["moved"] = false
			elif (mb.global_position - (st["start"] as Vector2)).length() > PhoneLayout.TAP_SLOP:
				st["moved"] = true
		elif ev is InputEventMouseMotion and ((ev as InputEventMouseMotion).button_mask & MOUSE_BUTTON_MASK_LEFT) != 0:
			if ((ev as InputEventMouseMotion).global_position - (st["start"] as Vector2)).length() > PhoneLayout.TAP_SLOP:
				st["moved"] = true)
	rtl.meta_clicked.connect(func(meta: Variant) -> void:
		if not st["moved"]:
			cb.call(meta))


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
	if variation == "Group":
		return ListGroup.new() # rows bring their own padding and dividers: no body separation
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
	r.add_theme_font_size_override("normal_font_size", fs(font_size))
	r.text = bbcode
	return r


# ---------------------------------------------------------------- buttons

## kind: "default" (theme), "primary", "soft", "outline", "flat", "danger"; any other word keeps the theme look.
## Height is max(min_h, Ds.btn_h()): 48 (touch target) on the phone, 40 on the PC.
static func button(text: String, kind: String = "default", accent: Color = Pal.INK, min_h: float = 0.0) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	if Platform.is_phone():
		b.custom_minimum_size.y = maxf(min_h, Ds.btn_h())
	elif min_h > 0.0:
		b.custom_minimum_size.y = min_h # PC: no forced height (phone_layout_test L-06); the padding keeps it >= 40
	style_button(b, kind, accent)
	return b


## The colour pair of an accent: [tonal surface, text colour that reads on it]. The known accents map to the SOFT / *_ON
## tokens (light and dark); INK maps to SUNK; an unknown colour is mixed into the surface and keeps itself as text.
static func soft_pair(accent: Color) -> Array:
	if accent.is_equal_approx(Pal.EN):
		return [Pal.EN_SOFT, Pal.EN_ON]
	if accent.is_equal_approx(Pal.JA):
		return [Pal.JA_SOFT, Pal.JA_ON]
	if accent.is_equal_approx(Pal.OK):
		return [Pal.OK_SOFT, Pal.OK_ON]
	if accent.is_equal_approx(Pal.BAD):
		return [Pal.BAD_SOFT, Pal.BAD_ON]
	if accent.is_equal_approx(Pal.WARN):
		return [Pal.WARN_SOFT, Pal.WARN_ON]
	if accent.is_equal_approx(Pal.PRIMARY):
		return [Pal.PRIMARY_SOFT, Pal.PRIMARY]
	if accent.is_equal_approx(Pal.INK):
		return [Pal.SUNK, Pal.INK]
	return [accent.lerp(Pal.SURFACE, 0.86), accent]


static func style_button(b: Button, kind: String, accent: Color) -> void:
	if kind == "flat":
		b.theme_type_variation = &"FlatButton"
		_clear_button_overrides(b)
		_pc_pad(b, "flat")
		if not accent.is_equal_approx(Pal.INK): # the default accent keeps the theme's muted flat look
			var fg: Color = (soft_pair(accent) as Array)[1]
			for n in ["font_color", "font_hover_color", "font_pressed_color", "font_hover_pressed_color", "font_focus_color"]:
				b.add_theme_color_override(n, fg)
		return
	var st: Dictionary = _button_styles(kind, accent)
	if st.is_empty():
		if kind == "default":
			_pc_pad(b, "default")
		return # unknown kind: the theme's default Button look
	for n in ["normal", "hover", "pressed", "hover_pressed", "disabled", "focus"]:
		b.add_theme_stylebox_override(n, st[n])
	var fg2: Color = st["fg"]
	b.add_theme_color_override("font_color", fg2)
	b.add_theme_color_override("font_hover_color", fg2)
	b.add_theme_color_override("font_pressed_color", fg2)
	b.add_theme_color_override("font_hover_pressed_color", fg2)
	b.add_theme_color_override("font_focus_color", fg2)
	b.add_theme_color_override("font_disabled_color", Color(fg2, 0.55))
	b.add_theme_font_override("font", bold_font())


## PC only: the theme's Button / FlatButton padding gives 39 / 35 px, below the 40 px minimum, and a forced
## custom_minimum_size is not allowed (phone_layout_test L-06). So the same styles come back with 10 px top and
## bottom padding (shared per scheme, see cache_enabled).
static func _pc_pad(b: Button, which: String) -> void:
	if Platform.is_phone():
		return
	var key := "pcpad|%s|%s" % [which, Pal.scheme()]
	var d: Dictionary
	if cache_enabled and _cache.has(key):
		d = _cache[key]
	else:
		d = {}
		for n in ["normal", "hover", "pressed", "hover_pressed", "disabled"]:
			var sb: StyleBox = (b.get_theme_stylebox(n) as StyleBox).duplicate()
			sb.content_margin_top = 10.0
			sb.content_margin_bottom = 10.0
			d[n] = sb
		if cache_enabled:
			_cache[key] = d
	for n in d.keys():
		b.add_theme_stylebox_override(n, d[n])


static func _clear_button_overrides(b: Button) -> void:
	for n in ["normal", "hover", "pressed", "hover_pressed", "disabled", "focus"]:
		b.remove_theme_stylebox_override(n)
	for n in ["font_color", "font_hover_color", "font_pressed_color", "font_hover_pressed_color", "font_focus_color", "font_disabled_color"]:
		b.remove_theme_color_override(n)
	b.remove_theme_font_override("font")


## The shared style set of a button look (normal / hover / pressed / hover_pressed / disabled / focus + "fg"), or {} for an
## unknown kind. Cached; see cache_enabled.
static func _button_styles(kind: String, accent: Color) -> Dictionary:
	if kind != "primary" and kind != "soft" and kind != "outline" and kind != "danger":
		return {}
	var key := "%s|%s|%s|%s|%s" % [kind, accent.to_html(true), Pal.scheme(), Ds.font_scale, Platform.is_phone()]
	if cache_enabled and _cache.has(key):
		return _cache[key]
	var bg: Color
	var hover: Color
	var pressed: Color
	var fg: Color
	var border: Color = Color(0, 0, 0, 0)
	var bw: int = 0
	if kind == "primary" or kind == "danger":
		var fill: Color = Pal.BAD if kind == "danger" else accent
		bg = fill
		hover = fill.lightened(0.12)
		pressed = fill.darkened(0.15)
		fg = Pal.ON_ACCENT
	else:
		var pair: Array = soft_pair(accent)
		bg = pair[0]
		fg = pair[1]
		hover = bg.lerp(fg, 0.08)
		pressed = bg.lerp(fg, 0.16)
		if kind == "outline":
			border = fg
			bw = 2 # outline = tonal + a 2 px border (StyleBox borders are whole px)
	var d := {}
	d["normal"] = _btn_style(bg, border, bw)
	d["hover"] = _btn_style(hover, border, bw)
	d["pressed"] = _btn_style(pressed, border, bw)
	d["hover_pressed"] = d["pressed"]
	d["disabled"] = _btn_style(Color(bg, bg.a * 0.4), Color(border, border.a * 0.4), bw)
	d["focus"] = _btn_style(Color(0, 0, 0, 0), Pal.PRIMARY, 2)
	d["fg"] = fg
	if cache_enabled:
		_cache[key] = d
	return d


static func _btn_style(bg: Color, border: Color, bw: int) -> StyleBoxFlat:
	return style(bg, border, bw, Ds.R_BTN, 18, 11)


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
	b.add_theme_font_size_override("font_size", fs(17))
	b.custom_minimum_size.y = maxf(Ds.btn_h(), 52.0 if Platform.is_phone() else 0.0)
	return b


static func paint_option(b: Button, state: String, accent: Color) -> void:
	# state: "idle" | "picked" | "right" | "wrong"
	var bg := Pal.SURFACE
	var border := Pal.LINE
	match state:
		"picked":
			bg = (soft_pair(accent) as Array)[0]
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
	var s := style(bg, border, 2, Ds.R_S, 16, 12)
	s.border_width_bottom = 4
	for n in ["normal", "hover", "pressed", "hover_pressed", "disabled"]:
		b.add_theme_stylebox_override(n, s)


static func tile(text: String) -> Button:
	var b := Button.new()
	b.theme_type_variation = &"Tile"
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	b.custom_minimum_size.y = Ds.btn_h()
	if Platform.is_phone():
		b.custom_minimum_size.x = maxf(b.custom_minimum_size.x, Ds.touch_min())
	return b


## Small text-only action (듣기 / 천천히 / 번역 ...). Phone: at least touch_min (48 dp) in both directions.
static func link_button(text: String, tip: String = "") -> Button:
	var b := Button.new()
	b.theme_type_variation = &"FlatButton"
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	b.add_theme_font_size_override("font_size", fs(14))
	if tip != "" and not Platform.is_phone():
		b.tooltip_text = tip
	if Platform.is_phone():
		b.add_theme_font_size_override("font_size", fs(15))
		var m: float = Ds.touch_min()
		b.custom_minimum_size.y = maxf(b.custom_minimum_size.y, m)
		b.custom_minimum_size.x = maxf(b.custom_minimum_size.x, m)
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
	var r: int = Ds.R_BTN - 3 # the Seg panel pads its buttons by 3
	for it in items:
		var value: String = str(it[0])
		var b := Button.new()
		b.text = str(it[1])
		b.focus_mode = Control.FOCUS_NONE
		b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		b.custom_minimum_size.y = Ds.touch_min()
		if phone:
			b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var sel: bool = value == current
		var fg: Color = Pal.MUTED
		if sel:
			fg = accent_for.call(value) if accent_for.is_valid() else Pal.INK
			var s := style(Pal.SURFACE, Color(0, 0, 0, 0), 0, r, 18, 7)
			if not Pal.is_dark(): # dark: the lighter surface already separates the selected segment
				s.shadow_color = Color(0, 0, 0, 0.12)
				s.shadow_size = 2
				s.shadow_offset = Vector2(0, 1)
			for n in ["normal", "hover", "pressed", "hover_pressed", "disabled"]:
				b.add_theme_stylebox_override(n, s)
			b.add_theme_font_override("font", bold_font())
		else:
			var f := style(Color(0, 0, 0, 0), Color(0, 0, 0, 0), 0, r, 18, 7)
			var hv := style(Color(Pal.SURFACE, 0.55), Color(0, 0, 0, 0), 0, r, 18, 7)
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


## Display chip (not pressable), 28 px high. The caller picks fg / bg: use chip_kind unless the pair is already a
## text-safe one (a *_ON colour on its SOFT surface).
static func chip(text: String, fg: Color, bg: Color, tip: String = "") -> PanelContainer:
	var p := tinted_panel(bg, Color(0, 0, 0, 0), 0, Ds.R_PILL, 10, 2)
	p.custom_minimum_size.y = 28.0
	var l := Label.new()
	l.text = text
	l.add_theme_color_override("font_color", fg)
	l.add_theme_font_size_override("font_size", fs(13))
	l.add_theme_font_override("font", bold_font())
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	p.add_child(l)
	if tip != "":
		p.tooltip_text = tip
	else:
		p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return p


## Display chip with a text-safe colour pair. kind: "ok" | "bad" | "warn" | "info" | "lang_en" | "lang_ja" | "neutral"
## (anything else counts as "neutral").
static func chip_kind(text: String, kind: String, tip: String = "") -> PanelContainer:
	var fg: Color = Pal.MUTED
	var bg: Color = Pal.SUNK
	match kind:
		"ok":
			fg = Pal.OK_ON
			bg = Pal.OK_SOFT
		"bad":
			fg = Pal.BAD_ON
			bg = Pal.BAD_SOFT
		"warn":
			fg = Pal.WARN_ON
			bg = Pal.WARN_SOFT
		"info":
			fg = Pal.PRIMARY
			bg = Pal.PRIMARY_SOFT
		"lang_en":
			fg = Pal.EN_ON
			bg = Pal.EN_SOFT
		"lang_ja":
			fg = Pal.JA_ON
			bg = Pal.JA_SOFT
		_:
			pass
	return chip(text, fg, bg, tip)


## Pressable choice chip. Phone: the hit area is touch_min tall and the drawn pill 8 px shorter (the stylebox is inset
## top and bottom); PC: 32. Selected = PRIMARY_SOFT surface + 2 px PRIMARY outline + bold text (colour, outline and weight
## all differ, never colour alone). `on_tap` is called when the chip is pressed: with the new state (not selected) when
## it takes one argument, else without arguments. The chip does not flip itself: the caller rebuilds it.
static func filter_chip(text: String, selected: bool, on_tap: Callable) -> Button:
	var b := Button.new()
	b.theme_type_variation = &"FilterChip"
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	var phone: bool = Platform.is_phone()
	b.custom_minimum_size.y = Ds.touch_min() if phone else 32.0
	var inset: float = 4.0 if phone else 0.0
	var key := "chip|%s|%s|%s|%s|%s" % [selected, Pal.scheme(), Ds.font_scale, phone, inset]
	var st: Dictionary
	if cache_enabled and _cache.has(key):
		st = _cache[key]
	else:
		st = {}
		var n: StyleBoxFlat
		var hv: StyleBoxFlat
		var pr: StyleBoxFlat
		if selected:
			n = style(Pal.PRIMARY_SOFT, Pal.PRIMARY, 2, Ds.R_PILL, 14, 6)
			hv = n
			pr = n
		else:
			n = style(Pal.SURFACE, Pal.LINE_STRONG, 1, Ds.R_PILL, 14, 6)
			hv = style(Pal.SUNK, Pal.LINE_STRONG, 1, Ds.R_PILL, 14, 6)
			pr = style(Pal.PRIMARY_SOFT, Pal.PRIMARY, 2, Ds.R_PILL, 14, 6)
		for sb in [n, hv, pr]:
			(sb as StyleBoxFlat).expand_margin_top = -inset
			(sb as StyleBoxFlat).expand_margin_bottom = -inset
		st["normal"] = n
		st["hover"] = hv
		st["pressed"] = pr
		if cache_enabled:
			_cache[key] = st
	for k in ["normal", "hover", "pressed", "hover_pressed"]:
		b.add_theme_stylebox_override(k, st["pressed" if k == "hover_pressed" else k])
	if selected:
		b.add_theme_color_override("font_color", Pal.PRIMARY)
		b.add_theme_color_override("font_hover_color", Pal.PRIMARY)
		b.add_theme_color_override("font_pressed_color", Pal.PRIMARY)
		b.add_theme_font_override("font", bold_font())
	b.pressed.connect(func() -> void:
		if on_tap.is_valid():
			if on_tap.get_argument_count() >= 1:
				on_tap.call(not selected)
			else:
				on_tap.call())
	return b


static func progress_bar(value: float, color: Color, height: float = 10.0) -> ProgressBar:
	var b := ProgressBar.new()
	b.min_value = 0.0
	b.max_value = 1.0
	b.value = clampf(value, 0.0, 1.0)
	b.show_percentage = false
	b.custom_minimum_size = Vector2(0, height)
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	b.add_theme_stylebox_override("fill", style(color, Color(0, 0, 0, 0), 0, Ds.R_PILL, 0, 0))
	return b


## Same look for an unknown amount of work (splash, waiting for the engine).
static func progress_indeterminate(color: Color, height: float = 10.0) -> ProgressBar:
	var b := progress_bar(0.0, color, height)
	b.indeterminate = true
	return b


## Checkbox row with a wrapping label. on_toggle(bool).
static func check_row(text: String, checked: bool, on_toggle: Callable, sub: String = "") -> HBoxContainer:
	var row := hbox(8)
	var cb := CheckBox.new()
	cb.button_pressed = checked
	cb.focus_mode = Control.FOCUS_NONE
	cb.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	cb.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	var m: float = Ds.touch_min()
	cb.custom_minimum_size = Vector2(m, m)
	cb.accessibility_name = text
	cb.toggled.connect(func(on: bool) -> void: on_toggle.call(on))
	row.add_child(cb)
	var col := vbox(1)
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if Platform.is_phone():
		col.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		row.custom_minimum_size.y = m
	var l := label(text, "Strong" if sub != "" else "")
	if checked:
		l.add_theme_color_override("font_color", Pal.MUTED)
	l.mouse_filter = Control.MOUSE_FILTER_STOP
	on_tap(l, func() -> void: cb.button_pressed = not cb.button_pressed)
	col.add_child(l)
	if sub != "":
		col.add_child(label(sub, "Small"))
	row.add_child(col)
	return row


## Labeled toggle (checkbox with plain text) bound to a pref key. For an on/off setting prefer pref_switch.
static func pref_toggle(text: String, pref_key: String) -> CheckBox:
	var cb := CheckBox.new()
	cb.text = text
	cb.focus_mode = Control.FOCUS_NONE
	cb.button_pressed = Store.pref_bool(pref_key)
	cb.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	cb.toggled.connect(func(on: bool) -> void: Store.set_pref(pref_key, on))
	if Platform.is_phone():
		cb.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	cb.custom_minimum_size.y = Ds.touch_min()
	return cb


## A switch (CheckButton, 52x32 track) without text; the hit area is at least 56x48.
static func switch_button(on: bool = false) -> CheckButton:
	var cb := CheckButton.new()
	cb.focus_mode = Control.FOCUS_NONE
	cb.button_pressed = on
	cb.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	cb.custom_minimum_size = Vector2(56.0, maxf(48.0, Ds.touch_min()))
	return cb


## Labeled on/off setting bound to a pref key (same keys as pref_toggle): text on the left, switch on the right.
static func pref_switch(text: String, pref_key: String) -> CheckButton:
	var cb := CheckButton.new()
	cb.text = text
	cb.focus_mode = Control.FOCUS_NONE
	cb.button_pressed = Store.pref_bool(pref_key)
	cb.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	cb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cb.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	cb.custom_minimum_size.y = maxf(48.0, Ds.touch_min())
	cb.accessibility_name = text
	cb.toggled.connect(func(on: bool) -> void: Store.set_pref(pref_key, on))
	return cb


## Row with a label (+ optional smaller line) and a switch at its right end; tapping the text toggles the switch too.
## The switch is row.get_meta("switch"). on_toggle(bool).
static func switch_row(text: String, checked: bool, on_toggle: Callable, sub: String = "") -> HBoxContainer:
	var row := hbox(12)
	row.custom_minimum_size.y = ListGroup.ROW_H_SUB if sub != "" else ListGroup.ROW_H
	var col := vbox(1)
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.size_flags_vertical = Control.SIZE_EXPAND_FILL
	col.alignment = BoxContainer.ALIGNMENT_CENTER
	var cb := switch_button(checked)
	cb.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	cb.accessibility_name = text
	cb.toggled.connect(func(on: bool) -> void: on_toggle.call(on))
	var flip := func() -> void: cb.button_pressed = not cb.button_pressed
	var l := label(text, "ListMain")
	l.mouse_filter = Control.MOUSE_FILTER_STOP
	on_tap(l, flip)
	col.add_child(l)
	if sub != "":
		var sl := label(sub, "ListSub")
		sl.mouse_filter = Control.MOUSE_FILTER_STOP
		on_tap(sl, flip)
		col.add_child(sl)
	row.add_child(col)
	row.add_child(cb)
	row.set_meta("switch", cb)
	return row


static func option_button(items: Array, selected: int) -> OptionButton:
	var o := OptionButton.new()
	o.focus_mode = Control.FOCUS_NONE
	o.fit_to_longest_item = false
	o.clip_text = true
	o.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	o.custom_minimum_size.y = maxf(o.custom_minimum_size.y, Ds.field_h())
	for it in items:
		o.add_item(str(it))
	if selected >= 0 and selected < items.size():
		o.select(selected)
	return o


## Caption (small, muted) above an input. A single-line input (LineEdit, SpinBox, OptionButton) gets Ds.field_h() as
## minimum height here: the theme does not size inputs (phone_layout_test measures the phone layout).
static func field(caption: String, control: Control) -> VBoxContainer:
	var v := vbox(4)
	v.add_child(label(caption, "Small"))
	if control is LineEdit or control is OptionButton or control is SpinBox:
		control.custom_minimum_size.y = maxf(control.custom_minimum_size.y, Ds.field_h())
	v.add_child(control)
	return v


## Section heading for a ListGroup / card stack (SectionHeader variation): `top` px above, 8 below, 8 at the left
## (page margin 16 + 8 = 24 from the screen edge).
static func section_header(text: String, top: int = Ds.S6) -> Label:
	return ListGroup.header(text, top)


## Scrolls a ScrollContainer to the bottom after layout settles.
static func scroll_to_bottom(sc: ScrollContainer) -> void:
	if not is_instance_valid(sc) or not sc.is_inside_tree():
		return
	var tree: SceneTree = sc.get_tree()
	await tree.process_frame
	if not is_instance_valid(sc):
		return
	await tree.process_frame
	if is_instance_valid(sc):
		var bar := sc.get_v_scroll_bar()
		sc.scroll_vertical = int(bar.max_value)
