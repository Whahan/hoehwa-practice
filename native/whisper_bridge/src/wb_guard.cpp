#include "wb_guard.h"

whisper_context *wb_guard_init(const char *path_utf8, whisper_context_params params) {
#if defined(__cpp_exceptions) || defined(__EXCEPTIONS)
	try {
		return whisper_init_from_file_with_params(path_utf8, params);
	} catch (...) {
		return nullptr;
	}
#else
	return whisper_init_from_file_with_params(path_utf8, params);
#endif
}

int wb_guard_full(whisper_context *ctx, whisper_full_params params, const float *samples, int n_samples) {
#if defined(__cpp_exceptions) || defined(__EXCEPTIONS)
	try {
		return whisper_full(ctx, params, samples, n_samples);
	} catch (...) {
		return -100;
	}
#else
	return whisper_full(ctx, params, samples, n_samples);
#endif
}
