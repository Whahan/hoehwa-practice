class_name SongTransfer
extends Node
## 노래 공부: PC 로 곡을 보내고 결과를 받아 설치한다. 설계 docs/song_study_design.md §4.2, §5.1, §5.4.
##
## 흐름 (start): 길 확인(Route) -> GET /health(song 키) -> 조각 업로드(POST /song/upload, 3 MiB 씩 파일에서 읽는다)
##   -> POST /song/jobs -> 1.5 초마다 GET /song/jobs/status -> GET /song/result -> GET /song/audio?part=N (이어 붙여 sha256 확인)
##   -> SongStore.install (SongModel.normalize 를 거침, id 는 SongStore.new_id) -> 성공한 뒤에만 POST /song/jobs/release.
## resume(rec): SongStore.pending_list() 의 기록으로 앱을 다시 켠 뒤 상태 확인부터 이어 받는다.
## cancel(): 서버에 cancel(작업이 있으면) + release 를 보내 정리하고 곧바로 finished(cancelled).
## abandon(): 서버에 아무것도 보내지 않고 조용히 멈춘다 (pending 은 남는다). 화면을 닫을 때 부른다. 노드가 트리에서 빠져도 같다.
##
## 모든 통신은 Api.post_json / get_json 으로만 한다 (HTTPRequest 를 직접 만들지 않는다). 토큰은 Api 가 헤더에 넣고 여기서는 다루지 않는다.
##
## progress(stage, pct, text): pct 는 0..100 전체 진행률로 단조 증가한다. stage:
##   "check" "upload" "queued" 와 서버 단계 이름("decode" "separate" "asr" "align" "enrich" "package"), "download" "install" "done".
## finished(result): {ok, song_id, err_code, message(한국어), warnings: Array, job, upload_id, resumable}
##   resumable: PC 에 작업이 남아 있고 pending 기록도 남았다 -> resume(SongStore.pending_list() 의 해당 기록).
##   upload_id: 조각을 올리다 끊겼으면 start() 를 같은 파일·params + {upload_id: 이 값} 으로 다시 불러 이어 올린다.
##   start()/resume() 를 일하는 중에 또 부르면 무시한다 (busy 속성으로 먼저 확인). 노드는 트리에 넣은 뒤 쓴다.
##   err_code: cancelled transport not_on_phone needs_pc not_connected pc_old app_old bad_args file_open empty_file
##   too_large bad_ext + 서버 코드(bad_audio too_long storage_full queue_full no_job asr_failed no_speech model_missing
##   server_restart internal ...) + 설치 코드(quota_songs quota_bytes sha_mismatch disk_write bad_song).
##   transport / 설치 실패 / sha_mismatch 는 pending 기록을 남기고(서버 결과도 남음), 나머지는 기록을 지운다.
## 시험용 조절: chunk_bytes, poll_interval, retry_delays. 시험 기록: chunk_log(보낸 조각 번호), resyncs.

signal progress(stage: String, pct: float, text: String)
signal finished(result: Dictionary)

const CHUNK_BYTES := 3 * 1024 * 1024
const MAX_FILE_BYTES := 64 * 1024 * 1024
const MAX_PARTS := 64
const EXTS := ["mp3", "ogg", "wav", "m4a", "flac", "aac", "opus"]
const POLL_SEC := 1.5
const RETRY_DELAYS := [0.5, 1.0, 2.0]
const POLL_FAIL_LIMIT := 5
const SONG_V := 1
const MAX_LINES := 400
const MAX_LINE_CHARS := 200
const MAX_LYRIC_CHARS := 20000
const MAX_RESYNC := 8

## 진행률 구간 (전체 0..100)
const PCT_UPLOAD_END := 15.0
const PCT_JOB_END := 85.0
const PCT_DOWNLOAD_END := 95.0

const STAGE_TEXT := {
	"decode": "소리 파일을 읽는 중",
	"separate": "목소리를 분리하는 중",
	"asr": "가사를 받아 적는 중",
	"align": "가사와 시간을 맞추는 중",
	"enrich": "읽기와 해석을 만드는 중",
	"package": "곡을 정리하는 중",
}

const MSG := {
	"cancelled": "취소했어요.",
	"transport": "PC와 연결이 끊겼어요. 연결을 확인한 뒤 다시 시도해 주세요. 작업은 PC에 남아 있어서 이어 받을 수 있어요.",
	"not_connected": "PC에 연결되지 않았어요.",
	"pc_old": "PC 프로그램이 노래 기능을 지원하지 않아요. PC 프로그램을 업데이트해 주세요.",
	"app_old": "PC 프로그램이 더 새 버전이에요. 앱을 업데이트해 주세요.",
	"busy": "이미 곡을 처리하고 있어요.",
	"bad_args": "곡 정보가 올바르지 않아요.",
	"file_open": "파일을 열 수 없어요. 다른 파일을 골라 주세요.",
	"empty_file": "빈 파일이에요. 다른 파일을 골라 주세요.",
	"too_large": "파일이 너무 커요. 64MB 이하의 파일을 골라 주세요.",
	"bad_ext": "mp3, ogg, wav, m4a, flac, aac, opus 파일만 쓸 수 있어요.",
	"bad_audio": "이 파일의 소리를 읽을 수 없어요. 보호된 파일이거나 깨진 파일일 수 있어요. 다른 형식(mp3)으로 바꿔서 다시 시도해 주세요.",
	"too_long": "곡이 너무 길어요. 10분 이하의 곡을 골라 주세요.",
	"storage_full": "PC의 저장 공간이 부족해서 곡을 올릴 수 없어요. 공간을 확보한 뒤 다시 시도해 주세요.",
	"queue_full": "처리 중인 곡이 너무 많아요. 잠시 뒤에 다시 시도해 주세요.",
	"upload_gap": "조각 순서가 맞지 않아 올리지 못했어요. 다시 시도해 주세요.",
	"no_upload": "PC가 올린 파일을 찾지 못했어요. 처음부터 다시 시도해 주세요.",
	"no_job": "PC에서 그 작업을 찾지 못했어요. PC가 다시 시작되었거나 시간이 지나 지워졌을 수 있어요. 처음부터 다시 시도해 주세요.",
	"job_running": "이 곡은 PC에서 이미 처리하고 있어요. 잠시 뒤 다시 확인해 주세요.",
	"not_done": "아직 끝나지 않은 작업이에요.",
	"bad_request": "요청 형식이 올바르지 않아요.",
	"song_unavailable": "이 PC에서는 곡 처리 기능을 쓸 수 없어요. 프로그램을 업데이트하거나 다시 설치해 주세요.",
	"asr_failed": "음성을 받아 적지 못했어요. 다시 시도해 주세요.",
	"no_speech": "소리가 들리지 않는 파일이에요. 다른 파일을 골라 주세요.",
	"model_missing": "음성 인식 모델을 불러오지 못했어요. PC의 설치 상태를 확인해 주세요.",
	"server_restart": "PC 프로그램이 다시 시작되어 작업이 끊겼어요. 같은 파일로 다시 시작해 주세요.",
	"internal": "곡을 처리하다 오류가 났어요. 다시 시도해 주세요.",
	"job_cancelled": "PC에서 작업이 취소되었어요.",
	"bad_response": "PC가 보낸 답을 읽지 못했어요. 다시 시도해 주세요.",
	"sha_mismatch": "내려받은 파일이 깨졌어요. 다시 시도해 주세요. 곡은 PC에 남아 있어요.",
	"disk_write": "이 기기에 저장하지 못했어요. 저장 공간을 확인한 뒤 다시 시도해 주세요. 곡은 PC에 남아 있어요.",
	"bad_song": "처리된 곡에 쓸 수 있는 가사가 없어요. 다른 파일이나 가사로 다시 시도해 주세요.",
	"bad_pending": "이어 받을 작업 정보가 올바르지 않아요.",
}

## 시험용 조절 장치
var chunk_bytes: int = CHUNK_BYTES
var poll_interval: float = POLL_SEC
var retry_delays: Array = RETRY_DELAYS.duplicate()
## 시험 기록: 마지막 run 에서 /song/upload 로 보낸 조각 번호 (실패한 시도 포함), 서버 상태로 맞춘 횟수.
var chunk_log: Array = []
var resyncs: int = 0
var last_progress: Dictionary = {}

var _run: Run = null


## 한 번의 start/resume 의 상태. 취소 뒤 새 start 가 와도 옛 코루틴이 새 상태를 건드리지 않게 따로 둔다.
class Run:
	extends RefCounted
	var src_path: String = ""
	var name: String = ""
	var params: Dictionary = {}
	var upload_id: String = ""
	var preset_upload: bool = false
	var upload_started: bool = false
	var job: String = ""
	var pct: float = 0.0
	var cancel_req: bool = false
	var abandoned: bool = false
	var finished: bool = false
	var committed: bool = false ## the song is installed: a late cancel() changes nothing
	var cur: Variant = null ## 날아가는 Api 호출
	var cur_kind: String = ""
	var timer: Timer = null
	var file: FileAccess = null
	var up_sha: String = ""
	var warnings: Array = []
	var restarts: int = 0


var busy: bool:
	get:
		return _run != null

var job_id: String:
	get:
		return _run.job if _run != null else ""

var upload_id: String:
	get:
		return _run.upload_id if _run != null else ""


# ================================================================ public

## src_path: 곡 파일 (user:// 절대경로 content:// 모두 FileAccess 로 조각씩 읽는다).
## params: {lang: "en"|"ja", title, artist, name(표시 이름, 확장자 판정용), upload_id(이어 올리기: 이전에 쓴 hex32),
##          lyrics: {source: "none"|"pasted"|"lrclib", lrclib_id, lines: [{text, t, p}]},
##          options: {translate, gloss, verify, precise, ai_ok}}
func start(src_path: String, params: Dictionary = {}) -> void:
	if _run != null:
		return ## already working: ignored (check `busy`); the running transfer keeps its own finished signal
	if not is_inside_tree():
		finished.emit(_result_err("bad_args"))
		return
	var r := Run.new()
	r.src_path = src_path
	r.params = params
	_begin(r)
	var res: Dictionary = await _go_new(r)
	_finish(r, res)


## SongStore.pending_list() 의 기록 ({job, upload_id, lang, title, t}) 으로 이어 받는다.
func resume(rec: Dictionary) -> void:
	if _run != null:
		return
	if not is_inside_tree():
		finished.emit(_result_err("bad_args"))
		return
	var r := Run.new()
	r.job = _safe_job(rec.get("job", ""))
	r.upload_id = str(rec.get("upload_id", ""))
	r.params = {"lang": str(rec.get("lang", "en")), "title": str(rec.get("title", "")), "resumed": true}
	_begin(r)
	var res: Dictionary
	if r.job == "":
		res = _result_err("bad_pending")
	else:
		res = await _go_resume(r)
	_finish(r, res)


## 서버에 cancel(작업이 있으면)과 release 를 보내 정리하고 곧바로 finished(cancelled) 를 낸다.
## 조각이나 작업 만들기 요청이 날아가는 중이면 그 요청이 끝난 뒤에 정리한다(늦게 도착한 조각이 폴더를 되살리지 않게).
func cancel() -> void:
	var r: Run = _run
	if r == null or r.finished or r.cancel_req or r.committed:
		return
	r.cancel_req = true
	var inflight: Variant = r.cur
	var kind: String = r.cur_kind
	if inflight != null and kind != "chunk" and kind != "create":
		(inflight as Api.ApiCall).cancel()
		inflight = null
	_wake(r)
	if r.job != "":
		SongStore.pending_remove(r.job)
	var up: String = r.upload_id if (r.upload_started or r.preset_upload) else ""
	_cleanup_server(r.job, up, inflight, kind)
	_finish(r, _result_err("cancelled"))


## 서버에 아무것도 보내지 않고 조용히 멈춘다 (finished 는 나오지 않는다, pending 은 남는다).
func abandon() -> void:
	var r: Run = _run
	if r == null or r.finished:
		return
	r.abandoned = true
	if r.cur != null:
		(r.cur as Api.ApiCall).cancel()
	_wake(r)
	_finish(r, {})


func _exit_tree() -> void:
	abandon()


## 오류 코드의 한국어 안내 (서버가 한국어 문장을 주면 모르는 코드에만 그 문장을 쓴다).
static func message_for(err_code: String, server_msg: String = "") -> String:
	if MSG.has(err_code):
		return str(MSG[err_code])
	match err_code:
		"quota_songs":
			return "곡은 최대 %d곡까지 저장할 수 있어요. 안 쓰는 곡을 지운 뒤 다시 시도해 주세요. 곡은 PC에 남아 있어요." % SongStore.max_songs
		"quota_bytes":
			return "저장 공간이 부족해요(곡 전체 %dMB까지). 안 쓰는 곡을 지운 뒤 다시 시도해 주세요. 곡은 PC에 남아 있어요." % int(SongStore.max_bytes / 1048576)
		"not_on_phone", "needs_pc":
			return Route.text_for(err_code)
	if server_msg != "":
		return server_msg
	return "곡을 가져오지 못했어요. (%s)" % err_code


## 서버 단계/남은 시간을 사람이 읽는 글로.
static func eta_text(eta_sec: Variant) -> String:
	if not (eta_sec is int or eta_sec is float):
		return ""
	var s: int = int(eta_sec)
	if s <= 0:
		return ""
	if s < 60:
		return "약 %d초 남음" % s
	return "약 %d분 남음" % int(ceil(s / 60.0))


# ================================================================ run plumbing

func _begin(r: Run) -> void:
	_run = r
	chunk_log = []
	resyncs = 0
	last_progress = {}


func _stopped(r: Run) -> bool:
	return r.cancel_req or r.abandoned or r.finished


func _wake(r: Run) -> void:
	if r.timer != null and is_instance_valid(r.timer):
		r.timer.stop()
		r.timer.timeout.emit()


func _wait(r: Run, sec: float) -> void:
	if _stopped(r):
		return
	var t := Timer.new()
	t.one_shot = true
	t.wait_time = maxf(sec, 0.01)
	add_child(t)
	r.timer = t
	t.start()
	await t.timeout
	if r.timer == t:
		r.timer = null
	if is_instance_valid(t):
		t.queue_free()


func _finish(r: Run, res: Dictionary) -> void:
	if r.finished:
		return
	r.finished = true
	if r.file != null:
		r.file.close()
		r.file = null
	if _run == r:
		_run = null
	if r.abandoned:
		return
	var out: Dictionary = res.duplicate()
	out["job"] = r.job
	if r.upload_started or r.preset_upload:
		out["upload_id"] = r.upload_id ## start() again with params.upload_id to continue this upload
	## Something to continue later: the PC still holds a finished or running job and the pending record is kept.
	out["resumable"] = bool(out.get("keep_pending", false)) and r.job != ""
	out.erase("keep_pending")
	finished.emit(out)


func _emit(r: Run, stage: String, pct: float, text: String) -> void:
	if _stopped(r):
		return
	r.pct = maxf(r.pct, clampf(pct, 0.0, 100.0))
	last_progress = {"stage": stage, "pct": r.pct, "text": text}
	progress.emit(stage, r.pct, text)


## One Api request. kind: "" (safe to cancel) | "chunk" | "create" (cancel waits for the answer, see cancel()).
func _req(r: Run, post: bool, path: String, body: Dictionary, timeout: float, kind: String = "") -> Dictionary:
	if _stopped(r):
		return _cancelled_res()
	var c: Api.ApiCall = Api.post_json(path, body, timeout, false) if post else Api.get_json(path, timeout, false)
	r.cur = c
	r.cur_kind = kind
	var res: Dictionary = await c.wait()
	if r.cur == c:
		r.cur = null
		r.cur_kind = ""
	return res


func _cancelled_res() -> Dictionary:
	return {"ok": false, "code": 0, "data": null, "error": "", "cancelled": true, "err_code": "cancelled", "err_body": null}


static func _is_transport(res: Dictionary) -> bool:
	if res.get("ok", false) or res.get("cancelled", false):
		return false
	var ec: String = str(res.get("err_code", ""))
	if ec == "transport":
		return true
	var code: int = int(res.get("code", 0))
	return ec == "" and (code == 502 or code == 504)


## An Api failure -> our result dictionary.
static func _api_err(res: Dictionary) -> Dictionary:
	var ec: String = str(res.get("err_code", ""))
	var code: int = int(res.get("code", 0))
	if bool(res.get("cancelled", false)):
		return _result_err("cancelled")
	if ec == "" and (code == 404 or code == 403 or code == 405):
		ec = "pc_old" ## the PC has no /song/* (old program)
	elif ec == "":
		ec = "internal" if code >= 500 else "bad_response"
	return _result_err(ec, str(res.get("error", "")))


static func _result_err(ec: String, server_msg: String = "", keep_pending: bool = false) -> Dictionary:
	return {"ok": false, "song_id": "", "err_code": ec, "message": message_for(ec, server_msg), "warnings": [], "job": "",
		"keep_pending": keep_pending}


static func _safe_job(v: Variant) -> String:
	var s: String = str(v)
	if s.length() != 10 or not s.begins_with("j_"):
		return ""
	for i in range(2, 10):
		var c: int = s.unicode_at(i)
		if not ((c >= 48 and c <= 57) or (c >= 97 and c <= 102)):
			return ""
	return s


static func _is_hex32(s: String) -> bool:
	if s.length() != 32:
		return false
	for i in 32:
		var c: int = s.unicode_at(i)
		if not ((c >= 48 and c <= 57) or (c >= 97 and c <= 102)):
			return false
	return true


## A number the PC sent, as int. Only a real int / finite float inside [lo, hi] counts. A missing key gives `dflt`
## (null = the key is required). Anything else (null, text, array, dictionary, NaN, out of range) gives null = bad answer.
static func _int_at(d: Variant, k: String, dflt: Variant, lo: int, hi: int) -> Variant:
	if not (d is Dictionary):
		return null
	var dd: Dictionary = d
	if not dd.has(k):
		return dflt
	var v: Variant = dd[k]
	var n: int = 0
	if v is int:
		n = v
	elif v is float and is_finite(v) and absf(v) < 4.0e18 and v == floorf(v):
		n = int(v) ## a fraction (40.5) is not a count
	else:
		return null
	return n if (n >= lo and n <= hi) else null


## A boolean the PC sent: only a real bool counts (missing -> dflt, anything else -> null = bad answer).
static func _bool_at(d: Variant, k: String, dflt: Variant) -> Variant:
	if not (d is Dictionary):
		return null
	var dd: Dictionary = d
	if not dd.has(k):
		return dflt
	return dd[k] if dd[k] is bool else null


static var _b64_re: RegEx = null


## Standard base64 text (A-Z a-z 0-9 + / and up to 2 "=" at the end, length a multiple of 4), not empty.
static func _is_base64(t: String) -> bool:
	if t.is_empty() or t.length() % 4 != 0:
		return false
	if _b64_re == null:
		_b64_re = RegEx.new()
		_b64_re.compile("^[A-Za-z0-9+/]+={0,2}$")
	return _b64_re.search(t) != null


static func _bad_res() -> Dictionary:
	return {"ok": false, "code": 200, "data": null, "error": "", "cancelled": false, "err_code": "bad_response", "err_body": null}


## Fire-and-forget server clean-up after a cancel. Static: it must outlive this node and never touch it.
static func _cleanup_server(job: String, up: String, inflight: Variant, kind: String) -> void:
	var jid: String = job
	if inflight != null:
		var res: Dictionary = await (inflight as Api.ApiCall).wait()
		if kind == "create" and jid == "" and res.get("ok", false) and res.get("data") is Dictionary:
			jid = _safe_job((res["data"] as Dictionary).get("job", ""))
	if jid != "":
		await Api.post_json("/song/jobs/cancel", {"job": jid}, 15.0, false).wait()
		await Api.post_json("/song/jobs/release", {"job": jid}, 15.0, false).wait()
	elif up != "":
		await Api.post_json("/song/jobs/release", {"upload_id": up}, 15.0, false).wait()


# ================================================================ start

func _check_route(r: Run) -> Dictionary:
	for probe in [["POST", "/song/upload"], ["GET", "/health"]]:
		if Route.decide(probe[0], probe[1]) == "none":
			var why: Dictionary = Route.why_none(probe[0], probe[1])
			return _result_err(str(why.get("err_code", "needs_pc")), str(why.get("text_ko", "")))
	if Api.base_url == "":
		return _result_err("not_connected")
	return {}


## GET /health: "song" key (old server -> pc_old) and song_v.
func _preflight(r: Run) -> Dictionary:
	_emit(r, "check", 0.0, "PC에 연결하는 중")
	var fails: int = 0
	while true:
		var res: Dictionary = await _req(r, false, "/health", {}, 20.0)
		if _stopped(r):
			return _result_err("cancelled")
		if res.get("ok", false):
			var d: Variant = res.get("data")
			## "song" must be the real boolean true; a missing key or any other type is an answer from a program without the song feature
			if not (d is Dictionary) or _bool_at(d, "song", false) != true:
				return _result_err("pc_old")
			var sv: Variant = _int_at(d, "song_v", 1, 0, 1000000)
			if sv == null:
				return _result_err("bad_response")
			if int(sv) > SONG_V:
				return _result_err("app_old")
			return {}
		if _is_transport(res) and fails < retry_delays.size():
			await _wait(r, float(retry_delays[fails]))
			fails += 1
			continue
		return _api_err(res)
	return {}


func _upload_name(src_path: String, params: Dictionary) -> String:
	var n: String = str(params.get("name", ""))
	if n == "":
		n = src_path.get_file()
	n = n.replace("\\", "/").get_file()
	if "." in n:
		var ext: String = n.get_extension().to_lower()
		if not EXTS.has(ext):
			return ""
		return n
	return "song.mp3" if n == "" else n + ".mp3"


func _go_new(r: Run) -> Dictionary:
	await get_tree().process_frame ## a handler connected right after start() sees every signal
	var p: Dictionary = r.params
	var lang: String = str(p.get("lang", ""))
	if lang != "en" and lang != "ja":
		return _result_err("bad_args")
	var route_err: Dictionary = _check_route(r)
	if not route_err.is_empty():
		return route_err
	r.name = _upload_name(r.src_path, p)
	if r.name == "":
		return _result_err("bad_ext")
	var pre_id: String = str(p.get("upload_id", ""))
	if pre_id != "":
		if not _is_hex32(pre_id):
			return _result_err("bad_args")
		r.upload_id = pre_id
		r.preset_upload = true
	else:
		r.upload_id = Crypto.new().generate_random_bytes(16).hex_encode()
	r.file = FileAccess.open(r.src_path, FileAccess.READ)
	if r.file == null:
		return _result_err("file_open")
	var size: int = r.file.get_length()
	if size <= 0:
		return _result_err("empty_file")
	if size > MAX_FILE_BYTES:
		return _result_err("too_large")
	var pre: Dictionary = await _preflight(r)
	if not pre.is_empty():
		return pre
	var up: Dictionary = await _upload(r, size)
	if not up.is_empty():
		return up
	var jr: Dictionary = await _create_job(r)
	if not jr.is_empty():
		return jr
	if r.file != null:
		r.file.close()
		r.file = null
	return await _run_job(r)


func _go_resume(r: Run) -> Dictionary:
	await get_tree().process_frame
	var route_err: Dictionary = _check_route(r)
	if not route_err.is_empty():
		return route_err
	var pre: Dictionary = await _preflight(r)
	if not pre.is_empty():
		return _keep(pre)
	return await _run_job(r)


static func _keep(res: Dictionary) -> Dictionary:
	if str(res.get("err_code", "")) == "transport":
		res["keep_pending"] = true
	return res


# ================================================================ upload

## Asks the PC how many chunks it has. -> {ok, next, done} or {ok:false, res}
func _server_next(r: Run, total: int) -> Dictionary:
	var res: Dictionary = await _req(r, false, "/song/upload?upload_id=" + r.upload_id, {}, 20.0)
	if res.get("ok", false) and res.get("data") is Dictionary:
		var d: Dictionary = res["data"]
		var nv: Variant = _int_at(d, "next", null, 0, total)
		var dn: Variant = _bool_at(d, "done", false)
		if nv == null or dn == null:
			return {"ok": false, "res": _bad_res()}
		return {"ok": true, "next": total if dn == true else int(nv), "done": dn == true}
	if res.get("ok", false):
		return {"ok": false, "res": _bad_res()} ## 200 but not an object
	return {"ok": false, "res": res}


func _upload(r: Run, size: int) -> Dictionary:
	var cb: int = maxi(1, chunk_bytes)
	var total: int = maxi(1, int(ceil(float(size) / float(cb))))
	var next: int = 0
	if r.preset_upload:
		var st: Dictionary = await _server_next(r, total)
		if _stopped(r):
			return _result_err("cancelled")
		if st["ok"]:
			next = int(st["next"])
		elif str(st["res"].get("err_code", "")) != "no_upload":
			return _keep(_api_err(st["res"]))
	var fails: int = 0
	var resync: int = 0
	var restarts: int = 0
	while next < total:
		if _stopped(r):
			return _result_err("cancelled")
		var off: int = next * cb
		var n: int = mini(cb, size - off)
		r.file.seek(off)
		var buf: PackedByteArray = r.file.get_buffer(n)
		if buf.size() != n:
			return _result_err("file_open")
		_emit(r, "upload", PCT_UPLOAD_END * float(next) / float(total), "올리는 중 %d/%d" % [next + 1, total])
		if _stopped(r):
			return _result_err("cancelled")
		var body: Dictionary = {"upload_id": r.upload_id, "index": next, "total": total, "name": r.name,
			"data_b64": Marshalls.raw_to_base64(buf)}
		buf = PackedByteArray()
		r.upload_started = true
		chunk_log.append(next)
		var last: bool = next == total - 1
		var res: Dictionary = await _req(r, true, "/song/upload", body, 180.0 if last else 120.0, "chunk")
		body = {}
		if _stopped(r):
			return _result_err("cancelled")
		if res.get("ok", false):
			fails = 0
			var dv: Variant = res.get("data")
			var recv: Variant = _int_at(dv, "received", next + 1, 0, total)
			var dne: Variant = _bool_at(dv, "done", false)
			if not (dv is Dictionary) or recv == null or dne == null:
				return _result_err("bad_response")
			var d: Dictionary = dv
			if dne == true:
				r.up_sha = str(d.get("sha256", "")).to_lower()
			next = clampi(maxi(next + 1, int(recv)), 0, total)
			_emit(r, "upload", PCT_UPLOAD_END * float(next) / float(total), "올리는 중 %d/%d" % [mini(next + 1, total), total])
			continue
		var ec: String = str(res.get("err_code", ""))
		if ec == "upload_gap":
			resync += 1
			resyncs += 1
			if resync > MAX_RESYNC:
				return _api_err(res)
			var eb: Variant = res.get("err_body")
			var exp: Variant = _int_at(eb, "expected", null, 0, total)
			if exp == null:
				return _result_err("bad_response") ## a gap answer must say where to continue
			next = int(exp)
			continue
		if _is_transport(res):
			fails += 1
			if fails > retry_delays.size():
				return _keep(_result_err("transport", "", true))
			await _wait(r, float(retry_delays[fails - 1]))
			if _stopped(r):
				return _result_err("cancelled")
			var st2: Dictionary = await _server_next(r, total) ## the PC may already have the chunk whose answer was lost
			if _stopped(r):
				return _result_err("cancelled")
			resyncs += 1
			if st2["ok"]:
				next = int(st2["next"])
			elif str(st2["res"].get("err_code", "")) == "bad_response":
				return _result_err("bad_response")
			elif str(st2["res"].get("err_code", "")) == "no_upload":
				if next > 0:
					restarts += 1
					if restarts > 1:
						return _api_err(st2["res"])
					next = 0 ## the PC lost the upload (restart / cleaned up): start over once
			continue
		return _api_err(res)
	_emit(r, "upload", PCT_UPLOAD_END, "올리기 끝")
	return {}


# ================================================================ job

static func _job_lines(lines: Variant) -> Array:
	var out: Array = []
	var chars: int = 0
	if not (lines is Array):
		return out
	for it in (lines as Array):
		if out.size() >= MAX_LINES:
			break
		if not (it is Dictionary):
			continue
		var text: String = str(it.get("text", "")).strip_edges()
		if text.length() > MAX_LINE_CHARS:
			text = text.substr(0, MAX_LINE_CHARS)
		if chars + text.length() > MAX_LYRIC_CHARS:
			break
		chars += text.length()
		var t: Variant = it.get("t", null)
		var tv: Variant = null
		if (t is int or t is float) and is_finite(float(t)) and float(t) >= 0.0 and float(t) <= 86400.0:
			tv = float(t)
		var pv: int = clampi(int(it.get("p", 0)) if (it.get("p", 0) is int or it.get("p", 0) is float) else 0, 0, 9999)
		out.append({"text": text, "t": tv, "p": pv})
	return out


static func job_body(upload_id: String, p: Dictionary) -> Dictionary:
	var ly: Dictionary = p.get("lyrics", {}) if p.get("lyrics", {}) is Dictionary else {}
	var source: String = str(ly.get("source", "none"))
	if not ["none", "pasted", "lrclib"].has(source):
		source = "none"
	var lyrics: Dictionary = {"source": source}
	if source != "none":
		lyrics["lines"] = _job_lines(ly.get("lines", []))
		var lid: Variant = ly.get("lrclib_id", null)
		if source == "lrclib" and (lid is int or lid is float) and float(lid) >= 0.0:
			lyrics["lrclib_id"] = int(lid)
	else:
		lyrics["lines"] = []
	var o: Dictionary = p.get("options", {}) if p.get("options", {}) is Dictionary else {}
	var opts := {}
	for k in [["translate", true], ["gloss", true], ["verify", true], ["precise", false], ["ai_ok", false]]:
		var v: Variant = o.get(k[0], k[1])
		opts[k[0]] = v if v is bool else k[1] ## the PC rejects anything but a real boolean
	return {"upload_id": upload_id, "lang": str(p.get("lang", "en")),
		"title": str(p.get("title", "")).substr(0, 200), "artist": str(p.get("artist", "")).substr(0, 200),
		"lyrics": lyrics, "options": opts}


func _put_pending(r: Run) -> void:
	SongStore.pending_put({"job": r.job, "upload_id": r.upload_id, "lang": str(r.params.get("lang", "en")),
		"title": str(r.params.get("title", "")), "t": int(Time.get_unix_time_from_system())})


func _create_job(r: Run) -> Dictionary:
	_emit(r, "queued", PCT_UPLOAD_END, "작업을 시작하는 중")
	var body: Dictionary = job_body(r.upload_id, r.params)
	var fails: int = 0
	var uncertain: bool = false ## an earlier try may have created the job without us seeing the answer
	while true:
		var res: Dictionary = await _req(r, true, "/song/jobs", body, 60.0, "create")
		if _stopped(r):
			return _result_err("cancelled")
		if res.get("ok", false) and res.get("data") is Dictionary:
			var jid: String = _safe_job((res["data"] as Dictionary).get("job", ""))
			if jid == "":
				return _result_err("bad_response")
			r.job = jid
			_put_pending(r)
			return {}
		var ec: String = str(res.get("err_code", ""))
		if _is_transport(res):
			uncertain = true
			fails += 1
			if fails > retry_delays.size():
				return _keep(_result_err("transport", "", true))
			await _wait(r, float(retry_delays[fails - 1]))
			if _stopped(r):
				return _result_err("cancelled")
			continue
		if ec == "job_running" and uncertain:
			return _result_err("job_running")
		return _api_err(res)
	return {}


func _status_text(d: Dictionary, spct: int, qp: int) -> String:
	var state: String = str(d.get("state", ""))
	if state == "queued":
		return "순서를 기다리는 중" if qp <= 0 else "순서를 기다리는 중 (앞에 %d곡)" % qp
	var stage: String = str(d.get("stage", ""))
	var msg: String = str(STAGE_TEXT.get(stage, ""))
	if msg == "":
		msg = str(d.get("message_ko", "")).strip_edges()
	if msg == "":
		msg = "곡을 만드는 중"
	var out: String = "%s %d%%" % [msg, spct]
	var eta: String = eta_text(d.get("eta_sec", null))
	if eta != "":
		out += " · " + eta
	return out


## status polling -> result -> audio -> install -> release.
func _run_job(r: Run) -> Dictionary:
	var fails: int = 0
	var wait_done: int = 0
	var st_warnings: Array = []
	while true:
		if _stopped(r):
			return _result_err("cancelled")
		var res: Dictionary = await _req(r, false, "/song/jobs/status?job=" + r.job, {}, 20.0)
		if _stopped(r):
			return _result_err("cancelled")
		if not res.get("ok", false):
			if _is_transport(res):
				fails += 1
				if fails >= POLL_FAIL_LIMIT:
					return _result_err("transport", "", true)
				await _wait(r, poll_interval)
				continue
			if int(res.get("code", 0)) < 500:
				SongStore.pending_remove(r.job) ## the job is gone (no_job) or the request is wrong: nothing to resume
			return _api_err(res)
		fails = 0
		var d: Dictionary = res["data"] if res.get("data") is Dictionary else {}
		var state: String = str(d.get("state", ""))
		if state == "queued" or state == "running":
			var pv: Variant = _int_at(d, "pct", 0, 0, 100)
			var qv: Variant = _int_at(d, "queue_pos", 0, 0, 1000000)
			if pv == null or qv == null:
				SongStore.pending_remove(r.job)
				return _result_err("bad_response")
			var spct: float = float(int(pv))
			var stage: String = "queued" if state == "queued" else (str(d.get("stage", "")) if str(d.get("stage", "")) != "" else "decode")
			_emit(r, stage, PCT_UPLOAD_END + (PCT_JOB_END - PCT_UPLOAD_END) * spct / 100.0, _status_text(d, int(pv), int(qv)))
		elif state == "done":
			if d.get("warnings") is Array:
				st_warnings = (d["warnings"] as Array).duplicate()
			_emit(r, "package", PCT_JOB_END, "곡을 내려받는 중")
			var got: Dictionary = await _finish_job(r, st_warnings)
			if str(got.get("err_code", "")) == "not_done" and wait_done < POLL_FAIL_LIMIT:
				wait_done += 1
				await _wait(r, poll_interval)
				continue
			return got
		elif state == "failed":
			var code: String = "internal"
			var smsg: String = ""
			if d.get("error") is Dictionary:
				code = str((d["error"] as Dictionary).get("code", "internal"))
				smsg = str((d["error"] as Dictionary).get("message", ""))
			if code == "server_restart" and r.restarts < 1 and r.src_path != "" and not bool(r.params.get("resumed", false)):
				## the PC restarted but still has the upload: start the same job again with the same lyrics
				r.restarts += 1
				SongStore.pending_remove(r.job)
				r.job = ""
				var again: Dictionary = await _create_job(r)
				if not again.is_empty():
					return again
				fails = 0
				continue
			SongStore.pending_remove(r.job)
			await _release_job(r)
			return _result_err(code, smsg)
		elif state == "cancelled":
			SongStore.pending_remove(r.job)
			await _release_job(r)
			return _result_err("job_cancelled")
		else:
			SongStore.pending_remove(r.job)
			return _result_err("bad_response")
		await _wait(r, poll_interval)
	return {}


func _release_job(r: Run) -> void:
	if r.job == "":
		return
	for i in 2:
		var res: Dictionary = await _req(r, true, "/song/jobs/release", {"job": r.job}, 20.0)
		if res.get("ok", false) or not _is_transport(res):
			return


## GET /song/result + /song/audio (parts) + sha256 check + install + release.
func _finish_job(r: Run, st_warnings: Array) -> Dictionary:
	var rr: Dictionary = await _retry_get(r, "/song/result?job=" + r.job, 60.0)
	if _stopped(r):
		return _result_err("cancelled")
	if not rr.get("ok", false):
		var e: Dictionary = _api_err(rr)
		if str(e["err_code"]) == "transport":
			e["keep_pending"] = true
		elif str(e["err_code"]) != "not_done":
			SongStore.pending_remove(r.job)
		return e
	if not (rr.get("data") is Dictionary):
		return _result_err("bad_response", "", true)
	var song: Dictionary = (rr["data"] as Dictionary).duplicate(true)
	var audio: PackedByteArray = PackedByteArray()
	var tries: int = 0
	var fa: Dictionary = {}
	while tries < 2:
		tries += 1
		fa = await _fetch_audio(r, song)
		if _stopped(r):
			return _result_err("cancelled")
		if fa.get("ok", false):
			audio = fa["audio"]
			break
		if str(fa.get("err_code", "")) != "sha_mismatch":
			break
	if not fa.get("ok", false):
		return fa ## sha_mismatch / transport / ...: no release, the pending record stays (the song is still on the PC)
	_emit(r, "install", PCT_DOWNLOAD_END, "저장하는 중")
	var inst: Dictionary = _install(r, song, audio)
	audio = PackedByteArray()
	if inst.get("ok", false):
		r.committed = true
	if not inst.get("ok", false):
		var ec: String = str(inst.get("err_code", "disk_write"))
		var res: Dictionary = _result_err(ec, "", ec != "bad_song")
		if ec == "bad_song":
			SongStore.pending_remove(r.job)
		return res
	## installed: only now forget the pending record and release the PC's copy
	SongStore.pending_remove(r.job)
	_emit(r, "install", 99.0, "정리하는 중")
	await _release_job(r)
	var warns: Array = []
	for w in (st_warnings + (song.get("warnings", []) if song.get("warnings") is Array else [])):
		if w is String and not warns.has(w):
			warns.append(w)
	_emit(r, "done", 100.0, "곡을 가져왔어요")
	return {"ok": true, "song_id": str(inst["id"]), "err_code": "", "message": "곡을 가져왔어요.", "warnings": warns, "job": r.job,
		"keep_pending": false}


## GET with the 3 transport retries.
func _retry_get(r: Run, path: String, timeout: float) -> Dictionary:
	var fails: int = 0
	while true:
		var res: Dictionary = await _req(r, false, path, {}, timeout)
		if _stopped(r) or res.get("ok", false) or not _is_transport(res):
			return res
		fails += 1
		if fails > retry_delays.size():
			return res
		await _wait(r, float(retry_delays[fails - 1]))
		if _stopped(r):
			return _cancelled_res()
	return {}


## Downloads every part and checks the whole file against the sha256 the PC announced (part answers, song.audio, upload).
func _fetch_audio(r: Run, song: Dictionary) -> Dictionary:
	var audio := PackedByteArray()
	var parts: int = 0
	var part: int = 0
	var server_sha: String = ""
	var total_bytes: int = 0
	while parts == 0 or part < parts:
		if _stopped(r):
			return _result_err("cancelled")
		var frac: float = float(part) / float(maxi(parts, 1))
		_emit(r, "download", PCT_JOB_END + (PCT_DOWNLOAD_END - PCT_JOB_END) * frac,
			"내려받는 중 %d/%d" % [part + 1, maxi(parts, 1)])
		var res: Dictionary = await _retry_get(r, "/song/audio?job=%s&part=%d" % [r.job, part], 120.0)
		if _stopped(r):
			return _result_err("cancelled")
		if not res.get("ok", false):
			var e: Dictionary = _api_err(res)
			if str(e["err_code"]) == "transport":
				e["keep_pending"] = true
			return e
		if not (res.get("data") is Dictionary):
			return _result_err("bad_response", "", true)
		var d: Dictionary = res["data"]
		var pn_v: Variant = _int_at(d, "parts", null, 1, MAX_PARTS)
		var pi_v: Variant = _int_at(d, "part", null, 0, MAX_PARTS)
		var nb_v: Variant = _int_at(d, "bytes", null, 1, MAX_FILE_BYTES)
		if pn_v == null or pi_v == null or nb_v == null or not (d.get("data_b64") is String) or not (d.get("sha256") is String):
			return _result_err("bad_response", "", true)
		var tb_v: Variant = _int_at(d, "total_bytes", null, 1, MAX_FILE_BYTES) if part == 0 else 0
		if tb_v == null:
			return _result_err("bad_response", "", true)
		var pn: int = int(pn_v)
		if int(pi_v) != part or (parts != 0 and pn != parts):
			return _result_err("sha_mismatch", "", true)
		parts = pn
		if not _is_base64(str(d["data_b64"])):
			return _result_err("bad_response", "", true)
		var raw: PackedByteArray = Marshalls.base64_to_raw(str(d["data_b64"]))
		if raw.size() != int(nb_v) or raw.is_empty():
			return _result_err("sha_mismatch", "", true)
		var psha: String = str(d.get("sha256", "")).to_lower()
		if part == 0:
			server_sha = psha
			total_bytes = int(tb_v)
		elif psha != server_sha:
			return _result_err("sha_mismatch", "", true)
		audio.append_array(raw)
		if audio.size() > MAX_FILE_BYTES:
			return _result_err("sha_mismatch", "", true)
		part += 1
	var got: String = SongStore.sha256_hex(audio)
	var meta_sha: String = ""
	if song.get("audio") is Dictionary:
		meta_sha = str((song["audio"] as Dictionary).get("sha256", "")).to_lower()
	var good: bool = SongModel.hex64(server_sha) != "" and got == server_sha and audio.size() == total_bytes
	if meta_sha != "" and meta_sha != got:
		good = false
	if r.up_sha != "" and r.up_sha != got:
		good = false
	if not good:
		return _result_err("sha_mismatch", "", true)
	return {"ok": true, "audio": audio}


func _install(r: Run, song: Dictionary, audio: PackedByteArray) -> Dictionary:
	var s: Dictionary = song.duplicate(true)
	s.erase("id") ## the new id comes from SongStore.new_id() inside install
	if str(s.get("title", "")).strip_edges() == "":
		s["title"] = str(r.params.get("title", ""))
	if str(s.get("artist", "")).strip_edges() == "":
		s["artist"] = str(r.params.get("artist", ""))
	var norm: Dictionary = SongModel.normalize(s)
	if norm.is_empty():
		return {"ok": false, "id": "", "err_code": "bad_song"}
	return SongStore.install(norm, audio)
