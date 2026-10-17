class_name MissionLogic
extends RefCounted
## 롤플레이 미션의 순수 계산 (별점, XP, 대본 모드 진행, 서버 응답 정리). 화면(MissionScreen)과 테스트가 함께 쓴다.
## 노드·네트워크·저장소를 건드리지 않는다. 설계: docs/english_v11_design.md 5장 F1.

const PASS_SIM := 60          ## 대본 모드: 모범 답과 이만큼 비슷하면 통과
const MAX_FAILS := 3          ## 대본 모드: 이 횟수만큼 틀리면 모범 답을 보여 주고 넘어감
const MAX_TEXT := 300         ## 보내는 문장 길이 한도 (서버도 300자에서 자른다)
const DEFAULT_MAX_TURNS := 10
const MAX_GOALS := 12         ## 방어: 목표가 이 이상이면 앞 12개만 (정상 데이터는 3~5개)
const MAX_SCRIPT := 24

## 목표를 달성한 방법 (done 딕셔너리의 값)
const BY_RULE := "rule"
const BY_MANUAL := "manual"
const BY_AI := "ai"


# ---------------------------------------------------------------- 별점 · XP

static func ratio(done: int, total: int) -> float:
	if total <= 0:
		return 0.0
	return clampf(float(done) / float(total), 0.0, 1.0)


## 별 3: 전부 달성 + 학습자 턴이 한도 이내. 별 2: 60% 이상. 별 1: 하나라도. 별 0: 그 외.
static func stars(done: int, total: int, learner_turns: int, max_turns: int) -> int:
	if total <= 0 or done <= 0:
		return 0
	var d: int = mini(done, total)
	if d == total and learner_turns <= max_turns:
		return 3
	if d * 10 >= total * 6:
		return 2
	return 1


## XP = 20 + 10 x 달성 목표 + 10 x 별
static func xp(done: int, star_count: int) -> int:
	return 20 + 10 * maxi(0, done) + 10 * clampi(star_count, 0, 3)


## 오늘 공부로 기록할지: 달성 1개 이상 또는 학습자 턴 3회 이상
static func marks_today(done: int, learner_turns: int) -> bool:
	return done >= 1 or learner_turns >= 3


static func star_text(n: int) -> String:
	var c: int = clampi(n, 0, 3)
	return "★".repeat(c) + "☆".repeat(3 - c)


## goals 중 done 에 들어 있는 것의 개수 (목록에 없는 id 는 세지 않는다)
static func count_done(goals: Array, done: Dictionary) -> int:
	var n := 0
	for g in goals:
		if g is Dictionary and done.has(str((g as Dictionary).get("id", ""))):
			n += 1
	return n


static func pending_ids(goals: Array, done: Dictionary) -> Array:
	var out: Array = []
	for g in goals:
		if g is Dictionary:
			var id: String = str((g as Dictionary).get("id", ""))
			if id != "" and not done.has(id):
				out.append(id)
	return out


static func goal_ids(goals: Array) -> Array:
	var out: Array = []
	for g in goals:
		if g is Dictionary and str((g as Dictionary).get("id", "")) != "":
			out.append(str((g as Dictionary)["id"]))
	return out


## 끝낼 때가 됐는지: 전부 달성했거나 학습자 턴이 한도에 닿음
static func should_end(done: int, total: int, learner_turns: int, max_turns: int) -> bool:
	if total > 0 and done >= total:
		return true
	return max_turns > 0 and learner_turns >= max_turns


## 보낼 문장 정리: 앞뒤 공백 제거 + 300자까지
static func clean_text(s: String) -> String:
	return s.strip_edges().left(MAX_TEXT)


# ---------------------------------------------------------------- 서버 응답 정리

static func _int(v: Variant, default_value: int) -> int:
	if v is int:
		return v
	if v is float and not is_nan(v) and not is_inf(v):
		return int(v)
	return default_value


## 미션 하나를 화면이 쓰는 모양으로 정리. 쓸 수 없는 데이터면 {} (id/제목/목표가 없을 때).
static func normalize_mission(raw: Variant) -> Dictionary:
	if not (raw is Dictionary):
		return {}
	var m: Dictionary = raw
	var id: String = str(m.get("id", "")).strip_edges()
	var title: String = str(m.get("title_ko", "")).strip_edges()
	if id == "" or title == "":
		return {}
	var goals: Array = []
	var seen := {}
	var raw_goals: Variant = m.get("goals", [])
	if raw_goals is Array:
		for g in raw_goals:
			if not (g is Dictionary):
				continue
			var gid: String = str((g as Dictionary).get("id", "")).strip_edges()
			if gid == "" or seen.has(gid) or goals.size() >= MAX_GOALS:
				continue
			seen[gid] = true
			goals.append({
				"id": gid,
				"label_ko": str((g as Dictionary).get("label_ko", gid)),
				"hint_en": str((g as Dictionary).get("hint_en", "")),
			})
	if goals.is_empty():
		return {}
	var script: Array = []
	var raw_script: Variant = m.get("script", [])
	if raw_script is Array:
		for ln in raw_script:
			if ln is Dictionary and str((ln as Dictionary).get("ai", "")).strip_edges() != "" and script.size() < MAX_SCRIPT:
				script.append({
					"ai": str((ln as Dictionary)["ai"]).strip_edges(),
					"goal": str((ln as Dictionary).get("goal", "")),
					"model": str((ln as Dictionary).get("model", "")).strip_edges(),
				})
	var scenario: Dictionary = m["scenario"] if m.get("scenario", null) is Dictionary else {}
	var max_turns: int = _int(m.get("max_turns", DEFAULT_MAX_TURNS), DEFAULT_MAX_TURNS)
	if max_turns < 1:
		max_turns = DEFAULT_MAX_TURNS
	return {
		"id": id,
		"title_ko": title,
		"situation_ko": str(m.get("situation_ko", "")),
		"min_stage": clampi(_int(m.get("min_stage", 1), 1), 1, 4),
		"max_turns": max_turns,
		"opening": str(m.get("opening", "")).strip_edges(),
		"goals": goals,
		"scenario": scenario,
		"script": script,
	}


## GET /missions 응답 -> {missions: Array, unsupported: bool, message: String}. 이상한 항목은 건너뛴다.
static func parse_list(data: Variant) -> Dictionary:
	var out := {"missions": [], "unsupported": false, "message": ""}
	if not (data is Dictionary):
		return out
	var d: Dictionary = data
	out["unsupported"] = bool(d.get("unsupported", false))
	out["message"] = str(d.get("message", ""))
	var raw: Variant = d.get("missions", [])
	if raw is Array:
		var ids := {}
		for r in raw:
			var m: Dictionary = normalize_mission(r)
			if m.is_empty() or ids.has(m["id"]):
				continue
			ids[m["id"]] = true
			(out["missions"] as Array).append(m)
	return out


## 사용자 단계에 맞는 미션(min_stage <= stage)을 먼저, 그 안에서는 원래 순서 유지.
static func sort_for_stage(missions: Array, stage: int) -> Array:
	var fit: Array = []
	var later: Array = []
	for m in missions:
		if int((m as Dictionary).get("min_stage", 1)) <= stage:
			fit.append(m)
		else:
			later.append(m)
	fit.append_array(later)
	return fit


## 모르는 id·잘못된 모양은 버리고, 이번에 새로 달성된 id 목록을 돌려준다. done[id] = BY_RULE.
static func apply_check(goals: Array, done: Dictionary, resp: Variant) -> Array:
	var fresh: Array = []
	for id in reached_ids(goals, resp):
		if not done.has(id):
			done[id] = BY_RULE
			fresh.append(id)
	return fresh


## /missions/check 응답에서 "이 문장이 닿은 목표 id" (goals[].done == true). 알려진 id 만.
static func reached_ids(goals: Array, resp: Variant) -> Array:
	var out: Array = []
	if not (resp is Dictionary):
		return out
	var known := {}
	for id in goal_ids(goals):
		known[id] = true
	var arr: Variant = (resp as Dictionary).get("goals", [])
	if not (arr is Array):
		return out
	for g in arr:
		if g is Dictionary and typeof((g as Dictionary).get("done", false)) == TYPE_BOOL and (g as Dictionary)["done"]:
			var id: String = str((g as Dictionary).get("id", ""))
			if known.has(id) and not out.has(id):
				out.append(id)
	return out


## /missions/judge 응답을 반영: pending 에 있던 id 중 done:true 이고 증거 문장이 내 발화에 들어 있는 것만 BY_AI.
## 서버도 같은 검사를 하지만 화면에서도 한 번 더 확인한다. 새로 달성된 id 를 돌려준다.
static func apply_judge(done: Dictionary, pending: Array, resp: Variant, me_texts: Array) -> Array:
	var fresh: Array = []
	if not (resp is Dictionary):
		return fresh
	var arr: Variant = (resp as Dictionary).get("goals", [])
	if not (arr is Array):
		return fresh
	var mine: Array = []
	for t in me_texts:
		mine.append(TextSim.norm_text(str(t), "en"))
	for g in arr:
		if not (g is Dictionary) or typeof((g as Dictionary).get("done", false)) != TYPE_BOOL or not (g as Dictionary)["done"]:
			continue
		var id: String = str((g as Dictionary).get("id", ""))
		var ev: String = TextSim.norm_text(str((g as Dictionary).get("evidence", "")), "en")
		if id == "" or not pending.has(id) or done.has(id) or ev == "":
			continue
		var quoted := false
		for t in mine:
			if (t as String).contains(ev):
				quoted = true
				break
		if quoted:
			done[id] = BY_AI
			fresh.append(id)
	return fresh


# ---------------------------------------------------------------- 대본 모드 (AI 없음)

static func script_new() -> Dictionary:
	return {"idx": 0, "fails": 0, "results": []}


static func script_finished(state: Dictionary, size: int) -> bool:
	return int(state.get("idx", 0)) >= size


## 내 답이 이 줄을 통과하는지: 규칙으로 줄의 목표에 닿았거나, 모범 답과 문장 유사도가 PASS_SIM 이상.
## `reached` = 이 문장이 규칙으로 닿은 목표 id 들 (서버가 안 되면 빈 배열).
static func script_passes(said: String, line: Dictionary, reached: Array) -> bool:
	if said.strip_edges() == "":
		return false
	var goal: String = str(line.get("goal", ""))
	if goal != "" and reached.has(goal):
		return true
	var model: String = str(line.get("model", ""))
	if model == "":
		return false
	return int(TextSim.similarity(said, model, "", "en")["score"]) >= PASS_SIM


## 한 번 답한 결과를 반영. outcome: "pass" | "retry" | "miss"(3번 틀려 모범 답을 보여 주고 넘어감) | "none"(이미 끝남).
## 원본 state 는 바꾸지 않는다. 반환: {state, outcome, finished}
static func script_step(state: Dictionary, size: int, passed: bool) -> Dictionary:
	var s: Dictionary = state.duplicate(true)
	if script_finished(s, size):
		return {"state": s, "outcome": "none", "finished": true}
	var outcome := "retry"
	if passed:
		outcome = "pass"
	else:
		s["fails"] = int(s["fails"]) + 1
		if int(s["fails"]) >= MAX_FAILS:
			outcome = "miss"
	if outcome != "retry":
		(s["results"] as Array).append(outcome)
		s["idx"] = int(s["idx"]) + 1
		s["fails"] = 0
	return {"state": s, "outcome": outcome, "finished": script_finished(s, size)}


# ---------------------------------------------------------------- 규칙 요약 (AI 피드백이 없을 때)

static func rule_summary(goals: Array, done: Dictionary, star_count: int, learner_turns: int) -> String:
	var total: int = goals.size()
	var n: int = count_done(goals, done)
	var lines: Array = ["목표 %d개 중 %d개를 달성했어요. 별 %d개, 말한 횟수 %d번." % [total, n, star_count, learner_turns]]
	var missing: Array = []
	for g in goals:
		if not done.has(str((g as Dictionary).get("id", ""))):
			missing.append(str((g as Dictionary).get("label_ko", "")))
	if total > 0 and missing.is_empty():
		lines.append("모든 목표를 해냈어요!")
	elif not missing.is_empty():
		lines.append("아직 못 한 목표: " + ", ".join(missing) + ". 힌트를 보고 다시 도전해 보세요.")
	return "\n".join(lines)
