extends Node
## Release course data (res://data/course, built by course_src/tools/build_course.py, weeks 1~16) -- v2.0 KB-3, KB-7, KB-8.
##   PC   : godot --headless --path <project>/godot res://tests/course_data_real_test.tscn
##   Phone: godot --headless --path <project>/godot --resolution 412x915 res://tests/course_data_real_test.tscn -- --phone
## Exit code 0 = all passed. Last line: "== course_data_real_test: N passed, M failed ==".
## Reads the real data through CourseData (hash check) and, independently, the raw JSON files (duplicate ids, counts, references).
## Broken copies (one flipped byte, a wrong manifest hash, a missing file) are written under user://test_kb_real and removed at the end.
## The checkers are also fed planted errors (lines "selfcheck FAIL-as-expected ...").

const TMP := "user://test_kb_real"
const FILES := ["en_weeks.json", "en_lexicon.json", "en_patterns.json", "en_sentences.json", "en_dialogues.json", "en_speak_prompts.json"]
const KEYS := {"en_weeks.json": "weeks", "en_lexicon.json": "words", "en_patterns.json": "patterns", "en_sentences.json": "sentences",
	"en_dialogues.json": "dialogues", "en_speak_prompts.json": "prompts"}
const WEEKS := 16
const MAX_TOTAL_BYTES := 1572864 ## 1.5 MB (KB-2)

## Data folder under test. Default: the release data. `-- --course-dir=<folder>` points the test at a copy (used to show that bad data fails).
var REAL: String = "res://data/course"
var passed: int = 0
var failed: int = 0
var _before: Array = []
var _saved_base: String = ""


func _ready() -> void:
	print("== course_data_real_test start ==")
	for a in OS.get_cmdline_user_args():
		if String(a).begins_with("--course-dir="):
			REAL = String(a).substr(13)
			print("  INFO  course dir override: ", REAL)
	_before = _user_listing()
	_saved_base = CourseData.base_dir
	_selfcheck()
	_manifest_and_hashes()
	_loader()
	_counts()
	_ids_and_refs()
	_token_order()
	_skeleton_table()
	_sources_and_personal()
	_tampered()
	_cleanup()
	CourseData.base_dir = _saved_base
	CourseData.reset()
	ok(_before == _user_listing(), "user:// listing unchanged by this test")
	print("== course_data_real_test: %d passed, %d failed ==" % [passed, failed])
	get_tree().quit(1 if failed > 0 else 0)


func ok(cond: bool, name: String) -> void:
	if cond:
		passed += 1
		print("  PASS  ", name)
	else:
		failed += 1
		print("  FAIL  ", name)


func eq(got: Variant, want: Variant, name: String) -> void:
	var good: bool = typeof(got) == typeof(want) and got == want
	ok(good, name if good else "%s  got=%s want=%s" % [name, str(got), str(want)])


# ------------------------------------------------------------------ helpers

func _read_json(path: String) -> Variant:
	if not FileAccess.file_exists(path):
		return null
	var j := JSON.new()
	if j.parse(FileAccess.get_file_as_string(path)) != OK:
		return null
	return j.data


func _list(file: String, dir: String = REAL) -> Array:
	var d: Variant = _read_json(dir.path_join(file))
	if d is Dictionary and (d as Dictionary).get(KEYS[file], null) is Array:
		return d[KEYS[file]]
	return []


func _sha(bytes: PackedByteArray) -> String:
	var c := HashingContext.new()
	c.start(HashingContext.HASH_SHA256)
	c.update(bytes)
	return c.finish().hex_encode()


## Problems of a manifest against the files next to it: wrong size / hash / record count / unlisted file. [] = fine.
func _manifest_problems(dir: String) -> Array:
	var out: Array = []
	var m: Variant = _read_json(dir.path_join("course_manifest.json"))
	if not (m is Dictionary) or not ((m as Dictionary).get("files", null) is Array):
		return ["manifest_unreadable"]
	var listed: Dictionary = {}
	for e in m["files"]:
		var name: String = str(e.get("path", ""))
		listed[name] = true
		var p: String = dir.path_join(name)
		if not FileAccess.file_exists(p):
			out.append("missing:" + name)
			continue
		var bytes: PackedByteArray = FileAccess.get_file_as_bytes(p)
		if bytes.size() != int(e.get("bytes", -1)):
			out.append("bytes:" + name)
		if _sha(bytes) != str(e.get("sha256", "")):
			out.append("sha256:" + name)
		if KEYS.has(name):
			var d: Variant = _read_json(p)
			if d is Dictionary and d.get(KEYS[name], null) is Array:
				if (d[KEYS[name]] as Array).size() != int(e.get("records", -1)):
					out.append("records:" + name)
			else:
				out.append("shape:" + name)
	for f in FILES:
		if f != "en_speak_prompts.json" and not listed.has(f):
			out.append("unlisted:" + f)
	return out


## ids that occur more than once in a list of records.
func _dup_ids(items: Array) -> Array:
	var seen: Dictionary = {}
	var dup: Array = []
	for it in items:
		var id: String = str(it.get("id", "")) if it is Dictionary else ""
		if id == "" or seen.has(id):
			dup.append(id)
		seen[id] = true
	return dup


## Words used by a sentence/dialogue-line list that are not lexicon ids.
func _unknown_word_refs(sentences: Array, lex: Dictionary) -> Array:
	var bad: Array = []
	for s in sentences:
		var ws: Variant = s.get("words", [])
		if not (ws is Array):
			bad.append(str(s.get("id", "")))
			continue
		for wid in ws:
			if not lex.has(wid):
				bad.append("%s:%s" % [s.get("id", ""), wid])
	return bad


## Sentences / lines whose own `o` is smaller than the `o` of a word they use (a future word).
func _future_refs(sentences: Array, lex: Dictionary) -> Array:
	var bad: Array = []
	for s in sentences:
		var o: int = int(s.get("o", 0))
		for wid in s.get("words", []):
			if lex.has(wid) and int(lex[wid].get("o", 0)) > o:
				bad.append("%s:%s" % [s.get("id", ""), wid])
	return bad


func _lex_by_id() -> Dictionary:
	var lex: Dictionary = {}
	for w in _list("en_lexicon.json"):
		lex[w["id"]] = w
	return lex


# ------------------------------------------------------------------ self checks (the checkers must be able to fail)

func _selfcheck() -> void:
	var dup: Array = _dup_ids([{"id": "w0001"}, {"id": "w0002"}, {"id": "w0001"}])
	ok(dup == ["w0001"], "selfcheck FAIL-as-expected duplicate id is found: %s" % str(dup))
	ok(not _dup_ids([{"id": "a"}, {"id": "b"}]).size() > 0, "selfcheck PASS-as-expected distinct ids are no duplicate")
	var lex := {"w0001": {"id": "w0001", "o": 11}, "w0002": {"id": "w0002", "o": 161}}
	var unk: Array = _unknown_word_refs([{"id": "s1", "words": ["w0001", "w9999"]}], lex)
	ok(unk.size() == 1, "selfcheck FAIL-as-expected unknown word ref is found: %s" % str(unk))
	var fut: Array = _future_refs([{"id": "s2", "o": 52, "words": ["w0001", "w0002"]}], lex)
	ok(fut == ["s2:w0002"], "selfcheck FAIL-as-expected future word (week 16 word in a week 5 sentence) is found: %s" % str(fut))
	ok(_future_refs([{"id": "s3", "o": 52, "words": ["w0001"]}], lex).is_empty(), "selfcheck PASS-as-expected a past word is no future word")
	ok(_sha(PackedByteArray([1, 2, 3])) != _sha(PackedByteArray([1, 2, 4])), "selfcheck hash differs for one changed byte")


# ------------------------------------------------------------------ KB-2 / KB-3

func _manifest_and_hashes() -> void:
	var probs: Array = _manifest_problems(REAL)
	ok(probs.is_empty(), "manifest sizes / sha256 / record counts match the real files %s" % str(probs))
	var m: Dictionary = _read_json(REAL.path_join("course_manifest.json"))
	var total: int = FileAccess.get_file_as_bytes(REAL.path_join("course_manifest.json")).size()
	var lines: Array = []
	for e in m["files"]:
		total += int(e["bytes"])
		lines.append("%s %d bytes %d records" % [e["path"], int(e["bytes"]), int(e["records"])])
	print("  INFO  files: ", "; ".join(PackedStringArray(lines)))
	print("  INFO  data total bytes (manifest + files): %d" % total)
	ok(total <= MAX_TOTAL_BYTES, "total size %d <= %d" % [total, MAX_TOTAL_BYTES])
	eq(int(m.get("v", 0)), 1, "manifest v == 1")
	eq(str(m.get("lang", "")), "en", "manifest lang == en")
	var mw: Array = m.get("weeks", [])
	ok(mw.size() == 2 and int(mw[0]) == 1 and int(mw[1]) == WEEKS, "manifest weeks == [1, 16] %s" % str(mw))
	eq(int(m.get("count", 0)), WEEKS, "manifest count == 16")
	# planted errors for the manifest checker (scratch copy)
	_planted_manifest_errors()


func _loader() -> void:
	CourseData.base_dir = REAL
	CourseData.reset()
	var r: Dictionary = CourseData.load_all()
	ok(bool(r.get("ok", false)), "CourseData.load_all ok (err_code '%s')" % str(r.get("err_code", "")))
	for f in FILES:
		eq(str(r["files"].get(f, "?")), "ok", "file status %s" % f)
	eq(CourseData.available_weeks(), WEEKS, "available_weeks() == 16")
	var st: Dictionary = CourseData.stats()
	print("  INFO  stats: ", str(st))
	eq(int(st["skipped"]), 0, "stats.skipped == 0 (no record dropped by the loader)")
	eq(int(st["weeks"]), WEEKS, "weeks indexed == 16")
	for w in range(1, WEEKS + 1):
		ok(not CourseData.week(w).is_empty(), "week %d present" % w)
	ok(CourseData.week(WEEKS + 1).is_empty(), "week 17 absent")


func _counts() -> void:
	var words: Array = _list("en_lexicon.json")
	var active: int = 0
	var passive: int = 0
	for w in words:
		if str(w.get("role", "")) == "active":
			active += 1
		elif str(w.get("role", "")) == "passive":
			passive += 1
	var pats: Array = _list("en_patterns.json")
	var sents: Array = _list("en_sentences.json")
	var dlgs: Array = _list("en_dialogues.json")
	var prompts: Array = _list("en_speak_prompts.json")
	var p_total: int = 0
	for g in prompts:
		p_total += (g["prompts"] as Array).size()
	print("  INFO  counts: active=%d passive=%d patterns=%d sentences=%d dialogues=%d prompt_groups=%d prompts=%d" % [
		active, passive, pats.size(), sents.size(), dlgs.size(), prompts.size(), p_total])
	ok(active >= 370 and active <= 410, "active words %d in 370..410" % active)
	ok(passive >= 110 and passive <= 130, "passive words %d in 110..130" % passive)
	eq(active + passive, words.size(), "every word is active or passive")
	ok(pats.size() >= 40 and pats.size() <= 60, "patterns %d in 40..60 (about 50 +-10)" % pats.size())
	eq(dlgs.size(), WEEKS, "dialogues == 16")
	eq(prompts.size(), 4, "speak prompt groups == 4 (months 1..4)")
	for g in prompts:
		eq((g["prompts"] as Array).size(), 3, "month %s has 3 prompts" % str(g.get("month")))
	var per_week: Dictionary = {}
	for s in sents:
		var w: int = int(s["o"]) / 10
		per_week[w] = int(per_week.get(w, 0)) + 1
	var lo: int = 1 << 30
	var parts: Array = []
	for w in range(1, WEEKS + 1):
		var n: int = int(per_week.get(w, 0))
		lo = mini(lo, n)
		parts.append(str(n))
		ok(n >= 36, "week %d sentences %d >= 36" % [w, n])
		eq(CourseData.sentences_for(w).size(), n, "sentences_for(%d) matches the file" % w)
	print("  INFO  sentences per week: ", ",".join(PackedStringArray(parts)), " (min %d)" % lo)
	# per week: words (active new / passive), patterns, dialogue exist
	for w in range(1, WEEKS + 1):
		var wk: Dictionary = CourseData.week(w)
		var wn: Array = wk.get("words", {}).get("new", [])
		var wp: Array = wk.get("words", {}).get("passive", [])
		ok(wn.size() >= 3 and wp.size() <= 16, "week %d new words %d, passive %d" % [w, wn.size(), wp.size()])
		ok(not CourseData.dialogue(str(wk.get("dialogue", ""))).is_empty(), "week %d dialogue %s exists" % [w, str(wk.get("dialogue", ""))])
		for pid in wk.get("patterns", []):
			ok(not CourseData.pattern(pid).is_empty(), "week %d pattern %s exists" % [w, str(pid)])
		eq((wk.get("days", []) as Array).size(), 7, "week %d has 7 day entries" % w)


func _ids_and_refs() -> void:
	for f in FILES:
		var items: Array = _list(f)
		var dups: Array = _dup_ids(items) if f != "en_weeks.json" and f != "en_speak_prompts.json" else []
		eq(dups.size(), 0, "no duplicate or empty id in %s %s" % [f, str(dups.slice(0, 5))])
	var wk_ids: Dictionary = {}
	for wk in _list("en_weeks.json"):
		ok(not wk_ids.has(wk["w"]), "week number %d appears once" % int(wk["w"]))
		wk_ids[wk["w"]] = true
	var lex: Dictionary = _lex_by_id()
	var sents: Array = _list("en_sentences.json")
	var unk: Array = _unknown_word_refs(sents, lex)
	eq(unk.size(), 0, "every sentence `words` id is in the lexicon %s" % str(unk.slice(0, 5)))
	var fut: Array = _future_refs(sents, lex)
	eq(fut.size(), 0, "no sentence uses a word introduced after it (o) %s" % str(fut.slice(0, 5)))
	var lines: Array = []
	var dl_unknown: Array = []
	var dl_future: Array = []
	for d in _list("en_dialogues.json"):
		for ln in d["lines"]:
			lines.append({"id": "%s#%s" % [d["id"], str(ln.get("s", ""))], "o": int(ln.get("o", 0)), "words": ln.get("words", [])})
	dl_unknown = _unknown_word_refs(lines, lex)
	dl_future = _future_refs(lines, lex)
	eq(dl_unknown.size(), 0, "every dialogue line `words` id is in the lexicon %s" % str(dl_unknown.slice(0, 5)))
	eq(dl_future.size(), 0, "no dialogue line uses a later word %s" % str(dl_future.slice(0, 5)))
	# sentence o is inside its week; pattern ids / examples resolve
	var pats: Dictionary = {}
	for p in _list("en_patterns.json"):
		pats[p["id"]] = p
	var bad_pat: Array = []
	for s in sents:
		if str(s.get("pat", "")) != "" and not pats.has(s["pat"]):
			bad_pat.append(s["id"])
	eq(bad_pat.size(), 0, "every sentence `pat` is a pattern id %s" % str(bad_pat.slice(0, 5)))
	var sent_ids: Dictionary = {}
	for s in sents:
		sent_ids[s["id"]] = true
	var bad_ex: Array = []
	for p in pats.values():
		for e in p.get("examples", []):
			if not sent_ids.has(e):
				bad_ex.append("%s:%s" % [p["id"], e])
	eq(bad_ex.size(), 0, "every pattern example is a sentence id %s" % str(bad_ex.slice(0, 5)))
	# word forms point at patterns that exist; form o respects the pattern
	var bad_form: Array = []
	for w in lex.values():
		for f in w.get("forms", []):
			if not pats.has(str(f.get("pat", ""))):
				bad_form.append("%s:%s" % [w["id"], f.get("f", "")])
	eq(bad_form.size(), 0, "every word form names an existing pattern %s" % str(bad_form.slice(0, 5)))
	# ko of a word is Hangul text, not empty, and id ranges follow the design (w0001~w0699 / s0001~s0999 / d0001~)
	var bad_range: Array = []
	for id in lex.keys():
		var n: int = int(str(id).substr(1))
		if not str(id).begins_with("w") or n < 1 or n > 699:
			bad_range.append(id)
	for s in sents:
		var n2: int = int(str(s["id"]).substr(1))
		if not str(s["id"]).begins_with("s") or n2 < 1 or n2 > 999:
			bad_range.append(s["id"])
	eq(bad_range.size(), 0, "ids stay inside the R1 ranges %s" % str(bad_range.slice(0, 5)))
	var no_ko: Array = []
	for w in lex.values():
		if str(w.get("ko", "")).strip_edges() == "":
			no_ko.append(w["id"])
	for s in sents:
		if str(s.get("ko", "")).strip_edges() == "":
			no_ko.append(s["id"])
	eq(no_ko.size(), 0, "no word / sentence without ko %s" % str(no_ko.slice(0, 5)))


## Token level: every word of the `en` text of a sentence / dialogue line is a lexicon spelling (headword, alt, form) whose smallest o is
## <= the o of the sentence. Independent of the `words` lists of the records. Digits are skipped here; their readings (`say`: number words,
## letter names of an acronym) are covered by course_guard_all_test (tts of every exercise) and by the linter NUM_SAY rules.
func _spelling_table(lex: Dictionary) -> Dictionary:
	var rx := RegEx.create_from_string("[a-z0-9]+(?:'[a-z0-9]+)*")
	var tab: Dictionary = {}
	var add := func(text: String, o: int) -> void:
		for m in rx.search_all(text.to_lower().replace("’", "'")):
			var t: String = m.get_string()
			if not tab.has(t) or int(tab[t]) > o:
				tab[t] = o
	var pats: Dictionary = {}
	for p in _list("en_patterns.json"):
		pats[p["id"]] = int(p.get("o", 0))
	for w in lex.values():
		var o: int = int(w["o"])
		add.call(str(w.get("en", "")), o)
		for a in w.get("alt", []):
			add.call(str(a), o)
		for f in w.get("forms", []):
			add.call(str(f.get("f", "")), maxi(o, int(pats.get(str(f.get("pat", "")), 0))))
	return tab


## items = [{id, o, text}] -> {future: [...], unknown: [...]}
func _token_problems(items: Array, tab: Dictionary) -> Dictionary:
	var rx := RegEx.create_from_string("[a-z0-9]+(?:'[a-z0-9]+)*")
	var fut: Array = []
	var unk: Array = []
	for it in items:
		for m in rx.search_all(str(it["text"]).to_lower().replace("’", "'")):
			var t: String = m.get_string()
			if t.is_valid_int():
				continue
			if not tab.has(t):
				unk.append("%s:%s" % [it["id"], t])
			elif int(tab[t]) > int(it["o"]):
				fut.append("%s:%s(o=%d>%d)" % [it["id"], t, int(tab[t]), int(it["o"])])
	return {"future": fut, "unknown": unk}


func _token_order() -> void:
	var lex: Dictionary = _lex_by_id()
	var tab: Dictionary = _spelling_table(lex)
	var items: Array = []
	for s in _list("en_sentences.json"):
		items.append({"id": s["id"], "o": int(s["o"]), "text": str(s.get("en", ""))})
	for d in _list("en_dialogues.json"):
		var i: int = 0
		for ln in d["lines"]:
			i += 1
			items.append({"id": "%s#%d" % [d["id"], i], "o": int(ln.get("o", 0)), "text": str(ln.get("en", ""))})
	var r: Dictionary = _token_problems(items, tab)
	eq((r["future"] as Array).size(), 0, "no sentence / dialogue line contains a word taught later than it (%d items, %d spellings) %s" % [items.size(), tab.size(), str((r["future"] as Array).slice(0, 5))])
	eq((r["unknown"] as Array).size(), 0, "no sentence / dialogue line contains a word that is not in the lexicon %s" % str((r["unknown"] as Array).slice(0, 8)))
	# planted: a week 16 word inside a week 5 sentence, and an invented word
	var late: String = ""
	for w in lex.values():
		if int(w["o"]) >= 160 and str(w["en"]).find(" ") < 0 and str(w["pos"]) != "propn":
			late = str(w["en"])
			break
	var p1: Dictionary = _token_problems([{"id": "plant1", "o": 52, "text": "Hi. " + late + "."}], tab)
	var p2: Dictionary = _token_problems([{"id": "plant2", "o": 52, "text": "Hi. zzyzx."}], tab)
	var p3: Dictionary = _token_problems([{"id": "plant3", "o": 52, "text": "Hi. Hello."}], tab)
	ok((p1["future"] as Array).size() == 1, "selfcheck FAIL-as-expected a week 16 word (%s) in a week 5 sentence is found: %s" % [late, str(p1["future"])])
	ok((p2["unknown"] as Array).size() == 1, "selfcheck FAIL-as-expected an unknown word is found: %s" % str(p2["unknown"]))
	ok((p3["future"] as Array).is_empty() and (p3["unknown"] as Array).is_empty(), "selfcheck PASS-as-expected 'Hi. Hello.' at week 5 is accepted")


## Every word's o equals the assignment table (skeleton.json) and the day it is listed on in en_weeks.json.
func _skeleton_table() -> void:
	var lex: Dictionary = _lex_by_id()
	# (a) en_weeks.json: o == w*10 + d of the day that lists the word (always possible, data only)
	var day_of: Dictionary = {}
	for wk in _list("en_weeks.json"):
		for dd in wk.get("days", []):
			for wid in dd.get("words", []):
				day_of[wid] = int(wk["w"]) * 10 + int(dd["d"])
	var bad_o: Array = []
	var missing_day: int = 0
	for w in lex.values():
		if str(w.get("role", "")) == "active":
			if not day_of.has(w["id"]):
				missing_day += 1
			elif int(w["o"]) != int(day_of[w["id"]]):
				bad_o.append("%s:%d!=%d" % [w["id"], int(w["o"]), int(day_of[w["id"]])])
	eq(bad_o.size(), 0, "active word o == w*10+d of its day in en_weeks.json %s" % str(bad_o.slice(0, 5)))
	eq(missing_day, 0, "every active word is listed on a day of its week")
	# (b) skeleton.json assignment table (only in the repository, not in the exported app)
	var sk_path: String = ProjectSettings.globalize_path("res://").path_join("../course_src/en/skeleton.json").simplify_path()
	var sk: Variant = _read_json(sk_path)
	if not (sk is Dictionary) or not (sk.get("words", null) is Array):
		print("  INFO  skeleton.json not found next to the project: table comparison UNVERIFIED (not counted as a pass)")
		return
	var rows: Array = (sk["words"] as Array).filter(func(t): return int(t.get("w", 99)) <= WEEKS)
	var in_table: int = rows.size()
	var table_ids: Dictionary = {}
	for t in rows:
		table_ids[t["id"]] = true
	var bad_tbl: Array = _table_mismatches(lex, rows)
	eq(bad_tbl.size(), 0, "every word o / role equals the assignment table of skeleton.json (%d rows) %s" % [in_table, str(bad_tbl.slice(0, 5))])
	var extra: Array = []
	for id in lex.keys():
		if not table_ids.has(id):
			extra.append(id)
	var extra_bad: Array = extra.filter(func(i): return str(lex[i].get("pos", "")) != "propn")
	print("  INFO  lexicon words not in the table: %d (all proper nouns: %s)" % [extra.size(), str(extra_bad.is_empty())])
	eq(extra_bad.size(), 0, "words outside the table are only proper nouns %s" % str(extra_bad.slice(0, 5)))
	# planted: a wrong o / role / missing word in the table must be found by the same comparison
	var first: Dictionary = rows[0]
	var plant1: Array = _table_mismatches(lex, [{"id": first["id"], "w": int(first["w"]) + 1, "d": first["d"], "role": first["role"]}])
	var plant2: Array = _table_mismatches(lex, [{"id": first["id"], "w": first["w"], "d": first["d"], "role": "passive" if first["role"] == "active" else "active"}])
	var plant3: Array = _table_mismatches(lex, [{"id": "w9999", "w": 1, "d": 1, "role": "active"}])
	ok(plant1.size() == 1 and plant2.size() == 1 and plant3.size() == 1,
		"selfcheck FAIL-as-expected a table row with a wrong week / role / unknown id is found: %s %s %s" % [str(plant1), str(plant2), str(plant3)])
	ok(_table_mismatches(lex, [first]).is_empty(), "selfcheck PASS-as-expected the true table row is accepted")


## Rows of the assignment table {id, w, d, role} whose word is absent or has another o / role in the lexicon.
func _table_mismatches(lex: Dictionary, rows: Array) -> Array:
	var bad: Array = []
	for t in rows:
		var want: int = int(t["w"]) * 10 + int(t["d"])
		if not lex.has(t["id"]):
			bad.append("%s:absent" % t["id"])
		elif int(lex[t["id"]]["o"]) != want:
			bad.append("%s:o=%d!=%d" % [t["id"], int(lex[t["id"]]["o"]), want])
		elif str(lex[t["id"]]["role"]) != str(t["role"]):
			bad.append("%s:role" % t["id"])
	return bad


# ------------------------------------------------------------------ KB-8

func _sources_and_personal() -> void:
	var sents: Array = _list("en_sentences.json")
	var tat: int = 0
	var own_bad: Array = []
	var tat_bad: Array = []
	for s in sents:
		var src: String = str(s.get("src", ""))
		var tid: int = int(s.get("tid", 0))
		if src == "tatoeba":
			tat += 1
			if tid <= 0:
				tat_bad.append(s["id"])
		elif src == "own":
			if tid != 0:
				own_bad.append(s["id"])
		else:
			own_bad.append(s["id"])
	print("  INFO  Tatoeba sentences: %d of %d" % [tat, sents.size()])
	eq(tat_bad.size(), 0, "every Tatoeba sentence has a tid %s" % str(tat_bad.slice(0, 5)))
	eq(own_bad.size(), 0, "own sentences have tid 0 and src is own|tatoeba %s" % str(own_bad.slice(0, 5)))
	ok(tat * 4 <= sents.size(), "Tatoeba share <= 25 %%")
	if tat > 0:
		eq(LocalReading.ATTRIBUTION, ShadowScreen.ATTRIBUTION, "attribution text equal in reading and shadow screens")
	# personal data and paths in every data file (raw text)
	var rx_path := RegEx.create_from_string("(?i)[a-z]:[\\\\/]|\\\\users\\\\|/users/|/home/|rtyu6|whahan|appdata|desktop")
	var rx_mail := RegEx.create_from_string("[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}")
	var rx_url := RegEx.create_from_string("(?i)https?://|www\\.")
	var rx_phone := RegEx.create_from_string("\\b\\d{3}[-. ]\\d{2,4}[-. ]\\d{4}\\b|\\b\\d{3}-\\d{4}\\b")
	var hits: Array = []
	var phones: Array = []
	for f in FILES + ["course_manifest.json"]:
		var txt: String = FileAccess.get_file_as_string(REAL.path_join(f))
		for rx in [rx_path, rx_mail, rx_url]:
			var m: RegExMatch = rx.search(txt)
			if m != null:
				hits.append("%s:%s" % [f, m.get_string()])
		for m2 in rx_phone.search_all(txt):
			var s2: String = m2.get_string()
			if not (s2.contains("555-01") or s2.contains("555 01")):
				phones.append("%s:%s" % [f, s2])
	eq(hits.size(), 0, "no user path / name / e-mail / URL in the data files %s" % str(hits.slice(0, 5)))
	eq(phones.size(), 0, "no phone number other than 555-01xx %s" % str(phones.slice(0, 5)))
	var plant: RegExMatch = rx_path.search("C:\\Users\\someone\\x")
	ok(plant != null, "selfcheck FAIL-as-expected a user path is caught by the path pattern")
	ok(rx_mail.search("a@b.com") != null, "selfcheck FAIL-as-expected an e-mail is caught by the mail pattern")
	ok(rx_phone.search("call 604-555-1234") != null and rx_phone.search("call 604-555-0123") != null,
		"selfcheck phone pattern matches phone shaped text (555-01xx is then excluded by the test)")


# ------------------------------------------------------------------ KB-7 (broken copies)

func _copy_dir(to: String) -> void:
	DirAccess.make_dir_recursive_absolute(to)
	for f in FILES + ["course_manifest.json"]:
		var bytes: PackedByteArray = FileAccess.get_file_as_bytes(REAL.path_join(f))
		var fa := FileAccess.open(to.path_join(f), FileAccess.WRITE)
		fa.store_buffer(bytes)
		fa.close()


func _planted_manifest_errors() -> void:
	var d: String = TMP.path_join("plant")
	_copy_dir(d)
	ok(_manifest_problems(d).is_empty(), "scratch copy: untouched copy has no manifest problem")
	# wrong hash in the manifest
	var m: Dictionary = _read_json(d.path_join("course_manifest.json"))
	m["files"][0]["sha256"] = "0".repeat(64)
	_write(d.path_join("course_manifest.json"), JSON.stringify(m, "", false).to_utf8_buffer())
	var p1: Array = _manifest_problems(d)
	ok(p1.size() == 1 and str(p1[0]).begins_with("sha256:"), "selfcheck FAIL-as-expected wrong manifest hash is found: %s" % str(p1))
	# wrong record count
	m = _read_json(REAL.path_join("course_manifest.json"))
	m["files"][1]["records"] = int(m["files"][1]["records"]) + 1
	_write(d.path_join("course_manifest.json"), JSON.stringify(m, "", false).to_utf8_buffer())
	var p2: Array = _manifest_problems(d)
	ok(p2.size() == 1 and str(p2[0]).begins_with("records:"), "selfcheck FAIL-as-expected wrong record count is found: %s" % str(p2))
	# one flipped byte in a data file
	_copy_dir(d)
	var bytes: PackedByteArray = FileAccess.get_file_as_bytes(d.path_join("en_lexicon.json"))
	bytes[bytes.size() / 2] = bytes[bytes.size() / 2] ^ 1
	_write(d.path_join("en_lexicon.json"), bytes)
	var p3: Array = _manifest_problems(d)
	ok(p3.has("sha256:en_lexicon.json"), "selfcheck FAIL-as-expected one flipped byte changes the hash: %s" % str(p3))
	_rm_tree(d)


func _write(path: String, bytes: PackedByteArray) -> void:
	var fa := FileAccess.open(path, FileAccess.WRITE)
	if fa == null:
		return
	fa.store_buffer(bytes)
	fa.close()


func _load_from(dir: String) -> Dictionary:
	CourseData.base_dir = dir
	CourseData.reset()
	return CourseData.load_all()


func _tampered() -> void:
	# control: a faithful copy loads ok
	var good: String = TMP.path_join("good")
	_copy_dir(good)
	var r0: Dictionary = _load_from(good)
	ok(bool(r0["ok"]) and CourseData.available_weeks() == WEEKS, "control: an untouched copy loads ok, 16 weeks")
	# (1) one byte changed in a data file, same length, still valid JSON: only the hash can notice
	var d1: String = TMP.path_join("flip")
	_copy_dir(d1)
	var bytes: PackedByteArray = FileAccess.get_file_as_bytes(d1.path_join("en_sentences.json"))
	var pos: int = -1
	for i in range(bytes.size() / 2, bytes.size()):
		if bytes[i] >= 97 and bytes[i] <= 121: # a..y -> next letter
			pos = i
			break
	bytes[pos] = bytes[pos] + 1
	_write(d1.path_join("en_sentences.json"), bytes)
	var r1: Dictionary = _load_from(d1)
	eq(str(r1["err_code"]), "course_corrupt", "selfcheck FAIL-as-expected one changed byte -> course_corrupt")
	eq(str(r1["files"]["en_sentences.json"]), "course_corrupt", "  the changed file is the one reported")
	eq(str(r1["files"]["en_lexicon.json"]), "ok", "  the other files keep loading")
	ok(CourseData.word("w0001").size() > 0, "  words are still readable when sentences are corrupt")
	# (2) wrong hash in the manifest
	var d2: String = TMP.path_join("hash")
	_copy_dir(d2)
	var m: Dictionary = _read_json(d2.path_join("course_manifest.json"))
	m["files"][2]["sha256"] = "f".repeat(64)
	_write(d2.path_join("course_manifest.json"), JSON.stringify(m, "", false).to_utf8_buffer())
	var r2: Dictionary = _load_from(d2)
	eq(str(r2["err_code"]), "course_corrupt", "selfcheck FAIL-as-expected wrong manifest hash -> course_corrupt")
	# (3) truncated file
	var d3: String = TMP.path_join("short")
	_copy_dir(d3)
	var b3: PackedByteArray = FileAccess.get_file_as_bytes(d3.path_join("en_weeks.json"))
	_write(d3.path_join("en_weeks.json"), b3.slice(0, b3.size() - 1))
	var r3: Dictionary = _load_from(d3)
	eq(str(r3["err_code"]), "course_corrupt", "selfcheck FAIL-as-expected truncated file -> course_corrupt")
	# (4) missing file
	var d4: String = TMP.path_join("gone")
	_copy_dir(d4)
	DirAccess.remove_absolute(d4.path_join("en_dialogues.json"))
	var r4: Dictionary = _load_from(d4)
	eq(str(r4["err_code"]), "course_missing", "selfcheck FAIL-as-expected missing file -> course_missing")
	# (5) no manifest
	var d5: String = TMP.path_join("nomanifest")
	_copy_dir(d5)
	DirAccess.remove_absolute(d5.path_join("course_manifest.json"))
	var r5: Dictionary = _load_from(d5)
	eq(str(r5["err_code"]), "course_missing", "selfcheck FAIL-as-expected no manifest -> course_missing")
	# back to the real data
	var rr: Dictionary = _load_from(REAL)
	ok(bool(rr["ok"]) and CourseData.available_weeks() == WEEKS, "real data loads again after the broken copies")


# ------------------------------------------------------------------ housekeeping

func _user_listing() -> Array:
	var out: Array = []
	var d := DirAccess.open("user://")
	if d == null:
		return out
	for n in d.get_files():
		out.append("f:%s:%d" % [n, FileAccess.get_file_as_bytes("user://" + n).size()])
	for n in d.get_directories():
		out.append("d:" + n)
	out.sort()
	return out


func _cleanup() -> void:
	_rm_tree(TMP)


func _rm_tree(p: String) -> void:
	var da := DirAccess.open(p)
	if da == null:
		return
	for f in da.get_files():
		DirAccess.remove_absolute(p.path_join(f))
	for sub in da.get_directories():
		_rm_tree(p.path_join(sub))
	DirAccess.remove_absolute(p)
