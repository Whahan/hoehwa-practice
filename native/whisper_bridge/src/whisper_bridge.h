// WhisperBridge: a thin GDExtension wrapper around whisper.cpp (docs/v200_phone_design.md section 1.4).
// One model, one transcription at a time (a second transcribe() call waits on the mutex).
#pragma once

#include <atomic>
#include <mutex>

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/string.hpp>

struct whisper_context;

namespace godot {

class WhisperBridge : public RefCounted {
	GDCLASS(WhisperBridge, RefCounted)

	std::mutex mutex_; // guards ctx_ (held for the whole transcription)
	mutable std::mutex name_mutex_; // guards model_file_ only (a String must not be read while it is written)
	whisper_context *ctx_ = nullptr;
	std::atomic<bool> loaded_{ false };
	std::atomic<bool> abort_{ false };
	int threads_ = 2;
	String model_file_;

protected:
	static void _bind_methods();

public:
	WhisperBridge();
	~WhisperBridge();

	static String version();
	static String check_model(const String &p_path); // "ok" or why the file is not a complete model (see model_check.h)
	static String cpu_features(); // e.g. "asimd asimddp i8mm", "" when unknown
	static Dictionary memory_info(); // {peak_kb, rss_kb} of this process (0 = unknown)

	int load_model(const String &p_path, int p_threads = 0);
	bool is_loaded() const;
	String model_file() const;
	void unload();
	Dictionary transcribe(const PackedByteArray &p_wav, const String &p_lang, const Dictionary &p_options = Dictionary());
	void abort();

private:
	void set_model_file(const String &p_name);
};

} // namespace godot
