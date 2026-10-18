class_name SyncState
extends RefCounted
## 동기화 사이드카 user://sync_state.json (설계 docs/sync_design.md §4.10). 기기별 파일이고 동기화 대상이 아니다.
##
## 이 클래스는 모양(blank / normalize)과 읽기·쓰기만 맡는다. 어떤 값이 언제 바뀌는지는 SyncEngine 이 정한다.
## 읽기: Progress.read_json_file 규칙(깨졌으면 .bad 로 격리). 쓰기: Progress.write_text_atomic, 쓰기 전에 이전 파일을 .prev 로 남긴다.
## 파일이 없는데 .prev / .bad 가 있거나, 있는데 못 읽으면 `lost` 로 알려 준다: 그 상태에서 새 기기로 자동 가입하면 이미 합쳐진
## 값이 이중 계산될 수 있어서 엔진이 멈추고 사용자에게 고르게 한다 (§4.10 끝).

const VERSION := 1
const CHOICES := ["undecided", "merge", "separate"]
const SKEW_MAX := 604800

## 저장하지 않는 값(비교용 직렬화에서 빼는 것): 매 라운드 바뀌는 상태 표시.
const VOLATILE := ["last_ok", "last_error", "skew"]


static func blank() -> Dictionary:
	return {
		"v": VERSION,
		"device_id": "",
		"enabled": false,
		"choice": "undecided",
		"disabled_at": 0,
		"hub_id": "",
		"seq": 0,
		"hub_rev": 0,
		"skew": 0,
		"own": {},
		"base": {},
		"pushed_hash": "",
		"push_pending": false,
		"last_ok": 0,
		"last_error": {"code": "", "at": 0},
		"peers": [],
		"rebase": null,
		"pending": null,
		"first_done": false,
	}


static func _int(v: Variant, dflt: int = 0, lo: int = 0, hi: int = 9007199254740992) -> int:
	var x: int = dflt
	if v is int:
		x = v
	elif v is float and is_finite(v):
		x = int(clampf(v, -9.0e18, 9.0e18))
	return clampi(x, lo, hi)


static func is_device_id(v: Variant) -> bool:
	if not (v is String) or (v as String).length() != 16:
		return false
	for ch in (v as String):
		if not ((ch >= "0" and ch <= "9") or (ch >= "a" and ch <= "f")):
			return false
	return true


## 16 hex 글자 난수 기기 id.
static func new_device_id() -> String:
	var c := Crypto.new()
	return c.generate_random_bytes(8).hex_encode()


## Anything -> a complete state (missing / wrong-typed fields take their defaults). `own` / `base` stay raw Dictionaries:
## SyncMerge cleans them itself.
static func normalize(raw: Variant) -> Dictionary:
	var st: Dictionary = blank()
	if not (raw is Dictionary):
		return st
	var d: Dictionary = raw
	if is_device_id(d.get("device_id", null)):
		st["device_id"] = d["device_id"]
	var ch: Variant = d.get("choice", "undecided")
	st["choice"] = ch if (ch is String and CHOICES.has(ch)) else "undecided"
	st["enabled"] = d.get("enabled", false) == true and st["choice"] != "undecided"
	st["disabled_at"] = _int(d.get("disabled_at", 0))
	if d.get("hub_id", null) is String:
		st["hub_id"] = (d["hub_id"] as String).left(64)
	st["seq"] = _int(d.get("seq", 0))
	st["hub_rev"] = _int(d.get("hub_rev", 0))
	st["skew"] = _int(d.get("skew", 0), 0, -SKEW_MAX, SKEW_MAX)
	st["own"] = (d["own"] as Dictionary).duplicate(true) if d.get("own", null) is Dictionary else {}
	st["base"] = (d["base"] as Dictionary).duplicate(true) if d.get("base", null) is Dictionary else {}
	if d.get("pushed_hash", null) is String:
		st["pushed_hash"] = (d["pushed_hash"] as String).left(128)
	st["push_pending"] = d.get("push_pending", false) == true
	st["last_ok"] = _int(d.get("last_ok", 0))
	var le: Variant = d.get("last_error", null)
	if le is Dictionary:
		st["last_error"] = {"code": str((le as Dictionary).get("code", "")).left(40), "at": _int((le as Dictionary).get("at", 0))}
	var peers: Array = []
	if d.get("peers", null) is Array:
		for p in (d["peers"] as Array):
			if p is Dictionary and is_device_id((p as Dictionary).get("device_id", null)):
				peers.append({
					"device_id": (p as Dictionary)["device_id"],
					"name": str((p as Dictionary).get("name", "")).left(40),
					"kind": "pc" if str((p as Dictionary).get("kind", "")) == "pc" else "phone",
					"saved_hub": _int((p as Dictionary).get("saved_hub", 0)),
				})
			if peers.size() >= 16:
				break
	st["peers"] = peers
	if d.get("rebase", null) is Dictionary and ((d["rebase"] as Dictionary).get("sets_at", null) is int or (d["rebase"] as Dictionary).get("sets_at", null) is float):
		st["rebase"] = {"sets_at": _int((d["rebase"] as Dictionary)["sets_at"])}
	var pd: Variant = d.get("pending", null)
	if pd is Dictionary and (pd as Dictionary).get("view", null) is Dictionary and (pd as Dictionary).get("own", null) is Dictionary:
		st["pending"] = {
			"view": (pd as Dictionary)["view"],
			"own": (pd as Dictionary)["own"],
			"seq": _int((pd as Dictionary).get("seq", 0)),
			"skew": _int((pd as Dictionary).get("skew", 0), 0, -SKEW_MAX, SKEW_MAX),
		}
		var pend_out: Dictionary = st["pending"]
		if (pd as Dictionary).get("hub_id", null) is String:
			pend_out["hub_id"] = (pd as Dictionary)["hub_id"]
		if (pd as Dictionary).get("pre", null) is Dictionary:
			pend_out["pre"] = (pd as Dictionary)["pre"]
		if (pd as Dictionary).get("pre_base", null) is Dictionary:
			pend_out["pre_base"] = (pd as Dictionary)["pre_base"]
		if (pd as Dictionary).get("mix_base", null) is Dictionary:
			pend_out["mix_base"] = (pd as Dictionary)["mix_base"]
	st["first_done"] = d.get("first_done", false) == true
	return st


## Reads the sidecar. -> {"state": Dictionary, "lost": bool, "status": "new"|"ok"|"empty"|"bad"|"unreadable"|"newer"}
## lost = the file is gone / broken / unreadable although there are traces of an earlier one (.prev / .bad): see the header.
static func load_file(path: String) -> Dictionary:
	var r: Dictionary = Progress.read_json_file(path)
	var status: String = str(r["status"])
	match status:
		"ok":
			var data: Dictionary = r["data"]
			if SyncState._int(data.get("v", 1), 1, 0, 1000000) > VERSION:
				return {"state": blank(), "lost": true, "status": "newer"}
			return {"state": normalize(data), "lost": false, "status": "ok"}
		"new":
			var traces: bool = FileAccess.file_exists(path + ".prev") or FileAccess.file_exists(path + ".bad")
			return {"state": blank(), "lost": traces, "status": "new"}
	return {"state": blank(), "lost": true, "status": status}


## JSON text of the state. With `volatile` false the status-only fields are left out (used to tell whether a write is needed).
static func serialize(st: Dictionary, volatile: bool = true) -> String:
	var out: Dictionary = {}
	for k in blank().keys():
		if volatile or not VOLATILE.has(k):
			out[k] = st.get(k, blank()[k])
	return JSON.stringify(out)


## Writes the sidecar atomically after keeping the previous file as `<path>.prev`.
static func save_file(path: String, st: Dictionary) -> bool:
	return save_text(path, serialize(st))


static func save_text(path: String, text: String) -> bool:
	if FileAccess.file_exists(path):
		var prev: String = path + ".prev"
		var gp: String = ProjectSettings.globalize_path(prev)
		if FileAccess.file_exists(prev):
			DirAccess.remove_absolute(gp)
		DirAccess.copy_absolute(ProjectSettings.globalize_path(path), gp)
	return Progress.write_text_atomic(path, text)
