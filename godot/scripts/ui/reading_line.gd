class_name ReadingLine
extends RefCounted
## The reading shown under a Japanese sentence: the hiragana line and, below it, the Hangul sound spelling
## (KanaHangul). One helper for every screen, so size and colour are decided here once.
##   ReadingLine.add(parent, reading, lang, Store.pref_bool("show_reading"), 0.0, pron)   # adds nothing when there is nothing to show
##   var rl := ReadingLine.make(reading, lang, show_kana, max_w, pron)                    # null when there is nothing to show
## Hiragana line: pref `show_reading` (the caller passes it as `show_kana`). Hangul line: pref `show_hangul_ja` (default on).
## The Hangul line is made from `pron` (the backend's katakana pronunciation form: exact) when given, else from the
## hiragana `reading` with KanaHangul's heuristic. Size = the theme's "Muted" step (one below the 16/17 body text),
## colour = Pal.INK (>= 4.5:1 on every surface); the old "Small" step in the muted grey was too faint. No dependency on UI.

const VARIATION := "Muted"
const HANGUL_PREF := "show_hangul_ja"


## VBox with the lines to show, or null (nothing is created, so no orphan node) when `lang` is not "ja", the reading is empty,
## or both lines are off. `max_w` > 0: each label gets a minimum width of its text width capped at max_w (needed inside a
## bubble that shrinks to its content, where an auto-wrapping label would otherwise collapse to nothing).
static func make(reading: String, lang: String, show_kana: bool = true, max_w: float = 0.0, pron: String = "") -> Control:
	var text: String = reading.strip_edges()
	if lang != "ja" or (text == "" and pron.strip_edges() == ""):
		return null
	var lines: Array[String] = []
	if show_kana and text != "":
		lines.append(text)
	if Store.pref_bool(HANGUL_PREF):
		var hangul: String = hangul_of(text, pron)
		if hangul != "" and hangul != text: # nothing to show when the text has no kana (e.g. romaji)
			lines.append(hangul)
	if lines.is_empty():
		return null
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 2)
	for l in lines:
		box.add_child(_line(l, max_w))
	return box


## make() + add_child when there is something to show. Returns the added box or null.
static func add(parent: Node, reading: String, lang: String, show_kana: bool = true, max_w: float = 0.0, pron: String = "") -> Control:
	var rl := make(reading, lang, show_kana, max_w, pron)
	if rl != null:
		parent.add_child(rl)
	return rl


## The Hangul sound spelling of one reading: from `pron` when it has kana, else from `reading`.
static func hangul_of(reading: String, pron: String = "") -> String:
	var p: String = pron.strip_edges()
	if p != "":
		return KanaHangul.from_pron(p)
	return KanaHangul.to_hangul(reading.strip_edges())


static func _line(text: String, max_w: float) -> Label:
	var l := Label.new()
	l.text = text
	l.theme_type_variation = VARIATION
	l.add_theme_color_override("font_color", Pal.INK)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if max_w > 0.0:
		var th: Theme = ThemeDB.get_project_theme()
		var f: Font = th.default_font if th != null and th.default_font != null else ThemeDB.fallback_font
		var size: int = Ds.fs(Ds.type_size(VARIATION))
		l.custom_minimum_size = Vector2(minf(f.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x + 6.0, max_w), 0)
	return l
