class_name Platform
extends RefCounted
## android = 실제 안드로이드 기기. phone = 안드로이드 또는 데스크톱 시험용 `-- --phone`.
## 플랫폼 판정은 이 파일만 한다. 다른 파일은 OS.has_feature("android") 대신 Platform.* 을 쓴다.

static func is_android() -> bool:
	return OS.has_feature("android")

static func is_phone() -> bool:
	return OS.has_feature("android") or OS.get_cmdline_user_args().has("--phone")

static func is_pc() -> bool:
	return not is_phone()
