extends Node
## G6: SongStudy (빈칸 · 모르는 단어 · 카드 항목 · 받아쓰기 · 노래 점수) + SongSingDrill (docs/song_study_design.md 5.4, 6, 8 G6).
##   godot --headless --path <project> res://tests/song_study_test.tscn
## Exit code 0 = all checks passed. Last line: "== song_study_test result: N passed, 0 failed ==".
## 서버 · 네트워크 없음: 채점 요청은 SpeakDrill.api_hook 으로 가로챈다. 가사는 모두 이 파일에서 직접 쓴 문장이다.
## 진행 기록 · 학습 기록은 user://song_study_test_* 로 돌리고 끝에 되돌린다 (실제 사용자 폴더는 건드리지 않는다).

const TEST_PROGRESS := "user://song_study_test_progress.json"
const TEST_LOG := "user://song_study_test_studylog.json"
const SCORE_FIX := "res://tests/sample_score.json"
const FAKE_REC := {"b64": "AAAA", "duration": 1.2, "ok": true, "silent": false}
const SECTIONS := ["cloze_en", "cloze_ja", "cards", "sync_shape", "limit", "score", "sing_drill", "dictation", "robust"]

var passed: int = 0
var failed: int = 0
var reached: Dictionary = {}
var requests: Array = []
var score_resp: Variant = null
var tts_calls: Array = []
var scored_n: int = 0
var silent_n: int = 0
var hook_scores: Array = []

var _saved_prefs: Dictionary = {}
var _saved_progress: Dictionary = {}
var _saved_progress_path: String = ""
var _saved_log_path: String = ""
var _saved_base: String = ""


func ok(cond: bool, name: String) -> void:
	if cond:
		passed += 1
		print("  PASS  ", name)
	else:
		failed += 1
		print("  FAIL  ", name)


func _ready() -> void:
	print("== song_study_test start ==")
	_setup()
	await _run()
	_teardown()
	for s in SECTIONS:
		ok(reached.has(s), "section '%s' ran to its end" % s)
	print("== song_study_test result: %d passed, %d failed ==" % [passed, failed])
	get_tree().quit(1 if failed > 0 else 0)


# ---------------------------------------------------------------- setup

func _setup() -> void:
	_saved_prefs = Store.prefs.duplicate(true)
	_saved_progress = Store.progress.duplicate(true)
	_saved_progress_path = Store.progress_path
	_saved_log_path = StudyLog.path
	_saved_base = Api.base_url
	Store.progress_path = TEST_PROGRESS
	Store.progress = Progress.blank()
	StudyLog.path = TEST_LOG
	StudyLog.load_from_disk()
	StudyLog.reset()
	Store.prefs["lang"] = "en"
	Store.prefs.erase("hide_prosody")
	Api.base_url = "http://127.0.0.1:9" # 닫힌 포트: 실수로 서버에 닿지 않게
	SpeakDrill.api_hook = Callable(self, "_hook")
	SpeakDrill.score_hook = Callable(self, "_on_score_hook")
	Tts.fetch_hook = Callable(self, "_tts_hook")


func _teardown() -> void:
	SpeakDrill.api_hook = Callable()
	SpeakDrill.score_hook = Callable()
	Tts.fetch_hook = Callable()
	Tts.stop()
	StudyLog.reset()
	StudyLog.path = _saved_log_path
	Store.progress_path = _saved_progress_path
	Store.progress = _saved_progress
	Api.base_url = _saved_base
	for f in [TEST_PROGRESS, TEST_LOG, TEST_LOG + ".bad"]:
		if FileAccess.file_exists(f):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(f))
	Store.prefs = _saved_prefs
	Store.save_prefs()


func _hook(method: String, path: String, body: Variant) -> Variant:
	requests.append({"method": method, "path": path, "body": body})
	if path.begins_with("/score"):
		return {"ok": true, "code": 200, "data": score_resp, "error": ""}
	return {"ok": false, "code": 404, "data": null, "error": "알 수 없는 경로예요."}


func _on_score_hook(l: String, res: Dictionary, src: String, _counted: bool) -> void:
	hook_scores.append({"lang": l, "score": res.get("score", 0), "source": src})


func _tts_hook(text: String, l: String, speed: float, _voice: String) -> Variant:
	tts_calls.append({"text": text, "lang": l, "speed": speed})
	return null


func frames(n: int = 3) -> void:
	for i in n:
		await get_tree().process_frame


func wait_until(cond: Callable, max_frames: int = 120) -> bool:
	for i in max_frames:
		if cond.call():
			return true
		await get_tree().process_frame
	return bool(cond.call())


func reqs(prefix: String) -> int:
	var n := 0
	for r in requests:
		if str((r as Dictionary)["path"]).begins_with(prefix):
			n += 1
	return n


func has_label(node: Node, needle: String) -> bool:
	if node is Label and (node as Label).text.find(needle) >= 0:
		return true
	if node is RichTextLabel and (node as RichTextLabel).get_parsed_text().find(needle) >= 0:
		return true
	for c in node.get_children():
		if has_label(c, needle):
			return true
	return false


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
			{"i": 5, "text": "It sits near the window", "ko": "창가에 앉아 있어요", "reading": "", "words": [
				W("It", "it", false), W("sits", "sit", true, "easy", 4.5), W("near", "near", true, "easy", 4.8),
				W("the", "the", false), W("window", "window", true, "easy", 4.9)]},
			{"i": 6, "text": "x".repeat(400), "ko": "", "reading": "", "words": []},
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
			{"i": 0, "text": "空を見上げて歩く", "ko": "하늘을 올려다보며 걸어요", "reading": "そらをみあげてあるく", "words": [
				W("空", "空", true, "easy", 4.5, {"reading": "そら"}), W("を", "を", false, "easy", 7.0, {"reading": "を"}),
				W("見上げて", "見上げる", true, "mid", 3.6, {"reading": "みあげて"}), W("歩く", "歩く", true, "easy", 4.4, {"reading": "あるく"})]},
			{"i": 1, "text": "小さな花が咲いた", "ko": "작은 꽃이 피었어요", "reading": "ちいさなはながさいた", "words": [
				W("小さな", "小さい", true, "easy", 4.2, {"reading": "ちいさな"}), W("花", "花", true, "easy", 4.6, {"reading": "はな"}),
				W("が", "が", false, "easy", 7.0, {"reading": "が"}), W("咲いた", "咲く", true, "mid", 3.4, {"reading": "さいた"})]},
			{"i": 2, "text": "ねえ、ねえ", "ko": "", "reading": "ねえねえ", "words": [W("ねえ", "ねえ", false), W("ねえ", "ねえ", false)]},
		],
		"glossary": {
			"空": {"pos": "명사", "ko": "하늘", "ipa": "", "pron": ""},
			"咲く": {"pos": "동사", "ko": "피다", "ipa": "", "pron": ""},
		},
	}


func blank_answers(c: Dictionary) -> Array:
	var out: Array = []
	for b in c["blanks"]:
		out.append(str((b as Dictionary)["answer"]))
	return out


# ---------------------------------------------------------------- run

func _run() -> void:
	_test_cloze_en()
	_test_cloze_ja()
	_test_cards()
	_test_sync_shape()
	_test_limit()
	_test_score()
	await _test_sing_drill()
	_test_dictation()
	_test_robust()


func _test_cloze_en() -> void:
	var song: Dictionary = en_song()
	# 같은 seed 는 같은 결과
	var same := true
	for sd in [0, 1, 7, 123456, -5]:
		var a: Dictionary = SongStudy.cloze(song, 0, 2, sd)
		var b: Dictionary = SongStudy.cloze(song, 0, 2, sd)
		if JSON.stringify(a) != JSON.stringify(b):
			same = false
	ok(same, "G6-2 same seed -> identical cloze (5 seeds)")
	# 난이도 1/2/3 = 빈칸 1/2/3
	var counts: Array = []
	for lv in [1, 2, 3]:
		counts.append((SongStudy.cloze(song, 0, lv, 11)["blanks"] as Array).size())
	ok(counts == [1, 2, 3], "G6-2 level 1/2/3 -> 1/2/3 blanks (got %s)" % str(counts))
	var c3: Dictionary = SongStudy.cloze(song, 0, 3, 5)
	ok(bool(c3["ok"]) and str(c3["prompt"]).count(SongStudy.BLANK) == 3, "G6-2 prompt has one ____ per blank")
	# 빈칸에 정답을 되돌려 넣으면 원문
	var parts: PackedStringArray = str(c3["prompt"]).split(SongStudy.BLANK)
	var joined: String = parts[0]
	var k := 0
	for b2 in c3["blanks"]:
		k += 1
		joined += str((b2 as Dictionary)["answer"]) + parts[k]
	ok(joined == "Silver rivers carry golden sunlight", "G6-2 prompt with the answers put back == original line")
	# 단어가 모자라면 가능한 만큼 (후보 2개인 줄에 level 3)
	var c_short: Dictionary = SongStudy.cloze(song, 4, 3, 2)
	ok((c_short["blanks"] as Array).size() == 2 and bool(c_short["ok"]), "G6-2 level 3 on a 2-candidate line -> 2 blanks")
	ok((SongStudy.cloze(song, 0, 0, 1)["blanks"] as Array).size() == 1 and (SongStudy.cloze(song, 0, 99, 1)["blanks"] as Array).size() == 3, "G6-2 level 0 -> 1 blank, level 99 -> 3 blanks (clamped)")
	# 불용어 · content:false 제외 (여러 seed)
	var bad_hit := false
	for sd in 40:
		for li in [1, 3, 5]:
			for a2 in blank_answers(SongStudy.cloze(song, li, 3, sd)):
				if ["I", "can't", "the", "on", "It", "and", "Oh", "yeah"].has(a2):
					bad_hit = true
	ok(not bad_hit, "G6-2 stopwords / content:false never become blanks (40 seeds x 3 lines)")
	var oh: Dictionary = SongStudy.cloze(song, 2, 2, 1)
	ok(not bool(oh["ok"]) and (oh["blanks"] as Array).is_empty() and str(oh["prompt"]) == "Oh yeah, oh yeah", "G6-2 line with no usable word -> ok:false, prompt = original")
	# 문법어인데 content 표시가 없어도 불용어 목록으로 거른다
	var raw_song: Dictionary = {"lang": "en", "lines": [{"text": "The river and the morning", "words": [
		{"w": "The", "lemma": "the"}, {"w": "river", "lemma": "river"}, {"w": "and", "lemma": "and"}, {"w": "the", "lemma": "the"}, {"w": "morning", "lemma": "morning"}]}]}
	var rs_hit := false
	for sd in 20:
		for a3 in blank_answers(SongStudy.cloze(raw_song, 0, 3, sd)):
			if a3.to_lower() == "the" or a3.to_lower() == "and":
				rs_hit = true
	ok(not rs_hit and (SongStudy.cloze(raw_song, 0, 3, 1)["blanks"] as Array).size() == 2, "G6-2 stopword list works without content flags (the/and skipped, 2 blanks left)")
	# 아는 단어 제외
	var known := {"silver": true, "river": true, "carry": true, "golden": true}
	var ck: Dictionary = SongStudy.cloze(song, 0, 3, 9, known)
	ok(blank_answers(ck) == ["sunlight"], "G6-2 known words are never blanked (only 'sunlight' left: %s)" % str(blank_answers(ck)))
	var all_known: Dictionary = {"silver": true, "river": true, "carry": true, "golden": true, "sunlight": true}
	ok(not bool(SongStudy.cloze(song, 0, 1, 9, all_known)["ok"]), "G6-2 every word known -> ok:false")
	# seed 마다 다른 선택이 나올 수 있다
	var seen := {}
	for sd in 30:
		seen[JSON.stringify(blank_answers(SongStudy.cloze(song, 0, 1, sd)))] = true
	ok(seen.size() >= 3, "G6-2 different seeds pick different words (%d distinct of 30)" % seen.size())
	# 빈칸 위치가 실제 글자와 맞다 (it 가 sits 안에 있어도 엉뚱한 곳을 잡지 않는다)
	var c_sit: Dictionary = SongStudy.cloze(song, 5, 3, 3)
	var sit_ok := true
	var text5: String = "It sits near the window"
	for b3 in c_sit["blanks"]:
		var bb: Dictionary = b3
		var st: int = int(bb["start"])
		if text5.substr(st, str(bb["answer"]).length()) != str(bb["answer"]):
			sit_ok = false
	ok(sit_ok and (c_sit["blanks"] as Array).size() == 3, "G6-2 blank positions point at the right text (3 blanks)")
	# alts: 대문자 · ' 변형
	var sp: Dictionary = {}
	for sd in 60:
		var cc: Dictionary = SongStudy.cloze(song, 1, 3, sd)
		for b4 in cc["blanks"]:
			if str((b4 as Dictionary)["answer"]) == "sparrow's":
				sp = b4
		if not sp.is_empty():
			break
	ok(not sp.is_empty(), "G6-2 (setup) a blank for \"sparrow's\" was produced")
	var alts: Array = sp.get("alts", [])
	ok(alts.has("Sparrow's") and alts.has("SPARROW'S") and alts.has("sparrow’s") and alts.has("sparrows") and not alts.has("sparrow's"), "G6-2 alts hold capital / curly-apostrophe / no-apostrophe forms, not the answer itself")
	ok(SongStudy.check_blank("en", sp, "SPARROW'S")["ok"] and SongStudy.check_blank("en", sp, "Sparrow’s")["ok"] and SongStudy.check_blank("en", sp, "sparrows")["ok"] and SongStudy.check_blank("en", sp, " sparrow's, ")["ok"], "G6-2 check_blank accepts case / apostrophe variants and surrounding punctuation")
	ok(not SongStudy.check_blank("en", sp, "sparow")["ok"] and not SongStudy.check_blank("en", sp, "")["ok"] and not SongStudy.check_blank("en", sp, "tiny")["ok"], "G6-2 check_blank rejects typo / empty / another word")
	# 보기
	var opt_ok := true
	for sd in 20:
		var co: Dictionary = SongStudy.cloze(song, 0, 2, sd)
		for b5 in co["blanks"]:
			var opts: Array = (b5 as Dictionary)["options"]
			var uniq := {}
			for o in opts:
				uniq[str(o).to_lower()] = true
			if not opts.has((b5 as Dictionary)["answer"]) or opts.size() > SongStudy.OPTION_COUNT or opts.size() < 2 or uniq.size() != opts.size():
				opt_ok = false
	ok(opt_ok, "G6-2 options: contain the answer, 2..4 entries, no duplicates (20 seeds)")
	reached["cloze_en"] = true


func _test_cloze_ja() -> void:
	var song: Dictionary = ja_song()
	var c: Dictionary = SongStudy.cloze(song, 0, 3, 4)
	ok((c["blanks"] as Array).size() == 3 and bool(c["ok"]), "G6-3 ja level 3 -> 3 blanks (particle を excluded)")
	var part_hit := false
	for sd in 40:
		for li in [0, 1]:
			for a in blank_answers(SongStudy.cloze(song, li, 3, sd)):
				if ["を", "が", "ねえ"].has(a):
					part_hit = true
	ok(not part_hit, "G6-3 ja particles / content:false never blanked (40 seeds)")
	var c1: Dictionary = {}
	for sd in 40:
		var cc: Dictionary = SongStudy.cloze(song, 0, 1, sd)
		if blank_answers(cc) == ["見上げて"]:
			c1 = cc
			break
	ok(not c1.is_empty(), "G6-3 (setup) a blank for 見上げて was produced")
	var b: Dictionary = (c1["blanks"] as Array)[0] if not c1.is_empty() else {}
	ok(str(b.get("reading", "")) == "みあげて" and (b.get("alts", []) as Array).has("みあげて"), "G6-3 ja blank keeps the reading (みあげて) and lists it in alts")
	var p1: String = str(c1.get("prompt", ""))
	ok(p1 == "空を____歩く", "G6-3 ja prompt text (%s)" % p1)
	ok(SongStudy.check_blank("ja", b, "見上げて")["ok"], "G6-3 ja: the written form (kanji) is correct")
	ok(SongStudy.check_blank("ja", b, "みあげて")["ok"], "G6-3 ja: the reading (hiragana) is correct")
	ok(not SongStudy.check_blank("ja", b, "あるく")["ok"] and not SongStudy.check_blank("ja", b, "")["ok"], "G6-3 ja: wrong word / empty is wrong")
	var direct: Dictionary = TextSim.similarity("みあげて", "見上げて", "みあげて", "ja")
	ok(int(SongStudy.check_blank("ja", b, "みあげて")["score"]) == int(direct["score"]), "G6-3 ja score comes from TextSim.similarity (%d)" % int(direct["score"]))
	ok(not SongStudy.check_blank("ja", b, "み")["ok"], "G6-3 ja: a single matching kana is not enough")
	reached["cloze_ja"] = true


func _test_cards() -> void:
	var song: Dictionary = en_song()
	var lc: Dictionary = SongStudy.line_card(song, 1)
	ok(lc.keys().size() == 5 and lc["lang"] == "en" and lc["target"] == "I can't forget the sparrow's tiny song" and lc["reading"] == "" and lc["ko"] == "참새의 작은 노래를 잊을 수 없어요", "G6-4 line_card (en) has lang/target/reading/ko/note")
	ok(str(lc["note"]) == "♪ Paper Boats – Test Band" and str(lc["note"]).begins_with("♪ ") and str(lc["note"]).length() <= 300, "G6-4 line_card note = '♪ 제목 – 가수'")
	var jl: Dictionary = SongStudy.line_card(ja_song(), 0)
	ok(jl["lang"] == "ja" and jl["target"] == "空を見上げて歩く" and jl["reading"] == "そらをみあげてあるく" and str(jl["note"]).begins_with("♪ そらのうた"), "G6-4 line_card (ja) carries the hiragana reading")
	var wc: Dictionary = SongStudy.word_card(song, "sparrow")
	ok(wc["lang"] == "en" and wc["target"] == "sparrow" and wc["reading"] == "ˈspæroʊ" and wc["ko"] == "참새", "G6-4 word_card (en): lemma / IPA / meaning")
	ok(str(wc["note"]) == "♪ Paper Boats · \"I can't forget the sparrow's tiny song\"", "G6-4 word_card note = ♪ title · \"line start\" (%s)" % str(wc["note"]))
	var wl: Dictionary = SongStudy.word_card(ja_song(), "空")
	ok(wl["lang"] == "ja" and wl["target"] == "空" and wl["reading"] == "そら" and wl["ko"] == "하늘" and str(wl["note"]).begins_with("♪ そらのうた · \""), "G6-4 word_card (ja): reading comes from the word")
	var wv: Dictionary = SongStudy.word_card(ja_song(), "咲く")
	ok(wv["target"] == "咲いた" and wv["reading"] == "さいた" and wv["ko"] == "피다", "G6-4 word_card (ja, conjugated verb): card uses the surface form so target and reading match")
	var long_song: Dictionary = en_song()
	(long_song["lines"] as Array)[0]["text"] = "Silver rivers carry golden sunlight over the long, long hills tonight"
	var wlong: Dictionary = SongStudy.word_card(long_song, "silver")
	ok(str(wlong["note"]).ends_with("…\"") and str(wlong["note"]).length() <= 300, "G6-4 long line is cut to 40 chars + …")
	ok(SongStudy.word_card(song, "Silver")["target"] == "silver" and SongStudy.word_card(song, "nothere").is_empty() and SongStudy.word_card(song, "").is_empty(), "G6-4 word_card is case-insensitive; unknown / empty lemma -> {}")
	var longline: Dictionary = SongStudy.line_card(song, 6)
	ok(str(longline["target"]).length() == 300, "G6-4 line_card target cut to 300 (got %d)" % str(longline["target"]).length())
	var title_long: Dictionary = en_song()
	title_long["title"] = "T".repeat(500)
	title_long["artist"] = "A".repeat(500)
	ok(str(SongStudy.line_card(title_long, 0)["note"]).length() <= 300 and str(SongStudy.word_card(title_long, "carry")["note"]).length() <= 300, "G6-4 notes stay <= 300 even with huge title / artist")
	var ctl: Dictionary = en_song()
	(ctl["lines"] as Array)[0]["text"] = "Silver\nrivers\tcarry"
	ok(SongStudy.line_card(ctl, 0)["target"] == "Silver rivers carry", "G6-4 control characters in the line become spaces")
	var no_artist: Dictionary = en_song()
	no_artist["artist"] = ""
	ok(SongStudy.line_card(no_artist, 0)["note"] == "♪ Paper Boats", "G6-4 note without an artist has no dash")
	# Store.add_review 에 넣어 본다
	Store.progress = Progress.blank()
	var items: Array = [lc, jl, wc, wl]
	var added: int = Store.add_review(items)
	ok(added == 4, "G6-4 Store.add_review takes the 4 card items (added %d)" % added)
	ok(Store.add_review(items) == 0, "G6-4 adding the same items again adds 0")
	var res2: Dictionary = SongStudy.add_cards(items)
	ok(int(res2["added"]) == 0 and int(res2["skipped"]) == 4 and int(res2["trimmed"]) == 0 and int(res2["total"]) == 4, "G6-4 add_cards on duplicates -> added 0, skipped 4")
	var res3: Dictionary = SongStudy.add_cards([SongStudy.line_card(song, 0), SongStudy.word_card(song, "lantern"), {}, {"lang": "fr", "target": "x"}])
	ok(int(res3["added"]) == 2 and int(res3["skipped"]) == 2 and int(res3["total"]) == 6, "G6-4 add_cards skips empty / bad-language items (added 2, skipped 2)")
	var rv: Array = Store.progress["review"]
	ok(str((rv[0] as Dictionary)["note"]) == str(lc["note"]) and str((rv[2] as Dictionary)["note"]).begins_with("♪ "), "G6-4 stored cards keep the ♪ note")
	reached["cards"] = true


func _test_sync_shape() -> void:
	# 복습 카드가 동기화의 clean_card 를 그대로 통과한다 (모양이 바뀌지 않는다)
	var rv: Array = Store.progress["review"]
	var all_ok := true
	for r in rv:
		var rd: Dictionary = r
		var cc: Dictionary = SyncDoc.clean_card(rd, "")
		if cc.is_empty() or cc["lang"] != rd["lang"] or cc["target"] != rd["target"] or cc["reading"] != rd["reading"] or cc["ko"] != rd["ko"] or cc["note"] != rd["note"]:
			all_ok = false
		if cc.get("key", "") != SyncDoc.card_key(str(rd["lang"]), str(rd["target"])):
			all_ok = false
	ok(rv.size() == 6 and all_ok, "G6-4 every song card passes SyncDoc.clean_card unchanged (lang/target/reading/ko/note) (%d cards)" % rv.size())
	var view: Dictionary = SyncDoc.extract(Store.progress, StudyLog.snapshot(), Store.prefs, 0)
	var cards: Array = view["cards"]
	var notes_ok := cards.size() == 6
	for cd in cards:
		if not str((cd as Dictionary)["note"]).begins_with("♪ "):
			notes_ok = false
	ok(notes_ok, "G6-4 SyncDoc.extract keeps all 6 cards with their ♪ notes")
	# 비교용: 이상한 모양은 clean_card 가 걸러 낸다 (검사가 실제로 실패할 수 있다)
	ok(SyncDoc.clean_card({"lang": "fr", "target": "x", "note": "♪ x"}, "").is_empty(), "G6-4 (control) clean_card rejects a card with a bad language")
	reached["sync_shape"] = true


func _test_limit() -> void:
	# 카드 수 한도: 3000 장이 차 있으면 새 카드가 들어오고 가장 오래된 카드가 밀려난다 -> trimmed 로 알린다
	Store.progress = Progress.blank()
	var seed_items: Array = []
	for i in Progress.MAX_REVIEW:
		seed_items.append({"lang": "en", "target": "filler %d" % i, "reading": "", "ko": "", "note": ""})
	var n0: int = Store.add_review(seed_items)
	ok(n0 == Progress.MAX_REVIEW and (Store.progress["review"] as Array).size() == Progress.MAX_REVIEW, "G6-4 (setup) review is full (%d cards)" % n0)
	var res: Dictionary = SongStudy.add_cards([SongStudy.line_card(en_song(), 0), SongStudy.word_card(en_song(), "lantern")])
	ok(int(res["added"]) == 2 and int(res["trimmed"]) == 2 and int(res["total"]) == Progress.MAX_REVIEW, "G6-4 full review: 2 added, 2 oldest trimmed, total stays 3000")
	var rv: Array = Store.progress["review"]
	ok(str((rv[rv.size() - 1] as Dictionary)["target"]) == "lantern" and str((rv[0] as Dictionary)["target"]) == "filler 2", "G6-4 the newest card is kept and the oldest were dropped")
	Store.progress = Progress.blank()
	reached["limit"] = true


func _test_score() -> void:
	ok(SongStudy.song_score({"accuracy": 90, "clarity": 80, "fluency": 40}) == 87, "G6-5 {90, 80, fluency 40} -> 87")
	ok(SongStudy.song_score({"accuracy": 0, "clarity": 0}) == 0, "G6-5 {0, 0} -> 0")
	ok(SongStudy.song_score({"accuracy": 100, "clarity": 100, "fluency": 0}) == 100, "G6-5 {100, 100, fluency 0} -> 100 (fluency does not count)")
	ok(SongStudy.song_score({"accuracy": 90.0, "clarity": 80.0}) == 87, "G6-5 float input -> 87")
	ok(SongStudy.song_score({}) == 0 and SongStudy.song_score({"score": 99}) == 0, "G6-5 missing keys -> 0")
	ok(SongStudy.song_score({"accuracy": 90}) == 64 and SongStudy.song_score({"clarity": 80}) == 24, "G6-5 one key missing counts as 0 (64 / 24)")
	ok(SongStudy.song_score({"accuracy": -40, "clarity": -3}) == 0, "G6-5 negative -> 0")
	ok(SongStudy.song_score({"accuracy": 500, "clarity": 900}) == 100, "G6-5 over 100 is clamped -> 100")
	ok(SongStudy.song_score({"accuracy": "90", "clarity": "80"}) == 0 and SongStudy.song_score({"accuracy": "abc", "clarity": null}) == 0, "G6-5 string / null values -> 0")
	ok(SongStudy.song_score({"accuracy": NAN, "clarity": INF}) == 0 and SongStudy.song_score({"accuracy": [90], "clarity": {"a": 1}}) == 0, "G6-5 NaN / Inf / array / dict values -> 0")
	ok(SongStudy.song_score(null) == 0 and SongStudy.song_score("x") == 0 and SongStudy.song_score([1]) == 0, "G6-5 non-dictionary input -> 0, no error")
	var fuzz_ok := true
	for a in [-1e9, -1, 0, 1, 33.3, 50, 99.5, 100, 101, 1e9]:
		for c in [-1e9, 0, 49, 100, 1e9]:
			var s: int = SongStudy.song_score({"accuracy": a, "clarity": c})
			if s < 0 or s > 100:
				fuzz_ok = false
	ok(fuzz_ok, "G6-5 any numeric input stays inside 0..100 (50 combinations)")
	reached["score"] = true


func _test_sing_drill() -> void:
	var fix: Variant = JSON.parse_string(FileAccess.get_file_as_string(SCORE_FIX))
	ok(fix is Dictionary and (fix as Dictionary).get("units", null) is Array, "G6-6 (setup) score fixture loaded")
	var resp: Dictionary = (fix as Dictionary).duplicate(true)
	resp["accuracy"] = 90
	resp["clarity"] = 80
	resp["fluency"] = 40
	resp["score"] = 55 # 서버가 유창성까지 넣어 낸 점수
	score_resp = resp
	var drill := SongSingDrill.new("en")
	add_child(drill)
	drill.scored.connect(func(_r: Dictionary, _t: String) -> void: scored_n += 1)
	drill.silent_result.connect(func(_t: String) -> void: silent_n += 1)
	ok(drill is SpeakDrill and drill.source == "song" and drill.show_prosody == false and drill.lang == "en", "G6-6 SongSingDrill extends SpeakDrill; source 'song'; show_prosody false")
	drill.set_target("Silver rivers carry golden sunlight", "", "은빛 강")
	drill.listen()
	drill.listen(true, "carry")
	await frames(2)
	ok(tts_calls.is_empty(), "G6-6 listen() does not read the lyric aloud (SongPlayer plays the song)")
	var base_log: Dictionary = StudyLog.range_summary("en", 1)[0]
	drill._on_recorded(FAKE_REC)
	var done: bool = await wait_until(func() -> bool: return drill.status != "scoring")
	ok(done and drill.status == "ok", "G6-6 a valid /score response -> status ok")
	ok(int(drill.result.get("score", -1)) == 87 and int(drill.result.get("score_raw", -1)) == 55, "G6-6 result.score == 87 (server said 55, kept as score_raw)")
	ok(scored_n == 1 and silent_n == 0, "G6-6 'scored' emitted exactly once, no silent_result (scored %d)" % scored_n)
	var log_now: Dictionary = StudyLog.range_summary("en", 1)[0]
	ok(int(log_now["score_n"]) == int(base_log["score_n"]) + 1 and int(log_now["score_sum"]) == int(base_log["score_sum"]) + 87, "G6-6 StudyLog got one score entry of 87")
	ok(hook_scores.size() == 1 and int(hook_scores[0]["score"]) == 87 and hook_scores[0]["source"] == "song", "G6-6 score_hook saw source 'song' and 87")
	ok(reqs("/score") == 1 and reqs("/prosody") == 0, "G6-6 one /score call, /prosody never called (lang en)")
	ok(has_label(drill, SongSingDrill.REF_NOTE), "G6-6 the 'reference only' note is shown with the score")
	# 무음 응답
	score_resp = {"transcript": "", "score": 0, "accuracy": 0, "clarity": 0, "fluency": 0, "units": [], "tips_ko": []}
	drill.set_target("Silver rivers carry golden sunlight")
	drill._on_recorded(FAKE_REC)
	await wait_until(func() -> bool: return drill.status != "scoring")
	ok(drill.status == "silent" and silent_n == 1 and scored_n == 1, "G6-6 transcript '' -> silent_result (silent %d, scored %d)" % [silent_n, scored_n])
	ok(int(StudyLog.range_summary("en", 1)[0]["score_n"]) == int(log_now["score_n"]), "G6-6 a silent answer adds nothing to StudyLog")
	ok(has_label(drill, SpeakDrill.SILENT_TEXT) and not has_label(drill, SongSingDrill.REF_NOTE), "G6-6 silent state shows the usual 'no sound' notice")
	# 이상한 응답 (units 없음)
	score_resp = {"transcript": "hello", "score": 80, "accuracy": 80, "clarity": 80}
	drill.set_target("hello")
	drill._on_recorded(FAKE_REC)
	await wait_until(func() -> bool: return drill.status != "scoring")
	ok(drill.status == "silent" and silent_n == 2 and scored_n == 1, "G6-6 response without units -> silent_result")
	# 직접 apply_score
	var direct: bool = drill.apply_score(resp)
	ok(direct and int(drill.result["score"]) == 87 and scored_n == 2, "G6-6 apply_score(valid) returns true and re-scores to 87")
	ok(not drill.apply_score(null) and not drill.apply_score({}) and not drill.apply_score("x"), "G6-6 apply_score(null / {} / string) -> false, no error")
	drill.stop_all()
	drill.queue_free()
	await frames(2)
	# 일본어도 억양 요청은 없다
	var jd := SongSingDrill.new("ja")
	add_child(jd)
	score_resp = resp
	var before_pros: int = reqs("/prosody")
	jd.set_target("空を見上げて歩く", "そらをみあげてあるく", "")
	jd._on_recorded(FAKE_REC)
	await wait_until(func() -> bool: return jd.status != "scoring")
	ok(jd.status == "ok" and int(jd.result["score"]) == 87 and reqs("/prosody") == before_pros, "G6-6 ja drill: 87, still no /prosody call")
	jd.queue_free()
	await frames(2)
	reached["sing_drill"] = true


func _test_dictation() -> void:
	var line_en: Dictionary = {"text": "Silver rivers carry golden sunlight", "reading": ""}
	var inputs: Array = ["Silver rivers carry golden sunlight", "silver rivers carry sunlight", "Silver river carry golden sunlite", "totally different words here", ""]
	var same := true
	for s in inputs:
		var a: Dictionary = SongStudy.dictation_score("en", s, line_en)
		var b: Dictionary = DictationDiff.diff(s, str(line_en["text"]))
		if int(a["score"]) != int(b["score"]):
			same = false
	ok(same, "G6-7 en: score equals DictationDiff.diff for 5 inputs")
	ok(int(SongStudy.dictation_score("en", "silver RIVERS carry golden sunlight!", line_en)["score"]) == 100, "G6-7 en: case / punctuation ignored -> 100")
	ok(int(SongStudy.dictation_score("en", "", line_en)["score"]) == 0 and int(SongStudy.dictation_score("en", "silver", "Silver rivers carry golden sunlight")["score"]) < 50, "G6-7 en: empty -> 0; a String target works too")
	var ja_line: Dictionary = {"text": "空を見上げて歩く", "reading": "そらをみあげてあるく"}
	ok(int(SongStudy.dictation_score("ja", "空を見上げて歩く", ja_line)["score"]) == 100, "G6-7 ja: exact -> 100")
	ok(int(SongStudy.dictation_score("ja", "", ja_line)["score"]) == 0 and int(SongStudy.dictation_score("ja", "  \n", ja_line)["score"]) == 0, "G6-7 ja: empty / blank string -> 0")
	ok(int(SongStudy.dictation_score("ja", "そらをみあげてあるく", ja_line)["score"]) == 100, "G6-7 ja: typing the reading (hiragana) also scores 100")
	var part: Dictionary = SongStudy.dictation_score("ja", "空を歩く", ja_line)
	var ref: Dictionary = TextSim.similarity("空を歩く", "空を見上げて歩く", "そらをみあげてあるく", "ja")
	ok(int(part["score"]) == int(ref["score"]) and int(part["score"]) > 0 and int(part["score"]) < 100, "G6-7 ja: partial answer = TextSim.similarity (%d)" % int(part["score"]))
	ok(int(SongStudy.dictation_score("ja", "あいうえお", {"text": "", "reading": ""})["score"]) == 0, "G6-7 ja: empty target -> 0")
	ok(int(SongStudy.dictation_score("ja", null, ja_line)["score"]) == 0 and int(SongStudy.dictation_score("en", null, null)["score"]) == 0, "G6-7 null input -> 0, no error")
	reached["dictation"] = true


func _test_robust() -> void:
	var song: Dictionary = en_song()
	for bad in [null, {}, "x", 5, [], {"lang": "fr", "lines": []}, {"lang": "en"}, {"lang": "en", "lines": "no"}, {"lang": "en", "lines": [5, null]}]:
		var c: Dictionary = SongStudy.cloze(bad, 0, 2, 1)
		ok(not bool(c["ok"]) and (c["blanks"] as Array).is_empty(), "robust: cloze(%s) -> ok:false, no error" % str(bad).left(24))
	ok(not bool(SongStudy.cloze(song, -1, 1, 1)["ok"]) and not bool(SongStudy.cloze(song, 99, 1, 1)["ok"]), "robust: line index out of range -> ok:false")
	ok(SongStudy.line_card(song, 99).is_empty() and SongStudy.line_card(null, 0).is_empty() and SongStudy.word_card(null, "x").is_empty(), "robust: cards from a bad song / index -> {}")
	var weird: Dictionary = {"lang": "en", "lines": [{"text": "River light", "words": [5, null, {"w": 3}, {"w": ""}, {"w": "River"}, {"lemma": "light"}, {"w": "light", "zipf": "x", "level": 7}]}]}
	var cw: Dictionary = SongStudy.cloze(weird, 0, 3, 1)
	ok(bool(cw["ok"]) and blank_answers(cw).has("River"), "robust: broken word entries are skipped, valid ones still work")
	ok(SongStudy.pick_unknown(null, {}, 5).is_empty() and SongStudy.pick_unknown(weird, {}, 5).size() >= 1, "robust: pick_unknown(bad song) -> [], weird words skipped")
	# pick_unknown
	var pk: Array = SongStudy.pick_unknown(song, {}, 50)
	var lemmas: Array = []
	for e in pk:
		lemmas.append((e as Dictionary)["lemma"])
	ok(not lemmas.has("the") and not lemmas.has("i") and not lemmas.has("oh") and lemmas.size() == 16, "pick_unknown: no function words, one entry per lemma (%d)" % lemmas.size())
	ok(lemmas.count("hold") == 1 and int((pk[lemmas.find("hold")] as Dictionary)["count"]) == 2, "pick_unknown: 'hold' appears twice -> one entry with count 2")
	ok((pk[0] as Dictionary)["level"] == "hard" and lemmas.find("silver") < lemmas.find("hold"), "pick_unknown: hard words first, easy words last (first %s)" % str(lemmas[0]))
	ok(pk[0]["lemma"] == "sparrow" and pk[0]["ko"] == "참새" and pk[0]["reading"] == "ˈspæroʊ" and int(pk[0]["line_i"]) == 1, "pick_unknown: lowest zipf first; entry carries meaning / IPA / first line")
	ok(SongStudy.pick_unknown(song, {}, 3).size() == 3 and SongStudy.pick_unknown(song, {}, 0).is_empty() and SongStudy.pick_unknown(song, {}, -2).is_empty(), "pick_unknown: limit respected (3 / 0 / -2)")
	var pk2: Array = SongStudy.pick_unknown(song, {"sparrow": true, "lantern": true}, 50)
	var l2: Array = []
	for e2 in pk2:
		l2.append((e2 as Dictionary)["lemma"])
	ok(not l2.has("sparrow") and not l2.has("lantern") and l2.size() == 14, "pick_unknown: known words are left out (%d left)" % l2.size())
	ok(JSON.stringify(SongStudy.pick_unknown(song, {}, 50)) == JSON.stringify(pk), "pick_unknown: same input -> same order")
	var pj: Array = SongStudy.pick_unknown(ja_song(), {}, 20)
	var jl: Array = []
	for e3 in pj:
		jl.append((e3 as Dictionary)["lemma"])
	ok(jl.size() == 6 and not jl.has("を") and not jl.has("が") and not jl.has("ねえ") and jl.has("見上げる"), "pick_unknown ja: particles dropped (%s)" % str(jl))
	# 곡 데이터를 바꾸지 않는다
	var snap: String = JSON.stringify(song)
	SongStudy.cloze(song, 0, 3, 1)
	SongStudy.pick_unknown(song, {}, 5)
	SongStudy.line_card(song, 1)
	SongStudy.word_card(song, "sparrow")
	ok(JSON.stringify(song) == snap, "robust: no function changes the song it was given")
	reached["robust"] = true
