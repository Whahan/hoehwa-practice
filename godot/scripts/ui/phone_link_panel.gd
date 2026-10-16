class_name PhoneLinkPanel
extends VBoxContainer
## PC 설정의 "휴대폰 연결" 카드 (docs/android_remote_design.md §4.8 다). Phase 0 뼈대: W2 가 구현한다.

## main.gd(W3) 가 상단 "폰 연결 켜짐" 표시에 읽는 마지막 상태
static var last_enabled: bool = false
