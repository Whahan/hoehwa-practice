class_name BadgeView
extends AppView
## 배지 화면(탭 키 "badges"): 받은 개수 + 진행 바, 분류 필터 칩, 타일 격자(폰 3열 / PC 5열), 타일을 누르면 시트. docs/v160_fun_design.md §4.4.
##
## 데이터는 직접 읽지 않는다. `provider`(BadgeEngine.ui_list 모양의 배열을 돌려주는 Callable)와 `on_seen`(새 배지를 봤다고 알리는
## Callable) 은 main.gd 가 꽂는다. 이 파일은 StudyLog / Store / BadgeEngine 을 부르지 않는다.
## 항목 = {id, name, desc, cat, glyph, got, at, retro, value, target, is_new}. 이름·id 가 비었거나 target <= 0 이거나 id 가 겹치는 항목은 건너뛴다.

const COLS_PHONE := 3
const COLS_WIDE := 5
const WIDE_MIN := 700.0
const NOTE_DEVICE := "일부 배지(가나·스피드·노래)는 이 기기의 기록으로 받아요."

static var provider: Callable = Callable()
static var on_seen: Callable = Callable()

var _scroll: PageScroll
var _grid: GridContainer = null
var _header: Control = null
var _filter: String = ""
var _items: Array = []
var _tiles: Dictionary = {}
var _visible: Array = []
var _chips: Array = []
var _sheet: Sheet = null


func _ready() -> void:
	_scroll = PageScroll.new(880.0)
	_scroll.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_scroll)
	_build()


## 탭이 보일 때: 목록을 다시 받아 그리고, 새 배지가 있었으면 on_seen 으로 "봤다"고 알린다(이 화면이 이번에 보여 주는 점은 그대로 남는다).
func refresh() -> void:
	if _scroll == null:
		return
	rebuild_keep_scroll(_scroll, _build)
	if _has_new() and on_seen.is_valid():
		on_seen.call()


func on_hide() -> void:
	if _sheet != null and is_instance_valid(_sheet):
		_sheet.close("dismiss")
	_sheet = null


func scroll_host() -> ScrollContainer:
	return _scroll


func header_block() -> Control:
	return _header if _header != null and is_instance_valid(_header) else null


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED and _grid != null and is_instance_valid(_grid):
		_grid.columns = _columns()


func _columns() -> int:
	return COLS_WIDE if size.x >= WIDE_MIN else COLS_PHONE


# ---------------------------------------------------------------- 시험·셸용 진입점

func tile(id: String) -> Control:
	var t: Variant = _tiles.get(id, null)
	return t if t is Control and is_instance_valid(t) else null


## 지금 필터로 보이는 id, 표 순서.
func visible_ids() -> Array:
	return _visible.duplicate()


## "" = 전체. 모르는 분류도 전체로 본다.
func set_filter(cat: String) -> void:
	var known := false
	for c in BadgeDefs.categories():
		if c[0] == cat:
			known = true
	_filter = cat if known else ""
	if _scroll != null:
		_build()


func filter() -> String:
	return _filter


func chips() -> Array:
	return _chips


func total_count() -> int:
	return _items.size()


func got_count() -> int:
	var n := 0
	for it in _items:
		if bool(it["got"]):
			n += 1
	return n


# ---------------------------------------------------------------- 데이터

## provider 가 준 값을 청소한 목록. 나쁜 항목은 버린다.
func _load_items() -> Array:
	var out: Array = []
	if not provider.is_valid():
		return out
	var raw: Variant = provider.call()
	if not (raw is Array):
		return out
	var seen_ids := {}
	for r in (raw as Array):
		if not (r is Dictionary):
			continue
		var d: Dictionary = r
		var id: String = str(d.get("id", ""))
		var nm: String = str(d.get("name", ""))
		var target: int = FunParts._i(d.get("target", 0))
		if id == "" or nm == "" or target <= 0 or seen_ids.has(id):
			continue
		seen_ids[id] = true
		var got: bool = FunParts._b(d.get("got", false))
		out.append({
			"id": id, "name": nm, "desc": str(d.get("desc", "")), "cat": str(d.get("cat", "")),
			"glyph": str(d.get("glyph", "star")), "got": got, "at": d.get("at", ""),
			"retro": got and FunParts._b(d.get("retro", false)),
			"value": clampi(maxi(0, FunParts._i(d.get("value", 0))), 0, target), "target": target,
			"is_new": got and FunParts._b(d.get("is_new", false)),
		})
	return out


func _has_new() -> bool:
	for it in _items:
		if bool(it["is_new"]):
			return true
	return false


# ---------------------------------------------------------------- 그리기

func _build() -> void:
	if _scroll == null:
		return
	var c: VBoxContainer = _scroll.content
	UI.clear(c)
	_grid = null
	_tiles.clear()
	_visible.clear()
	_chips.clear()
	_items = _load_items()
	_header = PageHeader.build("배지")
	c.add_child(_header)

	var got: int = got_count()
	var total: int = _items.size()
	var head := UI.vbox(8)
	var sum := UI.label("%d개 중 %d개 받았어요" % [total, got] if total > 0 else "표시할 배지가 아직 없어요", "Strong")
	head.add_child(sum)
	if total > 0:
		head.add_child(UI.progress_bar(float(got) / float(total), Pal.REWARD, 10.0))
	c.add_child(head)
	set_meta("summary", sum.text)

	var fl := UI.flow(8, 8)
	fl.add_child(_chip("전체", ""))
	for cat in BadgeDefs.categories():
		fl.add_child(_chip(str(cat[1]), str(cat[0])))
	c.add_child(fl)

	_grid = GridContainer.new()
	_grid.columns = _columns()
	_grid.add_theme_constant_override("h_separation", Ds.S2 if Platform.is_phone() else Ds.S3)
	_grid.add_theme_constant_override("v_separation", Ds.S2 if Platform.is_phone() else Ds.S3)
	_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for it in _items:
		if _filter != "" and str(it["cat"]) != _filter:
			continue
		var d: Dictionary = it
		var t: Button = FunParts.badge_tile(d, func() -> void: _open_sheet(str(d["id"])))
		t.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_grid.add_child(t)
		_tiles[d["id"]] = t
		_visible.append(d["id"])
	c.add_child(_grid)
	if _visible.is_empty() and total > 0:
		c.add_child(UI.label("이 분류에는 배지가 없어요", "Muted"))
	c.add_child(UI.label(NOTE_DEVICE, "Small"))
	UI.fix_cjk(c)
	bar_changed.emit()


func _chip(text: String, cat: String) -> Button:
	var b: Button = UI.filter_chip(text, _filter == cat, func() -> void: set_filter(cat))
	b.set_meta("cat", cat)
	_chips.append(b)
	return b


# ---------------------------------------------------------------- 상세 시트

func _open_sheet(id: String) -> void:
	var info: Dictionary = {}
	for it in _items:
		if it["id"] == id:
			info = it
	if info.is_empty():
		return
	var got: bool = bool(info["got"])
	var body := UI.vbox(12)
	var mid := CenterContainer.new()
	var gk: String = str(info["glyph"])
	if not got:
		gk = "lock"
	elif not GlyphIcon.KINDS.has(gk):
		gk = "star"
	mid.add_child(GlyphIcon.new(gk, 64.0, Pal.REWARD if got else Pal.MUTED))
	body.add_child(mid)
	if str(info["desc"]) != "":
		body.add_child(UI.label(str(info["desc"]), "Muted"))
	if got:
		var when: String = FunParts._md(info["at"])
		body.add_child(UI.label("받은 날 %s" % (when if when != "" else "-"), "Strong"))
		if bool(info["retro"]):
			body.add_child(UI.label("예전 기록으로 받았어요", "Small"))
	else:
		body.add_child(UI.label("진행 " + FunParts.progress_text(info), "Strong"))
		body.add_child(UI.progress_bar(float(info["value"]) / float(info["target"]), Pal.REWARD, 10.0))
	UI.fix_cjk(body)
	_sheet = Sheet.open(self, str(info["name"]), body, [{"id": "close", "text": "닫기", "kind": "soft"}])
	if _sheet.title_label != null:
		FunParts.fit_name(_sheet.title_label, str(info["name"]), 3) # 제목도 공백에서만 줄을 바꾼다
	_sheet.closed.connect(func(_r: Variant) -> void: _sheet = null)
