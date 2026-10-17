class_name DictationDiff
extends RefCounted
## 받아쓰기 채점 (순수 함수). 대소문자·문장부호를 무시하고, 축약형(I'd = I would)을 풀어서
## 단어 단위 LCS 로 정답과 비교한다.
##
## diff(said, target) -> {
##   score: int (0-100),
##   words: [{w: 정답 단어(원문 대소문자), ok: bool, kind: "ok"|"missing"|"typo", said: 철자가 틀리게 쓴 단어(typo 일 때)}],
##   extra: [정답에 없는데 쓴 단어(원문)]
## }

const MAX_LEN := 300
const MAX_TARGET_LEN := 600

## 철자 한 번 틀린 단어(편집 거리 1, 4글자 이상)에 주는 부분 점수. 문장에서 첫 번째 한 단어에만 준다.
const TYPO_CREDIT := 0.75
## 통과를 막는 "진짜 틀림" 기준: 빠진 단어 + 정답에 없는 단어 + 부분 점수 못 받은 철자 오류가 이 개수 이상이면 84점 이하.
const HARD_ERRORS := 2
const HARD_CAP := 84

## "he's" 처럼 소유격과 헷갈리는 's 는 이 대명사·의문사 뒤에서만 "is/has" 로 푼다.
## 그 밖의 단어(Tom's, Everyone's)는 표기 그대로도, is/has 로 푼 것도 정답으로 본다.
const S_IS := ["it", "he", "she", "that", "what", "there", "here", "where", "who", "how", "when", "why"]

const FIXED := {
	"cannot": ["can", "not"],
	"can't": ["can", "not"],
	"won't": ["will", "not"],
	"shan't": ["shall", "not"],
	"let's": ["let", "us"],
	"gonna": ["going", "to"],
	"wanna": ["want", "to"],
	"gotta": ["got", "to"],
	"kinda": ["kind", "of"],
	"sorta": ["sort", "of"],
	"lemme": ["let", "me"],
	"gimme": ["give", "me"],
	"dunno": ["do", "not", "know"],
	"alright": ["all", "right"],
}

## 아포스트로피 없이 쓴 축약형 중 다른 단어와 겹치지 않는 것 -> 아포스트로피 있는 표기.
## (ill, well, were, id, its, lets, wed, shed, hell 처럼 다른 단어와 겹치는 것은 여기 없다.
##  정답에 그 축약형이 있을 때만 `diff` 가 같은 단어로 인정한다.)
const NOAPOS := {
	"im": "i'm", "ive": "i've", "dont": "don't", "doesnt": "doesn't", "didnt": "didn't",
	"cant": "can't", "wont": "won't", "isnt": "isn't", "arent": "aren't", "wasnt": "wasn't",
	"werent": "weren't", "hasnt": "hasn't", "havent": "haven't", "hadnt": "hadn't",
	"wouldnt": "wouldn't", "couldnt": "couldn't", "shouldnt": "shouldn't", "mustnt": "mustn't",
	"neednt": "needn't", "aint": "ain't", "shant": "shan't",
	"youre": "you're", "youve": "you've", "youll": "you'll", "youd": "you'd",
	"theyre": "they're", "theyve": "they've", "theyll": "they'll", "theyd": "they'd",
	"weve": "we've", "thats": "that's", "whats": "what's", "hes": "he's", "shes": "she's",
	"theres": "there's", "heres": "here's", "wheres": "where's", "whos": "who's", "hows": "how's",
	"itll": "it'll", "itd": "it'd", "thatll": "that'll", "whatll": "what'll", "oclock": "o'clock",
}

## 같은 단어의 표기 변형 -> 대표 표기 (영국식/미국식, OK).
const CANON := {
	"ok": "okay", "colour": "color", "favourite": "favorite", "neighbour": "neighbor",
	"grey": "gray", "theatre": "theater", "centre": "center", "realise": "realize",
	"organise": "organize", "travelling": "traveling", "programme": "program", "mum": "mom",
}

const NEGATIONS := ["not", "no", "never"]
const ONES := ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve",
	"thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen"]
const TENS := ["", "", "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety"]
const ORDINALS := {"1st": "first", "2nd": "second", "3rd": "third", "4th": "fourth", "5th": "fifth", "6th": "sixth",
	"7th": "seventh", "8th": "eighth", "9th": "ninth", "10th": "tenth", "11th": "eleventh", "12th": "twelfth"}
## 철자 부분 점수에서 "이미 있는 다른 단어" 를 거르는 단어 목록 (한 줄에 하나). 없으면 거르지 않는다.
const COMMON_WORDS_PATH := "res://data/common_en_words.txt"
## 단어 끝에 붙는 활용 어미: 이것만 다르면 철자 실수가 아니라 다른 단어다 (apple/apples, walk/walked).
const INFLECTIONS := ["s", "es", "ed", "d", "ing"]
const AIN_T_BASES := ["is", "am", "are", "has", "have"]

static var _word_rx: RegEx = null
static var _ok_rx: RegEx = null
static var _common: Dictionary = {}
static var _common_loaded: bool = false


## 정답/입력 문장을 단어로 쪼갠다. 각 항목 {w: 표시용 원문, toks: PackedStringArray (풀어쓴 소문자, 대표형),
## alts: [PackedStringArray, ...] (인정되는 모든 풀이, alts[0] == toks)}.
static func split_words(s: String, max_len: int = MAX_LEN) -> Array:
	if _word_rx == null:
		_word_rx = RegEx.new()
		_word_rx.compile("[^A-Za-z0-9'À-ÖØ-öø-ÿ]+")
		_ok_rx = RegEx.new()
		_ok_rx.compile("(?i)(?<![A-Za-z])o\\.k\\.?(?![A-Za-z])")
	var t: String = s.left(max_len).replace("’", "'").replace("‘", "'").replace("`", "'")
	t = _ok_rx.sub(t, " okay ", true)
	t = _word_rx.sub(t, " ", true)
	var out: Array = []
	for piece in t.split(" ", false):
		var w: String = String(piece).lstrip("'").rstrip("'")
		if w == "":
			continue
		var alts: Array = alternatives(w.to_lower())
		out.append({"w": w, "toks": alts[0], "alts": alts})
	return out


## 소문자 단어 하나를 비교용 토큰으로 푼다. "i'd" -> [i, would], "don't" -> [do, not].
static func expand(word: String) -> PackedStringArray:
	return alternatives(word)[0]


static func _pa(items: Array) -> PackedStringArray:
	var out := PackedStringArray()
	for it in items:
		out.append(str(it))
	return out


## 소문자 단어 하나가 가질 수 있는 풀이들 (첫 번째가 대표). 같은 뜻으로 인정하는 표기를 모두 담는다.
static func alternatives(word: String) -> Array:
	var w: String = word
	if NOAPOS.has(w):
		w = str(NOAPOS[w])
	var res: Array = []
	if ORDINALS.has(w):
		res.append(_pa([ORDINALS[w]]))
	elif w.length() <= 3 and w.is_valid_int() and str(int(w)) == w and int(w) <= 100:
		res.append(_pa(_number_words(int(w))))
	elif FIXED.has(w):
		res.append(_pa(FIXED[w]))
	elif w == "ain't":
		for b in AIN_T_BASES: # am/is/are/has/have not 중 어느 것으로 풀어 썼든 인정
			res.append(_pa([b, "not"]))
	elif w.ends_with("n't") and w.length() > 3:
		res.append(_pa([w.left(w.length() - 3), "not"]))
	elif w.find("'") > 0:
		var q: int = w.find("'")
		var base: String = w.left(q)
		var suf: String = w.substr(q)
		match suf:
			"'m":
				res.append(_pa([base, "am"]))
			"'re":
				res.append(_pa([base, "are"]))
			"'ve":
				res.append(_pa([base, "have"]))
			"'ll":
				res.append(_pa([base, "will"]))
			"'d":
				res.append(_pa([base, "would"]))
				res.append(_pa([base, "had"])) # I'd better = I had better
			"'s":
				if not S_IS.has(base):
					res.append(_pa([w])) # 소유격일 수 있으니 표기 그대로가 대표
					res.append(_pa([base + "s"]))
				res.append(_pa([base, "is"]))
				res.append(_pa([base, "has"]))
		if res.is_empty():
			res.append(_pa([w]))
			res.append(_pa([w.replace("'", "")])) # o'clock = oclock
	else:
		res.append(_pa([w]))
	for a in res:
		var pa: PackedStringArray = a
		for k in pa.size():
			if CANON.has(pa[k]):
				pa[k] = str(CANON[pa[k]])
	return res


static func _number_words(n: int) -> Array:
	if n < 20:
		return [ONES[n]]
	if n == 100:
		return ["one", "hundred"]
	var out: Array = [TENS[n / 10]]
	if n % 10 != 0:
		out.append(ONES[n % 10])
	return out


## 흔한 영어 단어 목록 (처음 쓸 때 한 번만 읽는다). 파일이 없으면 비어 있어서 예전처럼 동작한다.
static func is_common_word(w: String) -> bool:
	if not _common_loaded:
		_common_loaded = true
		if FileAccess.file_exists(COMMON_WORDS_PATH):
			var f: FileAccess = FileAccess.open(COMMON_WORDS_PATH, FileAccess.READ)
			if f != null:
				for line in f.get_as_text().split("
", false):
					var t: String = String(line).strip_edges()
					if t != "":
						_common[t] = true
	return _common.has(w)


## 어미(-s, -es, -ed, -d, -ing)만 다른 두 단어인가.
static func _only_inflection_differs(a: String, b: String) -> bool:
	for suf in INFLECTIONS:
		if (a.length() > b.length() and a == b + suf) or (b.length() > a.length() and b == a + suf):
			return true
	return false


static func _contains_seq(hay: PackedStringArray, needle: PackedStringArray) -> bool:
	var n: int = needle.size()
	if n == 0 or hay.size() < n:
		return false
	for i in range(hay.size() - n + 1):
		var hit := true
		for k in n:
			if hay[i + k] != needle[k]:
				hit = false
				break
		if hit:
			return true
	return false


## alts 중 상대 문장(토큰열)에 그대로 나오는 첫 번째 풀이. 없으면 대표 풀이.
static func _pick(alts: Array, other: PackedStringArray) -> PackedStringArray:
	if alts.size() > 1:
		for a in alts:
			if _contains_seq(other, a):
				return a
	return alts[0]


static func _flatten(words: Array) -> Dictionary:
	var toks := PackedStringArray()
	var owner: Array = []
	for i in words.size():
		for t in (words[i] as Dictionary)["toks"]:
			toks.append(t)
			owner.append(i)
	return {"toks": toks, "owner": owner}


## 편집 거리 (삽입·삭제·바꿈, 이웃한 두 글자 맞바꿈도 1).
static func _lev(a: String, b: String) -> int:
	var n: int = a.length()
	var m: int = b.length()
	if n == 0:
		return m
	if m == 0:
		return n
	var rows: Array = []
	for i in n + 1:
		var row := PackedInt32Array()
		row.resize(m + 1)
		rows.append(row)
	for j in m + 1:
		rows[0][j] = j
	for i in range(1, n + 1):
		rows[i][0] = i
		for j in range(1, m + 1):
			var cost: int = 0 if a[i - 1] == b[j - 1] else 1
			var v: int = mini(mini(rows[i - 1][j] + 1, rows[i][j - 1] + 1), rows[i - 1][j - 1] + cost)
			if i > 1 and j > 1 and a[i - 1] == b[j - 2] and a[i - 2] == b[j - 1]:
				v = mini(v, rows[i - 2][j - 2] + 1)
			rows[i][j] = v
	return rows[n][m]


## 한 글자만 다른 두 단어가 "한 글자 바꿈" 인가 (글자 빠짐·끼움·맞바꿈이 아니라).
static func _is_substitution(said: String, want: String) -> bool:
	if said.length() != want.length():
		return false
	var diffs: int = 0
	for i in want.length():
		if said[i] != want[i]:
			diffs += 1
	return diffs == 1


## 철자가 비슷한가 (빠진 단어가 아니라 철자가 틀린 것으로 볼 만한가).
## 한 글자를 다른 글자로 바꾼 것은 타자 실수로 보이는 경우(5글자 이상, 첫 글자 같음)만 철자 틀림이다.
## walk/talk, want/went, cat/cut 은 다른 단어다.
static func _similar(said: String, want: String) -> bool:
	if said == want or want.length() < 4: # 3글자 이하 단어(he/she, cat/cut)는 한 글자 차이도 다른 단어다
		return false
	if is_common_word(said) or _only_inflection_differs(said, want):
		return false # 입력한 것이 그 자체로 있는 단어(price/prize, house/horse)거나 어미만 다르면 듣기 실수다
	var d: int = _lev(said, want)
	if d == 1 and _is_substitution(said, want):
		return want.length() >= 5 and said[0] == want[0]
	return d <= maxi(1, want.length() / 3) and d < want.length()


## 4글자 이상 단어를 글자 하나 빠뜨림·끼움·맞바꿈으로(또는 조건을 만족하는 한 글자 바꿈으로) 틀린 사소한 실수 (부분 점수 대상).
static func _near(said: String, want: String) -> bool:
	return want.length() >= 4 and said != want and _lev(said, want) == 1 and _similar(said, want)


## LCS 로 두 토큰열을 맞춘다. {len, pairs: [[i, j], ...] (오름차순), a_hit, b_hit}
static func _align(a: PackedStringArray, b: PackedStringArray) -> Dictionary:
	var n: int = a.size()
	var m: int = b.size()
	var dp: Array = []
	for i in n + 1:
		var row := PackedInt32Array()
		row.resize(m + 1)
		dp.append(row)
	for i in range(n - 1, -1, -1):
		for j in range(m - 1, -1, -1):
			if a[i] == b[j]:
				dp[i][j] = dp[i + 1][j + 1] + 1
			else:
				dp[i][j] = maxi(dp[i + 1][j], dp[i][j + 1])
	var a_hit: Array = []
	a_hit.resize(n)
	a_hit.fill(false)
	var b_hit: Array = []
	b_hit.resize(m)
	b_hit.fill(false)
	var pairs: Array = []
	var i := 0
	var j := 0
	while i < n and j < m:
		if a[i] == b[j]:
			a_hit[i] = true
			b_hit[j] = true
			pairs.append([i, j])
			i += 1
			j += 1
		elif dp[i + 1][j] >= dp[i][j + 1]:
			i += 1
		else:
			j += 1
	return {"len": dp[0][0], "pairs": pairs, "a_hit": a_hit, "b_hit": b_hit}


## 입력 문장의 각 단어에서 인정되는 풀이를 고른다. 아포스트로피 없이 쓴 단어(ill, its, well, were, id, lets ...)는
## 정답에 그 축약형(I'll, it's, we'll ...)이 있을 때만 그 뜻으로 인정한다.
static func _resolve_said(sw: Array, tw: Array, t_primary: PackedStringArray) -> void:
	var by_plain: Dictionary = {} # 아포스트로피를 뺀 철자 -> 정답 속 축약형 단어들
	for t in tw:
		var tl: String = str((t as Dictionary)["w"]).to_lower()
		if tl.find("'") >= 0:
			var key: String = tl.replace("'", "")
			if not by_plain.has(key):
				by_plain[key] = []
			(by_plain[key] as Array).append(tl)
	for s in sw:
		var d: Dictionary = s
		var alts: Array = (d["alts"] as Array).duplicate()
		var wl: String = str(d["w"]).to_lower()
		if wl.find("'") < 0 and by_plain.has(wl):
			for tl in by_plain[wl]:
				for a in alternatives(str(tl)):
					alts.append(a)
		var pick: PackedStringArray = _pick(alts, t_primary)
		d["toks"] = pick


static func diff(said: String, target: String) -> Dictionary:
	var tw: Array = split_words(target, MAX_TARGET_LEN)
	var sw: Array = split_words(said, MAX_LEN)
	var words: Array = []
	for w in tw:
		words.append({"w": str((w as Dictionary)["w"]), "ok": false, "kind": "missing"})
	if tw.is_empty():
		return {"score": 0, "words": words, "extra": []}
	if sw.is_empty():
		return {"score": 0, "words": words, "extra": []}

	# 같은 뜻의 여러 표기(can't/cannot, I'd/I had, Tom's/Tom is, ill/I'll)는 상대 문장에 나온 쪽으로 맞춘다.
	var t_primary: PackedStringArray = (_flatten(tw)["toks"] as PackedStringArray)
	_resolve_said(sw, tw, t_primary)
	var s_flat: PackedStringArray = (_flatten(sw)["toks"] as PackedStringArray)
	for t in tw:
		var td: Dictionary = t
		td["toks"] = _pick(td["alts"], s_flat)

	var tf: Dictionary = _flatten(tw)
	var sf: Dictionary = _flatten(sw)
	var t_toks: PackedStringArray = tf["toks"]
	var s_toks: PackedStringArray = sf["toks"]
	if s_toks.is_empty() or t_toks.is_empty():
		return {"score": 0, "words": words, "extra": []}

	var al: Dictionary = _align(s_toks, t_toks)
	var s_hit: Array = al["a_hit"]
	var t_hit: Array = al["b_hit"]
	var t_typo: Dictionary = {} # target token index -> said token it was probably meant to be
	var s_paired: Dictionary = {}
	var partial_tj: int = -1 # 부분 점수를 받는 철자 오류 토큰 (문장에서 첫 번째 하나)

	# 맞은 토큰 사이 빈 칸마다, 철자가 비슷한 틀린 입력을 정답 토큰과 짝지어 "철자 틀림" 으로 본다.
	var pairs: Array = (al["pairs"] as Array).duplicate()
	pairs.push_front([-1, -1])
	pairs.append([s_toks.size(), t_toks.size()])
	for k in range(pairs.size() - 1):
		var p0: Array = pairs[k]
		var p1: Array = pairs[k + 1]
		var s_gap: Array = []
		for si in range(int(p0[0]) + 1, int(p1[0])):
			s_gap.append(si)
		for tj in range(int(p0[1]) + 1, int(p1[1])):
			for si in s_gap:
				if s_paired.has(si):
					continue
				if _similar(s_toks[si], t_toks[tj]):
					s_paired[si] = true
					t_typo[tj] = s_toks[si]
					if partial_tj < 0 and _near(s_toks[si], t_toks[tj]):
						partial_tj = tj
					break

	var t_owner: Array = tf["owner"]
	var word_ok: Array = []
	var word_typo: Dictionary = {}
	var unmatched: Array = [] # 단어별 못 맞힌 토큰 수
	for i in tw.size():
		word_ok.append(true)
		unmatched.append(0)
	for j in t_toks.size():
		var wi: int = int(t_owner[j])
		if not bool(t_hit[j]):
			word_ok[wi] = false
			unmatched[wi] = int(unmatched[wi]) + 1
			if t_typo.has(j) and not word_typo.has(wi):
				word_typo[wi] = t_typo[j]
	var errors: int = 0
	for i in tw.size():
		var d: Dictionary = words[i]
		d["ok"] = bool(word_ok[i])
		if bool(word_ok[i]):
			d["kind"] = "ok"
			continue
		if word_typo.has(i):
			d["kind"] = "typo"
			d["said"] = str(word_typo[i])
		# 부분 점수를 받는 철자 실수 하나뿐이면 오류로 세지 않는다.
		var forgiven: bool = partial_tj >= 0 and int(t_owner[partial_tj]) == i and int(unmatched[i]) == 1
		if not forgiven:
			errors += 1

	var s_owner: Array = sf["owner"]
	var extra: Array = []
	var seen := {}
	for j in s_toks.size():
		if bool(s_hit[j]) or s_paired.has(j):
			continue
		var wi: int = int(s_owner[j])
		if seen.has(wi):
			continue
		seen[wi] = true
		extra.append(str((sw[wi] as Dictionary)["w"]))
	errors += extra.size()
	# 부정어(not/no/never)가 빠지거나 더해지면 뜻이 반대가 되므로 곧바로 "진짜 틀림" 으로 본다.
	for j in t_toks.size():
		if not bool(t_hit[j]) and NEGATIONS.has(t_toks[j]):
			errors = maxi(errors, HARD_ERRORS)
	for j in s_toks.size():
		if not bool(s_hit[j]) and not s_paired.has(j) and NEGATIONS.has(s_toks[j]):
			errors = maxi(errors, HARD_ERRORS)

	var lcs: int = int(al["len"])
	var credit: float = float(lcs) + (TYPO_CREDIT if partial_tj >= 0 else 0.0)
	var score: int = roundi(200.0 * credit / float(s_toks.size() + t_toks.size()))
	if lcs < maxi(s_toks.size(), t_toks.size()):
		score = mini(score, 99) # 완전히 같지 않으면 100 이 나오지 않게
	if errors >= HARD_ERRORS:
		score = mini(score, HARD_CAP) # 단어 빠짐/틀림이 둘 이상이면 통과 기준(85)을 넘지 못한다
	return {"score": clampi(score, 0, 100), "words": words, "extra": extra}


## "I'd like a coffee." -> "I _ _ _ _" 처럼 각 단어의 첫 글자만 보여 주는 힌트.
static func first_letters(target: String) -> String:
	var parts: Array[String] = []
	for w in split_words(target, MAX_TARGET_LEN):
		var s: String = str((w as Dictionary)["w"])
		parts.append(s.left(1) + "_".repeat(maxi(0, s.length() - 1)))
	return "   ".join(parts)


static func word_count(target: String) -> int:
	return split_words(target, MAX_TARGET_LEN).size()
