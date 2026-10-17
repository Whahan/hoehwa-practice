class_name Ipa
extends RefCounted
## Font that can draw IPA symbols (θ ð ɹ ʃ ɪ ɯ ɕ ...) next to Hangul/kana.

static var _regular: SystemFont = null
static var _bold: SystemFont = null


static func font(bold: bool = false) -> SystemFont:
	if bold and _bold != null:
		return _bold
	if not bold and _regular != null:
		return _regular
	var f := SystemFont.new()
	f.font_names = PackedStringArray(["Segoe UI", "Arial", "Lucida Sans Unicode", "Arial Unicode MS", "Roboto", "Noto Sans"])
	f.font_weight = 700 if bold else 400
	var fb1 := SystemFont.new()
	fb1.font_names = PackedStringArray(["Segoe UI Symbol", "Cambria Math", "Charis SIL", "DejaVu Sans", "Noto Sans Symbols", "Noto Sans Symbols 2", "Noto Sans"])
	var fb2 := SystemFont.new()
	fb2.font_names = PackedStringArray(["Malgun Gothic", "Yu Gothic UI", "Noto Sans CJK KR", "Noto Sans CJK JP"])
	var arr: Array[Font] = [fb1, fb2]
	f.fallbacks = arr
	if bold:
		_bold = f
	else:
		_regular = f
	return f
