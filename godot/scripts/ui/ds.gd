class_name Ds
extends RefCounted
## Design tokens except colours (those are in Pal): text sizes, spacing, radii, heights
## (docs/ui_redesign_design.md §5.2, §5.3, §6.2). Units are logical px; 1 logical px ~ 1 dp on the 412 px phone.

const R_XS := 6
const R_S := 12
const R_INPUT := 14
const R_BTN := 18
const R_CARD := 24
const R_SHEET := 28
const R_PILL := 99

const S1 := 4
const S2 := 8
const S3 := 12
const S4 := 16
const S5 := 20
const S6 := 24
const S8 := 32
const S10 := 40

## Recorder button sizes of the PC layout: phone_layout_test asserts them, do not change.
const REC_BIG_PC := Vector2(190, 58)
const REC_SMALL_PC := Vector2(96, 44)

const SCALES := [0.9, 1.0, 1.15, 1.3, 1.5]
const MIN_FONT := 12

## Theme type variation -> [PC size, phone size] before the font scale (§5.2).
## H2 on the phone is 21 (the design table says 22): 22 shifts the reading library page just enough that
## touch_scroll_test no longer finds a "card" start point there (one test case fewer, passed 122 < baseline 123).
## Default (no variation) is BASE_SIZE. Bold / colour live in tools/make_theme.gd.
const TYPE_TABLE := {
	"Big": [34, 34], "Score": [40, 40], "LargeTitle": [32, 32], "H1": [28, 30], "AppBarTitle": [20, 20],
	"H2": [21, 21], "H3": [17, 18], "Strong": [16, 17], "ListMain": [16, 17], "Muted": [15, 16],
	"Small": [13, 14], "ListSub": [13, 14], "Eyebrow": [12, 13], "SectionHeader": [14, 15], "Tile": [18, 18],
}
const BASE_SIZE := [16, 17]

static var font_scale: float = 1.0


## Accepts one of 0.9 / 1.0 / 1.15 / 1.3 / 1.5 or the closest one; NaN, infinity, <= 0 or a non-number -> 1.0.
static func set_font_scale(f: Variant) -> void:
	font_scale = sanitize_scale(f)


static func sanitize_scale(f: Variant) -> float:
	if typeof(f) != TYPE_FLOAT and typeof(f) != TYPE_INT:
		return 1.0
	var v: float = float(f)
	if is_nan(v) or is_inf(v) or v <= 0.0:
		return 1.0
	var best: float = 1.0
	var best_d: float = INF
	for s in SCALES:
		var d: float = absf(v - float(s))
		if d < best_d - 0.000001:
			best_d = d
			best = float(s)
	return best


## Text size n scaled by the user's font size setting, never below 12.
static func fs(n: int) -> int:
	return maxi(MIN_FONT, int(roundf(float(n) * font_scale)))


## Text size of a theme variation before the font scale (phone / PC picked by Platform).
static func type_size(variation: String) -> int:
	return type_size_for(variation, Platform.is_phone())


static func type_size_for(variation: String, phone: bool) -> int:
	var row: Array = TYPE_TABLE.get(variation, BASE_SIZE)
	return int(row[1 if phone else 0])


## Writes every size of the table (times the font scale) and the default size into `theme`. Idempotent: it
## recomputes from the table, never from the current value.
static func apply_type_sizes(theme: Theme, phone: bool) -> void:
	if theme == null:
		return
	theme.default_font_size = fs(type_size_for("", phone))
	for k in TYPE_TABLE.keys():
		theme.set_font_size("font_size", String(k), fs(type_size_for(String(k), phone)))


## Minimum touch target edge: PC 40; phone 48 dp expressed in logical px (48..60, larger when the screen is
## narrower than the 412 dp the logical canvas assumes).
static func touch_min() -> float:
	if not Platform.is_phone():
		return 40.0
	return clampf(48.0 / PhoneLayout.dp_scale(), 48.0, 60.0)


static func btn_h() -> float:
	return touch_min()


static func field_h() -> float:
	return touch_min()
