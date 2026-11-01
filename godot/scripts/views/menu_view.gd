class_name MenuView
extends AppView
## 메뉴: the phone-only screen behind the 5th bottom tab (docs/home_menu_design.md §7.6, §9.7). A one-line "내 기록" card on top,
## then list groups of rows (the screens that are not in the bottom bar). It only draws and reports: main.gd decides
## which rows exist (`set_entries`) and what a row does (`entry_chosen`).
##
## Entries: [{"title": String, "items": [{"key": String, "title": String, "sub": String}]}]. A group without a title or
## without a valid item is not shown; an item without a key or a title is skipped. Anything that is not a Dictionary /
## Array in the right place is ignored (no error).

signal entry_chosen(key: String)

## The key `entry_chosen` carries when the summary card ("내 기록") is pressed.
const SUMMARY_KEY := "stats"

var _scroll: PageScroll
var _groups: Array = []
var _summary: String = ""
var _rows: Dictionary = {}      ## key -> the row control of the entry that is on the screen
var _row_order: Array = []      ## keys in the order they are on the screen
var _group_boxes: Array = []    ## the ListGroup of every group that is shown
var _summary_card: Control = null


func _ready() -> void:
	_scroll = PageScroll.new(720.0)
	_scroll.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_scroll)
	_build()


## Replaces the rows (see the class comment for the shape). Draws at once when the screen is in the tree.
func set_entries(groups: Array) -> void:
	_groups = groups.duplicate(true)
	_build()


## Text of the "내 기록" card; "" = no card.
func set_summary(text: String) -> void:
	_summary = text.strip_edges()
	_build()


func refresh() -> void:
	_build()


func page_title() -> String:
	return "" # the app bar shows the tab name "메뉴"


func scroll_host() -> ScrollContainer:
	return _scroll


# ---------------------------------------------------------------- what is on the screen (tests and the shell)

func group_count() -> int:
	return _group_boxes.size()


func row_count() -> int:
	return _row_order.size()


## Keys of the rows on the screen, top to bottom.
func entry_keys() -> Array:
	return _row_order.duplicate()


## The row control of `key` (null when there is none).
func row_control(key: String) -> Control:
	var c: Variant = _rows.get(key, null)
	return c as Control if c != null and is_instance_valid(c) else null


## The "내 기록" card, or null.
func summary_card() -> Control:
	return _summary_card if _summary_card != null and is_instance_valid(_summary_card) else null


## What a tap on the row of `key` does. A key that is not on the screen is ignored.
func choose(key: String) -> void:
	if _rows.has(key):
		entry_chosen.emit(key)


# ---------------------------------------------------------------- building

func _build() -> void:
	if _scroll == null:
		return
	var c: VBoxContainer = _scroll.content
	UI.clear(c)
	_rows = {}
	_row_order = []
	_group_boxes = []
	_summary_card = null
	if _summary != "":
		_summary_card = _make_summary()
		c.add_child(_summary_card)
	for g in _groups:
		if not (g is Dictionary):
			continue
		var title: String = _text((g as Dictionary).get("title", ""))
		var items: Array = _valid_items((g as Dictionary).get("items", []))
		if title == "" or items.is_empty():
			continue
		c.add_child(ListGroup.header(title, Ds.S4 if _group_boxes.is_empty() and _summary_card == null else Ds.S6))
		var box := ListGroup.new()
		for it in items:
			var key: String = str((it as Dictionary)["key"])
			var row: Control = box.add_row(str((it as Dictionary)["title"]), str((it as Dictionary)["sub"]), _chevron(), func() -> void: choose(key))
			if row == null:
				continue
			_rows[key] = row
			_row_order.append(key)
		c.add_child(box)
		_group_boxes.append(box)


func _valid_items(raw: Variant) -> Array:
	var out: Array = []
	if not (raw is Array):
		return out
	var seen := {}
	for it in raw:
		if not (it is Dictionary):
			continue
		var key: String = _text((it as Dictionary).get("key", ""))
		var title: String = _text((it as Dictionary).get("title", ""))
		if key == "" or title == "" or seen.has(key):
			continue
		seen[key] = true
		out.append({"key": key, "title": title, "sub": _text((it as Dictionary).get("sub", ""))})
	return out


static func _text(v: Variant) -> String:
	return (v as String).strip_edges() if v is String else ""


func _chevron() -> Control:
	var t := GlyphIcon.new("chevron_right", 20.0, Pal.MUTED)
	t.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	return t


## "내 기록": a list-group card of one row with the sparkle in front; the whole row opens 기록.
func _make_summary() -> Control:
	var box := ListGroup.new()
	var row: Control = box.add_row("내 기록", _summary, _chevron(), func() -> void: entry_chosen.emit(SUMMARY_KEY))
	if row != null:
		var content: Variant = row.get("content") # the padded box of the row (ListGroup's own row class)
		if content is Node and (content as Node).get_child_count() > 0 and (content as Node).get_child(0) is HBoxContainer:
			var h := (content as Node).get_child(0) as HBoxContainer
			var sp := GlyphIcon.new("sparkle", 24.0, Pal.REWARD)
			sp.size_flags_vertical = Control.SIZE_SHRINK_CENTER
			h.add_child(sp)
			h.move_child(sp, 0)
	return box
