class_name KanaTyping
extends RefCounted
## 가나 입력 퀴즈(보기 없는 문제)의 채점. 순수 계산이다(파일·네트워크·저장 기록은 건드리지 않는다).
##
## 인정하는 답 = 글자 표의 로마자(`ro`, 헵번식) + 한글 소리(`ko`) + 훈령식·입력기식 변형(docs/v160_fun_design.md §5.7).
## 비교 전에 `normalize` 를 거친다: 안쪽·바깥쪽 공백 제거, 영문 소문자, 전각 영문·기호 -> 반각.
## 가타카나는 소리가 같은 히라가나(`hira` 칸)와 같은 정답이다. 한글은 완성된 음절만 맞다(조합 중인 자모 한 글자는 틀림).

## 히라가나 글자 -> 로마자 추가 정답(표의 `ro` 말고도 인정하는 것). 가타카나는 `entry["hira"]` 로 같은 줄을 쓴다.
const _EXTRA := {
	"し": ["si"],
	"ち": ["ti"],
	"つ": ["tu"],
	"ふ": ["hu"],
	"じ": ["zi"],
	"ぢ": ["di", "ji", "zi"],
	"づ": ["du", "zu"],
	"を": ["wo", "o"],
	"ん": ["n", "nn", "n'"],
	"しゃ": ["sya"], "しゅ": ["syu"], "しょ": ["syo"],
	"ちゃ": ["tya", "cha"], "ちゅ": ["tyu", "chu"], "ちょ": ["tyo", "cho"],
	"じゃ": ["zya", "jya"], "じゅ": ["zyu", "jyu"], "じょ": ["zyo", "jyo"],
}


## 비교용으로 다듬은 글: 모든 공백(전각 공백 포함) 제거, 전각 영문·숫자·기호(！-～) -> 반각, 소문자. 한글은 그대로.
static func normalize(s: String) -> String:
	var out := ""
	for i in s.length():
		var c: int = s.unicode_at(i)
		if c == 0x20 or (c >= 0x09 and c <= 0x0D) or c == 0xA0 or c == 0x3000:
			continue
		if c >= 0xFF01 and c <= 0xFF5E:
			c -= 0xFEE0
		out += char(c)
	return out.to_lower()


## 이 글자의 정답으로 인정하는 모든 글(이미 normalize 된 것). 글자 사전이 비었거나 `ro`·`ko` 가 없으면 빈 배열.
static func accepted(entry: Dictionary) -> Array[String]:
	var out: Array[String] = []
	var ro: String = normalize(str(entry.get("ro", "")))
	var ko: String = normalize(str(entry.get("ko", "")))
	if ro == "" or ko == "":
		return out
	out.append(ro)
	out.append(ko)
	var extra: Variant = _EXTRA.get(str(entry.get("hira", "")), [])
	for x in (extra as Array):
		var n: String = normalize(str(x))
		if not out.has(n):
			out.append(n)
	return out


## 입력이 정답이면 true. 빈 글·공백만·모르는 글자·엉뚱한 답은 모두 false.
static func check(entry: Dictionary, input: String) -> bool:
	var n: String = normalize(input)
	if n == "":
		return false
	return accepted(entry).has(n)
