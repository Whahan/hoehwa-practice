class_name LocalReading
extends RefCounted
## Phone version of the reading endpoints (API.md "읽기 모드 (/reading/*)"): POST /reading/analyze, POST /reading/gloss,
## GET /examples. Same result shapes as backend/reading.py (analyze / gloss / examples).
## Data (PackLoader, verified against manifest.json): reading_en.json {forms, zipf x10}, ipa_en.json, gloss_<lang>.json
## (made by another worker; may be absent), examples_<lang>.json.
## Design: docs/phone_standalone_design.md §3.5(4)(5), §4.3, §5.1, §5.2, §11 F14.
##
## Handler contract (LocalApi): static handle / is_available / unavailable_reason.
##
## analyze (English only): there is no spaCy on the phone, so
##   - words come from a regex tokenizer that cuts clitics the way spaCy does (don't -> do + n't, I'm -> I + 'm);
##   - the lemma is `forms[word]` (built with spaCy's rule tables and Tatoeba forms), else the word itself when it is in
##     the frequency table, else the best suffix-stripped candidate that is in the table (running -> run);
##   - zipf = max(zipf(lemma), zipf(word)) from the integer table (x10), level from the same thresholds as the PC;
##   - proper nouns (a capital letter inside a sentence, an unknown capitalised sentence opener, numbers, URLs, e-mail
##     addresses) are not words, like the PC;
##   - sentences are cut after . ! ? (not after Mr. / Dr. / initials, not before a lower-case letter) and at line breaks.
##   Result: tokens that join back to the text exactly, sentences, words (same assembly code as reading.analyze).
## lang "ja": a Japanese morphological analyser does not exist on the phone (design §3.5(4), choice 1) -> err_code
##   "ja_reading_pc" (the app tells the learner to connect the PC). No approximation is made.
## gloss: pre-made dictionary of representative meanings. A word that is not in it (or a missing / corrupt gloss file)
##   leaves that word out of `glosses` and sets degraded ["gloss_partial"]; the call itself does not fail.
## examples: examples_<lang>.json (sentences with a Korean translation only, ~1.1 万); degraded ["examples_subset"]
##   when fewer than `limit` sentences were found (the PC searches 790k sentences).

const MAX_CHARS := 20000       ## same as reading.MAX_CHARS
const MAX_GLOSS := 30          ## same as reading.MAX_GLOSS
const LANG_MSG := "lang은 'en' 또는 'ja'여야 해요."
const EMPTY_TEXT_MSG := "분석할 글을 붙여 넣어 주세요."
const EMPTY_GLOSS_MSG := "뜻을 찾을 단어를 보내 주세요."
const EMPTY_Q_MSG := "찾을 단어(q)를 보내 주세요."
const LONG_Q_MSG := "찾을 단어가 너무 길어요."
const ATTRIBUTION := "예문 출처: Tatoeba (tatoeba.org) · CC BY 2.0 FR"

## One raw token per match, the regex covers every character (the last alternative is "any character").
const TOKEN_PATTERN := r"(?:https?://|www\.)\S+|[A-Za-z0-9._+\-]+@[A-Za-z0-9\-]+(?:\.[A-Za-z0-9\-]+)+|[\p{L}\p{N}]+(?:['’]\p{L}+)*|\s+|[\s\S]"

const TERMINAL := ".!?…"
const OPENERS := "\"'“‘([{«¿¡"
const CLOSERS := "\"'”’)]}»"
const URL_TAIL := ".,;:!?)]}'\"”’"
const ABBREV := ["mr", "mrs", "ms", "dr", "prof", "sr", "jr", "st", "vs", "mt", "inc", "ltd", "co", "etc", "approx", "dept", "gen", "col", "lt", "capt", "sgt", "rev", "hon"]
## Words after which 's is "is"/"has" (a word) and not a possessive (not a word, like spaCy's POS tag).
const S_HOSTS := ["it", "he", "she", "that", "there", "here", "what", "who", "where", "how", "when", "why", "everyone",
	"everybody", "someone", "somebody", "anyone", "anybody", "nobody", "something", "nothing", "everything", "anything",
	"this", "let"]
const CLITIC_LEMMA := {"'m": "be", "'re": "be", "'ve": "have", "'ll": "will", "'d": "would", "n't": "not"}

## Cache of the table references (compared by identity with the PackLoader result, so PackLoader.reset() rebuilds).
static var _src: Variant = null
static var _forms: Dictionary = {}
static var _zipf: Dictionary = {}
static var _token_rx: RegEx = null


# ---------------------------------------------------------------- handler contract

static func is_available() -> bool:
	return _tables_err() == ""


## {err_code, text_ko} of the pack problem; empty values when the pack is fine.
static func unavailable_reason() -> Dictionary:
	var code: String = _tables_err()
	if code == "":
		return {"err_code": "", "text_ko": ""}
	return {"err_code": code, "text_ko": Route.text_for(code)}


## `path` has no query. Only POST /reading/analyze, POST /reading/gloss and GET /examples are served here.
static func handle(method: String, path: String, query: Dictionary, body: Dictionary) -> Dictionary:
	if method == "POST" and path == "/reading/analyze":
		return _analyze_req(body)
	if method == "POST" and path == "/reading/gloss":
		return _gloss_req(body)
	if method == "GET" and path == "/examples":
		return _examples_req(query)
	return LocalApi.fail("not_on_phone")


static func reset() -> void:
	_src = null
	_forms = {}
	_zipf = {}


static func _bad_request(msg: String) -> Dictionary:
	return LocalApi.fail("bad_request", msg, 400)


# ---------------------------------------------------------------- tables

## "" when reading_en.json is loaded into the static caches, else the PackLoader err_code.
static func _tables_err() -> String:
	var r: Dictionary = PackLoader.load_json("reading_en.json")
	if not bool(r.get("ok", false)):
		return str(r.get("err_code", "pack_missing"))
	var data: Variant = r["data"]
	if not (data is Dictionary) or not ((data as Dictionary).get("forms", null) is Dictionary) \
			or not ((data as Dictionary).get("zipf", null) is Dictionary):
		return "pack_corrupt"
	if not is_same(_src, data):
		_src = data
		_forms = (data as Dictionary)["forms"]
		_zipf = (data as Dictionary)["zipf"]
	return ""


static func zipf_of(word: String) -> float:
	return float(_zipf.get(_norm_key(word), 0)) / 10.0


static func level_of(z: float) -> String:
	if z >= 4.5:
		return "easy"
	if z >= 3.5:
		return "mid"
	return "hard"


static func _norm_key(w: String) -> String:
	return w.replace("’", "'").to_lower()


## Dictionary form of an English word (see header). Needs the tables to be loaded (`_tables_err() == ""`).
static func lemma_of(word: String) -> String:
	var lower: String = _norm_key(word)
	if _forms.has(lower):
		return str(_forms[lower])
	if _zipf.has(lower):
		return lower
	var best: String = ""
	var best_z: int = 0
	for c in _suffix_candidates(lower):
		var z: int = int(_zipf.get(c, 0))
		if z > best_z:
			best_z = z
			best = c
	return best if best != "" else lower


static func _suffix_candidates(w: String) -> Array:
	var out: Array = []
	var n: int = w.length()
	if n < 4:
		return out
	if w.ends_with("ies") and n > 4:
		out.append(w.substr(0, n - 3) + "y")
	if w.ends_with("ied") and n > 4:
		out.append(w.substr(0, n - 3) + "y")
	if w.ends_with("ing") and n > 5:
		var s: String = w.substr(0, n - 3)
		out.append_array([s, s + "e"])
		if _doubled(s):
			out.append(s.substr(0, s.length() - 1))
	if w.ends_with("ed") and n > 4:
		var s2: String = w.substr(0, n - 2)
		out.append_array([s2, w.substr(0, n - 1)])
		if _doubled(s2):
			out.append(s2.substr(0, s2.length() - 1))
	if w.ends_with("es") and n > 4:
		out.append_array([w.substr(0, n - 2), w.substr(0, n - 1)])
	if w.ends_with("s") and not w.ends_with("ss") and n > 3:
		out.append(w.substr(0, n - 1))
	if w.ends_with("ily") and n > 5:
		out.append(w.substr(0, n - 3) + "y")
	if w.ends_with("ly") and n > 4:
		out.append(w.substr(0, n - 2))
	for suf in ["ier", "iest"]:
		if w.ends_with(suf) and n > suf.length() + 2:
			out.append(w.substr(0, n - suf.length()) + "y")
	for suf2 in ["er", "est"]:
		if w.ends_with(suf2) and n > suf2.length() + 2:
			var s3: String = w.substr(0, n - suf2.length())
			out.append_array([s3, s3 + "e"])
			if _doubled(s3):
				out.append(s3.substr(0, s3.length() - 1))
	return out


static func _doubled(s: String) -> bool:
	var k: int = s.length()
	return k >= 3 and s[k - 1] == s[k - 2] and not (s[k - 1] in "aeiouls")


# ---------------------------------------------------------------- analyze

static func _analyze_req(body: Dictionary) -> Dictionary:
	var lang: String = str(body.get("lang", ""))
	if lang != "en" and lang != "ja":
		return _bad_request(LANG_MSG)
	if lang == "ja":
		return LocalApi.fail("ja_reading_pc")
	var raw: Variant = body.get("text", "")
	var text: String = raw if raw is String else ""
	if text.strip_edges() == "":
		return _bad_request(EMPTY_TEXT_MSG)
	if text.length() > MAX_CHARS:
		return _bad_request(too_long_msg(text.length()))
	var code: String = _tables_err()
	if code != "":
		return LocalApi.fail(code)
	return LocalApi.ok(analyze_en(text))


## Same wording as reading.analyze (400).
static func too_long_msg(n: int) -> String:
	return "글이 너무 길어요. %d자까지 한 번에 읽을 수 있어요(지금 %d자)." % [MAX_CHARS, n]


## {tokens, sentences, words} of an English text (the tables must be loaded). Assembly = reading.analyze.
static func analyze_en(text: String) -> Dictionary:
	var tokens: Array = []
	var cur: int = -1
	for r in _stream(text):
		var t: String = r[0]
		if t == "":
			continue
		var has_content: bool = t.strip_edges() != ""
		if has_content and (bool(r[4]) or cur < 0):
			cur += 1
		var s: int = maxi(cur, 0)
		if bool(r[1]):
			tokens.append({"t": t, "w": true, "lemma": r[2], "zipf": r[3], "level": level_of(float(r[3])), "s": s})
		elif tokens.size() > 0 and not bool(tokens[tokens.size() - 1]["w"]) and int(tokens[tokens.size() - 1]["s"]) == s:
			tokens[tokens.size() - 1]["t"] = str(tokens[tokens.size() - 1]["t"]) + t
		else:
			tokens.append({"t": t, "w": false, "s": s})
	var sents: Dictionary = {}
	var words: Dictionary = {}
	for tk in tokens:
		var si: int = int(tk["s"])
		if not sents.has(si):
			sents[si] = ""
		sents[si] = str(sents[si]) + str(tk["t"])
		if bool(tk["w"]):
			var lem: String = str(tk["lemma"])
			if not words.has(lem):
				words[lem] = {"lemma": lem, "count": 1, "zipf": tk["zipf"]}
			else:
				var w: Dictionary = words[lem]
				w["count"] = int(w["count"]) + 1
				w["zipf"] = maxf(float(w["zipf"]), float(tk["zipf"]))
	var word_list: Array = []
	for lem2 in words.keys():
		var w2: Dictionary = words[lem2]
		w2["level"] = level_of(float(w2["zipf"]))
		word_list.append(w2)
	var keys: Array = sents.keys()
	keys.sort()
	var sentences: Array = []
	for k in keys:
		sentences.append({"i": int(k), "text": str(sents[k]).strip_edges()})
	return {"tokens": tokens, "sentences": sentences, "words": word_list}


static func _rx() -> RegEx:
	if _token_rx == null:
		_token_rx = RegEx.new()
		_token_rx.compile(TOKEN_PATTERN)
	return _token_rx


## Raw tokens covering `text` exactly: [text, is_word, lemma, zipf, break_before].
static func _stream(text: String) -> Array:
	var out: Array = []
	var rx: RegEx = _rx()
	var n: int = text.length()
	var pos: int = 0
	var cand: bool = false          # a sentence end was seen and no other content since
	var cand_space: bool = false    # whitespace followed that sentence end
	var nl_gap: bool = false        # a line break since the last content token
	var at_start: bool = true       # the next word opens a sentence (opening quotes keep this)
	var started: bool = false       # a content token was seen
	var prev_word: String = ""      # lower-case previous word piece ("" after anything else)
	var prev_raw: String = ""       # text of the previous raw token when it was a plain word, else ""
	while pos < n:
		var m: RegExMatch = rx.search(text, pos)
		if m == null or m.get_start() != pos:
			# cannot happen (the last alternative matches any character); keep the round trip exact anyway
			out.append([text.substr(pos, 1), false, "", 0.0, false])
			pos += 1
			continue
		var s: String = m.get_string()
		var c0: String = s.substr(0, 1)
		if s.begins_with("http") or s.begins_with("www"):
			var cut: int = s.length()
			while cut > 1 and URL_TAIL.contains(s[cut - 1]):
				cut -= 1
			s = s.substr(0, cut)
		pos += s.length()
		if s.strip_edges() == "":
			out.append([s, false, "", 0.0, false])
			if s.contains("\n"):
				nl_gap = true
			if cand:
				cand_space = true
			prev_word = ""
			prev_raw = ""
			continue
		# a content token: does it open a new sentence?
		var is_link: bool = s.contains("@") or s.begins_with("http") or s.begins_with("www")
		var brk: bool = nl_gap
		if cand and cand_space and not _is_lower_start(s):
			brk = true
		if not started:
			brk = false          # the first sentence is opened by `cur < 0` in the assembly
			at_start = true
		started = true
		if brk:
			at_start = true
		if is_link or _is_alnum(c0):
			var pieces: Array = [s] if is_link else _split_clitics(s)
			for k in range(pieces.size()):
				var p: String = pieces[k]
				var info: Array = [false, "", 0.0] if is_link else _classify(p, at_start, prev_word)
				out.append([p, bool(info[0]), info[1], info[2], brk and k == 0])
				prev_word = _norm_key(p) if bool(info[0]) else ""
			at_start = false
			cand = false
			cand_space = false
			nl_gap = false
			prev_raw = s if (pieces.size() == 1 and not is_link) else ""
			if is_link:
				prev_word = ""
			continue
		# a single punctuation / symbol character
		out.append([s, false, "", 0.0, brk])
		nl_gap = false
		if TERMINAL.contains(s):
			if s == "." and _is_abbrev(prev_raw):
				cand = false
			else:
				cand = true
				cand_space = false
			at_start = false
		elif CLOSERS.contains(s) and cand and not cand_space:
			pass                 # `."` `?)` keep the sentence end alive
		else:
			cand = false
			cand_space = false
			if not OPENERS.contains(s):
				at_start = false
		prev_word = ""
		prev_raw = ""
	return out


static func _is_lower_start(s: String) -> bool:
	var ch: String = s.substr(0, 1)
	return ch == ch.to_lower() and ch != ch.to_upper()


static func _is_alnum(ch: String) -> bool:
	if ch == "":
		return false
	var code: int = ch.unicode_at(0)
	if code >= 48 and code <= 57:
		return true
	if code < 128:
		return (code >= 65 and code <= 90) or (code >= 97 and code <= 122)
	return ch.to_lower() != ch.to_upper() or code > 0x2FF   # letters of other scripts (digits of other scripts do not matter)


static func _is_abbrev(prev: String) -> bool:
	if prev == "":
		return false
	if prev.length() == 1 and prev != "I" and prev != "a" and prev != "A":
		return true
	return ABBREV.has(prev.to_lower())


## "don't" -> ["do", "n't"]; "I'm" -> ["I", "'m"]; "o'clock" stays one piece.
static func _split_clitics(s: String) -> Array:
	var i: int = s.find("'")
	if i < 0:
		i = s.find("’")
	if i <= 0:
		return [s]
	var lower: String = _norm_key(s)
	if lower.length() > 3 and lower.ends_with("n't"):
		return [s.substr(0, s.length() - 3), s.substr(s.length() - 3)]
	var tail: String = lower.substr(i)
	if CLITIC_LEMMA.has(tail) or tail == "'s":
		return [s.substr(0, i), s.substr(i)]
	return [s]


## [is_word, lemma, zipf] of one piece.
static func _classify(p: String, at_start: bool, prev_word: String) -> Array:
	var key: String = _norm_key(p)
	if key == "n't" or (key.begins_with("'") and key != "'"):
		var lem: String = ""
		if key == "'s":
			if not S_HOSTS.has(prev_word):
				return [false, "", 0.0]
			lem = "us" if prev_word == "let" else "be"
		else:
			lem = str(CLITIC_LEMMA.get(key, key.lstrip("'")))
		return [true, lem, maxf(zipf_of(lem), zipf_of(key))]
	var has_alpha: bool = false
	var has_digit: bool = false
	for i in range(p.length()):
		var code: int = p.unicode_at(i)
		if code >= 48 and code <= 57:
			has_digit = true
		elif (code >= 65 and code <= 90) or (code >= 97 and code <= 122):
			has_alpha = true
	if has_digit or not has_alpha:
		return [false, "", 0.0]
	if p != "I" and p != key:
		# a capital letter: a proper noun unless it only opens the sentence with a known word
		var rest: String = p.substr(1)
		var first: String = p.substr(0, 1)
		var only_first: bool = first != first.to_lower() and rest == rest.to_lower()
		if not (at_start and only_first):
			return [false, "", 0.0]
		if not _forms.has(key) and not _zipf.has(key):
			return [false, "", 0.0]
	var lemma: String = lemma_of(key)
	if not _is_lemma_text(lemma):
		lemma = key
	return [true, lemma, maxf(zipf_of(lemma), zipf_of(key))]


static func _is_lemma_text(s: String) -> bool:
	return s != "" and s.to_lower() != s.to_upper()


# ---------------------------------------------------------------- gloss

static func _gloss_req(body: Dictionary) -> Dictionary:
	var lang: String = str(body.get("lang", ""))
	if lang != "en" and lang != "ja":
		return _bad_request(LANG_MSG)
	var items: Variant = body.get("items", null)
	if not (items is Array) or (items as Array).is_empty():
		return _bad_request(EMPTY_GLOSS_MSG)
	if (items as Array).size() > MAX_GLOSS:
		return _bad_request("한 번에 %d개까지 뜻을 찾을 수 있어요." % MAX_GLOSS)
	var lemmas: Array = []
	var any: bool = false
	for it in items:
		var d: Dictionary = it if it is Dictionary else {}
		var lemma: String = " ".join(str(d.get("lemma", "")).split(" ", false))
		lemma = lemma.substr(0, 60)
		if lang == "en" and _capitalised(lemma):
			lemma = lemma.to_lower()
		lemmas.append(lemma)
		if lemma != "":
			any = true
	if not any:
		return _bad_request(EMPTY_GLOSS_MSG)
	var dict: Dictionary = {}
	var gr: Dictionary = PackLoader.load_json("gloss_%s.json" % lang)
	if bool(gr.get("ok", false)) and gr["data"] is Dictionary:
		dict = gr["data"]
	var forms_ok: bool = lang == "en" and _tables_err() == ""
	var ipa_dict: Dictionary = {}
	var ipa_loaded: bool = false
	var out: Array = []
	var missing: bool = false
	for k in range(lemmas.size()):
		var lem: String = lemmas[k]
		if lem == "":
			continue
		var e: Variant = _gloss_entry(dict, lem, lang, forms_ok)
		if e == null:
			missing = true
			continue
		var ed: Dictionary = e
		var ipa: String = str(ed.get("ipa", ""))
		if ipa == "" and lang == "en":
			if not ipa_loaded:
				ipa_loaded = true
				var ir: Dictionary = PackLoader.load_json("ipa_en.json")
				if bool(ir.get("ok", false)) and ir["data"] is Dictionary:
					ipa_dict = ir["data"]
			ipa = str(ipa_dict.get(_norm_key(lem), ""))
		out.append({"i": k, "lemma": lem, "pos": str(ed.get("pos", "")), "ko": str(ed.get("ko", "")), "ipa": ipa,
			"note": str(ed.get("note", "")), "pron": ""})
	return LocalApi.ok({"glosses": out}, ["gloss_partial"] if missing else [])


## Entry with a non-empty `ko` for `lem` (as given, lower case, or the lemma of an inflected form), else null.
static func _gloss_entry(dict: Dictionary, lem: String, lang: String, forms_ok: bool) -> Variant:
	var cands: Array = [lem]
	if lang == "en":
		var lower: String = _norm_key(lem)
		cands.append(lower)
		if forms_ok and _forms.has(lower):
			cands.append(str(_forms[lower]))
	for c in cands:
		var e: Variant = dict.get(c, null)
		if e is Dictionary and str((e as Dictionary).get("ko", "")).strip_edges() != "":
			return e
	return null


## Python: lemma[:1].isupper() and lemma[1:].islower()
static func _capitalised(s: String) -> bool:
	if s.length() < 2:
		return false
	var first: String = s.substr(0, 1)
	var rest: String = s.substr(1)
	return first != first.to_lower() and rest == rest.to_lower() and rest != rest.to_upper()


# ---------------------------------------------------------------- examples

static func _examples_req(query: Dictionary) -> Dictionary:
	var lang: String = str(query.get("lang", "en"))
	if lang != "en" and lang != "ja":
		return _bad_request(LANG_MSG)
	var q: String = str(query.get("q", "")).strip_edges()
	if q == "":
		return _bad_request(EMPTY_Q_MSG)
	if q.length() > 60:
		return _bad_request(LONG_Q_MSG)
	var limit: int = 5
	var ls: String = str(query.get("limit", "")).strip_edges()
	if ls.is_valid_int():
		limit = clampi(ls.to_int(), 1, 20)
	var r: Dictionary = PackLoader.load_json("examples_%s.json" % lang)
	if not bool(r.get("ok", false)):
		return LocalApi.fail(str(r.get("err_code", "pack_missing")))
	var data: Variant = r["data"]
	if not (data is Dictionary) or not ((data as Dictionary).get("sent", null) is Dictionary) \
			or not ((data as Dictionary).get("idx", null) is Dictionary):
		return LocalApi.fail("pack_corrupt")
	var sent: Dictionary = (data as Dictionary)["sent"]
	var idx: Dictionary = (data as Dictionary)["idx"]
	var key: String = _norm_key(q) if lang == "en" else q
	var ids: Array = []
	var seen_text: Dictionary = {}
	var rows: Array = []
	var hit: Variant = idx.get(key, null)
	if hit is Array:
		for v in hit:
			var sid: String = str(int(v))
			var rec: Variant = sent.get(sid, null)
			if not (rec is Dictionary):
				continue
			var t: String = str((rec as Dictionary).get("t", ""))
			if ids.has(sid) or seen_text.has(t):
				continue
			ids.append(sid)
			seen_text[t] = true
			rows.append(_row(sid, rec, lang))
			if rows.size() >= limit:
				break
	if rows.is_empty():
		rows = _like_search(sent, lang, q, limit)
	var attribution: String = str((data as Dictionary).get("attribution", ATTRIBUTION))
	if attribution == "":
		attribution = ATTRIBUTION
	return LocalApi.ok({"examples": rows, "attribution": attribution}, ["examples_subset"] if rows.size() < limit else [])


static func _row(sid: String, rec: Dictionary, lang: String) -> Dictionary:
	var id: int = int(sid)
	return {"id": id, "text": str(rec.get("t", "")), "ko": str(rec.get("ko", "")), "en": "", "ja": "",
		"url": "https://tatoeba.org/sentences/show/%d" % id}


## Substring search over the sentences (English: whole words only, case-insensitive), like reading._like_search.
static func _like_search(sent: Dictionary, lang: String, q: String, limit: int) -> Array:
	var rows: Array = []
	var rx: RegEx = null
	if lang == "en":
		rx = RegEx.new()
		if rx.compile("(?i)(?<![A-Za-z])" + _escape_rx(q) + "(?![A-Za-z])") != OK:
			return rows
	for sid in sent.keys():
		var rec: Variant = sent[sid]
		if not (rec is Dictionary):
			continue
		var t: String = str((rec as Dictionary).get("t", ""))
		var found: bool = rx.search(t) != null if rx != null else t.contains(q)
		if found:
			rows.append(_row(str(sid), rec, lang))
			if rows.size() >= limit:
				break
	return rows


static func _escape_rx(s: String) -> String:
	var out: String = ""
	for i in range(s.length()):
		var ch: String = s[i]
		if "\\.^$|?*+()[]{}-/".contains(ch):
			out += "\\"
		out += ch
	return out
