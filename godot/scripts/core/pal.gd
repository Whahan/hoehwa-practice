class_name Pal
extends RefCounted
## Colour palette shared by the theme and the code-built UI.

const BG := Color("#F4F5F7")
const SURFACE := Color("#FFFFFF")
const SUNK := Color("#ECEEF2")
const INK := Color("#1A202C")
const MUTED := Color("#5A6373")
const LINE := Color("#DDE1E8")
const EN := Color("#2C56C9")
const EN_SOFT := Color("#E7ECFA")
const JA := Color("#C4412A")
const JA_SOFT := Color("#F8E8E3")
const OK := Color("#23855A")
const OK_SOFT := Color("#E3F3EA")
const BAD := Color("#B83A3A")
const BAD_SOFT := Color("#F9E5E5")
const WARN := Color("#9A6A00")
const WARN_SOFT := Color("#FFF3D6")


static func accent(lang: String) -> Color:
	return JA if lang == "ja" else EN


static func soft(lang: String) -> Color:
	return JA_SOFT if lang == "ja" else EN_SOFT
