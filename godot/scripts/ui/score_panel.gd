class_name ScorePanel
extends RefCounted
## Builds the pronunciation result block shown after POST /score.
## Every word/mora chip is clickable when the server sent phonemes (`ph`): the phoneme row below shows the
## IPA symbols of that unit (green = fine, red = missed, with what was heard instead).

## Border widths of the word chips (px): a word said well has none, a missed word 2 (shape, not colour alone), the
## chosen chip 3.
const BAD_BW := 2
const WARN_BW := 1
const SELECTED_BW := 3

const IPA_LONG := "ː"
const IPA_STOP := "ʔ"


static func score_color(score: float) -> Color:
	if score >= 80.0:
		return Pal.OK
	if score >= 60.0:
		return Pal.WARN
	return Pal.BAD


## Colour of small text that states the score (verdict sentence): the *_ON twin of score_color, which reads on a surface.
static func score_text_color(score: float) -> Color:
	if score >= 80.0:
		return Pal.OK_ON
	if score >= 60.0:
		return Pal.WARN_ON
	return Pal.BAD_ON


static func verdict(score: float) -> String:
	if score >= 90.0:
		return "원어민이 바로 알아들어요"
	if score >= 70.0:
		return "대체로 알아들어요"
	return "잘 전달되지 않았어요"


static func _num(v: Variant) -> int:
	if v is float or v is int:
		return roundi(float(v))
	return 0


## units[i].ph as a clean Array of Dictionaries ([] when absent).
static func phonemes_of(unit: Dictionary) -> Array:
	var raw: Variant = unit.get("ph", null)
	var out: Array = []
	if raw is Array:
		for p in raw:
			if p is Dictionary and (p as Dictionary).has("p"):
				out.append(p)
	return out


static func has_bad_phoneme(unit: Dictionary) -> bool:
	for p in phonemes_of(unit):
		if not bool((p as Dictionary).get("ok", true)):
			return true
	return false


## How a word chip looks: {fg, bg, border, bw, bold}. ok = the word was heard, bad_ph = one of its sounds was off.
## Said well: OK_SOFT + OK_ON text, no outline. Heard but one sound off: WARN_SOFT + WARN_ON + 1 px WARN outline.
## Missed: BAD_SOFT + BAD_ON bold text + 2 px BAD outline.
static func unit_look(ok: bool, bad_ph: bool) -> Dictionary:
	if not ok:
		return {"fg": Pal.BAD_ON, "bg": Pal.BAD_SOFT, "border": Pal.BAD, "bw": BAD_BW, "bold": true}
	if bad_ph:
		return {"fg": Pal.WARN_ON, "bg": Pal.WARN_SOFT, "border": Pal.WARN, "bw": WARN_BW, "bold": true}
	return {"fg": Pal.OK_ON, "bg": Pal.OK_SOFT, "border": Color(0, 0, 0, 0), "bw": 0, "bold": false}


static func build(res: Dictionary, lang: String) -> VBoxContainer:
	var box := UI.vbox(12)
	var score: int = _num(res.get("score", 0))
	var col := score_color(score) # the big number is a fill-like colour (3:1 is enough at 40 px)

	var top := UI.hbox(16)
	var big := Label.new()
	big.theme_type_variation = &"Score"
	big.text = str(score)
	big.add_theme_color_override("font_color", col)
	top.add_child(big)
	var side := UI.vbox(2)
	side.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	side.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	side.add_child(UI.label("발음 점수", "Small", false))
	side.add_child(UI.colored(verdict(score), score_text_color(score), "Strong"))
	top.add_child(side)
	box.add_child(top)

	var stats := UI.hbox(8)
	for spec in [["정확도", "accuracy"], ["또렷함", "clarity"], ["유창성", "fluency"]]:
		var v: int = _num(res.get(spec[1], 0))
		# a plain SUNK tile with an INK number and a MUTED caption: the colour carries no meaning here
		var p := UI.tinted_panel(Pal.SUNK, Color(0, 0, 0, 0), 0, 10, 12, 8)
		p.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var c := UI.vbox(0)
		var n := Label.new()
		n.text = str(v)
		n.add_theme_font_size_override("font_size", UI.fs(22))
		n.add_theme_font_override("font", UI.bold_font())
		n.add_theme_color_override("font_color", Pal.INK)
		c.add_child(n)
		c.add_child(UI.colored(spec[0], Pal.MUTED, "Small", false))
		p.add_child(c)
		stats.add_child(p)
	box.add_child(stats)

	var transcript: String = str(res.get("transcript", ""))
	if transcript != "":
		box.add_child(UI.label("들린 문장:  " + transcript, "Muted"))

	var units: Variant = res.get("units", [])
	if units is Array and not (units as Array).is_empty():
		_add_units(box, units as Array, lang)

	var tips: Variant = res.get("tips_ko", [])
	if tips is Array and not (tips as Array).is_empty():
		var tb := UI.card("Sunk", 6)
		tb.body.add_child(UI.label("연습 팁", "Eyebrow", false))
		for t in tips:
			tb.body.add_child(UI.label("• " + str(t)))
		box.add_child(tb)
	UI.fix_cjk(box)
	return box


static func _add_units(box: VBoxContainer, units: Array, lang: String) -> void:
	var fl := UI.flow(5, 6)
	var chips: Array = [] # [{panel, fg, bg}] per unit index, null for skipped entries
	var detail := UI.vbox(0)
	var state := {"open": -1}
	var any_ph := false
	var first_bad := -1
	for i in units.size():
		var u: Variant = units[i]
		if not (u is Dictionary):
			chips.append(null)
			continue
		var ud: Dictionary = u
		var ok: bool = bool(ud.get("ok", false))
		var t: String = str(ud.get("t", ""))
		var heard: Variant = ud.get("heard", null)
		var ph: Array = phonemes_of(ud)
		var ph_bad: bool = has_bad_phoneme(ud)
		var tip := ""
		if not ok:
			tip = ("'%s'(으)로 들렸어요" % str(heard)) if heard != null and str(heard) != "" else "잘 들리지 않았어요"
		var look: Dictionary = unit_look(ok, ph_bad)
		var fg: Color = look["fg"]
		var bg: Color = look["bg"]
		if ok and ph_bad:
			tip = "단어는 알아들었지만 소리 하나가 어색해요"
		if not ph.is_empty():
			any_ph = true
			tip = (tip + " · " if tip != "" else "") + "눌러서 발음기호 보기"
			if first_bad < 0 and ph_bad:
				first_bad = i
		var ch := UI.chip(t, fg, bg, "" if Platform.is_phone() else tip)
		var lab := ch.get_child(0) as Label
		lab.add_theme_font_size_override("font_size", UI.fs(17))
		if not bool(look["bold"]):
			lab.remove_theme_font_override("font") # a word said well is plain, a missed one is bold (shape cue)
		ch.add_theme_stylebox_override("panel", UI.style(bg, look["border"], int(look["bw"]), Ds.R_PILL, 10, 2))
		if Platform.is_phone(): # touch target
			PhoneLayout.touch(ch, PhoneLayout.LINK_H)
			lab.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		if not ph.is_empty():
			ch.mouse_filter = Control.MOUSE_FILTER_STOP
			ch.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		chips.append({"panel": ch, "bg": bg, "border": look["border"], "bw": int(look["bw"])})
		fl.add_child(ch)
	box.add_child(fl)

	if not any_ph:
		if Platform.is_phone():
			box.add_child(UI.label("초록은 잘 말한 부분, 빨강은 놓친 부분이에요.", "Small"))
		else:
			box.add_child(UI.label("초록은 잘 말한 부분, 빨강은 놓친 부분이에요. 빨간 칸에 마우스를 올리면 어떻게 들렸는지 보여요.", "Small"))
		return

	var select := func(i: int) -> void:
		var now: int = int(state["open"])
		if now == i:
			i = -1
		state["open"] = i
		for k in chips.size():
			var c: Variant = chips[k]
			if c == null:
				continue
			var sel: bool = k == i
			# the chosen chip gets a thick INK outline, over its own resting outline (missed words keep their 2 px BAD one)
			var bcol: Color = Pal.INK if sel else c["border"]
			var bw: int = SELECTED_BW if sel else int(c["bw"])
			(c["panel"] as PanelContainer).add_theme_stylebox_override("panel", UI.style(c["bg"], bcol, bw, Ds.R_PILL, 10, 2))
		UI.clear(detail)
		if i >= 0:
			detail.add_child(_phoneme_detail(units[i] as Dictionary, lang))
			UI.fix_cjk(detail)

	for i in chips.size():
		var c: Variant = chips[i]
		if c == null or phonemes_of(units[i] as Dictionary).is_empty():
			continue
		var idx: int = i
		UI.on_tap(c["panel"] as PanelContainer, func() -> void: select.call(idx))
	box.add_child(detail)
	box.add_child(UI.label("초록은 잘 말한 부분, 노랑은 소리 하나가 어색한 부분, 빨강은 놓친 부분이에요. 글자를 누르면 발음기호별로 어떻게 들렸는지 볼 수 있어요.", "Small"))
	if first_bad >= 0:
		select.call(first_bad)


## Phoneme row of one unit: IPA chips, green = ok, red = missed (what was heard below it).
static func _phoneme_detail(unit: Dictionary, lang: String) -> Control:
	var card := UI.card("Sunk", 8)
	var head := UI.hbox(8)
	var name_l := UI.label("'%s' 발음기호" % str(unit.get("t", "")), "Strong", false)
	head.add_child(name_l)
	card.body.add_child(head)
	var row := UI.flow(6, 6)
	for p in phonemes_of(unit):
		row.add_child(_ph_chip(p as Dictionary))
	card.body.add_child(row)
	var misses: Array[String] = []
	for p in phonemes_of(unit):
		var pd: Dictionary = p
		if not bool(pd.get("ok", true)):
			var heard: Variant = pd.get("heard", null)
			if heard != null and str(heard) != "":
				misses.append("%s → %s" % [str(pd["p"]), str(heard)])
			else:
				misses.append("%s 안 들림" % str(pd["p"]))
	if misses.is_empty():
		card.body.add_child(UI.colored("모든 소리가 잘 들렸어요.", Pal.OK_ON, "Small"))
	else:
		card.body.add_child(UI.colored("어색했던 소리:  " + ",  ".join(misses), Pal.BAD_ON, "Small"))
	return card


static func _ph_chip(p: Dictionary) -> Control:
	var ok: bool = bool(p.get("ok", true))
	var conf: float = float(p.get("conf", 1.0)) if (p.get("conf", null) is float or p.get("conf", null) is int) else 1.0
	var sym: String = str(p.get("p", ""))
	var heard: Variant = p.get("heard", null)
	var fg: Color = Pal.OK_ON if ok else Pal.BAD_ON
	var bg: Color = Pal.OK_SOFT if ok else Pal.BAD_SOFT
	# a missed sound has a 2 px BAD outline, a good one a faint 1 px outline
	var panel := UI.tinted_panel(bg, Pal.BAD if not ok else Color(Pal.OK, 0.35), 2 if not ok else 1, 10, 10, 5)
	panel.custom_minimum_size = Vector2(44, 0)
	panel.tooltip_text = "%s · 확신도 %d%%" % ["잘 들렸어요" if ok else "어색했어요", roundi(conf * 100.0)]
	var v := UI.vbox(0)
	var l := Label.new()
	l.text = sym
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.add_theme_font_override("font", Ipa.font(true))
	l.add_theme_font_size_override("font_size", UI.fs(20))
	l.add_theme_color_override("font_color", fg)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.add_child(l)
	var sub := ""
	if sym == IPA_LONG:
		sub = "길게"
	elif sym == IPA_STOP:
		sub = "멈춤"
	if not ok:
		if heard != null and str(heard) != "":
			sub = "→ " + str(heard)
		elif sub == "":
			sub = "안 들림"
	if sub != "":
		var s := Label.new()
		s.text = sub
		s.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		s.add_theme_font_override("font", Ipa.font(false))
		s.add_theme_font_size_override("font_size", UI.fs(12))
		s.add_theme_color_override("font_color", fg if not ok else Pal.MUTED)
		s.mouse_filter = Control.MOUSE_FILTER_IGNORE
		v.add_child(s)
	panel.add_child(v)
	return panel
