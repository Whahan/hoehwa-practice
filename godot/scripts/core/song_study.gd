class_name SongStudy
extends RefCounted
## 노래 공부 로직 (설계 docs/song_study_design.md §5.4, §6, D8, D9): 빈칸 · 모르는 단어 · 복습 카드 항목 ·
## 받아쓰기 점수 · 노래 점수. 곡(song) 은 song.json 모양의 Dictionary (lines[].words[] 등) 를 그대로 받는다.
##
## 카드를 만드는 함수와 빈칸 만들기는 순수 함수다 (같은 입력 -> 같은 결과, 저장소를 건드리지 않는다).
## `add_cards` 만 Store.add_review 를 부른다 (저장은 부르는 쪽이 Store.save_progress()).
##
## 곡이 깨졌거나 줄 번호가 범위 밖이면 예외 없이 빈 결과(ok:false / {} / [])를 돌려준다.

const BLANK := "____"
const MIN_LEVEL := 1
const MAX_LEVEL := 3
const OPTION_COUNT := 4 ## 보기: 정답 1 + 오답 최대 3
const JA_BLANK_PASS := 85 ## 일본어 빈칸 정답 기준 (TextSim 유사도)
const TEXT_MAX := 300 ## 카드 글자 상한 (Store.add_review / SyncDoc.TEXT_MAX 와 같다)
const SNIPPET_MAX := 40 ## 단어 카드 note 에 넣는 줄 앞부분
const TITLE_MAX := 60
const MAX_PICK := 1000
const NOTE_MARK := "♪ "

## 노래 점수: 정확도·또렷함만 쓴다 (유창성 제외, D8). 서버 점수 0.6·정확도 + 0.25·또렷함 + 0.15·유창성 에서 0.15 몫을 빼고 0.85 로 나눈다.
const W_ACCURACY := 0.6
const W_CLARITY := 0.25
const W_SUM := 0.85

const LEVEL_RANK := {"hard": 0, "mid": 1, "easy": 2}

## 빈칸으로 만들지 않는 영어 단어 (문법어 · 대명사 · 추임새). 소문자, 아포스트로피는 ' 로 통일.
const EN_STOP := {
	"the": 1, "and": 1, "but": 1, "for": 1, "nor": 1, "yet": 1, "are": 1, "was": 1, "were": 1, "been": 1, "being": 1,
	"you": 1, "your": 1, "yours": 1, "she": 1, "her": 1, "hers": 1, "him": 1, "his": 1, "its": 1, "our": 1, "ours": 1,
	"they": 1, "them": 1, "their": 1, "theirs": 1, "who": 1, "whom": 1, "whose": 1, "what": 1, "which": 1, "when": 1,
	"where": 1, "why": 1, "how": 1, "this": 1, "that": 1, "these": 1, "those": 1, "there": 1, "here": 1, "then": 1,
	"than": 1, "with": 1, "without": 1, "within": 1, "from": 1, "into": 1, "onto": 1, "upon": 1, "over": 1, "under": 1,
	"about": 1, "above": 1, "below": 1, "after": 1, "before": 1, "between": 1, "through": 1, "during": 1, "off": 1,
	"out": 1, "any": 1, "all": 1, "some": 1, "each": 1, "every": 1, "both": 1, "either": 1, "neither": 1, "such": 1,
	"only": 1, "own": 1, "same": 1, "too": 1, "very": 1, "can": 1, "could": 1, "will": 1, "would": 1, "shall": 1,
	"should": 1, "may": 1, "might": 1, "must": 1, "have": 1, "has": 1, "had": 1, "having": 1, "does": 1, "did": 1,
	"doing": 1, "done": 1, "not": 1, "now": 1, "just": 1, "also": 1, "again": 1, "ever": 1, "never": 1, "once": 1,
	"yeah": 1, "yes": 1, "yep": 1, "nope": 1, "ooh": 1, "oooh": 1, "ohh": 1, "aah": 1, "hey": 1, "hmm": 1, "uh": 1,
	"huh": 1, "gonna": 1, "wanna": 1, "gotta": 1, "cause": 1, "'cause": 1, "til": 1, "till": 1,
	"i'm": 1, "i've": 1, "i'll": 1, "i'd": 1, "you're": 1, "you've": 1, "you'll": 1, "you'd": 1, "he's": 1, "she's": 1,
	"it's": 1, "we're": 1, "we've": 1, "we'll": 1, "we'd": 1, "they're": 1, "they've": 1, "they'll": 1, "they'd": 1,
	"that's": 1, "there's": 1, "here's": 1, "what's": 1, "let's": 1, "don't": 1, "doesn't": 1, "didn't": 1, "can't": 1,
	"won't": 1, "isn't": 1, "aren't": 1, "wasn't": 1, "weren't": 1, "couldn't": 1, "wouldn't": 1, "shouldn't": 1,
	"haven't": 1, "hasn't": 1, "hadn't": 1, "ain't": 1, "cannot": 1,
}


# ---------------------------------------------------------------- 공통 도우미

static func _lang_of(song: Variant) -> String:
	if song is Dictionary:
		var l: String = str((song as Dictionary).get("lang", ""))
		if l == "en" or l == "ja":
			return l
	return ""


static func _lines(song: Variant) -> Array:
	if song is Dictionary:
		var ls: Variant = (song as Dictionary).get("lines", null)
		if ls is Array:
			return ls
	return []


static func _line(song: Variant, i: int) -> Dictionary:
	var ls: Array = _lines(song)
	if i < 0 or i >= ls.size() or not (ls[i] is Dictionary):
		return {}
	return ls[i]


static func _words(line: Dictionary) -> Array:
	var ws: Variant = line.get("words", null)
	return ws if ws is Array else []


## 제어문자(줄바꿈 · 탭 포함)는 공백으로, 앞뒤 공백 제거, 길이 제한.
static func _clean(v: Variant, max_len: int) -> String:
	var s: String = str(v) if (v is String or v is int or v is float) else ""
	var out := ""
	for i in s.length():
		var c: int = s.unicode_at(i)
		out += " " if (c < 32 or c == 127) else s[i]
	return out.strip_edges().left(max_len)


static func _norm_apos(s: String) -> String:
	return s.replace("’", "'").replace("‘", "'").replace("`", "'")


static func _word_key(wd: Dictionary) -> String:
	var lem: String = str(wd.get("lemma", "")).strip_edges()
	if lem == "":
		lem = str(wd.get("w", "")).strip_edges()
	return lem.to_lower() if _is_latin(lem) else lem


static func _is_latin(s: String) -> bool:
	for i in s.length():
		if s.unicode_at(i) > 0x24F:
			return false
	return true


static func _alpha_count(s: String) -> int:
	var n := 0
	for i in s.length():
		var ch: String = s[i]
		if ch.to_lower() != ch.to_upper():
			n += 1
	return n


static func _is_hiragana(ch: String) -> bool:
	var c: int = ch.unicode_at(0)
	return c >= 0x3040 and c <= 0x309F


## 단어가 빈칸/모르는 단어 후보가 될 수 있나 (known 은 따로 본다).
static func _content_word(wd: Dictionary, lang: String) -> bool:
	if wd.get("content", true) == false:
		return false
	var w: String = str(wd.get("w", "")).strip_edges()
	if w == "":
		return false
	if lang == "en":
		if _alpha_count(w) < 3:
			return false
		var lw: String = _norm_apos(w).to_lower()
		if EN_STOP.has(lw) or EN_STOP.has(_word_key(wd)):
			return false
		return true
	var has_body := false
	for i in w.length():
		if TextSim.JA_SKIP.find(w[i]) == -1:
			has_body = true
			break
	if not has_body:
		return false
	if w.length() == 1 and _is_hiragana(w):
		return false # 조사 한 글자(が, を, に ...)
	return true


static func _is_known(wd: Dictionary, known: Dictionary) -> bool:
	if known.is_empty():
		return false
	var lem: String = str(wd.get("lemma", "")).strip_edges()
	var w: String = str(wd.get("w", "")).strip_edges()
	for k in [lem, lem.to_lower(), w, w.to_lower()]:
		if str(k) != "" and known.has(str(k)):
			return true
	return false


# ---------------------------------------------------------------- 빈칸

static func _is_word_char(ch: String) -> bool:
	return ch.to_lower() != ch.to_upper() or ch.is_valid_int()


## text 안에서 from 이후 w 가 나오는 자리. 영어는 다른 단어 한가운데(it 가 sit 안)는 건너뛴다. 못 찾으면 -1.
static func _find_word(text: String, w: String, from: int, lang: String) -> int:
	var p: int = text.findn(w, from)
	while p >= 0:
		if lang != "en":
			return p
		var before: String = text[p - 1] if p > 0 else ""
		var after_i: int = p + w.length()
		var after: String = text[after_i] if after_i < text.length() else ""
		var after2: String = text[after_i + 1] if after_i + 1 < text.length() else ""
		var bad := false
		if before != "" and _is_word_char(before):
			bad = true
		if after != "" and _is_word_char(after):
			bad = true
		if after != "" and (after == "'" or after == "’") and after2 != "" and _is_word_char(after2):
			bad = true # I 가 I'm 안에 있는 경우
		if before != "" and (before == "'" or before == "’") and p >= 2 and _is_word_char(text[p - 2]):
			bad = true
		if not bad:
			return p
		p = text.findn(w, p + 1)
	return -1


## 줄 글자 안에서 words[] 각 단어의 자리: [{k: words 번호, start, len, text: 원문 글자}] (찾은 것만, 순서대로).
static func _spans(line: Dictionary, lang: String) -> Array:
	var text: String = str(line.get("text", ""))
	var out: Array = []
	var cursor := 0
	var ws: Array = _words(line)
	for k in ws.size():
		if not (ws[k] is Dictionary):
			continue
		var w: String = str((ws[k] as Dictionary).get("w", "")).strip_edges()
		if w == "":
			continue
		var pos: int = _find_word(text, w, cursor, lang)
		if pos < 0:
			continue
		out.append({"k": k, "start": pos, "len": w.length(), "text": text.substr(pos, w.length())})
		cursor = pos + w.length()
	return out


static func _unique(items: Array, skip: String) -> Array:
	var seen := {}
	var out: Array = []
	for it in items:
		var s: String = str(it)
		if s == "" or s == skip or seen.has(s):
			continue
		seen[s] = true
		out.append(s)
	return out


## 영어 정답의 다른 표기: 대소문자 · 곧은/굽은 아포스트로피 · 아포스트로피 없음.
static func en_alts(answer: String) -> Array:
	var straight: String = _norm_apos(answer)
	var curly: String = straight.replace("'", "’")
	var forms: Array = [answer, straight, curly, straight.replace("'", "")]
	var all: Array = []
	for f in forms:
		var s: String = str(f)
		all.append(s)
		all.append(s.to_lower())
		all.append(s.substr(0, 1).to_upper() + s.substr(1).to_lower())
		all.append(s.to_upper())
	return _unique(all, answer)


static func _seed_for(seed_in: int, line_i: int, level: int) -> int:
	return (seed_in * 1000003 + line_i * 7919 + level * 104729) & 0x7FFFFFFFFFFF


static func _shuffle(arr: Array, rng: RandomNumberGenerator) -> void:
	for i in range(arr.size() - 1, 0, -1):
		var j: int = rng.randi_range(0, i)
		var t: Variant = arr[i]
		arr[i] = arr[j]
		arr[j] = t


## 이 줄의 빈칸을 만든다. level 1/2/3 = 빈칸 1/2/3개 (후보가 모자라면 가능한 만큼).
## known = {lemma: true} (Store.known_set(lang)): 아는 단어는 빈칸으로 만들지 않는다.
## -> {prompt, blanks: [{idx (words 번호), start, answer, alts, options, reading}], ok, level, line}
static func cloze(song: Variant, line_i: int, level: int, seed: int, known: Dictionary = {}) -> Dictionary:
	var lvl: int = clampi(level, MIN_LEVEL, MAX_LEVEL)
	var res := {"prompt": "", "blanks": [], "ok": false, "level": lvl, "line": line_i}
	var lang: String = _lang_of(song)
	var line: Dictionary = _line(song, line_i)
	if lang == "" or line.is_empty():
		return res
	var text: String = str(line.get("text", ""))
	res["prompt"] = text
	var ws: Array = _words(line)
	var cands: Array = []
	for sp in _spans(line, lang):
		var wd: Dictionary = ws[int((sp as Dictionary)["k"])]
		if _content_word(wd, lang) and not _is_known(wd, known):
			cands.append(sp)
	if cands.is_empty():
		return res
	var rng := RandomNumberGenerator.new()
	rng.seed = _seed_for(seed, line_i, lvl)
	var order: Array = range(cands.size())
	_shuffle(order, rng)
	var chosen: Array = []
	for n in mini(lvl, order.size()):
		chosen.append(cands[int(order[n])])
	chosen.sort_custom(_cmp_start)

	var pool: Array = _distractor_pool(song, lang)
	var blanks: Array = []
	var prompt := ""
	var cur := 0
	for sp in chosen:
		var d: Dictionary = sp
		var wd2: Dictionary = ws[int(d["k"])]
		var ans: String = str(d["text"])
		var rd: String = str(wd2.get("reading", "")).strip_edges() if lang == "ja" else ""
		var alts: Array = en_alts(ans) if lang == "en" else _unique([rd], ans)
		blanks.append({
			"idx": int(d["k"]), "start": int(d["start"]), "answer": ans, "alts": alts,
			"options": _options(ans, pool, rng), "reading": rd,
		})
		prompt += text.substr(cur, int(d["start"]) - cur) + BLANK
		cur = int(d["start"]) + int(d["len"])
	prompt += text.substr(cur)
	res["prompt"] = prompt
	res["blanks"] = blanks
	res["ok"] = not blanks.is_empty()
	return res


## 곡 전체의 내용어 (보기 오답 후보). 표기가 같은 것은 한 번만.
static func _distractor_pool(song: Variant, lang: String) -> Array:
	var seen := {}
	var out: Array = []
	for ln in _lines(song):
		if not (ln is Dictionary):
			continue
		for wd in _words(ln as Dictionary):
			if not (wd is Dictionary) or not _content_word(wd as Dictionary, lang):
				continue
			var w: String = str((wd as Dictionary).get("w", "")).strip_edges()
			var k: String = w.to_lower()
			if not seen.has(k):
				seen[k] = true
				out.append(w)
	return out


static func _options(answer: String, pool: Array, rng: RandomNumberGenerator) -> Array:
	var others: Array = []
	for w in pool:
		if str(w).to_lower() != answer.to_lower():
			others.append(w)
	_shuffle(others, rng)
	var opts: Array = [answer]
	for w in others:
		if opts.size() >= OPTION_COUNT:
			break
		opts.append(w)
	_shuffle(opts, rng)
	return opts


## 빈칸 하나의 답을 확인한다. -> {ok, score}
## 영어: 대소문자 · ' 모양 · 앞뒤 문장부호 무시, 정답이나 alts 와 같으면 정답.
## 일본어: TextSim.similarity 를 표기(한자)와 reading(히라가나) 둘 다에 대해 재서 높은 쪽이 JA_BLANK_PASS 이상이면 정답.
static func check_blank(lang: String, blank: Variant, said: Variant) -> Dictionary:
	var s: String = str(said) if (said is String) else ""
	if not (blank is Dictionary) or s.strip_edges() == "":
		return {"ok": false, "score": 0}
	var b: Dictionary = blank
	var answer: String = str(b.get("answer", ""))
	if answer == "":
		return {"ok": false, "score": 0}
	if lang == "ja":
		var sim: Dictionary = TextSim.similarity(s, answer, str(b.get("reading", "")), "ja")
		var sc: int = int(sim.get("score", 0))
		return {"ok": sc >= JA_BLANK_PASS, "score": sc}
	var want: Array = [answer]
	var alts: Variant = b.get("alts", [])
	if alts is Array:
		want.append_array(alts)
	var got: String = _en_norm(s)
	if got == "":
		return {"ok": false, "score": 0}
	for a in want:
		var n: String = _en_norm(str(a))
		if n != "" and (n == got or n.replace("'", "") == got.replace("'", "")):
			return {"ok": true, "score": 100}
	return {"ok": false, "score": 0}


static func _en_norm(s: String) -> String:
	var t: String = _norm_apos(s).strip_edges().to_lower()
	var a := 0
	var z: int = t.length()
	while a < z and not _is_word_char(t[a]):
		a += 1
	while z > a and not _is_word_char(t[z - 1]):
		z -= 1
	return t.substr(a, z - a)


# ---------------------------------------------------------------- 모르는 단어

## 모르는 단어 후보 (lemma 별 한 번). known = {lemma: true}.
## 어려운 단어(level hard > mid > easy, zipf 낮은 순) 먼저, 같으면 곡에 나온 순서. limit <= 0 이면 빈 배열.
## -> [{lemma, w, level, zipf, count, line_i, reading, ko}]
static func pick_unknown(song: Variant, known: Dictionary, limit: int) -> Array:
	var lang: String = _lang_of(song)
	if lang == "" or limit <= 0:
		return []
	var gloss: Dictionary = {}
	if (song as Dictionary).get("glossary", null) is Dictionary:
		gloss = (song as Dictionary)["glossary"]
	var by_key: Dictionary = {}
	var order: Array = []
	var li := -1
	for ln in _lines(song):
		li += 1
		if not (ln is Dictionary):
			continue
		for wd in _words(ln as Dictionary):
			if not (wd is Dictionary):
				continue
			var d: Dictionary = wd
			if not _content_word(d, lang) or _is_known(d, known):
				continue
			var key: String = _word_key(d)
			if key == "":
				continue
			if by_key.has(key):
				by_key[key]["count"] = int(by_key[key]["count"]) + 1
				continue
			var lem: String = str(d.get("lemma", "")).strip_edges()
			if lem == "":
				lem = str(d.get("w", "")).strip_edges()
			var g: Dictionary = _gloss_of(gloss, lem, str(d.get("w", "")))
			var lv: String = str(d.get("level", "mid"))
			var zv: Variant = d.get("zipf", null)
			var ent := {
				"lemma": lem, "w": str(d.get("w", "")).strip_edges(), "level": lv if LEVEL_RANK.has(lv) else "mid",
				"zipf": float(zv) if (zv is float or zv is int) else 3.5, "count": 1, "line_i": li,
				"reading": _word_reading(d, g, lang), "ko": _clean(g.get("ko", ""), TEXT_MAX), "_o": order.size(),
			}
			by_key[key] = ent
			order.append(ent)
	order.sort_custom(_cmp_unknown)
	var out: Array = []
	for e in order:
		if out.size() >= mini(limit, MAX_PICK):
			break
		(e as Dictionary).erase("_o")
		out.append(e)
	return out


static func _cmp_start(a: Dictionary, b: Dictionary) -> bool:
	return int(a["start"]) < int(b["start"])


static func _cmp_unknown(a: Dictionary, b: Dictionary) -> bool:
	var ra: int = int(LEVEL_RANK[a["level"]])
	var rb: int = int(LEVEL_RANK[b["level"]])
	if ra != rb:
		return ra < rb
	if not is_equal_approx(float(a["zipf"]), float(b["zipf"])):
		return float(a["zipf"]) < float(b["zipf"])
	return int(a["_o"]) < int(b["_o"])


static func _gloss_of(gloss: Dictionary, lemma: String, w: String) -> Dictionary:
	for k in [lemma, lemma.to_lower(), w, w.to_lower()]:
		if gloss.has(str(k)) and gloss[str(k)] is Dictionary:
			return gloss[str(k)]
	return {}


static func _word_reading(wd: Dictionary, g: Dictionary, lang: String) -> String:
	if lang == "ja":
		var r: String = str(wd.get("reading", "")).strip_edges()
		if r == "":
			r = str(g.get("reading", "")).strip_edges()
		return _clean(r, TEXT_MAX)
	return _clean(g.get("ipa", ""), TEXT_MAX)


# ---------------------------------------------------------------- 복습 카드 (Store.add_review 항목)

static func _title_of(song: Dictionary) -> String:
	var t: String = _clean(song.get("title", ""), TITLE_MAX)
	return t if t != "" else "제목 없음"


## "♪ 제목 – 가수" (줄 카드 note)
static func _song_note(song: Dictionary) -> String:
	var artist: String = _clean(song.get("artist", ""), TITLE_MAX)
	var s: String = NOTE_MARK + _title_of(song)
	if artist != "":
		s += " – " + artist
	return s.left(TEXT_MAX)


## 줄 카드: {lang, target: 줄 원문(<=300), reading: 일본어 히라가나, ko, note}. 줄이 없거나 글자가 비면 {}.
static func line_card(song: Variant, line_i: int) -> Dictionary:
	var lang: String = _lang_of(song)
	var line: Dictionary = _line(song, line_i)
	if lang == "" or line.is_empty():
		return {}
	var target: String = _clean(line.get("text", ""), TEXT_MAX)
	if target == "":
		return {}
	return {
		"lang": lang,
		"target": target,
		"reading": _clean(line.get("reading", ""), TEXT_MAX) if lang == "ja" else "",
		"ko": _clean(line.get("ko", ""), TEXT_MAX),
		"note": _song_note(song as Dictionary),
	}


## 단어 카드: {lang, target: lemma(없으면 표면형), reading: 영어 IPA / 일본어 히라가나, ko: 뜻, note: ♪ 제목 · "줄 앞 40자…"}.
## 일본어 활용형(咲いた, lemma 咲く)은 target 과 reading 이 어긋나지 않게 표면형으로 만든다 (용어집에 기본형 reading 이 있으면 기본형).
## lemma 가 곡에 없으면 {}.
static func word_card(song: Variant, lemma: String) -> Dictionary:
	var lang: String = _lang_of(song)
	var want: String = lemma.strip_edges()
	if lang == "" or want == "":
		return {}
	var gloss: Dictionary = {}
	if (song as Dictionary).get("glossary", null) is Dictionary:
		gloss = (song as Dictionary)["glossary"]
	var wl: String = want.to_lower()
	var li := -1
	for ln in _lines(song):
		li += 1
		if not (ln is Dictionary):
			continue
		for wd in _words(ln as Dictionary):
			if not (wd is Dictionary):
				continue
			var d: Dictionary = wd
			var lem: String = str(d.get("lemma", "")).strip_edges()
			var w: String = str(d.get("w", "")).strip_edges()
			if not (lem == want or w == want or (lem != "" and lem.to_lower() == wl) or w.to_lower() == wl):
				continue
			var g: Dictionary = _gloss_of(gloss, lem, w)
			var target: String = _clean(lem if lem != "" else w, TEXT_MAX)
			var reading: String = _word_reading(d, g, lang)
			if lang == "ja":
				# 읽기는 줄에 나온 표면형(w)의 것이다. 용언 활용형(咲いた)이면 기본형(咲く) 대신 표면형을 카드로 만들어
				# target 과 reading 이 어긋나지 않게 한다 (용어집에 기본형 읽기가 있으면 기본형을 쓴다).
				var gr: String = _clean(g.get("reading", ""), TEXT_MAX)
				if gr != "":
					reading = gr
				elif lem != "" and lem != w and w != "":
					target = _clean(w, TEXT_MAX)
			if target == "":
				continue
			var text: String = _clean((ln as Dictionary).get("text", ""), 2000)
			var snip: String = text.left(SNIPPET_MAX) + ("…" if text.length() > SNIPPET_MAX else "")
			var note: String = NOTE_MARK + _title_of(song as Dictionary)
			if snip != "":
				note += " · \"%s\"" % snip
			return {
				"lang": lang,
				"target": target,
				"reading": reading,
				"ko": _clean(g.get("ko", ""), TEXT_MAX),
				"note": note.left(TEXT_MAX),
			}
	return {}


## 카드 항목들을 복습 카드로 넣는다 (Store.add_review). 저장(Store.save_progress)은 부르는 쪽이 한다.
## -> {added, skipped (이미 있거나 못 쓰는 항목), trimmed (한도 3000 을 넘어 밀려난 오래된 카드 수), total}
static func add_cards(items: Array) -> Dictionary:
	var valid: Array = []
	for it in items:
		if it is Dictionary and not (it as Dictionary).is_empty():
			valid.append(it)
	var before: int = (Store.progress["review"] as Array).size()
	var added: int = Store.add_review(valid)
	var total: int = (Store.progress["review"] as Array).size()
	return {"added": added, "skipped": items.size() - added, "trimmed": maxi(0, before + added - total), "total": total}


# ---------------------------------------------------------------- 받아쓰기 · 노래 점수

## 받아쓰기 한 줄 채점. line = 곡의 줄(Dictionary: text, reading) 또는 정답 글자(String).
## 영어: DictationDiff.diff(said, text) 그대로. 일본어: TextSim.similarity(said, text, reading, "ja") (빈 입력은 0점).
static func dictation_score(lang: String, said: Variant, line: Variant) -> Dictionary:
	var s: String = str(said) if (said is String) else ""
	var text := ""
	var reading := ""
	if line is Dictionary:
		text = str((line as Dictionary).get("text", ""))
		reading = str((line as Dictionary).get("reading", ""))
	elif line is String:
		text = line
	if lang == "ja":
		if s.strip_edges() == "" or text.strip_edges() == "":
			return {"score": 0, "toks": PackedStringArray(), "hit": []}
		return TextSim.similarity(s, text, reading, "ja")
	return DictationDiff.diff(s, text)


static func _pct(v: Variant) -> float:
	if v is int or v is float:
		var f: float = float(v)
		if is_finite(f):
			return clampf(f, 0.0, 100.0)
	return 0.0


## 노래 점수 0~100 = round((0.6·정확도 + 0.25·또렷함) / 0.85). 키 누락 · 음수 · 문자열 · NaN 은 0 (또는 0~100 으로 보정).
static func song_score(res: Variant) -> int:
	if not (res is Dictionary):
		return 0
	var r: Dictionary = res
	var raw: float = (W_ACCURACY * _pct(r.get("accuracy", null)) + W_CLARITY * _pct(r.get("clarity", null))) / W_SUM
	return clampi(roundi(raw), 0, 100)
