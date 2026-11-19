// Thin wrappers around whisper.cpp calls that turn a C++ exception (bad_alloc, out_of_range, ...) into an error code.
// wb_guard.cpp is compiled WITH exceptions; the rest of the bridge is compiled without them (godot-cpp rule).
#pragma once

#include "whisper.h"

whisper_context *wb_guard_init(const char *path_utf8, whisper_context_params params);
int wb_guard_full(whisper_context *ctx, whisper_full_params params, const float *samples, int n_samples); // -100 = exception
