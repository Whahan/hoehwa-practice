extends SceneTree
## 점수 보정 도구(PA5a, docs/v201_design.md 2.4): 폰 쪽 결과를 PC(Windows)에서 만든다.
##   godot --headless --path <project> -s res://tools/calib_phone.gd -- --model=<ggml-base.en-q5_1.bin> --set=<folder> --out=<json> [--beam=1]
## 앱에 들어 있는 것과 같은 WhisperBridge(Windows DLL, N0 로 준비)에 같은 모델 파일로 --set 폴더의 클립(manifest.json 의 clip·file)을
## 전사해서 낱말(w, p, start, end)을 --out 에 저장한다. 점수는 여기서 만들지 않는다(calib_fit.py 가 서버 score_en 으로 계산).
## 출력(--out): {"v":1,"kind":"phone","model":"<파일 이름>","beam":N,"bridge":"<version>","clips":[{id, ok, error, text, duration, ms, words}]}
##   id 는 manifest 의 clip. 클립은 manifest 순서대로.
## 쓰는 곳은 --out 하나뿐이다. 인식 글자·문장은 화면에 찍지 않는다(숫자만). 개인 녹음이 든 폴더는 저장소 밖(scratch)에 둔다.
## 종료 코드: 0 성공, 1 실패(CALIB_PHONE_FAIL <이유>), 2 브리지(GDExtension)가 없음(CALIB_PHONE_NO_ENGINE)

const CHUNK_SECONDS := 30.0


func _arg(prefix: String) -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with(prefix):
			return a.substr(prefix.length())
	return ""


func _fail(reason: String, code: int = 1) -> void:
	print("CALIB_PHONE_FAIL ", reason)
	quit(code)


func _initialize() -> void:
	if not ClassDB.class_exists("WhisperBridge") or not ClassDB.can_instantiate("WhisperBridge"):
		print("CALIB_PHONE_NO_ENGINE")
		quit(2)
		return
	var model: String = _arg("--model=")
	var set_dir: String = _arg("--set=")
	var out_path: String = _arg("--out=")
	var beam_text: String = _arg("--beam=")
	var beam: int = int(beam_text) if beam_text != "" else 1
	if model == "" or set_dir == "" or out_path == "":
		_fail("args (--model=<file> --set=<folder> --out=<json> [--beam=1])")
		return
	if beam < 1 or beam > 3:
		_fail("beam (1..3)")
		return
	if not FileAccess.file_exists(model):
		_fail("model file")
		return
	if not FileAccess.file_exists(set_dir.path_join("manifest.json")):
		_fail("manifest")
		return
	var manifest: Variant = JSON.parse_string(FileAccess.get_file_as_string(set_dir.path_join("manifest.json")))
	if not (manifest is Dictionary) or not (manifest.get("clips") is Array) or (manifest["clips"] as Array).is_empty():
		_fail("manifest")
		return
	var bridge: Object = ClassDB.instantiate("WhisperBridge")
	var err: int = int(bridge.call("load_model", model, 0))
	if err != OK:
		_fail("load_model error %d" % err)
		return
	var results: Array = []
	var n_ok: int = 0
	var n_err: int = 0
	for c in manifest["clips"]:
		if not (c is Dictionary) or str(c.get("clip", "")) == "" or str(c.get("file", "")) == "":
			_fail("manifest clip")
			return
		var wav_path: String = set_dir.path_join(str(c["file"]))
		if not FileAccess.file_exists(wav_path):
			_fail("clip file missing")
			return
		var wav: PackedByteArray = FileAccess.get_file_as_bytes(wav_path)
		var r: Dictionary = bridge.call("transcribe", wav, "en", {"beam": beam, "max_seconds": CHUNK_SECONDS})
		var rec: Dictionary = {
			"id": str(c["clip"]),
			"ok": bool(r.get("ok", false)),
			"error": str(r.get("error", "")),
			"text": str(r.get("text", "")),
			"duration": float(r.get("duration", 0.0)),
			"ms": int(r.get("ms", 0)),
			"words": r.get("words", []),
		}
		if rec["ok"]:
			n_ok += 1
		else:
			n_err += 1
		results.append(rec)
	var doc: Dictionary = {
		"v": 1,
		"kind": "phone",
		"model": model.get_file(),
		"beam": beam,
		"bridge": str(bridge.call("version")),
		"clips": results,
	}
	bridge.call("unload")
	var dir: String = out_path.get_base_dir()
	if dir != "" and not DirAccess.dir_exists_absolute(dir):
		DirAccess.make_dir_recursive_absolute(dir)
	var f: FileAccess = FileAccess.open(out_path, FileAccess.WRITE)
	if f == null:
		_fail("cannot write --out")
		return
	f.store_string(JSON.stringify(doc, " ", true) + "\n")
	f.close()
	print("CALIB_PHONE_OK clips=%d ok=%d errors=%d" % [results.size(), n_ok, n_err])
	quit(0)
