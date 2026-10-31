extends Node
## 가사 외우기 M1: MemoMask (단위 나누기·단계 계획·시드 고정 가림 순서·가리기 그리기). 순수 함수 시험 (서버·파일 쓰기·마이크 없음).
##   godot --headless --path <project> res://tests/memo_mask_test.tscn
## Exit code 0 = all passed. Last line: "== memo_mask_test result: N passed, 0 failed =="
## 가사는 시험용으로 직접 쓴 문장뿐이다 (tests/fixtures/song/lyrics_en.txt, lyrics_ja.txt).

const EN_PATH := "res://tests/fixtures/song/lyrics_en.txt"
const JA_PATH := "res://tests/fixtures/song/lyrics_ja.txt"
const SRC_MASK := "res://scripts/core/memo_mask.gd"
const SRC_GRADE := "res://scripts/core/memo_grade.gd"

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


func _ready() -> void:
	print("== memo_mask_test start ==")
	_run()
	_reached_end = true
	ok(_reached_end, "끝까지 실행됨 (구간 끝 플래그)")
	print("== memo_mask_test result: %d passed, %d failed ==" % [passed, failed])
	get_tree().quit(1 if failed > 0 else 0)


# ---------------------------------------------------------------- 도우미 (검사기)

func _fixture(path: String) -> Array:
	var out: Array = []
	var f: FileAccess = FileAccess.open(path, FileAccess.READ)
	if f == null:
		return out
	for l in f.get_as_text().split("\n"):
		var s: String = String(l).strip_edges()
		if s == "" or s.begins_with("#"):
			continue
		out.append(s)
	return out


func _text_of(path: String) -> String:
	var f: FileAccess = FileAccess.open(path, FileAccess.READ)
	return "" if f == null else f.get_as_text()


## 0..n-1 의 순열인가
func _is_perm(a: Array, n: int) -> bool:
	if a.size() != n:
		return false
	var seen: Dictionary = {}
	for v in a:
		var i: int = int(v)
		if i < 0 or i >= n or seen.has(i):
			return false
		seen[i] = true
	return true


## 엄격한 오름차순 (중복 없음)
func _strict_asc(a: Array) -> bool:
	for k in range(1, a.size()):
		if int(a[k]) <= int(a[k - 1]):
			return false
	return true


## a 의 true 위치가 모두 b 에서도 true
func _subset(a: Array, b: Array) -> bool:
	if a.size() != b.size():
		return false
	for k in a.size():
		if bool(a[k]) and not bool(b[k]):
			return false
	return true


func _count_true(a: Array) -> int:
	var c: int = 0
	for v in a:
		if bool(v):
			c += 1
	return c


func _words_of(us: Array) -> Array:
	var out: Array = []
	for u in us:
		out.append(str((u as Dictionary)["w"]))
	return out


func _strip_skip(t: String) -> String:
	var out: String = ""
	for i in t.length():
		if TextSim.JA_SKIP.find(t[i]) == -1:
			out += t[i]
	return out


## 1자 단위는 앞뒤가 구분자(JA_SKIP)이거나 줄 끝일 때만 허용
func _singletons_isolated(t: String, us: Array) -> bool:
	for u in us:
		var d: Dictionary = u
		if int(d["e"]) - int(d["s"]) == 1:
			var s: int = int(d["s"])
			var e: int = int(d["e"])
			if s > 0 and TextSim.JA_SKIP.find(t[s - 1]) == -1:
				return false
			if e < t.length() and TextSim.JA_SKIP.find(t[e]) == -1:
				return false
	return true


func _no_singletons(us: Array) -> bool:
	for u in us:
		var d: Dictionary = u
		if int(d["e"]) - int(d["s"]) == 1:
			return false
	return true


func _run() -> void:
	var en: Array = _fixture(EN_PATH)
	var ja: Array = _fixture(JA_PATH)
	ok(en.size() == 6 and ja.size() == 5, "픽스처: 영어 6줄, 일본어 5줄")

	# ---- 검사기 자체 시험 (일부러 틀린 입력)
	ok(not _is_perm([0, 0, 2], 3), "검사기: 중복 순열 거절")
	ok(not _is_perm([0, 1], 3), "검사기: 길이가 다른 순열 거절")
	ok(not _is_perm([0, 1, 3], 3), "검사기: 범위 밖 순열 거절")
	ok(_is_perm([2, 0, 1], 3), "검사기: 올바른 순열 통과")
	ok(not _strict_asc([0, 2, 2, 4]) and not _strict_asc([0, 3, 2]) and _strict_asc([0, 1, 5]), "검사기: 오름차순 판정")
	ok(not _subset([true, false], [false, true]) and _subset([true, false], [true, true]), "검사기: 부분집합 판정")

	# ---- M1-2 영어 단위
	var want_counts: Array = [9, 9, 7, 9, 8, 8]
	var counts: Array = []
	var all_wc: bool = true
	var all_aligned: bool = true
	var all_slice: bool = true
	var all_mono: bool = true
	for line in en:
		var r: Dictionary = MemoMask.units(line, "en")
		var us: Array = r["units"]
		counts.append(us.size())
		all_wc = all_wc and us.size() == DictationDiff.word_count(line)
		all_aligned = all_aligned and bool(r["aligned"])
		var sw: Array = DictationDiff.split_words(line)
		var prev_e: int = 0
		for k in us.size():
			var d: Dictionary = us[k]
			var s: int = int(d["s"])
			var e: int = int(d["e"])
			all_slice = all_slice and line.substr(s, e - s) == str(d["w"])
			all_slice = all_slice and k < sw.size() and str((sw[k] as Dictionary)["w"]) == str(d["w"])
			all_mono = all_mono and s >= prev_e and e > s
			prev_e = e
	ok(counts == want_counts, "영어 단위 수 [9,9,7,9,8,8] (실제 %s)" % [str(counts)])
	ok(all_wc, "영어 단위 수 == DictationDiff.word_count")
	ok(all_aligned, "영어 6줄 모두 aligned == true")
	ok(all_slice, "영어 units[k] 의 [s,e) 조각 == w == split_words 의 w")
	ok(all_mono, "영어 단위 위치가 원문 순서대로 겹치지 않음")
	var odd: Dictionary = MemoMask.units("It’s o.k., fine", "en")
	ok(not bool(odd["aligned"]) and (odd["units"] as Array).size() == DictationDiff.word_count("It’s o.k., fine"),
		"영어 'o.k.' 줄은 aligned:false 이고 단위 수는 word_count 와 같다")
	ok(MemoMask.units("", "en")["units"] == [] and MemoMask.units(null, "en")["units"] == [] and MemoMask.units(5, "ja")["units"] == [],
		"빈·문자열 아닌 입력 -> 단위 0개")
	ok((MemoMask.units("!!! ...", "en")["units"] as Array).is_empty(), "구두점뿐인 줄 -> 단위 0개")

	# ---- M1-3 단계 계획
	ok(MemoMask.stage_plan(9) == [0, 3, 5, 7, 9], "stage_plan 9 -> [0,3,5,7,9]")
	ok(MemoMask.stage_plan(8) == [0, 2, 4, 6, 8], "stage_plan 8 -> [0,2,4,6,8]")
	ok(MemoMask.stage_plan(4) == [0, 1, 2, 3, 4], "stage_plan 4 -> [0,1,2,3,4]")
	ok(MemoMask.stage_plan(3) == [0, 1, 2, 3], "stage_plan 3 -> [0,1,2,3]")
	ok(MemoMask.stage_plan(2) == [0, 1, 2], "stage_plan 2 -> [0,1,2]")
	ok(MemoMask.stage_plan(1) == [0, 1], "stage_plan 1 -> [0,1]")
	ok(MemoMask.stage_plan(0) == [0], "stage_plan 0 -> [0]")
	ok(MemoMask.stage_plan(-3) == [0], "stage_plan 음수 -> [0]")
	ok(MemoMask.stage_plan(9, true) == [0, 5, 9], "stage_plan 빠르게 9 -> [0,5,9]")
	ok(MemoMask.stage_plan(1, true) == [0, 1], "stage_plan 빠르게 1 -> [0,1]")
	var plan_good: bool = true
	for n in range(0, 61):
		for fast in [false, true]:
			var p: Array = MemoMask.stage_plan(n, fast)
			plan_good = plan_good and int(p[0]) == 0 and int(p[p.size() - 1]) == n and _strict_asc(p)
			plan_good = plan_good and p.size() <= (3 if fast else 5)
	ok(plan_good, "stage_plan n=0..60 보통·빠르게: 첫 0, 끝 n, 엄격 오름차순, 단계 수 상한")
	ok(MemoMask.stage_plan(9) != [0, 2, 4, 6, 9], "검사기: 틀린 계획은 같지 않다")

	# ---- M1-4 가리는 순서
	var perm_ok: bool = true
	var same_ok: bool = true
	for n in range(0, 31):
		for seed in [0, 1, 0xa1b2c3d4, 0xffffffff]:
			var o1: Array = MemoMask.hide_order(n, seed)
			perm_ok = perm_ok and _is_perm(o1, n)
			same_ok = same_ok and o1 == MemoMask.hide_order(n, seed)
	ok(perm_ok, "hide_order 는 0..n-1 의 순열 (n=0..30, 시드 4개)")
	ok(same_ok, "같은 seed·n 은 항상 같은 순열")
	var distinct: Dictionary = {}
	for seed in [11, 222, 3333, 44444, 555555]:
		distinct[str(MemoMask.hide_order(9, seed))] = true
	ok(distinct.size() >= 2, "서로 다른 시드 5개 중 서로 다른 순열이 %d 종 (n=9)" % [distinct.size()])
	ok(MemoMask.hide_order(9, 0xa1b2c3d4) == [6, 2, 4, 1, 0, 5, 8, 3, 7], "골든: hide_order(9, 0xa1b2c3d4) (독립 계산 값)")
	ok(MemoMask.hide_order(9, 0) == [2, 1, 4, 3, 8, 6, 0, 7, 5], "골든: hide_order(9, 0)")
	ok(MemoMask.hide_order(6, 0xffffffff) == [4, 2, 0, 5, 3, 1], "골든: hide_order(6, 0xffffffff)")
	ok(MemoMask.mix(0, 0) == 2462723854 and MemoMask.mix(0xa1b2c3d4, 8) == 2710833382, "골든: mix 값 (32비트 정수 연산)")
	ok(MemoMask.hide_order(1, 5) == [0] and MemoMask.hide_order(0, 5) == [] and MemoMask.hide_order(-4, 5) == [], "hide_order 경계 n=1,0,음수")
	var sub_ok: bool = true
	var cnt_ok: bool = true
	for n in range(1, 25):
		for seed in [7, 0xa1b2c3d4]:
			var plan: Array = MemoMask.stage_plan(n)
			for a in plan.size():
				var fa: Array = MemoMask.hidden_flags(n, int(plan[a]), seed)
				cnt_ok = cnt_ok and fa.size() == n and _count_true(fa) == int(plan[a])
				for b in range(a + 1, plan.size()):
					sub_ok = sub_ok and _subset(fa, MemoMask.hidden_flags(n, int(plan[b]), seed))
	ok(sub_ok, "hidden_flags(n,c1) ⊆ hidden_flags(n,c2) (c1<c2, 모든 단계 쌍, n=1..24)")
	ok(cnt_ok, "hidden_flags 의 true 개수 == count, 길이 == n")
	ok(_count_true(MemoMask.hidden_flags(5, 99, 3)) == 5 and _count_true(MemoMask.hidden_flags(5, -2, 3)) == 0, "hidden_flags count 보정 (0..n)")
	ok(MemoMask.hidden_flags(0, 3, 1) == [] and MemoMask.hidden_flags(-1, 3, 1) == [], "hidden_flags n<=0 -> []")
	ok(MemoMask.seed_of("a1b2c3d4e5f6") == 2712847316 and MemoMask.seed_of("A1B2C3D4") == 2712847316, "seed_of: 앞 8자리 16진 -> 정수")
	ok(MemoMask.seed_of("") == 0 and MemoMask.seed_of("zz") == 0 and MemoMask.seed_of(42) == 0 and MemoMask.seed_of(null) == 0, "seed_of: 빈·16진 아님·문자열 아님 -> 0")
	ok(MemoMask.seed_of("ffffffffffff") == 0xffffffff, "seed_of: 32비트 상한")
	var sd: int = MemoMask.line_seed("The kettle", "en")
	ok(sd == 1299160904, "line_seed 골든 (sha256('the kettle') 앞 8자리, 독립 계산)")
	ok(MemoMask.line_seed("THE kettle!!", "en") == sd and MemoMask.line_seed("The   KETTLE", "en") == sd, "line_seed: 대소문자·구두점·공백 달라도 같은 시드")
	ok(MemoMask.line_seed("The kettle hums", "en") != sd, "line_seed: 다른 줄은 다른 시드")
	ok(MemoMask.line_seed(ja[0], "ja") == 3407606913, "line_seed 일본어 골든 (독립 계산)")

	# ---- M1-5 그리기
	var base: String = "The kettle hums while the morning climbs the wall"
	ok(MemoMask.render(base, "en", [1, 5]) == "The ____ hums while the ____ climbs the wall", "render 가림 {1,5} (번호 배열)")
	ok(MemoMask.render(base, "en", [false, true, false, false, false, true, false, false, false]) == "The ____ hums while the ____ climbs the wall", "render 가림 {1,5} (bool 배열)")
	ok(MemoMask.render("Nobody calls, so the quiet stays small", "en", [1]) == "Nobody ____, so the quiet stays small", "render 구두점 보존: calls 가림")
	ok(MemoMask.render(base, "en", []) == base and MemoMask.render(base, "en", [false, false]) == base, "render 가림 없음 -> 원문 그대로")
	ok(MemoMask.render(base, "en", [1, 99, -4]) == "The ____ hums while the morning climbs the wall", "render 범위 밖 번호는 무시")
	ok(MemoMask.render(base, "en", null) == base and MemoMask.render(null, "en", [0]) == "", "render 입력 이상 -> 예외 없음")
	var leak_ok: bool = true
	var blank_ok: bool = true
	var plan_stage_ok: bool = true
	for pair in [["en", en], ["ja", ja]]:
		var lg: String = pair[0]
		for line in (pair[1] as Array):
			var us: Array = MemoMask.units(line, lg)["units"]
			var n: int = us.size()
			var seed: int = MemoMask.line_seed(line, lg)
			var plan: Array = MemoMask.stage_plan(n)
			for c in plan:
				var shown: String = MemoMask.render(line, lg, MemoMask.hidden_flags(n, int(c), seed))
				blank_ok = blank_ok and shown.count(MemoMask.BLANK) == int(c)
				if int(c) == n:
					# 맨 끝 단계: BLANK 를 걷어내면 단위 글자가 하나도 없어야 한다
					var rest: String = shown.replace(MemoMask.BLANK, "")
					for k in rest.length():
						leak_ok = leak_ok and (TextSim.JA_SKIP.find(rest[k]) != -1 or rest[k] == "'")
					for u in us:
						var w: String = str((u as Dictionary)["w"])
						leak_ok = leak_ok and (w.length() < 3 or shown.find(w) == -1)
					for ch_i in line.length():
						var chs: String = line[ch_i]
						if TextSim.JA_SKIP.find(chs) == -1 and chs != "'":
							leak_ok = leak_ok and shown.find(chs) == -1
				elif int(c) > 0:
					plan_stage_ok = plan_stage_ok and shown != line
	ok(blank_ok, "render: 단계마다 BLANK 개수 == 가림 개수 (영어 6줄·일본어 5줄 전 단계)")
	ok(leak_ok, "맨 끝 단계 그리기 결과에 줄 글자가 하나도 없음 (영어 6줄·일본어 5줄)")
	ok(plan_stage_ok, "중간 단계는 원문과 다르게 그려짐")
	var scrubbed: String = MemoMask.render("Łódź, ŁŁ naïve", "en", [true, true])
	ok(scrubbed.replace(MemoMask.BLANK, "").strip_edges().replace(",", "").strip_edges() == "", "전부 가림: 단어 글자 집합 밖 글자(Ł)도 노출되지 않음 (%s)" % [scrubbed])
	var half: String = MemoMask.render("Łódź, naïve", "en", [true, false])
	ok(half.find("Ł") != -1 and half.find("naïve") != -1, "일부만 가리면 단위 밖 글자는 원문 그대로")
	var fw: String = MemoMask.render("It’s o.k., fine", "en", [false, true, false])
	ok(fw.count(MemoMask.BLANK) == 1 and fw.find("fine") != -1, "aligned:false 줄은 단어 목록을 이어 그림 (%s)" % [fw])
	ok(MemoMask.render("朝の窓辺で、小さなやかんが鳴る。", "ja", [true, true, true, true, true]).replace(MemoMask.BLANK, "") == "、。", "일본어 전부 가림: 구두점만 남음")

	# ---- M1-6 일본어 단위
	var ja_ok: bool = true
	var ja_strict: bool = true
	var ja_det: bool = true
	var ja_pos: bool = true
	for line in ja:
		var us: Array = MemoMask.units(line, "ja")["units"]
		var joined: String = "".join(PackedStringArray(_words_of(us)))
		ja_ok = ja_ok and joined == _strip_skip(line)
		ja_strict = ja_strict and line.length() >= 2 and _no_singletons(us)
		ja_det = ja_det and MemoMask.ja_split(line) == MemoMask.ja_split(line) and MemoMask.ja_split(line) == _words_of(us)
		for u in us:
			var d: Dictionary = u
			ja_pos = ja_pos and line.substr(int(d["s"]), int(d["e"]) - int(d["s"])) == str(d["w"])
	ok(ja_ok, "ja_split (a): 단위를 이으면 JA_SKIP 을 뺀 원문과 같음 (5줄)")
	ok(ja_strict, "ja_split (b): 2자 이상 줄에 1자 단위 없음 (5줄)")
	ok(ja_det, "ja_split (c): 두 번 호출 결과 같음, units 와 일치 (5줄)")
	ok(ja_pos, "ja units 의 [s,e) 조각 == w (5줄)")
	# 골든 (설계 §3.3 규칙으로 손으로 계산한 값)
	ok(MemoMask.ja_split("朝の窓辺で小さなやかんが鳴る") == ["朝の", "窓辺で", "小さなや", "かんが", "鳴る"], "골든 1: 朝の窓辺で小さなやかんが鳴る")
	ok(MemoMask.ja_split("青い椅子まで歩数をかぞえる") == ["青い", "椅子", "まで", "歩数", "をかぞ", "える"], "골든 2: 青い椅子まで歩数をかぞえる")
	var g2: Array = MemoMask.units("青い椅子まで歩数をかぞえる", "ja")["units"]
	var spans: Array = []
	for u in g2:
		spans.append([int((u as Dictionary)["s"]), int((u as Dictionary)["e"])])
	ok(spans == [[0, 2], [2, 4], [4, 6], [6, 8], [8, 11], [11, 13]], "골든 2 의 원문 위치 [s,e)")
	# 규칙 2·3 소형 골든
	ok(MemoMask.ja_split("あいうえお") == ["あいう", "えお"], "규칙2: 히라가나 5자 -> 3+2")
	ok(MemoMask.ja_split("あいうえおかき") == ["あいう", "えおかき"], "규칙2: 히라가나 7자 -> 3+4 (남는 1자는 앞 조각에)")
	ok(MemoMask.ja_split("あいうえおかきく") == ["あいう", "えおか", "きく"], "규칙2: 히라가나 8자 -> 3+3+2")
	ok(MemoMask.ja_split("ひらがな") == ["ひらがな"], "규칙2: 히라가나 4자는 자르지 않음")
	ok(MemoMask.ja_split("コーヒーを飲む") == ["コーヒーを", "飲む"], "규칙3: 1자 を(그 밖)는 앞과, 飲(한자)는 뒤와")
	ok(MemoMask.ja_split("iPhoneが好き") == ["iPhoneが", "好き"], "규칙3: 영숫자 덩어리 + が, 好き")
	ok(MemoMask.ja_split("を飲む") == ["を飲む"], "규칙3: 앞이 없는 1자는 뒤와 (を 다음 飲む 도 합쳐짐)")
	ok(MemoMask.ja_split("あ") == ["あ"] and MemoMask.ja_split("") == [] and MemoMask.ja_split("、。") == [], "줄 전체가 1자면 그대로, 빈·구두점뿐이면 0개")
	ok(MemoMask.ja_split("あ、い") == ["あ", "い"], "구분자로 둘러싸인 1자는 합칠 이웃이 없어 1자로 남음")
	var mixed: Array = ["コーヒーを飲む", "iPhoneが好き", "Ｗｉ-Fi가 좋아😀", "一二三四五六七八九", "アイウエオカキクケコサシス",
		"ひらがなだけのながいぶんしょうです", "今日は、いい天気。ね？", "ABC123 abc、あ", "「ありがとう」と言った", "ＡＢＣ１２３と漢字々〆カタカナ"]
	var m_a: bool = true
	var m_b: bool = true
	var m_c: bool = true
	for t in mixed:
		var us: Array = MemoMask.units(t, "ja")["units"]
		m_a = m_a and "".join(PackedStringArray(_words_of(us))) == _strip_skip(t)
		m_b = m_b and _singletons_isolated(t, us)
		m_c = m_c and MemoMask.units(t, "ja") == MemoMask.units(t, "ja")
	ok(mixed.size() >= 6 and m_a, "ja_split (a) 섞인 입력 %d개: 이으면 JA_SKIP 을 뺀 원문" % [mixed.size()])
	ok(m_b, "ja_split (b) 섞인 입력: 1자 단위는 구분자로 둘러싸인 경우뿐")
	ok(m_c, "ja_split (c) 섞인 입력: 결정적")
	ok(not _singletons_isolated("あい う", [{"w": "あ", "s": 0, "e": 1}, {"w": "い う", "s": 1, "e": 4}]), "검사기: 이웃이 있는 1자 단위는 거절")
	ok(not _no_singletons([{"w": "あ", "s": 0, "e": 1}]) and _no_singletons([{"w": "あい", "s": 0, "e": 2}]), "검사기: 1자 단위 검출")

	# ---- 금지 조건: 소스 검사
	var src: String = _text_of(SRC_MASK)
	ok(src != "" and src.find("RandomNumberGenerator") == -1 and src.find("randi") == -1 and src.find("randf") == -1 and src.find("randomize") == -1 and src.find("shuffle") == -1,
		"memo_mask.gd 에 엔진 난수(RandomNumberGenerator/randi/randf/randomize/shuffle) 0건")
	var both: String = src + _text_of(SRC_GRADE)
	var forbidden: Array = ["FileAccess", "DirAccess", "HTTPRequest", "Store.", "Api.", "OS.", "Time.", "static var", "get_node", "Engine."]
	var hits: Array = _hits(both, forbidden)
	ok(both != "" and hits.is_empty(), "memo_mask.gd·memo_grade.gd 에 파일·네트워크·전역 상태 접근 0건 %s" % [str(hits)])
	ok(not _hits("var f = FileAccess.open(p)
var s = Store.prefs", forbidden).is_empty(), "검사기: 금지 문자열이 있으면 잡는다")
	ok(_hits("var r = RandomNumberGenerator.new()", ["RandomNumberGenerator", "randi"]) == ["RandomNumberGenerator"], "검사기: 엔진 난수 사용을 잡는다")


func _hits(text: String, needles: Array) -> Array:
	var out: Array = []
	for n in needles:
		if text.find(str(n)) != -1:
			out.append(n)
	return out
