extends Node
## Tiny message bus: any script can call Toast.error("...") and the main scene shows it.

signal message(text: String, kind: String)


func info(text: String) -> void:
	message.emit(text, "info")


func ok(text: String) -> void:
	message.emit(text, "ok")


func error(text: String) -> void:
	message.emit(text, "error")
