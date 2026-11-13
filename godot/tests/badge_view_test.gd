extends Node
## 배지 화면(BadgeView)과 배지 타일(FunParts.badge_tile) 시험 (docs/v160_fun_design.md §6.5 B2-2, B2-3, B2-4, B2-7, B2-8, B2-11).
##   PC:   godot --headless --path godot res://tests/badge_view_test.tscn
##   폰:   godot --headless --path godot --resolution 412x915 res://tests/badge_view_test.tscn -- --phone [--font-scale=1.5] [--dark]
## 가짜 provider / on_seen 만 쓴다: StudyLog·Store·BadgeEngine 을 읽거나 쓰지 않고 파일도 쓰지 않는다. 서버 접속 없음.
## 검사기(겹침·크기 검사)는 일부러 망가뜨린 입력을 넣어 실제로 FAIL 하는지도 본다 ("selfcheck FAIL-as-expected" 줄).
## 마지막 줄: "== badge_view: N passed, M failed ==", 실패가 있으면 종료 코드 1.

var passed: int = 0
var failed: int = 0
var _phone: bool = false
var _scale: float = 1.0
var _dark: bool = false
var _fake: Array = []
var _seen_calls: int = 0
var _saved_provider: Callable
var _saved_on_seen: Callable

## 금지어는 조각으로 쪼개 둔다(이 파일 자체가 검색 규칙에 걸리지 않게).
const HEX_COLOR := "Color(" + "\"" + "#"
const NET_WORDS := ["HTTP" + "Request", "Ap" + "i.", "Rou" + "te.", "OS.shell" + "_open", "OS.request" + "_permission"]

## §5.5 표 순서의 23개: [id, 이름, 분류, 목표]
const DEFS := [
	["first_lesson", "첫 레슨", "learn", 1], ["lessons_10", "레슨 10번", "learn", 10], ["lessons_50", "레슨 50번", "learn", 50],
	["first_talk", "첫 원어민 대화", "speak", 1], ["cards_20", "복습 카드 20장", "learn", 20], ["reviews_100", "복습 100번", "learn", 100],
	["streak_3", "3일 연속", "habit", 3], ["streak_7", "7일 연속", "habit", 7], ["streak_30", "30일 연속", "habit", 30],
	["time_1h", "공부 1시간", "habit", 3600], ["time_10h", "공부 10시간", "habit", 36000],
	["mission_star3", "미션 별 3개", "speak", 1], ["mission_all_star3", "미션 8개 모두 별 3개", "speak", 8], ["pron_80", "발음 80점", "speak", 80],
	["song_first", "첫 가사 등록", "song", 1], ["song_done", "가사 한 곡 다 외움", "song", 1],
	["kana_hira", "히라가나 청음 마스터", "kana", 46], ["kana_kata", "가타카나 청음 마스터", "kana", 46], ["kana_all", "가나 전부 숙련", "kana", 208], ["kana_pairs", "헷갈리는 글자 극복", "kana", 20],
	["speed_first", "첫 스피드 퀴즈", "speed", 1], ["speed_combo_10", "콤보 10", "speed", 10], ["speed_score_500", "스피드 500점", "speed", 500],
]


func ok(cond: bool, name: String) -> void:
	if cond:
		passed += 1
		print("  PASS  ", name)
	else:
		failed += 1
		print("  FAIL  ", name)


## 검사기가 "나쁨"으로 판정해야 하는 입력: 나쁨으로 판정하면 통과로 센다.
func fails(verdict_is_bad: bool, name: String) -> void:
	if verdict_is_bad:
		passed += 1
		print("  PASS  selfcheck FAIL-as-expected: ", name)
	else:
		failed += 1
		print("  FAIL  selfcheck did NOT fail: ", name)


func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


func _size_window(want: Vector2i) -> void:
	if Vector2i(get_window().size) != want:
		get_window().min_size = Vector2i.ZERO
		get_window().size = want
		await _frames(3)


func _ready() -> void:
	_phone = Platform.is_phone()
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--font-scale=") and a.substr(13).is_valid_float():
			_scale = a.substr(13).to_float()
		elif a == "--dark":
			_dark = true
	print("== badge_view start (%s, scale %s%s) ==" % ["phone" if _phone else "pc", str(_scale), ", dark" if _dark else ""])
	_saved_provider = BadgeView.provider
	_saved_on_seen = BadgeView.on_seen
	Sheet.animate = false
	await _size_window(Vector2i(412, 915) if _phone else Vector2i(1280, 800))
	UiBoot.apply(get_window(), "dark" if _dark else "light", _scale)
	if _phone:
		PhoneLayout.install_touch_scroll(get_tree())
	await _frames(2)

	_selfchecks()
	await _test_grid_and_filter()
	await _test_sheet()
	await _test_new_dots()
	await _test_layout()
	await _test_garbage()
	_test_file_rules()

	BadgeView.provider = _saved_provider
	BadgeView.on_seen = _saved_on_seen
	print("== badge_view: %d passed, %d failed ==" % [passed, failed])
	get_tree().quit(1 if failed > 0 else 0)


# ---------------------------------------------------------------- fixtures / helpers

## 23개 가짜 배지: 앞 9개를 받은 것으로(날짜 11-02 ...), 새 배지(is_new)는 new_ids 에 든 것.
func _make_list(got_n: int, new_ids: Array = []) -> Array:
	var out: Array = []
	var i := 0
	for d in DEFS:
		var got: bool = i < got_n
		out.append({
			"id": d[0], "name": d[1], "desc": "%s 조건 설명" % d[1], "cat": d[2], "glyph": "star" if i % 2 == 0 else "sparkle",
			"got": got, "at": ("2026-11-%02d" % (i + 2)) if got else "", "retro": got and i == 0,
			"value": int(d[3]) if got else mini(3, int(d[3]) - 1), "target": int(d[3]), "is_new": got and new_ids.has(d[0]),
		})
		i += 1
	return out


func _install(list: Array) -> void:
	_fake = list
	_seen_calls = 0
	BadgeView.provider = func() -> Array: return _fake
	BadgeView.on_seen = func() -> void: _seen_calls += 1


func _make(sz: Vector2) -> Array:
	var holder := Control.new()
	holder.size = sz
	add_child(holder)
	var v := BadgeView.new()
	holder.add_child(v)
	v.size = sz
	await _frames(4)
	return [holder, v]


func _walk(node: Node, out: Array = []) -> Array:
	out.append(node)
	for ch in node.get_children():
		_walk(ch, out)
	return out


func _texts(node: Node) -> Array:
	var out: Array = []
	for n in _walk(node):
		if n is Label:
			out.append((n as Label).text)
		elif n is Button and (n as Button).text != "":
			out.append((n as Button).text)
	return out


func _any_text(node: Node, part: String) -> bool:
	for t in _texts(node):
		if part in str(t):
			return true
	return false


func _glyph_kinds(node: Node) -> Array:
	var out: Array = []
	for n in _walk(node):
		if n is GlyphIcon:
			out.append((n as GlyphIcon).kind)
	return out


func _has_dot(t: Node) -> bool:
	for n in _walk(t):
		if n is GlyphIcon and bool((n as GlyphIcon).get_meta("new_dot", false)):
			return true
	return false


## 오른쪽으로 삐져나온 Control 이름들(visible 만). 폭 w 기준.
func _sticks_out(root: Node, w: float) -> Array:
	var wide: Array = []
	for n in _walk(root):
		if n is Control and (n as Control).is_visible_in_tree() and (n as Control).get_global_rect().end.x > w + 1.5:
			wide.append("%s %.0f" % [n.get_class(), (n as Control).get_global_rect().end.x])
	return wide


func _sheet_node() -> Sheet:
	for n in get_tree().root.find_children("*", "Sheet", true, false):
		if is_instance_valid(n) and not (n as Sheet).is_closed():
			return n
	return null


# ---------------------------------------------------------------- selfchecks (검사기도 실패할 수 있어야 한다)

func _selfchecks() -> void:
	# 삐져나옴 검사기: 폭 200 칸에 폭 300 짜리 Control 을 넣으면 걸려야 한다
	var holder := Control.new()
	holder.position = Vector2.ZERO
	holder.size = Vector2(200, 100)
	add_child(holder)
	var wide := ColorRect.new()
	wide.size = Vector2(300, 20)
	holder.add_child(wide)
	fails(_sticks_out(holder, 200.0).size() > 0, "overflow checker flags a 300 px wide child in a 200 px parent")
	holder.queue_free()
	# 점 검사기: 점이 없는 일반 타일에서는 false
	var plain: Button = FunParts.badge_tile({"id": "x", "name": "이름", "got": true, "at": "2026-11-02", "target": 1, "value": 1, "is_new": false}, Callable())
	add_child(plain)
	fails(not _has_dot(plain), "dot checker finds no dot on a tile that is not new")
	plain.queue_free()
	# 가짜 목록 자체 점검: 23개, 분류별 개수가 설계(§5.5)와 같다
	var l: Array = _make_list(9)
	var cnt := {}
	for it in l:
		cnt[it["cat"]] = int(cnt.get(it["cat"], 0)) + 1
	ok(l.size() == 23 and cnt.get("speed", 0) == 3 and cnt.get("habit", 0) == 5 and cnt.get("learn", 0) == 5 and cnt.get("kana", 0) == 4 and cnt.get("song", 0) == 2 and cnt.get("speak", 0) == 4, "fixture: 23 badges, categories 5/5/4/2/4/3")


# ---------------------------------------------------------------- B2-2 격자와 필터

func _test_grid_and_filter() -> void:
	print("[grid and filter]")
	_install(_make_list(9))
	var sz := Vector2(412, 915) if _phone else Vector2(1280, 800)
	var made: Array = await _make(sz)
	var holder: Control = made[0]
	var v: BadgeView = made[1]
	var tiles: Array = v.find_children("*", "Button", true, false).filter(func(b: Node) -> bool: return (b as Button).has_meta("id"))
	ok(tiles.size() == 23, "23 tiles for 23 badges (got %d)" % tiles.size())
	ok(v.visible_ids().size() == 23 and v.visible_ids()[0] == "first_lesson" and v.visible_ids()[22] == "speed_score_500", "visible_ids in table order")
	ok(v.total_count() == 23 and v.got_count() == 9, "9 of 23 received")
	ok(_any_text(v, "23개 중 9개 받았어요"), "summary line '23개 중 9개 받았어요'")
	ok(v.tile("first_lesson") != null and v.tile("nope") == null, "tile(id) finds a tile, an unknown id gives null")
	var got_tile: Control = v.tile("first_lesson")
	var open_tile: Control = v.tile("kana_hira")
	ok(bool(got_tile.get_meta("got")) and not bool(open_tile.get_meta("got")), "received and open tiles are told apart (meta got)")
	ok(_any_text(got_tile, "11.02") and not _any_text(got_tile, "/"), "received tile: name + date '11.02', no progress text")
	ok(_any_text(got_tile, "첫 레슨"), "received tile shows its name")
	ok(_any_text(open_tile, "3/46") and _any_text(open_tile, "히라가나 청음 마스터"), "open tile: name + progress '3/46'")
	ok(_glyph_kinds(open_tile).has("lock") and not _glyph_kinds(got_tile).has("lock"), "open tile draws a lock, a received one does not")
	ok(_glyph_kinds(got_tile).has("star"), "received tile draws its badge glyph (star)")
	# 필터
	v.set_filter("speed")
	await _frames(3)
	ok(v.visible_ids() == ["speed_first", "speed_combo_10", "speed_score_500"], "filter 'speed' shows exactly the 3 speed badges: %s" % str(v.visible_ids()))
	ok(v.tile("first_lesson") == null and v.tile("speed_first") != null, "filter 'speed': other tiles are gone")
	v.set_filter("kana")
	await _frames(3)
	ok(v.visible_ids().size() == 4, "filter 'kana' shows 4")
	v.set_filter("")
	await _frames(3)
	ok(v.visible_ids().size() == 23, "back to '전체' shows 23 again")
	v.set_filter("zz")
	await _frames(3)
	ok(v.filter() == "" and v.visible_ids().size() == 23, "unknown filter counts as all")
	# 칩을 눌러서도 된다
	var speed_chip: Button = null
	for b in v.chips():
		if (b as Button).get_meta("cat") == "speed":
			speed_chip = b
	ok(speed_chip != null and speed_chip.text == "스피드", "filter chip '스피드' exists")
	speed_chip.pressed.emit()
	await _frames(3)
	ok(v.visible_ids().size() == 3 and v.filter() == "speed", "pressing the chip filters")
	ok(v.chips().size() == 7, "7 chips: 전체 + 6 categories")
	var cats_ok := true
	for b in v.chips():
		cats_ok = cats_ok and (b as Button).size.y >= 31.5
	ok(cats_ok, "chips are at least 32 px tall")
	ok(_any_text(v, "일부 배지") and _any_text(v, "이 기기의 기록"), "footer note: some badges come from this device's records")
	holder.queue_free()
	await _frames(2)


# ---------------------------------------------------------------- B2-3 시트

func _test_sheet() -> void:
	print("[sheet]")
	_install(_make_list(9))
	var sz := Vector2(412, 915) if _phone else Vector2(1280, 800)
	var made: Array = await _make(sz)
	var holder: Control = made[0]
	var v: BadgeView = made[1]
	ok(Sheet.depth() == 0, "no sheet before a tap")
	# 못 받은 배지
	(v.tile("kana_hira") as Button).pressed.emit()
	await _frames(4)
	ok(Sheet.is_open() and Sheet.depth() == 1, "tapping a tile opens a sheet")
	var sh: Sheet = _sheet_node()
	ok(sh != null and sh.title_label != null and sh.title_label.text == "히라가나 청음 마스터", "sheet title is the badge name")
	ok(sh != null and _any_text(sh, "히라가나 청음 마스터 조건 설명"), "sheet shows the description")
	ok(sh != null and _any_text(sh, "진행 3 / 46"), "open badge: sheet shows the progress '진행 3 / 46'")
	ok(sh != null and _glyph_kinds(sh).has("lock"), "open badge: big lock in the sheet")
	Sheet.close_top()
	await _frames(3)
	ok(Sheet.depth() == 0 and not Sheet.is_open(), "closing the sheet: depth 0")
	# 받은 배지 (소급)
	(v.tile("first_lesson") as Button).pressed.emit()
	await _frames(4)
	sh = _sheet_node()
	ok(sh != null and _any_text(sh, "받은 날 11.02") and _any_text(sh, "예전 기록으로 받았어요"), "received retro badge: date + '예전 기록으로 받았어요'")
	ok(sh != null and _glyph_kinds(sh).has("star"), "received badge: big star")
	Sheet.close_top()
	await _frames(3)
	# 받았지만 소급이 아닌 배지에는 소급 문구가 없다
	(v.tile("lessons_10") as Button).pressed.emit()
	await _frames(4)
	sh = _sheet_node()
	ok(sh != null and _any_text(sh, "받은 날 11.03") and not _any_text(sh, "예전 기록"), "non-retro badge: no 'old records' note")
	# 닫기 버튼
	if sh != null and sh.buttons.has("close"):
		(sh.buttons["close"] as Button).pressed.emit()
	await _frames(3)
	ok(Sheet.depth() == 0, "the close button closes the sheet")
	# 시트가 열린 채 화면이 숨겨지면 닫힌다
	(v.tile("speed_first") as Button).pressed.emit()
	await _frames(3)
	var was_open: bool = Sheet.is_open()
	v.on_hide()
	await _frames(3)
	ok(was_open and Sheet.depth() == 0, "on_hide() closes an open sheet")
	holder.queue_free()
	await _frames(2)


# ---------------------------------------------------------------- B2-4 새 배지 점

func _test_new_dots() -> void:
	print("[new badge dots]")
	_install(_make_list(9, ["streak_7", "streak_3"]))
	var sz := Vector2(412, 915) if _phone else Vector2(1280, 800)
	var made: Array = await _make(sz)
	var holder: Control = made[0]
	var v: BadgeView = made[1]
	ok(_has_dot(v.tile("streak_7")) and _has_dot(v.tile("streak_3")), "new badges carry a dot shape")
	ok(not _has_dot(v.tile("first_lesson")) and not _has_dot(v.tile("kana_hira")), "an old badge and an open badge have no dot")
	ok(_seen_calls == 0, "building the view does not call on_seen (only refresh does)")
	v.refresh()
	await _frames(5)
	ok(_seen_calls == 1, "refresh() with new badges calls on_seen exactly once (%d)" % _seen_calls)
	ok(_has_dot(v.tile("streak_7")), "the dot stays on screen for the visit that shows it")
	# 같은 화면을 다시 열면: provider 가 is_new 를 거짓으로 준다
	for it in _fake:
		it["is_new"] = false
	v.refresh()
	await _frames(5)
	ok(not _has_dot(v.tile("streak_7")) and not _has_dot(v.tile("streak_3")), "reopened: no dots when the provider says nothing is new")
	ok(_seen_calls == 1, "refresh() without new badges does not call on_seen again")
	# 필터를 바꿔도 on_seen 은 안 부른다
	v.set_filter("habit")
	await _frames(3)
	ok(_seen_calls == 1, "changing the filter does not call on_seen")
	ok(v.visible_ids().size() == 5, "habit filter: 5 badges")
	# on_seen 이 비어 있어도 에러 없이
	BadgeView.on_seen = Callable()
	_fake = _make_list(2, ["first_lesson"])
	v.refresh()
	await _frames(4)
	ok(is_instance_valid(v) and v.visible_ids().size() == 5 or v.visible_ids().size() == 23, "refresh() with an empty on_seen callable is harmless")
	holder.queue_free()
	await _frames(2)


# ---------------------------------------------------------------- B2-7 레이아웃

func _test_layout() -> void:
	print("[layout]")
	_install(_make_list(9, ["streak_7"]))
	var sz := Vector2(412, 915) if _phone else Vector2(1280, 800)
	var made: Array = await _make(sz)
	var holder: Control = made[0]
	var v: BadgeView = made[1]
	var want_cols: int = 3 if _phone else 5
	ok(v._grid != null and v._grid.columns == want_cols, "grid has %d columns here (got %d)" % [want_cols, v._grid.columns if v._grid != null else -1])
	var min_w: float = v._scroll.column.get_combined_minimum_size().x
	ok(min_w <= sz.x, "content minimum width %.0f <= %.0f" % [min_w, sz.x])
	var wide: Array = _sticks_out(v._scroll.content, sz.x)
	ok(wide.is_empty(), "nothing sticks out to the right of %.0f px %s" % [sz.x, str(wide.slice(0, 3))])
	var tiles: Array = v.find_children("*", "Button", true, false).filter(func(b: Node) -> bool: return (b as Button).has_meta("id"))
	var min_h := 9999.0
	var min_wid := 9999.0
	var max_right := 0.0
	for t in tiles:
		min_h = minf(min_h, (t as Button).size.y)
		min_wid = minf(min_wid, (t as Button).size.x)
		max_right = maxf(max_right, (t as Button).get_global_rect().end.x)
	ok(min_h >= 44.0, "every tile is at least 44 px tall (min %.1f)" % min_h)
	ok(max_right <= sz.x + 1.5, "tiles end inside the screen width (%.0f <= %.0f)" % [max_right, sz.x])
	if _phone:
		ok(min_wid >= 90.0, "phone: tiles are at least 90 px wide (min %.1f), so 3 columns, not 6" % min_wid)
	else:
		ok(min_wid >= 120.0, "PC: tiles are at least 120 px wide (min %.1f)" % min_wid)
	var rows := {}
	for t in tiles:
		rows[snappedf((t as Button).global_position.y, 1.0)] = true
	var first_row := 0
	var y0: float = (tiles[0] as Button).global_position.y
	for t in tiles:
		if absf((t as Button).global_position.y - y0) < 2.0:
			first_row += 1
	ok(first_row == want_cols, "first row has %d tiles (got %d)" % [want_cols, first_row])
	var bad_btn: Array = []
	for n in _walk(v):
		if n is Button and (n as Button).is_visible_in_tree() and (n as Button).size.y < 31.5:
			bad_btn.append("%s %.1f" % [(n as Button).text, (n as Button).size.y])
	ok(bad_btn.is_empty(), "no pressable thing under 32 px %s" % str(bad_btn.slice(0, 3)))
	if _phone:
		var small: Array = []
		for n in _walk(v):
			if n is Button and (n as Button).is_visible_in_tree() and (n as Button).size.y < 43.5:
				small.append("%s %.1f" % [(n as Button).text, (n as Button).size.y])
		ok(small.is_empty(), "phone: every button is at least 44 px tall %s" % str(small.slice(0, 3)))
	var tiny: Array = []
	for n in _walk(v):
		if n is Label and (n as Label).is_visible_in_tree() and (n as Label).get_theme_font_size("font_size") < 12:
			tiny.append((n as Label).text)
	ok(tiny.is_empty(), "no text under 12 px %s" % str(tiny.slice(0, 3)))
	# 크기를 바꾸면 열이 따라간다
	var other: Vector2 = Vector2(1280, 800) if _phone else Vector2(412, 915)
	holder.size = other
	v.size = other
	await _frames(4)
	var want2: int = 5 if other.x >= 700.0 else 3
	ok(v._grid.columns == want2, "after resizing to %dx%d the grid has %d columns (got %d)" % [other.x, other.y, want2, v._grid.columns])
	var wide2: Array = _sticks_out(v._scroll.content, other.x)
	ok(wide2.is_empty(), "after resizing nothing sticks out %s" % str(wide2.slice(0, 3)))
	holder.queue_free()
	await _frames(2)


# ---------------------------------------------------------------- B2-8 일부러 틀린 입력

func _test_garbage() -> void:
	print("[garbage input]")
	var sz := Vector2(412, 915) if _phone else Vector2(1280, 800)
	# provider 가 비어 있거나 이상한 값
	var cases: Array = [
		["empty array", []],
		["null", null],
		["a string", "x"],
		["a number", 5],
		["items are strings / null / numbers", ["a", null, 3, [1]]],
	]
	for c in cases:
		BadgeView.provider = func() -> Variant: return c[1]
		var made: Array = await _make(sz)
		var v: BadgeView = made[1]
		ok(is_instance_valid(v) and v.visible_ids().is_empty() and v.tile("a") == null, "provider gives %s: empty screen, no error" % c[0])
		ok(_any_text(v, "표시할 배지가 아직 없어요"), "provider gives %s: says there is nothing to show" % c[0])
		(made[0] as Control).queue_free()
		await _frames(2)
	# provider 가 비어 있는 Callable
	BadgeView.provider = Callable()
	var m0: Array = await _make(sz)
	ok(is_instance_valid(m0[1]) and (m0[1] as BadgeView).visible_ids().is_empty(), "an empty provider Callable: empty screen, no error")
	(m0[0] as Control).queue_free()
	await _frames(2)
	# 나쁜 항목은 건너뛰고 좋은 항목만 그린다
	var good: Dictionary = {"id": "g1", "name": "좋은 배지", "desc": "d", "cat": "habit", "glyph": "star", "got": true, "at": "2026-11-05", "retro": false, "value": 1, "target": 1, "is_new": false}
	var bad: Array = [
		{"id": "b_over", "name": "넘침", "cat": "habit", "got": false, "value": 50, "target": 10},
		{"id": "b_zero", "name": "나눗셈 0", "cat": "habit", "got": false, "value": 0, "target": 0},
		{"id": "b_noname", "name": "", "cat": "habit", "got": false, "value": 0, "target": 5},
		{"id": "", "name": "id 없음", "cat": "habit", "got": false, "value": 0, "target": 5},
		{"id": "g1", "name": "겹침", "cat": "habit", "got": false, "value": 0, "target": 5},
		{"id": "b_nan", "name": "NaN 값", "cat": "kana", "got": false, "value": NAN, "target": 5},
		{"id": "b_inf", "name": "INF 값", "cat": "kana", "got": false, "value": INF, "target": 5},
		{"id": "b_str", "name": "문자열 값", "cat": "kana", "got": false, "value": "x", "target": "y"},
		{"id": "b_neg", "name": "음수", "cat": "song", "got": false, "value": -4, "target": 5},
		{"id": "b_date", "name": "날짜 이상", "cat": "song", "got": true, "at": "xx", "value": 1, "target": 1},
		{"id": "b_nocat", "name": "분류 없음", "got": false, "value": 1, "target": 2},
		{"id": "b_glyph", "name": "도형 모름", "cat": "speed", "glyph": "zzz", "got": true, "at": "2026-11-01", "value": 1, "target": 1},
	]
	var mixed: Array = [good]
	mixed.append_array(bad)
	BadgeView.provider = func() -> Array: return mixed
	var made2: Array = await _make(sz)
	var v2: BadgeView = made2[1]
	var ids: Array = v2.visible_ids()
	ok(is_instance_valid(v2) and ids.has("g1") and ids.has("b_over") and ids.has("b_neg") and ids.has("b_date") and ids.has("b_glyph") and ids.has("b_nocat"), "bad items are cleaned or skipped: kept %s" % str(ids))
	ok(not ids.has("b_zero") and not ids.has("b_noname") and not ids.has("") and not ids.has("b_str"), "target 0 / no name / no id / text target are skipped")
	ok(ids.count("g1") == 1, "a duplicate id is shown once")
	var over: Control = v2.tile("b_over")
	ok(over != null and _any_text(over, "10/10") and not _any_text(over, "50"), "value above target is shown as target/target")
	ok(v2.tile("b_neg") != null and _any_text(v2.tile("b_neg"), "0/5"), "a negative value is shown as 0")
	ok(v2.tile("b_nan") != null and _any_text(v2.tile("b_nan"), "0/5") and _any_text(v2.tile("b_inf"), "0/5"), "NaN / INF values are shown as 0")
	ok(_glyph_kinds(v2.tile("b_glyph")).has("star"), "an unknown glyph name falls back to a star")
	ok(_any_text(v2, "%d개 중 %d개 받았어요" % [ids.size(), v2.got_count()]), "summary counts only the shown (valid) badges")
	(v2.tile("b_over") as Button).pressed.emit()
	await _frames(3)
	ok(Sheet.is_open(), "a cleaned item still opens its sheet")
	Sheet.close_top()
	await _frames(3)
	v2.set_filter("kana")
	await _frames(2)
	ok(v2.visible_ids() == ["b_nan", "b_inf"], "filter on the cleaned list works (kana: the 2 valid ones)")
	v2.set_filter("song")
	await _frames(2)
	v2.set_filter("")
	await _frames(2)
	(made2[0] as Control).queue_free()
	await _frames(2)
	# 타일 만드는 쪽에도 쓰레기를 넣는다
	var junk: Array = [null, {}, "x", 7, {"name": 5, "target": "a", "value": []}, {"id": "q", "name": "큐", "target": NAN, "value": NAN, "got": "yes"}]
	var all_built := true
	for j in junk:
		var t: Button = FunParts.badge_tile(j, Callable())
		add_child(t)
		all_built = all_built and t != null
		t.pressed.emit() # an empty on_tap Callable must not fail
		t.queue_free()
	await _frames(2)
	ok(all_built, "badge_tile builds from null / {} / strings / NaN without an error and pressing it with an empty callback is harmless")
	# 시트 전에 화면이 없어진 경우
	BadgeView.provider = func() -> Array: return _make_list(3)
	var v3 := BadgeView.new()
	v3.refresh()
	v3.on_hide()
	v3.free()
	ok(true, "refresh()/on_hide() before the view is in the tree are harmless")


func _test_file_rules() -> void:
	print("[file rules]")
	var paths := ["res://scripts/ui/fun_parts.gd", "res://scripts/views/badge_view.gd"]
	var bad_color := 0
	var bad_net := 0
	var bad_data := 0
	var bad_glyph := 0
	var emoji_rx := RegEx.new()
	emoji_rx.compile("[" + String.chr(0x2190) + "-" + String.chr(0x2bff) + String.chr(0x1F000) + "-" + String.chr(0x1FAFF) + "]")
	for p in paths:
		var f := FileAccess.open(p, FileAccess.READ)
		var raw: String = f.get_as_text()
		f.close()
		var t := ""
		for ln in raw.split("
"): # code only: a comment may name the classes it does not call
			t += ln.get_slice("#", 0) + "
"
		if HEX_COLOR in t:
			bad_color += 1
		for w in NET_WORDS:
			if w in t:
				bad_net += 1
		for w in ["StudyLog.", "Store.", "BadgeEngine"]:
			if w in t:
				bad_data += 1
		if emoji_rx.search(t) != null:
			bad_glyph += 1
	ok(bad_color == 0, "no Color(\"#...\") in the new files (Pal tokens only)")
	ok(bad_net == 0, "no network / permission calls in the new files")
	ok(bad_data == 0, "the new files do not call StudyLog / Store / BadgeEngine (data comes by provider, argument and callback)")
	ok(bad_glyph == 0, "no emoji or symbol characters in the new files")
	fails(emoji_rx.search("a " + String.chr(0x2605) + " b") != null and HEX_COLOR in ("x " + HEX_COLOR + "fff\")"), "file-rule scanner would catch a star character and a hex colour")
