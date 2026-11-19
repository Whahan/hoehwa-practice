// Structural check of a whisper.cpp ggml model file BEFORE it is handed to whisper.cpp.
// The loader of whisper.cpp ignores short reads (a cut-off file leaves uninitialised values, and "no tensors loaded" counts as
// success), so a damaged file can end in a crash later. This walks the whole file (header, mel filters, vocabulary, tensor table)
// and accepts it only when every byte it describes lies inside the file and the file ends exactly after the last tensor.
// No Godot dependency: it can be unit-tested on the host.
#pragma once

#include <cstdint>
#include <string>

namespace wb {

enum class ModelCheck {
	Ok = 0,
	CantOpen,
	TooSmall,
	BadMagic,
	BadHparams,
	BadFilters,
	BadVocab,
	BadTensor,
	Truncated,
	NoTensors,
};

const char *model_check_name(ModelCheck c);

// path is UTF-8. On success *out_size (if given) is the file size.
ModelCheck check_model_file(const std::string &path, int64_t *out_size = nullptr);

} // namespace wb
