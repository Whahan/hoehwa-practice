extends Node
## Manual microphone check (needs a real audio driver, so no --headless):
##   godot --path <project> res://tests/mic_test.tscn
## Records 2 seconds from the selected input device and prints what came back.


func _ready() -> void:
	print("input devices: ", AudioServer.get_input_device_list(), " current=", AudioServer.input_device)
	print("bus 'Record' index: ", AudioServer.get_bus_index("Record"), " muted=", AudioServer.is_bus_mute(AudioServer.get_bus_index("Record")))
	Recorder.finished.connect(_on_finished)
	var started: bool = Recorder.begin(1)
	print("begin() -> ", started)
	var t := 0.0
	while t < 2.0:
		await get_tree().process_frame
		t += get_process_delta_time()
		if int(t * 10) % 5 == 0:
			pass
	print("level while recording (0..1): %.3f, elapsed %.2f" % [Recorder.level, Recorder.elapsed])
	Recorder.end()


func _on_finished(result: Dictionary) -> void:
	print("finished: ok=", result.get("ok"), " silent=", result.get("silent"), " duration=%.2f" % float(result.get("duration", 0.0)),
		" wav bytes=", (result.get("wav", PackedByteArray()) as PackedByteArray).size(), " b64 chars=", str(result.get("b64", "")).length())
	var s: AudioStreamWAV = result.get("stream", null)
	if s != null:
		print("stream: rate=", s.mix_rate, " stereo=", s.stereo, " format=", s.format, " data=", s.data.size())
	get_tree().quit()
