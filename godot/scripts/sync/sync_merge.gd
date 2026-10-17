class_name SyncMerge
extends RefCounted
## 학습 기록 병합 순수 함수 (설계 docs/sync_design.md §4.4, §4.5, §7.2). 파일·네트워크·시계·난수·전역 상태 없음:
## 같은 입력이면 항상 같은 출력이고, 입력 Dictionary 는 바꾸지 않는다.
##
## sync_round(args) 한 번의 흐름
##   1. 정리      peers 검사(v), 모든 시각을 min(t, saved_hub + TIME_SLACK) 로 자르기
##   2. 내 이벤트  카운터 = 자기 몫 + max(0, local - base) / 집합 = add·del 이벤트 / 레지스터 / 음소 / 미션
##   3. 병합      몫의 합 / add·del 최대값 비교 / 카드 승자 / 레지스터 최신 / 미션 max
##   4. 채택      병합 결과를 내 복제본(own)에 반영
##   5. 검사      줄어듦 금지 등 (실패하면 ok=false, 로컬은 그대로)
##
## args: own, local, base, peers[{device_id, saved_hub, doc}], stamp, hub_now, today, rebase, device_id(선택, 음소 기록 순서 동률 처리용)
## 반환: {ok, own, view, report, problems}

const TIME_SLACK := 5
const DEL_KEEP_SEC := 400 * 86400
const PROTECT_NEW := 100 ## 카드 상한에서 가장 늦게 잘리는(가장 최근에 추가된) 카드 수
const _SETS := ["checks", "marks", "cards", "known.en", "known.ja"]

## 시험 전용: (view) -> view. 비어 있지 않으면 검사 직전에 병합 결과를 변조한다(검사기가 실제로 막는지 확인).
static var test_corrupt: Callable = Callable()


# ---------------------------------------------------------------- small public helpers

## 음소 기록 링(최대 HISTORY 자)에서 이 기기가 새로 관찰한 결과만 뽑는다 (§4.5).
## 링은 넘칠 때만 앞이 밀려 local 이 HISTORY 자가 된다. 그래서 local 이 HISTORY 보다 짧으면 "base 로 시작하는지"만 보고
## (아니면 관계 없음: local 전체가 새것), local 이 HISTORY 자이면 d = 0..len(base) 중 가장 작은 밀림을 골라 적게 센다.
static func new_outcomes(base_h: String, local_h: String) -> String:
	if base_h == "":
		return local_h
	var bl: int = base_h.length()
	var max_d: int = bl if local_h.length() >= SyncDoc.HISTORY else 0
	for d in range(0, max_d + 1):
		if local_h.begins_with(base_h.substr(d)):
			return local_h.substr(bl - d)
	return local_h


## a 가 b 를 이기나 (D5): reps 큰 쪽 -> last_review 늦은 쪽 -> stability 큰 쪽 -> 정규화 JSON 이 사전순으로 큰 쪽.
## 완전히 같으면 false. card_wins(a, b) 와 card_wins(b, a) 가 둘 다 true 인 경우는 없다.
static func card_wins(a: Dictionary, b: Dictionary) -> bool:
	var ra: int = SyncDoc.to_int(a.get("reps", 0), 0, SyncDoc.MAX_LEAF)
	var rb: int = SyncDoc.to_int(b.get("reps", 0), 0, SyncDoc.MAX_LEAF)
	if ra != rb:
		return ra > rb
	var la: int = SyncDoc.to_int(a.get("last_review", 0), 0, SyncDoc.MAX_LEAF)
	var lb: int = SyncDoc.to_int(b.get("last_review", 0), 0, SyncDoc.MAX_LEAF)
	if la != lb:
		return la > lb
	var sa: float = SyncDoc.to_flt(a.get("stability", 0.0), 0.0, 1.0e9, 0.0)
	var sb: float = SyncDoc.to_flt(b.get("stability", 0.0), 0.0, 1.0e9, 0.0)
	if sa != sb:
		return sa > sb
	return canonical(a) > canonical(b)


## 키 정렬 JSON 문자열 (비교·지문용). 정수와 정수값 실수(5, 5.0)는 같게 쓴다. NaN/inf 는 null.
static func canonical(v: Variant) -> String:
	var parts := PackedStringArray()
	_canon(v, parts)
	return "".join(parts)


static func _q(s: String) -> String:
	return "\"" + s.json_escape() + "\""


static func _canon(v: Variant, out: PackedStringArray) -> void:
	match typeof(v):
		TYPE_NIL:
			out.append("null")
		TYPE_BOOL:
			out.append("true" if v else "false")
		TYPE_INT:
			out.append(str(v))
		TYPE_FLOAT:
			var f: float = v
			if is_nan(f) or is_inf(f):
				out.append("null")
			elif f == floorf(f) and absf(f) <= 9007199254740992.0:
				out.append(str(int(f)))
			else:
				out.append(str(f))
		TYPE_STRING, TYPE_STRING_NAME:
			out.append(_q(str(v)))
		TYPE_DICTIONARY:
			var d: Dictionary = v
			var names: Array = []
			var back := {}
			for k in d:
				var ks: String = str(k)
				names.append(ks)
				back[ks] = k
			names.sort()
			out.append("{")
			var first := true
			for ks in names:
				if not first:
					out.append(",")
				first = false
				out.append(_q(ks))
				out.append(":")
				_canon(d[back[ks]], out)
			out.append("}")
		TYPE_ARRAY:
			out.append("[")
			var first2 := true
			for e in (v as Array):
				if not first2:
					out.append(",")
				first2 = false
				_canon(e, out)
			out.append("]")
		TYPE_PACKED_STRING_ARRAY, TYPE_PACKED_INT32_ARRAY, TYPE_PACKED_INT64_ARRAY, TYPE_PACKED_FLOAT32_ARRAY, TYPE_PACKED_FLOAT64_ARRAY:
			_canon(Array(v), out)
		_:
			out.append(_q(str(v)))


# ---------------------------------------------------------------- sync_round

static func _blank_report() -> Dictionary:
	return {
		"first": false, "peers": 0, "peers_skipped": [], "clamped_times": 0,
		"trimmed": {"cards": 0, "known": 0}, "changed": false,
		"changes": {"cards_added": 0, "cards_removed": 0, "cards_updated": 0, "checks_changed": 0,
			"marks_changed": 0, "known_added": 0, "known_removed": 0, "other_changed": false},
	}


static func _whole(v: Variant) -> bool:
	return v is int or (v is float and is_finite(v) and v == floorf(v))


static func sync_round(args: Dictionary) -> Dictionary:
	var report: Dictionary = _blank_report()
	var local: Dictionary = SyncDoc.norm_view(args.get("local", null))
	var base_in: Variant = args.get("base", null)
	var first: bool = not (base_in is Dictionary) or (base_in as Dictionary).is_empty()
	var base: Dictionary = SyncDoc.norm_view(null if first else base_in, true)
	report["first"] = first
	var hub_now: int = SyncDoc.to_int(args.get("hub_now", 0), 0, SyncDoc.MAX_TIME)
	var stamp: int = SyncDoc.to_int(args.get("stamp", 0), 0, SyncDoc.MAX_TIME)
	if stamp <= 0:
		stamp = hub_now
	var today: int = SyncDoc.to_int(args.get("today", 0), 0, 10000000)
	var own_id: String = ""
	if args.get("device_id", null) is String:
		own_id = args["device_id"]
	var rebase_at: int = -1
	var rb: Variant = args.get("rebase", null)
	if rb is Dictionary:
		rebase_at = SyncDoc.to_int((rb as Dictionary).get("sets_at", 0), 0, SyncDoc.MAX_TIME)

	# 1. peers
	var stat := {"clamped": 0}
	var reps: Array = []
	var peers_in: Variant = args.get("peers", null)
	var skipped: Array = report["peers_skipped"]
	var own_prev: Dictionary = SyncDoc.norm_replica(args.get("own", null), -1, {})
	reps.append({"id": own_id, "rep": own_prev, "peer": false})
	if peers_in is Array:
		for item in (peers_in as Array):
			var did: String = ""
			if item is Dictionary and (item as Dictionary).get("device_id", null) is String:
				did = (item as Dictionary)["device_id"]
			if not (item is Dictionary) or not ((item as Dictionary).get("doc", null) is Dictionary):
				skipped.append({"device_id": did, "reason": "invalid"})
				continue
			var doc: Dictionary = (item as Dictionary)["doc"]
			var ver: Variant = doc.get("v", null)
			if not _whole(ver) or int(ver) < 1:
				skipped.append({"device_id": did, "reason": "invalid"})
				continue
			if int(ver) > SyncDoc.SCHEMA:
				skipped.append({"device_id": did, "reason": "newer"})
				continue
			var sh: int = SyncDoc.to_int((item as Dictionary).get("saved_hub", 0), 0, SyncDoc.MAX_TIME)
			var cutoff: int = -1
			if sh > 0:
				cutoff = sh + TIME_SLACK
			elif hub_now > 0:
				cutoff = hub_now + TIME_SLACK
			reps.append({"id": did, "rep": SyncDoc.norm_replica(doc, cutoff, stat), "peer": true})
	report["peers"] = reps.size() - 1
	report["clamped_times"] = int(stat["clamped"])

	# 2. my own new events
	var own: Dictionary = (reps[0] as Dictionary)["rep"]
	var base_has_start: bool = (not first) and SyncDoc.is_iso((base_in as Dictionary).get("start", null))
	_update_own(own, local, base, base_has_start, first, stamp, rebase_at, _peer_dels(reps))

	# 3. merge
	var m: Dictionary = _merge(reps, local, today, report)
	var view: Dictionary = m["view"]

	# 4. adopt
	_adopt(own, m, rebase_at)
	var cut: int = stamp - DEL_KEEP_SEC
	for name in _SETS:
		var dl: Dictionary = _set_of(own, name)["del"]
		var ad: Dictionary = _set_of(own, name)["add"]
		for k in dl.keys():
			if int(ad.get(k, -1)) <= int(dl[k]):
				ad.erase(k) ## the old add of a deleted item goes together with its delete event
				if name == "cards":
					((own["progress"] as Dictionary)["cards"] as Dictionary)["data"].erase(k)
			if int(dl[k]) < cut:
				dl.erase(k)

	# 5. check (a test hook may corrupt the result first)
	if test_corrupt.is_valid():
		var changed_view: Variant = test_corrupt.call(view.duplicate(true))
		if changed_view is Dictionary:
			view = changed_view
	var problems: Array = check(local, view, {"reps": reps, "sets": m["sets"], "today": today,
		"trimmed": report["trimmed"], "nodata": m["nodata"]})
	if not problems.is_empty():
		var own_back: Variant = args.get("own", null)
		var local_back: Variant = args.get("local", null)
		return {
			"ok": false,
			"own": (own_back as Dictionary).duplicate(true) if own_back is Dictionary else {},
			"view": (local_back as Dictionary).duplicate(true) if local_back is Dictionary else SyncDoc.blank_view(),
			"report": report,
			"problems": problems,
		}
	_fill_changes(report, local, view)
	return {"ok": true, "own": own, "view": view, "report": report, "problems": []}


# ---------------------------------------------------------------- step 2: my own events

static func _set_of(rep: Dictionary, name: String) -> Dictionary:
	var prog: Dictionary = rep["progress"]
	match name:
		"checks":
			return prog["checks"]
		"marks":
			return prog["marks"]
		"cards":
			return prog["cards"]
		"known.en":
			return (prog["known"] as Dictionary)["en"]
	return (prog["known"] as Dictionary)["ja"]


static func _local_keys(local: Dictionary, name: String) -> Array:
	match name:
		"checks":
			return local["checks"]
		"marks":
			return local["marks"]
		"cards":
			var ks: Array = []
			for c in (local["cards"] as Array):
				ks.append((c as Dictionary)["key"])
			return ks
		"known.en":
			return (local["known"] as Dictionary)["en"]
	return (local["known"] as Dictionary)["ja"]


static func _base_keys(base: Dictionary, name: String) -> Array:
	match name:
		"checks":
			return base["checks"]
		"marks":
			return base["marks"]
		"cards":
			return base["cards"]
		"known.en":
			return (base["known"] as Dictionary)["en"]
	return (base["known"] as Dictionary)["ja"]


static func _dlt(local_v: Variant, base_v: Variant) -> int:
	return maxi(0, int(local_v) - int(base_v))


static func _counts_add(o: Dictionary, r: Dictionary, b: Dictionary, hi: int) -> Dictionary:
	var out: Dictionary = o.duplicate()
	for k in r:
		var d: int = _dlt(r[k], b.get(k, 0))
		if d > 0:
			out[k] = mini(int(out.get(k, 0)) + d, hi)
	return out


static func _rec_add(o: Dictionary, r: Dictionary, b: Dictionary) -> Dictionary:
	var out: Dictionary = SyncDoc.blank_rec()
	out["sec"] = mini(int(o["sec"]) + _dlt(r["sec"], b["sec"]), SyncDoc.MAX_SEC_PER_DAY)
	out["by"] = _counts_add(o["by"], r["by"], b["by"], SyncDoc.MAX_SEC_PER_DAY)
	out["n"] = _counts_add(o["n"], r["n"], b["n"], SyncDoc.MAX_COUNT)
	for part in ["lesson", "score"]:
		var op: Array = o[part]
		var rp: Array = r[part]
		var bp: Array = b[part]
		out[part] = [mini(int(op[0]) + _dlt(rp[0], bp[0]), SyncDoc.MAX_COUNT), mini(int(op[1]) + _dlt(rp[1], bp[1]), SyncDoc.MAX_COUNT)]
	return SyncDoc.clean_rec(out)


## name -> {key: true} for every key that some other device has a delete event for.
static func _peer_dels(reps: Array) -> Dictionary:
	var out := {}
	for name in _SETS:
		var d := {}
		for r in reps:
			if bool((r as Dictionary)["peer"]):
				for k in (_set_of((r as Dictionary)["rep"], name)["del"] as Dictionary):
					d[k] = true
		out[name] = d
	return out


static func _upd_set(s: Dictionary, lkeys: Array, bkeys: Array, use_base: bool, stamp: int, rebase_at: int, peer_del: Dictionary) -> void:
	var add: Dictionary = s["add"]
	var del: Dictionary = s["del"]
	var lset := {}
	for k in lkeys:
		lset[k] = true
	var bset := {}
	if use_base:
		for k in bkeys:
			bset[k] = true
	for k in lkeys:
		if rebase_at >= 0:
			add[k] = maxi(int(add.get(k, 0)), rebase_at)
		elif not bset.has(k) or (not add.has(k) and not peer_del.has(k)):
			add[k] = stamp
	if use_base:
		for k in bkeys:
			if not lset.has(k):
				del[k] = stamp


## One register ({value, t}): a change since the last agreed state becomes {value, stamp}.
static func _upd_reg(oreg: Dictionary, lv: Variant, dflt: Variant, has_ref: bool, ref: Variant, first: bool, stamp: int) -> Dictionary:
	var same_own: bool = SyncDoc.same_value(oreg["value"], lv)
	if first:
		if same_own:
			return oreg
		return {"value": lv, "t": 0 if SyncDoc.same_value(lv, dflt) else stamp}
	if has_ref and not SyncDoc.same_value(ref, lv):
		return {"value": lv, "t": stamp}
	if same_own:
		return oreg
	return {"value": lv, "t": 0 if SyncDoc.same_value(lv, dflt) else stamp}


## Changes `own` (a fresh, already cleaned copy) into own'.
static func _update_own(own: Dictionary, local: Dictionary, base: Dictionary, base_has_start: bool, first: bool, stamp: int, rebase_at: int, peer_dels: Dictionary) -> void:
	var prog: Dictionary = own["progress"]
	var sl: Dictionary = own["studylog"]
	# counters: xp, stats
	for l in SyncDoc.LANGS:
		(prog["xp"] as Dictionary)[l] = mini(int((prog["xp"] as Dictionary)[l]) + _dlt((local["xp"] as Dictionary)[l], (base["xp"] as Dictionary)[l]), SyncDoc.MAX_LEAF)
		for k in SyncDoc.STAT_KEYS:
			var ps: Dictionary = (prog["stats"] as Dictionary)[l]
			ps[k] = mini(int(ps[k]) + _dlt(((local["stats"] as Dictionary)[l] as Dictionary)[k], ((base["stats"] as Dictionary)[l] as Dictionary)[k]), SyncDoc.MAX_LEAF)
	# counters: per-day leaves
	var odays: Dictionary = sl["days"]
	var bdays: Dictionary = base["days"]
	for iso in (local["days"] as Dictionary):
		var per: Dictionary = (local["days"] as Dictionary)[iso]
		for l in per:
			var brec: Dictionary = SyncDoc.blank_rec()
			if bdays.has(iso) and (bdays[iso] as Dictionary).has(l):
				brec = (bdays[iso] as Dictionary)[l]
			var orec: Dictionary = SyncDoc.blank_rec()
			if odays.has(iso) and (odays[iso] as Dictionary).has(l):
				orec = (odays[iso] as Dictionary)[l]
			var nrec: Dictionary = _rec_add(orec, per[l], brec)
			if SyncDoc.rec_nonzero(nrec):
				if not odays.has(iso):
					odays[iso] = {}
				(odays[iso] as Dictionary)[l] = nrec
	# sets
	var use_base: bool = (not first) and rebase_at < 0
	for name in _SETS:
		_upd_set(_set_of(own, name), _local_keys(local, name), _base_keys(base, name), use_base, stamp, rebase_at, peer_dels[name])
	# card data: keep what this replica already holds (cards cut from the view stay in the hub copy), refresh the local ones
	var data: Dictionary = (prog["cards"] as Dictionary)["data"]
	var cadd: Dictionary = (prog["cards"] as Dictionary)["add"]
	var cdel: Dictionary = (prog["cards"] as Dictionary)["del"]
	for k in data.keys():
		if cdel.has(k) and int(cdel[k]) >= int(cadd.get(k, -1)):
			data.erase(k)
	for c in (local["cards"] as Array):
		var cd: Dictionary = (c as Dictionary).duplicate()
		cd.erase("key")
		data[(c as Dictionary)["key"]] = cd
	# registers
	prog["start"] = _upd_reg(prog["start"], local["start"], Plan.DEFAULT_START, base_has_start, base["start"] if base_has_start else prog["start"]["value"], first, stamp)
	var prefs: Dictionary = own["prefs"]
	for k in SyncDoc.SHARED_PREFS.keys():
		var oreg: Dictionary = prefs[k]
		prefs[k] = _upd_reg(oreg, (local["prefs"] as Dictionary)[k], SyncDoc.SHARED_PREFS[k], true, oreg["value"], first, stamp)
	# phonemes: the outcomes this device observed itself
	for l in SyncDoc.LANGS:
		var ophon: Dictionary = (sl["phon"] as Dictionary)[l]
		var bph: Dictionary = (base["phon"] as Dictionary)[l]
		for p in ((local["phon"] as Dictionary)[l] as Dictionary):
			var e: Dictionary = ((local["phon"] as Dictionary)[l] as Dictionary)[p]
			var bh: String = ""
			var bheard: Dictionary = {}
			if bph.has(p):
				bh = (bph[p] as Dictionary)["h"]
				bheard = (bph[p] as Dictionary)["heard"]
			var oe: Dictionary = {"h": "", "t": 0, "heard": {}}
			if ophon.has(p):
				oe = ophon[p]
			var fresh: String = new_outcomes(bh, e["h"])
			var nh: String = str(oe["h"]) + fresh
			if nh.length() > SyncDoc.HISTORY:
				nh = nh.substr(nh.length() - SyncDoc.HISTORY)
			oe["h"] = nh
			if fresh != "":
				oe["t"] = stamp
			oe["heard"] = SyncDoc.trim_heard(_counts_add(oe["heard"], e["heard"], bheard, SyncDoc.MAX_COUNT))
			if oe["h"] != "" or not (oe["heard"] as Dictionary).is_empty():
				ophon[p] = oe
		(sl["phon"] as Dictionary)[l] = SyncDoc.prune_phon(ophon)
	# missions
	var omis: Dictionary = sl["missions"]
	var bmis: Dictionary = base["missions"]
	for id in (local["missions"] as Dictionary):
		var lm: Dictionary = (local["missions"] as Dictionary)[id]
		var om: Dictionary = {"stars": 0, "plays": 0, "last": "", "done_goals": 0}
		if omis.has(id):
			om = omis[id]
		var bplays: int = int((bmis[id] as Dictionary)["plays"]) if bmis.has(id) else 0
		om["stars"] = maxi(int(om["stars"]), int(lm["stars"]))
		om["done_goals"] = maxi(int(om["done_goals"]), int(lm["done_goals"]))
		om["last"] = _later_iso(str(om["last"]), str(lm["last"]))
		om["plays"] = mini(int(om["plays"]) + _dlt(lm["plays"], bplays), SyncDoc.MAX_COUNT)
		omis[id] = om


static func _later_iso(a: String, b: String) -> String:
	return a if a >= b else b


# ---------------------------------------------------------------- step 3: merge

## add / del of every replica -> {add_max, del_max, present}. present = keys whose add_max >= del_max (no del = present).
static func _merge_set(reps: Array, name: String) -> Dictionary:
	var add_max := {}
	var del_max := {}
	for r in reps:
		var s: Dictionary = _set_of((r as Dictionary)["rep"], name)
		var a: Dictionary = s["add"]
		for k in a:
			var t: int = a[k]
			if t > int(add_max.get(k, -1)):
				add_max[k] = t
		var d: Dictionary = s["del"]
		for k in d:
			var t2: int = d[k]
			if t2 > int(del_max.get(k, -1)):
				del_max[k] = t2
	var present := {}
	for k in add_max:
		if not del_max.has(k) or int(add_max[k]) >= int(del_max[k]):
			present[k] = add_max[k]
	return {"add_max": add_max, "del_max": del_max, "present": present}


## Keys ordered by (add time ascending, key).
static func _order_by_add(present: Dictionary) -> Array:
	var buckets := {}
	for k in present:
		var t: int = present[k]
		if not buckets.has(t):
			buckets[t] = []
		(buckets[t] as Array).append(k)
	var times: Array = buckets.keys()
	times.sort()
	var out: Array = []
	for t in times:
		var b: Array = buckets[t]
		b.sort()
		out.append_array(b)
	return out


static func _sorted_keys(d: Dictionary) -> Array:
	var ks: Array = d.keys()
	ks.sort()
	return ks


static func _merge_reg(regs: Array, dflt: Variant) -> Dictionary:
	var best: Dictionary = {}
	for r in regs:
		var reg: Dictionary = r
		if best.is_empty() or int(reg["t"]) > int(best["t"]):
			best = reg
		elif int(reg["t"]) == int(best["t"]) and canonical(reg["value"]) > canonical(best["value"]):
			best = reg
	if best.is_empty() or int(best["t"]) <= 0:
		return {"value": dflt, "t": 0}
	return {"value": best["value"], "t": int(best["t"])}


static func _merge_phon(reps: Array, l: String) -> Dictionary:
	var by_p := {}
	for r in reps:
		var rep: Dictionary = (r as Dictionary)["rep"]
		var ph: Dictionary = ((rep["studylog"] as Dictionary)["phon"] as Dictionary)[l]
		for p in ph:
			if not by_p.has(p):
				by_p[p] = {"obs": [], "heard": {}}
			var e: Dictionary = ph[p]
			var slot: Dictionary = by_p[p]
			if e["h"] != "":
				(slot["obs"] as Array).append([int(e["t"]), str((r as Dictionary)["id"]), e["h"]])
			var heard: Dictionary = slot["heard"]
			for hk in (e["heard"] as Dictionary):
				heard[hk] = mini(int(heard.get(hk, 0)) + int((e["heard"] as Dictionary)[hk]), SyncDoc.MAX_COUNT)
	var out := {}
	for p in by_p:
		var obs: Array = (by_p[p] as Dictionary)["obs"]
		obs.sort_custom(func(a: Array, b: Array) -> bool:
			if a[0] != b[0]:
				return a[0] < b[0]
			if a[1] != b[1]:
				return a[1] < b[1]
			return a[2] < b[2])
		var h: String = ""
		for o in obs:
			h += (o as Array)[2]
		if h.length() > SyncDoc.HISTORY:
			h = h.substr(h.length() - SyncDoc.HISTORY)
		var heard2: Dictionary = SyncDoc.trim_heard((by_p[p] as Dictionary)["heard"])
		if h != "" or not heard2.is_empty():
			out[p] = {"h": h, "heard": heard2}
	return SyncDoc.prune_phon(out)


static func _merge(reps: Array, local: Dictionary, today: int, report: Dictionary) -> Dictionary:
	var view: Dictionary = SyncDoc.blank_view()
	# registers
	var regs_out := {}
	var starts: Array = []
	for r in reps:
		starts.append(((((r as Dictionary)["rep"] as Dictionary)["progress"] as Dictionary)["start"]))
	regs_out["start"] = _merge_reg(starts, Plan.DEFAULT_START)
	view["start"] = (regs_out["start"] as Dictionary)["value"]
	for k in SyncDoc.SHARED_PREFS.keys():
		var regs: Array = []
		for r in reps:
			regs.append((((r as Dictionary)["rep"] as Dictionary)["prefs"] as Dictionary)[k])
		regs_out["prefs." + k] = _merge_reg(regs, SyncDoc.SHARED_PREFS[k])
		(view["prefs"] as Dictionary)[k] = (regs_out["prefs." + k] as Dictionary)["value"]
	# counters
	for l in SyncDoc.LANGS:
		var sx: int = 0
		var stx := {}
		for k in SyncDoc.STAT_KEYS:
			stx[k] = 0
		for r in reps:
			var prog: Dictionary = ((r as Dictionary)["rep"] as Dictionary)["progress"]
			sx += int((prog["xp"] as Dictionary)[l])
			for k in SyncDoc.STAT_KEYS:
				stx[k] = int(stx[k]) + int((((prog["stats"] as Dictionary)[l]) as Dictionary)[k])
		(view["xp"] as Dictionary)[l] = clampi(sx, 0, SyncDoc.MAX_LEAF)
		for k in SyncDoc.STAT_KEYS:
			(((view["stats"] as Dictionary)[l]) as Dictionary)[k] = clampi(int(stx[k]), 0, SyncDoc.MAX_LEAF)
	# per-day records
	var min_day: int = today - (SyncDoc.KEEP_DAYS - 1)
	var acc := {}
	var day_ok := {}
	for r in reps:
		var dd: Dictionary = (((r as Dictionary)["rep"] as Dictionary)["studylog"] as Dictionary)["days"]
		for iso in dd:
			if not day_ok.has(iso):
				day_ok[iso] = today <= 0 or SyncDoc.iso_days(iso) >= min_day
			if not day_ok[iso]:
				continue
			if not acc.has(iso):
				acc[iso] = {}
			var per: Dictionary = dd[iso]
			for l in per:
				var src: Dictionary = per[l]
				if not (acc[iso] as Dictionary).has(l):
					(acc[iso] as Dictionary)[l] = {"sec": 0, "by": {}, "n": {}, "lesson": [0, 0], "score": [0, 0]}
				var dst: Dictionary = (acc[iso] as Dictionary)[l]
				dst["sec"] = int(dst["sec"]) + int(src["sec"])
				for part in ["by", "n"]:
					var dp: Dictionary = dst[part]
					for k in (src[part] as Dictionary):
						dp[k] = int(dp.get(k, 0)) + int((src[part] as Dictionary)[k])
				for part in ["lesson", "score"]:
					(dst[part] as Array)[0] = int((dst[part] as Array)[0]) + int((src[part] as Array)[0])
					(dst[part] as Array)[1] = int((dst[part] as Array)[1]) + int((src[part] as Array)[1])
	var vdays := {}
	for iso in acc:
		var one := {}
		for l in (acc[iso] as Dictionary):
			var rec: Dictionary = SyncDoc.clean_rec((acc[iso] as Dictionary)[l])
			if SyncDoc.rec_nonzero(rec):
				one[l] = rec
		if not one.is_empty():
			vdays[iso] = one
	view["days"] = vdays
	# phonemes, missions
	for l in SyncDoc.LANGS:
		(view["phon"] as Dictionary)[l] = _merge_phon(reps, l)
	var mis := {}
	for r in reps:
		var rm: Dictionary = (((r as Dictionary)["rep"] as Dictionary)["studylog"] as Dictionary)["missions"]
		for id in rm:
			var src2: Dictionary = rm[id]
			if not mis.has(id):
				mis[id] = {"stars": 0, "plays": 0, "last": "", "done_goals": 0}
			var dm: Dictionary = mis[id]
			dm["stars"] = maxi(int(dm["stars"]), int(src2["stars"]))
			dm["done_goals"] = maxi(int(dm["done_goals"]), int(src2["done_goals"]))
			dm["last"] = _later_iso(str(dm["last"]), str(src2["last"]))
			dm["plays"] = mini(int(dm["plays"]) + int(src2["plays"]), SyncDoc.MAX_COUNT)
	view["missions"] = SyncDoc.clean_missions(mis)
	# sets
	var sets := {}
	for name in _SETS:
		sets[name] = _merge_set(reps, name)
	view["checks"] = _sorted_keys((sets["checks"] as Dictionary)["present"])
	view["marks"] = _sorted_keys((sets["marks"] as Dictionary)["present"])
	var trimmed_known: int = 0
	for l in SyncDoc.LANGS:
		var ordered: Array = _order_by_add((sets["known." + l] as Dictionary)["present"])
		if ordered.size() > SyncDoc.MAX_KNOWN:
			trimmed_known += ordered.size() - SyncDoc.MAX_KNOWN
			ordered = ordered.slice(ordered.size() - SyncDoc.MAX_KNOWN)
		(view["known"] as Dictionary)[l] = ordered
	# cards: the winner per key; keys without any card data cannot be shown
	var cpresent: Dictionary = (sets["cards"] as Dictionary)["present"]
	var nodata: Array = []
	var winners := {}
	for k in cpresent:
		var win: Dictionary = {}
		for r in reps:
			var data: Dictionary = ((((r as Dictionary)["rep"] as Dictionary)["progress"] as Dictionary)["cards"] as Dictionary)["data"]
			if data.has(k):
				var cand: Dictionary = data[k]
				if win.is_empty() or card_wins(cand, win):
					win = cand
		if win.is_empty():
			nodata.append(k)
		else:
			winners[k] = win
	for k in nodata:
		cpresent.erase(k)
	var corder: Array = _order_by_add(cpresent)
	var trimmed_cards: int = 0
	var cut_cards := {} ## key -> true: present but over the limit (kept in the hub copy, not shown)
	if corder.size() > SyncDoc.MAX_CARDS:
		trimmed_cards = corder.size() - SyncDoc.MAX_CARDS
		# the cards with the least study history go first: reps low -> last_review old -> key.
		# The newest PROTECT_NEW cards (latest add time) go last, so a card the user just made is not the one that disappears.
		var protect := {}
		for i in range(maxi(0, corder.size() - PROTECT_NEW), corder.size()):
			protect[corder[i]] = true
		var cmp := func(a: Variant, b: Variant) -> bool:
			var wa: Dictionary = winners[a]
			var wb: Dictionary = winners[b]
			if wa["reps"] != wb["reps"]:
				return wa["reps"] < wb["reps"]
			if wa["last_review"] != wb["last_review"]:
				return wa["last_review"] < wb["last_review"]
			return str(a) < str(b)
		var rank: Array = []
		var rank_protected: Array = []
		for k in corder:
			if protect.has(k):
				rank_protected.append(k)
			else:
				rank.append(k)
		rank.sort_custom(cmp)
		rank_protected.sort_custom(cmp)
		rank.append_array(rank_protected)
		for i in trimmed_cards:
			cut_cards[rank[i]] = true
		var kept_order: Array = []
		for k in corder:
			if not cut_cards.has(k):
				kept_order.append(k)
		corder = kept_order
	var local_ids := {}
	for c in (local["cards"] as Array):
		var cid: String = str((c as Dictionary)["id"])
		if cid != "" and not local_ids.has((c as Dictionary)["key"]):
			local_ids[(c as Dictionary)["key"]] = cid
	var used := {}
	var assigned := {}
	for k in corder:
		if local_ids.has(k) and not used.has(local_ids[k]):
			assigned[k] = local_ids[k]
			used[local_ids[k]] = true
	var cards: Array = []
	for k in corder:
		var w: Dictionary = (winners[k] as Dictionary).duplicate()
		var id: String = str(assigned.get(k, ""))
		if id == "":
			id = str(w.get("id", ""))
			if id == "" or used.has(id):
				id = SyncDoc.gen_id(k, used)
			used[id] = true
		w["key"] = k
		w["id"] = id
		cards.append(w)
	view["cards"] = cards
	report["trimmed"] = {"cards": trimmed_cards, "known": trimmed_known}
	return {"view": view, "sets": sets, "nodata": nodata, "regs": regs_out, "cut_cards": cut_cards, "winners": winners}


# ---------------------------------------------------------------- step 4: adopt

## Brings own' in line with the merged result: every shown item gets the merged add time, card data = the winner,
## registers and mission bests = the merged values. Counters and phoneme observations stay this device's own.
static func _adopt(own: Dictionary, m: Dictionary, rebase_at: int) -> void:
	var view: Dictionary = m["view"]
	var sets: Dictionary = m["sets"]
	var prog: Dictionary = own["progress"]
	var shown := {
		"checks": view["checks"], "marks": view["marks"],
		"known.en": (view["known"] as Dictionary)["en"], "known.ja": (view["known"] as Dictionary)["ja"],
	}
	var ckeys: Array = []
	for c in (view["cards"] as Array):
		ckeys.append((c as Dictionary)["key"])
	shown["cards"] = ckeys
	for name in _SETS:
		var s: Dictionary = _set_of(own, name)
		var add: Dictionary = s["add"]
		var merged: Dictionary = sets[name]
		for k in (shown[name] as Array):
			add[k] = merged["add_max"][k]
	# card data: the winner of every shown card, plus (within the hub size limit) the cards that were cut from the view
	var cards_set: Dictionary = prog["cards"]
	var keep: Dictionary = cards_set["data"]
	for c in (view["cards"] as Array):
		var cd: Dictionary = (c as Dictionary).duplicate()
		cd.erase("key")
		keep[(c as Dictionary)["key"]] = cd
	var cut: Array = (m["cut_cards"] as Dictionary).keys()
	var winners: Dictionary = m["winners"]
	var room: int = SyncDoc.LIM_CARDS - (view["cards"] as Array).size()
	cut.sort_custom(func(a: Variant, b: Variant) -> bool: # most study history first
		var wa: Dictionary = winners[a]
		var wb: Dictionary = winners[b]
		if wa["reps"] != wb["reps"]:
			return wa["reps"] > wb["reps"]
		if wa["last_review"] != wb["last_review"]:
			return wa["last_review"] > wb["last_review"]
		return str(a) < str(b))
	for i in cut.size():
		var ck: String = cut[i]
		if i < room:
			var wd: Dictionary = (winners[ck] as Dictionary).duplicate()
			wd.erase("key")
			keep[ck] = wd
			(cards_set["add"] as Dictionary)[ck] = (sets["cards"] as Dictionary)["add_max"][ck]
		else:
			keep.erase(ck)
			(cards_set["add"] as Dictionary).erase(ck)
	# stale adds of deleted items go now (their delete event wins), so they cannot come back once the delete event expires;
	# a rebase round keeps them (the item is re-added from sets_at)
	if rebase_at < 0:
		for name in _SETS:
			var add2: Dictionary = _set_of(own, name)["add"]
			var present: Dictionary = (sets[name] as Dictionary)["present"]
			for k in add2.keys():
				if not present.has(k) and not (name == "cards" and (m["nodata"] as Array).has(k)):
					add2.erase(k)
					if name == "cards":
						keep.erase(k)
	for k in keep.keys():
		if not (cards_set["add"] as Dictionary).has(k):
			keep.erase(k)
	# registers: merged value and merged time
	var regs: Dictionary = m["regs"]
	prog["start"] = regs["start"]
	var prefs: Dictionary = own["prefs"]
	for k in SyncDoc.SHARED_PREFS.keys():
		prefs[k] = regs["prefs." + k]
	# missions: bests
	var omis: Dictionary = (own["studylog"] as Dictionary)["missions"]
	for id in (view["missions"] as Dictionary):
		var vm: Dictionary = (view["missions"] as Dictionary)[id]
		var om: Dictionary = {"stars": 0, "plays": 0, "last": "", "done_goals": 0}
		if omis.has(id):
			om = omis[id]
		om["stars"] = vm["stars"]
		om["done_goals"] = vm["done_goals"]
		om["last"] = vm["last"]
		omis[id] = om


# ---------------------------------------------------------------- step 5: check (§7.2)

static func _geti(d: Variant, path: Array) -> int:
	var cur: Variant = d
	for p in path:
		if cur is Dictionary and (cur as Dictionary).has(p):
			cur = (cur as Dictionary)[p]
		elif cur is Array and p is int and p >= 0 and p < (cur as Array).size():
			cur = (cur as Array)[p]
		else:
			return -1
	if cur is int:
		return cur
	return -1


static func _same_section(a: Variant, b: Variant) -> bool:
	if a is Array and b is Array and (a as Array).size() == (b as Array).size():
		var all_str := true
		for e in (a as Array):
			if not (e is String):
				all_str = false
				break
		if all_str:
			return a == b
	return canonical(a) == canonical(b)


## Checks a merge result against the local view. Returns [] when it is fine, else problem strings
## (key names and paths only, never values). ctx = {reps, sets, today, trimmed, nodata}.
static func check(local: Dictionary, view: Dictionary, ctx: Dictionary) -> Array:
	var problems: Array = []
	var reps: Array = ctx.get("reps", [])
	var today: int = int(ctx.get("today", 0))
	var trimmed: Dictionary = ctx.get("trimmed", {"cards": 0, "known": 0})
	var nodata := {}
	for k in ctx.get("nodata", []):
		nodata[k] = true
	# 5. shape: the result must already be in normal form (types, ranges, caps, sort order of the key lists)
	var clean: Dictionary = SyncDoc.norm_view(view)
	for sec in ["start", "checks", "marks", "xp", "stats", "days", "phon", "missions", "prefs", "cards"]:
		if not view.has(sec):
			problems.append("view.%s: missing" % sec)
		elif not _same_section(view[sec], clean[sec]):
			problems.append("view.%s: not normalized" % sec)
	if not view.has("known") or not (view["known"] is Dictionary):
		problems.append("view.known: missing")
	else:
		for l in SyncDoc.LANGS:
			if not _same_section((view["known"] as Dictionary).get(l, null), (clean["known"] as Dictionary)[l]):
				problems.append("view.known.%s: not normalized" % l)
	if not problems.is_empty():
		return problems
	var ids := {}
	for c in (view["cards"] as Array):
		var cid: String = str((c as Dictionary)["id"])
		if cid == "" or ids.has(cid):
			problems.append("view.cards: id")
			break
		ids[cid] = true
	if (view["cards"] as Array).size() > SyncDoc.MAX_CARDS:
		problems.append("view.cards: over limit")
	for l in SyncDoc.LANGS:
		if ((view["known"] as Dictionary)[l] as Array).size() > SyncDoc.MAX_KNOWN:
			problems.append("view.known.%s: over limit" % l)
	if not problems.is_empty():
		return problems
	# 1. counters never shrink (days outside the kept period are ignored)
	for l in SyncDoc.LANGS:
		if int((view["xp"] as Dictionary)[l]) < int((local["xp"] as Dictionary)[l]):
			problems.append("xp.%s" % l)
		for k in SyncDoc.STAT_KEYS:
			if int((((view["stats"] as Dictionary)[l]) as Dictionary)[k]) < int((((local["stats"] as Dictionary)[l]) as Dictionary)[k]):
				problems.append("stats.%s.%s" % [l, k])
	var min_day: int = today - (SyncDoc.KEEP_DAYS - 1)
	for iso in (local["days"] as Dictionary):
		if today > 0 and SyncDoc.iso_days(iso) < min_day:
			continue
		for l in ((local["days"] as Dictionary)[iso] as Dictionary):
			var lr: Dictionary = ((local["days"] as Dictionary)[iso] as Dictionary)[l]
			var vr: Variant = null
			if (view["days"] as Dictionary).has(iso):
				vr = ((view["days"] as Dictionary)[iso] as Dictionary).get(l, null)
			if not (vr is Dictionary):
				problems.append("days.%s.%s" % [iso, l])
				continue
			var v: Dictionary = vr
			if int(v["sec"]) < int(lr["sec"]):
				problems.append("days.%s.%s.sec" % [iso, l])
			for part in ["by", "n"]:
				if (v[part] as Dictionary).size() < SyncDoc.MAX_KEYS:
					for k in (lr[part] as Dictionary):
						if int((v[part] as Dictionary).get(k, 0)) < int((lr[part] as Dictionary)[k]):
							problems.append("days.%s.%s.%s" % [iso, l, part])
							break
			for part in ["lesson", "score"]:
				for i in 2:
					if int((v[part] as Array)[i]) < int((lr[part] as Array)[i]):
						problems.append("days.%s.%s.%s" % [iso, l, part])
						break
		if problems.size() > 40:
			break
	# 4. missions never shrink
	for id in (local["missions"] as Dictionary):
		var lm: Dictionary = (local["missions"] as Dictionary)[id]
		if not (view["missions"] as Dictionary).has(id):
			if (view["missions"] as Dictionary).size() < SyncDoc.MAX_MISSIONS:
				problems.append("missions.%s" % id)
			continue
		var vm: Dictionary = (view["missions"] as Dictionary)[id]
		for f in ["stars", "done_goals", "plays"]:
			if int(vm[f]) < int(lm[f]):
				problems.append("missions.%s.%s" % [id, f])
	# 2. a local item may only be missing when another device deleted it later than every add (recomputed here)
	var vsets := {"checks": view["checks"], "marks": view["marks"],
		"known.en": (view["known"] as Dictionary)["en"], "known.ja": (view["known"] as Dictionary)["ja"]}
	var vc: Array = []
	for c in (view["cards"] as Array):
		vc.append((c as Dictionary)["key"])
	vsets["cards"] = vc
	for name in _SETS:
		var shown := {}
		for k in (vsets[name] as Array):
			shown[k] = true
		var at_cap: bool = false
		if name == "cards":
			at_cap = int(trimmed.get("cards", 0)) > 0
		elif name.begins_with("known."):
			at_cap = int(trimmed.get("known", 0)) > 0
		for k in _local_keys(local, name):
			if shown.has(k) or at_cap:
				continue
			var add_all: int = -1
			var del_peer: int = -1
			for r in reps:
				var s: Dictionary = _set_of((r as Dictionary)["rep"], name)
				add_all = maxi(add_all, int((s["add"] as Dictionary).get(k, -1)))
				if bool((r as Dictionary)["peer"]):
					del_peer = maxi(del_peer, int((s["del"] as Dictionary).get(k, -1)))
			if name == "cards" and nodata.has(k):
				continue
			if del_peer <= add_all or del_peer < 0:
				problems.append("%s: item removed" % name)
				break
	# 3. cards: reps never go down, and the number of cards matches what the replicas say (recomputed here)
	var vby := {}
	for c in (view["cards"] as Array):
		vby[(c as Dictionary)["key"]] = c
	for c in (local["cards"] as Array):
		var key: String = (c as Dictionary)["key"]
		if vby.has(key) and int((vby[key] as Dictionary)["reps"]) < int((c as Dictionary)["reps"]):
			problems.append("cards.reps")
			break
	var union := {}
	for r in reps:
		var cs: Dictionary = ((((r as Dictionary)["rep"] as Dictionary)["progress"] as Dictionary)["cards"] as Dictionary)
		for k in (cs["data"] as Dictionary):
			union[k] = true
	var expected: int = 0
	for k in union:
		var a2: int = -1
		var d2: int = -1
		for r in reps:
			var cs2: Dictionary = ((((r as Dictionary)["rep"] as Dictionary)["progress"] as Dictionary)["cards"] as Dictionary)
			a2 = maxi(a2, int((cs2["add"] as Dictionary).get(k, -1)))
			d2 = maxi(d2, int((cs2["del"] as Dictionary).get(k, -1)))
		if a2 >= 0 and (d2 < 0 or a2 >= d2):
			expected += 1
	if (view["cards"] as Array).size() < expected - int(trimmed.get("cards", 0)):
		problems.append("cards: count")
	# 6. JSON round trip
	var js := JSON.new()
	if js.parse(JSON.stringify(view)) != OK:
		problems.append("json: parse")
	elif canonical(js.data) != canonical(view):
		problems.append("json: round trip")
	return problems


# ---------------------------------------------------------------- report

static func _fill_changes(report: Dictionary, local: Dictionary, view: Dictionary) -> void:
	var ch: Dictionary = report["changes"]
	var lcards := {}
	for c in (local["cards"] as Array):
		lcards[(c as Dictionary)["key"]] = c
	var vcards := {}
	for c in (view["cards"] as Array):
		vcards[(c as Dictionary)["key"]] = c
	var added: int = 0
	var updated: int = 0
	for k in vcards:
		if not lcards.has(k):
			added += 1
		elif canonical(vcards[k]) != canonical(lcards[k]):
			updated += 1
	var removed: int = 0
	for k in lcards:
		if not vcards.has(k):
			removed += 1
	ch["cards_added"] = added
	ch["cards_removed"] = removed
	ch["cards_updated"] = updated
	for name in ["checks", "marks"]:
		var ls := {}
		for k in (local[name] as Array):
			ls[k] = true
		var vs := {}
		for k in (view[name] as Array):
			vs[k] = true
		var n: int = 0
		for k in vs:
			if not ls.has(k):
				n += 1
		for k in ls:
			if not vs.has(k):
				n += 1
		ch[name + "_changed"] = n
	var kadd: int = 0
	var krem: int = 0
	for l in SyncDoc.LANGS:
		var lk := {}
		for k in ((local["known"] as Dictionary)[l] as Array):
			lk[k] = true
		var vk := {}
		for k in ((view["known"] as Dictionary)[l] as Array):
			vk[k] = true
			if not lk.has(k):
				kadd += 1
		for k in lk:
			if not vk.has(k):
				krem += 1
	ch["known_added"] = kadd
	ch["known_removed"] = krem
	var other := false
	for sec in ["start", "xp", "stats", "days", "phon", "missions", "prefs"]:
		if canonical(local[sec]) != canonical(view[sec]):
			other = true
			break
	ch["other_changed"] = other
	report["changed"] = other or added > 0 or removed > 0 or updated > 0 or int(ch["checks_changed"]) > 0 \
		or int(ch["marks_changed"]) > 0 or kadd > 0 or krem > 0
