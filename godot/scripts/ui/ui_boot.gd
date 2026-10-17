class_name UiBoot
extends RefCounted
## Applies colour scheme, theme file, phone adjustments, font size and icons once at start
## (docs/ui_redesign_design.md §5.1.4). The scheme is NOT switched while the app runs: code-built UI copies Pal
## colours when it is built, so a change needs a restart.
##
## Why the project theme is rewritten in place: in Godot 4.6.3 a Theme assigned to the ROOT Window (Window.theme)
## does not reach the Controls below it (measured: Label.get_theme_color still came from gui/theme/custom), while
## a Control.theme does. The app's controls get their theme from the project theme, so apply() copies the chosen
## theme into it (Theme.merge_with overwrites every item of the same name, so light and dark, built by the same code, replace each other completely: every control restyles at once, popups included). Window.theme is set
## too, so nothing changes if a later engine makes it effective.

const LIGHT_THEME := "res://theme/app_theme.tres"
const DARK_THEME := "res://theme/app_theme_dark.tres"


## scheme_pref "system" | "light" | "dark" (anything else = "system"); font_scale as Ds.set_font_scale.
## Returns the scheme that was applied: "light" | "dark".
static func apply(root: Window, scheme_pref: String, font_scale: float) -> String:
	return apply_with_paths(root, scheme_pref, font_scale, LIGHT_THEME, DARK_THEME)


## Same with explicit theme files (tests pass a missing or broken dark file). A dark theme that cannot be loaded
## makes the whole app light (a dark palette on a light theme would mix the two); a missing light theme leaves the
## project's current theme in place. Never throws.
static func apply_with_paths(root: Window, scheme_pref: String, font_scale: float, light_path: String, dark_path: String) -> String:
	var scheme: String = Pal.resolve(scheme_pref)
	var theme: Theme = null
	if scheme == "dark":
		theme = _load_theme(dark_path)
		if theme == null:
			push_error("UiBoot: dark theme '%s' could not be loaded, using the light theme" % dark_path)
			scheme = "light"
	Pal.use(scheme)
	if theme == null:
		theme = _load_theme(light_path)
	if theme == null:
		push_error("UiBoot: theme '%s' could not be loaded, keeping the current theme" % light_path)
		theme = ThemeDB.get_project_theme()
	if theme == null:
		theme = Theme.new()
	if Platform.is_phone():
		PhoneLayout.apply_theme(theme)
	Ds.set_font_scale(font_scale)
	Ds.apply_type_sizes(theme, Platform.is_phone())
	ThemeIcons.apply(theme)
	if root != null:
		root.theme = theme
	_install_in_project_theme(theme)
	if OS.is_debug_build() and OS.get_cmdline_user_args().has("--ui-debug"):
		print("UiBoot scheme=%s scale=%s phone=%s screen=%s visible=%s dpi=%s touch_min=%s" % [
			scheme, Ds.font_scale, Platform.is_phone(), DisplayServer.screen_get_size(),
			root.get_visible_rect().size if root != null else Vector2.ZERO, DisplayServer.screen_get_dpi(), Ds.touch_min()])
	return scheme


## Replaces the content of the project theme (gui/theme/custom) with `theme`'s. No project theme -> nothing to do.
static func _install_in_project_theme(theme: Theme) -> void:
	var project: Theme = ThemeDB.get_project_theme()
	if project == null or project == theme:
		return
	project.merge_with(theme)
	project.default_font = theme.default_font
	project.default_font_size = theme.default_font_size


## A fresh instance every time (cache ignored): apply() edits the theme, and the cached resource is the project
## theme itself, which must not be edited through a stale reference.
static func _load_theme(path: String) -> Theme:
	if not ResourceLoader.exists(path):
		return null
	var r: Resource = ResourceLoader.load(path, "Theme", ResourceLoader.CACHE_MODE_IGNORE)
	return r as Theme
