extends SceneTree
## Generates the two themes from the Pal / Ds tokens (run after changing a token; docs/ui_redesign_design.md §5):
##   godot --headless --path <project> --script res://tools/make_theme.gd
## Writes res://theme/app_theme.tres (light) and res://theme/app_theme_dark.tres (dark). Sizes are the PC sizes;
## PhoneLayout.apply_theme raises them for the phone and UiBoot.apply applies the font scale at start.
## Class names (Pal, Ds, ThemeIcons) must be known: run `godot --headless --path <project> --import` once after
## adding a script with a class_name.

const NAMES := ["Malgun Gothic", "Yu Gothic UI", "Meiryo", "Segoe UI"]
const OUT_LIGHT := "res://theme/app_theme.tres"
const OUT_DARK := "res://theme/app_theme_dark.tres"

const CLEAR := Color(0, 0, 0, 0)


func _init() -> void:
	var failed := 0
	for spec in [["light", OUT_LIGHT], ["dark", OUT_DARK]]:
		Pal.use(spec[0])
		var theme := build()
		var err := ResourceSaver.save(theme, spec[1])
		print("theme saved: ", spec[1], " err=", err)
		if err != OK:
			failed += 1
	Pal.use("light")
	quit(1 if failed > 0 else 0)


## The theme for the current Pal scheme.
func build() -> Theme:
	var theme := Theme.new()
	var font := _font(false)
	var bold := _font(true)
	theme.default_font = font
	theme.default_font_size = Ds.type_size_for("", false)

	_labels(theme, bold)
	_buttons(theme, bold)
	_panels(theme)
	_inputs(theme)
	_check_and_slider(theme)
	_popup(theme)
	_scroll_and_progress(theme)
	ThemeIcons.apply(theme)
	return theme


func _font(is_bold: bool) -> SystemFont:
	var f := SystemFont.new()
	f.font_names = PackedStringArray(NAMES)
	f.font_weight = 700 if is_bold else 400
	f.antialiasing = TextServer.FONT_ANTIALIASING_GRAY
	var fb: Array[Font] = []
	for n in ["Yu Gothic UI", "Meiryo", "Segoe UI Symbol"]:
		var s := SystemFont.new()
		s.font_names = PackedStringArray([n])
		s.font_weight = 700 if is_bold else 400
		fb.append(s)
	f.fallbacks = fb
	return f


func _sb(bg: Color, radius: int = 8, border: Color = CLEAR, bw: int = 0, ph: int = 14, pv: int = 8) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.set_corner_radius_all(radius)
	s.set_border_width_all(bw)
	s.border_color = border
	s.content_margin_left = ph
	s.content_margin_right = ph
	s.content_margin_top = pv
	s.content_margin_bottom = pv
	return s


func _empty(ph: int = 0, pv: int = 0) -> StyleBoxEmpty:
	var s := StyleBoxEmpty.new()
	s.content_margin_left = ph
	s.content_margin_right = ph
	s.content_margin_top = pv
	s.content_margin_bottom = pv
	return s


func _variation(theme: Theme, vname: String, base: String) -> void:
	theme.set_type_variation(vname, base)


## `Pal.SURFACE` nudged towards INK: a hover / pressed tint that works in both schemes.
func _tint(base: Color, amount: float) -> Color:
	return base.lerp(Pal.INK, amount)


func _labels(theme: Theme, bold: Font) -> void:
	theme.set_color("font_color", "Label", Pal.INK)
	theme.set_color("font_shadow_color", "Label", CLEAR)
	theme.set_constant("line_spacing", "Label", 4)
	theme.set_constant("line_separation", "RichTextLabel", 2)
	# [name, colour, bold]; the size comes from Ds.TYPE_TABLE
	for spec in [
		["H1", Pal.INK, true], ["H2", Pal.INK, true], ["H3", Pal.INK, true],
		["Muted", Pal.MUTED, false], ["Small", Pal.MUTED, false],
		["Eyebrow", Pal.MUTED, true], ["Big", Pal.INK, true], ["Strong", Pal.INK, true],
		["Score", Pal.INK, true],
		["LargeTitle", Pal.INK, true], ["AppBarTitle", Pal.INK, true], ["SectionHeader", Pal.PRIMARY, true],
		["ListMain", Pal.INK, false], ["ListSub", Pal.MUTED, false],
	]:
		var vname: String = spec[0]
		_variation(theme, vname, "Label")
		theme.set_font_size("font_size", vname, Ds.type_size_for(vname, false))
		theme.set_color("font_color", vname, spec[1])
		if spec[2]:
			theme.set_font("font", vname, bold)
	theme.set_color("default_color", "RichTextLabel", Pal.INK)
	theme.set_font("bold_font", "RichTextLabel", bold)
	theme.set_color("font_selected_color", "RichTextLabel", Pal.INK)
	theme.set_color("selection_color", "RichTextLabel", Color(Pal.PRIMARY, 0.30))


func _buttons(theme: Theme, bold: Font) -> void:
	var r := Ds.R_BTN
	var normal := _sb(Pal.SURFACE, r, Pal.LINE, 1, 16, 8)
	var hover := _sb(_tint(Pal.SURFACE, 0.05), r, Pal.LINE_STRONG, 1, 16, 8)
	var pressed := _sb(_tint(Pal.SURFACE, 0.10), r, Pal.LINE_STRONG, 1, 16, 8)
	var disabled := _sb(Pal.BG, r, Pal.LINE, 1, 16, 8)
	var focus := _sb(CLEAR, r, Pal.PRIMARY, 2, 16, 8)
	theme.set_stylebox("normal", "Button", normal)
	theme.set_stylebox("hover", "Button", hover)
	theme.set_stylebox("pressed", "Button", pressed)
	theme.set_stylebox("hover_pressed", "Button", pressed)
	theme.set_stylebox("disabled", "Button", disabled)
	theme.set_stylebox("focus", "Button", focus)
	theme.set_color("font_color", "Button", Pal.INK)
	theme.set_color("font_hover_color", "Button", Pal.INK)
	theme.set_color("font_pressed_color", "Button", Pal.INK)
	theme.set_color("font_hover_pressed_color", "Button", Pal.INK)
	theme.set_color("font_focus_color", "Button", Pal.INK)
	theme.set_color("font_disabled_color", "Button", Color(Pal.MUTED, 0.55))
	theme.set_constant("h_separation", "Button", 6)

	# Flat button used for tabs, icon-ish actions and links.
	_variation(theme, "FlatButton", "Button")
	theme.set_stylebox("normal", "FlatButton", _empty(10, 6))
	theme.set_stylebox("hover", "FlatButton", _sb(Pal.SUNK, r, CLEAR, 0, 10, 6))
	theme.set_stylebox("pressed", "FlatButton", _sb(_tint(Pal.SUNK, 0.08), r, CLEAR, 0, 10, 6))
	theme.set_stylebox("hover_pressed", "FlatButton", _sb(_tint(Pal.SUNK, 0.08), r, CLEAR, 0, 10, 6))
	theme.set_stylebox("disabled", "FlatButton", _empty(10, 6))
	theme.set_color("font_color", "FlatButton", Pal.MUTED)
	theme.set_color("font_hover_color", "FlatButton", Pal.INK)

	# Answer option (choice / fill / listen): wide, left aligned, thick bottom border.
	_variation(theme, "OptionRow", "Button")
	var opt_n := _sb(Pal.SURFACE, Ds.R_S, Pal.LINE, 2, 16, 12)
	opt_n.border_width_bottom = 4
	var opt_h := _sb(_tint(Pal.SURFACE, 0.03), Ds.R_S, Pal.LINE_STRONG, 2, 16, 12)
	opt_h.border_width_bottom = 4
	var opt_p := _sb(Pal.PRIMARY_SOFT, Ds.R_S, Pal.PRIMARY, 2, 16, 12)
	opt_p.border_width_bottom = 4
	theme.set_stylebox("normal", "OptionRow", opt_n)
	theme.set_stylebox("hover", "OptionRow", opt_h)
	theme.set_stylebox("pressed", "OptionRow", opt_p)
	theme.set_stylebox("hover_pressed", "OptionRow", opt_p)
	theme.set_stylebox("disabled", "OptionRow", opt_n)
	theme.set_color("font_disabled_color", "OptionRow", Pal.INK)

	# Word tile for the sentence builder.
	_variation(theme, "Tile", "Button")
	var t_n := _sb(Pal.SURFACE, Ds.R_S, Pal.LINE, 2, 14, 8)
	t_n.border_width_bottom = 4
	var t_h := _sb(_tint(Pal.SURFACE, 0.03), Ds.R_S, Pal.LINE_STRONG, 2, 14, 8)
	t_h.border_width_bottom = 4
	theme.set_stylebox("normal", "Tile", t_n)
	theme.set_stylebox("hover", "Tile", t_h)
	theme.set_stylebox("pressed", "Tile", t_h)
	theme.set_stylebox("hover_pressed", "Tile", t_h)
	theme.set_stylebox("disabled", "Tile", t_n)
	theme.set_color("font_disabled_color", "Tile", Pal.INK)
	theme.set_font_size("font_size", "Tile", Ds.type_size_for("Tile", false))

	# Filter chip (toggle): outlined pill; the pressed (= selected) state is PRIMARY_SOFT with a PRIMARY outline
	# and PRIMARY text, so the selection is not colour alone (the outline gets thicker too).
	_variation(theme, "FilterChip", "Button")
	var c_n := _sb(Pal.SURFACE, Ds.R_PILL, Pal.LINE_STRONG, 1, 14, 6)
	var c_h := _sb(Pal.SUNK, Ds.R_PILL, Pal.LINE_STRONG, 1, 14, 6)
	var c_p := _sb(Pal.PRIMARY_SOFT, Ds.R_PILL, Pal.PRIMARY, 2, 14, 6)
	theme.set_stylebox("normal", "FilterChip", c_n)
	theme.set_stylebox("hover", "FilterChip", c_h)
	theme.set_stylebox("pressed", "FilterChip", c_p)
	theme.set_stylebox("hover_pressed", "FilterChip", c_p)
	theme.set_stylebox("disabled", "FilterChip", _sb(Pal.BG, Ds.R_PILL, Pal.LINE, 1, 14, 6))
	theme.set_color("font_color", "FilterChip", Pal.INK)
	theme.set_color("font_hover_color", "FilterChip", Pal.INK)
	theme.set_color("font_pressed_color", "FilterChip", Pal.PRIMARY)
	theme.set_color("font_hover_pressed_color", "FilterChip", Pal.PRIMARY)
	theme.set_font_size("font_size", "FilterChip", Ds.type_size_for("Small", false))


func _panels(theme: Theme) -> void:
	theme.set_stylebox("panel", "PanelContainer", _empty())
	theme.set_stylebox("panel", "Card", _sb(Pal.SURFACE, Ds.R_CARD, Pal.LINE, 1, 20, 16))
	_variation(theme, "Card", "PanelContainer")
	theme.set_stylebox("panel", "BigCard", _sb(Pal.SURFACE, Ds.R_CARD, Pal.LINE, 1, 24, 22))
	_variation(theme, "BigCard", "PanelContainer")
	theme.set_stylebox("panel", "Sunk", _sb(Pal.SUNK, Ds.R_S, CLEAR, 0, 14, 12))
	_variation(theme, "Sunk", "PanelContainer")
	theme.set_stylebox("panel", "Seg", _sb(Pal.SUNK, Ds.R_BTN, CLEAR, 0, 3, 3))
	_variation(theme, "Seg", "PanelContainer")
	# Toast: a light scheme floats on a soft shadow; the dark one has none (the lighter surface separates it)
	var toast := _sb(Pal.TOAST_BG, Ds.R_BTN, CLEAR, 0, 18, 12)
	if not Pal.is_dark():
		toast.shadow_size = 8
		toast.shadow_offset = Vector2(0, 2)
		toast.shadow_color = Color(0, 0, 0, 0.14)
	theme.set_stylebox("panel", "Toast", toast)
	_variation(theme, "Toast", "PanelContainer")
	theme.set_stylebox("panel", "TopBar", _sb(Pal.BG, 0, Pal.LINE, 0, 0, 0))
	_variation(theme, "TopBar", "PanelContainer")
	# List group: one card holding several rows (rows bring their own horizontal padding and dividers)
	theme.set_stylebox("panel", "Group", _sb(Pal.SURFACE, Ds.R_CARD, CLEAR, 0, 0, 4))
	_variation(theme, "Group", "PanelContainer")
	var hs := StyleBoxLine.new()
	hs.color = Pal.LINE
	hs.thickness = 1
	theme.set_stylebox("separator", "HSeparator", hs)
	theme.set_constant("separation", "HSeparator", 8)


func _inputs(theme: Theme) -> void:
	var n := _sb(Pal.SURFACE, Ds.R_INPUT, Pal.LINE_STRONG, 1, 12, 9)
	var f := _sb(Pal.SURFACE, Ds.R_INPUT, Pal.PRIMARY, 2, 11, 8)
	var ro := _sb(Pal.SUNK, Ds.R_INPUT, Pal.LINE, 1, 12, 9)
	for t in ["LineEdit", "TextEdit"]:
		theme.set_stylebox("normal", t, n.duplicate() as StyleBox)
		theme.set_stylebox("focus", t, f.duplicate() as StyleBox)
		theme.set_stylebox("read_only", t, ro.duplicate() as StyleBox)
		theme.set_color("font_color", t, Pal.INK)
		theme.set_color("font_placeholder_color", t, Pal.MUTED)
		theme.set_color("caret_color", t, Pal.INK)
		theme.set_color("selection_color", t, Color(Pal.PRIMARY, 0.30))
	theme.set_color("font_uneditable_color", "LineEdit", Pal.MUTED)
	theme.set_constant("caret_width", "LineEdit", 2)
	theme.set_constant("arrow_margin", "OptionButton", 8)
	theme.set_constant("h_separation", "OptionButton", 8)


func _check_and_slider(theme: Theme) -> void:
	for t in ["CheckBox", "CheckButton"]:
		for s in ["normal", "hover", "pressed", "hover_pressed", "disabled", "focus"]:
			theme.set_stylebox(s, t, _empty(2, 4))
		for c in ["font_color", "font_hover_color", "font_pressed_color", "font_hover_pressed_color", "font_focus_color"]:
			theme.set_color(c, t, Pal.INK)
		theme.set_color("font_disabled_color", t, Color(Pal.MUTED, 0.55))
		theme.set_constant("h_separation", t, 12)

	var groove := _sb(Pal.SUNK, 4, CLEAR, 0, 0, 3)
	var area := _sb(Pal.PRIMARY, 4, CLEAR, 0, 0, 3)
	theme.set_stylebox("slider", "HSlider", groove)
	theme.set_stylebox("grabber_area", "HSlider", area)
	theme.set_stylebox("grabber_area_highlight", "HSlider", area)


func _popup(theme: Theme) -> void:
	theme.set_stylebox("panel", "PopupMenu", _sb(Pal.SURFACE_HI, Ds.R_INPUT, Pal.LINE, 1, 6, 6))
	theme.set_stylebox("hover", "PopupMenu", _sb(Pal.PRIMARY_SOFT, Ds.R_XS, CLEAR, 0, 8, 4))
	theme.set_stylebox("separator", "PopupMenu", _empty())
	theme.set_color("font_color", "PopupMenu", Pal.INK)
	theme.set_color("font_hover_color", "PopupMenu", Pal.INK)
	theme.set_color("font_disabled_color", "PopupMenu", Pal.MUTED)
	theme.set_color("font_separator_color", "PopupMenu", Pal.MUTED)
	theme.set_constant("v_separation", "PopupMenu", 8)
	theme.set_constant("item_start_padding", "PopupMenu", 8)
	theme.set_constant("item_end_padding", "PopupMenu", 8)


func _scroll_and_progress(theme: Theme) -> void:
	for t in ["VScrollBar", "HScrollBar"]:
		var track := _sb(CLEAR, 5, CLEAR, 0, 4, 4)
		theme.set_stylebox("scroll", t, track)
		theme.set_stylebox("scroll_focus", t, track)
		var gr := _sb(Color(Pal.LINE_STRONG, 0.55), 5, CLEAR, 0, 0, 0)
		var gh := _sb(Color(Pal.LINE_STRONG, 0.85), 5, CLEAR, 0, 0, 0)
		theme.set_stylebox("grabber", t, gr)
		theme.set_stylebox("grabber_highlight", t, gh)
		theme.set_stylebox("grabber_pressed", t, gh)
	theme.set_stylebox("background", "ProgressBar", _sb(Pal.SUNK, Ds.R_PILL, CLEAR, 0, 0, 0))
	theme.set_stylebox("fill", "ProgressBar", _sb(Pal.PRIMARY, Ds.R_PILL, CLEAR, 0, 0, 0))
	theme.set_color("font_color", "ProgressBar", Pal.INK)
