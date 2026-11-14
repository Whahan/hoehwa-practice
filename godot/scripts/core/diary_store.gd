class_name DiaryStore
extends RefCounted
## 한 줄 일기 저장소 (user://diary.json). 설계 docs/v170_design.md §2.4, §2.5.
##
## 이 기기 전용이다: 동기화(SyncDoc / SyncMerge)·studylog.json·progress.json 어디에도 일기 글을 넣지 않는다.
## "모든 기록 지우기"(Store.reset_progress)도 일기를 지우지 않는다. 일기는 remove() / clear() 로만 지운다.
## 글이 사용자가 쓴 것이라서 이 파일은 일기 글을 print / push_warning / 토스트로 내보내지 않는다.
##
## 파일 모양 (v1)
##   {"v":1,
##    "entries":[{"id":"d1731571200123", "date":"2026-11-14", "lang":"ja", "created":1731571200, "text":"...",
##                "state":"fixed", "items":[{"orig":"..","fix":"..","why":"..","reading":"..","pron":"..","same":false,"card":true}],
##                "fixed_at":1731571300}],
##    "cards_by_day":{"2026-11-14":2}}
##
## 읽을 때(_normalize)와 쓸 때 규칙을 강제한다:
##   entries 최대 MAX_ENTRIES(가득 차면 새 글은 거절, 조용히 지우지 않는다), id 는 ^d[0-9]{6,20}$ 이고 겹치지 않음,
##   date 는 실제 달력의 YYYY-MM-DD, lang 은 en|ja, text 는 1~300자, state 는 saved|fixed, items 는 0~3개(saved 는 []),
##   orig<=120 fix<=300 why<=200 reading/pron<=300 (넘으면 자름), cards_by_day 는 최근 14일만·값 0~100,
##   모르는 최상위 키는 그대로 보존한다.
##   구조가 틀린 일기(글이 문자열이 아님·401자·날짜 오류·모르는 state·겹친 id…)는 버린다. 하나라도 버렸으면
##   원래 파일을 먼저 `diary.json.bad` 로 옮겨 두고(Progress.quarantine) 정리한 내용을 새로 쓴다: 글이 사라지지 않는다.
## 파일이 깨졌으면(JSON 아님) 기존 방식대로 `.bad` 로 옮기고 빈 상태. 있는데 열 수 없으면 읽기 전용: 이번 실행은 저장하지 않는다.
## 쓰기는 Progress.write_text_atomic (임시 파일 -> 이름 바꾸기). 쓰기가 실패하면 메모리도 되돌린다.

const VERSION := 1
const MAX_ENTRIES := 1000
const MAX_TEXT := 300
const MAX_ITEMS := 3
const MAX_ORIG := 120
const MAX_FIX := 300
const MAX_WHY := 200
const MAX_READING := 300
const KEEP_CARD_DAYS := 14
const MAX_CARDS_VALUE := 100
const MAX_TS := 9999999999999
const LANGS := ["en", "ja"]
const STATES := ["saved", "fixed"]
const GUARD_DIR := "user://test_guard"
const CLEAN_LIMIT := 4096 ## clean_text() looks at this many characters at most
const ID_PATTERN := "^d[0-9]{6,20}$"

static var path := "user://diary.json"
## Tests only: pretend today is this day number (Plan.days_from_civil). -1 = system clock.
static var today_override: int = -1
## Tests only: pretend "now" is this unix time. -1 = system clock.
static var unix_override: int = -1
## "new" | "ok" | "empty" | "bad" | "unreadable" -- how the last load_from_disk() went.
static var last_load_status: String = ""
## How many entries (or whole lists) the last load had to throw away (their raw file went to `.bad`).
static var last_dropped: int = 0

static var _data: Dictionary = {}
static var _loaded: bool = false
static var _loaded_path: String = ""
static var _read_only: bool = false
static var _seq: int = 0
static var _id_rx: RegEx = null


# ---------------------------------------------------------------- clock / paths

static func today_days() -> int:
	return today_override if today_override >= 0 else Plan.today_days()


static func today_iso() -> String:
	return Plan.days_to_iso(today_days())


static func _now() -> int:
	return unix_override if unix_override >= 0 else int(Time.get_unix_time_from_system())


## The file that is really read and written. While the test guard is on, the real `user://diary.json`
## (by name, see Progress.REAL_FILE_NAMES) becomes `user://test_guard/diary.json`; any other path is used as it is.
static func effective_path() -> String:
	if Progress.guard_blocks(path):
		return GUARD_DIR.path_join(path.get_file())
	return path


# ---------------------------------------------------------------- load / save

static func _blank() -> Dictionary:
	return {"v": VERSION, "entries": [], "cards_by_day": {}}


static func _ensure() -> void:
	if not _loaded or _loaded_path != effective_path():
		load_from_disk()


## Forget what is in memory (the next call reads the file again). Tests use it after they change `path`.
static func forget() -> void:
	_loaded = false
	_loaded_path = ""
	_data = _blank()
	_read_only = false


## Reads the file. There is deliberately no function called reload (Godot's built-in GDScript.reload() would reset the statics).
static func load_from_disk() -> void:
	var p: String = effective_path()
	_loaded = true
	_loaded_path = p
	_read_only = false
	_data = _blank()
	last_dropped = 0
	var r: Dictionary = Progress.read_json_file(p)
	last_load_status = str(r["status"])
	if last_load_status == "unreadable":
		_read_only = true
		Toast.info("일기 파일을 읽지 못했어요. 이번에는 일기를 저장하지 않고, 다음에 다시 시도해요.")
		return
	if last_load_status != "ok":
		return ## new / empty / bad (read_json_file already moved a broken file to .bad)
	_data = _normalize(r["data"] as Dictionary)
	if last_dropped > 0:
		# Something could not be understood: keep the raw file as `.bad` before writing the cleaned one over it.
		Progress.quarantine(p)
		if not _write():
			var gp: String = ProjectSettings.globalize_path(p)
			if FileAccess.file_exists(gp + ".bad") and not FileAccess.file_exists(gp):
				DirAccess.rename_absolute(gp + ".bad", gp) ## put the original back; do not save over it this run
			_read_only = true


static func _write() -> bool:
	if _read_only:
		return false
	_prune_cards()
	var p: String = effective_path()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(p.get_base_dir()))
	return Progress.write_text_atomic(p, JSON.stringify(_data, "\t"))


## Writes the in-memory data; when that fails, `backup` (the state before the change) comes back.
static func _commit(backup: Dictionary) -> bool:
	if _write():
		return true
	_data = backup
	return false


static func _prune_cards() -> void:
	var cards: Dictionary = _data["cards_by_day"]
	var oldest: int = today_days() - (KEEP_CARD_DAYS - 1)
	for k in cards.keys():
		if not (k is String) or not Plan.is_valid_iso(k) or Plan.iso_to_days(k) < oldest:
			cards.erase(k)


# ---------------------------------------------------------------- normalizing (anything read from disk)

static func _int_field(v: Variant, hi: int) -> int:
	if (v is int) or (v is float and is_finite(v)):
		return clampi(int(v), 0, hi)
	return 0


## Booleans from disk: only true / a non-zero number count as true (bool("yes") is an error in GDScript).
static func as_bool(v: Variant) -> bool:
	if v is bool:
		return v
	if v is int or v is float:
		return v != 0
	return false


static func _s(v: Variant, cap: int) -> String:
	if not (v is String):
		return ""
	var t: String = DiaryLogic._trim(clean_text(v))
	return t if t.length() <= cap else t.substr(0, cap)


static func _is_id(v: Variant) -> bool:
	if not (v is String):
		return false
	if _id_rx == null:
		_id_rx = RegEx.new()
		_id_rx.compile(ID_PATTERN)
	return _id_rx.search(v) != null


## Strips control characters (newlines stay, tabs become a space), \r\n -> \n, and trims the ends.
static func clean_text(s: String) -> String:
	if s.length() > CLEAN_LIMIT:
		s = s.substr(0, CLEAN_LIMIT) ## far over every limit anyway; keeps a huge input from being scanned character by character
	var t: String = s.replace("\r\n", "\n").replace("\r", "\n")
	var out := ""
	for i in t.length():
		var cp: int = t.unicode_at(i)
		if cp == 10:
			out += "\n"
		elif cp == 9:
			out += " "
		elif cp == 0x2028 or cp == 0x2029:
			out += "\n"
		elif cp < 32 or cp == 127 or (cp >= 0x80 and cp < 0xA0) or cp == 0xFEFF or (cp >= 0x200B and cp <= 0x200F) or (cp >= 0x202A and cp <= 0x202E):
			continue
		else:
			out += t[i]
	return DiaryLogic._trim(out.strip_edges())


static func _norm_item(v: Variant) -> Dictionary:
	if not (v is Dictionary):
		return {}
	var d: Dictionary = v
	var fix: String = _s(d.get("fix", ""), MAX_FIX)
	return {
		"orig": _s(d.get("orig", ""), MAX_ORIG),
		"fix": fix,
		"why": _s(d.get("why", ""), MAX_WHY),
		"reading": _s(d.get("reading", ""), MAX_READING),
		"pron": _s(d.get("pron", ""), MAX_READING),
		"same": as_bool(d.get("same", false)) or fix == "",
		"card": as_bool(d.get("card", false)),
	}


static func _norm_items(v: Variant) -> Array:
	var out: Array = []
	if v is Array:
		for it in v:
			if out.size() >= MAX_ITEMS:
				break
			var ni: Dictionary = _norm_item(it)
			if not ni.is_empty() and not as_bool((it as Dictionary).get("bad", false)):
				out.append(ni)
	return out


## One entry from disk, or {} when its identity fields are wrong (the caller counts it as dropped).
static func _norm_entry(v: Variant, seen_ids: Dictionary) -> Dictionary:
	if not (v is Dictionary):
		return {}
	var e: Dictionary = v
	if not _is_id(e.get("id", null)) or seen_ids.has(e["id"]):
		return {}
	if not (e.get("lang", null) is String) or not LANGS.has(e["lang"]):
		return {}
	if not (e.get("text", null) is String):
		return {}
	var text: String = clean_text(e["text"])
	if text == "" or text.length() > MAX_TEXT:
		return {}
	if not (e.get("date", null) is String) or not Plan.is_valid_iso(e["date"]):
		return {}
	if not (e.get("state", null) is String) or not STATES.has(e["state"]):
		return {}
	seen_ids[e["id"]] = true
	var fixed: bool = e["state"] == "fixed"
	return {
		"id": e["id"],
		"date": e["date"],
		"lang": e["lang"],
		"created": _int_field(e.get("created", 0), MAX_TS),
		"text": text,
		"state": e["state"],
		"items": _norm_items(e.get("items", [])) if fixed else [],
		"fixed_at": _int_field(e.get("fixed_at", 0), MAX_TS) if fixed else 0,
	}


static func _normalize(raw: Dictionary) -> Dictionary:
	var out: Dictionary = _blank()
	for k in raw.keys():
		if not (k in ["v", "entries", "cards_by_day"]):
			out[k] = raw[k] ## unknown top-level keys survive (a newer app may have added them)
	var ver: Variant = raw.get("v", 1)
	if (ver is int or (ver is float and is_finite(ver))) and int(ver) >= 1:
		out["v"] = int(ver)
	var entries: Array = []
	var seen := {}
	var src: Variant = raw.get("entries", [])
	if src is Array:
		for e in src:
			var ne: Dictionary = _norm_entry(e, seen)
			if ne.is_empty():
				last_dropped += 1
			else:
				entries.append(ne)
	elif raw.has("entries"):
		last_dropped += 1 ## entries is not a list: nothing in it can be used (the raw file is kept as .bad)
	if entries.size() > MAX_ENTRIES:
		last_dropped += entries.size() - MAX_ENTRIES
		entries = entries.slice(entries.size() - MAX_ENTRIES) ## the oldest go (the newest are last in the file)
	out["entries"] = entries
	var cards := {}
	var cb: Variant = raw.get("cards_by_day", {})
	if cb is Dictionary:
		var oldest: int = today_days() - (KEEP_CARD_DAYS - 1)
		for k in (cb as Dictionary).keys():
			var n: Variant = (cb as Dictionary)[k]
			if k is String and Plan.is_valid_iso(k) and Plan.iso_to_days(k) >= oldest and ((n is int) or (n is float and is_finite(n))):
				cards[k] = clampi(int(n), 0, MAX_CARDS_VALUE)
	out["cards_by_day"] = cards
	return out


# ---------------------------------------------------------------- reading

static func is_read_only() -> bool:
	_ensure()
	return _read_only


## Entries of one language ("" = both), newest first. Copies: changing them does not change the store.
static func entries(lang: String = "") -> Array:
	_ensure()
	var out: Array = []
	var arr: Array = _data["entries"]
	var i: int = arr.size() - 1
	while i >= 0:
		var e: Dictionary = arr[i]
		if lang == "" or e["lang"] == lang:
			out.append(e.duplicate(true))
		i -= 1
	return out


static func get_entry(id: String) -> Dictionary:
	_ensure()
	for e in _data["entries"]:
		if (e as Dictionary)["id"] == id:
			return (e as Dictionary).duplicate(true)
	return {}


## Entries still waiting for the AI to fix them (state "saved"), newest first.
static func pending(lang: String = "") -> Array:
	var out: Array = []
	for e in entries(lang):
		if (e as Dictionary)["state"] == "saved":
			out.append(e)
	return out


## {"entries": n, "days": number of different dates, "fixed": n}: for badges. No text in it.
static func counts(lang: String = "") -> Dictionary:
	_ensure()
	var days := {}
	var n := 0
	var fixed := 0
	for e in _data["entries"]:
		var d: Dictionary = e
		if lang != "" and d["lang"] != lang:
			continue
		n += 1
		days[d["date"]] = true
		if d["state"] == "fixed":
			fixed += 1
	return {"entries": n, "days": days.size(), "fixed": fixed}


## Review cards the diary has put in today (the daily cap is DiaryLogic.CARDS_PER_DAY).
static func cards_today() -> int:
	_ensure()
	return int((_data["cards_by_day"] as Dictionary).get(today_iso(), 0))


# ---------------------------------------------------------------- writing

static func _res(ok: bool, id: String, reason: String, existed: bool = false) -> Dictionary:
	return {"ok": ok, "id": id, "reason": reason, "existed": existed}


static func _new_id(taken: Dictionary) -> String:
	var base: int = _now() * 1000 + (Time.get_ticks_msec() % 1000)
	while true:
		_seq += 1
		var id: String = "d%06d" % (base + _seq)
		if not taken.has(id):
			return id
	return ""


## Saves a new entry (state "saved"). The same (lang, date, text) again does not make a second entry: the old one is
## kept (its `created` becomes now) and `existed` is true.
## -> {"ok": bool, "id": String, "reason": "" | "full" | "read_only" | "invalid" | "write_failed", "existed": bool}
##   full = MAX_ENTRIES entries already (nothing is deleted for you), invalid = lang not en/ja or text empty / over 300 chars.
static func add(lang: String, text: String) -> Dictionary:
	_ensure()
	if _read_only:
		return _res(false, "", "read_only")
	var t: String = clean_text(text)
	if not LANGS.has(lang) or t == "" or t.length() > MAX_TEXT:
		return _res(false, "", "invalid")
	var date: String = today_iso()
	var backup: Dictionary = _data.duplicate(true)
	var arr: Array = _data["entries"]
	var taken := {}
	for e in arr:
		var d: Dictionary = e
		taken[d["id"]] = true
		if d["lang"] == lang and d["date"] == date and d["text"] == t:
			d["created"] = clampi(_now(), 0, MAX_TS)
			if not _commit(backup):
				return _res(false, "", "write_failed")
			return _res(true, str(d["id"]), "", true)
	if arr.size() >= MAX_ENTRIES:
		return _res(false, "", "full")
	var id: String = _new_id(taken)
	arr.append({"id": id, "date": date, "lang": lang, "created": clampi(_now(), 0, MAX_TS), "text": t,
		"state": "saved", "items": [], "fixed_at": 0})
	if not _commit(backup):
		return _res(false, "", "write_failed")
	return _res(true, id, "")


## The AI fixed the entry: state "fixed" and `items` (at most 3; bad ones are left out). False when the id is unknown,
## the store is read-only, or the file could not be written (then nothing changed).
static func set_fixed(id: String, items: Array) -> bool:
	_ensure()
	if _read_only:
		return false
	var backup: Dictionary = _data.duplicate(true)
	for e in _data["entries"]:
		var d: Dictionary = e
		if d["id"] == id:
			d["state"] = "fixed"
			d["items"] = _norm_items(items)
			d["fixed_at"] = clampi(_now(), 0, MAX_TS)
			return _commit(backup)
	return false


static func remove(id: String) -> bool:
	_ensure()
	if _read_only:
		return false
	var backup: Dictionary = _data.duplicate(true)
	var arr: Array = _data["entries"]
	for i in arr.size():
		if (arr[i] as Dictionary)["id"] == id:
			arr.remove_at(i)
			return _commit(backup)
	return false


## Deletes every entry (of one language when `lang` is given). Returns how many were deleted (0 when the file could not be written).
static func clear(lang: String = "") -> int:
	_ensure()
	if _read_only:
		return 0
	var backup: Dictionary = _data.duplicate(true)
	var keep: Array = []
	var gone := 0
	for e in _data["entries"]:
		if lang == "" or (e as Dictionary)["lang"] == lang:
			gone += 1
		else:
			keep.append(e)
	if gone == 0:
		return 0
	_data["entries"] = keep
	if not _commit(backup):
		return 0
	return gone


## Counts n review cards added today (kept 14 days). Not saved when read-only.
static func note_cards(n: int) -> void:
	_ensure()
	if n <= 0 or _read_only:
		return
	var backup: Dictionary = _data.duplicate(true)
	var cards: Dictionary = _data["cards_by_day"]
	var key: String = today_iso()
	cards[key] = mini(MAX_CARDS_VALUE, int(cards.get(key, 0)) + n)
	_commit(backup)
