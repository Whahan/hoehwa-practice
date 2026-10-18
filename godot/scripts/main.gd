extends Control
## Main scene: tab bar (top on the PC, bottom on the phone), the views, toast, backend splash and banner.
##
## Phone behaviour (Platform.is_phone(), docs/android_remote_design.md §5) is added next to the PC code;
## with `not Platform.is_phone()` every node and number is the same as before.
##
## Adding a tab (English v1.1: "연습", "기록"): `add_tab(key, label, view, short_label, after_key)` after _ready.
## `add_v11_tabs()` adds those two (and the StudyClock); _ready calls it only when this scene is the running scene
## of the app, so the layout tests that load main.tscn as a child still see the six original tabs.
## The PC top bar moves tabs that do not fit into a "더보기" menu, the phone bottom bar shows 6 cells and
## moves the rest into its "더보기" sheet (ui/bottom_tabs.gd). A view that has sub screens overrides
## AppView.go_back() so the Android back button can step out of them.

signal exit_requested

const TABS := [
	["today", "오늘"],
	["lesson", "레슨"],
	["talk", "원어민 대화"],
	["reading", "읽기"],
	["review", "복습"],
	["roadmap", "로드맵"],
]
## Shorter label of a tab in the phone bottom bar.
const TAB_SHORT := {"talk": "대화"}
const BACK_EXIT_MSEC := 2000
const MORE_TEXT := "더보기 ▾"

var views: Dictionary = {}
var tab_buttons: Dictionary = {}
var current: String = ""
var quit_on_exit: bool = true ## tests switch the real quit off

var _tabs: Array = TABS.duplicate(true)
var _tab_short: Dictionary = TAB_SHORT.duplicate()
var _phone: bool = false

var _root: VBoxContainer
var _top_row: HBoxContainer
var _top_more: Button
var _top_more_menu: PopupMenu
var _top_hidden: Array = []
var _top_pad: Control
var _bottom_tabs: BottomTabs
var _content: Control
var _banner: PanelContainer
var _banner_label: Label
var _banner_btn: Button
var _status_dot: PanelContainer
var _status_text: Label
var _link_dot: PanelContainer
var _link_text: Label
var _link_shown: bool = false
var _link_prev: bool = false
var _lan_probed: bool = false
var _lan_probe_on: bool = false

var _toast_box: PanelContainer
var _toast_label: Label
var _toast_gap: Control
var _toast_tween: Tween

var _splash_layer: CanvasLayer
var _splash_card: CardBox
var _splash_title: Label
var _splash_msg: Label
var _splash_bar: ProgressBar
var _splash_retry: Button
var _splash_find: Button
var _splash_note: Label
var _splash_dismissed: bool = false

var _connect_layer: CanvasLayer
var _connect_pad: MarginContainer
var _connect_view: Control
var _connect_dismissed: bool = false

var _last_kb: float = -1.0
var _last_insets: Dictionary = {}
var _last_back_msec: int = -100000


func _setup_window() -> void:
	if Platform.is_phone():
		return # the phone window is the screen; stretch settings come from the project (android)
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
	_phone = Platform.is_phone()
	if _phone:
		PhoneLayout.apply_theme(ThemeDB.get_project_theme())
		PhoneLayout.install_touch_scroll(get_tree()) # a drag that starts on a card / button scrolls the page
	_setup_window()
	set_anchors_preset(Control.PRESET_FULL_RECT)

	var bg := ColorRect.new()
	bg.color = Pal.BG
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	_root = VBoxContainer.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.add_theme_constant_override("separation", 0)
	add_child(_root)

	_root.add_child(_build_phone_top_bar() if _phone else _build_top_bar())
	_banner = _build_banner()
	_root.add_child(_banner)

	_content = Control.new()
	_content.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_content.clip_contents = true
	_root.add_child(_content)

	if _phone:
		_bottom_tabs = BottomTabs.new()
		_bottom_tabs.set_tabs(_tabs, _tab_short)
		_bottom_tabs.tab_selected.connect(show_view)
		_root.add_child(_bottom_tabs)

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
	if get_tree().current_scene == self:
		add_v11_tabs()
		add_sync()

	Toast.message.connect(_show_toast)
	Store.navigate.connect(_on_navigate)
	Backend.status_changed.connect(_on_backend_status)
	if _phone:
		(views["today"] as TodayView).connect_requested.connect(_open_connect_view)
		get_viewport().gui_focus_changed.connect(_on_focus_changed)
		_update_phone_chrome()

	show_view("today")
	_on_backend_status()
	Backend.start()


## Adds a tab behind the existing ones, or right after the tab `after_key` when that one exists.
## `short_label` is the phone bottom-bar text.
func add_tab(key: String, label: String, view: AppView, short_label: String = "", after_key: String = "") -> void:
	if views.has(key) or view == null:
		return
	var at: int = -1
	if after_key != "":
		for i in _tabs.size():
			if str((_tabs[i] as Array)[0]) == after_key:
				at = i + 1
	if at < 0:
		_tabs.append([key, label])
	else:
		_tabs.insert(at, [key, label])
	if short_label != "":
		_tab_short[key] = short_label
	views[key] = view
	view.visible = false
	_content.add_child(view)
	if _phone:
		_bottom_tabs.set_tabs(_tabs, _tab_short)
		_bottom_tabs.set_current(current)
	else:
		var idx: int = _top_more.get_index()
		if at >= 0 and tab_buttons.has(after_key):
			idx = (tab_buttons[after_key] as Button).get_index() + 1
		_add_top_button(key, label, idx)
		_style_tabs()
		_layout_top_tabs()


## English v1.1: 연습 after 대화, 기록 after 복습, and the study clock (StudyLog writer).
func add_v11_tabs() -> void:
	if views.has("practice"):
		return
	add_child(StudyClock.new())
	add_tab("practice", "연습", PracticeView.new(), "연습", "talk")
	add_tab("stats", "기록", StatsView.new(), "기록", "review")


## 1.2: learning-record sync (timers, app lifecycle, first-connection dialog). Like the StudyClock it is only added when this
## scene is the running scene, so the layout tests that load main.tscn as a child never get one.
func add_sync() -> void:
	if SyncManager.current == null:
		add_child(SyncManager.new())


## Keys of the tabs in the order of the tab bar.
func tab_keys() -> Array:
	var out: Array = []
	for t in _tabs:
		out.append(str((t as Array)[0]))
	return out


# ---------------------------------------------------------------- top bar (PC)

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
	_top_row = row
	row.resized.connect(_layout_top_tabs)
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

	for t in _tabs:
		_add_top_button(str(t[0]), str(t[1]), -1)

	# overflow menu for 7+ tabs: hidden (and out of the layout) while every tab fits
	_top_more = Button.new()
	_top_more.text = MORE_TEXT
	_top_more.focus_mode = Control.FOCUS_NONE
	_top_more.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	_top_more.visible = false
	_top_more.pressed.connect(_open_top_more)
	row.add_child(_top_more)
	_top_more_menu = PopupMenu.new()
	_top_more_menu.id_pressed.connect(func(id: int) -> void:
		if id >= 0 and id < _top_hidden.size():
			show_view(str(_top_hidden[id])))
	add_child(_top_more_menu)

	row.add_child(UI.spacer())
	# "폰 연결 켜짐" (the PC lets a phone in): hidden unless the settings card or /lan says so
	_link_dot = UI.tinted_panel(Pal.OK, Color(0, 0, 0, 0), 0, 99, 0, 0)
	_link_dot.custom_minimum_size = Vector2(9, 9)
	_link_dot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_link_dot.visible = false
	row.add_child(_link_dot)
	_link_text = UI.label("폰 연결 켜짐", "Small", false)
	_link_text.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_link_text.visible = false
	row.add_child(_link_text)
	var lgap := Control.new()
	lgap.custom_minimum_size = Vector2(10, 0)
	lgap.visible = false
	lgap.name = "LinkGap"
	row.add_child(lgap)
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


func _add_top_button(key: String, label: String, index: int) -> void:
	var b := Button.new()
	b.text = label
	b.focus_mode = Control.FOCUS_NONE
	b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	b.pressed.connect(func() -> void: show_view(key))
	tab_buttons[key] = b
	_top_row.add_child(b)
	if index >= 0:
		_top_row.move_child(b, index)


func _style_top_button(b: Button, sel: bool) -> void:
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


func _style_tabs() -> void:
	if _phone:
		_bottom_tabs.set_current(current)
		return
	for k in tab_buttons.keys():
		_style_top_button(tab_buttons[k] as Button, k == current)
	if _top_more != null:
		_style_top_button(_top_more, _top_hidden.has(current))


## Hides the tabs that do not fit into the top row and offers them in the "더보기" menu.
func _layout_top_tabs() -> void:
	if _phone or _top_row == null or _top_more == null:
		return
	var avail: float = size.x - 40.0 # window width minus the bar's 20 px margins (the row itself grows with its content)
	if avail <= 40.0:
		return
	var sep: float = float(_top_row.get_theme_constant("separation"))
	var fixed := 0.0
	var fixed_n := 0
	for c in _top_row.get_children():
		var ctl := c as Control
		if ctl == null or tab_buttons.values().has(ctl) or ctl == _top_more:
			continue
		if ctl.visible:
			fixed_n += 1
			if not (ctl.size_flags_horizontal & Control.SIZE_EXPAND):
				fixed += ctl.get_combined_minimum_size().x
	var keys: Array = tab_keys()
	var widths: Array = []
	for k in keys:
		widths.append((tab_buttons[k] as Button).get_combined_minimum_size().x)
	var more_w: float = _top_more.get_combined_minimum_size().x
	var shown: int = keys.size()
	while shown > 1:
		var n: int = fixed_n + shown + (1 if shown < keys.size() else 0)
		var need: float = fixed + sep * float(n - 1)
		for i in shown:
			need += float(widths[i])
		if shown < keys.size():
			need += more_w
		if need <= avail:
			break
		shown -= 1
	_top_hidden = []
	for i in keys.size():
		var b: Button = tab_buttons[keys[i]]
		var show: bool = i < shown
		if b.visible != show:
			b.visible = show
		if not show:
			_top_hidden.append(keys[i])
	var more_vis: bool = shown < keys.size()
	if _top_more.visible != more_vis:
		_top_more.visible = more_vis
	_style_tabs()


func _open_top_more() -> void:
	_top_more_menu.clear()
	for i in _top_hidden.size():
		_top_more_menu.add_item(_tab_label(str(_top_hidden[i])), i)
	var r := Rect2i(Vector2i(_top_more.global_position) + Vector2i(0, int(_top_more.size.y)), Vector2i(int(_top_more.size.x), 0))
	_top_more_menu.popup_on_parent(r)


func _tab_label(key: String) -> String:
	for t in _tabs:
		if str((t as Array)[0]) == key:
			return str((t as Array)[1])
	return key


# ---------------------------------------------------------------- top strip (phone)

func _build_phone_top_bar() -> Control:
	var bar := PanelContainer.new()
	bar.add_theme_stylebox_override("panel", UI.style(Pal.BG, Pal.LINE, 0, 0, 0, 0))
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 0)
	bar.add_child(col)
	_top_pad = UI.gap(0) # status bar / notch inset
	col.add_child(_top_pad)
	var m := MarginContainer.new()
	m.add_theme_constant_override("margin_left", PhoneLayout.PAD)
	m.add_theme_constant_override("margin_right", PhoneLayout.PAD)
	m.add_theme_constant_override("margin_top", 0)
	m.add_theme_constant_override("margin_bottom", 0)
	m.custom_minimum_size = Vector2(0, PhoneLayout.TOP_H)
	m.mouse_filter = Control.MOUSE_FILTER_STOP
	m.gui_input.connect(func(ev: InputEvent) -> void:
		if ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_LEFT:
			_open_settings())
	col.add_child(m)
	var row := UI.hbox(8)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	m.add_child(row)
	var title := Label.new()
	title.text = "회화 연습"
	title.theme_type_variation = &"H3"
	title.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(title)
	row.add_child(UI.spacer())
	_status_dot = UI.tinted_panel(Pal.MUTED, Color(0, 0, 0, 0), 0, 99, 0, 0)
	_status_dot.custom_minimum_size = Vector2(10, 10)
	_status_dot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_status_dot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(_status_dot)
	_status_text = UI.label("", "Small", false)
	_status_text.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(_status_text)
	var line := ColorRect.new()
	line.color = Pal.LINE
	line.custom_minimum_size = Vector2(0, 1)
	col.add_child(line)
	return bar


## Tapping the strip opens the settings (connection card) on the 오늘 tab.
func _open_settings() -> void:
	show_view("today")
	(views["today"] as TodayView).open_settings()


func show_view(name: String) -> void:
	if not views.has(name):
		return
	if _phone and _bottom_tabs != null:
		_bottom_tabs.close_more()
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
	p.add_theme_stylebox_override("panel", UI.style(Pal.WARN_SOFT, Color("#E8D49A"), 0, 0, 16 if _phone else 20, 10 if _phone else 8))
	var row := UI.adaptive(12)
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
				text = "PC 연결됨" if _phone else "AI 엔진 준비됨"
		Backend.Status.FAILED:
			dot = Pal.BAD
			text = "PC 연결 안 됨" if _phone else "AI 엔진 연결 안 됨"
		Backend.Status.NEEDS_PAIRING:
			dot = Pal.WARN
			text = "연결 필요" if _phone else "AI 엔진 준비 중…"
		_:
			dot = Pal.WARN
			text = "PC 연결 중…" if _phone else "AI 엔진 준비 중…"
	_status_dot.add_theme_stylebox_override("panel", UI.style(dot, Color(0, 0, 0, 0), 0, 99, 0, 0))
	_status_text.text = text

	# banner
	var down_text: String = "PC에 연결되어 있지 않아요. " if _phone else "AI 엔진에 연결되어 있지 않아요. "
	if st == Backend.Status.READY and Backend.llm_missing():
		_banner.visible = true
		_banner_label.text = Backend.llm_missing_text()
	elif st == Backend.Status.FAILED and _splash_dismissed:
		_banner.visible = true
		_banner_label.text = down_text + Backend.message
	else:
		_banner.visible = false

	# splash
	if st == Backend.Status.READY:
		_splash_dismissed = true # a later disconnect shows the banner, never the full-screen splash
		_splash_layer.visible = false
	else:
		_splash_layer.visible = not _splash_dismissed
		var failed: bool = st == Backend.Status.FAILED
		if _phone:
			var pairing: bool = st == Backend.Status.NEEDS_PAIRING
			_splash_title.text = "PC에 연결하지 못했어요" if failed else ("PC 연결이 필요해요" if pairing else "PC에 연결하는 중…")
			_splash_msg.text = Backend.message if Backend.message != "" else ("휴대폰에 Tailscale을 켜고, PC의 회화 연습에서 휴대폰 연결을 켠 뒤 연결해 주세요." if pairing else "PC가 켜져 있고 Tailscale이 연결돼 있는지 확인하고 있어요.")
			_splash_bar.visible = not failed and not pairing
			_splash_retry.visible = failed
			_splash_find.visible = failed or pairing
			_splash_find.text = "PC에 연결하기" if pairing else "다시 연결"
		else:
			_splash_title.text = "AI 엔진을 시작하지 못했어요" if failed else "AI 엔진 준비 중…"
			_splash_msg.text = Backend.message if Backend.message != "" else "처음에는 모델을 불러오느라 30초 정도 걸릴 수 있어요."
			_splash_bar.visible = not failed
			_splash_retry.visible = failed

	if _phone:
		_sync_connect_view(st)
	elif st == Backend.Status.READY and not _lan_probed:
		_lan_probed = true
		_probe_lan()


# ---------------------------------------------------------------- phone: connect screen

func _sync_connect_view(st: int) -> void:
	if st == Backend.Status.NEEDS_PAIRING:
		if not _connect_dismissed:
			_open_connect_view()
	else:
		_connect_dismissed = false
		if st == Backend.Status.READY and _connect_view != null and is_instance_valid(_connect_view) and not _connect_keep_open:
			_close_connect_view()


## True while the person opened the screen from the settings ("연결 변경") although the PC is connected.
var _connect_keep_open: bool = false


func is_connect_open() -> bool:
	return _connect_view != null and is_instance_valid(_connect_view)


func _open_connect_view() -> void:
	if not _phone or is_connect_open():
		return
	_connect_keep_open = Backend.status == Backend.Status.READY
	_connect_layer = CanvasLayer.new()
	_connect_layer.layer = 25
	add_child(_connect_layer)
	var holder := Control.new()
	holder.set_anchors_preset(Control.PRESET_FULL_RECT)
	_connect_layer.add_child(holder)
	var bg := ColorRect.new()
	bg.color = Pal.BG
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	holder.add_child(bg)
	_connect_pad = MarginContainer.new()
	_connect_pad.set_anchors_preset(Control.PRESET_FULL_RECT)
	holder.add_child(_connect_pad)
	var cv := ConnectView.new()
	cv.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cv.size_flags_vertical = Control.SIZE_EXPAND_FILL
	cv.allow_cancel = _connect_keep_open ## opened from "연결 변경" while connected: show the cancel button
	cv.connected.connect(func() -> void:
		_connect_dismissed = false
		_close_connect_view())
	cv.cancelled.connect(func() -> void:
		_connect_dismissed = true
		_close_connect_view())
	_connect_pad.add_child(cv)
	_connect_view = cv
	_last_kb = -1.0
	_update_phone_chrome()


func _close_connect_view() -> void:
	if _connect_layer != null and is_instance_valid(_connect_layer):
		_connect_layer.queue_free()
	_connect_layer = null
	_connect_pad = null
	_connect_view = null
	_connect_keep_open = false


# ---------------------------------------------------------------- phone: keyboard, safe area, back button

func _process(_delta: float) -> void:
	if _phone:
		_update_phone_chrome()
	else:
		_update_link_indicator()


func _update_phone_chrome() -> void:
	var kb: float = PhoneLayout.keyboard_height()
	var ins: Dictionary = PhoneLayout.safe_insets()
	if is_equal_approx(kb, _last_kb) and ins == _last_insets:
		return
	var kb_changed: bool = not is_equal_approx(kb, _last_kb)
	_last_kb = kb
	_last_insets = ins
	var typing: bool = kb > 0.0
	_root.offset_left = float(ins["left"])
	_root.offset_right = -float(ins["right"])
	_root.offset_bottom = -kb
	_top_pad.custom_minimum_size.y = float(ins["top"])
	_bottom_tabs.visible = not typing # the keyboard covers the bar: keep the page above it
	_bottom_tabs.set_bottom_inset(float(ins["bottom"]))
	_bottom_tabs.set_side_inset(0.0, 0.0)
	var tab_h: float = 0.0 if typing else PhoneLayout.TAB_H + float(ins["bottom"])
	_toast_gap.custom_minimum_size.y = 12.0 + (kb if typing else tab_h)
	if _connect_pad != null and is_instance_valid(_connect_pad):
		_connect_pad.add_theme_constant_override("margin_top", int(ins["top"]))
		_connect_pad.add_theme_constant_override("margin_left", int(ins["left"]))
		_connect_pad.add_theme_constant_override("margin_right", int(ins["right"]))
		_connect_pad.add_theme_constant_override("margin_bottom", int(kb if typing else ins["bottom"]))
	if kb_changed and typing:
		_keep_focus_visible()


func _on_focus_changed(node: Control) -> void:
	if node is LineEdit or node is TextEdit:
		_keep_focus_visible()


## Scrolls the page so that the focused text field is not hidden by the keyboard.
func _keep_focus_visible() -> void:
	await get_tree().process_frame
	await get_tree().process_frame
	var fo: Control = get_viewport().gui_get_focus_owner()
	if fo != null and is_instance_valid(fo) and (fo is LineEdit or fo is TextEdit):
		PhoneLayout.ensure_visible(fo)


## Android back button: one step back out of a sub screen, else to 오늘, else (twice within 2 s) quit.
func handle_back() -> void:
	if SyncManager.current != null and SyncManager.current.consume_back():
		return # the first-connection question is open: answer it first
	if is_connect_open():
		_connect_dismissed = true
		_close_connect_view()
		return
	if _bottom_tabs != null and _bottom_tabs.is_more_open():
		_bottom_tabs.close_more()
		return
	if views.has(current) and (views[current] as AppView).go_back():
		return
	if current != "today":
		show_view("today")
		return
	var now: int = Time.get_ticks_msec()
	if now - _last_back_msec <= BACK_EXIT_MSEC:
		_last_back_msec = -100000
		exit_requested.emit()
		if quit_on_exit:
			Backend.shutdown()
			get_tree().quit()
		return
	_last_back_msec = now
	Toast.info("한 번 더 누르면 종료돼요")


# ---------------------------------------------------------------- PC: "폰 연결 켜짐"

func _update_link_indicator() -> void:
	var last: bool = PhoneLinkPanel.last_enabled
	if last != _link_prev:
		if _link_prev and not last:
			_lan_probe_on = false # the settings card is the authority once it has seen the switch go off
		_link_prev = last
	var on: bool = last or _lan_probe_on
	if on == _link_shown:
		return
	_link_shown = on
	_link_dot.visible = on
	_link_text.visible = on
	_top_row.get_node("LinkGap").visible = on
	_layout_top_tabs()


## One look at /lan when the engine first answers: a PC app that restarts with the phone link left on
## still shows the dot before the settings card has been opened. Older engines answer 404: ignored.
func _probe_lan() -> void:
	var req = Api.get_json("/lan", 5.0, false)
	var res: Dictionary = await req.wait()
	if res["ok"] and res["data"] is Dictionary and bool((res["data"] as Dictionary).get("enabled", false)):
		_lan_probe_on = true


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
	if _phone:
		card.custom_minimum_size = Vector2(maxf(240.0, get_viewport_rect().size.x - 32.0), 0)
	_splash_card = card
	center.add_child(card)
	card.body.add_child(UI.label("회화 연습", "Eyebrow", false))
	_splash_title = UI.label("PC에 연결하는 중…" if _phone else "AI 엔진 준비 중…", "H2")
	card.body.add_child(_splash_title)
	_splash_msg = UI.label("", "Muted")
	card.body.add_child(_splash_msg)
	_splash_bar = ProgressBar.new()
	_splash_bar.indeterminate = true
	_splash_bar.show_percentage = false
	_splash_bar.custom_minimum_size = Vector2(0, 8)
	_splash_bar.add_theme_stylebox_override("fill", UI.style(Pal.EN, Color(0, 0, 0, 0), 0, 99, 0, 0))
	card.body.add_child(_splash_bar)
	var row := UI.adaptive(8)
	_splash_retry = UI.button("다시 시도", "primary", Pal.EN, 46)
	_splash_retry.pressed.connect(func() -> void: Backend.start())
	row.add_child(_splash_retry)
	if _phone:
		_splash_find = UI.button("다시 연결", "default", Pal.INK, 46)
		_splash_find.pressed.connect(_open_connect_view)
		row.add_child(_splash_find)
	var skip := UI.button("연결 없이 계속" if _phone else "엔진 없이 계속", "default", Pal.INK, 46)
	skip.pressed.connect(func() -> void:
		_splash_dismissed = true
		_on_backend_status())
	row.add_child(skip)
	card.body.add_child(row)
	if _phone:
		_splash_note = UI.label("PC 없이도 로드맵과 진행 기록은 볼 수 있어요. 레슨·대화·음성은 PC에 연결된 뒤에 써요.", "Small")
	else:
		_splash_note = UI.label("엔진 없이도 로드맵과 진행 기록은 볼 수 있어요. 레슨·대화·음성은 엔진이 준비된 뒤에 써요.", "Small")
	card.body.add_child(_splash_note)


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
	_toast_gap = UI.gap(28)
	v.add_child(_toast_gap)
	_toast_box = PanelContainer.new()
	_toast_box.theme_type_variation = &"Toast"
	_toast_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_toast_box.visible = false
	_toast_label = Label.new()
	_toast_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_toast_label.custom_minimum_size = Vector2(420, 0)
	if _phone:
		_toast_label.custom_minimum_size = Vector2(_toast_label_width(), 0)
	_toast_label.add_theme_color_override("font_color", Color.WHITE)
	_toast_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_toast_box.add_child(_toast_label)
	h.add_child(_toast_box)


## Phone: the toast is as wide as the screen minus a 16 px margin (and at most 420 px).
func _toast_label_width() -> float:
	return clampf(get_viewport_rect().size.x - 32.0 - 36.0, 200.0, 420.0)


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
	elif what == NOTIFICATION_WM_GO_BACK_REQUEST and _phone:
		handle_back()
	elif what == NOTIFICATION_RESIZED and _phone and _toast_label != null and _splash_card != null:
		_toast_label.custom_minimum_size.x = _toast_label_width()
		_splash_card.custom_minimum_size.x = maxf(240.0, get_viewport_rect().size.x - 32.0)
	elif what == NOTIFICATION_RESIZED and not _phone:
		_layout_top_tabs()
