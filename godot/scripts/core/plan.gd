class_name Plan
extends RefCounted
## Date / curriculum-position logic (mirrors the web app's position()).
##
## Dates are plain {year, month, day} dictionaries. Everything is converted to a
## day number (days since 1970-01-01) so no timezone is involved.

const DEFAULT_START := "2026-11-01"


static func days_from_civil(y: int, m: int, d: int) -> int:
	# Howard Hinnant's algorithm; works for any proleptic Gregorian date.
	var yy: int = y - (1 if m <= 2 else 0)
	var era: int = floori(float(yy) / 400.0)
	var yoe: int = yy - era * 400
	var mp: int = (m + 9) % 12
	var doy: int = (153 * mp + 2) / 5 + d - 1
	var doe: int = yoe * 365 + yoe / 4 - yoe / 100 + doy
	return era * 146097 + doe - 719468


static func civil_from_days(z: int) -> Dictionary:
	var zz: int = z + 719468
	var era: int = floori(float(zz) / 146097.0)
	var doe: int = zz - era * 146097
	var yoe: int = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
	var y: int = yoe + era * 400
	var doy: int = doe - (365 * yoe + yoe / 4 - yoe / 100)
	var mp: int = (5 * doy + 2) / 153
	var d: int = doy - (153 * mp + 2) / 5 + 1
	var m: int = mp + (3 if mp < 10 else -9)
	return {"year": y + (1 if m <= 2 else 0), "month": m, "day": d}


static func is_valid_iso(s: String) -> bool:
	var rx := RegEx.new()
	rx.compile("^\\d{4}-\\d{2}-\\d{2}$")
	if rx.search(s) == null:
		return false
	var p := s.split("-")
	var y: int = int(p[0])
	var m: int = int(p[1])
	var d: int = int(p[2])
	if m < 1 or m > 12 or d < 1 or d > 31:
		return false
	var back: Dictionary = civil_from_days(days_from_civil(y, m, d))
	return back["year"] == y and back["month"] == m and back["day"] == d


## ISO "YYYY-MM-DD" -> day number.
static func iso_to_days(s: String) -> int:
	var p := s.split("-")
	return days_from_civil(int(p[0]), int(p[1]), int(p[2]))


static func days_to_iso(days: int) -> String:
	var c: Dictionary = civil_from_days(days)
	return "%04d-%02d-%02d" % [c["year"], c["month"], c["day"]]


## Today's day number from the system clock (local date).
static func today_days() -> int:
	var d: Dictionary = Time.get_date_dict_from_system()
	return days_from_civil(d["year"], d["month"], d["day"])


static func today_iso() -> String:
	return days_to_iso(today_days())


## Day number of (start + n months), JS Date-style (day overflow rolls over).
static func add_months(start_days: int, n: int) -> int:
	var c: Dictionary = civil_from_days(start_days)
	var total: int = int(c["year"]) * 12 + int(c["month"]) - 1 + n
	var y: int = floori(float(total) / 12.0)
	var m: int = total - y * 12 + 1
	return days_from_civil(y, m, 1) + int(c["day"]) - 1


## Weekday 0=Sunday .. 6=Saturday for a day number.
static func weekday(days: int) -> int:
	return posmod(days + 4, 7) # 1970-01-01 was a Thursday


static func stage_of(month_n: int) -> int:
	return clampi(ceili(float(month_n) / 3.0), 1, 4)


## {phase: "before"|"on"|"after", n: 1-12, w: 1-4, days (before) | day_no (on/after)}
static func position(start_iso: String, today: int) -> Dictionary:
	var s: int = iso_to_days(start_iso)
	if today < s:
		return {"phase": "before", "n": 1, "w": 1, "days": s - today}
	var n := 0
	while n < 12 and add_months(s, n + 1) <= today:
		n += 1
	if n >= 12:
		return {"phase": "after", "n": 12, "w": 4, "day_no": today - s + 1}
	var w: int = mini(4, (today - add_months(s, n)) / 7 + 1)
	return {"phase": "on", "n": n + 1, "w": w, "day_no": today - s + 1}


static func total_days(start_iso: String) -> int:
	var s: int = iso_to_days(start_iso)
	return add_months(s, 12) - s


## "2026.11" for curriculum month n.
static func month_label(start_iso: String, n: int) -> String:
	var c: Dictionary = civil_from_days(add_months(iso_to_days(start_iso), n - 1))
	return "%04d.%02d" % [c["year"], c["month"]]


## Monday of the week containing the given day number.
static func monday_of(days: int) -> int:
	return days - posmod(weekday(days) - 1, 7)
