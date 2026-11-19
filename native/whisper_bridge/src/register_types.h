// Registration of the WhisperBridge GDExtension (entry symbol: whisper_bridge_init).
#pragma once

#include <godot_cpp/godot.hpp>

void initialize_whisper_bridge_module(godot::ModuleInitializationLevel p_level);
void uninitialize_whisper_bridge_module(godot::ModuleInitializationLevel p_level);
