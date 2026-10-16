class_name RemoteLink
extends RefCounted
## 휴대폰 → PC 연결 정보와 페어링 (docs/android_remote_design.md §4.5). Phase 0 뼈대: W2 가 구현한다.

const PATH := "user://remote.json"          # {"v":1,"base_url","token","device_id","server_name","paired_at"}
const DEFAULT_PORT := 8775
const DISCOVERY_PORT := 8776

## {ok, host, port, base_url, error}. IPv4(+선택 :포트)만. "http://", 끝 "/" 허용
static func parse_address(text: String) -> Dictionary:
	return {"ok": false, "host": "", "port": DEFAULT_PORT, "base_url": "", "error": ""}

## await 가능. [{name, host, port, base_url}], 없으면 []
static func discover(tree: SceneTree, timeout_sec: float = 2.5) -> Array:
	return []

## await. {ok, name, pairing_open, err_code, error}
static func hello(base_url: String) -> Dictionary:
	return {"ok": false, "name": "", "pairing_open": false, "err_code": "", "error": ""}

## await. {ok, token, device_id, server_name, err_code, error, attempts_left}
static func pair(base_url: String, code: String, device_name: String) -> Dictionary:
	return {"ok": false, "token": "", "device_id": "", "server_name": "", "err_code": "", "error": "", "attempts_left": 0}

## await. /lan/proof 를 nonce 로 호출해 HMAC 검증
static func proof_ok(base_url: String, conn: Dictionary) -> bool:
	return false

static func save(conn: Dictionary, path: String = PATH) -> bool:
	return false

## 없음·깨짐 → {}
static func load_saved(path: String = PATH) -> Dictionary:
	return {}

static func clear_token(path: String = PATH) -> void:
	pass
