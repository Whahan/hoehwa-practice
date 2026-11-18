// WhisperBridge implementation. Contract: docs/v200_phone_design.md section 1.4.
// Rules kept here on purpose:
//  - No transcript text, path or audio goes to any log (whisper/ggml log output is dropped).
//  - transcribe() never throws and never crashes on bad input: every failure is an {ok:false, error:...} result.
//  - Only English ("en") is accepted.
#include "whisper_bridge.h"

#include <algorithm>
#include <chrono>
#include <cctype>
#include <cmath>
#include <numeric>
#include <cstdint>
#include <cstring>
#include <string>
#include <thread>
#include <vector>

#include <godot_cpp/classes/file_access.hpp>
#include <godot_cpp/classes/global_constants.hpp>
#include <godot_cpp/classes/project_settings.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include "ggml.h"
#include "whisper.h"

#ifndef WB_WHISPER_COMMIT
#define WB_WHISPER_COMMIT "unknown"
#endif
#ifndef WB_BRIDGE_VERSION
#define WB_BRIDGE_VERSION "1"
#endif

namespace godot {

namespace {

constexpr int kTargetRate = 16000;
// Same rule as the PC server: fewer than 1600 samples (0.1 s) or a peak below 0.003 is "no sound".
constexpr int kMinSamples = 1600;
const float kSilencePeak = 0.003f;
constexpr float kMaxSecondsLimit = 30.0f; // one whisper window; longer audio is cut

void drop_log(ggml_log_level, const char *, void *) {}

bool abort_cb(void *p_user) {
	return static_cast<std::atomic<bool> *>(p_user)->load();
}

bool encoder_begin_cb(whisper_context *, whisper_state *, void *p_user) {
	return !static_cast<std::atomic<bool> *>(p_user)->load();
}

uint16_t rd16(const uint8_t *p) { return (uint16_t)(p[0] | (p[1] << 8)); }
uint32_t rd32(const uint8_t *p) { return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24); }

struct WavInfo {
	int format = 0; // 1 = PCM, 3 = float
	int channels = 0;
	int rate = 0;
	int bits = 0;
	const uint8_t *data = nullptr;
	size_t data_bytes = 0;
};

// Strict RIFF/WAVE reader. A data chunk that claims more bytes than the file has (a cut-off file) is rejected;
// a data size of 0 or 0xFFFFFFFF (streamed WAV) means "to the end of the file".
bool parse_wav(const uint8_t *p, size_t n, WavInfo &w) {
	if (n < 44 || std::memcmp(p, "RIFF", 4) != 0 || std::memcmp(p + 8, "WAVE", 4) != 0) {
		return false;
	}
	size_t off = 12;
	bool have_fmt = false;
	while (off + 8 <= n) {
		const uint8_t *ck = p + off;
		uint32_t sz = rd32(ck + 4);
		size_t body = off + 8;
		size_t remain = n - body;
		if (std::memcmp(ck, "fmt ", 4) == 0) {
			if (sz < 16 || sz > remain) {
				return false;
			}
			w.format = rd16(p + body);
			w.channels = rd16(p + body + 2);
			w.rate = (int)rd32(p + body + 4);
			w.bits = rd16(p + body + 14);
			if (w.format == 0xFFFE) { // WAVE_FORMAT_EXTENSIBLE: real format in the sub-format GUID
				if (sz < 40) {
					return false;
				}
				w.format = rd16(p + body + 24);
			}
			have_fmt = true;
		} else if (std::memcmp(ck, "data", 4) == 0) {
			if (!have_fmt) {
				return false;
			}
			size_t len = sz;
			if (sz == 0 || sz == 0xFFFFFFFFu) {
				len = remain;
			} else if (sz > remain) {
				return false;
			}
			w.data = p + body;
			w.data_bytes = len;
			break;
		}
		if (sz > remain) {
			return false;
		}
		off = body + sz + (sz & 1u);
	}
	if (!have_fmt || w.data == nullptr) {
		return false;
	}
	bool fmt_ok = (w.format == 1 && w.bits == 16) || (w.format == 3 && w.bits == 32);
	if (!fmt_ok || w.channels < 1 || w.channels > 2 || w.rate < 8000 || w.rate > 48000) {
		return false;
	}
	return true;
}

// Mono float at the file's own sample rate.
std::vector<float> decode_mono(const WavInfo &w) {
	size_t bytes_per_sample = (size_t)w.bits / 8;
	size_t frame = bytes_per_sample * (size_t)w.channels;
	size_t frames = w.data_bytes / frame;
	std::vector<float> out(frames);
	for (size_t i = 0; i < frames; i++) {
		float acc = 0.0f;
		for (int c = 0; c < w.channels; c++) {
			const uint8_t *s = w.data + i * frame + (size_t)c * bytes_per_sample;
			if (w.format == 1) {
				acc += (float)(int16_t)rd16(s) / 32768.0f;
			} else {
				uint32_t u = rd32(s);
				float f;
				std::memcpy(&f, &u, 4);
				acc += std::isfinite(f) ? f : 0.0f;
			}
		}
		out[i] = acc / (float)w.channels;
	}
	return out;
}

// Windowed-sinc resampler to 16 kHz (low-pass at the lower of the two Nyquist rates). The input/output rate ratio is
// rational (num/den), so there are only `den` distinct fractional offsets: the kernel of each one is computed once.
std::vector<float> resample_16k(const std::vector<float> &in, int rate) {
	if (rate == kTargetRate || in.empty()) {
		return in;
	}
	const long long g = std::gcd((long long)rate, (long long)kTargetRate);
	const long long num = rate / g; // input samples per `den` output samples
	const long long den = kTargetRate / g;
	const double scale = std::min(1.0, (double)kTargetRate / (double)rate);
	const double half = 16.0 / scale; // kernel half width in input samples
	const int H = (int)std::ceil(half);
	const int taps = 2 * H + 2; // input offsets m = -H .. H+1 around floor(x)
	const double pi = 3.14159265358979323846;
	std::vector<float> table((size_t)den * (size_t)taps);
	for (long long ph = 0; ph < den; ph++) {
		const double frac = (double)ph / (double)den;
		double wsum = 0.0;
		float *row = &table[(size_t)ph * (size_t)taps];
		for (int t = 0; t < taps; t++) {
			double d = (double)(t - H) - frac; // distance from the output position, in input samples
			double k = 0.0;
			if (std::fabs(d) < half) {
				double a = d * scale;
				double sinc = (std::fabs(a) < 1e-9) ? 1.0 : std::sin(pi * a) / (pi * a);
				k = sinc * 0.5 * (1.0 + std::cos(pi * d / half)) * scale;
			}
			row[t] = (float)k;
			wsum += k;
		}
		if (wsum > 1e-9) {
			for (int t = 0; t < taps; t++) {
				row[t] = (float)((double)row[t] / wsum);
			}
		}
	}
	const size_t out_n = (size_t)((long long)in.size() * den / num);
	std::vector<float> out(out_n);
	const long long n_in = (long long)in.size();
	for (size_t i = 0; i < out_n; i++) {
		const long long pos = (long long)i * num;
		const long long base = pos / den;
		const float *row = &table[(size_t)(pos % den) * (size_t)taps];
		double acc = 0.0;
		for (int t = 0; t < taps; t++) {
			long long j = base + t - H;
			if (j >= 0 && j < n_in) {
				acc += (double)row[t] * (double)in[(size_t)j];
			}
		}
		out[i] = (float)acc;
	}
	return out;
}

float peak_of(const std::vector<float> &v) {
	float m = 0.0f;
	for (float s : v) {
		m = std::max(m, std::fabs(s));
	}
	return m;
}

// Frame-energy trim (20 ms frames). Returns the start offset (samples) that was removed from the front.
size_t trim_silence(std::vector<float> &v) {
	const size_t frame = kTargetRate / 50;
	if (v.size() < frame * 4) {
		return 0;
	}
	size_t nf = v.size() / frame;
	std::vector<float> rms(nf);
	float maxrms = 0.0f;
	for (size_t f = 0; f < nf; f++) {
		double e = 0.0;
		for (size_t i = 0; i < frame; i++) {
			float s = v[f * frame + i];
			e += (double)s * s;
		}
		rms[f] = (float)std::sqrt(e / (double)frame);
		maxrms = std::max(maxrms, rms[f]);
	}
	float thr = std::max(0.0005f, maxrms * 0.05f);
	size_t first = nf, last = 0;
	for (size_t f = 0; f < nf; f++) {
		if (rms[f] >= thr) {
			first = std::min(first, f);
			last = f;
		}
	}
	if (first >= nf) {
		return 0;
	}
	const size_t pad = (size_t)(0.25 * kTargetRate);
	size_t s = first * frame;
	size_t e = std::min(v.size(), (last + 1) * frame);
	s = s > pad ? s - pad : 0;
	e = std::min(v.size(), e + pad);
	if (s == 0 && e == v.size()) {
		return 0;
	}
	std::vector<float> cut(v.begin() + (long)s, v.begin() + (long)e);
	v.swap(cut);
	return s;
}

bool is_punct_only(const char *t) {
	bool any = false;
	for (const unsigned char *p = (const unsigned char *)t; *p; p++) {
		unsigned char c = *p;
		if (c == ' ') {
			continue;
		}
		if (std::isalnum(c) || c >= 0x80) {
			return false;
		}
		any = true;
	}
	return any;
}

struct Word {
	std::string w;
	double psum = 0.0;
	int pcount = 0;
	double pall = 0.0;
	int pall_count = 0;
	int64_t t0 = 0, t1 = 0; // centiseconds
	bool t_valid = false;
	size_t seg = 0;
};

Dictionary fail(const char *p_err, double p_duration = 0.0, int p_ms = 0, const String &p_model = String()) {
	Dictionary d;
	d["ok"] = false;
	d["error"] = String(p_err);
	d["text"] = String();
	d["duration"] = p_duration;
	d["ms"] = p_ms;
	d["model"] = p_model;
	d["words"] = Array();
	return d;
}

} // namespace

void WhisperBridge::_bind_methods() {
	ClassDB::bind_static_method("WhisperBridge", D_METHOD("version"), &WhisperBridge::version);
	ClassDB::bind_method(D_METHOD("load_model", "path", "threads"), &WhisperBridge::load_model, DEFVAL(0));
	ClassDB::bind_method(D_METHOD("is_loaded"), &WhisperBridge::is_loaded);
	ClassDB::bind_method(D_METHOD("model_file"), &WhisperBridge::model_file);
	ClassDB::bind_method(D_METHOD("unload"), &WhisperBridge::unload);
	ClassDB::bind_method(D_METHOD("transcribe", "wav", "lang", "options"), &WhisperBridge::transcribe, DEFVAL(Dictionary()));
	ClassDB::bind_method(D_METHOD("abort"), &WhisperBridge::abort);
}

WhisperBridge::WhisperBridge() {
	whisper_log_set(drop_log, nullptr);
	ggml_log_set(drop_log, nullptr);
}

WhisperBridge::~WhisperBridge() {
	abort_.store(true);
	std::lock_guard<std::mutex> lk(mutex_);
	if (ctx_) {
		whisper_free(ctx_);
		ctx_ = nullptr;
	}
	loaded_.store(false);
}

String WhisperBridge::version() {
	return String("bridge ") + String(WB_BRIDGE_VERSION) + String(" / whisper.cpp ") + String(WB_WHISPER_COMMIT);
}

int WhisperBridge::load_model(const String &p_path, int p_threads) {
	std::lock_guard<std::mutex> lk(mutex_);
	if (ctx_) {
		whisper_free(ctx_);
		ctx_ = nullptr;
		loaded_.store(false);
		model_file_ = String();
	}
	if (p_path.is_empty()) {
		return (int)ERR_INVALID_PARAMETER;
	}
	if (!FileAccess::file_exists(p_path)) {
		return (int)ERR_FILE_NOT_FOUND;
	}
	String real = p_path;
	if (real.begins_with("res://") || real.begins_with("user://")) {
		real = ProjectSettings::get_singleton()->globalize_path(real);
	}
	CharString u8 = real.utf8();
	// whisper_init prints through the (dropped) log callback; a missing/short/garbled file returns nullptr.
	whisper_context_params cp = whisper_context_default_params();
	cp.use_gpu = false;
	whisper_context *c = whisper_init_from_file_with_params(u8.get_data(), cp);
	if (!c) {
		return (int)ERR_FILE_CORRUPT;
	}
	ctx_ = c;
	int cores = (int)std::thread::hardware_concurrency();
	if (p_threads > 0) {
		threads_ = std::min(p_threads, 16);
	} else {
		threads_ = std::max(2, std::min(4, cores - 2));
	}
	model_file_ = real.get_file();
	loaded_.store(true);
	return (int)OK;
}

bool WhisperBridge::is_loaded() const {
	return loaded_.load();
}

String WhisperBridge::model_file() const {
	return model_file_;
}

void WhisperBridge::unload() {
	abort_.store(true); // let a running transcription stop, then free under the mutex
	std::lock_guard<std::mutex> lk(mutex_);
	if (ctx_) {
		whisper_free(ctx_);
		ctx_ = nullptr;
	}
	loaded_.store(false);
	model_file_ = String();
}

void WhisperBridge::abort() {
	abort_.store(true);
}

Dictionary WhisperBridge::transcribe(const PackedByteArray &p_wav, const String &p_lang, const Dictionary &p_options) {
	using clock = std::chrono::steady_clock;
	auto t_start = clock::now();
	auto elapsed_ms = [&]() { return (int)std::max<long long>(1, std::chrono::duration_cast<std::chrono::milliseconds>(clock::now() - t_start).count()); };

	if (p_lang != String("en")) {
		return fail("bad_lang", 0.0, elapsed_ms());
	}

	// Options (typed defensively: GDScript may pass ints for floats and so on).
	int beam = 1;
	float max_seconds = kMaxSecondsLimit;
	bool trim = true;
	bool token_ts = true;
	if (p_options.has("beam")) {
		beam = std::max(1, std::min(5, (int)(int64_t)p_options["beam"]));
	}
	if (p_options.has("max_seconds")) {
		max_seconds = std::max(0.5f, std::min(kMaxSecondsLimit, (float)(double)p_options["max_seconds"]));
	}
	if (p_options.has("trim")) {
		trim = (bool)p_options["trim"];
	}
	if (p_options.has("token_timestamps")) {
		token_ts = (bool)p_options["token_timestamps"];
	}

	// Decode before taking the mutex, so a bad file is reported even while another transcription runs.
	WavInfo wi;
	if (!parse_wav(p_wav.ptr(), (size_t)p_wav.size(), wi)) {
		return fail("bad_wav", 0.0, elapsed_ms());
	}
	std::vector<float> pcm = resample_16k(decode_mono(wi), wi.rate);
	double duration = (double)pcm.size() / (double)kTargetRate;

	std::lock_guard<std::mutex> lk(mutex_);
	abort_.store(false); // an abort() only ever applies to the transcription that is running
	if (!ctx_) {
		return fail("no_model", duration, elapsed_ms());
	}
	String model = model_file_;

	if ((int)pcm.size() < kMinSamples || peak_of(pcm) < kSilencePeak) {
		Dictionary d;
		d["ok"] = true;
		d["error"] = String();
		d["text"] = String();
		d["duration"] = duration;
		d["ms"] = elapsed_ms();
		d["model"] = model;
		d["words"] = Array();
		return d;
	}

	size_t max_samples = (size_t)((double)max_seconds * kTargetRate);
	if (pcm.size() > max_samples) {
		pcm.resize(max_samples);
	}
	size_t front_cut = trim ? trim_silence(pcm) : 0;
	const double time_offset = (double)front_cut / (double)kTargetRate;
	if (pcm.size() < (size_t)kTargetRate) { // whisper wants some audio around the speech
		pcm.resize((size_t)kTargetRate, 0.0f);
	}

	whisper_full_params fp = whisper_full_default_params(beam > 1 ? WHISPER_SAMPLING_BEAM_SEARCH : WHISPER_SAMPLING_GREEDY);
	fp.n_threads = threads_;
	fp.language = "en";
	fp.translate = false;
	fp.no_context = true;
	fp.single_segment = true;
	fp.print_special = false;
	fp.print_progress = false;
	fp.print_realtime = false;
	fp.print_timestamps = false;
	fp.suppress_blank = true;
	fp.temperature = 0.0f;
	fp.temperature_inc = 0.0f; // no re-decoding passes: predictable time
	fp.greedy.best_of = 1;
	fp.token_timestamps = token_ts;
	if (beam > 1) {
		fp.beam_search.beam_size = beam;
	}
	fp.abort_callback = abort_cb;
	fp.abort_callback_user_data = &abort_;
	fp.encoder_begin_callback = encoder_begin_cb;
	fp.encoder_begin_callback_user_data = &abort_;

	int rc = whisper_full(ctx_, fp, pcm.data(), (int)pcm.size());
	if (abort_.load()) {
		return fail("aborted", duration, elapsed_ms(), model);
	}
	if (rc != 0) {
		return fail("engine", duration, elapsed_ms(), model);
	}

	// Build words: a token that starts with a space opens a new word; special tokens are skipped; punctuation-only
	// tokens are glued to the previous word and left out of its probability.
	const whisper_token eot = whisper_token_eot(ctx_);
	std::vector<Word> words;
	std::string text;
	int nseg = whisper_full_n_segments(ctx_);
	std::vector<std::pair<int64_t, int64_t>> seg_times;
	for (int s = 0; s < nseg; s++) {
		seg_times.emplace_back(whisper_full_get_segment_t0(ctx_, s), whisper_full_get_segment_t1(ctx_, s));
		const char *st = whisper_full_get_segment_text(ctx_, s);
		if (st) {
			text += st;
		}
		int nt = whisper_full_n_tokens(ctx_, s);
		for (int t = 0; t < nt; t++) {
			whisper_token_data td = whisper_full_get_token_data(ctx_, s, t);
			if (td.id >= eot) {
				continue;
			}
			const char *tt = whisper_full_get_token_text(ctx_, s, t);
			if (!tt || !*tt) {
				continue;
			}
			bool punct = is_punct_only(tt);
			bool opens = (tt[0] == ' ') || words.empty() || words.back().seg != (size_t)s;
			if (punct && !words.empty() && words.back().seg == (size_t)s) {
				opens = false;
			}
			if (opens) {
				Word w;
				w.seg = (size_t)s;
				w.t0 = td.t0;
				w.t1 = td.t1;
				w.t_valid = token_ts;
				words.push_back(w);
			}
			Word &cur = words.back();
			const char *piece = tt;
			if (cur.w.empty() && piece[0] == ' ') {
				while (*piece == ' ') {
					piece++;
				}
			}
			cur.w += piece;
			cur.pall += td.p;
			cur.pall_count++;
			if (!punct) {
				cur.psum += td.p;
				cur.pcount++;
			}
			cur.t1 = td.t1; // end = last token's t1
		}
	}
	// Drop words that ended up empty (e.g. only whitespace).
	words.erase(std::remove_if(words.begin(), words.end(), [](const Word &w) { return w.w.empty(); }), words.end());

	// Segment-level fallback timing: when a segment has a word with t1 <= t0, spread the segment's span over its words
	// by character count.
	std::vector<double> starts(words.size()), ends(words.size());
	for (size_t i = 0; i < words.size(); i++) {
		starts[i] = (double)words[i].t0 * 0.01;
		ends[i] = (double)words[i].t1 * 0.01;
	}
	for (int s = 0; s < nseg; s++) {
		bool bad = !token_ts;
		size_t total_chars = 0;
		std::vector<size_t> idx;
		for (size_t i = 0; i < words.size(); i++) {
			if (words[i].seg != (size_t)s) {
				continue;
			}
			idx.push_back(i);
			total_chars += std::max<size_t>(1, words[i].w.size());
			if (!(words[i].t1 > words[i].t0)) {
				bad = true;
			}
		}
		if (!bad || idx.empty()) {
			continue;
		}
		double a = (double)seg_times[(size_t)s].first * 0.01;
		double b = (double)seg_times[(size_t)s].second * 0.01;
		if (!(b > a)) {
			a = 0.0;
			b = (double)pcm.size() / (double)kTargetRate;
		}
		double pos = a;
		for (size_t i : idx) {
			double len = (b - a) * (double)std::max<size_t>(1, words[i].w.size()) / (double)total_chars;
			starts[i] = pos;
			ends[i] = pos + len;
			pos += len;
		}
	}

	Array warr;
	double prev_start = 0.0;
	for (size_t i = 0; i < words.size(); i++) {
		double st = starts[i] + time_offset;
		double en = ends[i] + time_offset;
		if (st < prev_start) {
			st = prev_start;
		}
		if (!(en > st)) {
			en = st + 0.01;
		}
		prev_start = st;
		double p = words[i].pcount > 0 ? words[i].psum / words[i].pcount : (words[i].pall_count > 0 ? words[i].pall / words[i].pall_count : 0.0);
		p = std::max(0.0, std::min(1.0, p));
		Dictionary wd;
		wd["w"] = String::utf8(words[i].w.c_str());
		wd["p"] = p;
		wd["start"] = st;
		wd["end"] = en;
		warr.push_back(wd);
	}

	// trim leading/trailing spaces of the full text
	size_t b0 = text.find_first_not_of(' ');
	size_t b1 = text.find_last_not_of(' ');
	std::string clean = (b0 == std::string::npos) ? std::string() : text.substr(b0, b1 - b0 + 1);

	Dictionary d;
	d["ok"] = true;
	d["error"] = String();
	d["text"] = String::utf8(clean.c_str());
	d["duration"] = duration;
	d["ms"] = elapsed_ms();
	d["model"] = model;
	d["words"] = warr;
	return d;
}

} // namespace godot
