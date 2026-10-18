extends Node
## Headless test: KanaHangul.to_hangul (scripts/core/kana_hangul.gd), the kana -> Hangul sound spelling.
##   godot --headless --path <project> res://tests/kana_hangul_test.tscn
## Exit code 0 = all checks passed. Pure function: no backend, no user files.
## Every expected value below is written out by hand from the rules in kana_hangul.gd (the rule is the comment):
##   plain  = BASE table, no word-initial voicing (か카 が가)   N = ん -> final ㄴ ("응" alone)
##   TSU    = っ -> final of the previous syllable: ㄱ before か行, ㅂ before ぱ行, ㅅ otherwise, dropped at the end
##   LONG   = ー or a repeated vowel (ああ いい うう ええ おお, えい, おう) -> "-"
##   YOON   = consonant + ゃゅょ / small ぁぃぅぇぉ (COMBO table)
##   PART   = topic は -> 와, direction へ -> 에, を -> 오 (heuristic: no word boundaries in the reading)

const CASES := [
	# --- greetings -------------------------------------------------------------------------------------
	["こんにちは", "콘니치와", "こ=코 (no voicing), N + trailing particle は"],
	["こんばんは", "콘반와", "こ=코; N is always ㄴ, even before ば"],
	["おはよう", "오하요-", "は inside a word stays 하; よう LONG"],
	["おはようございます", "오하요-고자이마스", "LONG; ざ voiced, ご plain, い after ざ(a) not long"],
	["ありがとう", "아리가토-", "LONG とう; ど/が voiced"],
	["ありがとうございます", "아리가토-고자이마스", "LONG + plain"],
	["すみません", "스미마센", "N after せ; す=스"],
	["さようなら", "사요-나라", "LONG よう"],
	["おやすみなさい", "오야스미나사이", "plain; さい is a-i, not long"],
	["はじめまして", "하지메마시테", "word-initial は = 하, じ=지"],
	["よろしくおねがいします", "요로시쿠오네가이시마스", "plain"],
	["いただきます", "이타다키마스", "plain, た타 だ다"],
	["ごちそうさま", "고치소-사마", "LONG そう"],
	["ください", "쿠다사이", "plain"],
	["おげんきですか", "오겐키데스카", "N after げ"],
	["はい", "하이", "あ-vowel then い is not long"],
	["いいえ", "이-에", "LONG いい, then え is a new vowel"],
	# --- numbers ---------------------------------------------------------------------------------------
	["いち", "이치", "plain"],
	["に", "니", "plain"],
	["さん", "산", "N"],
	["よん", "욘", "N"],
	["ろく", "로쿠", "plain"],
	["なな", "나나", "plain"],
	["はち", "하치", "は=하"],
	["きゅう", "큐-", "YOON きゅ + LONG う"],
	["じゅう", "쥬-", "YOON じゅ=쥬 (kana practice table) + LONG"],
	["ひゃく", "햐쿠", "YOON ひゃ=햐"],
	["せん", "센", "N"],
	["まん", "만", "N"],
	["にじゅうさんじ", "니쥬-산지", "YOON + LONG + N"],
	# --- weekdays --------------------------------------------------------------------------------------
	["げつようび", "게츠요-비", "つ=츠, LONG ようび"],
	["かようび", "카요-비", "LONG"],
	["すいようび", "스이요-비", "す(u)+い is not long"],
	["もくようび", "모쿠요-비", "LONG"],
	["きんようび", "킨요-비", "N after き"],
	["どようび", "도요-비", "LONG"],
	["にちようび", "니치요-비", "LONG"],
	# --- っ --------------------------------------------------------------------------------------------
	["がっこう", "각코-", "TSU before こ(か行) = ㄱ; LONG こう"],
	["きっぷ", "킵푸", "TSU before ぷ(ぱ行) = ㅂ"],
	["ちょっと", "춋토", "YOON ちょ=쵸 (same as the kana practice table) + TSU before と = ㅅ"],
	["ざっし", "잣시", "TSU before し = ㅅ"],
	["いっぱい", "입파이", "TSU before ぱ = ㅂ"],
	["きって", "킷테", "TSU before て = ㅅ"],
	["にっぽん", "닙폰", "TSU ㅂ + N"],
	["まって", "맛테", "TSU ㅅ"],
	["ずっと", "즛토", "TSU ㅅ"],
	["あっ", "아", "TSU at the end is dropped"],
	["っあ", "아", "TSU with nothing before it is dropped"],
	["あっー", "아-", "TSU before a non-kana is dropped"],
	# --- ん, long vowels -------------------------------------------------------------------------------
	["ほん", "혼", "N"],
	["にほんご", "니혼고", "N, ご plain"],
	["ん", "응", "N with no previous syllable = 응"],
	["んん", "응응", "second ん cannot attach to 응 either"],
	["せんせい", "센세-", "N; LONG えい"],
	["おかあさん", "오카-산", "LONG ああ; N"],
	["おとうさん", "오토-산", "LONG おう"],
	["おにいさん", "오니-산", "LONG いい"],
	["おねえさん", "오네-산", "LONG ええ"],
	["おおきい", "오-키-", "LONG おお, LONG いい"],
	["ええ", "에-", "LONG ええ"],
	["ああ", "아-", "LONG ああ"],
	["こうえん", "코-엔", "LONG こう, then え is new, N"],
	["すうじ", "스-지", "LONG うう"],
	["ちいさい", "치-사이", "LONG いい; さい not long"],
	["きれい", "키레-", "LONG えい"],
	["とうきょう", "토-쿄-", "LONG + YOON + LONG"],
	["おうさま", "오-사마", "LONG おう"],
	["かぁ", "카-", "small ぁ after a-vowel = LONG"],
	# --- yoon ------------------------------------------------------------------------------------------
	["きゃく", "캬쿠", "YOON きゃ"],
	["しゃしん", "샤신", "YOON しゃ + N"],
	["おちゃ", "오챠", "YOON ちゃ=챠 (kana practice table), distinct from ざ행 자"],
	["じゃあ", "쟈-", "YOON じゃ=쟈 (kana practice table) + LONG あ"],
	["にゃんにゃん", "냔냔", "YOON にゃ + N"],
	["みゃく", "먀쿠", "YOON みゃ"],
	["りょこう", "료코-", "YOON りょ + LONG"],
	["びょういん", "뵤-인", "YOON びょ + LONG う, い new, N"],
	["ぎゅうにゅう", "규-뉴-", "YOON ぎゅ, にゅ + LONG"],
	["しょうがっこう", "쇼-각코-", "YOON + LONG + TSU ㄱ"],
	["ぴょこ", "표코", "YOON ぴょ=표"],
	["じゅうしょ", "쥬-쇼", "YOON じゅ=쥬, しょ=쇼"],
	["ちゅうごく", "츄-고쿠", "YOON ちゅ=츄"],
	["ざっし", "잣시", "ざ stays 자 (not 쟈)"],
	["きゃゃ", "캬야", "an extra small ゃ is read as や"],
	# --- particles ---------------------------------------------------------------------------------------
	["わたしはがくせいです", "와타시와가쿠세-데스", "PART は after わたし; LONG せい"],
	["これはペンです", "코레와펜데스", "PART は after これ; katakana ペ페 ン→ㄴ"],
	["えきはどこですか", "에키와도코데스카", "PART は before どこ"],
	["まいあさはしります", "마이아사하시리마스", "は here starts the word はしります: stays 하"],
	["みずをください", "미즈오쿠다사이", "を = 오"],
	["がっこうへいきます", "각코-에이키마스", "PART へ = 에, and the next い is a new word (not LONG)"],
	["にほんへいく", "니혼에이쿠", "PART へ after ん"],
	["へや", "헤야", "へ at a word start stays 헤"],
	["おへそ", "오헤소", "へ in a word (exception list) stays 헤"],
	["ははは", "하하하", "は after は is never a particle"],
	["はな", "하나", "は at a word start = 하"],
	["ではありません", "데와아리마센", "PART は after で"],
	["トイレはどこですか", "토이레와도코데스카", "PART は before どこ; katakana"],
	["ほんをよむ", "혼오요무", "を after N"],
	["ほんはおもしろいです", "혼와오모시로이데스", "PART は after ん"],
	["わたしは___です", "와타시와___데스", "___ blank kept; は before it is the particle"],
	["ハハ", "하하", "katakana ハ is never a particle"],
	["わたしのへやはひろいです", "와타시노헤야와히로이데스", "へ right after の starts a word (へや)"],
	["このへやはかぜとおしがよい", "코노헤야와카제토-시가요이", "へ after の; PART は"],
	["そのへんじはおそいです", "소노헨지와오소이데스", "へ before ん is a word start (へんじ)"],
	["ていねいにはなします", "테-네-니하나시마스", "ていねい: えい is LONG (not ている)"],
	["まっています", "맛테이마스", "ています: て + い is not LONG"],
	["かれはバスでつうがくしています", "카레와바스데츠-가쿠시테이마스", "ています not LONG"],
	["おもうよ", "오모우요", "思う: う after も is not LONG"],
	["こういうことです", "코-유-코토데스", "いう read ゆう after う"],
	["いうことをきいて", "유-코토오키이테", "いう at the start; きいて has no LONG"],
	["にほんごはおもしろいです", "니혼고와오모시로이데스", "PART は after ご (ごは + non-ん)"],
	["ごはんをたべます", "고한오타베마스", "ごはん: は stays 하"],
	["かのじょのおはなしです", "카노죠노오하나시데스", "おは: honorific お + は stays 하"],
	["いいえ、ちがいます", "이-에、치가이마스", "いいえ: LONG first vowel"],
	["たのしいです", "타노시-데스", "-しい adjective before です: LONG"],
	["あるいはなにか", "아루이와나니카", "(known limit: reading only) は before なに = PART"],
	["がっこうにはいります", "각코-니하이리마스", "にはいる = に + はいる: は stays 하"],
	["えきではたらいています", "에키데하타라이테이마스", "ではたらく: は starts はたらく"],
	["ではありません", "데와아리마센", "PART は after で"],
	["くるはずです", "쿠루하즈데스", "はず: は stays 하"],
	["このはこにいれる", "코노하코니이레루", "このはこ: は stays 하"],
	# --- katakana / loanwords ---------------------------------------------------------------------------
	["テレビ", "테레비", "katakana = hiragana rules"],
	["パソコン", "파소콘", "ぱ=파 N"],
	["アイスクリーム", "아이스쿠리-무", "LONG ー"],
	["ファイル", "파이루", "YOON ふぁ=파"],
	["パーティー", "파-티-", "LONG ー, ティ=티"],
	["ディスコ", "디스코", "ディ=디"],
	["ウィキペディア", "위키페디아", "ウィ=위, ディ=디"],
	["ウェブ", "웨부", "ウェ=웨"],
	["ヴァイオリン", "바이오린", "ヴァ=바, N"],
	["フォーク", "포-쿠", "フォ=포 + LONG"],
	["チェック", "첵쿠", "チェ=체, TSU before ク = ㄱ"],
	["シェフ", "셰후", "シェ=셰"],
	["ジェット", "젯토", "ジェ=제, TSU ㅅ"],
	["クイズ", "쿠이즈", "く(u)+い is not long"],
	["ツアー", "츠아-", "LONG ー"],
	["ミュージック", "뮤-직쿠", "ミュ=뮤, LONG, TSU ㄱ"],
	["コーヒー", "코-히-", "LONG ー twice"],
	["ラーメン", "라-멘", "LONG + N"],
	["スーパー", "스-파-", "LONG"],
	["ケーキ", "케-키", "LONG"],
	["ビール", "비-루", "LONG"],
	["コーン", "콘-", "N attaches to the syllable before the long mark"],
	["ヴ", "부", "ヴ=부"],
	["カァ", "카-", "small ァ after a-vowel = LONG"],
	# --- punctuation, digits, Latin, mixed ---------------------------------------------------------------
	["こんにちは、げんきですか。", "콘니치와、겐키데스카。", "は before 、 is the particle; punctuation kept"],
	["ありがとう!", "아리가토-!", "ASCII ! kept"],
	["「ありがとう」", "「아리가토-」", "brackets kept"],
	["123", "123", "digits kept"],
	["ABC", "ABC", "Latin kept"],
	["あ い", "아 이", "space kept"],
	["3じ", "3지", "digit + kana"],
	["", "", "empty string"],
	["今日", "今日", "kanji pass through"],
	["漢字ひらがな", "漢字히라가나", "kanji pass through, kana converted"],
	["😀あ", "😀아", "emoji pass through"],
	["ー", "-", "a lone long mark"],
	["っ", "", "a lone small tsu is dropped"],
	["ぁ", "아", "a lone small vowel"],
]

## [pron, expected, source]: the backend's katakana pronunciation form (backend/server.py ja_pron, OpenJTalk `pron`; real output
## for the sentence in the comment). from_pron adds no guessing: particles are already ワ / エ / オ, long vowels already ー.
const PRON_CASES := [
	["コンニチワ", "콘니치와", "こんにちは"],
	["ワタシワガクセーデス。", "와타시와가쿠세-데스。", "私は学生です。"],
	["コノヘヤワヒロイデス。", "코노헤야와히로이데스。", "この部屋は広いです。"],
	["ガッコーエイキマス。", "각코-에이키마스。", "学校へ行きます。"],
	["マッテイマス。", "맛테이마스。", "待っています。 (ています: e + i is NOT long)"],
	["ユーコトヲキイテクダサイ。", "유-코토오키이테쿠다사이。", "言うことを聞いてください。 (the backend writes 言う as ユー)"],
	["ハナワキレーデス。", "하나와키레-데스。", "花は綺麗です。 (word-start は stays 하)"],
	["ハシワナガイデス。", "하시와나가이데스。", "橋は長いです。"],
	["ハジメワムズカシイデス。", "하지메와무즈카시-데스。", "初めは難しいです。 (-シイ adjective: long)"],
	["ハハワハタライテイマス。", "하하와하타라이테이마스。", "母は働いています。"],
	["ワタシノヘヤワヒロイデス。", "와타시노헤야와히로이데스。", "私の部屋は広いです。 (へ in a word stays 헤)"],
	["オテアライワアチラデス。", "오테아라이와아치라데스。", "お手洗いはあちらです。"],
	["ソノハナワアカイデス。", "소노하나와아카이데스。", "その花は赤いです。"],
	["ニホンゴワオモシロイデス。", "니혼고와오모시로이데스。", "日本語は面白いです。"],
	["オカーサンワウチニイマス。", "오카-산와우치니이마스。", "お母さんはうちにいます。 (ニイマス: no merge)"],
	["オトーサンワカイシャニイキマシタ。", "오토-산와카이샤니이키마시타。", "お父さんは会社に行きました。"],
	["パーティーワタノシカッタデス。", "파-티-와타노시캇타데스。", "パーティーは楽しかったです。"],
	["サムイノワキライデス。", "사무이노와키라이데스。", "寒いのは嫌いです。"],
	["ヘンジヲマッテイマス。", "헨지오맛테이마스。", "返事を待っています。"],
	["ソノヘンジワオソイデス。", "소노헨지와오소이데스。", "その返事は遅いです。"],
	["オモウ", "오모우", "思う: ウ after モ is not long"],
	["アイウエオ", "아이우에오", "no イウ rewriting in the app: the backend decides"],
	["ワカイウチニ", "와카이우치니", "若いうちに: イウ stays"],
	["シラナイウチニ", "시라나이우치니", "知らないうちに: イウ stays"],
	["イイウエニ", "이이우에니", "いいうえに: イウ stays"],
	["ユーコトヲキイテ", "유-코토오키이테", "言う already arrives as ユー"],
	["テイマス", "테이마스", "no vowel-repeat merging in pron"],
	["オカアサン", "오카아산", "pron has ー where the word is long: カア stays 카아"],
	["オカーサン", "오카-산", "ー once = one hyphen (no double application)"],
	["ガッコー", "각코-", "TSU ㄱ + ー"],
	["ジュー", "쥬-", "じゅ=쥬"],
	["チャ", "챠", "ちゃ=챠"],
	["ザッシ", "잣시", "ざ=자"],
	["コーヒーヲノミマス。", "코-히-오노미마스。", "コーヒーを飲みます。"],
	["ワタシワ___デス。", "와타시와___데스。", "the ___ blank is kept"],
	["", "", "empty"],
	["ABC123", "ABC123", "Latin and digits pass through"],
]

## Readings the backend produced (tests/sample_practice_sentences_ja.json): hiragana, spelling form, 。 kept.
const BACKEND := [
	["まいあさはしります。", "마이아사하시리마스。"],
	["みずをください。", "미즈오쿠다사이。"],
	["えきはどこですか。", "에키와도코데스카。"],
]

var passed: int = 0
var failed: int = 0


func ok(cond: bool, name: String) -> void:
	if cond:
		passed += 1
	else:
		failed += 1
		print("  FAIL  ", name)


func _ready() -> void:
	print("== kana hangul test start ==")
	_test_cases()
	_test_pron()
	_test_backend_samples()
	_test_kana_data()
	_test_corpus()
	_test_reading_line()
	_test_orphans()
	_test_robustness()
	print("== kana hangul result: %d passed, %d failed (%d cases) ==" % [passed, failed, CASES.size()])
	get_tree().quit(1 if failed > 0 else 0)


func _test_cases() -> void:
	print("[expected table]")
	ok(CASES.size() >= 60, "table has at least 60 cases (%d)" % CASES.size())
	for c in CASES:
		var got: String = KanaHangul.to_hangul(str(c[0]))
		ok(got == str(c[1]), "'%s' -> '%s' expected '%s' (%s)" % [c[0], got, c[1], c[2]])


func _test_pron() -> void:
	print("[pron path]")
	for c in PRON_CASES:
		var got: String = KanaHangul.from_pron(str(c[0]))
		ok(got == str(c[1]), "pron '%s' -> '%s' expected '%s' (%s)" % [c[0], got, c[1], c[2]])


## The kana practice table (KanaData) and the sound spelling here must agree: one entry per kana, hiragana and katakana.
func _test_kana_data() -> void:
	print("[KanaData agreement]")
	var n := 0
	for e in KanaData.entries("both"):
		var d: Dictionary = e
		n += 1
		var got: String = KanaHangul.to_hangul(str(d["ch"]))
		ok(got == str(d["ko"]), "KanaData %s = %s, KanaHangul gives %s" % [d["ch"], d["ko"], got])
		var gp: String = KanaHangul.from_pron(KanaData.to_katakana(str(d["ch"])))
		ok(gp == str(d["ko"]), "KanaData %s (pron path) = %s, got %s" % [d["ch"], d["ko"], gp])
	ok(n >= 150, "KanaData has %d entries" % n)
	ok(KanaHangul.to_hangul("ざ") != KanaHangul.to_hangul("じゃ"), "ざ and じゃ stay different")


## tests/kana_hangul_corpus.json: 462 real sentences of the lesson pool as the backend reads them (r = hiragana reading,
## p = pron, h = [index in r, は|へ, is a particle (OpenJTalk's own decision)]). Measures the heuristic fallback.
func _test_corpus() -> void:
	print("[corpus: heuristic fallback]")
	var f := FileAccess.open("res://tests/kana_hangul_corpus.json", FileAccess.READ)
	ok(f != null, "corpus fixture opens")
	if f == null:
		return
	var arr: Variant = JSON.parse_string(f.get_as_text())
	ok(arr is Array and (arr as Array).size() >= 400, "corpus has at least 400 sentences")
	var wrong := {"は": 0, "へ": 0}
	var total := {"は": 0, "へ": 0}
	var diff := 0
	var hira_left := 0
	for o in arr:
		var r: String = o["r"]
		for h in o["h"]:
			var idx: int = int(h[0])
			var ch: String = h[1]
			if idx >= r.length() or r[idx] != ch:
				continue
			var pred: bool = KanaHangul._ha_particle(r, idx) if ch == "は" else KanaHangul._he_particle(r, idx)
			total[ch] += 1
			if pred != bool(h[2]):
				wrong[ch] += 1
		if KanaHangul.to_hangul(r) != KanaHangul.from_pron(str(o["p"])):
			diff += 1
		if _has_kana(KanaHangul.from_pron(str(o["p"]))) or _has_kana(KanaHangul.to_hangul(r)):
			hira_left += 1
	var n_sent: int = (arr as Array).size()
	var ha_pct: float = 100.0 * wrong["は"] / maxf(1.0, total["は"])
	var he_pct: float = 100.0 * wrong["へ"] / maxf(1.0, total["へ"])
	var diff_pct: float = 100.0 * diff / maxf(1.0, n_sent)
	print("  fallback on %d sentences: は wrong %.1f%% (%d/%d), へ wrong %.1f%% (%d/%d), sentences differing from the pron spelling %.1f%%" % [n_sent, ha_pct, wrong["は"], total["は"], he_pct, wrong["へ"], total["へ"], diff_pct])
	ok(total["は"] >= 200, "corpus has は occurrences (%d)" % total["は"])
	ok(ha_pct <= 6.0, "fallback は wrong <= 6%% (%.1f%%; was 33.8%% before the rules were improved)" % ha_pct)
	ok(he_pct <= 12.0, "fallback へ wrong <= 12%% (%.1f%%; was 50%%)" % he_pct)
	ok(diff_pct <= 16.0, "fallback sentences differing from pron <= 16%% (%.1f%%; was 43.6%%)" % diff_pct)
	ok(hira_left == 0, "no kana left in any output (%d sentences)" % hira_left)


func _test_reading_line() -> void:
	print("[ReadingLine]")
	var saved: Dictionary = Store.prefs.duplicate(true)
	Store.prefs["show_hangul_ja"] = true
	ok(ReadingLine.make("こんにちは", "en") == null, "en -> null")
	ok(ReadingLine.make("", "ja") == null, "empty reading -> null")
	var a := ReadingLine.make("こんにちは", "ja", true)
	ok(a != null and a.get_child_count() == 2, "kana + hangul = 2 lines")
	if a != null:
		ok((a.get_child(0) as Label).text == "こんにちは" and (a.get_child(1) as Label).text == "콘니치와", "lines: hiragana then Hangul (heuristic)")
		a.free()
	var b := ReadingLine.make("こんにちは", "ja", true, 0.0, "コンニチワ")
	ok(b != null and (b.get_child(1) as Label).text == "콘니치와", "pron given: Hangul from pron")
	if b != null:
		b.free()
	var c := ReadingLine.make("えきはどこですか", "ja", true, 0.0, "エキワドコデスカ")
	ok(c != null and (c.get_child(1) as Label).text == "에키와도코데스카", "pron beats the reading")
	if c != null:
		c.free()
	var d := ReadingLine.make("こんにちは", "ja", false)
	ok(d != null and d.get_child_count() == 1 and (d.get_child(0) as Label).text == "콘니치와", "show_kana off: only the Hangul line")
	if d != null:
		d.free()
	Store.prefs["show_hangul_ja"] = false
	var e := ReadingLine.make("こんにちは", "ja", true)
	ok(e != null and e.get_child_count() == 1 and (e.get_child(0) as Label).text == "こんにちは", "hangul pref off: only the hiragana line")
	if e != null:
		e.free()
	ok(ReadingLine.make("こんにちは", "ja", false) == null, "both off -> null")
	Store.prefs["show_hangul_ja"] = true
	ok(ReadingLine.make("abc", "ja", false) == null, "text without kana, kana line off -> null")
	var g := ReadingLine.make("こんにちは", "ja", true, 120.0)
	ok(g != null and (g.get_child(0) as Label).custom_minimum_size.x > 0.0 and (g.get_child(0) as Label).custom_minimum_size.x <= 120.0, "max_w sets a capped minimum width")
	if g != null:
		g.free()
	var holder := Control.new()
	var added := ReadingLine.add(holder, "こんにちは", "ja", true, 0.0, "コンニチワ")
	ok(added != null and holder.get_child_count() == 1, "add() attaches the box")
	ok(ReadingLine.add(holder, "", "ja") == null and holder.get_child_count() == 1, "add() attaches nothing for an empty reading")
	holder.free()
	ok(ReadingLine.hangul_of("こんにちは") == "콘니치와" and ReadingLine.hangul_of("こんにちは", "コンニチワ") == "콘니치와", "hangul_of")
	Store.prefs = saved


## ReadingLine used to leave a hidden, unattached box behind for every bubble: 100 calls of every kind add no orphan node.
func _test_orphans() -> void:
	print("[orphan nodes]")
	var saved: Dictionary = Store.prefs.duplicate(true)
	var before: int = int(Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT))
	var holder := Control.new()
	for i in 100:
		Store.prefs["show_hangul_ja"] = (i % 2 == 0)
		var none1 := ReadingLine.make("", "ja")
		var none2 := ReadingLine.make("こんにちは", "en")
		var none3 := ReadingLine.make("こんにちは", "ja", false) if i % 2 == 1 else null
		ok(none1 == null and none2 == null and none3 == null, "null results create nothing (%d)" % i)
		var rl := ReadingLine.make("こんにちは", "ja", true, 200.0, "コンニチワ")
		if rl != null:
			holder.add_child(rl)
	for ch in holder.get_children():
		holder.remove_child(ch)
		ch.free()
	holder.free()
	var after: int = int(Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT))
	ok(after - before == 0, "orphan node count unchanged after 100 ReadingLine calls (%d -> %d)" % [before, after])
	Store.prefs = saved


func _test_backend_samples() -> void:
	print("[backend reading samples]")
	var f := FileAccess.open("res://tests/sample_practice_sentences_ja.json", FileAccess.READ)
	ok(f != null, "sample_practice_sentences_ja.json opens")
	var text: String = f.get_as_text() if f != null else ""
	for b in BACKEND:
		ok(text.contains(str(b[0])), "'%s' is a reading in the backend sample file" % b[0])
		var got: String = KanaHangul.to_hangul(str(b[0]))
		ok(got == str(b[1]), "backend reading '%s' -> '%s' expected '%s'" % [b[0], got, b[1]])
		# a hiragana-only reading never keeps a kana
		ok(not _has_kana(got), "no kana left in the output of '%s'" % b[0])


func _has_kana(s: String) -> bool:
	for i in s.length():
		var cp: int = s.unicode_at(i)
		if (cp >= 0x3041 and cp <= 0x3096) or (cp >= 0x30A1 and cp <= 0x30FA):
			return true
	return false


func _test_robustness() -> void:
	print("[robustness]")
	var weird := ["", " ", "\u0000", "\n\t", "゙", "ゝゞ", "ヽヾ", "ﾊﾝｶｸ", "〜〜〜", "​", "á", "🙂🙂🙂", "ー".repeat(50),
		"っ".repeat(50), "ん".repeat(50), "ゃゅょ", "ぁぃぅぇぉ", "ヴヴヴ", "は".repeat(30), "へ".repeat(30), "今日はいい天気ですね。"]
	for w in weird:
		var got: String = KanaHangul.to_hangul(str(w))
		ok(typeof(got) == TYPE_STRING, "no crash on %s" % JSON.stringify(w))
	# 20000 characters of every shape: well under 0.5 s each
	var big := {
		"sentence": "こんにちは。ありがとうございます、がっこうへいきます。",
		"は": "は", "ん": "ん", "っ": "っ", "ー": "ー", "へ": "へ", "kanji": "漢", "katakana": "チェック", "mixed": "あんっーはへゃ",
	}
	for k in big.keys():
		var unit: String = str(big[k])
		var src: String = unit.repeat(20000 / unit.length() + 1).left(20000)
		var t0 := Time.get_ticks_msec()
		var out: String = KanaHangul.to_hangul(src)
		var dt := Time.get_ticks_msec() - t0
		ok(src.length() == 20000, "20000-char input (%s)" % k)
		ok(dt <= 500, "20000 chars '%s' in %d ms (<= 500)" % [k, dt])
		ok(out.length() > 0 or k == "っ", "20000 chars '%s' gives output" % k)
	# not-kana characters are never altered
	var plain := "Hello, World 123 !?"
	ok(KanaHangul.to_hangul(plain) == plain, "Latin text is unchanged")
	ok(KanaHangul.to_hangul("漢字") == "漢字", "kanji are unchanged")
