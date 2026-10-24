class_name LocalPractice
extends RefCounted
## Phone version of GET /practice/ping, /practice/sentences, /practice/phonemes, /practice/phoneme
## (backend/practice.py, same rules: query parsers, eligibility limits, _pick ranking, dictation_ok, parse_exclude,
## drill sentences round-robin over the drill words). Design docs/phone_standalone_design.md §3.5(2), §5.5.
## Data (PackLoader, verified against manifest.json): practice_<lang>.json (sentences + `eligible` limits),
## phoneme_drills.json, examples_en.json (drill sentences).
##
## Known differences from the PC (A3a report):
##  - target_vocab(): the PC weights the words of the month/week curriculum with spaCy/WordNet lemmas. The phone
##    matches lower-case word tokens of the curriculum text (res://data/curriculum.json, bundled) against the pack
##    lemmas, with a short stop-word list. Random ranking is the same shape but the numbers differ.
##  - readings and pronunciations come from the pack (built with the PC functions), not computed on the phone.
##  - drill sentences come from examples_en.json (no Tatoeba DB) and skip the PC `blocked()` word list.
##  - RNG: Godot's RandomNumberGenerator, so seed=1 is reproducible on the phone but gives other numbers than Python.
##
## Handler contract (LocalApi): static handle / is_available / unavailable_reason.

const PRACTICE_VERSION := 1
const MAX_EXCLUDE_CHARS := 4000
const MAX_EXCLUDE_IDS := 500
const DICT_MIN_WORDS := 3
const DICT_MAX_WORDS := 10
const MIN_POOL := 80
const DRILLS_FILE := "phoneme_drills.json"
const EXAMPLES_FILE := "examples_en.json"
const CURRICULUM_PATH := "res://data/curriculum.json"
const LANG_MSG := "lang은 'en' 또는 'ja'여야 해요."
const MODE_MSG := "mode는 'shadow' 또는 'dictation'이어야 해요."
const DICT_JA_MSG := "받아쓰기는 영어만 지원해요."
const P_MSG := "소리(p)를 보내 주세요."
const NO_DRILL_MSG := "아직 연습 자료가 없는 소리예요."
const PUNCT_EDGE := ".,!?;:\"“”()"
const JA_PUNCT := "。、！？!?,.，．…・「」『』（）()\"'“”‘’〜~ー―-   \t\r\n"
const STOP_WORDS := ["a", "an", "the", "to", "of", "in", "on", "at", "is", "are", "am", "be", "it", "i", "you", "we",
	"he", "she", "they", "me", "my", "your", "do", "does", "did", "not", "no", "and", "or", "but", "if", "so", "for",
	"with", "that", "this", "what", "how", "let", "s", "t", "re", "ve", "ll", "d", "m"]

static var _target_cache: Dictionary = {}
static var _curriculum: Variant = null


# ---------------------------------------------------------------- handler contract

static func is_available() -> bool:
	return bool(PackLoader.load_json("practice_en.json")["ok"])


## Per request: Japanese sentences need practice_ja.json only (a damaged English pack must not stop them).
static func is_available_for(path: String, query: Dictionary, _body: Dictionary) -> bool:
	if path == "/practice/sentences" and str(query.get("lang", "en")) == "ja":
		return bool(PackLoader.load_json("practice_ja.json")["ok"])
	return is_available()


static func unavailable_reason_for(path: String, query: Dictionary, _body: Dictionary) -> Dictionary:
	if path == "/practice/sentences" and str(query.get("lang", "en")) == "ja":
		var r: Dictionary = PackLoader.load_json("practice_ja.json")
		if bool(r["ok"]):
			return {"err_code": "", "text_ko": ""}
		var code: String = str(r["err_code"])
		return {"err_code": code, "text_ko": Route.text_for(code)}
	return unavailable_reason()


## {err_code, text_ko} of the English practice pack problem; empty values when the pack is fine.
static func unavailable_reason() -> Dictionary:
	var r: Dictionary = PackLoader.load_json("practice_en.json")
	if bool(r["ok"]):
		return {"err_code": "", "text_ko": ""}
	var code: String = str(r["err_code"])
	return {"err_code": code, "text_ko": Route.text_for(code)}


static func handle(method: String, path: String, query: Dictionary, body: Dictionary) -> Dictionary:
	if method != "GET":
		return LocalApi.fail("not_on_phone")
	match path:
		"/practice/ping":
			return _ping()
		"/practice/sentences":
			return _sentences(query)
		"/practice/phonemes":
			return _phonemes()
		"/practice/phoneme":
			return _phoneme(query)
	return LocalApi.fail("not_on_phone")


# ---------------------------------------------------------------- endpoints

static func _ping() -> Dictionary:
	return LocalApi.ok({"ok": true, "practice": PRACTICE_VERSION,
		"missions": 1 if PackLoader.has_file("missions.json") else 0, "tatoeba": is_available()})


static func _sentences(q: Dictionary) -> Dictionary:
	var lang: String = str(q.get("lang", "en"))
	var mode: String = str(q.get("mode", ""))
	if lang != "en" and lang != "ja":
		return _bad(LANG_MSG)
	if mode != "shadow" and mode != "dictation":
		return _bad(MODE_MSG)
	if lang == "ja" and mode == "dictation":
		return _bad(DICT_JA_MSG)
	var month: int = _int_q(q.get("month", ""), 1, 12, 1)
	var stage: int = _int_q(q.get("stage", ""), 1, 4, int(ceil(float(month) / 3.0)))
	var week: int = _int_q(q.get("week", ""), 1, 4, 1)
	var n: int = _int_q(q.get("n", ""), 1, 20, 8)
	var seed_v: Variant = null
	var seed_s: String = str(q.get("seed", ""))
	if seed_s != "":
		seed_v = _parse_int(seed_s)
	var exclude: Dictionary = parse_exclude(str(q.get("exclude", "")))

	var r: Dictionary = PackLoader.load_json("practice_%s.json" % lang)
	if not bool(r["ok"]):
		return LocalApi.fail(str(r["err_code"]))
	var data: Variant = r["data"]
	if not _sentences_pack_ok(data):
		return LocalApi.fail("pack_corrupt")
	var sents: Array = _pick(data as Dictionary, lang, mode, stage, month, week, n, seed_v, exclude)
	return LocalApi.ok({"lang": lang, "mode": mode, "stage": stage, "sentences": sents,
		"attribution": _str_or((data as Dictionary).get("attribution"), "")})


static func _phonemes() -> Dictionary:
	var dr: Dictionary = _load_drills()
	if not bool(dr["ok"]):
		return LocalApi.fail(str(dr["err_code"]))
	var out: Array = []
	for d in dr["items"]:
		out.append({"p": d["p"], "label": d["label"], "hint_ko": d["hint_ko"]})
	return LocalApi.ok({"phonemes": out})


static func _phoneme(q: Dictionary) -> Dictionary:
	var p: String = str(q.get("p", "")).strip_edges()
	if p == "":
		return _bad(P_MSG)
	var dr: Dictionary = _load_drills()
	if not bool(dr["ok"]):
		return LocalApi.fail(str(dr["err_code"]))
	var d: Dictionary = {}
	for x in dr["items"]:
		if str(x["p"]) == p:
			d = x
			break
	if d.is_empty():
		return LocalApi.fail("not_found", NO_DRILL_MSG, 404)
	var count: int = _int_q(q.get("sentences", ""), 0, 5, 3)
	var sents: Array = _drill_sentences(d["words"], count)
	return LocalApi.ok({"p": d["p"], "label": d["label"], "hint_ko": d["hint_ko"], "words": d["words"],
		"pairs": d["pairs"], "phrases": d["phrases"], "sentences": sents, "attribution": _attribution()})


# ---------------------------------------------------------------- sentences (practice.py get_sentences / _pick)

## Same rule as practice.dictation_ok: 3..10 words, no digit, no capitalised word except the first and "I"-forms.
static func dictation_ok(text: String) -> bool:
	for k in range(text.length()):
		var code: int = text.unicode_at(k)
		if code >= 48 and code <= 57:
			return false
	var words: PackedStringArray = _split_ws(text)
	if words.size() < DICT_MIN_WORDS or words.size() > DICT_MAX_WORDS:
		return false
	for i in range(words.size()):
		var core: String = _strip_chars(words[i], PUNCT_EDGE)
		if core == "":
			return false
		if i == 0:
			continue
		var first: String = core.substr(0, 1)
		if first != first.to_lower() and core.replace("’", "'").get_slice("'", 0) != "I":
			return false
	return true


## Same rule as practice._ja_reading_ok: non-empty and hiragana only once punctuation is dropped.
static func ja_reading_ok(rd: String) -> bool:
	var core: String = ""
	for k in range(rd.length()):
		var ch: String = rd.substr(k, 1)
		if not JA_PUNCT.contains(ch):
			core += ch
	if core == "":
		return false
	for k in range(core.length()):
		var code: int = core.unicode_at(k)
		var hira: bool = (code >= 0x3041 and code <= 0x3096) or code == 0x309D or code == 0x309E
		if not hira:
			return false
	return true


## Same rule as practice.parse_exclude: "12,34,a,,%00" -> {12, 34}; cut at 4000 characters, at most 500 ids.
static func parse_exclude(raw: String) -> Dictionary:
	var out: Dictionary = {}
	for tok0 in raw.substr(0, MAX_EXCLUDE_CHARS).split(","):
		var tok: String = tok0.strip_edges()
		if tok.length() >= 1 and tok.length() <= 12 and _is_digits(tok):
			out[tok.to_int()] = true
			if out.size() >= MAX_EXCLUDE_IDS:
				break
	return out


static func _pick(data: Dictionary, lang: String, mode: String, stage: int, month: int, week: int, n: int,
		seed_v: Variant, exclude: Dictionary) -> Array:
	var cands: Array = _eligible(data, stage)
	var target: Dictionary = _target_vocab(lang, month, week)
	var rng := RandomNumberGenerator.new()
	if seed_v == null:
		rng.randomize()
	else:
		rng.seed = int(seed_v)
	var scored: Array = []
	for it in cands:
		var id: int = int(it["id"])
		if exclude.has(id):
			continue
		if mode == "dictation" and not dictation_ok(str(it["text"])):
			continue
		var s: float = 0.0
		var lemmas: Variant = it.get("lemmas", [])
		if lemmas is Array:
			for l in lemmas:
				s += float(target.get(str(l), 0.0))
		var score: float = minf(s, 8.0) * rng.randf_range(0.5, 1.5) + rng.randf() * 2.5
		scored.append([score, id, it])
	scored.sort_custom(_by_score)

	var out: Array = []
	var seen: Dictionary = {}
	var tries: int = 0
	for row in scored:
		if out.size() >= n:
			break
		var it: Dictionary = row[2]
		var text: String = str(it["text"])
		if seen.has(text):
			continue
		var reading: String = ""
		var pron: String = ""
		if lang == "ja":
			tries += 1
			if tries > n * 8 + 40:
				break
			reading = _str_or(it.get("reading"), "")
			if not ja_reading_ok(reading):
				continue
			pron = _str_or(it.get("pron"), "")
		seen[text] = true
		var sid: int = int(row[1])
		out.append({"id": sid, "text": text, "ko": _str_or(it.get("ko"), ""), "reading": reading, "pron": pron,
			"words": int(it.get("words", 0)), "url": _url(sid)})
	return out


static func _by_score(a: Array, b: Array) -> bool:
	if a[0] != b[0]:
		return a[0] > b[0]
	return int(a[1]) < int(b[1])


## practice._eligible: the first (stage, relaxed stage, any) limit that leaves at least MIN_POOL sentences.
static func _eligible(data: Dictionary, stage: int) -> Array:
	var el: Dictionary = data["eligible"]
	var lens: Dictionary = el["len"]
	var minz: Dictionary = el["min_zipf"]
	var items: Array = data["sentences"]
	var st: String = str(stage)
	var prev: String = str(maxi(stage - 1, 1))
	var passes: Array = [
		[float(minz[st]), lens[st]],
		[float(minz[prev]) - 0.5, lens[st]],
		[0.0, [lens["1"][0], lens["4"][1]]],
	]
	var c: Array = []
	for p in passes:
		var lo_z: float = p[0]
		var lo: int = int(p[1][0])
		var hi: int = int(p[1][1])
		c = []
		for it in items:
			var nn: int = int(it.get("words", 0))
			if nn >= lo and nn <= hi and float(it.get("dmin", 0.0)) >= lo_z:
				c.append(it)
		if c.size() >= MIN_POOL:
			return c
	return c


static func _sentences_pack_ok(data: Variant) -> bool:
	if not (data is Dictionary):
		return false
	var d: Dictionary = data
	var el: Variant = d.get("eligible")
	if not (el is Dictionary) or not ((el as Dictionary).get("len") is Dictionary) or not ((el as Dictionary).get("min_zipf") is Dictionary):
		return false
	for k in ["1", "2", "3", "4"]:
		if not ((el as Dictionary)["len"] as Dictionary).has(k) or not ((el as Dictionary)["min_zipf"] as Dictionary).has(k):
			return false
	var items: Variant = d.get("sentences")
	if not (items is Array):
		return false
	for it in items:
		if not (it is Dictionary) or not ((it as Dictionary).get("text") is String) or not _is_num((it as Dictionary).get("id")):
			return false
	return true


## Approximation of practice.lesson_rules.target_vocab (see the header). Cached per (lang, month, week).
static func _target_vocab(lang: String, month: int, week: int) -> Dictionary:
	var key: String = "%s-%d-%d" % [lang, month, week]
	if _target_cache.has(key):
		return _target_cache[key]
	var out: Dictionary = {}
	var cur: Dictionary = _curriculum_data()
	var lang_cur: Variant = cur.get(lang)
	var months: Array = (lang_cur as Dictionary).get("months", []) if lang_cur is Dictionary else []
	if not months.is_empty():
		var m: Dictionary = months[0]
		for x in months:
			if x is Dictionary and int(x.get("n", -1)) == month:
				m = x
				break
		var weeks: Array = m.get("weeks", []) if m.get("weeks") is Array else []
		if not weeks.is_empty():
			var wk: Dictionary = weeks[0]
			if week - 1 >= 0 and week - 1 < weeks.size() and weeks[week - 1] is Dictionary:
				wk = weeks[week - 1]
			for c in (m.get("content", []) if m.get("content") is Array else []):
				if c is Dictionary:
					_add_tokens(out, _str_or(c.get("v"), ""), 1.0, lang)
			_add_tokens(out, _str_or(m.get("title"), ""), 1.0, lang)
			_add_tokens(out, _str_or(wk.get("topic"), "") + " " + _str_or(wk.get("act"), ""), 3.0, lang)
	_target_cache[key] = out
	return out


static func _add_tokens(out: Dictionary, text: String, w: float, lang: String) -> void:
	if lang == "en":
		var rx := RegEx.create_from_string("[A-Za-z]+")
		for m in rx.search_all(text):
			var f: String = m.get_string().to_lower()
			if f.length() < 2:
				continue
			var ww: float = w * (0.3 if f in STOP_WORDS else 1.0)
			out[f] = maxf(float(out.get(f, 0.0)), ww)
	else:
		var jx := RegEx.create_from_string("[\\x{3040}-\\x{30FF}\\x{4E00}-\\x{9FFF}]+")
		for m in jx.search_all(text):
			var f: String = m.get_string()
			if f.length() < 2:
				continue
			out[f] = maxf(float(out.get(f, 0.0)), w)


static func _curriculum_data() -> Dictionary:
	if _curriculum == null:
		var parsed: Variant = null
		if FileAccess.file_exists(CURRICULUM_PATH):
			parsed = JSON.parse_string(FileAccess.get_file_as_string(CURRICULUM_PATH))
		if parsed is Dictionary:
			_curriculum = parsed
		else:
			push_warning("LocalPractice: curriculum unreadable; ranking by chance only")
			_curriculum = {}
	return _curriculum


# ---------------------------------------------------------------- drills (practice.py load_drills / get_phoneme)

static func _load_drills() -> Dictionary:
	var r: Dictionary = PackLoader.load_json(DRILLS_FILE)
	if not bool(r["ok"]):
		return {"ok": false, "items": [], "err_code": str(r["err_code"])}
	var data: Variant = r["data"]
	if not (data is Dictionary) or not ((data as Dictionary).get("phonemes") is Array):
		return {"ok": false, "items": [], "err_code": "pack_corrupt"}
	var items: Array = []
	var seen: Dictionary = {}
	for d in (data as Dictionary)["phonemes"]:
		var c: Variant = _clean_drill(d)
		if c != null and not seen.has(c["p"]):
			seen[c["p"]] = true
			items.append(c)
	return {"ok": true, "items": items, "err_code": ""}


static func _clean_drill(d: Variant) -> Variant:
	if not (d is Dictionary):
		return null
	var p: String = _str_or((d as Dictionary).get("p"), "").strip_edges()
	if p == "":
		return null
	var pairs: Array = []
	for x in _arr((d as Dictionary).get("pairs")):
		if x is Dictionary and _str_or(x.get("a"), "").strip_edges() != "" and _str_or(x.get("b"), "").strip_edges() != "":
			pairs.append({"a": _str_or(x.get("a"), "").strip_edges(), "b": _str_or(x.get("b"), "").strip_edges(),
				"ko": _str_or(x.get("ko"), "")})
	var phrases: Array = []
	for x in _arr((d as Dictionary).get("phrases")):
		if x is Dictionary and _str_or(x.get("text"), "").strip_edges() != "":
			phrases.append({"text": _str_or(x.get("text"), "").strip_edges(), "ko": _str_or(x.get("ko"), "")})
	var words: Array = []
	for w in _arr((d as Dictionary).get("words")):
		if w is String and (w as String).strip_edges() != "":
			words.append((w as String).strip_edges())
	var label: String = _str_or((d as Dictionary).get("label"), "")
	return {"p": p, "label": label if label != "" else p, "hint_ko": _str_or((d as Dictionary).get("hint_ko"), ""),
		"words": words, "pairs": pairs, "phrases": phrases}


## practice._drill_sentences: round-robin over the drill words (at most 8 words looked up); [] when the examples
## pack is not usable (the drills still work).
static func _drill_sentences(words: Array, count: int) -> Array:
	if count <= 0:
		return []
	var ex: Dictionary = PackLoader.load_json(EXAMPLES_FILE)
	if not bool(ex["ok"]) or not (ex["data"] is Dictionary):
		return []
	var sent: Dictionary = _dict((ex["data"] as Dictionary).get("sent"))
	var idx: Dictionary = _dict((ex["data"] as Dictionary).get("idx"))
	var order: Array = words.duplicate()
	order.shuffle()
	var per_word: Array = []
	var total: int = 0
	for w in order.slice(0, 8):
		var rows: Array = []
		for raw_id in _arr(idx.get(str(w).to_lower())):
			if not _is_num(raw_id):
				continue
			var eid: int = int(raw_id)
			var row: Variant = sent.get(str(eid))
			if row is Dictionary and _example_ok(row as Dictionary):
				rows.append({"id": eid, "text": _str_or((row as Dictionary).get("t"), ""),
					"ko": _str_or((row as Dictionary).get("ko"), ""), "url": _url(eid)})
				if rows.size() >= 6:
					break
		per_word.append(rows)
		total += rows.size()
		if total >= count * 2:
			break
	var out: Array = []
	var ids: Dictionary = {}
	var texts: Dictionary = {}
	var i: int = 0
	while out.size() < count and _any_left(per_word, i):
		for g in per_word:
			if i < (g as Array).size() and out.size() < count and not ids.has(g[i]["id"]) and not texts.has(g[i]["text"]):
				ids[g[i]["id"]] = true
				texts[g[i]["text"]] = true
				out.append(g[i])
		i += 1
	return out


## practice._example_ok: 3..10 words, plain English letters and punctuation, a Korean translation.
static func _example_ok(row: Dictionary) -> bool:
	var text: String = _str_or(row.get("t"), "")
	if _split_ws(text).size() < DICT_MIN_WORDS or _split_ws(text).size() > DICT_MAX_WORDS:
		return false
	var rx := RegEx.create_from_string("^[A-Za-z' ,.!?\\-]+$")
	return rx.search(text) != null and _str_or(row.get("ko"), "").strip_edges() != ""


static func _attribution() -> String:
	for f in ["practice_en.json", EXAMPLES_FILE]:
		var r: Dictionary = PackLoader.load_json(f)
		if bool(r["ok"]) and r["data"] is Dictionary:
			var a: String = _str_or((r["data"] as Dictionary).get("attribution"), "")
			if a != "":
				return a
	return ""


# ---------------------------------------------------------------- small helpers

static func _bad(msg: String) -> Dictionary:
	return LocalApi.fail("bad_request", msg, 400)


static func _url(id: int) -> String:
	return "https://tatoeba.org/sentences/show/%d" % id


## practice._int: optional sign, 1..18 digits; anything else gives null.
static func _parse_int(v: Variant) -> Variant:
	var s: String = str(v).strip_edges()
	var neg: bool = s.begins_with("-")
	var body: String = s.substr(1) if (neg or s.begins_with("+")) else s
	if body.length() < 1 or body.length() > 18 or not _is_digits(body):
		return null
	var val: int = body.to_int()
	return -val if neg else val


static func _int_q(v: Variant, lo: int, hi: int, dflt: int) -> int:
	var p: Variant = _parse_int(v)
	if p == null:
		return dflt
	return clampi(int(p), lo, hi)


static func _is_digits(s: String) -> bool:
	for k in range(s.length()):
		var code: int = s.unicode_at(k)
		if code < 48 or code > 57:
			return false
	return s.length() > 0


static func _is_num(v: Variant) -> bool:
	return v is int or v is float


static func _split_ws(text: String) -> PackedStringArray:
	return text.replace("\t", " ").replace("\n", " ").replace("\r", " ").split(" ", false)


static func _strip_chars(s: String, chars: String) -> String:
	var a: int = 0
	var b: int = s.length()
	while a < b and chars.contains(s.substr(a, 1)):
		a += 1
	while b > a and chars.contains(s.substr(b - 1, 1)):
		b -= 1
	return s.substr(a, b - a)


static func _str_or(v: Variant, dflt: String) -> String:
	if v is String:
		return v
	return dflt


static func _arr(v: Variant) -> Array:
	if v is Array:
		return v
	return []


static func _dict(v: Variant) -> Dictionary:
	if v is Dictionary:
		return v
	return {}


static func _any_left(per_word: Array, i: int) -> bool:
	for g in per_word:
		if (g as Array).size() > i:
			return true
	return false
