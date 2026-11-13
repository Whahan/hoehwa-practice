class_name KanaVoice
extends RefCounted
## 가나 소리를 내는 한 곳(docs/v160_fun_design.md D10). 지금은 Tts(폰 시스템 음성 또는 PC 음성)로 보내는 얇은 껍데기다.
## 나중에 번들 소리 묶음(선택 작업 K0)을 이 파일 하나만 바꿔 끼운다. 화면 코드는 이 클래스만 부른다.
##
## 소리를 낼 수 있는지의 판정은 KanaScreen.sound_available() / no_sound_text() 와 같다(시험이 두 글이 같은지 확인한다).
## 이 파일이 접속 상태를 읽는 곳은 `available()` 한 군데뿐이고, 요청을 직접 보내지는 않는다.

const NO_SOUND_TEXT := "소리를 들으려면 PC와 연결해 주세요. 지금은 소리 없이 글자만 익힐 수 있어요."
const NO_VOICE_TEXT := "이 폰에 일본어 음성이 없어요. 폰 설정에서 일본어 음성 데이터를 내려받으면 소리를 들을 수 있어요. 지금은 소리 없이 글자만 익힐 수 있어요."


## 소리를 낼 수 있나. 폰 시스템 음성 엔진이면 일본어 음성이 있는지, PC 엔진이면 PC 연결(주소)이 있는지.
static func available() -> bool:
	if str(Tts.engine_now()) == "system":
		return bool(Tts.system_voices_ok().get("ja", false))
	return Api.base_url != ""


## 글자 하나를 읽어 달라고 부탁한다. 부탁했으면 true, 낼 수 없거나 빈 글이면 false(소리 없이 지나가고 Tts 는 부르지 않는다).
static func speak(ch: String) -> bool:
	if ch.strip_edges() == "":
		return false
	if not available():
		return false
	Tts.speak(ch, "ja", false)
	return true


## 소리를 낼 수 없을 때 보여 줄 한 줄: 폰 음성 엔진이면 "일본어 음성 없음", PC 엔진이면 "PC 연결 필요".
static func no_text() -> String:
	return NO_VOICE_TEXT if str(Tts.engine_now()) == "system" else NO_SOUND_TEXT
