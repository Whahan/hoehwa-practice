class_name SongSingDrill
extends SpeakDrill
## 노래 따라 부르기 채점 (설계 D8): SpeakDrill(녹음 -> /score -> ScorePanel)을 그대로 쓰되,
## 박자가 달라도 점수가 깎이지 않게 /score 응답의 점수를 `SongStudy.song_score` 로 다시 계산한다
## (유창성 제외: round((0.6·정확도 + 0.25·또렷함) / 0.85)). 서버가 준 점수는 `score_raw` 로 남긴다.
## 억양(/prosody)은 요청하지 않는다. 곡 구간 듣기는 SongPlayer 가 하므로 listen() 은 아무것도 하지 않는다.
## 소리가 없거나 응답이 이상하면(무음) 기존 SpeakDrill 그대로 silent_result 를 낸다.
##
## 쓰는 법: var d := SongSingDrill.new(lang); 본문에 add_child(d); 하단 바에 d.make_recorder(); 줄이 바뀔 때 d.set_target(text, reading, ko).
## 녹음을 시작하기 전에 SongPlayer.pause() 는 부르는 화면이 한다 (마이크가 음악을 받지 않게).

const REF_NOTE := "노래 점수는 참고용이에요. 박자나 음을 늘린 건 점수에서 뺐어요."


func _init(l: String = "en") -> void:
	super(l, "song")
	show_prosody = false


## 곡 구간은 SongPlayer 가 재생한다: 가사를 Tts 로 읽지 않는다.
func listen(_slow: bool = false, _text_override: String = "") -> void:
	pass


## /score 응답을 노래 점수로 바꿔 적용한다. 쓸 수 있는 응답이면 true.
func apply_score(data: Variant) -> bool:
	if not SpeakDrill.is_valid_score(data):
		return super.apply_score(data) # 무음 처리(silent_result)는 부모가 한다
	var d: Dictionary = (data as Dictionary).duplicate(true)
	d["score_raw"] = d["score"]
	d["score"] = SongStudy.song_score(d)
	return super.apply_score(d)


func _render() -> void:
	super._render()
	if status == "ok":
		add_child(UI.label(REF_NOTE, "Muted"))
		UI.fix_cjk(self)
