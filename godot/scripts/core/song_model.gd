class_name SongModel
extends RefCounted
## 노래 공부: 곡 JSON(song.json v1)의 보정기. 순수 함수 (파일·네트워크·시계·난수·전역 상태를 쓰지 않는다).
## 설계 docs/song_study_design.md §5.2.
##
##   SongModel.normalize(raw) -> Dictionary   읽을 때마다(그리고 저장 전에) 거치는 보정. 입력은 바꾸지 않는다.
##
## 규칙(§5.2):
##   - raw 가 Dictionary 가 아니면 {} (곡 아님).
##   - v: 정수, 없거나 1 미만이면 1. v > 1 이면 읽기 전용(is_read_only) — 보정은 하되 저장은 SongStore 가 거절한다.
##   - 시간은 [0, duration] 으로 자르고 t1 > t0 (최소 MIN_LINE), 줄은 t0 오름차순(같으면 원래 순서), 줄 번호 i 는 0.. 로 다시 붙인다.
##     (marks.lines 와 stats.best 의 줄 번호는 줄이 옮겨진 만큼 따라 옮긴다. 지워진 줄의 표시는 버린다.)
##   - 줄 <= MAX_LINES(400), 단어 <= MAX_WORDS(80), 용어집 <= MAX_GLOSSARY, 문자열은 필드별 상한, 제어문자 제거.
##   - 모르는 level 은 "mid". 알 수 없는 키는 최상위·줄·단어에서 보존한다(보정하지 않음). 단 "_" 로 시작하는 키는
##     실행 중 내부 값(예: _audio_path)이라 디스크의 값을 믿지 않고 버린다.
##   - NaN/inf/문자열 같은 숫자 아닌 값은 0 (또는 기본값)으로 본다.
##
## 곡 종류(kind, docs/lyrics_memorize_design.md §5.1):
##   - 최상위 "kind" 가 "lyrics" 이면 음원 없는 곡(가사 외우기용): duration 0, 모든 줄 t0 = t1 = 0 (줄 순서는 입력 순서 그대로),
##     audio = {file "", bytes 0, sha256 "", orig_name ""}, source.timing "none", offset 0.
##   - "kind" 가 없거나 "audio" 거나 알 수 없는 값이면 음원 곡이다. 이때 출력에는 "kind" 키를 넣지 않는다 (kind 가 없던 시절의
##     정규화 결과와 한 바이트도 다르지 않다. 음원 곡의 source.timing "none" 은 예전처럼 "line" 으로 보정한다).
##   - 불변식 0 <= t0 < t1 <= duration 은 음원 곡에만 적용된다 (가사 곡은 시간이 없다).

const CURRENT_V := 1
const MAX_LINES := 400
const MAX_WORDS := 80
const MAX_GLOSSARY := 600
const MAX_MARK_WORDS := 600
const MAX_WARNINGS := 20
const MAX_DURATION := 7200.0
const MIN_LINE := 0.1 ## 줄 길이 하한(초)
const OFFSET_LIM := 5.0
const LEVELS := ["easy", "mid", "hard"]
const LANGS := ["en", "ja"]
const LYRICS_SOURCES := ["asr", "pasted", "lrclib"]
const TIMINGS := ["line", "word", "est", "none"] ## "none" 은 가사 곡(kind "lyrics")만
const KINDS := ["audio", "lyrics"]
## 필드별 문자열 상한 (글자 수)
const LEN_TITLE := 200
const LEN_LINE := 200 ## 서버 MAX_LINE_CHARS 와 같다
const LEN_READING := 400
const LEN_KO := 400
const LEN_WORD := 64
const LEN_GLOSS := 200
const LEN_NAME := 200
const LEN_ATTR := 200
const LEN_SMALL := 40


# ---------------------------------------------------------------- scalar helpers

## Removes control characters (< 0x20, 0x7f) and cuts to `max_len` characters. Non-strings become "".
static func clean_str(v: Variant, max_len: int) -> String:
	if not (v is String):
		return ""
	var s: String = v
	var out := ""
	var last: int = 0
	for i in s.length():
		var c: int = s.unicode_at(i)
		if c < 32 or c == 127:
			out += s.substr(last, i - last)
			last = i + 1
	out += s.substr(last)
	if out.length() > max_len:
		out = out.substr(0, max_len)
	return out


static func is_finite_num(v: Variant) -> bool:
	return v is int or (v is float and not is_nan(v) and not is_inf(v))


## Finite number in [lo, hi]; anything else -> dflt (clamped too).
static func num(v: Variant, lo: float, hi: float, dflt: float) -> float:
	if is_finite_num(v):
		return clampf(float(v), lo, hi)
	return clampf(dflt, lo, hi)


static func int_of(v: Variant, lo: int, hi: int, dflt: int) -> int:
	if v is int:
		return clampi(v, lo, hi)
	if v is float and not is_nan(v) and not is_inf(v):
		return clampi(int(clampf(v, -4.0e18, 4.0e18)), lo, hi)
	return clampi(dflt, lo, hi)


static func flag(v: Variant, dflt: bool = false) -> bool:
	return v if v is bool else dflt


static func hex64(v: Variant) -> String:
	if not (v is String):
		return ""
	var s: String = (v as String).to_lower()
	if s.length() != 64:
		return ""
	for i in 64:
		var c: int = s.unicode_at(i)
		if not ((c >= 48 and c <= 57) or (c >= 97 and c <= 102)):
			return ""
	return s


static func is_valid_id(id: Variant) -> bool:
	if not (id is String):
		return false
	var s: String = id
	if s.length() != 14 or not s.begins_with("s_"):
		return false
	for i in range(2, 14):
		var c: int = s.unicode_at(i)
		if not ((c >= 48 and c <= 57) or (c >= 97 and c <= 102)):
			return false
	return true


static func is_read_only(song: Dictionary) -> bool:
	return int(song.get("v", 1)) > CURRENT_V


## 음원 없는 곡(kind "lyrics")인가. 정규화를 거친 곡이나 읽어 온 곡 사전에 쓴다.
static func is_lyrics(song: Dictionary) -> bool:
	var k: Variant = song.get("kind", "audio")
	return k is String and k == "lyrics"


# ---------------------------------------------------------------- normalize

const _KNOWN_TOP := ["kind", "v", "id", "lang", "title", "artist", "created", "duration", "audio", "source", "offset", "lines",
	"glossary", "marks", "stats", "warnings", "app"]
const _KNOWN_LINE := ["i", "p", "t0", "t1", "text", "reading", "pron", "ko", "conf", "est", "stale", "words"]
const _KNOWN_WORD := ["w", "lemma", "level", "zipf", "s", "e", "est", "content", "reading"]


static func normalize(raw: Variant) -> Dictionary:
	if not (raw is Dictionary):
		return {}
	var src: Dictionary = raw
	var out := {}
	# unknown top-level keys are kept as they are
	for k in src.keys():
		if k is String and not _KNOWN_TOP.has(k) and not k.begins_with("_"):
			out[k] = _copy(src[k])
	var v: int = int_of(src.get("v", 1), 1, 1000000, 1)
	out["v"] = v
	var id: Variant = src.get("id", "")
	out["id"] = id if is_valid_id(id) else ""
	var lang: Variant = src.get("lang", "en")
	out["lang"] = lang if (lang is String and LANGS.has(lang)) else "en"
	out["title"] = clean_str(src.get("title", ""), LEN_TITLE)
	out["artist"] = clean_str(src.get("artist", ""), LEN_TITLE)
	out["created"] = int_of(src.get("created", 0), 0, 4102444800, 0)
	var kind: Variant = src.get("kind", "audio")
	var lyrics_only: bool = kind is String and kind == "lyrics"
	if lyrics_only:
		out["kind"] = "lyrics"
	var dur: float = num(src.get("duration", 0.0), 0.0, MAX_DURATION, 0.0)
	if lyrics_only:
		dur = 0.0

	# --- lines (positions in the input array are remembered for marks / best)
	var raw_lines: Variant = src.get("lines", [])
	var items: Array = [] ## [t0, original position, line]
	var pos: int = 0
	var max_end: float = 0.0
	if raw_lines is Array:
		for rl in (raw_lines as Array):
			var my_pos: int = pos
			pos += 1
			if not (rl is Dictionary):
				continue
			if items.size() >= MAX_LINES:
				break
			var ln: Dictionary = _norm_line_raw(rl)
			var t0: float = 0.0 if lyrics_only else num(rl.get("t0", 0.0), 0.0, MAX_DURATION, 0.0)
			var t1: float = 0.0 if lyrics_only else num(rl.get("t1", 0.0), 0.0, MAX_DURATION, 0.0)
			ln["t0"] = t0
			ln["t1"] = t1
			max_end = maxf(max_end, maxf(t0, t1))
			items.append([t0, my_pos, ln])
	if dur <= 0.0 and not items.is_empty() and not lyrics_only:
		dur = maxf(max_end, MIN_LINE) ## no usable duration: the lines themselves define it
	out["duration"] = dur
	# stable sort by t0 (ties keep the original order)
	var order: Array = []
	for n in items.size():
		order.append(n)
	order.sort_custom(func(a: int, b: int) -> bool:
		var ta: float = items[a][0]
		var tb: float = items[b][0]
		if ta != tb:
			return ta < tb
		return a < b)
	var remap := {} ## original position -> new index
	var lines: Array = []
	for new_i in order.size():
		var it: Array = items[order[new_i]]
		var ln2: Dictionary = it[2]
		if not lyrics_only:
			_fix_times(ln2, dur)
		ln2["i"] = new_i
		_fix_words(ln2, dur)
		remap[it[1]] = new_i
		lines.append(ln2)
	out["lines"] = lines

	if lyrics_only:
		out["audio"] = {"file": "", "bytes": 0, "sha256": "", "orig_name": ""}
		var lsrc: Dictionary = _norm_source(src.get("source", null))
		lsrc["timing"] = "none"
		out["source"] = lsrc
		out["offset"] = 0.0
	else:
		out["audio"] = _norm_audio(src.get("audio", null))
		var asrc: Dictionary = _norm_source(src.get("source", null))
		if asrc["timing"] == "none":
			asrc["timing"] = "line" ## 예전 정규화와 같은 결과 (음원 곡에 "none" 은 없다)
		out["source"] = asrc
		var off: float = num(src.get("offset", 0.0), -OFFSET_LIM, OFFSET_LIM, 0.0)
		out["offset"] = clampf(snappedf(off, 0.05), -OFFSET_LIM, OFFSET_LIM)
	out["glossary"] = _norm_glossary(src.get("glossary", null))
	out["marks"] = _norm_marks(src.get("marks", null), remap)
	out["stats"] = _norm_stats(src.get("stats", null), remap)
	out["warnings"] = _norm_warnings(src.get("warnings", null))
	out["app"] = clean_str(src.get("app", ""), LEN_SMALL)
	return out


static func _copy(v: Variant) -> Variant:
	if v is Dictionary or v is Array:
		return v.duplicate(true)
	return v


## Fields of a line that do not depend on the others; t0 / t1 / i / words are added by the caller.
static func _norm_line_raw(rl: Dictionary) -> Dictionary:
	var ln := {}
	for k in rl.keys():
		if k is String and not _KNOWN_LINE.has(k) and not k.begins_with("_"):
			ln[k] = _copy(rl[k])
	ln["p"] = int_of(rl.get("p", 0), 0, 9999, 0)
	ln["text"] = clean_str(rl.get("text", ""), LEN_LINE)
	ln["reading"] = clean_str(rl.get("reading", ""), LEN_READING)
	ln["pron"] = clean_str(rl.get("pron", ""), LEN_READING)
	ln["ko"] = clean_str(rl.get("ko", ""), LEN_KO)
	var conf: Variant = rl.get("conf", null)
	ln["conf"] = clampf(float(conf), 0.0, 1.0) if is_finite_num(conf) else null
	ln["est"] = flag(rl.get("est", false))
	ln["stale"] = flag(rl.get("stale", false))
	ln["_words_raw"] = rl.get("words", [])
	return ln


## t0 / t1 into [0, dur] with t1 > t0 (at least MIN_LINE long while the song is long enough).
static func _fix_times(ln: Dictionary, dur: float) -> void:
	var t0: float = clampf(ln["t0"], 0.0, dur)
	var t1: float = clampf(ln["t1"], 0.0, dur)
	if t1 < t0 + MIN_LINE:
		t1 = t0 + MIN_LINE
	if t1 > dur:
		t1 = dur
		t0 = maxf(0.0, minf(t0, dur - MIN_LINE))
	ln["t0"] = t0
	ln["t1"] = t1


static func _fix_words(ln: Dictionary, dur: float) -> void:
	var rw: Variant = ln["_words_raw"]
	ln.erase("_words_raw")
	var words: Array = []
	if rw is Array:
		for w in (rw as Array):
			if words.size() >= MAX_WORDS:
				break
			if not (w is Dictionary):
				continue
			var wd: Dictionary = w
			var o := {}
			for k in wd.keys():
				if k is String and not _KNOWN_WORD.has(k) and not k.begins_with("_"):
					o[k] = _copy(wd[k])
			o["w"] = clean_str(wd.get("w", ""), LEN_WORD)
			o["lemma"] = clean_str(wd.get("lemma", ""), LEN_WORD)
			var lv: Variant = wd.get("level", "mid")
			o["level"] = lv if (lv is String and LEVELS.has(lv)) else "mid"
			o["zipf"] = num(wd.get("zipf", 0.0), 0.0, 10.0, 0.0)
			var s: float = num(wd.get("s", 0.0), 0.0, dur, 0.0)
			var e: float = num(wd.get("e", 0.0), 0.0, dur, 0.0)
			if e < s:
				e = s
			o["s"] = s
			o["e"] = e
			o["est"] = flag(wd.get("est", false))
			o["content"] = flag(wd.get("content", true), true)
			if wd.has("reading"):
				o["reading"] = clean_str(wd.get("reading", ""), LEN_WORD)
			words.append(o)
	ln["words"] = words


static func _norm_audio(raw: Variant) -> Dictionary:
	var a: Dictionary = raw if raw is Dictionary else {}
	var f: String = clean_str(a.get("file", "audio.mp3"), LEN_NAME).replace("\\", "/").get_file()
	if f == "" or f == "." or f == "..":
		f = "audio.mp3"
	return {
		"file": f,
		"bytes": int_of(a.get("bytes", 0), 0, 1 << 40, 0),
		"sha256": hex64(a.get("sha256", "")),
		"orig_name": clean_str(a.get("orig_name", ""), LEN_NAME).replace("\\", "/").get_file(),
	}


static func _norm_source(raw: Variant) -> Dictionary:
	var s: Dictionary = raw if raw is Dictionary else {}
	var ly: Variant = s.get("lyrics", "pasted")
	var tm: Variant = s.get("timing", "line")
	var lid: Variant = s.get("lrclib_id", null)
	return {
		"lyrics": ly if (ly is String and LYRICS_SOURCES.has(ly)) else "pasted",
		"lrclib_id": int_of(lid, 0, 1 << 40, 0) if is_finite_num(lid) else null,
		"timing": tm if (tm is String and TIMINGS.has(tm)) else "line",
		"attribution": clean_str(s.get("attribution", ""), LEN_ATTR),
	}


static func _norm_glossary(raw: Variant) -> Dictionary:
	var out := {}
	if not (raw is Dictionary):
		return out
	for k in (raw as Dictionary).keys():
		if out.size() >= MAX_GLOSSARY:
			break
		if not (k is String):
			continue
		var key: String = clean_str(k, LEN_WORD)
		var e: Variant = (raw as Dictionary)[k]
		if key == "" or not (e is Dictionary):
			continue
		out[key] = {
			"pos": clean_str(e.get("pos", ""), LEN_SMALL),
			"ko": clean_str(e.get("ko", ""), LEN_GLOSS),
			"ipa": clean_str(e.get("ipa", ""), LEN_SMALL),
			"pron": clean_str(e.get("pron", ""), LEN_SMALL),
		}
	return out


static func _norm_marks(raw: Variant, remap: Dictionary) -> Dictionary:
	var m: Dictionary = raw if raw is Dictionary else {}
	var lines: Array = []
	var ml: Variant = m.get("lines", [])
	if ml is Array:
		for x in (ml as Array):
			if is_finite_num(x) and remap.has(int(x)):
				var n: int = remap[int(x)]
				if not lines.has(n):
					lines.append(n)
	lines.sort()
	var words: Array = []
	var mw: Variant = m.get("words", [])
	if mw is Array:
		for x in (mw as Array):
			if words.size() >= MAX_MARK_WORDS:
				break
			if x is String:
				var w: String = clean_str(x, LEN_WORD)
				if w != "" and not words.has(w):
					words.append(w)
	return {"lines": lines, "words": words}


static func _norm_stats(raw: Variant, remap: Dictionary) -> Dictionary:
	var s: Dictionary = raw if raw is Dictionary else {}
	var best := {}
	var bv: Variant = s.get("best", null)
	if bv is Dictionary:
		for k in (bv as Dictionary).keys():
			var ks: String = str(k)
			if not ks.is_valid_int():
				continue
			var old_i: int = int(ks)
			var val: Variant = (bv as Dictionary)[k]
			if remap.has(old_i) and is_finite_num(val):
				var ni: String = str(remap[old_i])
				best[ni] = maxi(int_of(val, 0, 100, 0), int(best.get(ni, 0)))
	return {
		"plays": int_of(s.get("plays", 0), 0, 1000000000, 0),
		"last": int_of(s.get("last", 0), 0, 4102444800, 0),
		"best": best,
	}


static func _norm_warnings(raw: Variant) -> Array:
	var out: Array = []
	if raw is Array:
		for x in (raw as Array):
			if out.size() >= MAX_WARNINGS:
				break
			if x is String:
				var w: String = clean_str(x, LEN_SMALL)
				if w != "" and not out.has(w):
					out.append(w)
	return out
