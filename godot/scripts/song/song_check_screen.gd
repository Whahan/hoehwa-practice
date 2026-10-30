class_name SongCheckScreen
extends Control
## 노래 공부 U3: 가사 확인·수정 화면 (docs/song_study_design.md §4.2 7번, §4.3, §5.2, §5.4, §5.5).
##
## 곡 추가가 끝난 직후(또는 학습 화면 ⋯ 메뉴)에 열리고, 줄을 고친 뒤 [저장하고 공부하기]로 나간다.
##   - 줄 목록, 줄 탭 -> 그 줄의 편집 카드(가사 글자 · 시작/끝 시간 · 합치기 · 나누기 · 삭제 · 듣기)
##   - 시작/끝 시간: "지금 위치로"(SongPlayer 의 재생 위치, 곡 시간), ±0.1 초
##   - 전체 오프셋(song.offset, ±5 초, 0.05 단위): 소리가 가사보다 늦게 나오면 +
##   - 줄 미리 듣기: SongPlayer.play_line (고친 시간으로 다시 불러온 뒤 재생)
##   - [변경 취소] = 연 뒤(또는 마지막 저장 뒤)의 모든 변경을 되돌림, [저장하고 공부하기] = SongStore.save_song
## 모든 편집은 후보 곡을 만들어 SongModel.normalize 를 거친 것만 받아들인다(시간 불변식: 0 <= t0 < t1 <= duration,
## 줄 t0 오름차순, 줄 <= 400, 글자 <= 200). 고친 글자 · 합치거나 나눈 줄은 stale:true(읽기·해석이 옛 글자 기준),
## 합치거나 나눈 줄은 est:true(시간 추정). 줄이 옮겨지는 만큼 marks.lines · stats.best 의 줄 번호도 같이 옮긴다.
## 저장이 실패하면(SongStore.save_song == false) 화면은 그대로 두고 안내만 띄운다 - 디스크의 예전 song.json 은 그대로다.
## 일치율이 낮은 곡(경고 low_match · est_times 등)은 위쪽에 안내를 띄우고, 시간이 추정이거나 인식이 불확실한 줄을
## "확인 필요" 표시로 눈에 띄게 한다(그 줄만 모아 보기 가능).
##
## 허브 계약(PracticeView 와 같은 모양):
##   signal closed                 화면을 떠난다(저장했든 아니든). 저장했으면 그 직전에 saved(song_id) 가 한 번 나가고 result == "saved".
##   func open(lang, args)         args: {"song_id": "s_…"} (SongStore 에서 읽음) 또는 {"song": Dictionary}(시험용, id 필요)
##   func on_hide() / go_back()    on_hide: 재생을 멈춘다. go_back: 저장 안 한 변경이 있으면 확인을 묻고 true.
## 소리: `player`(SongPlayer). 시험은 open() 전에 `player = SongPlayer.new()` 에 가짜 어댑터(backend)를 달아 넣는다.
## 없으면 화면이 만들고, songs_root 는 SongStore.root 로 맞춘다.

signal closed
signal saved(song_id: String)

const MAX_TEXT := SongModel.LEN_LINE
const MIN_LINE := SongModel.MIN_LINE
const NUDGE := 0.1
const TIME_STEP := 0.01
const CONF_LOW := 0.5 ## 이보다 낮은 줄 평균 단어 확률은 "인식 불확실"
const DOUBT_WARNINGS := ["low_match", "est_times", "offset_guess", "duration_mismatch", "hallucination_cut", "no_vocals"]

const MSG_LOAD_FAIL := "곡을 불러오지 못했어요. 목록으로 돌아가서 다시 열어 주세요."
const MSG_READONLY := "더 새로운 버전의 앱에서 만든 곡이라 여기서는 고칠 수 없어요. 듣고 공부하는 것은 그대로 할 수 있어요."
const MSG_DOUBT := "이 곡은 가사와 소리가 잘 맞지 않았어요. '확인 필요' 표시가 붙은 줄(%d개)을 들어 보면서 먼저 고쳐 주세요."
const MSG_SAVE_FAIL := "저장하지 못했어요. 예전에 저장한 내용은 그대로 남아 있어요. 저장 공간을 확인한 뒤 다시 눌러 주세요. (%s)"
const MSG_AUDIO := "소리를 불러오지 못해서 듣기는 쓸 수 없어요. 글자와 시간은 고칠 수 있어요. (%s)"
const MSG_OFFSET_HINT := "소리가 가사보다 늦게 나오면 +, 빨리 나오면 −로 맞춰요. 모든 줄에 한꺼번에 적용돼요."
const MSG_TIME_HINT := "소리를 듣다가 멈춘 곳으로 맞추려면 [지금 위치로]를 눌러요."
const TAG_EST := "시간 추정"
const TAG_CONF := "인식 불확실"
const TAG_STALE := "해석 갱신 필요"

var lang: String = "en"
var song_id: String = ""
var working: Dictionary = {} ## 지금 고치는 곡 (항상 SongModel.normalize 를 거친 모양)
var original: Dictionary = {} ## 연 직후(또는 마지막 저장) 모양: [변경 취소]가 돌아가는 곳
var selected: int = -1
var read_only: bool = false
var load_error: String = ""
var save_error: String = ""
var audio_ready: bool = false
var audio_error: String = ""
var suspect_only: bool = false
var result: String = "" ## "" | "saved" | "left"
var player: SongPlayer = null
var last_note: String = "" ## 마지막 편집에서 값을 맞춰 준 이유(없으면 "")

var _shell: Dictionary = {}
var _own_player: bool = false
var _hold: float = 0.0 ## 마지막으로 알려진 재생 위치(곡 시간)
var _loaded_sig: String = ""
var _banner_box: VBoxContainer = null
var _offset_label: Label = null
var _filter_box: HFlowContainer = null
var _list_box: VBoxContainer = null
var _rows: Dictionary = {} ## 줄 번호 -> [PanelContainer, meta Label, text Label]
var _editor: Control = null
var _text_edit: LineEdit = null
var _start_val: Label = null
var _end_val: Label = null
var _title_label: Label = null
var _play_btn: Button = null
var _slider: HSlider = null
var _time_label: Label = null
var _btn_revert: Button = null
var _btn_save: Button = null
var _transport: PanelContainer = null


func _init() -> void:
	_shell = SpeakDrill.build_shell(self, go_back, "← 곡")
	(_shell["title"] as Label).text = "가사 확인"
	_build_transport()
	_build_footer()


func _exit_tree() -> void:
	if player != null and is_instance_valid(player) and _own_player:
		player.unload()


# ---------------------------------------------------------------- open / close

func open(l: String, args: Dictionary = {}) -> void:
	lang = l if l == "ja" else "en"
	load_error = ""
	save_error = ""
	result = ""
	selected = -1
	suspect_only = false
	read_only = false
	working = {}
	original = {}
	var song: Dictionary = {}
	if args.has("song_id"):
		song_id = str(args["song_id"])
		song = SongStore.load_song(song_id)
	elif args.get("song", null) is Dictionary:
		song = SongModel.normalize(args["song"])
		song_id = str(song.get("id", ""))
	if song.is_empty() or (song["lines"] as Array).is_empty():
		load_error = MSG_LOAD_FAIL
		_render()
		return
	lang = str(song.get("lang", lang))
	original = song.duplicate(true)
	working = song.duplicate(true)
	read_only = SongModel.is_read_only(song)
	_hold = 0.0
	_ensure_player()
	_load_player()
	_render()


func on_hide() -> void:
	if player != null and is_instance_valid(player) and player.is_playing():
		player.pause()


## 안드로이드 뒤로 가기 / 머리줄 버튼. 저장 안 한 변경이 있으면 확인을 묻는다. 항상 true(처리함).
func go_back() -> bool:
	_flush_text()
	if is_dirty() and not read_only:
		var sh: Sheet = Sheet.confirm(self, "저장하지 않은 변경이 있어요", "버리고 나갈까요? 고친 내용은 사라져요.", "버리고 나가기", true, "계속 고치기")
		sh.closed.connect(func(r: Variant) -> void:
			if str(r) == "ok":
				_leave())
		return true
	_leave()
	return true


func _leave() -> void:
	if player != null and is_instance_valid(player):
		player.stop()
	if result == "":
		result = "left"
	closed.emit()


# ---------------------------------------------------------------- state helpers

func line_count() -> int:
	return (working.get("lines", []) as Array).size()


func lines() -> Array:
	return working.get("lines", [])


func _json(d: Dictionary) -> String:
	return JSON.stringify(d, "", true)


func has_pending_text() -> bool:
	if _text_edit == null or not is_instance_valid(_text_edit) or selected < 0 or selected >= line_count():
		return false
	return _text_edit.text.strip_edges() != str((lines()[selected] as Dictionary)["text"])


func is_dirty() -> bool:
	if working.is_empty():
		return false
	return _json(working) != _json(original) or has_pending_text()


## 시간이 추정이거나 인식이 불확실한 줄인가: "" | "est" | "conf"
static func suspect_reason(ln: Dictionary) -> String:
	if bool(ln.get("est", false)):
		return "est"
	var c: Variant = ln.get("conf", null)
	if (c is float or c is int) and float(c) < CONF_LOW:
		return "conf"
	return ""


func suspect_indices() -> Array:
	var out: Array = []
	var ls: Array = lines()
	for i in ls.size():
		if suspect_reason(ls[i]) != "":
			out.append(i)
	return out


func is_doubtful_song() -> bool:
	var w: Variant = working.get("warnings", [])
	if w is Array:
		for x in (w as Array):
			if DOUBT_WARNINGS.has(str(x)):
				return true
	return false


static func fmt_time(t: float) -> String:
	var m: int = int(t / 60.0)
	return "%d:%05.2f" % [m, t - 60.0 * float(m)]


## "지금 위치" (곡 시간, 오프셋 반영): 재생 중이거나 멈춘 상태면 플레이어 위치, 아니면 마지막으로 알려진 위치.
func current_pos() -> float:
	if player != null and is_instance_valid(player) and player.is_loaded() and (player.is_playing() or player.is_paused()):
		_hold = player.position()
	return _hold


# ---------------------------------------------------------------- editing (public; each one ends in SongModel.normalize)

## 후보 곡을 normalize 해서 받아들인다. 비면(곡이 아니면) 거절.
func _commit(cand: Dictionary) -> bool:
	var n: Dictionary = SongModel.normalize(cand)
	if n.is_empty() or (n["lines"] as Array).is_empty():
		return false
	n["id"] = song_id
	working = n
	return true


func _can_edit(i: int) -> bool:
	return not read_only and i >= 0 and i < line_count()


## 줄 글자를 고친다. 빈 글자는 거절(지우려면 삭제). 글자가 바뀌면 stale:true.
func set_text(i: int, text: String) -> bool:
	if not _can_edit(i):
		return false
	var t: String = SongModel.clean_str(text, MAX_TEXT).strip_edges()
	if t == "":
		return false
	if t == str((lines()[i] as Dictionary)["text"]):
		return true
	var cand: Dictionary = working.duplicate(true)
	var ln: Dictionary = (cand["lines"] as Array)[i]
	ln["text"] = t
	ln["stale"] = true
	if not _commit(cand):
		return false
	_after_edit(false, i)
	return true


## 시작 시간(곡 시간, 초)을 바꾼다. 앞 줄의 시작보다 앞서거나 뒷 줄의 시작을 넘지 못하게 맞춘다(줄 순서 유지).
## 끝이 시작을 앞서게 되면 줄 길이를 유지해서 끝을 옮긴다. 단어 시간(s/e)은 시작이 옮겨진 만큼 같이 옮긴다.
func set_line_start(i: int, t: float) -> bool:
	if not _can_edit(i) or not SongModel.is_finite_num(t):
		return false
	var ls: Array = lines()
	var cur: Dictionary = ls[i]
	var old0: float = float(cur["t0"])
	var old1: float = float(cur["t1"])
	var dur: float = float(working["duration"])
	var lo: float = float((ls[i - 1] as Dictionary)["t0"]) if i > 0 else 0.0
	var hi: float = float((ls[i + 1] as Dictionary)["t0"]) if i < ls.size() - 1 else dur
	hi = minf(hi, dur - MIN_LINE)
	hi = maxf(lo, hi)
	var want: float = snappedf(t, TIME_STEP)
	var nt0: float = clampf(want, lo, hi)
	last_note = "" if is_equal_approx(nt0, want) else "앞뒤 줄의 순서를 넘을 수 없어서 %s에 맞췄어요." % fmt_time(nt0)
	var nt1: float = old1
	if nt1 < nt0 + MIN_LINE:
		nt1 = minf(nt0 + (old1 - old0), dur)
	if is_equal_approx(nt0, old0) and is_equal_approx(nt1, old1):
		return true
	var cand: Dictionary = working.duplicate(true)
	var ln: Dictionary = (cand["lines"] as Array)[i]
	ln["t0"] = nt0
	ln["t1"] = nt1
	var d: float = nt0 - old0
	if d != 0.0:
		for w in (ln["words"] as Array):
			var wd: Dictionary = w
			wd["s"] = float(wd["s"]) + d
			wd["e"] = float(wd["e"]) + d
	if not _commit(cand):
		return false
	_after_edit(false, i)
	return true


## 끝 시간(곡 시간, 초). 시작 + 0.1 초 이상, 곡 길이 이하로 맞춘다.
func set_line_end(i: int, t: float) -> bool:
	if not _can_edit(i) or not SongModel.is_finite_num(t):
		return false
	var cur: Dictionary = lines()[i]
	var dur: float = float(working["duration"])
	var lo: float = float(cur["t0"]) + MIN_LINE
	if lo > dur:
		return false
	var want: float = snappedf(t, TIME_STEP)
	var nt1: float = clampf(want, lo, dur)
	last_note = "" if is_equal_approx(nt1, want) else "끝 시간은 시작 뒤 %.1f초 ~ 곡 끝 사이로 맞춰요." % MIN_LINE
	if is_equal_approx(nt1, float(cur["t1"])):
		return true
	var cand: Dictionary = working.duplicate(true)
	((cand["lines"] as Array)[i] as Dictionary)["t1"] = nt1
	if not _commit(cand):
		return false
	_after_edit(false, i)
	return true


func nudge_line_start(i: int, d: float) -> bool:
	if not _can_edit(i):
		return false
	return set_line_start(i, float((lines()[i] as Dictionary)["t0"]) + d)


func nudge_line_end(i: int, d: float) -> bool:
	if not _can_edit(i):
		return false
	return set_line_end(i, float((lines()[i] as Dictionary)["t1"]) + d)


func set_line_start_now(i: int) -> bool:
	return set_line_start(i, current_pos())


func set_line_end_now(i: int) -> bool:
	return set_line_end(i, current_pos())


## 줄 i 와 i+1 을 한 줄로: 글자는 이어 붙이고(영어는 띄어쓰기), 시간은 [i.t0, 더 늦은 t1], est:true, stale:true.
## 합친 글자가 200자를 넘으면 거절. 표시한 줄(marks)은 합쳐지고 최고 점수(stats.best)는 버린다(글자가 달라졌으므로).
func merge_lines(i: int) -> bool:
	if read_only or i < 0 or i >= line_count() - 1:
		return false
	var cand: Dictionary = working.duplicate(true)
	var ls: Array = cand["lines"]
	var a: Dictionary = ls[i]
	var b: Dictionary = ls[i + 1]
	var sep: String = "" if lang == "ja" else " "
	var text: String = (str(a["text"]) + sep + str(b["text"])).strip_edges()
	if text.length() > MAX_TEXT:
		last_note = "합친 글자가 %d자를 넘어서 합칠 수 없어요." % MAX_TEXT
		return false
	var m: Dictionary = a.duplicate(true)
	m["text"] = text
	m["t0"] = float(a["t0"])
	m["t1"] = maxf(float(a["t1"]), float(b["t1"]))
	m["est"] = true
	m["stale"] = true
	m["reading"] = _join_text(str(a["reading"]), str(b["reading"]), sep)
	m["pron"] = _join_text(str(a["pron"]), str(b["pron"]), sep)
	m["ko"] = _join_text(str(a["ko"]), str(b["ko"]), " ")
	m["words"] = (a["words"] as Array) + (b["words"] as Array)
	var ca: Variant = a.get("conf", null)
	var cb: Variant = b.get("conf", null)
	m["conf"] = minf(float(ca), float(cb)) if (ca != null and cb != null) else null
	var out: Array = []
	for k in ls.size():
		if k == i:
			out.append(m)
		elif k != i + 1:
			out.append(ls[k])
	cand["lines"] = out
	var at: int = i
	var mapping := func(j: int) -> Array:
		if j < at:
			return [j]
		if j == at or j == at + 1:
			return [at]
		return [j - 1]
	_remap_refs(cand, mapping, [at, at + 1])
	if not _commit(cand):
		return false
	selected = i
	_after_edit(true, i)
	return true


## 줄 i 를 둘로: `at` 글자 앞에서 자른다(-1 이면 가운데 가까운 띄어쓰기). 시간은 글자 수 비례로 나눈 추정(est:true),
## 두 줄 모두 stale:true 이고 읽기·발음·해석은 비운다(옛 글자 기준이므로). 단어는 글자 순서대로 나눈다.
## 줄이 400개이거나 0.2초보다 짧거나 어느 한쪽이 비면 거절.
func split_line(i: int, at: int = -1) -> bool:
	if not _can_edit(i) or line_count() >= SongModel.MAX_LINES:
		return false
	var cand: Dictionary = working.duplicate(true)
	var ls: Array = cand["lines"]
	var ln: Dictionary = ls[i]
	var text: String = str(ln["text"])
	var cut: int = at if (at > 0 and at < text.length()) else _auto_cut(text)
	var left: String = text.substr(0, cut).strip_edges()
	var right: String = text.substr(cut).strip_edges()
	if left == "" or right == "":
		last_note = "나눌 곳을 글자 사이에 두세요."
		return false
	var t0: float = float(ln["t0"])
	var t1: float = float(ln["t1"])
	if t1 - t0 < 2.0 * MIN_LINE:
		last_note = "줄이 너무 짧아서 나눌 수 없어요."
		return false
	var frac: float = float(left.length()) / float(left.length() + right.length())
	var tm: float = snappedf(clampf(t0 + (t1 - t0) * frac, t0 + MIN_LINE, t1 - MIN_LINE), TIME_STEP)
	if i < ls.size() - 1:
		tm = minf(tm, float((ls[i + 1] as Dictionary)["t0"])) # 줄 순서 유지
	tm = maxf(tm, t0)
	var parts: Array = _split_words(ln["words"] as Array, text, cut)
	var a: Dictionary = ln.duplicate(true)
	var b: Dictionary = ln.duplicate(true)
	for pair in [[a, left, t0, tm, parts[0]], [b, right, tm, t1, parts[1]]]:
		var d: Dictionary = pair[0]
		d["text"] = pair[1]
		d["t0"] = pair[2]
		d["t1"] = pair[3]
		d["words"] = pair[4]
		d["est"] = true
		d["stale"] = true
		d["reading"] = ""
		d["pron"] = ""
		d["ko"] = ""
	var out: Array = []
	for k in ls.size():
		if k == i:
			out.append(a)
			out.append(b)
		else:
			out.append(ls[k])
	cand["lines"] = out
	var at_i: int = i
	var mapping := func(j: int) -> Array:
		if j < at_i:
			return [j]
		if j == at_i:
			return [at_i, at_i + 1]
		return [j + 1]
	_remap_refs(cand, mapping, [at_i])
	if not _commit(cand):
		return false
	selected = i
	_after_edit(true, i)
	return true


## 줄 i 를 지운다. 마지막 한 줄은 지울 수 없다.
func delete_line(i: int) -> bool:
	if not _can_edit(i) or line_count() <= 1:
		return false
	var cand: Dictionary = working.duplicate(true)
	var ls: Array = cand["lines"]
	ls.remove_at(i)
	var at_i: int = i
	var mapping := func(j: int) -> Array:
		if j < at_i:
			return [j]
		if j == at_i:
			return []
		return [j - 1]
	_remap_refs(cand, mapping)
	if not _commit(cand):
		return false
	selected = mini(i, line_count() - 1)
	_after_edit(true, selected)
	return true


## 전체 오프셋(초): -5 ~ +5, 0.05 단위로 맞춘다.
func set_song_offset(v: float) -> bool:
	if read_only or not SongModel.is_finite_num(v):
		return false
	var cand: Dictionary = working.duplicate(true)
	cand["offset"] = clampf(snappedf(v, SongModel.OFFSET_LIM / 100.0), -SongModel.OFFSET_LIM, SongModel.OFFSET_LIM)
	if not _commit(cand):
		return false
	_after_edit(false, -1)
	return true


func nudge_song_offset(d: float) -> bool:
	return set_song_offset(float(working.get("offset", 0.0)) + d)


## 변경을 모두 되돌린다(연 직후 또는 마지막 저장 뒤 모양으로).
func revert() -> void:
	if working.is_empty():
		return
	_stop_player()
	working = original.duplicate(true)
	save_error = ""
	if selected >= line_count():
		selected = line_count() - 1
	_after_edit(true, selected)


## 저장한다. 바뀐 게 없으면 쓰지 않고 true. 쓰기에 실패하면 false 와 안내(save_error)를 남기고 화면 상태는 그대로 둔다.
func save() -> bool:
	_flush_text()
	if working.is_empty():
		return false
	if read_only:
		save_error = MSG_READONLY
		_render_banners()
		return false
	if not is_dirty():
		return true
	var out: Dictionary = SongModel.normalize(working)
	out["id"] = song_id
	if SongStore.save_song(out):
		original = out.duplicate(true)
		working = out.duplicate(true)
		save_error = ""
		_refresh_chrome()
		return true
	save_error = MSG_SAVE_FAIL % SongStore.last_error
	Toast.error("저장하지 못했어요. 예전 내용은 그대로예요.")
	_render_banners()
	_refresh_chrome()
	return false


# ---------------------------------------------------------------- editing helpers

static func _join_text(a: String, b: String, sep: String) -> String:
	if a == "":
		return b
	if b == "":
		return a
	return a + sep + b


## 자를 위치: 가운데에 가장 가까운 띄어쓰기 뒤, 띄어쓰기가 없으면 가운데 글자.
static func _auto_cut(text: String) -> int:
	var mid: int = text.length() / 2
	var best: int = -1
	var best_d: int = 1 << 30
	for k in range(1, text.length() - 1):
		if text[k] == " " and absi(k - mid) < best_d:
			best = k
			best_d = absi(k - mid)
	return best if best > 0 else mid


## 단어 목록을 글자 순서대로 앞뒤로 나눈다: 단어가 글자에서 시작하는 위치가 cut 앞이면 앞쪽.
static func _split_words(words: Array, text: String, cut: int) -> Array:
	var lo: String = text.to_lower()
	var pos: int = 0
	var side: int = 0
	var left: Array = []
	var right: Array = []
	for w in words:
		var token: String = str((w as Dictionary).get("w", "")).to_lower()
		var idx: int = lo.find(token, pos) if token != "" else -1
		if idx >= 0:
			side = 0 if idx < cut else 1
			pos = idx + token.length()
		if side == 0:
			left.append(w)
		else:
			right.append(w)
	return [left, right]


## 줄 번호가 옮겨질 때 marks.lines 와 stats.best 의 번호를 따라 옮긴다. mapping(옛 번호) -> 새 번호들.
## 한 줄로 가지 않는(합쳐지거나 나뉜) 줄과 drop_best 에 든 줄의 최고 점수는 버린다.
func _remap_refs(cand: Dictionary, mapping: Callable, drop_best: Array = []) -> void:
	var marks: Dictionary = cand.get("marks", {})
	var nl: Array = []
	for x in (marks.get("lines", []) as Array):
		for y in (mapping.call(int(x)) as Array):
			if not nl.has(y):
				nl.append(y)
	nl.sort()
	marks["lines"] = nl
	cand["marks"] = marks
	var stats: Dictionary = cand.get("stats", {})
	var best: Dictionary = stats.get("best", {})
	var nb := {}
	for k in best.keys():
		var oi: int = int(str(k))
		if drop_best.has(oi):
			continue
		var m: Array = mapping.call(oi)
		if m.size() != 1:
			continue
		var key: String = str(m[0])
		nb[key] = maxi(int(nb.get(key, 0)), int(best[k]))
	stats["best"] = nb
	cand["stats"] = stats


# ---------------------------------------------------------------- player

func _ensure_player() -> void:
	SongPlayer.songs_root = SongStore.root
	if player == null:
		player = SongPlayer.new()
		_own_player = true
		add_child(player)
	if not player.position_changed.is_connected(_on_position):
		player.position_changed.connect(_on_position)
		player.finished_loop.connect(func(_c: int) -> void: _sync_transport())
		player.song_ended.connect(_sync_transport)


func _sig() -> String:
	var parts := PackedStringArray()
	parts.append(str(working.get("offset", 0.0)))
	for ln in lines():
		parts.append("%s:%s" % [(ln as Dictionary)["t0"], (ln as Dictionary)["t1"]])
	return ",".join(parts)


func _load_player() -> void:
	audio_ready = player.load_song(working)
	audio_error = "" if audio_ready else player.last_error
	_loaded_sig = _sig()


## 줄 시간이나 오프셋이 플레이어에 불러 둔 것과 달라졌으면 다시 불러온다(재생 위치는 처음으로 돌아간다).
func _ensure_fresh() -> void:
	if player == null or working.is_empty():
		return
	if _sig() != _loaded_sig:
		var pos: float = _hold
		_load_player()
		_hold = pos
		_render_banners()


func _stop_player() -> void:
	if player != null and is_instance_valid(player):
		player.stop()
	_sync_transport()


## 줄 i 를 한 번 들려준다(SongPlayer.play_line). 고친 시간이 반영되도록 필요하면 다시 불러온다.
func preview_line(i: int) -> void:
	if i < 0 or i >= line_count() or player == null:
		return
	_ensure_fresh()
	if not audio_ready:
		return
	player.play_line(i, 1)
	_sync_transport()


func toggle_play() -> void:
	if player == null or not audio_ready:
		return
	if player.is_playing():
		player.pause()
	elif player.is_paused():
		_ensure_fresh()
		if player.is_paused():
			player.resume()
		else:
			player.play_from(_hold)
	else:
		_ensure_fresh()
		player.play_from(_hold)
	_sync_transport()


## 곡 시간 t 에서부터 재생한다 (슬라이더를 놓았을 때).
func seek(t: float) -> void:
	if player == null or not audio_ready:
		return
	_hold = clampf(t, 0.0, float(working.get("duration", 0.0)))
	_ensure_fresh()
	player.play_from(_hold)
	_sync_transport()


func _on_position(t: float) -> void:
	_hold = t
	if _slider != null and is_instance_valid(_slider):
		_slider.set_value_no_signal(t)
	_sync_transport()


func _sync_transport() -> void:
	if _play_btn == null or not is_instance_valid(_play_btn):
		return
	var playing: bool = player != null and is_instance_valid(player) and player.is_playing()
	var txt: String = "멈춤" if playing else "▶ 재생"
	if _play_btn.text != txt:
		_play_btn.text = txt
	_play_btn.disabled = not audio_ready
	var dur: float = float(working.get("duration", 0.0))
	var lt: String = "%s / %s" % [fmt_time(_hold), fmt_time(dur)]
	if _time_label.text != lt:
		_time_label.text = lt
	_slider.max_value = maxf(dur, 0.1)
	_slider.editable = audio_ready


# ---------------------------------------------------------------- build (fixed parts)

func _build_transport() -> void:
	_transport = PanelContainer.new()
	var st: StyleBoxFlat = UI.style(Pal.SURFACE, Pal.LINE, 0, 0, 0, 0)
	st.border_width_bottom = 1
	_transport.add_theme_stylebox_override("panel", st)
	var col := ColumnBox.new()
	col.max_width = 720.0
	col.min_pad = Ds.S3
	col.set_padding(Ds.S2, Ds.S2)
	_transport.add_child(col)
	var row := UI.hbox(10)
	col.content.add_child(row)
	_play_btn = SpeakDrill.touch_button("▶ 재생", "soft", Pal.PRIMARY)
	_play_btn.name = "BtnPlay"
	_play_btn.pressed.connect(toggle_play)
	row.add_child(_play_btn)
	_time_label = UI.label("0:00.00 / 0:00.00", "Muted", false)
	_time_label.name = "TimeLabel"
	_time_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_time_label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_time_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	row.add_child(_time_label)
	_slider = HSlider.new()
	_slider.name = "SeekSlider"
	_slider.min_value = 0.0
	_slider.max_value = 1.0
	_slider.step = 0.01
	_slider.focus_mode = Control.FOCUS_NONE
	_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_slider.custom_minimum_size.y = maxf(40.0, Ds.touch_min())
	_slider.drag_ended.connect(func(changed: bool) -> void:
		if changed:
			seek(_slider.value))
	col.content.add_child(_slider)
	var root: VBoxContainer = _shell["root"]
	root.add_child(_transport)
	root.move_child(_transport, 1) # 머리줄 아래, 목록 위에 고정


func _build_footer() -> void:
	var fcol: ColumnBox = _shell["footer_col"]
	UI.clear(fcol.content)
	var flow := UI.flow(10, 8)
	fcol.content.add_child(flow)
	_btn_revert = SpeakDrill.touch_button("변경 취소", "outline", Pal.INK)
	_btn_revert.name = "BtnRevert"
	_btn_revert.pressed.connect(_on_revert_pressed)
	flow.add_child(_btn_revert)
	_btn_save = SpeakDrill.touch_button("저장하고 공부하기", "primary", Pal.PRIMARY)
	_btn_save.name = "BtnSave"
	_btn_save.pressed.connect(_on_save_pressed)
	flow.add_child(_btn_save)
	(_shell["footer_holder"] as PanelContainer).visible = true


# ---------------------------------------------------------------- build (page)

func _render() -> void:
	var page: PageScroll = _shell["page"]
	UI.clear(page.content)
	_rows.clear()
	_editor = null
	_text_edit = null
	_banner_box = null
	_offset_label = null
	_filter_box = null
	_list_box = null
	_title_label = null
	var c: VBoxContainer = page.content
	if working.is_empty():
		(_shell["count"] as Label).text = ""
		_transport.visible = false
		_btn_revert.disabled = true
		_btn_save.disabled = true
		c.add_child(SpeakDrill.notice(load_error if load_error != "" else MSG_LOAD_FAIL))
		return
	_transport.visible = true
	_banner_box = UI.vbox(8)
	c.add_child(_banner_box)
	_title_label = UI.label("", "Strong")
	c.add_child(_title_label)
	c.add_child(_build_offset_card())
	_filter_box = UI.flow(8, 8)
	c.add_child(_filter_box)
	_list_box = UI.vbox(8)
	_list_box.name = "LineList"
	c.add_child(_list_box)
	_rebuild_list()
	_refresh_chrome()


func _build_offset_card() -> Control:
	var card := UI.card("Card", 8)
	card.name = "OffsetCard"
	card.body.add_child(UI.label("전체 오프셋", "Eyebrow", false))
	_offset_label = UI.label("", "H3", false)
	_offset_label.name = "OffsetValue"
	card.body.add_child(_offset_label)
	if not read_only:
		var flow := UI.flow(8, 8)
		for spec in [["BtnOffM5", "−0.5초", -0.5], ["BtnOffM1", "−0.1초", -0.1], ["BtnOffP1", "+0.1초", 0.1], ["BtnOffP5", "+0.5초", 0.5]]:
			var d: float = spec[2]
			var b: Button = SpeakDrill.touch_button(spec[1], "soft", Pal.INK)
			b.name = spec[0]
			b.pressed.connect(func() -> void:
				_flush_text()
				nudge_song_offset(d))
			flow.add_child(b)
		var z: Button = SpeakDrill.touch_button("0으로", "flat", Pal.INK)
		z.name = "BtnOffZero"
		z.pressed.connect(func() -> void:
			_flush_text()
			set_song_offset(0.0))
		flow.add_child(z)
		card.body.add_child(flow)
	card.body.add_child(UI.label(MSG_OFFSET_HINT, "Small"))
	return card


func _render_banners() -> void:
	if _banner_box == null or not is_instance_valid(_banner_box):
		return
	UI.clear(_banner_box)
	if read_only:
		_banner_box.add_child(_info_box(MSG_READONLY, false))
	if is_doubtful_song():
		_banner_box.add_child(_info_box(MSG_DOUBT % suspect_indices().size(), false))
	if not audio_ready and audio_error != "":
		_banner_box.add_child(_info_box(MSG_AUDIO % audio_error, false))
	if save_error != "":
		var b: PanelContainer = _info_box(save_error, true)
		b.name = "SaveError"
		_banner_box.add_child(b)


func _info_box(msg: String, bad: bool) -> PanelContainer:
	if bad:
		return SpeakDrill.notice(msg, true)
	var p: PanelContainer = UI.tinted_panel(Pal.WARN_SOFT, Color(0, 0, 0, 0), 0, Ds.R_S, 14, 10)
	p.add_child(UI.colored(msg, Pal.WARN_ON))
	return p


## 목록 위·아래의 바뀌는 글자들(머리 줄 수, 제목, 오프셋, 모아보기 칩, 버튼 상태, 안내)을 다시 쓴다.
func _refresh_chrome() -> void:
	if working.is_empty():
		return
	(_shell["count"] as Label).text = "%d줄" % line_count()
	if _title_label != null:
		var t: String = str(working.get("title", ""))
		var ar: String = str(working.get("artist", ""))
		_title_label.text = (t if t != "" else "(제목 없음)") + ((" – " + ar) if ar != "" else "")
	if _offset_label != null:
		_offset_label.text = "%+.2f초" % float(working.get("offset", 0.0))
	_render_filter()
	_render_banners()
	var dirty: bool = is_dirty()
	_btn_revert.disabled = (not dirty) or read_only
	_btn_save.text = "공부하러 가기" if read_only else "저장하고 공부하기"
	_sync_transport()


func _render_filter() -> void:
	if _filter_box == null:
		return
	UI.clear(_filter_box)
	var n: int = suspect_indices().size()
	if n == 0 and not suspect_only:
		return
	var all_chip: Button = UI.filter_chip("전체 %d줄" % line_count(), not suspect_only, func() -> void: set_suspect_only(false))
	all_chip.name = "ChipAll"
	_filter_box.add_child(all_chip)
	var sus_chip: Button = UI.filter_chip("확인 필요 %d줄만" % n, suspect_only, func() -> void: set_suspect_only(true))
	sus_chip.name = "ChipSuspect"
	_filter_box.add_child(sus_chip)


func set_suspect_only(b: bool) -> void:
	suspect_only = b
	if b and selected >= 0 and selected < line_count() and suspect_reason(lines()[selected]) == "":
		selected = -1
	_rebuild_list()
	_refresh_chrome()


func _visible_indices() -> Array:
	var out: Array = []
	for i in line_count():
		if not suspect_only or suspect_reason(lines()[i]) != "":
			out.append(i)
	return out


func _rebuild_list() -> void:
	if _list_box == null:
		return
	UI.clear(_list_box)
	_rows.clear()
	_editor = null
	_text_edit = null
	var idxs: Array = _visible_indices()
	if idxs.is_empty():
		_list_box.add_child(UI.label("확인 필요한 줄이 없어요.", "Muted"))
		return
	for i in idxs:
		var row: PanelContainer = _make_row(i)
		_list_box.add_child(row)
	if selected >= 0 and _rows.has(selected):
		_show_editor(selected)


func _make_row(i: int) -> PanelContainer:
	var p := PanelContainer.new()
	p.name = "Row%d" % i
	p.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	p.custom_minimum_size.y = Ds.touch_min() if Platform.is_phone() else 44.0
	var v := UI.vbox(2)
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	p.add_child(v)
	var meta := UI.label("", "Small")
	meta.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.add_child(meta)
	var txt := UI.label("", "ListMain")
	txt.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.add_child(txt)
	_rows[i] = [p, meta, txt]
	UI.on_tap(p, func() -> void: select_line(i))
	_fill_row(i)
	return p


func _fill_row(i: int) -> void:
	if not _rows.has(i) or i >= line_count():
		return
	var ln: Dictionary = lines()[i]
	var p: PanelContainer = _rows[i][0]
	var meta: Label = _rows[i][1]
	var txt: Label = _rows[i][2]
	var tags: Array = ["%d" % (i + 1), "%s ~ %s" % [fmt_time(float(ln["t0"])), fmt_time(float(ln["t1"]))]]
	var why: String = suspect_reason(ln)
	if why == "est":
		tags.append(TAG_EST)
	elif why == "conf":
		tags.append(TAG_CONF)
	if bool(ln.get("stale", false)):
		tags.append(TAG_STALE)
	meta.text = " · ".join(tags)
	meta.add_theme_color_override("font_color", Pal.WARN_ON if why != "" else Pal.MUTED)
	txt.text = str(ln["text"])
	p.accessibility_name = "%d번째 줄 %s" % [i + 1, str(ln["text"])]
	var sel: bool = i == selected
	var bg: Color = Pal.PRIMARY_SOFT if sel else Pal.SURFACE
	var border: Color = Pal.PRIMARY if sel else (Pal.WARN if why != "" else Pal.LINE)
	p.add_theme_stylebox_override("panel", UI.style(bg, border, 2 if sel else 1, Ds.R_S, 12, 8))


# ---------------------------------------------------------------- selection / line editor

func select_line(i: int) -> void:
	_flush_text()
	var old: int = selected
	selected = i if (i >= 0 and i < line_count()) else -1
	if old == selected:
		return
	_remove_editor()
	_fill_row(old)
	if selected >= 0:
		_fill_row(selected)
		_show_editor(selected)
	_refresh_chrome()


func _remove_editor() -> void:
	if _editor != null and is_instance_valid(_editor):
		if _editor.get_parent() != null:
			_editor.get_parent().remove_child(_editor)
		_editor.queue_free()
	_editor = null
	_text_edit = null
	_start_val = null
	_end_val = null


func _show_editor(i: int) -> void:
	_remove_editor()
	if not _rows.has(i):
		return
	_editor = _build_editor(i)
	var row: PanelContainer = _rows[i][0]
	_list_box.add_child(_editor)
	_list_box.move_child(_editor, row.get_index() + 1)
	_sync_editor()


func _build_editor(i: int) -> Control:
	var card := UI.card("Card", 10)
	card.name = "LineEditor"
	card.body.add_child(UI.label("%d번째 줄" % (i + 1), "Eyebrow", false))
	_text_edit = LineEdit.new()
	_text_edit.name = "TextInput"
	_text_edit.max_length = MAX_TEXT
	_text_edit.editable = not read_only
	_text_edit.custom_minimum_size.y = Ds.field_h()
	_text_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_text_edit.text_submitted.connect(func(_t: String) -> void: _flush_text())
	_text_edit.focus_exited.connect(_flush_text)
	card.body.add_child(UI.field("가사 (고치면 읽기·해석은 '갱신 필요'가 돼요)", _text_edit))
	var ear := SpeakDrill.touch_button("▶ 이 줄 듣기", "soft", Pal.PRIMARY)
	ear.name = "BtnPreview"
	ear.pressed.connect(func() -> void:
		_flush_text()
		preview_line(i))
	var play_row := UI.flow(8, 8)
	play_row.add_child(ear)
	card.body.add_child(play_row)
	if read_only:
		return card
	card.body.add_child(UI.label(MSG_TIME_HINT, "Small"))
	_start_val = UI.label("", "Strong", false)
	_start_val.name = "StartValue"
	card.body.add_child(_time_block("시작", _start_val, "Start", i))
	_end_val = UI.label("", "Strong", false)
	_end_val.name = "EndValue"
	card.body.add_child(_time_block("끝", _end_val, "End", i))
	var ops := UI.flow(8, 8)
	var specs: Array = [
		["BtnMergePrev", "앞 줄과 합치기", "soft", "merge_prev", i <= 0],
		["BtnMergeNext", "다음 줄과 합치기", "soft", "merge_next", i >= line_count() - 1],
		["BtnSplit", "나누기", "soft", "split", false],
		["BtnDelete", "삭제", "danger", "delete", line_count() <= 1],
	]
	for s in specs:
		var b: Button = SpeakDrill.touch_button(s[1], s[2], Pal.BAD if s[2] == "danger" else Pal.INK)
		b.name = s[0]
		b.disabled = s[4]
		var op: String = s[3]
		b.pressed.connect(func() -> void:
			_flush_text()
			_do_op(op, i)
			_note())
		ops.add_child(b)
	card.body.add_child(ops)
	card.body.add_child(UI.label("나누기는 글자 칸의 커서 자리에서 나눠요. 커서가 없으면 가운데 가까운 띄어쓰기에서 나눠요.", "Small"))
	return card


func _time_block(caption: String, value: Label, key: String, i: int) -> Control:
	var box := UI.vbox(4)
	var head := UI.hbox(8)
	head.add_child(UI.label(caption, "Muted", false))
	head.add_child(value)
	box.add_child(head)
	var flow := UI.flow(8, 8)
	for spec in [["−0.1초", -NUDGE, "Minus"], ["+0.1초", NUDGE, "Plus"]]:
		var d: float = spec[1]
		var b: Button = SpeakDrill.touch_button(spec[0], "soft", Pal.INK)
		b.name = "Btn" + key + spec[2]
		b.pressed.connect(func() -> void:
			_flush_text()
			if key == "Start":
				nudge_line_start(i, d)
			else:
				nudge_line_end(i, d)
			_note())
		flow.add_child(b)
	var nb: Button = SpeakDrill.touch_button("지금 위치로", "soft", Pal.PRIMARY)
	nb.name = "Btn" + key + "Now"
	nb.pressed.connect(func() -> void:
		_flush_text()
		if key == "Start":
			set_line_start_now(i)
		else:
			set_line_end_now(i)
		_note())
	flow.add_child(nb)
	box.add_child(flow)
	return box


func _do_op(op: String, i: int) -> void:
	match op:
		"merge_prev":
			merge_lines(i - 1)
		"merge_next":
			merge_lines(i)
		"split":
			split_line(i, _text_edit.caret_column if (_text_edit != null and is_instance_valid(_text_edit)) else -1)
		"delete":
			_ask_delete(i)


func _note() -> void:
	if last_note != "":
		Toast.info(last_note)
		last_note = ""


## 편집 카드의 값(글자 · 시작 · 끝)을 현재 곡에 맞춘다. 글자 칸에 입력 중인 글자는 건드리지 않는다.
func _sync_editor() -> void:
	if _editor == null or not is_instance_valid(_editor) or selected < 0 or selected >= line_count():
		return
	var ln: Dictionary = lines()[selected]
	if _text_edit != null and not _text_edit.has_focus() and _text_edit.text != str(ln["text"]):
		_text_edit.text = str(ln["text"])
	if _start_val != null:
		_start_val.text = fmt_time(float(ln["t0"]))
	if _end_val != null:
		_end_val.text = fmt_time(float(ln["t1"]))


## 글자 칸에서 고친 글자를 곡에 반영한다 (비었으면 되돌린다).
func _flush_text() -> void:
	if _text_edit == null or not is_instance_valid(_text_edit) or selected < 0 or selected >= line_count():
		return
	if read_only:
		return
	var typed: String = _text_edit.text
	if typed.strip_edges() == str((lines()[selected] as Dictionary)["text"]):
		return
	if not set_text(selected, typed):
		_text_edit.text = str((lines()[selected] as Dictionary)["text"])
		Toast.info("줄 글자는 비울 수 없어요. 줄을 없애려면 [삭제]를 누르세요.")


## 편집이 끝난 뒤 화면을 새로 그린다. structural: 줄 수나 순서가 바뀜.
func _after_edit(structural: bool, touched: int) -> void:
	save_error = ""
	if structural:
		_rebuild_list()
	else:
		if touched >= 0:
			_fill_row(touched)
		_sync_editor()
	_refresh_chrome()


# ---------------------------------------------------------------- buttons

func _ask_delete(i: int) -> void:
	if i < 0 or i >= line_count():
		return
	var preview: String = str((lines()[i] as Dictionary)["text"])
	var sh: Sheet = Sheet.confirm(self, "이 줄을 지울까요?", preview.left(60), "지우기", true)
	sh.closed.connect(func(r: Variant) -> void:
		if str(r) == "ok":
			delete_line(i))


func _on_revert_pressed() -> void:
	_flush_text()
	if not is_dirty():
		return
	var sh: Sheet = Sheet.confirm(self, "변경을 모두 취소할까요?", "고친 내용이 처음 상태로 돌아가요.", "변경 취소", true, "계속 고치기")
	sh.closed.connect(func(r: Variant) -> void:
		if str(r) == "ok":
			revert())


func _on_save_pressed() -> void:
	if read_only:
		_finish_saved()
		return
	if save():
		_finish_saved()


func _finish_saved() -> void:
	result = "saved"
	saved.emit(song_id)
	if player != null and is_instance_valid(player):
		player.stop()
	closed.emit()
