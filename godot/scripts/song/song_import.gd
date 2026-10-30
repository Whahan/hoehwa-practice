class_name SongImport
extends Node
## 노래 공부 U2: 곡 파일 고르기. 설계 docs/song_study_design.md §4.2 2번, §12.1a(폰에서 읽기 권한을 더하지 않는다), J0.
##
## pick(): PC 는 FileDialog(운영체제 대화상자가 되면 그것), 폰은 DisplayServer.file_dialog_show(시스템 파일 대화상자, 돌려주는 주소는
##   content:// 일 수 있고 FileAccess 로 읽는다). 폰에서 대화상자를 못 쓰면 failed("이 폰에서는 파일을 고를 수 없어요") 만 알리고 끝낸다.
##   기기 권한을 요청하는 코드는 일절 없다(시스템 대화상자가 고른 파일만 읽는다).
## 신호: picked(path) 고른 파일 / canceled() 아무것도 안 고르고 닫음 / failed(message) 대화상자를 열 수 없음.
## 검사: inspect(path) 이름·크기만 먼저 검사한다(64 MiB 초과·빈 파일·확장자). probe_duration(path) 은 mp3 / ogg / wav 에서만 길이를
##   알 수 있다(그 밖의 형식은 -1.0 = 모름, 길이 한도는 PC 가 알려 준다).
## 노드는 트리에 넣은 뒤 쓴다. 시험은 dialog_hook(filters, done) 으로 대화상자를 대신한다: 열었으면 true, done(path) / done("") 로 답한다.

signal picked(path: String)
signal canceled
signal failed(message: String)

const EXTS: Array = ["mp3", "ogg", "wav", "m4a", "flac", "aac", "opus"]
const MAX_BYTES := 64 * 1024 * 1024
const MAX_SECONDS := 600.0
const MSG_NO_DIALOG_PHONE := "이 폰에서는 파일을 고를 수 없어요. 곡은 PC 앱에서 추가해 주세요."
const MSG_NO_DIALOG_PC := "파일 선택 창을 열 수 없어요."
const TITLE := "곡 파일 고르기"

## 시험: (filters: PackedStringArray, done: Callable(path: String)) -> bool (대화상자를 열었나)
var dialog_hook: Callable = Callable()
var picking: bool = false
var open_count: int = 0 ## 대화상자를 연 횟수 (시험용)

var _dlg: FileDialog = null


## 대화상자를 연다. 이미 열려 있으면 무시. 열 수 없으면 failed 를 낸다.
func pick() -> void:
	if picking:
		return
	picking = true
	open_count += 1
	if dialog_hook.is_valid():
		var opened: bool = bool(dialog_hook.call(filters(), Callable(self, "_done")))
		if not opened:
			_fail()
		return
	if Platform.is_phone():
		_pick_phone()
	else:
		_pick_pc()


## 대화상자 필터. 폰(안드로이드)은 소리 파일 종류 한 줄, PC 는 확장자 목록.
static func filters() -> PackedStringArray:
	if Platform.is_phone():
		return PackedStringArray(["audio/*"])
	var globs: PackedStringArray = []
	for e in EXTS:
		globs.append("*." + str(e))
	return PackedStringArray([",".join(globs) + " ; 오디오 파일"])


func _pick_phone() -> void:
	if not DisplayServer.has_feature(DisplayServer.FEATURE_NATIVE_DIALOG_FILE):
		_fail()
		return
	var err: int = DisplayServer.file_dialog_show(TITLE, "", "", false, DisplayServer.FILE_DIALOG_MODE_OPEN_FILE, filters(),
			Callable(self, "_on_native"))
	if err != OK:
		_fail()


func _pick_pc() -> void:
	var dlg := FileDialog.new()
	dlg.title = TITLE
	dlg.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	dlg.access = FileDialog.ACCESS_FILESYSTEM
	dlg.use_native_dialog = true
	dlg.filters = filters()
	dlg.file_selected.connect(func(p: String) -> void: _done(p))
	dlg.canceled.connect(func() -> void: _done(""))
	add_child(dlg)
	_dlg = dlg
	dlg.popup_centered(Vector2i(820, 540))


func _on_native(status: bool, paths: PackedStringArray, _filter_index: int) -> void:
	# the system may call back from another moment of the frame: handle on the next idle step
	call_deferred("_done", String(paths[0]) if (status and not paths.is_empty()) else "")


func _done(path: String) -> void:
	if not picking:
		return
	picking = false
	if _dlg != null and is_instance_valid(_dlg):
		_dlg.queue_free()
	_dlg = null
	if path == "":
		canceled.emit()
	else:
		picked.emit(path)


func _fail() -> void:
	picking = false
	failed.emit(MSG_NO_DIALOG_PHONE if Platform.is_phone() else MSG_NO_DIALOG_PC)


func _exit_tree() -> void:
	picking = false
	if _dlg != null and is_instance_valid(_dlg):
		_dlg.queue_free()
	_dlg = null


# ---------------------------------------------------------------- file checks (static, tested)

## {ok, err_code, message, name, size, ext}. 이름·크기·확장자만 본다(소리 내용은 PC 가 검사한다).
## content:// 주소는 이름에 확장자가 없을 수 있어서 확장자 검사를 하지 않는다.
static func inspect(path: String) -> Dictionary:
	var res := {"ok": false, "err_code": "", "message": "", "name": "", "size": 0, "ext": ""}
	var is_uri: bool = path.begins_with("content://")
	var nm: String = "선택한 파일" if is_uri else path.replace("\\", "/").get_file()
	res["name"] = nm
	var ext: String = "" if is_uri else path.get_extension().to_lower()
	res["ext"] = ext
	if not is_uri and not EXTS.has(ext):
		return _bad(res, "bad_ext")
	var f: FileAccess = FileAccess.open(path, FileAccess.READ)
	if f == null:
		return _bad(res, "file_open")
	var size: int = f.get_length()
	f.close()
	res["size"] = size
	if size <= 0:
		return _bad(res, "empty_file")
	if size > MAX_BYTES:
		return _bad(res, "too_large")
	res["ok"] = true
	return res


static func _bad(res: Dictionary, code: String) -> Dictionary:
	res["err_code"] = code
	res["message"] = SongTransfer.message_for(code)
	return res


## 곡 길이(초). mp3 / ogg / wav 만 안다. 모르면 -1.0 (오디오 형식이 다르거나 content:// 주소).
static func probe_duration(path: String) -> float:
	match path.get_extension().to_lower():
		"mp3":
			var s: AudioStreamMP3 = AudioStreamMP3.load_from_file(path)
			return s.get_length() if s != null else -1.0
		"ogg":
			var o: AudioStreamOggVorbis = AudioStreamOggVorbis.load_from_file(path)
			return o.get_length() if o != null else -1.0
		"wav":
			return _wav_seconds(path)
	return -1.0


## RIFF/WAVE 머리글만 읽어 길이를 구한다 (파일 전체를 읽지 않는다). 못 읽으면 -1.0.
static func _wav_seconds(path: String) -> float:
	var f: FileAccess = FileAccess.open(path, FileAccess.READ)
	if f == null:
		return -1.0
	var total: int = f.get_length()
	if total < 44 or f.get_buffer(4).get_string_from_ascii() != "RIFF":
		return -1.0
	f.get_32()
	if f.get_buffer(4).get_string_from_ascii() != "WAVE":
		return -1.0
	var byte_rate: int = 0
	var guard: int = 0
	while f.get_position() + 8 <= total and guard < 64:
		guard += 1
		var id: String = f.get_buffer(4).get_string_from_ascii()
		var sz: int = f.get_32()
		var body: int = f.get_position()
		if id == "fmt " and sz >= 16:
			f.get_32() # format tag + channels
			f.get_32() # sample rate
			byte_rate = f.get_32()
		elif id == "data":
			var remain: int = total - body
			var n: int = sz if (sz > 0 and sz <= remain) else remain
			return float(n) / float(byte_rate) if byte_rate > 0 else -1.0
		f.seek(body + sz + (sz & 1))
	return -1.0
