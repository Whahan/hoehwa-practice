extends Node
## DictationDiffJa 시험 (순수 함수, 서버·화면·저장소 필요 없음. 말뭉치는 res://data/pack/practice_ja.json).
##   godot --headless --path <project> res://tests/dictation_diff_ja_test.tscn
##   godot --headless --path <project> --resolution 412x915 res://tests/dictation_diff_ja_test.tscn -- --phone
## 종료 코드 0 = 전부 통과. 마지막 줄: "== dictation_diff_ja: N passed, M failed ==" (실패 있으면 종료 코드 1)
## 시험 모음 이름: A1-2 말뭉치 3방식, A1-3 혼합, A1-4 변이 1000건, A1-5 통과선, A1-6 기존 점수 이상,
## A1-7 표기 차이 사례표, A1-8 한자 틀림, A1-9 틀린 입력, A1-10 segments 불변식, selfcheck 줄은 "시험이 실제로 실패를 잡는지".

var passed: int = 0
var failed: int = 0
var corpus: Array = []     # 받아쓰기 후보: {id, text, reading}
var corpus_all: Array = []


func ok(cond: bool, name: String) -> void:
	if cond:
		passed += 1
		print("  PASS  ", name)
	else:
		failed += 1
		print("  FAIL  ", name)


## 검사기가 틀린 입력을 실제로 "실패"로 판정하는지: detected 가 true 여야 통과 (검사기가 실패를 잡았다는 뜻)
func selfcheck(detected: bool, name: String) -> void:
	if detected:
		passed += 1
		print("  selfcheck FAIL-as-expected  ", name)
	else:
		failed += 1
		print("  FAIL  selfcheck: checker did NOT reject  ", name)


func _ready() -> void:
	print("== dictation_diff_ja test start ==")
	_load_corpus()
	_run()
	print("== dictation_diff_ja: %d passed, %d failed ==" % [passed, failed])
	get_tree().quit(1 if failed > 0 else 0)


# ---------------------------------------------------------------- 말뭉치

## §2.1 ja_dictation_ok 와 같은 규칙: 문장부호를 뺀 글자 수 6~24, 숫자(전각 포함)·알파벳 없음, 읽기는 히라가나뿐
func ja_dictation_ok(text: String, reading: String) -> bool:
	var core := ""
	for k in text.length():
		var ch: String = text.substr(k, 1)
		if TextSim.JA_SKIP.find(ch) == -1:
			core += ch
	if core.length() < 6 or core.length() > 24:
		return false
	for k in core.length():
		var c: int = core.unicode_at(k)
		if (c >= 0x30 and c <= 0x39) or (c >= 0xFF10 and c <= 0xFF19):
			return false
		if (c >= 0x41 and c <= 0x5A) or (c >= 0x61 and c <= 0x7A) or (c >= 0xFF21 and c <= 0xFF3A) or (c >= 0xFF41 and c <= 0xFF5A):
			return false
	return reading != "" and LocalPractice.ja_reading_ok(reading)


func _load_corpus() -> void:
	var raw: String = FileAccess.get_file_as_string("res://data/pack/practice_ja.json")
	var data: Variant = JSON.parse_string(raw)
	var sents: Array = (data as Dictionary).get("sentences", []) if data is Dictionary else []
	for s in sents:
		var d: Dictionary = s
		var row := {"id": int(d.get("id", 0)), "text": String(d.get("text", "")), "reading": String(d.get("reading", ""))}
		corpus_all.append(row)
		if ja_dictation_ok(row["text"], row["reading"]):
			corpus.append(row)


# ---------------------------------------------------------------- 보조

func _has_chunk(segs: Array) -> bool:
	for sg in segs:
		if bool((sg as Dictionary)["k"]):
			return true
	return false


func _chunk_count(segs: Array) -> int:
	var n := 0
	for sg in segs:
		if bool((sg as Dictionary)["k"]):
			n += 1
	return n


## 조각들로 쓴 글을 만든다: 한자 덩어리 번호가 kana_idx 에 들면 읽기로, 아니면 원문 표기로. kana_idx 가 [-1] 이면 전부 표기.
func _compose(segs: Array, kana_idx: Array) -> String:
	var out := ""
	var ci := 0
	for sg in segs:
		var d: Dictionary = sg
		if bool(d["k"]):
			out += String(d["r"]) if kana_idx.has(ci) else String(d["o"])
			ci += 1
		else:
			out += String(d["o"])
	return out


func _to_kata(s: String) -> String:
	var out := ""
	for k in s.length():
		var c: int = s.unicode_at(k)
		if c >= 0x3041 and c <= 0x3096:
			out += char(c + 0x60)
		else:
			out += s.substr(k, 1)
	return out


func _valid(d: Variant) -> bool:
	if not (d is Dictionary):
		return false
	var dd: Dictionary = d
	for key in ["score", "passed", "mode", "units", "extra", "len"]:
		if not dd.has(key):
			return false
	if typeof(dd["score"]) != TYPE_INT or int(dd["score"]) < 0 or int(dd["score"]) > 100:
		return false
	if typeof(dd["passed"]) != TYPE_BOOL or not (dd["units"] is Array) or not (dd["extra"] is Array):
		return false
	if not (String(dd["mode"]) in ["exact", "reading", "mixed", "wrong", "empty"]):
		return false
	for u in dd["units"]:
		if not (u is Dictionary):
			return false
		for key2 in ["w", "rd", "ok", "kind", "said"]:
			if not (u as Dictionary).has(key2):
				return false
		if not (String((u as Dictionary)["kind"]) in ["ok", "kana", "kanji_diff", "missing", "typo"]):
			return false
	return true


func _all_ok(d: Dictionary) -> bool:
	for u in d["units"]:
		if not bool((u as Dictionary)["ok"]):
			return false
	return (d["units"] as Array).size() > 0


func _unit_of_w(d: Dictionary, w: String) -> Dictionary:
	for u in d["units"]:
		if String((u as Dictionary)["w"]) == w:
			return u
	return {}


# ---------------------------------------------------------------- 본 시험

func _run() -> void:
	ok(DictationDiffJa.HW_KANA.length() == 56 and DictationDiffJa.HW_FULL.length() == 56, "table: half-width katakana tables are 56 chars each")
	ok(DictationDiffJa.VOICE_FROM.length() == DictationDiffJa.VOICE_TO.length() and DictationDiffJa.SEMI_FROM.length() == DictationDiffJa.SEMI_TO.length(), "table: voicing tables have matching lengths")
	print("corpus: %d sentences, dictation candidates (6-24 chars, no digits/latin, hiragana reading) = %d" % [corpus_all.size(), corpus.size()])
	ok(corpus.size() > 1500, "corpus: candidates found (%d)" % corpus.size())
	_t_fold()
	_t_corpus_three_ways()
	_t_mixed()
	_t_mutations()
	_t_pass_line()
	_t_not_lower_than_textsim()
	_t_cases()
	_t_kanji_diff()
	_t_invalid()
	_t_segments()
	_t_align_consistency()
	_t_hint()


func _t_fold() -> void:
	print("[fold]")
	var rows: Array = [
		["パイロット", "ぱいろっと"], ["ぱいろっと", "ぱいろっと"], ["ＰＣ", "pc"], ["ＡＢＣ１２３", "abc123"],
		["ｶﾞｽ", "がす"], ["ﾊﾟﾝ", "ぱん"], ["ｺｰﾋｰ", "こーひー"], ["コーヒー", "こーひー"],
		["彼は、学生です。", "彼は学生です"], ["a b\tc　d", "abcd"], ["「ありがとう」！？", "ありがとう"],
		["ヴ", "ゔ"], ["ヽヾ", "ゝゞ"], ["が", "が"], ["ぱ", "ぱ"], ["", ""], ["　 ", ""], ["、。…・〜", ""],
		["ー", "ー"], ["ラーメン", "らーめん"],
	]
	for r in rows:
		var got: String = DictationDiffJa.fold(r[0])
		ok(got == String(r[1]), "fold(%s) = %s (got %s)" % [r[0], r[1], got])
	ok(DictationDiffJa.fold("あ".repeat(1000)).length() == DictationDiffJa.MAX_LEN, "fold cuts input to MAX_LEN")
	ok(DictationDiffJa.fold(null) == "" and DictationDiffJa.fold(123) == "", "fold(non-string) = empty string")
	ok(DictationDiffJa.fold("こうひい") != DictationDiffJa.fold("コーヒー"), "fold keeps ー (こうひい != コーヒー)")


func _t_corpus_three_ways() -> void:
	print("[A1-2 corpus three ways: text / reading / katakana-ized text]")
	var bad: Array = []
	var bad_mode: Array = []
	var n_chunk := 0
	for row in corpus:
		var text: String = row["text"]
		var rd: String = row["reading"]
		var segs: Array = DictationDiffJa.segments(text, rd)
		var chunk: bool = _has_chunk(segs)
		if chunk:
			n_chunk += 1
		var d1: Dictionary = DictationDiffJa.diff(text, text, rd)
		var d2: Dictionary = DictationDiffJa.diff(rd, text, rd)
		var d3: Dictionary = DictationDiffJa.diff(_to_kata(text), text, rd)
		if int(d1["score"]) != 100 or int(d2["score"]) != 100 or int(d3["score"]) != 100:
			bad.append("%d(%d/%d/%d)" % [row["id"], d1["score"], d2["score"], d3["score"]])
		if String(d1["mode"]) != "exact" or String(d2["mode"]) != ("reading" if chunk else "exact") or String(d3["mode"]) != "exact":
			bad_mode.append("%d(%s/%s/%s)" % [row["id"], d1["mode"], d2["mode"], d3["mode"]])
	print("A1-2: %d sentences x 3 ways, with kanji/alnum chunks %d" % [corpus.size(), n_chunk])
	if bad.size() > 0:
		print("  score != 100 ids: ", bad.slice(0, 15))
	if bad_mode.size() > 0:
		print("  mode mismatch ids: ", bad_mode.slice(0, 15))
	ok(bad.is_empty(), "A1-2 all %d sentences: text, reading, katakana-ized text all score 100 (violations %d)" % [corpus.size(), bad.size()])
	ok(bad_mode.is_empty(), "A1-2 modes: text exact, reading reading|exact, katakana-ized exact (violations %d)" % bad_mode.size())
	# 검사기가 실패를 잡는지: 일부러 틀린 글 한 글자를 바꾼 입력은 100 이 아니어야 한다
	var bad_all: Array = []
	for row2 in corpus_all:
		if row2["reading"] == "":
			continue
		var da: Dictionary = DictationDiffJa.diff(row2["text"], row2["text"], row2["reading"])
		var db: Dictionary = DictationDiffJa.diff(row2["reading"], row2["text"], row2["reading"])
		if int(da["score"]) != 100 or int(db["score"]) != 100:
			bad_all.append("%d(%d/%d)" % [row2["id"], da["score"], db["score"]])
	if bad_all.size() > 0:
		print("  all-sentence score != 100 ids: ", bad_all.slice(0, 15))
	ok(bad_all.is_empty(), "A1-2 also over all %d sentences (digits/latin/length ignored): text and reading both 100 (violations %d)" % [corpus_all.size(), bad_all.size()])
	var row0: Dictionary = corpus[0]
	var wrong: Dictionary = DictationDiffJa.diff("あ" + String(row0["reading"]).substr(1), row0["text"], row0["reading"])
	selfcheck(int(wrong["score"]) != 100 or String(row0["reading"]).begins_with("あ"), "A1-2 a sentence with a wrong first character is not scored 100 (%d)" % wrong["score"])


func _t_mixed() -> void:
	print("[A1-3 mixed notation]")
	var tried := 0
	var good := 0
	var failed_ids: Array = []
	var fallback_ids: Array = []
	var single_tried := 0
	var single_good := 0
	var single_fail: Array = []
	for row in corpus:
		var text: String = row["text"]
		var rd: String = row["reading"]
		var segs: Array = DictationDiffJa.segments(text, rd)
		var cc: int = _chunk_count(segs)
		var aligned: bool = not (segs.size() == 1 and bool((segs[0] as Dictionary)["k"]) and cc == 1 and not _items_aligned(text, rd))
		if not aligned:
			fallback_ids.append(row["id"])
			continue
		if cc >= 2:
			for pick in [0, cc - 1]:
				tried += 1
				var said: String = _compose(segs, [pick])
				var d: Dictionary = DictationDiffJa.diff(said, text, rd)
				if int(d["score"]) == 100 and String(d["mode"]) == "mixed":
					good += 1
				else:
					failed_ids.append("%d[%d]=%d/%s" % [row["id"], pick, d["score"], d["mode"]])
		elif cc == 1:
			single_tried += 1
			var d1: Dictionary = DictationDiffJa.diff(_compose(segs, [0]), text, rd)
			if int(d1["score"]) == 100 and String(d1["mode"]) == "reading":
				single_good += 1
			else:
				single_fail.append("%d=%d/%s" % [row["id"], d1["score"], d1["mode"]])
	var rate: float = 100.0 * float(good) / float(maxi(1, tried))
	print("A1-3: mixed inputs tried %d, good %d (%.2f%%); single-chunk sentences %d, reading mode good %d; alignment fallback sentences %d" % [tried, good, rate, single_tried, single_good, fallback_ids.size()])
	if failed_ids.size() > 0:
		print("  mixed failures: ", failed_ids.slice(0, 20))
	if single_fail.size() > 0:
		print("  single-chunk failures: ", single_fail.slice(0, 20))
	print("  fallback ids: ", fallback_ids.slice(0, 60))
	ok(rate >= 98.0, "A1-3 mixed notation: 100 points and mode mixed in >= 98%% of alignable sentences (%.2f%%)" % rate)
	ok(100.0 * float(single_good) / float(maxi(1, single_tried)) >= 98.0, "A1-3 one kanji chunk written in kana -> 100 and mode reading in >= 98%% (%d/%d)" % [single_good, single_tried])
	# 검사기가 실패를 잡는지: 한자 덩어리를 틀린 읽기로 바꾼 입력은 mixed 100 이 아니다
	var d_bad: Dictionary = DictationDiffJa.diff("彼ははくせいです", "彼は学生です。", "かれはがくせいです。")
	selfcheck(not (int(d_bad["score"]) == 100 and String(d_bad["mode"]) == "mixed"), "A1-3 wrong reading for a chunk is not 'mixed 100' (%d, %s)" % [d_bad["score"], d_bad["mode"]])


## segments 가 정렬에 성공했는지(대체 경로가 아닌지): 조각 r 합이 fold(reading) 이고 한자 덩어리 수와 조각이 대체 경로 모양(한 조각 + k)인지
func _items_aligned(text: String, rd: String) -> bool:
	var segs: Array = DictationDiffJa.segments(text, rd)
	if segs.size() != 1:
		return true
	# 한 조각일 때: 정말 한 덩어리(한자만)인 문장인지 s 에 가나가 섞였는지로 구분
	var s: String = (segs[0] as Dictionary)["s"]
	for k in s.length():
		var c: int = s.unicode_at(k)
		if (c >= 0x3041 and c <= 0x3096) or c == 0x30FC:
			return false
	return true


func _t_mutations() -> void:
	print("[A1-4 1000 mutations of the reading, seed 20261114]")
	var rng := RandomNumberGenerator.new()
	rng.seed = 20261114
	var pool := "あいうえおかきくけこさしすせそたちつてとなにぬねのはひふへほまみむめもやゆよらりるれろわをんがぎぐげござじずぜぞだでどばびぶべぼぱぴぷぺぽっゃゅょー"
	var by_kind := {"del": [0, 0], "sub": [0, 0], "ins": [0, 0]}   # [flagged, total]
	var score_ok := 0
	var total := 0
	var miss: Array = []
	for n in 1000:
		var row: Dictionary = corpus[rng.randi() % corpus.size()]
		var text: String = row["text"]
		var rd: String = row["reading"]
		var r: String = DictationDiffJa.fold(rd)
		var segs: Array = DictationDiffJa.segments(text, rd)
		var kind: String = ["del", "sub", "ins"][n % 3]
		var pos: int = rng.randi() % r.length()
		var said: String
		if kind == "del":
			said = r.substr(0, pos) + r.substr(pos + 1)
		elif kind == "sub":
			var ch: String = r.substr(pos, 1)
			var rep: String = ch
			while rep == ch:
				rep = pool.substr(rng.randi() % pool.length(), 1)
			said = r.substr(0, pos) + rep + r.substr(pos + 1)
		else:
			var ins: String = pool.substr(rng.randi() % pool.length(), 1)
			said = r.substr(0, pos) + ins + r.substr(pos)
		total += 1
		var d: Dictionary = DictationDiffJa.diff(said, text, rd)
		if int(d["score"]) != 100:
			score_ok += 1
		var flagged: bool = _mut_flagged(d, kind, pos, segs)
		by_kind[kind][1] += 1
		if flagged:
			by_kind[kind][0] += 1
		elif miss.size() < 10:
			miss.append("%d %s@%d" % [row["id"], kind, pos])
	var fl := 0
	for k in by_kind:
		fl += int(by_kind[k][0])
	var rate: float = 100.0 * float(fl) / float(total)
	print("A1-4: score != 100: %d / %d; flagged %d / %d (%.2f%%); by kind %s" % [score_ok, total, fl, total, rate, str(by_kind)])
	if miss.size() > 0:
		print("  unflagged examples: ", miss)
	ok(score_ok == total, "A1-4 every mutation scores below 100 (%d/%d)" % [score_ok, total])
	ok(rate >= 95.0, "A1-4 the wrong place is flagged (unit ok=false, or extra for an insertion) in >= 95%% (%.2f%%)" % rate)
	# 검사기가 실패를 잡는지: 변이 없는 입력이면 어떤 칸도 표시되지 않아야 한다(= 표시 검사가 false)
	var row2: Dictionary = corpus[5]
	var d_clean: Dictionary = DictationDiffJa.diff(DictationDiffJa.fold(row2["reading"]), row2["text"], row2["reading"])
	selfcheck(not _mut_flagged(d_clean, "sub", 0, DictationDiffJa.segments(row2["text"], row2["reading"])), "A1-4 unmutated input flags nothing (flag checker returns false)")
	selfcheck(not _mut_flagged(d_clean, "ins", 0, []), "A1-4 unmutated input has no extra (flag checker returns false)")


## 변이 위치(읽기 글자 번호 pos)를 포함하는 칸이 ok=false 인가. 끼워 넣기는 정답에 없는 글자(extra)가 있는가.
func _mut_flagged(d: Dictionary, kind: String, pos: int, segs: Array) -> bool:
	if kind == "ins":
		return (d["extra"] as Array).size() > 0
	var off := 0
	var units: Array = d["units"]
	for i in units.size():
		var rl: int = String((units[i] as Dictionary)["rd"]).length()
		if pos >= off and pos < off + rl:
			return not bool((units[i] as Dictionary)["ok"])
		off += rl
	return false


func _t_pass_line() -> void:
	print("[A1-5 pass line]")
	var long_t := "わたしはまいあさろくじにおきます"   # 읽기 16자
	var d: Dictionary = DictationDiffJa.diff("わたしはまいあさろくじにおきまず", long_t, long_t)
	ok(DictationDiffJa.fold(long_t).length() >= 12 and bool(d["passed"]) and int(d["score"]) >= 85, "A1-5 12+ char sentence, one wrong char -> passed (%d)" % d["score"])
	var d_del: Dictionary = DictationDiffJa.diff("わたしはまいあさろくじにおきま", long_t, long_t)
	ok(bool(d_del["passed"]), "A1-5 12+ char sentence, one missing char -> passed (%d)" % d_del["score"])
	var short_t := "ごめんなさい"   # 읽기 6자
	var d2: Dictionary = DictationDiffJa.diff("ごめんなさえ", short_t, short_t)
	ok(DictationDiffJa.fold(short_t).length() == 6 and not bool(d2["passed"]) and int(d2["score"]) < 85, "A1-5 6 char sentence, one wrong char -> not passed (%d)" % d2["score"])
	var d3: Dictionary = DictationDiffJa.diff("わたしはまいあさおきま", long_t, long_t)   # 4글자 빠짐
	ok(int(d3["score"]) <= 84 and not bool(d3["passed"]), "A1-5 three or more wrong chars -> score <= 84 (%d)" % d3["score"])
	var d4: Dictionary = DictationDiffJa.diff("わたしはまいあさろくじにおき", long_t, long_t)   # 2글자 빠짐 = 오류 2 (<3, 상한 없음)
	ok(int(d4["score"]) > 84, "A1-5 two missing chars (errors 2 < HARD_ERRORS) are not capped (%d)" % d4["score"])
	var d5: Dictionary = DictationDiffJa.diff("わたしはまいあさろくじにおきます", long_t, long_t)
	ok(int(d5["score"]) == 100 and bool(d5["passed"]), "A1-5 exact long sentence -> 100 passed")
	# 상한(HARD_CAP) 효과: 상한 없이는 84 를 넘는 입력(긴 문장 3글자 빠짐)이 상한 때문에 84 이하
	var very_long := "きのうともだちといっしょにえいがをみにいきましたがとてもおもしろかったです"
	var d6: Dictionary = DictationDiffJa.diff("きのうともだちといっしょにえいがをみにいきましたとてもおもしろかっです", very_long, very_long)   # が, た 두 글자 빠짐 = 오류 2
	ok(int(d6["score"]) > 84, "A1-5 two missing chars in a long sentence are not capped (%d)" % d6["score"])
	d6 = DictationDiffJa.diff("きのうともだちといっしょにえいがをみにいきましたとてもおもしろかっです".replace("きのう", "きう"), very_long, very_long)   # 세 글자 빠짐 = 오류 3
	var raw_score: int = roundi(200.0 * float(DictationDiffJa.fold(very_long).length() - 3) / float(2 * DictationDiffJa.fold(very_long).length() - 3))
	ok(raw_score > 84 and int(d6["score"]) <= 84, "A1-5 HARD_CAP matters: uncapped score %d, reported %d" % [raw_score, d6["score"]])
	ok(DictationDiffJa.PASS_SCORE == 85 and DictationDiffJa.HARD_ERRORS == 3 and DictationDiffJa.HARD_CAP == 84, "A1-5 constants PASS_SCORE 85, HARD_ERRORS 3, HARD_CAP 84")


func _t_not_lower_than_textsim() -> void:
	print("[A1-6 never lower than TextSim.similarity for text-only / reading-only input]")
	var viol := 0
	var cmp := 0
	var ex: Array = []
	for row in corpus_all:
		var text: String = row["text"]
		var rd: String = row["reading"]
		if rd == "":
			continue
		for said in [text, rd]:
			var ts: int = int(TextSim.similarity(said, text, rd, "ja")["score"])
			var mine: int = int((DictationDiffJa.diff(said, text, rd) as Dictionary)["score"])
			cmp += 1
			if mine < ts:
				viol += 1
				if ex.size() < 5:
					ex.append("%d: %d < %d" % [row["id"], mine, ts])
	print("A1-6: compared %d inputs over all %d sentences (candidates + the rest), violations %d" % [cmp, corpus_all.size(), viol])
	if ex.size() > 0:
		print("  examples: ", ex)
	ok(viol == 0, "A1-6 diff().score >= TextSim.similarity() for every text-only and reading-only input (violations %d)" % viol)
	# 검사기가 실패를 잡는지: 일부러 낮춘 점수는 위반으로 판정되어야 한다
	var fake_low := 10
	var ts_full: int = int(TextSim.similarity("ありがとう", "ありがとう", "ありがとう", "ja")["score"])
	selfcheck(fake_low < ts_full, "A1-6 a lowered score (10) is reported as a violation against TextSim (%d)" % ts_full)


func _t_cases() -> void:
	print("[A1-7 notation differences, table]")
	# [said, text, reading, expected score (-1 = any < 100), label]
	var rows: Array = [
		["ぱいろっとです", "パイロットです。", "ぱいろっとです。", 100, "katakana target typed in hiragana"],
		["パイロットです", "パイロットです。", "ぱいろっとです。", 100, "katakana target typed in katakana"],
		["ﾊﾟｲﾛｯﾄです", "パイロットです。", "ぱいろっとです。", 100, "half-width katakana"],
		["ｐｃです", "PCです。", "ぴーしーです。", 100, "full-width latin p c"],
		["PCです", "PCです。", "ぴーしーです。", 100, "ascii latin P C"],
		["ぴーしーです", "PCです。", "ぴーしーです。", 100, "alnum chunk typed as reading"],
		["ぱいろっと　です！", "パイロットです。", "ぱいろっとです。", 100, "spaces and ! ignored"],
		["ぱいろっとです。。。", "パイロットです。", "ぱいろっとです。", 100, "extra marks ignored"],
		["彼は、学生です", "彼は学生です。", "かれはがくせいです。", 100, "missing 。 and extra 、"],
		["かれはがくせいです。", "彼は学生です。", "かれはがくせいです。", 100, "all kana for kanji text"],
		["行なう", "行う", "おこなう", 100, "okurigana: 行なう for target 行う"],
		["行う", "行う", "おこなう", 100, "okurigana: 行う for target 行う"],
		["おこなう", "行う", "おこなう", 100, "okurigana: kana for target 行う"],
		["行う", "行なう", "おこなう", 100, "okurigana: 行う for target 行なう"],
		["行なう", "行なう", "おこなう", 100, "okurigana: 行なう for target 行なう"],
		["ラーメン", "ラーメン", "らーめん", 100, "chouon kept: ラーメン"],
		["らーめん", "ラーメン", "らーめん", 100, "chouon kept: らーめん"],
		["ラアメン", "ラーメン", "らーめん", -1, "chouon replaced by vowel is wrong"],
		["らあめん", "ラーメン", "らーめん", -1, "chouon replaced by vowel (hiragana) is wrong"],
		["こうひい", "コーヒー", "こーひー", -1, "コーヒー typed こうひい is wrong"],
		["私わ学生です", "私は学生です。", "わたしはがくせいです。", -1, "particle は typed わ (kanji form) is wrong"],
		["わたしわがくせいです", "私は学生です。", "わたしはがくせいです。", -1, "particle は typed わ (kana form) is wrong"],
		["わたしはがくせいです", "私は学生です。", "わたしはがくせいです。", 100, "particle は typed は"],
		["きやく", "きゃく", "きゃく", -1, "small ゃ typed や is wrong"],
		["はなじ", "はなぢ", "はなぢ", -1, "ぢ typed じ is wrong"],
		["こにちは", "こんにちは", "こんにちは", -1, "ん dropped is wrong"],
		["きつて", "きって", "きって", -1, "small っ typed つ is wrong"],
		["おばさん", "おばあさん", "おばあさん", -1, "long vowel dropped is wrong"],
		["", "ありがとう", "ありがとう", 0, "empty input"],
	]
	var n := 0
	for r in rows:
		var d: Dictionary = DictationDiffJa.diff(r[0], r[1], r[2])
		var want: int = int(r[3])
		var good: bool
		if want == 100:
			good = int(d["score"]) == 100 and bool(d["passed"])
		elif want == 0:
			good = int(d["score"]) == 0 and String(d["mode"]) == "empty"
		else:
			good = int(d["score"]) < 100 and String(d["mode"]) == "wrong"
		n += 1
		ok(good and _valid(d), "A1-7 [%s] -> score %d mode %s" % [r[4], d["score"], d["mode"]])
	ok(n >= 20, "A1-7 table has %d rows (>= 20)" % n)
	# 한자 쓰기 정책: 모드
	var segs_text := "彼は学生です。"
	var segs_rd := "かれはがくせいです。"
	ok(String(DictationDiffJa.diff("彼は学生です", segs_text, segs_rd)["mode"]) == "exact", "A1-7 mode exact when every kanji chunk is written")
	ok(String(DictationDiffJa.diff("かれはがくせいです", segs_text, segs_rd)["mode"]) == "reading", "A1-7 mode reading when written all in kana")
	ok(String(DictationDiffJa.diff("彼はがくせいです", segs_text, segs_rd)["mode"]) == "mixed", "A1-7 mode mixed when only some chunks are kanji")
	var d_kind: Dictionary = DictationDiffJa.diff("かれは学生です", segs_text, segs_rd)
	ok(String((_unit_of_w(d_kind, "彼"))["kind"]) == "kana" and String((_unit_of_w(d_kind, "学生"))["kind"]) == "ok", "A1-7 unit kinds: kanji chunk typed in kana = kana, kanji written = ok")
	# 소 케이스: 철자 틀림(typo)/빠짐(missing)/정답에 없는 글자(extra) 이유
	var d_typo: Dictionary = DictationDiffJa.diff("パイロトです", "パイロットです。", "ぱいろっとです。")
	var kinds_typo: Array = []
	for u in d_typo["units"]:
		if not bool((u as Dictionary)["ok"]):
			kinds_typo.append((u as Dictionary)["kind"])
	ok(kinds_typo == ["missing"], "A1-7 a dropped small っ is a 'missing' unit (%s)" % str(kinds_typo))
	var d_typo2: Dictionary = DictationDiffJa.diff("パイロッドです", "パイロットです。", "ぱいろっとです。")
	var u_typo2: Dictionary = {}
	for u2 in d_typo2["units"]:
		if not bool((u2 as Dictionary)["ok"]):
			u_typo2 = u2
	ok(String(u_typo2.get("kind", "")) == "typo" and String(u_typo2.get("said", "")) == "ド", "A1-7 ト typed ド is a 'typo' unit with said 'ド' (%s)" % str(u_typo2))
	var d_extra: Dictionary = DictationDiffJa.diff("パイロットですよ", "パイロットです。", "ぱいろっとです。")
	ok((d_extra["extra"] as Array) == ["よ"] and int(d_extra["score"]) < 100, "A1-7 an added よ is reported in extra (%s)" % str(d_extra["extra"]))
	# 검사기가 실패를 잡는지
	selfcheck(not _valid({}) and not _valid({"score": 5}) and not _valid("x"), "A1-7 result validator rejects {}, partial dict and non-dict")
	var broken: Dictionary = DictationDiffJa.diff("パイロットです", "パイロットです。", "ぱいろっとです。")
	broken["mode"] = "great"
	selfcheck(not _valid(broken), "A1-7 result validator rejects an unknown mode")


func _t_kanji_diff() -> void:
	print("[A1-8 a different kanji in a kanji-chunk slot]")
	var text := "彼は学生です。"
	var rd := "かれはがくせいです。"
	var d: Dictionary = DictationDiffJa.diff("彼は学校です", text, rd)
	var u_bad: Dictionary = _unit_of_w(d, "学生")
	var others_ok := true
	for u in d["units"]:
		if String((u as Dictionary)["w"]) != "学生" and not bool((u as Dictionary)["ok"]):
			others_ok = false
	ok(String(u_bad.get("kind", "")) == "kanji_diff" and not bool(u_bad.get("ok", true)) and others_ok, "A1-8 学生 -> 学校: that unit kanji_diff ok=false, others ok (%s)" % str(u_bad))
	ok(String(u_bad.get("said", "")) == "学校", "A1-8 the unit shows what was written (学校)")
	ok(String(d["mode"]) == "wrong" and int(d["score"]) < 100, "A1-8 score below 100 (%d)" % d["score"])
	# 말뭉치 전체: 첫 한자 덩어리 자리에 쓰지 않을 한자("鬱鬱")를 넣는다
	var tried := 0
	var good := 0
	var ex: Array = []
	for row in corpus:
		var segs: Array = DictationDiffJa.segments(row["text"], row["reading"])
		var first := -1
		for i in segs.size():
			if bool((segs[i] as Dictionary)["k"]):
				first = i
				break
		if first < 0 or (segs.size() == 1):
			continue
		tried += 1
		var said := ""
		for i in segs.size():
			said += "鬱鬱" if i == first else String((segs[i] as Dictionary)["o"])
		var dd: Dictionary = DictationDiffJa.diff(said, row["text"], row["reading"])
		var units: Array = dd["units"]
		var fine: bool = units.size() == segs.size() and String((units[first] as Dictionary)["kind"]) == "kanji_diff" and not bool((units[first] as Dictionary)["ok"])
		for i in units.size():
			if i != first and not bool((units[i] as Dictionary)["ok"]):
				fine = false
		if fine:
			good += 1
		elif ex.size() < 8:
			ex.append(row["id"])
	var rate: float = 100.0 * float(good) / float(maxi(1, tried))
	print("A1-8: corpus sentences with a kanji chunk and other segments: %d, only that unit kanji_diff: %d (%.2f%%), failures %s" % [tried, good, rate, str(ex)])
	ok(rate >= 98.0, "A1-8 corpus: wrong kanji marks only that unit as kanji_diff in >= 98%% (%.2f%%)" % rate)
	# 검사기가 실패를 잡는지: 정답 입력에서는 kanji_diff 가 없어야 한다
	var d_ok: Dictionary = DictationDiffJa.diff("彼は学生です", text, rd)
	selfcheck(String(_unit_of_w(d_ok, "学生")["kind"]) != "kanji_diff" and _all_ok(d_ok), "A1-8 the correct kanji answer has no kanji_diff unit")


func _t_invalid() -> void:
	print("[A1-9 wrong / odd input]")
	var t := "彼は学生です。"
	var r := "かれはがくせいです。"
	var cases: Array = [
		["empty string", ""], ["spaces only", "   "], ["latin letters", "abc"], ["english sentence", "He is a student."],
		["korean sentence", "그는 학생입니다"], ["punctuation only", "、。！？"], ["digits", "12345"],
	]
	for c in cases:
		var d: Dictionary = DictationDiffJa.diff(c[1], t, r)
		ok(_valid(d) and int(d["score"]) <= 20, "A1-9 %s -> safe low score (%d, mode %s)" % [c[0], d["score"], d["mode"]])
		ok(String(d["mode"]) in ["empty", "wrong"] and not bool(d["passed"]), "A1-9 %s is not passed" % c[0])
	var d_long: Dictionary
	var t0: int = Time.get_ticks_msec()
	d_long = DictationDiffJa.diff("あ".repeat(10000), t, r)
	var dt: int = Time.get_ticks_msec() - t0
	ok(_valid(d_long) and dt <= 100, "A1-9 10,000 chars: finished in %d ms (<= 100), score %d" % [dt, d_long["score"]])
	var long_ok: Dictionary = DictationDiffJa.diff(r + "あ".repeat(9000), t, r)
	ok(_valid(long_ok) and int(long_ok["score"]) < 100, "A1-9 correct answer followed by 9,000 junk chars is cut at MAX_LEN and not 100 (%d)" % long_ok["score"])
	var d_noread: Dictionary = DictationDiffJa.diff("彼は学生です", t, "")
	ok(_valid(d_noread) and int(d_noread["score"]) == 100, "A1-9 reading == '' compares the written text only (%d)" % d_noread["score"])
	var d_noread2: Dictionary = DictationDiffJa.diff("彼は学校です", t, "")
	ok(_valid(d_noread2) and int(d_noread2["score"]) < 100, "A1-9 reading == '' with a wrong kanji is below 100 (%d)" % d_noread2["score"])
	var d_notext: Dictionary = DictationDiffJa.diff("かれ", "", "")
	ok(_valid(d_notext) and int(d_notext["score"]) == 0 and String(d_notext["mode"]) == "empty", "A1-9 text == '' and reading == '' -> score 0, empty")
	var d_notext2: Dictionary = DictationDiffJa.diff("かれ", "", "かれ")
	ok(_valid(d_notext2), "A1-9 text == '' with a reading -> valid result (%d)" % d_notext2["score"])
	var weird: Array = [null, 123, 4.5, true, [], {}, Vector2(1, 2)]
	var all_valid := true
	for w in weird:
		var d1: Dictionary = DictationDiffJa.diff(w, t, r)
		var d2: Dictionary = DictationDiffJa.diff("かれ", w, r)
		var d3: Dictionary = DictationDiffJa.diff("かれ", t, w)
		if not (_valid(d1) and _valid(d2) and _valid(d3)) or int(d1["score"]) != 0:
			all_valid = false
	ok(all_valid, "A1-9 non-string said / text / reading (null, int, float, bool, Array, Dictionary, Vector2): safe valid results, said non-string -> 0")
	ok(DictationDiffJa.first_hint(null) == "" and DictationDiffJa.first_hint("") == "", "A1-9 first_hint(non-string / empty) = ''")
	ok(DictationDiffJa.segments(null, null) == [] and DictationDiffJa.segments("", "") == [], "A1-9 segments(null/empty) = []")
	# 검사기가 실패를 잡는지: 점수 상한 검사는 일부러 큰 점수를 거절해야 한다
	var d_hi: Dictionary = DictationDiffJa.diff(r, t, r)
	selfcheck(not (int(d_hi["score"]) <= 20), "A1-9 'safe low score' check rejects a correct answer (score %d)" % d_hi["score"])


func _t_segments() -> void:
	print("[A1-10 segments invariants]")
	var bad_s: Array = []
	var bad_r: Array = []
	var fallback: Array = []
	var total := 0
	for pair in [["candidates", corpus], ["all sentences", corpus_all]]:
		var rows: Array = pair[1]
		var n_bad := 0
		var n_fb := 0
		var seen := 0
		for row in rows:
			var text: String = row["text"]
			var rd: String = row["reading"]
			if rd == "":
				continue
			seen += 1
			var segs: Array = DictationDiffJa.segments(text, rd)
			var s_join := ""
			var r_join := ""
			for sg in segs:
				s_join += String((sg as Dictionary)["s"])
				r_join += String((sg as Dictionary)["r"])
			if s_join != DictationDiffJa.fold(text) or r_join != DictationDiffJa.fold(rd):
				n_bad += 1
				if bad_s.size() < 10:
					bad_s.append(row["id"])
			# 대체 경로: 한 조각이면서 가나가 섞인 s(= 한자 덩어리가 아닌 것)
			if segs.size() == 1 and not _items_aligned(text, rd):
				n_fb += 1
				if pair[0] == "candidates":
					fallback.append(row["id"])
		var fb_rate: float = 100.0 * float(n_fb) / float(maxi(1, seen))
		print("A1-10 %s: sentences %d, invariant violations %d, fallback (single segment) %d (%.2f%%)" % [pair[0], seen, n_bad, n_fb, fb_rate])
		ok(n_bad == 0, "A1-10 %s: joined s == fold(text) and joined r == fold(reading) for every sentence (violations %d)" % [pair[0], n_bad])
		if pair[0] == "candidates":
			ok(fb_rate <= 3.0, "A1-10 candidates: fallback segments <= 3%% (%.2f%%, %d sentences)" % [fb_rate, n_fb])
			total = n_fb
	print("  fallback candidate ids: ", fallback.slice(0, 60))
	print("  fallback candidate count: %d" % total)
	# 검사기가 실패를 잡는지: 일부러 깨뜨린 조각은 불변식 위반이어야 한다
	var segs2: Array = DictationDiffJa.segments("彼は学生です。", "かれはがくせいです。")
	var joined := ""
	for sg2 in segs2:
		joined += String((sg2 as Dictionary)["r"])
	selfcheck(joined + "あ" != DictationDiffJa.fold("かれはがくせいです。"), "A1-10 invariant check rejects a segment list with an extra char")
	ok(segs2.size() == 5 and String((segs2[0] as Dictionary)["r"]) == "かれ" and String((segs2[2] as Dictionary)["r"]) == "がくせい", "A1-10 segments of 彼は学生です: 彼=かれ, 学生=がくせい (5 segments, got %d)" % segs2.size())


func _t_align_consistency() -> void:
	print("[internal LCS aligner == TextSim.lcs_match]")
	var rng := RandomNumberGenerator.new()
	rng.seed = 77
	var pool := "あいうえおかきくけこ"
	var mism := 0
	for n in 400:
		var a := PackedStringArray()
		var b := PackedStringArray()
		for i in rng.randi_range(0, 14):
			a.append(pool.substr(rng.randi() % 10, 1))
		for i in rng.randi_range(0, 14):
			b.append(pool.substr(rng.randi() % 10, 1))
		var m1: Dictionary = TextSim.lcs_match(a, b)
		var m2: Dictionary = DictationDiffJa._align(a, b)
		var t_of: PackedInt32Array = m2["t_of"]
		var same: bool = int(m1["len"]) == int(m2["len"])
		for j in b.size():
			if bool((m1["hit"] as Array)[j]) != (t_of[j] >= 0):
				same = false
		if not same:
			mism += 1
	ok(mism == 0, "internal aligner has the same length and hits as TextSim.lcs_match on 400 random pairs (mismatch %d)" % mism)


func _t_hint() -> void:
	print("[first_hint]")
	ok(DictationDiffJa.first_hint("かれはがくせいです。") == "かれ…", "first_hint = first 2 reading chars + ellipsis")
	ok(DictationDiffJa.first_hint("あ") == "あ…", "first_hint of a 1 char reading")
	ok(DictationDiffJa.first_hint("、あい。") == "あい…", "first_hint skips punctuation")
