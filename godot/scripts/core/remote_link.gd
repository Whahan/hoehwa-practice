class_name RemoteLink
extends RefCounted
## 휴대폰 → PC 연결 정보와 페어링 (docs/android_remote_design.md §4.5). 연결은 Tailscale(100.x) 전용이고 자동 찾기(UDP)는 없다.
##
## 토큰은 어디에도 출력하지 않는다(로그·print 금지). 파일(user://remote.json)에만 저장한다.

const PATH := "user://remote.json"          # {"v":1,"base_url","token","device_id","server_name","paired_at"}
const DEFAULT_PORT := 8775

const ADDRESS_HELP := "주소를 확인해 주세요. 예: 100.101.102.103 또는 100.101.102.103:8775 (PC의 Tailscale 숫자 주소만 쓸 수 있어요)"
const UNREACHABLE_HELP := "PC에 닿지 않아요. 두 기기 모두 Tailscale이 켜져 있고 같은 계정인지, PC의 휴대폰 연결이 켜져 있는지 확인해 주세요. PC에 Windows 방화벽 허용 창이 떴다면 허용해 주세요."
const OLD_PC_HELP := "이 PC의 회화 연습이 옛 버전이에요. PC 앱을 1.1.0 이상으로 업데이트해 주세요."
const NOT_HOEHWA_HELP := "이 주소에서 회화 연습 PC 앱을 찾지 못했어요. 주소를 다시 확인해 주세요."
const NEED_CODE_HELP := "PC에서 '새 코드 만들기'를 눌러 주세요."


# ---------------------------------------------------------------- json

## JSON.parse_string() prints an engine error for every non-JSON input; a broken remote.json is
## an expected input here, so parse quietly.
static func parse_json(text: String) -> Variant:
	var j := JSON.new()
	if j.parse(text) != OK:
		return null
	return j.data


# ---------------------------------------------------------------- address

## {ok, host, port, base_url, error}. IPv4(+선택 :포트)만(Tailscale 주소 100.x.y.z 가 보통). "http://", 끝 "/" 허용
static func parse_address(text: String) -> Dictionary:
	var bad := {"ok": false, "host": "", "port": DEFAULT_PORT, "base_url": "", "error": ADDRESS_HELP}
	var s: String = text.strip_edges()
	if s.to_lower().begins_with("http://"):
		s = s.substr(7)
	while s.ends_with("/"):
		s = s.substr(0, s.length() - 1)
	if s == "" or s.contains("/") or s.contains(" ") or s.contains("@"):
		return bad
	var parts: PackedStringArray = s.split(":")
	if parts.size() > 2:
		return bad
	var host: String = parts[0]
	var port: int = DEFAULT_PORT
	if parts.size() == 2:
		var p: String = parts[1]
		if p == "" or not p.is_valid_int() or p.length() > 5 or not _all_digits(p):
			return bad
		port = int(p)
		if port < 1 or port > 65535:
			return bad
	var octets: PackedStringArray = host.split(".")
	if octets.size() != 4:
		return bad
	var clean: Array[String] = []
	for o in octets:
		if o == "" or o.length() > 3 or not _all_digits(o):
			return bad
		var v: int = int(o)
		if v > 255:
			return bad
		clean.append(str(v))
	var h: String = ".".join(clean)
	return {"ok": true, "host": h, "port": port, "base_url": "http://%s:%d" % [h, port], "error": ""}


static func _all_digits(s: String) -> bool:
	for i in s.length():
		var c: int = s.unicode_at(i)
		if c < 48 or c > 57:
			return false
	return s.length() > 0


# ---------------------------------------------------------------- calls (no Authorization header)

## await. {ok, name, pairing_open, err_code, error}
static func hello(base_url: String) -> Dictionary:
	var out := {"ok": false, "name": "", "pairing_open": false, "err_code": "", "error": ""}
	var res: Dictionary = await Api.get_json_to(base_url, "/hello", 5.0, false).wait()
	if not res["ok"]:
		if int(res["code"]) == 404:
			out["err_code"] = "old_pc"
			out["error"] = OLD_PC_HELP
		elif int(res["code"]) == 0:
			out["err_code"] = "unreachable"
			out["error"] = UNREACHABLE_HELP
		else:
			out["err_code"] = str(res["err_code"]) if str(res["err_code"]) != "" else "http_%d" % int(res["code"])
			out["error"] = str(res["error"])
		return out
	var d: Variant = res["data"]
	if not (d is Dictionary) or int((d as Dictionary).get("hoehwa", 0)) != 1:
		out["err_code"] = "not_hoehwa"
		out["error"] = NOT_HOEHWA_HELP
		return out
	out["ok"] = true
	out["name"] = str((d as Dictionary).get("name", ""))
	out["pairing_open"] = bool((d as Dictionary).get("pairing_open", false))
	return out


## 공백·하이픈을 지운 6자리 숫자 코드, 아니면 "".
static func normalize_code(code: String) -> String:
	var c: String = code.replace(" ", "").replace("-", "").replace(" ", "").strip_edges()
	if c.length() == 6 and _all_digits(c):
		return c
	return ""


## await. {ok, token, device_id, server_name, err_code, error, attempts_left}
static func pair(base_url: String, code: String, device_name: String) -> Dictionary:
	var out := {"ok": false, "token": "", "device_id": "", "server_name": "", "err_code": "", "error": "", "attempts_left": -1}
	var c: String = normalize_code(code)
	if c == "":
		out["err_code"] = "code_format"
		out["error"] = "연결 코드는 숫자 6자리예요."
		return out
	var name: String = device_name.strip_edges().substr(0, 40)
	if name == "":
		name = "휴대폰"
	var res: Dictionary = await Api.post_json_to(base_url, "/pair", {"code": c, "device_name": name}, 10.0, false).wait()
	if res["ok"] and res["data"] is Dictionary and str((res["data"] as Dictionary).get("token", "")) != "":
		var d: Dictionary = res["data"]
		out["ok"] = true
		out["token"] = str(d["token"])
		out["device_id"] = str(d.get("device_id", ""))
		out["server_name"] = str(d.get("server_name", ""))
		out["attempts_left"] = -1
		return out
	if res["ok"]:
		out["err_code"] = "bad_reply"
		out["error"] = "PC가 보낸 답을 이해하지 못했어요. PC 앱을 최신 버전으로 업데이트해 주세요."
		return out
	var ec: String = str(res["err_code"])
	var body: Variant = res["err_body"]
	var left: int = -1
	if body is Dictionary and (body as Dictionary).has("attempts_left"):
		left = int((body as Dictionary)["attempts_left"])
	out["attempts_left"] = left
	out["err_code"] = ec if ec != "" else ("unreachable" if int(res["code"]) == 0 else "http_%d" % int(res["code"]))
	out["error"] = pair_error_text(out["err_code"], left, str(res["error"]), int(res["code"]))
	return out


static func pair_error_text(err_code: String, attempts_left: int, server_text: String = "", http_code: int = 0) -> String:
	match err_code:
		"code_invalid":
			var t := "코드가 맞지 않아요. 남은 기회 %d번." % maxi(attempts_left, 0)
			if attempts_left == 0:
				t += " PC에서 새 코드를 만들어 주세요."
			return t
		"pair_locked":
			return "코드를 너무 많이 틀려서 잠겼어요. PC에서 새 코드를 만들어 주세요."
		"no_active_code":
			return "코드 시간이 지났거나 이미 썼어요. PC에서 새 코드를 만들어 주세요."
		"device_limit":
			return "연결할 수 있는 휴대폰이 가득 찼어요(최대 8대). PC에서 안 쓰는 기기를 해제해 주세요."
		"code_format":
			return "연결 코드는 숫자 6자리예요."
		"unreachable", "transport":
			return UNREACHABLE_HELP
		_:
			if http_code == 404:
				return OLD_PC_HELP
			if server_text != "":
				return server_text
			return "연결하지 못했어요. 잠시 뒤 다시 시도해 주세요."


## await. /lan/proof 를 nonce 로 호출해 HMAC 검증(PC 가 이 토큰을 아는지). conn 은 {token, device_id} 를 가져야 한다.
## 자동 찾기가 없으므로 앱 흐름에서는 쓰지 않고, 계약 시험이 쓴다.
static func proof_ok(base_url: String, conn: Dictionary) -> bool:
	var tok: String = str(conn.get("token", ""))
	var dev: String = str(conn.get("device_id", ""))
	if tok == "" or dev == "":
		return false
	var nonce: String = Crypto.new().generate_random_bytes(12).hex_encode()
	var res: Dictionary = await Api.post_json_to(base_url, "/lan/proof", {"device_id": dev, "nonce": nonce}, 5.0, false).wait()
	if not res["ok"] or not (res["data"] is Dictionary):
		return false
	var got: String = str((res["data"] as Dictionary).get("proof", "")).to_lower()
	var want: String = expected_proof(tok, nonce)
	return got.length() == want.length() and got == want


static func expected_proof(token: String, nonce: String) -> String:
	var mac: PackedByteArray = Crypto.new().hmac_digest(HashingContext.HASH_SHA256, token.sha256_buffer(), nonce.to_utf8_buffer())
	return mac.hex_encode()


# ---------------------------------------------------------------- file

static func save(conn: Dictionary, path: String = PATH) -> bool:
	var data := {
		"v": 1,
		"base_url": str(conn.get("base_url", "")),
		"token": str(conn.get("token", "")),
		"device_id": str(conn.get("device_id", "")),
		"server_name": str(conn.get("server_name", "")),
		"paired_at": str(conn.get("paired_at", "")) if str(conn.get("paired_at", "")) != "" else Time.get_datetime_string_from_system(false, true),
	}
	var tmp: String = path + ".tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(JSON.stringify(data))
	f.close()
	var g: String = ProjectSettings.globalize_path(path)
	var gt: String = ProjectSettings.globalize_path(tmp)
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(g)
	return DirAccess.rename_absolute(gt, g) == OK


## 없음·깨짐 → {}. 토큰이 지워진 파일은 {base_url, server_name, token:""} 로 돌아온다(연결 화면 미리 채움용).
static func load_saved(path: String = PATH) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var parsed: Variant = parse_json(FileAccess.get_file_as_string(path))
	if not (parsed is Dictionary):
		return {}
	var d: Dictionary = parsed
	if not (d.get("base_url") is String) or not parse_address(str(d["base_url"]))["ok"]:
		return {}
	if d.has("token") and not (d["token"] is String):
		return {}
	return {
		"v": 1,
		"base_url": str(parse_address(str(d["base_url"]))["base_url"]),
		"token": str(d.get("token", "")),
		"device_id": str(d.get("device_id", "")),
		"server_name": str(d.get("server_name", "")),
		"paired_at": str(d.get("paired_at", "")),
	}


## 파일에서 토큰만 지운다(주소·PC 이름은 남김).
static func clear_token(path: String = PATH) -> void:
	var d: Dictionary = load_saved(path)
	if d.is_empty():
		return
	d["token"] = ""
	save(d, path)


## 파일을 완전히 지운다(시험 뒤 정리용).
static func delete_file(path: String = PATH) -> void:
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
