extends Node
## 가나 코스 로직 시험 (서버 없이, 화면 없이): KanaCourse(단계 24개·짝 21쌍·단계 시험·짝 문제·입력 문제) + KanaTyping(입력 채점) + KanaVoice.
##   PC   : godot --headless --path godot res://tests/kana_course_test.tscn
##   폰   : godot --headless --path godot res://tests/kana_course_test.tscn -- --phone
## 마지막 줄: "== kana_course: N passed, M failed =="  (실패가 있으면 종료 코드 1)
## 이 시험은 파일을 쓰지 않는다(기록·설정 저장 없음). 소리 시험은 Tts.fetch_hook 으로 합성 소리를 가로채서 서버가 필요 없다.
## 검사기(check_question 등)는 일부러 망가뜨린 입력을 넣어 실제로 FAIL 하는지도 본다 ("selfcheck FAIL-as-expected ..." 줄).
## 소리 시험은 자동 로드(autoload) Api·Route 를 get_node 로 잡아서 주소·플랫폼 판정만 바꾼다(요청은 한 번도 보내지 않는다).

const SEEDS := 200
const SRC_FILES := ["res://scripts/core/kana_course.gd", "res://scripts/core/kana_typing.gd", "res://scripts/core/kana_voice.gd"]

var passed: int = 0
var failed: int = 0
var tts_calls: Array = []


## SystemTts adapter with a fixed voice list (kana_test.gd 와 같은 방식).
class VoiceFake:
	extends SystemTts.Adapter
	var voices: Array = []
	func available() -> bool:
		return true
	func get_voices() -> Array:
		return voices
	func speak(_t: String, _v: String, _vol: int, _p: float, _r: float, _id: int, _i: bool) -> void:
		pass
	func stop() -> void:
		pass


func ok(cond: bool, name: String) -> void:
	if cond:
		passed += 1
		print("  PASS  ", name)
	else:
		failed += 1
		print("  FAIL  ", name)


## 검사기가 "실패로 판정"해야 하는 입력: 실패로 판정하면 통과로 센다.
func fails(verdict_is_bad: bool, name: String) -> void:
	if verdict_is_bad:
		passed += 1
		print("  PASS  selfcheck FAIL-as-expected: ", name)
	else:
		failed += 1
		print("  FAIL  selfcheck did NOT fail: ", name)


## 값이 false 여야 하는 입력(채점기가 틀린 답을 떨어뜨리는지): false 면 통과로 센다.
func expect_false(accepted: bool, name: String) -> void:
	fails(not accepted, name)


func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


func _ready() -> void:
	print("== kana_course test start (%s) ==" % ("phone" if Platform.is_phone() else "pc"))
	_test_stages()
	_test_pairs()
	_test_checker_selfcheck()
	_test_stage_tests()
	_test_stage_tests_nosound_and_weak()
	_test_pair_sessions()
	_test_typing()
	_test_typing_bad_inputs()
	_test_pass_and_next()
	_test_session_type_and_weak()
	_test_static_scan()
	await _test_voice()
	print("== kana_course: %d passed, %d failed ==" % [passed, failed])
	get_tree().quit(1 if failed > 0 else 0)


# ---------------------------------------------------------------- validators (also checked against broken input)

## 보기 질문(listen/read) 하나가 제대로인지: 문제 있으면 이유, 없으면 "". 보기 4개, 한글 소리·글자 중복 없음, 정답 정확히 1개.
static func check_question(q: Dictionary) -> String:
	var opts: Array = q.get("options", [])
	if opts.size() != 4:
		return "options != 4 (%d)" % opts.size()
	var kos := {}
	var chs := {}
	var right := 0
	for o in opts:
		kos[str((o as Dictionary).get("ko", ""))] = true
		chs[str((o as Dictionary).get("ch", ""))] = true
		if str((o as Dictionary).get("ko", "")) == str(q.get("ko", "-")):
			right += 1
	if kos.size() != 4:
		return "duplicate ko in options"
	if chs.size() != 4:
		return "duplicate ch in options"
	if right != 1:
		return "correct options = %d" % right
	var a: int = int(q.get("answer", -1))
	if a < 0 or a >= 4 or str((opts[a] as Dictionary).get("ch", "")) != str(q.get("ch", "-")):
		return "answer index does not point at the answer"
	return ""


## 짝 문제: check_question + 보기에 짝 글자가 들어 있다.
static func check_pair_question(q: Dictionary) -> String:
	var base: String = check_question(q)
	if base != "":
		return base
	var partner: String = str(q.get("partner", ""))
	var has_partner := false
	for o in (q["options"] as Array):
		if str((o as Dictionary).get("ch", "")) == partner:
			has_partner = true
	if partner == "" or not has_partner:
		return "partner letter missing from options"
	var pr: Dictionary = KanaCourse.pair_by_id(str(q.get("pair", "")))
	if pr.is_empty():
		return "unknown pair id"
	var ab: Array = [pr["a"], pr["b"]]
	if not (ab.has(q["ch"]) and ab.has(partner) and q["ch"] != partner):
		return "answer/partner is not the pair"
	return ""


## 입력 문제: 보기 없음, answer -1, accept 에 ro·ko 가 들어 있다.
static func check_type_question(q: Dictionary) -> String:
	if str(q.get("kind", "")) != "type":
		return "kind is not type"
	if not (q.get("options", [1]) as Array).is_empty():
		return "type question has options"
	if int(q.get("answer", 0)) != -1:
		return "type question answer != -1"
	var acc: Array = q.get("accept", [])
	if not (acc.has(KanaTyping.normalize(str(q.get("ro", "")))) and acc.has(KanaTyping.normalize(str(q.get("ko", ""))))):
		return "accept lacks ro/ko"
	return ""


func _check_any(q: Dictionary) -> String:
	match str(q.get("kind", "")):
		"type":
			return check_type_question(q)
		"read", "listen":
			return check_pair_question(q) if q.has("pair") else check_question(q)
	return "unknown kind"


# ---------------------------------------------------------------- stages (K1-2)

func _test_stages() -> void:
	print("[stages]")
	var h: Array = KanaCourse.stages("hira")
	var k: Array = KanaCourse.stages("kata")
	var all: Array = KanaCourse.stages("both")
	ok(h.size() == 12 and k.size() == 12 and all.size() == 24, "stages: hira 12, kata 12, both 24 (%d/%d/%d)" % [h.size(), k.size(), all.size()])
	ok(KanaCourse.stage_ids().size() == 24, "stage_ids() has 24 ids")
	var want_h: Array = []
	var want_k: Array = []
	for i in range(1, 12):
		want_h.append("h%d" % i)
		want_k.append("k%d" % i)
	want_h.append("p_h")
	want_k.append("p_k")
	var got_h: Array = h.map(func(s: Dictionary) -> String: return s["id"])
	var got_k: Array = k.map(func(s: Dictionary) -> String: return s["id"])
	ok(got_h == want_h and got_k == want_k, "ids in order: h1..h11,p_h / k1..k11,p_k")
	var ids_all: Array = KanaCourse.stage_ids()
	var want_order: Array = want_h + want_k
	ok(ids_all == want_order, "stage_ids() order = h1..h11, p_h, k1..k11, p_k")
	var sizes := [5, 5, 5, 5, 5, 5, 5, 11, 20, 5, 33]
	var size_ok := true
	for i in 11:
		size_ok = size_ok and (h[i]["chars"] as Array).size() == sizes[i] and (k[i]["chars"] as Array).size() == sizes[i] and h[i]["kind"] == "rows"
	ok(size_ok, "row stage sizes 5,5,5,5,5,5,5,11,20,5,33 for both scripts")
	for pair in [["hira", 0], ["kata", 1]]:
		var script: String = pair[0]
		var stg: Array = (h if script == "hira" else k).slice(0, 11)
		var seen := {}
		var overlap := 0
		var in_table := true
		for s in stg:
			for ch in s["chars"]:
				if seen.has(ch):
					overlap += 1
				seen[ch] = true
				var e: Dictionary = KanaData.get_entry(str(ch))
				in_table = in_table and not e.is_empty() and e["script"] == script
		var table: Array = KanaData.entries(script)
		var covers := seen.size() == table.size() and table.all(func(e: Dictionary) -> bool: return seen.has(e["ch"]))
		ok(overlap == 0 and covers and table.size() == 104 and in_table, "%s: stage letters = all %d letters of the table, no overlap (%d, overlap %d)" % [script, table.size(), seen.size(), overlap])
	ok(h[11]["id"] == "p_h" and h[11]["kind"] == "pairs" and k[11]["kind"] == "pairs" and (h[11]["groups"] as Array).is_empty(), "p_h / p_k are pair stages")
	var title_ok: bool = h[0]["title"] == "あ행" and k[0]["title"] == "ア행" and h[7]["title"] == "や·ら·わ·ん행" and k[7]["title"] == "ヤ·ラ·ワ·ン행" and h[8]["title"] == "탁음"
	ok(title_ok, "stage titles (hira / kata)")
	var all_have := true
	for s in all:
		for f in ["id", "script", "title", "kind", "groups", "chars"]:
			all_have = all_have and (s as Dictionary).has(f)
	ok(all_have, "every stage has id/script/title/kind/groups/chars")
	var mut: Dictionary = KanaCourse.stage_by_id("h1")
	(mut["chars"] as Array).clear()
	ok((KanaCourse.stage_by_id("h1")["chars"] as Array).size() == 5, "stage_by_id returns a copy (editing it does not change the course)")
	ok(KanaCourse.stage_by_id("h8")["groups"] == ["ya", "ra", "wa"], "h8 groups = ya, ra, wa")
	ok((KanaCourse.stage_by_id("h8")["chars"] as Array).has("ん") and (KanaCourse.stage_by_id("h8")["chars"] as Array).has("を"), "h8 contains ん and を")
	# 일부러 틀린 입력
	ok(KanaCourse.stage_by_id("zz").is_empty(), "stage_by_id('zz') = {}")
	ok(KanaCourse.stage_by_id("").is_empty() and KanaCourse.stage_by_id("h12").is_empty(), "stage_by_id('') and ('h12') = {}")
	ok(KanaCourse.stages("zzz").is_empty(), "stages('zzz') = []")


# ---------------------------------------------------------------- pairs (K1-3)

func _test_pairs() -> void:
	print("[pairs]")
	var all: Array = KanaCourse.pairs("both")
	var h: Array = KanaCourse.pairs("hira")
	var k: Array = KanaCourse.pairs("kata")
	ok(all.size() == 21 and h.size() == 10 and k.size() == 11, "21 pairs: hira 10, kata 11 (%d/%d/%d)" % [all.size(), h.size(), k.size()])
	var ids := {}
	var bad: Array = []
	for p in all:
		ids[p["id"]] = true
		var a: Dictionary = KanaData.get_entry(str(p["a"]))
		var b: Dictionary = KanaData.get_entry(str(p["b"]))
		if a.is_empty() or b.is_empty():
			bad.append("not in table " + str(p["id"]))
			continue
		if a["ko"] == b["ko"]:
			bad.append("same ko " + str(p["id"]))
		if a["script"] != p["script"] or b["script"] != p["script"]:
			bad.append("script " + str(p["id"]))
		var g: Dictionary = KanaData.group_by_id(str(p["group"]))
		var chars: Array = g.get("chars", [])
		if not (chars.has(p["a"]) and chars.has(p["b"])):
			bad.append("not in group " + str(p["id"]))
		if not (p["tip"] is String):
			bad.append("tip type " + str(p["id"]))
	ok(bad.is_empty(), "every pair: both letters in the table, different ko, both inside its group's chars (problems: %s)" % str(bad))
	ok(ids.size() == 21, "pair ids are unique")
	var has := func(a: String, b: String) -> bool:
		return all.any(func(p: Dictionary) -> bool: return p["a"] == a and p["b"] == b)
	ok(has.call("シ", "ツ") and has.call("ソ", "ン") and has.call("ぬ", "め"), "シ/ツ, ソ/ン, ぬ/め are included")
	ok(KanaCourse.pair_by_id(str(all[0]["id"])) == all[0] and KanaCourse.pair_by_id("zz").is_empty(), "pair_by_id works; unknown id = {}")
	var stage_p: Dictionary = KanaCourse.stage_by_id("p_h")
	var in_pairs := {}
	for p in h:
		in_pairs[p["a"]] = true
		in_pairs[p["b"]] = true
	ok((stage_p["chars"] as Array).size() == in_pairs.size() and (stage_p["chars"] as Array).all(func(c: String) -> bool: return in_pairs.has(c)), "p_h letters = union of the hira pairs (%d)" % in_pairs.size())
	var blank_tips := all.filter(func(p: Dictionary) -> bool: return str(p["tip"]).strip_edges() == "").size()
	ok(blank_tips <= 6, "tips: only the unsure pairs are blank (%d blank of 21)" % blank_tips)
	var tip_clean := all.all(func(p: Dictionary) -> bool: return str(p["tip"]) == str(p["tip"]).strip_edges() and not str(p["tip"]).contains("\n"))
	ok(tip_clean, "tips are one trimmed line")
	var tip_len_ok := all.all(func(p: Dictionary) -> bool: return str(p["tip"]).length() <= 130)
	ok(tip_len_ok, "tips are short (<= 130 chars)")


# ---------------------------------------------------------------- the checkers themselves (K1-8)

func _test_checker_selfcheck() -> void:
	print("[checkers reject broken input]")
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var q: Dictionary = KanaData.make_question("read", KanaData.get_entry("ぬ"), KanaData.entries("hira"), rng)
	ok(check_question(q) == "", "check_question accepts a real question")
	var other := 0
	for i in 4:
		if i != int(q["answer"]):
			other = i
			break
	var two := q.duplicate(true)
	(two["options"] as Array)[other] = KanaData.get_entry("ヌ") ## 같은 소리의 가타카나가 보기에 또 있다 -> 정답 2개
	fails(check_question(two) != "", "two options with the same Korean sound")
	var wrong_idx := q.duplicate(true)
	wrong_idx["answer"] = (int(q["answer"]) + 1) % 4
	fails(check_question(wrong_idx) != "", "answer index points at another letter")
	var rng2 := RandomNumberGenerator.new()
	rng2.seed = 11
	var pq: Dictionary = KanaCourse.build_pair_session([], "kata", rng2, 1)[0]
	ok(check_pair_question(pq) == "", "check_pair_question accepts a real pair question")
	var no_partner := pq.duplicate(true)
	var pi := -1
	for i in 4:
		if (no_partner["options"] as Array)[i]["ch"] == no_partner["partner"]:
			pi = i
	var swap_in: Dictionary = KanaData.get_entry("ヨ")
	if str(swap_in["ko"]) == str(no_partner["ko"]):
		swap_in = KanaData.get_entry("ロ")
	var used_ko := {}
	for o in (no_partner["options"] as Array):
		used_ko[o["ko"]] = true
	for cand in ["ヨ", "ロ", "ホ", "ミ", "キ"]:
		if not used_ko.has(KanaData.get_entry(cand)["ko"]):
			swap_in = KanaData.get_entry(cand)
			break
	(no_partner["options"] as Array)[pi] = swap_in ## 짝 글자를 다른 글자로 바꿈 (보기 4개·소리 중복 없음은 그대로)
	ok(check_question(no_partner) == "", "(setup) the swapped question is still a valid 4-option question; only the partner is gone")
	fails(check_pair_question(no_partner) != "", "pair question whose partner letter is missing from the options")
	var tq: Dictionary = KanaCourse.make_type_question(KanaData.get_entry("し"))
	ok(check_type_question(tq) == "", "check_type_question accepts a real type question")
	var tq_opts := tq.duplicate(true)
	tq_opts["options"] = [KanaData.get_entry("し")]
	fails(check_type_question(tq_opts) != "", "type question that has options")
	var tq_acc := tq.duplicate(true)
	tq_acc["accept"] = ["x"]
	fails(check_type_question(tq_acc) != "", "type question whose accept list lacks ro/ko")


# ---------------------------------------------------------------- stage tests (K1-4)

func _test_stage_tests() -> void:
	print("[build_stage_test]")
	var bad: Array = []
	var total_q := 0
	var kinds_bad := 0
	var consec_bad := 0
	var outside_bad := 0
	var count_bad := 0
	var rng := RandomNumberGenerator.new()
	for sid in KanaCourse.stage_ids():
		var st: Dictionary = KanaCourse.stage_by_id(str(sid))
		for sd in SEEDS:
			rng.seed = sd + 1000
			var qs: Array = KanaCourse.build_stage_test(str(sid), rng, true)
			if qs.size() != KanaCourse.STAGE_QUESTIONS:
				count_bad += 1
				continue
			var counts := {"listen": 0, "read": 0, "type": 0}
			var last := ""
			var seen_pass := {}
			for q in qs:
				total_q += 1
				counts[q["kind"]] = int(counts.get(q["kind"], 0)) + 1
				if not (st["chars"] as Array).has(q["ch"]):
					outside_bad += 1
				if q["ch"] == last:
					consec_bad += 1
				last = q["ch"]
				var why: String = _check_any(q)
				if why != "" and bad.size() < 5:
					bad.append("%s seed %d: %s" % [sid, sd, why])
				seen_pass[q["ch"]] = int(seen_pass.get(q["ch"], 0)) + 1
			if counts["listen"] != 5 or counts["read"] != 5 or counts["type"] != 5:
				kinds_bad += 1
			# 글자가 15개 이상인 단계는 15문제 안에서 같은 글자가 반복되지 않는다
			if (st["chars"] as Array).size() >= 15:
				for ch in seen_pass:
					if int(seen_pass[ch]) > 1:
						kinds_bad += 1
	ok(count_bad == 0, "every stage x %d seeds gives exactly 15 questions (bad %d)" % [SEEDS, count_bad])
	ok(kinds_bad == 0, "kinds: listen 5 + read 5 + type 5 each time, no repeat inside a 15+ letter stage (bad %d)" % kinds_bad)
	ok(outside_bad == 0, "every question's letter is one of that stage's letters (bad %d of %d)" % [outside_bad, total_q])
	ok(consec_bad == 0, "no letter twice in a row (bad %d)" % consec_bad)
	ok(bad.is_empty(), "all %d questions valid: 4 options with distinct Korean sounds, answer index right (%s)" % [total_q, str(bad)])
	# 5글자 단계는 한 바퀴(5문제)마다 모든 글자가 한 번씩
	var cyc_bad := 0
	for sd in 50:
		rng.seed = sd
		var qs2: Array = KanaCourse.build_stage_test("h1", rng, true)
		for pass_i in 3:
			var chunk := {}
			for j in 5:
				chunk[qs2[pass_i * 5 + j]["ch"]] = true
			if chunk.size() != 5:
				cyc_bad += 1
	ok(cyc_bad == 0, "5-letter stage cycles: every group of 5 questions has all 5 letters (bad %d)" % cyc_bad)
	# 짝 단계: 읽기/듣기 문제에는 그 글자의 짝이 보기에 들어 있다
	var pair_bad := 0
	var pair_n := 0
	for sid in ["p_h", "p_k"]:
		for sd in 60:
			rng.seed = sd + 77
			for q in KanaCourse.build_stage_test(sid, rng, true):
				if q["kind"] != "type":
					pair_n += 1
					if not q.has("pair") or check_pair_question(q) != "":
						pair_bad += 1
	ok(pair_bad == 0 and pair_n > 0, "pair stages: read/listen questions carry the pair partner in their options (bad %d of %d)" % [pair_bad, pair_n])
	# 일부러 틀린 입력
	rng.seed = 1
	ok(KanaCourse.build_stage_test("zz", rng).is_empty(), "build_stage_test('zz') = []")
	ok(KanaCourse.build_stage_test("", rng).is_empty() and KanaCourse.build_stage_test("h99", rng).is_empty(), "build_stage_test('') and ('h99') = []")
	# 같은 시드는 같은 문제
	var r1 := RandomNumberGenerator.new()
	r1.seed = 424242
	var r2 := RandomNumberGenerator.new()
	r2.seed = 424242
	var a: Array = KanaCourse.build_stage_test("h5", r1)
	var b: Array = KanaCourse.build_stage_test("h5", r2)
	var same := a.size() == b.size()
	for i in mini(a.size(), b.size()):
		same = same and a[i]["ch"] == b[i]["ch"] and a[i]["kind"] == b[i]["kind"]
	ok(same, "same seed -> same test (reproducible)")


func _test_stage_tests_nosound_and_weak() -> void:
	print("[build_stage_test: no sound, weak letters]")
	var rng := RandomNumberGenerator.new()
	var bad := 0
	for sid in KanaCourse.stage_ids():
		for sd in 20:
			rng.seed = sd + 5
			var counts := {"listen": 0, "read": 0, "type": 0}
			for q in KanaCourse.build_stage_test(str(sid), rng, false):
				counts[q["kind"]] = int(counts[q["kind"]]) + 1
			if counts["listen"] != 0 or counts["read"] != 10 or counts["type"] != 5:
				bad += 1
	ok(bad == 0, "sound=false: listen 0, read 10, type 5 for every stage (bad %d)" % bad)
	# 약한 글자 우선: 요음 단계(33글자)에서 약한 글자 5개를 정하면 15문제 안에 모두 나온다
	var yoon: Dictionary = KanaCourse.stage_by_id("h11")
	var chars: Array = yoon["chars"]
	var weak: Array = chars.slice(10, 15)
	var stats := {}
	for ch in chars:
		stats[ch] = [8, 0] ## 숙련 3
	for ch in weak:
		stats[ch] = [1, 4] ## 숙련 1 (약함)
	var miss := 0
	var weak_first_bad := 0
	for sd in SEEDS:
		rng.seed = sd
		var qs: Array = KanaCourse.build_stage_test("h11", rng, true, stats)
		var got := {}
		for q in qs:
			got[q["ch"]] = true
		for ch in weak:
			if not got.has(ch):
				miss += 1
		for i in 5:
			if not weak.has(qs[i]["ch"]):
				weak_first_bad += 1
	ok(miss == 0 and weak_first_bad == 0, "weak letters come first: all 5 weak letters are the first 5 questions (missing %d, not first %d)" % [miss, weak_first_bad])
	# 통계가 이상한 모양이어도 에러 없이 (일부러 틀린 입력)
	var junk := {"あ": "x", "い": [1], "う": null, "え": {"ok": "z"}, "お": [-3, -4]}
	rng.seed = 3
	ok(KanaCourse.build_stage_test("h1", rng, true, junk).size() == 15, "garbage stats do not break the test (still 15 questions)")
	# 숙련 3인 글자만 있으면(약한 글자 없음) 그냥 섞여서 나온다
	var strong := {}
	for ch in chars:
		strong[ch] = {"ok": 9, "bad": 0}
	rng.seed = 4
	ok(KanaCourse.build_stage_test("h11", rng, true, strong).size() == 15, "stats as {ok,bad} dictionaries are accepted")


# ---------------------------------------------------------------- pair sessions (K1-5)

func _test_pair_sessions() -> void:
	print("[build_pair_session]")
	var rng := RandomNumberGenerator.new()
	var bad: Array = []
	var total := 0
	var consec := 0
	var cases: Array = [["hira", []], ["kata", []], ["both", []]]
	for c in cases:
		for sd in SEEDS:
			rng.seed = sd + 31
			var qs: Array = KanaCourse.build_pair_session(c[1], c[0], rng, 10)
			if qs.size() != 10:
				bad.append("size %s %d" % [c[0], qs.size()])
			var last := ""
			for q in qs:
				total += 1
				var why: String = check_pair_question(q)
				if why != "" and bad.size() < 5:
					bad.append("%s seed %d: %s" % [c[0], sd, why])
				if q["ch"] == last:
					consec += 1
				last = q["ch"]
				if q["script"] != c[0] and c[0] != "both":
					bad.append("script mix")
	ok(bad.is_empty(), "%d pair questions (hira/kata/both x %d seeds): answer + partner both in the options, 4 distinct Korean sounds (%s)" % [total, SEEDS, str(bad)])
	ok(consec == 0, "no letter twice in a row in a pair session (bad %d)" % consec)
	# 고른 짝만
	var pid: String = str(KanaCourse.pairs("kata")[0]["id"])
	var only_ok := true
	var both_sides := {}
	for sd in 30:
		rng.seed = sd
		for q in KanaCourse.build_pair_session([pid], "kata", rng, 10):
			only_ok = only_ok and q["pair"] == pid and check_pair_question(q) == ""
			both_sides[q["ch"]] = true
	ok(only_ok and both_sides.size() == 2, "one chosen pair: every question is that pair and both sides appear as the answer (%s)" % str(both_sides.keys()))
	# listen 도 가능, 잘못된 kind 는 read
	rng.seed = 9
	var lq: Array = KanaCourse.build_pair_session([], "hira", rng, 5, "listen")
	var bq: Array = KanaCourse.build_pair_session([], "hira", rng, 5, "zzz")
	ok(lq.size() == 5 and lq[0]["kind"] == "listen" and bq[0]["kind"] == "read", "kind 'listen' is passed through; an unknown kind falls back to 'read'")
	# 일부러 틀린 입력
	ok(KanaCourse.build_pair_session(["nope"], "hira", rng).is_empty(), "unknown pair id -> []")
	ok(KanaCourse.build_pair_session([pid], "hira", rng).is_empty(), "a kata pair id asked with script hira -> []")
	ok(KanaCourse.build_pair_session([], "zzz", rng).is_empty(), "unknown script -> []")
	ok(KanaCourse.build_pair_session([], "hira", rng, 0).is_empty() and KanaCourse.build_pair_session([], "hira", rng, -3).is_empty(), "n = 0 or negative -> []")
	var sq: Array = KanaCourse.build_pair_session([], "kata", rng, 3)
	ok(sq.size() == 3 and (sq[0]["options"] as Array).size() == 4, "n is honoured (3 questions)")


# ---------------------------------------------------------------- typing (K1-6, K1-7)

func _test_typing() -> void:
	print("[KanaTyping]")
	var miss_ro: Array = []
	var miss_ko: Array = []
	for e in KanaData.entries("both"):
		if not KanaTyping.check(e, str(e["ro"])):
			miss_ro.append(e["ch"])
		if not KanaTyping.check(e, str(e["ko"])):
			miss_ko.append(e["ch"])
	ok(miss_ro.is_empty(), "all 208 letters: check(e, e.ro) is true (missing %s)" % str(miss_ro))
	ok(miss_ko.is_empty(), "all 208 letters: check(e, e.ko) is true (missing %s)" % str(miss_ko))
	ok(KanaData.entries("both").size() == 208, "(table has 208 letters)")
	var shi: Dictionary = KanaData.get_entry("し")
	ok(KanaTyping.check(shi, "SHI") and KanaTyping.check(shi, " shi ") and KanaTyping.check(shi, "ｓｈｉ") and KanaTyping.check(shi, "Ｓhi"), "SHI, ' shi ', fullwidth ｓｈｉ are accepted")
	ok(KanaTyping.check(shi, "s h i") and KanaTyping.check(shi, "\tshi\n") and KanaTyping.check(shi, "shi　") and KanaTyping.check(shi, "시"), "inner spaces, tab/newline, ideographic space, 시 are accepted")
	var extra: Dictionary = {
		"し": ["si"], "ち": ["ti"], "つ": ["tu"], "ふ": ["hu"], "じ": ["zi"], "ぢ": ["di", "ji", "zi"], "づ": ["du", "zu"],
		"を": ["wo", "o"], "ん": ["n", "nn", "n'"],
		"しゃ": ["sya"], "しゅ": ["syu"], "しょ": ["syo"], "ちゃ": ["tya", "cha"], "ちゅ": ["tyu", "chu"], "ちょ": ["tyo", "cho"],
		"じゃ": ["zya", "jya", "ja"], "じゅ": ["zyu", "jyu", "ju"], "じょ": ["zyo", "jyo", "jo"],
	}
	var extra_miss: Array = []
	for h in extra:
		for script in ["hira", "kata"]:
			var ch: String = h if script == "hira" else KanaData.to_katakana(h)
			var e: Dictionary = KanaData.get_entry(ch)
			for a in extra[h]:
				if e.is_empty() or not KanaTyping.check(e, str(a)):
					extra_miss.append("%s:%s" % [ch, a])
	ok(extra_miss.is_empty(), "§5.7 extra answers (si ti tu hu zi di du wo nn n' sya tya zya jya ...) for hira and kata (missing %s)" % str(extra_miss))
	ok(KanaTyping.check(KanaData.get_entry("ン"), "NN") and KanaTyping.check(KanaData.get_entry("ン"), "n'"), "ン: NN and n' (katakana follows the hiragana row)")
	ok(KanaTyping.check(KanaData.get_entry("ぢ"), "지") and KanaTyping.check(KanaData.get_entry("づ"), "즈") and KanaTyping.check(KanaData.get_entry("を"), "오"), "ぢ=지, づ=즈, を=오 (same Korean as じ ず お)")
	var tq: Dictionary = KanaCourse.make_type_question(KanaData.get_entry("し"))
	ok(check_type_question(tq) == "" and tq["ch"] == "し" and tq["accept"].has("shi") and tq["accept"].has("si") and tq["accept"].has("시"), "make_type_question: type, no options, answer -1, accept has shi/si/시")
	var acc: Array[String] = KanaTyping.accepted(KanaData.get_entry("か"))
	ok(acc.size() == 2 and acc[0] == "ka" and acc[1] == "카", "accepted(か) = [ka, 카] only (%s)" % str(acc))
	ok(KanaTyping.normalize("  ＳＨＩ ") == "shi" and KanaTyping.normalize("n ' n") == "n'n" and KanaTyping.normalize("시 시") == "시시", "normalize: trim, fullwidth, lowercase, inner spaces removed, apostrophe kept")
	var dup := true
	for e in KanaData.entries("both"):
		var a2: Array[String] = KanaTyping.accepted(e)
		var seen := {}
		for x in a2:
			if seen.has(x):
				dup = false
			seen[x] = true
	ok(dup, "accepted() never lists the same answer twice")


func _test_typing_bad_inputs() -> void:
	print("[KanaTyping: wrong inputs fail]")
	var shi: Dictionary = KanaData.get_entry("し")
	expect_false(KanaTyping.check(shi, ""), "check(し, '')")
	expect_false(KanaTyping.check(shi, "  "), "check(し, '  ')")
	expect_false(KanaTyping.check(KanaData.get_entry("き"), "ka"), "check(き, 'ka')")
	expect_false(KanaTyping.check(shi, "ㅅ"), "check(し, 'ㅅ') (a lone jamo)")
	expect_false(KanaTyping.check(shi, "시시"), "check(し, '시시')")
	expect_false(KanaTyping.check(shi, "shi?"), "check(し, 'shi?')")
	expect_false(KanaTyping.check({}, "a"), "check({}, 'a')")
	expect_false(KanaTyping.check({"ch": "x"}, "x"), "check(entry without ro/ko, 'x')")
	expect_false(KanaTyping.check(shi, "shishi"), "check(し, 'shishi')")
	expect_false(KanaTyping.check(KanaData.get_entry("づ"), "dzu"), "check(づ, 'dzu')")
	expect_false(KanaTyping.check(KanaData.get_entry("は"), "wa"), "check(は, 'wa') (は is ha here)")
	ok(KanaTyping.accepted({}).is_empty(), "accepted({}) = [] without an error")
	ok(KanaTyping.normalize("") == "" and KanaTyping.normalize("   ") == "", "normalize('') and normalize('   ') = ''")
	# 입력 칸이 만드는 흔한 모양: 한글 조합 중인 자모, 로마자 한 글자
	var all_reject := true
	for junk in ["ㅅ", "ㅅㅣ", "s", "sh", "ㅏ", "ㅤ", "し", "あ"]:
		all_reject = all_reject and not KanaTyping.check(shi, junk)
	ok(all_reject, "half-typed input (s, sh, ㅅ, ㅅㅣ) and the kana itself are not accepted as the reading")


# ---------------------------------------------------------------- pass / next (K1-9), K1-12 mutation lives here

func _test_pass_and_next() -> void:
	print("[pass / next_stage]")
	ok(KanaCourse.STAGE_QUESTIONS == 15 and KanaCourse.STAGE_PASS == 12, "constants: 15 questions, pass at 12")
	ok(KanaCourse.is_passed(12, 15), "is_passed(12, 15) = true")
	ok(KanaCourse.is_passed(15, 15) and KanaCourse.is_passed(13, 15), "is_passed(15,15) and (13,15) = true")
	expect_false(KanaCourse.is_passed(11, 15), "is_passed(11, 15)")
	expect_false(KanaCourse.is_passed(0, 0), "is_passed(0, 0)")
	expect_false(KanaCourse.is_passed(0, 15), "is_passed(0, 15)")
	expect_false(KanaCourse.is_passed(16, 15), "is_passed(16, 15) (more right than asked)")
	expect_false(KanaCourse.is_passed(-1, 15), "is_passed(-1, 15)")
	expect_false(KanaCourse.is_passed(4, 4), "is_passed(4, 4) (fewer than 5 questions)")
	ok(KanaCourse.is_passed(4, 5) and KanaCourse.is_passed(8, 10) and not KanaCourse.is_passed(7, 10), "other totals: 80% and at least 5 questions (4/5 yes, 8/10 yes, 7/10 no)")
	var done := {"h1": "2026-11-12", "h2": "2026-11-13"}
	ok(KanaCourse.next_stage("hira", done) == "h3", "next_stage('hira', h1+h2 done) = h3")
	ok(KanaCourse.next_stage("hira", {}) == "h1" and KanaCourse.next_stage("kata", {}) == "k1", "nothing done: h1 / k1")
	ok(KanaCourse.next_stage("both", {}) == "h1" and KanaCourse.next_stage("kata", done) == "k1", "'both' starts at h1; kata is not affected by hira progress")
	var all_h := {}
	for s in KanaCourse.stages("hira"):
		all_h[s["id"]] = "2026-11-14"
	ok(KanaCourse.next_stage("hira", all_h) == "", "all hira stages done -> ''")
	ok(KanaCourse.next_stage("both", all_h) == "k1", "all hira done: 'both' continues with k1")
	var all_done := all_h.duplicate()
	for s in KanaCourse.stages("kata"):
		all_done[s["id"]] = "2026-11-14"
	ok(KanaCourse.next_stage("both", all_done) == "" and KanaCourse.next_stage("kata", all_done) == "", "everything done -> ''")
	var skip := {"h1": "x", "h3": "x"}
	ok(KanaCourse.next_stage("hira", skip) == "h2", "an unfinished stage in the middle is found first (no lock)")
	ok(KanaCourse.next_stage("hira", {"h1": "x", "h2": "x", "h3": "x", "h4": "x", "h5": "x", "h6": "x", "h7": "x", "h8": "x", "h9": "x", "h10": "x", "h11": "x"}) == "p_h", "after h11 the next hira stage is the pair stage p_h")
	ok(KanaCourse.next_stage("zzz", {}) == "", "unknown script -> ''")


# ---------------------------------------------------------------- build_session / weak_letters

func _test_session_type_and_weak() -> void:
	print("[build_session type / weak_letters]")
	var rng := RandomNumberGenerator.new()
	rng.seed = 5
	var qs: Array = KanaCourse.build_session({"kind": "type", "script": "hira", "rows": ["ka"]}, rng, 10)
	var all_type := qs.size() == 10
	var in_ka := true
	for q in qs:
		all_type = all_type and check_type_question(q) == ""
		in_ka = in_ka and ["か", "き", "く", "け", "こ"].has(q["ch"])
	ok(all_type and in_ka, "build_session kind 'type': 10 type questions from the か row only")
	var rq: Array = KanaCourse.build_session({"kind": "read", "script": "kata"}, rng, 10)
	var ok_read := rq.size() == 10
	for q in rq:
		ok_read = ok_read and check_question(q) == "" and q["script"] == "kata"
	ok(ok_read, "build_session kind 'read' is delegated to KanaData (10 valid kata questions)")
	var fq: Array = KanaCourse.build_session({"kind": "type", "script": "kata", "focus": true}, rng, 6)
	ok(fq.size() == 6 and check_type_question(fq[0]) == "", "build_session type + focus (confusable groups) works")
	ok(KanaCourse.build_session({"kind": "type", "script": "hira", "only": ["zz"]}, rng, 5).is_empty(), "no usable letters -> []")
	var only: Array = KanaCourse.build_session({"kind": "type", "script": "hira", "only": ["あ", "い"]}, rng, 4)
	ok(only.size() == 4 and only.all(func(q: Dictionary) -> bool: return q["ch"] == "あ" or q["ch"] == "い"), "build_session type + only[] uses just those letters")
	# weak_letters
	var stats := {
		"あ": [8, 0], # 숙련 3
		"い": [1, 4], # 약함, 틀림 4
		"う": [0, 2], # 약함, 틀림 2
		"え": [2, 4], # 약함(맞힘 2 < 틀림 4 -> 1), 틀림 4, 맞힘 2
		"お": [3, 1], # 숙련 2
		"か": [0, 0], # 푼 적 없음
		"ア": [0, 5], # 가타카나, 틀림 5
	}
	var wl: Array = KanaCourse.weak_letters(stats, "hira", 10)
	ok(wl == ["い", "え", "う"], "weak_letters(hira): most mistakes first, ties by fewer right: %s" % str(wl))
	ok(KanaCourse.weak_letters(stats, "hira", 2) == ["い", "え"], "limit 2 keeps the 2 weakest")
	ok(KanaCourse.weak_letters(stats, "kata", 5) == ["ア"], "weak_letters(kata) only kata letters")
	ok(KanaCourse.weak_letters(stats, "both", 10) == ["ア", "い", "え", "う"], "weak_letters(both) mixes scripts, worst first")
	ok(KanaCourse.weak_letters({}, "hira", 5).is_empty(), "no stats -> []")
	ok(KanaCourse.weak_letters(stats, "hira", 0).is_empty() and KanaCourse.weak_letters(stats, "hira", -1).is_empty(), "limit 0 / negative -> []")
	ok(KanaCourse.weak_letters({"zz": [0, 9], "あ": "bad", "い": [1]}, "hira", 5).is_empty(), "unknown letters and malformed values are ignored")
	var dict_form := {"い": {"ok": 0, "bad": 3}}
	ok(KanaCourse.weak_letters(dict_form, "hira", 5) == ["い"], "{ok, bad} dictionary form works too")


# ---------------------------------------------------------------- static scan (C-4, C-11)

func _test_static_scan() -> void:
	print("[source scan: no network, no emoji, no hard-coded colors]")
	var forbid: Array = ["HTTP" + "Request", "Route" + ".", "OS.shell" + "_open", "OS.request" + "_permission", "Color(\"" + "#", "87" + "70", "87" + "75", "87" + "76", "fla" + "me", "불" + "꽃"]
	var hits: Array = []
	var api_lines := {}
	var emoji_hits := 0
	for f in SRC_FILES:
		var fa := FileAccess.open(str(f), FileAccess.READ)
		if fa == null:
			hits.append("cannot open " + str(f))
			continue
		var text: String = fa.get_as_text()
		fa.close()
		for w in forbid:
			if text.contains(str(w)):
				hits.append("%s contains %s" % [f, w])
		api_lines[f] = text.count("Api" + ".")
		for i in text.length():
			var c: int = text.unicode_at(i)
			if (c >= 0x2600 and c <= 0x27BF) or (c >= 0x1F000 and c <= 0x1FAFF) or c == 0x2605 or c == 0x2606:
				emoji_hits += 1
	ok(hits.is_empty(), "new sources: no http request class, route calls, shell open, permission request, fixed ports or hex colors (%s)" % str(hits))
	var api_ok: bool = int(api_lines.get("res://scripts/core/kana_course.gd", 0)) == 0 and int(api_lines.get("res://scripts/core/kana_typing.gd", 0)) == 0 and int(api_lines.get("res://scripts/core/kana_voice.gd", 0)) <= 1
	ok(api_ok, "the connection state is read only inside kana_voice.gd (once): %s" % str(api_lines))
	ok(emoji_hits == 0, "no emoji or symbol characters in the new sources (%d)" % emoji_hits)
	# 검사기 점검: 금지어가 실제로 들어 있는 글에서는 잡아내는지
	var probe := "var r = HTTP" + "Request.new()"
	fails(probe.contains("HTTP" + "Request"), "scan helper on text that contains the forbidden word")


# ---------------------------------------------------------------- voice (K1-10)

func _tts_hook(text: String, l: String, speed: float, _voice: String) -> Variant:
	tts_calls.append({"text": text, "lang": l, "speed": speed})
	return null


func _test_voice() -> void:
	print("[KanaVoice]")
	var api: Node = get_node("/root/Api")
	var route: Node = get_node("/root/Route")
	var saved_base: String = str(api.base_url)
	var saved_adapter = SystemTts.adapter
	var saved_pref: Variant = Store.prefs.get("tts_engine", "auto")
	var saved_hook: Callable = route.phone_hook
	var saved_prefs := Store.prefs.duplicate(true)
	var sent0: int = int(api.sent_count)
	# 1) PC 엔진(합성 소리 가로채기) + 연결 주소 있음 -> 부탁이 Tts 로 한 번
	Tts.fetch_hook = Callable(self, "_tts_hook")
	api.base_url = "http://127.0.0.1:9" ## 닫힌 포트: 실제 요청은 없고 소리는 hook 이 가로챈다
	tts_calls.clear()
	ok(str(Tts.engine_now()) == "pc" and KanaVoice.available(), "PC engine with an address: available()")
	ok(KanaVoice.speak("あ") == true, "speak('あ') returns true")
	await _frames(3)
	ok(tts_calls.size() == 1 and tts_calls[0]["text"] == "あ" and tts_calls[0]["lang"] == "ja", "...and the fake TTS hook got exactly 1 call: text あ, lang ja (%d calls)" % tts_calls.size())
	ok(KanaVoice.available() == _screen_like_available(), "available() matches the KanaScreen rule (engine system -> ja voice, else address)")
	# 2) PC 엔진 + 주소 없음 -> false, Tts 를 부르지 않음
	api.base_url = ""
	tts_calls.clear()
	ok(not KanaVoice.available(), "PC engine without an address: available() false")
	ok(KanaVoice.speak("あ") == false, "speak('あ') returns false when nothing can play")
	await _frames(3)
	ok(tts_calls.is_empty(), "...and Tts was not called (0 calls)")
	ok(KanaVoice.no_text() == KanaVoice.NO_SOUND_TEXT and KanaVoice.NO_SOUND_TEXT.contains("PC"), "no_text() (PC engine) = the connect-the-PC line")
	# 빈 글은 언제나 false
	api.base_url = "http://127.0.0.1:9"
	ok(KanaVoice.speak("") == false and KanaVoice.speak("   ") == false, "speak('') and speak('   ') = false without calling Tts")
	await _frames(2)
	ok(tts_calls.is_empty(), "empty text never reaches Tts")
	# 3) 폰 단독(시스템 음성): 일본어 음성이 있어야 한다
	Tts.fetch_hook = Callable() ## 시험 hook 이 있으면 엔진이 pc 로 고정된다
	route.phone_hook = func() -> bool: return true
	Store.prefs["tts_engine"] = "system"
	api.base_url = ""
	var vf := VoiceFake.new()
	vf.voices = [{"name": "Kyoko", "id": "ja-a", "language": "ja_JP"}, {"name": "English", "id": "en-a", "language": "en_US"}]
	SystemTts.adapter = vf
	Tts._sys = null
	ok(str(Tts.engine_now()) == "system" and KanaVoice.available(), "phone alone with a Japanese voice: available() true (no address needed)")
	ok(KanaVoice.speak("か") == true, "speak('か') returns true with a Japanese system voice")
	await _frames(2)
	vf.voices = [{"name": "English", "id": "en-a", "language": "en_US"}]
	Tts._sys = null
	ok(not KanaVoice.available() and KanaVoice.speak("か") == false, "only an English voice: available() false, speak() false")
	ok(KanaVoice.no_text() == KanaVoice.NO_VOICE_TEXT and KanaVoice.NO_VOICE_TEXT.contains("일본어 음성"), "no_text() (system engine) = the no-Japanese-voice line")
	ok(not KanaVoice.NO_VOICE_TEXT.contains("\n") and not KanaVoice.NO_SOUND_TEXT.contains("\n") and KanaVoice.NO_VOICE_TEXT != KanaVoice.NO_SOUND_TEXT, "the two notices are single, different lines")
	ok(KanaVoice.NO_SOUND_TEXT == KanaScreen.NO_SOUND_TEXT and KanaVoice.NO_VOICE_TEXT == KanaScreen.NO_VOICE_TEXT, "notice texts are identical to KanaScreen's")
	api.base_url = "http://127.0.0.1:9"
	ok(KanaVoice.available() == KanaScreen.sound_available() and KanaVoice.no_text() == KanaScreen.no_sound_text(), "available()/no_text() agree with KanaScreen (system engine)")
	Store.prefs["tts_engine"] = "pc"
	ok(KanaVoice.available() == KanaScreen.sound_available() and KanaVoice.no_text() == KanaScreen.no_sound_text(), "available()/no_text() agree with KanaScreen (PC engine, address set)")
	api.base_url = ""
	ok(KanaVoice.available() == KanaScreen.sound_available() and KanaVoice.no_text() == KanaScreen.no_sound_text(), "available()/no_text() agree with KanaScreen (PC engine, no address)")
	ok(int(api.sent_count) == sent0, "no request left through the connection layer during the whole voice test")
	# 되돌리기
	SystemTts.adapter = saved_adapter
	Tts._sys = null
	Tts.stop()
	Store.prefs = saved_prefs
	Store.prefs["tts_engine"] = saved_pref
	route.phone_hook = saved_hook
	Tts.fetch_hook = Callable()
	api.base_url = saved_base


## 시험용으로 다시 쓴 판정(KanaScreen.sound_available 과 같은 규칙).
func _screen_like_available() -> bool:
	if str(Tts.engine_now()) == "system":
		return bool(Tts.system_voices_ok().get("ja", false))
	return str(get_node("/root/Api").base_url) != ""
