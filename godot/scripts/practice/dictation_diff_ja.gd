class_name DictationDiffJa
extends RefCounted
## 일본어 받아쓰기 채점 (순수 함수. 노드·저장소·네트워크 없음).
## 비교 단위는 읽기(히라가나) 글자다. 가나만 써도 소리가 맞으면 정답이고, 한자까지 맞으면 mode "exact".
## 가타카나는 히라가나로 접고, 공백·문장부호는 무시한다. 장음 ー 는 철자이므로 그대로 둔다.
## 한자를 전부 쓰든, 일부만 쓰든, 가나로만 쓰든 소리와 표기가 맞으면 100점이다.
##
## 채점 방법(정렬 DP): 정답 문장을 글자 단위 항목으로 본다. 가나 항목은 읽기의 한 글자와 정확히 같아야 하고(닻),
## 한자(·숫자·영문) 글자는 읽기의 임의 구간(1글자 이상)에 대응한다. 쓴 글을 이 항목들에 맞춰 가장 오류가 적은 정렬을 고른다:
## 한자 글자를 그 한자 그대로 쓰면 구간 전체가 맞은 것, 가나로 쓰면 구간의 글자를 하나씩 맞춘다.
## 빠진 읽기 글자(missing)와 정답에 없는 쓴 글자(extra)가 각각 오류 1이다. 구간 경계를 하나로 정해 두지 않으므로
## 닻 가나가 읽기 안에도 나오는 문장(母親は…)에서도 쓴 글에 가장 잘 맞는 경계가 골라진다.
## 한자 바로 뒤의 가나를 빠뜨리면 그 가나는 항상 missing 이다(닻이 고정이므로 한자의 읽기가 대신 먹지 못한다).
## 유일한 허용: 한자를 쓴 뒤 정답 읽기의 끝 1~3글자를 송가나처럼 더 붙인 경우(정답 行う, 쓴 글 行なう)는 오류가 아니다.
##
## diff(said, text, reading) -> {
##   score: 0..100, passed: bool,
##   mode: "exact" | "reading" | "mixed" | "wrong" | "empty",
##   units: [{w: 정답 표기 조각(원문), rd: 읽기 조각, ok: bool,
##            kind: "ok" | "kana" | "kanji_diff" | "missing" | "typo", said: 쓴 조각, k: 한자 덩어리 여부}],
##   extra: [정답에 없는 글자 덩어리(문자열)...], len: 정답 읽기 글자 수
## }
## 인자는 Variant 이다: 문자열이 아니면(null·숫자 등) 점수 0 의 안전한 값을 돌려준다(에러 없음).

const MAX_LEN := 300            # 입력이 이보다 길면 앞 MAX_LEN 글자만 쓴다
const PASS_SCORE := 85          # 영어 DictationScreen.PASS_SCORE 와 같은 통과선
const HARD_ERRORS := 3          # 틀린 글자 수(len(R)+len(T)-2*lcs = 빠진 글자 + 정답에 없는 글자)가 이 이상이면 점수를 HARD_CAP 이하로
const HARD_CAP := 84
const SHORT_LEN := 8            # 읽기가 이 글자 수 이하인 짧은 문장은 오류가 하나라도 있으면 HARD_CAP 이하(한 글자 삭제·삽입도 불통과)
const TAIL_MAX := 3             # 한자 뒤에 더 붙여도 되는 송가나(읽기 끝) 글자 수의 상한

## 비교 때 지우는 글자: 공백·문장부호. ー(U+30FC)는 없다(유지).
const DROP := " \t\r\n　、。，．,.!?！？「」『』（）()…・〜~\"':;：；“”‘’"
## 반각 가타카나 U+FF66~FF9D (56자) -> 전각 가타카나
const HW_KANA := "ｦｧｨｩｪｫｬｭｮｯｰｱｲｳｴｵｶｷｸｹｺｻｼｽｾｿﾀﾁﾂﾃﾄﾅﾆﾇﾈﾉﾊﾋﾌﾍﾎﾏﾐﾑﾒﾓﾔﾕﾖﾗﾘﾙﾚﾛﾜﾝ"
const HW_FULL := "ヲァィゥェォャュョッーアイウエオカキクケコサシスセソタチツテトナニヌネノハヒフヘホマミムメモヤユヨラリルレロワン"
const VOICE_FROM := "かきくけこさしすせそたちつてとはひふへほうゝ"
const VOICE_TO := "がぎぐげござじずぜぞだぢづでどばびぶべぼゔゞ"
const SEMI_FROM := "はひふへほ"
const SEMI_TO := "ぱぴぷぺぽ"

const _UNIT := 1000             # 오류 하나의 비용
const _INF := 1 << 29
const _BUDGET_FIRST := 3000     # 1차 탐색은 오류 3개까지만 보고, 안 되면 제한 없이 다시
const _STATE_MAX := 250000      # 정렬 상태 수가 이보다 크면 정답 문장을 한 덩어리로 보는 대체 경로
const _PRIOR_MAX := 1500000     # 읽기 경계 사전 분포 계산 상한(항목 수 x 읽기 길이^2)

# 정렬 연산 코드
const _OP_KANA := 1
const _OP_KANA_MISS := 2
const _OP_KANJI := 3
const _OP_IN := 4
const _OP_IN_MISS := 5
const _OP_EXTRA := 6
const _OP_EXIT := 7


## 읽기 비교용 정규화: 앞 MAX_LEN 글자 -> 전각 영숫자 반각·소문자 -> 반각 가타카나 전각 -> 가타카나 -> 히라가나
## -> 공백·문장부호 삭제. ー 는 유지(`こうひい` 와 `コーヒー` 는 다르다).
static func fold(s: Variant) -> String:
	if not _is_str(s):
		return ""
	return "".join(_fold_full(String(s))["f"])


## [{"s": 접은 표기 조각, "r": 읽기 조각, "k": 한자(·숫자·영문) 덩어리 여부, "o": 원문 표기 조각}]
## 가나 글자는 한 글자씩, 한자 덩어리(문장부호로 끊김)는 한 조각. 읽기 경계는 가나 닻으로 정하고 닻만으로 안 정해지면 글자당 2글자에 가깝게.
## 정렬이 안 되면(표기와 읽기의 가나가 안 맞음) 전체를 한 조각(k true)으로(대체 경로).
## 불변식(읽기가 있을 때): s 를 이으면 fold(text), r 을 이으면 fold(reading).
## 읽기가 비어 있으면 표기만 비교하므로 조각마다 r = s, k = false.
static func segments(text: Variant, reading: Variant) -> Array:
	return _build(text, reading, false)["segs"]


## 읽기 앞 2글자 + "…". 읽기가 비면 "".
static func first_hint(reading: Variant) -> String:
	var rs: String = fold(reading)
	if rs == "":
		return ""
	return rs.substr(0, 2) + "…"


static func diff(said: Variant, text: Variant, reading: Variant = "") -> Dictionary:
	if not _is_str(said):
		return _empty_result()
	var fd: Dictionary = _fold_full(String(said))
	var sf_all: PackedStringArray = fd["f"]
	var so_all: PackedStringArray = fd["o"]
	var p_full: int = sf_all.size()
	var B: Dictionary = _build(text, reading, false)
	var rs: String = B["R"]
	var rn: int = rs.length()
	if rn == 0:
		return _empty_result()
	# 너무 긴 쓴 글은 정답 길이에 비례해 앞부분만 정렬하고 나머지는 전부 extra 로 센다
	var pn: int = mini(p_full, 4 * rn + 20)
	if (B["items"] as Array).size() * (rn + 1) * (pn + 1) > _STATE_MAX and not bool(B["fallback"]):
		B = _build(text, reading, true)
	var items: Array = B["items"]
	var n: int = items.size()
	var rch := PackedStringArray()
	for k in rn:
		rch.append(rs.substr(k, 1))
	var pch: PackedStringArray = sf_all.slice(0, pn)
	var pstr: String = "".join(pch)

	var it_s := PackedStringArray()
	var it_k := PackedByteArray()
	var it_last := PackedByteArray()
	var it_run := PackedInt32Array()
	for it in items:
		it_s.append(it["s"])
		it_k.append(1 if bool(it["k"]) else 0)
		it_last.append(1 if bool(it["last"]) else 0)
		it_run.append(int(it["run"]))
	var res: Dictionary = _search(it_s, it_k, it_last, B["a"], B["b"], rch, pch, pstr, rs, B["feas"], _BUDGET_FIRST)
	if not bool(res["ok"]):
		res = _search(it_s, it_k, it_last, B["a"], B["b"], rch, pch, pstr, rs, B["feas"], _INF)

	# ---- 연산 열 -> 읽기 글자별 결과
	var op_t: PackedInt32Array = res["op"]
	var op_i: PackedInt32Array = res["i"]
	var op_q: PackedInt32Array = res["q"]
	var op_p: PackedInt32Array = res["p"]
	var op_l: PackedInt32Array = res["l"]
	var r_match := PackedByteArray()   # 0 = 빠짐, 1 = 가나로 맞음, 2 = 한자를 써서 맞음
	r_match.resize(rn)
	var r_item := PackedInt32Array()
	r_item.resize(rn)
	var r_orig := PackedStringArray()
	r_orig.resize(rn)
	var r_gap_txt := PackedStringArray()   # 빠진 글자 묶음의 첫 글자에만: 그 자리에 쓴 글
	r_gap_txt.resize(rn)
	var r_gap_t := PackedByteArray()       # 빠진 글자 묶음에 쓴 글자가 있었는가
	r_gap_t.resize(rn)
	var r_gap_ideo := PackedByteArray()    # 그 글자 중 한자가 있었는가
	r_gap_ideo.resize(rn)
	var lcs := 0
	var kanji_items := 0   # 한자를 써서 맞춘 글자 항목 수
	var extras_n := 0
	var extra: Array = []
	var cur_miss: Array = []
	var cur_txt := ""
	var cur_n := 0
	var cur_ideo := false
	for k in op_t.size():
		var t: int = op_t[k]
		var matched := false
		if t == _OP_KANA or t == _OP_IN:
			var q0: int = op_q[k]
			r_match[q0] = 1
			r_item[q0] = op_i[k]
			r_orig[q0] = so_all[op_p[k]]
			lcs += 1
			matched = true
		elif t == _OP_KANJI:
			var q1: int = op_q[k]
			var l1: int = op_l[k]
			var origin := ""
			var it_len: int = String(it_s[op_i[k]]).length()
			for j in it_len:
				origin += so_all[op_p[k] + j]
			for j in l1:
				r_match[q1 + j] = 2
				r_item[q1 + j] = op_i[k]
				r_orig[q1 + j] = origin if j == 0 else ""
			lcs += l1
			kanji_items += 1
			matched = true
		elif t == _OP_KANA_MISS or t == _OP_IN_MISS:
			r_match[op_q[k]] = 0
			r_item[op_q[k]] = op_i[k]
			cur_miss.append(op_q[k])
		elif t == _OP_EXTRA:
			extras_n += 1
			cur_n += 1
			cur_txt += so_all[op_p[k]]
			if _is_ideo(sf_all[op_p[k]].unicode_at(0)):
				cur_ideo = true
		if matched:
			_flush_gap(cur_miss, cur_txt, cur_n, cur_ideo, r_gap_txt, r_gap_t, r_gap_ideo, extra)
			cur_miss = []
			cur_txt = ""
			cur_n = 0
			cur_ideo = false
	_flush_gap(cur_miss, cur_txt, cur_n, cur_ideo, r_gap_txt, r_gap_t, r_gap_ideo, extra)
	extras_n += p_full - pn
	if p_full > pn:
		var rest := ""
		for j in range(pn, p_full):
			rest += so_all[j]
		extra.append(rest)

	# ---- 점수
	var tn: int = lcs + extras_n
	var score := 0
	if tn > 0:
		score = roundi(200.0 * float(lcs) / float(rn + tn))
		var errors: int = (rn - lcs) + extras_n
		if errors >= HARD_ERRORS or (rn <= SHORT_LEN and errors >= 1):
			score = mini(score, HARD_CAP)
	var out: Dictionary = {"score": score, "passed": score >= PASS_SCORE, "mode": "empty", "units": [], "extra": extra, "len": rn}

	# ---- 칸(조각)별 결과
	var runs: Array = B["runs"]
	var units: Array = []
	var u_rd: Array = []
	var u_ok: Array = []
	var u_said: Array = []
	var u_all_kanji: Array = []
	var u_miss_t: Array = []
	var u_miss_ideo: Array = []
	var u_miss: Array = []
	for u in runs.size():
		u_rd.append("")
		u_ok.append(true)
		u_said.append("")
		u_all_kanji.append(true)
		u_miss_t.append(false)
		u_miss_ideo.append(false)
		u_miss.append(false)
	for q in rn:
		var u: int = it_run[r_item[q]]
		u_rd[u] = String(u_rd[u]) + rch[q]
		if r_match[q] == 0:
			u_ok[u] = false
			u_all_kanji[u] = false
			u_miss[u] = true
			u_said[u] = String(u_said[u]) + r_gap_txt[q]
			if r_gap_t[q] == 1:
				u_miss_t[u] = true
			if r_gap_ideo[q] == 1:
				u_miss_ideo[u] = true
		else:
			u_said[u] = String(u_said[u]) + r_orig[q]
			if r_match[q] != 2:
				u_all_kanji[u] = false
	var chunk_items := 0
	for kx in it_k:
		chunk_items += int(kx)
	for u in runs.size():
		var run: Dictionary = runs[u]
		var is_chunk: bool = bool(run["k"])
		var kind := "ok"
		if bool(u_ok[u]):
			if is_chunk and not bool(u_all_kanji[u]):
				kind = "kana"
		else:
			if is_chunk and bool(u_miss_ideo[u]):
				kind = "kanji_diff"
			elif bool(u_miss_t[u]):
				kind = "typo"
			else:
				kind = "missing"
		units.append({"w": run["o"], "rd": u_rd[u], "ok": bool(u_ok[u]), "kind": kind, "said": u_said[u], "k": is_chunk})
	out["units"] = units

	if tn == 0:
		out["mode"] = "empty"
	elif score < 100:
		out["mode"] = "wrong"
	elif chunk_items == 0 or kanji_items == chunk_items:
		out["mode"] = "exact"
	elif kanji_items == 0:
		out["mode"] = "reading"
	else:
		out["mode"] = "mixed"
	return out


# ---------------------------------------------------------------- 내부

static func _is_str(v: Variant) -> bool:
	var t: int = typeof(v)
	return t == TYPE_STRING or t == TYPE_STRING_NAME


static func _empty_result() -> Dictionary:
	return {"score": 0, "passed": false, "mode": "empty", "units": [], "extra": [], "len": 0}


static func _is_ideo(code: int) -> bool:
	return (code >= 0x4E00 and code <= 0x9FFF) or (code >= 0x3400 and code <= 0x4DBF) \
		or code == 0x3005 or code == 0x3007 or (code >= 0xF900 and code <= 0xFAFF) \
		or (code >= 0x20000 and code <= 0x2FA1F)


static func _is_glue(code: int) -> bool:
	return code == 0x3095 or code == 0x3096   # ヵ ヶ 를 접은 것: 한자 사이에서만 덩어리에 든다


static func _is_alnum(code: int) -> bool:
	return (code >= 0x30 and code <= 0x39) or (code >= 0x61 and code <= 0x7A)


## {"f": 접은 글자들, "o": 각 글자의 원문(탁점 결합 등으로 한 글자가 둘 이상의 원문일 수 있음),
##  "b": 이 글자 앞에서 문장부호·공백이 지워졌으면 1}
static func _fold_full(s: String) -> Dictionary:
	var f := PackedStringArray()
	var o := PackedStringArray()
	var b := PackedByteArray()
	var pending := false
	var n: int = mini(s.length(), MAX_LEN)
	for i in n:
		var orig: String = s.substr(i, 1)
		var code: int = s.unicode_at(i)
		var voiced: bool = code == 0xFF9E or code == 0x3099 or code == 0x309B
		var semi: bool = code == 0xFF9F or code == 0x309A or code == 0x309C
		if voiced or semi:
			if f.is_empty():
				continue
			var last: String = f[f.size() - 1]
			var idx: int = (VOICE_FROM if voiced else SEMI_FROM).find(last)
			if idx < 0:
				continue
			f[f.size() - 1] = (VOICE_TO if voiced else SEMI_TO).substr(idx, 1)
			o[o.size() - 1] = o[o.size() - 1] + orig
			continue
		var c: String = orig
		if code >= 0xFF01 and code <= 0xFF5E:
			code -= 0xFEE0
			c = char(code)
		elif code >= 0xFF66 and code <= 0xFF9D:
			c = HW_FULL.substr(code - 0xFF66, 1)
			code = c.unicode_at(0)
		if DROP.contains(c):
			pending = true
			continue
		if code >= 0x41 and code <= 0x5A:
			code += 32
			c = char(code)
		elif code >= 0x30A1 and code <= 0x30F6:
			code -= 0x60
			c = char(code)
		elif code == 0x30FD:
			c = "ゝ"
		elif code == 0x30FE:
			c = "ゞ"
		f.append(c)
		o.append(orig)
		b.append(1 if pending else 0)
		pending = false
	return {"f": f, "o": o, "b": b}


## 정답 문장을 글자 단위 항목으로 만든다.
## items: [{"s": 접은 글자(대체 경로는 문장 전체), "o": 원문, "k": 한자 글자 여부, "run": 조각 번호, "last": 조각의 마지막 글자 항목}]
## runs: [{"s", "o", "k"}] 조각(가나 한 글자 / 한자 덩어리). 한자 덩어리는 문장부호·공백이 지워진 자리에서 끊는다.
static func _char_items(fd: Dictionary, text_only: bool) -> Dictionary:
	var f: PackedStringArray = fd["f"]
	var o: PackedStringArray = fd["o"]
	var b: PackedByteArray = fd["b"]
	var items: Array = []
	var runs: Array = []
	var n: int = f.size()
	var i := 0
	while i < n:
		var code: int = f[i].unicode_at(0)
		if not text_only and (_is_ideo(code) or _is_alnum(code) or _is_glue(code)):
			var j := i
			var has := false
			while j < n:
				var cj: int = f[j].unicode_at(0)
				if j > i and b[j] == 1:
					break
				if _is_ideo(cj) or _is_alnum(cj):
					has = true
				elif not _is_glue(cj):
					break
				j += 1
			if has:
				var run_id: int = runs.size()
				runs.append({"s": "".join(f.slice(i, j)), "o": "".join(o.slice(i, j)), "k": true})
				for x in range(i, j):
					items.append({"s": f[x], "o": o[x], "k": true, "run": run_id, "last": x == j - 1})
				i = j
				continue
		runs.append({"s": f[i], "o": o[i], "k": false})
		items.append({"s": f[i], "o": o[i], "k": false, "run": runs.size() - 1, "last": true})
		i += 1
	return {"items": items, "runs": runs}


## 항목 i.. 가 읽기 q.. 를 남김없이 소비할 수 있는가: rows[i][q] (가나 항목은 같은 글자 1개, 한자 글자 항목은 1글자 이상)
static func _feasible(items: Array, rch: PackedStringArray) -> Array:
	var n: int = items.size()
	var m: int = rch.size()
	var okr: Array = []
	okr.resize(n + 1)
	var suf_next := PackedByteArray()
	var last := PackedByteArray()
	last.resize(m + 1)
	last[m] = 1
	okr[n] = last
	suf_next.resize(m + 2)
	for p in range(m, -1, -1):
		suf_next[p] = 1 if (last[p] == 1 or suf_next[p + 1] == 1) else 0
	var nxt_ok: PackedByteArray = last
	for i in range(n - 1, -1, -1):
		var cur := PackedByteArray()
		cur.resize(m + 1)
		var it: Dictionary = items[i]
		var is_k: bool = bool(it["k"])
		var its: String = it["s"]
		for pos in m:
			if is_k:
				cur[pos] = suf_next[pos + 1]
			elif rch[pos] == its and nxt_ok[pos + 1] == 1:
				cur[pos] = 1
		okr[i] = cur
		nxt_ok = cur
		var cs := PackedByteArray()
		cs.resize(m + 2)
		for p in range(m, -1, -1):
			cs[p] = 1 if (cur[p] == 1 or cs[p + 1] == 1) else 0
		suf_next = cs
	return okr


## 정답 문장 준비: {"items", "runs", "segs", "R", "feas", "a", "b", "fallback"}
## a[i], b[i] = 항목 i 에 사전 분포(글자당 2글자에 가까운 경계)가 주는 읽기 구간 [a, b)
static func _build(text: Variant, reading: Variant, force_fallback: bool) -> Dictionary:
	var tfd: Dictionary = _fold_full(String(text) if _is_str(text) else "")
	var rs: String = fold(reading)
	var ft: String = "".join(tfd["f"])
	var text_only: bool = rs == ""
	var ci: Dictionary = _char_items(tfd, text_only)
	var items: Array = ci["items"]
	var runs: Array = ci["runs"]
	var rch := PackedStringArray()
	var rtxt: String = ft if text_only else rs
	for k in rtxt.length():
		rch.append(rtxt.substr(k, 1))
	var fallback := false
	var feas: Array = []
	if not text_only:
		if force_fallback:
			fallback = true
		else:
			feas = _feasible(items, rch)
			var first: PackedByteArray = feas[0]
			if (items.size() > 0 and first[0] != 1) or (items.is_empty() and rs != ""):
				fallback = true
	if fallback:
		var o_all := ""
		for r in runs:
			o_all += String(r["o"])
		runs = [{"s": ft, "o": o_all, "k": true}]
		items = [{"s": ft, "o": o_all, "k": true, "run": 0, "last": true}]
		feas = _feasible(items, rch)
	if text_only:
		feas = _feasible(items, rch)
	var n: int = items.size()
	var m: int = rch.size()
	# 읽기 경계 사전 분포: 한자 글자 하나가 2글자쯤 읽히는 쪽(오차 합이 최소). 쓴 글이 정하는 것이 우선이다(탐색 단계)
	var la := PackedInt32Array()   # 항목별 읽기 길이
	la.resize(n)
	var pos := 0
	var use_prior: bool = n * m * m <= _PRIOR_MAX
	var best: Array = []
	if use_prior and not fallback:
		best.resize(n + 1)
		var lastb := PackedInt32Array()
		lastb.resize(m + 1)
		lastb.fill(_INF)
		lastb[m] = 0
		best[n] = lastb
		for i in range(n - 1, -1, -1):
			var row := PackedInt32Array()
			row.resize(m + 1)
			row.fill(_INF)
			var nxt: PackedInt32Array = best[i + 1]
			var it: Dictionary = items[i]
			for q in m:
				if bool(it["k"]):
					var bv: int = _INF
					for l in range(1, m - q + 1):
						var v: int = nxt[q + l]
						if v < _INF:
							v += absi(l - 2)
							if v < bv:
								bv = v
					row[q] = bv
				elif rch[q] == String(it["s"]) and nxt[q + 1] < _INF:
					row[q] = nxt[q + 1]
			best[i] = row
	for i in n:
		var it2: Dictionary = items[i]
		if not bool(it2["k"]):
			la[i] = 1
		elif fallback:
			la[i] = m - pos
		else:
			var l_pick := 1
			if use_prior:
				var nxt2: PackedInt32Array = best[i + 1]
				var bv2: int = _INF
				for l in range(1, m - pos + 1):
					var v2: int = nxt2[pos + l]
					if v2 < _INF:
						v2 += absi(l - 2)
						if v2 < bv2:
							bv2 = v2
							l_pick = l
			else:
				var nxt_f: PackedByteArray = feas[i + 1]
				while pos + l_pick <= m and nxt_f[pos + l_pick] != 1:
					l_pick += 1
			la[i] = l_pick
		pos += la[i]
	var a_arr := PackedInt32Array()
	var b_arr := PackedInt32Array()
	pos = 0
	for i in n:
		a_arr.append(pos)
		pos += la[i]
		b_arr.append(pos)
	# 조각 목록
	var segs: Array = []
	var run_r: Array = []
	for r in runs.size():
		run_r.append("")
	for i in n:
		var ru: int = int((items[i] as Dictionary)["run"])
		run_r[ru] = String(run_r[ru]) + rtxt.substr(a_arr[i], la[i])
	for r2 in runs.size():
		var rr: Dictionary = runs[r2]
		var rd_txt: String = run_r[r2]
		segs.append({"s": rr["s"], "r": rd_txt, "k": bool(rr["k"]) and not text_only, "o": rr["o"]})
	return {"items": items, "runs": runs, "segs": segs, "R": rtxt, "feas": feas, "a": a_arr, "b": b_arr, "fallback": fallback}


## 묶음(빠진 읽기 글자들 + 그 사이에 낀 쓴 글자들)을 닫는다: 빠진 글자가 있으면 첫 글자에 쓴 글을 달고, 없으면 extra 로.
static func _flush_gap(miss: Array, txt: String, n: int, ideo: bool, gap_txt: PackedStringArray, gap_t: PackedByteArray, gap_ideo: PackedByteArray, extra: Array) -> void:
	if miss.is_empty():
		if n > 0:
			extra.append(txt)
		return
	for q in miss:
		gap_t[q] = 1 if n > 0 else 0
		gap_ideo[q] = 1 if ideo else 0
	gap_txt[miss[0]] = txt


static func _rx(cost: PackedInt32Array, back: PackedInt32Array, lo: PackedInt32Array, hi: PackedInt32Array, rn: int, w: int, ti: int, tq: int, tp: int, nc: int, code: int, budget: int) -> void:
	if nc > budget:
		return
	var row: int = ti * (rn + 1) + tq
	var f: int = row * w + tp
	if nc < cost[f]:
		cost[f] = nc
		back[f] = code
		if tp < lo[row]:
			lo[row] = tp
		if tp > hi[row]:
			hi[row] = tp


## 정렬 탐색(최소 오류). 상태: B[i][q][p] = 항목 i 앞, 읽기 q 글자·쓴 글 p 글자 소비 / I[i][q][p] = 한자 글자 항목 i 의 읽기를 가나로 쓰는 중.
## {"ok": bool, "cost": int, "op","i","q","p","l": 연산 열(정답 순서)}
static func _search(it_s: PackedStringArray, it_k: PackedByteArray, it_last: PackedByteArray, a_arr: PackedInt32Array, b_arr: PackedInt32Array, rch: PackedStringArray, pch: PackedStringArray, pstr: String, rstr: String, feas: Array, budget: int) -> Dictionary:
	var n: int = it_s.size()
	var rn: int = rch.size()
	var pn: int = pch.size()
	var w: int = pn + 1
	var rw: int = (rn + 1) * w
	var total: int = (n + 1) * rw
	var rows: int = (n + 1) * (rn + 1)
	var cb := PackedInt32Array()
	cb.resize(total)
	cb.fill(_INF)
	var ci := PackedInt32Array()
	ci.resize(total)
	ci.fill(_INF)
	var bb := PackedInt32Array()
	bb.resize(total)
	var bi := PackedInt32Array()
	bi.resize(total)
	var lob := PackedInt32Array()
	lob.resize(rows)
	lob.fill(w)
	var hib := PackedInt32Array()
	hib.resize(rows)
	hib.fill(-1)
	var loi := PackedInt32Array()
	loi.resize(rows)
	loi.fill(w)
	var hii := PackedInt32Array()
	hii.resize(rows)
	hii.fill(-1)
	cb[0] = 0
	lob[0] = 0
	hib[0] = 0
	for i in range(n + 1):
		var feas_next: PackedByteArray
		if i < n:
			feas_next = feas[i + 1]
		for q in range(rn + 1):
			var row: int = i * (rn + 1) + q
			# ---- B 상태
			var p: int = lob[row]
			while p <= hib[row]:
				var f: int = row * w + p
				var c: int = cb[f]
				if c < _INF:
					var base: int = (f * 2) * 16
					if p < pn:
						_rx(cb, bb, lob, hib, rn, w, i, q, p + 1, c + _UNIT, base + _OP_EXTRA, budget)
					if i < n:
						if it_k[i] == 0:
							if p < pn and pch[p] == it_s[i]:
								_rx(cb, bb, lob, hib, rn, w, i + 1, q + 1, p + 1, c, base + _OP_KANA, budget)
							_rx(cb, bb, lob, hib, rn, w, i + 1, q + 1, p, c + _UNIT, base + _OP_KANA_MISS, budget)
						else:
							if q < rn:
								var out_of: int = 1 if (q < a_arr[i] or q >= b_arr[i]) else 0
								if p < pn and pch[p] == rch[q]:
									_rx(ci, bi, loi, hii, rn, w, i, q + 1, p + 1, c + out_of, base + _OP_IN, budget)
								_rx(ci, bi, loi, hii, rn, w, i, q + 1, p, c + _UNIT + out_of, base + _OP_IN_MISS, budget)
							var len_i: int = it_s[i].length()
							if len_i > 0 and p + len_i <= pn:
								var typed: bool
								if len_i == 1:
									typed = pch[p] == it_s[i]
								else:
									typed = pstr.substr(p, len_i) == it_s[i]
								if typed:
									for l in range(1, rn - q + 1):
										if feas_next[q + l] != 1:
											continue
										var ov: int = mini(q + l, b_arr[i]) - maxi(q, a_arr[i])
										var pc: int = l - maxi(0, ov)
										_rx(cb, bb, lob, hib, rn, w, i + 1, q + l, p + len_i, c + pc, base + _OP_KANJI, budget)
										if it_last[i] == 1 and l >= 2:
											for k in range(1, mini(TAIL_MAX, l - 1) + 1):
												if p + len_i + k <= pn and pstr.substr(p + len_i, k) == rstr.substr(q + l - k, k):
													_rx(cb, bb, lob, hib, rn, w, i + 1, q + l, p + len_i + k, c + pc, base + _OP_KANJI, budget)
				p += 1
			# ---- I 상태
			if i < n:
				p = loi[row]
				while p <= hii[row]:
					var f2: int = row * w + p
					var c2: int = ci[f2]
					if c2 < _INF:
						var base2: int = (f2 * 2 + 1) * 16
						if p < pn:
							_rx(ci, bi, loi, hii, rn, w, i, q, p + 1, c2 + _UNIT, base2 + _OP_EXTRA, budget)
						if q < rn:
							var out2: int = 1 if (q < a_arr[i] or q >= b_arr[i]) else 0
							if p < pn and pch[p] == rch[q]:
								_rx(ci, bi, loi, hii, rn, w, i, q + 1, p + 1, c2 + out2, base2 + _OP_IN, budget)
							_rx(ci, bi, loi, hii, rn, w, i, q + 1, p, c2 + _UNIT + out2, base2 + _OP_IN_MISS, budget)
						if feas_next[q] == 1:
							_rx(cb, bb, lob, hib, rn, w, i + 1, q, p, c2, base2 + _OP_EXIT, budget)
					p += 1
	var f_end: int = (n * (rn + 1) + rn) * w + pn
	var res: Dictionary = {"ok": false, "cost": _INF, "op": PackedInt32Array(), "i": PackedInt32Array(), "q": PackedInt32Array(), "p": PackedInt32Array(), "l": PackedInt32Array()}
	if cb[f_end] >= _INF:
		return res
	# ---- 되짚기
	var ops := PackedInt32Array()
	var oi := PackedInt32Array()
	var oq := PackedInt32Array()
	var op_p := PackedInt32Array()
	var ol := PackedInt32Array()
	var f_cur: int = f_end
	var kind: int = 0
	var guard := 0
	while not (f_cur == 0 and kind == 0) and guard < total * 2 + 10:
		guard += 1
		var code: int = bb[f_cur] if kind == 0 else bi[f_cur]
		var op: int = code % 16
		var pk: int = code / 16
		var prev_kind: int = pk % 2
		var prev_f: int = pk / 2
		var pi: int = prev_f / rw
		var prem: int = prev_f % rw
		var pq: int = prem / w
		var pp: int = prem % w
		var cq: int = (f_cur % rw) / w
		ops.append(op)
		oi.append(pi)
		oq.append(pq)
		op_p.append(pp)
		ol.append(cq - pq)
		f_cur = prev_f
		kind = prev_kind
	ops.reverse()
	oi.reverse()
	oq.reverse()
	op_p.reverse()
	ol.reverse()
	res["ok"] = true
	res["cost"] = cb[f_end]
	res["op"] = ops
	res["i"] = oi
	res["q"] = oq
	res["p"] = op_p
	res["l"] = ol
	return res
