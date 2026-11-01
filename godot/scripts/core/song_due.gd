class_name SongDue
extends RefCounted
## 홈의 "노래 외우기 N줄" 줄이 쓰는 집계. 순수 계산 + 읽기 전용 파일 읽기(곡 폴더를 옮기거나 쓰지 않는다).
## 홈은 보일 때마다 Thread 로 compute() 를 돌리고, 끝나면 메인 스레드가 store() 로 `cache` 를 채워 노래 줄만 다시 그린다.
## compute() 는 SongStore.list_snapshot()/memo_summary() 만 쓴다(정적 변수 대입·파일 이동 없음).
##
## lister 계약 (시험이 가짜를 넣는다): () -> {"list": [곡 사전...], "memo": {곡 id: memo_summary 사전}}
##   SongView._default_load() 가 돌려주는 모양과 같다. 곡 사전은 "id", "kind"("lyrics"|"audio") 만 쓴다.
##   모양이 틀린 값(null, 문자열, 사전이 아닌 원소, 음수·문자열 숫자)은 에러 없이 0 으로 센다.

const MIN_GAP_SEC := 30 ## 마지막 읽기에서 이만큼 안 지났으면 홈은 다시 읽지 않는다
const MAX_COUNT := 1000000 ## 곡 하나의 줄 수 상한(깨진 값 방어)

## at 0 = 아직 안 읽음. songs = 곡 수, lyrics = 그 중 가사 곡 수, due = 지금 외울 줄 합, fresh = 아직 안 외운 새 줄 합
static var cache: Dictionary = {"songs": 0, "lyrics": 0, "due": 0, "fresh": 0, "at": 0}


static func _blank(at: int) -> Dictionary:
	return {"songs": 0, "lyrics": 0, "due": 0, "fresh": 0, "at": at}


static func _count(v: Variant) -> int:
	if v is int:
		return clampi(v, 0, MAX_COUNT)
	if v is float and is_finite(v):
		return clampi(int(clampf(v, 0.0, float(MAX_COUNT))), 0, MAX_COUNT)
	return 0


## 곡 목록을 세어 결과를 돌려준다. **공유 상태(`cache`)를 쓰지 않는다**: 작업 스레드에서 불러도 된다(읽기만 한다).
## 결과를 `cache` 에 넣는 것은 메인 스레드의 몫이다(store). 정적 변수 대입은 스레드에 안전하지 않다.
## lister 가 비어 있으면 SongStore.list() + memo_summary. 시험 보호가 실제 곡 폴더를 막고 있으면 폴더를 열지 않고 0.
static func compute(lister: Callable = Callable()) -> Dictionary:
	var now: int = int(Time.get_unix_time_from_system())
	var raw: Variant = null
	if lister.is_valid():
		raw = lister.call()
	elif not SongStore.blocked():
		raw = _default_list(now)
	return _tally(raw, now)


## 메인 스레드 전용: compute() 결과를 `cache` 에 넣는다. 사전이 아니면 아무것도 바꾸지 않는다.
static func store(res: Variant) -> void:
	if res is Dictionary:
		cache = (res as Dictionary).duplicate()


## compute() + store(): 메인 스레드에서 바로 부르는 경우(시험·직접 호출). 스레드에서 부르지 말 것(compute 를 쓴다).
static func scan(lister: Callable = Callable()) -> Dictionary:
	var res: Dictionary = compute(lister)
	store(res)
	return res.duplicate()


static func _default_list(now: int) -> Dictionary:
	# SongStore.list_snapshot() is the read-only listing: it assigns no SongStore static and moves no file (a broken
	# song.json is only ignored here; the song screen moves it when it loads the list on the main thread).
	var l: Array = SongStore.list_snapshot(false, {}, false)["list"]
	var memo: Dictionary = {}
	for s in l:
		if s is Dictionary and str((s as Dictionary).get("kind", "audio")) == "lyrics":
			var sid: String = str((s as Dictionary).get("id", ""))
			memo[sid] = SongStore.memo_summary(sid, now)
	return {"list": l, "memo": memo}


static func _tally(raw: Variant, now: int) -> Dictionary:
	var res: Dictionary = _blank(now)
	if not (raw is Dictionary):
		return res
	var l: Variant = (raw as Dictionary).get("list", [])
	var memo: Variant = (raw as Dictionary).get("memo", {})
	if not (l is Array):
		return res
	if not (memo is Dictionary):
		memo = {}
	for s in (l as Array):
		if not (s is Dictionary):
			continue
		res["songs"] = int(res["songs"]) + 1
		if str((s as Dictionary).get("kind", "audio")) != "lyrics":
			continue
		res["lyrics"] = int(res["lyrics"]) + 1
		var m: Variant = (memo as Dictionary).get(str((s as Dictionary).get("id", "")), {})
		if m is Dictionary:
			res["due"] = int(res["due"]) + _count((m as Dictionary).get("due", 0))
			res["fresh"] = int(res["fresh"]) + _count((m as Dictionary).get("fresh", 0))
	return res


## 외울 줄 수(마지막으로 읽은 값).
static func due_lines() -> int:
	return int(cache.get("due", 0))


## 홈이 다시 읽어야 하는가: 아직 안 읽었거나 마지막 읽기에서 MIN_GAP_SEC 이상 지났거나 시계가 거꾸로 갔을 때.
static func needs_scan(now: int, min_gap: int = MIN_GAP_SEC) -> bool:
	var at: int = int(cache.get("at", 0))
	if at <= 0 or now < at:
		return true
	return now - at >= min_gap
