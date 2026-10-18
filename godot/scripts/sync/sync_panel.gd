class_name SyncPanel
extends VBoxContainer
## 설정 카드의 "학습 기록 동기화" 패널 (설계 docs/sync_design.md §6.3, §4.8, §4.8.1). 독립 패널이라 설정 화면을 개편해도 한 줄(마운트)로 옮긴다.
##
## UI.* 헬퍼와 테마 변형만 쓴다(직접 색·글자 크기 없음). 탭 동작은 전부 BaseButton 이라 PhoneLayout.install_touch_scroll 과 맞는다.
## 이 파일은 §6.3 의 문구를 상수로 한 곳에 모은다(SyncManager / SyncChoiceDialog 도 여기 것을 쓴다).
## SyncManager 가 없으면(레이아웃 시험처럼 main 이 자식 장면일 때) 아무것도 만들지 않는다 -> 설정 카드가 이 패널과 구분선을 숨긴다.

# ---------------------------------------------------------------- 문구 (설계 §6.3 표와 글자 그대로)

const T_TITLE := "학습 기록 동기화"
const DIALOG_TITLE_PHONE := "PC와 학습 기록을 합칠까요?"
const DIALOG_TITLE_PC := "폰과 학습 기록을 합칠까요?"
const DIALOG_BODY := "이 폰과 PC에 따로 쌓인 학습 기록을 하나로 합쳐요. 어느 쪽 기록도 지워지지 않고, 합치기 전에 백업해 둬요. 설정에서 언제든 끌 수 있어요."
const BTN_MERGE := "합치기"
const BTN_SEPARATE := "따로 쓰기"
const TOAST_SEPARATE := "따로 쓰기로 했어요. 설정의 '학습 기록 동기화'를 켜면 언제든 합칠 수 있어요."
const DESC_PC := "휴대폰 연결을 켜고 폰 앱에서 이 PC에 연결하면, 폰과 PC의 학습 기록이 자동으로 합쳐져요."
const DESC_PHONE := "PC에 연결돼 있으면 공부한 기록이 PC와 자동으로 합쳐져요. 연결이 안 될 때 공부한 것도 다음 연결 때 반영돼요."
const LAST_PREFIX := "마지막 동기화: "
const LAST_JUST := "방금 전"
const LAST_MIN := "%d분 전"
const LAST_TODAY := "오늘 %02d:%02d"
const LAST_DATE := "%d월 %d일 %02d:%02d"
const LAST_NONE := "아직 동기화하지 않았어요"
const DEVICES_PREFIX := "함께 쓰는 기기: "
const DEVICES_NONE := "아직 다른 기기가 없어요"
const STATUS_BUSY := "동기화 중…"
const STATUS_OK := "동기화됐어요"
const BTN_SYNC := "지금 동기화"
const SWITCH_NOTE := "끄면 이 기기의 기록은 PC와 주고받지 않아요. 다시 켜면 PC에 남아 있는 기록과 합쳐져요."
const LINK_RESTORE := "이전 상태로 되돌리기"
const REASON_LABELS := {"first": "첫 동기화 전", "auto": "동기화 전", "restore": "되돌리기 전", "unlink": "초기화 전"}
const RESTORE_CONFIRM := "이 시점으로 되돌릴까요? 자동 동기화가 꺼져요."
const BTN_RESTORE := "되돌리기"
const BTN_CANCEL := "취소"
const TOAST_FIRST_MERGE := "PC와 폰의 학습 기록을 합쳤어요. 합치기 전 기록은 백업해 뒀어요."
const TOAST_SYNCED := "동기화했어요."
const TOAST_SYNCED_CARDS := " 복습 카드 %d장이 새로 들어왔어요."
const CLOCK_WARN := "이 기기의 시계가 PC와 %d분 차이 나요. 시계를 자동으로 맞춰 주세요."
const TOAST_RESTORED := "되돌렸어요. 자동 동기화를 껐어요. 다시 켜면 PC와 다시 합쳐져요."
## 설계 §4.8: "모든 기록 지우기" 확인 문구(동기화가 켜져 있을 때)
const RESET_SYNC_TEXT := "동기화가 켜져 있어요. 지우면 이 기기의 동기화 연결이 끊기고, PC 보관함에 올라간 기록은 그대로 남아요. (PC 보관함까지 지우려면 PC의 backend\\data\\sync 폴더를 지우세요.)"
const RESET_BASE_TEXT := "정말 지울까요? 되돌릴 수 없어요."

# 설계에 없는 보조 문구(이 파일이 정한다)
const DIALOG_WORKING := "합치는 중…"
const TOAST_BUSY := "녹음이 끝나면 동기화해요."
const TOAST_CHOOSE := "합칠지 따로 쓸지 골라 주세요."
const TOAST_TRIMMED := "기록이 많아서 일부(복습 카드 %d장, 아는 단어 %d개)는 이 기기에 담지 못했어요. 보관함에는 그대로 남아 있어요."
const BACKUPS_NONE := "되돌릴 백업이 아직 없어요."
const BTN_RELINK_HUB := "이 PC와 새로 합치기"
const BTN_RELINK_LOST := "새로 합치기"
const RELINK_CONFIRM := "기록이 겹쳐 셀 수 있어요. 합치기 전에 백업해 둬요. 계속할까요?"
const GENERIC_ERROR := "동기화하지 못했어요. 잠시 뒤 다시 해 주세요."
## 엔진 오류표(SyncEngine.ERRORS)에 없는 코드: 엔진 진행 중/잘못된 선택, 허브가 직접 돌려주는 오류(sync_hub.py 의 문구)
const EXTRA_ERRORS := {
	"in_progress": "동기화 중이에요. 잠시 뒤 다시 해 주세요.",
	"bad_choice": "선택을 확인하지 못했어요. 다시 골라 주세요.",
	"forbidden_replica": "이 기기의 기록은 이 휴대폰에서 바꿀 수 없어요.",
	"seq_jump": "보낸 번호가 저장된 번호보다 너무 많이 앞서 있어요.",
}
const REFRESH_SEC := 30.0

# ---------------------------------------------------------------- 화면

## 시험이 바꿔 끼운다. 비어 있으면 _ready 가 SyncManager.current 를 쓴다.
var manager: SyncManager = null

var switch_box: CheckBox
var desc_label: Label
var note_label: Label
var last_label: Label
var devices_label: Label
var status_label: Label
var warn_box: VBoxContainer
var sync_button: Button
var relink_button: Button
var relink_confirm: VBoxContainer
var restore_link: Button
var backup_box: VBoxContainer
var backup_buttons: Array = [] ## 백업 목록의 버튼들(시험이 누른다)
var restore_confirm: VBoxContainer
var restore_yes: Button
var _updating: bool = false
var _pending_restore: String = ""
var _timer: Timer


func _init() -> void:
	add_theme_constant_override("separation", 10)


func _ready() -> void:
	if manager == null:
		manager = SyncManager.current
	if manager == null:
		return
	switch_box = CheckBox.new()
	switch_box.text = T_TITLE
	switch_box.focus_mode = Control.FOCUS_NONE
	switch_box.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	if Platform.is_phone():
		switch_box.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		UI.touch(switch_box, 48.0)
	switch_box.toggled.connect(_on_switch)
	add_child(switch_box)
	desc_label = UI.label(DESC_PHONE if manager.kind == "phone" else DESC_PC, "Small")
	add_child(desc_label)
	note_label = UI.label(switch_note_text(manager.kind), "Small")
	add_child(note_label)
	last_label = UI.label("", "")
	add_child(last_label)
	devices_label = UI.label("", "Small")
	add_child(devices_label)
	status_label = UI.label("", "Strong")
	add_child(status_label)
	warn_box = UI.vbox(4)
	add_child(warn_box)
	var brow := UI.flow(8, 8)
	sync_button = UI.button(BTN_SYNC, "soft")
	sync_button.pressed.connect(_on_sync_pressed)
	brow.add_child(sync_button)
	relink_button = UI.button(BTN_RELINK_HUB, "default")
	relink_button.pressed.connect(_on_relink_pressed)
	brow.add_child(relink_button)
	add_child(brow)
	relink_confirm = _confirm_box(RELINK_CONFIRM, BTN_RELINK_LOST, func() -> void: _do_relink())
	add_child(relink_confirm)
	restore_link = UI.link_button(LINK_RESTORE)
	restore_link.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	restore_link.pressed.connect(_on_restore_link)
	add_child(restore_link)
	backup_box = UI.vbox(6)
	backup_box.visible = false
	add_child(backup_box)
	restore_confirm = _confirm_box(RESTORE_CONFIRM, BTN_RESTORE, func() -> void: _do_restore())
	restore_yes = restore_confirm.get_meta("yes") as Button
	add_child(restore_confirm)
	manager.state_changed.connect(refresh)
	_timer = Timer.new()
	_timer.wait_time = REFRESH_SEC
	_timer.timeout.connect(refresh)
	add_child(_timer)
	_timer.start()
	visibility_changed.connect(func() -> void:
		if is_visible_in_tree():
			refresh())
	refresh()


## 안내 문구 + [yes_text] [취소] 한 줄. 처음엔 숨겨져 있다.
func _confirm_box(text: String, yes_text: String, on_yes: Callable) -> VBoxContainer:
	var box := UI.vbox(8)
	box.visible = false
	box.add_child(UI.label(text, "Small"))
	var row := UI.flow(8, 8)
	var yes := UI.button(yes_text, "primary")
	yes.pressed.connect(on_yes)
	row.add_child(yes)
	var no := UI.button(BTN_CANCEL, "default")
	no.pressed.connect(func() -> void: box.visible = false)
	row.add_child(no)
	box.add_child(row)
	box.set_meta("yes", yes)
	box.set_meta("no", no)
	return box


# ---------------------------------------------------------------- 갱신

func refresh() -> void:
	if manager == null or manager.engine == null or switch_box == null:
		return
	var st: Dictionary = manager.status()
	var enabled: bool = bool(st.get("enabled", false))
	var busy: bool = bool(st.get("manager_busy", false)) or bool(st.get("busy", false))
	_updating = true
	switch_box.set_pressed_no_signal(enabled)
	_updating = false
	switch_box.disabled = busy
	note_label.visible = not enabled
	sync_button.disabled = (not enabled) or busy
	sync_button.text = STATUS_BUSY if busy else BTN_SYNC
	var skew: int = int(st.get("clock_off_sec", 0))
	last_label.text = last_line(int(st.get("last_ok", 0)), int(Time.get_unix_time_from_system()) + skew, _bias_min())
	devices_label.text = devices_line(st.get("peers", []) as Array)
	# 상태 줄
	var le: Dictionary = st.get("last_error", {}) as Dictionary
	var code: String = str(le.get("code", ""))
	var text: String = ""
	if busy:
		text = STATUS_BUSY
	elif bool(st.get("lost", false)):
		text = error_text({"code": "state_lost"})
	elif code != "":
		text = error_text(le)
	elif enabled and manager.last_result.get("ok", false) == true:
		text = STATUS_OK
	status_label.text = text
	status_label.visible = text != ""
	# 경고 줄: 시계 + 결과의 경고(시계 문구는 위에서 따로 만든다)
	UI.clear(warn_box)
	if skew != 0:
		warn_box.add_child(UI.label(CLOCK_WARN % int(roundf(absf(float(skew)) / 60.0)), "Small"))
	for w in (manager.last_result.get("warnings", []) as Array):
		var ws: String = str(w)
		if ws != "" and not ws.begins_with("이 기기의 시계가"):
			warn_box.add_child(UI.label(ws, "Small"))
	warn_box.visible = warn_box.get_child_count() > 0
	# 새로 합치기: 다른 PC 에 붙었거나(hub_changed) 상태 파일이 손상됐을 때(state_lost)
	var lost: bool = bool(st.get("lost", false))
	relink_button.visible = lost or code == "hub_changed"
	relink_button.text = BTN_RELINK_LOST if lost else BTN_RELINK_HUB
	if not relink_button.visible:
		relink_confirm.visible = false
	restore_link.disabled = busy


static func _bias_min() -> int:
	return int(Time.get_time_zone_from_system().get("bias", 0))


# ---------------------------------------------------------------- 사용자 동작

func _on_switch(on: bool) -> void:
	if _updating or manager == null:
		return
	manager.set_enabled(on)
	refresh()


func _on_sync_pressed() -> void:
	if manager != null:
		manager.sync_manual()


func _on_relink_pressed() -> void:
	relink_confirm.visible = true


func _do_relink() -> void:
	relink_confirm.visible = false
	if manager != null:
		await manager.relink()


func _on_restore_link() -> void:
	backup_box.visible = not backup_box.visible
	restore_confirm.visible = false
	if backup_box.visible:
		_fill_backups()


func _fill_backups() -> void:
	UI.clear(backup_box)
	backup_buttons.clear()
	var list: Array = manager.engine.list_backups()
	if list.is_empty():
		backup_box.add_child(UI.label(BACKUPS_NONE, "Small"))
		return
	var bias: int = _bias_min()
	for b in list:
		var bd: Dictionary = b
		var btn := UI.button("%s · %s" % [stamp_text(int(bd.get("at", 0)), bias), reason_label(str(bd.get("reason", "")))], "default")
		var nm: String = str(bd.get("name", ""))
		btn.set_meta("backup", nm)
		btn.pressed.connect(func() -> void:
			_pending_restore = nm
			restore_confirm.visible = true)
		backup_box.add_child(btn)
		backup_buttons.append(btn)


func _do_restore() -> void:
	restore_confirm.visible = false
	var nm: String = _pending_restore
	_pending_restore = ""
	if nm == "" or manager == null:
		return
	var r: Dictionary = manager.restore(nm)
	if bool(r.get("ok", false)):
		backup_box.visible = false
	refresh()


# ---------------------------------------------------------------- 문구 만들기 (정적: 시험이 직접 부른다)

static func dialog_title(kind: String) -> String:
	return DIALOG_TITLE_PHONE if kind == "phone" else DIALOG_TITLE_PC


## PC 앱은 "PC" 자리를 "폰" 으로 바꾼다(같은 문장이 PC 기준으로 읽히게).
static func switch_note_text(kind: String) -> String:
	return SWITCH_NOTE if kind == "phone" else _pc_to_phone(SWITCH_NOTE)


static func restored_text(kind: String) -> String:
	return TOAST_RESTORED if kind == "phone" else _pc_to_phone(TOAST_RESTORED)


## PC 기준 문장을 폰 기준으로(조사도 맞춘다: PC와 -> 폰과, PC에 -> 폰에).
static func _pc_to_phone(s: String) -> String:
	return s.replace("PC와", "폰과").replace("PC에", "폰에").replace("PC", "폰")


## 결과/오류 Dictionary({code, error}) -> 사용자에게 보일 한국어 한 줄. 오류가 아니면 "".
static func error_text(res: Dictionary) -> String:
	var code: String = str(res.get("code", ""))
	if code == "ok" or code == "disabled" or code == "busy":
		return ""
	var e: String = str(res.get("error", ""))
	if e != "":
		return e
	if SyncEngine.ERRORS.has(code):
		return str(SyncEngine.ERRORS[code])
	if EXTRA_ERRORS.has(code):
		return str(EXTRA_ERRORS[code])
	return GENERIC_ERROR


## unix 초 + 시간대 편차(분) -> {m, d, h, min, ymd(일 번호 비교용 문자열)}
static func _parts(unix: int, bias_min: int) -> Dictionary:
	var d: Dictionary = Time.get_datetime_dict_from_unix_time(unix + bias_min * 60)
	return {"year": int(d["year"]), "month": int(d["month"]), "day": int(d["day"]), "hour": int(d["hour"]), "minute": int(d["minute"])}


## 백업 목록용 시각: "10월 16일 21:05"
static func stamp_text(unix: int, bias_min: int) -> String:
	var p: Dictionary = _parts(unix, bias_min)
	return LAST_DATE % [p["month"], p["day"], p["hour"], p["minute"]]


## "마지막 동기화" 줄 전체. last_ok == 0 이면 "아직 동기화하지 않았어요".
static func last_line(last_ok: int, now: int, bias_min: int) -> String:
	if last_ok <= 0:
		return LAST_NONE
	var ago: int = now - last_ok
	if ago < 60:
		return LAST_PREFIX + LAST_JUST
	if ago < 3600:
		return LAST_PREFIX + (LAST_MIN % int(ago / 60))
	var a: Dictionary = _parts(last_ok, bias_min)
	var n: Dictionary = _parts(now, bias_min)
	if a["year"] == n["year"] and a["month"] == n["month"] and a["day"] == n["day"]:
		return LAST_PREFIX + (LAST_TODAY % [a["hour"], a["minute"]])
	return LAST_PREFIX + (LAST_DATE % [a["month"], a["day"], a["hour"], a["minute"]])


static func devices_line(peers: Array) -> String:
	var names: Array[String] = []
	for p in peers:
		var n: String = str((p as Dictionary).get("name", "")).strip_edges() if p is Dictionary else ""
		names.append(n if n != "" else "기기")
	if names.is_empty():
		return DEVICES_NONE
	return DEVICES_PREFIX + ", ".join(names)


static func reason_label(reason: String) -> String:
	return str(REASON_LABELS.get(reason, reason))


# ---------------------------------------------------------------- "모든 기록 지우기" 연동 (today_view.gd 가 부른다)

## 동기화가 켜져 있으면 §4.8 문구를 앞에 붙인다.
static func reset_confirm_text() -> String:
	var m: SyncManager = SyncManager.current
	if m != null and m.engine != null and bool(m.status().get("enabled", false)):
		return RESET_SYNC_TEXT + "\n" + RESET_BASE_TEXT
	return RESET_BASE_TEXT


## 확인 줄 라벨의 문구를 정한다. 동기화 문구가 붙어 길어지면 줄바꿈을 켠다.
static func apply_reset_text(label: Label) -> void:
	var t: String = reset_confirm_text()
	label.text = t
	if t != RESET_BASE_TEXT:
		label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL


## 지우기 직전: 동기화 연결을 끊는다(백업 `unlink`, 스위치 끔, 몫 정보 비움). 매니저가 없으면 아무것도 안 한다.
## 진행 중인 동기화가 끝나기를 기다리므로 호출하는 쪽이 `await` 한다.
static func before_reset() -> void:
	var m: SyncManager = SyncManager.current
	if m != null:
		await m.before_reset()
