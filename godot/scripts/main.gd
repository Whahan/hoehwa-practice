extends Control
## Main scene: top tab bar, the six views, toast, backend splash and banner.

const TABS := [
	["today", "오늘"],
	["lesson", "레슨"],
	["talk", "원어민 대화"],
	["reading", "읽기"],
	["review", "복습"],
	["roadmap", "로드맵"],
]

var views: Dictionary = {}
var tab_buttons: Dictionary = {}
var current: String = ""

var _content: Control
var _banner: PanelContainer
var _banner_label: Label
var _banner_btn: Button
var _status_dot: PanelContainer
var _status_text: Label

var _toast_box: PanelContainer
var _toast_label: Label
var _toast_tween: Tween

var _splash_layer: CanvasLayer
var _splash_title: Label
var _splash_msg: Label
var _splash_bar: ProgressBar
var _splash_retry: Button
var _splash_dismissed: bool = false


func _setup_window() -> void:
	var win := get_window()
	var sc: float = DisplayServer.screen_get_scale()
	if sc > 1.01 and not OS.has_feature("editor"):
		# High-DPI screens: scale the UI and the window together.
		win.content_scale_factor = sc
		var usable: Rect2i = DisplayServer.screen_get_usable_rect()
		var target := Vector2i(int(1280.0 * sc), int(800.0 * sc))
		win.size = Vector2i(mini(target.x, usable.size.x), mini(target.y, usable.size.y))
		win.min_size = Vector2i(int(900.0 * sc), int(600.0 * sc))
		win.move_to_center()
	else:
		win.min_size = Vector2i(900, 600)


func _ready() -> void:
	_setup_window()
	set_anchors_preset(Control.PRESET_FULL_RECT)

	var bg := ColorRect.new()
	bg.color = Pal.BG
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	var root := VBoxContainer.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_theme_constant_override("separation", 0)
	add_child(root)

	root.add_child(_build_top_bar())
	_banner = _build_banner()
	root.add_child(_banner)

	_content = Control.new()
	_content.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_content.clip_contents = true
	root.add_child(_content)

	views = {
		"today": TodayView.new(),
		"lesson": LessonView.new(),
		"talk": TalkView.new(),
		"reading": ReadingView.new(),
		"review": ReviewView.new(),
		"roadmap": RoadmapView.new(),
	}
	for k in views.keys():
		var v: AppView = views[k]
		v.visible = false
		_content.add_child(v)

	_build_toast()
	_build_splash()

	Toast.message.connect(_show_toast)
	Store.navigate.connect(_on_navigate)
	Backend.status_changed.connect(_on_backend_status)

	show_view("today")
	_on_backend_status()
	Backend.start()


# ---------------------------------------------------------------- top bar

func _build_top_bar() -> Control:
	var bar := PanelContainer.new()
	bar.add_theme_stylebox_override("panel", UI.style(Pal.BG, Pal.LINE, 0, 0, 0, 0))
	var line_box := VBoxContainer.new()
	line_box.add_theme_constant_override("separation", 0)
	bar.add_child(line_box)
	var m := MarginContainer.new()
	m.add_theme_constant_override("margin_left", 20)
	m.add_theme_constant_override("margin_right", 20)
	m.add_theme_constant_override("margin_top", 8)
	m.add_theme_constant_override("margin_bottom", 0)
	line_box.add_child(m)
	var row := UI.hbox(4)
	m.add_child(row)

	var title := Label.new()
	title.text = "회화 연습"
	title.theme_type_variation = &"H3"
	title.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(title)
	row.add_child(UI.gap(0))
	var sp := Control.new()
	sp.custom_minimum_size = Vector2(18, 0)
	row.add_child(sp)

	for t in TABS:
		var b := Button.new()
		b.text = t[1]
		b.focus_mode = Control.FOCUS_NONE
		b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		var key: String = t[0]
		b.pressed.connect(func() -> void: show_view(key))
		tab_buttons[key] = b
		row.add_child(b)

	row.add_child(UI.spacer())
	_status_dot = UI.tinted_panel(Pal.MUTED, Color(0, 0, 0, 0), 0, 99, 0, 0)
	_status_dot.custom_minimum_size = Vector2(9, 9)
	_status_dot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(_status_dot)
	_status_text = UI.label("", "Small", false)
	_status_text.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(_status_text)

	var line := ColorRect.new()
	line.color = Pal.LINE
	line.custom_minimum_size = Vector2(0, 1)
	line_box.add_child(line)
	return bar


func _style_tabs() -> void:
	for k in tab_buttons.keys():
		var b: Button = tab_buttons[k]
		var sel: bool = k == current
		var sn := UI.style(Color(0, 0, 0, 0), Pal.INK if sel else Color(0, 0, 0, 0), 0, 0, 14, 10)
		sn.border_width_bottom = 3
		sn.content_margin_bottom = 9
		var sh := UI.style(Pal.SUNK if not sel else Color(0, 0, 0, 0), Pal.INK if sel else Color(0, 0, 0, 0), 0, 0, 14, 10)
		sh.border_width_bottom = 3
		sh.content_margin_bottom = 9
		for n in ["normal", "pressed", "focus", "disabled"]:
			b.add_theme_stylebox_override(n, sn)
		b.add_theme_stylebox_override("hover", sh)
		b.add_theme_stylebox_override("hover_pressed", sh)
		var col: Color = Pal.INK if sel else Pal.MUTED
		for n in ["font_color", "font_hover_color", "font_pressed_color", "font_hover_pressed_color", "font_focus_color"]:
			b.add_theme_color_override(n, col)
		if sel:
			b.add_theme_font_override("font", UI.bold_font())
		else:
			b.remove_theme_font_override("font")


func show_view(name: String) -> void:
	if not views.has(name):
		return
	if current != "" and views.has(current) and current != name:
		(views[current] as AppView).on_hide()
		(views[current] as AppView).visible = false
	current = name
	var v: AppView = views[name]
	v.visible = true
	v.refresh()
	_style_tabs()


func _on_navigate(view: String, lang: String) -> void:
	if lang == "en" or lang == "ja":
		Store.set_lang(lang)
	show_view(view)


# ---------------------------------------------------------------- banner / status

func _build_banner() -> PanelContainer:
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", UI.style(Pal.WARN_SOFT, Color("#E8D49A"), 0, 0, 20, 8))
	var row := UI.hbox(12)
	_banner_label = UI.colored("", Pal.WARN, "")
	row.add_child(_banner_label)
	_banner_btn = UI.button("다시 확인", "outline", Pal.WARN)
	_banner_btn.pressed.connect(func() -> void:
		if Backend.status == Backend.Status.READY:
			Backend.refresh_health()
		else:
			_splash_dismissed = false
			Backend.start())
	row.add_child(_banner_btn)
	p.add_child(row)
	p.visible = false
	return p


func _on_backend_status() -> void:
	var st: int = Backend.status
	var dot: Color = Pal.MUTED
	var text := ""
	match st:
		Backend.Status.READY:
			if Backend.llm_missing():
				dot = Pal.WARN
				text = "LLM 꺼짐"
			else:
				dot = Pal.OK
				text = "AI 엔진 준비됨"
		Backend.Status.FAILED:
			dot = Pal.BAD
			text = "AI 엔진 연결 안 됨"
		_:
			dot = Pal.WARN
			text = "AI 엔진 준비 중…"
	_status_dot.add_theme_stylebox_override("panel", UI.style(dot, Color(0, 0, 0, 0), 0, 99, 0, 0))
	_status_text.text = text

	# banner
	if st == Backend.Status.READY and Backend.llm_missing():
		_banner.visible = true
		_banner_label.text = Backend.llm_missing_text()
	elif st == Backend.Status.FAILED and _splash_dismissed:
		_banner.visible = true
		_banner_label.text = "AI 엔진에 연결되어 있지 않아요. " + Backend.message
	else:
		_banner.visible = false

	# splash
	if st == Backend.Status.READY:
		_splash_dismissed = true # a later disconnect shows the banner, never the full-screen splash
		_splash_layer.visible = false
	else:
		_splash_layer.visible = not _splash_dismissed
		var failed: bool = st == Backend.Status.FAILED
		_splash_title.text = "AI 엔진을 시작하지 못했어요" if failed else "AI 엔진 준비 중…"
		_splash_msg.text = Backend.message if Backend.message != "" else "처음에는 모델을 불러오느라 30초 정도 걸릴 수 있어요."
		_splash_bar.visible = not failed
		_splash_retry.visible = failed


# ---------------------------------------------------------------- splash

func _build_splash() -> void:
	_splash_layer = CanvasLayer.new()
	_splash_layer.layer = 20
	add_child(_splash_layer)
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_splash_layer.add_child(root)
	var bg := ColorRect.new()
	bg.color = Pal.BG
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_child(bg)
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_child(center)
	var card := UI.card("BigCard", 14)
	card.custom_minimum_size = Vector2(520, 0)
	center.add_child(card)
	card.body.add_child(UI.label("회화 연습", "Eyebrow", false))
	_splash_title = UI.label("AI 엔진 준비 중…", "H2")
	card.body.add_child(_splash_title)
	_splash_msg = UI.label("", "Muted")
	card.body.add_child(_splash_msg)
	_splash_bar = ProgressBar.new()
	_splash_bar.indeterminate = true
	_splash_bar.show_percentage = false
	_splash_bar.custom_minimum_size = Vector2(0, 8)
	_splash_bar.add_theme_stylebox_override("fill", UI.style(Pal.EN, Color(0, 0, 0, 0), 0, 99, 0, 0))
	card.body.add_child(_splash_bar)
	var row := UI.hbox(8)
	_splash_retry = UI.button("다시 시도", "primary", Pal.EN, 46)
	_splash_retry.pressed.connect(func() -> void: Backend.start())
	row.add_child(_splash_retry)
	var skip := UI.button("엔진 없이 계속", "default", Pal.INK, 46)
	skip.pressed.connect(func() -> void:
		_splash_dismissed = true
		_on_backend_status())
	row.add_child(skip)
	card.body.add_child(row)
	card.body.add_child(UI.label("엔진 없이도 로드맵과 진행 기록은 볼 수 있어요. 레슨·대화·음성은 엔진이 준비된 뒤에 써요.", "Small"))


# ---------------------------------------------------------------- toast

func _build_toast() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 30
	add_child(layer)
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(root)
	var v := VBoxContainer.new()
	v.set_anchors_preset(Control.PRESET_FULL_RECT)
	v.alignment = BoxContainer.ALIGNMENT_END
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(v)
	var h := HBoxContainer.new()
	h.alignment = BoxContainer.ALIGNMENT_CENTER
	h.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.add_child(h)
	v.add_child(UI.gap(28))
	_toast_box = PanelContainer.new()
	_toast_box.theme_type_variation = &"Toast"
	_toast_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_toast_box.visible = false
	_toast_label = Label.new()
	_toast_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_toast_label.custom_minimum_size = Vector2(420, 0)
	_toast_label.add_theme_color_override("font_color", Color.WHITE)
	_toast_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_toast_box.add_child(_toast_label)
	h.add_child(_toast_box)


func _show_toast(text: String, kind: String) -> void:
	_toast_label.text = text
	var bg: Color = Color("#222A38")
	if kind == "error":
		bg = Color("#8F2D2D")
	elif kind == "ok":
		bg = Color("#1D6B49")
	_toast_box.add_theme_stylebox_override("panel", UI.style(bg, Color(0, 0, 0, 0), 0, 10, 18, 12))
	_toast_box.visible = true
	_toast_box.modulate = Color(1, 1, 1, 0)
	if _toast_tween != null and _toast_tween.is_valid():
		_toast_tween.kill()
	_toast_tween = create_tween()
	_toast_tween.tween_property(_toast_box, "modulate:a", 1.0, 0.15)
	_toast_tween.tween_interval(6.0 if kind == "error" else 3.5)
	_toast_tween.tween_property(_toast_box, "modulate:a", 0.0, 0.4)
	_toast_tween.tween_callback(func() -> void: _toast_box.visible = false)


# ---------------------------------------------------------------- quit

func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		Backend.shutdown()
		get_tree().quit()
