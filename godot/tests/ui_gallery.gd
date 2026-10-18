extends Node
## Gallery of the basic UI parts (docs/ui_redesign_design.md §6.1 #3-#7, #10): list group + section header, buttons,
## chips, inputs, switches and checks, progress bars. For looking at them, not a test.
##   interactive:  godot --path <project> res://tests/ui_gallery.tscn -- [--phone] [--dark] [--font-scale=1.5]
##   PNG:          godot --path <project> --audio-driver Dummy res://tests/ui_gallery.tscn -- <out dir> [--phone] [--dark]
## With an out dir the whole page (not only the first screen) is rendered into one PNG,
## <out dir>/gallery_<phone|pc>_<light|dark>[_f150].png, and the program quits. Needs a real renderer (no --headless).
## Sections (scene names for the eye check): "묶음(ListGroup)", "버튼", "칩", "입력", "스위치·체크", "진행".
## Prefs written by the switches go to the test guard folder (this scene lives in res://tests/).

const PREFS := "user://test_ui_gallery_prefs.json"

var _out_dir: String = ""
var _old_prefs: String = ""


func _ready() -> void:
	var scheme := "light"
	var scale := 1.0
	for a in OS.get_cmdline_user_args():
		if a == "--dark":
			scheme = "dark"
		elif a.begins_with("--font-scale="):
			scale = float(a.substr(13))
		elif not a.begins_with("--") and _out_dir == "":
			_out_dir = a
	var phone: bool = Platform.is_phone()
	var win := Vector2i(412, 915) if phone else Vector2i(1280, 800)
	get_window().min_size = Vector2i.ZERO
	get_window().size = win
	_old_prefs = Store.prefs_path
	Store.prefs_path = PREFS
	UiBoot.apply(get_window(), scheme, scale)
	if phone:
		PhoneLayout.install_touch_scroll(get_tree())
	await get_tree().process_frame
	if _out_dir == "":
		_interactive(win)
		return
	await _shoot(win, scheme, scale)
	Store.prefs_path = _old_prefs
	get_tree().quit()


func _bg(parent: Node) -> void:
	var bg := ColorRect.new()
	bg.color = Pal.BG
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	parent.add_child(bg)


func _interactive(win: Vector2i) -> void:
	_bg(self)
	var host := Control.new()
	host.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(host)
	var ps := PageScroll.new(720.0)
	ps.set_anchors_preset(Control.PRESET_FULL_RECT)
	host.add_child(ps)
	_fill(ps.content)


func _shoot(win: Vector2i, scheme: String, scale: float) -> void:
	var svp := SubViewport.new()
	svp.size = Vector2i(win.x, 2000)
	svp.transparent_bg = false
	svp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(svp)
	_bg(svp)
	var col := ColumnBox.new()
	col.max_width = 720.0
	svp.add_child(col)
	col.position = Vector2.ZERO
	col.size = Vector2(win.x, 100)
	_fill(col.content)
	for i in 4:
		await get_tree().process_frame
	var h: int = clampi(int(ceil(col.get_combined_minimum_size().y)) + 8, 200, 8000)
	svp.size = Vector2i(win.x, h)
	col.size = Vector2(win.x, h)
	for i in 4:
		await get_tree().process_frame
	var img: Image = svp.get_texture().get_image()
	DirAccess.make_dir_recursive_absolute(_out_dir)
	var name := "gallery_%s_%s%s.png" % ["phone" if Platform.is_phone() else "pc", scheme, "" if is_equal_approx(scale, 1.0) else "_f%d" % int(round(scale * 100.0))]
	var path := _out_dir.path_join(name)
	var err := img.save_png(path)
	print("GALLERY %s err=%d size=%s" % [name, err, str(img.get_size())])


func _fill(c: VBoxContainer) -> void:
	c.add_child(UI.label("부품 모음", "LargeTitle" if Platform.is_phone() else "H1"))
	c.add_child(UI.label("기본 부품을 한 화면에서 확인해요.", "Muted"))

	c.add_child(UI.section_header("묶음 (ListGroup)"))
	var g := ListGroup.new()
	c.add_child(g)
	g.add_row("주 글만 있는 행")
	g.add_row("부연이 있는 행", "두 번째 줄에 설명이 들어가요.")
	g.add_value_row("값이 있는 행", "영어", func() -> void: pass)
	g.add_row("위험한 동작 행", "", null, func() -> void: pass, true)
	g.add_switch_row("스위치 행", "켜고 끌 수 있어요.", "auto_speak")
	g.add_check_row("체크 행", true, func(_on: bool) -> void: pass)

	c.add_child(UI.section_header("버튼"))
	var cb := UI.card("Card", 12)
	c.add_child(cb)
	var row := UI.flow(8, 8)
	cb.add(row)
	row.add_child(UI.button("채움 primary", "primary", Pal.PRIMARY))
	row.add_child(UI.button("영어 primary", "primary", Pal.EN))
	row.add_child(UI.button("일본어 primary", "primary", Pal.JA))
	row.add_child(UI.button("soft", "soft", Pal.PRIMARY))
	row.add_child(UI.button("outline", "outline", Pal.OK))
	row.add_child(UI.button("flat", "flat", Pal.PRIMARY))
	row.add_child(UI.button("danger", "danger"))
	var dis := UI.button("disabled", "primary", Pal.PRIMARY)
	dis.disabled = true
	row.add_child(dis)
	row.add_child(UI.button("default"))
	row.add_child(UI.link_button("▶ 듣기"))
	cb.add(UI.option_row("선택지 하나 (option_row)"))
	cb.add(UI.lang_segmented("en", func(_v: String) -> void: pass))

	c.add_child(UI.section_header("칩"))
	var cc := UI.card("Card", 12)
	c.add_child(cc)
	var chips := UI.flow(8, 8)
	cc.add(chips)
	for k in ["ok", "bad", "warn", "info", "lang_en", "lang_ja", "neutral"]:
		chips.add_child(UI.chip_kind(k, k))
	var fchips := UI.flow(8, 8)
	cc.add(fchips)
	fchips.add_child(UI.filter_chip("선택 안 됨", false, Callable()))
	fchips.add_child(UI.filter_chip("선택됨", true, Callable()))
	fchips.add_child(UI.filter_chip("또 하나", false, Callable()))

	c.add_child(UI.section_header("입력"))
	var ci := UI.card("Card", 12)
	c.add_child(ci)
	var le := LineEdit.new()
	le.placeholder_text = "이름을 입력하세요"
	ci.add(UI.field("입력칸", le))
	var le2 := LineEdit.new()
	le2.text = "입력된 글"
	ci.add(UI.field("글이 있는 입력칸", le2))
	ci.add(UI.field("선택 목록", UI.option_button(["하나", "둘", "셋"], 0)))

	c.add_child(UI.section_header("스위치·체크"))
	var cs := UI.card("Card", 4)
	c.add_child(cs)
	cs.add(UI.pref_switch("pref_switch (스위치)", "auto_speak"))
	cs.add(UI.switch_row("switch_row (꺼짐)", false, func(_on: bool) -> void: pass, "부연 한 줄"))
	cs.add(UI.switch_row("switch_row (켜짐)", true, func(_on: bool) -> void: pass))
	cs.add(UI.pref_toggle("pref_toggle (체크박스)", "auto_speak"))
	cs.add(UI.check_row("check_row 켜짐", true, func(_on: bool) -> void: pass))
	cs.add(UI.check_row("check_row 꺼짐", false, func(_on: bool) -> void: pass, "부연 한 줄"))

	c.add_child(UI.section_header("진행"))
	var cp := UI.card("Card", 10)
	c.add_child(cp)
	cp.add(UI.progress_bar(0.0, Pal.PRIMARY))
	cp.add(UI.progress_bar(0.35, Pal.EN))
	cp.add(UI.progress_bar(0.7, Pal.OK))
	cp.add(UI.progress_bar(1.0, Pal.JA))
	var pr := UI.progress_indeterminate(Pal.PRIMARY)
	pr.indeterminate = false # a still picture
	pr.value = 0.5
	cp.add(pr)
	cp.add(UI.label("3 / 5 완료", "Small"))

	c.add_child(UI.gap(24))
	UI.fix_cjk(c)
