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
const TXT_BATTERY_NOTE := "배터리 %는 시험 전후에 직접 적어 주세요(폰 화면 위쪽 숫자)."

const _STATES := ["missing", "partial", "downloading", "verifying", "ready", "corrupt"]
const _PARAM_STATES := ["calibrated", "uncalibrated"]

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
	return Sheet.open(host, TXT_TITLE, body, [{"id": "close", "text": "닫기", "kind": "flat"}])


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
		_free(str(ProjectSettings.get_setting("application/config/version", ""))), _free(OS.get_name()),
		_free(OS.get_version()), _free(OS.get_model_name()), OS.get_processor_count(), maxi(ram_mb, 0)])
	var ver: String = _version_token(st.get("bridge_version", null))
	if ver == NO_VALUE:
		ver = _version_token(_bridge_static("version"))
	var patch: String = NO_VALUE
	if typeof(st.get("abort_patch", null)) in [TYPE_INT, TYPE_FLOAT]:
		patch = "1" if int(st["abort_patch"]) == 1 else "0"
	elif ver != NO_VALUE:
		patch = "1" if ver.contains("+abort-sched") else "0"
	var cpu_v: Variant = _bridge_static("cpu_features")
	var cpu: String = _free(str(cpu_v).strip_edges().replace(" ", "+")) if cpu_v != null else NO_VALUE
	lines.append("bridge=%s abort_patch=%s cpu=%s" % [ver, patch, cpu])
	var ud: String = OS.get_user_data_dir()
	lines.append("user_dir_internal=%d" % (1 if (ud.begins_with("/data/user/") or ud.begins_with("/data/data/")) else 0))
	lines.append(_model_line(st))
	var ds: Dictionary = ModelStore.stats()
	lines.append("dl_requests=%s dl_resumed=%s dl_resume_mb=%s dl_last_host=%s dl_last_err=%s" % [
		_num(ds.get("requests", null)), _num(ds.get("resumed", null)), _num(_mb(ds.get("resume_bytes", null))),
		_word(ds.get("last_host", null), "^[a-z0-9.-]{1,80}$"), _word(ds.get("last_err", null), "^[a-z_]{1,24}$")])
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
		_free(id), state, _num(_mb(bytes)), 1 if state == "ready" else 0, params, _num(st.get("beam", null)),
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


## A string that matches `pattern` as a whole (lower-case words, host names, codes); anything else is "-".
static func _word(v: Variant, pattern: String) -> String:
	if typeof(v) != TYPE_STRING:
		return NO_VALUE
	var re := RegEx.new()
	if re.compile(pattern) != OK or re.search(String(v)) == null:
		return NO_VALUE
	return String(v)


## The bridge version as one token: only lower-case letters, digits and . / + _ - (the real text is
## "bridge 1 / whisper.cpp abc1234 +abort-sched"); spaces and slashes become "_".
static func _version_token(v: Variant) -> String:
	var w: String = _word(v, "^[a-z0-9 ./+_-]{1,80}$")
	if w == NO_VALUE:
		return NO_VALUE
	return w.replace(" / ", "_").replace(" ", "_").replace("/", "_")


## A string the OS gave (version, device name): characters outside letters, digits and . _ + - become "_".
static func _free(s: String) -> String:
	var out: String = ""
	for ch in s.strip_edges():
		var c: int = ch.unicode_at(0)
		var good: bool = (c >= 48 and c <= 57) or (c >= 65 and c <= 90) or (c >= 97 and c <= 122) or ch in [".", "_", "+", "-"]
		out += ch if good else "_"
	out = out.substr(0, 40)
	return out if out != "" else NO_VALUE


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
	var _total: int = 0
	var _touched: Dictionary = {"start": false, "end": false}


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
		bat_start = _battery_box("시작 배터리 %", "DiagBatStart", "start")
		bat_end = _battery_box("끝 배터리 %", "DiagBatEnd", "end")
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


	func _battery_box(caption: String, node_name: String, which: String) -> SpinBox:
		var sb := SpinBox.new()
		sb.name = node_name
		sb.min_value = 0
		sb.max_value = 100
		sb.step = 1
		sb.rounded = true
		sb.suffix = "%"
		sb.custom_minimum_size.y = maxf(48.0, Ds.touch_min())
		sb.accessibility_name = caption
		sb.value_changed.connect(func(_v: float) -> void: _touched[which] = true)
		add_child(UI.field(caption, sb))
		return sb


	func _exit_tree() -> void:
		if Recorder.finished.is_connected(_on_recorder_finished):
			Recorder.finished.disconnect(_on_recorder_finished)
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
		if _busy:
			return
		if SttDiagSheet.record_hook.is_valid():
			_lock(true)
			_say("")
			var r: Variant = await SttDiagSheet.record_hook.call()
			if not is_instance_valid(self):
				return
			_lock(false)
			_take_recording(r)
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
		if _busy:
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
		_total = n
		progress.visible = true
		progress.text = "시험 중이에요… 0 / %d" % n
		var res: Variant = await stt.call("bench", wav, SttDiagSheet.TARGET, n, Callable(self, "_on_step"))
		if not is_instance_valid(self):
			return
		progress.visible = false
		_lock(false)
		if not (res is Dictionary) or not (res as Dictionary).has("n"):
			_say(SttDiagSheet.TXT_BENCH_FAIL)
			return
		extra[key] = _numbers_only(res)
		SttDiagSheet._session[key] = (extra[key] as Dictionary).duplicate()
		_show_results()


	## LocalStt.bench reports its progress here (any argument shape: the first number is how many are done).
	func _on_step(a: Variant = null, _b: Variant = null, _c: Variant = null) -> void:
		if not is_instance_valid(self) or not progress.visible:
			return
		if typeof(a) == TYPE_INT or typeof(a) == TYPE_FLOAT:
			progress.text = "시험 중이에요… %d / %d" % [clampi(int(a), 0, _total), _total]


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
		var ex: Dictionary = extra.duplicate()
		if bool(_touched["start"]):
			ex["battery_start"] = clampi(int(bat_start.value), 0, 100)
		if bool(_touched["end"]):
			ex["battery_end"] = clampi(int(bat_end.value), 0, 100)
		var text: String = SttDiagSheet.report_text(ex)
		if SttDiagSheet.clipboard_hook.is_valid():
			SttDiagSheet.clipboard_hook.call(text)
		else:
			DisplayServer.clipboard_set(text)
		_say(SttDiagSheet.TXT_COPIED)
		Toast.ok(SttDiagSheet.TXT_COPIED)
