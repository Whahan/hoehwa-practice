class_name KanaData
extends RefCounted
## 히라가나 · 가타카나 글자표 (청음 46 + 탁음·반탁음 25 + 요음 33, 각각 히라가나와 가타카나) + 한글 소리 + 로마자 +
## 헷갈리는 글자 묶음 + 퀴즈 문제 만들기. 화면(KanaScreen)과 시험(kana_test.gd)이 같이 쓴다. 파일·네트워크는 건드리지 않는다.
##
## 글자 하나(entry) = {ch, script, hira, ko, ro, sec, grp, row, col, kana_id}
##   ch      글자 ("あ" / "ア" / "きゃ" / "キャ")
##   script  "hira" | "kata"
##   hira    같은 소리의 히라가나 (복습 카드의 읽기)
##   ko      한글 소리 (학습자용: か카 し시 つ츠 ん응)
##   ro      로마자 (헵번식)
##   sec     "seion" 청음 | "daku" 탁음 | "handaku" 반탁음 | "yoon" 요음
##   grp     행 묶음 id (RANGE_IDS): "a" "ka" ... "wa" | "daku" | "handaku" | "yoon"
##   row     표의 줄 번호 (구역 안), col 칸 번호 (0부터)
## 한글 소리가 같으면 로마자도 같다 (じ/ぢ 지 ji, ず/づ 즈 zu, お/を 오 o, 히라가나/가타카나). 그래서 퀴즈는
## 보기를 "한글 소리가 서로 다른" 글자로만 고른다 -> 소리 듣고 글자 고르기에서도 정답이 꼭 하나다.

const SCRIPTS := ["hira", "kata"]
const SECTIONS := ["seion", "daku", "handaku", "yoon"]
const SECTION_LABELS := {"seion": "청음 (기본 글자)", "daku": "탁음 (점 두 개)", "handaku": "반탁음 (동그라미)", "yoon": "요음 (작은 や ゆ よ)"}
const SECTION_COLS := {"seion": 5, "daku": 5, "handaku": 5, "yoon": 3}
const OPTIONS_N := 4
const QUIZ_N := 10

## 범위 선택 칩: [id, 이름]. 퀴즈에서 고르는 행 단위.
const RANGES := [
	["a", "あ행"], ["ka", "か행"], ["sa", "さ행"], ["ta", "た행"], ["na", "な행"], ["ha", "は행"],
	["ma", "ま행"], ["ya", "や행"], ["ra", "ら행"], ["wa", "わ행"],
	["daku", "탁음"], ["handaku", "반탁음"], ["yoon", "요음"],
]

## [행 id, 구역, 히라가나 칸(빈칸은 ""), 한글 소리, 로마자] -- 칸 수는 구역의 열 수(청음·탁음 5, 요음 3)
const _ROWS := [
	["a", "seion", ["あ", "い", "う", "え", "お"], ["아", "이", "우", "에", "오"], ["a", "i", "u", "e", "o"]],
	["ka", "seion", ["か", "き", "く", "け", "こ"], ["카", "키", "쿠", "케", "코"], ["ka", "ki", "ku", "ke", "ko"]],
	["sa", "seion", ["さ", "し", "す", "せ", "そ"], ["사", "시", "스", "세", "소"], ["sa", "shi", "su", "se", "so"]],
	["ta", "seion", ["た", "ち", "つ", "て", "と"], ["타", "치", "츠", "테", "토"], ["ta", "chi", "tsu", "te", "to"]],
	["na", "seion", ["な", "に", "ぬ", "ね", "の"], ["나", "니", "누", "네", "노"], ["na", "ni", "nu", "ne", "no"]],
	["ha", "seion", ["は", "ひ", "ふ", "へ", "ほ"], ["하", "히", "후", "헤", "호"], ["ha", "hi", "fu", "he", "ho"]],
	["ma", "seion", ["ま", "み", "む", "め", "も"], ["마", "미", "무", "메", "모"], ["ma", "mi", "mu", "me", "mo"]],
	["ya", "seion", ["や", "", "ゆ", "", "よ"], ["야", "", "유", "", "요"], ["ya", "", "yu", "", "yo"]],
	["ra", "seion", ["ら", "り", "る", "れ", "ろ"], ["라", "리", "루", "레", "로"], ["ra", "ri", "ru", "re", "ro"]],
	["wa", "seion", ["わ", "", "", "", "を"], ["와", "", "", "", "오"], ["wa", "", "", "", "o"]],
	["wa", "seion", ["ん", "", "", "", ""], ["응", "", "", "", ""], ["n", "", "", "", ""]],
	["daku", "daku", ["が", "ぎ", "ぐ", "げ", "ご"], ["가", "기", "구", "게", "고"], ["ga", "gi", "gu", "ge", "go"]],
	["daku", "daku", ["ざ", "じ", "ず", "ぜ", "ぞ"], ["자", "지", "즈", "제", "조"], ["za", "ji", "zu", "ze", "zo"]],
	["daku", "daku", ["だ", "ぢ", "づ", "で", "ど"], ["다", "지", "즈", "데", "도"], ["da", "ji", "zu", "de", "do"]],
	["daku", "daku", ["ば", "び", "ぶ", "べ", "ぼ"], ["바", "비", "부", "베", "보"], ["ba", "bi", "bu", "be", "bo"]],
	["handaku", "handaku", ["ぱ", "ぴ", "ぷ", "ぺ", "ぽ"], ["파", "피", "푸", "페", "포"], ["pa", "pi", "pu", "pe", "po"]],
	["yoon", "yoon", ["きゃ", "きゅ", "きょ"], ["캬", "큐", "쿄"], ["kya", "kyu", "kyo"]],
	["yoon", "yoon", ["しゃ", "しゅ", "しょ"], ["샤", "슈", "쇼"], ["sha", "shu", "sho"]],
	["yoon", "yoon", ["ちゃ", "ちゅ", "ちょ"], ["챠", "츄", "쵸"], ["cha", "chu", "cho"]],
	["yoon", "yoon", ["にゃ", "にゅ", "にょ"], ["냐", "뉴", "뇨"], ["nya", "nyu", "nyo"]],
	["yoon", "yoon", ["ひゃ", "ひゅ", "ひょ"], ["햐", "휴", "효"], ["hya", "hyu", "hyo"]],
	["yoon", "yoon", ["みゃ", "みゅ", "みょ"], ["먀", "뮤", "묘"], ["mya", "myu", "myo"]],
	["yoon", "yoon", ["りゃ", "りゅ", "りょ"], ["랴", "류", "료"], ["rya", "ryu", "ryo"]],
	["yoon", "yoon", ["ぎゃ", "ぎゅ", "ぎょ"], ["갸", "규", "교"], ["gya", "gyu", "gyo"]],
	["yoon", "yoon", ["じゃ", "じゅ", "じょ"], ["쟈", "쥬", "죠"], ["ja", "ju", "jo"]],
	["yoon", "yoon", ["びゃ", "びゅ", "びょ"], ["뱌", "뷰", "뵤"], ["bya", "byu", "byo"]],
	["yoon", "yoon", ["ぴゃ", "ぴゅ", "ぴょ"], ["퍄", "퓨", "표"], ["pya", "pyu", "pyo"]],
]

## 헷갈리는 글자 묶음 (각 묶음은 한글 소리가 서로 다른 글자 4개 이상: 집중 연습 보기가 전부 이 안에서 나온다).
## [id, 스크립트, 이름, 글자들]
const _GROUPS := [
	["h_nu_me", "hira", "ぬ め ね れ わ", ["ぬ", "め", "ね", "れ", "わ"]],
	["h_ru_ro", "hira", "る ろ ら ち", ["る", "ろ", "ら", "ち"]],
	["h_sa_chi", "hira", "さ ち き ら", ["さ", "ち", "き", "ら"]],
	["h_ha_ho", "hira", "は ほ ま に", ["は", "ほ", "ま", "に"]],
	["h_a_o", "hira", "あ お め ぬ", ["あ", "お", "め", "ぬ"]],
	["h_i_ri", "hira", "い り こ に", ["い", "り", "こ", "に"]],
	["h_dakuten", "hira", "점 구분 は ば ぱ ほ ぼ ぽ", ["は", "ば", "ぱ", "ほ", "ぼ", "ぽ"]],
	["h_ka_ga", "hira", "점 구분 か が さ ざ た だ", ["か", "が", "さ", "ざ", "た", "だ"]],
	["k_shi_tsu", "kata", "シ ツ ソ ン", ["シ", "ツ", "ソ", "ン"]],
	["k_ku_ke_ta", "kata", "ク ケ タ ス", ["ク", "ケ", "タ", "ス"]],
	["k_u_wa_fu", "kata", "ウ ワ フ ラ", ["ウ", "ワ", "フ", "ラ"]],
	["k_ko_yu", "kata", "コ ユ ヨ ロ", ["コ", "ユ", "ヨ", "ロ"]],
	["k_nu_su", "kata", "ヌ ス ナ メ", ["ヌ", "ス", "ナ", "メ"]],
	["k_a_ma", "kata", "ア マ ヤ ナ", ["ア", "マ", "ヤ", "ナ"]],
	["k_ru_re", "kata", "ル レ ノ ハ", ["ル", "レ", "ノ", "ハ"]],
	["k_dakuten", "kata", "점 구분 ハ バ パ ヘ ベ ペ", ["ハ", "バ", "パ", "ヘ", "ベ", "ペ"]],
]

static var _entries: Array = []
static var _by_ch: Dictionary = {}
static var _groups: Array = []


# ---------------------------------------------------------------- table

## 히라가나 글자 -> 같은 칸의 가타카나 (유니코드 0x60 차이: ぁ-ゖ -> ァ-ヶ). 히라가나가 아닌 글자는 그대로.
static func to_katakana(s: String) -> String:
	var out := ""
	for i in s.length():
		var c: int = s.unicode_at(i)
		if c >= 0x3041 and c <= 0x3096:
			c += 0x60
		out += char(c)
	return out


static func _build() -> void:
	if not _entries.is_empty():
		return
	var row_no := {}
	for r in _ROWS:
		var sec: String = r[1]
		var rn: int = int(row_no.get(sec, 0))
		row_no[sec] = rn + 1
		var cells: Array = r[2]
		for col in cells.size():
			var h: String = cells[col]
			if h == "":
				continue
			for script in SCRIPTS:
				var ch: String = h if script == "hira" else to_katakana(h)
				var e := {
					"ch": ch, "script": script, "hira": h, "ko": r[3][col], "ro": r[4][col],
					"sec": sec, "grp": r[0], "row": rn, "col": col,
				}
				_entries.append(e)
				_by_ch[ch] = e
	for g in _GROUPS:
		_groups.append({"id": g[0], "script": g[1], "label": g[2], "chars": (g[3] as Array).duplicate()})


## 스크립트 하나("hira"/"kata") 또는 둘 다("both")의 글자 전부. 표 순서.
static func entries(script: String = "both") -> Array:
	_build()
	if script == "both":
		return _entries.duplicate()
	var out: Array = []
	for e in _entries:
		if (e as Dictionary)["script"] == script:
			out.append(e)
	return out


## 한 구역(sec)의 글자들 (빈칸 제외, 표 순서).
static func section_entries(script: String, sec: String) -> Array:
	var out: Array = []
	for e in entries(script):
		if (e as Dictionary)["sec"] == sec:
			out.append(e)
	return out


## 구역을 표 줄로: [[칸 5개 또는 3개 (빈칸은 {})], ...]
static func section_rows(script: String, sec: String) -> Array:
	var cols: int = int(SECTION_COLS[sec])
	var rows: Array = []
	for e in section_entries(script, sec):
		var rn: int = int((e as Dictionary)["row"])
		while rows.size() <= rn:
			var blank: Array = []
			for i in cols:
				blank.append({})
			rows.append(blank)
		(rows[rn] as Array)[int((e as Dictionary)["col"])] = e
	return rows


static func get_entry(ch: String) -> Dictionary:
	_build()
	return _by_ch.get(ch, {})


static func has(ch: String) -> bool:
	_build()
	return _by_ch.has(ch)


## 범위 칩 id 목록(RANGES)에 속한 글자. ids 가 비어 있으면 전체.
static func in_ranges(script: String, ids: Array) -> Array:
	if ids.is_empty():
		return entries(script)
	var out: Array = []
	for e in entries(script):
		if ids.has((e as Dictionary)["grp"]):
			out.append(e)
	return out


static func range_ids() -> Array:
	var out: Array = []
	for r in RANGES:
		out.append(r[0])
	return out


# ---------------------------------------------------------------- mastery

## 맞힌/틀린 횟수 -> 익힘 정도 0..3. 0 = 아직 안 풀었음, 1 = 약함(틀림이 많음), 2 = 익히는 중, 3 = 익힘.
static func mastery(ok: int, bad: int) -> int:
	if ok + bad <= 0:
		return 0
	if ok >= 4 and bad * 3 <= ok:
		return 3
	if ok >= 2 and bad < ok:
		return 2
	return 1


# ---------------------------------------------------------------- confusable groups

## 헷갈리는 글자 묶음. script = "hira" | "kata" | "both".
static func groups(script: String = "both") -> Array:
	_build()
	if script == "both":
		return _groups.duplicate(true)
	var out: Array = []
	for g in _groups:
		if (g as Dictionary)["script"] == script:
			out.append((g as Dictionary).duplicate(true))
	return out


static func group_by_id(id: String) -> Dictionary:
	_build()
	for g in _groups:
		if (g as Dictionary)["id"] == id:
			return (g as Dictionary).duplicate(true)
	return {}


static func group_entries(g: Dictionary) -> Array:
	var out: Array = []
	for ch in g.get("chars", []):
		var e: Dictionary = get_entry(str(ch))
		if not e.is_empty():
			out.append(e)
	return out


# ---------------------------------------------------------------- quiz

## 문제 종류: "read" = 글자를 보고 소리(한글)를 고른다, "listen" = 소리를 듣고 글자를 고른다.
const KINDS := ["read", "listen"]


## 정답 하나와 보기를 만든다. 보기는 `pool` 에서 먼저 고르고, 모자라면 `fallback`, 그래도 모자라면 전체 글자에서 채운다.
## 보기 4개는 한글 소리가 모두 달라서 정답은 정확히 하나다.
## 돌려주는 값: {kind, ch, ko, ro, hira, script, options: [entry x4], answer: 정답 보기 번호(0~3)}
static func make_question(kind: String, answer: Dictionary, pool: Array, rng: RandomNumberGenerator, fallback: Array = []) -> Dictionary:
	_build()
	var used := {str(answer["ko"]): true}
	var opts: Array = [answer]
	for src in [pool, fallback, _entries]:
		if opts.size() >= OPTIONS_N:
			break
		var cands: Array = []
		for e in (src as Array):
			var ko: String = str((e as Dictionary)["ko"])
			if not used.has(ko):
				cands.append(e)
		_shuffle(cands, rng)
		for e in cands:
			if opts.size() >= OPTIONS_N:
				break
			var ko2: String = str((e as Dictionary)["ko"])
			if used.has(ko2):
				continue
			used[ko2] = true
			opts.append(e)
	_shuffle(opts, rng)
	var ans := 0
	for i in opts.size():
		if (opts[i] as Dictionary)["ch"] == answer["ch"]:
			ans = i
	return {
		"kind": kind, "ch": answer["ch"], "ko": answer["ko"], "ro": answer["ro"], "hira": answer["hira"],
		"script": answer["script"], "options": opts, "answer": ans,
	}


static func _shuffle(a: Array, rng: RandomNumberGenerator) -> void:
	var i: int = a.size() - 1
	while i > 0:
		var j: int = rng.randi_range(0, i)
		var t: Variant = a[i]
		a[i] = a[j]
		a[j] = t
		i -= 1


## 한 판(n문제)의 문제들.
## cfg = {kind: "read"|"listen", script: "hira"|"kata"|"both", rows: [범위 id...] (비면 전체), focus: bool (헷갈리는 글자 집중),
##        group: 집중 연습에서 한 묶음만 쓸 때 그 묶음 id (비면 범위의 모든 묶음), only: [글자...] (있으면 이 글자들만 낸다)}
## 같은 글자는 한 바퀴를 다 돌기 전에는 다시 나오지 않고, 바로 이어서 두 번 나오지도 않는다.
static func build_session(cfg: Dictionary, rng: RandomNumberGenerator, n: int = QUIZ_N) -> Array:
	_build()
	var kind: String = str(cfg.get("kind", "read"))
	var script: String = str(cfg.get("script", "hira"))
	var out: Array = []
	var scope: Array = entries(script) # 보기를 채울 수 있는 전체 범위
	if bool(cfg.get("focus", false)):
		var gs: Array = []
		var gid: String = str(cfg.get("group", ""))
		if gid != "":
			var one: Dictionary = group_by_id(gid)
			if not one.is_empty() and (script == "both" or one["script"] == script):
				gs.append(one) ## 다른 글자 종류의 묶음 id 는 무시한다
		if gs.is_empty() and gid == "":
			gs = groups(script)
		var ok_groups: Array = []
		for g in gs:
			if _group_ok(g):
				ok_groups.append(g)
		if ok_groups.is_empty():
			return out
		var last_ch := ""
		var seen := {}
		for q in n:
			var g: Dictionary = ok_groups[rng.randi_range(0, ok_groups.size() - 1)]
			var members: Array = group_entries(g)
			var fresh: Array = members.filter(func(e: Dictionary) -> bool: return not seen.has(e["ch"]) and e["ch"] != last_ch)
			if fresh.is_empty():
				seen.clear()
				fresh = members.filter(func(e: Dictionary) -> bool: return e["ch"] != last_ch)
			var ans: Dictionary = fresh[rng.randi_range(0, fresh.size() - 1)]
			seen[ans["ch"]] = true
			last_ch = ans["ch"]
			out.append(make_question(kind, ans, members, rng))
		return out
	var answers: Array = []
	var only: Array = cfg.get("only", [])
	if not only.is_empty():
		for ch in only:
			var e: Dictionary = get_entry(str(ch))
			if not e.is_empty():
				answers.append(e)
	else:
		answers = in_ranges(script, cfg.get("rows", []))
	if answers.is_empty():
		return out
	var queue: Array = []
	var last := ""
	for q in n:
		if queue.is_empty():
			queue = answers.duplicate()
			_shuffle(queue, rng)
			if queue.size() > 1 and (queue.back() as Dictionary)["ch"] == last:
				var t: Variant = queue[0]
				queue[0] = queue[queue.size() - 1]
				queue[queue.size() - 1] = t
		var ans2: Dictionary = queue.pop_back()
		last = ans2["ch"]
		out.append(make_question(kind, ans2, answers, rng, scope))
	return out


## 묶음의 글자가 4개 이상이고 한글 소리가 모두 다르면 true.
static func _group_ok(g: Dictionary) -> bool:
	var seen := {}
	for e in group_entries(g):
		seen[(e as Dictionary)["ko"]] = true
	return seen.size() >= OPTIONS_N
