class_name MemoMask
extends RefCounted
## 가사 외우기 "점점 가리기" 규칙 (설계 docs/lyrics_memorize_design.md §3.2, §3.3, §5.4). 순수 함수만 있다:
## 같은 입력 -> 같은 결과, 저장소·파일·네트워크·전역 상태를 건드리지 않는다.
##
## - units(text, lang): 가릴 수 있는 조각(단위). 영어 = DictationDiff.split_words 와 같은 단어, 일본어 = ja_split 덩어리.
## - stage_plan(n, fast): 단계별 가림 개수 [0, ..., n].
## - hide_order / hidden_flags: 줄 글자에서 정한 시드의 고정 순열. 앞 단계에서 가린 것은 다음 단계에서도 가려진다.
## - render(text, lang, hidden): 가린 단위를 BLANK 로 바꿔 그린 글자 (구두점·띄어쓰기 유지).
##
## 가리는 순서에 엔진 난수를 쓰지 않는다 (플랫폼·버전이 달라도 같은 결과여야 하므로 32비트 정수 연산만).

const BLANK := "____"
const MAX_TEXT := 600 ## DictationDiff.MAX_TARGET_LEN 과 같다 (이보다 긴 글자는 aligned:false)
const HIRA_SPLIT_AT := 5 ## 히라가나 덩어리가 이 글자 수 이상이면 앞에서부터 잘라 쓴다
const HIRA_CHUNK := 3
const MASK32 := 0xFFFFFFFF
const GOLDEN := 0x9E3779B9
const MUL1 := 0x85EBCA6B
const MUL2 := 0xC2B2AE35

const PCT_NORMAL := [0, 25, 50, 75, 100]
const PCT_FAST := [0, 50, 100]

# 일본어 글자 종류
const K_SEP := -1 ## 공백·구두점(TextSim.JA_SKIP): 덩어리를 끊는다, 단위에 넣지 않는다
const K_KANJI := 0
const K_HIRA := 1
const K_KATA := 2
const K_ALNUM := 3
const K_OTHER := 4 ## 그 밖의 글자 (한글·이모지 등): 자기 종류끼리만 이어진다. 단위에 들어가야 "전부 가림"에서 노출되지 않는다


# ------------------------------------------------------------ 단위 나누기

## lang 이 문자열 "ja" 인가 (다른 형식의 값이 와도 예외 없이 false).
static func is_ja(lang: Variant) -> bool:
	return lang is String and lang == "ja"


## {units: [{w: String, s: int, e: int}], aligned: bool}
## aligned:true  -> w == text.substr(s, e - s) (원문 위치 [s, e) 가 있다).
## aligned:false -> 영어에서 원문 위치를 믿을 수 없는 줄 ("o.k." 처럼 DictationDiff 가 특수 처리하는 글자, 600자 초과).
##                  단위는 DictationDiff.split_words 의 단어 목록이고 s = e = -1. render 는 단어를 공백으로 이어 그린다.
## 영어 단위 수는 언제나 DictationDiff.word_count(text) 와 같다 (aligned 여부와 무관).
## 영어의 w 는 원문 조각이라 곡선 따옴표(’)는 그대로 남는다 (split_words 의 w 는 ' 로 바뀐다).
static func units(text: Variant, lang: Variant) -> Dictionary:
	var t: String = text if (text is String) else ""
	if t == "":
		return {"units": [], "aligned": true}
	if is_ja(lang):
		return {"units": _ja_units(t), "aligned": true}
	return _en_units(t)


static func _is_en_word_char(c: int) -> bool:
	# DictationDiff 의 단어 글자: [A-Za-z0-9'À-ÖØ-öø-ÿ]
	return (c >= 48 and c <= 57) or (c >= 65 and c <= 90) or (c >= 97 and c <= 122) or c == 39 \
		or (c >= 0xC0 and c <= 0xD6) or (c >= 0xD8 and c <= 0xF6) or (c >= 0xF8 and c <= 0xFF)


static func _en_units(t: String) -> Dictionary:
	var norm: String = t.replace("’", "'").replace("‘", "'").replace("`", "'") # 글자 수 그대로
	var n: int = norm.length()
	var out: Array = []
	var i: int = 0
	while i < n:
		if _is_en_word_char(norm.unicode_at(i)):
			var j: int = i
			while j < n and _is_en_word_char(norm.unicode_at(j)):
				j += 1
			var s: int = i
			var e: int = j
			while s < e and norm.unicode_at(s) == 39:
				s += 1
			while e > s and norm.unicode_at(e - 1) == 39:
				e -= 1
			if e > s:
				out.append({"w": t.substr(s, e - s), "s": s, "e": e})
			i = j
		else:
			i += 1
	var want: int = DictationDiff.word_count(t)
	if t.length() <= MAX_TEXT and out.size() == want:
		return {"units": out, "aligned": true}
	var plain: Array = []
	for w in DictationDiff.split_words(t, MAX_TEXT):
		plain.append({"w": str((w as Dictionary)["w"]), "s": -1, "e": -1})
	return {"units": plain, "aligned": false}


static func _ja_kind(c: int, ch: String) -> int:
	if TextSim.JA_SKIP.find(ch) != -1:
		return K_SEP
	if (c >= 0x4E00 and c <= 0x9FFF) or (c >= 0x3400 and c <= 0x4DBF) or (c >= 0xF900 and c <= 0xFAFF) \
			or c == 0x3005 or c == 0x3006:
		return K_KANJI
	if c >= 0x3041 and c <= 0x309F:
		return K_HIRA
	if (c >= 0x30A0 and c <= 0x30FF) or (c >= 0x31F0 and c <= 0x31FF) or (c >= 0xFF66 and c <= 0xFF9F):
		return K_KATA
	if (c >= 48 and c <= 57) or (c >= 65 and c <= 90) or (c >= 97 and c <= 122) \
			or (c >= 0xFF10 and c <= 0xFF19) or (c >= 0xFF21 and c <= 0xFF3A) or (c >= 0xFF41 and c <= 0xFF5A):
		return K_ALNUM
	return K_OTHER


## 일본어 단위 (형태소 분석 없음, 결정적). 규칙 (설계 §3.3):
##  1. 글자를 종류(한자/히라가나/가타카나/영숫자/그 밖)별 덩어리로 나눈다. 공백·구두점(TextSim.JA_SKIP)은 끊는 자리.
##  2. 히라가나 덩어리가 5자 이상이면 앞에서 3자씩 자른다 (남는 1자는 앞 조각에 붙이고, 남는 2자는 별도 조각).
##  3. 구분자 없이 이어진 조각들 안에서, 1자 조각은 한자면 뒤 조각과, 그 밖이면 앞 조각과 합친다 (앞/뒤가 없으면 있는 쪽).
##     1자 조각이 없어질 때까지 왼쪽부터 반복. 구분자로 둘러싸인 1자 덩어리는 합칠 이웃이 없어 1자로 남는다.
## 단위를 이으면 JA_SKIP 글자를 뺀 원문과 같다. 순서는 원문 순서.
static func ja_split(text: Variant) -> Array:
	var out: Array = []
	for u in units(text, "ja")["units"]:
		out.append(str((u as Dictionary)["w"]))
	return out


static func _ja_units(t: String) -> Array:
	var n: int = t.length()
	var kinds: Array = []
	kinds.resize(n)
	for i in n:
		kinds[i] = _ja_kind(t.unicode_at(i), t[i])
	var out: Array = []
	var i: int = 0
	while i < n:
		if int(kinds[i]) == K_SEP:
			i += 1
			continue
		var g0: int = i
		while i < n and int(kinds[i]) != K_SEP:
			i += 1
		for p in _ja_group(kinds, g0, i):
			var d: Dictionary = p
			out.append({"w": t.substr(int(d["s"]), int(d["e"]) - int(d["s"])), "s": int(d["s"]), "e": int(d["e"])})
	return out


## 구분자 없는 글자 묶음 [g0, g1) 을 단위 조각 [{s, e, k}] 으로.
static func _ja_group(kinds: Array, g0: int, g1: int) -> Array:
	var pieces: Array = []
	var i: int = g0
	while i < g1:
		var k: int = int(kinds[i])
		var j: int = i
		while j < g1 and int(kinds[j]) == k:
			j += 1
		var run: int = j - i
		if k == K_HIRA and run >= HIRA_SPLIT_AT:
			var full: int = run / HIRA_CHUNK
			var rem: int = run % HIRA_CHUNK
			var at: int = i
			for c in full:
				var size: int = HIRA_CHUNK + (1 if (c == full - 1 and rem == 1) else 0)
				pieces.append({"s": at, "e": at + size, "k": k})
				at += size
			if rem == 2:
				pieces.append({"s": at, "e": at + 2, "k": k})
		else:
			pieces.append({"s": i, "e": j, "k": k})
		i = j
	while pieces.size() > 1:
		var idx: int = -1
		for p in pieces.size():
			var d: Dictionary = pieces[p]
			if int(d["e"]) - int(d["s"]) == 1:
				idx = p
				break
		if idx == -1:
			break
		var one: Dictionary = pieces[idx]
		var with_next: bool
		if int(one["k"]) == K_KANJI:
			with_next = idx + 1 < pieces.size()
		else:
			with_next = idx == 0
		if with_next:
			var nx: Dictionary = pieces[idx + 1]
			nx["s"] = one["s"]
			pieces.remove_at(idx)
		else:
			var pv: Dictionary = pieces[idx - 1]
			pv["e"] = one["e"]
			pieces.remove_at(idx)
	return pieces


# ------------------------------------------------------------ 단계 계획

## 단계별 가림 개수. 보통 0·25·50·75·100%, 빠르게 0·50·100%. 가림 개수 = ceil(비율 × n) (비율 > 0 이면 최소 1).
## 앞 단계와 개수가 같은 단계는 건너뛴다. 첫 값 0, 끝 값 n (n <= 0 이면 [0]).
static func stage_plan(n_units: int, fast: bool = false) -> Array:
	var n: int = maxi(0, n_units)
	var out: Array = [0]
	if n == 0:
		return out
	for pct in (PCT_FAST if fast else PCT_NORMAL):
		var c: int = clampi((int(pct) * n + 99) / 100, 0, n)
		if int(pct) > 0:
			c = maxi(c, 1)
		if c > int(out[out.size() - 1]):
			out.append(c)
	if int(out[out.size() - 1]) != n:
		out.append(n)
	return out


# ------------------------------------------------------------ 가리는 순서

## 줄 키(16진 문자열) 앞 8자리 -> 32비트 정수. 16진이 아닌 글자는 0 으로 친다.
static func seed_of(key: Variant) -> int:
	var k: String = key if (key is String) else ""
	var v: int = 0
	for i in mini(8, k.length()):
		var c: int = k.unicode_at(i)
		var d: int = 0
		if c >= 48 and c <= 57:
			d = c - 48
		elif c >= 97 and c <= 102:
			d = c - 87
		elif c >= 65 and c <= 70:
			d = c - 55
		v = (v << 4) | d
	return v & MASK32


## 줄 글자에서 시드 (MemoModel.line_key 와 같은 정의: norm_text 의 sha256 앞 12자리 -> seed_of).
static func line_seed(text: Variant, lang: Variant) -> int:
	var t: String = text if (text is String) else ""
	var lg: String = "ja" if is_ja(lang) else "en"
	return seed_of(TextSim.norm_text(t, lg).sha256_text().left(12))


## 위치 i 의 정렬 값 (murmur3 fmix32 계열, 32비트 정수 연산만).
static func mix(seed: int, i: int) -> int:
	var z: int = ((seed & MASK32) + (i + 1) * GOLDEN) & MASK32
	z = ((z ^ (z >> 16)) * MUL1) & MASK32
	z = ((z ^ (z >> 13)) * MUL2) & MASK32
	return (z ^ (z >> 16)) & MASK32


static func _cmp_pair(a: Array, b: Array) -> bool:
	if int(a[0]) != int(b[0]):
		return int(a[0]) < int(b[0])
	return int(a[1]) < int(b[1])


## 0..n-1 의 순열: mix(seed, i) 오름차순 (동률은 i). 앞쪽에 있는 위치가 먼저 가려진다.
static func hide_order(n: int, seed: int) -> Array:
	var pairs: Array = []
	for i in maxi(0, n):
		pairs.append([mix(seed, i), i])
	pairs.sort_custom(_cmp_pair)
	var out: Array = []
	for p in pairs:
		out.append(int((p as Array)[1]))
	return out


## 길이 n 의 bool 배열: hide_order 의 앞 count 개 위치가 true. count 는 0..n 으로 보정.
## count1 < count2 면 hidden_flags(n, count1, seed) 의 true 는 hidden_flags(n, count2, seed) 에서도 true.
static func hidden_flags(n: int, count: int, seed: int) -> Array:
	var size: int = maxi(0, n)
	var flags: Array = []
	flags.resize(size)
	flags.fill(false)
	var order: Array = hide_order(size, seed)
	for k in clampi(count, 0, size):
		flags[int(order[k])] = true
	return flags


# ------------------------------------------------------------ 그리기

## 가린 단위를 BLANK 로 바꾼 글자. hidden = hidden_flags 결과(bool 배열: 위치 k 가 true 면 k번째 단위를 가림) 또는
## 가릴 단위 번호 배열(int). 구두점·띄어쓰기·곡선 따옴표는 그대로 둔다.
## 단위가 하나도 안 보이는 경우(전부 가림)에는 단위 밖의 글자·숫자·결합 기호도 지운다 (영어 단어 글자 집합 밖의 글자가
## 구두점 자리에 남아 줄 글자가 노출되는 것을 막는다). aligned:false 줄은 단어 목록을 공백으로 이어 그린다.
static func render(text: Variant, lang: Variant, hidden: Variant) -> String:
	var t: String = text if (text is String) else ""
	var u: Dictionary = units(t, lang)
	var us: Array = u["units"]
	var hide: Dictionary = {}
	if hidden is Array:
		var h: Array = hidden
		for k in h.size():
			var v: Variant = h[k]
			if v is bool:
				if v:
					hide[k] = true
			elif v is int or v is float:
				hide[int(v)] = true
	var all_hidden: bool = true
	for k in us.size():
		if not hide.has(k):
			all_hidden = false
			break
	if not bool(u["aligned"]):
		var parts: PackedStringArray = PackedStringArray()
		for k in us.size():
			parts.append(BLANK if hide.has(k) else str((us[k] as Dictionary)["w"]))
		return " ".join(parts)
	var out: String = ""
	var pos: int = 0
	for k in us.size():
		var d: Dictionary = us[k]
		out += _gap(t.substr(pos, int(d["s"]) - pos), all_hidden)
		out += BLANK if hide.has(k) else str(d["w"])
		pos = int(d["e"])
	out += _gap(t.substr(pos), all_hidden)
	return out


## 단위 사이 글자. 전부 가림이면 글자·숫자·결합 기호를 지운다.
static func _gap(seg: String, scrub: bool) -> String:
	if not scrub or seg == "":
		return seg
	var rx := RegEx.new()
	rx.compile("[\\p{L}\\p{N}\\p{M}]")
	return rx.sub(seg, "", true)
