class_name TextSim
extends RefCounted
## Local "dictation vs target" similarity (port of the web app's similarity()),
## used for typed answers in the review screen and for build-tile checking.

const CONTR := {
	"i'm": "i am", "you're": "you are", "we're": "we are", "they're": "they are",
	"it's": "it is", "that's": "that is", "what's": "what is", "there's": "there is",
	"don't": "do not", "doesn't": "does not", "didn't": "did not", "can't": "can not",
	"cannot": "can not", "won't": "will not", "isn't": "is not", "aren't": "are not",
	"i'll": "i will", "you'll": "you will", "i'd": "i would",
}

const JA_SKIP := " \t\n\u3000\u3001\u3002\uff0c\uff0e,.!?\uff01\uff1f\u300c\u300d\u300e\u300f\uff08\uff09()\u2026\u30fb\u301c~\"'\uff1a:\uff1b;"


static func tokens(s: String, lang: String) -> PackedStringArray:
	var t: String = s.to_lower()
	var out := PackedStringArray()
	if lang == "en":
		var rx := RegEx.new()
		rx.compile("[^a-z0-9' ]+")
		t = t.replace("\u2019", "'").replace("\u2018", "'")
		t = rx.sub(t, " ", true)
		for w in t.split(" ", false):
			var rep: String = CONTR.get(w, w)
			for part in rep.split(" ", false):
				out.append(part)
	else:
		for i in t.length():
			var ch := t[i]
			if JA_SKIP.find(ch) == -1:
				out.append(ch)
	return out


static func norm_text(s: String, lang: String) -> String:
	var sep: String = "" if lang == "ja" else " "
	return sep.join(tokens(s, lang))


## Longest-common-subsequence matching. Returns {len: int, hit: Array (bool per element of b)}.
static func lcs_match(a: PackedStringArray, b: PackedStringArray) -> Dictionary:
	var n := a.size()
	var m := b.size()
	var dp: Array = []
	for i in n + 1:
		var row := PackedInt32Array()
		row.resize(m + 1)
		dp.append(row)
	for i in range(n - 1, -1, -1):
		for j in range(m - 1, -1, -1):
			if a[i] == b[j]:
				dp[i][j] = dp[i + 1][j + 1] + 1
			else:
				dp[i][j] = maxi(dp[i + 1][j], dp[i][j + 1])
	var hit: Array = []
	hit.resize(m)
	hit.fill(false)
	var i := 0
	var j := 0
	while i < n and j < m:
		if a[i] == b[j]:
			hit[j] = true
			i += 1
			j += 1
		elif dp[i + 1][j] >= dp[i][j + 1]:
			i += 1
		else:
			j += 1
	return {"len": dp[0][0], "hit": hit}


## {score 0-100, toks: PackedStringArray, hit: Array}
static func similarity(said: String, target: String, reading: String, lang: String) -> Dictionary:
	var s := tokens(said, lang)
	var best: Dictionary = {}
	for cand in [target, reading]:
		var c: String = cand
		if c == "":
			continue
		var tt := tokens(c, lang)
		if tt.is_empty():
			continue
		var r: Dictionary = lcs_match(s, tt)
		var denom: int = maxi(1, s.size() + tt.size())
		var score: int = roundi(2.0 * float(r["len"]) / float(denom) * 100.0)
		if best.is_empty() or score > int(best["score"]):
			best = {"score": score, "toks": tt, "hit": r["hit"]}
	if best.is_empty():
		return {"score": 0, "toks": PackedStringArray(), "hit": []}
	return best
