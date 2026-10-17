class_name PhonemeStats
extends RefCounted
## 음소별 틀림 집계 순수 함수.
##
## stats(한 언어분) = { "<음소 p>": {"h": "0110010", "heard": {"s": 5, "t": 1}} }
##   h     = 최근 HISTORY 번의 결과 문자열, "1" = 틀림, "0" = 맞음 (오래된 것이 앞)
##   heard = 틀렸을 때 "대신 들린 소리"별 횟수
## observe() 는 stats 를 직접 바꾼다 (집계한 음소 수를 돌려준다). 나머지는 읽기만 한다.

const HISTORY := 30
const MAX_PHONEMES := 80
const MAX_HEARD := 8
const MAX_P_LEN := 12


static func blank() -> Dictionary:
	return {}


## Folds one /score response into `stats`: every units[].ph[] entry with a non-empty `p` and a boolean-like `ok`.
## Returns the number of phoneme results recorded (0 for anything that is not a normal response).
static func observe(stats: Dictionary, res: Dictionary) -> int:
	var units: Variant = res.get("units", null)
	if not (units is Array):
		return 0
	var n := 0
	for u in units:
		if not (u is Dictionary):
			continue
		var phs: Variant = (u as Dictionary).get("ph", null)
		if not (phs is Array):
			continue
		for ph in phs:
			if not (ph is Dictionary):
				continue
			var d: Dictionary = ph
			var p_v: Variant = d.get("p", null)
			if not (p_v is String):
				continue
			var p: String = (p_v as String).strip_edges()
			if p == "" or p.length() > MAX_P_LEN:
				continue
			var ok_v: Variant = d.get("ok", null)
			var good: bool
			if ok_v is bool:
				good = ok_v
			elif ok_v is int or ok_v is float:
				good = float(ok_v) != 0.0
			else:
				continue
			var entry: Dictionary = _entry(stats, p)
			var h: String = str(entry["h"]) + ("0" if good else "1")
			if h.length() > HISTORY:
				h = h.substr(h.length() - HISTORY)
			entry["h"] = h
			if not good:
				var hv: Variant = d.get("heard", null)
				if hv is String:
					var hs: String = (hv as String).strip_edges()
					if hs != "" and hs.length() <= MAX_P_LEN and hs != p:
						var heard: Dictionary = entry["heard"]
						heard[hs] = int(heard.get(hs, 0)) + 1
						_trim_heard(heard)
			n += 1
	if n > 0:
		prune(stats, MAX_PHONEMES)
	return n


## Weakest sounds first: wrong-rate descending, then more samples first, then by symbol.
## Only sounds with at least `min_n` results and at least one miss are listed.
## Entry: {p, n, bad, rate, heard:{}}
static func weakest(stats: Dictionary, limit: int, min_n: int) -> Array:
	var rows: Array = []
	if limit <= 0:
		return rows
	for p in stats.keys():
		var e: Variant = stats[p]
		if not (e is Dictionary):
			continue
		var h: String = str((e as Dictionary).get("h", ""))
		var n: int = h.length()
		if n < maxi(min_n, 1):
			continue
		var bad: int = h.count("1")
		if bad <= 0:
			continue
		var heard: Variant = (e as Dictionary).get("heard", {})
		rows.append({"p": str(p), "n": n, "bad": bad, "rate": float(bad) / float(n), "heard": (heard as Dictionary).duplicate() if heard is Dictionary else {}})
	rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if a["rate"] != b["rate"]:
			return a["rate"] > b["rate"]
		if a["n"] != b["n"]:
			return a["n"] > b["n"]
		return str(a["p"]) < str(b["p"]))
	if rows.size() > limit:
		rows = rows.slice(0, limit)
	return rows


## Drops the sounds with the fewest samples until at most `max_count` are left.
static func prune(stats: Dictionary, max_count: int) -> void:
	if stats.size() <= max_count:
		return
	var keys: Array = stats.keys()
	keys.sort_custom(func(a: Variant, b: Variant) -> bool:
		var na: int = str((stats[a] as Dictionary).get("h", "")).length()
		var nb: int = str((stats[b] as Dictionary).get("h", "")).length()
		if na != nb:
			return na > nb
		return str(a) < str(b))
	for i in range(max_count, keys.size()):
		stats.erase(keys[i])


static func _entry(stats: Dictionary, p: String) -> Dictionary:
	var e: Variant = stats.get(p, null)
	if not (e is Dictionary):
		e = {"h": "", "heard": {}}
		stats[p] = e
	var d: Dictionary = e
	if not (d.get("h", null) is String):
		d["h"] = ""
	if not (d.get("heard", null) is Dictionary):
		d["heard"] = {}
	return d


static func _trim_heard(heard: Dictionary) -> void:
	if heard.size() <= MAX_HEARD:
		return
	var keys: Array = heard.keys()
	keys.sort_custom(func(a: Variant, b: Variant) -> bool:
		if heard[a] != heard[b]:
			return heard[a] > heard[b]
		return str(a) < str(b))
	for i in range(MAX_HEARD, keys.size()):
		heard.erase(keys[i])
