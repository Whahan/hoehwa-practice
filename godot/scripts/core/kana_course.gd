class_name KanaCourse
extends RefCounted
## 가나 기초 코스(단계 24개 + 헷갈리는 짝 21쌍)의 순수 계산: 단계 구성, 단계 시험·짝 연습·입력 문제 만들기, 통과 판정.
## docs/v160_fun_design.md §5.3 · §5.7. 글자표·보기 만들기는 KanaData 를 그대로 쓴다.
## StudyLog·Store 를 읽지 않고(통계는 인자로 받는다), 파일·네트워크도 건드리지 않는다.
##
## 단계 id: 히라가나 h1..h11 + 짝 p_h, 가타카나 k1..k11 + 짝 p_k (추천 순서 = h1..h11, p_h, k1..k11, p_k).
## 질문 사전의 공통 필드는 KanaData.make_question 과 같다({kind, ch, ko, ro, hira, script, options, answer}).
##   kind "listen"/"read" : options = 글자 4개(한글 소리가 모두 다름), answer = 정답 보기 번호
##   kind "type"          : options = [], answer = -1, accept = 인정하는 답 전부(KanaTyping.accepted)
## 짝 문제는 "pair"(짝 id)와 "partner"(짝 글자)가 더 붙고, 보기에 정답과 짝 글자가 꼭 들어간다.

const STAGE_QUESTIONS := 15
const STAGE_PASS := 12 ## 15문제 중 12개 이상 = 80%
const MIN_PASS_TOTAL := 5 ## 15문제가 아닌 판에서 통과를 따질 최소 문제 수
const PASS_PERCENT := 80
const STAGE_LISTEN := 5
const STAGE_READ := 5
const STAGE_TYPE := 5
const PAIR_SESSION_N := 10
const WEAK_LEVEL := 1 ## 숙련도가 이 값 이하면 약한 글자

## [단계 번호 1..11, 이름(히라가나 기준), KanaData 행 id 들]
const _ROW_STAGES := [
	[1, "あ행", ["a"]],
	[2, "か행", ["ka"]],
	[3, "さ행", ["sa"]],
	[4, "た행", ["ta"]],
	[5, "な행", ["na"]],
	[6, "は행", ["ha"]],
	[7, "ま행", ["ma"]],
	[8, "や·ら·わ·ん행", ["ya", "ra", "wa"]],
	[9, "탁음", ["daku"]],
	[10, "반탁음", ["handaku"]],
	[11, "요음", ["yoon"]],
]
const PAIR_STAGE_TITLE := "헷갈리는 짝"

## 헷갈리는 짝: [스크립트, 글자 a, 글자 b, 같은 묶음 id(KanaData._GROUPS), 구별 요령 한 줄(초안, 사용자 검수 전)]
## tip 이 빈 문자열이면 확신이 없는 짝이다: 화면은 그 줄을 숨긴다.
const _PAIRS := [
	["hira", "ぬ", "め", "h_nu_me", "ぬ는 오른쪽 아래 끝에 작은 고리가 하나 더 있고, め는 그 고리가 없이 끝이 뻗어요."],
	["hira", "ね", "れ", "h_nu_me", "ね는 끝이 고리처럼 말려 있고, れ는 끝이 바깥으로 뻗어 올라가요."],
	["hira", "れ", "わ", "h_nu_me", "れ는 오른쪽 아래 끝이 바깥으로 뻗고, わ는 끝이 안쪽으로 둥글게 말려요."],
	["hira", "る", "ろ", "h_ru_ro", "る는 아래 끝에 작은 고리가 있고, ろ는 고리 없이 열려 있어요."],
	["hira", "さ", "ち", "h_sa_chi", ""],
	["hira", "き", "さ", "h_sa_chi", "き는 가로획이 두 줄이고, さ는 한 줄이에요."],
	["hira", "は", "ほ", "h_ha_ho", "ほ는 は와 비슷하지만 오른쪽 위에 가로획이 한 줄 더 있어요."],
	["hira", "ほ", "ま", "h_ha_ho", "ほ는 왼쪽에 세로획이 따로 서 있고, ま는 가로획 두 줄을 세로획 하나가 꿰뚫고 아래에서 고리를 만들어요."],
	["hira", "あ", "お", "h_a_o", "お는 오른쪽 위에 점이 하나 있고, あ는 그 점이 없어요."],
	["hira", "い", "り", "h_i_ri", ""],
	["kata", "シ", "ツ", "k_shi_tsu", "シ는 점 두 개가 옆으로 누워 있고 긴 획이 아래에서 위로 올라가요. ツ는 점 두 개가 위에서 아래로 서 있고 긴 획이 위에서 아래로 내려와요."],
	["kata", "ソ", "ン", "k_shi_tsu", "ソ는 ツ에서 점 하나를 뺀 모양(긴 획이 위에서 아래로), ン은 シ에서 점 하나를 뺀 모양(긴 획이 아래에서 위로)이에요."],
	["kata", "ク", "ケ", "k_ku_ke_ta", "ケ는 ク보다 획이 하나 더 많고, 가운데로 가로획이 지나가요."],
	["kata", "ク", "タ", "k_ku_ke_ta", "タ는 ク 안에 짧은 삐침 한 획이 더 들어 있어요."],
	["kata", "ウ", "ワ", "k_u_wa_fu", "ウ는 맨 위에 짧은 세로획이 있고, ワ는 그 획이 없어요."],
	["kata", "ワ", "フ", "k_u_wa_fu", "ワ는 왼쪽에 짧은 세로획이 있고, フ는 한 획이에요."],
	["kata", "コ", "ユ", "k_ko_yu", "ユ는 コ와 비슷하지만 아래 가로획이 오른쪽으로 길게 삐져나와요."],
	["kata", "ヌ", "ス", "k_nu_su", "ヌ는 ス의 긴 획 위에 작은 획이 하나 더 겹쳐 있어요."],
	["kata", "ナ", "メ", "k_nu_su", "メ는 두 획이 X 자로 엇갈리고, ナ는 가로획 하나 위에 삐침이 걸쳐요."],
	["kata", "ア", "マ", "k_a_ma", ""],
	["kata", "ル", "レ", "k_ru_re", "ル는 획이 두 개이고, レ는 한 획이에요."],
]

static var _stages: Array = []
static var _pairs: Array = []
static var _built: bool = false


# ---------------------------------------------------------------- build (once)

static func _build() -> void:
	if _built:
		return
	var rows_h: Array = []
	var rows_k: Array = []
	for r in _ROW_STAGES:
		var groups: Array = (r[2] as Array).duplicate()
		for script in KanaData.SCRIPTS:
			var chars: Array = []
			for e in KanaData.entries(script):
				if groups.has((e as Dictionary)["grp"]):
					chars.append((e as Dictionary)["ch"])
			var title: String = str(r[1]) if script == "hira" else KanaData.to_katakana(str(r[1]))
			var st := {
				"id": "%s%d" % ["h" if script == "hira" else "k", int(r[0])],
				"script": script, "title": title, "kind": "rows",
				"groups": groups.duplicate(), "chars": chars,
			}
			(rows_h if script == "hira" else rows_k).append(st)
	_pairs.clear()
	for p in _PAIRS:
		var a: Dictionary = KanaData.get_entry(str(p[1]))
		var b: Dictionary = KanaData.get_entry(str(p[2]))
		var letter: String = "h" if p[0] == "hira" else "k"
		_pairs.append({
			"id": "pr_%s_%s_%s" % [letter, str(a.get("ro", "?")), str(b.get("ro", "?"))],
			"script": p[0], "a": p[1], "b": p[2], "group": p[3], "tip": p[4],
		})
	_stages.clear()
	_stages.append_array(rows_h)
	_stages.append(_pair_stage("hira"))
	_stages.append_array(rows_k)
	_stages.append(_pair_stage("kata"))
	_built = true


static func _pair_stage(script: String) -> Dictionary:
	var chars: Array = []
	for p in _pairs:
		if (p as Dictionary)["script"] != script:
			continue
		for k in ["a", "b"]:
			if not chars.has(p[k]):
				chars.append(p[k])
	# 표 순서로 정렬(짝 목록 순서가 아니라 글자표 순서)
	var ordered: Array = []
	for e in KanaData.entries(script):
		if chars.has((e as Dictionary)["ch"]):
			ordered.append((e as Dictionary)["ch"])
	return {
		"id": "p_h" if script == "hira" else "p_k", "script": script, "title": PAIR_STAGE_TITLE, "kind": "pairs",
		"groups": [], "chars": ordered,
	}


# ---------------------------------------------------------------- stages

## 단계 목록(추천 순서). script = "hira" | "kata" | "both". 복사본이라 고쳐도 원본은 그대로.
static func stages(script: String = "both") -> Array:
	_build()
	var out: Array = []
	for s in _stages:
		if script == "both" or (s as Dictionary)["script"] == script:
			out.append((s as Dictionary).duplicate(true))
	return out


static func stage_by_id(id: String) -> Dictionary:
	_build()
	for s in _stages:
		if (s as Dictionary)["id"] == id:
			return (s as Dictionary).duplicate(true)
	return {}


static func stage_ids() -> Array:
	_build()
	var out: Array = []
	for s in _stages:
		out.append((s as Dictionary)["id"])
	return out


## `done`(= StudyLog.kana_course_done())에 없는 첫 단계 id. 그 글자 종류의 단계를 다 했으면 "".
static func next_stage(script: String, done: Dictionary) -> String:
	for s in stages(script):
		if not done.has((s as Dictionary)["id"]):
			return str((s as Dictionary)["id"])
	return ""


## 단계 시험 통과 판정. 15문제는 12개 이상. 다른 문제 수는 80% 이상이면서 MIN_PASS_TOTAL 문제 이상.
static func is_passed(correct: int, total: int) -> bool:
	if total <= 0 or correct < 0 or correct > total:
		return false
	if total == STAGE_QUESTIONS:
		return correct >= STAGE_PASS
	return total >= MIN_PASS_TOTAL and correct * 100 >= PASS_PERCENT * total


# ---------------------------------------------------------------- pairs

## 헷갈리는 짝 목록. script = "hira" | "kata" | "both".
static func pairs(script: String = "both") -> Array:
	_build()
	var out: Array = []
	for p in _pairs:
		if script == "both" or (p as Dictionary)["script"] == script:
			out.append((p as Dictionary).duplicate(true))
	return out


static func pair_by_id(id: String) -> Dictionary:
	_build()
	for p in _pairs:
		if (p as Dictionary)["id"] == id:
			return (p as Dictionary).duplicate(true)
	return {}


# ---------------------------------------------------------------- questions

## 입력 문제(보기 없음).
static func make_type_question(answer: Dictionary) -> Dictionary:
	return {
		"kind": "type", "ch": answer.get("ch", ""), "ko": answer.get("ko", ""), "ro": answer.get("ro", ""),
		"hira": answer.get("hira", ""), "script": answer.get("script", ""),
		"options": [], "answer": -1, "accept": KanaTyping.accepted(answer),
	}


## 짝 문제: 보기 = 정답 + 짝 글자 + 같은 묶음(없으면 같은 글자 종류 전체)의 다른 글자 2개. 한글 소리가 모두 다르다.
static func make_pair_question(kind: String, answer: Dictionary, partner: Dictionary, pair_id: String, members: Array, rng: RandomNumberGenerator) -> Dictionary:
	var used := {str(answer["ko"]): true}
	var opts: Array = [answer]
	if not used.has(str(partner["ko"])):
		used[str(partner["ko"])] = true
		opts.append(partner)
	for src in [members, KanaData.entries(str(answer["script"]))]:
		if opts.size() >= KanaData.OPTIONS_N:
			break
		var cands: Array = []
		for e in (src as Array):
			if not used.has(str((e as Dictionary)["ko"])):
				cands.append(e)
		_shuffle(cands, rng)
		for e in cands:
			if opts.size() >= KanaData.OPTIONS_N:
				break
			if used.has(str((e as Dictionary)["ko"])):
				continue
			used[str((e as Dictionary)["ko"])] = true
			opts.append(e)
	_shuffle(opts, rng)
	var ans := 0
	for i in opts.size():
		if (opts[i] as Dictionary)["ch"] == answer["ch"]:
			ans = i
	return {
		"kind": kind, "ch": answer["ch"], "ko": answer["ko"], "ro": answer["ro"], "hira": answer["hira"],
		"script": answer["script"], "options": opts, "answer": ans, "pair": pair_id, "partner": partner["ch"],
	}


## 한 판(n문제)의 짝 문제. pair_ids 가 비면 script 의 모든 짝, 값이 있는데 맞는 짝이 하나도 없으면 [].
## 정답이 되는 쪽(a/b)을 번갈아 섞고, 같은 글자가 바로 이어서 나오지 않는다. kind 는 "read"(기본) 또는 "listen".
static func build_pair_session(pair_ids: Array, script: String, rng: RandomNumberGenerator, n: int = PAIR_SESSION_N, kind: String = "read") -> Array:
	var chosen: Array = []
	for p in pairs(script):
		if pair_ids.is_empty() or pair_ids.has((p as Dictionary)["id"]):
			chosen.append(p)
	var out: Array = []
	if chosen.is_empty() or n <= 0:
		return out
	var k: String = kind if KanaData.KINDS.has(kind) else "read"
	var queue: Array = []
	var last := ""
	for i in n:
		var pick: int = _pick_other(queue, last)
		if pick < 0:
			var fresh: Array = []
			for q in chosen:
				fresh.append([q, 0])
				fresh.append([q, 1])
			_shuffle(fresh, rng)
			queue.append_array(fresh)
			pick = _pick_other(queue, last)
		var item: Array = queue.pop_at(pick)
		var pr: Dictionary = item[0]
		var a: Dictionary = KanaData.get_entry(str(pr["a"] if int(item[1]) == 0 else pr["b"]))
		var b: Dictionary = KanaData.get_entry(str(pr["b"] if int(item[1]) == 0 else pr["a"]))
		last = str(a["ch"])
		out.append(make_pair_question(k, a, b, str(pr["id"]), KanaData.group_entries(KanaData.group_by_id(str(pr["group"]))), rng))
	return out


## 대기열 뒤쪽에서부터 정답 글자가 `last` 와 다른 첫 항목의 번호(없으면 -1).
static func _pick_other(queue: Array, last: String) -> int:
	var i: int = queue.size() - 1
	while i >= 0:
		if _item_ch(queue[i]) != last:
			return i
		i -= 1
	return -1


static func _item_ch(item: Array) -> String:
	var p: Dictionary = item[0]
	return str(p["a"] if int(item[1]) == 0 else p["b"])


## KanaData.build_session 과 같은 cfg 에 kind "type"(입력)을 더한 버전. read/listen 은 KanaData 가 그대로 만든다.
static func build_session(cfg: Dictionary, rng: RandomNumberGenerator, n: int = KanaData.QUIZ_N) -> Array:
	if str(cfg.get("kind", "read")) != "type":
		return KanaData.build_session(cfg, rng, n)
	var base := cfg.duplicate()
	base["kind"] = "read"
	var out: Array = []
	for q in KanaData.build_session(base, rng, n):
		out.append(make_type_question(KanaData.get_entry(str((q as Dictionary)["ch"]))))
	return out


## 단계 시험 15문제: 듣고 고르기 5 + 글자 보고 읽기 고르기 5 + 입력 5(섞여 나온다).
## sound=false(소리를 낼 수 없는 기기)면 듣기 5개가 읽기 고르기로 바뀐다. 같은 글자는 한 바퀴 안에 반복하지 않고
## 바로 이어서 나오지도 않는다(글자가 15개 미만인 단계는 순환). stats = {글자: [맞힘, 틀림]} 에서 숙련도가 약한 글자를 먼저 낸다.
static func build_stage_test(stage_id: String, rng: RandomNumberGenerator, sound: bool = true, stats: Dictionary = {}) -> Array:
	var st: Dictionary = stage_by_id(stage_id)
	if st.is_empty():
		return []
	var ents: Array = []
	for ch in st["chars"]:
		var e: Dictionary = KanaData.get_entry(str(ch))
		if not e.is_empty():
			ents.append(e)
	if ents.is_empty():
		return []
	var script: String = str(st["script"])
	var letters: Array = _letter_sequence(ents, STAGE_QUESTIONS, rng, stats)
	var kinds: Array = []
	for i in STAGE_LISTEN:
		kinds.append("listen" if sound else "read")
	for i in STAGE_READ:
		kinds.append("read")
	for i in STAGE_TYPE:
		kinds.append("type")
	_shuffle(kinds, rng)
	var scope: Array = KanaData.entries(script)
	var is_pairs: bool = st["kind"] == "pairs"
	var out: Array = []
	for i in STAGE_QUESTIONS:
		var e: Dictionary = letters[i]
		var kind: String = kinds[i]
		if kind == "type":
			out.append(make_type_question(e))
		elif is_pairs:
			out.append(_stage_pair_question(kind, e, script, ents, rng))
		else:
			out.append(KanaData.make_question(kind, e, ents, rng, scope))
	return out


## 짝 단계의 읽기/듣기 문제: 이 글자가 든 짝 하나를 골라 그 짝 글자를 보기에 넣는다.
static func _stage_pair_question(kind: String, e: Dictionary, script: String, ents: Array, rng: RandomNumberGenerator) -> Dictionary:
	var mine: Array = []
	for q in pairs(script):
		if q["a"] == e["ch"] or q["b"] == e["ch"]:
			mine.append(q)
	if mine.is_empty():
		return KanaData.make_question(kind, e, ents, rng, KanaData.entries(script))
	var pr: Dictionary = mine[rng.randi_range(0, mine.size() - 1)]
	var other: String = str(pr["b"] if pr["a"] == e["ch"] else pr["a"])
	return make_pair_question(kind, e, KanaData.get_entry(other), str(pr["id"]), KanaData.group_entries(KanaData.group_by_id(str(pr["group"]))), rng)


## 글자 n개의 출제 순서. 한 바퀴(= 모든 글자를 한 번씩)마다 약한 글자(숙련도 <= WEAK_LEVEL)를 앞에 두고 각각 섞는다.
## 바퀴가 바뀔 때 앞 바퀴의 마지막 글자가 새 바퀴의 첫 글자가 되지 않게 한다.
static func _letter_sequence(ents: Array, n: int, rng: RandomNumberGenerator, stats: Dictionary) -> Array:
	var seq: Array = []
	while seq.size() < n:
		var weak: Array = []
		var rest: Array = []
		for e in ents:
			if _mastery_of(stats, str((e as Dictionary)["ch"])) <= WEAK_LEVEL:
				weak.append(e)
			else:
				rest.append(e)
		_shuffle(weak, rng)
		_shuffle(rest, rng)
		var pass_order: Array = weak + rest
		if not seq.is_empty() and pass_order.size() > 1 and (pass_order[0] as Dictionary)["ch"] == (seq.back() as Dictionary)["ch"]:
			var t: Variant = pass_order[0]
			pass_order[0] = pass_order[1]
			pass_order[1] = t
		for e in pass_order:
			if seq.size() < n:
				seq.append(e)
	return seq


# ---------------------------------------------------------------- weak letters

## 푼 적이 있고 숙련도가 약한(<= WEAK_LEVEL) 글자들(글자 문자열), 틀림이 많은 순(같으면 맞힘 적은 순, 그다음 표 순서).
## stats = {글자: [맞힘, 틀림]} (StudyLog.kana_stats() 모양). script = "hira" | "kata" | "both". limit <= 0 이면 빈 배열.
static func weak_letters(stats: Dictionary, script: String, limit: int) -> Array:
	var out: Array = []
	if limit <= 0:
		return out
	var rows: Array = []
	var order := 0
	for e in KanaData.entries(script):
		order += 1
		var ch: String = str((e as Dictionary)["ch"])
		var ob: Array = _ok_bad(stats, ch)
		if int(ob[0]) + int(ob[1]) <= 0:
			continue
		if KanaData.mastery(int(ob[0]), int(ob[1])) <= WEAK_LEVEL:
			rows.append({"ch": ch, "ok": int(ob[0]), "bad": int(ob[1]), "order": order})
	rows.sort_custom(_weaker_first)
	for r in rows:
		if out.size() >= limit:
			break
		out.append(r["ch"])
	return out


static func _weaker_first(x: Dictionary, y: Dictionary) -> bool:
	if x["bad"] != y["bad"]:
		return int(x["bad"]) > int(y["bad"])
	if x["ok"] != y["ok"]:
		return int(x["ok"]) < int(y["ok"])
	return int(x["order"]) < int(y["order"])


## 통계에서 [맞힘, 틀림] (배열 [ok, bad] 또는 {ok, bad} 둘 다 받는다. 이상한 값은 0).
static func _ok_bad(stats: Dictionary, ch: String) -> Array:
	var v: Variant = stats.get(ch, null)
	if v is Array and (v as Array).size() >= 2:
		return [maxi(int((v as Array)[0]), 0), maxi(int((v as Array)[1]), 0)]
	if v is Dictionary:
		return [maxi(int((v as Dictionary).get("ok", 0)), 0), maxi(int((v as Dictionary).get("bad", 0)), 0)]
	return [0, 0]


static func _mastery_of(stats: Dictionary, ch: String) -> int:
	var ob: Array = _ok_bad(stats, ch)
	return KanaData.mastery(int(ob[0]), int(ob[1]))


static func _shuffle(a: Array, rng: RandomNumberGenerator) -> void:
	var i: int = a.size() - 1
	while i > 0:
		var j: int = rng.randi_range(0, i)
		var t: Variant = a[i]
		a[i] = a[j]
		a[j] = t
		i -= 1
