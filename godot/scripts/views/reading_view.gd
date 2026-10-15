class_name ReadingView
extends AppView
## 읽기 (LingQ/Lute style): paste a text, the words are colored by difficulty and by what the
## person already knows; clicking a word shows its meaning, IPA/reading, TTS and Tatoeba examples,
## and puts it into the review list ("복습에 추가") or the known-word list ("아는 단어").
##
## Backend: POST /reading/analyze, POST /reading/gloss, GET /examples (see API.md).
## Files: <storage_dir>/<id>.json (saved texts), <storage_dir>/cache/<id>.json (analysis),
##        <storage_dir>/glosses_<lang>.json (per-lemma meanings).

const NAME_KO := {"en": "영어", "ja": "일본어"}
const MAX_CHARS := 20000
const GLOSS_CHUNK := 20
const NARROW_W := 1000.0
const PANEL_W := 360.0
const FONT_SIZES := {"s": 17, "m": 20, "l": 24}
const MISSING_MSG := "읽기 기능을 쓰려면 AI 엔진을 최신으로 다시 시작해 주세요"
const LEVEL_KO := {"easy": "쉬운 단어", "mid": "보통 단어", "hard": "어려운 단어"}
const STATUS_KO := {"new": "새 단어", "learning": "복습 중", "known": "아는 단어", "easy": "쉬운 단어"}
const LEARN_BG := Color("#FFE6A6")
const LEARN_FG := Color("#6B4A00")
const SAMPLES := {
	"en": {"title": "A Walk After Dinner", "text": "Most evenings, after dinner, my grandfather takes a slow walk around the neighbourhood. He claims it helps his digestion, but I suspect he simply enjoys gossiping with the neighbours.\n\nLast week he came home grinning. A stray cat had followed him for three blocks, and he had reluctantly given it half of his sandwich. Now the cat waits for him at the gate every night, as patient as a tiny, furry accountant."},
	"ja": {"title": "朝の散歩", "text": "毎朝、私は近くの公園を散歩します。季節によって景色が少しずつ変わるので、毎日歩いても飽きません。\n\n昨日は桜のつぼみが膨らんでいるのに気づきました。来週には満開になるかもしれません。帰りにパン屋に寄って、焼きたてのパンを買いました。"},
}

var storage_dir: String = "user://reading"
var auto_fetch: bool = true ## tests switch network calls off and feed fixture data instead

var lang: String = "en"
var mode: String = "library" # library | reader
var doc: Dictionary = {} # {id, title, lang, text, created, opened}
var analyzing: bool = false
var analyze_error: String = ""
var tokens: Array = []
var sentences: Dictionary = {} # sentence index -> text
var lemmas: Dictionary = {} # key -> {lemma, level, zipf, count, tok, s}
var selected: int = -1 # token index shown in the word panel
var glosses: Dictionary = {} # lang -> {key -> {lemma, pos, ko, ipa, note}}
var gloss_pending: Dictionary = {} # "lang|key" -> true
var gloss_total: int = 0
var gloss_done: int = 0
var examples: Dictionary = {} # "lang|key" -> /examples response, or {"error": str}
var examples_pending: Dictionary = {}

var _draft_title: String = ""
var _draft_text: String = ""
var _confirm_delete: String = ""
var _confirm_bulk: String = "" # "" | "easy" | "all"
var _known: Dictionary = {}
var _learning: Dictionary = {}
var _doc_serial: int = 0
var _narrow: bool = false

var _lib_page: PageScroll
var _reader: VBoxContainer
var _head: VBoxContainer
var _split: BoxContainer
var _text_scroll: ScrollContainer
var _text_content: VBoxContainer
var _text_card: CardBox
var _rtl: RichTextLabel
var _text_state: VBoxContainer
var _panel: PanelContainer
var _panel_scroll: ScrollContainer
var _panel_body: VBoxContainer
var _gloss_label: Label
var _te: TextEdit
var _count_label: Label
var _analyze_btn: Button


func _ready() -> void:
	_lib_page = PageScroll.new(860.0)
	_lib_page.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_lib_page)
	_build_reader()
	lang = Store.lang()
	_ensure_dirs()
	_apply_layout()
	_render()


func refresh() -> void:
	if mode == "library":
		lang = Store.lang()
		_render()
	else:
		# statuses may have changed in another tab (복습 list edited)
		_refresh_sets()
		_render_header()
		_render_text()
		_render_panel()


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED and _split != null:
		_apply_layout()


# ---------------------------------------------------------------- helpers

func lemma_key(lemma: String) -> String:
	var t: String = lemma.strip_edges()
	return t.to_lower() if lang == "en" else t


func _accent() -> Color:
	return Pal.accent(lang)


## Light accent tint behind "unknown word" candidates.
func _new_bg() -> Color:
	return _accent().lerp(Color.WHITE, 0.8)


static func _hex(c: Color) -> String:
	return "#" + c.to_html(false)


static func _comma(n: int) -> String:
	var s := str(n)
	var out := ""
	while s.length() > 3:
		out = "," + s.right(3) + out
		s = s.left(s.length() - 3)
	return s + out


## Korean message for a failed backend call (404 = the running engine predates /reading).
static func error_text(res: Dictionary) -> String:
	if int(res.get("code", 0)) == 404:
		return MISSING_MSG
	var e: String = str(res.get("error", ""))
	return e if e != "" else "서버 응답을 읽지 못했어요. 잠시 뒤 다시 시도해 주세요."


func _font_key() -> String:
	var k: String = str(Store.prefs.get("reading_font", "m"))
	return k if FONT_SIZES.has(k) else "m"


func _refresh_sets() -> void:
	_known = Store.known_set(lang)
	_learning = {}
	for r in Store.review_for(lang):
		_learning[lemma_key(str((r as Dictionary)["target"]))] = true


## "known" | "learning" | "new" (mid/hard, not marked) | "easy"
func word_status(key: String) -> String:
	if _known.has(key):
		return "known"
	if _learning.has(key):
		return "learning"
	var lv: String = str((lemmas.get(key, {}) as Dictionary).get("level", "easy"))
	return "new" if lv == "mid" or lv == "hard" else "easy"


func counts() -> Dictionary:
	var c := {"new": 0, "learning": 0, "known": 0, "easy": 0}
	for k in lemmas.keys():
		c[word_status(k)] += 1
	return c


func _cur_glosses() -> Dictionary:
	if not glosses.has(lang):
		glosses[lang] = _load_json(storage_dir.path_join("glosses_%s.json" % lang), {})
	return glosses[lang]


func gloss_for(key: String) -> Dictionary:
	return (_cur_glosses().get(key, {}) as Dictionary)


# ---------------------------------------------------------------- storage

func _ensure_dirs() -> void:
	DirAccess.make_dir_recursive_absolute(storage_dir.path_join("cache"))


static func _load_json(path: String, fallback: Variant) -> Variant:
	if not FileAccess.file_exists(path):
		return fallback
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if parsed == null or typeof(parsed) != typeof(fallback):
		return fallback
	return parsed


static func _save_json(path: String, data: Variant) -> bool:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(JSON.stringify(data))
	return true


func doc_path(id: String) -> String:
	return storage_dir.path_join(id + ".json")


func save_doc(d: Dictionary) -> void:
	_ensure_dirs()
	if not _save_json(doc_path(str(d["id"])), d):
		Toast.error("글을 저장하지 못했어요.")


func new_doc(title: String, l: String, text: String) -> Dictionary:
	var t: String = title.strip_edges()
	if t == "":
		t = text.strip_edges().split("\n")[0].strip_edges()
		if t.length() > 40:
			t = t.left(40) + "…"
	var now: int = int(Time.get_unix_time_from_system())
	return {"id": Progress.new_id(), "title": t, "lang": l, "text": text, "created": now, "opened": now}


## Saved texts of language `l`, most recently opened first.
func list_docs(l: String) -> Array:
	var out: Array = []
	if not DirAccess.dir_exists_absolute(storage_dir):
		return out
	for f in DirAccess.get_files_at(storage_dir):
		if not f.ends_with(".json") or f.begins_with("glosses_"):
			continue
		var d: Variant = _load_json(storage_dir.path_join(f), {})
		if d is Dictionary and (d as Dictionary).has("id") and (d as Dictionary).has("text") and str((d as Dictionary).get("lang", "")) == l:
			out.append(d)
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a.get("opened", 0)) > int(b.get("opened", 0)))
	return out


func delete_doc(id: String) -> void:
	for p in [doc_path(id), storage_dir.path_join("cache").path_join(id + ".json")]:
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(p))


# ---------------------------------------------------------------- top-level render

func _render() -> void:
	_lib_page.visible = mode == "library"
	_reader.visible = mode == "reader"
	if mode == "library":
		_render_library()
	else:
		_refresh_sets()
		_render_header()
		_render_text()
		_render_panel()
		_apply_layout()


# ---------------------------------------------------------------- library

func _render_library() -> void:
	var c: VBoxContainer = _lib_page.content
	UI.clear(c)
	_te = null
	var acc: Color = _accent()
	var docs: Array = list_docs(lang)

	var top := UI.hbox(12)
	top.add_child(UI.lang_segmented(lang, func(v: String) -> void:
		lang = v
		Store.set_lang(v)
		_confirm_delete = ""
		_render()))
	top.add_child(UI.spacer())
	top.add_child(UI.label("저장한 글 %d개" % docs.size(), "Muted", false))
	c.add_child(top)

	var card := UI.card("BigCard", 12)
	card.body.add_child(UI.label("읽기", "Eyebrow", false))
	card.body.add_child(UI.label("읽고 싶은 %s 글을 붙여 넣으세요" % NAME_KO[lang], "H2"))
	card.body.add_child(UI.label("기사·소설·가사 무엇이든 좋아요. 분석하면 처음 보는 어려운 단어가 색으로 표시되고, 단어를 누르면 뜻·발음·예문을 보고 복습 목록에 넣을 수 있어요.", "Muted"))
	var title_le := LineEdit.new()
	title_le.placeholder_text = "제목 (선택)"
	title_le.text = _draft_title
	title_le.text_changed.connect(func(t: String) -> void: _draft_title = t)
	card.body.add_child(title_le)
	_te = TextEdit.new()
	_te.custom_minimum_size = Vector2(0, 260)
	_te.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	_te.placeholder_text = "여기에 %s 글을 붙여 넣으세요 (Ctrl+V)" % NAME_KO[lang]
	_te.text = _draft_text
	_te.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if lang == "ja":
		_te.add_theme_font_override("font", UI.ja_font())
		title_le.add_theme_font_override("font", UI.ja_font())
	_te.text_changed.connect(func() -> void:
		_draft_text = _te.text
		_update_draft_state())
	_te.gui_input.connect(func(ev: InputEvent) -> void:
		if ev is InputEventKey and ev.pressed and (ev as InputEventKey).ctrl_pressed and ((ev as InputEventKey).keycode == KEY_ENTER or (ev as InputEventKey).keycode == KEY_KP_ENTER):
			_te.accept_event()
			analyze_draft())
	card.body.add_child(_te)
	var row := UI.hbox(10)
	var sample := UI.link_button("예시 글 넣기", "연습용 짧은 %s 글을 넣어요" % NAME_KO[lang])
	sample.pressed.connect(func() -> void:
		var s: Dictionary = SAMPLES[lang]
		_draft_title = str(s["title"])
		_draft_text = str(s["text"])
		_render_library())
	row.add_child(sample)
	_count_label = UI.label("", "Small", false)
	_count_label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(_count_label)
	row.add_child(UI.spacer())
	_analyze_btn = UI.button("분석하기", "primary", acc, 50)
	_analyze_btn.custom_minimum_size.x = 180
	_analyze_btn.tooltip_text = "Ctrl+Enter"
	_analyze_btn.pressed.connect(analyze_draft)
	row.add_child(_analyze_btn)
	card.body.add_child(row)
	c.add_child(card)
	_update_draft_state()

	var list := UI.card("Card", 6)
	list.body.add_child(UI.label("저장한 %s 글" % NAME_KO[lang], "Eyebrow", false))
	if docs.is_empty():
		list.body.add_child(UI.label("아직 없어요. 위에 글을 붙여 넣고 '분석하기'를 누르면 여기에 저장돼요.", "Muted"))
	for i in docs.size():
		if i > 0:
			list.body.add_child(UI.hline())
		list.body.add_child(_doc_row(docs[i]))
	c.add_child(list)
	UI.fix_cjk(c)


func _update_draft_state() -> void:
	if _count_label == null or not is_instance_valid(_count_label):
		return
	var n: int = _draft_text.strip_edges().length()
	_count_label.text = "%s / %s자" % [_comma(n), _comma(MAX_CHARS)]
	_count_label.add_theme_color_override("font_color", Pal.BAD if n > MAX_CHARS else Pal.MUTED)
	_analyze_btn.disabled = n == 0 or n > MAX_CHARS


func _doc_row(d: Dictionary) -> Control:
	var id: String = str(d["id"])
	var row := UI.hbox(10)
	var col := UI.vbox(2)
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.add_child(UI.label(str(d.get("title", "")), "Strong"))
	var text: String = str(d.get("text", ""))
	var preview: String = text.replace("\n", " ").strip_edges()
	if preview.length() > 90:
		preview = preview.left(90) + "…"
	col.add_child(UI.label(preview, "Small"))
	var opened: int = int(d.get("opened", 0))
	var bias: int = int(Time.get_time_zone_from_system().get("bias", 0)) * 60
	var date: String = Time.get_date_string_from_unix_time(opened + bias) if opened > 0 else ""
	col.add_child(UI.colored("%s자 · 마지막으로 연 날 %s" % [_comma(text.length()), date], Pal.MUTED, "Small"))
	row.add_child(col)
	if _confirm_delete == id:
		row.add_child(UI.colored("정말 지울까요?", Pal.BAD, "Small", false))
		var yes := UI.button("지우기", "primary", Pal.BAD)
		yes.pressed.connect(func() -> void:
			delete_doc(id)
			_confirm_delete = ""
			_render_library())
		var no := UI.button("취소", "default")
		no.pressed.connect(func() -> void:
			_confirm_delete = ""
			_render_library())
		row.add_child(yes)
		row.add_child(no)
	else:
		var open := UI.button("열기", "soft", _accent())
		open.pressed.connect(func() -> void: open_doc(d))
		var del := UI.link_button("삭제")
		del.pressed.connect(func() -> void:
			_confirm_delete = id
			_render_library())
		row.add_child(open)
		row.add_child(del)
	for n in row.get_children():
		if n is Button or n is Label:
			(n as Control).size_flags_vertical = Control.SIZE_SHRINK_CENTER
	return row


func analyze_draft() -> void:
	var text: String = _draft_text.replace("\r\n", "\n").replace("\r", "\n").strip_edges()
	if text == "":
		Toast.info("먼저 글을 붙여 넣어 주세요.")
		return
	if text.length() > MAX_CHARS:
		Toast.error("글이 너무 길어요. %s자까지 분석할 수 있어요." % _comma(MAX_CHARS))
		return
	var d := new_doc(_draft_title, lang, text)
	save_doc(d)
	_draft_title = ""
	_draft_text = ""
	open_doc(d)


# ---------------------------------------------------------------- reader: open / analyze

func open_doc(d: Dictionary) -> void:
	_doc_serial += 1
	doc = d.duplicate()
	lang = "ja" if str(doc.get("lang", "en")) == "ja" else "en"
	doc["opened"] = int(Time.get_unix_time_from_system())
	save_doc(doc)
	mode = "reader"
	selected = -1
	_confirm_bulk = ""
	tokens = []
	sentences = {}
	lemmas = {}
	analyze_error = ""
	gloss_total = 0
	gloss_done = 0
	_text_scroll.scroll_vertical = 0
	var cached: Variant = _load_json(storage_dir.path_join("cache").path_join(str(doc["id"]) + ".json"), {})
	if cached is Dictionary and str((cached as Dictionary).get("text", "")) == str(doc["text"]) and set_analysis((cached as Dictionary).get("data", {}), false):
		return
	_run_analyze()


func back_to_library() -> void:
	_doc_serial += 1
	mode = "library"
	selected = -1
	analyzing = false
	Tts.stop()
	_render()


func _run_analyze() -> void:
	analyzing = true
	analyze_error = ""
	_render()
	if not auto_fetch:
		return
	var serial: int = _doc_serial
	var req = Api.post_json("/reading/analyze", {"lang": lang, "text": str(doc["text"])}, 120.0, false)
	var res: Dictionary = await req.wait()
	if serial != _doc_serial or not is_inside_tree():
		return
	analyzing = false
	if res["ok"] and res["data"] is Dictionary and set_analysis(res["data"], true):
		return
	if res["ok"]:
		analyze_error = "분석 결과를 읽지 못했어요. 다시 시도해 주세요."
	else:
		analyze_error = error_text(res)
	Toast.error(analyze_error)
	_render()


## Applies a /reading/analyze response. Returns false when it is not usable.
func set_analysis(data: Variant, cache_it: bool = true) -> bool:
	if not (data is Dictionary) or not ((data as Dictionary).get("tokens", null) is Array):
		return false
	var d: Dictionary = data
	tokens = []
	for t in d["tokens"]:
		if t is Dictionary and (t as Dictionary).has("t"):
			tokens.append(t)
	if tokens.is_empty():
		return false
	sentences = {}
	var raw_s: Variant = d.get("sentences", [])
	if raw_s is Array:
		for s in raw_s:
			if s is Dictionary:
				sentences[int((s as Dictionary).get("i", 0))] = str((s as Dictionary).get("text", ""))
	lemmas = {}
	for i in tokens.size():
		var tk: Dictionary = tokens[i]
		if not bool(tk.get("w", false)):
			continue
		var lem: String = str(tk.get("lemma", "")).strip_edges()
		if lem == "":
			lem = str(tk["t"]).strip_edges()
			tk["lemma"] = lem
		var key := lemma_key(lem)
		if key == "":
			tk["w"] = false
			continue
		if lemmas.has(key):
			(lemmas[key] as Dictionary)["count"] = int((lemmas[key] as Dictionary)["count"]) + 1
		else:
			lemmas[key] = {"lemma": lem, "level": str(tk.get("level", "easy")), "zipf": float(tk.get("zipf", 0.0)), "count": 1, "tok": i, "s": int(tk.get("s", 0))}
	analyzing = false
	analyze_error = ""
	if cache_it:
		_ensure_dirs()
		_save_json(storage_dir.path_join("cache").path_join(str(doc.get("id", "x")) + ".json"), {"text": str(doc.get("text", "")), "data": d})
	_render()
	_start_gloss_batch()
	return true


func sentence_text(s: int) -> String:
	if sentences.has(s) and str(sentences[s]) != "":
		return str(sentences[s])
	var parts := PackedStringArray()
	for tk in tokens:
		if int((tk as Dictionary).get("s", -1)) == s:
			parts.append(str((tk as Dictionary)["t"]))
	return "".join(parts).strip_edges()


## The word under token `i`: {key, lemma, surface, s, sentence, level} (empty if not a word).
func word_at(i: int) -> Dictionary:
	if i < 0 or i >= tokens.size() or not bool((tokens[i] as Dictionary).get("w", false)):
		return {}
	var tk: Dictionary = tokens[i]
	var lem: String = str(tk.get("lemma", tk["t"]))
	var s: int = int(tk.get("s", 0))
	return {"key": lemma_key(lem), "lemma": lem, "surface": str(tk["t"]), "s": s, "sentence": sentence_text(s), "level": str(tk.get("level", "easy"))}


# ---------------------------------------------------------------- reader: layout

func _build_reader() -> void:
	_reader = UI.vbox(0)
	_reader.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_reader)
	_head = UI.vbox(8)
	var hm := UI.margin(_head, 20, 14, 20, 12)
	_reader.add_child(hm)
	var line := ColorRect.new()
	line.color = Pal.LINE
	line.custom_minimum_size = Vector2(0, 1)
	_reader.add_child(line)

	_split = BoxContainer.new()
	_split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_split.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_split.add_theme_constant_override("separation", 0)
	_reader.add_child(_split)

	_text_scroll = ScrollContainer.new()
	_text_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_text_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_text_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var col := ColumnBox.new()
	col.max_width = 780.0
	col.set_padding(18, 28)
	_text_scroll.add_child(col)
	_text_content = col.content
	_split.add_child(_text_scroll)

	_text_state = UI.vbox(10)
	_text_content.add_child(_text_state)
	_text_card = UI.card("Card", 0)
	_rtl = RichTextLabel.new()
	_rtl.bbcode_enabled = true
	_rtl.fit_content = true
	_rtl.scroll_active = false
	_rtl.selection_enabled = false
	_rtl.meta_underlined = false
	_rtl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_rtl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_rtl.add_theme_color_override("default_color", Pal.INK)
	_rtl.add_theme_constant_override("line_separation", 9)
	_rtl.add_theme_constant_override("text_highlight_h_padding", 1)
	_rtl.add_theme_constant_override("text_highlight_v_padding", 2)
	_rtl.meta_clicked.connect(on_meta_clicked)
	_text_card.body.add_child(_rtl)
	_text_content.add_child(_text_card)

	_panel = PanelContainer.new()
	_panel_scroll = ScrollContainer.new()
	_panel_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_panel_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_panel.add_child(_panel_scroll)
	_panel_body = UI.vbox(12)
	_panel_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_panel_scroll.add_child(UI.margin(_panel_body, 20, 18, 20, 24))
	(_panel_scroll.get_child(0) as Control).size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_split.add_child(_panel)


func _apply_layout() -> void:
	if _split == null:
		return
	var was_narrow: bool = _narrow
	_narrow = size.x > 0.0 and size.x < NARROW_W
	_split.vertical = _narrow
	if was_narrow != _narrow and mode == "reader" and selected >= 0:
		_render_panel()
	var st := UI.style(Pal.SURFACE, Pal.LINE, 0, 0, 0, 0)
	if _narrow:
		st.border_width_top = 1
		st.shadow_color = Color(0, 0, 0, 0.08)
		st.shadow_size = 6
		_panel.custom_minimum_size = Vector2(0, maxf(260.0, size.y * 0.46))
		_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_panel.size_flags_vertical = Control.SIZE_FILL
		_panel.visible = selected >= 0
	else:
		st.border_width_left = 1
		_panel.custom_minimum_size = Vector2(PANEL_W, 0)
		_panel.size_flags_horizontal = Control.SIZE_FILL
		_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
		_panel.visible = true
	_panel.add_theme_stylebox_override("panel", st)


# ---------------------------------------------------------------- reader: header

func _render_header() -> void:
	UI.clear(_head)
	var acc: Color = _accent()
	var row1 := UI.hbox(10)
	var back := UI.link_button("← 목록")
	back.add_theme_font_size_override("font_size", 15)
	back.pressed.connect(back_to_library)
	row1.add_child(back)
	var lchip := UI.chip(NAME_KO[lang], acc, Pal.soft(lang))
	lchip.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row1.add_child(lchip)
	var title := UI.label(str(doc.get("title", "")), "H3", false)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.clip_text = true
	title.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	title.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row1.add_child(title)
	row1.add_child(UI.label("글자 크기", "Small", false))
	(row1.get_child(row1.get_child_count() - 1) as Control).size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row1.add_child(UI.segmented([["s", "작게"], ["m", "보통"], ["l", "크게"]], _font_key(), func(v: String) -> void:
		Store.set_pref("reading_font", v)
		_render_header()
		_render_text()))
	_head.add_child(row1)

	if tokens.is_empty():
		UI.fix_cjk(_head)
		return
	var c: Dictionary = counts()
	var row2 := UI.flow(14, 6)
	row2.add_child(_legend(_new_bg(), Pal.INK, "새 단어 %d" % c["new"], false, "아직 표시하지 않은 보통·어려운 단어 (모르는 단어 후보)"))
	row2.add_child(_legend(LEARN_BG, LEARN_FG, "복습 중 %d" % c["learning"], true, "복습 목록에 넣은 단어"))
	row2.add_child(_legend(Color(0, 0, 0, 0), Pal.INK, "아는 단어 %d" % c["known"], false, "'아는 단어'로 표시한 단어"))
	var easy_note := UI.colored("· 쉬운 단어 %d개는 색 없이 보여요" % c["easy"], Pal.MUTED, "Small", false)
	row2.add_child(easy_note)
	_head.add_child(row2)

	var row3 := UI.hbox(6)
	if _confirm_bulk != "":
		var n: int = bulk_keys(_confirm_bulk).size()
		var q: String = "쉬운 단어 %d개를 아는 단어로 표시할까요?" % n if _confirm_bulk == "easy" else "이 글에 남은 새 단어·쉬운 단어 %d개를 모두 아는 단어로 표시할까요?" % n
		var ql := UI.colored(q, Pal.INK, "Small", false)
		ql.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		row3.add_child(ql)
		var yes := UI.button("표시하기", "primary", acc)
		var which: String = _confirm_bulk
		yes.pressed.connect(func() -> void: mark_bulk_known(which))
		var no := UI.button("취소", "default")
		no.pressed.connect(func() -> void:
			_confirm_bulk = ""
			_render_header())
		row3.add_child(yes)
		row3.add_child(no)
	else:
		var b1 := UI.link_button("쉬운 단어 모두 아는 단어로")
		b1.disabled = bulk_keys("easy").is_empty()
		b1.pressed.connect(func() -> void:
			_confirm_bulk = "easy"
			_render_header())
		var b2 := UI.link_button("이 글의 남은 새 단어 모두 아는 단어로")
		b2.disabled = bulk_keys("all").is_empty()
		b2.pressed.connect(func() -> void:
			_confirm_bulk = "all"
			_render_header())
		row3.add_child(b1)
		row3.add_child(b2)
	row3.add_child(UI.spacer())
	_gloss_label = UI.colored("", Pal.MUTED, "Small", false)
	_gloss_label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row3.add_child(_gloss_label)
	_head.add_child(row3)
	_update_gloss_label()
	UI.fix_cjk(_head)


func _legend(bg: Color, fg: Color, text: String, underline: bool, tip: String) -> Control:
	var h := UI.hbox(6)
	h.tooltip_text = tip
	var sw := PanelContainer.new()
	var st := UI.style(bg, Pal.LINE if bg.a == 0.0 else Color(0, 0, 0, 0), 1 if bg.a == 0.0 else 0, 4, 0, 0)
	if underline:
		st.border_color = LEARN_FG
		st.border_width_bottom = 2
	sw.add_theme_stylebox_override("panel", st)
	sw.custom_minimum_size = Vector2(26, 18)
	sw.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	sw.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var ab := Label.new()
	ab.text = "Ab" if lang == "en" else "語"
	ab.add_theme_font_size_override("font_size", 12)
	ab.add_theme_color_override("font_color", fg)
	ab.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	ab.mouse_filter = Control.MOUSE_FILTER_IGNORE
	sw.add_child(ab)
	h.add_child(sw)
	var l := UI.label(text, "Small", false)
	l.add_theme_color_override("font_color", Pal.INK)
	l.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	l.mouse_filter = Control.MOUSE_FILTER_PASS
	h.add_child(l)
	return h


func _update_gloss_label() -> void:
	if _gloss_label == null or not is_instance_valid(_gloss_label):
		return
	if gloss_total > 0 and gloss_done < gloss_total:
		_gloss_label.text = "뜻 불러오는 중… %d/%d" % [gloss_done, gloss_total]
	else:
		_gloss_label.text = ""


## Lemma keys a bulk action would mark known: "easy" = easy words not yet marked,
## "all" = every remaining unmarked word (new + easy) of this text.
func bulk_keys(which: String) -> Array:
	var out: Array = []
	for k in lemmas.keys():
		var st: String = word_status(k)
		if st == "easy" or (which == "all" and st == "new"):
			out.append(k)
	return out


func mark_bulk_known(which: String) -> int:
	var keys: Array = bulk_keys(which)
	var n: int = Store.set_known(lang, keys, true)
	Store.save_progress()
	_confirm_bulk = ""
	_refresh_sets()
	_render_header()
	_render_text()
	_render_panel()
	if n > 0:
		Toast.ok("%d개를 아는 단어로 표시했어요." % n)
	return n


# ---------------------------------------------------------------- reader: text

func build_bbcode() -> String:
	var acc: Color = _accent()
	var new_bg: String = _hex(_new_bg())
	var sel_bg: String = _hex(acc)
	var learn_bg: String = _hex(LEARN_BG)
	var learn_fg: String = _hex(LEARN_FG)
	# Japanese has no spaces: two tinted words in a row alternate between two shades so
	# they do not melt into one block (朝 + ごはん).
	var new_bg2: String = _hex(acc.lerp(Color.WHITE, 0.7))
	var learn_bg2: String = _hex(LEARN_BG.darkened(0.08))
	var parts := PackedStringArray()
	var prev_tint: String = "" # tint of the directly preceding token ("" if none)
	for i in tokens.size():
		var tk: Dictionary = tokens[i]
		var t: String = UI.bb_escape(str(tk["t"]))
		if not bool(tk.get("w", false)):
			parts.append(t)
			prev_tint = ""
			continue
		var key := lemma_key(str(tk.get("lemma", "")))
		var inner: String = t
		var tint: String = ""
		if i == selected:
			inner = "[bgcolor=%s][color=#ffffff]%s[/color][/bgcolor]" % [sel_bg, t]
			tint = sel_bg
		else:
			match word_status(key):
				"new":
					tint = new_bg2 if prev_tint == new_bg else new_bg
					inner = "[bgcolor=%s]%s[/bgcolor]" % [tint, t]
				"learning":
					tint = learn_bg2 if prev_tint == learn_bg else learn_bg
					inner = "[bgcolor=%s][color=%s][u]%s[/u][/color][/bgcolor]" % [tint, learn_fg, t]
		prev_tint = tint
		parts.append("[url=%d]%s[/url]" % [i, inner])
	return "".join(parts)


func _render_text() -> void:
	UI.clear(_text_state)
	_text_card.visible = not tokens.is_empty()
	if analyzing:
		var box := UI.card("Card", 10)
		box.body.add_child(UI.label("글을 분석하는 중…", "Strong"))
		box.body.add_child(UI.label("단어마다 원형과 난이도를 찾고 있어요. 긴 글은 몇 초 걸릴 수 있어요.", "Muted"))
		var bar := ProgressBar.new()
		bar.indeterminate = true
		bar.show_percentage = false
		bar.custom_minimum_size = Vector2(0, 6)
		bar.add_theme_stylebox_override("fill", UI.style(_accent(), Color(0, 0, 0, 0), 0, 99, 0, 0))
		box.body.add_child(bar)
		_text_state.add_child(box)
	elif analyze_error != "" and tokens.is_empty():
		var p := UI.tinted_panel(Pal.BAD_SOFT, Color(0, 0, 0, 0), 0, 10, 16, 14)
		var v := UI.vbox(10)
		v.add_child(UI.colored(analyze_error, Pal.BAD))
		var row := UI.hbox(8)
		var retry := UI.button("다시 시도", "primary", _accent())
		retry.pressed.connect(_run_analyze)
		var back := UI.button("목록으로", "default")
		back.pressed.connect(back_to_library)
		row.add_child(retry)
		row.add_child(back)
		v.add_child(row)
		p.add_child(v)
		_text_state.add_child(p)
		# the text itself, unanalyzed, so the person still sees what they saved
		var raw := UI.label(str(doc.get("text", "")), "")
		if lang == "ja":
			raw.add_theme_font_override("font", UI.ja_font())
		_text_state.add_child(raw)
	_text_state.visible = _text_state.get_child_count() > 0
	if tokens.is_empty():
		_rtl.text = ""
		return
	var fs: int = int(FONT_SIZES[_font_key()])
	_rtl.add_theme_font_size_override("normal_font_size", fs)
	_rtl.add_theme_font_size_override("bold_font_size", fs)
	if lang == "ja":
		_rtl.add_theme_font_override("normal_font", UI.ja_font(false))
		_rtl.add_theme_font_override("bold_font", UI.ja_font(true))
		_rtl.add_theme_constant_override("line_separation", int(fs * 0.6))
	else:
		_rtl.remove_theme_font_override("normal_font")
		_rtl.remove_theme_font_override("bold_font")
		_rtl.add_theme_constant_override("line_separation", int(fs * 0.45))
	var sv: int = _text_scroll.scroll_vertical
	_rtl.text = build_bbcode()
	_text_scroll.scroll_vertical = sv


## RichTextLabel meta click: `meta` is the token index.
func on_meta_clicked(meta: Variant) -> void:
	var s: String = str(meta)
	if not s.is_valid_int():
		return
	select_token(int(s))


func select_token(i: int) -> void:
	var w: Dictionary = word_at(i)
	if w.is_empty():
		return
	selected = i
	_confirm_bulk = ""
	_render_text()
	_render_panel(true)
	_apply_layout()
	if _narrow:
		_scroll_to_selected()
	if auto_fetch:
		var key: String = w["key"]
		if gloss_for(key).is_empty() and not gloss_pending.has("%s|%s" % [lang, key]):
			_request_glosses([key], false)
		_fetch_examples(key)


## Bottom sheet: keep the clicked word visible above the sheet.
func _scroll_to_selected() -> void:
	if not is_inside_tree():
		return
	await get_tree().process_frame
	await get_tree().process_frame
	if selected < 0 or not is_instance_valid(_rtl):
		return
	var ch := 0
	for k in selected:
		ch += str((tokens[k] as Dictionary)["t"]).length()
	var line: int = _rtl.get_character_line(ch)
	if line < 0:
		return
	var y: float = _rtl.get_line_offset(line) + _rtl.global_position.y - _text_scroll.get_child(0).global_position.y
	var view_h: float = _text_scroll.size.y
	var top: float = float(_text_scroll.scroll_vertical)
	if y < top + 20.0 or y > top + view_h - 60.0:
		_text_scroll.scroll_vertical = int(maxf(0.0, y - view_h * 0.35))


func close_panel() -> void:
	selected = -1
	_render_text()
	_render_panel(true)
	_apply_layout()


func selected_word() -> Dictionary:
	return word_at(selected)


# ---------------------------------------------------------------- reader: word panel

func _render_panel(reset_scroll: bool = false) -> void:
	var sv: int = 0 if reset_scroll else _panel_scroll.scroll_vertical
	UI.clear(_panel_body)
	if selected < 0 or word_at(selected).is_empty():
		_render_panel_empty()
	else:
		_render_panel_word()
	UI.fix_cjk(_panel_body)
	if is_inside_tree():
		await get_tree().process_frame
		if is_instance_valid(_panel_scroll):
			_panel_scroll.scroll_vertical = sv


func _render_panel_empty() -> void:
	_panel_body.add_child(UI.label("단어", "Eyebrow", false))
	if tokens.is_empty():
		_panel_body.add_child(UI.label("글을 분석하면 단어를 눌러 볼 수 있어요.", "Muted"))
		return
	_panel_body.add_child(UI.label("글에서 단어를 눌러 보세요", "H3"))
	_panel_body.add_child(UI.label("뜻·발음·예문이 여기에 나와요. 모르는 단어는 '복습에 추가', 이미 아는 단어는 '아는 단어'로 표시하면 다음 글부터 색이 바뀌어요.", "Muted"))
	var tip := UI.tinted_panel(Pal.SUNK, Color(0, 0, 0, 0), 0, 10, 14, 10)
	tip.add_child(UI.label("색이 칠해진 단어는 자주 쓰이지 않는 단어(모르는 단어 후보)예요. 색이 없는 쉬운 단어도 눌러서 뜻을 볼 수 있어요.", "Small"))
	_panel_body.add_child(tip)


func _render_panel_word() -> void:
	var acc: Color = _accent()
	var w: Dictionary = selected_word()
	var key: String = w["key"]
	var st: String = word_status(key)
	var gl: Dictionary = gloss_for(key)

	var top := UI.hbox(8)
	var lem := UI.label(str(w["lemma"]), "", true)
	lem.add_theme_font_size_override("font_size", 28)
	lem.add_theme_font_override("font", UI.bold_font())
	top.add_child(lem)
	var close := UI.link_button("✕", "닫기")
	close.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	close.pressed.connect(close_panel)
	top.add_child(close)
	_panel_body.add_child(top)
	if lemma_key(str(w["surface"])) != key:
		_panel_body.add_child(UI.colored("본문에서는 %s" % str(w["surface"]), Pal.MUTED, "Small"))
	var chips := UI.flow(6, 6)
	var st_bg: Color = _new_bg() if st == "new" else (LEARN_BG if st == "learning" else (Pal.OK_SOFT if st == "known" else Pal.SUNK))
	var st_fg: Color = acc if st == "new" else (LEARN_FG if st == "learning" else (Pal.OK if st == "known" else Pal.MUTED))
	chips.add_child(UI.chip(STATUS_KO[st], st_fg, st_bg))
	if st != "easy":
		chips.add_child(UI.chip(LEVEL_KO.get(str(w["level"]), "단어"), Pal.MUTED, Pal.SUNK))
	if str(gl.get("pos", "")) != "":
		chips.add_child(UI.chip(str(gl["pos"]), Pal.MUTED, Pal.SUNK))
	_panel_body.add_child(chips)
	var sp := UI.flow(2, 0)
	var ipa: String = str(gl.get("ipa", ""))
	if lang == "en" and ipa != "" and not (ipa.begins_with("/") or ipa.begins_with("[")):
		ipa = "/%s/" % ipa
	if ipa != "":
		var il := UI.label(ipa, "", false)
		il.add_theme_font_size_override("font_size", 17)
		il.add_theme_color_override("font_color", Pal.MUTED)
		il.add_theme_font_override("font", UI.ja_font() if lang == "ja" else Ipa.font())
		il.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		sp.add_child(il)
		var gap := Control.new()
		gap.custom_minimum_size = Vector2(6, 0)
		sp.add_child(gap)
	var b1 := UI.link_button("▶ 듣기")
	b1.pressed.connect(func() -> void: Tts.speak(str(w["lemma"]), lang, false))
	var b2 := UI.link_button("천천히")
	b2.pressed.connect(func() -> void: Tts.speak(str(w["lemma"]), lang, true))
	var b3 := UI.link_button("문장 듣기")
	b3.pressed.connect(func() -> void: Tts.speak(str(w["sentence"]), lang, false))
	sp.add_child(b1)
	sp.add_child(b2)
	sp.add_child(b3)
	_panel_body.add_child(sp)

	# meaning
	var mean := UI.tinted_panel(Pal.soft(lang), Color(0, 0, 0, 0), 0, 10, 14, 12)
	var mv := UI.vbox(4)
	mean.add_child(mv)
	if str(gl.get("ko", "")) != "":
		var ko := UI.label(str(gl["ko"]), "")
		ko.add_theme_font_size_override("font_size", 20)
		ko.add_theme_font_override("font", UI.bold_font())
		mv.add_child(ko)
		if str(gl.get("note", "")) != "":
			mv.add_child(UI.label(str(gl["note"]), "Small"))
	elif gloss_pending.has("%s|%s" % [lang, key]):
		mv.add_child(UI.colored("뜻 불러오는 중…", Pal.MUTED, ""))
	else:
		mv.add_child(UI.colored("아직 뜻을 불러오지 않았어요.", Pal.MUTED, "Small"))
		var load_btn := UI.button("뜻 불러오기", "soft", acc)
		load_btn.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
		load_btn.pressed.connect(func() -> void: _request_glosses([key], false))
		mv.add_child(load_btn)
	_panel_body.add_child(mean)

	# actions (side by side in the bottom sheet so they stay above the fold)
	var act: BoxContainer = UI.hbox(8) if _narrow else UI.vbox(6)
	if st == "learning":
		var inrv := UI.button("✓ 복습 목록에 있어요", "soft", LEARN_FG, 44)
		inrv.disabled = true
		act.add_child(inrv)
	else:
		var add := UI.button("복습에 추가", "primary", acc, 44)
		add.pressed.connect(add_selected_to_review)
		act.add_child(add)
	if st != "known":
		var kn := UI.button("아는 단어", "outline", Pal.OK, 40)
		kn.tooltip_text = "이 단어는 앞으로 색 없이 보여요"
		kn.pressed.connect(mark_selected_known)
		act.add_child(kn)
	else:
		var un := UI.button("모르는 단어로 되돌리기", "outline", acc, 40)
		un.pressed.connect(unmark_selected)
		act.add_child(un)
	if _narrow:
		for b in act.get_children():
			(b as Control).size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_panel_body.add_child(act)

	# the sentence it appeared in
	_panel_body.add_child(UI.label("이 글의 문장", "Eyebrow", false))
	var sent := UI.rich(_sentence_bbcode(int(w["s"])), 16)
	sent.add_theme_color_override("default_color", Pal.INK)
	sent.add_theme_constant_override("line_separation", 4)
	if lang == "ja":
		sent.add_theme_font_override("normal_font", UI.ja_font(false))
		sent.add_theme_font_override("bold_font", UI.ja_font(true))
	_panel_body.add_child(sent)

	_panel_body.add_child(UI.hline())
	_panel_body.add_child(_examples_box(w))


## The sentence of token `selected` with the word highlighted.
func _sentence_bbcode(s: int) -> String:
	var parts := PackedStringArray()
	var started := false
	for i in tokens.size():
		var tk: Dictionary = tokens[i]
		if int(tk.get("s", -1)) != s:
			continue
		var t: String = str(tk["t"])
		if not started:
			t = t.lstrip(" \t\n")
			if t == "":
				continue
			started = true
		t = UI.bb_escape(t.replace("\n", " "))
		if i == selected:
			parts.append("[b][color=%s]%s[/color][/b]" % [_hex(_accent()), t])
		else:
			parts.append(t)
	return "".join(parts).strip_edges()


func _examples_box(w: Dictionary) -> Control:
	var box := UI.vbox(10)
	box.add_child(UI.label("예문", "Eyebrow", false))
	var ek: String = "%s|%s" % [lang, w["key"]]
	if not examples.has(ek):
		if examples_pending.has(ek):
			box.add_child(UI.colored("예문 찾는 중…", Pal.MUTED, "Small"))
		elif auto_fetch:
			var btn := UI.link_button("예문 찾기")
			btn.pressed.connect(func() -> void: _fetch_examples(str(w["key"])))
			box.add_child(btn)
		return box
	var data: Dictionary = examples[ek]
	if data.has("error"):
		box.add_child(UI.colored(str(data["error"]), Pal.BAD, "Small"))
		var retry := UI.link_button("다시 찾기")
		retry.pressed.connect(func() -> void:
			examples.erase(ek)
			_fetch_examples(str(w["key"])))
		box.add_child(retry)
		return box
	var list: Array = data.get("examples", []) if data.get("examples", []) is Array else []
	var shown := 0
	for e in list:
		if not (e is Dictionary) or str((e as Dictionary).get("text", "")).strip_edges() == "":
			continue
		var ed: Dictionary = e
		var text: String = str(ed["text"])
		var item := UI.vbox(2)
		var row := UI.hbox(4)
		var r := UI.rich(_highlight(text, w), 16)
		r.add_theme_color_override("default_color", Pal.INK)
		if lang == "ja":
			r.add_theme_font_override("normal_font", UI.ja_font(false))
			r.add_theme_font_override("bold_font", UI.ja_font(true))
		row.add_child(r)
		var play := UI.link_button("▶", "듣기")
		play.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
		play.pressed.connect(func() -> void: Tts.speak(text, lang, false))
		row.add_child(play)
		item.add_child(row)
		var tr: String = str(ed.get("ko", ""))
		if tr == "":
			tr = str(ed.get("en", "")) if lang == "ja" else str(ed.get("ja", ""))
			if tr == "":
				tr = str(ed.get("en", "")) + str(ed.get("ja", ""))
		if tr != "":
			item.add_child(UI.colored(tr, Pal.MUTED, "Small"))
		box.add_child(item)
		shown += 1
		if shown >= 3:
			break
	if shown == 0:
		box.add_child(UI.colored("이 단어가 들어간 Tatoeba 예문이 없어요.", Pal.MUTED, "Small"))
	var attr: String = str(data.get("attribution", ""))
	if attr == "":
		attr = "예문 출처: Tatoeba (tatoeba.org) · CC BY 2.0 FR"
	var al := UI.colored(attr, Pal.MUTED, "Small")
	al.add_theme_font_size_override("font_size", 12)
	box.add_child(al)
	return box


## Escapes `text` for BBCode and bolds the forms of the selected word in it.
func _highlight(text: String, w: Dictionary) -> String:
	var acc: String = _hex(_accent())
	var rx := RegEx.new()
	if lang == "en":
		var stem: String = str(w["lemma"])
		var surf: String = str(w["surface"])
		var alts := PackedStringArray()
		for s in [stem, surf]:
			var clean: String = str(s).strip_edges()
			if clean != "" and RegEx.create_from_string("^[A-Za-z' -]+$").search(clean) != null:
				alts.append(clean.replace("'", "\\'"))
		if alts.is_empty():
			return UI.bb_escape(text)
		rx.compile("(?i)\\b(%s)\\w*" % "|".join(alts))
	else:
		var cands := PackedStringArray()
		for s in [str(w["surface"]), str(w["lemma"])]:
			if s != "" and text.find(s) >= 0:
				cands.append(s)
		if cands.is_empty():
			# 食べる → 食べ: try the lemma without its last kana (conjugated forms)
			var l: String = str(w["lemma"])
			if l.length() >= 2 and text.find(l.left(l.length() - 1)) >= 0:
				cands.append(l.left(l.length() - 1))
		if cands.is_empty():
			return UI.bb_escape(text)
		var esc := PackedStringArray()
		for c in cands:
			var e := ""
			for ch in c:
				e += "\\x{%x}" % ch.unicode_at(0)
			esc.append(e)
		rx.compile("(%s)" % "|".join(esc))
	var out := ""
	var pos := 0
	for m in rx.search_all(text):
		out += UI.bb_escape(text.substr(pos, m.get_start() - pos))
		out += "[b][color=%s]%s[/color][/b]" % [acc, UI.bb_escape(m.get_string())]
		pos = m.get_end()
	out += UI.bb_escape(text.substr(pos))
	return out


# ---------------------------------------------------------------- word actions

func add_selected_to_review() -> int:
	var w: Dictionary = selected_word()
	if w.is_empty():
		return 0
	var gl: Dictionary = gloss_for(w["key"])
	var item := {
		"lang": lang,
		"target": str(w["lemma"]),
		"reading": str(gl.get("ipa", "")) if lang == "ja" else "",
		"ko": str(gl.get("ko", "")),
		"note": str(w["sentence"]),
	}
	var n: int = Store.add_review([item])
	Store.set_known(lang, [w["key"]], false)
	Store.save_progress()
	if n > 0:
		Toast.ok("복습 목록에 넣었어요: %s" % str(w["lemma"]))
	else:
		Toast.info("이미 복습 목록에 있어요.")
	_after_status_change()
	return n


func mark_selected_known() -> void:
	var w: Dictionary = selected_word()
	if w.is_empty():
		return
	Store.set_known(lang, [w["key"]], true)
	Store.save_progress()
	_after_status_change()


func unmark_selected() -> void:
	var w: Dictionary = selected_word()
	if w.is_empty():
		return
	Store.set_known(lang, [w["key"]], false)
	Store.save_progress()
	_after_status_change()


func _after_status_change() -> void:
	_refresh_sets()
	_render_header()
	_render_text()
	_render_panel()


# ---------------------------------------------------------------- glosses

func _start_gloss_batch() -> void:
	if not auto_fetch:
		return
	var want: Array = []
	for k in lemmas.keys():
		if word_status(k) == "new" and gloss_for(k).is_empty() and not gloss_pending.has("%s|%s" % [lang, k]):
			want.append(k)
	if want.is_empty():
		return
	_request_glosses(want, true)


## Requests meanings for `keys` (chunks of GLOSS_CHUNK, one after another).
## `batch` = the background request after analysis (drives the "뜻 불러오는 중…" counter).
func _request_glosses(keys: Array, batch: bool) -> void:
	var l: String = lang
	var serial: int = _doc_serial
	for k in keys:
		gloss_pending["%s|%s" % [l, k]] = true
	if batch:
		gloss_total = keys.size()
		gloss_done = 0
		_update_gloss_label()
	else:
		_render_panel()
	var i := 0
	while i < keys.size():
		var chunk: Array = keys.slice(i, i + GLOSS_CHUNK)
		i += GLOSS_CHUNK
		var items: Array = []
		for k in chunk:
			var info: Dictionary = lemmas.get(k, {})
			items.append({"lemma": str(info.get("lemma", k)), "sentence": sentence_text(int(info.get("s", 0)))})
		var req = Api.post_json("/reading/gloss", {"lang": l, "items": items}, Api.TIMEOUT_LLM, false)
		var res: Dictionary = await req.wait()
		for k in chunk:
			gloss_pending.erase("%s|%s" % [l, k])
		if not is_inside_tree():
			return
		var ok: bool = res["ok"] and res["data"] is Dictionary
		if ok:
			apply_glosses(res["data"], l)
		if serial != _doc_serial:
			# another text was opened meanwhile: the cache keeps what arrived, stop asking
			for k in keys.slice(i):
				gloss_pending.erase("%s|%s" % [l, k])
			return
		if batch:
			gloss_done = mini(gloss_total, gloss_done + chunk.size())
			_update_gloss_label()
		if not ok:
			if not res.get("cancelled", false):
				Toast.error(error_text(res))
			for k in keys.slice(i):
				gloss_pending.erase("%s|%s" % [l, k])
			if batch:
				gloss_total = 0
				_update_gloss_label()
			_render_panel()
			return
	if batch:
		gloss_total = 0
		_update_gloss_label()
	_render_panel()


## Merges a /reading/gloss response into the per-language cache (and saves it).
func apply_glosses(data: Variant, l: String = "") -> int:
	if l == "":
		l = lang
	if not (data is Dictionary) or not ((data as Dictionary).get("glosses", null) is Array):
		return 0
	if not glosses.has(l):
		glosses[l] = _load_json(storage_dir.path_join("glosses_%s.json" % l), {})
	var cache: Dictionary = glosses[l]
	var n := 0
	for g in (data as Dictionary)["glosses"]:
		if not (g is Dictionary):
			continue
		var gd: Dictionary = g
		var lem: String = str(gd.get("lemma", "")).strip_edges()
		if lem == "" or str(gd.get("ko", "")).strip_edges() == "":
			continue
		var key: String = lem.to_lower() if l == "en" else lem
		cache[key] = {"lemma": lem, "pos": str(gd.get("pos", "")), "ko": str(gd.get("ko", "")).strip_edges(), "ipa": str(gd.get("ipa", "")).strip_edges(), "note": str(gd.get("note", "")).strip_edges()}
		_backfill_review(l, lem, cache[key])
		n += 1
	if n > 0:
		_ensure_dirs()
		_save_json(storage_dir.path_join("glosses_%s.json" % l), cache)
		if mode == "reader" and l == lang:
			var w: Dictionary = selected_word()
			if not w.is_empty() and cache.has(w["key"]):
				_render_panel()
	return n


## A word added to review before its meaning arrived gets the meaning now.
func _backfill_review(l: String, lemma: String, g: Dictionary) -> void:
	var changed := false
	for r in Store.review_for(l):
		var rd: Dictionary = r
		if str(rd["target"]) == lemma and str(rd["ko"]) == "":
			rd["ko"] = str(g["ko"])
			if l == "ja" and str(rd["reading"]) == "":
				rd["reading"] = str(g["ipa"])
			changed = true
	if changed:
		Store.save_progress()


# ---------------------------------------------------------------- examples

func _fetch_examples(key: String) -> void:
	var l: String = lang
	var ek: String = "%s|%s" % [l, key]
	if examples.has(ek) or examples_pending.has(ek) or not auto_fetch:
		return
	examples_pending[ek] = true
	var lem: String = str((lemmas.get(key, {}) as Dictionary).get("lemma", key))
	var req = Api.get_json("/examples?lang=%s&q=%s&limit=5" % [l, lem.uri_encode()], Api.TIMEOUT_SHORT, false)
	var res: Dictionary = await req.wait()
	examples_pending.erase(ek)
	if not is_inside_tree():
		return
	if res["ok"] and res["data"] is Dictionary:
		examples[ek] = res["data"]
	elif not res.get("cancelled", false):
		examples[ek] = {"error": error_text(res)}
	var w: Dictionary = selected_word()
	if mode == "reader" and l == lang and not w.is_empty() and w["key"] == key:
		_render_panel()


## Test hook: puts a /examples response into the cache for `key` of the current language.
func set_examples(key: String, data: Dictionary) -> void:
	examples["%s|%s" % [lang, key]] = data
	var w: Dictionary = selected_word()
	if not w.is_empty() and w["key"] == key:
		_render_panel()
