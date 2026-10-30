class_name LrcParser
extends RefCounted
## LRC lyrics parser (pure, no I/O, never throws on bad input). Design: docs/song_study_design.md section 5.4.
##
## parse(text) -> {lines: [{t: float (-1.0 = no time), text: String, gap: true (only on empty-text lines)}],
##                 offset_ms: int, meta: {ar, ti, al, length}, timed: bool, words_in_line: bool}
##
## Accepted time tags: [mm:ss.xx] [mm:ss.xxx] [mm:ss] [m:ss.x] (minutes 1-3 digits, seconds 00-59,
## fraction 1-3 digits). Several tags in front of one text ("[00:10.00][01:20.00]chorus") expand to one
## line per tag; the result is sorted by time (equal times keep file order).
## [offset:+500] follows the common LRC convention: a positive value means the lyrics should show EARLIER,
## so the offset is SUBTRACTED from every time (result clamped to >= 0). offset_ms keeps the raw value
## (clamped to +-600000). The screen's global offset slider lets the user fix a file that disagrees.
## A timed line with empty text (e.g. "[01:30.00]") is kept as a gap marker: {t, text: "", gap: true}.
## Enhanced-LRC word tags <mm:ss.xx> are removed from the text (words_in_line = true).
## If the file has at least one valid time tag it is "timed" and lines without a time are dropped;
## otherwise timed = false and every non-empty text line is returned with t = -1.0.
## Broken lines (invalid time such as [99:99.99], over-long lines, tags with no text source) are skipped.

const MAX_INPUT_CHARS := 2_000_000 ## longer input is cut (a lyric file is a few KB)
const MAX_LINE_CHARS := 2000 ## a longer line is garbage, skipped
const MAX_LINES := 2000 ## result size cap
const MAX_OFFSET_MS := 600000
const MAX_META_CHARS := 200
const MAX_TIME_TAGS := 12 ## per line

static var _rx_time: RegEx = null
static var _rx_word: RegEx = null
static var _rx_ctrl: RegEx = null
static var _rx_meta: RegEx = null
static var _rx_offset: RegEx = null


static func _init_rx() -> void:
	if _rx_time != null:
		return
	_rx_time = RegEx.new()
	_rx_time.compile("^(\\d+):(\\d+)(?:\\.(\\d+))?$")
	_rx_word = RegEx.new()
	_rx_word.compile("<\\d{1,3}:\\d{1,2}(?:\\.\\d{1,3})?>")
	_rx_ctrl = RegEx.new()
	_rx_ctrl.compile("[\\x00-\\x08\\x0b\\x0c\\x0e-\\x1f\\x7f]")
	_rx_meta = RegEx.new()
	_rx_meta.compile("^([A-Za-z#]{1,16})\\s*:(.*)$")
	_rx_offset = RegEx.new()
	_rx_offset.compile("^\\s*([+-]?)\\s*(\\d{1,9})\\s*$")


static func _empty_result() -> Dictionary:
	return {
		"lines": [],
		"offset_ms": 0,
		"meta": {"ar": "", "ti": "", "al": "", "length": ""},
		"timed": false,
		"words_in_line": false,
	}


## Seconds for the inside of a "[...]" tag. Returns -1.0 if it is not time-shaped at all
## (digits:digits[.digits]), -2.0 if time-shaped but out of range ([99:99.99]).
static func _time_of(inner: String) -> float:
	if inner.length() > 12:
		return -1.0
	var m := _rx_time.search(inner)
	if m == null:
		return -1.0
	var mm: String = m.get_string(1)
	var ss: String = m.get_string(2)
	var fr: String = m.get_string(3)
	if mm.length() > 3 or ss.length() > 2 or fr.length() > 3:
		return -2.0
	var mi: int = int(mm)
	var se: int = int(ss)
	if se > 59:
		return -2.0
	var frac: float = 0.0
	if fr != "":
		frac = float(int(fr)) / pow(10.0, fr.length())
	return float(mi * 60 + se) + frac


static func _clean(s: String) -> String:
	return _rx_ctrl.sub(s, "", true)


static func _normalize_text(text: String) -> String:
	var t := text
	if t.begins_with("﻿"):
		t = t.substr(1)
	t = t.replace("\r\n", "\n").replace("\r", "\n")
	return t


static func parse(text: String) -> Dictionary:
	_init_rx()
	var res := _empty_result()
	var src: String = text
	if src.length() > MAX_INPUT_CHARS:
		src = src.substr(0, MAX_INPUT_CHARS)
	src = _normalize_text(src)

	var timed_lines: Array = [] # [{t, text, n}]
	var plain_lines: Array = []
	var offset_ms: int = 0
	var meta: Dictionary = res["meta"]
	var words_in_line := false
	var seq := 0

	for raw in src.split("\n"):
		var line: String = raw
		if line.length() > MAX_LINE_CHARS:
			continue
		line = line.strip_edges()
		if line == "":
			continue
		# leading [..] tags
		var times: Array = []
		var invalid_time := false
		var saw_meta := false
		var rest := line
		var guard := 0
		while rest.begins_with("[") and guard < 40:
			guard += 1
			var close := rest.find("]")
			if close < 0:
				if times.is_empty():
					invalid_time = true # unclosed "[" at the start of a line: broken line, skipped
				break
			var inner: String = rest.substr(1, close - 1)
			var tv := _time_of(inner)
			if tv >= 0.0:
				if times.size() < MAX_TIME_TAGS:
					times.append(tv)
				rest = rest.substr(close + 1)
				continue
			if tv == -2.0:
				invalid_time = true
				rest = rest.substr(close + 1)
				continue
			var mm := _rx_meta.search(inner)
			if mm != null:
				saw_meta = true
				var key: String = mm.get_string(1).to_lower()
				var val: String = _clean(mm.get_string(2)).strip_edges()
				if val.length() > MAX_META_CHARS:
					val = val.substr(0, MAX_META_CHARS)
				if key == "offset":
					var om := _rx_offset.search(val)
					if om != null:
						var n: int = int(om.get_string(2))
						if om.get_string(1) == "-":
							n = -n
						offset_ms = clampi(n, -MAX_OFFSET_MS, MAX_OFFSET_MS)
				elif meta.has(key) and String(meta[key]) == "":
					meta[key] = val
				rest = rest.substr(close + 1)
				continue
			break # not a tag ("[Chorus]" stays text)
		if times.is_empty():
			if invalid_time or saw_meta:
				continue # broken time / meta line: not lyrics
			var ptxt := _clean(rest).strip_edges()
			if ptxt == "":
				continue
			plain_lines.append({"t": -1.0, "text": ptxt})
			continue
		# text after the time tags
		var body: String = rest
		var had_words := false
		var stripped := _rx_word.sub(body, "", true)
		if stripped.length() != body.length():
			had_words = true
			body = stripped
			while body.find("  ") >= 0:
				body = body.replace("  ", " ")
		body = _clean(body).strip_edges()
		if had_words:
			words_in_line = true
		for tv2 in times:
			timed_lines.append({"t": tv2, "text": body, "n": seq})
			seq += 1

	res["offset_ms"] = offset_ms
	res["words_in_line"] = words_in_line
	if timed_lines.is_empty():
		res["timed"] = false
		var out_plain: Array = []
		for pl in plain_lines:
			if out_plain.size() >= MAX_LINES:
				break
			out_plain.append({"t": -1.0, "text": pl["text"]})
		res["lines"] = out_plain
		return res

	timed_lines.sort_custom(func(a, b): return a["t"] < b["t"] or (a["t"] == b["t"] and a["n"] < b["n"]))
	var shift: float = float(offset_ms) / 1000.0
	var out: Array = []
	for tl in timed_lines:
		if out.size() >= MAX_LINES:
			break
		var tt: float = snappedf(maxf(0.0, float(tl["t"]) - shift), 0.001)
		var entry := {"t": tt, "text": tl["text"]}
		if tl["text"] == "":
			entry["gap"] = true
		out.append(entry)
	res["timed"] = true
	res["lines"] = out
	return res


## Lyrics without times -> [{text: String, p: int}] ; p = stanza number (0-based). One or more blank lines
## start a new stanza; leading/trailing blanks are ignored. Lines are trimmed; control characters and a BOM
## are removed; a line over MAX_LINE_CHARS is skipped. Never throws.
static func split_plain(text: String) -> Array:
	_init_rx()
	var src: String = text
	if src.length() > MAX_INPUT_CHARS:
		src = src.substr(0, MAX_INPUT_CHARS)
	src = _normalize_text(src)
	var out: Array = []
	var p := 0
	var pending_break := false
	for raw in src.split("\n"):
		var line: String = raw
		if line.length() > MAX_LINE_CHARS:
			continue
		line = _clean(line).strip_edges()
		if line == "":
			if not out.is_empty():
				pending_break = true
			continue
		if pending_break:
			p += 1
			pending_break = false
		if out.size() >= MAX_LINES:
			break
		out.append({"text": line, "p": p})
	return out
