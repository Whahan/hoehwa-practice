extends Node
## S6a: 병합 단위 시험 (docs/sync_design.md §4.4 · §9.1 · §10.4 U01~U30, 예 A·B, 부록 A S2/S6).
## 문서만 보고 작성했다. 구현(sync_doc.gd, sync_merge.gd)은 실행 시점에만 load 하고, 이 파일은
## SyncMerge / SyncDoc / StreakCalc 을 class_name 으로 직접 참조하지 않는다(구현이 없어도 이 파일은 파싱되어
## "SyncMerge 없음"을 보고한다). 순수 함수만 호출하고 파일은 쓰지 않는다.
##   godot --headless --path <project> res://tests/sync_merge_test.tscn
## 종료코드: 0 = 전부 통과, 1 = 실패 있음(로드 실패 포함), 2 = SyncMerge/SyncDoc 파일 없음(미실행, S2 대기).
## 마지막 줄: "== sync merge: N passed, M failed ==" (미실행이면 "== sync merge: NOT RUN (...) ==").

const MERGE_PATH := "res://scripts/sync/sync_merge.gd"
const DOC_PATH := "res://scripts/sync/sync_doc.gd"
const STREAK_PATH := "res://scripts/core/streak_calc.gd"
const T0 := 1760000000
const PC_ID := "a1b2c3d4e5f60718"
const PH_ID := "b2c3d4e5f6071829"
const PH2_ID := "c3d4e5f607182930"
const PH3_ID := "d4e5f60718293041"
const DAY := 86400
const SHARED_PREFS := ["auto_fix_cards", "daily_goal_min", "lesson_source", "tts_speed", "tts_voice_en", "tts_voice_ja"]

var passed := 0
var failed := 0
var M = null   # SyncMerge (실행 시 load)
var D = null   # SyncDoc (실행 시 load)
var SC = null  # StreakCalc (core, 기존 파일)


func _ready() -> void:
	var miss: Array = []
	var broken: Array = []
	for pair in [["SyncMerge", MERGE_PATH], ["SyncDoc", DOC_PATH]]:
		if not ResourceLoader.exists(pair[1]):
			miss.append(pair[0])
		elif load(pair[1]) == null:
			broken.append(pair[0])
	if not broken.is_empty():
		print("로드 실패(파싱 오류 가능): %s" % ", ".join(PackedStringArray(broken)))
		print("== sync merge: 0 passed, 1 failed (로드 실패: %s) ==" % ", ".join(PackedStringArray(broken)))
		get_tree().quit(1)
		return
	if not miss.is_empty():
		print("SyncMerge 없음 - 미실행. 없는 파일: %s" % ", ".join(PackedStringArray(miss)))
		print("== sync merge: NOT RUN (%s 없음, S2 대기) ==" % ", ".join(PackedStringArray(miss)))
		get_tree().quit(2)
		return
	M = load(MERGE_PATH)
	D = load(DOC_PATH)
	SC = load(STREAK_PATH)
	run_all()
	print("== sync merge: %d passed, %d failed ==" % [passed, failed])
	get_tree().quit(1 if failed > 0 else 0)


func run_all() -> void:
	print("[U01~U06 합집합·이중계산·멱등·교환·수렴]")
	u01(); u02(); u03(); u04(); u05(); u06()
	print("[U07~U09 삭제 전파·재추가·동시 tie]")
	u07(); u08(); u09()
	print("[U10~U13 카드]")
	u10(); u11(); u12(); u13()
	print("[U14~U16 날짜 시간·잎·미션, U15b 로컬 감소 시 몫]")
	u14(); u15(); u15b(); u16()
	print("[U17~U19 보호권·연속·음소]")
	u17(); u18(); u19()
	print("[U20 시계]")
	u20()
	print("[U21~U25 스키마·깨진 입력·검사기·무작위]")
	u21(); u22(); u23(); u24(); u25()
	print("[U26~U30 설정·단어·시작일·rebase·항등]")
	u26(); u27(); u28(); u29(); u30()
	print("[M-04 입력 불변, M-05 성능]")
	m04(); m05()


# ---------------------------------------------------------------- 공통 helper

func ok(cond: bool, name: String, detail: String = "") -> void:
	if cond:
		passed += 1
		print("  PASS  ", name)
	else:
		failed += 1
		print("  FAIL  ", name, ("  -> " + detail) if detail != "" else "")


func rnd(a: Dictionary) -> Dictionary:
	var r = M.call("sync_round", a)
	if typeof(r) != TYPE_DICTIONARY:
		return {}
	return r


func canon(v) -> String:
	return str(M.call("canonical", v))


func _view(r: Dictionary) -> Dictionary:
	var v = r.get("view", {})
	return v if typeof(v) == TYPE_DICTIONARY else {}


func _dig(d, path: Array, default = null):
	var cur = d
	for k in path:
		if typeof(cur) == TYPE_DICTIONARY and cur.has(k):
			cur = cur[k]
		elif typeof(cur) == TYPE_ARRAY and typeof(k) == TYPE_INT and k >= 0 and k < cur.size():
			cur = cur[k]
		else:
			return default
	return cur


func _sorted(a) -> Array:
	var b: Array = []
	if typeof(a) == TYPE_ARRAY:
		b = a.duplicate()
	b.sort()
	return b


func _unique(a: Array) -> Array:
	var seen := {}
	var out: Array = []
	for x in a:
		if not seen.has(x):
			seen[x] = true
			out.append(x)
	return out


func _has(view: Dictionary, field: String, key) -> bool:
	var a = view.get(field, [])
	return typeof(a) == TYPE_ARRAY and a.has(key)


func _find_card(view: Dictionary, key: String) -> Dictionary:
	for c in view.get("cards", []):
		if typeof(c) == TYPE_DICTIONARY and c.get("key", "") == key:
			return c
	return {}


func _card_keys(view: Dictionary) -> Array:
	var out: Array = []
	for c in view.get("cards", []):
		out.append(c.get("key", ""))
	out.sort()
	return out


func _card_index(cards: Array, key: String) -> int:
	for i in range(cards.size()):
		if cards[i].get("key", "") == key:
			return i
	return -1


func _sec(view, day: String, lang: String = "en") -> int:
	return int(_dig(view, ["days", day, lang, "sec"], -1))


func _numok(x) -> bool:
	return typeof(x) == TYPE_INT and x >= 0 and x <= 9007199254740992


func _rep(ch: String, n: int) -> String:
	var s := ""
	for i in range(n):
		s += ch
	return s


## 달력 날짜 -> 일 번호(1970-01-01 = 0). Plan.days_from_civil 과 같은 규칙을 시험 안에 따로 적었다.
func _day(iso: String) -> int:
	var p := iso.split("-")
	var y := int(p[0])
	var m := int(p[1])
	var d := int(p[2])
	if m <= 2:
		y -= 1
	var era := y / 400
	var yoe := y - era * 400
	var mp := (m + 9) % 12
	var doy := (153 * mp + 2) / 5 + d - 1
	var doe := yoe * 365 + yoe / 4 - yoe / 100 + doy
	return era * 146097 + doe - 719468


func _dup(v):
	if typeof(v) == TYPE_DICTIONARY or typeof(v) == TYPE_ARRAY:
		return v.duplicate(true)
	return v


func _args(own, local, base, peers: Array, stamp: int, rebase = null) -> Dictionary:
	return {
		"own": _dup(own), "local": _dup(local), "base": _dup(base), "peers": peers,
		"stamp": stamp, "hub_now": stamp, "today": _day("2026-10-17"), "rebase": _dup(rebase),
	}


func _peer(id: String, doc, saved: int = T0 + 1000) -> Dictionary:
	return {"device_id": id, "saved_hub": saved, "doc": doc}


func _skip_reason(r: Dictionary, id: String) -> String:
	for e in _dig(r, ["report", "peers_skipped"], []):
		if typeof(e) == TYPE_DICTIONARY and e.get("device_id", "") == id:
			return str(e.get("reason", ""))
	return ""


func _blank_prefs() -> Dictionary:
	return {"daily_goal_min": 10, "lesson_source": "tatoeba", "auto_fix_cards": true,
		"tts_voice_en": "af_heart", "tts_voice_ja": "jf_alpha", "tts_speed": 1.0}


## 지역 뷰(§4.2) 빈 값. 키 이름·형식은 문서 그대로.
func _blank_local() -> Dictionary:
	return {
		"start": "2026-11-01", "checks": [], "marks": [],
		"xp": {"en": 0, "ja": 0},
		"stats": {"en": {"lessons": 0, "talks": 0}, "ja": {"lessons": 0, "talks": 0}},
		"cards": [], "known": {"en": [], "ja": []}, "days": {},
		"phon": {"en": {}, "ja": {}}, "missions": {}, "prefs": _blank_prefs(),
	}


## 카드 데이터(키 제외). key 는 "en|문장" 형식.
func _cdata(key: String, id: String, reps: int, last: int, stab: float = 2.0, note: String = "", due: int = T0) -> Dictionary:
	var lang := key.substr(0, 2)
	var target := key.substr(3)
	return {"id": id, "lang": lang, "target": target, "reading": "", "ko": "", "note": note,
		"due": due, "stability": stab, "difficulty": 5.0, "state": 2, "step": 0,
		"last_review": last, "reps": reps, "lapses": 0}


## 지역 뷰의 카드 한 장(key 포함).
func _card(key: String, id: String, reps: int, last: int, stab: float = 2.0, due: int = T0) -> Dictionary:
	var c := _cdata(key, id, reps, last, stab, "", due)
	c["key"] = key
	return c


func _rec(sec: int, by: Dictionary, n: Dictionary, lesson: Array, score: Array) -> Dictionary:
	return {"sec": sec, "by": by, "n": n, "lesson": lesson, "score": score}


## 복제본 문서(§4.3) 빈 값. 시험 입력용 "남의 복제본"을 손으로 만들 때 쓴다.
func _blank_doc() -> Dictionary:
	return {
		"v": 1,
		"progress": {
			"start": {"value": "2026-11-01", "t": 0},
			"checks": {"add": {}, "del": {}},
			"marks": {"add": {}, "del": {}},
			"xp": {"en": 0, "ja": 0},
			"stats": {"en": {"lessons": 0, "talks": 0}, "ja": {"lessons": 0, "talks": 0}},
			"cards": {"add": {}, "del": {}, "data": {}},
			"known": {"en": {"add": {}, "del": {}}, "ja": {"add": {}, "del": {}}},
		},
		"studylog": {"days": {}, "phon": {"en": {}, "ja": {}}, "missions": {}},
		"prefs": {
			"daily_goal_min": {"value": 10, "t": 0}, "lesson_source": {"value": "tatoeba", "t": 0},
			"auto_fix_cards": {"value": true, "t": 0}, "tts_voice_en": {"value": "af_heart", "t": 0},
			"tts_voice_ja": {"value": "jf_alpha", "t": 0}, "tts_speed": {"value": 1.0, "t": 0},
		},
	}


func _set_day(doc: Dictionary, day: String, lang: String, rec: Dictionary) -> void:
	if not doc["studylog"]["days"].has(day):
		doc["studylog"]["days"][day] = {}
	doc["studylog"]["days"][day][lang] = rec


## base 를 만든다(§4.4): 지역 뷰에서 cards.data·prefs 를 뺀 것, 카드는 키 배열.
func _base_of(view: Dictionary) -> Dictionary:
	var b: Dictionary = view.duplicate(true)
	b.erase("prefs")
	var keys: Array = []
	for c in view.get("cards", []):
		keys.append(c.get("key", ""))
	b["cards"] = keys
	return b


## 시험용 기기 상태: 자기 own(복제본), 지금 local(지역 뷰), base, 마지막으로 올린 시각 saved.
func _new_dev(id: String) -> Dictionary:
	return {"id": id, "own": {}, "local": _blank_local(), "base": {}, "saved": 0}


## 기기 한 라운드: 남의 own 을 peers 로 받고, 결과를 기기 상태에 반영(= 적용 후 base 재추출, §7.3).
func _sync(dev: Dictionary, others: Array, stamp: int) -> Dictionary:
	var peers: Array = []
	for o in others:
		peers.append({"device_id": o["id"], "saved_hub": o["saved"], "doc": o["own"]})
	var r := rnd(_args(dev["own"], dev["local"], dev["base"], peers, stamp))
	if r.get("ok", false) == true:
		dev["own"] = r["own"]
		dev["local"] = _view(r)
		dev["base"] = _base_of(dev["local"])
	dev["saved"] = stamp
	return r


func _rich_pc() -> Dictionary:
	var v := _blank_local()
	v["checks"] = ["en-1-w0"]
	v["marks"] = ["2026-10-15|en"]
	v["xp"] = {"en": 120, "ja": 0}
	v["stats"] = {"en": {"lessons": 3, "talks": 1}, "ja": {"lessons": 0, "talks": 0}}
	v["cards"] = [_card("en|I went home", "1a2b3c", 4, 1759900000, 2.3, T0)]
	v["known"] = {"en": ["go"], "ja": []}
	v["days"] = {"2026-10-15": {"en": _rec(600, {"lesson": 300}, {"lessons": 1}, [3, 5], [2, 160])}}
	v["missions"] = {"cafe_order": {"stars": 2, "plays": 3, "last": "2026-10-16", "done_goals": 2}}
	return v


func _rich_ph() -> Dictionary:
	var v := _blank_local()
	v["checks"] = ["en-2-w0"]
	v["marks"] = ["2026-10-16|ja"]
	v["xp"] = {"en": 0, "ja": 40}
	v["stats"] = {"en": {"lessons": 0, "talks": 0}, "ja": {"lessons": 2, "talks": 0}}
	v["cards"] = [_card("ja|家に帰る", "9f8e7d", 2, 1759950000, 3.1, T0)]
	v["known"] = {"en": ["see"], "ja": ["家"]}
	v["days"] = {"2026-10-16": {"ja": _rec(300, {}, {"lessons": 1}, [1, 2], [0, 0])}}
	v["phon"] = {"en": {"th": {"h": "0110", "heard": {"s": 5}}}, "ja": {}}
	v["missions"] = {"cafe_order": {"stars": 3, "plays": 1, "last": "2026-10-15", "done_goals": 1}}
	return v


func _progress_fixture() -> Dictionary:
	return {
		"start": "2026-11-01", "checks": {"en-1-w0": true}, "days": {"2026-10-15": {"en": true}},
		"xp": {"en": 10, "ja": 0}, "stats": {"en": {"lessons": 1, "talks": 0}, "ja": {"lessons": 0, "talks": 0}},
		"review": [{"id": "c1", "lang": "en", "target": "I went home", "reading": "", "ko": "", "note": "",
			"due": 1760000000, "stability": 2.3, "difficulty": 5.1, "state": 2, "step": 0,
			"last_review": 1759900000, "reps": 4, "lapses": 0}],
		"known_words": {"en": ["go"], "ja": []}, "updatedAt": 0,
	}


func _studylog_fixture(freeze: Dictionary) -> Dictionary:
	return {"v": 1, "saved": 0, "days": {}, "phon": {"en": {}, "ja": {}}, "freeze": freeze, "missions": {}}


## 무작위 시나리오용: 지역 뷰를 한 번 흔든다(정렬 유지).
func _mutate(v: Dictionary, rng: RandomNumberGenerator) -> void:
	var checks: Array = v["checks"]
	if rng.randf() < 0.5:
		var ck := "en-%d-w0" % rng.randi_range(1, 9)
		if not checks.has(ck):
			checks.append(ck)
	elif not checks.is_empty():
		checks.remove_at(rng.randi_range(0, checks.size() - 1))
	checks.sort()
	v["xp"]["en"] = int(v["xp"]["en"]) + rng.randi_range(0, 20)
	var cards: Array = v["cards"]
	var pool := ["en|w1", "en|w2", "en|w3", "en|w4", "en|w5"]
	var k: String = pool[rng.randi_range(0, pool.size() - 1)]
	var idx := _card_index(cards, k)
	if idx < 0 and rng.randf() < 0.6:
		cards.append(_card(k, "id" + k.substr(3), rng.randi_range(1, 4), T0 - 1000 + rng.randi_range(0, 500)))
	elif idx >= 0 and rng.randf() < 0.3:
		cards.remove_at(idx)
	cards.sort_custom(func(a, b): return a["key"] < b["key"])
	var known: Array = v["known"]["en"]
	var w: String = ["go", "see", "run"][rng.randi_range(0, 2)]
	if known.has(w):
		if rng.randf() < 0.3:
			known.erase(w)
	elif rng.randf() < 0.5:
		known.append(w)
	known.sort()
	var day := "2026-10-1%d" % rng.randi_range(1, 5)
	if not v["days"].has(day):
		v["days"][day] = {"en": _rec(0, {}, {}, [0, 0], [0, 0])}
	v["days"][day]["en"]["sec"] = int(v["days"][day]["en"]["sec"]) + rng.randi_range(0, 300)
	var m: Dictionary = v["missions"]
	if not m.has("cafe_order"):
		m["cafe_order"] = {"stars": 0, "plays": 0, "last": "2026-10-01", "done_goals": 0}
	m["cafe_order"]["stars"] = maxi(int(m["cafe_order"]["stars"]), rng.randi_range(0, 3))
	m["cafe_order"]["plays"] = int(m["cafe_order"]["plays"]) + rng.randi_range(0, 1)


# ---------------------------------------------------------------- U01~U06

func u01() -> void:
	var pc := _new_dev(PC_ID)
	var ph := _new_dev(PH_ID)
	pc["local"]["checks"] = ["en-1-w0", "en-2-w0"]
	ph["local"]["checks"] = ["en-2-w0", "en-3-w0"]
	_sync(pc, [], T0 + 10)
	var r := _sync(ph, [pc], T0 + 20)
	var got := _sorted(_dig(_view(r), ["checks"], []))
	ok(canon(got) == canon(["en-1-w0", "en-2-w0", "en-3-w0"]), "U01 첫 동기화 합집합 checks = {a,b,c}", canon(got))
	ok(got.count("en-2-w0") == 1, "U01 공통 항목 b 는 한 번만", canon(got))


func u02() -> void:
	var pc := _new_dev(PC_ID)
	var ph := _new_dev(PH_ID)
	pc["local"]["cards"] = [_card("en|X", "x1", 1, 100), _card("en|Y", "y1", 1, 100)]
	ph["local"]["cards"] = [_card("en|Y", "y1", 1, 100), _card("en|Z", "z1", 1, 100)]
	_sync(pc, [], T0 + 10)
	var r := _sync(ph, [pc], T0 + 20)
	var keys := _card_keys(_view(r))
	ok(canon(keys) == canon(["en|X", "en|Y", "en|Z"]), "U02 합집합 카드 {X,Y,Z}", canon(keys))
	ok(keys.size() == 3 and _unique(keys).size() == 3, "U02 Y 는 한 장만(키 중복 없음)", canon(keys))


func u03() -> void:
	var day := "2026-10-17"
	var pc := _new_dev(PC_ID)
	var ph := _new_dev(PH_ID)
	pc["local"]["days"] = {day: {"en": _rec(600, {}, {}, [0, 0], [0, 0])}}
	var r1 := _sync(pc, [], T0 + 10)                   # 예 A 1: PC 600
	ph["local"]["days"] = {day: {"en": _rec(300, {}, {}, [0, 0], [0, 0])}}
	var r2 := _sync(ph, [pc], T0 + 20)                 # 예 A 2: 폰 view 900
	var r3 := _sync(pc, [ph], T0 + 30)                 # 예 A 3: PC delta 0, view 900
	ok(_sec(_view(r1), day) == 600, "U03 예A-1 PC 단독 600", str(_sec(_view(r1), day)))
	ok(_sec(_view(r2), day) == 900, "U03 예A-2 폰 라운드 view 900", str(_sec(_view(r2), day)))
	ok(_sec(_view(r3), day) == 900, "U03 예A-3 PC 라운드 view 900(delta 0)", str(_sec(_view(r3), day)))
	pc["local"] = _dup(pc["local"])
	pc["local"]["days"][day]["en"]["sec"] = 960        # 예 A 4: PC 가 60초 더 공부
	var r4 := _sync(pc, [ph], T0 + 40)
	ok(_sec(_view(r4), day) == 960, "U03 예A-4 PC +60 → view 960", str(_sec(_view(r4), day)))
	var r5 := _sync(ph, [pc], T0 + 50)                 # 예 A 5: 폰 라운드
	ok(_sec(_view(r5), day) == 960 and _sec(ph["local"], day) == 960 and _sec(pc["local"], day) == 960,
		"U03 예A-5 양쪽 960 (이중 계산 1860 아님)", str([_sec(ph["local"], day), _sec(pc["local"], day)]))


func u04() -> void:
	var pc := _new_dev(PC_ID)
	pc["local"] = _rich_pc()
	var ph := _new_dev(PH_ID)
	ph["local"] = _rich_ph()
	_sync(ph, [], T0 + 10)
	var peers := [_peer(PH_ID, ph["own"], T0 + 10)]
	var r1 := rnd(_args(pc["own"], pc["local"], pc["base"], peers, T0 + 20))
	var r2 := rnd(_args(pc["own"], pc["local"], pc["base"], peers, T0 + 20))
	ok(canon(r1.get("own", {})) == canon(r2.get("own", {})) and canon(_view(r1)) == canon(_view(r2)),
		"U04 같은 입력 2번 → own·view 동일")
	var r3 := rnd(_args(r1["own"], _view(r1), _base_of(_view(r1)), peers, T0 + 20))
	ok(canon(r3.get("own", {})) == canon(r1.get("own", {})) and canon(_view(r3)) == canon(_view(r1)),
		"U04 결과를 다시 입력으로 넣은 3번째 → own·view 동일")


func u05() -> void:
	var da := _new_dev("aa11bb22cc33dd44")
	var db := _new_dev("bb22cc33dd44ee55")
	var dc := _new_dev("cc33dd44ee55ff66")
	var dd := _new_dev("dd44ee55ff660077")
	da["local"]["checks"] = ["en-1-w0"]
	da["local"]["xp"] = {"en": 3, "ja": 0}
	db["local"]["checks"] = ["en-2-w0"]
	db["local"]["marks"] = ["2026-10-14|ja"]
	dc["local"]["known"] = {"en": ["see"], "ja": []}
	dc["local"]["cards"] = [_card("en|C1", "c1", 1, 100)]
	dd["local"]["checks"] = ["en-4-w0"]
	_sync(da, [], T0 + 10)
	_sync(db, [], T0 + 11)
	_sync(dc, [], T0 + 12)
	var devs := [da, db, dc]
	var perms := [[0, 1, 2], [0, 2, 1], [1, 0, 2], [1, 2, 0], [2, 0, 1], [2, 1, 0]]
	var canons: Array = []
	var first_checks: Array = []
	for p in perms:
		var peers: Array = []
		for i in p:
			peers.append(_peer(devs[i]["id"], devs[i]["own"], devs[i]["saved"]))
		var r := rnd(_args(dd["own"], dd["local"], dd["base"], peers, T0 + 20))
		canons.append(canon(_view(r)))
		if first_checks.is_empty():
			first_checks = _sorted(_dig(_view(r), ["checks"], []))
	var same := true
	for c in canons:
		if c != canons[0]:
			same = false
	ok(same, "U05 peers 3개 6가지 순열 → view canonical 모두 동일")
	ok(canon(first_checks) == canon(["en-1-w0", "en-2-w0", "en-4-w0"]), "U05 (보조) 병합 내용 확인", canon(first_checks))


func u06() -> void:
	var pc := _new_dev(PC_ID)
	var ph := _new_dev(PH_ID)
	pc["local"]["checks"] = ["en-1-w0"]
	pc["local"]["xp"] = {"en": 10, "ja": 0}
	ph["local"]["checks"] = ["en-2-w0"]
	ph["local"]["xp"] = {"en": 5, "ja": 0}
	ph["local"]["cards"] = [_card("en|Q", "q1", 1, 100)]
	_sync(pc, [], T0 + 10)
	_sync(ph, [pc], T0 + 20)
	_sync(pc, [ph], T0 + 30)
	_sync(ph, [pc], T0 + 40)
	_sync(pc, [ph], T0 + 50)
	_sync(ph, [pc], T0 + 60)
	ok(canon(pc["local"]) == canon(ph["local"]), "U06 PC·폰 교대 두 번씩 → 두 기기 view 동일")


# ---------------------------------------------------------------- U07~U09

## U07/U08 공용: PC 가 체크 a 를 올림 → 폰이 받음 → PC 가 해제.
func _del_scenario() -> Dictionary:
	var pc := _new_dev(PC_ID)
	var ph := _new_dev(PH_ID)
	pc["local"]["checks"] = ["en-1-w0"]
	_sync(pc, [], T0 + 10)
	_sync(ph, [pc], T0 + 20)
	pc["local"]["checks"] = []
	_sync(pc, [ph], T0 + 30)
	var r := _sync(ph, [pc], T0 + 40)
	return {"pc": pc, "ph": ph, "r": r}


func u07() -> void:
	var s := _del_scenario()
	ok(not _has(_view(s["r"]), "checks", "en-1-w0"), "U07 PC 가 해제한 a 는 폰 병합 결과에서 없음")
	ok(not _has(s["pc"]["local"], "checks", "en-1-w0"), "U07 (보조) PC 쪽도 a 없음")


func u08() -> void:
	var s := _del_scenario()
	var ph: Dictionary = s["ph"]
	var pc: Dictionary = s["pc"]
	ph["local"]["checks"] = ["en-1-w0"]                # 삭제 뒤 다시 체크(더 늦은 add)
	var r := _sync(ph, [pc], T0 + 50)
	ok(_has(_view(r), "checks", "en-1-w0"), "U08 삭제 후 재추가(더 늦은 add) → 있음")
	var r2 := _sync(pc, [ph], T0 + 60)
	ok(_has(_view(r2), "checks", "en-1-w0"), "U08 (보조) PC 쪽도 다시 있음")


func u09() -> void:
	var da := _blank_doc()
	da["progress"]["checks"]["add"]["en-7-w0"] = T0 + 50
	var db := _blank_doc()
	db["progress"]["checks"]["del"]["en-7-w0"] = T0 + 50
	var r1 := rnd(_args({}, _blank_local(), {}, [_peer(PH_ID, da, T0 + 100), _peer(PH2_ID, db, T0 + 100)], T0 + 100))
	var r2 := rnd(_args({}, _blank_local(), {}, [_peer(PH2_ID, db, T0 + 100), _peer(PH_ID, da, T0 + 100)], T0 + 100))
	ok(_has(_view(r1), "checks", "en-7-w0"), "U09 동시 삭제/추가(같은 시각) → 있음(추가 우선)")
	ok(canon(_view(r1)) == canon(_view(r2)), "U09 피어 순서를 바꿔도 동일")


# ---------------------------------------------------------------- U10~U13 카드

func u10() -> void:
	var da := _blank_doc()
	da["progress"]["cards"]["add"]["en|W"] = T0
	da["progress"]["cards"]["data"]["en|W"] = _cdata("en|W", "w1", 5, 1000)
	var db := _blank_doc()
	db["progress"]["cards"]["add"]["en|W"] = T0
	db["progress"]["cards"]["data"]["en|W"] = _cdata("en|W", "w2", 6, 900)
	var r := rnd(_args({}, _blank_local(), {}, [_peer(PH_ID, da, T0 + 100), _peer(PH2_ID, db, T0 + 100)], T0 + 100))
	var c := _find_card(_view(r), "en|W")
	ok(c.get("reps", -1) == 6 and c.get("last_review", -1) == 900, "U10 reps 6(last 900) 승, reps 5(last 1000) 짐",
		str(c))


func u11() -> void:
	var a := _cdata("en|K", "k", 5, 1000, 2.0)
	var b := _cdata("en|K", "k", 5, 900, 2.0)
	ok(M.call("card_wins", a, b) == true and M.call("card_wins", b, a) == false,
		"U11 같은 reps: last_review 늦은 쪽 승")
	var c := _cdata("en|K", "k", 5, 1000, 3.0)
	var d := _cdata("en|K", "k", 5, 1000, 2.0)
	ok(M.call("card_wins", c, d) == true and M.call("card_wins", d, c) == false,
		"U11 같은 reps·last: stability 큰 쪽 승")
	var e := _cdata("en|K", "k", 5, 1000, 2.0, "x")
	var f := _cdata("en|K", "k", 5, 1000, 2.0, "y")
	var ef: bool = M.call("card_wins", e, f) == true
	var fe: bool = M.call("card_wins", f, e) == true
	ok(ef != fe, "U11 모두 같고 내용만 다름: 정확히 한쪽만 승(사전순)")
	ok(M.call("card_wins", a, a) == false, "U11 같은 카드끼리는 false")
	var g := _cdata("en|K", "k", 6, 900, 2.0)
	ok(M.call("card_wins", g, a) == true, "U11 reps 가 last_review 보다 먼저 본다(6/900 > 5/1000)")
	# 동률 쌍을 피어 순서 바꿔 병합해도 같은 결과
	var da := _blank_doc()
	da["progress"]["cards"]["add"]["en|K"] = T0
	da["progress"]["cards"]["data"]["en|K"] = e
	var db := _blank_doc()
	db["progress"]["cards"]["add"]["en|K"] = T0
	db["progress"]["cards"]["data"]["en|K"] = f
	var r1 := rnd(_args({}, _blank_local(), {}, [_peer(PH_ID, da, T0 + 100), _peer(PH2_ID, db, T0 + 100)], T0 + 100))
	var r2 := rnd(_args({}, _blank_local(), {}, [_peer(PH2_ID, db, T0 + 100), _peer(PH_ID, da, T0 + 100)], T0 + 100))
	ok(canon(_view(r1)) == canon(_view(r2)), "U11 (보조) 동률 카드의 병합 결과는 피어 순서와 무관")


func u12() -> void:
	var lo := _blank_local()
	lo["cards"] = [_card("en|X", "L1", 1, 100)]
	var dp := _blank_doc()
	dp["progress"]["cards"]["add"]["en|X"] = T0 + 5
	dp["progress"]["cards"]["data"]["en|X"] = _cdata("en|X", "P9", 1, 100)
	dp["progress"]["cards"]["add"]["en|Z"] = T0 + 5
	dp["progress"]["cards"]["data"]["en|Z"] = _cdata("en|Z", "L1", 1, 100)
	var r := rnd(_args({}, lo, {}, [_peer(PH_ID, dp)], T0 + 10))
	var x := _find_card(_view(r), "en|X")
	var z := _find_card(_view(r), "en|Z")
	ok(x.get("id", "") == "L1", "U12 같은 키 X: 로컬 id L1 유지", str(x.get("id", "")))
	ok(str(z.get("id", "")) != "" and z.get("id", "") != "L1", "U12 폰에서만 온 Z 는 로컬 id L1 과 겹치지 않게 바뀜",
		str(z.get("id", "")))
	var ids: Array = []
	for c in _view(r).get("cards", []):
		ids.append(c.get("id", ""))
	ok(_unique(ids).size() == ids.size(), "U12 (보조) 병합 뒤 카드 id 전부 유일", str(ids))


func u13() -> void:
	var dd := _blank_doc()
	dd["progress"]["cards"]["del"]["en|X"] = 100
	var dp := _blank_doc()
	dp["progress"]["cards"]["add"]["en|X"] = 50
	dp["progress"]["cards"]["data"]["en|X"] = _cdata("en|X", "x1", 2, 40)
	var r1 := rnd(_args({}, _blank_local(), {}, [_peer(PC_ID, dd, 200), _peer(PH_ID, dp, 200)], 200))
	ok(not _card_keys(_view(r1)).has("en|X"), "U13 PC 삭제(100) > 폰 add(50) → 삭제됨")
	var dp2 := _blank_doc()
	dp2["progress"]["cards"]["add"]["en|X"] = 150
	dp2["progress"]["cards"]["data"]["en|X"] = _cdata("en|X", "x1", 2, 40)
	var r2 := rnd(_args({}, _blank_local(), {}, [_peer(PC_ID, dd, 200), _peer(PH_ID, dp2, 200)], 200))
	ok(_card_keys(_view(r2)).has("en|X"), "U13 폰 add(150) > PC 삭제(100) → 있음")


# ---------------------------------------------------------------- U14~U16

func u14() -> void:
	var day := "2026-10-17"
	var day2 := "2026-10-18"
	var a := _blank_doc()
	_set_day(a, day, "en", _rec(600, {}, {}, [0, 0], [0, 0]))
	var b := _blank_doc()
	_set_day(b, day, "en", _rec(300, {}, {}, [0, 0], [0, 0]))
	var r1 := rnd(_args({}, _blank_local(), {}, [_peer(PC_ID, a, T0 + 100), _peer(PH_ID, b, T0 + 100)], T0 + 100))
	ok(_sec(_view(r1), day) == 900, "U14 같은 날: PC 600 + 폰 300 = 900", str(_sec(_view(r1), day)))
	var c := _blank_doc()
	_set_day(c, day, "en", _rec(50000, {}, {}, [0, 0], [0, 0]))
	var d := _blank_doc()
	_set_day(d, day, "en", _rec(50000, {}, {}, [0, 0], [0, 0]))
	var r2 := rnd(_args({}, _blank_local(), {}, [_peer(PC_ID, c, T0 + 100), _peer(PH_ID, d, T0 + 100)], T0 + 100))
	ok(_sec(_view(r2), day) == 86400, "U14 합이 86400 초과 → 86400 으로 잘림", str(_sec(_view(r2), day)))
	var e := _blank_doc()
	_set_day(e, day, "en", _rec(600, {}, {}, [0, 0], [0, 0]))
	var f := _blank_doc()
	_set_day(f, day2, "en", _rec(300, {}, {}, [0, 0], [0, 0]))
	var r3 := rnd(_args({}, _blank_local(), {}, [_peer(PC_ID, e, T0 + 100), _peer(PH_ID, f, T0 + 100)], T0 + 100))
	ok(_sec(_view(r3), day) == 600 and _sec(_view(r3), day2) == 300, "U14 다른 날: 각 날이 그대로(600 / 300)")


func u15() -> void:
	var day := "2026-10-17"
	var a := _blank_doc()
	_set_day(a, day, "en", _rec(0, {"lesson": 300}, {"lessons": 1}, [3, 5], [2, 160]))
	var b := _blank_doc()
	_set_day(b, day, "en", _rec(0, {"lesson": 200}, {"lessons": 2}, [1, 2], [1, 90]))
	var peers := [_peer(PC_ID, a, T0 + 100), _peer(PH_ID, b, T0 + 100)]
	var r1 := rnd(_args({}, _blank_local(), {}, peers, T0 + 100))
	var v := _view(r1)
	var rec = _dig(v, ["days", day, "en"], {})
	ok(_dig(rec, ["by", "lesson"]) == 500 and _dig(rec, ["n", "lessons"]) == 3,
		"U15 by·n 의 잎 전부 합", canon(rec))
	ok(canon(_dig(rec, ["lesson"], [])) == canon([4, 7]) and canon(_dig(rec, ["score"], [])) == canon([3, 250]),
		"U15 lesson·score 의 잎 전부 합", canon(rec))
	var r2 := rnd(_args(r1["own"], _view(r1), _base_of(v), peers, T0 + 100))
	ok(canon(_view(r2)) == canon(v), "U15 두 번째 라운드에도 같음(이중 계산 없음)")


func u16() -> void:
	var a := _blank_doc()
	a["studylog"]["missions"]["cafe_order"] = {"stars": 3, "done_goals": 2, "last": "2026-10-16", "plays": 3}
	var b := _blank_doc()
	b["studylog"]["missions"]["cafe_order"] = {"stars": 2, "done_goals": 1, "last": "2026-10-15", "plays": 2}
	var r := rnd(_args({}, _blank_local(), {}, [_peer(PC_ID, a, T0 + 100), _peer(PH_ID, b, T0 + 100)], T0 + 100))
	var m = _dig(_view(r), ["missions", "cafe_order"], {})
	ok(m.get("stars", -1) == 3, "U16 stars = max(3, 2) = 3", canon(m))
	ok(m.get("done_goals", -1) == 2, "U16 done_goals = max(2, 1) = 2", canon(m))
	ok(m.get("last", "") == "2026-10-16", "U16 last = 늦은 날", canon(m))
	ok(m.get("plays", -1) == 5, "U16 plays = 자기 몫 합 3 + 2 = 5", canon(m))


# ---------------------------------------------------------------- U17~U19

func u17() -> void:
	var prog := _progress_fixture()
	var sl_pc := _studylog_fixture({"en": {"tokens": 1, "frozen": ["2026-10-14"], "awarded": 2, "last": 20740},
		"ja": {"tokens": 0, "frozen": [], "awarded": 0, "last": 0}})
	var sl_ph := _studylog_fixture({"en": {"tokens": 2, "frozen": [], "awarded": 1, "last": 20741},
		"ja": {"tokens": 1, "frozen": ["2026-10-15"], "awarded": 0, "last": 20742}})
	var pr := _blank_prefs()
	pr["mic_device"] = "USB mic"
	pr["lang"] = "ja"
	var lpc = D.call("extract", prog, sl_pc, pr, 0)
	var lph = D.call("extract", prog, sl_ph, pr, 0)
	ok(canon(lpc).find("freeze") == -1 and canon(lph).find("freeze") == -1, "U17 extract 결과에 freeze 키 없음")
	var rpc := rnd(_args({}, lpc, {}, [], T0 + 10))
	var rph := rnd(_args({}, lph, {}, [_peer(PC_ID, rpc.get("own", {}), T0 + 10)], T0 + 20))
	ok(canon(rpc.get("own", {})).find("freeze") == -1 and canon(rph.get("own", {})).find("freeze") == -1
		and canon(_view(rph)).find("freeze") == -1, "U17 복제본·병합 view 에 freeze 키 없음")
	var opc = D.call("to_local", _view(rpc), 0, prog, sl_pc, pr)
	var oph = D.call("to_local", _view(rph), 0, prog, sl_ph, pr)
	ok(JSON.stringify(_dig(opc, ["studylog", "freeze"])) == JSON.stringify(sl_pc["freeze"]),
		"U17 to_local 결과 PC freeze 가 입력과 바이트 단위로 같음")
	ok(JSON.stringify(_dig(oph, ["studylog", "freeze"])) == JSON.stringify(sl_ph["freeze"]),
		"U17 to_local 결과 폰 freeze 가 입력과 바이트 단위로 같음")


func u18() -> void:
	var pc := _new_dev(PC_ID)
	var ph := _new_dev(PH_ID)
	pc["local"]["marks"] = ["2026-10-12|en", "2026-10-13|en"]   # 월·화
	ph["local"]["marks"] = ["2026-10-14|en", "2026-10-15|en"]   # 수·목
	_sync(pc, [], T0 + 10)
	var r := _sync(ph, [pc], T0 + 20)
	var marks := _sorted(_dig(_view(r), ["marks"], []))
	var want := ["2026-10-12|en", "2026-10-13|en", "2026-10-14|en", "2026-10-15|en"]
	ok(canon(marks) == canon(want), "U18 marks 합집합 = 4일", canon(marks))
	var done := {}
	for m in marks:
		done[_day(str(m).get_slice("|", 0))] = true
	var st = SC.call("settle", done, {}, 0, 0, _day("2026-10-15"))
	ok(int(_dig(st, ["streak"], -1)) == 4, "U18 StreakCalc.settle 연속 4", canon(st))


func u19() -> void:
	var rows := [["", "0101", "0101"], ["0101", "0101", ""], ["0101", "010111", "11"],
		[_rep("0", 30), _rep("0", 29) + "1", "1"], ["0101", "1111", "1111"]]
	for i in range(rows.size()):
		var row: Array = rows[i]
		var got = M.call("new_outcomes", row[0], row[1])
		ok(str(got) == row[2], "U19 new_outcomes 표 %d행" % (i + 1), "got=%s want=%s" % [str(got), row[2]])
	var da := _blank_doc()
	da["studylog"]["phon"]["en"]["th"] = {"h": "0101", "t": T0 + 100, "heard": {"s": 2}}
	var db := _blank_doc()
	db["studylog"]["phon"]["en"]["th"] = {"h": "11", "t": T0 + 200, "heard": {"s": 3}}
	var r := rnd(_args({}, _blank_local(), {}, [_peer(PC_ID, da, T0 + 300), _peer(PH_ID, db, T0 + 300)], T0 + 300))
	var p = _dig(_view(r), ["phon", "en", "th"], {})
	ok(p.get("h", "") == "010111" and _dig(p, ["heard", "s"], -1) == 5,
		"U19 두 기기 h 가 t 순으로 이어짐, heard 합 5", canon(p))
	var dc := _blank_doc()
	dc["studylog"]["phon"]["en"]["th"] = {"h": _rep("0", 25), "t": T0 + 100, "heard": {"s": 1}}
	var dd := _blank_doc()
	dd["studylog"]["phon"]["en"]["th"] = {"h": _rep("1", 10), "t": T0 + 200, "heard": {"s": 1}}
	var r2 := rnd(_args({}, _blank_local(), {}, [_peer(PC_ID, dc, T0 + 300), _peer(PH_ID, dd, T0 + 300)], T0 + 300))
	var h2 = _dig(_view(r2), ["phon", "en", "th", "h"], "")
	ok(str(h2) == _rep("0", 20) + _rep("1", 10), "U19 이어 붙인 35자는 뒤 30자만 남음", str(h2))


# ---------------------------------------------------------------- U20 시계

func u20() -> void:
	var H := T0
	var da := _blank_doc()
	da["progress"]["checks"]["del"]["en-1-w0"] = H + 10 * DAY    # 10일 뒤로 찍은 미래 삭제
	var db := _blank_doc()
	db["progress"]["checks"]["add"]["en-1-w0"] = H + 101         # 정직한 추가(B 허브 시각 H+100 + 1)
	var r := rnd(_args({}, _blank_local(), {}, [_peer(PC_ID, da, H), _peer(PH_ID, db, H + 100)], H + 100))
	ok(_has(_view(r), "checks", "en-1-w0"), "U20 ① 미래 t 의 삭제는 이후 정직한 추가를 이기지 못함")
	ok(int(_dig(r, ["report", "clamped_times"], 0)) > 0, "U20 ① (보조) 미래 시각이 잘린 것을 report 에 셈",
		str(_dig(r, ["report"], {})))
	var prog := _progress_fixture()
	var sl := _studylog_fixture({})
	var pr := _blank_prefs()
	var D0: int = 1760000000
	var L0: int = 1759900000
	var v_neg = D.call("extract", prog, sl, pr, -7200)
	ok(int(_dig(v_neg, ["cards", 0, "due"], -1)) == D0 - 7200, "U20 ② extract(skew=-7200): due 는 허브 시각(D-7200)",
		str(_dig(v_neg, ["cards", 0], {})))
	var back = D.call("to_local", v_neg, -7200, prog, sl, pr)
	var rc = _dig(back, ["progress", "review", 0], {})
	ok(int(rc.get("due", -1)) == D0 and int(rc.get("last_review", -1)) == L0,
		"U20 ② to_local(-7200) 왕복: 카드 due/last_review 보존", str(rc))
	var v_pos = D.call("extract", prog, sl, pr, 7200)
	ok(int(_dig(v_pos, ["cards", 0, "due"], -1)) == D0 + 7200, "U20 ③ extract(skew=+7200): due 는 D+7200")


# ---------------------------------------------------------------- U21~U25

func u21() -> void:
	var lo := _blank_local()
	var newer := _blank_doc()
	newer["v"] = 2
	newer["progress"]["checks"]["add"]["en-9-w0"] = T0
	var r1 := rnd(_args({}, lo, {}, [_peer(PH_ID, newer)], T0))
	ok(_skip_reason(r1, PH_ID) == "newer" and _dig(r1, ["report", "peers_skipped"], []).size() == 1,
		"U21 peer doc.v=2 → 병합에서 빠지고 peers_skipped[0].reason == newer", str(_dig(r1, ["report", "peers_skipped"], [])))
	ok(not _has(_view(r1), "checks", "en-9-w0"), "U21 (보조) 빠진 peer 의 항목은 view 에 없음")
	var nov := _blank_doc()
	nov.erase("v")
	var r2 := rnd(_args({}, lo, {}, [_peer(PH2_ID, nov)], T0))
	ok(_skip_reason(r2, PH2_ID) == "invalid", "U21 doc.v 누락 → invalid", str(_dig(r2, ["report", "peers_skipped"], [])))
	var strv := _blank_doc()
	strv["v"] = "1"
	var r3 := rnd(_args({}, lo, {}, [_peer(PH3_ID, strv)], T0))
	ok(_skip_reason(r3, PH3_ID) == "invalid", "U21 doc.v 문자열 → invalid", str(_dig(r3, ["report", "peers_skipped"], [])))
	var r4 := rnd(_args({}, lo, {}, [null, [1, 2], "x"], T0))
	ok(r4.get("ok", false) == true and _dig(r4, ["report", "peers_skipped"], []).size() == 3,
		"U21 peer 가 null/배열/문자열 → 예외 없이 invalid 로 건너뜀", str(r4.get("ok", "?")))
	var badsec := _blank_doc()
	badsec["progress"] = 5
	_set_day(badsec, "2026-10-17", "en", _rec(700, {}, {}, [0, 0], [0, 0]))
	var r5 := rnd(_args({}, lo, {}, [_peer(PH_ID, badsec)], T0))
	ok(r5.get("ok", false) == true and _sec(_view(r5), "2026-10-17") == 700,
		"U21 섹션 타입 틀림(progress=5): 예외 없이 그 섹션만 빈 값, studylog 는 반영(§4.4 1항)",
		str(_sec(_view(r5), "2026-10-17")))


func u22() -> void:
	var lo := _rich_pc()
	var base_r := rnd(_args({}, lo, {}, [], T0 + 10))
	for bad in [{"progress": 5}, null, "x"]:
		var r := rnd(_args(bad, lo, {}, [], T0 + 10))
		ok(r.get("ok", false) == true and canon(_view(r)) == canon(_view(base_r))
			and canon(r.get("own", {})) == canon(base_r.get("own", {})),
			"U22 깨진 own(%s) 을 {} 취급, 예외 없음" % str(bad))


func u23() -> void:
	for bad in [-5, NAN, INF, "abc", 1e30]:
		var lo := _blank_local()
		lo["xp"]["en"] = bad
		lo["stats"]["en"]["lessons"] = bad
		var r := rnd(_args({}, lo, {}, [], T0))
		var xp = _dig(_view(r), ["xp", "en"], null)
		var les = _dig(_view(r), ["stats", "en", "lessons"], null)
		ok(_numok(xp) and _numok(les), "U23 깨진 숫자 %s: 정수·0 이상·2^53 이하, 예외 없음" % str(bad),
			str([xp, les]))


func u24() -> void:
	var lo := _rich_pc()
	var r0 := rnd(_args({}, lo, {}, [], T0 + 10))
	ok(r0.get("ok", false) == true, "U24 대조군: 정상 입력은 ok==true")
	var cases := [
		["_corrupt_xp", "U24 검사기: xp.en 을 local 보다 작게 → 막힘"],
		["_corrupt_cards", "U24 검사기: 카드 수 줄임 → 막힘"],
		["_corrupt_stars", "U24 검사기: 별 3→1 → 막힘"],
	]
	for c in cases:
		M.test_corrupt = Callable(self, c[0])
		var r := rnd(_args({}, lo, {}, [], T0 + 10))
		M.test_corrupt = Callable()
		var problems = r.get("problems", [])
		ok(r.get("ok", true) == false and typeof(problems) == TYPE_ARRAY and not problems.is_empty()
			and canon(_view(r)) == canon(lo), c[1], str(r.get("ok", "?")) + " " + canon(problems))


func _corrupt_xp(v: Dictionary) -> Dictionary:
	v["xp"]["en"] = 0
	return v


func _corrupt_cards(v: Dictionary) -> Dictionary:
	v["cards"] = []
	return v


func _corrupt_stars(v: Dictionary) -> Dictionary:
	v["missions"]["cafe_order"]["stars"] = 1
	return v


func u25() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 20261017
	var bad: Array = []
	var rounds := 0
	for s in range(100):
		var devs := [_new_dev(PC_ID), _new_dev(PH_ID), _new_dev(PH2_ID)]
		for step in range(6):
			var di := rng.randi_range(0, 2)
			var dv: Dictionary = devs[di]
			_mutate(dv["local"], rng)
			var others: Array = []
			for j in range(3):
				if j != di:
					others.append(devs[j])
			var r := _sync(dv, others, T0 + s * 100000 + step * 10 + di)
			rounds += 1
			if r.get("ok", false) != true:
				bad.append("s%d/step%d" % [s, step])
	ok(bad.is_empty(), "U25 무작위 정상 시나리오 100개(시드 고정, %d 라운드) 모두 ok==true" % rounds,
		str(bad.slice(0, 5)))


# ---------------------------------------------------------------- U26~U30

func u26() -> void:
	var pa := _new_dev(PC_ID)
	var pb := _new_dev(PH_ID)
	_sync(pa, [], T0 + 10)
	pb["local"]["prefs"]["daily_goal_min"] = 20
	var r1 := _sync(pb, [pa], T0 + 20)
	ok(_dig(_view(r1), ["prefs", "daily_goal_min"]) == 20, "U26 기본값(t=0) vs 바꾼 값(t>0): 바꾼 값 승")
	var r2 := _sync(pa, [pb], T0 + 25)
	ok(_dig(_view(r2), ["prefs", "daily_goal_min"]) == 20, "U26 반대편 기기도 20")
	pa["local"]["prefs"]["daily_goal_min"] = 15
	_sync(pa, [pb], T0 + 30)
	pb["local"]["prefs"]["daily_goal_min"] = 25
	var r3 := _sync(pb, [pa], T0 + 40)
	ok(_dig(_view(r3), ["prefs", "daily_goal_min"]) == 25, "U26 둘 다 바꿈: 늦은 쪽(25, t=40) 승")
	var bad := _blank_doc()
	bad["prefs"]["daily_goal_min"] = {"value": "x", "t": T0 + 999}
	bad["prefs"]["lesson_source"] = {"value": "zzz", "t": T0 + 999}
	var rb := rnd(_args({}, _blank_local(), {}, [_peer(PH_ID, bad, T0 + 1000)], T0 + 1000))
	ok(_dig(_view(rb), ["prefs", "daily_goal_min"]) == 10 and _dig(_view(rb), ["prefs", "lesson_source"]) == "tatoeba",
		"U26 값 타입 틀림(daily_goal_min=\"x\", lesson_source=\"zzz\") 은 무시", canon(_dig(_view(rb), ["prefs"], {})))
	var pr := _blank_prefs()
	pr["mic_device"] = "USB mic"
	pr["lang"] = "ja"
	pr["show_fix"] = true
	var lp = D.call("extract", _progress_fixture(), _studylog_fixture({}), pr, 0)
	var keys := _sorted(_dig(lp, ["prefs"], {}).keys())
	ok(canon(lp).find("mic_device") == -1 and canon(lp).find("show_fix") == -1 and _dig(lp, ["prefs", "lang"]) == null,
		"U26 기기별 설정(mic_device, lang, show_fix)은 extract 결과에 없음")
	ok(canon(keys) == canon(_sorted(SHARED_PREFS)), "U26 (보조) 공유 prefs 는 정확히 6개 키", canon(keys))
	var rr := rnd(_args({}, lp, {}, [], T0))
	ok(canon(rr.get("own", {})).find("mic_device") == -1, "U26 (보조) 기기별 설정은 복제본에도 없음")


func u27() -> void:
	var pa := _new_dev(PC_ID)
	var pb := _new_dev(PH_ID)
	pa["local"]["known"] = {"en": ["go"], "ja": []}
	_sync(pa, [], T0 + 10)
	pb["local"]["known"] = {"en": ["see"], "ja": []}
	var r1 := _sync(pb, [pa], T0 + 20)
	ok(canon(_dig(_view(r1), ["known", "en"], [])) == canon(["go", "see"]), "U27 합집합 단어 {go, see}")
	var r2 := _sync(pa, [pb], T0 + 25)
	ok(canon(_dig(_view(r2), ["known", "en"], [])) == canon(["go", "see"]), "U27 (보조) 반대편도 {go, see}")
	pa["local"]["known"]["en"] = ["see"]                # go 해제
	_sync(pa, [pb], T0 + 30)
	var r3 := _sync(pb, [pa], T0 + 40)
	ok(canon(_dig(_view(r3), ["known", "en"], [])) == canon(["see"]), "U27 해제 전파: go 가 폰에서도 빠짐")
	var big := _blank_doc()
	for i in range(1, 30002):
		big["progress"]["known"]["en"]["add"]["w%05d" % i] = i
	var r4 := rnd(_args({}, _blank_local(), {}, [_peer(PC_ID, big, T0 + 100000)], T0 + 100000))
	var en: Array = _dig(_view(r4), ["known", "en"], [])
	ok(en.size() == 30000 and not en.has("w00001") and en.has("w30001"),
		"U27 상한 30000 초과: 오래된 것부터 잘림(w00001 빠지고 w30001 남음)", str(en.size()))
	ok(int(_dig(r4, ["report", "trimmed", "known"], 0)) >= 1, "U27 상한 초과를 report.trimmed.known 으로 보고",
		canon(_dig(r4, ["report"], {})))


func u28() -> void:
	# (a) 기본(t=0) vs 사용자 설정(t>0)
	var pa := _new_dev(PC_ID)
	var pb := _new_dev(PH_ID)
	_sync(pa, [], T0 + 10)
	pb["local"]["start"] = "2026-12-01"
	var r1 := _sync(pb, [pa], T0 + 20)
	ok(_dig(_view(r1), ["start"]) == "2026-12-01", "U28 기본(t=0) vs 설정(t>0): 설정값 승")
	# (b) 둘 다 설정: 늦은 쪽
	var qa := _new_dev(PC_ID)
	var qb := _new_dev(PH_ID)
	_sync(qa, [], T0 + 10)
	qa["local"]["start"] = "2026-12-20"
	_sync(qa, [], T0 + 30)
	_sync(qb, [qa], T0 + 35)
	qb["local"]["start"] = "2026-12-10"
	var r2 := _sync(qb, [qa], T0 + 40)
	ok(_dig(_view(r2), ["start"]) == "2026-12-10", "U28 둘 다 설정: 늦은 쪽(t=40, 2026-12-10) 승")
	# (c) 같은 t: ISO 큰 쪽
	var ta := _blank_doc()
	ta["progress"]["start"] = {"value": "2026-12-05", "t": 500}
	var tb := _blank_doc()
	tb["progress"]["start"] = {"value": "2026-12-10", "t": 500}
	var r3 := rnd(_args({}, _blank_local(), {}, [_peer(PC_ID, ta, T0 + 1000), _peer(PH_ID, tb, T0 + 1000)], T0 + 1000))
	var r4 := rnd(_args({}, _blank_local(), {}, [_peer(PH_ID, tb, T0 + 1000), _peer(PC_ID, ta, T0 + 1000)], T0 + 1000))
	ok(_dig(_view(r3), ["start"]) == "2026-12-10" and canon(_view(r3)) == canon(_view(r4)),
		"U28 같은 t: ISO 큰 쪽(2026-12-10), 피어 순서와 무관")


func u29() -> void:
	var lo := _blank_local()
	lo["checks"] = ["en-1-k1", "en-2-k2"]
	var dx := _blank_doc()
	dx["progress"]["checks"]["del"]["en-1-k1"] = 600
	var dy := _blank_doc()
	dy["progress"]["checks"]["del"]["en-2-k2"] = 400
	var r := rnd(_args({}, lo, {}, [_peer(PC_ID, dx, T0 + 1000), _peer(PH2_ID, dy, T0 + 1000)], T0 + 1000, {"sets_at": 500}))
	ok(not _has(_view(r), "checks", "en-1-k1"), "U29 rebase: sets_at=500 보다 늦은 남의 삭제 600 이 이김")
	ok(_has(_view(r), "checks", "en-2-k2"), "U29 rebase: 남의 삭제 400 은 sets_at 500 추가에 짐")
	ok(_dig(r, ["own", "progress", "checks", "add", "en-1-k1"]) == 500, "U29 (보조) rebase 집합 추가 시각 = sets_at",
		str(_dig(r, ["own", "progress", "checks", "add"], {})))


func u30() -> void:
	var lo := _rich_pc()
	var r := rnd(_args({}, lo, {}, [], T0 + 10))
	var v := _view(r)
	ok(canon(v) == canon(lo), "U30 첫 동기화 + 상대 없음: view == local (canonical)")
	var changed: bool = canon(v) != canon(lo)
	ok(changed == false, "U30 changed == false (백업·적용 불필요)")


# ---------------------------------------------------------------- U15b 로컬 카운터가 base 보다 줄어든 경우

func u15b() -> void:
	# 설계 §4.4 2항: 카운터 몫 = own + max(0, local - base). 로컬이 줄어도(오래된 날 정리 등) 자기 몫·병합값은 줄지 않는다.
	var day := "2026-10-17"
	var pc := _new_dev(PC_ID)
	pc["local"]["days"] = {day: {"en": _rec(600, {"lesson": 300}, {"lessons": 4}, [2, 5], [3, 240])}}
	pc["local"]["xp"] = {"en": 100, "ja": 0}
	_sync(pc, [], T0 + 10)
	var lo: Dictionary = _dup(pc["local"])
	lo["days"][day]["en"]["sec"] = 500
	lo["days"][day]["en"]["n"]["lessons"] = 2
	lo["days"][day]["en"]["score"] = [2, 160]
	lo["xp"]["en"] = 80
	var r := rnd(_args(pc["own"], lo, pc["base"], [], T0 + 20))
	var own: Dictionary = r.get("own", {})
	var v := _view(r)
	ok(r.get("ok", false) == true, "U15b 로컬 카운터가 base 보다 줄어도 검사 통과(view >= local 은 만족)")
	ok(int(_dig(own, ["studylog", "days", day, "en", "sec"], -1)) == 600
		and int(_dig(own, ["progress", "xp", "en"], -1)) == 100
		and int(_dig(own, ["studylog", "days", day, "en", "n", "lessons"], -1)) == 4,
		"U15b 자기 몫 유지: own sec 600, xp 100, n.lessons 4 (줄지 않음)",
		canon(_dig(own, ["studylog", "days", day, "en"], {})))
	ok(_sec(v, day) == 600 and int(_dig(v, ["xp", "en"], -1)) == 100,
		"U15b 병합 view 도 줄지 않음: sec 600, xp 100", str([_sec(v, day), _dig(v, ["xp", "en"], -1)]))
	ok(int(_dig(v, ["days", day, "en", "n", "lessons"], -1)) == 4
		and canon(_dig(v, ["days", day, "en", "score"], [])) == canon([3, 240])
		and int(_dig(v, ["days", day, "en", "by", "lesson"], -1)) == 300,
		"U15b 다른 합산 잎(n.lessons 4, score [3,240], by.lesson 300) 도 줄지 않음",
		canon(_dig(v, ["days", day, "en"], {})))


# ---------------------------------------------------------------- M-04 입력 불변, M-05 성능

func _iso(z: int) -> String:
	# 일 번호 -> "YYYY-MM-DD" (civil_from_days). 시험 안에 따로 적었다.
	z += 719468
	var era := z / 146097
	var doe := z - era * 146097
	var yoe := (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
	var y := yoe + era * 400
	var doy := doe - (365 * yoe + yoe / 4 - yoe / 100)
	var mp := (5 * doy + 2) / 153
	var d := doy - (153 * mp + 2) / 5 + 1
	var m := (mp + 3) if mp < 10 else (mp - 9)
	if m <= 2:
		y += 1
	return "%04d-%02d-%02d" % [y, m, d]


func m04() -> void:
	var pc := _new_dev(PC_ID)
	pc["local"] = _rich_pc()
	_sync(pc, [], T0 + 15)
	var ph := _new_dev(PH_ID)
	ph["local"] = _rich_ph()
	_sync(ph, [], T0 + 10)
	pc["local"]["checks"] = ["en-1-w0", "en-5-w0"]
	pc["local"]["xp"]["en"] = 130
	pc["local"]["days"]["2026-10-15"]["en"]["sec"] = 700
	var peers := [_peer(PH_ID, ph["own"], T0 + 10)]
	var a := {"own": pc["own"], "local": pc["local"], "base": pc["base"], "peers": peers,
		"stamp": T0 + 20, "hub_now": T0 + 20, "today": _day("2026-10-17"), "rebase": null}
	var before := canon(a)
	M.call("sync_round", a)
	ok(canon(a) == before, "M-04 sync_round 호출 전후 args canonical 동일 (rebase 없음)")
	var b := {"own": pc["own"], "local": pc["local"], "base": pc["base"], "peers": peers,
		"stamp": T0 + 20, "hub_now": T0 + 20, "today": _day("2026-10-17"), "rebase": {"sets_at": 500}}
	var before_b := canon(b)
	M.call("sync_round", b)
	ok(canon(b) == before_b, "M-04 sync_round 호출 전후 args canonical 동일 (rebase {sets_at:500})")


func m05() -> void:
	# 설계 §10.3 M-05 의 시험 규모: 기기당 카드 3000장, 날짜 365일, 아는 단어 30000 (두 기기).
	# 두 기기가 같은 키 집합을 가져 합집합이 상한(MAX_REVIEW 3000, MAX_KNOWN 30000) 안에 머문다.
	ok(_iso(_day("2028-02-29")) == "2028-02-29" and _iso(_day("2026-10-17")) == "2026-10-17",
		"M-05 (보조) 일 번호 <-> 날짜 문자열 변환 왕복 확인")
	var d0 := _day("2026-01-01")
	var pc := _new_dev(PC_ID)
	var ph := _new_dev(PH_ID)
	var cards_a: Array = []
	var cards_b: Array = []
	var words: Array = []
	for i in range(3000):
		cards_a.append(_card("en|c%04d" % i, "ia%04d" % i, 1, T0 - 100))
		cards_b.append(_card("en|c%04d" % i, "ib%04d" % i, 2 if i % 2 == 0 else 1, T0 - 50))
	for i in range(30000):
		words.append("w%05d" % i)
	var days_a := {}
	var days_b := {}
	for i in range(365):
		days_a[_iso(d0 + i)] = {"en": _rec(60 + i, {"lesson": 30}, {"lessons": 1}, [1, 2], [1, 80])}
		days_b[_iso(d0 + i)] = {"en": _rec(30 + i, {"lesson": 10}, {"lessons": 2}, [1, 2], [0, 0])}
	pc["local"]["cards"] = cards_a
	pc["local"]["known"] = {"en": words.duplicate(), "ja": []}
	pc["local"]["days"] = days_a
	_sync(pc, [], T0 + 10)
	ph["local"]["cards"] = cards_b
	ph["local"]["known"] = {"en": words.duplicate(), "ja": []}
	ph["local"]["days"] = days_b
	var args := _args(ph["own"], ph["local"], ph["base"], [_peer(PC_ID, pc["own"], T0 + 10)], T0 + 20)
	var t0 := Time.get_ticks_msec()
	var r := rnd(args)
	var ms := Time.get_ticks_msec() - t0
	print("PERF M-05 merge_ms=%d (cards 3000x2, days 365x2, known en 30000x2)" % ms)
	ok(ms <= 5000, "M-05 병합 시간 <= 5000 ms (카드 3000x2, 날짜 365, 아는 단어 30000x2)", "%d ms" % ms)
	var v := _view(r)
	ok(r.get("ok", false) == true, "M-05 (보조) 대용량 병합이 검사 통과")
	ok((v.get("cards", []) as Array).size() == 3000 and (_dig(v, ["days"], {}) as Dictionary).size() == 365
		and (_dig(v, ["known", "en"], []) as Array).size() == 30000,
		"M-05 (보조) 합집합 크기: 카드 3000, 날짜 365, 아는 단어 30000",
		str([(v.get("cards", []) as Array).size(), (_dig(v, ["days"], {}) as Dictionary).size(), (_dig(v, ["known", "en"], []) as Array).size()]))
