extends Control
## Main scene: the shell of the app (docs/ui_redesign_design.md §4, §6.3-6.7). On the phone a fixed app bar on top and
## the bottom tab bar (4 tabs + "더보기"); on the PC a navigation list on the left (SideNav). Both show the views,
## the toast host, the backend splash and the banner.
##
## Phone behaviour (Platform.is_phone(), docs/android_remote_design.md §5) is added next to the PC code.
##
## Adding a tab (English v1.1: "연습", "기록"): `add_tab(key, label, view, short_label, after_key)` after _ready.
## `add_v11_tabs()` adds those two (and the StudyClock); _ready calls it only when this scene is the running scene
## of the app, so the layout tests that load main.tscn as a child still see the original tabs.
## "설정" is the last tab of the list: on the phone it sits in the "더보기" sheet, on the PC it is the item at the
## bottom of the SideNav. A tab added without `after_key` goes in front of it.
## A view that has sub screens overrides AppView.go_back() so the Android back button can step out of them.
## The colour scheme and the text size are applied once at start (UiBoot): changing them in the settings needs a restart.

signal exit_requested

const TABS := [
	["today", "오늘"],
	["lesson", "레슨"],
	["talk", "원어민 대화"],
	["review", "복습"],
	["reading", "읽기"],
	["roadmap", "로드맵"],
	["settings", "설정"],
]
## Shorter label of a tab in the phone bottom bar.
const TAB_SHORT := {"talk": "대화"}
const SETTINGS_KEY := "settings"
const BACK_EXIT_MSEC := 2000
## Phone bottom bar: 4 tabs + "더보기" (the rest goes into the sheet).
const PHONE_MAX_DIRECT := 5
## PC SideNav: the order of the items in the two sections (a tab that is in neither list goes to the end of "기록").
const NAV_LEARN := ["today", "lesson", "talk", "practice", "reading", "song", "review"]
const NAV_RECORD := ["stats", "roadmap"]
## Views that draw their own title / back / action row while a sub screen is open (the chat, a practice screen): the
## phone app bar then shows only its tab name and the connection chip, so nothing appears twice.
const OWN_HEADER := ["talk", "practice", "song"]
## Phone: the top badge while no PC is connected and the person chose to work without one.
const STANDALONE_TEXT := "폰 단독 모드"

var views: Dictionary = {}
var current: String = ""
var quit_on_exit: bool = true ## tests switch the real quit off

var _tabs: Array = TABS.duplicate(true)
var _tab_short: Dictionary = TAB_SHORT.duplicate()
var _phone: bool = false

var _root: BoxContainer
var _app_bar: AppBar            ## phone
var _bottom_tabs: BottomTabs    ## phone
var _side_nav: SideNav          ## PC
var _content: Control
var _banner: PanelContainer
var _banner_label: Label
var _banner_btn: Button
var _conn_chip: ConnChip        ## engine / PC connection (phone: in the app bar, PC: at the bottom of the SideNav)
var _link_chip: ConnChip        ## PC: "폰 연결 켜짐"
var _status_dot: Panel          ## the dot and the text of _conn_chip (kept as handles for tests / tools)
var _status_text: Label
var _link_dot: Panel
var _link_text: Label
var _link_shown: bool = false
var _link_prev: bool = false
var _lan_probed: bool = false
var _lan_probe_on: bool = false

var _toast_host: ToastHost
var _toast_box: PanelContainer  ## = _toast_host.box (shots / tests set .visible)
var _toast_label: Label         ## = _toast_host.label

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


## Colour scheme and text size from the saved settings, applied before anything is built (code-built UI copies the
## colours when it is made). A test or tool that applied its own scheme first (Window.theme is set) is left alone.
## A broken saved value ("purple", "abc", 9.0) falls back inside UiBoot / Ds: light, or the closest size.
func _boot_ui() -> void:
	var win := get_window()
	if win.theme != null:
		return
	var raw: Variant = Store.prefs.get("font_scale", 1.0)
	var scale: float = float(raw) if (typeof(raw) == TYPE_FLOAT or typeof(raw) == TYPE_INT) else 1.0
	UiBoot.apply(win, str(Store.prefs.get("scheme", "system")), scale)


func _ready() -> void:
	_phone = Platform.is_phone()
	_boot_ui()
	if _phone:
		PhoneLayout.install_touch_scroll(get_tree()) # a drag that starts on a card / button scrolls the page
	_setup_window()
	set_anchors_preset(Control.PRESET_FULL_RECT)

	var bg := ColorRect.new()
	bg.color = Pal.BG
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	# the box that holds the banner, the views (and on the phone the bottom tabs)
	var page_box: BoxContainer
	if _phone:
		_root = VBoxContainer.new()
		page_box = _root
	else:
		_root = HBoxContainer.new()
		page_box = VBoxContainer.new()
		page_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		page_box.size_flags_vertical = Control.SIZE_EXPAND_FILL
		page_box.add_theme_constant_override("separation", 0)
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.add_theme_constant_override("separation", 0)
	add_child(_root)

	_conn_chip = ConnChip.new()
	_status_dot = _conn_chip.dot
	_status_text = _conn_chip.label
	if _phone:
		_build_app_bar()
		_root.add_child(_app_bar)
	else:
		_build_side_nav()
		_root.add_child(_side_nav)
		_root.add_child(page_box)

	_banner = _build_banner()
	page_box.add_child(_banner)

	_content = Control.new()
	_content.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_content.clip_contents = true
	page_box.add_child(_content)

	if _phone:
		_bottom_tabs = BottomTabs.new()
		_bottom_tabs.max_direct = PHONE_MAX_DIRECT
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
	if _phone:
		(views["reading"] as ReadingView).bar_hosted = true # the app bar shows the reader's back button, title and action
	for k in views.keys():
		_register_view(views[k] as AppView)

	_toast_host = ToastHost.new()
	add_child(_toast_host)
	_toast_host.bind_toast_bus()
	_toast_box = _toast_host.box
	_toast_label = _toast_host.label
	_build_splash()
	if get_tree().current_scene == self:
		add_v11_tabs()
		add_sync()
	# The settings screen is built after add_sync(): its SyncPanel looks for the SyncManager once, when it is made.
	var settings := SettingsView.new()
	settings.standalone_panels = _phone # 처리 위치 / 기능 현황 / 읽어 주는 목소리: the phone app only
	views[SETTINGS_KEY] = settings
	_register_view(views[SETTINGS_KEY] as AppView)

	Store.navigate.connect(_on_navigate)
	Backend.status_changed.connect(_on_backend_status)
	if _phone:
		Route.mode_changed.connect(_on_route_mode) # the badge depends on the mode too
		if standalone_ok():
			_splash_dismissed = true # "PC 없이 시작" was chosen before: the PC splash never blocks the home screen
	(views[SETTINGS_KEY] as SettingsView).connect_requested.connect(_open_connect_view)
	if _phone:
		get_viewport().gui_focus_changed.connect(_on_focus_changed)
		_update_phone_chrome()
	else:
		_rebuild_nav()

	show_view("today")
	_on_backend_status()
	Backend.start()


func _register_view(v: AppView) -> void:
	v.visible = false
	v.bar_changed.connect(_on_view_bar_changed.bind(v))
	_content.add_child(v)


## Adds a tab behind the existing ones (in front of "설정"), or right after the tab `after_key` when that one exists.
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
		at = _tabs.size()
		if at > 0 and str((_tabs[at - 1] as Array)[0]) == SETTINGS_KEY:
			at -= 1
	_tabs.insert(at, [key, label])
	if short_label != "":
		_tab_short[key] = short_label
	views[key] = view
	_register_view(view)
	if _phone:
		_bottom_tabs.set_tabs(_tabs, _tab_short)
		_bottom_tabs.set_current(current)
	else:
		_rebuild_nav()


## English v1.1: 연습 after 복습, 기록 after 읽기, and the study clock (StudyLog writer). 노래 (song study, docs/song_study_design.md) after 읽기.
func add_v11_tabs() -> void:
	if views.has("practice"):
		return
	add_child(StudyClock.new())
	add_tab("practice", "연습", PracticeView.new(), "연습", "review")
	add_tab("stats", "기록", StatsView.new(), "기록", "reading")
	add_tab("song", "노래", SongView.new(), "노래", "reading") # PC: after 읽기 in the side nav; phone: inside 더보기


## 1.2: learning-record sync (timers, app lifecycle, first-connection dialog). Like the StudyClock it is only added when this
## scene is the running scene, so the layout tests that load main.tscn as a child never get one.
func add_sync() -> void:
	if SyncManager.current == null:
		add_child(SyncManager.new())


## Keys of the tabs in the order of the tab list ("설정" last).
func tab_keys() -> Array:
	var out: Array = []
	for t in _tabs:
		out.append(str((t as Array)[0]))
	return out


func _tab_label(key: String) -> String:
	for t in _tabs:
		if str((t as Array)[0]) == key:
			return str((t as Array)[1])
	return key


# ---------------------------------------------------------------- PC: side navigation

func _build_side_nav() -> void:
	_side_nav = SideNav.new()
	_side_nav.item_selected.connect(show_view)
	_side_nav.set_settings_visible(true)
	_conn_chip.tapped.connect(_open_settings)
	_link_chip = ConnChip.new()
	_link_chip.set_state("ok", "폰 연결 켜짐")
	_link_chip.visible = false # hidden unless the settings card or /lan says the PC lets a phone in
	_link_chip.tapped.connect(_open_settings)
	_link_dot = _link_chip.dot
	_link_text = _link_chip.label
	var foot := VBoxContainer.new()
	foot.add_theme_constant_override("separation", 4)
	foot.add_child(_link_chip)
	foot.add_child(_conn_chip)
	_side_nav.set_footer(foot)


## The SideNav items from the tab list: "학습" (오늘 ... 복습) and "기록" (기록, 로드맵); "설정" is its footer item.
func _rebuild_nav() -> void:
	if _side_nav == null:
		return
	var learn: Array = []
	var record: Array = []
	for k in NAV_LEARN:
		if tab_keys().has(k):
			learn.append([k, _tab_label(k)])
	for k in NAV_RECORD:
		if tab_keys().has(k):
			record.append([k, _tab_label(k)])
	for k in tab_keys():
		if k != SETTINGS_KEY and not NAV_LEARN.has(k) and not NAV_RECORD.has(k):
			record.append([k, _tab_label(k)])
	_side_nav.set_items([{"title": "학습", "items": learn}, {"title": "기록", "items": record}])
	_side_nav.set_current(current)


# ---------------------------------------------------------------- phone: app bar

func _build_app_bar() -> void:
	_app_bar = AppBar.new()
	_app_bar.back_pressed.connect(_on_bar_back)
	_app_bar.action_pressed.connect(_on_bar_action)
	_app_bar.chip_pressed.connect(_open_settings)
	_app_bar.set_chip(_conn_chip)


## Title, back button, actions and scroll link of the app bar from the current view (AppView contract, §6.3).
## A sub screen (page_title differs from the tab name) gets the back button; 오늘 gets the "설정" action.
func _refresh_bar() -> void:
	if _app_bar == null or not views.has(current):
		return
	var v: AppView = views[current]
	var title: String = _tab_label(current)
	var back := false
	var actions: Array = []
	var t: String = v.page_title()
	if t != "" and t != title:
		if OWN_HEADER.has(current):
			title = "" # the screen draws its own title / back / action row: nothing twice
		else:
			title = t
			back = true
			actions = v.page_actions()
	elif current == "today":
		actions = [{"id": SETTINGS_KEY, "text": "설정"}]
	else:
		actions = v.page_actions()
	_app_bar.set_page(title, back, actions)
	_app_bar.bind_scroll(v.scroll_host(), v.header_block())


func _on_view_bar_changed(v: AppView) -> void:
	if views.get(current, null) == v:
		_refresh_bar()


func _on_bar_back() -> void:
	if views.has(current) and (views[current] as AppView).go_back():
		return
	if current != "today":
		show_view("today")


func _on_bar_action(id: String) -> void:
	if id == SETTINGS_KEY and current == "today":
		_open_settings()
		return
	if views.has(current):
		(views[current] as AppView).on_action(id)


## The connection chip / the settings action: the settings screen (its first section is the connection).
func _open_settings() -> void:
	show_view(SETTINGS_KEY)


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
	_refresh_bar()


func _style_tabs() -> void:
	if _bottom_tabs != null:
		_bottom_tabs.set_current(current)
	if _side_nav != null:
		_side_nav.set_current(current)


func _on_navigate(view: String, lang: String) -> void:
	if lang == "en" or lang == "ja":
		Store.set_lang(lang)
	show_view(view)


# ---------------------------------------------------------------- banner / status

func _build_banner() -> PanelContainer:
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", UI.style(Pal.WARN_SOFT, Color(0, 0, 0, 0), 0, 0, 16 if _phone else 20, 10 if _phone else 8))
	var row := UI.adaptive(12)
	# the bold "! " in front says "warning" without the colour
	var msg := UI.hbox(6)
	msg.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var mark := UI.label("! ", "Strong", false)
	mark.add_theme_color_override("font_color", Pal.WARN_ON)
	mark.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	msg.add_child(mark)
	_banner_label = UI.colored("", Pal.WARN_ON, "")
	_banner_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	msg.add_child(_banner_label)
	row.add_child(msg)
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
			if standalone_badge():
				dot = Pal.MUTED
				text = STANDALONE_TEXT
		Backend.Status.NEEDS_PAIRING:
			dot = Pal.WARN
			text = "연결 필요" if _phone else "AI 엔진 준비 중…"
			if standalone_badge():
				dot = Pal.MUTED
				text = STANDALONE_TEXT
		_:
			dot = Pal.WARN
			text = "PC 연결 중…" if _phone else "AI 엔진 준비 중…"
	_conn_chip.set_state(_chip_kind(dot), text)

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


## The ConnChip state for the colour the status block above chose (the chip shows a dot AND the text).
func _chip_kind(c: Color) -> String:
	if c.is_equal_approx(Pal.OK):
		return "ok"
	if c.is_equal_approx(Pal.WARN):
		return "warn"
	if c.is_equal_approx(Pal.BAD):
		return "bad"
	return "idle"


# ---------------------------------------------------------------- phone: standalone

## Phone: "PC 없이 시작" was chosen (prefs.standalone_ok). Then an unpaired start (NEEDS_PAIRING) does not open the
## connect screen and no splash covers the home screen.
func standalone_ok() -> bool:
	return _phone and bool(Store.prefs.get("standalone_ok", false))


## The badge says "폰 단독 모드" instead of "연결 필요" / "PC 연결 안 됨": phone, no PC connected (not paired, or not
## reachable), and either standalone_ok or the processing place "이 폰에서만".
func standalone_badge() -> bool:
	if not _phone or Backend.status == Backend.Status.READY:
		return false
	return standalone_ok() or Route.normalize_mode(Route.mode) == "phone"


func _on_route_mode(_m: String) -> void:
	_on_backend_status()


## [PC 없이 시작] on the connect screen: close it, make sure nothing covers the home screen, go home.
func _on_standalone_chosen() -> void:
	_connect_dismissed = true
	_splash_dismissed = true
	_close_connect_view()
	_on_backend_status()
	show_view("today")


# ---------------------------------------------------------------- phone: connect screen

func _sync_connect_view(st: int) -> void:
	if st == Backend.Status.NEEDS_PAIRING:
		if not _connect_dismissed and not standalone_ok():
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
	cv.standalone_chosen.connect(_on_standalone_chosen)
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
	_app_bar.set_top_inset(float(ins["top"])) # status bar / notch
	_bottom_tabs.visible = not typing # the keyboard covers the bar: keep the page above it
	_bottom_tabs.set_bottom_inset(float(ins["bottom"]))
	_bottom_tabs.set_side_inset(0.0, 0.0)
	var tab_h: float = 0.0 if typing else PhoneLayout.TAB_H + float(ins["bottom"])
	_toast_host.set_bottom_gap(12.0 + (kb if typing else tab_h))
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


## Android back button: the first-connection question, then an open sheet / dialog, then one step back out of a sub
## screen, else to 오늘, else (twice within 2 s) quit.
func handle_back() -> void:
	if SyncManager.current != null and SyncManager.current.consume_back():
		return # the first-connection question is open: answer it first
	if Sheet.handle_back():
		return # a sheet (choice, confirm, 더보기) is open: it is closed (or answered) first, the screen behind stays
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
	_link_chip.visible = on


## One look at /lan when the engine first answers: a PC app that restarts with the phone link left on
## still shows the chip before the settings card has been opened. Older engines answer 404: ignored.
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
	_splash_bar = UI.progress_indeterminate(Pal.PRIMARY, 8.0)
	card.body.add_child(_splash_bar)
	var row := UI.adaptive(8)
	_splash_retry = UI.button("다시 시도", "primary", Pal.PRIMARY, 46)
	_splash_retry.pressed.connect(func() -> void: Backend.start())
	row.add_child(_splash_retry)
	if _phone:
		_splash_find = UI.button("다시 연결", "soft", Pal.PRIMARY, 46)
		_splash_find.pressed.connect(_open_connect_view)
		row.add_child(_splash_find)
	var skip := UI.button("연결 없이 계속" if _phone else "엔진 없이 계속", "soft", Pal.INK, 46)
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


# ---------------------------------------------------------------- quit

func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		Backend.shutdown()
		get_tree().quit()
	elif what == NOTIFICATION_WM_GO_BACK_REQUEST and _phone:
		handle_back()
	elif what == NOTIFICATION_RESIZED and _phone and _splash_card != null:
		_splash_card.custom_minimum_size.x = maxf(240.0, get_viewport_rect().size.x - 32.0)
