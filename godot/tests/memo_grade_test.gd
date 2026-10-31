extends Node
## 가사 외우기 M1: MemoGrade (채점 래퍼: 통과선 입력 85·말하기 75, 좋음 95·85). 순수 함수 시험 (서버·파일·마이크 없음).
##   godot --headless --path <project> res://tests/memo_grade_test.tscn
## Exit code 0 = all passed. Last line: "== memo_grade_test result: N passed, 0 failed =="
## 가사는 시험용으로 직접 쓴 문장뿐이다 (tests/fixtures/song/lyrics_en.txt, lyrics_ja.txt).

const EN_PATH := "res://tests/fixtures/song/lyrics_en.txt"
const JA_PATH := "res://tests/fixtures/song/lyrics_ja.txt"

var passed: int = 0
var failed: int = 0
var _reached_end: bool = false


func ok(cond: bool, name: String) -> void:
	if cond:
		passed += 1
		print("  PASS  ", name)
	else:
		failed += 1
		print("  FAIL  ", name)


func _ready() -> void:
	print("== memo_grade_test start ==")
	_run()
	_reached_end = true
	ok(_reached_end, "끝까지 실행됨 (구간 끝 플래그)")
	print("== memo_grade_test result: %d passed, %d failed ==" % [passed, failed])
	get_tree().quit(1 if failed > 0 else 0)


func _fixture(path: String) -> Array:
	var out: Array = []
	var f: FileAccess = FileAccess.open(path, FileAccess.READ)
	if f == null:
		return out
	for l in f.get_as_text().split("\n"):
		var s: String = String(l).strip_edges()
		if s == "" or s.begins_with("#"):
			continue
		out.append(s)
	return out


func _all(a: Array, v: bool) -> bool:
	if a.is_empty():
		return false
	for x in a:
		if bool(x) != v:
			return false
	return true


func _false_at(marks: Array) -> Array:
	var out: Array = []
	for k in marks.size():
		if not bool(marks[k]):
			out.append(k)
	return out


## TextSim 점수가 정확히 score 가 되는 일본어 (줄, 입력) 한 쌍을 찾는다. 줄 = 서로 다른 히라가나 T자,
## 입력 = 줄 앞 L자 + 줄에 없는 가타카나 (S-L)자 -> LCS 가 L 이라 점수 = round(200*L/(S+T)).
func _ja_pair_for(score: int) -> Dictionary:
	for t_len in range(8, 41):
		for s_len in range(1, 41):
			for l in range(0, mini(s_len, t_len) + 1):
				if roundi(2.0 * float(l) / float(s_len + t_len) * 100.0) != score:
					continue
				var target: String = ""
				for i in t_len:
					target += String.chr(0x3041 + i)
				var said: String = target.left(l)
				for i in s_len - l:
					said += String.chr(0x30A1 + i)
				if int(TextSim.similarity(said, target, "", "ja")["score"]) == score:
					return {"text": target, "said": said}
	return {}


func _run() -> void:
	var en: Array = _fixture(EN_PATH)
	var ja: Array = _fixture(JA_PATH)
	ok(en.size() == 6 and ja.size() == 5, "픽스처: 영어 6줄, 일본어 5줄")

	# ---- 통과선 상수 (사용자 결정 §12.1b)
	ok(MemoGrade.PASS_TYPE == 85 and MemoGrade.PASS_SPEAK == 75 and MemoGrade.GOOD_TYPE == 95 and MemoGrade.GOOD_SPEAK == 85, "상수: 통과 85/75, 좋음 95/85")

	# ---- M1-8 경계: 점수만으로 낸 판정
	ok(not MemoGrade.verdict(84, "type")["passed"] and MemoGrade.verdict(85, "type")["passed"], "verdict: type 84 불통과 · 85 통과")
	ok(not MemoGrade.verdict(74, "speak")["passed"] and MemoGrade.verdict(75, "speak")["passed"], "verdict: speak 74 불통과 · 75 통과")
	ok(not MemoGrade.verdict(94, "type")["good"] and MemoGrade.verdict(95, "type")["good"], "verdict: type good 94 아님 · 95 좋음")
	ok(not MemoGrade.verdict(84, "speak")["good"] and MemoGrade.verdict(85, "speak")["good"], "verdict: speak good 84 아님 · 85 좋음")
	ok(MemoGrade.verdict(80, "speak")["passed"] and not MemoGrade.verdict(80, "type")["passed"], "verdict: 같은 80점이 speak 는 통과, type 은 불통과")

	# ---- M1-8 경계: 실제 채점 경로 (점수가 정확히 나오는 일본어 입력)
	for pair in [[84, "type", false, false], [85, "type", true, false], [94, "type", true, false], [95, "type", true, true],
			[74, "speak", false, false], [75, "speak", true, false], [84, "speak", true, false], [85, "speak", true, true]]:
		var want_score: int = pair[0]
		var via: String = pair[1]
		var made: Dictionary = _ja_pair_for(want_score)
		if made.is_empty():
			ok(false, "점수 %d 를 내는 입력을 찾지 못함" % [want_score])
			continue
		var r: Dictionary = MemoGrade.grade("ja", made["said"], {"text": made["text"]}, via)
		ok(int(r["score"]) == want_score and bool(r["passed"]) == bool(pair[2]) and bool(r["good"]) == bool(pair[3]) and r["via"] == via,
			"실채점 %s %d점 -> passed=%s good=%s (실제 %d/%s/%s)" % [via, want_score, str(pair[2]), str(pair[3]), int(r["score"]), str(r["passed"]), str(r["good"])])

	# ---- M1-7 영어
	var line_en: Dictionary = {"text": "I count my steps to the old blue chair", "reading": ""}
	var all_full: bool = true
	var size_ok: bool = true
	for t in en:
		var r2: Dictionary = MemoGrade.grade("en", t, {"text": t})
		all_full = all_full and int(r2["score"]) == 100 and r2["passed"] and r2["good"] and _all(r2["marks"], true) and not r2["silent"]
		size_ok = size_ok and (r2["marks"] as Array).size() == MemoMask.units(t, "en")["units"].size()
	ok(all_full, "영어: 정답 줄 입력 -> 100·passed·good·marks 전부 true (6줄)")
	ok(size_ok, "영어: marks 길이 == 단위 수 (6줄)")
	var miss: Dictionary = MemoGrade.grade("en", "I count my steps to the old chair", line_en)
	ok(int(miss["score"]) == 94 and int(miss["score"]) == int(DictationDiff.diff("I count my steps to the old chair", line_en["text"])["score"]),
		"영어: blue 빠짐 -> 94, DictationDiff 점수와 같음 (실제 %d)" % [int(miss["score"])])
	ok(miss["passed"] and not miss["good"], "영어: blue 빠짐 -> passed:true, good:false")
	ok(_false_at(miss["marks"]) == [7], "영어: blue 위치(7)만 false (실제 %s)" % [str(_false_at(miss["marks"]))])
	ok(str((miss["detail"] as Array)[7]["w"]) == "blue" and (miss["detail"] as Array)[7]["kind"] == "missing", "영어: detail[7] 은 blue·missing")
	var other: Dictionary = MemoGrade.grade("en", "Every morning the river is wide", line_en)
	ok(not other["passed"] and int(other["score"]) < 85 and not other["silent"], "영어: 전혀 다른 문장 -> passed:false")
	var neg: Dictionary = MemoGrade.grade("en", "I count my steps to the old not blue chair", line_en)
	ok(not neg["passed"] and "not" in neg["extra"] and int(neg["score"]) == int(DictationDiff.diff("I count my steps to the old not blue chair", line_en["text"])["score"]),
		"영어: 부정어 not 추가 -> DictationDiff 규칙대로 불통과, extra 에 not")
	var typo: Dictionary = MemoGrade.grade("en", "I count my steps to the old blue chiar", line_en)
	ok((typo["detail"] as Array)[8]["kind"] == "typo" and (typo["detail"] as Array)[8]["said"] == "chiar" and not typo["marks"][8], "영어: 철자 틀림 -> detail kind typo + 틀리게 쓴 단어")
	var sp: Dictionary = MemoGrade.grade("en", "I count my steps to the old chair", line_en, "speak")
	ok(sp["passed"] and sp["good"] and int(sp["threshold"]) == 75 and sp["via"] == "speak", "영어: 같은 94점이 speak 에서는 good:true, threshold 75")
	ok(int(miss["threshold"]) == 85 and miss["via"] == "type", "영어: type 의 threshold 85")
	ok(MemoGrade.grade("en", "I COUNT my steps, to the old blue chair!", line_en)["score"] == 100, "영어: 대소문자·구두점 무시 (100점)")

	# ---- M1-9 일본어
	var ja_full: bool = true
	var ja_size: bool = true
	var ja_reuse: bool = true
	for t in ja:
		var rj: Dictionary = MemoGrade.grade("ja", t, {"text": t})
		ja_full = ja_full and int(rj["score"]) == 100 and rj["passed"] and rj["good"] and _all(rj["marks"], true)
		ja_size = ja_size and (rj["marks"] as Array).size() == MemoMask.units(t, "ja")["units"].size()
		ja_reuse = ja_reuse and int(rj["score"]) == int(SongStudy.dictation_score("ja", t, {"text": t})["score"])
	ok(ja_full, "일본어: 정답 -> 100·passed·good·marks 전부 true (5줄)")
	ok(ja_size, "일본어: marks 길이 == 단위 수 (5줄)")
	ok(ja_reuse, "일본어: 점수는 SongStudy.dictation_score 와 같음 (재사용)")
	var l2: Dictionary = {"text": "青い椅子まで歩数をかぞえる", "reading": "あおいいすまでほすうをかぞえる"}
	var wrong: Dictionary = MemoGrade.grade("ja", "青い椅子まで月火をかぞえる", l2)
	ok(MemoMask.ja_split(l2["text"])[3] == "歩数" and _false_at(wrong["marks"]) == [3], "일본어: 한 단위(歩数)만 틀림 -> 그 단위(3)만 false (실제 %s)" % [str(_false_at(wrong["marks"]))])
	ok(int(wrong["score"]) == 85 and wrong["passed"] and not wrong["good"], "일본어: 13글자 중 2글자 틀림 -> 85점·통과·good 아님 (실제 %d)" % [int(wrong["score"])])
	var by_reading: Dictionary = MemoGrade.grade("ja", "あおいいすまでほすうをかぞえる", l2)
	ok(by_reading["passed"] and int(by_reading["score"]) == 100 and _all(by_reading["marks"], true), "일본어: 읽기를 주고 히라가나로 입력 -> 통과, marks 전부 true")
	var no_reading: Dictionary = MemoGrade.grade("ja", "あおいいすまでほすうをかぞえる", {"text": l2["text"]})
	ok(not no_reading["passed"] and int(no_reading["score"]) < 85, "일본어: 읽기 없이 히라가나 입력 -> 불통과 (%d)" % [int(no_reading["score"])])
	var punct: Dictionary = {"text": "朝の窓辺で、小さなやかんが鳴る。"}
	var rp: Dictionary = MemoGrade.grade("ja", "朝の窓辺で小さなやかんが鳴る", punct)
	ok((rp["marks"] as Array).size() == MemoMask.units(punct["text"], "ja")["units"].size() and int(rp["score"]) == 100 and _all(rp["marks"], true),
		"일본어: JA_SKIP(구두점) 있는 줄도 marks.size == units.size, 정답 100")
	var rp2: Dictionary = MemoGrade.grade("ja", "朝の窓辺で、月火なやかんが鳴る。", punct)
	ok((rp2["marks"] as Array).size() == 5 and _false_at(rp2["marks"]).size() >= 1 and rp2["marks"][0] and rp2["marks"][4], "일본어: 구두점 줄에서 틀린 글자가 있는 단위만 false")

	# ---- M1-10 틀린 입력
	for blank in ["", "   ", "\n\t "]:
		var rb: Dictionary = MemoGrade.grade("en", blank, line_en)
		ok(rb["silent"] and int(rb["score"]) == 0 and not rb["passed"] and not rb["good"] and (rb["marks"] as Array).size() == 9 and _all(rb["marks"], false),
			"빈 입력 %s -> silent:true, score 0, passed:false" % [var_to_str(blank)])
	ok(MemoGrade.grade("ja", "  ", {"text": ja[0]})["silent"], "일본어 공백 입력 -> silent")
	ok(MemoGrade.grade("en", "", line_en, "speak")["silent"] and int(MemoGrade.grade("en", "", line_en, "speak")["threshold"]) == 75, "speak 무음 -> silent, threshold 75")
	var long_in: String = "blue ".repeat(400)
	var rl: Dictionary = MemoGrade.grade("en", long_in, line_en)
	ok(int(rl["score"]) >= 0 and int(rl["score"]) <= 100 and (rl["said"] as String).length() <= MemoGrade.SAID_MAX, "2000자 입력 -> 점수 0~100, said 상한 %d" % [MemoGrade.SAID_MAX])
	var rl2: Dictionary = MemoGrade.grade("ja", "あ".repeat(2000), {"text": ja[1]})
	ok(int(rl2["score"]) >= 0 and int(rl2["score"]) <= 100 and not rl2["passed"], "일본어 2000자 입력 -> 0~100, 불통과")
	var ctrl: Dictionary = MemoGrade.grade("en", "I count" + String.chr(1) + "my steps" + String.chr(7) + "to the old blue chair", line_en)
	ok(int(ctrl["score"]) == 100 and (ctrl["said"] as String).find(String.chr(1)) == -1, "제어문자는 공백으로 -> 100점, said 에 제어문자 없음")
	var emo: Dictionary = MemoGrade.grade("en", "😀😀😀", line_en)
	ok(int(emo["score"]) == 0 and not emo["passed"] and not emo["silent"], "이모지만 입력 -> 0점, 불통과 (예외 0)")
	var emo2: Dictionary = MemoGrade.grade("ja", "😀😀😀", {"text": ja[0]})
	ok(int(emo2["score"]) == 0 and not emo2["passed"], "일본어 이모지 입력 -> 0점")
	var nonstr_ok: bool = true
	for bad in [123, null, 1.5, [], {}, true]:
		var rn: Dictionary = MemoGrade.grade("en", bad, line_en)
		nonstr_ok = nonstr_ok and rn["silent"] and int(rn["score"]) == 0 and not rn["passed"]
		var rn2: Dictionary = MemoGrade.grade("ja", bad, {"text": ja[0]})
		nonstr_ok = nonstr_ok and rn2["silent"] and int(rn2["score"]) == 0
	ok(nonstr_ok, "said 가 String 아닌 값(int/null/float/배열/사전/bool) -> silent·0점, 예외 0")
	var line_ok: bool = true
	for bad_line in [{}, {"reading": "x"}, {"text": 5}, {"text": null}, null, 7, [], "", {"text": ""}]:
		var rz: Dictionary = MemoGrade.grade("en", "hello there", bad_line)
		line_ok = line_ok and int(rz["score"]) == 0 and not rz["passed"] and (rz["marks"] as Array).is_empty()
		var rz2: Dictionary = MemoGrade.grade("ja", "こんにちは", bad_line)
		line_ok = line_ok and int(rz2["score"]) == 0 and not rz2["passed"] and (rz2["marks"] as Array).is_empty()
	ok(line_ok, "line 이 빈 사전·text 없음/문자열 아님/null/숫자/배열/빈 문자열 -> 0점·불통과·marks 0개, 예외 0")
	var nounit_en: Dictionary = MemoGrade.grade("en", "hello", {"text": "!!! ..."})
	var nounit_ja: Dictionary = MemoGrade.grade("ja", "こんにちは", {"text": "、。"})
	ok(not nounit_en["passed"] and (nounit_en["marks"] as Array).is_empty() and int(nounit_en["score"]) == 0 and not nounit_en["silent"], "영어 단위 0개 줄 -> 불통과, marks 0개")
	ok(not nounit_ja["passed"] and (nounit_ja["marks"] as Array).is_empty() and int(nounit_ja["score"]) == 0, "일본어 단위 0개 줄 -> 불통과, marks 0개")
	var lang_ok: bool = true
	for bad_lang in [null, "fr", 5, "", "EN"]:
		var rg: Dictionary = MemoGrade.grade(bad_lang, "I count my steps to the old blue chair", line_en)
		lang_ok = lang_ok and int(rg["score"]) == 100
	ok(lang_ok, "lang 이 이상하면 영어로 처리 (예외 0)")
	var untouched: Dictionary = {"text": "I count my steps to the old blue chair", "reading": "", "i": 3}
	var before: String = var_to_str(untouched)
	MemoGrade.grade("en", "I count", untouched)
	ok(var_to_str(untouched) == before, "채점이 line 사전을 바꾸지 않음")

	# ---- 자가 평가·via 정규화
	var sg: Dictionary = MemoGrade.self_result(true)
	var sb: Dictionary = MemoGrade.self_result(false)
	ok(sg["passed"] and sg["good"] and int(sg["score"]) == 100 and sg["via"] == "self" and not sg["silent"], "self_result(true): 통과·좋음·100점")
	ok(not sb["passed"] and not sb["good"] and int(sb["score"]) == 0 and sb["via"] == "self", "self_result(false): 불통과·0점")
	ok(MemoGrade.grade("en", "I count my steps to the old blue chair", line_en, "self")["via"] == "type" and MemoGrade.grade("en", "I count", line_en, null)["via"] == "type",
		"grade 의 via 가 type/speak 가 아니면 type 으로 (자가 평가는 self_result)")
	ok(MemoGrade.threshold("speak") == 75 and MemoGrade.threshold("type") == 85 and MemoGrade.threshold(null) == 85, "threshold(via)")
