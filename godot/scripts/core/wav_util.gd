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
