#include "model_check.h"

#include <filesystem>
#include <fstream>
#include <vector>

#include "ggml.h"

namespace wb {

namespace {

constexpr uint32_t kMagic = 0x67676d6c; // "ggml" (GGML_FILE_MAGIC of the pinned whisper.cpp)
constexpr int kMaxVocabToken = 1024;

bool type_allowed(int32_t t) {
	switch (t) {
		case GGML_TYPE_F32:
		case GGML_TYPE_F16:
		case GGML_TYPE_Q4_0:
		case GGML_TYPE_Q4_1:
		case GGML_TYPE_Q5_0:
		case GGML_TYPE_Q5_1:
		case GGML_TYPE_Q8_0:
		case GGML_TYPE_Q2_K:
		case GGML_TYPE_Q3_K:
		case GGML_TYPE_Q4_K:
		case GGML_TYPE_Q5_K:
		case GGML_TYPE_Q6_K:
			return true;
		default:
			return false;
	}
}

struct Reader {
	std::ifstream f;
	int64_t size = 0;
	int64_t pos = 0;

	bool at(int64_t off) {
		f.clear();
		f.seekg((std::streamoff)off);
		pos = off;
		return (bool)f;
	}
	template <typename T>
	bool get(T &v) {
		f.read(reinterpret_cast<char *>(&v), sizeof(T));
		if (!f) {
			return false;
		}
		pos += (int64_t)sizeof(T);
		return true;
	}
};

} // namespace

const char *model_check_name(ModelCheck c) {
	switch (c) {
		case ModelCheck::Ok: return "ok";
		case ModelCheck::CantOpen: return "cant_open";
		case ModelCheck::TooSmall: return "too_small";
		case ModelCheck::BadMagic: return "bad_magic";
		case ModelCheck::BadHparams: return "bad_hparams";
		case ModelCheck::BadFilters: return "bad_filters";
		case ModelCheck::BadVocab: return "bad_vocab";
		case ModelCheck::BadTensor: return "bad_tensor";
		case ModelCheck::Truncated: return "truncated";
		case ModelCheck::NoTensors: return "no_tensors";
	}
	return "unknown";
}

ModelCheck check_model_file(const std::string &path, int64_t *out_size) {
	Reader r;
	r.f.open(std::filesystem::u8path(path), std::ios::binary);
	if (!r.f) {
		return ModelCheck::CantOpen;
	}
	r.f.seekg(0, std::ios::end);
	r.size = (int64_t)r.f.tellg();
	r.f.seekg(0, std::ios::beg);
	if (out_size) {
		*out_size = r.size;
	}
	if (r.size < 4 + 44 + 8) {
		return ModelCheck::TooSmall;
	}

	uint32_t magic = 0;
	if (!r.get(magic) || magic != kMagic) {
		return ModelCheck::BadMagic;
	}

	int32_t hp[11];
	for (int i = 0; i < 11; i++) {
		if (!r.get(hp[i])) {
			return ModelCheck::Truncated;
		}
	}
	const int32_t n_vocab = hp[0], n_audio_ctx = hp[1], n_audio_state = hp[2], n_audio_head = hp[3], n_audio_layer = hp[4];
	const int32_t n_text_ctx = hp[5], n_text_state = hp[6], n_text_head = hp[7], n_text_layer = hp[8], n_mels = hp[9], ftype = hp[10];
	const bool layers_ok = n_audio_layer == 4 || n_audio_layer == 6 || n_audio_layer == 12 || n_audio_layer == 24 || n_audio_layer == 32;
	const bool ranges_ok = n_vocab >= 50000 && n_vocab <= 60000 && n_audio_ctx >= 1 && n_audio_ctx <= 3000 && n_audio_state >= 64 &&
			n_audio_state <= 2048 && n_audio_head >= 1 && n_audio_head <= 32 && n_audio_state % n_audio_head == 0 && layers_ok &&
			n_text_ctx >= 1 && n_text_ctx <= 1024 && n_text_state == n_audio_state && n_text_head == n_audio_head && n_text_layer >= 1 &&
			n_text_layer <= 32 && (n_mels == 80 || n_mels == 128) && ftype >= 0;
	if (!ranges_ok || ggml_ftype_to_ggml_type((enum ggml_ftype)(ftype % GGML_QNT_VERSION_FACTOR)) == GGML_TYPE_COUNT) {
		return ModelCheck::BadHparams;
	}

	// mel filters
	int32_t n_mel = 0, n_fft = 0;
	if (!r.get(n_mel) || !r.get(n_fft)) {
		return ModelCheck::Truncated;
	}
	if ((n_mel != 80 && n_mel != 128) || n_fft != 201) {
		return ModelCheck::BadFilters;
	}
	const int64_t filter_bytes = (int64_t)n_mel * n_fft * 4;
	if (r.pos + filter_bytes > r.size) {
		return ModelCheck::Truncated;
	}
	if (!r.at(r.pos + filter_bytes)) {
		return ModelCheck::Truncated;
	}

	// vocabulary
	int32_t n_tok = 0;
	if (!r.get(n_tok)) {
		return ModelCheck::Truncated;
	}
	if (n_tok < 1 || n_tok > n_vocab) {
		return ModelCheck::BadVocab;
	}
	for (int32_t i = 0; i < n_tok; i++) {
		uint32_t len = 0;
		if (!r.get(len)) {
			return ModelCheck::Truncated;
		}
		if (len > (uint32_t)kMaxVocabToken) {
			return ModelCheck::BadVocab;
		}
		if (r.pos + (int64_t)len > r.size) {
			return ModelCheck::Truncated;
		}
		if (len > 0 && !r.at(r.pos + (int64_t)len)) {
			return ModelCheck::Truncated;
		}
	}

	// tensor table: n_dims, name length, type, ne[n_dims], name, data
	int count = 0;
	std::vector<char> name;
	while (r.pos < r.size) {
		int32_t n_dims = 0, length = 0, ttype = 0;
		if (r.pos + 12 > r.size) {
			return ModelCheck::Truncated;
		}
		if (!r.get(n_dims) || !r.get(length) || !r.get(ttype)) {
			return ModelCheck::Truncated;
		}
		if (n_dims < 1 || n_dims > 4 || length < 1 || length > 255 || !type_allowed(ttype)) {
			return ModelCheck::BadTensor;
		}
		if (r.pos + 4 * (int64_t)n_dims > r.size) {
			return ModelCheck::Truncated;
		}
		int64_t nelem = 1;
		int32_t ne0 = 1;
		for (int d = 0; d < n_dims; d++) {
			int32_t e = 0;
			if (!r.get(e)) {
				return ModelCheck::Truncated;
			}
			if (e < 1) {
				return ModelCheck::BadTensor;
			}
			if (d == 0) {
				ne0 = e;
			}
			nelem *= e;
			if (nelem > 2147483647LL) { // whisper.cpp keeps the element count in an int32
				return ModelCheck::BadTensor;
			}
		}
		const int64_t blck = ggml_blck_size((enum ggml_type)ttype);
		if (blck < 1 || ne0 % blck != 0) {
			return ModelCheck::BadTensor;
		}
		if (r.pos + (int64_t)length > r.size) {
			return ModelCheck::Truncated;
		}
		name.assign((size_t)length, 0);
		r.f.read(name.data(), length);
		if (!r.f) {
			return ModelCheck::Truncated;
		}
		r.pos += length;
		for (char c : name) {
			if ((unsigned char)c < 0x20 || (unsigned char)c > 0x7e) {
				return ModelCheck::BadTensor;
			}
		}
		const int64_t bytes = nelem / blck * (int64_t)ggml_type_size((enum ggml_type)ttype);
		if (r.pos + bytes > r.size) {
			return ModelCheck::Truncated;
		}
		if (!r.at(r.pos + bytes)) {
			return ModelCheck::Truncated;
		}
		count++;
	}
	return count >= 1 ? ModelCheck::Ok : ModelCheck::NoTensors;
}

} // namespace wb
