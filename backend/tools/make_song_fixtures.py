# -*- coding: utf-8 -*-
"""Synthetic test songs for the song-study feature (task K6).

No real song, lyrics or recording is used. The lyrics are short sentences written by hand (CC0), see
godot/tests/fixtures/song/lyrics_en.txt and lyrics_ja.txt. Each lyric line is synthesized with Kokoro through a
running backend (POST /tts), the lines are placed one after another with random gaps (0.4..1.5 s) on a timeline
(so the true start/end of every line is known exactly), an instrumental backing track is computed from formulas
(4-chord pad + bass + noise percussion, tempo 90), the two are mixed at SNR inf / +10 / +5 / 0 dB and encoded as
wav, mp3, m4a, flac, ogg. A "<id>.truth.json" file with the true line times is written next to the result.

  Start a test server first (any free port 18791..18799), then:
      backend\\.venv\\Scripts\\python.exe -I backend\\tools\\make_song_fixtures.py --server http://127.0.0.1:18793 --out <dir>
  Options:  --langs en,ja  --snr inf,10,5,0  --formats wav,mp3,m4a,flac,ogg  --long 240 (4-minute version, mp3)
            --fixture-dir DIR  (also copy the small committed files: truth json + tone_8s.mp3 + tone_8s.json)
            --tone-only        (only the tiny pure-tone mp3, no server needed)
            --selftest         (checks the checkers themselves with deliberately wrong input, no server needed)

Exit codes: 0 ok, 2 server/TTS problem (nothing is written), 3 self-check failed, 1 other error.
"""
import argparse
import json
import math
import os
import random
import sys
import urllib.error
import urllib.request
from io import BytesIO

HERE = os.path.dirname(os.path.abspath(__file__))
FIXTURE_DIR = os.path.normpath(os.path.join(HERE, "..", "..", "godot", "tests", "fixtures", "song"))
SR = 44100              # master sample rate of every generated file
TEMPO = 90
VOICES = {"en": "af_heart", "ja": "jf_alpha"}
TRIM_REL_DB = -40.0     # speech edges = first/last 10 ms frame above (peak - 40 dB) of the line
FRAME = 0.01
EDGE_TOL = 0.05         # K6-2: line start/end vs. detected speech edge
DUR_TOL = 0.10
SNR_TOL = 0.5
GAP_MIN, GAP_MAX = 0.4, 1.5
INTRO_RANGE = (1.2, 2.2)
OUTRO = 1.5
FORMATS_ALL = ["wav", "mp3", "m4a", "flac", "ogg"]


class Fail(Exception):
    def __init__(self, msg, code=1):
        Exception.__init__(self, msg)
        self.code = code


def say(msg):
    print(msg, flush=True)


def err(ko, en):
    print("오류: %s\nERROR: %s" % (ko, en), file=sys.stderr, flush=True)


# ------------------------------------------------------------------------------------------------
# lyrics
# ------------------------------------------------------------------------------------------------
def parse_lyrics(path):
    """-> [{"text", "p"}], p = stanza number (blank line starts a new stanza, '#' lines are comments)"""
    out, p, pending_break = [], 0, False
    with open(path, "r", encoding="utf-8") as f:
        for raw in f.read().splitlines():
            s = raw.strip()
            if s.startswith("#"):
                continue
            if not s:
                pending_break = bool(out)
                continue
            if pending_break:
                p += 1
                pending_break = False
            out.append({"text": s, "p": p})
    return out


# ------------------------------------------------------------------------------------------------
# TTS client (urllib only)
# ------------------------------------------------------------------------------------------------
def http_json(url, body=None, timeout=10):
    data = None
    headers = {}
    if body is not None:
        data = json.dumps(body, ensure_ascii=False).encode("utf-8")
        headers["Content-Type"] = "application/json; charset=utf-8"
    req = urllib.request.Request(url, data=data, headers=headers)
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read()


def check_server(base, langs):
    try:
        h = json.loads(http_json(base.rstrip("/") + "/health", timeout=5).decode("utf-8"))
    except Exception as e:
        raise Fail("TTS 서버에 연결할 수 없어요 (%s). 먼저 backend\\server.py --port <포트> 로 시험 서버를 띄우세요. (%s)\n"
                   "Cannot reach the TTS test server at %s. Start backend\\server.py with --port first. (%s)"
                   % (base, type(e).__name__, base, e), 2)
    if not isinstance(h, dict) or not h.get("ok"):
        raise Fail("서버가 정상이 아니에요 (/health). / Server /health is not ok.", 2)


def synth(base, text, lang, voice):
    import numpy as np
    import soundfile as sf
    try:
        raw = http_json(base.rstrip("/") + "/tts", {"text": text, "lang": lang, "speed": 1.0, "voice": voice}, timeout=240)
    except urllib.error.HTTPError as e:
        raise Fail("TTS 합성 실패 (HTTP %s, lang=%s). / TTS synthesis failed: HTTP %s for %r" % (e.code, lang, e.code, text[:30]), 2)
    except Exception as e:
        raise Fail("TTS 서버 응답 오류 (%s). / TTS request failed: %s" % (type(e).__name__, e), 2)
    try:
        x, sr = sf.read(BytesIO(raw), dtype="float32", always_2d=False)
    except Exception as e:
        raise Fail("TTS가 WAV가 아닌 응답을 줬어요. / TTS did not return a WAV: %s" % e, 2)
    if x.ndim > 1:
        x = x.mean(axis=1)
    x = np.asarray(x, dtype=np.float32)
    if len(x) < sr * 0.2 or float(np.sqrt(np.mean(x ** 2))) < 1e-4:
        raise Fail("TTS 결과가 비었거나 무음이에요. / TTS returned empty or silent audio for %r" % text[:30], 2)
    return x, sr


# ------------------------------------------------------------------------------------------------
# DSP helpers
# ------------------------------------------------------------------------------------------------
def frame_env(x, sr, hop=FRAME):
    import numpy as np
    n = max(1, int(round(sr * hop)))
    m = len(x) // n
    if m == 0:
        return np.zeros(1)
    return np.sqrt((x[:m * n].reshape(m, n).astype(np.float64) ** 2).mean(axis=1))


def speech_edges(x, sr, lo=0.0, hi=None, rel_db=TRIM_REL_DB):
    """(first, last) time in seconds of the frames above peak+rel_db inside [lo, hi]; None if silent"""
    import numpy as np
    env = frame_env(x, sr)
    a = max(0, int(lo / FRAME))
    b = len(env) if hi is None else min(len(env), int(hi / FRAME) + 1)
    seg = env[a:b]
    if len(seg) == 0 or seg.max() <= 1e-6:
        return None
    idx = np.nonzero(seg > seg.max() * 10 ** (rel_db / 20.0))[0]
    return (a + idx[0]) * FRAME, (a + idx[-1] + 1) * FRAME


def trim_voice(x, sr, pad=0.01):
    import numpy as np
    e = speech_edges(x, sr)
    if e is None:
        raise Fail("합성 음성에서 말소리를 찾지 못했어요. / No speech found in a synthesized line.", 2)
    a = max(0, int((e[0] - pad) * sr))
    b = min(len(x), int((e[1] + pad) * sr))
    return x[a:b].copy()


def resample(x, sr_in, sr_out):
    from math import gcd
    from scipy.signal import resample_poly
    import numpy as np
    if sr_in == sr_out:
        return x.astype(np.float32)
    g = gcd(sr_in, sr_out)
    return resample_poly(x, sr_out // g, sr_in // g).astype(np.float32)


def rms(x):
    import numpy as np
    return float(np.sqrt(np.mean(np.square(x, dtype=np.float64)))) if len(x) else 0.0


def midi_hz(n):
    return 440.0 * 2.0 ** ((n - 69) / 12.0)


CHORDS = [  # C  Am  F  G, one bar each: (bass, [pad notes])
    (36, [60, 64, 67]),
    (33, [57, 60, 64]),
    (29, [53, 57, 60]),
    (31, [55, 59, 62]),
]


def make_backing(n, sr, seed):
    """instrumental backing track from formulas: chord pad + bass + noise percussion (tempo 90). float32, peak ~0.5"""
    import numpy as np
    rng = np.random.default_rng(seed)
    out = np.zeros(n, dtype=np.float64)
    beat = int(round(sr * 60.0 / TEMPO))
    bar = beat * 4
    nbars = n // bar + 1
    two_pi = 2 * math.pi
    for b in range(nbars):
        s0 = b * bar
        if s0 >= n:
            break
        ln = min(bar, n - s0)
        t = np.arange(bar) / sr
        bass, notes = CHORDS[b % 4]
        # pad: 3 notes x 3 harmonics, slightly detuned pairs for width, smooth edges so bars join without clicks
        pad = np.zeros(bar)
        for nt in notes:
            f = midi_hz(nt)
            for k, w in ((1, 1.0), (2, 0.4), (3, 0.2)):
                for det in (0.997, 1.003):
                    pad += w * np.sin(two_pi * f * k * det * t + rng.uniform(0, two_pi))
        pad *= 0.05
        edge = int(0.12 * sr)
        env = np.ones(bar)
        env[:edge] = 0.5 - 0.5 * np.cos(np.linspace(0, math.pi, edge))
        env[-edge:] = 0.5 + 0.5 * np.cos(np.linspace(0, math.pi, edge))
        bar_sig = pad * env
        # bass on beats 1 and 3
        for bt in (0, 2):
            i0 = bt * beat
            m = min(beat * 2, bar - i0)
            tt = np.arange(m) / sr
            bar_sig[i0:i0 + m] += 0.30 * np.sin(two_pi * midi_hz(bass) * tt) * np.exp(-tt * 2.5)
        # kick on 1 and 3: falling sine
        for bt in (0, 2):
            i0 = bt * beat
            m = min(int(0.25 * sr), bar - i0)
            tt = np.arange(m) / sr
            ph = two_pi * (50 * tt + 70 * (1 - np.exp(-tt * 30)) / 30)
            bar_sig[i0:i0 + m] += 0.55 * np.sin(ph) * np.exp(-tt * 18)
        # snare on 2 and 4: noise burst
        for bt in (1, 3):
            i0 = bt * beat
            m = min(int(0.18 * sr), bar - i0)
            tt = np.arange(m) / sr
            bar_sig[i0:i0 + m] += 0.30 * rng.standard_normal(m) * np.exp(-tt * 28)
        # hi-hat on eighth notes: high-passed noise
        for e8 in range(8):
            i0 = e8 * (beat // 2)
            m = min(int(0.05 * sr), bar - i0)
            tt = np.arange(m) / sr
            nz = np.diff(rng.standard_normal(m + 1))
            bar_sig[i0:i0 + m] += 0.10 * nz * np.exp(-tt * 90)
        out[s0:s0 + ln] += bar_sig[:ln]
    out = out.astype(np.float32)
    pk = float(np.max(np.abs(out)))
    if pk > 0:
        out *= 0.5 / pk
    return out


# ------------------------------------------------------------------------------------------------
# timeline
# ------------------------------------------------------------------------------------------------
def build_voice(lines, clips, sr, rng, target_seconds=0.0):
    """-> (voice float32, [{i, base_i, repeat, text, p, t0, t1}], duration). clips[k] is the trimmed speech of lines[k].
    A sample-exact timeline: t0/t1 are exactly where the clip was placed."""
    import numpy as np
    intro = round(rng.uniform(*INTRO_RANGE), 2)
    cur = int(intro * sr)
    placed = []
    chunks = []
    rep, i, stop = 0, 0, False
    while not stop:
        for k in range(len(lines)):
            c = clips[k]
            gap = int(round(rng.uniform(GAP_MIN, GAP_MAX) * sr)) if i > 0 else 0
            # long mode: whole repeats only, stop before the target length is exceeded
            if target_seconds > 0 and k == 0 and rep > 0 and (cur + gap) / sr + sum(len(x) for x in clips) / sr + OUTRO > target_seconds:
                stop = True
                break
            cur += gap
            chunks.append((cur, k, rep))
            cur += len(c)
            i += 1
        rep += 1
        if target_seconds <= 0:
            break
    total = cur + int(OUTRO * sr)
    voice = np.zeros(total, dtype=np.float32)
    for i, (s, k, rp) in enumerate(chunks):
        c = clips[k]
        voice[s:s + len(c)] += c
        placed.append({"i": i, "base_i": k, "repeat": rp, "text": lines[k]["text"], "p": lines[k]["p"],
                       "t0": round(s / sr, 4), "t1": round((s + len(c)) / sr, 4)})
    return voice, placed, total / sr


def active_mask(placed, n, sr):
    import numpy as np
    m = np.zeros(n, dtype=bool)
    for ln in placed:
        m[int(round(ln["t0"] * sr)):int(round(ln["t1"] * sr))] = True
    return m


def mix_at_snr(voice, backing, active, snr_db):
    """-> (mixed float32 with peak <= 0.95, scale). snr_db = None means voice only."""
    import numpy as np
    if snr_db is None:
        mixed = voice.astype(np.float64)
    else:
        rv = rms(voice[active])
        rb = rms(backing[active])
        g = rv / (rb * 10 ** (snr_db / 20.0))
        mixed = voice.astype(np.float64) + g * backing.astype(np.float64)
    pk = float(np.max(np.abs(mixed)))
    scale = 0.95 / pk if pk > 0.95 else 1.0
    return (mixed * scale).astype(np.float32), scale


def to_int16(x):
    import numpy as np
    return np.clip(np.round(x * 32767.0), -32768, 32767).astype(np.int16)


# ------------------------------------------------------------------------------------------------
# encoding / decoding
# ------------------------------------------------------------------------------------------------
def encode_av(path, pcm16, sr, codec, container=None, bitrate=None, options=None):
    import av
    with av.open(path, "w", format=container) as c:
        st = c.add_stream(codec, rate=sr, layout="mono")
        if bitrate:
            st.bit_rate = bitrate
        if options:
            st.codec_context.options = options
        rs = av.AudioResampler(format=st.format.name, layout="mono", rate=sr, frame_size=st.frame_size or None)
        step = sr  # feed 1 s at a time
        for a in range(0, len(pcm16), step):
            fr = av.AudioFrame.from_ndarray(pcm16[a:a + step].reshape(1, -1), format="s16", layout="mono")
            fr.sample_rate = sr
            for f2 in rs.resample(fr):
                for p in st.encode(f2):
                    c.mux(p)
        for f2 in rs.resample(None):
            for p in st.encode(f2):
                c.mux(p)
        for p in st.encode(None):
            c.mux(p)


def write_audio(path, pcm16, sr, fmt):
    import soundfile as sf
    if fmt == "wav":
        sf.write(path, pcm16, sr, subtype="PCM_16", format="WAV")
    elif fmt == "flac":
        encode_av(path, pcm16, sr, "flac", container="flac")
    elif fmt == "mp3":
        encode_av(path, pcm16, sr, "libmp3lame", container="mp3", bitrate=128000)
    elif fmt == "m4a":
        encode_av(path, pcm16, sr, "aac", container="ipod", bitrate=128000)
    elif fmt == "ogg":
        # libsndfile's built-in Vorbis encoder; one big write() overflows its stack on Windows, so write in blocks
        with sf.SoundFile(path, "w", samplerate=sr, channels=1, subtype="VORBIS", format="OGG") as f:
            for a in range(0, len(pcm16), 4096):
                f.write(pcm16[a:a + 4096])
    else:
        raise Fail("unknown format " + fmt)


def decode_audio(path):
    """-> (float32 mono, sample_rate) via av"""
    import av
    import numpy as np
    parts = []
    with av.open(path) as c:
        st = c.streams.audio[0]
        sr = st.rate
        rs = av.AudioResampler(format="flt", layout="mono", rate=sr)
        for fr in c.decode(st):
            for f2 in rs.resample(fr):
                parts.append(f2.to_ndarray().reshape(-1))
        for f2 in rs.resample(None):
            parts.append(f2.to_ndarray().reshape(-1))
    return (np.concatenate(parts).astype(np.float32) if parts else np.zeros(0, np.float32)), sr


# ------------------------------------------------------------------------------------------------
# checkers (K6-2, K6-3). They return a list of problem strings (empty = OK) and a stats dict.
# ------------------------------------------------------------------------------------------------
def check_timing(x, sr, truth, edge_tol=EDGE_TOL, dur_tol=DUR_TOL):
    probs, worst = [], 0.0
    dur = len(x) / sr
    if abs(dur - truth["duration"]) > dur_tol:
        probs.append("duration %.3f != truth %.3f (tol %.2f)" % (dur, truth["duration"], dur_tol))
    for ln in truth["lines"]:
        e = speech_edges(x, sr, ln["t0"] - 0.25, ln["t1"] + 0.25)
        if e is None:
            probs.append("line %d: no speech found near %.2f..%.2f" % (ln["i"], ln["t0"], ln["t1"]))
            continue
        d0, d1 = abs(e[0] - ln["t0"]), abs(e[1] - ln["t1"])
        worst = max(worst, d0, d1)
        if d0 > edge_tol:
            probs.append("line %d: start %.3f vs speech %.3f (diff %.3f > %.2f)" % (ln["i"], ln["t0"], e[0], d0, edge_tol))
        if d1 > edge_tol:
            probs.append("line %d: end %.3f vs speech %.3f (diff %.3f > %.2f)" % (ln["i"], ln["t1"], e[1], d1, edge_tol))
    return probs, {"duration": dur, "worst_edge_err": worst}


def check_silent_gaps(x, sr, truth, max_db=-60.0):
    """lossless clean file only: between lines (±0.05 s) there must be silence"""
    import numpy as np
    probs = []
    lines = truth["lines"]
    for a, b in zip(lines[:-1], lines[1:]):
        s, e = int((a["t1"] + 0.05) * sr), int((b["t0"] - 0.05) * sr)
        if e > s and rms(x[s:e]) > 10 ** (max_db / 20.0):
            probs.append("gap after line %d is not silent (rms %.5f)" % (a["i"], rms(x[s:e])))
    return probs


def check_snr(mixed_file_pcm16, voice_ref, active, snr_db, tol=SNR_TOL):
    """mixed_file_pcm16: samples read back from the written lossless file (int16 or float). voice_ref: the voice stem
    scaled exactly like the file. Returns (problems, measured_db)."""
    import numpy as np
    x = mixed_file_pcm16.astype(np.float64)
    if x.dtype.kind == "i" or np.abs(x).max() > 2.0:
        x = x / 32768.0
    n = min(len(x), len(voice_ref))
    resid = x[:n] - voice_ref[:n].astype(np.float64)
    rv = rms(voice_ref[:n][active[:n]])
    rr = rms(resid[active[:n]])
    measured = 20 * math.log10(rv / max(rr, 1e-12))
    if snr_db is None:
        return ([] if measured > 60.0 else ["voice-only file is not clean (residual SNR %.1f dB)" % measured]), measured
    if abs(measured - snr_db) > tol:
        return ["SNR %.2f dB measured vs %.2f requested (tol %.1f)" % (measured, snr_db, tol)], measured
    return [], measured


def snr_label(s):
    return "inf" if s is None else ("%g" % s)


# ------------------------------------------------------------------------------------------------
# tone fixture (tiny, committed)
# ------------------------------------------------------------------------------------------------
TONE_NOTES = [261.63, 293.66, 329.63, 349.23, 392.00, 440.00, 493.88, 523.25]   # C4..C5, 1 s each


def make_tone(out_dir):
    import numpy as np
    sr = 22050
    t = np.arange(sr * len(TONE_NOTES)) / sr
    x = np.zeros_like(t)
    notes = []
    for k, f in enumerate(TONE_NOTES):
        a, b = k * sr, (k + 1) * sr
        seg = np.sin(2 * math.pi * f * t[a:b])
        fade = int(0.02 * sr)
        seg[:fade] *= np.linspace(0, 1, fade)
        seg[-fade:] *= np.linspace(1, 0, fade)
        x[a:b] = seg
        notes.append({"t0": float(k), "t1": float(k + 1), "hz": f})
    pcm = to_int16(0.3 * x)
    os.makedirs(out_dir, exist_ok=True)
    path = os.path.join(out_dir, "tone_8s.mp3")
    encode_av(path, pcm, sr, "libmp3lame", container="mp3", bitrate=32000)
    y, ysr = decode_audio(path)
    meta = {"note": "pure sine tone, generated by backend/tools/make_song_fixtures.py (CC0); 1 s per note, C4..C5",
            "duration": float(len(TONE_NOTES)), "decoded_duration": round(len(y) / ysr, 4), "sample_rate": sr,
            "channels": 1, "bitrate": 32000, "bytes": os.path.getsize(path), "notes": notes}
    with open(os.path.join(out_dir, "tone_8s.json"), "w", encoding="utf-8", newline="\n") as f:
        json.dump(meta, f, ensure_ascii=False, indent=1)
        f.write("\n")
    return path, meta


# ------------------------------------------------------------------------------------------------
# main generation
# ------------------------------------------------------------------------------------------------
def generate(args):
    import numpy as np
    langs = [s for s in args.langs.split(",") if s]
    snrs = [None if s.strip().lower() == "inf" else float(s) for s in args.snr.split(",") if s.strip()]
    fmts = [s.strip() for s in args.formats.split(",") if s.strip()]
    for f in fmts:
        if f not in FORMATS_ALL:
            raise Fail("unknown format " + f)
    long_fmts = [s.strip() for s in args.long_formats.split(",") if s.strip()]
    lyr_dir = args.lyrics_dir
    lyrics = {}
    for lg in langs:
        p = os.path.join(lyr_dir, "lyrics_%s.txt" % lg)
        if not os.path.isfile(p):
            raise Fail("가사 파일이 없어요: %s / lyrics file missing: %s" % (p, p))
        lyrics[lg] = parse_lyrics(p)

    # 1) all synthesis first: if the server is missing nothing has been written yet (K6-4)
    check_server(args.server, langs)
    clips = {}
    for lg in langs:
        voice = args.voice.get(lg) or VOICES[lg]
        cl = []
        for ln in lyrics[lg]:
            x, sr0 = synth(args.server, ln["text"], lg, voice)
            x = trim_voice(x, sr0)
            x = resample(x, sr0, SR)
            cl.append(x)
            say("  tts %s %-44s %.2f s" % (lg, ln["text"][:44], len(x) / SR))
        clips[lg] = cl

    out = args.out
    os.makedirs(out, exist_ok=True)
    manifest, problems = [], []
    total_bytes = 0
    jobs = [(lg, 0.0) for lg in langs]
    if args.long > 0:
        jobs += [(lg, float(args.long)) for lg in langs]
    for lg, long_s in jobs:
        sid = "song_%s%s" % (lg, "_long" if long_s else "")
        rng = random.Random("%s:%s" % (args.seed, sid))
        cl = clips[lg]
        # normalize voice level: active RMS -> 0.1 (about -20 dBFS)
        voice, placed, dur = build_voice(lyrics[lg], cl, SR, rng, long_s)
        active = active_mask(placed, len(voice), SR)
        voice = voice * (0.1 / max(rms(voice[active]), 1e-9))
        backing = make_backing(len(voice), SR, int(args.seed) * 1000 + (1 if lg == "en" else 2))
        truth = {"schema": 1, "id": sid, "lang": lg, "voice": args.voice.get(lg) or VOICES[lg], "tempo": TEMPO,
                 "sample_rate": SR, "duration": round(len(voice) / SR, 4), "lyrics_file": "lyrics_%s.txt" % lg,
                 "intro": placed[0]["t0"], "snr_db": [snr_label(s) for s in snrs], "lines": placed,
                 "note": "t0/t1 are sample-exact positions where each synthesized line was placed (speech edges, "
                         "+-0.01 s pad). Regenerating may move times slightly if Kokoro output differs."}
        tp = os.path.join(out, sid + ".truth.json")
        with open(tp, "w", encoding="utf-8", newline="\n") as f:
            json.dump(truth, f, ensure_ascii=False, indent=1)
            f.write("\n")
        say("%s: %d lines, duration %.2f s" % (sid, len(placed), truth["duration"]))
        use_fmts = long_fmts if long_s else fmts
        for snr in snrs:
            mixed, scale = mix_at_snr(voice, backing, active, snr)
            voice_ref = voice * scale
            pcm = to_int16(mixed)
            for fmt in use_fmts:
                name = "%s_snr%s.%s" % (sid, snr_label(snr), fmt)
                path = os.path.join(out, name)
                write_audio(path, pcm, SR, fmt)
                sz = os.path.getsize(path)
                total_bytes += sz
                x, dsr = decode_audio(path)
                if snr is None:     # speech edges are only detectable without the backing track
                    tprobs, tst = check_timing(x, dsr, truth)
                else:               # mixed files: same timeline, so check the length only
                    tprobs, tst = check_timing(x, dsr, {"duration": truth["duration"], "lines": []})
                note = ""
                sprobs, measured = [], None
                if fmt in ("wav", "flac"):
                    sprobs, measured = check_snr(x, voice_ref, active, snr)
                    note = "snr %.2f dB" % measured
                if snr is None and fmt == "wav":
                    tprobs += check_silent_gaps(x, dsr, truth)
                status = "OK " if not (tprobs or sprobs) else "FAIL"
                say("  %s %-28s %8.0f KB  dur %.3f  edge-err %.3f s  %s" % (status, name, sz / 1024.0, tst["duration"], tst["worst_edge_err"], note))
                for p in tprobs + sprobs:
                    problems.append("%s: %s" % (name, p))
                manifest.append({"file": name, "id": sid, "lang": lg, "format": fmt, "snr_db": snr_label(snr),
                                 "bytes": sz, "duration": round(tst["duration"], 4), "worst_edge_err": round(tst["worst_edge_err"], 4),
                                 "snr_measured": None if measured is None else round(measured, 3), "ok": not (tprobs or sprobs)})
    with open(os.path.join(out, "manifest.json"), "w", encoding="utf-8", newline="\n") as f:
        json.dump({"files": manifest, "total_bytes": total_bytes}, f, ensure_ascii=False, indent=1)
    say("total audio %.1f MB in %d files (%s)" % (total_bytes / 1048576.0, len(manifest), out))
    return problems


def selftest():
    """The checkers must fail on deliberately wrong input. No server, no models."""
    import numpy as np
    import copy
    sr = SR
    # a fake 'voice': three tone bursts with silence between
    n = int(8 * sr)
    voice = np.zeros(n, np.float32)
    spans = [(1.0, 2.5), (3.2, 4.4), (5.3, 6.9)]
    t = np.arange(n) / sr
    for a, b in spans:
        i, j = int(a * sr), int(b * sr)
        voice[i:j] = 0.2 * np.sin(2 * math.pi * 300 * t[i:j]) * (0.6 + 0.4 * np.sin(2 * math.pi * 4 * t[i:j]))
    placed = [{"i": k, "text": "x", "p": 0, "t0": a, "t1": b} for k, (a, b) in enumerate(spans)]
    truth = {"duration": n / sr, "lines": placed}
    active = active_mask(placed, n, sr)
    backing = make_backing(n, sr, 1)
    ok = True

    def expect(name, probs, want_fail):
        nonlocal ok
        good = (len(probs) > 0) == want_fail
        ok = ok and good
        say("  selftest %-46s %s%s" % (name, "PASS" if good else "BAD ", "" if good else "  <- checker gave: %s" % probs[:2]))

    for snr in (10.0, 5.0, 0.0):
        mixed, sc = mix_at_snr(voice, backing, active, snr)
        pcm = to_int16(mixed)
        p, m = check_snr(pcm, voice * sc, active, snr)
        expect("snr %g correct" % snr, p, False)
        p, m = check_snr(pcm, voice * sc, active, snr + 1.5)
        expect("snr %g file vs requested %g" % (snr, snr + 1.5), p, True)
    mixed, sc = mix_at_snr(voice, backing, active, None)
    p, m = check_snr(to_int16(mixed), voice * sc, active, None)
    expect("voice-only clean", p, False)
    mixed5, sc5 = mix_at_snr(voice, backing, active, 5.0)
    p, m = check_snr(to_int16(mixed5), voice * sc5, active, None)
    expect("noisy file claimed as clean", p, True)
    p, st = check_timing(voice, sr, truth)
    expect("timing correct", p, False)
    bad = copy.deepcopy(truth)
    bad["lines"][1]["t0"] += 0.2
    p, st = check_timing(voice, sr, bad)
    expect("timing: line start shifted by 0.2 s", p, True)
    bad = copy.deepcopy(truth)
    bad["lines"][2]["t1"] -= 0.3
    p, st = check_timing(voice, sr, bad)
    expect("timing: line end shifted by 0.3 s", p, True)
    bad = copy.deepcopy(truth)
    bad["duration"] += 0.5
    p, st = check_timing(voice, sr, bad)
    expect("duration off by 0.5 s", p, True)
    p, st = check_timing(np.zeros(n, np.float32), sr, truth)
    expect("silent file", p, True)
    p = check_silent_gaps(voice + 0.01 * np.random.default_rng(0).standard_normal(n).astype(np.float32), sr, truth)
    expect("noise in the gaps", p, True)
    p = check_silent_gaps(voice, sr, truth)
    expect("clean gaps", p, False)
    return ok


def main():
    ap = argparse.ArgumentParser(description="synthetic test songs (K6)")
    ap.add_argument("--server", default="http://127.0.0.1:18793")
    ap.add_argument("--out", default=os.path.join(FIXTURE_DIR, "_gen"))
    ap.add_argument("--fixture-dir", default="", help="also write the small committed files here (truth json, tone_8s.*)")
    ap.add_argument("--lyrics-dir", default=FIXTURE_DIR)
    ap.add_argument("--langs", default="en,ja")
    ap.add_argument("--snr", default="inf,10,5,0")
    ap.add_argument("--formats", default=",".join(FORMATS_ALL))
    ap.add_argument("--long", type=float, default=0.0, help="also make a long version of about this many seconds (S0 timing)")
    ap.add_argument("--long-formats", default="mp3")
    ap.add_argument("--seed", type=int, default=6)
    ap.add_argument("--voice-en", default="")
    ap.add_argument("--voice-ja", default="")
    ap.add_argument("--tone-only", action="store_true")
    ap.add_argument("--selftest", action="store_true")
    args = ap.parse_args()
    args.voice = {"en": args.voice_en, "ja": args.voice_ja}
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
        sys.stderr.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass
    try:
        if args.selftest:
            ok = selftest()
            say("== make_song_fixtures selftest: %s ==" % ("ok" if ok else "FAILED"))
            return 0 if ok else 3
        if args.tone_only:
            path, meta = make_tone(args.fixture_dir or args.out)
            say("tone: %s (%d bytes, decoded %.3f s)" % (path, meta["bytes"], meta["decoded_duration"]))
            return 0
        problems = generate(args)
        path, meta = make_tone(args.out)
        say("tone: %s (%d bytes)" % (path, meta["bytes"]))
        if args.fixture_dir:
            os.makedirs(args.fixture_dir, exist_ok=True)
            import shutil
            for fn in sorted(os.listdir(args.out)):
                if fn.endswith(".truth.json") and "_long" not in fn or fn in ("tone_8s.mp3", "tone_8s.json"):
                    shutil.copyfile(os.path.join(args.out, fn), os.path.join(args.fixture_dir, fn))
                    say("copied %s -> %s" % (fn, args.fixture_dir))
        if problems:
            for p in problems:
                print("자체 검사 실패 / self-check failed: " + p, file=sys.stderr, flush=True)
            return 3
        say("== make_song_fixtures: all self-checks passed ==")
        return 0
    except Fail as e:
        print(str(e), file=sys.stderr, flush=True)
        return e.code
    except Exception as e:
        import traceback
        traceback.print_exc()
        err("예기치 않은 오류: %s" % e, "unexpected error: %s" % e)
        return 1


if __name__ == "__main__":
    sys.exit(main())
