class_name ThemeIcons
extends RefCounted
## Switch, check box, slider grabber and drop-down arrow, drawn from small SVG strings in the CURRENT Pal colours
## (docs/ui_redesign_design.md §5.6). No icon files: dark mode is a second call after Pal.use("dark").
##
## Textures are DPITexture (Godot 4.6) when the engine has the class: it keeps the SVG's nominal size in logical
## px and is re-rasterised for the screen scale, so a 52x32 switch stays sharp on a 2.6x phone. Older engines get
## an ImageTexture of the same pixel size (Image.load_svg_from_string, scale 1.0).

const SWITCH_W := 52
const SWITCH_H := 32
const BOX := 24
const GRABBER := 24
const ARROW := 16

## Theme type -> icon names set by apply(); tests walk this list.
const ICONS := {
	"CheckButton": ["checked", "unchecked", "checked_disabled", "unchecked_disabled"],
	"CheckBox": ["checked", "unchecked", "checked_disabled", "unchecked_disabled"],
	"HSlider": ["grabber", "grabber_highlight", "grabber_disabled"],
	"OptionButton": ["arrow"],
}


static func apply(theme: Theme) -> void:
	if theme == null:
		return
	var sw_on := _switch(true, 1.0)
	var sw_off := _switch(false, 1.0)
	var sw_on_d := _switch(true, 0.4)
	var sw_off_d := _switch(false, 0.4)
	theme.set_icon("checked", "CheckButton", _tex(sw_on, SWITCH_W, SWITCH_H))
	theme.set_icon("unchecked", "CheckButton", _tex(sw_off, SWITCH_W, SWITCH_H))
	theme.set_icon("checked_disabled", "CheckButton", _tex(sw_on_d, SWITCH_W, SWITCH_H))
	theme.set_icon("unchecked_disabled", "CheckButton", _tex(sw_off_d, SWITCH_W, SWITCH_H))
	theme.set_icon("checked", "CheckBox", _tex(_box(true, 1.0), BOX, BOX))
	theme.set_icon("unchecked", "CheckBox", _tex(_box(false, 1.0), BOX, BOX))
	theme.set_icon("checked_disabled", "CheckBox", _tex(_box(true, 0.4), BOX, BOX))
	theme.set_icon("unchecked_disabled", "CheckBox", _tex(_box(false, 0.4), BOX, BOX))
	theme.set_icon("grabber", "HSlider", _tex(_grabber(1.0), GRABBER, GRABBER))
	theme.set_icon("grabber_highlight", "HSlider", _tex(_grabber(1.0), GRABBER, GRABBER))
	theme.set_icon("grabber_disabled", "HSlider", _tex(_grabber(0.4), GRABBER, GRABBER))
	theme.set_icon("arrow", "OptionButton", _tex(_arrow(), ARROW, ARROW))


static func _hex(c: Color) -> String:
	return "#" + c.to_html(false)


static func _svg(w: int, h: int, body: String) -> String:
	return '<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" viewBox="0 0 %d %d">%s</svg>' % [w, h, w, h, body]


## Track 52x32. On: PRIMARY track, ON_ACCENT thumb at the right. Off: outlined LINE_STRONG track (3:1 against the
## surface), LINE_STRONG thumb at the left. `a` = opacity (disabled).
static func _switch(on: bool, a: float) -> String:
	var body: String
	if on:
		body = '<g opacity="%s"><rect x="1" y="2" width="50" height="28" rx="14" fill="%s"/><circle cx="37" cy="16" r="10" fill="%s"/></g>' % [str(a), _hex(Pal.PRIMARY), _hex(Pal.ON_ACCENT)]
	else:
		body = '<g opacity="%s"><rect x="2" y="3" width="48" height="26" rx="13" fill="%s" stroke="%s" stroke-width="2"/><circle cx="15" cy="16" r="7" fill="%s"/></g>' % [str(a), _hex(Pal.SUNK), _hex(Pal.LINE_STRONG), _hex(Pal.LINE_STRONG)]
	return _svg(SWITCH_W, SWITCH_H, body)


## Check box 24x24. On: PRIMARY fill + ON_ACCENT tick. Off: SURFACE fill, LINE_STRONG 2 px outline.
static func _box(on: bool, a: float) -> String:
	var body: String
	if on:
		body = '<g opacity="%s"><rect x="2" y="2" width="20" height="20" rx="6" fill="%s"/><path d="M7 12.4l3.6 3.6 6.4-7.2" fill="none" stroke="%s" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"/></g>' % [str(a), _hex(Pal.PRIMARY), _hex(Pal.ON_ACCENT)]
	else:
		body = '<g opacity="%s"><rect x="2" y="2" width="20" height="20" rx="6" fill="%s" stroke="%s" stroke-width="2"/></g>' % [str(a), _hex(Pal.SURFACE), _hex(Pal.LINE_STRONG)]
	return _svg(BOX, BOX, body)


static func _grabber(a: float) -> String:
	return _svg(GRABBER, GRABBER, '<g opacity="%s"><circle cx="12" cy="12" r="10" fill="%s" stroke="%s" stroke-width="2"/></g>' % [str(a), _hex(Pal.PRIMARY), _hex(Pal.SURFACE)])


static func _arrow() -> String:
	return _svg(ARROW, ARROW, '<path d="M3.5 6l4.5 4.5L12.5 6" fill="none" stroke="%s" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>' % _hex(Pal.MUTED))


static func _tex(svg: String, w: int, h: int) -> Texture2D:
	if ClassDB.class_exists("DPITexture"):
		var d: Texture2D = DPITexture.create_from_string(svg, 1.0)
		if d != null and d.get_width() >= w and d.get_height() >= h:
			return d
	var img := Image.new()
	if img.load_svg_from_string(svg, 1.0) != OK or img.is_empty():
		img = Image.create(w, h, false, Image.FORMAT_RGBA8)
		img.fill(Color(Pal.LINE_STRONG, 0.5))
	return ImageTexture.create_from_image(img)
