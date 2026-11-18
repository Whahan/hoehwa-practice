class_name CourseCards
extends RefCounted
## v2.0 review cards of a course day (design docs/v200_design.md §3.1, §11.1, §14 E3-6).
##
## One finished "new" day puts into the review list (Store.add_review, the same list FSRS schedules):
##   - every ACTIVE word taught that day (passive words are never cards): target = the English word, ko = its meaning
##   - one frame sentence per pattern taught that day: the first example sentence of the pattern
##   - day 4 only: up to 2 key lines of the week's mini dialogue: the learner's own lines in order (the first two lines when the
##     dialogue has no `user` role)
## note: "코스 5주 2일 · 단어" / "... · 문형" / "... · 대화". lang = "en", reading = "".
## Data comes from CourseData (tests point CourseData.base_dir at a fixture). Anything missing or invalid gives [] / 0.
## Cards with the same `lang|target` as another card of the list (or of the review list) are skipped, like Store.add_review does.
## add_unit() does nothing (0) unless CourseStore.mode() == "course", so the old path and Japanese never get course cards.

const LANG := "en"
const MAX_DIALOGUE_LINES := 2
const DIALOGUE_DAY := 4 ## the mini dialogue is taught on day 4 (design §2.2)
const KIND_WORD := "단어"
const KIND_PATTERN := "문형"
const KIND_DIALOGUE := "대화"


## "코스 5주 2일 · 단어". Invalid w / d give "".
static func note_for(w: Variant, d: Variant, kind: String) -> String:
	var o: int = CourseModel.order_of(w, d)
	if o < 0:
		return ""
	return "코스 %d주 %d일 · %s" % [o / 10, o % 10, kind]


## Cards of day (w, d): Array of {"lang","target","reading","ko","note"} (Store.add_review input). [] for an unknown day.
static func unit_cards(w: Variant, d: Variant) -> Array:
	var out: Array = []
	var o: int = CourseModel.order_of(w, d)
	if o < 0:
		return out
	var wi: int = o / 10
	var di: int = o % 10
	var week: Dictionary = CourseData.week(wi)
	if week.is_empty():
		return out
	var day: Dictionary = _day_of(week, di)
	if day.is_empty():
		return out
	var seen: Dictionary = {}
	for wid in _arr(day.get("words")):
		var wd: Dictionary = CourseData.word(wid)
		if wd.is_empty() or str(wd.get("role", "active")) != "active":
			continue
		_add(out, seen, str(wd.get("en", "")), str(wd.get("ko", "")), note_for(wi, di, KIND_WORD))
	for pid in _arr(day.get("patterns")):
		var pt: Dictionary = CourseData.pattern(pid)
		for sid in _arr(pt.get("examples")):
			var s: Dictionary = CourseData.sentence(sid)
			if str(s.get("en", "")).strip_edges() != "":
				_add(out, seen, str(s["en"]), str(s.get("ko", "")), note_for(wi, di, KIND_PATTERN))
				break
	if di == DIALOGUE_DAY:
		var dl: Dictionary = CourseData.dialogue(week.get("dialogue", ""))
		var lines: Array = _dialogue_lines(dl, wi * 10 + di)
		for ln in lines:
			_add(out, seen, str(ln.get("en", "")), str(ln.get("ko", "")), note_for(wi, di, KIND_DIALOGUE))
	return out


## Puts the cards of day (w, d) into the review list and saves progress when something was added.
## Returns how many cards were really added (duplicates are skipped by Store.add_review); asking again returns 0.
static func add_unit(w: Variant, d: Variant) -> int:
	if CourseStore.mode() != CourseStore.MODE_COURSE:
		return 0
	var cards: Array = unit_cards(w, d)
	if cards.is_empty():
		return 0
	var n: int = Store.add_review(cards)
	if n > 0:
		Store.save_progress()
	return n


## Up to MAX_DIALOGUE_LINES key lines of a dialogue (only lines taught by `cur_o`): the learner's lines (`user` role) first.
static func _dialogue_lines(dl: Dictionary, cur_o: int) -> Array:
	var mine: Array = []
	var rest: Array = []
	var user: String = str(dl.get("user", ""))
	for ln in _arr(dl.get("lines")):
		if not (ln is Dictionary):
			continue
		var l: Dictionary = ln
		if str(l.get("en", "")).strip_edges() == "":
			continue
		var lo: Variant = l.get("o", 0)
		if (lo is int or lo is float) and int(lo) > cur_o:
			continue
		if user != "" and str(l.get("s", "")) == user:
			mine.append(l)
		else:
			rest.append(l)
	var lines: Array = mine if not mine.is_empty() else rest
	return lines.slice(0, MAX_DIALOGUE_LINES)


static func _day_of(week: Dictionary, d: int) -> Dictionary:
	for e in _arr(week.get("days")):
		if e is Dictionary and int((e as Dictionary).get("d", 0)) == d:
			return e
	return {}


static func _arr(v: Variant) -> Array:
	return v if v is Array else []


static func _add(out: Array, seen: Dictionary, target: String, ko: String, note: String) -> void:
	var t: String = target.strip_edges()
	if t == "" or seen.has(t):
		return
	seen[t] = true
	out.append({"lang": LANG, "target": t, "reading": "", "ko": ko.strip_edges(), "note": note})
