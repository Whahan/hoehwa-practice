extends Node
## Headless test of the 읽기 (reading) tab, driven by fixture JSON (no backend needed):
##   godot --headless --path <project> res://tests/reading_test.tscn
## Optional live check against a running backend (needs /reading/* and "tatoeba" in /health):
##   godot --headless --path <project> res://tests/reading_test.tscn -- --api=http://127.0.0.1:8786
## Exit code 0 = all checks passed.

const DIR := "user://test_reading"
const PROGRESS := "user://test_reading_progress.json"

var passed: int = 0
var failed: int = 0
var rv: ReadingView


func _ready() -> void:
	print("== reading test start ==")
	_cleanup()
	Store.progress_path = PROGRESS
	Store.progress = Progress.blank()
	var holder := Control.new()
	holder.size = Vector2(1280, 760)
	add_child(holder)
	rv = ReadingView.new()
	rv.storage_dir = DIR
	rv.auto_fetch = false
	holder.add_child(rv)
	await _frames(2)

	_test_progress_compat()
	await _test_library()
	await _test_english()
	await _test_japanese()
	await _test_narrow()
	_test_errors()
	await _test_live()

	print("== reading result: %d passed, %d failed ==" % [passed, failed])
	_cleanup()
	get_tree().quit(1 if failed > 0 else 0)


func ok(cond: bool, name: String) -> void:
	if cond:
		passed += 1
		print("  PASS  ", name)
	else:
		failed += 1
		print("  FAIL  ", name)


func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


static func fixture(name: String) -> Variant:
	return JSON.parse_string(FileAccess.get_file_as_string("res://tests/" + name))


func _cleanup() -> void:
	for d in [DIR.path_join("cache"), DIR]:
		if DirAccess.dir_exists_absolute(d):
			for f in DirAccess.get_files_at(d):
				DirAccess.remove_absolute(ProjectSettings.globalize_path(d.path_join(f)))
			DirAccess.remove_absolute(ProjectSettings.globalize_path(d))
	if FileAccess.file_exists(PROGRESS):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(PROGRESS))


static func joined(tokens: Array) -> String:
	var parts := PackedStringArray()
	for t in tokens:
		parts.append(str((t as Dictionary)["t"]))
	return "".join(parts)


func token_index(surface: String, from: int = 0) -> int:
	for i in range(from, rv.tokens.size()):
		if str((rv.tokens[i] as Dictionary)["t"]) == surface:
			return i
	return -1


## Finds a Button with exactly this text under `root`.
func find_button(root: Node, text: String) -> Button:
	for n in root.get_children():
		if n is Button and (n as Button).text == text:
			return n
		var r: Button = find_button(n, text)
		if r != null:
			return r
	return null


func has_text(root: Node, needle: String) -> bool:
	for n in root.get_children():
		if (n is Label or n is Button) and str(n.text).find(needle) >= 0:
			return true
		if n is RichTextLabel and (n as RichTextLabel).get_parsed_text().find(needle) >= 0:
			return true
		if has_text(n, needle):
			return true
	return false


# ---------------------------------------------------------------- progress compatibility

func _test_progress_compat() -> void:
	print("[progress known_words]")
	var old: Dictionary = Progress.normalize({"start": "2026-11-01", "review": [{"lang": "en", "target": "Hi", "ko": "안녕"}]})
	ok(old["known_words"] is Dictionary and (old["known_words"]["en"] as Array).is_empty() and (old["known_words"]["ja"] as Array).is_empty(), "old progress file (no known_words) loads with empty sets")
	var messy: Dictionary = Progress.normalize({"known_words": {"en": ["run", "run", " ", 5, "walk"], "ja": "x", "fr": ["a"]}})
	ok(messy["known_words"]["en"] == ["run", "walk"] and (messy["known_words"]["ja"] as Array).is_empty() and not (messy["known_words"] as Dictionary).has("fr"), "normalize() cleans known_words: %s" % str(messy["known_words"]))
	ok(Progress.blank().has("known_words"), "blank() has known_words")


# ---------------------------------------------------------------- library

func _test_library() -> void:
	print("[library]")
	rv.lang = "en"
	rv.mode = "library"
	rv._render()
	await _frames(1)
	ok(rv._te != null and rv._analyze_btn != null and rv._analyze_btn.disabled, "library shows the paste box; 분석하기 disabled while empty")
	rv._te.text = "Hello world."
	rv._te.text_changed.emit()
	ok(not rv._analyze_btn.disabled and rv._draft_text == "Hello world.", "typing enables 분석하기")
	var d1: Dictionary = rv.new_doc("", "en", "First line title\nbody text")
	ok(d1["title"] == "First line title", "untitled doc takes its first line as title")
	d1["opened"] = 100
	rv.save_doc(d1)
	var d2: Dictionary = rv.new_doc("Second", "en", "two")
	d2["opened"] = 200
	rv.save_doc(d2)
	var d3: Dictionary = rv.new_doc("日本語", "ja", "にほんご")
	rv.save_doc(d3)
	var en_docs: Array = rv.list_docs("en")
	ok(en_docs.size() == 2 and en_docs[0]["title"] == "Second", "list_docs filters by language, newest first")
	rv._render_library()
	await _frames(1)
	ok(has_text(rv._lib_page.content, "Second") and has_text(rv._lib_page.content, "First line title"), "saved texts listed in the library")
	# delete with the in-app confirm
	var del: Button = null
	for b in _all_buttons(rv._lib_page.content):
		if b.text == "삭제":
			del = b
			break
	del.pressed.emit()
	await _frames(1)
	var yes: Button = find_button(rv._lib_page.content, "지우기")
	ok(yes != null and has_text(rv._lib_page.content, "정말 지울까요?"), "삭제 asks for confirmation in the app")
	yes.pressed.emit()
	await _frames(1)
	ok(rv.list_docs("en").size() == 1, "confirmed delete removes the file")
	rv.delete_doc(str(rv.list_docs("en")[0]["id"]))
	rv.delete_doc(str(d3["id"]))
	ok(rv.list_docs("en").is_empty() and rv.list_docs("ja").is_empty(), "delete_doc cleans up")


func _all_buttons(root: Node) -> Array:
	var out: Array = []
	for n in root.get_children():
		if n is Button:
			out.append(n)
		out.append_array(_all_buttons(n))
	return out


# ---------------------------------------------------------------- English reader

func _test_english() -> void:
	print("[english reader]")
	var data: Dictionary = fixture("sample_reading_analyze.json")
	var text: String = joined(data["tokens"])
	rv.lang = "en"
	rv._draft_title = "Running in the Rain"
	rv._draft_text = text
	rv.analyze_draft()
	ok(rv.mode == "reader" and rv.analyzing, "분석하기 saves the text and opens the reader (analyzing)")
	ok(rv.list_docs("en").size() == 1 and rv.list_docs("en")[0]["text"] == text, "pasted text saved as user://…/<id>.json")
	ok(rv.set_analysis(data), "fixture analysis accepted")
	await _frames(2)
	var parsed: String = rv._rtl.get_parsed_text()
	ok(parsed == text, "rendered text round-trips the original (incl. '[' and newlines)")
	if parsed != text:
		print("    got: ", parsed.c_escape().left(200))
	ok(rv.lemmas.size() == (data["words"] as Array).size(), "one entry per lemma (%d)" % rv.lemmas.size())
	var bb: String = rv.build_bbcode()
	var i_reck: int = token_index("reckless")
	var i_run: int = token_index("Running")
	ok(bb.find("[url=%d][bgcolor=" % i_reck) >= 0, "hard new word 'reckless' gets the accent background")
	ok(bb.find("[url=%d]Running[/url]" % i_run) >= 0, "easy word 'Running' stays plain but clickable")
	ok(bb.find("Maya") >= 0 and bb.find("]Maya") < 0, "proper noun (w:false) is not a link")
	var c: Dictionary = rv.counts()
	ok(c["new"] > 0 and c["learning"] == 0 and c["known"] == 0, "counters: %s" % str(c))
	ok(has_text(rv._head, "새 단어 %d" % c["new"]), "legend shows '새 단어 %d'" % c["new"])

	# click -> lemma
	rv.on_meta_clicked(str(i_run))
	await _frames(2)
	ok(rv.selected == i_run and rv.selected_word()["lemma"] == "run", "clicking 'Running' resolves lemma 'run'")
	ok(has_text(rv._panel_body, "본문에서는 Running"), "panel shows the surface form")
	ok(find_button(rv._panel_body, "뜻 불러오기") != null, "missing meaning offers '뜻 불러오기'")
	var i_was: int = token_index("was")
	rv.on_meta_clicked(str(i_was))
	ok(rv.selected_word()["lemma"] == "be", "clicking 'was' resolves lemma 'be'")
	rv.on_meta_clicked(str(token_index(" ")))
	ok(rv.selected == i_was, "clicking a space/punctuation token does nothing")
	rv.on_meta_clicked("abc")
	ok(rv.selected == i_was, "bad meta is ignored")

	# glosses arrive
	var n: int = rv.apply_glosses(fixture("sample_reading_gloss.json"))
	ok(n == 8, "8 glosses cached")
	ok(FileAccess.file_exists(DIR.path_join("glosses_en.json")), "gloss cache file written")
	rv.glosses.clear()
	ok(str(rv.gloss_for("reckless").get("ko", "")) == "무모한", "gloss cache reloads from disk")
	rv.on_meta_clicked(str(i_reck))
	await _frames(2)
	ok(has_text(rv._panel_body, "무모한") and has_text(rv._panel_body, "/ˈrɛkləs/"), "panel shows meaning + IPA")
	var sent: String = "Her neighbours thought she was reckless [or maybe brave]."
	ok(rv.selected_word()["sentence"] == sent, "word's sentence resolved")
	ok(has_text(rv._panel_body, sent), "panel shows the sentence (bbcode-escaped)")
	ok(find_button(rv._panel_body, "▶ 듣기") != null and find_button(rv._panel_body, "천천히") != null and find_button(rv._panel_body, "문장 듣기") != null, "듣기 / 천천히 / 문장 듣기 buttons")

	# examples
	rv.set_examples("reckless", fixture("sample_examples.json"))
	await _frames(1)
	ok(has_text(rv._panel_body, "I run every morning.") and has_text(rv._panel_body, "Don't run in the hallway [please].") and not has_text(rv._panel_body, "He ran away."), "up to 3 Tatoeba examples shown")
	ok(has_text(rv._panel_body, "나는 매일 아침 달린다.") and has_text(rv._panel_body, "彼女はバスに乗るために走っていた。"), "example translations (ko, else other language)")
	ok(has_text(rv._panel_body, "CC BY 2.0 FR"), "Tatoeba attribution under the examples")

	# add to review -> FSRS card
	var add: Button = find_button(rv._panel_body, "복습에 추가")
	ok(add != null, "'복습에 추가' button present")
	add.pressed.emit()
	await _frames(1)
	var items: Array = Store.review_for("en")
	ok(items.size() == 1, "review item created")
	if items.size() == 1:
		var it: Dictionary = items[0]
		ok(it["target"] == "reckless" and it["ko"] == "무모한" and it["note"] == sent and it["reading"] == "", "review item = {target: lemma, ko: meaning, note: sentence}")
		ok(it.has("due") and it.has("stability") and int(it["state"]) == FSRS.State.LEARNING and int(it["reps"]) == 0 and FSRS.is_new(it), "review item is a new FSRS card")
		ok(Store.due_for("en").size() == 1, "new card is due now")
	ok(rv.word_status("reckless") == "learning", "status -> learning (복습 중)")
	ok(rv.build_bbcode().find("[u]reckless[/u]") >= 0 or rv.selected == i_reck, "learning word underlined")
	rv.close_panel()
	ok(rv.build_bbcode().find("[u]reckless[/u]") >= 0, "learning word is underlined with amber tint")
	ok(rv.counts()["learning"] == 1, "counter 복습 중 = 1")

	# add before gloss arrives -> backfilled
	rv.on_meta_clicked(str(token_index("grey")))
	rv.add_selected_to_review()
	ok(str(_review_item("en", "grey").get("ko", "x")) == "", "word added before its meaning has empty ko")
	rv.apply_glosses({"glosses": [{"lemma": "grey", "pos": "형용사", "ko": "회색의", "ipa": "/ɡreɪ/", "note": ""}]})
	ok(str(_review_item("en", "grey").get("ko", "")) == "회색의", "meaning arriving later fills the review item")

	# known words persistence
	var i_untangle: int = token_index("untangle")
	rv.on_meta_clicked(str(i_untangle))
	await _frames(1)
	find_button(rv._panel_body, "아는 단어").pressed.emit()
	await _frames(1)
	ok(find_button(rv._panel_body, "모르는 단어로 되돌리기") != null, "known word offers '모르는 단어로 되돌리기'")
	rv.selected = -1
	ok(rv.word_status("untangle") == "known" and rv.build_bbcode().find("[url=%d]untangle[/url]" % i_untangle) >= 0, "아는 단어 -> plain text")
	rv.select_token(i_untangle)
	Store.load_progress()
	ok(Store.is_known("en", "untangle") and not Store.is_known("ja", "untangle"), "known word persisted per language (save/load)")
	var raw: Variant = JSON.parse_string(FileAccess.get_file_as_string(PROGRESS))
	ok(raw is Dictionary and (raw["known_words"]["en"] as Array).has("untangle"), "progress.json has known_words.en")
	rv._refresh_sets()
	find_button(rv._panel_body, "모르는 단어로 되돌리기").pressed.emit()
	await _frames(1)
	Store.load_progress()
	ok(not Store.is_known("en", "untangle") and rv.word_status("untangle") == "new", "되돌리기 removes it (persisted)")

	# bulk actions with confirm
	var easy_n: int = rv.bulk_keys("easy").size()
	ok(easy_n > 10, "%d easy lemmas" % easy_n)
	var b_easy: Button = find_button(rv._head, "쉬운 단어 모두 아는 단어로")
	b_easy.pressed.emit()
	await _frames(1)
	ok(rv._confirm_bulk == "easy" and find_button(rv._head, "표시하기") != null, "bulk action asks for confirmation")
	find_button(rv._head, "표시하기").pressed.emit()
	await _frames(1)
	ok(rv.counts()["known"] == easy_n and rv.counts()["easy"] == 0, "easy words marked known (%d)" % easy_n)
	var new_left: int = rv.counts()["new"]
	rv.mark_bulk_known("all")
	ok(rv.counts()["new"] == 0 and rv.counts()["known"] == easy_n + new_left and rv.counts()["learning"] == 2, "remaining new words marked known; review words untouched")
	Store.load_progress()
	ok((Store.progress["known_words"]["en"] as Array).size() == easy_n + new_left, "bulk known words persisted")

	# re-open: analysis cached, glosses instant
	var docs: Array = rv.list_docs("en")
	rv.back_to_library()
	ok(rv.mode == "library", "back to library")
	rv.glosses.clear()
	rv.open_doc(docs[0])
	ok(rv.mode == "reader" and not rv.analyzing and rv.tokens.size() == (data["tokens"] as Array).size(), "re-opening uses the cached analysis (no request)")
	ok(not rv.gloss_for("dissolve").is_empty(), "re-opening has glosses from the cache file")

	# font size
	Store.prefs["reading_font"] = "l"
	rv._render_text()
	ok(rv._rtl.get_theme_font_size("normal_font_size") == 24, "font size large = 24")
	Store.prefs.erase("reading_font")
	rv._render_text()


func _review_item(l: String, target: String) -> Dictionary:
	for r in Store.review_for(l):
		if (r as Dictionary)["target"] == target:
			return r
	return {}


# ---------------------------------------------------------------- Japanese reader

func _test_japanese() -> void:
	print("[japanese reader]")
	var data: Dictionary = fixture("sample_reading_analyze_ja.json")
	var text: String = joined(data["tokens"])
	var d: Dictionary = rv.new_doc("", "ja", text)
	rv.save_doc(d)
	rv.open_doc(d)
	ok(rv.lang == "ja" and rv.analyzing, "japanese doc opens (lang ja)")
	ok(rv.set_analysis(data), "japanese fixture accepted")
	await _frames(2)
	ok(rv._rtl.get_parsed_text() == text, "japanese text round-trips")
	ok(rv._rtl.get_theme_font("normal_font") == UI.ja_font(false), "japanese text uses the Japanese font")
	var i_tabe: int = token_index("食べ")
	rv.on_meta_clicked(str(i_tabe))
	await _frames(1)
	ok(rv.selected_word()["lemma"] == "食べる" and rv.selected_word()["sentence"] == "朝ごはんを食べてから、駅まで歩きました。", "clicking 食べ resolves 食べる + its sentence")
	ok(rv.build_bbcode().find("[bgcolor=#%s]" % Pal.JA.to_html(false)) >= 0, "selected word uses the Japanese accent")
	rv.apply_glosses(fixture("sample_reading_gloss_ja.json"))
	await _frames(1)
	ok(has_text(rv._panel_body, "먹다") and has_text(rv._panel_body, "たべる"), "japanese panel shows meaning + reading")
	rv.add_selected_to_review()
	var it: Dictionary = _review_item("ja", "食べる")
	ok(it.get("reading", "") == "たべる" and it.get("ko", "") == "먹다", "japanese review item carries the hiragana reading")
	ok(rv.word_status("傘") == "new" and rv.word_status("は") == "easy", "japanese statuses (傘 new, は easy)")
	ok(not Store.is_known("en", "傘") and rv.counts()["learning"] == 1, "known/learning sets are per language")
	var hl: String = rv._highlight("私は毎日パンを食べます。", rv.selected_word())
	ok(hl.find("[b][color=") >= 0 and hl.find("食べ") >= 0, "conjugated form highlighted in a Japanese example")


# ---------------------------------------------------------------- narrow window

func _test_narrow() -> void:
	print("[layout]")
	var holder: Control = rv.get_parent()
	holder.size = Vector2(1280, 760)
	await _frames(2)
	ok(not rv._split.vertical and rv._panel.visible, "wide window: side panel on the right")
	holder.size = Vector2(900, 700)
	await _frames(2)
	ok(rv._split.vertical, "narrow window: bottom sheet")
	rv.close_panel()
	ok(not rv._panel.visible, "narrow + nothing selected: sheet hidden")
	rv.select_token(token_index("傘"))
	ok(rv._panel.visible, "narrow + word selected: sheet shown")
	holder.size = Vector2(1280, 760)
	await _frames(1)


# ---------------------------------------------------------------- errors

func _test_errors() -> void:
	print("[errors]")
	ok(ReadingView.error_text({"code": 404, "error": "서버에서 오류가 났어요. (코드 404)"}) == ReadingView.MISSING_MSG, "404 -> '%s'" % ReadingView.MISSING_MSG)
	ok(ReadingView.error_text({"code": 400, "error": "글이 비어 있어요."}) == "글이 비어 있어요.", "backend Korean error passed through")
	ok(not rv.set_analysis({"tokens": "nope"}) and not rv.set_analysis(null), "malformed analysis rejected")
	ok(rv.apply_glosses({"glosses": [{"lemma": "", "ko": "x"}, {"lemma": "a", "ko": ""}, 3]}) == 0, "malformed glosses ignored")


# ---------------------------------------------------------------- live backend (optional)

func _test_live() -> void:
	print("[live backend]")
	if not Api.base_overridden:
		print("  SKIP  no --api=... given")
		return
	var h = Api.get_json("/health", 5.0, false)
	var hr: Dictionary = await h.wait()
	if not hr["ok"]:
		print("  SKIP  backend not reachable at %s" % Api.base_url)
		return
	print("  health: ", hr["data"])
	ok((hr["data"] as Dictionary).has("tatoeba"), "/health has 'tatoeba'")
	for l in ["en", "ja"]:
		var text: String = "She kept running anyway, although the stubborn rain refused to stop." if l == "en" else "昨日は雨が降っていたので、傘を持って行きました。"
		var a = Api.post_json("/reading/analyze", {"lang": l, "text": text}, 120.0, false)
		var ar: Dictionary = await a.wait()
		ok(ar["ok"] and ar["data"] is Dictionary, "POST /reading/analyze %s %s" % [l, "" if ar["ok"] else ar["error"]])
		if not ar["ok"]:
			continue
		ok(joined(ar["data"]["tokens"]) == text, "%s tokens join back to the text" % l)
		var d: Dictionary = rv.new_doc("live", l, text)
		rv.save_doc(d)
		rv.open_doc(d)
		ok(rv.set_analysis(ar["data"]), "%s live analysis renders" % l)
		await _frames(2)
		ok(rv._rtl.get_parsed_text() == text, "%s live text round-trips in the RichTextLabel" % l)
		var key: String = ""
		for k in rv.lemmas.keys():
			if rv.word_status(k) == "new":
				key = k
				break
		if key == "":
			key = rv.lemmas.keys()[0]
		var info: Dictionary = rv.lemmas[key]
		print("    word: ", info)
		var g = Api.post_json("/reading/gloss", {"lang": l, "items": [{"lemma": info["lemma"], "sentence": rv.sentence_text(int(info["s"]))}]}, Api.TIMEOUT_LLM, false)
		var gr: Dictionary = await g.wait()
		ok(gr["ok"] and rv.apply_glosses(gr["data"], l) >= 1, "POST /reading/gloss %s -> %s" % [l, str(gr["data"]) if gr["ok"] else gr["error"]])
		var e = Api.get_json("/examples?lang=%s&q=%s&limit=5" % [l, str(info["lemma"]).uri_encode()], 30.0, false)
		var er: Dictionary = await e.wait()
		ok(er["ok"] and er["data"] is Dictionary and (er["data"] as Dictionary).get("examples", null) is Array and str((er["data"] as Dictionary).get("attribution", "")) != "", "GET /examples %s q=%s -> %d examples" % [l, info["lemma"], ((er["data"] as Dictionary).get("examples", []) as Array).size() if er["ok"] else -1])
		if er["ok"]:
			rv.select_token(int(info["tok"]))
			rv.set_examples(key, er["data"])
			await _frames(1)
			ok(has_text(rv._panel_body, "Tatoeba"), "%s live examples render with attribution" % l)
