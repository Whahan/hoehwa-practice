extends Node
## Headless smoke test:
##   godot --headless --path <project> res://tests/smoke.tscn
## Exit code 0 = all checks passed.

var passed: int = 0
var failed: int = 0

const SAMPLE_LESSON := """
{"title": "카페에서 주문하기", "exercises": [
 {"type":"choice","question":"'I'd like a coffee.'의 뜻은?","options":["커피 주세요","커피 싫어요","커피 샀어요","커피 마셔요"],"answer":0,"explain":"I'd like ~ 는 정중한 요청이에요."},
 {"type":"fill","sentence":"___ I have a menu?","reading":"","ko":"메뉴판 좀 주실래요?","options":["Can","Is","Are","Do"],"answer":0,"explain":"Can I ~?"},
 {"type":"build","ko":"저는 매일 아침 일곱 시에 일어나요.","answer":["毎朝","七時に","起きます"],"extra":["寝ます","八時に"],"reading":"まいあさ しちじに おきます","explain":"시간 + に"},
 {"type":"build","ko":"물 한 잔 주세요.","answer":["Can","I","have","some","water"],"extra":["has","much"],"reading":"","explain":"Can I have ~"},
 {"type":"listen","audio":"Nice to meet you.","reading":"","options":["처음 뵙겠습니다","안녕히 가세요","고맙습니다","미안합니다"],"answer":0,"explain":"첫 만남 인사"},
 {"type":"speak","text":"I'd like a large coffee, please.","reading":"","ko":"큰 사이즈 커피 한 잔 주세요."},
 {"type":"bogus","x":1},
 {"type":"choice","question":"broken","options":["a"],"answer":5}
]}
"""

const SAMPLE_SCORE := """
{"transcript":"I would like a large coffee please","score":82,"accuracy":90,"clarity":75,"fluency":80,
 "units":[{"t":"I'd","ok":true,"conf":0.9,"heard":null},{"t":"like","ok":true,"conf":0.8,"heard":null},{"t":"rice","ok":false,"conf":0.3,"heard":"lice"}],
 "tips_ko":["'rice'가 'lice'로 들렸어요. r은 혀끝을 입천장에 대지 않아요."]}
"""


func _ready() -> void:
	print("== smoke test start ==")
	Store.progress_path = "user://test_progress.json"
	await _test_wav()
	_test_plan()
	_test_progress()
	_test_text_sim()
	_test_theme()
	await _test_lesson_ui()
	await _test_views()
	await _test_live_backend()
	print("== smoke result: %d passed, %d failed ==" % [passed, failed])
	DirAccess.remove_absolute(ProjectSettings.globalize_path("user://test_progress.json"))
	get_tree().quit(1 if failed > 0 else 0)


func ok(cond: bool, name: String) -> void:
	if cond:
		passed += 1
		print("  PASS  ", name)
	else:
		failed += 1
		print("  FAIL  ", name)


# ---------------------------------------------------------------- WAV

func _test_wav() -> void:
	print("[wav]")
	var st := WavUtil.silence(1.0, 16000, false)
	var bytes: PackedByteArray = WavUtil.to_wav_bytes(st)
	ok(bytes.size() == 44 + 32000, "1 s mono 16 kHz -> %d bytes (expected 32044)" % bytes.size())
	ok(bytes.slice(0, 4).get_string_from_ascii() == "RIFF", "header starts with RIFF")
	ok(bytes.slice(8, 12).get_string_from_ascii() == "WAVE", "WAVE tag")
	ok(bytes.slice(12, 16).get_string_from_ascii() == "fmt ", "fmt chunk")
	ok(bytes.decode_u16(20) == 1 and bytes.decode_u16(22) == 1, "PCM, 1 channel")
	ok(bytes.decode_u32(24) == 16000 and bytes.decode_u16(34) == 16, "rate 16000, 16 bit")
	ok(bytes.slice(36, 40).get_string_from_ascii() == "data" and bytes.decode_u32(40) == 32000, "data chunk length")
	ok(bytes.decode_u32(4) == bytes.size() - 8, "RIFF size field")
	# stereo 44.1 kHz
	var st2 := WavUtil.silence(0.5, 44100, true)
	var b2: PackedByteArray = WavUtil.to_wav_bytes(st2)
	ok(b2.size() == 44 + 44100 / 2 * 4, "0.5 s stereo 44.1 kHz length")
	# compare against Godot's own writer
	var path := "user://rec_test.wav"
	st.save_to_wav(path)
	var f := FileAccess.open(path, FileAccess.READ)
	var native: PackedByteArray = f.get_buffer(f.get_length())
	f = null
	ok(native.size() == bytes.size(), "same size as AudioStreamWAV.save_to_wav (%d vs %d)" % [native.size(), bytes.size()])
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	# round trip
	var back: AudioStreamWAV = WavUtil.from_wav_bytes(bytes)
	ok(back != null and absf(WavUtil.duration(back) - 1.0) < 0.01 and back.mix_rate == 16000, "from_wav_bytes round trip (load_from_buffer)")
	var back2: AudioStreamWAV = WavUtil.parse_manual(bytes)
	ok(back2 != null and back2.data.size() == 32000 and not back2.stereo, "manual parser round trip")
	var b64: String = Marshalls.raw_to_base64(bytes)
	ok(Marshalls.base64_to_raw(b64).size() == bytes.size(), "base64 round trip")
	ok(ClassDB.class_has_method("AudioStreamWAV", "load_from_buffer"), "AudioStreamWAV.load_from_buffer exists in this build")


# ---------------------------------------------------------------- dates

func _test_plan() -> void:
	print("[plan]")
	var start := "2026-11-01"
	var p1: Dictionary = Plan.position(start, Plan.iso_to_days("2026-10-15"))
	ok(p1["phase"] == "before" and p1["days"] == 17, "2026-10-15 -> before start, D-%s" % str(p1.get("days")))
	var p2: Dictionary = Plan.position(start, Plan.iso_to_days("2026-11-10"))
	ok(p2["phase"] == "on" and p2["n"] == 1 and p2["w"] == 2, "2026-11-10 -> month %s week %s" % [p2["n"], p2["w"]])
	var p3: Dictionary = Plan.position(start, Plan.iso_to_days("2027-02-20"))
	ok(p3["n"] == 4 and p3["w"] == 3, "2027-02-20 -> month %s week %s" % [p3["n"], p3["w"]])
	var p4: Dictionary = Plan.position(start, Plan.iso_to_days("2026-11-01"))
	ok(p4["n"] == 1 and p4["w"] == 1 and p4["day_no"] == 1, "start day -> month 1 week 1 day 1")
	var p5: Dictionary = Plan.position(start, Plan.iso_to_days("2026-11-30"))
	ok(p5["n"] == 1 and p5["w"] == 4, "2026-11-30 -> week capped at 4")
	var p6: Dictionary = Plan.position(start, Plan.iso_to_days("2027-11-01"))
	ok(p6["phase"] == "after", "2027-11-01 -> after (year complete)")
	ok(Plan.total_days(start) == 365, "year length 365")
	ok(Plan.stage_of(1) == 1 and Plan.stage_of(3) == 1 and Plan.stage_of(4) == 2 and Plan.stage_of(12) == 4, "stage_of")
	ok(Plan.weekday(Plan.iso_to_days("2026-10-15")) == 4, "2026-10-15 is a Thursday")
	ok(Plan.days_to_iso(Plan.iso_to_days("2028-02-29")) == "2028-02-29", "leap day round trip")
	ok(Plan.month_label(start, 3) == "2027.01", "month_label")


# ---------------------------------------------------------------- progress

func _test_progress() -> void:
	print("[progress]")
	var path := "user://test_progress_rt.json"
	var d: Dictionary = Progress.blank()
	d["start"] = "2026-12-01"
	d["xp"]["en"] = 30
	d["checks"]["en-1-w0"] = true
	d["days"]["2026-10-15"] = {"en": true}
	d["stats"]["ja"]["lessons"] = 2
	d["review"].append({"id": "a1", "lang": "en", "target": "Nice to meet you.", "reading": "", "ko": "처음 뵙겠습니다", "note": ""})
	ok(Progress.save_file(path, d), "save progress file")
	var back: Dictionary = Progress.load_file(path)
	ok(back["start"] == "2026-12-01" and back["xp"]["en"] == 30 and back["checks"].has("en-1-w0"), "round trip scalar fields")
	ok(back["days"]["2026-10-15"]["en"] == true and back["stats"]["ja"]["lessons"] == 2, "round trip days/stats")
	ok(back["review"].size() == 1 and back["review"][0]["target"] == "Nice to meet you.", "round trip review")
	var bad: Dictionary = Progress.normalize({"start": "garbage", "xp": {"en": "x"}, "review": [{"lang": "xx", "target": "a"}, 5]})
	ok(bad["start"] == Plan.DEFAULT_START and bad["xp"]["en"] == 0 and bad["review"].is_empty(), "normalize() repairs bad data")
	ok(back["review"][0]["state"] == FSRS.State.LEARNING and back["review"][0]["reps"] == 0 and int(back["review"][0]["due"]) > 0, "legacy review item migrated to a new FSRS card (due now)")
	var fsrs_item: Dictionary = Progress.normalize({"review": [{"lang": "ja", "target": "ありがとう", "due": 1900000000, "stability": 5.5, "difficulty": 4.2, "state": 2, "step": 0, "last_review": 1899000000, "reps": 3, "lapses": 1}]})["review"][0]
	ok(fsrs_item["due"] == 1900000000 and fsrs_item["state"] == 2 and is_equal_approx(fsrs_item["stability"], 5.5) and fsrs_item["lapses"] == 1, "normalize() keeps FSRS fields")
	var junk_item: Dictionary = Progress.normalize({"review": [{"lang": "en", "target": "x", "state": 9, "due": "soon", "stability": "?"}]})["review"][0]
	ok(junk_item["state"] == 1 and junk_item["reps"] == 0, "normalize() resets damaged FSRS fields")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	# Store with a throw-away path
	Store.load_progress()
	Store.add_review([{"lang": "en", "target": "Hello there", "ko": "안녕", "reading": "", "note": ""}, {"lang": "en", "target": "Hello there"}])
	ok(Store.review_for("en").size() == 1, "Store.add_review de-duplicates")
	Store.add_xp("ja", 20)
	Store.mark_today("ja")
	Store.save_progress()
	Store.load_progress()
	ok(Store.xp("ja") == 20 and Store.did_day(Plan.today_days(), "ja") and Store.streak("ja") >= 1, "Store save/load + streak")
	ok(Store.curriculum.has("en") and Store.months("en").size() == 12, "curriculum loaded (12 months)")


func _test_text_sim() -> void:
	print("[text_sim]")
	var s: Dictionary = TextSim.similarity("i would like a coffee", "I'd like a coffee.", "", "en")
	ok(int(s["score"]) >= 80, "contraction-normalised similarity = %s" % str(s["score"]))
	var s2: Dictionary = TextSim.similarity("りんごです", "りんごです。", "", "ja")
	ok(int(s2["score"]) == 100, "japanese exact = %s" % str(s2["score"]))
	ok(TextSim.norm_text("毎朝 七時に", "ja") == "毎朝七時に", "japanese tokens ignore spaces")


func _test_theme() -> void:
	print("[theme]")
	var th: Theme = ThemeDB.get_project_theme()
	ok(th != null, "project theme loaded (gui/theme/custom)")
	if th != null:
		ok(th.default_font is SystemFont and th.default_font_size == 16, "default font is SystemFont, size 16")
		var names: PackedStringArray = (th.default_font as SystemFont).font_names
		ok(names.size() == 4 and names[0] == "Malgun Gothic", "font_names = %s" % str(names))
		ok(th.has_stylebox("normal", "Button") and th.has_stylebox("hover", "Button") and th.has_stylebox("pressed", "Button"), "Button has normal/hover/pressed styles")


# ---------------------------------------------------------------- lesson UI

func _test_lesson_ui() -> void:
	print("[lesson ui]")
	var data: Variant = JSON.parse_string(SAMPLE_LESSON)
	var parsed: Array = LessonView._parse_lesson(data)
	ok(parsed.size() == 6, "valid exercises kept, invalid dropped (%d of 8)" % parsed.size())
	var lv := LessonView.new()
	add_child(lv)
	lv.size = Vector2(1100, 760)
	lv.lang = "en"
	lv.title = "t"
	lv.load_exercises(parsed)
	lv._render()
	await get_tree().process_frame
	var seen: Array[String] = []
	var guard := 0
	while lv.status == "run" and guard < 20:
		guard += 1
		var e: Dictionary = lv.cur()
		seen.append(str(e["type"]))
		lv.lang = "ja" if str(e["type"]) == "build" and e["answer"].size() == 3 else "en"
		match str(e["type"]):
			"choice", "fill", "listen":
				lv.picked = int(e["answer"]) if guard % 2 == 1 else (int(e["answer"]) + 1) % (e["options"] as Array).size()
				lv._render()
				lv.checked = false
				lv.check_answer()
			"build":
				lv.built = []
				for tok in e["answer"]:
					for tile in e["tiles"]:
						if tile["t"] == tok and not lv.built.has(tile["i"]):
							lv.built.append(tile["i"])
							break
				lv._render()
				lv.check_answer()
			"speak":
				lv.speak_result = JSON.parse_string(SAMPLE_SCORE)
				lv._render()
				lv.results.append({"ok": true, "ex": e})
				lv.next_exercise()
				await get_tree().process_frame
				continue
		await get_tree().process_frame
		lv.next_exercise()
		await get_tree().process_frame
	ok(seen == ["choice", "fill", "build", "build", "listen", "speak"], "walked all exercise types: %s" % str(seen))
	ok(lv.status == "done", "lesson reached the end screen")
	ok(lv.ok_count >= 3, "correct count = %d, XP +%d" % [lv.ok_count, lv.ok_count * 10])
	var rv: Dictionary = LessonView.review_from_exercise(parsed[1], "en")
	ok(rv["target"] == "Can I have a menu?", "reviewFromEx fill -> '%s'" % rv["target"])
	var panel := ScorePanel.build(JSON.parse_string(SAMPLE_SCORE), "en")
	add_child(panel)
	ok(panel.get_child_count() >= 4, "ScorePanel built (%d children)" % panel.get_child_count())
	panel.queue_free()
	lv.queue_free()
	await get_tree().process_frame


# ---------------------------------------------------------------- all views

func _test_views() -> void:
	print("[views]")
	var holder := Control.new()
	holder.size = Vector2(1024, 700)
	add_child(holder)
	for cls in [TodayView, LessonView, TalkView, ReviewView, RoadmapView, ReadingView]:
		var v: AppView = cls.new()
		holder.add_child(v)
		v.size = Vector2(1024, 700)
		v.refresh()
		await get_tree().process_frame
		await get_tree().process_frame
		ok(is_instance_valid(v) and v.get_child_count() > 0, "%s builds without errors" % v.get_script().get_global_name())
	# talk view: simulate a chat reply + feedback rendering
	var tv: TalkView = holder.get_child(2)
	tv.sc = TalkView.GENERIC[0]
	tv.lang = "ja"
	tv.stage = 2
	tv.status = "talk"
	tv._update_visibility()
	tv._update_header()
	tv._apply_reply({"reply": "こんにちは！今日は何をしましたか？", "reading": "こんにちは！きょうはなにをしましたか？", "ko": "안녕하세요! 오늘은 뭐 했어요?", "fix": "", "fix_ko": "", "suggest": ["仕事をしました。", "勉強しました。"]})
	tv.msgs.append({"role": "me", "text": "私は勉強をしました", "fix": "勉強しました。", "fix_ko": "'私は'는 생략해도 자연스러워요."})
	tv._render_msgs()
	tv._update_composer()
	await get_tree().process_frame
	ok(tv._msg_scroll.content.get_child_count() == 2, "chat bubbles rendered (AI + me with fix box)")
	tv.status = "fb"
	tv.fb = {"scores": {"fluency": 3, "accuracy": 4, "vocabulary": 2}, "summary": "잘했어요.", "corrections": [{"you": "私は勉強をしました", "better": "勉強しました。", "reading": "べんきょうしました。", "ko": "공부했어요.", "why": "주어 생략"}], "phrases": [{"phrase": "お疲れ様です", "reading": "おつかれさまです", "ko": "수고하세요"}]}
	tv._update_visibility()
	tv._render_fb()
	await get_tree().process_frame
	ok(tv._fb_page.content.get_child_count() >= 3, "feedback screen rendered")
	holder.queue_free()
	await get_tree().process_frame


# ---------------------------------------------------------------- live backend (optional)

func _test_live_backend() -> void:
	print("[live backend]")
	var h = Api.get_json("/health", 3.0, false)
	var res: Dictionary = await h.wait()
	if not res["ok"]:
		print("  SKIP  backend not reachable at %s (%s)" % [Api.base_url, res["error"]])
		return
	print("  health: ", res["data"])
	ok(res["data"] is Dictionary and (res["data"] as Dictionary).get("ok", false), "GET /health ok=true")
	var cur = Api.get_json("/curriculum", 30.0, false)
	var cr: Dictionary = await cur.wait()
	ok(cr["ok"] and cr["data"] is Dictionary and (cr["data"] as Dictionary).has("en") and (cr["data"] as Dictionary).has("ja"), "GET /curriculum")
	for l in ["en", "ja"]:
		var text := "Nice to meet you." if l == "en" else "はじめまして。"
		var t = Api.post_json("/tts", {"text": text, "lang": l, "speed": 1.0}, 60.0, false)
		var tr: Dictionary = await t.wait()
		if not tr["ok"]:
			print("  FAIL  POST /tts %s: %s" % [l, tr["error"]])
			failed += 1
			continue
		var stream: AudioStreamWAV = WavUtil.from_wav_bytes(tr["bytes"])
		ok(stream != null and WavUtil.duration(stream) > 0.3, "POST /tts %s -> %d bytes, %.2f s, %d Hz" % [l, (tr["bytes"] as PackedByteArray).size(), WavUtil.duration(stream), stream.mix_rate if stream else 0])
		if stream != null:
			var pl := AudioStreamPlayer.new()
			pl.stream = stream
			add_child(pl)
			pl.play()
			await get_tree().create_timer(minf(WavUtil.duration(stream), 2.5) + 0.2).timeout
			pl.queue_free()
	# STT / score on one second of silence: only the response *shape* is checked.
	var silent_b64: String = Marshalls.raw_to_base64(WavUtil.to_wav_bytes(WavUtil.silence(1.0, 16000)))
	var sc = Api.post_json("/stt", {"lang": "en", "audio_b64": silent_b64}, 60.0, false)
	var scr: Dictionary = await sc.wait()
	ok(scr["ok"] and scr["data"] is Dictionary and (scr["data"] as Dictionary).has("text"), "POST /stt shape %s" % str(scr["data"]).left(80))
	var sk = Api.post_json("/score", {"lang": "en", "target": "Nice to meet you.", "reading": "", "audio_b64": silent_b64}, 60.0, false)
	var skr: Dictionary = await sk.wait()
	ok(skr["ok"] and skr["data"] is Dictionary and (skr["data"] as Dictionary).has("score") and (skr["data"] as Dictionary).has("units"), "POST /score shape %s" % str(skr["data"]).left(100))
	if skr["ok"] and skr["data"] is Dictionary:
		var panel := ScorePanel.build(skr["data"], "en")
		add_child(panel)
		ok(panel.get_child_count() >= 3, "ScorePanel renders the real /score response")
		panel.queue_free()
