class_name MemoGrade
extends RefCounted
## 가사 외우기 채점 래퍼 (설계 docs/lyrics_memorize_design.md §3.4, §5.4). 순수 함수만 있다.
## 새 채점기를 만들지 않고 SongStudy.dictation_score (영어 DictationDiff.diff, 일본어 TextSim.similarity) 를 그대로 쓴다.
## 통과선 (사용자 결정 §12.1b): 입력 85, 말하기 75. "좋음"(복습 평가 Good 후보) 선: 입력 95, 말하기 85.
##
## grade(lang, said, line, via) -> {
##   score: int(0-100), passed: bool, good: bool, via: "type"|"speak", threshold: int,
##   marks: Array[bool]  # MemoMask.units(line.text, lang) 의 단위마다 맞음/틀림 (같은 길이)
##   extra: Array[String]  # 더한 단어 (영어만)
##   detail: Array[{w, ok, kind, said?}]  # 단위마다 (영어: kind ok|missing|typo + 틀리게 쓴 said, 일본어: ok|missing)
##   said: String  # 정리한 입력, silent: bool  # 입력이 비었음 (시도로 세지 않는다)
## }
## 어떤 입력에도 예외를 내지 않는다 (said 가 문자열이 아니거나, line 이 비었거나, 단위가 0개여도).

const PASS_TYPE := 85
const PASS_SPEAK := 75
const GOOD_TYPE := 95
const GOOD_SPEAK := 85
const SAID_MAX := 600 ## 채점에 쓰는 입력 글자 상한


static func _is_speak(via: Variant) -> bool:
	return via is String and via == "speak"


static func threshold(via: Variant) -> int:
	return PASS_SPEAK if _is_speak(via) else PASS_TYPE


static func good_threshold(via: Variant) -> int:
	return GOOD_SPEAK if _is_speak(via) else GOOD_TYPE


## 점수만으로 낸 판정 (경계 시험용). via 가 "speak" 가 아니면 입력(type) 기준.
static func verdict(score: int, via: Variant = "type") -> Dictionary:
	return {"passed": score >= threshold(via), "good": score >= good_threshold(via), "threshold": threshold(via)}


## 자가 평가("잘했어요"/"다시") 결과. 점수 계산 없음: 잘했어요 = 통과·좋음·100점, 다시 = 불통과·0점.
static func self_result(good: bool) -> Dictionary:
	return {"score": 100 if good else 0, "passed": good, "good": good, "via": "self", "threshold": 0,
		"marks": [], "extra": [], "detail": [], "said": "", "silent": false}


static func _line_str(line: Variant, key: String) -> String:
	if line is Dictionary:
		var v: Variant = (line as Dictionary).get(key, "")
		return v if (v is String) else ""
	if line is String and key == "text":
		return line
	return ""


## 제어문자(널·줄바꿈·탭)는 공백으로, 상한 길이로 자른다. 문자열이 아니면 "".
static func _clean_said(said: Variant) -> String:
	if not (said is String):
		return ""
	var s: String = (said as String).left(SAID_MAX)
	var out: String = ""
	for i in s.length():
		var c: int = s.unicode_at(i)
		out += " " if (c < 32 or c == 127) else s[i]
	return out


static func _result(score: int, via: String, marks: Array, extra: Array, detail: Array, said: String, silent: bool) -> Dictionary:
	var sc: int = clampi(score, 0, 100)
	var v: Dictionary = verdict(sc, via)
	var passed: bool = bool(v["passed"]) and not silent
	return {"score": sc, "passed": passed, "good": bool(v["good"]) and passed, "via": via,
		"threshold": int(v["threshold"]), "marks": marks, "extra": extra, "detail": detail,
		"said": said, "silent": silent}


static func grade(lang: Variant, said: Variant, line: Variant, via: Variant = "type") -> Dictionary:
	var lg: String = "ja" if MemoMask.is_ja(lang) else "en"
	var vv: String = "speak" if _is_speak(via) else "type"
	var text: String = _line_str(line, "text")
	var reading: String = _line_str(line, "reading")
	var us: Array = MemoMask.units(text, lg)["units"]
	var clean: String = _clean_said(said)
	var marks: Array = []
	var detail: Array = []
	for k in us.size():
		marks.append(false)
		detail.append({"w": str((us[k] as Dictionary)["w"]), "ok": false, "kind": "missing"})
	if clean.strip_edges() == "":
		return _result(0, vv, marks, [], detail, clean, true)
	if us.is_empty():
		return _result(0, vv, marks, [], detail, clean, false)
	var pack: Dictionary = {"text": text, "reading": reading}
	var res: Dictionary = SongStudy.dictation_score(lg, clean, pack)
	var score: int = _score_of(res)
	var extra: Array = []
	if lg == "ja":
		_ja_marks(clean, text, score, vv, us, marks, detail)
	else:
		var words: Variant = res.get("words", [])
		if words is Array:
			var ws: Array = words
			for k in mini(us.size(), ws.size()):
				var wd: Dictionary = ws[k]
				marks[k] = bool(wd.get("ok", false))
				var dd: Dictionary = detail[k]
				dd["ok"] = marks[k]
				dd["kind"] = str(wd.get("kind", "missing"))
				if wd.has("said"):
					dd["said"] = str(wd["said"])
		var ex: Variant = res.get("extra", [])
		if ex is Array:
			for e in ex:
				extra.append(str(e))
	return _result(score, vv, marks, extra, detail, clean, false)


static func _score_of(res: Variant) -> int:
	if res is Dictionary:
		var v: Variant = (res as Dictionary).get("score", 0)
		if v is int or v is float:
			var f: float = float(v)
			if is_finite(f):
				return clampi(roundi(f), 0, 100)
	return 0


## 일본어 단위 표시: 줄 글자만으로 비교한 맞은 글자(TextSim.similarity(...).hit)가 단위 안에서 전부 true 여야 맞음.
## 읽기(reading)를 쓴 비교가 더 높고 통과했으면 모두 맞음. hit 이 줄 글자와 어긋나면 전부 틀림으로 둔다.
static func _ja_marks(said: String, text: String, score: int, via: String, us: Array, marks: Array, detail: Array) -> void:
	var own: Dictionary = TextSim.similarity(said, text, "", "ja")
	var reading_won: bool = score > int(own.get("score", 0))
	var all_ok: bool = reading_won and score >= threshold(via)
	var hit: Array = own.get("hit", []) as Array
	var total: int = 0
	for u in us:
		total += str((u as Dictionary)["w"]).length()
	if not all_ok and (hit.size() != total or TextSim.tokens(text, "ja").size() != total):
		return
	var at: int = 0
	for k in us.size():
		var n: int = str((us[k] as Dictionary)["w"]).length()
		var good: bool = true
		if not all_ok:
			for j in range(at, at + n):
				if not bool(hit[j]):
					good = false
					break
		at += n
		marks[k] = good
		var dd: Dictionary = detail[k]
		dd["ok"] = good
		dd["kind"] = "ok" if good else "missing"
