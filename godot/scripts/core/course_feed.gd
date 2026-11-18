class_name CourseFeed
extends RefCounted
## v2.0 bridge CourseData -> LessonBuilder (design docs/v200_design.md §10.1, §10.4, §14 E3 "course_feed").
##
## LessonBuilder.build(spec, data, seed) wants one `data` dictionary and works fast only when that dictionary already holds the
## index made by LessonBuilder.prepare() (without it every build rebuilds the index: about 125 ms for 5,000 words). CourseFeed makes
## that dictionary once from the verified CourseData and keeps it until CourseData is reset or reloaded.
##
##   var data := CourseFeed.builder_data()           # {} when the course data is missing / broken / empty (see status())
##   var r := LessonBuilder.build({"kind":"new","w":5,"d":2,"seen":[]}, data, 1)    # or CourseFeed.build_unit(spec, seed)
##
## builder_data() keys: weeks, words, patterns, sentences, dialogues, speak_prompts (all Arrays, same records as CourseData holds, not
## copies: read-only) plus "_idx" (the prepared index, made by LessonBuilder.prepare). plain_data() is the same without "_idx".
## speak_prompts keep the file shape [{"month","w","prompts":[{"id","kind","en","ko","say","expect_any","o"}]}] with whole numbers as ints.
## Never raises: a broken course gives {} and status() = {"ok": false, "err_code", "text_ko"} (err_code: course_missing /
## course_corrupt from CourseData, or "course_empty" when it loaded but has no weeks or no words).
## Dialogues: CourseData has no list accessor, so they are looked up by the week's `dialogue` id and then by the ids d0001..d9999.
## Patterns: gathered from the weeks (also their days), the sentences (`pat`) and the word forms (`pat`).

const ERR_EMPTY := "course_empty"
const TEXT_EMPTY := "코스 데이터가 비어 있어요. 앱을 다시 설치해 주세요."
const SENTENCE_WEEKS := 99 ## sentences are collected for weeks 1..99 (valid data only has 1..72)
const MAX_DIALOGUE_NO := 9999

## Times LessonBuilder.prepare ran (tests: it must stay 1 while the course data stays the same).
static var prepare_count: int = 0

static var _src: Variant = null ## the CourseData.load_all() result the cache was made from (compared by identity)
static var _prepared: Dictionary = {}
static var _plain: Dictionary = {}
static var _status: Dictionary = {"ok": false, "err_code": "", "text_ko": ""}


## Forgets the cache (the next call builds again).
static func reset() -> void:
	_src = null
	_prepared = {}
	_plain = {}
	_status = {"ok": false, "err_code": "", "text_ko": ""}


## {"ok": bool, "err_code": String, "text_ko": String} of the last builder_data() / plain_data() call.
static func status() -> Dictionary:
	_refresh()
	return _status.duplicate()


## Data for LessonBuilder.build with the index inside (made once). {} when the course data is not usable.
static func builder_data() -> Dictionary:
	_refresh()
	return _prepared


## The six arrays without the index. {} when the course data is not usable.
static func plain_data() -> Dictionary:
	_refresh()
	return _plain


## Convenience: LessonBuilder.build(spec, builder_data(), seed). Without usable data: {"ok": false, "errors": [<err_code>], ...}.
static func build_unit(spec: Variant, seed_value: int) -> Dictionary:
	var data: Dictionary = builder_data()
	if data.is_empty():
		return {"ok": false, "exercises": [], "dropped": 0, "errors": [str(_status["err_code"])], "warnings": [],
			"dropped_info": [], "skipped": 0, "cur_o": 0}
	return LessonBuilder.build(spec, data, seed_value)


static func _refresh() -> void:
	var r: Dictionary = CourseData.load_all()
	if _src != null and is_same(_src, r):
		return
	_src = r
	_prepared = {}
	_plain = {}
	if not bool(r.get("ok", false)):
		var code: String = str(r.get("err_code", ""))
		_status = {"ok": false, "err_code": code if code != "" else CourseData.ERR_MISSING,
			"text_ko": str(r.get("text_ko", "")) if str(r.get("text_ko", "")) != "" else CourseData.text_for(CourseData.ERR_MISSING)}
		return
	var plain: Dictionary = _collect()
	if (plain["weeks"] as Array).is_empty() or (plain["words"] as Array).is_empty():
		_status = {"ok": false, "err_code": ERR_EMPTY, "text_ko": TEXT_EMPTY}
		return
	_plain = plain
	_prepared = LessonBuilder.prepare(plain)
	prepare_count += 1
	_status = {"ok": true, "err_code": "", "text_ko": ""}


static func _collect() -> Dictionary:
	var weeks: Array = []
	var pattern_ids: Dictionary = {}
	var dialogue_ids: Dictionary = {}
	for w in range(1, CourseData.MAX_WEEK + 1):
		var wk: Dictionary = CourseData.week(w)
		if wk.is_empty():
			continue
		weeks.append(wk)
		_note_ids(pattern_ids, wk.get("patterns"))
		if wk.get("days", null) is Array:
			for dd in wk["days"]:
				if dd is Dictionary:
					_note_ids(pattern_ids, (dd as Dictionary).get("patterns"))
		var did: Variant = wk.get("dialogue", "")
		if did is String and did != "":
			dialogue_ids[did] = true
	var lex: Dictionary = CourseData.lexicon()
	var wids: Array = lex.keys()
	wids.sort()
	var words: Array = []
	for id in wids:
		var wd: Dictionary = lex[id]
		words.append(wd)
		if wd.get("forms", null) is Array:
			for f in wd["forms"]:
				if f is Dictionary and (f as Dictionary).get("pat", null) is String:
					pattern_ids[(f as Dictionary)["pat"]] = true
	var sentences: Array = []
	for w in range(1, SENTENCE_WEEKS + 1):
		for s in CourseData.sentences_for(w):
			sentences.append(s)
			if (s as Dictionary).get("pat", null) is String and (s as Dictionary)["pat"] != "":
				pattern_ids[(s as Dictionary)["pat"]] = true
	for n in range(1, MAX_DIALOGUE_NO + 1):
		var key: String = "d%04d" % n
		if not CourseData.dialogue(key).is_empty():
			dialogue_ids[key] = true
	var dkeys: Array = dialogue_ids.keys()
	dkeys.sort()
	var dialogues: Array = []
	for k in dkeys:
		var dl: Dictionary = CourseData.dialogue(k)
		if not dl.is_empty():
			dialogues.append(dl)
	var pkeys: Array = pattern_ids.keys()
	pkeys.sort()
	var patterns: Array = []
	for k in pkeys:
		var pt: Dictionary = CourseData.pattern(k)
		if not pt.is_empty():
			patterns.append(pt)
	return {"weeks": weeks, "words": words, "patterns": patterns, "sentences": sentences, "dialogues": dialogues,
		"speak_prompts": _ints_deep(CourseData.speak_prompts().duplicate(true))}


static func _note_ids(into: Dictionary, v: Variant) -> void:
	if v is Array:
		for x in v:
			if x is String and x != "":
				into[x] = true


## Whole floats become ints (JSON numbers are floats): the prompts' inner `o` is not converted by CourseData.
static func _ints_deep(v: Variant) -> Variant:
	if v is Dictionary:
		var d: Dictionary = v
		for k in d.keys():
			d[k] = _ints_deep(d[k])
		return d
	if v is Array:
		var a: Array = v
		for i in a.size():
			a[i] = _ints_deep(a[i])
		return a
	if v is float and is_equal_approx(v, roundf(v)) and absf(v) < 1.0e9:
		return int(v)
	return v
