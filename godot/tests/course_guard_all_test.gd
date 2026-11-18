extends Node
## Full sweep of the release course data (v2.0 KB-4, design docs/v200_design.md §3.3 step 3, §14 KB).
##   PC   : godot --headless --path <project>/godot res://tests/course_guard_all_test.tscn
##   Phone: godot --headless --path <project>/godot --resolution 412x915 res://tests/course_guard_all_test.tscn -- --phone
## Exit code 0 = all passed. Last line: "== course_guard_all_test: N passed, M failed ==".
## Every (week 1..16) x (day 1..7) x (kind new|listen|speak|check|month|recap) x (5 seeds) is built through the real app path
## (CourseFeed.builder_data() -> LessonBuilder.build). Every exercise is then checked AGAIN, in play order, with
## LexiconGuard.check_exercise_set (seen = the words whose intro card came earlier in the unit) and by a second, separately written
## token oracle (this file: its own tokenizer and its own word table made from CourseData). Output:
##   checked N, violations V, dropped R%        (and one line per kind)
## dropped R% = guard-dropped exercises / (kept + dropped); must be < 2 % overall and per kind.
## Exercise counts per unit must be inside the range of its kind (design §3.1 / §7); units outside are all listed. Only units a learner can
## reach (see _reachable: check on day 6 only, month on the month-end day 6, recap not on week 1 day 1, new on days with new words)
## fail the test; the others are printed as "[not reachable]" (the grid still builds them, which proves the builder never crashes).
## Units the builder refuses (ok=false) are counted by reason; only "new" on a day without new words/patterns is expected.

const KINDS := ["new", "listen", "speak", "check", "month", "recap"]
const SEEDS := [1, 2, 3, 4, 5]
const WEEKS := 16
const MAX_DROP_PCT := 2.0
## Counts of exercises per unit (inclusive). new: envelope for a day that has new words (formula below is reported separately).
const RANGE := {"new": [20, 70], "listen": [8, 8], "speak": [3, 12], "check": [12, 12], "month": [5, 8], "recap": [5, 6]}
const EN_KEYS := ["tts", "target", "prompt", "prompt_en", "en", "say", "tpl", "sentence"]
const EN_LIST_KEYS := ["answer_tiles", "extra", "accept", "expect_any"]

var passed: int = 0
var failed: int = 0
var _before: Array = []
var _tok_rx: RegEx = null
var _tok_o: Dictionary = {} ## oracle: token -> smallest o of any lexicon entry / form that spells it
var _ex_count: int = 0


func _ready() -> void:
	print("== course_guard_all_test start ==")
	_before = _user_listing()
	_tok_rx = RegEx.create_from_string("[a-z0-9]+(?:'[a-z0-9]+)*")
	if "--guard-off" in OS.get_cmdline_user_args(): # proof run: with the guard off the oracle (second line) must still find a bad sentence
		LexiconGuard.enabled = false
		print("  INFO  --guard-off: LexiconGuard.enabled = false (this run is expected to FAIL)")
	ok(LexiconGuard.enabled, "LexiconGuard.enabled is true (a guard switched off would pass everything)")
	for a in OS.get_cmdline_user_args(): # `-- --course-dir=<folder>`: test a copy of the data (shows that bad data is noticed)
		if String(a).begins_with("--course-dir="):
			CourseData.base_dir = String(a).substr(13)
			print("  INFO  course dir override: ", CourseData.base_dir)
	CourseData.reset()
	CourseFeed.reset()
	var st: Dictionary = CourseFeed.status()
	var data: Dictionary = CourseFeed.builder_data()
	ok(bool(st.get("ok", false)) and not data.is_empty(), "CourseFeed.builder_data() ready %s" % str(st))
	eq(CourseData.available_weeks(), WEEKS, "available_weeks() == 16")
	if data.is_empty():
		print("== course_guard_all_test: %d passed, %d failed ==" % [passed, failed])
		get_tree().quit(1)
		return
	_make_oracle()
	_selfcheck(data)
	_sweep(data)
	_determinism(data)
	_passive_coverage(data)
	ok(_before == _user_listing(), "user:// listing unchanged by this test")
	print("== course_guard_all_test: %d passed, %d failed ==" % [passed, failed])
	get_tree().quit(1 if failed > 0 else 0)


func ok(cond: bool, name: String) -> void:
	if cond:
		passed += 1
		print("  PASS  ", name)
	else:
		failed += 1
		print("  FAIL  ", name)


func eq(got: Variant, want: Variant, name: String) -> void:
	var good: bool = typeof(got) == typeof(want) and got == want
	ok(good, name if good else "%s  got=%s want=%s" % [name, str(got), str(want)])


func _user_listing() -> Array:
	var out: Array = []
	var d := DirAccess.open("user://")
	if d == null:
		return out
	for n in d.get_files():
		out.append("f:%s:%d" % [n, FileAccess.get_file_as_bytes("user://" + n).size()])
	for n in d.get_directories():
		out.append("d:" + n)
	out.sort()
	return out


# ------------------------------------------------------------------ second oracle (independent of LexiconGuard)

func _tokens(text: String) -> Array:
	var out: Array = []
	var t: String = text.to_lower().replace("’", "'")
	for m in _tok_rx.search_all(t):
		out.append(m.get_string())
	return out


func _note(token: String, o: int) -> void:
	if not _tok_o.has(token) or int(_tok_o[token]) > o:
		_tok_o[token] = o


func _make_oracle() -> void:
	_tok_o = {}
	for w in CourseData.lexicon().values():
		var o: int = int(w["o"])
		for t in _tokens(str(w.get("en", ""))):
			_note(t, o)
		for a in w.get("alt", []):
			for t in _tokens(str(a)):
				_note(t, o)
		for f in w.get("forms", []):
			var po: int = int(CourseData.pattern(str(f.get("pat", ""))).get("o", 0))
			for t in _tokens(str(f.get("f", ""))):
				_note(t, maxi(o, po))
	print("  INFO  oracle table: %d spellings" % _tok_o.size())


## English strings of an exercise (the fields that carry English text the learner sees or hears).
func _english_of(ex: Dictionary) -> Array:
	var out: Array = []
	for k in EN_KEYS:
		if ex.get(k, null) is String:
			out.append(ex[k])
	if ex.get("answer", null) is Array and str(ex.get("type", "")) == "build":
		out.append(" ".join(PackedStringArray(ex["answer"])))
	for k in EN_LIST_KEYS:
		var v: Variant = ex.get(k, null)
		if v is Array:
			for e in v:
				if e is String:
					out.append(e)
				elif e is Array:
					out.append(" ".join(PackedStringArray(e)))
	var typ: String = str(ex.get("type", ""))
	var mode: String = str(ex.get("mode", ""))
	if (typ == "recognize" and mode == "hear_en") or (typ == "recall" and mode == "ko_en_choice"):
		for o in ex.get("options", []):
			out.append(str(o))
	if ex.get("cue", null) is Dictionary:
		out.append(str(ex["cue"].get("slot", "")))
		out.append(str(ex["cue"].get("with", "")))
	if ex.get("example", null) is Dictionary:
		for k in ["en", "say", "tts"]:
			out.append(str(ex["example"].get(k, "")))
	for e in ex.get("examples", []):
		if e is Dictionary:
			for k in ["en", "say", "tts"]:
				out.append(str(e.get(k, "")))
	for ln in ex.get("lines", []):
		if ln is Dictionary:
			for k in ["en", "say", "tts"]:
				out.append(str(ln.get(k, "")))
			for a in ln.get("accept", []):
				out.append(str(a))
	return out


## Oracle verdict for one exercise at cur_o: {future: [tokens whose smallest o > cur], unknown: [tokens not in the table]}.
func _oracle(ex: Dictionary, cur_o: int) -> Dictionary:
	var fut: Array = []
	var unk: Array = []
	for s in _english_of(ex):
		for t in _tokens(s):
			if not _tok_o.has(t):
				if not t.is_valid_int():  # digits are read through `say` (checked by the linter NUM_SAY rule and by the guard)
					unk.append(t)
			elif int(_tok_o[t]) > cur_o:
				fut.append("%s(o=%d)" % [t, int(_tok_o[t])])
	return {"future": fut, "unknown": unk}


# ------------------------------------------------------------------ self checks (the checkers must be able to fail)

func _selfcheck(data: Dictionary) -> void:
	# a future word planted into a real unit's exercises must be seen by BOTH checkers
	var r: Dictionary = LessonBuilder.build({"kind": "new", "w": 5, "d": 2, "seen": []}, data, 1)
	ok(bool(r["ok"]) and r["exercises"].size() > 20, "selfcheck base unit w5 d2 builds (%d exercises)" % r["exercises"].size())
	var fut_word: Dictionary = {}
	for w in CourseData.lexicon().values():
		if int(w["o"]) >= 150 and str(w.get("role", "")) == "active" and str(w["en"]).find(" ") < 0:
			fut_word = w
			break
	ok(not fut_word.is_empty(), "selfcheck a week 15+ word is available (%s o=%d)" % [str(fut_word.get("en", "")), int(fut_word.get("o", 0))])
	var idx: Dictionary = data["_idx"]
	var cur: int = 52
	var found_guard: int = 0
	var found_oracle: int = 0
	var planted: int = 0
	for ex in r["exercises"]:
		if str(ex.get("type", "")) == "build":
			var bad_ex: Dictionary = ex.duplicate(true)
			bad_ex["tts"] = str(bad_ex.get("tts", "")) + " " + str(fut_word["en"])
			planted += 1
			if not LexiconGuard.check_exercise_set(bad_ex, cur, {}, idx)["ok"]:
				found_guard += 1
			if not (_oracle(bad_ex, cur)["future"] as Array).is_empty():
				found_oracle += 1
	ok(planted > 0 and found_guard == planted, "selfcheck FAIL-as-expected LexiconGuard rejects a planted future word in %d/%d build exercises" % [found_guard, planted])
	ok(planted > 0 and found_oracle == planted, "selfcheck FAIL-as-expected the oracle rejects a planted future word in %d/%d build exercises" % [found_oracle, planted])
	# a not-yet-seen item must be rejected by the replay check (R6), accepted once its card came
	var rec: Dictionary = {}
	for ex in r["exercises"]:
		if str(ex.get("type", "")) == "recognize":
			var wid: String = str(ex["item"])
			if int(idx["word_o"][wid]) >= cur:
				rec = ex
				break
	ok(not rec.is_empty(), "selfcheck a recognize exercise of a word of today exists")
	if not rec.is_empty():
		ok(not LexiconGuard.check_exercise_set(rec, cur, {}, idx)["ok"], "selfcheck FAIL-as-expected today's word without its intro card is rejected")
		ok(LexiconGuard.check_exercise_set(rec, cur, {str(rec["item"]): true}, idx)["ok"], "selfcheck PASS-as-expected the same exercise after its intro card is accepted")
	# ranges / dropped ratio
	ok(not _in_range("listen", 7), "selfcheck FAIL-as-expected 7 exercises are outside the listen range")
	ok(not _in_range("check", 11), "selfcheck FAIL-as-expected 11 exercises are outside the check range")
	ok(_in_range("check", 12), "selfcheck PASS-as-expected 12 exercises are inside the check range")
	ok(_pct(5, 95) >= MAX_DROP_PCT, "selfcheck FAIL-as-expected 5 dropped of 100 is %.2f %% (>= limit)" % _pct(5, 95))
	ok(_pct(1, 99) < MAX_DROP_PCT, "selfcheck PASS-as-expected 1 dropped of 100 is %.2f %% (< limit)" % _pct(1, 99))


## Can the learner's day plan ever start this unit? (CourseModel.day_kind: D1~D4 new, D5 speak, D6 check, D7 free.)
func _reachable(kind: String, w: int, d: int, week: Dictionary) -> bool:
	match kind:
		"new":
			return CourseModel.day_kind(w, d) == "new"
		"check":
			return CourseModel.day_kind(w, d) == "check"
		"month":
			return CourseModel.day_kind(w, d) == "check" and bool(week.get("check", {}).get("month", false))
		"recap":
			return not (w == 1 and d == 1)
	return true


func _in_range(kind: String, n: int) -> bool:
	var r: Array = RANGE[kind]
	return n >= int(r[0]) and n <= int(r[1])


func _pct(dropped: int, kept: int) -> float:
	var total: int = dropped + kept
	return 0.0 if total == 0 else 100.0 * float(dropped) / float(total)


# ------------------------------------------------------------------ the sweep

## Number of exercises the plan of a `new` day should give: intro cards + 4 per active word + build 5 + listen 4 + speak 5 (+ dialogue on day 4).
func _plan_new(week: Dictionary, d: int, idx: Dictionary) -> int:
	var day: Dictionary = {}
	for e in week.get("days", []):
		if int(e.get("d", 0)) == d:
			day = e
	var nw: int = 0
	for wid in day.get("words", []):
		if str(idx["words"].get(wid, {}).get("role", "active")) == "active":
			nw += 1
	var np: int = 0
	for pid in day.get("patterns", []):
		if idx["pats"].has(pid):
			np += 1
	if nw == 0 and np == 0:
		return 0
	var n: int = nw + np + 4 * nw + 14
	if d == 4 and str(week.get("dialogue", "")) != "":
		n += 1
	return n


func _sweep(data: Dictionary) -> void:
	var idx: Dictionary = data["_idx"]
	var stat: Dictionary = {}
	for k in KINDS:
		stat[k] = {"units": 0, "ok": 0, "refused": {}, "ex": 0, "dropped": 0, "skipped": 0, "short_opts": 0, "drop_why": {}, "drop_item": {}, "violations": 0, "out_reach": 0,
			"oracle_future": 0, "unknown_tokens": {}, "out_of_range": [], "below_plan": 0, "above_plan": 0, "warn": {}, "min": 1 << 30, "max": 0}
	var viol_lines: Array = []
	var checked: int = 0
	var units: int = 0
	var t0: int = Time.get_ticks_msec()
	for w in range(1, WEEKS + 1):
		var week: Dictionary = idx["weeks"].get(w, {})
		for d in range(1, 8):
			for kind in KINDS:
				for sd in SEEDS:
					units += 1
					var s: Dictionary = stat[kind]
					s["units"] += 1
					var r: Dictionary = LessonBuilder.build({"kind": kind, "w": w, "d": d, "seen": []}, data, sd)
					s["dropped"] += int(r["dropped"])
					for di in r["dropped_info"]:
						var b0: Array = di.get("bad", [])
						var key2: String = "%s:%s" % [str(b0[0].get("why", "?")) if not b0.is_empty() else "?", str(b0[0].get("where", "?")) if not b0.is_empty() else "?"]
						s["drop_why"][key2] = int(s["drop_why"].get(key2, 0)) + 1
						var parts: PackedStringArray = str(di.get("id", "")).split(":")
						var item: String = parts[4] if parts.size() > 4 else str(di.get("id", ""))
						s["drop_item"][item] = int(s["drop_item"].get(item, 0)) + 1
					s["skipped"] += int(r["skipped"])
					for wn in r["warnings"]:
						var key: String = str(wn).split(":")[0]
						s["warn"][key] = int(s["warn"].get(key, 0)) + 1
					if not bool(r["ok"]):
						var why: String = ",".join(PackedStringArray(r["errors"]))
						if kind == "new" and why == "empty_day" and _plan_new(week, d, idx) == 0:
							why += " (no new words/patterns that day: expected)"
						else:
							why += " (UNEXPECTED)"
						s["refused"][why] = int(s["refused"].get(why, 0)) + 1
						if not (r["exercises"] as Array).is_empty():
							ok(false, "refused unit has exercises: %s w%d d%d seed %d" % [kind, w, d, sd])
						continue
					s["ok"] += 1
					var exs: Array = r["exercises"]
					s["ex"] += exs.size()
					s["min"] = mini(int(s["min"]), exs.size())
					s["max"] = maxi(int(s["max"]), exs.size())
					var cur: int = w * 10 + d
					var seen: Dictionary = {}
					var ids: Dictionary = {}
					for ex in exs:
						checked += 1
						var id: String = str(ex.get("id", ""))
						if ids.has(id) or id == "":
							s["violations"] += 1
							viol_lines.append("DUP/EMPTY id %s in %s w%d d%d seed %d" % [id, kind, w, d, sd])
						ids[id] = true
						var g: Dictionary = LexiconGuard.check_exercise_set(ex, cur, seen, idx)
						if not bool(g["ok"]):
							s["violations"] += 1
							if viol_lines.size() < 30:
								viol_lines.append("GUARD %s w%d d%d seed %d %s %s" % [kind, w, d, sd, id, str(g["bad"]).substr(0, 160)])
						var oc: Dictionary = _oracle(ex, cur)
						if not (oc["future"] as Array).is_empty():
							s["violations"] += 1
							s["oracle_future"] += 1
							if viol_lines.size() < 30:
								viol_lines.append("ORACLE %s w%d d%d seed %d %s future=%s" % [kind, w, d, sd, id, str(oc["future"]).substr(0, 160)])
						for u in oc["unknown"]:
							s["unknown_tokens"][u] = int(s["unknown_tokens"].get(u, 0)) + 1
						var typ: String = str(ex.get("type", ""))
						if typ == "teach_word":
							seen[str(ex.get("item", ""))] = true
						if (typ == "recognize" or typ == "recall" and str(ex.get("mode", "")) == "ko_en_choice" or typ == "listen" and str(ex.get("mode", "")) == "choose_ko") \
								and (ex.get("options", []) as Array).size() < 4:
							s["short_opts"] += 1
					if not _in_range(kind, exs.size()):
						var tag: String = "" if _reachable(kind, w, d, week) else " [not reachable]"
						(s["out_of_range"] as Array).append("%s w%d d%d seed %d n=%d%s" % [kind, w, d, sd, exs.size(), tag])
						if tag == "":
							s["out_reach"] += 1
					if kind == "new":
						var plan: int = _plan_new(week, d, idx)
						if exs.size() < plan:
							s["below_plan"] += 1
						elif exs.size() > plan:
							s["above_plan"] += 1
		print("  INFO  week %d swept (%d units so far, %d exercises checked, %d ms)" % [w, units, checked, Time.get_ticks_msec() - t0])
	# ---- report
	var total_drop: int = 0
	var total_kept: int = 0
	var total_viol: int = 0
	var total_skipped: int = 0
	for k in KINDS:
		var s: Dictionary = stat[k]
		var pct: float = _pct(int(s["dropped"]), int(s["ex"]))
		total_drop += int(s["dropped"])
		total_kept += int(s["ex"])
		total_viol += int(s["violations"])
		total_skipped += int(s["skipped"])
		var uk: Array = []
		for t in s["unknown_tokens"].keys():
			uk.append("%s:%d" % [t, int(s["unknown_tokens"][t])])
		uk.sort()
		print("  KIND  %s: units %d, built %d, refused %d, exercises %d (per unit %d..%d), dropped %d (%.3f%%), skipped(no options) %d, options<4 %d, violations %d, oracle_future %d" % [
			k, int(s["units"]), int(s["ok"]), int(s["units"]) - int(s["ok"]), int(s["ex"]), int(s["min"]) if int(s["ok"]) > 0 else 0, int(s["max"]),
			int(s["dropped"]), pct, int(s["skipped"]), int(s["short_opts"]), int(s["violations"]), int(s["oracle_future"])])
		if not (s["drop_why"] as Dictionary).is_empty():
			print("        dropped by (why:where, first reason of each dropped exercise): ", str(s["drop_why"]))
			print("        dropped items (item: times, over all weeks x 5 seeds): ", str(s["drop_item"]))
		for why in s["refused"].keys():
			print("        refused %d x %s" % [int(s["refused"][why]), why])
		if not (s["warn"] as Dictionary).is_empty():
			print("        builder warnings: ", str(s["warn"]))
		if k == "new":
			print("        new units vs plan (intro+4/word+14): below plan %d, above plan %d, of %d built" % [int(s["below_plan"]), int(s["above_plan"]), int(s["ok"])])
		print("        oracle-unknown tokens (info, glue words of number readings etc.): %d distinct %s" % [uk.size(), str(uk.slice(0, 25))])
		var oor: Array = s["out_of_range"]
		if not oor.is_empty():
			print("        OUT OF RANGE %s: %d units (%d reachable)" % [str(RANGE[k]), oor.size(), int(s["out_reach"])])
			for line in oor.slice(0, 40):
				print("          ", line)
	for line in viol_lines:
		print("  VIOLATION  ", line)
	print("checked %d, violations %d, dropped %.3f%% (dropped %d of %d, units %d, skipped-no-options %d)" % [
		checked, total_viol, _pct(total_drop, total_kept), total_drop, total_drop + total_kept, units, total_skipped])
	eq(units, WEEKS * 7 * KINDS.size() * SEEDS.size(), "units swept == 16 x 7 x 6 x 5")
	ok(checked > 0, "exercises checked: %d" % checked)
	eq(total_viol, 0, "violations (guard replay + oracle) == 0")
	ok(_pct(total_drop, total_kept) < MAX_DROP_PCT, "dropped %.3f%% < %.1f%% overall" % [_pct(total_drop, total_kept), MAX_DROP_PCT])
	for k in KINDS:
		var s2: Dictionary = stat[k]
		ok(_pct(int(s2["dropped"]), int(s2["ex"])) < MAX_DROP_PCT, "dropped %.3f%% < %.1f%% for %s" % [_pct(int(s2["dropped"]), int(s2["ex"])), MAX_DROP_PCT, k])
		eq(int(s2["out_reach"]), 0, "no reachable %s unit outside its exercise-count range %s (all outside: %d)" % [k, str(RANGE[k]), (s2["out_of_range"] as Array).size()])
		# every refused unit must be an expected one
		var unexpected: int = 0
		for why in s2["refused"].keys():
			if str(why).ends_with("(UNEXPECTED)"):
				unexpected += int(s2["refused"][why])
		eq(unexpected, 0, "no %s unit refused for an unexpected reason" % k)
	# new: the days that carry new words are built, the others refused only for empty_day
	var new_expected_days: int = 0
	for w in range(1, WEEKS + 1):
		for d in range(1, 8):
			if _plan_new(idx["weeks"].get(w, {}), d, idx) > 0:
				new_expected_days += 1
	eq(int(stat["new"]["ok"]), new_expected_days * SEEDS.size(), "new units built == days with new words/patterns (%d) x 5 seeds" % new_expected_days)


## Same (spec, data, seed) -> identical exercises (a spot check on the real data; the full proof is in lesson_builder_test).
func _determinism(data: Dictionary) -> void:
	var same: int = 0
	var n: int = 0
	for kind in KINDS:
		for w in [1, 8, 16]:
			n += 1
			var a: Dictionary = LessonBuilder.build({"kind": kind, "w": w, "d": 4 if kind == "new" else 6, "seen": []}, data, 3)
			var b: Dictionary = LessonBuilder.build({"kind": kind, "w": w, "d": 4 if kind == "new" else 6, "seen": []}, data, 3)
			if JSON.stringify(a["exercises"]) == JSON.stringify(b["exercises"]) and (a["exercises"] as Array).size() > 0:
				same += 1
	eq(same, n, "same (spec, seed) gives the same exercises (%d spot checks on the real data)" % n)
	# a different seed changes the order or the options somewhere
	var diff: int = 0
	for w in [5, 9, 13]:
		var a2: Dictionary = LessonBuilder.build({"kind": "listen", "w": w, "d": 6, "seen": []}, data, 1)
		var b2: Dictionary = LessonBuilder.build({"kind": "listen", "w": w, "d": 6, "seen": []}, data, 2)
		if JSON.stringify(a2["exercises"]) != JSON.stringify(b2["exercises"]):
			diff += 1
	ok(diff >= 1, "different seeds give a different listen set in %d of 3 spot checks" % diff)


# ------------------------------------------------------------------ passive words and named sentences

const COVER_SEEDS := 20
const WATCH := ["s0162", "s0163", "s0674"]


## Does every passive word (role passive, listen-only sentences) show up in some exercise? 20 seeds x 16 weeks x 7 days x 6 kinds.
## Two measures: (a) the word ids declared by the sentence / dialogue line an exercise plays (`sent`, `example.sent`, dialogue lines),
## (b) the spelling of the word (headword, alt, form) among the tokens of the exercise texts. Also: which exercises carry the
## sentences in WATCH (s0162 / s0163 phone numbers, s0674 ATM) and from which cur o on.
func _passive_coverage(data: Dictionary) -> void:
	var idx: Dictionary = data["_idx"]
	var passive: Dictionary = {}
	for w in CourseData.lexicon().values():
		if str(w.get("role", "")) == "passive":
			passive[w["id"]] = w
	var by_spelling: Dictionary = {} # token -> [word ids]
	for w in CourseData.lexicon().values():
		var texts: Array = [str(w.get("en", ""))]
		for a in w.get("alt", []):
			texts.append(str(a))
		for f in w.get("forms", []):
			texts.append(str(f.get("f", "")))
		for t0 in texts:
			for t in _tokens(t0):
				if not by_spelling.has(t):
					by_spelling[t] = []
				if not (by_spelling[t] as Array).has(w["id"]):
					by_spelling[t].append(w["id"])
	var hit_decl: Dictionary = {}
	var hit_text: Dictionary = {}
	var hit_kind: Dictionary = {} # kind -> {id: true} (declared ids)
	var watch: Dictionary = {} # sentence id -> {"count": n, "min_cur": o, "kinds": {kind: n}}
	for k in KINDS:
		hit_kind[k] = {}
	var units: int = 0
	for sd in range(1, COVER_SEEDS + 1):
		for w in range(1, WEEKS + 1):
			for d in range(1, 8):
				for kind in KINDS:
					var r: Dictionary = LessonBuilder.build({"kind": kind, "w": w, "d": d, "seen": []}, data, 100 + sd)
					units += 1
					if not bool(r["ok"]):
						continue
					for ex in r["exercises"]:
						var sids: Array = []
						for key in ["sent"]:
							if ex.get(key, null) is String:
								sids.append(ex[key])
						if ex.get("example", null) is Dictionary:
							sids.append(str(ex["example"].get("sent", "")))
						for e in ex.get("examples", []):
							if e is Dictionary:
								sids.append(str(e.get("sent", "")))
						var wids: Array = []
						for sid in sids:
							var sent: Variant = idx["sents"].get(sid)
							if sent != null:
								wids.append_array(sent.get("words", []))
						if ex.get("dialogue", null) is String:
							var dl: Variant = idx["dialogues"].get(ex["dialogue"]) if idx.has("dialogues") else null
							if dl == null:
								dl = CourseData.dialogue(str(ex["dialogue"]))
							if dl is Dictionary:
								for ln in dl.get("lines", []):
									wids.append_array(ln.get("words", []))
						for wid in wids:
							if passive.has(wid):
								hit_decl[wid] = true
								hit_kind[kind][wid] = true
						for txt in _english_of(ex):
							for t in _tokens(txt):
								for wid in by_spelling.get(t, []):
									if passive.has(wid):
										hit_text[wid] = true
						for sid in sids:
							if sid in WATCH:
								var rec: Dictionary = watch.get(sid, {"count": 0, "min_cur": 1 << 30, "kinds": {}})
								rec["count"] += 1
								rec["min_cur"] = mini(int(rec["min_cur"]), w * 10 + d)
								rec["kinds"][kind] = int(rec["kinds"].get(kind, 0)) + 1
								watch[sid] = rec
						if str(ex.get("type", "")) == "dialogue_script":
							pass
	var miss_decl: Array = []
	var miss_text: Array = []
	for id in passive.keys():
		if not hit_decl.has(id):
			miss_decl.append("%s(%s,o=%d)" % [id, str(passive[id]["en"]), int(passive[id]["o"])])
		if not hit_text.has(id):
			miss_text.append("%s(%s,o=%d)" % [id, str(passive[id]["en"]), int(passive[id]["o"])])
	miss_decl.sort()
	miss_text.sort()
	print("  COVER passive words %d, units built %d (%d seeds): shown by declared id %d, by spelling in text %d" % [
		passive.size(), units, COVER_SEEDS, hit_decl.size(), hit_text.size()])
	for k in KINDS:
		print("  COVER   passive words (declared ids) in %s exercises: %d" % [k, (hit_kind[k] as Dictionary).size()])
	print("  COVER not shown by declared id: %d %s" % [miss_decl.size(), str(miss_decl.slice(0, 30))])
	print("  COVER not shown by spelling:    %d %s" % [miss_text.size(), str(miss_text.slice(0, 30))])
	for sid in WATCH:
		var sent: Variant = idx["sents"].get(sid)
		print("  COVER %s o=%s scope=%s: %s" % [sid, str(sent.get("o", "?")) if sent != null else "absent", str(sent.get("scope", "?")) if sent != null else "-", str(watch.get(sid, "never shown"))])
		ok(watch.has(sid), "%s is played in some exercise (not dropped by the guard)" % sid)
		if watch.has(sid) and sent != null:
			ok(int(watch[sid]["min_cur"]) >= int(sent["o"]), "%s never appears before its own o (first at %d, o=%d)" % [sid, int(watch[sid]["min_cur"]), int(sent["o"])])
	ok(passive.size() > 0, "passive words exist")
	eq(miss_decl.size(), 0, "every passive word is played by some exercise (declared ids, %d seeds)" % COVER_SEEDS)
	eq(miss_text.size(), 0, "every passive word is heard / read in some exercise (spelling, %d seeds)" % COVER_SEEDS)
