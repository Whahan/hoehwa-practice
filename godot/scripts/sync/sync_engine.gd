class_name SyncEngine
extends RefCounted
## 학습 기록 동기화 엔진 (설계 docs/sync_design.md §3.3, §4.8.1, §6, §7). 병합 계산은 SyncMerge(순수 함수)가 하고,
## 이 클래스는 순서(받기 -> 병합·적용(await 없음) -> 올리기), 사이드카·백업·저널, 선택·스위치·재합류만 맡는다.
##
## 지킬 것
##  * choice == "undecided" 이거나 enabled == false 이면 /sync/* 요청을 한 번도 만들지 않는다 (probe_peers 만 예외: PC undecided).
##  * 병합에 넘기는 시각(stamp)은 허브 시각(응답의 hub_time)이다. 기기 시계를 그대로 쓰지 않는다 (§4.7).
##  * "own 이 있는데 base 가 없는" 상태를 만들지 않는다: base={} 는 첫 동기화로 해석돼 로컬 전체가 몫에 다시 더해진다.
##    그런 사이드카를 읽으면 state_lost 로 멈추고, 첫 가입·초기화 연결 해제는 own 과 base 를 함께 비운다.
##  * 적용 순서: 백업 -> 사이드카에 pending(저널) -> 파일 3개 -> 사이드카 base 갱신·pending 삭제.

signal finished(result: Dictionary)

const PULL_TIMEOUT := 20.0
const PULL_TIMEOUT_PHONE := 45.0
const PUSH_TIMEOUT := 30.0
const PUSH_TIMEOUT_PHONE := 60.0
const CLOCK_WARN_SEC := 120
const PROBE_ID := "0000000000000000"
const BODY_WARN_BYTES := 3 * 1024 * 1024

const ERRORS := {
	"unreachable": "PC에 닿지 않아요. 연결되면 자동으로 동기화해요.",
	"not_connected": "PC에 연결되지 않았어요.",
	"old_pc": "이 PC의 회화 연습이 기록 동기화를 지원하지 않아요. PC 앱을 1.2 이상으로 업데이트해 주세요.",
	"hub_changed": "다른 PC에 연결돼 있어요. 아래 '이 PC와 새로 합치기'를 눌러 주세요.",
	"state_lost": "동기화 상태 파일이 손상됐어요. '이전 상태로 되돌리기'로 복원하거나 '새로 합치기'를 눌러 주세요. (기록이 겹쳐 셀 수 있어요)",
	"merge_check_failed": "합친 결과를 확인하지 못해서 이 기기의 기록은 그대로 뒀어요. 다시 시도하거나 앱을 업데이트해 주세요.",
	"local_read_only": "이 기기의 기록 파일을 읽지 못해서 동기화를 쉬어요.",
	"disk": "기록을 저장하지 못했어요. 저장 공간을 확인해 주세요.",
	"server_rejected": "PC가 기록 형식을 받아들이지 않았어요. 두 기기의 앱 버전을 확인해 주세요.",
	"too_large": "기록이 너무 커서 보내지 못했어요.",
	"bad_reply": "PC가 보낸 답을 이해하지 못했어요.",
	"sync_off": "이 PC에서는 기록 동기화를 쓸 수 없어요.",
	"hub_store_failed": "PC에 기록을 저장하지 못했어요.",
}
const WARN_PEER_NEWER := "다른 기기의 앱이 더 새 버전이에요. 그 기기 기록은 앱을 업데이트한 뒤에 합쳐져요."

## 자동 백업 사이이 최소 간격(초). 시험은 0 으로 둔다. first / restore / unlink 와 재합류 백업은 항상 만든다.
var backup_min_gap: int = 300

var ports: SyncPorts
var _st: Dictionary = {}
var _loaded: bool = false
var _lost: bool = false
var _busy: bool = false
var _saved_cmp: String = ""
var _last_error: Dictionary = {"code": "", "error": "", "at": 0}
var _fp: String = ""
var _clock_off: int = 0
## Counts the things that must stop a round that is waiting for the network (switch off, unlink, restore, re-link).
var _gen: int = 0


func _init(p: SyncPorts) -> void:
	ports = p


# ---------------------------------------------------------------- state

func _ensure() -> void:
	if _loaded:
		return
	var r: Dictionary = SyncState.load_file(ports.state_path)
	_st = r["state"]
	_lost = bool(r["lost"])
	_loaded = true
	_saved_cmp = SyncState.serialize(_st, false)
	# own without base would count the whole local record a second time (see header)
	if not _lost and _st["pending"] == null and not (_st["own"] as Dictionary).is_empty() and (_st["base"] as Dictionary).is_empty():
		_lost = true


func _now() -> int:
	return int(ports.now_unix.call()) if ports.now_unix.is_valid() else int(Time.get_unix_time_from_system())


func _call_bool(c: Callable) -> bool:
	return c.is_valid() and bool(c.call())


## Writes the sidecar when something other than the status fields changed (or `force`). false = the write failed.
func _save(force: bool = false) -> bool:
	var cmp: String = SyncState.serialize(_st, false)
	if not force and cmp == _saved_cmp:
		return true
	if not SyncState.save_text(ports.state_path, SyncState.serialize(_st)):
		return false
	_saved_cmp = cmp
	return true


func _hub_now_estimate() -> int:
	return _now() + int(_st["skew"])


func _error_text(code: String) -> String:
	if code == "unreachable" and ports.device_kind == "pc":
		return "AI 엔진에 연결하지 못했어요. 연결되면 자동으로 동기화해요."
	return str(ERRORS.get(code, ""))


func _result(extra: Dictionary) -> Dictionary:
	var out: Dictionary = {
		"ok": false, "code": "ok", "error": "", "applied": false, "pushed": false, "reason": "", "peers": 0,
		"changes": {"cards_added": 0, "cards_removed": 0, "cards_updated": 0, "checks_changed": 0, "marks_changed": 0,
			"known_added": 0, "known_removed": 0},
		"trimmed": {"cards": 0, "known": 0}, "clock_off_sec": _clock_off, "warnings": [], "duration_ms": 0, "first": false,
	}
	for k in extra.keys():
		out[k] = extra[k]
	if str(out["error"]) == "" and not bool(out["ok"]):
		out["error"] = _error_text(str(out["code"]))
	return out


func _fail(code: String, extra: Dictionary = {}) -> Dictionary:
	var e: Dictionary = extra.duplicate()
	e["ok"] = false
	e["code"] = code
	return _result(e)


# ---------------------------------------------------------------- public: state questions

func needs_choice() -> bool:
	_ensure()
	return not _lost and str(_st["choice"]) == "undecided"


func status() -> Dictionary:
	_ensure()
	var le: Dictionary = _last_error.duplicate()
	if str(le["code"]) == "" and str((_st["last_error"] as Dictionary).get("code", "")) != "":
		le = {"code": str(_st["last_error"]["code"]), "error": _error_text(str(_st["last_error"]["code"])), "at": int(_st["last_error"]["at"])}
	return {
		"enabled": bool(_st["enabled"]) and not _lost,
		"choice": str(_st["choice"]),
		"linked": bool(_st["first_done"]) and str(_st["device_id"]) != "",
		"busy": _busy,
		"last_ok": int(_st["last_ok"]),
		"last_error": le,
		"peers": (_st["peers"] as Array).duplicate(true),
		"backups": SyncBackup.list(ports.backup_root).size(),
		"clock_off_sec": _clock_off,
		"first_done": bool(_st["first_done"]),
		"lost": _lost,
		"device_id": str(_st["device_id"]),
	}


func list_backups() -> Array:
	return SyncBackup.list(ports.backup_root)


func local_fingerprint() -> String:
	return _fp_of(ports.load_local.call())


static func _fp_of(local: Dictionary) -> String:
	return SyncMerge.canonical(SyncDoc.extract(local["progress"], local["studylog"], local["prefs"], 0)).sha256_text()


# ---------------------------------------------------------------- public: choice / switch

## "merge" | "separate". merge: switches sync on and does the first sync, returns its result. separate: sync stays off for good
## (never asked again) and no request is made; the result is {"ok": true, "code": "ok"}.
func set_choice(choice: String) -> Dictionary:
	_ensure()
	if choice != "merge" and choice != "separate":
		return _fail("bad_choice")
	if _lost:
		return _fail("state_lost")
	if choice == "separate":
		_gen += 1
		if bool(_st["enabled"]):
			_st["disabled_at"] = _hub_now_estimate()
		_st["choice"] = "separate"
		_st["enabled"] = false
		if not _save(true):
			return _fail("disk")
		return _result({"ok": true, "code": "ok"})
	_st["choice"] = "merge"
	_enable_internal()
	if not _save(true):
		return _fail("disk")
	return await sync_now("manual")


## Settings switch. Off: nothing is sent or received any more (the copy on the hub stays). On: a device that already joined
## re-joins with the union (rebase at the time it was switched off); a device that never joined starts with a plain first sync.
func set_enabled(on: bool) -> void:
	_ensure()
	if _lost:
		return
	if on:
		if str(_st["choice"]) == "undecided":
			_st["choice"] = "merge"
		_enable_internal()
	elif bool(_st["enabled"]):
		_gen += 1
		_st["enabled"] = false
		_st["disabled_at"] = _hub_now_estimate()
	_save(true)


func _enable_internal() -> void:
	if bool(_st["enabled"]):
		return
	_st["enabled"] = true
	if str(_st["device_id"]) == "":
		_st["device_id"] = SyncState.new_device_id()
	if bool(_st["first_done"]) and _st["rebase"] == null:
		var at: int = int(_st["disabled_at"])
		_st["rebase"] = {"sets_at": at if at > 0 else _hub_now_estimate()}


# ---------------------------------------------------------------- public: reset / re-link / restore

## Called before "모든 기록 지우기": backup `unlink`, sync off, own / base / hub / device forgotten (a new id joins later).
## The copy on the hub stays. -> {"ok": true, "warning": String}: warning is not empty when the backup (or the sidecar) could not be written.
func unlink_for_reset() -> Dictionary:
	_ensure()
	if _lost or (str(_st["choice"]) == "undecided" and not bool(_st["first_done"])):
		return {"ok": true, "warning": ""}
	_gen += 1
	# the reset was asked for by the person: a failing backup does not stop it, the result says so
	var warning: String = ""
	if not bool(_backup("unlink", true)["ok"]):
		warning = "연결을 끊기 전 백업을 만들지 못했어요."
	_forget_hub()
	_st["enabled"] = false
	_st["disabled_at"] = _hub_now_estimate()
	if not _save(true) and warning == "":
		warning = ERRORS["disk"]
	return {"ok": true, "warning": warning}


func _forget_hub() -> void:
	_st["own"] = {}
	_st["base"] = {}
	_st["hub_id"] = ""
	_st["device_id"] = ""
	_st["seq"] = 0
	_st["hub_rev"] = 0
	_st["pushed_hash"] = ""
	_st["push_pending"] = false
	_st["pending"] = null
	_st["rebase"] = null
	_st["first_done"] = false
	_st["peers"] = []
	_fp = ""


## "이 PC와 새로 합치기" / state_lost 의 "새로 합치기": backup `first`, new device id, own and base empty, sync on, first sync.
func relink_fresh() -> Dictionary:
	_ensure()
	if _busy:
		return _fail("in_progress")
	_gen += 1
	var b: Dictionary = _backup("first", true)
	if not b["ok"]:
		return _fail("disk")
	_forget_hub()
	_lost = false
	_st["choice"] = "merge"
	_st["enabled"] = true
	_st["device_id"] = SyncState.new_device_id()
	if not _save(true):
		return _fail("disk")
	return await sync_now("manual")


## Puts the three record files back to a backup (the state before is saved as `restore` first). Sync is switched off and the
## next switch-on re-joins with the union (rebase at the time of the backup); own and base stay as they are (§4.8).
func restore_backup(name: String) -> Dictionary:
	_ensure()
	if _busy:
		return {"ok": false, "error": "동기화 중이에요. 잠시 뒤 다시 해 주세요."}
	var v: Dictionary = SyncBackup.verify(ports.backup_root, name)
	if not v["ok"]:
		return {"ok": false, "error": "백업을 확인하지 못했어요."}
	var b: Dictionary = _backup("restore", true, name)
	if not b["ok"]:
		return {"ok": false, "error": ERRORS["disk"]}
	_gen += 1
	var r: Dictionary = SyncBackup.restore_files(ports.backup_root, name, ports.local_paths.call())
	if not r["ok"]:
		return {"ok": false, "error": ERRORS["disk"]}
	if ports.reload_local.is_valid():
		ports.reload_local.call()
	if bool(_st["first_done"]):
		_st["rebase"] = {"sets_at": maxi(1, int((v["meta"] as Dictionary)["at"]) + int(_st["skew"]))}
	_st["enabled"] = false
	_st["disabled_at"] = _hub_now_estimate()
	_st["pending"] = null
	if (_st["base"] as Dictionary).is_empty():
		_st["own"] = {} # never an own copy without a base (the first sync would be counted twice)
	_fp = ""
	if not _save(true):
		return {"ok": false, "error": ERRORS["disk"]}
	return {"ok": true, "error": ""}


# ---------------------------------------------------------------- backup

## -> {"ok": bool, "skipped": bool}. Automatic backups closer than backup_min_gap to the last one are skipped unless `force`.
## `protect` = a backup that is about to be restored: pruning must not delete it.
func _backup(reason: String, force: bool, protect: String = "") -> Dictionary:
	var now: int = _now()
	if not force:
		var lst: Array = SyncBackup.list(ports.backup_root)
		if not lst.is_empty() and now - int(lst[0]["at"]) < backup_min_gap and now >= int(lst[0]["at"]):
			return {"ok": true, "skipped": true}
	var paths: Dictionary = ports.local_paths.call() if ports.local_paths.is_valid() else {}
	var r: Dictionary = SyncBackup.create(ports.backup_root, reason, now, paths, ports.state_path)
	if not r["ok"]:
		return {"ok": false, "skipped": false}
	SyncBackup.prune(ports.backup_root, SyncBackup.KEEP, protect)
	return {"ok": true, "skipped": false}


# ---------------------------------------------------------------- probe (PC, undecided)

## Read-only look at the hub: how many OTHER devices have a copy there (-1 = failed / not applicable). Changes nothing locally.
func probe_peers() -> int:
	_ensure()
	if _lost or str(_st["choice"]) != "undecided":
		return -1
	var pr: Dictionary = await ports.http_get.call("/sync/pull?device_id=" + PROBE_ID, _pull_timeout())
	if not bool(pr.get("ok", false)):
		return -1
	var d: Variant = pr.get("data", null)
	if not (d is Dictionary) or not ((d as Dictionary).get("replicas", null) is Array):
		return -1
	return ((d as Dictionary)["replicas"] as Array).size()


# ---------------------------------------------------------------- the round

func _pull_timeout() -> float:
	return PULL_TIMEOUT_PHONE if ports.device_kind == "phone" else PULL_TIMEOUT


func _push_timeout() -> float:
	return PUSH_TIMEOUT_PHONE if ports.device_kind == "phone" else PUSH_TIMEOUT


## One sync round. Always returns the §6.4 dictionary; also emits `finished`.
func sync_now(reason: String) -> Dictionary:
	_ensure()
	if _busy:
		return _fail("in_progress", {"reason": reason})
	_busy = true
	var t0: int = Time.get_ticks_msec()
	var res: Dictionary = await _round(reason)
	res["reason"] = reason
	res["duration_ms"] = Time.get_ticks_msec() - t0
	_busy = false
	_note(res)
	finished.emit(res)
	return res


func _note(res: Dictionary) -> void:
	var code: String = str(res["code"])
	if bool(res["ok"]):
		_last_error = {"code": "", "error": "", "at": 0}
		_st["last_error"] = {"code": "", "at": 0}
		_st["last_ok"] = _hub_now_estimate()
	elif code != "disabled" and code != "in_progress" and code != "busy":
		_last_error = {"code": code, "error": str(res["error"]), "at": _now()}
		_st["last_error"] = {"code": code, "at": _now()}


func _http_fail(pr: Dictionary) -> Dictionary:
	var code: int = int(pr.get("code", 0))
	var ec: String = str(pr.get("err_code", ""))
	if bool(pr.get("cancelled", false)) or ec == "transport":
		return _fail("unreachable")
	if ec == "not_connected" or ec.begins_with("token_"):
		return _fail("not_connected")
	if code == 404:
		return _fail("old_pc")
	if code == 413 or ec == "too_large":
		return _fail("too_large")
	if ec == "sync_off":
		return _fail("sync_off")
	if ec == "store_failed":
		return _fail("hub_store_failed")
	if code >= 200 and code < 300:
		return _fail("bad_reply")
	if code == 0:
		return _fail("unreachable")
	return _fail("server_rejected")


static func _whole(v: Variant) -> bool:
	return v is int or (v is float and is_finite(v) and v == floorf(v))


## The reply of GET /sync/pull must have this shape; anything else is bad_reply.
static func _pull_ok(d: Variant) -> bool:
	if not (d is Dictionary):
		return false
	var m: Dictionary = d
	if not _whole(m.get("v", null)) or int(m["v"]) != 1:
		return false
	if not (m.get("hub_id", null) is String) or (m["hub_id"] as String) == "":
		return false
	if not _whole(m.get("hub_time", null)) or int(m["hub_time"]) <= 0 or not _whole(m.get("rev", null)):
		return false
	if m.get("unchanged", false) == true:
		return true
	if not (m.get("replicas", null) is Array):
		return false
	for r in (m["replicas"] as Array):
		if not (r is Dictionary) or not SyncState.is_device_id((r as Dictionary).get("device_id", null)):
			return false
	return true


func _pull(with_rev: bool) -> Dictionary:
	var path: String = "/sync/pull?device_id=%s" % str(_st["device_id"])
	if with_rev:
		path += "&rev=%d" % int(_st["hub_rev"])
	return await ports.http_get.call(path, _pull_timeout())


func _round(_reason: String) -> Dictionary:
	if _lost:
		return _fail("state_lost")
	if str(_st["choice"]) == "undecided" or not bool(_st["enabled"]):
		return _result({"ok": false, "code": "disabled"})
	if _call_bool(ports.is_read_only):
		return _fail("local_read_only")
	if str(_st["device_id"]) == "":
		_st["device_id"] = SyncState.new_device_id()
	var gen: int = _gen

	# 0. a journal left by an apply that did not finish is closed first
	if _st["pending"] != null:
		var rec: Dictionary = _finish_pending()
		if not bool(rec["ok"]):
			return rec
	var first_sync: bool = not bool(_st["first_done"])

	# 1. receive. The answer "unchanged" is only asked for when nothing is waiting to be sent or merged.
	var local0: Dictionary = ports.load_local.call()
	var quiet: bool = (not first_sync) and int(_st["hub_rev"]) > 0 and _fp != "" and _fp == _fp_of(local0) \
		and not bool(_st["push_pending"]) and _st["rebase"] == null
	var pr: Dictionary = await _pull(quiet)
	if gen != _gen:
		return _result({"ok": false, "code": "disabled"}) # switched off / unlinked while waiting: nothing is applied or sent
	if not bool(pr.get("ok", false)):
		return _http_fail(pr)
	var d: Variant = pr["data"]
	if not _pull_ok(d):
		return _fail("bad_reply")
	var dd: Dictionary = d
	if dd.get("unchanged", false) == true and str(_st["hub_id"]) != "" and str(dd["hub_id"]) != str(_st["hub_id"]):
		quiet = false
		pr = await _pull(false)
		if gen != _gen:
			return _result({"ok": false, "code": "disabled"})
		if not bool(pr.get("ok", false)):
			return _http_fail(pr)
		if not _pull_ok(pr["data"]) or (pr["data"] as Dictionary).get("unchanged", false) == true:
			return _fail("bad_reply")
		dd = pr["data"]
	var hub_id: String = str(dd["hub_id"])
	var hub_time: int = int(dd["hub_time"])
	var pull_rev: int = int(dd["rev"])
	var self_seq: int = 0
	if dd.get("self", null) is Dictionary and _whole((dd["self"] as Dictionary).get("seq", null)):
		self_seq = maxi(0, int((dd["self"] as Dictionary)["seq"]))
	var skew: int = clampi(hub_time - _now(), -SyncState.SKEW_MAX, SyncState.SKEW_MAX)
	_st["skew"] = skew
	_clock_off = skew if absi(skew) > CLOCK_WARN_SEC else 0

	if dd.get("unchanged", false) == true:
		# nothing new on the hub and nothing of ours to send
		_st["hub_rev"] = pull_rev
		_save()
		return _result({"ok": true, "code": "ok"})

	var replicas: Array = dd["replicas"]
	if str(_st["hub_id"]) != "" and str(_st["hub_id"]) != hub_id:
		if not replicas.is_empty():
			return _fail("hub_changed")
		# the hub folder was recreated and nobody else is there: our copy goes up again
		_st["pushed_hash"] = ""
		_st["hub_rev"] = 0
	var peers_meta: Array = []
	var peers: Array = []
	for rep in replicas:
		var rd: Dictionary = rep
		peers.append({"device_id": rd["device_id"], "saved_hub": rd.get("saved_hub", 0), "doc": rd.get("doc", null)})
		peers_meta.append({"device_id": rd["device_id"], "name": str(rd.get("name", "")).left(40),
			"kind": "pc" if str(rd.get("kind", "")) == "pc" else "phone", "saved_hub": int(rd["saved_hub"]) if _whole(rd.get("saved_hub", null)) else 0})

	# 2.-8. merge and apply: no await from here to the end of the apply
	var local: Dictionary = ports.load_local.call()
	var local_view: Dictionary = SyncDoc.extract(local["progress"], local["studylog"], local["prefs"], skew)
	var r: Dictionary = SyncMerge.sync_round({
		"own": _st["own"], "local": local_view, "base": _st["base"], "peers": peers,
		"stamp": hub_time, "hub_now": hub_time, "today": int(ports.today_days.call()),
		"rebase": _st["rebase"], "device_id": str(_st["device_id"]),
	})
	if not bool(r["ok"]):
		_write_problem(r["problems"])
		return _fail("merge_check_failed", {"peers": peers.size()})
	var report: Dictionary = r["report"]
	var changed: bool = bool(report["changed"])
	var rejoin: bool = _st["rebase"] != null
	var warnings: Array = []
	if _clock_off != 0:
		warnings.append("이 기기의 시계가 PC와 %d분 차이 나요. 시계를 자동으로 맞춰 주세요." % int(roundf(absf(float(_clock_off)) / 60.0)))
	for sk in report["peers_skipped"]:
		if str((sk as Dictionary).get("reason", "")) == "newer" and not warnings.has(WARN_PEER_NEWER):
			warnings.append(WARN_PEER_NEWER)

	var applied: bool = false
	if changed and _call_bool(ports.is_busy_ui):
		return _result({"ok": false, "code": "busy", "peers": peers.size(), "warnings": warnings})
	if first_sync or changed:
		var bk: Dictionary = _backup("first" if first_sync else "auto", first_sync or rejoin)
		if not bool(bk["ok"]):
			return _fail("disk", {"peers": peers.size()})
	if changed:
		# the journal holds the new own copy; the sidecar's own / base stay the old, matching pair until the apply is done
		var pend := {"view": r["view"], "own": r["own"], "seq": int(_st["seq"]), "skew": skew, "hub_id": hub_id, "pre": _section_hashes(local_view), "pre_base": SyncDoc.to_base(local_view)}
		_st["pending"] = pend
		if not _save(true):
			_st["pending"] = null
			return _fail("disk", {"peers": peers.size()})
		var parts: Dictionary = SyncDoc.to_local(r["view"], skew, local["progress"], local["studylog"], local["prefs"])
		if not bool(ports.apply_local.call(parts["progress"], parts["studylog"], parts["prefs_changes"])):
			# Some of the three files may already show the merge. Right now nothing else has touched them, so what the files
			# hold is the one base that fits the new own copy: the next round continues from there (no loss, nothing counted twice).
			var cur_now: Dictionary = ports.load_local.call()
			pend["mix_base"] = SyncDoc.to_base(SyncDoc.extract(cur_now["progress"], cur_now["studylog"], cur_now["prefs"], skew))
			_save(true)
			return _fail("disk", {"peers": peers.size()})
		applied = true
	if not _finish_local(skew, hub_id, r["own"]):
		return _fail("disk", {"peers": peers.size(), "applied": applied})
	_st["peers"] = peers_meta
	var ch: Dictionary = report["changes"]
	var changes := {}
	for k in ["cards_added", "cards_removed", "cards_updated", "checks_changed", "marks_changed", "known_added", "known_removed"]:
		changes[k] = int(ch.get(k, 0))

	# 9. send (a failure here leaves the local record consistent: the next round sends the same thing again)
	var out: Dictionary = {"applied": applied, "peers": peers.size(), "changes": changes, "trimmed": report["trimmed"],
		"warnings": warnings, "first": first_sync}
	var own_hash: String = SyncMerge.canonical(_st["own"]).sha256_text()
	if bool(_st["push_pending"]) or own_hash != str(_st["pushed_hash"]) or self_seq < int(_st["seq"]):
		var pu: Dictionary = await _push(own_hash, self_seq, pull_rev, gen)
		if str(pu.get("code", "")) == "aborted":
			return _result({"ok": false, "code": "disabled", "applied": applied}) # unlinked while the push was out: state is not touched
		if not bool(pu["ok"]):
			_st["push_pending"] = true
			_save()
			for k in out.keys():
				pu[k] = out[k]
			return pu
		out["pushed"] = true
	else:
		_st["hub_rev"] = pull_rev
	_save()
	out["ok"] = true
	out["code"] = "ok"
	return _result(out)


func _write_problem(problems: Array) -> void:
	## key names only, never values (the problems are paths like "xp.en")
	var list: Array = []
	for p in problems:
		if list.size() >= 20:
			break
		list.append(str(p).left(80))
	var text: String = JSON.stringify({"at": _now(), "count": problems.size(), "problems": list})
	var dir: String = ports.state_path.get_base_dir()
	Progress.write_text_atomic(dir.path_join("sync_last_problem.json"), text)


## Base := what the local files really contain now (not the merge result: normalisation / caps may differ), journal closed.
func _finish_local(skew: int, hub_id: String, own_new: Variant = null) -> bool:
	if own_new is Dictionary:
		_st["own"] = own_new
	var after: Dictionary = ports.load_local.call()
	var view_after: Dictionary = SyncDoc.extract(after["progress"], after["studylog"], after["prefs"], skew)
	_st["base"] = SyncDoc.to_base(view_after)
	_st["pending"] = null
	_st["rebase"] = null
	_st["first_done"] = true
	_st["hub_id"] = hub_id
	_fp = _fp_of(after)
	return _save(true)


const _SECTIONS := {
	"progress": ["start", "checks", "marks", "xp", "stats", "cards", "known"],
	"studylog": ["days", "phon", "missions"],
	"prefs": ["prefs"],
}


## sha256 of each file's part of a local view (to tell, after a stop, which files already show the merge).
static func _section_hashes(view: Dictionary) -> Dictionary:
	var out := {}
	for s in _SECTIONS.keys():
		var part := {}
		for k in _SECTIONS[s]:
			part[k] = view.get(k, null)
		out[s] = SyncMerge.canonical(part).sha256_text()
	return out


## Closes a journal left by an apply that did not finish.
##  * The apply failed in this run (the journal has `mix_base`): the files hold that mix; own advances, base follows the mix,
##    the normal round that comes next does the rest. Whatever was studied since stays in the next delta.
##  * The process stopped in the middle (no `mix_base`): each file is either as before the apply (it gets the view), as the
##    journalled view (left), or neither because something was studied since (it is never overwritten; its base is the
##    state before the apply, so what was studied counts in the next delta and nothing is counted twice or lost).
func _finish_pending() -> Dictionary:
	var pend: Dictionary = _st["pending"]
	var skew: int = int(pend["skew"])
	var hub_id: String = str(pend.get("hub_id", _st["hub_id"]))
	if pend.get("mix_base", null) is Dictionary and not (pend["mix_base"] as Dictionary).is_empty():
		_st["own"] = pend["own"]
		_st["base"] = pend["mix_base"]
		_st["pending"] = null
		_st["rebase"] = null
		_st["first_done"] = true
		_st["hub_id"] = hub_id
		_fp = ""
		if not _save(true):
			return _fail("disk")
		return {"ok": true}
	var local: Dictionary = ports.load_local.call()
	var cur: Dictionary = SyncDoc.extract(local["progress"], local["studylog"], local["prefs"], skew)
	var want: Dictionary = SyncDoc.norm_view(pend["view"])
	var pre: Dictionary = pend["pre"] if pend.get("pre", null) is Dictionary else {}
	var pre_base: Dictionary = pend["pre_base"] if pend.get("pre_base", null) is Dictionary else {}
	var h_cur: Dictionary = _section_hashes(cur)
	var h_want: Dictionary = _section_hashes(want)
	var need := {}  # still as before the apply, nothing studied since: gets the view
	var other := {} # neither: something was studied since (or it is half way). Never overwritten.
	for s in _SECTIONS.keys():
		if h_cur[s] == h_want[s]:
			continue
		if pre.has(s) and h_cur[s] == str(pre[s]):
			need[s] = true
		else:
			other[s] = true
	if not need.is_empty():
		var parts: Dictionary = SyncDoc.to_local(want, skew, local["progress"], local["studylog"], local["prefs"])
		var p_in: Dictionary = parts["progress"] if need.has("progress") else local["progress"]
		var s_in: Dictionary = parts["studylog"] if need.has("studylog") else local["studylog"]
		var pc: Dictionary = parts["prefs_changes"] if need.has("prefs") else {}
		if not bool(ports.apply_local.call(p_in, s_in, pc)):
			return _fail("disk")
	# base: what the files hold now, except the files left alone: for those the state before the apply, so that what was
	# studied since counts in the next delta (their merge share from the peers comes in with the normal round)
	var after: Dictionary = ports.load_local.call()
	var base_now: Dictionary = SyncDoc.to_base(SyncDoc.extract(after["progress"], after["studylog"], after["prefs"], skew))
	if not other.is_empty() and not pre_base.is_empty():
		for s in other.keys():
			for k in _SECTIONS[s]:
				if pre_base.has(k):
					base_now[k] = pre_base[k]
	_st["own"] = pend["own"]
	_st["base"] = base_now
	_st["pending"] = null
	_st["rebase"] = null
	_st["first_done"] = true
	_st["hub_id"] = hub_id
	_fp = ""
	if not _save(true):
		return _fail("disk")
	return {"ok": true}


## POST /sync/push with the current own copy. -> {"ok": true} or a failure result. Updates seq / pushed_hash / hub_rev.
func _push(own_hash: String, self_seq: int, pull_rev: int, gen: int) -> Dictionary:
	var problems: Array = SyncDoc.validate_replica(_st["own"])
	if not problems.is_empty():
		_write_problem(problems)
		return _fail("merge_check_failed")
	var seq: int = maxi(int(_st["seq"]), self_seq) + 1
	var pr: Dictionary = {}
	for attempt in 2:
		var body := {
			"v": 1, "device_id": str(_st["device_id"]), "name": ports.device_name if ports.device_name.strip_edges() != "" else ("휴대폰" if ports.device_kind == "phone" else "PC"),
			"kind": ports.device_kind, "seq": seq, "client_time": _now(), "skew": int(_st["skew"]), "doc": _st["own"],
		}
		pr = await ports.http_post.call("/sync/push", body, _push_timeout())
		if gen != _gen:
			return {"ok": false, "code": "aborted"}
		if bool(pr.get("ok", false)):
			break
		var ec: String = str(pr.get("err_code", ""))
		if attempt == 0 and int(pr.get("code", 0)) == 409 and (ec == "stale_seq" or ec == "seq_reuse"):
			var eb: Variant = pr.get("err_body", null)
			var stored: int = int((eb as Dictionary).get("stored_seq", seq)) if (eb is Dictionary and _whole((eb as Dictionary).get("stored_seq", null))) else seq
			seq = maxi(seq, stored) + 1
			continue
		return _http_fail(pr)
	var data: Variant = pr.get("data", null)
	if not (data is Dictionary) or (data as Dictionary).get("ok", false) != true:
		return _fail("bad_reply")
	_st["seq"] = seq
	_st["pushed_hash"] = own_hash
	_st["push_pending"] = false
	var rev_resp: int = int((data as Dictionary)["rev"]) if _whole((data as Dictionary).get("rev", null)) else pull_rev
	# only our own push moved the hub: remember its revision; otherwise a peer pushed in between and the next pull must see it
	_st["hub_rev"] = rev_resp if rev_resp <= pull_rev + 1 else pull_rev
	return {"ok": true}
