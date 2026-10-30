extends Node
## U4b: 노래 학습 화면의 탭 위젯 4개 — SongWordsTab · SongClozeTab · SongDictationTab · SongMeaningTab
## (docs/song_study_design.md 5.4, 6, 8 U-11 ~ U-13, 12.1b).
##   godot --headless --path <project> res://tests/song_tabs_test.tscn            (PC 모양)
##   godot --headless --path <project> --resolution 412x915 res://tests/song_tabs_test.tscn -- --phone   (폰 모양)
## Exit code 0 = all checks passed. Last line: "== song_tabs_test result: N passed, 0 failed ==".
## 서버 · 네트워크 없음: /song/enrich 는 SpeakDrill.api_hook(가짜 응답)으로 가로챈다. 가사는 모두 이 파일에서 직접 쓴 문장이다.
## 진행 기록 · 학습 기록 · 곡 저장소는 user://test_* 로 돌리고 끝에 되돌린다 (실제 사용자 폴더는 건드리지 않는다).

const TEST_PROGRESS := "user://song_tabs_test_progress.json"
const TEST_LOG := "user://song_tabs_test_studylog.json"
const TEST_SONGS := "user://test_songs_u4b"
const SECTIONS := ["words_en", "words_ja", "cloze_en", "cloze_ja", "dictation_en", "dictation_ja", "events", "meaning_rules", "meaning_request", "meaning_errors", "meaning_view", "pc_rule", "layout"]

var passed: int = 0
var failed: int = 0
var reached: Dictionary = {}
var requests: Array = []
var enrich_mode: String = "ok" ## ok | fail | fail2 | garbage | slow
var tts_calls: Array = []
var phone: bool = false

var _saved_prefs: Dictionary = {}
var _saved_progress: Dictionary = {}
var _saved_progress_path: String = ""
var _saved_log_path: String = ""
var _saved_base: String = ""
var _saved_root: String = ""
var _saved_route_mode: String = ""
var _gate_open: bool = false

signal gate


## 가짜 SongPlayer: 부른 것만 기록한다.
class FakePlayer:
	extends Node
	var played: Array = []
	var paused: int = 0

	func play_line(i: int, repeat: int = 1) -> void:
		played.append([i, repeat])

	func pause() -> void:
		paused += 1


func ok(cond: bool, name: String) -> void:
	if cond:
		passed += 1
		print("  PASS  ", name)
	else:
		failed += 1
		print("  FAIL  ", name)


func _ready() -> void:
	phone = Platform.is_phone()
	print("== song_tabs_test start (%s) ==" % ("phone" if phone else "pc"))
	_setup()
	await _run()
	_teardown()
	ok(not DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(TEST_SONGS)) and not FileAccess.file_exists(TEST_PROGRESS) and not FileAccess.file_exists(TEST_LOG), "cleanup: test song folder / progress / study log files removed")
	for s in SECTIONS:
		ok(reached.has(s), "section '%s' ran to its end" % s)
	print("== song_tabs_test result: %d passed, %d failed ==" % [passed, failed])
	get_tree().quit(1 if failed > 0 else 0)


# ---------------------------------------------------------------- setup

func _setup() -> void:
	_saved_prefs = Store.prefs.duplicate(true)
	_saved_progress = Store.progress.duplicate(true)
	_saved_progress_path = Store.progress_path
	_saved_log_path = StudyLog.path
	_saved_base = Api.base_url
	_saved_root = SongStore.root
	_saved_route_mode = Route.mode
	Store.progress_path = TEST_PROGRESS
	Store.progress = Progress.blank()
	StudyLog.path = TEST_LOG
	StudyLog.load_from_disk()
	StudyLog.reset()
	SongStore.root = TEST_SONGS
	Store.prefs["lang"] = "en"
	Store.prefs["show_reading"] = true
	Store.prefs["show_hangul_ja"] = true
	Store.prefs["song_consent"] = false
	Store.prefs.erase("song_translate")
	Api.base_url = "http://127.0.0.1:9" # 닫힌 포트: 실수로 서버에 닿지 않게
	SpeakDrill.api_hook = Callable(self, "_hook")
	Tts.fetch_hook = Callable(self, "_tts_hook")
	SongMeaningTab.pc_hook = Callable(self, "_pc_yes")


func _teardown() -> void:
	SpeakDrill.api_hook = Callable()
	Tts.fetch_hook = Callable()
	SongMeaningTab.pc_hook = Callable()
	Route.pc_ready_hook = Callable()
	Route.phone_hook = Callable()
	Route.mode = _saved_route_mode
	Tts.stop()
	StudyLog.reset()
	StudyLog.path = _saved_log_path
	Store.progress_path = _saved_progress_path
	Store.progress = _saved_progress
	Api.base_url = _saved_base
	_rm_dir(TEST_SONGS)
	SongStore.root = _saved_root
	for f in [TEST_PROGRESS, TEST_LOG, TEST_LOG + ".bad"]:
		if FileAccess.file_exists(f):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(f))
	Store.prefs = _saved_prefs
	Store.save_prefs()


func _rm_dir(path: String) -> void:
	var g: String = ProjectSettings.globalize_path(path)
	if not DirAccess.dir_exists_absolute(g):
		return
	var d := DirAccess.open(g)
	if d == null:
		return
	for sub in d.get_directories():
		_rm_dir(path.path_join(sub))
	for f in d.get_files():
		DirAccess.remove_absolute(g.path_join(f))
	DirAccess.remove_absolute(g)


func _pc_yes() -> bool:
	return true


func _pc_no() -> bool:
	return false


func _tts_hook(text: String, l: String, speed: float, _voice: String) -> Variant:
	tts_calls.append({"text": text, "lang": l, "speed": speed})
	return null


## /song/enrich 의 가짜 서버. 요청마다 줄 i 에 "번역 <i>" 을 돌려준다.
func _hook(method: String, path: String, body: Variant) -> Variant:
	requests.append({"method": method, "path": path, "body": body})
	if path != "/song/enrich":
		return {"ok": false, "code": 404, "data": null, "error": "알 수 없는 경로예요."}
	var n_enrich := 0
	for r in requests:
		if str((r as Dictionary)["path"]) == "/song/enrich":
			n_enrich += 1
	if enrich_mode == "slow":
		if not _gate_open:
			await gate
		return {"ok": true, "code": 200, "data": _answer(body), "error": ""}
	if enrich_mode == "fail" or (enrich_mode == "fail2" and n_enrich >= 2):
		return {"ok": false, "code": 500, "data": null, "error": "서버에서 오류가 났어요."}
	if enrich_mode == "garbage":
		return {"ok": true, "code": 200, "data": {"lines": [{"i": 9999, "ko": "범위 밖"}, "x", {"i": "a", "ko": "문자 번호"}, {"i": 0, "ko": ""}, {"ko": "번호 없음"}]}, "error": ""}
	return {"ok": true, "code": 200, "data": _answer(body), "error": ""}


func _answer(body: Variant) -> Dictionary:
	var lines: Array = []
	for it in (body as Dictionary)["lines"]:
		var i: int = int((it as Dictionary)["i"])
		var d := {"i": i, "ko": "번역 %d" % i, "reading": "", "pron": "", "words": []}
		if str((body as Dictionary)["lang"]) == "ja":
			d["reading"] = "よみ%d" % i
			d["pron"] = "ヨミ%d" % i
			d["words"] = [{"w": "新", "lemma": "新", "level": "easy", "zipf": 4.0, "content": true, "reading": "あたらしい"}]
		lines.append(d)
	return {"lines": lines, "glossary": {"新": {"pos": "형용사", "ko": "새로운", "ipa": "", "pron": ""}}, "warnings": []}


func frames(n: int = 3) -> void:
	for i in n:
		await get_tree().process_frame


func wait_until(cond: Callable, max_frames: int = 120) -> bool:
	for i in max_frames:
		if cond.call():
			return true
		await get_tree().process_frame
	return bool(cond.call())


func enrich_count() -> int:
	var n := 0
	for r in requests:
		if str((r as Dictionary)["path"]) == "/song/enrich":
			n += 1
	return n


## 노드 아래 어디든 (Label · Button · RichTextLabel) 글자에 needle 이 있나.
func has_text(node: Node, needle: String) -> bool:
	if node is Label and (node as Label).text.find(needle) >= 0:
		return true
	if node is Button and (node as Button).text.find(needle) >= 0:
		return true
	if node is RichTextLabel and (node as RichTextLabel).get_parsed_text().find(needle) >= 0:
		return true
	for c in node.get_children():
		if has_text(c, needle):
			return true
	return false


func find_button(node: Node, needle: String) -> Button:
	if node is Button and (node as Button).text.find(needle) >= 0:
		return node as Button
	for c in node.get_children():
		var r: Button = find_button(c, needle)
		if r != null:
			return r
	return null


func press(node: Node, needle: String) -> bool:
	var b: Button = find_button(node, needle)
	if b == null or b.disabled:
		return false
	b.pressed.emit()
	return true


func drill_n(l: String = "en") -> int:
	return int((StudyLog.range_summary(l, 1)[0]["n"] as Dictionary)["drill"])


func dict_n(l: String = "en") -> int:
	return int((StudyLog.range_summary(l, 1)[0]["n"] as Dictionary)["dictation"])


func shadow_n(l: String = "en") -> int:
	return int((StudyLog.range_summary(l, 1)[0]["n"] as Dictionary)["shadow"])


func review_count() -> int:
	return (Store.progress["review"] as Array).size()


func mk(cls: GDScript) -> Node:
	var n: Node = cls.new()
	add_child(n)
	return n


# ---------------------------------------------------------------- fixtures (직접 쓴 가사)

func W(w: String, lemma: String = "", content: bool = true, level: String = "mid", zipf: float = 4.0, extra: Dictionary = {}) -> Dictionary:
	var d := {"w": w, "lemma": lemma if lemma != "" else w.to_lower(), "level": level, "zipf": zipf, "content": content, "est": false}
	d.merge(extra, true)
	return d


func en_song() -> Dictionary:
	return {
		"v": 1, "id": "s_000000000001", "lang": "en", "title": "Paper Boats", "artist": "Test Band", "duration": 60.0,
		"lines": [
			{"i": 0, "text": "Silver rivers carry golden sunlight", "ko": "은빛 강이 황금빛 햇살을 실어 가요", "reading": "", "words": [
				W("Silver", "silver", true, "mid", 3.9), W("rivers", "river", true, "easy", 4.6), W("carry", "carry", true, "mid", 4.4),
				W("golden", "golden", true, "mid", 4.1), W("sunlight", "sunlight", true, "hard", 3.3)]},
			{"i": 1, "text": "I can't forget the sparrow's tiny song", "ko": "참새의 작은 노래를 잊을 수 없어요", "reading": "", "words": [
				W("I", "i", false, "easy", 7.0), W("can't", "can't", false, "easy", 6.0), W("forget", "forget", true, "easy", 4.8),
				W("the", "the", false, "easy", 7.5), W("sparrow's", "sparrow", true, "hard", 2.9), W("tiny", "tiny", true, "mid", 4.0),
				W("song", "song", true, "easy", 5.0)]},
			{"i": 2, "text": "Oh yeah, oh yeah", "ko": "", "reading": "", "words": [
				W("Oh", "oh", false), W("yeah", "yeah", false), W("oh", "oh", false), W("yeah", "yeah", false)]},
			{"i": 3, "text": "Hold the lantern, hold on", "ko": "등불을 들어요, 버텨요", "reading": "", "words": [
				W("Hold", "hold", true, "easy", 4.7), W("the", "the", false), W("lantern", "lantern", true, "hard", 3.0),
				W("hold", "hold", true, "easy", 4.7), W("on", "on", false)]},
			{"i": 4, "text": "Fog and moon", "ko": "안개와 달", "reading": "", "words": [
				W("Fog", "fog", true, "mid", 3.8), W("and", "and", false), W("moon", "moon", true, "easy", 4.5)]},
			{"i": 5, "text": "[Chorus]", "ko": "", "reading": "", "words": []},
		],
		"glossary": {
			"silver": {"pos": "명사", "ko": "은, 은빛", "ipa": "ˈsɪlvər", "pron": ""},
			"sparrow": {"pos": "명사", "ko": "참새", "ipa": "ˈspæroʊ", "pron": ""},
			"lantern": {"pos": "명사", "ko": "등불", "ipa": "ˈlæntərn", "pron": ""},
			"river": {"pos": "명사", "ko": "강", "ipa": "ˈrɪvər", "pron": ""},
		},
	}


func ja_song() -> Dictionary:
	return {
		"v": 1, "id": "s_000000000002", "lang": "ja", "title": "そらのうた", "artist": "テストバンド", "duration": 40.0,
		"lines": [
			{"i": 0, "text": "空を見上げて歩く", "ko": "하늘을 올려다보며 걸어요", "reading": "そらをみあげてあるく", "pron": "ソラヲミアゲテアルク", "words": [
				W("空", "空", true, "easy", 4.5, {"reading": "そら"}), W("を", "を", false, "easy", 7.0, {"reading": "を"}),
				W("見上げて", "見上げる", true, "mid", 3.6, {"reading": "みあげて"}), W("歩く", "歩く", true, "easy", 4.4, {"reading": "あるく"})]},
			{"i": 1, "text": "小さな花が咲いた", "ko": "작은 꽃이 피었어요", "reading": "ちいさなはながさいた", "pron": "", "words": [
				W("小さな", "小さい", true, "easy", 4.2, {"reading": "ちいさな"}), W("花", "花", true, "easy", 4.6, {"reading": "はな"}),
				W("が", "が", false, "easy", 7.0, {"reading": "が"}), W("咲いた", "咲く", true, "mid", 3.4, {"reading": "さいた"})]},
			{"i": 2, "text": "ねえ、ねえ", "ko": "", "reading": "ねえねえ", "pron": "", "words": [W("ねえ", "ねえ", false), W("ねえ", "ねえ", false)]},
		],
		"glossary": {
			"空": {"pos": "명사", "ko": "하늘", "ipa": "", "pron": ""},
			"咲く": {"pos": "동사", "ko": "피다", "ipa": "", "pron": ""},
		},
	}


## 해석이 모두 비어 있는 곡 (n 줄). SongStore 에 설치한 뒤 다시 읽은(정규화된) 곡을 돌려준다.
func install_blank_song(l: String, n: int) -> Dictionary:
	var lines: Array = []
	for i in n:
		lines.append({"i": i, "t0": float(i) * 2.0, "t1": float(i) * 2.0 + 1.5, "text": ("Line number %d sings" % i) if l == "en" else ("うた%dばん" % i),
			"ko": "", "reading": "" if l == "en" else "うた%d" % i, "words": [W("sings", "sing", true, "easy", 4.5)] if l == "en" else []})
	var raw := {"v": 1, "lang": l, "title": "Blank Song", "artist": "Test", "duration": float(n) * 2.0 + 5.0, "lines": lines}
	var audio: PackedByteArray = "not really mp3".to_utf8_buffer()
	var r: Dictionary = SongStore.install(raw, audio)
	if not bool(r.get("ok", false)):
		return {}
	return SongStore.load_song(str(r["id"]))


# ---------------------------------------------------------------- run

func _run() -> void:
	await _test_words_en()
	await _test_words_ja()
	await _test_cloze_en()
	await _test_cloze_ja()
	await _test_dictation_en()
	await _test_dictation_ja()
	await _test_events()
	await _test_meaning_rules()
	await _test_meaning_request()
	await _test_meaning_errors()
	await _test_meaning_view()
	await _test_pc_rule()
	await _test_layout()


func _test_words_en() -> void:
	Store.progress = Progress.blank()
	var song: Dictionary = en_song()
	var pl := FakePlayer.new()
	add_child(pl)
	var tab: SongWordsTab = mk(SongWordsTab) as SongWordsTab
	tab.setup(song, {"player": pl, "line": 1})
	await frames()
	var ref: Array = SongStudy.pick_unknown(song, {}, 200)
	ok(tab.words.size() == ref.size() and ref.size() > 5, "U-11 word list == SongStudy.pick_unknown (%d words)" % tab.words.size())
	ok(str(tab.words[0]["lemma"]) == "sparrow", "U-11 hardest word first (sparrow)")
	var has_stop := false
	for w in tab.words:
		if ["the", "i", "oh", "yeah", "and", "on"].has(str((w as Dictionary)["lemma"])):
			has_stop = true
	ok(not has_stop, "U-11 stopwords / content:false are not listed")
	ok(has_text(tab, "모르는 단어 %d개" % ref.size()) and has_text(tab, "sparrow's"), "U-11 header count + word shown")
	ok(tab.get_child_count() > 0 and not has_text(tab, "참새의 작은 노래"), "U-11 detail closed at first")
	# 단어를 누르면 뜻 · IPA
	var row: Button = null
	for c in tab.get_children():
		if c is Button and str((c as Button).get_meta("lemma", "")) == "sparrow":
			row = c
	ok(row != null, "U-11 word row button exists (meta lemma)")
	if row != null:
		row.pressed.emit()
	await frames()
	ok(tab.open_lemma == "sparrow" and has_text(tab, "발음기호  /ˈspæroʊ/") and has_text(tab, "참새"), "U-11 tap -> meaning (참새) and IPA shown")
	ok(has_text(tab, "곡에 1번 나와요"), "U-11 detail shows how often the word occurs")
	# 단어 듣기
	tts_calls.clear()
	var paused0: int = pl.paused
	ok(press(tab, "단어 듣기"), "U-11 [단어 듣기] pressable")
	await frames(4)
	ok(tts_calls.size() >= 1 and str(tts_calls[0]["text"]) == "sparrow's" and str(tts_calls[0]["lang"]) == "en", "U-11 word is read aloud via Tts (en)")
	ok(pl.paused == paused0 + 1, "U-11 the song is paused before the word is read (5.5)")
	ok(press(tab, "노래에서 듣기") and pl.played == [[1, 1]], "U-11 [노래에서 듣기] -> SongPlayer.play_line(first line, 1)")
	# 복습에 추가
	var base: int = review_count()
	var added: int = tab.add_card("sparrow")
	ok(added == 1 and review_count() == base + 1, "U-11 [복습에 추가] -> Store.add_review +1")
	var saved: Dictionary = Progress.load_file(TEST_PROGRESS)
	var on_disk := false
	for r in saved["review"]:
		if str((r as Dictionary)["target"]) == "sparrow" and str((r as Dictionary)["ko"]) == "참새" and str((r as Dictionary)["note"]).begins_with("♪ "):
			on_disk = true
	ok(on_disk, "U-11 the card is saved (Store.save_progress): file has sparrow / 참새 / note ♪")
	ok(tab.add_card("sparrow") == 0 and review_count() == base + 1, "U-11/F20 adding the same word again -> 0 new cards")
	ok(has_text(tab, "복습에 있어요") and find_button(tab, "복습에 있어요").disabled, "U-11 button turns into a disabled '복습에 있어요'")
	# 아는 단어
	var n_before: int = tab.words.size()
	ok(tab.mark_known("sparrow") and Store.is_known("en", "sparrow"), "U-11 [아는 단어] -> Store.is_known true")
	ok(tab.words.size() == n_before - 1 and tab.open_lemma == "", "U-11 known word leaves the list")
	var on_disk2: Dictionary = Progress.load_file(TEST_PROGRESS)
	ok((on_disk2["known_words"]["en"] as Array).has("sparrow"), "U-11 known word is saved to the progress file")
	# 현재 줄 필터
	tab.set_only_line(true)
	await frames()
	var keys: Array = []
	for w in tab.visible_words():
		keys.append(str((w as Dictionary)["lemma"]))
	keys.sort()
	ok(keys == ["forget", "song", "tiny"], "U-11 '현재 줄의 단어만' -> only line 1 words (sparrow is known now): %s" % str(keys))
	tab.set_line(3)
	await frames()
	var keys3: Array = []
	for w in tab.visible_words():
		keys3.append(str((w as Dictionary)["lemma"]))
	keys3.sort()
	ok(keys3 == ["hold", "lantern"], "U-11 set_line(3) follows the player's line: %s" % str(keys3))
	tab.set_only_line(false)
	# 쪽 나누기
	var big: Array = []
	for i in 80:
		big.append(W("word%dx" % i, "word%dx" % i, true, "mid", 4.0))
	var big_song := {"lang": "en", "title": "Big", "lines": [{"text": "many words", "words": big}], "glossary": {}}
	var tab2: SongWordsTab = mk(SongWordsTab) as SongWordsTab
	tab2.setup(big_song, {})
	await frames()
	ok(tab2.words.size() == 80 and count_buttons(tab2, "word") == SongWordsTab.PAGE and has_text(tab2, "더 보기"), "U-11 80 words -> first %d rows + [더 보기]" % SongWordsTab.PAGE)
	tab2.show_more()
	ok(count_buttons(tab2, "word") == SongWordsTab.PAGE * 2, "U-11 [더 보기] adds a page")
	# 곡이 비었을 때
	var tab3: SongWordsTab = mk(SongWordsTab) as SongWordsTab
	tab3.setup({"lang": "en", "title": "Empty", "lines": []}, {})
	await frames()
	ok(has_text(tab3, SongWordsTab.MSG_EMPTY_SONG), "U-11 a song without words -> guidance text")
	var all_known: Array = []
	for w in SongStudy.pick_unknown(song, {}, 500):
		all_known.append(str((w as Dictionary)["lemma"]))
	Store.set_known("en", all_known, true)
	tab.refresh()
	await frames()
	ok(tab.words.is_empty() and has_text(tab, SongWordsTab.MSG_EMPTY_ALL), "U-11 every word known -> '모두 아는 단어' text")
	Store.set_known("en", all_known, false)
	for t in [tab, tab2, tab3]:
		(t as Node).queue_free()
	pl.queue_free()
	await frames()
	reached["words_en"] = true


func count_buttons(node: Node, prefix: String) -> int:
	var n := 0
	for c in node.get_children():
		if c is Button and (c as Button).has_meta("lemma") and (c as Button).text.begins_with(prefix):
			n += 1
	return n


func _test_words_ja() -> void:
	Store.progress = Progress.blank()
	var song: Dictionary = ja_song()
	var tab: SongWordsTab = mk(SongWordsTab) as SongWordsTab
	tab.setup(song, {})
	await frames()
	var lemmas: Array = []
	for w in tab.words:
		lemmas.append(str((w as Dictionary)["lemma"]))
	ok(lemmas.has("空") and lemmas.has("咲く") and not lemmas.has("を") and not lemmas.has("が") and not lemmas.has("ねえ"), "U-11 ja: content words only (particles / interjections out): %s" % str(lemmas))
	tab.toggle_word("咲く")
	await frames()
	var hira: String = "さいた"
	var hangul: String = KanaHangul.to_hangul(hira)
	ok(hangul != "" and has_text(tab, hira) and has_text(tab, hangul), "U-11 ja: hiragana (%s) and Hangul sound (%s) are shown" % [hira, hangul])
	ok(has_text(tab, "피다") and has_text(tab, "기본형  咲く"), "U-11 ja: meaning (피다) and base form")
	Store.prefs["show_hangul_ja"] = false
	tab.on_show()
	await frames()
	ok(has_text(tab, hira) and not has_text(tab, hangul), "U-11 ja: show_hangul_ja off -> Hangul line gone, hiragana stays")
	Store.prefs["show_hangul_ja"] = true
	Store.prefs["show_reading"] = false
	tab.on_show()
	await frames()
	ok(not has_text(tab, hira) and has_text(tab, hangul), "U-11 ja: show_reading off -> hiragana gone, Hangul stays")
	Store.prefs["show_reading"] = true
	tts_calls.clear()
	tab.speak_word("空")
	await frames(4)
	ok(tts_calls.size() >= 1 and str(tts_calls[0]["lang"]) == "ja" and str(tts_calls[0]["text"]) == "空", "U-11 ja: word read aloud in ja")
	var base: int = review_count()
	ok(tab.add_card("空") == 1 and review_count() == base + 1, "U-11 ja: card added")
	var card_reading := ""
	var card_ko := ""
	for r in Store.progress["review"]:
		if str((r as Dictionary)["target"]) == "空":
			card_reading = str((r as Dictionary)["reading"])
			card_ko = str((r as Dictionary)["ko"])
	ok(card_reading == "そら" and card_ko == "하늘", "U-11 ja: card has hiragana reading + meaning")
	ok(not tab.speak_word("없는단어") and tab.add_card("없는단어") == 0, "robust: unknown lemma -> speak false, add_card 0")
	tab.queue_free()
	await frames()
	reached["words_ja"] = true


func _test_cloze_en() -> void:
	Store.progress = Progress.blank()
	StudyLog.reset()
	var song: Dictionary = en_song()
	var pl := FakePlayer.new()
	add_child(pl)
	var tab: SongClozeTab = mk(SongClozeTab) as SongClozeTab
	tab.seed_value = 7
	tab.setup(song, {"player": pl, "line": -1})
	tab.seed_value = 7
	tab.restart(1, -1)
	await frames()
	ok(tab.stage == "run" and tab.order == [0, 1, 3, 4], "U-12 session = lines that can make a blank [0,1,3,4] (got %s)" % str(tab.order))
	var cz0: Dictionary = SongStudy.cloze(song, 0, 1, 7, {})
	ok(tab.cur["prompt"] == cz0["prompt"] and has_text(tab, "____"), "U-12 prompt == SongStudy.cloze with the same seed, blank shown")
	ok((tab.cur["blanks"] as Array).size() == 1 and has_text(tab, "빈칸 1개") and has_text(tab, "1 / 4"), "U-12 level 1 -> 1 blank, progress '1 / 4'")
	# 비어 있으면 확인 안 됨
	ok(not tab.check(false) and tab.results.is_empty() and drill_n() == 0, "U-12 empty answer -> check() does nothing, no event")
	ok(find_button(tab, "확인").disabled, "U-12 [확인] disabled while a blank is empty")
	# 보기
	var opts: Array = (tab.cur["blanks"][0] as Dictionary)["options"]
	ok(opts.size() >= 2 and opts.has(str(tab.cur["blanks"][0]["answer"])), "U-12 options contain the answer (%d options)" % opts.size())
	tab.pick_option(0, str(opts[0]))
	await frames()
	ok(tab.answers[0] == str(opts[0]) and not find_button(tab, "확인").disabled, "U-12 picking an option fills the answer and enables [확인]")
	# 정답: 대문자 · 문장부호 무시
	var ans0: String = str(tab.cur["blanks"][0]["answer"])
	tab.set_answer(0, ans0.to_upper() + ".")
	var d0: int = drill_n()
	ok(tab.check(false) and bool(tab.results[0]["ok"]), "U-12 right answer (UPPERCASE + period) -> ok")
	ok(drill_n() == d0 + 1 and tab.event_n == 1, "U-12 one 'drill' event for the line")
	ok(not tab.check(false) and drill_n() == d0 + 1, "U-12 checking the same line again -> no second event")
	ok(has_text(tab, "맞았어요") and has_text(tab, "모두 맞았어요") and not has_text(tab, "____"), "U-12 right mark ✓ + full line shown after checking")
	tab.set_answer(0, "zzz")
	ok(str(tab.answers[0]) == ans0.to_upper() + ".", "U-12 a checked line cannot be edited")
	# 다음 줄 -> 오답
	tab.next_line()
	await frames()
	var ans1: String = str(tab.cur["blanks"][0]["answer"])
	tab.set_answer(0, "wrongword")
	ok(tab.check(false) and not bool(tab.results[1]["ok"]) and drill_n() == d0 + 2, "U-12 wrong answer -> not ok, 'drill' event +1")
	ok(has_text(tab, "정답: " + ans1) and has_text(tab, "wrongword") and has_text(tab, "틀린 빈칸"), "U-12 wrong mark ✕ + the right answer + my answer shown")
	var base: int = review_count()
	ok(press(tab, "이 줄 복습에 추가") and review_count() == base + 1, "U-12 [이 줄 복습에 추가] -> line card +1")
	ok(tab.add_line_cards(1) == 0 and review_count() == base + 1, "U-12/F20 same line card again -> 0")
	# 모르겠어요
	tab.next_line()
	await frames()
	ok(tab.check(true) and not bool(tab.results[3]["ok"]) and bool(tab.results[3]["gave_up"]) and drill_n() == d0 + 3, "U-12 '모르겠어요' -> wrong + one event")
	# 줄 이동 (set_line): 이미 푼 줄은 결과 상태
	tab.set_line(0)
	await frames()
	ok(tab.current_line() == 0 and tab.is_checked() and has_text(tab, "모두 맞았어요"), "U-12 set_line(0) jumps back to a solved line (shows its result)")
	tab.set_line(4)
	await frames()
	ok(tab.current_line() == 4 and not tab.is_checked(), "U-12 set_line(4) -> unsolved line")
	tab.set_line(2)
	ok(tab.current_line() == 4, "U-12 set_line(line not in session) -> stays")
	# 마지막 줄 -> 요약
	tab.set_answer(0, str(tab.cur["blanks"][0]["answer"]))
	tab.check(false)
	tab.next_line()
	await frames()
	ok(tab.stage == "summary" and has_text(tab, "4줄 중 2줄 정답"), "U-12 all lines done -> summary '4줄 중 2줄 정답'")
	ok(drill_n() == d0 + 4 and tab.event_n == 4, "U-12 exactly 4 'drill' events for 4 lines")
	ok(has_text(tab, "틀린 줄 2개") and has_text(tab, "✕ I can't forget the sparrow's tiny song"), "U-12 summary lists the wrong lines")
	# 틀린 줄 · 단어 복습
	var base2: int = review_count()
	var n_lines: int = tab.add_line_cards(-1)
	ok(n_lines == 1 and review_count() == base2 + 1, "U-12 [틀린 줄 복습에 추가] -> only new cards (line 1 was already added): %d" % n_lines)
	var n_words: int = tab.add_word_cards(-1)
	var wrong_words: Array = []
	for li in [1, 3]:
		wrong_words.append(str(tab.results[li]["blanks"][0]["answer"]))
	ok(n_words == 2 and review_count() == base2 + 3, "U-12 [틀린 단어 복습에 추가] -> 2 word cards %s" % str(wrong_words))
	ok(tab.add_word_cards(-1) == 0 and tab.add_line_cards(-1) == 0, "U-12/F20 repeating both -> 0")
	var sv: Dictionary = Progress.load_file(TEST_PROGRESS)
	ok((sv["review"] as Array).size() == review_count(), "U-12 review cards saved to the progress file (%d)" % review_count())
	# 다시 하기 · 난이도
	tab.set_level(3)
	await frames()
	ok(tab.stage == "run" and tab.results.is_empty() and tab.level == 3 and drill_n() == d0 + 4, "U-12 level change restarts the session, no events added")
	var n3: int = (tab.cur["blanks"] as Array).size()
	ok(n3 >= 1 and n3 <= 3 and has_text(tab, "빈칸 3개"), "U-12 level 3 -> up to 3 blanks (%d)" % n3)
	# 아는 단어는 빈칸에서 빠진다
	Store.set_known("en", ["sparrow", "tiny", "forget", "song"], true)
	var hit := false
	for sd in 25:
		tab.seed_value = sd
		tab.restart(3, 1)
		if tab.order.has(1):
			hit = true
	ok(not hit and not tab.order.has(1), "U-12 line 1 has only known words left -> no blank, line leaves the session")
	Store.set_known("en", ["sparrow", "tiny", "forget", "song"], false)
	# 끝까지 안 풀고 결과 보기
	tab.restart(1, -1)
	tab.finish()
	ok(tab.stage == "summary" and has_text(tab, "푼 줄이 없어요"), "U-12 finishing without solving -> '푼 줄이 없어요'")
	# 플레이어
	tab.restart(1, 3)
	ok(tab.play_current_line() and pl.played == [[3, 1]], "U-12 play_current_line -> SongPlayer.play_line(3, 1)")
	# 빈 곡
	var tab2: SongClozeTab = mk(SongClozeTab) as SongClozeTab
	tab2.setup({"lang": "en", "title": "x", "lines": [{"text": "Oh yeah", "words": [W("Oh", "oh", false)]}]}, {})
	await frames()
	ok(tab2.stage == "empty" and has_text(tab2, "빈칸을 만들 수 있는 줄이 없어요") and not tab2.check(false), "U-12 no usable line -> empty notice, check() false")
	tab.queue_free()
	tab2.queue_free()
	pl.queue_free()
	await frames()
	reached["cloze_en"] = true


func _test_cloze_ja() -> void:
	Store.progress = Progress.blank()
	StudyLog.reset()
	var song: Dictionary = ja_song()
	var tab: SongClozeTab = mk(SongClozeTab) as SongClozeTab
	tab.setup(song, {})
	tab.seed_value = 3
	tab.restart(2, -1)
	await frames()
	ok(tab.order == [0, 1] and (tab.cur["blanks"] as Array).size() == 2, "U-12 ja: lines [0,1] (ねえ has no usable word), level 2 -> 2 blanks")
	# 정답: 한자 표기 하나, 히라가나 읽기 하나
	var b0: Dictionary = tab.cur["blanks"][0]
	var b1: Dictionary = tab.cur["blanks"][1]
	tab.set_answer(0, str(b0["answer"]))
	tab.set_answer(1, str(b1["reading"]))
	ok(str(b1["reading"]) != "" and tab.check(false) and bool(tab.results[0]["ok"]), "U-12 ja: kanji answer and hiragana reading both count right (TextSim)")
	ok(drill_n("ja") == 1, "U-12 ja: one 'drill' event (lang ja)")
	tab.next_line()
	await frames()
	tab.set_answer(0, "ぜんぜんちがう")
	tab.set_answer(1, "ちがう")
	ok(tab.check(false) and not bool(tab.results[1]["ok"]) and drill_n("ja") == 2, "U-12 ja: wrong answers -> wrong, event +1")
	ok(has_text(tab, "ちいさなはながさいた") or has_text(tab, KanaHangul.to_hangul("ちいさなはながさいた")), "U-12 ja: reading / Hangul of the line shown after checking")
	tab.next_line()
	await frames()
	ok(tab.stage == "summary" and has_text(tab, "2줄 중 1줄 정답"), "U-12 ja: summary '2줄 중 1줄 정답'")
	var base: int = review_count()
	ok(tab.add_line_cards(-1) == 1 and review_count() == base + 1, "U-12 ja: wrong line -> card (reading hiragana)")
	var rd := ""
	for r in Store.progress["review"]:
		if str((r as Dictionary)["target"]) == "小さな花が咲いた":
			rd = str((r as Dictionary)["reading"])
	ok(rd == "ちいさなはながさいた", "U-12 ja: line card carries the hiragana reading")
	tab.queue_free()
	await frames()
	reached["cloze_ja"] = true


func _test_dictation_en() -> void:
	Store.progress = Progress.blank()
	StudyLog.reset()
	var song: Dictionary = en_song()
	var pl := FakePlayer.new()
	add_child(pl)
	var tab: SongDictationTab = mk(SongDictationTab) as SongDictationTab
	tab.setup(song, {"player": pl, "line": -1})
	await frames()
	ok(tab.order == [0, 1, 2, 3, 4], "U-12 dictation: [Chorus] marker line skipped, others listed (%s)" % str(tab.order))
	ok(has_text(tab, "1 / 5") and has_text(tab, "단어 5개"), "U-12 dictation: progress '1 / 5', word count 5")
	# 듣기
	ok(tab.listen() and pl.played == [[0, 1]] and has_text(tab, "들은 횟수 1"), "U-12 dictation: [줄 듣기] -> SongPlayer.play_line(0, 1), listen count 1")
	tab.listen()
	ok(pl.played.size() == 2 and has_text(tab, "들은 횟수 2"), "U-12 dictation: listening again -> count 2")
	# 빈 입력
	var e0: int = dict_n()
	ok(not tab.check(false) and tab.results.is_empty() and dict_n() == e0, "U-12 dictation: empty input -> nothing happens, no event")
	ok(find_button(tab, "확인").disabled, "U-12 dictation: [확인] disabled when empty")
	# 힌트
	tab.toggle_hint()
	await frames()
	ok(has_text(tab, "S_____"), "U-12 dictation: first-letter hint shown")
	# 정답
	tab.set_typed("silver rivers carry golden sunlight")
	var pz: int = pl.paused
	ok(tab.check(false), "U-12 dictation: check accepted")
	var r0: Dictionary = tab.results[0]
	var ref: Dictionary = SongStudy.dictation_score("en", "silver rivers carry golden sunlight", song["lines"][0])
	ok(int(r0["score"]) == int(ref["score"]) and int(r0["score"]) == 100 and bool(r0["passed"]), "U-12 dictation: score == SongStudy.dictation_score (100), passed")
	ok(dict_n() == e0 + 1 and tab.event_n == 1, "U-12 dictation: one 'dictation' event")
	ok(pl.paused == pz + 1, "U-12 dictation: song paused when the answer is checked")
	ok(not tab.check(false) and dict_n() == e0 + 1, "U-12 dictation: second check on the same line -> no second event")
	ok(has_text(tab, "100점") and has_text(tab, "통과!") and has_text(tab, "정답"), "U-12 dictation: result card 100점 / 통과")
	tab.next_line()
	await frames()
	# 오답
	tab.set_typed("I cant forget the tiny bird")
	tab.check(false)
	var r1: Dictionary = tab.results[1]
	var ref1: Dictionary = SongStudy.dictation_score("en", "I cant forget the tiny bird", song["lines"][1])
	ok(int(r1["score"]) == int(ref1["score"]) and not bool(r1["passed"]) and int(r1["score"]) < 85 and dict_n() == e0 + 2, "U-12 dictation: wrong text -> score from DictationDiff (%d), not passed, event +1" % int(r1["score"]))
	ok(has_text(tab, "빠짐") and has_text(tab, "✕ 통과 기준은 85점"), "U-12 dictation: missing words listed with ✕ and the reason")
	var base: int = review_count()
	ok(press(tab, "이 줄 복습에 추가") and review_count() == base + 1, "U-12 dictation: [이 줄 복습에 추가] -> card")
	tab.next_line()
	await frames()
	# 모르겠어요
	ok(tab.check(true) and int(tab.results[2]["score"]) == 0 and bool(tab.results[2]["gave_up"]) and dict_n() == e0 + 3, "U-12 dictation: '모르겠어요' -> 0점, event +1")
	tab.next_line()
	await frames()
	tab.set_typed("hold the lantern hold on")
	tab.check(false)
	tab.next_line()
	await frames()
	tab.set_typed("fog and moon")
	tab.check(false)
	tab.next_line()
	await frames()
	ok(tab.stage == "summary" and dict_n() == e0 + 5 and tab.event_n == 5, "U-12 dictation: summary after the last line; exactly 5 'dictation' events")
	var sm: Dictionary = tab.summarize()
	ok(int(sm["n"]) == 5 and int(sm["passed"]) == 3 and (sm["low"] as Array) == [1, 2], "U-12 dictation: summary n=5 passed=3 low=[1,2] (%s)" % str(sm))
	ok(has_text(tab, "통과 3줄 / 시도 5줄") and has_text(tab, "85점 미만 줄 복습에 추가"), "U-12 dictation: summary text + review button")
	var base2: int = review_count()
	ok(tab.add_line_cards(-1) == 1 and review_count() == base2 + 1, "U-12 dictation: lines under 85 -> cards (line 1 already there, line 2 new)")
	ok(tab.add_line_cards(-1) == 0, "U-12/F20 dictation: repeat -> 0")
	var sv: Dictionary = Progress.load_file(TEST_PROGRESS)
	ok((sv["review"] as Array).size() == review_count(), "U-12 dictation: cards saved to the progress file")
	# 플레이어 없이: Tts 로 대신 읽는다
	var tab2: SongDictationTab = mk(SongDictationTab) as SongDictationTab
	tab2.setup(song, {})
	await frames()
	tts_calls.clear()
	tab2.listen()
	await frames(4)
	ok(tts_calls.size() >= 1 and str(tts_calls[0]["text"]) == "Silver rivers carry golden sunlight", "U-12 dictation: no player -> Tts reads the line")
	# 줄 이동
	tab2.set_line(3)
	await frames()
	ok(tab2.current_line() == 3, "U-12 dictation: set_line(3) jumps to line 3")
	ok(SongDictationTab.is_dictable("en", {"text": "Hello there"}) and not SongDictationTab.is_dictable("en", {"text": "[Verse 1]"}) and not SongDictationTab.is_dictable("en", {"text": "  "}) and not SongDictationTab.is_dictable("ja", {"text": "、。"}), "U-12 dictation: is_dictable rules")
	tab.queue_free()
	tab2.queue_free()
	pl.queue_free()
	await frames()
	reached["dictation_en"] = true


func _test_dictation_ja() -> void:
	Store.progress = Progress.blank()
	StudyLog.reset()
	var song: Dictionary = ja_song()
	var tab: SongDictationTab = mk(SongDictationTab) as SongDictationTab
	tab.setup(song, {})
	await frames()
	ok(tab.order == [0, 1, 2] and has_text(tab, "글자 8자"), "U-12 dictation ja: lines [0,1,2], '글자 8자' for line 0")
	tab.set_typed("空を見上げて歩く")
	tab.check(false)
	ok(int(tab.results[0]["score"]) == 100 and bool(tab.results[0]["passed"]) and dict_n("ja") == 1, "U-12 dictation ja: exact -> 100 (TextSim), 'dictation' event (ja)")
	ok(has_text(tab, "そらをみあげてあるく") and has_text(tab, KanaHangul.from_pron("ソラヲミアゲテアルク")), "U-12 dictation ja: hiragana + Hangul (from pron) of the answer shown")
	tab.next_line()
	await frames()
	tab.set_typed("ちいさなはながさいた")
	tab.check(false)
	var ref: Dictionary = SongStudy.dictation_score("ja", "ちいさなはながさいた", song["lines"][1])
	ok(int(tab.results[1]["score"]) == int(ref["score"]) and int(ref["score"]) == 100, "U-12 dictation ja: hiragana reading typed -> 100 as well (TextSim reading)")
	tab.next_line()
	await frames()
	ok(tab.check(false) == false and dict_n("ja") == 2, "U-12 dictation ja: empty input -> 0 points path: check() false, no event")
	tab.set_typed("   ")
	ok(not tab.check(false), "U-12 dictation ja: blank input rejected")
	var dd: Dictionary = SongStudy.dictation_score("ja", "", song["lines"][0])
	ok(int(dd["score"]) == 0, "U-12 dictation ja: SongStudy.dictation_score of '' == 0")
	tab.queue_free()
	await frames()
	reached["dictation_ja"] = true


func _test_events() -> void:
	Store.progress = Progress.blank()
	StudyLog.reset()
	requests.clear()
	var song: Dictionary = en_song()
	var words: SongWordsTab = mk(SongWordsTab) as SongWordsTab
	var cloze: SongClozeTab = mk(SongClozeTab) as SongClozeTab
	var dic: SongDictationTab = mk(SongDictationTab) as SongDictationTab
	var mean: SongMeaningTab = mk(SongMeaningTab) as SongMeaningTab
	for t in [words, cloze, dic, mean]:
		(t as Node).call("setup", song, {})
	await frames()
	# 단어 · 해석 탭은 이벤트를 세지 않는다
	words.toggle_word("sparrow")
	words.speak_word("sparrow")
	words.add_card("sparrow")
	words.mark_known("fog")
	mean.add_line_card(0)
	mean.set_line(2)
	ok(drill_n() == 0 and dict_n() == 0 and shadow_n() == 0, "events: words / meaning tabs count no study events")
	# 빈칸 3줄 + 받아쓰기 2줄
	cloze.seed_value = 5
	cloze.restart(1, -1)
	for k in 3:
		cloze.set_answer(0, str(cloze.cur["blanks"][0]["answer"]))
		cloze.check(false)
		cloze.check(false) # 두 번째는 세지 않는다
		cloze.next_line()
	dic.set_typed("silver rivers carry golden sunlight")
	dic.check(false)
	dic.check(false)
	dic.next_line()
	dic.set_typed("anything")
	dic.check(false)
	ok(drill_n() == 3 and cloze.event_n == 3, "events: cloze tab -> exactly 3 'drill' for 3 lines (double check ignored)")
	ok(dict_n() == 2 and dic.event_n == 2, "events: dictation tab -> exactly 2 'dictation' for 2 lines")
	ok(shadow_n() == 0, "events: no tab counts 'shadow' (SongSingDrill / the sing tab does, no double count)")
	# 다시 하기는 새 회차 -> 새로 센다
	cloze.restart(1, -1)
	cloze.set_answer(0, str(cloze.cur["blanks"][0]["answer"]))
	cloze.check(false)
	ok(drill_n() == 4, "events: a new session counts again (4)")
	for t in [words, cloze, dic, mean]:
		(t as Node).queue_free()
	await frames()
	reached["events"] = true


func _test_meaning_rules() -> void:
	# ai_ok = song_consent AND 곡별 해석 켬
	var combos := [[false, false, false], [false, true, false], [true, false, false], [true, true, true]]
	var good := true
	for c in combos:
		Store.prefs["song_consent"] = c[0]
		var s := {"lang": "en", "lines": [], "translate": c[1]}
		if SongMeaningTab.ai_ok(s) != c[2]:
			good = false
	ok(good, "12.1b ai_ok == consent AND per-song switch for all 4 combinations")
	Store.prefs["song_consent"] = true
	Store.prefs.erase("song_translate")
	ok(SongMeaningTab.ai_ok({"lang": "en", "lines": []}), "12.1b song without the switch + no pref -> on by default (needs consent)")
	Store.prefs["song_translate"] = false
	ok(not SongMeaningTab.ai_ok({"lang": "en", "lines": []}) and SongMeaningTab.ai_ok({"lang": "en", "lines": [], "translate": true}), "12.1b pref song_translate=false is the default, the song's own switch wins")
	Store.prefs.erase("song_translate")
	Store.prefs["song_consent"] = false
	ok(not SongMeaningTab.ai_ok({"lang": "en", "lines": [], "translate": true}), "12.1b no consent -> false even with the song switch on")
	Store.prefs.erase("song_consent")
	ok(not SongMeaningTab.ai_ok({"lang": "en", "lines": [], "translate": true}), "12.1b song_consent key missing -> false")
	# 동의 전: 요청 0
	var song: Dictionary = install_blank_song("en", 5)
	ok(not song.is_empty() and (song["lines"] as Array).size() == 5, "setup: blank song installed in the test store")
	var tab: SongMeaningTab = mk(SongMeaningTab) as SongMeaningTab
	tab.setup(song, {})
	await frames()
	SpeakDrill.api_hook = Callable() # 진짜 Api 로 가면 sent_count 가 오른다
	requests.clear()
	var sent0: int = Api.sent_count
	var req0: Dictionary = tab.build_request([0, 1])
	ok(bool(req0["ai_ok"]) == false and req0.has("ai_ok"), "12.1b request body carries ai_ok:false when there is no consent")
	var started: bool = await tab.make_missing()
	await frames()
	ok(not started and tab.request_count == 0 and Api.sent_count == sent0 and requests.is_empty(), "12.1b no consent -> no request at all (request_count 0, Api.sent_count unchanged)")
	ok(has_text(tab, SongMeaningTab.MSG_NO_CONSENT) and find_button(tab, "해석 만들기") == null, "12.1b no consent -> explanation, no [해석 만들기] button")
	# 동의했지만 곡별로 끔
	Store.prefs["song_consent"] = true
	tab.set_translate(false)
	await frames()
	started = await tab.make_missing()
	ok(not started and tab.request_count == 0 and Api.sent_count == sent0, "12.1b consent but song switch off -> no request")
	ok(bool(tab.build_request([0])["ai_ok"]) == false, "12.1b ...and a built body says ai_ok:false")
	ok(bool(SongStore.load_song(str(song["id"])).get("translate", true)) == false, "12.1b the song's switch is saved in song.json")
	ok(has_text(tab, "이 곡의 해석을 AI로 만들기") and find_button(tab, "해석 만들기") == null, "12.1b switch row shown, button hidden while the switch is off")
	# PC 없음
	tab.set_translate(true)
	SongMeaningTab.pc_hook = Callable(self, "_pc_no")
	await frames()
	started = await tab.make_missing()
	ok(not started and tab.request_count == 0 and Api.sent_count == sent0 and has_text(tab, "PC에 연결해야 해요"), "U-13 no PC -> guidance, zero requests")
	ok(find_button(tab, "해석 만들기") == null, "U-13 no PC -> no [해석 만들기] button")
	SongMeaningTab.pc_hook = Callable(self, "_pc_yes")
	SpeakDrill.api_hook = Callable(self, "_hook")
	tab.queue_free()
	await frames()
	reached["meaning_rules"] = true


func _test_meaning_request() -> void:
	Store.prefs["song_consent"] = true
	requests.clear()
	enrich_mode = "ok"
	var song: Dictionary = install_blank_song("en", 45)
	var tab: SongMeaningTab = mk(SongMeaningTab) as SongMeaningTab
	tab.setup(song, {})
	await frames()
	ok(tab.missing_lines().size() == 45 and has_text(tab, "45줄 중 0줄에 해석이 있어요"), "U-13 45 lines without ko -> 'missing' 45, header '45줄 중 0줄'")
	ok(has_text(tab, "해석이 아직 없어요") and find_button(tab, "해석 만들기") != null, "U-13 shows '해석이 아직 없어요' and [해석 만들기] (PC connected)")
	var changed_n := [0]
	tab.song_changed.connect(func() -> void: changed_n[0] += 1)
	var done: bool = await tab.make_missing()
	await frames()
	ok(done and enrich_count() == 3 and tab.request_count == 3, "5.1 45 lines -> 3 requests of <= 20 lines (got %d)" % enrich_count())
	var sizes: Array = []
	var all_ai := true
	var tasks_ok := true
	var text_ok := true
	for r in requests:
		var b: Dictionary = (r as Dictionary)["body"]
		sizes.append((b["lines"] as Array).size())
		if b.get("ai_ok", null) != true:
			all_ai = false
		if not (b["tasks"] as Array).has("translate") or str(b["lang"]) != "en" or not b.has("known"):
			tasks_ok = false
		for it in b["lines"]:
			if str((it as Dictionary)["text"]) != "Line number %d sings" % int((it as Dictionary)["i"]):
				text_ok = false
	ok(sizes == [20, 20, 5], "5.1 batch sizes 20 / 20 / 5 (got %s)" % str(sizes))
	ok(all_ai, "12.1b every request has ai_ok:true (consent AND song switch both on)")
	ok(tasks_ok and text_ok and str((requests[0] as Dictionary)["method"]) == "POST", "5.1 body: POST /song/enrich {lang, lines[{i,text}], tasks has translate, known, ai_ok}")
	var lines: Array = song["lines"]
	var filled := 0
	for i in lines.size():
		if str((lines[i] as Dictionary)["ko"]) == "번역 %d" % i:
			filled += 1
	ok(filled == 45 and tab.missing_lines().is_empty(), "U-13 all 45 lines got their ko, nothing missing")
	ok(changed_n[0] == 1, "U-13 song_changed emitted once")
	var disk: Dictionary = SongStore.load_song(str(song["id"]))
	ok(str((disk["lines"] as Array)[44]["ko"]) == "번역 44" and str((disk["lines"] as Array)[0]["ko"]) == "번역 0", "U-13 the ko is saved into song.json (SongStore.save_song)")
	ok(has_text(tab, "45줄 중 45줄에 해석이 있어요") and has_text(tab, "번역 7") and find_button(tab, "해석 만들기") == null, "U-13 view updated: '45줄 중 45줄', ko shown, no button")
	ok(not (await tab.make_missing()) and enrich_count() == 3, "U-13 nothing missing -> no request")
	# 일본어 stale 줄
	requests.clear()
	var jsong: Dictionary = install_blank_song("ja", 3)
	(jsong["lines"][1] as Dictionary)["ko"] = "남아 있는 해석"
	(jsong["lines"][1] as Dictionary)["stale"] = true
	(jsong["lines"][2] as Dictionary)["ko"] = "그대로"
	var jt: SongMeaningTab = mk(SongMeaningTab) as SongMeaningTab
	jt.setup(jsong, {})
	await frames()
	ok(jt.missing_lines() == [0, 1] and has_text(jt, "고친 줄"), "U-13 ja: empty-ko line 0 and stale line 1 are missing; stale chip shown")
	var jreq: Dictionary = jt.build_request([0, 1])
	ok((jreq["tasks"] as Array).has("reading") and (jreq["tasks"] as Array).has("tokens") and (jreq["tasks"] as Array).has("gloss") and jreq["lang"] == "ja", "5.1 ja request tasks: reading + translate (+ tokens, gloss for edited lines)")
	var jdone: bool = await jt.make_missing()
	await frames()
	ok(jdone and enrich_count() == 1, "U-13 ja: one request")
	ok(str(jsong["lines"][0]["ko"]) == "번역 0" and str(jsong["lines"][1]["ko"]) == "번역 1" and str(jsong["lines"][2]["ko"]) == "그대로", "U-13 ja: ko filled (also the stale one), untouched line stays")
	ok(str(jsong["lines"][0]["reading"]) == "よみ0" and str(jsong["lines"][0]["pron"]) == "ヨミ0", "U-13 ja: reading / pron from the answer applied")
	ok(not bool(jsong["lines"][1]["stale"]) and (jsong["lines"][1]["words"] as Array).size() == 1 and jsong["glossary"].has("新"), "U-13 ja: stale line is refreshed (words + glossary merged) and stale -> false")
	tab.queue_free()
	jt.queue_free()
	await frames()
	reached["meaning_request"] = true


func _test_meaning_errors() -> void:
	Store.prefs["song_consent"] = true
	# 요청 실패
	enrich_mode = "fail"
	requests.clear()
	var song: Dictionary = install_blank_song("en", 3)
	var tab: SongMeaningTab = mk(SongMeaningTab) as SongMeaningTab
	tab.setup(song, {})
	await frames()
	var done: bool = await tab.make_missing()
	await frames()
	ok(not done and tab.missing_lines().size() == 3 and not tab.busy, "U-13 server error -> nothing applied, not busy")
	ok(has_text(tab, "서버에서 오류가 났어요") or has_text(tab, "해석을 만들지 못했어요"), "U-13 server error -> a Korean message is shown")
	# 오래된 서버 (404)
	var old_tab: SongMeaningTab = mk(SongMeaningTab) as SongMeaningTab
	old_tab.setup(song, {})
	SpeakDrill.api_hook = Callable(self, "_hook_404")
	await old_tab.make_missing()
	await frames()
	ok(has_text(old_tab, "PC 프로그램을 최신 버전으로 업데이트"), "U-13 404 (old PC program) -> '업데이트' guidance")
	SpeakDrill.api_hook = Callable(self, "_hook")
	old_tab.queue_free()
	# 둘째 묶음만 실패: 첫째는 반영
	enrich_mode = "fail2"
	requests.clear()
	var song2: Dictionary = install_blank_song("en", 30)
	var t2: SongMeaningTab = mk(SongMeaningTab) as SongMeaningTab
	t2.setup(song2, {})
	await frames()
	var part: bool = await t2.make_missing()
	await frames()
	ok(part and enrich_count() == 2 and t2.missing_lines().size() == 10, "U-13 second batch fails -> first 20 lines kept, 10 still missing")
	ok(has_text(t2, "20줄은 만들었어요") and str(SongStore.load_song(str(song2["id"]))["lines"][19]["ko"]) == "번역 19", "U-13 partial result is saved and reported")
	# 이상한 응답
	enrich_mode = "garbage"
	requests.clear()
	var song3: Dictionary = install_blank_song("en", 3)
	var t3: SongMeaningTab = mk(SongMeaningTab) as SongMeaningTab
	t3.setup(song3, {})
	await frames()
	var g: bool = await t3.make_missing()
	await frames()
	ok(not g and t3.missing_lines().size() == 3 and not t3.busy, "robust: garbled answer (out-of-range / wrong types / empty ko) -> nothing applied, no crash")
	var direct: int = t3.apply_response("not a dict", [0])
	ok(direct == 0 and t3.apply_response({"lines": "x"}, [0]) == 0 and t3.apply_response({"lines": [{"i": 1, "ko": "요청 안 한 줄"}]}, [0]) == 0, "robust: apply_response ignores non-dict / non-array / lines that were not requested")
	# 취소
	enrich_mode = "slow"
	_gate_open = false
	requests.clear()
	var song4: Dictionary = install_blank_song("en", 4)
	var t4: SongMeaningTab = mk(SongMeaningTab) as SongMeaningTab
	t4.setup(song4, {})
	await frames()
	t4.make_missing() # 기다리지 않는다
	await frames(3)
	ok(t4.busy and enrich_count() == 1 and has_text(t4, "해석 만드는 중"), "U-13 in progress: busy, '해석 만드는 중…' shown")
	ok(press(t4, "취소"), "U-13 [취소] pressable while busy")
	await frames()
	ok(not t4.busy and t4.missing_lines().size() == 4, "U-13 cancel -> not busy")
	_gate_open = true
	gate.emit()
	await frames(4)
	ok(t4.missing_lines().size() == 4 and enrich_count() == 1, "U-13 a late answer after cancel is ignored, no more requests")
	# 화면을 닫으면(on_hide) 요청 취소
	_gate_open = false
	var t5: SongMeaningTab = mk(SongMeaningTab) as SongMeaningTab
	var song5: Dictionary = install_blank_song("en", 2)
	t5.setup(song5, {})
	await frames()
	t5.make_missing()
	await frames(3)
	ok(t5.busy, "setup: second tab busy")
	t5.on_hide()
	ok(not t5.busy, "U-13 on_hide() cancels the running request")
	_gate_open = true
	gate.emit()
	await frames(3)
	enrich_mode = "ok"
	for t in [tab, t2, t3, t4, t5]:
		(t as Node).queue_free()
	await frames()
	reached["meaning_errors"] = true


func _hook_404(_m: String, _p: String, _b: Variant) -> Variant:
	return {"ok": false, "code": 404, "data": null, "error": ""}


func _test_meaning_view() -> void:
	Store.prefs["song_consent"] = true
	var song: Dictionary = ja_song()
	var pl := FakePlayer.new()
	add_child(pl)
	var tab: SongMeaningTab = mk(SongMeaningTab) as SongMeaningTab
	tab.setup(song, {"player": pl, "line": 1})
	await frames()
	var hira: String = "そらをみあげてあるく"
	var hangul: String = KanaHangul.from_pron("ソラヲミアゲテアルク")
	ok(has_text(tab, "空を見上げて歩く") and has_text(tab, "하늘을 올려다보며 걸어요"), "U-13 ja line: original + Korean meaning shown")
	ok(has_text(tab, hira) and hangul != "" and has_text(tab, hangul), "U-13 ja: hiragana + Hangul sound (from pron) shown")
	Store.prefs["show_hangul_ja"] = false
	tab.on_show()
	await frames()
	ok(has_text(tab, hira) and not has_text(tab, hangul), "U-13 show_hangul_ja off -> Hangul gone")
	Store.prefs["show_hangul_ja"] = true
	Store.prefs["show_reading"] = false
	tab.on_show()
	await frames()
	ok(not has_text(tab, hira) and has_text(tab, hangul), "U-13 show_reading off -> hiragana gone")
	Store.prefs["show_reading"] = true
	tab.on_show()
	await frames()
	ok(has_text(tab, "해석이 아직 없어요") and has_text(tab, "해석이 아직 없어요: 1줄"), "U-13 line without ko -> '해석이 아직 없어요' (count 1 in header)")
	# 줄 강조
	var st1: StyleBoxFlat = (tab._panels[1] as PanelContainer).get_theme_stylebox("panel") as StyleBoxFlat
	var st0: StyleBoxFlat = (tab._panels[0] as PanelContainer).get_theme_stylebox("panel") as StyleBoxFlat
	ok(st1.bg_color == Pal.PRIMARY_SOFT and st0.bg_color != Pal.PRIMARY_SOFT, "U-9 current line (1) is highlighted")
	tab.set_line(0)
	var st0b: StyleBoxFlat = (tab._panels[0] as PanelContainer).get_theme_stylebox("panel") as StyleBoxFlat
	var st1b: StyleBoxFlat = (tab._panels[1] as PanelContainer).get_theme_stylebox("panel") as StyleBoxFlat
	ok(st0b.bg_color == Pal.PRIMARY_SOFT and st1b.bg_color != Pal.PRIMARY_SOFT, "U-9 set_line(0) moves the highlight")
	# 플레이어 · 카드
	ok(tab.play_line(0) and pl.played == [[0, 1]], "U-13 [▶ 듣기] -> SongPlayer.play_line(0, 1)")
	var base: int = review_count()
	ok(tab.add_line_card(0) == 1 and review_count() == base + 1 and tab.add_line_card(0) == 0, "U-13 line -> review card once")
	ok(Progress.load_file(TEST_PROGRESS)["review"].size() == review_count(), "U-13 card saved to the progress file")
	# 영어 + [Chorus] 줄: 해석 요구 안 함
	var en: Dictionary = en_song()
	var te: SongMeaningTab = mk(SongMeaningTab) as SongMeaningTab
	te.setup(en, {})
	await frames()
	ok(te.missing_lines() == [2], "U-13 en: only 'Oh yeah' lacks ko ([Chorus] marker is not translated): %s" % str(te.missing_lines()))
	ok(SongMeaningTab.is_translatable({"text": "Hello"}) and not SongMeaningTab.is_translatable({"text": "[Bridge]"}) and not SongMeaningTab.is_translatable({"text": " "}), "U-13 is_translatable rules")
	tab.queue_free()
	te.queue_free()
	pl.queue_free()
	await frames()
	reached["meaning_view"] = true


func _test_pc_rule() -> void:
	SongMeaningTab.pc_hook = Callable() # 진짜 판정 (Route 의 시험 장치로 상황을 만든다)
	Route.pc_ready_hook = Callable(self, "_pc_yes")
	Route.phone_hook = func() -> bool: return true
	Route.mode = "auto"
	Api.base_url = "http://127.0.0.1:9"
	ok(SongMeaningTab.pc_available(), "pc_available: phone + auto + PC ready + address -> true")
	Route.mode = "phone"
	ok(not SongMeaningTab.pc_available(), "pc_available: phone mode (폰만) -> false")
	Route.mode = "auto"
	Route.pc_ready_hook = Callable(self, "_pc_no")
	ok(not SongMeaningTab.pc_available(), "pc_available: PC not ready -> false")
	Route.pc_ready_hook = Callable(self, "_pc_yes")
	Api.base_url = ""
	ok(not SongMeaningTab.pc_available(), "pc_available: phone without a PC address -> false")
	Api.base_url = "http://127.0.0.1:9"
	Route.phone_hook = func() -> bool: return false
	ok(SongMeaningTab.pc_available(), "pc_available: PC app + ready -> true")
	Route.pc_ready_hook = Callable(self, "_pc_no")
	ok(not SongMeaningTab.pc_available(), "pc_available: PC app, engine not ready -> false")
	Route.pc_ready_hook = Callable()
	Route.phone_hook = Callable()
	Route.mode = _saved_route_mode
	SongMeaningTab.pc_hook = Callable(self, "_pc_yes")
	reached["pc_rule"] = true


func _test_layout() -> void:
	# 좁은 화면(폰 412) / 넓은 화면(PC) 안에서 탭마다 가로로 삐져나오지 않고, 폰에서는 누르는 것이 터치 크기 이상이다.
	Store.prefs["song_consent"] = true
	var width: float = 412.0 if phone else 900.0
	var host := Control.new()
	host.custom_minimum_size = Vector2(width, 10)
	host.size = Vector2(width, 800)
	add_child(host)
	var song: Dictionary = en_song()
	var jsong: Dictionary = ja_song()
	var pl := FakePlayer.new()
	add_child(pl)
	var tabs: Array = []
	var w1: SongWordsTab = SongWordsTab.new()
	var c1: SongClozeTab = SongClozeTab.new()
	var d1: SongDictationTab = SongDictationTab.new()
	var m1: SongMeaningTab = SongMeaningTab.new()
	for t in [w1, c1, d1, m1]:
		host.add_child(t as Node)
		tabs.append(t)
	w1.setup(song, {"player": pl})
	w1.toggle_word("sparrow")
	c1.setup(song, {"player": pl})
	c1.set_answer(0, "x")
	c1.check(false)
	d1.setup(song, {"player": pl})
	d1.set_typed("a long wrong sentence about birds and rivers")
	d1.check(false)
	m1.setup(install_blank_song("en", 3), {"player": pl})
	await frames(3)
	var worst := 0.0
	for t in tabs:
		worst = maxf(worst, (t as Control).get_combined_minimum_size().x)
	ok(worst <= width, "U-2 no tab needs more than %d px of width (widest %.0f)" % [int(width), worst])
	var small := 0
	var total := 0
	for t in tabs:
		for b in (t as Node).find_children("*", "Button", true, false):
			total += 1
			if phone and (b as Button).custom_minimum_size.y < Ds.touch_min() - 0.5:
				small += 1
	ok(total > 10, "U-2 buttons found in the tabs (%d)" % total)
	if phone:
		ok(small == 0, "U-2 phone: every button is at least Ds.touch_min() (%.0f) tall (%d too small)" % [Ds.touch_min(), small])
	else:
		ok(true, "U-2 pc: touch size not checked")
	# 일본어 · 영어 곡 모두 다시 그려도 예외 없음
	w1.setup(jsong, {})
	c1.setup(jsong, {})
	d1.setup(jsong, {})
	m1.setup(jsong, {})
	await frames(2)
	ok(is_instance_valid(w1) and w1.get_child_count() > 0 and c1.get_child_count() > 0 and d1.get_child_count() > 0 and m1.get_child_count() > 0, "U-2 all four tabs render a ja song")
	# 깨진 곡을 줘도 죽지 않는다
	var junk: Array = [{}, {"lang": "xx"}, {"lines": "x"}, {"lang": "en", "lines": [1, "a", null, {"text": 5, "words": "x"}]}]
	var survive := true
	for jk in junk:
		for t in tabs:
			(t as Node).call("setup", jk, {})
		await frames(1)
		for t in tabs:
			if not is_instance_valid(t):
				survive = false
	ok(survive, "robust: empty / broken song dictionaries -> all tabs survive setup")
	host.queue_free()
	pl.queue_free()
	await frames()
	reached["layout"] = true
