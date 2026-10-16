class_name WavUtil
extends RefCounted
## WAV helpers: AudioStreamWAV <-> RIFF bytes.


## Builds a canonical 44-byte-header RIFF/WAVE file from an AudioStreamWAV
## (8-bit or 16-bit PCM). Returns an empty array for unsupported formats.
static func to_wav_bytes(stream: AudioStreamWAV) -> PackedByteArray:
	var out := PackedByteArray()
	if stream == null:
		return out
	var bits: int
	match stream.format:
		AudioStreamWAV.FORMAT_8_BITS:
			bits = 8
		AudioStreamWAV.FORMAT_16_BITS:
			bits = 16
		_:
			return out
	var data: PackedByteArray = stream.data
	if bits == 8:
		# Godot stores 8-bit as signed, WAV files use unsigned.
		var conv := PackedByteArray()
		conv.resize(data.size())
		for i in data.size():
			conv[i] = (data[i] + 128) & 0xFF
		data = conv
	var channels: int = 2 if stream.stereo else 1
	var rate: int = stream.mix_rate
	var block_align: int = channels * (bits / 8)
	out.resize(44)
	out.encode_u32(0, 0x46464952) # "RIFF"
	out.encode_u32(4, 36 + data.size())
	out.encode_u32(8, 0x45564157) # "WAVE"
	out.encode_u32(12, 0x20746d66) # "fmt "
	out.encode_u32(16, 16)
	out.encode_u16(20, 1) # PCM
	out.encode_u16(22, channels)
	out.encode_u32(24, rate)
	out.encode_u32(28, rate * block_align)
	out.encode_u16(32, block_align)
	out.encode_u16(34, bits)
	out.encode_u32(36, 0x61746164) # "data"
	out.encode_u32(40, data.size())
	out.append_array(data)
	return out


## Parses WAV bytes into an AudioStreamWAV. Tries the built-in loader first and
## falls back to a manual RIFF parser (PCM 8/16-bit).
static func from_wav_bytes(bytes: PackedByteArray) -> AudioStreamWAV:
	if bytes.size() < 44:
		return null
	if ClassDB.class_has_method("AudioStreamWAV", "load_from_buffer"):
		var s: AudioStreamWAV = AudioStreamWAV.load_from_buffer(bytes)
		if s != null and s.data.size() > 0:
			return s
	return parse_manual(bytes)


static func parse_manual(bytes: PackedByteArray) -> AudioStreamWAV:
	if bytes.size() < 44 or bytes.decode_u32(0) != 0x46464952 or bytes.decode_u32(8) != 0x45564157:
		return null
	var pos := 12
	var channels := 1
	var rate := 24000
	var bits := 16
	var fmt_ok := false
	var data := PackedByteArray()
	while pos + 8 <= bytes.size():
		var id: int = bytes.decode_u32(pos)
		var sz: int = bytes.decode_u32(pos + 4)
		var body := pos + 8
		if id == 0x20746d66: # "fmt "
			var tag: int = bytes.decode_u16(body)
			channels = bytes.decode_u16(body + 2)
			rate = bytes.decode_u32(body + 4)
			bits = bytes.decode_u16(body + 14)
			fmt_ok = tag == 1 or tag == 0xFFFE
		elif id == 0x61746164: # "data"
			var end := mini(body + sz, bytes.size())
			data = bytes.slice(body, end)
			break
		pos = body + sz + (sz & 1)
	if not fmt_ok or data.is_empty() or (bits != 8 and bits != 16) or channels < 1 or channels > 2:
		return null
	var st := AudioStreamWAV.new()
	st.mix_rate = rate
	st.stereo = channels == 2
	if bits == 16:
		st.format = AudioStreamWAV.FORMAT_16_BITS
		st.data = data
	else:
		st.format = AudioStreamWAV.FORMAT_8_BITS
		var conv := PackedByteArray()
		conv.resize(data.size())
		for i in data.size():
			conv[i] = (data[i] - 128) & 0xFF
		st.data = conv
	return st


## Length in seconds of a stream.
static func duration(stream: AudioStreamWAV) -> float:
	if stream == null or stream.mix_rate <= 0:
		return 0.0
	var bytes_per_frame: int = (2 if stream.stereo else 1) * (2 if stream.format == AudioStreamWAV.FORMAT_16_BITS else 1)
	return float(stream.data.size()) / float(bytes_per_frame * stream.mix_rate)


## A silent stream, for tests.
static func silence(seconds: float, rate: int = 16000, stereo: bool = false) -> AudioStreamWAV:
	var st := AudioStreamWAV.new()
	st.format = AudioStreamWAV.FORMAT_16_BITS
	st.mix_rate = rate
	st.stereo = stereo
	var data := PackedByteArray()
	data.resize(int(seconds * rate) * 2 * (2 if stereo else 1))
	st.data = data
	return st


## Mono 16-bit copy of `stream` (stereo -> average of both channels, 8-bit -> 16-bit; the sample rate is kept).
## `max_seconds` > 0 cuts longer audio. Returns null for formats other than 8/16-bit PCM.
static func to_mono16(stream: AudioStreamWAV, max_seconds: float = 0.0) -> AudioStreamWAV:
	var r: Dictionary = mono16_with_peak(stream, max_seconds)
	return r.get("stream", null)


## {stream: AudioStreamWAV (mono 16-bit), peak: float 0..1}. Safe to run in a worker thread (no scene access).
static func mono16_with_peak(stream: AudioStreamWAV, max_seconds: float = 0.0) -> Dictionary:
	var out := {"stream": null, "peak": 0.0}
	if stream == null or stream.mix_rate <= 0:
		return out
	var bits16: bool = stream.format == AudioStreamWAV.FORMAT_16_BITS
	if not bits16 and stream.format != AudioStreamWAV.FORMAT_8_BITS:
		return out
	var ch: int = 2 if stream.stereo else 1
	var bps: int = 2 if bits16 else 1
	var src: PackedByteArray = stream.data
	var frames: int = src.size() / (ch * bps)
	if max_seconds > 0.0:
		frames = mini(frames, int(max_seconds * float(stream.mix_rate)))
	var dst := PackedByteArray()
	dst.resize(frames * 2)
	var peak := 0
	if bits16 and ch == 1:
		# already the right shape: copy and scan for the peak
		dst = src.slice(0, frames * 2)
		for i in frames:
			var v: int = absi(dst.decode_s16(i * 2))
			if v > peak:
				peak = v
	elif bits16:
		for i in frames:
			var m: int = (src.decode_s16(i * 4) + src.decode_s16(i * 4 + 2)) >> 1
			dst.encode_s16(i * 2, m)
			var a: int = absi(m)
			if a > peak:
				peak = a
	else:
		for i in frames:
			var s: int
			if ch == 1:
				s = src.decode_s8(i) << 8
			else:
				s = (src.decode_s8(i * 2) + src.decode_s8(i * 2 + 1)) << 7
			dst.encode_s16(i * 2, s)
			var a2: int = absi(s)
			if a2 > peak:
				peak = a2
	var st := AudioStreamWAV.new()
	st.format = AudioStreamWAV.FORMAT_16_BITS
	st.mix_rate = stream.mix_rate
	st.stereo = false
	st.data = dst
	out["stream"] = st
	out["peak"] = float(peak) / 32767.0
	return out


## Largest absolute sample of an 8/16-bit stream, 0..1.
static func peak(stream: AudioStreamWAV) -> float:
	if stream == null:
		return 0.0
	var best := 0
	if stream.format == AudioStreamWAV.FORMAT_16_BITS:
		var n: int = stream.data.size() / 2
		for i in n:
			var v: int = absi(stream.data.decode_s16(i * 2))
			if v > best:
				best = v
		return float(best) / 32767.0
	if stream.format == AudioStreamWAV.FORMAT_8_BITS:
		for i in stream.data.size():
			var v8: int = absi(stream.data.decode_s8(i))
			if v8 > best:
				best = v8
		return float(best) / 127.0
	return 0.0


## Synthetic sine, for tests. `stereo` puts `right_gain` of the tone into the right channel.
static func sine(seconds: float, rate: int = 48000, freq: float = 440.0, amp: float = 0.5, stereo: bool = false, right_gain: float = 1.0) -> AudioStreamWAV:
	var n: int = int(seconds * rate)
	var st := AudioStreamWAV.new()
	st.format = AudioStreamWAV.FORMAT_16_BITS
	st.mix_rate = rate
	st.stereo = stereo
	var data := PackedByteArray()
	var ch: int = 2 if stereo else 1
	data.resize(n * ch * 2)
	for i in n:
		var v: int = int(sin(TAU * freq * float(i) / float(rate)) * amp * 32767.0)
		if stereo:
			data.encode_s16(i * 4, v)
			data.encode_s16(i * 4 + 2, int(float(v) * right_gain))
		else:
			data.encode_s16(i * 2, v)
	st.data = data
	return st
