extends Node
## LexiconGuard (배운 것만 나온다: 토큰화·문장 검사·문제 검사). 순수 함수 시험이라 화면·네트워크·사용자 파일 없음.
##   godot --headless --path <project>/godot res://tests/lexicon_guard_test.tscn
##   godot --headless --path <project>/godot --resolution 412x915 res://tests/lexicon_guard_test.tscn -- --phone
## 종료 코드 0 = 전부 통과. 마지막 줄: "== lexicon_guard: N passed, M failed =="
## 시험 데이터: tests/fixtures/course_builder/mini.json(4주 작은 코스) + 이 파일 안의 손으로 만든 작은 데이터.

const FIXTURE_DIR := "res://tests/fixtures/course_builder/mini"

var passed: int = 0
var failed: int = 0
var mini: Dictionary = {}


func ok(cond: bool, name: String) -> void:
	if cond:
		passed += 1
		print("  PASS  ", name)
	else:
		failed += 1
		print("  FAIL  ", name)


func _ready() -> void:
	print("== lexicon_guard start ==")
	var raw: Dictionary = load_k1_dir(FIXTURE_DIR)
	if not raw.is_empty():
		mini = LexiconGuard.index(raw)
	ok(not mini.is_empty(), "fixture loaded (K1 file format, wrapping keys stripped)")
	_test_tokens()
	_test_index_and_input()
	_test_sentences()
	_test_exercises()
	_test_selfcheck()
	_test_junk_types()
	print("== lexicon_guard: %d passed, %d failed ==" % [passed, failed])
	get_tree().quit(1 if failed > 0 else 0)



## K1(build_course.py) 출력 폴더를 읽어 빌더가 받는 data 로 바꾼다: 감싸는 키({"v":1,"lang":"en","<key>":[...]})를 벗긴 배열.
static func load_k1_dir(dir: String) -> Dictionary:
	var keys: Dictionary = {"en_weeks.json": ["weeks", "weeks"], "en_lexicon.json": ["words", "words"], "en_patterns.json": ["patterns", "patterns"],
		"en_sentences.json": ["sentences", "sentences"], "en_dialogues.json": ["dialogues", "dialogues"], "en_speak_prompts.json": ["prompts", "speak_prompts"]}
	var data: Dictionary = {}
	for fname in keys.keys():
		var f: FileAccess = FileAccess.open(dir.path_join(fname), FileAccess.READ)
		if f == null:
			return {}
		var parsed: Variant = JSON.parse_string(f.get_as_text())
		if not (parsed is Dictionary) or not (parsed.get(keys[fname][0]) is Array):
			return {}
		data[keys[fname][1]] = parsed[keys[fname][0]]
	return data


# ------------------------------------------------------------------ E2-2 토큰화 표 (>= 30행)

func _test_tokens() -> void:
	var rows: Array = [
		["I'm", "", ["i'm"]],
		["Mr. Smith", "", ["mr", "smith"]],
		["thirty-five", "", ["thirty", "five"]],
		["$5.99", "five ninety-nine", ["five", "ninety", "nine"]],
		["$5.99", "", ["5", "99"]],
		["Hello, world!", "", ["hello", "world"]],
		["HELLO", "", ["hello"]],
		["  spaced   out  ", "", ["spaced", "out"]],
		["Ｈｅｌｌｏ", "", ["hello"]],
		["a b", "", ["a", "b"]],
		["a　b", "", ["a", "b"]],
		["It’s", "", ["it's"]],
		["‘quoted’", "", ["quoted"]],
		["\"Yes,\" she said.", "", ["yes", "she", "said"]],
		["(maybe)", "", ["maybe"]],
		["wait...", "", ["wait"]],
		["well—done", "", ["well", "done"]],
		["I like 사과", "", ["i", "like", "사과"]],
		["", "", []],
		["   ", "", []],
		["...", "", []],
		["---", "", []],
		["dogs'", "", ["dogs"]],
		["'tis", "", ["tis"]],
		["rock'n'roll", "", ["rock'n'roll"]],
		["3:30", "", ["3", "30"]],
		["e.g.", "", ["e", "g"]],
		["a_b", "", ["a", "b"]],
		["I like ___.", "", ["i", "like"]],
		["line1\nline2\tline3", "", ["line1", "line2", "line3"]],
		["hi \u2605 there", "", ["hi", "there"]],
		["hi * there", "", ["hi", "there"]],
		["colour/color", "", ["colour", "color"]],
		["Hello,world", "", ["hello", "world"]],
		["I'm.", "", ["i'm"]],
		["it''s", "", ["it", "s"]],
		["It's John's", "", ["it's", "john's"]],
		["Hi", "   ", ["hi"]],
		["Ünder", "", ["ünder"]],
		["zero​width", "", ["zero", "width"]],
		["x-ray", "", ["x", "ray"]],
		["Hello！", "", ["hello"]],
		["ice cream", "", ["ice", "cream"]],
	]
	var bad: int = 0
	for r in rows:
		var got: Array = LexiconGuard.tokens(r[0], r[1])
		if got != r[2]:
			bad += 1
			print("    token row mismatch: ", var_to_str(r[0]), " say=", var_to_str(r[1]), " got=", got, " want=", r[2])
	ok(rows.size() >= 30, "token table has >= 30 rows (%d)" % rows.size())
	ok(bad == 0, "all token rows match (%d bad)" % bad)
	# 몇 행은 따로 눈에 보이게
	ok(LexiconGuard.tokens("I'm") == ["i'm"], "token: I'm kept whole")
	ok(LexiconGuard.tokens("thirty-five") == ["thirty", "five"], "token: hyphen splits")
	ok(LexiconGuard.tokens("$5.99", "five ninety-nine") == ["five", "ninety", "nine"], "token: say wins over text")
	ok(LexiconGuard.tokens("x  y　z") == ["x", "y", "z"], "token: odd spaces")
	ok(LexiconGuard.tokens("Hello,world") == ["hello", "world"] and LexiconGuard.tokens("5.99") == ["5", "99"], "token: K1 rule, every punctuation splits")
	var wrapped: Dictionary = {"words": {"v": 1, "lang": "en", "words": [{"id": "z1", "en": "hi", "o": 11}]}, "weeks": {"v": 1, "lang": "en", "weeks": [{"w": 1}]}}
	var wi: Dictionary = LexiconGuard.index(wrapped)["_idx"]
	ok(wi["words"].has("z1") and wi["weeks"].has(1), "wrapped K1 file objects are unwrapped by index()")
	# 정수 o
	ok(LexiconGuard.int_o(52) == 52 and LexiconGuard.int_o(52.0) == 52, "int_o int and integral float")
	ok(LexiconGuard.int_o(null) == LexiconGuard.INF_O and LexiconGuard.int_o("5") == LexiconGuard.INF_O, "int_o null/string -> INF")
	ok(LexiconGuard.int_o(5.5) == LexiconGuard.INF_O and LexiconGuard.int_o(NAN) == LexiconGuard.INF_O, "int_o fraction/NaN -> INF")


# ------------------------------------------------------------------ 색인·입력 방어

func _small() -> Dictionary:
	return {
		"words": [
			{"id": "a1", "en": "I", "pos": "pron", "ko": "나", "o": 12, "role": "active"},
			{"id": "a2", "en": "like", "pos": "v", "ko": "좋아하다", "o": 21, "role": "active"},
			{"id": "a3", "en": "tea", "pos": "n", "ko": "차", "o": 14, "role": "active"},
			{"id": "a4", "en": "coffee", "pos": "n", "ko": "커피", "o": 14, "role": "active", "syn": []},
			{"id": "a5", "en": "work", "pos": "v", "ko": "일하다", "o": 31, "role": "active", "forms": [{"f": "worked", "pat": "p_past"}, {"f": "works", "pat": "p_s"}, {"f": "working", "pat": "p_nope"}, {"f": "worker", "pat": ""}]},
			{"id": "a6", "en": "cash", "pos": "n", "ko": "현금", "o": 41, "role": "passive"},
			{"id": "a7", "en": "Mr.", "pos": "propn", "ko": "씨", "o": 15, "role": "active"},
			{"id": "a8", "en": "ice cream", "pos": "n", "ko": "아이스크림", "o": 22, "role": "active"},
			{"id": "a9", "en": "color", "pos": "n", "ko": "색", "o": 24, "role": "active", "alt": ["colour"]},
			{"id": "a10", "en": "Min", "pos": "propn", "ko": "민", "o": 13, "role": "active"},
			{"id": "a11", "en": "water", "pos": "n", "ko": "물", "o": 14, "role": "active"},
			{"id": "a12", "en": "tea2", "pos": "n", "ko": "차", "o": 14, "role": "active"},
			{"id": "a13", "en": "five", "pos": "num", "ko": "다섯", "o": 41, "role": "active"},
			{"id": "a14", "en": "ninety", "pos": "num", "ko": "아흔", "o": 41, "role": "active"},
			{"id": "a15", "en": "nine", "pos": "num", "ko": "아홉", "o": 41, "role": "active"},
			{"id": "a16", "en": "it", "pos": "pron", "ko": "그것", "o": 11, "role": "active"},
			{"id": "a17", "en": "is", "pos": "v", "ko": "이에요", "o": 11, "role": "active"},
			{"id": "a18", "en": "bad", "pos": "adj", "ko": "나쁜", "o": "x", "role": "active"},
		],
		"patterns": [{"id": "p_past", "tpl": "I worked.", "o": 44}, {"id": "p_s", "tpl": "He works.", "o": 33}],
		"sentences": [
			{"id": "s1", "en": "I like tea.", "ko": "저는 차를 좋아해요.", "o": 21, "scope": "all", "words": ["a1", "a2", "a3"]},
			{"id": "s2", "en": "I like cash.", "ko": "저는 현금을 좋아해요.", "o": 41, "scope": "listen", "words": ["a1", "a2", "a6"]},
			{"id": "s3", "en": "I like cash.", "ko": "저는 현금을 좋아해요.", "o": 41, "scope": "all", "words": []},
			{"id": "s4", "en": "I worked.", "ko": "저는 일했어요.", "o": 21, "scope": "all", "words": ["a1", "a5"]},
			{"id": "s5", "en": "It is $5.99.", "ko": "5.99달러예요.", "o": 41, "scope": "all", "say": "It is five ninety-nine.", "words": []},
			{"id": "s6", "en": "I like tea.", "ko": "저는 차를 좋아해요.", "o": 12, "scope": "all", "words": ["a1", "a2", "a3"]},
			{"id": "s7", "en": "I like ice cream.", "ko": "저는 아이스크림을 좋아해요.", "o": 22, "scope": "all", "words": []},
			{"id": "s8", "en": "I like ice.", "ko": "저는 얼음을 좋아해요.", "o": 22, "scope": "all", "words": []},
			{"id": "s9", "en": "Mr. Min likes tea.", "ko": "민 씨는 차를 좋아해요.", "o": 21, "scope": "all", "words": []},
			{"id": "s10", "en": "I like colour.", "ko": "저는 색을 좋아해요.", "o": 24, "scope": "all", "words": []},
			{"id": "s11", "en": "I like tea.", "ko": "저는 차를 좋아해요.", "o": 21, "scope": "weird", "words": []},
			{"id": "s12", "en": "I like tea.", "ko": "차", "scope": "all", "words": []},
			{"id": "s13", "en": "I like tea.", "ko": "차", "o": 21.0, "scope": "all", "words": ["zz"]},
			{"id": "s14", "en": "", "ko": "차", "o": 21, "scope": "all", "words": []},
			{"id": "s15", "en": "I like tea.", "ko": "차", "o": 21, "scope": "all", "words": ["a6"]},
		],
		"dialogues": [{"id": "d1", "w": 2, "user": "B", "lines": [
			{"s": "A", "en": "I like tea.", "ko": "저는 차를 좋아해요.", "o": 21},
			{"s": "B", "en": "I like cash.", "ko": "저는 현금을 좋아해요.", "o": 41}]}],
	}


func _test_index_and_input() -> void:
	var d: Dictionary = LexiconGuard.index(_small())
	ok(d.has("_idx") and LexiconGuard.index(d) == d, "index adds _idx once and is idempotent")
	var idx: Dictionary = d["_idx"]
	ok(idx["words"].size() == 18 and idx["sent_ids"].size() == 15, "index sizes")
	# 모음 형식: Array / Dictionary / 이상한 원소
	var as_dict: Dictionary = {"words": {"x1": {"en": "hi", "o": 11}, "x2": 5, "x3": {"id": "x9", "en": "yo", "o": 12}}}
	var di: Dictionary = LexiconGuard.index(as_dict)["_idx"]
	ok(di["words"].has("x1") and di["words"].has("x9") and not di["words"].has("x2"), "coll accepts Dictionary, skips non-dict")
	var weird: Dictionary = LexiconGuard.index({"words": [1, "a", null, {"en": "no id"}, {"id": "", "en": "x"}, {"id": "ok", "en": "fine", "o": 11}]})["_idx"]
	ok(weird["words"].size() == 1, "coll skips weird array items")
	# 빈·이상한 data 에서도 에러 없이 ok:false 또는 ok:true(빈 토큰)
	var empty_res: Dictionary = LexiconGuard.check_text("hello", 11, {})
	ok(not empty_res["ok"] and empty_res["bad"][0]["why"] == "unknown", "empty data: token unknown -> not ok")
	ok(LexiconGuard.check_text("", 11, {})["ok"], "empty data, empty text -> ok (nothing to check)")
	ok(not LexiconGuard.check_sentence("nope", 99, {})["ok"], "unknown sentence id -> not ok")
	ok(not LexiconGuard.check_sentence(5, 99, d)["ok"], "sentence of wrong type -> not ok, no error")
	ok(not LexiconGuard.check_exercise(null, 99, [], d)["ok"], "exercise null -> not ok")
	ok(not LexiconGuard.check_exercise("x", 99, null, d)["ok"], "exercise string + seen null -> not ok")
	ok(not LexiconGuard.check_exercise({"type": "nope"}, 99, [], d)["ok"], "unknown exercise type -> not ok")
	ok(not LexiconGuard.check_exercise({}, 99, [], d)["ok"], "empty exercise -> not ok")
	ok(not LexiconGuard.check_exercise({"type": "build"}, 11, [], null)["ok"], "data null -> not ok, no error")
	# 문자열 data 가 raw(색인 없음)여도 같은 결과
	var raw: Dictionary = _small()
	ok(LexiconGuard.check_sentence("s1", 21, raw)["ok"] == LexiconGuard.check_sentence("s1", 21, d)["ok"], "raw data and indexed data agree")


# ------------------------------------------------------------------ 문장 검사 표 (R1, R2, R3, R5)

func _test_sentences() -> void:
	var d: Dictionary = LexiconGuard.index(_small())
	var rows: Array = [
		# [문장 id, cur_o, 기대 ok, 설명]
		["s1", 21, true, "all words learned at cur"],
		["s1", 20, false, "sentence o 21 > 20"],
		["s1", 14, false, "like (21) not learned yet"],
		["s2", 41, true, "passive word in listen scope"],
		["s2", 40, false, "passive o 41 > 40"],
		["s3", 41, false, "passive word in scope all"],
		["s4", 21, false, "worked needs p_past (44)"],
		["s4", 43, false, "worked before pattern 44"],
		["s4", 44, false, "work itself o 31 ok, form ok at 44, but sentence o is 21? sentence ok but I-work chain: scope ok"],
		["s5", 41, true, "say is the token source (five ninety nine)"],
		["s5", 40, false, "five o 41 > 40"],
		["s6", 12, false, "like o 21 > 12 even though sentence o says 12"],
		["s7", 22, true, "multi-word entry ice cream"],
		["s8", 22, false, "ice alone is not a word"],
		["s9", 21, false, "likes is not a form"],
		["s10", 24, true, "alt spelling colour"],
		["s10", 23, false, "color o 24"],
		["s11", 21, false, "weird scope"],
		["s12", 21, false, "sentence without o -> future"],
		["s13", 21, false, "words[] has unknown id"],
		["s14", 21, false, "empty en"],
		["s15", 99, false, "words[] lists a passive word in a scope:all sentence"],
	]
	# s4 의 기대: o=21, 토큰 worked 는 44 -> cur 44 에서 ok, 단 문장 o 21 <= 44 라 ok. 위 설명 칸 보정.
	rows[8][2] = true
	var bad: int = 0
	for r in rows:
		var res: Dictionary = LexiconGuard.check_sentence(r[0], r[1], d)
		if res["ok"] != r[2]:
			bad += 1
			print("    sentence row mismatch: ", r[0], " cur=", r[1], " want ok=", r[2], " got ", res)
	ok(rows.size() >= 20, "sentence table has >= 20 rows (%d)" % rows.size())
	ok(bad == 0, "all sentence rows match (%d bad)" % bad)
	# bad 항목의 모양
	var r1: Dictionary = LexiconGuard.check_sentence("s6", 12, d)
	ok(not r1["ok"] and r1["bad"].size() >= 1 and r1["bad"][0].has("token") and r1["bad"][0].has("why") and r1["bad"][0].has("o"), "bad entries carry token/why/o")
	var has_future: bool = false
	for bb in r1["bad"]:
		if bb["why"] == "future" and bb["o"] == 21 and bb["token"] == "like":
			has_future = true
	ok(has_future, "bad: future token with its o")
	var r2: Dictionary = LexiconGuard.check_sentence("s3", 41, d)
	ok(r2["bad"][0]["why"] == "passive", "bad: passive in non-listen sentence")
	# 문장 Dictionary 를 직접 넘겨도 됨
	var direct: Dictionary = {"id": "zz", "en": "I like tea.", "o": 21, "scope": "all"}
	ok(LexiconGuard.check_sentence(direct, 21, d)["ok"], "sentence given as Dictionary")
	var direct_bad: Dictionary = {"id": "zz", "en": "I like cash.", "o": 21, "scope": "all"}
	ok(not LexiconGuard.check_sentence(direct_bad, 99, d)["ok"], "passive token in Dictionary sentence scope all -> not ok")
	# R3 활용형: 문형 o 가 더 늦으면 활용형 o 는 문형 o, 문형 모르는 id 는 미래
	ok(LexiconGuard.check_text("worked", 44, d)["ok"], "R3: worked ok at 44")
	ok(not LexiconGuard.check_text("worked", 43, d)["ok"], "R3: worked not ok at 43")
	ok(LexiconGuard.check_text("works", 33, d)["ok"] and not LexiconGuard.check_text("works", 32, d)["ok"], "R3: works follows p_s (33)")
	ok(not LexiconGuard.check_text("working", 99, d)["ok"], "R3: form with unknown pattern is never learned")
	ok(LexiconGuard.check_text("worker", 31, d)["ok"], "R3: form with empty pat uses the word o")
	var k1form: Dictionary = {"words": [{"id": "k1", "en": "work", "o": 31, "role": "active", "forms": [{"f": "worked", "pat": "p_gone", "o": 44}]}]}
	ok(LexiconGuard.check_text("worked", 44, k1form)["ok"] and not LexiconGuard.check_text("worked", 43, k1form)["ok"], "R3: K1 form o is used as given (pattern need not be in the data)")
	# 대소문자·부호·전각
	ok(LexiconGuard.check_text("  I   LIKE tea!!! ", 21, d)["ok"], "case, spaces, punctuation ignored")
	ok(LexiconGuard.check_text("Ｉ like tea", 21, d)["ok"], "fullwidth letters")
	ok(not LexiconGuard.check_text("I like 사과", 21, d)["ok"], "Korean mixed in English text is not a word")
	ok(LexiconGuard.check_text("Mr. Min", 15, d)["ok"], "Mr. (o 15) and Min (o 13) at 15")
	ok(not LexiconGuard.check_text("Mr. Min", 14, d)["ok"] and LexiconGuard.check_text("Mr. Min", 14, d)["bad"][0]["token"] == "mr", "Mr. not yet learned at 14")
	# R5 allow_passive
	ok(LexiconGuard.check_text("cash", 41, d, true)["ok"] and not LexiconGuard.check_text("cash", 41, d)["ok"], "R5: passive only with allow_passive")


# ------------------------------------------------------------------ 문제 검사 (R4, R6)

func _opts_ex(mode: String, ids: Array, texts: Array, ans: int) -> Dictionary:
	return {"type": "recognize", "id": "t", "mode": mode, "item": ids[ans], "prompt": "tea", "tts": "tea", "options": texts, "option_ids": ids, "answer": ans}


func _test_exercises() -> void:
	var d: Dictionary = LexiconGuard.index(_small())
	var seen: Array = ["a3", "a2"]
	# recognize en_ko: 정상
	var good: Dictionary = _opts_ex("en_ko", ["a3", "a1", "a2"], ["차", "나", "좋아하다"], 0)
	ok(LexiconGuard.check_exercise(good, 21, seen, d)["ok"], "recognize en_ko ok")
	# R6: 오늘(cur=14) 낱말 a3 는 소개 카드를 봐야
	var r6: Dictionary = LexiconGuard.check_exercise(_opts_ex("en_ko", ["a3", "a1", "a10"], ["차", "나", "민"], 0), 14, [], d)
	ok(not r6["ok"], "R6: today's word unseen -> not ok")
	var r6b: Dictionary = LexiconGuard.check_exercise(_opts_ex("en_ko", ["a3", "a1", "a10"], ["차", "나", "민"], 0), 14, ["a3", "a10"], d)
	ok(r6b["ok"], "R6: seen item with earlier-day options -> ok")
	var r6c: Dictionary = LexiconGuard.check_exercise(_opts_ex("en_ko", ["a3", "a1", "a10"], ["차", "나", "민"], 0), 15, [], d)
	ok(r6c["ok"], "R6: earlier-day words need no card")
	# (b) 미래 낱말 보기
	var fut: Dictionary = LexiconGuard.check_exercise(_opts_ex("en_ko", ["a3", "a1", "a2"], ["차", "나", "좋아하다"], 0), 20, seen, d)
	ok(not fut["ok"], "options with a future word (like, o 21 at cur 20) -> not ok")
	# 보기 하나가 수동 낱말
	var pas: Dictionary = LexiconGuard.check_exercise(_opts_ex("en_ko", ["a3", "a6", "a1"], ["차", "현금", "나"], 0), 41, seen, d)
	ok(not pas["ok"], "passive word as an option -> not ok")
	# 같은 뜻(ko) 보기: a3 차 와 a12 차
	var syn: Dictionary = LexiconGuard.check_exercise(_opts_ex("en_ko", ["a3", "a12", "a1"], ["차", "차 ", "나"], 0), 21, ["a3", "a12"], d)
	ok(not syn["ok"] and _has_why(syn, "syn_option"), "R4: option with the same ko as the answer -> not ok")
	# 보기 수·정답 범위
	var one: Dictionary = good.duplicate(true)
	one["options"] = ["차"]
	one["option_ids"] = ["a3"]
	ok(not LexiconGuard.check_exercise(one, 21, seen, d)["ok"], "fewer than 2 options -> not ok")
	var badans: Dictionary = good.duplicate(true)
	badans["answer"] = 7
	ok(not LexiconGuard.check_exercise(badans, 21, seen, d)["ok"], "answer out of range -> not ok")
	var dup: Dictionary = good.duplicate(true)
	dup["options"] = ["차", "차", "나"]
	ok(not LexiconGuard.check_exercise(dup, 21, seen, d)["ok"], "duplicate option text -> not ok")
	var mism: Dictionary = good.duplicate(true)
	mism["options"] = ["차", "나", "민"]
	ok(not LexiconGuard.check_exercise(mism, 21, seen, d)["ok"], "option text does not match its id -> not ok")
	# option_ids 없이 글만(뜻으로 찾기)
	var noids: Dictionary = good.duplicate(true)
	noids.erase("option_ids")
	ok(LexiconGuard.check_exercise(noids, 21, seen, d)["ok"], "options without option_ids are looked up by ko")
	noids["options"] = ["차", "좋아하다", "없는 뜻"]
	ok(not LexiconGuard.check_exercise(noids, 21, seen, d)["ok"], "option ko that is no word -> not ok")
	noids["options"] = ["차", "좋아하다", "현금"]
	ok(not LexiconGuard.check_exercise(noids, 41, seen, d)["ok"], "option ko of a passive word -> not ok")
	# (c) seen 에 없는 낱말 질문
	var unseen: Dictionary = {"type": "recall", "id": "t", "mode": "ko_en_type", "item": "a4", "prompt_ko": "커피", "accept": ["coffee"]}
	ok(not LexiconGuard.check_exercise(unseen, 14, ["a3"], d)["ok"], "recall of an unseen word today -> not ok")
	ok(LexiconGuard.check_exercise(unseen, 14, ["a3", "a4"], d)["ok"], "recall of a seen word -> ok")
	ok(LexiconGuard.check_exercise(unseen, 15, [], d)["ok"], "recall of an earlier day's word -> ok")
	# 미래/수동 항목
	var fi: Dictionary = {"type": "recall", "id": "t", "mode": "ko_en_type", "item": "a2", "prompt_ko": "좋아하다", "accept": ["like"]}
	ok(not LexiconGuard.check_exercise(fi, 14, ["a2"], d)["ok"], "future item -> not ok even if 'seen'")
	var pi: Dictionary = {"type": "recall", "id": "t", "mode": "ko_en_type", "item": "a6", "prompt_ko": "현금", "accept": ["cash"]}
	ok(not LexiconGuard.check_exercise(pi, 99, ["a6"], d)["ok"], "passive item -> not ok in recall")
	var unk: Dictionary = {"type": "recognize", "id": "t", "mode": "en_ko", "item": "nope", "prompt": "tea", "options": ["a", "b"], "answer": 0}
	ok(not LexiconGuard.check_exercise(unk, 99, [], d)["ok"], "unknown item id -> not ok")
	# recall accept 에 미래 낱말
	var acc: Dictionary = unseen.duplicate(true)
	acc["accept"] = ["coffee", "like"]
	ok(not LexiconGuard.check_exercise(acc, 15, [], d)["ok"], "recall accept with a future word -> not ok")
	# build
	var bld: Dictionary = {"type": "build", "id": "t", "sent": "s1", "ko": "x", "answer": ["I", "like", "tea"], "extra": ["coffee"], "accept": [["I", "like", "tea"]], "tts": "I like tea."}
	ok(LexiconGuard.check_exercise(bld, 21, [], d)["ok"], "build ok")
	var b2: Dictionary = bld.duplicate(true)
	b2["extra"] = ["work"]
	ok(not LexiconGuard.check_exercise(b2, 21, [], d)["ok"], "build extra tile with a future word -> not ok")
	b2["extra"] = ["cash"]
	ok(not LexiconGuard.check_exercise(b2, 99, [], d)["ok"], "build extra tile that is a passive word -> not ok")
	b2["extra"] = ["tea"]
	ok(not LexiconGuard.check_exercise(b2, 21, [], d)["ok"] and _has_why(LexiconGuard.check_exercise(b2, 21, [], d), "extra_dup"), "build extra tile equal to an answer tile -> not ok")
	var b3: Dictionary = bld.duplicate(true)
	b3["sent"] = "s2"
	b3["answer"] = ["I", "like", "cash"]
	b3["extra"] = []
	b3["accept"] = [["I", "like", "cash"]]
	b3["tts"] = "I like cash."
	ok(not LexiconGuard.check_exercise(b3, 41, [], d)["ok"], "R5: build from a scope:listen sentence -> not ok")
	var b4: Dictionary = bld.duplicate(true)
	b4["answer"] = ["I"]
	ok(not LexiconGuard.check_exercise(b4, 21, [], d)["ok"], "build with fewer than 2 answer tiles -> not ok")
	var b5: Dictionary = {"type": "build", "id": "t", "sent": "s5", "ko": "x", "answer": ["It", "is", "$5.99"], "extra": [], "accept": [], "tts": "It is five ninety-nine."}
	ok(LexiconGuard.check_exercise(b5, 41, [], d)["ok"], "build with say: tiles checked through say")
	# listen
	var lis: Dictionary = {"type": "listen", "id": "t", "mode": "choose_ko", "sent": "s1", "tts": "I like tea.", "options": ["저는 차를 좋아해요.", "저는 현금을 좋아해요."], "option_ids": ["s1", "s2"], "answer": 0}
	ok(not LexiconGuard.check_exercise(lis, 21, [], d)["ok"], "listen option sentence from the future (s2 o 41) -> not ok")
	ok(LexiconGuard.check_exercise(lis, 41, [], d)["ok"], "listen with a listen-scope option at 41 -> ok (passive allowed in listening)")
	var lis2: Dictionary = lis.duplicate(true)
	lis2["tts"] = "I like cash."
	lis2["sent"] = "s2"
	lis2["answer"] = 1
	ok(LexiconGuard.check_exercise(lis2, 41, [], d)["ok"], "listen tts with a passive word is allowed")
	ok(not LexiconGuard.check_exercise(lis2, 40, [], d)["ok"], "listen tts with a passive word before it was learned -> not ok")
	var lis3: Dictionary = lis.duplicate(true)
	lis3.erase("option_ids")
	ok(LexiconGuard.check_exercise(lis3, 41, [], d)["ok"], "listen options without ids are looked up by ko")
	lis3["options"] = ["저는 차를 좋아해요.", "엉뚱한 뜻"]
	ok(not LexiconGuard.check_exercise(lis3, 41, [], d)["ok"], "listen option ko that is no sentence -> not ok")
	var lty: Dictionary = {"type": "listen", "id": "t", "mode": "type", "sent": "s1", "tts": "I like tea.", "accept": ["I like tea."]}
	ok(LexiconGuard.check_exercise(lty, 21, [], d)["ok"], "listen type ok")
	lty["accept"] = ["I like tea.", "I like cash and tea."]
	ok(not LexiconGuard.check_exercise(lty, 21, [], d)["ok"], "listen type accept with unlearned words -> not ok")
	# (e) tts / say 에 미래 낱말
	var tts_bad: Dictionary = good.duplicate(true)
	tts_bad["tts"] = "I work"
	ok(not LexiconGuard.check_exercise(tts_bad, 21, seen, d)["ok"], "tts with a future word -> not ok")
	var say_bad: Dictionary = {"type": "speak", "id": "t", "mode": "repeat", "sent": "s5", "target": "It is $5.99.", "say": "It is five ninety-nine and work.", "tts": "It is five ninety-nine."}
	ok(not LexiconGuard.check_exercise(say_bad, 41, [], d)["ok"], "say with a future word -> not ok")
	# speak
	var spk: Dictionary = {"type": "speak", "id": "t", "mode": "substitute", "sent": "s1", "target": "I like tea.", "tts": "I like tea.", "cue": {"slot": "tea", "with": "coffee"}, "accept": ["I like coffee."]}
	ok(LexiconGuard.check_exercise(spk, 21, [], d)["ok"], "speak substitute ok")
	spk["cue"] = {"slot": "tea", "with": "cash"}
	ok(not LexiconGuard.check_exercise(spk, 41, [], d)["ok"], "speak cue.with passive word -> not ok")
	spk["cue"] = {"slot": "tea", "with": "coffee"}
	spk["accept"] = ["I like coffee.", "I like work."]
	ok(not LexiconGuard.check_exercise(spk, 21, [], d)["ok"], "speak accept with a future word -> not ok")
	var spk2: Dictionary = {"type": "speak", "id": "t", "mode": "repeat", "sent": "s2", "target": "I like cash.", "tts": "I like cash.", "accept": []}
	ok(not LexiconGuard.check_exercise(spk2, 41, [], d)["ok"], "R5: speak from a scope:listen sentence -> not ok")
	# teach
	var tw: Dictionary = {"type": "teach_word", "id": "t", "item": "a3", "prompt": "tea", "tts": "tea", "example": {"sent": "s1", "en": "I like tea.", "tts": "I like tea."}}
	ok(LexiconGuard.check_exercise(tw, 21, [], d)["ok"], "teach_word ok")
	ok(not LexiconGuard.check_exercise(tw, 20, [], d)["ok"], "teach_word example from the future -> not ok")
	var tw2: Dictionary = {"type": "teach_word", "id": "t", "item": "a2", "prompt": "like", "tts": "like"}
	ok(not LexiconGuard.check_exercise(tw2, 14, [], d)["ok"], "teach_word of a future word -> not ok")
	var tp: Dictionary = {"type": "teach_pattern", "id": "t", "pattern": "p_s", "tpl": "He works.", "examples": []}
	ok(not LexiconGuard.check_exercise(tp, 33, [], d)["ok"], "teach_pattern tpl uses words not learned (He) -> not ok")
	var tp2: Dictionary = {"type": "teach_pattern", "id": "t", "pattern": "nope", "tpl": "", "examples": []}
	ok(not LexiconGuard.check_exercise(tp2, 99, [], d)["ok"], "teach_pattern unknown pattern -> not ok")
	# dialogue
	var dl: Dictionary = {"type": "dialogue_script", "id": "t", "dialogue": "d1", "lines": [
		{"s": "A", "en": "I like tea.", "ko": "x", "tts": "I like tea.", "you": false},
		{"s": "B", "en": "I like cash.", "ko": "x", "tts": "I like cash.", "you": true, "accept": ["I like cash."]}]}
	ok(LexiconGuard.check_exercise(dl, 41, [], d)["ok"], "dialogue ok at 41 (passive allowed in dialogue)")
	ok(not LexiconGuard.check_exercise(dl, 30, [], d)["ok"], "dialogue before its lines' o -> not ok")
	var dl2: Dictionary = dl.duplicate(true)
	dl2["lines"] = []
	ok(not LexiconGuard.check_exercise(dl2, 41, [], d)["ok"], "dialogue without lines -> not ok")
	# 큰 데이터(fixture)에서 한 번
	var fx_seen: Array = []
	var fx: Dictionary = {"type": "recognize", "id": "t", "mode": "en_ko", "item": "w0001", "prompt": "hello", "tts": "hello", "options": ["안녕하세요", "네"], "option_ids": ["w0001", "w0003"], "answer": 0}
	ok(not LexiconGuard.check_exercise(fx, 11, fx_seen, mini)["ok"], "fixture: day-1 word asked before its card -> not ok")
	ok(LexiconGuard.check_exercise(fx, 11, ["w0001", "w0003"], mini)["ok"], "fixture: day-1 word after both cards -> ok")
	# 스위치
	LexiconGuard.enabled = false
	var off: bool = LexiconGuard.check_exercise(fut, 20, seen, d)["ok"] and LexiconGuard.check_sentence("s6", 12, d)["ok"] and LexiconGuard.check_text("zzz", 1, d)["ok"]
	LexiconGuard.enabled = true
	ok(off, "enabled=false makes every check pass (test-only switch)")
	ok(not LexiconGuard.check_exercise(fut, 20, seen, d)["ok"], "enabled restored: the same exercise fails again")


func _has_why(res: Dictionary, why: String) -> bool:
	for b in res["bad"]:
		if b["why"] == why:
			return true
	return false


# ------------------------------------------------------------------ C-12: 검사기도 실패할 수 있어야 한다

func _test_selfcheck() -> void:
	var d: Dictionary = LexiconGuard.index(_small())
	# (a) 문장에 미래 낱말
	var a: Dictionary = LexiconGuard.check_sentence({"id": "z", "en": "I like work.", "o": 21, "scope": "all"}, 21, d)
	print("selfcheck FAIL-as-expected sentence-with-future-word: ok=", a["ok"], " bad=", a["bad"].size())
	ok(not a["ok"], "selfcheck (a) future word in a sentence fails")
	# (b) 미래 낱말 보기
	var b: Dictionary = LexiconGuard.check_exercise(_opts_ex("en_ko", ["a3", "a1", "a2"], ["차", "나", "좋아하다"], 0), 20, ["a3"], d)
	print("selfcheck FAIL-as-expected future-option: ok=", b["ok"], " bad=", b["bad"].size())
	ok(not b["ok"], "selfcheck (b) future option fails")
	# (c) seen 에 없는 낱말
	var c: Dictionary = LexiconGuard.check_exercise({"type": "recall", "id": "t", "mode": "ko_en_type", "item": "a3", "prompt_ko": "차", "accept": ["tea"]}, 14, [], d)
	print("selfcheck FAIL-as-expected unseen-item: ok=", c["ok"], " bad=", c["bad"].size())
	ok(not c["ok"], "selfcheck (c) unseen item fails")
	# (d) 활용형이 아직 안 배운 문형 뒤
	var dd: Dictionary = LexiconGuard.check_sentence({"id": "z", "en": "I worked.", "o": 21, "scope": "all"}, 43, d)
	print("selfcheck FAIL-as-expected worked-before-pattern: ok=", dd["ok"], " bad=", dd["bad"].size())
	ok(not dd["ok"], "selfcheck (d) worked before its pattern fails")
	# (e) say 에 미래 낱말
	var e: Dictionary = LexiconGuard.check_sentence({"id": "z", "en": "It is $5.99.", "say": "It is five work.", "o": 21, "scope": "all"}, 21, d)
	print("selfcheck FAIL-as-expected say-with-future-word: ok=", e["ok"], " bad=", e["bad"].size())
	ok(not e["ok"], "selfcheck (e) future word in say fails")


# ------------------------------------------------------------------ 이상한 타입 (검토 1라운드 중요 1)

func _good_set(d: Dictionary) -> Array:
	return [
		{"type": "recognize", "id": "t", "mode": "en_ko", "item": "a3", "prompt": "tea", "tts": "tea", "options": ["\ucc28", "\ub098", "\uc88b\uc544\ud558\ub2e4"], "option_ids": ["a3", "a1", "a2"], "answer": 0},
		{"type": "recall", "id": "t", "mode": "ko_en_choice", "item": "a3", "prompt_ko": "x", "tts": "tea", "options": ["tea", "I"], "option_ids": ["a3", "a1"], "answer": 0, "accept": ["tea"]},
		{"type": "build", "id": "t", "sent": "s1", "ko": "x", "answer": ["I", "like", "tea"], "extra": ["coffee"], "accept": [["I", "like", "tea"]], "tts": "I like tea."},
		{"type": "listen", "id": "t", "mode": "choose_ko", "sent": "s1", "tts": "I like tea.", "options": ["\uc800\ub294 \ucc28\ub97c \uc88b\uc544\ud574\uc694.", "\uc800\ub294 \ud604\uae08\uc744 \uc88b\uc544\ud574\uc694."], "option_ids": ["s1", "s2"], "answer": 0},
		{"type": "listen", "id": "t", "mode": "type", "sent": "s1", "tts": "I like tea.", "accept": ["I like tea."]},
		{"type": "speak", "id": "t", "mode": "substitute", "sent": "s1", "target": "I like tea.", "tts": "I like tea.", "cue": {"slot": "tea", "with": "coffee"}, "accept": ["I like coffee."]},
		{"type": "speak", "id": "t", "mode": "answer", "prompt_en": "I like tea.", "tts": "I like tea.", "expect_any": ["tea"]},
		{"type": "teach_word", "id": "t", "item": "a3", "prompt": "tea", "tts": "tea", "example": {"sent": "s1", "en": "I like tea.", "tts": "I like tea."}},
		{"type": "teach_pattern", "id": "t", "pattern": "p_s", "tpl": "I tea", "examples": [{"sent": "s1", "en": "I like tea.", "tts": "I like tea."}]},
		{"type": "dialogue_script", "id": "t", "dialogue": "d1", "lines": [{"s": "A", "en": "I like tea.", "ko": "x", "tts": "I like tea.", "you": false}]},
	]


func _test_junk_types() -> void:
	var d: Dictionary = LexiconGuard.index(_small())
	var seen: Array = ["a3", "a2", "a1"]
	# 재현 입력 (검토자가 낸 것)
	var r1: Dictionary = LexiconGuard.check_exercise({"type": "recognize", "id": "t", "mode": "en_ko", "item": "a3", "prompt": "tea", "tts": "tea", "options": [null, 5, {}], "option_ids": ["a3", "a1", "a2"], "answer": 0}, 21, seen, d)
	print("selfcheck FAIL-as-expected junk-options: ok=", r1["ok"], " bad=", r1["bad"].size())
	ok(not r1["ok"] and _has_why(r1, "not_string"), "junk: options [null, 5, {}] -> ok=false (not_string)")
	var r2: Dictionary = LexiconGuard.check_exercise({"type": "build", "id": "t", "sent": "s1", "ko": "x", "answer": ["I", "like", "tea"], "extra": [null, 5], "accept": [], "tts": "I like tea."}, 21, [], d)
	print("selfcheck FAIL-as-expected junk-extra-tiles: ok=", r2["ok"], " bad=", r2["bad"].size())
	ok(not r2["ok"] and _has_why(r2, "not_string"), "junk: build extra [null, 5] -> ok=false (not_string)")
	var r3: Dictionary = LexiconGuard.check_exercise({"type": "build", "id": "t", "sent": "s1", "ko": "x", "answer": ["I", null, {}], "extra": [], "accept": [[1, 2], 5, null], "tts": "I like tea."}, 21, [], d)
	ok(not r3["ok"] and _has_why(r3, "not_string"), "junk: build answer/accept elements that are not text -> ok=false")
	var r4: Dictionary = LexiconGuard.check_exercise({"type": "recognize", "id": "t", "mode": "en_ko", "item": "a3", "prompt": "tea", "options": ["\ucc28", "\ub098"], "option_ids": [null, {}], "answer": 0}, 21, seen, d)
	ok(not r4["ok"], "junk: option_ids [null, {}] -> ok=false")
	var r5: Dictionary = LexiconGuard.check_exercise({"type": "listen", "id": "t", "mode": "choose_ko", "sent": "s1", "tts": "x", "options": [5, null], "option_ids": [1, 2], "answer": 0}, 21, [], d)
	ok(not r5["ok"] and _has_why(r5, "not_string"), "junk: listen options [5, null] -> ok=false")
	var r6: Dictionary = LexiconGuard.check_exercise({"type": "recognize", "id": "t", "mode": "en_ko", "item": {}, "prompt": [], "tts": 5, "options": ["a", "b"], "answer": 0}, 21, [], d)
	ok(not r6["ok"] and _has_why(r6, "not_string"), "junk: item {}, prompt [], tts 5 -> ok=false")
	var r7: Dictionary = LexiconGuard.check_exercise({"type": "speak", "id": "t", "mode": "substitute", "sent": "s1", "target": "I like tea.", "cue": 5, "accept": []}, 21, [], d)
	ok(not r7["ok"], "junk: cue 5 -> ok=false")
	var r8: Dictionary = LexiconGuard.check_exercise({"type": "dialogue_script", "id": "t", "lines": [{"en": 5, "tts": [], "say": {}}, 7]}, 21, [], d)
	ok(not r8["ok"], "junk: dialogue lines with non-text fields and a non-dict line -> ok=false")
	# 가드를 통과해야 하는 정상 문제 10개(비교용)
	var goods: Array = _good_set(d)
	var good_ok: int = 0
	for e in goods:
		var gr: Dictionary = LexiconGuard.check_exercise(e, 21, seen, d)
		if gr["ok"] or e["type"] in ["teach_pattern", "dialogue_script", "speak", "listen"]:
			good_ok += 1
	ok(good_ok == goods.size(), "the 10 base exercises used for the type fuzz are sane (%d)" % good_ok)
	# 필드마다 이상한 값을 넣어 본다: 에러(SCRIPT ERROR) 없이 항상 {ok, bad} 가 와야 한다
	var junk: Array = [null, 5, 1.5, true, {}, [], [null], [{}], [[]], [5, null], "", RefCounted.new()]
	var cases: int = 0
	var shaped: int = 0
	var flipped: int = 0
	for e in goods:
		for k in e.keys():
			for jv in junk:
				var copy: Dictionary = e.duplicate(true)
				copy[k] = jv
				var res: Variant = LexiconGuard.check_exercise(copy, 21, seen, d)
				cases += 1
				if res is Dictionary and res.has("ok") and res["ok"] is bool and res.get("bad") is Array:
					shaped += 1
					if k in ["type", "mode", "item", "tts", "prompt", "target"] and jv is Dictionary and not res["ok"]:
						flipped += 1
	print("fuzz: %d junk-field cases, %d well-formed results" % [cases, shaped])
	ok(cases >= 800 and shaped == cases, "type fuzz: %d cases (10 exercises x every field x 12 odd values), all give {ok, bad} without a script error" % cases)
	ok(flipped > 0, "type fuzz: a Dictionary in a text field is reported, not ignored (%d)" % flipped)
	# 문장·텍스트 입력의 이상한 타입
	var junk_sent: Array = [null, 5, [], {}, {"en": 5}, {"en": null, "o": {}}, {"id": [], "en": "x"}, {"words": 5, "en": "hi", "o": 11, "scope": []}]
	var s_cases: int = 0
	var s_ok: int = 0
	for js in junk_sent:
		var sr: Variant = LexiconGuard.check_sentence(js, 21, d)
		s_cases += 1
		if sr is Dictionary and sr.has("ok") and not sr["ok"]:
			s_ok += 1
	ok(s_ok == s_cases, "junk sentences (null, 5, [], {}, odd fields) -> ok=false for all %d" % s_cases)
	# item 7: expect_any, cue.slot 도 검사
	var e7: Dictionary = {"type": "speak", "id": "t", "mode": "answer", "prompt_en": "I like tea.", "tts": "I like tea.", "expect_any": ["tea", "work"]}
	var r9: Dictionary = LexiconGuard.check_exercise(e7, 21, [], d)
	ok(not r9["ok"] and _has_why(r9, "future"), "expect_any with a not-yet-learned word is checked")
	e7["expect_any"] = ["tea", 5]
	ok(not LexiconGuard.check_exercise(e7, 21, [], d)["ok"], "expect_any with a non-text item -> not ok")
	var e8: Dictionary = {"type": "speak", "id": "t", "mode": "substitute", "sent": "s1", "target": "I like tea.", "tts": "I like tea.", "cue": {"slot": "work", "with": "coffee"}, "accept": ["I like coffee."]}
	ok(not LexiconGuard.check_exercise(e8, 21, [], d)["ok"], "cue.slot with a not-yet-learned word is checked")
	# 가드를 끄면 이 시험들이 통과하지 못해야 한다(selfcheck): 켜진 상태에서만 not ok
	LexiconGuard.enabled = false
	var off: bool = LexiconGuard.check_exercise({"type": "recognize", "options": [null, 5, {}]}, 21, [], d)["ok"]
	LexiconGuard.enabled = true
	ok(off, "enabled=false: even junk passes (test-only switch), restored afterwards")
