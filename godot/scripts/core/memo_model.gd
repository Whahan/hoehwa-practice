class_name MemoModel
extends RefCounted
## 가사 외우기: 곡 폴더의 memo.json(줄마다의 외우기 기록) 보정기와 줄 키·요약·오늘 큐. 순수 함수
## (파일·네트워크·시계·난수·전역 상태를 쓰지 않는다. 시각은 now 로 받는다). 설계 docs/lyrics_memorize_design.md §5.3·§5.4.
##
##   memo.json (v1): {"v": 1, "lines": {<줄 키 12자>: {"stage", "seen", "tries", "passes", "card": FSRS 카드}},
##                    "stats": {"sessions", "last"}, "app": ""}
##   - 줄 키 = 줄 글자를 정규화(TextSim.norm_text)해 sha256 앞 12자리. 같은 키는 한 줄로 센다(후렴 묶기, 결정 Q2).
##     memo.json 에는 가사 글자가 없다 (해시 키와 숫자뿐).
##   - normalize 는 읽을 때마다 거친다: 잘못된 키·항목은 버리고, 숫자는 한도 안으로, 복구할 수 없는 카드는 버려
##     그 줄을 새 줄로 되돌린다. v > 1 이면 읽기 전용(is_read_only): 보정은 하되 저장은 SongStore 가 거절한다.
##   - 동기화·백업 대상이 아니다 (곡 폴더 안 파일).

const CURRENT_V := 1
const MAX_LINES := 400 ## 곡의 외울 줄 상한 (SongModel.MAX_LINES 와 같다)
const MAX_STAGE := 8
const MAX_COUNT := 1000000000
const MAX_TIME := 4102444800
const MAX_STABILITY := 100000.0
const MAX_DIFFICULTY := 100.0
const MAX_STEP := 100
const PRUNE_DAYS := 30
const REVIEW_CAP := 20
const NEW_CAP := 5
const KEY_LEN := 12

static var _rx_letter: RegEx = null


# ---------------------------------------------------------------- memo document

static func new_memo() -> Dictionary:
	return {"v": CURRENT_V, "lines": {}, "stats": {"sessions": 0, "last": 0}, "app": ""}


static func is_read_only(memo: Dictionary) -> bool:
	return int(memo.get("v", CURRENT_V)) > CURRENT_V


static func is_valid_key(k: Variant) -> bool:
	if not (k is String):
		return false
	var s: String = k
	if s.length() != KEY_LEN:
		return false
	for i in KEY_LEN:
		var c: int = s.unicode_at(i)
		if not ((c >= 48 and c <= 57) or (c >= 97 and c <= 102)):
			return false
	return true


## 읽을 때마다(그리고 저장 전에) 거치는 보정. 입력은 바꾸지 않는다. Dictionary 가 아니면 새 memo.
static func normalize(raw: Variant, now: int) -> Dictionary:
	if not (raw is Dictionary):
		return new_memo()
	var src: Dictionary = raw
	var out := new_memo()
	out["v"] = SongModel.int_of(src.get("v", CURRENT_V), 1, 1000000, CURRENT_V)
	out["app"] = SongModel.clean_str(src.get("app", ""), SongModel.LEN_SMALL)
	var st: Variant = src.get("stats", null)
	if st is Dictionary:
		out["stats"] = {
			"sessions": SongModel.int_of((st as Dictionary).get("sessions", 0), 0, MAX_COUNT, 0),
			"last": SongModel.int_of((st as Dictionary).get("last", 0), 0, MAX_TIME, 0),
		}
	var rl: Variant = src.get("lines", null)
	if rl is Dictionary:
		var keys: Array = []
		for k in (rl as Dictionary).keys():
			if is_valid_key(k) and (rl as Dictionary)[k] is Dictionary:
				keys.append(k)
		keys.sort()
		var lines := {}
		for k in keys:
			lines[k] = _norm_entry((rl as Dictionary)[k], now)
		if lines.size() > MAX_LINES:
			## 가장 오래 본 것부터 버린다 (seen 이 같으면 키 순서)
			var order: Array = lines.keys()
			order.sort_custom(func(a: String, b: String) -> bool:
				var sa: int = int(lines[a]["seen"])
				var sb: int = int(lines[b]["seen"])
				if sa != sb:
					return sa > sb
				return a < b)
			var kept := {}
			for i in MAX_LINES:
				kept[order[i]] = lines[order[i]]
			lines = kept
		out["lines"] = lines
	return out


static func _norm_entry(e: Dictionary, now: int) -> Dictionary:
	var out := {
		"stage": SongModel.int_of(e.get("stage", 0), 0, MAX_STAGE, 0),
		"seen": SongModel.int_of(e.get("seen", 0), 0, MAX_TIME, 0),
		"tries": SongModel.int_of(e.get("tries", 0), 0, MAX_COUNT, 0),
		"passes": SongModel.int_of(e.get("passes", 0), 0, MAX_COUNT, 0),
	}
	var card: Dictionary = clean_card(e.get("card", null), now)
	if not card.is_empty():
		out["card"] = card
	return out


## FSRS 카드 보정. 복구할 수 없으면 {} (그 줄은 새 줄 취급): 사전이 아님, due/state/stability/difficulty 가 숫자가 아니거나
## NaN/inf, state 가 1~3 밖, 안정도·난이도 음수, 복습·재학습 카드인데 안정도·난이도가 0 이하. 그 밖의 숫자는 한도 안으로 맞춘다.
static func clean_card(raw: Variant, now: int) -> Dictionary:
	if not (raw is Dictionary):
		return {}
	var d: Dictionary = raw
	for k in ["due", "state", "stability", "difficulty"]:
		if not SongModel.is_finite_num(d.get(k, null)):
			return {}
	for k in ["step", "last_review", "reps", "lapses"]:
		if d.has(k) and not SongModel.is_finite_num(d[k]):
			return {}
	var state: int = SongModel.int_of(d["state"], -1000000, 1000000, 0)
	if state < 1 or state > 3:
		return {}
	var stab: float = float(d["stability"])
	var diff: float = float(d["difficulty"])
	if stab < 0.0 or diff < 0.0:
		return {}
	if state != FSRS.State.LEARNING and (stab <= 0.0 or diff <= 0.0):
		return {}
	var c := {
		"due": SongModel.int_of(d["due"], 0, MAX_TIME, 0),
		"state": state,
		"stability": minf(stab, MAX_STABILITY),
		"difficulty": minf(diff, MAX_DIFFICULTY),
		"step": SongModel.int_of(d.get("step", 0), 0, MAX_STEP, 0),
		"last_review": SongModel.int_of(d.get("last_review", 0), 0, MAX_TIME, 0),
		"reps": SongModel.int_of(d.get("reps", 0), 0, MAX_COUNT, 0),
		"lapses": SongModel.int_of(d.get("lapses", 0), 0, MAX_COUNT, 0),
	}
	FSRS.ensure_fields(c, now) ## 값이 이미 맞으므로 그대로다 (안전망)
	return c


# ---------------------------------------------------------------- line keys

static func _letters() -> RegEx:
	if _rx_letter == null:
		_rx_letter = RegEx.new()
		_rx_letter.compile("[\\p{L}\\p{N}]")
	return _rx_letter


## 줄 글자 -> 12자리 hex 키. 대소문자·구두점·공백 차이는 같은 키(TextSim 정규화). 글자가 없으면 "".
static func line_key(text: Variant, lang: String) -> String:
	if not (text is String):
		return ""
	var nt: String = TextSim.norm_text(text, "ja" if lang == "ja" else "en")
	if nt == "":
		return ""
	return nt.sha256_text().left(KEY_LEN)


## 외울 줄인가: 키가 있고, 글자(문자·숫자)가 하나 이상 있고, [Chorus] 같은 [ ... ] 표시가 아니다.
## `line` 은 곡의 줄 사전({text: ...}) 또는 글자 그대로.
static func is_memo_line(line: Variant, lang: String) -> bool:
	var text: String = ""
	if line is Dictionary:
		var t: Variant = (line as Dictionary).get("text", "")
		text = t if t is String else ""
	elif line is String:
		text = line
	var tt: String = text.strip_edges()
	if tt == "" or (tt.begins_with("[") and tt.ends_with("]")):
		return false
	if _letters().search(tt) == null:
		return false
	return line_key(tt, lang) != ""


## 곡의 외울 줄 키: 곡 순서, 같은 키는 처음 위치만. [{key, i}]
static func keys_of(song: Dictionary) -> Array:
	var out: Array = []
	var ls: Variant = song.get("lines", [])
	if not (ls is Array):
		return out
	var lang: String = str(song.get("lang", "en"))
	var seen := {}
	for i in (ls as Array).size():
		var ln: Variant = (ls as Array)[i]
		if not (ln is Dictionary) or not is_memo_line(ln, lang):
			continue
		var k: String = line_key((ln as Dictionary).get("text", ""), lang)
		if seen.has(k):
			continue
		seen[k] = true
		out.append({"key": k, "i": i})
	return out


# ---------------------------------------------------------------- summary / queue

static func _card_of(memo: Dictionary, key: String) -> Dictionary:
	var ls: Variant = memo.get("lines", {})
	if ls is Dictionary and (ls as Dictionary).get(key, null) is Dictionary:
		var c: Variant = ((ls as Dictionary)[key] as Dictionary).get("card", null)
		if c is Dictionary:
			return c
	return {}


## {total, memorized, learning, fresh, due, next_due}. total = 서로 다른 키 수, memorized = state 2, learning = state 1·3,
## fresh = 카드 없음, due = 카드가 있고 due <= now 인 줄 수, next_due = due > now 인 카드 중 가장 이른 due (없으면 0).
static func summary(song: Dictionary, memo: Dictionary, now: int) -> Dictionary:
	var m: Dictionary = normalize(memo, now)
	var res := {"total": 0, "memorized": 0, "learning": 0, "fresh": 0, "due": 0, "next_due": 0}
	for e in keys_of(song):
		res["total"] += 1
		var c: Dictionary = _card_of(m, e["key"])
		if c.is_empty():
			res["fresh"] += 1
			continue
		if int(c["state"]) == FSRS.State.REVIEW:
			res["memorized"] += 1
		else:
			res["learning"] += 1
		var due: int = int(c["due"])
		if due <= now:
			res["due"] += 1
		elif int(res["next_due"]) == 0 or due < int(res["next_due"]):
			res["next_due"] = due
	return res


## 오늘 할 줄: [{key, i, kind: "review"|"new"}]. 복습 줄(카드가 있고 due <= now)이 due 오래된 순으로 먼저(최대 review_cap),
## 이어서 새 줄(카드 없음)이 곡 순서로(최대 new_cap). 같은 키는 한 번만.
## opts: review_cap(20), new_cap(5), only_line(-1: 그 줄 하나만 — 연습용, 상한 없음), skip_new(0: 새 줄 앞에서 이만큼 건너뜀).
static func build_queue(song: Dictionary, memo: Dictionary, now: int, opts: Dictionary = {}) -> Array:
	var m: Dictionary = normalize(memo, now)
	var keys: Array = keys_of(song)
	var only: int = SongModel.int_of(opts.get("only_line", -1), -1, 1000000, -1)
	if only >= 0:
		var lang: String = str(song.get("lang", "en"))
		var ls: Variant = song.get("lines", [])
		if not (ls is Array) or only >= (ls as Array).size() or not ((ls as Array)[only] is Dictionary):
			return []
		var ln: Dictionary = (ls as Array)[only]
		if not is_memo_line(ln, lang):
			return []
		var k: String = line_key(ln.get("text", ""), lang)
		return [{"key": k, "i": only, "kind": "review" if not _card_of(m, k).is_empty() else "new"}]
	var review_cap: int = SongModel.int_of(opts.get("review_cap", REVIEW_CAP), 0, 100000, REVIEW_CAP)
	var new_cap: int = SongModel.int_of(opts.get("new_cap", NEW_CAP), 0, 100000, NEW_CAP)
	var skip_new: int = SongModel.int_of(opts.get("skip_new", 0), 0, 100000, 0)
	var rev: Array = []
	var fresh: Array = []
	for e in keys:
		var c: Dictionary = _card_of(m, e["key"])
		if c.is_empty():
			fresh.append(e)
		elif int(c["due"]) <= now:
			rev.append({"key": e["key"], "i": e["i"], "due": int(c["due"])})
	rev.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if a["due"] != b["due"]:
			return a["due"] < b["due"]
		return a["i"] < b["i"])
	var out: Array = []
	for r in rev:
		if out.size() >= review_cap:
			break
		out.append({"key": r["key"], "i": r["i"], "kind": "review"})
	var n_new: int = 0
	for idx in fresh.size():
		if idx < skip_new:
			continue
		if n_new >= new_cap:
			break
		out.append({"key": fresh[idx]["key"], "i": fresh[idx]["i"], "kind": "new"})
		n_new += 1
	return out


## 곡에 없는 키 중 seen 이 PRUNE_DAYS(30)일 넘게 지난 것을 지운다 (가사를 고친 뒤 호출). 곡 사전에 lines 배열이 없으면 아무것도 안 한다.
static func prune(memo: Dictionary, song: Dictionary, now: int) -> void:
	if not (song.get("lines", null) is Array):
		return
	var ls: Variant = memo.get("lines", null)
	if not (ls is Dictionary):
		return
	var live := {}
	for e in keys_of(song):
		live[e["key"]] = true
	var cutoff: int = now - PRUNE_DAYS * 86400
	for k in (ls as Dictionary).keys():
		if live.has(k):
			continue
		var ent: Variant = (ls as Dictionary)[k]
		var seen: int = SongModel.int_of((ent as Dictionary).get("seen", 0), 0, MAX_TIME, 0) if ent is Dictionary else 0
		if seen < cutoff:
			(ls as Dictionary).erase(k)
