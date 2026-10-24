extends Node
## A4: LocalReading (phone POST /reading/analyze, POST /reading/gloss, GET /examples) against the shipped pack,
## small fixture packs and the PC golden file.
##   godot --headless --path <project> res://tests/local_reading_test.tscn [-- --golden=<path>]
## Exit code 0 = all checks passed. Last line: "== local_reading_test result: N passed, 0 failed =="
## Golden file: res://tests/fixtures/reading_golden.json (written by backend/tools/make_reading_golden.py from the PC
## server's POST /reading/analyze). `--golden=<path>` swaps in another golden file (tamper check).
## Fixture packs (PackLoader.base_dir is restored at the end): res://tests/fixtures/reading_pack (tiny reading / ipa /
## gloss / examples files with correct hashes), reading_pack_bad (wrong hashes), reading_pack_empty (no files).

const GOLDEN := "res://tests/fixtures/reading_golden.json"
const FIX := "res://tests/fixtures/reading_pack"
const FIX_BAD := "res://tests/fixtures/reading_pack_bad"
const FIX_EMPTY := "res://tests/fixtures/reading_pack_empty"
## Copied from backend/reading.py (analyze).
const PC_EMPTY := "분석할 글을 붙여 넣어 주세요."
const PC_LONG_20001 := "글이 너무 길어요. 20000자까지 한 번에 읽을 수 있어요(지금 20001자)."
const MIN_LEMMA := 0.90
const MIN_LEVEL := 0.85
const SECTIONS := 13

var passed: int = 0
var failed: int = 0
var lemma_rate: float = 0.0
var level_rate: float = 0.0
var sections_done: Array = []   ## a section that stops on a script error never reaches its _end()


func _ready() -> void:
	print("== local_reading_test start ==")
	PackLoader.base_dir = PackLoader.DEFAULT_DIR
	PackLoader.reset()
	LocalReading.reset()
	_test_pack()
	_test_shape()
	_test_golden()
	_test_lemma_cases()
	_test_non_words()
	_test_sentences()
	_test_errors_and_ja()
	_test_odd_inputs()
	_test_examples_real()
	await _test_dispatch()
	_test_fixture_pack()
	_test_gloss()
	_test_examples_fixture()
	_test_bad_and_empty_packs()
	PackLoader.base_dir = PackLoader.DEFAULT_DIR
	PackLoader.reset()
	LocalReading.reset()
	ok(sections_done.size() == SECTIONS, "all %d sections ran to their end (%s)" % [SECTIONS, str(sections_done)])
	print("== local_reading_test result: %d passed, %d failed ==" % [passed, failed])
	get_tree().quit(1 if failed > 0 else 0)


func _end(name: String) -> void:
	sections_done.append(name)


func ok(cond: bool, name: String) -> void:
	if cond:
		passed += 1
	else:
		failed += 1
		print("  FAIL  ", name)


func _analyze(text: Variant, lang: String = "en") -> Dictionary:
	return LocalReading.handle("POST", "/reading/analyze", {}, {"lang": lang, "text": text})


func _gloss(items: Variant, lang: String = "en") -> Dictionary:
	return LocalReading.handle("POST", "/reading/gloss", {}, {"lang": lang, "items": items})


func _examples(q: String, limit: String = "", lang: String = "en") -> Dictionary:
	var query: Dictionary = {"lang": lang, "q": q}
	if limit != "":
		query["limit"] = limit
	return LocalReading.handle("GET", "/examples", query, {})


func _use_pack(dir: String) -> void:
	PackLoader.base_dir = dir
	PackLoader.reset()
	LocalReading.reset()


func _golden_path() -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--golden="):
			return a.substr(9)
	return GOLDEN


func _load_golden() -> Dictionary:
	var f: FileAccess = FileAccess.open(_golden_path(), FileAccess.READ)
	if f == null:
		return {}
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	if parsed is Dictionary:
		return parsed
	return {}


func _joined(tokens: Array) -> String:
	var s: String = ""
	for t in tokens:
		s += str(t["t"])
	return s


func _word_tokens(r: Dictionary) -> int:
	var n: int = 0
	for t in r["data"]["tokens"]:
		if bool(t["w"]):
			n += 1
	return n


# ---------------------------------------------------------------- sections

func _test_pack() -> void:
	print("[pack, availability]")
	ok(LocalReading.is_available(), "is_available with the shipped pack")
	ok(str(LocalReading.unavailable_reason()["err_code"]) == "", "unavailable_reason is empty when the pack is fine")
	ok(LocalReading.zipf_of("the") > 6.0, "zipf_of(the) is high (%s)" % str(LocalReading.zipf_of("the")))
	ok(LocalReading.zipf_of("zzzqqxx") == 0.0, "zipf_of(unknown) is 0")
	ok(LocalReading.level_of(4.5) == "easy" and LocalReading.level_of(4.49) == "mid", "level_of 4.5 / 4.49 -> easy / mid")
	ok(LocalReading.level_of(3.5) == "mid" and LocalReading.level_of(3.49) == "hard", "level_of 3.5 / 3.49 -> mid / hard")
	var r: Dictionary = LocalReading.handle("DELETE", "/reading/analyze", {}, {})
	ok(not bool(r["ok"]) and str(r["err_code"]) == "not_on_phone", "other method / path -> not_on_phone")
	_end("pack")


func _test_shape() -> void:
	print("[analyze shape]")
	var r: Dictionary = _analyze("Running is fun. The dogs were barking loudly!")
	ok(bool(r["ok"]) and int(r["code"]) == 200, "analyze is ok 200")
	var d: Dictionary = r["data"]
	ok(str(d["via"]) == "phone" and (d["degraded"] as Array).is_empty(), "via phone, degraded empty")
	ok(d.has("tokens") and d.has("sentences") and d.has("words"), "tokens, sentences, words present")
	ok(_joined(d["tokens"]) == "Running is fun. The dogs were barking loudly!", "tokens join back to the text exactly")
	var keys_ok: bool = true
	for t in d["tokens"]:
		if not (t.has("t") and t.has("w") and t.has("s")):
			keys_ok = false
		if bool(t["w"]) and not (t.has("lemma") and t.has("zipf") and t.has("level")):
			keys_ok = false
	ok(keys_ok, "every token has t/w/s and words have lemma/zipf/level")
	ok((d["sentences"] as Array).size() == 2, "two sentences (%d)" % (d["sentences"] as Array).size())
	ok(str(d["sentences"][0]["text"]) == "Running is fun." and int(d["sentences"][1]["i"]) == 1, "sentence texts and indexes")
	var count_sum: int = 0
	for w in d["words"]:
		count_sum += int(w["count"])
	ok(count_sum == _word_tokens(r), "sum of word counts == word tokens (%d)" % count_sum)
	var lemmas: Array = []
	for w in d["words"]:
		lemmas.append(str(w["lemma"]))
	ok(lemmas.has("run") and lemmas.has("be") and lemmas.has("bark"), "words hold run / be / bark (%s)" % str(lemmas))
	var seen: Dictionary = {}
	var uniq: bool = true
	for l in lemmas:
		if seen.has(l):
			uniq = false
		seen[l] = true
	ok(uniq, "words are unique by lemma")
	var level_ok: bool = true
	for w in d["words"]:
		if str(w["level"]) != LocalReading.level_of(float(w["zipf"])):
			level_ok = false
	ok(level_ok, "word level follows the zipf thresholds")
	ok(bool(r["ok"]) and typeof(d["tokens"][0]["zipf"]) == TYPE_FLOAT, "zipf is a float")


func _test_golden() -> void:
	print("[golden: PC server output]")
	var g: Dictionary = _load_golden()
	var entries: Array = g.get("entries", []) as Array
	ok(entries.size() == 5, "golden has 5 paragraphs (%d)" % entries.size())
	var total: int = 0
	var lemma_ok: int = 0
	var level_ok: int = 0
	var sent_ok: int = 0
	var sent_total: int = 0
	var join_ok: bool = true
	for e in entries:
		var text: String = str(e["text"])
		var gt: Array = e["response"]["tokens"]
		var r: Dictionary = _analyze(text)
		if not bool(r["ok"]):
			join_ok = false
			continue
		var pt: Array = r["data"]["tokens"]
		if _joined(pt) != text or _joined(gt) != text:
			join_ok = false
		# word tokens by character offset
		var by_off: Dictionary = {}
		var off: int = 0
		for t in pt:
			if bool(t["w"]):
				by_off[off] = t
			off += str(t["t"]).length()
		off = 0
		for t in gt:
			if bool(t["w"]):
				total += 1
				var p: Variant = by_off.get(off, null)
				if p != null and str(p["t"]) == str(t["t"]):
					if str(p["lemma"]) == str(t["lemma"]):
						lemma_ok += 1
					if str(p["level"]) == str(t["level"]):
						level_ok += 1
			off += str(t["t"]).length()
		var gs: Array = e["response"]["sentences"]
		var ps: Array = r["data"]["sentences"]
		sent_total += gs.size()
		var ptexts: Dictionary = {}
		for s in ps:
			ptexts[str(s["text"])] = true
		for s in gs:
			if ptexts.has(str(s["text"])):
				sent_ok += 1
	ok(total > 250, "golden has more than 250 word tokens (%d)" % total)
	ok(join_ok, "phone tokens and golden tokens both join back to each paragraph")
	lemma_rate = float(lemma_ok) / float(maxi(total, 1))
	level_rate = float(level_ok) / float(maxi(total, 1))
	print("  golden lemma match: %d/%d = %.2f%% (need >= %.0f%%)" % [lemma_ok, total, lemma_rate * 100.0, MIN_LEMMA * 100.0])
	print("  golden level match: %d/%d = %.2f%% (need >= %.0f%%)" % [level_ok, total, level_rate * 100.0, MIN_LEVEL * 100.0])
	print("  golden sentence match: %d/%d (information)" % [sent_ok, sent_total])
	ok(lemma_rate >= MIN_LEMMA, "lemma match rate >= 90%% (%.2f%%)" % (lemma_rate * 100.0))
	ok(level_rate >= MIN_LEVEL, "level match rate >= 85%% (%.2f%%)" % (level_rate * 100.0))
	ok(float(sent_ok) / float(maxi(sent_total, 1)) >= 0.8, "sentence text match >= 80%% (%d/%d)" % [sent_ok, sent_total])
	# the checker itself: compare against a golden whose lemmas are all wrong -> the rate must collapse
	var wrong: int = 0
	var wrong_total: int = 0
	for e in entries:
		var text2: String = str(e["text"])
		var r2: Dictionary = _analyze(text2)
		var by_off2: Dictionary = {}
		var off2: int = 0
		for t in r2["data"]["tokens"]:
			if bool(t["w"]):
				by_off2[off2] = t
			off2 += str(t["t"]).length()
		off2 = 0
		for t in e["response"]["tokens"]:
			if bool(t["w"]):
				wrong_total += 1
				var p2: Variant = by_off2.get(off2, null)
				if p2 != null and str(p2["lemma"]) == str(t["lemma"]) + "_x":
					wrong += 1
			off2 += str(t["t"]).length()
	ok(wrong_total > 0 and float(wrong) / float(wrong_total) < MIN_LEMMA, "checker: a golden with wrong lemmas gives a rate below 90%% (%d/%d)" % [wrong, wrong_total])
	_end("golden")


func _lemmas(text: String) -> Array:
	var out: Array = []
	var r: Dictionary = _analyze(text)
	if not bool(r["ok"]):
		return out
	for t in r["data"]["tokens"]:
		if bool(t["w"]):
			out.append(str(t["lemma"]))
	return out


func _test_lemma_cases() -> void:
	print("[lemma cases]")
	ok(_lemmas("She went home") == ["she", "go", "home"], "went -> go (%s)" % str(_lemmas("She went home")))
	ok(_lemmas("Children are running") == ["child", "be", "run"], "children / are / running (%s)" % str(_lemmas("Children are running")))
	ok(_lemmas("He studies and carries boxes") == ["he", "study", "and", "carry", "box"], "studies / carries / boxes (%s)" % str(_lemmas("He studies and carries boxes")))
	ok(_lemmas("I don't know") == ["i", "do", "not", "know"], "don't -> do + not (%s)" % str(_lemmas("I don't know")))
	ok(_lemmas("We'd go; they're here; I've won") == ["we", "would", "go", "they", "be", "here", "i", "have", "win"], "'d / 're / 've (%s)" % str(_lemmas("We'd go; they're here; I've won")))
	ok(_lemmas("It’s fine") == ["it", "be", "fine"], "curly apostrophe: It’s -> it + be (%s)" % str(_lemmas("It’s fine")))
	ok(_lemmas("Let's go") == ["let", "us", "go"], "let's -> let + us (%s)" % str(_lemmas("Let's go")))
	ok(_lemmas("The ship was quickly sailing") .size() == 5, "five word tokens in a simple sentence")
	var z: String = LocalReading.lemma_of("blorbing")
	ok(z != "" and z == z.to_lower(), "unknown word gets a lower-case lemma (%s)" % z)
	ok(LocalReading.lemma_of("zzzqqxx") == "zzzqqxx", "unknown word without a stem stays as it is")
	ok(LocalReading.lemma_of("RUNNING") == "run", "lemma_of ignores case")
	_end("lemma cases")


func _test_non_words() -> void:
	print("[non-words]")
	var r: Dictionary = _analyze("Visit https://example.com/a/b. Mail me at jo.kim@example.com or call 555 1234 at 7:45, 4% off.")
	var words: Array = _lemmas("Visit https://example.com/a/b. Mail me at jo.kim@example.com or call 555 1234 at 7:45, 4% off.")
	ok(not words.has("example") and not words.has("com") and not words.has("jo"), "URL and e-mail parts are not words (%s)" % str(words))
	ok(not words.has("555") and not words.has("45"), "numbers are not words")
	var txt: String = "Visit https://example.com/a/b. Mail me at jo.kim@example.com or call 555 1234 at 7:45, 4% off."
	ok(_joined(r["data"]["tokens"]) == txt, "tokens with URL / e-mail / numbers join back exactly")
	var w2: Array = _lemmas("Yesterday my friend Daniel visited Paris with Maria's sister.")
	ok(not w2.has("daniel") and not w2.has("paris") and not w2.has("maria"), "capitalised names inside a sentence are not words (%s)" % str(w2))
	ok(w2.has("yesterday") and w2.has("visit") and w2.has("sister"), "other words stay words (%s)" % str(w2))
	ok(not w2.has("be"), "possessive 's after a name is not a word")
	var w3: Array = _lemmas("Maria went home. Zorblax laughed.")
	ok(w3.has("go") and not w3.has("zorblax"), "unknown capitalised opener is a name (%s)" % str(w3))
	var w4: Array = _lemmas("\"Where is it?\" she asked.")
	ok(w4 == ["where", "be", "it", "she", "ask"], "opening quote keeps the sentence start (%s)" % str(w4))
	var w5: Array = _lemmas("NASA and the iPhone and OK")
	ok(w5 == ["and", "the", "and"], "all-caps and mixed-case words are not words (%s)" % str(w5))
	_end("non-words")


func _test_sentences() -> void:
	print("[sentences]")
	var r: Dictionary = _analyze("Dr. Smith met Mr. Lee at 3.5 today. He smiled.\nThey left! Why? Because it rained... then stopped.")
	var s: Array = r["data"]["sentences"]
	var texts: Array = []
	for x in s:
		texts.append(str(x["text"]))
	ok(texts[0] == "Dr. Smith met Mr. Lee at 3.5 today.", "no break after Dr. / Mr. / decimals (%s)" % str(texts))
	ok(texts.has("They left!") and texts.has("Why?"), "breaks after ! and ? (%s)" % str(texts))
	ok(texts.has("He smiled."), "line break ends a sentence (%s)" % str(texts))
	var last: String = texts[texts.size() - 1]
	ok(last.begins_with("Because it rained"), "a lower-case word after ... does not start a sentence (%s)" % last)
	var idx_ok: bool = true
	for k in range(s.size()):
		if int(s[k]["i"]) != k:
			idx_ok = false
	ok(idx_ok, "sentence indexes count 0, 1, 2 ...")
	var t_ok: bool = true
	var last_s: int = 0
	for t in r["data"]["tokens"]:
		if int(t["s"]) < last_s:
			t_ok = false
		last_s = int(t["s"])
	ok(t_ok, "token sentence numbers never go back")
	var one: Dictionary = _analyze("  \n Hello   world \n\n  ")
	ok(bool(one["ok"]) and (one["data"]["sentences"] as Array).size() == 1 and str(one["data"]["sentences"][0]["text"]) == "Hello   world", "leading / trailing blanks: one sentence, text stripped")
	ok(_joined(one["data"]["tokens"]) == "  \n Hello   world \n\n  ", "blanks are kept in the tokens")
	_end("sentences")


func _test_errors_and_ja() -> void:
	print("[errors, ja, size limit]")
	var r: Dictionary = _analyze("")
	ok(not bool(r["ok"]) and int(r["code"]) == 400 and str(r["err_code"]) == "bad_request" and str(r["error"]) == PC_EMPTY, "empty text -> 400 with the PC text")
	r = _analyze("   \n\t ")
	ok(not bool(r["ok"]) and str(r["error"]) == PC_EMPTY, "blank text -> the same message")
	r = _analyze(null)
	ok(not bool(r["ok"]) and str(r["error"]) == PC_EMPTY, "text null -> the same message")
	r = _analyze(12345)
	ok(not bool(r["ok"]) and str(r["error"]) == PC_EMPTY, "text not a string -> the same message")
	r = _analyze("hello", "fr")
	ok(not bool(r["ok"]) and int(r["code"]) == 400 and str(r["error"]) == "lang은 'en' 또는 'ja'여야 해요.", "lang fr -> PC text")
	r = _analyze("a ".repeat(10000))
	ok(bool(r["ok"]), "exactly 20000 characters is accepted")
	r = _analyze("a ".repeat(10000) + "a")
	ok(not bool(r["ok"]) and int(r["code"]) == 400 and str(r["err_code"]) == "bad_request", "20001 characters -> 400 bad_request")
	ok(str(r["error"]) == PC_LONG_20001, "20001 characters -> the PC text (%s)" % str(r["error"]))
	ok(LocalReading.too_long_msg(20001) == PC_LONG_20001, "too_long_msg(20001) == PC text")
	ok(str(r["err_body"]["error"]) == PC_LONG_20001 and str(r["err_body"]["via"]) == "phone", "err_body carries the text and via phone")
	var big: String = "x".repeat(30000)
	r = _analyze(big)
	ok(not bool(r["ok"]) and str(r["error"]) == "글이 너무 길어요. 20000자까지 한 번에 읽을 수 있어요(지금 30000자).", "30000 characters -> the count is in the text")
	# Japanese: limited handling (design 3.5(4) choice 1): err_code ja_reading_pc, no crash
	r = _analyze("私は学生です。", "ja")
	ok(not bool(r["ok"]) and str(r["err_code"]) == "ja_reading_pc", "lang ja -> err_code ja_reading_pc")
	ok(int(r["code"]) == 503 and str(r["error"]) == Route.text_for("ja_reading_pc") and str(r["error"]) != "", "ja: HTTP 503 and the Korean guidance text")
	ok(str(r["err_body"]["code"]) == "ja_reading_pc" and str(r["err_body"]["via"]) == "phone", "ja: err_body code and via")
	for t in ["", "   ", "食べました", "😀", "a".repeat(30000)]:
		var rj: Dictionary = _analyze(t, "ja")
		ok(not bool(rj["ok"]) and str(rj["err_code"]) == "ja_reading_pc", "ja with odd text (%d chars) still ja_reading_pc, no crash" % str(t).length())
	r = _analyze(null, "ja")
	ok(str(r["err_code"]) == "ja_reading_pc", "ja with null text does not crash")
	var rg: Dictionary = _gloss([{"lemma": "食べる", "sentence": "食べます"}], "ja")
	ok(bool(rg["ok"]), "ja gloss does not crash (%s)" % str(rg["err_code"]))
	var re: Dictionary = _examples("食べる", "", "ja")
	ok(bool(re["ok"]) or str(re["err_code"]) != "", "ja examples does not crash")
	_end("errors and ja")


func _test_odd_inputs() -> void:
	print("[odd inputs]")
	var cases: Array = [
		"!!!", "...", "\"\"", "'", "😀 hello 😀", "Hello 世界 world", "안녕하세요 hello", "tab\tseparated\r\nlines\r\nhere",
		"“Curly” ‘quotes’ and — dashes – here", "well-known state-of-the-art", "a'b'c o'clock rock'n'roll", "e.g. i.e. U.S.A.",
		"x".repeat(5000), "I", "'s", "n't", "A", "1234", "a@b", "http://", "www.", "café naïve", "Ünïcödé",
	]
	var all_join: bool = true
	var all_ok: bool = true
	for c in cases:
		var r: Dictionary = _analyze(c)
		if not bool(r["ok"]):
			if str(r["error"]) == "":
				all_ok = false
			continue
		if _joined(r["data"]["tokens"]) != c:
			all_join = false
			print("    join differs for: ", str(c).substr(0, 40))
	ok(all_ok, "no odd input fails without a message")
	ok(all_join, "tokens join back to every odd input exactly (%d cases)" % cases.size())
	var long_word: Dictionary = _analyze("x".repeat(5000))
	ok(bool(long_word["ok"]) and _word_tokens(long_word) == 1, "a 5000-letter word is one word token")
	var t0: int = Time.get_ticks_msec()
	var para: String = "The old lighthouse stood on the highest rock, looking over a restless grey sea. "
	var big: String = para.repeat(240)
	var rb: Dictionary = _analyze(big.substr(0, 20000))
	var ms: int = Time.get_ticks_msec() - t0
	print("  analyze 20000 characters: %d ms" % ms)
	ok(bool(rb["ok"]) and ms < 8000, "20000 characters analyse in < 8 s (%d ms)" % ms)
	ok(_joined(rb["data"]["tokens"]) == big.substr(0, 20000), "20000-character text joins back exactly")
	_end("odd inputs")


func _test_examples_real() -> void:
	print("[examples, shipped pack]")
	var r: Dictionary = _examples("run")
	ok(bool(r["ok"]) and int(r["code"]) == 200, "GET /examples?q=run is ok")
	var d: Dictionary = r["data"]
	ok((d["examples"] as Array).size() == 5, "default limit 5 (%d)" % (d["examples"] as Array).size())
	ok((d["degraded"] as Array).is_empty() and str(d["via"]) == "phone", "full answer has no degraded flag")
	var e0: Dictionary = d["examples"][0]
	ok(e0.has("id") and e0.has("text") and e0.has("ko") and e0.has("en") and e0.has("ja") and e0.has("url"), "example has id/text/ko/en/ja/url")
	ok(str(e0["ko"]) != "" and str(e0["url"]) == "https://tatoeba.org/sentences/show/%d" % int(e0["id"]), "ko present, url from id")
	ok(str(d["attribution"]).contains("Tatoeba"), "attribution is the Tatoeba text")
	var ids: Dictionary = {}
	var uniq: bool = true
	for e in d["examples"]:
		if ids.has(int(e["id"])):
			uniq = false
		ids[int(e["id"])] = true
	ok(uniq, "examples are unique")
	ok((_examples("run", "2")["data"]["examples"] as Array).size() == 2, "limit=2 -> 2 examples")
	ok((_examples("run", "0")["data"]["examples"] as Array).size() == 1, "limit=0 is raised to 1")
	ok((_examples("run", "99")["data"]["examples"] as Array).size() <= 20, "limit=99 is cut to 20")
	ok((_examples("RUN", "3")["data"]["examples"] as Array).size() == 3, "q is case-insensitive")
	var ran: Dictionary = _examples("ran", "3")
	ok(bool(ran["ok"]) and (ran["data"]["examples"] as Array).size() >= 1, "an inflected form finds sentences too")
	var none: Dictionary = _examples("zzzqqxx")
	ok(bool(none["ok"]) and (none["data"]["examples"] as Array).is_empty() and (none["data"]["degraded"] as Array) == ["examples_subset"], "unknown word -> empty list + examples_subset")
	var e1: Dictionary = _examples("")
	ok(not bool(e1["ok"]) and int(e1["code"]) == 400 and str(e1["error"]) == "찾을 단어(q)를 보내 주세요.", "empty q -> 400 PC text")
	var e2: Dictionary = _examples("x".repeat(61))
	ok(not bool(e2["ok"]) and str(e2["error"]) == "찾을 단어가 너무 길어요.", "61-character q -> 400 PC text")
	var e3: Dictionary = LocalReading.handle("GET", "/examples", {"lang": "xx", "q": "run"}, {})
	ok(not bool(e3["ok"]) and int(e3["code"]) == 400, "bad lang -> 400")
	var ja: Dictionary = _examples("あいつ", "", "ja")
	ok(bool(ja["ok"]) and (ja["data"]["examples"] as Array).size() >= 1 and str(ja["data"]["examples"][0]["ko"]) != "", "ja examples from examples_ja.json")
	_end("examples (shipped pack)")


func _test_dispatch() -> void:
	print("[LocalApi dispatch]")
	var before: int = LocalApi.served_count
	var r: Dictionary = await LocalApi.dispatch("POST", "/reading/analyze", {"lang": "en", "text": "The dogs are running."})
	ok(bool(r["ok"]) and str(r["data"]["via"]) == "phone", "dispatch POST /reading/analyze -> ok via phone")
	ok(LocalApi.served_count == before + 1, "served_count moved by one")
	var r2: Dictionary = await LocalApi.dispatch("POST", "/reading/analyze", {"lang": "ja", "text": "犬が走る"})
	ok(not bool(r2["ok"]) and str(r2["err_code"]) == "ja_reading_pc", "dispatch ja -> ja_reading_pc")
	var r3: Dictionary = await LocalApi.dispatch("GET", "/examples?lang=en&q=run&limit=2", {})
	ok(bool(r3["ok"]) and (r3["data"]["examples"] as Array).size() == 2, "dispatch GET /examples?lang=en&q=run&limit=2 -> 2 examples")
	var r4: Dictionary = await LocalApi.dispatch("POST", "/reading/gloss", {"lang": "en", "items": [{"lemma": "zzzqqxx", "sentence": ""}]})
	ok(bool(r4["ok"]) and (r4["data"]["degraded"] as Array) == ["gloss_partial"], "dispatch gloss of an unknown word -> ok, gloss_partial")
	ok(LocalApi.available("POST", "/reading/analyze"), "LocalApi.available(POST /reading/analyze) is true")
	_end("dispatch")


func _test_fixture_pack() -> void:
	print("[fixture pack: tables and mapping]")
	_use_pack(FIX)
	ok(LocalReading.is_available(), "fixture pack is available (hashes verified)")
	ok(LocalReading.lemma_of("running") == "run" and LocalReading.lemma_of("went") == "go", "forms table used (running -> run, went -> go)")
	ok(LocalReading.lemma_of("jumping") == "jump", "suffix rule: jumping -> jump (in the frequency table)")
	ok(LocalReading.lemma_of("dogs") == "dog", "suffix rule: dogs -> dog")
	ok(LocalReading.lemma_of("barked") == "barked", "suffix rule: no candidate in the table -> word itself")
	ok(is_equal_approx(LocalReading.zipf_of("run"), 5.0), "zipf is the table value / 10 (run = 5.0)")
	var r: Dictionary = _analyze("The dog jumped and the birds went running.")
	var lm: Array = []
	for t in r["data"]["tokens"]:
		if bool(t["w"]):
			lm.append(str(t["lemma"]))
	ok(lm == ["the", "dog", "jump", "and", "the", "bird", "go", "run"], "analyze on the fixture tables (%s)" % str(lm))
	_end("fixture pack")


func _test_gloss() -> void:
	print("[gloss]")
	_use_pack(FIX)
	var r: Dictionary = _gloss([{"lemma": "run", "sentence": "I run."}, {"lemma": "go", "sentence": "Go!"}])
	ok(bool(r["ok"]) and int(r["code"]) == 200, "gloss with words in the dictionary is ok")
	var d: Dictionary = r["data"]
	ok((d["degraded"] as Array).is_empty() and str(d["via"]) == "phone", "all found: degraded is empty")
	var gl: Array = d["glosses"]
	ok(gl.size() == 2 and str(gl[0]["lemma"]) == "run" and str(gl[0]["ko"]) == "달리다" and int(gl[0]["i"]) == 0, "run -> 달리다, i = 0")
	ok(str(gl[0]["pos"]) == "동사" and str(gl[0]["ipa"]) == "rʌn" and str(gl[0]["note"]) == "" and str(gl[0]["pron"]) == "", "pos / ipa / note / pron keys")
	ok(str(gl[1]["ko"]) == "가다" and str(gl[1]["ipa"]) == "ɡoʊ", "empty ipa in the gloss is filled from ipa_en.json")
	# partial: one word missing
	r = _gloss([{"lemma": "run", "sentence": ""}, {"lemma": "zzzqqxx", "sentence": ""}, {"lemma": "dog", "sentence": ""}])
	ok(bool(r["ok"]), "partial: still ok")
	ok((r["data"]["degraded"] as Array) == ["gloss_partial"], "partial: degraded == [gloss_partial]")
	gl = r["data"]["glosses"]
	ok(gl.size() == 2 and int(gl[0]["i"]) == 0 and int(gl[1]["i"]) == 2 and str(gl[1]["ko"]) == "개", "partial: found words keep their request index (0 and 2)")
	# all missing
	r = _gloss([{"lemma": "zzzqqxx"}, {"lemma": "qqzzxx"}])
	ok(bool(r["ok"]) and (r["data"]["glosses"] as Array).is_empty() and (r["data"]["degraded"] as Array) == ["gloss_partial"], "nothing found: ok, empty list, gloss_partial (no total failure)")
	# entry with an empty ko counts as missing
	r = _gloss([{"lemma": "empty"}])
	ok(bool(r["ok"]) and (r["data"]["glosses"] as Array).is_empty() and (r["data"]["degraded"] as Array) == ["gloss_partial"], "entry with empty ko is treated as missing")
	# inflected form and capitalised lemma
	r = _gloss([{"lemma": "running", "sentence": ""}, {"lemma": "Dog", "sentence": ""}, {"lemma": "children"}])
	ok((r["data"]["glosses"] as Array).size() == 3 and (r["data"]["degraded"] as Array).is_empty(), "inflected forms (running, children) and Dog are found through forms / lower case")
	ok(str(r["data"]["glosses"][0]["lemma"]) == "running" and str(r["data"]["glosses"][0]["ko"]) == "달리다", "the answer keeps the requested lemma text")
	# whitespace and empty lemma entries
	r = _gloss([{"lemma": "  run  "}, {"lemma": ""}, "junk", 7, null])
	ok(bool(r["ok"]) and (r["data"]["glosses"] as Array).size() == 1 and (r["data"]["degraded"] as Array).is_empty(), "blank / junk items are skipped, not counted as missing")
	# request errors
	r = _gloss([])
	ok(not bool(r["ok"]) and int(r["code"]) == 400 and str(r["error"]) == "뜻을 찾을 단어를 보내 주세요.", "empty items -> 400 PC text")
	r = _gloss("run")
	ok(not bool(r["ok"]) and str(r["error"]) == "뜻을 찾을 단어를 보내 주세요.", "items not a list -> 400")
	r = _gloss([{"lemma": ""}, {"lemma": "  "}])
	ok(not bool(r["ok"]) and str(r["error"]) == "뜻을 찾을 단어를 보내 주세요.", "only empty lemmas -> 400")
	var many: Array = []
	for i in range(31):
		many.append({"lemma": "run"})
	r = _gloss(many)
	ok(not bool(r["ok"]) and int(r["code"]) == 400 and str(r["error"]) == "한 번에 30개까지 뜻을 찾을 수 있어요.", "31 items -> 400 PC text")
	many.pop_back()
	r = _gloss(many)
	ok(bool(r["ok"]) and (r["data"]["glosses"] as Array).size() == 30, "30 items are accepted")
	r = _gloss([{"lemma": "run"}], "xx")
	ok(not bool(r["ok"]) and int(r["code"]) == 400, "bad lang -> 400")
	# ja dictionary
	r = _gloss([{"lemma": "食べる", "sentence": "食べます"}, {"lemma": "走る", "sentence": ""}], "ja")
	ok(bool(r["ok"]) and (r["data"]["glosses"] as Array).size() == 1 and str(r["data"]["glosses"][0]["ko"]) == "먹다" and str(r["data"]["glosses"][0]["ipa"]) == "たべる", "ja: found word has ko and the hiragana reading")
	ok((r["data"]["degraded"] as Array) == ["gloss_partial"], "ja: a missing word -> gloss_partial")
	# gloss file absent (manifest lists no gloss file): same partial answer, never a failure
	_use_pack(FIX_EMPTY)
	r = _gloss([{"lemma": "run"}, {"lemma": "go"}])
	ok(bool(r["ok"]) and int(r["code"]) == 200, "gloss file absent: ok 200, not a failure")
	ok((r["data"]["glosses"] as Array).is_empty() and (r["data"]["degraded"] as Array) == ["gloss_partial"], "gloss file absent: empty glosses + gloss_partial")
	r = _gloss([{"lemma": "食べる"}], "ja")
	ok(bool(r["ok"]) and (r["data"]["degraded"] as Array) == ["gloss_partial"], "gloss_ja.json absent: gloss_partial")
	r = _gloss([])
	ok(not bool(r["ok"]) and int(r["code"]) == 400, "gloss file absent: a bad request is still a 400")
	# the shipped pack (gloss_en.json may or may not exist yet): never a failure, and partial for a nonsense word
	_use_pack(PackLoader.DEFAULT_DIR)
	r = _gloss([{"lemma": "zzzqqxx", "sentence": ""}])
	ok(bool(r["ok"]) and (r["data"]["degraded"] as Array) == ["gloss_partial"] and (r["data"]["glosses"] as Array).is_empty(), "shipped pack: nonsense word -> ok, partial")
	_end("gloss")


func _test_examples_fixture() -> void:
	print("[examples, fixture pack]")
	_use_pack(FIX)
	var r: Dictionary = _examples("run", "2")
	ok(bool(r["ok"]) and (r["data"]["examples"] as Array).size() == 2, "fixture: run, limit 2 -> 2 examples")
	ok(str(r["data"]["attribution"]) == "fixture attribution", "attribution is taken from the file")
	ok((r["data"]["degraded"] as Array).is_empty(), "limit reached -> no degraded flag")
	ok(int(r["data"]["examples"][0]["id"]) == 1 and str(r["data"]["examples"][0]["text"]) == "I run every morning." and str(r["data"]["examples"][0]["ko"]) == "나는 매일 아침 달린다.", "first example is the first id of the index")
	r = _examples("run", "5")
	ok((r["data"]["examples"] as Array).size() == 3 and (r["data"]["degraded"] as Array) == ["examples_subset"], "fewer than limit -> examples_subset")
	r = _examples("bird")
	ok((r["data"]["examples"] as Array).size() == 1 and str(r["data"]["examples"][0]["text"]) == "A bird sings.", "not in the index: whole-word text search finds it")
	r = _examples("bir")
	ok((r["data"]["examples"] as Array).is_empty(), "text search is whole-word only (bir does not match bird)")
	r = _examples("BIRD")
	ok((r["data"]["examples"] as Array).size() == 1, "text search ignores case")
	r = _examples("a.b(c")
	ok(bool(r["ok"]) and (r["data"]["examples"] as Array).is_empty(), "regex characters in q are escaped (no crash)")
	_use_pack(FIX_EMPTY)
	r = _examples("run")
	ok(not bool(r["ok"]) and str(r["err_code"]) == "pack_missing" and int(r["code"]) == 503, "examples file absent -> pack_missing 503")
	_end("examples (fixture)")


func _test_bad_and_empty_packs() -> void:
	print("[corrupt and missing packs]")
	_use_pack(FIX_BAD)
	ok(not LocalReading.is_available(), "corrupt reading_en.json: is_available false")
	ok(str(LocalReading.unavailable_reason()["err_code"]) == "pack_corrupt" and str(LocalReading.unavailable_reason()["text_ko"]) != "", "unavailable_reason: pack_corrupt with text")
	var r: Dictionary = _analyze("Hello world")
	ok(not bool(r["ok"]) and str(r["err_code"]) == "pack_corrupt" and int(r["code"]) == 503, "analyze with a corrupt pack -> pack_corrupt 503, no crash")
	r = _gloss([{"lemma": "run"}])
	ok(bool(r["ok"]) and (r["data"]["degraded"] as Array) == ["gloss_partial"], "corrupt gloss file -> ok + gloss_partial")
	_use_pack(FIX_EMPTY)
	ok(not LocalReading.is_available() and str(LocalReading.unavailable_reason()["err_code"]) == "pack_missing", "no reading_en.json in the manifest -> pack_missing")
	r = _analyze("Hello world")
	ok(not bool(r["ok"]) and str(r["err_code"]) == "pack_missing", "analyze without the pack -> pack_missing")
	r = _analyze("Hello", "ja")
	ok(str(r["err_code"]) == "ja_reading_pc", "ja is answered before the pack is needed")
	_use_pack(PackLoader.DEFAULT_DIR)
	ok(LocalReading.is_available(), "back on the shipped pack: available again")
	r = _analyze("Hello world")
	ok(bool(r["ok"]), "back on the shipped pack: analyze works again")
	_end("corrupt and missing packs")
