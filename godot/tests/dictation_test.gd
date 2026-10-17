extends Node
## DictationDiff.diff 표 테스트 (순수 함수, 서버 필요 없음).
##   godot --headless --path <project> res://tests/dictation_test.tscn
## 종료 코드 0 = 전부 통과. 마지막 줄: "== dictation result: N passed, 0 failed =="

var passed: int = 0
var failed: int = 0


func ok(cond: bool, name: String) -> void:
	if cond:
		passed += 1
		print("  PASS  ", name)
	else:
		failed += 1
		print("  FAIL  ", name)


func _ready() -> void:
	print("== dictation test start ==")
	_run()
	print("== dictation result: %d passed, %d failed ==" % [passed, failed])
	get_tree().quit(1 if failed > 0 else 0)


func _all_ok(d: Dictionary) -> bool:
	for w in d["words"]:
		if not bool((w as Dictionary)["ok"]):
			return false
	return (d["words"] as Array).size() > 0


func _kinds(d: Dictionary) -> Array:
	var out: Array = []
	for w in d["words"]:
		out.append((w as Dictionary)["kind"])
	return out


func _run() -> void:
	print("[exact / normalisation]")
	var d: Dictionary = DictationDiff.diff("I'd like a large coffee, please.", "I'd like a large coffee, please.")
	ok(int(d["score"]) == 100 and _all_ok(d) and (d["extra"] as Array).is_empty() and (d["words"] as Array).size() == 6, "identical sentence -> 100, every word ok, no extra")
	d = DictationDiff.diff("I RUN   every, morning!!", "I run every morning.")
	ok(int(d["score"]) == 100 and _all_ok(d), "case, punctuation and extra spaces are ignored")
	d = DictationDiff.diff("I would like a coffee", "I'd like a coffee.")
	ok(int(d["score"]) == 100 and _all_ok(d), "I would = I'd (said long form, target contraction)")
	d = DictationDiff.diff("I'd like a coffee", "I would like a coffee.")
	ok(int(d["score"]) == 100 and _all_ok(d), "I'd = I would (said contraction, target long form)")
	d = DictationDiff.diff("do not go", "Don't go.")
	ok(int(d["score"]) == 100 and _all_ok(d), "do not = don't")
	d = DictationDiff.diff("I can not swim", "I cannot swim.")
	ok(int(d["score"]) == 100 and _all_ok(d), "can not = cannot")
	d = DictationDiff.diff("I’d like tea", "I'd like tea.")
	ok(int(d["score"]) == 100, "curly apostrophe accepted")

	print("[missing / typo / extra / order]")
	d = DictationDiff.diff("I like a coffee", "I like a large coffee")
	ok(_kinds(d) == ["ok", "ok", "ok", "missing", "ok"] and int(d["score"]) < 100 and int(d["score"]) >= 85, "one word missing -> that word is 'missing' (score %d)" % int(d["score"]))
	d = DictationDiff.diff("I like a large coffe", "I like a large coffee")
	ok(_kinds(d) == ["ok", "ok", "ok", "ok", "typo"] and str((d["words"][4] as Dictionary)["said"]) == "coffe" and (d["extra"] as Array).is_empty(), "spelling mistake -> 'typo' with the typed word, not an extra word")
	d = DictationDiff.diff("I really like coffee", "I like coffee")
	ok(_all_ok(d) and d["extra"] == ["really"] and int(d["score"]) < 100, "added word is listed in extra, target words stay ok")
	d = DictationDiff.diff("coffee like I", "I like coffee")
	ok(int(d["score"]) < 50 and not _all_ok(d), "words in the wrong order score low (%d)" % int(d["score"]))
	d = DictationDiff.diff("a completely different thing", "I like coffee")
	ok(int(d["score"]) == 0 and not _all_ok(d), "nothing in common -> 0")

	print("[contractions: n't irregulars, both directions]")
	var same_pairs := [
		["I cannot swim", "I can't swim."], ["I can't swim.", "I cannot swim"], ["I can not swim", "I can't swim."], ["I can't swim", "I can not swim."],
		["I will not go", "I won't go."], ["I won't go", "I will not go."], ["We shall not go", "We shan't go."], ["We shan't go", "We shall not go."],
		["I am not going", "I ain't going."], ["I ain't going", "I am not going."], ["He is not here", "He ain't here."], ["He ain't here", "He is not here."],
	]
	for pr in same_pairs:
		d = DictationDiff.diff(pr[0], pr[1])
		ok(int(d["score"]) == 100 and _all_ok(d), "'%s' = '%s' (%d)" % [pr[0], pr[1], int(d["score"])])

	print("[apostrophe-less contractions]")
	var noapos := [
		["Im tired", "I'm tired."], ["I'm tired", "Im tired."], ["I dont know", "I don't know."], ["I don't know", "I dont know"],
		["She doesnt like fish", "She doesn't like fish."], ["He didnt come", "He didn't come."], ["I cant swim", "I can't swim."], ["I wont go", "I won't go."],
		["Youre late", "You're late."], ["Theyre here", "They're here."], ["Ive finished", "I've finished."], ["Thats my bag", "That's my bag."],
		["Whats your name", "What's your name?"], ["Hes a doctor", "He's a doctor."], ["Isnt it nice", "Isn't it nice?"],
		["Its raining", "It's raining."], ["Ill call you", "I'll call you."], ["Well see you soon", "We'll see you soon."], ["Were happy to help", "We're happy to help."],
		["Id like tea", "I'd like tea."], ["Lets go home", "Let's go home."],
	]
	for pr in noapos:
		d = DictationDiff.diff(pr[0], pr[1])
		ok(int(d["score"]) == 100 and _all_ok(d), "'%s' = '%s' (%d)" % [pr[0], pr[1], int(d["score"])])
	print("[words that overlap other words: accepted only when the answer is the contraction]")
	d = DictationDiff.diff("It's tail is long", "Its tail is long.")
	ok(int(d["score"]) < 85, "answer 'Its' (possessive) is not 'It's' (%d)" % int(d["score"]))
	d = DictationDiff.diff("I'll people need rest", "Ill people need rest.")
	ok(int(d["score"]) < 85, "answer 'Ill' is not matched by I'll (%d)" % int(d["score"]))
	d = DictationDiff.diff("I will go there", "We'll go there.")
	ok(int(d["score"]) < 85, "'We'll' is not 'I will' (%d)" % int(d["score"]))
	d = DictationDiff.diff("Its tail is long", "Its tail is long.")
	ok(int(d["score"]) == 100, "answer 'Its' typed as 'Its' -> 100")

	print("['s, 'd, OK")
	for pr in [["Everyone is ready", "Everyone's ready."], ["Everyone's ready", "Everyone is ready."], ["Tom is ready", "Tom's ready."], ["Toms car is red", "Tom's car is red."],
			["Tom's car is red", "Tom's car is red."], ["He has gone home", "He's gone home."], ["He's gone home", "He has gone home."], ["It is raining", "It's raining."],
			["I had better go", "I'd better go."], ["I'd better go", "I had better go."], ["I would better go", "I'd better go."], ["I'd like tea", "I would like tea."],
			["OK, I'll come", "Okay, I will come."], ["okay I will come", "OK I'll come"], ["It's O.K.", "It's okay."], ["Okay", "OK!"],
			["She likes colour", "She likes color."], ["I have 3 cats", "I have three cats."],
			["I am 20 years old", "I am twenty years old."], ["I am twenty years old", "I am 20 years old."], ["I am 21 years old", "I am twenty-one years old."],
			["I am twenty one years old", "I am 21 years old."], ["I am twenty-one years old", "I am 21 years old"], ["13 people came", "Thirteen people came."],
			["Thirteen people came", "13 people came."], ["I have 100 books", "I have one hundred books."], ["I have one hundred books", "I have 100 books."],
			["It is on the 3rd floor", "It is on the third floor."], ["It is on the third floor", "It is on the 3rd floor."], ["My birthday is on the 12th", "My birthday is on the twelfth."],
			["We have 45 students", "We have forty-five students."], ["We have forty five students", "We have 45 students."]]:
		d = DictationDiff.diff(pr[0], pr[1])
		ok(int(d["score"]) == 100 and _all_ok(d), "'%s' = '%s' (%d)" % [pr[0], pr[1], int(d["score"])])

	print("[partial credit for one small spelling slip]")
	d = DictationDiff.diff("I lke tea", "I like tea.")
	ok(_kinds(d) == ["ok", "typo", "ok"] and int(d["score"]) >= 85 and int(d["score"]) < 100, "3-word sentence, one slip -> 'typo' but passes (%d)" % int(d["score"]))
	d = DictationDiff.diff("Good mornin", "Good morning")
	ok(_kinds(d) == ["ok", "typo"] and int(d["score"]) >= 85, "2-word sentence, one slip passes (%d)" % int(d["score"]))
	d = DictationDiff.diff("She is my freind from school", "She is my friend from school.")
	ok(_kinds(d) == ["ok", "ok", "ok", "typo", "ok", "ok"] and int(d["score"]) >= 85, "swapped letters count as one slip (%d)" % int(d["score"]))
	d = DictationDiff.diff("I lke tea evry day", "I like tea every day.")
	ok(int(d["score"]) < 85, "two spelling slips do not both get credit (%d)" % int(d["score"]))
	d = DictationDiff.diff("The cat sat on the mat", "The cut sat on the mat")
	ok(int(d["score"]) < 100 and _kinds(d)[1] == "missing", "3-letter word off by one letter is a different word, not a slip")

	print("[one-letter substitutions get no spelling credit]")
	for pr in [["I walk home", "I talk home"], ["I went home", "I want home"], ["Go to bud", "Go to bus"], ["I lend it", "I land it"], ["I want home", "I went home"], ["The cat sat", "The cut sat"]]:
		d = DictationDiff.diff(pr[0], pr[1])
		var kinds: Array = _kinds(d)
		ok(int(d["score"]) < 85 and not kinds.has("typo"), "'%s' vs '%s' is a different word, no credit (%d)" % [pr[0], pr[1], int(d["score"])])
	d = DictationDiff.diff("I walk to the park today", "I talk to the park today")
	ok(int(d["score"]) < 85, "walk/talk in a 6-word sentence still fails (%d)" % int(d["score"]))
	d = DictationDiff.diff("She likes becuase it", "She likes because it")
	ok(_kinds(d)[2] == "typo" and int(d["score"]) >= 85, "transposition in a long word keeps credit (%d)" % int(d["score"]))
	d = DictationDiff.diff("She is defanitely here", "She is definitely here")
	ok(_kinds(d)[2] == "typo" and int(d["score"]) >= 85, "same-first-letter substitution in a 5+ letter word keeps credit (%d)" % int(d["score"]))
	d = DictationDiff.diff("She is tefinitely here", "She is definitely here")
	ok(not _kinds(d).has("typo") or int(d["score"]) < 85, "substitution of the first letter gets no credit (%d)" % int(d["score"]))

	print("[a real word typed for another real word is a listening mistake, no spelling credit]")
	for pr in [["I like the prize", "I like the price"], ["I see a house", "I see a horse"], ["Open your month", "Open your mouth"], ["I thank so", "I think so"],
			["I hard a noise", "I heard a noise"], ["It is quiet good", "It is quite good"], ["I bought apple", "I bought apples"], ["I bought apples", "I bought apple"],
			["He walked home", "He walks home"], ["She likes cat", "She likes cats"], ["I am go home", "I am going home"]]:
		d = DictationDiff.diff(pr[0], pr[1])
		ok(int(d["score"]) < 85 and not _kinds(d).has("typo"), "'%s' vs '%s' fails (%d)" % [pr[0], pr[1], int(d["score"])])
	print("[non-words keep the spelling credit]")
	for pr in [["I like coffe", "I like coffee"], ["I lke tea", "I like tea"], ["My freind is here", "My friend is here"], ["I eat vegtables", "I eat vegetables"],
			["Thier car is red", "Their car is red"], ["It is late becuase it rains", "It is late because it rains"]]:
		d = DictationDiff.diff(pr[0], pr[1])
		ok(int(d["score"]) >= 85 and _kinds(d).has("typo"), "'%s' vs '%s' still passes with 'typo' (%d)" % [pr[0], pr[1], int(d["score"])])
	ok(DictationDiff.is_common_word("price") and DictationDiff.is_common_word("horse") and not DictationDiff.is_common_word("freind") and not DictationDiff.is_common_word("thier"),
		"common word list is loaded (price, horse yes; freind, thier no)")

	print("[real mistakes stay below 85]")
	for pr in [["I tea", "I like tea."], ["I think we go to park today", "I think we should go to the park today."],
			["She goes to school by car every day", "She goes to school by bus every day."], ["He is a good teacher at our school", "She is a good teacher at our school."],
			["I will go now", "I won't go now."], ["I did go", "I didn't go."], ["I have no money", "I have money."], ["We never eat meat here", "We eat meat here."],
			["Please open the window", "Please close the door."], ["I want to buy a new bag", "I want to buy a new shirt."]]:
		d = DictationDiff.diff(pr[0], pr[1])
		ok(int(d["score"]) < 85, "'%s' vs '%s' fails (%d)" % [pr[0], pr[1], int(d["score"])])

	print("[degenerate input]")
	d = DictationDiff.diff("", "I like coffee")
	ok(int(d["score"]) == 0 and (d["words"] as Array).size() == 3 and not _all_ok(d) and (d["extra"] as Array).is_empty(), "empty answer -> 0, no error, all words missing")
	d = DictationDiff.diff("   \t  ", "I like coffee")
	ok(int(d["score"]) == 0, "whitespace-only answer -> 0")
	d = DictationDiff.diff("hello", "Hello!")
	ok(int(d["score"]) == 100 and (d["words"] as Array).size() == 1, "one-word target")
	d = DictationDiff.diff("hello", "")
	ok(int(d["score"]) == 0 and (d["words"] as Array).is_empty(), "empty target -> 0, no error")
	var long_said: String = "I like coffee " + "blah ".repeat(200)
	d = DictationDiff.diff(long_said, "I like coffee")
	ok(_all_ok(d) and (d["extra"] as Array).size() <= 60, "input over 300 characters is cut (%d extra words kept)" % (d["extra"] as Array).size())
	d = DictationDiff.diff("I like 😀 coffee 커피", "I like coffee")
	ok(int(d["score"]) == 100 and _all_ok(d), "emoji and Hangul mixed into the answer are ignored")
	d = DictationDiff.diff("😀😀", "I like coffee")
	ok(int(d["score"]) == 0, "only emoji -> 0")

	print("[helpers]")
	ok(DictationDiff.first_letters("I'd like tea.") == "I__   l___   t__", "first-letter hint: '%s'" % DictationDiff.first_letters("I'd like tea."))
	ok(DictationDiff.word_count("I'd like a large coffee, please.") == 6, "word count counts a contraction once")
