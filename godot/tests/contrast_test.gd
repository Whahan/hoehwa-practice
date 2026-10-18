extends Node
## Colour contrast, token and theme test (docs/ui_redesign_design.md §5.1.6, W1-1..W1-6):
##   godot --headless --path <project> res://tests/contrast_test.tscn
## Checks the WCAG contrast of the Pal pairs for the light and the dark scheme, that the checker itself can fail,
## that the original 16 light colours are unchanged, Pal.use / Ds.set_font_scale with bad values, the two theme
## files, UiBoot.apply (incl. a missing / broken dark theme), ThemeIcons and GlyphIcon.
## Last line: "== contrast: N passed, M failed ==", exit code 1 on any failure.

## Original palette (§5.1.1 light column). Must stay identical after Pal.use("light").
const LEGACY := {
	"BG": "#F4F5F7", "SURFACE": "#FFFFFF", "SUNK": "#ECEEF2", "INK": "#1A202C", "MUTED": "#5A6373",
	"LINE": "#DDE1E8", "EN": "#2C56C9", "EN_SOFT": "#E7ECFA", "JA": "#C4412A", "JA_SOFT": "#F8E8E3",
	"OK": "#23855A", "OK_SOFT": "#E3F3EA", "BAD": "#B83A3A", "BAD_SOFT": "#F9E5E5",
	"WARN": "#9A6A00", "WARN_SOFT": "#FFF3D6",
}

## Text pairs: contrast >= 4.5 (foreground/background). §5.1.6, plus the toast backgrounds of §5.1.2.
const TEXT_PAIRS := [
	"INK/BG", "INK/SURFACE", "INK/SURFACE_HI", "INK/SUNK", "MUTED/BG", "MUTED/SURFACE", "MUTED/SUNK",
	"MUTED/SURFACE_HI", "MUTED/PRIMARY_SOFT", "PRIMARY/SURFACE", "PRIMARY/BG", "PRIMARY/PRIMARY_SOFT",
	"EN/SURFACE", "EN_ON/EN_SOFT", "JA/SURFACE", "JA_ON/JA_SOFT", "JA_ON/BG", "OK_ON/OK_SOFT", "OK_ON/BG",
	"OK_ON/SURFACE", "WARN_ON/WARN_SOFT", "WARN_ON/BG", "WARN_ON/SURFACE", "BAD_ON/BAD_SOFT", "BAD_ON/SURFACE",
	"BAD_ON/BG", "ON_ACCENT/PRIMARY", "ON_ACCENT/EN", "ON_ACCENT/JA", "ON_ACCENT/OK", "ON_ACCENT/BAD",
	"TOAST_FG/TOAST_BG", "TOAST_FG/TOAST_OK", "TOAST_FG/TOAST_ERR", "LEARN_FG/LEARN_BG",
]
## Non-text pairs (dots, progress bars, borders, switch tracks): contrast >= 3.0.
const NONTEXT_PAIRS := [
	"LINE_STRONG/SURFACE", "LINE_STRONG/BG", "LINE_STRONG/SUNK", "OK/SURFACE", "BAD/SURFACE", "WARN/SURFACE",
	"PRIMARY/SURFACE",
]

var passed: int = 0
var failed: int = 0


func ok(cond: bool, name: String) -> void:
	if cond:
		passed += 1
		print("  PASS  ", name)
	else:
		failed += 1
		print("  FAIL  ", name)


# ---------------------------------------------------------------- WCAG maths

static func _lin(c: float) -> float:
	return c / 12.92 if c <= 0.03928 else pow((c + 0.055) / 1.055, 2.4)


static func luminance(c: Color) -> float:
	return 0.2126 * _lin(c.r) + 0.7152 * _lin(c.g) + 0.0722 * _lin(c.b)


static func ratio(a: Color, b: Color) -> float:
	var la := luminance(a)
	var lb := luminance(b)
	return (maxf(la, lb) + 0.05) / (minf(la, lb) + 0.05)


## true = passes `minimum`. The one place that decides pass / fail, also used by the self check.
static func passes(fg: Color, bg: Color, minimum: float) -> bool:
	return ratio(fg, bg) >= minimum


static func tok(n: String) -> Color:
	match n:
		"BG": return Pal.BG
		"SURFACE": return Pal.SURFACE
		"SURFACE_HI": return Pal.SURFACE_HI
		"SUNK": return Pal.SUNK
		"INK": return Pal.INK
		"MUTED": return Pal.MUTED
		"LINE": return Pal.LINE
		"LINE_STRONG": return Pal.LINE_STRONG
		"EN": return Pal.EN
		"EN_SOFT": return Pal.EN_SOFT
		"JA": return Pal.JA
		"JA_SOFT": return Pal.JA_SOFT
		"OK": return Pal.OK
		"OK_SOFT": return Pal.OK_SOFT
		"BAD": return Pal.BAD
		"BAD_SOFT": return Pal.BAD_SOFT
		"WARN": return Pal.WARN
		"WARN_SOFT": return Pal.WARN_SOFT
		"PRIMARY": return Pal.PRIMARY
		"PRIMARY_SOFT": return Pal.PRIMARY_SOFT
		"ON_ACCENT": return Pal.ON_ACCENT
		"EN_ON": return Pal.EN_ON
		"JA_ON": return Pal.JA_ON
		"OK_ON": return Pal.OK_ON
		"WARN_ON": return Pal.WARN_ON
		"BAD_ON": return Pal.BAD_ON
		"TOAST_BG": return Pal.TOAST_BG
		"TOAST_FG": return Pal.TOAST_FG
		"TOAST_OK": return Pal.TOAST_OK
		"TOAST_ERR": return Pal.TOAST_ERR
		"LEARN_BG": return ReadingView.learn_bg() # 읽기: the "복습 중" word highlight (W9)
		"LEARN_FG": return ReadingView.learn_fg()
	push_error("contrast_test: unknown token " + n)
	return Color(1, 0, 1)


func _ready() -> void:
	print("== contrast test start ==")
	_test_fresh_state()
	_test_pairs()
	_test_selfcheck()
	_test_legacy()
	_test_pal_use()
	_test_ds()
	_test_theme_files()
	await _test_uiboot()
	_test_icons()
	await _test_glyph()
	Pal.use("light")
	Ds.set_font_scale(1.0)
	print("== contrast: %d passed, %d failed ==" % [passed, failed])
	get_tree().quit(1 if failed > 0 else 0)


# ---------------------------------------------------------------- tests

func _test_fresh_state() -> void:
	print("[tokens before any Pal.use(): static var defaults equal the light table]")
	var bad: Array[String] = []
	for k in Pal.LIGHT.keys():
		if tok(String(k)) != Color(Pal.LIGHT[k]):
			bad.append(String(k))
	ok(bad.is_empty(), "initial values = light table (%s)" % ", ".join(bad))
	ok(Pal.scheme() == "light" and not Pal.is_dark(), "starts light")
	ok(Pal.LIGHT.keys() == Pal.DARK.keys(), "light and dark tables have the same tokens")


func _test_pairs() -> void:
	for scheme in ["light", "dark"]:
		print("[%s: text pairs >= 4.5]" % scheme)
		Pal.use(scheme)
		ok(Pal.scheme() == scheme and Pal.is_dark() == (scheme == "dark"), "%s is active" % scheme)
		for p in TEXT_PAIRS:
			var ab: PackedStringArray = String(p).split("/")
			var r := ratio(tok(ab[0]), tok(ab[1]))
			ok(passes(tok(ab[0]), tok(ab[1]), 4.5), "%s %s %.2f >= 4.5" % [scheme, p, r])
		print("[%s: non-text pairs >= 3.0]" % scheme)
		for p in NONTEXT_PAIRS:
			var ab: PackedStringArray = String(p).split("/")
			var r := ratio(tok(ab[0]), tok(ab[1]))
			ok(passes(tok(ab[0]), tok(ab[1]), 3.0), "%s %s %.2f >= 3.0" % [scheme, p, r])
	Pal.use("light")
	Pal.use("dark")
	var dark_dim: float = Pal.DIM.a
	Pal.use("light")
	ok(dark_dim > Pal.DIM.a, "dark scrim is darker than the light one")


func _test_selfcheck() -> void:
	print("[selfcheck: the checker must fail on bad input]")
	var r1 := ratio(Color("#777777"), Color("#FFFFFF"))
	var f1 := not passes(Color("#777777"), Color("#FFFFFF"), 4.5)
	print("selfcheck %s #777777/#FFFFFF %.2f" % ["FAIL-as-expected" if f1 else "UNEXPECTED-PASS", r1])
	ok(f1 and absf(r1 - 4.48) < 0.01, "selfcheck #777777/#FFFFFF is FAIL (4.48)")
	var r2 := ratio(Color("#767676"), Color("#FFFFFF"))
	var p2 := passes(Color("#767676"), Color("#FFFFFF"), 4.5)
	print("selfcheck %s #767676/#FFFFFF %.2f" % ["PASS-as-expected" if p2 else "UNEXPECTED-FAIL", r2])
	ok(p2 and absf(r2 - 4.54) < 0.01, "selfcheck #767676/#FFFFFF is PASS (4.54)")
	var r3 := ratio(Color(LEGACY["JA"]), Color(LEGACY["JA_SOFT"]))
	var f3 := not passes(Color(LEGACY["JA"]), Color(LEGACY["JA_SOFT"]), 4.5)
	print("selfcheck %s legacy JA/JA_SOFT %.2f" % ["FAIL-as-expected" if f3 else "UNEXPECTED-PASS", r3])
	ok(f3 and absf(r3 - 4.27) < 0.01, "selfcheck legacy JA/JA_SOFT is FAIL (4.27)")
	# the new replacement of that pair really passes in the same code path
	Pal.use("light")
	ok(passes(Pal.JA_ON, Pal.JA_SOFT, 4.5), "JA_ON/JA_SOFT passes where legacy JA/JA_SOFT failed")


func _test_legacy() -> void:
	print("[original 16 light colours unchanged (LEGACY table)]")
	Pal.use("light")
	for k in LEGACY.keys():
		ok(tok(String(k)) == Color(LEGACY[k]), "LEGACY %s == %s" % [k, LEGACY[k]])
	# decision B (2026-10-17): PRIMARY is the brighter blue, not the old EN blue. EN itself stays.
	ok(Pal.PRIMARY == Color("#0A6BD6") and Pal.PRIMARY != Pal.EN, "INTENTIONAL CHANGE: PRIMARY is B #0A6BD6 (EN unchanged)")
	ok(Pal.PRIMARY_SOFT == Color("#E8F1FC"), "INTENTIONAL CHANGE: PRIMARY_SOFT is B #E8F1FC")
	Pal.use("dark")
	ok(Pal.PRIMARY == Color("#7DB4FF") and Pal.PRIMARY_SOFT == Color("#12263F"), "dark PRIMARY / PRIMARY_SOFT are the B values")
	ok(Pal.BG != Color(LEGACY["BG"]) and Pal.INK != Color(LEGACY["INK"]), "dark differs from light")
	Pal.use("light")
	ok(Pal.accent("ja") == Pal.JA and Pal.accent("en") == Pal.EN and Pal.soft("ja") == Pal.JA_SOFT and Pal.soft("en") == Pal.EN_SOFT, "accent / soft unchanged")
	ok(Pal.on("ja") == Pal.JA_ON and Pal.on("en") == Pal.EN_ON, "Pal.on picks the *_ON colour")


func _test_pal_use() -> void:
	print("[Pal.use / Pal.resolve with bad input]")
	Pal.use("dark")
	Pal.use("purple")
	ok(Pal.scheme() == "light" and not Pal.is_dark(), "Pal.use('purple') -> light")
	ok(Pal.BG == Color(LEGACY["BG"]) and Pal.INK == Color(LEGACY["INK"]), "light values restored after a bad scheme")
	Pal.use("")
	ok(Pal.scheme() == "light", "Pal.use('') -> light")
	ok(Pal.resolve("dark") == "dark" and Pal.resolve("light") == "light", "resolve passes light / dark through")
	var sys := Pal.resolve("system")
	var weird := Pal.resolve("purple")
	ok(sys == "light" or sys == "dark", "resolve('system') is light or dark")
	ok(weird == sys, "resolve('purple') behaves like 'system'")
	Pal.use("light")


func _test_ds() -> void:
	print("[Ds]")
	Ds.set_font_scale(9.0)
	ok(Ds.font_scale == 1.5, "set_font_scale(9.0) -> 1.5")
	Ds.set_font_scale(0.0)
	ok(Ds.font_scale == 1.0, "set_font_scale(0.0) -> 1.0")
	Ds.set_font_scale(1.5)
	Ds.set_font_scale(NAN)
	ok(Ds.font_scale == 1.0, "set_font_scale(NAN) -> 1.0")
	Ds.set_font_scale(1.5)
	Ds.set_font_scale("big")
	ok(Ds.font_scale == 1.0, "set_font_scale('big') -> 1.0")
	Ds.set_font_scale(1.5)
	Ds.set_font_scale(-2.0)
	ok(Ds.font_scale == 1.0, "set_font_scale(-2.0) -> 1.0")
	Ds.set_font_scale(INF)
	ok(Ds.font_scale == 1.0, "set_font_scale(INF) -> 1.0")
	Ds.set_font_scale(null)
	ok(Ds.font_scale == 1.0, "set_font_scale(null) -> 1.0")
	Ds.set_font_scale(1.2)
	ok(is_equal_approx(Ds.font_scale, 1.15), "set_font_scale(1.2) -> 1.15 (nearest)")
	Ds.set_font_scale(0.9)
	ok(is_equal_approx(Ds.font_scale, 0.9), "set_font_scale(0.9) stays 0.9")
	Ds.set_font_scale(2)
	ok(Ds.font_scale == 1.5, "set_font_scale(int 2) -> 1.5")
	Ds.set_font_scale(1.0)
	ok(Ds.fs(10) == 12, "fs(10) is raised to the 12 minimum")
	ok(Ds.fs(16) == 16, "fs(16) at 100% is 16")
	Ds.set_font_scale(1.5)
	ok(Ds.fs(16) == 24 and Ds.fs(13) == 20, "fs at 150%: 16 -> 24, 13 -> 20")
	Ds.set_font_scale(0.9)
	ok(Ds.fs(12) == 12 and Ds.fs(34) == 31, "fs at 90%: 12 stays 12, 34 -> 31")
	Ds.set_font_scale(1.0)
	ok(Ds.type_size_for("Small", false) == 13 and Ds.type_size_for("Small", true) == 14, "Small 13 PC / 14 phone")
	ok(Ds.type_size_for("H1", false) == 28 and Ds.type_size_for("H1", true) == 30, "H1 28 PC / 30 phone")
	ok(Ds.type_size_for("Eyebrow", false) == 12 and Ds.type_size_for("Eyebrow", true) == 13, "Eyebrow 12 / 13")
	ok(Ds.type_size_for("NoSuchVariation", false) == 16 and Ds.type_size_for("", true) == 17, "unknown variation -> base size 16 / 17")
	ok(Ds.R_CARD == 24 and Ds.R_BTN == 18 and Ds.R_SHEET == 28 and Ds.S6 == 24 and Ds.REC_BIG_PC == Vector2(190, 58) and Ds.REC_SMALL_PC == Vector2(96, 44), "radii / spacing / recorder constants")
	var tm := Ds.touch_min()
	ok(tm == (40.0 if not Platform.is_phone() else 48.0), "touch_min is 40 on PC, 48 on a desktop-phone test (%s)" % tm)
	ok(PhoneLayout.BTN_H == 48.0 and PhoneLayout.LINK_H == 48.0, "PhoneLayout.BTN_H / LINK_H are 48")
	ok(is_equal_approx(PhoneLayout.dp_scale(), 1.0), "dp_scale is 1.0 off Android")


func _test_theme_files() -> void:
	print("[theme files]")
	var light: Resource = load("res://theme/app_theme.tres")
	var dark: Resource = load("res://theme/app_theme_dark.tres")
	ok(light is Theme, "app_theme.tres loads as Theme")
	ok(dark is Theme, "app_theme_dark.tres loads as Theme")
	if not (light is Theme and dark is Theme):
		return
	var lt := light as Theme
	var dt := dark as Theme
	var card := lt.get_stylebox("panel", "Card") as StyleBoxFlat
	ok(card != null and card.corner_radius_top_left == Ds.R_CARD, "Card radius == Ds.R_CARD (%d)" % Ds.R_CARD)
	var dcard := dt.get_stylebox("panel", "Card") as StyleBoxFlat
	ok(dcard != null and dcard.corner_radius_top_left == Ds.R_CARD, "dark Card radius == Ds.R_CARD")
	ok(lt.get_stylebox("normal", "Button").corner_radius_top_left == Ds.R_BTN, "Button radius == Ds.R_BTN")
	ok(lt.get_stylebox("normal", "LineEdit").corner_radius_top_left == Ds.R_INPUT, "LineEdit radius == Ds.R_INPUT")
	if not Platform.is_phone():
		ok(lt.get_font_size("font_size", "Small") == 13, "theme Small == 13 (PC)")
		ok(lt.get_font_size("font_size", "H1") == 28, "theme H1 == 28 (PC)")
		ok(lt.get_font_size("font_size", "Eyebrow") == 12, "theme Eyebrow == 12 (PC)")
		ok(lt.get_font_size("font_size", "Big") == 34 and lt.get_font_size("font_size", "Score") == 40, "theme Big 34 / Score 40")
		ok(lt.default_font_size == 16 and dt.default_font_size == 16, "default font size 16 in both")
	for v in ["Big", "BigCard", "Card", "Eyebrow", "FlatButton", "H1", "H2", "H3", "Muted", "OptionRow", "Score", "Seg", "Small", "Strong", "Sunk", "Tile", "Toast", "TopBar",
			"LargeTitle", "AppBarTitle", "SectionHeader", "ListMain", "ListSub", "Group", "FilterChip"]:
		ok(lt.get_type_variation_base(v) != "" and dt.get_type_variation_base(v) == lt.get_type_variation_base(v), "variation %s exists in both themes" % v)
	ok(lt.get_color("font_color", "Label") == Color(Pal.LIGHT["INK"]), "light theme Label colour = light INK")
	ok(dt.get_color("font_color", "Label") == Color(Pal.DARK["INK"]), "dark theme Label colour = dark INK")
	ok(dt.get_color("font_color", "SectionHeader") == Color(Pal.DARK["PRIMARY"]) and lt.get_color("font_color", "SectionHeader") == Color(Pal.LIGHT["PRIMARY"]), "SectionHeader uses PRIMARY of each scheme")
	var lbg := (lt.get_stylebox("panel", "TopBar") as StyleBoxFlat).bg_color
	var dbg := (dt.get_stylebox("panel", "TopBar") as StyleBoxFlat).bg_color
	ok(lbg == Color(Pal.LIGHT["BG"]) and dbg == Color(Pal.DARK["BG"]), "TopBar background = BG of each scheme")
	ok(lt.get_icon("checked", "CheckButton") != null and lt.get_icon("checked", "CheckButton").get_size().x >= 52, "light theme file carries the switch icon (>= 52 wide)")
	ok(dt.get_icon("checked", "CheckButton") != null and dt.get_icon("checked", "CheckButton").get_size().x >= 52, "dark theme file carries the switch icon (>= 52 wide)")
	ok(lt.get_icon("arrow", "OptionButton") != null, "light theme file carries the OptionButton arrow")


func _test_uiboot() -> void:
	print("[UiBoot.apply]")
	var win := Window.new()
	var probe := Label.new()
	probe.theme_type_variation = "H1"
	add_child(probe)
	var s := UiBoot.apply(win, "dark", 1.0)
	await get_tree().process_frame
	ok(s == "dark" and Pal.scheme() == "dark", "apply(dark) -> 'dark'")
	ok(win.theme != null and win.theme.get_color("font_color", "Label") == Color(Pal.DARK["INK"]), "window got the dark theme")
	# what the player sees: a Label in the tree resolves its colour through the project theme (Window.theme alone
	# does not reach controls in Godot 4.6.3), so apply() must change that
	ok(probe.get_theme_color("font_color") == Color(Pal.DARK["INK"]), "a live Label really uses the dark colours after apply(dark)")
	ok(ThemeDB.get_project_theme().get_icon("checked", "CheckButton") != null and ThemeDB.get_project_theme().get_stylebox("panel", "Card").bg_color == Color(Pal.DARK["SURFACE"]), "project theme now holds the dark Card / icons")
	s = UiBoot.apply(win, "light", 1.5)
	await get_tree().process_frame
	ok(s == "light" and Pal.scheme() == "light" and Ds.font_scale == 1.5, "apply(light, 1.5)")
	ok(probe.get_theme_color("font_color") == Color(Pal.LIGHT["INK"]), "a live Label is light again after apply(light)")
	ok(probe.get_theme_font_size("font_size") == Ds.fs(Ds.type_size_for("H1", Platform.is_phone())), "a live H1 Label follows the 150%% font size (%d)" % probe.get_theme_font_size("font_size"))
	var t: Theme = win.theme
	ok(t != null and t.get_color("font_color", "Label") == Color(Pal.LIGHT["INK"]), "window got the light theme")
	var small_phone := Platform.is_phone()
	ok(t.get_font_size("font_size", "Small") == Ds.fs(Ds.type_size_for("Small", small_phone)), "150%%: Small = %d" % t.get_font_size("font_size", "Small"))
	ok(t.default_font_size == Ds.fs(Ds.type_size_for("", small_phone)), "150%%: default size = %d" % t.default_font_size)
	# Ds.apply_type_sizes recomputes from the table: running it again on the same theme does not compound
	Ds.apply_type_sizes(t, small_phone)
	Ds.apply_type_sizes(t, small_phone)
	ok(t.get_font_size("font_size", "Small") == Ds.fs(Ds.type_size_for("Small", small_phone)), "applying 150%% twice to one theme does not compound (%d)" % t.get_font_size("font_size", "Small"))
	UiBoot.apply(win, "light", 1.0)
	t = win.theme
	ok(t.get_font_size("font_size", "Small") == Ds.type_size_for("Small", small_phone), "back to 100%: Small = table value")
	ok(t.get_icon("checked", "CheckButton") != null, "icons applied")
	s = UiBoot.apply(win, "purple", 1.0)
	ok(s == Pal.resolve("system"), "apply('purple') = system preference (%s)" % s)
	s = UiBoot.apply(win, "dark", 9.0)
	ok(s == "dark" and Ds.font_scale == 1.5, "apply(dark, 9.0) -> scale clamped to 1.5")
	# broken inputs: the dark theme is missing / garbage -> everything falls back to light, no crash
	s = UiBoot.apply_with_paths(win, "dark", 1.0, UiBoot.LIGHT_THEME, "res://theme/__no_such_dark_theme__.tres")
	ok(s == "light" and Pal.scheme() == "light", "missing dark theme file -> light")
	ok(win.theme != null and win.theme.get_color("font_color", "Label") == Color(Pal.LIGHT["INK"]), "missing dark theme: window has the light theme")
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(Store.GUARD_DIR))
	var bad_path: String = Store.GUARD_DIR + "/w1_bad_theme.tres"
	var f := FileAccess.open(bad_path, FileAccess.WRITE)
	if f != null:
		f.store_string("this is not a theme resource {{{")
		f.close()
	s = UiBoot.apply_with_paths(win, "dark", 1.0, UiBoot.LIGHT_THEME, bad_path)
	ok(s == "light" and Pal.scheme() == "light", "garbage dark theme file -> light")
	s = UiBoot.apply_with_paths(win, "light", 1.0, "res://theme/__no_such_light__.tres", "res://theme/__no_such_dark__.tres")
	ok(s == "light" and win.theme != null, "missing light theme too: still returns light with some theme")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(bad_path))
	# leave the shared, cached theme resources as the files define them
	UiBoot.apply(win, "light", 1.0)
	await get_tree().process_frame
	ok(probe.get_theme_color("font_color") == Color(Pal.LIGHT["INK"]) and probe.get_theme_font_size("font_size") == Ds.type_size_for("H1", Platform.is_phone()), "project theme restored to light 100%")
	probe.queue_free()
	win.free()
	Pal.use("light")
	Ds.set_font_scale(1.0)
	await get_tree().process_frame


## An icon is fine when it is a Texture2D whose image has a size and at least one visible pixel.
static func icon_ok(tex: Texture2D, min_w: int = 1, min_h: int = 1) -> bool:
	if tex == null:
		return false
	var im: Image = tex.get_image()
	if im == null or im.is_empty() or im.get_width() < min_w or im.get_height() < min_h:
		return false
	for y in range(0, im.get_height(), 2):
		for x in range(0, im.get_width(), 2):
			if im.get_pixel(x, y).a > 0.05:
				return true
	return false


func _test_icons() -> void:
	print("[ThemeIcons / GlyphIcon helpers]")
	# the checker itself: null, empty image and a fully transparent image must be rejected
	ok(not icon_ok(null), "selfcheck icon_ok(null) is false")
	var blank := Image.create(16, 16, false, Image.FORMAT_RGBA8)
	blank.fill(Color(0, 0, 0, 0))
	ok(not icon_ok(ImageTexture.create_from_image(blank)), "selfcheck icon_ok(transparent image) is false")
	for scheme in ["light", "dark"]:
		Pal.use(scheme)
		var th := Theme.new()
		ThemeIcons.apply(th)
		var n := 0
		for type_name in ThemeIcons.ICONS.keys():
			for icon_name in ThemeIcons.ICONS[type_name]:
				var tex: Texture2D = th.get_icon(icon_name, type_name)
				n += 1
				ok(icon_ok(tex), "%s %s/%s is a non-empty image" % [scheme, type_name, icon_name])
		ok(n == 12, "%s: 12 icons set" % scheme)
		var sw: Texture2D = th.get_icon("checked", "CheckButton")
		ok(sw.get_size().x >= 52 and sw.get_size().y >= 32, "%s switch is %s (>= 52x32)" % [scheme, sw.get_size()])
		ok(th.get_icon("checked", "CheckBox").get_size().x >= 24, "%s check box >= 24" % scheme)
		# colours really come from the current scheme: the switch track is PRIMARY when on
		var im: Image = sw.get_image()
		var px: Color = im.get_pixel(int(im.get_width() * 0.2), int(im.get_height() * 0.5))
		ok(absf(px.r - Pal.PRIMARY.r) < 0.06 and absf(px.g - Pal.PRIMARY.g) < 0.06 and absf(px.b - Pal.PRIMARY.b) < 0.06, "%s switch track pixel = PRIMARY" % scheme)
		var off: Image = th.get_icon("unchecked", "CheckButton").get_image()
		ok(off.get_pixel(int(off.get_width() * 0.7), int(off.get_height() * 0.5)).a > 0.5, "%s unchecked switch has a body" % scheme)
		ok(icon_ok(th.get_icon("checked_disabled", "CheckButton")), "%s disabled switch visible" % scheme)
	Pal.use("light")
	ThemeIcons.apply(null)
	ok(true, "ThemeIcons.apply(null) does not crash")


func _test_glyph() -> void:
	print("[GlyphIcon]")
	var host := Control.new()
	host.size = Vector2(200, 200)
	add_child(host)
	for kind in GlyphIcon.KINDS + ["nope", ""]:
		var g := GlyphIcon.new(kind, 24.0, Color.RED)
		ok(g.custom_minimum_size == Vector2(24, 24), "GlyphIcon('%s') min size 24x24" % kind)
		ok(g.mouse_filter == Control.MOUSE_FILTER_IGNORE, "GlyphIcon('%s') ignores the mouse" % kind)
		host.add_child(g)
	var d := GlyphIcon.new()
	ok(d.custom_minimum_size == Vector2(20, 20) and d.kind == "chevron_right" and d.icon_color == Pal.INK, "defaults: chevron_right 20 px INK")
	host.add_child(d)
	await get_tree().process_frame
	await get_tree().process_frame
	ok(host.get_child_count() == GlyphIcon.KINDS.size() + 3, "all glyphs survived two frames of drawing")
	var tiny := GlyphIcon.new("close", 0.0)
	host.add_child(tiny)
	await get_tree().process_frame
	ok(tiny.custom_minimum_size == Vector2.ZERO, "zero-size glyph draws nothing and does not crash")
	host.queue_free()
	await get_tree().process_frame
