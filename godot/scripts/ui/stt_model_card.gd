class_name SttModelCard
extends VBoxContainer
## "음성 인식 모델" card (docs/v201_design.md 2.2): the state of the on-device speech model and the buttons
## [모델 받기] / [이어받기] / [취소] / [모델 지우기] (+ one row per model when there is a choice).
##
## The settings screen mounts `SttModelCard.build(self)`; the speaking screen opens the same content as a sheet with
## `SttModelCard.open_sheet(host)`. All state and every progress text come from ModelStore (progress_label builds the
## "35 / 60 MB" text, nothing here formats a progress of its own). Nothing is downloaded before the person confirmed
## the Wi-Fi question; "나중에" starts nothing.
##
## Node names the tests press: ModelGetBtn, ModelResumeBtn, ModelCancelBtn, ModelDeleteBtn, ModelPick_<model id>.

const TITLE := "음성 인식 모델"
const WIFI_TITLE := "음성 인식 모델 받기"
const DELETE_TITLE := "모델 지우기"
const DELETE_TEXT := "받은 음성 인식 모델을 지워요. 다시 쓰려면 새로 받아야 해요."
const LOW_RAM_TEXT := "이 폰은 메모리가 적어서 작은 모델을 추천해요."
const BUSY_TEXT := "다른 모델을 받는 중이에요. 끝난 뒤에 다시 시도해 주세요."
const LOW_RAM_BYTES := 3221225472 ## 3 GiB: a "3 GB" phone reports less than this

## Tests: () -> int physical memory in bytes (default OS.get_memory_info()["physical"]); 0 or less = unknown.
static var memory_hook: Callable = Callable()

var host: Node = null
var title_label: Label = null
var status_label: Label = null
var bar: ProgressBar = null
var note_label: Label = null
var ram_label: Label = null
var pick_box: VBoxContainer = null
var get_btn: Button = null
var resume_btn: Button = null
var cancel_btn: Button = null
var delete_btn: Button = null

var _note: String = ""
var _picks: Dictionary = {} ## model id -> Button
var _events: Node = null


static func build(host_: Node = null) -> Control:
	var c := SttModelCard.new()
	c.host = host_
	c._build()
	return c


## The same card inside a sheet (the speaking screen's [모델 받기]). Returns the sheet.
static func open_sheet(host_: Node) -> Node:
	var card := SttModelCard.build(host_)
	return Sheet.open(host_, TITLE, card, [{"id": "close", "text": "닫기", "kind": "flat"}])


static func low_ram() -> bool:
	var mem: int = 0
	if memory_hook.is_valid():
		mem = int(memory_hook.call())
	else:
		mem = int(OS.get_memory_info().get("physical", 0))
	return mem > 0 and mem < LOW_RAM_BYTES


func _build() -> void:
	name = "SttModelCard"
	add_theme_constant_override("separation", 8)
	title_label = UI.label(TITLE, "ListMain")
	add_child(title_label)
	status_label = UI.label("", "")
	status_label.name = "ModelStatus"
	add_child(status_label)
	bar = UI.progress_bar(0.0, Pal.PRIMARY)
	bar.name = "ModelProgress"
	bar.visible = false
	add_child(bar)
	note_label = UI.label("", "Small")
	note_label.name = "ModelNote"
	add_child(note_label)
	ram_label = UI.label(LOW_RAM_TEXT, "Small")
	ram_label.name = "ModelRamHint"
	add_child(ram_label)
	pick_box = UI.vbox(6)
	pick_box.name = "ModelPicks"
	add_child(pick_box)
	var row := UI.flow(12, 8)
	get_btn = UI.button("모델 받기", "primary", Pal.PRIMARY)
	get_btn.name = "ModelGetBtn"
	get_btn.pressed.connect(_on_get)
	row.add_child(get_btn)
	resume_btn = UI.button("이어받기", "primary", Pal.PRIMARY)
	resume_btn.name = "ModelResumeBtn"
	resume_btn.pressed.connect(_on_get)
	row.add_child(resume_btn)
	cancel_btn = UI.button("취소", "soft", Pal.PRIMARY)
	cancel_btn.name = "ModelCancelBtn"
	cancel_btn.pressed.connect(_on_cancel)
	row.add_child(cancel_btn)
	delete_btn = UI.button("모델 지우기", "soft", Pal.BAD)
	delete_btn.name = "ModelDeleteBtn"
	delete_btn.pressed.connect(_on_delete)
	row.add_child(delete_btn)
	add_child(row)
	_events = ModelStore.events()
	_events.connect("progress", _on_progress)
	_events.connect("state_changed", _on_state)
	_events.connect("finished", _on_finished)
	refresh()
	UI.fix_cjk(self)


func _exit_tree() -> void:
	if _events != null and is_instance_valid(_events):
		for pair in [["progress", _on_progress], ["state_changed", _on_state], ["finished", _on_finished]]:
			if _events.is_connected(pair[0], pair[1]):
				_events.disconnect(pair[0], pair[1])


func _host() -> Node:
	return host if host != null and is_instance_valid(host) and host.is_inside_tree() else self


## Redraws from ModelStore (state, progress) and the remembered note.
func refresh() -> void:
	if status_label == null:
		return
	var mf: Dictionary = ModelStore.manifest()
	if not bool(mf["ok"]):
		status_label.text = ModelStore.ERR_TEXT["bad_manifest"]
		note_label.visible = false
		bar.visible = false
		ram_label.visible = false
		pick_box.visible = false
		for b in [get_btn, resume_btn, cancel_btn, delete_btn]:
			(b as Button).visible = false
		return
	var id: String = ModelStore.active_id()
	var inf: Dictionary = ModelStore.info(id)
	var st: String = str(inf.get("state", "missing"))
	var total: int = int(inf.get("bytes", 0))
	var part: int = int(inf.get("part_bytes", 0))
	bar.visible = false
	match st:
		"downloading":
			status_label.text = "받는 중 " + ModelStore.progress_label(part, total)
			bar.visible = true
			bar.value = float(part) / float(maxi(total, 1))
		"verifying":
			status_label.text = "받은 파일을 확인하는 중이에요…"
			bar.visible = true
			bar.value = 1.0
		"partial":
			status_label.text = "받다가 멈췄어요. " + ModelStore.progress_label(part, total)
			bar.visible = true
			bar.value = float(part) / float(maxi(total, 1))
		"ready":
			status_label.text = "준비됐어요 · %s · %s" % [str(inf.get("label_ko", "")), ModelStore.mb_label(total)]
		"corrupt":
			status_label.text = ModelStore.ERR_TEXT["model_corrupt"]
		_:
			status_label.text = "음성 인식 모델(%s)을 받으면 이 폰에서 영어 발음을 채점해요." % ModelStore.mb_label(total)
	note_label.text = _note
	note_label.visible = _note != ""
	ram_label.visible = low_ram()
	var busy: bool = st == "downloading" or st == "verifying"
	get_btn.visible = st == "missing" or st == "corrupt"
	get_btn.text = "다시 받기" if st == "corrupt" else "모델 받기"
	resume_btn.visible = st == "partial"
	cancel_btn.visible = st == "downloading"
	delete_btn.visible = st == "ready" or st == "partial" or st == "corrupt"
	_rebuild_picks(mf["models"], id, busy)


func _rebuild_picks(models: Array, active: String, busy: bool) -> void:
	for ch in pick_box.get_children():
		pick_box.remove_child(ch)
		ch.queue_free()
	_picks.clear()
	pick_box.visible = models.size() >= 2
	if models.size() < 2:
		return
	for m in models:
		var md: Dictionary = m
		var mid: String = str(md["id"])
		var st: String = ModelStore.state(mid)
		var tail: String = " · 받음" if st == "ready" else ""
		var b := UI.option_row("%s · %s%s" % [str(md["label_ko"]), ModelStore.mb_label(int(md["bytes"])), tail])
		b.name = "ModelPick_" + mid
		UI.paint_option(b, "picked" if mid == active else "idle", Pal.PRIMARY)
		b.disabled = busy and mid != active
		b.pressed.connect(_on_pick.bind(mid))
		pick_box.add_child(b)
		_picks[mid] = b
	UI.fix_cjk(pick_box)


func _on_pick(id: String) -> void:
	if ModelStore.state(ModelStore.active_id()) in ["downloading", "verifying"]:
		return
	ModelStore.set_active(id)
	_note = ""
	refresh()


func _on_progress(id: String, _done: int, _total: int) -> void:
	if id == ModelStore.active_id():
		refresh()


func _on_state(_id: String, _state: String) -> void:
	refresh()


func _on_finished(_id: String, ok: bool, err: String) -> void:
	if ok or err == "cancelled":
		_note = ""
	elif ModelStore.ERR_TEXT.has(err):
		_note = str(ModelStore.ERR_TEXT[err])
	refresh()


func _on_get() -> void:
	var id: String = ModelStore.active_id()
	var m: Dictionary = ModelStore.model(id)
	if m.is_empty():
		_note = str(ModelStore.ERR_TEXT["bad_manifest"])
		refresh()
		return
	var msg: String = "음성 인식 모델(%s)을 받아요. 와이파이에 연결돼 있나요?" % ModelStore.mb_label(int(m["bytes"]))
	var sh := Sheet.confirm(_host(), WIFI_TITLE, msg, "받기", false, "나중에")
	sh.closed.connect(func(r: Variant) -> void:
		if typeof(r) == TYPE_STRING and String(r) == "ok" and is_instance_valid(self):
			_begin(id, false))


func _begin(id: String, space_confirmed: bool) -> void:
	var r: Dictionary = ModelStore.start(id, space_confirmed)
	var code: String = str(r.get("err_code", ""))
	if bool(r.get("ok", false)):
		_note = ""
	elif code == "space_unknown":
		var sh := Sheet.confirm(_host(), WIFI_TITLE, ModelStore.SPACE_UNKNOWN_TEXT, "계속", false, "취소")
		sh.closed.connect(func(res: Variant) -> void:
			if typeof(res) == TYPE_STRING and String(res) == "ok" and is_instance_valid(self):
				_begin(id, true))
		return
	elif code == "no_space":
		_note = "저장 공간이 모자라요. 약 %d MB 이상 비운 뒤 다시 시도해 주세요." % int(r.get("need_mb", 0))
	elif code == "busy":
		_note = BUSY_TEXT
	elif ModelStore.ERR_TEXT.has(code):
		_note = str(ModelStore.ERR_TEXT[code])
	else:
		_note = str(ModelStore.ERR_TEXT["io"])
	refresh()


func _on_cancel() -> void:
	ModelStore.cancel(ModelStore.active_id())


func _on_delete() -> void:
	var id: String = ModelStore.active_id()
	var sh := Sheet.confirm(_host(), DELETE_TITLE, DELETE_TEXT, "지우기", true, "취소")
	sh.closed.connect(func(r: Variant) -> void:
		if typeof(r) == TYPE_STRING and String(r) == "ok" and is_instance_valid(self):
			if not ModelStore.remove(id):
				_note = str(ModelStore.ERR_TEXT["io"])
			else:
				_note = ""
			refresh())
