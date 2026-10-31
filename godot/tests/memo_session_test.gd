extends Node
## 가사 외우기 M3: MemoSession (큐 · 단계 상태기계 · FSRS 평가 · 저장 실패 시 상태 유지 · 요약). 서버·마이크·화면을 쓰지 않는다.
##   godot --headless --path <project> res://tests/memo_session_test.tscn
## Exit code 0 = all passed. Last line: "== memo_session_test result: N passed, 0 failed =="
## 가사는 tests/fixtures/song/lyrics_en.txt · lyrics_ja.txt (직접 쓴 문장, CC0) 와 이 파일의 직접 쓴 문장뿐이다.
## 시계는 주입한 NOW, FSRS.fuzz_override = 0.5 로 고정. 곡 저장소는 user://test_songs_memo_session 에만 쓴다.

const NOW := 1790000000
const DAY := 86400
const ROOT := "user://test_songs_memo_session"
const EN_PATH := "res://tests/fixtures/song/lyrics_en.txt"
const JA_PATH := "res://tests/fixtures/song/lyrics_ja.txt"
const SRC_PATH := "res://scripts/core/memo_session.gd"

var passed: int = 0
var failed: int = 0
var _en: Array = []
var _ja: Array = []


func ok(cond: bool, name: String) -> void:
	if cond:
		passed += 1
		print("  PASS  ", name)
	else:
		failed += 1
		print("  FAIL  ", name)


func _fixture_lines(path: String) -> Array:
	var f := FileAccess.open(path, FileAccess.READ)
	var out: Array = []
	if f == null:
		return out
	var kept: PackedStringArray = []
	for ln in f.get_as_text().split("\n"):
		if not ln.strip_edges().begins_with("#"):
			kept.append(ln)
	f.close()
	for e in LrcParser.split_plain("\n".join(kept)):
		out.append(e["text"])
	return out


func _song(lang: String, texts: Array) -> Dictionary:
	var lines: Array = []
	for i in texts.size():
		lines.append({"i": i, "p": 0, "t0": 0.0, "t1": 0.0, "text": texts[i], "reading": "", "pron": "", "ko": "해석 %d" % i})
	return {"v": 1, "kind": "lyrics", "id": "s_0123456789ab", "lang": lang, "title": "T", "lines": lines}


func _key(song: Dictionary, i: int) -> String:
	return MemoModel.line_key(song["lines"][i]["text"], song["lang"])


func _card(due: int, state: int = 2, last: int = -1) -> Dictionary:
	return {"due": due, "stability": 2.3, "difficulty": 5.1, "state": state, "step": 0,
		"last_review": (NOW - 3 * DAY) if last < 0 else last, "reps": 2, "lapses": 0}


func _memo_with(entries: Dictionary) -> Dictionary:
	var m := MemoModel.new_memo()
	for k in entries.keys():
		m["lines"][k] = entries[k]
	return m


func _ent(card: Dictionary = {}, stage: int = 0) -> Dictionary:
	var e := {"stage": stage, "seen": NOW - DAY, "tries": 1, "passes": 1}
	if not card.is_empty():
		e["card"] = card
	return e


func _ans(s: MemoSession, wrong: bool = false) -> Dictionary:
	## 지금 줄에 정답(또는 틀린 답)을 입력으로 낸다
	var c: Dictionary = s.current()
	var said: String = "zzq xxv wwy" if wrong else str(c["text"])
	return s.submit(MemoGrade.grade(c["lang"], said, {"text": c["text"], "reading": c["reading"]}, "type"))


func _run_line(s: MemoSession) -> Array:
	## 지금 줄을 끝까지 정답으로 진행한 이벤트 이름 목록
	var evs: Array = []
	var guard := 0
	while guard < 40:
		guard += 1
		var c: Dictionary = s.current()
		if not c["ok"] or c["done"]:
			break
		var ev: Dictionary
		if c["read_only_stage"]:
			ev = s.skip_read()
		else:
			ev = _ans(s)
		evs.append(ev["event"])
		if ev["event"] == "line_done" or ev["event"] == "save_failed":
			break
	return evs


func _count(a: Array, v: String) -> int:
	var n := 0
	for x in a:
		if x == v:
			n += 1
	return n


func _begin(song: Dictionary, memo: Dictionary, opts: Dictionary = {}, now: int = NOW) -> MemoSession:
	var s := MemoSession.new()
	s.begin(song, memo, now, opts)
	return s


func _ready() -> void:
	print("== memo_session_test start ==")
	FSRS.fuzz_override = 0.5
	_en = _fixture_lines(EN_PATH)
	_ja = _fixture_lines(JA_PATH)
	ok(_en.size() == 6 and _ja.size() == 5, "fixtures: 6 English lines, 5 Japanese lines")
	_rm_rf(ROOT)
	_test_begin_current()
	_test_new_line_good()
	_test_fail_reveal()
	_test_ratings()
	_test_review_line()
	_test_practice()
	_test_queue()
	_test_leave()
	_test_self_and_silent()
	_test_bad_input()
	_test_tiny_and_ja()
	_test_save_hooks()
	_test_real_store()
	_test_review_untouched()
	_test_clock_and_summary()
	_test_misc()
	_test_purity()
	_rm_rf(ROOT)
	FSRS.fuzz_override = -1.0
	ok(Progress.test_guard == true, "TEST_GUARD is on in this run")
	ok(true, "ran to the end of every section")
	print("== memo_session_test result: %d passed, %d failed ==" % [passed, failed])
	get_tree().quit(1 if failed > 0 else 0)


# ------------------------------------------------------------------ basics

func _test_begin_current() -> void:
	print("[begin / current]")
	var song := _song("en", _en)
	var s := _begin(song, MemoModel.new_memo())
	var c: Dictionary = s.current()
	ok(c["ok"] and c["total"] == 5 and c["pos"] == 1, "6 fresh lines -> queue of 5 (new cap), position 1")
	ok(c["kind"] == "new" and c["stage"] == 0 and c["read_only_stage"] and not c["final"], "a new line starts at stage 0 (read), not final")
	ok(c["stage_count"] == 5 and c["text"] == _en[0] and c["line_i"] == 0, "9-unit line: 5 stages, text and index match the song")
	ok((c["hidden"] as Array).size() == 9 and (c["hidden"] as Array).count(true) == 0 and c["hidden_count"] == 0, "stage 0: nothing hidden")
	ok(c["prev_text"] == "" and c["ko"] == "해석 0" and c["revealed"] == false and c["answered"] == false, "first line: no previous line; ko passed through; not revealed/answered")
	var s2 := _begin(song, MemoModel.new_memo(), {"prev_cue": true})
	s2.skip_read()
	_run_line(s2)
	s2.next_line()
	ok(s2.current()["prev_text"] == _en[0] and s2.current()["pos"] == 2, "prev_cue on (default): line 2 shows line 1 as the cue, position 2")
	var s3 := _begin(song, MemoModel.new_memo(), {"prev_cue": false})
	_run_line(s3)
	s3.next_line()
	ok(s3.current()["prev_text"] == "", "prev_cue off: no cue text")
	var hid: Array = []
	var s4 := _begin(song, MemoModel.new_memo())
	for k in 4:
		s4.skip_read() if k == 0 else _ans(s4)
		hid.append((s4.current()["hidden"] as Array).duplicate())
	var subset := true
	for k in range(1, hid.size()):
		for j in 9:
			if hid[k - 1][j] and not hid[k][j]:
				subset = false
	ok(subset and hid[0].count(true) == 3 and hid[1].count(true) == 5 and hid[2].count(true) == 7, "hidden counts 3,5,7 and a hidden word stays hidden in later stages")
	var s5 := _begin(song, MemoModel.new_memo())
	for k in 4:
		s5.skip_read() if k == 0 else _ans(s5)
	var f: Dictionary = s5.current()
	ok(f["final"] and f["hidden_count"] == 9 and (f["hidden"] as Array).count(true) == 9 and f["stage"] == 4, "stage 4 is final: all 9 units hidden")
	var s6 := _begin(song, MemoModel.new_memo(), {"fast": true})
	ok(s6.current()["stage_count"] == 3, "fast mode: 9 units -> 3 stages (0, 5, 9)")
	var ha := _begin(song, MemoModel.new_memo())
	var hb := _begin(song, MemoModel.new_memo())
	ha.skip_read()
	hb.skip_read()
	ok(ha.current()["hidden"] == hb.current()["hidden"], "same line, same stage -> same hidden units (deterministic)")


func _test_new_line_good() -> void:
	print("[new line, all correct (M3-2)]")
	var song := _song("en", _en)
	var memo0 := MemoModel.new_memo()
	var memo_before: Dictionary = memo0.duplicate(true)
	var s := _begin(song, memo0)
	var evs := _run_line(s)
	ok(_count(evs, "stage_pass") == 4 and evs[evs.size() - 1] == "line_done" and evs.size() == 5, "skip_read + 3 correct stages -> 4 stage_pass, then the final answer -> line_done")
	var key := _key(song, 0)
	var ent: Dictionary = s.memo["lines"][key]
	var card: Dictionary = ent["card"]
	var gap: int = int(card["due"]) - NOW
	print("  INFO  first interval after Good x2 (fuzz 0.5): %d s = %.2f days, stability %.3f, difficulty %.3f" % [gap, float(gap) / DAY, float(card["stability"]), float(card["difficulty"])])
	ok(card["state"] == 2 and card["reps"] == 2 and card["last_review"] == NOW, "card: state 2 (review), reps 2, last_review == now")
	ok(gap >= 86400 and gap <= 345600, "first interval within 1..4 days (measured %.2f days)" % (float(gap) / DAY))
	ok(ent["tries"] == 4 and ent["passes"] == 4 and ent["seen"] == NOW and ent["stage"] == 0, "entry: tries 4, passes 4, seen == now, stage reset")
	ok(memo0 == memo_before, "the memo passed to begin() is not modified")
	var c: Dictionary = s.current()
	ok(c["done"] and c["ok"] and c["rating"] == 3, "after line_done the line is still described (done) with rating Good")
	ok(s.next_line() and s.current()["pos"] == 2 and s.current()["kind"] == "new", "next_line moves to the next fresh line")


func _test_fail_reveal() -> void:
	print("[wrong answers, reveal (M3-3)]")
	var song := _song("en", _en)
	var s := _begin(song, MemoModel.new_memo())
	s.skip_read()
	_ans(s)
	_ans(s)
	ok(s.current()["stage"] == 3, "reached stage 3")
	var e1 := _ans(s, true)
	ok(e1["event"] == "stage_fail" and e1["fails_stage"] == 1 and s.current()["stage"] == 3, "first wrong answer: stage_fail, still stage 3, fails_stage 1")
	var e2 := _ans(s, true)
	ok(e2["event"] == "revealed" and s.current()["stage"] == 2 and s.current()["fails_stage"] == 0 and s.current()["revealed"], "second wrong in a row: revealed, stage drops to 2, fails reset, revealed flag")
	_ans(s)
	ok(s.current()["revealed"] == false and s.current()["stage"] == 3, "a correct answer after the reveal clears revealed and goes up")
	var s2 := _begin(song, MemoModel.new_memo())
	s2.skip_read()
	_ans(s2, true)
	var r1 := _ans(s2, true)
	ok(r1["event"] == "revealed" and s2.current()["stage"] == 1 and r1["dropped"] == false, "stage 1: two wrongs reveal but the stage cannot go below 1")
	var s3 := _begin(song, MemoModel.new_memo())
	s3.skip_read()
	_ans(s3)
	_ans(s3, true)
	_ans(s3, true)
	var evs := _run_line(s3)
	ok(evs[evs.size() - 1] == "line_done" and s3.current()["rating"] == 3, "a failure in a middle stage does not affect the rating (first final answer perfect -> Good)")
	ok(s3.memo["lines"][_key(song, 0)]["card"]["state"] == 2, "...and the card is a review card (state 2)")
	var s4 := _begin(song, MemoModel.new_memo())
	s4.skip_read()
	var rv := s4.reveal()
	ok(rv["event"] == "revealed" and s4.current()["stage"] == 1, "reveal() (answer button) at stage 1 reveals and stays at 1")
	var s5 := _begin(song, MemoModel.new_memo())
	ok(s5.reveal()["event"] == "ignored" and s5.current()["stage"] == 0, "reveal() in the read stage is ignored")
	ok(s5.submit(MemoGrade.grade("en", "x", {"text": _en[0]}, "type"))["event"] == "ignored", "submit() in the read stage is ignored")
	s5.skip_read()
	ok(s5.skip_read()["event"] == "ignored" and s5.current()["stage"] == 1, "skip_read() outside stage 0 is ignored")


func _final_stage_session(song: Dictionary, memo: Dictionary = {}) -> MemoSession:
	var s := _begin(song, memo if not memo.is_empty() else MemoModel.new_memo())
	s.skip_read()
	_ans(s)
	_ans(s)
	_ans(s)
	return s


func _test_ratings() -> void:
	print("[final-stage ratings (M3-4)]")
	var song := _song("en", _en)
	var now := NOW
	var s := _final_stage_session(song)
	ok(s.current()["final"], "at the final stage")
	ok(_ans(s, true)["event"] == "stage_fail", "one wrong answer at the final stage")
	var ev := _ans(s)
	var card: Dictionary = s.memo["lines"][_key(song, 0)]["card"]
	ok(ev["event"] == "line_done" and ev["rating"] == 2, "wrong once, then pass -> Hard")
	ok(card["state"] == 1 and card["step"] == 1 and int(card["due"]) - now == 600, "Hard on a new line: state 1, step 1, due in 600 s")
	var s2 := _final_stage_session(song)
	var c2: Dictionary = s2.current()
	var weak := MemoGrade.grade("en", "I count my steps to the old chair", {"text": "x"}, "type")
	weak["passed"] = true
	weak["good"] = false
	var ev2 := s2.submit(weak)
	ok(ev2["event"] == "line_done" and ev2["rating"] == 2, "first final attempt passes but good:false -> Hard")
	ok(s2.memo["lines"][_key(song, 0)]["card"]["state"] == 1 and c2["final"], "...card state 1")
	var s3 := _final_stage_session(song)
	_ans(s3, true)
	var rv := _ans(s3, true)
	ok(rv["event"] == "revealed" and rv["from_final"] and s3.current()["stage"] == 3, "two wrongs at the final stage reveal and drop to stage 3")
	var evs := _run_line(s3)
	var card3: Dictionary = s3.memo["lines"][_key(song, 0)]["card"]
	ok(evs[evs.size() - 1] == "line_done" and s3.current()["rating"] == 1, "line finished after a final-stage reveal -> Again")
	ok(card3["state"] == 1 and card3["step"] == 0 and int(card3["due"]) - now == 60, "Again on a new line: state 1, step 0, due in 60 s")
	var s4 := _final_stage_session(song)
	s4.reveal()
	var evs4 := _run_line(s4)
	ok(evs4[evs4.size() - 1] == "line_done" and s4.current()["rating"] == 1, "[show answer] at the final stage counts as Again too")
	ok(s4.memo["lines"][_key(song, 0)]["card"]["lapses"] == 0, "a new line's Again does not count a lapse")


func _test_review_line() -> void:
	print("[review lines (M3-5)]")
	var song := _song("en", _en)
	var k2 := _key(song, 2)
	var memo := _memo_with({k2: _ent(_card(NOW - 100))})
	var s := _begin(song, memo)
	var c: Dictionary = s.current()
	ok(c["kind"] == "review" and c["line_i"] == 2 and c["final"] and c["stage"] == c["stage_count"] - 1 and not c["read_only_stage"], "a due card starts at the final (blank) stage")
	ok(c["total"] == 6, "queue: 1 review line first, then the 5 new lines (total 6)")
	var before: Dictionary = memo["lines"][k2]["card"].duplicate()
	var ev := _ans(s)
	var after: Dictionary = s.memo["lines"][k2]["card"]
	ok(ev["event"] == "line_done" and ev["rating"] == 3, "review line, first final answer perfect -> line_done with Good")
	ok(float(after["stability"]) > float(before["stability"]) and int(after["due"]) > int(before["due"]) and after["state"] == 2 and after["lapses"] == 0, "Good: stability up, due later, still review")
	print("  INFO  review Good: stability %.3f -> %.3f, due in %.2f days" % [before["stability"], after["stability"], float(int(after["due"]) - NOW) / DAY])
	ok(after["reps"] == 3 and after["last_review"] == NOW, "reps 3 (one review applied), last_review == now")
	var s2 := _begin(song, memo)
	_ans(s2, true)
	_ans(s2, true)
	var evs := _run_line(s2)
	var a2: Dictionary = s2.memo["lines"][k2]["card"]
	ok(evs[evs.size() - 1] == "line_done" and s2.current()["rating"] == 1, "review line forgotten (reveal at the final stage) -> Again")
	ok(a2["lapses"] == 1 and a2["state"] == 3 and a2["reps"] == 3, "Again on a review card: lapses +1, state 3 (relearning), one review applied")
	var s3 := _begin(song, memo)
	_ans(s3, true)
	_ans(s3)
	ok(s3.current()["rating"] == 2 and s3.memo["lines"][k2]["card"]["reps"] == 3, "review line: wrong once then pass -> Hard, one review applied")


func _test_practice() -> void:
	print("[practice only (M3-6)]")
	var song := _song("en", _en)
	var k2 := _key(song, 2)
	var memo := _memo_with({k2: _ent(_card(NOW + DAY))})
	var s := _begin(song, memo, {"practice_only": true, "only_line": 2})
	var snap: Dictionary = s.memo.duplicate(true)
	ok(s.current()["total"] == 1 and s.current()["practice_only"] and s.current()["final"], "only_line 2 (memorized, not due): queue of 1, starts at the final stage")
	var ev := _ans(s)
	ok(ev["event"] == "line_done" and ev["counted"] == false, "practice: line_done with counted:false")
	ok(s.memo == snap, "practice: the memo is exactly what it was at begin()")
	var fin := s.finish()
	ok(fin["ok"] and s.memo == snap and s.summary()["lines_done"] == 0, "practice: finish() changes nothing, lines_done 0")
	var s2 := _begin(song, MemoModel.new_memo(), {"practice_only": true, "only_line": 0})
	var snap2: Dictionary = s2.memo.duplicate(true)
	var evs := _run_line(s2)
	ok(evs[evs.size() - 1] == "line_done" and s2.memo == snap2 and s2.memo["lines"].is_empty(), "practice of a fresh line: no entry is created")
	var s3 := _begin(song, MemoModel.new_memo(), {"practice_only": true, "only_line": 1})
	s3.skip_read()
	_ans(s3)
	s3.leave_line()
	ok(s3.memo["lines"].is_empty(), "practice: leave_line saves no stage")
	var normal := _begin(song, MemoModel.new_memo())
	var evn := _run_line(normal)
	ok(normal.summary()["lines_done"] == 1 and evn[evn.size() - 1] == "line_done", "a normal line end is counted:true (lines_done 1)")
	var ro_memo := MemoModel.new_memo()
	ro_memo["v"] = 2
	var calls: Array = []
	var s4 := _begin(song, ro_memo, {"save": func(id, m): calls.append(1); return true})
	ok(s4.practice_only and s4.read_only_memo, "a newer-version memo (v 2) forces practice mode")
	_run_line(s4)
	s4.finish()
	ok(calls.is_empty() and s4.memo["lines"].is_empty(), "read-only memo: nothing recorded, the save function is never called")


func _test_queue() -> void:
	print("[queue (M3-7)]")
	var a := ["ka", "mo", "ri", "tu", "ne", "so", "ba"]
	var b := ["la", "pe", "di", "zo", "vu"]
	var texts: Array = []
	for x in a:
		for y in b:
			texts.append("%s%s lantern keeps the window warm" % [x, y])
	ok(texts.size() == 35, "35 distinct generated lines")
	var song := _song("en", texts)
	song["lines"].insert(3, {"i": 3, "p": 0, "t0": 0.0, "t1": 0.0, "text": "[Chorus]", "reading": "", "pron": "", "ko": ""})
	song["lines"].insert(8, {"i": 8, "p": 0, "t0": 0.0, "t1": 0.0, "text": "♪♪ ...", "reading": "", "pron": "", "ko": ""})
	song["lines"].append({"i": 37, "p": 0, "t0": 0.0, "t1": 0.0, "text": texts[0].to_upper() + "!", "reading": "", "pron": "", "ko": ""})
	var entries := {}
	var due_of := {}
	var rev_idx: Array = []
	for i in song["lines"].size():
		var t: String = song["lines"][i]["text"]
		if MemoModel.is_memo_line(t, "en") and i != 37 and rev_idx.size() < 25 and i % 3 != 1:
			rev_idx.append(i)
	rev_idx = rev_idx.slice(0, 25)
	for n in rev_idx.size():
		var due: int = NOW - (n + 1) * 1000 if n % 2 == 0 else NOW - (30 - n) * 1000 ## 섞인 due
		var k := _key(song, rev_idx[n])
		entries[k] = _ent(_card(due))
		due_of[k] = due
	var s := _begin(song, _memo_with(entries))
	var q: Array = s._queue
	ok(q.size() == 25, "25 due review lines + 10 fresh -> queue of 25 (20 review + 5 new)")
	var kinds_ok := true
	var due_sorted := true
	var prev_due := -1
	for n in 25:
		if (n < 20) != (q[n]["kind"] == "review"):
			kinds_ok = false
		if n < 20:
			var d: int = due_of[q[n]["key"]]
			if d < prev_due:
				due_sorted = false
			prev_due = d
	ok(kinds_ok, "order: 20 review lines first, then 5 new")
	ok(due_sorted, "review lines: oldest due first")
	var new_idx: Array = []
	for n in range(20, 25):
		new_idx.append(q[n]["i"])
	var sorted_new := new_idx.duplicate()
	sorted_new.sort()
	ok(new_idx == sorted_new, "new lines keep song order")
	var keys := {}
	var dup := false
	var bad_line := false
	for e in q:
		if keys.has(e["key"]):
			dup = true
		keys[e["key"]] = true
		if e["i"] == 3 or e["i"] == 8 or e["i"] == 37:
			bad_line = true
	ok(not dup and not bad_line, "no duplicate key, no [Chorus] / symbol-only / repeated line")
	var so := _begin(song, _memo_with(entries), {"only_line": 5})
	ok(so.current()["total"] == 1 and so.current()["line_i"] == 5, "only_line -> a queue of 1")
	var sx := _begin(song, _memo_with(entries), {"only_line": 3})
	ok(sx.current()["ok"] == false, "only_line on a [Chorus] line -> empty queue, current() ok:false")
	var sk := _begin(song, MemoModel.new_memo(), {"skip_new": 2, "new_cap": 3})
	var first_new: Array = []
	for e in sk._queue:
		first_new.append(e["i"])
	var s0 := _begin(song, MemoModel.new_memo())
	ok(first_new.size() == 3 and first_new[0] == s0._queue[2]["i"], "skip_new 2, new_cap 3 -> starts at the third fresh line, 3 lines")
	var s_caps := _begin(song, _memo_with(entries), {"review_cap": 3, "new_cap": 1})
	ok(s_caps._queue.size() == 4, "review_cap 3 + new_cap 1 -> 4 lines")


func _test_leave() -> void:
	print("[leaving a line (M3-8)]")
	var song := _song("en", _en)
	var s := _begin(song, MemoModel.new_memo())
	s.skip_read()
	_ans(s)
	ok(s.current()["stage"] == 2, "at stage 2")
	var r := s.leave_line()
	var key := _key(song, 0)
	ok(r["ok"] and s.memo["lines"][key]["stage"] == 2 and not s.memo["lines"][key].has("card"), "leave_line: stage 2 saved, no card")
	ok(s.current()["left"] and _ans(s)["event"] == "ignored", "after leave_line the line is closed (submit ignored)")
	var s2 := _begin(song, s.memo)
	var c: Dictionary = s2.current()
	ok(c["line_i"] == 0 and c["stage"] == 2 and not c["read_only_stage"], "begin() again resumes the new line at stage 2")
	var evs := _run_line(s2)
	ok(evs[evs.size() - 1] == "line_done" and _count(evs, "stage_pass") == 2, "...and finishes from there (2 more stage_pass, then line_done)")
	var s3 := _begin(song, MemoModel.new_memo())
	var snap: Dictionary = s3.memo.duplicate(true)
	s3.leave_line()
	ok(s3.memo == snap, "leave at stage 0 of a fresh line: memo unchanged")
	var k3 := _key(song, 3)
	var memo := _memo_with({k3: _ent(_card(NOW - 10))})
	var s4 := _begin(song, memo)
	_ans(s4, true)
	var before: Dictionary = s4.memo.duplicate(true)
	s4.leave_line()
	ok(s4.memo == before and s4.memo["lines"][k3]["card"] == memo["lines"][k3]["card"], "leave on a review line: memo and card unchanged")
	var s5 := _begin(song, memo)
	s5.leave_line()
	ok(s5.next_line() and s5.current()["kind"] == "new", "after leave_line, next_line moves on")
	var s6 := _begin(song, MemoModel.new_memo())
	ok(s6.next_line() == false and s6.current()["line_i"] == 0, "next_line while the line is still in progress does nothing")


func _test_self_and_silent() -> void:
	print("[self rating, silent, self_pass (M3-9)]")
	var song := _song("en", _en)
	var s := _begin(song, MemoModel.new_memo())
	s.skip_read()
	var e := s.submit(MemoGrade.self_result(true))
	ok(e["event"] == "stage_pass" and s.current()["stage"] == 2, "self 'good' passes the stage")
	var f1 := s.submit(MemoGrade.self_result(false))
	var f2 := s.submit(MemoGrade.self_result(false))
	ok(f1["event"] == "stage_fail" and f2["event"] == "revealed" and s.current()["stage"] == 1, "self 'again' twice -> reveal and drop")
	var s2 := _final_stage_session(song)
	var ev := s2.submit(MemoGrade.self_result(true))
	ok(ev["event"] == "line_done" and ev["rating"] == 3, "self 'good' at the final stage -> line_done with Good")
	var s3 := _begin(song, MemoModel.new_memo())
	s3.skip_read()
	var silent := MemoGrade.grade("en", "   ", {"text": _en[0]}, "type")
	ok(silent["silent"] == true, "(MemoGrade reports silent for blank input)")
	var ign := s3.submit(silent)
	ok(ign["event"] == "ignored" and ign["reason"] == "silent" and s3.current()["fails_stage"] == 0 and s3.current()["stage"] == 1, "silent result: ignored, nothing counted")
	_ans(s3)
	_ans(s3)
	_ans(s3)
	s3.submit(silent)
	var done := _ans(s3)
	var ent: Dictionary = s3.memo["lines"][_key(song, 0)]
	ok(done["event"] == "line_done" and ent["tries"] == 4 and ent["passes"] == 4 and s3.current()["rating"] == 3, "silent results in the middle and at the final stage: tries unchanged (4), still Good")
	var s4 := _final_stage_session(song)
	var c4: Dictionary = s4.current()
	var sp := MemoGrade.grade("en", "completely different words here", {"text": c4["text"]}, "speak")
	ok(sp["passed"] == false and sp["via"] == "speak", "(a speak grade of a wrong sentence fails)")
	ok(s4.submit(sp)["event"] == "stage_fail", "speak misgrade: stage_fail")
	var sp_ev := s4.self_pass()
	ok(sp_ev["event"] == "line_done" and sp_ev["self_pass"] == true and sp_ev["rating"] == 3, "self_pass after a failed speak attempt: counted as a good first try -> Good")
	var ent4: Dictionary = s4.memo["lines"][_key(song, 0)]
	ok(ent4["tries"] == 4 and ent4["passes"] == 4 and ent4["card"]["state"] == 2, "self_pass replaces the misgraded attempt (tries 4, passes 4, review card)")
	ok(s4.self_pass()["event"] == "ignored", "self_pass again on a finished line is ignored")
	var s5 := _final_stage_session(song)
	var tf := MemoGrade.grade("en", "completely different words here", {"text": s5.current()["text"]}, "type")
	s5.submit(tf)
	ok(s5.self_pass()["event"] == "ignored" and s5.current()["stage"] == 4 and s5.current()["fails_stage"] == 1, "self_pass after a wrong typed answer is ignored (only for speak misgrades)")
	var s6 := _final_stage_session(song)
	s6.submit(sp)
	s6.submit(sp)
	ok(s6.current()["revealed"] and s6.current()["stage"] == 3, "two speak failures: revealed")
	var late := s6.self_pass()
	ok(late["event"] == "line_done" and s6.current()["rating"] == 2, "self_pass after a reveal undoes only the last attempt: the earlier wrong one remains -> Hard, not Again")
	var s7 := _begin(song, MemoModel.new_memo())
	ok(s7.self_pass()["event"] == "ignored", "self_pass with no attempt: ignored")
	var s8 := _final_stage_session(song)
	s8.submit(sp)
	s8.reveal()
	ok(s8.self_pass()["event"] == "ignored", "self_pass after another action (reveal): ignored")


func _test_bad_input() -> void:
	print("[bad input (M3-10)]")
	var song := _song("en", _en)
	var s := _final_stage_session(song)
	var snap: Dictionary = s.current().duplicate(true)
	var bads: Array = [{}, {"score": 90}, {"passed": "true"}, {"passed": 1}, null, 5, [], "x", {"passed": null}]
	var all_ign := true
	for b in bads:
		var ev := s.submit(b)
		if ev["event"] != "ignored":
			all_ign = false
	ok(all_ign, "submit({}), keyless dict, passed as string/int/null, null, int, array, string -> all ignored")
	ok(s.current() == snap, "...and the state did not change")
	var e1 := MemoSession.new()
	ok(e1.current()["ok"] == false and e1.submit({"passed": true})["event"] == "ignored" and e1.next_line() == false and e1.summary()["queue_total"] == 0, "a session that never began: current ok:false, submit ignored, summary safe")
	var e2 := _begin(_song("en", []), MemoModel.new_memo())
	ok(e2.current()["ok"] == false and e2.next_line() == false and e2.finish()["ok"] == true, "a song with no lines: empty queue, current() ok:false")
	var e3 := _begin(song, memo_all_future())
	ok(e3.current()["ok"] == true and e3.current()["kind"] == "new", "memo whose cards are all due later: only new lines in the queue")
	var done := _final_stage_session(song)
	_ans(done)
	var card1: Dictionary = done.memo["lines"][_key(song, 0)]["card"].duplicate()
	var memo1: Dictionary = done.memo.duplicate(true)
	for k in 5:
		_ans(done)
		done.submit(MemoGrade.self_result(true))
		done.reveal()
		done.skip_read()
	ok(done.memo == memo1 and done.memo["lines"][_key(song, 0)]["card"] == card1 and card1["reps"] == 2, "submit / reveal / skip_read after the line ended: ignored, the evaluation is applied once (reps stays 2)")
	var k2 := _key(song, 2)
	var future := _card(NOW - 100, 2, NOW + 5 * DAY)
	var sf := _begin(song, _memo_with({k2: _ent(future)}))
	var evf := _ans(sf)
	var cf: Dictionary = sf.memo["lines"][k2]["card"]
	ok(evf["event"] == "line_done" and (cf["due"] is int) and cf["due"] > 0 and cf["due"] < 4102444800, "clock before last_review: no error, due is a finite integer (%d)" % cf["due"])
	ok(cf["last_review"] >= NOW + 5 * DAY and cf["due"] >= cf["last_review"], "...and the review time is not moved back before the last review")
	var weird := MemoSession.new()
	weird.begin(null, null, -5, null)
	weird.begin("x", 5, 1 << 62, {"fast": "yes", "review_cap": "a", "new_cap": null, "save": 3, "clock": 4})
	ok(weird.current()["ok"] == false and weird.summary()["queue_total"] == 0, "begin() with garbage arguments: no error, empty queue")
	var hs := _begin(song, {"v": "x", "lines": {"zz": 5, _key(song, 0): {"stage": "x", "card": {"due": "no"}}}})
	ok(hs.current()["ok"] and hs.current()["line_i"] == 0 and hs.current()["kind"] == "new", "a messy memo is normalized: the broken card makes the line a new line")


func memo_all_future() -> Dictionary:
	var song := _song("en", _en)
	var e := {}
	for i in 3:
		e[_key(song, i)] = _ent(_card(NOW + DAY))
	return _memo_with(e)


func _test_tiny_and_ja() -> void:
	print("[tiny lines, Japanese (M3-11)]")
	var tiny := _song("en", ["Hello", "Hello again", "One two three"])
	var s := _begin(tiny, MemoModel.new_memo())
	ok(s.current()["stage_count"] == 2, "1 unit: stages [0, 1]")
	var evs := _run_line(s)
	ok(evs == ["stage_pass", "line_done"], "1-unit line: skip_read, then one answer finishes it")
	s.next_line()
	ok(s.current()["stage_count"] == 3, "2 units: stages [0, 1, 2]")
	evs = _run_line(s)
	ok(evs == ["stage_pass", "stage_pass", "line_done"], "2-unit line finishes after 3 actions")
	s.next_line()
	ok(s.current()["stage_count"] == 4, "3 units: stages [0, 1, 2, 3]")
	var guard := 0
	var all_ok := true
	var sj := _begin(_song("ja", _ja), MemoModel.new_memo(), {"new_cap": 5})
	ok(sj.current()["total"] == 5 and sj.current()["lang"] == "ja", "Japanese fixture: 5 lines in the queue")
	for n in 5:
		var e2 := _run_line(sj)
		if e2.is_empty() or e2[e2.size() - 1] != "line_done":
			all_ok = false
		sj.next_line()
	ok(all_ok, "every Japanese line runs to line_done")
	ok(sj.summary()["lines_done"] == 5 and sj.summary()["good"] == 5, "5 Japanese lines done, all Good")
	var jl := _begin(_song("ja", _ja), MemoModel.new_memo(), {"fast": true})
	var cj: Dictionary = jl.current()
	ok(cj["stage_count"] == 3 or cj["stage_count"] == 2 or cj["stage_count"] == 4 or cj["stage_count"] == 5, "Japanese line has a valid stage plan")
	var ja_song := _song("ja", _ja)
	ja_song["lines"][1]["reading"] = "あおいいすまであるすうをかぞえる"
	var sr := _begin(ja_song, _memo_with({_key(ja_song, 1): _ent(_card(NOW - 5))}), {"only_line": 1})
	var cr: Dictionary = sr.current()
	ok(cr["kind"] == "review" and cr["final"] and cr["reading"] == "あおいいすまであるすうをかぞえる", "Japanese review line: starts blank, reading is passed through")
	var ev := _ans(sr)
	ok(ev["event"] == "line_done" and ev["rating"] == 3, "Japanese review line, exact text -> Good")


# ------------------------------------------------------------------ saving

func _test_save_hooks() -> void:
	print("[saving: when, and what a failure keeps]")
	var song := _song("en", _en)
	var calls: Array = []
	var saver := func(id, m):
		calls.append({"id": id, "memo": (m as Dictionary).duplicate(true)})
		return true
	var s := _begin(song, MemoModel.new_memo(), {"save": saver})
	s.skip_read()
	_ans(s)
	_ans(s, true)
	_ans(s)
	ok(calls.is_empty() and s.saves == 0, "stage passes and wrong answers do not save")
	var evs := _run_line(s)
	ok(calls.size() == 1 and evs[evs.size() - 1] == "line_done" and calls[0]["id"] == "s_0123456789ab", "saved exactly once at the line end, with the song id")
	ok(calls[0]["memo"]["lines"][_key(song, 0)].has("card") and s.saves == 1, "the saved memo has the new card")
	s.next_line()
	s.skip_read()
	_ans(s)
	s.leave_line()
	ok(calls.size() == 2 and calls[1]["memo"]["lines"][_key(song, 1)]["stage"] == 2, "leave_line on a new line saves its stage")
	s.next_line()
	s.skip_read()
	_run_line(s)
	var n_before := calls.size()
	var fin := s.finish()
	ok(fin["ok"] and calls.size() == n_before + 1 and s.finished, "finish() saves once and the session is finished")
	ok(calls[calls.size() - 1]["memo"]["stats"]["sessions"] == 1 and calls[calls.size() - 1]["memo"]["stats"]["last"] == NOW, "stats: sessions 1, last == now")
	s.finish()
	ok(calls.size() == n_before + 1 and s.memo["stats"]["sessions"] == 1, "finish() twice counts the session once")
	## ---- failure keeps the state
	var okflag := {"v": false}
	var fcalls: Array = []
	var flaky := func(id, m):
		fcalls.append(1)
		if okflag["v"]:
			return {"ok": true, "err_code": ""}
		return {"ok": false, "err_code": "disk_write"}
	var f := _begin(song, MemoModel.new_memo(), {"save": flaky})
	var before: Dictionary = f.memo.duplicate(true)
	var fe: Array = _run_line(f)
	ok(fe[fe.size() - 1] == "save_failed", "save fails at the line end -> save_failed event")
	ok(f.memo == before and f.last_error == "disk_write", "memo unchanged, error code kept (disk_write)")
	var c: Dictionary = f.current()
	ok(c["done"] == false and c["pending_save"] == true and c["final"], "the line is not done: pending_save, still at the final stage")
	ok(f.next_line() == false and f.submit(MemoGrade.self_result(true))["reason"] == "save_pending", "next_line is blocked and submit is ignored while the save is pending")
	ok(f.summary()["lines_done"] == 0 and f.summary()["memorized"] == 0, "summary does not count the unsaved line")
	var r1 := f.retry_save()
	ok(r1["event"] == "save_failed" and f.memo == before, "retry while still failing: save_failed again, state kept")
	okflag["v"] = true
	var r2 := f.retry_save()
	var ent: Dictionary = f.memo["lines"][_key(song, 0)]
	ok(r2["event"] == "line_done" and r2["rating"] == 3 and ent["card"]["reps"] == 2 and ent["tries"] == 4, "retry after the disk recovers: line_done once, same Good rating, reps 2 (not applied twice)")
	ok(f.last_error == "" and f.next_line(), "error cleared, next line opens")
	## ---- failure at finish
	okflag["v"] = false
	_run_line(f)
	okflag["v"] = true
	f.retry_save()
	okflag["v"] = false
	var m_before: Dictionary = f.memo.duplicate(true)
	var ff := f.finish()
	ok(ff["ok"] == false and ff["err"] == "disk_write" and f.finished == false and f.memo == m_before, "finish() save failure: error returned, not finished, memo (stats) unchanged")
	okflag["v"] = true
	ok(f.finish()["ok"] and f.finished and f.memo["stats"]["sessions"] == 1, "finish() retried after recovery works, sessions 1")
	## ---- failure at leave
	okflag["v"] = false
	var lv := _begin(song, MemoModel.new_memo(), {"save": flaky})
	lv.skip_read()
	_ans(lv)
	var lm: Dictionary = lv.memo.duplicate(true)
	var lr := lv.leave_line()
	ok(lr["ok"] == false and lv.memo == lm and lv.current()["left"] == false, "leave_line save failure: error returned, memo unchanged, the line stays open")
	okflag["v"] = true
	ok(lv.leave_line()["ok"] and lv.memo["lines"][_key(song, 0)]["stage"] == 2, "leave_line again after recovery saves the stage")
	## ---- plain bool false and a missing function
	var bsave := _begin(song, MemoModel.new_memo(), {"save": func(id, m): return false})
	var be := _run_line(bsave)
	ok(be[be.size() - 1] == "save_failed" and bsave.last_error == "save_failed", "a save function returning plain false -> save_failed (generic code)")
	var nosave := _begin(song, MemoModel.new_memo())
	var ne := _run_line(nosave)
	ok(ne[ne.size() - 1] == "line_done" and nosave.saves == 0, "no save function: memo updated in memory, nothing saved")
	var junk := _begin(song, MemoModel.new_memo(), {"save": func(id, m): return "yes"})
	var je := _run_line(junk)
	ok(je[je.size() - 1] == "save_failed", "a save function returning a non-bool, non-dict value counts as a failure")


func _test_real_store() -> void:
	print("[with the real SongStore.save_memo on user://test_*]")
	var old_root: String = SongStore.root
	SongStore.root = ROOT
	SongStore.write_hook = Callable()
	ok(SongStore.root.begins_with("user://test_") and not SongStore.blocked(), "store root is a user://test_* folder")
	var base := _song("en", _en)
	var inst := SongStore.install_lyrics(base)
	ok(inst["ok"], "install a lyrics-only test song")
	var id: String = inst["id"]
	var song: Dictionary = SongStore.load_song(id)
	var saver := func(i, m):
		var okv: bool = SongStore.save_memo(i, m)
		return {"ok": okv, "err_code": SongStore.last_error}
	var memo: Dictionary = SongStore.load_memo(id)
	var s := _begin(song, memo, {"save": saver})
	var ev := _run_line(s)
	var disk: Dictionary = SongStore.load_memo(id)
	var key := _key(song, 0)
	ok(ev[ev.size() - 1] == "line_done" and disk["lines"][key]["card"]["state"] == 2, "line end: memo.json on disk has the review card")
	s.next_line()
	var disk_before: Dictionary = SongStore.load_memo(id)
	SongStore.write_hook = func(path): return false
	var fe := _run_line(s)
	var disk_during: Dictionary = SongStore.load_memo(id)
	ok(fe[fe.size() - 1] == "save_failed" and s.last_error == "disk_write", "disk write fails -> save_failed with the store's error code")
	ok(disk_during == disk_before and not s.memo["lines"].has(_key(song, 1)), "memo.json on disk unchanged, session memo unchanged (state kept)")
	SongStore.write_hook = Callable()
	var rr := s.retry_save()
	var disk_after: Dictionary = SongStore.load_memo(id)
	ok(rr["event"] == "line_done" and disk_after["lines"].has(_key(song, 1)) and disk_after["lines"][_key(song, 1)]["card"]["reps"] == 2, "retry after the hook is removed: saved, reps 2")
	s.next_line()
	s.skip_read()
	_ans(s)
	s.leave_line()
	s.finish()
	var d3: Dictionary = SongStore.load_memo(id)
	ok(d3["lines"][_key(song, 2)]["stage"] == 2 and d3["stats"]["sessions"] == 1, "leave + finish: stage 2 and sessions 1 on disk")
	var again := _begin(song, d3, {"save": saver}, NOW + 3 * DAY)
	ok(again.current()["kind"] == "review", "a later session (now + 3 days) reads the disk memo: the due lines come back as review")
	var inst2 := SongStore.install_lyrics(base)
	var ro: Dictionary = SongStore.load_memo(inst2["id"])
	ro["v"] = 2
	var ros := _begin(SongStore.load_song(inst2["id"]), ro, {"save": saver})
	_run_line(ros)
	ok(ros.practice_only and SongStore.load_memo(inst2["id"])["lines"].is_empty(), "read-only memo with the real store: nothing written")
	_rm_rf(ROOT)
	SongStore.root = old_root
	ok(not DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(ROOT)), "test store folder cleaned up")


func _test_review_untouched() -> void:
	print("[the old Review tab cards stay untouched]")
	var before: Array = (Store.progress["review"] as Array).duplicate(true)
	var song := _song("en", _en)
	var s := _begin(song, MemoModel.new_memo())
	for n in 5:
		_run_line(s)
		s.next_line()
	s.finish()
	var after: Array = Store.progress["review"]
	ok(s.summary()["lines_done"] == 5 and after == before, "a full session of 5 lines leaves Store.progress['review'] identical (%d cards)" % after.size())
	var memo_text := JSON.stringify(s.memo)
	ok(not memo_text.contains("kettle") and not memo_text.contains("paper boat"), "the memo holds no lyric text")


func _test_clock_and_summary() -> void:
	print("[clock, day passing, summary]")
	var song := _song("en", _en)
	var t := {"v": NOW}
	var clock := func(): return t["v"]
	var s := _begin(song, MemoModel.new_memo(), {"clock": clock}, 0)
	t["v"] = NOW + 100
	_run_line(s)
	ok(s.memo["lines"][_key(song, 0)]["card"]["last_review"] == NOW + 100 and s.now == NOW + 100, "opts.clock drives last_review (and now)")
	var sm: Dictionary = s.summary()
	ok(sm["memorized"] == 1 and sm["total"] == 6 and sm["lines_done"] == 1 and sm["good"] == 1 and sm["new_done"] == 1, "summary: memorized 1/6, 1 line done (Good, new)")
	ok(sm["next_due"] > NOW + 100 and sm["next_due_in"] == sm["next_due"] - (NOW + 100) and sm["left"] == 4, "summary: next_due is in the future, 4 lines left")
	var days: float = float(sm["next_due_in"]) / DAY
	print("  INFO  summary next review in %.2f days" % days)
	s.next_line()
	_final_line_hard(s)
	var sh: Dictionary = s.summary()
	ok(sh["hard"] == 1 and sh["learning"] == 1 and sh["memorized"] == 1 and sh["lines_done"] == 2, "summary after a Hard line: learning 1, memorized 1")
	ok(sh["next_due_in"] == 600, "summary: the nearest next review is the Hard line, 600 s away")
	for n in 3:
		s.next_line()
		_run_line(s)
	ok(s.next_line() == false and s.finished, "queue exhausted: next_line() false and the session finished automatically")
	ok(s.memo["stats"]["sessions"] == 1 and s.summary()["left"] == 0 and s.summary()["lines_done"] == 5, "5 lines done, sessions 1, nothing left")
	ok(s.current()["ok"] == false, "after the last line current() is ok:false")
	## 3 days later
	var memo2: Dictionary = s.memo.duplicate(true)
	var day3 := _begin(song, memo2, {}, NOW + 3 * DAY + 100)
	var q: Array = day3._queue
	var revs := 0
	for e in q:
		if e["kind"] == "review":
			revs += 1
	ok(revs >= 4, "3 days later: the memorized lines are due again (%d review lines)" % revs)
	ok(day3.current()["kind"] == "review" and day3.current()["final"] and day3.current()["stage"] == day3.current()["stage_count"] - 1, "...and a review line starts at the blank (final) stage")
	var c0: Dictionary = memo2["lines"][day3.current()["key"]]["card"]
	_ans(day3)
	var c1: Dictionary = day3.memo["lines"][day3.current()["key"]]["card"]
	ok(int(c1["due"]) > int(c0["due"]) and c1["last_review"] == NOW + 3 * DAY + 100, "answered correctly: due moves later, last_review == the new now")
	var early := _begin(song, memo2, {}, NOW + 3600)
	var rev_i: Array = []
	for e in early._queue:
		if e["kind"] == "review":
			rev_i.append(e["i"])
	ok(rev_i == [1], "an hour later only the Hard line (10 minutes) is due again (review lines: %s)" % str(rev_i))


func _final_line_hard(s: MemoSession) -> void:
	s.skip_read()
	_ans(s)
	_ans(s)
	_ans(s)
	_ans(s, true)
	_ans(s)


# ------------------------------------------------------------------ misc

func _test_misc() -> void:
	print("[misc]")
	var song := _song("en", _en)
	var s := _begin(song, MemoModel.new_memo())
	var c: Dictionary = s.current()
	var keys: Array = ["ok", "line_i", "key", "text", "reading", "ko", "lang", "kind", "practice_only", "pos", "total", "stage", "stage_count",
		"hidden", "hidden_count", "units", "aligned", "final", "read_only_stage", "fails_stage", "revealed", "prev_text", "answered"]
	var has_all := true
	for k in keys:
		if not c.has(k):
			has_all = false
	ok(has_all, "current() has every key of the design (section 5.5)")
	var sx := _begin(song, MemoModel.new_memo())
	var first := _run_line(sx)
	var again_done := sx.submit(MemoGrade.self_result(true))
	ok(first[first.size() - 1] == "line_done" and again_done["event"] == "ignored" and again_done["reason"] == "done", "a finished line: submit is ignored with reason 'done'")
	var s2 := _begin(song, MemoModel.new_memo())
	var s3 := _begin(song, MemoModel.new_memo())
	_run_line(s2)
	_run_line(s3)
	ok(s2.memo == s3.memo, "same input and clock -> identical memo (no randomness)")
	var one := _begin(song, MemoModel.new_memo(), {"only_line": 4})
	ok(one.current()["kind"] == "new" and one.current()["total"] == 1 and one.current()["line_i"] == 4, "only_line on a fresh line: kind new, queue of 1")
	var rep := _song("en", [_en[0], _en[1], _en[0], _en[0].to_upper()])
	var sr := _begin(rep, MemoModel.new_memo())
	ok(sr.current()["total"] == 2, "a refrain repeated 3 times (case differs): one queue entry")
	var jj := _song("ja", _ja)
	jj["lines"].insert(2, {"i": 2, "p": 0, "t0": 0.0, "t1": 0.0, "text": "[間奏]", "reading": "", "pron": "", "ko": ""})
	var sj := _begin(jj, MemoModel.new_memo())
	ok(sj.current()["total"] == 5, "Japanese: the [interlude] marker line is not in the queue")


func _test_purity() -> void:
	print("[purity and independence]")
	var f := FileAccess.open(SRC_PATH, FileAccess.READ)
	var src: String = f.get_as_text() if f != null else ""
	if f != null:
		f.close()
	ok(src.length() > 1000, "read memo_session.gd")
	for pat in ["Store.", "StudyLog", "FileAccess", "DirAccess", "RandomNumberGenerator", "randi", "randf", "Time.", "HTTPRequest", "OS."]:
		ok(not src.contains(pat), "memo_session.gd does not contain `%s`" % pat)
	ok(not src.contains("Engine.get_main_loop") and not src.contains("get_node") and not src.contains("autoload"), "no global lookups")


func _rm_rf(path: String) -> void:
	var g := ProjectSettings.globalize_path(path)
	var d := DirAccess.open(g)
	if d != null:
		for sub in d.get_directories():
			_rm_rf(path.path_join(sub))
		for fn in d.get_files():
			DirAccess.remove_absolute(g.path_join(fn))
	DirAccess.remove_absolute(g)
