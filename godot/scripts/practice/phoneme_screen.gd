class_name PhonemeScreen
extends Control
## 약한 소리 집중 연습 (영어만). /score 응답의 음소(ph)에서 자주 틀린 소리를 찾아, 그 소리가 든 구절·예문을 5문항 연습한다.
## 소리 목록 GET /practice/phonemes, 한 소리 GET /practice/phoneme?p=θ&sentences=3. 계약: 설계 8.3.

signal closed

const ITEMS_N := 5
const SENTENCES_N := 3
const XP_DONE := 10
const MARK_TODAY_AT := 5
const WEAK_SHOWN := 5
const NEXT_LOCK_MSEC := 250
const NO_PH_TEXT := "음소 분석을 쓸 수 없어요. 점수만 보여 드리고, 성공 여부는 판정하지 않아요."

## 소리 목록을 아직 못 받았을 때 쓰는 이름 (허브 칩 등)
const FALLBACK_LABELS := {
	"θ": "th (θ)", "ð": "th (ð)", "f": "f", "v": "v", "ɹ": "r (ɹ)", "l": "l", "z": "z", "ʃ": "sh (ʃ)",
	"æ": "æ", "ɪ": "ɪ", "iː": "iː", "ʊ": "ʊ", "uː": "uː", "ʌ": "ʌ", "ɛ": "ɛ",
}

## 시험 전용: Callable(lang: String, limit: int) -> Array (StudyLog.weak_phonemes 와 같은 모양)
static var weak_provider: Callable = Callable()

var lang: String = "en"
var stage: String = "loading" ## loading | error | unsupported | list | detail_loading | detail | drill | summary
var phonemes: Array = [] ## [{p, label, hint_ko}]
var weak: Array = [] ## [{p, n, bad, rate, heard}]
var cur_p: String = ""
var info: Dictionary = {}
var items: Array = [] ## 연습 문항 [{text, ko, url, kind}]
var results: Array = [] ## 문항마다 {tries, success, unavailable}
var idx: int = 0
var attempts: int = 0
var attribution: String = ""
var err_text: String = ""
var xp_gained: int = 0
var drill: SpeakDrill = null

var _shell: Dictionary = {}
var _top_box: VBoxContainer = null
var _next_btn: Button = null
var _serial: int = 0
var _call = null
var _from_args: bool = false
var _summary_done: bool = false
var _marked_today: bool = false
var _last_next_msec: int = -100000


func _init() -> void:
	_shell = SpeakDrill.build_shell(self, go_back)


func _exit_tree() -> void:
	_serial += 1
	SpeakDrill.cancel_call(_call)
	_call = null
	_leave_drill() ## _render() takes the drill and its recorder out of the tree: they would never be freed with this screen


## args: {p: "θ"} 가 있으면 소리 목록을 읽은 뒤 그 소리의 설명 화면으로 바로 간다.
func open(l: String, args: Dictionary = {}) -> void:
	lang = l
	_reset()
	if lang != "en":
		stage = "unsupported"
		_render()
		return
	var p: String = str(args.get("p", ""))
	_from_args = p != ""
	_load_list(p)


func on_hide() -> void:
	if drill != null and is_instance_valid(drill):
		drill.stop_all()
	else:
		Tts.stop()


## 뒤로: 연습 중이면 소리 설명 → 소리 목록 → 허브 순서.
func go_back() -> bool:
	match stage:
		"drill", "summary":
			_leave_drill()
			stage = "detail" if not info.is_empty() else "list"
			_render()
			return true
		"detail", "detail_loading":
			_serial += 1
			SpeakDrill.cancel_call(_call)
			_call = null
			stage = "list"
			_render()
			return true
	closed.emit()
	return true


func _reset() -> void:
	_serial += 1
	SpeakDrill.cancel_call(_call)
	_call = null
	_leave_drill()
	phonemes = []
	weak = []
	cur_p = ""
	info = {}
	items = []
	results = []
	idx = 0
	attempts = 0
	attribution = ""
	err_text = ""
	xp_gained = 0
	_summary_done = false
	_marked_today = false
	stage = "loading"


# ---------------------------------------------------------------- loading

static func weak_list(l: String, limit: int) -> Array:
	if weak_provider.is_valid():
		var v: Variant = weak_provider.call(l, limit)
		return v if v is Array else []
	return StudyLog.weak_phonemes(l, limit)


## 틀린 비율 (0~1 또는 0~100 어느 쪽으로 와도) -> 0~100 정수.
static func rate_pct(it: Dictionary) -> int:
	var r: float = float(it.get("rate", 0.0)) if (it.get("rate", null) is float or it.get("rate", null) is int) else 0.0
	if r <= 1.0:
		r *= 100.0
	return clampi(roundi(r), 0, 100)


static func parse_phonemes(data: Variant) -> Array:
	var out: Array = []
	if not (data is Dictionary):
		return out
	var arr: Variant = (data as Dictionary).get("phonemes", null)
	if not (arr is Array):
		return out
	for it in arr:
		if it is Dictionary and str((it as Dictionary).get("p", "")) != "":
			var d: Dictionary = it
			out.append({"p": str(d["p"]), "label": str(d.get("label", d["p"])), "hint_ko": str(d.get("hint_ko", ""))})
	return out


func label_of(p: String) -> String:
	for it in phonemes:
		if str((it as Dictionary)["p"]) == p:
			return str((it as Dictionary)["label"])
	return short_label(p)


static func short_label(p: String) -> String:
	return str(FALLBACK_LABELS.get(p, p))


func _load_list(then_choose: String) -> void:
	stage = "loading"
	_render()
	var serial: int = _serial
	var req: Object = SpeakDrill.request("/practice/phonemes", null, Api.TIMEOUT_SHORT)
	_call = req
	var res: Dictionary = await req.wait()
	if serial != _serial:
		return
	_call = null
	if bool(res.get("cancelled", false)):
		return
	if not bool(res.get("ok", false)):
		stage = "error"
		err_text = SpeakDrill.error_message(res, "소리 목록을 불러오지 못했어요. 잠시 뒤 다시 시도해 주세요.")
		_render()
		return
	phonemes = parse_phonemes(res.get("data", null))
	if phonemes.is_empty():
		stage = "error"
		err_text = "연습할 수 있는 소리가 아직 없어요."
		_render()
		return
	_refresh_weak()
	if then_choose != "":
		choose(then_choose)
		return
	stage = "list"
	_render()


func _refresh_weak() -> void:
	weak = []
	for it in weak_list(lang, WEAK_SHOWN + 5):
		if it is Dictionary:
			var p: String = str((it as Dictionary).get("p", ""))
			var known := false
			for ph in phonemes:
				if str((ph as Dictionary)["p"]) == p:
					known = true
					break
			if known:
				weak.append(it)
			if weak.size() >= WEAK_SHOWN:
				break


## 소리 하나를 고른다: 설명 자료를 받아 설명 화면으로.
func choose(p: String) -> void:
	_serial += 1
	SpeakDrill.cancel_call(_call)
	_call = null
	cur_p = p
	info = {}
	stage = "detail_loading"
	_render()
	var serial: int = _serial
	var req: Object = SpeakDrill.request("/practice/phoneme?p=%s&sentences=%d" % [p.uri_encode(), SENTENCES_N], null, Api.TIMEOUT_SHORT)
	_call = req
	var res: Dictionary = await req.wait()
	if serial != _serial or stage != "detail_loading":
		return
	_call = null
	if bool(res.get("cancelled", false)):
		return
	if not bool(res.get("ok", false)):
		stage = "error"
		err_text = SpeakDrill.error_message(res, "이 소리의 연습 자료를 불러오지 못했어요.")
		_render()
		return
	var d: Variant = res.get("data", null)
	var built := build_items(d)
	if built.is_empty():
		stage = "error"
		err_text = "이 소리는 아직 연습할 문장이 없어요."
		_render()
		return
	info = d as Dictionary
	items = built
	attribution = str(info.get("attribution", "")) if _has_sentences(info) else ""
	stage = "detail"
	_render()


static func _has_sentences(d: Dictionary) -> bool:
	var s: Variant = d.get("sentences", null)
	return s is Array and not (s as Array).is_empty()


## 구절(phrases)과 예문(sentences)에서 연습 문항 최대 5개: 예문은 3개까지, 모자란 만큼 구절로 채운다.
static func build_items(data: Variant) -> Array:
	var out: Array = []
	if not (data is Dictionary):
		return out
	var d: Dictionary = data
	var sents: Array = []
	var s_raw: Variant = d.get("sentences", null)
	if s_raw is Array:
		for s in s_raw:
			if s is Dictionary and str((s as Dictionary).get("text", "")).strip_edges() != "":
				sents.append({"text": str(s["text"]).strip_edges(), "ko": str((s as Dictionary).get("ko", "")), "url": str((s as Dictionary).get("url", "")), "kind": "sentence"})
			if sents.size() >= SENTENCES_N:
				break
	var phr: Array = []
	var p_raw: Variant = d.get("phrases", null)
	if p_raw is Array:
		for s in p_raw:
			if s is Dictionary and str((s as Dictionary).get("text", "")).strip_edges() != "":
				phr.append({"text": str(s["text"]).strip_edges(), "ko": str((s as Dictionary).get("ko", "")), "url": "", "kind": "phrase"})
	var n_phr: int = mini(phr.size(), ITEMS_N - sents.size())
	out.append_array(phr.slice(0, n_phr))
	out.append_array(sents)
	return out.slice(0, ITEMS_N)


# ---------------------------------------------------------------- drill

func start_drill() -> void:
	if items.is_empty():
		return
	_leave_drill()
	results = []
	for i in items.size():
		results.append({"tries": 0, "success": false, "unavailable": false})
	idx = 0
	attempts = 0
	xp_gained = 0
	_summary_done = false
	_marked_today = false
	stage = "drill"
	drill = SpeakDrill.new(lang, "drill")
	drill.show_prosody = false
	drill.make_recorder("말하기")
	drill.scored.connect(_on_scored)
	_render()
	_show_item()


func _leave_drill() -> void:
	if drill == null:
		return
	if is_instance_valid(drill):
		drill.stop_all()
		var rec: RecorderWidget = drill.recorder
		if rec != null and is_instance_valid(rec):
			if rec.get_parent() != null:
				rec.get_parent().remove_child(rec)
			rec.queue_free()
		if drill.get_parent() != null:
			drill.get_parent().remove_child(drill)
		drill.queue_free()
	drill = null
	_top_box = null
	_next_btn = null


func phoneme_off() -> bool:
	return Backend.status == Backend.Status.READY and Backend.health.has("phoneme") and not bool(Backend.health["phoneme"])


## 한 번의 채점 결과가 이 소리(p)를 잘 냈는지.
## 반환 {has_ph, found, good, success, unavailable, words: [{t, ok, heard}]}
static func judge(res: Dictionary, p: String) -> Dictionary:
	var out := {"has_ph": false, "found": 0, "good": 0, "success": false, "unavailable": true, "words": []}
	var units: Variant = res.get("units", null)
	if not (units is Array):
		return out
	for u in units:
		if not (u is Dictionary):
			continue
		var phs: Array = ScorePanel.phonemes_of(u as Dictionary)
		if phs.is_empty():
			continue
		out["has_ph"] = true
		var hit := 0
		var bad := 0
		var heard := ""
		for ph in phs:
			if str((ph as Dictionary).get("p", "")) != p:
				continue
			hit += 1
			if bool((ph as Dictionary).get("ok", true)):
				out["good"] = int(out["good"]) + 1
			else:
				bad += 1
				var hv: Variant = (ph as Dictionary).get("heard", null)
				if heard == "" and hv != null:
					heard = str(hv)
		if hit > 0:
			out["found"] = int(out["found"]) + hit
			(out["words"] as Array).append({"t": str((u as Dictionary).get("t", "")), "ok": bad == 0, "heard": heard})
	out["unavailable"] = not bool(out["has_ph"])
	out["success"] = int(out["found"]) > 0 and int(out["good"]) == int(out["found"])
	return out


func current() -> Dictionary:
	if idx >= 0 and idx < items.size():
		return items[idx]
	return {}


func _show_item() -> void:
	var it: Dictionary = current()
	if drill != null and not it.is_empty():
		drill.set_target(str(it["text"]), "", str(it.get("ko", "")))
	(_shell["count"] as Label).text = "%d / %d" % [idx + 1, items.size()] if stage == "drill" else ""
	_render_top()
	if _next_btn != null and is_instance_valid(_next_btn):
		_next_btn.text = "결과 보기" if idx + 1 >= items.size() else "다음 ▶"


func _on_scored(res: Dictionary, _tgt: String) -> void:
	if stage != "drill" or idx >= results.size():
		return
	var r: Dictionary = results[idx]
	r["tries"] = int(r["tries"]) + 1
	attempts += 1
	var v := judge(res, cur_p)
	r["unavailable"] = bool(v["unavailable"]) or phoneme_off()
	r["last"] = v
	if bool(v["success"]) and not bool(r["unavailable"]):
		r["success"] = true
	if not _marked_today and attempts >= MARK_TODAY_AT:
		_marked_today = true
		Store.mark_today(lang)
		Store.save_progress()
	_render_top()


func next_item() -> void:
	if stage != "drill":
		return
	if idx + 1 >= items.size():
		finish()
		return
	idx += 1
	_show_item()


func _on_next_pressed() -> void:
	var now: int = Time.get_ticks_msec()
	if now - _last_next_msec < NEXT_LOCK_MSEC:
		return
	_last_next_msec = now
	next_item()


func success_count() -> int:
	var n := 0
	for r in results:
		if bool((r as Dictionary)["success"]):
			n += 1
	return n


func finish() -> void:
	if stage != "drill" and stage != "summary":
		return
	stage = "summary"
	_leave_drill()
	if not _summary_done:
		_summary_done = true
		if attempts > 0:
			xp_gained = XP_DONE
			Store.add_xp(lang, XP_DONE)
			Store.save_progress()
			StudyLog.add_event(lang, "drill", 1)
	_render()


# ---------------------------------------------------------------- drawing

func _acc() -> Color:
	return Pal.EN


func _ipa_button(text: String, kind: String, accent: Color) -> Button:
	var b := SpeakDrill.touch_button(text, kind, accent)
	b.add_theme_font_override("font", Ipa.font(true))
	return b


## UI.chip_kind whose text wraps inside the chip when it is longer than 280 px (a long word + "(…로 들림)" at a big
## text size would otherwise be wider than the screen: the chip's label does not wrap by itself).
func _wrapping_chip(txt: String, kind: String) -> PanelContainer:
	var chip := UI.chip_kind(txt, kind)
	var lbl := chip.get_child(0) as Label
	lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	chip.custom_minimum_size.x = minf(UI.text_width(txt, Ds.fs(13), true) + 28.0, 280.0)
	return chip


## A sound to pick from the full list: the pill look of UI.filter_chip (not selected; pressing opens the sound).
func _ipa_chip(text: String, on_tap: Callable) -> Button:
	var b := UI.filter_chip(text, false, on_tap)
	b.add_theme_font_override("font", Ipa.font(true))
	return b


func _render() -> void:
	var c: VBoxContainer = (_shell["page"] as PageScroll).content
	if drill != null and is_instance_valid(drill) and drill.get_parent() != null:
		drill.get_parent().remove_child(drill)
	_top_box = null
	UI.clear(c)
	(_shell["title"] as Label).text = "약한 소리"
	(_shell["count"] as Label).text = ""
	if stage != "drill":
		SpeakDrill.hide_footer(_shell, drill.recorder if drill != null and is_instance_valid(drill) else null)
	match stage:
		"loading", "detail_loading":
			c.add_child(UI.label("불러오는 중이에요…", "Muted"))
			var cb := SpeakDrill.touch_button("취소", "soft", _acc())
			cb.pressed.connect(func() -> void: go_back())
			c.add_child(cb)
		"unsupported":
			c.add_child(SpeakDrill.notice("약한 소리 연습은 영어만 지원해요. 위쪽 탭에서 영어로 바꿔 주세요.", false))
			var ub := SpeakDrill.touch_button("연습으로", "flat", _acc())
			ub.pressed.connect(func() -> void: closed.emit())
			c.add_child(ub)
		"error":
			c.add_child(SpeakDrill.notice(err_text))
			var rb := SpeakDrill.touch_button("다시 시도", "primary", _acc())
			rb.pressed.connect(func() -> void:
				if cur_p != "" and not phonemes.is_empty():
					choose(cur_p)
				else:
					_load_list(""))
			c.add_child(rb)
			var bb := SpeakDrill.touch_button("연습으로", "flat", _acc())
			bb.pressed.connect(func() -> void: closed.emit())
			c.add_child(bb)
		"list":
			_render_list(c)
		"detail":
			_render_detail(c)
		"drill":
			_top_box = UI.vbox(12)
			c.add_child(_top_box)
			c.add_child(drill)
			_build_footer()
			_render_top()
			(_shell["count"] as Label).text = "%d / %d" % [idx + 1, items.size()]
		"summary":
			_render_summary(c)
	UI.fix_cjk(c)


func _render_list(c: VBoxContainer) -> void:
	var acc := _acc()
	var intro := UI.card("BigCard", 8)
	intro.body.add_child(UI.label("약한 소리 연습", "Eyebrow", false))
	intro.body.add_child(UI.label("자주 틀리는 소리만 골라서 연습해요", "H2"))
	intro.body.add_child(UI.label("레슨과 쉐도잉에서 채점한 결과로 약한 소리를 찾아요. 소리를 고르면 발음 방법을 보고 짧은 문장 5개를 연습해요.", "Muted"))
	c.add_child(intro)

	var wk := UI.card("Card", 10)
	wk.body.add_child(UI.label("지금 약한 소리 (최근 30회 기준)", "H3"))
	if weak.is_empty():
		wk.body.add_child(UI.label("아직 약한 소리를 찾지 못했어요. 레슨이나 쉐도잉에서 따라 말하면 약한 소리를 찾아 줘요. 아래에서 연습할 소리를 직접 골라도 돼요.", "Muted"))
	else:
		var fl := UI.flow(8, 8)
		for it in weak:
			var d: Dictionary = it
			var p: String = str(d["p"])
			var b := _ipa_button("%s  틀림 %d%%" % [label_of(p), rate_pct(d)], "soft", Pal.BAD)
			b.pressed.connect(func() -> void: choose(p))
			fl.add_child(b)
		wk.body.add_child(fl)
	c.add_child(wk)

	var all := UI.card("Card", 10)
	all.body.add_child(UI.label("소리 직접 고르기", "H3"))
	var fl2 := UI.flow(8, 8)
	for it in phonemes:
		var d2: Dictionary = it
		var p2: String = str(d2["p"])
		fl2.add_child(_ipa_chip(str(d2["label"]), func() -> void: choose(p2)))
	SpeakDrill.fit_touch(fl2) # the PC chip is 32 px high: every pressable thing here is at least 44
	for ch in fl2.get_children():
		(ch as Control).custom_minimum_size.x = maxf((ch as Control).custom_minimum_size.x, maxf(44.0, Ds.touch_min())) # one short symbol is still a full-size target
	all.body.add_child(fl2)
	c.add_child(all)


func _render_detail(c: VBoxContainer) -> void:
	var acc := _acc()
	var card := UI.card("BigCard", 10)
	var title := UI.label(str(info.get("label", cur_p)), "H2")
	title.add_theme_font_override("font", Ipa.font(true))
	card.body.add_child(title)
	if str(info.get("hint_ko", "")) != "":
		card.body.add_child(UI.label(str(info.get("hint_ko", "")), ""))
	c.add_child(card)

	var pairs: Variant = info.get("pairs", null)
	if pairs is Array and not (pairs as Array).is_empty():
		var pc := UI.card("Card", 10)
		pc.body.add_child(UI.label("비슷한 소리 구분", "H3"))
		for pr in pairs:
			if not (pr is Dictionary):
				continue
			var a: String = str((pr as Dictionary).get("a", ""))
			var b: String = str((pr as Dictionary).get("b", ""))
			if a == "" or b == "":
				continue
			var row := UI.flow(8, 6)
			var ba := SpeakDrill.touch_button("▶ " + a, "soft", acc)
			ba.pressed.connect(func() -> void: Tts.speak(a, "en", false))
			row.add_child(ba)
			var bb := SpeakDrill.touch_button("▶ " + b, "soft", acc)
			bb.pressed.connect(func() -> void: Tts.speak(b, "en", false))
			row.add_child(bb)
			pc.body.add_child(row)
			if str((pr as Dictionary).get("ko", "")) != "":
				pc.body.add_child(UI.label(str((pr as Dictionary)["ko"]), "Small"))
		c.add_child(pc)

	var words: Variant = info.get("words", null)
	if words is Array and not (words as Array).is_empty():
		var wc := UI.card("Card", 10)
		wc.body.add_child(UI.label("이 소리가 든 단어 듣기", "H3"))
		var fl := UI.flow(8, 8)
		for w in words:
			var ws: String = str(w)
			var wb := SpeakDrill.touch_button("▶ " + ws, "soft", acc)
			wb.pressed.connect(func() -> void: Tts.speak(ws, "en", false))
			fl.add_child(wb)
		wc.body.add_child(fl)
		c.add_child(wc)

	var go := SpeakDrill.touch_button("연습 시작 (%d문항)" % items.size(), "primary", acc, 52)
	go.pressed.connect(start_drill)
	c.add_child(go)


func _render_top() -> void:
	if _top_box == null or not is_instance_valid(_top_box) or stage != "drill":
		return
	UI.clear(_top_box)
	var it: Dictionary = current()
	if it.is_empty():
		return
	var acc := _acc()
	var card := UI.card("BigCard", 10)
	card.body.add_child(UI.label("연습 %d / %d  ·  소리 %s" % [idx + 1, items.size(), label_of(cur_p)], "Eyebrow", false))
	var big := UI.label(str(it["text"]), "")
	big.add_theme_font_size_override("font_size", Ds.fs(22))
	big.add_theme_font_override("font", UI.bold_font())
	card.body.add_child(big)
	if str(it.get("ko", "")) != "":
		card.body.add_child(UI.label(str(it["ko"]), "Muted"))
	var lr := UI.flow(8, 8)
	var b1 := SpeakDrill.touch_button("▶ 듣기", "soft", acc)
	b1.pressed.connect(func() -> void: drill.listen(false))
	lr.add_child(b1)
	var b2 := SpeakDrill.touch_button("천천히", "soft", acc)
	b2.pressed.connect(func() -> void: drill.listen(true))
	lr.add_child(b2)
	card.body.add_child(lr)
	if phoneme_off():
		card.body.add_child(UI.colored(NO_PH_TEXT, Pal.WARN_ON, "Small"))
	_top_box.add_child(card)

	var r: Dictionary = results[idx] if idx < results.size() else {}
	if not r.is_empty() and r.has("last"):
		_top_box.add_child(_verdict_box(r))
	UI.fix_cjk(_top_box)


func _verdict_box(r: Dictionary) -> Control:
	var v: Dictionary = r["last"]
	var box := UI.card("Sunk", 8)
	if bool(v["unavailable"]) or bool(r["unavailable"]):
		box.body.add_child(UI.colored(NO_PH_TEXT, Pal.WARN_ON))
		return box
	if int(v["found"]) == 0:
		box.body.add_child(UI.label("이 문장에서 %s 소리를 찾지 못했어요. 다시 말해 보세요." % label_of(cur_p), "Muted"))
		return box
	var head := "이번 소리 %s" % label_of(cur_p)
	box.body.add_child(UI.label(head, "Strong"))
	var fl := UI.flow(6, 6)
	for w in v["words"]:
		var wd: Dictionary = w
		var ok := bool(wd["ok"])
		var txt: String = str(wd["t"]) + ("  O" if ok else "  X")
		if not ok and str(wd.get("heard", "")) != "":
			txt += " (%s로 들림)" % str(wd["heard"])
		fl.add_child(_wrapping_chip(txt, "ok" if ok else "bad")) # the O / X in the text is the non-colour cue
	box.body.add_child(fl)
	if bool(v["success"]):
		box.body.add_child(UI.colored("✓ 성공! 이 소리가 잘 들렸어요.", Pal.OK_ON, "Strong"))
	else:
		box.body.add_child(UI.colored("✕ 다시 한 번 해 볼까요? 위의 발음 방법을 떠올려 보세요.", Pal.WARN_ON, "Small"))
	return box


func _build_footer() -> void:
	var row := SpeakDrill.new_footer_row(_shell, drill.recorder)
	row.add_child(drill.recorder)
	row.add_child(UI.spacer())
	_next_btn = SpeakDrill.touch_button("결과 보기" if idx + 1 >= items.size() else "다음 ▶", "primary", _acc())
	_next_btn.pressed.connect(_on_next_pressed)
	row.add_child(_next_btn)


func _render_summary(c: VBoxContainer) -> void:
	var acc := _acc()
	var card := UI.card("BigCard", 10)
	card.body.add_child(UI.label("약한 소리 연습 결과  ·  " + label_of(cur_p), "Eyebrow", false))
	var all_unavailable := true
	for r in results:
		if int((r as Dictionary)["tries"]) > 0 and not bool((r as Dictionary)["unavailable"]):
			all_unavailable = false
	if attempts == 0:
		card.body.add_child(UI.label("말해 본 문항이 없어요.", "H2"))
	elif all_unavailable:
		card.body.add_child(UI.label("%d문항 연습했어요" % attempts, "H2"))
		card.body.add_child(UI.colored(NO_PH_TEXT, Pal.WARN_ON, "Small"))
	else:
		var s := success_count()
		var good: bool = s * 2 >= items.size()
		card.body.add_child(UI.colored("%s %d/%d 성공" % ["✓" if good else "△", s, items.size()], Pal.OK_ON if good else Pal.WARN_ON, "H1", false))
		card.body.add_child(UI.label("한 번에 안 되어도 괜찮아요. 같은 소리를 며칠 나눠서 연습하면 좋아져요.", "Muted"))
	if xp_gained > 0:
		card.body.add_child(UI.label("+%d XP" % xp_gained, "Muted"))
	c.add_child(card)
	if attribution != "":
		c.add_child(UI.colored(attribution, Pal.MUTED, "Small"))
	var again := SpeakDrill.touch_button("다시 하기", "primary", acc, 48)
	again.pressed.connect(start_drill)
	c.add_child(again)
	var other := SpeakDrill.touch_button("다른 소리 고르기", "soft", acc, 48)
	other.pressed.connect(func() -> void:
		_leave_drill()
		info = {}
		_refresh_weak()
		stage = "list"
		_render())
	c.add_child(other)
	var out := SpeakDrill.touch_button("연습으로", "flat", acc, 48)
	out.pressed.connect(func() -> void: closed.emit())
	c.add_child(out)
