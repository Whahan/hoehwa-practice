# -*- coding: utf-8 -*-
"""PA5a: build the synthetic calibration set (docs/v201_design.md 2.4, docs/v200_phone_design.md 1.6).

  calib_make_set.py --out <dir> [--n-sentences 200] [--voices 4] [--seed 7]

English sentences of 3..10 words (godot\\data\\pack\\practice_en.json, topped up from godot\\data\\course\\en_sentences.json when there
are too few) are spoken by the server's own TTS (`synth_wav`, Kokoro, called in this process: no server, no port, no network).
Sentences that are the same after the server's word normalization (en_words) count once, and the course sentences are only added when
there are too few practice sentences. --out may not be inside a repository, a worktree or backend (exit 2, nothing written).
Voices: only the voice packs already on disk; asking for more than there are is NOT an error ("CALIB_SET_VOICES_LIMITED have=.. want=..").
Per sentence and voice, 8 variants (VARIANTS): clean / wrong (one word of the sentence replaced, the target stays the original) /
speed 0.8 / speed 1.25 / noise SNR 20 dB / SNR 10 dB / band limited to 8 kHz sampling / amplitude x0.2.
Output (everything under --out; nothing is written anywhere else, nothing under backend\\):
  manifest.json   {"v":1,"kind":"synth","seed","n_sentences","voices_requested","voices":[..],"variants":[..],
                   "clips":[{clip, file, sentence_id, target, variant, voice, wrong:null|{index, said}, spoken, seconds, sha256}]}
                  `wrong.index` counts the words of target.split(); `said` is what is read instead. Same seed -> same sentences, same
                  replaced words, same noise; the manifest bytes are the same too when the TTS is deterministic.
  clips\\<clip>.wav  16 kHz mono 16-bit
Exit code: 0 ok, 1 failure (CALIB_SET_FAIL <reason>), 2 usage error or a forbidden --out.
"""
import argparse
import difflib
import hashlib
import io
import json
import os
import random
import re
import shutil
import sys
import zlib

sys.dont_write_bytecode = True

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.append(HERE)   # -I does not add the script folder; calib_fit sits next to this file
ROOT = os.path.dirname(os.path.dirname(HERE))
PRACTICE_PATH = os.path.join(ROOT, "godot", "data", "pack", "practice_en.json")
COURSE_PATH = os.path.join(ROOT, "godot", "data", "course", "en_sentences.json")

VARIANTS = ("clean", "wrong", "speed08", "speed125", "snr20", "snr10", "band8k", "amp02")
SENT_RE = re.compile(r"^[A-Za-z][A-Za-z ,.'?!-]*$")
WORD_RE = re.compile(r"^([^A-Za-z']*)([A-Za-z']+)(.*)$")
MIN_WORDS, MAX_WORDS = 3, 10
# easy-to-hear swaps first (minimal pairs the learner meets); any other word is replaced by a clearly different one
CONFUSIONS = {
    "ship": ["sheep"], "sheep": ["ship"], "light": ["right"], "right": ["light"], "very": ["berry"], "think": ["sink"],
    "bad": ["bed"], "bed": ["bad"], "pen": ["pan"], "cup": ["cap"], "full": ["fool"], "rice": ["lice"], "play": ["pray"],
    "walk": ["work"], "work": ["walk"], "coffee": ["copy"], "water": ["winter"], "time": ["team"], "much": ["match"],
}


class SetError(Exception):
    pass


# ------------------------------------------------------------------------------------------------ sentences (no heavy imports here)
def _read_json(path):
    with open(path, "r", encoding="utf-8-sig") as f:
        return json.load(f)


def sentence_ok(text, lo=MIN_WORDS, hi=MAX_WORDS):
    if not isinstance(text, str) or not SENT_RE.match(text.strip()):
        return False
    return lo <= len(text.split()) <= hi


_KEY_CACHE = {}


def norm_key(text):
    """the sentence as the SERVER's scoring sees it (en_words): two texts with the same key are the same sentence"""
    k = _KEY_CACHE.get(text)
    if k is None:
        import calib_fit
        k = _KEY_CACHE[text] = " ".join(calib_fit.load_server().en_words(text))
    return k


def load_pool(lo=MIN_WORDS, hi=MAX_WORDS, need=0, practice=PRACTICE_PATH, course=COURSE_PATH, key_fn=None):
    """[(sentence_id, text)] sorted by id: the practice sentences (practice_en.json); the course sentences are added ONLY when there are
    fewer than `need` of them (an id that clashes gets a "c" prefix). A sentence is listed once per key_fn value (default norm_key:
    the same words after the server's normalization, whatever the case or punctuation)."""
    key_fn = key_fn or norm_key
    out, seen = [], set()
    try:
        for s in _read_json(practice).get("sentences", []):
            t = str(s.get("text", "")).strip()
            if not sentence_ok(t, lo, hi):
                continue
            k = key_fn(t)
            if k and k not in seen:
                seen.add(k)
                out.append((str(s["id"]), t))
    except (OSError, ValueError, KeyError) as e:
        raise SetError("cannot read practice_en.json (%s)" % type(e).__name__)
    if len(out) < need:
        have = {i for i, _t in out}
        try:
            for s in _read_json(course).get("sentences", []):
                t = str(s.get("en", "")).strip()
                if not sentence_ok(t, lo, hi):
                    continue
                k = key_fn(t)
                if k and k not in seen:
                    seen.add(k)
                    sid = str(s["id"])
                    out.append((("c" + sid) if sid in have else sid, t))
        except (OSError, ValueError, KeyError):
            pass   # the course file only tops the pool up
    out.sort(key=lambda x: x[0])
    return out


def pick_sentences(pool, n, seed):
    """n sentences of the pool (all when it has fewer), chosen with the seed, listed by id"""
    rng = random.Random(seed)
    chosen = list(pool) if n >= len(pool) else rng.sample(list(pool), n)
    chosen.sort(key=lambda x: x[0])
    return chosen


def vocabulary(pool):
    v = set()
    for _i, t in pool:
        for tok in t.split():
            m = WORD_RE.match(tok)
            if m:
                c = m.group(2).lower()
                if c.isalpha() and 3 <= len(c) <= 8:
                    v.add(c)
    return sorted(v)


def choose_wrong(text, rng, vocab):
    """one word of `text` and the different word that is read instead: ({"index", "said"}, spoken text). index counts text.split()."""
    toks = text.split()
    cand = []
    for i, tok in enumerate(toks):
        m = WORD_RE.match(tok)
        if m and len(m.group(2)) >= 3 and "'" not in m.group(2):
            cand.append(i)
    if not cand:
        cand = [i for i, tok in enumerate(toks) if WORD_RE.match(tok)]
    if not cand:
        raise SetError("a sentence without a word to replace")
    i = rng.choice(cand)
    pre, core, post = WORD_RE.match(toks[i]).groups()
    low = core.lower()
    if low in CONFUSIONS:
        said = rng.choice(CONFUSIONS[low])
    else:
        opts = [w for w in vocab if w != low and abs(len(w) - len(low)) <= 2 and w[0] != low[0]
                and difflib.SequenceMatcher(None, w, low).ratio() < 0.5]
        if not opts:
            opts = [w for w in vocab if w != low]
        if not opts:
            raise SetError("no word to replace a word with")
        said = rng.choice(opts)
    spoken_core = said.capitalize() if core[0].isupper() else said
    toks2 = list(toks)
    toks2[i] = pre + spoken_core + post
    return {"index": i, "said": said}, " ".join(toks2)


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for b in iter(lambda: f.read(1 << 20), b""):
            h.update(b)
    return h.hexdigest()


def write_json(path, obj):
    d = os.path.dirname(os.path.abspath(path))
    os.makedirs(d, exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        json.dump(obj, f, ensure_ascii=False, indent=1)
        f.write("\n")


# ------------------------------------------------------------------------------------------------ audio (numpy / scipy / soundfile only here)
def _to_16k(wav_bytes):
    import numpy as np
    import soundfile as sf
    from math import gcd
    from scipy.signal import resample_poly
    with sf.SoundFile(io.BytesIO(wav_bytes)) as f:
        sr = f.samplerate
        data = f.read(dtype="float32", always_2d=True).mean(axis=1)
    if sr != 16000 and len(data):
        g = gcd(int(sr), 16000)
        data = resample_poly(data, 16000 // g, int(sr) // g).astype(np.float32)
    return np.ascontiguousarray(data, dtype=np.float32)


def synth16(S, text, speed, voice, seed):
    """the server's own TTS, then 16 kHz mono float. The torch seed is set before every call: Kokoro draws random numbers for its
    vocoder, so without it two runs of the same set differ in the audio bytes."""
    try:
        import torch
        torch.manual_seed(seed & 0x7FFFFFFF)
    except Exception:
        pass
    return _to_16k(S.synth_wav(text, "en", speed, voice))


def add_noise(x, snr_db, seed):
    import numpy as np
    if len(x) == 0:
        return x
    rs = np.random.RandomState(seed & 0xFFFFFFFF)
    noise = rs.standard_normal(len(x)).astype(np.float32)
    ps = float(np.mean(x.astype(np.float64) ** 2))
    pn = float(np.mean(noise.astype(np.float64) ** 2))
    if ps <= 0.0 or pn <= 0.0:
        return x
    noise *= np.float32(np.sqrt(ps / (10.0 ** (snr_db / 10.0)) / pn))
    return (x + noise).astype(np.float32)


def band_limit_8k(x):
    """what a 8 kHz telephone-like recording keeps: down to 8 kHz sampling and back to 16 kHz"""
    import numpy as np
    from scipy.signal import resample_poly
    if len(x) == 0:
        return x
    return resample_poly(resample_poly(x, 1, 2), 2, 1).astype(np.float32)[:len(x)]


def write_wav16(path, x):
    import numpy as np
    import soundfile as sf
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    pcm = (np.clip(x, -1.0, 1.0) * 32767.0).round().astype(np.int16)
    sf.write(path, pcm, 16000, subtype="PCM_16", format="WAV")
    return len(pcm) / 16000.0


# ------------------------------------------------------------------------------------------------ the tool
def build(out_dir, n_sentences, voices_wanted, seed, out=print):
    import calib_fit
    calib_fit.require_out_paths(out_dir)
    work = os.path.join(out_dir, "_work")
    with calib_fit.no_network():
        S = calib_fit.load_server(work_dir=work)
        pool = load_pool(MIN_WORDS, MAX_WORDS, n_sentences)
        if not pool:
            raise SetError("no sentences")
        sentences = pick_sentences(pool, n_sentences, seed)
        if len(sentences) < n_sentences:
            out("CALIB_SET_SENTENCES_LIMITED have=%d want=%d" % (len(sentences), n_sentences))
        have_voices = list(S.available_voices("en"))
        if not have_voices:
            raise SetError("no English voice on disk")
        voices = have_voices[:max(1, voices_wanted)]
        if len(voices) < voices_wanted:
            out("CALIB_SET_VOICES_LIMITED have=%d want=%d" % (len(voices), voices_wanted))
        vocab = vocabulary(pool)
        rng = random.Random(seed * 1000003 + 17)
        wrong_plan = {sid: choose_wrong(text, rng, vocab) for sid, text in sentences}   # same word for every voice
        clips = []
        os.makedirs(os.path.join(out_dir, "clips"), exist_ok=True)
        for sid, text in sentences:
            wrong, spoken = wrong_plan[sid]
            for voice in voices:
                key = "c%s_%s_" % (sid, voice)
                base = synth16(S, text, 1.0, voice, seed + zlib.crc32((key + "clean").encode("utf-8")))
                audio = {
                    "clean": base,
                    "wrong": synth16(S, spoken, 1.0, voice, seed + zlib.crc32((key + "wrong").encode("utf-8"))),
                    "speed08": synth16(S, text, 0.8, voice, seed + zlib.crc32((key + "speed08").encode("utf-8"))),
                    "speed125": synth16(S, text, 1.25, voice, seed + zlib.crc32((key + "speed125").encode("utf-8"))),
                }
                for variant in VARIANTS:
                    clip = "c%s_%s_%s" % (sid, voice, variant)
                    if variant in audio:
                        x = audio[variant]
                    elif variant == "snr20":
                        x = add_noise(base, 20.0, seed + zlib.crc32(clip.encode("utf-8")))
                    elif variant == "snr10":
                        x = add_noise(base, 10.0, seed + zlib.crc32(clip.encode("utf-8")))
                    elif variant == "band8k":
                        x = band_limit_8k(base)
                    else:   # amp02
                        x = (base * 0.2).astype(base.dtype)
                    rel = "clips/%s.wav" % clip
                    seconds = write_wav16(os.path.join(out_dir, rel), x)
                    clips.append({
                        "clip": clip, "file": rel, "sentence_id": sid, "target": text, "variant": variant, "voice": voice,
                        "wrong": dict(wrong) if variant == "wrong" else None,
                        "spoken": spoken if variant == "wrong" else text,
                        "seconds": round(seconds, 3), "sha256": sha256_file(os.path.join(out_dir, rel)),
                    })
    manifest = {"v": 1, "kind": "synth", "seed": seed, "n_sentences": len(sentences), "voices_requested": voices_wanted,
                "voices": voices, "variants": list(VARIANTS), "clips": clips}
    write_json(os.path.join(out_dir, "manifest.json"), manifest)
    shutil.rmtree(work, ignore_errors=True)   # the espeak copy and the TTS cache are not part of the set
    out("CALIB_SET_OK clips=%d sentences=%d voices=%d" % (len(clips), len(sentences), len(voices)))
    return manifest


def main(argv=None):
    ap = argparse.ArgumentParser(description="build the synthetic calibration set (Kokoro voices already on disk)")
    ap.add_argument("--out", required=True, help="folder for manifest.json and clips\\ (created)")
    ap.add_argument("--n-sentences", type=int, default=200)
    ap.add_argument("--voices", type=int, default=4)
    ap.add_argument("--seed", type=int, default=7)
    args = ap.parse_args(argv)
    if args.n_sentences < 1 or args.voices < 1:
        print("--n-sentences and --voices must be at least 1")
        return 2
    import calib_fit
    try:
        build(os.path.abspath(args.out), args.n_sentences, args.voices, args.seed)
    except calib_fit.OutPathRefused:
        print("CALIB_SET_FAIL out_path")
        return 2
    except SetError as e:
        print("CALIB_SET_FAIL %s" % e)
        return 1
    except Exception as e:   # a TTS or audio failure: only the type (an exception text may hold a sentence)
        print("CALIB_SET_FAIL %s" % type(e).__name__)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
