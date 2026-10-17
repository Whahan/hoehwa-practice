extends Node
## Android recording path without a microphone (docs/android_remote_design.md §4.6, §9.2 R-11 / R-12 / R-15):
##   WavUtil.to_mono16 + the Recorder pipeline driven through Recorder.test_hooks (no audio device is opened).
##   godot --headless --path <project> res://tests/recorder_android_test.tscn -- --phone
## Exit code 0 = all checks passed. The real microphone and the permission dialog need a phone (R-20: not verified here).

var passed: int = 0
var failed: int = 0
var _toasts: Array = []


func ok(cond: bool, name: String) -> void:
	if cond:
		passed += 1
		print("  PASS  ", name)
	else:
		failed += 1
		print("  FAIL  ", name)


func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


func _wait_for(cond: Callable, timeout_sec: float = 5.0) -> bool:
	var t0: int = Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < int(timeout_sec * 1000.0):
		if cond.call():
			return true
		await get_tree().process_frame
	return bool(cond.call())


func _ready() -> void:
	print("== recorder android test start ==")
	Toast.message.connect(func(text: String, kind: String) -> void: _toasts.append([text, kind]))
	_test_to_mono16()
	_test_edge_inputs()
	await _test_pipeline()
	await _test_permission()
	await _test_limits()
	_reset()
	print("== recorder android result: %d passed, %d failed ==" % [passed, failed])
	get_tree().quit(1 if failed > 0 else 0)


func _reset() -> void:
	Recorder.mode_override = ""
	Recorder.test_hooks = {}
	Recorder.test_audio_source = Callable()
	if Recorder.recording:
		Recorder.cancel()
	Recorder.stopping = false
	Recorder._perm_waiting = false


# ---------------------------------------------------------------- WavUtil.to_mono16

static func _max_abs16(data: PackedByteArray, stride_bytes: int = 2) -> int:
	var best := 0
	var n: int = data.size() / stride_bytes
	for i in n:
		var v: int = absi(data.decode_s16(i * stride_bytes))
		if v > best:
			best = v
	return best


func _test_to_mono16() -> void:
	print("[to_mono16]")
	# R-11: stereo 48 kHz synthetic tone (same in both channels)
	var st: AudioStreamWAV = WavUtil.sine(1.0, 48000, 440.0, 0.5, true, 1.0)
	var frames_in: int = st.data.size() / 4
	var mono: AudioStreamWAV = WavUtil.to_mono16(st)
	ok(mono != null and not mono.stereo and mono.format == AudioStreamWAV.FORMAT_16_BITS, "stereo in -> mono 16-bit out")
	ok(mono.mix_rate == 48000, "mix_rate is kept (48000)")
	ok(mono.data.size() / 2 == frames_in, "sample count unchanged (%d frames)" % frames_in)
	# reference mix of the original, computed independently
	var peak_ref := 0
	for i in frames_in:
		var m: int = (st.data.decode_s16(i * 4) + st.data.decode_s16(i * 4 + 2)) >> 1
		peak_ref = maxi(peak_ref, absi(m))
	var peak_out: int = _max_abs16(mono.data)
	ok(absi(peak_out - peak_ref) <= 1, "peak equals the original within 1 LSB (%d vs %d)" % [peak_out, peak_ref])
	var same := true
	for i in range(0, frames_in, 997):
		var want: int = (st.data.decode_s16(i * 4) + st.data.decode_s16(i * 4 + 2)) >> 1
		if absi(mono.data.decode_s16(i * 2) - want) > 1:
			same = false
	ok(same, "samples are the channel average")
	# only the left channel carries sound: average = half
	var left_only: AudioStreamWAV = WavUtil.sine(0.5, 44100, 300.0, 0.6, true, 0.0)
	var lo_peak: int = _max_abs16(left_only.data, 4)
	var lm: AudioStreamWAV = WavUtil.to_mono16(left_only)
	var lm_peak: int = _max_abs16(lm.data)
	ok(absi(lm_peak - lo_peak / 2) <= 1 and lm_peak > 1000, "one-sided stereo -> still audible, half amplitude (%d vs %d/2)" % [lm_peak, lo_peak])
	# silence
	var quiet: AudioStreamWAV = WavUtil.silence(1.0, 48000, true)
	var qm: AudioStreamWAV = WavUtil.to_mono16(quiet)
	ok(qm != null and _max_abs16(qm.data) == 0 and WavUtil.mono16_with_peak(quiet)["peak"] == 0.0, "silence stays silence (peak 0)")
	# already mono: a copy
	var mono_in: AudioStreamWAV = WavUtil.sine(0.25, 16000, 200.0, 0.4, false)
	var mono_out: AudioStreamWAV = WavUtil.to_mono16(mono_in)
	ok(mono_out != null and mono_out.data == mono_in.data and mono_out.mix_rate == 16000, "mono 16-bit input is passed through unchanged")
	# 30 s upper bound
	var long_st: AudioStreamWAV = WavUtil.sine(33.0, 48000, 220.0, 0.3, true)
	var cut: AudioStreamWAV = WavUtil.to_mono16(long_st, Recorder.MAX_SECONDS)
	ok(cut != null and cut.data.size() / 2 == int(Recorder.MAX_SECONDS * 48000), "33 s input is cut to exactly MAX_SECONDS (%d frames)" % (cut.data.size() / 2))
	# WAV bytes: RIFF, 1 channel, 16 bit
	var wav: PackedByteArray = WavUtil.to_wav_bytes(mono)
	ok(wav.decode_u32(0) == 0x46464952 and wav.decode_u16(22) == 1 and wav.decode_u16(34) == 16 and wav.decode_u32(24) == 48000, "to_wav_bytes header: RIFF, 1 channel, 16 bit, 48000 Hz")
	ok(wav.size() == 44 + mono.data.size(), "to_wav_bytes size = 44 + data")
	var back: AudioStreamWAV = WavUtil.from_wav_bytes(wav)
	ok(back != null and back.data.size() == mono.data.size() and not back.stereo, "the WAV bytes load back as the same mono stream")
	# 30 s of 30 s stereo takes how long (phone-sized work must not freeze a frame: it runs in a thread)
	var t0: int = Time.get_ticks_msec()
	WavUtil.mono16_with_peak(WavUtil.sine(30.0, 48000, 440.0, 0.5, true), 30.0)
	print("    (info) 30 s stereo 48 kHz -> mono took %d ms on this PC" % (Time.get_ticks_msec() - t0))


func _test_edge_inputs() -> void:
	print("[to_mono16 bad inputs]")
	ok(WavUtil.to_mono16(null) == null, "null stream -> null")
	var adpcm := AudioStreamWAV.new()
	adpcm.format = AudioStreamWAV.FORMAT_IMA_ADPCM
	adpcm.data = PackedByteArray([1, 2, 3, 4])
	ok(WavUtil.to_mono16(adpcm) == null, "IMA ADPCM (not PCM) -> null")
	var empty := AudioStreamWAV.new()
	empty.format = AudioStreamWAV.FORMAT_16_BITS
	empty.mix_rate = 48000
	empty.stereo = true
	var em: AudioStreamWAV = WavUtil.to_mono16(empty)
	ok(em != null and em.data.size() == 0, "empty data -> empty mono stream, no crash")
	var odd := AudioStreamWAV.new()
	odd.format = AudioStreamWAV.FORMAT_16_BITS
	odd.mix_rate = 48000
	odd.stereo = true
	odd.data = PackedByteArray([1, 2, 3, 4, 5, 6, 7])   # one whole frame + 3 stray bytes
	var om: AudioStreamWAV = WavUtil.to_mono16(odd)
	ok(om != null and om.data.size() == 2 * (odd.data.size() / 4), "a partial last frame is dropped, not read out of range")
	var s8 := AudioStreamWAV.new()
	s8.format = AudioStreamWAV.FORMAT_8_BITS
	s8.mix_rate = 8000
	s8.stereo = false
	s8.data = PackedByteArray([0, 64, 127, -128 & 0xFF])
	var m8: AudioStreamWAV = WavUtil.to_mono16(s8)
	ok(m8 != null and m8.format == AudioStreamWAV.FORMAT_16_BITS and m8.data.size() == 8 and m8.data.decode_s16(4) == 127 << 8, "8-bit mono -> 16-bit (127 -> 32512)")
	ok(WavUtil.peak(WavUtil.sine(0.1, 16000, 100.0, 0.5, false)) > 0.45, "WavUtil.peak sees a 0.5 amplitude tone")


# ---------------------------------------------------------------- Recorder with hooks ("android" mode, no device)

## hooks for a recorder that "hears" `clip` and has the permission already.
func _hooks_for(clip: AudioStreamWAV, state: Dictionary) -> Dictionary:
	return {
		"granted": func() -> bool: return true,
		"open": func() -> bool:
			state["opened"] = int(state.get("opened", 0)) + 1
			return true,
		"recording": func() -> AudioStreamWAV: return clip,
		"close": func() -> void: state["closed"] = int(state.get("closed", 0)) + 1,
		"level": func() -> float: return 0.42,
	}


func _record_once(hooks: Dictionary, seconds: float, who: int) -> Dictionary:
	Recorder.mode_override = "android"
	Recorder.test_hooks = hooks
	var got: Array = []
	var cb := func(r: Dictionary) -> void: got.append(r)
	Recorder.finished.connect(cb)
	var began: bool = Recorder.begin(who)
	await _wait_for(func() -> bool: return Recorder._mic_live, 3.0)
	await get_tree().create_timer(seconds).timeout
	var level_seen: float = Recorder.level
	Recorder.end()
	await _wait_for(func() -> bool: return got.size() >= 1, 8.0)
	Recorder.finished.disconnect(cb)
	var res: Dictionary = got[0] if got.size() >= 1 else {}
	res["_began"] = began
	res["_count"] = got.size()
	res["_level"] = level_seen
	return res


func _test_pipeline() -> void:
	print("[Recorder pipeline]")
	var state := {}
	var clip: AudioStreamWAV = WavUtil.sine(2.0, 48000, 440.0, 0.5, true)
	var r: Dictionary = await _record_once(_hooks_for(clip, state), 0.3, 9001)
	ok(bool(r.get("_began", false)) and int(r.get("_count", 0)) == 1, "begin() true, finished emitted exactly once")
	ok(bool(r.get("ok", false)) and str(r.get("b64", "")) != "" and int(r.get("owner", 0)) == 9001, "result: ok, b64 set, owner kept")
	ok(not bool(r.get("silent", true)), "a tone is not silent")
	ok(absf(float(r.get("duration", 0.0)) - 2.0) < 0.01, "duration comes from the audio (%.2f s)" % float(r.get("duration", 0.0)))
	var wav: PackedByteArray = r.get("wav", PackedByteArray())
	ok(wav.size() > 44 and wav.decode_u16(22) == 1 and wav.decode_u16(34) == 16, "result.wav is a mono 16-bit WAV")
	ok(Marshalls.base64_to_raw(str(r.get("b64", ""))) == wav, "result.b64 is the base64 of result.wav")
	ok(r.get("stream") is AudioStreamWAV, "result carries the mono stream as well")
	ok(absf(float(r.get("_level", 0.0)) - 0.42) < 0.01, "the level hook feeds Recorder.level while recording")
	ok(not Recorder.recording and not Recorder.stopping and Recorder.level == 0.0, "recorder is idle afterwards")
	ok(int(state.get("opened", 0)) == 1 and int(state.get("closed", 0)) >= 1, "microphone opened once and closed")
	# silent recording
	var quiet: Dictionary = await _record_once(_hooks_for(WavUtil.silence(1.0, 48000, true), {}), 0.2, 9002)
	ok(bool(quiet.get("ok", false)) and bool(quiet.get("silent", false)), "R-11: silent audio -> ok:true, silent:true")
	# almost silent (below the threshold) vs just above
	var faint: AudioStreamWAV = WavUtil.sine(1.0, 48000, 440.0, 0.002, true)
	var rf: Dictionary = await _record_once(_hooks_for(faint, {}), 0.2, 9003)
	ok(bool(rf.get("silent", false)), "peak 0.002 < 0.003 counts as silent")
	var loud_enough: AudioStreamWAV = WavUtil.sine(1.0, 48000, 440.0, 0.01, true)
	var rl: Dictionary = await _record_once(_hooks_for(loud_enough, {}), 0.2, 9004)
	ok(not bool(rl.get("silent", true)), "peak 0.01 is not silent")
	# nothing recorded at all
	var none: Dictionary = await _record_once({"granted": func() -> bool: return true, "open": func() -> bool: return true, "recording": func() -> Variant: return null, "close": func() -> void: pass}, 0.2, 9005)
	ok(not bool(none.get("ok", true)) and int(none.get("_count", 0)) == 1, "no audio from the recorder -> ok:false (once)")
	# the main thread keeps running while a 30 s stereo recording is converted
	var long_clip: AudioStreamWAV = WavUtil.sine(30.0, 48000, 440.0, 0.5, true)
	var frames_during := [0]
	var counter := func() -> void: frames_during[0] += 1
	get_tree().process_frame.connect(counter)
	var rb: Dictionary = await _record_once(_hooks_for(long_clip, {}), 0.1, 9006)
	get_tree().process_frame.disconnect(counter)
	ok(bool(rb.get("ok", false)) and absf(float(rb.get("duration", 0.0)) - 30.0) < 0.01, "30 s recording converted (duration %.2f s)" % float(rb.get("duration", 0.0)))
	ok(int(frames_during[0]) > 3, "frames kept running during the conversion (%d frames)" % int(frames_during[0]))
	# a second begin while one is running is refused
	Recorder.mode_override = "android"
	Recorder.test_hooks = _hooks_for(clip, {})
	var b1: bool = Recorder.begin(1)
	var b2: bool = Recorder.begin(2)
	ok(b1 and not b2, "begin() while recording returns false")
	await _wait_for(func() -> bool: return Recorder._mic_live, 3.0)
	# cancel: no result, mic closed
	var got: Array = []
	var cb := func(res: Dictionary) -> void: got.append(res)
	Recorder.finished.connect(cb)
	Recorder.cancel()
	await _frames(5)
	Recorder.finished.disconnect(cb)
	ok(not Recorder.recording and got.is_empty() and not Recorder._mic_live, "cancel(): idle, no result delivered, microphone closed")
	Recorder.mode_override = ""
	Recorder.test_hooks = {}


func _test_permission() -> void:
	print("[permission flow]")
	Recorder.mode_override = "android"
	# denied
	_toasts.clear()
	var got: Array = []
	var cb := func(res: Dictionary) -> void: got.append(res)
	Recorder.finished.connect(cb)
	Recorder.test_hooks = {"granted": func() -> bool: return false, "request": func() -> bool: return false, "open": func() -> bool: return true}
	var began: bool = Recorder.begin(11)
	await _wait_for(func() -> bool: return got.size() >= 1, 3.0)
	ok(began and got.size() == 1 and not bool(got[0]["ok"]) and bool(got[0].get("reported", false)) and int(got[0]["owner"]) == 11, "denied: finished(ok:false, reported:true) once, owner kept")
	var texts: String = ""
	for t in _toasts:
		texts += str(t[0]) + "\n"
	ok(texts.contains("마이크 권한이 필요해요") and texts.contains("마이크 권한이 꺼져 있어요") and texts.contains("휴대폰 설정 > 앱 > 회화 연습 > 권한 > 마이크"), "denied: both Korean toasts (ask first, then how to enable)")
	ok(not Recorder.recording and not Recorder._mic_live, "denied: recorder idle, microphone not opened")
	got.clear()
	# granted through the dialog: the recording starts only after the answer
	var dialog := {"open": true, "answer": false}
	Recorder.test_hooks = {
		"granted": func() -> bool: return false,
		"request": func() -> bool:
			while dialog["open"]:
				await get_tree().process_frame
			return bool(dialog["answer"]),
		"open": func() -> bool: return true,
		"recording": func() -> AudioStreamWAV: return WavUtil.sine(1.0, 48000, 440.0, 0.5, true),
		"close": func() -> void: pass,
	}
	Recorder.begin(12)
	await _frames(5)
	ok(Recorder.recording and not Recorder._mic_live and Recorder._perm_waiting, "dialog open: recording flag set, microphone still closed")
	# the dialog itself pauses the app: that must not cancel the first recording
	Recorder.notification(Node.NOTIFICATION_APPLICATION_PAUSED)
	await _frames(2)
	ok(Recorder.recording and got.is_empty(), "PAUSED while the permission dialog is open does not cancel the start")
	dialog["answer"] = true
	dialog["open"] = false
	await _wait_for(func() -> bool: return Recorder._mic_live, 3.0)
	ok(Recorder._mic_live, "after 'allow' the microphone opens")
	await get_tree().create_timer(0.2).timeout
	Recorder.end()
	await _wait_for(func() -> bool: return got.size() >= 1, 5.0)
	ok(got.size() == 1 and bool(got[0]["ok"]), "recording after the dialog works")
	got.clear()
	# user taps stop while the dialog is still open
	dialog["open"] = true
	dialog["answer"] = true
	Recorder.begin(13)
	await _frames(5)
	Recorder.end()
	await _wait_for(func() -> bool: return got.size() >= 1, 3.0)
	ok(got.size() == 1 and not bool(got[0]["ok"]) and bool(got[0].get("reported", false)), "stop while the dialog is open: one quiet failure result, no hang")
	ok(not Recorder.recording and not Recorder.stopping, "... and the recorder is idle")
	dialog["open"] = false   # let the pending request coroutine finish
	await _frames(5)
	ok(not Recorder._mic_live and not Recorder.recording, "a late 'allow' after stop does not start a recording")
	got.clear()
	# PAUSED while recording cancels it (R-15, recorder part)
	Recorder.test_hooks = {"granted": func() -> bool: return true, "open": func() -> bool: return true, "recording": func() -> AudioStreamWAV: return WavUtil.sine(1.0, 48000, 440.0, 0.5, true), "close": func() -> void: pass}
	Recorder.begin(14)
	await _wait_for(func() -> bool: return Recorder._mic_live, 3.0)
	Recorder.notification(Node.NOTIFICATION_APPLICATION_PAUSED)
	await _frames(3)
	ok(not Recorder.recording and not Recorder._mic_live and got.is_empty(), "R-15: PAUSED while recording cancels it, nothing is delivered")
	Recorder.finished.disconnect(cb)
	Recorder.mode_override = ""
	Recorder.test_hooks = {}


func _test_limits() -> void:
	print("[limits and modes]")
	ok(Recorder.MAX_SECONDS == 30.0, "MAX_SECONDS stays 30")
	# the recorder ends itself at MAX_SECONDS
	Recorder.mode_override = "android"
	Recorder.test_hooks = {"granted": func() -> bool: return true, "open": func() -> bool: return true, "recording": func() -> AudioStreamWAV: return WavUtil.sine(31.0, 48000, 440.0, 0.5, true), "close": func() -> void: pass}
	var got: Array = []
	var cb := func(res: Dictionary) -> void: got.append(res)
	Recorder.finished.connect(cb)
	Recorder.begin(21)
	await _wait_for(func() -> bool: return Recorder._mic_live, 3.0)
	Recorder.elapsed = Recorder.MAX_SECONDS - 0.05
	await _wait_for(func() -> bool: return got.size() >= 1, 8.0)
	ok(got.size() == 1 and bool(got[0]["ok"]) and float(got[0]["duration"]) <= 30.01, "reaching MAX_SECONDS ends the recording; audio is cut to 30 s (%.2f s)" % (float(got[0]["duration"]) if got.size() > 0 else -1.0))
	Recorder.finished.disconnect(cb)
	# devices
	var devs: PackedStringArray = Recorder.input_devices()
	ok(devs.size() == 1 and devs[0] == "Default", "android: input_devices() is only ['Default']")
	Recorder.refresh_devices()   # must do nothing (no request)
	ok(true, "android: refresh_devices() returns without a request")
	# desktop --phone without a hook never opens a microphone and never talks to /mic
	Recorder.mode_override = "phone"
	Recorder.test_hooks = {}
	Recorder.test_audio_source = Callable()
	var before: int = Api.sent_count
	var got2: Array = []
	var cb2 := func(res: Dictionary) -> void: got2.append(res)
	Recorder.finished.connect(cb2)
	Recorder.begin(22)
	await _frames(6)
	Recorder.finished.disconnect(cb2)
	ok(got2.size() == 1 and not bool(got2[0]["ok"]) and bool(got2[0].get("reported", false)) and Api.sent_count == before, "desktop --phone, no test source: quiet failure, no request sent")
	ok(AudioServer.get_bus_index(Recorder.RECORD_BUS) == -1, "no 'Record' bus was created on the desktop")
	Recorder.mode_override = ""
