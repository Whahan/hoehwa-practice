extends SceneTree
## Screenshot sanity check (docs/ui_redesign_design.md §8.4 W1b). Headless, no engine or server needed:
##   godot --headless --path <project> --script res://tools/shot_check.gd -- <folder> [--expect=412x915] [--scheme=light|dark]
## Every *.png in <folder> is checked for:
##   size      : equals --expect (only when given)
##   blank     : luminance standard deviation < 0.02 (a single-colour image)
##   direction : mean luminance > 0.70 for --scheme=light, < 0.35 for --scheme=dark
## A folder without any PNG is a failure too (nothing was checked).
## Last line: "SHOT_CHECK ok=<n> bad=<m>". Exit code 1 when bad > 0, 2 for bad arguments.

const BLANK_STD := 0.02
const LIGHT_MIN_MEAN := 0.70
const DARK_MAX_MEAN := 0.35
const STEP := 4 ## sample every 4th pixel in x and y (enough for mean and deviation, fast in GDScript)


func _init() -> void:
	quit(_run())


func _run() -> int:
	var folder := ""
	var expect := Vector2i.ZERO
	var scheme := "light"
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--expect="):
			var parts := a.substr(9).to_lower().split("x")
			if parts.size() != 2 or not parts[0].is_valid_int() or not parts[1].is_valid_int():
				printerr("shot_check: bad --expect (want WxH): " + a)
				return 2
			expect = Vector2i(parts[0].to_int(), parts[1].to_int())
		elif a.begins_with("--scheme="):
			scheme = a.substr(9)
		elif a.begins_with("--"):
			printerr("shot_check: unknown option: " + a)
			return 2
		elif folder == "":
			folder = a
	if folder == "" or (scheme != "light" and scheme != "dark"):
		printerr("usage: -- <folder> [--expect=WxH] [--scheme=light|dark]")
		return 2
	folder = folder.replace("\\", "/")
	var dir := DirAccess.open(folder)
	if dir == null:
		printerr("shot_check: cannot open folder: " + folder)
		return 2
	var names: Array = []
	for f in dir.get_files():
		if f.to_lower().ends_with(".png"):
			names.append(f)
	names.sort()
	var ok := 0
	var bad := 0
	for n in names:
		var why := _check(folder.path_join(n), expect, scheme)
		if why == "":
			ok += 1
			print("  OK   ", n)
		else:
			bad += 1
			print("  BAD  ", n, "  ", why)
	if names.is_empty():
		bad += 1
		print("  BAD   no .png files in ", folder)
	print("SHOT_CHECK ok=%d bad=%d" % [ok, bad])
	return 1 if bad > 0 else 0


## "" when the image passes, otherwise the reason.
func _check(path: String, expect: Vector2i, scheme: String) -> String:
	var img: Image = Image.load_from_file(path)
	if img == null or img.is_empty():
		return "PNG load failed"
	var size := img.get_size()
	if expect != Vector2i.ZERO and size != expect:
		return "size %dx%d, expected %dx%d" % [size.x, size.y, expect.x, expect.y]
	var n := 0
	var sum := 0.0
	var sum2 := 0.0
	for y in range(0, size.y, STEP):
		for x in range(0, size.x, STEP):
			var c := img.get_pixel(x, y)
			var l := 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
			sum += l
			sum2 += l * l
			n += 1
	var mean := sum / n
	var std := sqrt(maxf(sum2 / n - mean * mean, 0.0))
	if std < BLANK_STD:
		return "blank image (luminance std %.4f < %.2f)" % [std, BLANK_STD]
	if scheme == "light" and mean <= LIGHT_MIN_MEAN:
		return "light scheme but mean luminance %.3f <= %.2f" % [mean, LIGHT_MIN_MEAN]
	if scheme == "dark" and mean >= DARK_MAX_MEAN:
		return "dark scheme but mean luminance %.3f >= %.2f" % [mean, DARK_MAX_MEAN]
	return ""
