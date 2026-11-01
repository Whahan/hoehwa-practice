extends Node
## HomeModel (홈 할 일·시작 버튼·이어하기·인사 문구) 표 시험. 순수 계산이라 스냅샷은 전부 직접 만든 사전이다.
##   godot --headless --path <project> res://tests/home_model_test.tscn
## Exit code 0 = all passed. Last line: "== home_model result: N passed, 0 failed =="
## 파일을 쓰지 않는다(시험 전후 user:// 목록 비교). 검사 함수도 일부러 틀린 값을 넣어 실패로 판정하는지 확인한다(selfcheck).

const NOW := 1790000000
const DAY := 86400

var passed: int = 0
var failed: int = 0
var _before: Array = []


func _ready() -> void:
	print("== home_model start ==")
	_before = _user_listing()
	_selfcheck()
	_tasks_table()
	_hero_table()
	_robustness()
	_messages()
	_resume()
	_purity()
	print("== home_model result: %d passed, %d failed ==" % [passed, failed])
	get_tree().quit(1 if failed > 0 else 0)


func ok(cond: bool, name: String) -> void:
	if cond:
		passed += 1
		print("  PASS  ", name)
	else:
		failed += 1
		print("  FAIL  ", name)


## 두 값을 JSON 글자로 비교한다(사전 순서 무관).
func same(got: Variant, want: Variant) -> bool:
	return JSON.stringify(got, "", true) == JSON.stringify(want, "", true)


func eq(got: Variant, want: Variant, name: String) -> void:
	var good: bool = same(got, want)
	ok(good, name if good else "%s  got=%s want=%s" % [name, JSON.stringify(got), JSON.stringify(want)])


## 스냅샷: 3개월차 2주(3/5), 평범한 사용 중인 사람. 필요한 키만 덮어쓴다.
func S(over: Dictionary = {}) -> Dictionary:
	var s := {"lang": "en", "phase": "on", "before_days": 0, "lesson_today": 0, "due": 0, "reviews_today": 0, "song_due": 0, "song_count": 0,
		"path": {"n": 3, "w": 2, "done": 3, "goal": 5, "finished": false},
		"goal_min": 10, "sec_today": 0, "streak": 0, "tokens": 0, "studied_today": false, "has_data": true, "first_run": false,
		"hour": 10, "now": NOW, "resume": {}}
	for k in over.keys():
		s[k] = over[k]
	return s


func line(ts: Array) -> String:
	var parts: PackedStringArray = []
	for t in ts:
		parts.append("%s:%s" % [t["id"], t["state"]])
	return ",".join(parts)


func titles(ts: Array) -> Array:
	var out: Array = []
	for t in ts:
		out.append(t["title"])
	return out


func rs(view: String, at: int, lang: String = "en") -> Dictionary:
	return {"view": view, "lang": lang, "at": at}


func _selfcheck() -> void:
	print("[selfcheck: 검사 함수가 틀린 값을 실패로 판정하는가]")
	var wrong1: bool = same(line(HomeModel.tasks(S())), "lesson:done,talk:optional")
	print("selfcheck %s tasks line vs wrong order" % ("FAIL-as-expected" if not wrong1 else "UNEXPECTED-PASS"))
	ok(not wrong1, "same() rejects a wrong task line")
	var wrong2: bool = same(HomeModel.message(S({"streak": 5, "hour": 20}))["text"], "오늘 아직이에요. 지금 하면 연속 5일!")
	print("selfcheck %s message vs off-by-one streak" % ("FAIL-as-expected" if not wrong2 else "UNEXPECTED-PASS"))
	ok(not wrong2, "same() rejects an off-by-one message")
	var wrong3: bool = same(HomeModel.hero(S({"due": 12}))["text"], "복습 12개 시작 ")
	print("selfcheck %s hero text vs trailing space" % ("FAIL-as-expected" if not wrong3 else "UNEXPECTED-PASS"))
	ok(not wrong3, "same() rejects a text that differs by one space")
	ok(same({"a": 1, "b": [1, 2]}, {"b": [1, 2], "a": 1}), "same() ignores key order")


func _tasks_table() -> void:
	print("[tasks]")
	var t: Array = HomeModel.tasks(S({"has_data": false, "first_run": true}))
	eq(line(t), "lesson:todo,talk:optional", "new user: lesson todo + talk optional, no review/song line")
	eq(titles(t), ["오늘의 레슨", "원어민과 말해 보기"], "new user titles")
	eq(t[0]["sub"], "3개월차 2주 · 3/5", "lesson sub shows the path cell")
	eq(t[0]["target"], {"view": "lesson", "args": {"lang": "en", "n": 3, "w": 2, "start": true}}, "lesson target args")
	eq(t[1]["sub"], "선택 · 5분이면 충분해요", "talk line sub")
	eq(t[1]["target"], {"view": "talk", "args": {"lang": "en"}}, "talk target")

	eq(line(HomeModel.tasks(S({"due": 12}))), "lesson:todo,review:todo,talk:optional", "due 12: review after lesson")
	eq(line(HomeModel.tasks(S({"due": 19}))), "lesson:todo,review:todo,talk:optional", "due 19: still after lesson")
	eq(line(HomeModel.tasks(S({"due": 20}))), "review:todo,lesson:todo,talk:optional", "due 20: review before lesson")
	eq(line(HomeModel.tasks(S({"due": 20, "lesson_today": 1}))), "review:todo,lesson:done,talk:optional", "due 20 + lesson done: review first, lesson after")
	eq(titles(HomeModel.tasks(S({"due": 12})))[1], "복습 12개", "review title format")

	eq(line(HomeModel.tasks(S({"lesson_today": 1, "due": 12}))), "review:todo,lesson:done,talk:optional", "lesson done: todo first, done after")
	eq(titles(HomeModel.tasks(S({"lesson_today": 1})))[0], "오늘의 레슨 완료", "lesson done title")
	var all_done: Array = HomeModel.tasks(S({"lesson_today": 2, "due": 0, "reviews_today": 3}))
	eq(line(all_done), "lesson:done,review:done,talk:optional", "everything done")
	eq(titles(all_done)[1], "복습 끝!", "due 0 and reviews today: 복습 끝!")

	var no_rev: Array = HomeModel.tasks(S({"due": 0, "reviews_today": 0}))
	var has_rev_text := false
	for x in titles(no_rev) + [t[0]["sub"], t[1]["sub"]]:
		if str(x).contains("복습"):
			has_rev_text = true
	ok(not has_rev_text, "due 0 and no review today: the word 복습 appears nowhere")

	eq(line(HomeModel.tasks(S({"song_due": 3}))), "lesson:todo,song:todo,talk:optional", "song_due 3: song line")
	eq(titles(HomeModel.tasks(S({"song_due": 3})))[1], "노래 외우기 3줄", "song title")
	eq(line(HomeModel.tasks(S({"song_due": 0, "song_count": 4}))), "lesson:todo,talk:optional", "songs exist but none due: no song line")
	eq(line(HomeModel.tasks(S({"due": 12, "song_due": 3}))), "lesson:todo,review:todo,song:todo,talk:optional", "4 lines max, base order")
	eq(line(HomeModel.tasks(S({"lesson_today": 1, "song_due": 2}))), "song:todo,lesson:done,talk:optional", "done lines go behind todo lines")

	var fin: Array = HomeModel.tasks(S({"path": {"n": 12, "w": 4, "done": 5, "goal": 5, "finished": true}}))
	eq(fin[0]["sub"], "1년 과정을 마쳤어요 · 복습 삼아 해 봐요", "finished path: lesson sub text")
	eq(line(fin), "lesson:todo,talk:optional", "finished path: the lesson line stays")


func _hero_table() -> void:
	print("[hero]")
	var h: Dictionary = HomeModel.hero(S({"has_data": false, "first_run": true}))
	eq([h["text"], h["kind"], h["all_done"]], ["오늘의 레슨 시작", "lesson", false], "new user: 오늘의 레슨 시작")
	eq(h["target"], {"view": "lesson", "args": {"lang": "en", "n": 3, "w": 2, "start": true}}, "hero target = lesson cell")
	h = HomeModel.hero(S({"resume": rs("lesson", NOW - 600)}))
	eq(h["text"], "레슨 이어하기", "recent lesson activity: 레슨 이어하기")
	h = HomeModel.hero(S({"resume": rs("review", NOW - 600)}))
	eq(h["text"], "오늘의 레슨 시작", "recent review activity does not rename the lesson button")
	h = HomeModel.hero(S({"resume": rs("lesson", NOW - 9 * DAY)}))
	eq(h["text"], "오늘의 레슨 시작", "old lesson activity: plain start")
	h = HomeModel.hero(S({"due": 12, "lesson_today": 1}))
	eq([h["text"], h["kind"], h["target"]["view"]], ["복습 12개 시작", "review", "review"], "lesson done: hero = review")
	h = HomeModel.hero(S({"due": 20}))
	eq([h["text"], h["kind"]], ["복습 20개 시작", "review"], "due 20: hero is review although lesson is todo")
	h = HomeModel.hero(S({"due": 19}))
	eq(h["kind"], "lesson", "due 19: hero stays lesson")
	h = HomeModel.hero(S({"lesson_today": 1, "song_due": 3}))
	eq([h["text"], h["kind"], h["target"]["view"]], ["노래 외우기 시작", "song", "song"], "lesson done + songs due: hero = song")
	h = HomeModel.hero(S({"lesson_today": 1, "reviews_today": 2}))
	eq([h["text"], h["kind"], h["all_done"], h["target"]["view"]], ["더 연습하기", "practice", true, "practice"], "all done: 더 연습하기")
	h = HomeModel.hero(S({"lang": "ja", "lesson_today": 1}))
	eq(h["target"], {"view": "practice", "args": {"lang": "ja"}}, "target carries the language")


func _robustness() -> void:
	print("[bad input]")
	var t: Array = HomeModel.tasks({})
	eq(line(t), "lesson:todo,talk:optional", "empty snapshot {} -> defaults, no error")
	eq(HomeModel.hero({})["text"], "오늘의 레슨 시작", "empty snapshot hero")
	eq(HomeModel.resume({}), {}, "empty snapshot resume")
	eq(HomeModel.message({})["kind"], "info", "empty snapshot message")
	eq(line(HomeModel.tasks(S({"due": -5}))), "lesson:todo,talk:optional", "due -5 -> no review line")
	eq(titles(HomeModel.tasks(S({"due": 1000000000})))[0], "복습 1000000000개", "due 10**9 (review first, text intact)")
	eq(titles(HomeModel.tasks(S({"due": 1.0e99})))[0], "복습 1000000000개", "due 1e99 float -> capped, no crash")
	eq(line(HomeModel.tasks(S({"due": "12"}))), "lesson:todo,talk:optional", "due as string -> 0")
	eq(line(HomeModel.tasks(S({"due": NAN, "song_due": INF}))), "lesson:todo,talk:optional", "NAN / INF -> defaults")
	eq(line(HomeModel.tasks(S({"due": null, "lesson_today": [1]}))), "lesson:todo,talk:optional", "null / array values -> defaults")
	var weird: Dictionary = {"lang": "fr", "path": 5, "resume": "x", "phase": 7, "hour": 99, "streak": -3}
	eq(line(HomeModel.tasks(weird)), "lesson:todo,talk:optional", "path/resume of the wrong type")
	eq(HomeModel.hero(weird)["target"]["args"]["lang"], "en", "unknown language falls back to en")
	eq(HomeModel.tasks(S({"path": {"n": 99, "w": -4, "done": 99999, "goal": 0}}))[0]["sub"], "12개월차 1주 · 5/5", "path numbers are clamped (goal 0 -> 5 default)")
	var s: Dictionary = S({"due": 12, "resume": rs("review", NOW)})
	var copy: Dictionary = s.duplicate(true)
	HomeModel.tasks(s)
	HomeModel.hero(s)
	HomeModel.resume(s)
	HomeModel.message(s)
	eq(s, copy, "functions do not modify the snapshot they are given")
	eq(HomeModel.snapshot("en"), {}, "snapshot() is only a stub in this task (returns {})")


func _messages() -> void:
	print("[message table]")
	var m: Dictionary
	m = HomeModel.message(S({"phase": "before", "before_days": 9}))
	eq([m["text"], m["kind"]], ["시작까지 D-9 · 지금 맛보기 레슨을 해 볼 수 있어요", "info"], "1: before start")
	m = HomeModel.message(S({"phase": "before", "before_days": 3, "first_run": true}))
	eq(m["text"], "시작까지 D-3 · 지금 맛보기 레슨을 해 볼 수 있어요", "1 beats 2 (before + first_run)")
	m = HomeModel.message(S({"phase": "before", "before_days": 3, "sec_today": 6000, "streak": 4, "hour": 20}))
	eq(m["text"], "시작까지 D-3 · 지금 맛보기 레슨을 해 볼 수 있어요", "1 beats 3 and 4")
	m = HomeModel.message(S({"first_run": true, "has_data": false}))
	eq([m["text"], m["kind"]], ["처음이에요! 레슨 하나부터 가볍게 시작해요.", "info"], "2: first run")
	m = HomeModel.message(S({"first_run": true, "sec_today": 600}))
	eq(m["text"], "처음이에요! 레슨 하나부터 가볍게 시작해요.", "2 beats 3")
	m = HomeModel.message(S({"sec_today": 600, "streak": 5}))
	eq([m["text"], m["kind"]], ["오늘 목표 달성! 연속 5일째예요.", "ok"], "3: goal reached, streak 5")
	m = HomeModel.message(S({"sec_today": 600, "streak": 2}))
	eq(m["text"], "오늘 목표 달성! 연속 2일째예요.", "3: streak 2 is the lowest that prints the streak")
	m = HomeModel.message(S({"sec_today": 600, "streak": 1}))
	eq([m["text"], m["kind"]], ["오늘 목표 달성! 잘했어요.", "ok"], "3: goal reached, streak 1")
	m = HomeModel.message(S({"sec_today": 599, "streak": 1}))
	ok(m["kind"] != "ok" or m["text"] != "오늘 목표 달성! 잘했어요.", "3: 599 sec of a 10 min goal is not reached")
	m = HomeModel.message(S({"sec_today": 9999, "goal_min": 0, "streak": 0}))
	ok(not str(m["text"]).begins_with("오늘 목표 달성"), "3: goal off (0) never counts as reached")
	m = HomeModel.message(S({"sec_today": 600, "streak": 5, "hour": 22}))
	eq(m["kind"], "ok", "3 beats 4")
	m = HomeModel.message(S({"streak": 5, "hour": 18}))
	eq([m["text"], m["kind"]], ["오늘 아직이에요. 지금 하면 연속 6일!", "warn"], "4: evening, streak 5 -> 6")
	m = HomeModel.message(S({"streak": 5, "hour": 17}))
	eq(m["text"], "오늘 할 일 1개 남았어요.", "4: before 18:00 falls through to 6")
	m = HomeModel.message(S({"streak": 5, "hour": 23, "studied_today": true, "lesson_today": 1}))
	eq(m["text"], "오늘 할 일을 다 했어요.", "4: studied today -> not the warning")
	m = HomeModel.message(S({"streak": 0, "has_data": true, "hour": 20}))
	eq([m["text"], m["kind"]], ["다시 시작해요. 오늘 한 번이면 연속 1일이에요.", "info"], "5: streak 0 with records")
	m = HomeModel.message(S({"streak": 0, "has_data": false}))
	eq(m["text"], "오늘 할 일 1개 남았어요.", "5 needs records; without them -> 6")
	m = HomeModel.message(S({"streak": 3, "due": 12, "song_due": 2}))
	eq([m["text"], m["kind"]], ["오늘 할 일 3개 남았어요.", "info"], "6: counts todo lines only (lesson, review, song)")
	m = HomeModel.message(S({"streak": 3, "lesson_today": 1, "reviews_today": 1}))
	eq([m["text"], m["kind"]], ["오늘 할 일을 다 했어요.", "ok"], "7: nothing left")


func _resume() -> void:
	print("[resume card]")
	eq(HomeModel.resume(S({"resume": rs("lesson", NOW - 60)})), {}, "lesson activity while the hero is the lesson -> no card")
	var c: Dictionary = HomeModel.resume(S({"due": 25, "resume": rs("lesson", NOW - 60)}))
	eq([c.get("title"), c.get("sub"), c.get("button")], ["레슨 이어하기", "3개월차 2주 · 3/5", "시작"], "lesson card text (hero is review)")
	eq(c.get("target"), {"view": "lesson", "args": {"lang": "en", "n": 3, "w": 2, "start": true}}, "lesson card target = navigate_args payload")
	c = HomeModel.resume(S({"due": 12, "resume": rs("review", NOW - 60)}))
	eq([c.get("title"), c.get("sub"), c.get("button")], ["복습 이어하기", "남은 12개", "시작"], "review card text (hero is the lesson)")
	eq(c.get("target"), {"view": "review", "args": {"lang": "en"}}, "review card target")
	c = HomeModel.resume(S({"due": 12, "lesson_today": 1, "resume": rs("review", NOW - 60)}))
	eq(c, {}, "review activity while the hero is review -> no card")
	c = HomeModel.resume(S({"due": 0, "resume": rs("review", NOW - 60)}))
	eq(c, {}, "review with nothing left (0) -> no card")
	c = HomeModel.resume(S({"song_due": 2, "lesson_today": 1, "due": 5, "resume": rs("song", NOW - 60)}))
	eq([c.get("title"), c.get("target")], ["노래 이어하기", {"view": "song", "args": {"lang": "en"}}], "song card (hero is review)")
	c = HomeModel.resume(S({"resume": rs("song", NOW - 7 * DAY)}))
	eq(c.get("title"), "노래 이어하기", "exactly 7 days old is still shown")
	eq(HomeModel.resume(S({"resume": rs("song", NOW - 7 * DAY - 1)})), {}, "7 days + 1 s -> no card")
	eq(HomeModel.resume(S({"resume": rs("song", NOW - 8 * DAY)})), {}, "8 days old -> no card")
	eq(HomeModel.resume(S({"resume": rs("song", NOW + 2 * DAY)})), {}, "2 days in the future -> no card")
	eq(HomeModel.resume(S({"resume": rs("song", NOW + DAY + 1)})), {}, "1 day + 1 s in the future -> no card")
	eq(HomeModel.resume(S({"resume": rs("song", NOW + DAY)})).get("title"), "노래 이어하기", "exactly 1 day ahead is tolerated")
	eq(HomeModel.resume(S({"resume": rs("hack", NOW)})), {}, "view \"hack\" -> no card")
	eq(HomeModel.resume(S({"resume": {"view": "song", "lang": "en", "at": "yesterday"}})), {}, "at as a string -> no card")
	eq(HomeModel.resume(S({"resume": {"view": "song", "lang": "en", "at": null}})), {}, "at null -> no card")
	eq(HomeModel.resume(S({"resume": rs("song", -5)})), {}, "negative at -> no card")
	eq(HomeModel.resume(S({"resume": rs("song", NOW, "fr")})), {}, "unknown language in the record -> no card")
	eq(HomeModel.resume(S({"resume": rs("song", NOW, "ja")})), {}, "record of the other language -> no card (assumption, see report)")
	eq(HomeModel.resume(S({"resume": "lesson"})), {}, "resume is not a dictionary -> no card")
	eq(HomeModel.resume(S({"resume": null})), {}, "resume null -> no card")
	eq(HomeModel.resume(S({"resume": {}})), {}, "no record -> no card")
	eq(HomeModel.resume(S({"has_data": false, "first_run": true})), {}, "new user -> no card")
	eq(HomeModel.resume(S({"resume": rs("practice", NOW)})).get("title"), "연습 이어하기", "practice card")
	eq(HomeModel.resume(S({"resume": rs("reading", NOW)})).get("title"), "읽기 이어하기", "reading card")
	eq(HomeModel.resume(S({"resume": rs("talk", NOW)})).get("title"), "대화 이어하기", "talk card")
	eq(HomeModel.resume(S({"lesson_today": 1, "reviews_today": 1, "resume": rs("practice", NOW)})), {}, "all done: the hero is practice, so a practice card is not repeated")
	var fl: Dictionary = HomeModel.resume(S({"resume": {"view": "talk", "lang": "en", "at": float(NOW)}}))
	eq(fl.get("title"), "대화 이어하기", "at stored as a float is accepted")


func _purity() -> void:
	print("[pure calculation]")
	var f := FileAccess.open("res://scripts/core/home_model.gd", FileAccess.READ)
	var raw: String = f.get_as_text() if f != null else ""
	ok(raw != "", "home_model.gd readable")
	var src: String = ""
	for ln in raw.split("
"): # 주석은 빼고 검사한다(snapshot 의 TODO 주석이 Store 를 언급한다)
		var cut: int = ln.find("#")
		src += (ln if cut < 0 else ln.substr(0, cut)) + "
"
	var bad: Array = []
	for w in ["FileAccess", "DirAccess", "Control", "Node", "add_child", ".new(", "Time.", "Store.", "StudyLog.", "Thread"]:
		if src.contains(w):
			bad.append(w)
	ok(bad.is_empty(), "home_model.gd has no file / node / clock / Store access %s" % str(bad))
	var after: Array = _user_listing()
	ok(same(_before, after), "user:// listing unchanged by this test")
	# 검사 함수가 실패할 수 있는지: 일부러 금지어가 든 글자를 같은 방식으로 검사한다.
	var fake: String = "func x(): add_child(Control.new())"
	var fake_bad: Array = []
	for w in ["FileAccess", "Control", "add_child"]:
		if fake.contains(w):
			fake_bad.append(w)
	print("selfcheck %s forbidden-word scan on a fake source" % ("FAIL-as-expected" if not fake_bad.is_empty() else "UNEXPECTED-PASS"))
	ok(not fake_bad.is_empty(), "the forbidden-word scan flags a fake source")


func _user_listing() -> Array:
	var out: Array = []
	var d := DirAccess.open("user://")
	if d == null:
		return out
	for n in d.get_files():
		out.append("%s:%d" % [n, FileAccess.get_file_as_bytes("user://" + n).size()])
	out.sort()
	return out
