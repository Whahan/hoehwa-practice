extends Node
## Gallery of the overlay / navigation parts for the eyes and for tools/shot_check.gd (W3-6): AppBar, PageHeader,
## ConnChip, BottomTabs, ToastHost (phone) / SideNav, PageHeader, ConnChip, ToastHost (PC), and a Sheet.
## Needs a real renderer (no --headless):
##   phone: godot --path <project> --resolution 412x915 --audio-driver Dummy res://tests/ui_gallery_nav.tscn -- <out dir> --phone [--dark]
##   PC:    godot --path <project> --resolution 1280x800 --audio-driver Dummy res://tests/ui_gallery_nav.tscn -- <out dir> [--dark]
## Writes <out>/nav_<phone|pc>_<light|dark>.png (the page) and <out>/sheets/nav_<...>_choice.png / _confirm.png.
## Reads and writes nothing of the app's own files.

var _out: String = ""


func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	_out = args[0] if args.size() > 0 and not args[0].begins_with("--") else "user://ui_gallery_nav"
	var dark: bool = args.has("--dark")
	var phone: bool = Platform.is_phone()
	DirAccess.make_dir_recursive_absolute(_out.path_join("sheets"))
	var want := Vector2i(412, 915) if phone else Vector2i(1280, 800)
	if Vector2i(get_window().size) != want:
		get_window().min_size = Vector2i.ZERO
		get_window().size = want
		await _frames(3)
	UiBoot.apply(get_window(), "dark" if dark else "light", 1.0)
	Sheet.animate = false
	var bg := ColorRect.new()
	bg.color = Pal.BG
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)
	var tag: String = "%s_%s" % ["phone" if phone else "pc", "dark" if dark else "light"]
	var toast: ToastHost = ToastHost.new()
	add_child(toast)
	if phone:
		_build_phone(bg, toast)
	else:
		_build_pc(bg, toast)
	await _frames(12)
	_save("nav_%s.png" % tag)
	var s := Sheet.choice(bg, "더보기", [["practice", "연습"], ["log", "기록"], ["roadmap", "로드맵"]], "log")
	await _frames(12)
	_save("sheets/nav_%s_choice.png" % tag)
	Sheet.close_top()
	await _frames(4)
	s = Sheet.confirm(bg, "기록 지우기", "이 기록을 지울까요? 지운 기록은 되돌릴 수 없어요.", "확인", true)
	await _frames(12)
	_save("sheets/nav_%s_confirm.png" % tag)
	Sheet.close_top()
	await _frames(3)
	get_tree().quit()


func _save(rel: String) -> void:
	var img: Image = get_viewport().get_texture().get_image()
	img.save_png(_out.path_join(rel))
	print("saved ", rel, " ", img.get_size())


func _tabs() -> Array:
	return [["today", "오늘"], ["lesson", "레슨"], ["talk", "원어민 대화"], ["practice", "연습"], ["reading", "읽기"], ["review", "복습"], ["log", "기록"], ["roadmap", "로드맵"]]


func _cards(col: VBoxContainer) -> void:
	for i in 4:
		var c := UI.card("Card", 8)
		c.body.add_child(UI.label("카드 %d" % (i + 1), "H3"))
		c.body.add_child(UI.label("내용이 들어가는 카드예요. 여러 줄로 길어지면 이렇게 줄바꿈이 돼요.", "Muted"))
		c.body.add_child(UI.button("시작", "primary", Pal.PRIMARY, 48.0))
		col.add_child(c)


func _build_phone(root: Control, toast: ToastHost) -> void:
	var v := VBoxContainer.new()
	v.set_anchors_preset(Control.PRESET_FULL_RECT)
	v.add_theme_constant_override("separation", 0)
	root.add_child(v)
	var bar := AppBar.new()
	v.add_child(bar)
	bar.set_top_inset(24.0)
	bar.set_page("레슨", true, [{"id": "settings", "text": "설정"}])
	var chip := ConnChip.new()
	chip.set_state("ok", "PC 연결됨")
	bar.set_chip(chip)
	var sc := ScrollContainer.new()
	sc.size_flags_vertical = Control.SIZE_EXPAND_FILL
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	v.add_child(sc)
	var col := VBoxContainer.new()
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.add_theme_constant_override("separation", 12)
	var m := UI.margin(col, 16, 0, 16, 16)
	m.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sc.add_child(m)
	var hdr := PageHeader.build("오늘", "2단계 · 5개월차 2주차")
	col.add_child(hdr)
	_cards(col)
	bar.bind_scroll(sc, hdr)
	var bt := BottomTabs.new()
	bt.set_tabs(_tabs(), {"talk": "대화"})
	bt.set_current("today")
	bt.set_badge("review", true)
	v.add_child(bt)
	toast.set_bottom_gap(12.0 + PhoneLayout.TAB_H)
	toast.show_message("저장했어요", "ok")


func _build_pc(root: Control, toast: ToastHost) -> void:
	var h := HBoxContainer.new()
	h.set_anchors_preset(Control.PRESET_FULL_RECT)
	h.add_theme_constant_override("separation", 0)
	root.add_child(h)
	var nav := SideNav.new()
	h.add_child(nav)
	nav.set_items([
		{"title": "학습", "items": [["today", "오늘"], ["lesson", "레슨"], ["talk", "원어민 대화"], ["practice", "연습"], ["reading", "읽기"], ["review", "복습"]]},
		{"title": "기록", "items": [["log", "기록"], ["roadmap", "로드맵"]]},
	])
	nav.set_current("lesson")
	var chip := ConnChip.new()
	chip.set_state("ok", "AI 엔진 준비됨")
	nav.set_footer(chip)
	nav.set_settings_visible(true)
	var content := VBoxContainer.new()
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.add_theme_constant_override("separation", 16)
	h.add_child(UI.margin(content, 0, 0, 0, 0))
	content.get_parent().size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.add_child(UI.margin(PageHeader.build("레슨", "오늘의 레슨", [{"id": "go", "text": "설정"}]), 32, 24, 32, 0))
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 16)
	content.add_child(UI.margin(col, 32, 0, 32, 0))
	_cards(col)
	toast.show_message("저장했어요", "ok")
