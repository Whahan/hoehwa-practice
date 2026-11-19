class_name SttDiagSheet
extends RefCounted
## "진단 보기" sheet of 설정 > 음성 인식 (docs/v201_design.md 2.5, 4.3): the phone measures its own speed and memory and
## copies ONE block of numbers and codes for the developer (hoehwa-diag 1). The block holds no recognised text, no target
## sentence, no path, no key and no user name: every value is a number, a short code, or a name from a whitelist.
##
## Buttons (node names the tests press): DiagRecBtn (one sentence, kept in memory only), DiagBench20Btn, DiagBench60Btn,
## DiagBatStart / DiagBatEnd (SpinBox 0..100, typed by the person), DiagCopyBtn. The raw block is never shown on screen.
## LocalStt is loaded by path (`load()`), so this file compiles and runs without it (the block then says `stt=missing`).

## The sentence the person reads for the speed test (shown on the screen; never part of the copied block).
const TARGET := "I would like a cup of coffee, please."
const BENCH_SHORT := 20
const BENCH_LONG := 60
const RECORD_SEC := 6.0
const LOCAL_STT_PATH := "res://scripts/local/local_stt.gd"
const NO_VALUE := "-"
const RECENT_MAX := 20
const SHOWN_MAX := 9999 ## screen numbers stay below five digits

const TXT_TITLE := "음성 인식 진단"
const TXT_INTRO := "이 폰이 말하기 채점을 얼마나 빨리 하는지 재요. 복사되는 글에는 속도·메모리 같은 숫자만 들어 있고, 녹음이나 인식된 글은 들어 있지 않아요."
const TXT_READ := "아래 문장을 소리 내어 읽으며 녹음해 주세요. 녹음은 메모리에만 있다가 이 시트를 닫으면 사라져요."
const TXT_NOT_RECORDED := "아직 녹음하지 않았어요."
const TXT_NEED_RECORD := "먼저 [한 문장 녹음]으로 위 문장을 녹음해 주세요."
const TXT_NO_STT := "이 앱에는 폰 음성 인식이 없어요."
const TXT_BENCH_FAIL := "시험을 끝내지 못했어요. 모델을 받았는지, 폰 채점이 켜져 있는지 확인해 주세요."
const TXT_REC_FAIL := "녹음하지 못했어요. 마이크 권한을 확인하고 다시 해 보세요."
const TXT_REC_SILENT := "소리가 거의 안 들어왔어요. 조금 더 크게 읽고 다시 녹음해 주세요."
const TXT_COPIED := "복사했어요. 대화창에 붙여 넣어 주세요."
const TXT_RUNNING := "시험 중이에요… "
const TXT_BATTERY_EMPTY := "입력 안 함"
const TXT_BATTERY_NOTE := "배터리 %는 시험 전후에 직접 적어 주세요(폰 화면 위쪽 숫자)."

const _STATES := ["missing", "partial", "downloading", "verifying", "ready", "corrupt"]
const _PARAM_STATES := ["calibrated", "uncalibrated"]
const _PLATFORMS := ["Windows", "Android", "Linux", "macOS", "iOS", "Web", "FreeBSD", "NetBSD", "OpenBSD", "BSD"]
## What WhisperBridge.cpu_features() can list (native/whisper_bridge/src/whisper_bridge.cpp).
const _CPU_FEATURES := ["asimd", "fphp", "asimdhp", "asimddp", "sve", "sve2", "i8mm", "bf16"]
## Whole-string formats (\A ... \z, nothing else may be in front of or behind the match). The bridge text is
## "bridge <n> / whisper.cpp <7 hex digits or unknown>[ +<patch>]..." (WhisperBridge::version()).
const RE_BRIDGE := "\\Abridge ([0-9]{1,3}) / whisper\\.cpp ([0-9a-f]{7}|unknown)((?: \\+abort-sched)?)\\z"
const RE_APP := "\\A[0-9]{1,3}\\.[0-9]{1,3}\\.[0-9]{1,3}(?:-(?:alpha|beta|rc)[0-9]{0,2})?\\z"
const RE_OS := "\\A[0-9]{1,3}(?:\\.[0-9]{1,5}){0,3}\\z"
const RE_DEVICE := "\\A(?:[A-Z]{1,4}-?[A-Z0-9]{2,10}|Pixel [0-9]{1,2}(?: ?(?:Pro XL|Pro|XL|a|Fold))?)\\z"
const RE_HOST := "\\A[a-z0-9](?:[a-z0-9-]{0,40}[a-z0-9])?(?:\\.[a-z0-9](?:[a-z0-9-]{0,40}[a-z0-9])?){1,6}\\z"

## Tests: a script with the LocalStt functions (stats, bench, ...). null = load LOCAL_STT_PATH when it exists.
static var stt_script_override: GDScript = null
## Tests: (text: String) -> void. Default DisplayServer.clipboard_set.
static var clipboard_hook: Callable = Callable()
## Tests: () -> {ok: bool, wav: PackedByteArray, duration: float}; may be a coroutine. Default Recorder.
static var record_hook: Callable = Callable()

## Numbers of this app run (bench results, batteries): a reopened sheet shows them again. Numbers only.
static var _session: Dictionary = {}


static func reset_for_tests() -> void:
	stt_script_override = null
	clipboard_hook = Callable()
	record_hook = Callable()
	_session = {}


## Opens the sheet; returns it.
static func open(host: Node) -> Node:
	var body := DiagBody.new()
	body.build()
	var sh: Sheet = Sheet.open(host, TXT_TITLE, body, [{"id": "close", "text": "닫기", "kind": "flat"}])
	# `closed` is sent the moment the sheet starts to close (the fade-out takes 200 ms more): from then on nothing may land in it
	sh.closed.connect(body.on_sheet_closed)
	return sh


# ---------------------------------------------------------------- the copied block

## The text that [결과 복사] puts on the clipboard (docs 4.3). `extra` = {bench20, bench60, battery_start, battery_end}:
## the two bench entries are the dictionaries `LocalStt.bench` returns, the batteries are numbers.
static func report_text(extra: Dictionary = {}) -> String:
	var st: Dictionary = _stats()
	var have_stt: bool = _stt() != null
	var lines: PackedStringArray = PackedStringArray()
	lines.append("hoehwa-diag 1")
	var mem: Dictionary = OS.get_memory_info()
	var ram_mb: int = int(round(float(int(mem.get("physical", 0))) / 1000000.0))
	lines.append("app=%s platform=%s os=%s device=%s cores=%d ram_mb=%d" % [
		app_token(ProjectSettings.get_setting("application/config/version", "")), platform_token(OS.get_name()),
		os_token(OS.get_version()), device_token(OS.get_model_name()), OS.get_processor_count(), maxi(ram_mb, 0)])
	var ver: String = version_token(st.get("bridge_version", null))
	if ver == NO_VALUE:
		ver = version_token(_bridge_static("version"))
	var patch: String = NO_VALUE
	if typeof(st.get("abort_patch", null)) in [TYPE_INT, TYPE_FLOAT]:
		patch = "1" if int(st["abort_patch"]) == 1 else "0"
	elif ver != NO_VALUE:
		patch = "1" if ver.contains("+abort-sched") else "0"
	var cpu: String = cpu_token(_bridge_static("cpu_features"))
	lines.append("bridge=%s abort_patch=%s cpu=%s" % [ver, patch, cpu])
	var ud: String = OS.get_user_data_dir()
	lines.append("user_dir_internal=%d" % (1 if (ud.begins_with("/data/user/") or ud.begins_with("/data/data/")) else 0))
	lines.append(_model_line(st))
	var ds: Dictionary = ModelStore.stats()
	lines.append("dl_requests=%s dl_resumed=%s dl_resume_mb=%s dl_last_host=%s dl_last_err=%s" % [
		_num(ds.get("requests", null)), _num(ds.get("resumed", null)), _num(_mb(ds.get("resume_bytes", null))),
		host_token(ds.get("last_host", null)), err_token(ds.get("last_err", null))])
	lines.append("stt_runs=%s stt_ok=%s timeouts=%s engine_err=%s aborted=%s load_count=%s unload_count=%s load_ms_first=%s" % [
		_num(st.get("runs", null)), _num(st.get("ok", null)), _num(st.get("timeouts", null)), _num(st.get("engine_err", null)),
		_num(st.get("aborted", null)), _num(st.get("load_count", null)), _num(st.get("unload_count", null)), _num(st.get("load_ms_first", null))])
	lines.append("stt_ms_p50=%s stt_ms_p95=%s stt_ms_max=%s audio_ms_p50=%s rtf_p50=%s" % [
		_num(st.get("stt_ms_p50", null)), _num(st.get("stt_ms_p95", null)), _num(st.get("stt_ms_max", null)),
		_num(st.get("audio_ms_p50", null)), _num(st.get("rtf_p50", null))])
	lines.append("rss_mb_before_load=%s rss_mb_after_load=%s rss_mb_peak=%s" % [
		_num(st.get("rss_mb_before_load", null)), _num(st.get("rss_mb_after_load", null)), _num(st.get("rss_mb_peak", null))])
	if not have_stt:
		lines.append("stt=missing")
	lines.append(_bench20_line(extra.get("bench20", null)))
	lines.append(_bench60_line(extra.get("bench60", null), extra.get("battery_start", null), extra.get("battery_end", null)))
	lines.append("recent=" + _recent(st.get("recent", null)))
	lines.append("api_sent_since_start=%d phone_served=%d" % [int(Api.sent_count), int(LocalApi.served_count)])
	var pos: Dictionary = CourseStore.pos()
	var review: Variant = Store.progress.get("review", [])
	lines.append("course_pos=w%dd%d review_cards=%d" % [int(pos.get("w", 0)), int(pos.get("d", 0)), (review as Array).size() if review is Array else 0])
	return "\n".join(lines) + "\n"


static func _model_line(st: Dictionary) -> String:
	var id: String = ModelStore.active_id()
	var inf: Dictionary = ModelStore.info(id)
	var state: String = str(inf.get("state", "missing"))
	if not _STATES.has(state):
		state = NO_VALUE
	var bytes: int = int(inf.get("bytes", 0)) if state == "ready" else int(inf.get("part_bytes", 0))
	var params: String = str(st.get("params_state", ""))
	if not _PARAM_STATES.has(params):
		params = NO_VALUE
	return "stt_model=%s state=%s file_mb=%s verified=%d params=%s beam=%s phone_off=%d score_where=%s" % [
		model_id_token(id), state, _num(_mb(bytes)), 1 if state == "ready" else 0, params, _num(st.get("beam", null)),
		1 if SettingsView.phone_scoring_off() else 0, Route.score_where()]


static func _bench20_line(b: Variant) -> String:
	if not (b is Dictionary) or (b as Dictionary).is_empty():
		return "bench20 -"
	var d: Dictionary = b
	return "bench20 n=%s ok=%s p50_ms=%s p95_ms=%s max_ms=%s" % [
		_num(d.get("n", null)), _num(d.get("ok", null)), _num(d.get("ms_p50", null)), _num(d.get("ms_p95", null)), _num(d.get("ms_max", null))]


static func _bench60_line(b: Variant, bat_start: Variant, bat_end: Variant) -> String:
	var bs: String = _battery(bat_start)
	var be: String = _battery(bat_end)
	var empty: bool = not (b is Dictionary) or (b as Dictionary).is_empty()
	if empty and bs == NO_VALUE and be == NO_VALUE:
		return "bench60 -"
	var d: Dictionary = b if b is Dictionary else {}
	var minutes: Variant = null
	if typeof(d.get("seconds", null)) in [TYPE_INT, TYPE_FLOAT]:
		minutes = float(d["seconds"]) / 60.0
	return "bench60 n=%s ok=%s fail=%s minutes=%s rss_mb_peak=%s battery_start=%s battery_end=%s" % [
		_num(d.get("n", null)), _num(d.get("ok", null)), _num(d.get("fail", null)), _num(minutes), _num(d.get("rss_mb_peak", null)), bs, be]


static func _battery(v: Variant) -> String:
	if typeof(v) in [TYPE_INT, TYPE_FLOAT] and is_finite(float(v)):
		return str(clampi(int(round(float(v))), 0, 100))
	return NO_VALUE


static func _recent(v: Variant) -> String:
	if not (v is Array):
		return NO_VALUE
	var arr: Array = v
	var out: PackedStringArray = PackedStringArray()
	for e in arr.slice(maxi(0, arr.size() - RECENT_MAX)):
		if e is Dictionary:
			var d: Dictionary = e
			out.append("%s/%s/%s" % [_num(d.get("score", null)), _num(d.get("n", null)), _num(d.get("ok", null))])
	return ",".join(out) if not out.is_empty() else NO_VALUE


# ---------------------------------------------------------------- value filters (nothing but numbers and whitelisted words)

## A number as an integer or with two decimals; anything else (text, bool, null, NaN) is "-".
static func _num(v: Variant) -> String:
	if typeof(v) != TYPE_INT and typeof(v) != TYPE_FLOAT:
		return NO_VALUE
	var f: float = float(v)
	if not is_finite(f):
		return NO_VALUE
	if is_equal_approx(f, round(f)):
		return "%d" % int(round(f))
	return "%.2f" % f


static func _mb(bytes: Variant) -> Variant:
	if typeof(bytes) != TYPE_INT and typeof(bytes) != TYPE_FLOAT:
		return null
	return float(bytes) / 1000000.0


## `v` when it is a String that `pattern` matches from its first to its last character, else "". Nothing is cleaned up:
## a string that is not exactly of the expected form is rejected whole.
static func _whole(v: Variant, pattern: String) -> String:
	if typeof(v) != TYPE_STRING:
		return ""
	var t: String = String(v)
	var re := RegEx.new()
	if t == "" or re.compile(pattern) != OK:
		return ""
	var m: RegExMatch = re.search(t)
	if m == null or m.get_start() != 0 or m.get_end() != t.length():
		return ""
	return t


## The bridge version as one token "<n>-<commit>[+<patch>]..." (from "bridge 1 / whisper.cpp abc1234 +abort-sched"), else "-".
static func version_token(v: Variant) -> String:
	if _whole(v, RE_BRIDGE) == "":
		return NO_VALUE
	var re := RegEx.new()
	re.compile(RE_BRIDGE)
	var m: RegExMatch = re.search(String(v))
	return "%s-%s%s" % [m.get_string(1), m.get_string(2), m.get_string(3).replace(" ", "")]


static func app_token(v: Variant) -> String:
	var t: String = _whole(v, RE_APP)
	return t if t != "" else NO_VALUE


static func platform_token(v: Variant) -> String:
	return String(v) if typeof(v) == TYPE_STRING and _PLATFORMS.has(String(v)) else NO_VALUE


static func os_token(v: Variant) -> String:
	var t: String = _whole(v, RE_OS)
	return t if t != "" else NO_VALUE


## The phone model the OS reports (Build.MODEL): a maker's model code ("SM-S921N", "CPH2451") or "Pixel <n>[ Pro|XL|a|Fold]";
## anything else (a name, a sentence, a path) reads "-". Words are joined by "_".
static func device_token(v: Variant) -> String:
	var t: String = _whole(v, RE_DEVICE)
	return t.replace(" ", "_") if t != "" else NO_VALUE


## CPU features of the bridge: every word must be a known feature name, else "-".
static func cpu_token(v: Variant) -> String:
	if typeof(v) != TYPE_STRING or String(v).strip_edges() == "":
		return NO_VALUE
	var out: PackedStringArray = PackedStringArray()
	for w in String(v).strip_edges().split(" ", false):
		if not _CPU_FEATURES.has(String(w)):
			return NO_VALUE
		out.append(String(w))
	return "+".join(out)


static func model_id_token(v: Variant) -> String:
	return String(v) if typeof(v) == TYPE_STRING and not ModelStore.model(String(v)).is_empty() else NO_VALUE


## The download host as one of the model manifest's own host names (the registered name a redirect host belongs to, by the same
## suffix rule ModelStore uses: "release-assets.githubusercontent.com" reads "githubusercontent.com"); anything else is "-".
## 127.0.0.1 only while ModelStore.allow_http_loopback is on (tests).
static func host_token(v: Variant) -> String:
	var t: String = _whole(v, RE_HOST)
	if t == "":
		return NO_VALUE
	var best: String = ""
	for h in ModelStore.manifest().get("hosts", []):
		var suffix: String = str(h)
		if (t == suffix or t.ends_with("." + suffix)) and suffix.length() > best.length():
			best = suffix
	if best != "":
		return best
	if ModelStore.allow_http_loopback and t == "127.0.0.1":
		return t
	return NO_VALUE


## The last download error: one of ModelStore's own codes (or "cancelled"), else "-".
static func err_token(v: Variant) -> String:
	if typeof(v) != TYPE_STRING:
		return NO_VALUE
	var t: String = String(v)
	return t if ModelStore.ERR_TEXT.has(t) or t == "cancelled" else NO_VALUE


# ---------------------------------------------------------------- LocalStt and the bridge, looked up by name

static func _stt() -> GDScript:
	var s: GDScript = stt_script_override
	if s == null and ResourceLoader.exists(LOCAL_STT_PATH):
		var r: Variant = load(LOCAL_STT_PATH)
		s = r if r is GDScript else null
	if s == null or not s.has_method("stats"):
		return null
	return s


static func _stats() -> Dictionary:
	var s: GDScript = _stt()
	if s == null:
		return {}
	var r: Variant = s.call("stats")
	return r if r is Dictionary else {}


## A static function of WhisperBridge (version, cpu_features) without naming the class: null when the bridge is not in this build.
static func _bridge_static(method: String) -> Variant:
	if not ClassDB.class_exists("WhisperBridge") or not ClassDB.can_instantiate("WhisperBridge"):
		return null
	var o: Object = ClassDB.instantiate("WhisperBridge")
	if o == null:
		return null
	var r: Variant = null
	if o.has_method(method):
		r = o.call(method)
	if not (o is RefCounted):
		o.free()
	return r


# ---------------------------------------------------------------- long jobs
# A coroutine that belongs to a node breaks when the node is freed while it waits ("Resumed function after await, but class
# instance is gone"). So the two waits of the sheet (the recording hook, LocalStt.bench) run here, in static functions that
# belong to no node, and hand the result back through a DiagJob that holds the sheet only weakly. A closed, freed or detached
# sheet (or a job cancelled by it) simply drops the result.

static func _run_record(job: DiagJob) -> void:
	var r: Variant = await record_hook.call()
	var b: Variant = job.alive()
	if b != null:
		b.record_done(r)


static func _run_bench(job: DiagJob, stt: GDScript, wav: PackedByteArray, n: int, key: String) -> void:
	var res: Variant = await stt.call("bench", wav, TARGET, n, Callable(job, "on_step"))
	var b: Variant = job.alive()
	if b != null:
		b.bench_done(key, res)


class DiagJob:
	extends RefCounted
	var body: WeakRef = null
	var cancelled: bool = false
	var total: int = 0

	## The sheet body while it is still open and in the tree, else null.
	func alive() -> Variant:
		if cancelled or body == null:
			return null
		var b: Variant = body.get_ref()
		if b == null or not is_instance_valid(b) or not (b as Node).is_inside_tree() or not b.is_open():
			return null
		return b

	## LocalStt.bench reports its progress here (any argument shape: the first number is how many are done).
	func on_step(a: Variant = null, _b: Variant = null, _c: Variant = null) -> void:
		var b: Variant = alive()
		if b != null:
			b.step(a, total)


# ---------------------------------------------------------------- the sheet content

class DiagBody:
	extends VBoxContainer

	var rec_btn: Button
	var bench20_btn: Button
	var bench60_btn: Button
	var copy_btn: Button
	var bat_start: SpinBox
	var bat_end: SpinBox
	var rec_label: Label
	var result20: Label
	var result60: Label
	var note: Label
	var progress: Label
	var wav: PackedByteArray = PackedByteArray()
	var extra: Dictionary = {}

	var _busy: bool = false
	var _recording: bool = false
	var _job: DiagJob = null
	var _closed: bool = false


	func build() -> void:
		name = "SttDiagBody"
		add_theme_constant_override("separation", 10)
		add_child(UI.label(SttDiagSheet.TXT_INTRO, "Small"))
		add_child(UI.label(SttDiagSheet.TXT_READ))
		var target := UI.label(SttDiagSheet.TARGET, "Strong")
		target.name = "DiagTarget"
		add_child(target)
		rec_btn = UI.button("한 문장 녹음", "primary", Pal.PRIMARY)
		rec_btn.name = "DiagRecBtn"
		rec_btn.pressed.connect(_on_rec)
		add_child(rec_btn)
		rec_label = UI.label(SttDiagSheet.TXT_NOT_RECORDED, "Small")
		rec_label.name = "DiagRecState"
		add_child(rec_label)
		bench20_btn = UI.button("%d회 속도 시험" % SttDiagSheet.BENCH_SHORT, "soft", Pal.PRIMARY)
		bench20_btn.name = "DiagBench20Btn"
		bench20_btn.pressed.connect(_on_bench.bind(SttDiagSheet.BENCH_SHORT, "bench20"))
		add_child(bench20_btn)
		result20 = UI.label("", "Small")
		result20.name = "DiagResult20"
		result20.visible = false
		add_child(result20)
		bench60_btn = UI.button("%d회 연속 시험" % SttDiagSheet.BENCH_LONG, "soft", Pal.PRIMARY)
		bench60_btn.name = "DiagBench60Btn"
		bench60_btn.pressed.connect(_on_bench.bind(SttDiagSheet.BENCH_LONG, "bench60"))
		add_child(bench60_btn)
		result60 = UI.label("", "Small")
		result60.name = "DiagResult60"
		result60.visible = false
		add_child(result60)
		progress = UI.label("", "Small")
		progress.name = "DiagProgress"
		progress.visible = false
		add_child(progress)
		add_child(UI.label(SttDiagSheet.TXT_BATTERY_NOTE, "Small"))
		bat_start = _battery_box("시작 배터리 %", "DiagBatStart")
		bat_end = _battery_box("끝 배터리 %", "DiagBatEnd")
		copy_btn = UI.button("결과 복사", "primary", Pal.PRIMARY)
		copy_btn.name = "DiagCopyBtn"
		copy_btn.pressed.connect(_on_copy)
		add_child(copy_btn)
		note = UI.label("", "Small")
		note.name = "DiagNote"
		note.visible = false
		add_child(note)
		var saved: Dictionary = SttDiagSheet._session
		for k in ["bench20", "bench60"]:
			if saved.get(k, null) is Dictionary:
				extra[k] = (saved[k] as Dictionary).duplicate()
		_show_results()
		Recorder.finished.connect(_on_recorder_finished)
		UI.fix_cjk(self)


	func _battery_box(caption: String, node_name: String) -> SpinBox:
		var sb := SpinBox.new()
		sb.name = node_name
		sb.min_value = 0
		sb.max_value = 100
		sb.step = 1
		sb.rounded = true
		sb.suffix = "%"
		sb.custom_minimum_size.y = maxf(48.0, Ds.touch_min())
		sb.accessibility_name = caption
		# Empty until the person enters a number. `entered` says so on its own, apart from what the box writes into its text:
		# true after a typed edit, Enter, a changed value (arrow keys) or a text that differs from what the box itself last showed.
		var le: LineEdit = sb.get_line_edit()
		le.placeholder_text = SttDiagSheet.TXT_BATTERY_EMPTY
		le.text = ""
		sb.set_meta("entered", false)
		sb.set_meta("base", "")
		sb.ready.connect(func() -> void:
			le.text = "" # the box writes its 0 when it enters the tree
			sb.set_meta("base", ""))
		sb.value_changed.connect(func(v: float) -> void:
			le.text = str(int(round(v))) # the box itself redraws its text only on the next draw
			sb.set_meta("entered", true)
			sb.set_meta("base", le.text))
		le.text_changed.connect(func(_t: String) -> void: sb.set_meta("entered", true))
		le.text_submitted.connect(func(_t: String) -> void: sb.set_meta("entered", true))
		# the box rewrites its own text ("0") when the field gets or loses the focus: that text is not an entry
		le.focus_entered.connect(func() -> void: sb.set_meta("focused", true))
		le.focus_exited.connect(func() -> void: sb.set_meta("focused", true))
		add_child(UI.field(caption, sb))
		return sb


	## The number the person entered in `sb`, clamped to 0..100 (typed text is applied first); null = nothing entered.
	func _battery_value(sb: SpinBox) -> Variant:
		var typed: String = sb.get_line_edit().text.replace("%", "").strip_edges()
		var base: String = str(sb.get_meta("base", "")).replace("%", "").strip_edges()
		var own_text: bool = bool(sb.get_meta("focused", false)) and typed == str(int(round(sb.value))) # the box's own refresh
		var entered: bool = bool(sb.get_meta("entered", false)) or (typed != "" and typed != base and not own_text)
		if not entered or typed == "" or not typed.is_valid_float():
			return null
		sb.apply()
		return clampi(int(round(sb.value)), 0, 100)


	func is_open() -> bool:
		return not _closed


	## The sheet started to close (Sheet.closed): drop a bench or recording hook still running, cancel a live recording.
	func on_sheet_closed(_result: Variant = null) -> void:
		_closed = true
		_stop_work()
		for n in find_children("*", "BaseButton", true, false):
			(n as BaseButton).disabled = true
		for n in find_children("*", "SpinBox", true, false):
			(n as SpinBox).editable = false


	func _exit_tree() -> void:
		_closed = true
		_stop_work()
		if Recorder.finished.is_connected(_on_recorder_finished):
			Recorder.finished.disconnect(_on_recorder_finished)


	func _stop_work() -> void:
		if _job != null:
			_job.cancelled = true
		if _recording and Recorder.recording and Recorder.owner_id == get_instance_id():
			Recorder.cancel()
		_recording = false


	func _say(text: String) -> void:
		note.text = text
		note.visible = text != ""


	func _lock(on: bool) -> void:
		_busy = on
		rec_btn.disabled = on
		bench20_btn.disabled = on
		bench60_btn.disabled = on


	# -------- recording (memory only)

	func _on_rec() -> void:
		if _closed or _busy:
			return
		if SttDiagSheet.record_hook.is_valid():
			_lock(true)
			_say("")
			_job = _new_job(0)
			SttDiagSheet._run_record(_job)
			return
		if _recording:
			Recorder.end() # second press: stop now
			return
		if Recorder.recording or Recorder.stopping:
			return
		_say("")
		if not Recorder.begin(get_instance_id()):
			_say(SttDiagSheet.TXT_REC_FAIL)
			return
		_recording = true
		rec_btn.text = "녹음 끝내기"
		rec_label.text = "녹음 중이에요. 문장을 읽고 [녹음 끝내기]를 눌러 주세요."
		get_tree().create_timer(SttDiagSheet.RECORD_SEC).timeout.connect(_auto_stop)


	func _auto_stop() -> void:
		if is_instance_valid(self) and _recording and Recorder.recording and Recorder.owner_id == get_instance_id():
			Recorder.end()


	func _on_recorder_finished(result: Dictionary) -> void:
		if not _recording:
			return
		_recording = false
		rec_btn.text = "한 문장 녹음"
		_take_recording(result)


	func _take_recording(r: Variant) -> void:
		var good: bool = false
		if r is Dictionary:
			var d: Dictionary = r
			var w: Variant = d.get("wav", null)
			if bool(d.get("ok", false)) and w is PackedByteArray and not (w as PackedByteArray).is_empty():
				if bool(d.get("silent", false)):
					wav = PackedByteArray()
					rec_label.text = SttDiagSheet.TXT_NOT_RECORDED
					_say(SttDiagSheet.TXT_REC_SILENT)
					return
				wav = w
				var secs: float = float(d.get("duration", 0.0))
				rec_label.text = "녹음했어요 · %.1f초" % clampf(secs, 0.0, 99.0) if secs > 0.0 else "녹음했어요."
				good = true
		if not good:
			wav = PackedByteArray()
			rec_label.text = SttDiagSheet.TXT_NOT_RECORDED
			_say(SttDiagSheet.TXT_REC_FAIL)


	# -------- speed tests

	func _on_bench(n: int, key: String) -> void:
		if _closed or _busy:
			return
		var stt: GDScript = SttDiagSheet._stt()
		if stt == null or not stt.has_method("bench"):
			_say(SttDiagSheet.TXT_NO_STT)
			return
		if wav.is_empty():
			_say(SttDiagSheet.TXT_NEED_RECORD)
			return
		_say("")
		_lock(true)
		progress.visible = true
		progress.text = SttDiagSheet.TXT_RUNNING + CourseModel.progress_label("", 0, n)
		_job = _new_job(n)
		SttDiagSheet._run_bench(_job, stt, wav, n, key)


	func _new_job(n: int) -> DiagJob:
		if _job != null:
			_job.cancelled = true
		var j := DiagJob.new()
		j.body = weakref(self)
		j.total = n
		return j


	## From the job: the recording hook returned.
	func record_done(r: Variant) -> void:
		_lock(false)
		_take_recording(r)


	## From the job: the bench returned (not called when the sheet was closed meanwhile).
	func bench_done(key: String, res: Variant) -> void:
		progress.visible = false
		_lock(false)
		if not (res is Dictionary) or not (res as Dictionary).has("n"):
			_say(SttDiagSheet.TXT_BENCH_FAIL)
			return
		extra[key] = _numbers_only(res)
		SttDiagSheet._session[key] = (extra[key] as Dictionary).duplicate()
		_show_results()


	## From the job: bench progress; `a` = how many runs are done.
	func step(a: Variant, total: int) -> void:
		if not progress.visible:
			return
		if typeof(a) == TYPE_INT or typeof(a) == TYPE_FLOAT:
			progress.text = SttDiagSheet.TXT_RUNNING + CourseModel.progress_label("", int(a), total)


	static func _numbers_only(res: Dictionary) -> Dictionary:
		var out: Dictionary = {}
		for k in ["n", "ok", "fail", "ms_p50", "ms_p95", "ms_max", "rss_mb_peak", "seconds"]:
			var v: Variant = res.get(k, null)
			if (typeof(v) == TYPE_INT or typeof(v) == TYPE_FLOAT) and is_finite(float(v)):
				out[k] = v
		return out


	# -------- what the person reads

	static func _sec_text(ms: Variant) -> String:
		if typeof(ms) != TYPE_INT and typeof(ms) != TYPE_FLOAT:
			return "-"
		return "%.1f초" % clampf(float(ms) / 1000.0, 0.0, 99.0)


	static func _shown(v: Variant) -> String:
		if typeof(v) != TYPE_INT and typeof(v) != TYPE_FLOAT or not is_finite(float(v)):
			return "-"
		return str(clampi(int(round(float(v))), 0, SttDiagSheet.SHOWN_MAX))


	func _memory_text() -> String:
		var st: Dictionary = SttDiagSheet._stats()
		var a: Variant = st.get("rss_mb_after_load", null)
		var b: Variant = st.get("rss_mb_before_load", null)
		if (typeof(a) == TYPE_INT or typeof(a) == TYPE_FLOAT) and (typeof(b) == TYPE_INT or typeof(b) == TYPE_FLOAT) and float(a) > 0.0:
			return " · 메모리 +%s MB" % _shown(maxf(float(a) - float(b), 0.0))
		return ""


	func _show_results() -> void:
		var d20: Variant = extra.get("bench20", null)
		result20.visible = d20 is Dictionary and not (d20 as Dictionary).is_empty()
		if result20.visible:
			var d: Dictionary = d20
			var fails: Variant = d["fail"] if d.has("fail") else (float(d.get("n", 0)) - float(d.get("ok", 0)))
			result20.text = "%s회 · 중앙값 %s · 가장 느린 %s · 실패 %s%s" % [_shown(d.get("n", null)), _sec_text(d.get("ms_p50", null)),
				_sec_text(d.get("ms_max", null)), _shown(fails), _memory_text()]
		var d60: Variant = extra.get("bench60", null)
		result60.visible = d60 is Dictionary and not (d60 as Dictionary).is_empty()
		if result60.visible:
			var d: Dictionary = d60
			var fails: Variant = d["fail"] if d.has("fail") else (float(d.get("n", 0)) - float(d.get("ok", 0)))
			var mins: String = "-"
			if typeof(d.get("seconds", null)) in [TYPE_INT, TYPE_FLOAT]:
				mins = "%.1f분" % clampf(float(d["seconds"]) / 60.0, 0.0, 99.0)
			result60.text = "%s회 · %s · 실패 %s%s" % [_shown(d.get("n", null)), mins, _shown(fails), _memory_text()]


	# -------- copy

	func _on_copy() -> void:
		if _closed:
			return
		var ex: Dictionary = extra.duplicate()
		var b_start: Variant = _battery_value(bat_start)
		var b_end: Variant = _battery_value(bat_end)
		if b_start != null:
			ex["battery_start"] = b_start
		if b_end != null:
			ex["battery_end"] = b_end
		var text: String = SttDiagSheet.report_text(ex)
		if SttDiagSheet.clipboard_hook.is_valid():
			SttDiagSheet.clipboard_hook.call(text)
		else:
			DisplayServer.clipboard_set(text)
		_say(SttDiagSheet.TXT_COPIED)
		Toast.ok(SttDiagSheet.TXT_COPIED)
