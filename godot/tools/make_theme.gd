extends SceneTree
## Generates res://theme/app_theme.tres (run once after changing the palette):
##   godot --headless --path <project> --script res://tools/make_theme.gd
## Needs the SVG icons in res://theme/ to be imported already (run --import first).

const NAMES := ["Malgun Gothic", "Yu Gothic UI", "Meiryo", "Segoe UI"]
const OUT_PATH := "res://theme/app_theme.tres"


func _init() -> void:
	var theme := Theme.new()
	var font := _font(false)
	var bold := _font(true)
	theme.default_font = font
	theme.default_font_size = 16

	_labels(theme, bold)
	_buttons(theme, bold)
	_panels(theme)
	_inputs(theme)
	_check_and_slider(theme)
	_popup(theme)
	_scroll_and_progress(theme)

	var err := ResourceSaver.save(theme, OUT_PATH)
	print("theme saved: ", OUT_PATH, " err=", err)
	quit(0 if err == OK else 1)


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


func _sb(bg: Color, radius: int = 8, border: Color = Color(0, 0, 0, 0), bw: int = 0, ph: int = 14, pv: int = 8) -> StyleBoxFlat:
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


func _labels(theme: Theme, bold: Font) -> void:
	theme.set_color("font_color", "Label", Pal.INK)
	theme.set_color("font_shadow_color", "Label", Color(0, 0, 0, 0))
	for spec in [
		["H1", 28, Pal.INK, true], ["H2", 21, Pal.INK, true], ["H3", 17, Pal.INK, true],
		["Muted", 15, Pal.MUTED, false], ["Small", 13, Pal.MUTED, false],
		["Eyebrow", 12, Pal.MUTED, true], ["Big", 34, Pal.INK, true], ["Strong", 16, Pal.INK, true],
		["Score", 40, Pal.INK, true],
	]:
		var vname: String = spec[0]
		_variation(theme, vname, "Label")
		theme.set_font_size("font_size", vname, spec[1])
		theme.set_color("font_color", vname, spec[2])
		if spec[3]:
			theme.set_font("font", vname, bold)
	theme.set_color("default_color", "RichTextLabel", Pal.INK)
	theme.set_font("bold_font", "RichTextLabel", bold)
	theme.set_color("font_selected_color", "RichTextLabel", Pal.INK)
	theme.set_color("selection_color", "RichTextLabel", Color("#C9D6F7"))


func _buttons(theme: Theme, bold: Font) -> void:
	var normal := _sb(Pal.SURFACE, 8, Pal.LINE, 1, 14, 8)
	var hover := _sb(Color("#F0F2F6"), 8, Color("#C9CFDA"), 1, 14, 8)
	var pressed := _sb(Color("#E2E5EB"), 8, Color("#B9C0CC"), 1, 14, 8)
	var disabled := _sb(Color("#F4F5F7"), 8, Pal.LINE, 1, 14, 8)
	var focus := _sb(Color(0, 0, 0, 0), 8, Color("#7C9BE8"), 2, 14, 8)
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
	theme.set_stylebox("hover", "FlatButton", _sb(Pal.SUNK, 8, Color(0, 0, 0, 0), 0, 10, 6))
	theme.set_stylebox("pressed", "FlatButton", _sb(Color("#E2E5EB"), 8, Color(0, 0, 0, 0), 0, 10, 6))
	theme.set_stylebox("hover_pressed", "FlatButton", _sb(Color("#E2E5EB"), 8, Color(0, 0, 0, 0), 0, 10, 6))
	theme.set_stylebox("disabled", "FlatButton", _empty(10, 6))
	theme.set_color("font_color", "FlatButton", Pal.MUTED)
	theme.set_color("font_hover_color", "FlatButton", Pal.INK)

	# Answer option (choice / fill / listen): wide, left aligned, thick bottom border.
	_variation(theme, "OptionRow", "Button")
	var opt_n := _sb(Pal.SURFACE, 12, Pal.LINE, 2, 16, 12)
	opt_n.border_width_bottom = 4
	var opt_h := _sb(Color("#F7F8FA"), 12, Color("#B9C0CC"), 2, 16, 12)
	opt_h.border_width_bottom = 4
	var opt_p := _sb(Color("#EEF2FC"), 12, Pal.EN, 2, 16, 12)
	opt_p.border_width_bottom = 4
	theme.set_stylebox("normal", "OptionRow", opt_n)
	theme.set_stylebox("hover", "OptionRow", opt_h)
	theme.set_stylebox("pressed", "OptionRow", opt_p)
	theme.set_stylebox("hover_pressed", "OptionRow", opt_p)
	theme.set_stylebox("disabled", "OptionRow", opt_n)
	theme.set_color("font_disabled_color", "OptionRow", Pal.INK)

	# Word tile for the sentence builder.
	_variation(theme, "Tile", "Button")
	var t_n := _sb(Pal.SURFACE, 10, Pal.LINE, 2, 14, 8)
	t_n.border_width_bottom = 4
	var t_h := _sb(Color("#F7F8FA"), 10, Color("#B9C0CC"), 2, 14, 8)
	t_h.border_width_bottom = 4
	theme.set_stylebox("normal", "Tile", t_n)
	theme.set_stylebox("hover", "Tile", t_h)
	theme.set_stylebox("pressed", "Tile", t_h)
	theme.set_stylebox("hover_pressed", "Tile", t_h)
	theme.set_stylebox("disabled", "Tile", t_n)
	theme.set_color("font_disabled_color", "Tile", Pal.INK)
	theme.set_font_size("font_size", "Tile", 18)


func _panels(theme: Theme) -> void:
	theme.set_stylebox("panel", "PanelContainer", _empty())
	var card := _sb(Pal.SURFACE, 12, Pal.LINE, 1, 18, 16)
	theme.set_stylebox("panel", "Card", card)
	_variation(theme, "Card", "PanelContainer")
	theme.set_stylebox("panel", "BigCard", _sb(Pal.SURFACE, 16, Pal.LINE, 1, 22, 20))
	_variation(theme, "BigCard", "PanelContainer")
	theme.set_stylebox("panel", "Sunk", _sb(Pal.SUNK, 10, Color(0, 0, 0, 0), 0, 14, 12))
	_variation(theme, "Sunk", "PanelContainer")
	theme.set_stylebox("panel", "Seg", _sb(Pal.SUNK, 10, Color(0, 0, 0, 0), 0, 3, 3))
	_variation(theme, "Seg", "PanelContainer")
	theme.set_stylebox("panel", "Toast", _sb(Color("#222A38"), 10, Color(0, 0, 0, 0), 0, 18, 12))
	_variation(theme, "Toast", "PanelContainer")
	theme.set_stylebox("panel", "TopBar", _sb(Pal.BG, 0, Pal.LINE, 0, 0, 0))
	_variation(theme, "TopBar", "PanelContainer")
	var hs := StyleBoxLine.new()
	hs.color = Pal.LINE
	hs.thickness = 1
	theme.set_stylebox("separator", "HSeparator", hs)
	theme.set_constant("separation", "HSeparator", 8)


func _inputs(theme: Theme) -> void:
	var n := _sb(Pal.SURFACE, 8, Pal.LINE, 1, 12, 9)
	var f := _sb(Pal.SURFACE, 8, Color("#7C9BE8"), 2, 11, 8)
	var ro := _sb(Pal.SUNK, 8, Pal.LINE, 1, 12, 9)
	theme.set_stylebox("normal", "LineEdit", n)
	theme.set_stylebox("focus", "LineEdit", f)
	theme.set_stylebox("read_only", "LineEdit", ro)
	theme.set_color("font_color", "LineEdit", Pal.INK)
	theme.set_color("font_placeholder_color", "LineEdit", Color(Pal.MUTED, 0.7))
	theme.set_color("font_uneditable_color", "LineEdit", Pal.MUTED)
	theme.set_color("caret_color", "LineEdit", Pal.INK)
	theme.set_color("selection_color", "LineEdit", Color("#C9D6F7"))
	theme.set_constant("caret_width", "LineEdit", 2)
	theme.set_stylebox("normal", "TextEdit", n)
	theme.set_stylebox("focus", "TextEdit", f)
	theme.set_stylebox("read_only", "TextEdit", ro)
	theme.set_color("font_color", "TextEdit", Pal.INK)
	theme.set_color("font_placeholder_color", "TextEdit", Color(Pal.MUTED, 0.7))
	theme.set_color("caret_color", "TextEdit", Pal.INK)
	theme.set_color("selection_color", "TextEdit", Color("#C9D6F7"))
	var arrow: Texture2D = load("res://theme/arrow_down.svg")
	if arrow != null:
		theme.set_icon("arrow", "OptionButton", arrow)
	theme.set_constant("arrow_margin", "OptionButton", 8)
	theme.set_constant("h_separation", "OptionButton", 8)


func _check_and_slider(theme: Theme) -> void:
	var on: Texture2D = load("res://theme/check_on.svg")
	var off: Texture2D = load("res://theme/check_off.svg")
	if on != null and off != null:
		for t in ["checked", "checked_disabled"]:
			theme.set_icon(t, "CheckBox", on)
		for t in ["unchecked", "unchecked_disabled"]:
			theme.set_icon(t, "CheckBox", off)
	for s in ["normal", "hover", "pressed", "hover_pressed", "disabled", "focus"]:
		theme.set_stylebox(s, "CheckBox", _empty(2, 4))
	for c in ["font_color", "font_hover_color", "font_pressed_color", "font_hover_pressed_color", "font_focus_color"]:
		theme.set_color(c, "CheckBox", Pal.INK)
	theme.set_constant("h_separation", "CheckBox", 10)

	var groove := _sb(Pal.SUNK, 4, Color(0, 0, 0, 0), 0, 0, 3)
	var area := _sb(Pal.EN, 4, Color(0, 0, 0, 0), 0, 0, 3)
	theme.set_stylebox("slider", "HSlider", groove)
	theme.set_stylebox("grabber_area", "HSlider", area)
	theme.set_stylebox("grabber_area_highlight", "HSlider", area)
	var g: Texture2D = load("res://theme/slider_grabber.svg")
	if g != null:
		theme.set_icon("grabber", "HSlider", g)
		theme.set_icon("grabber_highlight", "HSlider", g)
		theme.set_icon("grabber_disabled", "HSlider", g)


func _popup(theme: Theme) -> void:
	theme.set_stylebox("panel", "PopupMenu", _sb(Pal.SURFACE, 8, Pal.LINE, 1, 6, 6))
	theme.set_stylebox("hover", "PopupMenu", _sb(Color("#EEF2FC"), 6, Color(0, 0, 0, 0), 0, 8, 4))
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
		var track := _sb(Color(0, 0, 0, 0), 5, Color(0, 0, 0, 0), 0, 4, 4)
		theme.set_stylebox("scroll", t, track)
		theme.set_stylebox("scroll_focus", t, track)
		var gr := _sb(Color("#C5CAD3"), 5, Color(0, 0, 0, 0), 0, 0, 0)
		var gh := _sb(Color("#A5ACB9"), 5, Color(0, 0, 0, 0), 0, 0, 0)
		theme.set_stylebox("grabber", t, gr)
		theme.set_stylebox("grabber_highlight", t, gh)
		theme.set_stylebox("grabber_pressed", t, gh)
	theme.set_stylebox("background", "ProgressBar", _sb(Pal.SUNK, 99, Color(0, 0, 0, 0), 0, 0, 0))
	theme.set_stylebox("fill", "ProgressBar", _sb(Pal.INK, 99, Color(0, 0, 0, 0), 0, 0, 0))
	theme.set_color("font_color", "ProgressBar", Pal.INK)
