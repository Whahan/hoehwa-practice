class_name Pal
extends RefCounted
## Colour tokens shared by the theme and the code-built UI (docs/ui_redesign_design.md §5.1).
##
## Every token is a `static var` so `Pal.use("dark")` can swap the whole set; the names and the LIGHT values of the
## original 16 colours are unchanged, so `Pal.INK` keeps working everywhere. The scheme is applied once at start
## (UiBoot.apply): code that copies a colour while building a screen keeps that colour until the screen is rebuilt.
##
## Rules (§5.1.2): text uses the *_ON tokens and INK / MUTED / PRIMARY; fills, dots, progress bars and borders use
## OK / WARN / BAD / EN / JA; text on a filled button is ON_ACCENT. No Color("#...") literals outside this file.

const LIGHT := {
	"BG": "#F4F5F7", "SURFACE": "#FFFFFF", "SURFACE_HI": "#FFFFFF", "SUNK": "#ECEEF2",
	"INK": "#1A202C", "MUTED": "#5A6373", "LINE": "#DDE1E8", "LINE_STRONG": "#7C8596",
	"EN": "#2C56C9", "EN_SOFT": "#E7ECFA", "JA": "#C4412A", "JA_SOFT": "#F8E8E3",
	"OK": "#23855A", "OK_SOFT": "#E3F3EA", "BAD": "#B83A3A", "BAD_SOFT": "#F9E5E5",
	"WARN": "#9A6A00", "WARN_SOFT": "#FFF3D6",
	"PRIMARY": "#0A6BD6", "PRIMARY_SOFT": "#E8F1FC", "ON_ACCENT": "#FFFFFF",
	"EN_ON": "#2C56C9", "JA_ON": "#A8351F", "OK_ON": "#1B6B49", "WARN_ON": "#7F5700", "BAD_ON": "#B83A3A",
	"TOAST_BG": "#222A38", "TOAST_FG": "#FFFFFF", "TOAST_OK": "#1D6B49", "TOAST_ERR": "#8F2D2D",
}
const DARK := {
	"BG": "#101216", "SURFACE": "#1B1E24", "SURFACE_HI": "#23272F", "SUNK": "#252932",
	"INK": "#E8EAEE", "MUTED": "#A3AAB8", "LINE": "#343944", "LINE_STRONG": "#6F7888",
	"EN": "#8FA8F0", "EN_SOFT": "#1F2842", "JA": "#F08C78", "JA_SOFT": "#3A2420",
	"OK": "#5FCB96", "OK_SOFT": "#1C3328", "BAD": "#F28B8B", "BAD_SOFT": "#3A2224",
	"WARN": "#E3B34A", "WARN_SOFT": "#382E14",
	"PRIMARY": "#7DB4FF", "PRIMARY_SOFT": "#12263F", "ON_ACCENT": "#101216",
	"EN_ON": "#8FA8F0", "JA_ON": "#F08C78", "OK_ON": "#5FCB96", "WARN_ON": "#E3B34A", "BAD_ON": "#F28B8B",
	"TOAST_BG": "#2E333C", "TOAST_FG": "#F2F3F5", "TOAST_OK": "#1D6B49", "TOAST_ERR": "#8F2D2D",
}

# -- original 16 (names and light values unchanged) --
static var BG: Color = Color("#F4F5F7")           ## screen background
static var SURFACE: Color = Color("#FFFFFF")      ## cards, inputs, tab bar
static var SUNK: Color = Color("#ECEEF2")         ## pressed, tip box, progress track, segment background
static var INK: Color = Color("#1A202C")          ## body text
static var MUTED: Color = Color("#5A6373")        ## secondary text
static var LINE: Color = Color("#DDE1E8")         ## decorative divider (no contrast requirement)
static var EN: Color = Color("#2C56C9")
static var EN_SOFT: Color = Color("#E7ECFA")
static var JA: Color = Color("#C4412A")
static var JA_SOFT: Color = Color("#F8E8E3")
static var OK: Color = Color("#23855A")           ## fill / dot / border (text: OK_ON)
static var OK_SOFT: Color = Color("#E3F3EA")
static var BAD: Color = Color("#B83A3A")
static var BAD_SOFT: Color = Color("#F9E5E5")
static var WARN: Color = Color("#9A6A00")         ## fill / dot / border (text: WARN_ON)
static var WARN_SOFT: Color = Color("#FFF3D6")
# -- new tokens (§5.1.2) --
static var SURFACE_HI: Color = Color("#FFFFFF")   ## sheet, dialog, side nav
static var LINE_STRONG: Color = Color("#7C8596")  ## input / chip / switch-track boundary (3:1)
static var PRIMARY: Color = Color("#0A6BD6")      ## language-independent accent (decision B)
static var PRIMARY_SOFT: Color = Color("#E8F1FC") ## selected item background
static var ON_ACCENT: Color = Color("#FFFFFF")    ## text on a filled accent button
static var EN_ON: Color = Color("#2C56C9")
static var JA_ON: Color = Color("#A8351F")
static var OK_ON: Color = Color("#1B6B49")
static var WARN_ON: Color = Color("#7F5700")
static var BAD_ON: Color = Color("#B83A3A")
static var DIM: Color = Color(0, 0, 0, 0.32)      ## scrim behind a sheet / dialog
static var TOAST_BG: Color = Color("#222A38")
static var TOAST_FG: Color = Color("#FFFFFF")
static var TOAST_OK: Color = Color("#1D6B49")     ## toast background for kind "ok"
static var TOAST_ERR: Color = Color("#8F2D2D")    ## toast background for kind "error"

static var _scheme: String = "light"


## "light" | "dark". Anything else becomes "light" and leaves a warning (no exception).
static func use(scheme: String) -> void:
	var t: Dictionary = LIGHT
	if scheme == "dark":
		t = DARK
		_scheme = "dark"
		DIM = Color(0, 0, 0, 0.55)
	else:
		if scheme != "light":
			push_warning("Pal.use: unknown scheme '%s', using light" % scheme)
		_scheme = "light"
		DIM = Color(0, 0, 0, 0.32)
	BG = Color(t["BG"])
	SURFACE = Color(t["SURFACE"])
	SURFACE_HI = Color(t["SURFACE_HI"])
	SUNK = Color(t["SUNK"])
	INK = Color(t["INK"])
	MUTED = Color(t["MUTED"])
	LINE = Color(t["LINE"])
	LINE_STRONG = Color(t["LINE_STRONG"])
	EN = Color(t["EN"])
	EN_SOFT = Color(t["EN_SOFT"])
	JA = Color(t["JA"])
	JA_SOFT = Color(t["JA_SOFT"])
	OK = Color(t["OK"])
	OK_SOFT = Color(t["OK_SOFT"])
	BAD = Color(t["BAD"])
	BAD_SOFT = Color(t["BAD_SOFT"])
	WARN = Color(t["WARN"])
	WARN_SOFT = Color(t["WARN_SOFT"])
	PRIMARY = Color(t["PRIMARY"])
	PRIMARY_SOFT = Color(t["PRIMARY_SOFT"])
	ON_ACCENT = Color(t["ON_ACCENT"])
	EN_ON = Color(t["EN_ON"])
	JA_ON = Color(t["JA_ON"])
	OK_ON = Color(t["OK_ON"])
	WARN_ON = Color(t["WARN_ON"])
	BAD_ON = Color(t["BAD_ON"])
	TOAST_BG = Color(t["TOAST_BG"])
	TOAST_FG = Color(t["TOAST_FG"])
	TOAST_OK = Color(t["TOAST_OK"])
	TOAST_ERR = Color(t["TOAST_ERR"])


static func scheme() -> String:
	return _scheme


static func is_dark() -> bool:
	return _scheme == "dark"


## Preference ("system" | "light" | "dark", anything else counts as "system") -> "light" | "dark".
## "system" asks the OS; a display without dark-mode support gives "light".
static func resolve(pref: String) -> String:
	if pref == "light" or pref == "dark":
		return pref
	if DisplayServer.is_dark_mode_supported() and DisplayServer.is_dark_mode():
		return "dark"
	return "light"


static func accent(lang: String) -> Color:
	return JA if lang == "ja" else EN


static func soft(lang: String) -> Color:
	return JA_SOFT if lang == "ja" else EN_SOFT


## Text colour for use on SOFT surfaces and on BG (JA_ON | EN_ON).
static func on(lang: String) -> Color:
	return JA_ON if lang == "ja" else EN_ON
