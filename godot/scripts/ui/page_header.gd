class_name PageHeader
extends RefCounted
## The big title block that is the first item of a screen's scrolling page (docs/ui_redesign_design.md §6.3).
##
## Phone: a big title (at most two lines, then an ellipsis) and a one-line summary, standing low in a block that is
## at least 112 px high. It has nothing to tap (mouse_filter PASS everywhere), so a finger that starts on it scrolls
## the page. The fixed AppBar above the scroll shows the small title once this block has scrolled away.
## PC: one row: title (H1) with the summary under it on the left, action buttons on the right.
##
## `actions` = [{"id": String, "text": String, "cb": Callable (optional)}]. The phone shows none (the AppBar owns the
## actions there). On the PC every action is a tonal button; its Button is also stored in the root's meta
## "action_buttons" ({id: Button}) so a caller can connect `pressed` itself.

const PHONE_H := 112.0
const PC_H := 72.0


static func height() -> float:
	return PHONE_H if Platform.is_phone() else PC_H


static func build(title: String, subtitle: String = "", actions: Array = []) -> Control:
	return _build_phone(title, subtitle) if Platform.is_phone() else _build_pc(title, subtitle, actions)


static func _build_phone(title: String, subtitle: String) -> Control:
	var root := MarginContainer.new()
	root.name = "PageHeader"
	root.mouse_filter = Control.MOUSE_FILTER_PASS
	root.custom_minimum_size.y = PHONE_H
	# the page already keeps 16 px from the screen edge; 8 more put the text 24 px from it
	root.add_theme_constant_override("margin_left", Ds.S2)
	root.add_theme_constant_override("margin_right", Ds.S2)
	root.add_theme_constant_override("margin_top", 8)
	root.add_theme_constant_override("margin_bottom", 12)
	var col := VBoxContainer.new()
	col.mouse_filter = Control.MOUSE_FILTER_PASS
	col.alignment = BoxContainer.ALIGNMENT_END
	col.add_theme_constant_override("separation", 4)
	root.add_child(col)
	var t := UI.label(title, "LargeTitle")
	t.mouse_filter = Control.MOUSE_FILTER_PASS
	t.max_lines_visible = 2
	t.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	col.add_child(t)
	root.set_meta("title_label", t)
	if subtitle != "":
		var s := UI.label(subtitle, "Muted")
		s.mouse_filter = Control.MOUSE_FILTER_PASS
		s.max_lines_visible = 2
		s.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		col.add_child(s)
		root.set_meta("subtitle_label", s)
	return root


static func _build_pc(title: String, subtitle: String, actions: Array) -> Control:
	var root := HBoxContainer.new()
	root.name = "PageHeader"
	root.mouse_filter = Control.MOUSE_FILTER_PASS
	root.custom_minimum_size.y = PC_H
	root.add_theme_constant_override("separation", 12)
	var col := VBoxContainer.new()
	col.mouse_filter = Control.MOUSE_FILTER_PASS
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	col.add_theme_constant_override("separation", 2)
	root.add_child(col)
	var t := UI.label(title, "H1", false)
	t.mouse_filter = Control.MOUSE_FILTER_PASS
	t.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	col.add_child(t)
	root.set_meta("title_label", t)
	if subtitle != "":
		var s := UI.label(subtitle, "Muted", false)
		s.mouse_filter = Control.MOUSE_FILTER_PASS
		s.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		col.add_child(s)
		root.set_meta("subtitle_label", s)
	var buttons := {}
	for a in actions:
		if not (a is Dictionary):
			continue
		var text: String = str((a as Dictionary).get("text", ""))
		if text == "":
			continue
		var b := UI.button(text, "soft", Pal.PRIMARY, 40.0)
		b.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		var cb: Variant = (a as Dictionary).get("cb", null)
		if cb is Callable and (cb as Callable).is_valid():
			b.pressed.connect(cb)
		buttons[str((a as Dictionary).get("id", text))] = b
		root.add_child(b)
	root.set_meta("action_buttons", buttons)
	return root
