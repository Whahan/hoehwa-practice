extends Node
## Tiny message bus: any script can call Toast.error("...") and the main scene shows it.
##
## `message(text, kind)` is the long-standing contract (kind "info" | "ok" | "error"; the text that goes out is never
## changed). `snack` is the same for a message with one action button on its right (docs/ui_redesign_design.md §6.6).

signal message(text: String, kind: String)
signal snack(text: String, action_text: String, action: Callable)


func info(text: String) -> void:
	message.emit(text, "info")


func ok(text: String) -> void:
	message.emit(text, "ok")


func error(text: String) -> void:
	message.emit(text, "error")


## A message with an action button ("되돌리기" ...). While nobody listens to `snack` (a screen that has not been
## moved to ToastHost yet) it falls back to a plain info message, so the text is never lost.
func show_snack(text: String, action_text: String, action: Callable = Callable()) -> void:
	if snack.get_connections().is_empty():
		message.emit(text, "info")
		return
	snack.emit(text, action_text, action)
