extends Node
## LrcParser 시험 (서버·파일 없이, 순수 함수).
##   godot --headless --path godot res://tests/lrc_parser_test.tscn
## 가사는 모두 이 파일에서 직접 쓴 문장이다(실제 노래 가사 아님).
## 마지막 줄: "== lrc_parser_test result: N passed, M failed =="  (실패가 있으면 종료 코드 1)
## 일부러 틀린 기대값으로 비교 도우미가 실제로 FAIL 하는지도 본다 (_validator_self_test).

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


## lines 가 [[t, text], ...] 기대값과 같은지 (t 는 1 ms 이내).
func lines_eq(lines: Array, expect: Array) -> bool:
	if lines.size() != expect.size():
		return false
	for i in lines.size():
		var l: Dictionary = lines[i]
		if absf(float(l["t"]) - float(expect[i][0])) > 0.0005:
			return false
		if String(l["text"]) != String(expect[i][1]):
			return false
	return true


func _ready() -> void:
	print("== lrc_parser_test start ==")
	_validator_self_test()
	_test_time_formats()
	_test_multi_tags()
	_test_offset()
	_test_meta()
	_test_gap_lines()
	_test_bad_input()
	_test_crlf_bom_words()
	_test_untimed()
	_test_split_plain()
	_test_result_shape()
	_reached_end = true
	ok(_reached_end, "all sections ran to the end (last section flag set)")
	print("== lrc_parser_test result: %d passed, %d failed ==" % [passed, failed])
	get_tree().quit(1 if failed > 0 else 0)


func _validator_self_test() -> void:
	var r := LrcParser.parse("[00:01.00]one\n[00:02.00]two")
	ok(lines_eq(r["lines"], [[1.0, "one"], [2.0, "two"]]), "helper accepts the right expectation")
	ok(not lines_eq(r["lines"], [[1.0, "one"], [2.5, "two"]]), "helper rejects a wrong time")
	ok(not lines_eq(r["lines"], [[1.0, "one"], [2.0, "TWO"]]), "helper rejects a wrong text")
	ok(not lines_eq(r["lines"], [[1.0, "one"]]), "helper rejects a wrong line count")


func _test_time_formats() -> void:
	var r := LrcParser.parse("[00:17.12]a b c\n[00:20.123]second line\n[00:25]third\n[0:30.1]fourth\n[1:02.50]fifth")
	ok(r["timed"] == true, "timed:true when time tags exist")
	ok(lines_eq(r["lines"], [[17.12, "a b c"], [20.123, "second line"], [25.0, "third"], [30.1, "fourth"], [62.5, "fifth"]]),
		"[00:17.12] [00:20.123] [00:25] [0:30.1] [1:02.50] all parsed")
	var r2 := LrcParser.parse("[10:00.00]ten minutes\n[100:05.5]hundred minutes")
	ok(lines_eq(r2["lines"], [[600.0, "ten minutes"], [6005.5, "hundred minutes"]]), "two- and three-digit minutes")
	var r3 := LrcParser.parse("[00:05.00]  padded text  ")
	ok(lines_eq(r3["lines"], [[5.0, "padded text"]]), "text is trimmed")
	var r4 := LrcParser.parse("[00:01.00]b\n[00:00.50]a")
	ok(lines_eq(r4["lines"], [[0.5, "a"], [1.0, "b"]]), "out-of-order input is sorted by time")


func _test_multi_tags() -> void:
	var r := LrcParser.parse("[00:10.00][01:20.00]refrain line\n[00:30.00]verse line")
	ok(r["lines"].size() == 3, "[00:10.00][01:20.00]text expands to two lines (3 total)")
	ok(lines_eq(r["lines"], [[10.0, "refrain line"], [30.0, "verse line"], [80.0, "refrain line"]]),
		"expanded lines are sorted by time")
	var r2 := LrcParser.parse("[00:05.00]first\n[00:05.00]second")
	ok(lines_eq(r2["lines"], [[5.0, "first"], [5.0, "second"]]), "equal times keep file order")
	var r3 := LrcParser.parse("[00:01.00][00:02.00][00:03.00]x")
	ok(r3["lines"].size() == 3, "three tags on one line give three lines")
	var many := ""
	for i in 40:
		many += "[00:%02d.00]" % i
	var r4 := LrcParser.parse(many + "spam")
	ok(r4["lines"].size() <= LrcParser.MAX_TIME_TAGS, "tag count per line is capped (no blow-up)")


func _test_offset() -> void:
	# 관례: 양수 offset 은 모든 시간에서 빼 준다 (가사가 더 일찍 나옴).
	var r := LrcParser.parse("[offset:+500]\n[00:10.00]a\n[00:20.50]b")
	ok(r["offset_ms"] == 500, "offset_ms keeps the raw value 500")
	ok(lines_eq(r["lines"], [[9.5, "a"], [20.0, "b"]]), "[offset:+500] subtracts 0.5 s from every t")
	var r2 := LrcParser.parse("[00:10.00]a\n[offset:-250]")
	ok(r2["offset_ms"] == -250 and lines_eq(r2["lines"], [[10.25, "a"]]), "[offset:-250] adds 0.25 s (tag after the lyrics works too)")
	var r3 := LrcParser.parse("[offset:+2000]\n[00:01.00]early")
	ok(lines_eq(r3["lines"], [[0.0, "early"]]), "t never goes below 0 after the offset")
	var r4 := LrcParser.parse("[offset:abc]\n[00:03.00]x")
	ok(r4["offset_ms"] == 0 and lines_eq(r4["lines"], [[3.0, "x"]]), "a broken offset value is ignored")
	var r5 := LrcParser.parse("[offset: 100 ]\n[00:03.00]x")
	ok(r5["offset_ms"] == 100, "spaces around the offset value are fine")
	var r6 := LrcParser.parse("[offset:99999999]\n[00:03.00]x")
	ok(r6["offset_ms"] == LrcParser.MAX_OFFSET_MS, "huge offset is clamped")
	var r7 := LrcParser.parse("[00:03.00]x")
	ok(r7["offset_ms"] == 0, "no offset tag -> offset_ms 0")


func _test_meta() -> void:
	var r := LrcParser.parse("[ar:Test Artist]\n[ti:Test Title]\n[al:Test Album]\n[length:03:21]\n[by:someone]\n[00:01.00]hello")
	var m: Dictionary = r["meta"]
	ok(m["ar"] == "Test Artist" and m["ti"] == "Test Title" and m["al"] == "Test Album", "ar / ti / al read")
	ok(m["length"] == "03:21", "[length:03:21] is meta, not a time tag")
	ok(lines_eq(r["lines"], [[1.0, "hello"]]), "meta lines are not lyric lines")
	var r2 := LrcParser.parse("[AR:Upper]\n[00:01.00]x")
	ok(r2["meta"]["ar"] == "Upper", "meta keys are case-insensitive")
	var r3 := LrcParser.parse("[00:01.00]x")
	ok(r3["meta"].has("ar") and r3["meta"]["ar"] == "" and r3["meta"].has("length"), "meta always has the four keys")


func _test_gap_lines() -> void:
	var r := LrcParser.parse("[00:10.00]sing\n[00:14.00]\n[00:20.00]again")
	ok(r["lines"].size() == 3, "empty-text timed line is kept")
	ok(r["lines"][1]["text"] == "" and r["lines"][1].get("gap", false) == true and absf(float(r["lines"][1]["t"]) - 14.0) < 0.001,
		"gap line: text empty, gap:true, t kept")
	ok(not r["lines"][0].get("gap", false), "normal line has no gap flag")
	var r2 := LrcParser.parse("[00:10.00]a\n\n\n[00:12.00]b")
	ok(lines_eq(r2["lines"], [[10.0, "a"], [12.0, "b"]]), "blank lines without a time tag are not lines")


func _test_bad_input() -> void:
	var r := LrcParser.parse("")
	ok(r["lines"].is_empty() and r["timed"] == false, "empty string -> no lines, timed:false")
	var r2 := LrcParser.parse("just some words\nwithout any time tags")
	ok(r2["timed"] == false and r2["lines"].size() == 2 and float(r2["lines"][0]["t"]) == -1.0,
		"text without time tags -> timed:false, t = -1.0")
	var r3 := LrcParser.parse("[99:99.99]bad\n[00:05.00]good")
	ok(lines_eq(r3["lines"], [[5.0, "good"]]), "[99:99.99] line is skipped, the rest survives")
	var r3b := LrcParser.parse("[99:99.99]only bad")
	ok(r3b["lines"].is_empty() and r3b["timed"] == false, "only an invalid time -> nothing, timed:false")
	var r4 := LrcParser.parse("[ab:cd]junk\n[00:05.00]good")
	ok(lines_eq(r4["lines"], [[5.0, "good"]]), "[ab:cd] line is skipped")
	var r4b := LrcParser.parse("[00:75.00]sec too big\n[00:59.99]ok")
	ok(lines_eq(r4b["lines"], [[59.99, "ok"]]), "seconds 75 is invalid, 59.99 is fine")
	var r4c := LrcParser.parse("[00:05.1234]four digit fraction\n[00:06.00]ok")
	ok(lines_eq(r4c["lines"], [[6.0, "ok"]]), "4-digit fraction is invalid")
	var big := "[00:10.00]" + "x".repeat(1024 * 1024)
	var r5 := LrcParser.parse(big + "\n[00:20.00]after")
	ok(lines_eq(r5["lines"], [[20.0, "after"]]), "1 MB single line is skipped, no exception")
	var r5b := LrcParser.parse("y".repeat(1024 * 1024))
	ok(r5b["timed"] == false and r5b["lines"].is_empty(), "1 MB line without tags -> nothing")
	# A Godot String cannot hold a NUL (String.chr(0) makes the engine print "Unexpected NUL character"),
	# so the NUL case is covered by the other control characters (\u0001 \u0008 \u007f) and by the
	# GDScript reading path stopping at NUL before the text ever reaches the parser.
	var r6 := LrcParser.parse("[00:05.00]a\u0008b\n[00:06.00]c\u0001d\u007f\n[00:07.00]ok")
	ok(r6["lines"].size() == 3 and String(r6["lines"][2]["text"]) == "ok", "control chars do not throw")
	ok(String(r6["lines"][0]["text"]) == "ab" and String(r6["lines"][1]["text"]) == "cd", "control chars are cut out of the text")
	var has_ctrl := false
	for l in r6["lines"]:
		if String(l["text"]).find("\u0001") >= 0:
			has_ctrl = true
	ok(not has_ctrl, "control characters are removed from the text")
	var r7 := LrcParser.parse("[00:0")
	ok(r7["lines"].is_empty(), "unclosed bracket -> skipped")
	var r8 := LrcParser.parse("[]\n[:]\n[[[\n]]]\n[00:xx]\n[-1:00.00]neg")
	ok(r8["timed"] == false, "bracket junk does not become timed lines")
	var r9 := LrcParser.parse("[00:01.00]" + "[".repeat(5000))
	ok(r9["lines"].size() <= 1, "5000 open brackets: no hang, no exception")
	var spam := ""
	for i in 3000:
		spam += "[00:01.00]a\n"
	var r10 := LrcParser.parse(spam)
	ok(r10["lines"].size() <= LrcParser.MAX_LINES, "result size is capped")
	var r11 := LrcParser.parse("[Chorus]\n[00:05.00]real")
	ok(lines_eq(r11["lines"], [[5.0, "real"]]), "[Chorus] without time in a timed file is dropped")


func _test_crlf_bom_words() -> void:
	var r := LrcParser.parse("﻿[ti:T]\r\n[00:01.00]one\r\n[00:02.00]two\r\n")
	ok(lines_eq(r["lines"], [[1.0, "one"], [2.0, "two"]]), "CRLF and BOM are handled")
	ok(r["meta"]["ti"] == "T", "meta after BOM is read")
	var r1b := LrcParser.parse("[00:01.00]old mac\r[00:02.00]line ends\r")
	ok(lines_eq(r1b["lines"], [[1.0, "old mac"], [2.0, "line ends"]]), "bare CR line ends")
	var r2 := LrcParser.parse("[00:12.00]<00:12.00>The <00:12.40>quick <00:12.90>fox")
	ok(lines_eq(r2["lines"], [[12.0, "The quick fox"]]), "<mm:ss.xx> word tags removed, text kept")
	ok(r2["words_in_line"] == true, "words_in_line true when word tags exist")
	var r3 := LrcParser.parse("[00:12.00]no word tags here")
	ok(r3["words_in_line"] == false, "words_in_line false otherwise")
	var r4 := LrcParser.parse("[00:12.00]<00:12.00>glued<00:12.30>text")
	ok(lines_eq(r4["lines"], [[12.0, "gluedtext"]]), "tags with no spaces leave glued letters")
	var r5 := LrcParser.parse("[00:12.00]keep <b> and 3 < 5 > 2")
	ok(String(r5["lines"][0]["text"]) == "keep <b> and 3 < 5 > 2" and r5["words_in_line"] == false, "non-time angle brackets stay")


func _test_untimed() -> void:
	var r := LrcParser.parse("first line\n\nsecond line\n[Verse 2]\nthird")
	ok(r["timed"] == false and r["lines"].size() == 4, "untimed text: non-empty lines only (4)")
	ok(String(r["lines"][2]["text"]) == "[Verse 2]", "[Verse 2] (no colon) stays as text")
	var r2 := LrcParser.parse("[ti:Only Meta]\n[ar:X]")
	ok(r2["timed"] == false and r2["lines"].is_empty() and r2["meta"]["ti"] == "Only Meta", "meta only -> no lines, meta read")


func _test_split_plain() -> void:
	var a: Array = LrcParser.split_plain("line one\nline two\n\nline three\n\n\n\nline four")
	ok(a.size() == 4, "split_plain: 4 lines")
	ok(a[0]["p"] == 0 and a[1]["p"] == 0 and a[2]["p"] == 1 and a[3]["p"] == 2, "split_plain: stanza numbers 0,0,1,2 (multiple blanks = one break)")
	ok(String(a[2]["text"]) == "line three", "split_plain: text kept")
	var b: Array = LrcParser.split_plain("\n\n  padded  \r\n\r\nnext\r\n\r\n")
	ok(b.size() == 2 and String(b[0]["text"]) == "padded" and b[0]["p"] == 0 and b[1]["p"] == 1,
		"split_plain: leading/trailing blanks ignored, CRLF, trim")
	ok(LrcParser.split_plain("").is_empty(), "split_plain: empty -> []")
	ok(LrcParser.split_plain("\n  \n\t\n").is_empty(), "split_plain: only blanks -> []")
	var c: Array = LrcParser.split_plain("﻿with bom\nx\u0001y")
	ok(c.size() == 2 and String(c[0]["text"]) == "with bom" and String(c[1]["text"]) == "xy", "split_plain: BOM and control chars removed")
	var d: Array = LrcParser.split_plain("ok\n" + "z".repeat(1024 * 1024) + "\nafter")
	ok(d.size() == 2 and String(d[1]["text"]) == "after", "split_plain: 1 MB line skipped, no exception")
	var e := ""
	for i in 3000:
		e += "l%d\n" % i
	ok(LrcParser.split_plain(e).size() <= LrcParser.MAX_LINES, "split_plain: result size is capped")
	var f: Array = LrcParser.split_plain("한국어 가사 줄\n日本語の行")
	ok(f.size() == 2 and String(f[1]["text"]) == "日本語の行", "split_plain: non-ASCII text kept")


func _test_result_shape() -> void:
	var r := LrcParser.parse("[00:01.00]x")
	var keys: Array = r.keys()
	keys.sort()
	ok(keys == ["lines", "meta", "offset_ms", "timed", "words_in_line"], "result keys are exactly lines/meta/offset_ms/timed/words_in_line")
	ok(typeof(r["lines"][0]["t"]) == TYPE_FLOAT and typeof(r["offset_ms"]) == TYPE_INT, "t is float, offset_ms is int")
	var j := LrcParser.parse("[00:01.00]日本語のうた\n[00:03.50]한국어 줄")
	ok(lines_eq(j["lines"], [[1.0, "日本語のうた"], [3.5, "한국어 줄"]]), "Japanese / Korean text kept as is")
