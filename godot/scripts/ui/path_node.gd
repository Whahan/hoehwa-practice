class_name PathNode
extends Button
## One round node of the lesson path (docs/home_menu_design.md §7.3): a circle whose shape tells the state without colour.
##   done     PRIMARY fill, check mark            current  bigger, PRIMARY fill + REWARD ring, play mark
##   open     SURFACE + PRIMARY ring, week number past     SUNK + grey ring, week number (muted)
##   locked   SUNK + grey ring, lock mark
## A Button (BaseButton) so the phone touch hook passes a drag that starts on it on to the page (T5-11).

const STATES := ["done", "current", "open", "past", "locked"]
const STATE_WORD := {"done": "완료", "current": "지금", "open": "열림", "past": "건너뜀", "locked": "잠김"}

static var _style_cache: Dictionary = {}

var state: String = "locked"
var month_n: int = 1
var week_w: int = 1
var diameter: float = Ds.NODE_D


func _init(n: int = 1, w: int = 1, state_: String = "locked") -> void:
	month_n = n
	week_w = w
	state = state_ if STATES.has(state_) else "locked"
	focus_mode = Control.FOCUS_NONE
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	clip_text = false
	_apply()


## Same cell, new state (e.g. after a weekly check was switched).
func set_state(s: String) -> void:
	state = s if STATES.has(s) else "locked"
	_apply()


func state_word() -> String:
	return str(STATE_WORD.get(state, "잠김"))


func _apply() -> void:
	for c in get_children():
		remove_child(c)
		c.queue_free()
	diameter = Ds.NODE_D_CUR if state == "current" else Ds.NODE_D
	custom_minimum_size = Vector2(diameter, diameter)
	size = Vector2(diameter, diameter)
	accessibility_name = "%d개월차 %d주, %s" % [month_n, week_w, state_word()]
	tooltip_text = ""
	var fill: Color = Pal.SUNK
	var ring: Color = Pal.LINE_STRONG
	var ring_w: int = 2
	var fg: Color = Pal.MUTED
	var mark: String = "" # glyph kind; "" = the week number as text
	match state:
		"done":
			fill = Pal.PRIMARY
			ring_w = 0
			fg = Pal.ON_ACCENT
			mark = "check"
		"current":
			fill = Pal.PRIMARY
			ring = Pal.REWARD
			ring_w = 4
			fg = Pal.ON_ACCENT
			mark = "play"
		"open":
			fill = Pal.SURFACE
			ring = Pal.PRIMARY
			ring_w = 3
			fg = Pal.PRIMARY
		"past":
			pass
		_:
			mark = "lock"
	# the 48 nodes of the path share the same few style boxes (one pair per state and colour scheme; never edited afterwards)
	var ckey: String = "%s|%s|%s|%s" % [state, Pal.PRIMARY.to_html(), Pal.SUNK.to_html(), Pal.SURFACE.to_html()]
	if not _style_cache.has(ckey):
		var radius: int = int(ceilf(diameter * 0.5))
		_style_cache[ckey] = [
			UI.style(fill, ring, ring_w, radius, 0, 0),
			UI.style(fill.lightened(0.12) if Pal.is_dark() else fill.darkened(0.12), ring, ring_w, radius, 0, 0)]
	var sb: StyleBoxFlat = (_style_cache[ckey] as Array)[0]
	var pressed_sb: StyleBoxFlat = (_style_cache[ckey] as Array)[1]
	for n in ["normal", "focus", "disabled"]:
		add_theme_stylebox_override(n, sb)
	for n in ["hover", "pressed", "hover_pressed"]:
		add_theme_stylebox_override(n, pressed_sb)
	for n in ["font_color", "font_hover_color", "font_pressed_color", "font_hover_pressed_color", "font_focus_color", "font_disabled_color"]:
		add_theme_color_override(n, fg)
	add_theme_font_size_override("font_size", Ds.fs(18))
	add_theme_font_override("font", UI.bold_font())
	if mark == "":
		text = str(week_w)
	else:
		text = ""
		var px: float = diameter * (0.46 if mark != "play" else 0.5)
		var g := GlyphIcon.new(mark, px, fg)
		g.anchor_left = 0.5
		g.anchor_right = 0.5
		g.anchor_top = 0.5
		g.anchor_bottom = 0.5
		g.offset_left = -px * 0.5
		g.offset_right = px * 0.5
		g.offset_top = -px * 0.5
		g.offset_bottom = px * 0.5
		add_child(g)
