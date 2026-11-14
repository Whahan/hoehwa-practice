class_name DictationDiffJa
extends RefCounted
## 일본어 받아쓰기 채점 (순수 함수. 노드·저장소·네트워크 없음).
## 비교 단위는 읽기(히라가나) 글자다. 가나만 써도 소리가 맞으면 정답이고, 한자까지 맞으면 mode "exact".
## 가타카나는 히라가나로 접고, 공백·문장부호는 무시한다. 장음 ー 는 철자이므로 그대로 둔다.
## 혼합 표기(일부만 한자)는 정답 문장의 한자 덩어리마다의 읽기로 풀어서 비교한다.
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
const HARD_ERRORS := 3          # 틀린 글자 수(len(R)+len(T)-2*lcs)가 이 이상이면 점수를 HARD_CAP 이하로
const HARD_CAP := 84
const FOLLOW_MAX := 4           # 한자 덩어리 뒤 송가나를 살필 글자 수

## 비교 때 지우는 글자: 공백·문장부호. ー(U+30FC)는 없다(유지).
const DROP := " \t\r\n　、。，．,.!?！？「」『』（）()…・〜~\"':;：；“”‘’"
## 반각 가타카나 U+FF66~FF9D (56자) -> 전각 가타카나
const HW_KANA := "ｦｧｨｩｪｫｬｭｮｯｰｱｲｳｴｵｶｷｸｹｺｻｼｽｾｿﾀﾁﾂﾃﾄﾅﾆﾇﾈﾉﾊﾋﾌﾍﾎﾏﾐﾑﾒﾓﾔﾕﾖﾗﾘﾙﾚﾛﾜﾝ"
const HW_FULL := "ヲァィゥェォャュョッーアイウエオカキクケコサシスセソタチツテトナニヌネノハヒフヘホマミムメモヤユヨラリルレロワン"
const VOICE_FROM := "かきくけこさしすせそたちつてとはひふへほうゝ"
const VOICE_TO := "がぎぐげござじずぜぞだぢづでどばびぶべぼゔゞ"
const SEMI_FROM := "はひふへほ"
const SEMI_TO := "ぱぴぷぺぽ"


## 읽기 비교용 정규화: 앞 MAX_LEN 글자 -> 전각 영숫자 반각·소문자 -> 반각 가타카나 전각 -> 가타카나 -> 히라가나
## -> 공백·문장부호 삭제. ー 는 유지(`こうひい` 와 `コーヒー` 는 다르다).
static func fold(s: Variant) -> String:
	if not _is_str(s):
		return ""
	return "".join(_fold_full(String(s))["f"])


## [{"s": 접은 표기 조각, "r": 읽기 조각, "k": 한자(·숫자·영문) 덩어리 여부, "o": 원문 표기 조각}]
## 가나 글자는 한 글자씩, 한자 덩어리는 한 조각. 표기의 가나를 닻으로 읽기에서 찾아 그 사이를 한자 덩어리의 읽기로 정한다.
## 닻을 못 찾으면 전체를 한 조각(k true)으로(대체 경로).
## 불변식(읽기가 있을 때): s 를 이으면 fold(text), r 을 이으면 fold(reading).
## 읽기가 비어 있으면 표기만 비교하므로 조각마다 r = s, k = false.
static func segments(text: Variant, reading: Variant) -> Array:
	return _plan(text, reading)["segs"]


## 읽기 앞 2글자 + "…". 읽기가 비면 "".
static func first_hint(reading: Variant) -> String:
	var rs: String = fold(reading)
	if rs == "":
		return ""
	return rs.substr(0, 2) + "…"


static func diff(said: Variant, text: Variant, reading: Variant = "") -> Dictionary:
	if not _is_str(said):
		return _empty_result()
	var plan: Dictionary = _plan(text, reading)
	var segs: Array = plan["segs"]
	var rs: String = plan["R"]
	var rn: int = rs.length()
	if rn == 0:
		return _empty_result()
	var rch := PackedStringArray()
	for k in rn:
		rch.append(rs.substr(k, 1))

	# 한자 덩어리 목록(읽기 시작 위치 ro, 뒤따르는 가나 K 포함)
	var chunks: Array = []
	var ro := 0
	for si in segs.size():
		var sg: Dictionary = segs[si]
		if bool(sg["k"]) and String(sg["s"]) != "":
			var kk := ""
			var sj: int = si + 1
			while sj < segs.size() and not bool((segs[sj] as Dictionary)["k"]) and kk.length() < FOLLOW_MAX:
				kk += String((segs[sj] as Dictionary)["s"])
				sj += 1
			chunks.append({"s": sg["s"], "r": sg["r"], "K": kk, "ro": ro, "si": si})
		ro += String(sg["r"]).length()

	# 쓴 글 -> T (정답 문장의 한자 덩어리 표기는 그 읽기로 바꾼다)
	var fd: Dictionary = _fold_full(String(said))
	var sf: PackedStringArray = fd["f"]
	var so: PackedStringArray = fd["o"]
	var fstr: String = "".join(sf)
	var fn: int = sf.size()
	var tch := PackedStringArray()
	var tor := PackedStringArray()
	var tflag := PackedByteArray()  # 1 = 한자 덩어리를 쓴 것을 읽기로 바꾼 글자, 2 = 바꾸지 못한 한자, 0 = 그 밖
	var p := 0
	while p < fn:
		var best := -1
		var best_l := 0
		var best_d: int = 1 << 30
		for ci in chunks.size():
			var cc: Dictionary = chunks[ci]
			var cs: String = cc["s"]
			var cl: int = cs.length()
			if cl == 0 or p + cl > fn or cl < best_l:
				continue
			if fstr.substr(p, cl) != cs:
				continue
			var dd: int = absi(int(cc["ro"]) - tch.size())
			if cl > best_l or dd < best_d:
				best = ci
				best_l = cl
				best_d = dd
		if best < 0:
			tch.append(sf[p])
			tor.append(so[p])
			tflag.append(2 if _is_ideo(sf[p].unicode_at(0)) else 0)
			p += 1
			continue
		var ch: Dictionary = chunks[best]
		var rep: String = ch["r"]
		var kfol: String = ch["K"]
		var p2: int = p + best_l
		var origin := ""
		for q in range(p, p2):
			origin += so[q]
		var consumed := 0
		if kfol != "":
			var follow: String = fstr.substr(p2, FOLLOW_MAX)
			if not follow.begins_with(kfol):
				# 송가나 차이: 정답이 `行なう`(행 + なう) 인데 `行う` 로 쓴 경우 -> 읽기에 なう 의 앞쪽을 더해 준다
				for m in range(1, kfol.length()):
					if follow.begins_with(kfol.substr(m)):
						rep += kfol.substr(0, m)
						break
				# 정답이 `行う` 인데 `行なう` 로 쓴 경우 -> 읽기 끝과 겹치는 글자를 쓴 글에서 건너뛴다
				if consumed == 0 and rep == String(ch["r"]) and follow != "":
					for m2 in range(mini(3, rep.length() - 1), 0, -1):
						if rep.ends_with(follow.substr(0, m2)) and follow.substr(m2).begins_with(kfol):
							consumed = m2
							for q2 in range(p2, p2 + m2):
								origin += so[q2]
							break
		for k in rep.length():
			tch.append(rep.substr(k, 1))
			tor.append(origin if k == 0 else "")
			tflag.append(1)
		p = p2 + consumed

	var tn: int = tch.size()
	var out: Dictionary = {"score": 0, "passed": false, "mode": "empty", "units": [], "extra": [], "len": rn}
	# 맞은 글자 수가 같은 짝지음이 여럿이면 가나 닻(한자 덩어리가 아닌 칸)을 먼저 맞춘다: 가중치 1001 / 1000
	var wts := PackedInt32Array()
	for sg3 in segs:
		var w: int = 1000 if bool((sg3 as Dictionary)["k"]) else 1001
		for k in String((sg3 as Dictionary)["r"]).length():
			wts.append(w)
	var al: Dictionary = _align(tch, rch, wts)
	var t_of: PackedInt32Array = al["t_of"]
	var r_of: PackedInt32Array = al["r_of"]
	var lcs: int = int(TextSim.lcs_match(tch, rch)["len"])

	# 점수
	var score := 0
	if tn > 0:
		score = roundi(200.0 * float(lcs) / float(rn + tn))
		var errors: int = rn + tn - 2 * lcs
		if errors >= HARD_ERRORS:
			score = mini(score, HARD_CAP)
	out["score"] = score
	out["passed"] = score >= PASS_SCORE

	# 칸마다: 앞뒤로 맞은 글자 사이(틈)에 쓴 글자가 있었는지
	var prev_t := PackedInt32Array()
	var next_t := PackedInt32Array()
	prev_t.resize(rn)
	next_t.resize(rn)
	var last := -1
	for i in rn:
		prev_t[i] = last
		if t_of[i] >= 0:
			last = t_of[i]
	var nxt: int = tn
	for i in range(rn - 1, -1, -1):
		next_t[i] = nxt
		if t_of[i] >= 0:
			nxt = t_of[i]

	var units: Array = []
	var used_gap := {}
	var kanji_written := 0
	var chunk_units := 0
	var off := 0
	for si in segs.size():
		var sg2: Dictionary = segs[si]
		var rd: String = sg2["r"]
		var rl: int = rd.length()
		var is_chunk: bool = bool(sg2["k"])
		var all_ok := true
		var said_txt := ""
		var all_flag := true
		var has_gap_t := false
		var has_ideo := false
		for k in rl:
			var idx: int = off + k
			if t_of[idx] >= 0:
				if tflag[t_of[idx]] != 1:
					all_flag = false
				if is_chunk or all_ok:
					said_txt += tor[t_of[idx]]
			else:
				all_ok = false
				var gk: int = prev_t[idx] * 100000 + next_t[idx]
				for tj in range(prev_t[idx] + 1, next_t[idx]):
					has_gap_t = true
					if tflag[tj] == 2:
						has_ideo = true
				if not used_gap.has(gk):
					used_gap[gk] = true
					for tj2 in range(prev_t[idx] + 1, next_t[idx]):
						said_txt += tor[tj2]
		var kind := "ok"
		if all_ok:
			if is_chunk:
				chunk_units += 1
				if rl > 0 and all_flag:
					kanji_written += 1
				else:
					kind = "kana"
		else:
			if is_chunk:
				chunk_units += 1
			if is_chunk and has_ideo:
				kind = "kanji_diff"
			elif has_gap_t:
				kind = "typo"
			else:
				kind = "missing"
		units.append({"w": sg2["o"], "rd": rd, "ok": all_ok, "kind": kind, "said": said_txt, "k": is_chunk})
		off += rl
	out["units"] = units

	# 정답에 없는 글자 덩어리: 읽기 쪽 틈이 없는 곳에 낀 쓴 글자
	var extra: Array = []
	var t_i := 0
	var last_r := -1
	while t_i < tn:
		if r_of[t_i] >= 0:
			last_r = r_of[t_i]
			t_i += 1
			continue
		var t_e: int = t_i
		var run := ""
		while t_e < tn and r_of[t_e] < 0:
			run += tor[t_e]
			t_e += 1
		var next_r: int = r_of[t_e] if t_e < tn else rn
		if next_r - last_r - 1 == 0 and run != "":
			extra.append(run)
		t_i = t_e
	out["extra"] = extra

	# 표기 방식
	if tn == 0:
		out["mode"] = "empty"
	elif score < 100:
		out["mode"] = "wrong"
	elif chunk_units == 0 or kanji_written == chunk_units:
		out["mode"] = "exact"
	elif kanji_written == 0:
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


## {"f": 접은 글자들, "o": 각 글자의 원문(탁점 결합 등으로 한 글자가 둘 이상의 원문일 수 있음)}
static func _fold_full(s: String) -> Dictionary:
	var f := PackedStringArray()
	var o := PackedStringArray()
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
	return {"f": f, "o": o}


## 접은 글자들을 가나 한 글자 / 한자 덩어리로 묶는다: [{"s", "o", "k"}]
static func _items(fd: Dictionary) -> Array:
	var f: PackedStringArray = fd["f"]
	var o: PackedStringArray = fd["o"]
	var items: Array = []
	var n: int = f.size()
	var i := 0
	while i < n:
		var code: int = f[i].unicode_at(0)
		if _is_ideo(code) or _is_alnum(code) or _is_glue(code):
			var j := i
			var has := false
			while j < n:
				var cj: int = f[j].unicode_at(0)
				if _is_ideo(cj) or _is_alnum(cj):
					has = true
				elif not _is_glue(cj):
					break
				j += 1
			if has:
				items.append({"s": "".join(f.slice(i, j)), "o": "".join(o.slice(i, j)), "k": true})
				i = j
				continue
		items.append({"s": f[i], "o": o[i], "k": false})
		i += 1
	return items


## {"segs": 조각들, "R": 비교할 읽기(접은 것), "aligned": 정렬 성공 여부}
static func _plan(text: Variant, reading: Variant) -> Dictionary:
	var tfd: Dictionary = _fold_full(String(text) if _is_str(text) else "")
	var rs: String = fold(reading)
	var items: Array = _items(tfd)
	var ft: String = "".join(tfd["f"])
	var segs: Array = []
	if rs == "":
		for it in items:
			segs.append({"s": it["s"], "r": it["s"], "k": false, "o": it["o"]})
		return {"segs": segs, "R": ft, "aligned": true}
	var n: int = items.size()
	var m: int = rs.length()
	var rch := PackedStringArray()
	for k in m:
		rch.append(rs.substr(k, 1))
	var okr: Array = []
	var suf: Array = []
	okr.resize(n + 1)
	suf.resize(n + 1)
	var last := PackedByteArray()
	last.resize(m + 1)
	last[m] = 1
	var lsuf := PackedByteArray()
	lsuf.resize(m + 2)
	for p in range(m, -1, -1):
		lsuf[p] = 1 if (last[p] == 1 or lsuf[p + 1] == 1) else 0
	okr[n] = last
	suf[n] = lsuf
	for i in range(n - 1, -1, -1):
		var nxt_ok: PackedByteArray = okr[i + 1]
		var nxt_suf: PackedByteArray = suf[i + 1]
		var cur := PackedByteArray()
		cur.resize(m + 1)
		var it: Dictionary = items[i]
		var is_k: bool = bool(it["k"])
		var its: String = it["s"]
		for pos in m:
			if is_k:
				cur[pos] = nxt_suf[pos + 1]
			elif rch[pos] == its and nxt_ok[pos + 1] == 1:
				cur[pos] = 1
		var cs := PackedByteArray()
		cs.resize(m + 2)
		for p in range(m, -1, -1):
			cs[p] = 1 if (cur[p] == 1 or cs[p + 1] == 1) else 0
		okr[i] = cur
		suf[i] = cs
	var first: PackedByteArray = okr[0]
	if first[0] != 1:
		var o_all := ""
		for it in items:
			o_all += String(it["o"])
		return {"segs": [{"s": ft, "r": rs, "k": true, "o": o_all}], "R": rs, "aligned": false}
	var pos2 := 0
	for i in n:
		var it2: Dictionary = items[i]
		if bool(it2["k"]):
			var nx: PackedByteArray = okr[i + 1]
			var ln := 1
			while pos2 + ln <= m and nx[pos2 + ln] != 1:
				ln += 1
			segs.append({"s": it2["s"], "r": rs.substr(pos2, ln), "k": true, "o": it2["o"]})
			pos2 += ln
		else:
			segs.append({"s": it2["s"], "r": it2["s"], "k": false, "o": it2["o"]})
			pos2 += 1
	return {"segs": segs, "R": rs, "aligned": true}


## TextSim.lcs_match(a, b) 와 같은 맞은 글자 수. 짝(T 쪽 번호, R 쪽 번호)까지 돌려준다.
## wb(b 쪽 글자별 가중치, 비면 전부 1)가 있으면 글자 수가 같은 짝지음 중 가중치 합이 큰 쪽을 고른다
## (가중치 차이 1 x 글자 수 <= MAX_LEN 이 가중치 크기보다 작아서 맞은 글자 수가 먼저다).
## {"len": int, "t_of": PackedInt32Array(R 번호 -> T 번호 또는 -1), "r_of": PackedInt32Array(T 번호 -> R 번호 또는 -1)}
static func _align(a: PackedStringArray, b: PackedStringArray, wb: PackedInt32Array = PackedInt32Array()) -> Dictionary:
	var n: int = a.size()
	var m: int = b.size()
	var weighted: bool = wb.size() == m
	var dp: Array = []
	for i in n + 1:
		var row := PackedInt32Array()
		row.resize(m + 1)
		dp.append(row)
	for i in range(n - 1, -1, -1):
		for j in range(m - 1, -1, -1):
			var best: int = maxi(dp[i + 1][j], dp[i][j + 1])
			if a[i] == b[j]:
				best = maxi(best, dp[i + 1][j + 1] + (wb[j] if weighted else 1))
			dp[i][j] = best
	var t_of := PackedInt32Array()
	t_of.resize(m)
	t_of.fill(-1)
	var r_of := PackedInt32Array()
	r_of.resize(n)
	r_of.fill(-1)
	var i2 := 0
	var j2 := 0
	var cnt := 0
	while i2 < n and j2 < m:
		if a[i2] == b[j2] and dp[i2][j2] == dp[i2 + 1][j2 + 1] + (wb[j2] if weighted else 1):
			t_of[j2] = i2
			r_of[i2] = j2
			cnt += 1
			i2 += 1
			j2 += 1
		elif dp[i2 + 1][j2] >= dp[i2][j2 + 1]:
			i2 += 1
		else:
			j2 += 1
	return {"len": cnt, "t_of": t_of, "r_of": r_of}
